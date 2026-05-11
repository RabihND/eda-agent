# SPDX-License-Identifier: Apache-2.0
r"""dev/smoke.py -- direct stdio MCP test for eda-agent.

Bypasses Claude entirely. Spawns eda-agent.exe as a subprocess, does the
MCP initialize handshake, and lets you call any tool by name with a JSON
argument blob. Use this as the inner dev loop -- much faster than asking
an LLM to retry a tool call.

Examples:
    py dev\smoke.py list
    py dev\smoke.py call ping_altium
    py dev\smoke.py call get_altium_version
    py dev\smoke.py call lib_get_components "{}"
    py dev\smoke.py scenario quad_opamp
    py dev\smoke.py scenario ad9361
    py dev\smoke.py scenario ad9361_footprint

Environment:
    EDA_AGENT_EXE    override path to eda-agent.exe (default: detect from PATH)
    EDA_AGENT_DEBUG  if set, print every JSON-RPC frame in/out
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, Optional


# ---------- locate the binary ------------------------------------------------

def find_exe() -> str:
    env = os.environ.get("EDA_AGENT_EXE")
    if env and Path(env).is_file():
        return env
    found = shutil.which("eda-agent")
    if found:
        return found
    candidate = Path.home() / "AppData/Local/Programs/Python/Python312/Scripts/eda-agent.exe"
    if candidate.exists():
        return str(candidate)
    raise FileNotFoundError(
        "Couldn't find eda-agent.exe. Set EDA_AGENT_EXE or fix PATH."
    )


# ---------- minimal JSON-RPC over stdio ------------------------------------

class MCPClient:
    """A tiny MCP client. Just enough to initialize and call tools."""

    def __init__(self, exe: str, debug: bool = False, timeout: float = 15.0):
        self.exe = exe
        self.debug = debug
        self.timeout = timeout
        self.proc: Optional[subprocess.Popen] = None
        self._next_id = 0
        self._lock = threading.Lock()
        self._stderr_lines: list[str] = []
        self._stderr_thread: Optional[threading.Thread] = None

    def _drain_stderr(self):
        assert self.proc and self.proc.stderr
        for line in self.proc.stderr:
            line = line.rstrip()
            self._stderr_lines.append(line)
            if self.debug:
                print(f"[stderr] {line}", file=sys.stderr)

    def start(self):
        self.proc = subprocess.Popen(
            [self.exe, "serve"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1,  # line-buffered
        )
        self._stderr_thread = threading.Thread(target=self._drain_stderr, daemon=True)
        self._stderr_thread.start()

        # MCP initialize handshake.
        init = self.request("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "smoke.py", "version": "0.1"},
        })
        # Send the initialized notification (server expects it before tool calls).
        self.notify("notifications/initialized", {})
        return init

    def stop(self):
        if not self.proc:
            return
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        self.proc = None

    def _send(self, payload: dict):
        assert self.proc and self.proc.stdin
        line = json.dumps(payload, separators=(",", ":")) + "\n"
        if self.debug:
            print(f"[->] {line.strip()}", file=sys.stderr)
        self.proc.stdin.write(line)
        self.proc.stdin.flush()

    def _recv(self) -> dict:
        assert self.proc and self.proc.stdout
        deadline = time.time() + self.timeout
        while time.time() < deadline:
            line = self.proc.stdout.readline()
            if not line:
                if self.proc.poll() is not None:
                    err = "\n".join(self._stderr_lines[-20:])
                    raise RuntimeError(f"server died. last stderr:\n{err}")
                continue
            line = line.strip()
            if not line:
                continue
            if self.debug:
                print(f"[<-] {line}", file=sys.stderr)
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                # Server might print non-JSON garbage to stdout (bug). Skip and warn.
                print(f"WARN: non-JSON on stdout (skipped): {line!r}", file=sys.stderr)
        raise TimeoutError("no reply within timeout")

    def request(self, method: str, params: Any) -> Any:
        with self._lock:
            self._next_id += 1
            rid = self._next_id
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        msg = self._recv()
        if "error" in msg:
            raise RuntimeError(f"RPC error: {msg['error']}")
        return msg.get("result")

    def notify(self, method: str, params: Any):
        self._send({"jsonrpc": "2.0", "method": method, "params": params})


# ---------- top-level commands -----------------------------------------------

def cmd_list(client: MCPClient):
    res = client.request("tools/list", {})
    tools = res.get("tools", [])
    print(f"{len(tools)} tools registered:\n")
    for t in tools:
        print(f"  {t['name']}")


def cmd_call(client: MCPClient, tool_name: str, args_json: str):
    args = json.loads(args_json) if args_json else {}
    res = client.request("tools/call", {"name": tool_name, "arguments": args})
    # MCP returns result.content[0].text typically
    print(json.dumps(res, indent=2))


def _call_tool(client: MCPClient, tool: str, args: dict) -> Any:
    """Call a tool and unwrap the MCP `content[0].text` JSON payload."""
    res = client.request("tools/call", {"name": tool, "arguments": args})
    content = (res or {}).get("content") or []
    if not content:
        return res
    text = content[0].get("text", "")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text


def _check(label: str, ok: bool, detail: str = "") -> bool:
    mark = "PASS" if ok else "FAIL"
    line = f"  [{mark}] {label}"
    if detail:
        line += f" — {detail}"
    print(line)
    return ok


def _scenario_quad_opamp(client: MCPClient) -> int:
    """Build an LM324-shaped multi-part symbol end-to-end and verify it.

    Uses the actual LM324 pinout — 14 pins total, four op-amps, plus V+
    on pin 4 and V- on pin 11 shared across all parts. This produces a
    professionally-laid-out symbol you can place in a schematic.

    Requires an open SchLib doc in Altium. Creates a component named
    "LM324_DEMO" — old runs may leave it lying around; delete it
    manually in Altium if you re-run.
    """
    print("--- quad_opamp scenario ---")
    print("Pre-flight checks:")

    ping = _call_tool(client, "ping_altium", {})
    all_ok = _check(
        "Altium script responding",
        bool(ping.get("success")) if isinstance(ping, dict) else False,
        f"version={ping.get('altium_script_version')}" if isinstance(ping, dict) else str(ping),
    )

    active = _call_tool(client, "get_active_document", {})
    is_schlib = isinstance(active, dict) and active.get("document_kind") == "SCHLIB"
    all_ok &= _check(
        "Active document is a SchLib",
        is_schlib,
        f"file_name={active.get('file_name')}" if isinstance(active, dict) else str(active),
    )
    if not all_ok:
        print("Pre-flight failed — open a SchLib in Altium first.")
        return 1

    # Real LM324 pinout (14-pin DIP/SOIC):
    #   Part A: 1=OUT, 2=IN-, 3=IN+
    #   Part B: 7=OUT, 6=IN-, 5=IN+
    #   Part C: 8=OUT, 9=IN-, 10=IN+
    #   Part D: 14=OUT, 13=IN-, 12=IN+
    #   Shared: 4=V+, 11=V-
    # Body 600x400 mils, pins 100 mils inside the corner edges.
    PART_PINS = [
        # part index -> (out_pin, in_minus_pin, in_plus_pin, label_letter)
        (1, "1",  "2",  "3",  "A"),
        (2, "7",  "6",  "5",  "B"),
        (3, "8",  "9",  "10", "C"),
        (4, "14", "13", "12", "D"),
    ]

    # Op-amp triangle: 400 mils wide x 400 mils tall (square-ish, like a
    # standard schematic op-amp symbol). Vertices chosen so all five pin
    # body-attachment points land EXACTLY on the triangle:
    #   - left edge x=-200 spans y=-200..200 → IN- attaches at (-200,100),
    #     IN+ at (-200,-100)
    #   - top edge from (-200,200) to (200,0) passes through (0,100) where
    #     V+ body-attach lands
    #   - bottom edge from (-200,-200) to (200,0) passes through (0,-100)
    #     where V- body-attach lands
    #   - right tip (200,0) where OUT body-attach lands
    # All pins use length=200 (default) so a pin at x=-400 rotation=0
    # attaches at -400+200=-200, and so on for the other directions.
    TRIANGLE = [
        # top edge (top-left -> right tip)
        {"kind": "line", "x1": -200, "y1": 200, "x2": 200, "y2": 0, "width": 1},
        # bottom edge (right tip -> bottom-left)
        {"kind": "line", "x1": 200, "y1": 0, "x2": -200, "y2": -200, "width": 1},
        # left edge (bottom-left -> top-left)
        {"kind": "line", "x1": -200, "y1": -200, "x2": -200, "y2": 200, "width": 1},
    ]

    parts = []
    for _, out_p, inm_p, inp_p, letter in PART_PINS:
        parts.append({
            "body": list(TRIANGLE),  # one triangle per part
            "pins": [
                {"designator": out_p, "name": f"OUT{letter}",
                 "x": 400, "y": 0, "rotation": 180, "electrical_type": "output"},
                {"designator": inm_p, "name": f"IN{letter}-",
                 "x": -400, "y": 100, "rotation": 0, "electrical_type": "input"},
                {"designator": inp_p, "name": f"IN{letter}+",
                 "x": -400, "y": -100, "rotation": 0, "electrical_type": "input"},
            ],
        })

    # V+ enters the top edge at (0,100); V- enters the bottom edge at (0,-100).
    shared = [
        {"designator": "4",  "name": "V+",
         "x": 0, "y": 300, "rotation": 270, "electrical_type": "power"},
        {"designator": "11", "name": "V-",
         "x": 0, "y": -300, "rotation": 90, "electrical_type": "power"},
    ]

    print("\nBuilding LM324_OPAMP (real LM324 pinout, op-amp triangle bodies):")
    create_result = _call_tool(client, "lib_create_multipart_symbol", {
        "name": "LM324_OPAMP",
        "designator_prefix": "U",
        "description": "Quad low-power op-amp (smoke-test demo)",
        "parts": parts,
        "shared_pins": shared,
    })
    print("\nlib_create_multipart_symbol result:")
    print(json.dumps(create_result, indent=2))

    if not (isinstance(create_result, dict) and create_result.get("success")):
        print("\nFAILED: orchestrator did not report success.")
        return 1

    print("\nReading back via lib_get_pin_list:")
    pin_list = _call_tool(client, "lib_get_pin_list", {})

    passed = True
    passed &= _check(
        "part_count == 4",
        isinstance(pin_list, dict) and pin_list.get("part_count") == 4,
        f"got {pin_list.get('part_count') if isinstance(pin_list, dict) else pin_list!r}",
    )

    pins = pin_list.get("pins", []) if isinstance(pin_list, dict) else []
    by_desig = {p["designator"]: p for p in pins if isinstance(p, dict)}

    expected_owner = {
        "1": 1, "2": 1, "3": 1,        # part A
        "7": 2, "6": 2, "5": 2,        # part B
        "8": 3, "9": 3, "10": 3,       # part C
        "14": 4, "13": 4, "12": 4,     # part D
        "4": 0, "11": 0,               # shared
    }
    for desig, want in expected_owner.items():
        got = by_desig.get(desig, {}).get("owner_part_id")
        passed &= _check(
            f"pin {desig} owner_part_id == {want}",
            got == want,
            f"got {got!r}",
        )

    passed &= _check(
        "pin 1 (OUTA) coords round-tripped (x=400)",
        by_desig.get("1", {}).get("x") == 400,
        f"got x={by_desig.get('1', {}).get('x')!r}",
    )

    print()
    if passed:
        print("All assertions passed. Manual check: open Altium, find LM324_OPAMP")
        print("in the library panel, click through parts A/B/C/D, and confirm")
        print("V+/V- appear on every part while pin 1 only shows on part A.")
        return 0
    else:
        print("One or more assertions failed — see output above.")
        return 1


def _scenario_ad9361(client: MCPClient) -> int:
    """3-part AD9361 multi-part symbol using the actual datasheet pinout.

    Built via ``lib_create_ic_symbol`` (the auto-layout MCP tool) — the
    LLM only describes left/right pin lists per part with optional
    ``None`` separators between functional groups; the tool sizes the
    body, places pins with correct Altium geometry (Pin.Location at
    body-attach edge, names rendering INSIDE the body, designators
    OUTSIDE on the wire stub), and applies the standard cream-yellow
    body fill. Demonstrates the same workflow you'd use for a 1000-pin
    FPGA — just bigger lists.

    Sourced from AD9361 Rev. G datasheet, Table 13 (Pin Function
    Descriptions), 144-Ball CSP_BGA (10mm × 10mm). BGA grid coordinates
    (A1..M12) are used as pin designators throughout. Splits the chip
    along its functional boundaries:

      - Part A — RF I/O: 12 RX differential inputs (RX1A/B/C, RX2A/B/C),
                4 TX differential output pairs (TX1A/B, TX2A/B),
                TX_MON1/2, EXT_LO inputs, VCO_LDO outputs, XTALP/XTALN.
      - Part B — Digital interface: 12-bit P0 data port (CMOS / LVDS
                TX), 12-bit P1 data port (CMOS / LVDS RX), DATA_CLK,
                FB_CLK, RX_FRAME, TX_FRAME, SPI 4-wire.
      - Part C — Control + Aux + Power: ENABLE, TXNRX, RESETB, SYNC_IN,
                EN_AGC, TEST, CTRL_IN[3:0], CTRL_OUT[7:0], GPO[3:0],
                AUXDAC1/2, AUXADC, RBIAS, CLK_OUT, all 15 VDD rails,
                28 individual VSSA balls (one pin each), 8 individual VSSD
                balls, and 2 NC balls.

    P0/P1 pin names use the CMOS-mode primary function (e.g. "P0_D11");
    the LVDS-mode alternate (e.g. "TX_D5_P") is omitted from the symbol
    name for readability — refer to the datasheet for dual-function
    details. Each of the 144 BGA balls gets its own schematic pin so
    that footprint pin-to-pad mapping stays 1:1 (the MCP's
    ``_validate_pin_designator`` enforces this invariant — multi-pin
    alias strings like "A4,A6,B1" on a single pin are rejected).
    """
    print("--- ad9361 scenario ---")
    print("Pre-flight checks:")

    ping = _call_tool(client, "ping_altium", {})
    all_ok = _check(
        "Altium script responding",
        bool(ping.get("success")) if isinstance(ping, dict) else False,
        f"version={ping.get('altium_script_version')}" if isinstance(ping, dict) else str(ping),
    )

    active = _call_tool(client, "get_active_document", {})
    is_schlib = isinstance(active, dict) and active.get("document_kind") == "SCHLIB"
    all_ok &= _check(
        "Active document is a SchLib",
        is_schlib,
        f"file_name={active.get('file_name')}" if isinstance(active, dict) else str(active),
    )
    if not all_ok:
        print("Pre-flight failed — open a SchLib in Altium first.")
        return 1

    # Helper to keep the per-pin entries terse below.
    def P(desig: str, name: str, etype: str = "passive") -> dict:
        return {"designator": desig, "name": name, "electrical_type": etype}

    # Datasheet ball lists for the multi-ball ground / NC groups. Splitting
    # each into individual pins (one per BGA ball, all with the same name)
    # is what production schematic libraries do for big BGAs — every label
    # fits cleanly with no consolidated-string overflow, and ERC sees each
    # ball as a real pin tied to the right net.
    VSSA_BALLS = [
        "A4", "A6", "B1", "B2", "B12", "C2",
        "C7", "C8", "C9", "C10", "C11", "C12",
        "F3", "H2", "H3", "H6", "J2", "K2",
        "L2", "L3", "L7", "L8", "L9", "L10", "L11", "L12",
        "M4", "M6",
    ]
    VSSD_BALLS = ["D12", "F7", "F9", "F11", "G12", "H7", "H10", "K12"]
    NC_BALLS   = ["A3", "M3"]

    # ---- Part A: RF I/O ----
    # Functional groups separated visually by `None` rows. Order top-to-bottom.
    part_a = {
        "left_pins": [
            P("M1", "RX1A_P", "input"),  P("M2", "RX1A_N", "input"),
            P("H1", "RX1B_P", "input"),  P("J1", "RX1B_N", "input"),
            P("K1", "RX1C_P", "input"),  P("L1", "RX1C_N", "input"),
            None,
            P("A2", "RX2A_P", "input"),  P("A1", "RX2A_N", "input"),
            P("E1", "RX2B_P", "input"),  P("F1", "RX2B_N", "input"),
            P("C1", "RX2C_P", "input"),  P("D1", "RX2C_N", "input"),
            None,
            P("G1",  "RX_EXT_LO_IN",   "input"),
            P("G2",  "RX_VCO_LDO_OUT", "output"),
            None,
            P("M11", "XTALP", "input"),  P("M12", "XTALN", "input"),
        ],
        "right_pins": [
            P("M7",  "TX1A_P", "output"), P("M8",  "TX1A_N", "output"),
            P("M9",  "TX1B_P", "output"), P("M10", "TX1B_N", "output"),
            None,
            P("A8",  "TX2A_P", "output"), P("A7",  "TX2A_N", "output"),
            P("A10", "TX2B_P", "output"), P("A9",  "TX2B_N", "output"),
            None,
            P("A12", "TX_EXT_LO_IN",   "input"),
            P("B11", "TX_VCO_LDO_OUT", "output"),
            None,
            P("M5",  "TX_MON1", "input"), P("A5", "TX_MON2", "input"),
        ],
    }

    # ---- Part B: Digital data interface ----
    part_b = {
        "left_pins": [
            # P0 12-bit bus, high to low.
            P("E7",  "P0_D11", "bidirectional"), P("F8",  "P0_D10", "bidirectional"),
            P("D7",  "P0_D9",  "bidirectional"), P("E8",  "P0_D8",  "bidirectional"),
            P("D8",  "P0_D7",  "bidirectional"), P("E9",  "P0_D6",  "bidirectional"),
            P("D9",  "P0_D5",  "bidirectional"), P("E10", "P0_D4",  "bidirectional"),
            P("D10", "P0_D3",  "bidirectional"), P("E11", "P0_D2",  "bidirectional"),
            P("D11", "P0_D1",  "bidirectional"), P("E12", "P0_D0",  "bidirectional"),
            None,
            P("G7",  "RX_FRAME_N", "output"), P("G8", "RX_FRAME_P", "output"),
            P("G11", "DATA_CLK_P", "output"), P("H11","DATA_CLK_N", "output"),
            None,
            P("J5",  "SPI_CLK", "input"), P("J4", "SPI_DI", "input"),
        ],
        "right_pins": [
            # P1 12-bit bus, high to low.
            P("H8",  "P1_D11", "bidirectional"), P("J7",  "P1_D10", "bidirectional"),
            P("J8",  "P1_D9",  "bidirectional"), P("K7",  "P1_D8",  "bidirectional"),
            P("J9",  "P1_D7",  "bidirectional"), P("K8",  "P1_D6",  "bidirectional"),
            P("J10", "P1_D5",  "bidirectional"), P("K9",  "P1_D4",  "bidirectional"),
            P("J11", "P1_D3",  "bidirectional"), P("K10", "P1_D2",  "bidirectional"),
            P("J12", "P1_D1",  "bidirectional"), P("K11", "P1_D0",  "bidirectional"),
            None,
            P("F10", "FB_CLK_P", "input"),  P("G10", "FB_CLK_N", "input"),
            P("G9",  "TX_FRAME_P", "input"), P("H9",  "TX_FRAME_N", "input"),
            None,
            P("L6",  "SPI_DO", "output"), P("K6", "SPI_ENB", "input"),
        ],
    }

    # ---- Part C: Control + Aux + Power ----
    part_c = {
        "left_pins": [
            P("G6", "ENABLE",  "input"), P("H4", "TXNRX",   "input"),
            P("H5", "SYNC_IN", "input"), P("K5", "RESETB",  "input"),
            None,
            P("G5", "EN_AGC",  "input"), P("C4", "TEST",    "input"),
            None,
            P("C5", "CTRL_IN0", "input"), P("C6", "CTRL_IN1", "input"),
            P("D6", "CTRL_IN2", "input"), P("D5", "CTRL_IN3", "input"),
            None,
            P("D4", "CTRL_OUT0", "output"), P("E4", "CTRL_OUT1", "output"),
            P("E5", "CTRL_OUT2", "output"), P("E6", "CTRL_OUT3", "output"),
            P("F6", "CTRL_OUT4", "output"), P("F5", "CTRL_OUT5", "output"),
            P("F4", "CTRL_OUT6", "output"), P("G4", "CTRL_OUT7", "output"),
            None,
            P("B4", "GPO_3", "output"), P("B5", "GPO_2", "output"),
            P("B6", "GPO_1", "output"), P("B7", "GPO_0", "output"),
            None,
            P("B3", "AUXDAC1", "output"), P("C3", "AUXDAC2", "output"),
            P("L5", "AUXADC",  "input"),  P("L4", "RBIAS",   "input"),
            None,
            P("J6", "CLK_OUT", "output"),
        ],
        "right_pins": [
            # 1.3 V analog supplies (per RF/baseband subblock).
            P("D2",  "VDDA1P3_RX_RF",        "power"),
            P("D3",  "VDDA1P3_RX_TX",        "power"),
            P("E2",  "VDDA1P3_RX_LO",        "power"),
            P("F2",  "VDDA1P3_RX_VCO_LDO",   "power"),
            None,
            P("E3",  "VDDA1P3_TX_LO_BUFFER", "power"),
            P("B9",  "VDDA1P3_TX_LO",        "power"),
            P("B10", "VDDA1P3_TX_VCO_LDO",   "power"),
            None,
            P("J3",  "VDDA1P3_RX_SYNTH",     "power"),
            P("K3",  "VDDA1P3_TX_SYNTH",     "power"),
            P("K4",  "VDDA1P3_BB",           "power"),
            None,
            P("A11", "VDDA1P1_TX_VCO",       "power"),
            P("G3",  "VDDA1P1_RX_VCO",       "power"),
            None,
            P("F12", "VDDD1P3_DIG",          "power"),
            P("H12", "VDD_INTERFACE",        "power"),
            P("B8",  "VDD_GPO",              "power"),
            None,
            # 28 individual VSSA balls — one pin per ball, all named GND_A.
            *[P(b, "GND_A", "power") for b in VSSA_BALLS],
            None,
            # 8 individual VSSD balls — one pin per ball, all named GND_D.
            *[P(b, "GND_D", "power") for b in VSSD_BALLS],
            None,
            # 2 NC balls.
            *[P(b, "NC", "passive") for b in NC_BALLS],
        ],
    }

    parts = [part_a, part_b, part_c]
    # Pin count = non-None entries on both sides summed across parts.
    expected_pins_in_symbol = sum(
        sum(1 for r in (p["left_pins"] + p["right_pins"]) if r is not None)
        for p in parts
    )

    print(f"\nBuilding AD9361 via lib_create_ic_symbol (auto-layout, 3 parts):")
    print(f"  {expected_pins_in_symbol} pins on the symbol — all 144 balls of the")
    print(f"  CSP_BGA represented individually (clean labels, no overflow).")
    create_result = _call_tool(client, "lib_create_ic_symbol", {
        "name": "AD9361",
        "designator_prefix": "U",
        "description": "AD9361 RF Agile Transceiver (Analog Devices, 144-ball CSP_BGA)",
        "parts": parts,
    })
    print("\nlib_create_multipart_symbol result:")
    print(json.dumps(create_result, indent=2))

    if not (isinstance(create_result, dict) and create_result.get("success")):
        print("\nFAILED: orchestrator did not report success.")
        return 1

    print("\nReading back via lib_get_pin_list:")
    pin_list = _call_tool(client, "lib_get_pin_list", {})

    passed = True
    passed &= _check(
        "part_count == 3",
        isinstance(pin_list, dict) and pin_list.get("part_count") == 3,
        f"got {pin_list.get('part_count') if isinstance(pin_list, dict) else pin_list!r}",
    )

    pins = pin_list.get("pins", []) if isinstance(pin_list, dict) else []
    by_desig = {p["designator"]: p for p in pins if isinstance(p, dict)}

    # Spot-check one pin per part using real BGA coords from the datasheet.
    spot_checks = {
        "M1":  (1, "RX1A_P"),
        "M7":  (1, "TX1A_P"),
        "M11": (1, "XTALP"),
        "E7":  (2, "P0_D11"),
        "H8":  (2, "P1_D11"),
        "J5":  (2, "SPI_CLK"),
        "G6":  (3, "ENABLE"),
        "F12": (3, "VDDD1P3_DIG"),
        "H12": (3, "VDD_INTERFACE"),
        # Verify split-ground pins: each VSSA ball is its own pin on Part C.
        "A4":  (3, "GND_A"),
        "M6":  (3, "GND_A"),
        "K12": (3, "GND_D"),
        "M3":  (3, "NC"),
    }
    for desig, (want_part, want_name) in spot_checks.items():
        entry = by_desig.get(desig, {})
        passed &= _check(
            f"pin {desig} ({want_name}) on part {want_part}",
            entry.get("owner_part_id") == want_part
            and entry.get("name") == want_name,
            f"got owner_part_id={entry.get('owner_part_id')!r} name={entry.get('name')!r}",
        )

    passed &= _check(
        f"total pin count == {expected_pins_in_symbol}",
        len(pins) == expected_pins_in_symbol,
        f"got {len(pins)}",
    )

    # Sanity-check that no shared (owner_part_id=0) pins exist — this demo
    # uses a dedicated power part instead of shared pins.
    shared_count = sum(
        1 for p in pins if isinstance(p, dict) and p.get("owner_part_id") == 0
    )
    passed &= _check(
        "no shared pins (power lives on its own part)",
        shared_count == 0,
        f"got {shared_count} shared pin(s)",
    )

    print()
    if passed:
        print("All assertions passed. Manual check: open Altium, find AD9361 in")
        print("the library panel and click through parts A (RF I/O) / B (Digital")
        print("interface) / C (Control + Aux + Power). Each part should show a")
        print("filled cream-yellow rectangle with pins on left and/or right only,")
        print("real BGA coordinates as designators (M1, A7, J5, A4, M6, ...), and")
        print("a clean 1:1 pin-to-ball mapping — every one of the 144 BGA balls")
        print("appears as its own schematic pin. This is a real datasheet-accurate")
        print("AD9361 symbol you could drop into a schematic and bind to a footprint.")
        return 0
    else:
        print("One or more assertions failed — see output above.")
        return 1


def _scenario_ad9361_footprint(client: MCPClient) -> int:
    """Build the AD9361 144-ball CSP_BGA footprint in the active PcbLib.

    Datasheet source — AD9361 Rev. G, Figure 76 (Outline Dimensions,
    package option BC-144-7):

      - 144-ball CSP_BGA, body 10.0 mm × 10.0 mm × 1.7 mm max
      - BGA matrix 8.80 mm × 8.80 mm
      - Ball pitch 0.80 mm
      - Ball diameter 0.40 / 0.45 / 0.50 mm
      - 12 rows × 12 columns (rows lettered A,B,C,D,E,F,G,H,J,K,L,M;
        the letter 'I' is skipped per BGA convention to avoid confusion
        with column '1')

    Naive-user benchmark for the footprint side: this scenario stands
    in for "create the AD9361 footprint from the datasheet" — datasheet
    values up top, one batch call to place all 144 pads, four
    silkscreen tracks for the body outline.

    Requires an open .PcbLib document in Altium (File → New → Library
    → PCB Library, save as PcbLib1.PcbLib next to your SchLib).
    """
    print("--- ad9361_footprint scenario ---")
    print("Pre-flight checks:")

    ping = _call_tool(client, "ping_altium", {})
    all_ok = _check(
        "Altium script responding",
        bool(ping.get("success")) if isinstance(ping, dict) else False,
        f"version={ping.get('altium_script_version')}" if isinstance(ping, dict) else str(ping),
    )

    active = _call_tool(client, "get_active_document", {})
    is_pcblib = isinstance(active, dict) and active.get("document_kind") == "PCBLIB"
    all_ok &= _check(
        "Active document is a PcbLib",
        is_pcblib,
        f"file_name={active.get('file_name')}, kind={active.get('document_kind')}"
        if isinstance(active, dict) else str(active),
    )
    if not all_ok:
        print("Pre-flight failed. Open or create a .PcbLib in Altium first:")
        print("  File → New → Library → PCB Library, then save it.")
        return 1

    # ---- Datasheet values (mm) ----
    PITCH_MM = 0.80
    BALL_DIAM_MM = 0.45
    BODY_MM = 10.0
    ROW_LETTERS = "ABCDEFGHJKLM"   # 12 rows, no 'I'
    N_COLS = 12

    # ---- Convert mm to mils for the MCP API ----
    MILS_PER_MM = 1000.0 / 25.4    # 39.3700787...
    def mm_to_mils(mm: float) -> int:
        return int(round(mm * MILS_PER_MM))

    PITCH_MILS = mm_to_mils(PITCH_MM)             # ~31 mils
    PAD_MILS = mm_to_mils(BALL_DIAM_MM)           # ~18 mils
    BODY_HALF_MILS = mm_to_mils(BODY_MM / 2.0)    # ~197 mils

    n_rows = len(ROW_LETTERS)
    n_cols = N_COLS
    half_grid_w = ((n_cols - 1) * PITCH_MILS) // 2
    half_grid_h = ((n_rows - 1) * PITCH_MILS) // 2

    # A1 in the top-left when viewed from top: row A is +y, col 1 is -x.
    # Build pads in mm directly (lib_create_pcb_footprint takes mm-based fields).
    half_grid_w_mm = ((n_cols - 1) * PITCH_MM) / 2.0
    half_grid_h_mm = ((n_rows - 1) * PITCH_MM) / 2.0
    pads = []
    for r, letter in enumerate(ROW_LETTERS):
        y_mm = half_grid_h_mm - r * PITCH_MM
        for c in range(1, n_cols + 1):
            x_mm = -half_grid_w_mm + (c - 1) * PITCH_MM
            pads.append({
                "designator": f"{letter}{c}",
                "x_mm": x_mm, "y_mm": y_mm,
                "x_size_mm": BALL_DIAM_MM, "y_size_mm": BALL_DIAM_MM,
                "shape": "round",
            })

    print(f"\nBuilding AD9361_CSP_BGA_144 atomically via lib_create_pcb_footprint:")
    print(f"  {len(pads)} pads, body {BODY_MM}mm × {BODY_MM}mm, pitch {PITCH_MM}mm")

    # Single atomic call — footprint creation + 144 pads + body outline +
    # assembly outline + courtyard + pin-1 marker + designator text.
    # body_x_mm / body_y_mm are the package's full dimensions from the
    # datasheet outline drawing (10×10mm here). Silk and assembly draw AT
    # the body edge so pad-center to silk distance matches the datasheet's
    # "ball center to body edge" of 0.6mm. Courtyard auto-computes as
    # body + 0.25mm (IPC Nominal density default).
    pads_result = _call_tool(client, "lib_create_pcb_footprint", {
        "name": "AD9361_CSP_BGA_144",
        "description": "AD9361 RF Agile Transceiver — 144-ball CSP_BGA, 10mm × 10mm, 0.8mm pitch (BC-144-7)",
        "pads": pads,
        "body_x_mm": BODY_MM,
        "body_y_mm": BODY_MM,
        "courtyard_excess_mm": 0.25,
    })
    print(f"\nlib_create_pcb_footprint result:")
    print(json.dumps(pads_result, indent=2))

    if not (isinstance(pads_result, dict) and pads_result.get("success")):
        print("FAILED: lib_create_pcb_footprint did not report success.")
        return 1

    track_results = []  # placeholder for assertion below

    # ---- Assertions ----
    expected_pads = n_rows * n_cols  # 144
    passed = True
    passed &= _check(
        f"{expected_pads} pads added atomically",
        isinstance(pads_result, dict) and pads_result.get("pad_count") == expected_pads,
        f"got pad_count={pads_result.get('pad_count') if isinstance(pads_result, dict) else pads_result!r}",
    )
    passed &= _check(
        f"all {expected_pads} pads accepted (total = pad_count)",
        isinstance(pads_result, dict)
        and pads_result.get("total") == expected_pads
        and pads_result.get("pad_count") == expected_pads,
        f"got total={pads_result.get('total') if isinstance(pads_result, dict) else pads_result!r}, pad_count={pads_result.get('pad_count') if isinstance(pads_result, dict) else pads_result!r}",
    )

    print()
    if passed:
        print("All assertions passed. Manual check: open Altium, find")
        print("AD9361_CSP_BGA_144 in the PcbLib panel and verify visually:")
        print(f"  - 12×12 round pads at ~{PITCH_MILS} mil pitch (0.80 mm)")
        print(f"  - Pad designators A1..M12 (rows skip 'I'; 144 total)")
        print(f"  - {2 * BODY_HALF_MILS} × {2 * BODY_HALF_MILS} mil body outline (10mm × 10mm)")
        print(f"  - All pads on TopLayer (SMD)")
        return 0
    else:
        print("One or more assertions failed — see output above.")
        return 1


def cmd_scenario(client: MCPClient, name: str):
    """Pre-baked test scenarios. Add new ones here as we build features."""
    if name == "ping":
        for tool in ["ping_altium", "get_altium_version"]:
            print(f"--- {tool} ---")
            res = client.request("tools/call", {"name": tool, "arguments": {}})
            print(json.dumps(res, indent=2))
    elif name == "quad_opamp":
        sys.exit(_scenario_quad_opamp(client))
    elif name == "ad9361":
        sys.exit(_scenario_ad9361(client))
    elif name == "ad9361_footprint":
        sys.exit(_scenario_ad9361_footprint(client))
    else:
        print(f"unknown scenario: {name}")
        print("known: ping, quad_opamp, ad9361, ad9361_footprint")
        sys.exit(2)


# ---------- entrypoint -------------------------------------------------------

def main(argv: list[str]):
    if len(argv) < 1:
        print(__doc__)
        sys.exit(2)

    debug = bool(os.environ.get("EDA_AGENT_DEBUG"))
    exe = find_exe()
    if debug:
        print(f"[smoke] using {exe}", file=sys.stderr)

    client = MCPClient(exe, debug=debug)
    try:
        client.start()
        sub = argv[0]
        if sub == "list":
            cmd_list(client)
        elif sub == "call":
            if len(argv) < 2:
                print("usage: smoke.py call <tool_name> [args_json]", file=sys.stderr)
                sys.exit(2)
            cmd_call(client, argv[1], argv[2] if len(argv) > 2 else "{}")
        elif sub == "scenario":
            if len(argv) < 2:
                print("usage: smoke.py scenario <name>", file=sys.stderr)
                sys.exit(2)
            cmd_scenario(client, argv[1])
        else:
            print(f"unknown command: {sub}", file=sys.stderr)
            print(__doc__)
            sys.exit(2)
    finally:
        client.stop()


if __name__ == "__main__":
    main(sys.argv[1:])

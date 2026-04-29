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


def cmd_scenario(client: MCPClient, name: str):
    """Pre-baked test scenarios. Add new ones here as we build features."""
    if name == "ping":
        for tool in ["ping_altium", "get_altium_version"]:
            print(f"--- {tool} ---")
            res = client.request("tools/call", {"name": tool, "arguments": {}})
            print(json.dumps(res, indent=2))
    elif name == "quad_opamp":
        # Will exercise multi-part symbol creation once implemented.
        # For now this is a stub; fill in tool calls as the feature lands.
        print("TODO: implement quad_opamp scenario after lib_create_multipart_symbol lands.")
        print("Plan:")
        print("  1. lib_create_multipart_symbol(name='LM324', part_count=4, ...)")
        print("  2. lib_get_pin_list() to verify per-part assignment")
        print("  3. lib_get_component_details(name='LM324')")
    else:
        print(f"unknown scenario: {name}")
        print("known: ping, quad_opamp")
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

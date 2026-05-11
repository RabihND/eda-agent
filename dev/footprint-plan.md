# Footprint tooling — multi-phase plan

Goal: bring footprint-creation parity with what the schematic side now
has, so a "naive user" can ask "make me an AD9361 footprint from the
datasheet and link it to the symbol" and the LLM emits one MCP call.

The end-to-end test target throughout is the **AD9361 144-ball CSP_BGA**
(10mm × 10mm, 0.8mm pitch) — already proved on the schematic side as a
representative-of-real-FPGA stress case. Each phase is its own feature
branch, merged into `integration` independently, preserved for upstream
PRs.

## Phase 1 — Footprint primitives

Minimum viable footprint creation primitives so a 144-ball BGA isn't
144 individual MCP calls.

### Phase 1a (this branch — `feature/footprint-primitives`, off `feature/multi-part-symbols`)

The critical-path piece: **batch pad placement**. Without this, big-BGA
footprints are wall-time-prohibitive.

| Tool | Why |
|---|---|
| `lib_add_footprint_pads` | Batch pad placer mirroring `lib_add_pins`. 144-ball BGA in one call. Uses `_validate_pin_designator` for 1:1 enforcement (same rule as schematic side, no comma-separated alias designators). |

**Also done in 1a:** the singular `lib_add_footprint_pad` gets the
designator validator wired in (so 1:1 enforcement holds whether the
caller batches or not), and its docstring points to the batch tool for
anything beyond a few pads.

Body outline silk for the AD9361 demo uses the existing
`lib_add_footprint_track` (4 line segments forming a rectangle).

### Phase 1b (next branch — `feature/footprint-silk-shapes`)

The 2D primitives that the auto-layout tools (Phase 2) will need:

| Tool | Why |
|---|---|
| `lib_add_footprint_rectangle` | Body outline, courtyard, fab markings — single call instead of 4 tracks. |
| `lib_add_footprint_circle` | Pin-1 marker dot, round courtyard. |
| `lib_add_footprint_string` | Silkscreen text — designator placeholder ("U?"), value, manufacturer notes. |

### Smoke scenario (lives in 1a, extended in 1b)
`py dev\smoke.py scenario ad9361_footprint`:
- Phase 1a version: create `AD9361_CSP_BGA_144`, place 144 pads via
  the batch tool, draw 10mm × 10mm body outline as 4 silkscreen tracks.
- Phase 1b version: replace 4 tracks with one `lib_add_footprint_rectangle`,
  add a pin-1 circle near A1, add a "U?" designator string.

## Phase 2 — Footprint auto-layout

**Branch: `feature/footprint-auto-layout` (off `main` after Phase 1 lands)**

High-level package-aware tools so the LLM doesn't compute pad coordinates
from package geometry by hand.

### Tools added
| Tool | Args |
|---|---|
| `lib_create_bga_footprint` | name, rows, cols, pitch_mm, ball_diameter_mm, body_size_mm, row_letters (skip-I default), pin1_corner |
| `lib_create_qfp_footprint` | name, pin_count, pitch_mm, lead_length_mm, body_size_mm |
| `lib_create_qfn_footprint` | name, pin_count, pitch_mm, body_size_mm, exposed_pad_size_mm |
| `lib_create_soic_footprint` | name, pin_count, pitch_mm (default 1.27 = 50 mil), body_width_mm |

Each calls Phase-1 primitives (batch pads + silk shapes + pin-1 marker
+ designator) so the user describes the package in datasheet language,
not coordinates.

## Phase 3 — 3D body on footprint

**Branch: `feature/footprint-3d-body`**

Replaces the broken `lib_link_3d_model` (which adds an `ISch_Implementation`
on the *schematic component* and ignores offset/rotation params).

### Tools added
| Tool | What |
|---|---|
| `lib_add_3d_body` | Creates an `IPCB_BodyObject` on the **PcbLib footprint**. Supports embedded or linked .step. Working `offset_x/y/z` and `rotation_x/y/z`. Sets `StandOffHeight`. |
| `lib_set_component_height` | Sets the footprint's overall component height (for 3D mech clearance + bin-packing on enclosures). |

`lib_link_3d_model` (existing) — keep for backward compat but mark
deprecated in docstring; point callers at `lib_add_3d_body`.

## Phase 4 — Component parameters for BOM

**Branch: `feature/component-parameters`**

Pull through the datasheet metadata that quoting / assembly systems need.

### Tools added
| Tool | What |
|---|---|
| `lib_set_component_parameters` | Sets standard BOM params on the SchLib component: `Manufacturer`, `Manufacturer_PN`, `Description`, `Value`, `Tolerance`, `Voltage_Rating`, `Power_Rating`, `Package`, `Distributor`, `Distributor_PN`, `Datasheet`, plus arbitrary custom keys. |

Existing `lib_batch_set_params` already handles batch parameter setting
across many components — keep that as-is, the new tool is the
single-component convenience version.

## Phase 5 — BOM export

**Branch: `feature/bom-export`**

Pipe the populated parameters out as CSV into a quoting system.

### Tools verified / added
| Tool | What |
|---|---|
| `get_bom` (existing) | Audit: does it pull Manufacturer / Distributor params? |
| `export_bom_csv` | Writes a CSV at the given path with configurable column set: `[Designator, Manufacturer, Manufacturer_PN, Quantity, Value, Description, Distributor_PN, ...]`. |

## Phase 6 — End-to-end AD9361 demo

**Lands in `integration` after all phases merge.**

Single smoke scenario:
```
py dev\smoke.py scenario ad9361_full
```
that builds the AD9361 schematic symbol, footprint, links them, attaches
the 3D body, sets manufacturer parameters from the datasheet, and emits
a CSV BOM row — all from one call. The naive-user benchmark for the MCP.

## Risks / decisions

1. **Pad layer setting** — the existing `Lib_AddFootprintPad` reads a
   `layer` param but never applies it to `Pad.Layer`. Phase 1 inherits
   this behavior for now (matching is safer than guessing the right enum
   constant); fix it as part of Phase 2 once we have a known-good
   BGA-on-top-layer demo to verify against.
2. **3D body property names** — `IPCB_BodyObject` properties for offset
   and rotation need verification against Altium's actual API before
   Phase 3 ships, to avoid the kind of `LineColor`-vs-`Color` mistake we
   already paid for once. Before adding any property assignment, copy
   from a known-working DelphiScript example.
3. **Naming convention for footprints** — using `<chip>_<package>` (e.g.
   `AD9361_CSP_BGA_144`) so footprint names are readable in PcbLib panel
   and BOM export.

# Multi-part symbol creation — design plan

Goal: add multi-part symbol support (e.g. quad op-amp where one component
has 4 functional units A/B/C/D plus shared power pins) to eda-agent's
library tools.

Reference: [coffeenmusic/altium-mcp](https://github.com/coffeenmusic/altium-mcp)
already does this in a single tool. We mirror their approach but factor
it to fit eda-agent's existing factored design (separate create / add /
batch tools).

## Altium API recap

What Altium's DelphiScript exposes:

```pas
SchComponent.PartCount := N;        // total parts in this component
SchComponent.CurrentPartID := 1;    // which part is "active" for editing
SchComponent.DisplayMode := 0;      // normal vs alternate display

// Per-primitive (pin / rectangle / line / arc / polygon):
Pin.OwnerPartId := K;               // 1..N = belongs to part K
                                    // 0     = SHARED across all parts (e.g. VCC/GND)
Pin.OwnerPartDisplayMode := 0;
```

The whole thing is one component object with one `LibReference` (e.g.
"LM324"). Designators auto-suffix when placed: `U1A`, `U1B`, `U1C`, `U1D`.

## Design

### Option A — extend existing tools (chosen)

Add an optional `owner_part_id` parameter to every primitive-adding tool,
and a `part_count` parameter to `lib_create_symbol`.

| Tool | New parameter | Default |
|---|---|---|
| `lib_create_symbol` | `part_count: int` | 1 |
| `lib_add_pin` | `owner_part_id: int` | 1 |
| `lib_add_pins` | `owner_part_id` field on each pin dict | 1 |
| `lib_add_symbol_rectangle` | `owner_part_id: int` | 1 |
| `lib_add_symbol_line` | `owner_part_id: int` | 1 |
| `lib_add_symbol_arc` | `owner_part_id: int` | 1 |
| `lib_add_symbol_polygon` | `owner_part_id: int` | 1 |

`owner_part_id = 0` ⇒ shared across all parts (the canonical pattern for
power/ground).

Auto-grow `PartCount` if any pin's `owner_part_id > PartCount` at flush
time (matches coffeenmusic's behavior — forgiving when the LLM forgets
to set `part_count` upfront).

### Option B — new high-level convenience tool

Also add `lib_create_multipart_symbol` for one-shot creation. Useful when
the LLM has all the data at once (parsed from a datasheet):

```python
lib_create_multipart_symbol(
    name="LM324",
    designator_prefix="U",
    description="Quad op-amp",
    part_count=4,
    parts=[
        {  # part 1 (op-amp A)
            "body": {"kind": "rect", "x1": -200, "y1": -200, "x2": 200, "y2": 200},
            "pins": [
                {"designator": "1", "name": "OUT_A", "x": 200, "y": 0, ...},
                {"designator": "2", "name": "IN_A-", "x": -200, "y": 100, ...},
                {"designator": "3", "name": "IN_A+", "x": -200, "y": -100, ...},
            ],
        },
        # ...part 2, 3, 4 same shape
    ],
    shared_pins=[
        {"designator": "4",  "name": "VCC", ...},
        {"designator": "11", "name": "GND", ...},
    ],
)
```

Internally this just delegates to:
1. `lib_create_symbol(part_count=4, ...)`
2. for each part: place body + pins with `owner_part_id=1..N`
3. `lib_add_pins(shared_pins, owner_part_id=0)`

We'll do **both options**. Option A is the building block (any LLM can
chain them); Option B is the LLM-friendly convenience that turns a
datasheet into one tool call.

## Implementation plan

### Phase 1 — primitive owner_part_id support

Edit the **DelphiScript** side first (`scripts/altium/Library.pas`) — once
the underlying primitives accept `OwnerPartId`, the Python wrappers are
trivial passthroughs.

#### Files to edit (DelphiScript)

`scripts/altium/Library.pas` —
1. `Lib_CreateSymbol`:
   - Read `part_count` from params (default 1).
   - After `Component.LibReference := Name`, set
     `Component.PartCount := PartCountValue;`
     `Component.CurrentPartID := 1;`
     `Component.DisplayMode := 0;`
2. `Lib_AddPin`, `Lib_AddPins`:
   - Read `owner_part_id` (default 1; if absent on a per-pin record in
     `Lib_AddPins`, fall back to a top-level default in the params).
   - After pin creation, set `Pin.OwnerPartId := OwnerPartIdValue;`
     `Pin.OwnerPartDisplayMode := 0;`
3. `Lib_AddSymbolRectangle`, `Lib_AddSymbolLine`,
   `Lib_AddSymbolArc`, `Lib_AddSymbolPolygon`:
   - Same `owner_part_id` parameter and assignment after creation.
4. `Lib_GetComponentDetails` and `Lib_GetPinList`:
   - Include `owner_part_id` and `part_count` in returned JSON so we can
     verify what was created.

Helper to add (top of `Library.pas` if not already present):

```pas
Function ExtractIntDefault(Params : String; Key : String; Default : Integer) : Integer;
Var S : String;
Begin
    S := ExtractJsonValue(Params, Key);
    If S = '' Then Result := Default
    Else Result := StrToIntDef(S, Default);
End;
```

#### Files to edit (Python)

`src/eda_agent/tools/library.py` — add `owner_part_id` and `part_count`
parameters to the relevant `@mcp.tool()` functions, just forwarding to
the bridge call. Update docstrings to explain the convention
(0 = shared, 1..N = part).

### Phase 2 — convenience tool

Add `lib_create_multipart_symbol` to `tools/library.py`. Implement
**purely in Python** by orchestrating the lower-level tools — no new
DelphiScript needed. Each Phase-1 building block is one bridge call, so
the convenience tool is N+1 bridge calls but still one MCP turn.

### Phase 3 — verification

`dev/smoke.py scenario quad_opamp` runs:
1. Open / create a SchLib doc.
2. Call `lib_create_multipart_symbol` for an LM324.
3. Call `lib_get_component_details` and assert `part_count == 4`.
4. Call `lib_get_pin_list` and assert pins 4 and 11 have `owner_part_id == 0`.
5. Optional: open Altium UI manually and verify A/B/C/D show up correctly.

## Risks / open questions

1. **DelphiScript int parsing** — `StrToIntDef` should work but eda-agent
   may have its own helper; check `Utils.pas` first.
2. **PartCount must be set BEFORE adding pins?** — Probably yes. If we
   add pins to a 1-part component then bump PartCount later, Altium may
   not redistribute existing pins. Spec: set part_count at create time
   AND optionally allow bumping it later but document the caveat.
3. **`OwnerPartDisplayMode`** — coffeenmusic always sets it to 0. We do
   the same. If Alternate display mode support is ever needed, add an
   `owner_part_display_mode` parameter; out of scope for v1.
4. **Body assignment** — coffeenmusic creates one rectangle per part
   inside `CreateSchematicSymbol`. We give the LLM the building block
   (`lib_add_symbol_rectangle` with `owner_part_id`) and also offer the
   convenience tool that auto-creates per-part bodies if they're omitted.

## Acceptance criteria

- [ ] `lib_create_symbol(part_count=4)` creates a 4-part symbol.
- [ ] `lib_add_pin(..., owner_part_id=2)` adds a pin to part B.
- [ ] `lib_add_pin(..., owner_part_id=0)` adds a shared pin (visible on
      every part when placed).
- [ ] `lib_add_pins([{..., owner_part_id=1}, {..., owner_part_id=0}])`
      mixes part-specific and shared pins in one call.
- [ ] `lib_create_multipart_symbol` handles a quad op-amp end-to-end.
- [ ] `lib_get_pin_list` returns `owner_part_id` for each pin.
- [ ] `lib_get_component_details` returns `part_count`.
- [ ] `dev/smoke.py scenario quad_opamp` passes.
- [ ] Manual check: open Altium, place the symbol; A/B/C/D auto-suffix
      works; placing one auto-fills the rest into the same designator
      group.

# eda-agent bug report — Zynq UltraScale+ multi-part session

Source: Claude Desktop sessions, 2026-05 — building a 19-part / 784-pin
XCZU3EG/5EV SFVC784 symbol against `feature/footprint-primitives`
**before** the upstream main merge (`1aa3739`).

This file is a tracking artifact, not the report itself — see the
session log for the verbatim report. Use this file to mark which bugs
have been triaged / fixed.

Bridge version when filed: `2026.04.22.18`.

## Status legend

- `[ ]` open
- `[x]` fixed (commit ref in trailing note)
- `[~]` likely fixed by upstream merge — needs re-test to confirm
- `[!]` won't fix / by design

## Tracker

Audit performed after upstream merge `1aa3739` — see "Upstream merge"
column for whether the new `main` material plausibly addresses each
item.

| # | Status | Severity | Bug | Upstream merge | Note |
|---|--------|----------|-----|----------------|------|
| 1 | [x] | **Critical** | `query_objects` only sees active part in multi-part SchLib | not touched | Fixed: SchLib branch in `ProcessSchDocObjects` walks `CurrentSchComponent.SchIterator_Create` across all parts; emits `_owner_part_id` on every match. `OwnerPartId` is also a queryable property in the props list. |
| 2 | [x] | **Critical** | SchLib text labels via `create_object(eLabel, container=component)` don't persist | not touched | Fixed: `Gen_CreateObject` component path now calls `SetOwnerPart(NewObj, Component)` before `AddSchObject` + `MarkLibDirty` + `GraphicallyInvalidate`, matching the working `Lib_AddSymbolRectangle` flow. |
| 3 | [x] | Medium | `eTextString` rejected as unknown object type | not touched | Added `eTextString` and `eText` aliases mapping to `eLabel` (the actual schematic primitive token); `eNote` added separately. |
| 4 | [x] | **High** | `lib_batch_rename` always returns `failed: 1, renamed: 0` | function exists | Per-failure reason now reported in `errors` JSON field. Name-collision pre-check added. Each remove/readd wrapped in Try/Except so one bad row doesn't poison the batch. |
| 5 | [x] | **High** | No `lib_delete_component` tool | not added | Added `Lib_DeleteComponent` + `lib_delete_component` Python wrapper. |
| 6 | [x] | Medium | Bad property values crash the IPC bridge | not touched | `ApplySetPropertiesEx` adds a per-property Try/Except at the call-site (defense in depth above SetSchProperty's existing inner guard). `create_object` returns `skipped_properties` in the response so callers can see which props were rejected. |
| 7 | [x] | Medium | `lib_get_components` returns stale results after recent create | not touched | `Lib_GetComponents` now force-flushes the matching IServerDocument (`DoFileSave`) before invoking the on-disk reader, so unsaved in-editor changes are visible. |
| 8 | [x] | Medium | No `lib_set_active_part(part_id)` | not added | Added `Lib_SetActivePart` + `lib_set_active_part` Python wrapper. Validates part_id against `Component.PartCount`. |
| 9 | [x] | Low | `lib_get_component_details` reports `part_count: 20` for a 19-part symbol | not touched | `Lib_GetComponentDetails` now prefers the live `Component.PartCount` over the LibReader's `CompInfo.PartCount` (which was returning +1 on Altium 26.5). |
| 10 | [~] | Low | `refresh_document` doesn't invalidate the SCH Library panel cache | not touched | Investigated; the obvious `SCHM_LibraryComponentsListChanged` broadcast constant isn't declared on this build. Left as a documented limitation — user clicks off/on the SchLib tab to refresh the panel manually. |

## Verification scenario (apply after fixes)

```python
lib_create_ic_symbol(name="SMOKE_TEST", parts=[<3 parts, 20 pins total>])
batch_create([
    {"object_type": "eLabel", "container": "component",
     "properties": f"Text=PART_{i}|Location.X=0|Location.Y=400|OwnerPartId={i}"}
    for i in [1, 2, 3]
])
save_all()
assert query_objects("eLabel", "Text,OwnerPartId")["count"] == 3
assert "SMOKE_TEST" in lib_get_components()["names"]
lib_batch_rename([{"old_name": "SMOKE_TEST", "new_name": "SMOKE_TEST_2"}])
assert renamed == 1
lib_delete_component(name="SMOKE_TEST_2")
assert deleted is True
# Bad-property crash test:
create_object("eLabel", container="component",
              properties="Text=X|Location.X=0|Location.Y=0|OwnerPartId=1|Justification=2")
ping_altium()   # must still respond
```

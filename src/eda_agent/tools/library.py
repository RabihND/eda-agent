# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 George Saliba
"""Library management tools for Altium Designer MCP Server."""

from typing import Any, Optional
from ..bridge import get_bridge
from ..bridge.exceptions import InvalidParameterError
from .bulk_hints import BulkHintTracker
from .datasheet_hints import tag_response
from ..config import get_config


# Characters that indicate a designator was used to alias multiple package
# pads onto a single schematic pin. This is a long-standing convention in
# some Altium libraries but it BREAKS schematic↔footprint pin mapping —
# each schematic pin must correspond to exactly one footprint pad so that
# downstream PCB workflows (annotation, ECO, ECO-back, BOM, pick-and-place)
# stay coherent. Reject these everywhere a designator enters the system.
_INVALID_DESIGNATOR_CHARS = (",", ";", " ", "\t", "\n", "\r")


def _validate_pin_designator(designator: Any, context: str = "pin") -> str:
    """Enforce the 1-pin-per-pad invariant: one designator, no aliasing.

    Each schematic pin must map 1:1 to a single footprint pad. Multi-pin
    designator strings like ``"A4,A6,B1"`` (sometimes used to fold many
    GND/VCC balls onto a single symbol pin) silently break footprint
    binding — annotation can't unique-identify pads, ECO drifts, and the
    PCB sees a different pin count than the schematic. Always split
    grouped power/ground/NC pins into one symbol pin per package ball
    even if it makes the symbol taller.

    Returns the cleaned designator string. Raises InvalidParameterError
    with a clear remediation message on violation.
    """
    if not isinstance(designator, str):
        raise InvalidParameterError(
            f"{context} designator must be a string, got "
            f"{type(designator).__name__}"
        )
    cleaned = designator.strip()
    if not cleaned:
        raise InvalidParameterError(f"{context} designator is empty")
    for ch in _INVALID_DESIGNATOR_CHARS:
        if ch in cleaned:
            display = repr(ch) if ch in (" ", "\t", "\n", "\r") else ch
            raise InvalidParameterError(
                f"{context} designator {cleaned!r} contains {display!r} — "
                f"each schematic pin must map 1:1 to a single footprint "
                f"pad, so multi-pin aliases (e.g. 'A4,A6,B1') are not "
                f"allowed. Split grouped power/ground/NC pins into one "
                f"symbol pin per package ball."
            )
    return cleaned


def register_library_tools(mcp):
    """Register library tools with the MCP server."""

    # =========================================================================
    # Symbol Creation
    # =========================================================================

    @mcp.tool()
    async def lib_create_symbol(
        name: str,
        designator_prefix: str = "U",
        description: str = "",
        part_count: int = 1,
    ) -> dict[str, Any]:
        """Create a new schematic symbol in the active library.

        Args:
            name: Component name
            designator_prefix: Default designator prefix (e.g., "U", "R", "C")
            description: Component description
            part_count: Number of functional parts in this component. Use >1
                for multi-part symbols (e.g., 4 for a quad op-amp). Pins and
                shapes added afterwards take an ``owner_part_id``: 1..N picks
                which part the primitive belongs to, and 0 marks it as shared
                across all parts (the canonical pattern for VCC/GND on
                multi-part chips). Set this at create time — bumping it later
                will not redistribute existing pins.

        Returns:
            Dictionary with created symbol information
        """
        if part_count < 1:
            raise InvalidParameterError("part_count must be >= 1")
        bridge = get_bridge()
        result = await bridge.send_command_async(
            "library.create_symbol",
            {
                "name": name,
                "designator_prefix": designator_prefix,
                "description": description,
                "part_count": part_count,
            },
        )
        return result

    @mcp.tool()
    async def lib_add_pin(
        designator: str,
        name: str,
        x: int,
        y: int,
        length: int = 200,
        rotation: int = 0,
        electrical_type: str = "passive",
        hidden: bool = False,
        owner_part_id: int = 1,
    ) -> dict[str, Any]:
        """Add a pin to the current symbol.

        IMPORTANT — if you need to add more than one pin, use
        `lib_add_pins` (batch) instead. Creating a new symbol with 20+
        pins via this singular tool is the biggest wall-time sink in
        library workflows: each pin is a full LLM turn. The batch
        version does all pins in one PreProcess/PostProcess + one save.

        Args:
            designator: Pin designator — a single package-pad identifier
                (e.g., "1", "2", "M11", "A4"). Comma-separated alias
                strings ("A4,A6,B1") are REJECTED: each schematic pin
                must map 1:1 to exactly one footprint pad. For BGAs
                with many GND/VCC balls, call this once per ball with
                the same ``name`` and unique designators.
            name: Pin name
            x: X coordinate in mils
            y: Y coordinate in mils
            length: Pin length in mils
            rotation: Pin rotation in degrees (0, 90, 180, 270)
            electrical_type: Electrical type:
                - "input", "output", "bidirectional", "passive"
                - "open_collector", "open_emitter", "power", "hiz"
            hidden: Whether to hide the pin
            owner_part_id: Multi-part owner. 1..N picks which part the pin
                belongs to (matches ``part_count`` on ``lib_create_symbol``).
                ``0`` marks the pin as shared across all parts (the canonical
                pattern for VCC/GND on multi-part chips). Default 1.

        Returns:
            Dictionary confirming pin addition
        """
        if owner_part_id < 0:
            raise InvalidParameterError("owner_part_id must be >= 0 (0 = shared)")
        designator = _validate_pin_designator(
            designator, context=f"pin {name!r}"
        )
        bridge = get_bridge()
        result = await bridge.send_command_async(
            "library.add_pin",
            {
                "designator": designator,
                "name": name,
                "x": x,
                "y": y,
                "length": length,
                "rotation": rotation,
                "electrical_type": electrical_type,
                "hidden": hidden,
                "owner_part_id": owner_part_id,
            },
        )
        hint = BulkHintTracker.record_and_hint("lib_add_pin")
        if hint and isinstance(result, dict):
            result["_hint_bulk"] = hint
        return result

    @mcp.tool()
    async def lib_add_pins(
        pins: list[dict[str, Any]],
        default_owner_part_id: int = 1,
    ) -> dict[str, Any]:
        """Add MANY pins to the current symbol in ONE call.

        PREFER THIS over looping `lib_add_pin`. A 48-pin IC symbol
        built one pin at a time is 48 LLM turns; with this tool it's
        one turn + one PreProcess/PostProcess + one save.

        Args:
            pins: List of pin dicts, each with:
                - designator (str, required) — a SINGLE package-pad
                  identifier (e.g., "1", "M11", "A4"). Comma-separated
                  alias strings like "A4,A6,B1" are REJECTED: each
                  schematic pin must map 1:1 to exactly one footprint
                  pad. For BGAs with many GND/VCC balls, emit one entry
                  per ball with the same ``name`` and unique designators.
                - name       (str, required)
                - x, y       (int, mils) — pin endpoint
                - length     (int, mils, default 200)
                - rotation   (int, default 0) — 0/90/180/270
                - electrical_type (str, default "passive") — one of
                  input/output/bidirectional/passive/open_collector/
                  open_emitter/power/hiz/io
                - hidden     (bool, default False)
                - owner_part_id (int, optional) — multi-part owner.
                  1..N picks the part; 0 marks the pin as shared across
                  all parts (canonical for VCC/GND on multi-part chips).
                  If omitted on a pin, falls back to ``default_owner_part_id``.
            default_owner_part_id: Fallback ``owner_part_id`` for pins that
                don't set their own. Default 1 (regular single-part behavior).
                Set to 0 when the whole batch is shared power/ground pins.

        Example — quad op-amp stage A plus shared power:
            lib_add_pins(pins=[
                {"designator": "1",  "name": "OUT_A", "x": 0, "y": 0,
                 "electrical_type": "output", "owner_part_id": 1},
                {"designator": "2",  "name": "IN_A-", "x": 0, "y": 100,
                 "electrical_type": "input",  "owner_part_id": 1},
                {"designator": "3",  "name": "IN_A+", "x": 0, "y": 200,
                 "electrical_type": "input",  "owner_part_id": 1},
                {"designator": "4",  "name": "VCC",   "x": 0, "y": -100,
                 "electrical_type": "power",  "owner_part_id": 0},
                {"designator": "11", "name": "GND",   "x": 0, "y": -200,
                 "electrical_type": "power",  "owner_part_id": 0},
            ])

        Returns:
            Dict with added, failed, total counts.
        """
        if default_owner_part_id < 0:
            raise InvalidParameterError("default_owner_part_id must be >= 0 (0 = shared)")
        op_strs: list[str] = []
        for idx, p in enumerate(pins):
            name = str(p.get("name", "")).strip()
            desig = _validate_pin_designator(
                p.get("designator", ""),
                context=f"pins[{idx}] (name={name!r})",
            )
            fields = [
                f"designator={desig}",
                f"name={name}",
                f"x={int(p.get('x', 0))}",
                f"y={int(p.get('y', 0))}",
                f"length={int(p.get('length', 200))}",
                f"rotation={int(p.get('rotation', 0))}",
                f"electrical_type={p.get('electrical_type', 'passive')}",
                f"hidden={'true' if p.get('hidden') else 'false'}",
            ]
            if "owner_part_id" in p:
                opid = int(p["owner_part_id"])
                if opid < 0:
                    raise InvalidParameterError(
                        f"owner_part_id must be >= 0 (got {opid} for pin {desig!r})"
                    )
                fields.append(f"owner_part_id={opid}")
            op_strs.append(";".join(fields))

        if not op_strs:
            return {"error": "No valid pins", "added": 0}

        bridge = get_bridge()
        return await bridge.send_command_async(
            "library.add_pins",
            {
                "pins": "~~".join(op_strs),
                "default_owner_part_id": default_owner_part_id,
            },
        )

    @mcp.tool()
    async def lib_add_symbol_rectangle(
        x1: int,
        y1: int,
        x2: int,
        y2: int,
        fill_color: int = 11599871,
        border_color: int = 0,
        owner_part_id: int = 1,
    ) -> dict[str, Any]:
        """Add a rectangle to the current symbol body.

        Args:
            x1: First corner X in mils
            y1: First corner Y in mils
            x2: Opposite corner X in mils
            y2: Opposite corner Y in mils
            fill_color: Body fill color as a Delphi TColor integer
                (BGR-packed). Default ``11599871`` ($00B0FFFF) is the
                standard Altium cream-yellow IC body fill — the same
                color you see on stock library symbols. Pass ``-1`` for
                no fill (transparent body).
            border_color: Border line color as a Delphi TColor integer.
                Default ``0`` (black).
            owner_part_id: Multi-part owner. 1..N picks which part the
                rectangle belongs to (matches ``part_count`` on
                ``lib_create_symbol``). ``0`` marks it as shared across
                all parts. Default 1.

        Returns:
            Dictionary confirming rectangle addition
        """
        if owner_part_id < 0:
            raise InvalidParameterError("owner_part_id must be >= 0 (0 = shared)")
        bridge = get_bridge()
        result = await bridge.send_command_async(
            "library.add_symbol_rectangle",
            {
                "x1": x1,
                "y1": y1,
                "x2": x2,
                "y2": y2,
                "fill_color": fill_color,
                "border_color": border_color,
                "owner_part_id": owner_part_id,
            },
        )
        return result

    @mcp.tool()
    async def lib_add_symbol_line(
        x1: int,
        y1: int,
        x2: int,
        y2: int,
        width: int = 1,
        owner_part_id: int = 1,
    ) -> dict[str, Any]:
        """Add a line to the current symbol.

        Args:
            x1: Start X in mils
            y1: Start Y in mils
            x2: End X in mils
            y2: End Y in mils
            width: Line width
            owner_part_id: Multi-part owner. 1..N picks the part; 0 marks
                the line as shared across all parts. Default 1.

        Returns:
            Dictionary confirming line addition
        """
        if owner_part_id < 0:
            raise InvalidParameterError("owner_part_id must be >= 0 (0 = shared)")
        bridge = get_bridge()
        result = await bridge.send_command_async(
            "library.add_symbol_line",
            {
                "x1": x1, "y1": y1, "x2": x2, "y2": y2,
                "width": width, "owner_part_id": owner_part_id,
            },
        )
        return result

    # =========================================================================
    # Footprint Creation
    # =========================================================================

    @mcp.tool()
    async def lib_create_footprint(
        name: str,
        description: str = "",
    ) -> dict[str, Any]:
        """Create a new PCB footprint in the active library.

        Args:
            name: Footprint name
            description: Footprint description

        Returns:
            Dictionary with created footprint information
        """
        bridge = get_bridge()
        result = await bridge.send_command_async(
            "library.create_footprint",
            {"name": name, "description": description},
        )
        return result

    @mcp.tool()
    async def lib_add_footprint_pad(
        designator: str,
        x: int,
        y: int,
        x_size: int = 60,
        y_size: int = 60,
        hole_size: int = 0,
        shape: str = "rectangular",
        layer: str = "TopLayer",
        rotation: int = 0,
    ) -> dict[str, Any]:
        """Add a pad to the current footprint.

        Args:
            designator: Pad designator (e.g., "1", "2")
            x: X coordinate in mils
            y: Y coordinate in mils
            x_size: Pad X size in mils
            y_size: Pad Y size in mils
            hole_size: Drill hole size in mils (0 for SMD)
            shape: Pad shape ("round", "rectangular", "octagonal")
            layer: Layer ("TopLayer", "BottomLayer", "MultiLayer")
            rotation: Pad rotation in degrees

        Returns:
            Dictionary confirming pad addition
        """
        bridge = get_bridge()
        result = await bridge.send_command_async(
            "library.add_footprint_pad",
            {
                "designator": designator,
                "x": x,
                "y": y,
                "x_size": x_size,
                "y_size": y_size,
                "hole_size": hole_size,
                "shape": shape,
                "layer": layer,
                "rotation": rotation,
            },
        )
        return result

    @mcp.tool()
    async def lib_add_footprint_track(
        x1: int,
        y1: int,
        x2: int,
        y2: int,
        width: int = 10,
        layer: str = "TopOverlay",
    ) -> dict[str, Any]:
        """Add a track to the current footprint (for silkscreen/courtyard).

        Args:
            x1: Start X in mils
            y1: Start Y in mils
            x2: End X in mils
            y2: End Y in mils
            width: Track width in mils
            layer: Layer (typically TopOverlay for silkscreen)

        Returns:
            Dictionary confirming track addition
        """
        bridge = get_bridge()
        result = await bridge.send_command_async(
            "library.add_footprint_track",
            {"x1": x1, "y1": y1, "x2": x2, "y2": y2, "width": width, "layer": layer},
        )
        return result

    @mcp.tool()
    async def lib_add_footprint_arc(
        x_center: int,
        y_center: int,
        radius: int,
        start_angle: float = 0,
        end_angle: float = 360,
        width: int = 10,
        layer: str = "TopOverlay",
    ) -> dict[str, Any]:
        """Add an arc to the current footprint.

        Args:
            x_center: Center X in mils
            y_center: Center Y in mils
            radius: Arc radius in mils
            start_angle: Start angle in degrees
            end_angle: End angle in degrees
            width: Line width in mils
            layer: Layer for the arc

        Returns:
            Dictionary confirming arc addition
        """
        bridge = get_bridge()
        result = await bridge.send_command_async(
            "library.add_footprint_arc",
            {
                "x_center": x_center,
                "y_center": y_center,
                "radius": radius,
                "start_angle": start_angle,
                "end_angle": end_angle,
                "width": width,
                "layer": layer,
            },
        )
        return result

    # =========================================================================
    # Component Linking
    # =========================================================================

    @mcp.tool()
    async def lib_link_footprint(
        component_name: str,
        footprint_name: str,
        footprint_library: str = "",
    ) -> dict[str, Any]:
        """Link a footprint to a schematic component.

        NOTE: Uses the current active library component, not the specified
        component_name. Open/focus the target component in the SchLib editor
        before calling this.

        Args:
            component_name: Name of the schematic component (currently ignored —
                see note above)
            footprint_name: Name of the footprint to link
            footprint_library: Library containing the footprint (optional if same library)

        Returns:
            Dictionary confirming link
        """
        bridge = get_bridge()
        result = await bridge.send_command_async(
            "library.link_footprint",
            {
                "component_name": component_name,
                "footprint_name": footprint_name,
                "library_name": footprint_library,
            },
        )
        return result

    @mcp.tool()
    async def lib_link_3d_model(
        component_name: str,
        model_path: str,
        offset_x: float = 0,
        offset_y: float = 0,
        offset_z: float = 0,
        rotation_x: float = 0,
        rotation_y: float = 0,
        rotation_z: float = 0,
    ) -> dict[str, Any]:
        """Link a 3D model to a footprint.

        NOTE: offset and rotation parameters are currently ignored by Altium —
        set them manually in the library after linking.

        Args:
            component_name: Name of the footprint
            model_path: Path to the 3D model file (.step, .stp)
            offset_x: X offset in mils (ignored — see note)
            offset_y: Y offset in mils (ignored — see note)
            offset_z: Z offset in mils (ignored — see note)
            rotation_x: X rotation in degrees (ignored — see note)
            rotation_y: Y rotation in degrees (ignored — see note)
            rotation_z: Z rotation in degrees (ignored — see note)

        Returns:
            Dictionary confirming link
        """
        bridge = get_bridge()
        result = await bridge.send_command_async(
            "library.link_3d_model",
            {
                "component_name": component_name,
                "model_path": model_path,
                "offset_x": offset_x,
                "offset_y": offset_y,
                "offset_z": offset_z,
                "rotation_x": rotation_x,
                "rotation_y": rotation_y,
                "rotation_z": rotation_z,
            },
        )
        return result

    # =========================================================================
    # Library Search and Information
    # =========================================================================

    @mcp.tool()
    async def lib_get_components(library_path: Optional[str] = None) -> dict[str, Any]:
        """Get all components in a library.

        Args:
            library_path: Path to library (uses active library if not specified)

        Returns:
            Dictionary with "count" and "components" list
        """
        bridge = get_bridge()
        params = {}
        if library_path:
            params["library_path"] = library_path
        result = await bridge.send_command_async("library.get_components", params)
        return result or {}

    @mcp.tool()
    async def lib_search(
        query: str,
        search_type: str = "all",
    ) -> dict[str, Any]:
        """Search installed libraries for components.

        DATASHEET DISCIPLINE: Matches carry `_datasheet_guidance`.
        Before recommending any matched part as a replacement or
        answer, fetch its datasheet (WebSearch + WebFetch). Do not
        recommend based on symbol metadata alone.

        Args:
            query: Search query string
            search_type: What to search ("all", "name", "description", "parameters")

        Returns:
            Dict with matched components plus `_datasheet_guidance` +
            `_datasheet_parts`.
        """
        bridge = get_bridge()
        result = await bridge.send_command_async(
            "library.search", {"query": query, "search_type": search_type}
        )
        if isinstance(result, list):
            result = {"results": result}
        if isinstance(result, dict):
            synthetic = {"components": (
                result.get("results") or result.get("components") or []
            )}
            return tag_response(
                result, components=synthetic, context="lib_search"
            )
        return result

    @mcp.tool()
    async def lib_get_component_details(
        component_name: str,
        library_path: str,
    ) -> dict[str, Any]:
        """Get detailed information about a library component.

        NOTE: Uses the focused library document, not library_path. Open the
        target library in Altium before calling.

        Args:
            component_name: Name of the component
            library_path: Path to the library (currently ignored — see note)

        Returns:
            Dictionary with full component details. Includes ``part_count``
            (number of functional parts; 1 for ordinary symbols, >1 for
            multi-part symbols like quad op-amps).
        """
        bridge = get_bridge()
        result = await bridge.send_command_async(
            "library.get_component_details",
            {"component_name": component_name, "library_path": library_path},
        )
        return result

    @mcp.tool()
    async def lib_batch_set_params(
        assignments: list[dict[str, str]],
        library_path: Optional[str] = None,
    ) -> dict[str, Any]:
        """Batch set parameters on library components.

        Each assignment sets one parameter on one component.
        If the parameter exists it is updated; if not it is created.

        Args:
            assignments: List of dicts with keys:
                - component_name: Name of the component in the library
                - param_name: Parameter name (e.g., "Partnumber", "Manufacturer")
                - param_value: Value to set
            library_path: Path to library (uses active library if not specified)

        Returns:
            Dictionary with counts of updated, created, and failed assignments
        """
        config = get_config()
        config.ensure_workspace()
        batch_path = config.workspace_dir / "batch_params.txt"

        # Validate keys and values before writing
        required_keys = {"component_name", "param_name", "param_value"}
        for i, a in enumerate(assignments):
            missing = required_keys - set(a.keys())
            if missing:
                raise InvalidParameterError(
                    f"Assignment {i} is missing required keys: {', '.join(sorted(missing))}"
                )
            for key in required_keys:
                if "|" in str(a[key]):
                    raise InvalidParameterError(
                        f"Assignment {i}: '{key}' value contains pipe character '|' which would corrupt the batch file"
                    )

        with open(batch_path, "w", encoding="latin-1") as f:
            for a in assignments:
                f.write(f"{a['component_name']}|{a['param_name']}|{a['param_value']}\n")

        bridge = get_bridge()
        params = {"batch_file": str(batch_path)}
        if library_path:
            params["library_path"] = library_path
        result = await bridge.send_command_async(
            "library.batch_set_params", params, timeout=120.0
        )
        return result

    @mcp.tool()
    async def lib_batch_rename(
        assignments: list[dict[str, str]],
        library_path: Optional[str] = None,
    ) -> dict[str, Any]:
        """Batch rename components in a schematic library.

        Each assignment renames one component from old_name to new_name.

        Args:
            assignments: List of dicts with keys:
                - old_name: Current name of the component in the library
                - new_name: New name for the component
            library_path: Path to library (uses active library if not specified)

        Returns:
            Dictionary with counts of renamed and failed assignments
        """
        config = get_config()
        config.ensure_workspace()
        batch_path = config.workspace_dir / "batch_rename.txt"

        # Validate keys and values before writing
        required_keys = {"old_name", "new_name"}
        for i, a in enumerate(assignments):
            missing = required_keys - set(a.keys())
            if missing:
                raise InvalidParameterError(
                    f"Assignment {i} is missing required keys: {', '.join(sorted(missing))}"
                )
            for key in required_keys:
                if "|" in str(a[key]):
                    raise InvalidParameterError(
                        f"Assignment {i}: '{key}' value contains pipe character '|' which would corrupt the batch file"
                    )

        with open(batch_path, "w", encoding="latin-1") as f:
            for a in assignments:
                f.write(f"{a['old_name']}|{a['new_name']}\n")

        bridge = get_bridge()
        params = {"batch_file": str(batch_path)}
        if library_path:
            params["library_path"] = library_path
        result = await bridge.send_command_async(
            "library.batch_rename", params, timeout=120.0
        )
        return result

    @mcp.tool()
    async def lib_diff_libraries(
        library_a: str,
        library_b: str,
    ) -> dict[str, Any]:
        """Compare two schematic libraries and report differences.

        Returns which components are only in library A, only in B, or shared.

        Args:
            library_a: Full path to the first SchLib file
            library_b: Full path to the second SchLib file

        Returns:
            Dictionary with only_in_a, only_in_b, common arrays,
            and count_a, count_b, only_a, only_b, shared counts
        """
        bridge = get_bridge()
        result = await bridge.send_command_async(
            "library.diff_libraries",
            {"library_a": library_a, "library_b": library_b},
            timeout=60.0,
        )
        return result

    @mcp.tool()
    async def lib_add_symbol_arc(
        x_center: int,
        y_center: int,
        radius: int,
        start_angle: float = 0,
        end_angle: float = 360,
        width: int = 1,
        owner_part_id: int = 1,
    ) -> dict[str, Any]:
        """Add an arc to the current library symbol.

        Args:
            x_center: Center X coordinate in mils
            y_center: Center Y coordinate in mils
            radius: Arc radius in mils
            start_angle: Start angle in degrees (0 = right, 90 = up)
            end_angle: End angle in degrees
            width: Line width (0=zero, 1=small, 2=medium, 3=large)
            owner_part_id: Multi-part owner. 1..N picks the part; 0 marks
                the arc as shared across all parts. Default 1.

        Returns:
            Dictionary confirming arc addition
        """
        if owner_part_id < 0:
            raise InvalidParameterError("owner_part_id must be >= 0 (0 = shared)")
        bridge = get_bridge()
        result = await bridge.send_command_async(
            "library.add_symbol_arc",
            {
                "x_center": x_center,
                "y_center": y_center,
                "radius": radius,
                "start_angle": start_angle,
                "end_angle": end_angle,
                "width": width,
                "owner_part_id": owner_part_id,
            },
        )
        return result

    @mcp.tool()
    async def lib_add_symbol_polygon(
        vertices: str,
        owner_part_id: int = 1,
    ) -> dict[str, Any]:
        """Add a polygon (filled shape) to the current library symbol.

        Args:
            vertices: Comma-separated x,y coordinate pairs in mils.
                Example: "0,0,100,0,100,100,0,100" creates a square with
                vertices at (0,0), (100,0), (100,100), (0,100).
                Minimum 3 vertices (6 values) required.
            owner_part_id: Multi-part owner. 1..N picks the part; 0 marks
                the polygon as shared across all parts. Default 1.

        Returns:
            Dictionary confirming polygon addition with vertex count
        """
        if owner_part_id < 0:
            raise InvalidParameterError("owner_part_id must be >= 0 (0 = shared)")
        bridge = get_bridge()
        result = await bridge.send_command_async(
            "library.add_symbol_polygon",
            {"vertices": vertices, "owner_part_id": owner_part_id},
        )
        return result

    @mcp.tool()
    async def lib_set_component_description(
        component_name: str,
        description: str,
    ) -> dict[str, Any]:
        """Set the description field on a library component.

        Args:
            component_name: Name of the component in the active library
            description: New description text

        Returns:
            Dictionary confirming the description was set
        """
        bridge = get_bridge()
        result = await bridge.send_command_async(
            "library.set_component_description",
            {"component_name": component_name, "description": description},
        )
        return result

    @mcp.tool()
    async def lib_get_pin_list() -> dict[str, Any]:
        """Get all pins of the current library component.

        Returns:
            Dictionary with "count", "component" name, "part_count" (total
            functional parts in the component — 1 for ordinary symbols),
            and "pins" array. Each pin has: designator, name,
            electrical_type, x, y, orientation, hidden, owner_part_id
            (1..N picks which part the pin belongs to; 0 means shared
            across all parts).
        """
        bridge = get_bridge()
        result = await bridge.send_command_async(
            "library.get_pin_list", {}
        )
        return result

    @mcp.tool()
    async def lib_copy_component(
        source_name: str,
        new_name: str,
    ) -> dict[str, Any]:
        """Duplicate a component within the same schematic library.

        Creates a deep copy of the source component (including all pins,
        graphics, and parameters) and adds it to the library with the
        new name. The new component becomes the active component.

        Args:
            source_name: Name of the existing component to copy
            new_name: Name for the new component (must not already exist)

        Returns:
            Dictionary confirming the copy with source and new_name
        """
        bridge = get_bridge()
        result = await bridge.send_command_async(
            "library.copy_component",
            {"source_name": source_name, "new_name": new_name},
        )
        return result

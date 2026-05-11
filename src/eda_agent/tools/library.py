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

        IMPORTANT — for any footprint with more than ~5 pads, prefer
        ``lib_add_footprint_pads`` (batch). A 144-ball BGA built one pad
        at a time is 144 LLM turns; with the batch tool it's one turn
        plus one PreProcess/PostProcess + one save.

        Args:
            designator: Pad designator — a single package-pad identifier
                (e.g., "1", "2", "M11", "A4"). Comma-separated alias
                strings ("A4,A6,B1") are REJECTED: each footprint pad
                must map 1:1 to exactly one schematic pin.
            x: X coordinate in mils
            y: Y coordinate in mils
            x_size: Pad X size in mils
            y_size: Pad Y size in mils
            hole_size: Drill hole size in mils (0 for SMD)
            shape: Pad shape ("round", "rectangular", "octagonal")
            layer: Layer for SMD pads — "TopLayer" (default) or
                "BottomLayer". Through-hole pads (hole_size > 0) are
                automatically placed on MultiLayer regardless of this
                value.
            rotation: Pad rotation in degrees

        Returns:
            Dictionary confirming pad addition
        """
        designator = _validate_pin_designator(
            designator, context=f"footprint pad"
        )
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
    async def lib_add_footprint_pads(
        pads: list[dict[str, Any]],
    ) -> dict[str, Any]:
        """Add MANY pads to the current footprint in ONE call.

        PREFER THIS over looping ``lib_add_footprint_pad``. A 144-ball
        BGA placed one pad at a time is 144 LLM turns; with this tool
        it's one turn + one PreProcess/PostProcess + one save.

        Args:
            pads: List of pad dicts, each with:
                - designator (str, required) — single package-pad
                  identifier (e.g., "1", "M11", "A4"). Multi-pin alias
                  strings like "A4,A6,B1" are REJECTED: each footprint
                  pad must map 1:1 to exactly one schematic pin. For
                  shared-net groups, emit one pad per package ball with
                  unique designators.
                - x, y       (int, mils) — pad center
                - x_size, y_size (int, mils, default 60)
                - hole_size  (int, mils, default 0 = SMD; >0 = TH)
                - shape      (str, default "rectangular") — round /
                  rectangular / octagonal
                - layer      (str, default "TopLayer") — "TopLayer" or
                  "BottomLayer" for SMD pads. Through-hole pads
                  (hole_size > 0) automatically use MultiLayer.
                - rotation   (float, default 0) — degrees

        Example — 3-pin SOT-23::

            lib_add_footprint_pads(pads=[
                {"designator": "1", "x":  -38, "y":  -47, "x_size": 28, "y_size": 24},
                {"designator": "2", "x":  -38, "y":   47, "x_size": 28, "y_size": 24},
                {"designator": "3", "x":   38, "y":    0, "x_size": 28, "y_size": 24},
            ])

        Returns:
            Dict with added, failed, total counts.
        """
        # Direct port of coffeenmusic/altium-mcp's pad input format:
        #   "designator|xmm|ymm|wmm|hmm|shape"
        # joined by "~~" across pads. Convert any mil-based input to mm
        # since the .pas side uses MMsToCoord (matching reference verbatim).
        MILS_PER_MM = 1000.0 / 25.4

        def _to_mm(p: dict, key_mm: str, key_mils: str, default: float = 0.0) -> float:
            if key_mm in p:
                return float(p[key_mm])
            if key_mils in p:
                return float(p[key_mils]) / MILS_PER_MM
            return default

        def _shape_token(p: dict) -> str:
            raw = str(p.get("shape", "rectangular")).lower()
            if raw in ("round", "circle"):
                return "Round"
            if raw in ("oval", "obround", "rounded_rect"):
                return "Oval"
            return "Rect"

        op_strs: list[str] = []
        for idx, p in enumerate(pads):
            desig = _validate_pin_designator(
                p.get("designator", ""),
                context=f"pads[{idx}]",
            )
            xmm = _to_mm(p, "x_mm", "x")
            ymm = _to_mm(p, "y_mm", "y")
            wmm = _to_mm(p, "x_size_mm", "x_size", default=0.6)
            hmm = _to_mm(p, "y_size_mm", "y_size", default=0.6)
            shape = _shape_token(p)
            op_strs.append(f"{desig}|{xmm:g}|{ymm:g}|{wmm:g}|{hmm:g}|{shape}")

        if not op_strs:
            return {"error": "No pads provided", "added": 0}

        bridge = get_bridge()
        return await bridge.send_command_async(
            "library.add_footprint_pads",
            {"pads": "~~".join(op_strs)},
        )

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
    async def lib_create_pcb_footprint(
        name: str,
        pads: list[dict[str, Any]],
        description: str = "",
        body_x_mm: float = 0.0,
        body_y_mm: float = 0.0,
        courtyard_excess_mm: float = 0.25,
    ) -> dict[str, Any]:
        """Create a PcbLib footprint atomically — pads + body outline +
        courtyard + assembly + silkscreen + pin-1 marker + designator text.

        Single atomic .pas call holds the IPCB_Component reference stable
        through the entire operation, avoiding the stale-reference bug
        that hits when creation and pad-population are split across two
        MCP calls.

        Geometry per IPC-7351 convention:
          - Silkscreen body outline drawn AT body edge (Top Overlay).
          - Assembly outline drawn AT body edge (Top Assembly / Mech 13).
          - Courtyard drawn at body + ``courtyard_excess_mm`` on each side.
          - Pad-center to silk distance therefore matches datasheet
            "ball center to body edge" exactly (no inset offset error).

        Args:
            name: Footprint name (e.g. "BGA144C80P12X12_1000X1000X170").
            pads: List of pad dicts. Each dict supports either mm-based
                fields ``x_mm`` / ``y_mm`` / ``x_size_mm`` / ``y_size_mm``
                OR mil-based ``x`` / ``y`` / ``x_size`` / ``y_size``
                (the wrapper auto-converts mils → mm). Required key:
                ``designator`` (single package-pad identifier — the 1:1
                pin-to-pad validator runs here too). Optional ``shape``:
                ``"round"`` (default for SMD circles), ``"oval"``,
                ``"rectangular"``.
            description: Footprint description shown in the library panel.
            body_x_mm: Full body width in mm (the package's outer
                dimension from the datasheet outline drawing). Silk and
                assembly outlines draw at this size. 0 = auto-fit body
                to pad bounding box plus a small margin.
            body_y_mm: Full body height in mm. 0 = auto.
            courtyard_excess_mm: IPC clearance added beyond body for the
                courtyard outline. Default 0.25 mm (Nominal density).
                Use 0.50 for Most density (wave-solder), 0.10 for Least
                (handheld / fine-pitch BGA).

        Returns:
            Dict with success, footprint_name, pad_count, total,
            body_width_mm, body_height_mm, courtyard_width_mm,
            courtyard_height_mm.
        """
        if not pads:
            raise InvalidParameterError("pads must contain at least one entry")

        MILS_PER_MM = 1000.0 / 25.4

        def _to_mm(p: dict, key_mm: str, key_mils: str, default: float = 0.0) -> float:
            if key_mm in p:
                return float(p[key_mm])
            if key_mils in p:
                return float(p[key_mils]) / MILS_PER_MM
            return default

        def _shape_token(p: dict) -> str:
            raw = str(p.get("shape", "round")).lower()
            if raw in ("round", "circle"):
                return "Round"
            if raw in ("oval", "obround", "rounded_rect"):
                return "Oval"
            return "Rect"

        op_strs: list[str] = []
        for idx, p in enumerate(pads):
            desig = _validate_pin_designator(
                p.get("designator", ""),
                context=f"pads[{idx}]",
            )
            xmm = _to_mm(p, "x_mm", "x")
            ymm = _to_mm(p, "y_mm", "y")
            wmm = _to_mm(p, "x_size_mm", "x_size", default=0.6)
            hmm = _to_mm(p, "y_size_mm", "y_size", default=0.6)
            shape = _shape_token(p)
            op_strs.append(f"{desig}|{xmm:g}|{ymm:g}|{wmm:g}|{hmm:g}|{shape}")

        bridge = get_bridge()
        return await bridge.send_command_async(
            "library.create_pcb_footprint",
            {
                "name": name,
                "description": description,
                "pads": "~~".join(op_strs),
                "body_x_mm": body_x_mm,
                "body_y_mm": body_y_mm,
                "courtyard_excess_mm": courtyard_excess_mm,
            },
        )

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
            footprint_library: Full path or filename of the .PcbLib that
                contains the footprint. When provided, an explicit datafile
                link is written so the SchLib editor's preview pane can
                render the footprint thumbnail without a parent .LibPkg
                project. Leave empty to rely on Available Libraries / open
                PcbLibs / a parent LibPkg for resolution.

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

    @mcp.tool()
    async def lib_position_3d_body(
        target_x_mm: float = 0.0,
        target_y_mm: float = 0.0,
    ) -> dict[str, Any]:
        """Center every 3D body on the active footprint at (target_x, target_y).

        Use this after manually placing a 3D body via Altium's
        ``Place → 3D Body → Embed STEP`` UI when the body lands off-origin.
        Reads each body's bounding rectangle and moves the centroid to
        the requested target. Default (0, 0) puts the body on the
        footprint origin (where the pads sit).

        ROTATION NOTE: The `rotation_z_deg` parameter has been removed
        because `Model.SetState` rotates around the model's local origin
        (not the body's anchor), causing translation that's hard to
        compensate for across repeated calls. For rotation, use
        Altium's UI: click the 3D body → F11 → Properties → set Z
        rotation directly. Altium's own rotation logic handles this
        correctly without translation drift.

        Args:
            target_x_mm: Target X for the body centroid, in mm. Default 0.
            target_y_mm: Target Y for the body centroid, in mm. Default 0.

        Returns:
            Dictionary with ``moved`` (number of bodies recentered) and
            the target coordinates.
        """
        bridge = get_bridge()
        result = await bridge.send_command_async(
            "library.position_3d_body",
            {
                "target_x_mm": target_x_mm,
                "target_y_mm": target_y_mm,
                "rotation_z_deg": 0,     # leave rotation alone
                "skip_move": "false",
            },
        )
        return result

    @mcp.tool()
    async def lib_screenshot_footprint(output_path: str) -> dict[str, Any]:
        """Capture the current PcbLib editor view (2D or 3D) to a PNG.

        Implementation: uses Win32 GDI BitBlt against the Altium window
        (pattern from coffeenmusic/altium-mcp). The DelphiScript broker
        approach didn't work on this build; Python-side capture is more
        reliable since it bypasses Altium's own export pipeline.

        Whatever mode the PcbLib editor is currently in (2D or 3D) is what
        gets captured. To inspect 3D body orientation, switch to 3D mode in
        Altium first (press 3) before calling this.

        Args:
            output_path: Absolute path where the PNG should be written
                (e.g., ``C:/temp/ad9361_3d.png``).

        Returns:
            Dictionary with the output path and window dimensions on success.
        """
        # First, make sure the PcbLib doc is focused so we capture the right view.
        bridge = get_bridge()
        try:
            await bridge.send_command_async("library.screenshot_footprint", {"output_path": output_path})
        except Exception:
            pass  # The .pas-side broker is best-effort; we capture from Python regardless.

        try:
            import win32gui
            import win32ui
            import win32con
            from PIL import Image
        except ImportError as e:
            return {
                "success": False,
                "error": f"Missing dependency: {e}. Install with: pip install pywin32 Pillow",
            }

        # Find the Altium main window. Match on "Altium Designer" in the title.
        altium_windows = []
        altium_fallback = []

        def _collect(hwnd, _):
            if not win32gui.IsWindowVisible(hwnd):
                return True
            title = win32gui.GetWindowText(hwnd)
            if "Altium" in title and (".PcbLib" in title or ".PrjPcb" in title or ".PcbDoc" in title):
                altium_windows.append((hwnd, title))
            elif "Altium" in title:
                altium_fallback.append((hwnd, title))
            return True

        win32gui.EnumWindows(_collect, 0)
        candidates = altium_windows or altium_fallback
        if not candidates:
            return {"success": False, "error": "No Altium window found"}

        hwnd, title = candidates[0]
        left, top, right, bottom = win32gui.GetWindowRect(hwnd)
        w, h = right - left, bottom - top
        if w <= 0 or h <= 0:
            return {"success": False, "error": f"Bad window dims {w}x{h}"}

        # Bring it forward so we capture the actual rendered content (not occluded).
        try:
            win32gui.SetForegroundWindow(hwnd)
        except Exception:
            pass  # foreground change can fail under various Win32 focus rules; carry on.

        import time
        time.sleep(0.3)  # let the WM repaint after focus change

        # GDI BitBlt the window contents into a bitmap, then PIL it out.
        hwndDC = win32gui.GetWindowDC(hwnd)
        try:
            mfcDC = win32ui.CreateDCFromHandle(hwndDC)
            saveDC = mfcDC.CreateCompatibleDC()
            bmp = win32ui.CreateBitmap()
            bmp.CreateCompatibleBitmap(mfcDC, w, h)
            saveDC.SelectObject(bmp)
            saveDC.BitBlt((0, 0), (w, h), mfcDC, (0, 0), win32con.SRCCOPY)

            info = bmp.GetInfo()
            bits = bmp.GetBitmapBits(True)
            img = Image.frombuffer(
                "RGB",
                (info["bmWidth"], info["bmHeight"]),
                bits, "raw", "BGRX", 0, 1,
            )

            from pathlib import Path
            out = Path(output_path)
            out.parent.mkdir(parents=True, exist_ok=True)
            img.save(str(out), "PNG")

            return {
                "success": True,
                "output_path": str(out),
                "width": w,
                "height": h,
                "window_title": title,
            }
        finally:
            try: win32gui.DeleteObject(bmp.GetHandle())
            except Exception: pass
            try: saveDC.DeleteDC()
            except Exception: pass
            try: mfcDC.DeleteDC()
            except Exception: pass
            try: win32gui.ReleaseDC(hwnd, hwndDC)
            except Exception: pass

    @mcp.tool()
    async def lib_diag_footprint() -> dict[str, Any]:
        """Diagnostic: list 3D bodies on the active PcbLib footprint.

        Returns the body count, identifier, layer, and a has_model flag
        for each ``IPCB_ComponentBody`` primitive on the focused
        footprint. Use to debug "body was added but invisible" — tells
        you whether the STEP actually loaded into Body.Model and which
        layer the body landed on.

        Returns:
            Dictionary with ``body_count``, ``total_primitives``, and
            a ``bodies`` array.
        """
        bridge = get_bridge()
        result = await bridge.send_command_async("library.diag_footprint", {})
        return result

    @mcp.tool()
    async def lib_add_3d_body(
        model_path: str,
        offset_x_mm: float = 0.0,
        offset_y_mm: float = 0.0,
        rot_z_deg: float = 0.0,
        standoff_mm: float = 0.0,
        overall_height_mm: float = 0.0,
        mech_layer: int = 1,
    ) -> dict[str, Any]:
        """Embed a STEP / 3D model as a Component Body on the active PcbLib footprint.

        Operates on the focused footprint in the PCB library editor. Open
        the target footprint in the PcbLib panel before calling. The body
        is anchored at the footprint origin and inherits the part's overall
        rotation when placed on a board.

        Unlike `lib_link_3d_model` (which adds a schematic-side reference
        only), this writes the actual 3D primitive into the footprint, so
        every placed instance carries the geometry automatically.

        Args:
            model_path: Absolute path to the STEP / .stp / .step file.
            offset_x_mm: X offset of the model relative to footprint origin (mm).
            offset_y_mm: Y offset of the model relative to footprint origin (mm).
            rot_z_deg: Rotation around Z axis (degrees) — typical knob to align
                the imported model with the pad layout.
            standoff_mm: Body standoff height above the board (mm). 0 for typical
                surface-mount; > 0 for parts on plastic standoffs.
            overall_height_mm: Optional explicit body overall height (mm) for
                3D-collision DRC. Leave 0 to use the value from the STEP.
            mech_layer: Mechanical layer number to place the body on. The
                3D-rendering engine reads bodies from whichever mechanical
                layer is configured as the "Top 3D Body" component-layer
                pair in the library's Layer Stack Manager. Default 1
                (Altium's global default). Some templates use 2 (commonly
                paired with M3 for the bottom). Look at View Configuration
                → Component Layer Pairs to find the right one for your lib.

        Returns:
            Dictionary confirming the body was attached.
        """
        bridge = get_bridge()
        result = await bridge.send_command_async(
            "library.add_3d_body",
            {
                "model_path": model_path,
                "offset_x_mm": offset_x_mm,
                "offset_y_mm": offset_y_mm,
                "rot_z_deg": rot_z_deg,
                "standoff_mm": standoff_mm,
                "overall_height_mm": overall_height_mm,
                "mech_layer": mech_layer,
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
    async def lib_create_multipart_symbol(
        name: str,
        parts: list[dict[str, Any]],
        designator_prefix: str = "U",
        description: str = "",
        shared_pins: Optional[list[dict[str, Any]]] = None,
    ) -> dict[str, Any]:
        """Create a multi-part schematic symbol end-to-end in one call.

        Use this for components like quad op-amps, dual gates, or complex
        chips like the AD9361 that are split into functional blocks
        (e.g., RF / baseband / power). Each entry in ``parts`` becomes one
        functional unit that auto-suffixes when placed (U1A, U1B, ...).

        This is a Python orchestrator that delegates to the lower-level
        building blocks: ``lib_create_symbol`` (with ``part_count``), then
        per-part body + pin placements, then a final batch for shared pins.
        It does NOT auto-layout — you provide all coordinates in mils. For
        rectangle-body chips with auto-layout, prefer ``lib_create_ic_symbol``.

        ====== 1:1 pin-to-pad mapping (HARD RULE) ======

        Every pin entry in ``parts[i]["pins"]`` and ``shared_pins`` must
        have a SINGLE package-pad designator. Multi-pin alias strings
        like ``"A4,A6,B1"`` (sometimes used to fold ground/power balls
        onto one symbol pin) are REJECTED — the validator will raise
        ``InvalidParameterError``. For BGAs / large packages where many
        balls share a net (28× VSSA on a 144-ball BGA, 50× GND on a
        484-ball Zynq, etc.), emit one pin per ball with the same name
        and unique BGA-coordinate designators. This keeps schematic and
        footprint pin counts in sync — the 1:1 invariant is the only
        thing that lets ECO, BOM, and pick-and-place stay coherent.

        Args:
            name: Component name (e.g., "LM324", "AD9361").
            parts: One dict per functional part. Each dict supports:
                - ``body`` (optional): the part's outline. Accepts either:
                  * a single dict — short form for a rectangle:
                    ``{"x1": int, "y1": int, "x2": int, "y2": int}``
                  * a list of shape dicts, each with a ``kind`` field
                    (``"rect"`` / ``"line"`` / ``"arc"`` / ``"polygon"``)
                    plus that shape's parameters (same as the matching
                    ``lib_add_symbol_*`` tool). Use the list form to draw
                    op-amp triangles, gate symbols, or any multi-shape body.
                  All coordinates are in mils. Skip if you don't want a body.
                - ``pins`` (required): list of pin dicts in the same shape
                  ``lib_add_pins`` accepts (designator/name/x/y/length/
                  rotation/electrical_type/hidden). ``owner_part_id`` is
                  set automatically to this part's index — do NOT include it.
            designator_prefix: Default designator prefix. "U" for ICs.
            description: Component description (visible in the library panel).
            shared_pins: Pins that appear on every part (e.g., VCC, GND on
                a quad op-amp). Same dict shape as ``parts[i]["pins"]``.
                Each is created with ``owner_part_id=0`` (Altium's "shared
                across all parts" sentinel). Pass ``None`` or ``[]`` for
                components with no shared pins.

        Returns:
            Dict with::
                {"success": True,
                 "name": ..., "part_count": N,
                 "parts": [{"index": 1, "body": "ok"|"skipped",
                            "pins_added": k, "pins_failed": 0}, ...],
                 "shared_pins_added": int}
            Or, on early failure, the error dict from the underlying call.

        Example — LM324 quad op-amp:
            lib_create_multipart_symbol(
                name="LM324",
                description="Quad low-power op-amp",
                parts=[
                    {
                        "body": {"x1": -200, "y1": -200, "x2": 200, "y2": 200},
                        "pins": [
                            {"designator": "1", "name": "OUT_A",
                             "x": 200, "y": 0, "electrical_type": "output"},
                            {"designator": "2", "name": "IN_A-",
                             "x": -200, "y": 100, "electrical_type": "input"},
                            {"designator": "3", "name": "IN_A+",
                             "x": -200, "y": -100, "electrical_type": "input"},
                        ],
                    },
                    # ... parts B/C/D in the same shape
                ],
                shared_pins=[
                    {"designator": "4",  "name": "V+",
                     "x": 0, "y": 300, "electrical_type": "power"},
                    {"designator": "11", "name": "V-",
                     "x": 0, "y": -300, "electrical_type": "power"},
                ],
            )
        """
        if not parts:
            raise InvalidParameterError("parts must contain at least one entry")
        for i, part in enumerate(parts, start=1):
            if not isinstance(part, dict):
                raise InvalidParameterError(f"parts[{i-1}] must be a dict")
            if "pins" not in part or not part["pins"]:
                raise InvalidParameterError(
                    f"parts[{i-1}] is missing required 'pins' list"
                )

        part_count = len(parts)
        bridge = get_bridge()

        create_result = await bridge.send_command_async(
            "library.create_symbol",
            {
                "name": name,
                "designator_prefix": designator_prefix,
                "description": description,
                "part_count": part_count,
            },
        )
        if not isinstance(create_result, dict) or not create_result.get("success"):
            return create_result

        per_part_results: list[dict[str, Any]] = []

        for index, part in enumerate(parts, start=1):
            body_spec = part.get("body")
            if body_spec is None:
                shapes: list[dict[str, Any]] = []
            elif isinstance(body_spec, dict):
                shapes = [body_spec]
            elif isinstance(body_spec, list):
                shapes = list(body_spec)
            else:
                raise InvalidParameterError(
                    f"parts[{index-1}]['body'] must be dict or list, got {type(body_spec).__name__}"
                )

            body_ok = 0
            body_failed = 0
            for shape in shapes:
                kind = shape.get("kind", "rect")
                if kind == "rect":
                    payload = {
                        "x1": int(shape.get("x1", 0)),
                        "y1": int(shape.get("y1", 0)),
                        "x2": int(shape.get("x2", 0)),
                        "y2": int(shape.get("y2", 0)),
                        # Default to standard Altium cream-yellow body fill
                        # (TColor $00B0FFFF). Pass fill_color=-1 for no fill.
                        "fill_color": int(shape.get("fill_color", 11599871)),
                        "border_color": int(shape.get("border_color", 0)),
                        "owner_part_id": index,
                    }
                    cmd = "library.add_symbol_rectangle"
                elif kind == "line":
                    payload = {
                        "x1": int(shape.get("x1", 0)),
                        "y1": int(shape.get("y1", 0)),
                        "x2": int(shape.get("x2", 0)),
                        "y2": int(shape.get("y2", 0)),
                        "width": int(shape.get("width", 1)),
                        "owner_part_id": index,
                    }
                    cmd = "library.add_symbol_line"
                elif kind == "arc":
                    payload = {
                        "x_center": int(shape.get("x_center", 0)),
                        "y_center": int(shape.get("y_center", 0)),
                        "radius": int(shape.get("radius", 100)),
                        "start_angle": shape.get("start_angle", 0),
                        "end_angle": shape.get("end_angle", 360),
                        "width": int(shape.get("width", 1)),
                        "owner_part_id": index,
                    }
                    cmd = "library.add_symbol_arc"
                elif kind == "polygon":
                    vertices = shape.get("vertices", "")
                    if not vertices:
                        raise InvalidParameterError(
                            f"parts[{index-1}] polygon shape needs 'vertices' (comma-separated x,y pairs)"
                        )
                    payload = {
                        "vertices": vertices,
                        "owner_part_id": index,
                    }
                    cmd = "library.add_symbol_polygon"
                else:
                    raise InvalidParameterError(
                        f"parts[{index-1}] unknown shape kind {kind!r} "
                        f"(expected rect / line / arc / polygon)"
                    )
                shape_result = await bridge.send_command_async(cmd, payload)
                if isinstance(shape_result, dict) and shape_result.get("success"):
                    body_ok += 1
                else:
                    body_failed += 1

            if not shapes:
                body_status = "skipped"
            elif body_failed == 0:
                body_status = f"{body_ok} ok"
            else:
                body_status = f"{body_ok} ok, {body_failed} failed"

            op_strs: list[str] = []
            for pin_idx, p in enumerate(part["pins"]):
                pname = str(p.get('name', '')).strip()
                desig = _validate_pin_designator(
                    p.get("designator", ""),
                    context=f"parts[{index-1}].pins[{pin_idx}] (name={pname!r})",
                )
                fields = [
                    f"designator={desig}",
                    f"name={pname}",
                    f"x={int(p.get('x', 0))}",
                    f"y={int(p.get('y', 0))}",
                    f"length={int(p.get('length', 200))}",
                    f"rotation={int(p.get('rotation', 0))}",
                    f"electrical_type={p.get('electrical_type', 'passive')}",
                    f"hidden={'true' if p.get('hidden') else 'false'}",
                ]
                op_strs.append(";".join(fields))

            pins_added = 0
            pins_failed = 0
            if op_strs:
                pins_result = await bridge.send_command_async(
                    "library.add_pins",
                    {
                        "pins": "~~".join(op_strs),
                        "default_owner_part_id": index,
                    },
                )
                if isinstance(pins_result, dict):
                    pins_added = int(pins_result.get("added", 0))
                    pins_failed = int(pins_result.get("failed", 0))

            per_part_results.append({
                "index": index,
                "body": body_status,
                "pins_added": pins_added,
                "pins_failed": pins_failed,
            })

        shared_added = 0
        if shared_pins:
            op_strs = []
            for sp_idx, p in enumerate(shared_pins):
                pname = str(p.get('name', '')).strip()
                desig = _validate_pin_designator(
                    p.get("designator", ""),
                    context=f"shared_pins[{sp_idx}] (name={pname!r})",
                )
                fields = [
                    f"designator={desig}",
                    f"name={pname}",
                    f"x={int(p.get('x', 0))}",
                    f"y={int(p.get('y', 0))}",
                    f"length={int(p.get('length', 200))}",
                    f"rotation={int(p.get('rotation', 0))}",
                    f"electrical_type={p.get('electrical_type', 'passive')}",
                    f"hidden={'true' if p.get('hidden') else 'false'}",
                ]
                op_strs.append(";".join(fields))
            if op_strs:
                shared_result = await bridge.send_command_async(
                    "library.add_pins",
                    {
                        "pins": "~~".join(op_strs),
                        "default_owner_part_id": 0,
                    },
                )
                if isinstance(shared_result, dict):
                    shared_added = int(shared_result.get("added", 0))

        return {
            "success": True,
            "name": name,
            "part_count": part_count,
            "parts": per_part_results,
            "shared_pins_added": shared_added,
        }

    @mcp.tool()
    async def lib_create_ic_symbol(
        name: str,
        parts: list[dict[str, Any]],
        designator_prefix: str = "U",
        description: str = "",
        pin_length: int = 200,
        pin_spacing: int = 100,
        char_width: int = 55,
        body_padding: int = 200,
    ) -> dict[str, Any]:
        """Create a multi-part rectangular IC symbol with full auto-layout.

        This is the right tool for the canonical chip-symbol pattern: one
        filled rectangle body per functional part, pins on left and right
        sides only, pin NAMES rendered INSIDE the body, pin DESIGNATORS
        (the package pin numbers) rendered OUTSIDE on the wire stub.
        Body width and height are computed automatically from the pin
        counts and the longest pin name on each side. Scales cleanly from
        a 14-pin LM324 to a 1000-pin FPGA — just give it more parts and
        more pins.

        Why this exists separately from ``lib_create_multipart_symbol``:
        the lower-level orchestrator takes explicit pin coordinates and
        body shapes, which is the right API for non-rectangular bodies
        (op-amp triangles, gate symbols, etc.). For rectangle-body chips
        — which is 95% of real components — coordinate math is pure
        boilerplate, and the LLM should just describe the pin lists.

        Pin geometry follows Altium's actual convention (per the official
        Pin Properties documentation): ``Pin.Location`` is the
        non-electrical end (the body-attach point), and the pin extends
        outward from there by ``pin_length`` in the direction set by
        rotation. So body-attach sits exactly on the body edge, the
        electrical tip is one pin-length past the edge, and the pin name
        renders INSIDE the body anchored at the body-attach end. This
        matches the layout of stock Altium symbols and reference designs.

        Args:
            name: Component LibReference (e.g., "AD9361", "XC7Z020CLG484").
            parts: List of part dicts, one per functional unit (placed as
                A/B/C/...). Each part dict has:

                - ``left_pins`` (list, optional): pins on the left side,
                  top-to-bottom. Each entry is either a dict
                  ``{"designator": str, "name": str, "electrical_type":
                  str, "hidden": bool}`` OR ``None`` to insert a visual
                  group separator (one blank row of vertical space, no
                  pin created — use this between functional groups).
                  ``electrical_type`` defaults to ``"passive"``;
                  ``hidden`` defaults to False. ``designator`` MUST be
                  a single package-pad identifier (e.g. ``"1"``,
                  ``"M11"``, ``"A4"``) — comma-separated alias strings
                  like ``"A4,A6,B1"`` are REJECTED by the validator.
                  See "1:1 pin-to-pad mapping" below.
                - ``right_pins`` (list, optional): same format, on right.

                A part must have at least one pin in either side.

            ====== 1:1 pin-to-pad mapping (HARD RULE) ======

            Every entry in ``left_pins`` / ``right_pins`` becomes one
            schematic pin, and that pin maps directly to one footprint
            pad during PCB binding. Multiple package balls served by the
            same net (e.g., 28× VSSA grounds on a 144-ball BGA, 50× GND
            balls on a 484-ball Zynq, 100+ GND balls on a big FPGA) MUST
            be split into individual pin entries — one per ball, each
            with the actual ball-coordinate as its designator and the
            same ``name`` (e.g., ``"GND"``). This makes the symbol
            taller but it is the only correct option: consolidating
            balls onto a single pin via comma-separated designators
            silently breaks annotation, ECO, BOM, and pick-and-place.

            For very large packages (484+ pins) where one giant power
            part would be unwieldy, split power into several parts
            instead — e.g., one part per voltage domain (VCCINT,
            VCCAUX, VCCO_BANK_*, GND), each holding its own balls.
            The 1:1 invariant still holds within each part.
            designator_prefix: Default designator prefix on placement
                (e.g., "U" for ICs, "Q" for transistors). Default "U".
            description: Component description shown in the library panel.
            pin_length: Length of the pin line from body-attach to
                electrical tip, in mils. Default 200 (Altium convention).
            pin_spacing: Vertical spacing between adjacent pin rows in
                mils. Default 100 (Altium grid).
            char_width: Approximate mils per character used to size the
                body width so pin names fit inside without overlapping.
                Default 55 fits Altium's default schematic font; raise
                if you see clipping, lower if the body looks too wide.
            body_padding: Mils added on each side beyond the longest
                names (creates breathing room inside the body). Default 200.

        Returns:
            Same shape as ``lib_create_multipart_symbol``: dict with
            ``success``, ``name``, ``part_count``, ``parts`` (per-part
            body and pin counts), and ``shared_pins_added`` (always 0
            here — power pins live on a dedicated power part).

        Example — minimal 2-part chip with a group separator:

            lib_create_ic_symbol(
                name="DEMO_IC",
                parts=[
                    {  # Part A
                        "left_pins": [
                            {"designator": "1", "name": "IN1",  "electrical_type": "input"},
                            {"designator": "2", "name": "IN2",  "electrical_type": "input"},
                            None,  # whitespace separator
                            {"designator": "3", "name": "EN",   "electrical_type": "input"},
                        ],
                        "right_pins": [
                            {"designator": "4", "name": "OUT",  "electrical_type": "output"},
                        ],
                    },
                    {  # Part B (e.g., power)
                        "left_pins": [
                            {"designator": "5", "name": "VCC",  "electrical_type": "power"},
                        ],
                        "right_pins": [
                            {"designator": "6", "name": "GND",  "electrical_type": "power"},
                        ],
                    },
                ],
            )
        """
        if not parts:
            raise InvalidParameterError("parts must contain at least one entry")
        if pin_length <= 0:
            raise InvalidParameterError("pin_length must be > 0")
        if pin_spacing <= 0:
            raise InvalidParameterError("pin_spacing must be > 0")
        if char_width <= 0:
            raise InvalidParameterError("char_width must be > 0")

        built_parts: list[dict[str, Any]] = []

        for part_idx, part in enumerate(parts, start=1):
            if not isinstance(part, dict):
                raise InvalidParameterError(
                    f"parts[{part_idx-1}] must be a dict"
                )
            left_rows = list(part.get("left_pins") or [])
            right_rows = list(part.get("right_pins") or [])
            if not left_rows and not right_rows:
                raise InvalidParameterError(
                    f"parts[{part_idx-1}] must have at least one pin in left_pins or right_pins"
                )

            # Validate pin entries and compute longest name on each side.
            # Designators are validated through _validate_pin_designator,
            # which enforces the 1-pin-per-pad invariant (rejects multi-pin
            # alias strings like 'A4,A6,B1' that break footprint binding).
            def _max_chars(rows: list[Any], side: str) -> int:
                longest = 0
                for j, r in enumerate(rows):
                    if r is None:
                        continue
                    if not isinstance(r, dict):
                        raise InvalidParameterError(
                            f"parts[{part_idx-1}].{side}[{j}] must be a dict or None (got {type(r).__name__})"
                        )
                    nm = str(r.get("name", "")).strip()
                    if not nm:
                        raise InvalidParameterError(
                            f"parts[{part_idx-1}].{side}[{j}] missing required 'name'"
                        )
                    _validate_pin_designator(
                        r.get("designator", ""),
                        context=f"parts[{part_idx-1}].{side}[{j}] (name={nm!r})",
                    )
                    if len(nm) > longest:
                        longest = len(nm)
                return longest

            max_left_chars = _max_chars(left_rows, "left_pins")
            max_right_chars = _max_chars(right_rows, "right_pins")

            # Auto-size body. Width fits the widest left + right names with
            # padding. Round to 100-mil grid; enforce a sensible minimum.
            raw_w = (max_left_chars + max_right_chars) * char_width + body_padding * 2
            body_w = max(((raw_w + 99) // 100) * 100, 400)
            half_w = body_w // 2

            n_rows = max(len(left_rows), len(right_rows), 1)
            raw_h = n_rows * pin_spacing + body_padding
            body_h = max(((raw_h + 99) // 100) * 100, 300)
            half_h = body_h // 2

            # Top-down y assignment: row 0 at the top, decreasing by spacing.
            top_y = ((n_rows - 1) * pin_spacing) // 2

            pins: list[dict[str, Any]] = []
            for i, row in enumerate(left_rows):
                if row is None:
                    continue
                pins.append({
                    "designator": str(row["designator"]),
                    "name": str(row["name"]),
                    "x": -half_w,           # body-attach AT body's left edge
                    "y": top_y - i * pin_spacing,
                    "length": pin_length,
                    "rotation": 180,        # extends LEFT outward
                    "electrical_type": row.get("electrical_type", "passive"),
                    "hidden": bool(row.get("hidden", False)),
                })
            for i, row in enumerate(right_rows):
                if row is None:
                    continue
                pins.append({
                    "designator": str(row["designator"]),
                    "name": str(row["name"]),
                    "x": half_w,            # body-attach AT body's right edge
                    "y": top_y - i * pin_spacing,
                    "length": pin_length,
                    "rotation": 0,          # extends RIGHT outward
                    "electrical_type": row.get("electrical_type", "passive"),
                    "hidden": bool(row.get("hidden", False)),
                })

            built_parts.append({
                "body": {
                    "x1": -half_w, "y1": -half_h,
                    "x2":  half_w, "y2":  half_h,
                },
                "pins": pins,
            })

        # Delegate to the lower-level orchestrator (it handles
        # create_symbol + per-part body + per-part pin batches).
        return await lib_create_multipart_symbol(
            name=name,
            parts=built_parts,
            designator_prefix=designator_prefix,
            description=description,
            shared_pins=None,
        )

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

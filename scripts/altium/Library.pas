{ SPDX-License-Identifier: Apache-2.0                                   }
{ Copyright (c) 2026 George Saliba                                      }
{..............................................................................}
{ Library.pas - Library management functions for the Altium integration bridge                }
{..............................................................................}

{ Set the part ownership fields on a primitive so the lib editor knows     }
{ which part of the component it belongs to. Per Altium's official         }
{ createcomp_in_lib.pas reference, primitives without OwnerPartId /        }
{ OwnerPartDisplayMode are added to the component's collection but the    }
{ editor can't display them, symbols appear empty.                        }
Procedure SetOwnerPart(Obj : ISch_GraphicalObject; Component : ISch_Component);
Begin
    If Obj = Nil Then Exit;
    If Component <> Nil Then
    Begin
        Try Obj.OwnerPartId := Component.CurrentPartID; Except End;
        Try Obj.OwnerPartDisplayMode := Component.DisplayMode; Except End;
    End
    Else
    Begin
        Try Obj.OwnerPartId := 1; Except End;
        Try Obj.OwnerPartDisplayMode := 0; Except End;
    End;
End;

{ Resolve the target component for a Lib_Add* primitive helper.             }
{                                                                              }
{ SchLib.CurrentSchComponent in DelphiScript reflects the editor's selected }
{ component, which doesn't update when we add a new component via           }
{ AddSchComponent (the setter is a no-op). Trusting it would attach        }
{ primitives to whatever the editor was showing first (usually the default  }
{ Component_1 placeholder), leaving every newly-created symbol empty.       }
{                                                                              }
{ Use the global LastCreatedLibComponent we set in Lib_CreateSymbol         }
{ instead, falling back to CurrentSchComponent only if nothing has been     }
{ created in this session.                                                  }
Function GetTargetLibComponent(SchLib : ISch_Lib) : ISch_Component;
Begin
    Result := LastCreatedLibComponent;
    If Result = Nil Then
    Begin
        If SchLib <> Nil Then
            Result := SchLib.CurrentSchComponent;
    End;
End;

{ Mark the focused SchLib doc dirty without an immediate full-file save.    }
{ DoFileSave on a multi-MB SchLib costs hundreds of milliseconds to seconds }
{ per call, so doing it from every singular mutation (lib_add_pin,          }
{ lib_set_component_description, lib_link_footprint, ...) made one-symbol-  }
{ at-a-time editing unusable. Mirror the project-side deferred-save pattern }
{ (perf_deferred_save): mutations only flag dirty, and `save_all` /         }
{ SaveAllDirty flushes the .SchLib to disk at a logical checkpoint. The     }
{ workspace's free-document save sweep already covers standalone libs, so   }
{ no save_all changes are needed.                                            }
Procedure MarkLibDirty(SchLib : ISch_Lib);
Var
    Workspace : IWorkspace;
    Doc : IDocument;
    FullPath : String;
    ServerDoc : IServerDocument;
Begin
    If SchLib = Nil Then Exit;
    Workspace := GetWorkspace;
    If Workspace <> Nil Then
    Begin
        Doc := Workspace.DM_FocusedDocument;
        If Doc <> Nil Then
        Begin
            FullPath := '';
            Try FullPath := Doc.DM_FullPath; Except End;
            If FullPath <> '' Then
            Begin
                ServerDoc := Client.GetDocumentByPath(FullPath);
                If ServerDoc <> Nil Then
                    Try ServerDoc.SetModified(True); Except End;
            End;
        End;
    End;
End;

Function Lib_CreateSymbol(Params : String; RequestId : String) : String;
Var
    Name, DesignatorPrefix, Description, PartCountStr : String;
    PartCount : Integer;
    SchLib : ISch_Lib;
    Component : ISch_Component;
Begin
    Name := ExtractJsonValue(Params, 'name');
    DesignatorPrefix := ExtractJsonValue(Params, 'designator_prefix');
    Description := ExtractJsonValue(Params, 'description');
    PartCountStr := ExtractJsonValue(Params, 'part_count');

    If DesignatorPrefix = '' Then DesignatorPrefix := 'U';
    If PartCountStr = '' Then PartCount := 1
    Else PartCount := StrToIntDef(PartCountStr, 1);
    If PartCount < 1 Then PartCount := 1;

    // Get the current schematic library
    If SchServer = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_SCHLIB', 'No schematic library is active');
        Exit;
    End;

    SchLib := SchServer.GetCurrentSchDocument;
    If (SchLib = Nil) Or (SchLib.ObjectId <> eSchLib) Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_SCHLIB', 'No schematic library is active');
        Exit;
    End;

    // Create new component. Per Altium's createcomp_in_lib.pas reference,
    // CurrentPartID and DisplayMode must be set BEFORE adding primitives;
    // primitives carry OwnerPartId/OwnerPartDisplayMode that link them to
    // a specific part of the component. Without this scaffold, primitives
    // are added but the lib editor can't display them (symbol shows empty).
    Component := SchServer.SchObjectFactory(eSchComponent, eCreate_Default);
    If Component <> Nil Then
    Begin
        Component.CurrentPartID := 1;
        Component.DisplayMode := 0;
        Component.LibReference := Name;
        Component.Designator.Text := DesignatorPrefix + '?';
        Component.ComponentDescription := Description;
        // Multi-part support: PartCount must be set BEFORE adding pins so
        // OwnerPartId assignments on subsequent primitives are accepted.
        Component.PartCount := PartCount;
        Component.CurrentPartID := 1;
        Component.DisplayMode := 0;

        SchServer.ProcessControl.PreProcess(SchLib, '');
        SchLib.AddSchComponent(Component);
        SchServer.ProcessControl.PostProcess(SchLib, 'Edit');

        // Broadcast as a new component (source=nil, dest=c_BroadCast). This
        // is the pattern in Altium's createcomp_in_lib.pas, different from
        // the per-primitive SchRegisterObject(Container, Obj) which sends
        // from the container.
        Try
            SchServer.RobotManager.SendMessage(
                Nil, Nil, SCHM_PrimitiveRegistration,
                Component.I_ObjectAddress);
        Except End;

        SchLib.CurrentSchComponent := Component;
        LastCreatedLibComponent := Component;

        // Refresh the library editor view so the new component is visible.
        Try SchLib.GraphicallyInvalidate; Except End;

        MarkLibDirty(SchLib);
        Result := BuildSuccessResponse(RequestId, '{"success":true,"name":"' + EscapeJsonString(Name) + '","part_count":' + IntToStr(PartCount) + '}');
    End
    Else
        Result := BuildErrorResponse(RequestId, 'CREATE_FAILED', 'Failed to create symbol');
End;

Function Lib_AddPin(Params : String; RequestId : String) : String;
Var
    Designator, Name, ElecType, OwnerPartIdStr : String;
    X, Y, Length, Rotation, OwnerPartId : Integer;
    Hidden : Boolean;
    SchLib : ISch_Lib;
    Component : ISch_Component;
    Pin : ISch_Pin;
    Loc : TLocation;
Begin
    Designator := ExtractJsonValue(Params, 'designator');
    Name := ExtractJsonValue(Params, 'name');
    X := StrToIntDef(ExtractJsonValue(Params, 'x'), 0);
    Y := StrToIntDef(ExtractJsonValue(Params, 'y'), 0);
    Length := StrToIntDef(ExtractJsonValue(Params, 'length'), 200);
    Rotation := StrToIntDef(ExtractJsonValue(Params, 'rotation'), 0);
    ElecType := ExtractJsonValue(Params, 'electrical_type');
    Hidden := ExtractJsonValue(Params, 'hidden') = 'true';
    OwnerPartIdStr := ExtractJsonValue(Params, 'owner_part_id');
    If OwnerPartIdStr = '' Then OwnerPartId := 1
    Else OwnerPartId := StrToIntDef(OwnerPartIdStr, 1);

    SchLib := SchServer.GetCurrentSchDocument;
    If (SchLib = Nil) Or (SchLib.ObjectId <> eSchLib) Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_SCHLIB', 'No schematic library is active');
        Exit;
    End;

    Component := GetTargetLibComponent(SchLib);
    If Component = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_COMPONENT', 'No component is selected');
        Exit;
    End;

    Pin := SchServer.SchObjectFactory(ePin, eCreate_Default);
    If Pin <> Nil Then
    Begin
        Pin.Designator := Designator;
        Pin.Name := Name;
        { Location is a by-value record — read, mutate, write back. }
        Loc := Pin.Location;
        Loc.X := MilsToCoord(X);
        Loc.Y := MilsToCoord(Y);
        Pin.Location := Loc;
        Pin.PinLength := MilsToCoord(Length);
        Pin.Orientation := Rotation Div 90;
        Pin.IsHidden := Hidden;
        // Multi-part: 0 = shared across all parts, 1..N = belongs to part K.
        Pin.OwnerPartId := OwnerPartId;
        Pin.OwnerPartDisplayMode := 0;

        // Set electrical type. The bidirectional constant is spelled
        // eElectricIO in Altium's DelphiScript (eElectricBiDir is undeclared).
        If ElecType = 'input' Then Pin.Electrical := eElectricInput
        Else If ElecType = 'output' Then Pin.Electrical := eElectricOutput
        Else If ElecType = 'bidirectional' Then Pin.Electrical := eElectricIO
        Else If ElecType = 'io' Then Pin.Electrical := eElectricIO
        Else If ElecType = 'power' Then Pin.Electrical := eElectricPower
        Else If ElecType = 'open_collector' Then Pin.Electrical := eElectricOpenCollector
        Else If ElecType = 'open_emitter' Then Pin.Electrical := eElectricOpenEmitter
        Else If ElecType = 'hiz' Then Pin.Electrical := eElectricHiZ
        Else Pin.Electrical := eElectricPassive;

        SchServer.ProcessControl.PreProcess(SchLib, '');
        SetOwnerPart(Pin, Component);
        Component.AddSchObject(Pin);
        SchRegisterObject(Component, Pin);
        SchServer.ProcessControl.PostProcess(SchLib, 'Edit');

        MarkLibDirty(SchLib);
        Result := BuildSuccessResponse(RequestId, '{"success":true,"designator":"' + EscapeJsonString(Designator) + '","owner_part_id":' + IntToStr(OwnerPartId) + '}');
    End
    Else
        Result := BuildErrorResponse(RequestId, 'CREATE_FAILED', 'Failed to create pin');
End;

Function Lib_AddSymbolRectangle(Params : String; RequestId : String) : String;
Var
    X1, Y1, X2, Y2, OwnerPartId, FillColor, BorderColor : Integer;
    OwnerPartIdStr, FillColorStr, BorderColorStr : String;
    SchLib : ISch_Lib;
    Component : ISch_Component;
    Rect : ISch_Rectangle;
    Loc, Cnr : TLocation;
Begin
    X1 := StrToIntDef(ExtractJsonValue(Params, 'x1'), 0);
    Y1 := StrToIntDef(ExtractJsonValue(Params, 'y1'), 0);
    X2 := StrToIntDef(ExtractJsonValue(Params, 'x2'), 0);
    Y2 := StrToIntDef(ExtractJsonValue(Params, 'y2'), 0);
    OwnerPartIdStr := ExtractJsonValue(Params, 'owner_part_id');
    If OwnerPartIdStr = '' Then OwnerPartId := 1
    Else OwnerPartId := StrToIntDef(OwnerPartIdStr, 1);
    // fill_color: -1 means no fill; >=0 is a packed BGR Delphi TColor.
    // Standard Altium symbol body fill is $00B0FFFF (cream-yellow) = 11599871.
    FillColorStr := ExtractJsonValue(Params, 'fill_color');
    If FillColorStr = '' Then FillColor := 11599871
    Else FillColor := StrToIntDef(FillColorStr, 11599871);
    BorderColorStr := ExtractJsonValue(Params, 'border_color');
    If BorderColorStr = '' Then BorderColor := 0
    Else BorderColor := StrToIntDef(BorderColorStr, 0);

    SchLib := SchServer.GetCurrentSchDocument;
    If (SchLib = Nil) Or (SchLib.ObjectId <> eSchLib) Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_SCHLIB', 'No schematic library is active');
        Exit;
    End;

    Component := GetTargetLibComponent(SchLib);
    If Component = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_COMPONENT', 'No component is selected');
        Exit;
    End;

    Rect := SchServer.SchObjectFactory(eRectangle, eCreate_Default);
    If Rect <> Nil Then
    Begin
        { Location and Corner are by-value records — read, mutate, write back. }
        Loc := Rect.Location;
        Loc.X := MilsToCoord(X1);
        Loc.Y := MilsToCoord(Y1);
        Rect.Location := Loc;
        Cnr := Rect.Corner;
        Cnr.X := MilsToCoord(X2);
        Cnr.Y := MilsToCoord(Y2);
        Rect.Corner := Cnr;
        // Apply fill: <0 = transparent (legacy callers); else solid AreaColor.
        If FillColor < 0 Then
            Rect.IsSolid := False
        Else
        Begin
            Rect.IsSolid := True;
            Rect.AreaColor := FillColor;
        End;
        // Border line color — `Color` property on ISch_GraphicalObject
        // (NOT `LineColor`, which exists only on ISch_Line). Per Altium's
        // Schematic API docs the Color property "denotes the color region
        // of a closed object which is usually the border outline".
        Rect.Color := BorderColor;
        // Multi-part: 0 = shared across all parts, 1..N = belongs to part K.
        Rect.OwnerPartId := OwnerPartId;
        Rect.OwnerPartDisplayMode := 0;

        SchServer.ProcessControl.PreProcess(SchLib, '');
        SetOwnerPart(Rect, Component);
        Component.AddSchObject(Rect);
        SchRegisterObject(Component, Rect);
        SchServer.ProcessControl.PostProcess(SchLib, 'Edit');

        MarkLibDirty(SchLib);
        Result := BuildSuccessResponse(RequestId, '{"success":true}');
    End
    Else
        Result := BuildErrorResponse(RequestId, 'CREATE_FAILED', 'Failed to create rectangle');
End;

Function Lib_AddSymbolLine(Params : String; RequestId : String) : String;
Var
    X1, Y1, X2, Y2, Width, OwnerPartId : Integer;
    OwnerPartIdStr : String;
    SchLib : ISch_Lib;
    Component : ISch_Component;
    Line : ISch_Line;
    Loc, Cnr : TLocation;
Begin
    X1 := StrToIntDef(ExtractJsonValue(Params, 'x1'), 0);
    Y1 := StrToIntDef(ExtractJsonValue(Params, 'y1'), 0);
    X2 := StrToIntDef(ExtractJsonValue(Params, 'x2'), 0);
    Y2 := StrToIntDef(ExtractJsonValue(Params, 'y2'), 0);
    Width := StrToIntDef(ExtractJsonValue(Params, 'width'), 1);
    If Width < 0 Then Width := 0;
    If Width > 3 Then Width := 3;
    OwnerPartIdStr := ExtractJsonValue(Params, 'owner_part_id');
    If OwnerPartIdStr = '' Then OwnerPartId := 1
    Else OwnerPartId := StrToIntDef(OwnerPartIdStr, 1);

    SchLib := SchServer.GetCurrentSchDocument;
    If (SchLib = Nil) Or (SchLib.ObjectId <> eSchLib) Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_SCHLIB', 'No schematic library is active');
        Exit;
    End;

    Component := GetTargetLibComponent(SchLib);
    If Component = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_COMPONENT', 'No component is selected');
        Exit;
    End;

    Line := SchServer.SchObjectFactory(eLine, eCreate_Default);
    If Line <> Nil Then
    Begin
        { Location and Corner are by-value records — read, mutate, write back. }
        Loc := Line.Location;
        Loc.X := MilsToCoord(X1);
        Loc.Y := MilsToCoord(Y1);
        Line.Location := Loc;
        Cnr := Line.Corner;
        Cnr.X := MilsToCoord(X2);
        Cnr.Y := MilsToCoord(Y2);
        Line.Corner := Cnr;
        Line.LineWidth := Width;
        // Multi-part: 0 = shared across all parts, 1..N = belongs to part K.
        Line.OwnerPartId := OwnerPartId;
        Line.OwnerPartDisplayMode := 0;

        SchServer.ProcessControl.PreProcess(SchLib, '');
        SetOwnerPart(Line, Component);
        Component.AddSchObject(Line);
        SchRegisterObject(Component, Line);
        SchServer.ProcessControl.PostProcess(SchLib, 'Edit');

        MarkLibDirty(SchLib);
        Result := BuildSuccessResponse(RequestId, '{"success":true}');
    End
    Else
        Result := BuildErrorResponse(RequestId, 'CREATE_FAILED', 'Failed to create line');
End;

Function Lib_CreateFootprint(Params : String; RequestId : String) : String;
Var
    Name, Description : String;
    PcbLib : IPCB_Library;
    Footprint : IPCB_LibComponent;
Begin
    Name := ExtractJsonValue(Params, 'name');
    Description := ExtractJsonValue(Params, 'description');

    PcbLib := PCBServer.GetCurrentPCBLibrary;
    If PcbLib = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_PCBLIB', 'No PCB library is active');
        Exit;
    End;

    Footprint := PCBServer.CreatePCBLibComp;
    If Footprint <> Nil Then
    Begin
        Footprint.Name := Name;
        Footprint.Description := Description;

        PcbLib.RegisterComponent(Footprint);
        { Broadcast component-registration to the board so the editor and
          panels pick up the new footprint. Without this the footprint
          appears in the list but isn't fully bound, so primitives added
          to it later don't persist. Target = Board, event data = Footprint
          (per coffeenmusic/altium-mcp's CreatePCBFootprint pattern). }
        PCBServer.SendMessageToRobots(PcbLib.Board.I_ObjectAddress, c_Broadcast,
            PCBM_BoardRegisteration, Footprint.I_ObjectAddress);
        PcbLib.CurrentComponent := Footprint;
        PcbLib.Board.ViewManager_FullUpdate;

        Result := BuildSuccessResponse(RequestId, '{"success":true,"name":"' + EscapeJsonString(Name) + '"}');
    End
    Else
        Result := BuildErrorResponse(RequestId, 'CREATE_FAILED', 'Failed to create footprint');
End;

Function Lib_AddFootprintPad(Params : String; RequestId : String) : String;
Var
    Designator, Shape, LayerStr : String;
    X, Y, XSize, YSize, HoleSize : Integer;
    Rotation : Double;
    PcbLib : IPCB_Library;
    Footprint : IPCB_LibComponent;
    Pad : IPCB_Pad;
    PadLayer : TLayer;
Begin
    Designator := ExtractJsonValue(Params, 'designator');
    X := StrToIntDef(ExtractJsonValue(Params, 'x'), 0);
    Y := StrToIntDef(ExtractJsonValue(Params, 'y'), 0);
    XSize := StrToIntDef(ExtractJsonValue(Params, 'x_size'), 60);
    YSize := StrToIntDef(ExtractJsonValue(Params, 'y_size'), 60);
    HoleSize := StrToIntDef(ExtractJsonValue(Params, 'hole_size'), 0);
    Shape := ExtractJsonValue(Params, 'shape');
    LayerStr := ExtractJsonValue(Params, 'layer');
    Rotation := StrToFloatDef(ExtractJsonValue(Params, 'rotation'), 0);

    { Without an explicit Pad.Layer the pad is created but doesn't render
      and isn't counted in the PcbLib panel. Through-hole = MultiLayer,
      SMD goes to Top or Bottom based on the layer string. }
    If HoleSize > 0 Then
        PadLayer := eMultiLayer
    Else If LayerStr = 'BottomLayer' Then
        PadLayer := eBottomLayer
    Else
        PadLayer := eTopLayer;

    PcbLib := PCBServer.GetCurrentPCBLibrary;
    If PcbLib = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_PCBLIB', 'No PCB library is active');
        Exit;
    End;

    Footprint := PcbLib.CurrentComponent;
    If Footprint = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_FOOTPRINT', 'No footprint is selected');
        Exit;
    End;

    { Match coffeenmusic/altium-mcp's CreatePCBFootprint pattern verbatim:
      no PreProcess/PostProcess (those wrap an undo transaction that can
      roll back our changes), per-pad broadcast with target=Pad and
      event=c_NoEventData, then a final component-level broadcast and a
      ViewManager_FullUpdate. MarkLibDirty replaces the explicit save —
      the user flushes with Ctrl+S or save_all when ready. }
    Pad := PCBServer.PCBObjectFactory(ePadObject, eNoDimension, eCreate_Default);
    If Pad <> Nil Then
    Begin
        Pad.Name := Designator;
        Pad.Mode := ePadMode_Simple;
        Pad.HoleSize := MilsToCoord(HoleSize);
        Pad.X := MilsToCoord(X);
        Pad.Y := MilsToCoord(Y);
        Pad.Layer := PadLayer;
        Pad.TopXSize := MilsToCoord(XSize);
        Pad.TopYSize := MilsToCoord(YSize);
        If Shape = 'rectangular' Then Pad.TopShape := eRectangular
        Else If Shape = 'octagonal' Then Pad.TopShape := eOctagonal
        Else If Shape = 'rounded_rect' Then Pad.TopShape := eRoundedRectangle
        Else Pad.TopShape := eRounded;

        Footprint.AddPCBObject(Pad);
        PCBServer.SendMessageToRobots(Pad.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

        { Tell the board the footprint changed (component-level). }
        PCBServer.SendMessageToRobots(PcbLib.Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Footprint.I_ObjectAddress);
        PcbLib.CurrentComponent := Footprint;
        PcbLib.Board.ViewManager_FullUpdate;

        Result := BuildSuccessResponse(RequestId, '{"success":true,"designator":"' + EscapeJsonString(Designator) + '"}');
    End
    Else
        Result := BuildErrorResponse(RequestId, 'CREATE_FAILED', 'Failed to create pad');
End;

Function Lib_AddFootprintTrack(Params : String; RequestId : String) : String;
Var
    X1, Y1, X2, Y2, Width : Integer;
    LayerStr : String;
    PcbLib : IPCB_Library;
    Footprint : IPCB_LibComponent;
    Track : IPCB_Track;
    Layer : TLayer;
Begin
    X1 := StrToIntDef(ExtractJsonValue(Params, 'x1'), 0);
    Y1 := StrToIntDef(ExtractJsonValue(Params, 'y1'), 0);
    X2 := StrToIntDef(ExtractJsonValue(Params, 'x2'), 0);
    Y2 := StrToIntDef(ExtractJsonValue(Params, 'y2'), 0);
    Width := StrToIntDef(ExtractJsonValue(Params, 'width'), 10);
    LayerStr := ExtractJsonValue(Params, 'layer');

    PcbLib := PCBServer.GetCurrentPCBLibrary;
    If PcbLib = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_PCBLIB', 'No PCB library is active');
        Exit;
    End;

    Footprint := PcbLib.CurrentComponent;
    If Footprint = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_FOOTPRINT', 'No footprint is selected');
        Exit;
    End;

    If LayerStr = 'BottomOverlay' Then Layer := eBottomOverlay
    Else Layer := eTopOverlay;

    Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
    If Track <> Nil Then
    Begin
        Track.X1 := MilsToCoord(X1);
        Track.Y1 := MilsToCoord(Y1);
        Track.X2 := MilsToCoord(X2);
        Track.Y2 := MilsToCoord(Y2);
        Track.Width := MilsToCoord(Width);
        Track.Layer := Layer;

        Footprint.AddPCBObject(Track);
        PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);
        PCBServer.SendMessageToRobots(PcbLib.Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Footprint.I_ObjectAddress);
        PcbLib.Board.ViewManager_FullUpdate;

        Result := BuildSuccessResponse(RequestId, '{"success":true}');
    End
    Else
        Result := BuildErrorResponse(RequestId, 'CREATE_FAILED', 'Failed to create track');
End;

Function Lib_AddFootprintArc(Params : String; RequestId : String) : String;
Var
    XCenter, YCenter, Radius, StartAngle, EndAngle, Width : Integer;
    LayerStr : String;
    PcbLib : IPCB_Library;
    Footprint : IPCB_LibComponent;
    Arc : IPCB_Arc;
    Layer : TLayer;
Begin
    XCenter := StrToIntDef(ExtractJsonValue(Params, 'x_center'), 0);
    YCenter := StrToIntDef(ExtractJsonValue(Params, 'y_center'), 0);
    Radius := StrToIntDef(ExtractJsonValue(Params, 'radius'), 100);
    StartAngle := StrToIntDef(ExtractJsonValue(Params, 'start_angle'), 0);
    EndAngle := StrToIntDef(ExtractJsonValue(Params, 'end_angle'), 360);
    Width := StrToIntDef(ExtractJsonValue(Params, 'width'), 10);
    LayerStr := ExtractJsonValue(Params, 'layer');

    PcbLib := PCBServer.GetCurrentPCBLibrary;
    If PcbLib = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_PCBLIB', 'No PCB library is active');
        Exit;
    End;

    Footprint := PcbLib.CurrentComponent;
    If Footprint = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_FOOTPRINT', 'No footprint is selected');
        Exit;
    End;

    If LayerStr = 'BottomOverlay' Then Layer := eBottomOverlay
    Else Layer := eTopOverlay;

    Arc := PCBServer.PCBObjectFactory(eArcObject, eNoDimension, eCreate_Default);
    If Arc <> Nil Then
    Begin
        Arc.XCenter := MilsToCoord(XCenter);
        Arc.YCenter := MilsToCoord(YCenter);
        Arc.Radius := MilsToCoord(Radius);
        Arc.StartAngle := StartAngle;
        Arc.EndAngle := EndAngle;
        Arc.LineWidth := MilsToCoord(Width);
        Arc.Layer := Layer;

        Footprint.AddPCBObject(Arc);
        PCBServer.SendMessageToRobots(Arc.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);
        PCBServer.SendMessageToRobots(PcbLib.Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Footprint.I_ObjectAddress);
        PcbLib.Board.ViewManager_FullUpdate;

        Result := BuildSuccessResponse(RequestId, '{"success":true}');
    End
    Else
        Result := BuildErrorResponse(RequestId, 'CREATE_FAILED', 'Failed to create arc');
End;

{..............................................................................}
{ Lib_AddFootprintPads - Bulk add pads to the currently-selected PCB footprint. }
{ One PreProcess/PostProcess + one save for the whole batch, so a 144-ball BGA }
{ costs ~1x the overhead of placing one pad. Mirrors Lib_AddPins on the SchLib }
{ side. Designator validation (no comma-separated multi-pad aliases) is        }
{ enforced on the Python side via _validate_pin_designator before the batch    }
{ payload reaches here.                                                        }
{ Params: pads = '~~'-separated list; each pad has key=value fields joined by  }
{         ';'. Fields: designator, x, y, x_size, y_size (mils), hole_size      }
{         (mils, 0=SMD), shape (round/rectangular/octagonal), layer            }
{         (currently ignored — matches singular Lib_AddFootprintPad behavior), }
{         rotation (degrees, float).                                           }
{..............................................................................}

Function Lib_AddFootprintPads(Params : String; RequestId : String) : String;
Var
    PadsStr, PadData, ShapeStr, PadNum : String;
    XMM, YMM, WMM, HMM : Double;
    PadShape : TShape;
    Fields : TStringList;
    PcbLib : IPCB_Library;
    LibComp : IPCB_Component;
    Pad : IPCB_Pad;
    Added, OpCount : Integer;
    I, J, FieldStart : Integer;
Begin
    PadsStr := ExtractJsonValue(Params, 'pads');
    If PadsStr = '' Then
    Begin
        Result := BuildErrorResponse(RequestId, 'MISSING_PARAM', 'pads is required');
        Exit;
    End;

    PcbLib := PCBServer.GetCurrentPCBLibrary;
    If PcbLib = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_PCBLIB', 'No PCB library is active');
        Exit;
    End;

    LibComp := PcbLib.CurrentComponent;
    If LibComp = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_FOOTPRINT', 'No footprint is selected');
        Exit;
    End;

    Added := 0;
    OpCount := 0;

    { Direct port of coffeenmusic/altium-mcp's CreatePCBFootprint pad-loop.
      Input format per pad (joined by '~~' across pads):
        "designator|xmm|ymm|wmm|hmm|shape"
      Where shape is "Round" / "Rect" / "Oval". Coordinates in mm
      (matches reference's MMsToCoord usage). The Python wrapper handles
      mil→mm conversion before sending. Per-pad sequence: factory create →
      set props in coffeenmusic's exact order → AddPCBObject → broadcast. }
    Fields := TStringList.Create;
    Try
        While PadsStr <> '' Do
        Begin
            J := Pos('~~', PadsStr);
            If J > 0 Then
            Begin
                PadData := Copy(PadsStr, 1, J - 1);
                PadsStr := Copy(PadsStr, J + 2, Length(PadsStr));
            End
            Else
            Begin
                PadData := PadsStr;
                PadsStr := '';
            End;
            PadData := Trim(PadData);
            If PadData = '' Then Continue;
            OpCount := OpCount + 1;

            Fields.Clear;
            FieldStart := 1;
            For I := 1 To Length(PadData) + 1 Do
            Begin
                If (I > Length(PadData)) Or (PadData[I] = '|') Then
                Begin
                    Fields.Add(Trim(Copy(PadData, FieldStart, I - FieldStart)));
                    FieldStart := I + 1;
                End;
            End;

            If Fields.Count < 5 Then Continue;

            PadNum := Fields[0];
            XMM := StrToFloatDef(Fields[1], 0);
            YMM := StrToFloatDef(Fields[2], 0);
            WMM := StrToFloatDef(Fields[3], 0);
            HMM := StrToFloatDef(Fields[4], 0);
            If Fields.Count >= 6 Then ShapeStr := Fields[5]
            Else ShapeStr := 'Rect';

            If ShapeStr = 'Round' Then PadShape := eRounded
            Else If ShapeStr = 'Oval' Then PadShape := eRoundedRectangle
            Else PadShape := eRectangular;

            Pad := PCBServer.PCBObjectFactory(ePadObject, eNoDimension, eCreate_Default);
            Pad.Name := PadNum;
            Pad.Mode := ePadMode_Simple;
            Pad.HoleSize := 0;
            Pad.x := MMsToCoord(XMM);
            Pad.y := MMsToCoord(YMM);
            Pad.Layer := eTopLayer;
            Pad.TopXSize := MMsToCoord(WMM);
            Pad.TopYSize := MMsToCoord(HMM);
            Pad.TopShape := PadShape;

            LibComp.AddPCBObject(Pad);
            PCBServer.SendMessageToRobots(Pad.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);
            Added := Added + 1;
        End;
    Finally
        Fields.Free;
    End;

    PCBServer.SendMessageToRobots(PcbLib.Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, LibComp.I_ObjectAddress);
    PcbLib.CurrentComponent := LibComp;
    PcbLib.Board.ViewManager_FullUpdate;

    Result := BuildSuccessResponse(RequestId,
        '{"added":' + IntToStr(Added) + ',"total":' + IntToStr(OpCount) + '}');
End;

{..............................................................................}
{ Lib_CreatePCBFootprint — atomic footprint creation in ONE MCP call.          }
{ Direct port of coffeenmusic/altium-mcp's CreatePCBFootprint. Holds the       }
{ IPCB_Component reference from CreatePCBLibComp through the entire pad-add    }
{ loop, avoiding the stale-reference problem that hits when creation and pad   }
{ population are split across two MCP calls.                                   }
{                                                                              }
{ Params (JSON):                                                               }
{   name              — footprint name (string, required)                      }
{   description       — footprint description (string, optional)               }
{   pads              — '~~'-joined list of '|'-separated pad records:         }
{                       "designator|xmm|ymm|wmm|hmm|shape" where shape is     }
{                       "Round" / "Rect" / "Oval"                               }
{   body_x_mm         — full body width in mm (silk + assembly drawn here).    }
{                       0 = auto-fit to pad bounding box.                       }
{   body_y_mm         — full body height in mm. 0 = auto.                      }
{   courtyard_excess_mm — IPC clearance added beyond body for the courtyard    }
{                       outline (default 0.25 mm Nominal density).             }
{                                                                              }
{ Geometry: silkscreen + assembly outlines are drawn AT body edge (no inset    }
{ — so pad-center-to-silk matches the datasheet's body-edge dimension).        }
{ Courtyard is drawn at body + courtyard_excess_mm on each side.               }
{..............................................................................}
Function Lib_CreatePCBFootprint(Params : String; RequestId : String) : String;
Var
    Name, Description, PadsStr, PadData, ShapeStr, PadNum, S : String;
    XMM, YMM, WMM, HMM : Double;
    PadShape : TShape;
    PadFields : TStringList;
    PcbLib : IPCB_Library;
    LibComp : IPCB_Component;
    Pad : IPCB_Pad;
    Track : IPCB_Track;
    Pin1Arc : IPCB_Arc;
    DesigText : IPCB_Text;
    Added, Total : Integer;
    I, J, FieldStart : Integer;
    BodyXMM, BodyYMM, CourtyardExcess, TrackWMM : Double;
    BodyX1, BodyX2, BodyY1, BodyY2 : Double;     { silk + assembly outline }
    CrtX1, CrtX2, CrtY1, CrtY2 : Double;          { courtyard outline (body + excess) }
    MaxX, MinX, MaxY, MinY : Double;
    Pin1ChamferMM : Double;
    SilkLayer : TLayer;
Begin
    Name := ExtractJsonValue(Params, 'name');
    Description := ExtractJsonValue(Params, 'description');
    PadsStr := ExtractJsonValue(Params, 'pads');
    S := ExtractJsonValue(Params, 'body_x_mm');
    BodyXMM := StrToFloatDef(S, 0);
    S := ExtractJsonValue(Params, 'body_y_mm');
    BodyYMM := StrToFloatDef(S, 0);
    S := ExtractJsonValue(Params, 'courtyard_excess_mm');
    CourtyardExcess := StrToFloatDef(S, 0.25);     { IPC Nominal density default }
    TrackWMM := 0.1;                                { silk/assembly/courtyard line width }

    If Name = '' Then
    Begin
        Result := BuildErrorResponse(RequestId, 'MISSING_PARAM', 'name is required');
        Exit;
    End;

    PcbLib := PCBServer.GetCurrentPCBLibrary;
    If PcbLib = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_PCBLIB', 'No PCB library is active');
        Exit;
    End;

    Added := 0;
    Total := 0;
    MaxX := -1.0E9; MaxY := -1.0E9;
    MinX :=  1.0E9; MinY :=  1.0E9;
    SilkLayer := String2Layer('Top Overlay');

    { Create + register footprint, hold the LibComp ref through the
      whole function so the pads-list inserts hit the right object. }
    LibComp := PCBServer.CreatePCBLibComp;
    LibComp.Name := Name;
    PcbLib.RegisterComponent(LibComp);

    PadFields := TStringList.Create;
    Try
        While PadsStr <> '' Do
        Begin
            J := Pos('~~', PadsStr);
            If J > 0 Then
            Begin
                PadData := Copy(PadsStr, 1, J - 1);
                PadsStr := Copy(PadsStr, J + 2, Length(PadsStr));
            End
            Else
            Begin
                PadData := PadsStr;
                PadsStr := '';
            End;
            PadData := Trim(PadData);
            If PadData = '' Then Continue;
            Total := Total + 1;

            PadFields.Clear;
            FieldStart := 1;
            For I := 1 To Length(PadData) + 1 Do
            Begin
                If (I > Length(PadData)) Or (PadData[I] = '|') Then
                Begin
                    PadFields.Add(Trim(Copy(PadData, FieldStart, I - FieldStart)));
                    FieldStart := I + 1;
                End;
            End;

            If PadFields.Count < 5 Then Continue;

            PadNum := PadFields[0];
            XMM := StrToFloatDef(PadFields[1], 0);
            YMM := StrToFloatDef(PadFields[2], 0);
            WMM := StrToFloatDef(PadFields[3], 0);
            HMM := StrToFloatDef(PadFields[4], 0);
            If PadFields.Count >= 6 Then ShapeStr := PadFields[5]
            Else ShapeStr := 'Rect';

            If ShapeStr = 'Round' Then PadShape := eRounded
            Else If ShapeStr = 'Oval' Then PadShape := eRoundedRectangle
            Else PadShape := eRectangular;

            Pad := PCBServer.PCBObjectFactory(ePadObject, eNoDimension, eCreate_Default);
            Pad.Name := PadNum;
            Pad.Mode := ePadMode_Simple;
            Pad.HoleSize := 0;
            Pad.x := MMsToCoord(XMM);
            Pad.y := MMsToCoord(YMM);
            Pad.Layer := eTopLayer;
            Pad.TopXSize := MMsToCoord(WMM);
            Pad.TopYSize := MMsToCoord(HMM);
            Pad.TopShape := PadShape;

            LibComp.AddPCBObject(Pad);
            PCBServer.SendMessageToRobots(Pad.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);
            Added := Added + 1;

            If (XMM - WMM/2) < MinX Then MinX := XMM - WMM/2;
            If (YMM - HMM/2) < MinY Then MinY := YMM - HMM/2;
            If (XMM + WMM/2) > MaxX Then MaxX := XMM + WMM/2;
            If (YMM + HMM/2) > MaxY Then MaxY := YMM + HMM/2;
        End;
    Finally
        PadFields.Free;
    End;

    { Body outline (silk + assembly drawn AT body edge — no inset, so
      pad-center-to-silk distance matches the datasheet's body-edge
      dimension exactly). }
    If (BodyXMM > 0) And (BodyYMM > 0) Then
    Begin
        BodyX1 := -BodyXMM / 2.0; BodyX2 := BodyXMM / 2.0;
        BodyY1 := -BodyYMM / 2.0; BodyY2 := BodyYMM / 2.0;
    End
    Else If Added > 0 Then
    Begin
        { Auto-fit body to pad bounding box + a small margin. }
        BodyX1 := MinX - 0.25; BodyX2 := MaxX + 0.25;
        BodyY1 := MinY - 0.25; BodyY2 := MaxY + 0.25;
    End
    Else
    Begin
        BodyX1 := -1; BodyX2 := 1; BodyY1 := -1; BodyY2 := 1;
    End;

    { Courtyard = body + IPC clearance on each side. }
    CrtX1 := BodyX1 - CourtyardExcess; CrtX2 := BodyX2 + CourtyardExcess;
    CrtY1 := BodyY1 - CourtyardExcess; CrtY2 := BodyY2 + CourtyardExcess;

    { 4 courtyard tracks on Mechanical 15 (IPC convention). }
    Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
    Track.Layer := ILayer.MechanicalLayer(15);
    Track.x1 := MMsToCoord(CrtX1); Track.y1 := MMsToCoord(CrtY1);
    Track.x2 := MMsToCoord(CrtX2); Track.y2 := MMsToCoord(CrtY1);
    Track.Width := MMsToCoord(TrackWMM);
    LibComp.AddPCBObject(Track);
    PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

    Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
    Track.Layer := ILayer.MechanicalLayer(15);
    Track.x1 := MMsToCoord(CrtX2); Track.y1 := MMsToCoord(CrtY1);
    Track.x2 := MMsToCoord(CrtX2); Track.y2 := MMsToCoord(CrtY2);
    Track.Width := MMsToCoord(TrackWMM);
    LibComp.AddPCBObject(Track);
    PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

    Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
    Track.Layer := ILayer.MechanicalLayer(15);
    Track.x1 := MMsToCoord(CrtX2); Track.y1 := MMsToCoord(CrtY2);
    Track.x2 := MMsToCoord(CrtX1); Track.y2 := MMsToCoord(CrtY2);
    Track.Width := MMsToCoord(TrackWMM);
    LibComp.AddPCBObject(Track);
    PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

    Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
    Track.Layer := ILayer.MechanicalLayer(15);
    Track.x1 := MMsToCoord(CrtX1); Track.y1 := MMsToCoord(CrtY2);
    Track.x2 := MMsToCoord(CrtX1); Track.y2 := MMsToCoord(CrtY1);
    Track.Width := MMsToCoord(TrackWMM);
    LibComp.AddPCBObject(Track);
    PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

    { ----- Silkscreen body outline on Top Overlay — IPC pin-1 chamfered
      corner at the top-left. Chamfer size sized so the diagonal stays
      in the corner space BEFORE the first pad row (= less than the
      ball-to-edge distance, which for a typical fine-pitch BGA is
      ~0.6mm). 0.5mm chamfer keeps clear of pads even at 0.5mm pitch. }
    Pin1ChamferMM := 0.5;
    { Bottom edge (full length). }
    Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
    Track.Layer := SilkLayer;
    Track.x1 := MMsToCoord(BodyX1); Track.y1 := MMsToCoord(BodyY1);
    Track.x2 := MMsToCoord(BodyX2); Track.y2 := MMsToCoord(BodyY1);
    Track.Width := MMsToCoord(TrackWMM);
    LibComp.AddPCBObject(Track);
    PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

    { Right edge (full length). }
    Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
    Track.Layer := SilkLayer;
    Track.x1 := MMsToCoord(BodyX2); Track.y1 := MMsToCoord(BodyY1);
    Track.x2 := MMsToCoord(BodyX2); Track.y2 := MMsToCoord(BodyY2);
    Track.Width := MMsToCoord(TrackWMM);
    LibComp.AddPCBObject(Track);
    PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

    { Top edge (shortened on left for chamfer). }
    Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
    Track.Layer := SilkLayer;
    Track.x1 := MMsToCoord(BodyX2); Track.y1 := MMsToCoord(BodyY2);
    Track.x2 := MMsToCoord(BodyX1 + Pin1ChamferMM); Track.y2 := MMsToCoord(BodyY2);
    Track.Width := MMsToCoord(TrackWMM);
    LibComp.AddPCBObject(Track);
    PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

    { 45° chamfer at top-left corner — pin-1 indicator. }
    Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
    Track.Layer := SilkLayer;
    Track.x1 := MMsToCoord(BodyX1 + Pin1ChamferMM); Track.y1 := MMsToCoord(BodyY2);
    Track.x2 := MMsToCoord(BodyX1); Track.y2 := MMsToCoord(BodyY2 - Pin1ChamferMM);
    Track.Width := MMsToCoord(TrackWMM);
    LibComp.AddPCBObject(Track);
    PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

    { Left edge (shortened on top for chamfer). }
    Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
    Track.Layer := SilkLayer;
    Track.x1 := MMsToCoord(BodyX1); Track.y1 := MMsToCoord(BodyY2 - Pin1ChamferMM);
    Track.x2 := MMsToCoord(BodyX1); Track.y2 := MMsToCoord(BodyY1);
    Track.Width := MMsToCoord(TrackWMM);
    LibComp.AddPCBObject(Track);
    PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

    { ----- Assembly outline on Top Assembly (Mech 13) — at body edge. }
    Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
    Track.Layer := ILayer.MechanicalLayer(13);
    Track.x1 := MMsToCoord(BodyX1); Track.y1 := MMsToCoord(BodyY1);
    Track.x2 := MMsToCoord(BodyX2); Track.y2 := MMsToCoord(BodyY1);
    Track.Width := MMsToCoord(TrackWMM);
    LibComp.AddPCBObject(Track);
    PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

    Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
    Track.Layer := ILayer.MechanicalLayer(13);
    Track.x1 := MMsToCoord(BodyX2); Track.y1 := MMsToCoord(BodyY1);
    Track.x2 := MMsToCoord(BodyX2); Track.y2 := MMsToCoord(BodyY2);
    Track.Width := MMsToCoord(TrackWMM);
    LibComp.AddPCBObject(Track);
    PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

    Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
    Track.Layer := ILayer.MechanicalLayer(13);
    Track.x1 := MMsToCoord(BodyX2); Track.y1 := MMsToCoord(BodyY2);
    Track.x2 := MMsToCoord(BodyX1); Track.y2 := MMsToCoord(BodyY2);
    Track.Width := MMsToCoord(TrackWMM);
    LibComp.AddPCBObject(Track);
    PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

    Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
    Track.Layer := ILayer.MechanicalLayer(13);
    Track.x1 := MMsToCoord(BodyX1); Track.y1 := MMsToCoord(BodyY2);
    Track.x2 := MMsToCoord(BodyX1); Track.y2 := MMsToCoord(BodyY1);
    Track.Width := MMsToCoord(TrackWMM);
    LibComp.AddPCBObject(Track);
    PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

    { ----- Pin-1 indicator on Top Assembly — small triangle in the
      top-left corner (IPC convention). Diagonal + two short closing
      edges so the triangle is unambiguous on the assembly drawing. Same
      Pin1ChamferMM as silk → never crosses pad A1. }
    Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
    Track.Layer := ILayer.MechanicalLayer(13);
    Track.x1 := MMsToCoord(BodyX1); Track.y1 := MMsToCoord(BodyY2 - Pin1ChamferMM);
    Track.x2 := MMsToCoord(BodyX1 + Pin1ChamferMM); Track.y2 := MMsToCoord(BodyY2);
    Track.Width := MMsToCoord(TrackWMM);
    LibComp.AddPCBObject(Track);
    PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

    { Short top edge of triangle: from corner along top to the diagonal apex. }
    Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
    Track.Layer := ILayer.MechanicalLayer(13);
    Track.x1 := MMsToCoord(BodyX1); Track.y1 := MMsToCoord(BodyY2);
    Track.x2 := MMsToCoord(BodyX1 + Pin1ChamferMM); Track.y2 := MMsToCoord(BodyY2);
    Track.Width := MMsToCoord(TrackWMM);
    LibComp.AddPCBObject(Track);
    PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

    { Short left edge of triangle: from corner down to the diagonal apex. }
    Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
    Track.Layer := ILayer.MechanicalLayer(13);
    Track.x1 := MMsToCoord(BodyX1); Track.y1 := MMsToCoord(BodyY2);
    Track.x2 := MMsToCoord(BodyX1); Track.y2 := MMsToCoord(BodyY2 - Pin1ChamferMM);
    Track.Width := MMsToCoord(TrackWMM);
    LibComp.AddPCBObject(Track);
    PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

    { ----- Pin-1 marker — solid filled dot just outside the chamfered
      top-left corner. We achieve "filled" by setting LineWidth equal to
      2 × Radius so the ring's inner edge collapses to the centre and the
      whole disc is painted. Anchor: just outside the chamfer apex. }
    If Added > 0 Then
    Begin
        Pin1Arc := PCBServer.PCBObjectFactory(eArcObject, eNoDimension, eCreate_Default);
        Pin1Arc.Layer := SilkLayer;
        Pin1Arc.XCenter := MMsToCoord(BodyX1 - 0.3);
        Pin1Arc.YCenter := MMsToCoord(BodyY2 + 0.3);
        Pin1Arc.Radius := MMsToCoord(0.15);
        Pin1Arc.LineWidth := MMsToCoord(0.30);   { = 2 * Radius → solid disc }
        Pin1Arc.StartAngle := 0;
        Pin1Arc.EndAngle := 360;
        LibComp.AddPCBObject(Pin1Arc);
        PCBServer.SendMessageToRobots(Pin1Arc.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);
    End;

    { ----- Designator text "(.Designator)" on Top Assembly (Mech 13).
      The leading "." special string is replaced with the placed-component's
      designator at schematic-bind time. Place it centered, sized to the
      footprint width. ----- }
    DesigText := PCBServer.PCBObjectFactory(eTextObject, eNoDimension, eCreate_Default);
    DesigText.Text := '.Designator';
    DesigText.Layer := ILayer.MechanicalLayer(13);
    DesigText.XLocation := MMsToCoord(CrtX1 + 0.5);
    DesigText.YLocation := MMsToCoord(0);
    DesigText.Size := MMsToCoord(1.0);
    DesigText.Width := MMsToCoord(0.15);
    LibComp.AddPCBObject(DesigText);
    PCBServer.SendMessageToRobots(DesigText.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

    PCBServer.SendMessageToRobots(PcbLib.Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, LibComp.I_ObjectAddress);
    PcbLib.CurrentComponent := LibComp;
    PcbLib.Board.ViewManager_FullUpdate;

    Result := BuildSuccessResponse(RequestId,
        '{"success":true,"footprint_name":"' + EscapeJsonString(Name) +
        '","pad_count":' + IntToStr(Added) +
        ',"total":' + IntToStr(Total) +
        ',"body_width_mm":' + FloatToStr(BodyX2 - BodyX1) +
        ',"body_height_mm":' + FloatToStr(BodyY2 - BodyY1) +
        ',"courtyard_width_mm":' + FloatToStr(CrtX2 - CrtX1) +
        ',"courtyard_height_mm":' + FloatToStr(CrtY2 - CrtY1) + '}');
End;

Function Lib_LinkFootprint(Params : String; RequestId : String) : String;
Var
    FootprintName, LibraryName : String;
    SchLib : ISch_Lib;
    Component : ISch_Component;
    Impl : ISch_Implementation;
Begin
    FootprintName := ExtractJsonValue(Params, 'footprint_name');
    LibraryName := ExtractJsonValue(Params, 'library_name');
    LibraryName := StringReplace(LibraryName, '\\', '\', -1);

    SchLib := SchServer.GetCurrentSchDocument;
    If (SchLib = Nil) Or (SchLib.ObjectId <> eSchLib) Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_SCHLIB', 'No schematic library is active');
        Exit;
    End;

    Component := GetTargetLibComponent(SchLib);
    If Component = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_COMPONENT', 'No component is selected');
        Exit;
    End;

    Impl := Nil;
    Try
        Impl := SchServer.SchObjectFactory(eImplementation, eCreate_Default);
    Except
        Result := BuildErrorResponse(RequestId, 'LINK_FAILED', 'SchObjectFactory(eImplementation) raised');
        Exit;
    End;

    If Impl = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'LINK_FAILED', 'Failed to link footprint');
        Exit;
    End;

    Try
        Impl.ModelName := FootprintName;
        Impl.ModelType := cDocKind_PcbLib;
        Impl.IsCurrent := True;
        // NOTE: Tested on Altium 26.5 — Impl.LibraryIdentifier is read-only
        // and Impl.UseComponentLibrary likewise raises. The library_name
        // argument is intentionally ignored; use a parent .LibPkg or the
        // SchLib UI's "Add Footprint → Specified" dialog to attach an
        // explicit path for the preview pane.
        SetOwnerPart(Impl, Component);
        Component.AddSchObject(Impl);
        SchRegisterObject(Component, Impl);
    Except
        Result := BuildErrorResponse(RequestId, 'IMPL_BIND_FAILED', 'Failed to attach implementation to component');
        Exit;
    End;

    { NOTE: Earlier we tried to also write an explicit ISch_DatafileLink
      with the .PcbLib path so the SchLib editor preview pane could
      resolve the footprint without a parent .LibPkg. That code path
      crashed the script — likely because `eDatafileLink` is not a
      compiler-declared constant on this Altium build (a compile-time
      error Try/Except can't catch). For now the link is name-only;
      preview works once the user adds the path via the SchLib UI's
      "Add Footprint → Specified" dialog, or once the SchLib + PcbLib
      are wrapped in a parent .LibPkg project. The `library_name`
      argument is currently ignored. }

    Result := BuildSuccessResponse(RequestId, '{"success":true,"footprint":"' + EscapeJsonString(FootprintName) + '"}');
End;

Function Lib_Link3DModel(Params : String; RequestId : String) : String;
Var
    ModelPath, ModelName : String;
    SchLib : ISch_Lib;
    Component : ISch_Component;
    Impl : ISch_Implementation;
Begin
    ModelPath := ExtractJsonValue(Params, 'model_path');
    ModelPath := StringReplace(ModelPath, '\\', '\', -1);
    ModelName := ExtractJsonValue(Params, 'model_name');
    If ModelName = '' Then ModelName := ExtractFileName(ModelPath);

    SchLib := SchServer.GetCurrentSchDocument;
    If (SchLib = Nil) Or (SchLib.ObjectId <> eSchLib) Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_SCHLIB', 'No schematic library is active');
        Exit;
    End;

    Component := GetTargetLibComponent(SchLib);
    If Component = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_COMPONENT', 'No component is selected');
        Exit;
    End;

    Impl := SchServer.SchObjectFactory(eImplementation, eCreate_Default);
    If Impl <> Nil Then
    Begin
        Impl.ModelName := ModelName;
        Impl.ModelType := 'PCB3DModel';
        SetOwnerPart(Impl, Component);
        Component.AddSchObject(Impl);
        SchRegisterObject(Component, Impl);

        Result := BuildSuccessResponse(RequestId, '{"success":true,"model":"' + EscapeJsonString(ModelName) + '"}');
    End
    Else
        Result := BuildErrorResponse(RequestId, 'LINK_FAILED', 'Failed to link 3D model');
End;

{..............................................................................}
{ Lib_Add3DBody — embed a STEP file as a 3D body on the active PcbLib            }
{ footprint. Operates on PcbLib.CurrentComponent (the focused footprint in       }
{ the PcbLib editor). Body is anchored at the footprint origin by default;       }
{ pass offset_x_mm / offset_y_mm to nudge, rot_z_deg to rotate around Z          }
{ (most common — part orientation), standoff_mm for the body height above the    }
{ board (typically 0 for surface-mount, > 0 for parts on standoffs).             }
{                                                                                }
{ Pattern follows community-validated DelphiScript:                              }
{   ModelFactory_FromFilename → SetState_FromModel → Body.Model := <model>       }
{ This is the same flow Add → 3D Body → Generic in the Altium UI uses.           }
{..............................................................................}
Function Lib_Add3DBody(Params : String; RequestId : String) : String;
Var
    ModelPath, S : String;
    Standoff, Overall, RotZ : Double;
    MechLayerNum : Integer;
    PcbLib : IPCB_Library;
    LibComp : IPCB_LibComponent;
    Body : IPCB_ComponentBody;
    Model : IPCB_Model;
    AView : IServerDocumentView;
    AServerDocument : IServerDocument;
Begin
    ModelPath := ExtractJsonValue(Params, 'model_path');
    ModelPath := StringReplace(ModelPath, '\\', '\', -1);
    S := ExtractJsonValue(Params, 'standoff_mm');
    Standoff := StrToFloatDef(S, 0);
    S := ExtractJsonValue(Params, 'overall_height_mm');
    Overall := StrToFloatDef(S, 0);
    S := ExtractJsonValue(Params, 'mech_layer');
    MechLayerNum := StrToIntDef(S, 1);    { default Mechanical 1; many libs use 2 for "Top 3D Body" }
    S := ExtractJsonValue(Params, 'rot_z_deg');
    RotZ := StrToFloatDef(S, 0);

    If ModelPath = '' Then
    Begin
        Result := BuildErrorResponse(RequestId, 'MISSING_PARAM', 'model_path is required');
        Exit;
    End;
    If Not FileExists(ModelPath) Then
    Begin
        Result := BuildErrorResponse(RequestId, 'FILE_NOT_FOUND', 'STEP file does not exist: ' + ModelPath);
        Exit;
    End;

    PcbLib := PCBServer.GetCurrentPCBLibrary;
    If PcbLib = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_PCBLIB', 'No PCB library is active');
        Exit;
    End;

    LibComp := PcbLib.CurrentComponent;
    If LibComp = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_FOOTPRINT', 'No footprint is selected in the PCB library');
        Exit;
    End;

    { Granular Try/Except blocks: when an Altium API method raises (or
      DelphiScript can't coerce a return type), the script IDE pops a
      modal dialog. Without local Try/Except the polling loop hangs
      after dismissing the dialog. With small Try/Except around each
      risky call, clicking OK on the dialog lets execution fall into
      the local Except branch, the function returns a proper error
      response, and the polling loop resumes. }
    { Verified pattern from Altium-Designer-addons/scripts-libraries
      SPI_Cleanup_LPW_Footprint.pas (which credits AutoSTEPplacer.pas):
        1. Create body
        2. Set BodyProjection + Layer + opacity BEFORE model load
        3. ModelFactory_FromFilename → SetState_FromModel → Model.SetState(rotation) → Body.Model := Model
        4. SetState_Identifier(name) — METHOD form, NOT direct property assignment
        5. LibComp.AddPCBObject(Body)
        6. Mark IServerDocument.Modified := True so the 3D engine commits + re-renders
        7. ViewManager_FullUpdate                                                  }

    Body := Nil;
    Try
        Body := PCBServer.PCBObjectFactory(eComponentBodyObject, eNoDimension, eCreate_Default);
    Except
        Result := BuildErrorResponse(RequestId, 'BODY_CREATE_FAILED', 'PCBObjectFactory raised on eComponentBodyObject');
        Exit;
    End;
    If Body = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'BODY_CREATE_FAILED', 'Failed to create component body');
        Exit;
    End;

    { Side + layer + opacity BEFORE the model load. The verified working
      script does it in this order; doing it after the load gets the
      values clobbered. }
    Try Body.BodyProjection := eBoardSide_Top; Except End;
    Try Body.Layer := ILayer.MechanicalLayer(MechLayerNum); Except End;
    Try Body.BodyOpacity3D := 1.0; Except End;

    Try
        { Second arg = embed flag. True embeds the STEP geometry into
          the PcbLib (loads + stores the parsed shapes); False creates
          a "linked" reference that may not render unless the file is
          on the project's search path. AutoSTEPplacer uses False but
          renders via DoFileSave. We use True for full self-contained
          bodies that render in the PcbLib editor. }
        Model := Body.ModelFactory_FromFilename(ModelPath, True);
    Except
        Result := BuildErrorResponse(RequestId, 'STEP_LOAD_FAILED', 'ModelFactory_FromFilename raised on: ' + ModelPath);
        Exit;
    End;
    Try
        Body.SetState_FromModel;
        { ALWAYS call Model.SetState — verified pattern calls it
          unconditionally, before Body.Model := Model. This might be
          the trigger that actually parses the STEP geometry; without
          it, the Model is just a path reference with no shapes loaded.
          Args: (Xrot, Yrot, Zrot, ZOffsetCoord). }
        Model.SetState(0, 0, RotZ, MMsToCoord(Standoff));
        Body.Model := Model;
    Except
        Result := BuildErrorResponse(RequestId, 'BODY_BIND_FAILED', 'SetState_FromModel / Body.Model raised — likely STEP file invalid or geometry empty');
        Exit;
    End;

    { Skip SetState_Identifier — the working reference body has an
      empty identifier ("") and renders fine. Setting it on ours
      doesn't change visibility but is one less variable to consider. }

    Try
        If Standoff > 0 Then Body.StandoffHeight := MMsToCoord(Standoff);
        If Overall  > 0 Then Body.OverallHeight  := MMsToCoord(Overall);
    Except End;

    Try
        LibComp.AddPCBObject(Body);
    Except
        Result := BuildErrorResponse(RequestId, 'ADD_PCB_OBJECT_FAILED', 'LibComp.AddPCBObject(Body) raised');
        Exit;
    End;

    { CRITICAL: mark the IServerDocument as modified. Without this, the
      3D engine treats the in-memory body as ghosted and never includes
      it in the rendered scene — explaining "body added but invisible". }
    Try
        AView := Client.GetCurrentView;
        If AView <> Nil Then
        Begin
            AServerDocument := AView.OwnerDocument;
            If AServerDocument <> Nil Then AServerDocument.Modified := True;
        End;
    Except End;

    Try PcbLib.Board.ViewManager_FullUpdate; Except End;

    Result := BuildSuccessResponse(RequestId,
        '{"success":true,"model_path":"' + EscapeJsonString(ModelPath) +
        '","standoff_mm":' + FloatToStr(Standoff) +
        ',"overall_height_mm":' + FloatToStr(Overall) + '}');
End;


{..............................................................................}
{ Lib_DiagFootprint — list every primitive on the active PcbLib footprint with    }
{ its ObjectId, Layer, and (for ComponentBody) Identifier + a flag indicating    }
{ whether a Model is attached. Diagnostic-only — used to debug "the body was     }
{ added but doesn't render": tells us what layer it's on, whether the STEP       }
{ actually loaded into Body.Model, etc.                                           }
{..............................................................................}
Function Lib_DiagFootprint(Params : String; RequestId : String) : String;
Var
    PcbLib : IPCB_Library;
    LibComp : IPCB_LibComponent;
    Iter : IPCB_GroupIterator;
    Prim : IPCB_Primitive;
    Body : IPCB_ComponentBody;
    JSON, Entry, ObjStr, LayerStr, BBoxStr, HeightStr, ExtraStr : String;
    NumBodies, NumTotal : Integer;
    HasModel : Boolean;
    BRect : TCoordRect;
Begin
    PcbLib := PCBServer.GetCurrentPCBLibrary;
    If PcbLib = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_PCBLIB', 'No PCB library is active');
        Exit;
    End;
    LibComp := PcbLib.CurrentComponent;
    If LibComp = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_FOOTPRINT', 'No footprint is selected');
        Exit;
    End;

    NumBodies := 0;
    NumTotal := 0;
    JSON := '"bodies":[';

    Iter := LibComp.GroupIterator_Create;
    Try
        Iter.AddFilter_ObjectSet(MkSet(eComponentBodyObject));
        Prim := Iter.FirstPCBObject;
        While Prim <> Nil Do
        Begin
            NumTotal := NumTotal + 1;
            Body := Prim;
            If NumBodies > 0 Then JSON := JSON + ',';

            LayerStr := '?';
            Try LayerStr := GetLayerString(Body.Layer); Except End;
            ObjStr := '';
            Try ObjStr := Body.Identifier; Except End;

            HasModel := False;
            Try If Body.Model <> Nil Then HasModel := True; Except End;

            BBoxStr := '';
            Try
                BRect := Body.BoundingRectangle;
                BBoxStr := ',"bbox_w_mm":' + FloatToStr(CoordToMMs(BRect.Right - BRect.Left)) +
                           ',"bbox_h_mm":' + FloatToStr(CoordToMMs(BRect.Top - BRect.Bottom));
            Except End;

            HeightStr := '';
            Try HeightStr := ',"overall_height_mm":' + FloatToStr(CoordToMMs(Body.OverallHeight)); Except End;

            { Extra diagnostic properties — used to compare a working body
              against a non-rendering one to find the differentiating prop. }
            { BodyOpacity3D / Kind / Is3DBody / BodyProjection / StandoffHeight
              property reads triggered an ADVPCB.DLL access violation.
              Try/Except can't catch native AVs. Removed. Stick to
              OverallHeight + BoundingRectangle which we've confirmed work. }
            ExtraStr := '';

            If HasModel Then
                Entry := '{"identifier":"' + EscapeJsonString(ObjStr) +
                         '","layer":"'    + EscapeJsonString(LayerStr) +
                         '","has_model":true' + BBoxStr + HeightStr + ExtraStr + '}'
            Else
                Entry := '{"identifier":"' + EscapeJsonString(ObjStr) +
                         '","layer":"'    + EscapeJsonString(LayerStr) +
                         '","has_model":false' + BBoxStr + HeightStr + ExtraStr + '}';
            JSON := JSON + Entry;
            NumBodies := NumBodies + 1;
            Prim := Iter.NextPCBObject;
        End;
    Finally
        LibComp.GroupIterator_Destroy(Iter);
    End;

    JSON := '{"body_count":' + IntToStr(NumBodies) + ',' + JSON + ']}';
    Result := BuildSuccessResponse(RequestId, JSON);
End;

{..............................................................................}
{ Lib_Position3DBody — move every 3D body on the active footprint so its         }
{ centroid lands at (target_x_mm, target_y_mm). Use after a manual               }
{ Place > 3D Body if the body landed off-origin. The footprint's pads sit at     }
{ the footprint origin (0,0 by default), so passing default 0,0 centers the      }
{ body on top of the pads.                                                        }
{                                                                                }
{ Body.MoveToXY takes the SOUTH-WEST corner of the body's bounding box, so we    }
{ subtract half-width / half-height from the target to convert "centroid" intent }
{ into the SW coord the API expects. (Pattern from SPI_Cleanup_LPW_Footprint.pas) }
{..............................................................................}
Function Lib_Position3DBody(Params : String; RequestId : String) : String;
Var
    PcbLib : IPCB_Library;
    LibComp : IPCB_LibComponent;
    Iter : IPCB_GroupIterator;
    Body : IPCB_ComponentBody;
    BRect : TCoordRect;
    TargetX, TargetY, HalfW, HalfH, RotZ : Double;
    SwX, SwY, CenterX, CenterY : Integer;
    Moved : Integer;
    SkipMove : Boolean;
    S : String;
Begin
    S := ExtractJsonValue(Params, 'target_x_mm');
    TargetX := StrToFloatDef(S, 0);
    S := ExtractJsonValue(Params, 'target_y_mm');
    TargetY := StrToFloatDef(S, 0);
    S := ExtractJsonValue(Params, 'rotation_z_deg');
    RotZ := StrToFloatDef(S, 0);
    { skip_move=true: only apply rotation, leave the body's existing
      X/Y position alone. Useful when the user has already manually
      placed the body at the right location and just needs orientation
      fixed up. }
    S := ExtractJsonValue(Params, 'skip_move');
    SkipMove := (S = 'true') Or (S = '1');

    PcbLib := PCBServer.GetCurrentPCBLibrary;
    If PcbLib = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_PCBLIB', 'No PCB library is active');
        Exit;
    End;
    LibComp := PcbLib.CurrentComponent;
    If LibComp = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_FOOTPRINT', 'No footprint is selected');
        Exit;
    End;

    Moved := 0;
    Iter := LibComp.GroupIterator_Create;
    Try
        Iter.AddFilter_ObjectSet(MkSet(eComponentBodyObject));
        Body := Iter.FirstPCBObject;
        While Body <> Nil Do
        Begin
            Try
                { ORDER MATTERS: rotate FIRST, then re-center. The model
                  rotation (Model.SetState) may translate the body because
                  the STEP origin isn't always at the geometric center.
                  By doing rotation before MoveToXY, we let MoveToXY
                  read the post-rotation bounding box and place the
                  centroid exactly at (TargetX, TargetY). }

                If RotZ <> 0 Then
                Begin
                    Try
                        If Body.Model <> Nil Then
                            Body.Model.SetState(0, 0, RotZ, 0);
                    Except End;
                End;

                If Not SkipMove Then
                Begin
                    BRect := Body.BoundingRectangle;
                    HalfW := CoordToMMs(BRect.Right - BRect.Left) / 2.0;
                    HalfH := CoordToMMs(BRect.Top - BRect.Bottom) / 2.0;
                    SwX := MMsToCoord(TargetX - HalfW);
                    SwY := MMsToCoord(TargetY - HalfH);
                    Body.MoveToXY(SwX, SwY);
                End;

                Moved := Moved + 1;
            Except End;
            Body := Iter.NextPCBObject;
        End;
    Finally
        LibComp.GroupIterator_Destroy(Iter);
    End;

    Try PcbLib.Board.ViewManager_FullUpdate; Except End;

    Result := BuildSuccessResponse(RequestId,
        '{"success":true,"moved":' + IntToStr(Moved) +
        ',"target_x_mm":' + FloatToStr(TargetX) +
        ',"target_y_mm":' + FloatToStr(TargetY) +
        ',"rotation_z_deg":' + FloatToStr(RotZ) + '}');
End;

{..............................................................................}
{ Lib_ScreenshotFootprint — capture the current PcbLib editor view (2D or 3D     }
{ depending on which mode is active) to a PNG file. Used for AI-driven           }
{ "is the 3D body oriented correctly relative to pin 1?" inspection — the        }
{ multimodal agent reads the file, decides if a flip/rotation is needed, then    }
{ calls position_3d_body with rotation_z_deg.                                    }
{                                                                                }
{ Implementation: uses the same WorkspaceManager:PrintCurrent process that the   }
{ File → Page Setup → Preview → Save image dialog uses. Output format chosen     }
{ by file extension (.png recommended).                                          }
{..............................................................................}
Function Lib_ScreenshotFootprint(Params : String; RequestId : String) : String;
Var
    OutputPath : String;
    PcbLib : IPCB_Library;
Begin
    { Script-side just confirms the PcbLib is focused and forces a view
      refresh. The actual screen capture happens on the Python side via
      Win32 GDI BitBlt — that path is more reliable than any DelphiScript
      export broker. (Pattern from coffeenmusic/altium-mcp.) }
    OutputPath := ExtractJsonValue(Params, 'output_path');

    PcbLib := PCBServer.GetCurrentPCBLibrary;
    If PcbLib = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_PCBLIB', 'No PCB library is active');
        Exit;
    End;

    Try PcbLib.Board.ViewManager_FullUpdate; Except End;

    Result := BuildSuccessResponse(RequestId,
        '{"success":true,"ready_for_capture":true,"output_path":"' + EscapeJsonString(OutputPath) + '"}');
End;

Function Lib_GetComponents(Params : String; RequestId : String) : String;
Var
    LibReader : ILibCompInfoReader;
    CompInfo : IComponentInfo;
    SchLib : ISch_Lib;
    Component : ISch_Component;
    ParamIterator : ISch_Iterator;
    Param : ISch_Parameter;
    Workspace : IWorkspace;
    Doc : IDocument;
    ServerDoc : IServerDocument;
    LibPath, Data, CompName, ParamList, WithParamsStr : String;
    CompNum, I : Integer;
    First, WithParams : Boolean;
Begin
    // Get library path from parameter or active document
    LibPath := ExtractJsonValue(Params, 'library_path');
    LibPath := StringReplace(LibPath, '\\', '\', -1);

    // Optional flag: dump parameters per component. Default is FALSE because
    // GetState_SchComponentByLibRef + parameter iterator runs O(N) and is the
    // bottleneck on large libraries (a 400+ component standard lib takes
    // tens of seconds with parameters on, sub-second without). Callers that
    // need parameters for a specific symbol should use lib_get_component_details.
    WithParamsStr := ExtractJsonValue(Params, 'with_parameters');
    WithParams := (WithParamsStr = 'true') Or (WithParamsStr = 'True') Or (WithParamsStr = '1');

    If LibPath = '' Then
    Begin
        Workspace := GetWorkspace;
        If Workspace <> Nil Then
        Begin
            Doc := Workspace.DM_FocusedDocument;
            If Doc <> Nil Then
            Begin
                // DM_FileName returns just the basename;
                // CreateLibCompInfoReader needs the full path or it
                // silently returns an empty reader (which is exactly the
                // bug that made lib_get_components always report 0).
                Try LibPath := Doc.DM_FullPath; Except End;
                If LibPath = '' Then LibPath := Doc.DM_FileName;
            End;
        End;
    End;

    If LibPath = '' Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_LIBRARY', 'No library path and no active document');
        Exit;
    End;

    { CreateLibCompInfoReader reads the on-disk file directly. If the
      library is open in-editor with unsaved changes, the reader returns
      a stale snapshot — newly created components don't show up until
      the user calls save_all. Force a flush on the matching IServerDocument
      so subsequent ReadAllComponentInfo sees the latest write. }
    Try
        ServerDoc := Client.GetDocumentByPath(LibPath);
        If ServerDoc <> Nil Then
        Begin
            If ServerDoc.Modified Then
                Try ServerDoc.DoFileSave(''); Except End;
        End;
    Except End;

    // Use CreateLibCompInfoReader to enumerate components. ICompInfoReader is
    // a fast metadata reader, it returns CompName, AliasName, PartCount and
    // Description directly from the lib file without loading every symbol's
    // primitives, so the cheap path scales linearly with file IO.
    LibReader := SchServer.CreateLibCompInfoReader(LibPath);
    If LibReader = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'READER_FAILED', 'Failed to create library reader for: ' + LibPath);
        Exit;
    End;

    LibReader.ReadAllComponentInfo;
    CompNum := LibReader.NumComponentInfos;

    // Only navigate to live components when the caller asked for parameters,
    // otherwise we skip GetState_SchComponentByLibRef entirely.
    SchLib := Nil;
    If WithParams Then
        SchLib := SchServer.GetCurrentSchDocument;

    Data := '[';
    First := True;
    For I := 0 To CompNum - 1 Do
    Begin
        If Not First Then Data := Data + ',';
        First := False;
        CompInfo := LibReader.ComponentInfos[I];
        CompName := CompInfo.CompName;

        Data := Data + '{"name":"' + EscapeJsonString(CompName) + '"';
        Try Data := Data + ',"alias_name":"' + EscapeJsonString(CompInfo.AliasName) + '"'; Except End;
        Try Data := Data + ',"part_count":' + IntToStr(CompInfo.PartCount); Except End;
        Data := Data + ',"description":"' + EscapeJsonString(CompInfo.Description) + '"';

        // Slow path, opt-in via with_parameters=true.
        If WithParams Then
        Begin
            ParamList := '';
            If (SchLib <> Nil) And (SchLib.ObjectId = eSchLib) Then
            Begin
                Component := SchLib.GetState_SchComponentByLibRef(CompName);
                If Component <> Nil Then
                Begin
                    ParamIterator := Component.SchIterator_Create;
                    ParamIterator.AddFilter_ObjectSet(MkSet(eParameter));
                    Param := ParamIterator.FirstSchObject;
                    While Param <> Nil Do
                    Begin
                        If ParamList <> '' Then ParamList := ParamList + ',';
                        ParamList := ParamList + '"' + EscapeJsonString(Param.Name) + '":"' + EscapeJsonString(Param.Text) + '"';
                        Param := ParamIterator.NextSchObject;
                    End;
                    Component.SchIterator_Destroy(ParamIterator);
                End;
            End;
            Data := Data + ',"parameters":{' + ParamList + '}';
        End;
        Data := Data + '}';
    End;

    SchServer.DestroyCompInfoReader(LibReader);
    Data := Data + ']';

    Result := BuildSuccessResponse(RequestId, '{"count":' + IntToStr(CompNum) + ',"components":' + Data + '}');
End;

{ Lib_Search - case-insensitive substring search over all open SchLib docs. }
{ The previous implementation invoked Client:FindComponent, which only       }
{ pops the interactive Find Component panel and returns no data, so the     }
{ tool was unusable from an LLM. This handler enumerates SchLib members of  }
{ every workspace project plus the synthetic FreeDocumentsProject (where    }
{ standalone libraries live), opens an ILibCompInfoReader per file (fast,   }
{ no live-component load) and matches CompName / Description / AliasName   }
{ against the query.                                                         }
{                                                                              }
{ Params:                                                                     }
{   query        - substring (case-insensitive). Required.                   }
{   search_type  - 'all' (default) | 'name' | 'description' | 'parameters'. }
{                  'all' tests name + description + alias. 'parameters'     }
{                  also loads each candidate live (slow on big libs).        }
{   library_path - optional, restrict the search to a single .SchLib file.  }
{   limit        - max matches (default 100).                                }
{ Returns a JSON array of {name, alias_name, description, library_path,     }
{ part_count} per match.                                                     }
Function SearchOneLibrary(LibPath, Query, SearchType : String;
    SearchParams : Boolean; SchLib : ISch_Lib;
    Var ResultsJson : String; Var First : Boolean;
    Var Count : Integer; Limit : Integer) : Boolean;
Var
    LibReader : ILibCompInfoReader;
    CompInfo : IComponentInfo;
    Component : ISch_Component;
    ParamIterator : ISch_Iterator;
    Param : ISch_Parameter;
    LowerQuery, CompName, AliasName, Description : String;
    LowerName, LowerAlias, LowerDesc : String;
    NumComps, I : Integer;
    Matched, MatchedParam : Boolean;
Begin
    Result := False;
    LowerQuery := LowerCase(Query);

    LibReader := SchServer.CreateLibCompInfoReader(LibPath);
    If LibReader = Nil Then Exit;

    Try
        LibReader.ReadAllComponentInfo;
        NumComps := LibReader.NumComponentInfos;

        For I := 0 To NumComps - 1 Do
        Begin
            If Count >= Limit Then Break;

            CompInfo := LibReader.ComponentInfos[I];
            CompName := '';
            AliasName := '';
            Description := '';
            Try CompName := CompInfo.CompName; Except End;
            Try AliasName := CompInfo.AliasName; Except End;
            Try Description := CompInfo.Description; Except End;

            LowerName := LowerCase(CompName);
            LowerAlias := LowerCase(AliasName);
            LowerDesc := LowerCase(Description);

            Matched := False;
            If SearchType = 'name' Then
                Matched := Pos(LowerQuery, LowerName) > 0
            Else If SearchType = 'description' Then
                Matched := Pos(LowerQuery, LowerDesc) > 0
            Else
            Begin
                { 'all' / 'parameters' both check name + alias + description }
                { up front. parameters then drops to the slow path on miss. }
                Matched := (Pos(LowerQuery, LowerName) > 0)
                    Or (Pos(LowerQuery, LowerAlias) > 0)
                    Or (Pos(LowerQuery, LowerDesc) > 0);
            End;

            { Slow path, opt-in only via search_type='parameters'. Loads the }
            { live component and walks every parameter's name/value, that's }
            { what makes parameter-search expensive. }
            If (Not Matched) And SearchParams And (SchLib <> Nil) Then
            Begin
                Component := SchLib.GetState_SchComponentByLibRef(CompName);
                If Component <> Nil Then
                Begin
                    MatchedParam := False;
                    ParamIterator := Component.SchIterator_Create;
                    ParamIterator.AddFilter_ObjectSet(MkSet(eParameter));
                    Try
                        Param := ParamIterator.FirstSchObject;
                        While (Param <> Nil) And (Not MatchedParam) Do
                        Begin
                            If (Pos(LowerQuery, LowerCase(Param.Name)) > 0)
                                Or (Pos(LowerQuery, LowerCase(Param.Text)) > 0) Then
                                MatchedParam := True;
                            Param := ParamIterator.NextSchObject;
                        End;
                    Finally
                        Component.SchIterator_Destroy(ParamIterator);
                    End;
                    Matched := MatchedParam;
                End;
            End;

            If Matched Then
            Begin
                If Not First Then ResultsJson := ResultsJson + ',';
                First := False;
                ResultsJson := ResultsJson +
                    '{"name":"' + EscapeJsonString(CompName) +
                    '","alias_name":"' + EscapeJsonString(AliasName) +
                    '","description":"' + EscapeJsonString(Description) +
                    '","library_path":"' + EscapeJsonString(LibPath) +
                    '","part_count":' + IntToStr(CompInfo.PartCount) + '}';
                Inc(Count);
            End;
        End;
    Finally
        SchServer.DestroyCompInfoReader(LibReader);
    End;

    Result := True;
End;

Function Lib_Search(Params : String; RequestId : String) : String;
Var
    Query, SearchType, LibPathFilter : String;
    Workspace : IWorkspace;
    Project : IProject;
    Doc : IDocument;
    FocusedSchLib : ISch_Lib;
    DocPath, ResultsJson : String;
    I, J, Count, Limit : Integer;
    First, IsLib, SearchParams : Boolean;
Begin
    Query := ExtractJsonValue(Params, 'query');
    SearchType := ExtractJsonValue(Params, 'search_type');
    LibPathFilter := ExtractJsonValue(Params, 'library_path');
    LibPathFilter := StringReplace(LibPathFilter, '\\', '\', -1);
    Limit := StrToIntDef(ExtractJsonValue(Params, 'limit'), 100);

    If SearchType = '' Then SearchType := 'all';
    SearchParams := SearchType = 'parameters';

    If Query = '' Then
    Begin
        Result := BuildErrorResponse(RequestId, 'MISSING_PARAMS', 'query is required');
        Exit;
    End;

    Workspace := GetWorkspace;
    If Workspace = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_WORKSPACE', 'No workspace');
        Exit;
    End;

    { Parameter searches need the live component, which only the focused }
    { library exposes. Cache the focused SchLib so SearchOneLibrary can  }
    { pass it through without re-resolving on every match attempt.       }
    FocusedSchLib := Nil;
    If SearchParams Then
    Begin
        Try
            If (SchServer.GetCurrentSchDocument <> Nil)
                And (SchServer.GetCurrentSchDocument.ObjectId = eSchLib) Then
                FocusedSchLib := SchServer.GetCurrentSchDocument;
        Except End;
    End;

    ResultsJson := '';
    First := True;
    Count := 0;

    { Single-library mode short-circuits the workspace walk. }
    If LibPathFilter <> '' Then
        SearchOneLibrary(LibPathFilter, Query, SearchType, SearchParams,
            FocusedSchLib, ResultsJson, First, Count, Limit)
    Else
    Begin
        For I := 0 To Workspace.DM_ProjectCount - 1 Do
        Begin
            If Count >= Limit Then Break;
            Project := Workspace.DM_Projects(I);
            If Project = Nil Then Continue;
            For J := 0 To Project.DM_LogicalDocumentCount - 1 Do
            Begin
                If Count >= Limit Then Break;
                Doc := Project.DM_LogicalDocuments(J);
                If Doc = Nil Then Continue;
                IsLib := False;
                Try
                    DocPath := Doc.DM_FullPath;
                    IsLib := (UpperCase(Doc.DM_DocumentKind) = 'SCHLIB')
                        Or (Pos('.SCHLIB', UpperCase(DocPath)) > 0);
                Except End;
                If Not IsLib Then Continue;
                SearchOneLibrary(DocPath, Query, SearchType, SearchParams,
                    FocusedSchLib, ResultsJson, First, Count, Limit);
            End;
        End;

        { Free documents (libraries opened standalone, not in any project) }
        Try
            Project := Workspace.DM_FreeDocumentsProject;
            If Project <> Nil Then
            Begin
                For J := 0 To Project.DM_LogicalDocumentCount - 1 Do
                Begin
                    If Count >= Limit Then Break;
                    Doc := Project.DM_LogicalDocuments(J);
                    If Doc = Nil Then Continue;
                    IsLib := False;
                    Try
                        DocPath := Doc.DM_FullPath;
                        IsLib := (UpperCase(Doc.DM_DocumentKind) = 'SCHLIB')
                            Or (Pos('.SCHLIB', UpperCase(DocPath)) > 0);
                    Except End;
                    If Not IsLib Then Continue;
                    SearchOneLibrary(DocPath, Query, SearchType, SearchParams,
                        FocusedSchLib, ResultsJson, First, Count, Limit);
                End;
            End;
        Except End;
    End;

    Result := BuildSuccessResponse(RequestId,
        '{"query":"' + EscapeJsonString(Query) +
        '","search_type":"' + EscapeJsonString(SearchType) +
        '","count":' + IntToStr(Count) +
        ',"limit":' + IntToStr(Limit) +
        ',"truncated":' + BoolToJsonStr(Count >= Limit) +
        ',"results":[' + ResultsJson + ']}');
End;

{ Lib_GetComponentDetails - full inspection of one library component.        }
{ Returns metadata (name, description, part_count, alias_name) PLUS pins,    }
{ parameters, and full visual-style records for the designator, the comment, }
{ and every parameter (font_id, color, is_hidden, x, y, orientation,        }
{ justification). FontId can be expanded into a {name, size, bold, italic}  }
{ description by calling get_font_spec; we pass it through as an integer    }
{ here so the cost stays on the caller when style detail isn't needed.       }
{                                                                              }
{ Pins/parameters require loading the live ISch_Component, which only the    }
{ SchLib editor can produce, so the target library must be the focused       }
{ SchServer document. If the caller passed a library_path that doesn't       }
{ match the focused doc, we open it via WorkspaceManager:OpenObject before   }
{ resolving. Saves are deferred (see MarkLibDirty), so opening doesn't       }
{ disturb in-flight edits on other libs.                                     }
{                                                                              }
{ Schema breaks vs the previous version (introduced two commits ago):        }
{   designator_prefix (str) -> designator (object {text, font_id, color,    }
{                              is_hidden, x, y, orientation, justification})}
{   pins[].font_id, color, label_hidden added                                }
{   comment (object) added                                                   }
{   parameter_styles (array, parallel to parameters dict) added              }

{ BuildLabelStyleJson reads visual-style props off any ISch_Label-derived    }
{ object (Designator, Comment, Parameter, NetLabel, ...) using late-bound   }
{ accessors. Each access is wrapped in Try/Except since not every property  }
{ is present on every ISch_Label subtype, and DelphiScript fails at runtime }
{ rather than compile time on a missing late-bound property.                 }
Function BuildLabelStyleJson(Lbl : ISch_Label; IncludeText : Boolean) : String;
Var
    Txt : String;
    FontId, ColorVal, OrientVal, JustVal, LocX, LocY : Integer;
    HiddenVal : Boolean;
Begin
    Txt := '';
    FontId := 0;
    ColorVal := 0;
    OrientVal := 0;
    JustVal := 0;
    LocX := 0;
    LocY := 0;
    HiddenVal := False;
    Try Txt := Lbl.Text; Except End;
    Try FontId := Lbl.FontId; Except End;
    Try ColorVal := Lbl.Color; Except End;
    Try HiddenVal := Lbl.IsHidden; Except End;
    Try LocX := CoordToMils(Lbl.Location.X); Except End;
    Try LocY := CoordToMils(Lbl.Location.Y); Except End;
    Try OrientVal := Lbl.Orientation; Except End;
    Try JustVal := Lbl.Justification; Except End;

    Result := '{';
    If IncludeText Then
        Result := Result + '"text":"' + EscapeJsonString(Txt) + '",';
    Result := Result +
        '"font_id":' + IntToStr(FontId) +
        ',"color":' + IntToStr(ColorVal) +
        ',"is_hidden":' + BoolToJsonStr(HiddenVal) +
        ',"x":' + IntToStr(LocX) +
        ',"y":' + IntToStr(LocY) +
        ',"orientation":' + IntToStr(OrientVal) +
        ',"justification":' + IntToStr(JustVal) + '}';
End;

Function Lib_GetComponentDetails(Params : String; RequestId : String) : String;
Var
    ComponentName, LibPath, FocusedPath : String;
    LibReader : ILibCompInfoReader;
    CompInfo : IComponentInfo;
    Workspace : IWorkspace;
    Doc : IDocument;
    SchLib : ISch_Lib;
    Component : ISch_Component;
    PinIterator, ParamIterator : ISch_Iterator;
    Pin : ISch_Pin;
    Param : ISch_Parameter;
    CompNum, I, PinCount : Integer;
    Data, PinList, ParamList, StyleList, ElecStr : String;
    DesignatorJson, CommentJson, Description, AliasName : String;
    PartCount : Integer;
    PinLabelHidden : Boolean;
    First, FirstStyle, FoundInfo : Boolean;
Begin
    ComponentName := ExtractJsonValue(Params, 'component_name');
    LibPath := ExtractJsonValue(Params, 'library_path');
    LibPath := StringReplace(LibPath, '\\', '\', -1);

    If ComponentName = '' Then
    Begin
        Result := BuildErrorResponse(RequestId, 'MISSING_PARAMS', 'component_name is required');
        Exit;
    End;

    Workspace := GetWorkspace;
    If Workspace = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_WORKSPACE', 'No workspace');
        Exit;
    End;

    { Resolve the focused doc's path so we know whether to reopen. }
    FocusedPath := '';
    Doc := Workspace.DM_FocusedDocument;
    If Doc <> Nil Then
        Try FocusedPath := Doc.DM_FullPath; Except End;

    If LibPath = '' Then
        LibPath := FocusedPath;

    If LibPath = '' Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_LIBRARY',
            'No library document is active and no library_path was supplied');
        Exit;
    End;

    { Bring the requested library into focus when it isn't already. }
    If (FocusedPath = '') Or (UpperCase(FocusedPath) <> UpperCase(LibPath)) Then
    Begin
        ResetParameters;
        AddStringParameter('ObjectKind', 'Document');
        AddStringParameter('FileName', LibPath);
        RunProcess('WorkspaceManager:OpenObject');
    End;

    SchLib := SchServer.GetCurrentSchDocument;
    If (SchLib = Nil) Or (SchLib.ObjectId <> eSchLib) Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_SCHLIB',
            'Failed to focus library at ' + LibPath);
        Exit;
    End;

    { Cheap metadata lookup via CompInfoReader: the live component carries }
    { LibReference / ComponentDescription too, but PartCount is on the    }
    { reader's IComponentInfo and not on ISch_Component, so we fetch it   }
    { here. }
    Description := '';
    AliasName := '';
    PartCount := 1;
    FoundInfo := False;
    LibReader := SchServer.CreateLibCompInfoReader(LibPath);
    If LibReader <> Nil Then
    Begin
        Try
            LibReader.ReadAllComponentInfo;
            CompNum := LibReader.NumComponentInfos;
            For I := 0 To CompNum - 1 Do
            Begin
                CompInfo := LibReader.ComponentInfos[I];
                If CompInfo.CompName = ComponentName Then
                Begin
                    Try Description := CompInfo.Description; Except End;
                    Try AliasName := CompInfo.AliasName; Except End;
                    Try PartCount := CompInfo.PartCount; Except End;
                    FoundInfo := True;
                    Break;
                End;
            End;
        Finally
            SchServer.DestroyCompInfoReader(LibReader);
        End;
    End;

    Component := SchLib.GetState_SchComponentByLibRef(ComponentName);
    { Prefer the live Component.PartCount over the CompInfo reader's
      value — the reader has been observed to return PartCount+1 on
      Altium 26.5 (off-by-one, probably counting a shared/OwnerPartId=0
      bucket). The live property matches what Lib_CreateSymbol wrote. }
    If Component <> Nil Then
        Try PartCount := Component.PartCount; Except End;
    If Component = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'COMPONENT_NOT_FOUND',
            'Component not found in library: ' + ComponentName);
        Exit;
    End;

    If Description = '' Then
        Try Description := Component.ComponentDescription; Except End;

    { Designator + Comment full-style records. The sub-objects ARE        }
    { ISch_Label-derived so they expose Text + FontId + Color + IsHidden  }
    { + Location + Orientation + Justification.                            }
    DesignatorJson := '{"text":"","font_id":0,"color":0,"is_hidden":false,"x":0,"y":0,"orientation":0,"justification":0}';
    Try DesignatorJson := BuildLabelStyleJson(Component.Designator, True); Except End;
    CommentJson := '{"text":"","font_id":0,"color":0,"is_hidden":false,"x":0,"y":0,"orientation":0,"justification":0}';
    Try CommentJson := BuildLabelStyleJson(Component.Comment, True); Except End;

    { Pin list. font_id / color come from each pin's own ISch_Pin object  }
    { (it inherits from ISch_GraphicalObject which carries both); pin     }
    { name and pin number share that font/color, separate-font handling   }
    { is not exposed cleanly from DelphiScript. label_hidden is the visual}
    { hide-pin-label flag, distinct from pin.IsHidden which hides the pin }
    { from the canvas entirely.                                            }
    PinList := '';
    First := True;
    PinCount := 0;
    PinIterator := Component.SchIterator_Create;
    PinIterator.AddFilter_ObjectSet(MkSet(ePin));
    Try
        Pin := PinIterator.FirstSchObject;
        While Pin <> Nil Do
        Begin
            If Not First Then PinList := PinList + ',';
            First := False;

            If Pin.Electrical = eElectricInput Then ElecStr := 'input'
            Else If Pin.Electrical = eElectricOutput Then ElecStr := 'output'
            Else If Pin.Electrical = eElectricIO Then ElecStr := 'bidirectional'
            Else If Pin.Electrical = eElectricPassive Then ElecStr := 'passive'
            Else If Pin.Electrical = eElectricPower Then ElecStr := 'power'
            Else If Pin.Electrical = eElectricOpenCollector Then ElecStr := 'open_collector'
            Else If Pin.Electrical = eElectricOpenEmitter Then ElecStr := 'open_emitter'
            Else If Pin.Electrical = eElectricHiZ Then ElecStr := 'hiz'
            Else ElecStr := 'passive';

            { Pin label visibility: ISch_Pin.ShowName / ShowDesignator are }
            { the real flags; combine into a single label_hidden when both }
            { are off so the LLM can flag "neither pin name nor number is }
            { drawn". font_id / color are NOT exposed on ISch_Pin in the   }
            { Schematic API at all (only on the ISch_Label family), so we }
            { intentionally omit them from pins[] rather than fake zeros. }
            PinLabelHidden := False;
            Try PinLabelHidden := (Not Pin.ShowName) And (Not Pin.ShowDesignator); Except End;

            PinList := PinList + '{"designator":"' + EscapeJsonString(Pin.Designator) +
                '","name":"' + EscapeJsonString(Pin.Name) +
                '","electrical_type":"' + ElecStr +
                '","x":' + IntToStr(CoordToMils(Pin.Location.X)) +
                ',"y":' + IntToStr(CoordToMils(Pin.Location.Y)) +
                ',"orientation":' + IntToStr(Pin.Orientation) +
                ',"hidden":' + BoolToJsonStr(Pin.IsHidden) +
                ',"label_hidden":' + BoolToJsonStr(PinLabelHidden) + '}';
            Inc(PinCount);

            Pin := PinIterator.NextSchObject;
        End;
    Finally
        Component.SchIterator_Destroy(PinIterator);
    End;

    { Parameter dict (cheap lookups) plus parameter_styles array (visual). }
    { We iterate parameters once and build both shapes in lockstep so the  }
    { kth entry of parameter_styles always matches the kth iteration order.}
    ParamList := '';
    StyleList := '';
    First := True;
    FirstStyle := True;
    ParamIterator := Component.SchIterator_Create;
    ParamIterator.AddFilter_ObjectSet(MkSet(eParameter));
    Try
        Param := ParamIterator.FirstSchObject;
        While Param <> Nil Do
        Begin
            If Not First Then ParamList := ParamList + ',';
            First := False;
            ParamList := ParamList + '"' + EscapeJsonString(Param.Name) +
                '":"' + EscapeJsonString(Param.Text) + '"';

            If Not FirstStyle Then StyleList := StyleList + ',';
            FirstStyle := False;
            StyleList := StyleList + '{"name":"' + EscapeJsonString(Param.Name) +
                '","value":"' + EscapeJsonString(Param.Text) + '","style":' +
                BuildLabelStyleJson(Param, False) + '}';

            Param := ParamIterator.NextSchObject;
        End;
    Finally
        Component.SchIterator_Destroy(ParamIterator);
    End;

    Data := '{"name":"' + EscapeJsonString(ComponentName) + '"';
    Data := Data + ',"library_path":"' + EscapeJsonString(LibPath) + '"';
    Data := Data + ',"designator":' + DesignatorJson;
    Data := Data + ',"comment":' + CommentJson;
    Data := Data + ',"description":"' + EscapeJsonString(Description) + '"';
    Data := Data + ',"alias_name":"' + EscapeJsonString(AliasName) + '"';
    Data := Data + ',"part_count":' + IntToStr(PartCount);
    Data := Data + ',"pin_count":' + IntToStr(PinCount);
    Data := Data + ',"pins":[' + PinList + ']';
    Data := Data + ',"parameters":{' + ParamList + '}';
    Data := Data + ',"parameter_styles":[' + StyleList + ']}';

    Result := BuildSuccessResponse(RequestId, Data);
End;

Function Lib_BatchSetParams(Params : String; RequestId : String) : String;
Var
    LibPath, BatchPath : String;
    SchLib : ISch_Lib;
    Component : ISch_Component;
    ParamIterator : ISch_Iterator;
    Param : ISch_Parameter;
    NewParam : ISch_Parameter;
    FoundParam : ISch_Parameter;
    Workspace : IWorkspace;
    WDoc : IDocument;
    F : TextFile;
    Line, CompName, ParamName, ParamValue : String;
    PipePos1, PipePos2 : Integer;
    Updated, Created, Failed, LineNum : Integer;
Begin
    LibPath := ExtractJsonValue(Params, 'library_path');
    LibPath := StringReplace(LibPath, '\\', '\', -1);
    BatchPath := ExtractJsonValue(Params, 'batch_file');
    BatchPath := StringReplace(BatchPath, '\\', '\', -1);

    If BatchPath = '' Then
        BatchPath := WorkspaceDir + 'batch_params.txt';

    // Get library path from focused document if not provided
    If LibPath = '' Then
    Begin
        Workspace := GetWorkspace;
        If Workspace <> Nil Then
        Begin
            WDoc := Workspace.DM_FocusedDocument;
            If WDoc <> Nil Then
                LibPath := WDoc.DM_FileName;
        End;
    End;

    // Open the library to make it the current SchServer document
    If LibPath <> '' Then
    Begin
        ResetParameters;
        AddStringParameter('ObjectKind', 'Document');
        AddStringParameter('FileName', LibPath);
        RunProcess('WorkspaceManager:OpenObject');
    End;

    SchLib := SchServer.GetCurrentSchDocument;
    If (SchLib = Nil) Or (SchLib.ObjectId <> eSchLib) Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_SCHLIB', 'No schematic library is active');
        Exit;
    End;

    If Not FileExists(BatchPath) Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_BATCH_FILE', 'Batch file not found: ' + BatchPath);
        Exit;
    End;

    Updated := 0;
    Created := 0;
    Failed := 0;
    LineNum := 0;

    // Begin modification block for undo support
    SchServer.ProcessControl.PreProcess(SchLib, '');
    Try
        AssignFile(F, BatchPath);
        Reset(F);
        Try
            While Not EOF(F) Do
            Begin
                ReadLn(F, Line);
                Inc(LineNum);

                If Line = '' Then Continue;

                // Parse: CompName|ParamName|ParamValue
                PipePos1 := Pos('|', Line);
                If PipePos1 = 0 Then
                Begin
                    Inc(Failed);
                    Continue;
                End;
                CompName := Copy(Line, 1, PipePos1 - 1);
                Line := Copy(Line, PipePos1 + 1, Length(Line));
                PipePos2 := Pos('|', Line);
                If PipePos2 = 0 Then
                Begin
                    Inc(Failed);
                    Continue;
                End;
                ParamName := Copy(Line, 1, PipePos2 - 1);
                ParamValue := Copy(Line, PipePos2 + 1, Length(Line));

                Component := SchLib.GetState_SchComponentByLibRef(CompName);
                If Component = Nil Then
                Begin
                    Inc(Failed);
                    Continue;
                End;

                // Special case: Description is a component property, not a parameter
                If ParamName = 'Description' Then
                Begin
                    Component.ComponentDescription := ParamValue;
                    Inc(Updated);
                    Continue;
                End;

                // Find existing parameter
                FoundParam := Nil;
                ParamIterator := Component.SchIterator_Create;
                ParamIterator.AddFilter_ObjectSet(MkSet(eParameter));
                Param := ParamIterator.FirstSchObject;
                While Param <> Nil Do
                Begin
                    If Param.Name = ParamName Then
                    Begin
                        FoundParam := Param;
                        Break;
                    End;
                    Param := ParamIterator.NextSchObject;
                End;
                Component.SchIterator_Destroy(ParamIterator);

                If FoundParam <> Nil Then
                Begin
                    SchBeginModify(FoundParam);
                    FoundParam.Text := ParamValue;
                    SchEndModify(FoundParam);
                    Inc(Updated);
                End
                Else
                Begin
                    NewParam := SchServer.SchObjectFactory(eParameter, eCreate_Default);
                    If NewParam <> Nil Then
                    Begin
                        NewParam.Name := ParamName;
                        NewParam.Text := ParamValue;
                        SetOwnerPart(NewParam, Component);
                        Component.AddSchObject(NewParam);
                        SchRegisterObject(Component, NewParam);
                        Inc(Created);
                    End
                    Else
                        Inc(Failed);
                End;
            End;
        Finally
            CloseFile(F);
        End;
    Finally
        // End modification block - commit changes
        SchServer.ProcessControl.PostProcess(SchLib, 'Edit');
    End;

    MarkLibDirty(SchLib);
    Result := BuildSuccessResponse(RequestId,
        '{"updated":' + IntToStr(Updated) +
        ',"created":' + IntToStr(Created) +
        ',"failed":' + IntToStr(Failed) +
        ',"total_lines":' + IntToStr(LineNum) + '}');
End;

{..............................................................................}
{ Batch Rename Components                                                      }
{..............................................................................}

Function Lib_BatchRename(Params : String; RequestId : String) : String;
Var
    LibPath, BatchPath : String;
    SchLib : ISch_Lib;
    Component : ISch_Component;
    Workspace : IWorkspace;
    Doc : IDocument;
    ServerDoc : IServerDocument;
    F : TextFile;
    Line, OldName, NewName, Errors : String;
    PipePos : Integer;
    Renamed, Failed, LineNum : Integer;
Begin
    LibPath := ExtractJsonValue(Params, 'library_path');
    LibPath := StringReplace(LibPath, '\\', '\', -1);
    BatchPath := ExtractJsonValue(Params, 'batch_file');
    BatchPath := StringReplace(BatchPath, '\\', '\', -1);
    If BatchPath = '' Then
        BatchPath := WorkspaceDir + 'batch_rename.txt';

    // Get library path from parameter or focused document
    If LibPath = '' Then
    Begin
        Workspace := GetWorkspace;
        If Workspace <> Nil Then
        Begin
            Doc := Workspace.DM_FocusedDocument;
            If Doc <> Nil Then
                LibPath := Doc.DM_FileName;
        End;
    End;

    // Focus the library document to make it the current SchServer document
    If LibPath <> '' Then
    Begin
        ServerDoc := Client.GetDocumentByPath(LibPath);
        If ServerDoc <> Nil Then
            Client.ShowDocument(ServerDoc)
        Else
        Begin
            // Not yet open, open it
            ResetParameters;
            AddStringParameter('ObjectKind', 'Document');
            AddStringParameter('FileName', LibPath);
            RunProcess('WorkspaceManager:OpenObject');
        End;
    End;

    SchLib := SchServer.GetCurrentSchDocument;
    If (SchLib = Nil) Or (SchLib.ObjectId <> eSchLib) Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_SCHLIB', 'No schematic library is active. Provide library_path parameter.');
        Exit;
    End;

    If Not FileExists(BatchPath) Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_BATCH_FILE', 'Batch file not found: ' + BatchPath);
        Exit;
    End;

    Renamed := 0;
    Failed := 0;
    LineNum := 0;
    Errors := '';

    // Begin modification block
    SchServer.ProcessControl.PreProcess(SchLib, '');
    Try
        AssignFile(F, BatchPath);
        Reset(F);
        Try
            While Not EOF(F) Do
            Begin
                ReadLn(F, Line);
                Inc(LineNum);

                If Line = '' Then Continue;

                // Parse: OldName|NewName
                PipePos := Pos('|', Line);
                If PipePos = 0 Then
                Begin
                    Inc(Failed);
                    If Errors <> '' Then Errors := Errors + ';';
                    Errors := Errors + 'line ' + IntToStr(LineNum) + ': malformed (no | separator)';
                    Continue;
                End;
                OldName := Copy(Line, 1, PipePos - 1);
                NewName := Copy(Line, PipePos + 1, Length(Line));

                Component := SchLib.GetState_SchComponentByLibRef(OldName);
                If Component = Nil Then
                Begin
                    Inc(Failed);
                    If Errors <> '' Then Errors := Errors + ';';
                    Errors := Errors + OldName + '->' + NewName + ': component not found';
                    Continue;
                End;

                { Collision check — Altium silently keeps the old name if
                  the target already exists, so flag it up. }
                If SchLib.GetState_SchComponentByLibRef(NewName) <> Nil Then
                Begin
                    Inc(Failed);
                    If Errors <> '' Then Errors := Errors + ';';
                    Errors := Errors + OldName + '->' + NewName + ': target name already exists';
                    Continue;
                End;

                { Per-row Try/Except so a single bad write doesn't abort
                  the whole batch. The remove-and-readd pattern is what
                  actually updates the library's internal name index;
                  just writing Component.LibReference won't propagate. }
                Try
                    SchLib.RemoveSchComponent(Component);
                    Component.LibReference := NewName;
                    SchLib.AddSchComponent(Component);
                    Inc(Renamed);
                Except
                    Inc(Failed);
                    If Errors <> '' Then Errors := Errors + ';';
                    Errors := Errors + OldName + '->' + NewName + ': write raised';
                End;
            End;
        Finally
            CloseFile(F);
        End;
    Finally
        // End modification block - commit changes
        SchServer.ProcessControl.PostProcess(SchLib, 'Edit');
    End;

    SchLib.GraphicallyInvalidate;
    MarkLibDirty(SchLib);

    Result := BuildSuccessResponse(RequestId,
        '{"renamed":' + IntToStr(Renamed) +
        ',"failed":' + IntToStr(Failed) +
        ',"total_lines":' + IntToStr(LineNum) +
        ',"errors":"' + EscapeJsonString(Errors) + '"}');
End;

{..............................................................................}
{ Lib_DeleteComponent — remove a single component from the focused SchLib by    }
{ its LibReference. Pairs with batch_rename for library cleanup workflows.      }
{..............................................................................}
Function Lib_DeleteComponent(Params : String; RequestId : String) : String;
Var
    Name : String;
    SchLib : ISch_Lib;
    Component : ISch_Component;
Begin
    Name := ExtractJsonValue(Params, 'name');
    If Name = '' Then
    Begin
        Result := BuildErrorResponse(RequestId, 'MISSING_PARAM', 'name is required');
        Exit;
    End;

    SchLib := SchServer.GetCurrentSchDocument;
    If (SchLib = Nil) Or (SchLib.ObjectId <> eSchLib) Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_SCHLIB', 'No schematic library is active');
        Exit;
    End;

    Component := SchLib.GetState_SchComponentByLibRef(Name);
    If Component = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'COMPONENT_NOT_FOUND', 'Component not found: ' + Name);
        Exit;
    End;

    SchServer.ProcessControl.PreProcess(SchLib, '');
    Try
        SchLib.RemoveSchComponent(Component);
    Except
        SchServer.ProcessControl.PostProcess(SchLib, 'Edit');
        Result := BuildErrorResponse(RequestId, 'DELETE_FAILED', 'RemoveSchComponent raised on: ' + Name);
        Exit;
    End;
    SchServer.ProcessControl.PostProcess(SchLib, 'Edit');
    MarkLibDirty(SchLib);
    Try SchLib.GraphicallyInvalidate; Except End;

    Result := BuildSuccessResponse(RequestId,
        '{"deleted":true,"name":"' + EscapeJsonString(Name) + '"}');
End;

{..............................................................................}
{ Lib_SetActivePart — change which part of a multi-part SchLib component is     }
{ currently displayed in the editor. Pairs with query_objects' per-part fix     }
{ so callers can drive the editor view to a specific part for inspection.      }
{..............................................................................}
Function Lib_SetActivePart(Params : String; RequestId : String) : String;
Var
    PartIdStr : String;
    PartId, MaxParts : Integer;
    SchLib : ISch_Lib;
    Component : ISch_Component;
Begin
    PartIdStr := ExtractJsonValue(Params, 'part_id');
    PartId := StrToIntDef(PartIdStr, 1);

    SchLib := SchServer.GetCurrentSchDocument;
    If (SchLib = Nil) Or (SchLib.ObjectId <> eSchLib) Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_SCHLIB', 'No schematic library is active');
        Exit;
    End;

    Component := SchLib.CurrentSchComponent;
    If Component = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_COMPONENT', 'No component is selected in the SchLib');
        Exit;
    End;

    MaxParts := Component.PartCount;
    If (PartId < 1) Or (PartId > MaxParts) Then
    Begin
        Result := BuildErrorResponse(RequestId, 'PART_OUT_OF_RANGE',
            'part_id ' + IntToStr(PartId) + ' is outside [1, ' + IntToStr(MaxParts) + ']');
        Exit;
    End;

    Try Component.CurrentPartID := PartId; Except End;
    Try SchLib.GraphicallyInvalidate; Except End;

    Result := BuildSuccessResponse(RequestId,
        '{"part_id":' + IntToStr(PartId) +
        ',"part_count":' + IntToStr(MaxParts) +
        ',"component":"' + EscapeJsonString(Component.LibReference) + '"}');
End;

{..............................................................................}
{ Diff two SchLib files, reports components only in A, only in B, or both   }
{..............................................................................}

Function Lib_DiffLibraries(Params : String; RequestId : String) : String;
Var
    PathA, PathB : String;
    ReaderA, ReaderB : ILibCompInfoReader;
    NumA, NumB, I, J : Integer;
    NameA : String;
    FoundInB : Boolean;
    OnlyA, OnlyB, Common : String;
    CountA, CountB, CountCommon : Integer;
    First : Boolean;
Begin
    PathA := ExtractJsonValue(Params, 'library_a');
    PathA := StringReplace(PathA, '\\', '\', -1);
    PathB := ExtractJsonValue(Params, 'library_b');
    PathB := StringReplace(PathB, '\\', '\', -1);

    If (PathA = '') Or (PathB = '') Then
    Begin Result := BuildErrorResponse(RequestId, 'MISSING_PARAMS', 'library_a and library_b are required'); Exit; End;

    ReaderA := SchServer.CreateLibCompInfoReader(PathA);
    If ReaderA = Nil Then Begin Result := BuildErrorResponse(RequestId, 'READER_FAILED', 'Cannot read library A'); Exit; End;
    ReaderA.ReadAllComponentInfo;
    NumA := ReaderA.NumComponentInfos;

    ReaderB := SchServer.CreateLibCompInfoReader(PathB);
    If ReaderB = Nil Then
    Begin
        SchServer.DestroyCompInfoReader(ReaderA);
        Result := BuildErrorResponse(RequestId, 'READER_FAILED', 'Cannot read library B');
        Exit;
    End;
    ReaderB.ReadAllComponentInfo;
    NumB := ReaderB.NumComponentInfos;

    OnlyA := '';  CountA := 0;
    OnlyB := '';  CountB := 0;
    Common := ''; CountCommon := 0;

    // Find components in A: check if each exists in B
    For I := 0 To NumA - 1 Do
    Begin
        NameA := ReaderA.ComponentInfos[I].CompName;
        FoundInB := False;
        For J := 0 To NumB - 1 Do
        Begin
            If ReaderB.ComponentInfos[J].CompName = NameA Then Begin FoundInB := True; Break; End;
        End;
        If FoundInB Then
        Begin
            If CountCommon > 0 Then Common := Common + ',';
            Common := Common + '"' + EscapeJsonString(NameA) + '"';
            Inc(CountCommon);
        End
        Else
        Begin
            If CountA > 0 Then OnlyA := OnlyA + ',';
            OnlyA := OnlyA + '"' + EscapeJsonString(NameA) + '"';
            Inc(CountA);
        End;
    End;

    // Find components only in B
    For I := 0 To NumB - 1 Do
    Begin
        NameA := ReaderB.ComponentInfos[I].CompName;
        FoundInB := False;
        For J := 0 To NumA - 1 Do
        Begin
            If ReaderA.ComponentInfos[J].CompName = NameA Then Begin FoundInB := True; Break; End;
        End;
        If Not FoundInB Then
        Begin
            If CountB > 0 Then OnlyB := OnlyB + ',';
            OnlyB := OnlyB + '"' + EscapeJsonString(NameA) + '"';
            Inc(CountB);
        End;
    End;

    SchServer.DestroyCompInfoReader(ReaderA);
    SchServer.DestroyCompInfoReader(ReaderB);

    Result := BuildSuccessResponse(RequestId,
        '{"only_in_a":[' + OnlyA + '],"only_in_b":[' + OnlyB + '],"common":[' + Common + ']' +
        ',"count_a":' + IntToStr(NumA) + ',"count_b":' + IntToStr(NumB) +
        ',"only_a":' + IntToStr(CountA) + ',"only_b":' + IntToStr(CountB) +
        ',"shared":' + IntToStr(CountCommon) + '}');
End;

{..............................................................................}
{ Add an arc to the current library symbol                                    }
{ Params: x_center, y_center, radius, start_angle, end_angle, width          }
{..............................................................................}

Function Lib_AddSymbolArc(Params : String; RequestId : String) : String;
Var
    XCenter, YCenter, Radius, StartAngle, EndAngle, Width, OwnerPartId : Integer;
    OwnerPartIdStr : String;
    SchLib : ISch_Lib;
    Component : ISch_Component;
    Arc : ISch_Arc;
Begin
    XCenter := StrToIntDef(ExtractJsonValue(Params, 'x_center'), 0);
    YCenter := StrToIntDef(ExtractJsonValue(Params, 'y_center'), 0);
    Radius := StrToIntDef(ExtractJsonValue(Params, 'radius'), 100);
    StartAngle := StrToIntDef(ExtractJsonValue(Params, 'start_angle'), 0);
    EndAngle := StrToIntDef(ExtractJsonValue(Params, 'end_angle'), 360);
    Width := StrToIntDef(ExtractJsonValue(Params, 'width'), 1);
    If Width < 0 Then Width := 0;
    If Width > 3 Then Width := 3;
    OwnerPartIdStr := ExtractJsonValue(Params, 'owner_part_id');
    If OwnerPartIdStr = '' Then OwnerPartId := 1
    Else OwnerPartId := StrToIntDef(OwnerPartIdStr, 1);

    SchLib := SchServer.GetCurrentSchDocument;
    If (SchLib = Nil) Or (SchLib.ObjectId <> eSchLib) Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_SCHLIB', 'No schematic library is active');
        Exit;
    End;

    Component := GetTargetLibComponent(SchLib);
    If Component = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_COMPONENT', 'No component is selected');
        Exit;
    End;

    Arc := SchServer.SchObjectFactory(eArc, eCreate_Default);
    If Arc <> Nil Then
    Begin
        Arc.Location := Point(MilsToCoord(XCenter), MilsToCoord(YCenter));
        Arc.Radius := MilsToCoord(Radius);
        Arc.StartAngle := StartAngle;
        Arc.EndAngle := EndAngle;
        Arc.LineWidth := Width;
        // Multi-part: 0 = shared across all parts, 1..N = belongs to part K.
        Arc.OwnerPartId := OwnerPartId;
        Arc.OwnerPartDisplayMode := 0;

        SchServer.ProcessControl.PreProcess(SchLib, '');
        SetOwnerPart(Arc, Component);
        Component.AddSchObject(Arc);
        SchRegisterObject(Component, Arc);
        SchServer.ProcessControl.PostProcess(SchLib, 'Edit');

        MarkLibDirty(SchLib);
        Result := BuildSuccessResponse(RequestId, '{"success":true}');
    End
    Else
        Result := BuildErrorResponse(RequestId, 'CREATE_FAILED', 'Failed to create arc');
End;

{..............................................................................}
{ Add a polygon (filled shape) to the current library symbol                  }
{ Params: vertices (comma-separated x,y pairs: "x1,y1,x2,y2,x3,y3,...")     }
{..............................................................................}

Function Lib_AddSymbolPolygon(Params : String; RequestId : String) : String;
Var
    VerticesStr, Token, OwnerPartIdStr : String;
    SchLib : ISch_Lib;
    Component : ISch_Component;
    Polygon : ISch_Polygon;
    Remaining : String;
    CommaPos, VertexCount, X, Y, I, OwnerPartId : Integer;
    XValues, YValues : Array[0..99] Of Integer;
Begin
    VerticesStr := ExtractJsonValue(Params, 'vertices');

    If VerticesStr = '' Then
    Begin
        Result := BuildErrorResponse(RequestId, 'MISSING_PARAMS', 'vertices parameter is required');
        Exit;
    End;

    OwnerPartIdStr := ExtractJsonValue(Params, 'owner_part_id');
    If OwnerPartIdStr = '' Then OwnerPartId := 1
    Else OwnerPartId := StrToIntDef(OwnerPartIdStr, 1);

    SchLib := SchServer.GetCurrentSchDocument;
    If (SchLib = Nil) Or (SchLib.ObjectId <> eSchLib) Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_SCHLIB', 'No schematic library is active');
        Exit;
    End;

    Component := GetTargetLibComponent(SchLib);
    If Component = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_COMPONENT', 'No component is selected');
        Exit;
    End;

    // Parse comma-separated x,y pairs
    VertexCount := 0;
    Remaining := VerticesStr;
    While Remaining <> '' Do
    Begin
        // Get X
        CommaPos := Pos(',', Remaining);
        If CommaPos = 0 Then Break;
        Token := Copy(Remaining, 1, CommaPos - 1);
        Remaining := Copy(Remaining, CommaPos + 1, Length(Remaining));
        X := StrToIntDef(Token, 0);

        // Get Y
        CommaPos := Pos(',', Remaining);
        If CommaPos > 0 Then
        Begin
            Token := Copy(Remaining, 1, CommaPos - 1);
            Remaining := Copy(Remaining, CommaPos + 1, Length(Remaining));
        End
        Else
        Begin
            Token := Remaining;
            Remaining := '';
        End;
        Y := StrToIntDef(Token, 0);

        If VertexCount < 100 Then
        Begin
            XValues[VertexCount] := X;
            YValues[VertexCount] := Y;
            Inc(VertexCount);
        End;
    End;

    If VertexCount < 3 Then
    Begin
        Result := BuildErrorResponse(RequestId, 'INVALID_PARAMS', 'At least 3 vertices are required');
        Exit;
    End;

    Polygon := SchServer.SchObjectFactory(ePolygon, eCreate_Default);
    If Polygon <> Nil Then
    Begin
        Polygon.VerticesCount := VertexCount;
        Polygon.IsSolid := True;
        Polygon.LineWidth := eSmall;
        // Multi-part: 0 = shared across all parts, 1..N = belongs to part K.
        Polygon.OwnerPartId := OwnerPartId;
        Polygon.OwnerPartDisplayMode := 0;

        For I := 1 To VertexCount Do
            Polygon.Vertex[I] := Point(MilsToCoord(XValues[I-1]), MilsToCoord(YValues[I-1]));

        SchServer.ProcessControl.PreProcess(SchLib, '');
        SetOwnerPart(Polygon, Component);
        Component.AddSchObject(Polygon);
        SchRegisterObject(Component, Polygon);
        SchServer.ProcessControl.PostProcess(SchLib, 'Edit');

        MarkLibDirty(SchLib);
        Result := BuildSuccessResponse(RequestId,
            '{"success":true,"vertices":' + IntToStr(VertexCount) + '}');
    End
    Else
        Result := BuildErrorResponse(RequestId, 'CREATE_FAILED', 'Failed to create polygon');
End;

{..............................................................................}
{ Set the description field on a library component                            }
{ Params: component_name, description                                         }
{..............................................................................}

Function Lib_SetComponentDescription(Params : String; RequestId : String) : String;
Var
    CompName, Description : String;
    SchLib : ISch_Lib;
    Component : ISch_Component;
Begin
    CompName := ExtractJsonValue(Params, 'component_name');
    Description := ExtractJsonValue(Params, 'description');

    If CompName = '' Then
    Begin
        Result := BuildErrorResponse(RequestId, 'MISSING_PARAMS', 'component_name parameter is required');
        Exit;
    End;

    SchLib := SchServer.GetCurrentSchDocument;
    If (SchLib = Nil) Or (SchLib.ObjectId <> eSchLib) Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_SCHLIB', 'No schematic library is active');
        Exit;
    End;

    Component := SchLib.GetState_SchComponentByLibRef(CompName);
    If Component = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'COMPONENT_NOT_FOUND', 'Component not found: ' + CompName);
        Exit;
    End;

    SchServer.ProcessControl.PreProcess(SchLib, '');
    SchBeginModify(Component);
    Component.ComponentDescription := Description;
    SchEndModify(Component);
    SchServer.ProcessControl.PostProcess(SchLib, 'Edit');

    MarkLibDirty(SchLib);
    Result := BuildSuccessResponse(RequestId,
        '{"success":true,"component":"' + EscapeJsonString(CompName) +
        '","description":"' + EscapeJsonString(Description) + '"}');
End;

{..............................................................................}
{ Get all pins of the current library component                               }
{ Returns designator, name, electrical type, x, y for each pin               }
{..............................................................................}

Function Lib_GetPinList(Params : String; RequestId : String) : String;
Var
    SchLib : ISch_Lib;
    Component : ISch_Component;
    PinIterator : ISch_Iterator;
    Pin : ISch_Pin;
    JsonItems, ElecStr : String;
    First : Boolean;
    PinCount : Integer;
Begin
    SchLib := SchServer.GetCurrentSchDocument;
    If (SchLib = Nil) Or (SchLib.ObjectId <> eSchLib) Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_SCHLIB', 'No schematic library is active');
        Exit;
    End;

    Component := GetTargetLibComponent(SchLib);
    If Component = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_COMPONENT', 'No component is selected');
        Exit;
    End;

    JsonItems := '';
    First := True;
    PinCount := 0;

    PinIterator := Component.SchIterator_Create;
    PinIterator.AddFilter_ObjectSet(MkSet(ePin));

    Try
        Pin := PinIterator.FirstSchObject;
        While Pin <> Nil Do
        Begin
            If Not First Then JsonItems := JsonItems + ',';
            First := False;

            // Map electrical type to string. Altium uses eElectricIO for
            // bidirectional; eElectricBiDir is undeclared.
            If Pin.Electrical = eElectricInput Then ElecStr := 'input'
            Else If Pin.Electrical = eElectricOutput Then ElecStr := 'output'
            Else If Pin.Electrical = eElectricIO Then ElecStr := 'bidirectional'
            Else If Pin.Electrical = eElectricPassive Then ElecStr := 'passive'
            Else If Pin.Electrical = eElectricPower Then ElecStr := 'power'
            Else If Pin.Electrical = eElectricOpenCollector Then ElecStr := 'open_collector'
            Else If Pin.Electrical = eElectricOpenEmitter Then ElecStr := 'open_emitter'
            Else If Pin.Electrical = eElectricHiZ Then ElecStr := 'hiz'
            Else ElecStr := 'passive';

            JsonItems := JsonItems + '{"designator":"' + EscapeJsonString(Pin.Designator) +
                '","name":"' + EscapeJsonString(Pin.Name) +
                '","electrical_type":"' + ElecStr +
                '","x":' + IntToStr(CoordToMils(Pin.Location.X)) +
                ',"y":' + IntToStr(CoordToMils(Pin.Location.Y)) +
                ',"orientation":' + IntToStr(Pin.Orientation) +
                ',"hidden":' + BoolToJsonStr(Pin.IsHidden) +
                ',"owner_part_id":' + IntToStr(Pin.OwnerPartId) + '}';
            Inc(PinCount);

            Pin := PinIterator.NextSchObject;
        End;
    Finally
        Component.SchIterator_Destroy(PinIterator);
    End;

    Result := BuildSuccessResponse(RequestId,
        '{"count":' + IntToStr(PinCount) +
        ',"component":"' + EscapeJsonString(Component.LibReference) +
        '","part_count":' + IntToStr(Component.PartCount) +
        ',"pins":[' + JsonItems + ']}');
End;

{..............................................................................}
{ Duplicate a component within the same library                               }
{ Params: source_name, new_name                                               }
{..............................................................................}

Function Lib_CopyComponent(Params : String; RequestId : String) : String;
Var
    SourceName, NewName : String;
    SchLib : ISch_Lib;
    SourceComp, NewComp : ISch_Component;
Begin
    SourceName := ExtractJsonValue(Params, 'source_name');
    NewName := ExtractJsonValue(Params, 'new_name');

    If (SourceName = '') Or (NewName = '') Then
    Begin
        Result := BuildErrorResponse(RequestId, 'MISSING_PARAMS', 'source_name and new_name are required');
        Exit;
    End;

    SchLib := SchServer.GetCurrentSchDocument;
    If (SchLib = Nil) Or (SchLib.ObjectId <> eSchLib) Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_SCHLIB', 'No schematic library is active');
        Exit;
    End;

    SourceComp := SchLib.GetState_SchComponentByLibRef(SourceName);
    If SourceComp = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'COMPONENT_NOT_FOUND', 'Source component not found: ' + SourceName);
        Exit;
    End;

    // Check that new name doesn't already exist
    NewComp := SchLib.GetState_SchComponentByLibRef(NewName);
    If NewComp <> Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NAME_EXISTS', 'A component named "' + NewName + '" already exists');
        Exit;
    End;

    // Replicate the component (deep clone)
    NewComp := SourceComp.Replicate;
    If NewComp = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'COPY_FAILED', 'Failed to replicate component');
        Exit;
    End;

    NewComp.LibReference := NewName;

    SchServer.ProcessControl.PreProcess(SchLib, '');
    SchLib.AddSchComponent(NewComp);
    SchServer.ProcessControl.PostProcess(SchLib, 'Edit');

    SchLib.CurrentSchComponent := NewComp;

    MarkLibDirty(SchLib);
    Result := BuildSuccessResponse(RequestId,
        '{"success":true,"source":"' + EscapeJsonString(SourceName) +
        '","new_name":"' + EscapeJsonString(NewName) + '"}');
End;

{..............................................................................}
{ Lib_AddPins - Bulk add pins to the currently-selected library component.     }
{ One PreProcess/PostProcess + one save for the whole batch, so adding 50      }
{ pins to a new IC symbol costs ~1x the overhead of adding one pin.           }
{ Params: pins = '~~'-separated list; each pin has key=value fields joined by  }
{         ';'. Fields: designator, name, x, y, length (mils), rotation        }
{         (0/90/180/270), electrical_type (input/output/bidirectional/        }
{         passive/power/open_collector/open_emitter/hiz), hidden (true/false).}
{..............................................................................}

Function Lib_AddPins(Params : String; RequestId : String) : String;
Var
    PinsStr, Op, Remaining, DefaultOwnerStr : String;
    OpCount, Added, Failed : Integer;
    Designator, Name, ElecType, HiddenStr, OwnerStr : String;
    X, Y, Length, Rotation, OwnerPartId, DefaultOwnerPartId : Integer;
    Hidden : Boolean;
    SchLib : ISch_Lib;
    Component : ISch_Component;
    Pin : ISch_Pin;
    Loc : TLocation;
Begin
    PinsStr := ExtractJsonValue(Params, 'pins');
    If PinsStr = '' Then
    Begin
        Result := BuildErrorResponse(RequestId, 'MISSING_PARAM', 'pins is required');
        Exit;
    End;
    DefaultOwnerStr := ExtractJsonValue(Params, 'default_owner_part_id');
    If DefaultOwnerStr = '' Then DefaultOwnerPartId := 1
    Else DefaultOwnerPartId := StrToIntDef(DefaultOwnerStr, 1);

    SchLib := SchServer.GetCurrentSchDocument;
    If (SchLib = Nil) Or (SchLib.ObjectId <> eSchLib) Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_SCHLIB', 'No schematic library is active');
        Exit;
    End;

    Component := GetTargetLibComponent(SchLib);
    If Component = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_COMPONENT', 'No component is selected');
        Exit;
    End;

    Added := 0;
    Failed := 0;
    OpCount := 0;
    Remaining := PinsStr;

    SchServer.ProcessControl.PreProcess(SchLib, '');
    Try
        While True Do
        Begin
            Op := NextBatchOp(Remaining);
            If Op = '' Then Break;
            OpCount := OpCount + 1;
            Designator := GetBatchField(Op, 'designator');
            Name := GetBatchField(Op, 'name');
            X := StrToIntDef(GetBatchField(Op, 'x'), 0);
            Y := StrToIntDef(GetBatchField(Op, 'y'), 0);
            Length := StrToIntDef(GetBatchField(Op, 'length'), 200);
            Rotation := StrToIntDef(GetBatchField(Op, 'rotation'), 0);
            ElecType := GetBatchField(Op, 'electrical_type');
            HiddenStr := GetBatchField(Op, 'hidden');
            Hidden := (HiddenStr = 'true') Or (HiddenStr = '1');
            OwnerStr := GetBatchField(Op, 'owner_part_id');
            If OwnerStr = '' Then OwnerPartId := DefaultOwnerPartId
            Else OwnerPartId := StrToIntDef(OwnerStr, DefaultOwnerPartId);

            Pin := SchServer.SchObjectFactory(ePin, eCreate_Default);
            If Pin = Nil Then
            Begin
                Inc(Failed);
                Continue;
            End;

            Pin.Designator := Designator;
            Pin.Name := Name;
            { Location is a by-value record, read, mutate, write back.         }
            Loc := Pin.Location;
            Loc.X := MilsToCoord(X);
            Loc.Y := MilsToCoord(Y);
            Pin.Location := Loc;
            Pin.PinLength := MilsToCoord(Length);
            Pin.Orientation := Rotation Div 90;
            Pin.IsHidden := Hidden;
            // Multi-part: 0 = shared across all parts, 1..N = belongs to part K.
            Pin.OwnerPartId := OwnerPartId;
            Pin.OwnerPartDisplayMode := 0;

            If ElecType = 'input' Then Pin.Electrical := eElectricInput
            Else If ElecType = 'output' Then Pin.Electrical := eElectricOutput
            Else If ElecType = 'bidirectional' Then Pin.Electrical := eElectricIO
            Else If ElecType = 'io' Then Pin.Electrical := eElectricIO
            Else If ElecType = 'power' Then Pin.Electrical := eElectricPower
            Else If ElecType = 'open_collector' Then Pin.Electrical := eElectricOpenCollector
            Else If ElecType = 'open_emitter' Then Pin.Electrical := eElectricOpenEmitter
            Else If ElecType = 'hiz' Then Pin.Electrical := eElectricHiZ
            Else Pin.Electrical := eElectricPassive;

            SetOwnerPart(Pin, Component);

            Component.AddSchObject(Pin);
            SchRegisterObject(Component, Pin);
            Inc(Added);
        End;
    Finally
        SchServer.ProcessControl.PostProcess(SchLib, 'Edit');
    End;

    MarkLibDirty(SchLib);

    Result := BuildSuccessResponse(RequestId,
        '{"added":' + IntToStr(Added) + ',"failed":' + IntToStr(Failed)
        + ',"total":' + IntToStr(OpCount) + '}');
End;

{..............................................................................}
{ Lib_AuditStyles - bulk visual-style audit across every component in a       }
{ library. Walks SchLib.SchIterator with eSchComponent filter (live           }
{ components, no per-name GetState_SchComponentByLibRef lookup), and emits    }
{ the designator's full style record per component. Comment / parameter_     }
{ styles / pins are opt-in via flags so the default response stays compact.  }
{                                                                              }
{ Filter mode: when expect_designator_font_id and/or expect_designator_color }
{ are supplied, only components whose designator does NOT match the expected }
{ value go in the output. Without filters, every component is returned.       }
{                                                                              }
{ Params:                                                                     }
{   library_path                  - .SchLib path. Defaults to focused doc.   }
{   with_comment=true             - include comment style record per comp.  }
{   with_parameters=true          - include parameter_styles array per comp.}
{   with_pins=true                - include pins array per comp.             }
{   expect_designator_font_id=N   - filter: trim matches.                    }
{   expect_designator_color=N     - filter: trim matches.                    }
{   limit=5000                    - cap on emitted entries.                  }
{                                                                              }
{ Returns: {library_path, count, mismatch_count, limit, truncated,           }
{          filter_applied, components:[...]}.                                 }
Function Lib_AuditStyles(Params : String; RequestId : String) : String;
Var
    LibPath, FocusedPath, FlagStr : String;
    ExpFontIdStr, ExpColorStr : String;
    HasExpFontId, HasExpColor, FilterApplied : Boolean;
    WithComment, WithParameters, WithPins : Boolean;
    ExpFontId, ExpColor : Integer;
    Workspace : IWorkspace;
    Doc : IDocument;
    SchLib : ISch_Lib;
    LibReader : ILibCompInfoReader;
    CompInfo : IComponentInfo;
    PinIter, ParamIter : ISch_Iterator;
    Component : ISch_Component;
    Pin : ISch_Pin;
    Param : ISch_Parameter;
    DesigLabel : ISch_Label;
    Limit, Count, MismatchCount, PinCount, NumComps, I : Integer;
    DesigFontId, DesigColor : Integer;
    DesigJson, CommentJson, PinList, StyleList, ElecStr, ResultsJson, Entry, CompName : String;
    PinLabelHidden : Boolean;
    First, FirstPin, FirstStyle, Mismatched : Boolean;
Begin
    LibPath := ExtractJsonValue(Params, 'library_path');
    LibPath := StringReplace(LibPath, '\\', '\', -1);

    FlagStr := ExtractJsonValue(Params, 'with_comment');
    WithComment := (FlagStr = 'true') Or (FlagStr = 'True') Or (FlagStr = '1');
    FlagStr := ExtractJsonValue(Params, 'with_parameters');
    WithParameters := (FlagStr = 'true') Or (FlagStr = 'True') Or (FlagStr = '1');
    FlagStr := ExtractJsonValue(Params, 'with_pins');
    WithPins := (FlagStr = 'true') Or (FlagStr = 'True') Or (FlagStr = '1');

    Limit := StrToIntDef(ExtractJsonValue(Params, 'limit'), 5000);

    ExpFontIdStr := ExtractJsonValue(Params, 'expect_designator_font_id');
    ExpColorStr := ExtractJsonValue(Params, 'expect_designator_color');
    HasExpFontId := ExpFontIdStr <> '';
    HasExpColor := ExpColorStr <> '';
    ExpFontId := StrToIntDef(ExpFontIdStr, 0);
    ExpColor := StrToIntDef(ExpColorStr, 0);
    FilterApplied := HasExpFontId Or HasExpColor;

    Workspace := GetWorkspace;
    If Workspace = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_WORKSPACE', 'No workspace');
        Exit;
    End;

    FocusedPath := '';
    Doc := Workspace.DM_FocusedDocument;
    If Doc <> Nil Then
        Try FocusedPath := Doc.DM_FullPath; Except End;

    If LibPath = '' Then LibPath := FocusedPath;
    If LibPath = '' Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_LIBRARY',
            'No library document is active and no library_path was supplied');
        Exit;
    End;

    If (FocusedPath = '') Or (UpperCase(FocusedPath) <> UpperCase(LibPath)) Then
    Begin
        ResetParameters;
        AddStringParameter('ObjectKind', 'Document');
        AddStringParameter('FileName', LibPath);
        RunProcess('WorkspaceManager:OpenObject');
    End;

    SchLib := SchServer.GetCurrentSchDocument;
    If (SchLib = Nil) Or (SchLib.ObjectId <> eSchLib) Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_SCHLIB',
            'Failed to focus library at ' + LibPath);
        Exit;
    End;

    Count := 0;
    MismatchCount := 0;
    ResultsJson := '';
    First := True;

    { Enumerate via ILibCompInfoReader. The schematic SchIterator with        }
    { eSchComponent only walks components placed on a regular SchDoc, NOT    }
    { the symbol entries inside a SchLib. The CompInfoReader gives names    }
    { in document order; for each name we load the live ISch_Component via }
    { GetState_SchComponentByLibRef to read its designator/comment/parameter}
    { style records. This is the same pattern Lib_GetComponents uses.        }
    LibReader := SchServer.CreateLibCompInfoReader(LibPath);
    If LibReader = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'READER_FAILED',
            'Failed to create library reader for ' + LibPath);
        Exit;
    End;

    Try
        LibReader.ReadAllComponentInfo;
        NumComps := LibReader.NumComponentInfos;

        For I := 0 To NumComps - 1 Do
        Begin
            If Count >= Limit Then Break;

            CompInfo := LibReader.ComponentInfos[I];
            CompName := '';
            Try CompName := CompInfo.CompName; Except End;
            If CompName = '' Then Continue;

            Component := SchLib.GetState_SchComponentByLibRef(CompName);
            If Component = Nil Then Continue;

            { Read designator font_id / color via the typed ISch_Label local. }
            { Component.Designator returns ISch_Designator which IS an        }
            { ISch_Label, so the assignment + late-bound property reads       }
            { resolve cleanly at compile time.                                  }
            DesigLabel := Nil;
            DesigFontId := 0;
            DesigColor := 0;
            Try DesigLabel := Component.Designator; Except End;
            If DesigLabel <> Nil Then
            Begin
                Try DesigFontId := DesigLabel.FontId; Except End;
                Try DesigColor := DesigLabel.Color; Except End;
            End;

            Mismatched := False;
            If HasExpFontId And (DesigFontId <> ExpFontId) Then Mismatched := True;
            If HasExpColor And (DesigColor <> ExpColor) Then Mismatched := True;

            { Skip when filter is on and the component matches the expected }
            { style. Without filters, every component is emitted.            }
            If (Not FilterApplied) Or Mismatched Then
            Begin

                DesigJson := '{"text":"","font_id":0,"color":0,"is_hidden":false,"x":0,"y":0,"orientation":0,"justification":0}';
                If DesigLabel <> Nil Then
                    Try DesigJson := BuildLabelStyleJson(DesigLabel, True); Except End;

                Entry := '{"name":"' + EscapeJsonString(CompName) +
                    '","designator":' + DesigJson +
                    ',"mismatched":' + BoolToJsonStr(Mismatched);

                If WithComment Then
                Begin
                    CommentJson := '{"text":"","font_id":0,"color":0,"is_hidden":false,"x":0,"y":0,"orientation":0,"justification":0}';
                    Try CommentJson := BuildLabelStyleJson(Component.Comment, True); Except End;
                    Entry := Entry + ',"comment":' + CommentJson;
                End;

                If WithPins Then
                Begin
                    PinList := '';
                    FirstPin := True;
                    PinCount := 0;
                    PinIter := Component.SchIterator_Create;
                    PinIter.AddFilter_ObjectSet(MkSet(ePin));
                    Try
                        Pin := PinIter.FirstSchObject;
                        While Pin <> Nil Do
                        Begin
                            If Not FirstPin Then PinList := PinList + ',';
                            FirstPin := False;

                            If Pin.Electrical = eElectricInput Then ElecStr := 'input'
                            Else If Pin.Electrical = eElectricOutput Then ElecStr := 'output'
                            Else If Pin.Electrical = eElectricIO Then ElecStr := 'bidirectional'
                            Else If Pin.Electrical = eElectricPassive Then ElecStr := 'passive'
                            Else If Pin.Electrical = eElectricPower Then ElecStr := 'power'
                            Else If Pin.Electrical = eElectricOpenCollector Then ElecStr := 'open_collector'
                            Else If Pin.Electrical = eElectricOpenEmitter Then ElecStr := 'open_emitter'
                            Else If Pin.Electrical = eElectricHiZ Then ElecStr := 'hiz'
                            Else ElecStr := 'passive';

                            PinLabelHidden := False;
                            Try PinLabelHidden := (Not Pin.ShowName) And (Not Pin.ShowDesignator); Except End;

                            PinList := PinList + '{"designator":"' + EscapeJsonString(Pin.Designator) +
                                '","name":"' + EscapeJsonString(Pin.Name) +
                                '","electrical_type":"' + ElecStr +
                                '","x":' + IntToStr(CoordToMils(Pin.Location.X)) +
                                ',"y":' + IntToStr(CoordToMils(Pin.Location.Y)) +
                                ',"orientation":' + IntToStr(Pin.Orientation) +
                                ',"hidden":' + BoolToJsonStr(Pin.IsHidden) +
                                ',"label_hidden":' + BoolToJsonStr(PinLabelHidden) + '}';
                            Inc(PinCount);

                            Pin := PinIter.NextSchObject;
                        End;
                    Finally
                        Component.SchIterator_Destroy(PinIter);
                    End;
                    Entry := Entry + ',"pin_count":' + IntToStr(PinCount) +
                        ',"pins":[' + PinList + ']';
                End;

                If WithParameters Then
                Begin
                    StyleList := '';
                    FirstStyle := True;
                    ParamIter := Component.SchIterator_Create;
                    ParamIter.AddFilter_ObjectSet(MkSet(eParameter));
                    Try
                        Param := ParamIter.FirstSchObject;
                        While Param <> Nil Do
                        Begin
                            If Not FirstStyle Then StyleList := StyleList + ',';
                            FirstStyle := False;
                            StyleList := StyleList + '{"name":"' + EscapeJsonString(Param.Name) +
                                '","value":"' + EscapeJsonString(Param.Text) +
                                '","style":' + BuildLabelStyleJson(Param, False) + '}';
                            Param := ParamIter.NextSchObject;
                        End;
                    Finally
                        Component.SchIterator_Destroy(ParamIter);
                    End;
                    Entry := Entry + ',"parameter_styles":[' + StyleList + ']';
                End;

                Entry := Entry + '}';

                If Not First Then ResultsJson := ResultsJson + ',';
                First := False;
                ResultsJson := ResultsJson + Entry;

                If Mismatched Then Inc(MismatchCount);
                Inc(Count);
            End;
        End;
    Finally
        SchServer.DestroyCompInfoReader(LibReader);
    End;

    Result := BuildSuccessResponse(RequestId,
        '{"library_path":"' + EscapeJsonString(LibPath) + '"' +
        ',"count":' + IntToStr(Count) +
        ',"mismatch_count":' + IntToStr(MismatchCount) +
        ',"limit":' + IntToStr(Limit) +
        ',"truncated":' + BoolToJsonStr(Count >= Limit) +
        ',"filter_applied":' + BoolToJsonStr(FilterApplied) +
        ',"components":[' + ResultsJson + ']}');
End;

{..............................................................................}
{ Lib_SetLabelFormat - bulk OR single-component label-style writer.            }
{                                                                              }
{ Sets any subset of {font_id, color, is_hidden, orientation, justification}  }
{ on a target ISch_Label (designator, comment, or one named parameter) for    }
{ either one component (component_name supplied) or every component in the   }
{ library (component_name omitted). Symmetric counterpart to                  }
{ lib_audit_styles' filtering: when only_mismatched is true (default), the   }
{ handler skips components whose target label already matches every          }
{ specified field, so re-runs after partial application stay idempotent.     }
{                                                                              }
{ The whole edit batch is wrapped in ProcessControl.PreProcess /              }
{ PostProcess('Edit') so Altium's undo stack records it as one step. Each    }
{ label modification is bracketed by SchBeginModify / SchEndModify on the    }
{ ISch_Label so the SchServer broadcasts a refresh for that primitive.      }
{ MarkLibDirty fires once at the end; saves are deferred per the project-    }
{ side perf_deferred_save pattern.                                            }
{                                                                              }
{ Params (any combination of style fields, omitted ones are left untouched): }
{   library_path                  - .SchLib path. Defaults to focused doc.   }
{   component_name                - optional, single-component mode.         }
{   target=designator|comment|parameter:<name>  (default 'designator')      }
{   font_id, color, is_hidden, orientation, justification - new style values }
{   only_mismatched=true|false    (default true) - skip already-compliant   }
{   limit=5000                    - cap on processed components in bulk     }
{                                                                              }
{ Returns: {library_path, target, scope, total, modified, already_compliant, }
{          missing_target, failed, limit, truncated}.                         }
Procedure ResolveTargetLabel(Component : ISch_Component; Target : String;
    Var Lbl : ISch_Label; Var Found : Boolean);
Var
    Iter : ISch_Iterator;
    Param : ISch_Parameter;
    ParamName : String;
Begin
    Lbl := Nil;
    Found := False;

    If Target = 'designator' Then
    Begin
        Try Lbl := Component.Designator; Found := (Lbl <> Nil); Except End;
    End
    Else If Target = 'comment' Then
    Begin
        Try Lbl := Component.Comment; Found := (Lbl <> Nil); Except End;
    End
    Else If Pos('parameter:', Target) = 1 Then
    Begin
        ParamName := Copy(Target, 11, Length(Target) - 10);
        If ParamName = '' Then Exit;
        Iter := Component.SchIterator_Create;
        Iter.AddFilter_ObjectSet(MkSet(eParameter));
        Try
            Param := Iter.FirstSchObject;
            While Param <> Nil Do
            Begin
                If Param.Name = ParamName Then
                Begin
                    Lbl := Param;
                    Found := True;
                    Break;
                End;
                Param := Iter.NextSchObject;
            End;
        Finally
            Component.SchIterator_Destroy(Iter);
        End;
    End;
End;

Function ApplyLabelFormat(Lbl : ISch_Label;
    HasFontId : Boolean; NewFontId : Integer;
    HasColor : Boolean; NewColor : Integer;
    HasIsHidden : Boolean; NewIsHidden : Boolean;
    HasOrientation : Boolean; NewOrientation : Integer;
    HasJustification : Boolean; NewJustification : Integer;
    OnlyMismatched : Boolean) : Integer;
{ Returns 1 if modified, 0 if compliant (skipped), -1 if the write itself     }
{ raised (counted as failed by the caller).                                   }
Var
    Compliant : Boolean;
Begin
    Result := 0;
    If Lbl = Nil Then Exit;

    If OnlyMismatched Then
    Begin
        Compliant := True;
        If HasFontId Then
            Try If Lbl.FontId <> NewFontId Then Compliant := False; Except End;
        If Compliant And HasColor Then
            Try If Lbl.Color <> NewColor Then Compliant := False; Except End;
        If Compliant And HasIsHidden Then
            Try If Lbl.IsHidden <> NewIsHidden Then Compliant := False; Except End;
        If Compliant And HasOrientation Then
            Try If Lbl.Orientation <> NewOrientation Then Compliant := False; Except End;
        If Compliant And HasJustification Then
            Try If Lbl.Justification <> NewJustification Then Compliant := False; Except End;
        If Compliant Then Exit;
    End;

    Try
        SchBeginModify(Lbl);
        If HasFontId Then Lbl.FontId := NewFontId;
        If HasColor Then Lbl.Color := NewColor;
        If HasIsHidden Then Lbl.IsHidden := NewIsHidden;
        If HasOrientation Then Lbl.Orientation := NewOrientation;
        If HasJustification Then Lbl.Justification := NewJustification;
        SchEndModify(Lbl);
        Result := 1;
    Except
        Result := -1;
    End;
End;

Function Lib_SetLabelFormat(Params : String; RequestId : String) : String;
Var
    LibPath, FocusedPath, Target, CompName, FlagStr : String;
    HasFontId, HasColor, HasIsHidden, HasOrientation, HasJustification : Boolean;
    NewFontId, NewColor, NewOrientation, NewJustification : Integer;
    NewIsHidden, OnlyMismatched, Found : Boolean;
    Workspace : IWorkspace;
    Doc : IDocument;
    SchLib : ISch_Lib;
    LibReader : ILibCompInfoReader;
    CompInfo : IComponentInfo;
    Component : ISch_Component;
    Lbl : ISch_Label;
    Limit, Total, Modified, AlreadyCompliant, MissingTarget, Failed, NumComps, I, ApplyResult : Integer;
    Scope : String;
Begin
    LibPath := ExtractJsonValue(Params, 'library_path');
    LibPath := StringReplace(LibPath, '\\', '\', -1);
    Target := ExtractJsonValue(Params, 'target');
    If Target = '' Then Target := 'designator';
    CompName := ExtractJsonValue(Params, 'component_name');

    HasFontId := ExtractJsonValue(Params, 'font_id') <> '';
    NewFontId := StrToIntDef(ExtractJsonValue(Params, 'font_id'), 0);
    HasColor := ExtractJsonValue(Params, 'color') <> '';
    NewColor := StrToIntDef(ExtractJsonValue(Params, 'color'), 0);
    HasIsHidden := ExtractJsonValue(Params, 'is_hidden') <> '';
    NewIsHidden := False;
    FlagStr := ExtractJsonValue(Params, 'is_hidden');
    If (FlagStr = 'true') Or (FlagStr = 'True') Or (FlagStr = '1') Then NewIsHidden := True;
    HasOrientation := ExtractJsonValue(Params, 'orientation') <> '';
    NewOrientation := StrToIntDef(ExtractJsonValue(Params, 'orientation'), 0);
    HasJustification := ExtractJsonValue(Params, 'justification') <> '';
    NewJustification := StrToIntDef(ExtractJsonValue(Params, 'justification'), 0);

    FlagStr := ExtractJsonValue(Params, 'only_mismatched');
    OnlyMismatched := (FlagStr <> 'false') And (FlagStr <> 'False') And (FlagStr <> '0');

    Limit := StrToIntDef(ExtractJsonValue(Params, 'limit'), 5000);

    If (Not HasFontId) And (Not HasColor) And (Not HasIsHidden)
        And (Not HasOrientation) And (Not HasJustification) Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NOTHING_TO_SET',
            'At least one of font_id / color / is_hidden / orientation / justification must be supplied');
        Exit;
    End;

    Workspace := GetWorkspace;
    If Workspace = Nil Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_WORKSPACE', 'No workspace');
        Exit;
    End;

    FocusedPath := '';
    Doc := Workspace.DM_FocusedDocument;
    If Doc <> Nil Then Try FocusedPath := Doc.DM_FullPath; Except End;
    If LibPath = '' Then LibPath := FocusedPath;
    If LibPath = '' Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_LIBRARY',
            'No library document is active and no library_path was supplied');
        Exit;
    End;

    If (FocusedPath = '') Or (UpperCase(FocusedPath) <> UpperCase(LibPath)) Then
    Begin
        ResetParameters;
        AddStringParameter('ObjectKind', 'Document');
        AddStringParameter('FileName', LibPath);
        RunProcess('WorkspaceManager:OpenObject');
    End;

    SchLib := SchServer.GetCurrentSchDocument;
    If (SchLib = Nil) Or (SchLib.ObjectId <> eSchLib) Then
    Begin
        Result := BuildErrorResponse(RequestId, 'NO_SCHLIB',
            'Failed to focus library at ' + LibPath);
        Exit;
    End;

    Total := 0;
    Modified := 0;
    AlreadyCompliant := 0;
    MissingTarget := 0;
    Failed := 0;

    SchServer.ProcessControl.PreProcess(SchLib, '');
    Try
        If CompName <> '' Then
        Begin
            { Single-component mode. }
            Scope := 'single';
            Component := SchLib.GetState_SchComponentByLibRef(CompName);
            If Component = Nil Then
            Begin
                Result := BuildErrorResponse(RequestId, 'COMPONENT_NOT_FOUND',
                    'Component not found in library: ' + CompName);
                Exit;
            End;
            Total := 1;
            ResolveTargetLabel(Component, Target, Lbl, Found);
            If Not Found Then
                Inc(MissingTarget)
            Else
            Begin
                ApplyResult := ApplyLabelFormat(Lbl, HasFontId, NewFontId,
                    HasColor, NewColor, HasIsHidden, NewIsHidden,
                    HasOrientation, NewOrientation, HasJustification, NewJustification,
                    OnlyMismatched);
                If ApplyResult = 1 Then Inc(Modified)
                Else If ApplyResult = 0 Then Inc(AlreadyCompliant)
                Else Inc(Failed);
            End;
        End
        Else
        Begin
            { Bulk mode: walk library via CompInfoReader, same enumeration as }
            { Lib_GetComponents and Lib_AuditStyles.                            }
            Scope := 'bulk';
            LibReader := SchServer.CreateLibCompInfoReader(LibPath);
            If LibReader = Nil Then
            Begin
                Result := BuildErrorResponse(RequestId, 'READER_FAILED',
                    'Failed to create library reader for ' + LibPath);
                Exit;
            End;
            Try
                LibReader.ReadAllComponentInfo;
                NumComps := LibReader.NumComponentInfos;

                For I := 0 To NumComps - 1 Do
                Begin
                    If Total >= Limit Then Break;
                    CompInfo := LibReader.ComponentInfos[I];
                    CompName := '';
                    Try CompName := CompInfo.CompName; Except End;
                    If CompName = '' Then Continue;
                    Component := SchLib.GetState_SchComponentByLibRef(CompName);
                    If Component = Nil Then Continue;
                    Inc(Total);

                    ResolveTargetLabel(Component, Target, Lbl, Found);
                    If Not Found Then
                    Begin
                        Inc(MissingTarget);
                        Continue;
                    End;

                    ApplyResult := ApplyLabelFormat(Lbl, HasFontId, NewFontId,
                        HasColor, NewColor, HasIsHidden, NewIsHidden,
                        HasOrientation, NewOrientation, HasJustification, NewJustification,
                        OnlyMismatched);
                    If ApplyResult = 1 Then Inc(Modified)
                    Else If ApplyResult = 0 Then Inc(AlreadyCompliant)
                    Else Inc(Failed);
                End;
            Finally
                SchServer.DestroyCompInfoReader(LibReader);
            End;
        End;
    Finally
        SchServer.ProcessControl.PostProcess(SchLib, 'Edit');
    End;

    If Modified > 0 Then MarkLibDirty(SchLib);

    Try SchLib.GraphicallyInvalidate; Except End;

    Result := BuildSuccessResponse(RequestId,
        '{"library_path":"' + EscapeJsonString(LibPath) + '"' +
        ',"target":"' + EscapeJsonString(Target) + '"' +
        ',"scope":"' + EscapeJsonString(Scope) + '"' +
        ',"total":' + IntToStr(Total) +
        ',"modified":' + IntToStr(Modified) +
        ',"already_compliant":' + IntToStr(AlreadyCompliant) +
        ',"missing_target":' + IntToStr(MissingTarget) +
        ',"failed":' + IntToStr(Failed) +
        ',"limit":' + IntToStr(Limit) +
        ',"truncated":' + BoolToJsonStr(Total >= Limit) + '}');
End;

{..............................................................................}
{ Command Handler - must be at end                                             }
{..............................................................................}

Function HandleLibraryCommand(Action : String; Params : String; RequestId : String) : String;
Begin
    Case Action Of
        'create_symbol':        Result := Lib_CreateSymbol(Params, RequestId);
        'add_pin':              Result := Lib_AddPin(Params, RequestId);
        'add_pins':             Result := Lib_AddPins(Params, RequestId);
        'add_symbol_rectangle': Result := Lib_AddSymbolRectangle(Params, RequestId);
        'add_symbol_line':      Result := Lib_AddSymbolLine(Params, RequestId);
        'create_footprint':     Result := Lib_CreateFootprint(Params, RequestId);
        'add_footprint_pad':    Result := Lib_AddFootprintPad(Params, RequestId);
        'add_footprint_pads':   Result := Lib_AddFootprintPads(Params, RequestId);
        'create_pcb_footprint': Result := Lib_CreatePCBFootprint(Params, RequestId);
        'add_footprint_track':  Result := Lib_AddFootprintTrack(Params, RequestId);
        'add_footprint_arc':    Result := Lib_AddFootprintArc(Params, RequestId);
        'link_footprint':       Result := Lib_LinkFootprint(Params, RequestId);
        'link_3d_model':        Result := Lib_Link3DModel(Params, RequestId);
        'add_3d_body':          Result := Lib_Add3DBody(Params, RequestId);
        'diag_footprint':       Result := Lib_DiagFootprint(Params, RequestId);
        'position_3d_body':     Result := Lib_Position3DBody(Params, RequestId);
        'screenshot_footprint': Result := Lib_ScreenshotFootprint(Params, RequestId);
        'get_components':       Result := Lib_GetComponents(Params, RequestId);
        'search':               Result := Lib_Search(Params, RequestId);
        'get_component_details': Result := Lib_GetComponentDetails(Params, RequestId);
        'batch_set_params':    Result := Lib_BatchSetParams(Params, RequestId);
        'batch_rename':        Result := Lib_BatchRename(Params, RequestId);
        'diff_libraries':     Result := Lib_DiffLibraries(Params, RequestId);
        'add_symbol_arc':     Result := Lib_AddSymbolArc(Params, RequestId);
        'add_symbol_polygon': Result := Lib_AddSymbolPolygon(Params, RequestId);
        'set_component_description': Result := Lib_SetComponentDescription(Params, RequestId);
        'get_pin_list':       Result := Lib_GetPinList(Params, RequestId);
        'copy_component':     Result := Lib_CopyComponent(Params, RequestId);
        'audit_styles':       Result := Lib_AuditStyles(Params, RequestId);
        'set_label_format':   Result := Lib_SetLabelFormat(Params, RequestId);
        'delete_component':   Result := Lib_DeleteComponent(Params, RequestId);
        'set_active_part':    Result := Lib_SetActivePart(Params, RequestId);
    Else
        Result := BuildErrorResponse(RequestId, 'UNKNOWN_ACTION', 'Unknown library action: ' + Action);
    End;
End;

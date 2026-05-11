object StatusForm: TStatusForm
  Left = 200
  Top = 200
  BorderIcons = [biSystemMenu, biMinimize]
  BorderStyle = bsSizeable
  Caption = 'EDA Agent MCP'
  ClientHeight = 620
  ClientWidth = 480
  Color = $00141414
  Font.Charset = DEFAULT_CHARSET
  Font.Color = $00E8E8E8
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  FormStyle = fsStayOnTop
  OldCreateOrder = False
  ParentFont = False
  Position = poScreenCenter
  PixelsPerInch = 96
  TextHeight = 15
  OnClose = StatusFormClose
  object pnl_Top: TPanel
    Left = 0
    Top = 0
    Width = 480
    Height = 124
    Align = alTop
    BevelOuter = bvNone
    Color = $001C1C1C
    object pnl_StatusDot: TPanel
      Left = 16
      Top = 18
      Width = 10
      Height = 10
      BevelOuter = bvNone
      Caption = ''
      Color = $0064C864
    end
    object lbl_Status: TLabel
      Left = 32
      Top = 12
      Width = 360
      Height = 22
      AutoSize = False
      EllipsisPosition = epEndEllipsis
      Caption = 'EDA Agent MCP'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = $00F8F8F8
      Font.Height = -16
      Font.Name = 'Segoe UI Semibold'
      Font.Style = []
      ParentFont = False
    end
    object lbl_Version: TLabel
      Left = 392
      Top = 16
      Width = 76
      Height = 16
      Alignment = taRightJustify
      AutoSize = False
      Caption = 'v?'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = $00707070
      Font.Height = -11
      Font.Name = 'Consolas'
      Font.Style = []
      ParentFont = False
    end
    object pnl_Divider1: TPanel
      Left = 16
      Top = 42
      Width = 448
      Height = 1
      BevelOuter = bvNone
      Caption = ''
      Color = $00282828
    end
    object pnl_Stats: TPanel
      Left = 16
      Top = 52
      Width = 448
      Height = 60
      BevelOuter = bvNone
      Color = $001C1C1C
      object lbl_LblUp: TLabel
        Left = 0
        Top = 4
        Width = 112
        Height = 14
        Alignment = taCenter
        AutoSize = False
        Caption = 'UPTIME'
        Font.Charset = DEFAULT_CHARSET
        Font.Color = $00808080
        Font.Height = -9
        Font.Name = 'Segoe UI'
        Font.Style = [fsBold]
        ParentFont = False
      end
      object lbl_ValUp: TLabel
        Left = 0
        Top = 22
        Width = 112
        Height = 28
        Alignment = taCenter
        AutoSize = False
        Caption = '0s'
        Font.Charset = DEFAULT_CHARSET
        Font.Color = $00F0F0F0
        Font.Height = -19
        Font.Name = 'Consolas'
        Font.Style = []
        ParentFont = False
      end
      object lbl_LblReq: TLabel
        Left = 112
        Top = 4
        Width = 112
        Height = 14
        Alignment = taCenter
        AutoSize = False
        Caption = 'REQUESTS'
        Font.Charset = DEFAULT_CHARSET
        Font.Color = $00808080
        Font.Height = -9
        Font.Name = 'Segoe UI'
        Font.Style = [fsBold]
        ParentFont = False
      end
      object lbl_ValReq: TLabel
        Left = 112
        Top = 22
        Width = 112
        Height = 28
        Alignment = taCenter
        AutoSize = False
        Caption = '0'
        Font.Charset = DEFAULT_CHARSET
        Font.Color = $00F0F0F0
        Font.Height = -19
        Font.Name = 'Consolas'
        Font.Style = []
        ParentFont = False
      end
      object lbl_LblMs: TLabel
        Left = 224
        Top = 4
        Width = 112
        Height = 14
        Alignment = taCenter
        AutoSize = False
        Caption = 'ALTIUM MS'
        Font.Charset = DEFAULT_CHARSET
        Font.Color = $00808080
        Font.Height = -9
        Font.Name = 'Segoe UI'
        Font.Style = [fsBold]
        ParentFont = False
      end
      object lbl_ValMs: TLabel
        Left = 224
        Top = 22
        Width = 112
        Height = 28
        Alignment = taCenter
        AutoSize = False
        Caption = '0'
        Font.Charset = DEFAULT_CHARSET
        Font.Color = $00F0F0F0
        Font.Height = -19
        Font.Name = 'Consolas'
        Font.Style = []
        ParentFont = False
      end
      object lbl_LblStop: TLabel
        Left = 336
        Top = 4
        Width = 112
        Height = 14
        Alignment = taCenter
        AutoSize = False
        Caption = 'DETACH IN'
        Font.Charset = DEFAULT_CHARSET
        Font.Color = $00808080
        Font.Height = -9
        Font.Name = 'Segoe UI'
        Font.Style = [fsBold]
        ParentFont = False
      end
      object lbl_ValStop: TLabel
        Left = 336
        Top = 22
        Width = 112
        Height = 28
        Alignment = taCenter
        AutoSize = False
        Caption = '60s'
        Font.Charset = DEFAULT_CHARSET
        Font.Color = $00F0F0F0
        Font.Height = -19
        Font.Name = 'Consolas'
        Font.Style = []
        ParentFont = False
      end
    end
  end
  object pnl_ErrBar: TPanel
    Left = 0
    Top = 124
    Width = 480
    Height = 24
    Align = alTop
    BevelOuter = bvNone
    Color = $00141414
    object lbl_LastErr: TLabel
      Left = 16
      Top = 5
      Width = 448
      Height = 14
      AutoSize = False
      EllipsisPosition = epEndEllipsis
      Caption = ''
      Font.Charset = DEFAULT_CHARSET
      Font.Color = $005C7CFF
      Font.Height = -11
      Font.Name = 'Consolas'
      Font.Style = []
      ParentFont = False
    end
  end
  object pnl_Controls: TPanel
    Left = 0
    Top = 148
    Width = 480
    Height = 56
    Align = alTop
    BevelOuter = bvNone
    Color = $00141414
    object btn_Detach: TPanel
      Left = 16
      Top = 8
      Width = 96
      Height = 32
      BevelOuter = bvNone
      Caption = 'Detach'
      Color = $003B2C2C
      Cursor = crHandPoint
      Font.Charset = DEFAULT_CHARSET
      Font.Color = $00B0B0F8
      Font.Height = -12
      Font.Name = 'Segoe UI Semibold'
      Font.Style = []
      ParentFont = False
      TabOrder = 0
      OnClick = btn_DetachClick
      OnMouseEnter = btn_DetachEnter
      OnMouseLeave = btn_DetachLeave
    end
    object btn_ClearLog: TPanel
      Left = 120
      Top = 8
      Width = 96
      Height = 32
      BevelOuter = bvNone
      Caption = 'Clear log'
      Color = $00282828
      Cursor = crHandPoint
      Font.Charset = DEFAULT_CHARSET
      Font.Color = $00E0E0E0
      Font.Height = -12
      Font.Name = 'Segoe UI'
      Font.Style = []
      ParentFont = False
      TabOrder = 1
      OnClick = btn_ClearLogClick
      OnMouseEnter = btn_ClearLogEnter
      OnMouseLeave = btn_ClearLogLeave
    end
    object btn_ResetPerf: TPanel
      Left = 224
      Top = 8
      Width = 96
      Height = 32
      BevelOuter = bvNone
      Caption = 'Reset perf'
      Color = $00282828
      Cursor = crHandPoint
      Font.Charset = DEFAULT_CHARSET
      Font.Color = $00E0E0E0
      Font.Height = -12
      Font.Name = 'Segoe UI'
      Font.Style = []
      ParentFont = False
      TabOrder = 2
      OnClick = btn_ResetPerfClick
      OnMouseEnter = btn_ResetPerfEnter
      OnMouseLeave = btn_ResetPerfLeave
    end
  end
  object pnl_Filters: TPanel
    Left = 0
    Top = 204
    Width = 480
    Height = 40
    Align = alTop
    BevelOuter = bvNone
    Color = $00141414
    object chk_HidePings: TPanel
      Left = 16
      Top = 6
      Width = 180
      Height = 26
      BevelOuter = bvNone
      Alignment = taLeftJustify
      Caption = '  [x] Hide pings'
      Color = $00141414
      Cursor = crHandPoint
      Font.Charset = DEFAULT_CHARSET
      Font.Color = $00C8C8C8
      Font.Height = -11
      Font.Name = 'Consolas'
      Font.Style = []
      ParentFont = False
      TabOrder = 0
      OnClick = chk_HidePingsClick
      OnMouseEnter = chk_HidePingsEnter
      OnMouseLeave = chk_HidePingsLeave
    end
    object chk_OnlySlow: TPanel
      Left = 200
      Top = 6
      Width = 200
      Height = 26
      BevelOuter = bvNone
      Alignment = taLeftJustify
      Caption = '  [ ] Only >100ms'
      Color = $00141414
      Cursor = crHandPoint
      Font.Charset = DEFAULT_CHARSET
      Font.Color = $00C8C8C8
      Font.Height = -11
      Font.Name = 'Consolas'
      Font.Style = []
      ParentFont = False
      TabOrder = 1
      OnClick = chk_OnlySlowClick
      OnMouseEnter = chk_OnlySlowEnter
      OnMouseLeave = chk_OnlySlowLeave
    end
  end
  object pnl_TabBar: TPanel
    Left = 0
    Top = 244
    Width = 480
    Height = 32
    Align = alTop
    BevelOuter = bvNone
    Color = $00141414
    object tab_Log: TPanel
      Left = 16
      Top = 0
      Width = 96
      Height = 32
      BevelOuter = bvNone
      Alignment = taCenter
      Caption = 'Log'
      Color = $00141414
      Cursor = crHandPoint
      Font.Charset = DEFAULT_CHARSET
      Font.Color = $00F0D090
      Font.Height = -12
      Font.Name = 'Segoe UI Semibold'
      Font.Style = []
      ParentFont = False
      TabOrder = 0
      OnClick = tab_LogClick
      OnMouseEnter = tab_LogEnter
      OnMouseLeave = tab_LogLeave
    end
    object tab_Perf: TPanel
      Left = 112
      Top = 0
      Width = 96
      Height = 32
      BevelOuter = bvNone
      Alignment = taCenter
      Caption = 'Perf'
      Color = $00141414
      Cursor = crHandPoint
      Font.Charset = DEFAULT_CHARSET
      Font.Color = $00808080
      Font.Height = -12
      Font.Name = 'Segoe UI'
      Font.Style = []
      ParentFont = False
      TabOrder = 1
      OnClick = tab_PerfClick
      OnMouseEnter = tab_PerfEnter
      OnMouseLeave = tab_PerfLeave
    end
    object pnl_TabUnderlineLog: TPanel
      Left = 16
      Top = 30
      Width = 96
      Height = 2
      BevelOuter = bvNone
      Caption = ''
      Color = $00F0D090
    end
    object pnl_TabUnderlinePerf: TPanel
      Left = 112
      Top = 30
      Width = 96
      Height = 2
      BevelOuter = bvNone
      Caption = ''
      Color = $00141414
    end
  end
  object pnl_Divider2: TPanel
    Left = 0
    Top = 276
    Width = 480
    Height = 1
    Align = alTop
    BevelOuter = bvNone
    Caption = ''
    Color = $00282828
  end
  object mmo_Log: TMemo
    Left = 0
    Top = 277
    Width = 480
    Height = 343
    Align = alClient
    BorderStyle = bsNone
    Color = $00181818
    Font.Charset = DEFAULT_CHARSET
    Font.Color = $00D4D4D4
    Font.Height = -11
    Font.Name = 'Consolas'
    Font.Style = []
    ParentFont = False
    ReadOnly = True
    ScrollBars = ssVertical
    TabOrder = 0
  end
  object mmo_Perf: TMemo
    Left = 0
    Top = 277
    Width = 480
    Height = 343
    Align = alClient
    BorderStyle = bsNone
    Color = $00181818
    Font.Charset = DEFAULT_CHARSET
    Font.Color = $00D4D4D4
    Font.Height = -11
    Font.Name = 'Consolas'
    Font.Style = []
    ParentFont = False
    ReadOnly = True
    ScrollBars = ssVertical
    TabOrder = 1
    Visible = False
  end
end

# SPDX-License-Identifier: Apache-2.0
# dev/setup-mcp.ps1 -- safely add or remove the eda-agent MCP entry in
# both Claude Code (~/.claude.json) and Claude Desktop
# (%APPDATA%\Claude\claude_desktop_config.json).
#
# Why this script exists:
#   Editing claude_desktop_config.json while Claude Desktop is running
#   gets clobbered the next time Desktop auto-saves. This script
#   detects running Desktop processes and either asks you to close it,
#   waits for you, or kills them for you on confirmation -- so the edit
#   sticks.
#
# Usage:
#   .\dev\setup-mcp.ps1                   # add altium MCP to both configs
#   .\dev\setup-mcp.ps1 -Remove           # remove altium MCP from both
#   .\dev\setup-mcp.ps1 -DesktopOnly      # only touch Claude Desktop
#   .\dev\setup-mcp.ps1 -CliOnly          # only touch Claude Code CLI
#   .\dev\setup-mcp.ps1 -DryRun           # show what would happen
#   .\dev\setup-mcp.ps1 -Force            # kill Desktop without prompting
#                                         # (still prompts on actual config change)
#   .\dev\setup-mcp.ps1 -Yes              # auto-confirm config writes
#   .\dev\setup-mcp.ps1 -Name foo \
#                       -Command "C:\path\to\server.exe"
#                       # register a different MCP server (defaults to
#                       # altium + the eda-agent.exe we installed)
#
# Exit codes:
#   0  success / nothing to do
#   1  user cancelled
#   2  bad arguments / unrecoverable error
#   3  could not close Claude Desktop (still running after attempts)

[CmdletBinding()]
param(
    [string]$Name = "altium",
    [string]$Command = (Join-Path $env:LOCALAPPDATA "Programs\Python\Python312\Scripts\eda-agent.exe"),
    [string[]]$Args = @(),
    [hashtable]$Env = @{},
    [switch]$Remove,
    [switch]$CliOnly,
    [switch]$DesktopOnly,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Yes
)

$ErrorActionPreference = "Stop"

# -------------------------------------------------------------------------
# Paths
# -------------------------------------------------------------------------
$CliCfgPath     = Join-Path $env:USERPROFILE ".claude.json"
$DesktopCfgPath = Join-Path $env:APPDATA "Claude\claude_desktop_config.json"

# -------------------------------------------------------------------------
# Output helpers
# -------------------------------------------------------------------------
function Say-Info($msg)  { Write-Host "[setup-mcp] $msg" -ForegroundColor Cyan }
function Say-Ok($msg)    { Write-Host "[setup-mcp] $msg" -ForegroundColor Green }
function Say-Warn($msg)  { Write-Host "[setup-mcp] $msg" -ForegroundColor Yellow }
function Say-Err($msg)   { Write-Host "[setup-mcp] $msg" -ForegroundColor Red }
function Say-Step($msg)  { Write-Host ""; Write-Host "=== $msg ===" -ForegroundColor Magenta }

# -------------------------------------------------------------------------
# JSON IO -- no BOM, deep clone safe, preserves unrelated keys
# -------------------------------------------------------------------------
function Read-Json($path) {
    if (-not (Test-Path $path)) { return $null }
    $raw = Get-Content $path -Raw -ErrorAction Stop
    if (-not $raw -or -not $raw.Trim()) { return [PSCustomObject]@{} }
    return ConvertFrom-Json $raw
}

function Write-Json($path, $obj) {
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    # ConvertTo-Json default depth is shallow; use 30 for safety.
    $json = $obj | ConvertTo-Json -Depth 30
    # Write UTF-8 WITHOUT BOM. PowerShell 5.1's Set-Content -Encoding utf8
    # writes BOM, which Claude Code can misparse. Use .NET directly.
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Backup-File($path) {
    if (-not (Test-Path $path)) { return $null }
    $bak = "$path.bak-setup-mcp-{0:yyyyMMdd-HHmmss}" -f (Get-Date)
    Copy-Item $path $bak -Force
    return $bak
}

# -------------------------------------------------------------------------
# Build the MCP server entry. CLI uses {type, command, args, env};
# Desktop only requires {command, args}. Be conservative -- emit what
# each side actually consumes.
# -------------------------------------------------------------------------
function New-CliEntry {
    $envObj = New-Object PSCustomObject
    foreach ($k in $Env.Keys) {
        $envObj | Add-Member -NotePropertyName $k -NotePropertyValue $Env[$k] -Force
    }
    return [PSCustomObject]@{
        type    = "stdio"
        command = $Command
        args    = $Args
        env     = $envObj
    }
}

function New-DesktopEntry {
    $entry = [PSCustomObject]@{
        command = $Command
        args    = $Args
    }
    if ($Env.Count -gt 0) {
        $envObj = New-Object PSCustomObject
        foreach ($k in $Env.Keys) {
            $envObj | Add-Member -NotePropertyName $k -NotePropertyValue $Env[$k] -Force
        }
        $entry | Add-Member -NotePropertyName "env" -NotePropertyValue $envObj -Force
    }
    return $entry
}

# -------------------------------------------------------------------------
# Apply (add / remove) the entry to a parsed JSON object. Returns the
# modified object (mutates in place when possible).
# -------------------------------------------------------------------------
function Apply-Entry($cfg, $entry, [switch]$DoRemove) {
    if (-not $cfg) { $cfg = [PSCustomObject]@{} }

    $hasMcpServers = $cfg.PSObject.Properties.Name -contains "mcpServers"

    if ($DoRemove) {
        if ($hasMcpServers -and $cfg.mcpServers -and $cfg.mcpServers.PSObject.Properties.Name -contains $Name) {
            $cfg.mcpServers.PSObject.Properties.Remove($Name)
        }
        return $cfg
    }

    if (-not $hasMcpServers -or -not $cfg.mcpServers) {
        $servers = New-Object PSCustomObject
        $servers | Add-Member -NotePropertyName $Name -NotePropertyValue $entry -Force
        $cfg | Add-Member -NotePropertyName "mcpServers" -NotePropertyValue $servers -Force
    } else {
        $cfg.mcpServers | Add-Member -NotePropertyName $Name -NotePropertyValue $entry -Force
    }
    return $cfg
}

# -------------------------------------------------------------------------
# Claude Desktop process detection / shutdown
# -------------------------------------------------------------------------
function Get-ClaudeDesktopProcs {
    # Filter to processes whose Path is inside %APPDATA%\Claude (the actual
    # desktop app), so we don't accidentally kill a `claude.exe` CLI that
    # the user opened in a terminal.
    $claudeRoot = Join-Path $env:APPDATA "Claude"
    Get-Process -Name "claude" -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and $_.Path.StartsWith($claudeRoot, [StringComparison]::OrdinalIgnoreCase) }
        catch { $false }
    }
}

function Wait-DesktopClosed([int]$timeoutSec = 60) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $procs = Get-ClaudeDesktopProcs
        if (-not $procs) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Stop-Desktop([switch]$Confirm) {
    $procs = Get-ClaudeDesktopProcs
    if (-not $procs) { return $true }

    Say-Warn ("Claude Desktop is running ({0} processes)." -f $procs.Count)
    if (-not $Force -and $Confirm) {
        Write-Host "  Closing options:"
        Write-Host "    [K] Kill all Claude Desktop processes now (you may lose unsaved chat state)"
        Write-Host "    [W] I'll close it manually from the system tray, wait for me (up to 60s)"
        Write-Host "    [C] Cancel -- abort without changes"
        $choice = Read-Host "  Choice [K/W/C]"
        $choice = $choice.Trim().ToUpperInvariant()
        switch ($choice) {
            "K" { } # fall through to kill below
            "W" {
                Say-Info "Waiting up to 60s for Claude Desktop to exit..."
                if (Wait-DesktopClosed 60) {
                    Say-Ok "Claude Desktop closed."
                    return $true
                }
                Say-Err "Timed out waiting. Aborting -- close Desktop and re-run."
                return $false
            }
            default {
                Say-Warn "Cancelled."
                return $false
            }
        }
    }

    Say-Info "Killing $($procs.Count) Claude Desktop process(es)..."
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    if (Wait-DesktopClosed 10) {
        Say-Ok "Claude Desktop closed."
        return $true
    }
    Say-Err "Some Claude Desktop processes did not exit. Investigate via Task Manager."
    return $false
}

# -------------------------------------------------------------------------
# Per-config update flows
# -------------------------------------------------------------------------
function Update-CliConfig {
    Say-Step "Claude Code CLI config -- $CliCfgPath"

    if (-not (Test-Path $CliCfgPath)) {
        if ($Remove) {
            Say-Info "Config does not exist; nothing to remove."
            return $true
        }
        Say-Info "Config does not exist; will create one."
        $cfg = [PSCustomObject]@{}
    } else {
        $cfg = Read-Json $CliCfgPath
    }

    $entry  = New-CliEntry
    $before = if ($cfg.mcpServers) {
        ($cfg.mcpServers.PSObject.Properties.Name -contains $Name)
    } else { $false }

    $cfg = Apply-Entry $cfg $entry -DoRemove:$Remove

    $after = if ($cfg.mcpServers) {
        ($cfg.mcpServers.PSObject.Properties.Name -contains $Name)
    } else { $false }

    $action = if ($Remove) { "remove" } else { "add" }

    if ($DryRun) {
        Say-Info "[dry-run] would $action `"$Name`" in CLI config (was=$before, after=$after)"
        return $true
    }

    if (-not $Yes) {
        Write-Host "About to $action `"$Name`" in:"
        Write-Host "  $CliCfgPath"
        $r = Read-Host "Proceed? [Y/n]"
        if ($r.Trim().ToLowerInvariant() -eq "n") { Say-Warn "Skipped CLI config."; return $false }
    }

    $bak = Backup-File $CliCfgPath
    if ($bak) { Say-Info "Backup: $bak" }
    Write-Json $CliCfgPath $cfg

    # Strip BOM if PowerShell snuck one in (defensive -- our writer doesn't,
    # but if a previous tool did).
    $bytes = [System.IO.File]::ReadAllBytes($CliCfgPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Say-Warn "BOM detected, stripping."
        [System.IO.File]::WriteAllBytes($CliCfgPath, $bytes[3..($bytes.Length-1)])
    }

    Say-Ok "CLI config updated ($action)."
    return $true
}

function Update-DesktopConfig {
    Say-Step "Claude Desktop config -- $DesktopCfgPath"

    if (-not (Test-Path $DesktopCfgPath)) {
        if ($Remove) {
            Say-Info "Config does not exist; nothing to remove."
            return $true
        }
        Say-Info "Config does not exist; will create one."
        $cfg = [PSCustomObject]@{}
    } else {
        $cfg = Read-Json $DesktopCfgPath
    }

    # Critical guard: Desktop must NOT be running.
    if (-not $DryRun) {
        if (-not (Stop-Desktop -Confirm)) {
            Say-Err "Cannot safely edit Desktop config while Desktop is running. Aborting Desktop update."
            return $false
        }
    }

    $entry  = New-DesktopEntry
    $before = if ($cfg.mcpServers) {
        ($cfg.mcpServers.PSObject.Properties.Name -contains $Name)
    } else { $false }

    $cfg = Apply-Entry $cfg $entry -DoRemove:$Remove

    $after = if ($cfg.mcpServers) {
        ($cfg.mcpServers.PSObject.Properties.Name -contains $Name)
    } else { $false }

    $action = if ($Remove) { "remove" } else { "add" }

    if ($DryRun) {
        Say-Info "[dry-run] would $action `"$Name`" in Desktop config (was=$before, after=$after)"
        return $true
    }

    if (-not $Yes) {
        Write-Host "About to $action `"$Name`" in:"
        Write-Host "  $DesktopCfgPath"
        $r = Read-Host "Proceed? [Y/n]"
        if ($r.Trim().ToLowerInvariant() -eq "n") { Say-Warn "Skipped Desktop config."; return $false }
    }

    $bak = Backup-File $DesktopCfgPath
    if ($bak) { Say-Info "Backup: $bak" }
    Write-Json $DesktopCfgPath $cfg

    Say-Ok "Desktop config updated ($action)."
    Say-Info "Reopen Claude Desktop now (it was closed for the edit)."
    return $true
}

# -------------------------------------------------------------------------
# Main
# -------------------------------------------------------------------------
if ($CliOnly -and $DesktopOnly) {
    Say-Err "Cannot pass both -CliOnly and -DesktopOnly."
    exit 2
}

Say-Info "Server name : $Name"
Say-Info "Command     : $Command"
if ($Args.Count -gt 0) { Say-Info "Args        : $($Args -join ' ')" }
Say-Info "Mode        : $(if ($Remove) {'remove'} else {'add'})$(if ($DryRun) {' (dry run)'})"

# Sanity-check the Command path. Skip on -Remove (we don't need the binary
# to exist to delete its registration) and on -DryRun (informational mode).
if (-not $Remove -and -not $DryRun -and -not (Test-Path $Command)) {
    Say-Warn "Command path does not exist on disk: $Command"
    Say-Warn "MCP clients will fail to spawn the server until that file is in place."
    if (-not $Yes) {
        Write-Host "  [E] Enter a different path now"
        Write-Host "  [P] Proceed anyway (file will be there later)"
        Write-Host "  [C] Cancel"
        $r = (Read-Host "  Choice [E/P/C]").Trim().ToUpperInvariant()
        switch ($r) {
            "E" {
                $entered = Read-Host "Enter full path to the MCP server executable"
                $entered = $entered.Trim('"').Trim()
                if (-not $entered) { Say-Err "Empty path. Aborting."; exit 1 }
                $Command = $entered
                Say-Info "Command     : $Command"
                if (-not (Test-Path $Command)) {
                    Say-Warn "That path also doesn't exist; continuing anyway."
                }
            }
            "P" { Say-Info "Proceeding with non-existent path as requested." }
            default { Say-Warn "Cancelled."; exit 1 }
        }
    } else {
        Say-Info "(-Yes given; proceeding without prompt.)"
    }
}

$cliOk     = $true
$desktopOk = $true

if (-not $DesktopOnly) { $cliOk     = Update-CliConfig }
if (-not $CliOnly)     { $desktopOk = Update-DesktopConfig }

Say-Step "Summary"
$cliStatus     = "OK"; if (-not $cliOk)     { $cliStatus     = "SKIPPED / FAILED" }
$desktopStatus = "OK"; if (-not $desktopOk) { $desktopStatus = "SKIPPED / FAILED" }
Say-Info "CLI     : $cliStatus"
Say-Info "Desktop : $desktopStatus"

if (-not $DryRun -and -not $Remove) {
    Write-Host ""
    Write-Host "Verify with:" -ForegroundColor Magenta
    Write-Host "  claude mcp list"
    Write-Host "  (in Claude Desktop) Settings -> Local MCP servers"
}

if (-not ($cliOk -and $desktopOk)) { exit 1 }
exit 0

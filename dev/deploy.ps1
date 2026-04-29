# SPDX-License-Identifier: Apache-2.0
# dev/deploy.ps1 -- fast deploy of eda-agent changes for testing.
#
# Usage:
#   .\dev\deploy.ps1                    # copy .pas/.dfm/.PrjScr to runtime dir
#   .\dev\deploy.ps1 -ReinstallPython   # also pip install -e . (only needed if pyproject.toml or new entry points changed)
#   .\dev\deploy.ps1 -Watch             # watch mode: redeploy on file change
#
# What it does:
#   1. Copies DelphiScript files from <repo>\scripts\altium\ to the runtime
#      location at $env:USERPROFILE\EDA Agent\scripts\, where the Altium
#      Global Project loads them. Skips files whose source mtime is older
#      than the destination's (no-op when nothing changed).
#   2. Optionally re-installs the Python package (rare -- editable install
#      picks up source edits automatically; only re-install when pyproject
#      changed or new console scripts were added).
#   3. Prints the manual reload instructions for Altium and the MCP client.
#
# Why we don't shell out to `eda-agent install-scripts`:
#   It's slower (spawns Python), prompts for overwrite confirmation, and we
#   already know the source/dest layout. Direct Copy-Item is ~50ms.

[CmdletBinding()]
param(
    [switch]$ReinstallPython,
    [switch]$Watch,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

# Resolve repo root from this script's location -- works regardless of cwd.
$RepoRoot   = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$SrcDir     = Join-Path $RepoRoot "scripts\altium"
$DstDir     = Join-Path $env:USERPROFILE "EDA Agent\scripts"
$PyExe      = "C:\Users\logic\AppData\Local\Programs\Python\Python312\python.exe"

function Write-Info($msg) { if (-not $Quiet) { Write-Host "[deploy] $msg" -ForegroundColor Cyan } }
function Write-Ok($msg)   { if (-not $Quiet) { Write-Host "[deploy] $msg" -ForegroundColor Green } }
function Write-Warn2($msg) { Write-Host "[deploy] $msg" -ForegroundColor Yellow }

function Deploy-Scripts {
    if (-not (Test-Path $SrcDir)) {
        Write-Error "Source dir not found: $SrcDir"
    }
    if (-not (Test-Path $DstDir)) {
        Write-Info "Creating destination: $DstDir"
        New-Item -ItemType Directory -Path $DstDir -Force | Out-Null
    }

    $patterns = @("*.pas", "*.dfm", "*.PrjScr")
    $copied   = 0
    $skipped  = 0

    foreach ($pat in $patterns) {
        Get-ChildItem -Path $SrcDir -Filter $pat -File | ForEach-Object {
            $src = $_
            $dst = Join-Path $DstDir $src.Name
            $needsCopy = $true
            if (Test-Path $dst) {
                $dstItem = Get-Item $dst
                if ($src.LastWriteTimeUtc -le $dstItem.LastWriteTimeUtc -and $src.Length -eq $dstItem.Length) {
                    $needsCopy = $false
                }
            }
            if ($needsCopy) {
                Copy-Item -Path $src.FullName -Destination $dst -Force
                $copied++
                Write-Info ("  + " + $src.Name)
            } else {
                $skipped++
            }
        }
    }

    if ($copied -eq 0) {
        Write-Ok "Nothing to do ($skipped files already up to date)."
        return $false
    }
    Write-Ok "$copied file(s) copied, $skipped unchanged."
    return $true
}

function Reinstall-Python {
    if (-not (Test-Path $PyExe)) {
        Write-Error "Python not found at $PyExe. Edit deploy.ps1 if your install path differs."
    }
    Write-Info "pip install -e $RepoRoot"
    & $PyExe -m pip install -e $RepoRoot --quiet
    if ($LASTEXITCODE -ne 0) { Write-Error "pip install failed (exit $LASTEXITCODE)" }
    Write-Ok "Python package reinstalled."
}

function Print-Manual-Steps {
    Write-Host ""
    Write-Host "Next steps (manual):" -ForegroundColor Magenta
    Write-Host "  1. In Altium StatusForm, click Stop (or close the form). This kills the polling loop."
    Write-Host "  2. File -> Run Script... -> Altium_API -> Dispatcher.pas -> StartMCPServer -> Run."
    Write-Host "  3. In Claude Code: type ``/mcp`` then reconnect altium (or restart the session)."
    Write-Host "     For Claude Desktop, fully quit it from tray and reopen."
    Write-Host ""
}

# -- main ----

Write-Info "Repo: $RepoRoot"
Write-Info "Src:  $SrcDir"
Write-Info "Dst:  $DstDir"

if ($ReinstallPython) { Reinstall-Python }

if (-not $Watch) {
    $changed = Deploy-Scripts
    if ($changed) { Print-Manual-Steps }
    exit 0
}

# Watch mode: poll for changes once a second. FileSystemWatcher is more
# efficient but flaky on network / OneDrive paths -- polling is fine for dev.
Write-Info "Watch mode -- polling for changes. Ctrl+C to stop."
$lastDeploy = Get-Date
while ($true) {
    Start-Sleep -Seconds 1
    $newest = Get-ChildItem -Path $SrcDir -Include *.pas,*.dfm,*.PrjScr -File -Recurse |
              Sort-Object LastWriteTimeUtc -Descending |
              Select-Object -First 1
    if ($newest -and $newest.LastWriteTimeUtc -gt $lastDeploy.ToUniversalTime()) {
        Write-Info "Change detected: $($newest.Name)"
        $changed = Deploy-Scripts
        if ($changed) { Print-Manual-Steps }
        $lastDeploy = Get-Date
    }
}

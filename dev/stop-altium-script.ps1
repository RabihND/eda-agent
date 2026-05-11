# SPDX-License-Identifier: Apache-2.0
# dev/stop-altium-script.ps1 -- gracefully stop the Altium MCP polling loop.
#
# Use this when:
#   - The DelphiScript polling loop is hung after an exception dialog
#   - StatusForm Stop button is unresponsive
#   - Altium's Script IDE Stop button doesn't respond
#
# What it does:
#   1. Writes a 'stop' file to the IPC workspace dir. A live polling loop
#      checks for this every poll cycle and exits cleanly. This is the
#      gentlest option and works in ~95% of cases.
#   2. Waits up to 5 seconds for the loop to exit (response file disappears).
#   3. If still hung, prints instructions for manual recovery via Altium's
#      Script IDE -- pressing F2 (Stop) inside the script editor halts a
#      running script even when broken in the debugger.
#
# What this script will NEVER do: kill Altium itself. Altium hosts the
# script in-process, so the only way to "kill the script subprocess" is
# to kill all of Altium and lose unsaved work. That's never appropriate
# automatically. If the IDE manual recovery doesn't work, the user can
# choose to taskkill X2.exe themselves -- this script won't do it for them.

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# Resolve workspace dir the same way the .pas does:
#   1. Pointer file at C:\ProgramData\eda-agent\workspace-path.txt
#   2. Fallback: C:\EDA Agent\workspace\
$PointerFile  = "C:\ProgramData\eda-agent\workspace-path.txt"
$WorkspaceDir = "C:\EDA Agent\workspace\"
if (Test-Path $PointerFile) {
    $line = (Get-Content $PointerFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($line) {
        $line = $line.Trim()
        if ($line) { $WorkspaceDir = $line }
    }
}
if ($WorkspaceDir[-1] -ne '\') { $WorkspaceDir += '\' }

$StopFile = Join-Path $WorkspaceDir "stop"
$RespFile = Join-Path $WorkspaceDir "response.json"

function Write-Info($msg) { Write-Host "[stop] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "[stop] $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "[stop] $msg" -ForegroundColor Yellow }

if (-not (Test-Path $WorkspaceDir)) {
    New-Item -ItemType Directory -Path $WorkspaceDir -Force | Out-Null
}

Write-Info "Writing stop signal to $StopFile"
Set-Content -Path $StopFile -Value "1" -Encoding ascii

# Wait briefly for the loop to clean up. Loop deletes the stop file on exit
# so we use that as our success signal.
Write-Info "Waiting up to 5s for polling loop to acknowledge..."
$deadline = (Get-Date).AddSeconds(5)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 200
    if (-not (Test-Path $StopFile)) {
        Write-Ok "Polling loop exited cleanly. You can re-run StartMCPServer in Altium."
        exit 0
    }
}

Write-Warn2 "Stop file still present after 5s -- the loop is likely hung."
Write-Host ""
Write-Host "Manual recovery (try in this order):" -ForegroundColor Magenta
Write-Host "  1. In Altium's Script editor (the .pas window), click anywhere in the editor"
Write-Host "     so it has focus, then press F2 (Stop) or click the red square in the toolbar."
Write-Host "  2. If F2 is unresponsive, the script is broken in the debugger:"
Write-Host "       - Click OK on any error dialog that's open"
Write-Host "       - Press F9 (Run) to resume execution"
Write-Host "       - Then F2 to Stop"
Write-Host ""
Write-Host "This script will not kill Altium itself -- if the steps above don't work,"
Write-Host "you can manually 'taskkill /F /IM X2.exe' from the command line, but be"
Write-Host "aware that loses unsaved work in any open project."
Write-Host ""

exit 1

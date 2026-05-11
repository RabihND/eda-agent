@echo off
REM dev/stop-altium-script.cmd -- cmd.exe wrapper for stop-altium-script.ps1.
REM
REM Usage from a regular Command Prompt:
REM   dev\stop-altium-script.cmd          -- graceful stop, prompt before kill
REM   dev\stop-altium-script.cmd -Force   -- skip the kill confirmation
REM
REM Why a wrapper: PowerShell carries the actual logic (workspace path
REM resolution, 5s wait for clean exit, instructions, taskkill prompt).
REM Replicating it in pure batch would be brittle. This .cmd just hands
REM through to the PS1 with -ExecutionPolicy Bypass so it runs without
REM the user having to set the system-wide policy.

setlocal
set "SCRIPT_DIR=%~dp0"
set "PS1_PATH=%SCRIPT_DIR%stop-altium-script.ps1"

if not exist "%PS1_PATH%" (
    echo [stop] ERROR: %PS1_PATH% not found.
    echo [stop] Make sure stop-altium-script.ps1 is in the same folder as this .cmd file.
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1_PATH%" %*
exit /b %ERRORLEVEL%

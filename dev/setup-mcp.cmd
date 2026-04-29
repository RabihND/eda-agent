@echo off
REM Wrapper that invokes setup-mcp.ps1 with execution policy bypassed for
REM this call only. Forwards all args.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-mcp.ps1" %*

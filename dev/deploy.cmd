@echo off
REM Wrapper that invokes deploy.ps1 with execution policy bypassed for this
REM call only. Use this if you don't want to permanently change your
REM PowerShell execution policy. Forwards all args.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" %*

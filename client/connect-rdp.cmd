@echo off
rem ---------------------------------------------------------------------------
rem  connect-rdp.cmd - DOUBLE CLICK THIS.
rem
rem  Starts the RDP workflow if nothing is running, waits for the desktop,
rem  stores the credentials and opens Remote Desktop logged in. No typing.
rem
rem  Needs the GitHub CLI:  winget install --id GitHub.cli
rem  (then run "gh auth login" once)
rem
rem  Optional: drop a shortcut to this file on your Desktop or taskbar.
rem ---------------------------------------------------------------------------
setlocal
set "SCRIPT=%~dp0Connect-Rdp.ps1"

where pwsh >nul 2>&1
if %ERRORLEVEL%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -AutoReconnect %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -AutoReconnect %*
)

echo.
echo (press any key to close this window)
pause >nul

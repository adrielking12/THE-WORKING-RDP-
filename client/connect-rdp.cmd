@echo off
rem ---------------------------------------------------------------------------
rem  connect-rdp.cmd - double click this on Windows to look up the newest RDP
rem  session in the GitHub Actions log and connect to it with mstsc.
rem
rem  Needs the GitHub CLI:  winget install GitHub.cli   (then: gh auth login)
rem ---------------------------------------------------------------------------
setlocal
set "SCRIPT=%~dp0get-rdp-info.ps1"

where pwsh >nul 2>&1
if %ERRORLEVEL%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Wait -Launch %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Wait -Launch %*
)

echo.
pause

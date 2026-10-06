@echo off
rem ---------------------------------------------------------------------------
rem  connect-rdp.cmd - DOUBLE CLICK THIS. Nothing else needed.
rem
rem  It makes sure the GitHub CLI is installed, then runs Connect-Rdp.ps1 which
rem  starts the RDP machine, waits for it, saves the password and opens Remote
rem  Desktop already logged in.
rem
rem  Tip: right click this file -> Send to -> Desktop (create shortcut), or pin
rem  the shortcut to your taskbar. Then it really is one click.
rem ---------------------------------------------------------------------------
setlocal
set "SCRIPT=%~dp0Connect-Rdp.ps1"
set "GHDIR=%ProgramFiles%\GitHub CLI"

rem --- 1. the GitHub CLI is the only hard requirement ------------------------
where gh >nul 2>&1 && goto :run
if exist "%GHDIR%\gh.exe" set "PATH=%PATH%;%GHDIR%"
if exist "%GHDIR%\gh.exe" goto :run

where winget >nul 2>&1 || goto :nogh
echo.
echo The GitHub CLI is not installed yet. Installing it now...
echo (accept the prompt if Windows asks for permission)
echo.
winget install --id GitHub.cli -e --accept-source-agreements --accept-package-agreements
set "PATH=%PATH%;%GHDIR%"
goto :run

:nogh
echo.
echo The GitHub CLI is needed and winget is not available on this computer.
echo Install it once from https://cli.github.com then double click this again.
echo.
pause
exit /b 1

rem --- 2. run the connector, preferring PowerShell 7 -------------------------
:run
where pwsh >nul 2>&1 && goto :pwsh7
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -AutoReconnect %*
goto :done

:pwsh7
pwsh -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -AutoReconnect %*

:done
echo.
echo (press any key to close this window)
pause >nul

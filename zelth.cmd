@echo off
rem ============================================================================
rem  Zelth Launcher - Windows start script
rem  Usage: zelth.cmd  (double-click, or from a shell)
rem ============================================================================
setlocal
set "ZDIR=%~dp0"
if "%ZDIR:~-1%"=="\" set "ZDIR=%ZDIR:~0,-1%"

set "ELECTRON=%ZDIR%\node_modules\electron\dist\electron.exe"
if not exist "%ELECTRON%" set "ELECTRON=%ZDIR%\node_modules\.bin\electron.cmd"

if not exist "%ELECTRON%" (
    echo Electron runtime not found in "%ZDIR%\node_modules".
    echo Re-run the installer:  irm https://raw.githubusercontent.com/CradierTech/ZelthLauncher/main/installer/install.ps1 ^| iex
    pause
    exit /b 1
)

rem --no-sandbox is required for the bundled game; harmless on desktop.
start "" "%ELECTRON%" "%ZDIR%" --no-sandbox %*
exit /b 0

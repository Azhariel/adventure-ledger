@echo off
REM wowstats: builds the WoW Forever "Adventure Ledger" dashboard and opens it.
REM Log out of WoW (or /reload) first: SavedVariables are only written then.
REM   wowstats       build and open
REM   wowstats -n    build only (don't open the browser)
REM   wowstats live  start the tray icon, which runs the live server (page refreshes itself on /reload; Live module
REM                  from the combat log) and the hourly AH fetcher, and opens the page
REM   wowstats stop  stop the tray, the live server and the AH fetcher
REM Put a one-line shim on your PATH that calls this file:  @call "<repo>\bin\wowstats.bat" %*
setlocal
set "REPO=%~dp0.."
set "DASH=%REPO%\dashboard"
set "LUA=%LOCALAPPDATA%\Programs\Lua\bin\lua.exe"
if not exist "%LUA%" set "LUA=lua"

if /i "%~1"=="live" (
    call "%DASH%\tray.bat"
    exit /b 0
)
if /i "%~1"=="stop" (
    REM asks the tray (tray_stop file), the server (/stop) and the fetcher (fetcher_stop file) to stop
    powershell -NoProfile -ExecutionPolicy Bypass -File "%DASH%\tray.ps1" -Stop
    exit /b 0
)

REM the AH market data for the page; a failure (or no python) must not stop the build
python "%DASH%\market.py"
pushd "%DASH%"
"%LUA%" build.lua
set "RC=%ERRORLEVEL%"
popd
if not "%RC%"=="0" exit /b %RC%
REM the build may have changed the wanted list (market_wanted.tsv): run the engine again and rebuild only if it
REM wrote a new market.lua ("unchanged", "no data" or a failure keep the page just built)
set "MK="
for /f "delims=" %%r in ('python "%DASH%\market.py"') do set "MK=%%r"
if not "%MK%"=="written" goto built
pushd "%DASH%"
"%LUA%" build.lua
set "RC=%ERRORLEVEL%"
popd
if not "%RC%"=="0" exit /b %RC%
:built

if /i "%~1"=="-n" exit /b 0
REM If the live server is running, open the page from it (the file:// copy has no Live module).
powershell -NoProfile -Command "try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 http://127.0.0.1:8737/ | Out-Null; exit 0 } catch { exit 1 }"
if not errorlevel 1 (
    start "" "http://127.0.0.1:8737/"
    exit /b 0
)
start "" "%REPO%\data\dashboard.html"

@echo off
REM wowstats: builds the WoW Forever "Adventure Ledger" dashboard and opens it.
REM Log out of WoW (or /reload) first: SavedVariables are only written then.
REM   wowstats       build and open
REM   wowstats -n    build only (don't open the browser)
REM   wowstats live  start the live server (page refreshes itself on /reload; Live module from the combat log)
REM   wowstats stop  stop the live server
REM Put a one-line shim on your PATH that calls this file:  @call "<repo>\bin\wowstats.bat" %*
setlocal
set "REPO=%~dp0.."
set "DASH=%REPO%\dashboard"
set "LUA=%LOCALAPPDATA%\Programs\Lua\bin\lua.exe"
if not exist "%LUA%" set "LUA=lua"

if /i "%~1"=="live" (
    call "%DASH%\serve.bat"
    exit /b 0
)
if /i "%~1"=="stop" (
    powershell -NoProfile -Command "try { Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8737/stop -Headers @{ 'X-Ledger' = 'stop' } | Out-Null; 'Live server stopped.' } catch { 'Live server was not running.' }"
    exit /b 0
)

pushd "%DASH%"
"%LUA%" build.lua
set "RC=%ERRORLEVEL%"
popd
if not "%RC%"=="0" exit /b %RC%

if /i "%~1"=="-n" exit /b 0
REM If the live server is running, open the page from it (the file:// copy has no Live module).
powershell -NoProfile -Command "try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 http://127.0.0.1:8737/ | Out-Null; exit 0 } catch { exit 1 }"
if not errorlevel 1 (
    start "" "http://127.0.0.1:8737/"
    exit /b 0
)
start "" "%REPO%\data\dashboard.html"

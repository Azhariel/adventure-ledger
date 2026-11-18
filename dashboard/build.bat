@echo off
rem Builds the dashboard from your SavedVariables and opens it. Log out of WoW (or /reload) first so they are saved.
rem Where WoW is: ledger.cfg in the repo root (copy ledger.cfg.example). The page goes to ..\data\dashboard.html.
set "LUA=%LOCALAPPDATA%\Programs\Lua\bin\lua.exe"
if not exist "%LUA%" set "LUA=lua"
rem The AH market data for the page; a failure (or no python) must not stop the build.
python "%~dp0market.py"
"%LUA%" "%~dp0build.lua"
if errorlevel 1 (
  pause
  exit /b 1
)
rem The build may have changed the wanted list (market_wanted.tsv): run the engine again and rebuild only if it
rem wrote a new market.lua.
set "MK="
for /f "delims=" %%r in ('python "%~dp0market.py"') do set "MK=%%r"
if not "%MK%"=="written" goto open
"%LUA%" "%~dp0build.lua"
if errorlevel 1 (
  pause
  exit /b 1
)
:open
start "" "%~dp0..\data\dashboard.html"

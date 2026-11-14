@echo off
rem Builds the dashboard from your SavedVariables and opens it. Log out of WoW (or /reload) first so they are saved.
rem Where WoW is: ledger.cfg in the repo root (copy ledger.cfg.example). The page goes to ..\data\dashboard.html.
set "LUA=%LOCALAPPDATA%\Programs\Lua\bin\lua.exe"
if not exist "%LUA%" set "LUA=lua"
"%LUA%" "%~dp0build.lua"
if errorlevel 1 (
  pause
  exit /b 1
)
start "" "%~dp0..\data\dashboard.html"

@echo off
rem Installs the Adventure Ledger addons into WoW Forever. Options: -Wow "<folder>"   -Dev (link instead of copy)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
if errorlevel 1 pause

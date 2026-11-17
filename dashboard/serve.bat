@echo off
rem Starts the Adventure Ledger live server in the background (no console window) and opens the page.
rem It rebuilds the page whenever WoW saves (/reload, logout) and streams the combat log to the Live module.
rem Stop it with:  wowstats stop    (or end pythonw.exe in Task Manager). Its messages go to ..\data\server.log.
rem `wowstats live` now starts the tray (tray.bat), which runs this server and the AH fetcher; this file still
rem starts the server alone.
set "PYW=pythonw"
where pythonw >nul 2>&1 || set "PYW=python"
start "" %PYW% "%~dp0server.py" %*

@echo off
rem Starts the Adventure Ledger tray icon (no console window). The tray runs the live server and the AH fetcher,
rem shows their health (green / amber / grey) and has a menu to start, stop, fetch now or start with Windows.
rem `wowstats live` runs this; `wowstats stop` stops the tray and both. Its messages go to the data folder's tray.log.
rem start /min: a hidden PowerShell must get its own console, or it would hide the terminal you typed this in.
start "" /min powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0tray.ps1" %*

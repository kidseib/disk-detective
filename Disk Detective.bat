@echo off
rem Fallback launcher. Prefer DiskDetectiveLauncher.exe.
rem It starts a normal window; there is no server and nothing is installed.
cd /d "%~dp0"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0DiskDetective.ps1"

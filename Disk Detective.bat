@echo off
rem Double-click this file to open Disk Detective.
rem It starts a normal window; there is no server and nothing is installed.
cd /d "%~dp0"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0DiskDetective.ps1"

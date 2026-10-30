@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ForensicAid.ps1" -Install %*
pause

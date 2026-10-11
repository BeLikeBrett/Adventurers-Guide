@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0companion\start-windows.ps1"
if errorlevel 1 pause

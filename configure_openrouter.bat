@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0configure_openrouter.ps1"
pause

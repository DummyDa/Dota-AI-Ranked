@echo off
setlocal
title Dota AI Voice Chat Bridge
pushd "%~dp0"
echo Starting free OpenRouter chat analysis and local Piper voice...
echo Keep this window open while playing. Press Ctrl+C to stop.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start_voice_bridge.ps1"
set "bridge_exit_code=%errorlevel%"
echo.
echo Voice bridge stopped. Exit code: %bridge_exit_code%
popd
pause
exit /b %bridge_exit_code%

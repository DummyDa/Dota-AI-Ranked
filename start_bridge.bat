@echo off
setlocal
title Dota AI Bridge - Recorder
pushd "%~dp0"
if errorlevel 1 goto failed_directory

where python >nul 2>nul
if errorlevel 1 (
    echo Python was not found. Install Python and add it to PATH.
    popd
    pause
    exit /b 1
)

echo Starting Dota AI bridge at http://127.0.0.1:8765
echo Mode: RECORD ONLY. No AI commands will be executed.
echo Keep this window open while recording. Press Ctrl+C to stop.
echo.
python -u "%~dp0bridge_server.py" --data-dir "%~dp0data"
set "bridge_exit_code=%errorlevel%"
echo.
echo Bridge stopped. Exit code: %bridge_exit_code%
popd
pause
exit /b %bridge_exit_code%

:failed_directory
echo Cannot open the bridge directory.
pause
exit /b 1

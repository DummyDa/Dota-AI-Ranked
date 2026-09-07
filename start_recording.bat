@echo off
setlocal
title Spirit Breaker - Human Recorder
cd /d "%~dp0"
echo Record only. No AI commands. Keep this window open while playing.
where python >nul 2>nul || (
  echo Python was not found in PATH.
  pause
  exit /b 1
)
python -u bridge_server.py --data-dir "data\spirit_breaker_human" --snapshot-interval 0.2
pause

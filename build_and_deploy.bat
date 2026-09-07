@echo off
cd /d "%~dp0"
python -m unittest test_bot test_bridge
if errorlevel 1 goto failed
python build_bot.py --deploy
if errorlevel 1 goto failed
echo Build and deployment completed.
pause
exit /b 0
:failed
echo Validation or deployment failed. See output above.
pause
exit /b 1

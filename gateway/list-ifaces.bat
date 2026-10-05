@echo off
cd /d "%~dp0"
where py >nul 2>&1
if %errorlevel%==0 (
  py -3 run.py --list-ifaces
) else (
  python run.py --list-ifaces
)
pause

@echo off
cd /d "%~dp0"
where py >nul 2>&1
if %errorlevel%==0 (
  py -3 run.py --demo --listen 0.0.0.0:8443
) else (
  python run.py --demo --listen 0.0.0.0:8443
)
pause

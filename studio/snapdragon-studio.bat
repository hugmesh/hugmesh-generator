@echo off
REM Snapdragon Image Studio launcher (Windows). Requires Python 3.10+ and Docker Desktop.
REM   pip install -r requirements.txt
REM   snapdragon-studio.bat
cd /d "%~dp0"
python -m snapdragon_studio %*

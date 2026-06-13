@echo off
REM Snapdragon mesh-node - Windows .cmd wrapper (FD-09). Double-clickable / cmd.exe
REM front-end for mesh-node.ps1; passes all args straight through. Example:
REM   mesh-node.cmd -Keys .\mykeys -Role superadmin
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0mesh-node.ps1" %*

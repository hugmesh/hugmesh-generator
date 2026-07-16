@echo off
REM snapdragon-studio.bat - Snapdragon Image Studio launcher + guided Windows bootstrap.
REM
REM Double-click on a ready box and the wizard launches straight away. On a bare box it
REM DETECTS what is missing (Python, PySide6/venv, Docker, winget), reports each fact on
REM one DETECT line, and OFFERS consent-gated installs. It NEVER installs anything
REM without an explicit y/N answer (or the /auto flag), it only uses winget (the OS
REM package manager), and it never downloads-and-executes remote scripts.
REM
REM   snapdragon-studio.bat            guided run (detect, offer installs, launch)
REM   snapdragon-studio.bat /detect    print the DETECT report and exit (no prompts)
REM   snapdragon-studio.bat /auto      as guided, but every offer is accepted
REM   snapdragon-studio.bat --...      any --arg is HEADLESS automation: no prompts, no
REM                                    installs, straight to the launch line (e.g.
REM                                    --print-command, the qemu e2e contract)
REM
REM The docker build backend is OPTIONAL: without Docker the wizard still runs for
REM config/preview/--print-command; native builds are not available on Windows.
REM Exit codes: 0 launched (or /detect done, or open-a-new-terminal after a Python
REM install), 1 launch/pip/probe failure, 2 a required step was declined, 3 winget
REM missing (manual instructions printed).
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"

REM ---- pinned constants (single source; tests + the qemu harness grep these lines) ----
set "WINGET_PYTHON_ID=Python.Python.3.12"
set "WINGET_DOCKER_ID=Docker.DockerDesktop"
set "PYTHON_MIN=3.10"
set "VENV_DIR=%~dp0.venv-studio"

set "HEADLESS=0"
set "DETECT_ONLY=0"
set "AUTO=0"
set "ARGS="
set "PY_OK=0"
set "PY_ON_PATH=0"
set "PY_CMD="
set "PY_VERSION="
set "PY_PATH="
set "VENV_OK=0"
set "PYSIDE_SCOPE=none"
set "DOCKER_OK=0"
set "DOCKER_DETAIL="
set "WINGET_OK=0"
set "NOT_ELEVATED=0"

REM ---- arg scan: runs before ANY probe or prompt (automation must never see one) ----
for %%A in (%*) do (
    set "CUR=%%~A"
    if /i "%%~A"=="/detect" set "DETECT_ONLY=1"
    if /i "%%~A"=="/auto" set "AUTO=1"
    if "!CUR:~0,2!"=="--" set "HEADLESS=1"
)
REM /auto and /detect are bat-local: the /auto path rebuilds forwardable args (a shift
REM loop, because a plain star-expansion ignores shift); the plain path never rebuilds.
if not "%AUTO%"=="1" goto :dispatch
:rebuild_args
if "%~1"=="" goto :dispatch
set "KEEP_ARG=1"
if /i "%~1"=="/auto" set "KEEP_ARG=0"
if /i "%~1"=="/detect" set "KEEP_ARG=0"
if "%KEEP_ARG%"=="1" set ARGS=!ARGS! %1
shift
goto :rebuild_args

:dispatch
if "%DETECT_ONLY%"=="1" goto :detect_only
if "%HEADLESS%"=="1" goto :headless
goto :interactive

:detect_only
REM /detect: report and exit. Never prompts, never installs, never launches.
call :detect
exit /b 0

:headless
REM Automation path (--print-command etc): quiet probe, no prompts, no installs.
call :probe_python
if exist "%VENV_DIR%\Scripts\python.exe" goto :launch
if "%PY_ON_PATH%"=="1" goto :launch
echo ERROR: Python %PYTHON_MIN%+ was not found on PATH and no venv exists at "%VENV_DIR%".
echo Headless mode never installs anything. Run snapdragon-studio.bat with no arguments
echo for the guided setup.
exit /b 1

:interactive
REM Ready fast path: Python + Qt importable means straight to launch - no report, no
REM prompts. Docker probing is deliberately skipped here (the wizard re-detects docker
REM itself via platform_info; a hung docker pipe must not stall startup).
call :probe_python
call :probe_pyside
if "%PYSIDE_SCOPE%"=="venv" goto :launch
if "%PYSIDE_SCOPE%"=="system" if "%PY_ON_PATH%"=="1" goto :launch
goto :bootstrap

:bootstrap
echo Snapdragon Image Studio - Windows setup check
echo ----------------------------------------------
call :detect
echo(
if "%PY_OK%"=="1" goto :bootstrap_venv
if "%WINGET_OK%"=="1" goto :bootstrap_python
goto :no_winget

:bootstrap_python
call :install_python
if errorlevel 3 exit /b 0
if errorlevel 1 exit /b %ERRORLEVEL%
call :probe_pyside

:bootstrap_venv
if "%PYSIDE_SCOPE%"=="venv" goto :bootstrap_docker
if "%PYSIDE_SCOPE%"=="system" if "%PY_ON_PATH%"=="1" goto :bootstrap_docker
if "%VENV_OK%"=="1" goto :bootstrap_venv_refresh
call :install_venv
goto :bootstrap_venv_done
:bootstrap_venv_refresh
call :install_venv_refresh
:bootstrap_venv_done
if errorlevel 1 exit /b %ERRORLEVEL%

:bootstrap_docker
if "%DOCKER_OK%"=="1" goto :launch
if "%WINGET_OK%"=="0" goto :bootstrap_docker_no_winget
net session >nul 2>&1
if errorlevel 1 set "NOT_ELEVATED=1"
call :install_docker
goto :launch

:bootstrap_docker_no_winget
echo docker is missing and winget is unavailable, so Docker Desktop cannot be
echo auto-installed here. Manual install (OPTIONAL - docker build backend only):
echo   https://docs.docker.com/desktop/setup/install/windows-install/
echo Continuing without docker - the wizard still runs; the docker backend stays greyed.
goto :launch

:no_winget
echo(
echo winget is not available on this Windows edition (LTSC/Server?); nothing was
echo installed and this script will not download anything itself. Install manually:
echo   Python %PYTHON_MIN%+ : https://www.python.org/downloads/windows/
echo   Docker Desktop (OPTIONAL - docker build backend only):
echo     https://docs.docker.com/desktop/setup/install/windows-install/
echo   Studio deps: python -m pip install -r requirements.txt
echo Then re-run snapdragon-studio.bat.
exit /b 3

REM ==== probes (quiet: they only set variables; :detect does the reporting) ==========

:probe_python
set "PY_OK=0"
set "PY_ON_PATH=0"
set "PY_CMD="
set "PY_VERSION="
set "PY_PATH="
REM Exit-code probes: the Windows-Store python alias stub exits nonzero, so it reads as
REM missing - a where-based probe would false-positive on it.
python -c "import sys; v='%PYTHON_MIN%'.split('.'); raise SystemExit(0 if sys.version_info >= (int(v[0]), int(v[1])) else 1)" >nul 2>&1
if not errorlevel 1 set "PY_ON_PATH=1"
py -3 -c "import sys; v='%PYTHON_MIN%'.split('.'); raise SystemExit(0 if sys.version_info >= (int(v[0]), int(v[1])) else 1)" >nul 2>&1
if not errorlevel 1 (set "PY_OK=1" & set "PY_CMD=py -3")
if "%PY_OK%"=="0" if "%PY_ON_PATH%"=="1" (set "PY_OK=1" & set "PY_CMD=python")
if "%PY_OK%"=="0" goto :eof
for /f "delims=" %%V in ('!PY_CMD! -c "import sys; print(sys.version.split()[0])" 2^>nul') do set "PY_VERSION=%%V"
for /f "delims=" %%P in ('!PY_CMD! -c "import sys; print(sys.executable)" 2^>nul') do set "PY_PATH=%%P"
goto :eof

:probe_pyside
set "VENV_OK=0"
set "PYSIDE_SCOPE=none"
if exist "%VENV_DIR%\Scripts\python.exe" set "VENV_OK=1"
if "%VENV_OK%"=="0" goto :probe_pyside_system
"%VENV_DIR%\Scripts\python.exe" -c "import PySide6" >nul 2>&1
if not errorlevel 1 (set "PYSIDE_SCOPE=venv" & goto :eof)
:probe_pyside_system
if not "%PY_OK%"=="1" goto :eof
!PY_CMD! -c "import PySide6" >nul 2>&1
if not errorlevel 1 (set "PYSIDE_SCOPE=system" & goto :eof)
REM the gui/qt.py shim accepts PyQt6 as well
!PY_CMD! -c "import PyQt6" >nul 2>&1
if not errorlevel 1 set "PYSIDE_SCOPE=system"
goto :eof

:probe_docker
set "DOCKER_OK=0"
set "DOCKER_DETAIL="
where docker >nul 2>&1
if errorlevel 1 (set "DOCKER_DETAIL=cli-not-found" & goto :eof)
REM same reachability probe as core/platform_info: the cli exists, is the engine up?
docker info >nul 2>&1
if errorlevel 1 (set "DOCKER_DETAIL=engine-unreachable" & goto :eof)
set "DOCKER_OK=1"
goto :eof

:probe_winget
set "WINGET_OK=0"
where winget >nul 2>&1
if not errorlevel 1 set "WINGET_OK=1"
goto :eof

REM ==== the DETECT report: one machine-greppable line per fact ========================

:detect
call :probe_python
call :probe_pyside
call :probe_docker
call :probe_winget
if "%PY_OK%"=="1" (echo DETECT python=found version=!PY_VERSION! path=!PY_PATH!) else (echo DETECT python=missing version=none path=none)
if not "%PYSIDE_SCOPE%"=="none" (echo DETECT pyside6=found scope=!PYSIDE_SCOPE!) else (echo DETECT pyside6=missing scope=none)
if "%VENV_OK%"=="1" (echo DETECT venv=found path=!VENV_DIR!) else (echo DETECT venv=missing path=!VENV_DIR!)
if "%DOCKER_OK%"=="1" (echo DETECT docker=found) else (echo DETECT docker=missing detail=!DOCKER_DETAIL!)
echo   note: the docker backend is OPTIONAL - without it the wizard still runs for
echo   config/preview/--print-command; native builds are not available on Windows.
if "%WINGET_OK%"=="1" (echo DETECT winget=found) else (echo DETECT winget=missing)
goto :eof

REM ==== installs: consent-gated, idempotent; every one starts at :confirm =============

:install_python
echo(
echo Python %PYTHON_MIN%+ was not found. It can be installed now via winget
echo (per-user scope by default - no admin needed).
call :confirm "winget install --id %WINGET_PYTHON_ID% --exact --source winget"
if errorlevel 1 goto :install_python_declined
call winget install --id %WINGET_PYTHON_ID% --exact --source winget
REM winget failures return 0x8A15xxxx HRESULTs = NEGATIVE signed %ERRORLEVEL% values;
REM `if errorlevel 1` is a signed >=1 test and misses them, so NEQ 0 it must be.
if %ERRORLEVEL% NEQ 0 goto :install_python_failed
call :probe_python
if "%PY_OK%"=="1" goto :eof
echo Python installed, but this cmd session's PATH has not picked it up yet.
echo Open a NEW terminal (or double-click snapdragon-studio.bat again) to continue.
exit /b 3

:install_python_declined
echo Python is required to run the studio; nothing was installed.
echo Manual install: https://www.python.org/downloads/windows/ (version %PYTHON_MIN% or newer)
exit /b 2

:install_python_failed
echo winget could not install Python (see winget output above); nothing else was changed.
echo Manual install: https://www.python.org/downloads/windows/ (version %PYTHON_MIN% or newer)
exit /b 1

:install_venv
echo(
echo The studio GUI needs PySide6; it can be installed into a project-local venv.
call :confirm "!PY_CMD! -m venv %VENV_DIR% then %VENV_DIR%\Scripts\python.exe -m pip install -r requirements.txt (downloads PySide6)"
if errorlevel 1 goto :install_venv_declined
!PY_CMD! -m venv "%VENV_DIR%"
if errorlevel 1 goto :install_venv_create_failed
goto :install_venv_pip

:install_venv_refresh
echo(
echo A venv exists at "%VENV_DIR%" but PySide6 is not importable in it; pip can refresh it.
call :confirm "%VENV_DIR%\Scripts\python.exe -m pip install -r requirements.txt (downloads PySide6)"
if errorlevel 1 goto :install_venv_declined
goto :install_venv_pip

:install_venv_pip
"%VENV_DIR%\Scripts\python.exe" -m pip install -r "%~dp0requirements.txt"
if errorlevel 1 goto :install_venv_pip_failed
call :probe_pyside
if "%PYSIDE_SCOPE%"=="venv" goto :eof
echo pip finished but PySide6 is still not importable from the venv (see output above).
exit /b 1

:install_venv_declined
if "%PYSIDE_SCOPE%"=="system" if "%PY_ON_PATH%"=="1" goto :install_venv_use_system
echo PySide6 was not installed. Manual setup, then re-run snapdragon-studio.bat:
echo   !PY_CMD! -m venv "%VENV_DIR%"
echo   %VENV_DIR%\Scripts\python.exe -m pip install -r requirements.txt
exit /b 2

:install_venv_use_system
echo Continuing with the system Python - PySide6/PyQt6 is already importable there.
exit /b 0

:install_venv_create_failed
echo Could not create the venv (see output above); nothing else was changed.
exit /b 1

:install_venv_pip_failed
echo pip install failed (offline? behind a proxy?). Nothing was retried; re-run
echo snapdragon-studio.bat when the network is available.
exit /b 1

:install_docker
echo(
echo Docker Desktop can be installed now - it is OPTIONAL and only needed for the
echo docker build backend; without it the wizard still runs for config, preview and
echo --print-command. Native builds are not available on Windows.
echo Honest caveats: Docker Desktop needs WSL2, needs a reboot or log-out after
echo install, and needs admin rights.
if "%NOT_ELEVATED%"=="1" echo This cmd session is NOT elevated: winget will raise a UAC prompt or the install may fail.
call :confirm "winget install --id %WINGET_DOCKER_ID% --exact --source winget"
if errorlevel 1 goto :install_docker_declined
call winget install --id %WINGET_DOCKER_ID% --exact --source winget
REM same signed-HRESULT trap as :install_python — a failed winget must NOT fall through
REM to the success message (honesty rule), and negatives dodge `if errorlevel 1`.
if %ERRORLEVEL% NEQ 0 goto :install_docker_failed
echo Docker Desktop installed. Reboot or log out, start Docker Desktop once, and the
echo docker backend will light up in the wizard.
goto :eof

:install_docker_declined
echo Skipping Docker Desktop. The wizard still runs; the docker backend stays greyed
echo out (the wizard's existing preflight gating). Nothing was installed.
goto :eof

:install_docker_failed
echo winget could not install Docker Desktop (see winget output above). Continuing
echo without docker - the wizard still runs; the docker backend stays greyed out.
echo Manual install (optional): https://docs.docker.com/desktop/setup/install/windows-install/
goto :eof

REM ==== the consent gate ==============================================================

:confirm
REM Arg 1 is the EXACT command that will run on yes. Default answer is NO. AUTO=1
REM (/auto) short-circuits to yes; the HEADLESS path never reaches here at all.
echo   about to run: %~1
if "%AUTO%"=="1" (echo   /auto: proceeding without prompt & exit /b 0)
set "ANS="
set /p ANS=  proceed? [y/N]
if /i "!ANS!"=="y" exit /b 0
echo   (answer was not y - skipping)
exit /b 1

REM ==== launch: the byte-compatible contract ==========================================
REM The venv (when present) is activated by a PATH prepend, so the pinned launch line
REM below never changes shape - test_bat_launcher.py and the qemu harness grep it.

:launch
if exist "%VENV_DIR%\Scripts\python.exe" set "PATH=%VENV_DIR%\Scripts;%PATH%"
if "%AUTO%"=="1" goto :launch_auto
python -m snapdragon_studio %*
exit /b %ERRORLEVEL%
:launch_auto
python -m snapdragon_studio !ARGS!
exit /b %ERRORLEVEL%

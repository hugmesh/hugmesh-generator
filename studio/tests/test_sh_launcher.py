"""The Linux/macOS launcher contract: ``hugmesh-studio`` finds a Python with a Qt binding
without a terminal, never installs without asking, and can add a menu entry.

Everything runs against stub interpreters in a throwaway HOME, so no display, no network
and no real Studio is started.
"""
import os
import shutil
import stat
import subprocess

import pytest

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LAUNCHER = os.path.join(STUDIO_ROOT, "hugmesh-studio")
SH = shutil.which("sh")

pytestmark = pytest.mark.skipif(SH is None, reason="needs a POSIX sh")


def _env(tmp_path, **extra):
    home = tmp_path / "home"
    home.mkdir(exist_ok=True)
    env = {"HOME": str(home), "XDG_DATA_HOME": str(home / "data"), "PATH": str(tmp_path / "bin")}
    env.update(extra)
    return env


def _bin(tmp_path, python_body=None):
    """A PATH holding only the tools the launcher needs, plus an optional fake python3."""
    b = tmp_path / "bin"
    b.mkdir(exist_ok=True)
    for tool in ("dirname", "basename", "readlink", "mkdir", "chmod", "rm", "printf"):
        found = shutil.which(tool)
        if found and not (b / tool).exists():
            (b / tool).symlink_to(found)
    if python_body is not None:
        p = b / "python3"
        p.write_text("#!/bin/sh\n" + python_body)
        p.chmod(p.stat().st_mode | stat.S_IEXEC)
    return b


def _run(tmp_path, *args, **extra):
    return subprocess.run([SH, LAUNCHER, *args], env=_env(tmp_path, **extra), cwd=tmp_path,
                          stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)


def test_launcher_is_posix_sh_and_executable():
    first = open(LAUNCHER, encoding="utf-8").readline().strip()
    assert first == "#!/bin/sh"
    assert os.access(LAUNCHER, os.X_OK)


def test_detect_reports_the_override_interpreter(tmp_path):
    _bin(tmp_path)
    stub = tmp_path / "py"
    stub.write_text("#!/bin/sh\nexit 0\n")
    stub.chmod(0o755)
    r = _run(tmp_path, "--detect", HUGMESH_STUDIO_PYTHON=str(stub))
    assert r.returncode == 0
    assert "DETECT qt-binding=yes" in r.stdout and f"DETECT interpreter={stub}" in r.stdout


def test_no_qt_and_no_way_to_ask_installs_nothing_and_says_why(tmp_path):
    _bin(tmp_path, python_body="exit 1\n")          # a python3 with no Qt binding
    r = _run(tmp_path)
    assert r.returncode == 1
    assert "No Python with PySide6 or PyQt6 found" in r.stderr
    assert not (tmp_path / "home" / "data").exists(), "it built something without asking"


def test_runs_the_studio_module_with_args_forwarded(tmp_path):
    _bin(tmp_path)
    stub = tmp_path / "py"
    stub.write_text('#!/bin/sh\n[ "$1" = -c ] && exit 0\necho "RAN $*"\n')
    stub.chmod(0o755)
    r = _run(tmp_path, "--self-check", HUGMESH_STUDIO_PYTHON=str(stub))
    assert r.returncode == 0 and "RAN -m hugmesh_studio --self-check" in r.stdout


def test_install_launcher_writes_a_menu_entry_for_this_checkout(tmp_path):
    _bin(tmp_path)
    link = tmp_path / "lnk"
    link.symlink_to(LAUNCHER)                       # a symlink must still resolve the checkout
    r = subprocess.run([SH, str(link), "--install-launcher"], env=_env(tmp_path),
                       capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stderr
    desktop = (tmp_path / "home" / "data" / "applications" / "hugmesh-image-studio.desktop").read_text()
    assert f'Exec="{LAUNCHER}"' in desktop and "Terminal=false" in desktop

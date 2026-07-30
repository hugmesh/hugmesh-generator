"""The Windows .bat launcher contract — always-run offline checks (no qemu, no gate).

``hugmesh-studio.bat`` is what a Windows operator double-clicks; it runs
``python -m hugmesh_studio %*``. The dark-gated qemu harness
(``tests/qemu/windows-studio-e2e.sh``) exercises that .bat inside a REAL Windows guest,
but the boot needs an operator-provided image and SKIPS in CI. These checks run on every
pass and are the offline half of the same proof:

  1. BAT VALIDITY (static): the shipped .bat runs from its own dir and invokes the RIGHT
     entrypoint with args forwarded — a rename of the module or a dropped ``%*`` fails here.
  2. "SIMULATE THE BAT" (Linux): reconstruct the .bat's effective invocation
     (``python -m hugmesh_studio --print-command …``) and prove it emits a real builder
     command — so the command the qemu guest runs is known-good without needing Windows.

``--print-command`` IS the headless self-test the .bat exercises: app.py returns from the
``if args.print_command:`` block (core.build_driver + core.config only) BEFORE any Qt import,
so it needs no display in the guest (the build-matrix GUI column already relies on this).

These overlap deliberately with test_headless.py, but are framed as the ".bat contract" so a
future edit to the .bat or the module entrypoint is caught by a test named for it.
"""
import os
import re
import subprocess
import sys

import pytest

from hugmesh_studio.core.config import ImageConfig

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
BAT_PATH = os.path.join(STUDIO_ROOT, "hugmesh-studio.bat")

# any of the seven builder scripts is a valid "a command was emitted" marker (the qemu
# harness greps the same set).
BUILDER_CMD_RE = re.compile(
    r"build-(x86-host|rpi5|frite|jetson|orangepi5|orangepi-zero2|orangepi-zero2w|orangepi-zero3)-stage4\.sh")


# ── 1. BAT VALIDITY (static, no qemu) ──────────────────────────────────────────────────
def test_bat_runs_from_its_own_dir_and_targets_the_module():
    text = open(BAT_PATH, encoding="utf-8").read()
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()
             and not ln.strip().upper().startswith("REM")
             and not ln.strip().startswith("@")]
    # (1) cd into its own directory so the hugmesh_studio package is importable
    assert any(ln.lower().startswith("cd /d") and "%~dp0" in ln for ln in lines), text
    # (2) the RIGHT entrypoint, with args forwarded verbatim (%*)
    assert any("python -m hugmesh_studio" in ln and "%*" in ln for ln in lines), text


# ── 2. LINUX "SIMULATE THE BAT" — in-process ───────────────────────────────────────────
def test_simulate_bat_in_process_emits_builder_command(capsys):
    """``app.main(["--print-command", …])`` == what ``hugmesh-studio.bat --print-command``
    runs once the .bat has cd'd in and forwarded its args. A default ImageConfig() is a
    standalone x86 image, so the x86 builder is emitted; the path never imports Qt."""
    from hugmesh_studio import app
    before = {m for m in sys.modules if m.split(".")[0] in ("PySide6", "PyQt6")}
    rc = app.main(["--print-command", "--generator-dir", GENERATOR_DIR, "--backend", "native"])
    assert rc == 0
    out = capsys.readouterr().out
    assert "build-x86-host-stage4.sh" in out
    after = {m for m in sys.modules if m.split(".")[0] in ("PySide6", "PyQt6")}
    assert after == before      # the .bat's --print-command path is Qt-free


# ── 2. LINUX "SIMULATE THE BAT" — subprocess (the exact guest argv shape) ──────────────
def test_simulate_bat_subprocess_emits_builder_command():
    """The exact argv the guest's ``hugmesh-studio.bat --print-command`` expands to
    (``python -m hugmesh_studio --print-command …``), run as a real subprocess with no
    display — proving the .bat's payload works end-to-end off any GUI."""
    env_vars = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    env_vars.pop("DISPLAY", None)
    env_vars.pop("WAYLAND_DISPLAY", None)
    r = subprocess.run(
        [sys.executable, "-m", "hugmesh_studio", "--print-command",
         "--backend", "native", "--generator-dir", GENERATOR_DIR],
        capture_output=True, text=True, timeout=60, env=env_vars, cwd=STUDIO_ROOT)
    assert r.returncode == 0, r.stderr
    assert BUILDER_CMD_RE.search(r.stdout), r.stdout


def test_simulate_bat_exact_guest_argv_no_generator_dir():
    """The BYTE-FOR-BYTE argv the qemu guest's run-selftest.bat expands to:
    ``hugmesh-studio.bat --print-command --backend native`` -> (after the .bat's
    ``cd /d %~dp0``) ``python -m hugmesh_studio --print-command --backend native`` run
    from the studio dir with NO ``--generator-dir``. This is the ONLY offline test that
    exercises app._default_generator_dir()'s own resolution the way the guest relies on it
    (a regression there that raised would keep the other simulate-the-bat tests green — they
    all inject --generator-dir — while breaking the real guest command)."""
    env_vars = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    env_vars.pop("DISPLAY", None)
    env_vars.pop("WAYLAND_DISPLAY", None)
    r = subprocess.run(
        [sys.executable, "-m", "hugmesh_studio", "--print-command", "--backend", "native"],
        capture_output=True, text=True, timeout=60, env=env_vars, cwd=STUDIO_ROOT)
    assert r.returncode == 0, r.stderr
    assert BUILDER_CMD_RE.search(r.stdout), r.stdout


def test_simulate_bat_forwards_config_arg_to_a_non_default_platform(tmp_path):
    """Arg forwarding through the .bat contract: a saved rpi5 config rides ``--config``
    (which the .bat's ``%*`` passes straight through) onto the rpi5 builder — proving the
    guest can drive any platform, not just the default."""
    cfg = ImageConfig(mode="mesh", role="be", platform="rpi5", env="prod")
    p = tmp_path / "rpi5-be.json"
    cfg.save(str(p))
    env_vars = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    r = subprocess.run(
        [sys.executable, "-m", "hugmesh_studio", "--print-command", "--config", str(p),
         "--backend", "native", "--generator-dir", GENERATOR_DIR],
        capture_output=True, text=True, timeout=60, env=env_vars, cwd=STUDIO_ROOT)
    assert r.returncode == 0, r.stderr
    assert "build-rpi5-stage4.sh" in r.stdout
    assert cfg.builder_script in r.stdout

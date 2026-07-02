"""Headless --print-command: must work with no display and no Qt installed.

The matrix harness drives `python -m snapdragon_studio --print-command --config X.json`
for every role x platform x env — so the path must never import a Qt binding.
"""
import json
import os
import subprocess
import sys

import pytest

from snapdragon_studio.core.config import ImageConfig

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

MATRIX = [
    ("x86", "standalone", "standalone-thin", "test"),
    ("x86", "standalone", "standalone-thick", "prod"),
    ("x86", "cloud", "laptop", "test"),
    ("x86", "mesh", "omnibus", "prod"),
    ("rpi5", "mesh", "be", "prod"),
    ("frite", "cloud", "frite", "test"),
    ("jetson", "mesh", "edge_ai", "prod"),
]


def _write_cfg(tmp_path, platform, mode, role, env):
    cfg = ImageConfig(mode=mode, role=role, platform=platform, env=env, tailscale=True)
    p = tmp_path / f"{platform}-{role}-{env}.json"
    cfg.save(str(p))
    return cfg, str(p)


def test_print_command_in_process_never_imports_qt(tmp_path, capsys):
    from snapdragon_studio import app
    before = {m for m in sys.modules if m.split(".")[0] in ("PySide6", "PyQt6")}
    for platform, mode, role, env in MATRIX:
        cfg, path = _write_cfg(tmp_path, platform, mode, role, env)
        rc = app.main(["--print-command", "--config", path,
                       "--generator-dir", GENERATOR_DIR, "--backend", "native"])
        assert rc == 0
        out = capsys.readouterr().out
        assert cfg.builder_script in out
        assert f"--env {env}" in out
    after = {m for m in sys.modules if m.split(".")[0] in ("PySide6", "PyQt6")}
    assert after == before  # the headless path lazy-imports Qt on GUI paths only


@pytest.mark.parametrize("platform,mode,role,env", MATRIX)
def test_print_command_subprocess_smoke(tmp_path, platform, mode, role, env):
    cfg, path = _write_cfg(tmp_path, platform, mode, role, env)
    env_vars = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    env_vars.pop("DISPLAY", None)          # prove no display is needed
    env_vars.pop("WAYLAND_DISPLAY", None)
    r = subprocess.run(
        [sys.executable, "-m", "snapdragon_studio", "--print-command", "--config", path,
         "--generator-dir", GENERATOR_DIR, "--backend", "native"],
        capture_output=True, text=True, timeout=60, env=env_vars, cwd=STUDIO_ROOT)
    assert r.returncode == 0, r.stderr
    assert cfg.builder_script in r.stdout
    assert ("--role" in r.stdout) == (platform != "frite")


def test_print_command_config_round_trips_cli_args(tmp_path):
    """The printed command must embed exactly to_cli_args() for the loaded config."""
    cfg, path = _write_cfg(tmp_path, "rpi5", "mesh", "fe", "prod")
    reloaded = ImageConfig.load(path)
    env_vars = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    r = subprocess.run(
        [sys.executable, "-m", "snapdragon_studio", "--print-command", "--config", path,
         "--generator-dir", GENERATOR_DIR, "--backend", "native"],
        capture_output=True, text=True, timeout=60, env=env_vars, cwd=STUDIO_ROOT)
    assert r.returncode == 0, r.stderr
    assert " ".join(reloaded.to_cli_args()) in r.stdout
    assert "--role frontend" in r.stdout   # rpi5 spells be/fe out


def test_saved_matrix_configs_hold_no_secrets(tmp_path):
    cfg = ImageConfig(local_pass="pw", luks_pass="pw2")
    p = tmp_path / "s.json"
    cfg.save(str(p))
    data = json.loads(p.read_text(encoding="utf-8"))
    assert data["local_pass"] == "" and data["luks_pass"] == ""

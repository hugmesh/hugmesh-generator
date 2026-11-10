"""FleetDriver + the NVD API key (FAKE keys only).

A pen-test fleet run gets the stored key as a POINTER — ``NVD_API_KEY_FILE=<path>``
to a per-run 0600 copy (docker: a read-only mount) — and never the key itself on
argv, in env, in the preview, in the FleetConfig JSON, or in a streamed log line.
Also pins the #860 regression this lane hit: FleetDriver inherits BuildDriver.run,
which read ``cfg.local_pass`` — a field a FleetConfig does not have — so every fleet
run aborted with AttributeError before anything was spawned.
"""
from __future__ import annotations

import json
import os
import stat

import pytest

from hugmesh_studio.core import nvd_key
from hugmesh_studio.core.fleet import FleetConfig, FleetDriver
from hugmesh_studio.core.platform_info import HostInfo

KEY = "11111111-2222-4333-8444-555555555555"
GEN = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ROOT = HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                has_kvm=False, is_root=True, builder_image="hugmesh-builder")
POSIX = pytest.mark.skipif(os.name == "nt", reason="POSIX file modes")


@pytest.fixture
def driver(tmp_path, monkeypatch):
    d = FleetDriver(GEN, ROOT)
    d.workdir = str(tmp_path / "out")
    return d


def _flat(cmd):
    return " ".join(cmd)


def test_native_command_carries_the_pointer_not_the_key(driver):
    cmd = driver.command(FleetConfig(pentest=True), "native", nvd_key_file="/tmp/x/nvd_api_key")
    assert "NVD_API_KEY_FILE=/tmp/x/nvd_api_key" in cmd
    assert cmd.index("NVD_API_KEY_FILE=/tmp/x/nvd_api_key") < cmd.index("bash")  # inside env


def test_docker_command_mounts_the_copy_read_only(driver, monkeypatch):
    monkeypatch.setattr(driver, "_image_present", lambda: True)
    cmd = driver.command(FleetConfig(pentest_only=True), "docker",
                         nvd_key_file="/tmp/x/nvd_api_key")
    assert f"/tmp/x/nvd_api_key:{nvd_key.DOCKER_SECRET_PATH}:ro" in cmd
    i = cmd.index(f"{nvd_key.FILE_ENV}={nvd_key.DOCKER_SECRET_PATH}")
    assert cmd[i - 1] == "-e"
    assert "/tmp/x/nvd_api_key" not in " ".join(c for c in cmd if c.startswith(nvd_key.FILE_ENV))


def test_no_pentest_no_pointer_and_the_preview_never_has_one(driver):
    assert nvd_key.FILE_ENV not in _flat(driver.command(FleetConfig(), "native",
                                                        nvd_key_file="/tmp/x"))
    nvd_key.save(KEY)
    for be in ("native", "docker"):
        assert nvd_key.FILE_ENV not in driver.command_string(FleetConfig(pentest=True), be)
        assert KEY not in driver.command_string(FleetConfig(pentest=True), be)


@POSIX
@pytest.mark.parametrize("backend", ["native", "docker"])
def test_run_stages_a_private_copy_passes_its_path_and_removes_it(driver, backend):
    nvd_key.save(f" {KEY}\n")
    seen = {}

    def fake_stream(cmd, on_line, be):
        seen["cmd"] = cmd
        if backend == "native":
            path = next(c.split("=", 1)[1] for c in cmd if c.startswith(nvd_key.FILE_ENV + "="))
        else:
            mount = next(c for c in cmd if c.endswith(f":{nvd_key.DOCKER_SECRET_PATH}:ro"))
            path = mount.split(":")[0]
        seen["path"] = path
        seen["mode"] = stat.S_IMODE(os.stat(path).st_mode)
        seen["body"] = open(path).read()
        on_line(f"[INFO] NvdApiException: Invalid API Key: 11111-*****-55555")
        on_line(f"a script that echoed {KEY}")
        return 0

    driver._stream = fake_stream
    lines = []
    assert driver.run(FleetConfig(pentest=True), backend, on_line=lines.append) == 0
    assert seen["mode"] == 0o600 and seen["body"] == KEY
    assert not os.path.exists(seen["path"])                 # removed when the run ended
    assert all(KEY not in c for c in seen["cmd"])           # never on argv
    blob = "\n".join(lines)
    assert KEY not in blob and "11111-*****-55555" not in blob
    assert "[NVD key redacted]" in blob
    assert any(nvd_key.FILE_ENV in ln for ln in lines)      # the run says what it passed


def test_run_without_a_stored_key_says_so_and_still_runs(driver):
    driver._stream = lambda cmd, on_line, be: (driver.__dict__.setdefault("cmd", cmd), 0)[1]
    lines = []
    assert driver.run(FleetConfig(pentest=True), "native", on_line=lines.append) == 0
    assert nvd_key.FILE_ENV not in _flat(driver.cmd)
    assert any(nvd_key.PREFLIGHT_NO_KEY in ln for ln in lines)


def test_fleet_run_no_longer_dies_on_the_missing_local_pass_field(driver):
    """#860 made BuildDriver.run read ``run_cfg.local_pass``; a FleetConfig has none,
    so every 'Build fleet now' died with AttributeError before spawning anything."""
    driver._stream = lambda cmd, on_line, be: 0
    assert driver.run(FleetConfig(), "native", on_line=lambda s: None) == 0


def test_the_missing_key_note_is_advisory_never_a_preflight_refusal(driver):
    cfg = FleetConfig(pentest=True)
    assert driver.advisories(cfg) == [nvd_key.PREFLIGHT_NO_KEY]
    assert nvd_key.PREFLIGHT_NO_KEY not in driver.preflight(cfg, "native")
    assert driver.advisories(FleetConfig()) == []
    nvd_key.save(KEY)
    assert driver.advisories(cfg) == []


def test_no_fleet_config_field_or_record_holds_the_key():
    nvd_key.save(KEY)
    cfg = FleetConfig(pentest=True)
    assert not any("nvd" in f.lower() for f in cfg.to_dict())
    assert KEY not in json.dumps(cfg.to_dict()) and KEY not in json.dumps(cfg.to_env())


def test_a_fleet_session_record_holds_no_key():
    from hugmesh_studio.core import build_sessions
    nvd_key.save(KEY)
    s = build_sessions.new_fleet_session(FleetConfig(pentest=True), GEN,
                                         session_id="20261110-000000-nvd")
    build_sessions.start(s)
    text = open(s.path(), encoding="utf-8").read()
    assert '"pentest": true' in text and KEY not in text

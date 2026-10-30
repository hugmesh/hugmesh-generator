"""Sentences the native Windows Studio said that were untrue there (#827 group 6).

Qt-free. Most of these only change on Windows, so they run in the windows CI job and
skip elsewhere; the ones that take an ``osname`` run everywhere.
"""
from __future__ import annotations

import os
import shutil

import pytest

from hugmesh_studio.core import cross_dracut, e2e_catalogue, emulation, local_agent
from hugmesh_studio.core import timezones
from hugmesh_studio.core.cloud_deploy import CloudDeploy, CloudDeployOptions
from hugmesh_studio.core.platform_info import HostInfo

windows_only = pytest.mark.skipif(os.name != "nt", reason="native Windows behaviour")


def test_the_cross_dracut_note_does_not_guess_on_windows():
    said = cross_dracut.cross_fde_note(["pi-1"], ready=False, osname="nt")
    assert "Docker Desktop" in said and "NO usable" not in said and "'off'" not in said
    assert "NO usable" in cross_dracut.cross_fde_note(["pi-1"], ready=False, osname="posix")


def test_the_windows_flash_note_shows_the_steps_it_promises():
    host = HostInfo(os="windows", is_gentoo=False, has_docker=True, has_bash=False,
                    has_kvm=False, is_root=False, builder_image="hugmesh-builder")
    said = host.flash_blocker()
    assert "(below)" not in said and "usbipd attach --wsl" in said and "WSL2" in said


@windows_only
def test_a_creds_file_is_not_called_world_readable(tmp_path):
    creds = tmp_path / "creds.json"
    creds.write_text("{}")
    cd = CloudDeploy(str(tmp_path), CloudDeployOptions(creds_file=str(creds)))
    assert not any("chmod 600" in p for p in cd.validate()), cd.validate()


@windows_only
def test_npx_is_resolved_to_npx_cmd(tmp_path, monkeypatch):
    (tmp_path / e2e_catalogue.E2E_DIR / "node_modules").mkdir(parents=True)
    monkeypatch.setattr(e2e_catalogue.shutil, "which",
                        lambda name: r"C:\Program Files\nodejs\npx.CMD" if name == "npx"
                        else shutil.which(name))
    seen = []

    def runner(argv, **_kw):
        seen.append(argv)
        raise FileNotFoundError
    e2e_catalogue.list_specs(str(tmp_path), runner=runner)
    assert seen and seen[0][0].endswith("npx.CMD"), seen


@windows_only
def test_the_playwright_lane_says_wsl2_not_root():
    said = emulation.playwright_root_blocker()
    assert "WSL2" in said and "root shell" not in said and "work now" not in said


@windows_only
def test_the_ollama_remedy_is_not_a_posix_command_line():
    fix = next(p.fix for p in local_agent.diagnose(local_agent.Probe(ollama_path="ollama"))
               if p.code == "server_down")
    assert "setsid" not in fix and "~/.cache" not in fix and "Ollama app" in fix


@windows_only
def test_the_host_timezone_comes_from_windows_settings(monkeypatch):
    monkeypatch.delenv("TZ", raising=False)
    tz = timezones._from_windows()
    assert tz and "/" in tz or tz == "UTC", tz          # an IANA name, never a Windows one
    assert tz in timezones.available()
    assert timezones.host_timezone() == tz


def test_the_windows_lookup_is_silent_elsewhere():
    if os.name != "nt":
        assert timezones._from_windows() == ""

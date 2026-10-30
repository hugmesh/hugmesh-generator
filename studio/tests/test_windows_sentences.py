"""Sentences the native Windows Studio said that were untrue there (#827 group 6).

Qt-free. Most of these only change on Windows, so they run in the windows CI job and
skip elsewhere; the ones that take an ``osname`` run everywhere.
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import time

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


def _fake_npx(tmp_path, monkeypatch, body: str) -> str:
    """A real npx.cmd whose python child runs ``body``, so the spawn, the decode and the
    timeout all go through cmd.exe the way Node's npx.cmd does."""
    (tmp_path / e2e_catalogue.E2E_DIR / "node_modules").mkdir(parents=True)
    child = tmp_path / "child.py"
    child.write_text(body, encoding="utf-8")
    cmd = tmp_path / "npx.cmd"
    cmd.write_text(f'@"{sys.executable}" "{child}" %*\r\n', encoding="ascii")
    real = shutil.which
    monkeypatch.setattr(e2e_catalogue.shutil, "which",
                        lambda name, *a, **k: str(cmd) if name == "npx" else real(name, *a, **k))
    return str(tmp_path)


@windows_only
def test_npx_is_resolved_to_npx_cmd(tmp_path, monkeypatch):
    (tmp_path / e2e_catalogue.E2E_DIR / "node_modules").mkdir(parents=True)
    real = shutil.which
    monkeypatch.setattr(e2e_catalogue.shutil, "which",
                        lambda name, *a, **k: r"C:\Program Files\nodejs\npx.CMD"
                        if name == "npx" else real(name, *a, **k))
    seen = []

    def runner(argv, **_kw):
        seen.append(argv)
        raise FileNotFoundError
    e2e_catalogue.list_specs(str(tmp_path), runner=runner)
    assert seen and seen[0][0].endswith("npx.CMD"), seen


@windows_only
def test_the_npx_listing_reads_playwright_utf8_not_the_code_page(tmp_path, monkeypatch):
    # U+2014 is in real spec titles (15-rbac-per-realm-login.spec.ts); U+201D encodes
    # to a 0x9D byte cp1252 leaves undefined, which once made stdout None
    title = "SYSTEMS realm \u2014 admin logs in \u201dhere\u201d"
    payload = {"suites": [{"title": "a.spec.ts", "file": "a.spec.ts", "specs": [
        {"title": title, "file": "a.spec.ts", "tests": [{"results": []}]}]}]}
    root = _fake_npx(tmp_path, monkeypatch,
                     "import sys\n"
                     f"sys.stdout.buffer.write({json.dumps(payload, ensure_ascii=False)!r}"
                     ".encode('utf-8'))\n")
    got = e2e_catalogue.list_specs(root)
    assert got.error == "", got.error
    assert [t.title for t in got.tests] == [title]


@windows_only
def test_the_npx_listing_timeout_holds_over_a_grandchild(tmp_path, monkeypatch):
    # cmd.exe is the child, python the grandchild holding the pipes: killing cmd.exe
    # alone used to wait the full sleep out
    root = _fake_npx(tmp_path, monkeypatch, "import time\ntime.sleep(25)\n")
    start = time.monotonic()
    got = e2e_catalogue.list_specs(root, timeout=2)
    took = time.monotonic() - start
    assert "did not finish within 2s" in got.error, got.error
    assert took < 15, f"returned after {took:.1f}s for a 2s timeout"


@windows_only
def test_the_playwright_lane_says_wsl2_not_root():
    said = emulation.playwright_root_blocker()
    assert "WSL2" in said and "root shell" not in said and "work now" not in said


def _server_down_fix(osname):
    return next(p.fix for p in local_agent.diagnose(local_agent.Probe(ollama_path="ollama"),
                                                   osname=osname)
                if p.code == "server_down")


def test_the_ollama_remedy_is_not_a_posix_command_line():
    fix = _server_down_fix("nt")
    assert "setsid" not in fix and "~/.cache" not in fix and "Ollama app" in fix
    assert "setsid ollama serve" in _server_down_fix("posix")


@pytest.mark.parametrize("osname", ["nt", "posix"])
def test_the_ollama_remedy_keeps_the_agent_context_length(osname):
    # A server on Ollama's default context passes Re-check and then truncates the
    # agent's prompt; the remedy is the only place the 32768 can be said
    fix = _server_down_fix(osname)
    assert "OLLAMA_CONTEXT_LENGTH=32768" in fix and "127.0.0.1:11434" in fix, fix


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

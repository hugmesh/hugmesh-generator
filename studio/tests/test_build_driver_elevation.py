"""BuildDriver privilege-elevation path (bug B: GUI-launched native builds).

A GUI-launched non-root native build must NOT prepend a bare `sudo` — its password
prompt goes to an invisible terminal and the build hangs. When ``graphical=True`` the
driver elevates through a GRAPHICAL auth path (``sudo -A`` with a Qt SUDO_ASKPASS helper,
else ``pkexec``); a terminal/headless launch (``graphical=False``, the default) keeps the
plain terminal `sudo` so the printed command stays copy-pasteable and the sudo-prefix
strippers (test_headless / build-matrix check.sh) keep matching. The kill-tree wrap must
reuse the SAME prefix (root-owned tree) and keep the negative-pgid session semantics.
"""
import os
import subprocess

import pytest

from snapdragon_studio.core import build_driver as bd
from snapdragon_studio.core.build_driver import BuildDriver
from snapdragon_studio.core.config import ImageConfig
from snapdragon_studio.core.platform_info import HostInfo


def host(is_root=False, has_docker=True):
    return HostInfo(os="linux", is_gentoo=True, has_docker=has_docker, has_bash=True,
                    has_kvm=False, is_root=is_root, builder_image="snapdragon-builder")


def _cfg(tmp_path, platform="rpi5", role="pki"):
    return ImageConfig(mode="mesh", role=role, platform=platform, tailscale=True,
                       output_dir=str(tmp_path / "out"), jobs=4)


def _force_sudo_a(monkeypatch, askpass="/run/studio-askpass.sh"):
    """sudo present + askpass helper available -> the sudo -A primary path."""
    monkeypatch.setattr(bd.shutil, "which", lambda name: f"/usr/bin/{name}")
    monkeypatch.setattr(bd, "_askpass_helper_path", lambda: askpass)


def _force_pkexec(monkeypatch):
    """No askpass helper writable, pkexec present -> the pkexec fallback path."""
    monkeypatch.setattr(bd, "_askpass_helper_path", lambda: None)
    monkeypatch.setattr(bd.shutil, "which",
                        lambda name: "/usr/bin/pkexec" if name == "pkexec" else None)


# ── prefix selection ─────────────────────────────────────────────────────────────────
def test_terminal_launch_keeps_plain_sudo(tmp_path):
    d = BuildDriver(str(tmp_path), host(is_root=False), graphical=False)
    cmd = d.command(_cfg(tmp_path), "native")
    assert cmd[:2] == ["sudo", "bash"]            # unchanged terminal path
    assert d._elevation_prefix() == ["sudo"]
    assert d._elevation_env() is None             # inherit ambient env untouched


def test_root_never_elevates_even_graphical(tmp_path):
    d = BuildDriver(str(tmp_path), host(is_root=True), graphical=True)
    cmd = d.command(_cfg(tmp_path), "native")
    assert cmd[:1] == ["bash"]                    # no wrapper at all
    assert d._elevation_prefix() == []
    assert d._elevation_env() is None


def test_gui_launch_uses_sudo_dash_A_with_askpass(monkeypatch, tmp_path):
    _force_sudo_a(monkeypatch, askpass="/run/ap.sh")
    d = BuildDriver(str(tmp_path), host(is_root=False), graphical=True)
    cmd = d.command(_cfg(tmp_path), "native")
    assert cmd[:3] == ["sudo", "-A", "bash"]      # graphical auth, not a bare sudo
    env = d._elevation_env()
    assert env is not None and env["SUDO_ASKPASS"] == "/run/ap.sh"


def test_gui_launch_falls_back_to_pkexec(monkeypatch, tmp_path):
    _force_pkexec(monkeypatch)
    d = BuildDriver(str(tmp_path), host(is_root=False), graphical=True)
    cmd = d.command(_cfg(tmp_path), "native")
    assert cmd[:2] == ["pkexec", "bash"]
    assert d._elevation_env() is None             # pkexec needs no SUDO_ASKPASS


def test_gui_env_wrapper_stays_inside_elevation_boundary(monkeypatch, tmp_path):
    """HEADSCALE_URL's `env K=V` wrapper must sit AFTER the graphical prefix (sudo -A /
    pkexec both env_reset), exactly as it did after a plain sudo."""
    _force_sudo_a(monkeypatch)
    cfg = _cfg(tmp_path, "x86", "omnibus")
    cfg.headscale_url = "https://hs.acme.example"
    cmd = BuildDriver(str(tmp_path), host(is_root=False), graphical=True).command(cfg, "native")
    assert cmd[:4] == ["sudo", "-A", "env", "HEADSCALE_URL=https://hs.acme.example"]
    assert cmd[4] == "bash"


# ── kill-tree ────────────────────────────────────────────────────────────────────────
class _GracefulProc:
    pid = 4321

    def wait(self, timeout=None):
        return 0            # exits on TERM -> no KILL escalation

    def poll(self):
        return None


def _capture_run(monkeypatch):
    calls = []

    def fake_run(cmd, **kwargs):
        calls.append((list(cmd), kwargs.get("env")))
        return subprocess.CompletedProcess(cmd, 0)

    monkeypatch.setattr(bd.subprocess, "run", fake_run)
    return calls


def test_kill_tree_reuses_graphical_prefix_and_negative_pgid(monkeypatch, tmp_path):
    _force_sudo_a(monkeypatch, askpass="/run/ap.sh")
    d = BuildDriver(str(tmp_path), host(is_root=False), graphical=True)
    calls = _capture_run(monkeypatch)
    d._backend, d._pgid, d._proc = "native", 4321, _GracefulProc()
    d.cancel()
    cmd, env = calls[0]
    assert cmd == ["sudo", "-A", "kill", "-TERM", "-4321"]   # SAME prefix, negative pgid
    assert env["SUDO_ASKPASS"] == "/run/ap.sh"


def test_kill_tree_terminal_launch_still_plain_sudo(monkeypatch, tmp_path):
    """Regression guard: a NON-graphical non-root cancel keeps the plain sudo kill (the
    existing test_build_driver_cancel invariant) with no SUDO_ASKPASS env."""
    d = BuildDriver(str(tmp_path), host(is_root=False), graphical=False)
    calls = _capture_run(monkeypatch)
    d._backend, d._pgid, d._proc = "native", 7777, _GracefulProc()
    d.cancel()
    cmd, env = calls[0]
    assert cmd == ["sudo", "kill", "-TERM", "-7777"]
    assert env is None


# ── env plumbing into Popen ──────────────────────────────────────────────────────────
class _FakeProc:
    def __init__(self, pid=999):
        self.pid = pid
        self.stdout = iter([])

    def wait(self, timeout=None):
        return 0


def _capture_popen(monkeypatch):
    seen = {}

    def fake_popen(cmd, **kwargs):
        seen.update(kwargs)
        seen["cmd"] = list(cmd)
        return _FakeProc()

    monkeypatch.setattr(bd.subprocess, "Popen", fake_popen)
    return seen


def test_spawn_native_graphical_plumbs_askpass_env(monkeypatch, tmp_path):
    _force_sudo_a(monkeypatch, askpass="/run/ap.sh")
    seen = _capture_popen(monkeypatch)
    d = BuildDriver(str(tmp_path), host(is_root=False), graphical=True)
    d.run(_cfg(tmp_path), "native")
    assert seen["env"]["SUDO_ASKPASS"] == "/run/ap.sh"   # caller env carries it for sudo
    assert seen["start_new_session"] is True             # kill-tree session preserved


def test_spawn_docker_inherits_env_even_when_graphical(monkeypatch, tmp_path):
    _force_sudo_a(monkeypatch)
    seen = _capture_popen(monkeypatch)
    d = BuildDriver(str(tmp_path), host(is_root=False), graphical=True)
    d.run(_cfg(tmp_path, "x86", "omnibus"), "docker")
    assert seen["env"] is None                           # docker never elevates -> inherit
    assert seen["start_new_session"] is False


# ── the askpass helper file itself ───────────────────────────────────────────────────
def test_askpass_helper_is_written_executable_and_self_contained(monkeypatch, tmp_path):
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path / "cache"))
    monkeypatch.setattr(bd, "_ASKPASS_PATH_CACHE", None)
    p = bd._askpass_helper_path()
    assert p and os.access(p, os.X_OK)
    body = open(p, encoding="utf-8").read()
    assert "--askpass" in body and "snapdragon_studio" in body
    assert body.startswith("#!")

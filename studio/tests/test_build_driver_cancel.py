"""BuildDriver per-image cancel (design 2.5) — the fixes that make an honest per-image
Stop possible. Docker: a stable ``--name`` + ``--init`` so ``docker kill`` reaches PID1
(a forwarded TERM to the docker CLI never stops the PID1 bash builder). Native: a fresh
session so ``kill -TERM -<pgid>`` (sudo-wrapped when non-root) reaches the whole
sudo→bash→emerge tree that plain Popen.terminate() cannot signal, with a KILL escalation."""
import re
import subprocess

import pytest

from hugmesh_studio.core.build_driver import BuildDriver
from hugmesh_studio.core.config import ImageConfig
from hugmesh_studio.core.platform_info import HostInfo

_RUN = "hugmesh_studio.core.build_driver.subprocess.run"
_POPEN = "hugmesh_studio.core.build_driver.subprocess.Popen"


def host(is_root=True, has_docker=True):
    return HostInfo(os="linux", is_gentoo=True, has_docker=has_docker, has_bash=True,
                    has_kvm=False, is_root=is_root, builder_image="hugmesh-builder")


def _cfg(tmp_path, platform="x86", role="omnibus"):
    return ImageConfig(mode="mesh", role=role, platform=platform, tailscale=True,
                       output_dir=str(tmp_path / "out"), jobs=4)


class FakeProc:
    def __init__(self, pid=4242, wait_raises=False, wait_code=0):
        self.pid = pid
        self._raises = wait_raises
        self._code = wait_code
        self.terminated = False
        self.stdout = iter([])

    def poll(self):
        return None

    def wait(self, timeout=None):
        if self._raises and timeout is not None:
            raise subprocess.TimeoutExpired(cmd="build", timeout=timeout)
        return self._code

    def terminate(self):
        self.terminated = True


def _capture_run(monkeypatch):
    calls = []

    def fake_run(cmd, **kwargs):
        calls.append(list(cmd))
        return subprocess.CompletedProcess(cmd, 0)

    monkeypatch.setattr(_RUN, fake_run)
    return calls


# ── docker: command handle + kill ────────────────────────────────────────────────────
def test_docker_command_carries_init_and_stable_name(tmp_path):
    d = BuildDriver(str(tmp_path), host())
    assert re.fullmatch(r"sd-build-[0-9a-f]{12}", d._container_name)
    cmd = d.command(_cfg(tmp_path), "docker")
    assert cmd[:4] == ["docker", "run", "--rm", "--privileged"]   # legacy prefix intact
    i = cmd.index("--name")
    assert cmd[i - 1] == "--init"
    assert cmd[i + 1] == d._container_name
    assert i < cmd.index("hugmesh-builder")                    # a docker-run arg, not inner argv
    assert "--name" not in cmd[-1]                                # never leaks into the builder argv


def test_docker_command_name_stable_across_calls(tmp_path):
    d = BuildDriver(str(tmp_path), host())
    a = d.command(_cfg(tmp_path), "docker")
    b = d.command(_cfg(tmp_path), "docker")
    assert a[a.index("--name") + 1] == b[b.index("--name") + 1] == d._container_name


def test_cancel_docker_kills_container_by_name(monkeypatch, tmp_path):
    d = BuildDriver(str(tmp_path), host())
    calls = _capture_run(monkeypatch)
    d._backend, d._proc = "docker", FakeProc()
    d.cancel()
    assert ["docker", "kill", d._container_name] in calls
    assert d._cancel.is_set()


# ── native: new session + group kill ─────────────────────────────────────────────────
def _capture_popen(monkeypatch, proc):
    seen = {}

    def fake_popen(cmd, **kwargs):
        seen["cmd"] = list(cmd)
        seen.update(kwargs)
        return proc

    monkeypatch.setattr(_POPEN, fake_popen)
    return seen


def test_native_run_starts_new_session_and_records_pgid(monkeypatch, tmp_path):
    d = BuildDriver(str(tmp_path), host(is_root=True))
    seen = _capture_popen(monkeypatch, FakeProc(pid=9999))
    code = d.run(_cfg(tmp_path), "native")
    assert code == 0
    assert seen["start_new_session"] is True
    assert d._pgid == 9999 and d._backend == "native"


def test_docker_run_does_not_start_new_session(monkeypatch, tmp_path):
    d = BuildDriver(str(tmp_path), host())
    seen = _capture_popen(monkeypatch, FakeProc(pid=9999))
    d.run(_cfg(tmp_path), "docker")
    assert seen["start_new_session"] is False
    assert d._pgid is None and d._backend == "docker"


def test_cancel_native_root_sends_term_to_group(monkeypatch, tmp_path):
    d = BuildDriver(str(tmp_path), host(is_root=True))
    calls = _capture_run(monkeypatch)
    d._backend, d._pgid, d._proc = "native", 5555, FakeProc()   # wait()==0 -> no escalation
    d.cancel()
    assert ["kill", "-TERM", "-5555"] in calls
    assert not any("-KILL" in c for c in calls)                  # graceful exit -> no KILL
    assert not any(c[:2] == ["docker", "kill"] for c in calls)   # native leg only


def test_cancel_native_nonroot_wraps_kill_in_sudo(monkeypatch, tmp_path):
    # This test's SUBJECT is the sudo argv: it fakes subprocess.run and must reach the
    # fake past the driver's under-pytest refusal (build_driver.guard_elevation).
    monkeypatch.setenv("HUGMESH_STUDIO_ALLOW_ELEVATION_UNDER_TEST", "1")
    d = BuildDriver(str(tmp_path), host(is_root=False))
    calls = _capture_run(monkeypatch)
    d._backend, d._pgid, d._proc = "native", 7777, FakeProc()
    d.cancel()
    assert ["sudo", "kill", "-TERM", "-7777"] in calls


def test_cancel_native_escalates_to_kill_on_timeout(monkeypatch, tmp_path):
    d = BuildDriver(str(tmp_path), host(is_root=True))
    calls = _capture_run(monkeypatch)
    d._backend, d._pgid = "native", 8888
    d._proc = FakeProc(wait_raises=True)                          # ignores TERM -> escalate
    d.cancel()
    assert ["kill", "-TERM", "-8888"] in calls
    assert ["kill", "-KILL", "-8888"] in calls


def test_cancel_is_safe_before_any_run(tmp_path):
    # no backend/proc yet -> cancel must not raise
    BuildDriver(str(tmp_path), host()).cancel()

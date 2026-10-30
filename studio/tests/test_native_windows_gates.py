"""The Windows MSI runs the Studio natively, and the local-mesh and DevOps verbs cannot.

Measured on Windows 11 with the 0.3.0-beta.1 MSI (2026-10-23): "Bootstrapping",
"Building maven prerequisites" and "Installing DevOps prerequisites" all failed. The
first two said "make is required" (installing make would not help: the recipes are
bash, and System32\\bash.exe is the WSL launcher); the third said "Automatic install
covers Linux only". None named WSL2, the supported Windows runtime. Qt-free: every
gate here is core code, and the GUI refusal is the same sentence.
"""
from __future__ import annotations

import functools
import os
import subprocess
import types

import pytest

from hugmesh_studio.core import devops_tools, platform_info, qemu_tests
from hugmesh_studio.core import local_stack_node as lsn
from hugmesh_studio.core.build_driver import BuildDriver
from hugmesh_studio.core.cloud_deploy import CloudDeploy, CloudDeployOptions
from hugmesh_studio.core.config import ImageConfig
from hugmesh_studio.core.golive_driver import GoLiveDriver
from hugmesh_studio.core.phone_wizard import PhoneWizard
from hugmesh_studio.core.platform_info import HostInfo
from hugmesh_studio.core.worklist_driver import GENKEYS_SCRIPT, WorklistDriver


@pytest.fixture
def as_native_windows(monkeypatch):
    """Answer as the Windows build would, without changing os.name for the process
    (pathlib and subprocess read it too)."""
    monkeypatch.setattr(platform_info, "native_windows_blocker",
                        functools.partial(platform_info.native_windows_blocker,
                                          osname="nt"))


def test_the_sentence_names_wsl2_and_nothing_elsewhere():
    said = platform_info.native_windows_blocker("The local stack", osname="nt")
    assert said.startswith("The local stack runs `make` and bash scripts")
    assert "WSL2" in said and "Docker Desktop" in said and "/mnt/c" in said
    assert platform_info.native_windows_blocker("The local stack", osname="posix") == ""


def test_the_local_stack_says_wsl_not_make(as_native_windows, tmp_path):
    node = lsn.LocalStackNode(str(tmp_path))
    ok, why = node.available()
    assert not ok
    assert "WSL2" in why and "make is required" not in why, why


def test_the_devops_lane_says_wsl_not_install_kind(as_native_windows, tmp_path):
    problems = lsn.LocalStackNode(str(tmp_path)).devops_available()
    assert len(problems) == 1 and "WSL2" in problems[0], problems
    assert "Install DevOps prerequisites" not in problems[0], problems


def test_the_installer_refuses_with_the_same_sentence(as_native_windows, tmp_path):
    said: list[str] = []
    ok, msg = devops_tools.install(str(tmp_path), on_line=said.append)
    assert not ok and "WSL2" in msg, msg
    assert said and "WSL2" in said[0], said        # streamed, not only returned


# ── issue #827 group 1: bash drivers that were reachable from native Windows ─────────
@pytest.fixture
def no_spawn(monkeypatch):
    """A refusal must come BEFORE the spawn: on Windows the spawn is the failure."""
    def boom(*a, **k):
        raise AssertionError(f"spawned {a[0] if a else k.get('args')}")
    monkeypatch.setattr(subprocess, "Popen", boom)
    monkeypatch.setattr(subprocess, "run", boom)


def test_the_sentence_names_what_the_action_runs():
    said = platform_info.native_windows_blocker("Go Live", osname="nt", runs="bash scripts")
    assert said.startswith("Go Live runs bash scripts from") and "`make`" not in said


def test_go_live_says_why_instead_of_listing_no_provider(as_native_windows, no_spawn,
                                                         tmp_path):
    d = GoLiveDriver(str(tmp_path), is_root=False)
    assert "WSL2" in d.blocker()
    assert d.providers() == [] and d.models() == []
    assert "WSL2" in d.status_text()                # the preflight page shows this text
    said: list[str] = []
    assert d.run("plan", types.SimpleNamespace(), on_line=said.append) == 2
    assert said and "WSL2" in said[0], said


def test_cloud_deploy_is_unavailable_and_stages_no_creds(as_native_windows, no_spawn,
                                                         tmp_path, monkeypatch):
    drv = tmp_path / "hugmesh-cloud-deploy"
    drv.write_text("#!/bin/bash\n")
    monkeypatch.setenv("SNAP_CLOUD_DEPLOY_CMD", str(drv))  # exists: X_OK was the old test
    cd = CloudDeploy(str(tmp_path), CloudDeployOptions(creds="secret"))
    ok, why = cd.available()
    assert not ok and "WSL2" in why and "Cloud deploy" in why, why
    assert cd.providers() == []
    monkeypatch.setattr(cd, "_stage_creds",
                        lambda *_: pytest.fail("creds staged on a refused verb"))
    launched, msg = cd.run_verb_in_terminal("apply")
    assert not launched and "WSL2" in msg, msg


def test_the_phone_wizard_is_unavailable(as_native_windows, tmp_path, monkeypatch):
    drv = tmp_path / "phone-wizard.sh"
    drv.write_text("#!/bin/bash\n")
    monkeypatch.setenv("SNAP_PHONE_WIZARD", str(drv))
    ok, why = PhoneWizard(str(tmp_path)).available()
    assert not ok and "WSL2" in why and "phone wizard" in why, why


def test_qemu_lanes_refuse_before_spawning(as_native_windows, no_spawn, tmp_path):
    assert "WSL2" in qemu_tests.native_blocker()
    said: list[str] = []
    rc = qemu_tests.QemuTestRunner(str(tmp_path)).run(qemu_tests.QemuRunOptions(),
                                                      on_line=said.append)
    assert rc == 2 and said and "WSL2" in said[0], said


def test_a_native_build_is_refused_even_with_windows_sudo(as_native_windows, tmp_path):
    host = HostInfo(os="windows", is_gentoo=False, has_docker=True, has_bash=True,
                    has_kvm=False, is_root=False, builder_image="hugmesh-builder")
    d = BuildDriver(str(tmp_path), host)
    d._can_elevate = lambda: True                      # Windows 11's sudo.exe
    problems = d.preflight(ImageConfig(), "native")
    said = [p for p in problems if "native build" in p]
    assert said and "docker backend" in said[0] and "WSL2" in said[0], problems
    assert not any("elevation helper" in p for p in problems), problems


def _wl(backend):
    return types.SimpleNamespace(
        backend=backend, generator_dir=r"C:\src\hugmesh-generator",
        host=types.SimpleNamespace(builder_image="hugmesh-builder"))


def test_windows_keys_run_in_the_builder_container():
    out = r"C:\out\sessions\s1\keys-node1"
    args = ["--role", "host", "--out", out, "--random", "--superdomain", "acme.internal"]
    cmd = WorklistDriver._genkeys_command(_wl("docker"), "ignored", "acme", args,
                                          osname="nt")
    assert cmd[:4] == ["docker", "run", "--rm", "--init"]
    assert f"{os.path.dirname(out)}:/keys" in cmd and "BRAND=acme" in cmd
    i = cmd.index("hugmesh-builder")
    assert cmd[i + 1:] == ["bash", "./" + GENKEYS_SCRIPT.replace(os.sep, "/"),
                           "--role", "host", "--out", "/keys/keys-node1", "--random",
                           "--superdomain", "acme.internal"]
    assert args[3] == out                              # the caller's list is untouched


def test_keys_argv_is_unchanged_off_windows():
    args = ["--role", "host", "--out", "/o/keys-n", "--random"]
    for osname, backend in (("posix", "docker"), ("posix", "native"), ("nt", "native")):
        assert WorklistDriver._genkeys_command(_wl(backend), "/g/s.sh", "b", args,
                                               osname=osname) == ["/g/s.sh", *args]

"""The Windows MSI runs the Studio natively, and the local-mesh and DevOps verbs cannot.

Measured on Windows 11 with the 0.3.0-beta.1 MSI (2026-10-23): "Bootstrapping",
"Building maven prerequisites" and "Installing DevOps prerequisites" all failed. The
first two said "make is required" (installing make would not help: the recipes are
bash, and System32\\bash.exe is the WSL launcher); the third said "Automatic install
covers Linux only". None named WSL2, the supported Windows runtime. The gates are
core code, and the GUI refusal is the same sentence; the page tests at the end
(skipped without a Qt binding) pin that each page actually asks, because a core gate
on a path no page takes protects nobody.
"""
from __future__ import annotations

import functools
import ntpath
import os
import subprocess
import types

import pytest

# must be set BEFORE the first QApplication is created (the page tests below)
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from hugmesh_studio.core import devops_tools, emulation, mesh_emulation  # noqa: E402
from hugmesh_studio.core import platform_info, qemu_tests                # noqa: E402
from hugmesh_studio.core import local_stack_node as lsn                  # noqa: E402
from hugmesh_studio.core.build_driver import BuildDriver                 # noqa: E402
from hugmesh_studio.core.cloud_deploy import CloudDeploy, CloudDeployOptions  # noqa: E402
from hugmesh_studio.core.config import ImageConfig                       # noqa: E402
from hugmesh_studio.core.golive_driver import GoLiveDriver               # noqa: E402
from hugmesh_studio.core.phone_wizard import PhoneWizard                 # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                   # noqa: E402
from hugmesh_studio.core.worklist_driver import GENKEYS_SCRIPT, WorklistDriver  # noqa: E402

_REAL_BLOCKER = platform_info.native_windows_blocker


def _answer_as(monkeypatch, osname):
    monkeypatch.setattr(platform_info, "native_windows_blocker",
                        functools.partial(_REAL_BLOCKER, osname=osname))


@pytest.fixture
def as_native_windows(monkeypatch):
    """Answer as the Windows build would, without changing os.name for the process
    (pathlib and subprocess read it too)."""
    _answer_as(monkeypatch, "nt")


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


def test_the_emulation_spawn_refuses_a_script_before_popen(as_native_windows, no_spawn,
                                                           tmp_path):
    """The pages run their lanes through emulation.spawn, not QemuTestRunner; there the
    WinError 193 used to come back as "!! could not run ...run-qemu-docker.sh"."""
    runner = os.path.join(str(tmp_path), qemu_tests.RUNNER_SCRIPT)
    for spawn in (emulation.spawn, mesh_emulation.spawn):       # the alias, too
        said: list[str] = []
        assert spawn([runner, "--keep-alive"], str(tmp_path), on_line=said.append) == 2
        assert said and "WSL2" in said[0] and "could not run" not in said[0], said


def test_the_cli_save_mesh_refuses_before_its_own_exec(as_native_windows, no_spawn,
                                                       tmp_path, monkeypatch, capsys):
    """save-mesh without run= execs the runner through emulation_save, not spawn()."""
    from hugmesh_studio.core import emulation_save
    monkeypatch.setattr(emulation_save, "_run_argv",
                        lambda argv: pytest.fail(f"ran {argv[0]}"))
    sess = tmp_path / "out" / "sessions" / "20260819-101010-mesh00"
    sess.mkdir(parents=True)
    (sess / "hugmesh-x86-amd64-be-test-20260819T101010Z.img").write_bytes(b"\0")
    rc = emulation.main(["save-mesh", "--generator-dir", str(tmp_path)])
    err = capsys.readouterr().err
    assert rc == 2 and "WSL2" in err and "could not run" not in err, err


def test_the_device_poll_does_not_exec_the_runner(as_native_windows, no_spawn, tmp_path):
    # None is the documented "runner did not answer": the registry answers instead.
    assert emulation._runner_devices(str(tmp_path), str(tmp_path)) is None


def _docker_info_exits(monkeypatch, rc=1, raises=None):
    def run(*_a, **_k):
        if raises:
            raise raises
        return subprocess.CompletedProcess(["docker", "info"], rc, None, "refused")
    monkeypatch.setattr(qemu_tests.subprocess, "run", run)
    monkeypatch.setattr(qemu_tests, "wsl_docker_remedy", lambda: "")   # not under WSL


def test_docker_down_on_windows_says_start_docker_desktop(monkeypatch):
    """Windows has no 'docker' group (Docker Desktop's is docker-users): the daemon IS
    Docker Desktop, so starting it is the whole fix."""
    _docker_info_exits(monkeypatch)
    ok, why = qemu_tests.docker_available(osname="nt")
    assert not ok and "start Docker Desktop" in why and "'docker' group" not in why, why
    ok, why = qemu_tests.docker_available(osname="posix")
    assert not ok and "'docker' group" in why, why                       # unchanged
    _docker_info_exits(monkeypatch, raises=FileNotFoundError("docker"))
    assert "Install Docker Desktop" in qemu_tests.docker_available(osname="nt")[1]
    assert qemu_tests.docker_available(osname="posix")[1] == "docker was not found on PATH."


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
    assert f"{ntpath.dirname(out)}:/keys" in cmd and "BRAND=acme" in cmd
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


# ── the pages ask too ──────────────────────────────────────────────────────────────
# Each test answers once as Linux (the control: the same call arms the control there)
# and once as the MSI, so it means the same thing on either CI job.
_GENERATOR_DIR = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))


def _host(os_name):
    # a canned host so wizard construction never probes the machine (docker info &c.)
    return HostInfo(os=os_name, is_gentoo=os_name == "linux", has_docker=False,
                    has_bash=True, has_kvm=False, is_root=False,
                    builder_image="hugmesh-builder")


@pytest.fixture(scope="session")
def qapp():
    pytest.importorskip("hugmesh_studio.gui.qt",
                        reason="no Qt binding (PySide6/PyQt6) installed")
    from hugmesh_studio.gui.qt import QtWidgets
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def studio(qapp, monkeypatch):
    from hugmesh_studio.gui import wizard as wizard_mod
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": _host("linux"))
    monkeypatch.setattr(qemu_tests, "docker_available",
                        lambda *_a, **_k: (True, "docker is available."))
    w = wizard_mod.StudioWizard(_GENERATOR_DIR)
    yield w
    w.close()
    w.deleteLater()


def _page(wiz, cls):
    for pid in wiz.pageIds():
        if isinstance(wiz.page(pid), cls):
            return wiz.page(pid)
    raise AssertionError(f"no {cls.__name__} in the wizard")


def test_the_qemu_page_greys_every_lane_with_docker_up(studio, monkeypatch):
    from hugmesh_studio.gui.pages.qemu import QemuPage
    page = _page(studio, QemuPage)
    page.plan = types.SimpleNamespace(rows=["x86/be"])     # something to run
    page.pw_row.blockSignals(True)                          # no command preview
    page.pw_row.clear()
    page.pw_row.addItem("x86/be", "x86/be")
    page.pw_row.blockSignals(False)
    _answer_as(monkeypatch, "posix")
    page._docker_answered_paint((True, "docker is available."))
    assert page.run_btn.isEnabled() and page.pw_list_btn.isEnabled()
    _answer_as(monkeypatch, "nt")
    page._docker_answered_paint((True, "docker is available."))
    assert not page.run_btn.isEnabled() and not page.list_btn.isEnabled()
    assert not page.pw_list_btn.isEnabled() and not page.pw_run_btn.isEnabled()
    assert "WSL2" in page.docker_note.text()


def test_the_mesh_emulation_page_does_not_arm_start_on_docker_alone(studio, monkeypatch):
    from hugmesh_studio.gui.pages.mesh_emulation import MeshEmulationPage
    page = _page(studio, MeshEmulationPage)
    _answer_as(monkeypatch, "posix")
    page._docker_paint((True, "docker is available."))
    assert page._docker_ok                       # Start, row Start and "+" read this
    _answer_as(monkeypatch, "nt")
    page._docker_paint((True, "docker is available."))
    assert not page._docker_ok and not page.start_btn.isEnabled()
    assert "WSL2" in page.docker_note.text()
    assert "docker group" not in page.docker_note.text()


def test_the_build_page_offers_no_native_backend_on_windows(studio):
    from hugmesh_studio.gui.pages.build import BuildPage
    combo = _page(studio, BuildPage).backend
    items = [combo.itemText(i) for i in range(combo.count())]
    assert ("native" in items) == (os.name != "nt"), items


def test_go_live_preflight_will_not_lead_to_an_empty_provider_page(qapp, monkeypatch,
                                                                   tmp_path):
    from hugmesh_studio.gui.pages import golive as golive_mod
    monkeypatch.setattr(golive_mod.GoLiveDriver, "status_text", lambda self: "status")
    _answer_as(monkeypatch, "nt")                # built as the MSI: providers() stays put
    w = golive_mod.GoLiveWizard(str(tmp_path))
    try:
        preflight = w.page(w.pageIds()[0])
        assert isinstance(preflight, golive_mod.GoLivePreflightPage)
        assert not preflight.isComplete()
        _answer_as(monkeypatch, "posix")
        assert preflight.isComplete()
    finally:
        w.close()
        w.deleteLater()


def test_post_build_qemu_tests_refuse_instead_of_reporting_failures(studio, monkeypatch,
                                                                    as_native_windows):
    """The runner used to be handed to _FlashWorker anyway, and the WinError 193 came
    back as "QEMU device tests reported failures" for tests that never ran."""
    from hugmesh_studio.gui.pages import progress
    page = studio.page(studio._page_ids["progress"])
    monkeypatch.setattr(progress, "_FlashWorker",
                        lambda *_a, **_k: pytest.fail("spawned the runner"))
    monkeypatch.setattr(studio.cfg, "qemu_device_tests", True)
    page._maybe_qemu_tests()
    log = page.log.toPlainText()
    assert "WSL2" in log and "reported failures" not in log, log
    assert page.qemu_worker is None


def test_the_flash_panel_says_why_it_never_appears(studio, monkeypatch):
    from hugmesh_studio.core import flash_targets
    page = studio.page(studio._page_ids["progress"])
    monkeypatch.setattr(flash_targets, "list_targets", lambda: [])
    monkeypatch.setattr(page, "_run_all_ok", lambda: True)
    page._all_terminal = True
    monkeypatch.setattr(studio, "host", _host("linux"))
    page._refresh_flash_targets()
    assert page.flash_blocked_note.isHidden()    # Linux, no stick: the old silence
    monkeypatch.setattr(studio, "host", _host("windows"))
    page._refresh_flash_targets()
    assert not page.flash_blocked_note.isHidden() and page.flash_group.isHidden()
    said = page.flash_blocked_note.text()
    assert "WSL2" in said and "usbipd attach" in said, said

"""Windows sweep, cluster c7: the Home, Limits, Key-zip, Progress and Review pages.

Measured on the Windows sweep (2026-10-30, branch win/studio-windows-sweep-20261030):

* Home: the copy-a-home tooltips said ``tar czf home.tgz -C /home you`` and
  ``scripts/seed-packages-from-running-system.sh`` about "this machine", which on the
  MSI has neither /home nor Portage.
* Limits: any Memory text was saved ("abc" became ``--memory abc`` on every later docker
  run), and the GPU field ran ``docker info`` on the GUI thread per keystroke.
* Key-zip: the remember-roles help named a fixed ~/.config path and "mode 0600".
* Progress: the Windows "watch it in a terminal" command used the wildcard -Path, so a
  folder such as ``D:\\Builds [2026]`` resolved to nothing.
* Review: with Docker Desktop stopped, "auto" resolved to no backend and BuildDriver's
  RuntimeError escaped initializePage and validatePage (blank page, Continue enabled,
  crash log on click); "Build builder image now" lost its output to the next preflight;
  a refused held file showed its path with every backslash doubled.

Windows behaviour is selected through ``osname``/``host.os`` parameters, never by
changing os.name, so everything but the real-PowerShell check runs on Linux CI too.
"""
from __future__ import annotations

import functools
import os
import subprocess
import threading
import time
import types

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import build_driver as bd               # noqa: E402
from hugmesh_studio.core import resource_limits as rl            # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo           # noqa: E402
from hugmesh_studio.gui import limits_dialog                     # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod              # noqa: E402
from hugmesh_studio.gui.pages import build as build_page         # noqa: E402
from hugmesh_studio.gui.pages import home as home_page           # noqa: E402
from hugmesh_studio.gui.pages import keyzip as keyzip_page        # noqa: E402
from hugmesh_studio.gui.pages import progress as progress_page    # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                      # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

# Docker Desktop installed but stopped: no docker, no native build -> backend "none".
NO_BACKEND_HOST = HostInfo(os="linux", is_gentoo=False, has_docker=False, has_bash=True,
                           has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(scope="module")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


# ── Home: copy-a-home hints ──────────────────────────────────────────────────────────

def test_home_hints_on_windows_give_no_linux_only_advice_about_this_machine():
    hints = home_page.home_hints(osname="nt")
    for key in ("copy_tip", "archive_tip", "seed_packages_tip"):
        assert "-C /home you" not in hints[key], key
    assert "Make one with" not in hints["seed_packages_tip"]
    assert "This Machine's" not in hints["copy_label"]
    # where the file has to come from, and a path shape a Windows user has
    assert "Linux machine whose home it is" in hints["copy_tip"]
    assert "C:\\Users\\" in hints["archive_tip"]
    assert "Gentoo system" in hints["seed_packages_tip"]
    assert "this machine" not in hints["archive_mode"].lower()


def test_home_hints_on_linux_keep_the_original_wording():
    hints = home_page.home_hints(osname="posix")
    assert hints["copy_label"] == "Copy This Machine's Home Folder…"
    assert "e.g. tar czf home.tgz -C /home you" in hints["copy_tip"]
    assert hints["seed_packages_tip"].endswith(
        "Make one with scripts/seed-packages-from-running-system.sh.")
    assert hints["archive_mode"] == home_page._HOME_MODE_HELP["archive"]


def test_home_page_shows_the_windows_hints(qapp, monkeypatch):
    monkeypatch.setattr(home_page, "home_hints",
                        functools.partial(home_page.home_hints, osname="nt"))
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": NO_BACKEND_HOST)
    wiz = wizard_mod.StudioWizard(GENERATOR_DIR)
    try:
        page = wiz.page(wiz._page_ids["home"])
        assert "/home you" not in page.copy_home_btn.toolTip()
        assert "/home you" not in page.include_archive_labeled_row.toolTip()
        assert "Make one with" not in page.seed_packages_labeled_row.toolTip()
        page.mode.setCurrentText("archive")
        assert "a Windows user folder is not a Linux home" in page.mode_help.text()
    finally:
        wiz.close(); wiz.deleteLater()


# ── Limits: memory validation, GPU probe ──────────────────────────────────────────────

@pytest.mark.parametrize("text", ["abc", "16 GB", "16gb", "-1g", "1", "g"])
def test_memory_error_refuses_what_docker_or_the_overlay_cannot_read(text):
    assert limits_dialog.memory_error(text)


@pytest.mark.parametrize("text", ["", "  ", "16g", "8192m", "1.5g", "16G", "512m"])
def test_memory_error_accepts_docker_sizes_and_empty(text):
    assert limits_dialog.memory_error(text) == ""


@pytest.mark.parametrize("text", ["0", "0g", "0.0m"])
def test_memory_error_does_not_call_zero_below_dockers_minimum(text):
    # Docker reads a zero --memory as no limit, not as a size below its 6 MiB floor.
    msg = limits_dialog.memory_error(text)
    assert msg and "minimum" not in msg and "means no limit to Docker" in msg


@pytest.mark.parametrize("text", ["16 GB", "16gb", "16GiB"])
def test_memory_error_does_not_claim_docker_cannot_read_go_units_spellings(text):
    # Docker's RAMInBytes takes all three; only the stack overlay's parse_size cannot.
    msg = limits_dialog.memory_error(text)
    assert msg and "not a size Docker reads" not in msg
    assert "mesh stack" in msg


def test_limits_dialog_does_not_save_an_unreadable_memory(qapp, tmp_path):
    path = str(tmp_path / "limits.json")
    dlg = limits_dialog.LimitsDialog(settings_path=path, gpu_probe=lambda: True)
    try:
        dlg.mem_edit.setText("abc")
        assert not dlg._save_btn.isEnabled()
        assert not dlg.mem_error.isHidden()
        assert "abc" in dlg.mem_error.text()
        assert "abc of memory" not in dlg.effect.text()
        dlg.accept()
        assert not os.path.exists(path)
        assert rl.docker_run_args(rl.effective(path=path)).count("abc") == 0
        dlg.mem_edit.setText("16g")
        assert dlg._save_btn.isEnabled()
        dlg.accept()
        assert rl.effective(path=path).memory == "16g"
    finally:
        dlg.deleteLater()


def test_limits_dialog_probes_the_gpu_runtime_once_and_off_the_typing(qapp, tmp_path):
    calls = []
    release = threading.Event()

    def probe():
        calls.append(1)
        # docker info is slow; this one answers only once the typing below is done, so
        # typing that waited on it would hang here instead of passing on timing luck
        release.wait(30)
        return False

    dlg = limits_dialog.LimitsDialog(settings_path=str(tmp_path / "l.json"),
                                     gpu_probe=probe, osname="posix")
    try:
        for text in ("a", "al", "all"):
            dlg.gpu_edit.setText(text)
        dlg.mem_edit.setText("16g")
        assert dlg._gpu_runtime is None     # typing finished with the probe still out
        assert dlg.warning.isHidden()       # and nothing claimed before it answers
        release.set()
        deadline = time.monotonic() + 5
        while dlg._gpu_runtime is None and time.monotonic() < deadline:
            qapp.processEvents()
            time.sleep(0.01)
        assert calls == [1]
        assert dlg._gpu_runtime is False
        assert "NVIDIA Container Toolkit" in dlg.warning.text()
    finally:
        release.set()
        dlg.deleteLater()


def test_limits_dialog_on_windows_never_runs_the_linux_runtime_probe(qapp, tmp_path):
    def probe():
        raise AssertionError("docker info probed on Windows")

    dlg = limits_dialog.LimitsDialog(settings_path=str(tmp_path / "l.json"),
                                     gpu_probe=probe, osname="nt")
    try:
        dlg.gpu_edit.setText("all")
        qapp.processEvents()
        assert dlg.warning.text() == limits_dialog.WINDOWS_GPU_NOTE
        assert "NVIDIA Container Toolkit" not in dlg.warning.text()
    finally:
        dlg.deleteLater()


# ── Key-zip: remember-roles help ─────────────────────────────────────────────────────

def test_remember_roles_help_names_the_real_file_and_no_mode_on_windows(tmp_path):
    path = str(tmp_path / "login" / "roles.json")
    text = keyzip_page.remember_roles_help(path, osname="nt")
    assert path in text
    assert "0600" not in text
    assert "~/.config" not in text


def test_remember_roles_help_on_linux_keeps_the_default_wording_and_shows_overrides(
        tmp_path, monkeypatch):
    monkeypatch.delenv("HUGMESH_LOCAL_LOGIN_MANIFEST", raising=False)
    monkeypatch.delenv("XDG_CONFIG_HOME", raising=False)
    text = keyzip_page.remember_roles_help(None, osname="posix")
    assert "(~/.config/hugmesh-studio/local-login/roles.json, mode 0600)" in text
    override = str(tmp_path / "roles.json")
    assert f"({override}, mode 0600)" in keyzip_page.remember_roles_help(
        override, osname="posix")
    monkeypatch.setenv("HUGMESH_LOCAL_LOGIN_MANIFEST", override)
    assert f"({override}, mode 0600)" in keyzip_page.remember_roles_help(
        None, osname="posix")


# ── Progress: the Windows follow command ──────────────────────────────────────────────

def _watch(path, host_os):
    stub = types.SimpleNamespace(wiz=types.SimpleNamespace(
        host=types.SimpleNamespace(os=host_os)))
    return progress_page.ProgressPage._watch_command(stub, path)


def test_windows_watch_command_is_a_literal_single_quoted_path(tmp_path):
    log = tmp_path / "D [2026] $x `y" / "build.log"
    log.parent.mkdir()
    log.write_text("hello\n", encoding="utf-8")
    cmd = _watch(str(log), "windows")
    assert cmd == f"Get-Content -LiteralPath '{log}' -Wait -Tail 50"
    # an apostrophe (typographic ones too) is doubled, PowerShell's own escape
    assert progress_page.powershell_quote("Jo's\u2019") == "'Jo''s\u2019\u2019'"


def test_windows_watch_command_waits_for_a_log_that_does_not_exist_yet(tmp_path):
    cmd = _watch(str(tmp_path / "later.log"), "windows")
    assert cmd.startswith("while (-not (Test-Path -LiteralPath ")
    assert cmd.endswith("-Wait -Tail 50")


def test_linux_watch_command_is_unchanged(tmp_path):
    assert _watch("/out/a b/build.log", "linux") == "tail -F -n +1 '/out/a b/build.log'"


@pytest.mark.skipif(os.name != "nt", reason="runs Windows PowerShell")
def test_windows_watch_command_reads_a_bracketed_path_in_powershell(tmp_path):
    log = tmp_path / "J\u00f6hn [Work] out" / "build.log"
    log.parent.mkdir()
    log.write_text("hello\n", encoding="utf-8")
    # the copied command minus -Wait (which would follow forever)
    cmd = _watch(str(log), "windows").replace(" -Wait", "")
    proc = subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", cmd],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    assert proc.returncode == 0, proc.stderr
    assert "hello" in proc.stdout


# ── Review: no backend, builder-image transcript, held-file path ──────────────────────

def _no_backend_build_page(monkeypatch, tmp_path):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": NO_BACKEND_HOST)
    wiz = wizard_mod.StudioWizard(GENERATOR_DIR)
    page = wiz.page(wiz._page_ids["build"])
    page.outdir.setText(str(tmp_path / "out"))
    page._recompute_timer.setInterval(0)
    return wiz, page


def _settle(qapp, page):
    deadline = time.monotonic() + 15
    while page._recompute_busy and time.monotonic() < deadline:
        qapp.processEvents()
        time.sleep(0.01)
    page._join_preflight_worker()
    qapp.processEvents()


def test_review_with_no_backend_refuses_instead_of_raising(qapp, monkeypatch, tmp_path):
    wiz, page = _no_backend_build_page(monkeypatch, tmp_path)
    try:
        page.initializePage()               # raised RuntimeError before the fix
        assert page.summary.text()          # the review is still shown
        assert page.cmd.toPlainText() == ""
        _settle(qapp, page)
        assert page._problems, "a blocking preflight sentence"
        assert any("No build backend" in p or "Cannot assemble" in p
                   for p in page._problems), page._problems
        assert page.isComplete() is False
        assert "Preflight" in page.log.toPlainText()
        assert page.validatePage() is False  # raised again before the fix
    finally:
        page._join_preflight_worker()
        wiz.close(); wiz.deleteLater()


def test_no_backend_keeps_continue_greyed_even_on_an_empty_preflight(
        qapp, monkeypatch, tmp_path):
    wiz, page = _no_backend_build_page(monkeypatch, tmp_path)
    try:
        page.initializePage()
        _settle(qapp, page)
        page._on_preflight_done([], False, page._recompute_gen)
        assert page._problems and page.isComplete() is False
    finally:
        page._join_preflight_worker()
        wiz.close(); wiz.deleteLater()


def test_builder_image_output_survives_the_preflight_that_follows(
        qapp, monkeypatch, tmp_path):
    docker_host = HostInfo(os="linux", is_gentoo=False, has_docker=True, has_bash=True,
                           has_kvm=False, is_root=False, builder_image="hugmesh-builder")
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": docker_host)
    monkeypatch.setattr(bd.BuildDriver, "_image_present", lambda self: False)
    wiz = wizard_mod.StudioWizard(GENERATOR_DIR)
    page = wiz.page(wiz._page_ids["build"])
    page.outdir.setText(str(tmp_path / "out"))
    page._recompute_timer.setInterval(0)

    def fake_build(on_line=None):       # a failed builder-image build, nothing run
        on_line("Step 7/9 : RUN emerge failed")
        return 3
    monkeypatch.setattr(wiz.driver, "build_builder_image", fake_build)
    try:
        page.initializePage()
        _settle(qapp, page)
        page._build_builder_image()
        deadline = time.monotonic() + 15
        while page.image_worker.isRunning() and time.monotonic() < deadline:
            qapp.processEvents()
            time.sleep(0.01)
        page.image_worker.wait(5000)
        qapp.processEvents()
        _settle(qapp, page)
        text = page.log.toPlainText()
        assert "Step 7/9 : RUN emerge failed" in text
        assert "=== builder image build exited 3 ===" in text
        assert "Preflight" in text          # the refreshed preflight is still shown
    finally:
        page._join_preflight_worker()
        wiz.close(); wiz.deleteLater()


def _docker_build_page(monkeypatch, tmp_path):
    docker_host = HostInfo(os="linux", is_gentoo=False, has_docker=True, has_bash=True,
                           has_kvm=False, is_root=False, builder_image="hugmesh-builder")
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": docker_host)
    monkeypatch.setattr(bd.BuildDriver, "_image_present", lambda self: False)
    wiz = wizard_mod.StudioWizard(GENERATOR_DIR)
    page = wiz.page(wiz._page_ids["build"])
    page.outdir.setText(str(tmp_path / "out"))
    page._recompute_timer.setInterval(0)
    return wiz, page


@pytest.mark.parametrize("exc", [RecursionError("maximum recursion depth exceeded"),
                                 RuntimeError("something else broke")])
def test_only_the_no_backend_error_is_turned_into_a_refusal(
        qapp, monkeypatch, tmp_path, exc):
    # A recursion overflow (a RuntimeError subclass) or a RuntimeError from a real
    # docker assembly is not "no build backend" and must propagate as it did before.
    wiz, page = _docker_build_page(monkeypatch, tmp_path)

    def boom(self, cfg, backend=None):
        raise exc
    monkeypatch.setattr(bd.BuildDriver, "command_string", boom)
    try:
        with pytest.raises(type(exc)):
            page._preview()
        assert page._no_backend == ""
        assert not any("Cannot assemble" in p for p in page._problems)
    finally:
        page._join_preflight_worker()
        wiz.close(); wiz.deleteLater()


def test_no_backend_host_still_lets_a_recursion_error_propagate(
        qapp, monkeypatch, tmp_path):
    wiz, page = _no_backend_build_page(monkeypatch, tmp_path)

    def boom(self, cfg, backend=None):
        raise RecursionError("maximum recursion depth exceeded")
    monkeypatch.setattr(bd.BuildDriver, "command_string", boom)
    try:
        with pytest.raises(RecursionError):
            page._preview()
        assert page._no_backend == ""
    finally:
        page._join_preflight_worker()
        wiz.close(); wiz.deleteLater()


def test_a_long_builder_image_transcript_is_kept_as_its_tail(qapp, monkeypatch, tmp_path):
    # Every preflight pass re-lays the transcript out; 15000 kept lines made each pass
    # take seconds, so only the tail (which holds the failure and exit line) is kept.
    wiz, page = _docker_build_page(monkeypatch, tmp_path)
    try:
        page._builder_image_lines.clear()
        page._builder_image_dropped = 0
        page._keep_builder_image_line("=== building the docker builder image ===")
        with monkeypatch.context() as m:
            m.setattr(build_page.console, "write", lambda widget, s: None)
            for i in range(20000):
                page._builder_image_line(f"line {i}")
            page._builder_image_finished(3)
        page._join_preflight_worker()
        keep = build_page._BUILDER_IMAGE_KEEP_LINES
        assert len(page._builder_image_lines) == keep
        start = time.monotonic()
        page._set_log("Preflight: ok")
        elapsed = time.monotonic() - start
        text = page.log.toPlainText()
        assert page.log.document().blockCount() <= keep + 5
        assert f"{20002 - keep} earlier lines not shown" in text
        assert "line 19999" in text and "line 0\n" not in text
        assert text.endswith("=== builder image build exited 3 ===\n\nPreflight: ok")
        assert elapsed < 2.0, elapsed       # loose: unbounded took seconds per pass
    finally:
        page._join_preflight_worker()
        wiz.close(); wiz.deleteLater()


def test_held_file_refusal_shows_the_path_with_single_backslashes():
    e = FileNotFoundError(2, "The system cannot find the file specified",
                          "C:\\Users\\J\u00f6hn\\Keys [1]\\db.pem")
    text = build_page.hold_error_text(e, osname="nt")
    assert text == ("The system cannot find the file specified: "
                    "C:\\Users\\J\u00f6hn\\Keys [1]\\db.pem")
    assert "\\\\" not in text


def test_held_file_refusal_on_linux_is_str_of_the_error():
    e = PermissionError(13, "Permission denied", "/media/keys/db.pem")
    assert build_page.hold_error_text(e, osname="posix") == str(e)
    v = ValueError("held file too large")
    assert build_page.hold_error_text(v, osname="nt") == "held file too large"

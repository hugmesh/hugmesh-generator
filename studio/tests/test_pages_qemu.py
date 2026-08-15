"""QemuPage + the two ends of the qemu_e2e chain, driven offscreen.

Covers the operator ask verbatim ("run these tests containerized with qemu using
images built in other sessions or start a new build and then run these emulations
after; also … an option for when test environment is enabled on builds to run all
e2e tests with qemu emulated devices"):

* QemuPage "use existing" — the session picker offers only image-holding sessions,
  previews the exact runner command, and List/Run stream the runner's output;
* QemuPage "build first" — rejoins the image flow and arms cfg.qemu_e2e, the SAME
  non-argv field BuildPage's checkbox drives;
* BuildPage — the checkbox is gated on --env test (greyed + unticked on prod, and
  the collect re-enforces it against a programmatic bypass);
* ProgressPage — an all-ok build with the opt-in launches the containerized runner
  against the session's own workdir.

Hermetic: the wizard runs against a FAKE generator tree whose
tests/qemu/run-qemu-docker.sh is an echoing stub, and docker availability is
stubbed — no docker daemon, no qemu, no images.
"""
import os
from types import SimpleNamespace

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import qemu_tests               # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo   # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod      # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets              # noqa: E402

from _helpers import advance_to, pick_mode               # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

# a canned host so wizard construction never probes the machine (docker info &c.)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(autouse=True)
def _docker_stubbed(monkeypatch):
    # QemuPage states docker availability up-front; the REAL probe would make every
    # test here depend on the host's daemon. Stubbed to available — the unavailable
    # arm is asserted explicitly in test_qemu_page_says_when_docker_is_missing.
    monkeypatch.setattr(qemu_tests, "docker_available",
                        lambda: (True, "docker is available."))


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def fake_generator(tmp_path):
    """A generator tree with one image-holding session and a STUB runner script
    that echoes its argv — the full launch path runs, nothing containerized does."""
    gen = tmp_path / "gen"
    sess = gen / "out" / "sessions" / "20260201-000000-full"
    sess.mkdir(parents=True)
    for n in ("hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img.xz",
              "hugmesh-x86-amd64-be-test-20260807T172418Z.img"):
        (sess / n).write_bytes(b"")
    qdir = gen / "tests" / "qemu"
    qdir.mkdir(parents=True)
    stub = qdir / "run-qemu-docker.sh"
    stub.write_text('#!/usr/bin/env bash\necho "STUB-RUNNER $*"\nexit 0\n')
    stub.chmod(0o755)
    return gen, sess


@pytest.fixture
def wiz(qapp, fake_generator):
    gen, _sess = fake_generator
    w = wizard_mod.StudioWizard(str(gen))
    w.show()          # offscreen: makes per-widget isVisible() meaningful
    yield w
    w.close()
    w.deleteLater()


@pytest.fixture
def real_wiz(qapp):
    # the BuildPage-gate tests walk the full standalone flow, whose pages read
    # real generator-tree data — they get the real tree, no qemu stub needed
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _qemu_page(wiz):
    pick_mode(wiz, "qemu")
    return advance_to(wiz, wizard_mod.QemuPage)


# ---- QemuPage: "use existing images" ---------------------------------------------

def test_qemu_page_offers_sessions_and_previews_the_command(wiz, fake_generator):
    _gen, sess = fake_generator
    page = _qemu_page(wiz)
    assert page.use_existing.isChecked()                # the common case is default
    assert page.session_combo.count() == 1
    assert "2 image(s)" in page.session_combo.currentText()
    rows = page.rows_label.text()
    assert rows.index("rpi5/pki") < rows.index("x86/be")  # boot order: Pi first
    assert "decompressed" in rows                       # the .xz row says so
    # platform filter: all + the session's two platforms, Pi ranked first
    assert [page.platform_combo.itemData(i)
            for i in range(page.platform_combo.count())] == ["", "rpi5", "x86"]
    cmd = page.cmd_view.toPlainText()
    assert "run-qemu-docker.sh" in cmd
    assert f"--artifacts {sess}" in cmd
    assert "--jobs 2" in cmd and "--list" not in cmd    # preview shows the RUN argv


def test_qemu_list_devices_streams_the_stub_runner(wiz, qapp):
    page = _qemu_page(wiz)
    page._launch(list_only=True)
    assert page.worker is not None
    assert not page.run_btn.isEnabled()                 # running: no double-launch
    assert page.worker.wait(15000)
    qapp.processEvents()                                # deliver the queued signals
    log = page.log.toPlainText()
    assert "STUB-RUNNER" in log and "--list" in log and "--artifacts" in log
    assert "== device tests passed ==" in log
    assert page.run_btn.isEnabled() and not page.cancel_btn.isEnabled()


def test_qemu_use_existing_is_terminal_and_arms_nothing(wiz):
    page = _qemu_page(wiz)
    assert page.nextId() == -1 and page.isFinalPage()
    assert page.validatePage() is True
    assert wiz.cfg.qemu_e2e is False   # "test what exists" must not arm the hook


def test_qemu_page_says_when_docker_is_missing(wiz, monkeypatch):
    monkeypatch.setattr(qemu_tests, "docker_available",
                        lambda: (False, "docker was not found on PATH."))
    page = _qemu_page(wiz)
    assert not page.run_btn.isEnabled() and not page.list_btn.isEnabled()
    assert "cannot run on this machine" in page.docker_note.text()


# ---- QemuPage: "build first, then test" ------------------------------------------

def test_qemu_build_first_rejoins_the_image_flow_and_arms_the_hook(wiz):
    page = _qemu_page(wiz)
    page.build_first.setChecked(True)
    assert page.nextId() != -1                          # rejoins, not terminal
    assert not page.session_box.isVisible()             # picker is the other arm's
    assert wiz.cfg.qemu_e2e is False
    wiz.next()
    assert wiz.cfg.qemu_e2e is True                     # armed on the way out
    assert not isinstance(wiz.currentPage(), wizard_mod.QemuPage)


def test_qemu_page_without_sessions_forces_build_first(wiz, monkeypatch):
    monkeypatch.setattr(qemu_tests, "discover_sessions", lambda *_a, **_k: [])
    page = _qemu_page(wiz)
    assert not page.use_existing.isEnabled()
    assert page.build_first.isChecked()
    assert page.nextId() != -1


# ---- BuildPage: the --env test gate ----------------------------------------------

def test_build_qemu_e2e_gate_follows_env(real_wiz):
    """The checkbox lives and dies with --env: greyed + unticked on prod (a prod
    image prunes the in-cluster test runner, so the assertions would target a stack
    the build removed on purpose), reversible on test — and never an argv token."""
    build = advance_to(real_wiz, wizard_mod.BuildPage)
    assert build.env.currentText() == "test"            # the builders' own default
    assert build.qemu_e2e.isEnabled()
    build.qemu_e2e.setChecked(True)
    build.env.setCurrentText("prod")
    assert not build.qemu_e2e.isEnabled()
    assert not build.qemu_e2e.isChecked()               # prod may not carry the flag
    assert "prod" in build.qemu_e2e.toolTip()           # the WHY is on the widget
    build.env.setCurrentText("test")
    assert build.qemu_e2e.isEnabled()                   # reversible, not destroyed
    build.qemu_e2e.setChecked(True)
    build._preview()
    assert real_wiz.cfg.qemu_e2e is True
    assert not any("qemu" in a.lower() for a in real_wiz.cfg.to_cli_args())


def test_build_qemu_e2e_collect_reenforces_the_env_gate(real_wiz):
    """Belt and braces: even a programmatic check while prod is selected (the greyed
    widget still accepts setChecked) must not let a prod config carry the flag."""
    build = advance_to(real_wiz, wizard_mod.BuildPage)
    build.env.setCurrentText("prod")
    build.qemu_e2e.setChecked(True)                     # bypasses the greyed gate
    build._preview()
    assert real_wiz.cfg.qemu_e2e is False


# ---- ProgressPage: the post-build hook -------------------------------------------

def test_progress_runs_the_device_tests_after_an_all_ok_build(wiz, fake_generator,
                                                              qapp):
    _gen, sess = fake_generator
    prog = wiz.page(wiz._page_ids["progress"])
    wiz.cfg.qemu_e2e = True
    prog._session = SimpleNamespace(workdir=str(sess))
    prog._maybe_qemu_tests()
    assert prog.qemu_worker is not None
    assert prog.qemu_worker.wait(15000)
    qapp.processEvents()                                # deliver the queued signals
    log = prog.log.toPlainText()
    assert "STUB-RUNNER" in log
    assert f"--artifacts {sess}" in log                 # tests THIS build's images
    assert "=== QEMU device tests passed ===" in log


def test_progress_skips_the_device_tests_without_the_opt_in(wiz):
    prog = wiz.page(wiz._page_ids["progress"])
    wiz.cfg.qemu_e2e = False
    prog._session = SimpleNamespace(workdir="/nowhere")
    prog._maybe_qemu_tests()
    assert prog.qemu_worker is None


def test_qemu_opt_out_on_buildpage_survives_a_page_revisit(real_wiz):
    """Unticking the BuildPage checkbox must STAY unticked across a page revisit.

    This is the operator-visible bug and it is the PRIMARY forward route, not an
    exotic one. QemuPage.validatePage() only ever SETS cfg.qemu_e2e True, and
    BuildPage.initializePage() calls wiz.collect_all(), which re-runs the
    validatePage of every VISITED page. QemuPage is still visited on this route, so
    it re-arms the flag the operator just cleared, and build.py:888 re-ticks the
    checkbox from it — the post-build device tests then run after an explicit opt-out.

    Driven through the UI only. A test that calls validatePage() directly pins the
    mechanism and passes while this route stays broken.
    """
    qp = _qemu_page(real_wiz)
    qp.build_first.setChecked(True)
    real_wiz.next()
    assert real_wiz.cfg.qemu_e2e is True, "build-first should arm the hook"

    build = advance_to(real_wiz, wizard_mod.BuildPage)
    build.env.setCurrentText("test")          # the checkbox is gated on --env test
    build.qemu_e2e.setChecked(False)          # the operator opts OUT
    build._preview()
    assert real_wiz.cfg.qemu_e2e is False, "unticking must clear the flag"

    real_wiz.back()                           # leave BuildPage...
    real_wiz.next()                           # ...and walk straight back into it

    page = real_wiz.currentPage()
    assert isinstance(page, wizard_mod.BuildPage), \
        f"expected to land back on BuildPage, got {type(page).__name__}"
    assert real_wiz.cfg.qemu_e2e is False, (
        "revisiting BuildPage re-armed qemu_e2e — the operator's opt-out was silently "
        "reverted, so the post-build device tests would run anyway")
    assert build.qemu_e2e.isChecked() is False, "the checkbox re-ticked itself"

"""RESTART of a session whose Login Password was blanked: re-enter it IN PLACE.

PR #860 round 1: the login password is never saved (SECRET_FIELDS), so a restarted
session comes back with it empty. For a standalone image the restart then died on
"Preflight FAILED" and the operator had to Redo the whole walk; for a cloud/mesh
desktop it would silently build an image whose local account had no build-time
password. ProgressPage now shows an inline "Login Password needed to restart" group
(two masked fields + Start build, enabled only on a match), dispatches nothing until
it is filled, then writes the password onto the worklist base and dispatches.

Runs the REAL wizard on Qt's offscreen platform, renders the page, and asserts the
group's geometry (visible, non-zero, inside the page) — the screenshot lands in the
test's tmp dir.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import build_sessions, secret_files       # noqa: E402
from hugmesh_studio.core import worklist_driver as wd              # noqa: E402
from hugmesh_studio.core.config import ImageConfig                 # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo             # noqa: E402
from hugmesh_studio.core.worklist import synthesize                # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtWidgets                # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=True, builder_image="hugmesh-builder")
PW = "throwaway-restart-pw"


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(autouse=True)
def _fresh_vault(monkeypatch):
    monkeypatch.setattr(secret_files, "_VAULT", secret_files.SecretFileVault())


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.resize(1040, 780)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _fake_builddriver(monkeypatch, seen):
    from hugmesh_studio.core.config import standalone_login_problem

    class FakeBuildDriver:
        def __init__(self, gen, host, graphical=False, workdir=None):
            self.workdir = workdir

        def run(self, cfg, backend, on_line=None):
            seen.append(cfg.local_pass)
            return 0

        def cancel(self):
            pass

        def preflight(self, cfg, backend):
            p = standalone_login_problem(cfg)
            return [p] if p else []

        def preflight_warnings(self, cfg, backend):
            return []

        def command_string(self, cfg, backend=None):
            return f"cmd:{cfg.role}"

    monkeypatch.setattr(wd, "BuildDriver", FakeBuildDriver)


def _restarted(wiz, tmp_path, **kw):
    """A FAILED record whose dispatch carried a Login Password, reloaded the way
    StudioWizard.start_build_from_session does (the password comes back empty)."""
    cfg = ImageConfig(output_dir=str(tmp_path / "out"), local_user="magus",
                      local_pass=PW, **kw)
    s = build_sessions.new_session(synthesize(cfg), GENERATOR_DIR)
    assert s.blanked_secrets == ["local_pass"]
    build_sessions.start(s)
    build_sessions.finish(s, build_sessions.FAILED)
    reloaded = build_sessions.load(s.path())
    wl = reloaded.worklist()
    assert wl.base.local_pass == ""                    # never persisted
    wiz.worklist = wl
    wiz.cfg = wl.base
    wiz.build_backend = None
    wiz.pending_session_id = s.id
    return s


def _page(wiz):
    return wiz.page(wiz._page_ids["progress"])


def _settle(qapp, page=None):
    for _ in range(200):
        qapp.processEvents()
        if page is not None and page.worker is not None and not page.worker.isRunning():
            break
    if page is not None and page.worker is not None:
        page.worker.wait(5000)
    for _ in range(50):
        qapp.processEvents()


@pytest.mark.parametrize("cfg_kw", [
    dict(mode="standalone", role="standalone-thick", platform="x86"),   # was a dead end
    dict(mode="mesh", role="laptop", platform="x86"),                   # was silent
])
def test_restart_asks_for_the_login_password_in_place(monkeypatch, qapp, wiz, tmp_path,
                                                      cfg_kw):
    seen: list[str] = []
    _fake_builddriver(monkeypatch, seen)
    s = _restarted(wiz, tmp_path, **cfg_kw)
    wiz.setCurrentId(wiz._page_ids["progress"])
    page = _page(wiz)
    page.initializePage()
    _settle(qapp)
    # nothing dispatched, the record untouched, the panel up
    assert page.worker is None and seen == []
    assert build_sessions.load(s.path()).status == build_sessions.FAILED
    assert "Waiting for the Login Password" in page.log.toPlainText()
    box = page.relogin
    assert box.isVisible()
    # LOOK at it: on screen, non-zero, inside the page, fields and button visible
    shot = page.grab()
    shot.save(str(tmp_path / f"relogin-{cfg_kw['role']}.png"))
    r = box.geometry()
    assert r.width() > 200 and r.height() > 80, f"panel collapsed: {r}"
    assert page.rect().contains(r), f"panel {r} outside page {page.rect()}"
    for w in (page.relogin_pass, page.relogin_confirm, page.relogin_btn):
        assert w.isVisible() and w.width() > 20 and w.height() > 10
        tl = w.mapTo(page, QtCore.QPoint(0, 0))
        assert page.rect().contains(tl), f"{w.objectName() or w} not inside the page"
    assert page.relogin_pass.echoMode() == QtWidgets.QLineEdit.EchoMode.Password
    # mismatch: button stays disabled and says why
    assert not page.relogin_btn.isEnabled()
    page.relogin_pass.setText(PW)
    page.relogin_confirm.setText(PW + "x")
    assert not page.relogin_btn.isEnabled()
    assert "do not match" in page.relogin_err.text()
    # match: Start build dispatches with the password on the base
    page.relogin_confirm.setText(PW)
    assert page.relogin_btn.isEnabled()
    page.relogin_btn.click()
    _settle(qapp, page)
    assert not box.isVisible()
    assert seen == [PW], "the re-entered password did not reach the dispatch"
    assert page.relogin_pass.text() == "" and page.relogin_confirm.text() == ""
    assert build_sessions.load(s.path()).status == build_sessions.COMPLETE


def test_restart_without_a_prior_password_does_not_ask(monkeypatch, qapp, wiz, tmp_path):
    seen: list[str] = []
    _fake_builddriver(monkeypatch, seen)
    cfg = ImageConfig(mode="mesh", role="laptop", platform="x86",
                      output_dir=str(tmp_path / "out"), local_user="magus")
    s = build_sessions.new_session(synthesize(cfg), GENERATOR_DIR)
    build_sessions.start(s)
    build_sessions.finish(s, build_sessions.FAILED)
    wl = build_sessions.load(s.path()).worklist()
    wiz.worklist, wiz.cfg, wiz.build_backend, wiz.pending_session_id = wl, wl.base, None, s.id
    page = _page(wiz)
    page.initializePage()
    _settle(qapp, page)
    assert page.relogin.isHidden()          # explicitly hidden, not merely off-screen
    assert seen == [""]


def test_loaded_standalone_config_without_password_asks_instead_of_dead_end(
        monkeypatch, qapp, wiz, tmp_path):
    """Not a session restart: a standalone config reloaded from disk (password blanked
    on save) reaching dispatch. The only preflight refusal is the missing password,
    so the page asks for it rather than ending at 'Preflight FAILED'."""
    seen: list[str] = []
    _fake_builddriver(monkeypatch, seen)
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      output_dir=str(tmp_path / "out"), local_user="magus")
    wl = synthesize(cfg)
    wiz.worklist, wiz.cfg, wiz.build_backend, wiz.pending_session_id = wl, wl.base, None, None
    wiz.setCurrentId(wiz._page_ids["progress"])
    page = _page(wiz)
    page.initializePage()
    _settle(qapp)
    assert page.relogin.isVisible(), page.log.toPlainText()[:300] and page.worker is None and seen == []
    assert "Preflight FAILED" not in page.log.toPlainText()
    page.relogin_pass.setText(PW)
    page.relogin_confirm.setText(PW)
    page.relogin_btn.click()
    _settle(qapp, page)
    assert seen == [PW]

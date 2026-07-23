"""Build-creation sessions, end-to-end offscreen (mocked BuildDriver, no real builds).

Proves the REQUIREMENT set headlessly:
(a) a GUI-dispatched build writes a session record at START (running) and updates the
    outcome at FINISH — including a FAILED outcome carrying an error tail;
(b) each dispatch runs in its OWN <out>/sessions/<id>/ workdir (the driver's -w);
(c) the Welcome screen's Previous-builds list shows sessions with honest status and
    the search filters them (plus button gating: unmanaged rows can't Restart/Redo);
(d) RESTART re-dispatches the same config into the SAME dir (restarts increments,
    --resume togglable, running-elsewhere refused) and REDO loads the config back
    into the wizard as a NEW session;
(e) unmanaged wl-*.* dirs under the default out appear as unknown-status entries.
"""
import os
import socket

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import build_sessions as bs                # noqa: E402
from hugmesh_studio.core.config import Domain, ImageConfig, User   # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo             # noqa: E402
from hugmesh_studio.core import worklist_driver as wd              # noqa: E402
from hugmesh_studio.core.worklist import (                        # noqa: E402
    WorklistConfig, WorklistEntry, synthesize)
from hugmesh_studio.gui import wizard as wizard_mod                # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                        # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=True, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    yield w
    w.close()
    w.deleteLater()


def _install_fake_builddriver(monkeypatch, codes=None, lines=None):
    codes = codes or {}
    made = []

    class FakeBuildDriver:
        def __init__(self, gen, host, graphical=False, workdir=None):
            self.workdir = workdir
            self.cancelled = False
            self.ran = False
            made.append(self)

        def run(self, cfg, backend, on_line=None):
            self.ran = True
            if on_line:
                for ln in (lines or [f"==> building {cfg.role}"]):
                    on_line(ln)
            return codes.get(cfg.role, 0)

        def cancel(self):
            self.cancelled = True

        def preflight(self, cfg, backend):
            return []

        def command_string(self, cfg, backend=None):
            return f"cmd:{cfg.role}"

    monkeypatch.setattr(wd, "BuildDriver", FakeBuildDriver)
    return made


def _progress_page(wiz):
    return wiz.page(wiz._page_ids["progress"])


def _welcome_page(wiz):
    return wiz.page(wiz._page_ids["welcome"])


def _run_to_completion(qapp, page, timeout_ms=5000):
    if page.worker is not None:
        page.worker.wait(timeout_ms)
    for _ in range(500):
        qapp.processEvents()
        if page.isComplete():
            break


def _standalone_cfg(tmp_path, role="standalone-thick"):
    return ImageConfig(mode="standalone", role=role, platform="x86",
                       brand="acme", output_dir=str(tmp_path / "out"))


def _prime(wiz, worklist, generate_keys=True):
    wiz.worklist = worklist
    wiz.build_backend = None
    wiz.generate_node_keys = generate_keys


def _dispatch(qapp, wiz, tmp_path, monkeypatch, codes=None, lines=None, role="standalone-thick"):
    made = _install_fake_builddriver(monkeypatch, codes=codes, lines=lines)
    _prime(wiz, synthesize(_standalone_cfg(tmp_path, role=role)))
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)
    return page, made


# ── (a) records at start + finish, (b) per-session workdir ───────────────────────────
def test_dispatch_writes_running_then_complete_record(monkeypatch, qapp, wiz, tmp_path):
    page, made = _dispatch(qapp, wiz, tmp_path, monkeypatch)
    sessions = bs.load_all()
    assert len(sessions) == 1
    s = sessions[0]
    assert s.status == "complete"
    assert s.images[0]["status"] == "ok"
    assert s.images[0]["exit_code"] == 0
    assert s.started and s.finished
    assert s.pid == os.getpid() and s.hostname == socket.gethostname()
    # (b) the run dispatched into ITS OWN session dir, threaded to the BuildDriver -w
    assert s.workdir == os.path.join(str(tmp_path / "out"), "sessions", s.id)
    assert page.driver.workdir == s.workdir
    # scope to drivers the dispatch RAN: a BuildPage preview probe may construct a
    # throwaway driver mid-eventloop without a session (this test jumps straight to
    # the progress page; the real flow passes through BuildPage which mints the id)
    ran = [m for m in made if m.ran]
    assert ran and all(m.workdir == s.workdir for m in ran), [m.workdir for m in made]
    assert s.log_path == os.path.join(s.workdir, "build.log")
    # a second dispatch gets a DIFFERENT session dir (pending id was cleared)
    assert wiz.pending_session_id is None


def test_failed_dispatch_records_failed_with_error_tail(monkeypatch, qapp, wiz, tmp_path):
    lines = [f"line {i}" for i in range(60)]
    _dispatch(qapp, wiz, tmp_path, monkeypatch,
              codes={"standalone-thick": 3}, lines=lines)
    s = bs.load_all()[0]
    assert s.status == "failed"
    assert s.images[0]["status"] == "failed"
    assert s.images[0]["exit_code"] == 3
    tail = s.error_tail["standalone-thick.x86"]
    assert len(tail) == bs.ERROR_TAIL_LINES        # last ~40 lines, honest pointer
    assert tail[-1] == "line 59"


def test_two_dispatches_get_two_session_dirs(monkeypatch, qapp, wiz, tmp_path):
    _dispatch(qapp, wiz, tmp_path, monkeypatch)
    _dispatch(qapp, wiz, tmp_path, monkeypatch)
    sessions = bs.load_all()
    assert len(sessions) == 2
    assert sessions[0].workdir != sessions[1].workdir


def test_mesh_manifest_lands_in_the_session_dir(monkeypatch, qapp, wiz, tmp_path):
    _install_fake_builddriver(monkeypatch)
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                       brand_title="Acme", org="Acme-Inc", cluster_domain="acme.example",
                       superdomain="core.acme.internal", output_dir=str(tmp_path / "out"))
    base.domains = [Domain(name="acme.example", title="Acme")]
    base.users = [User(username="root-admin", domain="core.acme.internal",
                       role="superadmin")]
    wl = WorklistConfig(base=base, entries=[WorklistEntry(role="rpi5-desktop",
                                                          platform="rpi5")])
    _prime(wiz, wl)
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)
    s = bs.load_all()[0]
    assert page._manifest_path == os.path.join(s.workdir,
                                               "hugmesh-mesh-manifest.json")
    assert os.path.isfile(page._manifest_path)


# ── preview honesty (Review & Build shows the session -w) ─────────────────────────────
def test_build_page_preview_shows_the_session_workdir(monkeypatch, qapp, wiz, tmp_path):
    build = wiz.page(wiz._page_ids["build"])
    wiz.cfg = _standalone_cfg(tmp_path)
    build.outdir.setText(str(tmp_path / "out"))
    monkeypatch.setattr(wiz, "collect_all", lambda: None)
    build._preview()
    sid = wiz.pending_session_id
    assert sid
    shown = build.cmd.toPlainText()
    assert f"-w {tmp_path / 'out'}/sessions/{sid}" in shown
    build._preview()                     # Back-and-forth reuses ONE id per attempt
    assert wiz.pending_session_id == sid


# ── (c)+(e) the Welcome manager ───────────────────────────────────────────────────────
def _seed_sessions(tmp_path):
    ok = bs.new_session(synthesize(_standalone_cfg(tmp_path)), GENERATOR_DIR)
    bs.start(ok)
    bs.update_image(ok, 0, status="ok", exit_code=0)
    bs.finish(ok, "complete")
    bad_cfg = ImageConfig(mode="standalone", role="generic", platform="rpi5",
                          brand="acme", output_dir=str(tmp_path / "out"))
    bad = bs.new_session(synthesize(bad_cfg), GENERATOR_DIR)
    bs.start(bad)
    bs.update_image(bad, 0, status="failed", exit_code=2)
    bs.finish(bad, "failed", {"generic.rpi5": ["kaboom"]})
    return ok, bad


def test_welcome_lists_sessions_with_honest_status_and_filters(qapp, wiz, tmp_path):
    ok, bad = _seed_sessions(tmp_path)
    (tmp_path / "out" / "wl-pki.x86").mkdir(parents=True)      # (e) unmanaged
    wiz.cfg.output_dir = str(tmp_path / "out")
    page = _welcome_page(wiz)
    page.initializePage()
    w = page.previous_builds
    assert not w.isHidden()                       # rows exist -> section shown
    assert w.table.rowCount() == 3
    statuses = {w.table.item(i, 2).text() for i in range(3)}
    assert "✓ complete" in statuses
    assert "✗ failed · 1 of 1 images" in statuses  # explicit error indication
    assert "? unknown" in statuses                 # unmanaged: never fabricated
    # search filters (case-insensitive substring over role/platform/label/status/date)
    w.search.setText("rpi5")
    hidden = [w.table.isRowHidden(i) for i in range(3)]
    assert hidden.count(False) == 1
    w.search.setText("")
    w.status_filter.setCurrentText("failed")
    visible = [i for i in range(3) if not w.table.isRowHidden(i)]
    assert len(visible) == 1
    assert w._row_data[visible[0]].session.id == bad.id


def test_welcome_hidden_when_no_rows(qapp, wiz, tmp_path):
    wiz.cfg.output_dir = str(tmp_path / "empty-out")
    page = _welcome_page(wiz)
    page.initializePage()
    assert page.previous_builds.isHidden()             # first-run Welcome unchanged


def test_welcome_button_gating_unmanaged_vs_session(qapp, wiz, tmp_path):
    _seed_sessions(tmp_path)
    (tmp_path / "out" / "wl-pki.x86").mkdir(parents=True)
    wiz.cfg.output_dir = str(tmp_path / "out")
    w = _welcome_page(wiz).previous_builds
    w.refresh()
    session_row = next(i for i, r in enumerate(w._row_data) if r.kind == "session")
    unmanaged_row = next(i for i, r in enumerate(w._row_data) if r.kind == "unmanaged")
    w.table.selectRow(session_row)
    assert w.restart_btn.isEnabled() and w.redo_btn.isEnabled()
    w.table.selectRow(unmanaged_row)
    assert not w.restart_btn.isEnabled() and not w.redo_btn.isEnabled()
    assert "config snapshot" in w.restart_btn.toolTip()
    assert w.open_btn.isEnabled()                  # the wl- dir exists on disk


def test_stale_running_record_renders_as_stale_not_complete(qapp, wiz, tmp_path):
    import subprocess, sys
    s = bs.new_session(synthesize(_standalone_cfg(tmp_path)), GENERATOR_DIR)
    bs.start(s)
    proc = subprocess.Popen([sys.executable, "-c", "pass"])
    proc.wait()
    s.pid = proc.pid                               # simulate a crashed Studio
    bs.save(s)
    wiz.cfg.output_dir = str(tmp_path / "no-out")
    w = _welcome_page(wiz).previous_builds
    w.refresh()
    assert w.table.item(0, 2).text() == "● running (stale?)"


def test_unreadable_record_surfaced_as_row(qapp, wiz, tmp_path):
    os.makedirs(bs.sessions_dir(), exist_ok=True)
    with open(os.path.join(bs.sessions_dir(), "zzz.json"), "w") as fh:
        fh.write("{broken")
    wiz.cfg.output_dir = str(tmp_path / "no-out")
    w = _welcome_page(wiz).previous_builds
    w.refresh()
    assert w.table.rowCount() == 1
    assert w.table.item(0, 2).text() == "unreadable record"


# ── (d) RESTART / REDO ────────────────────────────────────────────────────────────────
def test_redo_loads_config_into_wizard_as_new_session(qapp, wiz, tmp_path):
    ok, _bad = _seed_sessions(tmp_path)
    wiz.pending_session_id = "stale-pending"
    wiz.load_session(ok.config)
    assert wiz.cfg.role == "standalone-thick"
    assert wiz.cfg.brand == "acme"
    assert wiz.worklist is not None
    assert [e.id for e in wiz.worklist.entries] == ["standalone-thick.x86"]
    assert wiz.pending_session_id is None          # the next Build mints a NEW session
    assert wiz.currentId() == wiz._page_ids["welcome"]   # lands back on page 1


def test_restart_redispatches_same_config_into_same_dir(monkeypatch, qapp, wiz, tmp_path):
    made = _install_fake_builddriver(monkeypatch)
    ok, _bad = _seed_sessions(tmp_path)
    os.makedirs(ok.workdir, exist_ok=True)
    wiz.start_build_from_session(bs.load(ok.path()), resume=True)
    page = _progress_page(wiz)
    _run_to_completion(qapp, page)
    assert page.driver.workdir == ok.workdir           # SAME session dir reused
    assert page.driver.worklist.base.resume is True    # --resume honored
    on_disk = bs.load(ok.path())
    assert on_disk.status == "complete"
    assert on_disk.restarts == 1                       # RESTART history
    assert len(on_disk.runs) == 2
    assert on_disk.history and on_disk.history[0]["status"] == "complete"
    assert len(bs.load_all()) == 2                     # updated, not duplicated


def test_restart_without_resume_keeps_resume_off(monkeypatch, qapp, wiz, tmp_path):
    _install_fake_builddriver(monkeypatch)
    ok, _bad = _seed_sessions(tmp_path)
    wiz.start_build_from_session(bs.load(ok.path()), resume=False)
    page = _progress_page(wiz)
    _run_to_completion(qapp, page)
    assert page.driver.worklist.base.resume is False


def test_restart_resume_does_not_ratchet_on(monkeypatch, qapp, wiz, tmp_path):
    """A resume-restart re-snapshots resume=true into the persisted record; the NEXT
    restart with the checkbox UNCHECKED must still dispatch WITHOUT --resume (the
    flag is assigned from the checkbox each time, never merely raised)."""
    _install_fake_builddriver(monkeypatch)
    ok, _bad = _seed_sessions(tmp_path)
    os.makedirs(ok.workdir, exist_ok=True)
    # cycle 1: resume-restart bakes resume=true into the record's config snapshot
    wiz.start_build_from_session(bs.load(ok.path()), resume=True)
    page = _progress_page(wiz)
    _run_to_completion(qapp, page)
    assert page.driver.worklist.base.resume is True
    assert bs.load(ok.path()).config["base"]["resume"] is True   # the ratchet bait
    # cycle 2: checkbox unchecked — must actively clear the flag, not inherit it
    wiz.start_build_from_session(bs.load(ok.path()), resume=False)
    page = _progress_page(wiz)
    _run_to_completion(qapp, page)
    assert page.driver.worklist.base.resume is False
    assert bs.load(ok.path()).config["base"]["resume"] is False


def test_restart_refused_while_running_elsewhere(qapp, wiz, tmp_path):
    from hugmesh_studio.gui.pages.sessions_widget import PreviousBuildsWidget
    s = bs.new_session(synthesize(_standalone_cfg(tmp_path)), GENERATOR_DIR)
    bs.start(s)                                    # running, pid = us, alive -> refuse
    ok, why = PreviousBuildsWidget.can_restart(s)
    assert not ok
    assert "another Studio process" in why


def test_restart_with_deleted_workdir_offers_redo(qapp, wiz, tmp_path):
    from hugmesh_studio.gui.pages.sessions_widget import PreviousBuildsWidget
    s = bs.new_session(synthesize(_standalone_cfg(tmp_path)), GENERATOR_DIR)
    bs.start(s)
    bs.finish(s, "complete")
    assert not os.path.isdir(s.workdir)            # never created (mocked run)
    ok, why = PreviousBuildsWidget.can_restart(s)
    assert not ok
    assert "Redo" in why


# ── delete / cleanup affordance ───────────────────────────────────────────────────────
def test_delete_button_gating(qapp, wiz, tmp_path):
    _seed_sessions(tmp_path)
    wiz.cfg.output_dir = str(tmp_path / "out")
    w = _welcome_page(wiz).previous_builds
    w.refresh()
    w.table.clearSelection()
    w._update_buttons()
    assert not w.delete_btn.isEnabled()            # nothing selected -> no per-row delete
    assert w.delete_all_btn.isEnabled()            # rows exist -> bulk cleanup available
    w.table.selectRow(0)
    assert w.delete_btn.isEnabled()                # any row is deletable


def test_delete_finished_session_drops_the_row(monkeypatch, qapp, wiz, tmp_path):
    ok, bad = _seed_sessions(tmp_path)
    wiz.cfg.output_dir = str(tmp_path / "out")
    w = _welcome_page(wiz).previous_builds
    w.refresh()
    assert len(bs.scan()[0]) == 2
    monkeypatch.setattr(QtWidgets.QMessageBox, "exec",
                        lambda self: QtWidgets.QMessageBox.StandardButton.Ok)
    row = next(i for i, r in enumerate(w._row_data)
               if r.kind == "session" and r.session.id == ok.id)
    w.table.selectRow(row)
    w._delete()
    assert not os.path.exists(ok.path())           # record unlinked
    assert len(bs.scan()[0]) == 1                   # scan count dropped
    ids = {r.session.id for r in w._row_data if r.kind == "session"}
    assert ok.id not in ids and bad.id in ids       # row gone after refresh, sibling kept


def test_delete_active_session_refused_with_warning(monkeypatch, qapp, wiz, tmp_path):
    s = bs.new_session(synthesize(_standalone_cfg(tmp_path)), GENERATOR_DIR)
    bs.start(s)                                    # running, our live pid -> active
    wiz.cfg.output_dir = str(tmp_path / "no-out")
    w = _welcome_page(wiz).previous_builds
    w.refresh()
    warned = []
    monkeypatch.setattr(QtWidgets.QMessageBox, "warning",
                        lambda *a, **k: warned.append(a[2]))
    monkeypatch.setattr(QtWidgets.QMessageBox, "exec",
                        lambda self: pytest.fail("confirm shown for an active session"))
    w.table.selectRow(0)
    w._delete()
    assert warned and "another Studio process" in warned[0]
    assert os.path.exists(s.path())                # in-progress record left intact
    assert "another Studio process" in w.delete_btn.toolTip()   # blocked reason shown


def test_delete_all_finished_prunes_but_keeps_running(monkeypatch, qapp, wiz, tmp_path):
    _seed_sessions(tmp_path)                        # 2 terminal records
    running = bs.new_session(synthesize(_standalone_cfg(tmp_path, role="be")),
                             GENERATOR_DIR)
    bs.start(running)                              # active -> must be skipped
    wiz.cfg.output_dir = str(tmp_path / "out")
    w = _welcome_page(wiz).previous_builds
    w.refresh()
    assert w.table.rowCount() == 3
    monkeypatch.setattr(QtWidgets.QMessageBox, "exec",
                        lambda self: QtWidgets.QMessageBox.StandardButton.Ok)
    info = []
    monkeypatch.setattr(QtWidgets.QMessageBox, "information",
                        lambda *a, **k: info.append(a[2]))
    w._delete_all()
    assert [r.id for r in bs.load_all()] == [running.id]   # only the active one kept
    assert info and "skipped 1" in info[0]
    assert w.table.rowCount() == 1                  # list refreshed to the survivor

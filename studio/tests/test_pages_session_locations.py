"""The three pages a custom-output-folder session has to reach, rendered offscreen.

Companion to test_session_locations.py (the Qt-free core). Here the session is built
the same way, into a folder no live config names, with ``<generator>/out/sessions``
present and EMPTY, and then the REAL pages are driven:

* the device-test page (QemuPage) must OFFER it, preselect it, name its folder, and
  spawn the runner with ``--artifacts`` pointing at it;
* the mesh-emulation page must plan its three devices;
* the Sessions page must show the row, visibly, with its location, and must also show
  an unmanaged ``wl-*`` build in a folder the operator has since switched away from.

"Look at the UI you built": every page is grabbed to a PNG (under
``$HUGMESH_TEST_SHOTS_DIR`` when set, else the test's tmp dir) and the widgets under
assertion are measured — on screen, non-empty, inside their page — rather than
trusted from a model.
"""
from __future__ import annotations

import functools
import os
import shlex

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import (build_sessions, emulation, platform_info,  # noqa: E402
                                 qemu_tests, session_locations)
from hugmesh_studio.core.config import ImageConfig                     # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                 # noqa: E402
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                    # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtWidgets                    # noqa: E402

from _helpers import advance_to, pick_mode                             # noqa: E402

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")
_REAL_BLOCKER = platform_info.native_windows_blocker

IMAGES = ("acme-rpi5-arm64-backend-prod-20261109T072422Z.img.xz",
          "acme-rpi5-arm64-frontend-prod-20261109T080602Z.img.xz",
          "acme-rpi5-arm64-pki-prod-20261109T053553Z.img.xz")

_STUB_RUNNER = """#!/usr/bin/env bash
echo "STUB-RUNNER $*"
exit 0
"""

_RUNS_BASH_STUB = pytest.mark.skipif(
    os.name == "nt", reason="spawns a bash stub runner as a real child process")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    monkeypatch.setattr(platform_info, "native_windows_blocker",
                        functools.partial(_REAL_BLOCKER, osname="posix"))


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(autouse=True)
def _no_host_probes(monkeypatch):
    """Same stubs test_pages_qemu.py uses: no docker daemon, no readiness probe
    thread, and emulation.status reads only the on-disk registry."""
    from hugmesh_studio.core.local_stack_node import LocalStackNode
    monkeypatch.setattr(qemu_tests, "docker_available",
                        lambda: (True, "docker is available."))
    monkeypatch.setattr(LocalStackNode, "e2e_ready",
                        lambda self, environment="docker": ["stubbed probe"])
    monkeypatch.setattr(emulation, "_runner_devices", lambda *_a, **_k: None)
    monkeypatch.setattr(emulation, "_docker_running_names", lambda: None)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def custom(tmp_path):
    """(generator dir, the custom output folder, the session record)."""
    gen = tmp_path / "gen"
    (gen / "out" / "sessions").mkdir(parents=True)        # present, and EMPTY
    qdir = gen / "tests" / "qemu"
    qdir.mkdir(parents=True)
    stub = qdir / "run-qemu-docker.sh"
    stub.write_text(_STUB_RUNNER)
    stub.chmod(0o755)

    out = tmp_path / "Images" / "out"
    base = ImageConfig(mode="mesh", output_dir=str(out))
    wl = WorklistConfig(base=base, entries=[
        WorklistEntry(role=r, platform="rpi5") for r in ("backend", "frontend", "pki")])
    rec = build_sessions.new_session(wl, str(gen))
    build_sessions.start(rec)
    os.makedirs(rec.workdir)
    for name in IMAGES:
        with open(os.path.join(rec.workdir, name), "wb") as fh:
            fh.write(b"\0")
    rec.images = [dict(i, status="ok", exit_code=0) for i in rec.images]
    build_sessions.finish(rec, build_sessions.COMPLETE)
    return gen, out, rec


@pytest.fixture
def wiz(qapp, custom):
    gen, _out, _rec = custom
    w = wizard_mod.StudioWizard(str(gen))
    # The operator has since pointed the wizard back at the default folder: nothing
    # in the LIVE config names the custom one, so only the registry can find it.
    w.cfg.output_dir = ""
    w.resize(1200, 860)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _shot(widget, tmp_path, name):
    qapp = QtWidgets.QApplication.instance()
    for _ in range(5):
        qapp.processEvents()
    folder = os.environ.get("HUGMESH_TEST_SHOTS_DIR") or str(tmp_path)
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, name)
    assert widget.grab().save(path), f"could not write {path}"
    assert os.path.getsize(path) > 0
    return path


def _on_screen(widget, page):
    """The widget is shown, has a real size, and sits inside its page."""
    assert widget.isVisible(), f"{widget.objectName() or type(widget).__name__} hidden"
    assert widget.width() > 40 and widget.height() > 10
    top_left = widget.mapTo(page, QtCore.QPoint(0, 0))
    assert top_left.x() >= 0 and top_left.y() >= 0


def _no_horizontal_overflow(page):
    """A folder path in the picker line must not set the page's minimum width.
    Before the size policy in populate_sessions it did: 1182 px of minimum width
    against 582 px for the same page with a default-folder session.

    This can only FAIL in a window narrower than that unguarded minimum. At the
    fixtures' 1200 px it passes with or without the fix (round-1 refutation); the
    narrow tests at the end of this file are the ones that guard it."""
    qapp = QtWidgets.QApplication.instance()
    qapp.processEvents()
    for area in page.findChildren(QtWidgets.QScrollArea):
        if area.isVisible() and area.widget() is not None:
            assert area.horizontalScrollBar().maximum() == 0, \
                f"page content {area.widget().minimumSizeHint().width()} px wide in a " \
                f"{area.viewport().width()} px viewport"


def _qemu_page(wiz):
    pick_mode(wiz, "e2e")
    advance_to(wiz, wizard_mod.E2EPage).arm_qemu.setChecked(True)
    return advance_to(wiz, wizard_mod.QemuPage)


def test_device_test_page_offers_preselects_and_names_the_custom_folder(wiz, custom, tmp_path):
    _gen, out, rec = custom
    page = _qemu_page(wiz)
    combo = page.session_combo
    assert combo.count() == 1, "the custom-folder session must be OFFERED"
    assert combo.currentIndex() == 0
    assert combo.itemData(0) == rec.workdir
    assert combo.currentText().endswith(os.sep + os.path.join("Images", "out")), \
        "the line must say which folder"
    assert "  ·  in " in combo.currentText()
    tip = combo.itemData(0, QtCore.Qt.ItemDataRole.ToolTipRole)
    assert f"Folder: {rec.workdir}" in tip
    assert page.use_existing.isEnabled() and not page.source_note.isVisible()
    # the preview is the argv: --artifacts is the custom session, not out/sessions
    cmd = shlex.split(page.cmd_view.toPlainText())
    assert cmd[cmd.index("--artifacts") + 1] == rec.workdir
    _on_screen(combo, page)
    _no_horizontal_overflow(page)
    _shot(page, tmp_path, "qemu-page-custom-folder-session.png")


@_RUNS_BASH_STUB
def test_device_test_page_starts_the_runner_on_the_custom_folder(wiz, custom, qapp):
    _gen, _out, rec = custom
    page = _qemu_page(wiz)
    page._launch(list_only=True)
    assert page.worker is not None and page.worker.wait(15000)
    qapp.processEvents()
    echoed = [ln for ln in page.log.toPlainText().splitlines()
              if ln.startswith("STUB-RUNNER")]
    assert echoed, "the runner was never spawned"
    argv = shlex.split(echoed[0])[1:]
    assert argv[argv.index("--artifacts") + 1] == rec.workdir


def test_mesh_emulation_page_plans_the_custom_folder_session(wiz, custom, tmp_path):
    _gen, out, rec = custom
    pick_mode(wiz, "meshemu")
    page = advance_to(wiz, wizard_mod.MeshEmulationPage)
    assert page.session_combo.count() == 1
    assert page.session_combo.itemData(0) == rec.workdir
    assert page.session_combo.currentText().endswith(os.path.join("Images", "out"))
    assert f"Folder: {rec.workdir}" in page.session_combo.itemData(
        0, QtCore.Qt.ItemDataRole.ToolTipRole)
    _no_horizontal_overflow(page)
    assert page.plan is not None and page.plan.session_path == rec.workdir
    assert page.devices.rowCount() == 3
    _on_screen(page.session_combo, page)
    _shot(page, tmp_path, "mesh-emulation-page-custom-folder-session.png")


def test_empty_state_names_the_folders_it_searched(qapp, tmp_path):
    gen = tmp_path / "bare-gen"
    (gen / "out" / "sessions").mkdir(parents=True)
    w = wizard_mod.StudioWizard(str(gen))
    w.show()
    try:
        page = _qemu_page(w)
        note = page.source_note.text()
        assert "No build session in any known output folder" in note
        assert os.path.join(str(gen), "out", "sessions") in note
    finally:
        w.close()
        w.deleteLater()


def test_sessions_page_shows_the_custom_folder_row_and_a_stale_folders_unmanaged_build(
        wiz, custom, tmp_path):
    _gen, out, rec = custom
    # A pre-session build tree in the custom folder: the live config no longer names
    # that folder, so only the registry can bring it onto the page.
    (out / "wl-pki.x86").mkdir()
    welcome = wiz.currentPage()
    welcome._buttons["sessions"].setChecked(True)      # "Review prior sessions"
    wiz.next()
    page = wiz.currentPage()
    assert page is wiz.page(wiz._page_ids["sessions"]), type(page).__name__
    w = page.previous_builds
    assert not w.isHidden()
    rows = {r.kind: i for i, r in enumerate(w._row_data)}
    assert set(rows) == {"session", "unmanaged"}
    i = rows["session"]
    assert not w.table.isRowHidden(i)
    loc = w.table.item(i, 5)
    assert loc.toolTip() == rec.workdir
    assert loc.text().endswith(os.path.basename(rec.workdir))
    rect = w.table.visualItemRect(loc)
    assert rect.isValid() and rect.width() > 0 and rect.height() > 0
    assert w.table.viewport().rect().intersects(rect), "the row is scrolled off"
    u = rows["unmanaged"]
    assert w.table.item(u, 5).toolTip() == str(out / "wl-pki.x86")
    _on_screen(w.table, page)
    _shot(page, tmp_path, "sessions-page-custom-folder-session.png")


# ── a drive that is away: said on the page, forgotten nowhere ────────────────────────
def _open_sessions_page(wiz):
    welcome = wiz.currentPage()
    welcome._buttons["sessions"].setChecked(True)      # "Review prior sessions"
    wiz.next()
    page = wiz.currentPage()
    assert page is wiz.page(wiz._page_ids["sessions"]), type(page).__name__
    return page


def test_sessions_page_says_a_folder_is_missing_and_forgets_nothing(wiz, custom, tmp_path):
    gen, out, rec = custom
    drive = out.parent
    away = str(drive) + ".unplugged"
    # An unreadable record beside it: its location is a FILE, never "missing".
    bad = os.path.join(build_sessions.sessions_dir(), "20260101-000000-bad000.json")
    with open(bad, "w", encoding="utf-8") as fh:
        fh.write("{not json")
    os.rename(drive, away)
    try:
        page = _open_sessions_page(wiz)                  # refresh() runs _out_roots
        w = page.previous_builds
        kinds = [r.kind for r in w._row_data]
        u = w.table.item(kinds.index("unreadable"), 5)
        assert u.toolTip() == bad and not u.text().startswith(w.MISSING_MARK), u.text()
        i = kinds.index("session")
        loc = w.table.item(i, 5)
        assert loc.text().startswith(w.MISSING_MARK), loc.text()
        assert rec.workdir in loc.toolTip() and "not plugged in" in loc.toolTip()
        assert w.table.viewport().rect().intersects(w.table.visualItemRect(loc))
        _shot(page, tmp_path, "sessions-page-folder-missing.png")
        assert str(out) in session_locations.registered_roots(), \
            "a page refresh forgot a folder for being away"
    finally:
        os.rename(away, drive)
    w.refresh()
    i = [r.kind for r in w._row_data].index("session")
    assert not w.table.item(i, 5).text().startswith(w.MISSING_MARK)
    assert w.table.item(i, 5).toolTip() == rec.workdir


def test_a_record_only_delete_then_a_refresh_with_the_drive_away_keeps_it_bootable(
        wiz, custom, tmp_path):
    """BLOCKER 1 of the round-1 refutation, driven through the real page: the
    Sessions page refresh used to prune the registry, and after a record-only delete
    the registry was the last thing that knew the folder."""
    gen, out, rec = custom
    assert build_sessions.delete(rec, remove_artifacts=False)
    drive = out.parent
    away = str(drive) + ".unplugged"
    os.rename(drive, away)
    try:
        _open_sessions_page(wiz).previous_builds.refresh()
        assert qemu_tests.discover_sessions(str(gen)) == []
    finally:
        os.rename(away, drive)
    assert [s.path for s in qemu_tests.discover_sessions(str(gen))] == [rec.workdir]
    assert emulation._as_session(str(gen), rec.id).path == rec.workdir

# ── the overflow guard, at a width where it can fail ─────────────────────────────────
#: Round-1 refutation of PR #928 (BLOCKER 2): at the fixtures' 1200 px window the
#: picker line is capped by elide_left at about 670 px, so the page could never
#: overflow there, and deleting the size-policy lines left every test green. At 700
#: px the same page overflows without them (measured: scrollbar maximum 83) and fits
#: with them (0). Each test below asserts its own preconditions — the window really
#: is that narrow, and the line really names an elided folder — so it cannot go
#: vacuous again by a window that refused to shrink or a path that came out short.
NARROW = 700


def _narrow(wiz):
    wiz.setMinimumSize(0, 0)
    wiz.resize(NARROW, 860)
    qapp = QtWidgets.QApplication.instance()
    for _ in range(5):
        qapp.processEvents()
    assert wiz.width() <= NARROW, f"the wizard refused to shrink: {wiz.width()} px"


def _long_folder_line(combo):
    text = combo.currentText()
    assert "  ·  in …" in text, f"the line does not name an ELIDED folder: {text!r}"


def _picker_sizing(combo):
    """The two lines in populate_sessions each have their own job, and each is pinned
    here because the overflow check alone cannot tell them apart: removing EITHER one
    still leaves the page inside a 700 px window (measured), removing BOTH overflows.

    * the size-adjust policy: the combo's preferred width must not follow its longest
      line (measured without it: 892 px for a line that names a folder);
    * the minimum contents length: a floor, so the picker can never be squeezed to an
      unreadable sliver (measured without it: a 29 px minimum)."""
    fm = combo.fontMetrics()
    line = fm.horizontalAdvance(combo.currentText())
    assert combo.sizeHint().width() < line, \
        f"the picker's preferred width ({combo.sizeHint().width()} px) follows its " \
        f"{line} px line"
    floor = 20 * fm.horizontalAdvance("X")
    assert combo.minimumSizeHint().width() >= floor, \
        f"the picker may shrink to {combo.minimumSizeHint().width()} px (< {floor})"


@pytest.mark.parametrize("page_kind", ["qemu", "meshemu"])
def test_a_named_folder_never_widens_a_narrow_page(wiz, custom, tmp_path, page_kind):
    _gen, _out, rec = custom
    _narrow(wiz)
    if page_kind == "qemu":
        page = _qemu_page(wiz)
    else:
        pick_mode(wiz, "meshemu")
        page = advance_to(wiz, wizard_mod.MeshEmulationPage)
    _narrow(wiz)
    combo = page.session_combo
    assert combo.itemData(combo.currentIndex()) == rec.workdir
    _long_folder_line(combo)
    areas = [a for a in page.findChildren(QtWidgets.QScrollArea)
             if a.isVisible() and a.widget() is not None]
    assert areas, "no visible scroll area: the overflow check would measure nothing"
    assert all(a.viewport().width() < NARROW for a in areas)
    _on_screen(combo, page)
    _no_horizontal_overflow(page)          # first: the both-lines-gone regression
    _picker_sizing(combo)
    # what the clipped closed combo still offers: the full folder on hover, under the
    # page's own help text, which must survive
    tip = combo.toolTip()
    assert f"Folder: {rec.workdir}" in tip
    assert tip.startswith("Sessions holding" if page_kind == "qemu"
                          else "Prior build sessions"), tip[:80]
    _shot(wiz, tmp_path, f"{page_kind}-page-custom-folder-at-{NARROW}px.png")

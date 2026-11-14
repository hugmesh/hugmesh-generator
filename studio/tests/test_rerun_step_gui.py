"""The progress page's rerun icons — offscreen, on the real widgets, with fakes for the
build driver and the wizard's restart (nothing is dispatched, nothing is elevated).

The operator ask (2026-11-13): *put a rerun icon after each finished step, to stop and
prompt to be sure, then retry the build from that point.*

Pinned:
* every stage row has an icon, hidden until that stage has run (done, failed or
  stopped), with what a click does as its tooltip;
* a click opens the inline confirmation (never a modal) with the plan's sentence;
  Cancel closes it and dispatches nothing;
* confirming on a finished build dispatches the session again with --resume and, for
  an x86 late step, --from-step <that step>; an early step dispatches --resume only;
* confirming while the build runs stops it first and dispatches only once the stop
  has landed;
* no session, a fleet run or a several-image page: the icon is greyed with the reason;
* LOOK: screenshots at 1200x800 and 942x552 with the confirmation open, every control
  inside its window or the tree's viewport.
"""
import os
import time

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import build_sessions                          # noqa: E402
from hugmesh_studio.core import rerun_step as rs                        # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                  # noqa: E402
from hugmesh_studio.core.progress_parse import platform_phases          # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                     # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtWidgets                     # noqa: E402
from hugmesh_studio.gui.pages import progress as progress_mod           # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=True, builder_image="hugmesh-builder")
SIZES = ((1200, 800), (942, 552))
SHOTS = os.environ.get("RERUN_STEP_SHOTS") or os.path.join(
    os.environ.get("TMPDIR", "/tmp"), "rerun-step-shots")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect", lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="session")
def qapp():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication(["rerun-step-tests"])


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    yield w
    w.close()
    w.deleteLater()


def settle(qapp, n=6):
    for _ in range(n):
        qapp.processEvents()


def assert_inside(container, widget, what):
    assert widget.isVisible(), f"{what} is not visible"
    tl = widget.mapTo(container, QtCore.QPoint(0, 0))
    r = QtCore.QRect(tl, widget.size())
    assert container.rect().contains(r), f"{what} {r} is outside {container.rect()}"


class Session:
    def __init__(self, kind="wizard"):
        self.id = "20991231-000000-abcdef"
        self.kind = kind


def _page(wiz, rows=(("standalone-thick.x86", "x86"),), session=Session()):
    # the real order (initializePage): the session record first, then the rows; no
    # hand-made sync — the icons must follow from the page's own rendering
    page = progress_mod.ProgressPage(wiz)
    page._reset()
    page._session = session
    for i, (label, platform) in enumerate(rows):
        page._build_row(i, label, platform)
    return page


def _idx(platform, sid):
    return [p["id"] for p in platform_phases(platform)].index(sid)


def _run_until(page, i, sid, platform="x86", fail=True):
    """Feed banners up to and including stage ``sid``; ``fail``: the run ends there."""
    k = _idx(platform, sid)
    for ph in platform_phases(platform)[:k + 1]:
        page._on_line(i, "==> " + ph["any"][0])
        page._drain_lines()
    if fail:
        row = page._rows[i]
        row.tracker.finalize(1, time.monotonic())
        for j in range(len(row.stage_items)):
            page._render_stage(row, j, time.monotonic())
        page._all_terminal = True
    return k


@pytest.fixture
def dispatched(monkeypatch, wiz):
    calls = []
    monkeypatch.setattr(wiz, "start_build_from_session",
                        lambda s, resume=False, from_step="": calls.append((s, resume, from_step)))
    monkeypatch.setattr(build_sessions, "load", lambda path: ("loaded", os.path.basename(path)))
    return calls


def test_icons_appear_only_on_stages_that_have_run(wiz, qapp):
    page = _page(wiz)
    row = page._rows[0]
    assert len(row.rerun_btns) == len(row.stage_items)
    assert all(b.isHidden() for b in row.rerun_btns.values())       # nothing has run
    k = _run_until(page, 0, "image-live")
    for j, b in row.rerun_btns.items():
        st = row.tracker.stages[j].state
        assert b.isHidden() == (st not in rs.RERUNNABLE_STATES), (j, st)
    assert row.tracker.stages[k].state == "failed" and not row.rerun_btns[k].isHidden()
    assert row.rerun_btns[k].isEnabled()
    assert "“Build LIVE image” and the steps after it" in row.rerun_btns[k].toolTip()
    assert row.rerun_btns[k + 1].isHidden()                             # the installer never ran


def test_confirming_a_late_step_dispatches_from_that_step(wiz, qapp, dispatched):
    page = _page(wiz)
    k = _run_until(page, 0, "image-live")
    page._rows[0].rerun_btns[k].click()
    assert not page.rerun_box.isHidden()
    assert "Rerun standalone-thick.x86 from “Build LIVE image”?" in page.rerun_note.text()
    assert page.rerun_go_btn.text() == "Rerun from here"
    assert dispatched == []                                             # asking dispatches nothing
    page.rerun_go_btn.click()
    settle(qapp)
    assert dispatched == [(("loaded", "20991231-000000-abcdef.json"), True, "image-live")]
    assert page.rerun_box.isHidden()


def test_an_early_step_dispatches_resume_only(wiz, qapp, dispatched):
    page = _page(wiz)
    _run_until(page, 0, "image-live")
    k = _idx("x86", "kernel")
    assert page._rows[0].tracker.stages[k].state == "done"
    page._ask_rerun(0, k)
    assert "--resume" in page.rerun_note.text()
    page._rerun_confirm()
    settle(qapp)
    assert dispatched and dispatched[0][1:] == (True, "")


def test_cancel_dispatches_nothing(wiz, qapp, dispatched):
    page = _page(wiz)
    k = _run_until(page, 0, "image-live")
    page._ask_rerun(0, k)
    page.rerun_cancel_btn.click()
    settle(qapp)
    assert page.rerun_box.isHidden() and dispatched == []


def test_a_running_build_is_stopped_first_then_rerun(wiz, qapp, dispatched, monkeypatch):
    page = _page(wiz)
    k = _run_until(page, 0, "image-raw", fail=False)                    # .img running now
    j = _idx("x86", "package-stage4")
    assert page._rows[0].tracker.stages[j].state == "done"
    page._all_terminal = False
    stops = []
    monkeypatch.setattr(page, "_stop_all", lambda: stops.append(1))
    page._ask_rerun(0, j)
    assert "stopped first" in page.rerun_note.text()
    assert page.rerun_go_btn.text() == "Stop and rerun from here"
    page._rerun_confirm()
    settle(qapp)
    assert stops == [1] and dispatched == []                            # waits for the stop
    assert "Stopping the running build" in page.rerun_note.text()
    assert not page._rows[0].rerun_btns[j].isEnabled()                  # no second rerun meanwhile
    page._on_finished_all(1)                                            # the stop landed
    settle(qapp)
    assert dispatched and dispatched[0][1:] == (True, "package-stage4")
    assert k == _idx("x86", "image-raw")


@pytest.mark.parametrize("rows,session,why", [
    ((("a.x86", "x86"),), None, rs.NO_SESSION),
    ((("a.x86", "x86"),), Session(kind="fleet"), rs.FLEET),
    ((("a.x86", "x86"), ("b.x86", "x86")), Session(), rs.ONE_IMAGE_ONLY),
])
def test_refused_pages_grey_the_icon_with_the_reason(wiz, qapp, rows, session, why, dispatched):
    page = _page(wiz, rows=rows, session=session)
    k = _run_until(page, 0, "image-live")
    b = page._rows[0].rerun_btns[k]
    assert not b.isHidden() and not b.isEnabled() and b.toolTip() == why
    page._ask_rerun(0, k)
    assert page.rerun_box.isHidden() and dispatched == []


@pytest.mark.parametrize("w,h", SIZES)
def test_the_page_with_the_confirmation_open_fits(wiz, qapp, w, h):
    page = _page(wiz)
    k = _run_until(page, 0, "image-live")
    page.show()
    page.resize(w, h)
    settle(qapp)
    page.tree.expandItem(page._rows[0].job_item)
    page.tree.scrollToItem(page._rows[0].stage_items[k])
    page._ask_rerun(0, k)
    settle(qapp, 10)
    os.makedirs(SHOTS, exist_ok=True)
    path = os.path.join(SHOTS, f"rerun-step-{w}x{h}.png")
    assert page.grab().save(path), path
    print("screenshot:", path)
    assert page.height() <= h, f"the page grew past the window: {page.height()} > {h}"
    assert_inside(page.tree.viewport(), page._rows[0].rerun_btns[k], "↻ Rerun on Build LIVE image")
    for wdg, what in ((page.rerun_note, "the confirmation text"),
                      (page.rerun_go_btn, "Rerun from here"), (page.rerun_cancel_btn, "Cancel")):
        assert_inside(page, wdg, what)
    assert page.rerun_go_btn.width() >= page.rerun_go_btn.minimumSizeHint().width()

"""The Build page's "Kernel config…" — the GUI face, offscreen, against fixture sessions.

The operator ask (2026-11-11): *on the build step, after an image is done compiling the
kernel allow for a button to open menuconfig in another window and change the kernel
config and resign it and repackage the tar and images.*

What is pinned, on the REAL widgets (no sudo, no docker, no terminal window — the build
driver and the window opener are fakes):

* the button sits on the job's **Build kernel** stage row, exists from the first paint,
  is greyed with its reason until THAT stage is done, then latches on (x86) — and on an
  ARM job it stays greyed with the one-sentence x86-only refusal;
* clicking it opens the inline panel bound to that image; the docked log collapses to
  its header while the panel is open and comes back on Hide;
* the panel shows the saved change, refuses to rebuild while the image is still
  building (and says why, beside the button), opens menuconfig through the opener and
  shows the copyable command when no window can be opened;
* a rebuild streams into the panel, is recorded on the session, and says what it did;
* the Previous builds list and the per-build window offer the same action;
* LOOK: screenshots at 1200x800 and 942x552 (the smallest window), with every control
  asserted inside its window or scroll viewport — not merely "visible" to a parent that
  clipped it (the 193-green-tests lesson).
"""
import json
import os
import time

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import build_sessions                          # noqa: E402
from hugmesh_studio.core import kernel_reconfig as kr                   # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                  # noqa: E402
from hugmesh_studio.core.progress_parse import platform_phases          # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                     # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtWidgets                     # noqa: E402
from hugmesh_studio.gui.pages import build_window                       # noqa: E402
from hugmesh_studio.gui.pages import progress as progress_mod           # noqa: E402
from hugmesh_studio.gui.pages._kernel_reconfig_panel import (           # noqa: E402
    KernelConfigWindow, KernelReconfigPanel)

from _kernel_reconfig_fixture import KV, make_session, result_json     # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=True, builder_image="hugmesh-builder")
SIZES = ((1200, 800), (942, 552))
SHOTS = os.environ.get("KERNEL_CONFIG_SHOTS") or os.path.join(
    os.environ.get("TMPDIR", "/tmp"), "kernel-config-shots")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect", lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="session")
def qapp():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication(["kernel-config-tests"])


def settle(qapp, n=6):
    for _ in range(n):
        qapp.processEvents()


def shot(widget, name):
    os.makedirs(SHOTS, exist_ok=True)
    path = os.path.join(SHOTS, f"kernel-config-{name}.png")
    assert widget.grab().save(path), path
    print("screenshot:", path)
    return path


def assert_inside(container, widget, what):
    """The WHOLE widget rectangle lies inside ``container`` (window or scroll viewport)."""
    assert widget.isVisible(), f"{what} is not visible"
    tl = widget.mapTo(container, QtCore.QPoint(0, 0))
    r = QtCore.QRect(tl, widget.size())
    assert container.rect().contains(r), f"{what} {r} is outside {container.rect()}"


def assert_not_squeezed(button, what):
    assert button.width() >= button.minimumSizeHint().width(), \
        f"{what}: {button.width()}px < its {button.minimumSizeHint().width()}px minimum (text clipped)"


class FakeDriver:
    """Never sudo, never docker: records what would have been streamed."""

    def __init__(self, on_stream=None):
        self.streams = []
        self._on = on_stream or (lambda argv, cb: 0)
        self.cancelled = False

    def reconfig_context(self, backend=None, live_container=""):
        return kr.RunContext(backend=backend or "docker", generator_dir=GENERATOR_DIR,
                             container=live_container, run_container_name="sd-build-test")

    def stream_command(self, argv, cb, backend):
        self.streams.append(argv)
        return self._on(argv, cb)

    def cancel(self):
        self.cancelled = True


# ── the Progress page ──────────────────────────────────────────────────────────────
@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    yield w
    w.close()
    w.deleteLater()


def _page(wiz, rows):
    page = progress_mod.ProgressPage(wiz)
    page._reset()
    for i, (label, platform) in enumerate(rows):
        page._build_row(i, label, platform)
    return page


def _through_kernel(page, i, platform="x86", extra=1):
    k = progress_mod._kernel_stage_index(platform)
    for ph in platform_phases(platform)[:k + 1 + extra]:
        page._on_line(i, "==> " + ph["any"][0])
        page._drain_lines()
    return k


def test_button_is_on_the_kernel_stage_greyed_until_that_stage_is_done(wiz, qapp):
    page = _page(wiz, (("pki.x86", "x86"),))
    row = page._rows[0]
    k = progress_mod._kernel_stage_index("x86")
    btn = page.tree.itemWidget(row.stage_items[k], progress_mod._COL_FLAGS)
    assert btn is row.kernel_btn and btn.text() == progress_mod._KERNEL_BTN_TEXT
    assert row.stage_items[k].text(progress_mod._COL_NAME).endswith("Build kernel")
    assert not btn.isEnabled() and btn.toolTip() == progress_mod._KERNEL_BTN_HINT
    _through_kernel(page, 0, extra=0)                     # kernel stage RUNNING
    assert not btn.isEnabled() and not row.kernel_ready
    _through_kernel(page, 0, extra=1)                     # the next banner: kernel DONE
    assert btn.isEnabled() and row.kernel_ready
    assert btn.toolTip() == progress_mod._KERNEL_BTN_READY_HINT
    # the package button keeps its own cell on the JOB row
    assert page.tree.itemWidget(row.job_item, progress_mod._COL_FLAGS) is row.pkg_btn


def test_an_arm_job_stays_greyed_with_the_x86_only_sentence(wiz, qapp):
    page = _page(wiz, (("pki.rpi5", "rpi5"),))
    row = page._rows[0]
    if row.kernel_btn is None:
        pytest.skip("this board's progress table has no kernel stage")
    _through_kernel(page, 0, platform="rpi5", extra=1)
    assert not row.kernel_btn.isEnabled() and not row.kernel_ready
    assert row.kernel_btn.toolTip() == kr.NOT_X86.format(board="rpi5")


def test_open_binds_the_panel_and_swaps_the_log_down(wiz, qapp, tmp_path):
    page = _page(wiz, (("pki.x86", "x86"),))
    page._session = make_session(str(tmp_path), pending=True, status="running",
                                 image_status="running")
    _through_kernel(page, 0)
    assert not page.log_collapse_btn.isChecked()
    page._open_kernel_panel(0)
    assert not page.kernel_group.isHidden() and page.kernel_panel.image_id == "pki.x86"
    assert page.log_collapse_btn.isChecked()             # the log gave up its height
    assert 'CONFIG_LOCALVERSION: "" -> "-hmtest"' in page.kernel_panel.diff.toPlainText()
    assert not page.kernel_panel.apply_btn.isEnabled()
    assert page.kernel_panel.apply_reason.text() == kr.STILL_BUILDING
    page._hide_kernel_panel()
    assert page.kernel_group.isHidden() and not page.log_collapse_btn.isChecked()


@pytest.mark.parametrize("w,h", SIZES)
def test_look_progress_page_with_the_panel_open(wiz, qapp, tmp_path, w, h):
    page = _page(wiz, (("pki.x86", "x86"), ("pki.rpi5", "rpi5")))
    page._session = make_session(str(tmp_path), pending=True)
    k = _through_kernel(page, 0)
    page.show()
    page.resize(w, h)
    settle(qapp)
    page._open_kernel_panel(0)
    page.tree.expandItem(page._rows[0].job_item)
    page.tree.scrollToItem(page._rows[0].stage_items[k])
    settle(qapp, 10)
    shot(page, f"progress-{w}x{h}")
    assert page.height() <= h, f"the page grew past the window: {page.height()} > {h}"
    assert_inside(page.tree.viewport(), page._rows[0].kernel_btn, "Kernel config… on Build kernel")
    assert_not_squeezed(page._rows[0].kernel_btn, "Kernel config…")
    vp = page.kernel_scroll.viewport()
    p = page.kernel_panel
    for wdg, what in ((p.status, "status"), (p.open_btn, "Open menuconfig…"),
                      (p.show_btn, "Show changes"), (p.discard_btn, "Discard edit")):
        assert_inside(vp, wdg, what)
    for b in (p.open_btn, p.show_btn, p.discard_btn, p.apply_btn):
        assert_not_squeezed(b, b.text())
    assert p.diff.height() >= 48
    page.close()


# ── the panel ──────────────────────────────────────────────────────────────────────
def _panel(qapp, session, *, driver=None, opener=None, busy=lambda: ""):
    p = KernelReconfigPanel(GENERATOR_DIR, driver_factory=lambda: driver or FakeDriver(),
                            opener=opener or (lambda t, ctx: (True, "linux")), busy=busy)
    p.bind(session)
    return p


def test_panel_refuses_in_one_sentence(qapp, tmp_path):
    p = _panel(qapp, make_session(str(tmp_path), platform="rpi5"))
    assert p.status.text() == kr.NOT_X86.format(board="rpi5")
    assert not p.open_btn.isEnabled() and not p.apply_btn.isEnabled()
    assert p.apply_reason.text() == kr.NOT_X86.format(board="rpi5")


def test_panel_open_menuconfig_reports_inline(qapp, tmp_path):
    s = make_session(str(tmp_path))
    seen = []
    p = _panel(qapp, s, opener=lambda t, ctx: (seen.append((t.image_id, ctx.backend)) or (True, "linux")))
    p.open_btn.click()
    assert seen == [("pki.x86", "docker")]
    assert "menuconfig is open in its own terminal window" in p.open_note.text()
    cmd = "docker run -it --rm --privileged ..."
    p2 = _panel(qapp, s, opener=lambda t, ctx: (False, kr.NO_TERMINAL.format(cmd=cmd)))
    p2.open_btn.click()
    assert cmd in p2.open_note.text() and not p2.open_note.isHidden()


def test_panel_waits_for_the_machine(qapp, tmp_path):
    p = _panel(qapp, make_session(str(tmp_path), pending=True),
               busy=lambda: "Builds run one at a time on this machine and an emulated device (QEMU) is running — the rebuild waits until it finishes.")
    assert not p.apply_btn.isEnabled() and "one at a time" in p.apply_reason.text()


def test_panel_follows_the_edit_file(qapp, tmp_path):
    s = make_session(str(tmp_path))
    p = _panel(qapp, s)
    p.show()                                           # the poll skips a hidden panel
    assert p.diff.toPlainText() == "" and p.apply_reason.text() == kr.NO_EDIT
    pend = os.path.join(s.workdir, "wl-pki.x86", "kernel-reconfig", "pending")
    os.makedirs(pend)
    with open(os.path.join(pend, "config.before"), "w") as fh:
        fh.write('CONFIG_LOCALVERSION=""\n')
    with open(os.path.join(pend, "config.after"), "w") as fh:
        fh.write('CONFIG_LOCALVERSION="-x"\n')
    p._poll()                                          # what the 2s timer does
    assert 'CONFIG_LOCALVERSION: "" -> "-x"' in p.diff.toPlainText()
    assert p.apply_btn.isEnabled() and p.apply_reason.text() == ""


def test_panel_rebuild_streams_records_and_says_so(qapp, tmp_path):
    s = make_session(str(tmp_path), pending=True)
    t = kr.locate(s)
    d = os.path.join(t.build_root, "kernel-reconfig", "20261111T130000Z")
    os.makedirs(d)
    with open(os.path.join(d, "result.json"), "w") as fh:
        json.dump(result_json(), fh)

    def stream(argv, cb):
        assert argv[-3:] == ["apply", "--build-root", "/out/wl-pki.x86"]
        cb("==> Building hardened kernel (reconfigured: menuconfig)")
        cb("KRC_RESULT=/out/wl-pki.x86/kernel-reconfig/20261111T130000Z/result.json")
        return 0
    drv = FakeDriver(stream)
    p = _panel(qapp, s, driver=drv)
    got = []
    p.applied.connect(got.append)
    p.apply_btn.click()
    end = time.monotonic() + 10
    while p._worker is not None and time.monotonic() < end:
        qapp.processEvents()
        time.sleep(0.02)
    settle(qapp)
    assert drv.streams and got, p.open_note.text()
    assert "Building hardened kernel (reconfigured: menuconfig)" in p.log.toPlainText()
    assert p.open_note.text().startswith("Done: pki.x86: kernel " + KV)
    assert build_sessions.find(s.id).kernel_reconfigs[0]["new_kver"] == KV + "-hmtest"


def test_panel_rebuild_refusal_is_shown_not_recorded(qapp, tmp_path):
    s = make_session(str(tmp_path), pending=True)
    drv = FakeDriver(lambda argv, cb: (cb("[kernel-reconfig] REFUSED: The edited kernel config fails the build's hardening asserts: CONFIG_LSM malformed — nothing was rebuilt."), 3)[1])
    p = _panel(qapp, s, driver=drv)
    p.apply_btn.click()
    end = time.monotonic() + 10
    while p._worker is not None and time.monotonic() < end:
        qapp.processEvents()
        time.sleep(0.02)
    settle(qapp)
    assert "fails the build's hardening asserts" in p.open_note.text()
    assert not build_sessions.find(s.id).kernel_reconfigs


@pytest.mark.parametrize("w,h", SIZES)
def test_look_kernel_config_window(qapp, tmp_path, w, h):
    s = make_session(str(tmp_path), pending=True)
    win = KernelConfigWindow(GENERATOR_DIR, s, driver_factory=lambda: FakeDriver(),
                             opener=lambda t, ctx: (False, kr.NO_TERMINAL.format(
                                 cmd=kr.copyable(kr.edit_argv(t, ctx)))),
                             busy=lambda: "")
    win.show()
    win.resize(w, h)
    settle(qapp)
    win.panel.open_btn.click()
    settle(qapp, 10)
    shot(win, f"window-{w}x{h}")
    p = win.panel
    for wdg, what in ((p.title, "title"), (p.status, "status"), (p.open_btn, "Open menuconfig…"),
                      (p.show_btn, "Show changes"), (p.discard_btn, "Discard edit"),
                      (p.open_note, "the copyable command"), (p.diff, "the change"),
                      (p.apply_btn, "Rebuild kernel + re-sign + repackage")):
        assert_inside(win, wdg, what)
    for b in (p.open_btn, p.show_btn, p.discard_btn, p.apply_btn):
        assert_not_squeezed(b, b.text())
    assert p.apply_btn.isEnabled()
    assert "docker run -it" in p.open_note.text()
    win.close()


# ── Previous builds + the per-build window ─────────────────────────────────────────
def test_build_window_offers_kernel_config_from_real_state(qapp, tmp_path):
    class Row:
        kind, status, label, when = "session", "complete", "pki", ""

        def status_text(self):
            return "complete"
    r = Row()
    r.session = make_session(str(tmp_path / "a"))
    r.location = r.session.workdir
    assert build_window.actions_for(r)["kernel"].enabled
    r2 = Row()
    r2.session = make_session(str(tmp_path / "b"), platform="rpi5", sid="20261111-120002-abcdef")
    r2.location = r2.session.workdir
    act = build_window.actions_for(r2)["kernel"]
    assert not act.enabled and act.reason == kr.NOT_X86.format(board="rpi5")
    opened = []
    win = build_window.BuildActionsWindow(r, on_kernel=opened.append, on_log=lambda _r: None)
    assert win.buttons["kernel"].text() == "Kernel config…" and win.buttons["kernel"].isEnabled()
    win.buttons["kernel"].click()
    assert opened == [r]
    plain = build_window.BuildActionsWindow(r)
    assert "kernel" not in plain.buttons                # no handler wired, no dead button
    win.close()
    plain.close()


def test_previous_builds_list_has_the_button(wiz, qapp, tmp_path):
    from hugmesh_studio.gui.pages import sessions_widget
    s = make_session(str(tmp_path))
    w = sessions_widget.SessionsWidget(wiz) if hasattr(sessions_widget, "SessionsWidget") else None
    if w is None:
        cls = next(c for n, c in vars(sessions_widget).items()
                   if isinstance(c, type) and issubclass(c, QtWidgets.QWidget) and hasattr(c, "_update_buttons"))
        w = cls(wiz)
    w.refresh()
    w.table.selectRow(0)
    settle(qapp)
    assert w.kernel_btn.text() == "Kernel config…"
    assert w.kernel_btn.isEnabled(), w.kernel_btn.toolTip()
    w._open_kernel_config()
    win = w._kernel_windows[s.id]
    assert win.isVisible() and win.panel.target is not None
    win.close()

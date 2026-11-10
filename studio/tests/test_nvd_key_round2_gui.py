"""PR #957 round 2 — the NVD key box in the REAL Fleet window (offscreen, FAKE keys).

Round 1 measured a bare ``FleetPage`` resized to 960x1200, where everything fits, so its
geometry asserts could not see what the operator would: the ``FleetWindow`` opens at
760x700 and ticking "Run the OWASP pen-test harness" put the whole NVD block below the
fold (prover + refuter, 2026-11-10). These tests open the real window at its own size and
two others, CLICK the checkbox with a real mouse event, and assert every row of the block
lies inside the step's viewport — no manual scrolling. Screenshots go to
``$NVD_SHOTS_DIR`` (else the test's tmp dir).

The rest pins the refuter's other GUI findings:

* after Save the key is unrecoverable from the box — Show + Ctrl+Z (real key events)
  yields 0 characters (``clear()`` kept QLineEdit's undo history: 36 came back);
* "Set org secret" refuses while the box holds a key other than the stored one, and the
  success line names the STORED key's fingerprint, never the key;
* a Verify result is bound to the fingerprint it checked: a result for key A that
  arrives after B was saved does not paint "accepted" over B, and the "set anyway"
  wording follows the stored key's real state.
"""
from __future__ import annotations

import os
import time

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import nvd_key                                # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtGui, QtWidgets             # noqa: E402

from test_nvd_key_core import NVD_200, FakeOpener                     # noqa: E402

KEY_A = "11111111-2222-4333-8444-555555555555"
KEY_B = "abcdef01-2345-4678-9abc-def012345678"
GEN = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
#: the block an operator must see after the tick, top to bottom
BLOCK = ("need_label", "request_link", "guide_link", "key_edit", "show_btn",
         "activation_label", "empty_label", "save_btn", "verify_btn", "forget_btn")


@pytest.fixture(scope="module")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture(autouse=True)
def _no_modals(monkeypatch):
    def boom(*a, **k):
        raise AssertionError("a modal was opened")
    for name in ("exec", "information", "warning", "critical", "question"):
        monkeypatch.setattr(QtWidgets.QMessageBox, name, boom, raising=False)


@pytest.fixture
def shots(tmp_path):
    d = os.environ.get("NVD_SHOTS_DIR") or str(tmp_path)
    os.makedirs(d, exist_ok=True)
    return d


def _settle(qapp, n=6):
    for _ in range(n):
        qapp.processEvents()
        QtCore.QCoreApplication.sendPostedEvents(None, QtCore.QEvent.Type.LayoutRequest)
    qapp.processEvents()


def _wait(qapp, cond, s=10.0):
    end = time.monotonic() + s
    while time.monotonic() < end:
        qapp.processEvents()
        if cond():
            return True
        time.sleep(0.01)
    return False


@pytest.fixture
def window(qapp):
    from hugmesh_studio.gui.pages.fleet import FleetWindow
    made = []

    def make(w, h):
        win = FleetWindow(GEN)
        win.resize(w, h)
        win.show()
        _settle(qapp)
        made.append(win)
        return win
    yield make
    for win in made:
        win.hide()
        win.deleteLater()
    qapp.processEvents()


def _send_key(widget, key, mods=QtCore.Qt.KeyboardModifier.NoModifier, text=""):
    """A real QKeyEvent press + release through the event loop (this host's PyQt6 has
    no QtTest), the way the refuter's Ctrl+Z probe drove it."""
    for t in (QtCore.QEvent.Type.KeyPress, QtCore.QEvent.Type.KeyRelease):
        QtWidgets.QApplication.sendEvent(widget, QtGui.QKeyEvent(t, key, mods, text))


def _viewport_rect(sa, widget):
    tl = widget.mapTo(sa.viewport(), QtCore.QPoint(0, 0))
    return QtCore.QRect(tl, widget.size())


def _click(widget):
    """A real left-button press + release on the widget's box/label."""
    pos = QtCore.QPointF(8, widget.height() / 2)
    gpos = QtCore.QPointF(widget.mapToGlobal(pos.toPoint()))
    btn = QtCore.Qt.MouseButton.LeftButton
    for t, buttons in ((QtCore.QEvent.Type.MouseButtonPress, btn),
                       (QtCore.QEvent.Type.MouseButtonRelease,
                        QtCore.Qt.MouseButton.NoButton)):
        QtWidgets.QApplication.sendEvent(widget, QtGui.QMouseEvent(
            t, pos, gpos, btn, buttons, QtCore.Qt.KeyboardModifier.NoModifier))


SIZES = [(760, 700), (942, 552), (1200, 700)]


@pytest.mark.parametrize("start", ["checkbox", "bottom"])
@pytest.mark.parametrize("size", SIZES, ids=[f"{w}x{h}" for w, h in SIZES])
def test_ticking_a_pentest_brings_the_whole_nvd_block_into_view(qapp, window, shots,
                                                                size, start):
    from hugmesh_studio.gui.pages.fleet import STEP_PLATFORMS
    win = window(*size)
    page = win.page
    assert page.stack.currentIndex() == STEP_PLATFORMS
    sa = page.step_scroll(STEP_PLATFORMS)
    vp = sa.viewport().rect()
    # the operator scrolls to where the checkbox is (they have to see it to click it),
    # or all the way down, then clicks it
    if start == "checkbox":
        sa.ensureWidgetVisible(page.pentest)
    else:
        sa.verticalScrollBar().setValue(sa.verticalScrollBar().maximum())
    _settle(qapp)
    assert vp.contains(_viewport_rect(sa, page.pentest)), "cannot click what is not shown"
    assert not page.nvd_key.isVisible()
    _click(page.pentest)
    _settle(qapp)
    assert page.pentest.isChecked() and page.nvd_key.isVisible()
    w = page.nvd_key
    path = os.path.join(shots, f"nvd-r2-fleet-tick-{size[0]}x{size[1]}-{start}.png")
    assert win.grab().save(path) and os.path.getsize(path) > 1000
    vp = sa.viewport().rect()
    out = {name: _viewport_rect(sa, getattr(w, name)) for name in BLOCK}
    for name, r in out.items():
        assert getattr(w, name).isVisible(), name
        assert r.height() > 0 and r.width() > 0, name
        assert vp.contains(r), (f"{name} at y={r.y()}..{r.bottom()} is outside the "
                                f"{vp.width()}x{vp.height()} viewport at {size}; {out}")
    # no horizontal scroll was needed for it either
    assert sa.horizontalScrollBar().value() == 0


def test_pentest_only_tick_also_reveals_the_block(qapp, window, shots):
    from hugmesh_studio.gui.pages.fleet import STEP_PLATFORMS
    win = window(760, 700)
    page = win.page
    sa = page.step_scroll(STEP_PLATFORMS)
    sa.ensureWidgetVisible(page.pentest_only)
    _settle(qapp)
    _click(page.pentest_only)
    _settle(qapp)
    assert page.pentest_only.isChecked()
    vp = sa.viewport().rect()
    for name in BLOCK:
        assert vp.contains(_viewport_rect(sa, getattr(page.nvd_key, name))), name
    assert win.grab().save(os.path.join(shots, "nvd-r2-fleet-tick-only-760x700.png"))


def test_loading_a_saved_config_does_not_jump_the_scroll(qapp, window):
    """Only the operator's tick scrolls: a config applied with pentest on (a resume,
    Previous builds) shows the box but leaves the step where it was."""
    from hugmesh_studio.gui.pages.fleet import STEP_PLATFORMS
    win = window(760, 700)
    page = win.page
    sa = page.step_scroll(STEP_PLATFORMS)
    sa.verticalScrollBar().setValue(0)
    page.nvd_key.setVisible(False)
    page._reveal_nvd_key(True)             # box hidden -> nothing to reveal, no scroll
    _settle(qapp)
    assert sa.verticalScrollBar().value() == 0
    page._reveal_nvd_key(False)            # an untick never scrolls
    assert sa.verticalScrollBar().value() == 0


# ── the key cannot be recovered from the box after Save (real key events) ──────────
@pytest.fixture
def box(qapp):
    from hugmesh_studio.gui.pages._nvd_key_widget import NvdKeyWidget
    w = NvdKeyWidget()
    w.resize(700, 600)
    w.show()
    _settle(qapp)
    yield w
    w.hide()
    w.deleteLater()
    qapp.processEvents()


def _type(widget, text):
    widget.setFocus()
    for ch in text:
        _send_key(widget, 0, text=ch)


def _chord(widget, key):
    _send_key(widget, key, QtCore.Qt.KeyboardModifier.ControlModifier)


@pytest.mark.parametrize("show_first", [False, True])
def test_after_save_show_and_ctrl_z_recover_nothing(qapp, box, show_first):
    w = box
    if show_first:
        w.show_btn.click()
    _type(w.key_edit, KEY_A)
    assert w.key_edit.text() == KEY_A
    w.save_btn.click()
    _settle(qapp)
    assert nvd_key.load() == KEY_A
    assert w.key_edit.text() == ""
    if not w.show_btn.isChecked():
        w.show_btn.click()                  # the operator presses Show ...
    assert w.key_edit.echoMode() == QtWidgets.QLineEdit.EchoMode.Normal
    for key in (QtCore.Qt.Key.Key_Z, QtCore.Qt.Key.Key_Z, QtCore.Qt.Key.Key_Y):
        _chord(w.key_edit, key)             # ... then Ctrl+Z, Ctrl+Z, Ctrl+Y
        _settle(qapp, 1)
        assert w.key_edit.text() == "", "the saved key came back out of the undo history"
    w.key_edit.undo()
    w.key_edit.redo()
    assert w.key_edit.text() == ""
    assert not w.key_edit.isUndoAvailable() and not w.key_edit.isRedoAvailable()
    assert not w.key_edit.isModified()
    assert KEY_A not in w.key_edit.displayText()


# ── the org-secret push: the stored key, named by fingerprint ────────────────────────
class _Gh:
    def __init__(self):
        self.calls = []

    def run(self, argv, input=None, timeout=None, **kw):
        from types import SimpleNamespace
        self.calls.append((list(argv), input))
        if argv[:3] == ["gh", "secret", "set"]:
            return SimpleNamespace(returncode=0, text="", err="")
        return SimpleNamespace(returncode=0, text="2026-11-10T12:00:00Z\nall\n", err="")


def _verified_store(key):
    nvd_key.save(key)
    nvd_key.record_verdict(nvd_key.verify(key, opener=FakeOpener(NVD_200)))
    assert nvd_key.status().verified


def test_push_refuses_while_the_box_holds_a_different_key(qapp, box):
    w = box
    gh = _Gh()
    w._runner = gh
    _verified_store(KEY_A)
    w.refresh()
    w.org_tick.setChecked(True)
    w.org_edit.setText("acme")
    w.key_edit.setText(KEY_B)               # typed, not saved
    w.org_btn.click()
    _settle(qapp)
    assert gh.calls == [], "gh ran while the box held a different key"
    text = w.org_status.text()
    assert text.startswith("Not set")
    assert "Save" in text and nvd_key.short_fingerprint(nvd_key.status().fingerprint) in text
    assert KEY_A not in text and KEY_B not in text
    # a malformed leftover in the box is refused too (which key did they mean?)
    w.key_edit.setText("not-a-key")
    w.org_btn.click()
    _settle(qapp)
    assert gh.calls == [] and w.org_status.text().startswith("Not set")


def test_push_success_names_the_stored_fingerprint(qapp, box):
    w = box
    gh = _Gh()
    w._runner = gh
    _verified_store(KEY_A)
    w.refresh()
    w.org_tick.setChecked(True)
    w.org_edit.setText("acme")
    w.key_edit.setText(f"  {KEY_A} ")       # the SAME key typed again is fine
    w.org_btn.click()
    assert _wait(qapp, lambda: w.org_btn.isEnabled() and "set on" in w.org_status.text())
    assert gh.calls[0][1] == KEY_A.encode()
    fp = nvd_key.short_fingerprint(nvd_key.status().fingerprint)
    text = w.org_status.text()
    assert fp in text and "stored key" in text
    assert KEY_A not in text


# ── a Verify result belongs to the key it checked ────────────────────────────────────
def test_a_late_verify_for_key_a_does_not_mark_saved_key_b(qapp, box):
    w = box
    nvd_key.save(KEY_A)
    w.refresh()
    res_a = nvd_key.verify(KEY_A, opener=FakeOpener(NVD_200))
    assert res_a.ok
    # B is saved while A's Verify is still in flight ...
    w.key_edit.setText(KEY_B)
    w.save_btn.click()
    assert nvd_key.load() == KEY_B
    # ... then A's result arrives (stored=True: it was a Verify of the stored key)
    w._verified(res_a, True)
    text = w.status_label.text()
    assert not text.startswith("accepted"), text
    assert nvd_key.short_fingerprint(res_a.fingerprint) in text
    assert "not verified" in text
    assert not nvd_key.status().verified


def test_a_late_verify_for_a_typed_key_does_not_label_a_different_box(qapp, box):
    w = box
    res_a = nvd_key.verify(KEY_A, opener=FakeOpener(NVD_200))
    w.key_edit.setText(KEY_B)               # the box changed while A was verified
    w._verified(res_a, False)
    assert not w.status_label.text().startswith("accepted")
    # and Save of B does not inherit A's verdict
    w.save_btn.click()
    assert not nvd_key.status().verified


def test_a_verify_label_names_the_fingerprint_it_checked(qapp, box):
    w = box
    nvd_key.save(KEY_A)
    w.refresh()
    w._opener = FakeOpener(NVD_200)
    w.verify_btn.click()
    assert _wait(qapp, lambda: w.verify_btn.isEnabled())
    fp = nvd_key.short_fingerprint(nvd_key.status().fingerprint)
    assert w.status_label.text().startswith("accepted") and fp in w.status_label.text()


def test_set_anyway_wording_follows_the_stored_key(qapp, box):
    w = box
    w.refresh()
    assert "no key is stored" in w.set_anyway.text()
    nvd_key.save(KEY_A)
    w.refresh()
    fp = nvd_key.short_fingerprint(nvd_key.status().fingerprint)
    assert "has not passed Verify" in w.set_anyway.text() and fp in w.set_anyway.text()
    assert w.set_anyway.isEnabled()
    nvd_key.record_verdict(nvd_key.verify(KEY_A, opener=FakeOpener(NVD_200)))
    w.refresh()
    assert "not needed" in w.set_anyway.text() and fp in w.set_anyway.text()
    assert "was not OK" not in w.set_anyway.text()
    assert not w.set_anyway.isEnabled()


def test_org_row_wording_fits_in_the_real_window(qapp, window, shots):
    """The longer set-anyway wording and the box-conflict refusal, rendered in the
    FleetWindow at its own 760x700: the tick's text is not clipped and the refusal
    label is tall enough for its wrapped text."""
    from hugmesh_studio.gui.pages.fleet import STEP_PLATFORMS
    win = window(760, 700)
    page = win.page
    sa = page.step_scroll(STEP_PLATFORMS)
    w = page.nvd_key
    _verified_store(KEY_A)
    page.pentest.setChecked(True)
    w.refresh()
    w.org_tick.setChecked(True)
    w.org_edit.setText("acme")
    w._runner = _Gh()
    w.key_edit.setText(KEY_B)
    w.org_btn.click()
    _settle(qapp)
    sa.ensureWidgetVisible(w.org_status, 0, 8)
    _settle(qapp)
    for lab, name in ((w.set_anyway, "set_anyway"), (w.org_status, "org_status")):
        assert lab.isVisible() and lab.width() > 0 and lab.height() > 0, name
        assert sa.viewport().rect().contains(_viewport_rect(sa, lab)), name
    assert w.set_anyway.width() >= w.set_anyway.sizeHint().width(), "set-anyway text clipped"
    need = w.org_status.heightForWidth(w.org_status.width())
    assert w.org_status.height() >= need - 1, "refusal text clipped"
    assert "not needed" in w.set_anyway.text() and not w.set_anyway.isEnabled()
    assert w.org_status.text().startswith("Not set")
    assert win.grab().save(os.path.join(shots, "nvd-r2-org-row-conflict-760x700.png"))

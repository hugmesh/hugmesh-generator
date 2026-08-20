"""WorklistPage embedded combos must not eat scroll-wheel events (issue #46, wave 1).

The defect this pins: a plain QComboBox (focusPolicy=WheelFocus) CHANGES ITS VALUE
when a wheel event lands on it — and the worklist is a long scrollable tree full of
embedded combos, so scrolling the page silently edits whatever row the cursor
happens to cross. Wave-1 forensics found the only board=rpi4 image ever recorded
(``rpi5-desktop.rpi5``, session 20260815-154029-05f5d2) in a fleet with no Pi 4
hardware, every sibling row at its default: rpi4 is exactly ONE wheel notch below
the rpi5 default in that row's board combo. The flip re-keyed the image's binpkg
pool to the cold ``snap-build-pi4`` (0% reuse from the populated pi5 pool) — and the
same silent flip on the encrypt_root combo would toggle a node's disk encryption.

The fix is ``NoWheelComboBox`` (gui/pages/_widgets.py): an UNFOCUSED combo ignores
the wheel (the tree scrolls instead); a combo the operator deliberately clicked
(focused) still wheel-edits. These tests fail against a plain QComboBox — verified:
the unfocused wheel-down flips rpi5 -> rpi4 under Qt's offscreen platform too.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.platform_info import HostInfo            # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod               # noqa: E402
from hugmesh_studio.gui.qt import Qt, QtCore, QtGui, QtWidgets    # noqa: E402
from hugmesh_studio.gui.wizard import medium_size                 # noqa: E402
from hugmesh_studio.gui.pages._widgets import NoWheelComboBox     # noqa: E402
from hugmesh_studio.gui.pages.worklist import WorklistPage        # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def page(qapp):
    """The WorklistPage as the operator meets it: populated and shown."""
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    pid = [i for i in w.pageIds() if isinstance(w.page(i), WorklistPage)][0]
    w.setStartId(pid)
    w.restart()
    w.resize(medium_size(QtCore.QRect(0, 0, 1920, 1080)))
    w.show()
    QtWidgets.QApplication.processEvents()
    yield w.page(pid)
    w.close()
    w.deleteLater()
    QtWidgets.QApplication.processEvents()


def _wheel_down(widget):
    """One wheel notch down at the widget's top-left — what a hover-scroll delivers."""
    ev = QtGui.QWheelEvent(
        QtCore.QPointF(5, 5), QtCore.QPointF(5, 5),
        QtCore.QPoint(0, 0), QtCore.QPoint(0, -120),
        Qt.MouseButton.NoButton, Qt.KeyboardModifier.NoModifier,
        Qt.ScrollPhase.NoScrollPhase, False)
    QtWidgets.QApplication.sendEvent(widget, ev)
    return ev


def _embedded_combos(page):
    """Every combo embedded in the worklist tree, labeled: (rid, column, combo)."""
    out = []
    for rid, (board, flavor) in page._combos.items():
        if board is not None:
            out.append((rid, "board", board))
        if flavor is not None:
            out.append((rid, "flavor", flavor))
    for rid, enc in page._enc_combos.items():
        if enc is not None:
            out.append((rid, "encrypt_root", enc))
    for rid, svc in page._services_combos.items():
        if svc is not None:
            out.append((rid, "services", svc))
    return out


def test_rpi5_desktop_board_defaults_to_rpi5(page):
    """The wave-1 anomaly's baseline: the rpi5-desktop row's board combo DEFAULTS to
    rpi5 (RPI_BOARDS order). board=rpi4 can only ever be a deliberate selection."""
    board, _flavor = page._combos["rpi5-desktop.rpi5"]
    assert board is not None
    assert board.currentText() == "rpi5"


def test_unfocused_wheel_never_edits_an_embedded_combo(page):
    """Scrolling the table must scroll the table: a wheel event on ANY unfocused
    embedded combo leaves its value untouched. (The event still ends up accepted —
    by the TREE's scroll machinery after the combo ignores it and Qt propagates to
    the ancestor view, which is precisely the desired routing; the standalone-widget
    test below is where non-acceptance is observable.) Against a plain QComboBox
    this fails on every row — the rpi5-desktop board combo flips rpi5 -> rpi4, the
    wave-1 corruption."""
    combos = _embedded_combos(page)
    assert combos, "worklist page built no embedded combos — fixture broken?"
    for rid, col, combo in combos:
        before = combo.currentText()
        _wheel_down(combo)
        assert combo.currentText() == before, \
            f"{rid} {col}: wheel over the UNFOCUSED combo edited it " \
            f"({before!r} -> {combo.currentText()!r}) — the wave-1 board=rpi4 flip"


def test_unfocused_wheel_is_ignored_not_swallowed(qapp):
    """The ignored event must PROPAGATE (event.ignore(), accepted=False) so the
    containing view scrolls — observable on a standalone widget with no scrollable
    ancestor to accept it after propagation."""
    combo = NoWheelComboBox()
    combo.addItems(["rpi5", "rpi4", "rpi3"])
    ev = _wheel_down(combo)
    assert combo.currentText() == "rpi5"
    assert not ev.isAccepted(), \
        "NoWheelComboBox accepted an unfocused wheel event — the page could never scroll past it"


def test_focused_combo_still_wheel_edits(qapp):
    """A DELIBERATE edit still works: click (focus) the combo, then wheel. Pins the
    other half of the contract so the guard cannot rot into a dead control."""
    win = QtWidgets.QWidget()
    lay = QtWidgets.QVBoxLayout(win)
    combo = NoWheelComboBox()
    combo.addItems(["rpi5", "rpi4", "rpi3"])
    lay.addWidget(combo)
    win.show()
    win.activateWindow()
    QtWidgets.QApplication.processEvents()
    combo.setFocus(Qt.FocusReason.MouseFocusReason)
    QtWidgets.QApplication.processEvents()
    assert combo.hasFocus(), "offscreen focus did not take — fixture ordering broke"
    ev = _wheel_down(combo)
    assert combo.currentText() == "rpi4", "focused NoWheelComboBox no longer wheel-edits"
    assert ev.isAccepted()
    win.close()
    win.deleteLater()
    QtWidgets.QApplication.processEvents()


def test_every_embedded_combo_is_wheel_guarded(page):
    """Structural sweep: every combo embedded in the tree IS a NoWheelComboBox, so a
    future column added with a plain QComboBox reintroduces the trap loudly here."""
    for rid, col, combo in _embedded_combos(page):
        assert isinstance(combo, NoWheelComboBox), \
            f"{rid} {col}: embedded combo is a plain {type(combo).__name__} — " \
            "wheel-scroll over it silently edits the worklist (issue #46 wave 1)"

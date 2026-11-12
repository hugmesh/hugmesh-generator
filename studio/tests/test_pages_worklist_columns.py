"""WorklistPage column sizing — "the columns load in an unoptimal state making it hard
to read. The selection buttons are only visible after expanding the column."

Measured root cause: ``worklist.py`` hardcoded ``setColumnWidth(_COL_CHECK, 28)`` and
never called ``setSectionResizeMode`` at all, so every column sat at the header's
100px Interactive default. The check column needed 60px and had 28 — and with the #375
family-group rows a child row's checkbox starts at ``indentation()`` (20px), leaving
~8px for the indicator itself.

The check column is the page's PRIMARY control (it is what selects a node to build), so
it must be fully visible on arrival with no dragging.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.platform_info import HostInfo            # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod               # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtWidgets               # noqa: E402
from hugmesh_studio.gui.wizard import medium_size                 # noqa: E402
from hugmesh_studio.gui.pages.worklist import (                   # noqa: E402
    WorklistPage, _COL_CHECK, _COL_BOARD, _COL_ENC, _COL_FLAVOR, _COL_NOTES,
)

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
    """The WorklistPage as the operator meets it: populated (initializePage) and shown at
    the wizard's real default size on a 1080p screen — the operator's actual display, and
    the size the medium resolves to wherever there is room."""
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


def test_tree_is_actually_populated(page):
    """Real-cases check for every assertion below: an empty tree would satisfy all of them."""
    assert page.tree.topLevelItemCount() > 0
    assert page.tree.sizeHintForColumn(_COL_CHECK) > 0


def test_check_column_is_fully_visible_without_dragging(page):
    """THE report. The check column must be on screen, at its full needed width, with
    nothing pushed out of the viewport."""
    tree, hdr = page.tree, page.tree.header()
    x = hdr.sectionViewportPosition(_COL_CHECK)
    size = hdr.sectionSize(_COL_CHECK)
    need = tree.sizeHintForColumn(_COL_CHECK)

    assert 0 <= x, f"check column starts off the left of the viewport (x={x})"
    assert x + size <= tree.viewport().width(), (
        f"check column [{x}, {x + size}] spills past the viewport "
        f"({tree.viewport().width()}px) — the operator must drag to reach it")
    assert size >= need, (
        f"check column is clipped: {size}px allotted, {need}px needed — this is the "
        "hardcoded 28px bug")
    assert tree.horizontalScrollBar().maximum() == 0, (
        "the row spills into a horizontal scrollbar at the default size")


def test_check_column_fits_the_375_group_row_indent(page):
    """#375 added family GROUP rows, so a child row's checkbox is pushed right by
    indentation() before the indicator is even drawn. The column must budget for both or
    the indicator is clipped on exactly the rows that matter (the selectable children)."""
    tree, hdr = page.tree, page.tree.header()
    assert hdr.sectionSize(_COL_CHECK) >= tree.indentation() + 16, (
        f"check column {hdr.sectionSize(_COL_CHECK)}px leaves no room for the indicator "
        f"after the {tree.indentation()}px group-row indent")


def test_check_column_auto_sizes_to_contents(page):
    """The fix is a resize POLICY, not another hardcoded number: ResizeToContents
    re-measures after initializePage() populates the tree."""
    hdr = page.tree.header()
    assert hdr.sectionResizeMode(_COL_CHECK) == \
        QtWidgets.QHeaderView.ResizeMode.ResizeToContents
    assert hdr.minimumSectionSize() <= 24


def _combos_in(tree, col):
    """Every setItemWidget() combo in column ``col``, over the whole tree."""
    found = []
    it = QtWidgets.QTreeWidgetItemIterator(tree)
    while it.value():
        w = tree.itemWidget(it.value(), col)
        if isinstance(w, QtWidgets.QComboBox):
            found.append(w)
        it += 1
    return found


def test_widget_columns_are_not_resize_to_contents(page):
    """THE TRAP. _COL_BOARD/_COL_RAM/_COL_FLAVOR/_COL_ENC are filled with setItemWidget()
    combos. When this page was written, sizeHintForColumn() measured 0 for them and
    ResizeToContents collapsed the column and HID the combos; on Qt 6.11 it measures the
    combos' LONGEST item instead and would push the row off-screen. So they keep
    explicit, non-zero widths — and those widths must hold what each column carries."""
    from hugmesh_studio.gui.pages.worklist import _COL_RAM
    hdr = page.tree.header()
    for col, name in ((_COL_BOARD, "board"), (_COL_RAM, "ram"), (_COL_FLAVOR, "flavor"),
                      (_COL_ENC, "enc")):
        assert hdr.sectionResizeMode(col) != \
            QtWidgets.QHeaderView.ResizeMode.ResizeToContents, (
            f"{name} column is ResizeToContents, but its cells hold setItemWidget() "
            f"combos: it would collapse (or widen to the combos' longest item)")
        assert hdr.sectionSize(col) >= 60, f"{name} column too narrow for its combo"


def test_combo_columns_hold_their_widest_combo_and_their_header(page):
    """A combo column narrower than its widest combo cuts that combo's text where the
    operator reads it ("orange-pi-5-plus", the RAM column's "choose…"), and one narrower
    than its header cuts the header ("Flavor/Desktop"). Measured with this run's own
    style and font, so a wider font (DejaVu Sans on a CI runner) is checked too. The
    Encryption column is not measured here: its jetson cell is GUI-29's (#1011)."""
    from hugmesh_studio.gui.pages.worklist import _COL_RAM
    tree, hdr = page.tree, page.tree.header()
    for col, name in ((_COL_BOARD, "board"), (_COL_RAM, "ram"), (_COL_FLAVOR, "flavor")):
        combos = _combos_in(tree, col)
        assert combos, f"no {name} combo on the worklist: nothing would be measured"
        widest = max(combos, key=lambda c: c.sizeHint().width())
        assert hdr.sectionSize(col) >= widest.sizeHint().width(), (
            f"{name} column is {hdr.sectionSize(col)}px; its combo showing "
            f"{widest.currentText()!r} wants {widest.sizeHint().width()}px")
        assert hdr.sectionSize(col) >= hdr.sectionSizeHint(col), (
            f"{name} column is {hdr.sectionSize(col)}px; its header label wants "
            f"{hdr.sectionSizeHint(col)}px")


def test_notes_absorbs_the_slack(page):
    """Notes stretches, replacing the accidental stretchLastSection outcome that handed
    Notes 452px while Role starved at 100 despite needing 391. Sitting AT the 100px a
    Stretch section stops at means the other columns already overflow the viewport (the
    RAM column did that, by 42px, and this read exactly 100)."""
    hdr = page.tree.header()
    assert hdr.sectionResizeMode(_COL_NOTES) == QtWidgets.QHeaderView.ResizeMode.Stretch
    assert hdr.sectionSize(_COL_NOTES) > 100, (
        f"Notes has {hdr.sectionSize(_COL_NOTES)}px at the default size: the other "
        "columns ate its room (a new column takes its width from the others)")


def test_every_column_is_reachable_at_the_default_size(page):
    """Nothing is off-screen on arrival — the 'unoptimal state' half of the report."""
    tree, hdr = page.tree, page.tree.header()
    last = _COL_NOTES
    right = hdr.sectionViewportPosition(last) + hdr.sectionSize(last)
    assert right <= tree.viewport().width() + 1, (
        f"columns overflow the viewport: right edge {right} > {tree.viewport().width()}")

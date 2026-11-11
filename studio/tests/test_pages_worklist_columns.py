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
from hugmesh_studio.gui.pages.worklist import _COL_RAM, _COL_SERVICES  # noqa: E402

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


_WIDGET_COLUMNS = ((_COL_BOARD, "board"), (_COL_RAM, "ram"), (_COL_FLAVOR, "flavor"),
                   (_COL_ENC, "enc"), (_COL_SERVICES, "services"))


def test_widget_columns_are_not_resize_to_contents(page):
    """THE TRAP. The Board/RAM/Flavor/Encryption/Services cells are setItemWidget()
    combos, so the ITEM TEXT is empty and sizeHintForColumn() knows these columns only
    through the combos of EXPANDED rows. ResizeToContents would size them by whatever
    happens to be expanded: 0 for a collapsed family (the combos hidden), the widest
    choice for an expanded one (the row pushed off-screen). They must keep explicit,
    non-zero widths."""
    tree, hdr = page.tree, page.tree.header()
    for col, name in _WIDGET_COLUMNS:
        assert hdr.sectionResizeMode(col) != \
            QtWidgets.QHeaderView.ResizeMode.ResizeToContents, (
            f"{name} column is ResizeToContents, but its cells hold setItemWidget() "
            f"combos with no item text — its width would follow what is expanded")
        assert hdr.sectionSize(col) >= 60, f"{name} column too narrow for its combo"
    # the trap is real, not hypothetical: no cell in these columns carries text, and
    # with every family collapsed they measure 0 (Qt measures only the combos of the
    # rows it shows, so the hint depends on what is expanded)
    groups = [tree.topLevelItem(i) for i in range(tree.topLevelItemCount())]
    rows = [g.child(i) for g in groups for i in range(g.childCount())]
    for col, name in _WIDGET_COLUMNS:
        assert not any(r.text(col) for r in groups + rows), f"{name} cells carry text"
    assert any(tree.sizeHintForColumn(col) > 0 for col, _n in _WIDGET_COLUMNS), \
        "no expanded row shows a combo: the collapse below would prove nothing"
    expanded = [g.isExpanded() for g in groups]
    try:
        for g in groups:
            g.setExpanded(False)
        assert [tree.sizeHintForColumn(col) for col, _n in _WIDGET_COLUMNS] == \
            [0] * len(_WIDGET_COLUMNS)
    finally:
        for g, was in zip(groups, expanded):
            g.setExpanded(was)


def _edit_field_width(combo) -> int:
    """The width the combo's style gives its text: the edit field, inside the frame and
    left of the arrow, at the width the column gave the combo."""
    opt = QtWidgets.QStyleOptionComboBox()
    opt.initFrom(combo)
    opt.editable = combo.isEditable()
    opt.frame = combo.hasFrame()
    return combo.style().subControlRect(
        QtWidgets.QStyle.ComplexControl.CC_ComboBox, opt,
        QtWidgets.QStyle.SubControl.SC_ComboBoxEditField, combo).width()


def test_every_choice_reads_whole_in_its_column(page):
    """The other half of the budget: the widths came back from the combo columns, so no
    choice an operator picks may be cut where they read it. Every Board, RAM, Flavor and
    Encryption choice reads whole; in Services every single-service choice does, and
    only the combined one ("Tor onion + Egress VPN") elides, as it did before."""
    cells = []
    for rid in page.rows:
        board, flavor = page._combos[rid]
        cells += [("board", rid, board), ("flavor", rid, flavor),
                  ("ram", rid, page._ram_combos[rid]), ("enc", rid, page._enc_combos[rid]),
                  ("services", rid, page._services_combos[rid])]
    cells = [(name, rid, c) for name, rid, c in cells if c is not None]
    assert {name for name, _r, _c in cells} == {"board", "flavor", "ram", "enc",
                                                "services"}, "a combo column is missing"
    clipped = []
    for name, rid, combo in cells:
        room = _edit_field_width(combo)
        for i in range(combo.count()):
            if name == "services" and len(combo.itemData(i) or ()) > 1:
                continue
            text = combo.itemText(i)
            need = combo.fontMetrics().horizontalAdvance(text)
            if need > room:
                clipped.append(f"{rid} {name} {text!r}: {need}px > {room}px")
    assert not clipped, "choices cut in their column:\n" + "\n".join(sorted(set(clipped)))


def test_notes_absorbs_the_slack(page):
    """Notes stretches, replacing the accidental stretchLastSection outcome that handed
    Notes 452px while Role starved at 100 despite needing 391."""
    hdr = page.tree.header()
    assert hdr.sectionResizeMode(_COL_NOTES) == QtWidgets.QHeaderView.ResizeMode.Stretch
    assert hdr.sectionSize(_COL_NOTES) > 100


def test_every_column_is_reachable_at_the_default_size(page):
    """Nothing is off-screen on arrival — the 'unoptimal state' half of the report."""
    tree, hdr = page.tree, page.tree.header()
    last = _COL_NOTES
    right = hdr.sectionViewportPosition(last) + hdr.sectionSize(last)
    assert right <= tree.viewport().width() + 1, (
        f"columns overflow the viewport: right edge {right} > {tree.viewport().width()}")

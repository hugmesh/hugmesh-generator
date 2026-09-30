"""The Selection column of the per-domain Services tables (hugmesh-generator#647).

What the operator saw on 2026-09-24, after the per-domain Services step landed on every
mesh route: nowhere to tick a service. The column holding the checkboxes was sized to
its header text, and a service row's cell starts two indentation steps in (the group
row, then the row) — so under the two-letter header "On" the cell was ZERO pixels wide
and the checkbox was never drawn. They renamed the header to "Selection" (PR #646),
which made the column wide enough at the default font, with four pixels to spare.

What is pinned here, on the REAL hosts of the shared body, headless (offscreen):

* the column is at least as wide as the style's checkbox indicator — measured where it
  matters, in the row's cell after its indentation — and the checkbox lies wholly
  inside its cell, on the image flow's page, the local docker mesh's step and the
  fleet's step, each at its default window size;
* a click in that column ticks the row: on the checkbox, beside it, and in the row's
  indentation;
* the width does NOT come from the header text: relabelled to the old "On" the
  checkbox is still whole and still clickable (this is the case that goes red when the
  width rule is removed — under "Selection" the old content-sized column happens to
  fit);
* a style with a bigger checkbox (a stylesheet) widens the column instead of clipping;
* the operator's header text "Selection" is kept, on both tables of the body, and the
  TUI's tables head the same column "selection" — read off the live page, so neither
  face can be renamed alone.

The GUI half skips without a Qt binding (the Qt-free job); the TUI half never skips.
Nothing here calls ``.exec()``.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from hugmesh_studio.core.config import Domain                          # noqa: E402
from hugmesh_studio.core.local_mesh_domains import LocalMeshDomains    # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                 # noqa: E402
from hugmesh_studio.tui import domain_services_step as tui_step        # noqa: E402
from hugmesh_studio.tui import journey                                 # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")

#: The header the operator gave the checkbox column (PR #646). Kept.
SELECTION = "Selection"


# ── TUI (never skipped): the word ─────────────────────────────────────────────────
def test_tui_tables_head_the_column_with_the_operators_word():
    d = Domain(name="a.example", optional_services=["akkoma"])
    assert tui_step.SELECTION_HEADER == SELECTION.lower()
    for headers, rows in (tui_step.service_table(d), tui_step.front_door_table(d)):
        assert headers[1] == "selection" and "on" not in headers
        assert {r[1] for r in rows} <= {"on", "-"}          # the cell still says on/off


def test_tui_screen_prints_the_header(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    md = LocalMeshDomains(domains=[Domain(name="mesh.example"), Domain(name="b.example")],
                          own_name="mesh.example")
    screen = tui_step.DomainServicesScreen(cfg_of=lambda j: md)
    j = journey.Journey(".")
    screen.enter(j)
    screen.feed(j, "n")
    heads = [ln.split() for ln in screen.lines(j) if "selection" in ln.split()[:2]]
    assert [h[:3] for h in heads] == [["#", "selection", "service"],
                                      ["cmd", "selection", "front"]]


# ── GUI (skips only without a Qt binding) ─────────────────────────────────────────
def _qt():
    return pytest.importorskip("hugmesh_studio.gui.qt",
                               reason="no Qt binding (PySide6/PyQt6) installed")


@pytest.fixture(scope="module")
def qapp():
    qt = _qt()
    return (qt.QtWidgets.QApplication.instance()
            or qt.QtWidgets.QApplication(["hugmesh-studio-selection-column"]))


def _settle(qapp):
    for _ in range(3):
        qapp.processEvents()


def _walk_to(wiz, cls, limit=16):
    for _ in range(limit):
        if isinstance(wiz.currentPage(), cls):
            return wiz.currentPage()
        before = wiz.currentId()
        wiz.next()
        assert wiz.currentId() != before, \
            f"flow stuck on {type(wiz.currentPage()).__name__}"
    raise AssertionError(f"never reached {cls.__name__}")


def _image_flow(qapp, monkeypatch):
    """The image flow's page, in the wizard at its default size, on an ADDED domain."""
    from hugmesh_studio.gui import wizard as wizard_mod
    from hugmesh_studio.gui.pages import domain_services as page_mod
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    c = w.cfg
    c.mode, c.role, c.additional_domains = "mesh", "omnibus", True
    c.domains = [Domain(name="acme.example", optional_services=["akkoma"])]
    w.restart()
    page = _walk_to(w, page_mod.DomainServicesPage)
    page._step(1)
    return page, w


def _local_mesh(qapp, monkeypatch):
    """The local docker mesh's Domain services step, reached through the wizard."""
    from hugmesh_studio.gui import wizard as wizard_mod
    from hugmesh_studio.gui.pages import localmesh as localmesh_mod
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    w.next()
    mode = w.currentPage()
    mode._buttons["localmesh"].setChecked(True)
    mode._on_mode_toggled()
    w.next()
    w.currentPage()._buttons["generate"].setChecked(True)
    w.next()
    _walk_to(w, localmesh_mod.LocalMeshDomainsPage)
    ctl = w.page(w._page_ids["localmesh"])
    ctl.domains_table._add("acme.example", "Acme")
    _walk_to(w, localmesh_mod.LocalMeshDomainServicesPage)
    ctl.domain_services._step(1)
    return ctl.domain_services, w


def _fleet(qapp, monkeypatch):
    """The fleet's Domain services step, in the fleet page at its default size."""
    from hugmesh_studio.core.fleet import FleetDriver
    from hugmesh_studio.gui.pages import fleet as fleet_mod
    monkeypatch.setattr("hugmesh_studio.core.build_driver.detect",
                        lambda builder_image="hugmesh-builder": HOST)
    p = fleet_mod.FleetPage(GENERATOR_DIR)
    p.driver = FleetDriver(GENERATOR_DIR, HOST)
    p.driver._image_present = lambda: True
    p.driver.run = lambda *a, **k: 0
    p.show()
    p.cluster_domain.setText("mesh.example")
    while p.stack.currentIndex() < fleet_mod.STEP_DOMAINS:
        p.next_btn.click()
    p.domains_table._add("acme.example", "Acme")
    p.next_btn.click()
    assert p.stack.currentIndex() == fleet_mod.STEP_DOMAIN_SERVICES
    p.domain_services._step(1)
    return p.domain_services, p


_HOSTS = {"image-flow": _image_flow, "local-docker-mesh": _local_mesh, "fleet": _fleet}


@pytest.fixture(params=sorted(_HOSTS))
def host(request, qapp, monkeypatch, tmp_path):
    """``(body, window)`` — the shared body on one of its real hosts, walked onto an
    added domain (the screen with BOTH checkbox tables live), shown at the host's own
    default size."""
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    body, window = _HOSTS[request.param](qapp, monkeypatch)
    assert body.current_domain() == "acme.example"
    _settle(qapp)
    yield body, window
    window.close()
    window.deleteLater()
    _settle(qapp)


def _mod():
    from hugmesh_studio.gui.pages import domain_services as page_mod
    return page_mod


def _indicator_width(box) -> int:
    qt = _qt()
    return box.style().pixelMetric(
        qt.QtWidgets.QStyle.PixelMetric.PM_IndicatorWidth, None, box)


def _indicator_rect(box):
    """Where the style draws the checkbox inside ``box``."""
    qt = _qt()
    opt = qt.QtWidgets.QStyleOptionButton()
    opt.initFrom(box)
    return box.style().subElementRect(
        qt.QtWidgets.QStyle.SubElement.SE_CheckBoxIndicator, opt, box)


def _first_service(body):
    slug = next(iter(body._boxes))
    return slug, body._rows[slug], body._boxes[slug]


def _assert_whole_checkbox(table, item, box):
    """The row's checkbox is wholly inside its Selection cell, and that cell — the part
    of the column left AFTER the row's indentation — is at least as wide as the
    style's checkbox indicator."""
    mod = _mod()
    need = _indicator_width(box)
    cell = table.visualRect(table.indexFromItem(item, mod._COL_ON))
    assert table.header().sectionSize(mod._COL_ON) >= need
    assert cell.width() >= need, \
        f"the Selection cell is {cell.width()}px wide; the checkbox needs {need}px"
    geom = box.geometry()
    assert cell.contains(geom), f"checkbox {geom.getRect()} outside cell {cell.getRect()}"
    assert geom.width() >= need
    assert box.rect().contains(_indicator_rect(box))
    assert table.viewport().rect().contains(geom.topLeft())


def _click(table, pos) -> None:
    """A left click at ``pos`` (viewport coordinates), delivered the way the window
    system delivers one: to the widget under the pointer, and from there up through
    its parents when that widget does not take it."""
    qt = _qt()
    vp = table.viewport()
    target = vp.childAt(pos) or vp
    local = qt.QtCore.QPointF(target.mapFrom(vp, pos))
    glob = qt.QtCore.QPointF(target.mapToGlobal(local.toPoint()))
    left, none = qt.Qt.MouseButton.LeftButton, qt.Qt.MouseButton.NoButton
    for kind, buttons in ((qt.QtCore.QEvent.Type.MouseButtonPress, left),
                          (qt.QtCore.QEvent.Type.MouseButtonRelease, none)):
        ev = qt.QtGui.QMouseEvent(kind, local, glob, left, buttons,
                                  qt.Qt.KeyboardModifier.NoModifier)
        qt.QtWidgets.QApplication.sendEvent(target, ev)
    qt.QtWidgets.QApplication.processEvents()


def _cell(table, item):
    return table.visualRect(table.indexFromItem(item, _mod()._COL_ON))


# ── 1. visible, on every host, at the default window size ─────────────────────────
def test_the_checkbox_column_shows_the_whole_checkbox_on_every_host(host):
    body, _window = host
    mod = _mod()
    slug, item, box = _first_service(body)
    _assert_whole_checkbox(body.table, item, box)
    # every service row, not only the first
    for s, b in body._boxes.items():
        _assert_whole_checkbox(body.table, body._rows[s], b)
    # the front-door table's checkbox too (an added domain has one)
    assert body._tor_box is not None
    _assert_whole_checkbox(body.front_door_table, body._tor_item, body._tor_box)
    # the explicit rule is what sized it: a fixed section, not a content-sized guess
    fixed = _qt().QtWidgets.QHeaderView.ResizeMode.Fixed
    for t in (body.table, body.front_door_table):
        assert t.header().sectionResizeMode(mod._COL_ON) == fixed
        assert t.header().sectionSize(mod._COL_ON) == mod.selection_column_width(t)
        # and the header is never cut short by it
        assert t.header().sectionSize(mod._COL_ON) >= \
            t.header().sectionSizeHint(mod._COL_ON)


# ── 2. a click in that column ticks the row ───────────────────────────────────────
def test_a_click_in_the_selection_column_toggles_the_row(host):
    body, _window = host
    slug, item, box = _first_service(body)
    before = box.isChecked()
    cell = _cell(body.table, item)
    # (a) on the checkbox itself
    on_box = box.geometry().topLeft() + _indicator_rect(box).center()
    _click(body.table, on_box)
    assert box.isChecked() is (not before)
    assert (slug in body.selected_slugs()) is (not before)
    # (b) in the cell, beside the checkbox — once, never twice
    beside = cell.topRight()
    beside.setX(cell.right() - 1)
    beside.setY(cell.center().y())
    assert not _indicator_rect(box).translated(box.geometry().topLeft()).contains(beside)
    _click(body.table, beside)
    assert box.isChecked() is before
    # (c) in the row's indentation, left of the cell but still in the column
    indent = cell.center()
    indent.setX(max(1, cell.left() - 3))
    _click(body.table, indent)
    assert box.isChecked() is (not before)
    # a click in ANOTHER column does nothing to the row
    other = body.table.visualRect(
        body.table.indexFromItem(item, _mod()._COL_DESC)).center()
    _click(body.table, other)
    assert box.isChecked() is (not before)


def test_a_click_in_the_front_door_tables_column_toggles_the_front_door(host):
    body, _window = host
    box, item = body._tor_box, body._tor_item
    assert box.isChecked() is False and body.tor_front_door() is False
    _click(body.front_door_table,
           box.geometry().topLeft() + _indicator_rect(box).center())
    assert box.isChecked() is True and body.tor_front_door() is True
    cell = _cell(body.front_door_table, item)
    beside = cell.center()
    beside.setX(cell.right() - 1)
    _click(body.front_door_table, beside)
    assert box.isChecked() is False and body.tor_front_door() is False


def test_the_own_domains_front_door_row_takes_no_click(host):
    # the mesh's own domain has no control there (its front door is the mesh's onion)
    body, _window = host
    body._step(-1)
    assert body._tor_box is None
    item = body.front_door_table.topLevelItem(0)
    _click(body.front_door_table, _cell(body.front_door_table, item).center())
    assert body._tor_box is None and body.tor_front_door() is False


# ── 3. the width is NOT the header's ──────────────────────────────────────────────
def test_the_old_two_letter_header_no_longer_hides_the_checkbox(host, qapp):
    # THE REGRESSION ITSELF. With a content-sized column, "On" made the section
    # exactly as wide as the row's indentation, the cell zero pixels wide, and the
    # checkbox was never laid out. The production header stays "Selection" — the
    # relabel is only how this test takes the header's help away.
    body, _window = host
    mod = _mod()
    for t in (body.table, body.front_door_table):
        t.headerItem().setText(mod._COL_ON, "On")
    body._step(-1)
    body._step(1)                      # a rebuild, as any walk does
    _settle(qapp)
    slug, item, box = _first_service(body)
    assert body.table.headerItem().text(mod._COL_ON) == "On"
    _assert_whole_checkbox(body.table, item, box)
    _assert_whole_checkbox(body.front_door_table, body._tor_item, body._tor_box)
    before = box.isChecked()
    _click(body.table, box.geometry().topLeft() + _indicator_rect(box).center())
    assert box.isChecked() is (not before)


def test_a_style_with_a_bigger_checkbox_widens_the_column(host, qapp):
    body, window = host
    mod = _mod()
    narrow = body.table.header().sectionSize(mod._COL_ON)
    window.setStyleSheet("QCheckBox::indicator { width: 34px; height: 34px; }")
    _settle(qapp)
    slug, item, box = _first_service(body)
    assert _indicator_width(box) >= 34          # the style really did change
    assert body.table.header().sectionSize(mod._COL_ON) > narrow
    _assert_whole_checkbox(body.table, item, box)
    _assert_whole_checkbox(body.front_door_table, body._tor_item, body._tor_box)


# ── 4. the word ───────────────────────────────────────────────────────────────────
def test_both_tables_keep_the_operators_header(host):
    body, _window = host
    mod = _mod()
    assert mod._HEADERS[mod._COL_ON] == SELECTION
    for t in (body.table, body.front_door_table):
        assert t.headerItem().text(mod._COL_ON) == SELECTION


def test_the_tui_tables_are_headed_like_the_gui_tables(host):
    """PARITY, read off the live page: the TUI's headers are the GUI tables' own
    header texts in lower case (the GUI's empty settings column has no TUI twin, and
    the TUI's first column is the command to type)."""
    body, _window = host
    d = Domain(name="a.example")

    def gui(table):
        item = table.headerItem()
        texts = [item.text(c) for c in range(table.columnCount())]
        return [t.lower() for t in texts if t]
    assert gui(body.table) == tui_step.service_table(d)[0][1:]
    assert gui(body.front_door_table) == tui_step.front_door_table(d)[0][1:]

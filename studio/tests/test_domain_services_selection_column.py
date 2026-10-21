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

THE GEOMETRY CHECKS RUN UNDER SEVERAL LOOKS (``_LOOKS``): the default style at the
default point size, the same at 8 pt, and every KDE style installed here (Breeze,
Oxygen) at 8 pt — the rows of #647's table where the header-sized column hid or clipped
the checkbox (Oxygen's indicator is 23 px; at 8 pt "Selection" alone left it 21 px) —
and the default style at 11.25 pt and 13.5 pt: what a forced font DPI of 120 and 144
makes of a 9 pt face on a platform that scales fonts alone (the robustness review of
#582 asked for 120 and 144). The style and font are set on the application BEFORE the
host is built and restored after. The click and wording checks run under the default
look only (the host is rebuilt for every case, and each build is a whole wizard).

WHY THE BIGGER FACES AND NOT ``QT_FONT_DPI``: under the offscreen platform that
variable does not enlarge the font at all — measured, the 9 pt face is 14 px tall at
96, 120 and 144 — it sets the device pixel ratio (1.25, 1.5) and so SHRINKS the logical
screen from 800x800 to 640x640 and 533x533, and ``medium_size`` clamps the wizard to
588x588 and 490x490. That is a small-screen case, which ``_SIZES`` covers directly and
deterministically (the 640x640 one); the bigger faces cover the fonts-only case. Both
are real desktops. So that the test host's screen cannot move what is measured, every
wizard host is built and then sized to the 800x800 screen's default (``_BUILT_ON``):
the same 736x736 window under any QT_FONT_DPI.

WHAT IS DRAWN IS ALSO CHECKED AS A WHOLE (#647, looked at): on every host the body's
widgets follow one another instead of overlapping — the fleet's step laid the front-door
table and the state line over the services table's lower rows until it scrolled like the
other two hosts — and the local docker mesh step's subtitle is whole at the wizard's
default size, where the longer sentence it replaced was cut off.

AND WHAT IS ON SCREEN WITHOUT SCROLLING (looked at again, the correctness review of
#582): the front-door checkbox, its table and the state line under it are inside the
page's scroll viewport at each host's default window size, under every look — ticked
and unticked. They were not: the services table kept a 300 px floor over some 180 px of
rows and the front-door table 90 px for one row, and the state line (which login the
onion serves, that Tor must be on for the mesh, what this route does with the tick) sat
2 to 48 px under the fold of the local docker mesh step and the fleet step. Both tables
are now exactly as tall as their rows (``fit_table_height``), re-fitted when the style
or font changes and when a group row is folded, and the state line is the front-door
table's caption with no gap. ``isVisible()`` cannot see a fold — a widget scrolled out
of the viewport is "visible" — so these tests measure viewport-relative geometry.

AND AT OTHER WINDOW SIZES AND BIGGER FACES (the robustness review of #582): with the
front door laid out UNDER the catalogue it was off screen again at a 13.5 pt face (the
local mesh step's checkbox cut by 3 px at 1040x780) and on any logical screen shorter
than about 700 px. The front-door block now comes right after the domain navigation,
ABOVE the long catalogue and its prose, on both faces (the TUI prints the same order),
and the fold is measured at the host's default size AND at every size in ``_SIZES``
under every look in ``_LOOKS``. The catalogue, a list, is what scrolls.

AND READABLE ACROSS, NOT ONLY ON SCREEN (the robustness review of #582, round 2): the
fold check above measures a vertical span, so with the state line's word wrap turned
off it stayed green while the rendered page was unreadable — the line became one row
cut at the page's right edge, and since the page's content widget takes the width of
its widest child, the banner, the lane note, the help and the "Not domain-scoped"
heading were cut there too, with no horizontal scrollbar to reach the rest (the page's
scroll area never shows one). So wherever the fold is measured, every prose label of
the body is measured too (``_prose_is_readable``): it wraps, its right edge mapped
into the scroll viewport is inside the viewport's width, it is as tall as the lines it
wraps to, and the content widget as a whole is no wider than the viewport.

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
    # the front door's table first, then the catalogue — the GUI page's order (#647)
    assert [h[:3] for h in heads] == [["cmd", "selection", "front"],
                                      ["#", "selection", "service"]]


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


def _dispose(window, qapp):
    """Really take a host's window down. ``deleteLater`` only posts a deferred
    delete, and with no ``exec()`` loop ever running in a test process that event is
    never delivered by ``processEvents`` alone — so every wizard this file builds
    (three hosts under four looks, many times over) stayed alive, and the 43rd
    test's style change had to re-polish forty windows' worth of widgets: the run
    stalled at 100% CPU and 2 GB. Delivering the deferred deletes here keeps each
    test to its own window."""
    qt = _qt()
    window.close()
    window.deleteLater()
    _settle(qapp)
    qapp.sendPostedEvents(None, qt.QtCore.QEvent.Type.DeferredDelete.value)
    _settle(qapp)


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
    """The fleet's Domain services step, in the fleet's real host window
    (``FleetWindow``, 760x700 by default) — as the two wizard hosts are measured in
    their real windows. A bare ``FleetPage`` has no default size: shown on its own it
    took its natural 533x533 at 13.5 pt, where the front-door table's 482 px of
    columns did not fit, an inner horizontal scrollbar covered the last row and the
    height pins failed on a window nobody opens."""
    from hugmesh_studio.core.fleet import FleetDriver
    from hugmesh_studio.gui.pages import fleet as fleet_mod
    monkeypatch.setattr("hugmesh_studio.core.build_driver.detect",
                        lambda builder_image="hugmesh-builder": HOST)
    win = fleet_mod.FleetWindow(GENERATOR_DIR)
    p = win.page
    p.driver = FleetDriver(GENERATOR_DIR, HOST)
    p.driver._image_present = lambda: True
    p.driver.run = lambda *a, **k: 0
    win.show()
    p.cluster_domain.setText("mesh.example")
    while p.stack.currentIndex() < fleet_mod.STEP_DOMAINS:
        p.next_btn.click()
    p.domains_table._add("acme.example", "Acme")
    p.next_btn.click()
    assert p.stack.currentIndex() == fleet_mod.STEP_DOMAIN_SERVICES
    p.domain_services._step(1)
    return p.domain_services, win


_HOSTS = {"image-flow": _image_flow, "local-docker-mesh": _local_mesh, "fleet": _fleet}

#: The KDE styles #647 measured the clipping under. Each one that is installed is
#: measured; Fusion (built into Qt) always is.
_KDE_STYLES = ("Breeze", "Oxygen")


def _installed_looks():
    """``[(style name, point size or None for the default), ...]`` — computed at
    collection so each look is its own test id. Without a Qt binding the GUI tests
    skip in ``_qt()`` anyway, so the list is then only a placeholder."""
    try:
        from hugmesh_studio.gui import qt as qt_mod
    except Exception:                          # noqa: BLE001 — no binding: see _qt()
        return [("Fusion", None)]
    qt_mod.QtWidgets.QApplication.instance() \
        or qt_mod.QtWidgets.QApplication(["hugmesh-studio-selection-column"])
    keys = set(qt_mod.QtWidgets.QStyleFactory.keys())
    return ([("Fusion", None), ("Fusion", 8.0)]
            + [(s, 8.0) for s in _KDE_STYLES if s in keys]
            # 9 pt at a forced font DPI of 120 and 144 (fonts scaled, widgets not)
            + [("Fusion", 11.25), ("Fusion", 13.5)])


_LOOKS = _installed_looks()

#: The screens a wizard window is sized for here, each through ``gui.wizard.
#: medium_size`` (the wizard's own clamp, so a change to it moves these): the
#: documented real ones — 1080p (1040x780), a 1366x768 laptop at 125 % scaling (a
#: 1092x614 logical screen, 1004x564) and a 1024x600 netbook (942x552) — plus the
#: offscreen platform's own 800x800 (736x736, the size the operator's #647
#: measurements used) and the 640x640 LOGICAL screen that platform shows under
#: QT_FONT_DPI=120 (588x588: there the variable sets the device pixel ratio, not the
#: font — see the module docstring), kept as a small-screen case.
_SCREENS = {"1080p": (1920, 1080), "768p-at-125pc": (1092, 614),
            "1024x600-netbook": (1024, 600), "800x800-offscreen": (800, 800),
            "640x640-logical": (640, 640)}

#: Every "as built" measurement of a WIZARD host is taken at the 800x800 screen's
#: default, set explicitly in ``_build_host``: the wizard sizes itself from the
#: platform's screen, which under QT_FONT_DPI=120 / 144 is 640x640 / 533x533 logical
#: pixels — a 490x490 window at a 13.5 pt face wraps the state line to ten lines and
#: puts a scrollbar on a six-column table, and no desktop has that screen. Pinned, the
#: file measures the same window whatever the test host's platform says.
_BUILT_ON = "800x800-offscreen"

#: Window sizes the fold is measured at, besides the host's as-built size.
_SIZES = tuple(_SCREENS.items())


def _size_of(label):
    from hugmesh_studio.gui.wizard import medium_size
    qt = _qt()
    w, h = _SCREENS[label]
    return medium_size(qt.QtCore.QRect(0, 0, w, h))


def _look_id(look):
    style, pt = look
    return f"{style}-{'default' if pt is None else str(int(pt)) + 'pt'}"


def _apply_look(qapp, look):
    """Put ``look`` (style name, point size or None) on the application; returns what
    to restore. Asserted, so a style that failed to load cannot pass as measured."""
    qt = _qt()
    style, pt = look
    if style not in qt.QtWidgets.QStyleFactory.keys():
        pytest.fail(f"the Qt style {style!r} vanished between collection and this test")
    saved = (qapp.style().objectName(), qt.QtGui.QFont(qapp.font()))
    qapp.setStyle(qt.QtWidgets.QStyleFactory.create(style))
    if pt is not None:
        f = qt.QtGui.QFont(saved[1])
        f.setPointSizeF(pt)
        qapp.setFont(f)
    _settle(qapp)
    assert qapp.style().objectName().lower() == style.lower()
    return saved


def _restore_look(qapp, saved):
    qt = _qt()
    qapp.setStyle(qt.QtWidgets.QStyleFactory.create(saved[0]))
    qapp.setFont(saved[1])
    _settle(qapp)


def _build_host(name, qapp, monkeypatch, tmp_path):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    body, window = _HOSTS[name](qapp, monkeypatch)
    assert body.current_domain() == "acme.example"
    _settle(qapp)
    if isinstance(window, _qt().QtWidgets.QWizard):
        # the wizard's default on the 800x800 screen, whatever this host's screen is
        size = _size_of(_BUILT_ON)
        window.resize(size)
        _settle(qapp)
        assert (window.width(), window.height()) == (size.width(), size.height())
    return body, window


@pytest.fixture(params=sorted(_HOSTS))
def host(request, qapp, monkeypatch, tmp_path):
    """``(body, window)`` — the shared body on one of its real hosts, walked onto an
    added domain (the screen with BOTH checkbox tables live), shown at the host's own
    default size, under the process's default look."""
    body, window = _build_host(request.param, qapp, monkeypatch, tmp_path)
    yield body, window
    _dispose(window, qapp)


_STYLED = [(h, look) for look in _LOOKS for h in sorted(_HOSTS)]


@pytest.fixture(params=_STYLED, ids=lambda p: f"{p[0]}-{_look_id(p[1])}")
def styled_host(request, qapp, monkeypatch, tmp_path):
    """The same, built under each look in ``_LOOKS`` (#647): the style and font are on
    the application before the host is built, checked on the table itself, and
    restored afterwards — ``qapp`` outlives every test in this process."""
    name, look = request.param
    saved = _apply_look(qapp, look)
    try:
        body, window = _build_host(name, qapp, monkeypatch, tmp_path)
        style, pt = look
        assert body.table.style().objectName().lower() == style.lower()
        if pt is not None:
            assert body.table.font().pointSizeF() == pt
        yield body, window
        _dispose(window, qapp)
    finally:
        _restore_look(qapp, saved)


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
def test_the_checkbox_column_shows_the_whole_checkbox_on_every_host(styled_host):
    body, _window = styled_host
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
def test_the_old_two_letter_header_no_longer_hides_the_checkbox(styled_host, qapp):
    # THE REGRESSION ITSELF. With a content-sized column, "On" made the section
    # exactly as wide as the row's indentation, the cell zero pixels wide, and the
    # checkbox was never laid out. The production header stays "Selection" — the
    # relabel is only how this test takes the header's help away.
    body, _window = styled_host
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


def test_a_style_with_a_bigger_checkbox_widens_the_column(styled_host, qapp):
    body, window = styled_host
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


def test_every_rows_full_description_is_reachable_as_its_tooltip(host):
    """The "What it does for this domain" column elides longer descriptions at the
    default window size (#647, looked at); the whole text is reachable from the cell
    as its tooltip — on every service row and on the front-door row — and that
    tooltip is the description itself, not a shortened one."""
    body, _window = host
    mod = _mod()
    assert body._boxes, "no service row to look at"
    for slug, item in body._rows.items():
        text = item.text(mod._COL_DESC)
        assert text, slug
        assert item.toolTip(mod._COL_DESC) == text, slug
    tor_text = body._tor_item.text(mod._COL_DESC)
    assert tor_text and body._tor_item.toolTip(mod._COL_DESC) == tor_text


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


# ── 5. what is drawn, as a whole ──────────────────────────────────────────────────
def _ancestors(w):
    p = w.parentWidget()
    while p is not None:
        yield p
        p = p.parentWidget()


def test_the_bodys_widgets_follow_one_another_on_every_host(host):
    """No widget of the body is painted over another (#647, looked at: the fleet step
    laid the front-door table and the state line across the services table's lower
    rows). Each widget's top is at or below the previous one's bottom, in the layout
    they share, and the services table keeps at least its minimum height."""
    body, _window = host
    order = [body.head, body.front_door_table, body.tor_note, body.enforcement,
             body.help, body.table, body.other_head, body.other_table]
    parent = body.table.parentWidget()
    for w in order:
        assert w.parentWidget() is parent, type(w).__name__
        assert w.isVisible()
    rects = [w.geometry() for w in order]
    for above, below, w in zip(rects, rects[1:], order[1:]):
        assert below.top() >= above.bottom(), \
            f"{type(w).__name__} at y={below.top()} starts above the previous widget's " \
            f"bottom y={above.bottom()}"
    assert body.table.height() >= body.table.minimumHeight()
    # ...because the body sits in a scroll area on every host (a plain layout squeezes
    # what it cannot fit and paints the rest on top of each other)
    qt = _qt()
    assert any(isinstance(a, qt.QtWidgets.QScrollArea) for a in _ancestors(body.table)), \
        "the body is not inside a scroll area on this host"


def _subtitle_is_whole(window, must_say):
    qt = _qt()
    page = window.currentPage()
    sub = page.subTitle()
    assert sub and must_say in sub
    labels = [lab for lab in window.findChildren(qt.QtWidgets.QLabel)
              if lab.text() == sub and lab.isVisible()]
    assert len(labels) == 1, "the wizard shows the subtitle exactly once"
    lab = labels[0]
    need = (lab.heightForWidth(lab.width()) if lab.wordWrap()
            else lab.sizeHint().height())
    assert need <= lab.height() + 1, \
        f"the subtitle needs {need}px and has {lab.height()}px — it is cut off " \
        f"(window {window.width()}x{window.height()}, {lab.font().pointSizeF()} pt)"


#: The screens the subtitle is measured on: the wizard's documented real ones (1080p, a
#: 768p laptop at 125 %, a 1024x600 netbook) and the 800x800 one, whose 736 px wide
#: window is where the operator saw the earlier sentence cut off (#647) and where, at
#: 13.5 pt, the sentence it replaced is three lines again. Qt's wizard header holds
#: two lines of subtitle and clips the rest; on the 640x640 logical screen (588 px
#: wide) at 13.5 pt any sentence worth printing is three lines, so that one is out.
_SUBTITLE_SCREENS = tuple((k, _SCREENS[k]) for k in
                          ("1080p", "768p-at-125pc", "1024x600-netbook", "800x800-offscreen"))


@pytest.mark.parametrize("look", _LOOKS, ids=_look_id)
def test_the_wizard_steps_subtitle_is_whole(look, qapp, monkeypatch, tmp_path):
    """The wizard's subtitle area holds two lines; the local docker mesh step's
    subtitle and the image flow page's fit them under every look measured here, at the
    wizard's default size on each screen in ``_SUBTITLE_SCREENS`` (the local mesh one
    was three lines and cut off mid-sentence at 9 pt, #647, and again at 13.5 pt until
    it was shortened)."""
    from hugmesh_studio.gui.wizard import medium_size
    qt = _qt()
    saved = _apply_look(qapp, look)
    try:
        for name, must_say in (("local-docker-mesh", "two steps on"),
                               ("image-flow", "every domain gets its own")):
            _body, window = _build_host(name, qapp, monkeypatch, tmp_path)
            try:
                for label, (sw, sh) in _SUBTITLE_SCREENS:
                    size = medium_size(qt.QtCore.QRect(0, 0, sw, sh))
                    window.resize(size)
                    _settle(qapp)
                    assert (window.width(), window.height()) == (size.width(), size.height()), \
                        f"{name} did not take the {label} size {size.width()}x{size.height()}"
                    _subtitle_is_whole(window, must_say)
            finally:
                _dispose(window, qapp)
    finally:
        _restore_look(qapp, saved)


# ── 6. above the fold: the front door and its state line, without scrolling ───────
def _scroll_area_of(w):
    qt = _qt()
    for a in _ancestors(w):
        if isinstance(a, qt.QtWidgets.QScrollArea):
            return a
    raise AssertionError("the body is not inside a scroll area on this host")


def _span_in(viewport, w):
    """``(top, bottom)`` of ``w`` in the viewport's own coordinates — what is on
    screen is what lies between 0 and the viewport's height."""
    top = w.mapTo(viewport, _qt().QtCore.QPoint(0, 0)).y()
    return top, top + w.height()


def _last_row(table):
    last = table.topLevelItem(table.topLevelItemCount() - 1)
    while last.isExpanded() and last.childCount():
        last = last.child(last.childCount() - 1)
    return last


def _prose_of(body):
    """Every prose label of the body, in page order: the per-domain head, the front
    door's state line, the honesty banner, the lane note (hidden while it has nothing
    to say), the help, the "Not domain-scoped" head, the scope legend and the walk's
    progress line. All of them word-wrap; none may be wider than the page."""
    return (("head", body.head), ("state line", body.tor_note),
            ("banner", body.enforcement), ("lane note", body.lane_note),
            ("help", body.help), ("other head", body.other_head),
            ("legend", body.legend), ("progress line", body.remaining))


def _prose_is_readable(body, qapp, where):
    """Every prose label the body shows is readable, not only on screen: it wraps, it
    lies wholly inside the scroll viewport's WIDTH, and it is as tall as the lines it
    wraps to. The page's scroll area never shows a horizontal scrollbar, so a label
    wider than the viewport is cut at the right edge with no way to reach the rest —
    and one such label widens the content widget, so every label beside it is cut too
    (seen with the state line's word wrap off: the fold check alone stayed green). The
    content widget is therefore measured as a whole as well."""
    qt = _qt()
    sa = _scroll_area_of(body.table)
    vp = sa.viewport()
    _settle(qapp)
    content = sa.widget()
    assert content.width() <= vp.width(), \
        f"the page's content is {content.width()}px wide in a {vp.width()}px " \
        f"viewport, so its right edge is cut off ({where})"
    for name, lab in _prose_of(body):
        if not lab.isVisible():
            # the one label allowed off the page is the lane note, and only while empty
            assert name == "lane note" and lab.text() == "", f"the {name} is hidden"
            continue
        assert lab.text(), f"the {name} is on the page with nothing to say ({where})"
        assert lab.wordWrap(), f"the {name} does not wrap ({where})"
        left = lab.mapTo(vp, qt.QtCore.QPoint(0, 0)).x()
        right = left + lab.width()
        assert 0 <= left and right <= vp.width(), \
            f"the {name} spans x={left}..{right} in a {vp.width()}px wide viewport " \
            f"({where})"
        need = lab.heightForWidth(lab.width())
        assert need <= lab.height() + 1, \
            f"the {name} needs {need}px for its text and has {lab.height()}px ({where})"


def _front_door_above_the_fold(body, qapp, where):
    sa = _scroll_area_of(body.table)
    vp = sa.viewport()
    for ticked in (False, True):
        body._tor_box.setChecked(ticked)
        _settle(qapp)
        assert sa.verticalScrollBar().value() == 0, "the page had to scroll"
        assert body.tor_note.text().startswith("Tor front door: ")
        assert ("on — " in body.tor_note.text()
                or "ticked — " in body.tor_note.text()) is ticked
        for name, w in (("front-door checkbox", body._tor_box),
                        ("front-door table", body.front_door_table),
                        ("state line", body.tor_note)):
            assert w.isVisible(), name
            top, bottom = _span_in(vp, w)
            assert top >= 0 and bottom <= vp.height(), \
                f"the {name} spans y={top}..{bottom} in a {vp.height()}px viewport " \
                f"({'ticked' if ticked else 'unticked'}, {where})"
        # ...and readable across: the state line is longest ticked, and every other
        # prose label of the body is measured with it
        _prose_is_readable(body, qapp, f"{'ticked' if ticked else 'unticked'}, {where}")
    # the caption: directly under its table, no gap
    assert _span_in(vp, body.tor_note)[0] == _span_in(vp, body.front_door_table)[1]


def test_the_front_door_and_its_state_line_are_above_the_fold_on_every_host(
        styled_host, qapp):
    """On every host, under every look, at the host's default window size and at every
    size in ``_SIZES``: the front-door checkbox, its table and the state line under it
    lie wholly inside the page's scroll viewport with the page not scrolled — with the
    front door unticked and, since that is the longer line, ticked — and every prose
    label of the body is readable across (wrapped, inside the viewport's width, tall
    enough for its lines; ``_prose_is_readable``).

    A host's window takes a size no smaller than its own floor, and the fold is then
    measured at the size it really took: every host scrolls (the fleet window's steps
    each sit in their own scroll area since the post-merge fix of #645, so its floor
    is the step title plus the Back / Next row, no longer its tallest and widest
    step), and what is asserted is that any clamp IS the window's own minimum."""
    body, window = styled_host
    _front_door_above_the_fold(body, qapp, f"as built, {window.width()}x{window.height()}")
    for label, _screen in _SIZES:
        size = _size_of(label)
        window.resize(size)
        _settle(qapp)
        floor = window.minimumSize()
        took = (max(size.width(), floor.width()), max(size.height(), floor.height()))
        assert (window.width(), window.height()) == took, \
            f"asked {size.width()}x{size.height()}, floor {floor.width()}x{floor.height()}"
        _front_door_above_the_fold(body, qapp, f"{label}: {took[0]}x{took[1]}")


def test_the_readability_check_sees_a_label_cut_at_the_right_edge(host, qapp):
    """The control for ``_prose_is_readable``, on the live page: with the state line's
    word wrap turned off (the change that left the fold check green while the page was
    unreadable) the check names the state line; with one label given a fixed width
    past the viewport it names that label; and put back, the page passes again."""
    body, _window = host
    body._tor_box.setChecked(True)
    _settle(qapp)
    _prose_is_readable(body, qapp, "as built")
    body.tor_note.setWordWrap(False)
    with pytest.raises(AssertionError, match="state line"):
        _prose_is_readable(body, qapp, "state line unwrapped")
    body.tor_note.setWordWrap(True)
    _settle(qapp)
    _prose_is_readable(body, qapp, "state line wrapped again")
    vp = _scroll_area_of(body.table).viewport()
    body.help.setMinimumWidth(vp.width() + 200)
    with pytest.raises(AssertionError, match="help|content"):
        _prose_is_readable(body, qapp, "help too wide")
    body.help.setMinimumWidth(0)
    _settle(qapp)
    _prose_is_readable(body, qapp, "help free again")


def test_the_front_door_is_laid_out_above_the_services_on_both_faces(host):
    """The order that keeps the front door on screen (#647, looked at at 120 and 144
    font DPI): on the GUI the front-door table and its state line come right after the
    domain navigation and before the honesty banner, the help and the catalogue; the
    TUI screen prints the same order (decision 71 = A — no new parity exemption)."""
    body, _window = host
    gui = [body.prev_btn, body.front_door_table, body.tor_note, body.enforcement,
           body.help, body.table]
    tops = [w.geometry().top() for w in gui]
    assert tops == sorted(tops) and len(set(tops)) == len(tops), tops
    assert body.front_door_table.geometry().bottom() <= body.table.geometry().top()
    # the text face, on the same kind of domain (an added one with a front door)
    md = LocalMeshDomains(domains=[Domain(name="mesh.example"), Domain(name="b.example")],
                          own_name="mesh.example")
    screen = tui_step.DomainServicesScreen(cfg_of=lambda j: md, lane_note="LANE")
    j = journey.Journey(".")
    screen.enter(j)
    screen.feed(j, "n")
    lines = screen.lines(j)

    def at(pred):
        hits = [i for i, ln in enumerate(lines) if pred(ln)]
        assert len(hits) == 1, hits
        return hits[0]
    front_door = at(lambda ln: ln.split()[:2] == ["cmd", "selection"])
    state = at(lambda ln: ln.startswith("Tor front door: "))
    banner = at(lambda ln: ln == tui_step.ENFORCEMENT_NOTE)
    lane = at(lambda ln: ln == "LANE")
    services = at(lambda ln: ln.split()[:2] == ["#", "selection"])
    # title, blank, then the table's header, rule and one row, then the state line
    assert front_door == 2 and state == front_door + 3
    assert front_door < state < banner < lane < services
    assert lines[services - 2].startswith("The services THIS domain provides")


def test_each_checkbox_table_is_exactly_as_tall_as_its_rows(styled_host):
    """No blank rows under the last one, no inner scrollbar hiding it: each of the
    two checkbox tables is fixed at its header plus its rows plus its frame, and its
    last row is drawn inside its own viewport."""
    body, _window = styled_host
    mod = _mod()
    for t in (body.table, body.front_door_table):
        assert t.height() == mod.table_content_height(t)
        assert t.minimumHeight() == t.maximumHeight() == t.height()
        assert not t.verticalScrollBar().isVisible()
        assert t.visualItemRect(_last_row(t)).bottom() < t.viewport().height()
    assert body.table.topLevelItemCount() >= 3 and body._boxes    # rows to speak of


def test_the_tables_grow_with_a_bigger_checkbox_and_shrink_with_a_folded_group(
        host, qapp):
    """The height follows the rows the way the width follows the checkbox: a style
    with a taller checkbox makes the rows taller and the tables grow to match; a
    folded group takes its rows off screen and the table shrinks to what is left."""
    body, window = host
    mod = _mod()
    before = {t: t.height() for t in (body.table, body.front_door_table)}
    window.setStyleSheet("QCheckBox::indicator { width: 34px; height: 34px; }")
    _settle(qapp)
    for t, was in before.items():
        assert _indicator_width(body._tor_box) >= 34      # the style really changed
        assert t.height() > was, type(t).__name__
        assert t.height() == mod.table_content_height(t)
    group = body.table.topLevelItem(0)
    assert group.childCount() > 0
    tall = body.table.height()
    group.setExpanded(False)
    _settle(qapp)
    assert body.table.height() == mod.table_content_height(body.table) < tall
    group.setExpanded(True)
    _settle(qapp)
    assert body.table.height() == tall


def test_the_tables_refit_when_the_walk_changes_the_rows(qapp, monkeypatch, tmp_path):
    """Two domains, one carrying a slug this catalogue does not offer: its screen has
    one group and one row more ("From your config"), so the services table must be
    taller there and shorter again on the way back — the REBUILD re-fits the height,
    not only the first show or a style change (nothing else resizes the table when
    the walk moves between domains)."""
    from hugmesh_studio.gui.pages.domain_services import DomainServicesWidget
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    mod = _mod()
    w = DomainServicesWidget()
    w.show()
    w.load(LocalMeshDomains(domains=[Domain(name="mesh.example"),
                                     Domain(name="plain.example"),
                                     Domain(name="extra.example",
                                            optional_services=["kept-from-config"])],
                            own_name="mesh.example"))
    w._step(1)
    _settle(qapp)
    assert w.current_domain() == "plain.example"
    plain, plain_groups = w.table.height(), w.table.topLevelItemCount()
    assert plain == mod.table_content_height(w.table)
    w._step(1)
    _settle(qapp)
    assert w.current_domain() == "extra.example"
    assert "kept-from-config" in w._boxes
    assert w.table.topLevelItemCount() == plain_groups + 1
    extra = w.table.height()
    assert extra == mod.table_content_height(w.table) > plain
    w._step(-1)
    _settle(qapp)
    assert w.current_domain() == "plain.example"
    assert w.table.height() == mod.table_content_height(w.table) == plain
    _dispose(w, qapp)


def test_a_walk_with_no_domains_leaves_no_blank_tables(qapp, monkeypatch, tmp_path):
    """The cleared screen ("No domains to configure.") re-fits both tables too: a
    table emptied by the walk keeps no rows' worth of blank height."""
    from hugmesh_studio.gui.pages.domain_services import DomainServicesWidget
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    mod = _mod()
    w = DomainServicesWidget()
    w.show()
    w.load(LocalMeshDomains(domains=[Domain(name="mesh.example"),
                                     Domain(name="b.example")],
                            own_name="mesh.example"))
    w._step(1)
    _settle(qapp)
    assert w.current_domain() == "b.example" and w._boxes
    tall = w.table.height()
    assert tall == mod.table_content_height(w.table)
    w.reload(LocalMeshDomains(domains=[], own_name=""))
    _settle(qapp)
    assert w.current_domain() == "" and w.head.text() == "No domains to configure."
    for t in (w.table, w.front_door_table):
        assert t.topLevelItemCount() == 0
        assert t.height() == mod.table_content_height(t) < tall
    _dispose(w, qapp)

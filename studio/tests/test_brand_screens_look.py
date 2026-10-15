"""What a person SEES on the superbrand drop-down, the design step and the Brand
settings tabs (hugmesh-generator#654, D8, D9; the #647 rule: 193 green tests once said a
control existed that the operator could not see).

For every new control: scrolled to, it is inside its viewport, wide enough for its text
and at least 24 px high when it is a button, a drop-down or a box; no row overlaps
another; a sentence draws all of its words; and no page asks for more width than its
window — at the two sizes the Studio opens at (1040x780 and 736x736), under two Qt styles,
at the default font and at 8 pt, plus the Fleet window at its own 760x700.

    HUGMESH_LOOK_SHOTS=<dir> python -m pytest tests/test_brand_screens_look.py

saves a PNG of each state so a reviewer can open what the test measured.

WHY A CHILD INTERPRETER, and why these are ``test_geom_*`` and not ``test_look_*``:
switching the application style in a process that already ran other wizard tests takes
minutes (tests/_look.py says why), so the geometry tests skip in an ordinary run and
the one test at the bottom starts them in a fresh interpreter. They are not named
``test_look_*`` because tests/test_look.py owns that prefix and a fixed list of files.
"""
import os
import re
import subprocess
import sys
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from _look import (LOOK_CHILD_ENV, assert_whole, child_only, looking,        # noqa: E402
                   settle, viewport_of)

from hugmesh_studio.core.config import DOMAIN_IDP_OWN, Domain, ImageConfig    # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                           # noqa: E402
from hugmesh_studio.gui.pages import domain_services as ds_mod                # noqa: E402
from hugmesh_studio.gui.pages import domains as dom_mod                       # noqa: E402
from hugmesh_studio.gui.pages import fleet as fleet_mod                       # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtWidgets                           # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
STUDIO_ROOT = os.path.dirname(HERE)
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

SIZES = [(1040, 780), (736, 736)]
CASES = [(style, pt, size) for size in SIZES for style in ("Fusion", "Breeze")
         for pt in (8.0, 9.0)]
IDS = [f"{style.lower()}-{pt:g}pt-{w}x{h}" for style, pt, (w, h) in CASES]
MIN_CLICK_HEIGHT = 24


@pytest.fixture(scope="module")
def qapp():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication(
        ["hugmesh-studio-brand-screens-look"])


# ── measuring ────────────────────────────────────────────────────────────────────────
def _scroll_to(page, widget, qapp):
    """Put ``widget`` 40 px below the top of the page's scroll area."""
    sa = getattr(page, "_content_scroll", None)
    if sa is None:
        return
    y = widget.mapTo(sa.widget(), QtCore.QPoint(0, 0)).y()
    sa.verticalScrollBar().setValue(max(0, y - 40))
    settle(qapp, 2)


def _inside(page, widget, what):
    vp = viewport_of(page)
    tl = vp.mapFromGlobal(widget.mapToGlobal(QtCore.QPoint(0, 0)))
    br = vp.mapFromGlobal(widget.mapToGlobal(QtCore.QPoint(widget.width() - 1,
                                                          widget.height() - 1)))
    assert tl.x() >= 0 and br.x() < vp.width(), \
        f"{what}: spans x {tl.x()}..{br.x()} of a {vp.width()}px viewport"
    assert tl.y() >= 0 and br.y() < vp.height(), \
        f"{what}: spans y {tl.y()}..{br.y()} of a {vp.height()}px viewport after scrolling to it"


def _drawn(page, widget, what, qapp, *, click=False):
    """Scrolled to: visible, inside the viewport, and — for something a person clicks or
    types in — at least 24 px high and wide enough for its own text."""
    _scroll_to(page, widget, qapp)
    assert widget.isVisible(), f"{what} is not visible"
    _inside(page, widget, what)
    if click:
        assert widget.height() >= MIN_CLICK_HEIGHT, f"{what} is {widget.height()}px tall"
    if isinstance(widget, QtWidgets.QAbstractButton) and widget.text():
        need = widget.fontMetrics().horizontalAdvance(widget.text().replace("&", "")) + 12
        assert widget.width() >= need - 2, \
            f"{what}: needs {need}px for {widget.text()!r}, has {widget.width()}px"
    if isinstance(widget, (QtWidgets.QLineEdit, QtWidgets.QComboBox)):
        assert widget.width() >= 90, f"{what} is {widget.width()}px wide"


def _page_fits(page, what, ignore=()):
    """No visible control reaches past the right edge of its viewport (#661)."""
    vp = viewport_of(page)
    over = []
    for w in page.findChildren(QtWidgets.QWidget):
        if not w.isVisible() or not vp.isAncestorOf(w) or any(
                w is i or i.isAncestorOf(w) for i in ignore):
            continue
        right = vp.mapFromGlobal(w.mapToGlobal(w.rect().topRight())).x() + 1
        if right > vp.width():
            over.append((right - vp.width(), type(w).__name__,
                         (getattr(w, "text", lambda: "")() or "")[:40]))
    assert not over, f"{what}: {len(over)} control(s) past the {vp.width()}px viewport: " + \
        "; ".join(f"{n} {t!r} by {b}px" for b, n, t in sorted(over, reverse=True)[:4])


def _sentences_whole(page, root, what, qapp, skip=()):
    for lab in root.findChildren(QtWidgets.QLabel):
        if not lab.isVisibleTo(page) or not lab.text() or not lab.wordWrap():
            continue
        if any(lab is s or s.isAncestorOf(lab) for s in skip):
            continue
        _scroll_to(page, lab, qapp)
        assert_whole(lab, f"{what}: {lab.text()[:48]!r}")


def _snap(widget, tag, style, pt, size):
    out = os.environ.get("HUGMESH_LOOK_SHOTS", "")
    if not out:
        return ""
    os.makedirs(out, exist_ok=True)
    path = os.path.join(out, f"brand-screens-{tag}-{style.lower()}-{pt:g}pt-"
                             f"{size[0]}x{size[1]}.png")
    widget.grab().save(path)
    return path


def _open(page, qapp, size):
    page.resize(*size)
    page.show()
    settle(qapp, 4)


def _mesh_cfg(**kw):
    cfg = ImageConfig()
    cfg.mode = "mesh"
    cfg.domains = [Domain(name="shop.example", title="Shop"),
                   Domain(name="blog.example", title="Blog", idp=DOMAIN_IDP_OWN)]
    for k, v in kw.items():
        setattr(cfg, k, v)
    return cfg


def _wiz(cfg=None):
    return SimpleNamespace(cfg=cfg or _mesh_cfg(), generator_dir=GENERATOR_DIR)


# ── the Branding page: the drop-down and the design step ─────────────────────────────
@pytest.mark.parametrize(("style", "pt", "size"), CASES, ids=IDS)
def test_geom_the_branding_pages_drop_down_and_design_are_drawn_whole(qapp, style, pt, size):
    child_only()
    with looking(qapp, style, pt):
        page = wizard_mod.BrandingPage(_wiz())
        try:
            page.initializePage()
            _open(page, qapp, size)
            what = f"branding {style} {pt:g}pt {size[0]}x{size[1]}"
            sb = page.superbrand
            _page_fits(page, what, ignore=(sb.look_editor or page,))
            _drawn(page, sb.picker.combo, f"{what}: the drop-down", qapp, click=True)
            assert sb.picker.combo.itemText(0) == "Create a new superbrand"
            assert sb.picker.combo.fontMetrics().horizontalAdvance(
                "Create a new superbrand") <= sb.picker.combo.width(), \
                f"{what}: the first item does not fit the drop-down"
            for f, le in sb.fields.items():
                _drawn(page, le, f"{what}: the {f} box", qapp, click=True)
            _drawn(page, sb.keep_btn, f"{what}: Keep this design", qapp, click=True)
            _drawn(page, sb.keep_name, f"{what}: the design name box", qapp, click=True)
            _sentences_whole(page, sb, what, qapp, skip=(sb.look_editor,)
                             if sb.look_editor else ())
            _snap(page, "branding-design", style, pt, size)
            # picking an existing choice swaps the design for a summary and Change it
            sb.picker.select("profile:example")
            settle(qapp, 3)
            _drawn(page, sb.picker.change_btn, f"{what}: Change it", qapp, click=True)
            assert sb.design.isHidden()
            _sentences_whole(page, sb.picker, what, qapp)
            _snap(page, "branding-summary", style, pt, size)
        finally:
            page.close()
            page.deleteLater()
            settle(qapp)


@pytest.mark.parametrize(("style", "pt", "size"), CASES, ids=IDS)
def test_geom_an_unaffiliated_branding_page_says_why_and_keeps_the_look(qapp, style, pt, size):
    child_only()
    with looking(qapp, style, pt):
        page = wizard_mod.BrandingPage(_wiz(_mesh_cfg(unaffiliated=True)))
        try:
            page.initializePage()
            _open(page, qapp, size)
            what = f"unaffiliated branding {style} {pt:g}pt {size[0]}x{size[1]}"
            sb = page.superbrand
            assert not sb.picker.combo.isEnabled()
            _drawn(page, sb.picker.note, f"{what}: the reason beside the drop-down", qapp)
            _drawn(page, sb.reason, f"{what}: the reason under the design", qapp)
            assert_whole(sb.picker.note, f"{what}: the picker's reason")
            assert_whole(sb.reason, f"{what}: the design's reason")
            assert sb.identity_box.isHidden()
            _snap(page, "branding-unaffiliated", style, pt, size)
        finally:
            page.close()
            page.deleteLater()
            settle(qapp)


# ── the Brand settings tabs ──────────────────────────────────────────────────────────
def _tabs_page(qapp, size):
    page = ds_mod.DomainServicesPage(_wiz())
    page.initializePage()
    _open(page, qapp, size)
    return page


@pytest.mark.parametrize(("style", "pt", "size"), CASES, ids=IDS)
def test_geom_every_tab_of_the_brand_screen_is_drawn_whole(qapp, style, pt, size):
    child_only()
    with looking(qapp, style, pt):
        page = _tabs_page(qapp, size)
        try:
            what = f"brand tabs {style} {pt:g}pt {size[0]}x{size[1]}"
            tabs = page.brand_tabs
            bar = tabs.tabBar()
            _drawn(page, bar, f"{what}: the tab bar", qapp, click=True)
            # every tab title is drawn whole (the bar does not elide them)
            for i in range(tabs.count()):
                r = bar.tabRect(i)
                need = bar.fontMetrics().horizontalAdvance(tabs.tabText(i))
                assert r.width() >= need, f"{what}: tab {tabs.tabText(i)!r} is {r.width()}px"
                assert r.height() >= MIN_CLICK_HEIGHT - 4
            page._step(1)                                     # a brand, not the superbrand
            for title in ("Identity", "Ways to reach it", "Services", "Look"):
                tabs.open_tab(title)
                settle(qapp, 3)
                t = f"{what} / {title}"
                _page_fits(page, t, ignore=(tabs.look_editor,) if tabs.look_editor else ())
                cur = tabs.currentWidget()                 # None on the Services tab
                if title in ("Identity", "Ways to reach it"):
                    # the short tabs are as tall as their content, whole on screen
                    _drawn(page, cur, f"{t}: the tab", qapp)
                    assert cur.height() <= 420, f"{t}: a short tab is {cur.height()}px tall"
                _sentences_whole(page, cur if cur is not None else page.table.parentWidget(),
                                 t, qapp,
                                 skip=(tabs.look_editor,) if tabs.look_editor else ())
                if title == "Ways to reach it":
                    _drawn(page, tabs.ways_btn, f"{t}: the button", qapp, click=True)
                    assert "Set up ways to reach this brand" == tabs.ways_btn.text()
                if title == "Identity":
                    for lab in (tabs.identity_form.itemAt(i).widget()
                                for i in range(tabs.identity_form.count())):
                        if lab is not None and lab.isVisible():
                            assert lab.height() >= 12 and lab.width() >= 30
                _snap(page, "tab-" + title.split()[0].lower(), style, pt, size)
        finally:
            page.close()
            page.deleteLater()
            settle(qapp)


@pytest.mark.parametrize(("style", "pt", "size"), CASES, ids=IDS)
def test_geom_the_services_tab_still_holds_what_it_held_above_the_fold(qapp, style, pt, size):
    """The tab bar adds a row above the services: the front door and its state line (the
    #647 rule) must still be on screen at the size the Studio opens at."""
    child_only()
    with looking(qapp, style, pt):
        page = _tabs_page(qapp, size)
        try:
            what = f"services tab {style} {pt:g}pt {size[0]}x{size[1]}"
            assert page.brand_tabs.currentIndex() == 2
            for w, name in ((page.brand_tabs.tabBar(), "the tab bar"),
                            (page.front_door_table, "the front door row"),
                            (page.tor_note, "the front door's state line")):
                _scroll_to(page, w, qapp)
                assert w.isVisible(), f"{what}: {name} not visible"
            page._content_scroll.verticalScrollBar().setValue(0)
            settle(qapp, 2)
            vp = viewport_of(page)
            bottom = vp.mapFromGlobal(page.tor_note.mapToGlobal(
                page.tor_note.rect().bottomLeft())).y()
            assert bottom <= vp.height(), \
                f"{what}: the front door's state line ends at {bottom}px of {vp.height()}px"
            _snap(page, "tab-services", style, pt, size)
        finally:
            page.close()
            page.deleteLater()
            settle(qapp)


@pytest.mark.parametrize(("style", "pt", "size"), CASES, ids=IDS)
def test_geom_the_brands_tables_summaries_are_drawn_whole(qapp, style, pt, size):
    child_only()
    with looking(qapp, style, pt):
        w = _wiz()
        w.currentIdChanged = SimpleNamespace(connect=lambda *_: None)
        w.currentPage = lambda: None
        page = dom_mod.DomainsPage(w)
        try:
            page.initializePage()
            _open(page, qapp, size)
            what = f"brands table {style} {pt:g}pt {size[0]}x{size[1]}"
            box = page.summary_box
            _scroll_to(page, box, qapp)
            assert box.isVisible()
            _inside(page, box, f"{what}: the summaries")
            assert_whole(box, f"{what}: the summaries")
            assert box.text().count("<br>") >= 3, "one line per row plus the heading"
            _page_fits(page, what)
            _snap(page, "brands-table", style, pt, size)
        finally:
            page.close()
            page.deleteLater()
            settle(qapp)


# ── the Fleet window ─────────────────────────────────────────────────────────────────
@pytest.mark.parametrize(("style", "pt"), [("Fusion", None), ("Breeze", None),
                                           ("Fusion", 8.0), ("Breeze", 8.0)])
def test_geom_the_fleet_window_has_no_sideways_scroll_on_any_step(qapp, style, pt):
    """The window opens at 760x700 and scrolled 103 px sideways on every step (the
    2026-10-01 audit; reproduced on origin/main): the Tor tick-box's text was 765 px
    wide. Every step, the new Superbrand step included, must fit its viewport."""
    child_only()
    with looking(qapp, style, pt):
        win = fleet_mod.FleetWindow(GENERATOR_DIR)
        try:
            win.resize(760, 700)
            win.show()
            settle(qapp, 4)
            page = win.page
            page.cluster_domain.setText("mesh.example")
            scroll = win.findChild(QtWidgets.QScrollArea)
            what = f"fleet {style} {pt or 'default'}"
            for i in range(fleet_mod.STEP_REVIEW):
                page._goto(i)
                settle(qapp, 4)
                title = fleet_mod._STEP_TITLES[i]
                assert scroll.horizontalScrollBar().maximum() == 0, (
                    f"{what} / {title}: the window scrolls "
                    f"{scroll.horizontalScrollBar().maximum()}px sideways")
                inner = page.stack.currentWidget().findChild(QtWidgets.QScrollArea)
                if inner is not None:
                    assert inner.horizontalScrollBar().maximum() == 0, f"{what} / {title}"
                if i == fleet_mod.STEP_SHARED:
                    for w in (page.brand_picker.combo, page.with_tor):
                        assert w.isVisible()
                    assert page.brand_picker.combo.height() >= MIN_CLICK_HEIGHT
                    assert page.brand_picker.item_labels()[0] == "Create a new superbrand"
                _snap(win, f"fleet-{i}-{title.split()[0].lower()}", style, pt or 0, (760, 700))
        finally:
            win.close()
            win.deleteLater()
            settle(qapp)


@pytest.mark.parametrize(("style", "pt"), [("Fusion", None), ("Breeze", 8.0)])
def test_geom_the_fleet_windows_tabs_fit_760_by_700(qapp, style, pt):
    child_only()
    with looking(qapp, style, pt):
        win = fleet_mod.FleetWindow(GENERATOR_DIR)
        try:
            win.resize(760, 700)
            win.show()
            settle(qapp, 4)
            page = win.page
            page.cluster_domain.setText("mesh.example")
            page._goto(fleet_mod.STEP_DOMAINS)
            page.domains_table._add("shop.example", "Shop")
            page._next()
            page._goto(fleet_mod.STEP_DOMAIN_SERVICES)
            settle(qapp, 4)
            scroll = win.findChild(QtWidgets.QScrollArea)
            tabs = page.domain_services.brand_tabs
            what = f"fleet tabs {style} {pt or 'default'}"
            page.domain_services._step(1)
            for title in ("Identity", "Look", "Services", "Ways to reach it"):
                tabs.open_tab(title)
                settle(qapp, 4)
                assert scroll.horizontalScrollBar().maximum() == 0, (
                    f"{what} / {title}: {scroll.horizontalScrollBar().maximum()}px sideways")
                bar = tabs.tabBar()
                assert bar.isVisible() and bar.height() >= MIN_CLICK_HEIGHT - 4
                for i in range(tabs.count()):
                    assert bar.tabRect(i).right() <= bar.width(), \
                        f"{what}: tab {i} is cut off by the bar"
                _snap(win, f"fleet-tab-{title.split()[0].lower()}", style, pt or 0, (760, 700))
        finally:
            win.close()
            win.deleteLater()
            settle(qapp)


# ── the parent: start the geometry tests where they can run ──────────────────────────
def _child_verdict(returncode, lines):
    if returncode != 0:
        return f"the child exited {returncode}"
    summary = next((ln for ln in reversed(lines) if " passed" in ln), "")
    m = re.search(r"(\d+) passed", summary)
    if not m or int(m.group(1)) == 0:
        return "the child ran no geometry case that passed"
    return ""


def test_a_geometry_run_needs_a_clean_exit_and_at_least_one_passing_case():
    assert _child_verdict(0, ["....", "30 passed, 2 skipped in 9.1s"]) == ""
    assert _child_verdict(1, ["1 failed, 15 passed in 9.1s"]) != ""
    assert _child_verdict(0, ["16 skipped in 0.3s"]) != ""
    assert _child_verdict(0, []) != ""


def test_the_brand_screens_are_drawn_whole_in_a_fresh_interpreter():
    if os.environ.get(LOOK_CHILD_ENV) == "1":
        pytest.skip("this is the child interpreter; the parent runs this test")
    env = dict(os.environ)
    env[LOOK_CHILD_ENV] = "1"
    proc = subprocess.run(
        [sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider",
         "-k", "test_geom_", "-rs", os.path.join(HERE, os.path.basename(__file__))],
        cwd=STUDIO_ROOT, env=env, capture_output=True, text=True, timeout=1500)
    lines = [ln for ln in (proc.stdout + proc.stderr).splitlines()
             if "propagateSizeHints" not in ln]
    problem = _child_verdict(proc.returncode, lines)
    assert not problem, f"{problem}:\n" + "\n".join(lines[-60:])

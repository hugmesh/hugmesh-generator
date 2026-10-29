"""What a person SEES on the Docker route's ‘Environment and brand’ step now that the
drop-down and the design are on it (hugmesh-generator#654, D8; the #647 rule: 193 green
tests once said a control existed that the operator could not see).

For every new control: scrolled to, it is inside its viewport, wide enough for its text and
at least 24 px high when a person clicks or types in it; no two rows overlap; every sentence
draws all of its words; a long design name does not widen the drop-down past the page; and
the page asks for no more width than its window — at the two sizes the Studio opens at
(1040x780 and 736x736), under two Qt styles, at 8 and 9 pt.

    HUGMESH_LOOK_SHOTS=<dir> python -m pytest tests/test_brand_docker_route_look.py

saves a PNG of each state so a reviewer can open what the test measured.

WHY A CHILD INTERPRETER: switching the application style in a process that already ran
other wizard tests takes minutes (tests/_look.py says why), so the ``test_geom_*`` tests skip
in an ordinary run and the one test at the bottom starts them in a fresh interpreter.
"""
import os
import subprocess
import sys
import types

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from _look import (LOOK_CHILD_ENV, assert_whole, child_only, looking,          # noqa: E402
                   settle, viewport_of)

from hugmesh_studio.core import brand_model                                    # noqa: E402
from hugmesh_studio.gui.pages import localmesh as lm_mod                       # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtWidgets                            # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
STUDIO_ROOT = os.path.dirname(HERE)
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

SIZES = [(1040, 780), (736, 736)]
CASES = [(style, pt, size) for size in SIZES for style in ("Fusion", "Breeze")
         for pt in (8.0, 9.0)]
IDS = [f"{style.lower()}-{pt:g}pt-{w}x{h}" for style, pt, (w, h) in CASES]
MIN_CLICK_HEIGHT = 24
LONG_NAME = "a-design-with-a-very-long-name-indeed"       # 37 characters, a legal slug


@pytest.fixture(scope="module")
def qapp():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication(
        ["hugmesh-studio-docker-brand-look"])


@pytest.fixture(autouse=True)
def _state(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    brand_model.save_design(LONG_NAME, brand_model.Superbrand(title="A long one"))


# ── measuring (the same rules tests/test_brand_screens_look.py applies) ───────────────
def _scroll_to(page, widget, qapp):
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


def _no_overlap(widgets, what):
    rects = []
    for w in widgets:
        if w is None or not w.isVisible():
            continue
        tl = w.mapToGlobal(QtCore.QPoint(0, 0))
        rects.append((QtCore.QRect(tl, w.size()), type(w).__name__,
                      (getattr(w, "text", lambda: "")() or w.objectName())[:30]))
    for i, (a, na, ta) in enumerate(rects):
        for b, nb, tb in rects[i + 1:]:
            inter = a.intersected(b)
            assert inter.isEmpty() or (inter.width() <= 1 or inter.height() <= 1), \
                f"{what}: {na} {ta!r} {a.getRect()} overlaps {nb} {tb!r} {b.getRect()}"


def _page_fits(page, what, ignore=()):
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


def _snap(page, tag, style, pt, size):
    out = os.environ.get("HUGMESH_LOOK_SHOTS", "")
    if not out:
        return ""
    os.makedirs(out, exist_ok=True)
    path = os.path.join(out, f"docker-brand-{tag}-{style.lower()}-{pt:g}pt-"
                             f"{size[0]}x{size[1]}.png")
    page.grab().save(path)
    return path


def _env_step(qapp, size):
    """The ‘Environment and brand’ step as the wizard draws it, at ``size``."""
    shim = types.SimpleNamespace(generator_dir=GENERATOR_DIR, localmesh_selected=True,
                                 localmesh_join_selected=False)
    ctl = lm_mod.LocalMeshPage(shim)
    wiz = types.SimpleNamespace(generator_dir=GENERATOR_DIR, localmesh_selected=True,
                                localmesh_join_selected=False, localmesh_page=ctl)
    page = lm_mod.LocalMeshEnvPage(wiz)
    page.resize(*size)
    page.show()
    page.initializePage()
    settle(qapp, 4)
    return page, ctl


def _close(page, ctl, qapp):
    page.close()
    ctl.close()
    page.deleteLater()
    ctl.deleteLater()
    settle(qapp)


@pytest.mark.parametrize(("style", "pt", "size"), CASES, ids=IDS)
def test_geom_the_default_design_is_drawn_whole(qapp, style, pt, size):
    child_only()
    with looking(qapp, style, pt):
        page, ctl = _env_step(qapp, size)
        try:
            what = f"docker brand design {style} {pt:g}pt {size[0]}x{size[1]}"
            pick, sb = ctl.brand_picker, ctl.superbrand_design
            _page_fits(page, what, ignore=(sb.look_editor or page,))
            # the drop-down: first item is the default, drawn whole, clickable
            _drawn(page, pick.combo, f"{what}: the drop-down", qapp, click=True)
            assert pick.combo.itemText(0) == "Create a new superbrand"
            assert pick.combo.currentIndex() == 0
            assert pick.combo.fontMetrics().horizontalAdvance(
                "Create a new superbrand") <= pick.combo.width(), \
                f"{what}: the first item does not fit the drop-down"
            # a long design name elides inside the drop-down instead of widening the page
            assert any(LONG_NAME in t for t in pick.item_labels())
            vp = viewport_of(page)
            assert pick.combo.width() <= vp.width(), \
                f"{what}: the drop-down is {pick.combo.width()}px in a {vp.width()}px page"
            # the design under it
            assert sb.design.isVisibleTo(page), f"{what}: the design is not shown"
            for f, le in sb.fields.items():
                _drawn(page, le, f"{what}: the {f} box", qapp, click=True)
            assert not sb.fields["public_name"].isEnabled()
            assert sb.fields["public_name"].placeholderText()
            _drawn(page, sb.keep_btn, f"{what}: Keep this design", qapp, click=True)
            _drawn(page, ctl.brand_effect_note, f"{what}: what this saves", qapp)
            assert_whole(ctl.brand_effect_note, f"{what}: what this saves")
            _no_overlap([pick.combo, pick.caption, *sb.fields.values(), sb.keep_name,
                         sb.keep_btn, ctl.superadmin], what)
            _sentences_whole(page, ctl.sections["env"], what, qapp,
                             skip=(sb.look_editor,) if sb.look_editor else ())
            # the account row and the environment cards are still where they were (the
            # superadmin box is the page's own, 22 px at 8 pt since before this change:
            # only that it is drawn is pinned here)
            _drawn(page, ctl.superadmin, f"{what}: the superadmin box", qapp)
            _drawn(page, ctl.env_test, f"{what}: the test card", qapp)
            _snap(page, "design", style, pt, size)
        finally:
            _close(page, ctl, qapp)


@pytest.mark.parametrize(("style", "pt", "size"), CASES, ids=IDS)
def test_geom_an_existing_profile_shows_a_summary_and_a_clickable_change_it(qapp, style, pt,
                                                                            size):
    child_only()
    with looking(qapp, style, pt):
        page, ctl = _env_step(qapp, size)
        try:
            what = f"docker brand summary {style} {pt:g}pt {size[0]}x{size[1]}"
            pick, sb = ctl.brand_picker, ctl.superbrand_design
            pick.select("profile:example")
            settle(qapp, 3)
            assert sb.design.isHidden(), f"{what}: the design stayed open"
            _drawn(page, pick.change_btn, f"{what}: Change it", qapp, click=True)
            assert pick.change_btn.text() == "Change it"
            _scroll_to(page, pick.summary, qapp)
            assert pick.summary.isVisible()
            _no_overlap([pick.combo, pick.summary, pick.change_btn], what)
            _page_fits(page, what, ignore=(sb.look_editor or page,))
            _sentences_whole(page, pick, what, qapp)
            _snap(page, "summary", style, pt, size)
            # one click on Change it opens the design again, drawn whole
            pick.change_btn.click()
            settle(qapp, 3)
            assert sb.design.isVisibleTo(page), f"{what}: Change it did not open the design"
            _drawn(page, sb.fields["id"], f"{what}: the id box after Change it", qapp,
                   click=True)
        finally:
            _close(page, ctl, qapp)


@pytest.mark.parametrize(("style", "pt", "size"), CASES, ids=IDS)
def test_geom_a_refused_id_is_drawn_whole_beside_the_boxes(qapp, style, pt, size):
    child_only()
    with looking(qapp, style, pt):
        page, ctl = _env_step(qapp, size)
        try:
            what = f"docker brand refusal {style} {pt:g}pt {size[0]}x{size[1]}"
            sb = ctl.superbrand_design
            sb.fields["id"].setText("Not A Slug")
            sb.fields["id"].editingFinished.emit()
            settle(qapp, 3)
            _drawn(page, sb.note, f"{what}: the refusal", qapp)
            assert_whole(sb.note, f"{what}: the refusal")
            _no_overlap([sb.note, *sb.fields.values()], what)
            _snap(page, "refusal", style, pt, size)
        finally:
            _close(page, ctl, qapp)


# ── the parent: one fresh interpreter for all of the above ───────────────────────────
def _child_verdict(rc: int, lines: list[str]) -> str:
    tail = lines[-1] if lines else ""
    if rc != 0:
        return f"the child interpreter exited {rc}"
    if " passed" not in tail or "failed" in tail or "error" in tail or "skipped" in tail:
        return f"the child did not pass cleanly: {tail!r}"
    return ""


def test_the_docker_route_brand_step_is_drawn_whole_in_a_fresh_interpreter():
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

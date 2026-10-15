"""The window's LookEditor (hugmesh-generator#654, D6 and D7): what it does, and what a
person SEES (the #647 rule: 193 green tests said a control existed that the operator
could not see).

Two halves. The ordinary tests drive the widget the way a person does (pick, type,
click) and read the record back. The ``test_look_*`` tests measure the drawing: every
control, scrolled to, is whole inside the viewport, tall enough to click and wide enough
to read, rows do not overlap, and a sentence draws all of its words — at the two window
sizes the Studio opens at (1040x780 and 736x736), under two Qt styles, at 8 and 9 pt.
They run in a fresh interpreter (tests/test_look.py starts it), because switching the
style of a process that holds other tests' widgets re-polishes every one of them.

    HUGMESH_LOOK_SHOTS=<dir> python -m pytest tests/test_look.py

saves a PNG of each state so a reviewer can open what the test measured.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from _look import assert_whole, child_only, looking, settle, viewport_of    # noqa: E402
from test_look_model import png_bytes                                         # noqa: E402

from hugmesh_studio.core import brand_look, theme                             # noqa: E402
from hugmesh_studio.gui.pages._lookeditor import LookEditor                   # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtWidgets                           # noqa: E402

#: the two windows the Studio opens at (1040x780 is the wide default, 736x736 what a
#: small display clamps it to) x two styles x 8 and 9 pt.
SIZES = [(1040, 780), (736, 736)]
CASES = [(style, pt, size) for size in SIZES for style in ("Fusion", "Breeze")
         for pt in (8.0, 9.0)]
IDS = [f"{style.lower()}-{pt:g}pt-{w}x{h}" for style, pt, (w, h) in CASES]


@pytest.fixture(scope="module")
def qapp():
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    yield app


def _png(tmp_path, name, w=32, h=32, noise=False):
    p = tmp_path / name
    p.write_bytes(png_bytes(w, h, noise=noise, opaque=not noise))
    return str(p)


# ── behaviour: what a person does, and the record it leaves ──────────────────────────
def test_a_design_edit_lands_in_the_record_and_emits_changed(qapp):
    ed = LookEditor(brand_look.Look(), path="docker")
    seen = []
    ed.changed.connect(lambda: seen.append(1))
    ed.preset.setCurrentIndex(ed.preset.findData("forest"))
    assert ed.model.get("preset") == "forest" and seen
    assert ed.primary.text() == ed.model.get("primary") != ""
    ed.primary.setText("#123456")
    ed.primary.editingFinished.emit()
    assert ed.model.get("primary") == "#123456"
    assert ed.preset.currentIndex() == 0, "a hand-typed colour flips the preset to Custom"
    assert ed.model.get("preset") == ""


def test_the_path_rule_touches_only_each_rows_direct_children_and_still_disables_the_inside(qapp):
    """set_path used to call setEnabled on EVERY descendant of a row, including a combo
    box's own popup and a line edit's inner widgets that Qt re-creates when a style
    changes; a stale one segfaulted the process now and then (seen as a crash in
    QWidget::setEnabled in tests/test_domain_services_selection_column.py). It now
    touches the row's direct children only, and a disabled parent disables what is inside
    it. (Mutation: put the recursive walk back and the source scan goes red.)"""
    import inspect
    src = inspect.getsource(LookEditor.set_path)
    assert "FindDirectChildrenOnly" in src
    ed = LookEditor(brand_look.Look({}, base={}), path="kind")
    ed.show()
    for field, control in ed.controls.items():
        assert not control.isEnabled(), field
        for child in control.findChildren(QtWidgets.QWidget):
            assert not child.isEnabled(), (field, type(child).__name__)
        assert ed.source_labels[field].isEnabled(), field
    ed.set_path("docker")
    for field, control in ed.controls.items():
        assert control.isEnabled(), field


def test_a_box_left_with_the_value_it_already_holds_is_not_an_edit(qapp):
    """Leaving a box unchanged emits nothing (the guard in LookEditor._write; with the
    guard replaced by 'always' every tab through the form announced an edit and
    re-drew the page)."""
    ed = LookEditor(brand_look.Look(), path="docker")
    seen = []
    ed.changed.connect(lambda: seen.append(1))
    ed.header_text.setText("Welcome")
    ed.header_text.editingFinished.emit()
    assert ed.model.get("header_text") == "Welcome" and len(seen) == 1
    ed.header_text.editingFinished.emit()           # focus leaves again, nothing typed
    ed.header_text.editingFinished.emit()
    assert len(seen) == 1, "an unchanged box announced an edit"
    ed.header_text.setText("Welcome back")
    ed.header_text.editingFinished.emit()
    assert len(seen) == 2


def test_a_refused_value_is_a_sentence_beside_the_control_and_never_a_pop_up(qapp):
    ed = LookEditor(brand_look.Look(), path="docker")
    ed.show()
    ed.primary.setText("blue")
    ed.primary.editingFinished.emit()
    assert ed.error_text() == "“blue” is not #RRGGBB — primary not changed"
    assert ed.error_note.isVisible() and ed.model.get("primary") == ""
    ed.primary.setText("#102030")
    ed.primary.editingFinished.emit()
    assert ed.error_text() == "" and not ed.error_note.isVisible()


def test_a_png_upload_moves_the_meter_and_an_svg_is_refused_beside_the_box(qapp, tmp_path):
    ed = LookEditor(brand_look.Look(), path="docker")
    ed.show()
    before = ed.meter.value()
    ed.picture_paths["logo_image"].setText(_png(tmp_path, "logo.png"))
    note = ed.picture_notes["logo_image"]
    assert note.full_text().startswith("Accepted: 32x32 PNG")
    assert ed.meter.value() > before
    assert ed.meter_label.text() == ed.model.budget().text()
    assert ed.model.get("logo_image").startswith("data:image/png;base64,")
    thumb = ed.picture_thumbs["logo_image"]
    assert thumb.isVisible() and not thumb.pixmap().isNull(), \
        "the picture is drawn from the bytes the stylesheet carries"
    assert not ed.picture_thumbs["login_bg_image"].isVisible()
    svg = tmp_path / "x.svg"
    svg.write_bytes(b'<svg xmlns="http://www.w3.org/2000/svg"><script/></svg>')
    ed.picture_paths["login_bg_image"].setText(str(svg))
    refused = ed.picture_notes["login_bg_image"].full_text()
    assert refused.startswith("Refused: SVG is not accepted")
    assert ed.model.get("login_bg_image") == ""


def test_a_picture_past_the_budget_is_refused_with_the_numbers(qapp, tmp_path):
    ed = LookEditor(brand_look.Look(), path="docker")
    ed.picture_paths["logo_image"].setText(_png(tmp_path, "big.png", 220, 220, noise=True))
    text = ed.picture_notes["logo_image"].full_text()
    assert text.startswith("Refused: This picture does not fit.")
    assert "102,400" in text and "220x220" in text
    assert ed.model.get("logo_image") == ""


def test_the_vanta_effects_are_listed_greyed_with_the_reason(qapp):
    ed = LookEditor(brand_look.Look(), path="docker")
    combo = ed.bg_effect
    assert combo.count() == len(theme.BG_EFFECTS)
    for i in range(combo.count()):
        effect = combo.itemData(i)
        item = combo.model().item(i)
        if effect in theme.VANTA_EFFECTS:
            assert not item.isEnabled()
            assert brand_look.VANTA_UNSELECTABLE in combo.itemText(i)
            assert item.toolTip() == theme.VANTA_DEPENDENCY_NOTE
        else:
            assert item.isEnabled()
    assert theme.VANTA_DEPENDENCY_NOTE in ed.vanta_note.text()


def test_the_font_requirement_sentence_shows_until_licence_and_source_are_given(
        qapp, monkeypatch):
    monkeypatch.setattr(brand_look, "_font_bytes", lambda look: (b"", ""))
    ed = LookEditor(brand_look.Look(), path="docker")
    ed.show()
    assert not ed.requirements_note.isVisible()
    ed.font_file.setText("/example/face.ttf")
    assert not ed.requirements_note.isVisible(), "a refused upload leaves nothing to require"
    ed.model.set("font_file", "/example/face.ttf")
    ed._refresh()
    assert ed.requirements_note.isVisible() and "licence" in ed.requirements_note.text()
    ed.font_licence.setText("SIL OFL 1.1")
    ed.font_licence.editingFinished.emit()
    ed.font_source.setText("example foundry")
    ed.font_source.editingFinished.emit()
    assert not ed.requirements_note.isVisible()


def _override(sb=None, path="docker", **own):
    base = brand_look.Look(sb or {"style": "sharp", "primary": "#3355aa"})
    return LookEditor(brand_look.Look(own, base=base.effective()), path=path)


def test_override_mode_marks_every_row_and_use_the_superbrands_value_arms_on_click_one(qapp):
    ed = _override(style="glass", decor="arrows")
    ed.show()
    assert ed.source_labels["style"].text() == brand_look.OWN_TEXT
    assert ed.source_labels["primary"].text() == brand_look.INHERITED_TEXT
    assert ed.use_buttons["style"].isEnabled() and not ed.use_buttons["primary"].isEnabled()
    btn = ed.use_buttons["style"]
    btn.click()
    assert btn.text() == brand_look.USE_SUPERBRAND_ARMED
    assert ed.model.get("style") == "glass", "the first click changes nothing"
    ed.use_buttons["decor"].click()                    # another field: re-arms, never applies
    assert btn.text() == brand_look.USE_SUPERBRAND
    assert ed.use_buttons["decor"].text() == brand_look.USE_SUPERBRAND_ARMED
    btn.click()
    btn.click()
    assert ed.model.get("style") == "sharp" and ed.source_labels["style"].text() == \
        brand_look.INHERITED_TEXT
    assert ed.model.record() == {"decor": "arrows"}
    assert not ed.use_buttons["style"].isEnabled()


def test_any_edit_disarms_the_button(qapp):
    ed = _override(style="glass")
    ed.use_buttons["style"].click()
    assert ed.armed_field() == "style"
    ed.header_text.setText("hello")
    ed.header_text.editingFinished.emit()
    assert ed.armed_field() is None
    assert ed.use_buttons["style"].text() == brand_look.USE_SUPERBRAND


def test_off_the_docker_mesh_every_override_control_is_drawn_disabled_with_the_reason(qapp):
    ed = _override(path="kind", style="glass")
    ed.show()
    assert ed.path_note.isVisible()
    assert ed.path_note.text() == brand_look.DOCKER_ONLY_SENTENCE
    for field, control in ed.controls.items():
        assert control.isVisible(), f"{field} is hidden, not disabled"
        assert not control.isEnabled(), f"{field} stays editable where nothing shows it"
        assert not ed.use_buttons[field].isEnabled()
    ed.set_path("docker")
    assert not ed.path_note.isVisible() and ed.style.isEnabled()


def test_design_mode_has_no_source_labels_and_no_use_buttons(qapp):
    ed = LookEditor(brand_look.Look(), path="kind")
    ed.show()
    assert not ed.path_note.isVisible()                # design is the superbrand's own
    assert all(not b.isVisible() for b in ed.use_buttons.values())
    assert all(not s.isVisible() for s in ed.source_labels.values())
    assert ed.style.isEnabled()


def test_the_board_and_the_contrast_line_follow_the_look(qapp):
    ed = LookEditor(brand_look.Look(), path="docker")
    ed.preset.setCurrentIndex(ed.preset.findData("forest"))
    assert ed.board_grid.count() == 10                # two rows of five tiles
    assert "Measured contrast on" in ed.contrast_line.text()
    assert ed.contrast_line.text() == brand_look.board(ed.model.effective()).contrast


def test_the_unaffiliated_rule_keeps_the_desktop_logo_row_drawn_but_disabled(qapp):
    ed = LookEditor(brand_look.Look(), path="docker")
    ed.show()
    ed.set_identity_allowed(False, "This build is unaffiliated: a logo is refused.")
    assert ed.identity_note.isVisible()
    assert not ed.controls["desktop_logo"].parentWidget().isEnabled()
    assert ed.controls["wallpaper"].isEnabled()        # look stays allowed
    ed.desktop_logo.setText("/example/logo.png")
    assert ed.model.get("desktop_logo") == ""


def test_set_model_switches_a_design_editor_to_a_brand_without_leaking_values(qapp):
    ed = LookEditor(brand_look.Look({"style": "flat"}), path="docker")
    sb = ed.model
    ed.set_model(brand_look.Look({}, base=sb.effective()))
    assert ed.style.currentData() == "flat"
    assert all(b.isVisible() or not ed.isVisible() for b in ed.use_buttons.values())
    assert ed.source_labels["style"].text() == brand_look.INHERITED_TEXT


# ── geometry: drawn, whole, and big enough to click ──────────────────────────────────
MIN_HEIGHT = 18


def _scroll_to(ed, widget, qapp):
    """Put ``widget``'s top 40 px below the viewport's top. Not ensureWidgetVisible: for a
    QLineEdit that asks for the text CURSOR's rectangle (about 17 px) to be visible, so
    the box itself could end half under the edge and still pass."""
    sa = ed._content_scroll
    y = widget.mapTo(sa.widget(), QtCore.QPoint(0, 0)).y()
    sa.verticalScrollBar().setValue(max(0, y - 40))
    settle(qapp, 2)


def _inside_viewport(ed, widget, what):
    vp = viewport_of(ed)
    tl = vp.mapFromGlobal(widget.mapToGlobal(QtCore.QPoint(0, 0)))
    br = vp.mapFromGlobal(widget.mapToGlobal(QtCore.QPoint(widget.width() - 1,
                                                          widget.height() - 1)))
    assert tl.x() >= 0 and br.x() < vp.width(), \
        f"{what}: spans x {tl.x()}..{br.x()} of a {vp.width()}px viewport"
    assert tl.y() >= 0 and br.y() < vp.height(), \
        f"{what}: spans y {tl.y()}..{br.y()} of a {vp.height()}px viewport after scrolling to it"


def _label_of(widget):
    return getattr(widget, "text", lambda: "")() or ""


def _row_neighbours_do_not_overlap(ed, what):
    """In every control row the visible parts sit side by side, none over another."""
    for field, control in ed.controls.items():
        row = control.parentWidget()
        kids = [w for w in row.children() if isinstance(w, QtWidgets.QWidget)
                and w.isVisibleTo(ed)]
        rects = [(w.geometry(), type(w).__name__) for w in kids]
        for i, (a, na) in enumerate(rects):
            for b, nb in rects[i + 1:]:
                inter = a.intersected(b)
                assert inter.isEmpty() or inter.width() <= 1, \
                    f"{what} {field}: {na} {a.getRect()} overlaps {nb} {b.getRect()}"


def _every_control_is_drawn(ed, qapp, what):
    from _look import assert_page_fits_its_window
    assert_page_fits_its_window(ed)
    _row_neighbours_do_not_overlap(ed, what)
    for field, control in ed.controls.items():
        _scroll_to(ed, control, qapp)
        label = f"{what}: {field} ({type(control).__name__})"
        assert control.isVisible(), f"{label} is not visible"
        _inside_viewport(ed, control, label)
        assert control.height() >= MIN_HEIGHT, f"{label} is {control.height()}px tall"
        if isinstance(control, (QtWidgets.QLineEdit, QtWidgets.QComboBox)):
            assert control.width() >= 90, f"{label} is {control.width()}px wide"
        if isinstance(control, QtWidgets.QCheckBox):
            ind = control.style().pixelMetric(QtWidgets.QStyle.PixelMetric.PM_IndicatorWidth)
            need = control.fontMetrics().horizontalAdvance(control.text()) + ind + 6
            assert need <= control.width() + 2, f"{label} needs {need}px, has {control.width()}px"
        for btn in control.parentWidget().findChildren(QtWidgets.QPushButton):
            if not btn.isVisibleTo(ed):
                continue
            _scroll_to(ed, btn, qapp)
            _inside_viewport(ed, btn, f"{label} button {btn.text()!r}")
            need = btn.fontMetrics().horizontalAdvance(btn.text()) + 12
            assert btn.width() >= need - 2, (
                f"{label} button {btn.text()!r}: needs {need}px of text room, has "
                f"{btn.width()}px")
            assert btn.height() >= MIN_HEIGHT


def _every_sentence_is_whole(ed, qapp, what):
    for lab in ed.findChildren(QtWidgets.QLabel):
        if not lab.isVisibleTo(ed) or not lab.text() or lab.pixmap() is not None and \
                not lab.pixmap().isNull():
            continue
        if lab.objectName().startswith("look_source_") or lab.parent() is ed.stripes:
            continue
        if getattr(lab, "full_text", None):          # an ElidedLabel elides on purpose
            assert lab.toolTip() == lab.full_text(), f"{what}: an elided label lost its tooltip"
            continue
        if lab.wordWrap():
            _scroll_to(ed, lab, qapp)
            assert_whole(lab, f"{what}: {lab.text()[:50]!r}")


def _shot(ed, qapp, tag, style, pt, size, scroll_to=None):
    out = os.environ.get("HUGMESH_LOOK_SHOTS", "")
    if not out:
        return ""
    os.makedirs(out, exist_ok=True)
    if scroll_to is not None:
        _scroll_to(ed, scroll_to, qapp)
    path = os.path.join(out, f"{tag}-{style.lower()}-{pt:g}pt-{size[0]}x{size[1]}.png")
    ed.grab().save(path)
    return path


def _open(ed, qapp, size):
    ed.resize(*size)
    ed.show()
    settle(qapp, 4)


@pytest.mark.parametrize(("style", "pt", "size"), CASES, ids=IDS)
def test_look_the_design_step_is_drawn_whole(qapp, tmp_path, style, pt, size):
    """The superbrand's design step with pictures set, the meter running and the board
    showing: every control reachable, whole and clickable; every sentence whole."""
    child_only()
    with looking(qapp, style, pt):
        ed = LookEditor(brand_look.Look(), path="docker")
        try:
            _open(ed, qapp, size)
            ed.preset.setCurrentIndex(ed.preset.findData("pride"))
            ed.picture_paths["logo_image"].setText(_png(tmp_path, "logo.png"))
            ed.picture_paths["login_bg_image"].setText(_png(tmp_path, "bg.png", 64, 36))
            ed.font_file.setText("/example/a-very-long-font-file-name-that-would-widen-the-"
                                 "whole-page-if-it-were-not-elided-VariableFont_wght.ttf")
            ed.primary.setText("red")
            ed.primary.editingFinished.emit()           # leaves the refusal sentence up
            settle(qapp)
            what = f"design {style} {pt:g}pt {size[0]}x{size[1]}"
            _every_control_is_drawn(ed, qapp, what)
            _every_sentence_is_whole(ed, qapp, what)
            # the refusal sentence is pinned above the scroll area: seen from anywhere
            assert ed.error_note.isVisible() and ed.error_note.parent() is ed
            assert_whole(ed.error_note, f"{what}: the refusal sentence")
            assert ed.error_note.geometry().right() <= ed.width()
            for w in (ed.meter, ed.meter_label, ed.contrast_line, ed.preview_btn,
                      ed.vanta_note, *ed.picture_thumbs.values()):
                _scroll_to(ed, w, qapp)
                assert w.isVisible(), f"{what}: {w.objectName() or type(w).__name__} hidden"
                _inside_viewport(ed, w, f"{what}: {w.objectName() or type(w).__name__}")
            assert ed.meter.height() >= 12
            assert ed.preview_btn.width() >= ed.preview_btn.fontMetrics().horizontalAdvance(
                ed.preview_btn.text()) + 8
            tiles = [ed.board_grid.itemAt(i).widget() for i in range(ed.board_grid.count())]
            assert len(tiles) == 10
            for t in tiles:
                _scroll_to(ed, t, qapp)
                assert t.width() >= 60 and t.height() >= 40, \
                    f"{what}: a board tile is {t.width()}x{t.height()}"
            _shot(ed, qapp, "design-top", style, pt, size, ed.mode_note)
            _shot(ed, qapp, "design-pictures", style, pt, size, ed.meter)
            _shot(ed, qapp, "design-preview", style, pt, size, ed.preview_btn)
        finally:
            ed.close()
            ed.deleteLater()
            settle(qapp)


@pytest.mark.parametrize(("style", "pt", "size"), CASES, ids=IDS)
def test_look_a_brands_look_tab_is_drawn_whole_with_one_override_and_one_armed(
        qapp, style, pt, size):
    """Override mode on the Docker mesh: the source label, 'Use the superbrand's value'
    and, armed, its longest sentence share a row with the control and the row still fits
    (the row the 736 px window is tightest for)."""
    child_only()
    with looking(qapp, style, pt):
        ed = _override(style="glass", header_text="Welcome to the whole mesh")
        try:
            _open(ed, qapp, size)
            ed.use_buttons["style"].click()              # armed: the long sentence
            ed.use_buttons["header_text"].click()        # armed instead; style disarms
            settle(qapp)
            assert ed.armed_field() == "header_text"
            assert ed.use_buttons["header_text"].text() == brand_look.USE_SUPERBRAND_ARMED
            what = f"brand {style} {pt:g}pt {size[0]}x{size[1]}"
            _every_control_is_drawn(ed, qapp, what)
            _every_sentence_is_whole(ed, qapp, what)
            for field in ("style", "header_text", "primary", "font_licence"):
                for w in (ed.source_labels[field], ed.use_buttons[field]):
                    _scroll_to(ed, w, qapp)
                    assert w.isVisible(), f"{what}: {field} {type(w).__name__} hidden"
                    _inside_viewport(ed, w, f"{what}: {field} {type(w).__name__}")
                    if isinstance(w, QtWidgets.QPushButton):
                        need = w.fontMetrics().horizontalAdvance(w.text()) + 12
                        assert w.width() >= need - 2, \
                            f"{what}: {w.text()!r} needs {need}px, has {w.width()}px"
            _shot(ed, qapp, "brand-look-top", style, pt, size, ed.mode_note)
            _shot(ed, qapp, "brand-look-shape", style, pt, size, ed.use_buttons["style"])
        finally:
            ed.close()
            ed.deleteLater()
            settle(qapp)


@pytest.mark.parametrize(("style", "pt", "size"), CASES, ids=IDS)
def test_look_the_disabled_override_controls_are_drawn_with_the_sentence(
        qapp, style, pt, size):
    """Off the Docker mesh nothing is hidden: every control is drawn, disabled, with the
    one sentence that says why drawn whole at the top."""
    child_only()
    with looking(qapp, style, pt):
        ed = _override(path="kind", style="glass")
        try:
            _open(ed, qapp, size)
            what = f"kind {style} {pt:g}pt {size[0]}x{size[1]}"
            assert ed.path_note.isVisible()
            _scroll_to(ed, ed.path_note, qapp)
            assert_whole(ed.path_note, f"{what}: the disabled-control sentence")
            _inside_viewport(ed, ed.path_note, f"{what}: the disabled-control sentence")
            _every_control_is_drawn(ed, qapp, what)
            _every_sentence_is_whole(ed, qapp, what)
            for field, control in ed.controls.items():
                assert not control.isEnabled(), f"{what}: {field} is editable"
            _shot(ed, qapp, "brand-look-kind", style, pt, size, ed.mode_note)
        finally:
            ed.close()
            ed.deleteLater()
            settle(qapp)


def _find_button(ed, field, text):
    row = ed.controls[field].parentWidget()
    return next(b for b in row.findChildren(QtWidgets.QPushButton) if b.text() == text)


def test_tabbing_through_an_override_form_does_not_freeze_the_inherited_fields(qapp):
    """Every box shows the inherited value and fires 'finished' when focus leaves it;
    that must not turn each one into the brand's own copy (D7)."""
    sb = {"primary": "#336699", "secondary": "#993366", "header_text": "Hello",
          "footer_text": "Bye", "style": "sharp"}
    ed = LookEditor(brand_look.Look({}, base=brand_look.Look(sb).effective()))
    ed.show()
    boxes = [c for c in ed.controls.values()
             if isinstance(c, QtWidgets.QLineEdit) and c.isEnabled()]
    assert len(boxes) >= 6
    for box in boxes:
        box.setFocus()
        qapp.processEvents()
        box.editingFinished.emit()
    ed.primary.setFocus()
    ed.secondary.setFocus()
    ed.header_text.setFocus()
    ed.primary.setFocus()
    qapp.processEvents()
    assert ed.model.own == {}, ed.model.own
    assert ed.source_labels["primary"].text() == brand_look.INHERITED_TEXT
    assert ed.model.record() == {}


def test_an_emptied_colour_box_in_override_mode_goes_back_to_the_superbrands(qapp):
    sb = brand_look.Look({"primary": "#336699"}).effective()
    ed = LookEditor(brand_look.Look({"primary": "#112233"}, base=sb))
    ed.primary.setText("")
    ed.primary.editingFinished.emit()
    assert ed.model.own == {}
    assert ed.primary.text() == "#336699", "the box shows what is in force again"
    assert ed.source_labels["primary"].text() == brand_look.INHERITED_TEXT


def test_a_changed_value_in_override_mode_is_the_brands_own(qapp):
    ed = _override()
    ed.header_text.setText("Mine")
    ed.header_text.editingFinished.emit()
    assert ed.model.own == {"header_text": "Mine"}
    assert ed.source_labels["header_text"].text() == brand_look.OWN_TEXT


def test_clear_removes_a_stored_picture_in_step_with_the_text_face(qapp):
    uri = brand_look.brand_images.reencode(png_bytes(8, 8), "logo").data_uri()
    ed = LookEditor(brand_look.Look({"logo_image": uri, "login_bg_image": uri}))
    ed.show()
    assert ed.picture_paths["logo_image"].text() == "", "a stored picture shows no path"
    _find_button(ed, "logo_image", "Clear").click()
    assert ed.model.get("logo_image") == ""
    assert not ed.picture_thumbs["logo_image"].isVisible()
    assert ed.model.get("login_bg_image") == uri, "only that row is cleared"
    _find_button(ed, "login_bg_image", "Clear").click()
    assert ed.model.get("login_bg_image") == ""
    assert ed.model.css() == brand_look.Look().css()


def test_clear_over_an_inherited_picture_is_the_brands_own_no_picture(qapp):
    uri = brand_look.brand_images.reencode(png_bytes(8, 8), "logo").data_uri()
    base = brand_look.Look({"logo_image": uri}).effective()
    ed = LookEditor(brand_look.Look({}, base=base))
    _find_button(ed, "logo_image", "Clear").click()
    assert ed.model.own == {"logo_image": ""}
    assert ed.model.get("logo_image") == ""
    assert ed.source_labels["logo_image"].text() == brand_look.OWN_TEXT

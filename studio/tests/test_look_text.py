"""The text face of the look editor — tui/themes.py LookText (hugmesh-generator#654,
D6 and D7, operator decision 71 = A: the GUI and the text-mode front end offer the same
controls).

Two things are pinned here, and the second is the one that fails quietly:

* LookText works as a screen: numbered sections, a source marker per row in override
  mode, a refusal that names its reason, 'use COMMAND' twice to hand a field back.
* PARITY. Every control of the window's LookEditor has a text command, and the two
  write the SAME record when given the same value. A control with no command is the
  drift decision 71 forbids; a command that writes something else is worse.

Qt-free except the parity half, which skips without a binding.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from hugmesh_studio.core import brand_look, theme                      # noqa: E402
from hugmesh_studio.tui import themes as tui_themes                    # noqa: E402
from hugmesh_studio.tui.themes import FIELD_COMMANDS, LookText, SECTIONS  # noqa: E402


def _text(model=None, path="docker"):
    return LookText(model or brand_look.Look(), path=path)


# ── the screen ───────────────────────────────────────────────────────────────────────
def test_the_screen_numbers_its_sections_in_the_windows_order():
    shown = "\n".join(_text().lines())
    for number, (title, fields) in enumerate(SECTIONS, 1):
        assert f"{number}. {title}" in shown
        for field in fields:
            assert FIELD_COMMANDS[field] in shown
    assert f"{len(SECTIONS) + 1}. Preview" in shown
    titles = [t for t, _ in SECTIONS]
    assert titles == ["Colours", "Font", "Shape and decoration", "Header", "Footer",
                      "Page background", "Pictures on the web pages",
                      "Desktop pictures and colours (x86 desktop images only)"]


def test_every_field_has_exactly_one_command_and_every_command_is_a_field():
    assert set(FIELD_COMMANDS) == set(brand_look.LOOK_FIELDS)
    assert len(set(FIELD_COMMANDS.values())) == len(FIELD_COMMANDS)
    in_sections = [f for _, fields in SECTIONS for f in fields]
    assert sorted(in_sections) == sorted(brand_look.LOOK_FIELDS)


def test_design_mode_shows_no_source_markers_and_override_mode_shows_one_per_row():
    design = "\n".join(_text().lines())
    assert brand_look.INHERITED_TEXT not in design
    base = brand_look.Look({"style": "sharp"})
    brand = brand_look.Look({"decor": "arrows"}, base=base.effective())
    shown = _text(brand).lines()
    assert sum(f"[{brand_look.INHERITED_TEXT}]" in ln for ln in shown) == len(brand_look.LOOK_FIELDS) - 1
    own = [ln for ln in shown if f"[{brand_look.OWN_TEXT}]" in ln]
    assert len(own) == 1 and "decor" in own[0]


def test_a_choice_command_alone_lists_the_choices_and_a_number_or_name_picks():
    t = _text()
    listing = t.feed("shape")
    for name in theme.STYLE_VARIANTS:
        assert brand_look.STYLE_LABELS[name] in listing
    assert t.feed("shape 2") == ""
    assert t.model.get("style") == list(theme.STYLE_VARIANTS)[1]
    assert t.feed("shape glass") == ""
    assert t.model.get("style") == "glass"
    assert "no such choice" in t.feed("shape 99")
    assert t.model.get("style") == "glass"


def test_a_malformed_colour_is_refused_with_the_windows_sentence_and_changes_nothing():
    t = _text()
    t.feed("1 #112233")
    assert t.feed("1 blue") == "“blue” is not #RRGGBB — primary not changed"
    assert t.model.get("primary") == "#112233"
    assert t.feed("1 -") == ""
    assert t.model.get("primary") == ""


def test_the_vanta_rows_are_listed_and_refused_with_the_dependency_named():
    t = _text()
    listing = t.feed("e")
    assert listing.count(brand_look.VANTA_UNSELECTABLE) == 4
    out = t.feed("e vanta-fog")
    assert out.startswith("vanta-fog is saved but not selectable")
    assert theme.VANTA_DEPENDENCY_NOTE in out
    assert t.model.get("bg_effect") == theme.BG_EFFECT_DEFAULT
    assert t.feed("e none") == "" and t.model.get("bg_effect") == "none"


def test_a_preset_fills_the_two_colours_and_a_hand_edit_flips_it_to_custom():
    t = _text()
    t.feed("p forest")
    assert t.model.get("preset") == "forest"
    assert t.model.get("primary") and t.model.get("secondary")
    t.feed("1 #123456")
    assert t.model.get("preset") == ""
    assert t.model.get("primary") == "#123456"


def test_m_alone_toggles_the_ramp_like_the_themes_screen():
    t = _text()
    t.feed("m")
    assert t.model.get("mode") == "light"
    t.feed("m")
    assert t.model.get("mode") == "dark"


def test_use_is_two_commands_and_anything_between_them_cancels_the_arm():
    base = brand_look.Look({"style": "sharp"})
    t = _text(brand_look.Look({"style": "glass", "decor": "arrows"}, base=base.effective()))
    armed = t.feed("use shape")
    assert brand_look.USE_SUPERBRAND_ARMED in armed
    assert t.model.get("style") == "glass"            # the first command changed nothing
    t.feed("board")                                    # something else in between
    assert t.model.armed is None
    t.feed("use shape")
    assert t.model.get("style") == "glass"            # armed again, still not applied
    assert "inherited from the superbrand again" in t.feed("use shape")
    assert t.model.record() == {"decor": "arrows"}


def test_use_says_so_when_the_value_is_already_inherited_or_there_is_no_superbrand():
    t = _text(brand_look.Look({}, base={}))
    assert "already inherited from the superbrand" in t.feed("use shape")
    assert "no superbrand above it" in _text().feed("use shape")
    assert "takes a command" in _text(brand_look.Look({}, base={})).feed("use banana")


def test_off_the_docker_path_an_override_is_refused_with_the_reason_not_hidden():
    brand = brand_look.Look({}, base={})
    t = _text(brand, path="kind")
    assert t.feed("shape glass") == brand_look.DOCKER_ONLY_SENTENCE
    assert brand.record() == {}
    assert brand_look.DOCKER_ONLY_SENTENCE in "\n".join(t.lines())
    assert _text(brand_look.Look({}, base={}), path="docker").feed("shape glass") == ""


def test_the_unaffiliated_rule_refuses_the_desktop_logo_and_allows_the_look():
    model = brand_look.Look()
    model.identity_allowed = False
    model.identity_reason = "This build is unaffiliated: a logo is refused."
    t = _text(model)
    assert t.feed("dlogo /tmp/logo.png") == "This build is unaffiliated: a logo is refused."
    assert model.get("desktop_logo") == ""
    assert t.feed("wallpaper /tmp/w.png") == "" and model.get("wallpaper") == "/tmp/w.png"
    assert t.feed("shape glass") == "" and t.feed("1 #123456") == ""


def test_the_font_requirement_is_a_line_under_the_font_section(monkeypatch):
    monkeypatch.setattr(brand_look, "_font_bytes", lambda look: (b"", ""))
    t = _text()
    t.model.set("font_file", "/example/face.ttf")
    shown = "\n".join(t.lines())
    assert "   ! The font's licence is required with an uploaded font" in shown
    t.feed("fontlicence SIL OFL 1.1")
    t.feed("fontsource example foundry")
    assert "   ! " not in "\n".join(t.lines())


def test_the_board_command_prints_the_measured_contrast_the_window_shows():
    t = _text()
    t.feed("p forest")
    out = t.feed("board")
    data = brand_look.board(t.model.effective())
    assert data.contrast in out
    assert "as text" in out and ":1" in out


def test_font_commands_on_the_themes_screen_edit_the_image_config_through_the_model():
    from hugmesh_studio.core.config import ImageConfig
    cfg = ImageConfig()
    screen = tui_themes.ThemesScreen()

    class _J:                                          # the three things feed() touches
        status = ""
        cfg = None

        def close_overlay(self):
            pass

    j = _J()
    j.cfg = cfg
    screen.feed(j, "font Humanist")
    assert cfg.login_font == "Humanist"
    screen.feed(j, "font Nonesuch")
    assert "no such choice" in j.status and cfg.login_font == "Humanist"
    screen.feed(j, "fontlicence SIL OFL 1.1")
    assert cfg.login_font_licence == "SIL OFL 1.1"
    screen.feed(j, "board")
    assert "Measured contrast" in j.status
    shown = "\n".join(screen.lines(j))
    assert "font       Humanist" in shown and "fontfile" in shown


# ── parity with the window ───────────────────────────────────────────────────────────
VALUES = {
    "preset": "forest", "mode": "light", "primary": "#112233", "secondary": "#445566",
    "font": "Humanist", "font_licence": "SIL OFL 1.1", "font_source": "example foundry",
    "style": "glass", "decor": "arrows",
    "header_hidden": True, "header_size": "tall", "header_bg": "#101010",
    "header_text": "Welcome to the mesh",
    "footer_hidden": True, "footer_size": "compact", "footer_bg": "#202020",
    "footer_text": "Footer words",
    "bg_effect": "none", "theme": "dark",
    "wallpaper": "/example/wall.png", "boot_background": "/example/boot.png",
    "boot_theme": "/example/grub", "login_screen_background": "/example/login.png",
    "desktop_logo": "/example/logo.png", "accent_color": "#abcdef",
    "color_scheme": "BreezeDark",
}
#: fields whose value comes from a file the window and the text screen both read; they
#: are covered by the upload tests, not by this table.
UPLOADS = {"font_file", "logo_image", "login_bg_image"}


@pytest.fixture(scope="module")
def qapp():
    qt = pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding")
    app = qt.QtWidgets.QApplication.instance() or qt.QtWidgets.QApplication([])
    yield app


def _window_set(editor, field, value):
    """Do to ONE window control what a person does: pick, tick or type and finish."""
    from hugmesh_studio.gui.qt import QtWidgets
    control = editor.controls[field]
    if isinstance(control, QtWidgets.QComboBox):
        idx = control.findData(value)
        assert idx >= 0, f"{field}: the window's combo has no row for {value!r}"
        control.setCurrentIndex(idx)
    elif isinstance(control, QtWidgets.QCheckBox):
        control.setChecked(bool(value))
    else:
        control.setText(value)
        control.editingFinished.emit()


def test_every_value_in_the_parity_table_names_a_real_field():
    assert set(VALUES) | UPLOADS == set(brand_look.LOOK_FIELDS)


def test_every_window_control_has_a_text_command_and_writes_the_same_record(qapp):
    pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding")
    from hugmesh_studio.gui.pages._lookeditor import LookEditor
    editor = LookEditor(brand_look.Look(), path="docker")
    # 1. the controls and the commands are the same set
    assert set(editor.controls) == set(FIELD_COMMANDS), (
        f"controls without a command: {sorted(set(editor.controls) - set(FIELD_COMMANDS))}; "
        f"commands without a control: {sorted(set(FIELD_COMMANDS) - set(editor.controls))}")
    # 2. the same value through either face is the same record, field by field
    for field, value in VALUES.items():
        win = LookEditor(brand_look.Look(), path="docker")
        _window_set(win, field, value)
        text = LookText(brand_look.Look())
        verb = FIELD_COMMANDS[field]
        arg = ("on" if value else "off") if isinstance(value, bool) else value
        said = text.feed(f"{verb} {arg}")
        assert said == "", f"{field}: the text command refused: {said!r}"
        assert win.model.record() == text.model.record(), (
            f"{field}: the window wrote {win.model.record()}, the text screen "
            f"{text.model.record()}")
        assert win.model.record().get(field) == value or field == "preset"


def test_both_faces_read_their_labels_from_the_one_table_in_core():
    pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding")
    from hugmesh_studio.gui.pages import _lookeditor, _theme_editor
    assert _lookeditor.EFFECT_LABELS is brand_look.EFFECT_LABELS
    assert _lookeditor.STYLE_LABELS is brand_look.STYLE_LABELS
    assert _lookeditor.DECOR_LABELS is brand_look.DECOR_LABELS
    assert tui_themes.EFFECT_LABELS == brand_look.EFFECT_LABELS
    assert _theme_editor._EFFECT_LABELS == brand_look.EFFECT_LABELS
    assert _lookeditor.USE_SUPERBRAND is brand_look.USE_SUPERBRAND
    assert _lookeditor.DOCKER_ONLY_SENTENCE is brand_look.DOCKER_ONLY_SENTENCE
    # and the table covers every selectable value, so neither face falls back to a bare id
    assert set(brand_look.STYLE_LABELS) == set(theme.STYLE_VARIANTS)
    assert set(brand_look.DECOR_LABELS) == set(theme.DECOR_VARIANTS)
    assert set(brand_look.EFFECT_LABELS) == set(theme.BG_EFFECTS)

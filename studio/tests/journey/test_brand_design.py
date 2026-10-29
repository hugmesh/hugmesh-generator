"""J-DESIGN — the superbrand's look and a brand's override, walked end to end in BOTH
faces with one script (hugmesh-generator#654, D6, D7 and D19; decision 71 = A).

THE SCRIPT (one list of gestures, run once through the window's LookEditor with real
widgets and once through the text screen's command lines):

  1. design the superbrand: choose a preset;
  2. upload a PNG as the logo — accepted, the meter moves;
  3. upload an SVG as the login background — refused, with the reason;
  4. upload a picture that would not fit — refused, with the numbers;
  5. open a brand over the superbrand's look and override two fields;
  6. arm "Use the superbrand's value" on one — nothing changes yet — and apply it.

WHAT IS COMPARED: the two faces' records, byte for byte as the record file would hold
them (json with sorted keys), against the record the script is EXPECTED to leave (built
here from the re-encoder and the preset table, not from the code under test); the
sentence each refusal shows; the stylesheet each look delivers; and that the brand
inherits the superbrand's logo while owning only the two fields it changed.

There is no #651 walker on main yet, so the two drivers below are this file's own: a
face is a handful of verbs, and a walker that drives pages can replace them without
touching the script. Nothing here starts a stack, a browser or a dialog.
"""
import json
import os
import re
import sys

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from hugmesh_studio.core import brand_images, brand_look, theme_presets    # noqa: E402
from hugmesh_studio.tui.themes import FIELD_COMMANDS, LookText             # noqa: E402
from test_look_model import png_bytes                                      # noqa: E402

SVG = (b'<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg">'
       b'<script>alert(1)</script></svg>')


@pytest.fixture
def pictures(tmp_path):
    files = {
        "logo": tmp_path / "logo.png", "svg": tmp_path / "bg.svg",
        "big": tmp_path / "big.png"}
    files["logo"].write_bytes(png_bytes(48, 48, opaque=True))
    files["svg"].write_bytes(SVG)
    files["big"].write_bytes(png_bytes(220, 220, noise=True))
    return {k: str(v) for k, v in files.items()}


# ── the two faces ────────────────────────────────────────────────────────────────────
class TextFace:
    """A person typing at the text screen."""

    def __init__(self, model, path="docker"):
        self.screen = LookText(model, path=path)
        self.model = model

    def choose(self, field, value):
        return self.screen.feed(f"{FIELD_COMMANDS[field]} {value}")

    def upload(self, field, path):
        return self.screen.feed(f"{FIELD_COMMANDS[field]} {path}")

    def use(self, field):
        return self.screen.feed(f"use {FIELD_COMMANDS[field]}")

    def meter_used(self):
        text = self.screen.feed("meter")
        return int(re.search(r"([\d,]+) of ", text).group(1).replace(",", ""))

    def open_brand(self, base_effective):
        return TextFace(brand_look.Look(base=base_effective))


class WindowFace:
    """A person using the window: real widgets, real signals."""

    def __init__(self, model, path="docker"):
        from hugmesh_studio.gui.pages._lookeditor import LookEditor
        self.editor = LookEditor(model, path=path)
        self.editor.show()
        self.model = model

    def choose(self, field, value):
        from hugmesh_studio.gui.qt import QtWidgets
        control = self.editor.controls[field]
        assert isinstance(control, QtWidgets.QComboBox), f"{field} is not a pick list"
        idx = control.findData(value)
        assert idx >= 0, f"{field}: the window offers no {value!r}"
        control.setCurrentIndex(idx)
        return self.editor.error_text()

    def upload(self, field, path):
        self.editor.picture_paths[field].setText(path)
        return self.editor.picture_notes[field].full_text()

    def use(self, field):
        self.editor.use_buttons[field].click()
        return self.editor.use_buttons[field].text()

    def meter_used(self):
        return self.model.budget().used if self.editor.meter.value() else 0

    def open_brand(self, base_effective):
        brand = brand_look.Look(base=base_effective)
        self.editor.set_model(brand)
        self.model = brand
        return self

    def meter_shown(self):
        return self.editor.meter.value()


def walk(face, pictures):
    """The script. Returns what a person would have read and the two records."""
    said = {}
    # 1. design the superbrand: a preset
    face.choose("preset", "forest")
    # 2. a PNG logo: accepted, the meter moves
    before = face.meter_used()
    said["logo"] = face.upload("logo_image", pictures["logo"])
    after = face.meter_used()
    assert after > before, f"the meter did not move: {before} -> {after}"
    # 3. an SVG: refused with the reason
    said["svg"] = face.upload("login_bg_image", pictures["svg"])
    # 4. one that would not fit: refused with the numbers
    said["big"] = face.upload("login_bg_image", pictures["big"])
    assert face.meter_used() == after, "a refused picture must not spend any budget"
    superbrand_record = dict(face.model.record())
    superbrand_css = face.model.css()
    superbrand_effective = face.model.effective()
    # 5. a brand over it: override two fields
    brand = face.open_brand(superbrand_effective)
    brand.choose("style", "glass")
    brand.choose("decor", "arrows")
    said["own_before_use"] = dict(brand.model.record())
    # 6. arm 'Use the superbrand's value' on shape: nothing changes yet; apply it
    said["armed"] = brand.use("style")
    said["record_while_armed"] = dict(brand.model.record())
    said["applied"] = brand.use("style")
    return said, superbrand_record, superbrand_css, dict(brand.model.record()), \
        brand.model.css(), brand.model.get("logo_image"), brand.model.source("logo_image")


def _expected(pictures):
    forest = theme_presets.by_id("forest")
    with open(pictures["logo"], "rb") as fh:
        logo = brand_images.reencode(fh.read(), "logo").data_uri()
    return {"preset": "forest", "primary": forest.primary, "secondary": forest.secondary,
            "logo_image": logo}


def _check(result, pictures):
    said, sb_record, sb_css, brand_record, brand_css, brand_logo, brand_logo_src = result
    expected = _expected(pictures)
    assert json.dumps(sb_record, sort_keys=True) == json.dumps(expected, sort_keys=True)
    assert said["logo"].startswith("Accepted: 48x48 PNG,")
    assert said["svg"].startswith("Refused: SVG is not accepted") and "PNG or JPEG" in said["svg"]
    assert said["big"].startswith("Refused: This picture does not fit.")
    for number in ("102,400", "220x220"):
        assert number in said["big"], (number, said["big"])
    assert said["own_before_use"] == {"style": "glass", "decor": "arrows"}
    assert said["record_while_armed"] == {"style": "glass", "decor": "arrows"}, \
        "the first click must change nothing"
    assert brand_look.USE_SUPERBRAND_ARMED.split(" to ")[0] in said["armed"]
    assert json.dumps(brand_record, sort_keys=True) == json.dumps({"decor": "arrows"})
    # what each look delivers: the superbrand's logo under both token names, and the
    # brand's own decoration (and no glass, which it handed back)
    assert "--sd-logo-image:" in sb_css and "--hug-logo-image:" in sb_css
    assert "--sd-logo-image:" in brand_css and brand_css.count(expected["logo_image"]) == 2
    assert brand_logo == expected["logo_image"] and brand_logo_src == brand_look.SUPERBRAND
    assert "--sd-nav-suffix-hover: ' \\2192';" in brand_css, "the brand's own decoration"
    assert "--sd-nav-suffix-hover" not in sb_css
    assert "--sd-radius: 0.9rem" not in brand_css, "glass was handed back, it must not ship"
    assert brand_css != sb_css


def test_text_face_walks_j_design(pictures):
    face = TextFace(brand_look.Look())
    _check(walk(face, pictures), pictures)


def test_window_face_walks_j_design(pictures):
    qt = pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding")
    app = qt.QtWidgets.QApplication.instance() or qt.QtWidgets.QApplication([])
    face = WindowFace(brand_look.Look())
    try:
        _check(walk(face, pictures), pictures)
    finally:
        face.editor.close()
        app.processEvents()


def test_both_faces_leave_the_same_bytes_and_say_the_same_sentences(pictures):
    qt = pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding")
    app = qt.QtWidgets.QApplication.instance() or qt.QtWidgets.QApplication([])
    text = walk(TextFace(brand_look.Look()), pictures)
    win_face = WindowFace(brand_look.Look())
    try:
        win = walk(win_face, pictures)
    finally:
        win_face.editor.close()
        app.processEvents()
    for i, (a, b) in enumerate(zip(text, win)):
        if i == 0:                     # what a person read: the three upload sentences
            for key in ("logo", "svg", "big", "own_before_use", "record_while_armed"):
                assert a[key] == b[key], f"{key}: text {a[key]!r} vs window {b[key]!r}"
            continue
        assert a == b, f"element {i} differs between the faces"

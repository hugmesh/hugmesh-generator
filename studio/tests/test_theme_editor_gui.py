"""The web chrome and background-effect fields of the look, after the theme move.

The modeless ThemeEditorDialog (#50 item 2) and the LoginThemeGroup it edited were
removed on 2026-10-21 as dead code (the look is chosen on each domain's Look tab, by
the LookEditor). The MODEL rules they carried still hold and are pinned here:
  1. The persisted ``login_*`` config KEYS never changed, so every saved session loads.
  2. A config saved before the chrome fields existed loads to the shipped defaults and
     composes BYTE-IDENTICAL css.
  3. Vanta values are valid persisted state and emit their token; unknown values fail
     closed.
  4. The LookEditor's background-effect picker ignores an unfocused wheel (PR #72), as
     the removed dialog's did.
"""
import json
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from hugmesh_studio.core import brand_look, theme                   # noqa: E402
from hugmesh_studio.core.config import ImageConfig                  # noqa: E402
from hugmesh_studio.core.validate import IdentityValidationError    # noqa: E402
from hugmesh_studio.gui.pages._lookeditor import LookEditor         # noqa: E402
from hugmesh_studio.gui.pages._widgets import NoWheelComboBox       # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtGui, QtWidgets          # noqa: E402


@pytest.fixture
def qapp():
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    yield app


def test_rename_is_labels_only_the_persisted_login_keys_survive(qapp):
    # The saved-session JSON keys keep their login_* names (the slug IS persisted
    # state), so an old session round-trips through the renamed surface unchanged.
    d = ImageConfig().to_dict()
    for key in ("login_primary_color", "login_secondary_color", "login_theme_preset",
                "login_theme_mode", "login_bg_effect", "login_header_hidden",
                "login_footer_text"):
        assert key in d


def test_old_theme_files_load_to_shipped_defaults_and_compose_identically(qapp, tmp_path):
    # A config saved BEFORE the chrome fields existed: no login_header_*/footer_*/
    # bg_effect keys at all.
    old = {"login_primary_color": "#336699", "login_font": "System UI"}
    cfg = ImageConfig.from_dict(old)
    assert cfg.login_bg_effect == "gradient"    # the shipped default, filled in
    assert cfg.login_header_hidden is False and cfg.login_footer_text == ""
    expected = theme.compose_login_css("#336699", font_preset="System UI")
    assert cfg.login_theme_css() == expected    # byte-identical: no chrome block
    assert "--sd-header" not in expected and "--sd-bg-effect" not in expected

    p = tmp_path / "old-theme.json"
    p.write_text(json.dumps(old), encoding="utf-8")
    assert ImageConfig.load(str(p)).login_theme_css() == expected


def test_vanta_values_are_valid_persisted_state_and_emit_their_token(qapp):
    # The MODEL path stands alone: a hand-written config needs no GUI round-trip.
    cfg = ImageConfig(login_bg_effect="vanta-fog")
    cfg.validate_identity()                     # must not raise
    assert "--sd-bg-effect: vanta-fog;" in cfg.login_theme_css()


def test_unknown_effect_and_size_fail_closed_like_every_login_field():
    with pytest.raises(IdentityValidationError):
        ImageConfig(login_bg_effect="vanta-spaghetti").validate_identity()
    with pytest.raises(IdentityValidationError):
        ImageConfig(login_header_size="huge").validate_identity()
    with pytest.raises(IdentityValidationError):
        ImageConfig(login_footer_bg="blue").validate_identity()
    # defaults stay valid (the conservative-schema guarantee)
    ImageConfig().validate_identity()


def test_effect_picker_ignores_an_unfocused_wheel(qapp):
    """PR #72's NoWheelComboBox pattern, on the look editor that replaced the dialog:
    a hover-scroll on the way past the picker must scroll the container, never
    silently swap the mesh's page background. The ignored event propagates
    (accepted=False) so a containing scroll area still gets the scroll."""
    ed = LookEditor(brand_look.Look(), path="docker")
    assert isinstance(ed.bg_effect, NoWheelComboBox)
    ed.bg_effect.clearFocus()
    before = ed.bg_effect.currentData()
    ev = QtGui.QWheelEvent(
        QtCore.QPointF(5, 5), QtCore.QPointF(5, 5),
        QtCore.QPoint(0, 0), QtCore.QPoint(0, -120),
        QtCore.Qt.MouseButton.NoButton, QtCore.Qt.KeyboardModifier.NoModifier,
        QtCore.Qt.ScrollPhase.NoScrollPhase, False)
    QtWidgets.QApplication.sendEvent(ed.bg_effect, ev)
    assert ed.bg_effect.currentData() == before, \
        "wheel over the UNFOCUSED effect picker edited it"
    assert not ev.isAccepted(), \
        "the ignored wheel must propagate so the page can scroll past the picker"

"""The Web-login-theme GUI (shared LoginThemeGroup + its two hosts).

The invariants that make the feature real rather than decorative:
  1. The token board consumes core/theme.py derive() — the swatches show the hexes
     that SHIP, with live-measured AA ratios (no second implementation to drift).
  2. BrandingPage in MESH mode: the desktop half greys, the login half stays live
     (greying it would gate the knob off on the only plane that renders it — the
     reason mesh stopped skipping this page).
  3. commit is UNCONDITIONAL: the unaffiliated-role / role-class clears may not
     touch login_* (mesh-plane data, image-scope clears).
  4. LocalMeshPage: collect_bootstrap() carries the derived css (the dead-default
     class guard), and a typo'd colour REFUSES the verb instead of silently
     shipping an unthemed stack.
  5. Slots never raise: garbage input -> error note, not a PyQt6 abort.
"""
import os
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from snapdragon_studio.core import theme                      # noqa: E402
from snapdragon_studio.core.config import ImageConfig         # noqa: E402
from snapdragon_studio.gui import wizard as wizard_mod        # noqa: E402
from snapdragon_studio.gui.pages._logintheme import LoginThemeGroup   # noqa: E402
from snapdragon_studio.gui.qt import QtWidgets                # noqa: E402

GENERATOR_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


@pytest.fixture
def qapp():
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    yield app


def _board_texts(group):
    out = []
    for i in range(group.board_grid.count()):
        w = group.board_grid.itemAt(i).widget()
        if w is not None:
            out.append(w.text())
    return "\n".join(out)


def test_board_shows_the_derived_hexes_and_measured_AA_ratios(qapp):
    g = LoginThemeGroup()
    g.primary.setText("#e91e63")
    g.secondary.setText("#00bcd4")
    board = _board_texts(g)
    d = theme.derive("#e91e63", "#00bcd4")
    for token in ("--sd-primary-bright", "--sd-primary-dim", "--sd-primary-soft",
                  "--sd-secondary-soft"):
        assert d[token] in board, f"{token}={d[token]} missing from the board"
    assert ":1 AA" in board            # live-measured ratios, not a static claim
    soft = d["--sd-primary-soft"]
    assert f"{theme.contrast_ratio(soft, theme.SHELL_BG):.2f}:1" in board


def test_group_slots_never_raise_on_garbage_and_show_the_reason(qapp):
    g = LoginThemeGroup()
    g.primary.setText("not a colour")   # textChanged slot fires _refresh + compose
    assert g.compose_css() == ""
    assert "not an #RRGGBB" in g.error_text()
    assert g.error_note.isVisibleTo(g)
    g.primary.setText("#336699")
    assert g.compose_css() != "" and g.error_text() == ""


def test_commit_load_roundtrip(qapp):
    g = LoginThemeGroup()
    g.primary.setText("#336699")
    g.secondary.setText("#996633")
    g.font_preset.setCurrentText("System UI")
    g.font_licence.setText("SIL OFL 1.1")
    g.font_source.setText("https://example.com")
    cfg = ImageConfig()
    g.commit(cfg)
    assert cfg.login_primary_color == "#336699"
    assert cfg.login_secondary_color == "#996633"
    assert cfg.login_font == "System UI"
    g2 = LoginThemeGroup()
    g2.load(cfg)
    assert g2.primary.text() == "#336699"
    assert g2.font_preset.currentText() == "System UI"
    # the "(keep the shipped font)" sentinel round-trips as EMPTY, not as a name.
    cfg2 = ImageConfig()
    LoginThemeGroup().commit(cfg2)
    assert cfg2.login_font == ""


def test_cfg_login_theme_css_matches_the_group_composition(qapp):
    g = LoginThemeGroup()
    g.primary.setText("#336699")
    g.font_preset.setCurrentText("Monospace")
    cfg = ImageConfig()
    g.commit(cfg)
    assert cfg.login_theme_css() == g.compose_css() != ""


def test_preview_button_writes_the_substituted_page_and_opens_it(qapp, tmp_path,
                                                                 monkeypatch):
    import snapdragon_studio.gui.pages._logintheme as lt
    opened = []
    monkeypatch.setattr(lt.QtGui.QDesktopServices, "openUrl",
                        staticmethod(lambda url: opened.append(url) or True))
    monkeypatch.setattr(lt.tempfile, "gettempdir", lambda: str(tmp_path))
    g = LoginThemeGroup()
    g.primary.setText("#e91e63")
    g._open_preview()
    assert len(opened) == 1
    path = opened[0].toLocalFile()
    text = open(path, encoding="utf-8").read()
    assert "--sd-primary: #e91e63;" in text
    assert 'data-testid="login-submit"' in text      # the REAL captured page
    # invalid input: preview refuses (no second write) instead of lying
    g.primary.setText("nope")
    g._open_preview()
    assert len(opened) == 1


def test_real_font_upload_is_validated_and_reaches_the_css(qapp, monkeypatch):
    import glob
    faces = sorted(glob.glob("/usr/share/fonts/**/*.ttf", recursive=True))
    if not faces:
        pytest.skip("no system ttf to exercise the real QFontDatabase path")
    g = LoginThemeGroup()
    g.font_file.setText(faces[0])
    assert g._font_bytes, g.font_note.text()
    assert g._font_family
    css = g.compose_css()
    assert "@font-face" in css and "data:font/ttf;base64," in css
    assert f'"{g._font_family}"' in css
    # junk rejected by the SAME path
    g2 = LoginThemeGroup()
    junk = os.path.join(os.path.dirname(faces[0]), "")  # a dir -> read error
    g2.font_file.setText("/nonexistent/file.woff2")
    assert g2._font_bytes == b"" and "cannot read" in g2.font_note.text()


# ── host: BrandingPage ──────────────────────────────────────────────────────────────
def test_mesh_branding_page_greys_desktop_half_but_login_half_stays_live(qapp):
    cfg = ImageConfig(mode="mesh", role="omnibus", platform="x86")
    page = wizard_mod.BrandingPage(SimpleNamespace(cfg=cfg, generator_dir=GENERATOR_DIR))
    page.initializePage()
    assert not page.form.isEnabled()            # desktop half: greyed (spec 2)
    assert page.login_theme.isEnabled()         # web half: live — the mesh serves it
    assert page.login_collapsible.is_expanded() # and it IS the page in mesh


def test_login_fields_survive_the_unaffiliated_and_mesh_clears(qapp):
    for cfg in (ImageConfig(mode="mesh", role="omnibus", platform="x86"),
                ImageConfig(mode="standalone", role="unaffiliated", platform="x86")):
        page = wizard_mod.BrandingPage(
            SimpleNamespace(cfg=cfg, generator_dir=GENERATOR_DIR))
        page.initializePage()
        page.login_theme.primary.setText("#336699")
        page.login_theme.secondary.setText("#996633")
        assert page.validatePage()
        assert cfg.login_primary_color == "#336699", cfg.role
        assert cfg.login_secondary_color == "#996633", cfg.role
        # while the desktop-branding clears still fired
        assert cfg.theme == "" and cfg.accent_color == ""


# ── host: LocalMeshPage ─────────────────────────────────────────────────────────────
def _mesh_page(qapp):
    return wizard_mod.LocalMeshPage(
        SimpleNamespace(cfg=ImageConfig(), generator_dir=GENERATOR_DIR,
                        localmesh_selected=True))


def test_collect_bootstrap_carries_the_derived_theme_css(qapp):
    page = _mesh_page(qapp)
    page.login_theme.primary.setText("#e91e63")
    boot_cfg = page.collect_bootstrap()
    assert boot_cfg.login_theme_css == theme.compose_login_css("#e91e63")
    page.login_theme.primary.setText("")
    assert page.collect_bootstrap().login_theme_css == ""


def test_bootstrap_up_refuses_on_a_typoed_colour_instead_of_silently_unthemed(qapp):
    page = _mesh_page(qapp)
    page.ack.setChecked(True)
    page.login_theme.primary.setText("#33669")     # one digit short
    page._bootstrap_up()
    assert "web login theme" in page.status.text()
    assert not page._running                       # nothing launched

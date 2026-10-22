"""The web sign-in look in the window, after the theme move (2026-10-21).

The old mesh-wide "Themes" group (LoginThemeGroup) and its modeless editor
(ThemeEditorDialog) were removed as dead code: the look is chosen on the Look tab of
each domain (row 0 is the mesh's own), by the LookEditor. What this file still pins:
  1. The browser preview's honesty rules, now on the LookEditor's button (the only
     caller of open_platform_preview): a verified open is green and names the file, a
     dispatched-but-unconfirmed open is amber, a total miss is red; every outcome names
     the file; a bad look refuses instead of opening a stale page; pressing again
     rewrites the same file with the new font.
  2. BrandingPage in MESH mode: the desktop half greys, and the web look is NOT here:
     one line points at the Look tab of the mesh's own domain.
  3. The unaffiliated-role / role-class clears may not touch login_* (mesh-plane
     data, image-scope clears).
  4. LocalMeshPage: collect_bootstrap() carries the css derived from the mesh's own
     look (row 0's Look tab), and a typo'd colour REFUSES the verb instead of silently
     shipping an unthemed stack.
  5. The two dead modules stay gone (an import of either fails).
"""
import importlib
import os
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from hugmesh_studio.core import brand_look, platform_preview, theme  # noqa: E402
from hugmesh_studio.core.config import ImageConfig         # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod        # noqa: E402
from hugmesh_studio.gui.pages import _look_shared          # noqa: E402
from hugmesh_studio.gui.pages._lookeditor import LookEditor  # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                # noqa: E402

GENERATOR_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


@pytest.fixture
def qapp():
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    yield app


# ── 5. the dead code stays dead ─────────────────────────────────────────────────────
@pytest.mark.parametrize("name", ["_logintheme", "_theme_editor"])
def test_the_old_theme_group_and_editor_modules_are_gone(name):
    with pytest.raises(ModuleNotFoundError):
        importlib.import_module(f"hugmesh_studio.gui.pages.{name}")


def test_the_look_editor_takes_its_two_helpers_from_the_shared_module():
    from hugmesh_studio.gui.pages import _lookeditor
    assert _lookeditor.open_platform_preview is _look_shared.open_platform_preview
    assert _lookeditor.populate_preset_combo is _look_shared.populate_preset_combo


# ── 1. the preview button's honesty rules, on the LookEditor ─────────────────────────
def _editor(primary="#e91e63"):
    ed = LookEditor(brand_look.Look(), path="docker")
    if primary:
        assert ed.model.try_set("primary", primary).ok
    return ed


def test_preview_button_writes_the_platform_page_and_opens_it(qapp, tmp_path,
                                                              monkeypatch):
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path))   # -> preview_out_dir()
    opened = []
    monkeypatch.setattr(_look_shared.login_preview, "open_in_browser",
                        lambda p: (bool(opened.append(p)) or True,
                                   "verified: test-opener exited 0"))
    # QDesktopServices is the LAST resort (its True is dispatch-only — the
    # historical false-positive); it must not fire when a verified opener worked.
    monkeypatch.setattr(
        _look_shared.QtGui.QDesktopServices, "openUrl",
        staticmethod(lambda url: pytest.fail(
            "QDesktopServices must not run when the verified opener succeeded")))
    ed = _editor("#e91e63")
    ed.preview_btn.click()
    assert len(opened) == 1
    path = opened[0]
    assert path.endswith(platform_preview.PLATFORM_PREVIEW_BASENAME)
    assert str(tmp_path) in path             # stable cache dir, NOT gettempdir()
    text = open(path, encoding="utf-8").read()
    assert "--sd-primary: #e91e63;" in text
    # the REAL captured login page rides along inside the platform page (srcdoc)
    assert "data-testid=&quot;login-submit&quot;" in text
    for pane in ("pane-login", "pane-matrix", "pane-akkoma", "pane-forum"):
        assert f'id="{pane}"' in text
    # result feedback: mechanism + path, selectable for a manual open
    assert "verified" in ed.preview_note.text() and path in ed.preview_note.text()
    assert ed.preview_note.isVisibleTo(ed)


def test_a_bad_look_refuses_the_preview_instead_of_opening_a_stale_page(qapp, tmp_path,
                                                                       monkeypatch):
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path))
    opened = []
    monkeypatch.setattr(_look_shared.login_preview, "open_in_browser",
                        lambda p: (bool(opened.append(p)) or True, "verified: test"))
    ed = _editor(None)

    def _bad_css():
        raise brand_look.LookError("primary: not an #RRGGBB colour")
    monkeypatch.setattr(ed.model, "css", _bad_css)
    ed.preview_btn.click()
    assert opened == []
    assert "Fix the look error" in ed.preview_note.text()
    assert ed.preview_note.isVisibleTo(ed)


def test_preview_button_rewrites_the_artifact_with_the_new_font(qapp, tmp_path,
                                                                monkeypatch):
    """Issue #225 ("the preview button doesn't overwrite the preview file"): change the
    font, press preview again — the SAME artifact must now carry the new font-family
    (old stack gone), in both the outer page and the login iframe."""
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path))
    opened = []
    monkeypatch.setattr(_look_shared.login_preview, "open_in_browser",
                        lambda p: (bool(opened.append(p)) or True,
                                   "verified: test-opener exited 0"))
    ed = _editor(None)
    assert ed.model.try_set("font", "Geometric").ok
    ed.preview_btn.click()
    assert "--sd-font-sans: Avenir" in open(opened[0], encoding="utf-8").read()

    assert ed.model.try_set("font", "Slab serif").ok
    ed.preview_btn.click()
    assert opened[1] == opened[0]                    # same artifact, rewritten
    text = open(opened[1], encoding="utf-8").read()
    assert text.count("--sd-font-sans: Rockwell") == 2   # outer page + iframe srcdoc
    assert "Avenir" not in text                      # old font family is GONE
    assert opened[1].endswith(platform_preview.PLATFORM_PREVIEW_BASENAME)


def test_preview_feedback_is_never_silent_and_always_names_the_file(qapp, tmp_path,
                                                                    monkeypatch):
    """The operator's actual bug report ("the login page preview isn't working"):
    every open outcome must leave a visible note carrying the file path — verified
    green, dispatched-but-unconfirmed amber, and total-miss red."""
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path))
    monkeypatch.setattr(_look_shared.login_preview, "open_in_browser",
                        lambda p: (False, "no browser opener worked (test)"))
    monkeypatch.setattr(_look_shared.QtGui.QDesktopServices, "openUrl",
                        staticmethod(lambda url: True))
    ed = _editor("#336699")
    ed.preview_btn.click()
    note = ed.preview_note.text()
    assert "cannot be confirmed" in note          # amber: honest about openUrl's True
    assert platform_preview.PLATFORM_PREVIEW_BASENAME in note
    assert "manually" in note
    # total miss: red, still names the file for a manual open
    monkeypatch.setattr(_look_shared.QtGui.QDesktopServices, "openUrl",
                        staticmethod(lambda url: False))
    ed.preview_btn.click()
    note = ed.preview_note.text()
    assert "Could not launch a browser" in note
    assert platform_preview.PLATFORM_PREVIEW_BASENAME in note
    assert ed.preview_note.isVisibleTo(ed)


# ── host: BrandingPage ──────────────────────────────────────────────────────────────
def test_mesh_branding_page_greys_desktop_half_but_login_half_stays_live(qapp):
    cfg = ImageConfig(mode="mesh", role="omnibus", platform="x86")
    page = wizard_mod.BrandingPage(SimpleNamespace(cfg=cfg, generator_dir=GENERATOR_DIR))
    page.initializePage()
    assert not page.form.isEnabled()            # desktop half: greyed (spec 2)
    # web half: no longer here — the page says where it is chosen
    assert not hasattr(page, "login_theme")
    assert page.look_pointer.isVisibleTo(page) and "Look" in page.look_pointer.text()


def test_login_fields_survive_the_unaffiliated_and_mesh_clears(qapp):
    for cfg in (ImageConfig(mode="mesh", role="omnibus", platform="x86"),
                ImageConfig(mode="standalone", role="unaffiliated", platform="x86")):
        page = wizard_mod.BrandingPage(
            SimpleNamespace(cfg=cfg, generator_dir=GENERATOR_DIR))
        # what row 0's Look tab writes (CfgLook writes through to these fields)
        cfg.login_primary_color = "#336699"
        cfg.login_secondary_color = "#996633"
        page.initializePage()
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
    page.mesh_look().set("primary", "#e91e63")      # row 0's Look tab edits this model
    boot_cfg = page.collect_bootstrap()
    assert boot_cfg.login_theme_css == theme.compose_login_css("#e91e63")
    page.mesh_look().set("primary", "")
    assert page.collect_bootstrap().login_theme_css == ""


def test_bootstrap_up_refuses_on_a_typoed_colour_instead_of_silently_unthemed(qapp):
    page = _mesh_page(qapp)
    page.mesh_look().set("primary", "#33669")      # one digit short (the raw verb)
    page._bootstrap_up()
    assert "the look" in page.status.text()        # names where it is fixed
    assert "Look" in page.status.text()
    assert not page._running                       # nothing launched

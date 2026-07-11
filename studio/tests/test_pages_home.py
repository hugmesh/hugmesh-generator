"""WS5 page surface — BrandingPage's branding-dir / colour-scheme / GRUB-theme
pickers (G8/G9/G33), HomePage's archive/seed extras (G31), the external
media-data set (G32) and local login composing WITHOUT --standalone (G28), plus
the NEW SystemPage: baked host identity -H/-T/-u (G26) and the x86 node fallback
credentials --user-password/--root-password as masked SECRET fields (G27).

Runs the REAL wizard on Qt's offscreen platform for the Branding/Home flows;
SystemPage is instantiated directly (it only needs a wiz-like object exposing
``.cfg``) so it stays green before StudioWizard registers the "system" slug.
Skipped whole when no Qt binding is installed — the rest of the suite stays
pure-core.
"""
import os
from types import SimpleNamespace

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("snapdragon_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from snapdragon_studio.core.config import (   # noqa: E402  (after the importorskip gate)
    SECRET_FIELDS, UNAFFILIATED_ROLE, WIZARD_PAGE_SLUGS, ImageConfig,
)
from snapdragon_studio.core.platform_info import HostInfo  # noqa: E402
from snapdragon_studio.gui import wizard as wizard_mod  # noqa: E402
from snapdragon_studio.gui.pages.home import _MEDIA_DEFAULT  # noqa: E402
from snapdragon_studio.gui.pages.system import SystemPage  # noqa: E402
from snapdragon_studio.gui.qt import Qt, QtWidgets  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

# a canned host so wizard construction never probes the machine (docker info &c.)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="snapdragon-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="snapdragon-builder": HOST)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["snapdragon-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()          # offscreen: makes per-widget isVisible() meaningful
    yield w
    w.close()
    w.deleteLater()


def advance_to(wiz, page_cls):
    """Click Next until page_cls is current — failing loudly if the flow stalls."""
    for _ in range(len(WIZARD_PAGE_SLUGS) + 1):
        page = wiz.currentPage()
        if isinstance(page, page_cls):
            return page
        before = wiz.currentId()
        wiz.next()
        assert wiz.currentId() != before, \
            f"flow stuck on {type(page).__name__} (validatePage rejected?)"
    raise AssertionError(f"never reached {page_cls.__name__}")


def pick_role(wiz, role):
    page = advance_to(wiz, wizard_mod.RolePage)
    for i in range(page.roles.count()):
        it = page.roles.item(i)
        if it.data(Qt.ItemDataRole.UserRole)[0] == role:
            page.roles.setCurrentItem(it)
            return page
    raise AssertionError(f"role {role} not offered on RolePage")


def flag_pairs(args):
    """(flag, value) view of an argv for --flag VALUE assertions."""
    return list(zip(args, args[1:]))


# ---- BrandingPage: branding-dir / colour-scheme / GRUB-theme (G8/G9/G33) -------

def test_branding_dir_scheme_grub_theme_collect_on_x86(wiz):
    """G8/G9/G33: the three previously widget-less branding fields collect from
    their pickers and reach the x86 argv (via the CUSTOM branding channel — spec 2's
    preset/custom either/or; selecting custom enables the eight fields)."""
    page = advance_to(wiz, wizard_mod.BrandingPage)
    assert page.form.isEnabled()
    page.rb_custom.setChecked(True)          # custom-branding channel (spec 2)
    assert page.custom_group.isEnabled() and not page.theme.isEnabled()
    page.fields["branding_dir"].setText("/tmp/brand-tree")
    page.fields["grub_theme"].setText("/tmp/grub-theme")
    page.fields["color_scheme"].setText("/tmp/Boogiepop.colors")
    advance_to(wiz, wizard_mod.NetworkPage)
    c = wiz.cfg
    assert c.branding_dir == "/tmp/brand-tree"
    assert c.grub_theme == "/tmp/grub-theme"
    assert c.color_scheme == "/tmp/Boogiepop.colors"
    pairs = flag_pairs(c.to_cli_args())
    assert ("--branding-dir", "/tmp/brand-tree") in pairs
    assert ("--grub-theme", "/tmp/grub-theme") in pairs
    assert ("--color-scheme", "/tmp/Boogiepop.colors") in pairs


def test_branding_dir_scheme_grub_theme_grey_and_clear_on_arm(wiz):
    """G10 pattern: the new branding fields are x86-only emission — they ride the
    form-wide grey on an ARM platform and clear on Next. Driven in CLOUD (a cloud
    rpi5-desktop is a desktop-class image so branding_allowed is True — the grey here
    is purely the PLATFORM axis, and cloud never skips the branding page)."""
    c = wiz.cfg
    c.mode = "cloud"; c.role = "rpi5-desktop"; c.platform = "rpi5"
    c.branding_dir = "/tmp/brand-tree"; c.grub_theme = "/tmp/grub-theme"
    c.color_scheme = "/tmp/Boogiepop.colors"
    wiz.restart()
    page = advance_to(wiz, wizard_mod.BrandingPage)
    assert not page.form.isEnabled()
    advance_to(wiz, wizard_mod.NetworkPage)
    assert c.branding_dir == "" and c.grub_theme == "" and c.color_scheme == ""
    args = c.to_cli_args()
    for flag in ("--branding-dir", "--grub-theme", "--color-scheme"):
        assert flag not in args


def test_branding_dir_scheme_grub_theme_clear_for_unaffiliated(wiz):
    """The unaffiliated role hard-conflicts on ALL branding assets — the new
    fields must join the role's clear-on-validate so a role switch cannot poison
    the argv (config._check_unaffiliated_conflicts lists all three)."""
    c = wiz.cfg
    c.branding_dir = "/tmp/brand-tree"; c.grub_theme = "/tmp/grub-theme"
    c.color_scheme = "/tmp/Boogiepop.colors"
    pick_role(wiz, UNAFFILIATED_ROLE)
    page = advance_to(wiz, wizard_mod.BrandingPage)
    assert page.unaffiliated_note.isVisible()
    advance_to(wiz, wizard_mod.NetworkPage)
    assert c.branding_dir == "" and c.grub_theme == "" and c.color_scheme == ""
    args = c.to_cli_args()   # would raise on any leftover branding asset
    for flag in ("--branding-dir", "--grub-theme", "--color-scheme"):
        assert flag not in args


# ---- BrandingPage: premade-theme XOR custom-branding either/or (spec 2) ---------
# Instantiated directly (the page only needs a wiz-like object exposing .cfg /
# .generator_dir) so these are robust to mesh skipping the branding page in the flow.

def test_branding_preset_channel_blanks_custom_fields(qapp):
    """spec 2: the premade-theme channel commits the theme and BLANKS the eight custom
    fields — a stray value on the disabled custom side can never ride along."""
    cfg = ImageConfig(theme="boogiepop")
    page = wizard_mod.BrandingPage(SimpleNamespace(cfg=cfg, generator_dir=GENERATOR_DIR))
    page.initializePage()
    assert page.rb_preset.isChecked()          # theme-only load selects the preset channel
    assert page.theme.isEnabled() and not page.custom_group.isEnabled()
    page.fields["branding_dir"].setText("/tmp/leak")   # stray value on the disabled side
    assert page.validatePage()
    assert cfg.theme == "boogiepop" and cfg.branding_dir == ""


def test_branding_both_set_resolves_custom_wins(qapp):
    """spec 2: a saved config with BOTH a premade theme AND custom assets → custom
    wins, the theme is cleared, and the reconciliation warning is shown."""
    cfg = ImageConfig(theme="boogiepop", wallpaper="/tmp/w.png")
    page = wizard_mod.BrandingPage(SimpleNamespace(cfg=cfg, generator_dir=GENERATOR_DIR))
    page.initializePage()
    assert page.rb_custom.isChecked()          # custom wins the either/or
    assert not page.both_set_note.isHidden()   # reconciliation warning shown
    assert page.validatePage()
    assert cfg.theme == "" and cfg.wallpaper == "/tmp/w.png"


# ---- HomePage: archive/seed extras (G31) + media-data set (G32) ----------------

def test_home_extras_and_media_collect_on_x86(wiz):
    """G31/G32: archive/seed pickers and the media-data group collect and emit."""
    home = advance_to(wiz, wizard_mod.HomePage)
    home.include_archive.setText("/tmp/home.tar.gz")
    home.seed_code_from.setText("/tmp/checkout")
    home.seed_packages.setText("/tmp/pkgs.list")
    home.media_data.setCurrentText("off")
    home.media_label.setText("media-data")
    home.no_vaults.setChecked(True)
    advance_to(wiz, wizard_mod.BuildPage)
    c = wiz.cfg
    args = c.to_cli_args()
    pairs = flag_pairs(args)
    assert ("--include-home-archive", "/tmp/home.tar.gz") in pairs
    assert ("--home-seed-code-from", "/tmp/checkout") in pairs
    assert ("--seed-packages-from", "/tmp/pkgs.list") in pairs
    assert ("--media-label", "media-data") in pairs
    assert "--no-media-data" in args and "--media-data" not in args
    assert "--no-vaults" in args


def test_media_data_tristate_default_roundtrips(wiz):
    """G32: media-data is tri-state like the proxy stack — the builder default
    (ON) must round-trip as '' and emit neither flag; 'on' forces --media-data."""
    home = advance_to(wiz, wizard_mod.HomePage)
    assert home.media_data.currentText() == _MEDIA_DEFAULT
    advance_to(wiz, wizard_mod.BuildPage)
    c = wiz.cfg
    assert c.media_data == ""
    args = c.to_cli_args()
    assert "--media-data" not in args and "--no-media-data" not in args
    wiz.restart()
    home = advance_to(wiz, wizard_mod.HomePage)
    home.media_data.setCurrentText("on")
    advance_to(wiz, wizard_mod.BuildPage)
    assert c.media_data == "on"
    assert "--media-data" in c.to_cli_args()


def test_home_extras_and_media_grey_and_clear_on_arm(wiz):
    """G10 pattern: the G31/G32 fields are x86-only — greyed on ARM (rows as one
    unit, line edit + Browse…) and force-cleared on Next."""
    c = wiz.cfg
    c.mode = "cloud"; c.role = "rpi5-desktop"; c.platform = "rpi5"
    c.include_home_archive = "/tmp/home.tar.gz"; c.home_seed_code_from = "/tmp/checkout"
    c.seed_packages_from = "/tmp/pkgs.list"
    c.media_data = "off"; c.media_label = "media-data"; c.no_vaults = True
    wiz.restart()
    home = advance_to(wiz, wizard_mod.HomePage)
    for w in (home.include_archive_row, home.seed_code_from_row, home.seed_packages_row,
              home.media_data, home.media_label, home.no_vaults):
        assert not w.isEnabled(), w
    advance_to(wiz, wizard_mod.BuildPage)
    assert c.include_home_archive == "" and c.home_seed_code_from == ""
    assert c.seed_packages_from == ""
    assert c.media_data == "" and c.media_label == "" and c.no_vaults is False
    args = c.to_cli_args()
    for flag in ("--include-home-archive", "--home-seed-code-from",
                 "--seed-packages-from", "--media-data", "--no-media-data",
                 "--media-label", "--no-vaults"):
        assert flag not in args


# ---- HomePage: local login composes WITHOUT --standalone (G28, UI half) --------

def test_local_login_composes_without_standalone_on_arm(wiz):
    """G28: the local user/pass stay live with Standalone unchecked, and a
    customized account reaches an ARM argv WITHOUT --standalone (the builder
    renames/hashes the image's default account)."""
    c = wiz.cfg
    c.mode = "mesh"; c.role = "rpi5-desktop"; c.platform = "rpi5"
    wiz.restart()
    home = advance_to(wiz, wizard_mod.HomePage)
    assert not home.standalone.isChecked()
    assert home.local_user.isEnabled() and home.local_pass.isEnabled()
    home.local_user.setText("gamer")
    home.local_pass.setText("hunter2")
    advance_to(wiz, wizard_mod.BuildPage)
    args = c.to_cli_args()
    assert "--standalone" not in args
    pairs = flag_pairs(args)
    assert ("--local-user", "gamer") in pairs
    assert ("--local-pass", "hunter2") in pairs


# ---- SystemPage: baked identity (G26) + node fallback credentials (G27) --------
# Instantiated directly — the page only needs a wiz-like object exposing .cfg, so
# these stay green before StudioWizard registers the "system" slug.

def _system_page(cfg=None):
    return SystemPage(SimpleNamespace(cfg=cfg or ImageConfig()))


def test_system_identity_collects_and_emits(qapp):
    """G26: -H/--hostname, -T/--timezone, -u/--user collect and reach the argv."""
    page = _system_page()
    page.initializePage()
    assert page.hostname.isEnabled() and page.timezone.isEnabled() and page.user.isEnabled()
    page.hostname.setText("node-1")
    page.timezone.setText("Europe/Berlin")
    page.user.setText("operator")
    assert page.validatePage()
    c = page.wiz.cfg
    assert (c.hostname, c.timezone, c.user) == ("node-1", "Europe/Berlin", "operator")
    pairs = flag_pairs(c.to_cli_args())
    assert ("--hostname", "node-1") in pairs
    assert ("--timezone", "Europe/Berlin") in pairs
    assert ("--user", "operator") in pairs


def test_system_identity_blank_leaves_builder_defaults(qapp):
    """'' = the builder's own role-derived hostname / UTC / default account —
    nothing is emitted for untouched fields."""
    page = _system_page()
    page.initializePage()
    assert page.validatePage()
    args = page.wiz.cfg.to_cli_args()
    for flag in ("--hostname", "--timezone", "--user"):
        assert flag not in args


def test_system_credentials_masked_secret_and_never_saved(qapp):
    """G27: both credentials are masked widgets, live in SECRET_FIELDS, reach the
    live x86 argv — and are BLANKED from the serialized config."""
    page = _system_page()
    assert page.user_password.echoMode() == QtWidgets.QLineEdit.EchoMode.Password
    assert page.root_password.echoMode() == QtWidgets.QLineEdit.EchoMode.Password
    assert "user_password" in SECRET_FIELDS and "root_password" in SECRET_FIELDS
    page.initializePage()
    assert page.user_password.isEnabled() and page.root_password.isEnabled()
    page.user_password.setText("fallback-user-pw")
    page.root_password.setText("fallback-root-pw")
    assert page.validatePage()
    c = page.wiz.cfg
    pairs = flag_pairs(c.to_cli_args())
    assert ("--user-password", "fallback-user-pw") in pairs
    assert ("--root-password", "fallback-root-pw") in pairs
    d = c.to_dict()   # save() path — plaintext secrets must be blanked
    assert d["user_password"] == "" and d["root_password"] == ""


def test_system_credentials_grey_and_clear_on_arm(qapp):
    """G27 platform gate: rpi5's equivalents are deprecated no-ops — the widgets
    grey off-x86 and stale secrets clear, while the all-platform identity fields
    stay live and keep emitting."""
    cfg = ImageConfig(mode="mesh", role="be", platform="rpi5",
                      hostname="node-9", user_password="pw1", root_password="pw2")
    page = _system_page(cfg)
    page.initializePage()
    assert not page.user_password.isEnabled() and not page.root_password.isEnabled()
    assert page.user_password.toolTip()   # the explanatory silent-drop tooltip
    assert page.hostname.isEnabled() and page.timezone.isEnabled() and page.user.isEnabled()
    assert page.validatePage()
    assert cfg.user_password == "" and cfg.root_password == ""
    assert cfg.hostname == "node-9"
    args = cfg.to_cli_args()
    assert "--user-password" not in args and "--root-password" not in args
    assert ("--hostname", "node-9") in flag_pairs(args)

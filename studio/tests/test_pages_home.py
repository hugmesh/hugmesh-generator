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

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import timezones  # noqa: E402
from hugmesh_studio.core.config import (   # noqa: E402  (after the importorskip gate)
    SECRET_FIELDS, UNAFFILIATED_ROLE, WIZARD_PAGE_SLUGS, ImageConfig,
    derive_default_user, derive_hostname,
)
from hugmesh_studio.core.platform_info import HostInfo  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod  # noqa: E402
from hugmesh_studio.gui.pages.home import HomePage, _MEDIA_DEFAULT  # noqa: E402
from hugmesh_studio.gui.pages.system import SystemPage  # noqa: E402
from hugmesh_studio.gui.qt import Qt, QtWidgets  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

# a canned host so wizard construction never probes the machine (docker info &c.)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


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
    if not page.select_role(role):
        raise AssertionError(f"role {role} not offered on RolePage")
    return page


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
    # ask 6: the premade picker is a card group in a greyable container now,
    # not a combo — `theme_box` is what the either/or enables/disables.
    assert page.custom_group.isEnabled() and not page.theme_box.isEnabled()
    page.fields["branding_dir"].setText("/tmp/brand-tree")
    page.fields["grub_theme"].setText("/tmp/grub-theme")
    page.fields["color_scheme"].setText("/tmp/Acme.colors")
    advance_to(wiz, wizard_mod.NetworkPage)
    c = wiz.cfg
    assert c.branding_dir == "/tmp/brand-tree"
    assert c.grub_theme == "/tmp/grub-theme"
    assert c.color_scheme == "/tmp/Acme.colors"
    pairs = flag_pairs(c.to_cli_args())
    assert ("--branding-dir", "/tmp/brand-tree") in pairs
    assert ("--grub-theme", "/tmp/grub-theme") in pairs
    assert ("--color-scheme", "/tmp/Acme.colors") in pairs


def test_branding_dir_scheme_grub_theme_grey_and_clear_on_arm(wiz):
    """G10 pattern: the new branding fields are x86-only emission — they ride the
    form-wide grey on an ARM platform and clear on Next. Driven in CLOUD (a cloud
    rpi5-desktop is a desktop-class image so branding_allowed is True — the grey here
    is purely the PLATFORM axis, and cloud never skips the branding page)."""
    c = wiz.cfg
    c.mode = "cloud"; c.role = "rpi5-desktop"; c.platform = "rpi5"
    c.branding_dir = "/tmp/brand-tree"; c.grub_theme = "/tmp/grub-theme"
    c.color_scheme = "/tmp/Acme.colors"
    wiz.restart()
    page = advance_to(wiz, wizard_mod.BrandingPage)
    assert not page.form.isEnabled()
    advance_to(wiz, wizard_mod.NetworkPage)
    assert c.branding_dir == "" and c.grub_theme == "" and c.color_scheme == ""
    args = c.to_cli_args()
    for flag in ("--branding-dir", "--grub-theme", "--color-scheme"):
        assert flag not in args


def test_branding_dir_scheme_grub_theme_clear_for_unaffiliated(wiz):
    """The unaffiliated role hard-conflicts on ALL branding assets — a role switch
    must not poison the argv (config._check_unaffiliated_conflicts lists all three).

    Updated for the unaffiliated-surface fix: the BrandingPage is no longer PART of
    this flow at all (applies_to skips it — a page whose every field is a hard
    conflict has nothing to offer), so the clearing this test used to observe on
    the page's validate now happens at ROLE COMMIT, and the walk below must land on
    the NetworkPage without ever seeing a branding screen. The original assertions
    — fields cleared, argv emittable, no branding flags — are unchanged; only WHERE
    the flow satisfies them moved."""
    c = wiz.cfg
    c.branding_dir = "/tmp/brand-tree"; c.grub_theme = "/tmp/grub-theme"
    c.color_scheme = "/tmp/Acme.colors"
    pick_role(wiz, UNAFFILIATED_ROLE)
    page = advance_to(wiz, wizard_mod.NetworkPage)
    assert not isinstance(page, wizard_mod.BrandingPage)
    # the walk from role -> network must not have passed through BrandingPage
    assert not any(isinstance(wiz.page(i), wizard_mod.BrandingPage)
                   for i in wiz.visitedIds() if i != -1), \
        "the BrandingPage was visited on an unaffiliated flow"
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
    cfg = ImageConfig(theme="dark")
    page = wizard_mod.BrandingPage(SimpleNamespace(cfg=cfg, generator_dir=GENERATOR_DIR))
    page.initializePage()
    assert page.rb_preset.isChecked()          # theme-only load selects the preset channel
    assert page.theme_box.isEnabled() and not page.custom_group.isEnabled()
    page.fields["branding_dir"].setText("/tmp/leak")   # stray value on the disabled side
    assert page.validatePage()
    assert cfg.theme == "dark" and cfg.branding_dir == ""


def test_branding_both_set_resolves_custom_wins(qapp):
    """spec 2: a saved config with BOTH a premade theme AND custom assets → custom
    wins, the theme is cleared, and the reconciliation warning is shown."""
    cfg = ImageConfig(theme="dark", wallpaper="/tmp/w.png")
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
    renames/hashes the image's default account).

    ASK 21 removed the --standalone checkbox from this page ("there is no reason for it
    there"), so the "unchecked" half is now read off the CONFIG, which is what the argv
    is built from anyway — and the pin below proves the widget is really gone rather
    than merely unused."""
    c = wiz.cfg
    c.mode = "mesh"; c.role = "rpi5-desktop"; c.platform = "rpi5"
    wiz.restart()
    # a mesh desktop entry must name its person (operator ask 2026-08-14) before
    # the worklist advances — the pre-checked rpi5-desktop row gets one here.
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    wl._desktop_people["rpi5-desktop.rpi5"] = ("gamer", "user")
    home = advance_to(wiz, wizard_mod.HomePage)
    assert not hasattr(home, "standalone"), "ask 21: the checkbox is still on HomePage"
    assert c.standalone is False
    assert home.local_user.isEnabled() and home.local_pass.isEnabled()
    home.local_user.setText("gamer")
    home.local_pass.setText("hunter2")
    advance_to(wiz, wizard_mod.BuildPage)
    args = c.to_cli_args()
    assert "--standalone" not in args
    pairs = flag_pairs(args)
    assert ("--local-user", "gamer") in pairs
    assert ("--local-pass", "hunter2") in pairs


# ---- HomePage: standalone framing + device-cannot-encrypt (spec 4) -------------

def test_home_standalone_framing_shown_only_on_standalone(wiz):
    """spec 4: on the standalone path the local user + root-disk password read as the
    primary action — the 'this is your login & FDE' helper shows and the group is
    retitled. On a cloud desktop the helper is hidden."""
    home = advance_to(wiz, wizard_mod.HomePage)          # standalone default flow
    assert home.standalone_helper.isVisible()
    assert home.login.title().startswith("Your login")
    c = wiz.cfg
    c.mode = "cloud"; c.role = "desktop"; c.platform = "x86"
    wiz.restart()
    home = advance_to(wiz, wizard_mod.HomePage)
    assert not home.standalone_helper.isVisible()


def test_home_encrypt_hidden_when_device_cannot_encrypt(qapp):
    """spec 4: a device with no FDE path (jetson) HIDES the --encrypt-root checkbox and
    shows a plain reason. encrypt_root is forced off (byte-identical — jetson is excluded
    from encrypt_root emission), but luks_pass (_ALL_PLATFORMS) is NOT cleared. Driven by
    direct instantiation since jetson is not reachable as a standalone/cloud desktop."""
    cfg = ImageConfig(mode="cloud", role="jetson-desktop", platform="jetson",
                      luks_pass="secret")
    page = HomePage(SimpleNamespace(cfg=cfg, generator_dir=GENERATOR_DIR))
    page.initializePage()
    assert not page.encrypt_root.isVisibleTo(page)
    assert page.no_enc_note.isVisibleTo(page)
    assert "cannot do full-disk encryption" in page.no_enc_note.text()
    page.encrypt_root.setChecked(True)                   # even if somehow set
    assert page.validatePage()
    assert cfg.encrypt_root is False                     # forced off (jetson excluded)
    assert cfg.luks_pass == "secret"                     # _ALL_PLATFORMS — not cleared


def test_home_encrypt_checkbox_shown_on_encryptable_platform(qapp):
    """The checkbox stays visible + functional on an FDE-capable platform (x86)."""
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86")
    page = HomePage(SimpleNamespace(cfg=cfg, generator_dir=GENERATOR_DIR))
    page.initializePage()
    assert page.encrypt_root.isVisibleTo(page)
    assert not page.no_enc_note.isVisibleTo(page)
    page.encrypt_root.setChecked(True)
    assert page.validatePage()
    assert cfg.encrypt_root is True
    assert "--encrypt-root" in cfg.to_cli_args()


# ---- SystemPage: baked identity (G26) + node fallback credentials (G27) --------
# Instantiated directly — the page only needs a wiz-like object exposing .cfg, so
# these stay green before StudioWizard registers the "system" slug.

def _system_page(cfg=None):
    return SystemPage(SimpleNamespace(cfg=cfg or ImageConfig()))


def _pick_zone(page, zone):
    """Select a zone in the ask-9 timezone DROPDOWN (adding it first when this host's
    tz database does not carry it, exactly as the page's own seeding does)."""
    i = page.timezone.findText(zone)
    if i < 0:
        page.timezone.addItem(zone)
        i = page.timezone.count() - 1
    page.timezone.setCurrentIndex(i)


def test_system_identity_collects_and_emits(qapp):
    """G26: -H/--hostname, -T/--timezone, -u/--user collect and reach the argv."""
    page = _system_page()
    page.initializePage()
    assert page.hostname.isEnabled() and page.timezone.isEnabled() and page.user.isEnabled()
    page.hostname.setText("node-1")
    _pick_zone(page, "Europe/Berlin")
    page.user.setText("operator")
    assert page.validatePage()
    c = page.wiz.cfg
    assert (c.hostname, c.timezone, c.user) == ("node-1", "Europe/Berlin", "operator")
    pairs = flag_pairs(c.to_cli_args())
    assert ("--hostname", "node-1") in pairs
    assert ("--timezone", "Europe/Berlin") in pairs
    assert ("--user", "operator") in pairs


def test_system_identity_preselects_the_builder_derived_values(qapp):
    """ASK 9 — the three identity fields are no longer blank.

    REPLACES test_system_identity_blank_leaves_builder_defaults, which pinned the OLD
    behaviour (nothing emitted for untouched fields). The operator asked for hostname,
    timezone and default user to be PRESELECTED, so all three now emit — and the
    hostname/user values are exactly what the builder would have derived itself
    (config.derive_hostname / derive_default_user transcribe its role switch), so the
    image is unchanged; only the argv is now explicit. The timezone comes from this
    build HOST, which IS a real change from the builders' UTC default."""
    page = _system_page()
    page.initializePage()
    c = page.wiz.cfg
    assert page.hostname.text() == derive_hostname(c) != ""
    assert page.user.text() == derive_default_user(c) != ""
    assert page.timezone.currentText() == timezones.default_timezone()
    assert page.validatePage()
    pairs = flag_pairs(c.to_cli_args())
    assert ("--hostname", derive_hostname(c)) in pairs
    assert ("--user", derive_default_user(c)) in pairs
    assert ("--timezone", timezones.default_timezone()) in pairs


def test_system_credentials_masked_secret_and_never_saved(qapp):
    """G27: both credentials are masked widgets, live in SECRET_FIELDS, reach the
    live x86 argv — and are BLANKED from the serialized config. Driven on a mesh
    NODE image (the only flow where node fallback creds are meaningful/shown)."""
    page = _system_page(ImageConfig(mode="mesh", role="pki", platform="x86"))
    assert page.user_password.echoMode() == QtWidgets.QLineEdit.EchoMode.Password
    assert page.root_password.echoMode() == QtWidgets.QLineEdit.EchoMode.Password
    assert "user_password" in SECRET_FIELDS and "root_password" in SECRET_FIELDS
    page.initializePage()
    # node-class x86: the group is shown (checked via the shown wizard in the flow
    # tests below; a directly-instantiated page is never shown so isVisible() is False).
    assert page.user_password.isEnabled() and page.root_password.isEnabled()
    # ASK 10: the credentials are an OPT-IN — nothing is collected until it is ticked.
    page.creds_optin.setChecked(True)
    page.user_password.setText("fallback-user-pw")
    page.root_password.setText("fallback-root-pw")
    assert page.validatePage()
    c = page.wiz.cfg
    pairs = flag_pairs(c.to_cli_args())
    assert ("--user-password", "fallback-user-pw") in pairs
    assert ("--root-password", "fallback-root-pw") in pairs
    d = c.to_dict()   # save() path — plaintext secrets must be blanked
    assert d["user_password"] == "" and d["root_password"] == ""


def test_system_credentials_hidden_and_cleared_on_desktop(wiz):
    """spec 3: node fallback creds are meaningless on a personal desktop — the whole
    group is HIDDEN (not greyed) on the standalone/cloud (desktop-class) flow, and any
    stale secret is blanked so it can never ride a desktop image's argv."""
    c = wiz.cfg
    c.user_password = "stale-user"; c.root_password = "stale-root"
    wiz.restart()
    sysp = advance_to(wiz, wizard_mod.SystemPage)   # standalone default flow
    assert not sysp.creds.isVisible()               # hidden entirely on a desktop image
    assert sysp.hostname.isVisible()                # identity fields stay
    advance_to(wiz, wizard_mod.HomePage)
    assert c.user_password == "" and c.root_password == ""
    args = c.to_cli_args()
    assert "--user-password" not in args and "--root-password" not in args


def test_system_credentials_shown_on_mesh_node_flow(wiz):
    """The group reappears on the mesh node (node-class x86) flow — the one place the
    fallback creds are meaningful — proving the hide re-gates per visit."""
    from _helpers import check_worklist_rows
    c = wiz.cfg
    c.mode = "mesh"
    wiz.restart()
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, "pki.x86")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    assert sysp.creds.isVisible()
    assert sysp.user_password.isEnabled() and sysp.root_password.isEnabled()


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


def test_system_credentials_survive_desktop_first_mesh_worklist(wiz):
    """EMISSION GUARD (review HIGH): the mesh creds gate keys on the WORKLIST, never
    the base config. WorklistPage sets the base role to the FIRST checked row, and
    rpi5-desktop (desktop-class) precedes edge_ai in the mesh catalog — keying on the
    base would hide the group AND clear the typed creds even though the x86 edge_ai
    NODE image consumes --user-password/--root-password. The materialized x86 argv
    must carry both flags, exactly as the pre-clarity page emitted them."""
    from _helpers import check_worklist_rows
    c = wiz.cfg
    c.mode = "mesh"
    wiz.restart()
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, "rpi5-desktop.rpi5", "edge_ai.x86")
    # a checked desktop must name its person (operator ask 2026-08-14)
    wl._desktop_people["rpi5-desktop.rpi5"] = ("gamer", "user")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    # premise of the regression: the FIRST entry really is desktop-class
    assert wiz.worklist.entries[0].role == "rpi5-desktop"
    assert sysp.creds.isVisible()      # shown: an x86 node row is checked
    sysp.creds_optin.setChecked(True)  # ask 10: opt in before typing
    sysp.user_password.setText("fleet-user-pw")
    sysp.root_password.setText("fleet-root-pw")
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert c.user_password == "fleet-user-pw"      # role-class clear must NOT fire
    node_argv = next(cfg.to_cli_args() for e, cfg in build._materialized
                     if e.platform == "x86")
    pairs = flag_pairs(node_argv)
    assert ("--user-password", "fleet-user-pw") in pairs
    assert ("--root-password", "fleet-root-pw") in pairs
    # ...and the ARM desktop row never picks the flags up (per-entry strip)
    arm_argv = next(cfg.to_cli_args() for e, cfg in build._materialized
                    if e.platform == "rpi5")
    assert "--user-password" not in arm_argv and "--root-password" not in arm_argv


def test_system_credentials_hidden_and_cleared_on_all_arm_worklist(wiz):
    """spec 3 twin of the desktop-first case: an ALL-ARM node worklist consumes the
    fallback creds on no entry (rpi5's equivalents are deprecated no-ops), so the
    group must HIDE — not show a control whose value would be silently stripped —
    and stale creds must blank. (The base platform is forced 'x86' for the shared
    option-superset pages, so a base-keyed gate would wrongly SHOW the group.)"""
    from _helpers import check_worklist_rows
    c = wiz.cfg
    c.mode = "mesh"
    c.user_password = "stale-user"; c.root_password = "stale-root"
    wiz.restart()
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, "pki.rpi5", "be.rpi5")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    assert not sysp.creds.isVisible()
    assert sysp.hostname.isVisible()               # identity fields stay
    advance_to(wiz, wizard_mod.HomePage)
    assert c.user_password == "" and c.root_password == ""


def test_system_credentials_survive_going_back_to_add_a_desktop_row(wiz):
    """In-session variant of the desktop-first regression: creds typed while the
    worklist was node-only must survive going BACK and adding a desktop row that
    then sorts first — re-gating on the next System visit keeps the group shown and
    the stored creds intact (they were silently discarded before the fix)."""
    from _helpers import check_worklist_rows
    c = wiz.cfg
    c.mode = "mesh"
    wiz.restart()
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, "edge_ai.x86")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    assert sysp.creds.isVisible()
    sysp.creds_optin.setChecked(True)              # ask 10: opt in before typing
    sysp.user_password.setText("fleet-user-pw")
    sysp.root_password.setText("fleet-root-pw")
    advance_to(wiz, wizard_mod.HomePage)           # validates System -> cfg stores creds
    while not isinstance(wiz.currentPage(), wizard_mod.WorklistPage):
        wiz.back()                                 # back to the worklist...
    check_worklist_rows(wiz.currentPage(), "rpi5-desktop.rpi5", "edge_ai.x86")
    # the freshly-added desktop row needs its person (operator ask 2026-08-14)
    wiz.currentPage()._desktop_people["rpi5-desktop.rpi5"] = ("gamer", "user")
    sysp = advance_to(wiz, wizard_mod.SystemPage)  # ...and forward again
    assert wiz.worklist.entries[0].role == "rpi5-desktop"
    assert sysp.creds.isVisible()
    assert sysp.user_password.text() == "fleet-user-pw"
    advance_to(wiz, wizard_mod.HomePage)
    assert c.user_password == "fleet-user-pw" and c.root_password == "fleet-root-pw"


# ── finding 1 / ASK 21: the Standalone checkbox left this page ──────────────────────
# The finding-1 guards themselves did not go away — they MOVED with the control, to
# tests/test_pages_fields_asks.py (the ask-21 section): the RolePage visibility gate,
# the orangepizero2/2w/zero3/3-lts appliance pins, the standalone-desktop pin, and the
# mesh-node clear are all re-asserted there against their new owner. What stays here is
# the pin that HomePage no longer offers OR WRITES the flag, because a half-move — the
# widget gone but the collect still running, or vice versa — is the failure mode.

def test_home_no_longer_carries_the_standalone_posture(qapp):
    """ASK 21 — "REMOVE the standalone user option from the Home-folder / encryption /
    login step — there is no reason for it there."

    Both halves, because either one alone is a bug: the widget is gone, AND HomePage's
    collect no longer writes ``cfg.standalone`` (it used to be the ONLY writer, so a
    collect left behind would silently zero a loaded appliance config on every visit —
    exactly the finding-1 regression, inverted)."""
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      standalone=True)
    page = HomePage(SimpleNamespace(cfg=cfg, generator_dir=GENERATOR_DIR))
    page.initializePage()
    assert not hasattr(page, "standalone"), "the --standalone checkbox is still on HomePage"
    assert page.validatePage()
    assert cfg.standalone is True, (
        "HomePage still writes cfg.standalone — a loaded standalone config is silently "
        "downgraded to a non-standalone, non-FDE image")
    assert "--standalone" in cfg.to_cli_args()
    # ...and the group it used to head is renamed: it is a LOGIN group now, not an
    # "account posture" group.
    assert page.login.title() == "Your login"


# ── finding 8: the "login" unlock factor on a node image ────────────────────────────

def test_home_login_unlock_factor_not_offered_on_a_node(qapp):
    """The builder writes the login-factor marker from inside its `elif ${ROLE_CLIENT}`
    branch (build-x86-host-stage4.sh:3174-3175), so on a cluster-node role
    `--unlock-keyfile login` writes NO marker — the factor silently does not exist. The
    flag still parses and validates (:1220) so nothing errs, and `--unlock-yubikey login`
    even adds sys-auth/pam-u2f to the package set at :3561, which is NOT role-gated: the
    node emerged a PAM module for a login factor it was never going to have.

    Note this is an ITEM-level gate, not a hidden row: 'boot' stays valid on a node (the
    installer enrolls it as a LUKS keyslot), so only the meaningless choice goes."""
    cfg = ImageConfig(mode="mesh", role="pki", platform="x86")
    page = HomePage(SimpleNamespace(cfg=cfg, generator_dir=GENERATOR_DIR))
    page.initializePage()
    for combo in (page.unlock_keyfile, page.unlock_yubikey):
        items = [combo.itemText(i) for i in range(combo.count())]
        assert items == ["(off)", "boot"], f"'login' still offered on a node: {items}"


def test_home_login_unlock_factor_offered_on_a_desktop(qapp):
    """The other direction — the gate must not eat the factor on the images that have it."""
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86")
    page = HomePage(SimpleNamespace(cfg=cfg, generator_dir=GENERATOR_DIR))
    page.initializePage()
    for combo in (page.unlock_keyfile, page.unlock_yubikey):
        items = [combo.itemText(i) for i in range(combo.count())]
        assert items == ["(off)", "boot", "login"], items


def test_home_stale_login_factor_dropped_on_collect_not_downgraded(qapp):
    """A 'login' arriving from a LOADED CONFIG (no widget involved) must be dropped, and
    must fall back to (off) — NOT to 'boot'. Downgrading would invent a boot-time factor
    the operator never asked for, which is its own silent-wrong-image bug."""
    cfg = ImageConfig(mode="mesh", role="pki", platform="x86")
    cfg.unlock_keyfile = "login"
    cfg.unlock_yubikey = "login"
    page = HomePage(SimpleNamespace(cfg=cfg, generator_dir=GENERATOR_DIR))
    page.initializePage()
    assert page.validatePage()
    assert cfg.unlock_keyfile == ""
    assert cfg.unlock_yubikey == ""
    argv = cfg.to_cli_args()
    assert "--unlock-keyfile" not in argv and "--unlock-yubikey" not in argv


def test_home_boot_unlock_factor_survives_on_a_node(qapp):
    """'boot' is genuinely valid on a node — the fix must not take it away."""
    cfg = ImageConfig(mode="mesh", role="pki", platform="x86")
    cfg.unlock_keyfile = "boot"
    page = HomePage(SimpleNamespace(cfg=cfg, generator_dir=GENERATOR_DIR))
    page.initializePage()
    assert page.validatePage()
    assert cfg.unlock_keyfile == "boot"
    assert "--unlock-keyfile" in cfg.to_cli_args()

"""Mesh/cloud identity surface of the wizard pages (WS3):

* NetworkPage — headscale URL (G2, out-of-band env delivery), brand-profile -C
  picker (G3), release-state (G4), games-domain (G6), org (G7), the explicit-none /
  all-services sentinels + subtractive exclude list (G13/G14), the per-platform
  services catalog incl. rpi5 infra slugs (G15), mesh agent version pins +
  --skip-tailscale (G29), and the force-off tri-state checkboxes (G34);
* UsersPage — the explicit --person-role picker (G18) and the games roles in the
  per-user role combo (G20);
* DomainsPage — the Domain.optional_services column (G19);
* KeyZipPage/core.keyzip — Secure-Boot key material wired into --keys-usb /
  --secureboot-key/--secureboot-cert (G5's key-zip half).

Runs the REAL wizard on Qt's offscreen platform (test_wizard.py's harness style)
and is skipped whole when no Qt binding is installed.
"""
import os
import zipfile

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("snapdragon_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from snapdragon_studio.core.config import (   # noqa: E402  (after the importorskip gate)
    Domain, OPTIONAL_SERVICES_BY_PLATFORM, OPTIONAL_SERVICES_CHOICES,
    PERSON_ROLE_CHOICES, SERVICES_ALL, SERVICES_NONE, WIZARD_PAGE_SLUGS,
)
from snapdragon_studio.core.platform_info import HostInfo
from snapdragon_studio.gui import wizard as wizard_mod
from snapdragon_studio.gui.pages.users import USER_ROLE_CHOICES
from snapdragon_studio.gui.qt import Qt, QtWidgets

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
            or QtWidgets.QApplication(["snapdragon-studio-identity-tests"]))


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


def back_to(wiz, page_cls):
    for _ in range(len(WIZARD_PAGE_SLUGS) + 1):
        page = wiz.currentPage()
        if isinstance(page, page_cls):
            return page
        wiz.back()
    raise AssertionError(f"never reached {page_cls.__name__} going back")


def pick_mode(wiz, mode):
    page = advance_to(wiz, wizard_mod.ModePage)
    idx = [m for m, _, _ in page.modes].index(mode)
    page.group.button(idx).setChecked(True)
    return page


def pick_role(wiz, role):
    page = advance_to(wiz, wizard_mod.RolePage)
    for i in range(page.roles.count()):
        it = page.roles.item(i)
        if it.data(Qt.ItemDataRole.UserRole)[0] == role:
            page.roles.setCurrentItem(it)
            return page
    raise AssertionError(f"role {role} not offered on RolePage")


def pairs(args):
    return list(zip(args, args[1:]))


# ---- NetworkPage: brand profile / org / games domain / release state (G3/G4/G6/G7) --

def test_identity_widgets_flow_to_the_argv(wiz):
    pick_mode(wiz, "mesh")
    pick_role(wiz, "omnibus")
    net = advance_to(wiz, wizard_mod.NetworkPage)
    net.brand_profile.setText("/tmp/brands/acme.conf")
    net.org.setText("Acme-Org")
    net.games_domain.setText("games.acme.example")
    net.release_state.setCurrentText("internal")
    advance_to(wiz, wizard_mod.KeyZipPage)    # Next past Network collects
    c = wiz.cfg
    assert c.brand_profile == "/tmp/brands/acme.conf"
    assert c.org == "Acme-Org"
    assert c.games_domain == "games.acme.example"
    assert c.release_state == "internal"
    p = pairs(c.to_cli_args())
    assert ("--config", "/tmp/brands/acme.conf") in p
    assert ("--org", "Acme-Org") in p
    assert ("--games-domain", "games.acme.example") in p
    assert ("--release-state", "internal") in p


def test_org_and_release_state_defaults_emit_nothing(wiz):
    pick_mode(wiz, "mesh")
    pick_role(wiz, "omnibus")
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert net.release_state.currentText() == "default"
    assert net.org.text() == "Snapdragon-Systems"
    advance_to(wiz, wizard_mod.KeyZipPage)
    args = wiz.cfg.to_cli_args()
    assert "--org" not in args and "--release-state" not in args and "--config" not in args


def test_release_state_and_games_domain_grey_and_clear_off_x86_rpi5(wiz):
    """G4/G6 are x86+rpi5-only emission — a frite cloud build greys both widgets
    and clears loaded/stale values on Next (the _gating contract)."""
    c = wiz.cfg
    c.mode = "cloud"; c.role = "frite"; c.platform = "frite"
    c.games_domain = "games.acme.example"; c.release_state = "public"
    wiz.restart()
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert not net.games_domain.isEnabled()
    assert not net.release_state.isEnabled()
    assert net.org.isEnabled()               # --org is all-platform (G7)
    assert net.brand_profile.isEnabled()     # -C/--config is all-platform (G3)
    advance_to(wiz, wizard_mod.KeyZipPage)
    assert c.games_domain == "" and c.release_state == ""
    args = c.to_cli_args()
    assert "--games-domain" not in args and "--release-state" not in args


# ---- NetworkPage: headscale URL + agent version pins (G2/G29) -----------------------

def test_headscale_url_reaches_the_config_but_never_the_argv(wiz):
    """G2: HEADSCALE_URL is delivered OUT-OF-BAND (build_driver env passthrough) —
    the widget must fill the field on every platform and no argv element may ever
    carry the URL (there is no builder flag for it)."""
    pick_mode(wiz, "mesh")
    pick_role(wiz, "omnibus")
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert net.headscale_url.isEnabled()      # NON_ARGV field: never platform-greyed
    net.headscale_url.setText("https://hs.acme.example")
    advance_to(wiz, wizard_mod.KeyZipPage)
    assert wiz.cfg.headscale_url == "https://hs.acme.example"
    assert all("hs.acme.example" not in a for a in wiz.cfg.to_cli_args())


def test_headscale_url_stays_enabled_on_arm(wiz):
    pick_mode(wiz, "cloud")
    pick_role(wiz, "frite")
    net = advance_to(wiz, wizard_mod.NetworkPage)
    net.headscale_url.setText("https://hs.acme.example")
    assert net.headscale_url.isEnabled()
    advance_to(wiz, wizard_mod.KeyZipPage)
    assert wiz.cfg.headscale_url == "https://hs.acme.example"   # not cleared: env-delivered


def test_mesh_agent_version_pins_and_skip_tailscale(wiz):
    pick_mode(wiz, "mesh")
    pick_role(wiz, "omnibus")
    net = advance_to(wiz, wizard_mod.NetworkPage)
    net.headscale_version.setText("0.23.0")
    net.tailscale_version.setText("1.66.0")
    net.skip_tailscale.setChecked(True)
    advance_to(wiz, wizard_mod.KeyZipPage)
    p = pairs(wiz.cfg.to_cli_args())
    assert ("--headscale-version", "0.23.0") in p
    assert ("--tailscale-version", "1.66.0") in p
    assert "--skip-tailscale" in wiz.cfg.to_cli_args()


# ---- NetworkPage: services sentinels + exclude list + per-platform catalog ----------

def test_services_explicit_none_sentinel(wiz):
    """G13: 'no optional services' is a REAL choice — emits --optional-services ""
    so the builder's akkoma tuwunel phpbb default is suppressed."""
    pick_mode(wiz, "mesh")
    pick_role(wiz, "omnibus")
    net = advance_to(wiz, wizard_mod.NetworkPage)
    net.services_none.setChecked(True)
    assert not net.services.isEnabled()       # the sentinel replaces the checklist
    advance_to(wiz, wizard_mod.KeyZipPage)
    assert wiz.cfg.optional_services == [SERVICES_NONE]
    assert ("--optional-services", "") in pairs(wiz.cfg.to_cli_args())
    # round-trips back into the same sentinel state
    back_to(wiz, wizard_mod.NetworkPage)
    assert net.services_none.isChecked() and not net.services_all.isChecked()


def test_services_all_sentinel_and_mutual_exclusion(wiz):
    pick_mode(wiz, "mesh")
    pick_role(wiz, "omnibus")
    net = advance_to(wiz, wizard_mod.NetworkPage)
    net.services_none.setChecked(True)
    net.services_all.setChecked(True)         # checking ALL must uncheck NONE
    assert not net.services_none.isChecked()
    advance_to(wiz, wizard_mod.KeyZipPage)
    assert wiz.cfg.optional_services == [SERVICES_ALL]
    args = wiz.cfg.to_cli_args()
    assert "--all-services" in args and "--optional-services" not in args


def test_exclude_services_subtractive_list(wiz):
    """G14: the subtractive --exclude-services list (applied last — the only way to
    subtract a brand.conf-injected slug) accepts space or comma separation."""
    pick_mode(wiz, "mesh")
    pick_role(wiz, "omnibus")
    net = advance_to(wiz, wizard_mod.NetworkPage)
    net.exclude.setText("akkoma, phpbb")
    advance_to(wiz, wizard_mod.KeyZipPage)
    assert wiz.cfg.exclude_services == ["akkoma", "phpbb"]
    assert ("--exclude-services", "akkoma phpbb") in pairs(wiz.cfg.to_cli_args())
    # a loaded config round-trips into the widget (space-normalized on restore)
    wiz.restart()
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert net.exclude.text() == "akkoma phpbb"


def test_untouched_services_still_leave_the_builder_default(wiz):
    """Neither sentinel + an empty checklist emits NOTHING (the builder default
    applies) — the pre-G13 behavior must not regress."""
    pick_mode(wiz, "mesh")
    pick_role(wiz, "omnibus")
    advance_to(wiz, wizard_mod.KeyZipPage)
    assert wiz.cfg.optional_services == []
    args = wiz.cfg.to_cli_args()
    assert "--optional-services" not in args and "--all-services" not in args


def test_rpi5_services_catalog_offers_infra_slugs(wiz):
    """G15: the rpi5 catalog adds the infra slugs (tor/egress-vpn/workloadConsole/
    anubis) — the ONLY way to bake a Tor-onion rpi5 node; x86 keeps its user-level
    catalog (it has dedicated --with-tor/--egress-vpn flags instead)."""
    pick_role(wiz, "generic")                 # standalone rpi5
    net = advance_to(wiz, wizard_mod.NetworkPage)
    slugs = [net.services.item(i).text() for i in range(net.services.count())]
    assert slugs == list(OPTIONAL_SERVICES_BY_PLATFORM["rpi5"])
    assert "tor" in slugs and "anubis" in slugs
    for i, slug in enumerate(slugs):
        if slug == "tor":
            net.services.item(i).setCheckState(Qt.CheckState.Checked)
    advance_to(wiz, wizard_mod.HomePage)
    assert ("--optional-services", "tor") in pairs(wiz.cfg.to_cli_args())
    # switching back to an x86 role rebuilds the catalog without the infra slugs
    back_to(wiz, wizard_mod.RolePage)
    pick_role(wiz, "standalone-thick")
    net = advance_to(wiz, wizard_mod.NetworkPage)
    slugs = [net.services.item(i).text() for i in range(net.services.count())]
    assert slugs == list(OPTIONAL_SERVICES_CHOICES)
    assert "tor" not in slugs


# ---- NetworkPage: force-off tri-states (G34) -----------------------------------------

def test_tri_state_force_off_reaches_the_argv(wiz):
    """G34: unchecking a tri-state box FORCES the feature off (--no-*) so a
    brand-profile (-C) default can be overridden from the GUI."""
    pick_mode(wiz, "mesh")
    pick_role(wiz, "omnibus")
    net = advance_to(wiz, wizard_mod.NetworkPage)
    for box in (net.aide, net.edge_ai, net.tor_onion, net.character_studio):
        box.setCheckState(Qt.CheckState.Unchecked)
    advance_to(wiz, wizard_mod.KeyZipPage)
    c = wiz.cfg
    assert (c.aide, c.edge_ai_service, c.tor_onion_service, c.character_studio) \
        == ("off", "off", "off", "off")
    args = c.to_cli_args()
    for flag in ("--no-aide", "--no-edge-ai", "--no-tor", "--no-character-studio"):
        assert flag in args, flag
    # …and fully checked forces them ON
    back_to(wiz, wizard_mod.NetworkPage)
    for box in (net.aide, net.edge_ai, net.tor_onion, net.character_studio):
        box.setCheckState(Qt.CheckState.Checked)
    advance_to(wiz, wizard_mod.KeyZipPage)
    args = c.to_cli_args()
    for flag in ("--with-aide", "--with-tor", "--with-character-studio"):
        assert flag in args, flag
    # omnibus ≠ edge_ai role, so the explicit opt-in emits the flag
    assert "--with-edge-ai" in args


def test_tri_state_part_checked_leaves_the_builder_default(wiz):
    """An untouched tri-state box sits PART-checked and emits NEITHER flag — the
    brand.conf/builder default must round-trip unclobbered (the proxy-stack
    combo's auto rule, extended to the G34 checkboxes)."""
    pick_mode(wiz, "mesh")
    pick_role(wiz, "omnibus")
    net = advance_to(wiz, wizard_mod.NetworkPage)
    for box in (net.aide, net.tor_onion, net.character_studio):
        assert box.checkState() == Qt.CheckState.PartiallyChecked, box.text()
    advance_to(wiz, wizard_mod.KeyZipPage)
    c = wiz.cfg
    assert c.aide is False and c.tor_onion_service is False and c.character_studio is False
    args = c.to_cli_args()
    for flag in ("--with-aide", "--no-aide", "--with-tor", "--no-tor",
                 "--with-character-studio", "--no-character-studio",
                 "--with-edge-ai", "--no-edge-ai"):
        assert flag not in args, flag
    back_to(wiz, wizard_mod.NetworkPage)
    assert net.aide.checkState() == Qt.CheckState.PartiallyChecked


# ---- UsersPage: explicit person-role picker (G18) + games roles (G20) ---------------

def test_person_role_derive_keeps_the_users_table_derivation(wiz):
    pick_mode(wiz, "cloud")                   # default cloud role: desktop (a client)
    users = advance_to(wiz, wizard_mod.UsersPage)
    users._add("alice", "acme.example", "superadmin")
    assert users.person_role.currentText() == "derive"
    advance_to(wiz, wizard_mod.HomePage)
    assert wiz.cfg.person_role == ""
    assert ("--person-role", "superadmin") in pairs(wiz.cfg.to_cli_args())


def test_person_role_explicit_pick_overrides_the_derivation(wiz):
    pick_mode(wiz, "cloud")
    users = advance_to(wiz, wizard_mod.UsersPage)
    users._add("alice", "acme.example", "superadmin")
    users.person_role.setCurrentText("mod")
    advance_to(wiz, wizard_mod.HomePage)
    assert wiz.cfg.person_role == "mod"
    assert ("--person-role", "mod") in pairs(wiz.cfg.to_cli_args())
    back_to(wiz, wizard_mod.UsersPage)        # round-trips into the combo
    assert users.person_role.currentText() == "mod"


def test_person_role_offers_exactly_the_builder_accepted_roles(wiz):
    pick_mode(wiz, "cloud")
    users = advance_to(wiz, wizard_mod.UsersPage)
    items = [users.person_role.itemText(i) for i in range(users.person_role.count())]
    assert items == ["derive", *PERSON_ROLE_CHOICES]


def test_person_role_greys_and_clears_on_arm(wiz):
    """--person-role is an x86-only flag: an rpi5 cloud client greys the picker and
    clears a loaded/stale value on Next (never silently dropped from the argv)."""
    c = wiz.cfg
    c.mode = "cloud"; c.role = "rpi5-desktop"; c.platform = "rpi5"
    c.person_role = "admin"
    wiz.restart()
    users = advance_to(wiz, wizard_mod.UsersPage)
    assert not users.person_role_row.isEnabled()
    advance_to(wiz, wizard_mod.HomePage)
    assert c.person_role == ""
    assert "--person-role" not in c.to_cli_args()


def test_user_role_combo_offers_the_grantable_games_roles(wiz):
    """G20: the per-user role combo carries the grantable games roles (games /
    games-services) — the derived Casdoor intersection roles stay excluded."""
    pick_mode(wiz, "mesh")
    users = advance_to(wiz, wizard_mod.UsersPage)
    users._add("bob", "acme.example", "games")
    combo = users.table.cellWidget(0, 2)
    assert [combo.itemText(i) for i in range(combo.count())] == list(USER_ROLE_CHOICES)
    assert combo.currentText() == "games"
    assert "games-admin" not in USER_ROLE_CHOICES        # derived, sync-Job-materialized
    advance_to(wiz, wizard_mod.HomePage)
    assert [u.role for u in wiz.cfg.users] == ["games"]
    # the games role reaches cluster provisioning via the mesh manifest
    assert wiz.cfg.mesh_manifest()["users"][0]["role"] == "games"


# ---- DomainsPage: the Domain.optional_services column (G19) --------------------------

def test_domains_table_round_trips_per_domain_services(wiz):
    c = wiz.cfg
    c.mode = "mesh"; c.role = "omnibus"
    c.domains = [Domain(name="acme.example", title="Acme", games=True,
                        optional_services=["akkoma", "tube"])]
    wiz.restart()
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    assert dom.table.item(0, 3).text() == "akkoma tube"   # loaded config restored
    dom._add("beta.example", "Beta", False, "phpbb, owncast")
    advance_to(wiz, wizard_mod.UsersPage)     # Next past Domains collects the table
    assert [d.optional_services for d in c.domains] == [["akkoma", "tube"],
                                                        ["phpbb", "owncast"]]
    manifest = c.mesh_manifest()
    assert manifest["domains"][1]["optional_services"] == ["phpbb", "owncast"]


# ---- KeyZipPage/core.keyzip: Secure-Boot key wiring (G5) -----------------------------

STAGING = os.path.join(os.path.expanduser("~"), ".snapdragon", "keyzip")


def _import_zip(wiz, zip_path):
    page = wiz.page(wiz._page_ids["keyzip"])
    page.path.setText(str(zip_path))
    page._import()
    return page


def test_keyzip_keys_usb_layout_wires_keys_usb(wiz, tmp_path):
    """A key-zip carrying the builder's KEYS-USB layout (Keys/kernel_key.{pem,der})
    threads the WHOLE staging dir as --keys-usb, so the image signs with the fleet
    Secure-Boot key instead of a per-build throwaway."""
    zp = tmp_path / "acme-keys.zip"
    with zipfile.ZipFile(zp, "w") as zf:
        zf.writestr("Keys/kernel_key.pem", "dummy-pem")
        zf.writestr("Keys/kernel_key.der", "dummy-der")
    page = _import_zip(wiz, zp)
    assert "Secure-Boot signing key" in page.out.text()
    assert wiz.cfg.keys_usb == STAGING
    assert wiz.cfg.secureboot_key == "" and wiz.cfg.secureboot_cert == ""
    assert ("--keys-usb", STAGING) in pairs(wiz.cfg.to_cli_args())


def test_keyzip_loose_key_material_wires_explicit_paths(wiz, tmp_path):
    zp = tmp_path / "acme-keys.zip"
    with zipfile.ZipFile(zp, "w") as zf:
        zf.writestr("secureboot/kernel_key.pem", "dummy-pem")
        zf.writestr("secureboot/kernel_key.der", "dummy-der")
    page = _import_zip(wiz, zp)
    assert "Secure-Boot signing key" in page.out.text()
    assert wiz.cfg.keys_usb == ""
    key = os.path.join(STAGING, "secureboot", "kernel_key.pem")
    cert = os.path.join(STAGING, "secureboot", "kernel_key.der")
    assert wiz.cfg.secureboot_key == key and wiz.cfg.secureboot_cert == cert
    p = pairs(wiz.cfg.to_cli_args())
    assert ("--secureboot-key", key) in p and ("--secureboot-cert", cert) in p


def test_keyzip_prefers_the_keys_usb_layout_over_loose_files(wiz, tmp_path):
    zp = tmp_path / "acme-keys.zip"
    with zipfile.ZipFile(zp, "w") as zf:
        zf.writestr("Keys/kernel_key.pem", "dummy-pem")
        zf.writestr("secureboot/kernel_key.der", "stray-der")
    _import_zip(wiz, zp)
    assert wiz.cfg.keys_usb == STAGING
    assert wiz.cfg.secureboot_cert == ""      # one channel, no mixed chains


def test_keyzip_without_key_material_leaves_sb_fields_alone(wiz, tmp_path):
    zp = tmp_path / "acme-keys.zip"
    with zipfile.ZipFile(zp, "w") as zf:
        zf.writestr("branding/logo.svg", "<svg/>")
    page = _import_zip(wiz, zp)
    assert "Secure-Boot signing key" not in page.out.text()
    assert wiz.cfg.keys_usb == "" and wiz.cfg.secureboot_key == ""
    args = wiz.cfg.to_cli_args()
    assert "--keys-usb" not in args and "--secureboot-key" not in args

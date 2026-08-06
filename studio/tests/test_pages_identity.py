"""Mesh/cloud identity surface of the wizard pages (WS3):

* NetworkPage — headscale URL (G2, out-of-band env delivery), brand-profile -C
  picker (G3), release-state (G4), games-domain (G6), org (G7), the explicit-none /
  all-services whole-set PRESET (G13/G14 — two mutually-exclusive checkboxes until
  ask 23 made it one dropdown), the per-platform services catalog incl. rpi5 infra
  slugs (G15), mesh agent version pins + --skip-tailscale (G29), and the
  definitely-off service checkboxes (G34, two-state since asks 1/4);
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

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import (   # noqa: E402  (after the importorskip gate)
    BUILTIN_DEFAULT_SERVICES, Domain, OPTIONAL_SERVICES_BY_PLATFORM,
    OPTIONAL_SERVICES_CHOICES, PERSON_ROLE_CHOICES, SERVICES_ALL, SERVICES_NONE, User,
    USER_LEVEL_SERVICES, WIZARD_PAGE_SLUGS,
)
from hugmesh_studio.core.platform_info import HostInfo
from hugmesh_studio.gui import wizard as wizard_mod
from hugmesh_studio.gui.pages.network import (   # noqa: E402
    _PRESET_ALL, _PRESET_CUSTOM, _PRESET_NONE, _SVC_COL_NAME,
)
from hugmesh_studio.gui.pages.users import USER_ROLE_CHOICES
from hugmesh_studio.gui.qt import Qt, QtWidgets

# shared wizard-navigation helpers (studio/tests is on sys.path via conftest/pytest);
# consolidated in _helpers so a flow change is edited in ONE place (design 6). mesh now
# skips RolePage, so the mesh identity tests drive their image off the WorklistPage.
from _helpers import (   # noqa: E402
    advance_to, back_to, check_worklist_rows, pairs, pick_mode, pick_role,
)

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
            or QtWidgets.QApplication(["hugmesh-studio-identity-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()          # offscreen: makes per-widget isVisible() meaningful
    yield w
    w.close()
    w.deleteLater()


def mesh_worklist(wiz, *ids):
    """Enter mesh and select the given worklist entry ids on the WorklistPage. Mesh
    skips RolePage — the role x platform multi-select replaces it — so the mesh identity
    tests pin their image here instead of pick_role(). Default: omnibus.x86, an x86 mesh
    node that surfaces every NetworkPage widget the old pick_role(mesh,'omnibus') did."""
    pick_mode(wiz, "mesh")
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, *(ids or ("omnibus.x86",)))
    return wl


# ---- NetworkPage: brand profile / org / games domain / release state (G3/G4/G6/G7) --

def test_identity_widgets_flow_to_the_argv(wiz):
    mesh_worklist(wiz)
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
    mesh_worklist(wiz)
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
    mesh_worklist(wiz)
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
    mesh_worklist(wiz)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    net.headscale_version.setText("0.23.0")
    net.tailscale_version.setText("1.66.0")
    net.skip_tailscale.setChecked(True)
    advance_to(wiz, wizard_mod.KeyZipPage)
    p = pairs(wiz.cfg.to_cli_args())
    assert ("--headscale-version", "0.23.0") in p
    assert ("--tailscale-version", "1.66.0") in p
    assert "--skip-tailscale" in wiz.cfg.to_cli_args()


# ---- NetworkPage: the services TABLE — whole-set preset + per-platform catalog ------
#
# ASK 23 rebuilt this surface as ONE table (gui/pages/network.py services_table), so these
# drive rows instead of a QListWidget and a pair of sentinel checkboxes. What is being
# pinned is unchanged: G13/G14's two whole-set shortcuts really are different builds, and
# G15's rpi5 infra slugs are really reachable.


def _svc_rows(net):
    """Every VISIBLE service slug in the table, in table order — the replacement for the
    old ``[net.services.item(i).text() for i in ...]``. Reads the row items rather than
    ``service_boxes`` so it sees exactly what the operator sees: a row the platform cannot
    express is hidden, and must not count as offered."""
    out = []
    for slug, item in net._svc_items.items():
        if not item.isHidden():
            out.append(slug)
    return out


def test_services_explicit_none_preset(wiz):
    """G13: 'no optional services' is a REAL choice — emits --optional-services ""
    so the builder's akkoma tuwunel phpbb default is suppressed. The two sentinel
    checkboxes are one dropdown since ask 23; the emission is byte-identical."""
    mesh_worklist(wiz)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    net.services_preset.setCurrentIndex(_PRESET_NONE)
    # the preset REPLACES the slug rows, so they grey (a flag-channel row stays live —
    # --optional-services "" does not unset WANT_TOR)
    assert not net.service_boxes["akkoma"].isEnabled()
    advance_to(wiz, wizard_mod.KeyZipPage)
    assert wiz.cfg.optional_services == [SERVICES_NONE]
    assert ("--optional-services", "") in pairs(wiz.cfg.to_cli_args())
    # round-trips back into the same preset
    back_to(wiz, wizard_mod.NetworkPage)
    assert net.services_preset.currentIndex() == _PRESET_NONE


def test_services_all_preset_and_structural_mutual_exclusion(wiz):
    """G14. The mutual exclusion used to be enforced in a toggled SLOT keeping two
    checkboxes out of step with each other; a combo cannot be in two states, so the
    property is now structural. Pinned anyway — it is the behaviour, not the widget,
    that matters."""
    mesh_worklist(wiz)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    net.services_preset.setCurrentIndex(_PRESET_NONE)
    net.services_preset.setCurrentIndex(_PRESET_ALL)
    assert net.services_preset.currentIndex() == _PRESET_ALL      # NONE is gone by construction
    advance_to(wiz, wizard_mod.KeyZipPage)
    assert wiz.cfg.optional_services == [SERVICES_ALL]
    args = wiz.cfg.to_cli_args()
    assert "--all-services" in args and "--optional-services" not in args


def test_exclude_services_is_gone_from_the_gui_but_still_emits(wiz):
    """ASK 2, verbatim: "remove the exclude services field, it makes no sense".

    The WIDGET is gone from every surface. The FIELD and the flag are deliberately kept
    (SURVEY §3): --exclude-services is the only knob that can subtract a slug a brand.conf
    injected straight into OPTIONAL_SERVICES (build-x86-host-stage4.sh, applied last), and
    tests/build-matrix/flag-coverage.sh would need two "no longer a GUI knob" allowlist
    entries if the field went — a claim about the GUI, weakening a builder differ.

    So this pins BOTH halves: no widget anywhere on the page, and a value arriving from a
    saved config / -C / extra flags still emits AND SURVIVES a trip through the page (a
    blind `c.exclude_services = []` in validatePage would silently blank it on every
    Next — the bug this test exists to catch)."""
    mesh_worklist(wiz)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert not hasattr(net, "exclude")
    for le in net.findChildren(QtWidgets.QLineEdit):
        assert "exclude" not in (le.placeholderText() + le.toolTip()).lower()
    # a value from another channel round-trips untouched
    wiz.cfg.exclude_services = ["akkoma", "phpbb"]
    back_to(wiz, wizard_mod.NetworkPage)
    advance_to(wiz, wizard_mod.KeyZipPage)
    assert wiz.cfg.exclude_services == ["akkoma", "phpbb"]
    assert ("--exclude-services", "akkoma phpbb") in pairs(wiz.cfg.to_cli_args())


def test_untouched_services_build_the_builder_default_set_explicitly(wiz):
    """An untouched flow builds EXACTLY the builders' default set — now said out loud on
    the argv instead of by saying nothing.

    This test used to assert the opposite (`optional_services == []`, no flag) and that is
    the behaviour the fix changed, so the replacement pins the property that actually
    mattered: the SERVICE SET is unchanged. `--optional-services "akkoma tuwunel phpbb"`
    resolves to the same three slugs as `${OPTIONAL_SERVICES:-akkoma tuwunel phpbb}`, and
    it is what the three ticked boxes on screen claim. The neither-sentinel half is kept.

    The one real difference, stated rather than glossed: an explicit list also overrides a
    brand profile's own OPTIONAL_SERVICES (built-in < brand.conf < flag), the same trade
    --no-tor already makes."""
    mesh_worklist(wiz)
    advance_to(wiz, wizard_mod.KeyZipPage)
    assert wiz.cfg.optional_services == list(BUILTIN_DEFAULT_SERVICES)
    args = wiz.cfg.to_cli_args()
    assert "--all-services" not in args
    value = dict(pairs(args))["--optional-services"]
    assert value.split() == list(BUILTIN_DEFAULT_SERVICES), (
        f"an untouched mesh asks for {value!r}, not the builders' own default set")


def test_rpi5_services_catalog_offers_infra_slugs(wiz):
    """G15: the rpi5 catalog adds the infra slugs (tor/egress-vpn/workloadConsole/
    anubis) — the ONLY way to bake a Tor-onion rpi5 node; x86 keeps its user-level
    catalog (it has dedicated --with-tor/--egress-vpn flags instead)."""
    pick_role(wiz, "generic")                 # standalone rpi5
    net = advance_to(wiz, wizard_mod.NetworkPage)
    slugs = _svc_rows(net)
    # Every rpi5 catalogue slug is offered. NOT set-EQUALITY: the table is one row per
    # SERVICE, not one row per catalogue entry, so a service the rpi5 builder reaches
    # through its own flag instead of the catalogue is legitimately here too
    # (edge-ai-tts — edge_ai_tts is x86+rpi5 while the rpi5 slug catalogue has no such
    # entry). Asserting equality would be asserting the old one-row-per-slug list back.
    assert set(OPTIONAL_SERVICES_BY_PLATFORM["rpi5"]) <= set(slugs)
    assert "edge-ai-tts" in slugs and net._channel("edge-ai-tts") == "flag"
    assert "tor" in slugs and "anubis" in slugs
    net.service_boxes["tor"].setChecked(True)
    advance_to(wiz, wizard_mod.HomePage)
    # tor rides the rpi5 SLUG channel, so it JOINS the ticked rows in one list. The
    # builders' default set is ticked on arrival (it is genuinely what an untouched build
    # ships), so a Tor-onion Pi is "the usual three PLUS tor" — which is what the screen
    # shows. Asserting the value equals "tor" alone would be asserting that ticking one row
    # silently switched the other three off.
    value = dict(pairs(wiz.cfg.to_cli_args()))["--optional-services"]
    assert "tor" in value.split(), value
    assert set(value.split()) == set(BUILTIN_DEFAULT_SERVICES) | {"tor"}, value
    # switching back to an x86 role re-derives the offered rows without the infra slugs
    back_to(wiz, wizard_mod.RolePage)
    pick_role(wiz, "standalone-thick")
    net = advance_to(wiz, wizard_mod.NetworkPage)
    slugs = _svc_rows(net)
    assert "anubis" not in slugs and "workloadConsole" not in slugs
    # x86 standalone hides tor as well — its channel there is the dedicated flag, which is
    # a cloud/mesh cluster service (see initializePage's mode gate on the FLAG channel)
    assert "tor" not in slugs


def test_rpi5_tor_row_is_live_not_greyed(wiz):
    """REGRESSION. One unified row per service means the row's channel differs per
    platform, and gating it on the DEDICATED FLAG greyed it wherever only the SLUG channel
    exists. `tor` on rpi5 is exactly that (tor_onion_service is x86-only), so the only way
    to bake a Tor-onion Pi node was greyed out. Probe before the fix:

        mesh/pki/rpi5   tor  ON=_/dis
    """
    pick_role(wiz, "generic")                 # standalone rpi5
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert not net._svc_items["tor"].isHidden(), "the rpi5 tor row went missing"
    assert net.service_boxes["tor"].isEnabled(), (
        "the rpi5 tor row is greyed again — G15 says it is the ONLY Tor-onion Pi channel")


# ---- NetworkPage: client-role services honesty note (PR #304 verify follow-up) ------

def test_services_client_note_visible_and_nonblocking_on_a_client_role(wiz):
    """A CLIENT-class role (builder ROLE_CLIENT) never bakes the cluster GitOps
    tree — the builders accept --optional-services but ignore it (build-rpi5's
    plan echoes 'n/a (role=desktop; no cluster GitOps tree baked)'). The services
    box must say so on a cloud rpi5-desktop, WITHOUT gating: the checklist stays
    enabled and the argv emission is unchanged."""
    pick_mode(wiz, "cloud")
    pick_role(wiz, "rpi5-desktop")            # rpi5 ROLE_CLIENT: builder --role desktop
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert net.services_role_note.isVisible()
    assert "IGNORED" in net.services_role_note.text()
    assert "rpi5-desktop" in net.services_role_note.text()
    assert net.services_box.isEnabled()                     # hint, not a gate
    assert net.service_boxes["akkoma"].isEnabled()
    assert net.service_boxes["akkoma"].isChecked()      # a builder default, ticked
    net.service_boxes["owncast"].setChecked(True)
    advance_to(wiz, wizard_mod.KeyZipPage)
    # emission untouched by the note: the builder accepts (and itself ignores) the flag
    value = dict(pairs(wiz.cfg.to_cli_args()))["--optional-services"]
    assert set(value.split()) == set(BUILTIN_DEFAULT_SERVICES) | {"owncast"}, value


def test_services_client_note_visible_on_x86_standalone_desktops(wiz):
    """x86 classifies EVERY non-node role ROLE_CLIENT (config.py G18 /
    X86_NODE_ROLES) — the standalone desktops skip the GitOps tree too, so the
    note shows for them as well."""
    pick_role(wiz, "standalone-thick")        # standalone mode (default), platform x86
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert net.services_role_note.isVisible()
    assert net.service_boxes["akkoma"].isEnabled()


def test_services_client_note_hidden_on_node_roles(wiz):
    """Cluster NODE roles bake the GitOps tree — no note. Covers the x86 node
    class (omnibus) and the rpi5 nuance: standalone 'generic' is NODE-class
    (build-rpi5 leaves ROLE_CLIENT=false for generic/pki/backend/frontend; G16
    exists precisely because generic DOES reach the services)."""
    c = wiz.cfg
    c.mode = "mesh"; c.role = "omnibus"; c.platform = "x86"   # x86 node role (mesh has no RolePage)
    wiz.restart()
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert not net.services_role_note.isVisible()
    # rpi5 node role: restart with a loaded-config style rpi5 'be' mesh build
    c = wiz.cfg
    c.mode = "mesh"; c.role = "be"; c.platform = "rpi5"
    wiz.restart()
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert not net.services_role_note.isVisible()
    # rpi5 standalone 'generic': node-class despite living in standalone mode
    c.mode = "standalone"; c.role = "generic"; c.platform = "rpi5"
    wiz.restart()
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert not net.services_role_note.isVisible()
    assert net.services_box.isEnabled()       # G16: generic still reaches the services


def test_services_client_note_hidden_where_the_platform_has_no_flag(wiz):
    """On a platform whose builder never parses --optional-services (frite) the
    box is greyed by the capability gate with its own tooltip — the client-role
    note must NOT stack a second, contradictory explanation on top."""
    pick_mode(wiz, "cloud")
    pick_role(wiz, "frite")
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert not net.services_box.isEnabled()   # the G12 grey, unchanged
    assert not net.services_role_note.isVisible()


# ---- NetworkPage: force-off tri-states (G34) -----------------------------------------

def test_tri_state_force_off_reaches_the_argv(wiz):
    """G34: unchecking a tri-state box FORCES the feature off (--no-*) so a
    brand-profile (-C) default can be overridden from the GUI."""
    mesh_worklist(wiz)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    for box in (net.aide, net.edge_ai, net.tor_onion, net.character_studio, net.edge_ai_tts):
        box.setChecked(False)
    advance_to(wiz, wizard_mod.KeyZipPage)
    c = wiz.cfg
    assert (c.aide, c.edge_ai_service, c.tor_onion_service, c.character_studio, c.edge_ai_tts) \
        == ("off", "off", "off", "off", "off")
    args = c.to_cli_args()
    for flag in ("--no-aide", "--no-edge-ai", "--no-tor", "--no-character-studio", "--no-edge-ai-tts"):
        assert flag in args, flag
    # …and fully checked forces them ON
    back_to(wiz, wizard_mod.NetworkPage)
    for box in (net.aide, net.edge_ai, net.tor_onion, net.character_studio, net.edge_ai_tts):
        box.setChecked(True)
    advance_to(wiz, wizard_mod.KeyZipPage)
    args = c.to_cli_args()
    for flag in ("--with-aide", "--with-tor", "--with-character-studio", "--with-edge-ai-tts"):
        assert flag in args, flag
    # omnibus ≠ edge_ai role, so the explicit opt-in emits the flag
    assert "--with-edge-ai" in args


def test_no_part_checked_state_survives_anywhere_on_the_page(wiz):
    """The INVERSE of the test this replaces.

    It used to assert that an untouched box sits PART-CHECKED and emits neither flag.
    Ask 1, verbatim: "gui studio should leave optional services and edge ai unchecked
    instead of half checked for default no" — so that state is gone, and its absence is
    the fix rather than a side effect. Pinned by sweeping EVERY service box (plus the two
    named ones that are not catalogue slugs) rather than a hand-listed four, so a service
    added later cannot quietly arrive tri-state — that is exactly how the page grew six of
    them."""
    mesh_worklist(wiz)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    for name, box in (("aide", net.aide), ("edge_ai", net.edge_ai),
                      ("edge_ai_analysis", net.edge_ai_analysis),
                      *net.service_boxes.items()):
        assert not box.isTristate(), f"{name} is still a 3-state box"
        assert box.checkState() != Qt.CheckState.PartiallyChecked, f"{name} is half-checked"
        # DEFINITE, not necessarily OFF: ask 23's rule is "anything off by default is
        # unchecked; pre-check what is genuinely on by default", and the builders' own
        # default set (BUILTIN_DEFAULT_SERVICES) is genuinely on by default. Asserting
        # "everything starts unchecked" here was asserting the box lie in the other
        # direction — see test_the_builtin_default_set_arrives_ticked_and_is_emitted.
        assert box.isChecked() == (name in BUILTIN_DEFAULT_SERVICES), (
            f"{name} does not default to the state the builder would produce")
    advance_to(wiz, wizard_mod.KeyZipPage)
    c = wiz.cfg
    # …and "unchecked" now REACHES the argv as a definite off. That property is what the
    # third state existed for (a brand.conf sourced at build-x86-host-stage4.sh:841, i.e.
    # BEFORE the arg loop, can set WANT_TOR=true), so losing it would have been a real
    # regression rather than a simplification.
    assert (c.aide, c.edge_ai_service, c.tor_onion_service, c.character_studio,
            c.character_forge, c.edge_ai_tts) == ("off",) * 6
    args = c.to_cli_args()
    for flag in ("--no-aide", "--no-edge-ai", "--no-tor", "--no-character-studio",
                 "--no-character-forge", "--no-edge-ai-tts"):
        assert flag in args, f"{flag} missing — unchecked stopped meaning definitely off"
    back_to(wiz, wizard_mod.NetworkPage)
    assert net.aide.checkState() == Qt.CheckState.Unchecked


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


# ---- UsersPage: the domain dropdown + superadmin lock (spec 5/6) ---------------------

def test_users_domain_cell_is_a_dropdown_of_defined_domains(wiz):
    """Spec 6: the per-user Domain cell is a dropdown of the superdomain + every domain
    defined on the Domains page (+ session-added rows), not free text."""
    mesh_worklist(wiz)
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    dom._add("acme.example", "Acme")
    users = advance_to(wiz, wizard_mod.UsersPage)   # Next past Domains defines acme
    users._add("bob", role="user")
    combo = users.table.cellWidget(0, 1)            # the Domain cell is a combo now
    items = [combo.itemText(i) for i in range(combo.count())]
    assert wiz.cfg.effective_superdomain() in items
    assert "acme.example" in items


def test_users_superadmin_locks_domain_to_superdomain(wiz):
    """Spec 5: choosing the superadmin role forces + locks the row's domain to the
    orchestration superdomain; any other role unlocks the dropdown."""
    pick_mode(wiz, "cloud")
    users = advance_to(wiz, wizard_mod.UsersPage)
    users._add("alice", "acme.example", "user")
    dom_combo = users.table.cellWidget(0, 1)
    role_combo = users.table.cellWidget(0, 2)
    assert dom_combo.isEnabled()
    role_combo.setCurrentText("superadmin")
    assert not dom_combo.isEnabled()
    assert dom_combo.currentText() == wiz.cfg.effective_superdomain()
    role_combo.setCurrentText("user")
    assert dom_combo.isEnabled()


def test_users_loaded_undefined_domain_is_flagged(wiz):
    """A loaded user whose domain is not among the defined domains keeps its value,
    suffixed '(not defined)' with an orange warning — never silently rewritten."""
    c = wiz.cfg
    c.mode = "cloud"
    c.domains = [Domain(name="acme.example", title="Acme")]
    c.users = [User(username="bob", domain="ghost.example", role="user")]
    wiz.restart()
    users = advance_to(wiz, wizard_mod.UsersPage)
    combo = users.table.cellWidget(0, 1)
    assert combo.currentText() == "ghost.example (not defined)"
    assert users.warn.isVisible()
    advance_to(wiz, wizard_mod.HomePage)            # Next past Users collects the table
    assert [u.domain for u in c.users] == ["ghost.example"]   # stored raw, not rewritten


# ---- DomainsPage: the Domain.optional_services column (G19) --------------------------

def test_domains_table_round_trips_per_domain_services(wiz):
    c = wiz.cfg
    c.mode = "mesh"; c.role = "omnibus"
    # a loaded row arrives pre-migrated (from_dict maps a truthy legacy games ->
    # optional_services += ["games"]); the Domain dataclass no longer has a games field.
    c.domains = [Domain(name="acme.example", title="Acme",
                        optional_services=["akkoma", "tube"])]
    wiz.restart()
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    assert dom.table.item(0, 2).text() == "akkoma tube"   # services now column 2
    dom._add("beta.example", "Beta", "phpbb, owncast")
    advance_to(wiz, wizard_mod.UsersPage)     # Next past Domains collects the table
    assert [d.optional_services for d in c.domains] == [["akkoma", "tube"],
                                                        ["phpbb", "owncast"]]
    manifest = c.mesh_manifest()
    assert manifest["domains"][1]["optional_services"] == ["phpbb", "owncast"]


def test_domains_default_prefill_seeds_the_cluster_domain(wiz):
    """Spec 4: a fresh cloud Domains page prefills row 0 with the cluster domain (the
    PRIMARY domain — table position defines the first --domains element)."""
    pick_mode(wiz, "cloud")
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    assert dom.table.rowCount() == 1
    assert dom.table.item(0, 0).text() == wiz.cfg.cluster_domain
    assert dom.table.item(0, 1).text() == wiz.cfg.brand_title


def test_domains_applies_to_hidden_in_cloud(wiz):
    """The 'Applies to' picker is a worklist-of-images concept — hidden in cloud where
    the single image attaches implicitly (it is shown in mesh)."""
    pick_mode(wiz, "cloud")
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    assert dom.table.isColumnHidden(3)


def test_domains_applies_to_writes_domain_images(wiz):
    """Spec 4: the mesh 'Applies to' menu writes Domain.images — the worklist entry ids
    a domain attaches to (empty = all eligible); node-role images are offered but
    flagged '(manifest only)' since a node build takes no --domains."""
    mesh_worklist(wiz, "omnibus.x86", "be.rpi5")
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    dom._add("acme.example", "Acme", "", ["omnibus.x86"])
    r = dom.table.rowCount() - 1
    btn = dom.table.cellWidget(r, 3)                # the 'Applies to' cell widget
    assert btn.selected_ids() == ["omnibus.x86"]
    assert "manifest only" in btn._actions["be.rpi5"].text()   # node row flagged
    advance_to(wiz, wizard_mod.UsersPage)           # Next past Domains collects the table
    acme = [d for d in wiz.cfg.domains if d.name == "acme.example"][0]
    assert acme.images == ["omnibus.x86"]


# ---- KeyZipPage/core.keyzip: Secure-Boot key wiring (G5) -----------------------------

STAGING = os.path.join(os.path.expanduser("~"), ".hugmesh", "keyzip")


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

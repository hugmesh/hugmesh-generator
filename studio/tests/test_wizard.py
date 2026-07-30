"""Wizard GUI behavior — mode-gated page flow, the tri-state proxy stack, the
BuildPage ISO/finish widgets (img-size / cached / live-toram / bundle-source),
and the per-platform capability greying (gui/pages/_gating.py: x86-only widgets
disabled + cleared on ARM platforms instead of silently dropping their values).

Runs the REAL wizard on Qt's offscreen platform (no display needed) and is skipped
whole when no Qt binding is installed — the rest of the suite stays pure-core.
"""
import json
import os
import zipfile

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import (   # noqa: E402  (after the importorskip gate)
    ImageConfig, MODE_SKIPPED_PAGES, OPTIONAL_SERVICES_CHOICES, ROLE_CHOICES,
    UNAFFILIATED_ROLE, WIZARD_PAGE_SLUGS, superadmin_plane_applies,
)
from hugmesh_studio.core.local_login_agent import load_manifest  # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo
from hugmesh_studio.gui import wizard as wizard_mod
from hugmesh_studio.gui.qt import Qt, QtWidgets

from _helpers import check_worklist_rows  # noqa: E402

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
    if not page.select_role(role):
        raise AssertionError(f"role {role} not offered on RolePage")
    return page


def pick_platform(role_page, plat):
    if plat not in role_page._machine_buttons:
        raise AssertionError(f"machine card {plat} not present on RolePage")
    role_page.select_machine(plat)


# ---- page catalog / slug map --------------------------------------------------

def test_page_slugs_map_to_the_right_pages(wiz):
    """WIZARD_PAGE_SLUGS is zip'd against the registration order — this pins each
    slug to its page CLASS so a reorder can't silently skip the wrong page. The new
    "worklist" (mesh multi-select) and "progress" (terminal) slugs are included;
    ProgressPage lands in WS-REVIEWUI, so it is None-tolerant until registered."""
    expect = {"welcome": wizard_mod.WelcomePage, "mode": wizard_mod.ModePage,
              "localmesh": wizard_mod.LocalMeshPage, "phone": wizard_mod.PhonePage,
              "quest": wizard_mod.QuestPage,
              "deploy": wizard_mod.DeployPage, "idp": wizard_mod.IdpPage,
              "role": wizard_mod.RolePage, "worklist": wizard_mod.WorklistPage,
              "hardware": wizard_mod.HardwarePage, "branding": wizard_mod.BrandingPage,
              "network": wizard_mod.NetworkPage, "keyzip": wizard_mod.KeyZipPage,
              "domains": wizard_mod.DomainsPage, "users": wizard_mod.UsersPage,
              "system": wizard_mod.SystemPage, "home": wizard_mod.HomePage,
              "build": wizard_mod.BuildPage, "progress": wizard_mod.ProgressPage}
    assert set(expect) == set(WIZARD_PAGE_SLUGS)
    for slug, cls in expect.items():
        if cls is None:      # ProgressPage not landed yet (WS-REVIEWUI creates it)
            assert slug not in wiz._page_ids
            continue
        assert type(wiz.page(wiz._page_ids[slug])) is cls


# ---- RolePage: board/flavor axes round-trip (rpi5 / orangepi5 / orangepizero2) --
# Regression coverage for a real bug: RolePage used to have NO widgets for these
# three platforms' board/flavor axes at all, so initializePage() never restored a
# loaded config's board/flavor into anything visible, and validatePage()'s
# else-branch unconditionally reset cfg.board/cfg.flavor to "" for them — a
# config with platform="rpi5" board="rpi4" (or orangepi5/orangepizero2) silently
# lost that axis the moment the wizard revisited/revalidated RolePage (e.g. via
# "Load config…" -> wiz.restart(), then Next/Back or any BuildPage preview that
# calls collect_all()). check.sh's Qt-free GUI channel never exercises this
# (it drives config.py directly), so this was the ONLY channel with the gap —
# and the only channel with no coverage of it before this test existed.

def test_rpi5_board_survives_a_loaded_config_round_trip(wiz):
    wiz.cfg.mode = "standalone"
    wiz.cfg.role = "generic"
    wiz.cfg.platform = "rpi5"
    wiz.cfg.board = "rpi4"
    wiz.restart()
    page = advance_to(wiz, wizard_mod.RolePage)
    assert page.rpi5_box.isVisible()
    assert page.rpi5_board.currentText() == "rpi4"
    wiz.next()
    assert wiz.cfg.platform == "rpi5"
    assert wiz.cfg.board == "rpi4"


def test_orangepi5_board_and_flavor_survive_a_loaded_config_round_trip(wiz):
    wiz.cfg.mode = "cloud"
    wiz.cfg.role = "orangepi5"
    wiz.cfg.platform = "orangepi5"
    wiz.cfg.board = "orange-pi-5"
    wiz.cfg.flavor = "live"
    wiz.restart()
    page = advance_to(wiz, wizard_mod.RolePage)
    assert page.orangepi5_box.isVisible()
    assert page.orangepi5_board.currentText() == "orange-pi-5"
    assert page.orangepi5_flavor.currentText() == "live"
    wiz.next()
    assert wiz.cfg.platform == "orangepi5"
    assert wiz.cfg.board == "orange-pi-5"
    assert wiz.cfg.flavor == "live"


def test_orangepizero2_flavor_survives_a_loaded_config_round_trip(wiz):
    wiz.cfg.mode = "cloud"
    wiz.cfg.role = "orangepizero2"
    wiz.cfg.platform = "orangepizero2"
    wiz.cfg.flavor = "installer"
    wiz.restart()
    page = advance_to(wiz, wizard_mod.RolePage)
    assert page.orangepizero2_box.isVisible()
    assert page.orangepizero2_flavor.currentText() == "installer"
    wiz.next()
    assert wiz.cfg.platform == "orangepizero2"
    assert wiz.cfg.flavor == "installer"
    assert wiz.cfg.board == ""


def test_orangepizero2w_flavor_survives_a_loaded_config_round_trip(wiz):
    wiz.cfg.mode = "cloud"
    wiz.cfg.role = "orangepizero2w"
    wiz.cfg.platform = "orangepizero2w"
    wiz.cfg.flavor = "installer"
    wiz.restart()
    page = advance_to(wiz, wizard_mod.RolePage)
    assert page.orangepizero2w_box.isVisible()
    assert page.orangepizero2w_flavor.currentText() == "installer"
    wiz.next()
    assert wiz.cfg.platform == "orangepizero2w"
    assert wiz.cfg.flavor == "installer"
    assert wiz.cfg.board == ""


def test_orangepizero3_flavor_survives_a_loaded_config_round_trip(wiz):
    wiz.cfg.mode = "cloud"
    wiz.cfg.role = "orangepizero3"
    wiz.cfg.platform = "orangepizero3"
    wiz.cfg.flavor = "installer"
    wiz.restart()
    page = advance_to(wiz, wizard_mod.RolePage)
    assert page.orangepizero3_box.isVisible()
    assert page.orangepizero3_flavor.currentText() == "installer"
    wiz.next()
    assert wiz.cfg.platform == "orangepizero3"
    assert wiz.cfg.flavor == "installer"
    assert wiz.cfg.board == ""


def test_orangepi3lts_flavor_survives_a_loaded_config_round_trip(wiz):
    wiz.cfg.mode = "cloud"
    wiz.cfg.role = "orangepi3-lts"
    wiz.cfg.platform = "orangepi3-lts"
    wiz.cfg.flavor = "installer"
    wiz.restart()
    page = advance_to(wiz, wizard_mod.RolePage)
    assert page.orangepi3lts_box.isVisible()
    assert page.orangepi3lts_flavor.currentText() == "installer"
    wiz.next()
    assert wiz.cfg.platform == "orangepi3-lts"
    assert wiz.cfg.flavor == "installer"
    assert wiz.cfg.board == ""


def _rpi5_board_items(page):
    return [page.rpi5_board.itemText(i) for i in range(page.rpi5_board.count())]


def test_rpi5_node_role_board_picker_excludes_rpi3(wiz):
    """A node/appliance rpi5 role (standalone 'generic') must NOT offer rpi3 — it is
    desktop-only (1GB RAM), and the builder hard-errors that combo. The picker mirrors
    the builder so the selection can't dead-end (honesty rule)."""
    pick_mode(wiz, "standalone")
    page = pick_role(wiz, "generic")
    pick_platform(page, "rpi5")
    assert page.rpi5_box.isVisible()
    assert _rpi5_board_items(page) == ["rpi5", "rpi4"]
    assert "rpi3" not in _rpi5_board_items(page)


def test_rpi5_desktop_role_board_picker_includes_rpi3(wiz):
    """The desktop rpi5 role (rpi5-desktop) is the ONE rpi5 role that may target rpi3 —
    the picker offers all three boards there."""
    pick_mode(wiz, "cloud")
    page = pick_role(wiz, "rpi5-desktop")
    pick_platform(page, "rpi5")
    assert page.rpi5_box.isVisible()
    assert _rpi5_board_items(page) == ["rpi5", "rpi4", "rpi3"]


def test_chromebook_selectable_as_standalone_desktop(wiz):
    """Discoverability: the Chromebook desktop is pickable in standalone mode (no
    mesh/SSO), not only as a cloud client — and emits a builder-valid command."""
    pick_mode(wiz, "standalone")
    page = pick_role(wiz, "chromebook")   # raises if not offered
    pick_platform(page, "x86")
    wiz.next()
    assert wiz.cfg.role == "chromebook" and wiz.cfg.platform == "x86"
    args = wiz.cfg.to_cli_args()
    assert args[:2] == ["--role", "chromebook"]
    assert "--no-tailscale" in args and "--no-sso" in args


def test_worklist_rpi5_node_rows_exclude_rpi3(wiz):
    """The mesh WorklistPage's per-row board picker gates rpi3 the same way: node rows
    (pki/be/fe on rpi5) offer rpi5/rpi4 only; the rpi5-desktop row offers all three."""
    pick_mode(wiz, "mesh")
    page = advance_to(wiz, wizard_mod.WorklistPage)

    def items(rid):
        combo, _flavor = page._combos[rid]
        return [combo.itemText(i) for i in range(combo.count())]

    for rid in ("pki.rpi5", "be.rpi5", "fe.rpi5"):
        assert items(rid) == ["rpi5", "rpi4"], rid
        assert "rpi3" not in items(rid)
    assert items("rpi5-desktop.rpi5") == ["rpi5", "rpi4", "rpi3"]


def test_rpi5_orangepi5_orangepizero2_boxes_mutually_exclusive(wiz):
    """Only the active platform's board/flavor box is visible — no stale box
    left showing (and no stale value silently applying) after switching."""
    pick_mode(wiz, "cloud")
    page = pick_role(wiz, "orangepi5")
    assert page.orangepi5_box.isVisible()
    assert not page.orangepizero2_box.isVisible()
    assert not page.rpi5_box.isVisible()
    assert not page.frite_box.isVisible()
    assert not page.jetson_box.isVisible()
    page = pick_role(wiz, "orangepizero2")
    assert page.orangepizero2_box.isVisible()
    assert not page.orangepi5_box.isVisible()


# ---- mode-gated page flow ------------------------------------------------------

def test_standalone_flow_skips_admin_pages(wiz):
    """standalone: Welcome→Mode→Role→Hardware→Branding→Network→System→Home→Build —
    the key-zip and superadmin domains/users pages are never routed through (the
    system-identity page is visited in EVERY mode)."""
    seen = []
    for _ in range(len(WIZARD_PAGE_SLUGS)):
        seen.append(type(wiz.currentPage()).__name__)
        if isinstance(wiz.currentPage(), wizard_mod.BuildPage):
            break
        wiz.next()
    assert seen == ["WelcomePage", "ModePage", "RolePage", "HardwarePage",
                    "BrandingPage", "NetworkPage", "SystemPage", "HomePage",
                    "BuildPage"]
    for skipped_slug in MODE_SKIPPED_PAGES["standalone"]:
        assert not wiz.hasVisitedPage(wiz._page_ids[skipped_slug])


def test_phone_side_flow_reaches_terminal_page_and_skips_images(wiz):
    """MDM phone is a non-image side-flow (like localmesh): the radio routes Mode →
    Phone (terminal, nextId==-1), leaves cfg.mode an image mode untouched, and no
    image page (role/hardware/branding/build) is ever visited."""
    pick_mode(wiz, "phone")
    before = wiz.cfg.mode
    page = advance_to(wiz, wizard_mod.PhonePage)
    assert wiz.phone_selected is True
    assert wiz.localmesh_selected is False
    assert wiz.cfg.mode == before                       # phone never sets cfg.mode
    assert page.nextId() == -1 and page.isFinalPage()   # terminal: Finish, no image
    for slug in ("localmesh", "quest", "deploy", "role", "hardware", "branding", "build"):
        assert not wiz.hasVisitedPage(wiz._page_ids[slug])


def test_quest_side_flow_reaches_terminal_page_and_skips_images(wiz):
    """MDM Quest headset is a non-image side-flow (the phone's twin): the radio
    routes Mode → Quest (terminal, nextId==-1), leaves cfg.mode an image mode
    untouched, and no image page (role/hardware/branding/build) — nor the other
    side-flows — is ever visited."""
    pick_mode(wiz, "quest")
    before = wiz.cfg.mode
    page = advance_to(wiz, wizard_mod.QuestPage)
    assert wiz.quest_selected is True
    assert wiz.phone_selected is False
    assert wiz.localmesh_selected is False
    assert wiz.cfg.mode == before                       # quest never sets cfg.mode
    assert page.nextId() == -1 and page.isFinalPage()   # terminal: Finish, no image
    for slug in ("localmesh", "phone", "deploy", "role", "hardware", "branding", "build"):
        assert not wiz.hasVisitedPage(wiz._page_ids[slug])


def test_deploy_side_flow_reaches_terminal_page_and_skips_images(wiz):
    """Cloud deploy is the third non-image side-flow: the radio routes Mode →
    Deploy (terminal, nextId==-1), leaves cfg.mode an image mode untouched, and no
    image page (role/hardware/branding/build) — nor the other side-flows — is ever
    visited."""
    pick_mode(wiz, "deploy")
    before = wiz.cfg.mode
    page = advance_to(wiz, wizard_mod.DeployPage)
    assert wiz.deploy_selected is True
    assert wiz.phone_selected is False
    assert wiz.localmesh_selected is False
    assert wiz.cfg.mode == before                       # deploy never sets cfg.mode
    assert page.nextId() == -1 and page.isFinalPage()   # terminal: Finish, no image
    for slug in ("localmesh", "phone", "quest", "role", "hardware", "branding", "build"):
        assert not wiz.hasVisitedPage(wiz._page_ids[slug])


@pytest.mark.parametrize("mode", ["cloud", "mesh"])
def test_cloud_and_mesh_flows_keep_their_admin_pages(wiz, mode):
    pick_mode(wiz, mode)
    advance_to(wiz, wizard_mod.BuildPage)
    for slug in ("keyzip", "domains", "users"):
        assert wiz.hasVisitedPage(wiz._page_ids[slug])
    # mesh drives its image set off the WorklistPage (a role x platform multi-select)
    # instead of the single-image role/hardware pages; cloud keeps those and skips the
    # worklist (MODE_SKIPPED_PAGES). BrandingPage is VISITED in mesh since the web
    # login-theme section landed there (the mesh serves the login page it themes);
    # its desktop-asset half still greys+clears by role-class (see the greying test).
    if mode == "mesh":
        assert wiz.hasVisitedPage(wiz._page_ids["worklist"])
        for slug in ("role", "hardware"):
            assert not wiz.hasVisitedPage(wiz._page_ids[slug])
        assert wiz.hasVisitedPage(wiz._page_ids["branding"])
    else:
        assert not wiz.hasVisitedPage(wiz._page_ids["worklist"])
        assert wiz.hasVisitedPage(wiz._page_ids["role"])


def test_mesh_worklist_multiselect_builds_entries_and_prunes_domain_refs(wiz):
    """The WorklistPage is the mesh role x platform multi-select: it exposes the checkable
    rows by stable id (``{role}.{platform}``), defaults navigable (the mode-default row
    pre-checked), builds one WorklistEntry per checked row, pins the shared-page gating to
    the x86 option-superset, and prunes an unchecked row's id from every Domain.images."""
    from hugmesh_studio.core.config import Domain

    pick_mode(wiz, "mesh")
    page = advance_to(wiz, wizard_mod.WorklistPage)
    assert {"omnibus.x86", "be.x86", "be.rpi5", "edge_ai.jetson"} <= set(page.rows)
    assert page.row_for_id("be.rpi5") is page.rows["be.rpi5"]
    assert page.isComplete()                       # a default row pre-checked -> navigable

    # a domain attached to two images; one of them (be.rpi5) will be left unchecked
    wiz.cfg.domains = [Domain(name="acme.example", title="Acme",
                              images=["omnibus.x86", "be.rpi5"])]
    for rid in ("omnibus.x86", "be.x86", "be.rpi5", "edge_ai.jetson"):
        page.row_for_id(rid).setCheckState(
            0, Qt.CheckState.Checked if rid in {"omnibus.x86", "be.x86"}
            else Qt.CheckState.Unchecked)
    assert page.validatePage()

    assert {e.id for e in wiz.worklist.entries} == {"omnibus.x86", "be.x86"}
    assert wiz.cfg.role == wiz.worklist.entries[0].role   # first checked row (table order)
    assert wiz.cfg.platform == "x86"                      # option-superset gating
    # be.rpi5 is no longer a checked row, so its attachment is pruned; omnibus.x86 stays
    assert wiz.cfg.domains[0].images == ["omnibus.x86"]


# ---- WorklistPage: per-row encryption scoping (spec 4) -------------------------

def test_worklist_per_row_encryption_column_and_jetson_disabled(wiz):
    """spec 4: each buildable node row gets a default/on/off Encryption combo; the
    jetson row shows a DISABLED 'off — jetson cannot encrypt' cell (no combo). The
    fleet-wide LUKS-passphrase scoping hint is present."""
    pick_mode(wiz, "mesh")
    page = advance_to(wiz, wizard_mod.WorklistPage)
    # a normal node row has an editable combo defaulting to "default" (inherit Home)
    combo = page._enc_combos["be.x86"]
    assert combo is not None
    assert [combo.itemText(i) for i in range(combo.count())] == ["default", "on", "off"]
    assert combo.currentText() == "default"
    # jetson cannot encrypt: no combo, a disabled display cell instead
    assert page._enc_combos["edge_ai.jetson"] is None
    assert "applies to EVERY encrypted node" in page.enc_hint.text()


def test_worklist_untouched_rows_are_byte_identical(wiz):
    """Emission identity: an untouched worklist resolves every row's encrypt_root to
    'default' — exactly as before the per-row column existed (additive default)."""
    pick_mode(wiz, "mesh")
    page = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(page, "pki.x86", "be.x86", "fe.x86")
    assert page.validatePage()
    assert {e.encrypt_root for e in wiz.worklist.entries} == {"default"}


def test_worklist_per_row_encryption_override_flows(wiz):
    """A per-row 'on'/'off' override writes entry.encrypt_root for THAT node only,
    while untouched rows stay 'default' (inherit the base) — the WHICH-device scoping."""
    pick_mode(wiz, "mesh")
    page = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(page, "pki.x86", "be.x86")
    page._enc_combos["pki.x86"].setCurrentText("on")
    page._enc_combos["be.x86"].setCurrentText("off")
    assert page.validatePage()
    by_id = {e.id: e.encrypt_root for e in wiz.worklist.entries}
    assert by_id == {"pki.x86": "on", "be.x86": "off"}


def test_switching_back_to_standalone_clears_stranded_admin_state(wiz):
    """Mesh flow parks domains/users/keyzip in the config; flipping the mode back to
    standalone (whose flow SKIPS those pages) must clear them so state the user can
    no longer reach never leaks into save() or the argv."""
    pick_mode(wiz, "mesh")
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    dom._add("acme.example", "Acme")
    usr = advance_to(wiz, wizard_mod.UsersPage)   # Next past Domains collects the table
    usr._add("bob", "acme.example", "admin")
    advance_to(wiz, wizard_mod.HomePage)          # Next past Users collects the table
    assert [d.name for d in wiz.cfg.domains] == ["acme.example"]
    assert [u.username for u in wiz.cfg.users] == ["bob"]
    back_to(wiz, wizard_mod.ModePage)
    pick_mode(wiz, "standalone")
    advance_to(wiz, wizard_mod.RolePage)          # Next past Mode commits + clears
    assert wiz.cfg.mode == "standalone"
    assert wiz.cfg.domains == [] and wiz.cfg.users == [] and wiz.cfg.keyzip == ""
    args = wiz.cfg.to_cli_args()
    assert "--domains" not in args and "--person-role" not in args


def test_mode_radios_reflect_a_loaded_config(wiz):
    """ModePage.initializePage must re-check the radio from cfg.mode (loaded config /
    restart) — otherwise the constructor's standalone default clobbers it on Next."""
    wiz.cfg.mode = "mesh"
    wiz.cfg.role = "omnibus"
    wiz.restart()
    page = advance_to(wiz, wizard_mod.ModePage)
    assert page.group.checkedButton().property("mode") == "mesh"
    wiz.next()
    assert wiz.cfg.mode == "mesh"


# ---- proxy stack: tri-state, round-trips -----------------------------------------

def test_proxy_stack_auto_survives_a_page_visit(wiz):
    """The old checkbox collapsed auto→on/off on first visit; the combo must leave
    an untouched page at auto — and auto emits neither proxy flag."""
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert net.proxy_stack.currentText() == "auto"
    advance_to(wiz, wizard_mod.HomePage)
    assert wiz.cfg.proxy_stack == "auto"
    args = wiz.cfg.to_cli_args()
    assert "--proxy-stack" not in args and "--no-proxy-stack" not in args
    back_to(wiz, wizard_mod.NetworkPage)
    assert net.proxy_stack.currentText() == "auto"


def test_proxy_stack_explicit_choice_round_trips(wiz):
    net = advance_to(wiz, wizard_mod.NetworkPage)
    net.proxy_stack.setCurrentText("off")
    advance_to(wiz, wizard_mod.HomePage)
    assert wiz.cfg.proxy_stack == "off"
    assert "--no-proxy-stack" in wiz.cfg.to_cli_args()
    back_to(wiz, wizard_mod.NetworkPage)
    assert net.proxy_stack.currentText() == "off"
    net.proxy_stack.setCurrentText("on")
    advance_to(wiz, wizard_mod.HomePage)
    assert wiz.cfg.proxy_stack == "on"
    assert "--proxy-stack" in wiz.cfg.to_cli_args()


# ---- BuildPage: img-size / cached / live-toram / bundle-source --------------------

def test_buildpage_defaults_and_new_widget_emission(wiz):
    build = advance_to(wiz, wizard_mod.BuildPage)
    # defaults mirror the config/builder defaults (standalone: bundle_source ON)
    assert build.img_size.value() == 0 and build.img_size.specialValueText()
    assert not build.cached.isChecked()
    assert build.live_toram.isChecked()
    assert build.bundle_source.isChecked() and build.bundle_source.isEnabled()
    assert not build.bundle_note.isVisible()
    # flip everything, refresh the preview, and check the emitted argv
    build.img_size.setValue(4096)
    build.cached.setChecked(True)
    build.live_toram.setChecked(False)
    build.bundle_source.setChecked(False)
    build._preview()
    c = wiz.cfg
    assert (c.img_size, c.cached, c.live_toram, c.bundle_source) == (4096, True, False, False)
    args = c.to_cli_args()
    assert ("--img-size", "4096") in zip(args, args[1:])
    assert "--cached" in args and "--no-live-toram" in args and "--no-bundle-source" in args
    assert "./build-x86-host-stage4.sh" in build.cmd.toPlainText()


def test_buildpage_bundle_source_default_follows_the_mode(wiz):
    pick_mode(wiz, "cloud")
    build = advance_to(wiz, wizard_mod.BuildPage)
    # cloud: ModePage keeps bundle_source off (the build script's own default)
    assert not build.bundle_source.isChecked() and build.bundle_source.isEnabled()


def test_buildpage_unaffiliated_disables_and_clears_bundle_source(wiz):
    """Unaffiliated role: the bundle-source control greys out with the note shown
    (the BrandingPage pattern) and the config/argv stay clear of the flag pair —
    the preview must succeed (no conflict raised)."""
    pick_role(wiz, UNAFFILIATED_ROLE)
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert not build.bundle_source.isEnabled()
    assert not build.bundle_source.isChecked()
    assert build.bundle_note.isVisible()
    build._preview()
    assert wiz.cfg.bundle_source is False
    args = wiz.cfg.to_cli_args()
    assert "--bundle-source" not in args and "--no-bundle-source" not in args
    assert ("--role", UNAFFILIATED_ROLE) in zip(args, args[1:])
    assert "./build-x86-host-stage4.sh" in build.cmd.toPlainText()


def test_buildpage_unaffiliated_generic_knobs_still_flow(wiz):
    """img-size / cached / live-toram are generic (not affiliation) — they must stay
    usable and emitted on the unaffiliated role."""
    pick_role(wiz, UNAFFILIATED_ROLE)
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.img_size.isEnabled() and build.cached.isEnabled() and build.live_toram.isEnabled()
    build.img_size.setValue(9216)
    build.cached.setChecked(True)
    build._preview()
    args = wiz.cfg.to_cli_args()
    assert ("--img-size", "9216") in zip(args, args[1:]) and "--cached" in args


def test_buildpage_role_detour_round_trips_bundle_source(wiz):
    """unaffiliated → back → a branded standalone role: the control re-enables and
    the user's explicit re-check reaches the argv (no permanently stuck clear)."""
    pick_role(wiz, UNAFFILIATED_ROLE)
    advance_to(wiz, wizard_mod.BuildPage)
    back_to(wiz, wizard_mod.RolePage)
    pick_role(wiz, "standalone-thick")
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.bundle_source.isEnabled() and not build.bundle_note.isVisible()
    build.bundle_source.setChecked(True)
    build._preview()
    assert wiz.cfg.bundle_source is True
    assert "--bundle-source" in wiz.cfg.to_cli_args()


def test_buildpage_iso_knobs_grey_out_off_x86(wiz):
    """The rpi5 generic server: cached/live-toram/bundle-source are x86 ISO knobs the
    arm builders never parse — greyed out, and config.py emits none of them."""
    pick_role(wiz, "generic")
    build = advance_to(wiz, wizard_mod.BuildPage)
    for w in (build.cached, build.live_toram, build.bundle_source):
        assert not w.isEnabled()
    assert build.img_size.isEnabled()      # --img-size IS an arm flag
    build.img_size.setValue(8192)
    build._preview()
    args = wiz.cfg.to_cli_args()
    assert ("--img-size", "8192") in zip(args, args[1:])
    for flag in ("--cached", "--uncached", "--live-toram", "--no-live-toram",
                 "--bundle-source", "--no-bundle-source"):
        assert flag not in args


# ---- per-platform capability gating (G10/G11/G12/G16) --------------------------
# The wizard used to gate widgets by MODE while config.py emits flags by PLATFORM,
# so ~24 x86-only widgets sat un-greyed on ARM and silently dropped their values.
# gui/pages/_gating.py now greys them per the capability table and clears the
# config field on Next; these tests pin both halves plus the G16 inversion
# (services gate on capability, not mode).

def test_network_x86_only_widgets_grey_and_clear_on_arm_cloud(wiz):
    """G10/G12: a frite cloud build shows every x86-only network widget greyed
    (SSO not force-checked into a silently-dropped flag) and clears loaded/stale
    values on Next instead of stranding them into save() or the argv."""
    c = wiz.cfg
    c.mode = "cloud"; c.role = "frite"; c.platform = "frite"
    c.sso = True; c.egress_vpn = "/tmp/egress.conf"; c.aide = True
    c.proxy_stack = "on"; c.tor_onion_service = True; c.edge_ai_service = True
    c.optional_services = ["akkoma"]; c.enable_games = True; c.character_studio = True
    c.edge_ai_tts = True
    wiz.restart()
    net = advance_to(wiz, wizard_mod.NetworkPage)
    for w in (net.sso, net.egress_row, net.egress_locked, net.proxy_stack,
              net.snort, net.aide, net.edge_ai_box, net.tor_onion,
              net.character_studio, net.edge_ai_tts, net.services_box, net.games):
        assert not w.isEnabled(), w
    assert not net.sso.isChecked()      # cloud force-check suppressed off-x86
    assert net.tailscale.isEnabled()    # all-platform knobs stay live
    assert net.root_login.isEnabled()
    advance_to(wiz, wizard_mod.KeyZipPage)   # Next past Network collects + clears
    # sso clears to its dataclass default — the never-set "" tri-state sentinel
    # (mode-default; emits nothing on ARM regardless), not an explicit False
    assert c.sso == "" and c.egress_vpn == "" and c.aide is False
    assert c.proxy_stack == "auto" and c.tor_onion_service is False
    assert c.edge_ai_service is False and c.character_studio is False
    assert c.edge_ai_tts is False
    assert c.optional_services == [] and c.enable_games is False
    args = c.to_cli_args()
    for flag in ("--with-sso", "--egress-vpn", "--with-aide", "--proxy-stack",
                 "--with-tor", "--with-edge-ai", "--with-character-studio",
                 "--with-edge-ai-tts",
                 "--optional-services", "--enable-games"):
        assert flag not in args


def test_network_widgets_reenable_on_switch_back_to_x86(wiz):
    """The grey-out must not be sticky: frite → back → an x86 cloud role restores
    the widgets (including the cloud SSO force-check)."""
    pick_mode(wiz, "cloud")
    pick_role(wiz, "frite")
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert not net.sso.isEnabled()
    back_to(wiz, wizard_mod.RolePage)
    pick_role(wiz, "desktop")
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert net.sso.isEnabled() and net.sso.isChecked()
    for w in (net.egress_row, net.egress_locked, net.proxy_stack, net.snort,
              net.aide, net.edge_ai_box, net.tor_onion, net.character_studio,
              net.edge_ai_tts, net.services_box, net.games):
        assert w.isEnabled(), w


def test_standalone_rpi5_generic_reaches_services_and_games(wiz):
    """G16: the services/games/character-studio/edge-ai-tts boxes gate on platform
    CAPABILITY, not mode — rpi5 emits --optional-services/--enable-games/
    --with-character-studio/--with-edge-ai-tts on every role, and 'generic' (the
    only standalone rpi5 role) must reach them."""
    pick_role(wiz, "generic")            # standalone mode (default), platform rpi5
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert net.services_box.isVisible() and net.services_box.isEnabled()
    assert net.games.isEnabled() and net.character_studio.isEnabled()
    assert net.edge_ai_tts.isEnabled()
    # Node-only surfaces stay mode-gated. Assert the SECTION, not edge_ai_box: the box
    # is the section's collapsible content, so its visibility also means "expanded" —
    # asserting there would pass on a merely-collapsed section and stop pinning the gate.
    assert not net.edge_ai_section.isVisible()
    assert not net.tor_onion.isVisible()
    net.services.item(0).setCheckState(Qt.CheckState.Checked)
    net.games.setChecked(True)
    net.character_studio.setChecked(True)
    net.edge_ai_tts.setChecked(True)
    advance_to(wiz, wizard_mod.HomePage)
    args = wiz.cfg.to_cli_args()
    assert ("--optional-services", OPTIONAL_SERVICES_CHOICES[0]) in zip(args, args[1:])
    assert "--enable-games" in args and "--with-character-studio" in args
    assert "--with-edge-ai-tts" in args


@pytest.mark.parametrize("role", ["frite", "orangepi5", "orangepizero2"])
def test_services_box_greyed_on_non_rpi5_arm_clients(wiz, role):
    """G12: the cluster services/games/character-studio/edge-ai-tts controls stay
    visible but grey on the ARM platforms whose builders don't parse the flags."""
    pick_mode(wiz, "cloud")
    pick_role(wiz, role)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert net.services_box.isVisible() and not net.services_box.isEnabled()
    assert not net.games.isEnabled() and not net.character_studio.isEnabled()
    assert not net.edge_ai_tts.isEnabled()


def test_branding_form_greyed_for_mesh_node(qapp):
    """spec 2 (INVERSION of the old platform-only gate): theming is a DESKTOP-class
    surface — a MESH node can never carry a theme, even on x86. branding_allowed is
    False in mesh regardless of platform, so the whole form greys (by ROLE-CLASS, not
    the platform axis) and every branding field clears on Next.

    The old test asserted an x86 mesh *omnibus* RE-ENABLED the branding form (the
    platform-only gate saw x86 and re-enabled it) — a direct spec-2 contradiction,
    reversed here. Instantiated directly so the assertion survives the flow skipping
    the branding page in mesh (MODE_SKIPPED_PAGES)."""
    from types import SimpleNamespace

    from hugmesh_studio.core.config import ImageConfig
    cfg = ImageConfig(mode="mesh", role="omnibus", platform="x86",
                      theme="boogiepop", wallpaper="/tmp/w.png", brand_locked=True)
    page = wizard_mod.BrandingPage(SimpleNamespace(cfg=cfg, generator_dir=GENERATOR_DIR))
    page.initializePage()
    assert not page.form.isEnabled()          # x86 mesh NODE: greyed by role-class
    assert page.unaffiliated_note.isHidden()  # not the unaffiliated ROLE message
    assert page.validatePage()                # clears on Next (belt & braces)
    assert cfg.theme == "" and cfg.wallpaper == "" and cfg.brand_locked is False
    args = cfg.to_cli_args()
    assert "--theme" not in args and "--wallpaper" not in args and "--brand-locked" not in args


def test_hardware_gpu_and_kernel_builtin_grey_on_arm(wiz):
    """G10: --gpu-driver/--kernel-builtin are x86-only; Wi-Fi/Bluetooth are
    all-platform and must keep flowing to the argv."""
    c = wiz.cfg
    c.gpu_driver = "nvidia"; c.kernel_builtin = True
    pick_role(wiz, "generic")            # standalone rpi5
    hw = advance_to(wiz, wizard_mod.HardwarePage)
    assert not hw.gpu.isEnabled() and not hw.builtin.isEnabled()
    assert hw.wifi.isEnabled() and hw.bt.isEnabled()
    hw.wifi.setChecked(True)
    advance_to(wiz, wizard_mod.BrandingPage)
    assert c.gpu_driver == "auto" and c.kernel_builtin is False
    assert c.enable_wifi is True
    args = c.to_cli_args()
    assert "--gpu-driver" not in args and "--kernel-builtin" not in args
    assert "--enable-wifi" in args


@pytest.mark.skipif(
    "frite" not in {r for r, _, _ in ROLE_CHOICES["standalone"]},
    reason="standalone ARM catalog entries (G17) not landed in ROLE_CHOICES yet")
def test_standalone_frite_role_flows_with_capability_gating(wiz):
    """G17 page-flow side: the new standalone frite catalog entry rides the normal
    standalone flow (admin pages skipped), shows the frite board box, and gets the
    same capability greying a cloud frite build does (services/SSO/branding off)."""
    page = pick_role(wiz, "frite")           # standalone mode (default)
    assert page.frite_box.isVisible() and not page.client_box.isVisible()
    branding = advance_to(wiz, wizard_mod.BrandingPage)
    assert not branding.form.isEnabled()     # x86-only branding assets greyed
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert not net.sso.isEnabled()
    assert net.services_box.isVisible() and not net.services_box.isEnabled()
    advance_to(wiz, wizard_mod.HomePage)     # standalone: keyzip/domains/users skipped
    for skipped_slug in MODE_SKIPPED_PAGES["standalone"]:
        assert not wiz.hasVisitedPage(wiz._page_ids[skipped_slug])
    assert wiz.cfg.platform == "frite" and wiz.cfg.mode == "standalone"
    assert "./build-frite-stage4.sh" in wiz.cfg.to_command_string()


def test_home_provisioning_greys_and_clears_on_arm(wiz):
    """G10: home_* provisioning is x86-only (like the unlock combos, which keep
    their original gating through the shared helper); the local-login group and
    encrypt-root stay live — they land on every platform. This is the ARM-platform-gate
    case (a rpi5 client greys the x86-only home widgets); the x86 node-role role-class
    case is test_home_provisioning_greyed_for_x86_mesh_node."""
    c = wiz.cfg
    c.mode = "cloud"; c.role = "rpi5-desktop"; c.platform = "rpi5"
    c.home_mode = "adopt"; c.home_device = "LABEL=home"
    c.home_encrypted = True; c.home_seed_code = "stack"
    wiz.restart()
    home = advance_to(wiz, wizard_mod.HomePage)
    for w in (home.mode, home.device, home.backup_row, home.encrypted, home.seed,
              home.unlock_keyfile, home.unlock_yubikey):
        assert not w.isEnabled(), w
    assert home.standalone.isEnabled() and home.local_user.isEnabled()
    assert home.encrypt_root.isEnabled() and home.luks_pass.isEnabled()
    advance_to(wiz, wizard_mod.BuildPage)
    assert c.home_mode == "create" and c.home_device == ""
    assert c.home_encrypted is False and c.home_seed_code == "none"
    assert not any(a.startswith("--home-") for a in c.to_cli_args())


def test_home_provisioning_greyed_for_x86_mesh_node(wiz):
    """spec 7 (role-class axis, isolated from the platform gate): home provisioning is
    a DESKTOP-class surface — HIDDEN+cleared on a NODE image even on x86, where the
    platform gate alone would leave every home widget live. Disk-encryption and the
    local-login group stay live (nodes ARE root-encrypted)."""
    c = wiz.cfg
    c.mode = "mesh"; c.role = "omnibus"; c.platform = "x86"
    c.home_mode = "adopt"; c.home_device = "LABEL=home"
    c.home_encrypted = True; c.home_seed_code = "stack"
    wiz.restart()
    home = advance_to(wiz, wizard_mod.HomePage)
    for w in (home.mode, home.device, home.backup_row, home.encrypted, home.seed,
              home.include_archive_row, home.seed_code_from_row, home.seed_packages_row):
        assert not w.isVisible(), w          # role-class HIDE, NOT platform (x86 supports these)
    assert home.encrypt_root.isEnabled() and home.luks_pass.isEnabled()
    assert home.standalone.isEnabled() and home.local_user.isEnabled()
    advance_to(wiz, wizard_mod.BuildPage)
    assert c.home_mode == "create" and c.home_device == ""
    assert c.home_encrypted is False and c.home_seed_code == "none"
    assert not any(a.startswith("--home-") for a in c.to_cli_args())


# ---- dynamic page-skip (nextId applies_to) — emission-neutral -----------------------

def test_superadmin_plane_predicate():
    """The dynamic-skip predicate: mesh always applies; a cloud CLIENT role applies
    (emits --domains/--person-role); a cloud NODE role does not (nothing emitted, no
    manifest); standalone is statically skipped anyway."""
    assert superadmin_plane_applies(ImageConfig(mode="mesh", role="omnibus"))
    assert superadmin_plane_applies(ImageConfig(mode="cloud", role="laptop"))
    assert not superadmin_plane_applies(ImageConfig(mode="cloud", role="be"))
    assert not superadmin_plane_applies(ImageConfig(mode="standalone", role="standalone-thick"))


def test_cloud_node_role_dynamically_skips_domains_and_users(wiz):
    """nextId() skips the superadmin Domains/Users tables for a (loaded) cloud NODE
    build — they contribute no argv there — while a cloud CLIENT keeps them."""
    dom_id = wiz._page_ids["domains"]
    usr_id = wiz._page_ids["users"]
    terminal = {wiz._page_ids["build"], wiz._page_ids["progress"]}
    wiz.cfg = ImageConfig(mode="cloud", role="be", platform="x86", brand="acme",
                          cluster_domain="acme.example")
    assert wiz._dynamically_skipped(dom_id, terminal)
    assert wiz._dynamically_skipped(usr_id, terminal)
    wiz.cfg.role = "laptop"                         # a cloud client emits --domains/--person-role
    assert not wiz._dynamically_skipped(dom_id, terminal)
    assert not wiz._dynamically_skipped(usr_id, terminal)


def test_terminal_pages_never_dynamically_skipped(wiz):
    terminal = {wiz._page_ids["build"], wiz._page_ids["progress"]}
    for slug in ("build", "progress"):
        assert not wiz._dynamically_skipped(wiz._page_ids[slug], terminal)


def test_skipping_domains_users_is_emission_neutral_for_cloud_node(wiz):
    """The ALL-OPTIONS guard: skipping Domains/Users (never visiting them) leaves the
    argv byte-identical to force-visiting them, because a cloud NODE role suppresses
    --domains/--person-role and cloud writes no manifest."""
    base = dict(mode="cloud", role="be", platform="x86", brand="acme",
                cluster_domain="acme.example")
    baseline = ImageConfig(**base).to_cli_args()   # domains/users skipped -> defaults
    visited = ImageConfig(**base)
    wiz.cfg = visited                              # force-visit both superadmin pages
    dom = wiz.page(wiz._page_ids["domains"]); dom.initializePage(); dom.validatePage()
    usr = wiz.page(wiz._page_ids["users"]); usr.initializePage(); usr.validatePage()
    assert visited.to_cli_args() == baseline       # visiting them changed no argv


# ---- NetworkPage: tailnet/SSO + mesh-control-plane role-class reflow (specs 3, 5) ----

def test_tailnet_sso_group_shown_and_superdomain_readonly_in_cloud(wiz):
    """spec 3/5: the Tailnet+SSO group is user-editable (and default-checked) for a
    cloud branded desktop; the mesh control plane shows with the superdomain as a
    read-only DERIVED display (so the Users-page superadmin lock is explicable)."""
    c = wiz.cfg
    c.mode = "cloud"; c.role = "desktop"; c.platform = "x86"
    wiz.restart()
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert net.tailnet_box.isVisible() and not net.tailnet_reason.isVisible()
    assert net.tailscale.isChecked() and net.sso.isChecked()   # default-checked cloud desktop
    assert net.mesh_box.isVisible()
    assert net.superdomain.isReadOnly()
    assert net.superdomain.text() == c.effective_superdomain()


def test_tailnet_and_mesh_groups_hidden_in_standalone(wiz):
    """spec 3: standalone images have no tailnet — the Tailnet+SSO group AND the whole
    mesh control plane are hidden, with a reason label in the tailnet group's place."""
    c = wiz.cfg
    c.mode = "standalone"; c.role = "standalone-thick"; c.platform = "x86"
    wiz.restart()
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert not net.tailnet_box.isVisible()
    assert net.tailnet_reason.isVisible()
    assert not net.mesh_box.isVisible()


def test_superdomain_editable_and_committed_in_mesh(wiz):
    """spec 3/5: mesh HIDES the tailnet/SSO toggles (forced on off-UI in
    enter_mesh_defaults/materialize — this page no longer force-checks them) and makes
    the orchestration superdomain EDITABLE; an explicit value commits to the config."""
    c = wiz.cfg
    c.mode = "mesh"; c.role = "omnibus"; c.platform = "x86"
    wiz.restart()
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert not net.tailnet_box.isVisible()          # forced off-UI, not user-shown
    assert net.mesh_box.isVisible() and not net.superdomain.isReadOnly()
    net.superdomain.setText("core.acme.internal")
    advance_to(wiz, wizard_mod.KeyZipPage)
    assert c.superdomain == "core.acme.internal"


# ---- KeyZipPage: opt-in passwordless-login roles emission ---------------------
# Wiring-level coverage complementing test_keyzip_roles_manifest.py's pure-core
# tests: the checkbox is seeded from (and defaults OFF regardless of)
# StudioWizard's remember_roles_for_passwordless_login constructor arg, and the
# checkbox — not the constructor default — is the actual gate at import time.

_KEYS_SECRETS_JSON = {
    "hugmesh-pki": {
        "casdoor-admin": {"username": "admin", "password": "ADMIN-PLAINTEXT-SECRET"},
        "casdoor-superadmin": {"username": "superadmin", "password": "SUPERADMIN-SECRET-XYZ"},
    },
}


def _make_keys_zip(path):
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("keys/ca.crt", "dummy-ca")
        zf.writestr("vault/secrets.json", json.dumps(_KEYS_SECRETS_JSON))


def test_keyzip_page_checkbox_defaults_off_regardless_of_wizard(qapp):
    """Even when the Studio-level flag is on, a fresh checkbox instance still
    starts from that same explicit value — never silently True by omission."""
    w_off = wizard_mod.StudioWizard(GENERATOR_DIR)
    try:
        assert w_off.remember_roles_for_passwordless_login is False
        page = w_off.page(w_off._page_ids["keyzip"])
        assert page.remember_roles.isChecked() is False
    finally:
        w_off.deleteLater()

    w_on = wizard_mod.StudioWizard(GENERATOR_DIR, remember_roles_for_passwordless_login=True)
    try:
        assert w_on.remember_roles_for_passwordless_login is True
        page = w_on.page(w_on._page_ids["keyzip"])
        assert page.remember_roles.isChecked() is True
    finally:
        w_on.deleteLater()


def test_keyzip_page_import_opt_in_off_writes_no_manifest(qapp, tmp_path):
    zip_path = tmp_path / "acme-keys.zip"
    _make_keys_zip(str(zip_path))
    manifest_path = tmp_path / "roles.json"

    w = wizard_mod.StudioWizard(GENERATOR_DIR, login_manifest_path=str(manifest_path))
    try:
        page = w.page(w._page_ids["keyzip"])
        assert not page.remember_roles.isChecked()   # default OFF
        page.path.setText(str(zip_path))
        page._import()
        assert "Imported" in page.out.text()
        assert "passwordless-login" not in page.out.text()
        assert not manifest_path.exists()
    finally:
        w.deleteLater()


def test_keyzip_page_import_opt_in_on_writes_only_superadmin(qapp, tmp_path):
    zip_path = tmp_path / "acme-keys.zip"
    _make_keys_zip(str(zip_path))
    manifest_path = tmp_path / "roles.json"

    w = wizard_mod.StudioWizard(
        GENERATOR_DIR, remember_roles_for_passwordless_login=True,
        login_manifest_path=str(manifest_path))
    try:
        page = w.page(w._page_ids["keyzip"])
        assert page.remember_roles.isChecked()   # seeded ON from the constructor arg
        page.path.setText(str(zip_path))
        page._import()
        assert "passwordless-login roles remembered: superadmin" in page.out.text()
        m = load_manifest(str(manifest_path))
        assert [r.id for r in m.roles] == ["superadmin"]
        assert "ADMIN-PLAINTEXT-SECRET" not in manifest_path.read_text(encoding="utf-8")
    finally:
        w.deleteLater()


def test_keyzip_page_unchecking_the_box_overrides_the_wizard_default(qapp, tmp_path):
    """The checkbox is the real gate at import time — flipping it off must suppress
    emission even though the wizard was constructed with the flag on."""
    zip_path = tmp_path / "acme-keys.zip"
    _make_keys_zip(str(zip_path))
    manifest_path = tmp_path / "roles.json"

    w = wizard_mod.StudioWizard(
        GENERATOR_DIR, remember_roles_for_passwordless_login=True,
        login_manifest_path=str(manifest_path))
    try:
        page = w.page(w._page_ids["keyzip"])
        page.remember_roles.setChecked(False)
        page.path.setText(str(zip_path))
        page._import()
        assert not manifest_path.exists()
    finally:
        w.deleteLater()

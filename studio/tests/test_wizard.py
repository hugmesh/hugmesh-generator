"""Wizard GUI behavior — mode-gated page flow, the tri-state proxy stack, and the
BuildPage ISO/finish widgets (img-size / cached / live-toram / bundle-source).

Runs the REAL wizard on Qt's offscreen platform (no display needed) and is skipped
whole when no Qt binding is installed — the rest of the suite stays pure-core.
"""
import os

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("snapdragon_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from snapdragon_studio.core.config import (   # noqa: E402  (after the importorskip gate)
    MODE_SKIPPED_PAGES, UNAFFILIATED_ROLE, WIZARD_PAGE_SLUGS,
)
from snapdragon_studio.core.platform_info import HostInfo
from snapdragon_studio.gui import wizard as wizard_mod
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


# ---- page catalog / slug map --------------------------------------------------

def test_page_slugs_map_to_the_right_pages(wiz):
    """WIZARD_PAGE_SLUGS is zip'd against the registration order — this pins each
    slug to its page CLASS so a reorder can't silently skip the wrong page."""
    expect = {"welcome": wizard_mod.WelcomePage, "mode": wizard_mod.ModePage,
              "role": wizard_mod.RolePage, "hardware": wizard_mod.HardwarePage,
              "branding": wizard_mod.BrandingPage, "network": wizard_mod.NetworkPage,
              "keyzip": wizard_mod.KeyZipPage, "domains": wizard_mod.DomainsPage,
              "users": wizard_mod.UsersPage, "home": wizard_mod.HomePage,
              "build": wizard_mod.BuildPage}
    assert set(expect) == set(WIZARD_PAGE_SLUGS)
    for slug, cls in expect.items():
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
    """standalone: Welcome→Mode→Role→Hardware→Branding→Network→Home→Build — the
    key-zip and superadmin domains/users pages are never routed through."""
    seen = []
    for _ in range(len(WIZARD_PAGE_SLUGS)):
        seen.append(type(wiz.currentPage()).__name__)
        if isinstance(wiz.currentPage(), wizard_mod.BuildPage):
            break
        wiz.next()
    assert seen == ["WelcomePage", "ModePage", "RolePage", "HardwarePage",
                    "BrandingPage", "NetworkPage", "HomePage", "BuildPage"]
    for skipped_slug in MODE_SKIPPED_PAGES["standalone"]:
        assert not wiz.hasVisitedPage(wiz._page_ids[skipped_slug])


@pytest.mark.parametrize("mode", ["cloud", "mesh"])
def test_cloud_and_mesh_flows_keep_their_admin_pages(wiz, mode):
    pick_mode(wiz, mode)
    advance_to(wiz, wizard_mod.BuildPage)
    for slug in ("keyzip", "domains", "users"):
        assert wiz.hasVisitedPage(wiz._page_ids[slug])


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
    build.img_size.setValue(6144)
    build.cached.setChecked(True)
    build._preview()
    args = wiz.cfg.to_cli_args()
    assert ("--img-size", "6144") in zip(args, args[1:]) and "--cached" in args


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

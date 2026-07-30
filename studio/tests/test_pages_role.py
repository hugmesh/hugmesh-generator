"""RolePage MACHINE-FIRST rebuild (spec 1) + machine-profile fold (spec 2).

Drives the REAL wizard on Qt's offscreen platform: the machine is chosen as a card,
the image-type (role) list is filtered to that machine, the board/flavor knobs appear
inline, and the machine-profile preset lives with the x86 card (folded off the Hardware
page). The overriding guard is EMISSION IDENTITY — the same user intent must yield the
same cfg.platform/role/board/flavor the old role→platform combo produced.

Skipped whole when no Qt binding is installed (the rest of the suite stays pure-core).
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import ROLE_CHOICES  # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod  # noqa: E402
from hugmesh_studio.gui.qt import Qt  # noqa: E402

from _helpers import advance_to, pick_mode, pick_role, pick_platform  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="session")
def qapp():
    from hugmesh_studio.gui.qt import QtWidgets
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _pickable_devices(role_page):
    """Device ids whose browser row is actually selectable for a build in the current
    mode (the honesty gate: unsupported / zero-role-in-mode rows carry no flags)."""
    return {did for did, item in role_page._device_items.items()
            if item.flags() & Qt.ItemFlag.ItemIsSelectable}


def _role_ids(role_page):
    return [role_page.roles.item(i).data(Qt.ItemDataRole.UserRole)[0]
            for i in range(role_page.roles.count())]


# ---- machine tier = the union of THIS mode's ROLE_CHOICES platforms ----------------

@pytest.mark.parametrize("mode", ["standalone", "cloud"])
def test_pickable_devices_span_the_mode_platform_union(wiz, mode):
    """The PICKABLE device rows span exactly the platform UNION of ROLE_CHOICES[mode] —
    no hardcoded list. jetson is NOT in standalone/cloud (mesh-only), so its devices are
    visible in the browser but never pickable here."""
    from hugmesh_studio.core import device_catalog
    cat = device_catalog.load_catalog()
    pick_mode(wiz, mode)
    page = advance_to(wiz, wizard_mod.RolePage)
    union = {p for _r, plats, _l in ROLE_CHOICES[mode] for p in plats}
    pickable = _pickable_devices(page)
    assert {cat.device(d).builder_platform for d in pickable} == union
    assert union == {"x86", "rpi5", "frite", "orangepi5", "orangepizero2", "orangepizero2w",
                     "orangepizero3"}
    assert not any(cat.device(d).builder_platform == "jetson" for d in pickable)
    # …but the jetson devices are still LISTED (visibility, #351), with the reason text
    assert "orin-nano" in page._device_items
    assert f"no {mode} image" in page._device_items["orin-nano"].text(2)


def test_x86_card_is_default_and_first(wiz):
    """x86 is the default machine (matches today's default-platform behaviour) and sorts
    first among the cards."""
    page = advance_to(wiz, wizard_mod.RolePage)   # standalone default
    assert page._selected_machine() == "x86"
    assert page._all_machines[0] == "x86"


def test_selecting_machine_filters_image_types(wiz):
    """Selecting a machine card repopulates the image-type list to the roles that
    machine supports; Chromebook is an x86 IMAGE-TYPE, not its own card."""
    page = advance_to(wiz, wizard_mod.RolePage)   # standalone, x86 default
    assert "chromebook" in _role_ids(page)        # chromebook rides under the x86 card
    assert "generic" not in _role_ids(page)       # rpi5-only role hidden under x86
    pick_platform(page, "rpi5")
    assert _role_ids(page) == ["generic"]         # only the rpi5 role remains
    assert page.rpi5_box.isVisible() and not page.client_box.isVisible()


def test_experimental_badge_rides_through_device_rows(wiz):
    """#351: the EXPERIMENTAL tagging on the Orange Pi devices rides through — the
    status column carries the badge (with the fail-loud caveat) on every pickable
    experimental device row."""
    pick_mode(wiz, "cloud")
    page = advance_to(wiz, wizard_mod.RolePage)
    for did in ("orange-pi-5", "orange-pi-5-plus", "orange-pi-zero2"):
        assert "EXPERIMENTAL" in page._device_items[did].text(2), did


# ---- EMISSION IDENTITY: machine-first yields the SAME cfg for the same intent ------

def test_emission_identity_x86_standalone_desktop(wiz):
    pick_mode(wiz, "standalone")
    page = pick_role(wiz, "standalone-thick")
    pick_platform(page, "x86")
    advance_to(wiz, wizard_mod.HardwarePage)
    c = wiz.cfg
    assert (c.role, c.platform, c.board, c.flavor) == ("standalone-thick", "x86", "", "")


def test_emission_identity_frite_standalone_installer(wiz):
    pick_mode(wiz, "standalone")
    page = pick_role(wiz, "frite")
    pick_platform(page, "frite")
    assert page.frite_box.isVisible()
    page.flavor.setCurrentText("installer")
    advance_to(wiz, wizard_mod.HardwarePage)
    c = wiz.cfg
    assert (c.role, c.platform, c.flavor) == ("frite", "frite", "installer")
    assert c.board == "la-frite"   # the frite default board


def test_emission_identity_rpi5_desktop_client(wiz):
    pick_mode(wiz, "cloud")
    page = pick_role(wiz, "rpi5-desktop")
    pick_platform(page, "rpi5")
    page.rpi5_board.setCurrentText("rpi4")
    advance_to(wiz, wizard_mod.HardwarePage)
    c = wiz.cfg
    assert (c.role, c.platform, c.board, c.flavor) == ("rpi5-desktop", "rpi5", "rpi4", "")


def test_emission_identity_chromebook_under_x86(wiz):
    """Chromebook stays an x86 image-type, and emits a builder-valid x86 command."""
    pick_mode(wiz, "standalone")
    page = pick_role(wiz, "chromebook")
    pick_platform(page, "x86")
    advance_to(wiz, wizard_mod.HardwarePage)
    c = wiz.cfg
    assert (c.role, c.platform) == ("chromebook", "x86")
    assert c.to_cli_args()[:2] == ["--role", "chromebook"]


# ---- NO second machine picker anywhere in the flow ---------------------------------

def test_no_second_machine_picker(wiz):
    """The old standalone 'Platform' combo is gone (the card IS the platform), and the
    Hardware page never had — and must not have — a platform/profile picker of its own."""
    role = advance_to(wiz, wizard_mod.RolePage)
    assert not hasattr(role, "platform")            # the redundant combo is removed
    hw = advance_to(wiz, wizard_mod.HardwarePage)
    assert not hasattr(hw, "profile")               # the machine-defining preset moved


# ---- PROFILE FOLD (spec 2): the preset lives on the x86 card, seeds gpu/wifi/bt -----

def test_profile_preset_only_on_x86_card(wiz):
    page = advance_to(wiz, wizard_mod.RolePage)     # standalone x86 default
    assert page.profile_row.isVisible()
    pick_platform(page, "frite")                    # a non-x86 card
    assert not page.profile_row.isVisible()         # no profiles for ARM


def test_profile_seeds_gpu_wifi_bt_and_records_hw_profile(wiz):
    """Picking a profile on the RolePage x86 card pre-fills cfg's gpu/wifi/bt (the
    Hardware step reflects them), and hw_profile round-trips — all WITHOUT changing the
    argv (hw_profile is NON_ARGV; gpu/wifi/bt are finalised on the Hardware page)."""
    role = advance_to(wiz, wizard_mod.RolePage)
    idx = role.profile.findData("framework-13-intel")   # gpu 'intel' -> intel-free
    assert idx > 0
    role.profile.setCurrentIndex(idx)
    hw = advance_to(wiz, wizard_mod.HardwarePage)        # runs role.validatePage first
    assert hw.gpu.currentText() == "intel-free"          # folded alias
    assert hw.wifi.isChecked() and hw.bt.isChecked()
    assert wiz.cfg.hw_profile == "framework-13-intel"
    args = wiz.cfg.to_cli_args()
    assert "--hw-profile" not in " ".join(args)          # the preset never emits a flag


def test_hardware_revisit_does_not_clobber_hw_profile(wiz):
    """Regression: hw_profile is set on the RolePage now — revisiting/validating the
    Hardware page must NOT reset it to '' (the delete of hardware.validatePage's line)."""
    role = advance_to(wiz, wizard_mod.RolePage)
    role.profile.setCurrentIndex(role.profile.findData("framework-13-intel"))
    advance_to(wiz, wizard_mod.HardwarePage)
    advance_to(wiz, wizard_mod.BuildPage)               # re-validates Hardware on the way
    assert wiz.cfg.hw_profile == "framework-13-intel"

"""Build/hardware/role page behavior for the WS4 gap set — the composable role
flags (G21/G22), the artifact matrix (G23/G24), grow policy (G25), image stamps
(G30), --nvidia-cuda (G33), the U-Boot chain (G35), jetson --kernel-flavor (G36),
the ARM kernel/board overrides box (G37), build plumbing (G38), the PENTEST env
toggle (G40) and the hw-profile preset-only labeling (G41).

Runs the REAL wizard on Qt's offscreen platform (no display needed) and is skipped
whole when no Qt binding is installed — same harness as test_wizard.py.
"""
import copy
import os

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import (ImageConfig, UNAFFILIATED_ROLE,  # noqa: E402
                                           resolve_installer_ui_default)
from hugmesh_studio.core.platform_info import HostInfo    # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod       # noqa: E402
from hugmesh_studio.gui.pages import build as build_mod   # noqa: E402
from hugmesh_studio.gui.qt import Qt, QtWidgets           # noqa: E402

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
    from hugmesh_studio.core.config import WIZARD_PAGE_SLUGS
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
    from hugmesh_studio.core.config import WIZARD_PAGE_SLUGS
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
    if not page.select_role(role):     # machine-first: selects the supporting card too
        raise AssertionError(f"role {role} not offered on RolePage")
    return page


def pairs(args):
    return list(zip(args, args[1:]))


# ---- RolePage: composable --capable / --unaffiliated (G21/G22) -----------------

def test_role_capable_composes_on_standalone_thin(wiz):
    page = pick_role(wiz, "standalone-thin")
    assert page.client_box.isVisible() and page.capable.isEnabled()
    page.capable.setChecked(True)
    advance_to(wiz, wizard_mod.HardwarePage)
    assert wiz.cfg.capable is True
    assert "--capable" in wiz.cfg.to_cli_args()


def test_role_capable_composes_on_cloud_laptop(wiz):
    pick_mode(wiz, "cloud")
    page = pick_role(wiz, "laptop")
    page.capable.setChecked(True)
    advance_to(wiz, wizard_mod.HardwarePage)
    assert "--capable" in wiz.cfg.to_cli_args()


def test_role_unaffiliated_composes_on_standalone_thin(wiz):
    """G22: an unaffiliated standalone-thin — inexpressible before — emits the
    composable flag, suppresses the brand plane + bundle pair, and greys the
    BuildPage bundle-source control exactly like the dedicated role does."""
    page = pick_role(wiz, "standalone-thin")
    assert page.unaffiliated.isEnabled()
    page.unaffiliated.setChecked(True)
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert wiz.cfg.unaffiliated is True
    assert not build.bundle_source.isEnabled()
    assert not build.bundle_source.isChecked()
    assert build.bundle_note.isVisible()
    args = wiz.cfg.to_cli_args()
    assert "--unaffiliated" in args
    for flag in ("--brand", "--with-tailscale", "--no-tailscale", "--with-sso",
                 "--no-sso", "--bundle-source", "--no-bundle-source"):
        assert flag not in args
    # the preview succeeded — no conflict raised on a default identity
    assert "./build-x86-host-stage4.sh" in build.cmd.toPlainText()


def test_role_unaffiliated_checkbox_disabled_in_cloud(wiz):
    """Composable --unaffiliated is standalone-only (cloud/mesh person-device
    identity is a builder hard-conflict) — the checkbox greys, capable stays live."""
    pick_mode(wiz, "cloud")
    page = pick_role(wiz, "laptop")
    assert not page.unaffiliated.isEnabled()
    assert not page.unaffiliated.isChecked()
    assert page.capable.isEnabled()
    assert "unaffiliated" in page.unaffiliated.toolTip()


def test_role_unaffiliated_checkbox_disabled_on_dedicated_role(wiz):
    """The dedicated role id presets --unaffiliated in the builder's own role
    switch — the composable checkbox greys there and the flag is never emitted."""
    page = pick_role(wiz, UNAFFILIATED_ROLE)
    assert not page.unaffiliated.isEnabled()
    assert not page.unaffiliated.isChecked()
    advance_to(wiz, wizard_mod.HardwarePage)
    assert wiz.cfg.unaffiliated is False
    assert "--unaffiliated" not in wiz.cfg.to_cli_args()


def test_role_capable_clears_when_client_box_hides(wiz):
    """A capable pick on x86 can't linger into an ARM build (no --capable there)."""
    page = pick_role(wiz, "standalone-thin")
    page.capable.setChecked(True)
    advance_to(wiz, wizard_mod.HardwarePage)
    assert wiz.cfg.capable is True
    page = back_to(wiz, wizard_mod.RolePage)
    pick_role(wiz, "generic")            # standalone rpi5 — client box hides
    advance_to(wiz, wizard_mod.HardwarePage)
    assert wiz.cfg.capable is False
    assert "--capable" not in wiz.cfg.to_cli_args()


# ---- RolePage: U-Boot chain (G35) + jetson kernel flavor (G36) ------------------

def test_role_frite_uboot_fields_flow(wiz):
    page = pick_role(wiz, "frite")
    assert page.frite_box.isVisible()
    page.frite_uboot_url.setText("https://example.org/u-boot-frite.bin")
    page.frite_uboot_defconfig.setText("libretech-ac_defconfig")
    page.frite_skip_uboot.setChecked(True)
    advance_to(wiz, wizard_mod.HardwarePage)
    c = wiz.cfg
    assert (c.uboot_url, c.uboot_defconfig, c.skip_uboot) == (
        "https://example.org/u-boot-frite.bin", "libretech-ac_defconfig", True)
    p = pairs(c.to_cli_args())
    assert ("--uboot-url", "https://example.org/u-boot-frite.bin") in p
    assert ("--uboot-defconfig", "libretech-ac_defconfig") in p
    assert "--skip-uboot" in c.to_cli_args()


@pytest.mark.parametrize("role,url_attr,def_attr,skip_attr", [
    ("orangepi5", "orangepi5_uboot_url", "orangepi5_uboot_defconfig", "orangepi5_skip_uboot"),
    ("orangepizero2", "orangepizero2_uboot_url", "orangepizero2_uboot_defconfig",
     "orangepizero2_skip_uboot"),
    ("orangepizero2w", "orangepizero2w_uboot_url", "orangepizero2w_uboot_defconfig",
     "orangepizero2w_skip_uboot"),
    ("orangepizero3", "orangepizero3_uboot_url", "orangepizero3_uboot_defconfig",
     "orangepizero3_skip_uboot"),
])
def test_role_orangepi_uboot_fields_flow(wiz, role, url_attr, def_attr, skip_attr):
    page = pick_role(wiz, role)
    getattr(page, url_attr).setText("https://example.org/u-boot.itb")
    getattr(page, def_attr).setText("custom_defconfig")
    getattr(page, skip_attr).setChecked(False)
    advance_to(wiz, wizard_mod.HardwarePage)
    p = pairs(wiz.cfg.to_cli_args())
    assert ("--uboot-url", "https://example.org/u-boot.itb") in p
    assert ("--uboot-defconfig", "custom_defconfig") in p
    assert "--skip-uboot" not in wiz.cfg.to_cli_args()


def test_role_uboot_clears_on_platform_switch(wiz):
    """A frite U-Boot override can't linger into an x86 build (no --uboot-* there)."""
    page = pick_role(wiz, "frite")
    page.frite_uboot_url.setText("https://example.org/u-boot-frite.bin")
    advance_to(wiz, wizard_mod.HardwarePage)
    assert wiz.cfg.uboot_url
    back_to(wiz, wizard_mod.RolePage)
    pick_role(wiz, "standalone-thick")
    advance_to(wiz, wizard_mod.HardwarePage)
    assert wiz.cfg.uboot_url == "" and wiz.cfg.uboot_defconfig == ""
    assert wiz.cfg.skip_uboot is False
    assert not any(a.startswith("--uboot") for a in wiz.cfg.to_cli_args())


# NOTE: the jetson --kernel-flavor RolePage tests were REMOVED with the redesign. The
# jetson roles (full/gpu-host/jetson-desktop/edge_ai) are mesh-only, and mesh now SKIPS
# RolePage (MODE_SKIPPED_PAGES) in favour of the WorklistPage role x platform multi-select
# — so the old pick_mode("mesh") -> RolePage -> jetson path no longer exists in the GUI.
# The jetson-mesh materialize behaviour (encrypt_root exemption, per-image axes) is covered
# by WS-MODEL's test_worklist.py materialize() unit tests (design 6). The kernel_flavor combo
# stays on RolePage for any non-mesh jetson support and is exercised via test_wizard.py.


# ---- HardwarePage: --nvidia-cuda (G33), ARM overrides (G37), preset label (G41) --

def test_hardware_nvidia_cuda_x86(wiz):
    hw = advance_to(wiz, wizard_mod.HardwarePage)
    assert hw.nvidia_cuda.isEnabled()
    hw.gpu.setCurrentText("nvidia")      # the builder requires the proprietary driver
    hw.nvidia_cuda.setChecked(True)
    advance_to(wiz, wizard_mod.BrandingPage)
    args = wiz.cfg.to_cli_args()
    assert "--nvidia-cuda" in args
    assert ("--gpu-driver", "nvidia") in pairs(args)


def test_hardware_nvidia_cuda_greys_and_clears_on_arm(wiz):
    wiz.cfg.nvidia_cuda = True           # e.g. loaded from an x86 config
    pick_role(wiz, "generic")            # standalone rpi5
    hw = advance_to(wiz, wizard_mod.HardwarePage)
    assert not hw.nvidia_cuda.isEnabled()
    advance_to(wiz, wizard_mod.BrandingPage)
    assert wiz.cfg.nvidia_cuda is False
    assert "--nvidia-cuda" not in wiz.cfg.to_cli_args()


def test_hardware_arm_overrides_rpi5(wiz):
    """G37 on the rpi5 family: -c/-d/--dtb-prefix/--kernel-img/--pcie-gen3 are live;
    --dtb (the frite/jetson/orangepi* spelling) greys out."""
    pick_role(wiz, "generic")
    hw = advance_to(wiz, wizard_mod.HardwarePage)
    assert hw.arm_box.isVisible()
    for w in (hw.cpu, hw.defconfig, hw.dtb_prefix, hw.kernel_img, hw.pcie_gen3):
        assert w.isEnabled(), w
    assert not hw.dtb.isEnabled()
    hw.cpu.setText("cortex-a76")
    hw.defconfig.setText("bcm2712_defconfig")
    hw.dtb_prefix.setText("broadcom/")
    hw.kernel_img.setText("kernel_2712.img")
    hw.pcie_gen3.setChecked(True)
    advance_to(wiz, wizard_mod.BrandingPage)
    args = wiz.cfg.to_cli_args()
    p = pairs(args)
    assert ("--cpu", "cortex-a76") in p
    assert ("--defconfig", "bcm2712_defconfig") in p
    assert ("--dtb-prefix", "broadcom/") in p
    assert ("--kernel-img", "kernel_2712.img") in p
    assert "--pcie-gen3" in args
    assert wiz.cfg.dtb == ""             # the greyed spelling was cleared


def test_hardware_arm_overrides_frite_dtb(wiz):
    pick_role(wiz, "frite")
    hw = advance_to(wiz, wizard_mod.HardwarePage)
    assert hw.dtb.isEnabled()
    assert not hw.dtb_prefix.isEnabled() and not hw.kernel_img.isEnabled()
    assert not hw.pcie_gen3.isEnabled()
    hw.dtb.setText("meson-gxl-s805x-libretech-ac.dtb")
    advance_to(wiz, wizard_mod.BrandingPage)
    assert ("--dtb", "meson-gxl-s805x-libretech-ac.dtb") in pairs(wiz.cfg.to_cli_args())


def test_hardware_arm_box_hidden_and_cleared_on_x86(wiz):
    c = wiz.cfg
    c.cpu = "cortex-a76"; c.dtb = "x.dtb"; c.pcie_gen3 = True   # e.g. a loaded ARM config
    hw = advance_to(wiz, wizard_mod.HardwarePage)               # default x86 flow
    assert not hw.arm_box.isVisible()
    advance_to(wiz, wizard_mod.BrandingPage)
    assert c.cpu == "" and c.dtb == "" and c.pcie_gen3 is False
    args = c.to_cli_args()
    for flag in ("--cpu", "--defconfig", "--dtb", "--dtb-prefix", "--kernel-img",
                 "--pcie-gen3"):
        assert flag not in args


def test_role_profile_is_labeled_preset_only(wiz):
    """G41 (decided document-as-preset): the profile combo — now folded onto the
    RolePage's x86 machine card (spec fold 2) — says it never emits a builder flag
    itself; it only pre-fills the gpu/wifi/bt fields. HardwarePage no longer has one."""
    role = advance_to(wiz, wizard_mod.RolePage)
    assert "never emits a builder flag" in role.profile.toolTip()
    hw = advance_to(wiz, wizard_mod.HardwarePage)
    assert not hasattr(hw, "profile")   # the preset moved off the Hardware page


# ---- BuildPage: artifact matrix (G23/G24) ---------------------------------------

def test_build_x86_artifact_matrix(wiz):
    build = advance_to(wiz, wizard_mod.BuildPage)
    # x86: the full img/live-iso/installer-iso/tar/skip-iso matrix is live;
    # the rpi5/ARM-only axes grey out
    for w in (build.build_img, build.live_iso, build.installer_iso,
              build.build_tar, build.skip_iso):
        assert w.isVisible(), w
    # inapplicable artifact axes are now HIDDEN (setVisible False), not greyed
    for w in (build.build_iso, build.sd_only, build.image_only):
        assert not w.isVisible(), w
    # tri-state flag-pairs are G34 tri-CHECKBOXES now (the build-page idiom fix:
    # ☑=--flag, ☐=--no-flag, ■=leave the builder default); emission is unchanged.
    build.build_img.setCheckState(Qt.CheckState.Unchecked)
    build.live_iso.setCheckState(Qt.CheckState.Checked)
    build.installer_iso.setChecked(True)
    build.build_tar.setCheckState(Qt.CheckState.Unchecked)
    build.skip_iso.setChecked(True)
    build._preview()
    args = wiz.cfg.to_cli_args()
    assert "--no-img" in args and "--live-iso" in args and "--installer-iso" in args
    assert "--no-tar" in args and "--skip-iso" in args


def test_buildpage_restores_jobs_from_config(wiz):
    """A loaded config's non-default parallel-jobs value must survive to Review & Build:
    initializePage restores the spinbox, else validatePage writes back the widget default (8)."""
    wiz.cfg.jobs = 16
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.jobs.value() == 16          # restored (was silently reset to 8 before the fix)
    build.validatePage()
    assert wiz.cfg.jobs == 16                # round-trip: not clobbered back to the default


def test_build_artifact_tristate_default_emits_nothing(wiz):
    build = advance_to(wiz, wizard_mod.BuildPage)
    build._preview()
    args = wiz.cfg.to_cli_args()
    for flag in ("--img", "--no-img", "--live-iso", "--no-live-iso",
                 "--installer-iso", "--tar", "--no-tar", "--skip-iso"):
        assert flag not in args


def test_build_rpi5_artifacts(wiz):
    pick_role(wiz, "generic")
    build = advance_to(wiz, wizard_mod.BuildPage)
    for w in (build.build_img, build.build_iso, build.sd_only, build.build_tar,
              build.skip_iso):
        assert w.isVisible(), w
    for w in (build.live_iso, build.installer_iso, build.image_only):
        assert not w.isVisible(), w
    build.build_iso.setChecked(True)     # bootable installer ISO for an UNencrypted image
    build.sd_only.setChecked(True)
    build.build_tar.setCheckState(Qt.CheckState.Checked)
    build._preview()
    args = wiz.cfg.to_cli_args()
    assert "--iso" in args and "--sd-only" in args and "--tar" in args


def test_build_frite_image_only(wiz):
    pick_role(wiz, "frite")
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.image_only.isVisible()
    assert not build.build_img.isVisible()   # frite has no --img/--no-img (hidden, not greyed)
    build.image_only.setChecked(True)
    build._preview()
    assert "--image-only" in wiz.cfg.to_cli_args()


def test_askpass_mode_prints_password_and_exits_zero(monkeypatch, qapp):
    """The GUI SUDO_ASKPASS helper (`--askpass`) pops a password dialog and prints the
    entry to stdout so `sudo -A` gets the password from a DIALOG, never an invisible
    terminal — the core of bug B's fix."""
    import contextlib
    import io

    from hugmesh_studio import app
    from hugmesh_studio.gui.qt import QtWidgets
    monkeypatch.setattr(QtWidgets, "QApplication", lambda *a, **k: qapp)
    monkeypatch.setattr(QtWidgets.QInputDialog, "getText",
                        staticmethod(lambda *a, **k: ("s3cr3t-pw", True)))
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = app.main(["--askpass"])
    assert rc == 0
    assert buf.getvalue().strip() == "s3cr3t-pw"


def test_askpass_mode_cancel_returns_nonzero(monkeypatch, qapp):
    """A cancelled dialog exits non-zero so sudo aborts the elevation cleanly instead of
    treating an empty string as the password."""
    from hugmesh_studio import app
    from hugmesh_studio.gui.qt import QtWidgets
    monkeypatch.setattr(QtWidgets, "QApplication", lambda *a, **k: qapp)
    monkeypatch.setattr(QtWidgets.QInputDialog, "getText",
                        staticmethod(lambda *a, **k: ("", False)))
    assert app.main(["--askpass"]) == 1


def test_build_preview_resolves_unset_flavor_on_deepcopy(monkeypatch, wiz):
    """The Review-page preview resolves an UNSET frite/opi5/opz2 flavor to the single
    artifact (--flavor installer) the materialize path would build, and does so on a
    DEEPCOPY so the shared, re-editable/savable wiz.cfg is never mutated by a render.
    (In the normal wizard flow RolePage sets an explicit flavor, so this exercises the
    defensive unset case directly: an unset-flavor cfg reaching the BuildPage.)"""
    build = advance_to(wiz, wizard_mod.BuildPage)
    # a frite config with a genuinely UNSET flavor lands on the Review page; suppress the
    # per-page re-collect so the isolated unset value survives into _preview.
    wiz.cfg = ImageConfig(mode="standalone", role="frite", platform="frite",
                          board="la-frite", flavor="")
    monkeypatch.setattr(wiz, "collect_all", lambda: None)
    build._preview()
    shown = build.cmd.toPlainText()
    assert "--flavor installer" in shown          # resolved to a single artifact
    assert "--flavor both" not in shown
    # the shared cfg is untouched — resolve ran on the deepcopy, never on wiz.cfg
    assert wiz.cfg.flavor == ""
    assert "--flavor both" in " ".join(wiz.cfg.to_cli_args())  # to_cli_args default unchanged


def test_build_x86_artifact_picks_clear_on_arm(wiz):
    build = advance_to(wiz, wizard_mod.BuildPage)
    build.live_iso.setCheckState(Qt.CheckState.Checked)
    build.installer_iso.setChecked(True)
    build._preview()
    assert "--live-iso" in wiz.cfg.to_cli_args()
    back_to(wiz, wizard_mod.RolePage)
    pick_role(wiz, "frite")
    build = advance_to(wiz, wizard_mod.BuildPage)
    build._preview()
    assert wiz.cfg.live_iso == "" and wiz.cfg.installer_iso is False
    args = wiz.cfg.to_cli_args()
    assert "--live-iso" not in args and "--installer-iso" not in args


# ---- BuildPage: Secure Boot (G5) -------------------------------------------------

def test_build_secure_boot_off(wiz):
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.sb_box.isVisible()
    build.secure_boot.setCheckState(Qt.CheckState.Unchecked)
    build._preview()
    args = wiz.cfg.to_cli_args()
    assert "--no-secure-boot" in args and "--secure-boot" not in args


def test_build_secure_boot_fleet_key_paths(wiz):
    """The fleet SB-chain continuity path: hand-SET key/cert PATHS thread through
    verbatim. (Since the secret-file vault, BROWSING additionally holds the key
    CONTENT in memory — see test_secret_files*.py — but typed/programmatic paths
    keep exactly these plain-path semantics: nothing is read by the Studio.)"""
    build = advance_to(wiz, wizard_mod.BuildPage)
    build.secure_boot.setCheckState(Qt.CheckState.Checked)
    build.keys_usb.setText("/media/KEYS")
    build.secureboot_key.setText("/media/KEYS/Keys/kernel_key.pem")
    build.secureboot_cert.setText("/media/KEYS/Keys/kernel_key.der")
    build._preview()
    args = wiz.cfg.to_cli_args()
    p = pairs(args)
    assert "--secure-boot" in args
    assert ("--keys-usb", "/media/KEYS") in p
    assert ("--secureboot-key", "/media/KEYS/Keys/kernel_key.pem") in p
    assert ("--secureboot-cert", "/media/KEYS/Keys/kernel_key.der") in p


def test_build_secure_boot_key_paths_persist_to_saved_configs(wiz, tmp_path):
    """Key PATHS keep persisting — unlike passwords, they survive a save/load round
    trip (the headless/CLI channel and --print-specs depend on it). The secret-file
    vault changes only what happens to browsed CONTENT (held in memory, never
    persisted — test_secret_files.py pins that scan); the path contract is pinned
    HERE so the vault work can never silently regress it."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    build.secureboot_key.setText("/media/KEYS/Keys/kernel_key.pem")
    build._preview()
    path = tmp_path / "cfg.json"
    warnings = wiz.cfg.save(str(path))
    assert warnings == []
    from hugmesh_studio.core.config import ImageConfig
    assert ImageConfig.load(str(path)).secureboot_key == "/media/KEYS/Keys/kernel_key.pem"


def test_build_secure_boot_greys_and_clears_on_arm(wiz):
    c = wiz.cfg
    c.secure_boot = "on"; c.keys_usb = "/media/KEYS"   # e.g. loaded from an x86 config
    pick_role(wiz, "generic")
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert not build.sb_box.isVisible()
    build._preview()
    assert c.secure_boot == "" and c.keys_usb == ""
    args = c.to_cli_args()
    for flag in ("--secure-boot", "--no-secure-boot", "--keys-usb",
                 "--secureboot-key", "--secureboot-cert"):
        assert flag not in args


# ---- BuildPage: grow (G25) + image stamps (G30) -----------------------------------

def test_build_grow_policy_and_custom_size(wiz):
    build = advance_to(wiz, wizard_mod.BuildPage)
    build.grow.setCurrentText("none")
    build._preview()
    assert ("--grow", "none") in pairs(wiz.cfg.to_cli_args())
    build.grow.setCurrentText("16G")     # editable: a size cap types straight in
    build._preview()
    assert ("--grow", "16G") in pairs(wiz.cfg.to_cli_args())
    build.grow.setCurrentText("")
    build._preview()
    assert "--grow" not in wiz.cfg.to_cli_args()


def test_build_grow_flows_on_arm_too(wiz):
    pick_role(wiz, "generic")
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.grow.isEnabled()
    build.grow.setCurrentText("fill")
    build._preview()
    assert ("--grow", "fill") in pairs(wiz.cfg.to_cli_args())


def test_build_stamps_x86(wiz):
    build = advance_to(wiz, wizard_mod.BuildPage)
    build.version.setText("1.2.3")
    build.release_tag.setText("2026.07-rc1")
    build._preview()
    p = pairs(wiz.cfg.to_cli_args())
    assert ("--version", "1.2.3") in p
    assert ("--release-tag", "2026.07-rc1") in p


def test_build_release_tag_greys_on_arm_version_flows(wiz):
    pick_role(wiz, "generic")
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.version.isEnabled() and not build.release_tag.isVisible()
    build.version.setText("1.2.3")
    build.release_tag.setText("stale")   # greyed — must be cleared, not emitted
    build._preview()
    assert wiz.cfg.release_tag == ""
    args = wiz.cfg.to_cli_args()
    assert ("--version", "1.2.3") in pairs(args)
    assert "--release-tag" not in args


# ---- BuildPage: plumbing (G38) + PENTEST (G40) ------------------------------------

def test_build_plumbing_x86(wiz):
    build = advance_to(wiz, wizard_mod.BuildPage)
    # the free-text extra-packages field is retired (packages move to the PackagesDialog);
    # the rest of the plumbing box still flows.
    assert not hasattr(build, "extra_packages")
    build.skip_kernel.setChecked(True)
    build.skip_clean.setChecked(True)
    build.distdir.setText("/mnt/distfiles")
    build.build_subdir.setText("snap-build-alt")
    build.seed_url.setText("https://example.org/stage3/")
    build._preview()
    args = wiz.cfg.to_cli_args()
    p = pairs(args)
    assert "--skip-kernel" in args and "--skip-clean" in args
    assert ("--distdir", "/mnt/distfiles") in p
    assert ("--build-subdir", "snap-build-alt") in p
    assert ("--seed-url", "https://example.org/stage3/") in p
    assert "--extra-packages" not in args


def test_build_plumbing_arm(wiz):
    pick_role(wiz, "generic")
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert not build.distdir.isVisible()           # --distdir is x86-only (hidden, not greyed)
    build.distdir.setText("/stale")                # greyed — cleared, not emitted
    build.skip_kernel.setChecked(True)
    build._preview()
    assert wiz.cfg.distdir == ""
    args = wiz.cfg.to_cli_args()
    assert "--skip-kernel" in args and "--distdir" not in args


def test_build_pentest_env_toggle_never_argv(wiz):
    """G40: PENTEST=1 is a fleet/env knob the driver forwards — the checkbox sets
    the config field and the argv stays clean of it on every platform."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.pentest.isEnabled()
    build.pentest.setChecked(True)
    build._preview()
    assert wiz.cfg.pentest is True
    assert not any("pentest" in a.lower() for a in wiz.cfg.to_cli_args())
    # stays live on ARM too (it is out-of-band, not a builder flag)
    back_to(wiz, wizard_mod.RolePage)
    pick_role(wiz, "generic")
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.pentest.isEnabled() and build.pentest.isChecked()
    build._preview()
    assert wiz.cfg.pentest is True
    assert not any("pentest" in a.lower() for a in wiz.cfg.to_cli_args())


# ---- Review & Build page (spec 8) -------------------------------------------------

def test_review_page_replaces_build_now_with_packages(wiz):
    """The in-form 'Build now' button is gone (the build runs on the terminal
    ProgressPage); a single image shows the per-image Packages… button, hides the mesh
    summary, and the page is a commit page (Back disabled once committed)."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.title() == "Review & Build"
    assert not hasattr(build, "build_btn")     # 'Build now' removed
    assert build.isCommitPage()
    assert build.packages_btn.isVisible()
    assert not build.worklist_group.isVisible()


def test_review_commits_single_entry_worklist_for_standalone(wiz):
    """Leaving Review commits a 1-entry worklist synthesized from the config (so the
    driver/progress/manifest have exactly one shape) and stashes the run parameters
    ProgressPage reads."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.validatePage() is True
    wl = wiz.worklist
    assert wl is not None and len(wl.entries) == 1
    assert wl.entries[0].role == wiz.cfg.role
    assert wl.entries[0].platform == "x86"
    assert hasattr(wiz, "build_backend")
    assert wiz.generate_node_keys is True      # not mesh -> node key-zips not applicable


def test_review_mesh_shows_per_image_summary_and_keeps_worklist(wiz):
    """Mesh Review shows one summary row per worklist image + the node key-zip opt-out,
    hides the single-image Packages button, and commits the WorklistPage selection (not a
    synthesized 1-entry worklist)."""
    pick_mode(wiz, "mesh")
    wl_page = advance_to(wiz, wizard_mod.WorklistPage)
    for rid in ("omnibus.x86", "be.rpi5"):
        wl_page.row_for_id(rid).setCheckState(0, Qt.CheckState.Checked)
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.worklist_group.isVisible()
    assert not build.packages_btn.isVisible()
    assert build.gen_keys.isChecked()
    ids = {build.worklist_table.item(r, 0).text()
           for r in range(build.worklist_table.rowCount())}
    assert {"omnibus.x86", "be.rpi5"} <= ids
    assert build.validatePage() is True
    assert {e.id for e in wiz.worklist.entries} >= {"omnibus.x86", "be.rpi5"}
    assert wiz.build_backend == build._backend()


# ── low-memory preflight WARNING on the Review pane (2026-07-15 freeze guard) ─────────
def test_preflight_warning_renders_but_never_gates_build(wiz):
    """A warning rides the problems pane as TEXT ONLY: it appears under 'Preflight OK.'
    without entering _problems, so isComplete()/the Build button gate exactly as before."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    warning = ("Low host memory: 2.0 GiB available, swap 100% full — a heavy compile "
               "can freeze the host; consider lowering parallel jobs or closing apps.")
    build._on_preflight_done([], False, build._recompute_gen, [warning])
    text = build.log.toPlainText()
    assert "Preflight OK." in text
    assert "Warnings (advisory — the build is not blocked):" in text
    assert warning in text
    assert build._problems == []                    # never routed into the blocking channel
    assert build.isComplete()                       # Build stays enabled despite the warning
    build._join_preflight_worker()


def test_preflight_warning_appends_under_a_problems_list(wiz):
    build = advance_to(wiz, wizard_mod.BuildPage)
    build._on_preflight_done(["some blocking problem"], False, build._recompute_gen,
                             ["Low host memory: warn"])
    text = build.log.toPlainText()
    assert "Preflight:\n  - some blocking problem" in text
    assert "Low host memory: warn" in text
    assert build._problems == ["some blocking problem"]   # the warning did not join them
    assert not build.isComplete()                          # blocked by the PROBLEM only
    build._join_preflight_worker()


def test_three_arg_preflight_done_still_works(wiz):
    """The pre-warning slot arity (problems, image_missing, req_id) keeps working —
    warnings default to empty."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    build._on_preflight_done([], False, build._recompute_gen)
    assert "Warnings" not in build.log.toPlainText()
    assert build.isComplete()
    build._join_preflight_worker()


# ---- BuildPage: Installer-UI role-class honesty (headless node -> cli) -----------
# The combo used to offer "all" and DEFAULT to it even for a mesh-node fleet, where the
# graphical Calamares front-end is not merely expensive but UNBUILDABLE: its USE closure
# (specs-x86/portage/package.use/desktop) is copied only for ROLE_CLIENT roles
# (build-x86-host-stage4.sh:2496). A combo reading "all" on a node LIED about what the
# image would get; materialize now rewrites it to "cli", and the combo must say so.

def test_installer_ui_pinned_and_greyed_on_a_mesh_node(wiz):
    """A mesh node: the combo reads what materialize will actually emit ("cli"), is
    greyed, and carries the explanatory reason (disable-with-reason, NOT hidden — the
    operator must be able to see WHY).

    Mesh has NO RolePage — the role comes from the WorklistPage selection (the flow is
    ModePage -> WorklistPage), so this drives the worklist, not pick_role()."""
    pick_mode(wiz, "mesh")
    wl_page = advance_to(wiz, wizard_mod.WorklistPage)
    wl_page.row_for_id("pki.x86").setCheckState(0, Qt.CheckState.Checked)
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.installer_ui.currentText() == "cli"
    assert not build.installer_ui.isEnabled()
    assert not build.installer_ui_row.isEnabled()
    assert build.installer_ui.toolTip()               # the reason is on the control
    assert build.installer_ui_row.toolTip()           # ...and on the label row
    assert build.installer_ui.isVisible()             # greyed, never hidden


def test_installer_ui_live_and_all_on_a_cloud_client(wiz):
    """No-regression: a client keeps the full choice, defaulted to "all", ungreyed and
    with no tooltip — byte-identical to the pre-fix behaviour."""
    pick_mode(wiz, "cloud")
    pick_role(wiz, "laptop")
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.installer_ui.currentText() == "all"
    assert build.installer_ui.isEnabled()
    assert build.installer_ui_row.isEnabled()
    assert build.installer_ui.toolTip() == ""
    assert wiz.cfg.installer_ui == "all"


def test_installer_ui_regate_restores_the_combo_when_role_leaves_node_class(wiz):
    """The every-visit re-gate contract: a node visit must never STRAND a later desktop
    on "cli" — going back and picking a client role re-enables the combo and restores
    "all" (validatePage writes the combo's value back, so a stuck "cli" would silently
    strip a desktop's graphical installer)."""
    pick_mode(wiz, "mesh")
    wl_page = advance_to(wiz, wizard_mod.WorklistPage)
    wl_page.row_for_id("pki.x86").setCheckState(0, Qt.CheckState.Checked)
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert not build.installer_ui.isEnabled() and build.installer_ui.currentText() == "cli"
    # flip to a desktop-class role and come back (back_to: pick_mode advances FORWARD
    # only, and BuildPage is downstream of ModePage)
    back_to(wiz, wizard_mod.ModePage)
    pick_mode(wiz, "cloud")
    pick_role(wiz, "laptop")
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.installer_ui.isEnabled()
    assert build.installer_ui.currentText() == "all"
    assert build.installer_ui.toolTip() == ""
    assert wiz.cfg.installer_ui == "all"      # the node visit must not have poisoned it


def test_installer_ui_node_visit_does_not_persist_cli_into_the_config(wiz):
    """REGRESSION (found by the re-gate test): _preview() used to write the combo back
    UNCONDITIONALLY, so a node visit persisted "cli" into cfg.installer_ui — and every
    LATER desktop image inherited it, silently losing its graphical installer. On a node
    the combo REPORTS what the resolver will emit; it is not a user choice, so it is not
    written back. The user's real preference survives a node detour."""
    pick_mode(wiz, "mesh")
    wl_page = advance_to(wiz, wizard_mod.WorklistPage)
    wl_page.row_for_id("pki.x86").setCheckState(0, Qt.CheckState.Checked)
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.installer_ui.currentText() == "cli"      # the combo reports "cli"...
    build._preview()                                      # ...and validatePage/_preview
    assert wiz.cfg.installer_ui == "all"                  # ...must NOT persist it


def test_installer_ui_command_pane_shows_the_resolved_value_for_a_node(wiz):
    """REGRESSION (review mustFix #1): the combo was honest but the COMMAND PANE was not.
    _preview() deep-copied the cfg and applied only resolve_platform_defaults, never its
    role-class twin — so the pane rendered `--installer-ui all` for an x86 node while the
    real build ran `--installer-ui cli`. The pane is COPY-PASTEABLE and its own contract
    is "DISPLAY the same command the real build will run": an operator pasting the stale
    argv got WANT_CALAMARES=true (:1246) -> app-admin/calamares (:3532) -> the
    unsatisfiable libpwquality[python] wall this whole change exists to prevent."""
    pick_mode(wiz, "mesh")
    wl_page = advance_to(wiz, wizard_mod.WorklistPage)
    wl_page.row_for_id("pki.x86").setCheckState(0, Qt.CheckState.Checked)
    build = advance_to(wiz, wizard_mod.BuildPage)
    build._preview()
    cmd = build.cmd.toPlainText()
    assert "--installer-ui cli" in cmd
    assert "--installer-ui all" not in cmd      # the exact pre-fix lie
    assert wiz.cfg.installer_ui == "all"        # ...and the preview must not mutate cfg


@pytest.mark.parametrize("stored,shown", [("all", "cli"), ("ncurses", "ncurses")])
def test_installer_ui_node_displays_what_will_actually_be_emitted(wiz, stored, shown):
    """REGRESSION (review mustFix #2): the GUI RESTATED the resolver's rule ("a node shows
    cli") instead of ASKING it. The resolver's rewrite is CONDITIONAL — it only replaces
    the calamares-triggering values (all/calamares) — so a node carrying "ncurses" builds
    ncurses, and pinning the display to "cli" was a lie in the opposite direction, with a
    tooltip whose stated reason was also false. Both surfaces (combo + command pane) must
    agree with core.config.effective_installer_ui, which is what materialize applies.

    Reachable for real: loading a saved config with installer_ui="ncurses" on a node role,
    or picking a client, choosing ncurses, then switching to a node role."""
    pick_mode(wiz, "mesh")
    wl_page = advance_to(wiz, wizard_mod.WorklistPage)
    wl_page.row_for_id("pki.x86").setCheckState(0, Qt.CheckState.Checked)
    wiz.cfg.installer_ui = stored
    build = advance_to(wiz, wizard_mod.BuildPage)
    build.initializePage()                  # re-enter carrying the stored value
    # the value a materialized node entry really gets — computed, never hard-coded
    probe = copy.deepcopy(wiz.cfg)
    resolve_installer_ui_default(probe)
    assert probe.installer_ui == shown      # guards the expectation itself
    assert build.installer_ui.currentText() == shown
    build._preview()
    assert f"--installer-ui {shown}" in build.cmd.toPlainText()
    assert not build.installer_ui.isEnabled()   # greyed for EVERY node either way
    assert build.installer_ui.toolTip()         # ...and always says why
    # ...and the stated REASON must be true too, not just present: the pre-fix tooltip
    # told an ncurses node "installs unattended (CLI)... choose a client role to pick a
    # front-end" while an ncurses front-end is precisely what it was about to build.
    claims_cli_pin = build_mod._INSTALLER_UI_REWRITTEN_REASON in build.installer_ui.toolTip()
    assert claims_cli_pin is (shown != stored)
    assert wiz.cfg.installer_ui == stored       # never written back on a node

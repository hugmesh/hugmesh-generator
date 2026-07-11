"""Build/hardware/role page behavior for the WS4 gap set — the composable role
flags (G21/G22), the artifact matrix (G23/G24), grow policy (G25), image stamps
(G30), --nvidia-cuda (G33), the U-Boot chain (G35), jetson --kernel-flavor (G36),
the ARM kernel/board overrides box (G37), build plumbing (G38), the PENTEST env
toggle (G40) and the hw-profile preset-only labeling (G41).

Runs the REAL wizard on Qt's offscreen platform (no display needed) and is skipped
whole when no Qt binding is installed — same harness as test_wizard.py.
"""
import os

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("snapdragon_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from snapdragon_studio.core.config import UNAFFILIATED_ROLE  # noqa: E402
from snapdragon_studio.core.platform_info import HostInfo    # noqa: E402
from snapdragon_studio.gui import wizard as wizard_mod       # noqa: E402
from snapdragon_studio.gui.qt import Qt, QtWidgets           # noqa: E402

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
    from snapdragon_studio.core.config import WIZARD_PAGE_SLUGS
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
    from snapdragon_studio.core.config import WIZARD_PAGE_SLUGS
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


def test_hardware_profile_is_labeled_preset_only(wiz):
    """G41 (decided document-as-preset): the profile combo says it never emits a
    builder flag itself — it only pre-fills the gpu/wifi/bt fields."""
    hw = advance_to(wiz, wizard_mod.HardwarePage)
    assert "never emits a builder flag" in hw.profile.toolTip()


# ---- BuildPage: artifact matrix (G23/G24) ---------------------------------------

def test_build_x86_artifact_matrix(wiz):
    build = advance_to(wiz, wizard_mod.BuildPage)
    # x86: the full img/live-iso/installer-iso/tar/skip-iso matrix is live;
    # the rpi5/ARM-only axes grey out
    for w in (build.build_img, build.live_iso, build.installer_iso,
              build.build_tar, build.skip_iso):
        assert w.isEnabled(), w
    for w in (build.build_iso, build.sd_only, build.image_only):
        assert not w.isEnabled(), w
    build.build_img.setCurrentIndex(build.build_img.findData("off"))
    build.live_iso.setCurrentIndex(build.live_iso.findData("on"))
    build.installer_iso.setChecked(True)
    build.build_tar.setCurrentIndex(build.build_tar.findData("off"))
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
        assert w.isEnabled(), w
    for w in (build.live_iso, build.installer_iso, build.image_only):
        assert not w.isEnabled(), w
    build.build_iso.setChecked(True)     # bootable installer ISO for an UNencrypted image
    build.sd_only.setChecked(True)
    build.build_tar.setCurrentIndex(build.build_tar.findData("on"))
    build._preview()
    args = wiz.cfg.to_cli_args()
    assert "--iso" in args and "--sd-only" in args and "--tar" in args


def test_build_frite_image_only(wiz):
    pick_role(wiz, "frite")
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.image_only.isEnabled()
    assert not build.build_img.isEnabled()   # frite has no --img/--no-img
    build.image_only.setChecked(True)
    build._preview()
    assert "--image-only" in wiz.cfg.to_cli_args()


def test_build_x86_artifact_picks_clear_on_arm(wiz):
    build = advance_to(wiz, wizard_mod.BuildPage)
    build.live_iso.setCurrentIndex(build.live_iso.findData("on"))
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
    assert build.sb_box.isEnabled()
    build.secure_boot.setCurrentIndex(build.secure_boot.findData("off"))
    build._preview()
    args = wiz.cfg.to_cli_args()
    assert "--no-secure-boot" in args and "--secure-boot" not in args


def test_build_secure_boot_fleet_key_paths(wiz):
    """The fleet SB-chain continuity path: key/cert PATHS thread through (the
    Studio never reads the key material — paths only, they aren't secrets)."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    build.secure_boot.setCurrentIndex(build.secure_boot.findData("on"))
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
    """Key PATHS are not secrets (the material is never read) — unlike passwords,
    they must survive a save/load round trip."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    build.secureboot_key.setText("/media/KEYS/Keys/kernel_key.pem")
    build._preview()
    path = tmp_path / "cfg.json"
    warnings = wiz.cfg.save(str(path))
    assert warnings == []
    from snapdragon_studio.core.config import ImageConfig
    assert ImageConfig.load(str(path)).secureboot_key == "/media/KEYS/Keys/kernel_key.pem"


def test_build_secure_boot_greys_and_clears_on_arm(wiz):
    c = wiz.cfg
    c.secure_boot = "on"; c.keys_usb = "/media/KEYS"   # e.g. loaded from an x86 config
    pick_role(wiz, "generic")
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert not build.sb_box.isEnabled()
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
    assert build.version.isEnabled() and not build.release_tag.isEnabled()
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
    assert not build.distdir.isEnabled()           # --distdir is x86-only
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

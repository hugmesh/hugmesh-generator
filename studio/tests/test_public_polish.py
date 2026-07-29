"""Public-consumption GUI polish — the shippable-app punch-list, headless.

Every check runs on Qt's offscreen platform against the REAL widgets (no real build,
no display): window branding, a humane no-backend empty state, dev-jargon removal,
gating the whole-release Fleet tool behind expert mode, one-choke-point label
accessibility, an About/version surface, and palette-aware muted text.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

import hugmesh_studio                                          # noqa: E402
from hugmesh_studio import __version__, advanced_mode          # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo         # noqa: E402
from hugmesh_studio.gui import branding_icon, styles           # noqa: E402
from hugmesh_studio.gui import tray as tray_mod                # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod            # noqa: E402
from hugmesh_studio.gui.pages import fleet as fleet_mod        # noqa: E402
from hugmesh_studio.gui.pages import golive as golive_mod      # noqa: E402
from hugmesh_studio.gui.pages._widgets import _row             # noqa: E402
from hugmesh_studio.gui.qt import BINDING, QtWidgets           # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

# A host that CANNOT build anything (no native Gentoo, no Docker) -> default_backend "none".
NO_BACKEND = HostInfo(os="darwin", is_gentoo=False, has_docker=False, has_bash=True,
                      has_kvm=False, is_root=False, builder_image="hugmesh-builder")
# A Docker-only host (Windows/mac with Docker Desktop, or non-Gentoo Linux).
DOCKER = HostInfo(os="linux", is_gentoo=False, has_docker=True, has_bash=True,
                  has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def _make_wizard(qapp, host=DOCKER):
    """A real StudioWizard with a pinned host (patched at wizard_mod.detect)."""
    orig = wizard_mod.detect
    wizard_mod.detect = lambda builder_image="hugmesh-builder": host
    try:
        return wizard_mod.StudioWizard(GENERATOR_DIR)
    finally:
        wizard_mod.detect = orig


def _welcome(wiz):
    return next(p for p in wiz._pages if isinstance(p, wizard_mod.WelcomePage))


def _page(wiz, cls):
    return next(p for p in wiz._pages if isinstance(p, cls))


# ── P1-A: one brand icon, shared across every top-level window ────────────────────────
def test_brand_icon_is_a_real_painted_icon(qapp):
    assert not branding_icon.brand_icon().isNull()
    pm = branding_icon.brand_pixmap()
    assert pm.width() == branding_icon.ICON_PX and pm.height() == branding_icon.ICON_PX


def test_tray_reuses_the_shared_brand_mark(qapp):
    # the tray's private names are now aliases of the shared painter (no duplicate copy)
    assert tray_mod._brand_pixmap is branding_icon.brand_pixmap
    assert tray_mod._brand_icon is branding_icon.brand_icon


def test_every_top_level_window_carries_the_icon(qapp):
    wiz = _make_wizard(qapp)
    assert not wiz.windowIcon().isNull()
    gl = golive_mod.GoLiveWizard(GENERATOR_DIR)
    assert not gl.windowIcon().isNull()
    fw = fleet_mod.FleetWindow(GENERATOR_DIR)
    assert not fw.windowIcon().isNull()
    for w in (wiz, gl, fw):
        w.deleteLater()


# ── P1-B / P1-C: humane empty state + no dev jargon on the first screen ───────────────
def test_no_backend_host_gets_actionable_guidance(qapp):
    wiz = _make_wizard(qapp, host=NO_BACKEND)
    html = _welcome(wiz)._intro_html()
    assert "can't build images yet" in html
    assert "Docker Desktop" in html                 # tells the user how to fix it
    assert "Backend: none" not in html              # never the bare dev signal
    wiz.deleteLater()


def test_buildable_host_shows_its_backend(qapp):
    wiz = _make_wizard(qapp, host=DOCKER)
    html = _welcome(wiz)._intro_html()
    assert "docker" in html and "can't build" not in html
    wiz.deleteLater()


def test_welcome_drops_generator_flags_jargon(qapp):
    wiz = _make_wizard(qapp, host=DOCKER)
    html = _welcome(wiz)._intro_html()
    assert "generator's flags" not in html and "maps to the generator" not in html
    wiz.deleteLater()


# ── P2-A: the whole-release Fleet tool is gated behind expert mode ────────────────────
def _fleet_button(welcome):
    return next((b for b in welcome.findChildren(QtWidgets.QPushButton)
                 if b.text() == "Fleet build…"), None)


def test_fleet_button_hidden_by_default(qapp, monkeypatch):
    monkeypatch.delenv(hugmesh_studio.ADVANCED_ENV, raising=False)
    assert advanced_mode() is False
    wiz = _make_wizard(qapp)
    assert _fleet_button(_welcome(wiz)) is None      # off the public first screen
    wiz.deleteLater()


def test_fleet_button_shown_in_advanced_mode(qapp, monkeypatch):
    monkeypatch.setenv(hugmesh_studio.ADVANCED_ENV, "1")
    assert advanced_mode() is True
    wiz = _make_wizard(qapp)
    assert _fleet_button(_welcome(wiz)) is not None
    wiz.deleteLater()


def test_fleet_entry_still_reachable_via_method_when_gated(qapp, monkeypatch):
    # gating hides the BUTTON, never removes the capability: _fleet() (and --fleet) work
    monkeypatch.delenv(hugmesh_studio.ADVANCED_ENV, raising=False)
    wiz = _make_wizard(qapp)
    _welcome(wiz)._fleet()
    assert getattr(wiz, "fleet_window", None) is not None and wiz.fleet_window.isVisible()
    wiz.fleet_window.deleteLater()
    wiz.deleteLater()


# ── P2-B: raw CLI flags left the placeholders (moved into tooltips) ───────────────────
def test_hardware_placeholders_humanized_flags_in_tooltips(qapp):
    wiz = _make_wizard(qapp)
    hw = _page(wiz, wizard_mod.HardwarePage)
    for field, flag in ((hw.cpu, "--cpu"), (hw.defconfig, "--defconfig"),
                        (hw.dtb, "--dtb"), (hw.dtb_prefix, "--dtb-prefix"),
                        (hw.kernel_img, "--kernel-img")):
        assert flag not in field.placeholderText()   # no raw flag in the public prompt
        assert flag in field.toolTip()               # still discoverable by power users
    wiz.deleteLater()


def test_system_and_network_placeholders_humanized(qapp):
    wiz = _make_wizard(qapp)
    sysp = _page(wiz, wizard_mod.SystemPage)
    assert "--hostname" not in sysp.hostname.placeholderText()
    assert "--hostname" in sysp.hostname.toolTip()
    assert "--timezone" not in sysp.timezone.placeholderText()
    assert "--user" not in sysp.user.placeholderText()
    net = _page(wiz, wizard_mod.NetworkPage)
    assert "--headscale-version" not in net.headscale_version.placeholderText()
    assert "--headscale-version" in net.headscale_version.toolTip()
    assert "--tailscale-version" not in net.tailscale_version.placeholderText()
    wiz.deleteLater()


# ── P2-C: label -> field accessibility wired from the one _row choke point ────────────
def test_row_wires_buddy_and_accessible_name(qapp):
    le = QtWidgets.QLineEdit()
    row = _row("Hostname", le)
    lab = row.findChild(QtWidgets.QLabel)
    assert le.accessibleName() == "Hostname"
    assert lab is not None and lab.buddy() is le


# ── P3-A: an About/version surface replaces the stdout binding print ──────────────────
def test_version_constant_present():
    assert isinstance(__version__, str) and __version__.count(".") >= 1


def test_wizard_has_help_button_wired_to_about(qapp):
    wiz = _make_wizard(qapp)
    assert wiz.testOption(QtWidgets.QWizard.WizardOption.HaveHelpButton)
    assert wiz.button(QtWidgets.QWizard.WizardButton.HelpButton).text() == "About"
    about = wiz._about_text()
    assert __version__ in about
    # the license disclosure follows the ACTUAL runtime binding (LGPL vs GPL)
    if BINDING == "PySide6":
        assert "LGPL" in about
    elif BINDING == "PyQt6":
        assert "GPL" in about
    wiz.deleteLater()


# ── P3-B: mode descriptions use the shared muted colour, not near-invisible "gray" ────
def test_mode_descriptions_use_muted_not_bare_gray(qapp):
    wiz = _make_wizard(qapp)
    mode = _page(wiz, wizard_mod.ModePage)
    sheets = [lb.styleSheet() for lb in mode.findChildren(QtWidgets.QLabel)
              if lb.styleSheet()]
    assert any(styles.MUTED in s for s in sheets)
    assert not any("color: gray" in s for s in sheets)
    wiz.deleteLater()

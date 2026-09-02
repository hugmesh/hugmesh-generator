"""Issues #233 + #232 — ISO option enable/disable logic on the Review page.

Pins the BuildPage behaviour the operator's builder notes asked for:

* the Installer ISO row is GREYED (never hidden) on platforms whose builder does not
  parse --installer-iso — the Pi first among them — with the reason on the row
  (#233 "grey out installer iso option for unsupported (pi)");
* the two live-ISO sub-options grey out while Live ISO is deselected;
* "Skip the ISO stage" sits WITH the ISO rows and greys them while ticked;
* the root-image-size tooltip is rich text, so Qt word-wraps it instead of rendering
  one screen-crossing line (#232);
* the Image-options section explains its defaults in a visible hint (#232).

Pure widget-state assertions on the REAL wizard (Qt offscreen) — greying is
presentation only, so no argv assertions belong here (test_pages_build.py owns
emission). Headless-safe: nothing modal, nothing docker.
"""
import os

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.platform_info import HostInfo    # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod       # noqa: E402
from hugmesh_studio.gui.pages import build as build_mod   # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets               # noqa: E402

from _helpers import advance_to, pick_role                # noqa: E402

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


# ---- #233: installer ISO greyed (not hidden) where the builder has no flag --------

def test_installer_iso_greyed_with_reason_on_rpi5(wiz):
    """A Pi build shows the x86 Installer ISO row greyed, and the tooltip points at
    the row the Pi actually has (--iso) — the exact ask, not a silent hide."""
    pick_role(wiz, "generic")
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.installer_iso.isVisible()
    assert not build.installer_iso.isEnabled()
    assert not build.artifact_labels["installer_iso"].isEnabled()
    tip = build.installer_iso.toolTip()
    assert "--installer-iso" in tip and "--iso" in tip
    # the caption carries the same reason (no live caption beside a dead box)
    assert build.artifact_labels["installer_iso"].toolTip() == tip
    # ...while the Pi's OWN installer-ISO row stays live
    assert build.build_iso.isEnabled()


def test_installer_iso_greyed_on_frite_names_x86(wiz):
    """A builder with no ISO stage at all (frite) greys the row too, saying only the
    x86 builder parses the flag — derived from the support matrix, not hardcoded."""
    pick_role(wiz, "frite")
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.installer_iso.isVisible()
    assert not build.installer_iso.isEnabled()
    assert "x86" in build.installer_iso.toolTip()
    # the frite builder has no --skip-iso either: that row stays platform-HIDDEN
    assert not build.skip_iso.isVisible()


def test_installer_iso_enabled_on_x86(wiz):
    build = advance_to(wiz, wizard_mod.BuildPage)      # default x86 flow
    assert build.installer_iso.isVisible()
    assert build.installer_iso.isEnabled()
    assert build.installer_iso.toolTip() == ""


# ---- #233: live-ISO sub-options follow the Live ISO checkbox ----------------------

def test_live_iso_deselect_greys_suboptions(wiz):
    build = advance_to(wiz, wizard_mod.BuildPage)      # x86: live_iso default-checked
    assert build.cached.isEnabled() and build.live_toram.isEnabled()
    build.live_iso.setChecked(False)
    for w in (build.cached, build.live_toram,
              build.artifact_labels["cached"], build.artifact_labels["live_toram"]):
        assert not w.isEnabled(), w
    assert "Live ISO" in build.cached.toolTip()
    # the Live ISO box itself stays live — it is the way back
    assert build.live_iso.isEnabled()
    build.live_iso.setChecked(True)
    assert build.cached.isEnabled() and build.live_toram.isEnabled()


# ---- #233: skip-iso lives with the ISO rows and greys them ------------------------

def test_skip_iso_row_sits_with_the_iso_rows(wiz):
    """Row order is artifact_labels' insertion order: skip-iso directly follows the
    ISO block (…installer_iso, build_iso, sd_only) instead of sitting two rows from
    the bottom, a scroll away from the options it negates."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    keys = list(build.artifact_labels)
    assert keys.index("skip_iso") == keys.index("sd_only") + 1
    assert keys.index("skip_iso") < keys.index("build_tar")


def test_skip_iso_greys_the_iso_rows_on_x86(wiz):
    build = advance_to(wiz, wizard_mod.BuildPage)
    build.skip_iso.setChecked(True)
    for w in (build.live_iso, build.installer_iso, build.cached, build.live_toram):
        assert not w.isEnabled(), w
        assert "Skip the ISO stage" in w.toolTip(), w
    # non-ISO artifacts are untouched
    for w in (build.build_img, build.build_tar, build.compress, build.resume):
        assert w.isEnabled(), w
    build.skip_iso.setChecked(False)
    for w in (build.live_iso, build.installer_iso, build.cached, build.live_toram):
        assert w.isEnabled(), w
    # the flag-pair explanation comes back on the re-enabled Live ISO box
    assert build.live_iso.toolTip() == build_mod._FLAG_TIP


def test_skip_iso_greys_the_pi_iso_row(wiz):
    pick_role(wiz, "generic")                          # rpi5
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.build_iso.isEnabled()
    build.skip_iso.setChecked(True)
    assert not build.build_iso.isEnabled()
    assert "Skip the ISO stage" in build.build_iso.toolTip()
    # --sd-only is not an ISO option; it stays live
    assert build.sd_only.isEnabled()
    build.skip_iso.setChecked(False)
    assert build.build_iso.isEnabled()


def test_greying_is_presentation_only_never_rewrites_a_checkbox(wiz):
    """The page's gating split, held: _sync_iso_options greys, it never unchecks —
    value correctness stays with _preview/clear_unsupported."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    build.installer_iso.setChecked(True)
    build.cached.setChecked(True)
    build.skip_iso.setChecked(True)
    assert build.installer_iso.isChecked() and build.cached.isChecked()
    build.skip_iso.setChecked(False)
    assert build.installer_iso.isChecked() and build.cached.isChecked()


# ---- #232: the root-image-size tooltip wraps, and the defaults are explained ------

def test_img_size_tooltip_is_rich_text_so_it_wraps(wiz):
    """Qt renders a plain-text tooltip as ONE line; this one ran off small screens.
    Rich text word-wraps at a readable width — pin the <qt> wrapper that buys that."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    tip = build.img_size.toolTip()
    assert tip.startswith("<qt>") and tip.endswith("</qt>")
    assert "role default" in tip


def test_image_options_defaults_are_explained_on_screen(wiz):
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.image_defaults_hint.isVisible()
    text = build.image_defaults_hint.text()
    for phrase in ("Installer UI", "role default", "fill", "Release tag"):
        assert phrase in text, phrase


# ---- #233: the explainer copy is the rewritten one --------------------------------

def test_artifacts_explainer_is_the_rewritten_copy(wiz):
    build = advance_to(wiz, wizard_mod.BuildPage)
    text = build.artifacts_hint.text()
    assert "one build option and the file it produces" in text
    assert "Ticked = you get it" not in text
    # the changelog-speak is gone from the installer caption
    assert "no longer" not in build.artifact_labels["installer_iso"].text()

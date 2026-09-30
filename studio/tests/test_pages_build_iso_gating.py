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
    """A builder that does not parse --installer-iso (frite) greys the row too, saying
    the flag is x86's — derived from the support matrix, not hardcoded.

    The premise this docstring used to state — "a builder with no ISO stage at all
    (frite)" — was FALSE, and the tooltip it guarded said so to the operator. frite has
    a full ISO stage; what it lacks is a per-artifact FLAG. The corrected copy is
    asserted positively in test_installer_iso_note_sends_flavor_builders_to_the_flavor_
    control below, because an `"x86" in tooltip` check like the one here happily passes
    over wrong copy — which is how the false sentence shipped."""
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


# ---- #233 second pass: the three copy claims #236 shipped that were not true -----
#
# All three were UNGUARDED — which is exactly how they shipped. Each test below asserts
# the CORRECTED claim positively, not just the absence of the old wording, so a revert
# to a plausible-but-false string still fails.

def test_compress_caption_is_platform_aware_not_one_false_sentence(wiz):
    """--compress does not mean one thing, so one caption cannot be true.

    x86/rpi5/jetson compress IMG_PATH only (build-x86-host-stage4.sh:6756,
    build-rpi5-stage4.sh:4653, build-jetson-stage4.sh:2409); the seven flavor builders
    compress LIVE_PATH + INSTALLER_PATH and never an .img (build-frite-stage4.sh:2438,
    :2547). The caption #236 shipped — "every artifact above gains .xz" — was false on
    BOTH families and inverted between them."""
    build = advance_to(wiz, wizard_mod.BuildPage)          # x86
    x86 = build.artifact_labels["compress"].text()
    assert ".img" in x86 and "only artifact" in x86
    assert "every artifact above" not in x86

    # ...and the ISO family gets the INVERSE statement, so no one string can serve both
    frite = build_mod._compress_note("frite")
    assert "ISOs" in frite and "never touches the .img" in frite
    assert frite != x86, "one static caption cannot be true on both families"


def test_compress_caption_follows_the_platform_actually_selected(wiz):
    """The caption is restated on every visit (initializePage), not baked at widget
    construction — pick frite and the row ON SCREEN says what frite's --compress does."""
    pick_role(wiz, "frite")
    build = advance_to(wiz, wizard_mod.BuildPage)
    text = build.artifact_labels["compress"].text()
    assert text == build_mod._compress_note("frite")
    assert "never touches the .img" in text


def test_installer_iso_note_sends_flavor_builders_to_the_flavor_control(wiz):
    """On frite/orangepi the greyed row must NOT claim the builder makes no installer
    ISO — it makes one by default under --flavor both, which is what Studio emits. It
    points at the control that really owns the choice, the way the rpi5 branch already
    points at the --iso row."""
    pick_role(wiz, "frite")
    build = advance_to(wiz, wizard_mod.BuildPage)
    tip = build.installer_iso.toolTip()
    assert not build.installer_iso.isEnabled()
    assert "Flavor" in tip and "both" in tip
    assert "produces no installer ISO" not in tip
    # the caption carries the same reason (no live caption beside a dead box)
    assert build.artifact_labels["installer_iso"].toolTip() == tip


def test_installer_iso_note_still_says_no_iso_for_jetson():
    """The sentence is not deleted, it is SCOPED: jetson really does build no installer
    ISO (build-jetson-stage4.sh contains no installer.iso at all), so jetson keeps it —
    and must not be redirected to a Flavor control it does not have."""
    jetson = build_mod._installer_iso_note("jetson")
    assert "produces no installer ISO" in jetson
    assert "Flavor" not in jetson
    for p in ("frite", "orangepi5", "orangepizero2", "orangepizero2w",
              "orangepizero3", "orangepi3-lts", "orangepi4-lts"):
        assert "produces no installer ISO" not in build_mod._installer_iso_note(p), p


def test_artifacts_explainer_rule_describes_the_gate_that_exists(wiz):
    """The rewrite's own second sentence promised a CAPABILITY gate ("rows this
    platform's builder cannot make"). The gate keys on the FLAG, not the capability:
    frite hides the Live ISO row (live_iso is x86-only in PLATFORM_FIELD_SUPPORT) while
    building live.iso by default. Prove both halves — the hidden row on frite, and copy
    that no longer asserts the builder cannot make it."""
    pick_role(wiz, "frite")
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert not build.live_iso.isVisibleTo(build)          # the row really is hidden
    text = build.artifacts_hint.text()
    assert "does not parse" in text                        # flags, not capabilities
    assert "cannot make" not in text
    assert "hidden row is not a missing artifact" in text


# ---- #233's one unchecked box: the xz compression level --------------------------

def test_compress_level_is_a_dropdown_over_the_builders_whole_range(wiz):
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert isinstance(build.compress_level, QtWidgets.QComboBox)
    levels = [build.compress_level.itemData(i)
              for i in range(build.compress_level.count())]
    assert levels == list(range(10))                       # xz's own 0-9, what the
    #                                                        builders validate
    assert build.compress_level.currentData() == 9         # the builders' own level


def test_compress_level_greys_with_the_compress_box(wiz):
    """The sub-option shape reused from cached/live_toram: a preset with nothing to
    compress is greyed and says why, and Compress itself stays live as the way back."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.compress.isChecked() and build.compress_level.isEnabled()
    build.compress.setChecked(False)
    for w in (build.compress_level, build.compress_level_label,
              build.artifact_labels["compress_level"]):
        assert not w.isEnabled(), w
        assert "Tick Compress" in w.toolTip(), w
    assert build.compress.isEnabled()
    build.compress.setChecked(True)
    assert build.compress_level.isEnabled()
    assert build.compress_level.toolTip() == ""


def test_compress_level_greying_never_rewrites_the_value(wiz):
    """Presentation only, the page's standing rule — a preset chosen, un-ticked and
    re-ticked survives (and emits nothing at all while --compress is absent)."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    build.compress_level.setCurrentIndex(build.compress_level.findData(3))
    build.compress.setChecked(False)
    assert build.compress_level.currentData() == 3
    build._preview()
    assert "--compress-level" not in wiz.cfg.to_cli_args()
    build.compress.setChecked(True)
    assert build.compress_level.currentData() == 3


def test_compress_level_reaches_argv_only_off_its_default(wiz):
    build = advance_to(wiz, wizard_mod.BuildPage)
    build._preview()
    assert "--compress-level" not in wiz.cfg.to_cli_args()   # default 9: silent
    build.compress_level.setCurrentIndex(build.compress_level.findData(6))
    build._preview()
    args = wiz.cfg.to_cli_args()
    assert ("--compress-level", "6") in list(zip(args, args[1:]))
    assert "--compress" in args


@pytest.mark.parametrize("stored,shown,emitted", [
    (-1, 0, "0"),          # below the range: the nearest legal preset, not the default
    (99, 9, None),         # above it: clamps to 9, which is the level that emits nothing
    ("6", 6, "6"),         # a JSON string: int()-able, so it is a real level
    ("nine", 9, None),     # not a number at all: the builder default, no flag
])
def test_out_of_range_level_shows_exactly_what_it_will_ship(wiz, stored, shown, emitted):
    """The page and the argv must be the SAME function of the same --config JSON.

    The combo can only ever hold 0-9, but a hand-edited config can carry anything, so
    initializePage and ImageConfig._compress_level_args are two readings of one
    untrusted value. They were briefly different functions of it — findData() fell back
    to 9 where emission clamped to 0 — which made ONE config.json produce two different
    artifacts depending on whether the operator happened to open this page. Both now go
    through config.clamp_compress_level; this pins that they agree, which the other
    twelve level tests cannot, because they all set the level THROUGH the combo.
    """
    wiz.cfg.compress_level = stored
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.compress_level.currentData() == shown
    build._preview()
    args = wiz.cfg.to_cli_args()
    pairs = list(zip(args, args[1:]))
    if emitted is None:
        assert "--compress-level" not in args
    else:
        assert ("--compress-level", emitted) in pairs

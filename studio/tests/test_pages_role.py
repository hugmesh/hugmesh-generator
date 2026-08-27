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

from types import SimpleNamespace  # noqa: E402

from hugmesh_studio.core.config import (  # noqa: E402
    ImageConfig, ROLE_CHOICES, UNAFFILIATED_ROLE, x86_desktop_axis,
)
from hugmesh_studio.core.platform_info import HostInfo  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod  # noqa: E402
from hugmesh_studio.gui.pages.role import RolePage  # noqa: E402
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
                     "orangepizero3", "orangepi3-lts", "orangepi4-lts"}
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


# ---- x86 desktop-weight combo per role (desktop-axis honesty) ----------------------
# build-x86-host-stage4.sh hard-errors an explicit --desktop that contradicts a
# weight-pinning standalone role name, so the combo must never offer such a pick
# (same honesty rule as the rpi3 board gate). Client roles keep both weights.

def _weight_items(page):
    return [page.desktop.itemText(i) for i in range(page.desktop.count())]


def test_desktop_weight_combo_shrinks_to_the_pinned_weight(wiz):
    """standalone-thin offers only its own thin weight (+ the role default);
    standalone-thick / standalone-unaffiliated only full — 'standalone-thin/full'
    is a contradiction in terms the builder now rejects loudly."""
    pick_mode(wiz, "standalone")
    page = pick_role(wiz, "standalone-thin")
    assert _weight_items(page) == ["(default)", "thin"]
    pick_role(wiz, "standalone-thick")
    assert _weight_items(page) == ["(default)", "full"]
    pick_role(wiz, "standalone-unaffiliated")
    assert _weight_items(page) == ["(default)", "full"]


def test_desktop_weight_combo_keeps_both_weights_standalone_chromebook(wiz):
    """A person-device client role really takes both weights — the combo must not
    over-shrink (chromebook is the standalone-mode client role)."""
    pick_mode(wiz, "standalone")
    page = pick_role(wiz, "chromebook")
    assert _weight_items(page) == ["(default)", "thin", "full"]


def test_desktop_weight_combo_keeps_both_weights_cloud_desktop(wiz):
    """Cloud client roles keep both weights too — cloud/x86/desktop/thin is a REAL
    image after the cause-C fix, so thin must stay offered on the desktop role."""
    pick_mode(wiz, "cloud")
    page = pick_role(wiz, "desktop")
    assert _weight_items(page) == ["(default)", "thin", "full"]


def test_desktop_weight_explicit_thin_survives_the_desktop_role(wiz):
    """The cause-C regression pinned at the GUI layer: cloud/desktop + an explicit
    thin weight must emit --desktop thin (the builder no longer silently upgrades
    it to full, so the thin-weight desktop image is REAL and reachable here)."""
    pick_mode(wiz, "cloud")
    page = pick_role(wiz, "desktop")
    page.desktop.setCurrentText("thin")
    advance_to(wiz, wizard_mod.HardwarePage)
    args = wiz.cfg.to_cli_args()
    joined = " ".join(args)
    assert "--desktop thin" in joined
    assert (wiz.cfg.role, wiz.cfg.desktop) == ("desktop", "thin")


# ══════════════════════════════════════════════════════════════════════════════════════
# THE 2026-08-26 DE-DUPLICATION ROUND
#
# Operator report, verbatim: "standalone menu is asking same questions seemingly multiple
# times when nothing should be an image there related to the mesh or domain at all."
# Their image was role=standalone-unaffiliated / platform=x86 (session
# 20260826-151356-64070a, build-standalone-unaffiliated.x86.log). A measured headless walk
# proved no page is visited twice — every duplicate is a REPEATED QUESTION inside one
# screen or across two adjacent ones. The four this file owns:
#
#   (a) the machine SCAN, offered on RolePage AND on the very next HardwarePage;
#   (b) the knobs the chosen ROLE already pins (--standalone / --capable / desktop weight)
#       and --with-sunshine, which standalone mode has already answered;
#   (c) the TWO SPELLINGS of "unaffiliated" — the ROLE ROW and a composable checkbox on
#       the same screen, producing the identical image.
#
# The gates below are pinned in BOTH directions: every hide has a mutation guard proving
# the surface survives where it still means something. That is the whole risk of a
# de-duplication round — a rule that hid the control from everyone would satisfy the
# operator's report and silently delete four real capabilities.
# ══════════════════════════════════════════════════════════════════════════════════════

def _role_page(cfg):
    """RolePage against a stub wizard (it touches nothing but ``.cfg`` and
    ``.generator_dir``) — the same construction test_pages_fields_asks.py uses, so a gate
    can be probed for an arbitrary (mode, role, platform) without walking the flow."""
    page = RolePage(SimpleNamespace(cfg=cfg, generator_dir=GENERATOR_DIR))
    page.initializePage()
    return page


# ---- (a) ONE machine scanner in the flow -------------------------------------------

def test_the_machine_scan_is_offered_exactly_once(wiz):
    """DECISION 2(a). The scanner lived on two consecutive pages: a synthetic
    ``this-machine-scan`` row in RolePage's machine-profile combo (running hw_scan.scan()
    into a RolePage-local output label) and HardwarePage's "Scan THIS machine" button —
    same call, same three fields, same text template. It now exists only on HardwarePage,
    which owns the fields a scan writes."""
    role = advance_to(wiz, wizard_mod.RolePage)
    ids = [role.profile.itemData(i) for i in range(role.profile.count())]
    assert "this-machine-scan" not in ids, (
        "the synthetic scanner row is back in the machine-profile combo — that is the "
        "duplicate of HardwarePage's Scan button, one page earlier")
    assert not hasattr(role, "scan_out"), (
        "RolePage still carries the scan output label; with the scan gone it can only "
        "ever render empty")
    hw = advance_to(wiz, wizard_mod.HardwarePage)
    assert hw.scan_btn.isVisibleTo(hw) and hasattr(hw, "scan_out"), (
        "the surviving scanner must be the HardwarePage one — removing BOTH would also "
        "satisfy the assertions above")


def test_every_machine_profile_is_a_real_machine(wiz):
    """The mutation guard for the removal: the combo still lists the curated machines
    (only the ACTION row went), and each id resolves to a loaded profile."""
    role = advance_to(wiz, wizard_mod.RolePage)
    ids = [role.profile.itemData(i) for i in range(role.profile.count())
           if role.profile.itemData(i)]
    assert len(ids) > 30, f"the profile catalog collapsed to {len(ids)} entries"
    assert set(ids) == {pr.id for pr in role.profiles}, (
        "the combo and the loaded catalog disagree — a synthetic, machine-less row is "
        "exactly the shape the removed scanner entry had")
    assert "framework-13-intel" in ids       # the profile the fold tests above drive


# ---- (b) the knobs the ROLE already pins -------------------------------------------

@pytest.mark.parametrize("role", ["standalone-thin", "standalone-thick",
                                  UNAFFILIATED_ROLE])
def test_image_posture_is_hidden_where_the_role_presets_it(qapp, role):
    """build-x86-host-stage4.sh sets STANDALONE=true in the role arm itself (:1325 thin,
    :1332 thick, :1344 unaffiliated — RE-DERIVED against the current file, these first
    shipped as the pre-diff :1310/:1317/:1329), and the measured standalone walk emits no
    --standalone at all — so the "Image posture" box asked the operator to re-answer what
    the image type above had already decided. The SECTION goes with the checkbox: a
    mode-gated group must not leave an orphan header behind."""
    page = _role_page(ImageConfig(mode="standalone", role=role, platform="x86"))
    assert not page.standalone.isVisibleTo(page)
    assert not page.posture_box.isVisibleTo(page), (
        "the 'Image posture' header survived its only control")


@pytest.mark.parametrize("mode,role,platform", [
    ("standalone", "chromebook", "x86"),          # composes: a standalone Chromebook
    ("cloud", "laptop", "x86"),                   # composes: an FDE cloud laptop
    ("standalone", "orangepizero2", "orangepizero2"),   # the appliance's DEFINING posture
])
def test_image_posture_survives_where_it_genuinely_composes(qapp, mode, role, platform):
    """MUTATION GUARD for the gate above — and the finding-1 regression pin. A rule that
    keyed on "standalone mode" instead of "this role presets it" would hide the box on the
    Chromebook (where --standalone is the only way to drop the mesh plane) and on the ARM
    appliances, whose builders compose ${STANDALONE} unconditionally
    (build-orangepi-zero2-stage4.sh:637-648) and whose whole point it is."""
    page = _role_page(ImageConfig(mode=mode, role=role, platform=platform))
    assert page.standalone.isVisibleTo(page)
    assert page.posture_box.isVisibleTo(page)
    assert "compose the same posture" in page.standalone.toolTip()


def test_capable_is_hidden_only_where_the_role_presets_it(qapp):
    """--capable: :1332 and :1344 set CAPABLE=true for standalone-thick and
    standalone-unaffiliated, so the checkbox there is a no-op question. :1325 does NOT set
    it for standalone-thin — that is exactly the compose G21 was added for, so the
    checkbox stays. (Numbers RE-DERIVED; the pre-diff :1317/:1329/:1310 pointed at
    unrelated code.)"""
    for role in ("standalone-thick", UNAFFILIATED_ROLE):
        page = _role_page(ImageConfig(mode="standalone", role=role, platform="x86"))
        assert not page.capable.isVisibleTo(page), role
    page = _role_page(ImageConfig(mode="standalone", role="standalone-thin", platform="x86"))
    assert page.capable.isVisibleTo(page)
    assert page.capable.isEnabled()


def test_desktop_weight_row_is_hidden_when_the_role_pins_the_only_answer(qapp):
    """A combo offering "(default)" plus the one weight the role already pins is not a
    choice. The gate keys on the SAME x86_desktop_axis() the combo is filtered by, so the
    two can never disagree; the caption row and the weight help label go with it rather
    than being left as orphans over a hidden control."""
    for role in ("standalone-thin", "standalone-thick", UNAFFILIATED_ROLE):
        page = _role_page(ImageConfig(mode="standalone", role=role, platform="x86"))
        assert len(x86_desktop_axis(role)) == 1, role   # the premise
        assert not page.desktop_row.isVisibleTo(page), role
        assert not page.desktop_help.isVisibleTo(page), role


def test_desktop_weight_row_survives_on_a_role_with_a_real_choice(qapp):
    """MUTATION GUARD: the client roles really take both weights, so the row must stay —
    a rule that hid it everywhere would also pass the test above."""
    for mode, role in (("standalone", "chromebook"), ("cloud", "desktop"),
                       ("cloud", "laptop")):
        page = _role_page(ImageConfig(mode=mode, role=role, platform="x86"))
        assert len(x86_desktop_axis(role)) == 2, role   # the premise
        assert page.desktop_row.isVisibleTo(page), role
        assert page.desktop_help.isVisibleTo(page), role


def test_sunshine_is_hidden_and_cleared_on_a_standalone_image(qapp):
    """DECISION 2(d). Sunshine streams "to mesh headsets over the tailnet only", but
    ModePage's standalone arm force-clears both (`cfg.tailscale = cfg.sso = False`) — no
    tailnet for its nftables fence to admit. Unlike the role-pinned knobs above this is
    the INAPPLICABLE kind of hide, so the field is CLEARED: the builder's own drop-guard
    does not fire on this argv shape (the guard tested only SKIP_TAILSCALE||UNAFFILIATED, while
    --no-tailscale sets only SKIP_MESH; widened to include ${SKIP_MESH} in the same change
    set — `grep -n 'if ${WANT_SUNSHINE}'` finds it, since the line number has already moved
    twice this session), so a stale tick really would bake Sunshine onto
    a tailnet-less desktop."""
    cfg = ImageConfig(mode="standalone", role="chromebook", platform="x86", sunshine=True)
    page = _role_page(cfg)
    assert not page.sunshine.isVisibleTo(page)
    assert page.validatePage()
    assert cfg.sunshine is False, "a hidden Sunshine tick still rode the standalone argv"
    assert "--with-sunshine" not in cfg.to_cli_args()


def test_sunshine_survives_on_a_cloud_client_desktop(qapp):
    """MUTATION GUARD: cloud clients DO have the tailnet Sunshine's fence needs, so the
    checkbox — and its long "what does this bake" tooltip, which the gate helper blanks on
    every allowed pass — must both survive."""
    cfg = ImageConfig(mode="cloud", role="laptop", platform="x86", sunshine=True)
    page = _role_page(cfg)
    assert page.sunshine.isVisibleTo(page)
    assert "nftables fence" in page.sunshine.toolTip(), (
        "the in-scope tooltip was blanked by the gate and never restored")
    assert page.validatePage()
    assert cfg.sunshine is True
    assert "--with-sunshine" in cfg.to_cli_args()


# ---- (c) the TWO spellings of "unaffiliated" ----------------------------------------
#
# REWRITTEN 2026-08-26. The first cut of decision 2(c) hid the composable checkbox for the
# whole of standalone mode and cleared cfg.unaffiliated wherever it was hidden, and the
# two tests here pinned that drop. Both the premise and the code were wrong:
#
#   * PREMISE. "Both spellings produce the identical build" holds for standalone-thick
#     alone. build-x86-host-stage4.sh's standalone-unaffiliated arm PINS DESKTOP="full"
#     and CAPABLE=true (:1344), so `--role chromebook --unaffiliated` (a coreboot/UEFI
#     laptop image) and `--role standalone-thin --unaffiliated` (the light LXDE weight)
#     are images the role row CANNOT express. The hide deleted them from the wizard.
#   * CODE. The hide axis (mode != "standalone") was ANDed with the legality axis (mode ==
#     "standalone" and role != UNAFFILIATED_ROLE) into one `tickable`. They are mutually
#     exclusive on mode, so tickable was False in EVERY mode and validatePage's identical
#     pair cleared the field unconditionally — measured in
#     test_a_loaded_unaffiliated_config_is_not_rewritten_by_a_page_visit below.
#
# The rule these tests now pin: HIDE and CLEAR are separate axes, and only the
# INAPPLICABLE one clears (RolePage._unaffiliated_block).


def test_unaffiliated_is_hidden_only_on_the_role_that_already_is_it(qapp):
    """The duplicate the operator really reported: on ``standalone-unaffiliated`` the
    checkbox re-asks what the image-type row ONE LINE ABOVE has already answered — the
    builder's own role arm sets UNAFFILIATED=true there. So it is hidden AND cleared.

    The clear is safe precisely because it is argv-NEUTRAL: config.py emits the flag as
    ``if self.unaffiliated and self.role != UNAFFILIATED_ROLE``, so it was never going to
    ride this role's command line. That is asserted here rather than assumed — an
    argv-changing "neutral" clear is the defect this file exists to keep out."""
    cfg = ImageConfig(mode="standalone", role=UNAFFILIATED_ROLE, platform="x86",
                      unaffiliated=True)
    before = cfg.to_cli_args()
    page = _role_page(cfg)
    assert not page.unaffiliated.isVisibleTo(page)
    assert not page.unaffiliated.isEnabled()
    assert "IS the unaffiliated desktop" in page.unaffiliated.toolTip(), (
        "the hidden row must still carry the reason it is hidden")
    assert page.validatePage()
    assert cfg.unaffiliated is False
    assert cfg.to_cli_args() == before, (
        "the clear on the dedicated role moved the argv — it is only allowed because the "
        "emitter suppresses the flag on this role anyway")


@pytest.mark.parametrize("role", ["chromebook", "standalone-thin", "standalone-thick"])
def test_the_composable_flag_stays_offered_on_every_other_standalone_role(qapp, role):
    """MUTATION GUARD for the tautology. Hiding (or disabling) the checkbox across
    standalone mode makes ``--unaffiliated`` unreachable in EVERY mode, because cloud/mesh
    is where the compose is a builder hard-conflict — there is no third mode. On
    chromebook and standalone-thin it also deletes an image nothing else can build."""
    page = _role_page(ImageConfig(mode="standalone", role=role, platform="x86"))
    assert page.unaffiliated.isVisibleTo(page), (
        f"the composable --unaffiliated checkbox is unreachable on standalone/{role}")
    assert page.unaffiliated.isEnabled()
    assert "CANNOT" in page.unaffiliated.toolTip(), (
        "the in-scope tooltip — which is what now answers the operator's 'asked twice' "
        "report, instead of deleting the capability — was blanked by the gate")


def test_a_loaded_unaffiliated_config_is_not_rewritten_by_a_page_visit(qapp):
    """THE REGRESSION PIN for the 2026-08-26 defect, with the measured argv in full.

    ImageConfig(mode="standalone", role="chromebook", platform="x86", unaffiliated=True),
    walked with initializePage() + validatePage() and NOTHING touched:

        BEFORE  --role chromebook … --unaffiliated --snort …
        AFTER   --role chromebook … --no-tailscale --no-sso --snort … --bundle-source …

    --unaffiliated was gone and --bundle-source had appeared (validatePage's
    ``if c.role == UNAFFILIATED_ROLE or c.unaffiliated:`` no longer fired), so the image
    silently regained BRAND=hugmesh, the /etc/hugmesh marker tree, the hugmesh-* tooling,
    the HUGMESH_LIVE/HUGMESH_INSTALL volids and hugmesh.efi. The role row still read
    "chromebook" and nothing warned.

    This is the REDUNDANT axis (the role row offers a related spelling), and a redundant
    hide must never rewrite a loaded config — the same rule --capable states beside it."""
    cfg = ImageConfig(mode="standalone", role="chromebook", platform="x86",
                      unaffiliated=True)
    before = cfg.to_cli_args()
    assert "--unaffiliated" in before and "--bundle-source" not in before
    page = _role_page(cfg)
    assert page.unaffiliated.isChecked(), (
        "initializePage dropped the loaded tick — the restore is gated on something "
        "other than 'is this compose impossible'")
    assert page.validatePage()
    assert cfg.unaffiliated is True
    after = cfg.to_cli_args()
    assert "--unaffiliated" in after, "a page visit dropped --unaffiliated"
    assert "--bundle-source" not in after, (
        "--bundle-source was added to an unaffiliated image — the builder hard-errors on "
        "that pair (build-x86-host-stage4.sh:1410)")
    assert after == before, f"a page visit rewrote the image:\n {before}\n {after}"


def test_a_live_role_switch_does_not_untick_the_composable_flag(qapp):
    """MUTATION-BATTERY PIN (the one that survived the first pass). The regression test
    above cannot see a stray ``setChecked(False)`` in the gate, because on a page VISIT
    the gate runs from ``_role_changed`` BEFORE initializePage's restore, which puts the
    tick straight back. It is only reachable through a live ``currentRowChanged`` — the
    operator moving through the image-type list — and there an unconditional untick would
    silently drop --unaffiliated from a config they only browsed past.

    chromebook -> standalone-thin is the interesting move: both are REDUNDANT-axis roles,
    and both compose --unaffiliated into an image the standalone-unaffiliated row cannot
    express (it pins the full/capable weight)."""
    cfg = ImageConfig(mode="standalone", role="chromebook", platform="x86",
                      unaffiliated=True)
    page = _role_page(cfg)
    assert page.unaffiliated.isChecked()
    assert page.select_role("standalone-thin")
    assert page.unaffiliated.isChecked(), (
        "a role switch between two roles that both COMPOSE the flag unticked it")
    assert page.unaffiliated.isVisibleTo(page) and page.unaffiliated.isEnabled()
    assert page.validatePage()
    assert cfg.unaffiliated is True
    assert "--unaffiliated" in cfg.to_cli_args()


def test_unaffiliated_checkbox_still_explains_itself_outside_standalone(qapp):
    """MUTATION GUARD: cloud/mesh is the INAPPLICABLE axis — greyed, cleared, and the
    tooltip is the only place that explains why an unaffiliated cloud desktop is
    impossible. Hiding it there would answer the operator's question by concealing it."""
    page = _role_page(ImageConfig(mode="cloud", role="laptop", platform="x86"))
    assert page.unaffiliated.isVisibleTo(page)
    assert not page.unaffiliated.isEnabled()
    assert "hard-conflict" in page.unaffiliated.toolTip()


def test_the_cloud_clear_is_re_derived_from_cfg_not_from_the_widget(qapp):
    """BELT & BRACES on the axis that really must clear. The gate already leaves the box
    unticked in cloud mode, so deleting validatePage's own conjunct changes nothing UNLESS
    the box is ticked behind the gate's back — a failed re-gate, or a collect_all() after
    a ModePage switch that never re-visited this page. validatePage re-derives the axis
    from cfg, so it must still refuse; if it did not, ``to_cli_args()`` would RAISE
    (config._check_unaffiliated_conflicts hard-errors for mode cloud/mesh) and the
    BuildPage preview would show a traceback instead of a command."""
    cfg = ImageConfig(mode="cloud", role="laptop", platform="x86")
    page = _role_page(cfg)
    page.unaffiliated.setChecked(True)
    assert page.validatePage()
    assert cfg.unaffiliated is False, (
        "validatePage collected a tick the cloud gate had refused — the preview now raises")
    assert "--unaffiliated" not in cfg.to_cli_args()


# ---- the two hide REASONS carry different emission obligations ----------------------

def test_a_role_pinned_hide_does_not_rewrite_a_loaded_config(qapp):
    """The rule that separates the two kinds of hide. --standalone / --capable / an
    agreeing --desktop are REDUNDANT on standalone-thick: the builder's role arm sets the
    same values, so the image is identical whether the flags ride along or not. Clearing
    them would silently rewrite a loaded config on a mere page visit — so they are left
    alone. (Contrast test_sunshine_is_hidden_and_cleared_on_a_standalone_image, where the
    value would reach a builder that cannot honour it.)"""
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      standalone=True, capable=True, desktop="full")
    page = _role_page(cfg)
    assert not page.standalone.isVisibleTo(page)
    assert not page.capable.isVisibleTo(page)
    assert not page.desktop_row.isVisibleTo(page)
    assert page.validatePage()
    assert (cfg.standalone, cfg.capable, cfg.desktop) == (True, True, "full")


def test_the_out_of_scope_standalone_clear_still_fires(qapp):
    """REGRESSION PIN: adding the "redundant" arm must not weaken the ORIGINAL ask-21
    guard. standalone-thick/x86 is in scope; generic/rpi5 (an arm64 server appliance) is
    not, and a tick made on the former must still be dropped on the latter — the builder
    hard-errors on --standalone with a node role."""
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      standalone=True)
    page = _role_page(cfg)
    assert page.select_role("generic")
    assert not page.standalone.isVisibleTo(page)
    assert page.validatePage()
    assert cfg.standalone is False
    assert "--standalone" not in cfg.to_cli_args()


# ---- DECISION 1: an unaffiliated image has a LOOK but no IDENTITY -------------------

def test_the_unaffiliated_commit_splits_identity_from_look(qapp):
    """DECISION 1 (operator, 2026-08-26): "There should be the menu for adding the themes
    as in the branded images". RolePage used to blank EVERY branding field when the
    unaffiliated role was committed, which is why the theme menu was unreachable on that
    image. A brand IS an affiliation, but a wallpaper names nobody — so the LOOK fields
    survive the commit and the IDENTITY fields are still forced back to the neutral
    identity the builder demands."""
    cfg = ImageConfig(mode="standalone", role=UNAFFILIATED_ROLE, platform="x86",
                      theme="dark", branding_dir="/tmp/b", wallpaper="/tmp/w.png",
                      grub_background="/tmp/gb", grub_theme="/tmp/g",
                      login_background="/tmp/lb", accent_color="#ff0000",
                      color_scheme="BreezeDark",
                      brand="acme", brand_title="Acme Inc", org="acme",
                      brand_logo="/tmp/l.png", brand_locked=True)
    page = _role_page(cfg)
    assert page.validatePage()
    for fld, want in (("theme", "dark"), ("branding_dir", "/tmp/b"),
                      ("wallpaper", "/tmp/w.png"), ("grub_background", "/tmp/gb"),
                      ("grub_theme", "/tmp/g"), ("login_background", "/tmp/lb"),
                      ("accent_color", "#ff0000"), ("color_scheme", "BreezeDark")):
        assert getattr(cfg, fld) == want, f"LOOK field {fld} was blanked by the commit"
    # IDENTITY is reset to the DATACLASS DEFAULTS, not to "": the builder's conflict test
    # is "differs from the neutral identity" (:1383-1385), not "non-empty", so blanking
    # brand/brand_title/org would TRIP the very check it is meant to satisfy.
    assert (cfg.brand, cfg.brand_title, cfg.org) == ("hugmesh", "HugMesh Systems", "hugmesh")
    assert cfg.brand_logo == "" and cfg.brand_locked is False
    assert cfg.bundle_source is False        # unchanged: bundled source IS platform machinery


def test_a_branded_role_keeps_both_its_look_and_its_identity(qapp):
    """MUTATION GUARD for the split: the clear must still run only on the unaffiliated
    posture. A branded standalone desktop keeps everything."""
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      theme="dark", brand="acme", brand_locked=True)
    page = _role_page(cfg)
    assert page.validatePage()
    assert (cfg.theme, cfg.brand, cfg.brand_locked) == ("dark", "acme", True)

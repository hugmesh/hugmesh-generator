"""BuildPage — one widget idiom per kind of control + the collapsible sections.

Operator report (2026-07-29, verbatim): "there's a mixture of sections in the build
area that are dropdowns instead of buttons for the same kinds of thing, organize this
build page better."

The mixture was real and lived in the Artifacts box (build.py@42a9e50:269-288): three
'(builder default)/on/off' _tri_combo DROPDOWNS (root image / live ISO / rootfs tar)
interleaved among five CHECKBOX siblings answering the SAME kind of question — "do I
get this artifact?" — plus a fourth such dropdown for Secure Boot (:308). The fix pins
ONE idiom per kind:

* on/off build toggles are CHECKBOXES — TWO-STATE, always, with a definite default;
* pick-one VALUE enumerations (backend / --env / installer front-end / --grow) stay
  DROPDOWNS;
* actions (Packages… / Refresh preview / Build builder image now) stay PUSH BUTTONS.

ASK 13 (operator, verbatim, 2026-08): "cached iso, live iso, bundle, compress and resume
should all be default on and should include the artifacts as they're the same thing side
by side". The dropdowns had become tri-state CHECKBOXES in the first pass, whose
part-checked square meant "leave the builder's own default"; that square is ask 1's
complaint in the other direction and is gone. Every --flag/--no-flag box on this page is
now two-state and defaults CHECKED, which is what the builder's own default already was
(BUILD_IMG/LIVE_ISO/BUILD_TAR/SECURE_BOOT are all `true` — see the block above
build._flag_check). What the file pins therefore INVERTED, and the inversion is the fix,
not a slackening: the tests below now assert that no part-checked state survives and
that "unchecked" reaches the argv as a definite --no-<flag>.

"Image options" and "Artifacts" also stopped being two sections: an option and the
artifact it yields are ONE row now (build.artifact_labels).

...and the page is grouped with _widgets.Collapsible sections (the NetworkPage pattern,
test_pages_network_sections.py is the model for this file). The same trap applies and
is pinned again here: "collapsed" must never be confusable with the PLATFORM GATE that
clears unsupported fields, and no reorganization may change the emitted argv.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.platform_info import HostInfo            # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod               # noqa: E402
from hugmesh_studio.gui.qt import Qt, QtWidgets                   # noqa: E402
from hugmesh_studio.gui.pages import build as build_mod           # noqa: E402
from hugmesh_studio.gui.pages._widgets import Collapsible         # noqa: E402

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
    """Click Next until page_cls is current — failing loudly if the flow stalls.
    (Same harness as test_pages_build.py: BuildPage needs the upstream pages'
    collect, so it is reached by walking the real flow, never by setStartId.)"""
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


def _sections(build):
    return {
        "exec": build.exec_section, "worklist": build.worklist_section,
        "image": build.image_section, "artifacts": build.artifacts_section,
        "sb": build.sb_section, "plumbing": build.plumbing_section,
    }


# ------------------------------------------------ the report: one idiom per kind

def test_artifact_and_sb_toggles_are_all_checkboxes_no_dropdowns_left(wiz):
    """The reported mixture, pinned shut: every control in the Artifacts box and the
    Secure Boot toggle is a CHECKBOX — no QComboBox may reappear among same-kind
    toggle siblings."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.artifacts_box.findChildren(QtWidgets.QComboBox) == []
    assert build.sb_box.findChildren(QtWidgets.QComboBox) == []
    for w in (build.build_img, build.live_iso, build.installer_iso, build.build_iso,
              build.sd_only, build.build_tar, build.skip_iso, build.image_only,
              build.secure_boot):
        assert isinstance(w, QtWidgets.QCheckBox), w


def test_flag_pairs_are_two_state_and_default_checked(wiz):
    """THE INVERSE of the test this replaces (ask 13).

    It used to require all THREE states, because the tri-square was how the builder's own
    default round-tripped. Ask 13, verbatim: "cached iso, live iso, bundle, compress and
    resume should all be default on" — so the square is gone here exactly as it went from
    the NetworkPage service boxes, and the property it existed for is preserved a
    different way: the builder default for every one of these flags IS on, so a checked
    two-state box says it precisely.

    Swept over EVERY checkbox on the page rather than a hand-listed four, so a control
    added later cannot quietly arrive tri-state — that is how the page grew four of them."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    for box in (build.build_img, build.live_iso, build.build_tar, build.secure_boot):
        assert not box.isTristate(), box.text()
        assert box.checkState() == Qt.CheckState.Checked, box.text()
        assert "two-state" in box.toolTip().lower(), box.text()
    # ...and nothing anywhere else on the page kept a third state either.
    for box in build.findChildren(QtWidgets.QCheckBox):
        assert not box.isTristate(), box.text()
        assert box.checkState() != Qt.CheckState.PartiallyChecked, box.text()
    # ask 13's five, at their DEFINITE defaults: all five checked on arrival.
    for box in (build.cached, build.live_iso, build.bundle_source, build.compress,
                build.resume):
        assert box.isChecked(), box.text()


def test_value_enumerations_stay_dropdowns_and_actions_stay_buttons(wiz):
    """The other half of the idiom rule: dropdowns are reserved for pick-one VALUE
    enumerations, buttons for actions — so the artifact fix cannot be 'solved' by
    drifting everything to one widget type."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    for combo in (build.backend, build.env, build.installer_ui, build.grow):
        assert isinstance(combo, QtWidgets.QComboBox), combo
    assert build.grow.isEditable()          # a size cap ("16G") types straight in
    for btn in (build.packages_btn, build.preview_btn, build.build_image_btn):
        assert isinstance(btn, QtWidgets.QPushButton), btn


def test_the_tri_state_legend_went_with_the_third_state(wiz):
    """The legend explained the square. Ask 1's whole point is that a screen needing a
    paragraph to explain its own checkboxes has the wrong checkboxes, so removing the
    square without removing its paragraph would have left the page contradicting itself.

    Pinned as an ABSENCE plus a replacement: no legend attribute, no page text still
    teaching the square, and every flag-pair box carrying the two-state explanation on
    its own tooltip instead."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert not hasattr(build, "tri_legend")
    for lab in build.findChildren(QtWidgets.QLabel):
        low = lab.text().lower()
        assert "part-checked" not in low and "3-state" not in low, lab.text()
    for box in (build.build_img, build.live_iso, build.build_tar, build.secure_boot):
        tip = box.toolTip().lower()
        assert "--no-" in tip and "unchecked" in tip, box.text()


def test_flag_pair_emission_is_definite_in_both_directions(wiz):
    """The widget changed shape twice; what it EMITS must stay something the operator can
    read off the box. Checked emits --flag, unchecked emits --no-flag, and there is no
    longer any state that emits neither.

    The arriving default now puts --img/--live-iso/--tar/--secure-boot on the argv where
    it used to put nothing. That is the honesty change and NOT a build change: all four
    builder defaults are already `true` (build-x86-host-stage4.sh:231/236/238/484), so the
    added flags re-state what the builder would have done. Asserted here so the claim
    lives next to the emission it is about."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    build._preview()
    args = wiz.cfg.to_cli_args()
    for flag in ("--img", "--live-iso", "--tar", "--secure-boot"):
        assert flag in args, f"{flag} missing — checked stopped meaning definitely on"
    for flag in ("--no-img", "--no-live-iso", "--no-tar", "--no-secure-boot"):
        assert flag not in args, flag
    build.build_img.setChecked(True)
    build.live_iso.setChecked(False)
    build.secure_boot.setChecked(False)
    build._preview()
    args = wiz.cfg.to_cli_args()
    assert "--img" in args and "--live-iso" not in args
    assert "--no-live-iso" in args and "--no-secure-boot" in args
    assert (wiz.cfg.build_img, wiz.cfg.live_iso, wiz.cfg.secure_boot) == (
        "on", "off", "off")           # the stored domain is unchanged too


def test_a_loaded_tri_state_value_round_trips_onto_the_checkbox(wiz, monkeypatch):
    """initializePage must show a loaded config's tri-state (including the bool
    back-compat spelling ImageConfig._tri normalizes) — the restore half of the
    round-trip the old _set_tri did for the combos."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    # suppress the visited-pages re-collect so the injected values survive into
    # initializePage (the test_build_preview_resolves_unset_flavor idiom).
    monkeypatch.setattr(wiz, "collect_all", lambda: None)
    wiz.cfg.build_img = "on"
    wiz.cfg.build_tar = "off"
    wiz.cfg.secure_boot = True          # bool back-compat -> 'on'
    build.initializePage()
    assert build.build_img.checkState() == Qt.CheckState.Checked
    assert build.build_tar.checkState() == Qt.CheckState.Unchecked
    assert build.secure_boot.checkState() == Qt.CheckState.Checked


# ------------------------------------------------------------ collapsible sections

def test_every_section_is_collapsible(wiz):
    """Every section folds; content visibility is asserted only for sections in scope
    for the mode (standalone hides the mesh worklist — its own gate test below)."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    checked = 0
    for name, sec in _sections(build).items():
        assert isinstance(sec, Collapsible), name
        assert sec.toggle.isCheckable(), name
        sec.set_expanded(False)
        assert not sec.is_expanded(), f"{name} toggle did not collapse"
        assert not sec.content.isVisible(), f"{name} content did not collapse"
        sec.set_expanded(True)
        assert sec.is_expanded(), f"{name} toggle did not re-expand"
        if sec.isVisible():
            assert sec.content.isVisible(), f"{name} did not re-expand"
            checked += 1
    assert checked >= 4, "too few in-scope sections exercised to be meaningful"


def test_collapsing_never_disables_children(wiz):
    """WHY the sections are not checkable QGroupBoxes: unchecking one DISABLES its
    children, and 'greyed' is precisely the platform gate's signal here."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    build.artifacts_section.set_expanded(False)
    for w in (build.build_img, build.live_iso, build.installer_iso, build.skip_iso):
        assert w.isEnabled(), f"{w} was disabled by COLLAPSING — reads as a gate"


def test_default_expansion_keeps_the_review_surfaces_open(wiz):
    """A Review page must not hide what is being reviewed: execution, image options,
    artifacts and Secure Boot arrive expanded. Only the all-default advanced plumbing
    folds away."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.exec_section.is_expanded()
    assert build.image_section.is_expanded()
    assert build.artifacts_section.is_expanded()
    assert build.sb_section.is_expanded()
    assert not build.plumbing_section.is_expanded()
    # the operator's entry points really are on screen
    assert build.backend.isVisible() and build.packages_btn.isVisible()
    # ASK 13: the option and the artifact it yields are ONE row, so the artifact caption
    # must be on screen beside its box — not in a section one scroll away.
    assert build.build_img.isVisible()
    assert build.artifact_labels["build_img"].isVisible()
    assert ".img" in build.artifact_labels["build_img"].text()


def test_a_non_default_plumbing_value_forces_the_section_open(wiz, monkeypatch):
    """...but a folded section holding a non-default value would never be found — a
    loaded --skip-kernel (or a stashed extra-flags line) must open it (compared
    against ImageConfig's own dataclass defaults, the NetworkPage rule)."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert not build.plumbing_section.is_expanded()
    monkeypatch.setattr(wiz, "collect_all", lambda: None)
    wiz.cfg.skip_kernel = True
    build.initializePage()
    assert build.plumbing_section.is_expanded(), "an overridden value was hidden"
    wiz.cfg.skip_kernel = False
    wiz.cfg.extra_flags = "--frob"
    build.initializePage()
    assert build.plumbing_section.is_expanded(), "a stashed escape hatch was hidden"


def test_a_manual_expansion_survives_revisits(wiz):
    """The fold default is re-derived every visit; a section the operator opened by
    hand (toggle.click — a real interaction) must not be re-folded underneath them."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert not build.plumbing_section.is_expanded()
    build.plumbing_section.toggle.click()
    assert build.plumbing_section.is_expanded()
    build.initializePage()               # revisit with an all-default config
    assert build.plumbing_section.is_expanded(), (
        "the operator's manual expansion was re-folded on revisit")


# ------------------------------------------- THE TRAP: collapsed != platform-gated

def test_collapsing_every_section_does_not_change_the_emitted_argv(wiz):
    """EMISSION SAFETY, the central requirement: collapsing is presentation only —
    _preview/validatePage read widget VALUES (which a hidden widget keeps), and
    clear_unsupported keys on the capability table, never on visibility."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    build.build_img.setCheckState(Qt.CheckState.Unchecked)
    build.live_iso.setCheckState(Qt.CheckState.Checked)
    build.cached.setChecked(True)
    build.skip_kernel.setChecked(True)
    build._preview()
    expanded_argv = wiz.cfg.to_cli_args()

    for sec in _sections(build).values():
        sec.set_expanded(False)
    QtWidgets.QApplication.processEvents()
    build._preview()
    collapsed_argv = wiz.cfg.to_cli_args()

    assert collapsed_argv == expanded_argv, (
        "collapsing a section changed the emitted argv — collapse must be "
        "presentation only")
    # non-vacuity: the argv actually carries the collapsed sections' values
    assert "--no-img" in expanded_argv and "--live-iso" in expanded_argv
    assert "--cached" in expanded_argv and "--skip-kernel" in expanded_argv


def test_a_value_set_while_its_section_is_folded_still_collects(wiz):
    """No config field is lost to the reorganization: a value set while its section
    is FOLDED (e.g. restored by a config load) still reaches the argv."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    build.plumbing_section.set_expanded(False)
    build.seed_url.setText("https://example.org/stage3/")
    build.pentest.setChecked(True)
    build._preview()
    args = wiz.cfg.to_cli_args()
    assert ("--seed-url", "https://example.org/stage3/") in zip(args, args[1:])
    assert wiz.cfg.pentest is True      # env knob: in cfg, never argv (G40)


def test_sb_platform_gate_hides_the_whole_section_not_just_the_box(wiz):
    """The gate targets the SECTION so ARM leaves no orphan 'Secure Boot signing'
    header over nothing (the NetworkPage egress-section lesson) — and the gate is
    still the capability table's, not the fold state's."""
    pick_role(wiz, "generic")            # standalone rpi5: no --secure-boot flag
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert not build.sb_section.isVisible(), "orphan Secure Boot section header"
    assert not build.sb_box.isVisible()


def test_sb_section_comes_back_in_scope_on_x86(wiz):
    """Non-vacuity for the gate test above + collapse-vs-gate disambiguation: on x86
    the section shows, and FOLDING it must not read as (or become) the gate — the
    section stays visible and enabled, only its content hides."""
    build = advance_to(wiz, wizard_mod.BuildPage)      # default flow = x86
    assert build.sb_section.isVisible() and build.sb_box.isVisible()
    build.sb_section.set_expanded(False)
    assert build.sb_section.isVisible(), "collapse hid the section header itself"
    assert build.sb_section.isEnabled() and build.secure_boot.isEnabled()
    assert not build.sb_box.isVisible()                 # folded means folded...
    build.sb_section.set_expanded(True)
    assert build.sb_box.isVisible()                     # ...and comes back


def test_worklist_section_gates_with_mode_and_no_orphan_packages_label(wiz):
    """Mode gating carries the section WITH its content (no orphan collapsible
    header), and the single-image Packages row is gated as a ROW — gating only the
    button used to leave a stray 'Packages' label on the mesh page."""
    build = advance_to(wiz, wizard_mod.BuildPage)       # standalone
    assert not build.worklist_section.isVisible()
    assert not build.worklist_group.isVisible()
    assert build.packages_row.isVisible() and build.packages_btn.isVisible()


def test_worklist_section_shows_in_mesh_and_packages_row_hides_whole(wiz):
    pick_mode(wiz, "mesh")
    wl_page = advance_to(wiz, wizard_mod.WorklistPage)
    wl_page.row_for_id("omnibus.x86").setCheckState(0, Qt.CheckState.Checked)
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.worklist_section.isVisible()
    assert build.worklist_group.isVisible()
    assert not build.packages_row.isVisible(), "orphan 'Packages' label in mesh"
    assert not build.packages_btn.isVisible()


def test_sections_live_inside_the_scroll_area(wiz):
    """Cooperate with _scroll.py rather than fight it: collapsing shrinks the scroll
    content and the scrollbar retires naturally — the page scrolls, never resizes."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    scroll = build.findChild(QtWidgets.QScrollArea)
    assert scroll is not None
    for sec in _sections(build).values():
        assert scroll.isAncestorOf(sec), sec
    assert scroll.widgetResizable()


def test_no_stray_tri_helper_left_on_this_page(qapp):
    """Neither retired factory may come back: _tri_combo (the dropdown idiom the operator
    reported in 2026-07) nor _tri_check (the tri-state box ask 13 replaced). A new call
    site cannot quietly reintroduce either, which is what kept happening — the second was
    itself the fix for the first."""
    assert not hasattr(build_mod, "_tri_combo")
    assert not hasattr(build_mod, "_tri_check")
    assert not hasattr(build_mod, "_tri_value")
    # its replacement carries the whole contract this file pins
    box = build_mod._flag_check("probe (--probe / --no-probe)")
    assert not box.isTristate()
    assert box.checkState() == Qt.CheckState.Checked
    assert build_mod._flag_value(box) == "on"
    box.setChecked(False)
    assert build_mod._flag_value(box) == "off"       # never "" — ask 13
    # the restore half: a config value still normalizes onto the box, including the
    # '' a --config JSON or a headless caller may still legitimately carry.
    build_mod._set_flag(box, "off")
    assert not box.isChecked()
    build_mod._set_flag(box, "")
    assert box.isChecked(), "'' must read as checked — the builder default is ON"

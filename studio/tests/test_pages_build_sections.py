"""BuildPage — one widget idiom per kind of control + the collapsible sections.

Operator report (2026-07-29, verbatim): "there's a mixture of sections in the build
area that are dropdowns instead of buttons for the same kinds of thing, organize this
build page better."

The mixture was real and lived in the Artifacts box (build.py@42a9e50:269-288): three
'(builder default)/on/off' _tri_combo DROPDOWNS (root image / live ISO / rootfs tar)
interleaved among five CHECKBOX siblings answering the SAME kind of question — "do I
get this artifact?" — plus a fourth such dropdown for Secure Boot (:308). The fix pins
ONE idiom per kind:

* on/off build toggles are CHECKBOXES — tri-state (the NetworkPage G34 idiom, square =
  leave the builder default) where the builder has a --flag/--no-flag pair;
* pick-one VALUE enumerations (backend / --env / installer front-end / --grow) stay
  DROPDOWNS;
* actions (Packages… / Refresh preview / Build builder image now) stay PUSH BUTTONS.

...and groups the page with _widgets.Collapsible sections (the NetworkPage pattern,
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


def test_tri_state_pairs_keep_all_three_states(wiz):
    """Do NOT collapse the flag-pairs to plain checkboxes: the combo they replaced
    existed so the builder's own default could round-trip ('' emits neither --flag
    nor --no-flag). The tri-state square is that emit-nothing state — a two-state
    box would collapse it to an explicit on/off on first visit."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    for box in (build.build_img, build.live_iso, build.build_tar, build.secure_boot):
        assert box.isTristate(), box.text()
        # the default really is the square (= leave the builder default)
        assert box.checkState() == Qt.CheckState.PartiallyChecked, box.text()
        assert "3-state" in box.toolTip()
    # ...and the single-flag toggles stay two-state — tri-stating a single positive
    # flag would invent a "force off" state the builder has no flag for.
    for box in (build.installer_iso, build.build_iso, build.sd_only,
                build.skip_iso, build.image_only):
        assert not box.isTristate(), box.text()


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


def test_tri_state_legend_is_visible_not_just_a_tooltip(wiz):
    """The NetworkPage lesson, applied on arrival: the square's meaning must be on the
    page in words — a hover tooltip alone produced the 'partially selected but it's
    not clear why' report over there."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.tri_legend.isVisible()
    text = build.tri_legend.text().lower()
    assert "part-checked" in text or "partly" in text
    assert "default" in text          # the square MEANS "leave the builder default"
    assert "square" in text


def test_tri_checkbox_emission_is_byte_identical_to_the_old_dropdowns(wiz):
    """The widget changed shape; the config domain must not have: square emits neither
    flag, checked emits --flag, unchecked emits --no-flag — exactly what the combos'
    ''/'on'/'off' currentData() produced."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    build._preview()
    args = wiz.cfg.to_cli_args()
    for flag in ("--img", "--no-img", "--live-iso", "--no-live-iso", "--tar",
                 "--no-tar", "--secure-boot", "--no-secure-boot"):
        assert flag not in args       # all squares -> the builder's own defaults
    build.build_img.setCheckState(Qt.CheckState.Checked)
    build.live_iso.setCheckState(Qt.CheckState.Unchecked)
    build.secure_boot.setCheckState(Qt.CheckState.Unchecked)
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
    assert build.build_img.isVisible() and build.tri_legend.isVisible()


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


def test_no_stray_tri_combo_helper_left(qapp):
    """The _tri_combo factory is gone — a new call site cannot quietly reintroduce
    the dropdown idiom the operator reported."""
    assert not hasattr(build_mod, "_tri_combo")
    # its replacement carries the whole contract this file pins
    box = build_mod._tri_check("probe (--probe / --no-probe)")
    assert box.isTristate()
    assert box.checkState() == Qt.CheckState.PartiallyChecked
    assert build_mod._tri_value(box) == ""

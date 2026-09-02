"""NetworkPage — the collapsible sections and the services-legibility reports.

Report (3): "options like tor, character studio and edge ai are partially selected but
it's not clear why. If this is selectable per node, make sure that there's another
option for this in another table like with the node images."

  * The square WAS the G34 tri-state's "leave the brand-profile/builder default" state,
    and the first fix made its meaning visible with a legend rather than removing it.
    The operator came back (ask 1, verbatim: "gui studio should leave optional services
    and edge ai unchecked instead of half checked for default no") — a screen that needs
    a paragraph to explain its own checkboxes has the wrong checkboxes. So the state is
    GONE: every service box is two-state with a definite default, and unchecked emits the
    strongest "off" the flag has. The tests below pin the absence, and pin that "off"
    still reaches the argv — that property was the reason the third state existed, and
    losing it would have been a real regression rather than a simplification.
  * Per-node: NO. Answered from the builders, not from UI convenience —
    ``build-rpi5-stage4.sh:1394`` gate_optional_services() prunes unselected slugs out of
    the CLUSTER GitOps tree at ``${SYSROOT}/var/lib/hugmesh/cluster``, and ``:2958``
    bakes that tree into EVERY cluster-class node. With app-of-apps recurse+prune, two
    nodes with different service sets = two conflicting desired states for one cluster,
    where the surviving tree DELETES the other's services. Studio's own model agrees:
    ``core/worklist.py`` WorklistEntry has no service field. So the page states the
    mesh-wide truth instead of growing a per-node table for a control the platform does
    not have.

Report (4): the page is a long flat wall -> collapsible sections. The trap this file
exists to pin: "collapsed" must never be confusable with the PLATFORM GATING that
CLEARS unsupported fields.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import (                          # noqa: E402
    BUILTIN_DEFAULT_SERVICES, ImageConfig,
)
from hugmesh_studio.core.platform_info import HostInfo            # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod               # noqa: E402
from hugmesh_studio.gui.qt import Qt, QtWidgets                   # noqa: E402
from hugmesh_studio.gui.pages.network import (                    # noqa: E402
    _AI_GROUP, _BACKING_GROUP, NetworkPage,
)

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
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _net(wiz, **cfg_kw):
    """The NetworkPage as the operator meets it: the wizard's CURRENT page, shown and
    initialized for the given config.

    It must genuinely be the current page — isVisible() is False for every widget on a
    non-current QWizardPage, which would make every visibility assertion here pass or
    fail for the wrong reason.
    """
    pid = [i for i in wiz.pageIds() if isinstance(wiz.page(i), NetworkPage)][0]
    wiz.cfg = ImageConfig(**cfg_kw)
    wiz.setStartId(pid)
    wiz.restart()                       # fires initializePage() with cfg in place
    wiz.setStartId(-1)
    QtWidgets.QApplication.processEvents()
    page = wiz.page(pid)
    assert wiz.currentPage() is page
    return page


def _sections(page):
    return {
        "identity": page.identity_section, "tailnet": page.tailnet_section,
        "mesh": page.mesh_section, "egress": page.egress_section,
        "security": page.security_section,
        # edge_ai and the backing services are GROUPS of the services table since ask 23,
        # not page sections, so they are not in this map. Their fold and their mode gate
        # are pinned directly, below.
        "services": page.services_section,
    }


# ------------------------------------------------- (1)/(4) no half-checked boxes remain

def test_no_service_box_is_tristate_and_none_start_half_checked(wiz):
    """ASK 1 + ASK 4. Every box in this section is an ordinary two-state checkbox with a
    DEFINITE default, and that default is the state the builder would actually produce.

    Sweeps `service_boxes` rather than a hand-listed five, so a service added later
    cannot quietly arrive tri-state — that is exactly how the page grew six of them.

    "Definite" is the property, not "off": ask 23 says pre-check what is genuinely on by
    default, and BUILTIN_DEFAULT_SERVICES is what an untouched build ships
    (`OPTIONAL_SERVICES="${OPTIONAL_SERVICES:-akkoma tuwunel phpbb}"`). Those three arrive
    ticked; everything else arrives unticked; nothing arrives half."""
    page = _net(wiz, mode="mesh", role="backend", platform="x86")
    for name, box in (("aide", page.aide), ("edge-ai", page.edge_ai),
                      *page.service_boxes.items()):
        assert not box.isTristate(), f"{name} is still a 3-state box"
        assert box.checkState() != Qt.CheckState.PartiallyChecked, f"{name} half-checked"
        assert box.isChecked() == (name in BUILTIN_DEFAULT_SERVICES), (
            f"{name} does not default to what the builder would produce")


def test_the_tri_state_legend_is_gone_because_there_is_nothing_left_to_explain(wiz):
    """The legend paragraph WAS the fix for report (3); ask 1 is the operator saying the
    fix was the wrong one. Pin its absence, not just the boxes' shape — a legend left
    behind would describe a state the page can no longer be in."""
    page = _net(wiz, mode="mesh", role="backend", platform="x86")
    assert not hasattr(page, "tri_legend"), (
        "the 3-state legend survived the two-state conversion")
    for lab in page.findChildren(QtWidgets.QLabel):
        assert "part-checked" not in lab.text().lower(), lab.text()


def test_unchecked_still_reaches_the_argv_as_a_definite_off(wiz):
    """The property the third state existed for, kept. A brand profile (-C) can set
    WANT_TOR=true (build-x86-host-stage4.sh sources brand.conf at :888, BEFORE the arg
    loop at :891), so an unchecked box that emitted NOTHING would leave the service on
    while claiming otherwise. Unchecked emits --no-*; the box never lies."""
    page = _net(wiz, mode="mesh", role="backend", platform="x86")
    page.validatePage()
    argv = wiz.cfg.to_cli_args()
    for flag in ("--no-tor", "--no-character-studio", "--no-character-forge",
                 "--no-edge-ai-tts", "--no-aide", "--no-edge-ai"):
        assert flag in argv, f"{flag} missing — unchecked stopped meaning definitely off"


# ------------------------------------------------- (3) the per-node question, answered

def test_page_states_that_services_are_mesh_wide_not_per_node(wiz):
    """The honest answer to "is this selectable per node?" is stated on the page."""
    page = _net(wiz, mode="mesh", role="backend", platform="x86")
    assert page.services_scope_note.isVisible()
    text = page.services_scope_note.text().lower()
    assert "once" in text and "mesh" in text
    assert "not per node" in text or "not per-node" in text


def test_page_admits_the_node_scoped_registry_nuance(wiz):
    """tor and egress-vpn ARE node-scoped in specs/cluster/optional-services.yaml
    (`scope: node`), but Studio emits them mesh-wide today. Say so rather than imply a
    per-node control exists — the gap is queued as a feature, not hidden."""
    page = _net(wiz, mode="mesh", role="backend", platform="x86")
    text = page.services_node_scope_note.text().lower()
    assert "tor" in text and "egress-vpn" in text and "mesh-wide" in text


def test_no_per_node_service_table_was_invented(wiz):
    """Guard against the ungrounded fix: Studio's model has no per-node service axis
    (core/worklist.py WorklistEntry), so no per-node service table may exist."""
    from hugmesh_studio.core.worklist import WorklistEntry
    fields = set(WorklistEntry.__dataclass_fields__)
    for service_field in ("optional_services", "tor_onion_service", "character_studio",
                          "edge_ai_service", "edge_ai_tts"):
        assert service_field not in fields, (
            f"WorklistEntry grew {service_field}: services became per-node, so the GUI's "
            "mesh-wide claim is now a lie — revisit the note and the builders")


# ------------------------------------------------------------ (4) collapsible sections

def test_every_section_is_collapsible(wiz):
    """Report (4): every section folds. Content visibility is only asserted for sections
    the mode gate actually shows — in mesh, tailnet is gate-hidden, and expanding it must
    NOT resurrect it (that is the trap, pinned in its own test below)."""
    page = _net(wiz, mode="mesh", role="backend", platform="x86")
    checked = 0
    for name, sec in _sections(page).items():
        assert sec.toggle.isCheckable(), name
        sec.set_expanded(False)
        assert not sec.is_expanded(), f"{name} toggle did not collapse"
        assert not sec.content.isVisible(), f"{name} content did not collapse"
        sec.set_expanded(True)
        assert sec.is_expanded(), f"{name} toggle did not re-expand"
        if sec.isVisible():          # in scope for this mode -> content comes back
            assert sec.content.isVisible(), f"{name} did not re-expand"
            checked += 1
    assert checked >= 4, "too few in-scope sections exercised to be meaningful"


def test_collapsing_never_disables_children(wiz):
    """WHY this is not a checkable QGroupBox: unchecking one DISABLES its children, and
    in this wizard "greyed" is precisely gate_widgets' signal for "your platform cannot
    do this". A collapsed section would be indistinguishable from a gated one."""
    page = _net(wiz, mode="mesh", role="backend", platform="x86")
    page.services_section.set_expanded(False)
    for w in (page.services_box, page.tor_onion, page.character_studio, page.games,
              page.service_boxes["akkoma"]):
        assert w.isEnabled(), f"{w} was disabled by COLLAPSING — reads as a gate"


def test_default_expansion_keeps_required_and_reported_sections_open(wiz):
    """Default expansion must not hide something the operator must set. Identity carries
    the required brand/apex domain; services is the section both reports were about."""
    page = _net(wiz, mode="mesh", role="backend", platform="x86")
    assert page.identity_section.is_expanded()
    assert page.services_section.is_expanded()
    assert page.mesh_section.is_expanded()        # carries the superdomain
    assert page.services_box.isVisible() and page.tor_onion.isVisible()


def test_all_default_optional_sections_start_collapsed(wiz):
    """The point of the change: an all-default optional section folds away, so the page
    is not a flat wall on arrival."""
    page = _net(wiz, mode="mesh", role="backend", platform="x86")
    assert not page.security_section.is_expanded()
    # edge-AI's fold is now its table row's sub-options (ask 23): the service row itself
    # is always on screen — it is one service among the others — and what folds away
    # while everything is default is its default-model / analysis-API sub-rows.
    assert not page.edge_ai_item.isExpanded()


def test_a_non_default_value_forces_its_section_open(wiz):
    """...but a section holding a non-default/problem value must NOT be folded away —
    the operator would never find it."""
    # snort DEFAULTS to True, so the override that must force the section open is
    # snort=False — the expansion rule reads ImageConfig's declared defaults, not
    # a guess about which way each flag points.
    page = _net(wiz, mode="mesh", role="backend", platform="x86", snort=False)
    assert page.security_section.is_expanded(), "an overridden value was hidden"
    # aide's dataclass default is False, which the two-state box reads as UNCHECKED and
    # collects back as "off" — so "off" is now the DEFAULT picture and cannot be the
    # override that forces the section open. "on" is.
    page = _net(wiz, mode="mesh", role="backend", platform="x86", aide="on")
    assert page.security_section.is_expanded(), "a forced-ON service box was hidden"
    page = _net(wiz, mode="mesh", role="backend", platform="x86", root_login="yes")
    assert page.security_section.is_expanded()


def test_the_edge_ai_role_auto_check_forces_its_row_open(wiz):
    """The edge_ai ROLE auto-selects the service; that must be visible, not folded.

    The carrier changed (a table row's expander, not a page section) but the property is
    identical, and it is the reason the rule exists at all: a value the operator did not
    set must never land inside something folded shut."""
    page = _net(wiz, mode="mesh", role="edge-ai", platform="x86")
    assert page.edge_ai.isChecked()
    assert page.edge_ai_item.isExpanded()
    assert page.group_items[_AI_GROUP].isExpanded()


def test_section_titles_are_not_eaten_as_mnemonics(wiz):
    """QToolButton is a QAbstractButton, so '&' in its text becomes a MNEMONIC:
    "Identity & Domain" rendered as "Identity _Domain". Caught by looking at the page,
    not by any assertion — hence this one."""
    page = _net(wiz, mode="mesh", role="backend", platform="x86")
    assert page.identity_section.title() == "Identity & Domain"
    # the displayed text must carry the escaped form, or Qt swallows the ampersand
    assert page.identity_section.toggle.text() == "Identity && Domain"


def test_out_of_scope_egress_section_leaves_no_orphan_header(wiz):
    """The role-class gate hides the egress field + lock, but the section header and
    _row()'s caption are not gate members — a mesh node showed an "Egress VPN" header
    over an empty body."""
    page = _net(wiz, mode="mesh", role="backend", platform="x86")
    assert not page.egress_row.isVisibleTo(page), "precondition: egress gated off"
    assert not page.egress_section.isVisible(), "orphan Egress VPN section header"


def test_in_scope_egress_section_is_shown_and_usable(wiz):
    """Non-vacuity for the test above: the section must really come back in scope."""
    page = _net(wiz, mode="cloud", role="laptop", platform="x86")
    assert page.egress_section.isVisible()
    assert page.egress_row.isVisibleTo(page)


def test_mode_gated_sections_hide_their_header_too(wiz):
    """A mode-gated group must not leave an orphan section header that expands to
    nothing."""
    page = _net(wiz, mode="standalone", role="standalone-thick", platform="x86")
    assert not page.mesh_section.isVisible() and not page.mesh_box.isVisible()
    # edge-AI's mode gate hides its TABLE GROUP ROW, which takes the edge-AI row and both
    # sub-rows with it — the table's equivalent of "no orphan header".
    assert page.group_items[_AI_GROUP].isHidden()
    assert page.group_items[_BACKING_GROUP].isHidden()
    assert not page.tailnet_section.isVisible()
    assert page.tailnet_reason.isVisible(), "the explain-why note went with the section"


# ------------------------------------------- THE TRAP: collapsed != platform-gated

def test_collapsing_every_section_does_not_change_the_emitted_argv(wiz):
    """EMISSION SAFETY, the central requirement: collapsing is presentation only.

    Structural, not a convention: validatePage() reads widget VALUES (which a hidden
    widget keeps), and _gating.clear_unsupported keys on platform_supports(field,
    platform) — the capability table — never on widget visibility.
    """
    page = _net(wiz, mode="mesh", role="backend", platform="x86")
    page.service_boxes["akkoma"].setChecked(True)
    page.character_studio.setChecked(True)
    page.tor_onion.setChecked(False)          # definite OFF
    page.snort.setChecked(True)
    page.domain.setText("example.org")

    page.validatePage()
    expanded_argv = wiz.cfg.to_cli_args()

    for sec in _sections(page).values():
        sec.set_expanded(False)
    QtWidgets.QApplication.processEvents()
    page.validatePage()
    collapsed_argv = wiz.cfg.to_cli_args()

    assert collapsed_argv == expanded_argv, (
        "collapsing a section changed the emitted argv — collapse must be presentation "
        "only")
    # non-vacuity: the argv actually carries the collapsed sections' values
    assert "--with-character-studio" in expanded_argv
    assert "--no-tor" in expanded_argv


def test_collapsed_is_not_confused_with_the_platform_gate_that_clears(wiz):
    """The trap named explicitly. clear_unsupported() must reset a field because the
    PLATFORM cannot do it — never because its section happens to be folded."""
    # x86 supports character_studio: collapsed or not, the value survives.
    page = _net(wiz, mode="mesh", role="backend", platform="x86")
    page.character_studio.setChecked(True)
    page.services_section.set_expanded(False)
    page.validatePage()
    assert wiz.cfg.character_studio is True, (
        "a supported field was cleared because its section was collapsed")

    # frite does NOT support it: the gate clears it even with the section EXPANDED.
    page = _net(wiz, mode="cloud", role="frite", platform="frite")
    page.services_section.set_expanded(True)
    page.character_studio.setChecked(True)
    page.validatePage()
    assert wiz.cfg.character_studio is False, (
        "the platform gate stopped clearing — expansion must not defeat it")


def test_collapse_does_not_leak_a_gate_hidden_widget(wiz):
    """Qt tracks the explicit hidden flag per widget, so expanding a section must not
    resurrect a child the ROLE-CLASS gate hid (egress on a node-class image)."""
    page = _net(wiz, mode="mesh", role="backend", platform="x86")
    assert not page.egress_row.isVisibleTo(page), "precondition: egress gated off"
    page.egress_section.set_expanded(False)
    page.egress_section.set_expanded(True)
    assert not page.egress_row.isVisibleTo(page), (
        "expanding the section resurrected a gate-hidden widget")


def test_gating_while_collapsed_does_not_leak_the_widget_out(wiz):
    """The other direction: re-gating a child VISIBLE while its section is collapsed
    must not show it through the collapsed container."""
    page = _net(wiz, mode="mesh", role="backend", platform="x86")
    page.services_section.set_expanded(False)
    page.character_studio.setVisible(True)      # what a re-gate does
    assert not page.character_studio.isVisible(), (
        "a re-gated widget leaked out of a collapsed section")


def test_sections_live_inside_the_scroll_area(wiz):
    """Cooperate with #341's _scroll.py rather than fight it: the collapsibles are in the
    scroll content, so collapsing shrinks the content height and the scrollbar retires
    naturally — the page scrolls, it never resizes the window."""
    page = _net(wiz, mode="mesh", role="backend", platform="x86")
    scroll = page.findChild(QtWidgets.QScrollArea)
    assert scroll is not None
    assert scroll.isAncestorOf(page.services_section)
    assert scroll.widgetResizable()


def test_a_manual_expansion_survives_leaving_and_returning_to_the_page(wiz):
    """The fold default is re-derived from the config on every visit (initializePage),
    which used to throw away the operator's own expansion every time they stepped
    Next/Back over the page: open Security, walk away, come back, it is folded again.

    A section the operator opened by hand must stay open for the session.
    """
    page = _net(wiz, mode="mesh", role="backend", platform="x86")
    assert not page.security_section.is_expanded()      # all-default: folded on arrival
    # click the header, exactly as the operator does (`clicked` is what marks it touched;
    # calling set_expanded() directly would not, and must not — that is the page's own
    # programmatic path).
    page.security_section.toggle.click()
    assert page.security_section.is_expanded()
    page = _net(wiz, mode="mesh", role="backend", platform="x86")   # re-initializePage
    assert page.security_section.is_expanded(), (
        "the operator's manual expansion was re-folded on revisit")


def test_an_untouched_section_still_tracks_the_config_on_revisit(wiz):
    """The other half: respecting a manual fold must NOT freeze the default. A section
    the operator never touched keeps re-deriving, so a change made on an EARLIER page
    still opens the section that shows it (picking the edge_ai role auto-checks the
    service). This is what a blunt first-visit-only seed would have broken.
    """
    page = _net(wiz, mode="mesh", role="backend", platform="x86")
    assert not page.edge_ai_item.isExpanded()
    page = _net(wiz, mode="mesh", role="edge-ai", platform="x86")   # role changed earlier
    assert page.edge_ai_item.isExpanded(), (
        "an untouched fold stopped tracking the config")


def test_manual_expansion_state_is_presentation_only(wiz):
    """Belt and braces on the load-bearing invariant: touching the folds changes no argv."""
    page = _net(wiz, mode="mesh", role="backend", platform="x86")
    page.validatePage()
    before = list(wiz.cfg.to_cli_args())
    for sec in _sections(page).values():
        sec.toggle.click()                  # flip every section by hand
    page.validatePage()
    assert list(wiz.cfg.to_cli_args()) == before


def test_collapsed_is_not_the_mode_gate_on_the_edge_ai_group(wiz):
    """THE TRAP, carried over to the table. "Folded" and "the mode gate says no" must stay
    two distinguishable states, or a folded group reads as an inapplicable one.

    They are now two DIFFERENT calls on the same item — setExpanded (fold) and setHidden
    (gate) — which is what makes them impossible to confuse. The old section could only
    express both through visibility, which is why the gate had to live on the section and
    never on its content box.
    """
    # applicable mode, all-default => the group is IN the table (gate says yes) and its
    # service row is there; only the edge-AI row's sub-options are folded.
    page = _net(wiz, mode="cloud", role="backend", platform="x86")
    ai = page.group_items[_AI_GROUP]
    assert not ai.isHidden(), "the mode gate wrongly hid an applicable group"
    assert not page.edge_ai_item.isHidden()
    assert not page.edge_ai_item.isExpanded(), "all-default sub-options should be folded"
    # folding the GROUP by hand must not be mistaken for the gate…
    ai.setExpanded(False)
    assert not ai.isHidden(), "collapsing a group must not gate it"
    # …and the values survive the fold, so nothing about the argv moves.
    page.validatePage()
    assert wiz.cfg.edge_ai_service == "off"
    # inapplicable mode => the gate hides the group row, and with it every child.
    page = _net(wiz, mode="standalone", role="generic", platform="rpi5")
    assert page.group_items[_AI_GROUP].isHidden()


# ─────────────────────────────────────────────────────────────────────────────────────
# OPERATOR REPORT 2026-08-26, verbatim: "standalone menu is asking same questions
# seemingly multiple times when nothing should be an image there related to the mesh or
# domain at all. There should also be no inbetween menu for configuring domain."
#
# The image was role=standalone-unaffiliated / platform=x86
# (out/sessions/20260826-151356-64070a/build-standalone-unaffiliated.x86.log). Three of
# the six defects that report named live on this page's SECTIONS, so they are pinned
# here; the emission halves are in test_pages_identity.py.
#
# The whole block leans on ONE rule, which is why it sits next to
# test_out_of_scope_egress_section_leaves_no_orphan_header and
# test_mode_gated_sections_hide_their_header_too: hide the SECTION, not just the inner
# box. A Collapsible whose content is gated away still draws its header and still
# expands — to nothing.
# ─────────────────────────────────────────────────────────────────────────────────────

def test_the_domain_rows_are_gone_on_a_standalone_x86_image(wiz):
    """DEFECT 1 — "There should also be no inbetween menu for configuring domain".

    core/config.py::_x86_args keeps --cluster-domain / --games-domain / --release-state
    inside `if self.mode in ("cloud", "mesh")`, so on a standalone x86 image not one of
    them can reach the argv — yet the page offered a prefilled "hugmesh.net" apex box.

    _row() captions are asserted through the ROW, not the inner widget: gating the
    QLineEdit alone would have left "Public apex domain" floating over nothing, which is
    the same orphan-caption bug the egress row already had.
    """
    page = _net(wiz, mode="standalone", role="standalone-thick", platform="x86")
    for name in ("domain_row", "games_domain_row", "release_state_row"):
        assert not getattr(page, name).isVisibleTo(page), f"{name} still on screen"
    assert page.identity_reason.isVisible(), "the explain-why note went with the rows"
    assert "cloud and mesh" in page.identity_reason.text()


def test_the_domain_row_STAYS_on_a_standalone_rpi5_image(wiz):
    """The non-vacuity half, and the regression the platform-scoped predicate exists to
    prevent. A blanket `mode == "standalone"` hide would have looked right on the
    operator's x86 image and silently blanked a field NINE arm64 builders parse:
    core/config.py::_arm_common_args emits --cluster-domain with no mode fork at all, and
    _rpi5_args does the same for --release-state / --games-domain. A standalone rpi5
    'generic' image really does carry a cluster domain (build-rpi5-stage4.sh:3386) —
    'generic' is the one standalone role that bakes a cluster GitOps tree (G16)."""
    page = _net(wiz, mode="standalone", role="generic", platform="rpi5")
    for name in ("domain_row", "games_domain_row", "release_state_row"):
        assert getattr(page, name).isVisibleTo(page), f"{name} wrongly hidden on rpi5"
    assert page.identity_section.isVisible()
    assert not page.identity_reason.isVisible()


def test_the_identity_section_header_goes_with_its_last_row(wiz):
    """DEFECT 1 + 3, meeting the orphan-header rule. On a standalone UNAFFILIATED x86
    image BOTH axes reject — the brand trio and the brand profile because a brand IS an
    affiliation (core/config.py::_check_unaffiliated_conflicts raises on them), the
    cluster trio because the x86 builder bakes no cluster plane in standalone mode. Every
    row inside identity_box is then hidden, so the section itself must go: otherwise the
    page keeps a bold "Identity & Domain" header that expands to an empty box."""
    page = _net(wiz, mode="standalone", role="standalone-unaffiliated", platform="x86")
    for name in ("brand_profile_row", "brand_row", "brand_title_row", "org_row",
                 "domain_row", "games_domain_row", "release_state_row"):
        assert not getattr(page, name).isVisibleTo(page), f"{name} still on screen"
    assert not page.identity_box.isVisible()
    assert not page.identity_section.isVisible(), "orphan Identity & Domain header"
    # …and the note that replaces it is a PAGE-LEVEL sibling, like tailnet_reason, so it
    # survives the section's own hide. A note inside the box would have vanished with it.
    assert page.identity_reason.isVisible(), (
        "the whole section disappeared with no explanation on screen")


def test_a_half_rejected_identity_section_keeps_its_header(wiz):
    """Non-vacuity for the test above: the section must only vanish when it is EMPTY. An
    affiliated standalone desktop still owns a brand, so the header stays and carries the
    four rows that survive."""
    page = _net(wiz, mode="standalone", role="standalone-thick", platform="x86")
    assert page.identity_section.isVisible()
    for name in ("brand_profile_row", "brand_row", "brand_title_row", "org_row"):
        assert getattr(page, name).isVisibleTo(page), f"{name} wrongly hidden"


def test_the_identity_help_line_describes_only_what_is_on_screen(wiz):
    """DEFECT 2 — the orphan help text. The fixed sentence ended "...distinct from the
    internal superdomain below", but the superdomain row lives in mesh_box, which every
    standalone flow hides. Same treatment as tailnet_reason: say only what is true of
    THIS visit."""
    # cloud/mesh: both halves present AND the superdomain really is below.
    page = _net(wiz, mode="mesh", role="backend", platform="x86")
    assert page.superdomain_row.isVisibleTo(page), "precondition"
    assert "superdomain below" in page.identity_help.text()
    # standalone rpi5: apex domain yes, superdomain no -> the dangling clause must go.
    page = _net(wiz, mode="standalone", role="generic", platform="rpi5")
    assert not page.superdomain_row.isVisibleTo(page), "precondition"
    assert "apex domain" in page.identity_help.text()
    assert "superdomain" not in page.identity_help.text(), (
        "the help line still points at a row that is not on the page")
    # standalone x86: brand only.
    page = _net(wiz, mode="standalone", role="standalone-thick", platform="x86")
    assert "brand identity" in page.identity_help.text().lower()
    assert "apex domain" not in page.identity_help.text()
    assert "superdomain" not in page.identity_help.text()
    # Nothing left: no sentence at all, and the label carries its OWN hide rather than
    # merely inheriting the section's. Asserted against identity_box, not against the
    # page: isVisibleTo(page) is False here for BOTH labels-that-hid-themselves and
    # labels-inside-a-hidden-box, so it could not tell the two apart and a mutation that
    # dropped `identity_help.setVisible(...)` escaped it (mutation battery M13).
    # isVisibleTo(identity_box) asks only "would it show if its own box were shown".
    page = _net(wiz, mode="standalone", role="standalone-unaffiliated", platform="x86")
    assert page.identity_help.text() == ""
    assert not page.identity_help.isVisibleTo(page.identity_box), (
        "an empty help label is still taking a line in the section")


def test_the_services_section_header_goes_with_its_box(wiz):
    """DEFECT 5 — the orphan SERVICES header. services_scope_note and
    services_node_scope_note are added to `svc_content`, OUTSIDE services_box, and it is
    svc_content the collapsible wraps. Hiding only the box therefore left a standalone
    desktop with a "Services & apps" header plus two paragraphs of mesh-wide prose
    ("Chosen ONCE for the whole mesh…", "tor and egress-vpn are node-scoped…") over an
    invisible picker."""
    for role in ("standalone-thick", "standalone-unaffiliated"):
        page = _net(wiz, mode="standalone", role=role, platform="x86")
        assert not page.services_box.isVisible(), f"{role}: precondition"
        assert not page.services_section.isVisible(), f"{role}: orphan services header"
        assert not page.services_scope_note.isVisibleTo(page), (
            f"{role}: mesh-wide prose left on a standalone screen")
        assert not page.services_node_scope_note.isVisibleTo(page), f"{role}: ditto"


def test_the_services_section_survives_where_the_cluster_is_real(wiz):
    """Non-vacuity for the test above, on both sides of the interesting boundary.

    * standalone rpi5 'generic' is NODE-class and DOES bake the cluster tree (G16), so it
      keeps the picker even though it is a standalone image;
    * a CLOUD x86 desktop keeps it too — deliberately. That path is left exactly as it
      was: a branded cloud client can legitimately be re-rolled as a node later, so the
      honest treatment there is the heads-up note, not a disappearance.
    """
    page = _net(wiz, mode="standalone", role="generic", platform="rpi5")
    assert page.services_section.isVisible() and page.services_box.isVisible()
    page = _net(wiz, mode="cloud", role="laptop", platform="x86")
    assert page.services_section.isVisible() and page.services_box.isVisible()
    assert page.services_role_note.isVisible(), (
        "the cloud desktop path lost the heads-up note it is supposed to keep")


def test_a_re_gate_on_every_visit_brings_the_hidden_rows_back(wiz):
    """THE OTHER HALF OF THE HOUSE RULE, and the one a hide-only fix always forgets: a
    field that becomes applicable again must be REACHABLE and EMITTED again.

    Structural rather than conventional — every gate above is computed inside
    initializePage from cfg, and QWizard fires initializePage on each visit, so there is
    no cached "already hidden" state to go stale. Driven here by re-entering the same
    page object with a different config."""
    page = _net(wiz, mode="standalone", role="standalone-unaffiliated", platform="x86")
    assert not page.identity_section.isVisible() and not page.services_section.isVisible()
    page = _net(wiz, mode="mesh", role="backend", platform="x86")
    for name in ("brand_profile_row", "brand_row", "brand_title_row", "org_row",
                 "domain_row", "games_domain_row", "release_state_row"):
        assert getattr(page, name).isVisibleTo(page), f"{name} never came back"
    assert page.identity_section.isVisible()
    assert page.services_section.isVisible() and page.services_box.isVisible()
    assert not page.identity_reason.isVisible()
    # and it emits again — the value, not just the widget, has to survive the round trip
    page.domain.setText("example.org")
    page.validatePage()
    assert ("--cluster-domain", "example.org") in list(
        zip(wiz.cfg.to_cli_args(), wiz.cfg.to_cli_args()[1:]))


def test_the_standalone_subtitle_does_not_promise_a_brand_it_hid(wiz):
    """DEFECT 6 — the last mesh-plane leak the sweep turned up, and the same orphan-prose
    class as defect 2, one level up. The standalone subtitle read "Brand identity, the
    optional egress VPN and the host security stack…" on EVERY standalone image — on an
    unaffiliated one it named a section the page had just gated away.

    The flag behind it is computed once, at the top of initializePage, and read by three
    surfaces (this subtitle, the brand rows, the services picker) — one spelling, which
    is itself part of the operator's ask."""
    page = _net(wiz, mode="standalone", role="standalone-thick", platform="x86")
    assert "Brand identity" in page.subTitle(), "precondition: an affiliated desktop"
    page = _net(wiz, mode="standalone", role="standalone-unaffiliated", platform="x86")
    assert "Brand identity" not in page.subTitle(), page.subTitle()
    assert "unaffiliated" in page.subTitle().lower()
    assert "no brand" in page.subTitle().lower()

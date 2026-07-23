"""NetworkPage — the collapsible sections and the tri-state legibility reports.

Report (3): "options like tor, character studio and edge ai are partially selected but
it's not clear why. If this is selectable per node, make sure that there's another
option for this in another table like with the node images."

  * The square is the G34 tri-state's "leave the brand-profile/builder default" state.
    All three states are REQUIRED — a plain two-state box could never force a brand.conf
    (-C) default back OFF — so the fix is to make the meaning VISIBLE, not to remove it.
  * Per-node: NO. Answered from the builders, not from UI convenience —
    ``build-rpi5-stage4.sh:1376`` gate_optional_services() prunes unselected slugs out of
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

from hugmesh_studio.core.config import ImageConfig                # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo            # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod               # noqa: E402
from hugmesh_studio.gui.qt import Qt, QtWidgets                   # noqa: E402
from hugmesh_studio.gui.pages.network import NetworkPage          # noqa: E402

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
        "security": page.security_section, "edge_ai": page.edge_ai_section,
        "services": page.services_section,
    }


# ---------------------------------------------------------------- (3) tri-state legend

def test_tri_state_legend_is_visible_not_just_a_tooltip(wiz):
    """The report's actual cause: the meaning of the square existed ONLY as a hover
    tooltip. It must be on the page, in words, without hovering."""
    page = _net(wiz, mode="mesh", role="backend", platform="x86")
    assert page.tri_legend.isVisible()
    text = page.tri_legend.text().lower()
    assert "part-checked" in text or "partly" in text
    assert "default" in text          # the square MEANS "leave the default"
    # and it must explain the confusing default state itself
    assert "square" in text


def test_tri_state_boxes_keep_all_three_states(wiz):
    """Do NOT collapse the tri-state to a plain checkbox: a two-state box could only
    ever emit the positive flag, so a brand profile's (-C) default could never be
    forced OFF (--no-tor / --no-character-studio / --no-edge-ai)."""
    page = _net(wiz, mode="mesh", role="backend", platform="x86")
    for box in (page.aide, page.edge_ai, page.tor_onion, page.character_studio,
                page.edge_ai_tts):
        assert box.isTristate(), box.text()
    # the default really is the square (which is what prompted the report)
    assert page.tor_onion.checkState() == Qt.CheckState.PartiallyChecked
    assert page.character_studio.checkState() == Qt.CheckState.PartiallyChecked
    # the tooltip is kept as well as the legend, not replaced by it
    assert "3-state" in page.tor_onion.toolTip()


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
    for w in (page.services_box, page.services, page.tor_onion, page.character_studio,
              page.games):
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
    assert not page.edge_ai_section.is_expanded()


def test_a_non_default_value_forces_its_section_open(wiz):
    """...but a section holding a non-default/problem value must NOT be folded away —
    the operator would never find it."""
    # snort DEFAULTS to True, so the override that must force the section open is
    # snort=False — the expansion rule reads ImageConfig's declared defaults, not
    # a guess about which way each flag points.
    page = _net(wiz, mode="mesh", role="backend", platform="x86", snort=False)
    assert page.security_section.is_expanded(), "an overridden value was hidden"
    page = _net(wiz, mode="mesh", role="backend", platform="x86", aide="off")
    assert page.security_section.is_expanded(), "a forced-OFF tri-state was hidden"
    page = _net(wiz, mode="mesh", role="backend", platform="x86", root_login="yes")
    assert page.security_section.is_expanded()


def test_the_edge_ai_role_auto_check_forces_its_section_open(wiz):
    """The edge_ai ROLE auto-selects the service; that must be visible, not folded."""
    page = _net(wiz, mode="mesh", role="edge_ai", platform="x86")
    assert page.edge_ai.checkState() == Qt.CheckState.Checked
    assert page.edge_ai_section.is_expanded()


def test_section_titles_are_not_eaten_as_mnemonics(wiz):
    """QToolButton is a QAbstractButton, so '&' in its text becomes a MNEMONIC:
    "Identity & domain" rendered as "Identity _domain". Caught by looking at the page,
    not by any assertion — hence this one."""
    page = _net(wiz, mode="mesh", role="backend", platform="x86")
    assert page.identity_section.title() == "Identity & domain"
    # the displayed text must carry the escaped form, or Qt swallows the ampersand
    assert page.identity_section.toggle.text() == "Identity && domain"


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
    assert not page.edge_ai_section.isVisible() and not page.edge_ai_box.isVisible()
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
    page.services.item(0).setCheckState(Qt.CheckState.Checked)
    page.character_studio.setCheckState(Qt.CheckState.Checked)
    page.tor_onion.setCheckState(Qt.CheckState.Unchecked)     # force OFF
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
    page.character_studio.setCheckState(Qt.CheckState.Checked)
    page.services_section.set_expanded(False)
    page.validatePage()
    assert wiz.cfg.character_studio is True, (
        "a supported field was cleared because its section was collapsed")

    # frite does NOT support it: the gate clears it even with the section EXPANDED.
    page = _net(wiz, mode="cloud", role="frite", platform="frite")
    page.services_section.set_expanded(True)
    page.character_studio.setCheckState(Qt.CheckState.Checked)
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
    assert not page.edge_ai_section.is_expanded()
    page = _net(wiz, mode="mesh", role="edge_ai", platform="x86")   # role changed earlier
    assert page.edge_ai_section.is_expanded(), (
        "an untouched section stopped tracking the config")


def test_manual_expansion_state_is_presentation_only(wiz):
    """Belt and braces on the load-bearing invariant: touching the folds changes no argv."""
    page = _net(wiz, mode="mesh", role="backend", platform="x86")
    page.validatePage()
    before = list(wiz.cfg.to_cli_args())
    for sec in _sections(page).values():
        sec.toggle.click()                  # flip every section by hand
    page.validatePage()
    assert list(wiz.cfg.to_cli_args()) == before


def test_collapsed_is_not_the_mode_gate_on_the_edge_ai_box(wiz):
    """edge_ai_box is the edge-AI section's collapsible CONTENT, so its visibility means
    "expanded". The MODE gate must therefore be pinned on the SECTION — setting it on the
    box too would give one flag two meanings, and a collapsed section would read as an
    inapplicable one.
    """
    # applicable mode, all-default => section SHOWN (gate says yes) but folded.
    page = _net(wiz, mode="cloud", role="backend", platform="x86")
    assert page.edge_ai_section.isVisible(), "the mode gate wrongly hid an applicable section"
    assert not page.edge_ai_section.is_expanded()
    assert not page.edge_ai_box.isVisible(), "collapsed content should be hidden"
    # inapplicable mode => the gate hides the whole section, header and all.
    page = _net(wiz, mode="standalone", role="generic", platform="rpi5")
    assert not page.edge_ai_section.isVisible()

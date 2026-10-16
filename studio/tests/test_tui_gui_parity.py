"""GUI <-> TUI surface parity (#51 phase 2) — the two faces of one Studio.

Runs the REAL Qt pages offscreen (importorskip, like every GUI suite) and pins
the TUI's journey surfaces against them item for item: choice ids, JOURNEY
order, routing targets, labels and derived allow-sets. Where the shared truth
already lives in core (WIZARD_PAGE_SLUGS, DOMAIN_IDP_CHOICES, theme.BG_EFFECTS)
the TUI consumes it directly and the pin is structural; where the GUI page owns
the literal (card lists, labels), THESE tests are what keeps the mirror honest.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import e2e_environments as env_mod           # noqa: E402
from hugmesh_studio.core import emulation as em                       # noqa: E402
from hugmesh_studio.core import qemu_tests as qt                      # noqa: E402
from hugmesh_studio.core.config import (                               # noqa: E402
    VAULT_FIELDS, WIZARD_PAGE_SLUGS, Domain, ImageConfig)
from hugmesh_studio.core.platform_info import HostInfo                 # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                    # noqa: E402
from hugmesh_studio.gui.pages import _theme_editor                     # noqa: E402
from hugmesh_studio.gui.pages import domains as gui_domains            # noqa: E402
from hugmesh_studio.gui.pages import localcloud_nodes as gui_lc        # noqa: E402
from hugmesh_studio.gui.pages import vault as gui_vault                # noqa: E402
from hugmesh_studio.gui.pages import welcome as gui_welcome            # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                            # noqa: E402
from hugmesh_studio.tui import domains_step, journey, themes           # noqa: E402
from hugmesh_studio.tui import e2e as tui_e2e                          # noqa: E402
from hugmesh_studio.tui import localcloud as tui_lc                    # noqa: E402
from hugmesh_studio.tui import localmesh as tui_lm                     # noqa: E402
from hugmesh_studio.tui import qemu as tui_qemu                        # noqa: E402

from _helpers import advance_to                                        # noqa: E402

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
    w.show()          # offscreen: gives the wizard a current page to walk from
    yield w
    w.close()


# ── the canonical page order: one source, both faces ────────────────────────────────
def test_tui_page_order_is_the_wizard_slug_tuple():
    assert journey.PAGE_ORDER is WIZARD_PAGE_SLUGS


# ── welcome (#67): ids, titles, journey order, routing targets ──────────────────────
def test_welcome_cards_match_the_gui_page(wiz):
    page = advance_to(wiz, wizard_mod.WelcomePage)
    assert [(cid, label) for cid, label, _ in page.choices] == \
        [(cid, label) for cid, label, _ in journey.WELCOME_CHOICES]
    # the full card blurbs too — the TUI renders the same descriptions
    assert [desc for _, _, desc in page.choices] == \
        [desc for _, _, desc in journey.WELCOME_CHOICES]


def test_welcome_targets_match_the_gui_address_book():
    assert journey.WELCOME_TARGET == gui_welcome._CHOICE_TARGET


def test_welcome_default_is_build_on_both_faces(wiz):
    page = advance_to(wiz, wizard_mod.WelcomePage)
    assert page._selected_choice() == "build"
    j = journey.Journey(GENERATOR_DIR)
    j.feed("")                            # a plain Enter
    assert j.slug == "mode"               # the historical welcome -> mode flow


# ── mode (#67 + the #65/#69 cards): ids, journey order, default by id ───────────────
def test_mode_menu_matches_the_gui_page_id_for_id(wiz):
    page = advance_to(wiz, wizard_mod.ModePage)
    assert [(mid, label) for mid, label, _ in page.modes] == \
        [(mid, label) for mid, label, _ in journey.MODE_CHOICES]
    assert [desc for _, _, desc in page.modes] == \
        [desc for _, _, desc in journey.MODE_CHOICES]


def test_mode_default_is_standalone_by_id_on_both_faces(wiz):
    page = advance_to(wiz, wizard_mod.ModePage)
    assert page._selected_mode() == "standalone" == journey.MODE_DEFAULT_CHOICE


# ── the e2e card: the same card, the same door, on both faces ──────────────────────
def test_the_qemu_card_is_gone_from_both_menus_together(wiz):
    """The 2026-08-27 removal, pinned as a PAIR.

    A GUI-only edit is the failure this file exists to catch, and it is the exact
    shape of this change: the card lists are two literals in two modules. Asserting
    the id is absent from BOTH is what makes a half-done removal red rather than a
    parity drift discovered three weeks later.
    """
    page = advance_to(wiz, wizard_mod.ModePage)
    assert "qemu" not in [mid for mid, _, _ in page.modes]
    assert "qemu" not in [mid for mid, _, _ in journey.MODE_CHOICES]
    assert "e2e" in [mid for mid, _, _ in page.modes]
    assert "e2e" in [mid for mid, _, _ in journey.MODE_CHOICES]


def test_e2e_flow_is_hosted_on_both_faces(wiz):
    """The card is not a promise the TUI breaks: the GUI's "e2e" slug is a real
    E2EPage and the TUI's is a real E2EScreen, not an honest stub that would send
    the operator back to the GUI."""
    page = wiz.page(wiz._page_ids["e2e"])
    assert isinstance(page, wizard_mod.E2EPage)
    j = journey.Journey(GENERATOR_DIR)
    screen = j.screen_for("e2e")
    assert isinstance(screen, tui_e2e.E2EScreen)
    assert not isinstance(screen, journey.PendingSideFlow)


def test_the_e2e_chooser_is_the_catalogue_on_both_faces(wiz):
    """Neither face may restate the environment ids: the GUI combo is built from
    describe() and the TUI screen renders environment_ids(). A restated list is how
    a label and the mesh a run actually drives come to disagree."""
    page = wiz.page(wiz._page_ids["e2e"])
    ids = list(env_mod.environment_ids())
    assert [page.env_combo.itemData(i)
            for i in range(page.env_combo.count())] == ids
    j = journey.Journey(GENERATOR_DIR)
    j.feed("")                                        # welcome -> mode
    j.feed(str([m for m, _, _ in journey.MODE_CHOICES].index("e2e") + 1))
    text = "\n".join(j.lines())
    for env_id in ids:
        assert env_id in text


# ── qemu device tests: the card went, the LANE did not, on both faces ──────────────
def test_qemu_flow_survives_the_card_removal_on_both_faces(wiz):
    """Removing a MENU CARD must not delete a lane.

    The QEMU device-test page is the Studio's only door to two harnesses the mesh-
    emulation page does not offer — the Playwright-on-an-emulated-device suite
    (tests/qemu/run-qemu-e2e.sh) and the SELinux AVC workout
    (tests/qemu/avc-workout.sh) — so both faces keep hosting it, reached from the e2e
    card: the GUI's second radio arm and the TUI's `d` key.
    """
    page = wiz.page(wiz._page_ids["qemu"])
    assert isinstance(page, wizard_mod.QemuPage)
    j = journey.Journey(GENERATOR_DIR)
    screen = j.screen_for("qemu")
    assert isinstance(screen, tui_qemu.QemuScreen)
    assert not isinstance(screen, journey.PendingSideFlow)

    # …and BOTH doors arm the same transient flag, from the e2e surface.
    e2e_page = wiz.page(wiz._page_ids["e2e"])
    e2e_page.arm_qemu.setChecked(True)
    assert wiz.qemu_selected is True
    e2e_page.arm_suite.setChecked(True)
    assert wiz.qemu_selected is False

    j.feed("")                                        # welcome -> mode
    j.feed(str([m for m, _, _ in journey.MODE_CHOICES].index("e2e") + 1))
    j.feed(tui_e2e.DEVICE_LANE_KEY)
    assert j.slug == "qemu"
    assert j.flags["qemu_selected"] is True


def test_qemu_session_completeness_words_come_from_the_session_itself():
    """Both pickers describe an aborted build with the SESSION's own badge — the
    GUI combo renders ``BuildSession.summary()`` (which embeds it), the TUI
    renders the badge directly. Neither face spells "partial" for itself."""
    row = qt.DeviceRow(platform="x86", arch="amd64", role="backend", env="test",
                       image="/s/hugmesh-x86-amd64-be-test-20260819T125930Z.img")
    aborted = qt.BuildSession(path="/s", name="s", rows=[row], expected_images=4)
    whole = qt.BuildSession(path="/s", name="s", rows=[row], expected_images=1)
    assert tui_qemu.session_badge(aborted) == aborted.completeness_badge()
    assert tui_qemu.session_badge(aborted) in aborted.summary()
    assert tui_qemu.session_badge(whole) == tui_qemu.COMPLETE_BADGE
    assert whole.completeness_badge() == ""      # complete: no badge to embed


def test_qemu_verdict_vocabulary_is_the_single_graders():
    """The three verdicts no runner ever prints are synthesized in exactly one
    place (core.emulation) and only LOOKED UP by either face — so a row cannot be
    graded PASS on one surface and SUSPECT on the other."""
    assert set(tui_qemu.VERDICT_LEGEND) == {
        em.VERDICT_SUSPECT, em.VERDICT_STALE, em.VERDICT_NO_RESULT}


# ── localcloud (#65): the derived allow-set and the identity reader ─────────────────
def test_localcloud_allowed_roles_match_the_gui_derivation():
    assert tui_lc.ALLOWED_ROLES == gui_lc.LOCALCLOUD_ALLOWED_ROLES


def test_localcloud_identity_readers_agree(tmp_path):
    # both read the same on-disk override points (bootstrap config, secrets bundle,
    # seeder roster); an empty generator dir must yield the same brand-default
    # answer from either face.
    assert tui_lc.local_mesh_identity(str(tmp_path)) == \
        gui_lc.local_mesh_identity(str(tmp_path))


def test_localcloud_casdoor_grant_tables_agree():
    """Issue #228: both import faces carry EVERY mapped Casdoor grant into User.roles
    from ONE table each — the tables must be the same table, and a multi-grant persona
    must import identically (admin + games, not the top of a ladder)."""
    assert tui_lc._CASDOOR_ROLE_MAP == gui_lc._CASDOOR_ROLE_MAP
    granted = ("ROLE_USER", "ROLE_GAMES", "ROLE_ADMIN", "ROLE_MATRIX")
    assert tui_lc._person_roles(granted) == gui_lc._person_roles(granted) \
        == ["admin", "user", "games"]


# ── users (#228): the Roles vocabulary and the multi-role rendering ──────────────────
def test_users_roles_vocabulary_is_the_core_tuple_on_both_faces(wiz):
    """The GUI RoleCell offers exactly core USER_ROLE_CHOICES (one checkbox each) and
    the TUI users screen renders the SAME full set for a multi-role account — a role
    the GUI can tick that the TUI would not show is the half-feature this guards."""
    from hugmesh_studio.core.config import USER_ROLE_CHOICES, User
    from hugmesh_studio.gui.pages import users as gui_users
    c = wiz.cfg
    c.mode = "mesh"
    c.configure_users = True
    c.users = [User(username="ada", domain="acme.example",
                    roles=["games", "admin", "games-services"])]
    wiz.restart()
    page = advance_to(wiz, wizard_mod.UsersPage)
    cell = page.table.cellWidget(0, 2)
    assert isinstance(cell, gui_users.RoleCell)
    assert cell.choices() == list(USER_ROLE_CHOICES) == list(gui_users.USER_ROLE_CHOICES)
    assert cell.roles() == ["admin", "games", "games-services"]
    j = journey.Journey(GENERATOR_DIR)
    j.cfg.users = list(c.users)
    text = "\n".join(j.screen_for("users").lines(j))
    assert "admin, games, games-services" in text
    assert "roles" in text.splitlines()[0]


# ── domains (#71): the Sign-in vocabulary and labels ────────────────────────────────
def test_domain_signin_labels_match_the_gui_combo():
    gui_labels = {value: label for value, label, _tip in gui_domains._IDP_ITEMS}
    assert domains_step.IDP_LABELS == gui_labels


# ── themes (#63): effect labels and the vanta dependency note ───────────────────────
def test_effect_labels_match_the_gui_editor():
    assert themes.EFFECT_LABELS == _theme_editor._EFFECT_LABELS


def test_vanta_dependency_note_matches_the_gui_editor():
    assert themes.VANTA_DEPENDENCY_NOTE == _theme_editor.VANTA_DEPENDENCY_NOTE


# ── the secrets store (#224): one trio, one rule, both faces ────────────────────────
def test_vault_step_edits_the_same_trio_on_both_faces(wiz):
    """The GUI page's widget map and the TUI screen's command vocabulary are BOTH
    pinned to config.VAULT_FIELDS, in order — a field added to one face without the
    other is the half-feature the parity guards exist to catch."""
    page = wiz.page(wiz._page_ids["vault"])
    assert isinstance(page, gui_vault.VaultPage)
    assert tuple(page.field_widgets) == VAULT_FIELDS
    assert tuple(journey.VAULT_COMMANDS.values()) == VAULT_FIELDS
    j = journey.Journey(GENERATOR_DIR)
    screen = j.screen_for("vault")
    assert isinstance(screen, journey.VaultScreen)
    assert not isinstance(screen, journey.PendingStep)


def test_vault_step_refuses_the_same_input_with_the_same_sentence(wiz):
    """Neither face restates the rule: both render config.vault_field_error, so an
    http:// address (or a stray external address) is refused with ONE sentence
    everywhere. The second row used to be a stray KV mount; #285 decision 22 removed
    that field from both faces, and the EXTERNAL address is the residue case now."""
    page = wiz.page(wiz._page_ids["vault"])
    j = journey.Journey(GENERATOR_DIR)
    j.goto("vault")
    ext = "https://vault.outside.example:8200"
    for widget_text, tui_line in (("http://vault.example", "a http://vault.example"),
                                  ("", f"x {ext}")):
        page.addr.setText(widget_text)
        page.external_addr.setText(ext if widget_text == "" else "")
        gui_err = page.error()
        assert gui_err
        j.feed(tui_line)
        assert j.status == f"refused: {gui_err}"


# ── worklist (#234): one step, one name on both faces ───────────────────────────────
def test_worklist_screen_title_matches_the_gui_page(wiz):
    """The TUI's worklist screen and gui/pages/worklist.py are the SAME step — the
    role x platform image picker — so they must name it the same way.

    Nothing compared them before, and the two were never equal: f5da52b4 (the commit
    that added the TUI screen) wrote ``title = "Mesh worklist"`` while the GUI page
    already read "Choose the images to build". Read off the REAL page object rather
    than a literal, so a future GUI retitle fails here instead of drifting silently.

    Deliberately NOT the Review page's "Mesh worklist" collapsible header
    (build.py) — that is a section on a different page and keeps its own name.
    """
    page = next(wiz.page(i) for i in wiz.pageIds()
                if isinstance(wiz.page(i), wizard_mod.WorklistPage))
    assert journey.WorklistScreen.title == page.title() == "Choose the images to build"


# ── #494 (decisions 69 + 71): domains and their services on both faces ──────────────
def _localmesh_choice_page(wiz):
    return next(wiz.page(i) for i in wiz.pageIds()
                if isinstance(wiz.page(i), wizard_mod.LocalMeshChoicePage))


def test_localmesh_choice_cards_match_the_gui_page(wiz):
    page = _localmesh_choice_page(wiz)
    assert [(cid, title) for cid, title, _ in page.choices] == \
        list(tui_lm.LOCALMESH_CHOICES)
    checked = [cid for cid, btn in page._buttons.items() if btn.isChecked()]
    assert checked == [tui_lm.LOCALMESH_DEFAULT_CHOICE]


def test_localmesh_domain_steps_are_hosted_on_both_faces(wiz):
    """The GUI expands the slot into Domains + Domain services steps right after Env
    & brand; the TUI hosts the same two steps (not a stub) over the same state."""
    slugs = [s for s, _c in wizard_mod._LOCALMESH_STEPS]
    assert slugs.index("localmesh_domain_services") == \
        slugs.index("localmesh_domains") + 1
    j = journey.Journey(GENERATOR_DIR)
    screen = j.screen_for("localmesh")
    assert isinstance(screen, tui_lm.LocalMeshScreen)
    assert not isinstance(screen, journey.PendingSideFlow)
    lm = wiz.page(wiz._page_ids["localmesh"])
    for note in (lm.domain_services.lane_note.text(), tui_lm.LANE_NOTE):
        assert "NOT what decides which compose profiles come up" in note


def test_the_own_row_reads_the_same_on_both_faces():
    assert (domains_step.OWN_APPLIES, domains_step.OWN_IDP, domains_step.OWN_CA) == \
        (gui_domains._OWN_APPLIES, gui_domains._OWN_IDP, gui_domains._OWN_CA)


@pytest.mark.parametrize("cfg", [
    ImageConfig(mode="mesh"),                                       # default path
    ImageConfig(mode="mesh", cluster_domain=""),
    ImageConfig(mode="mesh", cluster_domain="", additional_domains=True,
                domains=[Domain(name="a.example")]),
    ImageConfig(mode="mesh", additional_domains=True,
                domains=[Domain(name="a.example")]),
    ImageConfig(mode="cloud", role="desktop", domains=[Domain(name="a.example")]),
    ImageConfig(mode="cloud", role="desktop"),
], ids=["mesh-default", "mesh-no-apex", "mesh-rows-no-apex", "mesh-rows",
        "cloud-row", "cloud-empty"])
def test_both_faces_walk_the_services_step_on_the_same_flows(wiz, cfg):
    """The GUI page's applies_to and the TUI walk decide from the SAME predicate
    (core services_page_applies), and both walk the same domains, own domain first."""
    page = wiz.page(wiz._page_ids["domain_services"])
    j = journey.Journey(GENERATOR_DIR, cfg=cfg)
    j.slug = "domains"
    j.advance()
    assert (j.slug == "domain_services") == page.applies_to(cfg)
    if page.applies_to(cfg):
        from hugmesh_studio.core.domain_services import domain_names_for_services
        assert [d.name for d in j.screen().domains(j)] == \
            domain_names_for_services(cfg)


# ── #587 / #588: the fleet, Go-Live and cloud-CA surfaces (decision 71 = A) ────────────
def test_the_fleet_steps_are_the_same_objects_on_both_faces(qapp, monkeypatch):
    """The GUI fleet window's Domains / Domain services steps and the TUI's fleet
    screen: same lane sentence, no Sign-in column on either, same refusal."""
    from hugmesh_studio.core import build_driver
    from hugmesh_studio.core.fleet import FLEET_LANE_NOTE, fleet_gate_reason
    from hugmesh_studio.gui.pages import fleet as gui_fleet
    from hugmesh_studio.tui.fleet import FleetScreen
    monkeypatch.setattr(build_driver, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    page = gui_fleet.FleetPage(GENERATOR_DIR)
    assert page.domain_services.lane_note.text() == FLEET_LANE_NOTE
    assert FleetScreen().services.lane_note == FLEET_LANE_NOTE
    assert page.domains_table.table.isColumnHidden(gui_domains._COL_IDP)
    j = journey.Journey(GENERATOR_DIR)
    j.goto("fleet")
    j.feed("set cluster_domain mesh.example")
    j.feed("")
    j.feed("a acme.example")
    headers, _rows = j.screen().table(j)
    assert "sign-in" not in headers
    # the same rows on both faces refuse with the same sentence
    page.cluster_domain.setText("mesh.example")
    page._goto(gui_fleet.STEP_DOMAINS)
    page.domains_table._add("acme.example", "")
    assert page._commit_domains()
    page._goto(gui_fleet.STEP_DOMAIN_SERVICES)    # GUI: lands on the own domain
    page._leave(gui_fleet.STEP_DOMAIN_SERVICES)   # ...and records it walked
    j.feed("")                                    # TUI: domains -> services (own)
    j.feed("")                                    # services -> review
    assert fleet_gate_reason(page.collect()) == j.screen().refusal(j) != ""
    page.deleteLater()


def test_the_fleet_tor_note_is_one_string_on_both_faces(qapp, monkeypatch):
    """What WITH_TOR does per builder is said ONCE (core.fleet.WITH_TOR_NOTE): the
    wrapped note under the GUI's Tor checkbox (and its tooltip) and the line the TUI's
    options stage prints for the ``with_tor`` knob. The sentence left the checkbox
    itself in the post-merge review of #645 — a QCheckBox never wraps, and it had made
    every fleet step 825 px wide — so this is where a GUI-only or TUI-only rewording
    would show."""
    from hugmesh_studio.core import build_driver
    from hugmesh_studio.core.fleet import WITH_TOR_NOTE
    from hugmesh_studio.gui.pages import fleet as gui_fleet
    monkeypatch.setattr(build_driver, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    page = gui_fleet.FleetPage(GENERATOR_DIR)
    assert page.with_tor_note.text() == WITH_TOR_NOTE == page.with_tor.toolTip()
    assert page.with_tor_note.wordWrap()
    j = journey.Journey(GENERATOR_DIR)
    j.goto("fleet")
    assert "with_tor: " + WITH_TOR_NOTE in j.lines()
    assert "x86 --with-tor" in WITH_TOR_NOTE and "--optional-services" in WITH_TOR_NOTE
    page.deleteLater()


def test_go_live_offers_and_plans_the_same_domains_on_both_faces(qapp, tmp_path,
                                                                  monkeypatch):
    from hugmesh_studio.core.golive_domains import exposure_lines, plan_rows
    from hugmesh_studio.gui.pages import golive as gui_golive
    from hugmesh_studio.tui.golive import GoLiveScreen
    (tmp_path / "cd").write_text("mesh.example\n")
    (tmp_path / "doms").write_text("shop.example\nmesh.example\n")
    monkeypatch.setenv("GOLIVE_CLUSTER_DOMAIN_FILE", str(tmp_path / "cd"))
    monkeypatch.setenv("GOLIVE_DOMAINS_FILE", str(tmp_path / "doms"))
    monkeypatch.setenv("GL_ONION_EXPORT_DIR", str(tmp_path / "no-tor"))
    w = gui_golive.GoLiveWizard(GENERATOR_DIR)
    w.opts.provider, w.model = "byo-domain", w.driver.provider("byo-domain").model
    inputs = w.page(w._page_ids["inputs"])
    inputs.initializePage()
    gui_list = [inputs.domain_pick.itemData(i) for i in range(inputs.domain_pick.count())]
    j = journey.Journey(GENERATOR_DIR)
    j.goto("golive")
    screen = j.screen()
    assert isinstance(screen, GoLiveScreen)
    assert screen.domains(j) == gui_list == ["mesh.example", "shop.example"]
    inputs.domain_pick.setCurrentIndex(1)
    assert inputs.validatePage()
    gen = w.page(w._page_ids["generate"])
    gen.initializePage()
    screen.opts.provider, screen.opts.domain = "byo-domain", "shop.example"
    assert gen.exposure.toPlainText().splitlines() == screen.plan_lines(j) == \
        exposure_lines(plan_rows(w.driver, w.opts))
    w.deleteLater()


def test_the_cloud_ca_inheritance_note_is_one_string_on_both_faces(wiz):
    from hugmesh_studio.core.config import CLIENT_CA_INHERITANCE_NOTE
    from _helpers import pick_mode
    pick_mode(wiz, "cloud")
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    j = journey.Journey(GENERATOR_DIR)
    j.cfg.mode = "cloud"
    j.goto("domains")
    assert dom.client_ca_note.text() == CLIENT_CA_INHERITANCE_NOTE
    assert CLIENT_CA_INHERITANCE_NOTE in j.screen().lines(j)


# ── #383: a loaded worklist survives a pass through either face ─────────────────────
def _fully_populated_worklist(base):
    """One node row and one desktop row with EVERY optional per-entry field set — the
    shape a saved JSON worklist has when an operator has edited it on the GUI."""
    from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry
    return WorklistConfig(base=base, entries=[
        WorklistEntry(role="backend", platform="x86", board="", flavor="",
                      desktop="", encrypt_root="on",
                      packages_add="app-misc/foo", packages_drop="app-misc/bar",
                      infra_services=("tor",), hostname="be-one"),
        WorklistEntry(role="rpi5-desktop", platform="rpi5", board="rpi5",
                      desktop="xfce", encrypt_root="off",
                      packages_add="media-gfx/baz", packages_drop="app-misc/qux",
                      desktop_user="alice", desktop_user_roles=["admin", "games"],
                      hostname="alice-pi"),
    ])


def test_tui_worklist_feed_keeps_every_per_entry_field_of_a_loaded_worklist():
    """WorklistScreen.feed rebuilt each kept entry as WorklistEntry(role, platform,
    hostname) only, so board / flavor / desktop / encrypt_root / package deltas /
    infra_services / the desktop person silently vanished on a re-entry through the TUI
    (the loss is silent: the envelope just shrinks). Re-entering with the same rows
    checked must be the identity on every entry."""
    j = journey.Journey(GENERATOR_DIR)
    j.worklist = _fully_populated_worklist(j.cfg)
    before = [e.to_dict() for e in j.worklist.entries]
    assert all(before[0][k] == v for k, v in (("encrypt_root", "on"), ("hostname", "be-one")))
    screen = journey.WorklistScreen()
    screen.enter(j)
    assert len(screen._checked) == 2            # both loaded rows are pre-checked
    screen.feed(j, "")
    after = [e.to_dict() for e in j.worklist.entries]
    assert after == before
    # a NEW row starts from defaults, and an unchecked row is dropped, not carried
    j2 = journey.Journey(GENERATOR_DIR)
    j2.worklist = _fully_populated_worklist(j2.cfg)
    s2 = journey.WorklistScreen()
    s2.enter(j2)
    gone = next(i for i, (r, p, _l) in enumerate(s2._rows) if (r, p) == ("backend", "x86"))
    s2.feed(j2, str(gone + 1))                  # a NUMBER toggles: uncheck backend.x86
    s2.feed(j2, "")
    assert [e.id for e in j2.worklist.entries] == ["rpi5-desktop.rpi5"]
    assert j2.worklist.entries[0].to_dict() == before[1]


def test_tui_and_gui_worklist_passes_agree_on_a_loaded_worklist(wiz):
    """The same loaded worklist, re-confirmed unchanged on each face, comes out equal
    (the GUI path is the reference: its validatePage keeps prior state)."""
    from _helpers import pick_mode
    pick_mode(wiz, "mesh")
    page = advance_to(wiz, wizard_mod.WorklistPage)
    wiz.worklist = _fully_populated_worklist(wiz.cfg)
    before = [e.to_dict() for e in wiz.worklist.entries]
    page.initializePage()
    assert page.validatePage()
    gui = [e.to_dict() for e in wiz.worklist.entries]

    j = journey.Journey(GENERATOR_DIR)
    j.worklist = _fully_populated_worklist(j.cfg)
    screen = journey.WorklistScreen()
    screen.enter(j)
    screen.feed(j, "")
    tui = [e.to_dict() for e in j.worklist.entries]
    assert tui == gui == before


# ── #638 / decision 71 = A: the build-first mode picker on both faces ──────────────
def test_the_build_first_arm_offers_the_same_three_builds_on_both_faces(wiz):
    from hugmesh_studio.core import emulation as _emu
    from hugmesh_studio.gui.pages import mode as gui_mode
    page = wiz.page(wiz._page_ids["qemu"])
    gui = [(rb.property("mode"), rb.text()) for rb in page.build_mode_radios.values()]
    assert tuple(gui) == tui_qemu.image_mode_choices()
    assert dict(tui_qemu.image_mode_choices()) == gui_mode.IMAGE_MODE_TITLES
    # the sentence under the picker is ONE core string on both faces
    page._seed_build_mode()                 # what entering the page does
    page.build_first.setChecked(True)
    page.build_mode_radios["cloud"].setChecked(True)
    assert page.build_mode_note.text() == _emu.build_first_mode_note(
        gui_mode.IMAGE_MODE_TITLES["cloud"], gui_mode.IMAGE_MODE_TITLES[wiz.cfg.mode])
    j = journey.Journey(GENERATOR_DIR)
    j.feed("")
    j.feed("4")
    j.feed(tui_e2e.DEVICE_LANE_KEY)
    j.feed(tui_qemu.BUILD_FIRST_KEY)
    assert _emu.build_first_mode_note(
        gui_mode.IMAGE_MODE_TITLES[j.cfg.mode],
        gui_mode.IMAGE_MODE_TITLES[j.cfg.mode]) in "\n".join(j.lines())


# ── #661 / decision 71 = A: the consent line says the same thing on both faces ───────
def test_the_consent_prompt_opens_with_the_tick_boxs_words(wiz):
    """The GUI split its consent sentence (a short tick-box, the rest in a wrapped
    label beside it) so the page fits its window; the TUI asks the same question in
    one line. The words on the box are the opening of that question, and the box and
    its label together are still the whole old sentence."""
    box = wiz.page(wiz._page_ids["localcloud"]).confirm
    assert box.text() == gui_lc.CONSENT_SHORT
    prompt = tui_lc.LocalCloudScreen().prompt(journey.Journey(GENERATOR_DIR))
    assert prompt.startswith(gui_lc.CONSENT_SHORT)
    assert f"{gui_lc.CONSENT_SHORT} {gui_lc.CONSENT_REST}" == (
        "I understand: k8s will stop to proceed — the local Kubernetes (DevOps) stack "
        "must come down before these node images are configured and built.")


# ── #654 / decisions D8 and D9 / decision 71 = A: the superbrand and the brand screens ─
# The window's drop-down, design step and four tabs, and the text screens' lists and
# sections, are ONE model (tui/superbrand_step.BrandSession, tui/brand_step); these pin
# the two faces id for id so a control that exists on one face cannot be missing on the
# other, and a word cannot be spelt twice.
def _brand_gen(tmp_path):
    (tmp_path / "brands").mkdir(exist_ok=True)
    (tmp_path / "brands" / "example.conf").write_text("BRAND=example\n")
    return str(tmp_path)


def _mesh_image_wiz(tmp_path, **cfg_kw):
    from types import SimpleNamespace
    cfg = ImageConfig()
    cfg.mode = "mesh"
    cfg.domains = [Domain(name="shop.example", title="Shop")]
    for k, v in cfg_kw.items():
        setattr(cfg, k, v)
    return SimpleNamespace(cfg=cfg, generator_dir=_brand_gen(tmp_path))


def test_the_superbrand_drop_down_lists_the_same_items_in_the_same_order_on_both_faces(
        qapp, tmp_path):
    from hugmesh_studio.gui.pages.brand_picker import BrandPicker
    from hugmesh_studio.tui import superbrand_step as sbs
    w = _mesh_image_wiz(tmp_path)
    session = sbs.session_for(w, "image", w.cfg, w.generator_dir)
    picker = BrandPicker(session)
    j = journey.Journey(w.generator_dir)
    j.cfg.mode = "mesh"
    j.goto("branding")
    j.feed("s")
    shown = [ln.strip().lstrip("*").strip() for ln in j.lines() if ln.strip()[:2].lstrip("*")[:1].isdigit()
             and ". " in ln]
    shown = [ln.split(". ", 1)[1] for ln in shown]
    assert shown[:len(picker.item_labels())] == picker.item_labels()
    assert picker.item_labels()[0] == sbs.CREATE_LABEL == "Create a new superbrand"
    assert [picker.combo.itemData(i) for i in range(picker.combo.count())] == [
        c.key for c in session.choices()]
    # the same default on both: nothing chosen yet means Create
    assert picker.current_key() == sbs.CREATE_KEY and "*1. Create" in "\n".join(j.lines())


def test_the_design_step_offers_the_same_identity_fields_as_the_text_commands(qapp, tmp_path):
    from hugmesh_studio.gui.pages.superbrand import SuperbrandStep
    from hugmesh_studio.tui import superbrand_step as sbs
    w = _mesh_image_wiz(tmp_path)
    step = SuperbrandStep(sbs.session_for(w, "image", w.cfg, w.generator_dir),
                          look_in_step=False)
    assert tuple(step.fields) == sbs.IDENTITY_FIELDS
    j = journey.Journey(w.generator_dir)
    j.cfg.mode = "mesh"
    j.goto("branding")
    text = "\n".join(_feed_all(j, "s"))
    for field, label in sbs.IDENTITY_LABELS.items():
        assert label in text, f"the text screen has no {label!r} row"
    # a GUI box's label is the text screen's label, word for word
    for field, label in sbs.IDENTITY_LABELS.items():
        row = step.fields[field].parentWidget()
        assert any(lab.text() == label for lab in row.findChildren(QtWidgets.QLabel))
    # the Look is the look editor on one face and the look screen on the other; the
    # one-to-one pin of their controls is tests/test_look_text.py
    from hugmesh_studio.core import brand_model
    assert "look" in text and tuple(brand_model.LOOK_KEYS)


def _feed_all(j, *lines):
    for ln in lines:
        j.feed(ln)
    return j.lines()


def test_the_four_tabs_and_the_four_text_sections_are_the_same_four_in_the_same_order(
        qapp, tmp_path):
    from hugmesh_studio.gui.pages.brand_screen import TAB_TITLES
    from hugmesh_studio.gui.pages import domain_services as gui_ds
    from hugmesh_studio.tui import brand_step
    assert TAB_TITLES == tuple(t for _n, t in brand_step.SECTIONS) == (
        "Identity", "Look", "Services", "Ways to reach it")
    w = _mesh_image_wiz(tmp_path)
    page = gui_ds.DomainServicesPage(w)
    page.initializePage()
    assert [page.brand_tabs.tabText(i) for i in range(4)] == list(TAB_TITLES)
    # both faces open on Services, the step every older flow walked
    assert page.brand_tabs.currentIndex() == brand_step.SECTION_SERVICES - 1
    j = journey.Journey(w.generator_dir)
    j.cfg.mode = "mesh"
    j.cfg.domains = list(w.cfg.domains)
    j.goto("domain_services")
    top = "\n".join(j.lines())
    assert "*3. Services" in top
    for n, title in brand_step.SECTIONS:
        assert f"{n}. {title}" in top.replace("*", "")


def test_every_setting_has_one_editing_home_and_both_faces_say_where(qapp, tmp_path):
    """The Identity mirror and the Ways summary say where each is changed in the SAME
    words on both faces (the sentences are brand_step's, not spelt twice)."""
    from hugmesh_studio.gui.pages import domain_services as gui_ds
    from hugmesh_studio.tui import brand_step
    w = _mesh_image_wiz(tmp_path)
    page = gui_ds.DomainServicesPage(w)
    page.initializePage()
    page._step(1)                                   # shop.example
    tabs = page.brand_tabs
    j = journey.Journey(w.generator_dir)
    j.cfg.mode = "mesh"
    j.cfg.domains = list(w.cfg.domains)
    j.goto("domain_services")
    j.feed("n")
    j.feed("open 1")
    identity = "\n".join(j.lines())
    assert tabs.identity_home.text() == brand_step.IDENTITY_HOME
    assert brand_step.IDENTITY_HOME in identity
    j.feed("open 4")
    ways = "\n".join(j.lines())
    assert brand_step.WAYS_HOME in ways and tabs.ways_note.text() == brand_step.WAYS_HOME
    assert tabs.ways_btn.text() == brand_step.WAYS_BUTTON
    # the same nine effect sentences, from one table
    import html
    for _way, _value, _path, effect in brand_step.brand_view(
            page._brand_session(), "shop.example").ways():
        assert effect in ways and html.escape(effect) in tabs.ways_text.text()


def test_the_brands_summary_is_one_sentence_on_both_faces(qapp, tmp_path):
    from hugmesh_studio.gui.pages import domains as gui_dom
    from hugmesh_studio.tui import domains_step as tui_dom
    w = _mesh_image_wiz(tmp_path)
    w.cfg.domains = [Domain(name="shop.example", title="Shop", tor=True,
                            look={"primary": "#aa0000"})]
    from types import SimpleNamespace
    w2 = SimpleNamespace(cfg=w.cfg, generator_dir=w.generator_dir,
                         currentIdChanged=SimpleNamespace(connect=lambda *_: None),
                         currentPage=lambda: None)
    table = gui_dom.DomainsPage(w2)
    table.initializePage()
    gui = dict(table.brand_summaries())
    j = journey.Journey(w.generator_dir)
    j.cfg = w.cfg
    j.goto("domains")
    text = "\n".join(tui_dom.DomainsScreen().lines(j))
    for name, line in gui.items():
        assert line in text, f"the text table lacks the window's summary of {name}"


def test_the_fleet_window_and_its_text_twin_offer_the_same_superbrand_step(qapp, monkeypatch):
    from hugmesh_studio.core import build_driver
    from hugmesh_studio.gui.pages import fleet as gui_fleet
    from hugmesh_studio.tui import superbrand_step as sbs
    from hugmesh_studio.tui.fleet import FleetScreen
    monkeypatch.setattr(build_driver, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    page = gui_fleet.FleetPage(GENERATOR_DIR)
    j = journey.Journey(GENERATOR_DIR)
    j.goto("fleet")
    j.feed("brand")
    text = "\n".join(j.lines())
    page._goto(gui_fleet.STEP_SHARED)
    labels = page.brand_picker.item_labels()
    assert labels[0] == sbs.CREATE_LABEL and f"*1. {sbs.CREATE_LABEL}" in text
    for label in labels:
        assert label in text
    assert tuple(page.superbrand_step.fields) == sbs.IDENTITY_FIELDS
    # the window has a step for it and the text screen reaches it by one command
    assert gui_fleet._STEP_TITLES[gui_fleet.STEP_BRAND] == "Superbrand"
    assert isinstance(j.screen(), FleetScreen) and j.screen().stage == "brand"
    page.deleteLater()


def test_the_unaffiliated_reason_is_one_sentence_on_both_faces(qapp, tmp_path):
    from hugmesh_studio.gui.pages.brand_picker import BrandPicker
    from hugmesh_studio.gui.pages.superbrand import SuperbrandStep
    from hugmesh_studio.tui import superbrand_step as sbs
    w = _mesh_image_wiz(tmp_path, unaffiliated=True)
    session = sbs.session_for(w, "image", w.cfg, w.generator_dir)
    picker = BrandPicker(session)
    step = SuperbrandStep(session, look_in_step=False)
    j = journey.Journey(w.generator_dir)
    j.cfg = w.cfg
    j.goto("branding")
    text = "\n".join(_feed_all(j, "s"))
    assert picker.note.text() == step.reason.text() == sbs.UNAFFILIATED_REASON
    assert sbs.UNAFFILIATED_REASON in text
    assert picker.combo.count() == 0 and sbs.CREATE_LABEL not in text

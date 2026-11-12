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
from hugmesh_studio.gui.pages import _lookeditor                       # noqa: E402
from hugmesh_studio.gui.pages import domains as gui_domains            # noqa: E402
from hugmesh_studio.gui.pages import localcloud_nodes as gui_lc        # noqa: E402
from hugmesh_studio.gui.pages import vault as gui_vault                # noqa: E402
from hugmesh_studio.gui.pages import welcome as gui_welcome            # noqa: E402
from hugmesh_studio.gui.qt import Qt, QtCore, QtWidgets                # noqa: E402
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


def test_the_emulation_backend_choices_are_one_tuple_on_every_face(wiz):
    """QEMU for Windows beside Docker: the GUI page's chooser, the TUI screen's
    BACKEND_KEY and the CLI all choose from ``qemu_windows.BACKENDS`` — the same ids,
    the same labels, in the same order. The CLI side: the WHPX lines the TUI prints
    name the flag ``qemu_windows.add_cli_arguments`` defines, and that very module."""
    import argparse
    from hugmesh_studio.core import qemu_windows as qw
    from hugmesh_studio.tui import meshemu as tui_meshemu
    combo = wiz.page(wiz._page_ids["meshemu"]).backend_combo
    gui = tuple((combo.itemData(i), combo.itemText(i)) for i in range(combo.count()))
    tui, backend = [], qw.BACKENDS[0][0]
    for _ in qw.BACKENDS:
        tui.append((backend, tui_meshemu.backend_label(backend)))
        backend = tui_meshemu.next_backend(backend)
    assert gui == tuple(tui) == qw.BACKENDS
    studio, module = tui_meshemu.WHPX_CLI_PREFIXES
    ap = argparse.ArgumentParser()
    qw.add_cli_arguments(ap)
    assert ap.parse_args([studio[1], "status"]).qemu_windows == ["status"]
    assert module[-1] == qw.__name__


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
    # the window's one look editor (the old ThemeEditorDialog was removed as dead code)
    assert themes.EFFECT_LABELS == _lookeditor.EFFECT_LABELS


def test_vanta_dependency_note_matches_the_gui_editor():
    # the LookEditor shows the core sentence on its greyed vanta rows and its note
    assert themes.VANTA_DEPENDENCY_NOTE == _lookeditor.theme.VANTA_DEPENDENCY_NOTE


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
    # since 2026-10-21 the per-domain choice IS what the Docker mesh runs: both faces
    # say so in the model's one sentence, and neither says the old, false one
    from hugmesh_studio.core.local_mesh_domains import DOCKER_SERVICES_NOTE
    for note in (lm.domain_services.lane_note.text(), tui_lm.LANE_NOTE):
        assert note == DOCKER_SERVICES_NOTE
        assert "NOT what decides which compose profiles come up" not in note


def test_the_own_row_reads_the_same_on_both_faces():
    assert (domains_step.OWN_APPLIES, domains_step.OWN_IDP, domains_step.OWN_CA) == \
        (gui_domains._OWN_APPLIES, gui_domains._OWN_IDP, gui_domains._OWN_CA)


# ── GUI-22 (GUI retest 2026-11-11): the own row is the FIRST row, and is drawn whole ──
#: How every face names the own row. The GUI table numbers its rows from 1 (Qt's
#: vertical header) and the TUI from 1 ("1 (own)", "Row 1 is …"); the help text said
#: "Row 0", which is a row nobody can see.
FIRST_ROW = "The first row is this mesh's OWN domain"


def _localmesh_domains_step(wiz, prod=False):
    """Welcome -> Local Docker mesh -> Generate -> Env & brand -> Domains. ``prod``
    picks the prod environment on the way, where the own row's name is typed here."""
    from hugmesh_studio.gui.pages import localmesh as gui_lm
    wiz.next()
    mode = wiz.currentPage()
    mode._buttons["localmesh"].setChecked(True)
    mode._on_mode_toggled()
    wiz.next()
    wiz.currentPage()._buttons["generate"].setChecked(True)
    wiz.next()
    ctl = wiz.page(wiz._page_ids["localmesh"])
    if prod:
        ctl.env_prod.setChecked(True)
    wiz.next()
    assert isinstance(wiz.currentPage(), gui_lm.LocalMeshDomainsPage), \
        type(wiz.currentPage()).__name__
    return ctl


def _image_domains_page(wiz):
    from _helpers import check_worklist_rows, enable_additional_domains, pick_mode
    pick_mode(wiz, "mesh")
    check_worklist_rows(advance_to(wiz, wizard_mod.WorklistPage), "omnibus.x86")
    enable_additional_domains(wiz)
    return advance_to(wiz, wizard_mod.DomainsPage)


def test_the_own_row_is_the_first_row_in_the_same_words_on_every_face(
        wiz, monkeypatch, tmp_path):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    # the TUI: the own row is numbered 1, and its help says so
    j = journey.Journey(GENERATOR_DIR)
    j.feed("")                                  # welcome -> mode
    j.feed("1")                                 # Local Docker mesh
    j.feed("2")                                 # Generate a new mesh
    assert j.screen().stage == "domains"
    tui = "\n".join(j.lines())
    assert "Row 1 is this mesh's OWN domain" in tui and "1 (own)" in tui
    # the GUI: both hosts of the table open their help with the same sentence, and
    # neither still says "row 0" anywhere in it
    image = _image_domains_page(wiz)
    assert image.is_own_row(0)
    assert image.table.model().headerData(0, Qt.Orientation.Vertical) == 1
    helps = [image.table_help.text()]
    wiz.close()
    wiz2 = wizard_mod.StudioWizard(GENERATOR_DIR)
    wiz2.show()
    try:
        ctl = _localmesh_domains_step(wiz2)
        table = ctl.domains_table
        assert table.is_own_row(0)
        assert table.table.model().headerData(0, Qt.Orientation.Vertical) == 1
        helps.append(ctl.domains_help.text())
        # the refusal to remove it says the same thing
        table.table.selectRow(0)
        table._remove()
        assert table.row_note.text().startswith("The first row is this mesh's own domain")
    finally:
        wiz2.close()
    for text in helps:
        assert text.startswith(FIRST_ROW + ":") or text.startswith(FIRST_ROW + " ("), text
        assert "row 0" not in text.lower(), text


def test_the_prod_route_calls_the_apex_row_the_first_row_in_every_sentence(
        wiz, monkeypatch, tmp_path):
    """Round 2: three more sentences on the generate-a-new-mesh PROD route said "row 0"
    beside a table that numbers the row 1: the note under the Mesh overlay step's
    mirror, the blank-apex note, and the refusal of an apex that is no domain name."""
    from hugmesh_studio.gui.pages import localmesh as gui_lm
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    ctl = _localmesh_domains_step(wiz, prod=True)
    said = [ctl.boot_domain_note.text()]
    wiz.next()                                  # a blank apex is a note, not a refusal
    assert isinstance(wiz.currentPage(), gui_lm.LocalMeshDomainServicesPage)
    said.append(ctl.domains_note.text())
    assert "public apex domain in the first row" in said[-1], said[-1]
    wiz.back()
    ctl.domains_table.table.item(0, gui_domains._COL_NAME).setText("Not A Domain")
    before = wiz.currentId()
    wiz.next()                                  # refused, inline
    assert wiz.currentId() == before
    said.append(ctl.domains_note.text())
    assert said[-1].startswith("the first row: not a domain name: 'Not A Domain'"), said[-1]
    for text in said:
        assert "the first row" in text and "row 0" not in text.lower(), text


def test_a_refused_org_names_its_row_by_the_number_the_table_shows(qapp):
    """The org refusal counted rows from 0, so the own row was "row 0" and the first
    added one "row 1" beside a vertical header that says 1 and 2."""
    host = gui_domains.DomainsTableWidget(cfg=None)
    try:
        host.fill([], "mesh.example")
        host._add("chat.example", "Chat")
        table = host.table
        for row in (0, 1):
            # a trailing hyphen: the cell lets it be typed, the rule refuses it
            table.cellWidget(row, gui_domains._COL_ORG).setText("acme-")
        shown = [table.model().headerData(r, Qt.Orientation.Vertical) for r in (0, 1)]
        assert shown == [1, 2]
        assert [p.split(":")[0] for p in host.org_problems()] == \
            ["row 1 (mesh.example)", "row 2 (chat.example)"]
    finally:
        host.close()
        host.deleteLater()
        QtCore.QCoreApplication.sendPostedEvents(None, QtCore.QEvent.Type.DeferredDelete)
        qapp.processEvents()


#: The window sizes the 2026-11-11 retest walked, and the two routes that host the
#: table, plus one narrower than any of them (where the columns MUST give width back).
#: Where the viewport holds every column whole the own row's labels must be whole:
#: always on the local-mesh route (four columns to the image flow's six), at the two
#: larger sizes on the image flow. Everywhere else a label may be ELIDED — drawn
#: ending in ‘…’ with its whole text in the tooltip — but never CUT.
#: The third field is how many domains are ADDED under the own row. An added row's Base
#: CA picker asks for 300 px on the image flow, so there the own row's labels share the
#: give with it from 1040x780 down; the local-mesh route has no such column.
_WALKED = [((1200, 800), "image", 0, True), ((1040, 780), "image", 0, True),
           ((942, 552), "image", 0, None), ((760, 560), "image", 0, None),
           ((1200, 800), "localmesh", 0, True), ((1040, 780), "localmesh", 0, True),
           ((942, 552), "localmesh", 0, True),
           ((1040, 780), "image", 1, None), ((942, 552), "image", 1, None),
           ((942, 552), "localmesh", 1, True)]


def _click_add_domain(host):
    add, = [b for b in host.findChildren(QtWidgets.QPushButton)
            if b.text() == "Add domain"]
    add.click()


@pytest.mark.parametrize("size,route,added,whole", _WALKED,
                         ids=[f"{r}-{w}x{h}" + "+row" * n for (w, h), r, n, _ in _WALKED])
def test_the_domains_table_draws_the_own_row_whole_and_fits_its_columns(
        qapp, monkeypatch, tmp_path, size, route, added, whole):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    wiz = wizard_mod.StudioWizard(GENERATOR_DIR)
    wiz.show()
    try:
        # walked and drawn at the wizard's own size, THEN resized: the fit must follow
        host = (_image_domains_page(wiz) if route == "image"
                else _localmesh_domains_step(wiz).domains_table)
        for _ in range(added):
            _click_add_domain(host)
        for _ in range(20):
            qapp.processEvents()
        wiz.resize(*size)
        for _ in range(20):
            qapp.processEvents()
        table = host.table
        hh = table.horizontalHeader()
        viewport = table.viewport().width()
        shown = [c for c in range(table.columnCount()) if not hh.isSectionHidden(c)]
        # every column inside the viewport: no horizontal scroll, the org cell whole
        assert table.horizontalScrollBar().maximum() == 0, (route, size)
        org = gui_domains._COL_ORG
        assert hh.sectionViewportPosition(org) + hh.sectionSize(org) <= viewport
        # the org column is not the one that takes the spare room any more: it was
        # stretched over 315-773 px, a third to two thirds of the table
        assert hh.sectionSize(org) < viewport // 3, (hh.sectionSize(org), viewport)
        # ...and it never gives room back either: its line edit keeps its full size
        cell = table.cellWidget(0, org)
        assert cell.isVisible() and cell.width() >= cell.sizeHint().width(), \
            (cell.width(), cell.sizeHint().width())
        # no header elided ("Optional services" was, at 100 px): at least the style's own
        # size hint for the section, which is what Qt needs to draw the text whole
        for c in shown:
            text = str(table.model().headerData(c, Qt.Orientation.Horizontal))
            assert hh.sectionSize(c) >= hh.sectionSizeHint(c), \
                (text, hh.sectionSize(c), hh.sectionSizeHint(c))
        # the own row's read-only labels: whole, or elided with "…" — never cut
        labels = [(c, table.cellWidget(0, c)) for c in shown
                  if c in (gui_domains._COL_APPLIES, gui_domains._COL_IDP,
                           gui_domains._COL_CA)]
        assert labels and host.is_own_row(0)
        for c, lab in labels:
            full = getattr(lab, "full_text", lab.text)()
            room = lab.contentsRect().width()
            if lab.text() == full:
                assert lab.fontMetrics().horizontalAdvance(full) <= room, \
                    f"{full!r} cut at {room}px with no ellipsis"
            else:
                assert not whole, f"{full!r} elided at {room}px on {route} {size}"
                assert lab.text().endswith("…") and full.startswith(lab.text()[:-1])
                assert lab.fontMetrics().horizontalAdvance(lab.text()) <= room
            assert full in lab.toolTip(), (full, lab.toolTip())
        shots = os.environ.get("HUGMESH_SHOTS_DIR") or str(tmp_path)
        os.makedirs(shots, exist_ok=True)
        assert wiz.grab().save(os.path.join(
            shots, f"gui22-{route}-domains-{size[0]}x{size[1]}{'+row' * added}.png"))
    finally:
        wiz.close()
        wiz.deleteLater()


#: The installed styles among the ones the layout suites measure. One that is not
#: installed here is not a case — never a skip.
_FIT_STYLES = [s for s in ("Fusion", "Windows", "Breeze", "Oxygen")
               if s in QtWidgets.QStyleFactory.keys()]


@pytest.mark.parametrize("style_name", _FIT_STYLES)
def test_the_fit_gives_a_cell_widget_its_whole_width_in_every_style(qapp, style_name):
    """The view draws a cell WIDGET inside the style's item-text margins (Breeze: 3 px a
    side), so a column fitted to the widget's size hint alone left Breeze's org cell
    2 px short of it and its Sign-in label elided with room to spare. The style is set
    on the widget tree, never on the application (see test_fleet_window_layout.py)."""
    style = QtWidgets.QStyleFactory.create(style_name)
    host = gui_domains.DomainsTableWidget(cfg=None)
    try:
        host.fill([], "mesh.example")                  # the own row alone
        for w in [host, *host.findChildren(QtWidgets.QWidget)]:
            w.setStyle(style)
        host.resize(1200, 300)
        host.show()
        for _ in range(20):
            qapp.processEvents()
        table = host.table
        assert host.is_own_row(0)
        for c in (gui_domains._COL_IDP, gui_domains._COL_ORG):
            cell = table.cellWidget(0, c)
            assert cell.isVisible() and cell.width() >= cell.sizeHint().width(), \
                (style_name, c, cell.width(), cell.sizeHint().width())
        label = table.cellWidget(0, gui_domains._COL_IDP)
        assert label.text() == label.full_text(), (style_name, label.text())
    finally:
        host.close()
        host.deleteLater()
        QtCore.QCoreApplication.sendPostedEvents(None, QtCore.QEvent.Type.DeferredDelete)
        qapp.processEvents()
    del style                                          # after the table is gone


# ── GUI-22 round 2: a cell that is TYPED in keeps its room, and the fit follows it ───
# Round 1's fit measured the Domain column by its text alone and re-ran only on a resize,
# a row or a cell widget. On the generate-a-new-local-mesh PROD route the own row's name
# is typed on this step (it is the public apex) and starts EMPTY, so the column dropped
# to its header (52 px, where Qt's default section had given it 100) and stayed there
# once the name was committed: "example.com" was drawn "exam…" beside a 613 px Title.
#: Names wider than the typing room (126 and 156 px at the offscreen font), which only a
#: RE-FIT can draw whole. The first is the reviewer's added-row example.
_WIDE_NAMES = ("community.example.org", "shop.community.example.org")


def _settle(qapp, n=20):
    for _ in range(n):
        qapp.processEvents()


def _size_tag(size):
    return "default" if size is None else "minimum" if size == (1, 1) \
        else f"{size[0]}x{size[1]}"


def _item_fit(table, row, column):
    """``(asks, has)`` for the ITEM at (row, column): the width its delegate asks for to
    draw the text on one line, and the width of the rect the style gives that text. The
    view cuts the text short with ‘…’ exactly when it asks for more than it has."""
    index = table.model().index(row, column)
    opt = QtWidgets.QStyleOptionViewItem()
    table.initViewItemOption(opt)
    opt.rect = table.visualRect(index)
    has = table.style().subElementRect(
        QtWidgets.QStyle.SubElement.SE_ItemViewItemText, opt, table).width()
    return table.sizeHintForIndex(index).width(), has


def _type_in_cell(qapp, table, row, column, text):
    """Type ``text`` into an item cell the way a person does: open the cell's editor,
    type, commit. The editor is the one line edit in the viewport that is no org cell."""
    table.setCurrentCell(row, column)
    table.editItem(table.item(row, column))
    _settle(qapp, 5)
    editor, = [w for w in table.viewport().findChildren(QtWidgets.QLineEdit)
               if not isinstance(w, gui_domains._OrgCell) and w.isVisible()]
    editor.setText(text)
    delegate = table.itemDelegate()
    delegate.commitData.emit(editor)
    delegate.closeEditor.emit(
        editor, QtWidgets.QAbstractItemDelegate.EndEditHint.SubmitModelCache)
    _settle(qapp)
    assert table.item(row, column).text() == text


def _assert_fitted(table, where):
    """What every fit leaves behind: no sideways scroll, the org cell whole and inside
    the viewport (#647), no header elided."""
    hh = table.horizontalHeader()
    org = gui_domains._COL_ORG
    assert table.horizontalScrollBar().maximum() == 0, where
    assert hh.sectionViewportPosition(org) + hh.sectionSize(org) \
        <= table.viewport().width(), where
    cell = table.cellWidget(0, org)
    assert cell.width() >= cell.sizeHint().width(), (where, cell.width())
    for c in range(table.columnCount()):
        if not hh.isSectionHidden(c):
            assert hh.sectionSize(c) >= hh.sectionSizeHint(c), (where, c)


#: The wizard's own size, the two retest sizes the review measured at, one narrower.
_TYPED_AT = [None, (1200, 800), (942, 552), (760, 560)]


@pytest.mark.parametrize("size", _TYPED_AT, ids=[_size_tag(s) for s in _TYPED_AT])
def test_the_prod_apex_cell_has_room_to_type_in_and_the_fit_follows_the_name(
        qapp, monkeypatch, tmp_path, size):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    wiz = wizard_mod.StudioWizard(GENERATOR_DIR)
    wiz.show()
    try:
        host = _localmesh_domains_step(wiz, prod=True).domains_table
        _settle(qapp)
        if size:
            wiz.resize(*size)
            _settle(qapp)
        table, name = host.table, gui_domains._COL_NAME
        hh = table.horizontalHeader()
        item = table.item(0, name)
        assert host.is_own_row(0) and item.text() == ""
        assert item.flags() & Qt.ItemFlag.ItemIsEditable
        shots = os.environ.get("HUGMESH_SHOTS_DIR") or str(tmp_path)
        os.makedirs(shots, exist_ok=True)

        def shot(what):
            table.clearSelection()
            _settle(qapp, 3)
            assert wiz.grab().save(os.path.join(
                shots, f"gui22-prod-apex-{what}-{_size_tag(size)}.png"))

        # EMPTY: the cell the apex is typed into keeps at least the width Qt's default
        # section gave it before the fit (100 px; it was fitted down to the header's 52)
        typing_room = hh.defaultSectionSize()
        assert hh.sectionSize(name) >= typing_room, (hh.sectionSize(name), typing_room)
        _assert_fitted(table, ("empty", size))
        shot("empty")
        # TYPED, and committed through the cell's own editor: drawn whole. The review's
        # apex first, then names only a re-fit can make room for.
        for typed in ("example.com",) + _WIDE_NAMES:
            _type_in_cell(qapp, table, 0, name, typed)
            asks, has = _item_fit(table, 0, name)
            assert asks <= has, f"{typed!r} is cut: it asks {asks}px and has {has}px"
            assert hh.sectionSize(name) >= typing_room
            _assert_fitted(table, (typed, size))
            shot(typed)
        wide = hh.sectionSize(name)
        # WRITTEN by the page, not typed (a loaded record lands in this cell that way)
        item.setText("apex." + _WIDE_NAMES[1])
        _settle(qapp)
        asks, has = _item_fit(table, 0, name)
        assert asks <= has, f"a written name is cut: it asks {asks}px and has {has}px"
        _assert_fitted(table, ("written", size))
        # CLEARED: the room goes back to Title, but never below the typing room
        _type_in_cell(qapp, table, 0, name, "")
        assert typing_room <= hh.sectionSize(name) < wide, (hh.sectionSize(name), wide)
        _assert_fitted(table, ("cleared", size))
        # ...and the fit is at rest: nothing it does asks for another one
        fired = []
        table._fit_timer.timeout.connect(lambda: fired.append(1))
        _settle(qapp, 50)
        assert not fired and not table._fit_timer.isActive()
    finally:
        wiz.close()
        wiz.deleteLater()


def _nothing_else_gives(table):
    """Whether every shown column but Domain is as narrow as the fit ever makes it: its
    header (Title: ten characters), GitHub org apart, which gives nothing. Only then
    does the fit take width from the Domain column."""
    hh = table.horizontalHeader()
    title_floor = table.fontMetrics().averageCharWidth() * 10
    for c in range(table.columnCount()):
        if hh.isSectionHidden(c) or c in (gui_domains._COL_NAME, gui_domains._COL_ORG):
            continue
        floor = table.header_need(c)
        if c == gui_domains._COL_TITLE:
            floor = max(floor, title_floor)
        if hh.sectionSize(c) > floor:
            return False
    return True


#: Both routes, at the wizard's own size and at a retest size; and the local-mesh route
#: at the wizard's MINIMUM size, where the columns no longer fit and Title — with no
#: text of its own on that route — was fitted down to its header (33 px for 70).
#: The third field: whether the viewport has room for the widest name in EVERY style.
#: Where it may not (seven columns at the wizard's own size under Breeze or Oxygen; the
#: minimum size), the name may be cut, but only once no other column has anything left
#: to give.
_ADDED_AT = [("image", None, None), ("image", (1200, 800), True),
             ("image", (942, 552), True), ("localmesh", None, True),
             ("localmesh", (942, 552), True), ("localmesh", (1, 1), None)]


@pytest.mark.parametrize("route,size,whole", _ADDED_AT,
                         ids=[f"{r}-{_size_tag(s)}" for r, s, _ in _ADDED_AT])
def test_an_added_rows_typed_cells_have_room_and_its_name_is_drawn_whole(
        qapp, monkeypatch, tmp_path, route, size, whole):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    wiz = wizard_mod.StudioWizard(GENERATOR_DIR)
    wiz.show()
    try:
        host = (_image_domains_page(wiz) if route == "image"
                else _localmesh_domains_step(wiz).domains_table)
        _settle(qapp)
        if size:
            wiz.resize(*size)                 # (1, 1): Qt holds it at its minimum size
            _settle(qapp)
        table = host.table
        hh = table.horizontalHeader()
        name, title = gui_domains._COL_NAME, gui_domains._COL_TITLE
        _click_add_domain(host)
        _settle(qapp)
        row = table.rowCount() - 1
        assert row == 1 and host.is_own_row(0) and not host.is_own_row(row)
        for c in (name, title):
            assert table.item(row, c).text() == ""
            assert table.item(row, c).flags() & Qt.ItemFlag.ItemIsEditable
        # the new row's two typed cells have room before anything is typed in them
        chars = table.fontMetrics().averageCharWidth()
        assert hh.sectionSize(name) >= hh.defaultSectionSize(), hh.sectionSize(name)
        assert hh.sectionSize(title) >= chars * 10, (hh.sectionSize(title), chars)
        _assert_fitted(table, (route, size, "added"))
        # and a name typed into it is drawn whole: the column follows what is typed
        for typed in _WIDE_NAMES:
            _type_in_cell(qapp, table, row, name, typed)
            asks, has = _item_fit(table, row, name)
            assert asks <= has or (not whole and _nothing_else_gives(table)), \
                f"{typed!r} is cut: it asks {asks}px and has {has}px"
            assert hh.sectionSize(title) >= chars * 10
            _assert_fitted(table, (route, size, typed))
        shots = os.environ.get("HUGMESH_SHOTS_DIR") or str(tmp_path)
        os.makedirs(shots, exist_ok=True)
        table.clearSelection()
        _settle(qapp, 3)
        assert wiz.grab().save(os.path.join(
            shots, f"gui22-{route}-added-row-typed-{_size_tag(size)}.png"))
    finally:
        wiz.close()
        wiz.deleteLater()


def test_the_fit_never_takes_from_the_org_column_and_takes_typing_room_last(qapp):
    """The whole give-back order, asked of the fit directly at every viewport width: a
    drawn window never gets narrow enough to reach its last step, which is why a fit
    that also took width from GitHub org (#647) passed every drawn case."""
    host = gui_domains.DomainsTableWidget(cfg=None)
    try:
        host.fill([], "mesh.example")
        host._add()                                    # a row whose cells are typed in
        table = host.table
        for c in range(table.columnCount()):
            table.setColumnHidden(c, False)            # all seven, as on the image flow
        cols = list(range(table.columnCount()))
        name, title, org = (gui_domains._COL_NAME, gui_domains._COL_TITLE,
                            gui_domains._COL_ORG)
        need = {c: table.column_need(c) for c in cols}
        least = {c: table.header_need(c) for c in cols}
        chars = table.fontMetrics().averageCharWidth()
        least[title] = max(least[title], chars * 10)   # a title: never under ten characters
        least[org] = need[org]                         # the org cell: never under its need
        # a typed-in Domain cell asks for its typing room even while it is empty
        assert need[name] >= table.horizontalHeader().defaultSectionSize() > least[name]
        assert need[title] >= least[title]
        floor = sum(least.values())
        for room in range(0, sum(need.values()) + 200):
            w = table.fit_widths(room)
            assert w[org] == need[org], (room, w[org])
            assert all(w[c] >= least[c] for c in cols), (room, w)
            # exactly the viewport (no gap, no scroll) until even the floors do not fit
            assert sum(w.values()) == max(room, floor), (room, w)
            if w[name] < need[name]:
                # the typing room is the LAST width given back: by then every other
                # column is already at its floor
                assert all(w[c] == least[c] for c in cols if c != name), (room, w)
    finally:
        host.close()
        host.deleteLater()
        QtCore.QCoreApplication.sendPostedEvents(None, QtCore.QEvent.Type.DeferredDelete)
        qapp.processEvents()


def test_a_name_nobody_can_type_in_is_still_fitted_to_its_text(qapp):
    """The typing room is for cells that are typed in. The image flow's own row and a
    test mesh's are read-only, so a table that holds only such a row keeps the widths
    round 1 gave it; the room arrives with the first row that can be typed in."""
    host = gui_domains.DomainsTableWidget(cfg=None)     # the own name is not typed here
    try:
        host.fill([], "a.example")
        table, name = host.table, gui_domains._COL_NAME
        room = table.horizontalHeader().defaultSectionSize()
        assert not table.item(0, name).flags() & Qt.ItemFlag.ItemIsEditable
        assert table.typing_room(name) == 0 and table.column_need(name) < room
        host._add()
        assert table.item(1, name).flags() & Qt.ItemFlag.ItemIsEditable
        assert table.typing_room(name) >= room and table.column_need(name) >= room
        # ...and leaves with the last one
        table.removeRow(1)
        assert table.typing_room(name) == 0 and table.column_need(name) < room
    finally:
        host.close()
        host.deleteLater()
        QtCore.QCoreApplication.sendPostedEvents(None, QtCore.QEvent.Type.DeferredDelete)
        qapp.processEvents()


def test_the_typing_room_grows_with_the_font(qapp):
    """Qt's default section is a pixel count; at a large font it is a handful of
    characters. The typing room is also never under fourteen average characters."""
    host = gui_domains.DomainsTableWidget(cfg=None, own_name_editable=lambda: True)
    try:
        font = host.font()
        font.setPointSize(20)
        host.setFont(font)
        host.fill([], "")                              # a prod own row, not typed yet
        host.resize(1200, 300)
        host.show()
        _settle(qapp)
        table = host.table
        hh = table.horizontalHeader()
        chars = table.fontMetrics().averageCharWidth()
        assert chars * 14 > hh.defaultSectionSize(), (chars, hh.defaultSectionSize())
        assert hh.sectionSize(gui_domains._COL_NAME) >= chars * 14
    finally:
        host.close()
        host.deleteLater()
        QtCore.QCoreApplication.sendPostedEvents(None, QtCore.QEvent.Type.DeferredDelete)
        qapp.processEvents()


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


def test_the_nvd_key_block_is_one_set_of_words_on_both_faces(qapp, monkeypatch):
    """The NVD API key the pen-test's SCA step needs (core/nvd_key.py): the GUI fleet
    window's box (shown once a pen-test is ticked) and the TUI fleet options' block
    (shown once ``set pentest on``) carry the same core strings, line for line; and a
    Verify verdict reads the same on both (label + sentence, VERDICT_LABELS)."""
    from hugmesh_studio.core import build_driver, nvd_key
    from hugmesh_studio.gui.pages import fleet as gui_fleet
    monkeypatch.setattr(build_driver, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    page = gui_fleet.FleetPage(GENERATOR_DIR)
    w = page.nvd_key
    gui_words = [w.need_label.text(), w.activation_label.text(), w.empty_label.text(),
                 w.consent_label.text()]
    assert gui_words == [nvd_key.NEED_LINE, nvd_key.ACTIVATION_WARNING,
                         nvd_key.EMPTY_REFUSED, nvd_key.VERIFY_CONSENT]
    assert nvd_key.REQUEST_URL in w.request_link.text()
    j = journey.Journey(GENERATOR_DIR)
    j.goto("fleet")
    j.feed("set pentest on")
    tui = "\n".join(j.lines())
    for words in gui_words + [nvd_key.REQUEST_URL, nvd_key.GUIDE_URL]:
        assert words in tui, words
    # the status line is the same function on both faces
    assert w.status_label.text() == "NVD API key: " + nvd_key.status_line()
    assert "NVD API key: " + nvd_key.status_line() in tui
    # a verdict: the GUI's status label and the TUI's status both print
    # res.checked_line() (the verdict plus the fingerprint of the key it checked)
    res = nvd_key.classify(404, {"message": "Invalid apiKey."})
    assert res.line().startswith(nvd_key.VERDICT_LABELS[nvd_key.NOT_ACCEPTED] + ": ")
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


@pytest.mark.parametrize("path,where", [("docker", "repo"), ("docker", "bare"),
                                        ("image", "repo"), ("fleet", "repo")])
def test_where_a_domains_own_look_shows_is_one_sentence_on_both_faces(
        qapp, tmp_path, path, where):
    """The window's Look tab and the text screen's look section say the same thing
    about where an added domain's own look shows (core/look_serving): served by Host on
    the Docker mesh, recorded only on a checkout whose door does not serve it, not
    applied on the image and Fleet routes."""
    from hugmesh_studio.core import brand_look, look_serving
    from hugmesh_studio.gui.pages._lookeditor import LookEditor
    gen = (os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
           if where == "repo" else str(tmp_path))
    base = brand_look.Look({"primary": "#3355aa"}).effective()
    ed = LookEditor(brand_look.Look({}, base=base), path=path, generator_dir=gen)
    text = "\n".join(themes.LookText(brand_look.Look({}, base=base), path=path,
                                     generator_dir=gen).lines())
    want = look_serving.own_look_sentence(path, gen)
    gui = ed.served_note.text() if path == "docker" else ed.path_note.text()
    assert gui == want
    assert want in text
    ed.deleteLater()


# ── HugMesh tokens (operator ask 2026-11-04): issuing from the window, text, CLI ───────
def test_issuing_a_token_offers_the_same_roles_shell_rule_and_lifetime_on_every_face(
        qapp, monkeypatch, capsys):
    """The window's "Issue a HugMesh token…" dialog, the text screen and the CLI offer
    the core's roles, shell access exactly for its shell roles, and the core's longest
    lifetime — and both faces say the same fingerprint and shell sentences."""
    import time

    from hugmesh_studio.core import mesh_token as mt
    from hugmesh_studio.gui import mesh_token_issue_dialog as dmod
    from hugmesh_studio.tui import mesh_token_step as tstep

    def no_container(runner=None):
        raise mt.TokenError("tool", "No running headscale container was found.")
    monkeypatch.setattr(mt, "find_headscale_container", no_container)
    dlg = dmod.IssueTokenDialog()
    try:
        deadline = time.monotonic() + 30
        while dmod.probe_running(dlg, "_probe") and time.monotonic() < deadline:
            dlg._probe.wait(100)
            qapp.processEvents()
        qapp.processEvents()
        # roles: the dialog's combo, the screen, the CLI's --role choices, the core
        gui_roles = tuple(dlg.role.itemText(i) for i in range(dlg.role.count()))
        with pytest.raises(SystemExit):
            mt.main(["issue", "--help"])
        help_text = capsys.readouterr().out
        cli_roles = tuple(help_text.split("--role {", 1)[1].split("}", 1)[0].split(","))
        assert gui_roles == tstep.MeshTokenScreen.roles() == cli_roles == mt.ROLES
        # shell: the dialog's tick box is enabled exactly where the screen allows it,
        # and both are the core's SHELL_ROLES (the CLI refuses the rest: check_fields)
        for role in mt.ROLES:
            dlg.role.setCurrentText(role)
            assert dlg.shell.isEnabled() is tstep.MeshTokenScreen.shell_allowed(role) \
                is (role in mt.SHELL_ROLES)
        assert tuple(mt.SHELL_ROLES) == ("admin", "superadmin")
        # the longest lifetime: every unit of the dialog tops out at the core's maximum
        for unit, size in dmod.UNITS:
            dlg.unit.setCurrentText(unit)
            assert dlg.lifetime.maximum() * size == mt.MAX_LIFETIME_S
        j = journey.Journey(GENERATOR_DIR)
        screen = tstep.MeshTokenScreen()
        j.open_overlay(screen)
        days = mt.MAX_LIFETIME_S // 86400
        j.feed(f"e {days}d")
        assert screen.lifetime_s == mt.MAX_LIFETIME_S and not j.status
        j.feed(f"e {days + 1}d")
        assert screen.lifetime_s == mt.MAX_LIFETIME_S and j.status
        # the sentences both faces show
        assert (tstep.TITLE, tstep.FINGERPRINT_NOTE, tstep.SHELL_ONLY_TIP) == \
            (dmod.TITLE, dmod.FINGERPRINT_NOTE, dmod.SHELL_ONLY_TIP)
    finally:
        dlg.close()
        dlg.deleteLater()


def test_go_live_names_targets_and_their_limits_identically_on_both_faces(
        qapp, tmp_path, monkeypatch):
    """The emulated-target words are spelled ONCE: the picker rows (GUI Preflight) and
    the `t` list (TUI), the per-mechanism reachability, the EPHEMERAL sentence, and the
    Mesh emulation action on the front door."""
    import _golive_fake_guest as fake
    from hugmesh_studio.core import golive_target
    from hugmesh_studio.gui.pages import golive as gui_golive
    from hugmesh_studio.gui.pages import mesh_emulation as gui_meshemu
    from hugmesh_studio.tui import golive as tui_golive
    from hugmesh_studio.tui import meshemu as tui_meshemu
    guest = fake.install(tmp_path, monkeypatch)
    fake.register(guest, label="rpi5/pki")
    fake.register(guest, label="x86/laptop", platform="x86", role="laptop", port=22402)
    monkeypatch.setattr(gui_golive.qemu_devices, "default_work_dir",
                        lambda _gen: guest.work_dir)
    w = gui_golive.GoLiveWizard(GENERATOR_DIR, target="rpi5/pki")
    pre = w.page(w._page_ids["preflight"])
    pre.initializePage()
    gui_rows = [pre.target_pick.itemText(i) for i in range(pre.target_pick.count())]
    j = journey.Journey(GENERATOR_DIR)
    j.goto("golive")
    screen = j.screen()
    screen.work_dir = guest.work_dir
    tui_rows = [tui_golive.target_title(t) for t in screen.target_rows(j)]
    assert gui_rows == tui_rows
    assert gui_rows[0] == tui_golive.THIS_HOST == gui_golive.THIS_HOST
    # the reachability line under each exposure card is the TUI's provider sub-line
    exp = w.page(w._page_ids["exposure"])
    exp.initializePage()
    assert screen.set_target(j, w.target) == ""
    tui_text = "\n".join(screen.lines(j))
    for model, lb in exp.reach.items():
        if lb.text():
            assert lb.text().split(": ", 1)[1] in tui_text, model
    assert golive_target.EPHEMERAL_NOTE in gui_golive.ephemeral_text(w.target)
    assert gui_meshemu.GO_LIVE_ACTION == tui_meshemu.GO_LIVE_ACTION
    w.deleteLater()

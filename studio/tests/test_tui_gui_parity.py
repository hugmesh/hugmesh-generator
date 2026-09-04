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
from hugmesh_studio.core.config import WIZARD_PAGE_SLUGS               # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                 # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                    # noqa: E402
from hugmesh_studio.gui.pages import _theme_editor                     # noqa: E402
from hugmesh_studio.gui.pages import domains as gui_domains            # noqa: E402
from hugmesh_studio.gui.pages import localcloud_nodes as gui_lc        # noqa: E402
from hugmesh_studio.gui.pages import welcome as gui_welcome            # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                            # noqa: E402
from hugmesh_studio.tui import domains_step, journey, themes           # noqa: E402
from hugmesh_studio.tui import e2e as tui_e2e                          # noqa: E402
from hugmesh_studio.tui import localcloud as tui_lc                    # noqa: E402
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
    # both read the same on-disk seams (bootstrap config, secrets bundle,
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

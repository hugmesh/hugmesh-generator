"""Issue #50 items 1+1a — the guided welcome flow, headless.

Proves the REQUIREMENT set offscreen:
(a) a FRESH start lands on the Welcome screen: the hugmesh explainer (with the
    GitHub README getting-started link as a real, externally-opened anchor) plus
    TWO large icon buttons in the ChoiceCard idiom;
(b) each button navigates to the right page id — START BUILDING -> "mode",
    REVIEW PRIOR SESSIONS -> "sessions" — and the local-mesh journey is entered
    from the MODE menu, which raises the transient wizard flag;
(c) a CLICK on a card is choosing-is-proceeding (ask 14 / choice_nav), while a bare
    setChecked never navigates on its own;
(d) the demoted sessions screen carries the Previous-builds manager + Load/Save,
    and Back from it returns to Welcome;
(e) ModePage.modes is reordered to the operator's mesh-building journey
    (local mesh -> prod mesh build -> QEMU emulation -> publish/flash -> desktops)
    with the no-pick default still standalone BY ID.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import WIZARD_PAGE_SLUGS               # noqa: E402
from hugmesh_studio.gui import choice_cards as cc                      # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                    # noqa: E402
from hugmesh_studio.gui.pages import welcome as welcome_mod            # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                            # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    # the sessions page's initializePage scans the build-session store — keep the
    # suite out of the operator's real one
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.restart()
    yield w
    w.close()
    w.deleteLater()


def _welcome(wiz):
    return wiz.page(wiz._page_ids["welcome"])


def _mode(wiz):
    """The ModePage — since DECISION 2(d) the ONLY door onto the local-mesh flow."""
    return wiz.page(wiz._page_ids["mode"])


def _pick_localmesh(mode_page):
    """Tick ModePage's "Local Docker mesh" card the way test_local_mesh.py does.

    By PROPERTY, not by index: ModePage.modes is deliberately reordered (item (e)
    of this file's own contract), so an index would rot the moment the journey
    order changes again."""
    for b in mode_page.group.buttons():
        if b.property("mode") == "localmesh":
            b.setChecked(True)
            return b
    raise AssertionError("ModePage no longer offers a 'localmesh' card")


# ── (a) the first screen: explainer + two cards ───────────────────────────────────────

def test_fresh_start_lands_on_welcome(wiz):
    assert isinstance(wiz.currentPage(), wizard_mod.WelcomePage)
    # "welcome" is the FIRST slug and nothing else sets a start id
    assert WIZARD_PAGE_SLUGS[0] == "welcome"
    assert wiz.currentId() == wiz._page_ids["welcome"]


def test_welcome_renders_two_icon_cards(wiz):
    # DECISION 2(d) (operator, 2026-08-26: "asking same questions seemingly multiple
    # times"): the welcome "Start a local mesh" card and ModePage's "Local Docker
    # mesh" card were two doors onto ONE flow. The mode menu keeps it; welcome
    # dropped it. Was three cards, is two.
    page = _welcome(wiz)
    cards = page.group.buttons()
    assert len(cards) == 2 == len(page.choices)
    assert [c.property("choice") for c in cards] == ["build", "sessions"]
    for i, card in enumerate(cards):
        assert isinstance(card, cc.ChoiceCard)
        assert page.group.button(i) is card        # id == option index (ModePage idiom)
    # default is START BUILDING, so a plain Next keeps the historical welcome -> mode
    assert page._buttons["build"].isChecked()
    assert page.isComplete()
    # THE NEGATIVE, kept as a negative: the duplicate door is gone from every surface
    # this page exposes — no card, no button registry entry, and (welcome.py:51-54)
    # no routing target, because a target for a card nobody can pick would leave an
    # unreachable branch in nextId().
    assert "localmesh" not in page._buttons
    assert "localmesh" not in welcome_mod._CHOICE_TARGET
    assert "localmesh" not in welcome_mod._CHOICE_ICONS
    assert all(c.property("choice") != "localmesh" for c in cards)


def test_welcome_explainer_links_to_the_readme_getting_started(wiz):
    page = _welcome(wiz)
    # the anchor must hand off to the desktop browser — Qt only does that with
    # openExternalLinks; without it the click is silently swallowed
    assert page.explainer.openExternalLinks()
    html = page._explainer_html()
    assert welcome_mod.README_GETTING_STARTED in html
    assert "github.com/hugmesh/hugmesh-generator" in html
    assert "HugMesh" in html                       # an explainer, not just a link


# ── (b) each card navigates to the right page id ──────────────────────────────────────

def test_build_choice_advances_to_the_mode_menu(wiz):
    _welcome(wiz)._buttons["build"].setChecked(True)
    wiz.next()
    assert wiz.currentId() == wiz._page_ids["mode"]
    assert isinstance(wiz.currentPage(), wizard_mod.ModePage)


def test_the_local_mesh_door_is_the_mode_menu_not_welcome(wiz):
    # RE-POINTED by DECISION 2(d). The property this test has always pinned — that
    # the local-mesh journey is REACHABLE and raises the transient flag — is intact;
    # only the door moved. Welcome -> "Start building" -> mode -> "Local Docker mesh"
    # is now the single route, one screen longer and one duplicate shorter.
    _welcome(wiz)._buttons["build"].setChecked(True)
    wiz.next()
    assert wiz.currentId() == wiz._page_ids["mode"]
    _pick_localmesh(_mode(wiz))
    wiz.next()
    # issue #334: the branch now OPENS on its two-card choice screen (join an existing
    # mesh with a key / generate a new one) instead of the old tabbed page. Same door,
    # same transient flag; the first screen behind it is the choice, not the form.
    assert wiz.currentId() == wiz._page_ids["localmesh_choice"]
    assert isinstance(wiz.currentPage(), wizard_mod.LocalMeshChoicePage)
    # the SAME transient flag the welcome card used to raise (LocalMeshPage.applies_to
    # reads it) — and never persisted into cfg (cfg.mode stays an image mode)
    assert wiz.localmesh_selected is True
    assert wiz.cfg.mode in ("standalone", "cloud", "mesh")


def test_sessions_choice_advances_to_the_sessions_screen(wiz):
    _welcome(wiz)._buttons["sessions"].setChecked(True)
    wiz.next()
    assert wiz.currentId() == wiz._page_ids["sessions"]
    assert isinstance(wiz.currentPage(), wizard_mod.SessionsPage)


def test_mode_choice_after_a_localmesh_detour_clears_the_flag(wiz):
    # mode -> localmesh, Back, mode -> standalone: the transient flag must not
    # strand True (the wizard's skip-walk would otherwise stop on LocalMeshPage).
    # DECISION 2(d) moved the DETOUR's start from welcome to mode; the stranding
    # hazard it guards is unchanged, and is now wholly ModePage's to clear.
    _welcome(wiz)._buttons["build"].setChecked(True)
    wiz.next()
    mp = _mode(wiz)
    _pick_localmesh(mp)
    wiz.next()
    assert wiz.currentId() == wiz._page_ids["localmesh_choice"]
    wiz.back()
    assert wiz.currentId() == wiz._page_ids["mode"]
    mp._buttons["standalone"].setChecked(True)
    wiz.next()
    assert wiz.localmesh_selected is False
    # not the choice screen and not ANY of the branch's steps (issue #334 turned one
    # stranded page into nine, so the stranding hazard is checked across all of them)
    for slug in [s for s in wiz._page_ids
                 if s == "localmesh" or s.startswith("localmesh_")]:
        assert wiz.currentId() != wiz._page_ids[slug], slug


def test_welcome_still_lowers_a_stranded_localmesh_flag(wiz):
    # The card is gone but WelcomePage.validatePage STILL clears the flag, written
    # as a constant False rather than a comparison against an id nothing can select
    # (welcome.py:206). That is what makes a Back-navigation from ModePage's card all
    # the way to the first screen safe: without it, a stranded True would send the
    # very next Next into LocalMeshPage. Set it by hand — no card can raise it here.
    page = _welcome(wiz)
    wiz.localmesh_selected = True
    assert page.validatePage() is True
    assert wiz.localmesh_selected is False


# ── (c) choosing is proceeding (ask 14), setChecked never navigates ───────────────────

def test_clicking_a_card_navigates(qapp, wiz):
    _welcome(wiz)._buttons["sessions"].click()
    qapp.processEvents()
    assert wiz.currentId() == wiz._page_ids["sessions"]


def test_setchecked_alone_never_navigates(qapp, wiz):
    # a loaded config / Back-navigation restore selects programmatically — that
    # must never walk the wizard forward on its own (choice_nav's contract)
    _welcome(wiz)._buttons["sessions"].setChecked(True)
    qapp.processEvents()
    assert wiz.currentId() == wiz._page_ids["welcome"]


# ── (d) the demoted sessions screen ───────────────────────────────────────────────────

def test_sessions_screen_carries_the_builds_manager_and_load_save(wiz):
    page = wiz.page(wiz._page_ids["sessions"])
    assert hasattr(page, "previous_builds")        # gui.shell/pages.fleet scan for it
    texts = [b.text() for b in page.findChildren(QtWidgets.QPushButton)]
    assert "Load config…" in texts and "Save config…" in texts


def test_back_from_sessions_returns_to_welcome(wiz):
    _welcome(wiz)._buttons["sessions"].setChecked(True)
    wiz.next()
    wiz.back()
    assert isinstance(wiz.currentPage(), wizard_mod.WelcomePage)


def test_plain_next_from_sessions_continues_into_the_menu(wiz):
    # reviewing what you built continues naturally into building (positional next)
    _welcome(wiz)._buttons["sessions"].setChecked(True)
    wiz.next()
    wiz.next()
    assert wiz.currentId() == wiz._page_ids["mode"]


# ── (e) ModePage journey order ────────────────────────────────────────────────────────

def test_mode_page_order_matches_the_operators_journey(wiz):
    # the #67 journey order, grown in place by the cards #65 (localcloud) and
    # #69 (meshemu) added — this pin lagged both merges (it failed on main).
    page = wiz.page(wiz._page_ids["mode"])
    assert [m for m, _, _ in page.modes] == [
        "localmesh",     # local mesh first…
        "localcloud",    # …turning that local mesh into node images (#65)
        "mesh",          # …then the production mesh (node images)
        "e2e",           # …then the e2e test lane (2026-08-27: it took the
                         #    "QEMU device tests" card's slot, and is that page's
                         #    only remaining door)
        "meshemu",       # …then whole-mesh emulation (#69)
        "deploy", "phone", "quest",   # publish / flash+enroll side-flows
        "cloud", "standalone",        # the single-image desktop builds
    ]
    # the no-pick default stays standalone BY ID, not by index — the reorder must
    # not change which choice the default flow exercises
    assert page._buttons["standalone"].isChecked()

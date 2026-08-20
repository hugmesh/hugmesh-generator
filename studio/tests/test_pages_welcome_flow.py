"""Issue #50 items 1+1a — the guided welcome flow, headless.

Proves the REQUIREMENT set offscreen:
(a) a FRESH start lands on the Welcome screen: the hugmesh explainer (with the
    GitHub README getting-started link as a real, externally-opened anchor) plus
    THREE large icon buttons in the ChoiceCard idiom;
(b) each button navigates to the right page id — START BUILDING -> "mode",
    START A LOCAL MESH -> "localmesh" (raising the same transient wizard flag
    ModePage's card raises), REVIEW PRIOR SESSIONS -> "sessions";
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


# ── (a) the first screen: explainer + three cards ─────────────────────────────────────

def test_fresh_start_lands_on_welcome(wiz):
    assert isinstance(wiz.currentPage(), wizard_mod.WelcomePage)
    # "welcome" is the FIRST slug and nothing else sets a start id
    assert WIZARD_PAGE_SLUGS[0] == "welcome"
    assert wiz.currentId() == wiz._page_ids["welcome"]


def test_welcome_renders_three_icon_cards(wiz):
    page = _welcome(wiz)
    cards = page.group.buttons()
    assert len(cards) == 3 == len(page.choices)
    assert [c.property("choice") for c in cards] == ["build", "localmesh", "sessions"]
    for i, card in enumerate(cards):
        assert isinstance(card, cc.ChoiceCard)
        assert page.group.button(i) is card        # id == option index (ModePage idiom)
    # default is START BUILDING, so a plain Next keeps the historical welcome -> mode
    assert page._buttons["build"].isChecked()
    assert page.isComplete()


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


def test_localmesh_choice_advances_to_the_local_stack_flow(wiz):
    _welcome(wiz)._buttons["localmesh"].setChecked(True)
    wiz.next()
    assert wiz.currentId() == wiz._page_ids["localmesh"]
    assert isinstance(wiz.currentPage(), wizard_mod.LocalMeshPage)
    # the SAME transient flag ModePage's card raises (LocalMeshPage.applies_to
    # reads it) — and never persisted into cfg (cfg.mode stays an image mode)
    assert wiz.localmesh_selected is True
    assert wiz.cfg.mode in ("standalone", "cloud", "mesh")


def test_sessions_choice_advances_to_the_sessions_screen(wiz):
    _welcome(wiz)._buttons["sessions"].setChecked(True)
    wiz.next()
    assert wiz.currentId() == wiz._page_ids["sessions"]
    assert isinstance(wiz.currentPage(), wizard_mod.SessionsPage)


def test_mode_choice_after_a_localmesh_detour_clears_the_flag(wiz):
    # welcome -> localmesh, Back, welcome -> mode: the transient flag must not
    # strand True (the wizard's skip-walk would otherwise stop on LocalMeshPage)
    page = _welcome(wiz)
    page._buttons["localmesh"].setChecked(True)
    wiz.next()
    wiz.back()
    page._buttons["build"].setChecked(True)
    wiz.next()
    assert wiz.currentId() == wiz._page_ids["mode"]
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
    page = wiz.page(wiz._page_ids["mode"])
    assert [m for m, _, _ in page.modes] == [
        "localmesh",     # local mesh first…
        "mesh",          # …then the production mesh (node images)
        "qemu",          # …then QEMU emulation of the built images
        "deploy", "phone", "quest",   # publish / flash+enroll side-flows
        "cloud", "standalone",        # the single-image desktop builds
    ]
    # the no-pick default stays standalone BY ID, not by index — the reorder must
    # not change which choice the default flow exercises
    assert page._buttons["standalone"].isChecked()

"""The local-mesh TWO-CARD entry and its wizard STEPS (issue #334, part 1+2 of #333).

What replaced what: the page was a QTabWidget — "Join an existing mesh with a key" and
one 600-line bootstrap tab — and is now ``LocalMeshChoicePage`` (two cards) routing
either to a terminal join step or through seven bring-up steps, in the order the
surface has always had its sections.

These tests pin the parts that can silently rot:

* the CARD ROUTING itself, in both directions, including the choice's default;
* that the split forked NO implementation — every widget still lives on the one
  ``LocalMeshPage`` and a step merely re-parents a section, so nothing can drift;
* that a section which is never claimed (join on the generate branch, the prod-only
  overlay on a test mesh) is not left rendered on the bring-up step;
* that the whole branch stays skipped on every image mode, which is the contract
  standing in for a MODE_SKIPPED_PAGES entry (localmesh is not an image mode, so it
  has never had one).
"""
import os

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import MODE_SKIPPED_PAGES        # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo           # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod              # noqa: E402
from hugmesh_studio.gui.pages import localmesh as localmesh_mod  # noqa: E402
from hugmesh_studio.gui.pages import localmesh_choice as choice_mod  # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                      # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")

#: the bring-up steps, in flow order — the section order the surface has always had.
BOOTSTRAP_STEPS = ["LocalMeshEnvPage", "LocalMeshSourcePage", "LocalMeshServicesPage",
                   "LocalMeshIdpPage", "LocalMeshOverlayPage", "LocalMeshReviewPage",
                   "LocalMeshPage"]


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    """No wizard construction ever probes this machine (docker info &c.)."""
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()            # offscreen: makes per-widget isVisible() meaningful
    yield w
    w.close()
    w.deleteLater()


def _to_choice(wiz):
    """Welcome -> Start building -> ModePage -> "Local Docker mesh" -> the cards."""
    wiz.next()                                   # welcome's default card
    mode = wiz.currentPage()
    assert type(mode).__name__ == "ModePage", type(mode).__name__
    mode._buttons["localmesh"].setChecked(True)
    mode._on_mode_toggled()
    wiz.next()
    page = wiz.currentPage()
    assert isinstance(page, choice_mod.LocalMeshChoicePage), type(page).__name__
    return page


def _walk(wiz, limit=15):
    """Class names of the pages a plain Next-Next-Next walk visits from here."""
    seen = []
    for _ in range(limit):
        seen.append(type(wiz.currentPage()).__name__)
        before = wiz.currentId()
        wiz.next()
        if wiz.currentId() == before:
            break
    return seen


# ── the entry: two cards, not two tabs ─────────────────────────────────────────────
def test_the_tab_widget_is_gone(wiz):
    page = wiz.page(wiz._page_ids["localmesh"])
    assert not hasattr(page, "tabs")
    assert page.findChild(QtWidgets.QTabWidget) is None


def test_the_entry_is_exactly_two_cards(wiz):
    page = _to_choice(wiz)
    assert [cid for cid, _t, _d in page.choices] == ["join", "generate"]
    assert len(page.group.buttons()) == 2
    for card in page._buttons.values():
        assert isinstance(card, wizard_mod.QtWidgets.QAbstractButton)
    # the two cards ARE the two tabs this replaced, by their own words
    assert "Join an existing mesh with a key" == page._buttons["join"].text()
    assert "Generate a new mesh" == page._buttons["generate"].text()


def test_the_default_card_is_join_the_tab_that_used_to_open(wiz):
    page = _to_choice(wiz)
    assert page._selected() == "join"
    assert page.isComplete() is True


def test_join_card_routes_to_the_terminal_join_step(wiz):
    page = _to_choice(wiz)
    page._buttons["join"].setChecked(True)
    wiz.next()
    step = wiz.currentPage()
    assert isinstance(step, localmesh_mod.LocalMeshJoinPage)
    assert step.nextId() == -1 and step.isFinalPage()   # a joined node ends the path
    assert wiz.localmesh_join_selected is True


def test_generate_card_routes_through_the_bring_up_steps_in_section_order(wiz):
    page = _to_choice(wiz)
    page._buttons["generate"].setChecked(True)
    wiz.next()
    assert wiz.localmesh_join_selected is False
    seen = _walk(wiz)
    # test env by default, so the prod-only overlay step is skipped (see below)
    assert seen == [s for s in BOOTSTRAP_STEPS if s != "LocalMeshOverlayPage"], seen
    assert isinstance(wiz.currentPage(), localmesh_mod.LocalMeshPage)
    assert wiz.currentPage().nextId() == -1      # still terminal


def test_prod_adds_the_overlay_step(wiz):
    page = _to_choice(wiz)
    page._buttons["generate"].setChecked(True)
    wiz.next()
    wiz.page(wiz._page_ids["localmesh"]).env_prod.setChecked(True)
    assert _walk(wiz) == BOOTSTRAP_STEPS


def test_the_card_choice_is_re_pickable_both_ways(wiz):
    page = _to_choice(wiz)
    page._buttons["generate"].setChecked(True)
    wiz.next()
    assert isinstance(wiz.currentPage(), localmesh_mod.LocalMeshEnvPage)
    wiz.back()
    assert isinstance(wiz.currentPage(), choice_mod.LocalMeshChoicePage)
    # initializePage reflects the committed answer, not the constructor default
    assert wiz.currentPage()._selected() == "generate"
    wiz.currentPage()._buttons["join"].setChecked(True)
    wiz.next()
    assert isinstance(wiz.currentPage(), localmesh_mod.LocalMeshJoinPage)


# ── one implementation: the steps hold nothing ─────────────────────────────────────
def test_a_step_owns_no_widgets_it_re_parents_the_controllers_section(wiz):
    ctl = wiz.page(wiz._page_ids["localmesh"])
    page = _to_choice(wiz)
    page._buttons["generate"].setChecked(True)
    wiz.next()
    env = wiz.currentPage()
    # the SAME widgets, moved — never copied. env_test/brand/superadmin are still the
    # controller's attributes, which is what keeps collect_bootstrap() and every
    # existing test reading one object.
    assert ctl.sections["env"].parentWidget() is env._lay.parentWidget()
    assert ctl.env_test.isChecked() is True
    assert ctl.superadmin.text() == "superadmin"
    assert env.ctl is ctl


def test_a_section_no_step_claimed_is_not_left_on_the_bring_up_page(wiz):
    """The join form must not be rendered on the bring-up step, and neither must the
    prod-only overlay on a test mesh. Both are sections whose step was never visited."""
    ctl = wiz.page(wiz._page_ids["localmesh"])
    page = _to_choice(wiz)
    page._buttons["generate"].setChecked(True)
    wiz.next()
    _walk(wiz)
    assert isinstance(wiz.currentPage(), localmesh_mod.LocalMeshPage)
    assert ctl.sections["join"].isVisible() is False
    assert ctl.sections["overlay"].isVisible() is False
    assert ctl.sections["bringup"].isVisible() is True
    assert ctl.run_view.isVisible() is True


def test_the_run_view_follows_the_page_a_verb_runs_from(wiz):
    """One staged tree + one log, shared by both paths — the join step and the
    bring-up step are the only pages a verb can run from, and only one of them is
    reachable per flow, so the run view moves rather than being duplicated."""
    ctl = wiz.page(wiz._page_ids["localmesh"])
    page = _to_choice(wiz)
    page._buttons["join"].setChecked(True)
    wiz.next()
    join = wiz.currentPage()
    assert ctl.run_view.parentWidget() is join._lay.parentWidget()
    assert ctl.log is not None and ctl.stage_tree is not None
    # …and back on the generate branch it returns to the bring-up step
    wiz.back()
    wiz.currentPage()._buttons["generate"].setChecked(True)
    wiz.next()
    _walk(wiz)
    assert ctl.run_view.parentWidget() is ctl._body.parentWidget()


def test_a_running_verb_greys_the_join_steps_exit(wiz):
    ctl = wiz.page(wiz._page_ids["localmesh"])
    page = _to_choice(wiz)
    page._buttons["join"].setChecked(True)
    wiz.next()
    join = wiz.currentPage()
    assert join.isComplete() is True
    ctl._running = True
    ctl.completeChanged.emit()
    assert join.isComplete() is False
    ctl._running = False
    ctl.completeChanged.emit()
    assert join.isComplete() is True


# ── the branch stays off every image flow ──────────────────────────────────────────
@pytest.mark.parametrize("mode", ["mesh", "cloud", "standalone"])
def test_every_local_mesh_page_is_skipped_on_an_image_mode(wiz, mode):
    """localmesh is not an image mode, so it appears in NO mode's MODE_SKIPPED_PAGES
    tuple and never has — the whole branch is skipped dynamically instead. Every page
    the split added must obey the same rule, or picking "mesh" would walk an operator
    into the docker-mesh setup."""
    wiz.next()
    mp = wiz.currentPage()
    mp._buttons[mode].setChecked(True)
    mp._on_mode_toggled()
    assert mp.validatePage() is True
    assert wiz.localmesh_selected is False
    slugs = [s for s in wiz._page_ids if s == "localmesh" or s.startswith("localmesh_")]
    assert len(slugs) == 9, slugs
    for slug in slugs:
        assert slug not in MODE_SKIPPED_PAGES[wiz.cfg.mode]     # never was, still is not
        assert wiz.page(wiz._page_ids[slug]).applies_to(wiz.cfg) is False, slug


def test_the_bootstrap_steps_are_off_the_join_branch_and_vice_versa(wiz):
    ctl = wiz.page(wiz._page_ids["localmesh"])
    page = _to_choice(wiz)
    page._buttons["join"].setChecked(True)
    assert page.validatePage() is True
    for slug in ("localmesh_env", "localmesh_source", "localmesh_services",
                 "localmesh_idp", "localmesh_overlay", "localmesh_review"):
        assert wiz.page(wiz._page_ids[slug]).applies_to(wiz.cfg) is False, slug
    assert wiz.page(wiz._page_ids["localmesh_join"]).applies_to(wiz.cfg) is True
    page._buttons["generate"].setChecked(True)
    assert page.validatePage() is True
    assert wiz.page(wiz._page_ids["localmesh_join"]).applies_to(wiz.cfg) is False
    assert wiz.page(wiz._page_ids["localmesh_env"]).applies_to(wiz.cfg) is True
    assert ctl.applies_to(wiz.cfg) is True


def test_the_choice_screen_commits_nothing_to_cfg(wiz):
    """Running a docker mesh is not an image mode: the card raises a wizard-transient
    flag and cfg — every saved config, every builder argv — never learns it exists."""
    before = wiz.cfg.to_dict() if hasattr(wiz.cfg, "to_dict") else dict(vars(wiz.cfg))
    page = _to_choice(wiz)
    page._buttons["generate"].setChecked(True)
    assert page.validatePage() is True
    after = wiz.cfg.to_dict() if hasattr(wiz.cfg, "to_dict") else dict(vars(wiz.cfg))
    assert after == before

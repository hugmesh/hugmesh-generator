"""The local-mesh TWO-CARD entry and its wizard STEPS (issue #334, part 1+2 of #333).

What replaced what: the page was a QTabWidget — "Join an existing mesh with a key" and
one 600-line bootstrap tab — and is now ``LocalMeshChoicePage`` (two cards) routing
either to a terminal join step or through seven bring-up steps, in the order the
surface has always had its sections.

These tests pin the parts that can silently go stale:

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


# ── a step that can START a verb must SHOW that verb (refute round, blocker) ────────
def _to_review(wiz):
    """Walk the generate branch as far as the saved-meshes / review step."""
    page = _to_choice(wiz)
    page._buttons["generate"].setChecked(True)
    wiz.next()
    for _ in range(12):
        if isinstance(wiz.currentPage(), localmesh_mod.LocalMeshReviewPage):
            return wiz.currentPage()
        before = wiz.currentId()
        wiz.next()
        if wiz.currentId() == before:
            break
    raise AssertionError("never reached LocalMeshReviewPage: "
                         + type(wiz.currentPage()).__name__)


def _verb_pages(wiz):
    """Every local-mesh page from which a REAL verb can be started.

    Read off the code, not a hand-kept list: a page hosts a verb if it claims a
    section carrying a control wired to something that calls ``_launch``. Today that
    is the join form (Start/Stop), the saved-mesh table on the review step
    (start_requested -> _start_saved) and the bring-up Actions row.
    """
    return {"localmesh_join", "localmesh_review", "localmesh"}


@pytest.mark.parametrize("slug", sorted(_verb_pages(None)))
def test_every_page_a_verb_can_start_from_hosts_the_run_view(wiz, slug):
    """THE REGRESSION THIS PINS. The split moved the saved-mesh table — whose Start
    and Restore run ``boot.start_saved`` / ``boot.restore`` on a QThread, minutes of
    docker output — onto the review step, and left the run surface behind on the
    controller. The operator pressed Start and got nothing: no status line, no stage
    tree, no log, no Cancel, no failure notice. Everything that verb says lives in
    ``run_view``, so any page it can be launched from must be showing it.
    """
    ctl = wiz.page(wiz._page_ids["localmesh"])
    if slug == "localmesh_join":
        page = _to_choice(wiz)
        page._buttons["join"].setChecked(True)
        wiz.next()
    elif slug == "localmesh_review":
        _to_review(wiz)
    else:
        page = _to_choice(wiz)
        page._buttons["generate"].setChecked(True)
        wiz.next()
        _walk(wiz)
    cur = wiz.currentPage()
    assert type(cur).__name__ != "LocalMeshChoicePage"
    for name in ("status", "stage_tree", "log"):
        assert getattr(ctl, name).isVisible() is True, f"{slug}: {name} not visible"
    host = (ctl._body if cur is ctl else cur._lay).parentWidget()
    assert ctl.run_view.parentWidget() is host, slug


def test_a_refused_saved_mesh_start_says_so_where_the_operator_can_see_it(wiz):
    """``_start_saved``'s refusal paths write into ``ctl.status`` and leave the row
    button ENABLED, so an invisible status line makes a refused click indistinguishable
    from a broken one — this repo's named failure mode."""
    ctl = wiz.page(wiz._page_ids["localmesh"])
    review = _to_review(wiz)
    assert ctl.status.isVisible() is True

    class _Rec:
        config, form, label, id = {}, {}, "demo", "demo"

    ctl._running, ctl._running_label = True, "Generate && start"
    ctl._start_saved(_Rec(), "start")
    assert "Still running" in ctl.status.text()
    assert ctl.status.isVisible() is True         # …and the operator can READ it
    ctl._running, ctl._running_label = False, ""

    ctl._mesh_up = True
    ctl._start_saved(_Rec(), "start")
    assert "stop it first" in ctl.status.text()
    assert ctl.status.isVisible() is True
    ctl._mesh_up = None
    assert isinstance(review, localmesh_mod.LocalMeshReviewPage)


def test_the_run_view_hands_back_to_the_bring_up_step(wiz):
    """The review step claims the run view; Next must not strand it there."""
    ctl = wiz.page(wiz._page_ids["localmesh"])
    review = _to_review(wiz)
    assert ctl.run_view.parentWidget() is review._lay.parentWidget()
    wiz.next()
    assert isinstance(wiz.currentPage(), localmesh_mod.LocalMeshPage)
    assert ctl.run_view.parentWidget() is ctl._body.parentWidget()
    assert ctl.run_view.isVisible() is True
    wiz.back()                                    # …and claims it again on the way in
    assert isinstance(wiz.currentPage(), localmesh_mod.LocalMeshReviewPage)
    assert ctl.run_view.parentWidget() is review._lay.parentWidget()
    assert ctl.status.isVisible() is True


# ── the busy guard, on EVERY step (refute round, major) ────────────────────────────
@pytest.mark.parametrize("slug", ["localmesh_env", "localmesh_source",
                                  "localmesh_services", "localmesh_idp",
                                  "localmesh_review", "localmesh_join"])
def test_a_running_verb_greys_next_on_every_step(wiz, slug):
    """``_LocalMeshStep.initializePage`` connects the controller's completeChanged to
    each step's own, under a comment promising the step's Next greys mid-verb. Without
    an ``isComplete`` override that signal re-evaluated a gate that never said no, and
    the operator could walk forward out of a running docker verb — something the
    single-page flow forbade."""
    step = wiz.page(wiz._page_ids[slug])
    ctl = wiz.page(wiz._page_ids["localmesh"])
    assert step.isComplete() is True
    ctl._running = True
    assert step.isComplete() is False, slug
    ctl._running = False
    assert step.isComplete() is True


def test_the_running_gate_actually_disables_the_wizards_next_button(wiz):
    """isComplete is only half of it — the signal has to reach the wizard."""
    ctl = wiz.page(wiz._page_ids["localmesh"])
    _to_review(wiz)
    nxt = wiz.button(QtWidgets.QWizard.WizardButton.NextButton)
    assert nxt.isEnabled() is True
    ctl._running, ctl._running_label = True, "Generate && start"
    ctl.completeChanged.emit()                    # exactly what _launch does
    assert nxt.isEnabled() is False
    ctl._running, ctl._running_label = False, ""
    ctl.completeChanged.emit()                    # …and what _verb_done does
    assert nxt.isEnabled() is True


# ── native-default invariant across the WHOLE step branch ──────────────────────────
def test_walking_every_new_step_untouched_commits_nothing_to_cfg(wiz):
    """The Studio's named failure mode is a knob that silently does nothing; the
    mirror of it is a screen that silently does something. Seven new steps were added
    to the flow, and an operator who walks all of them without touching a field must
    leave cfg — and therefore ``to_cli_args()`` — byte-identical. (The local-mesh
    branch drives LocalMeshBootstrapConfig, which never reaches builder argv, so the
    correct answer here is ZERO delta, not "a delta we understand".)"""
    before, before_argv = wiz.cfg.to_dict(), list(wiz.cfg.to_cli_args())
    ctl = wiz.page(wiz._page_ids["localmesh"])
    page = _to_choice(wiz)
    page._buttons["generate"].setChecked(True)
    wiz.next()
    ctl.env_prod.setChecked(True)                 # the widest walk: all seven steps
    seen = _walk(wiz)
    ctl.env_test.setChecked(True)                 # leave the default as we found it
    assert seen == BOOTSTRAP_STEPS, seen
    assert wiz.cfg.to_dict() == before
    assert list(wiz.cfg.to_cli_args()) == before_argv


def test_walking_the_join_step_untouched_commits_nothing_to_cfg(wiz):
    before, before_argv = wiz.cfg.to_dict(), list(wiz.cfg.to_cli_args())
    page = _to_choice(wiz)
    page._buttons["join"].setChecked(True)
    wiz.next()
    assert isinstance(wiz.currentPage(), localmesh_mod.LocalMeshJoinPage)
    assert wiz.cfg.to_dict() == before
    assert list(wiz.cfg.to_cli_args()) == before_argv


def test_the_controller_reclaims_the_run_view_on_any_show_not_only_a_forward_one(wiz):
    """The ownership rule is ONE rule: whichever local-mesh page is on screen holds the
    run view, claimed from showEvent so it holds on a Back too.

    The controller is the last step today, so the wizard only ever enters it forward
    and initializePage would be enough — which is exactly why this drives the hook
    directly. Without it the rule would be "showEvent, except the controller, which
    relies on being last", and inserting any step after bring-up would silently strand
    the log on the page behind it.
    """
    ctl = wiz.page(wiz._page_ids["localmesh"])
    review = _to_review(wiz)
    assert ctl.run_view.parentWidget() is review._lay.parentWidget()
    ctl.hide()
    ctl.show()                       # what QWizard does when it switches to a page
    assert ctl.run_view.parentWidget() is ctl._body.parentWidget()
    assert ctl.sections["bringup"].parentWidget() is ctl._body.parentWidget()
    ctl.hide()


def test_a_step_relays_the_controllers_complete_changed_as_its_own(wiz):
    """``initializePage`` connects ctl.completeChanged -> this step's own signal.

    The wizard's Next button does not prove this: QWizard::setPage connects
    completeChanged for EVERY page it holds, so the controller's emission already
    re-polls the current page's isComplete whether or not this relay exists. What the
    relay buys is that the STEP's own signal is truthful — anything that watches a
    QWizardPage the documented way sees the change — so it is pinned here directly
    rather than through a button that would stay green with the wire cut.
    """
    ctl = wiz.page(wiz._page_ids["localmesh"])
    step = _to_review(wiz)
    seen = []
    step.completeChanged.connect(lambda: seen.append(step.isComplete()))
    ctl._running = True
    ctl.completeChanged.emit()
    ctl._running = False
    ctl.completeChanged.emit()
    assert seen == [False, True], seen

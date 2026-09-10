"""What the wizard's LAST button on each page is actually called.

Operator report, 2026-08-21: *"overall and if all the finish button does is exit then
just label it exit."*

The survey behind this file walked every registered page of both Qt wizards and asked,
per page: does pressing the final button do anything beyond closing the window — a
build, an apply, a write, a state commit? The answer split three ways, and all three
arms are pinned here:

* **Pure close -> "Exit".** Eight pages of ``StudioWizard`` (the local mesh's join
  step and its bring-up step, phone, quest, deploy, qemu-on-its-terminal-arm, meshemu,
  progress) and the go-live wizard's flip page. The local mesh contributes two since
  issue #334 split its tabs into a card choice: joining an existing mesh with a key and
  generating a new one are separate branches, and BOTH end in the wizard. Every verb they own is an in-page button that has already run by the time the
  operator reaches for the wizard button, and the work outlives the window on purpose
  — the docker mesh keeps running, the emulated devices keep running, the build has
  already finished — so the button is a plain "leave the Studio" and now says so. Six
  of the seven define no ``validatePage`` at all; the seventh's is a no-op on the arm
  where it is terminal (see
  ``test_no_exit_labelled_page_commits_anything_on_the_way_out``).
* **Does real work -> left as "Finish".** ``gui/pages/idp_provider.ProviderConfigWindow``:
  its Finish is the ``QDialog.Accepted`` that makes ``IdpPage`` write issuer /
  client id / JWKS back into ``cfg``. Cancel there discards them. Renaming that to
  "Exit" would be the same lie in the other direction, so it is a DELIBERATE exception
  and this file pins it as one.
* **Not a Finish button at all.** ``BuildPage`` is a Qt *commit* page, so Qt shows a
  Commit button and no Finish. Its module docstring claimed "the wizard's Finish
  becomes a Build action"; ask 22 moved the dispatch off the page and that sentence
  never followed. The live button was mislabelled too — see
  ``test_review_pages_commit_button_says_continue_not_build``.

EVERY assertion below reads the RENDERED ``QAbstractButton.text()`` off the live
wizard, not the ``setButtonText`` call: the relabel is a per-PAGE override
(``QWizardPage.setButtonText``, which Qt's ``updateButtonTexts()`` prefers over the
wizard-wide one), and a per-page override that never reaches the widget is exactly the
failure mode a call-site assertion cannot see.
"""
import os
import time

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.platform_info import HostInfo          # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod             # noqa: E402
from hugmesh_studio.gui.pages import idp_provider               # noqa: E402
from hugmesh_studio.gui.pages._widgets import EXIT_BUTTON_TEXT  # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                     # noqa: E402

from tests.test_wizard import advance_to, pick_mode             # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

FINISH = QtWidgets.QWizard.WizardButton.FinishButton
COMMIT = QtWidgets.QWizard.WizardButton.CommitButton

# a canned host so wizard construction never probes the machine (docker info &c.)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(autouse=True)
def _e2e_gate_stubbed(monkeypatch):
    """E2EPage's entry starts an off-thread readiness probe that shells docker (three
    30s subprocesses plus an HTTP probe). This file walks that page — it is the RUN
    E2E TESTS card, and since 2026-08-27 also the route to QemuPage — and none of its
    assertions are about the host's daemon, so the probe answers instantly here."""
    from hugmesh_studio.core.local_stack_node import LocalStackNode
    monkeypatch.setattr(LocalStackNode, "e2e_ready",
                        lambda self, environment="docker": ["stubbed probe"])


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    # ProgressPage writes a tray build-status file; keep it out of the real ~/.hugmesh.
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(autouse=True)
def _no_real_emulation_probes(monkeypatch):
    """The two emulation pages read build sessions and docker on entry. Serve both from
    canned values so THESE tests are about the button label, not the host's out/ tree."""
    from hugmesh_studio.core import qemu_tests

    session = qemu_tests.BuildSession(path="/nowhere/s1", name="s1", rows=[
        qemu_tests.DeviceRow(platform="rpi5", arch="arm64", role="pki", env="test",
                             image="/nowhere/s1/hugmesh-rpi5-arm64-pki-test-0.img")])
    monkeypatch.setattr(qemu_tests, "discover_sessions", lambda *_a, **_k: [session])
    monkeypatch.setattr(qemu_tests, "docker_available",
                        lambda: (True, "docker is available."))


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


def _finish_button(wiz):
    b = wiz.button(FINISH)
    assert b is not None, "the wizard has no Finish button widget at all"
    return b


# ---- the pure-close terminal pages: Exit, and it reaches the widget ---------------

#: (ModePage choice, page class) for every side-flow that ENDS in the wizard. Each is
#: terminal (``nextId() == -1``), and pressing the final button runs nothing — pinned
#: by ``test_no_exit_labelled_page_commits_anything_on_the_way_out``.
TERMINAL_SIDE_FLOWS = [
    # the local mesh's DEFAULT card is "join an existing mesh with a key" (issue #334),
    # so a plain Next-Next walk from the mode menu ends on the join step. The other
    # branch's terminal page gets its own walk below, the way QemuPage does.
    ("localmesh", "LocalMeshJoinPage"),
    ("phone", "PhonePage"),
    ("quest", "QuestPage"),
    ("deploy", "DeployPage"),
    ("e2e", "E2EPage"),
    ("meshemu", "MeshEmulationPage"),
]

#: QemuPage is terminal and Exit-labelled too, but it is no longer reached from a
#: mode-menu card — its own card was removed on 2026-08-27 and E2EPage's second radio
#: arm is the door. It gets its own walk below rather than a row here.


@pytest.mark.parametrize("mode,page_name", TERMINAL_SIDE_FLOWS,
                         ids=[m for m, _ in TERMINAL_SIDE_FLOWS])
def test_terminal_side_flow_pages_render_exit_not_finish(wiz, mode, page_name):
    """Walk the real flow to each terminal page and read the button off the window.

    This is the assertion the operator's report asks for: on a page where the only
    thing the button does is close the Studio, the WIDGET must say Exit."""
    page_cls = getattr(wizard_mod, page_name)
    pick_mode(wiz, mode)
    page = advance_to(wiz, page_cls)

    assert page.nextId() == -1, f"{page_name} stopped being terminal"

    btn = _finish_button(wiz)
    assert btn.isVisible(), f"{page_name} is final but renders no Finish button"
    assert btn.text() == EXIT_BUTTON_TEXT == "Exit", (
        f"{page_name} still renders {btn.text()!r}")


def test_the_local_mesh_bring_up_step_renders_exit_behind_the_generate_card(wiz):
    """The OTHER local-mesh branch's terminal page.

    ``TERMINAL_SIDE_FLOWS`` walks with no clicks, which takes the choice screen's
    default (join). Generating a new mesh is the second card, and its last step —
    bring-up and monitor — is terminal for exactly the same reason: the mesh keeps
    running in Docker after the window closes, so the button only leaves the Studio."""
    pick_mode(wiz, "localmesh")
    choice = advance_to(wiz, wizard_mod.LocalMeshChoicePage)
    choice._buttons["generate"].setChecked(True)
    page = advance_to(wiz, wizard_mod.LocalMeshPage)

    assert page.nextId() == -1, "LocalMeshPage stopped being terminal"
    btn = _finish_button(wiz)
    assert btn.isVisible(), "LocalMeshPage is final but renders no Finish button"
    assert btn.text() == EXIT_BUTTON_TEXT == "Exit"


def test_the_qemu_page_still_renders_exit_behind_the_e2e_card(wiz):
    """The removed card's page, walked to through its NEW door.

    ``TERMINAL_SIDE_FLOWS`` drives ``pick_mode``, and "qemu" is no longer a mode id —
    but the page is still terminal on its default arm and still Exit-labelled, so the
    guard has to keep reaching it. This is that walk."""
    pick_mode(wiz, "e2e")
    e2e_page = advance_to(wiz, wizard_mod.E2EPage)
    e2e_page.arm_qemu.setChecked(True)
    page = advance_to(wiz, wizard_mod.QemuPage)

    assert page.nextId() == -1, "QemuPage stopped being terminal"
    btn = _finish_button(wiz)
    assert btn.isVisible(), "QemuPage is final but renders no Finish button"
    assert btn.text() == EXIT_BUTTON_TEXT == "Exit"


def test_progress_page_renders_exit_once_the_build_has_settled(wiz):
    """The build screen's button, on the wizard, with no build dispatched.

    Reached by ``setStartId`` + ``restart()`` rather than by walking the flow on
    purpose: arriving at this page normally DISPATCHES the committed worklist
    (``ProgressPage.initializePage``). With ``worklist = None`` initializePage builds
    no rows and starts nothing (the same no-op path
    tests/test_pages_progress.py::test_no_worklist_completes_immediately pins), which
    is all this assertion needs."""
    wiz.worklist = None
    pid = wiz._page_ids["progress"]
    wiz.setStartId(pid)
    try:
        wiz.restart()
    finally:
        wiz.setStartId(-1)

    page = wiz.currentPage()
    assert isinstance(page, wizard_mod.ProgressPage)
    assert page._rows == []                     # nothing was dispatched
    btn = _finish_button(wiz)
    assert btn.isVisible() and btn.isEnabled()
    assert btn.text() == "Exit"


def test_every_terminal_page_is_labelled_exit_and_no_other_page_is(wiz):
    """The drift guard: terminal-ness and the Exit label must stay the same set.

    A page added later that ends a branch gets the same treatment automatically-ish —
    this fails loudly if it does not, and equally if a NON-terminal page picks up an
    Exit label it will never render. ``QWizardPage.buttonText`` falls back to the
    wizard's text, so an untouched page reads Qt's default "&Finish"."""
    labelled, terminal = set(), set()
    for page in wiz._pages:
        name = type(page).__name__
        if page.nextId() == -1:
            terminal.add(name)
        if page.buttonText(FINISH) == EXIT_BUTTON_TEXT:
            labelled.add(name)

    assert terminal == {"LocalMeshPage", "LocalMeshJoinPage",
                        "PhonePage", "QuestPage", "DeployPage",
                        "E2EPage", "QemuPage", "MeshEmulationPage", "ProgressPage"}
    assert labelled == terminal


def test_no_exit_labelled_page_commits_anything_on_the_way_out(wiz):
    """The CONDITION behind the rename, asserted rather than assumed.

    Qt calls ``validatePage()`` when Finish is pressed, so a terminal page that
    overrides it has a way to do real work on the way out — and "Exit" would then be
    wrong. Exactly one of the seven does, for a reason that does not apply on the arm
    where it is terminal:

    ``QemuPage.validatePage`` seeds ``cfg.qemu_device_tests`` for the "build first, then test"
    arm — the arm that REJOINS the image flow and therefore shows Next, not Finish. On
    the terminal arm the radio is on "use existing images", so the seed writes
    ``qemu_device_tests = False``, which is already the field's default (config.py: ``qemu_device_tests:
    bool = False``), into a config the closing wizard discards. Nothing is emitted,
    nothing is saved.

    Everything else must stay override-free: this fails the moment a page picks up an
    exit-time commit that its "Exit" label no longer describes."""
    def overrides_validate_page(page) -> bool:
        # walk the MRO down to Qt's own class: `type(page).validatePage is not
        # QWizardPage.validatePage` looks equivalent and is NOT — PyQt6's sip builds a
        # fresh wrapper per attribute access, so that identity test reports EVERY page
        # as an overrider and the guard passes vacuously in the direction that matters.
        for klass in type(page).__mro__:
            if klass is QtWidgets.QWizardPage:
                return False
            if "validatePage" in vars(klass):
                return True
        return False

    overriders = {type(p).__name__ for p in wiz._pages
                  if p.nextId() == -1 and overrides_validate_page(p)}
    assert overriders == {"QemuPage"}

    qemu = wiz.page(wiz._page_ids["qemu"])
    assert qemu.use_existing.isChecked()          # the terminal arm is the default
    wiz.cfg.qemu_device_tests = True                       # a value the seed must be free to clear
    assert qemu.validatePage() is True
    assert wiz.cfg.qemu_device_tests is False              # the field's own default: a no-op write


# ---- the deliberate exception: a Finish that really commits ----------------------

def test_provider_config_window_keeps_finish_because_its_finish_does_work(qapp):
    """NOT renamed, on purpose.

    ``ProviderConfigWindow`` is the other QWizard in the Studio, and its Finish is the
    accept that makes ``IdpPage`` (idp.py: ``win.exec() == Accepted`` -> ``result_values()``)
    write the issuer / client id / JWKS into ``cfg``; Cancel discards them. That button
    performs a state commit, so it keeps saying Finish — the rename is for buttons that
    do nothing, and applying it here would be the same mislabel pointing the other way."""
    win = idp_provider.ProviderConfigWindow("keycloak")
    try:
        review = win.review_page
        assert review.nextId() == -1                    # it IS the final page
        assert review.buttonText(FINISH) != EXIT_BUTTON_TEXT
        # and it is really the commit seam: the caller only reads these on Accepted
        assert hasattr(win, "result_values")
    finally:
        win.close()
        win.deleteLater()


# ---- BuildPage: a commit button that promised a build it does not run -------------

def test_review_page_shows_no_finish_button_at_all(wiz):
    """BuildPage is a Qt COMMIT page, so Qt swaps Next for Commit and hides Finish.

    Pinned because the module docstring said the opposite for a while ("the wizard's
    Finish becomes a Build action"), which is what sent this survey looking for a
    Finish button here in the first place."""
    pick_mode(wiz, "standalone")
    page = advance_to(wiz, wizard_mod.BuildPage)
    assert page.isCommitPage()
    assert page.nextId() != -1                      # LaunchPage follows it
    assert not _finish_button(wiz).isVisible()
    page._join_preflight_worker()


def test_review_pages_commit_button_says_continue_not_build(qapp, wiz):
    """The Review page starts nothing, so its button must not promise a build.

    Ask 22 moved the dispatch to the separate LaunchPage and renamed this button in
    ``__init__`` accordingly — but ``_set_busy`` still restored the pre-ask-22 "Build"
    when the docker preflight settled, and a preflight runs on every visit, so "Build"
    is what the operator actually saw. Reading the RENDERED text is the whole point:
    the ``__init__`` call was already right and asserting on it would have passed."""
    pick_mode(wiz, "standalone")
    page = advance_to(wiz, wizard_mod.BuildPage)

    # the preflight is off-thread (the freeze fix); let it settle so the button is in
    # its RESTING state rather than the transient "Checking Docker…".
    deadline = time.time() + 20
    while page._recompute_busy and time.time() < deadline:
        qapp.processEvents()
        time.sleep(0.005)
    page._join_preflight_worker()
    qapp.processEvents()

    btn = wiz.button(COMMIT)
    assert btn is not None and btn.isVisible()
    assert not page._recompute_busy, "docker preflight never settled"
    assert btn.text() == "Continue", (
        f"the Review page's commit button reads {btn.text()!r} — it commits the "
        "worklist and lands on the Launch screen, it does not build")

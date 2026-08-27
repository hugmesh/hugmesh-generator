"""E2EPage — the RUN E2E TESTS card's page, driven for real on Qt's offscreen platform.

WHAT THIS PAGE REPLACED. The operator asked on 2026-08-27 to "remove QEMU device
emulation menu item as it does not do anything that cannot be done from the other
menu, but add the run e2e tests button". This page took that card's slot. The QEMU
device-test PAGE was not removed — it is the Studio's only door to
tests/qemu/run-qemu-e2e.sh and tests/qemu/avc-workout.sh — so this page's second radio
arm is its door, and that routing is pinned here and in test_wizard.py.

*** THE ASSERTION THIS FILE EXISTS FOR: IT MUST NEVER BE A LYING BUTTON. ***
A run door that is armed when the mesh cannot host the suite is worse than no door,
because the failure surfaces as a wall of red inside the harness instead of a sentence
on the page. So the gate is pinned in every state: shut before anything is
established, shut and NAMING the reasons when the probe refuses, open only on an empty
answer — and the tree's Run button gated by the same list, in the same sentences.

The Qt-free model behind the chooser is covered by test_e2e_environments.py; the
tree dialog by test_pages_e2e_tree.py. This file is the page.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt")

from hugmesh_studio.core import e2e_catalogue as ec              # noqa: E402
from hugmesh_studio.core import e2e_environments as env_mod      # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo           # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod              # noqa: E402
from hugmesh_studio.gui.pages import e2e as e2e_page_mod         # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                      # noqa: E402

from _helpers import advance_to, pick_mode                       # noqa: E402

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

# a canned host so wizard construction never probes the machine (docker info &c.)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(autouse=True)
def _no_real_docker_probe(monkeypatch):
    """Stub the HOST probe the gate runs off-thread.

    Two reasons, and both are the repo's own house style (test_wizard.py stubs
    docker_available/discover_sessions for exactly this):

    * ``e2e_ready()`` is three ``subprocess.run(..., timeout=30)`` docker calls plus a
      5s urlopen. Letting them run makes this file's verdict depend on whether the
      operator's docker daemon happens to be up, which is not what any assertion here
      is about — the page's GATING is.
    * a probe thread still in flight when its page is destroyed is a Qt qFatal, not an
      exception. A stubbed answer returns in microseconds, so the threads this file
      starts are always finished before teardown reaches them.

    The probe's own WIRING (that it is asked about the CHOSEN environment) is pinned
    separately below, against a fake node, with no thread involved.
    """
    from hugmesh_studio.core.local_stack_node import LocalStackNode
    monkeypatch.setattr(LocalStackNode, "e2e_ready",
                        lambda self, environment="docker": ["stubbed probe"])


@pytest.fixture(scope="module")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(REPO)
    w.show()
    yield w
    # Drain any probe still in flight BEFORE the page can be destroyed: a running
    # QThread whose owner is destroyed aborts the process (qFatal), which is a
    # miserable way to learn that a test leaked one.
    for _ in range(200):
        page = w.page(w._page_ids["e2e"])
        live = [getattr(page, a, None) for a in ("_gate_probe", "_cat_probe")]
        if not any(t is not None and t.isRunning() for t in live):
            break
        qapp.processEvents()
    w.close()
    qapp.processEvents()


@pytest.fixture
def page(wiz):
    """The page reached the way an operator reaches it: through its mode card."""
    pick_mode(wiz, "e2e")
    return advance_to(wiz, wizard_mod.E2EPage)


def _catalogue():
    """A minimal-but-real Catalogue: one spec file with one passing test.

    Built directly rather than through load_catalogue so this file needs no `npx`,
    no node_modules and no fixture tree — what is under test here is the PAGE's
    gating of the dialog, not the dialog's own model (test_pages_e2e_tree.py).
    """
    test = ec.E2ETest(spec_file="specs/01-front-page.spec.ts",
                      title="front page loads",
                      title_path=("front page loads",),
                      status=ec.STATUS_PASSED)
    feature = ec.Feature(file="specs/01-front-page.spec.ts", number="01",
                         tests=(test,))
    return ec.Catalogue(features=[feature])


# ── the card, and where it goes ──────────────────────────────────────────────

def test_the_card_routes_to_this_page(wiz, page):
    assert wiz.e2e_selected is True
    assert wiz.currentId() == wiz._page_ids["e2e"]
    assert page.arm_suite.isChecked()           # the suite arm is the default
    assert page.nextId() == -1                  # …and it is terminal


def test_the_page_commits_nothing_to_the_config(wiz, page):
    """Like every side-flow page: it raises a transient wizard flag and touches no
    ImageConfig field, so the applies_to skip guard holds trivially."""
    before = wiz.cfg.to_dict()
    page.env_combo.setCurrentIndex(page.env_combo.findData("kind"))
    page.arm_qemu.setChecked(True)
    page.arm_suite.setChecked(True)
    assert wiz.cfg.to_dict() == before
    # …and it has no validatePage of its own, so collect_all() cannot re-run a
    # commit through it (the trap QemuPage.validatePage's docstring records).
    assert "validatePage" not in vars(wizard_mod.E2EPage)


# ── the chooser: the catalogue, never a restated list ────────────────────────

def test_the_chooser_offers_exactly_the_catalogued_environments(page):
    ids = [page.env_combo.itemData(i) for i in range(page.env_combo.count())]
    assert ids == list(env_mod.environment_ids()), (
        "the combo and the catalogue disagree; the chooser is BUILT from "
        "describe(), never restated")


def test_the_chooser_defaults_to_todays_behaviour(page):
    assert page.environment() == env_mod.DEFAULT_ENVIRONMENT == "docker"


def test_selecting_an_environment_reaches_the_plan(page):
    """THE LOAD-BEARING PATH: chooser -> plan -> the env a runner is spawned with."""
    for env_id in env_mod.environment_ids():
        page.env_combo.setCurrentIndex(page.env_combo.findData(env_id))
        assert page.environment() == env_id
        assert env_mod.plan(page.environment()).env[env_mod.ENV_VAR] == env_id


def test_every_chooser_row_has_a_tooltip_naming_its_pins(page):
    from hugmesh_studio.gui.qt import Qt
    for i in range(page.env_combo.count()):
        tip = page.env_combo.itemData(i, int(Qt.ItemDataRole.ToolTipRole)) or ""
        assert env_mod.ENV_VAR in tip
        assert "Start it with" in tip


def test_changing_the_chooser_explains_itself_inline(page):
    """A selection handler may not open a modal, so everything it has to say has to
    land in a label. A silently re-pointed target is the defect."""
    page.env_combo.setCurrentIndex(page.env_combo.findData("kind"))
    note = page.env_note.text()
    assert "kind" in note
    assert env_mod.ENV_VAR in note, "the note must name the channel the choice rides on"
    assert "kind-up" in note, "the note must say what to run to start that mesh"


def test_the_page_says_it_starts_nothing(page):
    """`plan(boot=True)` is refused for qemu (root) and this page never asks for it.
    Every 'how do I start that mesh' answer is TEXT, and the page says so."""
    for env_id in env_mod.environment_ids():
        page.env_combo.setCurrentIndex(page.env_combo.findData(env_id))
        note = page.env_note.text()
        assert "Nothing here starts it" in note
        assert env_mod.plan(env_id).start_hint in note


def test_the_scoped_gate_is_declared_for_the_non_docker_meshes(page):
    """e2e_ready() deliberately checks only this checkout for kind and qemu, leaving
    liveness to the harness. A page that hid that would read as a full check."""
    page.env_combo.setCurrentIndex(page.env_combo.findData("docker"))
    assert "answered by the harness" not in page.env_note.text()
    for env_id in ("kind", "qemu"):
        page.env_combo.setCurrentIndex(page.env_combo.findData(env_id))
        assert "answered by the harness" in page.env_note.text()


def test_the_emulator_probe_is_a_note_and_never_a_block(page, monkeypatch):
    """emulator_running() cannot see a device emulating INSIDE the runner container,
    so a False must never shut the door — it is rendered as a note and nothing else."""
    monkeypatch.setattr(env_mod, "emulator_running", lambda runner=None: False)
    page.env_combo.setCurrentIndex(page.env_combo.findData("qemu"))
    assert "no qemu-system-* process is running" in page.env_note.text()
    assert "NOT a gate" in page.env_note.text()
    page._on_gate_answer([])                    # a clean readiness answer…
    assert page.tree_btn.isEnabled()            # …still arms the door


# ── the gate: shut, named, open ──────────────────────────────────────────────

def test_the_gate_starts_shut_before_anything_is_established(page):
    """Nothing established must read as a BLOCKER, never as permission — the
    tri-state seed. An empty blocker list here would be a lie the size of the door."""
    assert page.blockers() == [e2e_page_mod.UNCHECKED_BLOCKER]
    assert page.blockers() != []
    assert not page.tree_btn.isEnabled()
    assert "Checking" in page.gate_note.text()


def test_blockers_shut_the_door_and_name_themselves(page):
    page._on_gate_answer(["the local stack is not running — bring it up first.",
                          "tests/e2e/node_modules missing."])
    assert not page.tree_btn.isEnabled()
    for why in ("the local stack is not running", "node_modules missing"):
        assert why in page.tree_btn.toolTip()
        assert why in page.gate_note.text()
    assert page.blockers() == ["the local stack is not running — bring it up first.",
                               "tests/e2e/node_modules missing."]


def test_a_clean_answer_is_the_only_thing_that_arms_the_door(page):
    page._on_gate_answer(["something"])
    assert not page.tree_btn.isEnabled()
    page._on_gate_answer([])
    assert page.tree_btn.isEnabled()
    assert page.blockers() == []
    assert "Ready" in page.gate_note.text()


def test_changing_the_environment_re_shuts_the_door_until_re_answered(page):
    """The gate's answer belongs to ONE environment. Carrying it across a change
    would arm the button for a mesh nobody probed."""
    page._on_gate_answer([])
    assert page.tree_btn.isEnabled()
    page.env_combo.setCurrentIndex(page.env_combo.findData("kind"))
    assert not page.tree_btn.isEnabled()
    assert "Checking" in page.gate_note.text()


def test_the_gate_probe_is_asked_about_the_chosen_environment(page):
    """Before this, a probe reused from the docker page answered for the compose
    stack — so choosing kind would have greyed the door for reasons describing a
    mesh the operator never selected."""
    from hugmesh_studio.gui.pages import localmesh as lm

    class FakeNode:
        def __init__(self):
            self.asked = []

        def e2e_ready(self, environment="docker"):
            self.asked.append(environment)
            return []

    node = FakeNode()
    page.env_combo.setCurrentIndex(page.env_combo.findData("qemu"))
    probe = lm._E2EGateProbe(node, environment=page.environment())
    probe.run()
    assert node.asked == ["qemu"]


# ── the e2e surface: opened non-modally, gated by the same list ──────────────

def test_the_tree_opens_non_modally_and_carries_the_page_blockers(page, qapp):
    """The house rule, exercised rather than asserted: the dialog is show()n, so a
    headless test drives the whole chain with nothing waiting on a human."""
    page._on_gate_answer(["the local stack is not running — bring it up first."])
    page._show_tree(_catalogue())
    dlg = page._tree_dialog
    try:
        assert dlg.isVisible()
        assert not dlg.isModal()
        assert dlg.blockers == page.blockers()
        # …and the Run button inside it is SHUT, naming the page's own reason.
        assert not dlg.run_btn.isEnabled()
        assert "the local stack is not running" in dlg.run_btn.toolTip()
    finally:
        dlg.close()
        dlg.deleteLater()
        qapp.processEvents()


def test_a_clean_gate_lets_the_tree_arm_on_a_selection(page, qapp):
    from hugmesh_studio.gui.qt import Qt
    page._on_gate_answer([])
    page._show_tree(_catalogue())
    dlg = page._tree_dialog
    try:
        assert dlg.blockers == []
        assert not dlg.run_btn.isEnabled()      # nothing checked yet
        item = dlg.feature_items["specs/01-front-page.spec.ts"]
        item.setCheckState(0, Qt.CheckState.Checked)
        assert dlg.run_btn.isEnabled()          # a selection, and no blocker
    finally:
        dlg.close()
        dlg.deleteLater()
        qapp.processEvents()


def test_opening_the_tree_twice_does_not_leak_the_first(page, qapp):
    page._on_gate_answer([])
    page._show_tree(_catalogue())
    first = page._tree_dialog
    page._show_tree(_catalogue())
    try:
        assert page._tree_dialog is not first
        assert not first.isVisible()
    finally:
        page._tree_dialog.close()
        page._tree_dialog.deleteLater()
        qapp.processEvents()


def test_a_run_is_refused_when_the_gate_refuses(page, monkeypatch):
    """The tree's `accepted` is not a licence: _run re-probes, because enablement can
    go stale the moment the mesh changes underneath the page."""
    started = []
    monkeypatch.setattr(page, "_launch",
                        lambda *a, **k: started.append(a))

    class RefusingNode:
        def e2e_ready(self, environment="docker"):
            return ["the RUNNING stack's env is 'prod', not 'test'."]

    monkeypatch.setattr(page.boot, "_stack_node", lambda: RefusingNode())
    page._run(("specs/01-front-page.spec.ts",))
    assert started == []
    assert "Cannot run e2e" in page.status.text()
    assert "not 'test'" in page.status.text()


def test_a_refused_plan_is_rendered_and_never_spawned(page, monkeypatch):
    """core/e2e_environments refuses to BRING A MESH UP (root, and an unanswerable
    password prompt HANGS rather than fails). A page must render that refusal, never
    act on it."""
    started = []
    monkeypatch.setattr(page, "_launch", lambda *a, **k: started.append(a))

    class ReadyNode:
        def e2e_ready(self, environment="docker"):
            return []

    monkeypatch.setattr(page.boot, "_stack_node", lambda: ReadyNode())
    refused = env_mod.plan("qemu", boot=True)
    assert not refused.runnable                 # the module's own refusal, unmodified
    monkeypatch.setattr(env_mod, "plan", lambda *a, **k: refused)
    page._run(())
    assert started == []
    assert "Cannot run e2e" in page.status.text()


# ── the identity bridge: stated, never silent ────────────────────────────────

def test_the_identity_note_says_which_superadmin_a_run_would_use(page):
    """A menu-level page built from generator_dir alone loses the MINTED superadmin
    the local-mesh bootstrap put in the secrets bundle, and every superadmin scenario
    then 401s. Whatever the answer is here, the page must say it."""
    text = page.identity_note.text()
    assert text.strip()
    assert "Identity:" in text
    bridge, why = page._superadmin_bridge()
    assert why in text
    if bridge:
        assert set(bridge) == {"CASDOOR_SUPERADMIN_USERNAME", "E2E_SUPERADMIN_PASSWORD"}
        assert "secrets bundle" in why
    else:
        assert "deterministic e2e defaults" in why


def test_the_bridge_is_read_through_the_bootstraps_own_reader(page, monkeypatch):
    """One reader for that bundle. A second parser of secrets.json here is how the
    GUI's idea of the minted superadmin drifts from the bootstrap's."""
    from hugmesh_studio.gui.pages import e2e as mod
    monkeypatch.setattr(mod.LocalMeshBootstrap, "superadmin_login",
                        lambda self: ("minted-admin", "s3cret"))
    bridge, why = page._superadmin_bridge()
    assert bridge == {"CASDOOR_SUPERADMIN_USERNAME": "minted-admin",
                      "E2E_SUPERADMIN_PASSWORD": "s3cret"}
    assert "minted-admin" in why
    assert "s3cret" not in why, "a password must never be rendered on the page"


# ── the second arm: the door the removed card left behind ────────────────────

def test_the_qemu_arm_is_the_only_writer_of_the_device_test_flag(wiz, page):
    assert wiz.qemu_selected is False
    page.arm_qemu.setChecked(True)
    assert wiz.qemu_selected is True
    assert page.nextId() == wiz._page_ids["qemu"]
    assert not page.isFinalPage()               # Next, not Exit, on this arm
    assert page.chain_note.isVisible() or not page.suite_box.isVisible()
    page.arm_suite.setChecked(True)
    assert wiz.qemu_selected is False
    assert page.nextId() == -1
    assert page.isFinalPage()


def test_a_re_walk_of_the_mode_screen_does_not_disarm_the_qemu_arm(wiz, page):
    """collect_all() re-runs the validatePage of every VISITED page — including
    ModePage's — so a flat ``qemu_selected = False`` there would silently disarm the
    arm the operator just picked, every time BuildPage was reached. The radio would
    still read "Emulated-device test lanes" while Next skipped QemuPage."""
    page.arm_qemu.setChecked(True)
    assert wiz.qemu_selected is True
    wiz.collect_all()
    assert wiz.qemu_selected is True, (
        "a re-run of ModePage.validatePage disarmed the device-test page")
    assert page.nextId() == wiz._page_ids["qemu"]


def test_committing_a_different_card_does_disarm_the_qemu_arm(wiz, page):
    """The other half of the same rule: a REAL switch must clear it, or a stale True
    strands QemuPage into an unrelated flow."""
    from _helpers import back_to
    page.arm_qemu.setChecked(True)
    assert wiz.qemu_selected is True
    mode = back_to(wiz, wizard_mod.ModePage)
    mode._buttons["standalone"].setChecked(True)
    assert mode.validatePage() is True
    assert wiz.qemu_selected is False
    assert wiz.e2e_selected is False


def test_the_qemu_arm_names_the_three_lanes_it_leads_to(page):
    """The card that was removed described "ephemeral asserted boots". What it
    actually UNIQUELY held was two harnesses with no other door, so this arm names
    them rather than leaving them to be rediscovered."""
    text = page.arm_qemu.toolTip() + page.chain_note.text()
    for script in ("run-qemu-docker.sh", "run-qemu-e2e.sh", "avc-workout.sh"):
        assert script in text
    assert "Mesh emulation" in page.chain_note.text(), (
        "the persistent-device destination must still be named somewhere")

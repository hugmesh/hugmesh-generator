"""The DevOps lane's stop controls: the confirmation the DELETE never had, and the
non-destructive HALT/RESUME pair beside it (hugmesh-generator#356, decision 44 = a).

WHY THIS TEST EXISTS, in two halves.

THE INVERSION. `Delete DevOps lane` went straight to `_launch`: one click deleted the
kind cluster, its Vault KV, its Casdoor identities and every account seeded with them,
with nothing in between — while the LESS destructive `Stop && clean Docker…` did
confirm (`_bootstrap_clean`). The destructive control was the one with no
confirmation. That is fixed here through a module-level seam, `confirm_devops_down`,
the same shape `gui.pages.progress.confirm_flash` uses: the gate is EXERCISED by this
suite rather than stubbed away with the method that carries it. A test that patched
`_devops_down` would prove nothing about the dialog.

THE MISSING VERB. `kind` has no pause, so until now "stop the lane" and "destroy the
lane" were the same button. The halt is the other half: scale the mesh workloads to 0
AND suspend ArgoCD auto-sync. What this file pins about it is the GUI's share of that
contract — that Halt is offered only when the lane's state is KNOWN to be running, that
it does NOT confirm (it is not destructive, and a confirmation on a reversible action
is how operators learn to click through the one that matters), and that the delete's
confirmation points at it.

NO MODALS IN PAGE LOGIC. Every dialog here is reached from an explicit button click
and never from validatePage / initializePage / isComplete / itemChanged — a modal in
any of those deadlocks the offscreen suite forever. The structural assertions at the
bottom pin that, not just the behaviour.

MOSTLY Qt-FREE, on purpose. `LocalMeshPage.__init__` builds the entire surface and
starts its probes; these drive the REAL methods against minimal stand-ins carrying
only the attributes those methods touch, so the code under test is production code.
Only the button-gating tests build a widget, and they build `MeshMonitorWidget` alone
— never the page.
"""
from __future__ import annotations

import inspect
import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import pytest  # noqa: E402

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding installed in this job")

from hugmesh_studio.gui.qt import QtWidgets  # noqa: E402
from hugmesh_studio.gui.pages import localmesh  # noqa: E402
from hugmesh_studio.gui.pages import _mesh_monitor_widget as mw  # noqa: E402
from hugmesh_studio.core import local_stack_node  # noqa: E402


@pytest.fixture(scope="module")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


# ── the stand-in page ────────────────────────────────────────────────────────────
class _Node:
    """Records which node verb ran, and nothing else. A real LocalStackNode would
    shell `make`."""

    def __init__(self) -> None:
        self.calls: list[str] = []

    def devops_down(self, on_line=None, cancel=None):
        self.calls.append("devops_down")
        return True, ""

    def devops_halt(self, on_line=None, cancel=None):
        self.calls.append("devops_halt")
        return True, ""

    def devops_resume(self, on_line=None, cancel=None):
        self.calls.append("devops_resume")
        return True, ""


class _Boot:
    def __init__(self, node) -> None:
        self._node = node

    def _stack_node(self):
        return self._node


class _Page:
    """Only what _devops_down / _devops_halt / _devops_resume touch."""

    def __init__(self) -> None:
        self.node = _Node()
        self.boot = _Boot(self.node)
        self.notes: list[str] = []
        self.launched: list[str] = []

    def _note(self, text, queue=True):
        self.notes.append(text)

    def _launch(self, title, fn, **kw):
        self.launched.append(kw.get("verb", title))
        # Run the thunk so the node verb is really reached, exactly as _launch would.
        fn(lambda _line: None, lambda: False)

    # the real methods under test
    _devops_down = localmesh.LocalMeshPage._devops_down
    _devops_halt = localmesh.LocalMeshPage._devops_halt
    _devops_resume = localmesh.LocalMeshPage._devops_resume


@pytest.fixture
def page():
    return _Page()


def _answers(value):
    """A confirm_devops_down stand-in that records its arguments and answers `value`."""
    seen = {}

    def _confirm(parent, title, text, buttons, default):
        seen["title"] = title
        seen["text"] = text
        seen["buttons"] = buttons
        seen["default"] = default
        return value

    return _confirm, seen


# ── the confirmation the destructive button never had ───────────────────────────
def test_delete_confirms_before_it_deletes(page, monkeypatch):
    confirm, seen = _answers(localmesh.DEVOPS_DOWN_CANCEL)
    monkeypatch.setattr(localmesh, "confirm_devops_down", confirm)
    page._devops_down()
    assert page.node.calls == [], "Cancel still deleted the cluster"
    assert page.launched == [], "Cancel still launched the verb"
    assert seen["title"], "no confirmation was shown at all"


def test_delete_proceeds_on_ok(page, monkeypatch):
    confirm, _ = _answers(localmesh.DEVOPS_DOWN_OK)
    monkeypatch.setattr(localmesh, "confirm_devops_down", confirm)
    page._devops_down()
    assert page.node.calls == ["devops_down"]
    assert page.launched == ["devops-down"]


def test_cancel_says_nothing_was_deleted(page, monkeypatch):
    """The `_bootstrap_clean` idiom: a declined destructive action LOGS that it was
    declined. Silence is indistinguishable from a broken button."""
    confirm, _ = _answers(localmesh.DEVOPS_DOWN_CANCEL)
    monkeypatch.setattr(localmesh, "confirm_devops_down", confirm)
    page._devops_down()
    assert any("cancelled" in n and "NOT deleted" in n for n in page.notes), page.notes


def test_cancel_is_the_default_button(page, monkeypatch):
    """Return cannot delete a cluster. The default is Cancel, as it is for the flash."""
    confirm, seen = _answers(localmesh.DEVOPS_DOWN_CANCEL)
    monkeypatch.setattr(localmesh, "confirm_devops_down", confirm)
    page._devops_down()
    assert seen["default"] == localmesh.DEVOPS_DOWN_CANCEL


def test_anything_other_than_ok_cancels(page, monkeypatch):
    """Not `!= Cancel`. A dialog dismissed with Escape or the window's X returns
    neither button, and that must not delete a cluster."""
    confirm, _ = _answers(object())
    monkeypatch.setattr(localmesh, "confirm_devops_down", confirm)
    page._devops_down()
    assert page.node.calls == []


# ── what the confirmation SAYS ──────────────────────────────────────────────────
# A generic "are you sure?" is what teaches operators to click through. This one
# enumerates what goes, what stays, and what the next start costs — the shape
# _bootstrap_clean already uses.
@pytest.mark.parametrize("phrase", [
    "Vault",                      # the KV that goes with the cluster
    "Casdoor",                    # the identities seeded into it
    "compose",                    # and what is NOT touched
    "EMPTY until it is reseeded",  # a rebuilt mesh is empty and nothing tells you
    "Halt DevOps lane",           # the non-destructive alternative
])
def test_confirmation_enumerates_what_goes_and_what_stays(page, monkeypatch, phrase):
    confirm, seen = _answers(localmesh.DEVOPS_DOWN_CANCEL)
    monkeypatch.setattr(localmesh, "confirm_devops_down", confirm)
    page._devops_down()
    assert phrase in seen["text"], f"confirmation never mentions {phrase!r}"


def test_confirmation_names_the_cluster_it_deletes(page, monkeypatch):
    """The name comes from the ONE reader of KIND_CLUSTER_NAME the verb itself uses,
    so the dialog can never name a different cluster than `kind delete` removes."""
    monkeypatch.setenv("KIND_CLUSTER_NAME", "some-other-lane")
    confirm, seen = _answers(localmesh.DEVOPS_DOWN_CANCEL)
    monkeypatch.setattr(localmesh, "confirm_devops_down", confirm)
    page._devops_down()
    assert "some-other-lane" in seen["text"]
    assert "some-other-lane-control-plane" in seen["text"]


# ── the halt is NOT destructive, and must not confirm ────────────────────────────
def test_halt_does_not_confirm(page, monkeypatch):
    """A confirmation on a reversible action is how an operator learns to click
    through the one that matters. Halt keeps the cluster and everything in it."""
    def _boom(*a, **k):
        raise AssertionError("the halt must not raise a modal")

    monkeypatch.setattr(localmesh, "confirm_devops_down", _boom)
    page._devops_halt()
    assert page.node.calls == ["devops_halt"]
    assert page.launched == ["devops-halt"]


def test_resume_does_not_confirm(page, monkeypatch):
    def _boom(*a, **k):
        raise AssertionError("the resume must not raise a modal")

    monkeypatch.setattr(localmesh, "confirm_devops_down", _boom)
    page._devops_resume()
    assert page.node.calls == ["devops_resume"]
    assert page.launched == ["devops-resume"]


def test_halt_says_nothing_is_deleted(page):
    page._devops_halt()
    joined = " ".join(page.notes)
    assert "NOTHING is deleted" in joined, joined


def test_resume_says_it_does_not_restore_everything(page):
    """The decision's own words: resume must put back what the halt suspended, not
    'everything', or it silently undoes a deliberate suspend."""
    page._devops_resume()
    joined = " ".join(page.notes)
    assert "another reason stays suspended" in joined, joined


# ── the node verbs reach the right make targets ─────────────────────────────────
def test_node_verbs_call_the_documented_targets(monkeypatch):
    seen = []

    def _fake_make(self, target, **kw):
        seen.append(target)
        return True, ""

    monkeypatch.setattr(local_stack_node.LocalStackNode, "_make", _fake_make)
    node = local_stack_node.LocalStackNode.__new__(local_stack_node.LocalStackNode)
    node.devops_halt()
    node.devops_resume()
    node.devops_down()
    assert seen == ["kind-halt", "kind-resume", "kind-down"]


def test_halt_is_not_wired_to_the_destructive_target():
    """The one-line mistake this whole issue is about: `kind-down` deletes. If halt
    ever resolves to it, everything above still passes and the operator loses the
    cluster."""
    src = inspect.getsource(local_stack_node.LocalStackNode.devops_halt)
    assert "kind-halt" in src
    assert "kind-down" not in src.split('"""')[-1], "halt reaches the destructive target"


# ── the monitor's gate: unknown is never "no" ───────────────────────────────────
def test_halt_is_offered_only_when_the_lane_is_known_to_run(qapp):
    w = mw.MeshMonitorWidget()
    w.set_kind_lane(True)
    assert w.halt_btn.isEnabled()
    assert w.resume_btn.isEnabled()


def test_halt_is_greyed_when_the_lane_state_is_unknown(qapp):
    """Invariant I5 in GUI form. `running is None` means the census could not be
    taken, and acting on that is the run-ungated-lane.sh exit-5 mistake — the one
    the shell half of this feature refuses with."""
    w = mw.MeshMonitorWidget()
    w.set_kind_lane(None, "kubectl not on PATH")
    assert not w.halt_btn.isEnabled()
    assert not w.resume_btn.isEnabled()


def test_the_unknown_gate_says_why_and_quotes_the_reason(qapp):
    w = mw.MeshMonitorWidget()
    w.set_kind_lane(None, "kubectl not on PATH")
    tip = w.halt_btn.toolTip()
    assert "could not be read" in tip
    assert "kubectl not on PATH" in tip, "the reason was dropped"
    assert "not 'nothing running'" in tip


def test_halt_is_greyed_when_the_lane_is_down(qapp):
    w = mw.MeshMonitorWidget()
    w.set_kind_lane(False)
    assert not w.halt_btn.isEnabled()
    assert "nothing to halt" in w.halt_btn.toolTip()


def test_both_tooltips_are_rewritten_on_every_branch(qapp):
    """The bug set_view_session already had to fix once: writing only one branch's
    tooltip leaves the ENABLED button explaining why it is disabled."""
    w = mw.MeshMonitorWidget()
    w.set_kind_lane(None, "boom")
    w.set_kind_lane(True)
    assert "could not be read" not in w.halt_btn.toolTip()
    assert "could not be read" not in w.resume_btn.toolTip()
    w.set_kind_lane(None, "boom")
    assert "could not be read" in w.halt_btn.toolTip()
    assert "could not be read" in w.resume_btn.toolTip()


def test_the_controls_start_greyed_before_any_snapshot(qapp):
    """A fresh widget has read nothing. Offering a halt there would be acting on an
    unknown lane at its most literal."""
    w = mw.MeshMonitorWidget()
    assert not w.halt_btn.isEnabled()
    assert not w.resume_btn.isEnabled()


def test_buttons_emit_and_do_not_shell(qapp):
    """Like every other control on this widget: it EMITS, the mounting page runs it.
    A widget that shelled would run `make` on the GUI thread."""
    w = mw.MeshMonitorWidget()
    w.set_kind_lane(True)
    fired = []
    w.halt_requested.connect(lambda: fired.append("halt"))
    w.resume_requested.connect(lambda: fired.append("resume"))
    w.halt_btn.click()
    w.resume_btn.click()
    assert fired == ["halt", "resume"]


def test_halt_button_has_no_ellipsis_and_delete_still_warns(qapp):
    """House idiom: an ellipsis promises a dialog. The halt raises none, so it has
    none — and that difference is the operator's cue to which button is which."""
    w = mw.MeshMonitorWidget()
    assert "…" not in w.halt_btn.text()
    assert "..." not in w.halt_btn.text()
    # The armed tooltip, not the greyed one — a fresh widget has read nothing and is
    # deliberately in the unknown state (see the test above).
    w.set_kind_lane(True)
    assert "kind-halt" in w.halt_btn.toolTip()


def test_the_halt_tooltip_names_what_keeps_running(qapp):
    """Scaling coredns, kyverno, the provisioner or ArgoCD to 0 makes resume itself
    impossible, so the halt leaves them up. An operator who is halting to free
    resources must not think the button failed."""
    w = mw.MeshMonitorWidget()
    tip = mw._HALT_TIP
    for name in ("coredns", "kyverno", "ArgoCD"):
        assert name in tip, f"the halt tooltip never mentions {name}"
    assert "Resume impossible" in tip


# ── structural: the no-modals rule, and the single call site ─────────────────────
def test_confirm_is_a_module_level_seam():
    assert callable(localmesh.confirm_devops_down)


def test_exactly_one_call_site():
    """One gate. A second call site is a second place for the wording — and for a
    future edit to leave one of them unguarded."""
    src = inspect.getsource(localmesh)
    assert src.count("confirm_devops_down(") == 1


def test_the_gate_lives_in_devops_down_and_nowhere_dangerous():
    """The no-modals rule, structurally. A QMessageBox reached from validatePage,
    initializePage, isComplete or itemChanged hangs the offscreen suite forever."""
    src = inspect.getsource(localmesh.LocalMeshPage._devops_down)
    assert "confirm_devops_down(" in src
    checked = []
    for name in ("validatePage", "initializePage", "isComplete", "itemChanged"):
        meth = getattr(localmesh.LocalMeshPage, name, None)
        if meth is None or not callable(meth):
            continue
        try:
            body = inspect.getsource(meth)
        except (TypeError, OSError):
            # Inherited straight from QWizardPage — a C++ slot with no Python body,
            # so this page cannot have put a modal in it. Recorded, not silently
            # skipped: an empty `checked` list below would mean this test proved
            # nothing at all.
            continue
        checked.append(name)
        assert "confirm_devops_down" not in body, f"{name} raises the confirmation"
        assert "QMessageBox" not in body, f"{name} raises a modal"
    assert checked, "no Python-defined hook was inspected — this test proved nothing"


def test_neither_halt_nor_resume_raises_a_modal():
    for meth in (localmesh.LocalMeshPage._devops_halt,
                 localmesh.LocalMeshPage._devops_resume):
        body = inspect.getsource(meth)
        assert "QMessageBox" not in body
        assert "confirm_devops_down" not in body


# ── the SECOND tri-state: is the lane already halted? ───────────────────────────
# A halted lane still reports running=True — the halt KEEPS the cluster. Before this
# the Studio offered Halt on an already-halted lane with nothing on screen saying it
# was halted, so pressing it twice was a normal operator action. That mattered a
# great deal more when a second halt could destroy the first one's record; it is
# still wrong now that kind-halt.sh refuses, because a refusal after the fact is not
# the same as a control that shows you the state.
def test_a_halted_lane_greys_halt_and_points_at_resume(qapp):
    w = mw.MeshMonitorWidget()
    w.set_kind_lane(True, halted=True)
    assert not w.halt_btn.isEnabled(), "Halt was offered on an already-halted lane"
    assert w.resume_btn.isEnabled()
    tip = w.halt_btn.toolTip()
    assert "already HALTED" in tip
    assert "Resume DevOps lane" in tip, "the greyed control does not say what to do instead"


def test_a_running_unhalted_lane_greys_resume(qapp):
    w = mw.MeshMonitorWidget()
    w.set_kind_lane(True, halted=False)
    assert w.halt_btn.isEnabled()
    assert not w.resume_btn.isEnabled(), "Resume was offered with nothing to resume"
    assert "not halted" in w.resume_btn.toolTip()


def test_an_unreadable_halt_state_offers_both_and_says_so(qapp):
    """Unknown is not 'not halted', exactly as unknown is not 'not running'. The
    shell half refuses (exit 5) when it cannot read its own record; the GUI cannot
    refuse on the operator's behalf, so it offers both and names the uncertainty."""
    w = mw.MeshMonitorWidget()
    w.set_kind_lane(True, halted=None)
    assert w.halt_btn.isEnabled()
    assert w.resume_btn.isEnabled()
    for tip in (w.halt_btn.toolTip(), w.resume_btn.toolTip()):
        assert "could not be determined" in tip
        assert "not the same as 'there is none'" in tip
        # …and it must NOT read like the lane-unknown branch, which is a different
        # uncertainty with a different answer (that one greys both controls).
        assert "could not be read" not in tip


def test_the_halted_state_never_overrides_a_down_or_unknown_lane(qapp):
    """halted is a REFINEMENT of running, never a promotion of it. A lane that is
    down or unestablished must stay fully greyed whatever the halt record says."""
    w = mw.MeshMonitorWidget()
    for running in (False, None):
        for halted in (True, False, None):
            w.set_kind_lane(running, "why", halted=halted)
            assert not w.halt_btn.isEnabled(), (running, halted)
            assert not w.resume_btn.isEnabled(), (running, halted)


def test_the_halted_branch_rewrites_both_tooltips_too(qapp):
    """Same trap as the unknown branch: a stale sentence on the button that is now
    enabled. Walk every transition, not just into the new state."""
    w = mw.MeshMonitorWidget()
    w.set_kind_lane(True, halted=True)
    assert "already HALTED" in w.halt_btn.toolTip()
    w.set_kind_lane(True, halted=False)
    assert "already HALTED" not in w.halt_btn.toolTip()
    assert "not halted" in w.resume_btn.toolTip()
    w.set_kind_lane(True, halted=None)
    assert "not halted" not in w.resume_btn.toolTip()
    assert "could not be determined" in w.resume_btn.toolTip()


def test_the_page_passes_the_halted_state_through(qapp):
    """The wiring, not the widget. _on_monitor must forward LaneState.halted, or the
    gate above is dead code fed a permanent None."""
    seen = {}

    class _Mon:
        def set_view_session(self, *a, **k):
            pass

        def set_kind_lane(self, running, reason="", halted=None):
            seen.update(running=running, reason=reason, halted=halted)

    class _Kind:
        running = True
        halted = True
        detail = "cluster hugmesh-local · HALTED"
        error = ""

    class _Snap:
        kind = _Kind()
        view_doors = ()
        view_lane = ""

    page = localmesh.LocalMeshPage.__new__(localmesh.LocalMeshPage)
    page.monitor = _Mon()
    page._sync_monitor_gate = lambda: None
    localmesh.LocalMeshPage._on_monitor(page, _Snap())
    assert seen["running"] is True
    assert seen["halted"] is True, "LaneState.halted never reached the gate"


# ── the probe behind it ─────────────────────────────────────────────────────────
def test_lane_state_halted_defaults_to_unknown():
    from hugmesh_studio.core import mesh_monitor as mm
    assert mm.LaneState(True).halted is None, (
        "a lane nobody asked about must not default to 'not halted'")


@pytest.mark.parametrize("rc,out,want", [
    (0, '{"version": 2}', True),
    (0, "", False),
    (1, 'Error from server (NotFound): configmaps "hugmesh-kind-halt" not found', False),
    (1, "Unable to connect to the server: net/http: TLS handshake timeout", None),
    (1, "error: You must be logged in to the server (Unauthorized)", None),
])
def test_the_halt_record_probe_is_a_tri_state(rc, out, want, monkeypatch):
    """The same distinction kind-halt.sh makes in shell, and for the same reason: a
    read that FAILED is not a record that is ABSENT. Conflating them is what let a
    second halt overwrite a good record with an all-zero one."""
    from hugmesh_studio.core import mesh_monitor as mm

    monkeypatch.setattr(mm, "_probe", lambda node, cmd, timeout: (rc, out))
    budget = mm._Budget(30)
    assert mm._halt_record_present(None, "kubectl", "kind-hugmesh-local", budget) is want


def test_the_halt_record_probe_is_pinned_to_the_context_and_namespace(monkeypatch):
    from hugmesh_studio.core import mesh_monitor as mm

    calls = []
    monkeypatch.setattr(mm, "_probe",
                        lambda node, cmd, timeout: (calls.append(cmd), (1, "NotFound"))[1])
    mm._halt_record_present(None, "kubectl", "kind-hugmesh-local", mm._Budget(30))
    cmd = calls[0]
    assert "--context" in cmd and cmd[cmd.index("--context") + 1] == "kind-hugmesh-local"
    assert "-n" in cmd and cmd[cmd.index("-n") + 1] == mm.ARGOCD_NS
    assert mm.KIND_HALT_STATE_CM in cmd
    # READ ONLY. This runs on every monitor poll against the operator's live cluster.
    assert not ({"patch", "scale", "delete", "create", "apply", "edit"} & set(cmd)), cmd


def test_the_halt_record_probe_is_skipped_rather_than_guessed_when_out_of_budget(monkeypatch):
    """An exhausted deadline must answer None, not False. Reporting 'not halted'
    because there was no time to ask is the census mistake in miniature."""
    from hugmesh_studio.core import mesh_monitor as mm

    monkeypatch.setattr(mm, "_probe",
                        lambda *a, **k: pytest.fail("the probe ran with no budget"))
    assert mm._halt_record_present(None, "kubectl", "kind-x", mm._Budget(0)) is None


# ── the other destructive door ──────────────────────────────────────────────────
def test_the_kind_delete_button_is_not_called_stop(qapp):
    """Since #356 the Studio ships a real non-destructive stop. This button runs
    `kind delete cluster` and used to be labelled "Stop Kubernetes now" — with both
    verbs in one application that label points the operator at the wrong one."""
    from hugmesh_studio.gui.pages import localcloud_nodes as ln

    # The BUTTON's text, not the module source: the comment explaining the rename
    # quotes the old label, and a source-wide search cannot tell a label from a note
    # about a label.
    src = inspect.getsource(ln)
    assert 'QPushButton("Stop Kubernetes now")' not in src
    assert 'QPushButton("Delete the Kubernetes cluster now")' in src
    assert "Halt DevOps lane" in src, "the destructive button does not name the stop"

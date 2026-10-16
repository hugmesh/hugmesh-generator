"""The Studio GUI half of the e2e ENVIRONMENT lane: the chooser and the evidence
browser, driven for real on Qt's offscreen platform.

GUI test file -> importorskip the binding, exactly as every other GUI file here
does. The Qt-FREE model behind both surfaces is covered by
test_e2e_environments.py / test_e2e_evidence.py, which run with no toolkit at
all.

*** THE HOUSE RULE THIS FILE IS THE GUARD FOR ***
NO QMessageBox AND NO .exec() INSIDE validatePage OR AN itemChanged HANDLER — it
HANGS headless tests (feedback_no_modals_in_page_logic). The chooser's handler
and the evidence tree's selection handler are BOTH driven here with no modal
loop available, so a modal creeping into either would hang this file rather than
some unrelated suite three weeks later. test_no_modal_in_page_logic asserts it
statically too, because a hang is a terrible way to learn.
"""
import json
import os

import pytest

pytest.importorskip("hugmesh_studio.gui.qt")

from hugmesh_studio.core import e2e_environments as env_mod   # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                    # noqa: E402

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


@pytest.fixture
def localmesh_page(qt_app):
    from hugmesh_studio.gui import wizard as wizard_mod
    wiz = wizard_mod.StudioWizard(REPO)
    wiz.setStartId(wiz._page_ids["localmesh"])
    wiz.restart()
    page = wiz.currentPage()
    assert type(page).__name__ == "LocalMeshPage"
    yield page
    wiz.deleteLater()


@pytest.fixture
def qt_app():
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    return app


# ── the chooser ──────────────────────────────────────────────────────────────

def test_chooser_offers_exactly_the_catalogued_environments(localmesh_page):
    combo = localmesh_page.e2e_env_combo
    ids = [combo.itemData(i) for i in range(combo.count())]
    assert ids == list(env_mod.environment_ids()), (
        "the combo box and the catalogue disagree; the chooser is supposed to be "
        "BUILT from describe(), not restated")


def test_chooser_defaults_to_todays_behaviour(localmesh_page):
    """docker is what an unset SNAP_ENV has always meant. A different default
    would silently re-point every GUI run."""
    assert localmesh_page.e2e_environment() == env_mod.DEFAULT_ENVIRONMENT == "docker"


def test_selecting_an_environment_reaches_the_plan(localmesh_page):
    """THE PATH THAT MATTERS: chooser -> plan -> the env the runner is spawned
    with. Broken deliberately by the guard battery's M1."""
    combo = localmesh_page.e2e_env_combo
    for env_id in env_mod.environment_ids():
        combo.setCurrentIndex(combo.findData(env_id))
        assert localmesh_page.e2e_environment() == env_id
        plan = env_mod.plan(localmesh_page.e2e_environment())
        assert plan.env[env_mod.ENV_VAR] == env_id


def test_changing_the_chooser_explains_itself_inline(localmesh_page):
    """A selection handler may not open a modal, so everything it has to say has
    to land in a label. An empty status here would leave the operator with a
    silently-changed target."""
    combo = localmesh_page.e2e_env_combo
    combo.setCurrentIndex(combo.findData("kind"))
    text = localmesh_page.status.text()
    assert "kind" in text
    assert env_mod.ENV_VAR in text, "the status must name the channel the choice rides on"
    assert "kind-up" in text, "the status must say what to run to start that mesh"


def test_every_chooser_row_has_a_tooltip_naming_its_pins(localmesh_page):
    from hugmesh_studio.gui.qt import Qt
    combo = localmesh_page.e2e_env_combo
    for i in range(combo.count()):
        tip = combo.itemData(i, int(Qt.ItemDataRole.ToolTipRole)) or ""
        assert env_mod.ENV_VAR in tip
        assert "Start it with" in tip


def test_the_gate_probe_is_asked_about_the_chosen_environment(localmesh_page):
    """Before this, the readiness probe always answered for the DOCKER compose
    stack, so selecting kind would have greyed the Run button for reasons
    describing a mesh the operator never chose."""
    from hugmesh_studio.gui.pages import localmesh as lm

    class FakeNode:
        def __init__(self):
            self.asked = []

        def e2e_ready(self, environment="docker"):
            self.asked.append(environment)
            return []

    node = FakeNode()
    probe = lm._E2EGateProbe(node, environment="qemu")
    probe.run()
    assert node.asked == ["qemu"]


@pytest.mark.real_stack_probes          # this IS the function under test
def test_e2e_ready_is_scoped_by_environment():
    """The docker probes below the node_modules check describe ONE mesh. Running
    them for kind or qemu would report blockers about a stack nobody selected."""
    from hugmesh_studio.core.local_stack_node import LocalStackNode
    node = LocalStackNode(REPO)
    called = []
    node.status = lambda *a, **k: called.append("status") or (_ for _ in ()).throw(
        AssertionError("status() must not be probed for a non-docker environment"))
    problems = node.e2e_ready("kind")
    assert called == []
    assert all("stack is not running" not in p for p in problems)


@pytest.mark.real_stack_probes          # this IS the function under test
def test_e2e_ready_rejects_an_unknown_environment():
    from hugmesh_studio.core.local_stack_node import LocalStackNode
    with pytest.raises(ValueError):
        LocalStackNode(REPO).e2e_ready("compose")


# ── the evidence browser ─────────────────────────────────────────────────────

def _fixture_run(tmp_path, missing=False):
    run = tmp_path / "bdd-steps" / "r1"
    (run / "f" / "s").mkdir(parents=True)
    png = run / "f" / "s" / "001-step.png"
    png.write_bytes(bytes.fromhex("89504e470d0a1a0a") + b"\x00" * 32)
    (run / "f" / "s" / "001-step.json").write_text("{}", encoding="utf-8")
    row = {
        "env": "kind", "interface": "studio", "feature": "features/f.feature",
        "scenario": "s", "step": "I do a thing", "ordinal": 1,
        "role": None, "service": None, "platform": None, "layer": "ui",
        "failed": False, "kind": "widget-grab",
        "path": "f/s/001-step.png", "sidecar": "f/s/001-step.json",
        "bytes": 40, "at": "2026-08-26T00:00:00Z", "note": "page=localmesh",
    }
    (run / "manifest.json").write_text(json.dumps({
        "schema": "hugmesh.bdd.evidence-manifest/1", "runId": "r1",
        "root": str(run), "generatedAt": "2026-08-26T00:00:00Z",
        "counts": {"artefacts": 1, "failed": 0,
                   "byEnv": {}, "byInterface": {}, "byKind": {}},
        "artefacts": [row],
    }), encoding="utf-8")
    if missing:
        png.unlink()
    return str(tmp_path)


def test_evidence_browser_groups_by_environment_and_interface(qt_app, tmp_path):
    from hugmesh_studio.gui.pages._e2e_evidence_dialog import E2EEvidenceDialog
    dlg = E2EEvidenceDialog(report_dir=_fixture_run(tmp_path))
    top = dlg.tree.topLevelItem(0)
    assert top is not None, "the tree is empty for a run that has one artefact"
    assert top.text(0) == "kind"
    assert top.child(0).text(0) == "studio"
    leaf = top.child(0).child(0).child(0).child(0)
    assert "widget-grab" in leaf.text(1)
    assert "kind" in dlg.header.text() and "studio" in dlg.header.text()
    dlg.deleteLater()


def test_evidence_browser_shows_a_lying_row_LOUDLY(qt_app, tmp_path):
    """*** THE ONE THAT MATTERS. *** A row whose artefact is gone must stay in
    the tree, marked, and the header must say the index and the disk disagree.
    Filtering it out would turn a broken run into a clean-looking one — the
    single most expensive thing this surface could do."""
    from hugmesh_studio.gui.pages._e2e_evidence_dialog import E2EEvidenceDialog
    dlg = E2EEvidenceDialog(report_dir=_fixture_run(tmp_path, missing=True))
    top = dlg.tree.topLevelItem(0)
    leaf = top.child(0).child(0).child(0).child(0)
    assert "MISSING ON DISK" in leaf.text(0)
    # isHidden(), not isVisible(): a widget on a dialog nobody show()ed is never
    # "visible" no matter what setVisible() was told, so isVisible() here would
    # assert on the dialog's own state rather than on this label's.
    assert not dlg.problems.isHidden()
    assert "MISSING" in dlg.problems.text()
    assert "MISSING file" in dlg.header.text()
    # ...and selecting it explains the situation INLINE rather than in a modal.
    dlg.tree.setCurrentItem(leaf)
    assert "NOT ON DISK" in dlg.text.toPlainText()
    dlg.deleteLater()


def test_evidence_browser_empty_state_names_the_command(qt_app, tmp_path):
    """'No runs found' with no next step reads as 'the app is broken'."""
    from hugmesh_studio.gui.pages._e2e_evidence_dialog import E2EEvidenceDialog
    dlg = E2EEvidenceDialog(report_dir=str(tmp_path))
    assert dlg.tree.topLevelItemCount() == 0
    assert "stack-e2e-bdd-env" in dlg.header.text()
    assert "SNAP_ENV=kind" in dlg.header.text()
    dlg.deleteLater()


def test_evidence_browser_never_edits_the_evidence(qt_app, tmp_path):
    """Evidence is a RECORD. An editable pane over it would let a reviewer
    'fix' the thing they are supposed to be reading."""
    from hugmesh_studio.gui.pages._e2e_evidence_dialog import E2EEvidenceDialog
    dlg = E2EEvidenceDialog(report_dir=_fixture_run(tmp_path))
    assert dlg.text.isReadOnly()
    dlg.deleteLater()


# ── the house rule, statically ───────────────────────────────────────────────

@pytest.mark.parametrize("rel", [
    "hugmesh_studio/gui/pages/_e2e_evidence_dialog.py",
    "hugmesh_studio/gui/pages/localmesh.py",
    # E2EPage (the RUN E2E TESTS card, 2026-08-27) added a SECOND environment combo
    # and two arm radios, i.e. two more currentIndexChanged/toggled handlers — the
    # exact signal class this check exists for.
    "hugmesh_studio/gui/pages/e2e.py",
])
def test_no_modal_in_page_logic(rel):
    """No QMessageBox and no .exec() inside PAGE LOGIC.

    THE RULE IS PRECISE, and being precise is what makes it enforceable. A modal
    is fine from a BUTTON CLICK — `_bootstrap_clean` has confirmed a destructive
    stack wipe that way since long before this unit — and fatal from
    ``validatePage`` or from a handler Qt calls while a widget is CHANGING, where
    a headless test has no event loop to answer it and simply hangs
    (feedback_no_modals_in_page_logic).

    So the banned sites are computed rather than guessed: ``validatePage``, plus
    every function CONNECTED to one of the state-change signals below. That set
    is exactly where this unit added code — the environment combo's
    currentIndexChanged and the evidence tree's itemSelectionChanged/itemClicked.

    Comments cannot fool this check: it walks the AST, where comments do not
    exist and a docstring is a Constant no Call test can match. Both files
    DISCUSS this rule in prose containing the very words a grep would look for,
    which is precisely the comment-token inversion this repo has been bitten by
    five times.
    """
    import ast
    path = os.path.join(os.path.dirname(__file__), "..", rel)
    with open(path, encoding="utf-8") as fh:
        tree = ast.parse(fh.read())

    # Signals Qt emits WHILE something is changing. A modal opened from one of
    # these blocks the change itself.
    STATE_SIGNALS = {
        "itemChanged", "currentIndexChanged", "itemSelectionChanged",
        "currentItemChanged", "currentRowChanged", "itemClicked",
        "textChanged", "stateChanged", "toggled", "currentChanged",
    }
    banned_handlers = {"validatePage"}
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Call)
                and isinstance(node.func, ast.Attribute)
                and node.func.attr == "connect"):
            continue
        sig = node.func.value
        signal_name = sig.attr if isinstance(sig, ast.Attribute) else ""
        if signal_name not in STATE_SIGNALS:
            continue
        for arg in node.args:
            # self._handler
            if isinstance(arg, ast.Attribute):
                banned_handlers.add(arg.attr)
            # lambda *_a: self._handler()
            for inner in ast.walk(arg):
                if isinstance(inner, ast.Call) and isinstance(inner.func, ast.Attribute):
                    banned_handlers.add(inner.func.attr)

    # REAL-CASES CHECK. The evidence dialog is KNOWN to wire state-change signals
    # (currentIndexChanged, itemSelectionChanged, itemClicked). If the detector
    # ever finds none there, it has broken and this test would be passing while
    # checking nothing. localmesh.py is not asserted this way because its handler
    # set is not this unit's to pin.
    if rel.endswith("_e2e_evidence_dialog.py"):
        assert len(banned_handlers) > 1, (
            "no state-change handler was identified in %s, so this check would "
            "pass vacuously — the detector is broken." % rel)

    def offenders(fn):
        hits = []
        for node in ast.walk(fn):
            if isinstance(node, ast.Attribute) and node.attr == "QMessageBox":
                hits.append("QMessageBox@%d" % node.lineno)
            if isinstance(node, ast.Name) and node.id == "QMessageBox":
                hits.append("QMessageBox@%d" % node.lineno)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) \
                    and node.func.attr == "exec":
                hits.append("exec()@%d" % node.lineno)
        return hits

    for fn in ast.walk(tree):
        if not isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        if fn.name not in banned_handlers:
            continue
        hits = offenders(fn)
        assert not hits, (
            "%s: %s() is page logic (validatePage, or connected to a state-change "
            "signal) and contains %s. A modal there hangs every headless test — "
            "use an inline label; exec() only from a button click."
            % (rel, fn.name, ", ".join(hits)))


def test_the_modal_detector_actually_bites(tmp_path):
    """A guard nobody has seen fail is a guard nobody has tested. Plant the
    defect in a throwaway file and require the same logic to catch it."""
    import ast
    bad = tmp_path / "bad_page.py"
    bad.write_text(
        "class P:\n"
        "    def build(self):\n"
        "        self.combo.currentIndexChanged.connect(self._on_change)\n"
        "    def _on_change(self):\n"
        "        QtWidgets.QMessageBox.information(self, 'hi', 'there')\n",
        encoding="utf-8")
    tree = ast.parse(bad.read_text(encoding="utf-8"))
    handlers = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) \
                and node.func.attr == "connect":
            for arg in node.args:
                if isinstance(arg, ast.Attribute):
                    handlers.add(arg.attr)
    assert "_on_change" in handlers
    fn = [n for n in ast.walk(tree)
          if isinstance(n, ast.FunctionDef) and n.name == "_on_change"][0]
    assert any(isinstance(n, ast.Attribute) and n.attr == "QMessageBox"
               for n in ast.walk(fn))

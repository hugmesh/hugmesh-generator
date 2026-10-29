"""The local AI agent launcher (#695), driven headless through the REAL wizard with the
REAL bottom panel mounted, and through the REAL single-page dialog, with a fake prober and
a fake launcher.

Pinned here:

* the card lives in the Studio's bottom panel (gui/_local_ai_dock.py, Assistant tab) and
  NOT on the Bring-up page any more (operator ask 2026-10-21: out of the build phase);
  the build phase hosts no copy of it, in the wizard or in ``LocalMeshDialog``; it still
  follows the local-mesh page (``follow_page``); building it reads nothing from the
  machine, the first look happens when the card is first SHOWN, on a worker thread, and
  nothing starts without a press;
* every missing prerequisite (Ollama not installed, server not answering, no model with
  tools, no agent command, a folder that is not a repository) is named in the status in
  plain words, the Start button is disabled and its tooltip says why, and Re-check picks
  up a fix;
* a press hands the launcher exactly the right argv, folder, environment and brief for
  each lane, makes a copy with no remote, and a refusal shows the lines to run by hand;
* Copy command is always available;
* GEOMETRY, in every state, at the wizard's smallest supported window (736x736) and a
  normal one: every control is drawn inside the card and inside the viewport, tall and
  wide enough to click, nothing overlaps, and long paths and commands elide or scroll
  instead of pushing a control out. #647 is why this is a test and not a reading of the
  layout code.

Set LOCAL_AGENT_SHOTS=<dir> to save a PNG of the card in each state.
"""
import ast
import inspect
import os
import subprocess
import threading
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import local_agent as la                       # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                  # noqa: E402
from hugmesh_studio.core import local_ai_status as lai                 # noqa: E402
from hugmesh_studio.gui import _local_ai_dock as dock_mod              # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                     # noqa: E402
from hugmesh_studio.gui.pages import _local_agent_widget as law         # noqa: E402
from hugmesh_studio.gui.pages import localmesh as lm                    # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtGui, QtWidgets              # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")

SMALLEST = (736, 736)          # gui.wizard.medium_size on an 800x800 screen
NORMAL = (1040, 706)           # a 768p laptop
SHOTS = os.environ.get("LOCAL_AGENT_SHOTS", "")
SECRET = "must-never-reach-the-agent"
APP = "hugmesh-user-bff-api"


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-local-agent-tests"]))


def _quiet_snapshot():
    return lai.Snapshot(taken=0.0, state_dir="/nonexistent", host="127.0.0.1:11434",
                        summary="Local AI: (test)")


@pytest.fixture
def wiz(qapp):
    """A Studio window as StudioShell opens one: the wizard with the bottom panel
    mounted, COLLAPSED, so the card is not shown (and does not look at the machine)
    until a test has installed its fakes."""
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    dock_mod.mount_dock(w, GENERATOR_DIR, auto_poll=False, expanded=False,
                        snapshot_fn=_quiet_snapshot)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def git(*args, cwd):
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
               GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
    p = subprocess.run(["git", *args], cwd=cwd, env=env, capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    return p.stdout.strip()


@pytest.fixture
def src_tree(tmp_path):
    """The operator's own tree: two real git checkouts and one plain folder."""
    src = tmp_path / "mine"
    for name in (APP, "hugmesh-admin-ui"):
        d = src / name
        d.mkdir(parents=True)
        git("init", "-q", "-b", "main", cwd=d)
        (d / "README.md").write_text(f"# {name}\n")
        git("add", "README.md", cwd=d)
        git("commit", "-q", "-m", "first", cwd=d)
    (src / "hugmesh-gateway").mkdir()                  # exists, but not a repository
    return str(src)


# ── fakes ────────────────────────────────────────────────────────────────────────
def probe_of(models=("qwen3:8b",), agents=("claude",), ollama=True, up=True, tools=True,
             error="connection refused"):
    return la.Probe(
        ollama_path="/usr/bin/ollama" if ollama else "", server="127.0.0.1:11434",
        server_up=up, server_error="" if up else error,
        models=tuple(la.ModelInfo(m, tools) for m in models) if up else (),
        agents={a: ("/usr/bin/" + a if a in agents else "") for a in la.AGENTS})


class Prober:
    def __init__(self, probe):
        self.probe = probe
        self.calls = 0
        self.threads = []

    def __call__(self):
        self.calls += 1
        self.threads.append(threading.current_thread())
        return self.probe


class Launcher:
    def __init__(self, opened=True, reason="", terminal="konsole"):
        self.opened, self.reason, self.terminal = opened, reason, terminal
        self.plans = []
        self.threads = []

    def __call__(self, plan):
        self.plans.append(plan)
        self.threads.append(threading.current_thread())
        return la.LaunchResult(self.opened, self.opened, self.terminal if self.opened else "",
                               self.reason, plan.after_copy_text)


def _to(wiz, cls, limit=16):
    for _ in range(limit):
        if isinstance(wiz.currentPage(), cls):
            return wiz.currentPage()
        before = wiz.currentId()
        wiz.next()
        assert wiz.currentId() != before, f"stuck on {type(wiz.currentPage()).__name__}"
    raise AssertionError(f"never reached {cls.__name__}")


def _to_bringup(wiz, probe=None, launcher=None, source_dir=None, size=None):
    """Welcome -> ... -> the Bring-up page, with the fakes installed BEFORE the card is
    first shown (that first show is what starts the first look)."""
    if size:
        wiz.resize(*size)
    wiz.next()
    mode = wiz.currentPage()
    mode._buttons["localmesh"].setChecked(True)
    mode._on_mode_toggled()
    wiz.next()
    wiz.currentPage()._buttons["generate"].setChecked(True)
    wiz.next()
    ctl = wiz.localmesh_page
    card = wiz.local_ai_dock.agent_card
    prober = Prober(probe or probe_of())
    launch = launcher or Launcher()
    card.set_prober(prober)
    card.set_launcher(launch)
    _to(wiz, lm.LocalMeshSourcePage)
    if source_dir is not None:
        ctl.src_existing.setChecked(True)
        ctl.src_dir.setText(source_dir)
    _to(wiz, lm.LocalMeshPage)
    # the Bring-up step opens the panel on its Local mesh tab; the card is on Assistant
    wiz.local_ai_dock.show_tab("assistant")
    _settle()
    assert card.isVisible()
    card.wait_idle()
    _settle()
    return ctl, card, prober, launch


def _settle(n=3):
    for _ in range(n):
        QtWidgets.QApplication.processEvents()


def _pick(card, app=APP, lane=None):
    card.app_box.setCurrentIndex(card.app_box.findData(
        next(a.path for a in card.apps if a.name == app)))
    if lane:
        card.set_lane(lane)
    _settle()


# ── where the card lives, and when it first looks ────────────────────────────────
def test_the_card_sits_in_the_bottom_panel_not_on_the_bringup_page(wiz, src_tree):
    ctl, card, prober, _l = _to_bringup(wiz, source_dir=src_tree)
    dock = wiz.local_ai_dock
    assert isinstance(card, law.LocalAgentWidget)
    assert isinstance(wiz.currentPage(), lm.LocalMeshPage)
    assert not ctl.isAncestorOf(card), "the card is back in the build phase"
    assert dock.isAncestorOf(card) and card.isVisible()
    assert card.title() == law.TITLE
    assert prober.calls == 1
    # the ONE card: the panel's, nowhere else in the window
    assert wiz.findChildren(law.LocalAgentWidget) == [card]
    assert not hasattr(ctl, "local_agent")
    # the Actions box that holds BOTH lanes' buttons moved into the same panel
    assert dock.isAncestorOf(ctl.boot_start_btn) and dock.isAncestorOf(ctl.devops_up_btn)


def test_the_build_phase_hosts_no_card(qapp):
    """The operator's ask: the card leaves the build phase. The single-page frame (which
    has no panel) builds the whole Bring-up surface and must not bring the card back."""
    dlg = lm.LocalMeshDialog(GENERATOR_DIR)
    try:
        assert dlg.findChildren(law.LocalAgentWidget) == []
        assert not hasattr(dlg.page, "local_agent")
        assert "LocalAgentWidget" not in inspect.getsource(lm)
    finally:
        dlg.close()
        dlg.deleteLater()


def test_building_the_page_reads_nothing_from_the_machine(qapp):
    """The probe is kicked by the card's first SHOW. Constructing the page (and so the
    card) must not touch Ollama, the PATH or the network."""
    calls = []
    card = law.LocalAgentWidget(GENERATOR_DIR, prober=lambda: calls.append(1) or probe_of())
    assert calls == [] and card.probe is None
    assert not card.start_btn.isEnabled()
    assert card.start_btn.toolTip() == "Still checking this machine."
    card.deleteLater()


def test_the_first_look_runs_off_the_gui_thread(wiz, src_tree):
    _ctl, _card, prober, _l = _to_bringup(wiz, source_dir=src_tree)
    assert prober.threads and all(t is not threading.main_thread() for t in prober.threads)


def test_nothing_starts_without_a_press_even_when_everything_is_ready(wiz, src_tree):
    _ctl, card, _p, launch = _to_bringup(wiz, source_dir=src_tree)
    assert card.start_btn.isEnabled()
    card.recheck()
    card.wait_idle()
    _settle(5)
    assert launch.plans == [] and card.last_outcome is None


# ── ready, per lane ──────────────────────────────────────────────────────────────
def test_a_ready_card_names_what_will_run(wiz, src_tree):
    _ctl, card, _p, _l = _to_bringup(wiz, source_dir=src_tree)
    assert card.problems() == []
    assert card.start_btn.isEnabled()
    assert card.status.text().startswith("Ready: Claude Code on qwen3:8b")
    assert "00b" not in card.status.styleSheet() and "#2e7d32" in card.status.styleSheet()
    assert card.agent_box.currentData() == "claude" and card.model_box.currentData() == "qwen3:8b"
    assert {a.name for a in card.apps} >= {APP, "hugmesh-admin-ui", "hugmesh-gateway"}


@pytest.mark.parametrize("lane,word", [(la.LANE_DOCKER, "Lane: Docker"),
                                       (la.LANE_KIND, "Lane: kind")])
def test_a_press_hands_the_launcher_the_right_command_folder_environment_and_brief(
        wiz, src_tree, monkeypatch, lane, word):
    monkeypatch.setenv("GH_TOKEN", SECRET)
    monkeypatch.setenv("SSH_AUTH_SOCK", SECRET)
    ctl, card, _p, launch = _to_bringup(wiz, source_dir=src_tree)
    _pick(card, APP, lane)
    card.start_btn.click()
    assert card.wait_idle()
    _settle()
    (plan,) = launch.plans
    assert plan.argv == ("ollama", "launch", "claude", "--model", "qwen3:8b")
    assert not [a for a in plan.argv if a in la.FORBIDDEN_FLAGS]
    # the folder: a copy under the Studio's state, never the source, never .stack-src
    state = os.environ["HUGMESH_STUDIO_STATE_DIR"]
    assert plan.cwd.startswith(os.path.join(state, "agent-work") + os.sep)
    assert plan.cwd != os.path.join(src_tree, APP) and ".stack-src" not in plan.cwd
    assert git("remote", cwd=plan.cwd) == ""
    assert git("branch", "--show-current", cwd=plan.cwd).startswith("lm/")
    assert os.path.isfile(os.path.join(plan.cwd, "README.md"))
    # the environment: the allowlist only
    assert "GH_TOKEN" not in plan.env and "SSH_AUTH_SOCK" not in plan.env
    assert SECRET not in "".join(plan.env.values())
    assert SECRET not in plan.shell_command and "env -i " in plan.shell_command
    # the brief, written beside the copy and carrying this mesh's real values
    assert os.path.isfile(plan.scratch.brief_path)
    assert not plan.scratch.brief_path.startswith(plan.cwd + os.sep)
    brief = open(plan.scratch.brief_path, encoding="utf-8").read()
    assert word in brief and ctl.mesh_domains.own_name in brief
    assert f"repository {APP}" in brief and "Never run: git push, sudo" in brief
    if lane == la.LANE_KIND:
        assert f"make kind-images ONLY={APP}" in brief
    else:
        assert "no single-service rebuild target" in brief
    # the work ran off the GUI thread, and the outcome is shown inline
    assert all(t is not threading.main_thread() for t in launch.threads)
    assert card.note.isVisible() and "#2e7d32" in card.note.styleSheet()
    assert "konsole" in card.note.text() and plan.title in card.note.text()
    assert card.command_box.isVisible() and "env -i" in card.command_box.toPlainText()


def test_every_start_writes_the_project_context_fresh_and_the_brief_points_at_it(
        wiz, src_tree):
    """The operator's rule: every agent the assistant starts is told what HugMesh is and
    where the local sources are — written fresh at each start, beside the brief."""
    ctl, card, _p, launch = _to_bringup(wiz, source_dir=src_tree)
    _pick(card, APP)
    card.start_btn.click()
    assert card.wait_idle()
    _settle()
    (plan,) = launch.plans
    assert plan.context_path and os.path.isfile(plan.context_path)
    text = open(plan.context_path, encoding="utf-8").read()
    assert "## Where the local sources are" in text
    assert f"The folder this mesh builds from: `{src_tree}`" in text
    assert os.path.join(src_tree, APP) in text, "the domain's code folders are missing"
    assert f"Domain `{ctl.mesh_domains.own_name}`" in text or ctl.mesh_domains.own_name in text
    brief = open(plan.scratch.brief_path, encoding="utf-8").read()
    assert f"Read {plan.context_path} first" in brief
    # fresh: a second start rewrites it (an old file is never left to describe the mesh)
    with open(plan.context_path, "w", encoding="utf-8") as fh:
        fh.write("stale")
    card.start_btn.click()
    assert card.wait_idle()
    _settle()
    assert open(plan.context_path, encoding="utf-8").read() != "stale"


def _run_verb(ctl, label):
    """What the page does around a verb, minus the verb: it records one run with the
    label the person saw and emits completeChanged at the start and the end."""
    ctl._runs.append(lm._StageRun(label, []))
    ctl.completeChanged.emit()
    _settle()


def test_the_lane_follows_the_verb_the_page_last_ran(wiz, src_tree):
    """A person who just pressed Start DevOps lane must not be handed the Docker
    brief: the Lane drop-down follows the page's most recent lane verb, a hand pick
    stays until the page's lane changes, and the brief says the lane in use."""
    ctl, card, _p, launch = _to_bringup(wiz, source_dir=src_tree)
    assert card.lane_box.currentData() == la.LANE_DOCKER          # nothing ran yet
    _run_verb(ctl, "Starting the DevOps lane")
    assert card.lane_box.currentData() == la.LANE_KIND
    _pick(card, APP)
    card.start_btn.click()
    assert card.wait_idle()
    _settle()
    (plan,) = launch.plans
    assert plan.lane == la.LANE_KIND
    assert "Lane: kind" in open(plan.scratch.brief_path, encoding="utf-8").read()
    _run_verb(ctl, "Bootstrapping")                                 # the Docker lane
    assert card.lane_box.currentData() == la.LANE_DOCKER
    card.set_lane(la.LANE_KIND)                                     # a hand pick ...
    _run_verb(ctl, "Saving mesh")                                   # ... not a lane verb
    card.recheck()
    card.wait_idle()
    _settle()
    assert card.lane_box.currentData() == la.LANE_KIND, "a hand pick survives a re-check"
    _run_verb(ctl, "Halting the DevOps lane")
    _run_verb(ctl, "Stopping the stack")
    assert card.lane_box.currentData() == la.LANE_DOCKER
    card.set_lane(la.LANE_KIND)                                     # a hand pick ...
    _run_verb(ctl, "Stopping and cleaning Docker")                  # ... then a NEW verb
    assert card.lane_box.currentData() == la.LANE_DOCKER, "every new lane verb is followed"


def test_the_lane_words_match_every_verb_label_of_the_page():
    """The words the card reads a lane from are pinned to the page's own ``_launch``
    labels, read from its source: every devops-* verb classifies as kind, the Docker
    lane's verbs as Docker, and a readiness check, a save or a browser door as neither."""
    src = open(lm.__file__, encoding="utf-8").read()
    labels = {}
    for node in ast.walk(ast.parse(src)):
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and node.func.attr == "_launch" and node.args
                and isinstance(node.args[0], ast.Constant)):
            continue
        verb = next((k.value.value for k in node.keywords
                     if k.arg == "verb" and isinstance(k.value, ast.Constant)), "")
        labels[node.args[0].value] = verb
    assert len(labels) >= 12, labels
    assert any(v.startswith("devops") for v in labels.values())
    for label, verb in labels.items():
        got = law.lane_from_page(SimpleNamespace(_runs=[SimpleNamespace(label=label)]))
        if verb.startswith("devops"):
            assert got == la.LANE_KIND, (label, verb)
        elif verb in ("up", "clean") or "mesh node" in label or "the stack" in label:
            assert got == la.LANE_DOCKER, (label, verb)
        else:
            assert got == "", (label, verb)
    assert law.lane_from_page(SimpleNamespace(_runs=[])) == ""
    assert law.lane_from_page(SimpleNamespace()) == ""              # a half-built page
    # the most recent lane verb decides, whatever came after it
    page = SimpleNamespace(_runs=[SimpleNamespace(label=l) for l in
                                  ("Bootstrapping", "Starting the DevOps lane", "Saving mesh")])
    assert law.lane_from_page(page) == la.LANE_KIND


def _window_shot(window, name):
    if not SHOTS:
        return
    os.makedirs(SHOTS, exist_ok=True)
    _settle(3)
    window.grab().save(os.path.join(SHOTS, f"local-agent-{name}.png"))


@pytest.fixture
def frame(qapp, src_tree):
    """The single-page frame (LocalMeshDialog) on the own tree, with the fakes installed
    before the card's first show. No QWizard around it: nothing but the page's own
    signals can reach the card, which is what the hook tests need."""
    dlg = lm.LocalMeshDialog(GENERATOR_DIR)
    page = dlg.page
    # The card as the panel builds it, wired to this page by the same one function.
    card = law.LocalAgentWidget(GENERATOR_DIR, context=lambda: law.context_from_page(page))
    law.follow_page(card, page)
    card.set_prober(Prober(probe_of()))
    launch = Launcher()
    card.set_launcher(launch)
    dlg.resize(*SMALLEST)
    dlg.show()
    card.resize(*SMALLEST)
    card.show()
    page.src_existing.setChecked(True)
    page.src_dir.setText(src_tree)
    assert card.wait_idle()
    _settle(3)
    yield dlg, page, card, launch
    card.close()
    card.deleteLater()
    dlg.close()
    dlg.deleteLater()


def test_the_lane_follows_the_page_in_the_single_page_frame_too(frame, src_tree):
    """The stepped wizard happens to re-show the card when a verb starts (QWizard's own
    reaction to completeChanged), which hides a missing hook; the frame does not, so
    this is the test that fails when the page stops telling the card a verb ran."""
    _dlg, page, card, launch = frame
    assert card.lane_box.currentData() == la.LANE_DOCKER
    _run_verb(page, "Starting the DevOps lane")
    assert card.lane_box.currentData() == la.LANE_KIND
    _pick(card, APP)
    card.start_btn.click()
    assert card.wait_idle()
    _settle()
    (plan,) = launch.plans
    assert plan.lane == la.LANE_KIND
    assert "Lane: kind" in open(plan.scratch.brief_path, encoding="utf-8").read()
    _run_verb(page, "Stopping the stack")
    assert card.lane_box.currentData() == la.LANE_DOCKER
    card.set_lane(la.LANE_KIND)
    _run_verb(page, "Saving mesh")
    assert card.lane_box.currentData() == la.LANE_KIND, "a hand pick survives a save"
    _run_verb(page, "Stopping and cleaning Docker")
    assert card.lane_box.currentData() == la.LANE_DOCKER, "every new lane verb is followed"


@pytest.mark.parametrize("size", [SMALLEST, NORMAL], ids=["736x736", "1040x706"])
def test_the_card_and_the_code_folders_block_never_overlap(wiz, src_tree, size):
    """#689's Code folders block is on the Repo source step; the card is in the bottom
    panel, which is on every step. With both on screen, each is drawn whole, the block
    above the panel, and neither covers the other."""
    ctl, card, _p, _l = _to_bringup(wiz, source_dir=src_tree, size=size)
    block = ctl.code_folders
    for _ in range(16):
        if isinstance(wiz.currentPage(), lm.LocalMeshSourcePage):
            break
        wiz.back()
    assert isinstance(wiz.currentPage(), lm.LocalMeshSourcePage)
    wiz.local_ai_dock.show_tab("assistant")
    _settle(3)
    assert {a.name for a in card.apps} >= {APP, "hugmesh-admin-ui"}
    assert card.selection()[1].path.startswith(src_tree + os.sep)
    assert card.start_btn.isEnabled(), card.status.text()
    assert card.isVisible() and block.isVisible()
    # what is ON SCREEN of each: the panel's options viewport, and the part of the block
    # inside the step's own scroll viewport (the block is taller than the step)
    _scroll_of(block).ensureWidgetVisible(block, 0, 0)
    _settle(3)
    cr = _rect_in(_scroll_of(card).viewport(), wiz)
    br = _rect_in(block, wiz).intersected(_rect_in(_scroll_of(block).viewport(), wiz))
    assert not cr.isEmpty() and br.height() >= 60, (cr, br)
    assert wiz.rect().contains(cr) and wiz.rect().contains(br), (cr, br)
    assert not cr.intersects(br), (cr, br)
    assert br.bottom() < cr.top(), "the Repo source block sits above the panel"
    assert card.width() >= 400 and block.width() >= 400, (card.width(), block.width())
    _window_shot(wiz, f"wizard-repo-source-and-panel-{size[0]}x{size[1]}")
    _assert_geometry(card, None, "source-step", size)


def test_the_card_is_in_the_panel_on_every_step(wiz, src_tree):
    ctl, card, _p, _l = _to_bringup(wiz, source_dir=src_tree, size=SMALLEST)
    block = ctl.code_folders
    assert isinstance(wiz.currentPage(), lm.LocalMeshPage) and card.isVisible()
    assert not block.isVisible() and not ctl.isAncestorOf(block)
    _scroll_of(card).ensureWidgetVisible(card, 0, 0)
    _window_shot(wiz, "wizard-bringup-736x736")
    for _ in range(16):
        if isinstance(wiz.currentPage(), lm.LocalMeshSourcePage):
            break
        wiz.back()
    page = wiz.currentPage()
    assert isinstance(page, lm.LocalMeshSourcePage)
    _settle(3)
    assert page.isAncestorOf(block) and block.isVisible()
    assert card.isVisible() and not page.isAncestorOf(card)
    _window_shot(wiz, "wizard-repo-source-736x736")


def test_the_selected_app_is_the_one_copied(wiz, src_tree):
    _ctl, card, _p, launch = _to_bringup(wiz, source_dir=src_tree)
    _pick(card, "hugmesh-admin-ui")
    card.start_btn.click()
    card.wait_idle()
    (plan,) = launch.plans
    assert plan.scratch.source.path == os.path.join(src_tree, "hugmesh-admin-ui")
    assert os.path.basename(plan.cwd) == "hugmesh-admin-ui"


def test_the_card_opens_on_an_app_that_exists_not_the_first_one_listed(wiz, src_tree,
                                                                       monkeypatch):
    """The #689 map lists every platform app, downloaded or not, in name order."""
    real = law.list_apps

    def with_a_missing_one_first(generator_dir, ctx):
        apps, note = real(generator_dir, ctx)
        ghost = law.AppChoice("hugmesh-aaa-not-downloaded", "/nowhere/hugmesh-aaa", False,
                              "not downloaded yet")
        return [ghost] + apps, note
    monkeypatch.setattr(law, "list_apps", with_a_missing_one_first)
    _ctl, card, _p, _l = _to_bringup(wiz, source_dir=src_tree)
    assert card.apps[0].name == "hugmesh-aaa-not-downloaded"
    assert card.selection()[1].exists and card.start_btn.isEnabled()
    assert card.app_box.itemText(0).endswith("(not downloaded)")


def test_a_second_press_reuses_the_untouched_copy_and_never_deletes_one(wiz, src_tree):
    _ctl, card, _p, launch = _to_bringup(wiz, source_dir=src_tree)
    card.start_btn.click()
    card.wait_idle()
    first = launch.plans[-1].cwd
    card.start_btn.click()
    card.wait_idle()
    assert launch.plans[-1].cwd == first and "the one from before" in card.note.text()
    open(os.path.join(first, "mine.txt"), "w").write("work")
    card.start_btn.click()
    card.wait_idle()
    assert launch.plans[-1].cwd == first + "-2"
    assert os.path.exists(os.path.join(first, "mine.txt"))


def test_uncommitted_edits_in_the_real_folder_are_called_out(wiz, src_tree):
    open(os.path.join(src_tree, APP, "README.md"), "a").write("edit\n")
    _ctl, card, _p, _l = _to_bringup(wiz, source_dir=src_tree)
    _pick(card, APP)
    card.start_btn.click()
    card.wait_idle()
    assert "1 uncommitted change(s)" in card.note.text()


# ── every missing prerequisite ───────────────────────────────────────────────────
@pytest.mark.parametrize("probe,first,words", [
    (probe_of(ollama=False), "ollama_missing", ("not installed", "docs section 2")),
    (probe_of(up=False), "server_down", ("not answering on 127.0.0.1:11434",
                                         "connection refused", "ollama serve")),
    (probe_of(models=()), "no_models", ("no model is pulled", "ollama pull qwen3:8b")),
    (probe_of(models=("plain:1",), tools=False), "no_tools_model",
     ("tools capability", "plain:1")),
    (probe_of(agents=()), "agent_missing", ("`claude` command is not installed",
                                            "ollama launch claude")),
])
def test_each_missing_prerequisite_is_named_and_blocks_start(wiz, src_tree, probe, first,
                                                             words):
    _ctl, card, _p, launch = _to_bringup(wiz, probe=probe, source_dir=src_tree)
    probs = card.problems()
    assert probs and probs[0].code == first
    text = card.status.text()
    for w in words:
        assert w in text, (w, text)
    assert "#b00020" in card.status.styleSheet()
    assert not card.start_btn.isEnabled()
    assert card.start_btn.toolTip() == probs[0].what
    assert card.docs.isVisible() and "docs/LOCAL-AI-ASSISTANT.md#" in card.docs.text()
    # the second guard: forced past the disabled button, the handler still starts nothing
    card.start_btn.click()
    card._start()
    card.wait_idle()
    assert launch.plans == [] and card.last_outcome is None


def test_everything_missing_names_the_first_and_lists_the_rest(wiz, src_tree):
    _ctl, card, _p, _l = _to_bringup(
        wiz, probe=probe_of(ollama=False, up=False, agents=()), source_dir=src_tree)
    assert [p.code for p in card.problems()] == ["ollama_missing", "server_down", "agent_missing"]
    assert card.status.text().startswith("Ollama is not installed")
    assert card.more.isVisible() and "not answering" in card.more.text() \
        and "`claude` command" in card.more.text()


def test_a_folder_that_is_not_a_repository_blocks_start_with_its_reason(wiz, src_tree):
    _ctl, card, _p, launch = _to_bringup(wiz, source_dir=src_tree)
    _pick(card, "hugmesh-gateway")
    assert not card.start_btn.isEnabled()
    assert "not a git repository" in card.status.text()
    assert card.start_btn.toolTip().endswith("copied for an agent.")
    card._start()
    card.wait_idle()
    assert launch.plans == []


def test_a_source_that_has_not_been_downloaded_says_so(wiz, tmp_path):
    empty = tmp_path / "nothing-here"
    empty.mkdir()
    _ctl, card, _p, _l = _to_bringup(wiz, source_dir=str(empty))
    assert not card.start_btn.isEnabled()
    assert card.problems()[0].code == "source"
    assert not card.app_box.isEnabled() or all(not a.exists for a in card.apps)


def test_a_repository_the_real_check_refuses_is_reported_at_the_press(wiz, src_tree):
    """The cheap check only sees a .git entry; git itself says there is no commit."""
    bare = os.path.join(src_tree, "hugmesh-gateway")
    git("init", "-q", cwd=bare)
    _ctl, card, _p, launch = _to_bringup(wiz, source_dir=src_tree)
    _pick(card, "hugmesh-gateway")
    assert card.start_btn.isEnabled()
    card.start_btn.click()
    card.wait_idle()
    assert launch.plans == []
    assert "no commits" in card.note.text() and "#b00020" in card.note.styleSheet()
    assert not card.command_box.isVisible()


def test_a_model_that_cannot_use_tools_blocks_start(wiz, src_tree):
    probe = la.Probe("/usr/bin/ollama", server_up=True, agents={"claude": "/usr/bin/claude"},
                     models=(la.ModelInfo("qwen3:8b", True), la.ModelInfo("plain:1", False)))
    _ctl, card, _p, _l = _to_bringup(wiz, probe=probe, source_dir=src_tree)
    assert card.start_btn.isEnabled()
    card.model_box.setCurrentIndex(card.model_box.findData("plain:1"))
    _settle()
    assert card.problems()[0].code == "model_no_tools"
    assert not card.start_btn.isEnabled()
    assert "(no tools)" in card.model_box.itemText(card.model_box.findData("plain:1"))


def test_recheck_picks_up_a_fix(wiz, src_tree):
    _ctl, card, prober, _l = _to_bringup(wiz, probe=probe_of(up=False), source_dir=src_tree)
    assert not card.start_btn.isEnabled()
    prober.probe = probe_of()
    card.recheck_btn.click()
    card.wait_idle()
    _settle()
    assert prober.calls == 2 and card.start_btn.isEnabled()
    assert card.status.text().startswith("Ready")


def test_an_agent_that_is_not_installed_is_marked_in_the_list(wiz, src_tree):
    _ctl, card, _p, _l = _to_bringup(wiz, probe=probe_of(agents=("claude",)),
                                      source_dir=src_tree)
    texts = {card.agent_box.itemData(i): card.agent_box.itemText(i)
             for i in range(card.agent_box.count())}
    assert "not installed" not in texts["claude"]
    assert texts["opencode"].endswith("not installed")


# ── a launch nothing took ────────────────────────────────────────────────────────
def test_when_no_terminal_takes_the_request_the_exact_lines_are_shown(
        wiz, src_tree, tmp_path, monkeypatch):
    """The REAL launch with no terminal installed, so the text in the box is the text
    the product produces, and then that text is RUN in bash against the copy that was
    just made: it has to exit 0 and print no git failure, and start the agent."""
    bindir = tmp_path / "bin"
    bindir.mkdir()
    seen = tmp_path / "agent-ran.txt"
    (bindir / "ollama").write_text(f'#!/bin/sh\necho "$PWD $*" > {seen}\n')
    (bindir / "ollama").chmod(0o755)
    monkeypatch.setenv("PATH", f"{bindir}:{os.environ.get('PATH', '/usr/bin:/bin')}")
    plans = []

    def no_terminal(plan):
        plans.append(plan)
        host = la.Host("linux", which=lambda _c: None, environ={"DISPLAY": ":0"})
        return la.launch(plan, host)

    _ctl, card, _p, _l = _to_bringup(wiz, launcher=no_terminal, source_dir=src_tree)
    card.start_btn.click()
    card.wait_idle()
    _settle()
    (plan,) = plans
    assert "#b00020" in card.note.styleSheet()
    assert "No window was opened: no terminal emulator was found" in card.note.text()
    assert card.command_box.isVisible()
    shown = card.command_box.toPlainText()
    assert shown.rstrip("\n") == plan.after_copy_text.rstrip("\n")
    assert "git clone" not in shown and "git remote remove" not in shown
    assert os.path.isdir(plan.cwd), "the copy exists even though no window opened"
    proc = subprocess.run(["bash", "--noprofile", "--norc", "-c", shown],
                          capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, proc.stderr
    assert proc.stderr == "", proc.stderr
    ran = seen.read_text().split()
    assert os.path.realpath(ran[0]) == os.path.realpath(plan.cwd)
    assert ran[1:5] == ["launch", "claude", "--model", "qwen3:8b"]


def test_the_copy_button_shows_the_long_form_that_makes_the_copy(wiz, src_tree):
    """Copy command runs BEFORE any copy exists, so it keeps the clone / no-remote /
    branch lines; only the text shown after a Start drops them."""
    _ctl, card, _p, _l = _to_bringup(wiz, source_dir=src_tree)
    card.copy_btn.click()
    card.wait_idle()
    _settle()
    shown = card.command_box.toPlainText()
    assert shown.startswith("git clone --no-hardlinks -- ")
    assert "git remote remove origin" in shown and "git switch -c lm/" in shown
    assert card.copied_text == shown


def test_a_new_app_list_updates_the_status_without_a_recheck(wiz, src_tree):
    """The app list is re-read when the source choice changes (the e2e driver does this
    after the first look at the machine has already finished). The status and Start
    must follow it: a list that arrives after the look finished once left the card
    saying "No app folder is known yet" beside a chosen app."""
    ctl, card, _p, _l = _to_bringup(wiz)              # no source chosen yet
    card.wait_idle()
    _settle()
    ctl.src_existing.setChecked(True)
    ctl.src_dir.setText(src_tree)
    card.refresh_apps()
    _settle()
    assert card.app_box.currentText() in (APP, "hugmesh-admin-ui")   # first real repository
    assert "No app folder" not in card.status.text(), card.status.text()
    assert card.start_btn.isEnabled(), card.status.text()


def test_the_workers_never_read_a_widget_or_the_page(wiz, src_tree):
    """Qt widgets are GUI-thread only (a thread mistake aborts the Studio). The page's
    context callable, the selection and the app list are all read at the press, on the
    GUI thread, and the worker is handed the values."""
    ctl, card, _p, launch = _to_bringup(wiz, source_dir=src_tree)
    main = threading.main_thread()
    reads = []
    real_ctx, real_sel = card._context, card.selection

    def ctx():
        reads.append(("context", threading.current_thread()))
        return real_ctx()

    def sel():
        reads.append(("selection", threading.current_thread()))
        return real_sel()

    card._context = ctx
    card.selection = sel
    for button in (card.start_btn, card.copy_btn):
        reads.clear()
        button.click()
        card.wait_idle()
        _settle()
        assert {n for n, _t in reads} >= {"context", "selection"}, reads
        off = [(n, t.name) for n, t in reads if t is not main]
        assert not off, f"the worker read the page: {off}"
    assert launch.plans and launch.threads[0] is not main      # the launch itself is off-thread


def test_a_launcher_that_raises_is_shown_not_thrown_into_qt(wiz, src_tree):
    def boom(plan):
        raise RuntimeError("terminal exploded")
    _ctl, card, _p, _l = _to_bringup(wiz, launcher=boom, source_dir=src_tree)
    card.start_btn.click()
    card.wait_idle()
    assert "Unexpected RuntimeError: terminal exploded" in card.note.text()
    assert card.start_btn.isEnabled()


# ── copy ─────────────────────────────────────────────────────────────────────────
def test_copy_is_always_available_and_copies_the_lines_when_ready(wiz, src_tree):
    _ctl, card, _p, launch = _to_bringup(wiz, source_dir=src_tree)
    assert card.copy_btn.isEnabled()
    card.copy_btn.click()
    card.wait_idle()
    _settle()
    assert launch.plans == [], "Copy must not start anything"
    assert card.copied_text.startswith("git clone --no-hardlinks -- ")
    assert "git remote remove origin" in card.copied_text and "env -i " in card.copied_text
    assert os.path.isfile(card.copied_text.split("$(cat ")[1].split(")")[0])    # the brief
    assert "Copied the lines" in card.note.text()


def test_copy_still_works_when_nothing_can_start_and_says_what_to_fix(wiz, src_tree):
    _ctl, card, _p, _l = _to_bringup(wiz, probe=probe_of(ollama=False), source_dir=src_tree)
    assert card.copy_btn.isEnabled() and not card.start_btn.isEnabled()
    card.copy_btn.click()
    card.wait_idle()
    assert "Ollama is not installed" in card.copied_text
    assert "what was copied is what to fix first" in card.note.text()


# ── no modal, no move ────────────────────────────────────────────────────────────
def test_no_modal_and_no_window_move_anywhere_in_the_card():
    src = inspect.getsource(law)
    core = inspect.getsource(la)
    for text in (src, core):
        for banned in ("QMessageBox", ".exec(", "QFileDialog", "QInputDialog", ".move(",
                       "exec_("):
            assert banned not in text, banned
    # the card's new host: the panel opens no modal and moves no window either
    panel = inspect.getsource(dock_mod)
    for banned in ("QMessageBox", ".exec(", "QFileDialog", "QInputDialog", ".move("):
        assert banned not in panel, banned


# ── geometry: a control nobody can see is not delivered ──────────────────────────
def _rect_in(widget, ancestor):
    return QtCore.QRect(widget.mapTo(ancestor, QtCore.QPoint(0, 0)), widget.size())


def _controls(card):
    out = [("start", card.start_btn), ("copy", card.copy_btn), ("recheck", card.recheck_btn)]
    out += [("lane", card.lane_box), ("app", card.app_box), ("agent", card.agent_box),
            ("model", card.model_box)]
    return out


def _scroll_of(card):
    """The scroll area the card is drawn in (the panel's options column)."""
    w = card.parentWidget()
    while w is not None and not isinstance(w, QtWidgets.QScrollArea):
        w = w.parentWidget()
    assert w is not None, "the card is not inside a scroll area"
    return w


def _assert_geometry(card, ctl, state, size):  # noqa: ARG001 — ctl kept for the call sites
    scroll = _scroll_of(card)
    viewport = scroll.viewport()
    assert scroll.horizontalScrollBar().maximum() == 0, \
        "content wider than the viewport is cut off: no horizontal scrollbar exists"
    assert scroll.widget().width() <= viewport.width()
    assert card.width() <= viewport.width() and card.width() >= 400, (card.width(), size)
    rects = []
    for key, w in _controls(card):
        assert w.isVisible(), (state, key)
        r = _rect_in(w, card)
        assert card.rect().contains(r), (state, key, r, card.rect())
        assert r.height() >= 20, (state, key, r.height())
        if isinstance(w, QtWidgets.QPushButton):
            text_w = w.fontMetrics().horizontalAdvance(w.text())
            assert r.width() >= text_w + 8, (state, key, "label clipped", r.width(), text_w)
        else:
            assert r.width() >= 100, (state, key, r.width())
        for other_key, other in rects:
            assert not r.intersects(other), (state, key, other_key, r, other)
        rects.append((key, r))
        # DRAWN: scroll it into view and ask Qt what is actually visible of it
        scroll.ensureWidgetVisible(w, 0, 0)
        _settle(2)
        vis = w.visibleRegion().boundingRect()
        assert vis.width() >= r.width() - 1 and vis.height() >= r.height() - 1, \
            (state, key, "not fully drawn", vis, r)
    for name in ("status", "more", "docs", "note"):
        lab = getattr(card, name)
        if not lab.isVisible():
            continue
        lr = _rect_in(lab, card)
        assert card.rect().contains(lr), (state, name, lr)
        assert lab.height() >= lab.heightForWidth(lab.width()) - 2, \
            (state, name, "wrapped text clipped", lab.height(), lab.heightForWidth(lab.width()))
    fr = _rect_in(card.folder_label, card)
    assert card.rect().contains(fr)
    assert card.folder_label.minimumSizeHint().width() < 120, "a long path must elide"
    if card.command_box.isVisible():
        cr = _rect_in(card.command_box, card)
        assert card.rect().contains(cr) and cr.height() >= 40
        assert card.command_box.horizontalScrollBar().maximum() >= 0
    return rects


def _shot(card, ctl, name):
    if not SHOTS:
        return
    os.makedirs(SHOTS, exist_ok=True)
    _scroll_of(card).ensureWidgetVisible(card, 0, 0)
    _settle(3)
    card.grab().save(os.path.join(SHOTS, f"local-agent-{name}.png"))


STATES = ["ready", "ollama-missing", "server-down", "no-tools-model", "no-agent",
          "launch-failed", "launched", "everything-missing", "not-a-repo"]


def _into_state(card, state, launcher):
    if state in ("ready", "launched", "launch-failed"):
        return
    probe = {"ollama-missing": probe_of(ollama=False), "server-down": probe_of(up=False),
             "no-tools-model": probe_of(models=("plain:1",), tools=False),
             "no-agent": probe_of(agents=()),
             "everything-missing": probe_of(ollama=False, up=False, agents=())}.get(state)
    if probe is not None:
        card.set_prober(Prober(probe))
        card.recheck()
        card.wait_idle()
    if state == "not-a-repo":
        _pick(card, "hugmesh-gateway")
    _settle()


@pytest.mark.parametrize("size", [SMALLEST, NORMAL], ids=["736x736", "1040x706"])
@pytest.mark.parametrize("state", STATES)
def test_every_state_is_drawn_whole_at_the_window_sizes(wiz, tmp_path, state, size):
    # a deep path and a long mesh name: neither may push a control out of the card
    deep = tmp_path
    for i in range(6):
        deep = deep / f"a-rather-long-directory-name-{i}"
    deep = deep / "source-tree"
    for name in (APP, "hugmesh-gateway"):
        d = deep / name
        d.mkdir(parents=True)
        git("init", "-q", "-b", "main", cwd=d)
        (d / "f").write_text("x")
        git("add", "f", cwd=d)
        git("commit", "-q", "-m", "m", cwd=d)
    if state == "not-a-repo":
        (deep / "hugmesh-gateway" / ".git").rename(deep / "hugmesh-gateway" / "git-removed")
    launcher = Launcher(opened=(state != "launch-failed"),
                        reason="no terminal took the request (konsole exited 2; xterm "
                               "exited 3; this reason is long on purpose, to wrap)")
    ctl, card, _p, _l = _to_bringup(wiz, launcher=launcher, source_dir=str(deep), size=size)
    assert wiz.size() == QtCore.QSize(*size)
    _into_state(card, state, launcher)
    if state in ("launched", "launch-failed"):
        card.start_btn.click()
        card.wait_idle()
        _settle()
        assert card.command_box.isVisible()
        assert len(card.command_box.toPlainText().splitlines()[-1]) > 300, \
            "the command line is long; it must scroll, not widen the card"
    _scroll_of(card).ensureWidgetVisible(card, 0, 0)
    _settle(3)
    _assert_geometry(card, ctl, state, size)
    _shot(card, ctl, f"{state}-{size[0]}x{size[1]}")


def test_geometry_holds_at_a_small_font_too(wiz, src_tree, qapp):
    """#647's second finding: a column sized for 9 pt clipped again at 8 pt."""
    saved = qapp.font()
    small = QtGui.QFont(saved)
    small.setPointSize(8)
    qapp.setFont(small)
    try:
        ctl, card, _p, _l = _to_bringup(wiz, source_dir=src_tree, size=SMALLEST)
        _scroll_of(card).ensureWidgetVisible(card, 0, 0)
        _settle(3)
        _assert_geometry(card, ctl, "ready-8pt", SMALLEST)
    finally:
        qapp.setFont(saved)

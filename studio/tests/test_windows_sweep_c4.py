"""Windows sweep (#827), cluster c4 — the local-cloud gate, the QEMU chain note, the
tray, the Studio panel, the e2e source editor, the LocalMesh status line and the two
terminal screens (Local AI, Go-Live).

The contract on native Windows (the MSI) is: a function WORKS, or REFUSES with a true
sentence saying why and what to do. Each test below pins one way that contract was
broken; the Linux behaviour of the same code is pinned beside it where it could drift.
Gates take an ``osname`` (or read the wizard's pinned host) so both sides run on any
CI; tests that drive code with no such seam are ``skipif(os.name != "nt")``.
"""
import inspect
import os
import threading
import time
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import e2e_catalogue as ec                    # noqa: E402
from hugmesh_studio.core import local_ai_status as lai                 # noqa: E402
from hugmesh_studio.core import ollama_docker as odk                   # noqa: E402
from hugmesh_studio.core import platform_info, qemu_tests              # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                 # noqa: E402
from hugmesh_studio.gui import build_supervisor                        # noqa: E402
from hugmesh_studio.gui import tray as tray_mod                        # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                    # noqa: E402
from hugmesh_studio.gui.pages import localcloud_nodes as lc_mod        # noqa: E402
from hugmesh_studio.gui.pages import localmesh as lm_mod               # noqa: E402
from hugmesh_studio.gui.pages import qemu as qemu_page                 # noqa: E402
from hugmesh_studio.gui.pages.e2e_tree_dialog import (                 # noqa: E402
    E2ETreeDialog, read_source, write_source)
from hugmesh_studio.gui.qt import QtCore, QtWidgets                    # noqa: E402
from hugmesh_studio.tui import golive as tui_golive                    # noqa: E402
from hugmesh_studio.tui import local_ai as tui_lai                     # noqa: E402

from _helpers import advance_to, pick_mode                             # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

WINDOWS_ONLY = pytest.mark.skipif(os.name != "nt", reason="native Windows behaviour")
POSIX_ONLY = pytest.mark.skipif(os.name == "nt", reason="the Linux side of a Windows gate")

#: The real teardown, kept before the autouse fixture below stubs it.
_REAL_TEARDOWN = lc_mod.local_k8s_teardown


def _host(os_name: str) -> HostInfo:
    return HostInfo(os=os_name, is_gentoo=False, has_docker=False, has_bash=True,
                    has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture(autouse=True)
def _isolated_state(tmp_path, monkeypatch):
    # the saved Ollama choice, tips and the like are read from here, never from ~
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def _wait_until(qapp, pred, timeout_s: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout_s
    while not pred() and time.monotonic() < deadline:
        qapp.processEvents()
        time.sleep(0.01)
    qapp.processEvents()
    return bool(pred())


# ── local cloud nodes: the k8s gate ─────────────────────────────────────────────────
@pytest.fixture
def k8s_up(monkeypatch):
    """A cluster is detected (a native kind.exe can see one made from WSL2 on the shared
    Docker Desktop engine); a teardown the page should never reach fails the test."""
    calls = []

    def _never(_gd, on_line=None, cancel=None):
        calls.append(_gd)
        raise AssertionError("local_k8s_teardown reached")

    monkeypatch.setattr(lc_mod, "local_k8s_running", lambda _gd: True)
    monkeypatch.setattr(lc_mod, "local_k8s_teardown", _never)
    monkeypatch.setattr(lc_mod, "local_mesh_identity",
                        lambda _gd: ("mesh.example.org", [("superadmin", ["superadmin"])],
                                     False))
    return calls


def _gate_page(qapp, monkeypatch, host_os: str):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": _host(host_os))
    wiz = wizard_mod.StudioWizard(GENERATOR_DIR)
    wiz.show()
    pick_mode(wiz, "localcloud")
    page = advance_to(wiz, wizard_mod.LocalCloudNodesPage)
    assert _wait_until(qapp, lambda: page._k8s_up is not None), "k8s probe never answered"
    return wiz, page


def _close(wiz, page, qapp):
    for name in ("_k8s_probe", "worker"):
        t = getattr(page, name, None)
        if t is not None:
            try:
                t.wait(5000)
            except RuntimeError:
                pass
    qapp.processEvents()
    wiz.close()
    wiz.deleteLater()
    qapp.processEvents()


def test_k8s_teardown_blocker_is_the_wsl2_sentence_on_native_windows_only():
    said = lc_mod.k8s_teardown_blocker("nt")
    assert said == platform_info.native_windows_blocker(
        "Deleting the local Kubernetes cluster", osname="nt")
    assert "WSL2" in said
    assert lc_mod.k8s_teardown_blocker("posix") == ""


def test_the_gate_names_the_button_that_exists(qapp, monkeypatch, k8s_up):
    """The button was renamed to "Delete the Kubernetes cluster now"; the sentence under
    it still told the operator to press "Stop Kubernetes now" (every platform)."""
    wiz, page = _gate_page(qapp, monkeypatch, "linux")
    try:
        text = page.gate_note.text()
        assert page.down_btn.text() in text
        assert "Stop Kubernetes now" not in text
        page.confirm.setChecked(True)
        assert page.down_btn.isEnabled()          # Linux: unchanged, the button arms
    finally:
        _close(wiz, page, qapp)


def test_native_windows_gate_refuses_in_words_and_never_spawns_make(qapp, monkeypatch,
                                                                    k8s_up):
    """Pressing the button ran `make kind-down` and logged a raw WinError 2, and Next
    stayed blocked with no way forward. Now the button never arms there and the note
    gives the WSL2 sentence plus how to get past the gate."""
    wiz, page = _gate_page(qapp, monkeypatch, "windows")
    try:
        page.confirm.setChecked(True)
        assert not page.down_btn.isEnabled()
        text = page.gate_note.text()
        assert lc_mod.k8s_teardown_blocker("nt") in text
        assert "kind-down" in text and "Back and Next" in text
        page._stop_k8s()                          # even a direct call refuses
        assert k8s_up == []
        assert not page._running
        assert not page.isComplete()              # the cluster is still there
    finally:
        _close(wiz, page, qapp)


@WINDOWS_ONLY
def test_local_k8s_teardown_refuses_on_native_windows(tmp_path):
    lines = []
    ok, why = _REAL_TEARDOWN(str(tmp_path), on_line=lines.append)
    assert not ok
    assert why == lc_mod.k8s_teardown_blocker() and "WSL2" in why
    assert lines == [why]


# ── QEMU page: the build-first arm's promise ────────────────────────────────────────
SENTENCE = "QEMU device tests and mesh emulation runs bash scripts ... inside WSL2 instead."


def test_build_first_note_promises_an_automatic_run_only_where_one_can_happen(monkeypatch):
    monkeypatch.setattr(qemu_tests, "native_blocker", lambda: "")
    assert "will run automatically" in qemu_page.QemuPage._chain_note_text()
    monkeypatch.setattr(qemu_tests, "native_blocker", lambda: SENTENCE)
    text = qemu_page.QemuPage._chain_note_text()
    assert "will run automatically" not in text
    assert SENTENCE in text and "<b>not</b>" in text


def test_build_first_does_not_carry_an_opt_in_the_build_screen_refuses(monkeypatch):
    monkeypatch.setattr(qemu_page, "commit_image_mode", lambda *_a: None)
    for blocker, expected in (("", True), (SENTENCE, False)):
        monkeypatch.setattr(qemu_tests, "native_blocker", lambda b=blocker: b)
        wiz = SimpleNamespace(cfg=SimpleNamespace(qemu_device_tests=None))
        fake = SimpleNamespace(build_first=SimpleNamespace(isChecked=lambda: True),
                               selected_build_mode=lambda: "x86", wiz=wiz)
        assert qemu_page.QemuPage.validatePage(fake) is True
        assert wiz.cfg.qemu_device_tests is expected


def test_no_kvm_tcg_advice_where_no_run_can_happen(qapp):
    """Native Windows (the wizard's host) gets no TCG/KVM advice; Linux and WSL keep it
    (WSL reports "linux", so its .wslconfig remedy still shows)."""
    for host_os, shown in (("linux", True), ("windows", False)):
        host = _host(host_os)
        fake = SimpleNamespace(kvm_note=QtWidgets.QLabel(""), wiz=SimpleNamespace(host=host))
        qemu_page.QemuPage._refresh_kvm_note(fake)
        assert host.kvm_blocker()                  # there is advice to give or withhold
        assert (fake.kvm_note.text() == host.kvm_blocker()) is shown
        fake.kvm_note.deleteLater()


# ── tray: Start local stack ─────────────────────────────────────────────────────────
class _FakeNode:
    def __init__(self):
        self.started = 0

    def status(self):
        return SimpleNamespace(running=False, detail="not started")

    def start(self):
        self.started += 1
        return False, "should not be reached"


class _FakeTray:
    def __init__(self):
        self.notes, self.refreshed = [], 0

    def _notify(self, title, text):
        self.notes.append((title, text))

    def _refresh(self):
        self.refreshed += 1


def _section(qapp, blocker):
    sec = tray_mod._Section(_FakeNode(), label="local stack", blocker=blocker)
    menu = QtWidgets.QMenu()
    sec.add_to_menu(menu)
    sec.tray = _FakeTray()
    return sec, menu


def test_stack_section_blocker_is_the_local_stack_refusal():
    gd = GENERATOR_DIR
    assert tray_mod._stack_section(gd, osname="nt").blocker() == \
        platform_info.native_windows_blocker("The local stack", osname="nt")
    assert tray_mod._stack_section(gd, osname="posix").blocker() == ""


def test_start_local_stack_is_disabled_with_the_whole_sentence_on_native_windows(qapp):
    """It stayed enabled, every press blocked for the preflight and then a balloon cut
    the 417-character refusal at 255, before the 'what to do' half."""
    said = platform_info.native_windows_blocker("The local stack", osname="nt")
    assert len(said) > 255
    sec, _menu = _section(qapp, lambda: said)
    sec.refresh()
    assert not sec.start_act.isEnabled()
    assert sec.start_act.toolTip() == said            # whole, not a 255-char balloon
    assert "WSL2" in sec.status_act.text()
    sec._start()
    assert sec.node.started == 0 and sec.tray.notes == []


def test_start_local_stack_unchanged_where_it_can_run(qapp):
    sec, _menu = _section(qapp, None)
    sec.refresh()
    assert sec.start_act.isEnabled()
    assert sec.status_act.text() == "local stack: stopped (not started)"
    sec._start()
    assert sec.node.started == 1


# ── the Studio panel: a dispatched build stays on the roster ────────────────────────
class _Worker(QtCore.QThread):
    def __init__(self, gate):
        super().__init__()
        self.gate = gate

    def run(self):
        self.gate.wait(10)


def _snapshot():
    s = lai.Snapshot(taken=time.time(), state_dir="state", host="127.0.0.1:11434",
                     ollama_installed=True, ollama_up=True, models=["qwen3:8b"],
                     loaded=[], worker="stopped", counts={})
    s.summary = lai.summary_line(s)
    return s


def test_a_build_adopted_before_its_thread_starts_is_not_reaped_by_the_panel(qapp):
    """ProgressPage adopts, THEN starts the worker. The panel refreshed on `changed`
    synchronously, its running() read reaped the not-yet-started row, and the build
    lost its roster entry, its window pin and Quit's cancel."""
    from hugmesh_studio.gui import _local_ai_dock as dock_mod
    build_supervisor.reset_supervisor()
    dock = dock_mod.LocalAIDock(GENERATOR_DIR, snapshot_fn=_snapshot, auto_poll=False)
    window = QtWidgets.QWidget()
    gate = threading.Event()
    worker = _Worker(gate)
    sup = build_supervisor.supervisor()
    try:
        sup.adopt(session_id="c4-reap", label="c4", worker=worker, driver=None,
                  window=window)
        worker.start()
        qapp.processEvents()
        build = sup.find("c4-reap")
        assert build is not None
        assert build.window is window
        assert sup.count() == 1
        # the panel's own refresh (now on the next loop turn) sees it running
        assert _wait_until(qapp, lambda: "1 image build running"
                           in dock.activity.full_text())
    finally:
        gate.set()
        worker.wait(5000)
        qapp.processEvents()
        build_supervisor.reset_supervisor()
        dock.deleteLater()
        window.deleteLater()
        qapp.processEvents()


# ── Local AI: Windows-true advice in both faces ─────────────────────────────────────
def test_the_replaced_advice_is_still_what_local_ai_status_says():
    """If core/local_ai_status rewords its advice, the rewrite here would silently stop
    matching; fail loudly instead."""
    src = inspect.getsource(lai)
    for old, _system, _docker in tui_lai._WINDOWS_UP:
        assert old in src, old


@pytest.mark.parametrize("text", [
    "Install it (see the link), then run: scripts/local-ai.sh up",
    "Start it with: scripts/local-ai.sh up",
    "Ollama is not answering on 127.0.0.1:11434. Start it with scripts/local-ai.sh up "
    "(see docs/LOCAL-AI-ASSISTANT.md).",
])
def test_windows_advice_names_no_bash_script_on_native_windows(text):
    for mode, word in ((odk.SYSTEM, "Ollama for Windows"), (odk.DOCKER, "container")):
        got = tui_lai.windows_advice(text, mode, osname="nt")
        assert "local-ai.sh" not in got and word in got
    assert tui_lai.windows_advice(text, odk.SYSTEM, osname="posix") == text


def test_native_windows_note_is_the_wsl2_sentence_plus_the_windows_path():
    note = tui_lai.native_windows_note("nt")
    assert "WSL2" in note and lai.WINDOWS_NATIVE_PATH in note
    assert tui_lai.native_windows_note("posix") == ""


def _down_snapshot():
    s = _snapshot()
    s.ollama_up, s.ollama_installed = False, False
    s.problem = "Ollama is not installed on this machine."
    s.fix = "Install it (see the link), then run: scripts/local-ai.sh up"
    return s


@WINDOWS_ONLY
def test_tui_local_ai_screen_gives_no_bash_lines_on_native_windows(tmp_path):
    gen = tmp_path / "gen Jörg Ä"
    screen = tui_lai.LocalAIScreen(snapshot_fn=_down_snapshot, generator_dir=str(gen))
    j = SimpleNamespace(slug="")
    screen.enter(j)
    text = "\n".join(screen.lines(j))
    assert "local-ai.sh up" not in text
    assert "Run it yourself" not in text
    assert "WSL2" in text and "Ollama for Windows" in text


@POSIX_ONLY
def test_tui_local_ai_screen_unchanged_on_linux(tmp_path):
    screen = tui_lai.LocalAIScreen(snapshot_fn=_down_snapshot, generator_dir=str(tmp_path))
    j = SimpleNamespace(slug="")
    screen.enter(j)
    text = "\n".join(screen.lines(j))
    assert "Run it yourself" in text and "scripts/local-ai.sh up" in text


def test_start_local_assistant_writes_its_context_inside_the_studio_state_dir(
        qapp, tmp_path, monkeypatch):
    """Review round: each press of Start local assistant on native Windows wrote
    HUGMESH-CONTEXT.md and its inputs into %USERPROFILE%\\.local\\state\\hugmesh\\local-ai
    (lai.state_dir()'s XDG rule), outside the Studio state dir. Linux keeps that rule."""
    from hugmesh_studio.gui import _local_ai_dock as dock_mod
    home = tmp_path / "home"
    for var in ("HOME", "USERPROFILE"):
        monkeypatch.setenv(var, str(home))
    for var in ("XDG_STATE_HOME", lai.STATE_ENV):
        monkeypatch.delenv(var, raising=False)
    got = []
    monkeypatch.setattr(odk, "start_assistant", lambda gen, mode, extra_env=None, **k:
                        got.append(dict(extra_env or {})) or lai.StartResult(True, "ok", ""))
    dock = dock_mod.LocalAIDock(GENERATOR_DIR, snapshot_fn=_snapshot, auto_poll=False)
    try:
        dock._make_default_start(osname="nt")()
        ctx = got[-1]["HUGMESH_AGENT_CONTEXT"]
        assert os.path.isfile(ctx)
        assert os.path.commonpath([ctx, str(tmp_path / "state")]) == str(tmp_path / "state")
        assert not home.exists(), list(home.rglob("*"))
        dock._make_default_start(osname="posix")()
        assert os.path.dirname(got[-1]["HUGMESH_AGENT_CONTEXT"]) == lai.state_dir()
    finally:
        dock.deleteLater()
        qapp.processEvents()


@WINDOWS_ONLY
def test_studio_panel_gives_no_bash_advice_on_native_windows(qapp):
    from hugmesh_studio.gui import _local_ai_dock as dock_mod
    dock = dock_mod.LocalAIDock(GENERATOR_DIR, snapshot_fn=_down_snapshot, auto_poll=False)
    work = dock_mod.LocalWorkWindow(GENERATOR_DIR, snapshot_fn=_down_snapshot)
    try:
        dock.ollama_mode = odk.SYSTEM
        dock._render_instance()
        assert "local-ai.sh" not in dock.docker_label.text()
        dock.apply_snapshot(_down_snapshot())
        assert "local-ai.sh" not in dock.note.text()
        assert "local-ai.sh up" not in dock.summary.toolTip()
        assert "WSL2" in dock.start_btn.toolTip()
        work.show_snapshot(_down_snapshot())
        assert "WSL2" in work.commands.text() and ".sh todo" not in work.commands.text()
        assert "local-ai.sh" not in work.problem.text()
    finally:
        dock.deleteLater()
        work.deleteLater()
        qapp.processEvents()


# ── e2e tree: Save keeps the file's own bytes ───────────────────────────────────────
def test_save_keeps_lf_and_reports_the_bytes_written(qapp, tmp_path):
    """A text-mode write turned every LF into CRLF on Windows (the repo is eol=lf) and
    the status reported len(str), not bytes."""
    path = tmp_path / "x.feature"
    path.write_bytes(b"Feature: J\xc3\xb6rg\n  Scenario: a\n    Given b\n")
    dlg = E2ETreeDialog(ec.Catalogue(), str(tmp_path))
    try:
        dlg._load_source({"path": str(path)})
        dlg.source_edit.setPlainText(dlg.source_edit.toPlainText() + "    Then c\n")
        dlg._save_source()
        data = path.read_bytes()
        assert data == b"Feature: J\xc3\xb6rg\n  Scenario: a\n    Given b\n    Then c\n"
        assert f"({len(data)} bytes)" in dlg.source_status.text()
    finally:
        dlg.deleteLater()
        qapp.processEvents()


def test_a_crlf_file_round_trips_as_crlf(tmp_path):
    path = tmp_path / "y.spec.ts"
    path.write_bytes(b"a\r\nb\r\n")
    text, newline = read_source(str(path))
    assert (text, newline) == ("a\nb\n", "\r\n")
    n = write_source(str(path), text + "c\n", newline)
    assert path.read_bytes() == b"a\r\nb\r\nc\r\n" and n == 9


# ── LocalMesh: the probe never erases a refusal or a verb's result ──────────────────
def test_node_probe_does_not_overwrite_the_refusal(qapp):
    line = lm_mod._StatusLine("")
    mirror = QtWidgets.QLabel("")
    line.add_mirror(mirror)
    refusal = platform_info.native_windows_blocker("The DevOps lane", osname="nt") or "X"
    line.setText(refusal)
    fake = SimpleNamespace(status=line, _running=True)
    lm_mod.LocalMeshPage._on_node_status(fake, False, "not started")
    assert refusal in line.text() and "Status: stopped (not started)" in line.text()
    assert mirror.text() == line.text()
    line.setText("FAILED — see the log below")     # the next press writes a new message
    lm_mod.LocalMeshPage._on_node_status(fake, True, "up")
    assert line.text() == "FAILED — see the log below\nStatus: running (up)"


# ── Go-Live (text UI): the real reason, not a guess about a file ────────────────────
class _BlockedDriver:
    def __init__(self, said):
        self.said = said

    def blocker(self):
        return self.said

    def providers(self):
        return [] if self.said else [SimpleNamespace(key="x")]


def test_go_live_screen_says_the_wsl2_sentence_not_is_the_file_present():
    said = platform_info.native_windows_blocker("Go Live", osname="nt",
                                                runs="bash scripts")
    screen = tui_golive.GoLiveScreen()
    screen.driver = _BlockedDriver(said)
    screen.opts.domain = "mesh.example.org"
    j = SimpleNamespace(generator_dir=GENERATOR_DIR, overlay=screen, status="")
    text = "\n".join(screen.lines(j))
    assert said in text
    assert "present?" not in text
    assert "domain: mesh.example.org (picked from its Brand settings)" in text
    screen.feed(j, "1")
    assert j.status == said                        # not "no such provider: '1'"


@WINDOWS_ONLY
def test_go_live_screen_on_native_windows_with_the_real_driver(tmp_path):
    screen = tui_golive.GoLiveScreen()
    j = SimpleNamespace(generator_dir=str(tmp_path), overlay=None, status="")
    text = "\n".join(screen.lines(j))
    assert "WSL2" in text and "present?" not in text

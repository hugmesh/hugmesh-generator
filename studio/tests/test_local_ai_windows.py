"""The local AI assistant on native Windows (the MSI, or a source run under PowerShell),
with Ollama for Windows as the model host — and the same code's Linux side beside it.

The Local AI parts of the Windows sweep's cluster c4 (#827), ported onto main: the
Studio panel and the text UI's Local AI screen gave bash advice (``scripts/local-ai.sh``
lines nobody on the MSI can run), the screen printed an XDG state path
(``C:\\Users\\<you>\\.local\\state\\...``) no Windows program uses, and Start local
assistant wrote its agent context there. The core sentences themselves are pinned in
test_local_ai_status.py with an injected ``osname``; the faces below have no such seam,
so their Windows half is ``skipif(os.name != "nt")`` and their Linux half the reverse.
"""
import os
import threading
import time

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from types import SimpleNamespace                                      # noqa: E402

from hugmesh_studio.core import local_ai_status as lai                 # noqa: E402
from hugmesh_studio.core import ollama_docker as odk                   # noqa: E402
from hugmesh_studio.gui import build_supervisor                        # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtWidgets                    # noqa: E402
from hugmesh_studio.tui import local_ai as tui_lai                     # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

WINDOWS_ONLY = pytest.mark.skipif(os.name != "nt", reason="native Windows behaviour")
POSIX_ONLY = pytest.mark.skipif(os.name == "nt", reason="the Linux side of a Windows gate")


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture(autouse=True)
def _isolated_state(tmp_path, monkeypatch):
    # the saved Ollama choice, tips and the like are read from here, never from ~
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    # Ollama is absent whatever this host has installed: one set of sentences per OS
    real = lai.shutil.which
    monkeypatch.setattr(lai.shutil, "which",
                        lambda name, *a, **k: None if name == "ollama" else real(name, *a, **k))


def _wait_until(qapp, pred, timeout_s: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout_s
    while not pred() and time.monotonic() < deadline:
        qapp.processEvents()
        time.sleep(0.01)
    qapp.processEvents()
    return bool(pred())


def _snapshot():
    s = lai.Snapshot(taken=time.time(), state_dir="state", host="127.0.0.1:11434",
                     ollama_installed=True, ollama_up=True, models=["qwen3:8b"],
                     loaded=[], worker="stopped", counts={})
    s.summary = lai.summary_line(s)
    return s


def _down_snapshot():
    """The real read, with Ollama absent (nothing installed, nothing answering) as on
    this host: its sentences are the ones this platform gives."""
    return odk.adjust_snapshot(
        lai.read_snapshot({"OLLAMA_HOST": "127.0.0.1:1"}, builds=lambda: [],
                          probe=lambda: (False, [], [], "")), odk.SYSTEM)


# ── the shared note ─────────────────────────────────────────────────────────────────
def test_windows_worker_note_is_the_wsl2_sentence_plus_the_windows_path():
    note = lai.windows_worker_note("nt")
    assert "WSL2" in note and note.endswith(lai.WINDOWS_NATIVE_PATH)
    assert "Ollama for Windows" in note and "127.0.0.1:11434" in note
    assert lai.windows_worker_note("posix") == ""


# ── the text UI's Local AI screen ───────────────────────────────────────────────────
@WINDOWS_ONLY
def test_tui_local_ai_screen_gives_no_bash_lines_on_native_windows(tmp_path):
    gen = tmp_path / "gen Jörg Ä"
    screen = tui_lai.LocalAIScreen(snapshot_fn=_down_snapshot, generator_dir=str(gen))
    j = SimpleNamespace(slug="")
    screen.enter(j)
    text = "\n".join(screen.lines(j))
    assert "local-ai.sh up" not in text and ".sh todo" not in text
    assert "Run it yourself" not in text
    assert "WSL2" in text and "Ollama for Windows" in text and lai.OLLAMA_DOWNLOAD in text
    # the state path is a real Windows folder (the Studio's), not ~\.local\state
    assert os.path.join(".local", "state") not in text
    assert os.path.join(os.environ["HUGMESH_STUDIO_STATE_DIR"], "local-ai") in text
    assert lai.DOC_URL in text


@POSIX_ONLY
def test_tui_local_ai_screen_unchanged_on_linux(tmp_path):
    screen = tui_lai.LocalAIScreen(snapshot_fn=_down_snapshot, generator_dir=str(tmp_path))
    j = SimpleNamespace(slug="")
    screen.enter(j)
    text = "\n".join(screen.lines(j))
    assert "Run it yourself" in text and "scripts/local-ai.sh up" in text


# ── the Studio panel ────────────────────────────────────────────────────────────────
@WINDOWS_ONLY
def test_studio_panel_gives_no_bash_advice_on_native_windows(qapp):
    from hugmesh_studio.gui import _local_ai_dock as dock_mod
    dock = dock_mod.LocalAIDock(GENERATOR_DIR, snapshot_fn=_down_snapshot, auto_poll=False)
    work = dock_mod.LocalWorkWindow(GENERATOR_DIR, snapshot_fn=_down_snapshot)
    try:
        dock.ollama_mode = odk.SYSTEM
        dock._render_instance()
        assert "local-ai.sh" not in dock.docker_label.text()
        assert "Ollama for Windows" in dock.docker_label.text()
        dock.apply_snapshot(_down_snapshot())
        assert "local-ai.sh" not in dock.note.text()
        assert "local-ai.sh" not in dock.summary.toolTip()
        assert lai.DOC_URL in dock.summary.toolTip()
        tip = dock.start_btn.toolTip()
        assert "WSL2" in tip and "local-ai.sh start" not in tip
        work.show_snapshot(_down_snapshot())
        assert "WSL2" in work.commands.text() and ".sh todo" not in work.commands.text()
        assert "local-ai.sh" not in work.problem.text()
        assert "Ollama for Windows" in work.problem.text()
    finally:
        dock.deleteLater()
        work.deleteLater()
        qapp.processEvents()


@POSIX_ONLY
def test_studio_panel_keeps_the_run_it_yourself_lines_on_linux(qapp):
    from hugmesh_studio.gui import _local_ai_dock as dock_mod
    work = dock_mod.LocalWorkWindow(GENERATOR_DIR, snapshot_fn=_down_snapshot)
    dock = dock_mod.LocalAIDock(GENERATOR_DIR, snapshot_fn=_down_snapshot, auto_poll=False)
    try:
        work.show_snapshot(_down_snapshot())
        assert "local-ai.sh start" in work.commands.text()
        assert "scripts/local-ai.sh up" in work.problem.text()
        assert "local-ai.sh start" in dock.start_btn.toolTip()
    finally:
        dock.deleteLater()
        work.deleteLater()
        qapp.processEvents()


def test_start_local_assistant_writes_its_context_where_the_state_dir_says(
        qapp, tmp_path, monkeypatch):
    """Each press of Start local assistant on native Windows wrote HUGMESH-CONTEXT.md and
    its inputs into %USERPROFILE%\\.local\\state\\hugmesh\\local-ai (the bash script's XDG
    rule), outside the Studio state dir. There it now lands in the Studio's own folder;
    Linux keeps the XDG rule."""
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
        dock._make_default_start()()
        ctx = got[-1]["HUGMESH_AGENT_CONTEXT"]
        assert os.path.isfile(ctx)
        assert os.path.dirname(ctx) == lai.state_dir()
        if os.name == "nt":
            studio = str(tmp_path / "state")
            assert os.path.commonpath([ctx, studio]) == studio
            assert not home.exists(), list(home.rglob("*"))
        else:
            assert ctx.startswith(os.path.join(str(home), ".local", "state"))
    finally:
        dock.deleteLater()
        qapp.processEvents()


# ── the Studio panel: a dispatched build stays on the roster ────────────────────────
class _Worker(QtCore.QThread):
    def __init__(self, gate):
        super().__init__()
        self.gate = gate

    def run(self):
        self.gate.wait(10)


def test_a_build_adopted_before_its_thread_starts_is_not_reaped_by_the_panel(qapp):
    """ProgressPage adopts, THEN starts the worker. The panel refreshed on `changed`
    synchronously, its running() read reaped the not-yet-started row, and the build
    lost its roster entry, its window pin and Quit's cancel (every platform)."""
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

"""The Studio's bottom panel — one strip along the bottom of every Studio window.

It began as the Local AI dock (a prompt bar) and is now the one panel the operator asked
for on 2026-10-21: the local assistant, the local-mesh actions, the live pod view and the
running builds, docked at the bottom of the wizard window, open or collapsed on ANY page,
and able to pop out into a window of its own and back.

Collapsed it is a single row: a chevron, one line of local-AI status ("Local AI: ready,
qwen3:8b loaded, 2 queued, 1 running"), one line of what is running ("Mesh: idle · 1
image build"), **Start local assistant**, **Current work** and **Pop out**. Expanded it
adds tabs:

* **Assistant** — the prompt line (Enter sends) and its answer area, and beside them
  every option the assistant has: WHICH Ollama it talks to (the system one, or the
  Studio's own pinned container — core/ollama_docker.py), where the person's checkouts
  are, and the local AI agent launcher that used to be the card "Work on this mesh with a
  local AI agent" on the Bring-up page (gui/pages/_local_agent_widget.py, unchanged in
  what it does). Every agent it starts gets a fresh project-context file
  (core/agent_context.py).
* **Local mesh** — the local-mesh Actions box (Generate & start, Stop, DevOps lane, …).
* **Running mesh** — the pods and containers of both lanes (the running-mesh monitor).
* **Mesh run** — the staged view and log of the verb that is running.
* **Image builds** — every image build this Studio is running, with a way to show it.

The last four are the local-mesh page's own widgets, MOVED here (LocalMeshPage.take_section
with ``dock=True``), never copied: one implementation, and a verb keeps running and
streaming into them whatever page is on screen, with the panel collapsed or popped out.

Everything about the local AI reads :mod:`..core.local_ai_status` — the same snapshot the
text UI and the command line show — and talks only to an Ollama on this machine.

THREADS. The window thread never waits on the model, on docker or on the disk. Snapshot
reads, the prompt and the start request run on short daemon threads that touch no Qt
object: they put their results on a plain queue, and a timer on the window thread drains
it. A window closed mid-request therefore leaves a thread finishing harmlessly, never a
thread calling into a destroyed widget. Nothing starts at import time, and the first poll
waits until the dock is actually shown.

NO MODAL DIALOGS. Problems are shown inline, in words, with the fix. The Current work
window and the popped-out panel are ordinary windows. Nothing here positions a window with
``move()`` (a no-op on Wayland): the dock is laid out inside its parent.

WHERE IT SITS. QWizard keeps all its content in one child widget and exposes no bottom
slot, so :func:`mount_dock` shortens that child by the dock's height and puts the dock
in the strip below it. The child is watched rather than the wizard because QWizard
resizes it in its own ``resizeEvent``, after any filter on the wizard has run.
"""
from __future__ import annotations

import os
import queue
import sys
import threading
import traceback

from ..core import agent_context as actx
from ..core import assistant_settings
from ..core import local_ai_status as lai
from ..core import ollama_docker as odk
from . import styles
from .qt import Qt, QtCore, QtGui, QtWidgets, Signal

__all__ = ["LocalAIDock", "LocalWorkWindow", "PanelWindow", "mount_dock", "dock_height_for",
           "TABS"]

POLL_MS = 5000
DRAIN_MS = 120
#: Height of the dock when expanded, capped so the page above stays usable. The panel
#: shows tabs of real content now, so it may take a little more than the prompt bar did;
#: the full-size view is the popped-out window.
EXPANDED_PX = 280
EXPANDED_FRACTION = 0.38
MIN_CLICK_PX = 28
_SETTINGS = assistant_settings.FILE_NAME
#: The panel's tabs, in order: (key, label).
TABS = (("assistant", "Assistant"), ("mesh", "Local mesh"), ("pods", "Running mesh"),
        ("run", "Mesh run"), ("builds", "Image builds"))


def _log_swallowed(where: str) -> None:
    print(f"local-ai dock: swallowed exception in {where}", file=sys.stderr)
    traceback.print_exc(file=sys.stderr)


def dock_height_for(window_height: int, expanded: bool, bar_px: int) -> int:
    """How tall the dock may be in a window of ``window_height`` — a pure function so
    the cap is testable for window sizes this host does not have."""
    if not expanded:
        return bar_px
    return max(bar_px + 76, min(EXPANDED_PX, int(window_height * EXPANDED_FRACTION)))


# ── remembering open/closed ──────────────────────────────────────────────────────────
def _settings_path() -> str | None:
    return assistant_settings.settings_path()


def load_expanded() -> bool:
    return bool(assistant_settings.get("expanded", False))


def save_expanded(expanded: bool) -> None:
    # MERGED into the file, never a rewrite: the same file holds the Ollama choice and
    # the checkouts folder, and opening the panel must not forget either.
    assistant_settings.update(expanded=bool(expanded))


# ── small pieces ─────────────────────────────────────────────────────────────────────
class _ElidedLabel(QtWidgets.QLabel):
    """One line that shortens itself with an ellipsis instead of widening its row —
    a long status must never push a button out of the dock. The full text is the
    tooltip."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self._full = ""
        self.setSizePolicy(QtWidgets.QSizePolicy.Policy.Ignored,
                           QtWidgets.QSizePolicy.Policy.Preferred)
        self.setTextInteractionFlags(Qt.TextInteractionFlag.NoTextInteraction)

    def set_full_text(self, text: str) -> None:
        self._full = text
        self.setToolTip(text)
        self._elide()

    def full_text(self) -> str:
        return self._full

    def _elide(self) -> None:
        shown = self.fontMetrics().elidedText(
            self._full, Qt.TextElideMode.ElideRight, max(10, self.width()))
        QtWidgets.QLabel.setText(self, shown)

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self._elide()

    def minimumSizeHint(self):
        return QtCore.QSize(40, super().minimumSizeHint().height())


def _key_code(event) -> int:
    """``event.key()`` as a plain integer. PyQt6 returns an int; PySide6 from 6.4 returns
    an enum member, which does not compare equal to an int from the other binding's
    table. Deciding on the code works for both."""
    key = event.key()
    try:
        return int(key)
    except (TypeError, ValueError):
        return int(getattr(key, "value", -1))


_SEND_KEYS = (int(Qt.Key.Key_Return), int(Qt.Key.Key_Enter))
_ESCAPE = int(Qt.Key.Key_Escape)


class _PromptLine(QtWidgets.QLineEdit):
    """The prompt box. Enter here means "send", Escape means "never mind", nothing else.

    A plain QLineEdit emits ``returnPressed`` and then leaves the key UNACCEPTED, so the
    dialog it sits in gets it next and presses its default button. The dock sits in a
    QWizard on every page: that button is Next, or on the worklist page the one that
    commits a build. So the key is accepted here once the line has handled it.

    Escape is the other key a QDialog claims: unaccepted, it CLOSES THE WHOLE STUDIO
    WINDOW. A person who starts a question and thinks better of it should lose the
    question, not the Studio, so Escape with text in the line clears the line and stops
    there. On an empty line there is nothing left to cancel: the line leaves the key
    alone and :meth:`LocalAIDock.keyPressEvent` takes it, so it still closes nothing.
    Every other key goes where it always went."""

    def keyPressEvent(self, event):
        code = _key_code(event)
        if code == _ESCAPE and self.text():
            self.clear()
            event.accept()
            return
        super().keyPressEvent(event)
        if code in _SEND_KEYS:
            event.accept()


class _AnswerArea(QtWidgets.QPlainTextEdit):
    """The read-only answer area. It sits one Tab to the right of the prompt and a click
    into it (to select or copy the model's answer) focuses it. A read-only text edit
    takes neither Return nor Escape, so both would travel on to the wizard exactly as
    they did from a plain QLineEdit: Return presses Next (or the build button), Escape
    closes the Studio. Both stop here; arrows, Page keys and Ctrl+C still do what a
    text view does.

    WHICH WIDGETS OF THE DOCK KEEP WHICH KEYS. The dock's keyboard stops, in Tab order,
    are the chevron, Start local assistant, Current work, the prompt, Send, Clear and
    this area. Enter never reaches the wizard from any of them: it sends (prompt),
    shows or hides the prompt (chevron, :class:`_Chevron`), presses the focused button
    (the four QPushButtons are autoDefault on a dialog window and take the key
    themselves) or does nothing (here). Escape cancels only what is being typed (the
    prompt) and otherwise does nothing: it is never the wizard's Cancel from any stop
    of the dock, because :meth:`LocalAIDock.keyPressEvent` takes it on the way up."""

    def keyPressEvent(self, event):
        code = _key_code(event)
        super().keyPressEvent(event)
        if self.isReadOnly() and code in _SEND_KEYS:
            event.accept()


class _Chevron(QtWidgets.QToolButton):
    """The dock's handle: the arrow that shows or hides the prompt, and the FIRST Tab
    stop of the dock (Tab from the page's last control lands here). A QToolButton
    presses itself on Space but not on Return, and leaves Return unaccepted, so Enter
    here used to travel on to the wizard and press Next — or, on the worklist page,
    the button that starts a build — from the widget a keyboard user reaches first.
    Enter now presses the chevron, once per key press: a held key repeats the event and
    each click would show or hide the prompt and rewrite the settings file, so repeats
    are swallowed (Space already ignores them, as QAbstractButton does). Escape does
    nothing here (see :class:`_AnswerArea`)."""

    def keyPressEvent(self, event):
        code = _key_code(event)
        if code in _SEND_KEYS:
            if not event.isAutoRepeat():
                self.click()
            event.accept()
            return
        super().keyPressEvent(event)


class _Threads:
    """Run a function on a daemon thread; collect results on the window thread.

    The function and its result must not touch Qt. ``drain()`` is called from a timer
    on the window thread and hands each ``(tag, value, error)`` to a callback."""

    def __init__(self):
        self._q: "queue.SimpleQueue" = queue.SimpleQueue()
        self.in_flight: set = set()

    def submit(self, tag: str, fn, *args, **kw) -> bool:
        if tag in self.in_flight:
            return False
        self.in_flight.add(tag)

        def run():
            try:
                self._q.put((tag, fn(*args, **kw), None))
            except Exception as exc:        # noqa: BLE001 — reported, not raised
                self._q.put((tag, None, exc))
        threading.Thread(target=run, name=f"local-ai-{tag}", daemon=True).start()
        return True

    def put(self, tag: str, value, error=None) -> None:
        self._q.put((tag, value, error))

    def drain(self, handle) -> None:
        while True:
            try:
                tag, value, error = self._q.get_nowait()
            except queue.Empty:
                return
            # every submitted job clears its own tag when its result comes home (the
            # prompt's chunk/done/error are put(), never submitted, so they hold none)
            self.in_flight.discard(tag)
            handle(tag, value, error)


def _styled_button(text: str, tip: str = "") -> QtWidgets.QPushButton:
    b = QtWidgets.QPushButton(text)
    b.setMinimumHeight(MIN_CLICK_PX)
    if tip:
        b.setToolTip(tip)
    return b


# ── the Current work window ──────────────────────────────────────────────────────────
class LocalWorkWindow(QtWidgets.QWidget):
    """Non-modal list of the current local work, refreshed every 5 seconds while open."""

    def __init__(self, generator_dir: str, *, snapshot_fn=None, start_fn=None,
                 poll_ms: int = POLL_MS, auto_poll: bool = True, parent=None):
        super().__init__(parent)
        self.setWindowFlag(Qt.WindowType.Window, True)
        self.setWindowTitle("Local AI: current work")
        self.resize(780, 520)
        self.generator_dir = generator_dir
        self._snapshot_fn = snapshot_fn or (lambda: lai.read_snapshot())
        self._start_fn = start_fn
        self._threads = _Threads()
        self.snapshot = None
        self.diff_paths: dict = {}

        lay = QtWidgets.QVBoxLayout(self)
        self.summary = QtWidgets.QLabel("Reading the local AI state…")
        self.summary.setWordWrap(True)
        f = self.summary.font()
        f.setBold(True)
        self.summary.setFont(f)
        lay.addWidget(self.summary)

        self.problem = QtWidgets.QLabel("")
        self.problem.setWordWrap(True)
        self.problem.setStyleSheet(f"color: {styles.WARN};")
        self.problem.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        self.problem.setVisible(False)
        lay.addWidget(self.problem)

        self.facts = QtWidgets.QLabel("")
        self.facts.setWordWrap(True)
        self.facts.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        lay.addWidget(self.facts)

        self.tree = QtWidgets.QTreeWidget()
        self.tree.setHeaderLabels(["Kind", "State", "Work", "Detail"])
        self.tree.setRootIsDecorated(False)
        self.tree.setUniformRowHeights(True)
        self.tree.setAlternatingRowColors(True)
        self.tree.setMinimumHeight(120)
        self.tree.header().setStretchLastSection(True)
        self.tree.setColumnWidth(0, 70)
        self.tree.setColumnWidth(1, 120)
        self.tree.setColumnWidth(2, 300)
        self.tree.currentItemChanged.connect(lambda *_: self._sync_buttons())
        lay.addWidget(self.tree, 1)

        row = QtWidgets.QHBoxLayout()
        self.refresh_btn = _styled_button("Refresh", "Read the state again now")
        self.refresh_btn.clicked.connect(self.refresh)
        self.start_btn = _styled_button("Start local assistant",
                                        "Start the local Ollama and the queue worker")
        self.start_btn.clicked.connect(self._start)
        self.diff_btn = _styled_button("Open draft diff", "Show the selected draft's diff below")
        self.diff_btn.clicked.connect(self.open_selected_diff)
        self.diff_btn.setEnabled(False)
        for b in (self.refresh_btn, self.start_btn, self.diff_btn):
            row.addWidget(b)
        row.addStretch(1)
        self.stamp = QtWidgets.QLabel("")
        self.stamp.setStyleSheet(styles.muted())
        row.addWidget(self.stamp)
        lay.addLayout(row)

        self.diff_view = QtWidgets.QPlainTextEdit()
        self.diff_view.setReadOnly(True)
        self.diff_view.setLineWrapMode(QtWidgets.QPlainTextEdit.LineWrapMode.NoWrap)
        self.diff_view.setFont(QtGui.QFontDatabase.systemFont(QtGui.QFontDatabase.SystemFont.FixedFont))
        self.diff_view.setPlaceholderText("Select a draft and press Open draft diff. "
                                          "Read it yourself before you use it.")
        self.diff_view.setMinimumHeight(90)
        lay.addWidget(self.diff_view, 1)

        self.commands = QtWidgets.QLabel("")
        self.commands.setWordWrap(True)
        self.commands.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        self.commands.setStyleSheet(styles.muted())
        cmds = lai.commands(generator_dir)
        self.commands.setText(
            "Run it yourself in a terminal:  " + cmds["start"] + "   |   queue issues and watch:  "
            + cmds["todo"] + "   |   chat:  " + cmds["chat"])
        lay.addWidget(self.commands)

        self._timer = QtCore.QTimer(self)
        self._timer.setInterval(poll_ms)
        self._timer.timeout.connect(self.refresh)
        self._drain = QtCore.QTimer(self)
        self._drain.setInterval(DRAIN_MS)
        self._drain.timeout.connect(self._on_drain)
        self._auto_poll = auto_poll

    def keyPressEvent(self, event):
        """Escape closes this window and nothing else (it is a window of its own and
        its keys never reach the Studio's wizard)."""
        if _key_code(event) == _ESCAPE:
            self.close()
            event.accept()
            return
        super().keyPressEvent(event)

    # ---- life cycle -----------------------------------------------------------------
    def showEvent(self, event):
        super().showEvent(event)
        self._drain.start()
        if self._auto_poll:
            self._timer.start()
        self.refresh()

    def hideEvent(self, event):
        super().hideEvent(event)
        self._timer.stop()
        self._drain.stop()

    # ---- data -----------------------------------------------------------------------
    def refresh(self) -> None:
        self._threads.submit("snapshot", self._snapshot_fn)
        if not self._drain.isActive():
            self._drain.start()

    def show_snapshot(self, snap) -> None:
        """Render a snapshot now (the dock hands over the one it already has)."""
        self.snapshot = snap
        self.summary.setText(snap.summary)
        if snap.problem:
            self.problem.setText(f"{snap.problem}  {snap.fix}  See {snap.doc}.")
            self.problem.setVisible(True)
        else:
            self.problem.setVisible(False)
        beat = "never" if snap.heartbeat_age is None else f"{int(snap.heartbeat_age)} s ago"
        self.facts.setText(
            f"Server: {snap.host or '(refused)'} "
            f"{'answering' if snap.ollama_up else 'not answering'}.   "
            f"Model loaded: {', '.join(snap.loaded) or 'none'}.   "
            f"Worker: {snap.worker}"
            + (f" (pid {snap.worker_pid})" if snap.worker_pid else "")
            + f", last heartbeat {beat}.   State: {snap.state_dir}")
        keep = self.tree.currentItem().data(0, Qt.ItemDataRole.UserRole) if self.tree.currentItem() else None
        self.tree.clear()
        self.diff_paths = {}
        labels = {"queue": "Queue", "draft": "Draft", "build": "Build"}
        pick = None
        for job in snap.jobs:
            item = QtWidgets.QTreeWidgetItem(
                [labels.get(job.kind, job.kind), job.state, job.title, job.detail])
            item.setData(0, Qt.ItemDataRole.UserRole, f"{job.kind}:{job.id}")
            item.setToolTip(2, job.path or job.title)
            self.tree.addTopLevelItem(item)
            if job.diff_path:
                self.diff_paths[f"{job.kind}:{job.id}"] = job.diff_path
            if keep == f"{job.kind}:{job.id}":
                pick = item
        if pick is not None:
            self.tree.setCurrentItem(pick)
        self.stamp.setText("updated " + QtCore.QTime.currentTime().toString("HH:mm:ss"))
        self._sync_buttons()

    def _sync_buttons(self) -> None:
        item = self.tree.currentItem()
        key = item.data(0, Qt.ItemDataRole.UserRole) if item is not None else None
        self.diff_btn.setEnabled(key in self.diff_paths)
        self.diff_btn.setToolTip("Show the selected draft's diff below" if key in self.diff_paths
                                 else "Select a draft that has a diff")

    def open_selected_diff(self) -> bool:
        item = self.tree.currentItem()
        key = item.data(0, Qt.ItemDataRole.UserRole) if item is not None else None
        path = self.diff_paths.get(key)
        if not path:
            return False
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                self.diff_view.setPlainText(fh.read())
        except OSError as exc:
            self.diff_view.setPlainText(f"Could not read {path}: {exc}")
            return False
        return True

    def _start(self) -> None:
        if self._start_fn is not None:
            self._start_fn()

    def _on_drain(self) -> None:
        try:
            self._threads.drain(self._handle)
        except Exception:
            _log_swallowed("LocalWorkWindow._on_drain")

    def _handle(self, tag, value, error) -> None:
        if tag == "snapshot" and error is None and value is not None:
            self.show_snapshot(value)
        elif tag == "snapshot":
            self.summary.setText(f"Could not read the local AI state: {error}")


# ── the panel's pieces ───────────────────────────────────────────────────────────────
def _scroll(inner: QtWidgets.QWidget) -> QtWidgets.QScrollArea:
    """A tab's content in a scroll area: a part taller than the strip scrolls instead of
    forcing the strip (and with it the window) taller, or being clipped."""
    area = QtWidgets.QScrollArea()
    area.setWidgetResizable(True)
    area.setFrameShape(QtWidgets.QFrame.Shape.NoFrame)
    area.setWidget(inner)
    return area


def _placeholder(text: str) -> QtWidgets.QLabel:
    lab = QtWidgets.QLabel(text)
    lab.setWordWrap(True)
    lab.setStyleSheet(styles.muted())
    lab.setAlignment(Qt.AlignmentFlag.AlignTop | Qt.AlignmentFlag.AlignLeft)
    return lab


class PanelWindow(QtWidgets.QWidget):
    """The panel popped out into a window of its own. Closing it (or Escape) puts the
    panel back at the bottom of the Studio window; nothing running is touched."""

    def __init__(self, dock: "LocalAIDock", parent=None):
        super().__init__(parent)
        self.setWindowFlag(Qt.WindowType.Window, True)
        self.setWindowTitle("HugMesh Studio panel")
        self.setObjectName("studioPanelWindow")
        self._dock = dock
        self.lay = QtWidgets.QVBoxLayout(self)
        self.lay.setContentsMargins(8, 8, 8, 8)
        head = QtWidgets.QHBoxLayout()
        note = QtWidgets.QLabel("The panel from the bottom of the Studio window. Close this "
                                "window, or press Put back, to return it there.")
        note.setWordWrap(True)
        note.setStyleSheet(styles.muted())
        self.back_btn = _styled_button("Put back", "Return the panel to the bottom of the "
                                                   "Studio window")
        self.back_btn.clicked.connect(self.close)
        head.addWidget(note, 1)
        head.addWidget(self.back_btn)
        self.lay.addLayout(head)
        self.resize(980, 640)

    def keyPressEvent(self, event):
        if _key_code(event) == _ESCAPE:
            self.close()
            event.accept()
            return
        super().keyPressEvent(event)

    def closeEvent(self, event):
        try:
            self._dock.put_back()
        except Exception:
            _log_swallowed("PanelWindow.closeEvent")
        super().closeEvent(event)


# ── the dock ─────────────────────────────────────────────────────────────────────────
class LocalAIDock(QtWidgets.QFrame):
    """The Studio's bottom panel. See the module docstring."""

    layout_changed = Signal()

    def __init__(self, generator_dir: str, parent=None, *, snapshot_fn=None, prompt_fn=None,
                 start_fn=None, poll_ms: int = POLL_MS, auto_poll: bool = True,
                 expanded: bool | None = None, work_window_factory=None,
                 open_build=None, agent_card: bool = True):
        super().__init__(parent)
        self.setObjectName("localAIDock")
        self.setFrameShape(QtWidgets.QFrame.Shape.NoFrame)
        self.setAutoFillBackground(True)
        self.generator_dir = generator_dir
        # WHICH OLLAMA. Read once here and changed only by the Assistant tab's choice;
        # every call below takes its environment from _env(), the ONE switch
        # (core/ollama_docker.assistant_env), so the instance shown is the one used.
        self.ollama_mode = odk.current_mode()
        self._snapshot_fn = snapshot_fn or self._default_snapshot
        self._prompt_fn = prompt_fn or self._default_prompt
        self._custom_start = start_fn is not None
        self._start_fn = start_fn or self._default_start_now
        self._work_factory = work_window_factory
        self._open_build = open_build
        self._threads = _Threads()
        self._auto_poll = auto_poll
        self.snapshot = None
        self.work_window = None
        self.panel_window = None
        self.popped = False
        self.mesh_page = None
        self._mesh_was_running = False
        self.docker_state = None
        self.gpu = None
        self.expanded = load_expanded() if expanded is None else bool(expanded)
        self._history: list = []
        # Counts the times Clear was pressed. Every request remembers the number it started
        # under; what comes back from an older one (late words, its finished answer, its
        # error) is dropped, so Clear cannot be undone by an answer that was still on its way.
        self._clears = 0
        self._busy = False
        self._stop = threading.Event()
        self._alive = threading.Event()         # set when the dock is destroyed
        self._answered = False
        self._message = ""                      # a transient line (waiting, started, failed)
        self._message_warn = False
        self._message_token = 0

        outer = QtWidgets.QVBoxLayout(self)
        outer.setContentsMargins(8, 3, 8, 4)
        outer.setSpacing(3)
        self._outer = outer

        # the bar: always visible
        self.bar = QtWidgets.QWidget()
        bar = QtWidgets.QHBoxLayout(self.bar)
        bar.setContentsMargins(0, 0, 0, 0)
        bar.setSpacing(8)
        self.chevron = _Chevron()
        self.chevron.setAutoRaise(True)
        self.chevron.setMinimumSize(MIN_CLICK_PX, MIN_CLICK_PX)
        self.chevron.clicked.connect(self._chevron_clicked)
        self.chevron.setAccessibleName("Show or hide the Studio panel")
        self.summary = _ElidedLabel()
        self.summary.setMinimumHeight(MIN_CLICK_PX)
        self.summary.set_full_text("Local AI: reading status…")
        self.activity = _ElidedLabel()
        self.activity.setMinimumHeight(MIN_CLICK_PX)
        self.activity.setStyleSheet(styles.muted())
        self.activity.set_full_text("Mesh: idle · no image build running")
        self.start_btn = _styled_button("Start local assistant",
                                        "Start the local Ollama and the queue worker "
                                        "(runs scripts/local-ai.sh start; in Docker mode it "
                                        "starts the Studio's Ollama container first)")
        self.start_btn.clicked.connect(self.start_assistant)
        self.work_btn = _styled_button("Current work",
                                       "Open a window with the queue, the drafts and the running builds")
        self.work_btn.clicked.connect(self.show_current_work)
        self.pop_btn = _styled_button("Pop out", "Open this panel in a window of its own "
                                                 "(close that window to put it back)")
        self.pop_btn.clicked.connect(self.toggle_pop)
        bar.addWidget(self.chevron)
        bar.addWidget(self.summary, 3)
        bar.addWidget(self.activity, 2)
        bar.addWidget(self.start_btn)
        bar.addWidget(self.work_btn)
        bar.addWidget(self.pop_btn)
        outer.addWidget(self.bar)

        # the expanded part: the tabs
        self.body = QtWidgets.QWidget()
        body = QtWidgets.QVBoxLayout(self.body)
        body.setContentsMargins(0, 0, 0, 0)
        body.setSpacing(0)
        self.tabs = QtWidgets.QTabWidget()
        self.tabs.setDocumentMode(True)
        self.tabs.setUsesScrollButtons(True)
        body.addWidget(self.tabs, 1)
        outer.addWidget(self.body, 1)
        self._tab_index: dict = {}

        # ── Assistant: the chat on the left, every option on the right ──────────────
        chat = QtWidgets.QWidget()
        chat_lay = QtWidgets.QVBoxLayout(chat)
        chat_lay.setContentsMargins(0, 3, 0, 0)
        chat_lay.setSpacing(3)
        self.note = QtWidgets.QLabel("")
        self.note.setWordWrap(True)
        self.note.setStyleSheet(styles.muted())
        self.note.setVisible(False)
        row = QtWidgets.QHBoxLayout()
        row.setSpacing(6)
        self.prompt = _PromptLine()
        self.prompt.setMinimumHeight(MIN_CLICK_PX)
        self.prompt.setPlaceholderText("Ask the local model (stays on this machine). Enter sends.")
        self.prompt.setAccessibleName("Prompt for the local model")
        self.prompt.returnPressed.connect(self.send)
        self.send_btn = _styled_button("Send")
        self.send_btn.clicked.connect(self._send_or_stop)
        self.clear_btn = _styled_button("Clear", "Forget the conversation")
        self.clear_btn.clicked.connect(self.clear)
        row.addWidget(self.prompt, 1)
        row.addWidget(self.send_btn)
        row.addWidget(self.clear_btn)
        self.answer = _AnswerArea()
        self.answer.setReadOnly(True)
        self.answer.setLineWrapMode(QtWidgets.QPlainTextEdit.LineWrapMode.WidgetWidth)
        self.answer.setMinimumHeight(36)
        self.answer.setPlaceholderText("The model's answer appears here.")
        self.answer.setAccessibleName("Answer from the local model")
        chat_lay.addWidget(self.note)
        chat_lay.addLayout(row)
        chat_lay.addWidget(self.answer, 1)

        options = QtWidgets.QWidget()
        opt = QtWidgets.QVBoxLayout(options)
        opt.setContentsMargins(0, 3, 4, 3)
        self.instance_box = QtWidgets.QGroupBox("Which Ollama the assistant uses")
        ib = QtWidgets.QVBoxLayout(self.instance_box)
        self.mode_system = QtWidgets.QRadioButton(f"System Ollama ({odk.endpoint(odk.SYSTEM)})")
        self.mode_system.setToolTip(odk.MODE_WORDS[odk.SYSTEM] + ". The Studio never "
                                    "starts a second one beside it in this mode.")
        self.mode_docker = QtWidgets.QRadioButton(
            f"Ollama in Docker ({odk.IMAGE_VERSION}, port {odk.docker_port()})")
        self.mode_docker.setToolTip(odk.MODE_WORDS[odk.DOCKER] + ". "
            f"Runs {odk.IMAGE.split('@')[0]} as the container {odk.CONTAINER}, models kept "
            f"in the {odk.VOLUME} volume, on a loopback-only port that never clashes with "
            "the system 11434. The GPU is passed through when Docker can provide one. "
            "Nothing starts until you press Start.")
        for radio in (self.mode_system, self.mode_docker):
            radio.setMinimumHeight(MIN_CLICK_PX)            # a click target, not a 19 px line
        (self.mode_docker if self.ollama_mode == odk.DOCKER else self.mode_system).setChecked(True)
        self.mode_system.toggled.connect(lambda on: on and self.set_ollama_mode(odk.SYSTEM))
        self.mode_docker.toggled.connect(lambda on: on and self.set_ollama_mode(odk.DOCKER))
        self.instance_label = QtWidgets.QLabel("")
        self.instance_label.setWordWrap(True)
        self.instance_label.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        self.docker_label = QtWidgets.QLabel("")
        self.docker_label.setWordWrap(True)
        self.docker_label.setStyleSheet(styles.muted())
        self.docker_label.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        drow = QtWidgets.QHBoxLayout()
        self.docker_start_btn = _styled_button("Start Docker Ollama",
                                               "Start only the container (Start local "
                                               "assistant also starts the queue worker)")
        self.docker_start_btn.clicked.connect(self.start_docker_ollama)
        self.docker_stop_btn = _styled_button("Stop Docker Ollama",
                                              "Stop the container; the models volume stays")
        self.docker_stop_btn.clicked.connect(self.stop_docker_ollama)
        drow.addWidget(self.docker_start_btn)
        drow.addWidget(self.docker_stop_btn)
        drow.addStretch(1)
        ib.addWidget(self.mode_system)
        ib.addWidget(self.mode_docker)
        ib.addWidget(self.instance_label)
        ib.addLayout(drow)
        ib.addWidget(self.docker_label)
        opt.addWidget(self.instance_box)

        self.checkouts_box = QtWidgets.QGroupBox("Where your checkouts are")
        cb = QtWidgets.QVBoxLayout(self.checkouts_box)
        self.checkouts_edit = QtWidgets.QLineEdit(
            str(assistant_settings.get("checkouts_dir", "") or ""))
        self.checkouts_edit.setMinimumHeight(MIN_CLICK_PX)
        self.checkouts_edit.setPlaceholderText(actx.default_checkouts_dir(generator_dir))
        self.checkouts_edit.setToolTip(
            "The folder that holds your hugmesh-* git checkouts. Every agent the assistant "
            "starts is told about it, and the queue worker drafts from it. Empty = the "
            "folder that holds this generator checkout (or $HUGMESH_REPOS_ROOT).")
        self.checkouts_edit.editingFinished.connect(self._save_checkouts)
        self.checkouts_note = QtWidgets.QLabel(
            "Every agent the assistant starts gets a fresh project-context file: what "
            "HugMesh is, its repositories, the Studio, and where these checkouts and "
            "each domain's code folders are.")
        self.checkouts_note.setWordWrap(True)
        self.checkouts_note.setStyleSheet(styles.muted())
        cb.addWidget(self.checkouts_edit)
        cb.addWidget(self.checkouts_note)
        opt.addWidget(self.checkouts_box)

        self.agent_card = None
        if agent_card:
            from .pages import _local_agent_widget as law
            self.agent_card = law.LocalAgentWidget(
                generator_dir, context=self._agent_context, environ=self._env,
                context_text=self._agent_context_text)
            opt.addWidget(self.agent_card)
        opt.addStretch(1)
        self.options_scroll = _scroll(options)

        self.assistant_split = QtWidgets.QSplitter(Qt.Orientation.Horizontal)
        self.assistant_split.setChildrenCollapsible(False)
        self.assistant_split.addWidget(chat)
        self.assistant_split.addWidget(self.options_scroll)
        # The options column gets three fifths: the agent launcher's form needs about
        # 400 px to show its drop-downs whole, and the chat line needs less.
        # Until the person drags the handle, every resize re-applies that split.
        self._split_moved = False
        self.assistant_split.splitterMoved.connect(self._on_split_moved)
        self.assistant_split.installEventFilter(self)
        self._add_tab("assistant", self.assistant_split)

        # ── the local mesh's parts (claimed from LocalMeshPage by attach_mesh_page) ──
        self._hosts: dict = {}
        no_page = ("This Studio window has no local-mesh page yet. Choose \"Run a local "
                   "Docker mesh\" on the mode screen; its {what} then lives here.")
        for key, what in (("mesh", "actions"), ("pods", "running-mesh view"),
                          ("run", "run log")):
            inner = QtWidgets.QWidget()
            lay = QtWidgets.QVBoxLayout(inner)
            lay.setContentsMargins(0, 3, 4, 3)
            ph = _placeholder(no_page.format(what=what))
            lay.addWidget(ph)
            lay.addStretch(1)
            self._hosts[key] = (inner, lay, ph)
            self._add_tab(key, _scroll(inner))

        # ── image builds: the process-wide roster (gui/build_supervisor.py) ─────────
        builds = QtWidgets.QWidget()
        bl = QtWidgets.QVBoxLayout(builds)
        bl.setContentsMargins(0, 3, 4, 3)
        self.builds_tree = QtWidgets.QTreeWidget()
        self.builds_tree.setHeaderLabels(["Build", "State", "Running for"])
        self.builds_tree.setRootIsDecorated(False)
        self.builds_tree.setUniformRowHeights(True)
        self.builds_tree.setMinimumHeight(60)
        self.builds_tree.setColumnWidth(0, 380)
        self.builds_tree.currentItemChanged.connect(lambda *_: self._sync_builds_buttons())
        brow = QtWidgets.QHBoxLayout()
        self.build_show_btn = _styled_button("Show this build",
                                             "Bring the window that is running it to the front")
        self.build_show_btn.clicked.connect(self.show_selected_build)
        self.builds_note = QtWidgets.QLabel("")
        self.builds_note.setWordWrap(True)
        self.builds_note.setStyleSheet(styles.muted())
        brow.addWidget(self.build_show_btn)
        brow.addWidget(self.builds_note, 1)
        bl.addWidget(self.builds_tree, 1)
        bl.addLayout(brow)
        self._add_tab("builds", builds)

        last = str(assistant_settings.get("tab", "assistant") or "assistant")
        self.tabs.setCurrentIndex(self._tab_index.get(last, 0))
        self.tabs.currentChanged.connect(self._on_tab_changed)

        self._drain = QtCore.QTimer(self)
        self._drain.setInterval(DRAIN_MS)
        self._drain.timeout.connect(self._on_drain)
        self._poll = QtCore.QTimer(self)
        self._poll.setInterval(poll_ms)
        self._poll.timeout.connect(self.refresh)
        # The "what is running" line and the builds list: in-memory reads only, once a
        # second while the panel is on screen.
        self._activity_timer = QtCore.QTimer(self)
        self._activity_timer.setInterval(1000)
        self._activity_timer.timeout.connect(self.refresh_activity)
        try:
            from . import build_supervisor
            build_supervisor.supervisor().changed.connect(self.refresh_activity)
        except Exception:                        # pragma: no cover - no QApplication
            _log_swallowed("LocalAIDock(supervisor)")
        alive = self._alive
        self.destroyed.connect(lambda *_: alive.set())      # a request outliving its window stops
        self._render_instance()
        self.refresh_activity()
        self._apply_expanded(notify=False)

    def _on_split_moved(self, *_a) -> None:
        self._split_moved = True

    def eventFilter(self, obj, event):
        try:
            if obj is self.assistant_split and event.type() == QtCore.QEvent.Type.Resize \
                    and not self._split_moved:
                self._apply_split()
                # and once more after the splitter's own resize handling has run
                QtCore.QTimer.singleShot(0, self._apply_split)
        except Exception:
            _log_swallowed("LocalAIDock.eventFilter")
        return False

    def _apply_split(self) -> None:
        try:
            sp = self.assistant_split
            if self._split_moved or sp.width() <= 0:
                return
            w = max(0, sp.width() - sp.handleWidth())
            want = [w * 2 // 5, w - w * 2 // 5]
            if sp.sizes() != want:
                sp.blockSignals(True)
                sp.setSizes(want)
                sp.blockSignals(False)
        except RuntimeError:                     # destroyed before the timer fired
            pass

    def _add_tab(self, key: str, widget) -> None:
        label = dict(TABS)[key]
        self._tab_index[key] = self.tabs.addTab(widget, label)

    def keyPressEvent(self, event):
        """Escape never closes the Studio from the dock, and Enter never presses the
        wizard's Next from it. A key a dock widget leaves unaccepted travels up through
        here to the wizard: a QDialog closes itself on an Escape nobody took, and presses
        its default button (Next, or on the worklist page the one that starts a build) on
        an Enter nobody took — from a drop-down or a check box of the Local mesh tab,
        say. The operator's rule is that Escape only cancels the current input or dialog:
        the prompt clears its own text (:class:`_PromptLine`), and on every other stop of
        the dock there is nothing of the dock's to cancel, so the key ends here. The
        wizard's own Cancel button and the window's close button still close it."""
        if _key_code(event) in (_ESCAPE,) + _SEND_KEYS:
            event.accept()
            return
        super().keyPressEvent(event)

    # ---- geometry -------------------------------------------------------------------
    def bar_height(self) -> int:
        return max(MIN_CLICK_PX, self.bar.sizeHint().height()) + 7

    def preferred_height(self, window_height: int) -> int:
        return dock_height_for(window_height, self.expanded and not self.popped,
                               self.bar_height())

    # ---- expand / collapse ----------------------------------------------------------
    def _chevron_clicked(self) -> None:
        if self.popped:
            self.put_back()
            if not self.expanded:
                self.set_expanded(True)
            return
        self.set_expanded(not self.expanded)

    def set_expanded(self, on: bool) -> None:
        if bool(on) == self.expanded:
            return
        self.expanded = bool(on)
        save_expanded(self.expanded)
        self._apply_expanded()
        if self.expanded and self.current_tab() == "assistant":
            self.prompt.setFocus()

    def _apply_expanded(self, notify: bool = True) -> None:
        if not self.popped:
            self.body.setVisible(self.expanded)
        self.chevron.setArrowType(Qt.ArrowType.DownArrow if self.expanded and not self.popped
                                  else Qt.ArrowType.UpArrow)
        self.chevron.setToolTip("Hide the panel" if self.expanded and not self.popped
                                else "Show the panel")
        if notify:
            self.layout_changed.emit()

    # ---- tabs -----------------------------------------------------------------------
    def current_tab(self) -> str:
        i = self.tabs.currentIndex()
        return next((k for k, v in self._tab_index.items() if v == i), "assistant")

    def show_tab(self, key: str) -> None:
        """Open the panel on tab ``key``: in its window when popped out, at the bottom
        of the Studio window otherwise."""
        if key in self._tab_index:
            self.tabs.setCurrentIndex(self._tab_index[key])
        if self.popped and self.panel_window is not None:
            self.panel_window.show()
            self.panel_window.raise_()
            self.panel_window.activateWindow()
        else:
            self.set_expanded(True)

    def _on_tab_changed(self, _i: int) -> None:
        try:
            key = self.current_tab()
            assistant_settings.update(tab=key)
            self._tab_shown(key)
        except Exception:
            _log_swallowed("LocalAIDock._on_tab_changed")

    def _tab_shown(self, key: str) -> None:
        """A local-mesh tab was opened: make sure what it shows is being read."""
        page = self.mesh_page
        if key == "builds":
            self.refresh_activity()
        if page is None or key not in ("mesh", "pods"):
            return
        try:
            if getattr(page, "_mesh_up", None) is None:
                page._probe_mesh_state()
            sec = getattr(page, "monitor_section", None)
            if key == "pods" and sec is not None and not sec.is_expanded():
                # In the panel the TAB is the open-or-closed control; a folded table
                # inside an opened tab would be a second click for nothing.
                sec.set_expanded(True)
        except Exception:
            _log_swallowed("LocalAIDock._tab_shown")

    # ---- pop out / put back ---------------------------------------------------------
    def toggle_pop(self) -> None:
        if self.popped:
            self.put_back()
        else:
            self.pop_out()

    def pop_out(self):
        """Move the tabs into a window of their own. Nothing is rebuilt: the same widgets
        change parent, so a running verb keeps streaming into its log."""
        if self.popped:
            return self.panel_window
        if self.panel_window is None:
            self.panel_window = PanelWindow(self, parent=self.window())
        self._outer.removeWidget(self.body)
        self.panel_window.lay.addWidget(self.body, 1)
        self.body.setVisible(True)
        self.popped = True
        self.pop_btn.setText("Put back")
        self.pop_btn.setToolTip("Return the panel to the bottom of this window")
        self._apply_expanded()
        self.panel_window.show()
        self.panel_window.raise_()
        self.panel_window.activateWindow()
        return self.panel_window

    def put_back(self) -> None:
        if not self.popped:
            return
        self.popped = False
        if self.panel_window is not None:
            self.panel_window.lay.removeWidget(self.body)
        self._outer.addWidget(self.body, 1)
        self.pop_btn.setText("Pop out")
        self.pop_btn.setToolTip("Open this panel in a window of its own "
                                "(close that window to put it back)")
        self._apply_expanded()
        if self.panel_window is not None and self.panel_window.isVisible():
            self.panel_window.hide()

    # ---- the local-mesh page's parts -------------------------------------------------
    def attach_mesh_page(self, page) -> bool:
        """Take the local-mesh page's Actions box, running-mesh monitor and run view into
        the panel. They are MOVED (one implementation); the page shows a note saying
        where they went. False when there is no page to take them from."""
        if page is None or not hasattr(page, "take_section"):
            return False
        self.mesh_page = page
        for key, part in (("mesh", "actions"), ("pods", "monitor"), ("run", "run")):
            _inner, lay, ph = self._hosts[key]
            w = page.take_section(part, lay, dock=True)
            if w is not None:
                ph.setVisible(False)
        try:
            page.attach_dock(self.show_tab)
            page.completeChanged.connect(self._on_mesh_changed)
        except Exception:
            _log_swallowed("LocalAIDock.attach_mesh_page")
        if self.agent_card is not None:
            from .pages import _local_agent_widget as law
            law.follow_page(self.agent_card, page)
        self.refresh_activity()
        return True

    def _on_mesh_changed(self) -> None:
        """A verb started or ended on the local-mesh page (its completeChanged). When one
        STARTS, the panel opens on the run so the person sees it, wherever they are."""
        try:
            running = bool(getattr(self.mesh_page, "_running", False))
            if running and not self._mesh_was_running:
                self.show_tab("run")
            self._mesh_was_running = running
            self.refresh_activity()
        except Exception:
            _log_swallowed("LocalAIDock._on_mesh_changed")

    # ---- what is running --------------------------------------------------------------
    def _running_builds(self) -> list:
        try:
            from . import build_supervisor
            return build_supervisor.supervisor().running()
        except Exception:
            return []

    def refresh_activity(self) -> None:
        try:
            page = self.mesh_page
            mesh_running = bool(getattr(page, "_running", False)) if page is not None else False
            mesh_label = str(getattr(page, "_running_label", "") or "") if mesh_running else ""
            builds = self._running_builds()
            mesh_words = f"Mesh: {mesh_label or 'a verb'} running" if mesh_running else "Mesh: idle"
            build_words = (f"{len(builds)} image build{'s' if len(builds) != 1 else ''} running"
                           if builds else "no image build running")
            self.activity.set_full_text(f"{mesh_words} · {build_words}")
            if self.current_tab() == "builds" or self.builds_tree.topLevelItemCount() != (
                    len(builds) + (1 if mesh_running else 0)):
                self._fill_builds(builds, mesh_running, mesh_label)
        except RuntimeError:                     # a widget deleted under us at teardown
            pass
        except Exception:
            _log_swallowed("LocalAIDock.refresh_activity")

    def _fill_builds(self, builds, mesh_running: bool, mesh_label: str) -> None:
        keep = self.builds_tree.currentItem().data(0, Qt.ItemDataRole.UserRole) \
            if self.builds_tree.currentItem() else None
        self.builds_tree.clear()
        pick = None
        if mesh_running:
            item = QtWidgets.QTreeWidgetItem([f"Local mesh: {mesh_label or 'a verb'}",
                                              "running", ""])
            item.setData(0, Qt.ItemDataRole.UserRole, "mesh:")
            self.builds_tree.addTopLevelItem(item)
            if keep == "mesh:":
                pick = item
        for b in builds:
            secs = int(b.elapsed())
            item = QtWidgets.QTreeWidgetItem([b.label, "running", f"{secs // 60}:{secs % 60:02d}"])
            key = f"build:{b.session_id}"
            item.setData(0, Qt.ItemDataRole.UserRole, key)
            item.setToolTip(0, b.workdir or b.label)
            self.builds_tree.addTopLevelItem(item)
            if keep == key:
                pick = item
        if pick is None and self.builds_tree.topLevelItemCount():
            pick = self.builds_tree.topLevelItem(0)
        if pick is not None:
            self.builds_tree.setCurrentItem(pick)
        self.builds_note.setText(
            "" if self.builds_tree.topLevelItemCount() else
            "Nothing is building. An image build started from any Studio window, and a "
            "local-mesh verb, are listed here while they run; closing a window or this "
            "panel never stops one.")
        self._sync_builds_buttons()

    def _sync_builds_buttons(self) -> None:
        item = self.builds_tree.currentItem()
        self.build_show_btn.setEnabled(item is not None)
        self.build_show_btn.setToolTip("Bring the window that is running it to the front"
                                       if item is not None else "Select a running build")

    def show_selected_build(self) -> bool:
        item = self.builds_tree.currentItem()
        key = item.data(0, Qt.ItemDataRole.UserRole) if item is not None else ""
        if key == "mesh:":
            self.show_tab("run")
            return True
        if not key or not str(key).startswith("build:"):
            return False
        sid = str(key)[len("build:"):]
        from . import build_supervisor
        live = build_supervisor.supervisor().find(sid)
        if self._open_build is not None:
            self._open_build(_SessionRef(sid))
            return True
        win = getattr(live, "window", None) if live is not None else None
        if win is not None:
            win.show()
            win.raise_()
            win.activateWindow()
            return True
        return False

    # ---- which Ollama -----------------------------------------------------------------
    def _env(self) -> dict:
        """The environment every assistant call uses — THE switch between the system
        Ollama and the Docker one (core/ollama_docker.assistant_env)."""
        return odk.assistant_env(self.ollama_mode)

    def set_ollama_mode(self, mode: str) -> None:
        if mode == self.ollama_mode:
            return
        self.ollama_mode = mode
        odk.set_mode(mode)
        self._render_instance()
        self.refresh()
        if self.agent_card is not None and getattr(self.agent_card, "_first_probe_done", False):
            self.agent_card.recheck()            # the models live on the other server

    def _render_instance(self) -> None:
        mode = self.ollama_mode
        self.instance_label.setText(odk.describe(mode))
        docker = mode == odk.DOCKER
        self.docker_start_btn.setVisible(docker)
        self.docker_stop_btn.setVisible(docker)
        st, gpu = self.docker_state, self.gpu
        if not docker:
            self.docker_label.setText(
                "The Studio does not start or stop the system Ollama from here: Start "
                "local assistant runs scripts/local-ai.sh start, which starts it only if "
                "it is down.")
            return
        bits = []
        if st is None:
            bits.append("Checking Docker…")
        elif not st.docker_ok:
            bits.append(f"Docker is not answering: {st.error}")
        elif st.running:
            bits.append(f"Container {odk.CONTAINER} is running.")
        elif st.exists:
            bits.append(f"Container {odk.CONTAINER} exists and is stopped.")
        else:
            bits.append(f"No container yet: the first start downloads {odk.IMAGE_VERSION} "
                        "(about 3.8 GB).")
        if gpu is not None:
            bits.append(gpu.words)
        bits.append("Pull a model into it: " + odk.pull_command(lai.DEFAULT_MODEL))
        self.docker_label.setText("  ".join(bits))
        self.docker_start_btn.setEnabled(not (st is not None and st.running))
        self.docker_stop_btn.setEnabled(bool(st is not None and st.running))

    def start_docker_ollama(self) -> None:
        self.docker_start_btn.setEnabled(False)
        self._say("Starting the Docker Ollama (the first start downloads the image)…")
        self._threads.submit("docker-start", lambda: odk.start(environ=self._env()))

    def stop_docker_ollama(self) -> None:
        self.docker_stop_btn.setEnabled(False)
        self._threads.submit("docker-stop", odk.stop)

    def _save_checkouts(self) -> None:
        assistant_settings.update(checkouts_dir=self.checkouts_edit.text().strip())

    # ---- the agent card's inputs ----------------------------------------------------------
    def _agent_context(self):
        from .pages import _local_agent_widget as law
        page = self.mesh_page
        return law.context_from_page(page) if page is not None else law.AgentContext()

    def _agent_context_text(self, ctx) -> str:
        """The project-context text for one agent start. Runs on the card's WORKER (it
        reads the disk); it reads only plain values."""
        return actx.context_for(
            self.generator_dir, source_mode=ctx.source_mode, source_dir=ctx.source_dir,
            rows=ctx.domain_rows, mesh=ctx.mesh, ollama=odk.describe(self.ollama_mode))

    # ---- polling --------------------------------------------------------------------
    def showEvent(self, event):
        super().showEvent(event)
        self._drain.start()
        self._activity_timer.start()
        if self._auto_poll:
            self._poll.start()
        QtCore.QTimer.singleShot(0, self.refresh)          # after the window is up, not during it

    def hideEvent(self, event):
        super().hideEvent(event)
        self._poll.stop()
        self._activity_timer.stop()

    def _default_snapshot(self):
        mode = self.ollama_mode
        snap = lai.read_snapshot(env=odk.assistant_env(mode))
        return odk.adjust_snapshot(snap, mode, self.generator_dir)

    def refresh(self) -> None:
        self._threads.submit("snapshot", self._snapshot_fn)
        if self.ollama_mode == odk.DOCKER and self._auto_poll:
            self._threads.submit("docker-state", odk.state)
            if self.gpu is None:
                self._threads.submit("gpu", odk.detect_gpu)

    def apply_snapshot(self, snap) -> None:
        self.snapshot = snap
        line = snap.summary
        if self.ollama_mode == odk.DOCKER and line.startswith("Local AI:"):
            # which instance is in use, on the line that is always on screen
            line = "Local AI (Docker):" + line[len("Local AI:"):]
        self.summary.set_full_text(line)
        tip = line + "\n" + odk.describe(self.ollama_mode)
        if snap.problem:
            tip += f"\n{snap.problem} {snap.fix}\nSee {snap.doc}"
        self.summary.setToolTip(tip)
        self._render_note()
        if self.work_window is not None and self.work_window.isVisible():
            self.work_window.show_snapshot(snap)

    # ---- the note line: a transient message wins over the standing problem ------------
    def _say(self, text: str, seconds: float = 0.0, warn: bool = False) -> None:
        """Show ``text`` under the status line. ``seconds`` > 0 clears it after that long;
        0 keeps it until the next action replaces it. ``warn`` colours it as a problem."""
        self._message = text
        self._message_warn = warn
        self._message_token += 1
        token = self._message_token
        self._render_note()
        if seconds > 0:
            QtCore.QTimer.singleShot(int(seconds * 1000), lambda: self._unsay(token))

    def _unsay(self, token: int) -> None:
        try:
            if token == self._message_token:
                self._message = ""
                self._render_note()
        except RuntimeError:                      # the dock was destroyed first
            pass

    def _render_note(self) -> None:
        text, warn = self._message, self._message_warn
        if not text and self.snapshot is not None and self.snapshot.problem:
            text = (f"{self.snapshot.problem} {self.snapshot.fix} "
                    f"(See {self.snapshot.doc}.)")
            warn = True
        self.note.setStyleSheet(f"color: {styles.WARN};" if warn else styles.muted())
        self.note.setText(text)
        self.note.setVisible(bool(text))

    # ---- the prompt -----------------------------------------------------------------
    def _default_prompt(self, text, history, on_chunk, should_stop, env=None):
        # No model is named here on purpose: ``send_prompt`` then asks ``pick_model``, the
        # one place $LOCAL_AI_MODEL and the default are honoured, exactly as the command
        # line and the text UI do. Preferring whatever happens to be loaded would make the
        # dock answer from a different model than the other faces under the same settings.
        # ``env`` is the chosen Ollama's (read on the window thread at Send).
        return lai.send_prompt(text, history=history, on_chunk=on_chunk,
                               should_stop=should_stop, env=env)

    def send(self) -> bool:
        """Send the prompt line to the model on a worker thread. False if nothing was sent."""
        text = self.prompt.text().strip()
        if not text or self._busy:
            return False
        self.prompt.clear()
        self._busy = True
        self._stop = threading.Event()
        stop, alive = self._stop, self._alive
        self._answered = False
        self.send_btn.setText("Stop")
        self.send_btn.setToolTip("Stop the answer")
        self._append(f"You: {text}\nLocal AI: ")
        self._say("Waiting for the model. The first answer after a pause can take a minute "
                  "while it loads.")
        history = list(self._history)
        q = self._threads
        born = self._clears
        env = self._env()
        default = self._prompt_fn == self._default_prompt

        def work():
            try:
                chunk = lambda c: q.put("chunk", (born, c))          # noqa: E731
                stopping = lambda: stop.is_set() or alive.is_set()     # noqa: E731
                if default:
                    answer = self._default_prompt(text, history, chunk, stopping, env=env)
                else:
                    answer = self._prompt_fn(text, history, chunk, stopping)
                q.put("done", (born, text, answer))
            except Exception as exc:      # noqa: BLE001 — shown to the person, as a sentence
                q.put("error", (born, str(exc) or exc.__class__.__name__))
        threading.Thread(target=work, name="local-ai-prompt", daemon=True).start()
        return True

    def _send_or_stop(self) -> None:
        if self._busy:
            self._stop.set()
        else:
            self.send()

    def clear(self) -> None:
        self._clears += 1
        self._history.clear()
        self.answer.clear()
        if self._busy:
            self._stop.set()
            # Release the dock now. The old request may sit in the model's load for up to
            # two minutes before it hears the stop, and a person who cleared it must be
            # able to ask again at once; what it eventually sends back is dropped.
            self._finish_prompt()

    def _append(self, text: str) -> None:
        cur = self.answer.textCursor()
        cur.movePosition(QtGui.QTextCursor.MoveOperation.End)
        cur.insertText(text)
        self.answer.setTextCursor(cur)
        self.answer.verticalScrollBar().setValue(self.answer.verticalScrollBar().maximum())

    def _finish_prompt(self) -> None:
        self._busy = False
        self.send_btn.setText("Send")
        self.send_btn.setToolTip("")
        self._say("")

    # ---- the buttons ----------------------------------------------------------------
    def _worker_env(self, ctx) -> dict:
        """What the queue worker is started with beyond the Ollama address: the checkouts
        folder (draft.sh's HUGMESH_REPOS_ROOT) and the project-context file its agents
        read (HUGMESH_AGENT_CONTEXT, written fresh here). Runs on the start thread."""
        env = self._env()
        root = actx.checkouts_dir(self.generator_dir, env)
        text = actx.context_for(self.generator_dir, source_mode=ctx.source_mode,
                                source_dir=ctx.source_dir, rows=ctx.domain_rows,
                                mesh=ctx.mesh, ollama=odk.describe(self.ollama_mode),
                                environ=env)
        path = actx.write_context(os.path.join(lai.state_dir(env), actx.CONTEXT_NAME), text)
        return {actx.REPOS_ROOT_ENV: root, actx.CONTEXT_ENV: path}

    def _default_start_now(self):
        """The default start when no ``start_fn`` was injected: built at press time by
        :meth:`start_assistant` (it must read the page on the window thread)."""
        return self._make_default_start()()

    def _make_default_start(self):
        ctx = self._agent_context()               # widgets: read HERE, on the window thread
        mode = self.ollama_mode
        gen = self.generator_dir

        def run():
            extra = self._worker_env(ctx)
            return odk.start_assistant(gen, mode, extra_env=extra)
        return run

    def start_assistant(self) -> None:
        """Start the local Ollama (system or Docker) and the queue worker; never blocks,
        never a dialog."""
        self.start_btn.setEnabled(False)
        self.start_btn.setText("Starting…")
        self._threads.in_flight.discard("start")
        fn = self._start_fn if self._custom_start else self._make_default_start()
        self._threads.submit("start", fn)

    def show_current_work(self):
        if self.work_window is None:
            factory = self._work_factory or (lambda: LocalWorkWindow(
                self.generator_dir, snapshot_fn=self._snapshot_fn, start_fn=self.start_assistant,
                parent=self.window()))
            self.work_window = factory()
        if self.snapshot is not None:
            self.work_window.show_snapshot(self.snapshot)
        self.work_window.show()
        self.work_window.raise_()
        self.work_window.activateWindow()
        return self.work_window

    # ---- results come home on the window thread -------------------------------------
    def _on_drain(self) -> None:
        try:
            self._threads.drain(self._handle)
        except Exception:
            _log_swallowed("LocalAIDock._on_drain")

    def _handle(self, tag, value, error) -> None:
        if tag == "snapshot":
            if error is None and value is not None:
                self.apply_snapshot(value)
            else:
                self.summary.set_full_text(f"Local AI: status unavailable ({error})")
        elif tag == "docker-state":
            if error is None:
                self.docker_state = value
                self._render_instance()
        elif tag == "gpu":
            if error is None:
                self.gpu = value
                self._render_instance()
        elif tag in ("docker-start", "docker-stop"):
            ok = error is None and value is not None and value.ok
            msg = value.message if value is not None else str(error)
            self._say(msg, 30, warn=not ok)
            if self._auto_poll:
                self._threads.submit("docker-state", odk.state)
            QtCore.QTimer.singleShot(1500, self.refresh)
            self._render_instance()
        elif tag == "chunk":
            born, piece = value
            if born != self._clears:
                return                       # a question the person has since cleared
            if not self._answered:
                self._answered = True
                self._say("")
            self._append(piece)
        elif tag == "done":
            born, _text, answer = value
            if born == self._clears:
                self._append("\n\n")
                if answer.strip():
                    self._history += [{"role": "user", "content": _text},
                                      {"role": "assistant", "content": answer}]
                    del self._history[:-40]
                self._finish_prompt()
        elif tag == "error":
            born, message = value
            if born != self._clears:
                return                       # Clear already released the dock; a newer question may own it
            self._append(f"\n[{message}]\n\n")
            self._finish_prompt()
            self._say(str(message), 30, warn=True)
            self.refresh()
        elif tag == "start":
            self.start_btn.setEnabled(True)
            self.start_btn.setText("Start local assistant")
            res = value if error is None else None
            if res is not None and res.ok:
                self._say(res.message, 20)
                QtCore.QTimer.singleShot(1500, self.refresh)
                QtCore.QTimer.singleShot(6000, self.refresh)
            else:
                # Could not start it from here: open the work window, which shows the
                # exact command to run yourself.
                cmd = res.command if res is not None else lai.commands(self.generator_dir)["start"]
                why = res.message if res is not None else str(error)
                self._say(f"{why} Run it yourself: {cmd}", 60, warn=True)
                self.show_current_work()


class _SessionRef:
    """What StudioShell.open_build_window reads from a session: its id."""

    def __init__(self, sid: str):
        self.id = sid


# ── mounting on a window ─────────────────────────────────────────────────────────────
class _DockMount(QtCore.QObject):
    """Keeps the dock in a strip along the bottom of a QWizard and the wizard's content
    above it. Parented to the wizard, so it lives and dies with it."""

    def __init__(self, wizard, dock: LocalAIDock):
        super().__init__(wizard)
        self.wizard = wizard
        self.dock = dock
        self.container = self._find_container(wizard)
        self._busy = False
        wizard.installEventFilter(self)
        if self.container is not None:
            self.container.installEventFilter(self)
        dock.layout_changed.connect(self.relayout)

    @staticmethod
    def _find_container(wizard):
        """The direct child of the wizard that holds the page and the buttons."""
        probe = wizard.button(QtWidgets.QWizard.WizardButton.NextButton)
        w = probe
        while w is not None and w.parentWidget() is not wizard:
            w = w.parentWidget()
        return w

    def strip_height(self) -> int:
        return self.dock.preferred_height(self.wizard.height())

    def relayout(self) -> None:
        if self._busy:
            return
        self._busy = True
        try:
            width, height = self.wizard.width(), self.wizard.height()
            h = min(self.strip_height(), max(0, height - 120))
            if self.container is not None:
                self.container.setGeometry(0, 0, width, max(0, height - h))
            self.dock.setGeometry(0, height - h, width, h)
            self.dock.raise_()
        finally:
            self._busy = False

    def eventFilter(self, obj, event):
        try:
            t = event.type()
            if t in (QtCore.QEvent.Type.Resize, QtCore.QEvent.Type.Show,
                     QtCore.QEvent.Type.LayoutRequest):
                if obj is self.container or t == QtCore.QEvent.Type.Show:
                    self.relayout()
                elif obj is self.wizard:
                    # QWizard resizes its content AFTER this filter; the container filter
                    # above then corrects it. Place the dock now so it never lags a frame.
                    self.dock.setGeometry(0, self.wizard.height() - self.strip_height(),
                                          self.wizard.width(), self.strip_height())
        except Exception:
            _log_swallowed("_DockMount.eventFilter")
        return False


def mount_dock(wizard, generator_dir: str, **kw) -> LocalAIDock:
    """Add the Studio panel to a Studio window. Idempotent: a second call returns the
    dock the window already has. The window's local-mesh page (when it has one) hands
    its Actions box, running-mesh monitor and run view to the panel here."""
    existing = getattr(wizard, "local_ai_dock", None)
    if existing is not None:
        return existing
    dock = LocalAIDock(generator_dir, parent=wizard, **kw)
    wizard.local_ai_dock = dock
    wizard._local_ai_mount = _DockMount(wizard, dock)
    try:
        dock.attach_mesh_page(getattr(wizard, "localmesh_page", None))
    except Exception:
        _log_swallowed("mount_dock(attach_mesh_page)")
    wizard._local_ai_mount.relayout()
    dock.show()
    return dock

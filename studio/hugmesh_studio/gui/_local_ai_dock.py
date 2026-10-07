"""The Local AI dock — one thin bar along the bottom of every Studio window.

Collapsed it is a single row: a chevron, one line of local-AI status ("Local AI: ready,
qwen3:8b loaded, 2 queued, 1 running"), a **Start local assistant** button and a
**Current work** button. Expanded it adds a prompt line (Enter sends) and a scrollable
answer area. **Current work** opens a separate, non-modal window listing the queue, the
drafts (with a viewer for each draft's diff), the model loaded and the Studio's own
running builds.

Everything here reads :mod:`..core.local_ai_status` — the same snapshot the text UI and
the command line show — and talks only to the Ollama on this machine.

THREADS. The window thread never waits on the model or on the disk. Snapshot reads, the
prompt and the start request run on short daemon threads that touch no Qt object: they
put their results on a plain queue, and a timer on the window thread drains it. A window
closed mid-request therefore leaves a thread finishing harmlessly, never a thread
calling into a destroyed widget. Nothing starts at import time, and the first poll waits
until the dock is actually shown.

NO MODAL DIALOGS. Problems are shown inline, in words, with the fix. The Current work
window is an ordinary window. Nothing here positions a window with ``move()`` (a no-op
on Wayland): the dock is laid out inside its parent.

WHERE IT SITS. QWizard keeps all its content in one child widget and exposes no bottom
slot, so :func:`mount_dock` shortens that child by the dock's height and puts the dock
in the strip below it. The child is watched rather than the wizard because QWizard
resizes it in its own ``resizeEvent``, after any filter on the wizard has run.
"""
from __future__ import annotations

import json
import os
import queue
import sys
import threading
import traceback

from ..core import local_ai_status as lai
from ..core import state_paths
from . import styles
from .qt import Qt, QtCore, QtGui, QtWidgets, Signal

__all__ = ["LocalAIDock", "LocalWorkWindow", "mount_dock", "dock_height_for"]

POLL_MS = 5000
DRAIN_MS = 120
#: Height of the dock when expanded, capped so the page above stays usable.
EXPANDED_PX = 190
EXPANDED_FRACTION = 0.36
MIN_CLICK_PX = 28
_SETTINGS = "local-ai-dock.json"


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
    try:
        return os.path.join(state_paths.state_dir(), _SETTINGS)
    except Exception:                       # e.g. pytest without an isolated state dir
        return None


def load_expanded() -> bool:
    path = _settings_path()
    try:
        with open(path or "", encoding="utf-8") as fh:
            return bool(json.load(fh).get("expanded", False))
    except (OSError, ValueError, AttributeError):
        return False


def save_expanded(expanded: bool) -> None:
    path = _settings_path()
    if not path:
        return
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"expanded": bool(expanded)}, fh)
    except OSError:
        pass                                # a convenience, never worth a message


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
            if tag in self.in_flight and tag in ("snapshot", "start"):
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


# ── the dock ─────────────────────────────────────────────────────────────────────────
class LocalAIDock(QtWidgets.QFrame):
    """The persistent prompt bar. See the module docstring."""

    layout_changed = Signal()

    def __init__(self, generator_dir: str, parent=None, *, snapshot_fn=None, prompt_fn=None,
                 start_fn=None, poll_ms: int = POLL_MS, auto_poll: bool = True,
                 expanded: bool | None = None, work_window_factory=None):
        super().__init__(parent)
        self.setObjectName("localAIDock")
        self.setFrameShape(QtWidgets.QFrame.Shape.NoFrame)
        self.setAutoFillBackground(True)
        self.generator_dir = generator_dir
        self._snapshot_fn = snapshot_fn or (lambda: lai.read_snapshot())
        self._prompt_fn = prompt_fn or self._default_prompt
        self._start_fn = start_fn or (lambda: lai.start_assistant(generator_dir))
        self._work_factory = work_window_factory
        self._threads = _Threads()
        self._auto_poll = auto_poll
        self.snapshot = None
        self.work_window = None
        self.expanded = load_expanded() if expanded is None else bool(expanded)
        self._history: list = []
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

        # the bar: always visible
        self.bar = QtWidgets.QWidget()
        bar = QtWidgets.QHBoxLayout(self.bar)
        bar.setContentsMargins(0, 0, 0, 0)
        bar.setSpacing(8)
        self.chevron = QtWidgets.QToolButton()
        self.chevron.setAutoRaise(True)
        self.chevron.setMinimumSize(MIN_CLICK_PX, MIN_CLICK_PX)
        self.chevron.clicked.connect(lambda: self.set_expanded(not self.expanded))
        self.chevron.setAccessibleName("Show or hide the local AI prompt")
        self.summary = _ElidedLabel()
        self.summary.setMinimumHeight(MIN_CLICK_PX)
        self.summary.set_full_text("Local AI: reading status…")
        self.start_btn = _styled_button("Start local assistant",
                                        "Start the local Ollama and the queue worker "
                                        "(runs scripts/local-ai.sh start)")
        self.start_btn.clicked.connect(self.start_assistant)
        self.work_btn = _styled_button("Current work",
                                       "Open a window with the queue, the drafts and the running builds")
        self.work_btn.clicked.connect(self.show_current_work)
        bar.addWidget(self.chevron)
        bar.addWidget(self.summary, 1)
        bar.addWidget(self.start_btn)
        bar.addWidget(self.work_btn)
        outer.addWidget(self.bar)

        # the expanded part
        self.body = QtWidgets.QWidget()
        body = QtWidgets.QVBoxLayout(self.body)
        body.setContentsMargins(0, 0, 0, 0)
        body.setSpacing(3)
        self.note = QtWidgets.QLabel("")
        self.note.setWordWrap(True)
        self.note.setStyleSheet(styles.muted())
        self.note.setVisible(False)
        row = QtWidgets.QHBoxLayout()
        row.setSpacing(6)
        self.prompt = QtWidgets.QLineEdit()
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
        self.answer = QtWidgets.QPlainTextEdit()
        self.answer.setReadOnly(True)
        self.answer.setLineWrapMode(QtWidgets.QPlainTextEdit.LineWrapMode.WidgetWidth)
        self.answer.setMinimumHeight(36)
        self.answer.setPlaceholderText("The model's answer appears here.")
        self.answer.setAccessibleName("Answer from the local model")
        body.addWidget(self.note)
        body.addLayout(row)
        body.addWidget(self.answer, 1)
        outer.addWidget(self.body, 1)

        self._drain = QtCore.QTimer(self)
        self._drain.setInterval(DRAIN_MS)
        self._drain.timeout.connect(self._on_drain)
        self._poll = QtCore.QTimer(self)
        self._poll.setInterval(poll_ms)
        self._poll.timeout.connect(self.refresh)
        alive = self._alive
        self.destroyed.connect(lambda *_: alive.set())      # a request outliving its window stops
        self._apply_expanded(notify=False)

    # ---- geometry -------------------------------------------------------------------
    def bar_height(self) -> int:
        return max(MIN_CLICK_PX, self.bar.sizeHint().height()) + 7

    def preferred_height(self, window_height: int) -> int:
        return dock_height_for(window_height, self.expanded, self.bar_height())

    # ---- expand / collapse ----------------------------------------------------------
    def set_expanded(self, on: bool) -> None:
        if bool(on) == self.expanded:
            return
        self.expanded = bool(on)
        save_expanded(self.expanded)
        self._apply_expanded()
        if self.expanded:
            self.prompt.setFocus()

    def _apply_expanded(self, notify: bool = True) -> None:
        self.body.setVisible(self.expanded)
        self.chevron.setArrowType(Qt.ArrowType.DownArrow if self.expanded else Qt.ArrowType.UpArrow)
        self.chevron.setToolTip("Hide the prompt" if self.expanded else "Show the prompt")
        if notify:
            self.layout_changed.emit()

    # ---- polling --------------------------------------------------------------------
    def showEvent(self, event):
        super().showEvent(event)
        self._drain.start()
        if self._auto_poll:
            self._poll.start()
        QtCore.QTimer.singleShot(0, self.refresh)          # after the window is up, not during it

    def hideEvent(self, event):
        super().hideEvent(event)
        self._poll.stop()

    def refresh(self) -> None:
        self._threads.submit("snapshot", self._snapshot_fn)

    def apply_snapshot(self, snap) -> None:
        self.snapshot = snap
        self.summary.set_full_text(snap.summary)
        tip = snap.summary
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
    def _default_prompt(self, text, history, on_chunk, should_stop):
        model = None
        if self.snapshot is not None and self.snapshot.loaded:
            model = self.snapshot.loaded[0]
        return lai.send_prompt(text, model, history=history, on_chunk=on_chunk,
                               should_stop=should_stop)

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

        def work():
            try:
                answer = self._prompt_fn(text, history, lambda c: q.put("chunk", c),
                                     lambda: stop.is_set() or alive.is_set())
                q.put("done", (text, answer))
            except Exception as exc:      # noqa: BLE001 — shown to the person, as a sentence
                q.put("error", str(exc) or exc.__class__.__name__)
        threading.Thread(target=work, name="local-ai-prompt", daemon=True).start()
        return True

    def _send_or_stop(self) -> None:
        if self._busy:
            self._stop.set()
        else:
            self.send()

    def clear(self) -> None:
        self._history.clear()
        self.answer.clear()
        if self._busy:
            self._stop.set()

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
    def start_assistant(self) -> None:
        """Start the local Ollama and the queue worker; never blocks, never a dialog."""
        self.start_btn.setEnabled(False)
        self.start_btn.setText("Starting…")
        self._threads.in_flight.discard("start")
        self._threads.submit("start", self._start_fn)

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
        elif tag == "chunk":
            if not self._answered:
                self._answered = True
                self._say("")
            self._append(value)
        elif tag == "done":
            self._append("\n\n")
            _text, answer = value
            if answer.strip():
                self._history += [{"role": "user", "content": _text},
                                  {"role": "assistant", "content": answer}]
                del self._history[:-40]
            self._finish_prompt()
        elif tag == "error":
            self._append(f"\n[{value}]\n\n")
            self._finish_prompt()
            self._say(str(value), 30, warn=True)
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
    """Add the Local AI dock to a Studio window. Idempotent: a second call returns the
    dock the window already has."""
    existing = getattr(wizard, "local_ai_dock", None)
    if existing is not None:
        return existing
    dock = LocalAIDock(generator_dir, parent=wizard, **kw)
    wizard.local_ai_dock = dock
    wizard._local_ai_mount = _DockMount(wizard, dock)
    wizard._local_ai_mount.relayout()
    dock.show()
    return dock

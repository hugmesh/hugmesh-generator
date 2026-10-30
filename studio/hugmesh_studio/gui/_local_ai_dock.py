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

WHERE THE PERSON IS. ``mount_dock`` connects the wizard's native ``currentIdChanged``
to :meth:`LocalAIDock.on_page_changed`, which maps the page id back to its slug through
``wizard._page_ids`` (a private attribute of gui/wizard.py, which this file must not
edit: accepted, and ``test_the_dock_knows_every_wizard_page_by_its_slug`` fails loudly
if that map ever stops covering ``pageIds()``). A window with no such signal (the
Fleet window, the standalone local-mesh dialog) announces the slug ``mount_dock`` was
given as ``page_slug``. The domain and tab on screen are re-read at use time from the
page's own ``current_domain()`` and ``brand_tabs.bar``, never cached: "Next domain"
does not change the page id. A ``Tip: ...`` for the page sits in the collapsed bar and
above the answer area (core/assistant_tips: curated, no model needed; a running model
may replace it with one sentence for the same page). Every question goes out with the
primer, the page facts, the page's options and the docs snippets (core/assistant_prompt);
the answer gets a Sources footer, and a proposed setting change or code edit becomes an
inline card with Apply / Cancel and then Undo / Revert — applied through the page's own
functions (core/assistant_actions, core/assistant_code_edits), never without the press.
"""
from __future__ import annotations

import html
import os
import queue
import sys
import threading
import time
import traceback
import weakref

from ..core import agent_context as actx
from ..core import assistant_actions as aact
from ..core import assistant_catalogue as acat
from ..core import assistant_code_edits as aedit
from ..core import assistant_context as actxt
from ..core import assistant_docs as adocs
from ..core import assistant_prompt as aprompt
from ..core import assistant_settings
from ..core import assistant_tips as atips
from ..core import local_ai_status as lai
from ..core import ollama_docker as odk
from ..core import plain_words
from . import styles
from .qt import Qt, QtCore, QtGui, QtWidgets, Signal

__all__ = ["LocalAIDock", "LocalWorkWindow", "PanelWindow", "mount_dock", "dock_height_for",
           "TABS"]

POLL_MS = 5000
#: How many lines of a running image build's log the Image builds tab shows.
BUILD_TAIL_LINES = 400
_TAIL_BYTES = 64 * 1024
DRAIN_MS = 120
#: Height of the dock when expanded, capped so the page above stays usable. The panel
#: shows tabs of real content now, so it may take a little more than the prompt bar did;
#: the full-size view is the popped-out window.
EXPANDED_PX = 280
EXPANDED_FRACTION = 0.38
#: While the local-mesh Bring-up step is on screen the page itself holds only a note
#: (its actions, table and log are in the panel), so the panel may take this share of
#: the window instead. The page's title, note and the wizard's buttons keep the rest.
TALL_FRACTION = 0.62
MIN_CLICK_PX = 28
#: How long a page must have been on screen before the model is asked for a tip.
MODEL_TIP_SETTLE_S = 4.0
_SETTINGS = assistant_settings.FILE_NAME
#: Tabs that get the TALL height while they are open in the docked panel. The Running
#: mesh tab holds the pod table (at least six rows), the domain strip and the Tor list;
#: at the usual 280 px cap only five rows showed and the strip and the Tor list were
#: below the fold (2026-10-21 round 2: "the docked Running mesh tab shows the domain
#: strip, Tor list and at least 6 rows at the default docked size").
TALL_TABS = ("pods",)
#: The panel's tabs, in order: (key, label).
TABS = (("assistant", "Assistant"), ("mesh", "Local mesh"), ("pods", "Running mesh"),
        ("run", "Mesh run"), ("builds", "Image builds"))


def _log_swallowed(where: str) -> None:
    print(f"local-ai dock: swallowed exception in {where}", file=sys.stderr)
    traceback.print_exc(file=sys.stderr)


def plain(label: "QtWidgets.QLabel") -> "QtWidgets.QLabel":
    """``label`` shows its text as written. Qt's default (AutoText) reads text that
    looks like markup as rich text, so a card quoting a file's ``<body>`` line showed
    "the file says ''" (PR #832 review); every label that shows model, file or log
    text goes through here."""
    label.setTextFormat(Qt.TextFormat.PlainText)
    return label


def plain_tip(text: str) -> str:
    """A tooltip that shows ``text`` as written: tooltips have no text format of their
    own and read markup-looking text as rich text, so such text is escaped."""
    text = text or ""
    if "<" not in text and "&" not in text:
        return text
    return "<p style='white-space:pre-wrap'>" + html.escape(text) + "</p>"


def dock_height_for(window_height: int, expanded: bool, bar_px: int,
                    tall: bool = False) -> int:
    """How tall the dock may be in a window of ``window_height`` — a pure function so
    the cap is testable for window sizes this host does not have. ``tall``: the page
    above has nothing but a note to show (the Bring-up step)."""
    if not expanded:
        return bar_px
    if tall:
        return max(bar_px + 76, int(window_height * TALL_FRACTION))
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
        plain(self)

    def set_full_text(self, text: str) -> None:
        self._full = text
        self.setToolTip(plain_tip(text))
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
        self._generator_dir = generator_dir
        self._set_commands()
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

    def _set_commands(self) -> None:
        """The run-it-yourself line, for the Ollama the assistant uses NOW (Docker mode
        puts that instance's OLLAMA_HOST in front of each command)."""
        try:
            cmds = odk.commands_for(self._generator_dir)
        except Exception:                        # noqa: BLE001 — a label never raises
            cmds = lai.commands(self._generator_dir)
        self.commands.setText(
            "Run it yourself in a terminal:  " + cmds["start"] + "   |   queue issues and watch:  "
            + cmds["todo"] + "   |   chat:  " + cmds["chat"])

    def show_snapshot(self, snap) -> None:
        """Render a snapshot now (the dock hands over the one it already has)."""
        self._set_commands()
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
        self.tall = False
        #: what the page asked for (set_tall); ``tall`` also follows the open tab
        self._page_tall = False
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
        # THE TIP for the page the person is on (core/assistant_tips). Hidden, it and
        # its button take no width and the activity line regains the space.
        self.tip = _ElidedLabel()
        self.tip.setObjectName("assistant_tip")
        self.tip.setMinimumHeight(MIN_CLICK_PX)
        self.tip.setStyleSheet(styles.muted())
        self.tip_hide = QtWidgets.QToolButton()
        self.tip_hide.setText("\u00d7")
        self.tip_hide.setToolTip("Hide tips")
        self.tip_hide.setAccessibleName("Hide tips")
        self.tip_hide.setAutoRaise(True)
        self.tip_hide.setFixedSize(MIN_CLICK_PX, MIN_CLICK_PX)
        self.tip_hide.clicked.connect(lambda: self.set_tips_hidden(True))
        bar.addWidget(self.chevron)
        bar.addWidget(self.summary, 3)
        bar.addWidget(self.activity, 2)
        bar.addWidget(self.tip, 3)
        bar.addWidget(self.tip_hide)
        bar.addWidget(self.start_btn)
        bar.addWidget(self.work_btn)
        bar.addWidget(self.pop_btn)
        outer.addWidget(self.bar)
        # page awareness (see the module docstring): set by on_page_changed / mount_dock
        self._wizard_ref = None
        self._page_slug = ""
        self._page_title = ""
        self._page_subtitle = ""
        self._page_id = None
        self._tip_text = ""
        self._tip_born = None                   # (clears, slug, domain) of the tip request in flight
        self._tip_asked: dict = {}               # (slug, domain) -> when the model was last asked
        self._last_prompt: dict = {}             # born -> the Prompt behind the answer in flight
        self._card = None                        # the one proposal / diff card
        self._undo: dict = {}                    # assistant_actions.undo_key -> Applied (one level per domain)
        self._applied_edit = None                # the last code edit (for Revert)
        self._rotation = atips.TipRotation()

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
        self.note = plain(QtWidgets.QLabel(""))
        self.note.setWordWrap(True)
        self.note.setStyleSheet(styles.muted())
        self.note.setVisible(False)
        tip_row = QtWidgets.QHBoxLayout()
        tip_row.setSpacing(4)
        self.tip_line = plain(QtWidgets.QLabel(""))
        self.tip_line.setObjectName("assistant_tip_line")
        self.tip_line.setWordWrap(True)
        self.tip_line.setStyleSheet(styles.muted())
        self.tip_line.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        self.tip_hide2 = QtWidgets.QToolButton()
        self.tip_hide2.setText("\u00d7")
        self.tip_hide2.setToolTip("Hide tips")
        self.tip_hide2.setAccessibleName("Hide tips")
        self.tip_hide2.setAutoRaise(True)
        self.tip_hide2.setFixedSize(MIN_CLICK_PX, MIN_CLICK_PX)
        self.tip_hide2.clicked.connect(lambda: self.set_tips_hidden(True))
        tip_row.addWidget(self.tip_line, 1)
        tip_row.addWidget(self.tip_hide2, 0, Qt.AlignmentFlag.AlignTop)
        self.tip_row = QtWidgets.QWidget()
        self.tip_row.setLayout(tip_row)
        tip_row.setContentsMargins(0, 0, 0, 0)
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
        chat_lay.addWidget(self.tip_row)
        chat_lay.addLayout(row)
        chat_lay.addWidget(self.answer, 1)
        # the one card for a proposed change or code edit (none until an answer has one)
        self.card_host = QtWidgets.QVBoxLayout()
        self.card_host.setContentsMargins(0, 0, 0, 0)
        chat_lay.addLayout(self.card_host)

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

        self.tips_show_btn = _styled_button("Show tips", "Show the tip for each page again")
        self.tips_show_btn.setFlat(True)
        self.tips_show_btn.clicked.connect(lambda: self.set_tips_hidden(False))
        self.tips_show_btn.setVisible(False)
        opt.addWidget(self.tips_show_btn)

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
        self.builds_tree.setColumnWidth(0, 210)        # the tree shares the tab with the log
        self.builds_tree.currentItemChanged.connect(lambda *_: self._on_build_picked())
        brow = QtWidgets.QHBoxLayout()
        self.build_show_btn = _styled_button("Show this build",
                                             "Bring the window that is running it to the front")
        self.build_show_btn.clicked.connect(self.show_selected_build)
        self.builds_note = QtWidgets.QLabel("")
        self.builds_note.setWordWrap(True)
        self.builds_note.setStyleSheet(styles.muted())
        brow.addWidget(self.build_show_btn)
        brow.addWidget(self.builds_note, 1)
        # THE RUNNING BUILD ITSELF, at the bottom of the window: the last lines of the
        # picked build's log, read from its build.log once a second while this tab is
        # on screen. The full view (stages, packages, flash) stays in the build's own
        # window ("Show this build"); this is the live tail, never a second runner.
        self.build_log_title = QtWidgets.QLabel("")
        self.build_log_title.setWordWrap(True)
        self.build_log_title.setStyleSheet(styles.muted())
        self.build_log_title.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse)
        self.build_log = QtWidgets.QPlainTextEdit()
        self.build_log.setReadOnly(True)
        self.build_log.setLineWrapMode(QtWidgets.QPlainTextEdit.LineWrapMode.NoWrap)
        self.build_log.setMaximumBlockCount(BUILD_TAIL_LINES)
        self.build_log.setMinimumHeight(60)
        self.build_log.setAccessibleName("Last lines of the picked build's log")
        self.build_log.setPlaceholderText("Pick a running build above to follow its log here.")
        self._tail_key = None                    # (path, size, mtime) last shown
        self._tail_pick = None                   # the row whose log is shown
        self._tail_follow = True                 # keep the newest line in view
        self.build_log.verticalScrollBar().actionTriggered.connect(self._on_tail_scrolled)
        self.builds_split = QtWidgets.QSplitter(Qt.Orientation.Horizontal)
        self.builds_split.setChildrenCollapsible(False)
        left = QtWidgets.QWidget()
        ll = QtWidgets.QVBoxLayout(left)
        ll.setContentsMargins(0, 0, 0, 0)
        ll.addWidget(self.builds_tree, 1)
        ll.addLayout(brow)
        right = QtWidgets.QWidget()
        rl = QtWidgets.QVBoxLayout(right)
        rl.setContentsMargins(0, 0, 0, 0)
        rl.addWidget(self.build_log_title)
        rl.addWidget(self.build_log, 1)
        self.builds_split.addWidget(left)
        self.builds_split.addWidget(right)
        self.builds_split.setStretchFactor(0, 2)
        self.builds_split.setStretchFactor(1, 3)
        bl.addWidget(self.builds_split, 1)
        self._add_tab("builds", builds)

        last = str(assistant_settings.get("tab", "assistant") or "assistant")
        self.tabs.setCurrentIndex(self._tab_index.get(last, 0))
        self.tabs.currentChanged.connect(self._on_tab_changed)
        self._sync_tall()                 # a remembered Running mesh tab opens tall

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
        self._apply_tips_hidden(bool(assistant_settings.get("tips_hidden", False)))
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
        h = dock_height_for(window_height, self.expanded and not self.popped,
                            self.bar_height(), self.tall)
        if self.expanded and not self.popped:
            h = max(h, self.card_need())
        return h

    def _note_shown(self) -> bool:
        return bool(self.note.text()) and not self.note.isHidden()

    def card_need(self) -> int:
        """How tall the docked panel must be to show the whole card (its text and its
        button row) and the whole note line above a 36 px answer area, or 0 with no
        card and no note on the Assistant tab. The usual cap (38 % of the window) has no
        room for a card at the netbook default 942x552: its Apply / Close / Undo row
        fell below the window edge (PR #832 review); nor for a long note, such as the
        native Windows start refusal, which showed 41 of its 140 px there (round 4).
        While either is up the panel grows to fit it; _DockMount still leaves the page
        at least 120 px."""
        card = self._card
        if self.current_tab() != "assistant" or (card is None and not self._note_shown()):
            return 0
        try:
            chat = card.parentWidget() if card is not None else self.note.parentWidget()
            if chat is None:
                return 0
            if self.body.isVisible() and chat.isVisible():
                top = chat.mapTo(self, QtCore.QPoint(0, 0)).y()
            else:
                m = self._outer.contentsMargins()
                top = (m.top() + self.bar.sizeHint().height() + self._outer.spacing()
                       + self.tabs.tabBar().sizeHint().height())
            need = chat.minimumSizeHint().height()
            if self.note.isVisibleTo(chat) and self.note.text():
                # a wrapped label's minimum is one line; what it shows is its full height
                w = max(50, self.note.width())
                need += max(0, self.note.heightForWidth(w) - self.note.minimumSizeHint().height())
            return top + need + self._outer.contentsMargins().bottom() + 2
        except RuntimeError:                     # a card on its way out
            return 0

    def _card_resized(self) -> None:
        """The card's height changed (a longer status, a new width): place the panel
        again on the next turn of the event loop. Synchronously it would land inside
        _DockMount.relayout, which ignores a call made while it is placing."""
        if getattr(self, "_card_relayout_due", False):
            return
        self._card_relayout_due = True

        def again():
            try:
                self._card_relayout_due = False
                self.layout_changed.emit()
            except RuntimeError:                 # the dock was destroyed first
                pass
        QtCore.QTimer.singleShot(0, again)

    def set_tall(self, on: bool) -> None:
        """Let the panel take most of the window (the Bring-up step is on screen) or go
        back to its usual cap. The panel is ALSO tall while a ``TALL_TABS`` tab is
        open, whatever the page says: ``_sync_tall`` is the one writer of ``tall``."""
        self._page_tall = bool(on)
        self._sync_tall()

    def _sync_tall(self) -> None:
        want = bool(getattr(self, "_page_tall", False)) or self.current_tab() in TALL_TABS
        if want == self.tall:
            return
        self.tall = want
        self.layout_changed.emit()

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
            if self._card is not None:
                # the body was just shown or moved: card_need() measured it before its
                # layout ran, so place the panel once more when it has
                self._card_resized()

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
            self._sync_tall()
            if self._card is not None:
                self.layout_changed.emit()        # the card's height counts on one tab only
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
            page.attach_dock(self.show_tab, self.set_tall)
            page.completeChanged.connect(self._on_mesh_changed)
        except Exception:
            _log_swallowed("LocalAIDock.attach_mesh_page")
        if self.agent_card is not None:
            from .pages import _local_agent_widget as law
            law.follow_page(self.agent_card, page)
        self.refresh_activity()
        self.refresh_tip()
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
            self.refresh_tip()
            if self.current_tab() == "builds" or self.builds_tree.topLevelItemCount() != (
                    len(builds) + (1 if mesh_running else 0)):
                self._fill_builds(builds, mesh_running, mesh_label)
            if self.current_tab() == "builds":
                self.refresh_build_tail()
        except RuntimeError:                     # a widget deleted under us at teardown
            pass
        except Exception:
            _log_swallowed("LocalAIDock.refresh_activity")

    def _fill_builds(self, builds, mesh_running: bool, mesh_label: str) -> None:
        keep = self.builds_tree.currentItem().data(0, Qt.ItemDataRole.UserRole) \
            if self.builds_tree.currentItem() else None
        # rebuilt in silence: the pick is re-read ONCE at the end (_on_build_picked), so
        # the clear in between is not taken for "nothing picked"
        self.builds_tree.blockSignals(True)
        try:
            self._fill_builds_rows(builds, mesh_running, mesh_label, keep)
        finally:
            self.builds_tree.blockSignals(False)
        self.builds_note.setText(
            "" if self.builds_tree.topLevelItemCount() else
            "Nothing is building. An image build started from any Studio window, and a "
            "local-mesh verb, are listed here while they run; closing a window or this "
            "panel never stops one.")
        self._on_build_picked()

    def _fill_builds_rows(self, builds, mesh_running: bool, mesh_label: str, keep) -> None:
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

    def _on_build_picked(self) -> None:
        """Another row was picked. The list is rebuilt every second while the tab is on
        screen, which re-picks the same row: that is not a new pick, and the log is
        re-read only when its file changed (refresh_activity -> refresh_build_tail)."""
        self._sync_builds_buttons()
        item = self.builds_tree.currentItem()
        key = item.data(0, Qt.ItemDataRole.UserRole) if item is not None else None
        if key != self._tail_pick:
            self._tail_pick = key
            self._tail_key = None
            self._tail_follow = True
            self.refresh_build_tail()

    def _picked_build_log(self) -> "tuple[str, str]":
        """``(log path, words for the title)`` of the picked row; path "" = nothing to
        follow, and the words say why."""
        item = self.builds_tree.currentItem()
        key = str(item.data(0, Qt.ItemDataRole.UserRole) or "") if item is not None else ""
        if not key:
            return "", ""
        if key == "mesh:":
            return "", ("The local mesh's own run log is on the Mesh run tab "
                        "(\u201cShow this build\u201d opens it).")
        from . import build_supervisor
        b = build_supervisor.supervisor().find(key[len("build:"):])
        if b is None:
            return "", "That build is no longer running."
        path = getattr(b, "log_path", "") or (
            os.path.join(b.workdir, "build.log") if getattr(b, "workdir", "") else "")
        if not path:
            return "", f"{b.label}: this build has no log file to follow."
        return path, f"{b.label} \u2014 last lines of {path}"

    def _tail_to_end(self) -> None:
        # QPlainTextEdit lays text out lazily, so the scroll range grows after the set:
        # move now and once more when the layout has caught up.
        self.build_log.moveCursor(QtGui.QTextCursor.MoveOperation.End)
        bar = self.build_log.verticalScrollBar()
        bar.setValue(bar.maximum())

        def again():
            try:
                if self._tail_follow:
                    bar.setValue(bar.maximum())
            except RuntimeError:
                pass
        QtCore.QTimer.singleShot(0, again)

    def _on_tail_scrolled(self, *_a) -> None:
        """The person moved the log's scroll bar: follow the end only while it is there."""
        def look():
            try:
                bar = self.build_log.verticalScrollBar()
                self._tail_follow = bar.value() >= bar.maximum() - 2
            except RuntimeError:
                pass
        QtCore.QTimer.singleShot(0, look)

    def refresh_build_tail(self) -> None:
        """Show the last lines of the picked build's log. Reads at most 64 KB from the
        end of the file, and only when its size or time changed."""
        try:
            path, words = self._picked_build_log()
            self.build_log_title.setText(words)
            if not path:
                if self._tail_key is not None or self.build_log.toPlainText():
                    self.build_log.clear()
                self._tail_key = None
                return
            try:
                st = os.stat(path)
            except OSError:
                self.build_log_title.setText(words + " (not written yet)")
                self.build_log.clear()
                self._tail_key = None
                return
            key = (path, st.st_size, st.st_mtime_ns)
            if key == self._tail_key:
                return
            self._tail_key = key
            with open(path, "rb") as fh:
                fh.seek(max(0, st.st_size - _TAIL_BYTES))
                data = fh.read(_TAIL_BYTES)
            lines = data.decode("utf-8", "replace").splitlines()
            if st.st_size > _TAIL_BYTES and lines:
                lines = lines[1:]                # the first one was cut in the middle
            bar = self.build_log.verticalScrollBar()
            was = bar.value()
            self.build_log.setPlainText("\n".join(lines[-BUILD_TAIL_LINES:]))
            # follow the end unless the person scrolled up to read something
            if self._tail_follow:
                self._tail_to_end()
            else:
                bar.setValue(min(was, bar.maximum()))
        except RuntimeError:                     # a widget deleted under us at teardown
            pass
        except Exception:
            _log_swallowed("LocalAIDock.refresh_build_tail")

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
        # the page half of "where", read HERE on the window thread (widgets); the state
        # half (files) is collected on the worker below
        where = self._page_where(question=text) if default else None
        if where is not None:
            try:                                # the values on screen, through Apply's own readers
                where = where.with_page(current=aact.current_values(self._target_for(where)))
            except Exception:                   # noqa: BLE001 — "current:" is a help, never a crash
                _log_swallowed("LocalAIDock.current_values")
        code = self._code_context(where, text) if default else None
        self._stop_tip()                        # the model answers one thing at a time

        def work():
            try:
                chunk = lambda c: q.put("chunk", (born, c))          # noqa: E731
                stopping = lambda: stop.is_set() or alive.is_set()     # noqa: E731
                if default:
                    answer = self._grounded_prompt(text, history, chunk, stopping, env=env,
                                                   where=where, born=born, code=code)
                else:
                    answer = self._prompt_fn(text, history, chunk, stopping)
                q.put("done", (born, text, answer))
            except Exception as exc:      # noqa: BLE001 — shown to the person, as a sentence
                q.put("error", (born, str(exc) or exc.__class__.__name__))
        threading.Thread(target=work, name="local-ai-prompt", daemon=True).start()
        return True

    def _grounded_prompt(self, text, history, on_chunk, should_stop, *, env, where, born,
                         code=None):
        """The default prompt, grounded: collect the state rows (files only, 1 s each),
        build the Prompt, keep it for the footer, then ask the model. Worker thread."""
        state_dir = self._state_dir()
        collectors = [("build", lambda: actxt.build_rows(state_dir)),
                      ("local mesh log", lambda: actxt.mesh_rows(state_dir)),
                      ("assistant", lambda: actxt.assistant_rows(env))]
        ctx = code.get("ctx") if code else None
        if ctx is not None and getattr(ctx, "mesh", ""):
            collectors.append(("code folders", lambda: actxt.code_rows(
                self.generator_dir, ctx.source_mode, ctx.source_dir, ctx.domain_rows, ctx.mesh,
                state_root=state_dir)))
        rows = actxt.collect(collectors)
        where = where.with_state(rows)
        files_block = ""
        if code and code.get("workspace") is not None:
            ws = code["workspace"]
            if code.get("files"):
                parts = []
                for rel in code["files"]:
                    body, why = aedit.file_text(ws, rel)
                    parts.append(f"[file: {rel} in {ws.name}]\n" + (body if not why else f"({why})"))
                files_block = "\n\n".join(parts)
            elif code.get("wants_edit"):
                files_block = (f"[code folder {ws.name} at {ws.path}; the person named no "
                               "file — ask which file to change]")
        prompt = aprompt.build(text, where, history, env=env, generator_dir=self.generator_dir,
                               files_block=files_block)
        self._last_prompt[born] = prompt
        return lai.send_prompt(text, env=env, history=prompt.history, system=prompt.system,
                               on_chunk=on_chunk, should_stop=should_stop)

    def _state_dir(self) -> str:
        try:
            from ..core import state_paths
            return state_paths.state_dir()
        except Exception:                       # noqa: BLE001 — no state dir: no state rows
            return ""

    def _send_or_stop(self) -> None:
        if self._busy:
            self._stop.set()
        else:
            self.send()

    def clear(self) -> None:
        self._clears += 1
        self._history.clear()
        self.answer.clear()
        self._last_prompt.clear()
        self._undo.clear()
        self._applied_edit = None
        self._drop_card()
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

    # ---- where the person is -----------------------------------------------------------
    def set_page_slug(self, slug: str, title: str = "", subtitle: str = "") -> None:
        """A window with no page signal names its one page (fleet, localmesh)."""
        self._page_slug = slug or ""
        self._page_title = title or atips.TIPS.get(slug, ("",))[0][:0] or slug.replace("_", " ").title()
        self._page_subtitle = subtitle or ""
        self.refresh_tip(force=True)

    def on_page_changed(self, page_id) -> None:
        """The wizard turned to ``page_id``: remember its slug and title; the tip follows."""
        try:
            wiz = self._wizard_ref() if self._wizard_ref is not None else None
            if wiz is None:
                return
            ids = getattr(wiz, "_page_ids", {}) or {}
            slug = {v: k for k, v in ids.items()}.get(page_id, "")
            page = wiz.page(page_id) if page_id is not None and page_id >= 0 else None
            self._page_id = page_id
            self._page_slug = slug
            self._page_title = (page.title() if page is not None else "") or slug.replace("_", " ").title()
            self._page_subtitle = page.subTitle() if page is not None else ""
            self._stop_tip()
            self._drop_card()                     # a proposal is about the page it was made on
            self.refresh_tip(force=True)
        except RuntimeError:
            pass
        except Exception:
            _log_swallowed("LocalAIDock.on_page_changed")

    def _page_body(self):
        """The domain-services body on screen, or None: the Docker route's step holds
        the local-mesh page's widget; the image route's page IS the body."""
        slug = self._page_slug
        if slug == "localmesh_domain_services" and self.mesh_page is not None:
            return getattr(self.mesh_page, "domain_services", None)
        if slug == "domain_services":
            wiz = self._wizard_ref() if self._wizard_ref is not None else None
            if wiz is not None and self._page_id is not None:
                page = wiz.page(self._page_id)
                if page is not None and hasattr(page, "current_domain") and hasattr(page, "brand_tabs"):
                    return page
        return None

    def _page_where(self, question: str = "") -> "actxt.Where":
        """The PAGE half of ``Where``: attribute reads only (window thread)."""
        slug = self._page_slug
        wiz = self._wizard_ref() if self._wizard_ref is not None else None
        cfg = getattr(wiz, "cfg", None) if wiz is not None else None
        mode = str(getattr(cfg, "mode", "") or "") if cfg is not None else ""
        route = "image"
        if slug.startswith("localmesh") or (self.mesh_page is not None and slug in ("", "localmesh")):
            mode, route = "docker", "docker"
        elif slug == "fleet":
            route = "fleet"
        step_index = step_total = 0
        try:
            from ..core.config import MODE_SKIPPED_PAGES
            ids = getattr(wiz, "_page_ids", {}) if wiz is not None else {}
            skipped = set(MODE_SKIPPED_PAGES.get(mode, ())) if mode in MODE_SKIPPED_PAGES else set()
            visited = [k for k in ids if k not in skipped]
            if route == "docker":
                visited = [k for k in visited if k.startswith("localmesh")]
            elif route == "image":
                visited = [k for k in visited if not k.startswith("localmesh")]
            if slug in visited:
                step_index, step_total = visited.index(slug) + 1, len(visited)
        except Exception:                       # noqa: BLE001 — a step number is decoration
            pass
        domain, own, tab = "", False, ""
        body = self._page_body()
        if body is not None:
            try:
                domain = body.current_domain() or ""
                view = getattr(getattr(body, "brand_tabs", None), "view", None)
                own = bool(getattr(view, "own", False)) if view is not None else False
                bar = getattr(getattr(body, "brand_tabs", None), "bar", None)
                if bar is not None:
                    tab = {0: "identity", 1: "look", 2: "services", 3: "ways"}.get(bar.currentIndex(), "")
            except Exception:                   # noqa: BLE001
                pass
        brand, domains, activity = (), (), []
        try:
            if route == "docker" and self.mesh_page is not None:
                md = getattr(self.mesh_page, "mesh_domains", None)
                own_name = str(getattr(md, "own_name", "") or "")
                domains = actxt.domain_rows_from(getattr(md, "domains", ()) or (), own_name=own_name)
                block = {}
                fn = getattr(self.mesh_page, "_superbrand_block", None)
                if callable(fn):
                    block = fn() or {}
                combo = getattr(self.mesh_page, "brand", None)
                brand = actxt.brand_rows_from(block or {"id": combo.currentText().strip() if combo else ""})
            elif cfg is not None:
                domains = actxt.domain_rows_from(getattr(cfg, "domains", ()) or ())
                brand = actxt.brand_rows_from({"id": getattr(cfg, "brand", ""),
                                               "title": getattr(cfg, "brand_title", "")})
            page = self.mesh_page
            if page is not None:
                up = getattr(page, "_mesh_up", None)
                running = bool(getattr(page, "_running", False))
                label = str(getattr(page, "_running_label", "") or "")
                activity.append(("local mesh", "up" if up else ("down" if up is False else "not checked")))
                activity.append(("running now", label or "a verb" if running else "nothing"))
            builds = self._running_builds()
            if builds:
                activity.append(("builds running", ", ".join(getattr(b, "label", "?") for b in builds)))
        except Exception:                       # noqa: BLE001 — facts, never a crash
            pass
        return actxt.Where(face="gui", slug=slug, title=self._page_title, subtitle=self._page_subtitle,
                           mode=mode or "docker", step_index=step_index, step_total=step_total,
                           domain=domain, own_domain=own, tab=tab, route=route, brand=brand,
                           domains=domains, activity=tuple(actxt.scrub_rows(activity)),
                           question=question)

    def _target_for(self, where):
        """The apply target for the page on screen (window thread), or None."""
        body = self._page_body()
        if body is not None:
            return aact.GuiTabsTarget(body)
        if where.slug in acat.MESH_PAGES and self.mesh_page is not None:
            return aact.MeshTarget(self.mesh_page)
        return None

    def _code_context(self, where, question: str) -> dict:
        """What a code-edit question needs: the domain's workspace (if any) and the files
        it names. Reads the agent context (widgets) here; the folder walk is small."""
        out: dict = {"ctx": None, "workspace": None, "files": [], "wants_edit": False}
        try:
            ctx = self._agent_context()
            out["ctx"] = ctx
            low = question.lower()
            wants = any(w in low for w in ("change", "edit", "replace", "rename", "fix", "update",
                                            "set the", "make the", "footer", "text in", ".html",
                                            ".css", ".ts", ".md", ".json"))
            out["wants_edit"] = wants
            if not wants or not getattr(ctx, "mesh", "") or not where.domain:
                return out
            spaces = aedit.find_workspaces(self.generator_dir, ctx.source_mode, ctx.source_dir,
                                           ctx.domain_rows, ctx.mesh, state_root=self._state_dir(),
                                           only_domain=where.domain)
            if not spaces:
                return out
            named = [ws for ws in spaces if aedit.files_mentioned(question, ws)]
            ws = named[0] if named else spaces[0]
            out["workspace"] = ws
            out["files"] = aedit.files_mentioned(question, ws)
        except Exception:                       # noqa: BLE001
            _log_swallowed("LocalAIDock._code_context")
        return out

    # ---- the tip -------------------------------------------------------------------------
    def set_tips_hidden(self, hidden: bool) -> None:
        assistant_settings.update(tips_hidden=bool(hidden))
        self._apply_tips_hidden(bool(hidden))
        self.layout_changed.emit()

    def tips_hidden(self) -> bool:
        return not self.tip.isVisibleTo(self) if hasattr(self, "tip") else False

    def _apply_tips_hidden(self, hidden: bool) -> None:
        for w in (self.tip, self.tip_hide):
            w.setVisible(not hidden)
        # the expanded tip line steps aside while a card is up (the bar above keeps the
        # tip): at 1024x700 the two together pushed the card's buttons off the window
        self.tip_row.setVisible(not hidden and getattr(self, "_card", None) is None)
        self.tips_show_btn.setVisible(hidden)

    def _set_tip_text(self, text: str, model: bool = False) -> None:
        # the strip is a brand screen too: a word the screens never show stays off it
        low = (text or "").lower()
        if any(w in low for w in plain_words.FORBIDDEN_ON_SCREENS):
            text = ""
        self._tip_text = text
        self.tip.set_full_text(("Tip: " + text) if text else "")
        self.tip_line.setText(("Tip: " + text) if text else "")
        if model:
            self.tip.setToolTip(plain_tip("Tip: " + text + "\n(from the local model)"))

    def refresh_tip(self, force: bool = False) -> None:
        """The curated tip for the page on screen (a dict lookup); then, when a model is
        loaded and the dock is idle, one request for a better sentence."""
        try:
            where = self._page_where()
            if not where.slug and not force:
                return
            text = atips.tip_for(where, rotation=self._rotation) if where.slug else ""
            key = (where.slug, where.domain, where.tab)
            if force or key != getattr(self, "_tip_key", None):
                self._tip_key = key
                self._page_since = time.monotonic()
                self._set_tip_text(text)
                if force:
                    assistant_settings.update(last_tip_slug=where.slug)
            self._maybe_model_tip(where)
        except RuntimeError:
            pass
        except Exception:
            _log_swallowed("LocalAIDock.refresh_tip")

    def _maybe_model_tip(self, where) -> None:
        """One request for a model-written tip, and only when the person has settled on
        a page: a loaded model, the dock idle and visible, nothing in flight, the same
        page for MODEL_TIP_SETTLE_S, and not again for the same page and domain within
        ten minutes. The curated tip is already on screen either way."""
        snap = self.snapshot
        if (self._busy or self._tip_born is not None or snap is None or not snap.ok
                or not snap.loaded or not where.slug or self.tips_hidden()
                or not self.isVisible()
                or time.monotonic() - getattr(self, "_page_since", 0.0) < MODEL_TIP_SETTLE_S):
            return
        key = (where.slug, where.domain)
        last = self._tip_asked.get(key, 0.0)
        if time.monotonic() - last < 600:
            return
        self._tip_asked[key] = time.monotonic()
        born = (self._clears, where.slug, where.domain)
        self._tip_born = born
        env = self._env()
        alive = self._alive
        dock = weakref.ref(self)

        def changed() -> bool:
            d = dock()
            if d is None or alive.is_set():
                return True
            try:
                return d._tip_born != born
            except RuntimeError:
                return True
        self._threads.submit("tip", atips.model_tip, where, env, should_stop=changed,
                             generator_dir=self.generator_dir)

    def _stop_tip(self) -> None:
        self._tip_born = None

    # ---- cards: a proposed change or code edit ------------------------------------------
    def _drop_card(self) -> None:
        if self._card is not None:
            self.card_host.removeWidget(self._card)
            self._card.setParent(None)
            self._card.deleteLater()
            self._card = None
            self._apply_tips_hidden(not self.tip_hide.isVisibleTo(self))
            self.layout_changed.emit()

    def _show_card(self, card) -> None:
        self._drop_card()
        self._card = card
        self.card_host.addWidget(card)
        self.tip_row.setVisible(False)
        card.show()
        card._fit()
        self.layout_changed.emit()

    def _offer_card(self, answer: str, question: str, prompt) -> None:
        """A ```change block becomes a proposal card; a ```diff block a diff card."""
        try:
            where = prompt.where if prompt is not None else self._page_where(question)
            proposal = aact.parse_proposal(answer, question)
            if proposal is not None:
                target = self._target_for(where)
                where = where.with_page(question=question)
                v = aact.validate(proposal, where, target)
                self._show_card(_ProposalCard(self, v, where, target))
                return
            if "```diff" in answer:
                self._offer_diff(answer, question, where)
            elif "```change" in answer:
                self._append(aact.NO_BLOCK_HINT + "\n\n")
        except Exception:
            _log_swallowed("LocalAIDock._offer_card")

    def _offer_diff(self, answer: str, question: str, where) -> None:
        code = self._code_context(where, question)
        ws = code.get("workspace")
        if ws is None:
            self._append("That domain has no code folder yet; the Code folders block on the "
                         "page makes one.\n\n")
            return
        reason = aedit.too_big_reason(question)
        if reason:
            self._handoff(question, reason)
            return
        edits = aedit.parse_diff(answer, ws)
        if isinstance(edits, aedit.DiffProblem):
            self._append(f"Not applied: {edits.text}\n\n")
            return
        reason = aedit.too_big_reason(question, edits)
        if reason:
            self._handoff(question, reason)
            return
        self._show_card(_DiffCard(self, ws, edits))

    def _handoff(self, question: str, reason: str) -> None:
        self._append(aedit.handoff_text(reason) + "\n\n")
        if self.agent_card is not None:
            try:
                self.agent_card.set_first_task(question)
            except Exception:                   # noqa: BLE001
                _log_swallowed("LocalAIDock._handoff")

    def open_diff_viewer(self, text: str) -> None:
        """Show a diff in the Current work window's viewer (non-modal)."""
        win = self.show_current_work()
        try:
            win.diff_view.setPlainText(text)
        except Exception:                       # noqa: BLE001
            pass

    # ---- the buttons ----------------------------------------------------------------
    def _worker_env(self, ctx) -> dict:
        """What the queue worker is started with beyond the Ollama address: the checkouts
        folder (draft.sh's HUGMESH_REPOS_ROOT) and the project-context file its agents
        read (HUGMESH_AGENT_CONTEXT, written fresh here with this mesh's domains, and
        written again by draft.sh before each agent). The same core call the shell's
        `local-ai.sh start` makes when the text UI or a terminal starts the worker.
        Runs on the start thread."""
        env = self._env()
        return actx.worker_env(self.generator_dir, ollama=odk.describe(self.ollama_mode),
                               source_mode=ctx.source_mode, source_dir=ctx.source_dir,
                               rows=ctx.domain_rows, mesh=ctx.mesh, environ=env)

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
                prompt = self._last_prompt.pop(born, None)
                if answer.strip() and not self._answered:
                    self._append(answer)             # a prompt that did not stream still shows
                if answer.strip():
                    # history keeps the BARE answer; the footer is shown, never remembered
                    self._history += [{"role": "user", "content": _text},
                                      {"role": "assistant", "content": answer}]
                    del self._history[:-40]
                if prompt is not None:
                    footer = aprompt.after_answer(answer, prompt)
                    if footer:
                        self._append("\n\n" + footer)        # a blank line: the footer is not the answer
                self._append("\n\n")
                self._finish_prompt()
                self._drop_card()                 # a new answer replaces any pending card
                if prompt is not None:
                    self._offer_card(answer, _text, prompt)
        elif tag == "error":
            born, message = value
            if born != self._clears:
                return                       # Clear already released the dock; a newer question may own it
            prompt = self._last_prompt.pop(born, None)
            self._append(f"\n[{message}]\n")
            if prompt is not None and "not answering" in str(message) or (
                    prompt is not None and "not running" in str(message).lower()):
                self._append(aprompt.NOT_RUNNING + "\n")
            if prompt is not None:
                fallback = aprompt.fallback_line(prompt)
                if fallback:
                    self._append(fallback + "\n")
            self._append("\n")
            self._finish_prompt()
            self._say(str(message), 30, warn=True)
            self.refresh()
        elif tag == "tip":
            if error is None and value and self._tip_born is not None:
                born, slug, domain = self._tip_born
                now = self._page_where()
                if born == self._clears and (slug, domain) == (now.slug, now.domain) \
                        and not self._busy:
                    self._set_tip_text(str(value), model=True)
            self._tip_born = None
        elif tag == "start":
            self.start_btn.setEnabled(True)
            self.start_btn.setText("Start local assistant")
            res = value if error is None else None
            # what came of it is said in the note, on the Assistant tab: open the panel
            # there, or a press on the collapsed strip shows nothing at all (round 4:
            # the native Windows refusal opens no work window, so it was never seen)
            self.show_tab("assistant")
            if res is not None and res.ok:
                self._say(res.message, 20)
                QtCore.QTimer.singleShot(1500, self.refresh)
                QtCore.QTimer.singleShot(6000, self.refresh)
            else:
                # Could not start it from here: open the work window, which shows the
                # exact command to run yourself.
                cmd = (res.command if res is not None
                       else odk.commands_for(self.generator_dir, self.ollama_mode)["start"])
                why = res.message if res is not None else str(error)
                # no command (native Windows): the script is not a thing to run there; a
                # message that already names the command is not told it twice
                self._say(f"{why} Run it yourself: {cmd}" if cmd and cmd not in why else why,
                          60, warn=True)
                if cmd:
                    self.show_current_work()


class _Card(QtWidgets.QFrame):
    """A framed block under the answer area with a title, rows and a button row.
    Never a dialog: it lives in the dock's layout and only its buttons act."""

    def __init__(self, title: str, parent=None):
        super().__init__(parent)
        self.setObjectName("assistant_card")
        self.setFrameShape(QtWidgets.QFrame.Shape.StyledPanel)
        lay = QtWidgets.QVBoxLayout(self)
        lay.setContentsMargins(8, 6, 8, 6)
        lay.setSpacing(4)
        self.title = plain(QtWidgets.QLabel(title))
        f = self.title.font()
        f.setBold(True)
        self.title.setFont(f)
        self.title.setWordWrap(True)
        lay.addWidget(self.title)
        self.rows = plain(QtWidgets.QLabel(""))
        self.rows.setWordWrap(True)
        self.rows.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        lay.addWidget(self.rows)
        self.status = plain(QtWidgets.QLabel(""))
        self.status.setWordWrap(True)
        self.status.setStyleSheet(styles.muted())
        lay.addWidget(self.status)
        self.buttons = QtWidgets.QHBoxLayout()
        self.buttons.setSpacing(6)
        lay.addLayout(self.buttons)
        self.apply_btn = _styled_button("Apply")
        self.cancel_btn = _styled_button("Cancel")
        self.undo_btn = _styled_button("Undo")
        self.undo_btn.setVisible(False)
        self.buttons.addWidget(self.apply_btn)
        self.buttons.addWidget(self.cancel_btn)
        self.buttons.addWidget(self.undo_btn)
        self.buttons.addStretch(1)
        self._lay = lay

    STATUS_CHARS = 170                          # about three lines at the narrow width

    @classmethod
    def compact(cls, text: str) -> str:
        """``text`` cut at a list comma under STATUS_CHARS (the card is a few lines;
        the full text goes to the tooltip and the answer area)."""
        if len(text) <= cls.STATUS_CHARS:
            return text
        cut = text.rfind(", ", 0, cls.STATUS_CHARS)
        cut = cut if cut > 40 else cls.STATUS_CHARS
        return text[:cut].rstrip(" ,") + ", … (the full list is in the answer above)"

    def say(self, text: str, warn: bool = False, detail: str = "") -> None:
        self.status.setStyleSheet(f"color: {styles.WARN};" if warn else styles.muted())
        shown = self.compact(text)
        self.status.setText(shown)
        self.status.setToolTip(plain_tip(detail or (text if shown != text else "")))
        if shown != text and getattr(self, "_appended", "") != text:
            # the card promises "the full list is in the answer above": keep that promise
            # (once: a second press of the same refused Apply adds nothing)
            dock = getattr(self, "dock", None)
            if dock is not None:
                dock._append(text + "\n\n")
                self._appended = text
        self._fit()

    def _fit(self) -> None:
        """Never squeezed below its wrapped text: the answer area above gives way
        instead (a long status line was once clipped top and bottom)."""
        self.rows.setVisible(bool(self.rows.text()))
        self.status.setVisible(bool(self.status.text()))
        w = self.width() if self.width() > 50 else self.sizeHint().width()
        need = self._lay.totalHeightForWidth(w)
        if need > 0 and need != self.minimumHeight():
            self.setMinimumHeight(need)
            dock = getattr(self, "dock", None)
            if dock is not None:
                dock._card_resized()

    def resizeEvent(self, event) -> None:       # noqa: N802 — Qt override
        super().resizeEvent(event)
        self._fit()

    def refused(self, text: str) -> None:
        self.say(text, warn=True)
        self.apply_btn.setVisible(False)
        self.undo_btn.setVisible(False)
        self.cancel_btn.setText("Close")


class _ProposalCard(_Card):
    """``Proposed change — <domain>`` with ``<label>: <from> -> <to>``, Apply / Cancel,
    then Undo. Apply goes through assistant_actions.apply on the window thread."""

    def __init__(self, dock: "LocalAIDock", validated, where, target):
        self.dock, self.where, self.target = dock, where, target
        self.validated = validated
        self.applied = None
        v = validated
        dom = getattr(v, "domain", "") or getattr(where, "domain", "") or "this mesh"
        super().__init__(f"Proposed change \u2014 {dom}", dock)
        self.cancel_btn.clicked.connect(self._cancel)
        self.apply_btn.clicked.connect(self._apply)
        self.undo_btn.clicked.connect(self._undo)
        self.swatch = None
        if isinstance(v, aact.Refusal):
            self.rows.setText("")
            self.refused(v.text)                     # a long one also goes to the answer area
            return
        self.rows.setText(v.row_text() + (f"\n({v.note})" if v.note else ""))
        if v.key in ("look.primary", "look.secondary") and isinstance(v.after, str):
            self.swatch = QtWidgets.QLabel("")
            self.swatch.setObjectName("assistant_swatch")
            self.swatch.setFixedSize(16, 16)
            self.swatch.setStyleSheet(f"background: {v.after}; border: 1px solid #888;")
            self.swatch.setToolTip(v.after)
            self.buttons.insertWidget(0, self.swatch)
        # focus order: after Send (the prompt row) comes the card
        QtWidgets.QWidget.setTabOrder(dock.clear_btn, self.apply_btn)
        QtWidgets.QWidget.setTabOrder(self.apply_btn, self.cancel_btn)
        QtWidgets.QWidget.setTabOrder(self.cancel_btn, self.undo_btn)    # Undo, right after Apply

    def _cancel(self) -> None:
        self.dock._drop_card()

    def _apply(self) -> None:
        try:
            if isinstance(self.validated, aact.Refusal) or self.target is None:
                return
            res = aact.apply(self.validated, self.where, self.target)
            if isinstance(res, aact.Refusal):
                self.say(res.text, warn=True)
                if "since I proposed" in res.text or res.text.startswith("Already set"):
                    self.apply_btn.setVisible(False)
                return
            self.applied = res
            self.dock._undo[res.target_id] = res
            self.say("Applied. The page shows the new value.")
            self.apply_btn.setVisible(False)
            self.undo_btn.setVisible(True)
            self.cancel_btn.setText("Close")
        except Exception as exc:                # noqa: BLE001 — said on the card
            self.say(f"Not applied: {exc.__class__.__name__}: {exc}", warn=True)
            _log_swallowed("_ProposalCard._apply")

    def _undo(self) -> None:
        try:
            if self.applied is None or self.target is None:
                self.say("Nothing to undo.", warn=True)
                return
            res = aact.undo(self.applied, self.where, self.target)
            if isinstance(res, aact.Refusal):
                self.say(res.text, warn=True)
                return
            self.dock._undo.pop(self.applied.target_id, None)
            self.applied = None
            self.say("Undone.")
            self.undo_btn.setVisible(False)
        except Exception as exc:                # noqa: BLE001
            self.say(f"Not undone: {exc.__class__.__name__}: {exc}", warn=True)
            _log_swallowed("_ProposalCard._undo")


class _DiffCard(_Card):
    """``Proposed edit — <app>-<domain>``: file list, View diff, Apply / Cancel, Revert."""

    def __init__(self, dock: "LocalAIDock", workspace, edits):
        self.dock, self.workspace, self.edits = dock, workspace, list(edits)
        self.applied = None
        super().__init__(f"Proposed edit \u2014 {workspace.name}", dock)
        n, m = len(self.edits), sum(e.changed for e in self.edits)
        self.rows.setText(f"{n} file(s), {m} changed lines: " + ", ".join(e.path for e in self.edits))
        self.view_btn = _styled_button("View diff", "Show the diff in the Current work window")
        self.view_btn.clicked.connect(self._view)
        self.buttons.insertWidget(0, self.view_btn)
        self.undo_btn.setText("Revert")
        self.cancel_btn.clicked.connect(lambda: dock._drop_card())
        self.apply_btn.clicked.connect(self._apply)
        self.undo_btn.clicked.connect(self._revert)
        self.say("Local only: nothing is committed, pushed or run.")
        QtWidgets.QWidget.setTabOrder(dock.clear_btn, self.view_btn)
        QtWidgets.QWidget.setTabOrder(self.view_btn, self.apply_btn)
        QtWidgets.QWidget.setTabOrder(self.apply_btn, self.cancel_btn)
        QtWidgets.QWidget.setTabOrder(self.cancel_btn, self.undo_btn)

    def _domain_moved(self, verb: str) -> str:
        """The refusal when the page no longer shows this folder's domain, else "".
        The proposal card refuses the same way; a diff card left up after Next domain
        once applied to the folder it names while another domain was on screen."""
        mine = self.workspace.domain or ""
        try:
            now = self.dock._page_where().domain or ""
        except Exception:                       # noqa: BLE001 — unreadable page: refuse
            now = ""
        if now.lower() == mine.lower():
            return ""
        return (f"This edit is for {mine}, but the page now shows {now or 'no domain'}. "
                f"Go back to {mine} to {verb} it; nothing was changed.")

    def preview_text(self) -> str:
        return aedit.preview(self.edits)

    def _view(self) -> None:
        self.dock.open_diff_viewer(self.preview_text())

    def _apply(self) -> None:
        try:
            moved = self._domain_moved("apply")
            if moved:
                self.say(moved, warn=True)
                return
            res = aedit.apply(self.edits, self.workspace, self.dock._state_dir())
            if isinstance(res, aedit.DiffProblem):
                self.say(res.text, warn=True)
                return
            self.applied = res
            self.dock._applied_edit = res
            self.say(f"Applied to {os.path.basename(res.workspace.rstrip(os.sep))}. Not committed; "
                     "Revert puts the old text back.",
                     detail=f"Folder: {res.workspace}\nBefore-copies: {res.before_dir}")
            self.apply_btn.setVisible(False)
            self.undo_btn.setVisible(True)
            self.cancel_btn.setText("Close")
        except Exception as exc:                # noqa: BLE001
            self.say(f"Not applied: {exc.__class__.__name__}: {exc}", warn=True)
            _log_swallowed("_DiffCard._apply")

    def _revert(self) -> None:
        try:
            if self.applied is None:
                return
            moved = self._domain_moved("revert")
            if moved:
                self.say(moved, warn=True)
                return
            why = aedit.revert(self.applied)
            if why:
                self.say(why, warn=True)
                return
            self.say("Reverted.")
            self.undo_btn.setVisible(False)
            self.dock._applied_edit = None
        except Exception as exc:                # noqa: BLE001
            self.say(f"Not reverted: {exc.__class__.__name__}: {exc}", warn=True)
            _log_swallowed("_DiffCard._revert")


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
        if not hasattr(wizard, "button"):           # a plain window: nothing to shorten
            return None
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
                    # above then corrects it. Place the dock AND the content now, from one
                    # height: placing the dock alone left the content at the height an
                    # earlier pass computed, under the panel, whenever the card's height
                    # changed in between (collapse and re-expand or put back with a card
                    # up: content 332 over a panel top of 317 at 942x552, PR #832 round 3).
                    self.relayout()
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
    page_slug = kw.pop("page_slug", "")
    dock = LocalAIDock(generator_dir, parent=wizard, **kw)
    wizard.local_ai_dock = dock
    wizard._local_ai_mount = _DockMount(wizard, dock)
    try:
        dock.attach_mesh_page(getattr(wizard, "localmesh_page", None))
    except Exception:
        _log_swallowed("mount_dock(attach_mesh_page)")
    # THE PAGE HOOK: the wizard's own signal says which page is on screen; a window
    # without one (fleet, the standalone local-mesh dialog) is told its one slug.
    try:
        dock._wizard_ref = weakref.ref(wizard)
        sig = getattr(wizard, "currentIdChanged", None)
        if sig is not None and hasattr(wizard, "pageIds"):
            sig.connect(dock.on_page_changed)
            dock.on_page_changed(wizard.currentId())      # announce the page it is already on
        if not dock._page_slug:
            dock.set_page_slug(page_slug or ("localmesh" if getattr(wizard, "localmesh_page", None)
                                             is not None else ""))
    except Exception:
        _log_swallowed("mount_dock(page hook)")
    wizard._local_ai_mount.relayout()
    dock.show()
    return dock

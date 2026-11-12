"""The "Kernel config…" panel — ONE widget, used inline by the Progress page (once an
image's Build kernel stage is done) and by the per-build window a finished session opens.

Every decision and every sentence comes from :mod:`core.kernel_reconfig`, so the CLI
(``--kernel-config*``) and the TUI sessions review say exactly the same things. No modal
anywhere: refusals, the terminal hand-off and the rebuild's outcome all report on labels
inside the panel.

* **Open menuconfig…** opens ``make menuconfig`` for THIS image's kernel tree in its own
  terminal window (inside the build system, on a copy of the build's final .config —
  the build's own .config is never touched, so it is safe while the image is still
  building). Where no terminal window can be opened the label shows the exact command.
* **Show changes** re-reads the saved edit; a timer does the same whenever the edit file
  changes, so the diff appears by itself once the operator saves in menuconfig.
* **Rebuild kernel + re-sign + repackage** is disabled with its reason beside it until
  the image's build has finished OK, an edit that changes something is saved, the key a
  signed image used is still there, and no other build or emulated device is running
  (builds run one at a time on this machine). It streams the rebuild into the log below
  and records the result on the session.
* **Discard edit** drops the saved, unapplied edit.
"""
from __future__ import annotations

from typing import Callable

from ...core import build_sessions, kernel_reconfig as kr
from ..qt import QtCore, QtGui, QtWidgets, Signal
from ..styles import ERROR, OK, WARN, muted
from ._widgets import own_probe

__all__ = ["KernelReconfigPanel"]

#: How often the panel re-reads the saved edit (ms): menuconfig runs in another window.
POLL_MS = 2000


class _StreamWorker(QtCore.QThread):
    """Runs one streamed script verb off the GUI thread. Never raises out of run()."""
    line = Signal(str)
    done = Signal(object)

    def __init__(self, fn: Callable[[Callable[[str], None]], object]):
        super().__init__()
        self._fn = fn

    def run(self):
        try:
            self.done.emit(self._fn(self.line.emit))
        except Exception as exc:  # noqa: BLE001 - reported inline
            self.done.emit(exc)


class KernelReconfigPanel(QtWidgets.QWidget):
    """Inline kernel reconfiguration for one image of one session."""

    #: Emitted after an applied rebuild was recorded (the session record changed).
    applied = Signal(object)

    def __init__(self, generator_dir: str, *, driver_factory=None, opener=None,
                 busy: Callable[[], str] | None = None, show_title: bool = True, parent=None):
        super().__init__(parent)
        self.generator_dir = generator_dir
        # seams: tests inject a fake driver (never sudo/docker) and a fake opener (never
        # a window on the operator's desktop)
        self._driver_factory = driver_factory or self._default_driver
        self._opener = opener or kr.open_editor
        self._busy = busy or kr.busy_reason
        self.session = None
        self.image_id: str | None = None
        self.image_running: bool | None = None
        self.live_container = ""
        self.target: kr.KernelTarget | None = None
        self.refusal = ""
        self._worker: _StreamWorker | None = None
        self._driver = None
        self._seen_mtime = 0.0

        lay = QtWidgets.QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        self.title = QtWidgets.QLabel("<b>Kernel config</b>")
        self.title.setVisible(show_title)     # a host group box may carry the title instead
        lay.addWidget(self.title)
        self.status = QtWidgets.QLabel("")
        self.status.setWordWrap(True)
        self.status.setTextInteractionFlags(QtCore.Qt.TextInteractionFlag.TextSelectableByMouse)
        lay.addWidget(self.status)

        row1 = QtWidgets.QHBoxLayout()
        self.open_btn = QtWidgets.QPushButton("Open menuconfig…")
        self.open_btn.setToolTip("Opens make menuconfig for this image's kernel in its own "
                                 "terminal window. Save and exit there to keep the change.")
        self.open_btn.clicked.connect(self._open_editor)
        row1.addWidget(self.open_btn)
        self.show_btn = QtWidgets.QPushButton("Show changes")
        self.show_btn.clicked.connect(self.refresh)
        row1.addWidget(self.show_btn)
        self.discard_btn = QtWidgets.QPushButton("Discard edit")
        self.discard_btn.clicked.connect(self._discard)
        row1.addWidget(self.discard_btn)
        row1.addStretch(1)
        lay.addLayout(row1)

        self.open_note = QtWidgets.QLabel("")
        self.open_note.setWordWrap(True)
        self.open_note.setTextInteractionFlags(QtCore.Qt.TextInteractionFlag.TextSelectableByMouse)
        self.open_note.setStyleSheet(muted())
        self.open_note.setVisible(False)
        lay.addWidget(self.open_note)

        self.diff = QtWidgets.QPlainTextEdit()
        self.diff.setReadOnly(True)
        self.diff.setPlaceholderText("No saved change yet — open menuconfig, change an "
                                     "option, then save and exit.")
        self.diff.setMinimumHeight(48)
        self.diff.setMaximumHeight(120)
        f = QtGui.QFontDatabase.systemFont(QtGui.QFontDatabase.SystemFont.FixedFont)
        self.diff.setFont(f)
        lay.addWidget(self.diff)

        row2 = QtWidgets.QHBoxLayout()
        self.apply_btn = QtWidgets.QPushButton("Rebuild kernel + re-sign + repackage")
        self.apply_btn.setToolTip(
            "Rebuilds only the kernel and its modules from the saved edit (the build's own "
            "hardening checks run on it first), re-signs the Secure Boot UKI with the key "
            "this build used, and repackages the stage4 tar, the .img and the ISOs. The "
            "previous artifacts move to superseded/.")
        self.apply_btn.clicked.connect(self._apply)
        row2.addWidget(self.apply_btn)
        self.apply_reason = QtWidgets.QLabel("")
        self.apply_reason.setWordWrap(True)
        self.apply_reason.setStyleSheet(muted())
        row2.addWidget(self.apply_reason, 1)
        lay.addLayout(row2)

        self.restart_note = QtWidgets.QLabel(
            "A Restart or Redo of this session rebuilds the kernel from its fragments and "
            "drops an applied edit.")
        self.restart_note.setWordWrap(True)
        self.restart_note.setStyleSheet(muted())
        lay.addWidget(self.restart_note)

        self.log = QtWidgets.QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setFont(f)
        self.log.setMaximumBlockCount(5000)
        self.log.setMinimumHeight(60)
        self.log.setVisible(False)
        lay.addWidget(self.log, 1)
        # spare height goes BELOW the controls (the log is hidden until a rebuild runs;
        # without this a tall window spread the rows apart with dead bands between them)
        lay.addStretch(1)

        self._timer = QtCore.QTimer(self)
        self._timer.setInterval(POLL_MS)
        self._timer.timeout.connect(self._poll)
        self._sync_buttons()

    # ── binding ───────────────────────────────────────────────────────────────
    def bind(self, session, image_id: str | None = None, *, image_running: bool | None = None,
             live_container: str = "") -> None:
        """Point the panel at one image of one session and re-read everything."""
        self.session = session
        self.image_id = image_id
        self.image_running = image_running
        self.live_container = live_container
        self.open_note.setVisible(False)
        self.refresh()
        if not self._timer.isActive():
            self._timer.start()

    def set_running(self, image_running: bool, live_container: str = "") -> None:
        self.image_running = image_running
        self.live_container = live_container
        self.refresh()

    def _default_driver(self):
        from ...core.build_driver import BuildDriver
        return BuildDriver(self.generator_dir, graphical=True)

    def _ctx(self, driver):
        backend = getattr(self.session, "backend", None) or None
        return driver.reconfig_context(backend, live_container=self.live_container
                                       if self.image_running else "")

    # ── reading ───────────────────────────────────────────────────────────────
    def refresh(self) -> None:
        if self.session is None:
            self.target, self.refusal = None, "No build selected."
        else:
            t = kr.locate(self.session, self.image_id, image_running=self.image_running)
            if isinstance(t, str):
                self.target, self.refusal = None, t
            else:
                self.target, self.refusal = t, ""
        t = self.target
        if t is None:
            self.title.setText("<b>Kernel config</b>")
            self.status.setText(self.refusal)
            self.status.setStyleSheet(f"color: {WARN};")
            self.diff.setPlainText("")
        else:
            self.title.setText(f"<b>Kernel config — {t.image_id}</b>")
            self.status.setText(t.summary())
            self.status.setStyleSheet("")
            changes = t.pending_changes()
            self.diff.setPlainText(kr.format_diff(changes) if changes else "")
            self._seen_mtime = t.pending_mtime()
        self._sync_buttons()

    def _poll(self) -> None:
        t = self.target
        if t is None or self.isHidden():
            return
        if t.pending_mtime() != self._seen_mtime:
            self.refresh()

    def apply_block_reason(self) -> str:
        if self._worker is not None:
            return "A kernel rebuild is running."
        if self.target is None:
            return self.refusal
        return kr.apply_refusal(self.target) or self._busy()

    def _sync_buttons(self) -> None:
        running = self._worker is not None
        t = self.target
        self.open_btn.setEnabled(t is not None and not running)
        self.show_btn.setEnabled(t is not None)
        self.discard_btn.setEnabled(t is not None and t.has_pending() and not running)
        why = self.apply_block_reason()
        self.apply_btn.setEnabled(not why)
        self.apply_reason.setText(why)
        self.apply_btn.setToolTip(self.apply_btn.toolTip())

    # ── actions ───────────────────────────────────────────────────────────────
    def _say(self, text: str, colour: str = "") -> None:
        self.open_note.setText(text)
        self.open_note.setStyleSheet(f"color: {colour};" if colour else muted())
        self.open_note.setVisible(bool(text))

    def _open_editor(self) -> None:
        t = self.target
        if t is None:
            return
        try:
            ok, msg = self._opener(t, self._ctx(self._driver_factory()))
        except Exception as exc:  # noqa: BLE001 - shown inline, never a dialog
            ok, msg = False, f"Could not open menuconfig: {exc}"
        if ok:
            self._say("menuconfig is open in its own terminal window — change what you "
                      "need, Save, then Exit. The change appears here by itself.", OK)
        else:
            self._say(msg, WARN)
        self._timer.start()

    def _start(self, fn, on_done) -> None:
        self.log.setVisible(True)
        w = _StreamWorker(fn)
        w.line.connect(self.log.appendPlainText)
        w.done.connect(on_done)
        own_probe(self, "_worker", w)
        w.start()
        self._sync_buttons()

    def _discard(self) -> None:
        t = self.target
        if t is None or self._worker is not None:
            return
        drv = self._driver_factory()
        ctx = self._ctx(drv)
        argv = kr.verb_argv(t, ctx, "discard")
        self._start(lambda cb: drv.stream_command(argv, cb, ctx.backend), self._discard_done)

    def _discard_done(self, rc) -> None:
        self._worker = None
        if isinstance(rc, Exception):
            self._say(f"Discard failed: {rc}", ERROR)
        elif rc != 0:
            self._say(f"Discard failed (exit {rc}) — see the log below.", ERROR)
        else:
            self._say("The saved edit was discarded.")
        self.refresh()

    def _apply(self) -> None:
        t = self.target
        why = self.apply_block_reason()
        if t is None or why:
            self._sync_buttons()
            return
        drv = self._driver_factory()
        self._driver = drv
        ctx = self._ctx(drv)
        self.log.clear()
        self._say("Rebuilding the kernel — this takes a while; the log below follows it.")
        self._start(lambda cb: kr.run_apply(
            t, ctx, lambda a, c: drv.stream_command(a, c, ctx.backend), cb), self._apply_done)

    def cancel(self) -> None:
        """Stop a running rebuild (the driver's own per-backend kill)."""
        if self._driver is not None and self._worker is not None:
            self._driver.cancel()

    def _apply_done(self, res) -> None:
        self._worker = None
        self._driver = None
        t = self.target
        if isinstance(res, Exception):
            self._say(f"The rebuild could not start: {res}", ERROR)
        elif res.refusal:
            self._say(res.refusal, WARN)
        elif res.rc != 0:
            self._say(f"The rebuild failed (exit {res.rc}) — the artifacts were not "
                      "replaced; see the log below.", ERROR)
        elif not res.result:
            self._say("The rebuild finished but its result record could not be read.", ERROR)
        elif t is not None and self.session is not None:
            try:
                row = kr.record(self.session, t, res.result, save=build_sessions.save)
                self._say("Done: " + kr.describe_record(row), OK)
                self.applied.emit(row)
            except Exception as exc:  # noqa: BLE001
                self._say(f"Rebuilt, but the session record could not be updated: {exc}", WARN)
        self.refresh()


class KernelConfigWindow(QtWidgets.QWidget):
    """The panel in its own NON-modal top-level window, for a finished session (the
    Previous builds list and the per-build window). One per session: reopening raises it."""

    def __init__(self, generator_dir: str, session, *, driver_factory=None, opener=None,
                 busy=None, parent=None):
        super().__init__(parent, QtCore.Qt.WindowType.Window)
        self.setWindowTitle(f"Kernel config — {getattr(session, 'label', '') or getattr(session, 'id', '')}")
        self.resize(760, 520)
        lay = QtWidgets.QVBoxLayout(self)
        self.panel = KernelReconfigPanel(generator_dir, driver_factory=driver_factory,
                                         opener=opener, busy=busy, parent=self)
        lay.addWidget(self.panel, 1)
        close = QtWidgets.QPushButton("Close")
        close.clicked.connect(self.close)
        lay.addWidget(close, 0, QtCore.Qt.AlignmentFlag.AlignRight)
        self.panel.bind(session)

"""ProgressPage — the terminal build page, present in EVERY mode (slug "progress").

The wizard's Finish is a Build action: leaving the Review page commits a WorklistConfig
(standalone/cloud = a 1-entry worklist; mesh = the WorklistPage's selection) and lands here.
This page runs that worklist through :class:`~...core.worklist_driver.WorklistDriver` on a
worker thread and shows ONE row per image — status, a determinate progress bar driven by the
honest banner-phase parser (:mod:`...core.progress_parse`), the current phase, and a per-row
Stop — plus a shared log that switches to the clicked row's ring buffer, and footer lines for
the once-per-worklist steps (mesh manifest written, per-node key-zips generated).

Finish is disabled until every row is terminal (ok / failed / stopped); Back is disabled for
free because the Review page is a commit page. Nothing here fakes a percent — an image whose
builder has not yet hit a known phase banner shows an indeterminate (busy) bar, exactly as
:class:`~...core.progress_parse.ProgressParser` reports it.
"""
from __future__ import annotations

from collections import deque

from ..qt import QtCore, QtWidgets, Signal
from ..tray import write_build_status
from ...core.progress_parse import ProgressParser
from ...core.worklist_driver import WorklistDriver

# status id -> (symbol, colour) for the per-row status glyph.
_STATUS_GLYPH = {
    "queued": ("○", "#888888"),
    "running": ("●", "#1a73e8"),
    "ok": ("✓", "#188038"),
    "failed": ("✗", "#c5221f"),
    "stopped": ("■", "#888888"),
}


class _WorklistWorker(QtCore.QThread):
    """Runs WorklistDriver.run_all() off the GUI thread, re-emitting its callbacks as Qt
    signals (queued to the GUI thread) — the direct N-image generalization of build.py's
    _BuildWorker / fleet.py's _FleetWorker."""
    entry_start = Signal(int)
    line = Signal(int, str)
    entry_done = Signal(int, object)      # exit code may be None (a stopped image)
    manifest = Signal(str)
    keys = Signal(int, str, bool)
    finished_all = Signal(int)

    def __init__(self, driver: WorklistDriver):
        super().__init__()
        self.driver = driver

    def run(self) -> None:
        code = self.driver.run_all(
            on_entry_start=lambda i: self.entry_start.emit(i),
            on_line=lambda i, ln: self.line.emit(i, ln),
            on_entry_done=lambda i, c: self.entry_done.emit(i, c),
            on_manifest=lambda p: self.manifest.emit(p),
            on_keys=lambda i, p, ok: self.keys.emit(i, p, ok))
        self.finished_all.emit(code)


class _Row:
    """The per-image UI + parse state (one worklist entry)."""

    def __init__(self, index: int, label: str, platform: str):
        self.index = index
        self.label = label
        self.parser = ProgressParser(platform)
        self.buffer: deque[str] = deque(maxlen=4000)
        self.terminal = False
        # widgets (wired by ProgressPage._build_row)
        self.status: QtWidgets.QLabel | None = None
        self.bar: QtWidgets.QProgressBar | None = None
        self.phase: QtWidgets.QLabel | None = None
        self.stop_btn: QtWidgets.QToolButton | None = None


class ProgressPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Building")
        self.setSubTitle("One progress bar per image. Finish is enabled once every build "
                         "has finished, failed, or stopped.")
        lay = QtWidgets.QVBoxLayout(self)

        self._rows_host = QtWidgets.QWidget()
        self._rows_lay = QtWidgets.QVBoxLayout(self._rows_host)
        self._rows_lay.setContentsMargins(0, 0, 0, 0)
        scroll = QtWidgets.QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setWidget(self._rows_host)
        scroll.setMaximumHeight(230)
        lay.addWidget(scroll)

        self.footer = QtWidgets.QLabel("")
        self.footer.setWordWrap(True)
        self.footer.setStyleSheet("color: gray;")
        lay.addWidget(self.footer)

        self.log = QtWidgets.QPlainTextEdit()
        self.log.setReadOnly(True)
        lay.addWidget(self.log, 1)

        btns = QtWidgets.QHBoxLayout()
        self.stop_all_btn = QtWidgets.QPushButton("Stop all")
        self.stop_all_btn.clicked.connect(self._stop_all)
        btns.addWidget(self.stop_all_btn)
        btns.addStretch(1)
        lay.addLayout(btns)

        self.driver: WorklistDriver | None = None
        self.worker: _WorklistWorker | None = None
        self._rows: list[_Row] = []
        self._selected = 0
        self._all_terminal = False
        self._manifest_path = ""
        self._keys_done: list[str] = []
        self._last_status: tuple | None = None    # de-dupes build-status file writes
        # never orphan a running build when the wizard closes — cancel and join the
        # worker on the wizard's finished signal (QWizard is a QDialog).
        self.wiz.finished.connect(self._abort_run)

    # ---- lifecycle --------------------------------------------------------------
    def initializePage(self) -> None:
        if self.worker is not None and self.worker.isRunning():
            return
        self._reset()
        wl = getattr(self.wiz, "worklist", None)
        if wl is None or not wl.entries:
            self.log.setPlainText("No images to build.")
            self._all_terminal = True
            self.completeChanged.emit()
            return
        backend = getattr(self.wiz, "build_backend", None)
        generate_keys = getattr(self.wiz, "generate_node_keys", True)
        try:
            self.driver = WorklistDriver(self.wiz.generator_dir, wl, host=self.wiz.host,
                                         backend=backend, generate_keys=generate_keys)
            materialized = self.driver.materialize()
            problems = self.driver.preflight()
        except Exception as e:                      # invalid identity / materialize failure
            self.log.setPlainText(f"Cannot start the build: {e}")
            self._all_terminal = True
            self.completeChanged.emit()
            return
        for i, (entry, cfg) in enumerate(materialized):
            self._build_row(i, entry.id, cfg.platform or "x86")
        self._select_row(0)
        if problems:
            # never launch a build preflight says cannot run (the Review page already gates
            # its Build button on the same check; this defends the direct/back-nav path).
            self.log.setPlainText("Preflight FAILED — build not started:\n  - "
                                  + "\n  - ".join(problems))
            self._all_terminal = True
            self.completeChanged.emit()
            return
        self._start_worker()

    def _reset(self) -> None:
        while self._rows_lay.count():
            item = self._rows_lay.takeAt(0)
            w = item.widget()
            if w is not None:
                w.deleteLater()
        self._rows = []
        self._selected = 0
        self._all_terminal = False
        self._manifest_path = ""
        self._keys_done = []
        self.footer.setText("")
        self.log.setPlainText("")
        self._last_status = None
        write_build_status("idle")                # clear any prior badge on the tray

    def _build_row(self, index: int, label: str, platform: str) -> None:
        row = _Row(index, label, platform)
        w = QtWidgets.QFrame()
        w.setFrameShape(QtWidgets.QFrame.Shape.StyledPanel)
        h = QtWidgets.QHBoxLayout(w)
        h.setContentsMargins(6, 2, 6, 2)
        row.status = QtWidgets.QLabel()
        row.status.setFixedWidth(16)
        h.addWidget(row.status)
        name = QtWidgets.QLabel(label)
        name.setMinimumWidth(150)
        h.addWidget(name)
        row.bar = QtWidgets.QProgressBar()
        row.bar.setRange(0, 100)
        row.bar.setValue(0)
        h.addWidget(row.bar, 1)
        row.phase = QtWidgets.QLabel("queued")
        row.phase.setMinimumWidth(150)
        row.phase.setStyleSheet("color: gray;")
        h.addWidget(row.phase)
        row.stop_btn = QtWidgets.QToolButton()
        row.stop_btn.setText("Stop")
        row.stop_btn.clicked.connect(lambda _=False, i=index: self._stop_one(i))
        h.addWidget(row.stop_btn)
        # clicking anywhere on the row shows its log; a lightweight event filter keeps the
        # child widgets clickable too.
        w.mousePressEvent = lambda _e, i=index: self._select_row(i)  # type: ignore[assignment]
        self._rows_lay.addWidget(w)
        self._set_status(row, "queued")
        self._rows.append(row)

    def _start_worker(self) -> None:
        assert self.driver is not None
        self.worker = _WorklistWorker(self.driver)
        self.worker.entry_start.connect(self._on_entry_start)
        self.worker.line.connect(self._on_line)
        self.worker.entry_done.connect(self._on_entry_done)
        self.worker.manifest.connect(self._on_manifest)
        self.worker.keys.connect(self._on_keys)
        self.worker.finished_all.connect(self._on_finished_all)
        self._write_status()                  # building 0% -> the tray shows a badge
        self.completeChanged.emit()
        self.worker.start()

    # ---- slots (GUI thread) -----------------------------------------------------
    def _on_entry_start(self, i: int) -> None:
        self._set_status(self._rows[i], "running")
        self._rows[i].phase.setText("starting…")

    def _on_line(self, i: int, line: str) -> None:
        row = self._rows[i]
        row.buffer.append(line)
        state = row.parser.feed(line)
        self._apply_state(row, state)
        self._write_status()
        if i == self._selected:
            self.log.appendPlainText(line)

    def _on_entry_done(self, i: int, code) -> None:
        row = self._rows[i]
        if code is not None:
            row.parser.finalize(code)
        status = self.driver.results[i].status if self.driver else (
            "ok" if code == 0 else "failed")
        self._set_status(row, status)
        row.terminal = True
        if status == "ok":
            row.bar.setRange(0, 100)
            row.bar.setValue(100)
            row.phase.setText("done")
        else:
            # failed/stopped: take the bar OUT of indeterminate (busy) mode and hold the
            # last known percent, so the row reads as a stalled determinate bar instead of
            # a perpetual spinner. (A broken-docker build never emits a phase banner, so
            # the parser stays honestly indeterminate — this is what left every failed row
            # showing an empty busy bar and nothing ever "at 100" = the user's symptom.)
            last = row.parser.state().percent
            row.bar.setRange(0, 100)
            row.bar.setValue(last if last is not None else 0)
            row.phase.setText("stopped" if status == "stopped" else "FAILED")
        self._write_status()
        self.completeChanged.emit()

    def _on_manifest(self, path: str) -> None:
        self._manifest_path = path
        self._refresh_footer()

    def _on_keys(self, i: int, path: str, ok: bool) -> None:
        self._keys_done.append(f"{self._rows[i].label}: {'✓' if ok else '✗'} {path}")
        self._refresh_footer()

    def _on_finished_all(self, code: int) -> None:
        self._all_terminal = True
        self.stop_all_btn.setEnabled(False)
        for row in self._rows:
            if row.stop_btn is not None:
                row.stop_btn.setEnabled(False)
        self.log.appendPlainText(f"\n=== worklist finished (summary exit {code}) ===")
        self._write_status()                  # final complete/error badge for the tray
        self.completeChanged.emit()

    # ---- build-status channel (tray badge) --------------------------------------
    def _aggregate_percent(self) -> int:
        """A single 0..100 across every row for the tray badge: an ok/done row is 100, an
        indeterminate row (no phase banner yet) counts as 0, everything else its coarse
        parser estimate — the mean of those."""
        if not self._rows:
            return 0
        total = 0
        for row in self._rows:
            pct = row.parser.state().percent
            total += pct if pct is not None else 0
        return int(total / len(self._rows))

    def _write_status(self) -> None:
        """Publish the current build state to the tray's status file (de-duped)."""
        if not self._rows:
            return
        total = len(self._rows)
        running = sum(1 for r in self._rows if not r.terminal)
        percent = self._aggregate_percent()
        if self._all_terminal:
            ok = bool(self.driver) and all(
                self.driver.results[i].status == "ok" for i in range(total))
            state = "complete" if ok else "error"
        else:
            state = "building"
        key = (state, percent, running, total)
        if key == self._last_status:
            return
        self._last_status = key
        write_build_status(state, percent=percent, running=running, total=total)

    # ---- rendering helpers ------------------------------------------------------
    def _apply_state(self, row: _Row, state) -> None:
        if state.percent is None:
            # honest indeterminate: a busy bar, never a fabricated number.
            row.bar.setRange(0, 0)
        else:
            row.bar.setRange(0, 100)
            row.bar.setValue(state.percent)
        if state.phase_label:
            row.phase.setText(state.phase_label)

    def _set_status(self, row: _Row, status: str) -> None:
        sym, colour = _STATUS_GLYPH.get(status, ("○", "#888888"))
        if row.status is not None:
            row.status.setText(sym)
            row.status.setStyleSheet(f"color: {colour}; font-weight: bold;")

    def _select_row(self, i: int) -> None:
        if not self._rows:
            return
        self._selected = i
        self.log.setPlainText("\n".join(self._rows[i].buffer))

    def _refresh_footer(self) -> None:
        parts = []
        if self._manifest_path:
            parts.append(f"mesh manifest written: {self._manifest_path}")
        parts.extend(self._keys_done)
        self.footer.setText("\n".join(parts))

    # ---- stop -------------------------------------------------------------------
    def _stop_one(self, i: int) -> None:
        if self.driver is not None:
            self.driver.cancel(i)

    def _stop_all(self) -> None:
        if self.driver is not None:
            self.driver.cancel_all()

    def _abort_run(self, *_a) -> None:
        """Cancel and join a still-running build so the wizard closing never orphans a
        builder process or a live QThread."""
        if self.worker is not None and self.worker.isRunning():
            if self.driver is not None:
                self.driver.cancel_all()
            self.worker.wait(3000)

    # ---- wizard contract --------------------------------------------------------
    def isComplete(self) -> bool:
        """Finish is enabled only once every image row is terminal (the run has settled)."""
        return self._all_terminal

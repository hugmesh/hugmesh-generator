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

import os
import subprocess
from collections import deque

from ..qt import QtCore, QtWidgets, Signal
from ..tray import write_build_status
from ...core import flash_targets
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


class _FlashWorker(QtCore.QThread):
    """Runs scripts/flash-disk.sh (via flash_targets.flash_argv) off the GUI thread,
    streaming its stdout into the log pane — the same QThread pattern as _WorklistWorker
    / build.py's _BuilderImageWorker. It NEVER re-implements dd: the script does the real
    write plus dl_require_root / unmount / whole-disk refusal / size-fit. The GUI does its
    OWN typed-path confirm before this ever launches (see ProgressPage._flash_clicked)."""
    line = Signal(str)
    done = Signal(int)

    def __init__(self, argv: list[str], cwd: str):
        super().__init__()
        self._argv = argv
        self._cwd = cwd

    def run(self) -> None:
        try:
            proc = subprocess.Popen(self._argv, cwd=self._cwd, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True, bufsize=1)
        except OSError as e:
            self.line.emit(f"!! could not launch the flasher: {e}")
            self.done.emit(1)
            return
        assert proc.stdout is not None
        for ln in proc.stdout:
            self.line.emit(ln.rstrip("\n"))
        self.done.emit(proc.wait())


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
    # the overall-bar stylesheet, parameterised on the chunk colour so the terminal
    # green (all-ok) and the running/blue state share one template — and so _reset()
    # can put the bar back to blue for a second run on the same page instance.
    _TOTAL_BAR_QSS = (
        "QProgressBar {{ border: 1px solid #8a97b3; border-radius: 4px; "
        "text-align: center; font-weight: bold; }} "
        "QProgressBar::chunk {{ background-color: {chunk}; }}")

    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Building")
        self.setSubTitle("One progress bar per image. Finish is enabled once every build "
                         "has finished, failed, or stopped.")
        lay = QtWidgets.QVBoxLayout(self)

        # ── OVERALL / TOTAL progress (across the WHOLE worklist) — a prominent block
        # ABOVE the per-image rows. It is a pure READER of the existing
        # _aggregate_percent() (the same number the #339 tray badge uses), so it invents
        # no second progress figure and cannot drift from the tray status file.
        self.total_label = QtWidgets.QLabel("Overall — queued")
        tf = self.total_label.font(); tf.setBold(True); tf.setPointSize(tf.pointSize() + 2)
        self.total_label.setFont(tf)
        lay.addWidget(self.total_label)
        self.total_bar = QtWidgets.QProgressBar()
        self.total_bar.setRange(0, 100)
        self.total_bar.setValue(0)
        self.total_bar.setTextVisible(True)
        self.total_bar.setFormat("%p%  ·  overall")
        # a taller groove + accent chunk so the overall bar visually outranks the thin
        # per-image PART bars below it.
        self.total_bar.setMinimumHeight(26)
        self.total_bar.setStyleSheet(self._TOTAL_BAR_QSS.format(chunk="#1a73e8"))  # blue
        lay.addWidget(self.total_bar)

        self._rows_host = QtWidgets.QWidget()
        self._rows_lay = QtWidgets.QVBoxLayout(self._rows_host)
        self._rows_lay.setContentsMargins(0, 0, 0, 0)
        scroll = QtWidgets.QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setWidget(self._rows_host)
        # loosen the cramped 230px cap so multi-image worklists read without cramping
        scroll.setMinimumHeight(180)
        scroll.setMaximumHeight(340)
        lay.addWidget(scroll)

        self.footer = QtWidgets.QLabel("")
        self.footer.setWordWrap(True)
        self.footer.setStyleSheet("color: gray;")
        lay.addWidget(self.footer)

        # ── post-build "Flash to a device" group (hidden until an all-ok run finishes) ──
        self.flash_group = QtWidgets.QGroupBox("Flash to a device")
        fg = QtWidgets.QHBoxLayout(self.flash_group)
        self.flash_combo = QtWidgets.QComboBox()
        fg.addWidget(self.flash_combo, 1)
        self.flash_refresh_btn = QtWidgets.QPushButton("Refresh")
        self.flash_refresh_btn.clicked.connect(self._refresh_flash_targets)
        fg.addWidget(self.flash_refresh_btn)
        self.flash_btn = QtWidgets.QPushButton("Flash…")
        self.flash_btn.clicked.connect(self._flash_clicked)
        fg.addWidget(self.flash_btn)
        self.flash_group.setVisible(False)
        lay.addWidget(self.flash_group)

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
        # flash-to-a-device state (post-build)
        self.flash_worker: _FlashWorker | None = None
        self._flash_targets: list = []
        self._flash_timer = QtCore.QTimer(self)
        self._flash_timer.setInterval(2500)        # live device come/go refresh
        self._flash_timer.timeout.connect(self._refresh_flash_targets)
        # never orphan a running build when the wizard closes — cancel and join the
        # worker on the wizard's finished signal (QWizard is a QDialog).
        self.wiz.finished.connect(self._abort_run)

    # ---- lifecycle --------------------------------------------------------------
    def initializePage(self) -> None:
        if self.worker is not None and self.worker.isRunning():
            return
        # grow the window for readability on the terminal build page (guarded so it only
        # ever grows — never shrinks an already-larger window, and earlier pages are
        # unaffected since this fires on landing here).
        tw, th = 1040, 780
        if self.wiz.width() < tw or self.wiz.height() < th:
            self.wiz.resize(max(self.wiz.width(), tw), max(self.wiz.height(), th))
        self._flash_timer.start()                  # live device refresh while on this page
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
                                         backend=backend, generate_keys=generate_keys,
                                         graphical=True)
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
        self._refresh_overall()             # seed the K-of-N label before the run starts
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
        self.flash_group.setVisible(False)        # only an all-ok finish reveals it
        self.total_bar.setRange(0, 100)
        self.total_bar.setValue(0)
        # put the chunk back to blue: a prior all-ok run turned it green, and a second
        # build on the SAME page instance must not render green (or stay green under an
        # 'Overall FAILED' label) before the terminal branch re-colours it.
        self.total_bar.setStyleSheet(self._TOTAL_BAR_QSS.format(chunk="#1a73e8"))
        self._refresh_overall()                   # zero the overall block
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
        self._refresh_overall()

    def _on_line(self, i: int, line: str) -> None:
        row = self._rows[i]
        row.buffer.append(line)
        state = row.parser.feed(line)
        self._apply_state(row, state)
        self._write_status()
        self._refresh_overall()
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
        self._refresh_overall()
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
        self._refresh_overall()
        # post-build device flashing — ONLY on an all-ok run (never for a failure).
        if self._run_all_ok():
            self._refresh_flash_targets()
            self._maybe_auto_flash()
        self.completeChanged.emit()

    def _run_all_ok(self) -> bool:
        return (bool(self._rows) and self.driver is not None
                and all(self.driver.results[i].status == "ok"
                        for i in range(len(self._rows))))

    # ---- overall/total bar (a pure reader of _aggregate_percent) -----------------
    def _refresh_overall(self) -> None:
        """Drive the OVERALL bar + label from the EXISTING _aggregate_percent() (never a
        second number). Reads the current phase + K-of-N images for a legible label, and
        mirrors the per-row done/FAILED treatment at the whole-worklist level."""
        total = len(self._rows)
        if total == 0:
            self.total_bar.setRange(0, 100)
            self.total_bar.setValue(0)
            self.total_label.setText("Overall — queued")
            return
        terminal = sum(1 for r in self._rows if r.terminal)
        pct = self._aggregate_percent()
        if self._all_terminal:
            if self._run_all_ok():
                self.total_bar.setStyleSheet(self._TOTAL_BAR_QSS.format(chunk="#188038"))  # green
                self.total_bar.setRange(0, 100)
                self.total_bar.setValue(100)
                self.total_label.setText(f"Overall — done · {total} of {total} images")
            else:
                self.total_bar.setRange(0, 100)
                self.total_bar.setValue(pct)
                self.total_label.setText(
                    f"Overall — FAILED · {terminal} of {total} images finished")
            return
        # running: if EVERY row is still non-determinate (no phase banner yet), match the
        # per-row busy semantics with an indeterminate overall bar; else show the mean.
        if all(r.parser.state().percent is None for r in self._rows):
            self.total_bar.setRange(0, 0)
        else:
            self.total_bar.setRange(0, 100)
            self.total_bar.setValue(pct)
        self.total_label.setText(f"Overall — {self._current_phase()} · "
                                 f"image {min(terminal + 1, total)} of {total}")

    def _current_phase(self) -> str:
        """The phase label of the first still-running (non-terminal) row, for the overall
        label; falls back to a settled summary word."""
        for row in self._rows:
            if not row.terminal:
                txt = row.phase.text() if row.phase is not None else ""
                return txt or "building"
        return "done" if self._run_all_ok() else "finishing"

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
        self._flash_timer.stop()
        if self.worker is not None and self.worker.isRunning():
            if self.driver is not None:
                self.driver.cancel_all()
            self.worker.wait(3000)
        if self.flash_worker is not None and self.flash_worker.isRunning():
            self.flash_worker.wait(3000)

    # ---- flash to a device (post-build) -----------------------------------------
    # flash-disk.sh accepts only these --role tokens; a client/desktop role maps to the
    # generic 'host' artifact glob (the flasher auto-picks *-host-*.img from the work dir).
    _FLASH_ROLES = frozenset({"pki", "backend", "frontend", "host", "be", "fe", "omnibus"})

    def _flash_argv_for(self, target) -> list[str]:
        c = self.wiz.cfg
        work_dir = c.output_dir or os.path.join(self.wiz.generator_dir, "out")
        role = c.role if c.role in self._FLASH_ROLES else "host"
        arch = flash_targets.arch_for_platform(c.platform)
        return flash_targets.flash_argv(target, generator_dir=self.wiz.generator_dir,
                                        role=role, arch=arch, work_dir=work_dir)

    def _refresh_flash_targets(self) -> None:
        """Re-scan (read-only) and repopulate the combo, preserving the selection by
        device path; show the group only after an all-ok build with ≥1 target. Live
        come/go is driven by the 2.5s timer + the Refresh button."""
        try:
            targets = flash_targets.list_targets()
        except Exception:
            targets = []
        self._flash_targets = targets
        prev = self.flash_combo.currentData()
        self.flash_combo.clear()
        for t in targets:
            self.flash_combo.addItem(t.label(), t.path)
        if prev is not None:
            i = self.flash_combo.findData(prev)
            if i >= 0:
                self.flash_combo.setCurrentIndex(i)
        busy = self.flash_worker is not None and self.flash_worker.isRunning()
        self.flash_btn.setEnabled(bool(targets) and not busy)
        # only reveal post-build on an all-ok run (never before completion, never on fail)
        if self._all_terminal and self._run_all_ok() and targets:
            self.flash_group.setVisible(True)

    def _selected_target(self):
        path = self.flash_combo.currentData()
        for t in self._flash_targets:
            if t.path == path:
                return t
        return None

    def _flash_clicked(self) -> None:
        """GUI-side safety gate: require the operator to TYPE the exact device path
        (re-implementing flash-disk.sh's dl_confirm_destroy typed-path prompt in-GUI,
        since the script has no tty here) before launching the flasher worker."""
        target = self._selected_target()
        if target is None:
            return
        typed, ok = QtWidgets.QInputDialog.getText(
            self, "Confirm device to ERASE",
            f"This will ERASE {target.path} ({target.label()}).\n"
            f"Type the exact device path to confirm:")
        if not ok or typed.strip() != target.path:
            self.log.appendPlainText(
                f"Flash cancelled — typed path did not match {target.path}.")
            return
        self._start_flash(target)

    def _maybe_auto_flash(self) -> None:
        """The ONLY auto path: the BuildPage flash-with-build opt-in (default OFF). It
        fires only when opted-in, the run was all-ok, and the SAME device (matched on a
        stable identity, not just the /dev path) is STILL attached per a fresh read-only
        scan — no typed confirm (the checkbox WAS the explicit opt-in).

        The identity check defends a TOCTOU device-swap: a build can run for hours, and
        on Linux /dev/sdX is enumeration-order dependent, so a bare path match could
        silently flash a DIFFERENT removable disk that took the same node after the
        originally-selected one was unplugged. We require the re-scanned target at that
        path to also match the stashed device's size + model before writing."""
        opted, want = getattr(self.wiz, "flash_after", (False, None))
        if not opted or want is None:
            return
        # tolerate a legacy bare-path stash, but require full identity when we have it.
        want_path = getattr(want, "path", want)
        target = next((t for t in flash_targets.list_targets()
                       if t.path == want_path), None)
        if target is None:
            self.log.appendPlainText(
                f"Flash-after-build: device {want_path} is no longer attached — skipped.")
            return
        if isinstance(want, flash_targets.FlashTarget) and (
                target.size != want.size or target.model != want.model):
            self.log.appendPlainText(
                f"Flash-after-build: the device now at {want_path} is not the one selected "
                f"at build start (identity changed) — skipped for safety. "
                f"Use the Flash… button to confirm the new device.")
            return
        self.log.appendPlainText(f"Flash-after-build: flashing {want_path} (opted in)…")
        self._start_flash(target)

    def _start_flash(self, target) -> None:
        if self.flash_worker is not None and self.flash_worker.isRunning():
            return
        self.flash_btn.setEnabled(False)
        self.flash_refresh_btn.setEnabled(False)
        self.log.appendPlainText(f"\n=== flashing {target.path} via scripts/flash-disk.sh ===")
        self.flash_worker = _FlashWorker(self._flash_argv_for(target), self.wiz.generator_dir)
        self.flash_worker.line.connect(lambda s: self.log.appendPlainText(s))
        self.flash_worker.done.connect(self._flash_done)
        self.flash_worker.start()

    def _flash_done(self, code: int) -> None:
        self.log.appendPlainText(f"=== flash exited {code} ===")
        self.flash_refresh_btn.setEnabled(True)
        self._refresh_flash_targets()

    # ---- wizard contract --------------------------------------------------------
    def isComplete(self) -> bool:
        """Finish is enabled only once every image row is terminal (the run has settled)."""
        return self._all_terminal

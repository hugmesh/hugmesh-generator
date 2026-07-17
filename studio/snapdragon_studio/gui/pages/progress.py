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
import time
from collections import deque

from ..qt import QtCore, QtGui, QtWidgets, Qt, Signal
from ..tray import write_build_status
from ...core import build_sessions
from ...core import flash_targets
from ...core.progress_parse import ProgressParser, platform_phases
from ...core.stage_tracker import StageTracker
from ...core.worklist_driver import WorklistDriver

# status id -> (symbol, colour) for the per-JOB status glyph (col0).
_STATUS_GLYPH = {
    "queued": ("○", "#888888"),
    "running": ("●", "#1a73e8"),
    "ok": ("✓", "#188038"),
    "failed": ("✗", "#c5221f"),
    "stopped": ("■", "#888888"),
}

# stage state -> (symbol, colour) for the per-STAGE glyph (nested under a job). Neutral
# glyphs (pending/skipped/stopped) are grey and NEVER green — only a stage the parser
# actually advanced past shows the green ✓, so the tree can't claim a stage passed that
# the builder never completed.
_STAGE_GLYPH = {
    "pending": ("○", "#888888"),
    "running": ("●", "#1a73e8"),
    "done": ("✓", "#188038"),
    "failed": ("✗", "#c5221f"),
    "skipped": ("–", "#888888"),
    "stopped": ("■", "#888888"),
}

# tree column indices.
_COL_NAME, _COL_PROGRESS, _COL_TIME = 0, 1, 2


def _fmt_elapsed(secs: float | None) -> str:
    """m:ss elapsed for the Time column (empty for a stage that never started)."""
    if secs is None:
        return ""
    secs = int(secs)
    return f"{secs // 60}:{secs % 60:02d}"


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
        # StageTracker reuses the parser's EXACT ordered phase table (no parallel taxonomy)
        # so the nested stages and the bar can never disagree.
        self.tracker = StageTracker(platform_phases(platform or "x86"))
        self.buffer: deque[str] = deque(maxlen=4000)   # authoritative full raw job log
        self.terminal = False
        self.job_t_start: float | None = None
        # widgets (wired by ProgressPage._build_row)
        self.status: QtWidgets.QLabel | None = None    # kept for compat; col0 shows the glyph
        self.bar: QtWidgets.QProgressBar | None = None
        self.phase: QtWidgets.QLabel | None = None     # off-tree; still updated (tests read it)
        self.stop_btn: QtWidgets.QToolButton | None = None
        # tree items (wired by ProgressPage._build_row)
        self.job_item: QtWidgets.QTreeWidgetItem | None = None
        self.stage_items: list[QtWidgets.QTreeWidgetItem] = []


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

        # ── NESTED, DRILLABLE job/stage tree (GitHub-Actions style) — replaces the flat
        # QVBoxLayout-of-QFrames. A QTreeWidget (the established Studio idiom, cf.
        # worklist.py / packages_dialog.py) already scrolls itself, so it slots directly
        # in below the TOTAL bar (no wrapping QScrollArea — that would double-scroll). Each
        # top-level item is a JOB (one image); its children are the STAGES from the honest
        # phase table. The #348 PART bar is embedded into a job's Progress column via
        # setItemWidget, so row.bar stays the SAME widget object every existing test reads.
        self.tree = QtWidgets.QTreeWidget()
        self.tree.setColumnCount(3)
        self.tree.setHeaderLabels(["Job / Stage", "Progress", "Time"])
        self.tree.setColumnWidth(_COL_NAME, 320)
        self.tree.setColumnWidth(_COL_PROGRESS, 220)
        self.tree.setMinimumHeight(180)
        self.tree.setMaximumHeight(340)
        self.tree.itemClicked.connect(self._on_item_clicked)
        self.tree.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.tree.customContextMenuRequested.connect(self._on_tree_menu)
        lay.addWidget(self.tree)

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

        # drill-down detail pane: the SAME single QPlainTextEdit, retitled by the header to
        # show whether it's a whole job's raw log or one stage's slice.
        self.log_header = QtWidgets.QLabel("Log")
        self.log_header.setStyleSheet("font-weight: bold;")
        lay.addWidget(self.log_header)
        self.log = QtWidgets.QPlainTextEdit()
        self.log.setReadOnly(True)
        lay.addWidget(self.log, 1)

        btns = QtWidgets.QHBoxLayout()
        self.stop_all_btn = QtWidgets.QPushButton("Stop all")
        self.stop_all_btn.clicked.connect(self._stop_all)
        btns.addWidget(self.stop_all_btn)
        # GH-Actions-style failure list: cycles through every failed job/stage, expanding
        # and loading each one's log slice. Enabled once ≥1 failure is recorded.
        self.next_fail_btn = QtWidgets.QPushButton("Next failure ⤥")
        self.next_fail_btn.setEnabled(False)
        self.next_fail_btn.clicked.connect(self._next_failure)
        btns.addWidget(self.next_fail_btn)
        btns.addStretch(1)
        lay.addLayout(btns)

        self.driver: WorklistDriver | None = None
        self.worker: _WorklistWorker | None = None
        # durable session record (core/build_sessions) — created in initializePage,
        # WRITTEN only at real dispatch (_start_worker) and updated per image / at finish.
        self._session: build_sessions.BuildSession | None = None
        self._session_done = False
        self._rows: list[_Row] = []
        self._selected = 0
        self._selected_stage: int | None = None   # None = the job's raw log is shown
        self._all_terminal = False
        self._manifest_path = ""
        self._keys_done: list[str] = []
        self._last_status: tuple | None = None    # de-dupes build-status file writes
        # failure navigation: (job index, stage index or None), in dispatch order.
        self._failures: list[tuple[int, int | None]] = []
        self._fail_ptr = -1
        # one repeating 1s timer makes the running job/stage visibly "tick" — a couple of
        # label writes per second, no per-line cost; stopped once the run settles.
        self._tick = QtCore.QTimer(self)
        self._tick.setInterval(1000)
        self._tick.timeout.connect(self._on_tick)
        # flash-to-a-device state (post-build)
        self.flash_worker: _FlashWorker | None = None
        self._flash_targets: list = []
        self._flash_queue: list = []       # Review-page plan assignments, run sequentially
        # entry_id -> the CONCRETE artifact that entry's build produced (snapshot diff
        # around each sequential entry build) — what the flash plan passes as
        # --artifact so flash-disk.sh never has to guess between same-role images.
        self._entry_artifacts: dict[str, str] = {}
        self._entry_baseline: dict[str, float] = {}
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
            self._sync_back_button()
            return
        # Resolve "auto" HERE, once, so the record and the driver agree. BuildPage's
        # combo maps "auto" -> None (build.py _backend), and WorklistDriver separately
        # re-resolves `backend or host.default_backend` at six call sites — so an auto
        # build used to persist backend=None while really running native, leaving the
        # record unable to say what ran and letting a restart (wizard.py restores
        # build_backend from session.backend) silently pick a DIFFERENT backend if the
        # host default had changed since. Resolving once keeps "auto" a UI-only concept.
        # "none" (no usable backend) resolves the same as None did: the driver raises.
        backend = (getattr(self.wiz, "build_backend", None)
                   or self.wiz.host.default_backend)
        generate_keys = getattr(self.wiz, "generate_node_keys", True)
        # per-session artifact dir + durable record: the id BuildPage minted for its
        # preview (pending_session_id) is consumed here so preview == dispatch; a
        # RESTART pins an existing id so the SAME record/workdir is reused. Nothing is
        # written until _start_worker (real dispatch).
        self._session = build_sessions.new_session(
            wl, self.wiz.generator_dir, backend=backend, generate_keys=generate_keys,
            session_id=getattr(self.wiz, "pending_session_id", None))
        self._session_done = False
        try:
            self.driver = WorklistDriver(self.wiz.generator_dir, wl, host=self.wiz.host,
                                         backend=backend, generate_keys=generate_keys,
                                         graphical=True, workdir=self._session.workdir)
            materialized = self.driver.materialize()
            problems = self.driver.preflight()
        except Exception as e:                      # invalid identity / materialize failure
            self.log.setPlainText(f"Cannot start the build: {e}")
            self._all_terminal = True
            self.completeChanged.emit()
            self._sync_back_button()
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
            self._sync_back_button()
            return
        # ADVISORY low-memory warnings (2026-07-15 freeze guard): leading log lines
        # only, deliberately outside the blocking branch above — dispatch proceeds,
        # and nothing is throttled (the argv is identical with or without them).
        try:
            warnings = self.driver.preflight_warnings()
        except Exception:
            warnings = []
        for w in warnings:
            self.log.appendPlainText(f"WARNING: {w}")
        self._start_worker()

    def _reset(self) -> None:
        self._tick.stop()
        self.tree.clear()               # drops every job + stage item (and its embedded bar)
        self._rows = []
        self._selected = 0
        self._selected_stage = None
        self._failures = []
        self._fail_ptr = -1
        self.next_fail_btn.setEnabled(False)
        self._all_terminal = False
        self._sync_back_button()      # a fresh run is in flight -> Back disabled again
        self._manifest_path = ""
        self._keys_done = []
        self.footer.setText("")
        self.log_header.setText("Log")
        self.log.setPlainText("")
        self._last_status = None
        self._flash_queue = []
        self._entry_artifacts = {}
        self._entry_baseline = {}
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
        # JOB item (top-level) — the GitHub-Actions "all jobs listed up front" seam.
        job_item = QtWidgets.QTreeWidgetItem(self.tree)
        job_item.setData(_COL_NAME, Qt.ItemDataRole.UserRole, (index, None))
        row.job_item = job_item
        # row.status stays a real QLabel for back-compat; col0 carries the visible glyph.
        row.status = QtWidgets.QLabel()
        # the #348 PART bar, embedded into the job's Progress column (same widget object).
        row.bar = QtWidgets.QProgressBar()
        row.bar.setRange(0, 100)
        row.bar.setValue(0)
        self.tree.setItemWidget(job_item, _COL_PROGRESS, row.bar)
        # off-tree phase label — no longer shown (the running STAGE conveys the phase) but
        # still updated so every existing assertion on row.phase.text() holds.
        row.phase = QtWidgets.QLabel("queued")
        # kept for back-compat + the per-image Stop context-menu action (see _on_tree_menu).
        row.stop_btn = QtWidgets.QToolButton()
        row.stop_btn.setText("Stop")
        row.stop_btn.clicked.connect(lambda _=False, i=index: self._stop_one(i))
        # STAGE children — one per phase-table row, keyed by phase_index, all "pending".
        row.stage_items = []
        now = time.monotonic()
        for j in range(len(row.tracker.stages)):
            child = QtWidgets.QTreeWidgetItem(job_item)
            child.setData(_COL_NAME, Qt.ItemDataRole.UserRole, (index, j))
            row.stage_items.append(child)
            self._render_stage(row, j, now)
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
        if self._session is not None:         # START record: status "running" + pid
            build_sessions.start(self._session)
        self.completeChanged.emit()
        self._sync_back_button()
        self.worker.start()

    # ---- slots (GUI thread) -----------------------------------------------------
    def _work_dir(self) -> str:
        """The build output dir — the same resolution the flash plan's work_dir and
        WorklistDriver._output_dir use."""
        return (self.wiz.cfg.output_dir
                or os.path.join(self.wiz.generator_dir, "out"))

    def _on_entry_start(self, i: int) -> None:
        row = self._rows[i]
        self._set_status(row, "running")
        row.phase.setText("starting…")
        row.job_t_start = time.monotonic()
        if row.job_item is not None:
            self.tree.expandItem(row.job_item)      # GH-Actions focuses the active job
        if not self._tick.isActive():
            self._tick.start()
        # read-only baseline of the flashable artifacts already in the work dir, so
        # _on_entry_done can identify by diff WHICH image THIS entry produced (the
        # worklist is sequential, so the diff is unambiguous). This is what lets the
        # flash plan pass a concrete --artifact instead of trusting flash-disk.sh's
        # newest-mtime role glob, which cannot tell same-role entries apart.
        self._entry_baseline = flash_targets.snapshot_artifacts(self._work_dir())
        self._refresh_overall()

    def _on_line(self, i: int, line: str) -> None:
        row = self._rows[i]
        row.buffer.append(line)
        state = row.parser.feed(line)
        self._apply_state(row, state)
        # attribute the line to the currently-running stage + advance stage state on a
        # banner transition. O(1) per line; tree items are touched only on a transition.
        now = time.monotonic()
        delta = row.tracker.feed(line, state.phase_index, now)
        if delta.any():
            for j in delta.touched():
                self._render_stage(row, j, now)
        self._write_status()
        self._refresh_overall()
        # live drill-down append: only when the arriving line's target matches the current
        # selection — the whole job (stage None) gets every line; a selected stage gets a
        # line only while it is the running stage of that job.
        if i == self._selected:
            if self._selected_stage is None or row.tracker.cur == self._selected_stage:
                self.log.appendPlainText(line)

    def _on_entry_done(self, i: int, code) -> None:
        row = self._rows[i]
        now = time.monotonic()
        if code is not None:
            row.parser.finalize(code)
        status = self.driver.results[i].status if self.driver else (
            "ok" if code == 0 else "failed")
        # settle the nested stages: exit 0 -> running done + trailing skipped; cancel ->
        # running stopped (neutral); nonzero -> running stage failed. Never fabricates a
        # done/green stage the builder didn't complete. A user-initiated Stop of a RUNNING
        # image makes proc.wait() return the killed process's nonzero code (e.g. 143/137)
        # while res.status is "stopped"; map that cancel back to None so the running stage
        # settles NEUTRAL (stopped) instead of red FAILED under a grey STOPPED job.
        stage_code = None if status == "stopped" else code
        row.tracker.finalize(stage_code, now)
        for j in range(len(row.stage_items)):
            self._render_stage(row, j, now)
        self._set_status(row, status)
        row.terminal = True
        if status == "ok" and self.driver is not None:
            # record the artifact THIS entry produced (diff vs its start baseline);
            # "" (nothing new / compressed-only output) stays unrecorded, so a flash
            # assignment for this entry fails SAFE (skipped, never a glob guess).
            art = flash_targets.new_artifact(self._work_dir(), self._entry_baseline)
            if art:
                self._entry_artifacts[self.driver.results[i].entry.id] = art
        if row.job_item is not None and row.job_t_start is not None:
            row.job_item.setText(_COL_TIME, _fmt_elapsed(now - row.job_t_start))
        if status == "ok":
            row.bar.setRange(0, 100)
            row.bar.setValue(100)
            row.phase.setText("done")
            if row.job_item is not None:
                self.tree.collapseItem(row.job_item)   # settled -> tuck it away
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
            if status == "failed":
                # FAILURE FOCUS: expand the job and land the user on the exact failing
                # stage's log slice (or the job's raw log if it died before any banner —
                # #339: no fake stage is invented to host that error).
                fj = row.tracker.failed_index()
                self._failures.append((i, fj))
                self._fail_ptr = len(self._failures) - 1
                self.next_fail_btn.setEnabled(True)
                if row.job_item is not None:
                    self.tree.expandItem(row.job_item)
                self._focus_node(i, fj)
        if self._session is not None and self.driver is not None:   # partial truth
            r = self.driver.results[i]
            build_sessions.update_image(self._session, i, status=r.status,
                                        exit_code=r.exit_code, keys_ok=r.keys_ok)
        self._write_status()
        self._refresh_overall()
        self.completeChanged.emit()
        self._sync_back_button()

    def _on_manifest(self, path: str) -> None:
        self._manifest_path = path
        self._refresh_footer()

    def _on_keys(self, i: int, path: str, ok: bool) -> None:
        self._keys_done.append(f"{self._rows[i].label}: {'✓' if ok else '✗'} {path}")
        self._refresh_footer()

    def _on_finished_all(self, code: int) -> None:
        self._all_terminal = True
        self._tick.stop()                      # nothing running -> stop the elapsed ticker
        self.stop_all_btn.setEnabled(False)
        for row in self._rows:
            if row.stop_btn is not None:
                row.stop_btn.setEnabled(False)
        self.log.appendPlainText(f"\n=== worklist finished (summary exit {code}) ===")
        self._finalize_session()              # FINISH record: outcome + error tails
        self._write_status()                  # final complete/error badge for the tray
        self._refresh_overall()
        # post-build device flashing — ONLY on an all-ok run (never for a failure).
        if self._run_all_ok():
            self._refresh_flash_targets()
            self._maybe_auto_flash()
        self.completeChanged.emit()
        self._sync_back_button()

    def _finalize_session(self, status: str | None = None) -> None:
        """FINISH write for the session record (once per run): status from the driver
        results — all ok -> complete, any failed -> failed, else stopped — unless
        forced (the wizard-close abort passes "stopped" since it really cancels), plus
        the failed rows' error tails. Clears the wizard's pending id so a second build
        mints a fresh session."""
        if self._session is None or self._session_done or self.driver is None:
            return
        self._session_done = True
        results = self.driver.results
        tails = {results[i].entry.id:
                 list(self._rows[i].buffer)[-build_sessions.ERROR_TAIL_LINES:]
                 for i in range(min(len(self._rows), len(results)))
                 if results[i].status == "failed"}
        build_sessions.finish(self._session,
                              status or build_sessions.overall_status(
                                  [r.status for r in results]), tails)
        if getattr(self.wiz, "pending_session_id", None) == self._session.id:
            self.wiz.pending_session_id = None

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
        if row.job_item is not None:
            row.job_item.setText(_COL_NAME, f"{sym}  {row.label}")
            row.job_item.setForeground(_COL_NAME, QtGui.QBrush(QtGui.QColor(colour)))

    def _render_stage(self, row: _Row, j: int, now: float) -> None:
        """Reflect one stage's tracker state onto its tree item (glyph+label, state word,
        elapsed). Called only on a transition or the 1s tick — never per line."""
        st = row.tracker.stages[j]
        item = row.stage_items[j]
        sym, colour = _STAGE_GLYPH.get(st.state, ("○", "#888888"))
        item.setText(_COL_NAME, f"{sym}  {st.label}")
        item.setForeground(_COL_NAME, QtGui.QBrush(QtGui.QColor(colour)))
        item.setText(_COL_PROGRESS, st.state)
        item.setText(_COL_TIME, _fmt_elapsed(st.elapsed(now)))

    def _on_tick(self) -> None:
        """Make the running job + its active stage visibly tick their elapsed time. One
        pass over the (at most one) running row — a couple of label writes per second."""
        now = time.monotonic()
        for row in self._rows:
            if row.terminal or row.job_t_start is None:
                continue
            if row.job_item is not None:
                row.job_item.setText(_COL_TIME, _fmt_elapsed(now - row.job_t_start))
            if row.tracker.cur >= 0:
                self._render_stage(row, row.tracker.cur, now)

    # ---- drill-down selection ---------------------------------------------------
    def _on_item_clicked(self, item, _col: int = 0) -> None:
        data = item.data(_COL_NAME, Qt.ItemDataRole.UserRole)
        if not data:
            return
        i, j = data
        self._load_detail(i, j)

    def _load_detail(self, i: int, stage_j: int | None) -> None:
        """Load the selected node's log into the shared pane: a JOB shows its full raw log;
        a STAGE shows only that stage's captured slice."""
        if not (0 <= i < len(self._rows)):
            return
        row = self._rows[i]
        self._selected = i
        self._selected_stage = stage_j
        if stage_j is None:
            self.log.setPlainText("\n".join(row.buffer))
            self.log_header.setText(f"Log — {row.label}")
        else:
            st = row.tracker.stages[stage_j]
            self.log.setPlainText("\n".join(st.lines))
            self.log_header.setText(f"Log — {row.label} ▸ {st.label}")

    def _focus_node(self, i: int, stage_j: int | None) -> None:
        """Expand the job, select the target node, and load its log slice — the shared
        primitive behind failure-focus and the Next-failure button."""
        if not (0 <= i < len(self._rows)):
            return
        row = self._rows[i]
        item = row.job_item if stage_j is None else row.stage_items[stage_j]
        if row.job_item is not None:
            self.tree.expandItem(row.job_item)
        if item is not None:
            self.tree.setCurrentItem(item)     # programmatic: does NOT re-fire itemClicked
        self._load_detail(i, stage_j)

    def _next_failure(self) -> None:
        """Cycle to the next recorded failure (wrapping), like GH-Actions' failure list."""
        if not self._failures:
            return
        self._fail_ptr = (self._fail_ptr + 1) % len(self._failures)
        i, stage_j = self._failures[self._fail_ptr]
        self._focus_node(i, stage_j)

    def _on_tree_menu(self, pos) -> None:
        """Right-click a still-running job/stage to Stop that one image (the per-image Stop
        that the old per-row button offered, now that the row is a tree node)."""
        item = self.tree.itemAt(pos)
        if item is None:
            return
        data = item.data(_COL_NAME, Qt.ItemDataRole.UserRole)
        if not data:
            return
        i, _j = data
        if not (0 <= i < len(self._rows)) or self._rows[i].terminal:
            return
        menu = QtWidgets.QMenu(self.tree)
        act = menu.addAction(f"Stop {self._rows[i].label}")
        act.triggered.connect(lambda _=False, idx=i: self._stop_one(idx))
        menu.exec(self.tree.viewport().mapToGlobal(pos))

    def _select_row(self, i: int) -> None:
        if not self._rows:
            return
        self._focus_node(i, None)

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
        self._tick.stop()
        # drop any still-queued plan assignments FIRST: a running dd outlives the 3s
        # join below, and when its done signal finally fires, _flash_done would chain
        # _flash_next — starting the NEXT destructive flash after the user aborted.
        self._flash_queue = []
        if self.worker is not None and self.worker.isRunning():
            if self.driver is not None:
                self.driver.cancel_all()
            self.worker.wait(3000)
            self._finalize_session(status="stopped")   # honest: the close cancelled it
        if self.flash_worker is not None and self.flash_worker.isRunning():
            self.flash_worker.wait(3000)

    # ---- flash to a device (post-build) -----------------------------------------
    # flash-disk.sh accepts only these --role tokens; a client/desktop role maps to the
    # generic 'host' artifact glob (the flasher auto-picks *-host-*.img from the work dir).
    _FLASH_ROLES = frozenset({"pki", "backend", "frontend", "host", "be", "fe", "omnibus"})

    def _flash_argv_for(self, target) -> list[str]:
        c = self.wiz.cfg
        work_dir = (self._session.workdir if self._session is not None else
                    c.output_dir or os.path.join(self.wiz.generator_dir, "out"))
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
        # preferred: the Review-page per-device plan (multi-device, per-image). The
        # assignments run SEQUENTIALLY (chained from _flash_done); the identity check
        # runs PER ASSIGNMENT inside _flash_next, immediately before each write — a
        # single up-front scan here would be minutes stale for assignment 2..N (each
        # dd takes minutes), reopening the same-node stick-swap TOCTOU the check
        # exists to stop.
        plan = getattr(self.wiz, "flash_plan", None)
        if plan:
            self._flash_queue = list(plan)
            self._flash_next()
            return
        # legacy single-target tuple stash (pre-table configs / older callers)
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

    def _flash_next(self) -> None:
        """Run the next queued plan assignment (sequential: chained from _flash_done,
        so two flashers can never run at once).

        BOTH safety checks run HERE, immediately before each destructive write —
        never once for the whole queue, because the previous flash took minutes and
        any earlier validation is stale by now (TOCTOU):

        * identity: a FRESH read-only scan must show a device at the assigned path
          whose size + model match the one assigned at build time — /dev/sdX is
          enumeration-order dependent, so a same-node different-stick swap during an
          earlier flash would otherwise be blindly written;
        * artifact: the CONCRETE image recorded for this assignment's entry (the
          per-entry snapshot diff, see _on_entry_start/_on_entry_done) is passed as
          --artifact. Without one we SKIP rather than let flash-disk.sh's role glob
          guess — it cannot tell two same-role entries apart.

        A failed check skips THAT assignment (logged) and moves on to the next."""
        while self._flash_queue:
            if self.flash_worker is not None and self.flash_worker.isRunning():
                self.flash_worker.wait(3000)  # the previous worker already emitted done
            a = self._flash_queue.pop(0)
            artifact = self._entry_artifacts.get(a.entry_id, "")
            if not artifact:
                self.log.appendPlainText(
                    f"Flash plan: no artifact was recorded for {a.entry_id} in this run "
                    f"— skipped for safety (flash manually: scripts/flash-disk.sh "
                    f"--artifact <image> {a.target.path}).")
                continue
            live = next((t for t in flash_targets.list_targets()
                         if t.path == a.target.path), None)
            if live is None:
                self.log.appendPlainText(
                    f"Flash plan: device {a.target.path} is no longer attached — skipped.")
                continue
            if live.size != a.target.size or live.model != a.target.model:
                self.log.appendPlainText(
                    f"Flash plan: the device now at {a.target.path} is not the one "
                    f"assigned at build time (identity changed) — skipped for safety.")
                continue
            self.log.appendPlainText(
                f"Flash plan: {a.entry_id} ({os.path.basename(artifact)}) → "
                f"{a.target.path} (opted in)…")
            self._start_flash(a.target, argv=flash_targets.assignment_argv(
                a, generator_dir=self.wiz.generator_dir, artifact=artifact))
            return

    def _start_flash(self, target, argv: list[str] | None = None) -> None:
        if self.flash_worker is not None and self.flash_worker.isRunning():
            return
        self.flash_btn.setEnabled(False)
        self.flash_refresh_btn.setEnabled(False)
        self.log.appendPlainText(f"\n=== flashing {target.path} via scripts/flash-disk.sh ===")
        self.flash_worker = _FlashWorker(argv or self._flash_argv_for(target),
                                         self.wiz.generator_dir)
        self.flash_worker.line.connect(lambda s: self.log.appendPlainText(s))
        self.flash_worker.done.connect(self._flash_done)
        self.flash_worker.start()

    def _flash_done(self, code: int) -> None:
        self.log.appendPlainText(f"=== flash exited {code} ===")
        self.flash_refresh_btn.setEnabled(True)
        self._refresh_flash_targets()
        self._flash_next()                    # chain the next plan assignment (if any)

    # ---- wizard contract --------------------------------------------------------
    def _sync_back_button(self) -> None:
        """Re-arm Back once the run has SETTLED, so a failed build is not a dead end.

        BuildPage is a Qt commit page (build.py setCommitPage(True) — "Build" is a real
        point of no return for the run it starts), and Qt disables Back on the page
        FOLLOWING a commit page. That is correct while a build is in flight, but it also
        made a FAILED build unrecoverable: the operator could not step back to Review &
        Build to fix the config and rebuild — the whole wizard had to be redone (real
        report 2026-07-17: "there's no way to go back after a build fails"). Once every
        row is terminal the run is over, so nothing is left uncommitted by stepping back;
        the next Build just starts a new run (build_sessions already models runs /
        restarts / history).

        Qt re-disables the button on each button-state update, so this is called after
        every completeChanged emit (which triggers one) rather than a single time.
        """
        wiz = self.wizard()
        if wiz is None:
            return
        # SCOPED enum (QWizard.WizardButton.BackButton), not QWizard.BackButton:
        # PyQt6 exposes enum members ONLY on the scoped type, so the unscoped form
        # AttributeErrors — and an unhandled exception in a Qt slot ABORTS the app,
        # so it crashed the Studio on Build for every PyQt6 user (2026-07-17).
        # PySide6 tolerates both, which is exactly why the test suite missed it.
        # The scoped form is what the rest of this file uses (Qt.CheckState.Checked,
        # Qt.ItemFlag.ItemIsUserCheckable) and works on BOTH bindings.
        btn = wiz.button(QtWidgets.QWizard.WizardButton.BackButton)
        if btn is not None:
            btn.setEnabled(self._all_terminal)

    def isComplete(self) -> bool:
        """Finish is enabled only once every image row is terminal (the run has settled)."""
        return self._all_terminal

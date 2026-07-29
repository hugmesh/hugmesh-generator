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

PACKAGES (third level): under the stage that is emerging, every package portage reports
gets its OWN row — JOB -> STAGE -> GROUP -> PACKAGE — fed by the Qt-free
:class:`~...core.emerge_packages.EmergePackageParser` (the per-package sibling of the
banner parser). The GROUP nodes are the five emerge groups the builders announce with the
pinned ``==> Emerge group: <g>`` banner (image/tools/dependencies/system/world). The group
is a LEVEL, not a stage, on purpose: the stage list is pinned 1:1 to the platform's phase
table (StageTracker "invents no taxonomy of its own", stage_tracker.py), and that table is
drift-probed against the builders' real ``banner`` call sites — while the emerge groups cut
ACROSS stages differently per platform (x86 runs all five emerge invocations inside its one
"Emerge packages" stage, build-x86-host-stage4.sh:4355-4450; the ARM builders split them
over "Phase 1: @system" and "Phase 2: stage4"). Making groups stages would fork the phase
taxonomy per platform and break the drift probe; a level under whichever stage was RUNNING
when the group's packages appeared preserves both truths. Each package row carries a real
QProgressBar (driven by the parser's ladder-derived, monotonic percent), its USE flags in
the Flags column (read from the per-package portage log's elog header), the latest
build-tool telemetry line compacted next to the bar, the full elog header + telemetry in
the row tooltip, and click-to-open of the package's own emerge log in the shared log pane.

LAYOUT: the job/stage TREE is the primary surface and the log is secondary, so the two sit
in a vertical QSplitter (tree ~2 : log ~1, i.e. the log takes at most a third) that the
operator can drag. The log panel — header + log + "watch it in a terminal" help — can be
collapsed to its header or detached into its own window; neither ever interrupts the
reader or loses a line, because :meth:`ProgressPage._on_line` appends to the
QPlainTextEdit's *document*, which is independent of the widget's visibility or parent.
The help names the REAL file the builder writes (``build_sessions.image_log_name`` — the
studio twin of the builders' ``IMAGE_LOG_FILE``): the GUI pane and that file are one
stream, so `tail -F` on it shows exactly what this page shows.
"""
from __future__ import annotations

import os
import re
import shlex
import subprocess
import time
from collections import deque

from ..qt import QtCore, QtGui, QtWidgets, Qt, Signal
from ..tray import write_build_status
from ...core import build_sessions
from ...core import flash_targets
from ...core.emerge_packages import (
    EmergePackageParser, PackageProgress, STEP_DONE, STEP_FAILED, STEP_QUEUED,
    find_package_log)
from ...core.progress_parse import ProgressParser, platform_phases, strip_ansi
from ...core.stage_tracker import StageTracker
from ...core.worklist_driver import WorklistDriver

# Residual control bytes AFTER strip_ansi() — a bare ESC that formed no complete
# SGR/CSI sequence, plus BEL/BS/CR/VT/FF (the x86 emerge stream carries CR from its
# progress bars) and DEL. The class spares EXACTLY two: \x09 TAB (real layout in
# builder output, and Qt renders it) and \x0a LF (never reaches here — the reader
# splits on it — but excluded so this stays safe if it ever sees a whole block).
_C0_RE = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")


def _display_safe(line: str) -> str:
    """A builder line made safe for a Qt text widget: drop the colour/cursor escapes
    first, then any control byte left over. Qt has no glyph for these, so each one
    paints a BOX (the operator's 2026-07-17 report). Idempotent and lossless for real
    text — it only removes bytes that could never render."""
    return _C0_RE.sub("", strip_ansi(line))


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

# per-PACKAGE glyphs: queued/done/failed mirror the stage palette; every mid-ladder step
# (unpack..install) renders the running blue dot — the ladder position itself is conveyed
# by the row's progress bar, not by six more glyphs.
_PKG_GLYPH = {
    STEP_QUEUED: ("○", "#888888"),
    STEP_DONE: ("✓", "#188038"),
    STEP_FAILED: ("✗", "#c5221f"),
}
_PKG_RUNNING_GLYPH = ("●", "#1a73e8")

# tree column indices — SYMBOLIC ONLY (renumbered when Flags landed; nothing may hardcode
# these). Flags sits between Progress and Time so a package row reads
# name -> bar+tool -> USE flags, and the Time column stays the trailing narrow one.
_COL_NAME, _COL_PROGRESS, _COL_FLAGS, _COL_TIME = 0, 1, 2, 3

# the shared-log-pane read of a package's on-disk emerge log is TAIL-BOUNDED: a real
# compile log can run to hundreds of MB (inkscape's is 1.2 MB, libreoffice's far larger)
# and QPlainTextEdit must never be handed one wholesale. 2 MiB comfortably covers every
# normal log while keeping the worst case a bounded read; the watch-help still names the
# full file for a terminal `tail -F`.
_PKG_LOG_TAIL_BYTES = 2 * 1024 * 1024

# tool_info is stored VERBATIM by the parser (its documented contract: a real ninja
# compile line can be ~4 KB — inkscape's g++ invocation), so the GUI must elide: the
# in-row label keeps a short head, the tooltip a longer one. Neither ever truncates the
# parser's own state — only what is painted.
_TOOL_CELL_CHARS = 72
_TOOL_TIP_CHARS = 300


def _elide(text: str, limit: int) -> str:
    """Head-elide for the tool-telemetry surfaces (the informative part of a ninja/make
    line is its head — the [N/M] counter and the tool name; the tail is argv noise)."""
    return text if len(text) <= limit else text[:limit - 1] + "…"


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


class _DetachedLogWindow(QtWidgets.QWidget):
    """The top-level window the log panel is popped into by "Detach ⇱".

    Two deliberate ownership choices, both load-bearing (see ProgressPage._detach_log):

    * **Parented to the WIZARD** (``Qt.WindowType.Window`` makes it a real top-level
      anyway), so it can never outlive the app or linger as a stray window — and so
      dropping the last Python reference does NOT destroy it (the wizard owns it).
    * **No WA_DeleteOnClose**: closing must RE-DOCK the panel, not destroy it. The
      closeEvent below routes every close through the page's single re-dock primitive,
      which reparents the panel out of this window BEFORE the window can be destroyed.

    Without that ordering, destroying this window would destroy its children — including
    the QPlainTextEdit the still-running build streams into — and the next line to arrive
    would raise ``RuntimeError: wrapped C/C++ object ... has been deleted`` (PyQt6) /
    ``Internal C++ object ... already deleted`` (PySide6) inside _on_line. That is a Qt
    SLOT, where an unhandled exception ABORTS the Studio mid-build. Both were reproduced
    on both bindings while designing this; the two choices above are what defeat them.
    """

    def __init__(self, parent, page):
        super().__init__(parent, Qt.WindowType.Window)
        self._page = page
        self.setWindowTitle("Build log")
        self.resize(900, 500)
        lay = QtWidgets.QVBoxLayout(self)
        lay.setContentsMargins(6, 6, 6, 6)

    def closeEvent(self, ev):
        # Re-dock rather than orphan: the panel goes back into the splitter (and the
        # stream keeps landing) instead of being destroyed with this window. _redock_log
        # clears the page's window ref FIRST, so this cannot recurse.
        self._page._redock_log()
        ev.accept()


class _Row:
    """The per-image UI + parse state (one worklist entry)."""

    def __init__(self, index: int, label: str, platform: str, log_root: str = ""):
        self.index = index
        self.label = label
        self.log_root = log_root
        self.parser = ProgressParser(platform)
        # StageTracker reuses the parser's EXACT ordered phase table (no parallel taxonomy)
        # so the nested stages and the bar can never disagree.
        self.tracker = StageTracker(platform_phases(platform or "x86"))
        # the per-PACKAGE sibling of the banner parser. log_root points at the build's
        # <workdir>/wl-<id>/sysroot/var/log/portage/build — the SAME path shape for every
        # builder (all six set SYSROOT="${BUILD_ROOT}/sysroot", e.g.
        # build-x86-host-stage4.sh:1799, build-rpi5-stage4.sh:1396, and BUILD_ROOT is
        # ${WORK_DIR}/${BUILD_SUBDIR} with BUILD_SUBDIR = entry.build_subdir = wl-<id>,
        # worklist.py:116/249) — so USE flags + per-package logs resolve as portage writes
        # them. Empty log_root (direct-slot tests) keeps the parser a pure stream parser
        # with no filesystem access, per its documented contract.
        self.pkg_parser = EmergePackageParser(log_root)
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
        # per-package tree state (wired lazily by ProgressPage._render_package as portage
        # reports each package — a --capable build emerges HUNDREDS, so everything below
        # is dict-keyed for O(1) per-line updates and NOTHING is ever rebuilt wholesale).
        self.group_items: dict[str, QtWidgets.QTreeWidgetItem] = {}   # group -> node
        self.pkg_items: dict[str, QtWidgets.QTreeWidgetItem] = {}     # atom -> row item
        self.pkg_bars: dict[str, QtWidgets.QProgressBar] = {}
        self.pkg_tools: dict[str, QtWidgets.QLabel] = {}              # compact tool_info
        self.pkg_progress: dict[str, PackageProgress] = {}            # live parser rows
        # last-painted fingerprint per atom -> skip every no-op widget write (the parser
        # returns a row for tool_info-only updates too, and 74,998 lines of a real build
        # are ninja counters alone — the fingerprint keeps those a cheap tuple compare).
        self.pkg_shown: dict[str, tuple] = {}


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
        self.tree.setColumnCount(4)
        # Flags: per-PACKAGE USE flags from the elog header of the package's own portage
        # log (there is NO stream-side source — the whole 3.16M-line reference transcript
        # contains zero "USE:" lines; see emerge_packages.py). Job/stage rows leave it "".
        self.tree.setHeaderLabels(["Job / Stage / Package", "Progress", "Flags", "Time"])
        self.tree.setColumnWidth(_COL_NAME, 320)
        self.tree.setColumnWidth(_COL_PROGRESS, 220)
        self.tree.setColumnWidth(_COL_FLAGS, 180)
        self.tree.setMinimumHeight(180)
        # NO setMaximumHeight: the tree is the PRIMARY surface and must grow with the
        # window. It used to be capped at 340px, which (once the stretch below was fixed)
        # left a growing band of dead grey space under it inside its own splitter pane at
        # tall windows. The splitter now bounds it instead — draggable, not hard-capped.
        self.tree.itemClicked.connect(self._on_item_clicked)
        self.tree.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.tree.customContextMenuRequested.connect(self._on_tree_menu)

        self.footer = QtWidgets.QLabel("")
        self.footer.setWordWrap(True)
        self.footer.setStyleSheet("color: gray;")

        # ── TREE / LOG split ──────────────────────────────────────────────────────────
        # The reported defect: "the final build screen should show mainly the tree of the
        # build with the current log below it taking up at most 1/3 of the vertical".
        # It did the opposite — `addWidget(self.tree)` carried NO stretch (so the tree was
        # pinned to its ~192px sizeHint forever) while `addWidget(self.log, 1)` took every
        # spare pixel. Measured at the 1040x780 this page resizes itself to: tree 31% /
        # log 44%, and the inversion WORSENED with height (21% / 61% at 900).
        #
        # A QSplitter fixes the proportions AND hands the operator the drag handle: the
        # tree pane gets stretch 2, the log pane stretch 1 (~2:1, log <= 1/3), and only the
        # LOG pane is collapsible — the tree can never be dragged shut.
        self.splitter = QtWidgets.QSplitter(Qt.Orientation.Vertical)

        tree_pane = QtWidgets.QWidget()
        tree_lay = QtWidgets.QVBoxLayout(tree_pane)
        tree_lay.setContentsMargins(0, 0, 0, 0)
        tree_lay.addWidget(self.tree, 1)      # stretch 1: the tree absorbs the pane
        tree_lay.addWidget(self.footer)       # the footer rides directly under the tree
        self.splitter.addWidget(tree_pane)

        # the log PANEL (header row + log + watch-help) is the unit that collapses and
        # detaches. self.log NEVER moves — its parent is always this panel — so the
        # _on_line append path is invariant under detach/re-dock (see _detach_log).
        self.log_panel = QtWidgets.QWidget()
        log_lay = QtWidgets.QVBoxLayout(self.log_panel)
        log_lay.setContentsMargins(0, 0, 0, 0)

        hdr = QtWidgets.QHBoxLayout()
        hdr.setContentsMargins(0, 0, 0, 0)
        # drill-down detail pane: the SAME single QPlainTextEdit, retitled by the header to
        # show whether it's a whole job's raw log or one stage's slice.
        self.log_header = QtWidgets.QLabel("Log")
        self.log_header.setStyleSheet("font-weight: bold;")
        hdr.addWidget(self.log_header)
        hdr.addStretch(1)
        self.log_collapse_btn = QtWidgets.QToolButton()
        self.log_collapse_btn.setArrowType(Qt.ArrowType.DownArrow)
        self.log_collapse_btn.setAutoRaise(True)
        self.log_collapse_btn.setCheckable(True)
        self.log_collapse_btn.setToolTip("Collapse the log")
        self.log_collapse_btn.toggled.connect(self._set_log_collapsed)
        hdr.addWidget(self.log_collapse_btn)
        self.log_detach_btn = QtWidgets.QToolButton()
        self.log_detach_btn.setText("Detach ⇱")
        self.log_detach_btn.setAutoRaise(True)
        self.log_detach_btn.setToolTip("Pop the log out into its own window")
        self.log_detach_btn.clicked.connect(self._toggle_detach)
        hdr.addWidget(self.log_detach_btn)
        log_lay.addLayout(hdr)

        self.log = QtWidgets.QPlainTextEdit()
        self.log.setReadOnly(True)
        # 0, not the default sizeHint floor: the log pane must be draggable/collapsible
        # all the way shut, leaving just the header row as the restore handle.
        self.log.setMinimumHeight(0)
        log_lay.addWidget(self.log, 1)

        # ── "watch it in a terminal" help (greyed, selectable, REAL path) ─────────────
        self.log_help_row = QtWidgets.QWidget()
        help_lay = QtWidgets.QHBoxLayout(self.log_help_row)
        help_lay.setContentsMargins(0, 0, 0, 0)
        self.log_help = QtWidgets.QLabel("")
        self.log_help.setWordWrap(True)
        self.log_help.setStyleSheet("color: gray;")      # greyed, like self.footer
        # greyed help the operator cannot copy is useless — make it a real selection.
        self.log_help.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse
            | Qt.TextInteractionFlag.TextSelectableByKeyboard)
        help_lay.addWidget(self.log_help, 1)
        self.log_copy_btn = QtWidgets.QToolButton()
        self.log_copy_btn.setText("Copy")
        self.log_copy_btn.setAutoRaise(True)
        self.log_copy_btn.setToolTip("Copy the watch command to the clipboard")
        self.log_copy_btn.clicked.connect(self._copy_watch_command)
        help_lay.addWidget(self.log_copy_btn)
        log_lay.addWidget(self.log_help_row)

        self.splitter.addWidget(self.log_panel)
        self.splitter.setStretchFactor(0, 2)      # tree pane: 2 shares of any spare space
        self.splitter.setStretchFactor(1, 1)      # log pane:  1 share  -> ~1/3
        self.splitter.setCollapsible(0, False)    # the tree can never be dragged shut
        self.splitter.setCollapsible(1, True)     # the log can
        lay.addWidget(self.splitter, 1)           # the splitter absorbs ALL spare height

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
        lay.addWidget(self.flash_group)          # below the splitter, beside the action bar

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
        # log panel state: the detached window (None = docked), the splitter sizes to
        # restore on expand/re-dock, and the one-shot 2:1 seed (applied on first show —
        # NOT in __init__, where the splitter's height is still 0).
        self._log_window: _DetachedLogWindow | None = None
        self._saved_sizes: list[int] = []
        self._split_seeded = False
        self._help_cmd = ""                     # what the help's Copy button yields
        # True only once a build is REALLY dispatched (_start_worker). Until then no
        # builder has opened a log file, so the watch-help must not name a path that
        # does not and will not exist (no worklist / preflight failure / pre-dispatch).
        self._dispatched = False
        # durable session record (core/build_sessions) — created in initializePage,
        # WRITTEN only at real dispatch (_start_worker) and updated per image / at finish.
        self._session: build_sessions.BuildSession | None = None
        self._session_done = False
        self._rows: list[_Row] = []
        self._selected = 0
        self._selected_stage: int | None = None   # None = the job's raw log is shown
        # package drill-down: (job index, atom) while a PACKAGE row's emerge log is shown
        # in the shared pane, else None. Mutually exclusive with the stage/job stream view
        # — while set, _on_line never appends stream lines to the pane (the pane shows a
        # FILE, followed by the 1s tick), and _load_detail clears it on any job/stage click.
        self._selected_pkg: tuple[int, str] | None = None
        self._pkg_log_size = -1                   # last-loaded size, for the tick follow
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
        # EVERY flashable artifact each entry produced (newest first) — one x86
        # entry can emit .img + .live.iso + .installer.iso in a single run, and the
        # per-device FLAVOUR pick needs the whole set (recording only the newest
        # would make every non-default flavour unreachable).
        self._entry_artifact_sets: dict[str, tuple[str, ...]] = {}
        self._entry_baseline: dict[str, float] = {}
        self._flash_timer = QtCore.QTimer(self)
        self._flash_timer.setInterval(2500)        # live device come/go refresh
        self._flash_timer.timeout.connect(self._refresh_flash_targets)
        # never orphan a running build when the wizard closes — cancel and join the
        # worker on the wizard's finished signal (QWizard is a QDialog).
        self.wiz.finished.connect(self._abort_run)

    # ---- log panel: split / collapse / detach / watch-help ----------------------
    def showEvent(self, ev) -> None:
        super().showEvent(ev)
        self._seed_split()

    def resizeEvent(self, ev) -> None:
        super().resizeEvent(ev)
        self._seed_split()

    def _seed_split(self) -> None:
        """Seed the 2:1 tree:log split ONCE, on the first show/resize that gives the
        splitter a real height (it is 0 in __init__, so setSizes there is a no-op). After
        this the stretch factors (2 vs 1) keep the ratio as the window grows, and any
        operator drag is theirs to keep — this never fights it."""
        if self._split_seeded:
            return
        h = self.splitter.height()
        if h <= 0:
            return
        self._split_seeded = True
        self._saved_sizes = self._default_sizes(h)
        self.splitter.setSizes(self._saved_sizes)

    @staticmethod
    def _default_sizes(h: int) -> list[int]:
        top = int(h * 2 / 3)
        return [top, h - top]

    def _restore_sizes(self) -> None:
        """Put the log pane back to its pre-collapse/pre-detach share (or a fresh 2:1)."""
        h = self.splitter.height()
        sizes = self._saved_sizes
        if len(sizes) != 2 or sizes[1] <= 0 or sum(sizes) <= 0:
            sizes = self._default_sizes(h if h > 0 else 600)
        self.splitter.setSizes(sizes)

    def _log_is_docked(self) -> bool:
        return self.splitter.indexOf(self.log_panel) != -1

    def _set_log_collapsed(self, collapsed: bool) -> None:
        """Collapse/restore the log BODY, keeping the header row as the restore handle.

        Hiding self.log alone is NOT enough: QSplitter does not re-lay a pane when a
        GRANDCHILD hides, so the pane kept its full size and the operator got an empty grey
        box instead of the tree's space back (measured while building this). So the pane is
        resized to the header's height too — 23px collapsed, header still visible.

        COLLAPSE ONLY MEANS ANYTHING WHILE DOCKED. In the detached window the log body IS
        the window's entire content, so honouring `collapsed` there would leave a blank
        900x500 box (review finding B, reproduced on both bindings). The body's visibility
        is therefore `collapsed AND docked`, never `collapsed` alone — that makes the empty
        window unreachable even for a programmatic setChecked, not merely hard to click.

        Output is NEVER lost while collapsed: appendPlainText is a QTextDocument
        operation, wholly independent of widget visibility, and _on_line is untouched —
        it does not branch on collapsed state and the reader is never stopped.
        """
        docked = self._log_is_docked()
        if collapsed and docked:
            sizes = self.splitter.sizes()
            if len(sizes) == 2 and sizes[1] > 0:
                self._saved_sizes = sizes          # remember the share to restore
        body_visible = not (collapsed and docked)
        self.log.setVisible(body_visible)
        self.log_help_row.setVisible(body_visible)
        if docked:
            if collapsed:
                hh = self.log_panel.minimumSizeHint().height()
                self.splitter.setSizes([max(0, self.splitter.height() - hh), hh])
            else:
                self._restore_sizes()
        self.log_collapse_btn.setArrowType(
            Qt.ArrowType.RightArrow if collapsed else Qt.ArrowType.DownArrow)
        self.log_collapse_btn.setToolTip(
            "Expand the log" if collapsed else "Collapse the log")

    def _toggle_detach(self) -> None:
        self._redock_log() if self._log_window is not None else self._detach_log()

    def _detach_log(self) -> None:
        """Pop the log panel into its own top-level window.

        Only the PANEL moves — self.log's parent stays log_panel, so _on_line's
        appendPlainText target is untouched and a build streaming mid-detach cannot
        break. The now-empty splitter pane disappears and the tree takes the full height.

        Detaching FORCE-EXPANDS: "put the log in its own window" and "hide the log body"
        are contradictory instructions, and the operator asked for the former. Without
        this, Collapse-then-Detach handed back a blank 900x500 window (review finding B).
        The collapse control is hidden for the duration — the state it toggles has no
        meaning here, so offering it would only be a trap.
        """
        if self._log_window is not None:
            return
        if self._log_is_docked():
            sizes = self.splitter.sizes()
            if len(sizes) == 2 and sizes[1] > 0:
                self._saved_sizes = sizes
        # While still DOCKED, so this routes through the normal restore-sizes path and
        # leaves _saved_sizes meaning what it says.
        self.log_collapse_btn.setChecked(False)
        self.log_collapse_btn.setVisible(False)
        win = _DetachedLogWindow(self.wiz, self)
        win.layout().addWidget(self.log_panel)     # reparents the panel onto the window
        self._log_window = win
        win.show()
        self.log_detach_btn.setText("Re-dock ⇲")
        self.log_detach_btn.setToolTip("Put the log back in the build page")

    def _redock_log(self) -> None:
        """Put the panel back in the splitter — the ONE primitive every exit path uses
        (the Re-dock button, the detached window's close, _reset, and _abort_run).

        insertWidget reparents the panel off the window BEFORE the window is ever
        destroyed. That ordering is what makes the reparent-then-destroy trap (a deleted
        C++ QPlainTextEdit under a live Python wrapper, raising inside the _on_line slot
        and aborting the app) unreachable.

        The docked layout is a PURE FUNCTION of the collapse flag: rather than
        unconditionally handing the pane its full share back, re-dock replays
        _set_log_collapsed. An unconditional _restore_sizes() here gave a body-hidden
        panel 28% of the page — 187px of dead grey, the very defect this change set out to
        remove (review finding A).
        """
        win = self._log_window
        if win is None:
            return
        self._log_window = None            # FIRST: re-entrancy guard for closeEvent
        self.splitter.insertWidget(1, self.log_panel)   # reparent off the window
        self.log_panel.setVisible(True)
        self.log_collapse_btn.setVisible(True)
        # Sizes + body visibility derived from the flag, never assumed.
        self._set_log_collapsed(self.log_collapse_btn.isChecked())
        win.hide()
        win.deleteLater()                  # safe now: the panel is no longer its child
        self.log_detach_btn.setText("Detach ⇱")
        self.log_detach_btn.setToolTip("Pop the log out into its own window")

    def _watch_command(self, path: str) -> str:
        """The REAL command to follow `path` on THIS host.

        `tail -F`, not `tail -f`: a queued/pre-dispatch job has no log file yet, and
        `tail -f` exits on a missing file while `-F` retries by name — so the command is
        copy-paste-correct BEFORE the job starts. `-n +1` starts at the top, so the
        terminal shows the same stream from the beginning. Windows has no tail at all.
        """
        host = getattr(self.wiz, "host", None)
        if getattr(host, "os", "linux") == "windows":
            return f'Get-Content -Wait -Tail 50 "{path}"'
        return f"tail -F -n +1 {shlex.quote(path)}"

    def _refresh_log_help(self) -> None:
        """Point the greyed help at the CURRENTLY SELECTED job's real log file.

        The paths are derived from the same helpers the builders and the session record
        use — never guessed: build_sessions.image_log_name(entry_id) is the studio twin of
        the builders' IMAGE_LOG_FILE="${WORK_DIR}/build-${BUILD_SUBDIR#wl-}.log", and
        _session.log_path is the shared build.log. A STAGE selection shows its JOB's path:
        stages are slices of that one file, so there is no per-stage file to name. A
        PACKAGE selection names the package's OWN portage log — that file genuinely
        exists per package (unlike stages), so `tail -F` on it is the real per-package
        follow. A package whose log is not on disk yet falls through to the job-level
        help: the job stream IS where that package's output currently lands.
        """
        if self._selected_pkg is not None:
            i, atom = self._selected_pkg
            if 0 <= i < len(self._rows):
                pkg_path = self._pkg_log_path(self._rows[i], atom)
                if pkg_path and os.path.isfile(pkg_path):
                    self._help_cmd = self._watch_command(pkg_path)
                    self.log_copy_btn.setEnabled(True)
                    self.log_help.setText(
                        "This package's own portage log — the same file this pane "
                        "shows. Watch it in a terminal:\n"
                        f"    {self._help_cmd}")
                    return
        if not self._dispatched or self._session is None or not self._rows:
            self._help_cmd = ""
            self.log_help.setText("No build session yet — no log file exists on disk.")
            self.log_copy_btn.setEnabled(False)
            return
        i = self._selected if 0 <= self._selected < len(self._rows) else 0
        img_path = os.path.join(self._session.workdir,
                                build_sessions.image_log_name(self._rows[i].label))
        self._help_cmd = self._watch_command(img_path)
        self.log_copy_btn.setEnabled(True)
        self.log_help.setText(
            "Same stream as this pane — the GUI reads the very file the builder writes. "
            "Watch it in a terminal:\n"
            f"    {self._help_cmd}\n"
            f"    whole run:  {self._watch_command(self._session.log_path)}")

    def _copy_watch_command(self) -> None:
        if self._help_cmd:
            QtWidgets.QApplication.clipboard().setText(self._help_cmd)

    # ---- lifecycle --------------------------------------------------------------
    def initializePage(self) -> None:
        if self.worker is not None and self.worker.isRunning():
            return
        # NO window resize here. This page used to ratchet the window up to 1040x780
        # for build-log readability; that grew but never shrank (so the window stayed
        # oversized on every page after) and ignored the screen entirely (on an 800x800
        # display it made the window bigger than the display). The wizard now OPENS at
        # that same readable size, screen-clamped, for every page — gui/wizard.py
        # medium_size() — so this page gets its readability without the one-way jump.
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
            # per-package portage logs (USE flags + click-to-log) live under the entry's
            # own build tree: <session>/wl-<id>/sysroot/var/log/portage/build — verified
            # on the real session 20260725-140638-09692d and identical for every builder
            # (see the log_root note in _Row.__init__). No per-platform or per-role
            # branch: EVERY worklist entry (mesh node roles and standalone/client roles
            # alike) gets the same package instrumentation.
            self._build_row(i, entry.id, cfg.platform or "x86",
                            log_root=os.path.join(
                                self._session.workdir, entry.build_subdir, "sysroot",
                                "var", "log", "portage", "build"))
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
        # re-dock FIRST, before anything clears: a page reset while the log is detached
        # must not leave the panel (and self.log, which it owns) parented to a window
        # this page no longer tracks. _redock_log is a no-op when already docked.
        self._redock_log()
        self._dispatched = False        # nothing is running -> no log file to point at yet
        self.tree.clear()               # drops every job + stage + package item (and bars)
        self._rows = []
        self._selected = 0
        self._selected_stage = None
        self._selected_pkg = None
        self._pkg_log_size = -1
        self._failures = []
        self._fail_ptr = -1
        self.next_fail_btn.setEnabled(False)
        self._all_terminal = False
        self._sync_back_button()      # a fresh run is in flight -> Back disabled again
        self._manifest_path = ""
        self._keys_done = []
        self.footer.setText("")
        self.log_header.setText("Log")
        self.log.setPlainText("")       # the DOCUMENT clears; the widget itself is alive
        self._refresh_log_help()        # back to "no build session yet"
        self._last_status = None
        self._flash_queue = []
        self._entry_artifacts = {}
        self._entry_artifact_sets = {}
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

    def _build_row(self, index: int, label: str, platform: str,
                   log_root: str = "") -> None:
        row = _Row(index, label, platform, log_root)
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
        # a builder is really launching now, so the per-image log files are real (or are
        # about to be — `tail -F` handles the not-yet-created case): show the paths.
        self._dispatched = True
        self._refresh_log_help()
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
        # SANITISE ONCE, HERE. The builders colour their output unconditionally, so a
        # real line arrives as e.g. "\x1b[1;36m==> Rebranding\x1b[0m" — and the x86
        # emerge output also emits cursor moves ("\x1b[A", "\x1b[72C"). Qt has no glyph
        # for ESC, so every one of them painted a BOX in the log (351 ESCs in a real
        # 53 MB session log). The parser already strip_ansi()es internally, so only the
        # DISPLAY path was ever raw — and it fed THREE operator-visible surfaces: this
        # pane, row.buffer -> error_tail -> the session record/sessions list, and the
        # stage tracker's per-stage slices. strip_ansi is idempotent, so feeding the
        # cleaned line to the parser/tracker changes no phase/stage behaviour.
        # NOT the on-disk build.log: WorklistDriver writes that itself and it KEEPS its
        # colours, which is what makes the watch command's `tail -f` render correctly.
        line = _display_safe(line)
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
        # per-PACKAGE parse — AFTER tracker.feed so tracker.cur already reflects the stage
        # a just-crossed banner opened (a package's group node nests under the stage that
        # is emerging it). feed() is O(1) per line (first-char gated) and returns the ONE
        # row a line moved, or None — so the tree is touched for at most one package per
        # line and never rebuilt. strip_ansi is idempotent, so the _display_safe()d line
        # parses identically to the raw one (same reasoning as the parser/tracker above).
        pkg = row.pkg_parser.feed(line)
        if pkg is not None:
            self._render_package(row, pkg)
        self._write_status()
        self._refresh_overall()
        # live drill-down append: only when the arriving line's target matches the current
        # selection — the whole job (stage None) gets every line; a selected stage gets a
        # line only while it is the running stage of that job. A selected PACKAGE shows a
        # FILE (its portage log, tick-followed), never the stream — appending here would
        # interleave whole-job lines into it.
        if i == self._selected and self._selected_pkg is None:
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
            arts = flash_targets.new_artifacts(self._work_dir(), self._entry_baseline)
            if arts:
                eid = self.driver.results[i].entry.id
                self._entry_artifact_sets[eid] = arts
                # the single auto pick (newest .img else newest) — unchanged contract
                self._entry_artifacts[eid] = flash_targets.pick_artifact(
                    arts, flash_targets.FLAVOR_AUTO)
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

    # ---- per-package rendering (JOB -> STAGE -> GROUP -> PACKAGE) -----------------
    def _group_item(self, row: _Row, group: str) -> QtWidgets.QTreeWidgetItem:
        """Get-or-create the GROUP node for one of the parser's emerge groups, nested
        under the stage that was RUNNING when the group's first package appeared (the
        builder banners into a stage, then emerges inside it — so that stage owns the
        work). A package seen before ANY stage banner (tracker.cur == -1, possible only
        for a builder that emerges before its first `banner` call — none of the six do
        today) nests under the job itself rather than a fabricated stage."""
        item = row.group_items.get(group)
        if item is not None:
            return item
        parent = (row.stage_items[row.tracker.cur] if row.tracker.cur >= 0
                  else row.job_item)
        item = QtWidgets.QTreeWidgetItem(parent)
        item.setData(_COL_NAME, Qt.ItemDataRole.UserRole, (row.index, ("group", group)))
        # GROUP_UNKNOWN ("") = packages portage reported before any `==> Emerge group:`
        # banner. Rendered as "ungrouped" — honestly NOT filed under "image" (the pinned
        # contract: pre-banner group must never be guessed).
        item.setText(_COL_NAME, group or "ungrouped")
        if not group:
            item.setToolTip(_COL_NAME, "The builder announced no emerge group before "
                                       "these packages (pre-banner output).")
        row.group_items[group] = item
        return item

    def _pkg_tooltip(self, pkg: PackageProgress) -> str:
        """The row tooltip: the FULL elog header block (Package/Repository/Maintainer/
        USE/FEATURES — whatever portage actually wrote; a binary merge lacks Maintainer)
        plus the latest build-tool telemetry line. The tool line is elided for the
        tooltip only — a real ninja line can be ~4 KB and Qt renders a plain-text
        tooltip unwrapped."""
        lines = [pkg.atom]
        for key, val in pkg.header.items():
            lines.append(f"{key}: {val}")
        if not pkg.header:
            lines.append("elog header not read yet — no per-package log found so far")
        if pkg.tool_info:
            lines.append(f"tool: {_elide(pkg.tool_info, _TOOL_TIP_CHARS)}")
        return "\n".join(lines)

    def _render_package(self, row: _Row, pkg: PackageProgress) -> None:
        """Reflect ONE package's live parser row onto its tree item — called only when
        feed() reported that row moved, and every widget write below is guarded by the
        last-painted fingerprint, so the 74,998 ninja-counter lines of a real build cost
        a tuple compare + a bar/label write each, and non-package lines cost nothing."""
        atom = pkg.atom
        item = row.pkg_items.get(atom)
        if item is None:
            gitem = self._group_item(row, pkg.group)
            item = QtWidgets.QTreeWidgetItem(gitem)
            item.setData(_COL_NAME, Qt.ItemDataRole.UserRole,
                         (row.index, ("pkg", atom)))
            # the same setItemWidget idiom as the job bar (#348), plus a compact grey
            # tool-telemetry label NEXT TO the bar — live while this package is the
            # current one, keeping its last line afterwards (every row keeps state).
            cell = QtWidgets.QWidget()
            cl = QtWidgets.QHBoxLayout(cell)
            cl.setContentsMargins(0, 0, 0, 0)
            cl.setSpacing(6)
            bar = QtWidgets.QProgressBar()
            bar.setRange(0, 100)                # ladder percent is ALWAYS determinate
            bar.setValue(pkg.percent)
            tool = QtWidgets.QLabel("")
            tool.setStyleSheet("color: gray;")
            cl.addWidget(bar, 1)
            cl.addWidget(tool, 1)
            self.tree.setItemWidget(item, _COL_PROGRESS, cell)
            row.pkg_items[atom] = item
            row.pkg_bars[atom] = bar
            row.pkg_tools[atom] = tool
            row.pkg_progress[atom] = pkg         # live shared object (parser contract)
        shown = (pkg.step, pkg.percent, pkg.failed, len(pkg.use_flags),
                 len(pkg.header), pkg.tool_info)
        last = row.pkg_shown.get(atom)
        if shown == last:
            return
        row.pkg_shown[atom] = shown
        if last is None or last[0] != pkg.step or last[2] != pkg.failed:
            sym, colour = _PKG_GLYPH.get(pkg.step, _PKG_RUNNING_GLYPH)
            item.setText(_COL_NAME, f"{sym}  {atom}")
            item.setForeground(_COL_NAME, QtGui.QBrush(QtGui.QColor(colour)))
            # step transitions also (re)compute the group counter — done counts change
            # exactly then, and (N of M) totals only on Emerging lines (a step change).
            # totals() is only meaningful for the parser's CURRENT group (its documented
            # contract), so past groups keep their last-painted, frozen text.
            if pkg.group == row.pkg_parser.group():
                done, total = row.pkg_parser.totals()
                row.group_items[pkg.group].setText(
                    _COL_PROGRESS, f"{done} of {total} done")
            if pkg.failed:
                # failure focus, package edition: surface the red row (the job/stage
                # failure focus in _on_entry_done lands on the stage's log slice; the
                # expanded group is what makes the culprit PACKAGE visible in the tree).
                self.tree.expandItem(row.group_items[pkg.group])
        if last is None or last[1] != pkg.percent:
            row.pkg_bars[atom].setValue(pkg.percent)
        if pkg.use_flags and (last is None or last[3] != len(pkg.use_flags)):
            flags = " ".join(pkg.use_flags)
            item.setText(_COL_FLAGS, flags)
            item.setToolTip(_COL_FLAGS, flags)   # the cell elides; the tip is the full set
        if pkg.tool_info and (last is None or last[5] != pkg.tool_info):
            tool = row.pkg_tools[atom]
            tool.setText(_elide(pkg.tool_info, _TOOL_CELL_CHARS))
            tool.setToolTip(_elide(pkg.tool_info, _TOOL_TIP_CHARS))
        item.setToolTip(_COL_NAME, self._pkg_tooltip(pkg))

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
        # the package-log follow rides the SAME 1s tick (no second timer): while a
        # package row is selected its on-disk log grows as portage writes it, and the
        # pane reloads only when the file's SIZE changed — a stat per second, a read
        # only on growth.
        self._follow_package_log()

    # ---- drill-down selection ---------------------------------------------------
    def _on_item_clicked(self, item, _col: int = 0) -> None:
        data = item.data(_COL_NAME, Qt.ItemDataRole.UserRole)
        if not data:
            return
        i, j = data
        # payloads: JOB (i, None) / STAGE (i, int) / GROUP (i, ("group", g)) /
        # PACKAGE (i, ("pkg", atom)) — all 2-tuples, so _on_tree_menu's unpack holds.
        if isinstance(j, tuple):
            kind, key = j
            if kind == "pkg":
                self._load_package_detail(i, key)
            else:
                # a GROUP header drills to its OWNING node's log (the stage it nests
                # under, or the job for the pre-stage case) — the group itself has no
                # log of its own and faking one would violate the pane's honesty.
                pdata = item.parent().data(_COL_NAME, Qt.ItemDataRole.UserRole) \
                    if item.parent() is not None else None
                if pdata:
                    pi, pj = pdata
                    self._load_detail(pi, pj if isinstance(pj, int) else None)
            return
        self._load_detail(i, j)

    def _load_detail(self, i: int, stage_j: int | None) -> None:
        """Load the selected node's log into the shared pane: a JOB shows its full raw log;
        a STAGE shows only that stage's captured slice."""
        if not (0 <= i < len(self._rows)):
            return
        row = self._rows[i]
        self._selected = i
        self._selected_stage = stage_j
        self._selected_pkg = None            # back to the stream view
        if stage_j is None:
            self.log.setPlainText("\n".join(row.buffer))
            self.log_header.setText(f"Log — {row.label}")
        else:
            st = row.tracker.stages[stage_j]
            self.log.setPlainText("\n".join(st.lines))
            self.log_header.setText(f"Log — {row.label} ▸ {st.label}")
        # the single funnel for every selection change (_on_item_clicked, _focus_node,
        # failure navigation), so the watch-help always names the SELECTED job's log.
        self._refresh_log_help()

    # ---- package drill-down: the emerge log FILE in the shared pane ---------------
    def _pkg_log_path(self, row: _Row, atom: str) -> str:
        """The package's on-disk emerge log: the parser's resolved path when it has one
        (which, for a failure, is the exact file portage NAMED), else a fresh lookup —
        covering the click-before-resolution window (the parser resolves lazily on step
        transitions). "" when no log exists yet."""
        pkg = row.pkg_progress.get(atom)
        if pkg is not None and pkg.log_path and os.path.isfile(pkg.log_path):
            return pkg.log_path
        return find_package_log(row.log_root, atom)

    def _read_pkg_log(self, path: str) -> str:
        """A TAIL-BOUNDED, display-safe read of a per-package portage log. The elog
        header (and any compile output) arrives ANSI-coloured, and Qt paints a box per
        escape byte (the 2026-07-17 report) — so the whole block goes through the same
        _display_safe used for stream lines (its control-byte class deliberately spares
        LF/TAB, so it is block-safe). Unreadable -> an honest error line, never a silent
        empty pane."""
        try:
            size = os.path.getsize(path)
            with open(path, "rb") as fh:
                if size > _PKG_LOG_TAIL_BYTES:
                    fh.seek(size - _PKG_LOG_TAIL_BYTES)
                text = fh.read().decode("utf-8", errors="replace")
        except OSError as e:
            return f"Could not read the emerge log {path}: {e}"
        text = _display_safe(text)
        if size > _PKG_LOG_TAIL_BYTES:
            mib = size / (1024 * 1024)
            text = (f"… showing the last 2 MiB of {mib:.0f} MiB — "
                    f"full file: {path}\n{text}")
        return text

    def _load_package_detail(self, i: int, atom: str) -> None:
        """Load a PACKAGE's own emerge log into the shared pane (the same single pane +
        header idiom every other selection uses — no second log widget). A log that
        portage has not written yet is said OUT LOUD in the pane, never shown as an
        empty box that reads as an empty log."""
        if not (0 <= i < len(self._rows)):
            return
        row = self._rows[i]
        self._selected = i
        self._selected_stage = None
        self._selected_pkg = (i, atom)
        pkg = row.pkg_progress.get(atom)
        group = (pkg.group if pkg is not None and pkg.group else "ungrouped")
        path = self._pkg_log_path(row, atom)
        if path and os.path.isfile(path):
            try:
                self._pkg_log_size = os.path.getsize(path)
            except OSError:
                self._pkg_log_size = -1
            self.log.setPlainText(self._read_pkg_log(path))
            self.log_header.setText(f"Log — {row.label} ▸ {group} ▸ {atom}")
        else:
            self._pkg_log_size = -1
            where = row.log_root or "<the build's sysroot>/var/log/portage/build"
            if row.terminal:
                self.log.setPlainText(
                    f"No emerge log was written for {atom} in this run.\n"
                    f"Portage writes one under\n    {where}\n"
                    f"when an ebuild starts; this build finished without one for this "
                    f"package (it may never have started, or was merged without "
                    f"logging).")
            else:
                self.log.setPlainText(
                    f"No emerge log for {atom} yet.\n"
                    f"Portage writes it under\n    {where}\n"
                    f"the moment the ebuild starts — this view loads it automatically "
                    f"once it exists.")
            self.log_header.setText(
                f"Log — {row.label} ▸ {group} ▸ {atom} (no log yet)")
        self._refresh_log_help()

    def _follow_package_log(self) -> None:
        """Tick-driven tail-follow of the selected package's log FILE: reload only when
        its size changed (or when a not-yet-written log first appears). One stat per
        second; the bounded reload runs only on growth."""
        if self._selected_pkg is None:
            return
        i, atom = self._selected_pkg
        if not (0 <= i < len(self._rows)):
            return
        path = self._pkg_log_path(self._rows[i], atom)
        if not path or not os.path.isfile(path):
            return                       # still honest "no log yet" — keep waiting
        try:
            size = os.path.getsize(path)
        except OSError:
            return
        if size != self._pkg_log_size:
            self._load_package_detail(i, atom)

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
        # re-dock BEFORE the wizard destroys its children: the detached window is one of
        # them, and it owns the log panel. Reparenting the panel back into this page first
        # means the window can be destroyed without taking self.log's C++ object with it —
        # which would make the next streamed line raise inside the _on_line slot.
        self._redock_log()
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
            flavor = getattr(a, "flavor", flash_targets.FLAVOR_AUTO)
            artifact = flash_targets.pick_artifact(
                self._entry_artifact_sets.get(a.entry_id, ()), flavor)
            if not artifact:
                # legacy single-record store (pre-flavour callers/tests seed only
                # this): honour it when it satisfies the requested flavour.
                single = self._entry_artifacts.get(a.entry_id, "")
                if single and (flavor == flash_targets.FLAVOR_AUTO or
                               flash_targets.classify_artifact_flavor(single) == flavor):
                    artifact = single
            if not artifact:
                built = self._entry_artifact_sets.get(a.entry_id, ())
                if built and flavor != flash_targets.FLAVOR_AUTO:
                    names = ", ".join(os.path.basename(b) for b in built)
                    self.log.appendPlainText(
                        f"Flash plan: {a.entry_id} built no '{flavor}' artifact this "
                        f"run (built: {names}) — skipped rather than writing the "
                        f"wrong image. Check the build's image variant (e.g. build "
                        f"both) or pick 'auto'.")
                else:
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
            flav = "" if flavor == flash_targets.FLAVOR_AUTO else f" [{flavor}]"
            self.log.appendPlainText(
                f"Flash plan: {a.entry_id}{flav} ({os.path.basename(artifact)}) → "
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

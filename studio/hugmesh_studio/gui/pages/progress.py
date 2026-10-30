"""ProgressPage — the terminal build page, present in EVERY mode (slug "progress").

Leaving the Review page commits a WorklistConfig (standalone/cloud = a 1-entry worklist;
mesh = the WorklistPage's selection); the separate Launch screen's Continue then lands here.
This page runs that worklist through :class:`~...core.worklist_driver.WorklistDriver` on a
worker thread and shows ONE row per image — status, a determinate progress bar driven by the
honest banner-phase parser (:mod:`...core.progress_parse`), the current phase, and a per-row
Stop — plus a shared log that switches to the clicked row's ring buffer, and footer lines for
the once-per-worklist steps (mesh manifest written, per-node key-zips generated).

This page's final button is EXIT, not Finish: the build is already running by the time the
page is reached, so pressing it does nothing but close the Studio (see
_widgets.label_finish_as_exit). It is disabled until every row is terminal (ok / failed /
stopped); Back is disabled for free because the Review page is a commit page. Nothing here
fakes a percent — an image whose builder has not yet hit a known phase banner shows an
indeterminate (busy) bar, exactly as :class:`~...core.progress_parse.ProgressParser`
reports it.

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
Each JOB row carries a "Packages ▸" control that opens that image's groups in one click —
present from the first paint but DISABLED and greyed, with the reason in its tooltip, until
that job's OWN emerge phase begins (_sync_pkg_expand / _emerge_started: the group banner,
the first named atom, or portage's scheduler line — never a stage label, which differs per
platform, and never a timer or a percent).

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

import dataclasses
import os
import re
import shlex
import subprocess
import time
import traceback
from collections import deque

from ..qt import QtCore, QtGui, QtWidgets, Qt, Signal
from .. import build_supervisor
from .. import console
from .. import flag_badges
from ..tray import write_build_status
from ...core import build_sessions
from ...core.build_driver import ElevationRefused, guard_elevation
from ...core import flash_targets, flash_validate
from ...core import qemu_tests
from ...core import secret_files
from ...core.emerge_packages import (
    EmergePackageParser, GROUP_UNKNOWN, PackageProgress, STEP_DONE, STEP_FAILED,
    STEP_QUEUED, find_package_log)
from ...core.progress_parse import ProgressParser, platform_phases, strip_ansi
from ...core.stage_tracker import StageTracker
from ...core.worklist_driver import WorklistDriver
from ._widgets import hold_thread, label_finish_as_exit

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


# THE flash confirmation (#337). A module-level override point on purpose: headless tests
# monkeypatch this name, so the one destructive gate the GUI owns is exercised by the
# suite instead of being stubbed away with _start_flash. It is called from
# _start_flash — an explicit click / an explicitly opted-in post-build action — and
# NEVER from validatePage / initializePage / isComplete / itemChanged, where a modal
# deadlocks the offscreen tests.
confirm_flash = QtWidgets.QMessageBox.warning
# what a confirmed flash must return; anything else cancels.
FLASH_OK = QtWidgets.QMessageBox.StandardButton.Ok
FLASH_CANCEL = QtWidgets.QMessageBox.StandardButton.Cancel

# the flash-plan table's status colours (#415) — the same red/green/grey the job tree
# uses, named once so a refusal is never rendered in a colour that reads like "fine".
_FLASH_RED = "#c5221f"
_FLASH_GREEN = "#188038"
_FLASH_GREY = "#888888"


# status id -> (symbol, colour) for the per-JOB status glyph (col0).
_STATUS_GLYPH = {
    "queued": ("○", "#888888"),
    "running": ("●", "#1a73e8"),
    "ok": ("✓", "#188038"),
    "failed": ("✗", "#c5221f"),
    "stopped": ("■", "#888888"),
    # a finished one-shot on the Local-mesh monitor (#378): done, neither running nor
    # halted — a grey check, never the green ✓ of a healthy service.
    "completed": ("✔", "#5f6368"),
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

# tree column indices — SYMBOLIC ONLY (renumbered when Flags landed, and again when the
# four PACKAGE-FLAG columns landed; nothing may hardcode these). Reading order for a
# package row is name -> bar+tool -> elog USE -> the four portage-flag columns, with Time
# staying the trailing narrow one.
#
# _COL_FLAGS is the ORIGINAL, always-available column: the flat enabled-only USE list out
# of the package's own elog header (docs/PACKAGE-FLAG-BADGES.md §3.1). It also hosts the
# per-job "show packages" button on job rows. The four columns after it are the RICHER,
# conditionally-available ones — resolver merge-list state (§2) + VDB (§3) — and each is
# hidden until some row actually has content for it (§5 "empty column ⇒ no column").
_COL_NAME, _COL_PROGRESS, _COL_FLAGS = 0, 1, 2
_COL_USE_EXPAND, _COL_USE, _COL_KEYWORDS, _COL_LICENSE = 3, 4, 5, 6
_COL_TIME = 7

#: badge-column key -> tree column index, in flag_badges.FLAG_COLUMNS order.
_FLAG_COLS = {
    "USE_EXPAND": _COL_USE_EXPAND,
    "USE": _COL_USE,
    "KEYWORDS": _COL_KEYWORDS,
    "LICENSE": _COL_LICENSE,
}

#: What the Configure-view dialog offers, in tree order: (column index, label, key).
#: ``key`` is the flag_badges key for the four badge columns and None for the plain
#: ones. _COL_NAME is deliberately ABSENT — hiding the identity column would leave
#: rows the operator cannot tell apart, which is not a view preference but a broken
#: view. Everything else is fair game.
_CONFIGURABLE_COLUMNS: tuple[tuple[int, str, str | None], ...] = (
    (_COL_PROGRESS,    "Progress",   None),
    (_COL_FLAGS,       "Flags",      None),
    (_COL_USE_EXPAND,  "USE_EXPAND", "USE_EXPAND"),
    (_COL_USE,         "USE",        "USE"),
    (_COL_KEYWORDS,    "KEYWORDS",   "KEYWORDS"),
    (_COL_LICENSE,     "LICENSE",    "LICENSE"),
    (_COL_TIME,        "Time",       None),
)

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

# ── LINE COALESCING: the drain clock ───────────────────────────────────────────────────
# 50 ms (~20 Hz) is the same figure localmesh.py's drain uses and for the same reason: it
# is below the ~100 ms threshold at which a UI starts to read as laggy, so the pane still
# looks live, while the per-line cost of delivery collapses from O(lines) to O(ticks).
_DRAIN_MS = 50

#: LIVE log-pane block cap. A QPlainTextEdit's document grows without bound as long as
#: something appends to it, and this page's stream is measured at 3.16M lines / 353 MB for
#: ONE x86 build (core/emerge_packages.py:12) — an hours-long build therefore ended with a
#: multi-hundred-MB document whose every repaint got slower.
#:
#: Capping the LIVE pane loses nothing that was recoverable anyway: the authoritative raw
#: log of a job is _Row.buffer, itself a deque(maxlen=4000), and clicking the job row
#: reloads the pane from THAT (see _load_detail). A stage slice is bounded at
#: stage_tracker._STAGE_LOG_MAXLEN = 2000. 20,000 blocks is therefore 5x the largest
#: drill-down the page can restore — the cap can only ever drop lines the drill-down had
#: already dropped. The one view that is NOT bounded this way is a PACKAGE's own on-disk
#: emerge log (_PKG_LOG_TAIL_BYTES, up to 2 MiB of file), so the cap is lifted for that
#: pane and re-applied on any return to a stream view (_set_log_cap).
_LOG_MAX_BLOCKS = 20000

# ── the per-JOB package-list affordance ────────────────────────────────────────────────
# Operator, 2026-07-29, after watching a live build with the per-package tree: "we can see
# the packages now in the current builder and this is good leave this as a default with the
# option to expand greyed out until things reach the emerge phase". They had opened the tree
# while the job was still at "Verify seed" — a control that looks live and yields nothing
# reads as a broken feature, so the control is present from the first paint but DISABLED
# (Qt greys a disabled QToolButton; the :disabled rule below pins the grey rather than
# trusting the active style) and carries the honest reason as its tooltip. It enables per
# job, the moment THAT job's emerge phase really starts — see ProgressPage._sync_pkg_expand.
_PKG_EXPAND_TEXT = "Packages ▸"
_PKG_EXPAND_HINT = "packages appear once the build reaches the emerge phase"
_PKG_EXPAND_READY_HINT = ("Show this image's packages — expands its emerge groups "
                          "in the tree")
_PKG_EXPAND_QSS = ("QToolButton { padding: 0px 6px; } "
                   "QToolButton:disabled { color: #888888; }")


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
        # NEVER let an exception escape this thread. run_all() can raise BEFORE the
        # per-image loop starts — a mesh writes its manifest into the session workdir
        # first, so an unwritable <out>/sessions/ (root-owned, e.g. left behind by an
        # earlier NATIVE sudo build) raises PermissionError there. Escaping, the QThread
        # died with finished_all NEVER emitted: every row stayed "pending", the overall
        # bar sat at "queued - image 1 of N", the log pane stayed empty, and the GUI
        # waited forever with no error anywhere. The sibling _FlashWorker below already
        # guards its run() this way; this one did not.
        try:
            code = self.driver.run_all(
                on_entry_start=lambda i: self.entry_start.emit(i),
                on_line=lambda i, ln: self.line.emit(i, ln),
                on_entry_done=lambda i, c: self.entry_done.emit(i, c),
                on_manifest=lambda p: self.manifest.emit(p),
                on_keys=lambda i, p, ok: self.keys.emit(i, p, ok))
        except BaseException as e:  # noqa: BLE001 - a hung GUI is worse than any re-raise
            # Surface it where the operator is already looking (the log pane), then end
            # the run non-zero so the UI leaves "queued" and Exit/Back become usable.
            self.line.emit(0, f"!! build run aborted before completion: {e}")
            for ln in traceback.format_exc().rstrip().splitlines():
                self.line.emit(0, f"   {ln}")
            self.finished_all.emit(1)
            return
        self.finished_all.emit(code)


class _FlashWorker(QtCore.QThread):
    """Runs scripts/flash-disk.sh (via flash_targets.flash_argv) off the GUI thread,
    streaming its stdout into the log pane — the same QThread pattern as _WorklistWorker
    / build.py's _BuilderImageWorker. It NEVER re-implements dd: the script does the real
    write plus dl_require_root / unmount / whole-disk refusal / size-fit. Every launch of
    this worker goes through ProgressPage._start_flash, which shows the ONE OK/Cancel
    warning first (#337) — that dialog, not a typed device path, is the gate, because the
    argv carries --no-confirm and so skips the script's own dl_confirm_destroy."""
    line = Signal(str)
    done = Signal(int)

    def __init__(self, argv: list[str], cwd: str):
        super().__init__()
        self._argv = argv
        self._cwd = cwd

    def run(self) -> None:
        try:
            # #304: this worker owns its own Popen, so BuildDriver._spawn's guard does not
            # cover it. flash_argv() starts with `sudo -A`; guard_elevation refuses it
            # under HUGMESH_STUDIO_NO_ELEVATION / pytest BEFORE the spawn (and before any
            # prompt), and the refusal is reported like any other launch failure instead
            # of escaping a QThread.run (PyQt6 qFatal).
            guard_elevation(self._argv)
            proc = subprocess.Popen(self._argv, cwd=self._cwd, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True, bufsize=1)
        except (OSError, ElevationRefused) as e:
            self.line.emit(f"!! could not launch the flasher: {e}")
            self.done.emit(1)
            return
        assert proc.stdout is not None
        for ln in proc.stdout:
            self.line.emit(ln.rstrip("\n"))
        self.done.emit(proc.wait())


class _ImageCheckWorker(QtCore.QThread):
    """Runs the #415 image validator off the GUI thread (flash_validate.check_image).

    It NEVER opens a device and NEVER flashes: every check is a read of the ARTIFACT
    (stat, the first 32 KiB, `xz --robot --list`, and hashlib when the build left a
    checksum). It is a thread because hashing a multi-GiB image, and the xz index read
    on a slow disk, would otherwise freeze the window."""
    done = Signal(object)          # list[flash_validate.ImageReport]

    def __init__(self, jobs: list[dict]):
        super().__init__()
        self._jobs = jobs

    def run(self) -> None:
        out = []
        for j in self._jobs:
            try:
                out.append(flash_validate.check_image(**j))
            except Exception as e:      # a check must never take the window with it
                out.append(flash_validate.ImageReport(
                    j.get("path", ""), j.get("device_path", ""),
                    (flash_validate.Check("check", flash_validate.BAD,
                                          f"the check itself failed: {e}"),)))
        self.done.emit(out)


class _DetachedLogWindow(QtWidgets.QWidget):
    """The top-level window the log panel is popped into by "Detach ⇱".

    Two deliberate ownership choices, both relied on (see ProgressPage._detach_log):

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
        # per-package FLAG state (docs/PACKAGE-FLAG-BADGES.md): streamed resolver
        # merge-list rows + the build's own VDB. Both roots come off the SAME log_root the
        # package parser already uses — the sysroot is log_root minus its fixed
        # var/log/portage/build tail, and the session dir is the sysroot's grandparent
        # (<workdir>/wl-<id>/sysroot) — so nothing here hardcodes a session path and an
        # empty log_root (direct-slot tests) degrades to a pure stream join with no
        # filesystem access at all.
        sysroot = flag_badges.sysroot_from_log_root(log_root)
        self.flag_join = flag_badges.ImageFlagJoin(
            sysroot,
            flag_badges.descriptions_for_session(
                os.path.dirname(os.path.dirname(sysroot)) if sysroot else ""))
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
        # PARALLEL emerge (--jobs). The same skip-the-no-op discipline, one level up: the
        # parser bumps SchedulerState.revision whenever its ">>> Jobs:" figures or its
        # in-flight atom set change, and 1752 of a real rpi5 build's 22,025 lines are those
        # status lines — so the aggregate is repainted on a revision change, not per line.
        self.sched_rev = -1
        self.pkg_parallel_shown = False   # group node auto-expanded once, on detection
        # one-shot latch: a fault on the per-package log-follow path disables the follow for
        # this row instead of re-raising every tick (see ProgressPage._poll_packages).
        self.pkg_poll_off = False
        # the per-job package-list affordance + its ONE-WAY latch. False = this job has not
        # reached its emerge phase, so the control is present but disabled and greyed; it
        # flips exactly once, on this job's own first emerge evidence, and never back (a
        # finished build keeps its packages browsable). See ProgressPage._sync_pkg_expand.
        self.pkg_btn: QtWidgets.QToolButton | None = None
        self.pkg_expandable = False


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
        self.setSubTitle("One progress bar per image. Exit is enabled once every build "
                         "has finished, failed, or stopped.")
        # The build is ALREADY running by the time this page is reached — the final
        # button starts nothing and writes nothing, it only closes the Studio, so it
        # says Exit (_widgets.label_finish_as_exit).
        label_finish_as_exit(self)
        lay = QtWidgets.QVBoxLayout(self)

        # ── view controls: a single "Configure view" entry point above everything
        # else, so the operator can add/remove columns without hunting for a header
        # context menu. Right-aligned on its own row: it is a view preference, not a
        # build action, and must not sit in the same visual rank as Exit/Stop.
        view_row = QtWidgets.QHBoxLayout()
        view_row.addStretch(1)
        self.configure_view_btn = QtWidgets.QToolButton()
        self.configure_view_btn.setText("Configure view ▾")
        self.configure_view_btn.setToolTip(
            "Choose which columns this table shows.\n"
            "Badge columns normally appear on their own once a package supplies that "
            "flag; ticking or unticking one here overrides that for the rest of the "
            "session.")
        self.configure_view_btn.setAutoRaise(True)
        self.configure_view_btn.clicked.connect(self._open_view_config)
        view_row.addWidget(self.configure_view_btn)
        lay.addLayout(view_row)

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
        self.tree.setColumnCount(8)
        # Flags: per-PACKAGE USE flags from the elog header of the package's own portage
        # log (there is NO stream-side source — the whole 3.16M-line reference transcript
        # contains zero "USE:" lines; see emerge_packages.py). Job/stage rows leave it "".
        #
        # USE_EXPAND / USE / KEYWORDS / LICENSE are the badge columns
        # (docs/PACKAGE-FLAG-BADGES.md). USE_EXPAND is deliberately NOT called
        # "package.env": PYTHON_TARGETS/ABI_X86/CPU_FLAGS_* are USE_EXPAND variables set in
        # package.use / make.conf, while /etc/portage/package.env maps atoms to environment
        # FILES and has nothing to do with these (§3.1).
        self.tree.setHeaderLabels(["Job / Stage / Package", "Progress", "Flags",
                                   "USE_EXPAND", "USE", "KEYWORDS", "LICENSE", "Time"])
        self.tree.setColumnWidth(_COL_NAME, 320)
        self.tree.setColumnWidth(_COL_PROGRESS, 220)
        self.tree.setColumnWidth(_COL_FLAGS, 180)
        for _c in _FLAG_COLS.values():
            self.tree.setColumnWidth(_c, 220)
        # the badge columns' owner: installs ONE painting delegate across all four (no
        # per-badge child widgets — a real build has 300+ packages) and keeps every column
        # hidden until a row gives it content.
        self.flag_columns = flag_badges.FlagColumns(self.tree, _FLAG_COLS)
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
        # BOUNDED DOCUMENT — see _LOG_MAX_BLOCKS. Without this an hours-long build grows
        # the QTextDocument to millions of blocks and every repaint pays for all of them.
        self.log.setMaximumBlockCount(_LOG_MAX_BLOCKS)
        # Monospace + no wrap. Portage aligns its USE-flag columns with spaces, and in a
        # proportional face those columns do not line up at all; a wrapped 200-char
        # compiler line destroys the same alignment, so a horizontal scrollbar is the
        # honest trade. (attach() re-applies the block cap set just above.)
        console.attach(self.log, _LOG_MAX_BLOCKS)
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
        fg = QtWidgets.QVBoxLayout(self.flash_group)
        # ── row 1: WHICH IMAGE (#415) ─────────────────────────────────────────────
        # Before #415 this group held a device dropdown and nothing else: the image was
        # chosen FOR the operator by flash-disk.sh's newest-.img-else-newest-.iso glob,
        # so an x86 run emitting .img.xz + .live.iso + .installer.iso could only ever
        # flash the .img.xz — the other two were unreachable from this page, and the
        # confirmation said "auto-picked by scripts/flash-disk.sh" rather than a name.
        # This combo lists the artifacts THIS run actually produced (newest first) and
        # defaults to the same pick_artifact("auto") file the glob would have taken, so
        # an operator who never touches it writes exactly what they wrote before.
        r1 = QtWidgets.QHBoxLayout()
        r1.addWidget(QtWidgets.QLabel("Image:"))
        self.flash_image_combo = QtWidgets.QComboBox()
        self.flash_image_combo.setToolTip(
            "WHICH built image is written. Lists every flashable artifact this run "
            "produced, newest first; the default is the one scripts/flash-disk.sh "
            "would have auto-picked (newest .img, else newest). The choice is passed "
            "as --artifact and is named in the confirmation before anything is "
            "written.")
        self.flash_image_combo.setSizeAdjustPolicy(
            QtWidgets.QComboBox.SizeAdjustPolicy.AdjustToMinimumContentsLengthWithIcon)
        r1.addWidget(self.flash_image_combo, 1)
        self.flash_check_btn = QtWidgets.QPushButton("Check image(s)")
        self.flash_check_btn.setToolTip(
            "Validate the selected image(s) WITHOUT flashing: the file exists and is "
            "readable, its format magic is right (xz container / ISO9660 / MBR or "
            "GPT), the size that will actually be WRITTEN fits the target (an .img.xz "
            "expands — the size on disk is not the size written), the name carries the "
            "target's arch and role and the planned flavour, and the sha256 matches "
            "when the build left one. Nothing is written.")
        self.flash_check_btn.clicked.connect(self._check_images_clicked)
        r1.addWidget(self.flash_check_btn)
        fg.addLayout(r1)
        # ── row 2: WHICH DEVICE (unchanged) ───────────────────────────────────────
        r2 = QtWidgets.QHBoxLayout()
        r2.addWidget(QtWidgets.QLabel("Device:"))
        self.flash_combo = QtWidgets.QComboBox()
        r2.addWidget(self.flash_combo, 1)
        self.flash_refresh_btn = QtWidgets.QPushButton("Refresh")
        self.flash_refresh_btn.clicked.connect(self._refresh_flash_targets)
        r2.addWidget(self.flash_refresh_btn)
        self.flash_btn = QtWidgets.QPushButton("Flash…")
        self.flash_btn.clicked.connect(self._flash_clicked)
        r2.addWidget(self.flash_btn)
        fg.addLayout(r2)
        # ── row 3: the validator's INLINE report (#415 D) ─────────────────────────
        # Read-only text, never a dialog: a modal here would deadlock the offscreen
        # suite, and the house rule keeps confirm_flash as the ONE dialog on this page.
        self.flash_check_out = QtWidgets.QPlainTextEdit()
        self.flash_check_out.setReadOnly(True)
        self.flash_check_out.setMaximumHeight(150)
        self.flash_check_out.setVisible(False)
        fg.addWidget(self.flash_check_out)
        self.flash_group.setVisible(False)
        lay.addWidget(self.flash_group)          # below the splitter, beside the action bar
        # Where flashing cannot work on this host (native Windows; WSL with no USB
        # attached) there are never any targets, so the group above never appears.
        # After an all-ok run this note takes its place and says why, with the fix.
        self.flash_blocked_note = QtWidgets.QLabel()
        self.flash_blocked_note.setWordWrap(True)
        self.flash_blocked_note.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse)
        self.flash_blocked_note.setVisible(False)
        lay.addWidget(self.flash_blocked_note)

        # ── post-build FLASH PLAN table (#415, mesh / multi-entry) ────────────────
        # The Review page plans entry -> device. Until #415 the IMAGE half of that was
        # a 3-value flavour AXIS chosen before anything was built, and at flash time
        # the resolved filename appeared only inside one OK/Cancel dialog, one device
        # at a time. This table states the whole plan at once — entry, the exact file,
        # the device — and lets the image be changed per row before that row is
        # written. A row whose planned flavour was NOT built keeps its LOUD refusal:
        # its combo defaults to an explicit "none — will be SKIPPED", never to some
        # other file, so a silent skip can never become a silent default.
        self.flash_plan_box = QtWidgets.QGroupBox(
            "Flash plan — which image goes to which device")
        fpl = QtWidgets.QVBoxLayout(self.flash_plan_box)
        self.flash_plan_table = QtWidgets.QTableWidget(0, 4)
        self.flash_plan_table.setHorizontalHeaderLabels(
            ["Build entry", "Image", "Device", "Status"])
        self.flash_plan_table.verticalHeader().setVisible(False)
        self.flash_plan_table.setEditTriggers(
            QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
        self.flash_plan_table.setSelectionMode(
            QtWidgets.QAbstractItemView.SelectionMode.NoSelection)
        self.flash_plan_table.setMaximumHeight(160)
        fpl.addWidget(self.flash_plan_table)
        self.flash_plan_box.setVisible(False)
        lay.addWidget(self.flash_plan_box)

        # ── per-image WRITE PROGRESS (#415) ───────────────────────────────────────
        # Before #415 a flash was log lines only: `==> Writing img to /dev/sdz (this
        # can take a while)` and then dd's byte counters scrolling past — no bar, and
        # on a multi-image plan no way to tell image 2 of 3 from image 3 of 3.
        #
        # This bar is driven by BYTES, never by a timer. Numerator: GNU dd's own
        # status=progress updates, which all three of flash-disk.sh's write arms
        # already emit. Denominator: the `Write-bytes:` line flash-disk.sh now prints
        # immediately before dd starts (its ART_SIZE — the UNCOMPRESSED size for a
        # .img.xz, i.e. what actually lands on the disk). When no denominator arrives
        # the bar goes INDETERMINATE and the label says so, rather than inventing a
        # percentage out of elapsed time.
        self.flash_progress_box = QtWidgets.QWidget()
        fpb = QtWidgets.QVBoxLayout(self.flash_progress_box)
        fpb.setContentsMargins(0, 0, 0, 0)
        self.flash_progress_label = QtWidgets.QLabel("")
        self.flash_progress_label.setWordWrap(True)
        fpb.addWidget(self.flash_progress_label)
        self.flash_progress_bar = QtWidgets.QProgressBar()
        self.flash_progress_bar.setRange(0, 100)
        self.flash_progress_bar.setValue(0)
        self.flash_progress_bar.setTextVisible(False)
        fpb.addWidget(self.flash_progress_bar)
        self.flash_progress_box.setVisible(False)
        lay.addWidget(self.flash_progress_box)

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

        # ── LINE COALESCING — why the window used to freeze ───────────────────────────
        # _WorklistWorker emits ONE queued signal PER OUTPUT LINE, and the old slot ran
        # the whole pipeline inline for each: sanitise -> flag join -> raw buffer ->
        # ProgressParser -> _apply_state (bar + phase label) -> StageTracker ->
        # EmergePackageParser -> _render_package -> _render_scheduler -> _sync_pkg_expand
        # -> _write_status -> _refresh_overall -> appendPlainText. Six of those touch a
        # widget, so the GUI thread paid a repaint request PER LINE.
        #
        # That is the same defect localmesh.py's drain fixed, on a far bigger stream: the
        # kind-up burst that froze the window there is "tens of thousands" of lines, while
        # ONE real x86 build measured 3.16M lines / 353 MB (core/emerge_packages.py:12) —
        # and this page drives every image build, the product's longest verb. The builds
        # were ALWAYS off-thread; it was the DELIVERY that blocked.
        #
        # Now the worker's signal does one cheap thing — append to this deque — and a
        # ~20 Hz drain runs the pipeline for the whole batch. The PARSING half still runs
        # per line, in arrival order, so the per-package emerge ladder, the stage slices
        # and the flag join are accounted EXACTLY as before; only the RENDERING is
        # batched: one bar/phase write per row per tick, one package repaint per moved
        # atom per tick, one status + overall refresh, one appendPlainText. Cost becomes
        # O(ticks), not O(lines). Nothing is dropped — every line still reaches
        # row.buffer, the parsers and the tracker.
        self._line_inbox: deque[tuple[int, str]] = deque()
        self._drain = QtCore.QTimer(self)
        self._drain.setInterval(_DRAIN_MS)
        self._drain.timeout.connect(self._drain_lines)
        # flash-to-a-device state (post-build)
        self.flash_worker: _FlashWorker | None = None
        # post-build QEMU emulated-device tests (BuildPage's qemu_device_tests opt-in) — its own
        # worker slot, never flash_worker's: a flash plan and a device-test run are
        # independent opt-ins and must not steal each other's done signal.
        self.qemu_worker: _FlashWorker | None = None
        # #415: the read-only image validator's thread — its OWN slot, never
        # flash_worker's, so a check can never be mistaken for a write in progress.
        self.check_worker: _ImageCheckWorker | None = None
        self._flash_targets: list = []
        # #415: the last candidate tuple the Image combo was built from. The 2.5 s
        # device timer re-enters _refresh_flash_images, and repopulating an unchanged
        # combo would reset the operator's pick under their cursor every 2.5 s.
        self._flash_image_cands: tuple[str, ...] | None = None
        # #415 write-progress state. _flash_write_total is the denominator from
        # flash-disk.sh's `Write-bytes:` line (0 = unknown -> indeterminate bar, never
        # a made-up percentage); _flash_write_done is dd's own byte counter.
        self._flash_plan_pos = 0
        # #415: WHICH plan-table row the in-flight flash belongs to, or -1 when the
        # flash came from anywhere else (the Flash… button, the legacy single-target
        # stash). _flash_done paints the outcome onto THIS row. Deriving the row from
        # _flash_plan_pos instead let an unrelated later standalone flash repaint the
        # LAST plan row, so a device that failed — or was never written at all — could
        # end up reading "written".
        self._flash_active_row = -1
        # Set by _start_flash when it refuses to start because the previous flasher is
        # still running; read by _flash_next, which must then say that row was NOT
        # started rather than leave it claiming "writing…" forever.
        self._flash_busy_skipped = False
        self._flash_image_index = 0        # 1-based "image N of M"
        self._flash_image_total = 0
        self._flash_image_name = ""
        self._flash_write_total = 0
        self._flash_write_done = 0
        self._flash_rate = ""
        self._flash_queue: list = []       # Review-page plan assignments, run sequentially
        # confirmation state (#337): the extra notes the ONE flash warning shows, and
        # whether the operator declined the last one. Both are consumed inside
        # _start_flash / _flash_next and never outlive a single dialog.
        self._flash_caveats: list[str] = []
        self._flash_cancelled = False
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
        # ASK 16 — a window CLOSE must not stop a build.
        #
        # This used to be `self.wiz.finished.connect(self._abort_run)`: QWizard is a
        # QDialog, so `finished` fires on an ordinary close, and closing the Studio
        # cancelled the builder and joined the worker. "Builds continue in the
        # background" was not merely missing — the opposite was wired up.
        #
        # Now the close DETACHES the window's furniture (re-dock the log, stop the
        # cosmetic timers) and leaves the run alone. The run itself is owned by
        # gui/build_supervisor.py, which is parented to the QApplication and holds the
        # window alive until the build finishes, so this page's slots always have a
        # live C++ object to land on (the deleted-object-in-a-slot crash the
        # _DetachedLogWindow docstring documents). A REAL exit still cancels — that is
        # supervisor().cancel_all() on QApplication.aboutToQuit, wired in gui/shell.py.
        self.wiz.finished.connect(self._detach_from_window)
        # the supervisor's record for the run this page dispatched (set in _start_worker)
        self._supervised = None

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

    def _set_log_cap(self, capped: bool) -> None:
        """Bound the log document, or lift the bound for a FILE view.

        Capped is the normal state (see _LOG_MAX_BLOCKS): the live stream is unbounded and
        every drill-down it can restore is itself a bounded ring buffer, so the cap can
        only drop lines the drill-down had already dropped. A PACKAGE's own emerge log is
        the exception — that pane shows a real file, tail-read at up to
        _PKG_LOG_TAIL_BYTES, and a cap would silently eat the HEAD of what was read. So
        the bound is lifted for exactly that view and re-applied on any return to a stream
        view. Nothing appends to the pane while a package is selected (_consume_line
        returns None for a _selected_pkg), so the uncapped window cannot grow."""
        self.log.setMaximumBlockCount(_LOG_MAX_BLOCKS if capped else 0)

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
        # RESTART secret-file re-collection (2026-07-29 ask: "if the build is
        # restarted, a prompt appears to reenter when it is needed"): when the pending
        # id names an EXISTING record whose dispatch consumed held-in-memory secret
        # files (core/secret_files.py), every one missing from THIS process's vault
        # must be re-selected BEFORE dispatch — a fresh Studio process cannot have
        # them (content is never persisted), and silently falling back to the
        # snapshot's stale PATH would sign with material the operator never
        # re-approved for this run (or dead-end on an unplugged USB an hour in).
        # Declining aborts honestly: nothing is dispatched, nothing is written
        # (new_session/start never run), the record keeps its prior truth.
        abort = self._collect_missing_held_files(wl)
        if abort:
            self.log.setPlainText(abort)
            self._all_terminal = True
            self.completeChanged.emit()
            self._sync_back_button()
            return
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

    # ---- held-in-memory secret files: the RESTART re-collection gate --------------
    def _collect_missing_held_files(self, wl) -> str:
        """Ensure every secret file the pending session's PRIOR dispatch consumed from
        the vault is in THIS process's vault, prompting the operator to re-select each
        missing one. Returns "" to proceed, or the honest abort message ("Build not
        started: …") when the operator declines / cancels a picker — the caller MUST
        then refuse dispatch. A fresh pending id (no record on disk yet — the normal
        first-build path) and a record that consumed nothing both pass untouched."""
        sid = getattr(self.wiz, "pending_session_id", None)
        if not sid:
            return ""
        try:
            prior = build_sessions.load(
                os.path.join(build_sessions.sessions_dir(), f"{sid}.json"))
        except (OSError, ValueError):
            return ""            # BuildPage's freshly minted preview id — no record yet
        missing = secret_files.missing_for_restart(
            getattr(prior, "held_secret_files", []))
        for rec in missing:
            if not self._reprompt_held_file(rec, wl):
                label = secret_files.FIELD_LABELS.get(
                    rec.get("field", ""), rec.get("field", "secret file"))
                return (f"Build not started: {label} ({rec.get('name', '?')}) was held "
                        f"only in the memory of the Studio process that dispatched this "
                        f"session — held secret files are never saved to disk, configs "
                        f"or session records — and it was not re-selected. Nothing was "
                        f"dispatched; the recorded path was NOT silently reused. Use "
                        f"Restart again to re-select it.")
        return ""

    def _reprompt_held_file(self, rec: dict, wl) -> bool:
        """One missing item: explain WHAT is needed and WHY, then re-select + re-hold
        it. True only when the item is held again; any cancel/decline is False (the
        caller aborts the dispatch). The re-selected path is written back onto the
        worklist base so the dispatch's origin pin (build_driver._consume_held_
        secret_files) matches — and new_session then snapshots that truth."""
        field = rec.get("field", "")
        label = secret_files.FIELD_LABELS.get(field, field)
        name = rec.get("name", "?")
        fp = str(rec.get("sha256", ""))[:12] or "unknown"
        why = secret_files.FIELD_WHY.get(field, "the build consumes it")
        box = QtWidgets.QMessageBox(self)
        box.setWindowTitle("Restart needs a secret file re-selected")
        box.setText(
            f"This session's build used {label}:\n    {name} · sha256 {fp}\n\n"
            f"It was held only in the memory of the Studio process that dispatched it "
            f"(held secret files are never saved to disk, configs or session records), "
            f"so this restart must re-collect it before the build can start.\n\n"
            f"Why it is needed: {why}.\n\nRe-select it now?")
        box.setStandardButtons(QtWidgets.QMessageBox.StandardButton.Ok
                               | QtWidgets.QMessageBox.StandardButton.Cancel)
        box.button(QtWidgets.QMessageBox.StandardButton.Ok).setText("Re-select…")
        if box.exec() != QtWidgets.QMessageBox.StandardButton.Ok:
            return False
        while True:
            if field == "keys_usb":
                p = QtWidgets.QFileDialog.getExistingDirectory(self, label)
            else:
                p, _sel = QtWidgets.QFileDialog.getOpenFileName(
                    self, label, "", "All files (*)")
            if not p:
                return False                       # picker cancelled -> honest abort
            try:
                entry = secret_files.vault().hold(field, p)
            except (OSError, ValueError) as e:     # unreadable / empty keys dir / oversized
                QtWidgets.QMessageBox.warning(
                    self, "Cannot hold that selection", f"{e}\n\nPick again or Cancel.")
                continue
            break
        # Same-file honesty, informational only: a rotated key is a legitimate operator
        # choice, so a fingerprint change is REPORTED (log pane), never blocked.
        if rec.get("sha256") and entry.sha256 != rec.get("sha256"):
            self.log.appendPlainText(
                f"NOTE: re-selected {label} has a different fingerprint "
                f"(sha256 {entry.fingerprint}) than the previous run ({fp}) — "
                f"building with the newly selected file.")
        # keep the dispatched config in step with the fresh selection so the origin
        # pin consumes it (and the updated record snapshot tells the truth).
        setattr(wl.base, field, entry.origin)
        return True

    def _reset(self) -> None:
        self._tick.stop()
        # Drop any output still banked from a previous run BEFORE self._rows goes away —
        # a stale (index, line) pair belongs to rows that no longer exist.
        self._drain.stop()
        self._line_inbox.clear()
        # re-dock FIRST, before anything clears: a page reset while the log is detached
        # must not leave the panel (and self.log, which it owns) parented to a window
        # this page no longer tracks. _redock_log is a no-op when already docked.
        self._redock_log()
        self._dispatched = False        # nothing is running -> no log file to point at yet
        self.tree.clear()               # drops every job + stage + package item (and bars)
        # the badge columns go back to all-hidden: a fresh run must not show last run's
        # columns (§5 "empty column ⇒ no column" is a property of what is on screen NOW).
        self.flag_columns.reset()
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
        self._flash_caveats = []
        self._flash_cancelled = False
        self._entry_artifacts = {}
        self._entry_artifact_sets = {}
        self._entry_baseline = {}
        # #415: the PREVIOUS run's images must not linger in the Image combo — a
        # second build on the same page instance would otherwise offer, and default
        # to, a file the new run never produced.
        self._flash_image_cands = None
        self.flash_image_combo.clear()
        self._flash_plan_pos = 0
        self._flash_active_row = -1
        self._flash_busy_skipped = False
        self._flash_image_index = 0
        self._flash_image_total = 0
        self._flash_image_name = ""
        self._flash_write_total = 0
        self._flash_write_done = 0
        self._flash_rate = ""
        self.flash_progress_bar.setRange(0, 100)
        self.flash_progress_bar.setValue(0)
        self.flash_progress_label.setText("")
        self.flash_progress_box.setVisible(False)
        self.flash_check_out.setPlainText("")
        self.flash_check_out.setVisible(False)
        self.flash_plan_table.setRowCount(0)
        self.flash_plan_box.setVisible(False)
        self.flash_group.setVisible(False)        # only an all-ok finish reveals it
        self.flash_blocked_note.setVisible(False)  # ... or, where flashing cannot work, this
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
        # JOB item (top-level) — the GitHub-Actions "all jobs listed up front" convention.
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
        # the PACKAGE-LIST affordance, in the job row's otherwise-empty Flags cell (the same
        # setItemWidget idiom as the bar above; only PACKAGE rows write Flags text). Created
        # DISABLED with the honest hint — nothing enables it but this job's own emerge phase
        # beginning (_sync_pkg_expand). It lives on the top-level job row, so collapsing or
        # re-expanding the job never touches it.
        row.pkg_btn = QtWidgets.QToolButton()
        row.pkg_btn.setText(_PKG_EXPAND_TEXT)
        row.pkg_btn.setAutoRaise(True)
        row.pkg_btn.setStyleSheet(_PKG_EXPAND_QSS)
        row.pkg_btn.setEnabled(False)
        row.pkg_btn.setToolTip(_PKG_EXPAND_HINT)
        row.pkg_btn.clicked.connect(lambda _=False, i=index: self._expand_packages(i))
        self.tree.setItemWidget(job_item, _COL_FLAGS, row.pkg_btn)
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
        self.worker = hold_thread(_WorklistWorker(self.driver))
        self.worker.entry_start.connect(self._on_entry_start)
        self.worker.line.connect(self._on_line)
        self.worker.entry_done.connect(self._on_entry_done)
        self.worker.manifest.connect(self._on_manifest)
        self.worker.keys.connect(self._on_keys)
        self.worker.finished_all.connect(self._on_finished_all)
        self._write_status()                  # building 0% -> the tray shows a badge
        if self._session is not None:         # START record: status "running" + pid
            build_sessions.start(self._session)
        # ASK 16 — hand the run to the process-wide supervisor BEFORE starting it. From
        # here the worker's Qt parent is the supervisor (not this page, not the window)
        # and the supervisor pins the window alive until the run ends, so closing the
        # window cannot destroy the C++ objects this page's slots stream into.
        self._supervised = build_supervisor.supervisor().adopt(
            session_id=(self._session.id if self._session is not None else ""),
            label=(self._session.label if self._session is not None
                   else self._supervisor_label()),
            worker=self.worker, driver=self.driver, window=self.wiz.window(),
            workdir=(self._session.workdir if self._session is not None
                     else self._work_dir()),
            kind=(getattr(self._session, "kind", "wizard")
                  if self._session is not None else "wizard"),
            # followed by the Studio panel's Image builds tab (its live tail)
            log_path=(getattr(self._session, "log_path", "") or ""
                      if self._session is not None else ""),
            # A REAL exit (aboutToQuit -> cancel_all) genuinely stops this run, so the
            # record must say "stopped". Without this hook the old close-abort's
            # _finalize_session was simply lost when the abort moved off the window
            # close, and a quit-interrupted build stayed "running" with a dead pid —
            # rendered as "running (stale?)" in the build list forever.
            on_cancelled=lambda: self._finalize_session(status="stopped"))
        # a builder is really launching now, so the per-image log files are real (or are
        # about to be — `tail -F` handles the not-yet-created case): show the paths.
        self._dispatched = True
        self._refresh_log_help()
        self.completeChanged.emit()
        self._sync_back_button()
        self._drain.start()      # stopped in _on_finished_all, after a final flush
        self.worker.start()

    def _supervisor_label(self) -> str:
        """A roster label when no session record exists (direct-slot tests / a record
        that could not be written): the config's own role·platform, never a fake id."""
        c = self.wiz.cfg
        return " · ".join(p for p in (c.role or "build", c.platform or "x86") if p)

    # ---- slots (GUI thread) -----------------------------------------------------
    def _work_dir(self) -> str:
        """The dir the running build actually WRITES ITS ARTIFACTS INTO.

        The session workdir first (``<out>/sessions/<id>/``), because that is what
        this page hands the driver as ``workdir=`` at dispatch and therefore what
        ``WorklistDriver._output_dir()`` resolves to for every image. Falling back to
        the shared ``<out>`` — which is what this returned unconditionally — pointed
        the per-entry artifact snapshot at a directory the build never touches, so
        ``new_artifacts()`` diffed two identical listings, returned (), and EVERY
        flash-plan assignment refused with "no artifact was recorded for <entry> in
        this run". That is the #337 refusal, and on this host it was worse than empty:
        ``out/`` still holds an August pki image, so the baseline was a stale
        unrelated artifact set.

        The ``<out>`` fallback stays for the no-session callers (direct-slot tests,
        a record that could not be written)."""
        if self._session is not None and self._session.workdir:
            return self._session.workdir
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
        """Worker-signal slot. Deliberately does NOTHING but enqueue — see the coalescing
        note where ``_drain`` is constructed. Anything real here runs once PER OUTPUT LINE
        on the GUI thread, and this page's stream is millions of lines long."""
        self._line_inbox.append((i, line))

    def _drain_lines(self) -> None:
        """Process every line banked since the last tick.

        Two halves, deliberately split:

        * PER LINE (unchanged, in arrival order) — sanitise, flag join, raw buffer,
          ProgressParser, StageTracker, EmergePackageParser, and the get-or-create of a
          package's tree item. All pure bookkeeping except the item creation, which is
          one-time per atom and must stay per line: a group node nests under whichever
          stage was RUNNING when its first package appeared, so deferring it to the end of
          the batch could file a group under the wrong stage.
        * ONCE PER BATCH (the repainting half) — the job bar + phase label, each moved
          package's row, the parallel-emerge aggregate, the package-list affordance, the
          tray status file, the overall bar, and ONE appendPlainText for the pane.
        """
        if not self._line_inbox:
            return
        # Snapshot and clear FIRST: the worker thread keeps emitting while this runs, and
        # draining in place would livelock on a fast producer.
        batch = [self._line_inbox.popleft() for _ in range(len(self._line_inbox))]
        touched_rows: list[int] = []                       # ordered, de-duped
        moved: dict[tuple[int, str], PackageProgress] = {}  # (row, atom) -> live row
        visible: list[str] = []
        # The COLOURED originals, pane only. Every other consumer (row.buffer ->
        # error_tail -> the session record, and the stage tracker) keeps taking the
        # sanitised text: those are read back as text, and markup would corrupt them.
        visible_raw: list[str] = []
        for i, raw_line in batch:
            # Defensive: _reset() can empty self._rows while the old worker is still
            # emitting. This is a Qt slot's downstream, and on PyQt6 an IndexError
            # escaping into Qt calls qFatal and ABORTS the Studio.
            if not (0 <= i < len(self._rows)):
                continue
            row = self._rows[i]
            if i not in touched_rows:
                touched_rows.append(i)
            line = self._consume_line(row, raw_line, moved)
            if line is not None:
                visible.append(line)
                visible_raw.append(raw_line)
        for (i, _atom), pkg in moved.items():
            self._render_package(self._rows[i], pkg)
        for i in touched_rows:
            row = self._rows[i]
            # state() is a fresh snapshot of the parser's CURRENT state, so painting it
            # once at the end of the batch shows exactly what painting it per line would
            # have left on screen.
            self._apply_state(row, row.parser.state())
            self._render_scheduler(row)
            self._sync_pkg_expand(row)
        if touched_rows:
            self._write_status()
            self._refresh_overall()
        if visible:
            # RENDER the colour rather than discarding it. _display_safe() strips it
            # because Qt paints a box for a bare ESC, but stripping also threw away the
            # one signal the builders deliberately encode -- portage colours a failure
            # red and a transition green, and the operator was left scanning monochrome
            # text for them. console.write_batch keeps the single-append fast path for
            # batches with no escapes, which is nearly all of them.
            console.write_batch(self.log, visible_raw, visible)

    def _consume_line(self, row: _Row, line: str,
                      moved: dict[tuple[int, str], PackageProgress]) -> str | None:
        """The PER-LINE half of the pipeline (see _drain_lines). Returns the sanitised
        line when it belongs in the pane under the current selection, else None; records
        any package the line moved in ``moved`` for the batch's single repaint."""
        i = row.index
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
        raw_line = line
        line = _display_safe(line)
        # per-package FLAG columns: portage's resolver merge-list rows ("[ebuild N ] …").
        # Gated on the SANITISED line so the test is one C-level startswith on a string
        # this method already built — the overwhelming majority of a build's millions of
        # lines cost exactly that. The RAW line is what gets parsed, though: under
        # --color=y the per-token colour is the ONLY thing separating §1.3's states 10 and
        # 11, and _display_safe has already thrown it away. §0c: this display is a
        # slot-conflict accident, so it may never arrive — the VDB half stands alone when
        # it does not.
        if line.startswith(flag_badges.RESOLVER_PREFIXES):
            rr = row.flag_join.feed_line(raw_line)
            # a merge list normally precedes the merging, so the package row does not
            # exist yet and _render_package will pick the flags up when it creates it.
            # Under --keep-going portage can re-run the depgraph MID-build, though, and
            # that second display must land on the rows that are already on screen.
            if rr is not None and rr.cpv in row.pkg_items:
                self._apply_flag_cells(row, rr.cpv, row.pkg_items[rr.cpv])
        # PLAN PREVIEW — the only USE source a NORMAL build has. Portage's merge-list
        # display above is conflict-triggered and normally never appears (measured: zero
        # [ebuild rows across a live 1.37M-line session), which is why the USE columns
        # stayed empty while KEYWORDS/LICENSE painted from the VDB. The plan carries
        # portage's own USE="…" column verbatim, one line per package, emitted before the
        # merge — so like a merge list it usually lands BEFORE the row exists and
        # _render_package collects it then. Same cheap prefix gate on the sanitised line.
        elif line.startswith(flag_badges.PLAN_PREFIX):
            cpv = row.flag_join.feed_plan_line(raw_line)
            if cpv is not None and cpv in row.pkg_items:
                self._apply_flag_cells(row, cpv, row.pkg_items[cpv])
        row.buffer.append(line)
        state = row.parser.feed(line)
        # NOT _apply_state here: the bar + phase label are painted ONCE for the whole
        # batch, from row.parser.state(), at the end of the drain.
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
            # CREATE the row's tree item now (one-time per atom, and it must happen here:
            # _group_item nests a group under whichever stage is RUNNING at this instant),
            # but defer the PAINTING to the batch. 74,998 lines of a real build are ninja
            # counters for the SAME atom, each of which used to repaint its label; the
            # PackageProgress object is live and shared (the parser's documented
            # contract), so painting it once per drain paints its final state.
            self._render_package(row, pkg, paint=False)
            moved[(i, pkg.atom)] = pkg
        # PARALLEL emerge (_render_scheduler), the package-list affordance
        # (_sync_pkg_expand), the tray status file and the overall bar are all repainting
        # surfaces with no per-line semantics, so the drain runs them once for the batch.
        #
        # live drill-down append: only when the arriving line's target matches the current
        # selection — the whole job (stage None) gets every line; a selected stage gets a
        # line only while it is the running stage of that job. A selected PACKAGE shows a
        # FILE (its portage log, tick-followed), never the stream — appending here would
        # interleave whole-job lines into it. Evaluated PER LINE because tracker.cur can
        # move partway through a batch.
        if i == self._selected and self._selected_pkg is None:
            if self._selected_stage is None or row.tracker.cur == self._selected_stage:
                return line
        return None

    def _on_entry_done(self, i: int, code) -> None:
        # FLUSH BEFORE SETTLING. Up to one drain interval of this entry's output is still
        # banked when its done signal arrives, and those are exactly the lines that say
        # HOW it finished. Draining after tracker.finalize() would feed them to a tracker
        # that has already settled — the failing stage would lose the very output that
        # explains the failure.
        self._drain_lines()
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
        self._drain_lines()                    # final flush (see _on_entry_done)
        self._drain.stop()                     # an idle page must own no delivery clock
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
            self._maybe_qemu_tests()
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
        final = status or build_sessions.overall_status([r.status for r in results])
        build_sessions.finish(self._session, final, tails)
        # Held-secret-file lifecycle (the operator's own words set it): "held in
        # memory until the build is completed" — so a COMPLETE outcome drops exactly
        # the entries this session consumed. failed/stopped KEEP them: a same-process
        # Restart then redispatches without re-prompting (the retry the retention
        # exists for). Studio exit drops everything regardless (process memory).
        if final == build_sessions.COMPLETE:
            secret_files.vault().drop_fields(
                rec.get("field", "") for rec in
                (self._session.held_secret_files or []) if isinstance(rec, dict))
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

    def _group_progress_text(self, row: _Row, group: str) -> str:
        """The GROUP node's Progress cell: our own reconstructed "<done> of <total> done",
        plus portage's live PARALLEL-emerge aggregate when portage has actually spoken.

        The two halves are kept textually distinct rather than merged into one number. Ours
        counts rows that reached ``Completed (N of M)``; portage's ``running`` / ``merge
        wait`` counts are its scheduler's own view and legitimately lead ours (it reports a
        job running on the line BEFORE the ``Emerging`` that names the atom). Showing both
        is what answers the operator's question — "which packages are actually compiling
        right now" — without inventing a reconciled figure neither side stated.

        The suffix appears ONLY once a ``>>> Jobs:`` line has been parsed AND some clause is
        non-zero, so a serial build's cell is unchanged, and portage's own "0 of 0 complete"
        (20 of them in the real rpi5 transcript — an emerge invocation with nothing to do)
        adds no noise."""
        done, total = row.pkg_parser.totals()
        text = f"{done} of {total} done"
        sched = row.pkg_parser.scheduler()
        if sched.seen:
            parts = []
            if sched.running:
                parts.append(f"{sched.running} running")
            if sched.merge_wait:
                parts.append(f"{sched.merge_wait} merge wait")
            if sched.failed:
                parts.append(f"{sched.failed} failed")
            if parts:
                text += "  ·  " + "  ·  ".join(parts)
        return text

    def _render_scheduler(self, row: _Row) -> None:
        """Repaint the parallel-emerge aggregate onto the CURRENT group node, and (once)
        open that node so the several simultaneously-live package rows are actually visible.

        Revision-gated against the parser's SchedulerState, which is the whole point: this
        is called from the per-line path AND from the 1s tick, and on a real build the
        scheduler line repeats thousands of times with identical figures. No group node yet
        (the aggregate arrived before the first package) is a normal early state, not an
        error — the next package creates the node and paints it."""
        sched = row.pkg_parser.scheduler()
        if sched.revision == row.sched_rev:
            return
        group = row.pkg_parser.group()
        item = row.group_items.get(group)
        if item is None:
            # NOTE the revision is deliberately NOT consumed here: the figures are real,
            # they just have nowhere to go yet, so the very next call paints them once the
            # first package of the group creates its node.
            return
        row.sched_rev = sched.revision
        item.setText(_COL_PROGRESS, self._group_progress_text(row, group))
        if row.pkg_parser.parallel() and not row.pkg_parallel_shown:
            # Serial builds are left collapsed exactly as before. Under --jobs the point of
            # the feature is that SEVERAL rows are live at once, so the tree opens itself
            # the first time the parser proves that — once, never fighting the operator's
            # own collapse afterwards.
            row.pkg_parallel_shown = True
            self.tree.expandItem(item)

    # ---- the package-list affordance: greyed until THIS job is really emerging --------
    @staticmethod
    def _emerge_started(row: _Row) -> bool:
        """Has THIS job's emerge phase actually begun?

        Read off the SAME parser that builds the package level of the tree, never off a
        stage LABEL, a percent or a clock:

        * ``pkg_items`` — portage has already named a package for this job (a
          ``>>> Emerging (N of M) <atom>`` line); the strongest possible proof, and the
          one that also covers a builder that emerges before any group banner (the
          honest GROUP_UNKNOWN case, which the tree renders as "ungrouped");
        * ``pkg_parser.group()`` — the builders' pinned ``==> Emerge group: <g>`` banner,
          printed immediately BEFORE the emerge invocation it names, so it is the
          earliest honest "we are emerging now" the stream carries. It is the very
          signal the GROUP nodes are keyed on;
        * ``scheduler().seen`` — portage's own ``>>> Jobs: N of M complete`` scheduler
          line: emerge is running and talking, even if no atom has been named yet.

        A stage-label match was deliberately NOT used: platforms name their emerge stages
        differently ("Emerge packages" on x86 vs "Phase 1: @system" / "Phase 2: stage4" on
        every ARM builder, core/progress-tables.json), so a label rule would silently
        never enable on ARM. The three signals above are platform-independent because the
        BANNERS are — the same reason the group level is a level and not a stage.
        """
        if row.pkg_items:
            return True
        parser = row.pkg_parser
        if parser.group() != GROUP_UNKNOWN:
            return True
        return bool(parser.scheduler().seen)

    def _sync_pkg_expand(self, row: _Row) -> None:
        """Flip one job's package-list affordance from greyed to live, ONCE.

        Called from the per-line path and from the 1s tick, both of which are Qt slots on
        the operator's PyQt6 build — where an unhandled exception calls qFatal and ABORTS
        the Studio mid-build — so every step is guarded and a fault leaves the control in
        its current (honest) state instead of ending the session. The latch is one-way by
        construction: `pkg_expandable` is only ever set True, so a settled/collapsed job
        keeps its packages browsable and nothing can re-grey a control the operator has
        already seen go live. It is also strictly PER JOB — each row carries its own latch
        and its own parser, so in a multi-image worklist an image still fetching its seed
        stays greyed while the one that is emerging does not."""
        if row.pkg_expandable:
            return                       # latched: one integer-cheap test per call after
        try:
            if not self._emerge_started(row):
                return
            row.pkg_expandable = True
            if row.pkg_btn is not None:
                row.pkg_btn.setEnabled(True)
                row.pkg_btn.setToolTip(_PKG_EXPAND_READY_HINT)
        except Exception:                # noqa: BLE001 - see docstring (PyQt6 qFatal)
            # Deliberately silent and NOT latched: the next line/tick re-evaluates. The
            # only realistic fault here is a widget whose C++ object went away with the
            # page, and a log line about that would be noise on top of a teardown.
            return

    def _expand_packages(self, i: int) -> None:
        """Open job `i`'s package list — the action behind the affordance.

        Expands the job, the stage(s) hosting its emerge groups and the group nodes
        themselves, then scrolls to the first group. It EXPANDS only; it never collapses
        anything the operator opened, and it does nothing while the job's latch is still
        closed (belt and braces — the disabled button cannot emit `clicked` in the first
        place, so this also covers a programmatic call).

        Defensive for the same reason as _poll_packages: this is a Qt slot, and on PyQt6
        an unhandled exception here would qFatal-ABORT the operator's Studio."""
        try:
            if not (0 <= i < len(self._rows)):
                return
            row = self._rows[i]
            if not row.pkg_expandable:
                return
            if row.job_item is not None:
                self.tree.expandItem(row.job_item)
            first = None
            for item in row.group_items.values():
                parent = item.parent()
                if parent is not None:
                    self.tree.expandItem(parent)   # the stage the group nests under
                self.tree.expandItem(item)
                if first is None:
                    first = item
            if first is not None:
                self.tree.scrollToItem(first)
            elif 0 <= row.tracker.cur < len(row.stage_items):
                # emerging, but portage has not named a group/package yet: open the
                # running stage so the rows land in view as they arrive.
                self.tree.expandItem(row.stage_items[row.tracker.cur])
        except Exception as exc:         # noqa: BLE001 - see docstring (PyQt6 qFatal)
            self.log.appendPlainText(
                f"NOTE: could not open the package list ({type(exc).__name__}: {exc}) — "
                f"the tree's own expand arrows still work.")

    def _poll_packages(self, row: _Row, now: float) -> None:
        """PARALLEL emerge, live rows: let the parser tail each in-flight package's OWN
        portage build log and repaint the ones that moved.

        Under ``--jobs`` portage diverts each concurrent package's compile output to that
        package's log instead of the shared stdout, so the stream this page receives carries
        nothing that could move those bars — which is exactly why several rows used to sit
        frozen at 'emerge' with no percent. EmergePackageParser.poll() does the reading
        (bounded: a byte offset per atom, a capped chunk per atom per pass, at most a few
        dozen atoms) and returns only the rows that changed, so the fingerprint-guarded
        _render_package still does one bar/label write per moved row and nothing is rebuilt.

        DEFENSIVE BY REQUIREMENT, not by taste. This runs inside a QTimer slot, and the
        operator's Studio runs on PyQt6, where an unhandled exception in a Qt slot calls
        qFatal and ABORTS the process (PySide6 merely prints it) — so a transient fault
        while reading inside the build's chroot could kill the whole application mid-build.
        Everything is caught, reported ONCE into the log pane, and the follow is then
        latched off for that row: a degraded live view is a bug, a dead Studio is a
        catastrophe."""
        if row.pkg_poll_off:
            return
        try:
            for pkg in row.pkg_parser.poll(now):
                self._render_package(row, pkg)
            self._render_scheduler(row)
            # KEYWORDS/LICENSE come ONLY from the VDB (§2.2), and portage writes a
            # package's VDB directory around its own Completed line — so the read that
            # ran on the step transition can legitimately have been a moment early. A
            # small bounded retry per tick (never a rescan) fills those rows in; atoms
            # that never appear are dropped after a capped number of attempts.
            for atom, cells in row.flag_join.retry_pending().items():
                item = row.pkg_items.get(atom)
                if item is not None:
                    self.flag_columns.apply(item, cells)
        except Exception as exc:                      # noqa: BLE001 - see docstring
            row.pkg_poll_off = True
            self.log.appendPlainText(
                f"NOTE: live per-package log follow disabled for {row.label} "
                f"({type(exc).__name__}: {exc}) — the build and its own logs are "
                f"unaffected; package rows still advance from the build stream.")

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

    def _render_package(self, row: _Row, pkg: PackageProgress,
                        paint: bool = True) -> None:
        """Reflect ONE package's live parser row onto its tree item — called only when
        feed() reported that row moved, and every widget write below is guarded by the
        last-painted fingerprint, so the 74,998 ninja-counter lines of a real build cost
        a tuple compare + a bar/label write each, and non-package lines cost nothing.

        ``paint=False`` does the get-or-create half ONLY. The drain calls it that way per
        line so a group node still nests under the stage that was running when its first
        package appeared, then calls it again (painting) once per moved atom per tick —
        see _drain_lines. The state it paints is the same either way: PackageProgress is
        the parser's live, shared row object, not a snapshot."""
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
        if not paint:
            return
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
                row.group_items[pkg.group].setText(
                    _COL_PROGRESS, self._group_progress_text(row, pkg.group))
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
        self._apply_flag_cells(row, atom, item)

    def _apply_flag_cells(self, row: _Row, atom: str,
                          item: QtWidgets.QTreeWidgetItem) -> None:
        """Join this package's flag data onto its row and reveal any column it fills.

        ``cells_if_changed`` returns None unless something genuinely new is available for
        the atom (a resolver row indexed since the last look, or its VDB record finally
        on disk), so the common case is one dict lookup and a tuple compare — this runs
        once per moved package row, of which a real build has 300+.

        DEFENSIVE for the same reason as _poll_packages: this is reached from a Qt slot,
        and the operator runs PyQt6 where an exception escaping a slot calls qFatal and
        ABORTS the Studio. A missing badge is a blemish; a dead Studio mid-build is not."""
        try:
            cells = row.flag_join.cells_if_changed(atom)
            if cells:
                self.flag_columns.apply(item, cells)
        except Exception:                             # noqa: BLE001 — see docstring
            pass

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
            # PARALLEL emerge: the concurrent packages' live step/percent/tool line come
            # off their own portage logs, and this existing 1 Hz tick is the poll clock
            # (no second timer). A no-op on a serial build — the parser's poll() returns
            # immediately unless the stream has PROVEN --jobs parallelism.
            self._poll_packages(row, now)
            # second (cheap, latched) drive of the package-list affordance: the poll path
            # can be what first proves this job is emerging, and the tick is the one clock
            # that runs even when the stream has gone quiet mid-compile.
            self._sync_pkg_expand(row)
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
        self._set_log_cap(True)              # …which is the bounded one
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
        # a FILE view, not the stream: lift the block cap so a tail-read log is shown
        # whole rather than head-truncated (see _set_log_cap).
        self._set_log_cap(False)
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

    def _open_view_config(self) -> None:
        """The Configure-view dialog: one checkbox per hideable column.

        Every slot reachable from a widget signal is exception-guarded — the operator
        runs PyQt6, where an exception escaping a slot into Qt aborts the Studio
        outright rather than printing a traceback."""
        try:
            dlg = QtWidgets.QDialog(self)
            dlg.setWindowTitle("Configure view")
            dl = QtWidgets.QVBoxLayout(dlg)
            dl.addWidget(QtWidgets.QLabel(
                "Columns shown in the build table. The four flag columns normally\n"
                "reveal themselves once a package supplies that flag; a choice made\n"
                "here overrides that for the rest of the session."))

            boxes: list[tuple[QtWidgets.QCheckBox, int, str | None]] = []
            for col, label, key in _CONFIGURABLE_COLUMNS:
                box = QtWidgets.QCheckBox(label)
                box.setChecked(not self.tree.isColumnHidden(col))
                if key is not None:
                    box.setToolTip(
                        f"{label} — a portage flag column. Hidden by default until a "
                        f"package supplies {label} data; tick to keep it visible even "
                        f"when empty.")
                dl.addWidget(box)
                boxes.append((box, col, key))

            btns = QtWidgets.QDialogButtonBox(
                QtWidgets.QDialogButtonBox.StandardButton.Ok
                | QtWidgets.QDialogButtonBox.StandardButton.Cancel)
            # "Reset" hands the badge columns back to AUTO. Without it an operator who
            # has ticked something can never get the reveal-on-content behaviour back
            # except by restarting the Studio.
            reset_btn = btns.addButton("Reset to automatic",
                                       QtWidgets.QDialogButtonBox.ButtonRole.ResetRole)
            btns.accepted.connect(dlg.accept)
            btns.rejected.connect(dlg.reject)

            def _reset() -> None:
                try:
                    for key in _FLAG_COLS:
                        self.flag_columns.set_override(key, None)
                    for box, col, _k in boxes:
                        box.setChecked(not self.tree.isColumnHidden(col))
                except Exception:        # noqa: BLE001
                    pass
            reset_btn.clicked.connect(_reset)
            dl.addWidget(btns)

            if dlg.exec() != QtWidgets.QDialog.DialogCode.Accepted:
                return
            for box, col, key in boxes:
                want = box.isChecked()
                if key is not None:
                    # Route badge columns through their controller so the choice
                    # survives the next reset() and beats the auto-reveal.
                    self.flag_columns.set_override(key, want)
                else:
                    self.tree.setColumnHidden(col, not want)
        except Exception:        # noqa: BLE001 — PyQt6: never let a slot raise
            return

    def _on_tree_menu(self, pos) -> None:
        """Right-click a still-running job/stage to Stop that one image (the per-image Stop
        that the old per-row button offered, now that the row is a tree node), and copy a
        package row's flags verbatim.

        The Stop entry keeps its exact old condition (a live row only). Copy is offered
        for any row that HAS flag text, terminal or not — the whole point of the badge
        columns is that a finished build stays inspectable."""
        item = self.tree.itemAt(pos)
        if item is None:
            return
        data = item.data(_COL_NAME, Qt.ItemDataRole.UserRole)
        if not data:
            return
        i, _j = data
        if not (0 <= i < len(self._rows)):
            return
        menu = QtWidgets.QMenu(self.tree)
        if not self._rows[i].terminal:
            act = menu.addAction(f"Stop {self._rows[i].label}")
            act.triggered.connect(lambda _=False, idx=i: self._stop_one(idx))
        # §5's copy-paste guarantee: what lands on the clipboard is the KEY="…" text
        # portage itself printed, never a re-rendering of our badges.
        flags = self.flag_columns.copy_text_for(item)
        if flags:
            cact = menu.addAction("Copy flags (verbatim)")
            cact.triggered.connect(lambda _=False, t=flags: self._copy_to_clipboard(t))
        if menu.actions():
            menu.exec(self.tree.viewport().mapToGlobal(pos))

    def _copy_to_clipboard(self, text: str) -> None:
        """Clipboard write, guarded: a headless/clipboard-less session must never take
        the Studio down from inside a menu slot (PyQt6 aborts on a slot exception)."""
        try:
            QtWidgets.QApplication.clipboard().setText(text)
        except Exception:                             # noqa: BLE001
            pass

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

    def _detach_from_window(self, *_a) -> None:
        """ASK 16: the wizard window CLOSED — put the window's furniture away and leave
        the build running.

        What is stopped here is cosmetic and window-scoped only: the flash-device
        rescan timer and the elapsed-time ticker exist to paint a visible page, and a
        closed window paints nothing. The BUILD is untouched — no cancel, no join —
        because gui/build_supervisor.py owns it now and the tray badge keeps reporting
        it from the status file.

        Two things are relied on and must stay:

        * ``_redock_log()`` FIRST, exactly as the old abort did. The detached log
          window is a child of the wizard; reparenting the log panel back into this
          page before anything else means a later teardown cannot take ``self.log``'s
          C++ object with it and make the next streamed line raise inside ``_on_line``
          — a Qt slot, where an unhandled exception ABORTS the Studio under PyQt6.
        * ``_flash_queue = []``. A queued destructive flash must NOT fire after the
          operator closed the window: dd is not a thing to start at a window nobody is
          watching. Cancelling the queue is not cancelling the build.

        A still-running FLASH is joined, because it writes to a physical device and
        must not be left racing a closing window.
        """
        self._redock_log()
        self._flash_timer.stop()
        self._tick.stop()
        # The DRAIN deliberately keeps running. Unlike the elapsed ticker it is not
        # cosmetic: it is the only thing that feeds row.buffer (the session record's error
        # tails) and _write_status (the tray badge that reports a backgrounded build), and
        # ASK 16 says a closed window must not stop the run. The supervisor pins the
        # window's C++ objects alive, so the appends still have somewhere to land, and at
        # ~20 Hz an unwatched page costs a batch append per tick.
        dropped = len(self._flash_queue)
        self._flash_queue = []
        self._flash_caveats = []
        self._flash_cancelled = False
        # #415: the rows that were still QUEUED will now never be written, and a table
        # that keeps saying "queued" about them asserts a pending write that nothing
        # will ever perform. Say so on the rows themselves. The row currently being
        # written (if any) is NOT touched: its worker is joined just below and its
        # _flash_done still delivers the real outcome.
        if dropped:
            try:
                start = self._flash_plan_pos
            except (AttributeError, RuntimeError):
                start = 0
            for r in range(start, start + dropped):
                self._set_plan_status(
                    r, "not written — flashing was stopped", _FLASH_GREY)
                self._lock_plan_row(r)
        if self.flash_worker is not None and self.flash_worker.isRunning():
            self.flash_worker.wait(3000)
        # A still-running QEMU device-test run is NOT joined: it can run for hours,
        # touches no physical device, and (ASK 16) a window close must not stop it.
        # Its signals are detached so the closing widgets are never emitted into —
        # the containers run to completion and their per-device result JSON lands in
        # out/qemu-runs/results, which QemuPage re-reads on its next visit.
        if self.qemu_worker is not None and self.qemu_worker.isRunning():
            try:
                self.qemu_worker.line.disconnect()
                self.qemu_worker.done.disconnect()
            except (TypeError, RuntimeError):
                pass

    def _abort_run(self, *_a) -> None:
        """Cancel and join a still-running build. Reserved for a REAL teardown (the
        supervisor's ``cancel_all`` on ``QApplication.aboutToQuit``, and the tests that
        drive an explicit abort) — never a window close; see _detach_from_window."""
        self._detach_from_window()
        if self.worker is not None and self.worker.isRunning():
            if self.driver is not None:
                self.driver.cancel_all()
            self.worker.wait(3000)
            self._finalize_session(status="stopped")   # honest: the abort cancelled it

    # ---- flash to a device (post-build) -----------------------------------------
    # The flasher's accepted set, derived from the ONE vocabulary
    # (flash_targets.FLASH_ROLE_TOKENS -> scripts/_roles-lib.sh) rather than restated
    # here. This local copy is what let the GUI hand `be` to a flasher that
    # normalized it to `backend` and then globbed with no arch anchor — the
    # "Flash to device" button offering an arm64 Raspberry Pi ISO for an x86 backend.
    _FLASH_ROLES = flash_targets.FLASH_ROLE_TOKENS

    def _flash_role_arch(self) -> tuple[str, str]:
        """(role token, arch) for the standalone flash path — the two anchors
        flash-disk.sh globs on. A desktop/appliance role has no artifact of its own to
        glob for, so it falls back to the generic worker image, spelled canonically."""
        c = self.wiz.cfg
        role = c.role if c.role in self._FLASH_ROLES else "backend-gpu"
        return role, flash_targets.arch_for_platform(c.platform)

    def _flash_work_dir(self) -> str:
        """ONE spelling of "where this run's artifacts are". Was a verbatim copy of the
        pre-#415 inline expression, which differed from _work_dir() for a session whose
        workdir is falsy (it yielded "" where _work_dir falls back to <out>); the #415
        Image combo searched one and the argv named the other. _work_dir() is the one
        carrying the #337 session-workdir reasoning, so it is the one that stays."""
        return self._work_dir()

    def _flash_argv_for(self, target) -> list[str]:
        role, arch = self._flash_role_arch()
        # #415: the operator's image pick from the group's Image combo, or "" when
        # nothing was recorded — in which case NO --artifact is emitted and
        # flash-disk.sh auto-picks exactly as it always did.
        return flash_targets.flash_argv(target, generator_dir=self.wiz.generator_dir,
                                        role=role, arch=arch,
                                        artifact=self._selected_image() or None,
                                        work_dir=self._flash_work_dir())

    # ---- WHICH IMAGE (#415) ------------------------------------------------------
    def _flash_image_candidates(self) -> tuple[str, ...]:
        """Every flashable artifact this run can offer, newest first, deduped.

        Primary source is what the per-entry snapshot diff RECORDED (the same
        ``_entry_artifact_sets`` the plan path resolves against), unioned across
        entries because the standalone group has no entry selector. When a run
        recorded nothing (a resumed build that rewrote no image, a restarted wizard)
        we fall back to the SAME read-only arch+role name match flash-disk.sh itself
        uses — never a guess of our own, and never a write."""
        order: list[tuple[str, float, int]] = []
        seen: set[str] = set()

        def _add(path: str) -> None:
            if path in seen:
                return
            seen.add(path)
            try:
                mtime = os.stat(path).st_mtime
            except OSError:
                mtime = 0.0
            order.append((path, mtime, len(order)))

        for arts in self._entry_artifact_sets.values():
            for a in arts:
                _add(a)
        if not order:
            try:
                role, arch = self._flash_role_arch()
                work_dir = self._work_dir()
            except Exception:
                role, arch, work_dir = "", "", ""
            if work_dir:
                for a in flash_targets.find_artifacts(work_dir, role=role, arch=arch):
                    _add(a)
        # newest first; the per-entry recording order breaks ties (it is already
        # newest-first), so a tmp_path fixture whose files share an mtime stays stable.
        order.sort(key=lambda c: (-c[1], c[2]))
        return tuple(p for p, _m, _i in order)

    def _flash_default_image(self, cands: tuple[str, ...]) -> str:
        """The image this group PRESELECTS, which must never disagree with the arch
        this same group is about to put in the argv.

        ``_flash_image_candidates`` unions EVERY entry's recorded artifacts, because
        the standalone group has no entry selector — so on a multi-entry run the
        newest recorded image can belong to the other architecture. Preselecting it
        emitted ``--arch x86`` together with an arm64 ``--artifact``, and flash-disk.sh
        takes an explicit artifact VERBATIM (it never re-globs), so the arch anchor
        that exists to stop exactly that would have been bypassed by a DEFAULT nobody
        chose.

        So the default is drawn only from files whose name carries this page's arch,
        preferring those that also carry its role — the same two anchors
        ``find_artifacts`` filters on. When nothing matches, the default is "" and the
        caller offers an explicit "(none)" row: no ``--artifact`` is emitted and
        flash-disk.sh picks exactly as it did before #415. The other entries' images
        stay LISTED, so writing one is still possible — just never by default."""
        role, arch = "", ""
        try:
            role, arch = self._flash_role_arch()
        except Exception:
            pass
        if not arch:
            return flash_targets.pick_artifact(cands, flash_targets.FLAVOR_AUTO)
        same_role = tuple(p for p in cands
                          if flash_targets.artifact_matches(p, role=role, arch=arch))
        # arch alone, for a run whose role token the artifact name spells differently
        # (a desktop/appliance role falls back to the generic worker image); the arch
        # half is the one the argv asserts, so it is never relaxed.
        same_arch = tuple(p for p in cands
                          if flash_targets.artifact_arch_matches(p, arch))
        return (flash_targets.pick_artifact(same_role, flash_targets.FLAVOR_AUTO)
                or flash_targets.pick_artifact(same_arch, flash_targets.FLAVOR_AUTO))

    def _refresh_flash_images(self) -> None:
        """Repopulate the Image combo, preserving the operator's pick by PATH.

        Default selection == ``_flash_default_image(...)``: the same "newest .img else
        newest" pick flash-disk.sh's own glob would have taken, restricted to this
        page's own architecture so the preselection can never contradict the ``--arch``
        the very same argv carries. This control changes WHAT is written only when
        somebody actually changes it."""
        cands = self._flash_image_candidates()
        if cands == getattr(self, "_flash_image_cands", None):
            return                      # the 2.5 s timer must not fight the operator
        self._flash_image_cands = cands
        prev = self.flash_image_combo.currentData()
        self.flash_image_combo.clear()
        if not cands:
            # Honest empty: no --artifact is emitted and flash-disk.sh picks, exactly
            # as it did before #415. Never a silent default that LOOKS chosen.
            self.flash_image_combo.addItem(
                "(this run recorded no image — scripts/flash-disk.sh will auto-pick)",
                "")
            self.flash_image_combo.setEnabled(False)
            return
        self.flash_image_combo.setEnabled(True)
        default = self._flash_default_image(cands)
        if not default:
            # Images exist, but none of them belongs to THIS page's architecture. The
            # honest default is none at all — the same pre-#415 auto-pick path — with
            # the cross-arch files still listed below so a deliberate choice is
            # possible and an accidental one is not.
            self.flash_image_combo.addItem(
                "(none of this run's images match this build's architecture — "
                "scripts/flash-disk.sh will auto-pick)", "")
        for p in cands:
            label = flash_targets.artifact_label(p)
            self.flash_image_combo.addItem(
                label + ("   ← default (auto-pick)" if p == default else ""), p)
        i = self.flash_image_combo.findData(prev) if prev else -1
        if i < 0:
            i = self.flash_image_combo.findData(default) if default else 0
        self.flash_image_combo.setCurrentIndex(max(0, i))

    def _selected_image(self) -> str:
        """The Image combo's path, or "" (nothing recorded / no Qt on a stub page)."""
        try:
            return self.flash_image_combo.currentData() or ""
        except Exception:
            return ""

    # ---- WHICH IMAGE, PER PLAN ROW (#415, mesh / multi-entry) ---------------------
    def _render_flash_plan(self, plan) -> None:
        """Fill the plan table: one row per assignment, each naming its ENTRY, the
        exact IMAGE FILE it will write, and its DEVICE.

        The image combo lists that entry's whole recorded artifact set, so a row can
        be retargeted by FILENAME — the flavour axis alone cannot name an unflavoured
        artifact (rpi5's plain .iso) and cannot tell two same-flavour files apart.
        Its DEFAULT is pick_artifact(set, planned flavour): identical to what
        _flash_next resolves on its own, so rendering this table changes nothing about
        what gets written.

        When that default is EMPTY — the run built no artifact of the planned flavour —
        the row is marked and its combo defaults to an explicit "(none …)" entry, so
        _flash_next still falls through to its existing loud refusal. Other files stay
        offered BELOW that entry: overriding is possible, but only as a deliberate act.
        """
        t = self.flash_plan_table
        t.setRowCount(0)
        for a in plan:
            row = t.rowCount()
            t.insertRow(row)
            flavor = getattr(a, "flavor", flash_targets.FLAVOR_AUTO)
            built = tuple(self._entry_artifact_sets.get(a.entry_id, ()))
            default = flash_targets.pick_artifact(built, flavor)
            flav = "" if flavor == flash_targets.FLAVOR_AUTO else f"  [{flavor}]"
            t.setItem(row, 0, QtWidgets.QTableWidgetItem(f"{a.entry_id}{flav}"))
            combo = QtWidgets.QComboBox()
            combo.setToolTip(
                "The exact file written to this device. Defaults to the artifact this "
                "row's planned flavour resolves to; every other image this entry built "
                "is listed too, so a row can be retargeted by NAME. Changing it here "
                "changes what is written — the confirmation for this device names the "
                "file before anything is destroyed.")
            if not default:
                combo.addItem(
                    f"(none — this run built no '{flavor}' image: row will be SKIPPED)"
                    if flavor != flash_targets.FLAVOR_AUTO else
                    "(none — this run recorded no image for this entry)", "")
            for p in built:
                combo.addItem(flash_targets.artifact_label(p), p)
            i = combo.findData(default) if default else 0
            combo.setCurrentIndex(max(0, i))
            combo.currentIndexChanged.connect(
                lambda _=0, r=row: self._plan_image_changed(r))
            t.setCellWidget(row, 1, combo)
            dev = QtWidgets.QTableWidgetItem(a.target.label())
            t.setItem(row, 2, dev)
            t.setItem(row, 3, QtWidgets.QTableWidgetItem(""))
            if not default:
                self._set_plan_status(
                    row, f"no '{flavor}' image this run — will be SKIPPED"
                    if flavor != flash_targets.FLAVOR_AUTO else
                    "nothing recorded — resolved at flash time", _FLASH_RED)
            else:
                self._set_plan_status(row, "queued", "")
        t.resizeColumnsToContents()
        self.flash_plan_box.setVisible(t.rowCount() > 0)

    def _plan_row_resolved(self, row: int) -> bool:
        """True once _flash_next has CONSUMED this row — it has been written, failed,
        skipped, cancelled or refused, and its Status is a finished verdict."""
        try:
            return 0 <= row < self._flash_plan_pos
        except (AttributeError, RuntimeError):
            return False

    def _lock_plan_row(self, row: int) -> None:
        """Freeze a row's image combo the moment _flash_next consumes it. Retargeting
        it can no longer change anything — the queue has already moved past it — so
        the control must stop inviting a change that would silently do nothing."""
        try:
            combo = self.flash_plan_table.cellWidget(row, 1)
            if combo is not None:
                combo.setEnabled(False)
                combo.setToolTip("This row has already been resolved — changing it "
                                 "now would not change what was written.")
        except (AttributeError, RuntimeError):
            pass

    def _plan_image_changed(self, row: int) -> None:
        """Re-label a row the operator retargeted, so the table never shows 'will be
        SKIPPED' next to a file that is now going to be written.

        A row _flash_next has already consumed is left ALONE. Re-labelling it "queued"
        claimed a write was still pending for a device whose flash had already
        finished (or been skipped) and which nothing would ever revisit — the table's
        one job is to say what happened to each device, so a finished verdict must not
        be overwritten by a control that can no longer affect it."""
        if self._plan_row_resolved(row):
            return
        chosen = self._plan_image_for(row)
        self._set_plan_status(row, "queued" if chosen else "no image — will be SKIPPED",
                              "" if chosen else _FLASH_RED)

    def _plan_image_for(self, row: int) -> str:
        """The plan table's per-row image override, or "" — "" means "resolve exactly
        as before", which is what keeps the existing refusal path alive."""
        try:
            combo = self.flash_plan_table.cellWidget(row, 1)
            return (combo.currentData() or "") if combo is not None else ""
        except Exception:
            return ""

    # ---- VALIDATE the image(s), WITHOUT flashing (#415 D) -------------------------
    def _check_jobs(self) -> list[dict]:
        """One check job per image that a Flash would write, with the target it would
        be written to.

        A queued PLAN is checked row by row (each row's chosen image against THAT
        row's device, role, arch and planned flavour); otherwise the standalone pair —
        the Image combo's pick against the Device combo's target — is checked. A plan
        row with no image resolved still produces a job, so the report says so instead
        of quietly listing one image fewer than the table shows."""
        jobs: list[dict] = []
        try:
            rows = self.flash_plan_table.rowCount()
        except (AttributeError, RuntimeError):
            rows = 0
        try:
            live_targets = list(self._flash_targets)
        except (AttributeError, RuntimeError):
            live_targets = []
        if rows:
            for i, a in enumerate(getattr(self.wiz, "flash_plan", None) or []):
                if i >= rows:
                    break
                # Prefer the size the device reports RIGHT NOW over the one recorded
                # when the plan was made: a stick swapped since then makes a plan-time
                # "it fits" verdict optimistic. (The write itself is still refused by
                # _flash_next's identity check and by flash-disk.sh's own size-fit;
                # this only keeps the ADVISORY honest.)
                live = next((t for t in live_targets
                             if t.path == a.target.path), None)
                jobs.append({"path": self._plan_image_for(i),
                             "device_size": (live.size if live is not None
                                             else a.target.size),
                             "device_path": a.target.path,
                             "role": a.role, "arch": a.arch,
                             "flavor": getattr(a, "flavor",
                                               flash_targets.FLAVOR_AUTO)})
            if jobs:
                return jobs
        target = self._selected_target()
        role, arch = self._flash_role_arch()
        return [{"path": self._selected_image(),
                 "device_size": target.size if target is not None else 0,
                 "device_path": target.path if target is not None else "",
                 "role": role, "arch": arch,
                 "flavor": flash_targets.FLAVOR_AUTO}]

    def _check_images_clicked(self) -> None:
        """The Check image(s) button. READ-ONLY: it can never write, and it is not a
        route into _start_flash — there is no confirmation here because there is
        nothing to confirm."""
        if self.check_worker is not None and self.check_worker.isRunning():
            return
        jobs = self._check_jobs()
        self.flash_check_out.setVisible(True)
        self.flash_check_out.setPlainText(
            f"Checking {len(jobs)} image(s)… (read-only — nothing is written)")
        self.flash_check_btn.setEnabled(False)
        self.check_worker = hold_thread(_ImageCheckWorker(jobs))
        self.check_worker.done.connect(self._on_check_done)
        self.check_worker.start()

    def _on_check_done(self, reports) -> None:
        self.flash_check_btn.setEnabled(True)
        self.flash_check_out.setVisible(True)
        self.flash_check_out.setPlainText(flash_validate.report_text(reports))

    # ---- per-image WRITE PROGRESS (#415) -----------------------------------------
    def _on_flash_line(self, s: str) -> None:
        """The flasher worker's line slot: log it, then move the bar on BYTES.

        Fed only by _FlashWorker, so no builder log line can reach these parsers."""
        self.log.appendPlainText(s)
        total = flash_targets.parse_write_total(s)
        if total > 0:
            self._flash_write_total = total
            self._render_flash_progress()
            return
        done, rate = flash_targets.parse_dd_progress(s)
        if done > 0:
            self._flash_write_done = done
            self._flash_rate = rate
            self._render_flash_progress()

    def _begin_flash_progress(self, artifact: str) -> None:
        """Arm the indicator for ONE image; called from _start_flash, after the
        confirmation was accepted and before the worker starts."""
        self._flash_image_name = artifact
        self._flash_write_total = 0
        self._flash_write_done = 0
        self._flash_rate = ""
        if self._flash_image_total <= 0:      # the Flash… button: a plan of one
            self._flash_image_total = 1
            self._flash_image_index = 1
        self._render_flash_progress()

    def _render_flash_progress(self) -> None:
        name = os.path.basename(self._flash_image_name) or "(auto-picked by the script)"
        head = (f"Image {self._flash_image_index} of {self._flash_image_total} — "
                f"{name}")
        total, done = self._flash_write_total, self._flash_write_done
        if total > 0:
            pct = min(100, int(done * 100 // total))
            self.flash_progress_bar.setRange(0, 100)
            self.flash_progress_bar.setValue(pct)
            tail = (f"{pct}% — {flash_targets.human_size(done)} of "
                    f"{flash_targets.human_size(total)} written")
        else:
            # NO denominator: an indeterminate bar shows ACTIVITY. It must never be
            # read as progress, so the label says exactly that.
            self.flash_progress_bar.setRange(0, 0)
            tail = (f"{flash_targets.human_size(done)} written — total size not "
                    f"reported, so this bar shows activity, not progress"
                    if done else "starting — waiting for the first byte count")
        if self._flash_rate:
            tail += f" · {self._flash_rate}"
        self.flash_progress_label.setText(head + " — " + tail)
        self.flash_progress_box.setVisible(True)

    def _finish_flash_progress(self, code: int) -> None:
        """Land the bar honestly: 100% only on rc=0 WITH a denominator, otherwise say
        what happened rather than snapping a partial write to full."""
        self.flash_progress_bar.setRange(0, 100)
        name = os.path.basename(self._flash_image_name) or "(auto-picked)"
        head = f"Image {self._flash_image_index} of {self._flash_image_total} — {name}"
        if code == 0:
            self.flash_progress_bar.setValue(100)
            self.flash_progress_label.setText(f"{head} — written")
        else:
            written = flash_targets.human_size(self._flash_write_done)
            self.flash_progress_bar.setValue(
                min(100, int(self._flash_write_done * 100 // self._flash_write_total))
                if self._flash_write_total > 0 else 0)
            self.flash_progress_label.setText(
                f"{head} — FAILED (rc={code})" +
                (f" after {written}" if written else ""))

    def _set_plan_status(self, row: int, text: str, color: str) -> None:
        try:
            if row < 0 or row >= self.flash_plan_table.rowCount():
                return          # the standalone Flash… path has no plan table rows
            item = self.flash_plan_table.item(row, 3)
            if item is None:
                item = QtWidgets.QTableWidgetItem("")
                self.flash_plan_table.setItem(row, 3, item)
            item.setText(text)
            if color:
                item.setForeground(QtGui.QColor(color))
        except Exception:
            pass

    def _refresh_flash_targets(self) -> None:
        """Re-scan (read-only) and repopulate the combo, preserving the selection by
        device path; show the group only after an all-ok build with ≥1 target. Live
        come/go is driven by the 2.5s timer + the Refresh button."""
        try:
            targets = flash_targets.list_targets()
        except Exception:
            targets = []
        self._flash_targets = targets
        self._refresh_flash_images()          # #415: keep the Image combo in step
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
        settled_ok = self._all_terminal and self._run_all_ok()
        if settled_ok and targets:
            self.flash_group.setVisible(True)
        # No targets because this host cannot flash at all: say so rather than nothing.
        # flash_blocker() is "" on a Linux host that can flash, where a missing stick
        # keeps the old silence (plug one in and the timer reveals the group).
        host = getattr(self.wiz, "host", None)
        blocker = "" if targets or host is None else host.flash_blocker()
        self.flash_blocked_note.setText(blocker)
        self.flash_blocked_note.setVisible(bool(settled_ok and blocker))

    def _selected_target(self):
        path = self.flash_combo.currentData()
        for t in self._flash_targets:
            if t.path == path:
                return t
        return None

    def _flash_clicked(self) -> None:
        """The Flash… button. The destroy gate lives in _start_flash, which is the ONE
        funnel both this button and the post-build plan go through — so there is
        exactly one confirmation per flash, never two on this path (#337)."""
        target = self._selected_target()
        if target is None:
            return
        # #415: the caveat is now only for the case it was always TRUE for — no image
        # could be named. When the Image combo has a pick, that exact file is passed as
        # --artifact and the confirmation prints its name, so the "watch the Artifact :
        # line" instruction would be a lie.
        self._flash_caveats = [] if self._selected_image() else [
            "No image was named for this flash, so scripts/flash-disk.sh will "
            "auto-pick the newest matching one in the work dir. Watch the "
            "\"Artifact :\" line it prints before it writes."]
        # #415: this button writes ONE image. Set it explicitly rather than inheriting
        # a previous plan run's N, which would label it "Image 3 of 3".
        self._flash_image_total = 1
        self._flash_image_index = 1
        # #415: this flash is NOT a plan row. Without disowning the row here, its
        # result would be painted onto whatever row _flash_plan_pos last pointed at —
        # i.e. a hand flash after the plan drained would rewrite the last row's Status.
        self._flash_active_row = -1
        self._start_flash(target)

    def _maybe_auto_flash(self) -> None:
        """The ONLY auto path: the BuildPage flash-with-build opt-in (default OFF). It
        fires only when opted-in, the run was all-ok, and the SAME device (matched on a
        stable identity, not just the /dev path) is STILL attached per a fresh read-only
        scan.

        SINCE #337 this path also raises the ONE OK/Cancel warning, because it funnels
        through _start_flash like every other route to a write. That is a DELIBERATE
        deviation from "a modal only in an explicit click handler": the checkbox was
        ticked minutes-to-hours earlier on the BuildPage, and the issue asks for the
        warning "at the moment the flash is started", which is here. It is safe
        headlessly only because ``confirm_flash`` is a module-level override point every test
        monkeypatches — do NOT inline a QMessageBox call here. Operator consequence,
        stated plainly: ticking flash-with-build and walking away now leaves a waiting
        dialog rather than a flashed stick.

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
            # #415: state the WHOLE plan — entry, exact image FILE, device — before the
            # first write, and keep the per-row image combos live. Assignments 2..N run
            # minutes later (each dd takes minutes), so a row really can be retargeted
            # while an earlier one writes; _flash_next reads each row at the moment it
            # resolves that row, never once up front.
            self._flash_plan_pos = 0
            # "image N of M": M is the number of ASSIGNMENTS queued, so a skipped row
            # still advances N — the operator's count matches the table's rows.
            self._flash_image_total = len(self._flash_queue)
            self._flash_image_index = 0
            try:
                self._render_flash_plan(plan)
            except Exception:
                pass            # a partially-constructed page (direct-slot tests)
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
        self._flash_image_total = 1          # #415: one image on the legacy path
        self._flash_image_index = 1
        self._flash_active_row = -1          # #415: not a plan row either
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
            # #415: this assignment's row in the flash-plan table. Read HERE, at the
            # moment this row resolves — never captured up front — so an image changed
            # while an earlier device was being written is honoured.
            #
            # try/except, not getattr(..., 0): on a page built with __new__ (the
            # direct-slot tests) PyQt raises RuntimeError — not AttributeError — for a
            # read of an unset attribute, so a getattr DEFAULT does not cover it. pos
            # = -1 then means "no plan table here": no override, no status writes, and
            # the resolution below is byte-for-byte the pre-#415 chain.
            try:
                pos = self._flash_plan_pos
                self._flash_plan_pos = pos + 1
                self._flash_image_index = pos + 1
            except (AttributeError, RuntimeError):
                pos = -1
            if pos >= 0:
                # This row is now CONSUMED: whatever happens below is its final
                # verdict, so its image control stops accepting changes that could no
                # longer reach the write.
                self._lock_plan_row(pos)
            flavor = getattr(a, "flavor", flash_targets.FLAVOR_AUTO)
            # The assignment's work_dir was resolved on the BuildPage, before this
            # run's session existed, so it names the shared <out>. The build wrote
            # into <out>/sessions/<id>/ — prefer that when it is really there.
            work_dir = a.work_dir
            try:
                live_dir = self._work_dir()
            except Exception:
                # A partially-constructed page (direct-slot tests build one with
                # __new__, and PyQt raises RuntimeError — not AttributeError — for
                # ANY attribute read on it, so a getattr default cannot cover this).
                # The recorded work_dir is the honest fallback; nothing else changes.
                live_dir = ""
            if live_dir and os.path.isdir(live_dir) and live_dir != work_dir:
                work_dir = live_dir
                a = dataclasses.replace(a, work_dir=live_dir)
            caveats: list[str] = []
            # #415: the plan table's per-row image. Its DEFAULT is exactly the
            # pick_artifact() below, so this is a no-op unless the operator changed it;
            # and it is "" for a row whose flavour was not built, which is what keeps
            # the refusal below reachable instead of silently substituting a file.
            chosen = self._plan_image_for(pos)
            artifact = chosen or flash_targets.pick_artifact(
                self._entry_artifact_sets.get(a.entry_id, ()), flavor)
            if chosen and flavor != flash_targets.FLAVOR_AUTO and \
                    flash_targets.classify_artifact_flavor(chosen) != flavor:
                caveats.append(
                    f"You picked {os.path.basename(chosen)} in the flash plan; this "
                    f"row was planned for the '{flavor}' artifact. The file above is "
                    f"what will be written.")
            if not artifact:
                # legacy single-record store (pre-flavour callers/tests seed only
                # this): honour it when it satisfies the requested flavour.
                single = self._entry_artifacts.get(a.entry_id, "")
                if single and (flavor == flash_targets.FLAVOR_AUTO or
                               flash_targets.classify_artifact_flavor(single) == flavor):
                    artifact = single
            if not artifact and not self._entry_artifact_sets.get(a.entry_id):
                # NOTHING was recorded for this entry. Before refusing, LOOK: the
                # finished image is usually sitting in the work dir, and a dead end
                # here is what #337 reported ("the flash-path validation rejects a
                # valid target"). The fallback is a read-only name match on the same
                # two anchors flash-disk.sh uses (arch + role), and what it finds is
                # named IN THE CONFIRMATION rather than written silently — the role
                # glob genuinely cannot tell two same-role entries apart, so a human
                # reads the filename before anything is destroyed.
                #
                # Gated on an EMPTY recorded set on purpose: an entry that recorded a
                # set WITHOUT the requested flavour still skips below, because there
                # the build is known not to have produced that flavour.
                found = flash_targets.find_artifacts(work_dir, role=a.role,
                                                     arch=a.arch)
                artifact = flash_targets.pick_artifact(found, flavor)
                if artifact:
                    caveats.append(
                        f"This run recorded no image for {a.entry_id}. The file above "
                        f"was matched in {work_dir} by arch ({a.arch}) and role "
                        f"({a.role}) only" +
                        (f", out of {len(found)} candidates there" if len(found) > 1
                         else "") + " — check the name is the image you meant.")
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
                        f"and no {a.arch} {a.role} image was found in {work_dir} "
                        f"— skipped (flash manually: scripts/flash-disk.sh "
                        f"--artifact <image> {a.target.path}).")
                self._set_plan_status(pos, "SKIPPED — no image resolved", _FLASH_RED)
                continue
            live = next((t for t in flash_targets.list_targets()
                         if t.path == a.target.path), None)
            if live is None:
                self.log.appendPlainText(
                    f"Flash plan: device {a.target.path} is no longer attached — skipped.")
                self._set_plan_status(pos, "SKIPPED — device gone", _FLASH_RED)
                continue
            if live.size != a.target.size or live.model != a.target.model:
                self.log.appendPlainText(
                    f"Flash plan: the device now at {a.target.path} is not the one "
                    f"assigned at build time (identity changed) — skipped for safety.")
                self._set_plan_status(pos, "SKIPPED — device identity changed",
                                      _FLASH_RED)
                continue
            flav = "" if flavor == flash_targets.FLAVOR_AUTO else f" [{flavor}]"
            self.log.appendPlainText(
                f"Flash plan: {a.entry_id}{flav} ({os.path.basename(artifact)}) → "
                f"{a.target.path} (opted in)…")
            # Read by _start_flash's confirmation only; cleared there so a caveat can
            # never leak onto the NEXT device's dialog.
            self._flash_caveats = caveats
            self._flash_cancelled = False       # set by _start_flash on a decline
            self._flash_busy_skipped = False    # set by _start_flash when it refuses
            # #415: claim the row BEFORE the write starts, so _flash_done paints the
            # outcome onto THIS row no matter how many flashes follow. _start_flash
            # un-claims it on every path that does not actually start a worker.
            self._flash_active_row = pos
            self._set_plan_status(pos, "writing…", "")
            self._start_flash(a.target, argv=flash_targets.assignment_argv(
                a, generator_dir=self.wiz.generator_dir, artifact=artifact))
            if getattr(self, "_flash_busy_skipped", False):
                # The previous flasher is STILL running after the 3 s join, so this
                # assignment never started — and the row is currently claiming
                # "writing…", which is a lie about a device nothing has touched. Say
                # so loudly and move on; every following row hits the same guard and
                # is marked the same way, so the table never shows a write that never happened.
                self._flash_busy_skipped = False
                self.log.appendPlainText(
                    f"Flash plan: {a.entry_id} → {a.target.path} was NOT started — the "
                    f"previous flash is still running. Nothing was written to "
                    f"{a.target.path}.")
                self._set_plan_status(pos, "NOT started — flasher busy", _FLASH_RED)
                continue
            if getattr(self, "_flash_cancelled", False):
                # the operator declined THIS device — offer the next assignment
                # rather than stranding the rest of the plan.
                self._flash_cancelled = False
                self._set_plan_status(pos, "cancelled — not written", _FLASH_GREY)
                continue
            return

    def _flash_confirm_text(self, target, argv: list[str]) -> str:
        """The body of the one flash warning: what is destroyed, what is written, and
        every condition that used to be a silent refusal."""
        gib = target.size / (1 << 30)
        name = (target.model or target.fs_label or "").strip() or "(unknown)"
        lines = [f"This ERASES {target.path} — {name}, {gib:.1f} GiB, {target.kind}.",
                 "Everything on that device is overwritten. It cannot be undone.",
                 ""]
        artifact = ""
        if argv and "--artifact" in argv:
            i = argv.index("--artifact")
            if i + 1 < len(argv):
                artifact = argv[i + 1]
        if artifact:
            lines.append(f"Image:  {os.path.basename(artifact)}")
            if flash_targets.is_compressed_artifact(artifact):
                lines.append("        (compressed — decompressed straight onto the "
                             "disk, so the written size is larger than the file)")
        else:
            lines.append("Image:  auto-picked by scripts/flash-disk.sh")
        for note in getattr(self, "_flash_caveats", ()) or ():
            lines += ["", note]
        return "\n".join(lines)

    def _start_flash(self, target, argv: list[str] | None = None) -> None:
        """Launch the flasher — behind THE confirmation (#337).

        One OK/Cancel warning, here, at the moment the flash starts, for every path
        into it (the Flash… button and each post-build plan assignment). It is a
        module-level override point (``confirm_flash``) so the headless suite exercises the real
        gate, and it is called from a click / an explicitly opted-in post-build action
        — never from validatePage, initializePage, isComplete or itemChanged, where a
        modal deadlocks an offscreen test."""
        if self.flash_worker is not None and self.flash_worker.isRunning():
            # Busy: this assignment never starts, so its caveats must not survive to be
            # printed in the NEXT device's confirmation. (_flash_next sets _flash_caveats
            # BEFORE calling us, and the clear below is only reached once we get past
            # this guard — so without this line a 3s worker-wait timeout leaks one
            # device's "matched by arch+role only" note onto a different device.)
            self._flash_caveats = []
            # #415: nothing was started, so this row owns no worker — say so to
            # _flash_next (which has already painted it "writing…") and make sure the
            # NEXT done signal cannot be attributed to it.
            self._flash_busy_skipped = True
            self._flash_active_row = -1
            return
        argv = argv or self._flash_argv_for(target)
        answer = confirm_flash(self, "Flash — this erases the device",
                              self._flash_confirm_text(target, argv),
                              FLASH_OK | FLASH_CANCEL, FLASH_CANCEL)
        self._flash_caveats = []
        if answer != FLASH_OK:
            self._flash_cancelled = True
            # #415: no worker starts, so no done signal belongs to this row.
            self._flash_active_row = -1
            self.log.appendPlainText(
                f"Flash cancelled — {target.path} was not written.")
            return
        self.flash_btn.setEnabled(False)
        self.flash_refresh_btn.setEnabled(False)
        self.log.appendPlainText(f"\n=== flashing {target.path} via scripts/flash-disk.sh ===")
        # #415: arm the per-image indicator for THIS write. After the confirmation, so
        # a declined flash never paints a bar; the artifact name comes off the argv, so
        # the label can never disagree with what is actually being written.
        try:
            art = ""
            if "--artifact" in argv:
                i = argv.index("--artifact")
                art = argv[i + 1] if i + 1 < len(argv) else ""
            self._begin_flash_progress(art)
        except (AttributeError, RuntimeError):
            pass                # a page built with __new__ (direct-slot tests)
        self.flash_worker = hold_thread(_FlashWorker(argv, self.wiz.generator_dir))
        self.flash_worker.line.connect(self._on_flash_line)
        self.flash_worker.done.connect(self._flash_done)
        self.flash_worker.start()

    def _flash_done(self, code: int) -> None:
        self.log.appendPlainText(f"=== flash exited {code} ===")
        self.flash_refresh_btn.setEnabled(True)
        # #415: record the OUTCOME on the row the FINISHED flash actually belonged to.
        #
        # It must be _flash_active_row, not `_flash_plan_pos - 1`: every _FlashWorker
        # lands here, the Flash… button's included, and after a plan has drained
        # _flash_plan_pos == len(plan) — so the derived index would repaint the LAST
        # plan row with an unrelated standalone flash's result. That is a table saying
        # "written" about a device this flash never touched (and, in the dangerous
        # direction, overwriting a real FAILED with a green "written"). -1 means "this
        # flash was not a plan row": _set_plan_status ignores it.
        try:
            row = self._flash_active_row
        except (AttributeError, RuntimeError):
            row = -1
        self._set_plan_status(row,
                              "written" if code == 0 else f"FAILED (rc={code})",
                              _FLASH_GREEN if code == 0 else _FLASH_RED)
        self._flash_active_row = -1       # consumed: never repainted by a later flash
        try:
            self._finish_flash_progress(code)
        except (AttributeError, RuntimeError):
            pass
        self._refresh_flash_targets()
        self._flash_next()                    # chain the next plan assignment (if any)

    # ---- post-build QEMU emulated-device tests (cfg.qemu_device_tests opt-in) ---
    def _maybe_qemu_tests(self) -> None:
        """BuildPage's "after the build, run the QEMU emulated-device tests" opt-in
        (cfg.qemu_device_tests — a NON-ARGV field, offered only for --env test builds; the
        gate lives on BuildPage and is re-enforced at collect time).

        Runs tests/qemu/run-qemu-docker.sh against THIS session's workdir — the same
        containerized harness QemuPage drives interactively, so "build then test"
        and "test what exists" are one code path — streaming its output into the
        shared log. Called only from an all-ok _on_finished_all: booting the
        artifacts of a failed run would assert against images that were never fully
        produced. The checkbox WAS the explicit opt-in, and there is no second confirm
        here — unlike _maybe_auto_flash, which since #337 DOES warn. The difference is
        the blast radius, not the opt-in: this boots images in a container and writes no
        block device, so there is nothing to destroy."""
        if not getattr(self.wiz.cfg, "qemu_device_tests", False):
            return
        blocker = qemu_tests.native_blocker()
        if blocker:
            # The runner is a bash script: on native Windows the spawn IS the failure,
            # and _qemu_tests_done would then blame "failures" for tests that never ran.
            self.log.appendPlainText(f"QEMU device tests: skipped. {blocker}")
            return
        workdir = self._session.workdir if self._session is not None else ""
        if not workdir or not os.path.isdir(workdir):
            self.log.appendPlainText(
                "QEMU device tests: no session workdir to test — skipped.")
            return
        if self.qemu_worker is not None and self.qemu_worker.isRunning():
            return
        opts = qemu_tests.QemuRunOptions(artifacts_dir=workdir)
        self.log.appendPlainText(
            "\n=== QEMU emulated-device tests (opted in with the build) ===\n"
            f"$ {qemu_tests.command_string(self.wiz.generator_dir, opts)}")
        self.qemu_worker = hold_thread(_FlashWorker(
            qemu_tests.runner_command(self.wiz.generator_dir, opts),
            self.wiz.generator_dir))
        self.qemu_worker.line.connect(lambda s: self.log.appendPlainText(s))
        self.qemu_worker.done.connect(self._qemu_tests_done)
        self.qemu_worker.start()

    def _qemu_tests_done(self, code: int) -> None:
        self.log.appendPlainText(
            "=== QEMU device tests passed ===" if code == 0 else
            f"=== QEMU device tests reported failures (exit {code}) — per-device "
            "results are under out/qemu-runs/results ===")

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
        """Exit is enabled only once every image row is terminal (the run has settled)."""
        return self._all_terminal

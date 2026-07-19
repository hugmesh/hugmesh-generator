"""FleetPage / FleetWindow — the multi-role fan-out channel (G39): a Studio
front-end for scripts/build-all-roles.sh's fleet targets (the menu's build-all /
build-everything / rpi / x86) and their env knobs (X86_OMNIBUS / X86_STANDALONE /
RPI_ROLES / FRITE=1 / JETSON=1 / ORANGEPI5=1 / ORANGEPIZERO2=1 / PENTEST=1 /
SKIP_KEYS=1 / …).

Deliberately SELF-CONTAINED (like golive.py): ``FleetWindow(generator_dir)`` works
without any wizard-page registration, so the single-image wizard's page registry
(gui/wizard.py) does not need to know about the fleet channel to ship it.
All option logic lives Qt-free in core.fleet (FleetConfig/FleetDriver) — this
module only collects widgets into a FleetConfig and streams the run.

NON-MODAL + SINGLE INSTANCE: the wizard's Welcome page opens the fleet flow via
:func:`open_fleet_window` — a plain ``show()`` (never ``exec()``), so the Welcome
screen and its Previous-builds session manager stay fully interactive while the
fleet window is open AND while a run streams (_FleetWorker already runs off the
GUI thread; the old ``exec()`` nested-event-loop block is gone). Re-invoking
focuses the ONE existing window. FleetWindow does NOT set WA_DeleteOnClose:
closing hides it, so the instance (and a running _FleetWorker + FleetDriver)
survives — single instance, state preservation, and honest backgrounding are
structurally correct. ``snapdragon_studio --fleet`` (app.py) hosts the same class
standalone as its own top-level window; the ``FleetDialog`` alias below keeps its
deferred import working unchanged.

PROGRESSIVE STEPS: the old all-at-once form is now five small steps inside a
QStackedWidget (Platforms -> Roles & boards -> Shared options -> Review -> Run) —
deliberately NOT a second QWizard. Every child widget keeps its attribute name /
widget type / ``_default_combo`` sentinel rule, and :meth:`FleetPage.collect` is
byte-for-byte unchanged, so identical choices necessarily produce an identical
FleetConfig and identical build-all-roles.sh argv on both backends (the page's
whole emission contract; tests pin it against pre-refactor goldens).

SESSIONS: a dispatched fleet run writes a durable build-session record
(core/build_sessions, kind="fleet") with its own per-session /out workdir — the
#357 pattern, applied via the driver's runtime ``workdir`` override so the config
itself never changes. Status is honest: running -> complete/failed/stopped, one
aggregate "all-roles" image row (we cannot truthfully track per-role outcomes
from the script's stream, so we do not fabricate them), and the streamed output
is teed into ``<workdir>/fleet.log``. ``session_changed`` fires after every
record write so the Welcome screen's Previous-builds table refreshes LIVE.
"""
from __future__ import annotations

import os
from collections import deque

from ..qt import QtCore, QtWidgets, Signal
from ..branding_icon import brand_icon
from ...core import build_sessions
from ...core.config import (
    ENV_CHOICES, FRITE_BOARDS, FRITE_DESKTOPS, FRITE_FLAVORS, JETSON_BOARDS,
    KERNEL_FLAVOR_CHOICES, ORANGEPI5_BOARDS, ORANGEPI5_FLAVORS,
    ORANGEPIZERO2_FLAVORS, RPI_BOARDS,
)
from ...core.fleet import FleetConfig, FleetDriver
from ._widgets import _file_picker, _row

# The five progressive steps (indices into FleetPage.stack).
STEP_PLATFORMS, STEP_ROLES, STEP_SHARED, STEP_REVIEW, STEP_RUN = range(5)
_STEP_TITLES = ("Platforms", "Roles & boards", "Shared options", "Review", "Run")


class _FleetWorker(QtCore.QThread):
    """Runs FleetDriver.run() off the GUI thread (mirrors build.py's _BuildWorker)."""
    line = Signal(str)
    done = Signal(int)

    def __init__(self, driver, cfg, backend):
        super().__init__()
        self.driver, self.cfg, self.backend = driver, cfg, backend

    def run(self):
        code = self.driver.run(self.cfg, self.backend, on_line=lambda s: self.line.emit(s))
        self.done.emit(code)


def _default_combo(choices, tooltip=""):
    """A combo whose FIRST entry is the script-default sentinel '' (shown as
    '(default)') — mirrors ImageConfig's only-non-defaults emission rule."""
    c = QtWidgets.QComboBox()
    c.addItem("(default)", "")
    for x in choices:
        c.addItem(x, x)
    if tooltip:
        c.setToolTip(tooltip)
    return c


class FleetPage(QtWidgets.QWidget):
    """Widget collecting one FleetConfig; host it in FleetWindow or any container.

    The refactor to progressive steps only RE-PARENTED the existing widgets into
    stack pages: every attribute (self.skip_x86 … self.extra_flags) and collect()
    survive unchanged, so the FleetConfig/argv emission is identical to the old
    all-at-once form for the same widget states.
    """

    #: Emitted after EVERY build_sessions write (start/update/finish) so the
    #: Welcome screen's Previous-builds table can refresh live.
    session_changed = Signal()

    def __init__(self, generator_dir: str, parent=None):
        super().__init__(parent)
        self.generator_dir = generator_dir
        self.driver = FleetDriver(generator_dir)
        self.worker = None
        # session plumbing (the BuildPage._pending_session_workdir precedent):
        # the id is minted lazily on entering Review so preview == dispatch;
        # a RESTART pins an existing id so the SAME record/workdir is reused.
        self.pending_session_id: str | None = None
        self._session: build_sessions.BuildSession | None = None
        self._log_fh = None
        self._tail: deque[str] = deque(maxlen=build_sessions.ERROR_TAIL_LINES)
        self._stop_requested = False

        outer = QtWidgets.QVBoxLayout(self)
        self.step_title = QtWidgets.QLabel()
        f = self.step_title.font(); f.setBold(True); self.step_title.setFont(f)
        outer.addWidget(self.step_title)
        self.stack = QtWidgets.QStackedWidget()
        outer.addWidget(self.stack, 1)

        # ── step 1: PLATFORMS — which families participate ──
        p1 = QtWidgets.QWidget(); l1 = QtWidgets.QVBoxLayout(p1)
        default_grp = QtWidgets.QGroupBox(
            "Default fleet (rpi5 pki/backend/frontend + x86 pki/be/fe/be+gpu)")
        dl = QtWidgets.QVBoxLayout(default_grp)
        self.skip_x86 = QtWidgets.QCheckBox("Skip x86 entirely (SKIP_X86=1)")
        self.skip_rpi = QtWidgets.QCheckBox("Skip the Raspberry Pi roles (SKIP_RPI=1)")
        dl.addWidget(self.skip_x86); dl.addWidget(self.skip_rpi)
        l1.addWidget(default_grp)
        optin_grp = QtWidgets.QGroupBox(
            "Opt-in platforms (each mirrors the FRITE=1 knob family)")
        ol = QtWidgets.QVBoxLayout(optin_grp)
        self.frite = QtWidgets.QCheckBox("La/Le Frite light desktop (FRITE=1)")
        self.frite_only = QtWidgets.QCheckBox("ONLY the Frite (FRITE_ONLY=1)")
        self.jetson = QtWidgets.QCheckBox("Jetson Orin edge-AI (JETSON=1 — EXPERIMENTAL)")
        self.jetson_only = QtWidgets.QCheckBox("ONLY the Jetson (JETSON_ONLY=1)")
        self.orangepi5 = QtWidgets.QCheckBox("Orange Pi 5 / 5 Plus (ORANGEPI5=1 — EXPERIMENTAL)")
        self.orangepi5_only = QtWidgets.QCheckBox("ONLY the Orange Pi 5 (ORANGEPI5_ONLY=1)")
        self.orangepizero2 = QtWidgets.QCheckBox(
            "Orange Pi Zero 2 headless appliance (ORANGEPIZERO2=1 — EXPERIMENTAL)")
        self.orangepizero2_only = QtWidgets.QCheckBox("ONLY the Zero 2 (ORANGEPIZERO2_ONLY=1)")
        for w in (self.frite, self.frite_only, self.jetson, self.jetson_only,
                  self.orangepi5, self.orangepi5_only,
                  self.orangepizero2, self.orangepizero2_only):
            ol.addWidget(w)
        l1.addWidget(optin_grp)
        pt_grp = QtWidgets.QGroupBox("Pen-test harness")
        pl = QtWidgets.QVBoxLayout(pt_grp)
        self.pentest = QtWidgets.QCheckBox("Run the OWASP pen-test harness after the build (PENTEST=1)")
        self.pentest_only = QtWidgets.QCheckBox("Pen-test ONLY, no image builds (PENTEST_ONLY=1)")
        pl.addWidget(self.pentest); pl.addWidget(self.pentest_only)
        l1.addWidget(pt_grp)
        l1.addStretch(1)
        self.stack.addWidget(p1)

        # ── step 2: ROLES & BOARDS — per-platform detail, VISIBILITY-only gating ──
        # A deselected platform's group is hidden, never cleared: a hidden stale
        # knob still emits exactly what the old form emitted for the same states.
        p2 = QtWidgets.QWidget(); l2 = QtWidgets.QVBoxLayout(p2)
        hint = QtWidgets.QLabel(
            "Only the platforms selected in step 1 are shown; hidden values are "
            "kept, not cleared.")
        hint.setWordWrap(True)
        l2.addWidget(hint)
        self.x86_group = QtWidgets.QGroupBox("x86 roles")
        xl = QtWidgets.QVBoxLayout(self.x86_group)
        self.x86_omnibus = QtWidgets.QCheckBox("Append the x86 omnibus all-in-one role (X86_OMNIBUS=1)")
        self.x86_all = QtWidgets.QCheckBox("Every x86 role incl. omnibus (X86_ALL=1)")
        self.x86_standalone = QtWidgets.QCheckBox(
            "Append the x86 standalone desktops — thin + thick + unaffiliated (X86_STANDALONE=1)")
        self.x86_standalone_only = QtWidgets.QCheckBox(
            "ONLY the x86 standalone desktops (X86_STANDALONE_ONLY=1 — skips the cluster roles)")
        for w in (self.x86_omnibus, self.x86_all, self.x86_standalone,
                  self.x86_standalone_only):
            xl.addWidget(w)
        self.x86_roles = QtWidgets.QLineEdit()
        self.x86_roles.setPlaceholderText("explicit x86 subset, space-separated (X86_ROLES=\"pki omnibus\")")
        xl.addWidget(_row("x86 roles", self.x86_roles))
        l2.addWidget(self.x86_group)
        self.rpi_group = QtWidgets.QGroupBox("Raspberry Pi")
        rl = QtWidgets.QVBoxLayout(self.rpi_group)
        self.rpi_roles = QtWidgets.QLineEdit()
        self.rpi_roles.setPlaceholderText(
            "RPi role subset (RPI_ROLES=\"pki backend frontend desktop\"; desktop is opt-in)")
        rl.addWidget(_row("RPi roles", self.rpi_roles))
        self.rpi_board = _default_combo(
            RPI_BOARDS, "RPI_BOARD — rpi3 is DESKTOP-ONLY (pair with RPI_ROLES=desktop)")
        rl.addWidget(_row("RPi board", self.rpi_board))
        l2.addWidget(self.rpi_group)
        self.frite_group = QtWidgets.QGroupBox("Frite")
        fl = QtWidgets.QVBoxLayout(self.frite_group)
        self.frite_board = _default_combo(FRITE_BOARDS)
        self.frite_flavor = _default_combo(FRITE_FLAVORS)
        self.frite_desktop = _default_combo(FRITE_DESKTOPS)
        fl.addWidget(_row("Frite board", self.frite_board))
        fl.addWidget(_row("Frite flavor", self.frite_flavor))
        fl.addWidget(_row("Frite desktop", self.frite_desktop))
        l2.addWidget(self.frite_group)
        self.jetson_group = QtWidgets.QGroupBox("Jetson")
        jl = QtWidgets.QVBoxLayout(self.jetson_group)
        self.jetson_roles = QtWidgets.QLineEdit()
        self.jetson_roles.setPlaceholderText("JETSON_ROLES subset (default: edge_ai)")
        self.jetson_board = _default_combo(JETSON_BOARDS)
        self.jetson_kernel_flavor = _default_combo(
            KERNEL_FLAVOR_CHOICES, "JETSON_KERNEL_FLAVOR — the l4t BUILD is a stub that hard-errors today")
        jl.addWidget(_row("Jetson roles", self.jetson_roles))
        jl.addWidget(_row("Jetson board", self.jetson_board))
        jl.addWidget(_row("Jetson kernel", self.jetson_kernel_flavor))
        l2.addWidget(self.jetson_group)
        self.orangepi5_group = QtWidgets.QGroupBox("Orange Pi 5")
        o5l = QtWidgets.QVBoxLayout(self.orangepi5_group)
        self.orangepi5_board = _default_combo(ORANGEPI5_BOARDS)
        self.orangepi5_flavor = _default_combo(ORANGEPI5_FLAVORS)
        o5l.addWidget(_row("OPi5 board", self.orangepi5_board))
        o5l.addWidget(_row("OPi5 flavor", self.orangepi5_flavor))
        l2.addWidget(self.orangepi5_group)
        self.orangepizero2_group = QtWidgets.QGroupBox("Orange Pi Zero 2")
        ozl = QtWidgets.QVBoxLayout(self.orangepizero2_group)
        self.orangepizero2_flavor = _default_combo(ORANGEPIZERO2_FLAVORS)
        ozl.addWidget(_row("OPZ2 flavor", self.orangepizero2_flavor))
        l2.addWidget(self.orangepizero2_group)
        self.pentest_group = QtWidgets.QGroupBox("Pen-test")
        ptl = QtWidgets.QVBoxLayout(self.pentest_group)
        self.pentest_env = _default_combo(("compose", "local", "cluster"))
        self.pentest_scan = _default_combo(("baseline", "full"))
        self.pentest_pipeline = _default_combo(("main", "games"))
        ptl.addWidget(_row("Pen-test env", self.pentest_env))
        ptl.addWidget(_row("Pen-test scan", self.pentest_scan))
        ptl.addWidget(_row("Pen-test pipeline", self.pentest_pipeline))
        l2.addWidget(self.pentest_group)
        l2.addStretch(1)
        self.stack.addWidget(p2)

        # ── step 3: SHARED OPTIONS — the fleet-wide pass-through ──
        p3 = QtWidgets.QWidget(); l3 = QtWidgets.QVBoxLayout(p3)
        shared = QtWidgets.QGroupBox("Fleet-wide")
        sl = QtWidgets.QVBoxLayout(shared)
        self.skip_keys = QtWidgets.QCheckBox(
            "Skip the per-role KEYS folder generation (SKIP_KEYS=1 — folders are the default)")
        sl.addWidget(self.skip_keys)
        self.env = _default_combo(ENV_CHOICES, "--env forwarded to every builder (default test)")
        sl.addWidget(_row("Build env", self.env))
        self.brand_profile = QtWidgets.QLineEdit()
        bp_btn = _file_picker(self, self.brand_profile, "Brand profile", "Brand profile (*.conf)")
        bp = QtWidgets.QWidget(); bh = QtWidgets.QHBoxLayout(bp); bh.setContentsMargins(0, 0, 0, 0)
        bh.addWidget(self.brand_profile, 1); bh.addWidget(bp_btn)
        sl.addWidget(_row("Brand profile", bp))
        self.cluster_domain = QtWidgets.QLineEdit()
        self.cluster_domain.setPlaceholderText("--cluster-domain forwarded to every builder")
        sl.addWidget(_row("Cluster domain", self.cluster_domain))
        self.headscale_url = QtWidgets.QLineEdit()
        self.headscale_url.setPlaceholderText(
            "brand mesh control server (HEADSCALE_URL env — baked to /etc/snapdragon/headscale-url)")
        sl.addWidget(_row("Headscale URL", self.headscale_url))
        self.output_dir = QtWidgets.QLineEdit()
        od_btn = _file_picker(self, self.output_dir, "Output directory", directory=True)
        od = QtWidgets.QWidget(); oh = QtWidgets.QHBoxLayout(od); oh.setContentsMargins(0, 0, 0, 0)
        oh.addWidget(self.output_dir, 1); oh.addWidget(od_btn)
        sl.addWidget(_row("Output dir", od))
        self.jobs = QtWidgets.QSpinBox(); self.jobs.setRange(1, 128); self.jobs.setValue(8)
        sl.addWidget(_row("Jobs", self.jobs))
        self.backend = QtWidgets.QComboBox(); self.backend.addItems(["auto", "native", "docker"])
        sl.addWidget(_row("Backend", self.backend))
        self.extra_flags = QtWidgets.QLineEdit()
        self.extra_flags.setPlaceholderText("extra pass-through builder flags, appended verbatim")
        sl.addWidget(_row("Extra flags", self.extra_flags))
        l3.addWidget(shared)
        l3.addStretch(1)
        self.stack.addWidget(p3)

        # ── step 4: REVIEW — the exact command (unchanged emission) + preflight ──
        p4 = QtWidgets.QWidget(); l4 = QtWidgets.QVBoxLayout(p4)
        l4.addWidget(QtWidgets.QLabel("Command:"))
        self.cmd = QtWidgets.QPlainTextEdit(); self.cmd.setReadOnly(True); self.cmd.setMaximumHeight(100)
        l4.addWidget(self.cmd)
        self.preview_btn = QtWidgets.QPushButton("Refresh preview")
        self.preview_btn.clicked.connect(self.refresh_preview)
        pb_row = QtWidgets.QHBoxLayout(); pb_row.addWidget(self.preview_btn); pb_row.addStretch(1)
        l4.addLayout(pb_row)
        self.problems = QtWidgets.QPlainTextEdit(); self.problems.setReadOnly(True)
        l4.addWidget(self.problems, 1)
        self.stack.addWidget(p4)

        # ── step 5: RUN — live progress + Stop ──
        p5 = QtWidgets.QWidget(); l5 = QtWidgets.QVBoxLayout(p5)
        self.stop_btn = QtWidgets.QPushButton("Stop"); self.stop_btn.setEnabled(False)
        self.stop_btn.clicked.connect(self._stop)
        st_row = QtWidgets.QHBoxLayout(); st_row.addWidget(self.stop_btn); st_row.addStretch(1)
        l5.addLayout(st_row)
        self.log = QtWidgets.QPlainTextEdit(); self.log.setReadOnly(True)
        l5.addWidget(self.log, 1)
        self.stack.addWidget(p5)

        # ── Back / Next navigation row ──
        nav = QtWidgets.QHBoxLayout()
        self.back_btn = QtWidgets.QPushButton("Back")
        self.back_btn.clicked.connect(self._back)
        self.next_btn = QtWidgets.QPushButton("Next")
        self.next_btn.clicked.connect(self._next)
        nav.addWidget(self.back_btn); nav.addStretch(1); nav.addWidget(self.next_btn)
        outer.addLayout(nav)

        # step-1 participation drives step-2 group VISIBILITY only (never values)
        for cb in (self.skip_x86, self.skip_rpi, self.frite, self.frite_only,
                   self.jetson, self.jetson_only, self.orangepi5, self.orangepi5_only,
                   self.orangepizero2, self.orangepizero2_only,
                   self.pentest, self.pentest_only):
            cb.toggled.connect(self._update_group_visibility)
        self._update_group_visibility()
        self._goto(STEP_PLATFORMS)

    # ---- widget -> FleetConfig collection (the page's whole contract) --------
    def collect(self) -> FleetConfig:
        return FleetConfig(
            skip_x86=self.skip_x86.isChecked(),
            x86_omnibus=self.x86_omnibus.isChecked(),
            x86_all=self.x86_all.isChecked(),
            x86_roles=self.x86_roles.text().strip(),
            x86_standalone=self.x86_standalone.isChecked(),
            x86_standalone_only=self.x86_standalone_only.isChecked(),
            skip_rpi=self.skip_rpi.isChecked(),
            rpi_roles=self.rpi_roles.text().strip(),
            rpi_board=self.rpi_board.currentData(),
            frite=self.frite.isChecked(), frite_only=self.frite_only.isChecked(),
            frite_board=self.frite_board.currentData(),
            frite_flavor=self.frite_flavor.currentData(),
            frite_desktop=self.frite_desktop.currentData(),
            jetson=self.jetson.isChecked(), jetson_only=self.jetson_only.isChecked(),
            jetson_roles=self.jetson_roles.text().strip(),
            jetson_board=self.jetson_board.currentData(),
            jetson_kernel_flavor=self.jetson_kernel_flavor.currentData(),
            orangepi5=self.orangepi5.isChecked(),
            orangepi5_only=self.orangepi5_only.isChecked(),
            orangepi5_board=self.orangepi5_board.currentData(),
            orangepi5_flavor=self.orangepi5_flavor.currentData(),
            orangepizero2=self.orangepizero2.isChecked(),
            orangepizero2_only=self.orangepizero2_only.isChecked(),
            orangepizero2_flavor=self.orangepizero2_flavor.currentData(),
            skip_keys=self.skip_keys.isChecked(),
            pentest=self.pentest.isChecked(), pentest_only=self.pentest_only.isChecked(),
            pentest_env=self.pentest_env.currentData(),
            pentest_scan=self.pentest_scan.currentData(),
            pentest_pipeline=self.pentest_pipeline.currentData(),
            headscale_url=self.headscale_url.text().strip(),
            env=self.env.currentData(),
            brand_profile=self.brand_profile.text().strip(),
            cluster_domain=self.cluster_domain.text().strip(),
            output_dir=self.output_dir.text().strip(),
            jobs=self.jobs.value(),
            extra_flags=self.extra_flags.text().strip(),
        )

    # ---- FleetConfig -> widgets (the exact inverse of collect, for RESTART/REDO) ----
    def apply(self, cfg: FleetConfig) -> None:
        def combo(c, val):
            i = c.findData(val)
            c.setCurrentIndex(i if i >= 0 else 0)
        self.skip_x86.setChecked(cfg.skip_x86)
        self.x86_omnibus.setChecked(cfg.x86_omnibus)
        self.x86_all.setChecked(cfg.x86_all)
        self.x86_roles.setText(cfg.x86_roles)
        self.x86_standalone.setChecked(cfg.x86_standalone)
        self.x86_standalone_only.setChecked(cfg.x86_standalone_only)
        self.skip_rpi.setChecked(cfg.skip_rpi)
        self.rpi_roles.setText(cfg.rpi_roles)
        combo(self.rpi_board, cfg.rpi_board)
        self.frite.setChecked(cfg.frite)
        self.frite_only.setChecked(cfg.frite_only)
        combo(self.frite_board, cfg.frite_board)
        combo(self.frite_flavor, cfg.frite_flavor)
        combo(self.frite_desktop, cfg.frite_desktop)
        self.jetson.setChecked(cfg.jetson)
        self.jetson_only.setChecked(cfg.jetson_only)
        self.jetson_roles.setText(cfg.jetson_roles)
        combo(self.jetson_board, cfg.jetson_board)
        combo(self.jetson_kernel_flavor, cfg.jetson_kernel_flavor)
        self.orangepi5.setChecked(cfg.orangepi5)
        self.orangepi5_only.setChecked(cfg.orangepi5_only)
        combo(self.orangepi5_board, cfg.orangepi5_board)
        combo(self.orangepi5_flavor, cfg.orangepi5_flavor)
        self.orangepizero2.setChecked(cfg.orangepizero2)
        self.orangepizero2_only.setChecked(cfg.orangepizero2_only)
        combo(self.orangepizero2_flavor, cfg.orangepizero2_flavor)
        self.skip_keys.setChecked(cfg.skip_keys)
        self.pentest.setChecked(cfg.pentest)
        self.pentest_only.setChecked(cfg.pentest_only)
        combo(self.pentest_env, cfg.pentest_env)
        combo(self.pentest_scan, cfg.pentest_scan)
        combo(self.pentest_pipeline, cfg.pentest_pipeline)
        self.headscale_url.setText(cfg.headscale_url)
        combo(self.env, cfg.env)
        self.brand_profile.setText(cfg.brand_profile)
        self.cluster_domain.setText(cfg.cluster_domain)
        self.output_dir.setText(cfg.output_dir)
        self.jobs.setValue(cfg.jobs)
        self.extra_flags.setText(cfg.extra_flags)
        self._update_group_visibility()

    def load_from_session(self, s, pin: bool = True) -> None:
        """RESTART/REDO entry: load a fleet session's recorded config back into the
        widgets and land on the Review step. ``pin=True`` (RESTART) reuses the SAME
        record id/workdir — new_fleet_session archives the prior outcome into
        ``history``; ``pin=False`` (REDO) mints a fresh record at Review."""
        self.apply(FleetConfig.from_dict(s.config))
        self.backend.setCurrentText(s.backend or "auto")
        self.pending_session_id = s.id if pin else None
        self._goto(STEP_REVIEW)

    # ---- step navigation ------------------------------------------------------
    def _goto(self, i: int) -> None:
        self.stack.setCurrentIndex(i)
        self.step_title.setText(f"Step {i + 1} of {len(_STEP_TITLES)} — {_STEP_TITLES[i]}")
        if i == STEP_REVIEW:
            self._enter_review()
        self._update_nav()

    def _update_nav(self) -> None:
        i = self.stack.currentIndex()
        running = self.worker is not None and self.worker.isRunning()
        self.back_btn.setEnabled(i > 0 and not running)   # Back disabled while running
        if i == STEP_REVIEW:
            self.next_btn.setText("Build fleet now")
            self.next_btn.setEnabled(not running)
        else:
            self.next_btn.setText("Next")
            self.next_btn.setEnabled(i < STEP_RUN and not running)

    def _back(self) -> None:
        i = self.stack.currentIndex()
        if i > 0:
            self._goto(i - 1)

    def _next(self) -> None:
        i = self.stack.currentIndex()
        if i == STEP_REVIEW:
            if self._start():
                self._goto(STEP_RUN)
        elif i < STEP_RUN:
            self._goto(i + 1)

    def _update_group_visibility(self) -> None:
        """Step-2 groups follow step-1 participation — VISIBILITY ONLY, never
        auto-clearing values, so a hidden stale knob still emits exactly what the
        old all-at-once form emitted for the same widget states."""
        self.x86_group.setVisible(not self.skip_x86.isChecked())
        self.rpi_group.setVisible(not self.skip_rpi.isChecked())
        self.frite_group.setVisible(self.frite.isChecked() or self.frite_only.isChecked())
        self.jetson_group.setVisible(self.jetson.isChecked() or self.jetson_only.isChecked())
        self.orangepi5_group.setVisible(
            self.orangepi5.isChecked() or self.orangepi5_only.isChecked())
        self.orangepizero2_group.setVisible(
            self.orangepizero2.isChecked() or self.orangepizero2_only.isChecked())
        self.pentest_group.setVisible(
            self.pentest.isChecked() or self.pentest_only.isChecked())

    # ---- preview / run ----------------------------------------------------------
    def _backend(self):
        b = self.backend.currentText()
        return None if b == "auto" else b

    def _session_out_dir(self) -> str:
        return (self.output_dir.text().strip()
                or os.path.join(os.path.abspath(self.generator_dir), "out"))

    def _enter_review(self) -> None:
        """Mint the session id ONCE per dispatch attempt (lazily — Back-and-forth
        reuses it) and preview with the per-session workdir override applied, so
        preview == dispatch (the BuildPage._pending_session_workdir precedent).
        The override is runtime driver state only — NEVER written into the config."""
        if not self.pending_session_id:
            self.pending_session_id = build_sessions.new_session_id()
        self.driver.workdir = build_sessions.session_workdir(
            self._session_out_dir(), self.pending_session_id)
        self.refresh_preview()

    def refresh_preview(self):
        try:
            cfg = self.collect()
            self.cmd.setPlainText(self.driver.command_string(cfg, self._backend()))
        except Exception as e:  # IdentityValidationError etc. — show, never crash
            self.cmd.setPlainText(f"INVALID: {e}")
            self.problems.setPlainText("")
            return
        problems = self.driver.preflight(cfg, self._backend())
        if problems:
            self.problems.setPlainText(
                "Preflight:\n" + "\n".join(f"  - {p}" for p in problems))
        else:
            self.problems.setPlainText("Preflight: OK")

    def _start(self) -> bool:
        try:
            cfg = self.collect()
        except Exception as e:
            self.problems.setPlainText(f"INVALID: {e}")
            return False
        problems = self.driver.preflight(cfg, self._backend())
        if problems:
            self.problems.setPlainText(
                "Preflight FAILED:\n" + "\n".join(f"  - {p}" for p in problems))
            return False
        # durable session record (kind="fleet") — same id the Review preview used,
        # so preview == dispatch; a pinned id (RESTART) reuses the SAME record.
        if not self.pending_session_id:
            self.pending_session_id = build_sessions.new_session_id()
        s = build_sessions.new_fleet_session(
            cfg, self.generator_dir, backend=self._backend(),
            session_id=self.pending_session_id)
        self.driver.workdir = s.workdir
        self.refresh_preview()
        self._session = s
        self._stop_requested = False
        self._tail = deque(maxlen=build_sessions.ERROR_TAIL_LINES)
        try:                                   # tee target for the streamed output
            os.makedirs(s.workdir, exist_ok=True)
            self._log_fh = open(s.log_path, "a", encoding="utf-8")
        except OSError:
            self._log_fh = None                # best-effort: never blocks the build
        build_sessions.start(s)                # status running + pid/hostname
        self.session_changed.emit()
        self.log.clear()
        self.stop_btn.setEnabled(True)
        self.worker = _FleetWorker(self.driver, cfg, self._backend())
        self.worker.line.connect(self._on_line)
        self.worker.done.connect(self._done)
        self.worker.start()
        self._update_nav()
        return True

    def _on_line(self, line: str) -> None:
        self.log.appendPlainText(line)
        self._tail.append(line)
        if self._log_fh is not None:
            try:
                self._log_fh.write(line + "\n")
                self._log_fh.flush()
            except OSError:
                pass

    def _stop(self):
        self._stop_requested = True
        self.driver.cancel()

    def _done(self, code):
        self.stop_btn.setEnabled(False)
        self.log.appendPlainText(f"\n[fleet] exited with code {code}")
        if self._log_fh is not None:
            try:
                self._log_fh.close()
            except OSError:
                pass
            self._log_fh = None
        s = self._session
        if s is not None:                      # honest terminal record
            img_status = ("ok" if code == 0
                          else "stopped" if self._stop_requested else "failed")
            build_sessions.update_image(s, 0, status=img_status, exit_code=code)
            status = (build_sessions.COMPLETE if code == 0
                      else build_sessions.STOPPED if self._stop_requested
                      else build_sessions.FAILED)
            tail = ({"fleet": list(self._tail)}
                    if status == build_sessions.FAILED else None)
            build_sessions.finish(s, status, tail)
            self.session_changed.emit()
        self._session = None
        self.pending_session_id = None         # next run mints a fresh record
        self._update_nav()


class FleetWindow(QtWidgets.QDialog):
    """The fleet host window: non-modal from the wizard (open via
    :func:`open_fleet_window` — plain ``show()``), or its own top-level window on
    the standalone ``--fleet`` entry (app.py). No WA_DeleteOnClose: closing HIDES
    it, so the instance (and a running _FleetWorker/FleetDriver) survives —
    single-instance focus, state preservation, and honest backgrounding."""

    def __init__(self, generator_dir: str, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Snapdragon fleet build (build-all-roles)")
        self.setWindowIcon(brand_icon())
        lay = QtWidgets.QVBoxLayout(self)
        scroll = QtWidgets.QScrollArea(); scroll.setWidgetResizable(True)
        self.page = FleetPage(generator_dir)
        scroll.setWidget(self.page)
        lay.addWidget(scroll)
        self.resize(760, 700)

    def closeEvent(self, e):
        """Closing mid-run asks: Stop (driver.cancel(); the worker's done signal
        still fires into the hidden window and finalizes the record as stopped),
        Background (the run continues; its record stays ``running`` and keeps
        updating in Previous builds — honest backgrounding), or Cancel."""
        w = self.page.worker
        if w is not None and w.isRunning():
            box = QtWidgets.QMessageBox(self)
            box.setWindowTitle("Fleet build running")
            box.setText("A fleet build is still running.")
            stop = box.addButton(
                "Stop build", QtWidgets.QMessageBox.ButtonRole.DestructiveRole)
            box.addButton("Keep running in background",
                          QtWidgets.QMessageBox.ButtonRole.AcceptRole)
            cancel = box.addButton(QtWidgets.QMessageBox.StandardButton.Cancel)
            box.exec()
            clicked = box.clickedButton()
            if clicked is cancel:
                e.ignore()
                return
            if clicked is stop:
                self.page._stop()
            e.accept()                         # hide; the instance survives either way
            return
        e.accept()


# app.py's deferred ``from .gui.pages.fleet import FleetDialog`` (the standalone
# --fleet entry) and any external references keep working unchanged.
FleetDialog = FleetWindow


def open_fleet_window(wiz, session=None, reuse_record: bool = True):
    """Open (or focus) THE wizard's one non-modal fleet window.

    Owns the singleton: an existing ``wiz.fleet_window`` is shown/raised; otherwise
    a FleetWindow is created parented to the wizard (a QDialog parented to the
    wizard is still a separate top-level window — non-modal, so the Welcome page,
    the Previous-builds table, and every wizard button stay fully interactive while
    the fleet window is open AND while a run streams). Its ``session_changed`` is
    wired to the Previous-builds refresh so a dispatched fleet run appears/updates
    LIVE. ``session`` routes RESTART (``reuse_record=True`` — same record/workdir,
    prior outcome archived) and REDO (``reuse_record=False`` — fresh record) back
    into the window on the Review step. Never calls exec()."""
    win = getattr(wiz, "fleet_window", None)
    if win is None:
        win = FleetWindow(wiz.generator_dir, parent=wiz)
        wiz.fleet_window = win
        pb = _previous_builds_widget(wiz)
        if pb is not None:
            win.page.session_changed.connect(pb.refresh)
    if session is not None:
        win.page.load_from_session(session, pin=reuse_record)
    win.show()
    win.raise_()
    win.activateWindow()
    return win


def _previous_builds_widget(wiz):
    """The wizard's PreviousBuildsWidget (WelcomePage.previous_builds), or None."""
    for pid in (wiz.pageIds() if hasattr(wiz, "pageIds") else []):
        pb = getattr(wiz.page(pid), "previous_builds", None)
        if pb is not None:
            return pb
    return None

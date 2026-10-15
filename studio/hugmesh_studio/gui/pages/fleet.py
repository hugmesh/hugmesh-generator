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

NON-MODAL + SINGLE INSTANCE: the wizard's Sessions page opens the fleet flow via
:func:`open_fleet_window` — a plain ``show()`` (never ``exec()``), so the Sessions
screen and its Previous-builds session manager stay fully interactive while the
fleet window is open AND while a run streams (_FleetWorker already runs off the
GUI thread; the old ``exec()`` nested-event-loop block is gone). Re-invoking
focuses the ONE existing window. FleetWindow does NOT set WA_DeleteOnClose:
closing hides it, so the instance (and a running _FleetWorker + FleetDriver)
survives — single instance, state preservation, and honest backgrounding are
structurally correct. ``hugmesh_studio --fleet`` (app.py) hosts the same class
standalone as its own top-level window; the ``FleetDialog`` alias below keeps its
deferred import working unchanged.

PROGRESSIVE STEPS: the old all-at-once form is now small steps inside a
QStackedWidget (Platforms -> Roles & boards -> Shared options -> Domains -> Domain
services -> Review -> Run) — deliberately NOT a second QWizard. Every child widget keeps its attribute name /
widget type / ``_default_combo`` sentinel rule, and :meth:`FleetPage.collect` is
byte-for-byte unchanged, so identical choices necessarily produce an identical
FleetConfig and identical build-all-roles.sh argv on both backends (the page's
whole emission contract; tests pin it against pre-refactor goldens).

DOMAINS (#587): the two steps after Shared options are the image flow's own surfaces,
re-hosted exactly as the generate-a-new-local-mesh route hosts them — the shared
Domains table (``DomainsTableWidget``; row 0 is the fleet's own domain, taken from the
Cluster domain field) and the per-domain services walk (``DomainServicesWidget``, one
page per domain). The per-domain gate refuses at Review, INLINE in the preflight pane
(never a modal), through ``FleetDriver.preflight`` — so a RESTART refuses too. The
Sign-in column is hidden here: a fleet stands up no Casdoor, so offering "Own" would be
a knob that reaches nothing. What the rows do and do not reach is ``core.fleet``'s
module doc, and the services step says it in one sentence (``FLEET_LANE_NOTE``).

SESSIONS: a dispatched fleet run writes a durable build-session record
(core/build_sessions, kind="fleet") with its own per-session /out workdir — the
#357 pattern, applied via the driver's runtime ``workdir`` override so the config
itself never changes. Status is honest: running -> complete/failed/stopped, one
aggregate "all-roles" image row (we cannot truthfully track per-role outcomes
from the script's stream, so we do not fabricate them), and the streamed output
is teed into ``<workdir>/fleet.log``. ``session_changed`` fires after every
record write so the Sessions screen's Previous-builds table refreshes LIVE.
"""
from __future__ import annotations

import os
import traceback
from collections import deque

from ..qt import QtCore, QtWidgets, Signal
from .. import console
from ..branding_icon import brand_icon
from ...core import build_sessions
from ...core.config import (
    ENV_CHOICES, FRITE_BOARDS, FRITE_DESKTOPS, FRITE_FLAVORS, JETSON_BOARDS,
    KERNEL_FLAVOR_CHOICES, ORANGEPI5_BOARDS, ORANGEPI5_FLAVORS,
    ORANGEPIZERO2_FLAVORS, ORANGEPIZERO2W_FLAVORS, ORANGEPIZERO3_FLAVORS, ORANGEPI3LTS_FLAVORS,
    ORANGEPI4LTS_FLAVORS,
    RPI_BOARDS,
)
from ...core.fleet import (FLEET_LANE_NOTE, FleetConfig, FleetDomains, FleetDriver,
                           commit_fleet_domains, fleet_domain_fields,
                           fleet_domains_from_config, seed_fleet_domains)
from ...core import plain_words
from ...tui.superbrand_step import session_for
from ._scroll import scrollable
from ._widgets import _file_picker, _row
from .brand_picker import BrandPicker
from .domain_services import DomainServicesWidget
from .domains import _COL_IDP, DomainsTableWidget
from .superbrand import SuperbrandStep

# The progressive steps (indices into FleetPage.stack). STEP_BRAND (#654, D8) is the
# superbrand's design: the drop-down is on Shared options (where the brand profile row
# was), and choosing ‘Create a new superbrand’ there opens the design on this step.
(STEP_PLATFORMS, STEP_ROLES, STEP_SHARED, STEP_BRAND, STEP_DOMAINS,
 STEP_DOMAIN_SERVICES, STEP_REVIEW, STEP_RUN) = range(8)
_STEP_TITLES = ("Platforms", "Roles & boards", "Shared options",
                plain_words.term("superbrand").capitalize(), "Domains",
                "Domain services", "Review", "Run")


class _FleetBrandOptions:
    """The two FleetConfig fields the superbrand step reads and writes — the Cluster
    domain and the brand profile — as attributes over the page's own line edits, so the
    fleet has ONE store for each (the edit, which ``collect`` already reads)."""

    def __init__(self, page):
        self._page = page

    @property
    def cluster_domain(self) -> str:
        return self._page.cluster_domain.text().strip()

    @cluster_domain.setter
    def cluster_domain(self, value: str) -> None:
        self._page.cluster_domain.setText(value)

    @property
    def brand_profile(self) -> str:
        return self._page.brand_profile.text().strip()

    @brand_profile.setter
    def brand_profile(self, value: str) -> None:
        self._page.brand_profile.setText(value)

# ── the log drain (see FleetPage.__init__'s coalescing note) ──────────────────────────
#: ~20 Hz, the same figure localmesh.py and progress.py use: below the ~100 ms threshold
#: at which a UI reads as laggy, so the pane still looks live.
_DRAIN_MS = 50

#: LIVE log-pane block cap. Unlike progress.py, this page keeps NO in-memory ring buffer
#: of the run — ``_tail`` holds only the last ERROR_TAIL_LINES for the session record's
#: failure tail — so a cap here really would discard scrollback that nothing on screen can
#: restore. The full stream IS durable: every line is teed to <workdir>/fleet.log, which
#: the session record names, so nothing is LOST — but it is not one click away. Hence a
#: deliberately generous cap: 100,000 lines is far more than anyone scrolls back through,
#: while still bounding a fan-out run that would otherwise grow the document to millions
#: of blocks over an all-roles build.
_LOG_MAX_BLOCKS = 100000


class _FleetWorker(QtCore.QThread):
    """Runs FleetDriver.run() off the GUI thread (mirrors build.py's _BuildWorker)."""
    line = Signal(str)
    done = Signal(int)

    def __init__(self, driver, cfg, backend):
        super().__init__()
        self.driver, self.cfg, self.backend = driver, cfg, backend

    def run(self):
        # NEVER let an exception escape this thread (#373). BuildDriver._spawn raises
        # ElevationRefused before the Popen under HUGMESH_STUDIO_NO_ELEVATION (the
        # operator's headless/CI knob), and FleetDriver prepends sudo on a non-root native
        # host. Escaping a reimplemented QThread.run, PyQt6 qFatals the process (rc 134);
        # with crashlog installed the thread merely dies with `done` NEVER emitted, so
        # FleetPage._done never closes the tee/stop button and the session stays
        # 'running'. Mirrors progress._WorklistWorker.run.
        try:
            code = self.driver.run(self.cfg, self.backend,
                                   on_line=lambda s: self.line.emit(s))
        except BaseException as e:  # noqa: BLE001 - a hung GUI is worse than any re-raise
            self.line.emit(f"!! fleet run aborted before completion: {e}")
            for ln in traceback.format_exc().rstrip().splitlines():
                self.line.emit(f"   {ln}")
            self.done.emit(1)
            return
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
    #: Sessions screen's Previous-builds table can refresh live.
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
        #: The Domains / Domain services steps' state (#587) — empty until the Domains
        #: step is first entered (it seeds row 0 there), so a run that never walks the
        #: steps (a RESTART lands on Review) carries exactly what its record carried.
        self.fleet_domains = FleetDomains()
        self._brand_options = _FleetBrandOptions(self)

        # ── LINE COALESCING — the GUI thread must not do per-line I/O ────────────────
        # _FleetWorker emits ONE queued signal PER OUTPUT LINE, and the old slot did three
        # things inline for each of them: appendPlainText (a document edit + repaint
        # request), write(), and flush(). The flush is the worst of the three — a
        # SYNCHRONOUS syscall to the filesystem on the GUI thread, once per line, over the
        # same fan-out stream a single x86 build measures at 3.16M lines / 353 MB
        # (core/emerge_packages.py:12) and a fleet run multiplies by every role. A slow or
        # busy disk therefore blocked the event loop directly.
        #
        # Now the signal does one cheap thing — append to this deque — and a ~20 Hz drain
        # does ONE appendPlainText and ONE write+flush for the whole batch (see
        # _drain_lines). The tee is still line-exact and still flushed, so `tail -F` on
        # <workdir>/fleet.log behaves as before; it is flushed 20x a second instead of
        # 20,000x. Cost becomes O(ticks), not O(lines).
        self._line_inbox: deque[str] = deque()
        self._drain = QtCore.QTimer(self)
        self._drain.setInterval(_DRAIN_MS)
        self._drain.timeout.connect(self._drain_lines)

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
        self.orangepizero2w = QtWidgets.QCheckBox(
            "Orange Pi Zero 2W headless appliance (ORANGEPIZERO2W=1 — EXPERIMENTAL)")
        self.orangepizero2w_only = QtWidgets.QCheckBox("ONLY the Zero 2W (ORANGEPIZERO2W_ONLY=1)")
        self.orangepizero3 = QtWidgets.QCheckBox(
            "Orange Pi Zero 3 headless appliance (ORANGEPIZERO3=1 — EXPERIMENTAL)")
        self.orangepizero3_only = QtWidgets.QCheckBox("ONLY the Zero 3 (ORANGEPIZERO3_ONLY=1)")
        self.orangepi3lts = QtWidgets.QCheckBox(
            "Orange Pi 3 LTS headless appliance (ORANGEPI3LTS=1 — EXPERIMENTAL)")
        self.orangepi3lts_only = QtWidgets.QCheckBox("ONLY the OPi 3 LTS (ORANGEPI3LTS_ONLY=1)")
        self.orangepi4lts = QtWidgets.QCheckBox(
            "Orange Pi 4 LTS light desktop (ORANGEPI4LTS=1 — EXPERIMENTAL)")
        self.orangepi4lts_only = QtWidgets.QCheckBox("ONLY the OPi 4 LTS (ORANGEPI4LTS_ONLY=1)")
        for w in (self.frite, self.frite_only, self.jetson, self.jetson_only,
                  self.orangepi5, self.orangepi5_only,
                  self.orangepizero2, self.orangepizero2_only,
                  self.orangepizero2w, self.orangepizero2w_only,
                  self.orangepizero3, self.orangepizero3_only,
                  self.orangepi3lts, self.orangepi3lts_only,
                  self.orangepi4lts, self.orangepi4lts_only):
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
        self.orangepizero2w_group = QtWidgets.QGroupBox("Orange Pi Zero 2W")
        ozwl = QtWidgets.QVBoxLayout(self.orangepizero2w_group)
        self.orangepizero2w_flavor = _default_combo(ORANGEPIZERO2W_FLAVORS)
        ozwl.addWidget(_row("OPZ2W flavor", self.orangepizero2w_flavor))
        l2.addWidget(self.orangepizero2w_group)
        self.orangepizero3_group = QtWidgets.QGroupBox("Orange Pi Zero 3")
        oz3l = QtWidgets.QVBoxLayout(self.orangepizero3_group)
        self.orangepizero3_flavor = _default_combo(ORANGEPIZERO3_FLAVORS)
        oz3l.addWidget(_row("OPZ3 flavor", self.orangepizero3_flavor))
        l2.addWidget(self.orangepizero3_group)
        self.orangepi3lts_group = QtWidgets.QGroupBox("Orange Pi 3 LTS")
        o3ll = QtWidgets.QVBoxLayout(self.orangepi3lts_group)
        self.orangepi3lts_flavor = _default_combo(ORANGEPI3LTS_FLAVORS)
        o3ll.addWidget(_row("OPi3-LTS flavor", self.orangepi3lts_flavor))
        l2.addWidget(self.orangepi3lts_group)
        self.orangepi4lts_group = QtWidgets.QGroupBox("Orange Pi 4 LTS")
        o4ll = QtWidgets.QVBoxLayout(self.orangepi4lts_group)
        self.orangepi4lts_flavor = _default_combo(ORANGEPI4LTS_FLAVORS)
        o4ll.addWidget(_row("OPi4-LTS flavor", self.orangepi4lts_flavor))
        l2.addWidget(self.orangepi4lts_group)
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
        # The superbrand drop-down (#654, D8): the same widget the image route's Branding
        # page and the Docker route's brand step host, over the same session. A profile
        # chosen here fills the Brand profile field below it (one store); ‘Create a new
        # superbrand’ opens the design on the next step.
        self.brand_picker = BrandPicker()
        sl.addWidget(self.brand_picker)
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
            "brand mesh control server (HEADSCALE_URL env — baked to /etc/hugmesh/headscale-url)")
        sl.addWidget(_row("Headscale URL", self.headscale_url))
        self.output_dir = QtWidgets.QLineEdit()
        od_btn = _file_picker(self, self.output_dir, "Output directory", directory=True)
        od = QtWidgets.QWidget(); oh = QtWidgets.QHBoxLayout(od); oh.setContentsMargins(0, 0, 0, 0)
        oh.addWidget(self.output_dir, 1); oh.addWidget(od_btn)
        # ISSUE #231 vocabulary: one spelling per role across the GUI. This page
        # already said "Output directory" in its own file-dialog caption one line
        # up and "Output dir" on the row — the same field, two names.
        sl.addWidget(_row("Output directory", od))
        self.jobs = QtWidgets.QSpinBox(); self.jobs.setRange(1, 128); self.jobs.setValue(8)
        sl.addWidget(_row("Jobs", self.jobs))
        self.backend = QtWidgets.QComboBox(); self.backend.addItems(["auto", "native", "docker"])
        sl.addWidget(_row("Backend", self.backend))
        self.extra_flags = QtWidgets.QLineEdit()
        self.extra_flags.setPlaceholderText("extra pass-through builder flags, appended verbatim")
        sl.addWidget(_row("Extra flags", self.extra_flags))
        l3.addWidget(shared)
        # NODE SERVICES (#579 item 3's GUI half, #587): FleetConfig has carried these
        # since #600 but this page never collected them, so a RESTART of a WITH_TOR=1
        # fleet session silently rebuilt WITHOUT Tor (apply() had nowhere to put it).
        node_svcs = QtWidgets.QGroupBox("Node services (every cluster-node image of the run)")
        nl = QtWidgets.QVBoxLayout(node_svcs)
        # A QCheckBox cannot wrap: its minimum width IS its text, and this one's was 765 px
        # in a 722 px viewport — the whole window scrolled 103 px sideways on every step
        # (measured 2026-10-01, and again here at 760x700). The box keeps its short name;
        # the long explanation is a wrapped line under it.
        self.with_tor = QtWidgets.QCheckBox(
            "Tor v3 onion on every cluster-node image (WITH_TOR=1)")
        nl.addWidget(self.with_tor)
        self.with_tor_note = QtWidgets.QLabel(
            "x86 gets --with-tor and rpi5 gets 'tor' folded into --optional-services; "
            "client roles never carry it.")
        self.with_tor_note.setWordWrap(True)
        self.with_tor_note.setStyleSheet("color: gray;")
        nl.addWidget(self.with_tor_note)
        self.optional_services = QtWidgets.QLineEdit()
        self.optional_services.setPlaceholderText(
            "OPTIONAL_SERVICES env for both node builders, space-separated "
            "(empty = each builder's default)")
        nl.addWidget(_row("Optional services", self.optional_services))
        l3.addWidget(node_svcs)
        l3.addStretch(1)
        self.stack.addWidget(p3)

        # ── step 4: SUPERBRAND — the design the drop-down's ‘Create a new superbrand’ opens ──
        # SCROLLS like every tall step of this window: the look editor is long, and at
        # the window's 760x700 a plain layout clipped it (#647, looked at).
        p_brand = QtWidgets.QWidget(); lb = scrollable(p_brand)
        self.brand_help = QtWidgets.QLabel(
            "The superbrand is the mesh's one governing brand: its name, its look and "
            "how it is reached are what every brand under it starts from. Choose it "
            "from the drop-down on the previous step; ‘Create a new superbrand’ opens "
            "the design here.")
        self.brand_help.setWordWrap(True)
        self.brand_help.setStyleSheet("color: gray;")
        lb.addWidget(self.brand_help)
        self.superbrand_step = SuperbrandStep(route="fleet", with_picker=False)
        lb.addWidget(self.superbrand_step)
        lb.addStretch(1)
        self.stack.addWidget(p_brand)
        self.brand_picker.designing_changed.connect(self.superbrand_step.refresh)
        self.superbrand_step.picker.designing_changed.connect(self.brand_picker.refresh)

        # ── step 5: DOMAINS — the shared table, row 0 = this fleet's own domain ──
        p_dom = QtWidgets.QWidget(); ld = QtWidgets.QVBoxLayout(p_dom)
        self.domains_help = QtWidgets.QLabel(
            "Every domain this fleet's mesh serves. Row 0 is its OWN domain — the "
            "Cluster domain from the previous step, or the builders' default when that "
            "is empty — and cannot be removed. Add every OTHER domain below. Each one "
            "gets its own page on the next step, and the build refuses while any "
            "domain here has never been through it, naming the domain.")
        self.domains_help.setWordWrap(True)
        self.domains_help.setStyleSheet("color: gray;")
        ld.addWidget(self.domains_help)
        self.domains_table = DomainsTableWidget(
            cfg=lambda: self.fleet_domains, brand_session=lambda: self._brand_session())
        # a fleet stands up no Casdoor: a per-domain "Own" sign-in would reach nothing
        self.domains_table.table.setColumnHidden(_COL_IDP, True)
        ld.addWidget(self.domains_table)
        # Inline, never a modal: why Next refused (a junk / duplicate / own-again row).
        self.domains_note = QtWidgets.QLabel("")
        self.domains_note.setWordWrap(True)
        self.domains_note.setStyleSheet("color: #c62828;")
        self.domains_note.setVisible(False)
        ld.addWidget(self.domains_note)
        self.stack.addWidget(p_dom)

        # ── step 6: DOMAIN SERVICES — one page per domain, own domain first ──
        # SCROLLS, like the image flow's page and the local docker mesh's step (#647,
        # looked at): the shared body is taller than this page at its default size —
        # two checkbox tables, the state line and the read-only table — and in a
        # plain layout the services table kept its minimum height while the widgets
        # under it were laid out over its lower rows (measured under Fusion, Breeze
        # and Oxygen: the front-door row painted across the third service group).
        p_svc = QtWidgets.QWidget(); lsv = scrollable(p_svc)
        self.domain_services = DomainServicesWidget(
            scope_cfg=None, entries=None, lane_note=FLEET_LANE_NOTE,
            brand_session=lambda: self._brand_session(), route="fleet")
        lsv.addWidget(self.domain_services)
        self.stack.addWidget(p_svc)

        # ── step 7: REVIEW — the exact command (unchanged emission) + preflight ──
        p4 = QtWidgets.QWidget(); l4 = QtWidgets.QVBoxLayout(p4)
        l4.addWidget(QtWidgets.QLabel("Command:"))
        self.cmd = console.attach(QtWidgets.QPlainTextEdit()); self.cmd.setReadOnly(True); self.cmd.setMaximumHeight(100)
        l4.addWidget(self.cmd)
        self.preview_btn = QtWidgets.QPushButton("Refresh preview")
        self.preview_btn.clicked.connect(self.refresh_preview)
        pb_row = QtWidgets.QHBoxLayout(); pb_row.addWidget(self.preview_btn); pb_row.addStretch(1)
        l4.addLayout(pb_row)
        self.problems = console.attach(QtWidgets.QPlainTextEdit()); self.problems.setReadOnly(True)
        l4.addWidget(self.problems, 1)
        self.stack.addWidget(p4)

        # ── step 8: RUN — live progress + Stop ──
        p5 = QtWidgets.QWidget(); l5 = QtWidgets.QVBoxLayout(p5)
        self.stop_btn = QtWidgets.QPushButton("Stop"); self.stop_btn.setEnabled(False)
        self.stop_btn.clicked.connect(self._stop)
        st_row = QtWidgets.QHBoxLayout(); st_row.addWidget(self.stop_btn); st_row.addStretch(1)
        l5.addLayout(st_row)
        self.log = console.attach(QtWidgets.QPlainTextEdit()); self.log.setReadOnly(True)
        # BOUNDED DOCUMENT — see _LOG_MAX_BLOCKS. An all-roles fan-out streams for hours
        # and every appended block stays in the QTextDocument forever otherwise.
        self.log.setMaximumBlockCount(_LOG_MAX_BLOCKS)
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
                   self.orangepizero2w, self.orangepizero2w_only,
                   self.orangepizero3, self.orangepizero3_only,
                   self.orangepi3lts, self.orangepi3lts_only,
                   self.orangepi4lts, self.orangepi4lts_only,
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
            orangepizero2w=self.orangepizero2w.isChecked(),
            orangepizero2w_only=self.orangepizero2w_only.isChecked(),
            orangepizero2w_flavor=self.orangepizero2w_flavor.currentData(),
            orangepizero3=self.orangepizero3.isChecked(),
            orangepizero3_only=self.orangepizero3_only.isChecked(),
            orangepizero3_flavor=self.orangepizero3_flavor.currentData(),
            orangepi3lts=self.orangepi3lts.isChecked(),
            orangepi3lts_only=self.orangepi3lts_only.isChecked(),
            orangepi3lts_flavor=self.orangepi3lts_flavor.currentData(),
            orangepi4lts=self.orangepi4lts.isChecked(),
            orangepi4lts_only=self.orangepi4lts_only.isChecked(),
            orangepi4lts_flavor=self.orangepi4lts_flavor.currentData(),
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
            with_tor=self.with_tor.isChecked(),
            optional_services=self.optional_services.text().strip(),
            # COPIES (core.fleet.fleet_domain_fields — the TUI's review builds its
            # FleetConfig through the same call).
            **fleet_domain_fields(self.fleet_domains),
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
        self.orangepizero2w.setChecked(cfg.orangepizero2w)
        self.orangepizero2w_only.setChecked(cfg.orangepizero2w_only)
        combo(self.orangepizero2w_flavor, cfg.orangepizero2w_flavor)
        self.orangepizero3.setChecked(cfg.orangepizero3)
        self.orangepizero3_only.setChecked(cfg.orangepizero3_only)
        combo(self.orangepizero3_flavor, cfg.orangepizero3_flavor)
        self.orangepi3lts.setChecked(cfg.orangepi3lts)
        self.orangepi3lts_only.setChecked(cfg.orangepi3lts_only)
        combo(self.orangepi3lts_flavor, cfg.orangepi3lts_flavor)
        self.orangepi4lts.setChecked(cfg.orangepi4lts)
        self.orangepi4lts_only.setChecked(cfg.orangepi4lts_only)
        combo(self.orangepi4lts_flavor, cfg.orangepi4lts_flavor)
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
        self.with_tor.setChecked(cfg.with_tor)
        self.optional_services.setText(cfg.optional_services)
        # the RECORDED rows and markers, never "every row reviewed" — a record whose
        # walk was incomplete must still be refused at Review. A NEW state object on
        # purpose, and NOT pushed into the services widget here: its next load() sees
        # a different object and drops its working answers by itself, whereas a
        # load() now would SHOW (and so mark walked) a domain the operator is not
        # looking at — this runs on the way to Review, not on the services step.
        self.fleet_domains = fleet_domains_from_config(cfg)
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
        if i == STEP_SHARED:
            self._refresh_brand_widgets()
        elif i == STEP_BRAND:
            self._refresh_brand_widgets()
        elif i == STEP_DOMAINS:
            self._seed_domains()
            self.domains_table._refresh_summary_cells()
        elif i == STEP_DOMAIN_SERVICES:
            self.domain_services.load(self.fleet_domains)
        elif i == STEP_REVIEW:
            self._enter_review()
        self._update_nav()

    # ---- the superbrand drop-down and its design (#654, D8) ------------------------
    def _brand_session(self):
        """This window's superbrand session: the Cluster domain and Brand profile line
        edits and the Domains steps' state, behind the one model the image route and the
        text screens use. Rebuilt when the state object is replaced (``apply``)."""
        return session_for(self, "fleet", (self._brand_options, self.fleet_domains),
                           self.generator_dir)

    def _refresh_brand_widgets(self) -> None:
        session = self._brand_session()
        self.brand_picker.set_session(session)
        self.superbrand_step.set_session(session)

    # ---- the Domains / Domain services steps (#587) ----------------------------
    def _seed_domains(self) -> None:
        """Enter Domains: row 0 = the fleet's own domain (re-synced with the Cluster
        domain field on every entry), then fill the table from the state."""
        seed_fleet_domains(self.fleet_domains, self.cluster_domain.text())
        self.domains_table.fill(self.fleet_domains.domains, self.fleet_domains.own_name)
        self.domains_note.setVisible(False)

    def _commit_domains(self) -> bool:
        """Leave Domains: record the table's rows (always — a Back keeps them) and
        refuse Next, INLINE, on a row that cannot be a domain."""
        added, _ca = self.domains_table.rows()
        problems = commit_fleet_domains(self.fleet_domains, added)
        self.domains_note.setText(
            "\n".join(problems + ["Fix or remove these rows to continue."])
            if problems else "")
        self.domains_note.setVisible(bool(problems))
        return not problems

    def _leave(self, i: int) -> bool:
        """Record what the step being LEFT holds; False keeps the operator there."""
        if i == STEP_BRAND:
            self.superbrand_step.commit(save=False)
        if i == STEP_DOMAINS:
            return self._commit_domains()
        if i == STEP_DOMAIN_SERVICES:
            self.domain_services.record(self.fleet_domains)
            self.domain_services.commit_brand(save=True)
        return True

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
            # Back RECORDS too (never refuses): a row typed on Domains must reach the
            # state whichever way the operator leaves.
            self._leave(i)
            self._goto(i - 1)

    def _next(self) -> None:
        i = self.stack.currentIndex()
        if i == STEP_REVIEW:
            if self._start():
                self._goto(STEP_RUN)
        elif i < STEP_RUN:
            if self._leave(i):
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
        self.orangepizero2w_group.setVisible(
            self.orangepizero2w.isChecked() or self.orangepizero2w_only.isChecked())
        self.orangepizero3_group.setVisible(
            self.orangepizero3.isChecked() or self.orangepizero3_only.isChecked())
        self.orangepi3lts_group.setVisible(
            self.orangepi3lts.isChecked() or self.orangepi3lts_only.isChecked())
        self.orangepi4lts_group.setVisible(
            self.orangepi4lts.isChecked() or self.orangepi4lts_only.isChecked())
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
        self._line_inbox.clear()               # nothing from a previous run may leak in
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
        self._drain.start()                    # stopped in _done, after a final flush
        self.worker.start()
        self._update_nav()
        return True

    def _on_line(self, line: str) -> None:
        """Worker-signal slot. Deliberately does NOTHING but enqueue — see the coalescing
        note in __init__. Any real work here (a widget append, a write, a flush) runs once
        PER OUTPUT LINE on the GUI thread, which is what stalls the event loop."""
        self._line_inbox.append(line)

    def _drain_lines(self) -> None:
        """Deliver every line banked since the last tick: ONE pane append, ONE tee
        write + flush, and the error-tail ring updated per line (a pure deque append,
        no I/O). Order is preserved and nothing is dropped — the tee is still
        line-exact, so `tail -F` on <workdir>/fleet.log shows the same stream."""
        if not self._line_inbox:
            return
        # Snapshot and clear FIRST: the worker thread keeps emitting while this runs, and
        # draining in place would livelock on a fast producer.
        batch = [self._line_inbox.popleft() for _ in range(len(self._line_inbox))]
        blob = "\n".join(batch)
        console.write(self.log, blob)
        self._tail.extend(batch)
        if self._log_fh is not None:
            try:
                self._log_fh.write(blob + "\n")
                self._log_fh.flush()
            except OSError:
                pass

    def _stop(self):
        self._stop_requested = True
        self.driver.cancel()

    def _done(self, code):
        # FLUSH BEFORE SETTLING: up to one drain interval of output is still banked when
        # the run finishes, and those are exactly the lines that say HOW it finished —
        # closing the tee first would drop them from fleet.log, and settling the record
        # first would compute the error tail without them.
        self._drain_lines()
        self._drain.stop()          # an idle page owns no delivery clock
        self.stop_btn.setEnabled(False)
        console.write(self.log, f"\n[fleet] exited with code {code}")
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
        self.setWindowTitle("HugMesh fleet build (build-all-roles)")
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
    wizard is still a separate top-level window — non-modal, so the Sessions page,
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
    """The wizard's PreviousBuildsWidget (SessionsPage.previous_builds), or None."""
    for pid in (wiz.pageIds() if hasattr(wiz, "pageIds") else []):
        pb = getattr(wiz.page(pid), "previous_builds", None)
        if pb is not None:
            return pb
    return None

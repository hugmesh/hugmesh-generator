"""LocalMeshPage — the wizard page behind ModePage's fourth first-screen choice
("Local Docker mesh"). It runs a dockerized HugMesh mesh on THIS machine (no
image build, no server hardware) — IN the wizard flow, not a popout.

Formerly a modal ``LocalMeshDialog(QDialog).exec()`` launched from ModePage; the
operator rejected exactly that ("should follow the same gui wizard and not pop out
a new window"), so the surface is now a real registered QWizardPage:
  - ModePage's localmesh radio sets ``wiz.localmesh_selected`` (transient, NEVER in
    cfg — ModePage.initializePage documents why cfg.mode stays an IMAGE mode);
  - ``applies_to()`` reads that flag, so the page is dynamically skipped on every
    image-mode flow (it emits ZERO ImageConfig fields — the nextId() ALL-OPTIONS
    guard holds trivially);
  - the page is TERMINAL for its branch (``nextId() == -1`` + setFinalPage): after
    running a docker mesh there is no image to build. Back returns to ModePage; the
    stack lives in docker, not in the page, so navigation never disturbs it.

TWO mutually-exclusive paths, surfaced as tabs (unchanged from the dialog):
  - JOIN an existing mesh with a key — collect a tailnet/headscale auth key + node
    knobs into a LocalMeshConfig and drive LocalMeshNode start/stop/logs.
  - GENERATE & START a NEW local mesh FROM SCRATCH — mint ALL credentials + bring
    up the full platform stack seeded with a fresh superadmin, via LocalMeshBootstrap.
    Nothing runs until the operator acknowledges the read-only plan preview.

NEW on the bootstrap tab (the operator's other two asks):
  - BRAND — the GUI was strictly less capable than its own CLI: collect_bootstrap()
    never passed ``brand=``, pinning every GUI run to secret/hugmesh/ while
    ``--brand`` worked fine. The picker lists the real brands/ catalog
    (discover_brands) and stays editable; validate() DNS-label-gates the slug
    exactly as gen-keystores.sh does.
  - SOURCE — where the buildable repo files come from: download/update all repos
    into ./.stack-src (the default; exactly what `make stack-up` has always done,
    now VISIBLE), or an existing tree (STACK_SRC=<dir> + STACK_NO_CLONE=1 so the
    operator's checkouts are never fetched/updated/git-reset — clone-all-repos.sh's
    update path is a `git reset --hard`). The third option (render from templates)
    is a permanently DISABLED radio with the reason inline: it answers "why isn't
    rendering here?" in-product, and a disabled control can never lie.

All verbs (join start/stop, bootstrap up/down) run on a _MeshWorker QThread — the
golive _DriverWorker precedent. up() shells `make stack-up`, an hours-long docker
build on a cold box; on the GUI thread it froze the old dialog solid
(operator-reported). The long verbs additionally STREAM (on_line, cancel), so their
output arrives live and the whole process group can be cancelled; the remaining
buffered verbs state that caveat in the status text, never a faked progress bar.

STAGED VIEW (replaces the flat scrolling log the operator asked to remove): the
streamed lines drive core/progress_parse.ProgressParser + core/stage_tracker.StageTracker
over the ``localmesh-*`` phase tables in core/progress-tables.json (see
core/local_mesh_stages.py for which verb uses which). A QTreeWidget shows one row per
verb RUN with its stages nested underneath (label, state, elapsed), and the single log
pane below FOLLOWS the selection — a stage shows only its own captured slice, the run
row the full raw log. This is deliberately progress.py's implementation, imported rather
than re-created, down to the glyph palette. It stays honest by construction because
StageTracker owns the semantics: a stage goes green only once the run advanced PAST it,
a nonzero exit fails the RUNNING stage and leaves trailing ones pending, and a cancel
marks the running stage 'stopped' (neutral), never failed.

``LocalMeshDialog`` survives as a thin standalone-host shim wrapping the page
(``LocalMeshDialog(generator_dir).exec()`` still works, per its original promise).
"""
from __future__ import annotations

import os
import threading
import time
import types
from collections import deque

from ..qt import Qt, QtCore, QtGui, QtWidgets, Signal
from ..choice_cards import ChoiceCard, ChoiceCardGroup
from ..flow_layout import flow_box
from ...core import vaults
from ...core.config import IDP_CHOICES, IDP_LABELS, idp_effective_jwks
from ...core.egress_conf import validate_egress_conf
from ...core.local_mesh import LocalMeshConfig, LocalMeshNode
from ...core.local_mesh_bootstrap import (
    LocalMeshBootstrap, LocalMeshBootstrapConfig, _parse_web_locales,
    discover_brands)
from ...core.local_mesh_stages import verb_phases
from ...core.local_services import (
    UNAVAILABLE_LOCALLY, by_slug as local_service, default_selection,
    describe as local_describe, local_groups, local_slugs)
from ...core.progress_parse import ProgressParser
from ...core.seeded_credentials import load_roster
from ...core.stage_tracker import StageTracker
from ._credentials_dialog import CredentialsDialog
from ._add_user_dialog import AddUserDialog
from ._logintheme import LoginThemeGroup
from ._scroll import scrollable
from ._widgets import _row, collapsible, own_probe, probe_running
# The staged view is progress.py's, not a second one: importing its glyph palette and
# its two formatters is what keeps a stage rendered here byte-identical to the same
# stage rendered on the image-build screen. Re-declaring {"done": ("✓", "#188038"), …}
# would be exactly the duplicated catalogue the house rule forbids — and the first
# palette change would leave the two screens disagreeing about what green means.
# progress.py imports nothing from this module (the reverse dependency is via
# gui/pages/__init__), so this cannot cycle.
from .progress import _STAGE_GLYPH, _STATUS_GLYPH, _display_safe, _fmt_elapsed

# Per-provider placeholder hints — the SAME endpoint shapes gui/pages/idp.py
# carries (one picker, two frames: the node wizard page and this bootstrap tab).
_IDP_ISSUER_HINTS = {
    "entra": "https://login.microsoftonline.com/<tenant-id>/v2.0",
    "aws": "https://cognito-idp.<region>.amazonaws.com/<user-pool-id>",
    "oidc": "https://id.example.org (the token `iss` value, exactly)",
}

# ── the services table's column grid ────────────────────────────────────────────
# Symbolic indices (network.py's rule): a test names the column it reads instead of
# asserting on a magic number, and inserting a column stays one edit. MECH is this
# table's own column — the local mesh drives services through TWO unrelated
# back-ends, and which one a row uses decides whether ticking it restarts containers,
# so hiding that in prose would leave the operator guessing.
_LS_COL_NAME, _LS_COL_ON, _LS_COL_MECH, _LS_COL_DESC = range(4)
_LS_HEADERS = ("Service", "On", "How it is applied", "What enabling it does")


def _grey_note(text: str) -> "QtWidgets.QLabel":
    """The page's standing idiom for a wrapped, grey, explain-the-limit line (the
    source-coverage note, the IdP note) — one helper instead of a fourth copy."""
    lbl = QtWidgets.QLabel(text)
    lbl.setWordWrap(True)
    lbl.setStyleSheet("color: gray;")
    return lbl


_IDP_JWKS_HINTS = {
    "entra": "empty = <issuer>/discovery/v2.0/keys",
    "aws": "empty = <issuer>/.well-known/jwks.json",
    "oidc": "empty = <issuer>/.well-known/jwks",
}


class _StatusProbe(QtCore.QThread):
    """Ask the RUNNING stack what it is, off the GUI thread.

    `docker compose ps` shells out and can block for seconds (a busy or wedged
    daemon blocks for its whole timeout), so this must never run inline — that is
    the same class of bug as the per-line log delivery: work on the GUI thread
    with no way for the event loop to breathe. It runs on page entry, so doing it
    inline would freeze the window exactly when the operator first looks at it.

    Emits (running, detail). Never raises: LocalStackNode.status() already folds
    every failure into StackStatus(running=False, detail=<why>), which is the
    honest answer for "docker is not there" as much as for "nothing is up"."""
    result = Signal(bool, str)

    def __init__(self, node, parent=None):
        super().__init__(parent)
        self._node = node

    def run(self):
        try:
            st = self._node.status()
            self.result.emit(bool(st.running), str(st.detail or ""))
        except Exception as e:                      # never kill the page over a probe
            self.result.emit(False, f"{type(e).__name__}: {e}")


class _E2EGateProbe(QtCore.QThread):
    """Ask the RUNNING stack whether the e2e suite could run, off the GUI thread.

    LocalStackNode.e2e_ready() is THREE blocking `subprocess.run(..., timeout=30)` calls
    deep — `docker compose ps` (local_stack_node.py:872) and, when the stack is up,
    running_env()'s `compose ps -q` + `docker inspect` (local_stack_node.py:690 and :697)
    — plus a 5s urlopen probe of Casdoor. Run inline from initializePage (via
    _refresh_status -> _sync_e2e_gate) that is a potential ~95s freeze on merely ENTERING
    the page, on top of MeshNode.status()'s own 30s (mesh_node.py:135). A wedged docker
    daemon blocks each of those for its full timeout, and none of that work needs the GUI
    thread.

    Emits the problems list (empty = ready). Never raises: e2e_ready() already folds every
    probe failure into a human sentence, and an exception escaping run() would leave the
    button stuck in its 'checking…' state forever."""
    result = Signal(object)                     # list[str]

    def __init__(self, node, parent=None):
        super().__init__(parent)
        self._node = node

    def run(self):
        try:
            self.result.emit(list(self._node.e2e_ready()))
        except Exception as e:                  # never kill the page over a probe
            self.result.emit([f"the readiness probe failed: {type(e).__name__}: {e}"])


class _MeshWorker(QtCore.QThread):
    """Runs ONE mesh verb off the GUI thread. Hold a reference on the page
    (self.worker) — a local would be GC'd mid-run and take the thread with it.

    Two verb shapes:
      * buffered (the original): a zero-arg callable returning (ok, lines-or-msg) —
        the result lines are emitted when it finishes;
      * streaming: ``stream=True`` and the callable takes (on_line, cancel) — every
        line is emitted AS THE VERB RUNS (line.emit is thread-safe: a queued
        signal), and the returned lines are NOT re-emitted (they already streamed —
        re-dumping them doubled every milestone in the log)."""
    line = Signal(str)
    done = Signal(bool)

    def __init__(self, fn, parent=None, stream=False, cancel=None):
        super().__init__(parent)
        self._fn = fn
        self._stream = stream
        self.cancel = cancel

    def run(self):  # noqa: D102 — QThread contract
        try:
            if self._stream:
                ok, _out = self._fn(self.line.emit, self.cancel)
            else:
                ok, out = self._fn()
                for ln in (out if isinstance(out, (list, tuple)) else [out]):
                    if ln:
                        self.line.emit(str(ln))
        except Exception as e:  # a worker exception must NEVER abort the app
            self.line.emit(f"!! {type(e).__name__}: {e}")
            ok = False
        self.done.emit(bool(ok))


# Stage-tree column indices — SYMBOLIC ONLY (progress.py's rule: nothing may hardcode a
# column number, so inserting a column stays a one-line change).
_ST_COL_NAME, _ST_COL_STATE, _ST_COL_TIME = 0, 1, 2

#: Raw-log ring per run. A cold `make stack-up` prints far more than the ~4k lines an
#: image build's tree row keeps, and this page holds at most a handful of runs, so the
#: buffer is deliberately larger than progress.py's.
_RUN_LOG_MAXLEN = 20000

#: LIVE log-pane block cap, pinned to _RUN_LOG_MAXLEN on purpose.
#:
#: The QTextDocument grew without bound while a verb streamed: an hours-long cold
#: `make stack-up` is ~100k lines of compose/maven output, all of it appended and none of
#: it ever dropped, so repaints got steadily slower over the run. The cap loses nothing
#: recoverable — the drill-down reloads the pane from _StageRun.buffer (this same
#: maxlen) or from a stage slice (stage_tracker._STAGE_LOG_MAXLEN = 2000), so a line the
#: cap drops is one the buffer had already dropped.
_LOG_MAX_BLOCKS = _RUN_LOG_MAXLEN


class _StageRun:
    """One VERB run's stage bookkeeping — the local-mesh analogue of progress.py's
    ``_Row``, minus the image-build-only machinery (no progress bar, no emerge package
    ladder: `make stack-up` has no per-package stream).

    Each launched verb gets its own run, so the tree keeps the HISTORY of this session
    (readiness check, then m2, then the bring-up) instead of overwriting itself, and an
    earlier run's log stays reachable by clicking its row. ``phases`` may be empty — a
    verb whose shell prints no ``==> `` banners honestly gets zero stages rather than a
    fabricated ladder."""

    def __init__(self, label: str, phases: list[dict]):
        self.label = label
        # ONE table drives both: the parser turns a banner into a phase index, the
        # tracker turns the index rise into stage transitions. Two tables could
        # disagree; there is only one.
        self.parser = ProgressParser(phases=phases)
        self.tracker = StageTracker(phases)
        self.buffer: deque[str] = deque(maxlen=_RUN_LOG_MAXLEN)
        self.status = "running"          # _STATUS_GLYPH key: running/ok/failed/stopped
        self.t_start = time.monotonic()
        self.t_end: float | None = None
        # tree items (wired by LocalMeshPage._build_run_item)
        self.item: QtWidgets.QTreeWidgetItem | None = None
        self.stage_items: list[QtWidgets.QTreeWidgetItem] = []

    def elapsed(self, now: float) -> float:
        return max((self.t_end if self.t_end is not None else now) - self.t_start, 0.0)


class LocalMeshPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.generator_dir = wiz.generator_dir
        self.node = LocalMeshNode(self.generator_dir, LocalMeshConfig())
        self.boot = LocalMeshBootstrap(self.generator_dir, LocalMeshBootstrapConfig())
        self.worker: _MeshWorker | None = None
        # Users added via the Add-user verb THIS session, as seeder specs
        # ("name:ROLES:PW_ENV"). The FULL list rides every Add-user re-seed:
        # apply-systems-roles.sh writes EXACT role member sets, so a spec that
        # drops out of a later render loses its role memberships.
        self._added_user_specs: list[str] = []
        self._running = False
        self.setTitle("Local Docker mesh")
        self.setSubTitle("Run a HugMesh mesh on THIS machine in Docker — no image "
                         "build, no server hardware. This is the end of this path: "
                         "Finish closes the wizard; the mesh keeps running in Docker.")
        self.setFinalPage(True)

        # the bootstrap tab stacks ~15 rows + a plan preview — by far the tallest
        # page in the wizard (minimum ~670px). Wrap in the shared scroll area so a
        # tall page SCROLLS instead of growing the window (the _scroll.py contract;
        # Role/Network/Build/Home do the same) — without this, showing the page
        # grew the wizard ~50px and the jitter guard (#400) rightly failed.
        lay = scrollable(self)
        self.tabs = QtWidgets.QTabWidget()
        self.tabs.addTab(self._build_join_tab(), "Join an existing mesh with a key")
        self.tabs.addTab(self._build_bootstrap_tab(),
                         "Generate && start a NEW local mesh from scratch")
        lay.addWidget(self.tabs)

        # Shared status line + staged view (used by BOTH tabs).
        self.status = QtWidgets.QLabel("")
        self.status.setWordWrap(True)
        lay.addWidget(self.status)

        # ── STAGED VIEW: stage tree above, the SAME single log below ─────────────────
        # The flat scrolling log this replaces was the operator's complaint: an hour-long
        # cold bring-up is ~100k lines of compose/maven output with nothing to say WHERE
        # it is, and the one milestone that answers that ("==> Up. Front door:") scrolls
        # past in a second. progress.py already solved this for image builds, so this is
        # the same solution, not a second one: a tree of stages driven by
        # core/stage_tracker.StageTracker, and the log pane FILTERED to whatever is
        # selected — a stage shows only its own slice, the run row shows the raw log.
        #
        # self.log stays the same QPlainTextEdit object with the same parent for the
        # page's whole life (tests read page.log, and _on_line's append path must not
        # care which node is selected).
        self.stage_tree = QtWidgets.QTreeWidget()
        self.stage_tree.setColumnCount(3)
        self.stage_tree.setHeaderLabels(["Stage", "State", "Time"])
        self.stage_tree.setRootIsDecorated(True)
        self.stage_tree.setUniformRowHeights(True)
        self.stage_tree.setMinimumHeight(140)
        self.stage_tree.setColumnWidth(_ST_COL_NAME, 340)
        self.stage_tree.setColumnWidth(_ST_COL_STATE, 90)
        self.stage_tree.itemClicked.connect(self._on_stage_clicked)
        self.stage_hint = QtWidgets.QLabel(
            "No verb has run yet. Start one from the tab above and its stages appear "
            "here; click a stage to see only that stage's output in the log below.")
        self.stage_hint.setWordWrap(True)
        self.stage_hint.setStyleSheet("color: gray;")

        tree_pane = QtWidgets.QWidget()
        tree_lay = QtWidgets.QVBoxLayout(tree_pane)
        tree_lay.setContentsMargins(0, 0, 0, 0)
        tree_lay.addWidget(self.stage_tree, 1)
        tree_lay.addWidget(self.stage_hint)

        log_panel = QtWidgets.QWidget()
        log_lay = QtWidgets.QVBoxLayout(log_panel)
        log_lay.setContentsMargins(0, 0, 0, 0)
        # The header is the honesty label of the filtered pane: without it, a stage slice
        # and the full raw log look identical and the operator cannot tell which they are
        # reading (progress.py's log_header, same job).
        self.log_header = QtWidgets.QLabel("Log")
        self.log_header.setStyleSheet("font-weight: bold;")
        log_lay.addWidget(self.log_header)
        self.log = QtWidgets.QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMinimumHeight(0)      # so the log pane can be dragged fully shut
        # BOUNDED DOCUMENT — see _LOG_MAX_BLOCKS.
        self.log.setMaximumBlockCount(_LOG_MAX_BLOCKS)
        log_lay.addWidget(self.log, 1)

        # 2:1 with only the LOG collapsible — the tree can never be dragged shut, which
        # is what makes the splitter safe to hand the operator (progress.py's split).
        self.stage_splitter = QtWidgets.QSplitter(Qt.Orientation.Vertical)
        self.stage_splitter.addWidget(tree_pane)
        self.stage_splitter.addWidget(log_panel)
        self.stage_splitter.setStretchFactor(0, 2)
        self.stage_splitter.setStretchFactor(1, 1)
        self.stage_splitter.setCollapsible(0, False)
        self.stage_splitter.setCollapsible(1, True)
        lay.addWidget(self.stage_splitter, 1)

        # Run history + the drill-down selection. _selected_stage None = the run's raw
        # log; an int = that stage's slice (the ONLY thing that filters the live stream).
        self._runs: list[_StageRun] = []
        self._selected = -1
        self._selected_stage: int | None = None
        # Page-authored lines emitted BEFORE a verb starts ("[bootstrap] generating
        # credentials …", the WARNINGs): they belong to the run that is about to begin,
        # so _launch drains them into its buffer — otherwise selecting the run row would
        # silently drop the very lines that explain what it is doing.
        self._pending: list[str] = []
        # ONE 1 Hz clock (progress.py's rule: no second timer), running only while a verb
        # is, so an idle page costs nothing. It re-renders the RUNNING stage only.
        self._tick = QtCore.QTimer(self)
        self._tick.setInterval(1000)
        self._tick.timeout.connect(self._on_tick)

        # ── LINE COALESCING — why the window used to freeze ──────────────────
        # _MeshWorker emits ONE queued signal PER OUTPUT LINE, and the old slot
        # did the whole per-line pipeline inline: sanitise -> parse -> track ->
        # re-render the touched stage rows -> appendPlainText. That is fine for a
        # chatty verb and fatal for a torrential one. `make kind-up` (kind cluster
        # create + image pulls + ArgoCD rollouts) emits tens of thousands of lines
        # in bursts, so the GUI thread got tens of thousands of queued slot calls
        # each doing a widget repaint — the event loop never got back to painting
        # or input handling and the window went white/unresponsive (operator
        # report 2026-08-14: "starting the devops pipeline seemed to freeze the
        # window"). The verb itself was ALWAYS off-thread; it was the delivery
        # that blocked.
        #
        # Now the worker's signal does one cheap thing — append to this deque —
        # and a ~20 Hz drain does the pipeline for the whole batch, rendering and
        # appending ONCE per tick instead of once per line. Cost becomes O(ticks),
        # not O(lines), so the pane still looks live (50 ms is below the ~100 ms
        # threshold where a UI reads as laggy) while the event loop stays free.
        # Nothing is dropped: every line still reaches run.buffer and the parser,
        # just in batches.
        self._line_inbox: deque[str] = deque()
        self._drain = QtCore.QTimer(self)
        self._drain.setInterval(50)
        self._drain.timeout.connect(self._drain_lines)

        # Is a local mesh up RIGHT NOW? None until the first probe answers — a
        # tri-state on purpose, because "unknown" must not be treated as "no"
        # (that would grey the teardown buttons on every page entry for as long
        # as `docker compose ps` takes).
        self._mesh_up: bool | None = None

        # Run the gate ONCE now that every widget it touches exists: the operator
        # should see WHY 'Generate & start' is disabled before clicking it, not
        # only after toggling the checkbox.
        self._sync_boot_gate()

    # ── wizard-flow contract ─────────────────────────────────────────────────────

    def nextId(self) -> int:
        # Terminal branch: no image follows a docker mesh. HugMeshWizard.nextId's
        # skip walk is -1-safe (_dynamically_skipped returns False for nid < 0).
        return -1

    def applies_to(self, cfg) -> bool:  # noqa: ARG002 — the hook's fixed signature
        # localmesh is a WIZARD-transient choice, deliberately absent from cfg
        # (ModePage.initializePage: "cfg.mode is only ever an IMAGE mode"), so this
        # reads the wizard, not cfg. The page emits ZERO ImageConfig fields — it
        # drives LocalMeshBootstrapConfig, which never reaches builder argv — so the
        # ALL-OPTIONS skip guard holds trivially.
        return bool(getattr(self.wiz, "localmesh_selected", False))

    def isComplete(self) -> bool:
        # Finish stays disabled while a verb runs — leaving mid-up would orphan the
        # worker's signals into a destroyed page.
        return not self._running

    def initializePage(self):
        self._refresh_status()
        self._refresh_plan()
        # ENTERING THE PAGE MUST TELL YOU WHAT IS ALREADY RUNNING. The stage tree
        # only ever showed THIS session's runs, so after a Studio restart it was
        # empty and the page looked identical whether the mesh was up or down —
        # "Stop mesh" was enabled with nothing to stop, and "Generate && start"
        # invited a second bring-up over a live stack (operator report
        # 2026-08-14). Probe the real compose project instead of assuming.
        self._probe_mesh_state()

    # ── JOIN tab (handlers now threaded; widget names unchanged) ─────────────────
    def _build_join_tab(self) -> QtWidgets.QWidget:
        w = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(w)
        intro = QtWidgets.QLabel(
            "Join an EXISTING mesh: run a HugMesh mesh node on THIS machine in "
            "Docker — no separate server hardware and no image build. Provide a "
            "tailnet/headscale auth key; the dockerized node joins the mesh and serves "
            "locally.")
        intro.setWordWrap(True)
        lay.addWidget(intro)

        self.auth_key = QtWidgets.QLineEdit()
        self.auth_key.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.auth_key.setPlaceholderText("tskey-… (required — the tailnet/headscale auth key)")
        self.auth_key.setToolTip(
            "The pre-auth key the node's tailscale container joins with (staged as "
            "TS_AUTHKEY). Never saved to disk by this page beyond the local compose "
            "project's .env.")
        lay.addWidget(_row("Auth key", self.auth_key))

        self.node_name = QtWidgets.QLineEdit()
        self.node_name.setPlaceholderText("optional hostname on the tailnet (default: hugmesh-node)")
        lay.addWidget(_row("Node name", self.node_name))

        self.login_server = QtWidgets.QLineEdit()
        self.login_server.setPlaceholderText(
            "optional self-hosted headscale URL, e.g. https://headscale.example.com")
        self.login_server.setToolTip(
            "For a self-hosted headscale control plane — appended to TS_EXTRA_ARGS as "
            "--login-server=<url>. Leave empty to use Tailscale's default coordinator.")
        lay.addWidget(_row("Login server", self.login_server))

        btns = QtWidgets.QHBoxLayout()
        self.start_btn = QtWidgets.QPushButton("Start")
        self.stop_btn = QtWidgets.QPushButton("Stop")
        self.logs_btn = QtWidgets.QPushButton("View logs…")
        self.start_btn.clicked.connect(self._start)
        self.stop_btn.clicked.connect(self._stop)
        self.logs_btn.clicked.connect(self._logs)
        btns.addWidget(self.start_btn)
        btns.addWidget(self.stop_btn)
        btns.addWidget(self.logs_btn)
        btns.addStretch(1)
        lay.addLayout(btns)
        lay.addStretch(1)
        return w

    # ── BOOTSTRAP tab ────────────────────────────────────────────────────────────
    def _build_bootstrap_tab(self) -> QtWidgets.QWidget:
        w = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(w)
        intro = QtWidgets.QLabel(
            "Generate ALL credentials from scratch and start a NEW superadmin-"
            "controlled mesh on THIS machine: mint the Casdoor/DB/observability "
            "secrets + a fresh superadmin, bring up the full platform stack, and (in "
            "prod) attach the tailscale overlay. Nothing runs until you acknowledge "
            "the plan below.")
        intro.setWordWrap(True)
        lay.addWidget(intro)

        # ENV test/prod — ASK 14: two big clickable cards, not two radios. The
        # ChoiceCardGroup keeps the exact QButtonGroup surface (setChecked / isChecked /
        # checkedButton), so every existing caller and test reads it unchanged.
        # Deliberately NOT wired to advance_on_choice: this is one field on a long
        # configuration form, not a pick-one screen — "choosing is proceeding" would
        # mean picking an environment skipped the rest of the form.
        self.env_group = ChoiceCardGroup(self)
        self.env_test = ChoiceCard(
            "test",
            "LAN-only / offline. Self-signed material, no public domain, nothing "
            "published. The safe default.")
        self.env_prod = ChoiceCard(
            "prod",
            "A real public domain, with the tailscale overlay attached. Needs a "
            "domain and a key below.")
        self.env_group.add_card(self.env_test, 0)
        self.env_group.add_card(self.env_prod, 1)
        self.env_test.setChecked(True)
        envcol = QtWidgets.QVBoxLayout()
        envcol.addWidget(self.env_test)
        envcol.addWidget(self.env_prod)
        lay.addWidget(_row("Environment", self._wrap(envcol)))

        # BRAND — the real catalog + an editable slug. Fixes the GUI-narrower-than-
        # CLI bug: collect_bootstrap() used to omit brand=, pinning every GUI run to
        # secret/hugmesh/ and the wrong <brand>-pki superadmin lookup.
        self.brand = QtWidgets.QComboBox()
        self.brand.setEditable(True)
        self.brand.addItems(discover_brands(self.generator_dir))
        self.brand.setToolTip(
            "The Vault base path segment (secret/<brand>/) AND the profile selector "
            "(brands/<brand>.conf, sourced by gen-cluster-secrets.sh when present). "
            "Must be a DNS label — the same gate gen-keystores.sh applies.")
        lay.addWidget(_row("Brand", self.brand))
        self.brand_note = QtWidgets.QLabel("")
        self.brand_note.setWordWrap(True)
        self.brand_note.setStyleSheet("color: gray;")
        lay.addWidget(self.brand_note)

        # SOURCE — where the buildable repo files come from. Radio labels derive
        # their count from the compose file compose actually reads — never a
        # hardcoded "all repos" claim.
        src_box = QtWidgets.QGroupBox("Repo source (what the stack builds from)")
        sl = QtWidgets.QVBoxLayout(src_box)
        # ASK 14 — three cards, not three radios. The group keeps the QButtonGroup
        # surface, so src_clone/src_existing/src_render read exactly as before.
        n = len(self.boot.expected_contexts())
        self.src_group = ChoiceCardGroup(self)
        self.src_clone = ChoiceCard(
            f"Download the source for all {n} repos",
            "`make stack-clone` clones/updates each hugmesh-* repo from GIT_BASE into "
            "./.stack-src, then compose builds every service from those files. Needs "
            "network on the first run. [default]")
        self.src_group.add_card(self.src_clone, 0)
        self.src_clone.setChecked(True)
        sl.addWidget(self.src_clone)

        self.src_existing = ChoiceCard(
            "Build from a source tree I already have",
            "Point at a directory holding hugmesh-<name> checkouts; they are never "
            "fetched, updated or git-reset.")
        self.src_group.add_card(self.src_existing, 1)
        sl.addWidget(self.src_existing)
        row = QtWidgets.QHBoxLayout()
        self.src_dir = QtWidgets.QLineEdit()
        self.src_dir.setPlaceholderText("directory holding hugmesh-<name> checkouts")
        self.src_browse = QtWidgets.QPushButton("Browse…")
        self.src_browse.clicked.connect(self._browse_src)
        row.addWidget(self.src_dir, 1)
        row.addWidget(self.src_browse)
        sl.addLayout(row)
        self.src_coverage = QtWidgets.QLabel("")
        self.src_coverage.setWordWrap(True)
        self.src_coverage.setStyleSheet("color: gray;")
        sl.addWidget(self.src_coverage)
        guard = QtWidgets.QLabel(
            "Your checkouts are NEVER fetched, updated, or git-reset in this mode "
            "(STACK_NO_CLONE=1 skips the clone/update step entirely).")
        guard.setWordWrap(True)
        guard.setStyleSheet("color: gray;")
        sl.addWidget(guard)

        # The honest deferral: a DISABLED card can never lie. ChoiceCard renders a
        # disabled option with a DASHED border — a shape cue, not just grey text — so
        # "not available" reads without relying on colour.
        self.src_render = ChoiceCard(
            "Render repo source from templates",
            "Not available — see below.")
        self.src_group.add_card(self.src_render, 2)
        self.src_render.setEnabled(False)
        sl.addWidget(self.src_render)
        why = QtWidgets.QLabel(
            "scripts/render-tenant-set.sh needs `cd scripts/tooling && npm install` "
            "(node deps absent), and only 3 archetypes exist for the fleet — the Spring "
            "BFFs and gateways render to a placeholder README with no buildable source. "
            "Use 'Download the source' above: it produces real, buildable files for "
            "every repo.")
        why.setWordWrap(True)
        why.setStyleSheet("color: gray;")
        sl.addWidget(why)
        lay.addWidget(src_box)

        self.superadmin = QtWidgets.QLineEdit("superadmin")
        self.superadmin.setToolTip(
            "The platform superadmin login to mint. Its password is generated fresh "
            "and written ONLY to the offline secrets bundle — never shown here.")
        lay.addWidget(_row("Superadmin", self.superadmin))

        # ── SERVICES: which individual services this local mesh runs ─────────────
        # This page used to expose exactly two coarse toggles (social, tor), so every
        # service that ships DEFAULT-OFF in the federation registry — wiki, owncast,
        # tube, character-forge — was running-but-invisible with no UI to turn it on.
        # The surface is the node wizard's services-table idiom (network.py): grouped
        # rows + a slug->checkbox registry, because services are INDEPENDENT toggles
        # and a choice-card group would state a mutual exclusion that does not exist.
        # The catalogue, the grouping, the descriptions and the shipped defaults all
        # come from core (local_services / config) — this loop builds widgets only.
        svc_box = QtWidgets.QGroupBox("Services to run on this local mesh")
        svl = QtWidgets.QVBoxLayout(svc_box)
        svl.addWidget(_grey_note(
            "Two mechanisms you can tick, one list. COMPOSE PROFILE rows start or "
            "stop containers, so they take effect at bring-up and changing one later "
            "needs a stop + start. FEDERATION rows do not start anything — those "
            "containers are always up — they flip the service's federation_modules "
            "`enabled` row at seed time, which is what makes it appear in (or vanish "
            "from) the mesh menu. DEVOPS LANE rows are greyed and carry no checkbox: "
            "they are Kubernetes controllers this docker mesh cannot run at all, so "
            "they are listed for what they are and started by the DevOps buttons "
            "below. Anything the local docker stack has no mechanism for is greyed "
            "with the reason instead of offered as a toggle that would change "
            "nothing."))
        self.services_table = QtWidgets.QTreeWidget()
        self.services_table.setColumnCount(len(_LS_HEADERS))
        self.services_table.setHeaderLabels(list(_LS_HEADERS))
        self.services_table.setRootIsDecorated(True)
        self.services_table.setAlternatingRowColors(True)
        self.services_table.setUniformRowHeights(False)
        self.services_table.setSelectionMode(
            QtWidgets.QAbstractItemView.SelectionMode.NoSelection)
        # The page body already lives in a QScrollArea (scrollable(self)), which gives
        # a child tree zero height to negotiate for — without a floor the whole table
        # collapses to its header row.
        self.services_table.setMinimumHeight(300)
        _svc_hdr = self.services_table.header()
        _svc_hdr.setStretchLastSection(True)
        for _c in (_LS_COL_NAME, _LS_COL_ON, _LS_COL_MECH):
            _svc_hdr.setSectionResizeMode(
                _c, QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        svl.addWidget(self.services_table)

        # ONE row per slug, keyed by the slug core names it — deliberately NOT a
        # prettified display name, so a row here, the plan preview's checklist and the
        # federation_modules row can all be matched up by eye.
        self.service_boxes: dict[str, QtWidgets.QCheckBox] = {}
        self._svc_items: dict[str, QtWidgets.QTreeWidgetItem] = {}
        # The VPN conf backing the egress-vpn checkbox ("" = none picked yet).
        self._egress_vpn_conf = ""
        for _title, _slugs in local_groups():
            gitem = QtWidgets.QTreeWidgetItem(self.services_table)
            gitem.setText(_LS_COL_NAME, _title)
            _gf = gitem.font(_LS_COL_NAME)
            _gf.setBold(True)
            gitem.setFont(_LS_COL_NAME, _gf)
            gitem.setExpanded(True)
            for _slug in _slugs:
                item = QtWidgets.QTreeWidgetItem(gitem)
                item.setText(_LS_COL_NAME, _slug)
                self._svc_items[_slug] = item
                svc = local_service(_slug)
                if svc is None:
                    # Unavailable locally: the honest row — never a live checkbox
                    # over a mechanism that is absent. Copy is LAY-USER short
                    # (operator ask 2026-08-14): "Disabled" + the map's one plain
                    # sentence; the technical why lives beside the map entry.
                    why = UNAVAILABLE_LOCALLY[_slug]
                    item.setText(_LS_COL_MECH, "disabled")
                    item.setText(_LS_COL_DESC, f"Disabled — {why}")
                    item.setToolTip(_LS_COL_DESC, f"Disabled — {why}")
                    grey = QtGui.QBrush(QtGui.QColor("#888888"))
                    for _c in (_LS_COL_NAME, _LS_COL_MECH, _LS_COL_DESC):
                        item.setForeground(_c, grey)
                    continue
                # THREE mechanisms, so the label is derived by the module that owns
                # them (LocalService.mechanism_label) — this used to be a TWO-way
                # branch, which labelled both DevOps-lane rows "federation: " with an
                # empty module and then gave them a live checkbox that drove nothing.
                item.setText(_LS_COL_MECH, svc.mechanism_label())
                desc = local_describe(_slug)
                item.setText(_LS_COL_DESC, desc)
                item.setToolTip(_LS_COL_DESC, desc)
                if not svc.is_selectable():
                    # DEVOPS-LANE row: INFORMATIONAL, never a checkbox — the same
                    # honesty idiom as the unavailable rows above, except this one
                    # points at a lane that WORKS (the DevOps buttons below, which
                    # `describe` names). A checkbox here could only be inert: no
                    # compose profile and no federation row exists to flip.
                    grey = QtGui.QBrush(QtGui.QColor("#888888"))
                    for _c in (_LS_COL_NAME, _LS_COL_MECH, _LS_COL_DESC):
                        item.setForeground(_c, grey)
                    continue
                box = QtWidgets.QCheckBox()
                box.setToolTip(desc)
                # The SHIPPED state, not a guess: a box ticked for something the mesh
                # does not actually run (or unticked for something it does) is the
                # same lie either way.
                box.setChecked(_slug in default_selection())
                if _slug == "egress-vpn":
                    # This toggle needs a FILE to mean anything: a USER click pops
                    # the conf picker (`clicked` never fires for programmatic
                    # setChecked — the no-modal rule that keeps headless tests
                    # alive), and _enforce_egress_conf unchecks a conf-less box at
                    # every exit so it can never be LEFT checked while unusable.
                    box.clicked.connect(self._egress_vpn_clicked)
                self.services_table.setItemWidget(item, _LS_COL_ON, box)
                self.service_boxes[_slug] = box
        # The two profile switches keep their historical attribute names because they
        # ARE the config's social/with_tor fields and the whole page (plan preview,
        # collect_bootstrap, the Tor buttons, the tests) refers to them by those names.
        # Aliases of the very same widget — never a second checkbox that could disagree
        # with its row, which is exactly the "one service, two spellings" bug the node
        # wizard's services table was rebuilt to kill.
        self.social = self.service_boxes["tuwunel"]
        self.with_tor = self.service_boxes["tor"]
        # egress-vpn status line: which conf backs the checkbox, or why it was
        # unchecked. Inline, never a message box (no-modal rule).
        self.egress_note = QtWidgets.QLabel("")
        self.egress_note.setWordWrap(True)
        self.egress_note.setVisible(False)
        svl.addWidget(self.egress_note)
        lay.addWidget(svc_box)

        # Web login languages. NOT a desktop-theming knob (those are x86-only and
        # skipped in mesh mode) — the web login is served to browsers BY the mesh,
        # so this is a cluster-plane fact and belongs here, on the config that
        # brings up the stack that builds the login-ui image. EMPTY = English-only
        # (the source language; smallest artifact; zero catalog requests).
        self.web_locales = QtWidgets.QLineEdit()
        self.web_locales.setPlaceholderText("English only — e.g. de, fr, pt-BR to add catalogs")
        self.web_locales.setToolTip(
            "Translation catalogs the web login IMAGE ships (comma-separated locale "
            "tags). English is the source language and always works with no catalog, "
            "so leaving this empty ships the smallest image and issues zero catalog "
            "requests. A locale here must have a catalog in the login-ui repo, or the "
            "login-ui image build fails loudly.")
        lay.addWidget(_row("Web login languages", self.web_locales))

        # Web login THEME — the same shared group BrandingPage hosts (one
        # implementation, two frames): this flow is terminal at this page, so
        # BrandingPage is unreachable from it. Collapsed: a from-scratch bring-up
        # usually starts with the shipped brand.
        self.login_theme = LoginThemeGroup()
        lay.addWidget(collapsible("Web login theme (colours + fonts)",
                                  self.login_theme, expanded=False))

        # IDENTITY PROVIDER (I6.6) — the SAME picker the node wizard's IdP page
        # carries. Casdoor (built-in) is the default and threads NOTHING; an
        # external provider threads OIDC_ISSUER/OIDC_CLIENT_ID/OIDC_JWKS_URI into
        # the stack env (validation-only in the local TEST stack — the honest note
        # below and the plan preview both say so).
        self.idp_box = QtWidgets.QGroupBox("Identity provider")
        ib = QtWidgets.QVBoxLayout(self.idp_box)
        self.idp = QtWidgets.QComboBox()
        for idp_id in IDP_CHOICES:
            self.idp.addItem(IDP_LABELS[idp_id], idp_id)
        self.idp.setToolTip(
            "Casdoor (built-in) is the native default — zero configuration, "
            "byte-identical stack env. External providers thread the provider-"
            "neutral OIDC_* env vars into `make stack-up`.")
        ib.addWidget(_row("Provider", self.idp))
        self.idp_issuer = QtWidgets.QLineEdit()
        self.idp_issuer.setToolTip("External OIDC issuer URL (https://…) — must "
                                   "byte-match the token `iss` claim.")
        ib.addWidget(_row("Issuer URL", self.idp_issuer))
        self.idp_client_id = QtWidgets.QLineEdit()
        self.idp_client_id.setPlaceholderText("the provider's client id (public — never a secret)")
        ib.addWidget(_row("Client ID", self.idp_client_id))
        self.idp_jwks = QtWidgets.QLineEdit()
        self.idp_jwks.setToolTip("Optional JWKS URL override; empty derives the "
                                 "provider's documented default from the issuer.")
        ib.addWidget(_row("JWKS URL", self.idp_jwks))
        self.idp_note = QtWidgets.QLabel(
            "HONEST LIMIT: the local compose stack pins its own two-issuer Casdoor "
            "split, so an external IdP here is VALIDATION-ONLY config (threaded as "
            "OIDC_ISSUER/OIDC_CLIENT_ID/OIDC_JWKS_URI env). Native login, MFA "
            "step-up and roles stay Casdoor-only — see docs/IDENTITY-PROVIDERS.md.")
        self.idp_note.setWordWrap(True)
        self.idp_note.setStyleSheet("color: gray;")
        ib.addWidget(self.idp_note)
        lay.addWidget(collapsible("Identity provider (Casdoor built-in / external OIDC)",
                                  self.idp_box, expanded=False))

        # prod-only overlay group.
        self.prod_group = QtWidgets.QGroupBox("Mesh overlay (prod only)")
        pg = QtWidgets.QVBoxLayout(self.prod_group)
        self.boot_domain = QtWidgets.QLineEdit()
        self.boot_domain.setPlaceholderText("public apex domain, e.g. example.com (required in prod)")
        pg.addWidget(_row("Domain", self.boot_domain))
        self.boot_auth_key = QtWidgets.QLineEdit()
        self.boot_auth_key.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.boot_auth_key.setPlaceholderText("tskey-… (required in prod — attaches the overlay)")
        pg.addWidget(_row("Auth key", self.boot_auth_key))
        self.boot_login_server = QtWidgets.QLineEdit()
        self.boot_login_server.setPlaceholderText("optional self-hosted headscale URL")
        pg.addWidget(_row("Login server", self.boot_login_server))
        lay.addWidget(self.prod_group)

        # Plan preview (read-only) — the confirm-before-run surface.
        lay.addWidget(QtWidgets.QLabel("Plan preview (what will be generated + started):"))
        self.plan_view = QtWidgets.QPlainTextEdit()
        self.plan_view.setReadOnly(True)
        self.plan_view.setLineWrapMode(QtWidgets.QPlainTextEdit.LineWrapMode.NoWrap)
        f = self.plan_view.font()
        f.setStyleHint(f.StyleHint.Monospace)
        f.setFamily("monospace")
        self.plan_view.setFont(f)
        lay.addWidget(self.plan_view, 1)

        # What is ALREADY up, answered on page entry by the off-thread probe. This
        # is the first thing to read after a Studio restart: the stage tree below
        # only ever shows THIS session's runs, so without this the page looks
        # identical whether the mesh is live or absent.
        self._mesh_state_label = QtWidgets.QLabel("Mesh state: checking…")
        self._mesh_state_label.setWordWrap(True)
        self._mesh_state_label.setToolTip(
            "Whether a local mesh is running right now, read from the actual "
            "compose project (not from anything this session did). Re-checked "
            "when you enter this page and after every verb finishes.")
        lay.addWidget(self._mesh_state_label)

        self.ack = QtWidgets.QCheckBox(
            "I understand this will MINT credentials and START containers on this machine.")
        lay.addWidget(self.ack)

        # A WRAPPING block, not a row. These fourteen actions in a QHBoxLayout
        # made the page's minimum width the SUM of all fourteen buttons — wider
        # than a laptop screen, so everything past "Generate && start" drifted
        # off the right edge with no way to resize or scroll to it (operator
        # report 2026-08-14). FlowLayout reports a ONE-BUTTON minimum and wraps
        # onto as many rows as the window is narrow enough to need.
        brow_box, brow = flow_box("Actions")
        self.boot_start_btn = QtWidgets.QPushButton("Generate && start")
        self.boot_down_btn = QtWidgets.QPushButton("Stop mesh")
        self.boot_start_btn.clicked.connect(self._bootstrap_up)
        self.boot_down_btn.clicked.connect(self._bootstrap_down)
        self.boot_down_btn.setToolTip(
            "`make stack-down` + stop the mesh overlay: every container goes away "
            "and the stack's data volumes are dropped. The IMAGES stay, so the next "
            "start is a warm (fast) bring-up.")
        brow.addWidget(self.boot_start_btn)
        brow.addWidget(self.boot_down_btn)
        # Disk reclamation, separated from Stop on purpose: stopping is routine,
        # deleting ~28 built images is not, and conflating them would make a warm
        # restart cost an hour-long rebuild.
        self.boot_clean_btn = QtWidgets.QPushButton("Stop && clean Docker…")
        self.boot_clean_btn.setToolTip(
            "`make stack-clean`: stops everything, drops the volumes AND removes the "
            "images this stack BUILT, plus the private-maven registry container and "
            "its cache. Pulled base images (postgres/cassandra/mastodon/…) are kept, "
            "and no `docker system prune` is ever run — nothing outside the local "
            "mesh is touched. The next start is a COLD build (hours). Asks first.")
        self.boot_clean_btn.clicked.connect(self._bootstrap_clean)
        brow.addWidget(self.boot_clean_btn)
        # Host readiness WITHOUT committing to anything: the same preflight `up`
        # runs (docker daemon, buildx-in-env, disk headroom, maven prerequisites),
        # surfaced on demand so problems appear BEFORE the operator acknowledges.
        self.preflight_btn = QtWidgets.QPushButton("Check readiness")
        self.preflight_btn.setToolTip(
            "Read-only host probes — docker daemon, buildx visibility in the exact "
            "build env, disk headroom under the docker data-root, and (for a cold "
            "build) the local maven registry. Nothing is generated or started.")
        self.preflight_btn.clicked.connect(self._check_readiness)
        brow.addWidget(self.preflight_btn)
        # The cold-build prerequisite preflight names — runnable HERE so a
        # from-scratch bring-up never needs a terminal detour.
        self.m2_btn = QtWidgets.QPushButton("Build maven prereqs (m2)")
        self.m2_btn.setToolTip(
            "`make stack-m2-bootstrap`: builds the org-private systems.hugmesh "
            "maven artifacts FROM SOURCE and serves them from a local registry "
            "container — required once before the FIRST (cold) stack build; "
            "readiness tells you when. Streams below; long (Spring builds).")
        self.m2_btn.clicked.connect(self._m2_bootstrap)
        brow.addWidget(self.m2_btn)
        self.cancel_btn = QtWidgets.QPushButton("Cancel")
        self.cancel_btn.setToolTip("Terminate the running verb's whole process "
                                   "group (make + compose + docker builds).")
        self.cancel_btn.clicked.connect(self._cancel_clicked)
        self.cancel_btn.setVisible(False)
        brow.addWidget(self.cancel_btn)
        self.open_web_btn = QtWidgets.QPushButton("Open web UI")
        self.open_web_btn.setToolTip(
            "Open the running stack's front door (http://localhost:8088) in your "
            "browser. The same platform is also served over TLS at "
            "https://localhost:8488 (self-minted per-machine CA — import "
            "tests/stack/.tls-front/ca.crt or accept the browser warning). "
            "Does nothing destructive; if the stack is down the browser "
            "just shows a connection error.")
        self.open_web_btn.clicked.connect(self._open_web_ui)
        brow.addWidget(self.open_web_btn)
        self.copy_onion_btn = QtWidgets.QPushButton("Copy .onion address")
        self.copy_onion_btn.setToolTip(
            "Copy the local mesh's minted Tor .onion address to the clipboard (open "
            "it in Tor Browser — a normal browser cannot reach a .onion). Enabled "
            "only after a TOR=1 bring-up has published the address.")
        self.copy_onion_btn.clicked.connect(self._copy_onion)
        brow.addWidget(self.copy_onion_btn)
        self.creds_btn = QtWidgets.QPushButton("Sign-in credentials")
        self.creds_btn.setToolTip(
            "Show the accounts `make stack-seed` provisions (username, password, "
            "roles) with one-click copy — the answer to \"the login page is up, "
            "who do I log in AS?\". Read from the seeder itself, so it matches "
            "what was actually seeded. Deterministic throwaway TEST credentials "
            "for this local stack only.")
        self.creds_btn.clicked.connect(self._show_credentials)
        brow.addWidget(self.creds_btn)
        # Runs tests/e2e against the RUNNING stack. Enablement + tooltip are
        # owned by _sync_e2e_gate (test env + stack up + seeded — live probes,
        # never the form's un-applied selection).
        self.e2e_btn = QtWidgets.QPushButton("Run e2e suite")
        self.e2e_btn.setEnabled(False)
        self.e2e_btn.clicked.connect(self._run_e2e)
        brow.addWidget(self.e2e_btn)
        # ── vaults + managed volumes (operator ask 2026-08-14) ──────────────
        # Always enabled: unlike the verbs above, this opens a READ-FIRST view
        # whose own tabs report honestly when there is nothing to manage (no
        # docker daemon, or Vault absent because it is a DevOps-lane service).
        # Greying it on "mesh not running" would be worse — the volumes OUTLIVE
        # the containers, and a stopped mesh is exactly when an operator wants
        # to inspect or reclaim them.
        self.vaults_btn = QtWidgets.QPushButton("Vaults && volumes…")
        self.vaults_btn.setToolTip(
            "Manage this mesh's durable state: the compose project's managed "
            "volumes (size, which container holds each, and a guarded delete) "
            "and its Vault entries. Volumes are where the mesh's data actually "
            "lives — every BFF's postgres, cassandra, the uploads — so deleting "
            "one is permanent and no rebuild restores it. Vault runs on the "
            "DevOps (Kubernetes) lane, so on a docker-only mesh that tab tells "
            "you how to start it rather than showing an empty list.")
        self.vaults_btn.clicked.connect(self._open_vaults)
        brow.addWidget(self.vaults_btn)
        # ── the DEVOPS lane (Kubernetes) ────────────────────────────────────
        # ArgoCD + the workload console are k8s CONTROLLERS — no compose profile
        # can host them (core/local_services.MECH_KIND). These two buttons drive
        # the repo's real local Kubernetes lane (`make kind-up`, which installs
        # upstream ArgoCD and applies this mesh's app tree), so the DevOps
        # surface is genuinely reachable instead of permanently greyed
        # (operator ask 2026-08-14).
        self.devops_tools_btn = QtWidgets.QPushButton("Install DevOps prerequisites")
        self.devops_tools_btn.setToolTip(
            "Fetch the DevOps lane's missing CLIs (kind, kubectl) into this "
            "repo's out/tools/bin — USER-LOCAL: no sudo, nothing installed "
            "outside the repo, pinned versions, each binary SHA-256 verified "
            "against its published checksum before it is made executable. "
            "Delete that directory to undo. Runs only when you press this.")
        self.devops_tools_btn.clicked.connect(self._devops_install_tools)
        brow.addWidget(self.devops_tools_btn)
        self.devops_up_btn = QtWidgets.QPushButton("Start DevOps lane (Kubernetes)")
        self.devops_up_btn.setToolTip(
            "Create the local Kubernetes cluster and bootstrap the mesh on it: "
            "real upstream ArgoCD (GitOps), the app tree, Vault KV and the "
            "identity seed — the lane where ArgoCD and the workload console "
            "actually work. SEPARATE from the docker mesh above: starting it "
            "changes nothing about the running containers. LONG (image pulls + "
            "rollouts); output streams below and Cancel stays available. "
            "Requires `kind` and `kubectl` on PATH — you are told up front if "
            "either is missing.")
        self.devops_up_btn.clicked.connect(self._devops_up)
        brow.addWidget(self.devops_up_btn)
        self.devops_down_btn = QtWidgets.QPushButton("Delete DevOps lane")
        self.devops_down_btn.setToolTip(
            "Delete the local Kubernetes cluster. Destroys the DevOps lane ONLY "
            "— the docker mesh and every one of its volumes are untouched.")
        self.devops_down_btn.clicked.connect(self._devops_down)
        brow.addWidget(self.devops_down_btn)
        self.add_user_btn = QtWidgets.QPushButton("Add user…")
        self.add_user_btn.setToolTip(
            "Create a NEW named account on the RUNNING mesh (username, password, "
            "roles) by re-running the idempotent seeder with EXTRA_ROLE_USERS — "
            "the same machinery that seeds mesh-operator, including registration "
            "stage 2 and Matrix/Mastodon provisioning for the roles it holds. "
            "The stack must be up (the seeder says so plainly if it is not).")
        self.add_user_btn.clicked.connect(self._add_user)
        brow.addWidget(self.add_user_btn)
        # No trailing addStretch: a FlowLayout has no stretch concept, and a
        # spacer item would be wrapped as if it were another button.
        lay.addWidget(brow_box)

        # Live-refresh the plan + gate the start button on the acknowledgement.
        self.env_test.toggled.connect(self._refresh_plan)
        self.env_prod.toggled.connect(self._refresh_plan)
        self.brand.currentTextChanged.connect(self._refresh_plan)
        self.src_clone.toggled.connect(self._refresh_plan)
        self.src_existing.toggled.connect(self._refresh_plan)
        self.src_dir.textChanged.connect(self._refresh_plan)
        self.superadmin.textChanged.connect(self._refresh_plan)
        # EVERY services row, not just the two profile ones — the plan preview prints
        # the whole selection, so a row that did not refresh it would leave the
        # confirm-before-run manifest describing a mesh the operator no longer chose.
        # (self.social / self.with_tor ARE two of these boxes, so they are covered
        # here; connecting them again would just refresh the plan twice per click.)
        for _svc_box in self.service_boxes.values():
            _svc_box.toggled.connect(self._refresh_plan)
        self.web_locales.textChanged.connect(self._refresh_plan)
        self.login_theme.primary.textChanged.connect(self._refresh_plan)
        self.login_theme.secondary.textChanged.connect(self._refresh_plan)
        self.login_theme.font_preset.currentIndexChanged.connect(self._refresh_plan)
        self.login_theme.font_file.textChanged.connect(self._refresh_plan)
        self.idp.currentIndexChanged.connect(self._refresh_plan)
        self.idp_issuer.textChanged.connect(self._refresh_plan)
        self.idp_client_id.textChanged.connect(self._refresh_plan)
        self.idp_jwks.textChanged.connect(self._refresh_plan)
        self.boot_domain.textChanged.connect(self._refresh_plan)
        self.boot_auth_key.textChanged.connect(self._refresh_plan)
        self.boot_login_server.textChanged.connect(self._refresh_plan)
        self.ack.toggled.connect(self._sync_boot_gate)
        self._refresh_plan()
        return w

    @staticmethod
    def _wrap(inner_layout) -> QtWidgets.QWidget:
        holder = QtWidgets.QWidget()
        holder.setLayout(inner_layout)
        return holder

    def _browse_src(self):
        d = QtWidgets.QFileDialog.getExistingDirectory(
            self, "Source tree holding hugmesh-<name> checkouts", self.src_dir.text())
        if d:
            self.src_dir.setText(d)

    # ── config collection ────────────────────────────────────────────────────────
    def collect(self) -> LocalMeshConfig:
        """JOIN-tab widgets -> LocalMeshConfig."""
        return LocalMeshConfig(
            auth_key=self.auth_key.text().strip(),
            node_name=self.node_name.text().strip(),
            login_server=self.login_server.text().strip(),
        )

    # ── egress-vpn conf channel (operator ask 2026-08-14) ────────────────────────
    def _egress_vpn_clicked(self, checked: bool) -> None:
        """USER toggled the egress-vpn box (mouse/keyboard — `clicked` never fires
        for programmatic setChecked, so no dialog can hang a headless test).
        Checking demands a conf immediately; cancel/invalid mean the check does
        not stand."""
        if not checked:
            self._egress_vpn_conf = ""
            self.egress_note.setVisible(False)
            return
        path, _filter = QtWidgets.QFileDialog.getOpenFileName(
            self, "Pick your VPN provider's config file", "",
            "VPN configs (*.conf *.ovpn);;All files (*)")
        kind, err = validate_egress_conf(path)
        if err:
            self.service_boxes["egress-vpn"].setChecked(False)
            self._egress_vpn_conf = ""
            self.egress_note.setStyleSheet("color: #c62828;")
            self.egress_note.setText(f"Egress VPN stays off — {err}")
            self.egress_note.setVisible(True)
            self._refresh_plan()
            return
        self._egress_vpn_conf = path
        self.egress_note.setStyleSheet("color: gray;")
        self.egress_note.setText(
            f"Egress VPN config: {os.path.basename(path)} ({kind}).")
        self.egress_note.setVisible(True)
        # the box's `toggled` already refreshed the plan BEFORE this handler ran
        # (with no conf yet) — refresh again now the conf exists.
        self._refresh_plan()

    def _enforce_egress_conf(self) -> None:
        """The exit gate: the box may not be LEFT checked without a valid conf
        (the file may also have vanished since it was picked). Silent uncheck +
        inline note — never a dialog (this runs from hideEvent and collectors)."""
        box = self.service_boxes.get("egress-vpn")
        if box is None or not box.isChecked():
            return
        _kind, err = validate_egress_conf(self._egress_vpn_conf)
        if err:
            box.setChecked(False)
            self._egress_vpn_conf = ""
            self.egress_note.setStyleSheet("color: #c62828;")
            self.egress_note.setText(f"Egress VPN was turned OFF — {err}")
            self.egress_note.setVisible(True)

    def hideEvent(self, event) -> None:                       # noqa: N802 (Qt)
        self._enforce_egress_conf()
        super().hideEvent(event)

    def collect_services(self) -> tuple[str, ...]:
        """The ticked services, in the core catalogue's order (never widget order —
        the config, the plan checklist and the seeder env must all list them the same
        way). Always a tuple, never None: this page HAS a picker, so its selection is
        explicit even when it happens to equal the shipped defaults. Byte-identity on
        the untouched path is preserved by core instead — federation_env() exports
        nothing while the selection matches what the registry ships, and the two
        profile rows are the same two booleans this page always sent."""
        # NO enforcement here: every box's `toggled` refreshes the plan preview
        # through this method, so unchecking from here would revert a user's click
        # BEFORE its `clicked` handler could open the conf dialog. The pending
        # conf-less moment is covered by bootstrap.validate()'s blocking problem
        # (shown in the plan) and _enforce_egress_conf at the real exits.
        return tuple(s for s in local_slugs()
                     if self.service_boxes[s].isChecked())

    def collect_bootstrap(self) -> LocalMeshBootstrapConfig:
        """BOOTSTRAP-tab widgets -> LocalMeshBootstrapConfig — EVERY operator-visible
        control, so none can silently do nothing (the dead-default class: ``brand``
        was declared on the config but never passed here, making the GUI strictly
        less capable than the CLI's ``--brand``)."""
        return LocalMeshBootstrapConfig(
            env=("prod" if self.env_prod.isChecked() else "test"),
            superadmin_username=self.superadmin.text().strip() or "superadmin",
            # social/with_tor stay because they are what LocalStackNode turns into
            # SOCIAL=/TOR=; they read the SAME two widgets the services table hosts,
            # so they can never disagree with the selection below.
            social=self.social.isChecked(),
            with_tor=self.with_tor.isChecked(),
            services=self.collect_services(),
            egress_vpn_conf=self._egress_vpn_conf,
            cluster_domain=self.boot_domain.text().strip(),
            auth_key=self.boot_auth_key.text().strip(),
            login_server=self.boot_login_server.text().strip(),
            brand=self.brand.currentText().strip(),
            source_mode=("existing" if self.src_existing.isChecked() else "clone"),
            source_dir=self.src_dir.text().strip(),
            web_locales=_parse_web_locales(self.web_locales.text()),
            # "" on invalid input, with the reason in error_text() — the verb
            # handlers refuse to launch on it, so a typo can never silently ship
            # an unthemed stack the operator believed was themed.
            login_theme_css=self.login_theme.compose_css(),
            # I6.6 identity provider — casdoor default carries EMPTY endpoint
            # fields (byte-identical env); validate() fail-closes the combinations.
            idp=self.selected_idp(),
            idp_issuer=(self.idp_issuer.text().strip()
                        if self.selected_idp() != "casdoor" else ""),
            idp_client_id=(self.idp_client_id.text().strip()
                           if self.selected_idp() != "casdoor" else ""),
            idp_jwks=(self.idp_jwks.text().strip()
                      if self.selected_idp() != "casdoor" else ""),
        )

    def selected_idp(self) -> str:
        """The provider id behind the combo's current row (data role, never the
        display label — labels are free to change)."""
        return self.idp.currentData() or "casdoor"

    # ── worker plumbing (the no-freeze fix) ──────────────────────────────────────
    def _launch(self, label: str, fn, stream: bool = False,
                cancellable: bool = False, verb: str = ""):
        """Run one verb off the GUI thread; buttons + Finish re-arm on done.
        ``stream=True`` verbs take (on_line, cancel) and their output lands in the
        log LIVE (what makes an hour-long cold compose build watchable);
        ``cancellable`` arms the Cancel button, which terminates the verb's whole
        process group. Buffered verbs keep the honest old caveat: output arrives
        when the step finishes.

        ``verb`` names the phase table to stage this run against
        (core.local_mesh_stages.verb_phases). Omitted / unknown = no banners are
        published by that shell, so the run gets ZERO stages and its drill-down is
        simply the raw log — never an invented single-stage ladder."""
        if self._running:
            return
        self._running = True
        self._set_verbs_enabled(False)
        cancel = threading.Event() if cancellable else None
        if stream:
            self.status.setText(f"{label} — output streams below as it happens; the "
                                f"wizard stays responsive."
                                + (" Cancel stops the whole build."
                                   if cancellable else ""))
        else:
            self.status.setText(f"{label} — this can take several minutes; the wizard "
                                f"stays responsive. Output appears when the step "
                                f"finishes.")
        self.cancel_btn.setVisible(cancellable)
        self.cancel_btn.setEnabled(cancellable)
        run = _StageRun(label, verb_phases(verb))
        # the handler's own pre-flight lines are this run's first log lines
        run.buffer.extend(self._pending)
        self._pending.clear()
        self._runs.append(run)
        self._build_run_item(run)
        self._load_detail(len(self._runs) - 1, None)
        self.worker = _MeshWorker(fn, parent=self, stream=stream, cancel=cancel)
        # NOT appendPlainText: every line now goes through the parser/tracker first, so
        # the tree advances and the pane only shows what the SELECTED node covers.
        self.worker.line.connect(self._on_line)
        self.worker.done.connect(self._verb_done)
        self._tick.start()
        self._drain.start()     # stopped in _verb_done, after a final flush
        self.completeChanged.emit()
        self.worker.start()

    def _cancel_clicked(self):
        w = self.worker
        if w is not None and w.cancel is not None and self._running:
            w.cancel.set()
            self.cancel_btn.setEnabled(False)
            self.status.setText("Cancelling — terminating the build process group…")

    def _verb_done(self, ok: bool):
        self._running = False
        # FLUSH BEFORE SETTLING: up to one drain interval of output can still be
        # banked when the verb finishes, and those are exactly the lines that say
        # HOW it finished. Draining after _settle_run would file them under a run
        # already marked terminal; dropping them would lose the failure reason.
        self._drain_lines()
        self._drain.stop()         # same rule as the clock: an idle page owns no timer
        self._set_verbs_enabled(True)
        self.cancel_btn.setVisible(False)
        self.status.setText("Done." if ok else "FAILED (see log).")
        self._tick.stop()          # unconditionally: an idle page must own no clock
        self._settle_run(ok)
        self._refresh_status()
        # A verb is the one thing that CHANGES whether a mesh is up (start, stop,
        # clean), so re-read the real state rather than inferring it from the
        # verb's exit code — a partially-failed bring-up leaves containers behind
        # and "failed" would otherwise be recorded as "nothing is running".
        self._probe_mesh_state()
        self.completeChanged.emit()

    def _settle_run(self, ok: bool) -> None:
        """Terminal stage bookkeeping, in StageTracker's documented vocabulary — the
        exit code it wants is the one thing the GUI has to derive:

          ok                      -> 0    (running stage done, trailing stages skipped)
          cancelled by operator   -> None (running stage STOPPED, trailing left pending)
          anything else           -> 1    (running stage FAILED, trailing left pending)

        The cancel case must be distinguished BEFORE the failure case: a cancelled verb
        returns ok=False like a broken one, and painting a stage the operator themself
        stopped as a red ✗ failure is the exact dishonesty stage_tracker's docstring
        forbids."""
        if not self._runs:
            return
        run = self._runs[-1]
        w = self.worker
        cancelled = bool(w is not None and w.cancel is not None and w.cancel.is_set())
        code = 0 if ok else (None if cancelled else 1)
        now = time.monotonic()
        run.tracker.finalize(code, now)
        run.t_end = now
        run.status = "ok" if ok else ("stopped" if cancelled else "failed")
        for j in range(len(run.tracker.stages)):
            self._render_stage(run, j, now)
        self._render_run(run, now)
        # A failure's first question is "which step, and what did it say?" — answer it
        # by selecting the failed stage, so the log pane already holds that slice.
        failed = run.tracker.failed_index()
        if failed is not None:
            self._focus_stage(len(self._runs) - 1, failed)

    # ── staged view: tree building, rendering, drill-down ────────────────────────
    def _note(self, text: str, queue: bool = True) -> None:
        """A PAGE-authored log line (a warning, or the "here is what I am about to do"
        line a handler prints before launching). It is not worker output, so it never
        touches the parser — but it is queued for the run that is about to start, so the
        run's raw log begins with the sentence that explains it.

        ``queue=False`` for a note that announces NO run — the "you answered No"
        line of an abandoned confirmation. Queuing that one would leave it sitting in
        _pending until some unrelated later verb launched and adopted it, so the next
        run's raw log would open by reporting a cancellation that is not part of it."""
        if queue:
            self._pending.append(text)
        self.log.appendPlainText(text)

    def _build_run_item(self, run: _StageRun) -> None:
        """One top-level row per run, one child per phase-table row — created UP FRONT
        (all pending) rather than as stages are reached, so the operator can see the
        whole ladder, and what is still ahead, from the first second."""
        i = len(self._runs) - 1
        item = QtWidgets.QTreeWidgetItem(self.stage_tree)
        item.setData(_ST_COL_NAME, Qt.ItemDataRole.UserRole, (i, None))
        run.item = item
        for j in range(len(run.tracker.stages)):
            child = QtWidgets.QTreeWidgetItem(item)
            child.setData(_ST_COL_NAME, Qt.ItemDataRole.UserRole, (i, j))
            run.stage_items.append(child)
            self._render_stage(run, j, run.t_start)
        self._render_run(run, run.t_start)
        self.stage_tree.expandItem(item)
        self.stage_tree.setCurrentItem(item)
        self.stage_hint.setText(
            "Click a stage to show only that stage's output below; click the run row "
            "for the full raw log. A stage turns green only once the run has moved "
            "PAST it."
            if run.stage_items else
            f"{run.label}: this step publishes no stage banners, so it has no stages — "
            f"the row's drill-down is its raw log.")

    def _render_run(self, run: _StageRun, now: float) -> None:
        """The run row's glyph/state/elapsed. Uses progress.py's JOB palette (the run is
        this page's job) so a running/ok/failed/stopped row reads identically on both
        build screens."""
        if run.item is None:
            return
        sym, colour = _STATUS_GLYPH.get(run.status, ("○", "#888888"))
        run.item.setText(_ST_COL_NAME, f"{sym}  {run.label}")
        run.item.setForeground(_ST_COL_NAME,
                               QtGui.QBrush(QtGui.QColor(colour)))
        run.item.setText(_ST_COL_STATE, run.status)
        run.item.setText(_ST_COL_TIME, _fmt_elapsed(run.elapsed(now)))

    def _render_stage(self, run: _StageRun, j: int, now: float) -> None:
        """Reflect one stage's tracker state onto its tree item (glyph+label, the raw
        state word, elapsed). Called ONLY on a real transition, on the 1 Hz tick for the
        running stage, and once per stage at terminal settle — never per line, which is
        what keeps a 100k-line bring-up cheap to render."""
        st = run.tracker.stages[j]
        item = run.stage_items[j]
        sym, colour = _STAGE_GLYPH.get(st.state, ("○", "#888888"))
        item.setText(_ST_COL_NAME, f"{sym}  {st.label}")
        item.setForeground(_ST_COL_NAME, QtGui.QBrush(QtGui.QColor(colour)))
        item.setText(_ST_COL_STATE, st.state)
        item.setText(_ST_COL_TIME, _fmt_elapsed(st.elapsed(now)))

    def _on_line(self, raw_line: str) -> None:
        """Worker-signal slot. Deliberately does NOTHING but enqueue — see the
        coalescing note where ``_drain`` is constructed. Any real work here runs
        once PER OUTPUT LINE on the GUI thread, which is what froze the window."""
        self._line_inbox.append(raw_line)

    def _drain_lines(self) -> None:
        """Process every line banked since the last tick: sanitise -> raw buffer ->
        parser -> tracker for each, then render the touched stages and append to
        the pane ONCE for the whole batch.

        The per-line half (parse/track/buffer) still runs for every line — it is
        pure CPU and cheap. The expensive half (stage re-render, appendPlainText)
        is what gets batched, because those repaint."""
        if not self._line_inbox:
            return
        # Snapshot and clear FIRST: the worker thread keeps appending while this
        # runs, and draining in place would livelock on a fast producer.
        batch = [self._line_inbox.popleft() for _ in range(len(self._line_inbox))]

        # Compose/maven colour their output unconditionally and portage-style
        # progress bars carry CR; Qt paints a BOX for every escape byte it cannot
        # render.
        if not self._runs:                       # lines with no run (defensive)
            self.log.appendPlainText("\n".join(_display_safe(ln) for ln in batch))
            return

        i = len(self._runs) - 1
        run = self._runs[i]
        now = time.monotonic()
        touched: set[int] = set()
        visible: list[str] = []
        for raw_line in batch:
            line = _display_safe(raw_line)
            run.buffer.append(line)
            state = run.parser.feed(line)
            delta = run.tracker.feed(line, state.phase_index, now)
            if delta.any():
                touched.update(delta.touched())
            # THE filtering rule (unchanged): the live stream lands in the pane only
            # when the selected node actually contains it — the whole run (stage
            # None), or the stage that is running right now. Selecting an older
            # stage freezes the pane on that slice. Evaluated PER LINE because
            # tracker.cur can move partway through a batch.
            if i == self._selected and (self._selected_stage is None
                                        or run.tracker.cur == self._selected_stage):
                visible.append(line)
        if touched:
            for j in sorted(touched):
                self._render_stage(run, j, now)
            self._render_run(run, now)
        if visible:
            self.log.appendPlainText("\n".join(visible))

    def _on_tick(self) -> None:
        """1 Hz: make the live run and its ONE running stage tick their elapsed time."""
        if not self._runs:
            return
        run = self._runs[-1]
        if run.t_end is not None:
            return
        now = time.monotonic()
        self._render_run(run, now)
        if run.tracker.cur >= 0:
            self._render_stage(run, run.tracker.cur, now)

    def _on_stage_clicked(self, item, _col: int = 0) -> None:
        data = item.data(_ST_COL_NAME, Qt.ItemDataRole.UserRole)
        if not data:
            return
        i, j = data                     # RUN row = (i, None); STAGE row = (i, int)
        self._load_detail(i, j)

    def _load_detail(self, i: int, stage_j: int | None) -> None:
        """Load the selected node into the shared pane: a RUN shows its full raw log, a
        STAGE only the slice StageTracker captured for it. The pane is the same widget
        either way — the header says which, because a slice and a full log are otherwise
        indistinguishable."""
        if not (0 <= i < len(self._runs)):
            return
        run = self._runs[i]
        self._selected = i
        self._selected_stage = stage_j
        if stage_j is None:
            self.log.setPlainText("\n".join(run.buffer))
            self.log_header.setText(f"Log — {run.label}")
        else:
            st = run.tracker.stages[stage_j]
            self.log.setPlainText("\n".join(st.lines))
            self.log_header.setText(f"Log — {run.label} ▸ {st.label}")

    def _focus_stage(self, i: int, stage_j: int) -> None:
        """Select a stage programmatically (failure navigation). setCurrentItem does NOT
        re-fire itemClicked, so the load has to be called explicitly."""
        if not (0 <= i < len(self._runs)):
            return
        run = self._runs[i]
        if run.item is not None and 0 <= stage_j < len(run.stage_items):
            self.stage_tree.expandItem(run.item)
            self.stage_tree.setCurrentItem(run.stage_items[stage_j])
        self._load_detail(i, stage_j)

    def _set_verbs_enabled(self, on: bool):
        # e2e_btn is deliberately NOT in this list. Its enablement is a claim about the
        # RUNNING stack (test env + up + seeded), not about whether a verb is busy, so a
        # blanket setEnabled(True) here would arm it on evidence nobody gathered — a
        # possibility only since the gate went off-thread and stopped answering
        # instantly. _sync_e2e_gate below owns it in every state, busy included.
        for b in (self.start_btn, self.stop_btn, self.logs_btn, self.boot_down_btn,
                  self.boot_clean_btn, self.preflight_btn, self.m2_btn):
            b.setEnabled(on)
        # STATE-AWARE TEARDOWN. Stopping/cleaning a stack that is not up does
        # nothing but stream a confusing no-op, and the buttons being live implied
        # there was something to stop. `_mesh_up` is None until the first probe
        # answers — leave them enabled in that window rather than briefly greying
        # controls that may well be valid (an unknown is not a "no").
        if on and self._mesh_up is False:
            for b in (self.boot_down_btn, self.boot_clean_btn):
                b.setEnabled(False)
                b.setToolTip("Disabled: no local mesh is running — nothing to "
                             "stop or clean. (Checked on entry; re-checked after "
                             "every verb.)")
        # The onion/creds/web buttons are only meaningful against a live stack too,
        # but they are read-only and self-explaining when it is down, so they keep
        # their existing behaviour rather than growing another disabled state.
        # the bootstrap start additionally requires the acknowledgement — and carries
        # the "why am I disabled?" tooltip, so route it through the one gate.
        self._sync_boot_gate()
        self._sync_e2e_gate()

    # ── JOIN handlers ────────────────────────────────────────────────────────────
    def _refresh_status(self):
        """Kick off the JOIN-tab node probe, off the GUI thread.

        MeshNode.status() shells `docker compose ps` with a 30s timeout
        (core/mesh_node.py:135) and a wedged daemon blocks for all of it. This ran INLINE
        from initializePage, so entering the page could freeze the window for 30s before
        it had even painted — the same defect the _StatusProbe docstring describes, on the
        same class of call, so it uses the same probe (MeshStatus and StackStatus both
        carry .running/.detail).

        TRI-STATE, never a guess: until the answer arrives the line says "checking…" and
        Stop is left exactly as it was. Rendering "stopped" while the probe is still out
        would be a claim about the mesh that nothing has established."""
        if not probe_running(self, "_node_probe"):   # in flight = its answer is coming
            self.status.setText("Status: checking…")
            probe = own_probe(self, "_node_probe", _StatusProbe(self.node, parent=self))
            probe.result.connect(self._on_node_status)
            probe.start()
        self._sync_e2e_gate()

    def _on_node_status(self, running: bool, detail: str):
        self.status.setText(f"Status: {'running' if running else 'stopped'} ({detail})")
        if not self._running:
            self.stop_btn.setEnabled(running)

    def _start(self):
        self.node = LocalMeshNode(self.generator_dir, self.collect())
        ok, why = self.node.available()
        if not ok:
            self.status.setText(f"Cannot start: {why}")
            return
        self._note("[local-mesh] docker compose up -d …")
        self._launch("Starting the mesh node", self.node.start)

    def _stop(self):
        self._launch("Stopping the mesh node", self.node.stop)

    def _logs(self):
        # A container-log dump is NOT a run: it has no stages and belongs to no row in
        # the tree, so it takes over the pane and says so in the header, and the
        # selection is dropped — otherwise the header would still name a run whose log
        # is no longer on screen. (The button is disabled while a verb runs, so this can
        # never steal the pane from a live stream.)
        self.log.setPlainText(self.node.logs() or "(no logs — node not started?)")
        self.log_header.setText("Log — `docker compose logs` for the mesh node")
        self._selected, self._selected_stage = -1, None

    # ── BOOTSTRAP handlers ───────────────────────────────────────────────────────
    def _refresh_plan(self):
        prod = self.env_prod.isChecked()
        self.prod_group.setVisible(prod)
        self.src_dir.setEnabled(self.src_existing.isChecked())
        self.src_browse.setEnabled(self.src_existing.isChecked())
        # IdP endpoint fields enabled IFF an external provider is picked (casdoor
        # needs — and permits — nothing); placeholders follow the provider.
        ext = self.selected_idp() != "casdoor"
        for w in (self.idp_issuer, self.idp_client_id, self.idp_jwks):
            w.setEnabled(ext)
        self.idp_issuer.setPlaceholderText(
            _IDP_ISSUER_HINTS.get(self.selected_idp(), "") if ext
            else "built-in Casdoor — nothing to configure")
        self.idp_jwks.setPlaceholderText(
            _IDP_JWKS_HINTS.get(self.selected_idp(), "") if ext else "")
        self.boot = LocalMeshBootstrap(self.generator_dir, self.collect_bootstrap())
        # live, never-rounded-up coverage for the existing-tree mode
        if self.src_existing.isChecked():
            found, missing = self.boot.source_coverage()
            total = len(found) + len(missing)
            if not self.src_dir.text().strip():
                self.src_coverage.setText("")
            elif missing:
                head = ", ".join(missing[:4]) + (", …" if len(missing) > 4 else "")
                self.src_coverage.setText(
                    f"{len(found)} of {total} build contexts found. Missing: {head} — "
                    f"compose will fail when it builds those services.")
            else:
                self.src_coverage.setText(f"{total} of {total} build contexts found.")
        else:
            self.src_coverage.setText("")
        self.brand_note.setText(
            "" if self.boot.brand_has_conf() or not self.brand.currentText().strip()
            else f"No brands/{self.brand.currentText().strip()}.conf — runs with "
                 f"built-in defaults (profile presets stay unset).")
        self.plan_view.setPlainText(self.boot.plan())
        self._sync_boot_gate()

    def _probe_mesh_state(self):
        """Kick off the off-thread stack probe (see _StatusProbe). Re-entrant-safe:
        a probe already in flight is left alone rather than stacking threads."""
        if probe_running(self, "_probe"):
            return
        self._mesh_state_label.setText("Mesh state: checking…")
        self._probe = own_probe(self, "_probe",
                                _StatusProbe(self.boot._stack_node(), parent=self))
        self._probe.result.connect(self._on_mesh_state)
        self._probe.start()

    def _on_mesh_state(self, running: bool, detail: str):
        self._mesh_up = running
        if running:
            self._mesh_state_label.setText(
                f"Mesh state: RUNNING — {detail}. 'Generate && start' would bring up "
                f"a second time over the live stack; stop it first if you want a "
                f"clean bring-up.")
        else:
            self._mesh_state_label.setText(
                f"Mesh state: not running ({detail}). Nothing to stop or clean.")
        # Re-run the gates now that the answer is known.
        if not self._running:
            self._set_verbs_enabled(True)

    def _sync_boot_gate(self):
        # The from-scratch start is gated behind the explicit acknowledgement — nothing
        # is generated or started on mere selection (non-destructive by default).
        acked = self.ack.isChecked()
        self.boot_start_btn.setEnabled(acked and not self._running)
        # A disabled button that explains nothing reads as "the app is broken": the
        # click does nothing, and the "Acknowledge the plan first." status line below
        # is UNREACHABLE precisely because the button is disabled. Say why, on the
        # control itself and in the status line, before anyone clicks.
        self.boot_start_btn.setToolTip(
            "Mint credentials and bring up the whole local mesh. On a cold box this "
            "also builds the maven prerequisites first, automatically."
            if acked else
            "Disabled until the acknowledgement above is ticked — nothing is "
            "generated or started on mere selection.")
        # getattr: this gate also runs during construction, BEFORE the shared status
        # label exists (and _set_verbs_enabled can reach it early too).
        status = getattr(self, "status", None)
        if status is not None and not acked and not self._running:
            status.setText("Tick the acknowledgement above to enable "
                           "'Generate && start'.")

    def _bootstrap_up(self):
        if not self.ack.isChecked():
            self.status.setText("Acknowledge the plan first.")
            return
        self.boot = LocalMeshBootstrap(self.generator_dir, self.collect_bootstrap())
        if self.login_theme.error_text():
            self.status.setText(
                "Cannot start: web login theme: " + self.login_theme.error_text())
            return
        problems = self.boot.validate()
        if problems:
            self.status.setText("Cannot start: " + "; ".join(problems))
            return
        for warn in self.boot.warnings():
            self._note(f"WARNING: {warn}")
        self._note("[bootstrap] generating credentials + starting the full "
                   "platform stack from scratch …")
        boot = self.boot
        self._launch("Bootstrapping",
                     lambda on_line, cancel: boot.up(on_line=on_line, cancel=cancel),
                     stream=True, cancellable=True, verb="up")

    def _bootstrap_down(self):
        self._launch("Stopping the stack", self.boot.down)

    def _bootstrap_clean(self):
        """Stop AND reclaim disk. Destructive and slow to undo (the next start is a
        cold build), so it confirms first — and the confirmation says exactly what
        is removed and what is NOT, rather than a generic 'are you sure?'."""
        if QtWidgets.QMessageBox.question(
                self, "Stop and clean Docker?",
                "This stops the local mesh and then REMOVES:\n"
                "  • every container of this stack, and its data volumes\n"
                "  • the ~28 images this stack BUILT\n"
                "  • the private-maven registry container and its cache\n\n"
                "It does NOT touch pulled base images (postgres, cassandra, "
                "mastodon, …), images from other projects, or anything outside this "
                "compose project — no `docker system prune` is run.\n\n"
                "The next start will be a COLD build (hours). Continue?",
                QtWidgets.QMessageBox.StandardButton.Yes
                | QtWidgets.QMessageBox.StandardButton.No,
                QtWidgets.QMessageBox.StandardButton.No
        ) != QtWidgets.QMessageBox.StandardButton.Yes:
            self._note("[stack-clean] cancelled — nothing was removed.", queue=False)
            return
        self.boot = LocalMeshBootstrap(self.generator_dir, self.collect_bootstrap())
        boot = self.boot
        self._note("[stack-clean] stopping the mesh and removing its containers, "
                   "volumes and built images …")
        self._launch("Stopping and cleaning Docker",
                     lambda on_line, cancel: boot.clean(on_line=on_line, cancel=cancel),
                     stream=True, cancellable=True, verb="clean")

    def _check_readiness(self):
        """Read-only host preflight on demand — the exact probes `up` gates on,
        BEFORE the operator commits. Runs off-thread (docker probes can block)."""
        self.boot = LocalMeshBootstrap(self.generator_dir, self.collect_bootstrap())
        boot = self.boot

        def probe():
            problems = boot.preflight()
            if problems:
                return False, ["[readiness] NOT ready:",
                               *(f"  - {p}" for p in problems),
                               "[readiness] fix the above; 'Build maven prereqs "
                               "(m2)' covers the maven-registry one."]
            return True, ["[readiness] READY — docker daemon, buildx, disk "
                          "headroom and maven prerequisites all check out."]

        self._launch("Checking host readiness", probe)

    def _m2_bootstrap(self):
        """The cold-build prerequisite, from the GUI: streams `make
        stack-m2-bootstrap` (org-private maven artifacts built from source into
        the local registry container)."""
        self.boot = LocalMeshBootstrap(self.generator_dir, self.collect_bootstrap())
        boot = self.boot
        self._note("[m2-bootstrap] building the private maven artifacts from "
                   "source (one-time cold-build prerequisite) …")
        self._launch("Building maven prerequisites",
                     lambda on_line, cancel: boot.m2_bootstrap(on_line=on_line,
                                                               cancel=cancel),
                     stream=True, cancellable=True, verb="m2")

    def _sync_e2e_gate(self):
        """Honest enablement for 'Run e2e suite': enabled ONLY when the RUNNING
        stack is up, was started with ENV=test, and the e2e personas are seeded
        (LocalStackNode.e2e_ready — read-only probes of the live stack, never
        the form's un-applied env cards). The tooltip always names the exact
        blockers (the _sync_boot_gate rule: a disabled button that explains
        nothing reads as 'the app is broken'). Runs from _refresh_status —
        page entry + verb end, never on a timer.

        OFF-THREAD (see _E2EGateProbe): e2e_ready() is three 30s docker subprocesses plus
        a 5s HTTP probe, and running it inline from initializePage could freeze the window
        for ~95s on a wedged daemon. A probe already in flight is left alone rather than
        stacking threads."""
        btn = getattr(self, "e2e_btn", None)
        if btn is None:
            return
        if self._running:
            btn.setEnabled(False)
            btn.setToolTip("A verb is running — wait for it to finish.")
            return
        # TRI-STATE. "Unknown" is rendered as unknown, never as a blocker: the button
        # cannot be armed for an action nothing has verified, but the tooltip says the
        # answer is still coming instead of listing reasons that were never established.
        # This runs BEFORE the in-flight guard on purpose — a caller that just blanket-
        # enabled the verb buttons must not be able to leave this one armed by arriving
        # while a probe happens to be out.
        btn.setEnabled(False)
        btn.setToolTip("Checking whether the running stack can host the e2e suite "
                       "(docker probes — this can take a few seconds)…")
        if probe_running(self, "_e2e_probe"):
            return                       # its answer is already on the way
        probe = own_probe(self, "_e2e_probe",
                          _E2EGateProbe(self.boot._stack_node(), parent=self))
        probe.result.connect(self._on_e2e_ready)
        probe.start()

    def _on_e2e_ready(self, problems):
        """The gate's answer arrived (GUI thread). A verb that started while the probe was
        out wins: _launch already disabled the button, and re-enabling it here would arm a
        second run over a live one."""
        btn = getattr(self, "e2e_btn", None)
        if btn is None or self._running:
            return
        problems = list(problems or [])
        btn.setEnabled(not problems)
        btn.setToolTip(
            "Run the Playwright e2e suite (tests/e2e) against the running "
            "local mesh's TLS front door. Output streams below; specs that "
            "need the mock lane or a federation peer SKIP with their reason, "
            "and the final line reports passed/failed/skipped from the "
            "reporter's summary.json."
            if not problems else
            "Disabled:\n- " + "\n- ".join(problems))

    def _devops_install_tools(self):
        """Install the lane's missing CLIs (user-local, checksum-verified)."""
        node = self.boot._stack_node()
        need = node.devops_available()
        if not need:
            self.status.setText("DevOps prerequisites are already installed.")
            return
        self._note("[devops] installing the DevOps lane's prerequisites into "
                   "out/tools/bin (user-local, checksum-verified) …")
        self._launch("Installing DevOps prerequisites",
                     lambda on_line, cancel: node.devops_install_tools(on_line=on_line),
                     stream=True, verb="devops-tools")

    def _devops_up(self):
        """Start the DevOps (Kubernetes) lane. The tool check runs HERE too, so
        the operator gets the missing-prerequisite sentence instead of a failed
        make deep in a streamed log."""
        node = self.boot._stack_node()
        problems = node.devops_available()
        if problems:
            self.status.setText("Cannot start the DevOps lane: "
                                + "; ".join(problems))
            return
        self._note("[devops] creating the local Kubernetes cluster and "
                   "bootstrapping ArgoCD + the app tree — this is long; the "
                   "docker mesh above is unaffected …")
        self._launch("Starting the DevOps lane",
                     lambda on_line, cancel: node.devops_up(on_line=on_line,
                                                            cancel=cancel),
                     stream=True, cancellable=True, verb="devops-up")

    def _devops_down(self):
        node = self.boot._stack_node()
        self._note("[devops] deleting the local Kubernetes cluster (the docker "
                   "mesh and its volumes are untouched) …")
        self._launch("Deleting the DevOps lane",
                     lambda on_line, cancel: node.devops_down(on_line=on_line,
                                                              cancel=cancel),
                     stream=True, cancellable=True, verb="devops-down")

    def _open_vaults(self):
        """Open the Vaults & managed-volumes manager.

        A real modal (exec) is correct HERE and would not be in page logic: this is a
        button click, not validatePage/itemChanged, so nothing headless is waiting on it
        — and the dialog owns its own off-thread probe, so opening it cannot block this
        page. Held on self so the wrapper is not collected while the dialog is up."""
        from ..vaults_dialog import VaultsDialog
        self._vaults_dialog = VaultsDialog(self, project=self._compose_project())
        self._vaults_dialog.exec()

    def _compose_project(self) -> str:
        """The compose project this page's mesh runs under. Falls back to the shipped
        default rather than guessing from the form, because the DIALOG describes what is
        actually on the machine, not what the un-applied selection would create."""
        node = getattr(self, "node", None)
        return getattr(node, "compose_project", None) or vaults.DEFAULT_PROJECT

    def _run_e2e(self):
        """Run the e2e suite against the RUNNING stack. The gate is re-probed
        here (and again inside run_e2e) because enablement can go stale the
        moment the stack changes underneath the page."""
        node = self.boot._stack_node()
        problems = node.e2e_ready()
        if problems:
            self.status.setText("Cannot run e2e: " + "; ".join(problems))
            self._sync_e2e_gate()
            return
        self._note(f"[e2e] running the Playwright suite against {node.web_url} "
                   f"(seeded ENV=test stack) …")
        # Bridge the mesh's REAL superadmin identity (minted by this bootstrap)
        # into the suite: without it every superadmin login 401s, because the
        # seeded handle/password are the minted ones, not the e2e defaults.
        bridge: dict[str, str] = {}
        creds = self.boot.superadmin_login()
        if creds:
            bridge = {"CASDOOR_SUPERADMIN_USERNAME": creds[0],
                      "E2E_SUPERADMIN_PASSWORD": creds[1]}
            self._note(f"[e2e] superadmin identity bridged: {creds[0]} "
                       "(password from the minted secrets bundle)")
        self._launch("Running the e2e suite",
                     lambda on_line, cancel: node.run_e2e(extra_env=bridge,
                                                          on_line=on_line,
                                                          cancel=cancel),
                     stream=True, cancellable=True, verb="e2e")

    def _open_web_ui(self):
        QtGui.QDesktopServices.openUrl(
            QtCore.QUrl(self.boot._stack_node().web_url))

    def _show_credentials(self):
        """Show the seeded persona roster (username / password / roles), copyable.

        Opened from the bring-up row rather than popped automatically after a
        successful `up`: the operator often wants it again later (a second browser,
        a different role) and a one-shot toast would be gone by then. The roster is
        parsed fresh on each open so it reflects the CURRENT checkout + the same env
        the Studio hands `make stack-seed`."""
        roster = load_roster(self.generator_dir,
                             env=self.boot._stack_node()._build_env())
        CredentialsDialog(roster, front_door=self.boot._stack_node().web_url,
                          parent=self).exec()

    def _add_user(self):
        """Add ONE named user to the RUNNING mesh by re-running the idempotent
        seeder with EXTRA_ROLE_USERS appended (seed-accounts.sh's additive door).
        The FULL re-seed is the only correct lane: apply-systems-roles.sh sets
        each role's members to EXACTLY the rendered list, so a single-user
        render would wipe every other persona's memberships."""
        dlg = AddUserDialog(self.generator_dir, parent=self)
        if dlg.exec() != QtWidgets.QDialog.DialogCode.Accepted:
            return
        spec, pw_env, password = dlg.result_spec()
        uname = spec.split(":", 1)[0]
        self._added_user_specs = [s for s in self._added_user_specs
                                  if s.split(":", 1)[0] != uname]
        self._added_user_specs.append(spec)
        env = {"EXTRA_ROLE_USERS": " ".join(self._added_user_specs)}
        if password:
            env[pw_env] = password          # env-only — never argv, never logged
        stack = self.boot._stack_node()
        self._note(f"[add-user] re-seeding with '{uname}' appended (idempotent; "
                   "existing personas re-applied unchanged) …")
        self._launch(f"Adding user {uname}",
                     lambda on_line, cancel: stack.seed(env, on_line=on_line,
                                                        cancel=cancel),
                     stream=True, cancellable=True)

    def _copy_onion(self):
        """Copy the published .onion address to the clipboard. A normal browser
        can't open a .onion, so we copy (for pasting into Tor Browser) rather than
        openUrl — and say plainly when none has been published yet."""
        url = self.boot._stack_node().onion_url()
        if not url:
            QtWidgets.QMessageBox.information(
                self, "No .onion yet",
                "No Tor .onion has been published. Bring the mesh up with "
                "'Expose the mesh as a Tor v3 .onion' ticked (TOR=1) and wait ~30s "
                "for tor to publish the address.")
            return
        QtWidgets.QApplication.clipboard().setText(url)
        QtWidgets.QMessageBox.information(
            self, "Onion address copied",
            f"Copied to the clipboard:\n\n{url}\n\nOpen it in Tor Browser (a normal "
            "browser cannot reach a .onion).")


class LocalMeshDialog(QtWidgets.QDialog):
    """Thin standalone-host shim: ``LocalMeshDialog(generator_dir).exec()`` still
    works without any wizard, hosting the SAME LocalMeshPage (one implementation,
    two frames). The wizard flow itself never opens this — ModePage flows into the
    page via Next now."""

    def __init__(self, generator_dir: str, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Run a local Docker mesh")
        self.resize(720, 620)
        shim = types.SimpleNamespace(generator_dir=generator_dir,
                                     localmesh_selected=True)
        self.page = LocalMeshPage(shim)
        lay = QtWidgets.QVBoxLayout(self)
        lay.addWidget(self.page, 1)
        close = QtWidgets.QPushButton("Close")
        close.clicked.connect(self.accept)
        row = QtWidgets.QHBoxLayout()
        row.addStretch(1)
        row.addWidget(close)
        lay.addLayout(row)
        self.page.initializePage()

    def __getattr__(self, name):
        # FULL backward compatibility for the dialog's former surface: every widget
        # and handler (auth_key, tabs, plan_view, _start, _bootstrap_up, …) now lives
        # on the hosted page — delegate so pre-conversion callers keep working
        # unchanged. __getattr__ fires only when normal lookup MISSES, so the
        # dialog's own attributes (page, windowTitle, …) are never shadowed; the
        # __dict__ guard keeps a mid-__init__ lookup (before self.page exists) an
        # honest AttributeError instead of infinite recursion.
        page = self.__dict__.get("page")
        if page is None:
            raise AttributeError(name)
        return getattr(page, name)

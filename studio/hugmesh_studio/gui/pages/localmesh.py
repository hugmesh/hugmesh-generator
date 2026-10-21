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

TWO mutually-exclusive paths. They used to be TABS; issue #334 replaced that with
the two-card entry every other major path in the Studio uses, and broke the second
path into wizard steps:

  - ``LocalMeshChoicePage`` (pages/localmesh_choice.py) is the entry — card one JOIN
    an existing mesh with a key, card two GENERATE a new mesh.
  - JOIN is one terminal step (``LocalMeshJoinPage``): a tailnet/headscale auth key +
    node knobs into a LocalMeshConfig, driving LocalMeshNode start/stop/logs.
  - GENERATE & START a NEW local mesh FROM SCRATCH is nine steps, in the order this
    surface has always had its sections — Environment & brand -> Domains -> Domain
    services -> Repo source -> Services -> Identity provider -> Mesh overlay (prod
    only) -> Saved meshes & review -> Bring-up & monitor. It mints ALL credentials
    and brings up the full platform stack seeded with a fresh superadmin, via
    LocalMeshBootstrap. Nothing runs on mere selection: the read-only plan preview
    on the review step says what an ``up`` will do, and the button on the last step
    is what runs it.

DOMAINS ON THIS ROUTE (issue #494; reported 2026-09-23: "no gui based multidomain
config in the studio for the generate new mesh path"). The route used to carry ONE
domain field (``boot_domain``, on the prod-only overlay step) and no per-domain
services, so the #495 gate ``_bootstrap_up`` calls could never bite here. Now:
  - ``self.mesh_domains`` (core/local_mesh_domains.LocalMeshDomains) is the domain
    state — kept OFF wiz.cfg, because this branch emits zero ImageConfig fields and
    wiz.cfg.mode is an image mode on which the gate would be a no-op;
  - the ‘Domains’ step hosts the SAME table as the image flow (pages/domains.py
    DomainsTableWidget): row 0 is this mesh's own domain — the brand-default apex on a
    test mesh (fixed), the public apex on a prod one (typed HERE; the overlay step's
    Domain field is a read-only mirror of it, so there are never two disagreeing
    domain fields) — and every added row's Sign-in=own feeds
    ``LocalMeshBootstrapConfig.own_idp_domains`` (one Casdoor each, core/own_casdoor);
  - the ‘Domain services’ step hosts the SAME per-domain services stepper as the
    image flow (pages/domain_services.DomainServicesWidget), one domain at a time;
    the selection is RECORDED with the mesh (``LocalMeshBootstrapConfig.domains``)
    and is NOT what picks the compose profiles — the mesh-wide Services step is;
  - ``_domain_services_refusal`` — the ONE seam both start doors call — gates
    ``mesh_domains`` with a remedy naming these two steps, then wiz.cfg as before.
  - EMISSION NEUTRALITY: a flow that only clicks Next through both steps collects a
    LocalMeshBootstrapConfig byte-identical to one from before the steps existed
    (row 0 is default-shaped, so it is not recorded; no own-IdP rows; the test-env
    apex is never written into ``boot_domain``). Pinned by
    tests/test_localmesh_domains_steps.py.

ONE PAGE STILL OWNS EVERYTHING. ``LocalMeshPage`` builds the whole surface in
``__init__`` exactly as it always did and keeps each block in ``self.sections``;
a step page holds no widgets and no state, and merely CLAIMS its block on first
visit (``take_section``, which re-parents it). That is what keeps the split from
forking the implementation: every verb, every gate, every probe and every widget
attribute the tests read stays on this one object, and ``LocalMeshDialog`` — which
claims nothing — still hosts the entire surface on it.

NEW on the bootstrap tab (the operator's other two asks):
  - BRAND — the GUI was strictly less capable than its own CLI: collect_bootstrap()
    never passed ``brand=``, pinning every GUI run to secret/hugmesh/ while
    ``--brand`` worked fine. Since #654 (D8) the brand box is the SUPERBRAND
    DROP-DOWN (``brand_picker.BrandPicker``): ‘Create a new superbrand’ first and the
    default, then this configuration's own superbrand, saved designs and the real
    brands/*.conf profiles; choosing Create opens ``superbrand.SuperbrandStep`` (the
    design) at the foot of this section. ``self.brand`` keeps the text surface over the
    brand carrier the session writes; validate() DNS-label-gates the slug exactly as
    gen-keystores.sh does.
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
StageTracker owns the semantics: a stage passes only once the run advanced PAST it,
a nonzero exit fails the RUNNING stage and leaves trailing ones pending, and a cancel
marks the running stage 'stopped' (neutral), never failed.

``LocalMeshDialog`` survives as a thin standalone-host shim wrapping the page
(``LocalMeshDialog(generator_dir).exec()`` still works, per its original promise).
It has no wizard to walk, so it shows every section stacked in one scroll — the same
widgets in the same order, with no tab bar in front of them.
"""
from __future__ import annotations

import dataclasses
import os
import re
import threading
import time
import types
from collections import deque

from ..qt import Qt, QtCore, QtGui, QtWidgets, Signal
from .. import console
from ..choice_cards import ChoiceCard, ChoiceCardGroup
from ..flow_layout import flow_box
from ...core import plain_words, saved_meshes, vaults
from ...core.config import IDP_CHOICES, IDP_LABELS, github_org_problem, idp_effective_jwks
from ...core.config import DOMAIN_IDP_OWN, DOMAIN_IDP_SUPERDOMAIN, Domain
from ...core.domain_services import ACTION_MESH_START, gate_reason, record_reviewed
from ...core.local_mesh_domains import (
    DOMAIN_NAME_RE, LOCAL_MESH_REMEDY, SAVED_MESH_REMEDY, LocalMeshDomains,
    added_row_problems, bootstrap_domain_records, domains_from_bootstrap,
    own_idp_names, record_walk, reviewed_record_names)
from ...core.e2e_catalogue import Catalogue, load_catalogue
from ...core.egress_conf import validate_egress_conf
from ...core.local_mesh import LocalMeshConfig, LocalMeshNode
from ...core.local_mesh_bootstrap import (
    LocalMeshBootstrap, LocalMeshBootstrapConfig, _parse_web_locales)
from ...core.local_mesh_stages import verb_phases
from ...core.local_stack_node import (
    LocalStackNode,
    # ONE reader of the KIND_CLUSTER_NAME override, so the confirmation text
    # can never name a different cluster than the verb deletes (#356).
    _kind_cluster_name as kind_cluster_name,
)
from ...core import mesh_monitor
from ...core.local_services import (
    KIND_ADDONS, UNAVAILABLE_LOCALLY, by_slug as local_service, default_selection,
    describe as local_describe, kind_addon_slugs, local_groups, local_slugs)
from ...core.progress_parse import ProgressParser
from ...core import credentials_truth
from ...core import kind_seed
from ...core.seeded_credentials import Roster, annotate, load_roster
from ...core.instance import state_dir
from ...core.stage_tracker import StageTracker
from ...tui.localmesh import PUBLIC_NAME_HOME, sync_brand_session
from ...tui.superbrand_step import CREATE_KEY, session_for
from ...core import e2e_environments
from ._credentials_dialog import CredentialsDialog
from .domain_services import DomainServicesWidget
from .domains import DomainsTableWidget
from ._mesh_monitor_widget import MeshMonitorProbe, MeshMonitorWidget, MeshScaleWorker
from ._add_user_dialog import AddUserDialog
from ._local_agent_widget import LocalAgentWidget, context_from_page
from ._code_folders_widget import CodeFoldersWidget
from ._saved_meshes_widget import SavedMeshProbe, SavedMeshesWidget
from ._logintheme import LoginThemeGroup
from ._scroll import scrollable
from ._widgets import _row, collapsible, label_finish_as_exit, own_probe, probe_running
from .brand_picker import BrandPicker
from .superbrand import SuperbrandStep
# The staged view is progress.py's, not a second one: importing its glyph palette and
# its two formatters is what keeps a stage rendered here byte-identical to the same
# stage rendered on the image-build screen. Re-declaring {"done": ("✓", "#188038"), …}
# would be exactly the duplicated catalogue the house rule forbids — and the first
# palette change would leave the two screens disagreeing about what green means.
# progress.py imports nothing from this module (the reverse dependency is via
# gui/pages/__init__), so this cannot cycle.
from .progress import _STAGE_GLYPH, _STATUS_GLYPH, _display_safe, _fmt_elapsed

# THE DevOps-lane DELETE confirmation (#356). A module-level override point on purpose, the
# same shape `gui.pages.progress.confirm_flash` uses: headless tests monkeypatch this
# name, so the gate on this page's most destructive button is EXERCISED by the suite
# instead of being stubbed away with _devops_down.
#
# Why it was unguarded until now is worth recording. `Delete DevOps lane` (:1485)
# went straight to _launch — one click deleted the kind cluster, its Vault KV, its
# Casdoor identities and every seeded account — while the LESS destructive
# `Stop && clean Docker…` did confirm (_bootstrap_clean). The destructive control was
# the one with no confirmation. Decision 44 kept that fix in scope regardless of how
# the halt itself landed.
#
# Called from _devops_down — an explicit button click — and NEVER from validatePage /
# initializePage / isComplete / itemChanged, where a modal deadlocks the offscreen
# tests.
confirm_devops_down = QtWidgets.QMessageBox.warning
#: what a confirmed delete must return; anything else cancels.
DEVOPS_DOWN_OK = QtWidgets.QMessageBox.StandardButton.Ok
DEVOPS_DOWN_CANCEL = QtWidgets.QMessageBox.StandardButton.Cancel

#: The HALT is not destructive, so it gets no modal — pressing it loses nothing and
#: Resume sits beside it. The DELETE is the destructive one. The text lives here so
#: tests assert on the sentences rather than a paraphrase.
_DEVOPS_DOWN_CONFIRM_TITLE = "Delete the DevOps lane?"
_DEVOPS_DOWN_CONFIRM_TEXT = (
    "This DELETES the kind cluster `{cluster}` and everything in it:\n"
    "  • every pod, PVC and Secret — including Vault's KV and the Casdoor\n"
    "    identities seeded into it, and every account seeded with them\n"
    "  • the `{cluster}-control-plane` container and its image cache\n\n"
    "It does NOT touch the docker compose project of the same name: your local\n"
    "mesh's containers and volumes are untouched, and no `docker system prune`\n"
    "is run.\n\n"
    "The next `Start DevOps lane` is a FULL bring-up (image pulls + rollouts,\n"
    "long), and the cluster comes back EMPTY until it is reseeded — nothing will\n"
    "tell you that it is empty.\n\n"
    "If you only want to STOP the lane, use `Halt DevOps lane` on the monitor\n"
    "below instead: it keeps the cluster and everything in it, and Resume brings\n"
    "it back.\n\n"
    "Delete it?"
)

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


#: What LoginThemeGroup.load() reads when a saved-mesh record carries no theme
#: inputs: the shipped brand. Keys are ImageConfig's login_* names (the group's
#: own load/commit contract) — ALL seventeen that commit() writes, because
#: apply_bootstrap filters the record's form against this dict. Listing only
#: the eight colour/font keys silently threw away the nine web-chrome inputs on
#: every Load/Restore (header hidden, header/footer colours, background effect),
#: derived a different login page, and then reported "every field applied".
#: Chrome falls back inside load() itself, so "" / False are the shipped page.
_THEME_FORM_DEFAULTS = {
    "login_theme_preset": "", "login_theme_mode": "dark",
    "login_primary_color": "", "login_secondary_color": "",
    "login_font": "", "login_font_file": "",
    "login_font_licence": "", "login_font_source": "",
    "login_header_hidden": False, "login_header_size": "",
    "login_header_bg": "", "login_header_text": "",
    "login_footer_hidden": False, "login_footer_size": "",
    "login_footer_bg": "", "login_footer_text": "",
    "login_bg_effect": "",
}


_IDP_JWKS_HINTS = {
    "entra": "empty = <issuer>/discovery/v2.0/keys",
    "aws": "empty = <issuer>/.well-known/jwks.json",
    "oidc": "empty = <issuer>/.well-known/jwks",
}


class _StatusProbe(QtCore.QThread):
    """Ask the RUNNING stack what it is, off the GUI thread.

    `docker compose ps` shells out and can block for seconds (a busy or hung
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
    the page, on top of MeshNode.status()'s own 30s (mesh_node.py:135). A hung docker
    daemon blocks each of those for its full timeout, and none of that work needs the GUI
    thread.

    Emits the problems list (empty = ready). Never raises: e2e_ready() already folds every
    probe failure into a human sentence, and an exception escaping run() would leave the
    button stuck in its 'checking…' state forever."""
    result = Signal(object)                     # list[str]

    def __init__(self, node, environment: str = "docker", parent=None):
        super().__init__(parent)
        self._node = node
        # WHICH mesh the readiness question is being asked ABOUT. Without it the
        # probe always answered for the docker compose stack, so selecting kind
        # or qemu would have greyed the Run button for reasons describing a mesh
        # the operator had not chosen.
        self._environment = environment

    def run(self):
        try:
            self.result.emit(list(self._node.e2e_ready(self._environment)))
        except Exception as e:                  # never kill the page over a probe
            self.result.emit([f"the readiness probe failed: {type(e).__name__}: {e}"])


class _E2ECatalogueProbe(QtCore.QThread):
    """Build the e2e CATALOGUE off the GUI thread, for the feature tree.

    core.e2e_catalogue.load_catalogue() shells `npx playwright test --list` (0.3s on a
    warm checkout, but a 180s ceiling), reads the last run's report.json and walks every
    spec source. That is the same class of call _E2EGateProbe exists for, so it gets the
    same treatment: a button press must never be able to freeze the window, however
    briefly, and a box with no node_modules is exactly where the ceiling bites.

    Emits the Catalogue. Never raises — load_catalogue already folds every failure into
    its own `problems` list, and an exception escaping run() would leave the operator
    with a button that did nothing at all."""
    result = Signal(object)                     # e2e_catalogue.Catalogue

    def __init__(self, generator_dir: str, env=None, parent=None):
        super().__init__(parent)
        self._dir = generator_dir
        self._env = env

    def run(self):
        try:
            self.result.emit(load_catalogue(self._dir, env=self._env))
        except Exception as e:                  # never kill the page over a probe
            cat = Catalogue()
            cat.problems.append(
                f"the e2e catalogue could not be built: {type(e).__name__}: {e}")
            self.result.emit(cat)


class _CredsProbe(QtCore.QThread):
    """Gather the sign-in credentials AND whether they are true of the running
    mesh, off the GUI thread.

    Pressing "Sign-in credentials" used to do three blocking things INLINE before
    its modal opened: parse three seeder scripts, build the stack env — which
    WRITES the theme/limits overlay files — and nothing at all about the mesh, so
    the dialog presented whatever was on disk as the way in. Now the click starts
    this probe and the dialog is constructed in its result slot, from facts:
    core/credentials_truth.probe_credentials is docker + Casdoor + stat, blocking
    by contract (up to ~30s on a hung daemon), so it runs here.

    Emits ``(Roster, CredentialTruth | None)``. Never raises: a failure lands in
    ``Roster.error`` so the dialog's existing unreadable-roster branch renders it,
    and an exception escaping run() would leave the button stuck at "checking…"."""
    result = Signal(object)                     # (Roster, CredentialTruth | None)

    def __init__(self, boot, generator_dir: str, added=(), parent=None):
        super().__init__(parent)
        self._boot = boot
        self._dir = generator_dir
        self._added = tuple(added)

    def run(self):
        try:
            node = self._boot._stack_node()
            env = node._build_env(write_overlays=False)   # a probe READS
            roster = load_roster(self._dir, env=env)
            truth = credentials_truth.probe_credentials(
                self._dir, env, node, self._boot, operator_user=roster.operator)
            roster = annotate(roster, truth, added=self._added)
        except Exception as e:                  # never kill the page over a probe
            roster = Roster(error=f"the credentials probe failed: "
                                  f"{type(e).__name__}: {e}")
            truth = None
        self.result.emit((roster, truth))


#: The monitor's off-thread reader. ONE class, defined in ``_mesh_monitor_widget``
#: (issue #341, second item): this used to be a hand copy of ``MeshMonitorProbe``,
#: kept because the dedup could only run THIS way — ``_mesh_monitor_widget`` cannot
#: import from here (this module imports it at load, so that would be circular) — and
#: #336 forbade its lane from touching this file. ``test_localmesh_monitor.
#: test_the_two_monitor_probes_have_not_drifted`` pinned the drift until the alias
#: landed; it now pins the identity. Same treatment as before: never inline, held
#: with own_probe, guarded with probe_running (see _refresh_monitor).
_MonitorProbe = MeshMonitorProbe


class _MeshWorker(QtCore.QThread):
    """Runs ONE mesh verb off the GUI thread. Hold a reference on the page
    (self.worker) — a local would be GC'd mid-run and take the thread with it.

    Two verb shapes:
      * buffered (the original): a zero-arg callable returning (ok, lines-or-msg) —
        the result lines are emitted when it finishes;
      * streaming: ``stream=True`` and the callable takes (on_line, cancel) — every
        line is emitted AS THE VERB RUNS (line.emit is thread-safe: a queued
        signal), and the returned lines are NOT re-emitted (they already streamed —
        re-dumping them doubled every milestone in the log).

    THE ONE EXCEPTION, and why it is not a hole in that rule: a streaming verb that
    FAILS having emitted NOTHING. "They already streamed" is the whole justification
    for dropping the return value, and when nothing streamed it is simply false — the
    run then showed an empty log under a status bar reading "FAILED (see log)", which
    is the least useful thing this page can say. Zero emitted lines means there is
    nothing to double, so emitting the reason there is safe by construction. The
    verbs themselves also stream their own reasons now (core/local_stack_node,
    core/devops_tools); this is the net under any future one that forgets."""
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
                emitted = 0

                def _emit(ln: str) -> None:
                    nonlocal emitted
                    emitted += 1
                    self.line.emit(ln)

                ok, out = self._fn(_emit, self.cancel)
                if not ok and emitted == 0 and out:
                    for ln in str(out).splitlines():
                        self.line.emit(ln)
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


# A persona credential printed as "<user> / <value>" (the shape `make stack-seed`
# used to echo: "e2e-admin / <password>", then the bare value AGAIN in the same
# sentence). Belt and braces behind the Makefile no longer printing it: a run log is
# persisted to disk, so a line in this shape must not reach it with the value
# attached. The value is learned from the shape and then scrubbed EVERYWHERE in the
# run, not just where the shape matched — the old sentence repeated it.
_PERSONA_SECRET_RE = re.compile(r"\be2e-[A-Za-z0-9_.-]+ / (\S+)")
_MIN_SECRET_LEN = 6     # refuse to scrub a short token that would shred ordinary text


def _redact_run_log(lines) -> list:
    lines = list(lines)
    secrets = set()
    for ln in lines:
        for m in _PERSONA_SECRET_RE.finditer(ln):
            tok = m.group(1)
            for cand in (tok, tok.rstrip(").,;:'\"")):
                if len(cand) >= _MIN_SECRET_LEN:
                    secrets.add(cand)
    # Longest first, so a value that contains another is replaced whole.
    for sec in sorted(secrets, key=len, reverse=True):
        lines = [ln.replace(sec, "[redacted]") for ln in lines]
    return lines


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


class _BrandId(QtCore.QObject):
    """The brand id this page reads and writes as TEXT — what the editable ``Brand`` box
    was (#654, D8). ``collect_bootstrap``, the plan, the saved-mesh round trip and
    ``tests/test_local_mesh_source_axis.py`` all say ``self.brand.currentText()`` and
    ``setCurrentText``; the drop-down that replaced the box keeps that surface so none of
    them changes, and the value lives in ONE place, the page's brand carrier."""

    currentTextChanged = Signal(str)

    def __init__(self, page: "LocalMeshPage"):
        super().__init__(page)
        self._page = page

    def currentText(self) -> str:
        return self._page._brand_boot.brand

    def setCurrentText(self, text: str) -> None:
        self._page._set_brand_id(text)


class LocalMeshPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.generator_dir = wiz.generator_dir
        self.node = LocalMeshNode(self.generator_dir, LocalMeshConfig())
        self.boot = LocalMeshBootstrap(self.generator_dir, LocalMeshBootstrapConfig())
        self.worker: _MeshWorker | None = None
        # THE DOMAINS OF THIS MESH (#494) — see the module docstring. Empty until the
        # Domains step seeds row 0 on its first visit (never here: a host with no
        # steps, and a saved-mesh Start on a flow that never opened the step, keep
        # passing the gate exactly as before).
        self.mesh_domains = LocalMeshDomains()
        # THE BRAND CARRIER (#654, D8): the one bootstrap configuration the superbrand
        # session (tui/superbrand_step.py) reads and writes, so the picker, the design
        # and the text screens all drive one model. It holds only what the session owns:
        # the brand id and the superbrand block. ``collect_bootstrap`` takes exactly
        # those two from it and everything else from the page's own controls, so there
        # is one writer for each field. REPLACED, never edited in place, when a saved
        # mesh is applied (the session belongs to the configuration object it was made
        # for).
        self._brand_boot = LocalMeshBootstrapConfig()
        self._brand_mounted = False
        self._brand_busy = False
        #: a central sign-in address a SAVED MESH carried (a choice, kept); every other
        #: address is derived from the environment and the domain and re-derived
        self._brand_explicit_signin = ""
        self._brand_file_note = ""       # why the last record-file save was refused ("" = none)
        # THE CONTROLLER HANDLE. Every local-mesh step page (LocalMeshChoicePage and
        # the _LocalMeshStep subclasses at the bottom of this module) finds this page
        # here, and only at initializePage time — so the wizard may construct the steps
        # in display order with this page LAST and no construction-order dance is
        # needed. A standalone host (LocalMeshDialog's SimpleNamespace shim) accepts
        # the attribute too and simply never reads it; a host that refuses it is not an
        # error, because nothing but a step page ever looks it up.
        try:
            wiz.localmesh_page = self
        except Exception:                    # noqa: BLE001 — read-only host shim
            pass
        # Users added via the Add-user verb THIS session, as seeder specs
        # ("name:ROLES:PW_ENV"). The FULL list rides every Add-user re-seed:
        # apply-systems-roles.sh writes EXACT role member sets, so a spec that
        # drops out of a later render loses its role memberships.
        self._added_user_specs: list[str] = []
        self._running = False
        self._running_label = ""
        # apply_bootstrap() in flight: _refresh_plan returns early so the plan
        # preview re-renders ONCE at the end, not once per setter (ask C).
        self._applying_bootstrap = False
        # The e2e gate's last ANSWER, kept so an open feature tree can be gated by
        # the same sentences the button's tooltip carries. Starts non-empty on
        # purpose: before any probe reports, "nothing established" must read as a
        # blocker, never as permission.
        self._e2e_blockers: list[str] = [
            "the running stack has not been checked yet — the readiness probe has "
            "not reported."]
        self.setTitle("Bring-up and monitor")
        self.setSubTitle("Everything is chosen. Press 'Generate && start' to mint the "
                         "credentials and bring the mesh up on THIS machine; the "
                         "stages and the running-mesh table below report what happens. "
                         "This is the end of this path: Exit closes the Studio; the "
                         "mesh keeps running in Docker.")
        self.setFinalPage(True)
        # Pressing the final button here does nothing but close the Studio — no
        # build, no apply, no write, no state commit — so it says so (_widgets:
        # label_finish_as_exit).
        label_finish_as_exit(self)

        # SECTIONS, NOT TABS (issue #334). The two paths used to be a QTabWidget —
        # "Join an existing mesh with a key" and the bootstrap tab — the one pick-one
        # control left in the Studio that was not the two-card entry every other major
        # path uses. The tabs are gone: LocalMeshChoicePage
        # (pages/localmesh_choice.py) is the entry, and the bootstrap surface is a
        # sequence of wizard STEPS (the classes at the bottom of this module).
        #
        # This page still BUILDS the whole surface, in the order it always had, and
        # keeps each block in `self.sections`. That is what makes the split cheap and
        # keeps ONE implementation: every widget, handler, gate and test contract stays
        # on this one page object, and a step page merely CLAIMS the block it is
        # responsible for (take_section, which re-parents it). The standalone
        # LocalMeshDialog claims nothing, so it hosts the entire surface on this page
        # exactly as before — one implementation, two frames.
        #
        # The scroll area stays: a claimed step is still tall (the services table alone
        # floors at 300px), and a tall page must SCROLL rather than grow the window
        # (the _scroll.py contract; Role/Network/Build/Home do the same).
        lay = scrollable(self)
        self._body = lay
        self.sections: dict[str, QtWidgets.QWidget] = {
            "join": self._build_join_section(),
            "env": self._build_env_section(),
            "domains": self._build_domains_section(),
            "domain_services": self._build_domain_services_section(),
            "source": self._build_source_section(),
            "services": self._build_services_section(),
            "idp": self._build_idp_section(),
            "overlay": self._build_overlay_section(),
            "review": self._build_review_section(),
            "bringup": self._build_bringup_section(),
        }
        for _sec in self.sections.values():
            lay.addWidget(_sec)

        # Shared status line + staged view, used by BOTH paths — held in ONE widget so
        # a step page can claim the whole run surface with take_section("run"). Join
        # and bring-up are the two pages a verb can run from, and only one of them is
        # reachable in a given flow (the choice card decides), so the run view FOLLOWS
        # whichever is on screen instead of being duplicated.
        self.run_view = QtWidgets.QWidget()
        run_lay = QtWidgets.QVBoxLayout(self.run_view)
        run_lay.setContentsMargins(0, 0, 0, 0)
        self.status = QtWidgets.QLabel("")
        self.status.setWordWrap(True)
        run_lay.addWidget(self.status)

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
            "No verb has run yet. Start one from the buttons above and its stages "
            "appear here; click a stage to see only that stage's output in the log "
            "below.")
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
        self.log = console.attach(QtWidgets.QPlainTextEdit())
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
        run_lay.addWidget(self.stage_splitter, 1)
        lay.addWidget(self.run_view, 1)

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

        # What the last credentials probe established about the running mesh
        # (core/credentials_truth.CredentialTruth), None until the button is
        # pressed. Users this session's Add user seeded — (name, roles), never the
        # password — so the dialog can list them as "added this session".
        self._cred_truth = None
        self._added_users_ok: list[tuple[str, tuple[str, ...]]] = []
        # ── the running-mesh monitor's state (the table itself lives in the bring-up
        # section; see _build_bringup_section). None until the first snapshot answers —
        # the same tri-state rule as _mesh_up, and for the same reason.
        self._monitor: mesh_monitor.MonitorSnapshot | None = None
        # Set at every verb's end, cleared when a read STARTS after it: the state
        # probe's answer (and a read that was already in flight) re-reads the
        # monitor, so a just-finished bring-up populates the table with no click.
        self._monitor_stale = False
        #: The same flag for the SAVED-MESH table: a verb has changed the things its
        #: per-row facts are read from (data volumes, the credentials file, the
        #: source tree), so the rows on screen are stale. Consumed by _on_mesh_state,
        #: for the reason _verb_done spells out.
        self._saved_stale = False
        # THIRD timer on this page, justified: _tick is the 1 Hz run clock, _drain the
        # 50 ms log coalescer — different jobs, different cadences — and this one is
        # the only one stopped when its section is folded. NOT started here: it runs
        # only while the section is expanded, the page visible, and no verb running.
        self._monitor_timer = QtCore.QTimer(self)
        self._monitor_timer.setInterval(10_000)
        self._monitor_timer.timeout.connect(self._on_monitor_tick)
        # completeChanged fires at every verb start AND end (_launch / _verb_done), so
        # it is the hook that lets the monitor's note say "paused" the moment a verb
        # begins without this lane touching _launch.
        # The plan preview follows every control that feeds it, and renders ONCE now
        # that every section exists. This used to be the tail of the bootstrap-tab
        # builder; with the surface built in eight pieces it belongs here, after all
        # eight, so nothing is wired before the widget it reads exists.
        self._wire_plan_signals()
        self._refresh_plan()
        self.completeChanged.connect(self._sync_monitor_gate)

        # Run the gate ONCE now that every widget it touches exists, so
        # 'Generate & start' is armed (and carries its tooltip) from first paint.
        self._sync_boot_gate()
        # Saved meshes (ask C): the last `_mesh_up` the table was re-probed for —
        # a verb that changes what is on disk (stop, clean, start) flips it, and
        # that flip is what re-checks every row's "Restores as" off-thread.
        self._saved_last_up: bool | None = None
        self._sync_saved_gate()
        # …and the monitor's, so it is greyed with "checking…" (never empty-but-
        # enabled) from first paint. No probe: that rides _on_mesh_state.
        self._sync_monitor_gate()

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
        # Exit stays disabled while a verb runs — leaving mid-up would orphan the
        # worker's signals into a destroyed page.
        return not self._running

    def initializePage(self):
        # Ownership first (_reclaim_sections runs on every show, and take_section is
        # idempotent), then the things that must happen only on a real forward entry:
        # the probes.
        self.take_section("bringup", self._body)
        self.take_section("run", self._body)
        self._hide_stepped_sections()
        # the standalone dialog hosts every section on this page and has no Environment
        # step to give the brand drop-down its session; a wizard's step does it itself
        # and this repeat is cheap and safe
        self.mount_brand()
        self._refresh_status()
        self._refresh_plan()
        # ENTERING THE PAGE MUST TELL YOU WHAT IS ALREADY RUNNING. The stage tree
        # only ever showed THIS session's runs, so after a Studio restart it was
        # empty and the page looked identical whether the mesh was up or down —
        # "Stop mesh" was enabled with nothing to stop, and "Generate && start"
        # invited a second bring-up over a live stack (operator report
        # 2026-08-14). Probe the real compose project instead of assuming.
        self._probe_mesh_state()
        # Saved meshes: a directory listing + JSON parses (no subprocess); the
        # per-row docker/git facts ride the off-thread _saved_probe it kicks off.
        self.saved_meshes.refresh()
        # The monitor adds NO probe here: its first snapshot rides _on_mesh_state's
        # slot, which keeps "entering the page returns immediately" provable.
        self._sync_monitor_gate()

    # ── section plumbing ────────────────────────────────────────────────────────
    def _stepped_sections(self) -> set:
        """Section keys some OTHER page of this wizard is responsible for.

        Read off the wizard's own page list (each ``_LocalMeshStep`` declares its
        ``SECTION``) rather than hardcoded here, so adding or removing a step is one
        edit in the wizard's slot expansion and this stays true. A standalone host —
        LocalMeshDialog's SimpleNamespace shim — has no page list at all, which is
        exactly right: with no steps to claim anything, this page keeps everything.
        """
        pages = getattr(getattr(self, "wiz", None), "_pages", None) or ()
        return {getattr(p, "SECTION", "") for p in pages if p is not self} - {""}

    def _hide_stepped_sections(self) -> None:
        """Hide any section a step owns that is still sitting on this page.

        A step claims its section the first time it is VISITED, so a step that was
        skipped (the prod-only overlay on a test mesh) or never reached (the join
        branch, when the choice card sent the flow the other way) would otherwise
        leave its block rendered here — the bring-up step showing a join form is
        exactly the muddle the two cards exist to remove. take_section() shows a
        section again when it is claimed, so this cannot strand one.
        """
        host = self._body.parentWidget()
        for key in self._stepped_sections():
            sec = self.sections.get(key)
            if sec is not None and sec.parentWidget() is host:
                sec.setVisible(False)

    def take_section(self, key: str, layout) -> "QtWidgets.QWidget | None":
        """Move section ``key`` into ``layout`` and return it (None for an unknown key).

        Adding a widget to a layout re-parents it, so this IS the move — there is no
        copy anywhere and no second instance of anything. Idempotent by parent: a
        section already living in ``layout`` is left exactly where it is, which is what
        makes it safe to call from every ``initializePage`` (Qt calls that on every
        forward visit, and re-inserting on each one would reorder the page).

        Insertion lands BEFORE the layout's trailing stretch when it has one (a step
        page adds one so its content sits at the top), and at the end otherwise (this
        page's own body, where the run view must stay last).
        """
        w = self.run_view if key == "run" else self.sections.get(key)
        if w is None:
            return None
        host = layout.parentWidget()
        if host is not None and w.parentWidget() is host:
            return w
        idx = layout.count()
        for i in range(layout.count()):
            if layout.itemAt(i).spacerItem() is not None:
                idx = i
                break
        # stretch 1 for the run view only: the staged tree + log is the one block that
        # should absorb a step page's spare height.
        layout.insertWidget(idx, w, 1 if key == "run" else 0)
        # setParent() hides a widget; a section that has been moved must be shown
        # again. The blocks INSIDE it keep their own visibility (prod_group's
        # test/prod toggle, every Collapsible's fold) — those are children, untouched.
        w.setVisible(True)
        return w

    # ── JOIN section (handlers now threaded; widget names unchanged) ─────────────
    def _build_join_section(self) -> QtWidgets.QWidget:
        w = QtWidgets.QGroupBox("Join an existing mesh with a key")
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

    # ── BOOTSTRAP sections, in the order the surface has always had ──────────────
    def _build_env_section(self) -> QtWidgets.QWidget:
        w = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(w)
        lay.setContentsMargins(0, 0, 0, 0)
        intro = QtWidgets.QLabel(
            "Generate ALL credentials from scratch and start a NEW superadmin-"
            "controlled mesh on THIS machine: mint the Casdoor/DB/observability "
            "secrets + a fresh superadmin, bring up the full platform stack, and (in "
            "prod) attach the tailscale overlay. Nothing runs until you press "
            "'Generate && start' on the last step — the read-only plan on the review "
            "step before it is exactly what that button will do.")
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

        # BRAND — the superbrand drop-down (#654, D8) where the editable slug box was.
        # ‘Create a new superbrand’ is the first item and the default; then this
        # configuration's own superbrand, the saved designs and the real brands/*.conf
        # profiles (the old box's catalogue, discover_brands, is the profile half). The
        # slug the old box fixed (collect_bootstrap() used to omit brand=, pinning every
        # GUI run to secret/hugmesh/) is still collected: ``self.brand`` keeps the text
        # surface and reads the carrier the picker writes. The design itself is the last
        # block of this section, below.
        self.brand = _BrandId(self)
        self.brand_picker = BrandPicker()
        sb = plain_words.term("superbrand")
        self.brand_picker.setToolTip(
            f"Which {sb} governs this mesh. A brand's id is also the Vault base "
            "path segment (secret/<id>/) AND the profile selector (brands/<id>.conf, "
            "sourced by gen-cluster-secrets.sh when present): it must be a DNS label — "
            "the same gate gen-keystores.sh applies.")
        lay.addWidget(self.brand_picker)
        # one plain sentence when the drop-down or the design could not do what was asked
        # (the page used to print a traceback to the terminal and carry on half-drawn)
        self.brand_error = QtWidgets.QLabel("")
        self.brand_error.setObjectName("brand_error")
        self.brand_error.setWordWrap(True)
        self.brand_error.setStyleSheet("color: #b00020;")
        self.brand_error.setVisible(False)
        lay.addWidget(self.brand_error)
        self.brand_note = QtWidgets.QLabel("")
        self.brand_note.setWordWrap(True)
        self.brand_note.setStyleSheet("color: gray;")
        lay.addWidget(self.brand_note)

        # SUPERADMIN moved up one block, from between "Repo source" and "Services" to
        # the end of this one. It is the account this bring-up MINTS, so it belongs
        # with the environment and brand that decide where it is minted — and as its
        # own wizard step, "Repo source" is about the source tree and nothing else.
        # Presentation only: collect_bootstrap reads the same widget either way.
        self.superadmin = QtWidgets.QLineEdit("superadmin")
        self.superadmin.setToolTip(
            "The platform superadmin login to mint. Its password is generated fresh "
            "and written ONLY to the offline secrets bundle — never shown here.")
        lay.addWidget(_row("Superadmin", self.superadmin))

        # ‘DESIGN YOUR SUPERBRAND’ (#654, D8): the design the drop-down's ‘Create a new
        # superbrand’ opens, drawn under the rest of this section so the environment
        # and the account stay where they always were. It is the same step the image
        # route's Branding page hosts, over the session of THIS route. The design is
        # shown only while one is open (a created superbrand, or ‘Change it’ on an
        # existing one); an existing choice shows its read-only summary in the picker.
        self.superbrand_design = SuperbrandStep(route="docker", with_picker=False)
        lay.addWidget(self.superbrand_design)
        self.brand_effect_note = QtWidgets.QLabel(
            "What this saves: the design goes into the mesh's brand record and the plan on "
            "the review step. This Docker mesh still takes its web login look from the ‘Web login "
            "theme’ on the Services step until the start path reads the record.")
        self.brand_effect_note.setObjectName("brand_effect_note")
        self.brand_effect_note.setWordWrap(True)
        self.brand_effect_note.setStyleSheet("color: gray;")
        lay.addWidget(self.brand_effect_note)
        self.brand_picker.designing_changed.connect(self.superbrand_design.refresh)
        self.brand_picker.designing_changed.connect(self._brand_changed)
        self.superbrand_design.changed.connect(self._brand_changed)
        lay.addStretch(1)
        return w

    # ── DOMAINS + DOMAIN SERVICES sections (#494) ────────────────────────────────
    def _build_domains_section(self) -> QtWidgets.QWidget:
        w = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(w)
        lay.setContentsMargins(0, 0, 0, 0)
        self.domains_help = QtWidgets.QLabel(
            "Row 0 is this mesh's OWN domain: on a test mesh the brand-default apex "
            "(fixed — a test mesh publishes nothing), on a prod mesh the public apex, "
            "typed here (it is what the minted issuer and superadmin align with; the "
            "Mesh overlay step shows it read-only). Add every OTHER domain this mesh "
            "serves below. ‘Sign-in’ = which Casdoor serves that domain: Superdomain "
            "(the mesh's central one) or Own (a Casdoor instance of its own is brought "
            "up beside the central one — host ports 8001, 8002, … in row order). "
            "‘Optional services’ is READ-ONLY here: every domain — this row 0 "
            "included — gets its own page on the ‘Domain services’ step that follows, "
            "and a mesh start refuses while any domain here has never been through "
            "it, naming the domain.")
        self.domains_help.setWordWrap(True)
        self.domains_help.setStyleSheet("color: gray;")
        lay.addWidget(self.domains_help)
        self.domains_table = DomainsTableWidget(
            cfg=lambda: self.mesh_domains,
            own_name_editable=lambda: self.env_prod.isChecked())
        lay.addWidget(self.domains_table)
        # Inline (never a modal): a prod mesh whose own domain is still blank.
        self.domains_note = QtWidgets.QLabel("")
        self.domains_note.setWordWrap(True)
        self.domains_note.setStyleSheet("color: #c62828;")
        self.domains_note.setVisible(False)
        lay.addWidget(self.domains_note)
        return w

    def _build_domain_services_section(self) -> QtWidgets.QWidget:
        w = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(w)
        lay.setContentsMargins(0, 0, 0, 0)
        # The SAME body as the image flow's DomainServicesPage. No mesh-wide config to
        # read the "not domain-scoped" table's state column from on this route (that
        # column reads an ImageConfig's services; the local mesh's live on the
        # Services step, two steps on), so scope_cfg stays None and the step subtitle
        # says so rather than leaving the column looking broken.
        self.domain_services = DomainServicesWidget(
            scope_cfg=None, entries=None,
            lane_note=("ON THIS LOCAL DOCKER MESH: the per-domain selection is "
                       "recorded with the mesh (and shown in the plan) — it is NOT "
                       "what decides which compose profiles come up; the mesh-wide "
                       "‘Services’ step two steps on is."))
        lay.addWidget(self.domain_services)
        return w

    def _own_domain_name(self) -> str:
        """The mesh's own domain as the Domains step shows it in row 0: the resolved
        apex (``LocalMeshBootstrapConfig.resolved_domain``: the typed cluster domain,
        else the brand default) on a test mesh; on a prod mesh exactly what
        ``boot_domain`` holds — possibly "" until the operator types it here."""
        typed = self.boot_domain.text().strip()
        if self.env_prod.isChecked():
            return typed
        return typed or LocalMeshBootstrapConfig().resolved_domain()

    def _seed_domains(self) -> None:
        """Enter the Domains step: make row 0 the mesh's own domain and fill the table.

        First visit: seeds the single own row. Later visits: re-syncs row 0's name
        with the environment / ``boot_domain`` (the env may have changed on the step
        before, or a saved mesh may have been applied), keeping every added row.
        The seed happens HERE, not in the constructor (see ``mesh_domains``)."""
        md = self.mesh_domains
        own = self._own_domain_name()
        if not md.domains:
            md.domains = [Domain(name=own, title="")]
            md.own_name = own
        elif md.own_name != own:
            row = md.by_name(md.own_name)
            if row is not None:
                row.name = own
            else:
                md.domains.insert(0, Domain(name=own, title=""))
            md.own_name = own
            # a renamed own domain is a domain nobody has reviewed under that name
            record_reviewed(md, md.domain_services_reviewed)
        self.domains_table.fill(md.domains, md.own_name)
        self.domains_note.setVisible(False)
        # Once the Domains step owns the own domain, the overlay's field is a mirror.
        self.boot_domain.setReadOnly(True)
        self.boot_domain_note.setVisible(True)

    def _domain_row_problems(self) -> list[str]:
        """Why the recorded rows cannot go to a bring-up; [] when they can.

        The ADDED rows (``mesh_domains.domains[1:]`` — row 0 is the own domain by
        construction) must be domain names, distinct, and not the own domain again;
        a typed prod apex must be a domain name. The TUI refuses the same cases at
        entry, with the same words (``core.local_mesh_domains.added_row_problems``).
        A BLANK prod apex is not listed: the bring-up's own validate() refuses that,
        as it always has, and the step shows its own note for it."""
        md = self.mesh_domains
        problems = added_row_problems([d.name for d in md.domains[1:]], md.own_name)
        own = (md.own_name or "").strip()
        if self.env_prod.isChecked() and own and not DOMAIN_NAME_RE.match(own):
            problems.insert(0, f"row 0: not a domain name: {own!r} (lowercase "
                               "dotted hostname, e.g. example.org)")
        return problems

    def _commit_domains(self) -> bool:
        """Leave the Domains step: the table's rows become ``mesh_domains``, row 0's
        typed name (prod) becomes ``boot_domain`` — the ONE direction the mirror is
        written in — and the reviewed markers are pruned to the rows that still
        exist.

        Refuses (returns False, inline note — never a modal) only on a row that
        cannot be a domain: a non-hostname, a duplicate, or an added row named
        after row 0 (PR #595 skeptics: those reached ``own_idp_domains`` as a
        duplicate ``casdoor-<slug>`` service, or an own Casdoor for the mesh's own
        apex). The rows are STILL recorded, so a Back keeps what was typed and the
        next entry shows it again; the refusal is on Next, and the bring-up
        re-checks (``_bootstrap_up``). A blank prod apex is a note, not a refusal:
        the bring-up's own validate() refuses that, as it always has."""
        md = self.mesh_domains
        added, _ca = self.domains_table.rows()
        own = self.domains_table.own_row_name()
        prod = self.env_prod.isChecked()
        if prod:
            if own != self.boot_domain.text().strip():
                self.boot_domain.setText(own)
        else:
            own = md.own_name or own
        prev = md.by_name(md.own_name) if md.own_name else None
        # The own row's org comes from its CELL, like every added row's: the state
        # is written only by the cell's focus-loss slot, and the Next shortcut or a
        # programmatic next() never moves focus. The state is read only when the
        # table has no own row to read. A non-slug stays out of the state (the
        # refusal below names it); the cell keeps it for the operator to fix.
        table = self.domains_table
        if any(table.is_own_row(r) for r in range(table.table.rowCount())):
            own_org = table.own_row_github_org()
            if github_org_problem(own_org):
                own_org = ""
        else:
            own_org = getattr(prev, "github_org", "") if prev else ""
        own_row = Domain(name=own, title="", idp=DOMAIN_IDP_SUPERDOMAIN,
                         optional_services=list(prev.optional_services) if prev else [],
                         github_org=own_org)
        for d in added:
            if github_org_problem(getattr(d, "github_org", "")):
                d.github_org = ""
        md.domains = [own_row] + added
        md.own_name = own
        record_reviewed(md, md.domain_services_reviewed)
        blank = prod and not own
        # a GitHub org that is not a slug is refused here, inline, with the sentence
        # the image flow's DomainsPage.validatePage uses — it used to be accepted on
        # this route and reach the saved record
        problems = table.org_problems() + self._domain_row_problems()
        lines = list(problems)
        if blank:
            lines.append(
                "A prod mesh needs its public apex domain in row 0 — the minted "
                "issuer and superadmin align with it. The mesh cannot start without "
                "it.")
        if problems:
            lines.append("Fix or remove these rows to continue.")
        self.domains_note.setText("\n".join(lines))
        self.domains_note.setVisible(bool(lines))
        self._refresh_plan()
        return not problems

    def _build_source_section(self) -> QtWidgets.QWidget:
        w = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(w)
        lay.setContentsMargins(0, 0, 0, 0)
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
        # CODE FOLDERS (#689): the git checkout behind every app of every domain, with
        # a button to open it. It reads the cards above, so it sits on this step in
        # BOTH frames (the stepped wizard claims the whole "source" section; the
        # single-page dialog keeps it) with no section claim of its own.
        self.code_folders = CodeFoldersWidget(self.generator_dir)
        lay.addWidget(self.code_folders)
        lay.addStretch(1)
        return w

    def _build_services_section(self) -> QtWidgets.QWidget:
        w = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(w)
        lay.setContentsMargins(0, 0, 0, 0)
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
            "on the bring-up step. Anything the local docker stack has no mechanism "
            "for is greyed "
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
                    # `describe` names). A checkbox here could only do nothing: no
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
        # "Themes", not "Web login theme" (#50 item 2): label-only rename — the
        # persisted login_* config keys keep their names so old sessions load.
        lay.addWidget(collapsible("Themes (colours, fonts + web chrome)",
                                  self.login_theme, expanded=False))
        return w

    def _build_idp_section(self) -> QtWidgets.QWidget:
        w = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(w)
        lay.setContentsMargins(0, 0, 0, 0)
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
        lay.addStretch(1)
        return w

    def _build_overlay_section(self) -> QtWidgets.QWidget:
        w = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(w)
        lay.setContentsMargins(0, 0, 0, 0)
        # prod-only overlay group.
        self.prod_group = QtWidgets.QGroupBox("Mesh overlay (prod only)")
        pg = QtWidgets.QVBoxLayout(self.prod_group)
        self.boot_domain = QtWidgets.QLineEdit()
        self.boot_domain.setPlaceholderText("public apex domain, e.g. example.com (required in prod)")
        pg.addWidget(_row("Domain", self.boot_domain))
        # Read-only MIRROR of the Domains step's row 0 once that step has been visited
        # (_seed_domains flips it): one domain field the operator types, one place it
        # is shown again. A host with no steps (LocalMeshDialog) keeps it editable.
        self.boot_domain_note = QtWidgets.QLabel(
            "Set on the ‘Domains’ step (row 0, this mesh's own domain); shown here "
            "read-only so the overlay and the domains table can never disagree.")
        self.boot_domain_note.setWordWrap(True)
        self.boot_domain_note.setStyleSheet("color: gray;")
        self.boot_domain_note.setVisible(False)
        pg.addWidget(self.boot_domain_note)
        self.boot_auth_key = QtWidgets.QLineEdit()
        self.boot_auth_key.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.boot_auth_key.setPlaceholderText("tskey-… (required in prod — attaches the overlay)")
        pg.addWidget(_row("Auth key", self.boot_auth_key))
        self.boot_login_server = QtWidgets.QLineEdit()
        self.boot_login_server.setPlaceholderText("optional self-hosted headscale URL")
        pg.addWidget(_row("Login server", self.boot_login_server))
        lay.addWidget(self.prod_group)
        lay.addStretch(1)
        return w

    def _build_review_section(self) -> QtWidgets.QWidget:
        w = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(w)
        lay.setContentsMargins(0, 0, 0, 0)
        # Plan preview (read-only) — the confirm-before-run surface.
        lay.addWidget(QtWidgets.QLabel("Plan preview (what will be generated + started):"))
        self.plan_view = console.attach(QtWidgets.QPlainTextEdit())
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

        # ── SAVED MESHES (ask C) — ABOVE the Actions row on purpose: the operator
        # asked for the table to be in front of them when they try to generate a
        # new mesh, so it sits between "what is running" and "Generate && start".
        # Collapsed when empty (with a VISIBLE grey line, never a hidden widget),
        # auto-expanded when records exist; a manual fold wins for the session
        # (Collapsible.set_default_expanded). Every docker/git call the rows need
        # runs on _saved_probe, off-thread — the widget itself only renders.
        self.saved_meshes = SavedMeshesWidget(self)
        self.saved_meshes.generator_dir = self.generator_dir
        self.saved_section = collapsible("Saved meshes", self.saved_meshes,
                                         expanded=False)
        self.saved_meshes.section = self.saved_section
        self.saved_meshes.start_requested.connect(self._start_saved)
        self.saved_meshes.load_requested.connect(self._load_saved)
        self.saved_meshes.probe_needed.connect(self._probe_saved)
        lay.addWidget(self.saved_section)
        return w

    def _build_bringup_section(self) -> QtWidgets.QWidget:
        w = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(w)
        lay.setContentsMargins(0, 0, 0, 0)

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
            "`make stack-halt` + stop the mesh overlay: every container stops and "
            "the stack's data volumes are KEPT (identity, rooms, accounts, the BFF "
            "databases), so 'Start' on a saved mesh — or the next 'Generate && "
            "start' — reattaches them. The IMAGES stay too, so the next start is a "
            "warm (fast) bring-up. 'Stop && clean Docker…' is the one that drops "
            "volumes.")
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
        # surfaced on demand so problems appear BEFORE anything is started.
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
        # The tooltip is DERIVED from the node's own front-door addresses — a
        # default node here (the form is only half-built at this point), the LIVE
        # node again in _on_mesh_state. A hardcoded copy used to name
        # http://localhost:8088 as the door while the button opened
        # https://localhost:8488.
        self.open_web_btn.setToolTip(
            self._open_web_tooltip(LocalStackNode(self.generator_dir)))
        self.open_web_btn.clicked.connect(self._open_web_ui)
        brow.addWidget(self.open_web_btn)
        self.copy_onion_btn = QtWidgets.QPushButton("Copy .onion address")
        self.copy_onion_btn.setToolTip(
            "Copy the local mesh's minted Tor .onion address to the clipboard (open "
            "it in Tor Browser — a normal browser cannot reach a .onion). Before "
            "tor has published an address, clicking explains how to get one.")
        self.copy_onion_btn.clicked.connect(self._copy_onion)
        brow.addWidget(self.copy_onion_btn)
        self.creds_btn = QtWidgets.QPushButton("Sign-in credentials")
        self.creds_btn.setToolTip(
            "Show the accounts this mesh ACTUALLY has — usernames, the password "
            "THIS RUN generated, roles, and which apps each opens — with one-click "
            "copy: the answer to \"the login page is up, who do I log in AS?\". "
            "Read from run-state (the running Casdoor, the run-state credentials "
            "file, the minted secrets bundle), not from an example. When nothing "
            "has been seeded, or the stored password predates the last completed "
            "seed, it says so instead of showing a value as fact. Checks off-thread "
            "first (a few seconds), then opens.")
        self.creds_btn.clicked.connect(self._show_credentials)
        brow.addWidget(self.creds_btn)
        # Runs tests/e2e against the RUNNING stack. Enablement + tooltip are
        # owned by _sync_e2e_gate (test env + stack up + seeded — live probes,
        # never the form's un-applied selection).
        # WHICH MESH the run drives. The operator asked for e2e evidence in all
        # three environments; before this chooser the GUI could only ever run
        # against the docker compose mesh, and there was no way to say otherwise
        # short of a terminal.
        #
        # ONE CONTRACT WITH THE CLI. The choice does not become a flag, a config
        # key or a different make target — it becomes SNAP_ENV on the child
        # process, which is exactly what `SNAP_ENV=kind make stack-e2e-bdd-env`
        # sets and what tests/e2e/steps/world.ts reads. core/e2e_environments
        # builds both. A second mechanism here is how the GUI's label and the
        # run's actual target come to disagree.
        self.e2e_env_combo = QtWidgets.QComboBox()
        # `envrow`, NOT `_row`: this method already uses the module-level _row()
        # layout helper, and shadowing it with a loop variable turns every later
        # call into an UnboundLocalError that only fires when the page is built.
        for envrow in e2e_environments.describe():
            self.e2e_env_combo.addItem(envrow["label"], envrow["id"])
            self.e2e_env_combo.setItemData(
                self.e2e_env_combo.count() - 1,
                "%s\n\nRuns: make %s with %s=%s\nPins: %s\nStart it with: %s"
                % (envrow["note"], envrow["makeTarget"], e2e_environments.ENV_VAR,
                   envrow["id"], ", ".join(envrow["pins"]) or "<none>",
                   envrow["startHint"]),
                int(Qt.ItemDataRole.ToolTipRole))
        self.e2e_env_combo.setCurrentIndex(
            max(0, self.e2e_env_combo.findData(e2e_environments.DEFAULT_ENVIRONMENT)))
        self.e2e_env_combo.setToolTip(
            "Which mesh the e2e suite drives. The choice rides as "
            + e2e_environments.ENV_VAR
            + " on the run — the same channel a terminal uses — so the Studio and "
              "the CLI can never target different meshes. Nothing here STARTS a "
              "mesh: a scenario whose environment is not serving skips with a "
              "reason naming exactly what to run.")
        # currentIndexChanged, not activated: a programmatic change must re-gate
        # too. The handler only re-probes and edits a label — it opens NO modal,
        # because a QMessageBox from a selection handler hangs headless tests.
        self.e2e_env_combo.currentIndexChanged.connect(self._on_e2e_env_changed)
        brow.addWidget(QtWidgets.QLabel("e2e target:"))
        brow.addWidget(self.e2e_env_combo)
        # LABEL CHANGED 2026-08-26, and the reason is a real behaviour change worth
        # a name: this button used to run `make stack-e2e` — the 33 HANDWRITTEN
        # spec files — and now runs `make stack-e2e-bdd-env`, the GHERKIN lane.
        # That is the only lane that honours the environment chooser (world.ts's
        # per-scenario SNAP_ENV gate) and the only one that writes per-step
        # evidence, so a chooser bolted onto the old target would have been a
        # control that changed nothing. The handwritten specs did not go away;
        # they are still `make stack-e2e` from a terminal, and the tooltip says so
        # rather than leaving an operator to discover the swap.
        # THE E2E FEATURE TREE (operator ask 2026-08-26). This was "Run e2e suite":
        # one button that ran all 221 specs and went one colour, so nothing on this
        # page could answer "which feature broke?", "who was the failing persona?" or
        # "what does the suite even cover?". It now opens a TREE — Gherkin features,
        # spec files with their last verdicts, the personas each draws from, an
        # editable source pane and a screenshot browser — and the run is whatever the
        # operator CHECKS there.
        #
        # Its enablement is UNCHANGED and still owned by _sync_e2e_gate (test env +
        # stack up + seeded — live probes, never the form's un-applied selection),
        # because the thing behind it is still, ultimately, a run against the RUNNING
        # stack, and the blocker-listing tooltip is the only place those blockers are
        # ever named.
        self.e2e_btn = QtWidgets.QPushButton("e2e features…")
        self.e2e_btn.setEnabled(False)
        self.e2e_btn.clicked.connect(self._open_e2e_tree)
        brow.addWidget(self.e2e_btn)
        # The per-step evidence a run leaves behind, browsable per environment
        # and per interface. Always enabled: it READS a report dir, and its own
        # empty state names the command that would produce one — greying it on
        # "no stack" would hide the evidence of every past run.
        self.e2e_evidence_btn = QtWidgets.QPushButton("e2e evidence…")
        self.e2e_evidence_btn.setToolTip(
            "Browse the per-step evidence the Gherkin lane recorded: a screenshot "
            "for every browser step, a TRANSCRIPT (argv, stdout, the real exit "
            "code) for every cli step, and a Qt widget grab for every Studio step "
            "— grouped by environment and interface, with the manifest checked "
            "against the disk in both directions.")
        self.e2e_evidence_btn.clicked.connect(self._open_e2e_evidence)
        brow.addWidget(self.e2e_evidence_btn)
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
        # ── save the RUNNING mesh (ask C) ─────────────────────────────────────
        # Gated by _sync_saved_gate (this page's own `_mesh_up`, never a monitor
        # snapshot): a record of a mesh that is not running would describe
        # nothing. The copy-credentials box is OFF by default — the operator's
        # own wording was "credential pointers" — and the consequence of leaving
        # it off is stated in the table's "Restores as" column, not hidden.
        self.save_mesh_btn = QtWidgets.QPushButton("Save this mesh")
        self.save_mesh_btn.clicked.connect(self._save_mesh)
        brow.addWidget(self.save_mesh_btn)
        self.save_copy_creds = QtWidgets.QCheckBox(
            "Also copy its credential files into the record")
        self.save_copy_creds.setChecked(False)
        self.save_copy_creds.setToolTip(
            "OFF (default): the record keeps only POINTERS to .e2e-credentials and "
            "keys-out/vault/secrets.json (paths, hashes, mtimes) — no password ever "
            "enters the record. ON: both files are ALSO copied into the record's "
            "own folder under the Studio state dir at 0600, which is what brings "
            "the SAME accounts and passwords back after 'Stop && clean Docker' "
            "(the next 'Generate && start' re-mints them otherwise).")
        brow.addWidget(self.save_copy_creds)
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
        # ── the DevOps lane's OWN service selection (operator ask 2026-08-26) ──
        # Until this row existed, "Start DevOps lane" took no selection at all:
        # `make kind-up` passed KIND_PROFILE and MFA, so the curated Application
        # set could only be changed by editing bootstrap-kind.sh. These boxes ARE
        # live — they become KIND_ADDONS on the bring-up's env — which is what
        # separates them from the greyed argocd/workloadConsole rows in the
        # services table above (those name a lane; these drive one).
        #
        # They start at the LANE's shipped default (metrics-server ON), not at
        # off: the seven HPAs the lane deploys are already applied and already
        # ineffective without it, so an unticked default would render the broken state
        # as the normal one.
        self.kind_addon_boxes: dict[str, QtWidgets.QCheckBox] = {}
        for _addon in KIND_ADDONS:
            _box = QtWidgets.QCheckBox(_addon.label)
            _box.setChecked(_addon.default_on)
            _box.setToolTip(_addon.note + "  Applied by 'Start DevOps lane' "
                            "(KIND_ADDONS); the docker mesh above ignores it.")
            self.kind_addon_boxes[_addon.slug] = _box
            brow.addWidget(_box)
        self.devops_down_btn = QtWidgets.QPushButton("Delete DevOps lane")
        self.devops_down_btn.setToolTip(
            "Delete the local Kubernetes cluster. Destroys the DevOps lane ONLY "
            "— the docker mesh and every one of its volumes are untouched.")
        self.devops_down_btn.clicked.connect(self._devops_down)
        brow.addWidget(self.devops_down_btn)
        self.add_user_btn = QtWidgets.QPushButton("Add user…")
        self.add_user_btn.setToolTip(
            "Create a NEW named account on the RUNNING mesh (username, password, "
            "roles) through that lane's OWN seeder — never a bespoke Casdoor call, "
            "so the account is created by the machinery that created every other "
            "persona. On the docker mesh that is the idempotent `make stack-seed` "
            "with EXTRA_ROLE_USERS (registration stage 2 included); on the kind "
            "lane it is seed-accounts.sh --roles + apply-systems-roles.sh against "
            "the live Casdoor, exactly as bootstrap-kind.sh step 10 does, applied "
            "through the `make view LANE=kind-svc` casdoor door. Either way the "
            "identity is READ BACK from the mesh afterwards: the seeder's own exit "
            "code is not evidence. A mesh must be up (it says plainly if not).")
        self.add_user_btn.clicked.connect(self._add_user)
        brow.addWidget(self.add_user_btn)
        # No trailing addStretch: a FlowLayout has no stretch concept, and a
        # spacer item would be wrapped as if it were another button.
        lay.addWidget(brow_box)
        # LOCAL AI AGENT (#695). The Docker mesh and the kind DevOps lane end on this one
        # page, so one card serves both (its Lane drop-down only changes the brief). It
        # reads the source choice and domains at press time through the context callable;
        # the one hook is completeChanged, which fires at every verb start and end, so the
        # card's Lane follows the lane whose verb just ran (Start DevOps lane -> kind).
        self.local_agent = LocalAgentWidget(
            self.generator_dir, context=lambda: context_from_page(self))
        lay.addWidget(self.local_agent)
        self.completeChanged.connect(self.local_agent.refresh_apps)
        # The source cards too: the stepped wizard re-shows the card after the Repo
        # source step, but the single-page frame has no step change, so a changed
        # source choice there would keep listing the other tree's apps until Re-check.
        self.src_existing.toggled.connect(lambda _on: self.local_agent.refresh_apps())
        self.src_dir.textChanged.connect(lambda _t: self.local_agent.refresh_apps())

        # ── RUNNING-MESH MONITOR (operator ask, 2026-09-01): every pod and container
        # of BOTH lanes, its addresses, and an Open button only where the browser may
        # safely go. Collapsed by default and it STAYS that way — set_default_expanded
        # is deliberately not applied on "a mesh is running": the operator asked for
        # collapsed-by-default, and re-deriving the fold on every visit would fight
        # that. The section TITLE carries the answer while folded. Greyed (disabled,
        # empty) when neither lane runs; enabled and populated when either does —
        # `Collapsible` toggles setVisible only, so fold and grey compose.
        # scaling=True is the Replicas column (#333 item 4 / #341): −/+/Apply per pod
        # or container row, driving `docker compose up -d --scale` or `kubectl scale`
        # on the CONTROLLER behind the row. The kwarg alone would ship a knob whose
        # Apply emits into nothing (the widget refuses out loud in that case); the
        # receiver is _scale_monitor below, off-thread and one at a time, the same
        # shape MeshMonitorSection gives the two emulation screens.
        self.monitor = MeshMonitorWidget(self, scaling=True)
        self._monitor_title = "Running mesh — pods, addresses and doors"
        self.monitor_section = collapsible(self._monitor_title, self.monitor,
                                           expanded=False)
        self.monitor_section.toggle.toggled.connect(self._on_monitor_toggled)
        self.monitor.refresh_requested.connect(lambda: self._refresh_monitor("button"))
        self.monitor.open_requested.connect(self._open_door)
        self.monitor.view_up_requested.connect(self._view_up)
        self.monitor.view_down_requested.connect(self._view_down)
        self.monitor.scale_requested.connect(self._scale_monitor)
        # The kind lane's non-destructive stop and its undo (#356). They sit on the
        # monitor because this is the screen that reads BOTH lanes, and therefore the
        # screen an operator is on when they decide to stop something. Both go through
        # _launch, so the page's existing busy guard covers them: a halt racing a
        # bring-up is worse than either.
        self.monitor.halt_requested.connect(self._devops_halt)
        self.monitor.resume_requested.connect(self._devops_resume)
        #: Which row's scale is in flight ("" when none) — what _on_scale_done forgets.
        self._scaling_key = ""
        lay.addWidget(self.monitor_section)
        return w

    def _wire_plan_signals(self) -> None:
        """Live-refresh the plan preview from every control that feeds it.

        Called ONCE from __init__ after all eight sections are built. It has to be a
        method rather than a tail of one builder: the controls it connects are spread
        across six of them, and a builder that wired its own would be connecting a slot
        that reads widgets a later builder has not created yet."""
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
        # A hidden page owns no poll. showEvent below is the other half of the pair:
        # the FOLD STATE survives the visit, so a section the operator left open
        # must get its 10 s refresh back or it freezes on the page-entry read while
        # its own tooltip still promises "refreshed every 10 s".
        self._monitor_timer.stop()
        super().hideEvent(event)

    def _reclaim_sections(self) -> None:
        """Take back what THIS page shows: the bring-up block and the run view.

        Widget ownership only; NO probe runs here, so it is safe on every show. Qt calls
        initializePage only on a FORWARD visit, and the run view is CONTENDED — the
        join step and the review step claim it too — so the reclaim has to hang off a
        hook that fires both ways or a Back would leave the log on the page behind.
        Standalone (LocalMeshDialog) nothing ever moved and there are no steps, so
        every call below is a no-op.
        """
        self.take_section("bringup", self._body)
        self.take_section("run", self._body)
        self._hide_stepped_sections()

    def showEvent(self, event) -> None:                       # noqa: N802 (Qt)
        super().showEvent(event)
        # ONE showEvent on this class, deliberately: a second def further up the class
        # body would silently lose to this one (later def wins, no error anywhere), so
        # the section reclaim is a call from here rather than its own override.
        self._reclaim_sections()
        # The twin of hideEvent's stop (mesh_emulation.py:500-513 is the in-repo
        # precedent). Nothing else restarts the timer — _on_monitor_toggled only
        # fires on an actual fold change — so without this a revisited page shows a
        # visible, expanded, permanently frozen table.
        if getattr(self, "monitor_section", None) is not None \
                and self.monitor_section.is_expanded():
            self._monitor_timer.start()

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

    # ── the superbrand drop-down and its design (#654, D8) ───────────────────────
    def _brand_sync_in(self) -> None:
        """Copy onto the carrier what the record also says and the page alone owns: the
        environment, the typed domain and the Tor selection (the record reads them to
        derive its public name, its central sign-in and its Tor way), and refresh the
        session's cached copies of the two that are derived, so a design made on a test
        mesh and saved after the person switched to prod says the prod name."""
        c = self._brand_boot
        c.env = "prod" if self.env_prod.isChecked() else "test"
        c.cluster_domain = self.boot_domain.text().strip()
        c.with_tor = self.with_tor.isChecked()
        c.services = self.collect_services()
        s = self.superbrand_design.session
        if s is not None:
            sync_brand_session(s, c, explicit_signin=self._brand_explicit_signin)

    def _superbrand_block(self) -> dict:
        """The designed superbrand block ``collect_bootstrap`` hands the bring-up: the
        session's block without the things this page derives from its own controls.
        A Tor choice would be a second statement of the Tor tick (and the start refuses
        a record that contradicts the tick); a DERIVED sign-in address would go stale
        the day the environment or the domain changes. A sign-in address a saved mesh
        carried as its own choice is kept."""
        block = dict(self._brand_boot.superbrand or {})
        ways = {k: v for k, v in (block.get("ways") or {}).items() if k != "tor"}
        if ways:
            block["ways"] = ways
        else:
            block.pop("ways", None)
        if not self._brand_explicit_signin:
            block.pop("central_signin", None)       # derived: re-derived by whoever reads it
        return block

    def _fix_design_widgets(self) -> None:
        """Put back what this route fixes about the design after the session redrew it
        (every refresh re-enables its boxes). The public-name box is read-only: the
        mesh's public name has ONE editing home, the Domains step's first row (a test
        mesh has none), and a second box would be a setting editable in two places that
        could disagree. The sentence about what a design saves shows under an open one."""
        box = self.superbrand_design.fields["public_name"]
        box.setEnabled(False)
        box.setText("")
        box.setPlaceholderText(PUBLIC_NAME_HOME)
        box.setToolTip(f"The public name is {PUBLIC_NAME_HOME}.")
        # the sentence about what a design saves belongs under an OPEN design only
        s = self.superbrand_design.session
        self.brand_effect_note.setVisible(bool(s is not None and s.designing))

    def mount_brand(self) -> None:
        """Give the drop-down and the design their session. Called whenever a step
        claims the Environment section (and by the standalone dialog's page), so the
        session always describes the page as it is now; cheap and safe to repeat."""
        try:
            self._brand_sync_in()
            session = session_for(self, "docker", (self._brand_boot, self.mesh_domains),
                                  self.generator_dir)
            self._brand_busy = True
            try:
                if self.brand_picker.session is not session:
                    self.brand_picker.set_session(session)
                    self.superbrand_design.set_session(session)
                else:
                    self.brand_picker.refresh()
                    self.superbrand_design.refresh()
                self._fix_design_widgets()
                self._brand_mounted = True
            finally:
                self._brand_busy = False
            self._refresh_brand_note()
            self._brand_ok()
        except Exception:                       # noqa: BLE001 — never raise out of a slot
            self._brand_swallow("mount_brand")

    def _refresh_brand_note(self) -> None:
        """The note about a picked profile that has no brands/<id>.conf. It is redrawn
        whenever the pick can have changed (the plan refresh, the step mounting, the
        drop-down or the design changing), not only with the plan: a note drawn before
        the session existed would otherwise stay under the default Create."""
        brand = self.brand.currentText().strip()
        sess = self.superbrand_design.session
        # About a profile the person PICKED. Under ‘Create a new superbrand’ (the default)
        # nothing was picked, and a brand being designed has no profile file by
        # definition: the sentence there read as a warning about something they did not
        # choose.
        creating = sess is not None and sess.choice == CREATE_KEY
        # read the file, not self.boot: that object is built from the LAST plan refresh
        # and may still hold the brand from before this pick
        has_conf = os.path.isfile(os.path.join(self.generator_dir, "brands", f"{brand}.conf"))
        self.brand_note.setText(
            "" if creating or has_conf or not brand
            else f"No brands/{brand}.conf — runs with built-in defaults "
                 f"(profile presets stay unset).")
        self.brand_note.setVisible(bool(self.brand_note.text()))

    def _brand_changed(self, *_args) -> None:
        """The picker or the design changed the session: write it onto the carrier (the
        session refuses a record that cannot be saved and says why inline) and let the
        plan and the brand note follow."""
        if self._brand_busy or self.superbrand_design.session is None:
            return
        try:
            self._brand_sync_in()
            step = self.superbrand_design
            problems = step.session.commit()
            # a refusal is added to the step's note, never wiped by a good commit: the
            # design that just refused an id (and put its sentence there) commits the
            # id it fell back to without a problem
            if problems:
                step.note.setStyleSheet("color: #b00020;")
                step.note.setText(problems[0])
                step.note.setVisible(True)
            self._fix_design_widgets()
            self.brand.currentTextChanged.emit(self._brand_boot.brand)
            self._refresh_brand_note()
            self._brand_ok()
        except Exception:                       # noqa: BLE001
            self._brand_swallow("_brand_changed")

    def leave_brand(self) -> bool:
        """Leave the step (Next or Back), or reach the review: write the design onto the
        carrier and the record file. NEVER blocks: a refusal is shown inline by the
        design and the start refuses downstream; a page that refused its own Next would
        strand a person who cannot see why. An untouched session writes nothing."""
        if not self._brand_mounted or self.superbrand_design.session is None:
            return True
        try:
            self._brand_sync_in()
            problems = self.superbrand_design.commit(save=True)
            self.brand.currentTextChanged.emit(self._brand_boot.brand)
            self._brand_ok()
            # The design's own note sits under the drop-down, on a step the person has
            # just left. A refusal is also said on the plan they read before starting
            # (and here, for when they come back), so a record file that was not
            # written is never silent.
            sentence = ((self.superbrand_design.session.message or problems[0])
                        if problems else "")
            self._brand_file_note = sentence
            if sentence:
                self.brand_error.setText(sentence)
                self.brand_error.setVisible(True)
        except Exception:                       # noqa: BLE001
            self._brand_swallow("leave_brand")
        return True

    def _set_brand_id(self, text: str) -> None:
        """``self.brand.setCurrentText``: the text surface the old box had."""
        block = dict(self._brand_boot.superbrand or {})
        if not self._brand_explicit_signin:
            block.pop("central_signin", None)       # the carrier's one is derived
        self._adopt_brand(text, block)

    def _adopt_brand(self, brand: str, block: dict | None) -> None:
        """Make ``brand`` and the designed ``block`` this page's brand (a typed slug, a
        saved mesh applied). The carrier is REPLACED, not edited: the session belongs
        to the configuration object it was made for, so a new carrier gets a new
        session, which selects what the saved mesh carried."""
        brand = (brand or "").strip()
        self._brand_explicit_signin = str((block or {}).get("central_signin") or "")
        self._brand_boot = dataclasses.replace(
            self._brand_boot, brand=brand, superbrand=dict(block or {}))
        if self._brand_mounted:
            self.mount_brand()
        self.brand.currentTextChanged.emit(brand)

    def _brand_swallow(self, where: str) -> None:
        """A slot must never raise (PyQt6 aborts the process), so the failure is written
        to the terminal for whoever debugs it AND said once on the page, where the person
        is looking: they are never left with a half-drawn step and no word."""
        import sys
        import traceback
        print(f"localmesh: swallowed exception in {where}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        self.brand_error.setText(
            f"The {plain_words.term('superbrand')} step could not be drawn or saved just "
            "now, and nothing was changed by that. Go back one step and forward again; if "
            "it comes back, the details are in the terminal.")
        self.brand_error.setVisible(True)

    def _brand_ok(self) -> None:
        self.brand_error.setText("")
        self.brand_error.setVisible(False)

    def collect_bootstrap(self) -> LocalMeshBootstrapConfig:
        """BOOTSTRAP-tab widgets -> LocalMeshBootstrapConfig — EVERY operator-visible
        control, so none can silently do nothing (the silently-does-nothing-default class: ``brand``
        was declared on the config but never passed here, making the GUI strictly
        less capable than the CLI's ``--brand``)."""
        records = bootstrap_domain_records(self.mesh_domains.domains,
                                           self.mesh_domains.own_name)
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
            # the design's block, from the carrier the superbrand session writes (the one
            # writer of this field, so a design cannot be lost the way ``brand`` once was)
            superbrand=self._superbrand_block(),
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
            # ALWAYS a tuple, never None: this page HAS a picker for the DevOps
            # lane now, so its selection is explicit even when it equals the
            # lane's default. Byte-identity on the untouched path is preserved in
            # core instead (kind_addon_env exports nothing while the selection
            # matches what the lane ships) — the same split collect_services()
            # uses, and for the same reason.
            kind_addons=self.collect_kind_addons(),
            # THE DOMAINS (#494): the rows the Domains step recorded, and the names
            # whose sign-in is Own — derived from the same rows, so the Casdoor the
            # compose lane brings up and the row the operator sees cannot disagree.
            # Both are () on a flow that never touched the steps, or only clicked
            # Next through them (row 0 default-shaped is not recorded).
            domains=records,
            own_idp_domains=own_idp_names(self.mesh_domains.domains),
            # which of those rows were walked — what a saved-mesh Start gates on
            # (never a name that is not recorded, so () on an untouched flow)
            domain_services_reviewed=reviewed_record_names(self.mesh_domains, records),
        )

    def theme_form(self) -> dict:
        """The Themes group's INPUTS (colours, preset, mode, font, chrome) — what a
        saved-mesh record needs to re-populate widgets whose config field is
        DERIVED: ``login_theme_css`` is their output and is not invertible."""
        ns = types.SimpleNamespace()
        self.login_theme.commit(ns)
        return dict(vars(ns))

    def apply_bootstrap(self, cfg: LocalMeshBootstrapConfig,
                        form: dict | None = None) -> list[str]:
        """The exact inverse of :meth:`collect_bootstrap`: put ``cfg`` into the
        BOOTSTRAP tab's widgets. Returns the field NAMES it could not apply, for
        the caller to render inline (never a modal): ``auth_key`` always (never
        stored — the widget is left exactly as typed), ``services``/``kind_addons``
        when the record says None (no picker was used — the boxes keep their state,
        because None is not ()), a ``source_dir`` that no longer exists, an egress
        conf that moved, a theme with no form inputs, and the fields this page has
        no control for. Touches the bootstrap tab only, and refreshes the plan
        preview ONCE at the end — ``_refresh_plan`` returns early while
        ``_applying_bootstrap`` is set, so ~40 setters do not re-render it."""
        missing: list[str] = []
        self._applying_bootstrap = True
        try:
            (self.env_prod if cfg.env == "prod" else self.env_test).setChecked(True)
            # the id AND the designed block: the picker then shows what the saved mesh
            # carried (a design as the current superbrand, a profile as itself)
            self._adopt_brand(cfg.brand, cfg.superbrand)
            if cfg.source_mode == "existing":
                self.src_existing.setChecked(True)
            else:
                self.src_clone.setChecked(True)
            self.src_dir.setText(cfg.source_dir)
            if (cfg.source_mode == "existing" and cfg.source_dir
                    and not os.path.isdir(cfg.source_dir)):
                missing.append("source_dir")
            self.superadmin.setText(cfg.superadmin_username or "superadmin")
            # The two legacy booleans first (a CLI-made record with no picker),
            # then the explicit selection — which is authoritative — wins.
            self.social.setChecked(bool(cfg.social))
            self.with_tor.setChecked(bool(cfg.with_tor))
            if cfg.services is None:
                missing.append("services")
            else:
                chosen = set(cfg.services)
                for slug, box in self.service_boxes.items():
                    box.setChecked(slug in chosen)
            # The egress-vpn row only means anything with a valid conf behind
            # it (the fail-closed rule): re-validate the recorded PATH now.
            self._egress_vpn_conf = ""
            self.egress_note.setVisible(False)
            box = self.service_boxes.get("egress-vpn")
            if box is not None and box.isChecked():
                kind, err = validate_egress_conf(cfg.egress_vpn_conf)
                if err:
                    box.setChecked(False)
                    missing.append("egress_vpn_conf")
                    self.egress_note.setStyleSheet("color: #c62828;")
                    self.egress_note.setText(f"Egress VPN stays off — {err}")
                else:
                    self._egress_vpn_conf = cfg.egress_vpn_conf
                    self.egress_note.setStyleSheet("color: gray;")
                    self.egress_note.setText(
                        f"Egress VPN config: "
                        f"{os.path.basename(cfg.egress_vpn_conf)} ({kind}).")
                self.egress_note.setVisible(True)
            self.web_locales.setText(", ".join(cfg.web_locales))
            # THEME: the record's `form` carries the group's inputs; without them a
            # non-empty derived css cannot be reproduced, so the group is reset to
            # the shipped brand and the field is reported rather than half-applied.
            theme_ns = dict(_THEME_FORM_DEFAULTS)
            if form:
                theme_ns.update({k: v for k, v in form.items() if k in theme_ns})
            elif cfg.login_theme_css.strip():
                missing.append("login_theme_css")
            self.login_theme.load(types.SimpleNamespace(**theme_ns))
            idx = self.idp.findData(cfg.idp if cfg.idp in IDP_CHOICES else "casdoor")
            self.idp.setCurrentIndex(max(0, idx))
            self.idp_issuer.setText(cfg.idp_issuer)
            self.idp_client_id.setText(cfg.idp_client_id)
            self.idp_jwks.setText(cfg.idp_jwks)
            self.boot_domain.setText(cfg.cluster_domain)
            self.boot_login_server.setText(cfg.login_server)
            self._apply_domains(cfg)
            missing.append("auth_key")          # never stored; left as typed
            if cfg.kind_addons is None:
                missing.append("kind_addons")
            else:
                chosen = set(cfg.kind_addons)
                for slug, box in self.kind_addon_boxes.items():
                    box.setChecked(slug in chosen)
            for name in ("out_dir", "node_name"):
                if getattr(cfg, name):
                    missing.append(name)
        finally:
            self._applying_bootstrap = False
        self._refresh_plan()
        return missing

    def _apply_domains(self, cfg: LocalMeshBootstrapConfig) -> None:
        """The inverse of the domain fields ``collect_bootstrap`` emits: rebuild
        ``mesh_domains`` from the record (``core.local_mesh_domains.
        domains_from_bootstrap`` — row 0 the record's cluster domain or the brand
        default, then its rows, then any own-IdP name a CLI-made record carries
        alone). REVIEWED is what the record SAYS was reviewed
        (``domain_services_reviewed``), plus an unrecorded own domain — never every
        loaded row: a record can be written from a form with un-walked rows, or by
        the CLI with no rows at all, so the gate must still name those. A record
        carrying no domains leaves the state alone when the Domains step was never
        visited (the step seeds row 0 on its own visit), and otherwise resets it to
        the own row — so applying a pre-#494 record changes nothing about the
        gate."""
        md = self.mesh_domains
        loaded = domains_from_bootstrap(cfg)
        if loaded is None:
            if not md.domains:
                return
            own = cfg.cluster_domain.strip() or cfg.resolved_domain()
            loaded = LocalMeshDomains(domains=[Domain(name=own, title="")],
                                      domain_services_reviewed=[own], own_name=own)
        md.domains = loaded.domains
        md.own_name = loaded.own_name
        md.domain_services_reviewed = list(loaded.domain_services_reviewed)
        self.domains_table.fill(md.domains, md.own_name)
        # The stepper's working copy belongs to the rows it was seeded from. The rows
        # were just REPLACED under it, so re-seed it from them: otherwise the next
        # time the Domain services step records (Next or Back out of it) it writes
        # the old walk's ticks over the loaded ones and rebuilds the reviewed markers
        # from the old walk, un-reviewing every loaded row.
        self.domain_services.reload(md)
        self.domains_note.setVisible(False)
        self.boot_domain.setReadOnly(True)
        self.boot_domain_note.setVisible(True)

    def collect_kind_addons(self) -> tuple[str, ...]:
        """The ticked DevOps-lane add-ons, in catalogue order (never widget order).

        An EMPTY tuple is meaningful and is NOT None: it means the operator
        deliberately unticked everything, which core exports as the literal
        `none`. Collapsing the two would silently re-enable metrics-server."""
        return tuple(s for s in kind_addon_slugs()
                     if self.kind_addon_boxes[s].isChecked())

    def selected_idp(self) -> str:
        """The provider id behind the combo's current row (data role, never the
        display label — labels are free to change)."""
        return self.idp.currentData() or "casdoor"

    # ── worker plumbing (the no-freeze fix) ──────────────────────────────────────
    def _launch(self, label: str, fn, stream: bool = False,
                cancellable: bool = False, verb: str = ""):
        """Run one verb off the GUI thread; buttons + Exit re-arm on done.
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
            # NOT a silent return. This guard is correct — one verb at a time — but
            # saying nothing made a pressed button indistinguishable from a broken
            # one, and the buttons are re-armed only in _verb_done, so any verb that
            # never reaches it leaves every button on this page a no-op that reports
            # NOTHING. "I pressed Start and nothing happened" is then the only
            # symptom, with no line in the log and no status text to work from.
            busy = self._running_label or "a previous step"
            self.status.setText(
                f"Still running: {busy}. One verb at a time — its output is in the "
                f"log below. Wait for it to finish"
                + (", or press Cancel to stop it."
                   if self.cancel_btn.isVisible() else ".")
            )
            return
        if probe_running(self, "_scale_worker"):
            # The mirror of _scale_monitor's verb guard (issue #341): a verb that
            # rewrites the compose project or the cluster while a `--scale` / `kubectl
            # scale` is still running races it for the same container set. Said out
            # loud for the same reason the guard above is.
            self.status.setText(
                "Still running: a Replicas change in the running-mesh table. One "
                "action at a time on this mesh — wait for its result on that table's "
                "status line, then press again.")
            return
        self._running = True
        self._running_label = label
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
        # A BANKED LINE BELONGS TO THE RUN THAT WAS CURRENT WHEN IT WAS BANKED.
        # _drain_lines files every batch against _runs[-1], so anything still in
        # the inbox when a new run is appended is silently re-attributed to that
        # new run. Flush FIRST, while _runs[-1] is still the previous run, so a
        # straggler from any source lands on its own run (or, if there is none, in
        # the pane) rather than opening the next run's log with someone else's line.
        self._drain_lines()
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

    def _save_run_log(self, run, ok: bool) -> str:
        """Write this run's output to a file and return the path ("" on failure).

        WHY. Until now a verb's output lived ONLY in memory (_StageRun.buffer) and
        in the log pane. The Studio's own stdout goes to /dev/null under a desktop
        launcher, so when an operator reported "the DevOps lane fails" there was no
        artifact anywhere on disk to read — the report could not be acted on
        without asking them to reproduce it and copy the pane by hand. The verb had
        already run, at length, and its evidence was thrown away.

        Best-effort by construction: this is a GUI callback on the finish path, so
        it must never raise and must never be the reason a run reports failure.
        A path we could not write is simply not offered.

        PRIVATE BY CONSTRUCTION (#362). A verb's output can carry a secret (the
        seeder's persona password once did), so the directory is 0700 and each
        file 0600 — the default umask left both world-readable in the operator's
        home. Known secret shapes are also redacted on the way to disk
        (:func:`_redact_run_log`)."""
        try:
            d = os.path.join(state_dir(), "logs")
            os.makedirs(d, mode=0o700, exist_ok=True)
            # makedirs' mode only applies to a directory it CREATES; an existing
            # one from an earlier Studio is still 0755.
            os.chmod(d, 0o700)
            stamp = time.strftime("%Y%m%d-%H%M%S")
            safe = "".join(c if (c.isalnum() or c in "-_") else "-"
                           for c in (run.label or "verb")).strip("-") or "verb"
            path = os.path.join(d, f"{stamp}-{safe}-{'ok' if ok else 'FAILED'}.log")
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            os.fchmod(fd, 0o600)    # a pre-existing file keeps its old mode otherwise
            with os.fdopen(fd, "w", encoding="utf-8", errors="replace") as fh:
                fh.write(f"# {run.label} — {'succeeded' if ok else 'FAILED'}\n")
                fh.write("# %d line(s) retained (the pane's ring buffer keeps the last "
                         "%d)\n\n" % (len(run.buffer), _RUN_LOG_MAXLEN))
                for ln in _redact_run_log(run.buffer):
                    fh.write(ln + "\n")
            return path
        except Exception:
            return ""

    def _verb_done(self, ok: bool):
        self._running = False
        self._running_label = ""
        # FLUSH BEFORE SETTLING: up to one drain interval of output can still be
        # banked when the verb finishes, and those are exactly the lines that say
        # HOW it finished. Draining after _settle_run would file them under a run
        # already marked terminal; dropping them would lose the failure reason.
        self._drain_lines()
        self._drain.stop()         # same rule as the clock: an idle page owns no timer
        self._set_verbs_enabled(True)
        self.cancel_btn.setVisible(False)
        # Persist BEFORE the status text, so a failure can name the file it wrote.
        saved = self._save_run_log(self._runs[-1], ok) if self._runs else ""
        if saved:
            self._on_line(f"[log] this run was saved to {saved}")
            # DELIVER IT NOW, while _runs[-1] is still the run this notice is
            # ABOUT. _on_line only banks into _line_inbox, and the drain timer was
            # stopped a few lines above, so without this flush the notice sits in
            # the inbox until the NEXT verb restarts the timer — and _drain_lines
            # always files a batch against _runs[-1], which by then is a DIFFERENT
            # run. That is not theoretical: every one of the 5 saved logs in the
            # operator's corpus that carries a save notice opens with the PREVIOUS
            # run's filename, a perfect misattribution chain.
            self._drain_lines()
        if ok:
            self.status.setText("Done." + (f"  Log: {saved}" if saved else ""))
        else:
            self.status.setText(
                ("FAILED — see the log below; a copy is saved at " + saved)
                if saved else
                "FAILED (see log). NOTE: the run log could not be written to disk.")
        self._tick.stop()          # unconditionally: an idle page must own no clock
        self._settle_run(ok)
        self._refresh_status()
        try:
            self._refresh_code_folders()    # the verb may have created the checkouts
        except Exception:                   # noqa: BLE001 — never skip the re-read below
            pass
        # A verb is the one thing that CHANGES whether a mesh is up (start, stop,
        # clean), so re-read the real state rather than inferring it from the
        # verb's exit code — a partially-failed bring-up leaves containers behind
        # and "failed" would otherwise be recorded as "nothing is running".
        # …and mark the monitor STALE so that probe's answer re-reads it too,
        # collapsed or not (the section title must say what a just-finished
        # bring-up left running). This is what "populates right after generation
        # completes" without inventing a generation-completed signal: there is
        # none, and _probe_mesh_state is already the page's ONE "state changed,
        # re-read" entry point — the override point tests silence (`_probe_mesh_state =
        # lambda: None`) to keep a page quiet while they drive verbs. A second
        # background read started directly here ran behind that override point's back:
        # measured as three REAL `kubectl get` reads and a Qt abort at teardown
        # in two suites that never asked for a monitor.
        self._monitor_stale = True
        # …and the SAVED-MESH table with it. _sync_saved_gate (from
        # _set_verbs_enabled above) re-gates the 'Save this mesh' button, but the
        # table's own rows are read from things a verb changes and it does not
        # touch: 'Clean mesh' drops the data volumes a record's Start needs,
        # 'Restore (reseed)' rewrites the credentials file a record hashed, and a
        # bring-up creates both. Left unrefreshed, a row goes on offering a Start
        # whose volumes are gone — with the old blocked-reason tooltip to match —
        # until the operator leaves the page and comes back. It rides
        # _on_mesh_state for the same reason the monitor does: a re-scan started
        # directly here would go behind the `_probe_mesh_state = lambda: None`
        # override point the tests use to keep a page quiet while they drive verbs.
        self._saved_stale = True
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
        console.write(self.log, text)

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
            console.write(self.log, "\n".join(_display_safe(ln) for ln in batch))
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
            console.write(self.log, "\n".join(visible))

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
        # boot_start_btn carries its own "why am I disabled?" tooltip, so route it
        # through the one gate rather than the blanket loop above.
        self._sync_boot_gate()
        self._sync_e2e_gate()
        self._sync_saved_gate()

    # ── JOIN handlers ────────────────────────────────────────────────────────────
    def _refresh_status(self):
        """Kick off the JOIN-tab node probe, off the GUI thread.

        MeshNode.status() shells `docker compose ps` with a 30s timeout
        (core/mesh_node.py:135) and a hung daemon blocks for all of it. This ran INLINE
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
    def _refresh_code_folders(self):
        """Re-read the Code folders block from the current source choice and Domains
        table. Called from _refresh_plan AND when a verb finishes: 'Generate & start'
        runs make stack-clone, which creates the very folders this block reported as
        'not downloaded yet', and no form control changes when it does."""
        self.code_folders.refresh(self.boot.cfg.source_mode, self.boot.cfg.source_dir,
                                  self.mesh_domains.domains,
                                  own_name=self._own_domain_name(),
                                  record_id=getattr(self, "_loaded_record_id", "") or "")

    def _refresh_plan(self):
        if getattr(self, "_applying_bootstrap", False):
            return                      # apply_bootstrap refreshes once at its end
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
        # The code-folder rows follow the same source choice and the Domains table
        # (every path that changes either already lands here). Cheap: the widget
        # rebuilds only when the map differs.
        self._refresh_code_folders()
        self._refresh_brand_note()
        plan = self.boot.plan()
        note = getattr(self, "_brand_file_note", "")
        if note:
            plan += f"\n\nBRAND RECORD: {note}\n"
        self.plan_view.setPlainText(plan)
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
        # The front-door tooltip names the LIVE node's addresses, never a copy.
        try:
            self.open_web_btn.setToolTip(self._open_web_tooltip(self.boot._stack_node()))
        except Exception:                       # a stub node in a test has no ports
            pass
        # The monitor's snapshot rides this slot rather than initializePage: ONE read
        # when nothing has been read yet this visit (the kind lane can be up while
        # compose is down, and only a snapshot can say so), when the section is
        # open, when compose's answer disagrees with the last snapshot — up OR down
        # — while folded (so the title says what is up NOW), or when a verb just
        # ended (_monitor_stale). Re-entrant-safe —
        # a probe already out is left alone, and the stale flag then survives until
        # that probe finishes (see _on_monitor_finished).
        # `running` here is the COMPOSE-only answer, so it cannot speak for a kind
        # cluster coming up behind a folded section — re-read whenever the title
        # currently claims nothing runs, or it keeps asserting that after the mesh
        # is up (the two-lane case this feature was written for).
        # A verb just ended: re-scan the saved-mesh records and re-probe their
        # per-row facts. Disk only on this thread (a directory listing and small
        # JSON parses); the docker/git half rides the off-thread _saved_probe that
        # refresh() kicks off, exactly as it does on page entry.
        if self._saved_stale:
            self._saved_stale = False
            self.saved_meshes.refresh()
            # refresh() KEEPS the probe answers it already holds (so the table does
            # not flash back to "Checking…") and asks only for records it has never
            # seen — on its own it re-scans the DISK and re-probes nothing. The
            # per-row facts a verb changes (volumes, the credentials hash, a running
            # mesh) come from this explicit re-probe. When _mesh_up flipped,
            # _sync_saved_gate (via _set_verbs_enabled above) already started one
            # and the in-flight guard makes this a no-op; when it did not flip
            # (Clean with the mesh already down, a Restore that failed) this is
            # the only re-probe there is.
            self._probe_saved(self.saved_meshes.records())
        # `running` is the compose answer that just arrived. A folded title that
        # still names a mesh which a terminal `make stack-halt` (or a crash) took
        # down since the last read would otherwise keep its rows, its Open buttons
        # and "N/N ready" — with the page's own mesh-state line, two lines up,
        # saying "not running". Re-entering the page did not fix it either: the
        # re-entry read only fired for a title that claimed NOTHING runs.
        last = self._monitor
        compose_changed = (last is not None and running != bool(
            getattr(getattr(last, "compose", None), "running", False)))
        if (self._monitor_stale or last is None
                or self.monitor_section.is_expanded() or running
                or compose_changed
                or not bool(getattr(last, "any_running", False))):
            if self._refresh_monitor("mesh state"):
                self._monitor_stale = False
        self._sync_monitor_gate()

    def _sync_boot_gate(self):
        """Arm 'Generate && start' whenever no verb is already running.

        THERE IS NO ACKNOWLEDGEMENT ANY MORE. A tick-box reading "I understand this
        will MINT credentials and START containers on this machine" used to gate this
        button; it was removed on operator report. It restated the button's own label
        ("Generate && start"), sat under a read-only plan preview that already spells
        out exactly what an ``up`` generates and starts, and everything it warned
        about happens on THIS machine and is undone from this same page (Stop mesh /
        Stop && clean Docker). The three OTHER "I understand" boxes in Studio stay:
        deploy.py gates an APPLY against a real cloud account, and the two localcloud
        ones gate a k8s teardown — destructive or remote, neither reversible here.

        A disabled button that explains nothing still reads as "the app is broken",
        so the one remaining precondition (no verb already in flight) says so."""
        idle = not self._running
        self.boot_start_btn.setEnabled(idle)
        self.boot_start_btn.setToolTip(
            "Mint credentials and bring up the whole local mesh on THIS machine. On "
            "a cold box this also builds the maven prerequisites first, "
            "automatically. Undone from this page: 'Stop mesh' stops the containers "
            "and KEEPS the volumes (in prod it also detaches the overlay); 'Stop && "
            "clean Docker…' drops them."
            if idle else
            "Disabled while a verb is running — wait for it to finish, or Cancel.")

    def _domain_services_refusal(self) -> str:
        """"" when a mesh may start; otherwise the refusal naming every domain with no
        recorded service configuration (#495).

        A pure read through ``core.domain_services.gate_reason`` — the SAME override point the
        image-build gate calls — so the two paths cannot drift and a test can drive
        the refusal with a bare ImageConfig and no docker."""
        # THIS ROUTE'S OWN DOMAINS FIRST (#494): the rows the Domains step recorded,
        # with the remedy naming that step. A PURE READ: the Domain services step
        # records on the way out in BOTH directions (validatePage on Next,
        # cleanupPage on Back), and both start buttons live on later steps, so the
        # record is already written when this runs. Re-recording from the stepper
        # here was worse than redundant — after a saved mesh was loaded into the form
        # it rebuilt the reviewed markers from the stepper's OLD walk and refused the
        # loaded rows. Empty until the step is first visited — a host with no steps
        # keeps passing, exactly as before.
        md = getattr(self, "mesh_domains", None)
        if md is not None and md.domains:
            refusal = gate_reason(md, ACTION_MESH_START, remedy=LOCAL_MESH_REMEDY)
            if refusal:
                return refusal
        cfg = getattr(getattr(self, "wiz", None), "cfg", None)
        if cfg is None:
            return ""
        return gate_reason(cfg, ACTION_MESH_START)

    def _saved_domain_services_refusal(self, rec, cfg: LocalMeshBootstrapConfig) -> str:
        """"" when saved mesh ``rec`` (its config already parsed as ``cfg``) may
        start; otherwise the refusal naming every domain OF THE RECORD with no
        recorded service configuration.

        Reviewed = the record's own markers (``domains_from_bootstrap``), plus the
        form's markers for the record's names ONLY while the form holds this very
        record (``Load into the form`` sets ``_loaded_record_id``) — that is the
        remedy the refusal names: load it, walk the named domains, start it again.
        A draft's walk of some other mesh's rows never counts. Neither does the
        image flow's table (``wiz.cfg`` — a superadmin Domains table loaded on the
        Sessions screen): the record's config is what runs, so rows of an unrelated
        image-flow draft must not refuse it (#631 section 3). ``_bootstrap_up``,
        which starts the FORM's config, still gates that table."""
        md = domains_from_bootstrap(cfg)
        if md is None:
            return ""
        extra = self._saved_walk_extras(rec, md)
        md.domain_services_reviewed = list(md.domain_services_reviewed) + extra
        return gate_reason(md, ACTION_MESH_START, remedy=SAVED_MESH_REMEDY)

    def _saved_walk_extras(self, rec, md: LocalMeshDomains | None) -> list[str]:
        """The record's domains (``md`` — ``domains_from_bootstrap`` of its config)
        that the FORM walked but the record does not mark reviewed — counted only
        while the form holds this very record (``_loaded_record_id``); [] otherwise."""
        if md is None or getattr(self, "_loaded_record_id", None) != rec.id:
            return []
        names = set(md.names())
        return [n for n in self.mesh_domains.domain_services_reviewed
                if n in names and n not in md.domain_services_reviewed]

    def _heal_saved_record(self, rec, cfg: LocalMeshBootstrapConfig,
                           extras: list[str]) -> str:
        """Write the form's walk of ``extras`` into saved mesh ``rec`` — into
        ``cfg`` (what runs now, so ``boot.cfg`` and a later Save mesh carry it, and
        ``apply_bootstrap`` re-seeds the form WITH it) and into the record on disk
        (so the next Start, in this session or the next, passes on the record's own
        markers). Without this the remedy worked for one Start only: applying the
        record re-seeded the form's markers from the un-healed record (PR #595
        robustness skeptic, round 2).

        Best-effort, like every other record write: a failed write never refuses
        the Start the gate just allowed — it is said, inline, in the saved-meshes
        note. Returns that sentence ("" when the record was written)."""
        record_walk(cfg, self.mesh_domains, extras)
        rec.config["domains"] = [dict(r) for r in cfg.domains]
        rec.config["domain_services_reviewed"] = list(cfg.domain_services_reviewed)
        try:
            path = saved_meshes.save(rec)
        except (OSError, RuntimeError):
            path = ""
        named = ", ".join(extras)
        if path:
            self._note(f"[saved-mesh] recorded the service configuration of {named} "
                       f"into '{rec.label or rec.id}' -> {path}")
            return ""
        return (f" The service configuration walked for {named} could NOT be written "
                "into the saved record, so the next Start will ask for it again.")

    def _bootstrap_up(self):
        # THE PER-DOMAIN SERVICES GATE (#494/#495), on the docker/local-mesh half of
        # the operator's ask ("before building or starting a mesh in docker or nodes").
        # Same override point as the image-build gate on gui/pages/launch.py, same refusal
        # wording, and it lands in the same status line every other refusal on this
        # page uses — no modal, and the button stays enabled so the reason is readable
        # and actionable rather than a disabled control that explains nothing.
        #
        # The SAME gate guards Saved meshes -> Start/Restore (_start_saved): both
        # bring a docker mesh up on the same compose project from the same wiz.cfg.
        #
        # SCOPE, PLAINLY: this reads THIS route's Domains step (``mesh_domains`` —
        # row 0 the mesh's own domain, plus every added one) with a remedy naming
        # that step, and then ``wiz.cfg.domains`` — the superadmin Domains table of a
        # config loaded on the Sessions screen, or of a mesh flow the operator
        # stepped into the local-docker lane from. ``LocalMeshDialog`` has no wizard
        # at all, hence the getattr.
        # Rows that cannot be a domain first — the Domains step refuses them on Next;
        # this is the backstop for any other way they got here (the TUI's words, one
        # helper) — and only then the services gate, which is about the rows that
        # can: fixing a row may change which domains still need their page.
        row_problems = self._domain_row_problems()
        if row_problems:
            self.status.setText("Cannot start: domains: " + "; ".join(row_problems)
                                + " — fix them on the ‘Domains’ step.")
            return
        refusal = self._domain_services_refusal()
        if refusal:
            self.status.setText(refusal)
            return
        self.boot = LocalMeshBootstrap(self.generator_dir, self.collect_bootstrap())
        if self.login_theme.error_text():
            self.status.setText(
                "Cannot start: themes: " + self.login_theme.error_text())
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
        for ~95s on a hung daemon. A probe already in flight is left alone rather than
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
                          _E2EGateProbe(self.boot._stack_node(),
                                        environment=self.e2e_environment(),
                                        parent=self))
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
        # Kept so an OPEN feature tree's Run button can be gated by the same answer
        # (and named with the same sentences) as the page button's tooltip.
        self._e2e_blockers = list(problems)
        btn.setEnabled(not problems)
        btn.setToolTip(
            "Browse the e2e suite as a tree — Gherkin features, spec files with "
            "their last verdicts and skip reasons, the seeded personas each draws "
            "from, the source (editable), and the screenshots a run produced — then "
            "run the features you CHECK against the mesh named by the chooser to "
            "the left. Output streams below; a scenario whose environment or "
            "persona is unavailable SKIPS with its reason, and the final line "
            "reports passed/failed/skipped from the reporter's summary.json. "
            "Every step also leaves evidence — a screenshot, a transcript or a "
            "Qt widget grab — browsable with 'e2e evidence…'.\n\n"
            "The 33 HANDWRITTEN spec files are a separate lane and are not run "
            "by this button: `make stack-e2e` from a terminal."
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
        # REBUILD from the live widgets first, exactly like every docker verb
        # below does. self.boot is only refreshed by _refresh_plan, which the
        # DevOps add-on boxes deliberately do not drive (they say nothing about
        # the docker plan) — so without this line the lane would start with
        # whatever add-on selection the config happened to be holding, which is
        # the stale-selection bug this channel exists to remove.
        self.boot = LocalMeshBootstrap(self.generator_dir, self.collect_bootstrap())
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
        """DESTRUCTIVE — `kind delete cluster`. Confirms first, through the
        module-level ``confirm_devops_down`` override point, and the confirmation enumerates
        what goes and what stays rather than asking a generic "are you sure?" —
        a generic one is what makes operators click through. It also points at the
        non-destructive `Halt DevOps lane`, because most of the time that is what
        the operator actually wants and its absence is why this button was being
        pressed at all (#356)."""
        cluster = kind_cluster_name()
        answer = confirm_devops_down(
            self, _DEVOPS_DOWN_CONFIRM_TITLE,
            _DEVOPS_DOWN_CONFIRM_TEXT.format(cluster=cluster),
            DEVOPS_DOWN_OK | DEVOPS_DOWN_CANCEL, DEVOPS_DOWN_CANCEL)
        if answer != DEVOPS_DOWN_OK:
            self._note("[devops] cancelled — the cluster was NOT deleted.", queue=False)
            return
        node = self.boot._stack_node()
        self._note("[devops] deleting the local Kubernetes cluster (the docker "
                   "mesh and its volumes are untouched) …")
        self._launch("Deleting the DevOps lane",
                     lambda on_line, cancel: node.devops_down(on_line=on_line,
                                                              cancel=cancel),
                     stream=True, cancellable=True, verb="devops-down")

    # ── the NON-destructive stop (#356, decision 44 = a) ──────────────────────
    def _devops_halt(self):
        """`make kind-halt` — scale the mesh workloads to 0 AND suspend ArgoCD
        auto-sync. NOT destructive: the cluster, its volumes, its Vault KV and its
        Casdoor identities all stay, so this deliberately does NOT confirm. The
        streamed output is the point — it names every Application it suspended and
        the state each was in when it froze.

        CANCELLABLE, and safe to cancel — but only because of how kind-halt.sh is
        built. ``cancellable=True`` arms a Cancel that terminates the verb's whole
        process GROUP (local_stack_node.py:749-751), so the halt can stop between any
        two API calls. The script therefore writes its record BEFORE the first
        mutation: a cancelled halt leaves a cluster that Resume can fully undo and
        that a second Halt will finish, with the pre-halt replica counts intact.
        (Before that, cancelling was MORE destructive than letting it finish — the
        cluster ended up halted with no record of how to put it back.) The note below
        says so, because an operator deciding whether to press Cancel should not have
        to infer it."""
        node = self.boot._stack_node()
        self._note("[devops] halting the DevOps lane: suspending ArgoCD auto-sync "
                   "and scaling the mesh workloads to 0. NOTHING is deleted — the "
                   "cluster and its data stay, and Resume puts back exactly what "
                   "this suspends. Cancel is safe here: the record of what to undo "
                   "is written before the first change, so a cancelled halt can be "
                   "resumed or finished …")
        self._launch("Halting the DevOps lane",
                     lambda on_line, cancel: node.devops_halt(on_line=on_line,
                                                              cancel=cancel),
                     stream=True, cancellable=True, verb="devops-halt")

    def _devops_resume(self):
        """`make kind-resume` — put back exactly what the halt recorded. Never
        "everything": an Application suspended for another reason stays suspended."""
        node = self.boot._stack_node()
        self._note("[devops] resuming the DevOps lane: restoring the replica counts "
                   "and the auto-sync the halt recorded (anything suspended for "
                   "another reason stays suspended) …")
        self._launch("Resuming the DevOps lane",
                     lambda on_line, cancel: node.devops_resume(on_line=on_line,
                                                                cancel=cancel),
                     stream=True, cancellable=True, verb="devops-resume")

    # ── saved meshes (ask C): save / probe / start / load ─────────────────────
    def _sync_saved_gate(self):
        """The ONE writer for 'Save this mesh' and the saved-meshes table's gate,
        driven by this page's own tri-state ``_mesh_up`` — deliberately NOT by any
        monitor snapshot (that would couple two lanes for one boolean). Called
        from the tail of _set_verbs_enabled, which owns the greyed-with-a-reason
        idiom, and once at construction."""
        up = self._mesh_up
        idle = not self._running
        on = idle and up is True
        self.save_mesh_btn.setEnabled(on)
        self.save_copy_creds.setEnabled(on)
        if not idle:
            tip = "Disabled while a verb is running — wait for it to finish, or Cancel."
        elif up is None:
            tip = "Checking whether a local mesh is running…"
        elif up is False:
            tip = ("Disabled — no local mesh is running; there is nothing to save. "
                   "(Checked on entry; re-checked after every verb.)")
        else:
            tip = ("Record the RUNNING mesh so it can be started or restored from "
                   "the 'Saved meshes' table instead of generated from scratch: "
                   "THIS PAGE'S configuration (the only knob a running mesh can be "
                   "read back for is its env, which is cross-checked and reported "
                   "when it disagrees), the env it exports, the overlay text, the "
                   "per-repo source HEADs, the doors, the superadmin/operator "
                   "usernames and the accounts this Studio added (names and roles), "
                   "credential POINTERS (paths, hashes — never a password) and an "
                   "INVENTORY of its data volumes. The volumes' contents are NOT "
                   "saved: multi-GB, a consistent copy needs the stack halted, "
                   "'Stop mesh' keeps them anyway, and casdoor-pg is an identity "
                   "database. Runs off-thread; the mesh is not touched.")
        self.save_mesh_btn.setToolTip(tip)
        self.saved_meshes.set_context(mesh_up=up, busy=not idle)
        if idle and up is not None and up != self._saved_last_up:
            # a verb changed what is on disk — re-check every row's plan
            self._saved_last_up = up
            self._probe_saved(self.saved_meshes.records())

    def _probe_saved(self, records):
        """Kick off the off-thread per-record probe (docker volumes/images/ps + a
        git rev-parse per source repo). Re-entrant-safe: an in-flight probe is
        left alone rather than stacking threads."""
        recs = list(records or [])
        if not recs or probe_running(self, "_saved_probe"):
            return
        probe = own_probe(self, "_saved_probe", SavedMeshProbe(recs, parent=self))
        probe.result.connect(self._on_saved_probe)
        # AFTER own_probe's own `finished` handlers (which clear the attribute),
        # so the in-flight guard above is already False when this runs.
        probe.finished.connect(self._saved_probe_finished)
        probe.start()

    def _on_saved_probe(self, results):
        self.saved_meshes.apply_probe(results or {})

    def _saved_probe_finished(self):
        """A record saved (or scanned) WHILE a probe was out was skipped by the
        in-flight guard and would sit on "Checking…" until the next `_mesh_up`
        flip; ask again for exactly those."""
        pending = self.saved_meshes.unprobed()
        if pending:
            self._probe_saved(pending)

    def _save_mesh(self):
        """Record the running mesh — through _launch, so it inherits the busy
        guard, the staged view, the run log and the buttons' re-arm. The capture
        is docker + git + two sha256s and runs on the worker; nothing here touches
        the mesh. No credential VALUE reaches a log line: the worker prints the
        record id and path, and whether files were copied or only pointed at."""
        if self._mesh_up is not True:
            self.status.setText("Nothing to save: no local mesh is running "
                                "(checked on entry and after every verb).")
            return
        boot = self.boot
        node = boot._stack_node()
        gen = self.generator_dir
        copy = self.save_copy_creds.isChecked()
        users = list(self._added_user_specs)
        form = self.theme_form()

        # filled by the worker, read by _on_saved_captured on the GUI thread (the
        # done signal is what orders the two) — the disagreement belongs ON SCREEN,
        # under the table, not only in the run log the operator has to scroll back.
        outcome: dict = {}

        def capture(on_line, cancel):
            rec = saved_meshes.capture(gen, boot.cfg, node, boot,
                                       copy_credentials=copy, extra_users=users,
                                       form=form)
            path = saved_meshes.save(rec)
            if not path:
                on_line("[mesh-save] FAILED: the record could not be written under "
                        f"{saved_meshes.meshes_dir()} (is the Studio state dir "
                        "writable?). The mesh is untouched.")
                return False, []
            on_line(f"[mesh-save] saved '{rec.label}' as {rec.id} -> {path}")
            on_line(f"[mesh-save] {rec.volume_count()} data volume(s) inventoried, "
                    "not copied; credential files "
                    + ("copied into the record's folder at 0600" if copy else
                       "recorded as pointers only (paths, hashes, mtimes)"))
            # The record is built from THIS PAGE's configuration; the one knob that
            # can be read back off a running mesh is its env. When the two disagree
            # the record does not describe the mesh that is up, and a restore from
            # it would bring up the form's mesh instead — say so where the press
            # happened, not only in the JSON.
            for d in (rec.last_seen.get("disagrees_with_running") or []):
                line = (f"[mesh-save] WARNING: this page says {d['field']}="
                        f"{d['form']} but the running mesh reports "
                        f"{d['field']}={d['running']}. The record follows the page, "
                        "so restoring it brings up the page's mesh, not the one "
                        "running now.")
                on_line(line)
                outcome["warning"] = line.split("WARNING: ", 1)[1]
            return True, []

        before = self.worker
        self._note("[mesh-save] recording the running mesh …")
        self._launch("Saving mesh", capture, stream=True, cancellable=False, verb="")
        if self.worker is not None and self.worker is not before:
            # after _verb_done (connected first): the table re-scans the disk
            self.worker.done.connect(
                lambda ok, out=outcome: self._on_saved_captured(ok, out))

    def _on_saved_captured(self, _ok: bool, outcome: dict | None = None):
        self.saved_meshes.refresh()
        warning = str((outcome or {}).get("warning") or "")
        if warning:
            self.saved_meshes.set_note(warning)

    _NOT_APPLIED_WHY = {
        "auth_key": "auth key (never stored — re-enter it for a prod mesh)",
        "services": "services (saved without a picker selection — the boxes keep "
                    "their current state)",
        "kind_addons": "DevOps add-ons (saved without a selection — the boxes keep "
                       "their current state)",
        "source_dir": "source tree (the recorded directory no longer exists)",
        "egress_vpn_conf": "egress VPN config (the file moved or is invalid — the "
                           "egress-vpn row was unticked)",
        "login_theme_css": "theme (the record carries only the derived CSS — the "
                           "Themes group was reset to the shipped brand)",
        "out_dir": "out_dir (this page has no control for it)",
        "node_name": "node_name (this page has no control for it)",
    }

    def _not_applied_text(self, rec, missing: list[str]) -> str:
        label = rec.label or rec.id
        if not missing:
            return f"Loaded '{label}' into the form; every field applied."
        why = [self._NOT_APPLIED_WHY.get(m, m) for m in missing]
        return f"Loaded '{label}' into the form. Not applied: " + "; ".join(why) + "."

    def _load_saved(self, rec):
        cfg = LocalMeshBootstrapConfig.from_dict(rec.config)
        missing = self.apply_bootstrap(cfg, form=rec.form)
        # the form now holds THIS record's rows: a domain walked on the Domain
        # services step from here on counts for this record's Start (the saved-mesh
        # refusal's remedy — _saved_domain_services_refusal)
        self._loaded_record_id = rec.id
        self.saved_meshes.set_note(self._not_applied_text(rec, missing))

    def _start_saved(self, rec, mode: str):
        """Bring a saved mesh back. Case 1 (volumes + images present) runs
        ``boot.start_saved`` — ``stack.start()`` only, no re-mint, no re-seed.
        Case 2 (volumes gone) runs ``boot.restore`` — the up() sequence MINUS
        generate_creds, seeded from the record's pointers/copies. NEVER
        ``_bootstrap_up``: that re-mints secrets.json and invalidates the very
        record being restored. ``verb=""`` deliberately: verb_phases("up") draws a
        mint-and-seed ladder neither walks, and staging against it would render a
        ladder that never completes."""
        if self._running:
            self.status.setText(f"Still running: {self._running_label or 'a verb'}. "
                                "Wait for it to finish, or Cancel.")
            return
        if self._mesh_up is True:
            self.status.setText("A local mesh is running — stop it first. Starting "
                                "a saved mesh over a live one would bring up a "
                                "second stack on the same compose project.")
            return
        # THE PER-DOMAIN SERVICES GATE (#494/#495), SECOND DOOR. Saved meshes ->
        # Start/Restore brings a docker mesh up on the same compose project
        # _bootstrap_up does, so gating only _bootstrap_up would have left the
        # operator's ask ("before … starting a mesh in docker") satisfied by one
        # button and bypassed by the one next to it. Same override point, same status line,
        # and BEFORE apply_bootstrap so a refused click does not silently rewrite the
        # form on its way to doing nothing.
        #
        # It gates THE RECORD's domains — the record's config is what runs — never
        # the form's in-progress rows (PR #595 skeptics: a draft with two un-walked
        # domains refused Start of an unrelated record, while a CLI-made record's
        # own-IdP domains started with no services page ever shown).
        cfg = LocalMeshBootstrapConfig.from_dict(rec.config)
        refusal = self._saved_domain_services_refusal(rec, cfg)
        if refusal:
            self.status.setText(refusal)
            return
        # The gate passed on the form's walk of some of the record's domains: write
        # that walk INTO the record before the record is applied back over the form
        # (which would otherwise throw the walk away) — see _heal_saved_record.
        extras = self._saved_walk_extras(rec, domains_from_bootstrap(cfg))
        healed = self._heal_saved_record(rec, cfg, extras) if extras else ""
        missing = self.apply_bootstrap(cfg, form=rec.form)
        self.saved_meshes.set_note(self._not_applied_text(rec, missing) + healed)
        # The RECORD's config is what runs — never the form's re-collection,
        # which would turn a CLI-made record's services=None (profile defaults)
        # into whatever the boxes happen to hold, and an egress conf that moved
        # into a mesh silently started WITHOUT its VPN (validate() below refuses
        # that instead: fail-closed). The one field a record never carries comes
        # from the form: a prod restore needs the auth key the operator typed.
        cfg.auth_key = self.boot_auth_key.text().strip()
        self.boot = LocalMeshBootstrap(self.generator_dir, cfg)
        if self.login_theme.error_text():
            self.status.setText("Cannot start the saved mesh: themes: "
                                + self.login_theme.error_text())
            return
        problems = self.boot.validate()
        if problems:
            self.status.setText("Cannot start the saved mesh: " + "; ".join(problems))
            return
        boot = self.boot
        label = rec.label or rec.id
        if mode == saved_meshes.MODE_START:
            self._note(f"[saved-mesh] starting '{label}' — reattaching its data "
                       "volumes; nothing is re-minted or re-seeded …")
            self._launch(f"Starting saved mesh {label}",
                         lambda on_line, cancel: boot.start_saved(
                             rec, on_line=on_line, cancel=cancel),
                         stream=True, cancellable=True, verb="")
        else:
            self._note(f"[saved-mesh] restoring '{label}' — bringing the stack up "
                       "and seeding it again; credentials are NOT re-minted …")
            self._launch(f"Restoring saved mesh {label}",
                         lambda on_line, cancel: boot.restore(
                             rec, on_line=on_line, cancel=cancel),
                         stream=True, cancellable=True, verb="")

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

    def _open_e2e_tree(self):
        """Open the e2e feature tree. The catalogue is built OFF-THREAD.

        load_catalogue shells `npx playwright test --list` and walks every spec source
        — a subprocess with a 180s ceiling. Building it inline would freeze the window
        on the very click meant to open a browser, which is the defect _E2EGateProbe
        and _StatusProbe already exist for on this page; this is the same shape.

        A probe already in flight is left alone rather than stacking `npx` processes.
        """
        if probe_running(self, "_e2e_cat_probe"):
            self.status.setText("Still enumerating the e2e suite — one moment.")
            return
        self.status.setText(
            "Enumerating the e2e suite (asking Playwright for the spec list; this "
            "works with the stack down) …")
        probe = own_probe(self, "_e2e_cat_probe",
                          _E2ECatalogueProbe(
                              self.generator_dir,
                              env=self.boot._stack_node()._build_env(
                                  write_overlays=False),   # a catalogue READS
                              parent=self))
        probe.result.connect(self._show_e2e_tree)
        probe.start()

    def _show_e2e_tree(self, catalogue):
        """The catalogue arrived (GUI thread): put the tree on screen.

        NON-MODAL, deliberately. A run started from the tree streams into THIS page's
        log, and a modal would sit on top of the thing the operator needs to watch.
        `accepted` carries the selection back, so the dialog is also drivable by a
        headless test without exec() ever being called (house rule).
        """
        from .e2e_tree_dialog import E2ETreeDialog
        # The gate's own blockers, so the tree's Run button can never be armed for a
        # stack that cannot host the suite — and NAMES them when it is not, which is
        # the same contract the page button's tooltip carries.
        blockers = list(self._e2e_blockers)
        # A previous tree is CLOSED and destroyed first. These are parented to the
        # page, so rebinding the attribute alone would leak the old dialog for the
        # life of the page (own_probe's docstring documents exactly this trap for
        # QThreads; a QDialog child is the same object graph).
        old = getattr(self, "_e2e_dialog", None)
        if old is not None:
            old.close()
            old.deleteLater()
        dlg = E2ETreeDialog(catalogue, self.generator_dir, blockers=blockers,
                            parent=self)
        self._e2e_dialog = dlg              # held: a local would be collected
        dlg.accepted.connect(lambda: self._run_e2e(dlg.run_specs))
        dlg.show()
        self.status.setText(
            f"e2e feature tree: {len(catalogue.features)} spec file(s), "
            f"{len(catalogue.tests)} test(s). Check what to run.")

    def _run_e2e(self, specs=()):
        """Run the SELECTED e2e specs against the RUNNING stack. The gate is re-probed
        here (and again inside run_e2e) because enablement can go stale the
        moment the stack changes underneath the page.

        ``specs`` is the tree's selection — Playwright positional filters, already
        validated by e2e_catalogue.safe_spec_args. It is passed THROUGH to run_e2e,
        which puts it in the spawned `make` argv. An empty tuple runs the whole suite
        and is only reachable from a caller that never made a selection: the tree
        refuses an empty selection rather than falling back to everything.
        """
        node = self.boot._stack_node()
        env_id = self.e2e_environment()
        problems = node.e2e_ready(env_id)
        if problems:
            self.status.setText("Cannot run e2e: " + "; ".join(problems))
            self._sync_e2e_gate()
            return
        plan = e2e_environments.plan(env_id)
        specs = tuple(specs or ())
        target = (node.web_url if env_id == "docker"
                  else plan.env.get(e2e_environments.BASE_URL_VAR, env_id))
        self._note(f"[e2e] running the Gherkin suite against the {env_id} mesh "
                   f"({target}) — {e2e_environments.ENV_VAR}={env_id}, "
                   f"make {plan.make_target} …")
        self._note("[e2e] selection: "
                   + (", ".join(specs) if specs
                      else "none — the WHOLE suite"))
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
        self._launch(f"Running the e2e suite ({env_id})",
                     lambda on_line, cancel: node.run_e2e(extra_env=bridge,
                                                          on_line=on_line,
                                                          cancel=cancel,
                                                          environment=env_id,
                                                          specs=specs),
                     stream=True, cancellable=True, verb="e2e")

    def e2e_environment(self) -> str:
        """Which mesh the e2e chooser currently names. Falls back to the default
        (docker — what an unset SNAP_ENV has always meant) when the combo has not
        been built yet, so a caller during construction cannot crash the page."""
        combo = getattr(self, "e2e_env_combo", None)
        if combo is None:
            return e2e_environments.DEFAULT_ENVIRONMENT
        return combo.currentData() or e2e_environments.DEFAULT_ENVIRONMENT

    def _on_e2e_env_changed(self, *_a):
        """The chooser moved: re-gate and say what the new target means.

        NO MODAL HERE. This is a selection handler, and a QMessageBox/exec() in
        one wedges every headless test — the same rule that keeps them out of
        validatePage. Everything it has to say goes into the status label and
        the button tooltip.
        """
        env_id = self.e2e_environment()
        try:
            plan = e2e_environments.plan(env_id)
        except ValueError as exc:
            self.status.setText(str(exc))
            return
        self.status.setText(
            "e2e target: %s — the run will be launched as %s=%s make %s. "
            "Nothing here starts that mesh; if it is not serving, every scenario "
            "pinned to it skips with a reason. Start it with: %s"
            % (env_id, e2e_environments.ENV_VAR, env_id, plan.make_target,
               plan.start_hint))
        self._sync_e2e_gate()

    def _open_e2e_evidence(self):
        """Open the per-step evidence browser.

        exec() is legitimate HERE and only here: this is a BUTTON CLICK, not
        page logic — nothing headless is waiting on a validatePage or an
        itemChanged to return. Held on self so the wrapper is not collected
        while the dialog is up (the _open_vaults precedent above)."""
        from ._e2e_evidence_dialog import E2EEvidenceDialog
        self._e2e_evidence_dialog = E2EEvidenceDialog(
            self, generator_dir=getattr(self.wizard(), "generator_dir", "") or "")
        self._e2e_evidence_dialog.exec()

    def _open_web_ui(self):
        QtGui.QDesktopServices.openUrl(
            QtCore.QUrl(self.boot._stack_node().web_url))

    @staticmethod
    def _open_web_tooltip(node) -> str:
        """The Open web UI tooltip, from the node's OWN addresses — so it can never
        again name a door the button does not open."""
        return (f"Open the running stack's front door ({node.web_url}) in your "
                f"browser — TLS, under the per-machine CA in tests/stack/.tls-front/"
                f"ca.crt (import it once, or accept the warning). The same platform "
                f"is also served in plaintext at {node.plain_web_url}. Does nothing "
                f"destructive; if the stack is down the browser just shows a "
                f"connection error.")

    # ── running-mesh monitor ─────────────────────────────────────────────────────
    def _sync_monitor_gate(self):
        """The ONE writer of setEnabled on self.monitor, of its note and of the
        section title (the build.py:_sync_iso_options rule). Tri-state: unknown is
        "checking…", never "no mesh"; a failed read clears the rows and says so —
        showing stale rows as current is the failure this monitor exists to fix."""
        mon = getattr(self, "monitor", None)
        if mon is None:
            return
        snap = self._monitor
        title = self._monitor_title
        if snap is None:
            mon.setEnabled(False)
            mon.clear()
            if probe_running(self, "_monitor_probe") or self._mesh_up is None:
                note = "Checking what is running…"
            else:
                note = ("Not read yet — expand this section or press Refresh "
                        "(re-checked after every action).")
            mon.note.setText(note)
            mon.setToolTip(note)
            self.monitor_section.toggle.setText(f"{title} — checking…".replace("&", "&&"))
            return
        ready, total = snap.ready_counts
        lanes = (f"compose {self._lane_word(snap.compose)} · "
                 f"kind {self._lane_word(snap.kind)}")
        if self._running:
            mon.setEnabled(snap.any_running)
            # The note and the title below quote THIS snapshot, so the rows must come
            # from it too. A verb-time Refresh (the widget's own button stays live
            # while a verb runs) used to leave the previous read's rows on screen
            # under a note saying nothing is running — stale rows shown as current,
            # the exact failure this monitor exists to fix.
            if snap.any_running:
                mon.render(snap)
            else:
                mon.clear()
            note = (f"Paused while {self._running_label or 'the verb'} runs — "
                    f"refreshed when it finishes. Last read {snap.taken_at}: "
                    f"{ready}/{total} ready · {lanes}.")
            mon.note.setText(note)
            mon.setToolTip(note)
            self.monitor_section.toggle.setText(
                f"{title} — paused ({ready}/{total} ready)".replace("&", "&&"))
            return
        if snap.any_running:
            mon.setEnabled(True)
            mon.render(snap)
            note = f"{ready}/{total} ready · {lanes} · read {snap.taken_at}."
            extra = list(snap.errors) + list(snap.notes)
            if extra:
                note += "\n" + " ".join(extra)
            mon.note.setText(note)
            mon.setToolTip("Refreshed every 10 s while this section is open, and "
                           "after every action.")
            self.monitor_section.toggle.setText(
                f"{title} — {ready}/{total} ready".replace("&", "&&"))
        elif snap.any_unknown:
            # the last read could not ESTABLISH a lane: rows cleared, the exact
            # sentences shown. Unknown is never rendered as "no mesh" (I5), even
            # when the read carried no error sentence — the lane's own detail
            # says what was (not) asked.
            mon.setEnabled(False)
            mon.clear()
            why = " ".join(snap.errors) or " · ".join(
                f"{name}: {lane.error or lane.detail or 'not established'}"
                for name, lane in (("kind", snap.kind), ("compose", snap.compose))
                if lane.running is None)
            note = "Could not read the running mesh: " + why
            mon.note.setText(note)
            mon.setToolTip(note)
            self.monitor_section.toggle.setText(
                f"{title} — could not read".replace("&", "&&"))
        else:
            mon.setEnabled(False)
            mon.clear()
            note = ("No mesh is running. Generate one, or start the DevOps lane, "
                    "and this fills in.")
            if snap.errors or snap.notes:
                note += " " + " ".join(list(snap.errors) + list(snap.notes))
            mon.note.setText(note)
            mon.setToolTip(note)
            self.monitor_section.toggle.setText(
                f"{title} — nothing running".replace("&", "&&"))

    @staticmethod
    def _lane_word(lane) -> str:
        if lane.running is None:
            return "not established"
        return "up" if lane.running else "down"

    def _refresh_monitor(self, reason: str = "") -> bool:
        """Kick off ONE off-thread snapshot (see _MonitorProbe). Re-entrant-safe: a
        probe already in flight is left alone rather than stacking threads. The 10 s
        tick is the only caller that stands down while a verb runs — a button press
        or a mesh-state answer still reads. Returns True when a read was started
        (or a synthetic one produced), False when one was already in flight."""
        if probe_running(self, "_monitor_probe"):
            return False
        if reason == "tick" and self._running:
            return False
        try:
            node = self.boot._stack_node()
        except Exception as e:                  # a page mid-teardown, or a bad config
            self._monitor = mesh_monitor.MonitorSnapshot(
                taken_at=time.strftime("%H:%M:%S"),
                compose=mesh_monitor.LaneState(None, error=str(e)),
                kind=mesh_monitor.LaneState(None, error=str(e)),
                errors=(f"no stack node to ask: {type(e).__name__}: {e}",))
            self._sync_monitor_gate()
            return True
        probe = own_probe(self, "_monitor_probe",
                          _MonitorProbe(self.generator_dir, node, parent=self))
        probe.result.connect(self._on_monitor)
        # own_probe connected its release FIRST, so by this slot the attribute is
        # clear and a follow-up read can start.
        probe.finished.connect(self._on_monitor_finished)
        probe.start()
        self._sync_monitor_gate()
        return True

    def _on_monitor_finished(self):
        """A verb ended while a read was in flight: that read may predate the verb's
        effect, so exactly one fresh read follows it."""
        if self._monitor_stale and self._refresh_monitor("post-verb"):
            self._monitor_stale = False

    def _on_monitor(self, snap):
        """The snapshot arrived (GUI thread): render through the one gate, and arm
        exactly one of the view-door buttons from the LIVE session answer."""
        self._monitor = snap
        # the live-doors answer was read off-thread with the snapshot (a session-file
        # read plus a TCP connect per door is I/O, and this slot is on the GUI thread)
        self.monitor.set_view_session(bool(getattr(snap, "view_doors", ())),
                                      lane=str(getattr(snap, "view_lane", "") or ""))
        # Halt/Resume are armed from the KIND lane's tri-state, not from a boolean and
        # not from this page's `_mesh_up` (which answers COMPOSE only — invariant I11).
        # running is None means the census could not be taken, and that must grey the
        # controls with a reason rather than offering them (I5).
        _kind = getattr(snap, "kind", None)
        # halted is the SECOND tri-state and is read off the same snapshot: a halted
        # lane still reports running=True, so without it Halt is offered on a lane
        # that is already halted (#356). None means the record could not be read,
        # which is not 'not halted' — the widget leaves both offered and says so.
        self.monitor.set_kind_lane(getattr(_kind, "running", None),
                                   str(getattr(_kind, "error", "") or
                                       getattr(_kind, "detail", "") or ""),
                                   halted=getattr(_kind, "halted", None))
        self._sync_monitor_gate()

    def _on_monitor_toggled(self, on: bool):
        """Expanding refreshes once and starts the poll; collapsing stops it. Fires on
        programmatic setChecked too, so it must be (and is) re-entrancy-safe."""
        if on:
            self._refresh_monitor("expanded")
            self._monitor_timer.start()
        else:
            self._monitor_timer.stop()

    def _on_monitor_tick(self):
        if not (self.isVisible() and self.monitor_section.is_expanded()):
            return
        if self._running:
            self._sync_monitor_gate()           # the note says "paused"
            return
        if probe_running(self, "_monitor_probe"):
            return
        self._refresh_monitor("tick")

    def _scale_monitor(self, key: str, replicas: int) -> None:
        """Apply on a Replicas row: run ONE ``mesh_monitor.scale`` off the GUI thread.

        ``MeshMonitorSection._scale`` for this page (issue #341 — copied, not
        re-derived, per the issue's own instruction), plus the one rule the Section
        has no notion of: this page runs mesh VERBS (start / stop / clean / seed),
        and a ``docker compose up --scale`` racing a ``make stack-up`` against the
        same project is the same container-set race the widget's busy guard exists
        to stop. So a scale is refused, out loud, while a verb runs — and
        ``_launch`` refuses a verb while a scale runs. A pressed button that does
        nothing is this repo's named failure mode, so each refusal names itself
        somewhere the operator is already looking.

        Two guards, two different signals: ``probe_running(self, "_scale_worker")``
        is the one-at-a-time hold (a second Apply already in Qt's queue when the
        first latched lands here, so the disabled buttons alone are not enough) —
        it returns quietly because the widget is ALREADY saying "Scaling … to N…"
        on the inline line with every strip disabled, same as ``Section._scale``;
        ``self._running`` is the verb hold, and it writes its own sentence because
        nothing on the table says a verb is running.
        """
        if probe_running(self, "_scale_worker"):
            return
        if self._running:
            busy = self._running_label or "a previous step"
            self.monitor.set_scale_status(
                f"Not scaled: {busy} is still running. One action at a time on this "
                f"mesh — wait for it to finish, then press Apply again.")
            return
        snap = self._monitor
        unit = None
        for u in (snap.units if snap is not None else ()):
            if u.key == key:
                unit = u
                break
        if unit is None:
            self.monitor.set_scale_status(
                "That row is no longer in the last read — press Refresh and try again.")
            return
        try:
            node = self.boot._stack_node()
        except Exception as e:                  # a bad config, not a crash
            self.monitor.set_scale_status(f"Cannot scale: {type(e).__name__}: {e}")
            return
        self._scaling_key = key
        self.monitor.set_scale_busy(
            True, f"Scaling {unit.scale.describe()} to {replicas}…")
        worker = own_probe(self, "_scale_worker",
                           MeshScaleWorker(self.generator_dir, node, unit, replicas))
        worker.done.connect(self._on_scale_done)
        worker.start()

    def _on_scale_done(self, ok: bool, text: str) -> None:
        """The scale finished (GUI thread): release the busy guard with its answer on
        the inline line, and re-read — the count the table shows comes from the ROWS,
        so it only moves once the lanes are read again."""
        key, self._scaling_key = self._scaling_key, ""
        if key:
            self.monitor.forget_scale_target(key)
        self.monitor.set_scale_busy(False, text)
        self._refresh_monitor("post-scale")

    def _open_door(self, url: str):
        """A row's Open button. The URL was gated twice already (core + widget); a
        third refusal here is belt-and-braces, and the status line says why."""
        why = mesh_monitor.unsafe_door_reason(url)
        if why:
            self.status.setText(f"Not opened: {why}")
            return
        QtGui.QDesktopServices.openUrl(QtCore.QUrl(url))

    def _view_up(self):
        """`make view` in the background — the sanctioned browser door. Opt-in, one
        press, never automatic: it binds loopback ports on this machine. The lane
        follows what is running (kind's host shell, else the compose front doors)."""
        snap = self._monitor
        if snap is not None:
            lane = ("compose" if (not bool(snap.kind.running)
                                  and bool(snap.compose.running)) else "kind")
        else:
            # no snapshot yet (the footer button pressed before the first read
            # answered): the page's own compose-only answer is all there is, and
            # "kind" for a machine with only compose up would bind a door to a
            # cluster that does not exist
            lane = "compose" if self._mesh_up is True else "kind"
        node = self.boot._stack_node()
        self._note(f"[view] serving the {lane} lane's front doors on 127.0.0.1 "
                   f"(`make view LANE={lane}`; run `make view-trust` once per machine "
                   f"so the browser trusts the loopback CA) …")
        self._launch("Opening the browser door",
                     lambda on_line, cancel: node._make(
                         "view", timeout=120, on_line=on_line, cancel=cancel,
                         args=[f"LANE={lane}"]),
                     stream=True, cancellable=True)

    def _view_down(self):
        node = self.boot._stack_node()
        self._note("[view] stopping the background view session (`make view-stop`) …")
        self._launch("Stopping the browser door",
                     lambda on_line, cancel: node._make(
                         "view-stop", timeout=60, on_line=on_line, cancel=cancel),
                     stream=True)

    def _show_credentials(self):
        """Probe first, modal from the SLOT (_on_credentials) — never inline.

        Opened from the bring-up row rather than popped automatically after a
        successful `up`: the operator often wants it again later (a second browser,
        a different role) and a one-shot toast would be gone by then. Everything
        is gathered fresh on each press (the CURRENT checkout, the same env the
        Studio hands `make stack-seed`, and the mesh that is running NOW), on a
        _CredsProbe thread. A press while one is in flight is a no-op: its answer
        is coming, and a second probe would only stack a second dialog."""
        if probe_running(self, "_creds_probe"):
            return
        self.creds_btn.setEnabled(False)
        self.creds_btn.setText("Sign-in credentials (checking…)")
        probe = own_probe(self, "_creds_probe",
                          _CredsProbe(self.boot, self.generator_dir,
                                      added=self._added_users_ok, parent=self))
        probe.result.connect(self._on_credentials)
        probe.start()

    def _on_credentials(self, payload):
        """The _CredsProbe result slot: re-arm the button, publish the one-line
        truth on the mesh-state line, then open the dialog. A modal opened from a
        slot that a BUTTON started is still button-driven — nothing here runs from
        validatePage or itemChanged."""
        self.creds_btn.setText("Sign-in credentials")
        self.creds_btn.setEnabled(True)
        roster, truth = payload
        if truth is not None:
            # The mesh-state line gains the seed truth as a second sentence, so
            # the page states it without the dialog. A previous headline is
            # replaced, never stacked; _on_mesh_state's next rewrite drops it,
            # which is right — that probe ran after a verb changed the mesh.
            base = self._mesh_state_label.text()
            prev = getattr(self._cred_truth, "headline", "")
            if prev and base.endswith(prev):
                base = base[:-len(prev)].rstrip()
            self._mesh_state_label.setText(f"{base} {truth.headline}".strip())
        self._cred_truth = truth
        # Held on self so the wrapper is not collected while the dialog is up.
        self._creds_dialog = CredentialsDialog(
            roster, truth, front_door=self.boot._stack_node().web_url, parent=self)
        self._creds_dialog.exec()

    def _add_user(self):
        """Add ONE named user to the RUNNING mesh — on EITHER lane (#540).

        The dialog is the same on both: username, roles, password. What differs is
        the APPLY, because the two lanes seed differently and neither may be driven
        with the other's seeder:

          * COMPOSE — re-run the idempotent seeder with EXTRA_ROLE_USERS appended
            (``make stack-seed``, seed-accounts.sh's additive door);
          * KIND — render with ``seed-accounts.sh --roles`` and apply
            ``roles/apply-systems-roles.sh`` against the live Casdoor, which is what
            bootstrap-kind.sh step 10 does (``core/kind_seed``).

        Neither is a bespoke Casdoor call: the account is created by exactly the
        machinery that created every other persona on its lane. The FULL spec list
        is re-rendered in both cases, because apply-systems-roles.sh sets each
        role's members to EXACTLY the rendered list — a single-user render would
        wipe every other persona's memberships.

        The lane is decided in the WORKER (``stack.status()`` is blocking), never
        here."""
        dlg = AddUserDialog(self.generator_dir, parent=self)
        if dlg.exec() != QtWidgets.QDialog.DialogCode.Accepted:
            return
        spec, pw_env, password = dlg.result_spec()
        uname = spec.split(":", 1)[0]
        self._added_user_specs = [s for s in self._added_user_specs
                                  if s.split(":", 1)[0] != uname]
        self._added_user_specs.append(spec)
        # E2E_PASSWORD_KEEP=1: `make stack-seed` STARTS a run and would mint a new
        # shared password (tests/stack/e2e-password.sh) — re-passwording every
        # persona already on this mesh just to add one account. Keep the run's.
        env = {"EXTRA_ROLE_USERS": " ".join(self._added_user_specs),
               "E2E_PASSWORD_KEEP": "1"}
        if password:
            env[pw_env] = password          # env-only — never argv, never logged
        stack = self.boot._stack_node()
        roles = tuple(r for r in spec.split(":")[1].split(",") if r) \
            if spec.count(":") >= 2 else ()

        def _seed(on_line, cancel):
            try:
                compose_up = bool(stack.status().running)
            except Exception:               # docker absent: not a compose mesh
                compose_up = False
            if compose_up:
                ok, msg = stack.seed(env, on_line=on_line, cancel=cancel)
            else:
                ok, msg = self._add_user_kind(uname, roles, pw_env, password,
                                              stack, on_line)
            if ok:
                # Runs on the worker thread; a plain list swap under the GIL, read
                # on the GUI thread only at the next credentials press. Name and
                # roles ONLY — the password went to the seeder's env and is gone.
                self._added_users_ok = [u for u in self._added_users_ok
                                        if u[0] != uname] + [(uname, roles)]
            return ok, msg

        self._note(f"[add-user] re-seeding with '{uname}' appended (idempotent; "
                   "existing personas re-applied unchanged) …")
        self._launch(f"Adding user {uname}", _seed, stream=True, cancellable=True)

    def _add_user_kind(self, uname, roles, pw_env, password, stack, on_line):
        """The kind-lane apply. Runs on the WORKER thread (blocking by contract).

        Refuses rather than guessing when no kind cluster is there either: "the
        casdoor door is not up" would be a true sentence about the wrong problem."""
        cluster = kind_cluster_name()
        up = kind_seed.kind_lane_up(cluster=cluster)
        if up is not True:
            return False, (
                "No mesh is running to add a user to: the compose stack is down and "
                + (f"there is no kind cluster named {cluster}." if up is False else
                   "docker did not answer about the kind cluster.")
                + " Start one first.")
        try:
            env = stack._build_env(write_overlays=False)      # an add READS the env
        except Exception:
            env = None
        outcome = kind_seed.add_user_kind(
            generator_dir=self.generator_dir, cluster=cluster,
            specs=self._added_user_specs, username=uname, roles=roles,
            password=password, password_env=pw_env, env=env, on_line=on_line)
        return outcome.ok, outcome.message

    def _copy_onion(self):
        """Copy the published .onion address to the clipboard. A normal browser
        can't open a .onion, so we copy (for pasting into Tor Browser) rather than
        openUrl — and say plainly when none has been published yet."""
        url = self.boot._stack_node().onion_url()
        if not url:
            QtWidgets.QMessageBox.information(
                self, "No .onion yet",
                "No Tor .onion has been published. On the Services step, tick "
                "\"On\" for the \"tor\" row, bring the mesh up, and wait ~30s "
                "for tor to publish the address.")
            return
        QtWidgets.QApplication.clipboard().setText(url)
        QtWidgets.QMessageBox.information(
            self, "Onion address copied",
            f"Copied to the clipboard:\n\n{url}\n\nOpen it in Tor Browser (a normal "
            "browser cannot reach a .onion).")


# ══════════════════════════════════════════════════════════════════════════════════
# THE WIZARD STEPS (issue #334)
# ══════════════════════════════════════════════════════════════════════════════════
# Each class below is ONE step of the local-mesh flow and holds NO widgets and NO
# state: it claims a section of LocalMeshPage on entry and that is all it does. The
# alternative — moving widgets onto per-step pages — would have split this page's
# handlers, gates, probes and worker across eight objects, and every cross-section
# invariant it enforces (the plan preview reads six sections; _refresh_plan gates the
# start button; the egress-conf exit guard) would have had to be re-plumbed through
# the wizard. Nothing here can drift from the page, because there is nothing here.
#
# MODE_SKIPPED_PAGES is UNTOUCHED and stays correct for every mode, exactly as it is
# for LocalMeshPage itself: "localmesh" is not a mode and appears in no mode's skip
# tuple — every page on this branch is DYNAMICALLY skipped instead, by applies_to()
# reading wiz.localmesh_selected. The ALL-OPTIONS guard nextId() documents holds
# trivially for all of them: this branch emits ZERO ImageConfig fields (it drives
# LocalMeshBootstrapConfig, which never reaches builder argv), so a skipped step
# changes no argv byte.


class _LocalMeshStep(QtWidgets.QWizardPage):
    """Base for a GENERATE-A-NEW-MESH step: title, subtitle, and one claimed section.

    ``initializePage`` is where the claim happens rather than ``__init__`` because the
    controller page is constructed LAST of the group (it is the final step), and Qt
    calls initializePage only after the whole wizard exists. So the steps need no
    construction-order dance and a missing controller is simply an empty page rather
    than an import-time crash.
    """

    SECTION = ""
    TITLE = ""
    SUBTITLE = ""

    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle(self.TITLE)
        self.setSubTitle(self.SUBTITLE)
        # Same scroll contract as the controller page: a claimed section can be tall
        # (services floors at 300px) and a tall page must scroll, never grow the window.
        self._lay = scrollable(self)
        self._lay.addStretch(1)
        self._wired = False

    # ── the controller ──────────────────────────────────────────────────────────
    @property
    def ctl(self) -> "LocalMeshPage | None":
        """The one LocalMeshPage that owns every widget (it sets the handle in its
        constructor). None only if this step is built without one — a bare test
        harness — in which case the step renders empty instead of raising."""
        return getattr(self.wiz, "localmesh_page", None)

    # ── flow ────────────────────────────────────────────────────────────────────
    def applies_to(self, cfg) -> bool:      # noqa: ARG002 — the hook's fixed signature
        """On the flow only when the mode menu picked the local mesh AND the choice
        screen picked GENERATE. Reads the wizard, not cfg, for the reason
        LocalMeshPage.applies_to gives: localmesh is a wizard-transient choice that is
        deliberately absent from ImageConfig."""
        return bool(getattr(self.wiz, "localmesh_selected", False)
                    and not getattr(self.wiz, "localmesh_join_selected", True))

    def isComplete(self) -> bool:
        """False while a verb runs on the controller — the controller's own rule.

        Every step inherits it, not just the join step. LocalMeshPage.isComplete has
        always refused to advance mid-verb ("leaving mid-up would orphan the worker's
        signals into a destroyed page"), and a step that can START a verb — the review
        step hosts the saved-mesh table's Start/Restore buttons — needs exactly the
        same refusal. Without it the wiring below emitted completeChanged into a gate
        that never said no, so the operator could walk forward out of a running
        bring-up: a straight regression from the single-page flow.
        """
        ctl = self.ctl
        return True if ctl is None else not ctl._running

    def _claim(self) -> None:
        """Re-parent onto this step every section it is responsible for.

        Called from BOTH initializePage and showEvent, because Qt calls initializePage
        only on a FORWARD visit ("as a result of the user clicking Next"): pressing
        Back re-SHOWS a page without re-initialising it. For a section only one page
        ever wants that is harmless — nobody took it away. The RUN VIEW is the
        exception: the join step, the review step and the controller all claim it, so
        whichever page took it last keeps it across a Back, and the step the operator
        is actually looking at is left with a verb it cannot show. take_section is
        idempotent by parent, so the duplicate call on a forward visit costs nothing.
        """
        ctl = self.ctl
        if ctl is None:
            return
        ctl.take_section(self.SECTION, self._lay)

    def showEvent(self, ev):
        super().showEvent(ev)
        self._claim()

    def initializePage(self):
        ctl = self.ctl
        if ctl is None:
            return
        self._claim()
        if not self._wired:
            # A verb running on the controller must grey THIS page's Next/Exit too —
            # the controller emits completeChanged at every verb start and end
            # (_launch / _verb_done) and a step has no other way to hear it. isComplete
            # above is the gate it re-evaluates.
            ctl.completeChanged.connect(self.completeChanged)
            self._wired = True


class LocalMeshJoinPage(_LocalMeshStep):
    """Card one: run a node that JOINS an existing mesh, using an auth key.

    Terminal, like the bring-up step: a joined node is the end of this path, there is
    no image to build after it, and the final button only closes the Studio
    (label_finish_as_exit). It claims the RUN VIEW as well as its own section, because
    start/stop/logs stream into the same staged tree + log the bootstrap verbs use.
    """

    SECTION = "join"
    TITLE = "Join an existing mesh with a key"
    SUBTITLE = ("Run a HugMesh mesh node on THIS machine in Docker with a "
                "tailnet/headscale auth key — no server hardware, no image build. "
                "This is the end of this path: Exit closes the Studio; the node keeps "
                "running in Docker.")

    def __init__(self, wiz):
        super().__init__(wiz)
        self.setFinalPage(True)
        label_finish_as_exit(self)

    def applies_to(self, cfg) -> bool:      # noqa: ARG002 — the hook's fixed signature
        return bool(getattr(self.wiz, "localmesh_selected", False)
                    and getattr(self.wiz, "localmesh_join_selected", False))

    def nextId(self) -> int:
        return -1

    def _claim(self) -> None:
        super()._claim()
        ctl = self.ctl
        if ctl is not None:
            ctl.take_section("run", self._lay)

    def initializePage(self):
        super().initializePage()
        ctl = self.ctl
        if ctl is None:
            return
        ctl._refresh_status()


class LocalMeshEnvPage(_LocalMeshStep):
    SECTION = "env"
    TITLE = "Environment and brand"
    SUBTITLE = ("Where this mesh lives and whose name it carries: a LAN-only test "
                f"mesh or a public prod one, the {plain_words.term('superbrand')} that "
                "governs it (create one, or pick an existing profile), and the "
                "superadmin account the bring-up mints.")

    def initializePage(self):
        super().initializePage()
        ctl = self.ctl
        if ctl is not None:
            ctl.mount_brand()

    def showEvent(self, ev):
        """Back into this step fires no initializePage, and the drop-down must describe
        the page as it is now (the environment and the domain may have changed)."""
        super().showEvent(ev)
        ctl = self.ctl
        if ctl is not None:
            ctl.mount_brand()

    def validatePage(self):
        ctl = self.ctl
        return True if ctl is None else ctl.leave_brand()

    def cleanupPage(self):
        ctl = self.ctl
        if ctl is not None:
            ctl.leave_brand()


class LocalMeshDomainsPage(_LocalMeshStep):
    """The mesh's domains (#494): row 0 its own, then every other one it serves."""

    SECTION = "domains"
    TITLE = "Domains"
    SUBTITLE = ("Every domain this mesh serves, its own domain first. Each one gets "
                "its own service page on the next step, and the mesh will not start "
                "while any domain here has never been through it. A row whose sign-in "
                "is ‘Own’ brings up a Casdoor of its own beside the central one.")

    def initializePage(self):
        super().initializePage()
        ctl = self.ctl
        if ctl is not None:
            ctl._seed_domains()

    def showEvent(self, ev):
        """Back into this step fires no initializePage, and the services column is a
        read-only MIRROR of what the next step recorded — refresh it on every show,
        exactly what the image flow's DomainsPage does through currentIdChanged."""
        super().showEvent(ev)
        ctl = self.ctl
        if ctl is not None:
            ctl.domains_table._refresh_services_cells()

    def validatePage(self):
        ctl = self.ctl
        return True if ctl is None else ctl._commit_domains()

    def cleanupPage(self):
        """Back also records: Qt calls cleanupPage (not validatePage) on Back, and a
        row typed here must reach ``mesh_domains`` either way."""
        ctl = self.ctl
        if ctl is not None:
            ctl._commit_domains()


class LocalMeshDomainServicesPage(_LocalMeshStep):
    """One domain's services at a time (#494) — the image flow's page, re-hosted."""

    SECTION = "domain_services"
    TITLE = "Domain services"
    # Two lines at the wizard's default size: the subtitle area holds no more, and the
    # longer sentence this replaced was cut off mid-way (#647, looked at). Short enough
    # to stay two lines at a 13.5 pt face too (what a forced font DPI of 144 gives a
    # 9 pt face; measured at the 736 px wide window an 800x800 screen clamps the wizard
    # to, where the earlier 177-character sentence wrapped to three). The rest of what
    # it said is on the page itself (the lane note above the tables, and the ‘not
    # domain-scoped’ table's own heading).
    SUBTITLE = ("Each domain's optional services, one domain per page, this mesh's own "
                "first. Choices that bind the whole mesh are on the ‘Services’ step, "
                "two steps on.")

    def initializePage(self):
        super().initializePage()
        ctl = self.ctl
        if ctl is not None:
            ctl.domain_services.load(ctl.mesh_domains)

    def validatePage(self):
        ctl = self.ctl
        if ctl is not None:
            ctl.domain_services.record(ctl.mesh_domains)
            # the brands (the Domains rows) are final here: save the record with them
            ctl.leave_brand()
            ctl._refresh_plan()
        return True

    def cleanupPage(self):
        ctl = self.ctl
        if ctl is not None:
            ctl.domain_services.record(ctl.mesh_domains)


class LocalMeshSourcePage(_LocalMeshStep):
    SECTION = "source"
    TITLE = "Repo source"
    SUBTITLE = ("Where the buildable repo files come from — cloned into ./.stack-src, "
                "or checkouts you already have. Compose builds every service from "
                "whatever this points at.")


class LocalMeshServicesPage(_LocalMeshStep):
    SECTION = "services"
    TITLE = "Services"
    SUBTITLE = ("Which services this mesh runs, and how its web login looks. A row "
                "the local docker stack has no mechanism for is greyed with the "
                "reason instead of offered as a toggle that would change nothing.")


class LocalMeshIdpPage(_LocalMeshStep):
    SECTION = "idp"
    TITLE = "Identity provider"
    SUBTITLE = ("Who signs users in. Casdoor is built in and needs nothing; an "
                "external OIDC provider is threaded into the stack env, and the note "
                "on this step says exactly how far that goes on a local stack.")


class LocalMeshOverlayPage(_LocalMeshStep):
    SECTION = "overlay"
    TITLE = "Mesh overlay"
    SUBTITLE = ("The tailnet key that attaches this mesh to the overlay, and the "
                "public domain it was given on the Domains step. Prod only — a test "
                "mesh never sees this step.")

    def applies_to(self, cfg) -> bool:
        """Prod only. A test mesh publishes nothing and attaches no overlay, so the
        group was already hidden on the old single page; as a STEP the honest form of
        "hidden" is "not visited". Leaves the output unchanged: every field here is a
        LocalMeshBootstrapConfig field, and collect_bootstrap reads the widgets
        directly, so an unvisited step leaves them exactly as apply_bootstrap or the
        constructor set them."""
        if not super().applies_to(cfg):
            return False
        ctl = self.ctl
        return True if ctl is None else bool(ctl.env_prod.isChecked())


class LocalMeshReviewPage(_LocalMeshStep):
    """Saved meshes + the read-only plan: the confirm-before-run step.

    The operator asked for the saved-mesh table to be in front of them BEFORE they
    generate a new one, and this is now literally the step before the button.
    """

    SECTION = "review"
    TITLE = "Saved meshes and the plan"
    SUBTITLE = ("What a bring-up will generate and start, and the meshes already "
                "saved on this machine. The plan itself is read-only; a saved row's "
                "Start or Restore does run docker, and its output appears below.")

    def _claim(self) -> None:
        # THE RUN SURFACE COMES WITH THE TABLE. The saved-mesh rows are not a preview:
        # start_requested -> _start_saved launches boot.start_saved / boot.restore on a
        # _MeshWorker QThread — minutes of docker output — and every word that verb
        # says to the operator lives in run_view (status line, stage tree, log, Cancel).
        # It also carries the REFUSALS: _start_saved's "Still running: …", "A local
        # mesh is running — stop it first", the per-domain services gate's "Cannot
        # start this mesh: …" (#495), the theme error and boot.validate()'s problems
        # all land in ctl.status, and the row buttons stay enabled through each of
        # them. Claimed here, a refused click says why and a started verb can
        # be watched and cancelled; unclaimed, both are silent. LocalMeshPage
        # .showEvent reclaims it on entry, so the hand-back to the bring-up step
        # needs no code here.
        super()._claim()
        ctl = self.ctl
        if ctl is not None:
            ctl.take_section("run", self._lay)

    def initializePage(self):
        super().initializePage()
        ctl = self.ctl
        if ctl is None:
            return
        # Re-render the plan from the four steps behind this one, then answer "what is
        # already running?" and re-read the saved rows. Both probes are off-thread and
        # re-entrant-safe (probe_running), so arriving here twice starts no second one.
        ctl.leave_brand()
        ctl._refresh_plan()
        ctl._probe_mesh_state()
        ctl.saved_meshes.refresh()
        # Deliberately NOT _refresh_status(): that probes the JOIN node
        # (`docker compose ps` on the join stack) and writes "Status: running/stopped"
        # into this same label. On the generate branch that is a sentence about a mesh
        # the operator is not running, so the label is left empty until this step's own
        # verb — or its refusal — has something true to put in it.


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

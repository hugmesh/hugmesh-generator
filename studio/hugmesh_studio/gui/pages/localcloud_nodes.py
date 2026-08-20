"""LocalCloudNodesPage — "Create nodes for local cloud" (issue #50, items 3-5).

The operator has a LOCAL Docker mesh configured (and possibly LIVE, with real
users) and the k8s/DevOps lane running. This page is the gate between that local
cloud and the node-image wizard: it

* imports the local mesh's identity — its apex domain and the accounts the
  Studio provisioned — into the shared :class:`~...core.config.ImageConfig`, so
  the images that come out of the flow join the SAME mesh identity the operator
  already went live with (accounts created after go-live live in the mesh's
  identity tier and stay valid without being listed here);
* collects the operator's explicit consent that **k8s will stop to proceed** —
  as an INLINE, modeless checkbox (never a QMessageBox/exec(): a modal in page
  logic hangs headless tests, the repo-wide rule) — and then actually STOPS it:
  the tick ARMS a Stop button that runs ``make kind-down``
  (:meth:`~...core.local_stack_node.LocalStackNode.devops_down`) on a worker
  thread with streamed output and Cancel, the way every long verb in the Studio
  runs. Next stays shut while a cluster is still known to be up, so node images
  are never configured against a live k8s lane;
* then REJOINS the existing image flow as an ABBREVIATED mesh wizard: it commits
  ``cfg.mode = "mesh"`` itself (its ModePage card, like every side-flow card,
  commits nothing) and installs the worklist restriction hook
  (``wiz.worklist_role_allow``) so the WorklistPage offers ONLY the laptop and
  cluster-node image types — the person-desktop variants and every no-mesh-role
  device row are withdrawn, because the local cloud's devices are its nodes plus
  the operator's laptop.

Unlike its terminal side-flow siblings (localmesh/phone/quest/deploy) this page
is an ENTRY, not a destination: Next continues into the normal mesh chain
(idp -> worklist -> ...), which is what "abbreviated wizard" means — the same
pages, a narrowed worklist, and the identity already filled in.
"""
from __future__ import annotations

import functools
import threading

from .. import console
from ..qt import Qt, QtCore, QtWidgets, Signal
from ._scroll import scrollable
from ._widgets import own_probe, probe_running
from .localmesh import _MeshWorker
from ...core.config import (
    MODE_DEFAULT_ROLE, ROLE_CHOICES, User, enter_mesh_defaults, image_class,
)
from ...core.local_mesh_bootstrap import LocalMeshBootstrap
from ...core.seeded_credentials import load_roster

# The abbreviated worklist (issue #50): ONLY the laptop and the cluster-node image
# types. DERIVED from ROLE_CHOICES + image_class rather than listed, so a new node
# role is offered here in the same commit that creates it, with no edit to this
# page — the same no-local-list rule as WorklistPage's mesh_capable() gate.
LOCALCLOUD_ALLOWED_ROLES = tuple(
    role for role, _platforms, _label in ROLE_CHOICES["mesh"]
    if role == "laptop" or image_class("mesh", role) == "node")

# Casdoor role grants -> the ImageConfig User.role ladder (first match wins;
# everything else is a plain user). Only ROLES are imported — never passwords:
# User carries no secret by design, and the mesh's identity tier keeps them.
_CASDOOR_ROLE_MAP = (
    ("ROLE_SUPERADMIN", "superadmin"),
    ("ROLE_ADMIN", "admin"),
    ("ROLE_MOD", "mod"),
)


def _person_role(roles) -> str:
    for granted, person in _CASDOOR_ROLE_MAP:
        if granted in roles:
            return person
    return "user"


def local_mesh_identity(generator_dir: str) -> tuple[str, list[tuple[str, str]]]:
    """The local mesh's importable identity: ``(apex domain, [(username, role)...])``.

    READ-ONLY and offline (plain file reads, no docker/compose probe — this runs in
    ``initializePage`` and must never stall the GUI): the apex comes from the
    bootstrap config's resolution (the brand default unless the operator set one),
    the accounts from the two channels the Studio itself provisioned — the minted
    superadmin in the runtime secrets bundle (``keys-out/vault/secrets.json``) and
    the seeder's persona roster. Users created interactively AFTER go-live live in
    the running mesh's identity tier; they cannot be enumerated from disk and do
    not need to be — building node images for the same domain leaves them valid.
    Passwords are never read into the config (User rows carry no secret)."""
    boot = LocalMeshBootstrap(generator_dir)
    domain = boot.cfg.resolved_domain()
    users: list[tuple[str, str]] = []
    creds = boot.superadmin_login()
    if creds:
        users.append((creds[0], "superadmin"))
    roster = load_roster(generator_dir)
    seen = {name for name, _role in users}
    for u in roster.users:
        if u.username not in seen:
            seen.add(u.username)
            users.append((u.username, _person_role(u.roles)))
    return domain, users


def local_k8s_running(generator_dir: str) -> bool:
    """Is the local Kubernetes (DevOps) lane up right now?

    A read-only `kind get clusters` (LocalStackNode.devops_running) behind ONE
    module symbol, like ``local_mesh_identity`` above — the page's whole view of the
    cluster goes through here, so a test pins the host in one place and the GUI has
    no second opinion about what is running."""
    return LocalMeshBootstrap(generator_dir)._stack_node().devops_running()


def local_k8s_teardown(generator_dir: str, on_line=None,
                       cancel=None) -> tuple[bool, str]:
    """`make kind-down` — delete the local Kubernetes cluster. Destructive for the
    DevOps lane ONLY: the docker mesh and every one of its volumes are untouched.
    Same single-symbol seam as ``local_k8s_running``; streams and cancels because it
    is always run off the GUI thread (see LocalCloudNodesPage._stop_k8s)."""
    return LocalMeshBootstrap(generator_dir)._stack_node().devops_down(
        on_line=on_line, cancel=cancel)


class _K8sGateProbe(QtCore.QThread):
    """Ask whether the DevOps lane is up, OFF the GUI thread.

    `kind get clusters` shells out (LocalStackNode._probe, 15 s ceiling) and this runs
    from initializePage — inline it is the same freeze-on-entry defect
    localmesh._StatusProbe/_E2EGateProbe exist to prevent. Emits True only when a
    cluster is KNOWN to be up; never raises, because devops_running() already folds
    every failure into False and an exception escaping run() would leave the gate
    stuck in "checking…" forever."""
    result = Signal(bool)

    def __init__(self, generator_dir: str, parent=None):
        super().__init__(parent)
        self._generator_dir = generator_dir

    def run(self):  # noqa: D102 — QThread contract
        try:
            self.result.emit(bool(local_k8s_running(self._generator_dir)))
        except Exception:                # noqa: BLE001 — never kill the page over a probe
            self.result.emit(False)


class LocalCloudNodesPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self._imported = False       # one-shot import latch (see validatePage)
        self._domain = ""
        self._users: list[tuple[str, str]] = []
        self.worker: _MeshWorker | None = None
        self._k8s_probe: _K8sGateProbe | None = None
        self._running = False        # a `make kind-down` is in flight
        # TRI-STATE k8s truth: None = not established yet, True = a cluster is up,
        # False = nothing to stop. Only a KNOWN-UP cluster holds Next — "unknown is
        # rendered as unknown, never as a blocker" is the rule the local-mesh e2e
        # gate already follows, and a probe that cannot answer must never strand the
        # operator on a page whose Next can no longer enable.
        self._k8s_up: bool | None = None
        self.setTitle("Create nodes for local cloud")
        self.setSubTitle(
            "Turn the local Docker mesh into real device images. The abbreviated "
            "wizard ahead reuses the domain and accounts already provisioned here "
            "and offers only the laptop and cluster-node image types.")
        lay = scrollable(self)

        intro = QtWidgets.QLabel(
            "This flow REUSES what you built locally: the node images join the "
            "same apex domain, and the accounts the Studio provisioned are carried "
            "into the users step (editable there). If this mesh has already gone "
            "LIVE with real users, that stays valid — accounts created after "
            "go-live live in the mesh's identity tier and keep working; they are "
            "simply not listed below.")
        intro.setWordWrap(True)
        lay.addWidget(intro)

        # what WILL be imported, shown before consent is asked — filled per visit.
        self.summary = QtWidgets.QLabel("")
        self.summary.setWordWrap(True)
        self.summary.setTextFormat(Qt.TextFormat.RichText)
        lay.addWidget(self.summary)

        # ── the k8s gate — INLINE and modeless (no QMessageBox/exec in page logic:
        # a modal here hangs headless tests; the checkbox + isComplete() is the
        # same gate, visible, and Next stays disabled until it is ticked). ──
        self.confirm = QtWidgets.QCheckBox(
            "I understand: k8s will stop to proceed — the local Kubernetes "
            "(DevOps) stack must come down before these node images are "
            "configured and built.")
        self.confirm.toggled.connect(self._on_confirm_toggled)
        lay.addWidget(self.confirm)

        # The consent ARMS the destructive verb; it never performs it on its own —
        # nothing on this page deletes a cluster without a press. `make kind-down`
        # then runs OFF the GUI thread: calling it inline (from validatePage, say)
        # would freeze the wizard for the minutes a teardown takes, and a silent
        # background mutation of the operator's cluster deserves the same streamed
        # log + Cancel surface every other long verb in the Studio has.
        row = QtWidgets.QWidget()
        brow = QtWidgets.QHBoxLayout(row)
        brow.setContentsMargins(0, 0, 0, 0)
        self.down_btn = QtWidgets.QPushButton("Stop Kubernetes now")
        self.down_btn.setEnabled(False)
        self.down_btn.setToolTip(
            "Delete the local Kubernetes cluster (`make kind-down`). Destroys the "
            "DevOps lane ONLY — the docker mesh and every one of its volumes are "
            "untouched. Armed by the confirmation above; output streams below and "
            "Cancel stays available.")
        self.down_btn.clicked.connect(self._stop_k8s)
        brow.addWidget(self.down_btn)
        self.cancel_btn = QtWidgets.QPushButton("Cancel")
        self.cancel_btn.setVisible(False)
        self.cancel_btn.clicked.connect(self._cancel_clicked)
        brow.addWidget(self.cancel_btn)
        brow.addStretch(1)
        lay.addWidget(row)

        self.gate_note = QtWidgets.QLabel("")
        self.gate_note.setWordWrap(True)
        self.gate_note.setStyleSheet("color: gray;")
        lay.addWidget(self.gate_note)

        # Hidden until a teardown actually runs: an empty console on a page that
        # usually has nothing to stream is just height. The page is inside the shared
        # scroll area, so revealing it SCROLLS rather than resizing the wizard (the
        # #400 no-jitter rule).
        self.log = console.attach(QtWidgets.QPlainTextEdit())
        self.log.setMinimumHeight(140)
        self.log.setVisible(False)
        lay.addWidget(self.log, 1)
        lay.addStretch(1)
        self._sync_gate()

    # ---- slots (guarded: PyQt6 qFatals on an exception escaping a slot) ----------
    def _on_confirm_toggled(self, *_):
        try:
            self._sync_gate()
        except Exception:                    # noqa: BLE001 — never crash the toggle
            pass

    # ---- the k8s gate: one place decides arming, wording and completeness --------
    def _sync_gate(self):
        """The Stop button's arming, the note and completeChanged in ONE call.

        Every input to the gate (the consent toggle, the probe's answer, the verb's
        start and end) routes through here, so the button, the sentence under it and
        whether Next is available can never disagree with each other."""
        acked = self.confirm.isChecked()
        self.down_btn.setEnabled(acked and self._k8s_up is True and not self._running)
        self.gate_note.setText(self._gate_text())
        self.completeChanged.emit()

    def _gate_text(self) -> str:
        if self._running:
            return ("Deleting the local Kubernetes cluster — the output streams "
                    "below and the wizard stays responsive; Cancel stops the verb. "
                    "The docker mesh and its volumes are untouched.")
        if self._k8s_up is None:
            return "Checking whether the local Kubernetes (DevOps) lane is running…"
        if self._k8s_up:
            return ("The local Kubernetes (DevOps) lane is RUNNING. Confirm above, "
                    "then press “Stop Kubernetes now” — Next stays disabled "
                    "until the cluster is gone.")
        return ("No local Kubernetes cluster is running — there is nothing to stop. "
                "Next stays disabled until you confirm.")

    def _start_k8s_probe(self):
        if probe_running(self, "_k8s_probe"):
            return                           # its answer is already on the way
        probe = own_probe(self, "_k8s_probe",
                          _K8sGateProbe(self.wiz.generator_dir, parent=self))
        probe.result.connect(self._on_k8s_answer)
        probe.start()

    def _on_k8s_answer(self, running: bool):
        """The probe's answer arrived (GUI thread). A teardown started while it was
        out WINS: re-marking the lane from a stale probe would re-arm Stop over a live
        run, and _down_done re-probes anyway."""
        if self._running:
            return
        self._k8s_up = bool(running)
        self._sync_gate()

    # ---- the teardown (off-thread, streamed, cancellable) ------------------------
    def _stop_k8s(self):
        if self._running or not self.confirm.isChecked():
            return                           # never without the explicit consent
        self._running = True
        self.log.clear()
        self.log.setVisible(True)
        console.write(self.log, "[devops] deleting the local Kubernetes cluster "
                                "(the docker mesh and its volumes are untouched) …")
        self.cancel_btn.setVisible(True)
        self.cancel_btn.setEnabled(True)
        cancel = threading.Event()
        gd = self.wiz.generator_dir
        self.worker = _MeshWorker(
            lambda on_line, c: local_k8s_teardown(gd, on_line=on_line, cancel=c),
            parent=self, stream=True, cancel=cancel)
        # functools.partial, not a lambda: the slot outlives this method and a lambda
        # closing over self.log would keep re-resolving it.
        self.worker.line.connect(functools.partial(console.write, self.log))
        self.worker.done.connect(self._down_done)
        self._sync_gate()
        self.worker.start()

    def _cancel_clicked(self):
        w = self.worker
        if w is not None and w.cancel is not None and self._running:
            w.cancel.set()                   # _make terminates the whole process group
            self.cancel_btn.setEnabled(False)
            console.write(self.log,
                          "[devops] cancelling — terminating `make kind-down` …")

    def _down_done(self, ok: bool):
        self._running = False
        self.cancel_btn.setVisible(False)
        console.write(self.log, "[devops] kind-down finished."
                      if ok else "[devops] kind-down FAILED (see the log above).")
        # RE-PROBE rather than believe the exit status: `kind delete cluster` exits 0
        # for a cluster that was never there, and a failed or cancelled run can leave
        # one half gone. _k8s_up is deliberately NOT reset to None first — that would
        # open the gate for the width of the probe right after a FAILED teardown.
        self._sync_gate()
        self._start_k8s_probe()

    # ---- wizard-flow contract (mirrors the other ModePage side-flow pages) -------
    def applies_to(self, cfg) -> bool:  # noqa: ARG002 — the hook's fixed signature
        # A WIZARD-transient choice, deliberately absent from cfg (ModePage keeps
        # cfg.mode an IMAGE mode until THIS page commits it on Next).
        return bool(getattr(self.wiz, "localcloud_selected", False))

    def isComplete(self) -> bool:
        # THE gate, all three halves: the explicit k8s-will-stop consent, no cluster
        # still KNOWN to be up, and no teardown in flight (leaving mid-verb would
        # configure the images against a cluster that is only half gone).
        return (self.confirm.isChecked() and not self._running
                and self._k8s_up is not True)

    def initializePage(self):
        # Re-read the local mesh on EVERY forward entry (it may have been
        # re-bootstrapped since), reset the one-shot import latch, and CLEAR the
        # consent box — the confirmation is the point of this page, so it is
        # asked afresh each time the operator routes through it.
        self._imported = False
        self.confirm.setChecked(False)
        self._domain, self._users = local_mesh_identity(self.wiz.generator_dir)
        # Re-establish the k8s truth too — unless a teardown is still streaming
        # (the operator can walk Back and forward while `make kind-down` runs, and
        # that run, not a fresh probe, owns the gate until it finishes).
        if not self._running:
            self._k8s_up = None
            self._start_k8s_probe()
        self._sync_gate()
        listed = ", ".join(f"{name} ({role})" for name, role in self._users)
        self.summary.setText(
            f"<b>Imported from the local mesh:</b><br>"
            f"apex domain <b>{self._domain or '(brand default)'}</b>"
            + (f"<br>accounts: {listed}" if listed
               else "<br>accounts: none found on disk (unseeded or "
                    "terminal-managed mesh)"))

    def validatePage(self) -> bool:
        if not self.isComplete():
            # isComplete() already disables Next; this guards the collect_all()
            # re-run too — the SAME expression, so the two can never drift.
            return False
        cfg = self.wiz.cfg
        # Commit the mesh chain exactly the way ModePage's mesh card does — this
        # page owns the commit because its ModePage card is a side-flow card and
        # sets nothing (the operator can still Back out without residue).
        prev = cfg.mode
        cfg.mode = "mesh"
        if cfg.role not in {r for r, _, _ in ROLE_CHOICES["mesh"]}:
            cfg.role = MODE_DEFAULT_ROLE["mesh"]
        cfg.bundle_source = False            # mesh images never bundle the source
        enter_mesh_defaults(cfg, fresh=(prev != "mesh"))
        if prev != "mesh":
            self.wiz.worklist = None         # fresh worklist on transition into mesh
        # The ABBREVIATION: restrict the WorklistPage to the laptop + node rows.
        # Lifted by any other ModePage commit (mode.py clears it), so a plain
        # mesh flow started later offers the full catalog again.
        self.wiz.worklist_role_allow = LOCALCLOUD_ALLOWED_ROLES
        # ONE-SHOT import. collect_all() re-runs validatePage on every visited
        # page, so an unlatched import would clobber later operator edits (e.g.
        # the cluster domain on the Network step) on every Build-page arrival.
        # The latch resets on each forward entry (initializePage), where a
        # re-import is exactly what a revisit means.
        if not self._imported:
            self._imported = True
            if self._domain:
                cfg.cluster_domain = self._domain
            superdomain = cfg.effective_superdomain()
            existing = {(u.username, u.domain) for u in cfg.users}
            for username, role in self._users:
                # superadmins belong to the orchestration superdomain (spec 5 —
                # UsersPage locks their row there); everyone else lands on the
                # imported apex the local mesh served them on.
                dom = superdomain if role == "superadmin" else cfg.cluster_domain
                if (username, dom) not in existing:
                    cfg.users.append(User(username=username, domain=dom, role=role))
            # make the Users TABLE reachable so the imported accounts are visible
            # and editable (users_choice pre-selects the table card from this).
            cfg.configure_users = bool(cfg.users)
        # The teardown itself has ALREADY happened by the time this runs: the gate
        # above only opens once the probe says no cluster is up, so there is nothing
        # left to do here (and nothing destructive may run from validatePage — it is
        # re-entered by collect_all on every Build-page arrival).
        return True

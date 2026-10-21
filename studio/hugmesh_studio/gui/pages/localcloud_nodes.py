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
import html
import threading

from .. import console
from ..qt import Qt, QtCore, QtWidgets, Signal
from ._scroll import scrollable
from ._widgets import own_probe, probe_running
from .localmesh import _MeshWorker
from ...core.config import (
    MODE_DEFAULT_ROLE, ROLE_CHOICES, User, enter_mesh_defaults, image_class,
    normalize_user_roles,
)
from ...core import saved_meshes
from ...core.local_mesh_bootstrap import (
    LocalMeshBootstrap, LocalMeshIdentity, localcloud_tor_note, saved_mesh_choice_text,
    saved_mesh_source,
)
from ...core.local_mesh_domains import (
    apply_imported_domains, imported_domains_lines, imported_mesh_domains,
)
from ...core.seeded_credentials import load_roster

# The abbreviated worklist (issue #50): ONLY the laptop and the cluster-node image
# types. DERIVED from ROLE_CHOICES + image_class rather than listed, so a new node
# role is offered here in the same commit that creates it, with no edit to this
# page — the same no-local-list rule as WorklistPage's mesh_capable() gate.
LOCALCLOUD_ALLOWED_ROLES = tuple(
    role for role, _platforms, _label in ROLE_CHOICES["mesh"]
    if role == "laptop" or image_class("mesh", role) == "node")
# ...and the platforms those rows come on — what the Tor note (#579) splits into
# "carries the onion" / "cannot", derived the same way, never listed.
LOCALCLOUD_PLATFORMS = tuple(dict.fromkeys(
    plat for role, platforms, _label in ROLE_CHOICES["mesh"]
    if role in LOCALCLOUD_ALLOWED_ROLES for plat in platforms))

# Casdoor role grants -> ImageConfig User.roles (issue #228: EVERY mapped grant is
# carried, not the top of a ladder — a persona holding ROLE_ADMIN and ROLE_GAMES
# imports as admin + games; anything unmapped contributes nothing, and a persona
# with no mapped grant is a plain user). The TUI twin (tui/localcloud.py) keeps the
# same table. Only ROLES are imported — never passwords: User carries no secret by
# design, and the mesh's identity tier keeps them.
_CASDOOR_ROLE_MAP = (
    ("ROLE_SUPERADMIN", "superadmin"),
    ("ROLE_ADMIN", "admin"),
    ("ROLE_MOD", "mod"),
    ("ROLE_USER", "user"),
    ("ROLE_GAMES", "games"),
    ("ROLE_GAMES_SERVICES", "games-services"),
)


#: The consent line, in two halves (#661): the tick-box carries the short first
#: half (a QCheckBox cannot wrap), the word-wrapped label beside it the rest. The
#: TUI's prompt (tui/localcloud.py) opens with the same first half.
CONSENT_SHORT = "I understand: k8s will stop to proceed"
CONSENT_REST = ("— the local Kubernetes (DevOps) stack must come down before these "
                "node images are configured and built.")


class _ConsentText(QtWidgets.QLabel):
    """The wrapped half of the consent line: a click on it ticks the box it belongs
    to, so the sentence behaves as one control although only its head is the box."""

    def __init__(self, text: str, box: QtWidgets.QCheckBox, parent=None):
        super().__init__(text, parent)
        self._box = box
        self.setWordWrap(True)
        self.setCursor(Qt.CursorShape.PointingHandCursor)

    def mousePressEvent(self, event):  # noqa: N802 — Qt override
        try:
            if event.button() == Qt.MouseButton.LeftButton and self._box.isEnabled():
                self._box.toggle()
        except Exception:                    # noqa: BLE001 — never crash on a click
            pass
        super().mousePressEvent(event)


def _person_roles(roles) -> list[str]:
    return normalize_user_roles(
        [person for granted, person in _CASDOOR_ROLE_MAP if granted in roles])


def local_mesh_identity(generator_dir: str, record_id: str = "") -> LocalMeshIdentity:
    """The local mesh's importable identity: ``(apex domain, [(username, roles)...],
    with_tor, source, mesh_domains)`` — a :class:`LocalMeshIdentity`.

    READ-ONLY and offline (plain file reads, no docker/compose probe — this runs in
    ``initializePage`` and must never stall the GUI). The mesh's CONFIG comes from the newest saved-mesh record
    for this checkout (``LocalMeshBootstrap.for_checkout``), so the apex and whether
    the mesh ran the Tor onion (``effective_with_tor()`` — the services row whenever
    there is a selection) are what that mesh actually SAVED, not a default config's
    brand domain with Tor off (#579). No record: the defaults, and ``source`` is "".
    A record is the mesh as saved, not a probe of what is running (#309). The
    accounts come from the two channels the Studio itself provisioned — the minted
    superadmin in the runtime secrets bundle and the seeder's persona roster. Users
    created after go-live live in the running mesh's identity tier; they cannot be
    enumerated from disk and do not need to be. Passwords are never read into the
    config (User rows carry no secret).

    WHICH record: the newest one whose mesh was UP when it was saved, so a newer
    draft (saved before its first bring-up) never replaces the mesh that ran; the
    newest draft only when nothing ever ran (``source`` then says NEVER RAN).
    ``record_id`` is the operator's own pick from this checkout's records."""
    boot, rec = LocalMeshBootstrap.for_checkout(generator_dir, record_id=record_id)
    domain = boot.cfg.resolved_domain()
    users: list[tuple[str, list[str]]] = []
    creds = boot.superadmin_login()
    if creds:
        users.append((creds[0], ["superadmin"]))
    roster = load_roster(generator_dir)
    seen = {name for name, _roles in users}
    for u in roster.users:
        if u.username not in seen:
            seen.add(u.username)
            users.append((u.username, _person_roles(u.roles)))
    # #636: EVERY domain the saved mesh carries, not just the apex — the rows its
    # Domains step recorded (title, sign-in, per-domain services) and which of them
    # its Domain services step walked. None for a one-domain / pre-#494 record.
    return LocalMeshIdentity(domain, users, bool(boot.cfg.effective_with_tor()),
                             saved_mesh_source(rec),
                             imported_mesh_domains(boot.cfg) if rec is not None
                             else None)


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
    Same single-symbol override point as ``local_k8s_running``; streams and cancels because it
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
        self._users: list[tuple[str, list[str]]] = []
        self._with_tor = False       # the imported mesh ran the Tor onion (#579)
        self._source = ""            # which saved record the import read ("" = none)
        self._mesh_domains = None    # the saved mesh's domain rows (#636), or None
        self._picked_id = ""         # a record the operator picked ("" = the default)
        self._filling_pick = False   # the picker is being refilled, not picked from
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

        # WHICH saved mesh feeds the images — inline, never a modal. The default is
        # the newest record whose mesh RAN (a newer draft, saved before its first
        # bring-up, must not replace it); the operator can pick any record of this
        # checkout, a draft included, and the summary below says what that imports.
        # Hidden when this checkout has no saved mesh.
        self.record_row = QtWidgets.QWidget()
        prow = QtWidgets.QGridLayout(self.record_row)
        prow.setContentsMargins(0, 0, 0, 0)
        self.record_label = QtWidgets.QLabel("Import from saved mesh:")
        self.record_pick = QtWidgets.QComboBox()
        # the combo must not widen the page past the window (#661): its width comes
        # from the layout, and a long record name is elided by the view
        self.record_pick.setSizeAdjustPolicy(
            QtWidgets.QComboBox.SizeAdjustPolicy.AdjustToMinimumContentsLengthWithIcon)
        self.record_pick.setMinimumContentsLength(24)
        self.record_pick.setToolTip(
            "The saved local mesh whose domain, domains, accounts and Tor choice the "
            "node images take. Listed: the meshes that RAN first, newest first, then "
            "drafts (saved before their first bring-up) marked 'never ran'.")
        self.record_label.setBuddy(self.record_pick)
        self.record_pick.currentIndexChanged.connect(self._on_record_picked)
        prow.addWidget(self.record_label, 0, 0)
        prow.addWidget(self.record_pick, 0, 1)
        prow.setColumnStretch(1, 1)
        lay.addWidget(self.record_row)
        self.record_note = QtWidgets.QLabel(
            "To keep the mesh you are working on, save it from the local mesh page "
            "(the 'Saved meshes and the plan' section, Save current mesh); it then "
            "shows up here.")
        self.record_note.setWordWrap(True)
        self.record_note.setStyleSheet("color: gray;")
        lay.addWidget(self.record_note)

        # what WILL be imported, shown before consent is asked — filled per visit.
        self.summary = QtWidgets.QLabel("")
        self.summary.setWordWrap(True)
        self.summary.setTextFormat(Qt.TextFormat.RichText)
        lay.addWidget(self.summary)

        # The Tor carry-over (#579), INLINE — never a modal (a modal in page logic
        # hangs headless tests). Hidden unless the imported mesh ran Tor; says what
        # the images will carry and names the platforms that cannot carry it.
        self.tor_note = QtWidgets.QLabel("")
        self.tor_note.setWordWrap(True)
        self.tor_note.setVisible(False)
        lay.addWidget(self.tor_note)

        # ── the k8s gate — INLINE and modeless (no QMessageBox/exec in page logic:
        # a modal here hangs headless tests; the checkbox + isComplete() is the
        # same gate, visible, and Next stays disabled until it is ticked). ──
        # A SHORT box plus a word-wrapped sentence beside it (#661). QCheckBox never
        # wraps its text: with the whole sentence on the box the page's minimum width
        # was 804 px inside the 736 px window, and every line on the page — this one,
        # the accounts line, the intro paragraph — was cut off at the right edge with
        # no sideways scroll. The label is the rest of the sentence and clicking it
        # ticks the box, so the whole line is still the one control.
        self.confirm = QtWidgets.QCheckBox(CONSENT_SHORT)
        self.confirm.toggled.connect(self._on_confirm_toggled)
        self.confirm_text = _ConsentText(CONSENT_REST, self.confirm)
        consent = QtWidgets.QWidget()
        crow = QtWidgets.QHBoxLayout(consent)
        crow.setContentsMargins(0, 0, 0, 0)
        crow.addWidget(self.confirm, 0, Qt.AlignmentFlag.AlignTop)
        crow.addWidget(self.confirm_text, 1)
        lay.addWidget(consent)

        # The consent ARMS the destructive verb; it never performs it on its own —
        # nothing on this page deletes a cluster without a press. `make kind-down`
        # then runs OFF the GUI thread: calling it inline (from validatePage, say)
        # would freeze the wizard for the minutes a teardown takes, and a silent
        # background mutation of the operator's cluster deserves the same streamed
        # log + Cancel surface every other long verb in the Studio has.
        row = QtWidgets.QWidget()
        brow = QtWidgets.QHBoxLayout(row)
        brow.setContentsMargins(0, 0, 0, 0)
        # LABELLED "Delete", not "Stop". Since #356 the Studio also ships a real
        # non-destructive stop (Halt DevOps lane, on the mesh monitor), and this
        # button used to be called "Stop Kubernetes now" while doing `kind delete
        # cluster`. With both verbs in one application that old label was actively
        # misleading: "stop" now means the halt, and this one destroys.
        self.down_btn = QtWidgets.QPushButton("Delete the Kubernetes cluster now")
        self.down_btn.setEnabled(False)
        self.down_btn.setToolTip(
            "DESTRUCTIVE: deletes the local Kubernetes cluster (`make kind-down` -> "
            "`kind delete cluster`). Destroys the DevOps lane ONLY — the docker mesh "
            "and every one of its volumes are untouched.\n\nThis is NOT the stop "
            "control. To stop the lane and KEEP it — cluster, PVCs, Vault KV and all "
            "— use `Halt DevOps lane` on the mesh monitor, or `make kind-halt`. This "
            "page needs the cluster gone, which is why the destructive one is here.\n\n"
            "Armed by the confirmation above; output streams below and Cancel stays "
            "available.")
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

    def _forget_domain_pages(self) -> None:
        """Tell the Domains table and the Domain services walk that their rows were
        replaced under them (see ``validatePage``). By slug through the wizard's page
        registry, so a flow built without one of the pages (a test wizard, a future
        route) is not a crash; the pages' own methods say what forgetting means."""
        ids = getattr(self.wiz, "_page_ids", None) or {}
        for slug, method in (("domains", "forget_rows"),
                             ("domain_services", "forget_answers")):
            page = self.wiz.page(ids[slug]) if slug in ids else None
            forget = getattr(page, method, None)
            if forget is not None:
                forget()

    def _forget_users_page(self) -> None:
        """Tell the Users table its rows were replaced under it (see ``validatePage``).
        Looked up by slug like ``_forget_domain_pages``, so a wizard without the page
        (a test wizard, a future route) is not a crash."""
        ids = getattr(self.wiz, "_page_ids", None) or {}
        page = self.wiz.page(ids["users"]) if "users" in ids else None
        forget = getattr(page, "forget_rows", None)
        if forget is not None:
            forget()

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
        records = self._fill_record_pick()
        if self._picked_id and self._picked_id not in {r.id for r in records}:
            self._picked_id = ""           # the picked record is gone
        if self._picked_id:
            self._select_pick(self._picked_id)
        self._read_identity()
        # Re-establish the k8s truth too — unless a teardown is still streaming
        # (the operator can walk Back and forward while `make kind-down` runs, and
        # that run, not a fresh probe, owns the gate until it finishes).
        if not self._running:
            self._k8s_up = None
            self._start_k8s_probe()
        self._sync_gate()
        self._render_summary()

    # ---- which saved mesh the import reads ----------------------------------------
    def _fill_record_pick(self) -> list:
        """Refill the picker from this checkout's records (plain file reads) and
        show it only when there is something to pick. Selects the default (row 0:
        the newest record that ran, else the newest draft — ``for_checkout``'s
        choice) without counting as a pick."""
        try:
            records = saved_meshes.records_for_checkout(self.wiz.generator_dir)
        except Exception:                    # noqa: BLE001 — offline read, never fatal
            records = []
        self._filling_pick = True
        try:
            self.record_pick.clear()
            for rec in records:
                self.record_pick.addItem(saved_mesh_choice_text(rec), rec.id)
            if records:
                self.record_pick.setCurrentIndex(0)
        finally:
            self._filling_pick = False
        self.record_row.setVisible(bool(records))
        return records

    def _select_pick(self, rec_id: str) -> None:
        idx = self.record_pick.findData(rec_id)
        if idx >= 0:
            self._filling_pick = True
            try:
                self.record_pick.setCurrentIndex(idx)
            finally:
                self._filling_pick = False

    def _read_identity(self) -> None:
        # LocalMeshIdentity(*...) so a canned 3-tuple (with_tor, no source) loads too.
        # The record id is passed only for an explicit pick, so a reader pinned with
        # the one-argument signature keeps working.
        gen = self.wiz.generator_dir
        raw = (local_mesh_identity(gen, record_id=self._picked_id) if self._picked_id
               else local_mesh_identity(gen))
        ident = LocalMeshIdentity(*raw)
        self._domain, self._users = ident.domain, list(ident.users)
        self._with_tor, self._source = bool(ident.with_tor), str(ident.source or "")
        self._mesh_domains = ident.mesh_domains

    def _on_record_picked(self, *_):
        """The operator picked a saved mesh: re-read what it imports, re-render the
        summary, and import afresh on Next (the one-shot latch is reset)."""
        if self._filling_pick:
            return
        try:
            rec_id = str(self.record_pick.currentData() or "")
            default = str(self.record_pick.itemData(0) or "")
            self._picked_id = "" if rec_id == default else rec_id
            self._imported = False
            self._read_identity()
            self._render_summary()
        except Exception as e:               # noqa: BLE001 — never kill the page
            self.summary.setText(f"Could not read that saved mesh: {html.escape(str(e))}")

    def _render_summary(self) -> None:
        listed = ", ".join(
            f"{name} ({roles if isinstance(roles, str) else ', '.join(roles)})"
            for name, roles in self._users)
        # RichText: every imported string is escaped (a record label is operator text).
        self.summary.setText(
            "<b>Imported from the local mesh:</b><br>"
            + (f"from the {html.escape(self._source)}<br>" if self._source
               else "no saved mesh for this checkout — the defaults below<br>")
            + f"apex domain <b>{html.escape(self._domain or '(brand default)')}</b>"
            + (f"<br>accounts: {html.escape(listed)}" if listed
               else "<br>accounts: none found on disk (unseeded or "
                    "terminal-managed mesh)")
            + f"<br>Tor onion: <b>{'on' if self._with_tor else 'off'}</b>"
            + "".join(f"<br>{'domains: ' if i == 0 else '&nbsp;' * 9}"
                      f"{html.escape(line)}"
                      for i, line in enumerate(
                          imported_domains_lines(self._mesh_domains))))
        self.tor_note.setText(localcloud_tor_note(LOCALCLOUD_PLATFORMS)
                              if self._with_tor else "")
        self.tor_note.setVisible(self._with_tor)

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
            # EVERY DOMAIN, not just the apex (#636) — after cluster_domain, which is
            # how the import tells the mesh's own row from the added ones. Shared with
            # the TUI (core.local_mesh_domains.apply_imported_domains), so the two faces
            # cannot import a different set of domains.
            apply_imported_domains(cfg, self._mesh_domains)
            # The rows were just REPLACED on the SAME configuration object, which the
            # two image-flow pages that hold a working copy of them cannot see: their
            # identity check only notices a NEW object (Load config, Redo). A Domains
            # table filled earlier in this Studio session, or a Domain services walk
            # made then, would otherwise be written back over the import on the way
            # to the build screen (post-merge review of PR #644).
            self._forget_domain_pages()
            # THE SAVED-MESH -> NODE-IMAGE BRIDGE (#579): a mesh that ran Tor builds
            # node images that carry it. Set on the BASE, as the mesh-wide default the
            # Network step owns (it shows there ticked, and can be unticked) — the
            # worklist rows do not exist yet at this point. materialize() emits it
            # through each platform's real channel: x86 --with-tor, rpi5 the `tor`
            # node slug (worklist._apply_infra_services), nothing where no builder
            # can bake it. Only ever turns it ON: a mesh without Tor leaves the
            # operator's own choice alone.
            if self._with_tor:
                cfg.tor_onion_service = True
            superdomain = cfg.effective_superdomain()
            # The saved mesh's accounts REPLACE ``cfg.users`` (like the domains above):
            # accounts an earlier flow of this Studio session left behind belong to
            # that flow, and would be built into these node images pinned to a domain
            # the manifest no longer carries (#707). A saved mesh with no accounts
            # therefore leaves none, which is also the truth.
            imported: list[User] = []
            taken: set[tuple[str, str]] = set()
            for username, roles in self._users:
                # ``roles`` is one role name or the list of them (issue #228 — the
                # canned fixtures and any older caller still hand in a bare string).
                roles = [roles] if isinstance(roles, str) else list(roles)
                # superadmins belong to the Tailscale root domain (spec 5 —
                # UsersPage locks their row there); everyone else lands on the
                # imported apex the local mesh served them on.
                dom = superdomain if "superadmin" in roles else cfg.cluster_domain
                if (username, dom) not in taken:
                    taken.add((username, dom))
                    imported.append(User(username=username, domain=dom, roles=roles))
            cfg.users = imported
            # Same shape of problem as the domain rows: the rows were replaced on the
            # SAME configuration object, so the Users table (a working copy keyed to
            # the object) cannot see it and would write its stale rows back over the
            # import. It forgets them and writes nothing until entered again.
            self._forget_users_page()
            # make the Users TABLE reachable so the imported accounts are visible
            # and editable (users_choice pre-selects the table card from this).
            cfg.configure_users = bool(cfg.users)
        # The teardown itself has ALREADY happened by the time this runs: the gate
        # above only opens once the probe says no cluster is up, so there is nothing
        # left to do here (and nothing destructive may run from validatePage — it is
        # re-entered by collect_all on every Build-page arrival).
        return True

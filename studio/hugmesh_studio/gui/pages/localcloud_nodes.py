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
  logic hangs headless tests, the repo-wide rule);
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

from ..qt import Qt, QtWidgets
from ._scroll import scrollable
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


class LocalCloudNodesPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self._imported = False       # one-shot import latch (see validatePage)
        self._domain = ""
        self._users: list[tuple[str, str]] = []
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

        self.gate_note = QtWidgets.QLabel(
            "The Studio does not take the k8s stack down for you yet: bring it "
            "down from the Local Docker Mesh page's DevOps controls or with "
            "`make kind-down` (the docker mesh and its volumes are untouched). "
            "Next stays disabled until you confirm.")
        self.gate_note.setWordWrap(True)
        self.gate_note.setStyleSheet("color: gray;")
        lay.addWidget(self.gate_note)
        lay.addStretch(1)

    # ---- slots (guarded: PyQt6 qFatals on an exception escaping a slot) ----------
    def _on_confirm_toggled(self, *_):
        try:
            self.completeChanged.emit()
        except Exception:                    # noqa: BLE001 — never crash the toggle
            pass

    # ---- wizard-flow contract (mirrors the other ModePage side-flow pages) -------
    def applies_to(self, cfg) -> bool:  # noqa: ARG002 — the hook's fixed signature
        # A WIZARD-transient choice, deliberately absent from cfg (ModePage keeps
        # cfg.mode an IMAGE mode until THIS page commits it on Next).
        return bool(getattr(self.wiz, "localcloud_selected", False))

    def isComplete(self) -> bool:
        # THE gate: nothing proceeds without the explicit k8s-will-stop consent.
        return self.confirm.isChecked()

    def initializePage(self):
        # Re-read the local mesh on EVERY forward entry (it may have been
        # re-bootstrapped since), reset the one-shot import latch, and CLEAR the
        # consent box — the confirmation is the point of this page, so it is
        # asked afresh each time the operator routes through it.
        self._imported = False
        self.confirm.setChecked(False)
        self._domain, self._users = local_mesh_identity(self.wiz.generator_dir)
        listed = ", ".join(f"{name} ({role})" for name, role in self._users)
        self.summary.setText(
            f"<b>Imported from the local mesh:</b><br>"
            f"apex domain <b>{self._domain or '(brand default)'}</b>"
            + (f"<br>accounts: {listed}" if listed
               else "<br>accounts: none found on disk (unseeded or "
                    "terminal-managed mesh)"))

    def validatePage(self) -> bool:
        if not self.confirm.isChecked():
            return False     # isComplete() already disables Next; guard collect too
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
        # TODO(issue #50, deferred): actually take the k8s stack down here by
        # wiring core.local_stack_node.LocalStackNode.devops_down() (`make
        # kind-down`) through a worker thread with streamed output, the way
        # LocalMeshPage runs its long verbs — a synchronous call in validatePage
        # would freeze the GUI for the minutes a teardown takes, and a silent
        # background mutation of the operator's cluster needs the same
        # cancel/log surface every other long verb has. Until then this gate
        # collects the explicit consent and the teardown is the manual step the
        # note above the checkbox names.
        return True

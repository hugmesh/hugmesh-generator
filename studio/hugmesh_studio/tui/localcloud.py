""""Create nodes for local cloud" — the TUI surface of GUI PR #65 (issue #50).

The gate between an already-running local Docker mesh and the node-image wizard.
Same semantics as ``gui/pages/localcloud_nodes.py``, restated for a prompt loop:

* IMPORT the local mesh's identity into the shared ImageConfig — the apex domain
  (-> ``cluster_domain``) and the Studio-provisioned accounts (minted superadmin
  + seeder roster; usernames/roles ONLY, never passwords). Superadmins land on
  the orchestration superdomain, everyone else on the imported apex, and
  ``configure_users`` flips on so the accounts are visible on the users step.
* The k8s GATE: nothing proceeds without the operator's explicit "k8s will stop
  to proceed" consent — asked afresh on every entry, inline (a y/N prompt IS the
  modeless form of the GUI's checkbox), and declining backs out with NOTHING
  committed.
* Then REJOIN the mesh chain (idp -> worklist -> ...): the gate commits
  ``cfg.mode = "mesh"`` itself and installs the worklist restriction
  (:data:`ALLOWED_ROLES` -> ``Journey.worklist_role_allow``) so the worklist
  offers ONLY the laptop and cluster-node image types.

The identity readers are Qt-free MIRRORS of the GUI page's (that module imports
the Qt binding at import time, so the TUI cannot reuse it directly);
test_tui_gui_parity.py pins both derivations against the GUI's where a Qt
binding exists, so they cannot drift silently.
"""
from __future__ import annotations

from ..core.config import (
    MODE_DEFAULT_ROLE, ROLE_CHOICES, User, enter_mesh_defaults, image_class,
)
from ..core.local_mesh_bootstrap import LocalMeshBootstrap
from ..core.seeded_credentials import load_roster

__all__ = ["ALLOWED_ROLES", "LocalCloudScreen", "apply_gate",
           "local_mesh_identity"]

#: The abbreviated worklist: ONLY the laptop and the cluster-node image types —
#: DERIVED from ROLE_CHOICES x image_class (never a hand-kept list), exactly the
#: GUI's LOCALCLOUD_ALLOWED_ROLES (parity-pinned).
ALLOWED_ROLES = tuple(
    role for role, _platforms, _label in ROLE_CHOICES["mesh"]
    if role == "laptop" or image_class("mesh", role) == "node")

# Casdoor role grants -> the User.role ladder (first match wins; everything else
# is a plain user). Only ROLES are imported — never passwords.
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
    """The local mesh's importable identity: ``(apex domain, [(username, role)])``.

    READ-ONLY and offline (plain file reads — no docker/compose probe): the apex
    from the bootstrap config's resolution, the accounts from the two channels
    the Studio itself provisioned — the minted superadmin in the runtime secrets
    bundle and the seeder's persona roster. Accounts created after go-live live
    in the mesh's identity tier; they cannot be enumerated from disk and do not
    need to be. Passwords are never read into the config."""
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


def apply_gate(journey, domain: str, users: list[tuple[str, str]]) -> None:
    """Commit the abbreviated mesh chain — the GUI gate's validatePage, mirrored.

    Applied ONCE per confirmed gate pass (the prompt loop has no collect_all
    re-run, so the GUI's one-shot latch is the flow itself here); the
    (username, domain) dedup below keeps even a repeat visit from stacking
    duplicate rows."""
    cfg = journey.cfg
    prev = cfg.mode
    cfg.mode = "mesh"
    if cfg.role not in {r for r, _, _ in ROLE_CHOICES["mesh"]}:
        cfg.role = MODE_DEFAULT_ROLE["mesh"]
    cfg.bundle_source = False            # mesh images never bundle the source
    enter_mesh_defaults(cfg, fresh=(prev != "mesh"))
    if prev != "mesh":
        journey.worklist = None          # fresh worklist on transition into mesh
    # THE abbreviation: restrict the worklist to the laptop + node rows. Lifted
    # by any other mode commit (Journey.commit_mode clears it).
    journey.worklist_role_allow = ALLOWED_ROLES
    if domain:
        cfg.cluster_domain = domain
    superdomain = cfg.effective_superdomain()
    existing = {(u.username, u.domain) for u in cfg.users}
    for username, role in users:
        # superadmins belong to the orchestration superdomain (UsersPage locks
        # them there); everyone else lands on the imported apex.
        dom = superdomain if role == "superadmin" else cfg.cluster_domain
        if (username, dom) not in existing:
            existing.add((username, dom))
            cfg.users.append(User(username=username, domain=dom, role=role))
    # make the users step reachable so the imported accounts are visible.
    cfg.configure_users = bool(cfg.users)


class LocalCloudScreen:
    """The gate screen: identity summary + the k8s consent, then the mesh chain."""

    slug = "localcloud"
    title = "Create nodes for local cloud"
    wants_q = True                       # q declines the gate (back, no residue)

    def __init__(self):
        self._domain = ""
        self._users: list[tuple[str, str]] = []

    def enter(self, j) -> None:
        # re-read on EVERY forward entry (the mesh may have been re-bootstrapped
        # since); consent is asked afresh each time — that is the point of the
        # page. local_mesh_identity is looked up on the MODULE so tests can pin
        # a canned mesh exactly as the GUI tests do.
        self._domain, self._users = local_mesh_identity(j.generator_dir)

    def lines(self, j) -> list[str]:  # noqa: ARG002 — screen-protocol signature
        listed = ", ".join(f"{name} ({role})" for name, role in self._users)
        return [
            "Turn the local Docker mesh into real device images. The "
            "abbreviated wizard ahead reuses the domain and accounts already "
            "provisioned here and offers only the laptop and cluster-node "
            "image types.",
            "",
            "Imported from the local mesh:",
            f"  apex domain: {self._domain or '(brand default)'}",
            "  accounts: " + (listed or "none found on disk (unseeded or "
                                        "terminal-managed mesh)"),
            "",
            "If this mesh has already gone LIVE with real users, that stays "
            "valid — accounts created after go-live live in the mesh's "
            "identity tier and keep working; they are simply not listed above.",
            "",
            "K8S GATE: the local Kubernetes (DevOps) stack must come down "
            "before these node images are configured and built. The Studio "
            "does not take it down for you yet: bring it down from the Local "
            "Docker Mesh flow's DevOps controls or with `make kind-down` (the "
            "docker mesh and its volumes are untouched).",
        ]

    def prompt(self, j) -> str:  # noqa: ARG002
        return ("I understand: k8s will stop to proceed — continue into the "
                "abbreviated mesh wizard? [y/N] ")

    def feed(self, j, line: str) -> None:
        if line.lower() in ("y", "yes"):
            apply_gate(j, self._domain, self._users)
            j.advance()                  # rejoin the mesh chain: idp -> worklist
            return
        # declining (or q/Enter/anything else) backs out with NOTHING committed
        # — the GUI's Back-without-residue, restated.
        j.status = "nothing committed — the gate needs the explicit consent."
        j.goto("mode")

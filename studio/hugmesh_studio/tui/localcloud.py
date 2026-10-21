""""Create nodes for local cloud" — the TUI surface of GUI PR #65 (issue #50).

The gate between an already-running local Docker mesh and the node-image wizard.
Same semantics as ``gui/pages/localcloud_nodes.py``, restated for a prompt loop:

* IMPORT the local mesh's identity into the shared ImageConfig — the apex domain
  (-> ``cluster_domain``) and the Studio-provisioned accounts (minted superadmin
  + seeder roster; usernames/roles ONLY, never passwords). Superadmins land on
  the Tailscale root domain, everyone else on the imported apex, and
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

from ..core import saved_meshes
from ..core.config import (
    MODE_DEFAULT_ROLE, ROLE_CHOICES, User, enter_mesh_defaults, image_class,
    normalize_user_roles,
)
from ..core.local_mesh_bootstrap import (
    LocalMeshBootstrap, LocalMeshIdentity, localcloud_tor_note, saved_mesh_choice_text,
    saved_mesh_source,
)
from ..core.local_mesh_domains import (
    apply_imported_domains, imported_domains_lines, imported_mesh_domains,
)
from ..core.seeded_credentials import load_roster

__all__ = ["ALLOWED_ROLES", "LocalCloudScreen", "apply_gate",
           "local_mesh_identity"]

#: The abbreviated worklist: ONLY the laptop and the cluster-node image types —
#: DERIVED from ROLE_CHOICES x image_class (never a hand-kept list), exactly the
#: GUI's LOCALCLOUD_ALLOWED_ROLES (parity-pinned).
ALLOWED_ROLES = tuple(
    role for role, _platforms, _label in ROLE_CHOICES["mesh"]
    if role == "laptop" or image_class("mesh", role) == "node")
#: ...and the platforms those rows come on (the GUI's LOCALCLOUD_PLATFORMS, same
#: derivation) — what the Tor note (#579) splits into "carries it" / "cannot".
PLATFORMS = tuple(dict.fromkeys(
    plat for role, platforms, _label in ROLE_CHOICES["mesh"]
    if role in ALLOWED_ROLES for plat in platforms))

# Casdoor role grants -> User.roles (issue #228: EVERY mapped grant is carried, not
# the top of a ladder — a persona holding ROLE_ADMIN and ROLE_GAMES imports as
# admin + games; anything unmapped contributes nothing, and a persona with no mapped
# grant is a plain user). The GUI twin (gui/pages/localcloud_nodes.py) keeps the
# same table. Only ROLES are imported — never passwords.
_CASDOOR_ROLE_MAP = (
    ("ROLE_SUPERADMIN", "superadmin"),
    ("ROLE_ADMIN", "admin"),
    ("ROLE_MOD", "mod"),
    ("ROLE_USER", "user"),
    ("ROLE_GAMES", "games"),
    ("ROLE_GAMES_SERVICES", "games-services"),
)


def _person_roles(roles) -> list[str]:
    return normalize_user_roles(
        [person for granted, person in _CASDOOR_ROLE_MAP if granted in roles])


def local_mesh_identity(generator_dir: str, record_id: str = "") -> LocalMeshIdentity:
    """The local mesh's importable identity: ``(apex domain, [(username, roles)...],
    with_tor, source, mesh_domains)`` — a :class:`LocalMeshIdentity`.

    READ-ONLY and offline (plain file reads, no docker/compose probe — this runs in
    a screen's ``enter`` and must never stall the prompt loop). The mesh's CONFIG comes from the newest saved-mesh record
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


def apply_gate(journey, domain: str, users: list[tuple[str, list[str]]],
               with_tor: bool = False, mesh_domains=None) -> None:
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
    # EVERY DOMAIN, not just the apex (#636) — the GUI gate's call, the same core
    # function, after cluster_domain (which tells the own row from the added ones).
    apply_imported_domains(cfg, mesh_domains)
    # THE SAVED-MESH -> NODE-IMAGE BRIDGE (#579), the GUI gate's rule restated: a
    # mesh that ran Tor sets the mesh-wide onion default on the base (the network
    # step shows it and can clear it); materialize() emits it per platform. Only
    # ever turns it ON.
    if with_tor:
        cfg.tor_onion_service = True
    superdomain = cfg.effective_superdomain()
    # The saved mesh's accounts REPLACE ``cfg.users`` (like the domains), the GUI
    # gate's rule restated (#707): accounts an earlier flow of the session left behind
    # are not part of this mesh. The (username, domain) dedup keeps a repeat visit —
    # and a duplicated imported row — from stacking.
    imported: list[User] = []
    taken: set[tuple[str, str]] = set()
    for username, roles in users:
        # ``roles`` is one role name or the list of them (issue #228 — the canned
        # fixtures and any older caller still hand in a bare string).
        roles = [roles] if isinstance(roles, str) else list(roles)
        # superadmins belong to the Tailscale root domain (UsersPage locks
        # them there); everyone else lands on the imported apex.
        dom = superdomain if "superadmin" in roles else cfg.cluster_domain
        if (username, dom) not in taken:
            taken.add((username, dom))
            imported.append(User(username=username, domain=dom, roles=roles))
    cfg.users = imported
    # make the users step reachable so the imported accounts are visible.
    cfg.configure_users = bool(cfg.users)


class LocalCloudScreen:
    """The gate screen: identity summary + the k8s consent, then the mesh chain."""

    slug = "localcloud"
    title = "Create nodes for local cloud"
    wants_q = True                       # q declines the gate (back, no residue)

    def __init__(self):
        self._domain = ""
        self._users: list[tuple[str, list[str]]] = []
        self._with_tor = False
        self._source = ""
        self._mesh_domains = None
        #: this checkout's saved meshes, the ones that RAN first (the GUI picker's
        #: list), and the one the operator picked by number ("" = the default)
        self._records: list = []
        self._picked_id = ""

    def enter(self, j) -> None:
        # re-read on EVERY forward entry (the mesh may have been re-bootstrapped
        # since); consent is asked afresh each time — that is the point of the
        # page. local_mesh_identity is looked up on the MODULE so tests can pin
        # a canned mesh exactly as the GUI tests do.
        try:
            self._records = saved_meshes.records_for_checkout(j.generator_dir)
        except Exception:                    # noqa: BLE001 — offline read, never fatal
            self._records = []
        if self._picked_id not in {r.id for r in self._records}:
            self._picked_id = ""
        self._read(j)

    def _read(self, j) -> None:
        # the record id rides only an explicit pick, so a reader pinned with the
        # one-argument signature keeps working
        raw = (local_mesh_identity(j.generator_dir, record_id=self._picked_id)
               if self._picked_id else local_mesh_identity(j.generator_dir))
        ident = LocalMeshIdentity(*raw)
        self._domain, self._users = ident.domain, list(ident.users)
        self._with_tor, self._source = bool(ident.with_tor), str(ident.source or "")
        self._mesh_domains = ident.mesh_domains

    def lines(self, j) -> list[str]:  # noqa: ARG002 — screen-protocol signature
        listed = ", ".join(
            f"{name} ({roles if isinstance(roles, str) else ', '.join(roles)})"
            for name, roles in self._users)
        return [
            "Turn the local Docker mesh into real device images. The "
            "abbreviated wizard ahead reuses the domain and accounts already "
            "provisioned here and offers only the laptop and cluster-node "
            "image types.",
            "",
            "Imported from the local mesh:",
            "  " + (f"from the {self._source}" if self._source
                    else "no saved mesh for this checkout — the defaults below"),
            f"  apex domain: {self._domain or '(brand default)'}",
            "  accounts: " + (listed or "none found on disk (unseeded or "
                                        "terminal-managed mesh)"),
            f"  Tor onion: {'on' if self._with_tor else 'off'}",
            *[("  domains: " if i == 0 else "           ") + line
              for i, line in enumerate(imported_domains_lines(self._mesh_domains))],
            *(["", localcloud_tor_note(PLATFORMS)] if self._with_tor else []),
            *self._pick_lines(),
            "",
            "If this mesh has already gone LIVE with real users, that stays "
            "valid — accounts created after go-live live in the mesh's "
            "identity tier and keep working; they are simply not listed above.",
            "",
            "K8S GATE: the local Kubernetes (DevOps) stack must come down "
            "before these node images are configured and built. THIS terminal "
            "flow does not take it down for you — the GUI's gate page runs the "
            "teardown itself; here, bring it down with `make kind-down` or from "
            "the Local Docker Mesh flow's DevOps controls (the docker mesh and "
            "its volumes are untouched).",
        ]

    def _pick_lines(self) -> list[str]:
        """The GUI's 'Import from saved mesh' picker as a numbered list (only when
        there is more than one record to choose from)."""
        if len(self._records) < 2:
            return []
        current = self._picked_id or self._records[0].id
        return ["", "Saved meshes of this checkout (type a number to import that one "
                    "instead; the ones that ran come first, drafts say 'never ran'):",
                *[f"  {i}) {saved_mesh_choice_text(r)}"
                  + ("   <- importing" if r.id == current else "")
                  for i, r in enumerate(self._records, 1)]]

    def prompt(self, j) -> str:  # noqa: ARG002
        pick = (f", or 1-{len(self._records)} to import another saved mesh"
                if len(self._records) > 1 else "")
        return ("I understand: k8s will stop to proceed — continue into the "
                f"abbreviated mesh wizard? [y/N{pick}] ")

    def feed(self, j, line: str) -> None:
        if line.strip().isdigit() and len(self._records) > 1:
            n = int(line.strip())
            if 1 <= n <= len(self._records):
                rec = self._records[n - 1]
                self._picked_id = "" if n == 1 else rec.id
                self._read(j)
                j.status = f"importing saved mesh '{rec.label or rec.id}'"
            else:
                j.status = f"no saved mesh numbered {n} — pick 1-{len(self._records)}"
            return                       # stay on the gate: consent is still asked
        if line.lower() in ("y", "yes"):
            apply_gate(j, self._domain, self._users, with_tor=self._with_tor,
                       mesh_domains=self._mesh_domains)
            j.advance()                  # rejoin the mesh chain: idp -> worklist
            return
        # declining (or q/Enter/anything else) backs out with NOTHING committed
        # — the GUI's Back-without-residue, restated.
        j.status = "nothing committed — the gate needs the explicit consent."
        j.goto("mode")

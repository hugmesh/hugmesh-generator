"""Is what the credentials dialog shows TRUE of the mesh that is running right now?

WHY THIS EXISTS. ``core/seeded_credentials.py`` answers "who does the seeder
provision, and with what password" by parsing the checkout's shell scripts and the
run-state credentials file. That is a correct answer to a question nobody asked.
The operator's question is "who can I log into THIS mesh as, right now" — and the
old surface answered it with four claims it could not support:

  1. THE ROSTER WAS THE CHECKOUT'S, NOT THE MESH'S. Every persona in
     seed-accounts.sh was listed whether or not `make stack-seed` had ever run
     against the stack that is up.
  2. THE PASSWORD WAS WHATEVER WAS ON DISK. ``.e2e-credentials`` survives a
     `stack-clean` that dropped the Casdoor volume it belonged to, so a file
     written weeks earlier was presented as the way in.
  3. ``mesh-operator`` WAS LED WITH UNCONDITIONALLY. It exists only on the
     ``SEED_COMPLETE_REGISTRATION=1`` path the Studio drives (seed-e2e.sh
     LOCAL_OPERATOR_*); a terminal `make stack-seed` never creates it, and the
     kind lane never runs that seeder at all.
  4. THE SUPERADMIN ROW WAS THE SCRIPT'S, NOT THE MINT'S. The extras file's
     ``${SUPERADMIN_PERSONA}`` default was shown, while the Studio actually seeded
     the username + password MINTED into keys-out/vault/secrets.json.

This module gathers FACTS about the running mesh and folds them into ONE statement
the GUI can render. Its halves are deliberately separate:

  * :func:`credentials_file` / :func:`read_values` — the ONE parser of the
    run-state credentials file (seeded_credentials delegates here). It keeps the
    OSError KIND instead of swallowing it: a root-owned file after a sudo
    `make e2e` is a permission problem with a named fix, not "(not seeded)".
  * :func:`assess` — PURE. No docker, no filesystem, no clock beyond the stamp it
    is handed. The whole state machine, and therefore the whole test surface, is
    driven with plain facts.
  * :func:`probe_credentials` — BLOCKING BY CONTRACT (docker + urlopen + stat).
    It gathers the facts and calls :func:`assess`. Callers run it on a worker
    thread; it never raises, and every gather failure downgrades ONE fact to
    unknown rather than failing the whole answer.

HOW A SEED IS CORROBORATED. Every `make stack-seed` STARTS a run: tests/stack/
e2e-password.sh's ``e2e_password_start_run`` writes a NEW value to the file before
seeding (unless E2E_PASSWORD is set or E2E_PASSWORD_KEEP=1, which reuse it — the
Studio's Add user and saved-mesh restore pass KEEP), and the seeder's apply hook
reconciles every stored password to that value (seed-accounts.sh "rotated N
password(s) reconciled"). A seed that dies after the rotation leaves the file
NEWER than the last completed seed — the stale shape below. So the
identities in a Casdoor volume hold the file's value exactly when a seed
COMPLETED after the file was last written — and that completion is what the
Studio's own run log records (``<state>/logs/<stamp>-Bootstrapping-ok.log`` and
``…-Adding-user-<name>-ok.log``; both verbs run `make stack-seed`) — and, for a
seed run from a TERMINAL, the seed stamp seed-e2e.sh writes beside the credentials
file once its identity leg is verified (``<file>.seeded``: the file's sha256 + a
time; :func:`seed_stamp`, trusted only while the sha256 still matches). Mtime order
between the file and the volume proves NOTHING on its own: a second-generation
mesh (volume recreated, file reused) is valid with an OLDER file, and a file
regenerated after a seed is stale with a NEWER one. The stale shape seed-e2e.sh
leg 1c names ("a persisted casdoor volume + a lost/regenerated .e2e-credentials")
is therefore "file rewritten AFTER the last completed seed".

TRI-STATE, NEVER A FALSE NEGATIVE. "I could not establish it" is rendered as
unknown, never as "no". A mesh whose docker daemon is unreachable is not an
unseeded mesh, and saying the stored password is wrong is as much a lie as saying
it is right. Unknown keeps the passwords on screen and MARKS them unverified.

THE KIND LANE IS ASKED, NOT ASSUMED (#539). This module used to declare the kind
lane unknown BY CONSTRUCTION — "its Casdoor is ClusterIP with no host port, so
nothing here can ask it anything". That premise was measurably false, and the cost
of believing it was an operator report: a kind mesh whose identity seed had never
run (bootstrap-kind.sh exited at the step-10 `wait_job casdoor-init` during the
#396 sign-in lockout, while ArgoCD carried on converging) served a healthy login
page over an EMPTY identity store, and this table answered "who can I sign in as"
with the CHECKOUT's roster and a real-looking password. Casdoor's database is a
pod, and a pod can be read without any host port:

    kubectl -n hugmesh-pki exec deploy/casdoor-pg -- \
      psql -U casdoor -d casdoor -Atc 'select owner, name from "user" ...'

So :func:`gather_kind_identities` asks the RUNNING cluster who it holds, and
:func:`annotate` marks every persona the cluster does not have ``not seeded``
INSTEAD of showing it with a password. Three things that read the same to a
careless probe are kept apart, because their fixes differ:

  * the cluster answered and holds no personas  -> up-unseeded ("re-run the seed")
  * the cluster could not be asked              -> unknown ("fix the probe's access")
  * the lane is HALTED (casdoor-pg at 0 replicas) -> unknown, naming the halt

THE HALT IS NOT AN ERROR PATH, IT IS THE COMMON ONE. `kubectl exec deploy/X` on a
Deployment scaled to 0 does not fail — it BLOCKS until its own timeout waiting for
a pod (measured on the halted reference cluster: 40s, killed by `timeout`, no
diagnostic). So the gatherer reads ``.status.readyReplicas`` FIRST and never
issues an exec it knows will hang.

SECRET DISCIPLINE. :class:`CredentialsFile` carries key NAMES only, never a value.
:attr:`CredentialTruth.headline` and :attr:`~CredentialTruth.detail` are asserted
password-free by test — they are the strings that reach tooltips, banners and the
page's state line, any of which can end up in a screenshot or a run log. Only
:class:`~hugmesh_studio.core.seeded_credentials.SeededUser` rows carry values, and
only the dialog renders those. Nothing here writes anything anywhere.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import time
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime

# ONE reader of the compose project + its label, so a volume question asked here
# can never disagree with the volume manager's own answer.
from .vaults import DEFAULT_PROJECT as COMPOSE_PROJECT
from .vaults import _LBL_PROJECT as _COMPOSE_LABEL

# ── the eight states ─────────────────────────────────────────────────────────────
#: Nothing was established: docker unreachable, a probe failed, a seed this Studio
#: did not record, or the kind lane (unknown by construction — see the module doc).
STATE_UNKNOWN = "unknown"
#: Nothing is up and no identity store survives — the roster is a FORECAST.
STATE_NO_MESH = "no-mesh"
#: Stopped but not destroyed: `Stop mesh` is `make stack-halt`, which KEEPS the
#: volumes, so the identities (and their passwords) are still there for a restart.
STATE_HALTED = "halted"
#: Containers are up, but Casdoor holds no seeded persona yet.
STATE_UP_UNSEEDED = "up-unseeded"
#: Up, seeded, and a seed completed after the password on disk was written.
STATE_SEEDED = "seeded"
#: Up and seeded, but the password on disk was rewritten AFTER the last completed
#: seed — the identities hold a previous value and every sign-in will 401.
STATE_SEEDED_SUSPECT = "seeded-suspect"
#: A bring-up minted a superadmin bundle and no seed has completed since.
STATE_MINTED_NOT_SEEDED = "minted-not-seeded"
#: The run-state file exists but this user cannot read it (root-owned 0600).
STATE_UNREADABLE = "unreadable"

#: Every state, so a caller can pin the set without re-listing it.
STATES = (STATE_UNKNOWN, STATE_NO_MESH, STATE_HALTED, STATE_UP_UNSEEDED,
          STATE_SEEDED, STATE_SEEDED_SUSPECT, STATE_MINTED_NOT_SEEDED,
          STATE_UNREADABLE)

#: The lanes a truth can be about. "" = no lane established.
LANE_COMPOSE = "compose"
LANE_KIND = "kind"

# ── per-user liveness markers (SeededUser.live) ───────────────────────────────────
#: A seed completed with the password shown, and this persona is on that lane.
LIVE = "live"
#: The identities exist but hold a password the file no longer holds (401s).
STALE = "stale"
#: The identities exist in a stopped mesh's kept volume; valid on the next start.
HALTED = "halted"
#: No identity store holds this persona right now.
NOT_SEEDED = "not seeded"
#: This lane's seeder never creates this persona (mesh-operator off the Studio path).
NOT_ON_LANE = "not on this lane"
#: The identity EXISTS but holds none of the roles the roster says it should (#539).
#: Casdoor's ``role`` rows carry their members, and a persona in none of its own
#: roles is not a working sign-in: the gateway floor alone lets it authenticate and
#: then 403 on everything, which reads to an operator exactly like a wrong password.
#: Never inferred from an absence — only from a role table this Studio actually read.
NO_ROLES = "no roles"
#: The value shown may well be right; nothing here could corroborate it.
UNVERIFIED = "unverified"
#: Nothing could be established — the probe's own access failed (no kubectl, a
#: halted lane, an API that did not answer). NOT "this account does not exist":
#: that is NOT_SEEDED, and the two have different fixes.
UNKNOWN = "unknown"
#: Created by this session's Add user; its password was never stored.
ADDED = "added this session"

MARKERS = (LIVE, STALE, HALTED, NOT_SEEDED, NOT_ON_LANE, NO_ROLES, UNVERIFIED,
           UNKNOWN, ADDED)

# The env knob and default name of the run-state credentials file
# (tests/stack/e2e-password.sh CONTRACT rule 3). seeded_credentials keeps no copy
# of these — it delegates both the path rule and the parse here, so there is
# exactly one parser and exactly one place the default name is written down.
CREDENTIALS_FILE_ENV = "E2E_CREDENTIALS_FILE"
CREDENTIALS_FILE_NAME = ".e2e-credentials"
SHARED_PASSWORD_ENV = "E2E_PASSWORD"

#: The identity store. `docker volume inspect <project>_casdoor-pg` says whether the
#: CURRENT Casdoor database exists and when it was created.
IDENTITY_VOLUME_SUFFIX = "casdoor-pg"
#: The persona seed-e2e.sh leg 1 always creates — its presence is "seeded".
SEED_WITNESS_USER = "e2e-admin"

# ── the kind lane's identity store (#539) ─────────────────────────────────────────
# Casdoor on the kind lane keeps every org/role/user in a dedicated Postgres,
# specs/cluster/manifests/casdoor/pg.yaml: Deployment ``casdoor-pg`` in namespace
# ``hugmesh-pki``, POSTGRES_DB ``casdoor``, and the DB user fixed at ``casdoor`` by
# the casdoor-db ExternalSecret template (scripts/gen-cluster-secrets.sh: "The DB
# user is the fixed 'casdoor' … only the password is minted"). Named here rather
# than parsed out of the manifest because these three are what the manifest's own
# readinessProbe hard-codes (`pg_isready -U casdoor -d casdoor`) — if they ever
# move, that probe moves with them and this constant is the next thing to fix.
KIND_CASDOOR_NS = "hugmesh-pki"
KIND_CASDOOR_DB_DEPLOY = "casdoor-pg"
KIND_CASDOOR_DB_USER = "casdoor"
KIND_CASDOOR_DB_NAME = "casdoor"
#: Where bootstrap-kind.sh records the password its seed actually used. Absent =
#: the seed never got that far (which is exactly what #539 found on the reference
#: cluster). Read ONLY to compare against the value already on screen; the value
#: never reaches a dataclass, a log or the GUI.
KIND_SEED_SECRET_NS = "hugmesh-frontend"
KIND_SEED_SECRET = "test-seed-passwords"
KIND_SEED_SECRET_KEY = "E2E_PASSWORD"

#: The issue's own query, verbatim, so what the Studio reads and what an operator
#: can reproduce at a terminal are the same statement. ``-A -t`` makes psql print
#: ``owner|name`` rows with no header and no padding.
KIND_USERS_SQL = 'select owner, name from "user" order by owner, name'
#: Casdoor's ``role`` rows carry their membership as a JSON array of ``owner/name``
#: in the ``users`` column (xorm ``Users []string``). ``users`` is the LAST field,
#: so a ``|`` split with maxsplit=1 cannot be confused by the JSON.
KIND_ROLES_SQL = 'select name, users from "role" order by name'

#: Per-call ceilings. The readiness read is tiny; the two execs each go through the
#: API server into a pod. NOTHING here may be unbounded: `kubectl exec deploy/<x>`
#: on a Deployment scaled to 0 BLOCKS waiting for a pod instead of failing, so an
#: unbounded call on a halted lane hangs the probe thread forever.
#: `make kind-halt`'s record, and where it lives — kept in step with
#: scripts/kind-halt.sh's own ARGOCD_NS / STATE_CM defaults (and with
#: mesh_monitor's copy of them).
KIND_HALT_NS = "devops"
KIND_HALT_CM = "hugmesh-kind-halt"

KIND_READY_TIMEOUT_S = 15
KIND_EXEC_TIMEOUT_S = 25
KIND_SECRET_TIMEOUT_S = 15

#: The Studio's run-log names for the THREE verbs that run `make stack-seed`
#: (localmesh.py `_launch("Bootstrapping", …)`, `_launch(f"Adding user {u}", …)`
#: and the saved-mesh lane's `_launch(f"Restoring saved mesh {label}", …)` — a
#: cold restore is start + seed; all slugified by `_save_run_log`). A `-ok.log`
#: of any of them is the only in-Studio record that a seed COMPLETED. "Starting
#: saved mesh" is deliberately NOT here: a warm start reattaches volumes and
#: seeds nothing, so it says nothing about the identities' password.
_SEED_LOG_RE = re.compile(
    r"^(?P<stamp>\d{8}-\d{6})-(?:Bootstrapping|Adding-user-.*|Restoring-saved-mesh-.*)"
    r"-ok\.log$")

#: Shown IN the password cell when the file cannot be read: the resolver's
#: "(not seeded)" marker would be false, and a plausible-looking value worse.
UNREADABLE_MARKER = "(credentials file unreadable — see the banner)"
#: Shown in the password cell of a user this session added: the value went to the
#: seeder's env only and was never kept anywhere the Studio could re-read.
ADDED_MARKER = "(added this session — password not stored)"

# The chown fix e2e-password.sh prints for exactly this case (its
# e2e_password_read) — repeated here so the GUI hands over the same remedy.
_CHOWN_FIX = ("A sudo run (`make e2e` drives QEMU as root) writes it root-owned "
              "0600. Fix: `sudo chown $(id -un) {path}` — or delete it and re-seed.")


@dataclass(frozen=True)
class CredentialsFile:
    """What the run-state credentials file IS — never what it contains.

    ``keys`` is the KEY NAMES only. This struct is handed to tooltips and status
    lines, so it must stay safe to render anywhere; the values go to the roster,
    which only the dialog's table renders."""
    path: str
    exists: bool
    readable: bool
    mtime: float | None
    error: str
    keys: tuple[str, ...]

    @property
    def written(self) -> str:
        return fmt_time(self.mtime) if self.mtime is not None else ""


@dataclass(frozen=True)
class CredentialTruth:
    """ONE statement about the credentials of the mesh that is (or is not) running.

    ``headline`` is one sentence for a banner; ``detail`` is the longer text with
    the fix when there is one. Both are password-free by contract (test-enforced).
    ``superadmin`` is the (username, password) MINTED into secrets.json — the only
    value carried here, because it is what the superadmin ROW renders; the strings
    above never quote it."""
    state: str
    lane: str
    headline: str
    detail: str
    file: CredentialsFile
    #: When the last seed COMPLETED, as recorded by this Studio ("" = no record).
    seeded_at: str
    #: Did registration stage 2 run (mesh-operator exists)? None = not established.
    stage2: bool | None
    #: The operator account this lane's seeder would create ("" when it never does).
    operator_user: str
    #: (username, password) from secrets.json; ("", "") when no bundle is readable.
    superadmin: tuple[str, str]
    checked_at: str
    #: Is the MINTED superadmin proven seeded? None = not established.
    superadmin_seeded: bool | None = None
    #: The liveness marker every shared-password persona gets (see MARKERS).
    marker: str = UNVERIFIED
    #: When set, REPLACES the password cell of every shared-password persona.
    password_marker: str = ""
    #: The usernames the RUNNING identity store actually holds (#539), or None when
    #: nothing could be read. NOT a roster: it is whatever Casdoor answered with,
    #: service accounts included. ``annotate`` joins it per row, so a persona the
    #: mesh does not have is marked ``not seeded`` instead of being shown with a
    #: password. None never becomes "absent" — that is the whole tri-state rule.
    present_users: frozenset[str] | None = None
    #: ``(ROLE_NAME, {members})`` pairs read from the live role table, or None when
    #: the role read failed (the user read can succeed while this one does not, and
    #: then no row may be marked ``no roles``). A tuple, not a dict, so this frozen
    #: dataclass stays hashable.
    role_members: tuple[tuple[str, frozenset[str]], ...] | None = None

    @property
    def verified(self) -> bool:
        """True only when a shown password has been positively corroborated."""
        return self.state == STATE_SEEDED

    def holds_any_role(self, user: str, roles) -> bool | None:
        """Is ``user`` a member of ANY of ``roles`` in the live store? None = the
        role table was not read, so nothing may be concluded either way."""
        if self.role_members is None:
            return None
        wanted = {r for r in (roles or ()) if r}
        if not wanted:
            # A roster row with no roles at all cannot be failed on its roles.
            return True
        members = {name: mem for name, mem in self.role_members}
        return any(user in members.get(r, frozenset()) for r in wanted)


# ── the run-state file ────────────────────────────────────────────────────────────

def _credentials_path(generator_dir: str | None, env: Mapping[str, str] | None) -> str:
    src = env if env is not None else os.environ
    return src.get(CREDENTIALS_FILE_ENV) or (
        os.path.join(generator_dir, CREDENTIALS_FILE_NAME) if generator_dir else "")


def _parse_kv(lines) -> dict[str, str]:
    """Plain ``KEY=value`` lines, no quotes, no export keyword (CONTRACT rule 3) —
    the same shape `set -a; . file; set +a` and `docker compose --env-file` accept."""
    out: dict[str, str] = {}
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        out[key.strip()] = val.strip()
    return out


def credentials_file(generator_dir: str | None,
                     env: Mapping[str, str] | None = None) -> CredentialsFile:
    """Describe the run-state credentials file — KEY NAMES only, never a value.

    Honours ``E2E_CREDENTIALS_FILE`` from ``env`` (else os.environ), defaulting to
    ``<generator_dir>/.e2e-credentials``. The OSError KIND survives into
    ``error``/``readable`` instead of being swallowed, so a root-owned file after a
    sudo `make e2e` can be reported as the permission problem it is."""
    path = _credentials_path(generator_dir, env)
    if not path:
        return CredentialsFile(path="", exists=False, readable=False, mtime=None,
                               error="no credentials-file path (no generator dir)",
                               keys=())
    try:
        st = os.stat(path)
    except FileNotFoundError:
        return CredentialsFile(path=path, exists=False, readable=False, mtime=None,
                               error="absent", keys=())
    except OSError as e:
        return CredentialsFile(path=path, exists=False, readable=False, mtime=None,
                               error=f"{type(e).__name__}: {e.strerror or e}", keys=())
    mtime = float(st.st_mtime)
    try:
        with open(path, encoding="utf-8") as fh:
            keys = tuple(_parse_kv(fh.readlines()).keys())
    except PermissionError as e:
        return CredentialsFile(path=path, exists=True, readable=False, mtime=mtime,
                               error=f"PermissionError: {e.strerror or e}", keys=())
    except OSError as e:
        return CredentialsFile(path=path, exists=True, readable=False, mtime=mtime,
                               error=f"{type(e).__name__}: {e.strerror or e}", keys=())
    except UnicodeDecodeError as e:
        return CredentialsFile(path=path, exists=True, readable=False, mtime=mtime,
                               error=f"not a text file: {e}", keys=())
    return CredentialsFile(path=path, exists=True, readable=True, mtime=mtime,
                           error="", keys=keys)


def read_values(generator_dir: str | None,
                env: Mapping[str, str] | None = None) -> dict[str, str]:
    """The file's ``KEY=value`` pairs — {} when absent/unreadable/unparseable, so a
    resolver falls through to its not-seeded marker instead of raising. This is the
    ONE parser; seeded_credentials._read_credentials_file wraps it."""
    path = _credentials_path(generator_dir, env)
    if not path:
        return {}
    try:
        with open(path, encoding="utf-8") as fh:
            return _parse_kv(fh.readlines())
    except (OSError, UnicodeDecodeError):
        return {}


# ── the seed stamp (tests/stack/e2e-password.sh, e2e_password_stamp_seeded) ────────

#: Suffix of the stamp file the compose seeder writes beside the credentials file.
SEED_STAMP_SUFFIX = ".seeded"


def seed_stamp_path(cred_path: str) -> str:
    return f"{cred_path}{SEED_STAMP_SUFFIX}" if cred_path else ""


def file_sha256(path: str) -> str:
    """Hex sha256 of a file, "" when it cannot be read (the fingerprint the stamp
    and the saved-mesh records both use)."""
    h = hashlib.sha256()
    try:
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(65536), b""):
                h.update(chunk)
    except OSError:
        return ""
    return h.hexdigest()


def seed_stamp(cred_path: str) -> float | None:
    """When did a seed last reconcile the identity store to THIS credentials file
    — or None when nothing vouches for the file as it is now.

    seed-e2e.sh writes ``<file>.seeded`` once its identity leg is verified, holding
    the sha256 of the credentials file it reconciled to. It is trusted ONLY while
    that sha256 still equals the file on disk: any rewrite since (another lane's
    run start, a saved-mesh put-back of a different copy, a hand edit) and the
    stamp vouches for nothing. This is the record a TERMINAL ``make stack-seed``
    leaves — the Studio's own run log only covers the seeds it launched. Never
    raises; the stamp holds a hash and a time, never a value."""
    stamp = seed_stamp_path(cred_path)
    if not stamp:
        return None
    try:
        with open(stamp, encoding="utf-8") as fh:
            kv = _parse_kv(fh.readlines())
    except (OSError, UnicodeDecodeError):
        return None
    want = kv.get("E2E_SEEDED_SHA256", "").lower()
    if len(want) != 64 or file_sha256(cred_path) != want:
        return None
    try:
        at = float(kv.get("E2E_SEEDED_AT", ""))
    except ValueError:
        return None
    # The stamp's clock is whole seconds and the file's mtime is not; with the
    # fingerprint matching, the identities hold exactly this file's value, so the
    # seed counts as no older than the file it reconciled to.
    try:
        at = max(at, float(os.stat(cred_path).st_mtime))
    except OSError:
        pass
    return at


# ── small pure helpers ────────────────────────────────────────────────────────────

def fmt_time(epoch: float | None) -> str:
    if epoch is None:
        return ""
    try:
        return time.strftime("%Y-%m-%d %H:%M", time.localtime(epoch))
    except (OverflowError, ValueError, OSError):
        return ""


def parse_docker_time(text: str) -> float | None:
    """`docker volume inspect --format {{.CreatedAt}}` → epoch seconds, or None.

    Docker prints RFC-3339 with an offset (``2026-08-27T06:20:11-07:00``); some
    builds print Go's default layout (``2026-08-27 06:20:11 -0700 PDT``). Anything
    else is "not established" — never a guessed time."""
    s = (text or "").strip()
    if not s:
        return None
    try:
        return datetime.fromisoformat(s).timestamp()
    except ValueError:
        pass
    m = re.match(r"^(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})(?:\.\d+)?\s*([+-]\d{4})", s)
    if m:
        try:
            return datetime.strptime(f"{m.group(1)} {m.group(2)}",
                                     "%Y-%m-%d %H:%M:%S %z").timestamp()
        except ValueError:
            try:
                return datetime.strptime(f"{m.group(1)} {m.group(2)}",
                                         "%Y-%m-%dT%H:%M:%S %z").timestamp()
            except ValueError:
                return None
    return None


def last_seed_ok(logs_dir: str) -> float | None:
    """When did a seeding verb last COMPLETE, per this Studio's run logs?

    The stamp in the file name is taken over the mtime: `_save_run_log` writes the
    file at the moment the verb finishes, so the two agree, but the name survives a
    copy/backup/restore that the mtime would not. None = no record (a terminal
    `make stack-seed` leaves none — which is why "no record" is *unverified*,
    never "not seeded")."""
    try:
        names = os.listdir(logs_dir)
    except OSError:
        return None
    best: float | None = None
    for name in names:
        m = _SEED_LOG_RE.match(name)
        if not m:
            continue
        try:
            when = time.mktime(time.strptime(m.group("stamp"), "%Y%m%d-%H%M%S"))
        except (ValueError, OverflowError):
            try:
                when = os.stat(os.path.join(logs_dir, name)).st_mtime
            except OSError:
                continue
        if best is None or when > best:
            best = when
    return best


def _newer(a: float | None, b: float | None) -> bool | None:
    """a > b, or None when either side is not established."""
    if a is None or b is None:
        return None
    return a > b


# ── the kind lane's identity store: pure parsers (#539) ───────────────────────────

@dataclass(frozen=True)
class KindIdentities:
    """What the RUNNING kind Casdoor holds — or why it could not be asked.

    ``users``/``roles`` are None when NOT ESTABLISHED, never empty-as-a-guess. They
    are independent: the user read can land while the role read does not, and then
    the roster shows real presence with no role verdict at all, which is the honest
    pair. ``reason`` is operator-facing prose naming the access problem, so the
    banner can say "this Studio cannot tell, and here is what to fix" rather than
    the much scarier "this mesh has nobody in it".

    ``password_matches`` compares the on-screen shared password against the value
    bootstrap-kind.sh recorded in the ``test-seed-passwords`` Secret. Only the
    BOOLEAN survives this dataclass — the secret's value is compared inside the
    gatherer and dropped."""
    users: frozenset[str] | None = None
    roles: tuple[tuple[str, frozenset[str]], ...] | None = None
    reason: str = ""
    #: True when the lane's own halt record explains an unreadable store.
    halted: bool | None = None
    password_matches: bool | None = None


def parse_psql_users(text: str) -> frozenset[str] | None:
    """``owner|name`` rows from ``psql -At`` -> the bare usernames.

    None when the output cannot be read as that shape AT ALL, because a probe that
    silently turns a psql error page into "zero users" reports an unseeded mesh for
    what is really a broken read — the exact false negative this module forbids.
    An output with no rows at all IS a real empty answer (`frozenset()`), and that
    is the state #539 was reported over."""
    if text is None:
        return None
    lines = [ln.strip() for ln in str(text).splitlines() if ln.strip()]
    if not lines:
        return frozenset()
    out: set[str] = set()
    for ln in lines:
        if "|" not in ln:
            # psql error prose ("ERROR:  relation ... does not exist", "could not
            # connect"), a kubectl diagnostic, anything but a row.
            return None
        _owner, _, name = ln.partition("|")
        name = name.strip()
        if not name:
            return None
        out.add(name)
    return frozenset(out)


def parse_psql_roles(text: str) -> tuple[tuple[str, frozenset[str]], ...] | None:
    """``name|["owner/user", …]`` rows -> ``(ROLE, {bare usernames})`` pairs.

    ONE unparseable row voids the WHOLE answer. A partial role table would mark a
    persona "no roles" on the strength of a row this Studio failed to read, which
    is a fabricated negative about a sign-in — worse than no verdict."""
    if text is None:
        return None
    lines = [ln.strip() for ln in str(text).splitlines() if ln.strip()]
    if not lines:
        return ()
    pairs: list[tuple[str, frozenset[str]]] = []
    for ln in lines:
        if "|" not in ln:
            return None
        name, _, raw = ln.partition("|")
        name = name.strip()
        raw = raw.strip()
        if not name:
            return None
        if not raw:
            pairs.append((name, frozenset()))
            continue
        try:
            members = json.loads(raw)
        except ValueError:
            return None
        if members is None:
            members = []
        if not isinstance(members, list):
            return None
        bare: set[str] = set()
        for m in members:
            if not isinstance(m, str):
                return None
            # Casdoor stores membership as "owner/name".
            bare.add(m.rsplit("/", 1)[-1].strip())
        pairs.append((name, frozenset(bare)))
    return tuple(pairs)


# ── the state machine ─────────────────────────────────────────────────────────────

def assess(*, mesh_running: bool | None, volumes_present: bool | None,
           seeded_admin: bool | None, seeded_operator: bool | None,
           creds: CredentialsFile, casdoor_created: float | None,
           secrets_mtime: float | None, last_seed_ok: float | None,
           lane: str = LANE_COMPOSE, operator_user: str = "",
           superadmin: tuple[str, str] = ("", ""), env_password: bool = False,
           status_detail: str = "", checked_at: str = "",
           kind: "KindIdentities | None" = None) -> CredentialTruth:
    """Fold plain facts into ONE :class:`CredentialTruth`. PURE — no I/O.

    Facts (None = not established, and None never becomes a claim):
      mesh_running     the compose project has containers (LocalStackNode.status)
      volumes_present  the identity volume ``<project>_casdoor-pg`` exists
      seeded_admin     Casdoor answered and holds/does not hold ``e2e-admin``
      seeded_operator  same for the lane's operator account
      creds            the run-state credentials file (names + mtime, no values)
      casdoor_created  the identity volume's CreatedAt (epoch)
      secrets_mtime    keys-out/vault/secrets.json's mtime (the last MINT)
      last_seed_ok     when a seed last COMPLETED: this Studio's run log, or the
                       seed stamp beside the credentials file (seed_stamp)
      lane             "compose" | "kind" | ""
      env_password     E2E_PASSWORD is set in the seeder's env (file not needed)
      kind             what the RUNNING kind Casdoor holds (#539), or None when
                       this is not the kind lane. Its own fields are tri-state.
    """
    checked_at = checked_at or time.strftime("%Y-%m-%d %H:%M:%S")
    seeded_at = fmt_time(last_seed_ok)
    sa_user, sa_pw = (superadmin or ("", ""))
    sa_ok = bool(sa_user and sa_pw)
    # The MINTED superadmin is proven seeded only when a seed completed after the
    # mint AND the identity store that seed populated is the one that exists now.
    # A store (re)created after the last recorded seed was populated by a run this
    # Studio did not record (a terminal seed), so the record proves nothing about
    # it. Measured on the reference host 2026-09-02: mint 04:40, recorded seed
    # 04:43, stack-clean 04:49, a new casdoor-pg at 07:29 — "seeded" was a lie.
    minted_after_seed = _newer(secrets_mtime, last_seed_ok)
    # TRI-STATE on purpose: True / False / None. `docker volume inspect` can
    # fail, or print a layout parse_docker_time does not recognise, and then the
    # store's age is NOT ESTABLISHED. Coercing that None to False would hand back
    # the strongest positive claim ("live", "still valid for the next start")
    # about a store nothing dated — the exact lie this guard exists to stop.
    store_after_record = _newer(casdoor_created, last_seed_ok)
    if secrets_mtime is None:
        superadmin_seeded: bool | None = False if not sa_ok else None
    elif last_seed_ok is None or store_after_record is not False:
        superadmin_seeded = None
    else:
        superadmin_seeded = not minted_after_seed
    # The stale shape seed-e2e.sh leg 1c names: the run-state file rewritten AFTER
    # the last recorded seed (moot when the seeder took E2E_PASSWORD from its env).
    file_after_record = bool(not env_password and creds.mtime is not None
                             and last_seed_ok is not None
                             and creds.mtime > last_seed_ok)
    # Does the recorded seed vouch for the store that exists now, holding the
    # password on disk now? Only then is a value "still valid" / "live".
    record_covers = (last_seed_ok is not None and store_after_record is False
                     and not file_after_record)
    minted_unseeded = secrets_mtime is not None and (
        last_seed_ok is None or bool(minted_after_seed))

    def truth(state: str, headline: str, detail: str, *, marker: str,
              stage2: bool | None, lane_: str = lane, op: str = operator_user,
              sa_seeded: bool | None = superadmin_seeded,
              password_marker: str = "",
              present: "frozenset[str] | None" = None,
              role_members: "tuple[tuple[str, frozenset[str]], ...] | None" = None
              ) -> CredentialTruth:
        return CredentialTruth(
            state=state, lane=lane_, headline=headline, detail=detail, file=creds,
            seeded_at=seeded_at, stage2=stage2, operator_user=op,
            superadmin=(sa_user, sa_pw) if sa_ok else ("", ""),
            checked_at=checked_at, superadmin_seeded=sa_seeded, marker=marker,
            password_marker=password_marker, present_users=present,
            role_members=role_members)

    file_line = (f"Credentials file: {creds.path} (written {creds.written})."
                 if creds.exists else
                 (f"Credentials file: none at {creds.path}." if creds.path
                  else "Credentials file: no path."))
    seed_line = (f"Last completed seed on record: {seeded_at}."
                 if seeded_at else
                 "No completed seed is on record: neither this Studio's run log nor "
                 "a seed stamp that still matches the credentials file (a terminal "
                 "`make stack-seed` writes one beside it once its identity leg is "
                 "verified).")

    # (g) A file that exists but cannot be read is the most actionable state there
    # is, whatever the mesh is doing — and nothing below could compare values or
    # times honestly without reading it.
    if creds.exists and not creds.readable:
        return truth(
            STATE_UNREADABLE,
            "The run-state credentials file exists but cannot be read "
            "(root-owned after a sudo `make e2e`).",
            f"{creds.path}: {creds.error}. "
            + _CHOWN_FIX.format(path=creds.path)
            + " Until then no password can be shown for the shared-password personas.",
            marker=UNVERIFIED, stage2=None, password_marker=UNREADABLE_MARKER)

    # (h, lane rule) THE KIND LANE IS ASKED (#539). It used to return unknown
    # unconditionally, on the premise that its ClusterIP Casdoor could not be
    # reached — which was false: its database is a pod, and a pod can be read. What
    # follows keeps the three unreadable-vs-empty cases apart, because their fixes
    # differ: re-run the seed, resume the halted lane, or fix the probe's access.
    if lane == LANE_KIND:
        k = kind if kind is not None else KindIdentities(
            reason="the kind lane was not read")
        # bootstrap-kind.sh runs seed-accounts.sh --roles and never seed-e2e.sh, so
        # registration stage 2 does not happen here and the operator account is not
        # created — that much really is by construction and is unchanged.
        kind_lane_note = (
            "bootstrap-kind.sh (step 10) seeds the seed-accounts.sh personas with "
            "the same run-state password and never runs seed-e2e.sh, so the "
            "operator account is not created on this lane and registration stage 2 "
            "never ran. ")
        if k.users is None:
            # NOT ESTABLISHED. Every row keeps its password and is marked unknown;
            # nothing here says an account is missing, because nothing was read.
            halt_note = ""
            if k.halted is True:
                halt_note = ("The lane is HALTED — its workloads, casdoor-pg "
                             "included, are scaled to 0. `make kind-resume` (or "
                             "Resume DevOps lane) puts them back; until then the "
                             "identity store cannot be read and this says nothing "
                             "about who is seeded. ")
            return truth(
                STATE_UNKNOWN,
                "Not established — this Studio could not read the kind cluster's "
                "identity store, so it cannot say who is seeded (this is NOT "
                "'nobody is seeded').",
                halt_note + (f"Why: {k.reason}. " if k.reason else "")
                + kind_lane_note
                + "Passwords shown are whatever the run-state holds, unverified. "
                + file_line + " " + seed_line,
                marker=UNKNOWN, stage2=None, op="")

        present = k.users
        witness = SEED_WITNESS_USER in present
        count = len(present)
        # STAGE 2 FROM THE STORE, not from the lane's reputation. bootstrap-kind.sh
        # runs seed-accounts.sh only, so the operator account is not created here —
        # but that is a statement about the SEEDER, and the store is the thing being
        # asked. An account somebody really did create must not be told it is "not
        # on this lane"; an absent one still gets that precise marker, which carries
        # its own explanation, rather than the blunter "not seeded".
        has_op = bool(operator_user) and operator_user in present
        op_name = operator_user if has_op else ""
        if not witness:
            # THE REPORTED STATE. The cluster answered; it holds service accounts
            # and no persona. That is a seed that never ran, and it has a fix.
            return truth(
                STATE_UP_UNSEEDED,
                "This kind mesh has NO identities seeded — Casdoor answered and "
                f"holds {count} account(s), none of them a seeded persona. The "
                "accounts below do not exist on this cluster and cannot sign in.",
                f"Casdoor's database holds no '{SEED_WITNESS_USER}'. "
                "bootstrap-kind.sh seeds identities at step 10, immediately after "
                "`wait_job hugmesh-pki casdoor-init`; a bring-up that failed that "
                "wait exits BEFORE seeding while ArgoCD carries on converging, "
                "which leaves exactly this — a healthy, serving mesh with an empty "
                "identity store. Fix: re-run the identity seed (`make kind-up` "
                "re-enters step 10 idempotently), not a password reset. "
                + kind_lane_note + file_line,
                marker=NOT_SEEDED, stage2=has_op, op=op_name, sa_seeded=False,
                present=present, role_members=k.roles)

        # Seeded. Is the password ON SCREEN the one this cluster was seeded with?
        # bootstrap-kind.sh records what it used in the test-seed-passwords Secret,
        # so this is a real corroboration and not an inference from mtimes.
        roles_note = ("" if k.roles is not None else
                      "The role table could not be read, so no row's roles are "
                      "vouched for. ")
        if k.password_matches is False:
            return truth(
                STATE_SEEDED_SUSPECT,
                "The personas exist on this kind mesh, but it was seeded with a "
                "DIFFERENT password than the one shown — sign-in will 401 until "
                "it is re-seeded.",
                f"Casdoor holds '{SEED_WITNESS_USER}', and the "
                f"{KIND_SEED_SECRET} Secret in {KIND_SEED_SECRET_NS} (written by "
                "the bring-up that seeded this cluster) records a different value "
                "from the one on disk here. Fix: re-run the identity seed, which "
                "reconciles every persona to the current value. "
                + roles_note + kind_lane_note + file_line,
                marker=STALE, stage2=has_op, op=op_name,
                present=present, role_members=k.roles)
        if k.password_matches is True:
            return truth(
                STATE_SEEDED,
                f"Seeded. Casdoor on this kind cluster holds {count} account(s) "
                f"including '{SEED_WITNESS_USER}', and the password shown matches "
                f"the one the bring-up recorded in {KIND_SEED_SECRET}.",
                roles_note + kind_lane_note + file_line,
                marker=LIVE, stage2=has_op, op=op_name,
                present=present, role_members=k.roles)
        return truth(
            STATE_UNKNOWN,
            f"Seeded — Casdoor on this kind cluster holds {count} account(s) "
            f"including '{SEED_WITNESS_USER}' — but the password shown could not "
            "be corroborated.",
            f"The {KIND_SEED_SECRET} Secret in {KIND_SEED_SECRET_NS}, where the "
            "bring-up records the password it seeded with, could not be read"
            + (f" ({k.reason})" if k.reason else "")
            + ". The personas are real; the value beside them is unverified. "
            + roles_note + kind_lane_note + file_line,
            marker=UNVERIFIED, stage2=has_op, op=op_name,
            present=present, role_members=k.roles)

    # (h) docker did not answer at all.
    if mesh_running is None:
        return truth(
            STATE_UNKNOWN,
            "Not established — docker did not answer, so nothing here can say "
            "what is seeded.",
            (f"Status probe: {status_detail}. " if status_detail else "")
            + "Passwords shown are whatever the run-state holds, unverified. "
            + file_line + " " + seed_line,
            marker=UNVERIFIED, stage2=None)

    if not mesh_running:
        store = volumes_present
        if minted_unseeded:
            # (c) A mint with no completed seed since it.
            if store:
                return truth(
                    STATE_MINTED_NOT_SEEDED,
                    f"A bring-up minted a new superadmin ({fmt_time(secrets_mtime)}) "
                    "and no seed has completed since — the minted superadmin is not "
                    "in the stopped mesh's identity store.",
                    "The kept identity volume still holds the PREVIOUS seed, so the "
                    "shared-password personas may work after a start, but nothing "
                    "here can prove it. `Generate && start` re-mints; a plain start "
                    "+ `make stack-seed` reconciles every persona to the file's "
                    "value. " + file_line + " " + seed_line,
                    marker=UNVERIFIED, stage2=None, sa_seeded=False)
            return truth(
                STATE_MINTED_NOT_SEEDED,
                f"A bring-up minted a superadmin ({fmt_time(secrets_mtime)}) and "
                "then failed before seeding — nothing holds these accounts yet.",
                "No identity store exists (no casdoor-pg volume), so no persona "
                "below can sign in anywhere right now. The next successful "
                "bring-up seeds them. " + file_line + " " + seed_line,
                marker=NOT_SEEDED, stage2=False, sa_seeded=False)
        if store:
            # (b) `Stop mesh` is `make stack-halt`: volumes kept, identities intact.
            # Whether they hold the password on disk is exactly as provable as for
            # a running mesh: a recorded seed that populated THIS store after the
            # file was last written vouches for it; nothing else does.
            kept = ("The identity volume (casdoor-pg"
                    + (f", created {fmt_time(casdoor_created)}" if casdoor_created else "")
                    + ") survived the stop. ")
            if record_covers:
                return truth(
                    STATE_HALTED,
                    "Stopped, not destroyed — `Stop mesh` kept the volumes, so these "
                    "credentials are still valid for the next start.",
                    kept + "Start the mesh and sign in with the password shown; "
                    "nothing needs re-seeding. " + file_line + " " + seed_line,
                    marker=HALTED, stage2=True)
            if last_seed_ok is not None and store_after_record is False:
                # The recorded seed populated this store; the file was rewritten
                # since — the kept identities hold a value the file no longer does.
                return truth(
                    STATE_HALTED,
                    "Stopped, not destroyed — but the credentials file was rewritten "
                    "after the last completed seed, so the kept identities hold a "
                    "DIFFERENT password; sign-in will 401 after the next start "
                    "until it is re-seeded.",
                    kept + f"The credentials file was rewritten {creds.written}, "
                    f"after the last completed seed ({seeded_at}) — seed-e2e.sh leg "
                    "1c's stale shape. Fix: start the mesh, then re-run `make "
                    "stack-seed` (or Add user); the apply hook reconciles every "
                    "stored password to the file's value.",
                    marker=STALE, stage2=True)
            return truth(
                STATE_HALTED,
                "Stopped, not destroyed — the identity volume survived, but no seed "
                "this Studio recorded populated it, so whether it holds the "
                "password on disk is unverified.",
                kept + (f"It was created after the last recorded seed ({seeded_at}), "
                        "so a run this Studio did not record populated it. "
                        if store_after_record else
                        (f"The last recorded seed ({seeded_at}) cannot be tied to "
                         "THIS store: `docker volume inspect` did not answer with a "
                         "time this Studio can read, so the store may have been "
                         "recreated since. "
                         if store_after_record is None and last_seed_ok is not None
                         else "No completed seed is recorded by this Studio. "))
                + "Start the mesh and press this button again (a running Casdoor "
                "can be asked), or re-run `make stack-seed` to reconcile every "
                "persona to the file's value. " + file_line + " " + seed_line,
                marker=UNVERIFIED, stage2=None)
        if store is None:
            return truth(
                STATE_UNKNOWN,
                "Not running, and whether an identity volume survives could not "
                "be established.",
                "docker did not answer the volume query. " + file_line + " " + seed_line,
                marker=UNVERIFIED, stage2=None)
        # (a) Nothing up, nothing kept: the roster is a forecast.
        return truth(
            STATE_NO_MESH,
            "No mesh is running — nothing is seeded. These are the accounts a "
            "bring-up WOULD create.",
            "No compose containers and no identity volume. `Generate && start` "
            "mints a superadmin, brings the stack up and seeds every account below "
            "with the run-state password (reusing the file's value when the file "
            "exists). " + file_line + " " + seed_line,
            marker=NOT_SEEDED, stage2=False, sa_seeded=False)

    # ── running ──
    if seeded_admin is None:
        return truth(
            STATE_UNKNOWN,
            "The stack is up, but Casdoor did not answer on localhost:8000 — "
            "seededness is not established.",
            "Passwords shown are whatever the run-state holds, unverified. "
            + file_line + " " + seed_line,
            marker=UNVERIFIED, stage2=None)
    if not seeded_admin:
        # (d)
        return truth(
            STATE_UP_UNSEEDED,
            "The stack is up but unseeded — run `make stack-seed`, or press "
            "Add user.",
            f"Casdoor answered but holds no '{SEED_WITNESS_USER}'. "
            + ("A superadmin was minted "
               f"({fmt_time(secrets_mtime)}) and is waiting for that seed. "
               if minted_unseeded else "")
            + file_line + " " + seed_line,
            marker=NOT_SEEDED, stage2=False, sa_seeded=False)

    # seeded: which password do the identities hold?
    stage2 = seeded_operator if operator_user else False
    if not env_password and not creds.exists:
        return truth(
            STATE_UNKNOWN,
            "Seeded, but the run-state credentials file is gone — the password "
            "that seeded it cannot be shown.",
            "Re-run `make stack-seed`: it generates a fresh password, records it, "
            "and reconciles every persona to it. " + file_line + " " + seed_line,
            marker=UNVERIFIED, stage2=stage2)
    if last_seed_ok is None:
        return truth(
            STATE_UNKNOWN,
            "Seeded by a run this Studio did not record — the password on disk is "
            "unverified.",
            "Casdoor holds the seeded personas, but nothing here records a seed "
            "completing after the credentials file was written, so the file's "
            "value cannot be vouched for. A Studio bring-up or Add user records "
            "one. " + file_line + " " + seed_line,
            marker=UNVERIFIED, stage2=stage2)
    if store_after_record is None:
        # The store's age is not established (`docker volume inspect` failed, or
        # printed a layout parse_docker_time does not recognise), so the recorded
        # seed cannot be tied to the store that exists NOW. A store recreated since
        # would hold DIFFERENT passwords, and this is the one fact that would say
        # so — absent it, "live" is a guess, not a claim.
        return truth(
            STATE_UNKNOWN,
            "Seeded, but the age of the identity store could not be established — "
            "the password on disk is unverified.",
            "`docker volume inspect` did not answer with a time this Studio can "
            f"read, so whether the last recorded seed ({seeded_at}) populated the "
            "store that exists NOW is unknown; a store recreated since (a "
            "`stack-clean`, a `down -v`) would hold a different password. Press "
            "this button again, or re-run `make stack-seed` to reconcile every "
            "persona to the file's value. " + file_line + " " + seed_line,
            marker=UNVERIFIED, stage2=stage2)
    if store_after_record:
        # The store the recorded seed populated is gone; whatever populated this
        # one (a terminal seed, or a bring-up still running) left no record, so
        # neither "live" nor "stale" can be claimed — not even with a newer file,
        # since the unrecorded seed may have run after that rewrite.
        return truth(
            STATE_UNKNOWN,
            "Seeded into an identity store created after the last seed this "
            "Studio recorded — the password on disk is unverified.",
            f"casdoor-pg was created {fmt_time(casdoor_created)}, after the last "
            f"recorded seed ({seeded_at}). Either a bring-up is still running (its "
            "record is written when it finishes — press again once it has) or a "
            "terminal seed populated the store. " + file_line,
            marker=UNVERIFIED, stage2=stage2)
    if file_after_record:
        # (e) The exact shape seed-e2e.sh leg 1c names: the identities were
        # reconciled to a value the file no longer holds.
        return truth(
            STATE_SEEDED_SUSPECT,
            "The identities in this mesh were seeded under a DIFFERENT password "
            "than the one on disk — sign-in will 401 for every account until it "
            "is re-seeded.",
            f"The credentials file was rewritten {creds.written}, after the last "
            f"completed seed ({seeded_at}) — a persisted casdoor volume plus a "
            "lost/regenerated .e2e-credentials does this (seed-e2e.sh leg 1c). "
            "Fix: re-run `make stack-seed` (or Add user, which re-runs it); the "
            "apply hook reconciles every stored password to the file's value.",
            marker=STALE, stage2=stage2)
    # (f)
    src = ("the seeder's environment (E2E_PASSWORD)" if env_password
           else f"`{os.path.basename(creds.path) or CREDENTIALS_FILE_NAME}` "
                f"(written {creds.written})")
    return truth(
        STATE_SEEDED,
        f"Seeded. Password read from {src}; last seed completed {seeded_at}.",
        f"Casdoor holds '{SEED_WITNESS_USER}'"
        + (f" and the operator account '{operator_user}'" if stage2 else
           (f"; the operator account '{operator_user}' is NOT on this lane "
            "(registration stage 2 did not run — a terminal `make stack-seed` "
            "omits it; the Studio's bring-up and Add user include it)"
            if operator_user and stage2 is False else ""))
        + ". "
        + ("The minted superadmin was seeded by that run. " if superadmin_seeded
           else ("A superadmin was minted after that seed and is not proven "
                 "seeded. " if superadmin_seeded is False and sa_ok else ""))
        + file_line,
        marker=LIVE, stage2=stage2)


# ── the blocking gatherer ─────────────────────────────────────────────────────────

def _default_logs_dir() -> str:
    try:
        from .state_paths import state_dir
        return os.path.join(state_dir(), "logs")
    except Exception:              # under pytest with no override: no record, not a crash
        return ""


def _probe_safe(node, cmd: list[str], timeout: int) -> tuple[int, str]:
    """``node._probe`` with every failure folded into a failed read — a stand-in
    node without ``_probe`` reports rc 1 rather than raising through the probe."""
    try:
        rc, out = node._probe(cmd, timeout)
        return int(rc), str(out or "")
    except Exception as e:                           # noqa: BLE001 — folded on purpose
        return 1, f"{type(e).__name__}: {e}"


def gather_kind_identities(node, generator_dir: str, cluster: str,
                           shared_password: str = "") -> KindIdentities:
    """Ask the RUNNING kind cluster who its Casdoor holds. BLOCKING, never raises.

    Every step can only ever downgrade a fact to "not established" (None) with a
    ``reason`` — nothing here may conclude that an account is absent from a read it
    did not take. The order is deliberate:

      1. ``kubectl`` on PATH at all (the lane's own resolver, so the Studio and the
         DevOps buttons mean the same binary);
      2. ``casdoor-pg``'s ``.status.readyReplicas`` — because `kubectl exec
         deploy/<x>` on a Deployment scaled to 0 does NOT fail, it blocks until its
         own timeout waiting for a pod. Measured on the halted reference cluster:
         40s with no diagnostic. A halted lane is the common case here, not an
         exotic one, so it is answered without an exec;
      3. the users query — the issue's own statement, verbatim;
      4. the roles query — INDEPENDENT: it may fail while (3) succeeded, and then
         no row gets a roles verdict;
      5. the ``test-seed-passwords`` Secret, to corroborate the password already on
         screen. Its value is compared here and dropped; only the boolean leaves.

    ``node`` is duck-typed on ``_probe(cmd, timeout)`` exactly as the compose path
    is, so a test hands in a fake cluster at this one override point."""
    def run(cmd: list[str], timeout: int) -> tuple[int, str]:
        return _probe_safe(node, cmd, timeout)

    try:
        from . import devops_tools
        kubectl = devops_tools.which("kubectl", generator_dir)
    except Exception as e:                           # noqa: BLE001
        return KindIdentities(reason=f"kubectl could not be resolved "
                                     f"({type(e).__name__}: {e})")
    if not kubectl:
        return KindIdentities(
            reason="kubectl is not installed — press 'Install DevOps prerequisites' "
                   "on this page")
    ctx = f"kind-{cluster}"
    base = [kubectl, "--context", ctx, "-n", KIND_CASDOOR_NS]

    rc, out = run(base + ["get", "deploy", KIND_CASDOOR_DB_DEPLOY, "-o",
                          "jsonpath={.status.readyReplicas}"], KIND_READY_TIMEOUT_S)
    if rc != 0:
        why = (out or "").strip()[:200] or "no output"
        if "notfound" in why.lower() or "not found" in why.lower():
            return KindIdentities(
                reason=f"this cluster has no {KIND_CASDOOR_DB_DEPLOY} Deployment in "
                       f"{KIND_CASDOOR_NS} — it is not a HugMesh identity cluster, "
                       f"or its manifests never synced")
        return KindIdentities(reason=f"the cluster's API did not answer "
                                     f"({why})")
    ready = 0
    try:
        ready = int((out or "0").strip() or "0")
    except ValueError:
        ready = 0
    if ready < 1:
        halted = _kind_halted(node, kubectl, ctx)
        return KindIdentities(
            halted=halted,
            reason=f"{KIND_CASDOOR_DB_DEPLOY} has no ready replica, so its database "
                   f"cannot be queried"
                   + ("" if halted is not True else " (the lane is halted)"))

    psql = ["psql", "-U", KIND_CASDOOR_DB_USER, "-d", KIND_CASDOOR_DB_NAME, "-Atc"]
    exec_pfx = base + ["exec", f"deploy/{KIND_CASDOOR_DB_DEPLOY}", "--"]
    rc, out = run(exec_pfx + psql + [KIND_USERS_SQL], KIND_EXEC_TIMEOUT_S)
    if rc != 0:
        return KindIdentities(
            reason=f"the identity query failed ({(out or '').strip()[:200] or 'no output'})")
    users = parse_psql_users(out)
    if users is None:
        return KindIdentities(
            reason="the identity query answered with something that is not a row "
                   "set, so who exists was not established")

    rc, out = run(exec_pfx + psql + [KIND_ROLES_SQL], KIND_EXEC_TIMEOUT_S)
    roles = parse_psql_roles(out) if rc == 0 else None

    matches: bool | None = None
    reason = ""
    if shared_password:
        rc, out = run([kubectl, "--context", ctx, "-n", KIND_SEED_SECRET_NS, "get",
                       "secret", KIND_SEED_SECRET, "-o",
                       "jsonpath={.data." + KIND_SEED_SECRET_KEY + "}"],
                      KIND_SECRET_TIMEOUT_S)
        raw = (out or "").strip()
        if rc != 0 or not raw:
            why = raw[:160] or "no output"
            reason = (f"the {KIND_SEED_SECRET} Secret is absent from "
                      f"{KIND_SEED_SECRET_NS}" if "notfound" in why.lower()
                      or "not found" in why.lower() or not raw
                      else f"reading {KIND_SEED_SECRET} failed: {why}")
        else:
            try:
                import base64
                # Compared and dropped: the decoded value is never returned, stored
                # or rendered — only this boolean leaves the function.
                matches = base64.b64decode(raw).decode("utf-8").strip() == shared_password
            except Exception as e:                   # noqa: BLE001
                reason = (f"the {KIND_SEED_SECRET} Secret could not be decoded "
                          f"({type(e).__name__})")
    else:
        reason = "no shared password is available locally to compare against"
    return KindIdentities(users=users, roles=roles, reason=reason,
                          password_matches=matches)


def _kind_halted(node, kubectl: str, ctx: str) -> bool | None:
    """Is `make kind-halt`'s record on this cluster? True / False / **None**.

    Asked by EXISTENCE (`-o name`), not by reading the record's field: a
    ``jsonpath={.data.halt.json}`` needs the dot in the key escaped, and getting
    that wrong yields an empty string with rc 0 — which reads as "not halted" on a
    halted lane. Existence is the whole question here anyway; the record's contents
    belong to `make kind-halt-status`, which is the authority.

    Deliberately mirrors ``mesh_monitor._halt_record_present`` rather than importing
    it: that module pulls in this lane's view catalogue and door logic, and this one
    stays small and import-light. Only NotFound means "no halt record"; every other
    failure is None, because unknown is not "not halted"."""
    rc, out = _probe_safe(node, [kubectl, "--context", ctx, "-n", KIND_HALT_NS,
                                 "get", "configmap", KIND_HALT_CM, "-o", "name"],
                          KIND_READY_TIMEOUT_S)
    if rc == 0:
        return bool((out or "").strip())
    low = (out or "").lower()
    if "notfound" in low or "not found" in low:
        return False
    return None


def probe_credentials(generator_dir: str, env: Mapping[str, str] | None, node, boot,
                      *, operator_user: str = "", logs_dir: str | None = None,
                      project: str = COMPOSE_PROJECT) -> CredentialTruth:
    """Gather the facts about the running mesh and :func:`assess` them.

    BLOCKING BY CONTRACT: `docker compose ps` (30s ceiling), three `docker` probes
    (15s each), up to two Casdoor GETs (5s each) and a few stats. Run it on a worker
    thread — the GUI wraps it in ``_CredsProbe``. Never raises: every gather that
    fails downgrades ONE fact to None, and :func:`assess` renders None as
    "not established", never as "no".

    ``node`` is a LocalStackNode (``status()``, ``_probe()``, ``seeded_user()``);
    ``boot`` a LocalMeshBootstrap (``secrets_json``, ``superadmin_login()``). Both
    are duck-typed so a test can hand in a fake at exactly this override point."""
    checked_at = time.strftime("%Y-%m-%d %H:%M:%S")
    creds = credentials_file(generator_dir, env)
    env_password = bool((env if env is not None else os.environ).get(SHARED_PASSWORD_ENV))

    def probe(cmd: list[str], timeout: int = 15) -> tuple[int, str]:
        try:
            rc, out = node._probe(cmd, timeout)
            return int(rc), str(out or "")
        except Exception as e:
            return 1, f"{type(e).__name__}: {e}"

    # 1. the compose project
    mesh_running: bool | None
    status_detail = ""
    try:
        st = node.status()
        mesh_running, status_detail = bool(st.running), str(st.detail or "")
    except Exception as e:
        mesh_running, status_detail = None, f"{type(e).__name__}: {e}"

    # 2. the kind lane (only consulted when compose is not the running lane).
    #    #539: when it IS the lane, its identity store is READ — see
    #    gather_kind_identities. That read is the whole point; "unknown by
    #    construction" was the bug.
    kind_up: bool | None = None
    kind: KindIdentities | None = None
    if not mesh_running:
        try:
            from .local_stack_node import _kind_cluster_name
            cluster = _kind_cluster_name()
        except Exception:
            cluster = "hugmesh-local"
        rc, out = probe(["docker", "ps", "--filter", f"name=^{cluster}-control-plane$",
                         "--format", "{{.Names}}"])
        kind_up = bool(out.strip()) if rc == 0 else None
        if kind_up:
            # The password already on screen, resolved the same way the roster
            # resolves it (env wins over the run-state file) — handed in so the
            # gatherer can compare it against what the bring-up recorded, and
            # never re-derived there.
            src = env if env is not None else os.environ
            shared = (src.get(SHARED_PASSWORD_ENV)
                      or read_values(generator_dir, env).get(SHARED_PASSWORD_ENV, ""))
            kind = gather_kind_identities(node, generator_dir, cluster,
                                          shared_password=shared)

    # 3. the identity volume, by compose LABEL (never by name prefix, never from the
    #    compose file — volumes whose definitions were renamed survive `down -v`)
    volume = f"{project}_{IDENTITY_VOLUME_SUFFIX}"
    rc, out = probe(["docker", "volume", "ls", "--filter",
                     f"label={_COMPOSE_LABEL}={project}", "--format", "{{.Name}}"])
    volumes_present: bool | None
    if rc == 0:
        volumes_present = volume in {ln.strip() for ln in out.splitlines()}
    else:
        volumes_present = None
    casdoor_created: float | None = None
    if volumes_present:
        rc, out = probe(["docker", "volume", "inspect", volume, "--format",
                         "{{.CreatedAt}}"])
        casdoor_created = parse_docker_time(out) if rc == 0 else None

    # 4. who Casdoor holds (compose lane, running only — it has the host port)
    seeded_admin: bool | None = None
    seeded_operator: bool | None = None
    if mesh_running:
        ask = getattr(node, "seeded_user", None)
        if callable(ask):
            try:
                seeded_admin = ask(SEED_WITNESS_USER)[0]
            except Exception:
                seeded_admin = None
            if operator_user and seeded_admin:
                try:
                    seeded_operator = ask(operator_user)[0]
                except Exception:
                    seeded_operator = None

    # 5. the minted bundle — its mtime and the superadmin it advertises
    secrets_mtime: float | None = None
    try:
        secrets_mtime = float(os.stat(boot.secrets_json).st_mtime)
    except (OSError, AttributeError, TypeError, ValueError):
        secrets_mtime = None
    superadmin: tuple[str, str] = ("", "")
    try:
        sa = boot.superadmin_login()
        if sa and sa[0] and sa[1]:
            superadmin = (str(sa[0]), str(sa[1]))
    except Exception:
        superadmin = ("", "")

    # 6. the last COMPLETED seed: this Studio's own run log, or the seed stamp a
    #    terminal `make stack-seed` leaves beside the credentials file (trusted only
    #    while its fingerprint still matches the file on disk — see seed_stamp)
    seed_ok = last_seed_ok(logs_dir if logs_dir is not None else _default_logs_dir())
    stamped = seed_stamp(creds.path) if creds.readable else None
    if stamped is not None and (seed_ok is None or stamped > seed_ok):
        seed_ok = stamped

    lane = LANE_COMPOSE if mesh_running else (LANE_KIND if kind_up else LANE_COMPOSE)
    return assess(mesh_running=mesh_running, volumes_present=volumes_present,
                  seeded_admin=seeded_admin, seeded_operator=seeded_operator,
                  creds=creds, casdoor_created=casdoor_created,
                  secrets_mtime=secrets_mtime, last_seed_ok=seed_ok, lane=lane,
                  operator_user=operator_user, superadmin=superadmin,
                  env_password=env_password, status_detail=status_detail,
                  checked_at=checked_at, kind=kind)

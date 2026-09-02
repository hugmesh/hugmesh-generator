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

HOW A SEED IS CORROBORATED. tests/stack/e2e-password.sh's ``e2e_password_ensure``
REUSES the file's value whenever the file exists and only generates when it is
absent, and the seeder's apply hook reconciles every stored password to the value
it resolved (seed-accounts.sh "rotated N password(s) reconciled"). So the
identities in a Casdoor volume hold the file's value exactly when a seed
COMPLETED after the file was last written — and that completion is what the
Studio's own run log records (``<state>/logs/<stamp>-Bootstrapping-ok.log`` and
``…-Adding-user-<name>-ok.log``; both verbs run `make stack-seed`). Mtime order
between the file and the volume proves NOTHING on its own: a second-generation
mesh (volume recreated, file reused) is valid with an OLDER file, and a file
regenerated after a seed is stale with a NEWER one. The stale shape seed-e2e.sh
leg 1c names ("a persisted casdoor volume + a lost/regenerated .e2e-credentials")
is therefore "file rewritten AFTER the last completed seed".

TRI-STATE, NEVER A FALSE NEGATIVE. "I could not establish it" is rendered as
unknown, never as "no". A mesh whose docker daemon is unreachable is not an
unseeded mesh, and saying the stored password is wrong is as much a lie as saying
it is right. Unknown keeps the passwords on screen and MARKS them unverified. The
kind lane is unknown BY CONSTRUCTION: bootstrap-kind.sh seeds seed-accounts.sh
personas only (never seed-e2e.sh, so never mesh-operator) and its Casdoor is
ClusterIP with no host port, so nothing here can ask it anything.

SECRET DISCIPLINE. :class:`CredentialsFile` carries key NAMES only, never a value.
:attr:`CredentialTruth.headline` and :attr:`~CredentialTruth.detail` are asserted
password-free by test — they are the strings that reach tooltips, banners and the
page's state line, any of which can end up in a screenshot or a run log. Only
:class:`~hugmesh_studio.core.seeded_credentials.SeededUser` rows carry values, and
only the dialog renders those. Nothing here writes anything anywhere.
"""
from __future__ import annotations

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
#: The value shown may well be right; nothing here could corroborate it.
UNVERIFIED = "unverified"
#: Nothing can be asked (the kind lane).
UNKNOWN = "unknown"
#: Created by this session's Add user; its password was never stored.
ADDED = "added this session"

MARKERS = (LIVE, STALE, HALTED, NOT_SEEDED, NOT_ON_LANE, UNVERIFIED, UNKNOWN, ADDED)

# The env knob and default name of the run-state credentials file
# (tests/stack/e2e-password.sh CONTRACT rule 3). seeded_credentials re-exports
# these — it delegates its reading here so there is exactly one parser.
CREDENTIALS_FILE_ENV = "E2E_CREDENTIALS_FILE"
CREDENTIALS_FILE_NAME = ".e2e-credentials"
SHARED_PASSWORD_ENV = "E2E_PASSWORD"

#: The identity store. `docker volume inspect <project>_casdoor-pg` says whether the
#: CURRENT Casdoor database exists and when it was created.
IDENTITY_VOLUME_SUFFIX = "casdoor-pg"
#: The persona seed-e2e.sh leg 1 always creates — its presence is "seeded".
SEED_WITNESS_USER = "e2e-admin"

#: The Studio's run-log names for the two verbs that run `make stack-seed`
#: (localmesh.py `_launch("Bootstrapping", …)` / `_launch(f"Adding user {u}", …)`,
#: slugified by `_save_run_log`). A `-ok.log` of either is the only in-Studio
#: record that a seed COMPLETED.
_SEED_LOG_RE = re.compile(r"^(?P<stamp>\d{8}-\d{6})-(?:Bootstrapping|Adding-user-.*)-ok\.log$")

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

    @property
    def verified(self) -> bool:
        """True only when a shown password has been positively corroborated."""
        return self.state == STATE_SEEDED


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


# ── the state machine ─────────────────────────────────────────────────────────────

def assess(*, mesh_running: bool | None, volumes_present: bool | None,
           seeded_admin: bool | None, seeded_operator: bool | None,
           creds: CredentialsFile, casdoor_created: float | None,
           secrets_mtime: float | None, last_seed_ok: float | None,
           lane: str = LANE_COMPOSE, operator_user: str = "",
           superadmin: tuple[str, str] = ("", ""), env_password: bool = False,
           status_detail: str = "", checked_at: str = "") -> CredentialTruth:
    """Fold plain facts into ONE :class:`CredentialTruth`. PURE — no I/O.

    Facts (None = not established, and None never becomes a claim):
      mesh_running     the compose project has containers (LocalStackNode.status)
      volumes_present  the identity volume ``<project>_casdoor-pg`` exists
      seeded_admin     Casdoor answered and holds/does not hold ``e2e-admin``
      seeded_operator  same for the lane's operator account
      creds            the run-state credentials file (names + mtime, no values)
      casdoor_created  the identity volume's CreatedAt (epoch)
      secrets_mtime    keys-out/vault/secrets.json's mtime (the last MINT)
      last_seed_ok     when a seeding verb last COMPLETED (this Studio's record)
      lane             "compose" | "kind" | ""
      env_password     E2E_PASSWORD is set in the seeder's env (file not needed)
    """
    checked_at = checked_at or time.strftime("%Y-%m-%d %H:%M:%S")
    seeded_at = fmt_time(last_seed_ok)
    sa_user, sa_pw = (superadmin or ("", ""))
    sa_ok = bool(sa_user and sa_pw)
    # The MINTED superadmin is proven seeded only when a seed completed after the mint.
    minted_after_seed = _newer(secrets_mtime, last_seed_ok)
    if secrets_mtime is None:
        superadmin_seeded: bool | None = False if not sa_ok else None
    elif last_seed_ok is None:
        superadmin_seeded = None
    else:
        superadmin_seeded = not minted_after_seed
    minted_unseeded = secrets_mtime is not None and (
        last_seed_ok is None or bool(minted_after_seed))

    def truth(state: str, headline: str, detail: str, *, marker: str,
              stage2: bool | None, lane_: str = lane, op: str = operator_user,
              sa_seeded: bool | None = superadmin_seeded,
              password_marker: str = "") -> CredentialTruth:
        return CredentialTruth(
            state=state, lane=lane_, headline=headline, detail=detail, file=creds,
            seeded_at=seeded_at, stage2=stage2, operator_user=op,
            superadmin=(sa_user, sa_pw) if sa_ok else ("", ""),
            checked_at=checked_at, superadmin_seeded=sa_seeded, marker=marker,
            password_marker=password_marker)

    file_line = (f"Credentials file: {creds.path} (written {creds.written})."
                 if creds.exists else
                 (f"Credentials file: none at {creds.path}." if creds.path
                  else "Credentials file: no path."))
    seed_line = (f"Last completed seed recorded by this Studio: {seeded_at}."
                 if seeded_at else
                 "No completed seed is recorded by this Studio (a terminal "
                 "`make stack-seed` leaves no record here).")

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

    # (h, lane rule) The kind lane is unknown BY CONSTRUCTION: bootstrap-kind.sh
    # seeds seed-accounts.sh personas only (never seed-e2e.sh, never
    # mesh-operator), and its Casdoor is ClusterIP with no host port.
    if lane == LANE_KIND:
        return truth(
            STATE_UNKNOWN,
            "Not established — the kind lane is up and its Casdoor has no host "
            "port, so nothing here can verify who is seeded.",
            "bootstrap-kind.sh seeds the seed-accounts.sh personas with the same "
            "run-state password, but never runs seed-e2e.sh, so the operator "
            "account does not exist on this lane and registration stage 2 never "
            "ran. Passwords shown are unverified. " + file_line + " " + seed_line,
            marker=UNKNOWN, stage2=None, op="")

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
            return truth(
                STATE_HALTED,
                "Stopped, not destroyed — `Stop mesh` kept the volumes, so these "
                "credentials are still valid for the next start.",
                "The identity volume (casdoor-pg"
                + (f", created {fmt_time(casdoor_created)}" if casdoor_created else "")
                + ") survived the stop. Start the mesh and sign in with the "
                "password shown; nothing needs re-seeding. " + file_line + " "
                + seed_line,
                marker=HALTED, stage2=None if last_seed_ok is None else True)
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
    if not env_password and creds.mtime is not None and creds.mtime > last_seed_ok:
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
    if casdoor_created is not None and casdoor_created > last_seed_ok:
        return truth(
            STATE_UNKNOWN,
            "Seeded into an identity store created after the last seed this "
            "Studio recorded — the password on disk is unverified.",
            f"casdoor-pg was created {fmt_time(casdoor_created)}, after the last "
            f"recorded seed ({seeded_at}). Either a bring-up is still running (its "
            "record is written when it finishes — press again once it has) or a "
            "terminal seed populated the store. " + file_line,
            marker=UNVERIFIED, stage2=stage2)
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
    are duck-typed so a test can hand in a fake at exactly this seam."""
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

    # 2. the kind lane (only consulted when compose is not the running lane)
    kind_up: bool | None = None
    if not mesh_running:
        try:
            from .local_stack_node import _kind_cluster_name
            cluster = _kind_cluster_name()
        except Exception:
            cluster = "hugmesh-local"
        rc, out = probe(["docker", "ps", "--filter", f"name=^{cluster}-control-plane$",
                         "--format", "{{.Names}}"])
        kind_up = bool(out.strip()) if rc == 0 else None

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

    # 6. the last COMPLETED seed this Studio recorded
    seed_ok = last_seed_ok(logs_dir if logs_dir is not None else _default_logs_dir())

    lane = LANE_COMPOSE if mesh_running else (LANE_KIND if kind_up else LANE_COMPOSE)
    return assess(mesh_running=mesh_running, volumes_present=volumes_present,
                  seeded_admin=seeded_admin, seeded_operator=seeded_operator,
                  creds=creds, casdoor_created=casdoor_created,
                  secrets_mtime=secrets_mtime, last_seed_ok=seed_ok, lane=lane,
                  operator_user=operator_user, superadmin=superadmin,
                  env_password=env_password, status_detail=status_detail,
                  checked_at=checked_at)

"""Build-session records — durable per-dispatch build history (model + IO, no Qt).

Every GUI-dispatched build run becomes a persisted :class:`BuildSession`: id +
timestamps + a human label, the FULL config snapshot (the same worklist envelope
``Save config…`` writes, secrets blanked), the per-session artifact workdir
(``<out>/sessions/<id>/`` — see :func:`session_workdir`), the dispatch params, final
status and per-image outcomes, and a pointer to the per-session ``build.log``.

Records live one-file-per-session under :func:`sessions_dir` — the exact same
directory family AND ``$HUGMESH_STUDIO_STATE_DIR`` override as the tray's
``build_status_path()`` (gui/tray.py), so the tests' ``_isolated_state_dir`` fixture
isolates both for free.

Write discipline (all best-effort, atomic tmp+``os.replace`` — a build must NEVER
die because a record could not be written, mirroring ``tray.write_build_status``):

* :func:`start` — at REAL dispatch, status ``running`` + pid/hostname;
* :func:`update_image` — one atomic rewrite per image completion (never per line),
  so a later crash still preserves partial truth;
* :func:`finish` — terminal status + the failed rows' error tails.

Crash honesty: a SIGKILL'd/crashed Studio simply leaves the last-written record —
status ``running`` with whatever per-image outcomes were true. :func:`load_all`
never rewrites records; :func:`is_stale` lets a UI RENDER "running (process gone)"
without ever mutating the record into a fake terminal state. Corrupt JSON files are
skipped (surfaced via :func:`scan` as unreadable paths), never a crash.

Qt-free by construction (the :mod:`.worklist_driver` precedent) — imported by the
GUI pages and driven directly by the pure-core tests.
"""
from __future__ import annotations

import json
import os
import shutil
import socket
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime
from typing import Any

from . import secret_files
from .config import PLATFORM_FIELD_SUPPORT, SECRET_FIELDS
from .worklist import WorklistConfig

# Session terminal/lifecycle states. Per-image states reuse the worklist_driver
# vocabulary (queued/running/ok/failed/stopped) verbatim.
RUNNING, COMPLETE, FAILED, STOPPED = "running", "complete", "failed", "stopped"

# How many trailing log lines finish() keeps per FAILED image (the error pointer a
# "View errors" affordance renders without re-reading a multi-GB build.log).
ERROR_TAIL_LINES = 40

LOG_NAME = "build.log"   # the builders' LOG_FILE basename (keys off -w)


def image_log_name(entry_id: str) -> str:
    """The per-image log basename a builder writes NEXT TO the shared build.log —
    derived from the builders' ``IMAGE_LOG_FILE="${WORK_DIR}/build-${BUILD_SUBDIR#wl-}.log"``
    (the worklist driver passes ``--build-subdir wl-<entry-id>``, so a Studio run's
    per-image log is ``build-<entry-id>.log``). The shared ``build.log`` (log_path)
    is unchanged: still written, still what every existing reader opens."""
    return f"build-{entry_id}.log"

# A fleet run's teed stream (the GUI writes it — build-all-roles.sh has no LOG_FILE
# of its own, so the tee is the honest per-session log, real content only).
FLEET_LOG_NAME = "fleet.log"


# ── paths ─────────────────────────────────────────────────────────────────────────────
def sessions_dir() -> str:
    """The session-record directory. Honours ``$HUGMESH_STUDIO_STATE_DIR`` (tests /
    hygiene) exactly like ``tray.build_status_path``; defaults to
    ``~/.hugmesh/studio/sessions``."""
    base = os.environ.get("HUGMESH_STUDIO_STATE_DIR") or os.path.join(
        os.path.expanduser("~"), ".hugmesh", "studio")
    return os.path.join(base, "sessions")


def session_workdir(out_dir: str, session_id: str) -> str:
    """The per-session ARTIFACT dir: ``<out>/sessions/<id>/``. Everything a GUI run
    lands in the shared ``<out>`` today (the per-entry ``wl-*`` trees, ``build.log``,
    the mesh manifest, ``keys-*``) lands here instead — applied as a runtime driver
    ``workdir`` override at dispatch, NEVER written into the config (goldens /
    ``--print-command`` keep the non-session default for the same config)."""
    return os.path.join(os.path.abspath(out_dir), "sessions", session_id)


def new_session_id() -> str:
    """A sortable id: ``%Y%m%d-%H%M%S-`` + 6 hex chars (uniqueness within the second)."""
    return datetime.now().strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:6]


def _now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


# ── labels ────────────────────────────────────────────────────────────────────────────
def derive_label(wl: WorklistConfig) -> str:
    """A human row label: 1 entry -> ``role · platform[ · board/flavor]``;
    N entries -> ``mesh · N images (platforms)``."""
    entries = wl.entries
    if len(entries) == 1:
        e = entries[0]
        parts = [e.role or "(role unset)", e.platform or "x86"]
        axis = e.board or e.flavor
        if axis:
            parts.append(axis)
        return " · ".join(parts)
    platforms: list[str] = []
    for e in entries:
        if e.platform and e.platform not in platforms:
            platforms.append(e.platform)
    return f"mesh · {len(entries)} images ({', '.join(platforms)})"


def fleet_platform_families(cfg) -> list[str]:
    """The platform families a FleetConfig actually builds, in the script's own
    order — a faithful mirror of scripts/build-all-roles.sh's sequential knob
    evaluation (each *_ONLY zeroes every EARLIER family but not a later opt-in;
    PENTEST_ONLY skips all image builds)."""
    if cfg.pentest_only:
        return ["pentest"]
    rpi = not cfg.skip_rpi
    x86 = not cfg.skip_x86
    if x86 and cfg.x86_standalone_only:        # elif chain: SKIP_X86 wins over it
        rpi = False
    frite = cfg.frite or cfg.frite_only
    if cfg.frite_only:
        rpi = x86 = False
    jetson = cfg.jetson or cfg.jetson_only
    if cfg.jetson_only:
        rpi = x86 = frite = False
    opi5 = cfg.orangepi5 or cfg.orangepi5_only
    if cfg.orangepi5_only:
        rpi = x86 = frite = jetson = False
    opz2 = cfg.orangepizero2 or cfg.orangepizero2_only
    if cfg.orangepizero2_only:
        rpi = x86 = frite = jetson = opi5 = False
    opz2w = cfg.orangepizero2w or cfg.orangepizero2w_only
    if cfg.orangepizero2w_only:
        rpi = x86 = frite = jetson = opi5 = opz2 = False
    opz3 = cfg.orangepizero3 or cfg.orangepizero3_only
    if cfg.orangepizero3_only:
        rpi = x86 = frite = jetson = opi5 = opz2 = opz2w = False
    fams = [name for name, on in (
        ("rpi5", rpi), ("x86", x86), ("frite", frite), ("jetson", jetson),
        ("orangepi5", opi5), ("orangepizero2", opz2),
        ("orangepizero2w", opz2w), ("orangepizero3", opz3)) if on]
    if cfg.pentest:
        fams.append("pentest")
    return fams


def derive_fleet_label(cfg) -> str:
    """A human row label for a fleet run: ``fleet: rpi5, x86, frite``."""
    fams = fleet_platform_families(cfg)
    return "fleet: " + (", ".join(fams) if fams else "(nothing selected)")


# ── the record ────────────────────────────────────────────────────────────────────────
@dataclass
class BuildSession:
    """One persisted build-creation session (see the module docstring)."""
    id: str = ""
    created: str = ""                 # first minted
    # "wizard" (single-image/mesh worklist run) | "fleet" (build-all-roles run).
    # from_dict filters unknown keys, so pre-existing records load as "wizard".
    kind: str = "wizard"
    started: str = ""                 # latest run's dispatch time
    finished: str = ""                # latest run's terminal time ("" while running)
    label: str = ""                   # derive_label() summary
    # the FULL worklist envelope (WorklistConfig.to_dict(), secrets blanked) — reload
    # is WorklistConfig.from_dict, byte-compatible with what Save config… writes.
    config: dict = field(default_factory=dict)
    # SECRET_FIELDS that were set at dispatch but NOT persisted (same blanking rule as
    # save) — RESTART/REDO warn the user to re-enter them instead of failing silently.
    blanked_secrets: list = field(default_factory=list)
    # Secret FILES whose CONTENT was held in memory at dispatch (core/secret_files.py:
    # the 2026-07-29 "held in memory until the build is completed" ask). Each row is
    # HeldSecretFile.record() — {field, name, sha256}: enough for a RESTART in a fresh
    # Studio process to PROMPT for exactly the missing items (and for the operator to
    # verify a re-selected file matches), never the material and never even its path.
    # from_dict filters unknown keys, so pre-existing records load with [].
    held_secret_files: list = field(default_factory=list)
    workdir: str = ""                 # absolute per-session artifact dir
    backend: str | None = None        # exact dispatch params BuildPage stashes
    generate_keys: bool = True
    status: str = RUNNING             # running | complete | failed | stopped
    # [{id, role, platform, status, exit_code, keys_ok}] — mirrors EntryResult.
    images: list = field(default_factory=list)
    log_path: str = ""                # <workdir>/build.log (the builders' LOG_FILE)
    error_tail: dict = field(default_factory=dict)   # {image_id: [last ~40 lines]}
    pid: int | None = None            # crash honesty: is_stale() probes this
    hostname: str = ""
    restarts: int = 0                 # RESTART count (== len(runs) - 1)
    runs: list = field(default_factory=list)         # dispatch timestamps, oldest first
    history: list = field(default_factory=list)      # prior runs' outcomes (RESTART)

    def path(self) -> str:
        return os.path.join(sessions_dir(), f"{self.id}.json")

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "BuildSession":
        if not isinstance(d, dict):
            raise ValueError("session record must be a JSON object")
        known = set(cls.__dataclass_fields__)  # type: ignore[attr-defined]
        return cls(**{k: v for k, v in d.items() if k in known})

    def worklist(self) -> WorklistConfig:
        """The config snapshot as a live WorklistConfig (RESTART/REDO's round-trip)."""
        return WorklistConfig.from_dict(self.config)


# ── construction at dispatch ──────────────────────────────────────────────────────────
def _held_secret_file_records(wl: WorklistConfig) -> list[dict]:
    """The content-free ``held_secret_files`` rows for a dispatch: every vault entry
    this run will actually CONSUME — the field is set on the base, the held copy is
    for exactly that path (build_driver's origin pin), and at least one entry's
    platform emits the flag (PLATFORM_FIELD_SUPPORT — a pure-ARM worklist consumes
    no x86-only signing material, so a restart of it must not demand any)."""
    v = secret_files.vault()
    platforms = {(e.platform or "x86") for e in wl.entries}
    out: list[dict] = []
    for f in secret_files.VAULT_FIELDS:
        path = getattr(wl.base, f, "")
        held = v.get(f)
        if not path or held is None or held.origin != path:
            continue
        support = PLATFORM_FIELD_SUPPORT.get(f)
        if support is not None and not (platforms & set(support)):
            continue
        out.append(held.record())
    return out


def new_session(wl: WorklistConfig, generator_dir: str, *,
                backend: str | None = None, generate_keys: bool = True,
                session_id: str | None = None) -> BuildSession:
    """Assemble the BuildSession for a dispatch (no write — :func:`start` writes).

    ``session_id`` naming an EXISTING record means RESTART: the record is reloaded and
    UPDATED in place — its prior outcome (status/images/error_tail) is archived into
    ``history`` rather than silently erased, and the same workdir is reused. A fresh /
    unknown id creates a new record with a fresh ``<out>/sessions/<id>/`` workdir."""
    out = wl.base.output_dir or os.path.join(os.path.abspath(generator_dir), "out")
    sid = session_id or new_session_id()

    s: BuildSession | None = None
    if session_id:
        try:
            s = load(os.path.join(sessions_dir(), f"{session_id}.json"))
        except (OSError, ValueError):
            s = None
    if s is not None and s.status != RUNNING:      # archive the prior run's truth
        s.history.append({"started": s.started, "finished": s.finished,
                          "status": s.status, "images": s.images,
                          "error_tail": s.error_tail})
    if s is None:
        s = BuildSession(id=sid, created=_now())
        s.workdir = session_workdir(out, sid)

    s.label = derive_label(wl)
    s.config = wl.to_dict()                        # secrets blanked (the save rule)
    s.blanked_secrets = [k for k in SECRET_FIELDS if getattr(wl.base, k, "")]
    s.held_secret_files = _held_secret_file_records(wl)
    s.backend = backend
    s.generate_keys = generate_keys
    s.images = [{"id": e.id, "role": e.role, "platform": e.platform,
                 "status": "queued", "exit_code": None, "keys_ok": None,
                 "log": image_log_name(e.id)}
                for e in wl.entries]
    s.error_tail = {}
    s.log_path = os.path.join(s.workdir, LOG_NAME)
    return s


def new_fleet_session(cfg, generator_dir: str, *, backend: str | None = None,
                      session_id: str | None = None) -> BuildSession:
    """Assemble the BuildSession for a FLEET dispatch (core.fleet.FleetConfig —
    duck-typed so this module stays import-light). Mirrors :func:`new_session`
    exactly, including the RESTART semantics: ``session_id`` naming an existing
    non-running record reloads it, archives its prior outcome into ``history`` and
    reuses the same workdir; a fresh/unknown id gets a fresh
    ``<out>/sessions/<id>/`` where out = cfg.output_dir or <generator>/out.

    One honest AGGREGATE image row: build-all-roles.sh streams many roles through
    one process and we cannot truthfully attribute per-role outcomes from its
    stream, so we record exactly one "all-roles" row instead of fabricating N.
    Nothing is written until :func:`start` (the ProgressPage precedent)."""
    out = cfg.output_dir or os.path.join(os.path.abspath(generator_dir), "out")
    sid = session_id or new_session_id()

    s: BuildSession | None = None
    if session_id:
        try:
            s = load(os.path.join(sessions_dir(), f"{session_id}.json"))
        except (OSError, ValueError):
            s = None
    if s is not None and s.status != RUNNING:      # archive the prior run's truth
        s.history.append({"started": s.started, "finished": s.finished,
                          "status": s.status, "images": s.images,
                          "error_tail": s.error_tail})
    if s is None:
        s = BuildSession(id=sid, created=_now())
        s.workdir = session_workdir(out, sid)

    s.kind = "fleet"
    s.label = derive_fleet_label(cfg)
    s.config = cfg.to_dict()                       # no SECRET fields in a fleet config
    s.blanked_secrets = []
    s.held_secret_files = []                       # ...and no secret-FILE fields either
    s.backend = backend
    s.images = [{"id": "fleet", "role": "all-roles",
                 "platform": ", ".join(fleet_platform_families(cfg)),
                 "status": "queued", "exit_code": None, "keys_ok": None}]
    s.error_tail = {}
    s.log_path = os.path.join(s.workdir, FLEET_LOG_NAME)
    return s


# ── write points (atomic, best-effort — exactly like tray.write_build_status) ─────────
def save(s: BuildSession) -> None:
    """Atomically persist the record. Best-effort: a build must never die because a
    record could not be written."""
    path = s.path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = f"{path}.{os.getpid()}.tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(s.to_dict(), fh, indent=2)
        os.replace(tmp, path)
    except OSError:
        pass


def start(s: BuildSession) -> None:
    """START write, at REAL dispatch: status ``running`` + pid/hostname. On a RESTART
    the same record flips back to running with ``restarts`` incremented and the new
    dispatch appended to ``runs``."""
    s.started = _now()
    s.finished = ""
    s.status = RUNNING
    s.pid = os.getpid()
    s.hostname = socket.gethostname()
    s.runs.append(s.started)
    s.restarts = max(0, len(s.runs) - 1)
    save(s)


def update_image(s: BuildSession, index: int, *, status: str,
                 exit_code: int | None = None, keys_ok: bool | None = None) -> None:
    """Per-image completion write (one atomic rewrite per image, never per line) so a
    later crash still preserves partial truth."""
    if 0 <= index < len(s.images):
        s.images[index].update(status=status, exit_code=exit_code, keys_ok=keys_ok)
    save(s)


def finish(s: BuildSession, status: str,
           error_tail: dict[str, list[str]] | None = None) -> None:
    """FINISH write: the terminal status (complete/failed/stopped) plus the failed
    rows' error tails (the honest error pointer, never fabricated)."""
    s.finished = _now()
    s.status = status
    s.error_tail = {k: list(v)[-ERROR_TAIL_LINES:] for k, v in (error_tail or {}).items()}
    save(s)


def overall_status(image_statuses: list[str]) -> str:
    """The session's terminal status from the per-image driver results: all ok ->
    complete; any failed -> failed; else stopped (mirrors summary_exit_code's
    tolerance semantics without inventing a new state)."""
    if image_statuses and all(st == "ok" for st in image_statuses):
        return COMPLETE
    if any(st == "failed" for st in image_statuses):
        return FAILED
    return STOPPED


# ── reads ─────────────────────────────────────────────────────────────────────────────
def load(path: str) -> BuildSession:
    """Load one record; raises OSError/ValueError on a missing/corrupt file."""
    with open(path, encoding="utf-8") as fh:
        return BuildSession.from_dict(json.load(fh))


def scan() -> tuple[list[BuildSession], list[str]]:
    """All records newest-first (the sortable id is the sort key) plus the paths of
    unreadable/corrupt files — surfaced, never rewritten, never a crash."""
    sessions: list[BuildSession] = []
    unreadable: list[str] = []
    try:
        names = sorted(os.listdir(sessions_dir()), reverse=True)
    except OSError:
        return [], []
    for name in names:
        if not name.endswith(".json"):
            continue
        path = os.path.join(sessions_dir(), name)
        try:
            sessions.append(load(path))
        except (OSError, ValueError):
            unreadable.append(path)
    return sessions, unreadable


def load_all() -> list[BuildSession]:
    """The readable records, newest-first. Never rewrites anything on disk."""
    return scan()[0]


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except (PermissionError, OSError):
        return True         # exists but not ours / unknown — do not claim it died
    return True


def is_stale(s: BuildSession) -> bool:
    """True when a record says ``running`` but its recorded pid (on THIS host) is gone
    — the UI renders "running (process gone — likely interrupted)". Purely a RENDER
    hint: the record itself is never mutated into a fake terminal state. A running
    record from another host is never called stale (we cannot probe it)."""
    return (s.status == RUNNING and bool(s.pid)
            and s.hostname == socket.gethostname()
            and not _pid_alive(int(s.pid)))


# ── pre-session (unmanaged) discovery ─────────────────────────────────────────────────
@dataclass
class UnmanagedBuild:
    """A best-effort discovered pre-session build tree: a ``wl-<role>.<platform>``
    dir under the default out dir that no session record owns. Status is honestly
    ``unknown`` — never fabricated — and no config snapshot exists (Restart/Redo do
    not apply)."""
    path: str
    role: str
    platform: str
    mtime: float
    has_log: bool
    log_path: str


def discover_unmanaged(out_dir: str) -> list[UnmanagedBuild]:
    """Scan ``out_dir`` (top level only — session trees live under ``out/sessions/``
    and are never scanned) for ``wl-<role>.<platform>`` build dirs, newest first.
    Best-effort: an unreadable out dir yields an empty list."""
    found: list[UnmanagedBuild] = []
    legacy_log = os.path.join(out_dir, LOG_NAME)
    has_legacy_log = os.path.isfile(legacy_log)
    try:
        names = os.listdir(out_dir)
    except OSError:
        return []
    for name in names:
        if not name.startswith("wl-") or "." not in name[3:]:
            continue
        path = os.path.join(out_dir, name)
        if not os.path.isdir(path):
            continue
        role, _, platform = name[3:].rpartition(".")
        try:
            mtime = os.stat(path).st_mtime
        except OSError:
            mtime = 0.0
        found.append(UnmanagedBuild(path=path, role=role, platform=platform,
                                    mtime=mtime, has_log=has_legacy_log,
                                    log_path=legacy_log))
    found.sort(key=lambda u: u.mtime, reverse=True)
    return found


# ── deletion / cleanup (best-effort, three-way guarded — the Welcome delete affordance) ─
def is_active(s: BuildSession) -> bool:
    """True when a record is a build in progress RIGHT NOW — status ``running`` and NOT
    stale (its pid is alive on this host, or it is a running record from another host we
    cannot probe). The never-delete guard: an active session is a live build and its
    record / artifacts must never be removed out from under it. (Same predicate the
    RESTART gate uses — see :meth:`sessions_widget.PreviousBuildsWidget.can_restart`.)"""
    return s.status == RUNNING and not is_stale(s)


def _is_session_workdir(path: str, session_id: str) -> bool:
    """Safety shape-check for ANY rmtree: True only when ``path`` matches the
    ``<out>/sessions/<id>`` footprint :func:`session_workdir` mints — the basename IS the
    session id and its parent dir is ``sessions``. A hand-edited/tampered record whose
    ``workdir`` points elsewhere (``/``, ``$HOME``, the shared out dir) fails this and is
    never rmtree'd — record deletion (a cheap unlink) still proceeds."""
    norm = os.path.normpath(path)
    return (os.path.basename(norm) == session_id
            and os.path.basename(os.path.dirname(norm)) == "sessions")


def delete(s: BuildSession, *, remove_artifacts: bool = False) -> bool:
    """Delete a session record — and, only when asked, its artifact tree. Refuses an
    ACTIVE (in-progress) session: returns False, nothing touched.

    Best-effort like the write points: the record ``<id>.json`` is unlinked in a
    try/except (an already-gone file is success, never a crash). The artifact dir is
    rmtree'd ONLY when ``remove_artifacts`` is set AND ``s.workdir`` passes the
    :func:`_is_session_workdir` shape-check, so a poisoned workdir can never rmtree an
    arbitrary path. Returns True once the record is gone."""
    if is_active(s):
        return False
    try:
        os.remove(s.path())
    except OSError:
        pass
    if (remove_artifacts and _is_session_workdir(s.workdir, s.id)
            and os.path.isdir(s.workdir)):
        shutil.rmtree(s.workdir, ignore_errors=True)
    return True


def delete_path(path: str) -> None:
    """Best-effort unlink of a single record file — for corrupt/unreadable records that
    never parse into a :class:`BuildSession` (surfaced by :func:`scan`). Never raises."""
    try:
        os.remove(path)
    except OSError:
        pass


def delete_unmanaged(u: UnmanagedBuild, *, remove_tree: bool = True) -> bool:
    """Delete a discovered pre-session ``wl-*`` build tree (they accumulate identically
    to session dirs). Guarded by the same shape discipline: rmtree runs only when the
    basename is a ``wl-*`` dir that exists — never the shared out dir or a forged path.
    Returns True on removal, False when the guard refuses or ``remove_tree`` is off."""
    if (remove_tree and os.path.basename(os.path.normpath(u.path)).startswith("wl-")
            and os.path.isdir(u.path)):
        shutil.rmtree(u.path, ignore_errors=True)
        return True
    return False


def prune(*, remove_artifacts: bool = False) -> tuple[int, int]:
    """Bulk-delete every NON-active session record (powers "Delete all finished"):
    iterate the readable records, skip each active (in-progress) one, pass every other
    to :func:`delete`. Returns ``(deleted, skipped_active)``."""
    deleted = skipped = 0
    for s in load_all():
        if is_active(s):
            skipped += 1
            continue
        if delete(s, remove_artifacts=remove_artifacts):
            deleted += 1
    return deleted, skipped


# ── search (dumb, fast, unit-testable) ────────────────────────────────────────────────
def session_haystack(s: BuildSession) -> str:
    """The precomputed lowercase filter haystack for a session row: label + roles +
    platforms + status + ISO date."""
    parts = [s.label, s.status, s.created, s.started]
    for img in s.images:
        parts += [str(img.get("role", "")), str(img.get("platform", ""))]
    return " ".join(p for p in parts if p).lower()


def unmanaged_haystack(u: UnmanagedBuild) -> str:
    return " ".join([u.role, u.platform, "unknown", "unmanaged",
                     datetime.fromtimestamp(u.mtime).isoformat(timespec="seconds")
                     if u.mtime else ""]).lower()


def matches(haystack: str, query: str) -> bool:
    """Case-insensitive substring match: every whitespace-separated term of ``query``
    must appear in the haystack."""
    return all(tok in haystack for tok in query.lower().split())

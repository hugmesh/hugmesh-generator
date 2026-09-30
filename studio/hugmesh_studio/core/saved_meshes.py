"""Saved local meshes — durable per-mesh records so a mesh can be brought BACK
instead of always being generated from scratch (model + IO, no Qt).

OPERATOR ASK (2026-09-01): "an option to SAVE the running mesh into a persisted
config, and a TABLE of saved meshes shown when one tries to generate a new mesh,
from which a saved entry can be started/restored (and deleted), instead of always
generating from scratch."

Records live one-file-per-mesh under :func:`meshes_dir` — ``<state>/meshes/<id>.json``
— resolved through :func:`.state_paths.state_dir`, so ``$HUGMESH_STUDIO_STATE_DIR``
and the pytest home-fallback guard apply here exactly as they do to the build
sessions, the crash logs and the run logs. The id convention (``%Y%m%d-%H%M%S-`` +
6 hex) is COPIED from :func:`.build_sessions.new_session_id` rather than imported:
``build_sessions`` drags the whole worklist/config/roles stack in behind it, and
this module is reached from a page that already imports enough.

WHAT A RECORD IS, AND WHAT IT IS NOT
====================================
A record is the mesh's *identity and shape*: the full
:class:`.local_mesh_bootstrap.LocalMeshBootstrapConfig`, the env a bring-up
exports, the TEXT of the generated compose/theme overlays, the per-repo source
HEADs it was built from, the compose project and kind cluster names, the doors,
the extra accounts' names and roles, and an INVENTORY of the data volumes.

**DATA VOLUMES ARE NOT INCLUDED.** ``volumes["included"]`` is a literal ``False``
in every record this module writes, and the reason travels IN the record so a
restore can state it rather than surprise anyone. Four reasons:

1. **Size and shape.** A local mesh declares 16-20 named volumes — ``casdoor-pg``
   (the whole identity tier), nine BFF postgres, ``cassandra``, ``tuwunel``,
   the mastodon/akkoma uploads, ``tor-onion-keys``. Routinely multi-GB. Records
   live under ``~/.hugmesh/studio``.
2. **Consistency.** A correct copy needs the stack HALTED plus a helper container
   per volume (``docker run --rm -v <vol>:/v busybox tar``). That machinery exists
   nowhere in core, and a hot copy of a running postgres is a corrupt copy that
   looks fine until the restore.
3. **Usually unnecessary.** The page's Stop is ``make stack-halt``
   (:meth:`.local_stack_node.LocalStackNode.stop`), which KEEPS every volume — so
   the common "bring my mesh back" case reattaches the same data with no copy.
4. **Secret surface.** Copying ``casdoor-pg`` would put a full identity database —
   hashes, tokens — into the Studio state dir, outside the operator's existing
   secret handling.

The inventory is taken by compose LABEL (:func:`.vaults.list_volumes`), NEVER from
the compose file: three volumes on this host survived a ``stack-clean`` because
their compose definitions had been RENAMED, and ``down -v`` only drops what the
CURRENT files declare. A file-derived inventory would have reported them absent.

NO SECRET VALUE IS EVER WRITTEN. ``credentials`` holds POINTERS — paths, sha256s,
mtimes — plus the superadmin USERNAME. ``auth_key`` is dropped on the way out and
named in ``blanked_secrets``; ``egress_vpn_conf`` is stored as a path only (the
file itself is a VPN credential). The credential-file COPY is opt-in and OFF by
default (the operator's own wording was "credential pointers"); when asked for, the
copies land in the record's own side dir at 0600 and the record says ``copied:
true`` so a restore can use them — the VALUES still never enter the JSON.

BLOCKING BY CONTRACT. :func:`capture` and :func:`probe_state` shell out to docker
and git and must be called OFF the GUI thread (the ``_StatusProbe``/``own_probe``
idiom in ``gui/pages/_widgets.py``). :func:`restore_plan` is PURE given probe
results — the :func:`.emulation_save.plan_mesh_save` split, for the same reason: a
table has to render "what would a restore give me back" without touching docker.

Qt-free by construction (the :mod:`.build_sessions` precedent) — imported by the
GUI page and driven directly by the pure-core tests.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime
from typing import Any

from . import vaults
from .local_stack_node import _COMPOSE_PROJECT, PRIVATE_ARTIFACT_SERVICES
from .state_paths import state_dir

#: Record schema version. Bumped only for a change ``from_dict`` cannot absorb.
SCHEMA = 1

#: Per-call docker/git timeout. Matches the vaults/local_stack_node convention.
_CMD_TIMEOUT = 30

#: The two credential files a record points at (and, on the opt-in, copies).
E2E_CREDENTIALS_BASENAME = ".e2e-credentials"

#: Generated/derived files a restore RE-DERIVES rather than replays. Named in the
#: record so the operator can see what is deliberately absent instead of wondering.
REGENERATED = (
    ".m2-registry.env",
    "tests/stack/.tls-front/",
    "tests/stack/.mastodon.env",
)

#: The generated overlays whose TEXT the record carries verbatim. These are
#: gitignored dot-files the Makefile wildcard-includes, so replaying the text is
#: what makes a restored mesh come up with the same limits/theme/own-Casdoor shape.
_OVERLAY_FILES = {
    "theme_css": os.path.join("tests", "stack", ".theme.css"),
    "compose_limits": os.path.join("tests", "stack", ".compose.limits.yaml"),
    "compose_own_domains": os.path.join("tests", "stack",
                                        ".compose.own-domains.yaml"),
}

#: Substrings that mark an env var as secret-shaped. ``_build_env`` starts from
#: ``os.environ.copy()``, so a naive snapshot would persist every token in the
#: operator's shell. The snapshot keeps only what the NODE added or changed (see
#: :func:`_env_snapshot`) and then drops anything matching these — belt and braces,
#: because "only the delta" is a claim about a function this module does not own.
_SECRET_ENV_MARKERS = ("TOKEN", "SECRET", "PASSWORD", "PASSWD", "AUTHKEY",
                       "AUTH_KEY", "CREDENTIAL", "PRIVATE_KEY", "APIKEY",
                       "API_KEY", "_PW", "SESSION")

#: Env vars that are neither secret nor useful in a record: the theme CSS is
#: carried verbatim in ``overlays`` already and is kilobytes long.
_BULKY_ENV = ("HUG_THEME_CSS", "SNAP_THEME_CSS")

#: The one-sentence reason every record carries beside ``included: False``.
VOLUMES_NOT_INCLUDED_REASON = (
    "data volumes are inventoried, never copied: they are multi-GB, a consistent "
    "copy needs the stack halted plus a helper container per volume, 'Stop mesh' "
    "(make stack-halt) keeps them anyway, and copying casdoor-pg would put an "
    "identity database into the Studio state dir")


# ── paths + ids ────────────────────────────────────────────────────────────────
def meshes_dir() -> str:
    """``<state>/meshes`` — one record file per saved mesh, plus one optional side
    dir per record for credential copies."""
    return os.path.join(state_dir(), "meshes")


def new_id() -> str:
    """A sortable id: ``%Y%m%d-%H%M%S-`` + 6 hex chars (uniqueness within the
    second, so two Studio processes saving at once cannot collide). Deliberately
    the same SHAPE as ``build_sessions.new_session_id`` — copied, not imported;
    see the module docstring."""
    return datetime.now().strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:6]


def _now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _safe_id(rec_id: str) -> bool:
    """A record id that can only name a file DIRECTLY inside ``meshes_dir()``: non-empty,
    no separator, not ``.``/``..``. (The minted shape is :func:`new_id`'s; hand-written
    ids in old records are tolerated so long as they cannot walk.)"""
    return (isinstance(rec_id, str) and rec_id not in ("", ".", "..")
            and "/" not in rec_id and "\\" not in rec_id and os.sep not in rec_id
            and "\0" not in rec_id)


def _inside_meshes(path: str) -> bool:
    base = os.path.normpath(meshes_dir())
    try:
        return os.path.commonpath([base, os.path.normpath(path)]) == base \
            and os.path.normpath(path) != base
    except ValueError:                           # e.g. different drives
        return False


def _copy_path(entry) -> str | None:
    """The absolute path of a record's credential copy, or ``None`` when the pointer is
    not a plain path INSIDE ``meshes_dir()``.

    A record is JSON on a disk anyone can write to; ``os.path.join(meshes_dir(), x)``
    discards ``meshes_dir()`` when ``x`` is absolute and walks out with ``..`` (#363),
    which let a record point a restore's seeder at, or copy into the generator checkout,
    any readable file. Every read and write of a copy goes through here.
    """
    if not isinstance(entry, dict):
        return None
    rel = str(entry.get("copy") or "")
    if not rel or os.path.isabs(rel) or "\0" in rel:
        return None
    path = os.path.normpath(os.path.join(meshes_dir(), rel))
    return path if _inside_meshes(path) else None


# ── the record ─────────────────────────────────────────────────────────────────
@dataclass
class SavedMesh:
    """One persisted local mesh (see the module docstring for what is and is not
    in here)."""

    schema: int = SCHEMA
    id: str = ""
    label: str = ""
    created: str = ""
    updated: str = ""
    generator_dir: str = ""
    generator_head: str = ""
    hostname: str = ""
    #: Every LocalMeshBootstrapConfig field (``LocalMeshBootstrapConfig.to_dict``),
    #: with the secret-bearing ones blanked (see ``blanked_secrets``).
    config: dict = field(default_factory=dict)
    #: Secret-bearing config fields deliberately NOT persisted, by NAME.
    blanked_secrets: list = field(default_factory=list)
    #: What a bring-up exports on top of the ambient environment, minus anything
    #: secret-shaped or bulky (see :func:`_env_snapshot`).
    env_snapshot: dict = field(default_factory=dict)
    #: TEXT of the generated overlays (theme / limits / own-domains).
    overlays: dict = field(default_factory=dict)
    #: Files a restore RE-DERIVES rather than replays (:data:`REGENERATED`).
    regenerated: list = field(default_factory=list)
    #: {mode, dir, repos:[{name, path, branch, head, dirty}]}
    source: dict = field(default_factory=dict)
    #: {compose_project, kind_cluster, kube_context}
    lanes: dict = field(default_factory=dict)
    #: POINTERS only — paths, hashes, mtimes, the superadmin USERNAME. No values.
    credentials: dict = field(default_factory=dict)
    #: {included: False, reason: "...", inventory: [{name, short, size_bytes,
    #: in_use_by}]}
    volumes: dict = field(default_factory=dict)
    #: {web_url, plain_web_url, onion}
    doors: dict = field(default_factory=dict)
    #: {compose_running, kind_running, running_env, at}
    last_seen: dict = field(default_factory=dict)
    #: [{username, roles, password_saved: False}] — names and roles only.
    extra_users: list = field(default_factory=list)
    #: The GUI form's INPUTS behind config fields that are DERIVED (the theme's
    #: primary/secondary/preset/font — ``login_theme_css`` is their output and is
    #: not invertible). The page writes and reads this; core never interprets it.
    form: dict = field(default_factory=dict)
    #: Free-text notes rendered under the table (never a substitute for a field).
    notes: list = field(default_factory=list)

    def path(self) -> str:
        return os.path.join(meshes_dir(), f"{self.id}.json")

    def copy_dir(self) -> str:
        """The record's own side dir — the ONLY place this module ever writes
        anything but its JSON, and the only path :func:`delete` will rmtree."""
        return os.path.join(meshes_dir(), self.id)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "SavedMesh":
        """Load a record, filtering unknown keys and COERCING every declared-``str``
        field (and every dict/list field to its container type).

        The :meth:`.build_sessions.BuildSession.from_dict` rationale applies
        verbatim: a record is JSON on a disk anyone can write to, and a non-``str``
        ``label`` reaching ``QTableWidgetItem`` from inside a Qt slot is a
        ``qFatal`` under PyQt6, not an exception something can catch. So the
        coercion happens once, at this boundary, rather than at each consumer.
        ``str(value)`` renders what the record actually says (never a substitute);
        ``null`` becomes ``""``, the field's own default.
        """
        if not isinstance(d, dict):
            raise ValueError("saved-mesh record must be a JSON object")
        known = set(cls.__dataclass_fields__)          # type: ignore[attr-defined]
        vals = {k: v for k, v in d.items() if k in known}
        for k in _STR_FIELDS.intersection(vals):
            v = vals[k]
            if not isinstance(v, str):
                vals[k] = "" if v is None else str(v)
        for k in _DICT_FIELDS.intersection(vals):
            if not isinstance(vals[k], dict):
                vals[k] = {}
        for k in _LIST_FIELDS.intersection(vals):
            if not isinstance(vals[k], list):
                vals[k] = []
        if "schema" in vals and not isinstance(vals["schema"], int):
            vals["schema"] = SCHEMA
        return cls(**vals)

    # ---- derived, render-only helpers (no IO) ---------------------------------
    def services_text(self) -> str:
        """The saved service selection as one line — honouring the None/() split
        (see :class:`.local_mesh_bootstrap.LocalMeshBootstrapConfig`)."""
        svc = self.config.get("services")
        if svc is None:
            return "(picker unused — profile defaults)"
        if not svc:
            return "none (explicit)"
        return ", ".join(str(s) for s in svc)

    def brand_text(self) -> str:
        env = str(self.config.get("env") or "test")
        brand = str(self.config.get("brand") or "")
        return f"{env} / {brand}" if brand else env

    def volume_count(self) -> int:
        return len(self.volumes.get("inventory") or [])

    def volume_names(self) -> list[str]:
        return [str(v.get("name") or "") for v in (self.volumes.get("inventory") or [])
                if isinstance(v, dict) and v.get("name")]

    def credential_copies(self) -> list[str]:
        """Absolute paths of the credential copies this record DECLARES. A record
        that declares one whose file is gone is the case :func:`restore_plan`
        blocks on — declared and missing is worse than never copied, because a
        restore would silently mint different passwords."""
        out: list[str] = []
        for key in ("e2e_file", "secrets_json"):
            entry = self.credentials.get(key) or {}
            if isinstance(entry, dict) and entry.get("copied") and entry.get("copy"):
                # An out-of-tree pointer is REPORTED as a copy that is not there (a path
                # that can never be a file), so the plan BLOCKS — it never reads it
                # (#363). Fail closed, not silently "no copies declared".
                out.append(_copy_path(entry) or os.path.join(
                    meshes_dir(), ".refused-pointer-" + os.path.basename(str(entry["copy"]))))
        return out

    def has_credential_copies(self) -> bool:
        return bool(self.credential_copies())

    def same_checkout(self, generator_dir: str, hostname: str = "") -> bool:
        """Does this record describe the mesh THIS Studio session drives? A
        record from another checkout (or another host) points at another mesh's
        volumes, so a warm Start over it would reattach the wrong data."""
        same_dir = os.path.abspath(self.generator_dir or "") == os.path.abspath(
            generator_dir or "")
        same_host = (not hostname) or (not self.hostname) or (self.hostname == hostname)
        return same_dir and same_host


#: The fields DECLARED ``str``/``dict``/``list`` above — derived from the dataclass
#: so a field added later is covered without anyone remembering to.
def _fields_of(kind: str) -> frozenset[str]:
    return frozenset(
        name for name, f in SavedMesh.__dataclass_fields__.items()   # type: ignore[attr-defined]
        if f.type == kind or getattr(f.type, "__name__", "") == kind)


_STR_FIELDS = _fields_of("str")
_DICT_FIELDS = _fields_of("dict")
_LIST_FIELDS = _fields_of("list")


# ── persistence ────────────────────────────────────────────────────────────────
def save(rec: SavedMesh) -> str:
    """Atomically persist the record; returns the path, or ``""`` on failure.

    Best-effort by construction (the ``build_sessions.save`` discipline): a save is
    something an operator asked for on top of a RUNNING mesh, and no failure to
    write a JSON file may ever be allowed to take that mesh down or raise out of a
    Qt slot. The caller renders the empty return as a note.
    """
    rec.updated = _now()
    path = rec.path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = f"{path}.{os.getpid()}.tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(rec.to_dict(), fh, indent=2, sort_keys=False)
        os.replace(tmp, path)
        return path
    except (OSError, TypeError, ValueError):
        return ""


def load(path: str) -> SavedMesh:
    """Load one record; raises OSError/ValueError on a missing/corrupt file."""
    with open(path, encoding="utf-8") as fh:
        rec = SavedMesh.from_dict(json.load(fh))
    # The id names the side dir and is joined into paths (path(), copy_dir(), delete()):
    # a record whose id is not safe, or disagrees with the file it came from, is
    # tampered or mis-copied. Refuse it here so scan() surfaces it as an `unreadable`
    # row (deletable BY PATH) instead of handing out a record that can walk (#363).
    stem = os.path.basename(path)
    stem = stem[:-5] if stem.endswith(".json") else stem
    if not _safe_id(rec.id) or rec.id != stem:
        raise ValueError(f"saved-mesh record id {rec.id!r} does not match its file")
    return rec


def scan() -> tuple[list[SavedMesh], list[str]]:
    """All records newest-first (the sortable id is the sort key) plus the paths of
    unreadable/corrupt files — SURFACED, never rewritten, never a crash. A corrupt
    record becomes a row the operator can delete; silently skipping it would leave
    a file they cannot see and cannot remove from the Studio."""
    recs: list[SavedMesh] = []
    unreadable: list[str] = []
    try:
        names = sorted(os.listdir(meshes_dir()), reverse=True)
    except OSError:
        return [], []
    for name in names:
        if not name.endswith(".json"):
            continue
        path = os.path.join(meshes_dir(), name)
        try:
            recs.append(load(path))
        except (OSError, ValueError, TypeError):
            unreadable.append(path)
    return recs, unreadable


def find(mesh_id: str) -> SavedMesh | None:
    """The record with this id, or None (unreadable records never match)."""
    for r in scan()[0]:
        if r.id == mesh_id:
            return r
    return None


def latest_for_checkout(generator_dir: str,
                        hostname: str | None = None) -> SavedMesh | None:
    """The most recently SAVED record that describes the mesh this checkout drives
    (:meth:`SavedMesh.same_checkout` — same generator dir, same host), or None.

    "Most recent" is ``updated`` (a re-save moves a record forward), falling back to
    ``created`` and then the sortable id. Pure file reads, no docker — the one reader
    the node-image flows use to learn what a saved local mesh RAN (its domain, its
    services and therefore whether it ran Tor, #579). ``hostname`` defaults to this
    host; pass ``""`` to match any host."""
    host = socket.gethostname() if hostname is None else hostname
    mine = [r for r in scan()[0] if r.same_checkout(generator_dir, host)]
    if not mine:
        return None
    return max(mine, key=lambda r: (_stamp(r.updated) or _stamp(r.created), r.id))


def _stamp(value: str) -> float:
    """An ISO-8601 record timestamp as epoch seconds (0.0 when unparseable). Parsed
    rather than string-compared: ``_now()`` writes the LOCAL offset, so two records
    either side of a DST change would otherwise sort by their text."""
    try:
        return datetime.fromisoformat(str(value)).timestamp()
    except (TypeError, ValueError):
        return 0.0


def _is_record_copy_dir(path: str, rec_id: str) -> bool:
    """Safety shape-check for ANY rmtree: True only when ``path`` matches the
    ``<state>/meshes/<id>`` footprint :meth:`SavedMesh.copy_dir` mints — the
    basename IS the record id and its parent is ``meshes``. A hand-edited or
    tampered record whose id points elsewhere (``/``, ``$HOME``, the generator
    tree) fails this and is never rmtree'd (the
    ``build_sessions._is_session_workdir`` guard shape, same reason)."""
    norm = os.path.normpath(path)
    return (bool(rec_id)
            and rec_id not in ("", ".", "..")
            and os.sep not in rec_id
            and os.path.basename(norm) == rec_id
            and os.path.basename(os.path.dirname(norm)) == "meshes")


def delete(rec: SavedMesh, *, remove_copies: bool = True) -> bool:
    """Delete a record — and, unless told not to, its own side dir.

    Removes NOTHING outside ``<state>/meshes``: no volume, no image, no container,
    nothing under the generator tree. The running mesh is untouched by design; the
    UI says so where the operator presses it.
    """
    # The record FILE is checked like the side dir is: an id that walks ('../../x')
    # made rec.path() resolve outside <state>/meshes and os.remove() deleted it (#363).
    # Refuse, and say so — the caller's tampered record is surfaced as unreadable by
    # scan() and removed by path (delete_path), which is itself pinned to meshes_dir().
    if not (_safe_id(rec.id) and os.path.dirname(os.path.normpath(rec.path()))
            == os.path.normpath(meshes_dir())):
        return False
    try:
        os.remove(rec.path())
    except OSError:
        pass
    d = rec.copy_dir()
    if remove_copies and _is_record_copy_dir(d, rec.id) and os.path.isdir(d):
        shutil.rmtree(d, ignore_errors=True)
    return True


def delete_path(path: str) -> None:
    """Best-effort unlink of a single record FILE — for the corrupt records
    :func:`scan` surfaces, which never parse into a :class:`SavedMesh`. Refuses
    anything outside the meshes dir: a corrupt record is a path this module
    listed, never one handed in from elsewhere."""
    norm = os.path.normpath(path)
    if os.path.dirname(norm) != os.path.normpath(meshes_dir()):
        return
    try:
        os.remove(norm)
    except OSError:
        pass


# ── small blocking helpers (docker / git / hashing) ────────────────────────────
def _run(args: list[str], *, cwd: str | None = None,
         timeout: int = _CMD_TIMEOUT) -> tuple[int, str]:
    """One subprocess call. Never raises — a missing binary or a hung daemon is
    an honest "unknown", not a traceback out of a worker thread."""
    try:
        r = subprocess.run(args, cwd=cwd, capture_output=True, text=True,
                           timeout=timeout)
        return r.returncode, (r.stdout or "")
    except (OSError, subprocess.SubprocessError):
        return 1, ""


def _sha256(path: str) -> str:
    try:
        h = hashlib.sha256()
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return ""


def _mtime(path: str) -> str:
    try:
        return datetime.fromtimestamp(os.path.getmtime(path)).astimezone(
        ).isoformat(timespec="seconds")
    except OSError:
        return ""


def _git(repo: str, *args: str) -> str:
    rc, out = _run(["git", "-C", repo, *args], timeout=15)
    return out.strip() if rc == 0 else ""


def _repo_rows(root: str) -> list[dict]:
    """One row per ``hugmesh-*`` checkout under ``root``: name, path, branch, HEAD
    and whether the tree is dirty.

    The recorded per-repo HEAD is the ONLY reproducibility handle this record can
    offer: the mesh builds from unmerged fix BRANCHES in ``.stack-src``, and a kept
    (non-disposable) checkout may have moved since. A restore does not check these
    out — it SHOWS them, so "the images are rebuilt from the tree as it is now" is
    a statement the operator can check rather than a surprise.
    """
    rows: list[dict] = []
    try:
        names = sorted(n for n in os.listdir(root) if n.startswith("hugmesh"))
    except OSError:
        return rows
    for name in names:
        p = os.path.join(root, name)
        if not os.path.isdir(os.path.join(p, ".git")):
            continue
        rows.append({
            "name": name,
            "path": p,
            "branch": _git(p, "rev-parse", "--abbrev-ref", "HEAD"),
            "head": _git(p, "rev-parse", "HEAD"),
            "dirty": bool(_git(p, "status", "--porcelain")),
        })
    return rows


def _env_snapshot(build_env: dict[str, str],
                  ambient: dict[str, str] | None = None) -> dict[str, str]:
    """The env a bring-up ADDS or CHANGES, minus anything secret-shaped or bulky.

    ``LocalStackNode._build_env`` starts from ``os.environ.copy()``, so persisting
    it whole would put every token in the operator's shell (GH_TOKEN, cloud keys,
    an inherited TS_AUTHKEY) into a JSON file under ``~/.hugmesh/studio``. Keeping
    only the DELTA against the ambient environment is what makes the snapshot the
    stack's own knobs — ENV, SOCIAL/TOR/PHPBB…, PUBLIC_HOST_PORT, STACK_SRC,
    KIND_ADDONS, the OIDC endpoints — and nothing else. The marker filter then runs
    over that anyway, because "only the delta" is a claim about a function this
    module does not own and must not be the only thing standing between a shell
    variable and a saved file.
    """
    amb = os.environ if ambient is None else ambient
    out: dict[str, str] = {}
    for k, v in (build_env or {}).items():
        if amb.get(k) == v:
            continue                     # inherited, not this mesh's choice
        if k in _BULKY_ENV:
            continue
        if any(m in k.upper() for m in _SECRET_ENV_MARKERS):
            continue
        out[k] = v
    return dict(sorted(out.items()))


def _read_text(path: str, limit: int = 512 * 1024) -> str:
    """The text of a generated overlay, capped. The cap is not paranoia: the record
    is a JSON file the GUI reloads on every page entry, and an overlay is at most a
    few KB — anything past the cap is a file that is no longer the overlay."""
    try:
        if os.path.getsize(path) > limit:
            return ""
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def _kind_cluster() -> str:
    return os.environ.get("KIND_CLUSTER_NAME", "") or "hugmesh-local"


# ── capture (BLOCKING — run it on a worker thread) ─────────────────────────────
def capture(generator_dir: str, cfg, node, boot, *, label: str = "",
            copy_credentials: bool = False,
            project: str = vaults.DEFAULT_PROJECT,
            extra_users: list[str] | None = None,
            form: dict | None = None) -> SavedMesh:
    """Build (and RETURN, without writing) the record for the mesh described by
    ``cfg`` and served by ``node``.

    BLOCKING BY CONTRACT: ``docker volume ls`` + one ``inspect`` per volume, a
    ``git rev-parse`` per source repo, two sha256s, and ``node.running_env()``
    (itself two docker calls). Call it from a worker thread.

    ``copy_credentials`` is the opt-in: with it, ``.e2e-credentials`` and
    ``keys-out/vault/secrets.json`` are copied into the record's side dir at 0600
    and the record says ``copied: true``. Without it — the DEFAULT — only paths,
    hashes and mtimes are recorded, and a cold restore uses whatever credential
    files are on disk at that time (the plan says so). Either way no secret VALUE
    is written into the JSON.

    ``form`` is the GUI's opaque input dict for derived config fields (the theme
    inputs); core stores it and never reads it.
    """
    from .local_mesh_bootstrap import LocalMeshBootstrapConfig  # local: avoid a cycle

    rec = SavedMesh(id=new_id(), created=_now(),
                    generator_dir=os.path.abspath(generator_dir),
                    hostname=socket.gethostname())
    rec.label = label or _derive_label(cfg)
    rec.generator_head = _git(rec.generator_dir, "rev-parse", "HEAD")
    rec.config = (cfg.to_dict() if hasattr(cfg, "to_dict")
                  else LocalMeshBootstrapConfig().to_dict())
    # auth_key is a tailnet credential: NEVER persisted, named as absent instead.
    rec.config["auth_key"] = ""
    rec.blanked_secrets = ["auth_key"]
    rec.regenerated = list(REGENERATED)
    rec.form = dict(form or {})

    # OVERLAYS — the on-disk text is what the last bring-up ran with (the Makefile
    # wildcard-includes these files). Read BEFORE the env below and with
    # `write_overlays=False` there: a save is a READ of the running mesh and must
    # not rewrite the checkout's overlays with the form's current values on its
    # way past. (Order kept anyway — a record whose overlays could be rewritten
    # mid-capture is a record that describes neither state.)
    rec.overlays = {name: _read_text(os.path.join(rec.generator_dir, rel))
                    for name, rel in _OVERLAY_FILES.items()}

    # ENV — the exact dict `make stack-*` runs with, reduced to this mesh's own
    # knobs. Never re-derived here: a second derivation is how the record and the
    # bring-up come to disagree.
    try:
        rec.env_snapshot = _env_snapshot(node._build_env(write_overlays=False))
    except Exception:                     # a probe must never sink the save
        rec.env_snapshot = {}

    src_mode = str(rec.config.get("source_mode") or "clone")
    src_dir = str(rec.config.get("source_dir") or "")
    root = (os.path.abspath(src_dir) if src_mode == "existing" and src_dir
            else os.path.join(rec.generator_dir, ".stack-src"))
    rec.source = {"mode": src_mode, "dir": root, "repos": _repo_rows(root)}

    rec.lanes = {
        "compose_project": project,
        "kind_cluster": _kind_cluster(),
        "kube_context": "kind-" + _kind_cluster(),
    }

    # VOLUMES — inventory by compose LABEL, never from the compose file (see the
    # module docstring). `included` is a literal False, with its reason travelling
    # beside it so every consumer states the same thing.
    inv = []
    try:
        for v in vaults.list_volumes(project):
            inv.append({"name": v.name, "short": v.short,
                        "size_bytes": v.size_bytes,
                        "in_use_by": list(v.in_use_by)})
    except Exception:
        inv = []
    rec.volumes = {"included": False, "reason": VOLUMES_NOT_INCLUDED_REASON,
                   "inventory": inv}
    if not inv:
        rec.notes.append("No data volumes were found for compose project "
                         f"'{project}' at save time (docker unreachable, or the "
                         "mesh was never brought up) — a restore is a cold one.")

    rec.doors = {
        "web_url": str(getattr(node, "web_url", "") or ""),
        "plain_web_url": str(getattr(node, "plain_web_url", "") or ""),
        "onion": (node.onion_url() if hasattr(node, "onion_url") else ""),
    }

    try:
        st = node.status()
        compose_running = bool(getattr(st, "running", False))
    except Exception:
        compose_running = False
    try:
        running_env = str(node.running_env() or "") if hasattr(node, "running_env") else ""
    except Exception:
        running_env = ""
    rec.last_seen = {"compose_running": compose_running, "kind_running": None,
                     "running_env": running_env, "at": _now()}
    # WHAT THE RECORD IS. `config` is the page FORM's configuration, not a read-back
    # of the running containers: the only knob this module can read off a running
    # mesh is ENV (`running_env`, from the gateway's CASDOOR_ISSUER_URI — nothing
    # else is recorded anywhere but the form). So a form that is not the mesh in
    # front of it — most easily after a Studio restart, when the page opens at its
    # defaults over a mesh that is still up — produces a record that will restore a
    # DIFFERENT mesh. That is a real limit of this lane, and the one thing it must
    # never do is stay quiet about it: `disagrees_with_running` is the structured
    # form, the note is the rendered one, and the page repeats both at save time
    # (localmesh._save_mesh) instead of leaving them inside the JSON.
    form_env = str(rec.config.get("env") or "test")
    if running_env and running_env != form_env:
        rec.last_seen["disagrees_with_running"] = [
            {"field": "env", "form": form_env, "running": running_env}]
        rec.notes.append(
            f"The form said env={form_env} but the running stack reported "
            f"env={running_env} at save time — the record follows the FORM. Load "
            "the mesh's own configuration into the page before saving, or this "
            "record restores the form's mesh, not the one that was running.")

    rec.extra_users = _extra_user_rows(extra_users or [])
    rec.credentials = _credential_pointers(rec, boot, copy=copy_credentials)
    if not copy_credentials:
        rec.notes.append(
            "Credential files were NOT copied into this record (pointers only). A "
            "warm start reuses the mesh's own files; a cold restore seeds with "
            "whatever credential files are on disk then.")
    return rec


def _derive_label(cfg) -> str:
    """A human row label: ``test · hugmesh · 7 service(s)``. Derived, never asked
    for — a save must be one press, and a record with no label is unreadable."""
    env = getattr(cfg, "env", "test") or "test"
    brand = getattr(cfg, "brand", "") or ""
    svc = getattr(cfg, "services", None)
    if svc is None:
        tail = "profile defaults"
    else:
        tail = f"{len(svc)} service(s)" if svc else "no services"
    return " · ".join(x for x in (env, brand, tail) if x)


def _extra_user_rows(specs: list[str]) -> list[dict]:
    """``name:ROLES:PW_ENV`` seeder specs -> name + roles rows.

    The third field is an env var NAME, and the password itself was only ever in
    the child process's environment at creation time, so it is UNRECOVERABLE — the
    row says so with ``password_saved: False`` rather than leaving the operator to
    discover it at restore time.
    """
    rows: list[dict] = []
    for spec in specs:
        parts = str(spec).split(":")
        if not parts or not parts[0]:
            continue
        rows.append({"username": parts[0],
                     "roles": parts[1] if len(parts) > 1 else "",
                     "password_saved": False})
    return rows


def _credential_pointers(rec: SavedMesh, boot, *, copy: bool) -> dict:
    """Paths, hashes, mtimes — and, only when ``copy`` is set, 0600 copies in the
    record's own side dir. NEVER a value."""
    gen = rec.generator_dir
    e2e_path = os.path.join(gen, E2E_CREDENTIALS_BASENAME)
    secrets_path = str(getattr(boot, "secrets_json", "") or os.path.join(
        gen, "keys-out", "vault", "secrets.json"))

    out: dict[str, Any] = {
        "note": "passwords are NOT stored — only paths, hashes and mtimes",
        "superadmin_username": "",
        "stage2": True,        # the GUI seeds with SEED_COMPLETE_REGISTRATION=1
        "operator_user": "mesh-operator",
    }
    try:
        login = boot.superadmin_login() if hasattr(boot, "superadmin_login") else None
        out["superadmin_username"] = (login[0] if login else "")
    except Exception:
        out["superadmin_username"] = ""
    if not out["superadmin_username"]:
        out["superadmin_username"] = str(rec.config.get("superadmin_username") or "")

    for key, path, base in (("e2e_file", e2e_path, "e2e-credentials"),
                            ("secrets_json", secrets_path, "secrets.json")):
        entry: dict[str, Any] = {
            "path": path,
            "sha256": _sha256(path),
            "mtime": _mtime(path),
            "copied": False,
            "copy": "",
        }
        if copy and os.path.isfile(path):
            dest_dir = rec.copy_dir()
            try:
                os.makedirs(dest_dir, mode=0o700, exist_ok=True)
                os.chmod(dest_dir, 0o700)
                dest = os.path.join(dest_dir, base)
                shutil.copyfile(path, dest)
                os.chmod(dest, 0o600)
                entry["copied"] = True
                entry["copy"] = os.path.join(rec.id, base)
            except OSError:
                entry["copied"] = False
                entry["copy"] = ""
        out[key] = entry
    return out


# ── live state (BLOCKING) + the PURE plan over it ──────────────────────────────
def _compose_running(project: str) -> bool:
    """Is anything of this compose project RUNNING now? ``docker ps`` without
    ``-a`` on purpose: a halted mesh still owns its (stopped) containers, and a
    stopped container must not read as "a mesh is up"."""
    rc, out = _run(["docker", "ps", "--filter",
                    f"label=com.docker.compose.project={project}", "-q"],
                   timeout=15)
    return rc == 0 and bool(out.strip())


def _images_present(project: str) -> bool:
    """The SAME set :meth:`.LocalStackNode.cold_build_expected` reads, so this
    module's "images are present" can never disagree with the page's own
    cold-build warning."""
    for svc in PRIVATE_ARTIFACT_SERVICES:
        rc, out = _run(["docker", "images", "-q", f"{project}-{svc}"], timeout=15)
        if rc != 0 or not out.strip():
            return False
    return True


def probe_state(rec: SavedMesh, *, project: str = "") -> dict:
    """What is TRUE on this machine right now, for one record. BLOCKING (docker).

    Returns the exact keyword set :func:`restore_plan` consumes, so the split is
    "gather here, decide there" — the same shape ``emulation_save.plan_mesh_save``
    uses, and what lets the decision be unit-tested with no docker at all.
    """
    proj = project or str((rec.lanes or {}).get("compose_project")
                          or vaults.DEFAULT_PROJECT)
    try:
        live = {v.name for v in vaults.list_volumes(proj)}
    except Exception:
        live = set()
    want = rec.volume_names()
    present = [n for n in want if n in live]
    missing = [n for n in want if n not in live]

    e2e = (rec.credentials or {}).get("e2e_file") or {}
    saved_sha = str(e2e.get("sha256") or "")
    creds_match = bool(saved_sha) and _sha256(str(e2e.get("path") or "")) == saved_sha

    src = (rec.source or {})
    root = str(src.get("dir") or "")
    source_ok = bool(root) and os.path.isdir(root)
    drift: list[str] = []
    for row in src.get("repos") or []:
        if not isinstance(row, dict):
            continue
        p = str(row.get("path") or "")
        if not os.path.isdir(p):
            drift.append(f"{row.get('name') or p} (gone)")
            continue
        head_now = _git(p, "rev-parse", "HEAD")
        if head_now and row.get("head") and head_now != row.get("head"):
            drift.append(f"{row.get('name')} (HEAD moved)")

    return {
        # a record with NO inventory is a cold restore, never an unknown one:
        # the probe DID answer, and "unknown" is reserved for "not asked yet"
        "volumes_present": bool(want) and not missing,
        "volumes_seen": len(present),
        "volumes_missing": tuple(missing),
        "images_present": _images_present(proj or _COMPOSE_PROJECT),
        "creds_match": creds_match,
        "mesh_running": _compose_running(proj),
        "source_ok": source_ok,
        "source_drift": tuple(drift),
        "copies_missing": tuple(p for p in rec.credential_copies()
                                if not os.path.isfile(p)),
    }


#: :attr:`RestorePlan.mode` values.
MODE_START = "start"        # case 1 — volumes + images present: reattach
MODE_RESEED = "reseed"      # case 2 — volumes gone: bring up + re-seed
MODE_BLOCKED = "blocked"    # a mesh is already up, or a declared copy is missing
MODE_UNKNOWN = "unknown"    # nothing has probed yet — never rendered as "no"


@dataclass(frozen=True)
class RestorePlan:
    """What a restore of THIS record would actually give back — decided at RESTORE
    time from live facts, never guessed at save time."""

    mode: str = MODE_UNKNOWN
    sentence: str = "Checking what is on this machine…"
    warnings: tuple[str, ...] = ()
    #: "12 present" / "gone (cleaned)" / "unknown" — the table's Volumes column.
    volumes_text: str = "unknown"

    def can_start(self) -> bool:
        return self.mode == MODE_START

    def can_reseed(self) -> bool:
        return self.mode == MODE_RESEED


def restore_plan(rec: SavedMesh, *, volumes_present: bool | None = None,
                 images_present: bool = False, creds_match: bool = False,
                 mesh_running: bool = False, source_ok: bool = True,
                 copies_missing: tuple[str, ...] = (),
                 source_drift: tuple[str, ...] = (),
                 volumes_missing: tuple[str, ...] = (),
                 volumes_seen: int = 0) -> RestorePlan:
    """PURE given probe results (:func:`probe_state` gathers them).

    Three cases, and the tri-state that is not a case:

    1. VOLUMES PRESENT + IMAGES PRESENT (after ``Stop mesh``, which is
       ``make stack-halt`` and KEEPS volumes) -> **Start**: reattach, no re-mint and
       no re-seed. Identity, rooms and posts survive.
    2. VOLUMES GONE (after ``Stop && clean Docker``) -> **Restore (reseed)**: bring
       up and seed again. WITH credential copies the usernames AND passwords come
       back; without them the usernames come back and the passwords are whatever
       the credential files on disk hold — the same ones only while
       ``creds_match``. The ``.onion`` does not come back either way — its key
       volume is gone.
    3. SOURCE MOVED / different HEAD -> still allowed, with the drift named: the
       images are rebuilt from the tree as it is NOW.

    ``volumes_present=None`` is UNKNOWN and renders as unknown. A tri-state matters
    here for the same reason it does on the page: telling an operator their volumes
    are gone because a probe has not answered yet is a claim about their data that
    nothing established.
    """
    warn: list[str] = []
    n = rec.volume_count()
    if volumes_present is None:
        vol_text = "unknown"
    elif volumes_present:
        vol_text = f"{n} present"
    elif volumes_missing and len(volumes_missing) < n:
        vol_text = f"{n - len(volumes_missing)} of {n} present"
    else:
        vol_text = "gone (cleaned)" if n else "none recorded"

    if copies_missing:
        return RestorePlan(
            MODE_BLOCKED,
            "Blocked — this record declares saved credential files that are no "
            "longer on disk: " + ", ".join(os.path.basename(p) for p in copies_missing)
            + ". Restoring anyway would seed different passwords than the record "
              "promises.",
            tuple(warn), vol_text)
    if mesh_running:
        return RestorePlan(
            MODE_BLOCKED,
            "Blocked — a local mesh is running right now. Stop it first; starting "
            "a saved mesh over a live one brings up a second stack on the same "
            "compose project.",
            tuple(warn), vol_text)
    if not source_ok:
        warn.append("the recorded source tree is gone — images are rebuilt from "
                    "whatever tree the form points at now")
    elif source_drift:
        warn.append("source drift: " + ", ".join(source_drift)
                    + " — images are rebuilt from the tree as it is now")

    if volumes_present is None:
        return RestorePlan(MODE_UNKNOWN, "Checking what is on this machine…",
                           tuple(warn), vol_text)

    copied = rec.has_credential_copies()
    if volumes_present and images_present:
        tail = ("The saved credential files are put back first, so the accounts "
                "are unchanged." if copied and not creds_match else
                "The mesh's current credential files are used as they are.")
        return RestorePlan(
            MODE_START,
            f"Start: reattaches {n} data volume(s) — identity, rooms and posts "
            f"survive. No credentials are re-minted and no re-seed runs. {tail}",
            tuple(warn), vol_text)
    if volumes_present and not images_present:
        warn.append("the service images are gone — the start is a COLD build (hours)")
        return RestorePlan(
            MODE_START,
            f"Start (cold build): the {n} data volume(s) are still here but the "
            f"images are not — this rebuilds them and then reattaches the same "
            f"data. No re-mint, no re-seed.",
            tuple(warn), vol_text)
    if volumes_missing and len(volumes_missing) < n:
        warn.append("only part of the data is still here (missing: "
                    + ", ".join(volumes_missing) + ") — treated as a cold restore")
    if copied:
        return RestorePlan(
            MODE_RESEED,
            "Restore (reseed): the data volumes are gone, so this brings the mesh "
            "up empty and seeds it again from the SAVED credential files — same "
            "usernames, same passwords, fresh data. The .onion is not restored (its "
            "key volume was removed).",
            tuple(warn), vol_text)
    if creds_match:
        return RestorePlan(
            MODE_RESEED,
            "Restore (reseed): the data volumes are gone and no credential files "
            "were saved with this record, but the files on disk still match it — "
            "same usernames, same passwords, fresh data. The .onion is not restored "
            "(its key volume was removed).",
            tuple(warn), vol_text)
    return RestorePlan(
        MODE_RESEED,
        "Restore (reseed): the data volumes are gone, no credential files were "
        "saved with this record, and the files on disk have changed since — same "
        "usernames, passwords from the CURRENT files (not this mesh's), fresh data. "
        "The .onion is not restored (its key volume was removed).",
        tuple(warn), vol_text)


def restore_env(rec: SavedMesh) -> dict[str, str]:
    """The env a restore's SEED runs with, from the record's pointers.

    Env only — never argv, never a log line. ``E2E_CREDENTIALS_FILE`` points the
    seeder at the saved copy (so the same password file is used instead of a fresh
    mint), and the superadmin username/password ride the two names ``seed-e2e.sh``
    resolves. Returns only the username when nothing was copied: the caller then
    seeds with what is on disk and the plan already said what that means.
    """
    env: dict[str, str] = {}
    e2e = (rec.credentials or {}).get("e2e_file") or {}
    e2e_copy = _copy_path(e2e) if e2e.get("copied") else None
    if e2e_copy:
        env["E2E_CREDENTIALS_FILE"] = e2e_copy
    user = str((rec.credentials or {}).get("superadmin_username") or "")
    if user:
        env["CASDOOR_SUPERADMIN_USERNAME"] = user
    pw = _saved_superadmin_password(rec)
    if pw:
        env["E2E_SUPERADMIN_PASSWORD"] = pw
    return env


def _saved_superadmin_password(rec: SavedMesh) -> str:
    """Read the minted superadmin password OUT OF THE SAVED COPY of secrets.json —
    never out of the record, which has never held it. Returns "" when no copy was
    made, which is exactly the case whose consequence the plan already states."""
    entry = (rec.credentials or {}).get("secrets_json") or {}
    path = _copy_path(entry) if entry.get("copied") else None
    if not path:
        return ""
    brand = str((rec.config or {}).get("brand") or "hugmesh")
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        sa = (data.get(f"{brand}-pki") or {}).get("casdoor-superadmin") or {}
        return str(sa.get("password") or "")
    except (OSError, ValueError, AttributeError):
        return ""


def _write_private_copy(src: str, target: str) -> bool:
    """Copy ``src`` to ``target`` so the new file is 0600 from its FIRST byte: written
    through an ``O_EXCL`` 0600 temp file in the target's own dir, then ``os.replace``d.
    ``copyfile`` + ``chmod`` created a fresh target at ``0666 & ~umask`` (0644 under
    umask 022) until the chmod (#363); ``tests/stack/e2e-password.sh`` does it this way."""
    tmp = f"{target}.{os.getpid()}.tmp"
    try:
        os.makedirs(os.path.dirname(target), exist_ok=True)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(fd, "wb") as out, open(src, "rb") as inp:
                shutil.copyfileobj(inp, out)
        except BaseException:
            try:
                os.remove(tmp)
            except OSError:
                pass
            raise
        os.chmod(tmp, 0o600)            # an O_CREAT mode is masked by umask; pin it
        os.replace(tmp, target)
        return True
    except OSError:
        try:
            os.remove(tmp)
        except OSError:
            pass
        return False


def put_copies_back(rec: SavedMesh, *, e2e_target: str, secrets_target: str,
                    only_if_changed: bool = True) -> list[str]:
    """Copy the record's saved credential files back INTO PLACE (0600), returning
    the basenames it restored. ``only_if_changed`` skips a target whose sha256
    already equals the saved one, so a no-op restore rewrites nothing.

    Why in place and not just ``E2E_CREDENTIALS_FILE``: every LATER seed from the
    page — "Add user…", a re-run of the seeder — reads ``<repo>/.e2e-credentials``,
    and ``superadmin_login()`` reads ``keys-out/vault/secrets.json``. Pointing one
    seed at the copy while the in-place file still holds another mesh's password is
    how the next seed mints a second password and every persona 401s
    (``seed-e2e.sh`` leg 1c, exit 3).
    """
    restored: list[str] = []
    for key, target in (("e2e_file", e2e_target), ("secrets_json", secrets_target)):
        entry = (rec.credentials or {}).get(key) or {}
        src = _copy_path(entry) if entry.get("copied") else None
        if not src or not os.path.isfile(src):
            continue
        if only_if_changed and _sha256(target) == _sha256(src):
            continue
        if _write_private_copy(src, target):
            restored.append(os.path.basename(target))
    return restored


# ── Qt-free CLI face ───────────────────────────────────────────────────────────
# The same posture as core/emulation_save.py's: whatever the GUI can do here, a
# terminal can do too, over the same objects — so the record format is never a
# GUI-only artifact that only one surface can read.
def _print_record(rec: SavedMesh) -> None:
    print(f"{rec.id}  {rec.label}")
    print(f"  saved:      {rec.created} on {rec.hostname}")
    print(f"  generator:  {rec.generator_dir} @ {rec.generator_head[:12] or '?'}")
    print(f"  env/brand:  {rec.brand_text()}")
    print(f"  services:   {rec.services_text()}")
    print(f"  volumes:    {rec.volume_count()} inventoried, included="
          f"{rec.volumes.get('included')!r}")
    print(f"  doors:      {rec.doors.get('web_url') or '?'}")
    creds = rec.credentials or {}
    copied = [k for k in ("e2e_file", "secrets_json")
              if (creds.get(k) or {}).get("copied")]
    print("  creds:      pointers only"
          + (f"; copies: {', '.join(copied)}" if copied else "; no copies"))


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="python -m hugmesh_studio.core.saved_meshes",
        description=("List, show and delete the Studio's SAVED local-mesh records "
                     "(<state>/meshes/<id>.json). Records hold a mesh's identity, "
                     "config, source HEADs and a volume INVENTORY — never volume "
                     "CONTENTS and never a password. Saving and restoring live in "
                     "core/local_mesh_bootstrap.py (mesh-save / mesh-restore)."))
    p.add_argument("subcommand", choices=("list", "show", "delete"))
    p.add_argument("mesh_id", nargs="?", default="",
                   help="the record id (show/delete)")
    p.add_argument("--keep-copies", action="store_true",
                   help="delete: keep the record's credential-copy dir")
    args = p.parse_args(argv)

    recs, unreadable = scan()
    if args.subcommand == "list":
        for r in recs:
            _print_record(r)
        for u in unreadable:
            print(f"UNREADABLE {u}", file=sys.stderr)
        if not recs and not unreadable:
            print(f"no saved meshes under {meshes_dir()}")
        return 0

    if not args.mesh_id:
        print("a record id is required", file=sys.stderr)
        return 2
    match = [r for r in recs if r.id == args.mesh_id]
    if not match:
        print(f"no saved mesh with id {args.mesh_id}", file=sys.stderr)
        return 1
    rec = match[0]
    if args.subcommand == "show":
        print(json.dumps(rec.to_dict(), indent=2))
        return 0
    delete(rec, remove_copies=not args.keep_copies)
    print(f"deleted {rec.id} (the running mesh, its volumes and keys-out/ are "
          f"untouched)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

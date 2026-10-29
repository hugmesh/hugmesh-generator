"""A folder per DOMAIN holding a git copy of each app that domain has — the Qt-free half
of the "Copies for this domain" part of the Code folders block.

The operator's asks, verbatim (2026-10-21):

    "Make sure the clones repos for each subfolder for each domain have folder and repo
     names that reflect the domain they are apps for. Make sure that any services a
     domain shouldn't have doesn't have those folders cloned."

WHAT THIS IS, AND WHAT IT IS NOT. The mesh BUILD reads one flat tree (``.stack-src`` or
the operator's own tree, ``core.code_folders``): compose has one ``context:`` per app
and one image per app serves every domain, so that tree cannot be split per domain.
The copies here are a SECOND tree, for working on one domain's apps:

    <state dir>/domain-code/<mesh>/<domain>/<app>.<domain>/

* ``<domain>`` is :func:`safe_folder_name` of the domain name (no ``/``, no ``..``,
  nothing outside ``[a-z0-9.-]``), and a copy's folder carries the domain again, so a
  path pasted anywhere still says which domain it is for.
* Each copy is a ``git clone`` of the build checkout (no network, no credentials, the
  exact commit the mesh compiles). Its git remote is named for the DOMAIN, not
  ``origin`` (``git push chat.example.org domain/chat.example.org`` reads as what it
  does; the remote's URL is still that build checkout); the local branch is
  ``domain/<domain>``, ``.git/description`` says "<app> for <domain>", and ``git
  config hugmesh.domain`` / ``hugmesh.app`` / ``hugmesh.mesh`` / ``hugmesh.remote``
  carry the same facts for scripts.
* A marker file, ``.git/hugmesh-workspace.json``, is written LAST. Only a folder with
  the marker is ever treated as one of ours: a folder without it is reported as "not
  made by the Studio" and is never offered for removal.
* Edits in a copy do NOT reach the mesh until they are in the build tree (push them,
  or pull them into the build checkout). Every screen says so.

WHICH APPS. Exactly the rows ``code_folders.code_folder_map`` lists for the domain that
are a ``hugmesh-<name>`` checkout (``KIND_REPO``): the platform apps every domain runs
plus the domain's chosen services, and NOT the apps of a service the domain did not
choose (``code_folders.service_owners``). A folder outside the source root (games, tor)
and a stock image get no copy.

EXTRA FOLDERS. A copy of ours whose app the domain no longer has (a service was
un-ticked), and the folder of a domain that is no longer in the mesh, are EXTRA. They
are listed, never removed silently: the screen arms a removal on a first click and acts
on a second, and :func:`remove_extra` re-checks every condition at that moment and
refuses a copy that is not still a plain clone (:func:`extra_status`: changed, untracked
or ignored files, commits on any branch or tag, commits the build checkout does not
have NOW, stashes, linked working trees, and its own git hooks or settings).

SHARED COPIES FOLDER. The ``<mesh>`` folder is the mesh's own domain name, and every
test mesh has the same one, so meshes share it. A copy this mesh does not need but a
SAVED mesh still has (:func:`saved_mesh_claims`) is CLAIMED, listed with that mesh's
name, and never extra. A mesh that was never saved cannot be known about
(:data:`SHARED_ROOT_NOTE` says so on every screen that lists another mesh's folders).

SAFETY. No path is followed through a symbolic link: :func:`safe_folder_name` makes
names that cannot climb, every folder between the workspace root and a copy is checked
with ``lstat`` before anything is created or removed, a copy is never made inside a
``.stack-src`` or inside its own source, and ``shutil.rmtree`` (which does not follow
links inside the tree) only ever runs on a real, marked folder directly inside its
domain folder.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
from dataclasses import dataclass
from typing import Callable, Optional

from . import code_folders as cf
from .local_agent import GitRunner, _run_git
from .state_paths import state_dir

__all__ = [
    "MARKER", "WORKSPACE_DIR", "EDITS_NOTE", "WorkspaceRepo", "ExtraFolder",
    "DomainWorkspace", "WorkspacePlan", "ExtraStatus", "CloneResult", "RemoveResult",
    "safe_folder_name", "copy_folder_name", "workspace_root", "plan_workspaces",
    "clone_repo", "clone_missing", "extra_status", "remove_extra", "read_marker",
    "saved_mesh_claims", "same_mesh_ids", "superseded_ids", "remote_name",
    "older_remote_copies", "git_settings",
    "SHARED_ROOT_NOTE",
]

#: The marker file inside a copy's ``.git`` folder (so ``git status`` never sees it).
MARKER = "hugmesh-workspace.json"
#: Under the Studio's state dir, beside ``agent-work`` (core/local_agent.py).
WORKSPACE_DIR = "domain-code"
#: The one sentence every screen shows about what a copy is for.
EDITS_NOTE = ("These copies are for working on each domain's apps. The mesh is still "
              "built from the source root above: an edit made in a copy reaches the "
              "mesh only once it is in that tree (push it, or pull it there).")

#: Said wherever a folder that is not this mesh's is listed (the copies folder is keyed
#: on the mesh's own domain name, which every test mesh shares).
SHARED_ROOT_NOTE = ("Every mesh with this own domain name shares this copies folder. "
                    "Copies a saved mesh still uses are kept and never offered for "
                    "removal; a mesh that was never saved cannot be checked, so save a "
                    "mesh before you remove another one's folders.")

_MAX_NAME = 100


# ── names ────────────────────────────────────────────────────────────────────────
def safe_folder_name(name: str) -> str:
    """A domain (or mesh) name as ONE safe folder name, or "" when nothing usable is
    left. Lower case; anything outside ``[a-z0-9.-]`` becomes ``-`` (so ``/``, ``\\``,
    spaces and NULs cannot survive); runs of dots collapse to one (so ``..`` cannot
    survive); no leading or trailing dot or dash (no hidden folder, no option-looking
    name); at most 100 characters; and never ending in ``.lock`` (git refuses a branch
    named that, and the branch is ``domain/<this>``)."""
    s = (name or "").strip().lower()
    s = re.sub(r"[^a-z0-9.-]+", "-", s)
    s = re.sub(r"\.{2,}", ".", s)
    s = re.sub(r"-{2,}", "-", s)
    s = s.strip(".-")[:_MAX_NAME].strip(".-")
    if s.endswith(".lock"):
        s = s[: -len(".lock")] + "-lock"
    return "" if s in ("", ".", "..") else s


def copy_folder_name(app: str, domain_slug: str) -> str:
    """``hugmesh-user-ui`` + ``chat.example.org`` -> ``hugmesh-user-ui.chat.example.org``
    — the app first (it sorts and reads as "this app, for that domain")."""
    return f"{app}.{domain_slug}"


def remote_name(domain_slug: str) -> str:
    """The git remote a domain's copy names its build checkout by: the domain's own
    folder name (``chat.example.org``). :func:`safe_folder_name` already makes it a
    legal remote name: only ``[a-z0-9.-]``, no ``..``, no leading dot or dash, never
    ending in ``.lock``."""
    return domain_slug


def older_remote_copies(ws: "DomainWorkspace") -> "list[tuple[str, str]]":
    """``[(app, remote), ...]`` for the made copies of ``ws`` whose build-checkout
    remote is NOT the domain's name (:func:`remote_name`) — made before that rule, so
    ``git push <domain>`` does not work there and every screen must say which name
    does."""
    want = remote_name(ws.slug)
    return [(repo.app, repo.remote) for repo in ws.cloned()
            if repo.remote and repo.remote != want]


def workspace_root(mesh: str, state_root: Optional[str] = None) -> str:
    """``<state dir>/domain-code/<mesh>``: under the Studio's state, never /tmp and never
    inside a ``.stack-src`` (which ``make stack-clone`` git-resets)."""
    return os.path.join(state_root or state_dir(), WORKSPACE_DIR,
                        safe_folder_name(mesh) or "mesh")


# ── the plan (read-only, no subprocess: refresh calls it on every change) ─────────
@dataclass(frozen=True)
class WorkspaceRepo:
    """One app of one domain, and its copy."""
    app: str
    folder_name: str
    dest: str
    source: str
    source_exists: bool
    #: the copy is there and carries our marker for this domain and app
    cloned: bool
    #: why a copy cannot be made now ("" = it can, or it is already made)
    reason: str
    reasons: tuple[str, ...] = ()
    #: a made copy's name for its build checkout, from its marker (``origin`` for a
    #: copy made before the remote was named for the domain); "" when not made
    remote: str = ""

    @property
    def can_clone(self) -> bool:
        return not self.cloned and not self.reason


@dataclass(frozen=True)
class ExtraFolder:
    """A copy of ours that this domain no longer needs."""
    path: str
    app: str
    domain: str
    why: str


@dataclass(frozen=True)
class DomainWorkspace:
    name: str
    slug: str
    folder: str
    #: why this domain gets no folder at all ("" = it does)
    problem: str
    repos: tuple[WorkspaceRepo, ...]
    extras: tuple[ExtraFolder, ...]
    #: folders in the domain folder that the Studio did not make — never touched
    foreign: tuple[str, ...]
    #: False for the folder of a domain that is no longer in the mesh
    in_mesh: bool = True
    #: copies this mesh does not need but a SAVED mesh still does (same copies folder):
    #: listed, never offered for removal
    claimed: tuple[ExtraFolder, ...] = ()

    def missing(self) -> tuple[WorkspaceRepo, ...]:
        return tuple(r for r in self.repos if r.can_clone)

    def cloned(self) -> tuple[WorkspaceRepo, ...]:
        return tuple(r for r in self.repos if r.cloned)


@dataclass(frozen=True)
class WorkspacePlan:
    mesh: str
    root: str
    #: why no copy can be made anywhere ("" = the root is usable)
    root_problem: str
    domains: tuple[DomainWorkspace, ...]

    def extras(self) -> tuple[ExtraFolder, ...]:
        return tuple(x for d in self.domains for x in d.extras)


def _is_link(path: str) -> bool:
    try:
        return os.path.islink(path)
    except OSError:
        return False


def _links_below(root: str, path: str) -> str:
    """The first component from ``root`` (inclusive) down to ``path`` that is a symbolic
    link, or "" when there is none. ``root``'s own parents (the state dir may live
    behind a link on purpose) are not judged."""
    root = os.path.abspath(root)
    path = os.path.abspath(path)
    if path != root and not path.startswith(root + os.sep):
        return path
    cur = root
    if _is_link(cur):
        return cur
    rel = os.path.relpath(path, root)
    if rel == ".":
        return ""
    for part in rel.split(os.sep):
        cur = os.path.join(cur, part)
        if _is_link(cur):
            return cur
    return ""


def read_marker(folder: str) -> "dict | None":
    """The marker of a copy, or None. Nothing is followed through a link: the folder,
    its ``.git`` and the marker itself must all be real."""
    git_dir = os.path.join(folder, ".git")
    marker = os.path.join(git_dir, MARKER)
    if _is_link(folder) or _is_link(git_dir) or _is_link(marker):
        return None
    if not os.path.isdir(git_dir) or not os.path.isfile(marker):
        return None
    try:
        with open(marker, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or not all(
            isinstance(data.get(k), str) and data.get(k) for k in ("domain", "slug", "app")):
        return None
    return data


def _scan(folder: str) -> "list[tuple[str, str, dict | None]]":
    """``(entry name, path, marker)`` for every entry of a domain folder, without
    following a link. A link or a plain file is listed with marker None."""
    out = []
    try:
        with os.scandir(folder) as it:
            for entry in it:
                try:
                    real_dir = entry.is_dir(follow_symlinks=False)
                except OSError:
                    real_dir = False
                marker = read_marker(entry.path) if real_dir else None
                out.append((entry.name, entry.path, marker))
    except OSError:
        return []
    return sorted(out)


def saved_mesh_claims(generator_dir: str, *, state_root: Optional[str] = None,
                      exclude_record_id: str = "", environ=None
                      ) -> "dict[tuple[str, str], str]":
    """``{(domain folder name, app): saved mesh label}`` for every app a SAVED mesh
    (``<state dir>/meshes/*.json``, core/saved_meshes.py) still has on one of its
    domains. Read-only, never raises.

    Why: the copies folder is keyed on the mesh's own domain name, and every test mesh
    is called the same (``hugmesh.net``), so several meshes share one copies folder. A
    domain or a service that is gone from THIS mesh may still belong to another saved
    mesh; its copies are then not extra. ``exclude_record_id`` is the record the form
    was loaded from (its stale copy must not keep what the person just un-ticked). A
    mesh that was never saved cannot be known about; every screen says so.

    The OLDER records of that same mesh are left out too: every record lists the
    records it was saved after (``SavedMesh.follows``, core/saved_meshes.py), so two
    saves of one mesh do not leave the first one keeping copies the second dropped.
    A NEWER record saved from the same line still claims (it may be the state the
    person goes back to).

    A record that a later save of its mesh lists (:func:`superseded_ids`) claims
    nothing either, whatever the form holds: after a restart, or on the text
    interface (which loads no record), the first of two saves would otherwise keep
    the copies the second save dropped. Releasing only makes a copy EXTRA; it is still
    removed only on a second click, and only when it is a plain copy."""
    from . import saved_meshes
    from .local_mesh_bootstrap import DEFAULT_DOMAIN
    meshes = os.path.join(state_root or state_dir(), "meshes")
    out: dict[tuple[str, str], str] = {}
    try:
        names = sorted(os.listdir(meshes))
    except OSError:
        return out
    records = []
    for fname in names:
        if not fname.endswith(".json") or _is_link(os.path.join(meshes, fname)):
            continue
        try:
            records.append(saved_meshes.load(os.path.join(meshes, fname)))
        except Exception:                        # noqa: BLE001 — an unreadable record claims nothing
            continue
    skip = same_mesh_ids(records, exclude_record_id) | superseded_ids(records)
    for rec in records:
        if rec.id in skip:
            continue
        cfg = rec.config if isinstance(rec.config, dict) else {}
        rows = [r for r in (cfg.get("domains") or ()) if isinstance(r, dict)
                and isinstance(r.get("name"), str) and r.get("name").strip()]
        own = str(cfg.get("cluster_domain") or "").strip() or DEFAULT_DOMAIN
        if not any(r["name"].strip() == own for r in rows):
            rows.insert(0, {"name": own, "optional_services": [], "idp": ""})
        try:
            m = cf.code_folder_map(generator_dir, "clone", "", rows, environ=environ)
        except Exception:                        # noqa: BLE001
            continue
        label = rec.label or rec.id
        for dom in m.domains:
            slug = safe_folder_name(dom.name)
            for app in dom.apps:
                if slug and app.kind == cf.KIND_REPO:
                    out.setdefault((slug, app.name), label)
    return out


def superseded_ids(records) -> "set[str]":
    """The ids of records a later save of the same mesh lists in its ``follows``:
    older states of a mesh that was saved again. A record never supersedes itself."""
    out: set = set()
    for rec in records:
        own = getattr(rec, "id", "")
        for value in (getattr(rec, "follows", None) or ()):
            if isinstance(value, str) and value and value != own:
                out.add(value)
    return out


def same_mesh_ids(records, record_id: str) -> "set[str]":
    """``record_id`` and every EARLIER record of the same mesh: its ``follows`` line,
    and the lines of those records in turn (a record deleted from the middle of a
    line does not cut off the ones before it, since each record lists all of them).
    Empty when ``record_id`` is ""."""
    if not record_id:
        return set()
    by_id = {getattr(r, "id", ""): r for r in records}
    out, todo = set(), [record_id]
    while todo and len(out) < 1000:
        cur = todo.pop()
        if not isinstance(cur, str) or not cur or cur in out:
            continue
        out.add(cur)
        rec = by_id.get(cur)
        todo.extend(v for v in (getattr(rec, "follows", None) or ())
                    if isinstance(v, str))
    return out


def plan_workspaces(generator_dir: str, source_mode: str, source_dir: str, domains,
                    mesh: str, *, state_root: Optional[str] = None,
                    environ=None, folder_map: "cf.CodeFolderMap | None" = None,
                    record_id: str = "",
                    claims: "dict[tuple[str, str], str] | None" = None
                    ) -> WorkspacePlan:
    """The whole picture, read-only: for every domain row, the copies it should have,
    which exist, which cannot be made and why, and what is EXTRA. ``folder_map`` is the
    code-folder map for the same inputs when the caller already has it.

    A copy this mesh does not need is EXTRA only when no saved mesh still has that app
    on that domain (:func:`saved_mesh_claims`, read only when there is such a copy);
    otherwise it is CLAIMED and never offered for removal. ``record_id`` is the saved
    record this mesh was loaded from (left out of the claims); ``claims`` replaces the
    saved-mesh read (tests)."""
    root = workspace_root(mesh, state_root)
    _claims: "list[dict[tuple[str, str], str]]" = [claims] if claims is not None else []

    def claimed_by(slug: str, app: str) -> str:
        if not _claims:
            _claims.append(saved_mesh_claims(generator_dir, state_root=state_root,
                                             exclude_record_id=record_id,
                                             environ=environ))
        return _claims[0].get((slug, app), "")

    m = folder_map or cf.code_folder_map(generator_dir, source_mode, source_dir,
                                         domains, environ=environ)
    root_problem = ""
    # ``domain-code`` and ``<mesh>`` must be real folders; the state dir above them may
    # be a link on purpose and is not judged.
    link = next((p for p in (os.path.dirname(root), root) if _is_link(p)), "")
    if link:
        root_problem = (f"{link} is a link; the Studio does not make or remove copies "
                        "through a link.")
    elif os.path.lexists(root) and not os.path.isdir(root):
        root_problem = f"{root} is a file, not a folder."

    out: list[DomainWorkspace] = []
    seen_slugs: dict[str, str] = {}
    for dom in m.domains:
        slug = safe_folder_name(dom.name)
        folder = os.path.join(root, slug) if slug else ""
        problem = root_problem
        if not slug:
            problem = f"‘{dom.name}’ has no letters or digits to name a folder with."
        elif slug in seen_slugs:
            problem = (f"‘{dom.name}’ and ‘{seen_slugs[slug]}’ would share the folder "
                       f"{slug}; rename one of them.")
        else:
            seen_slugs[slug] = dom.name
        if not problem and folder and _links_below(root, folder):
            problem = f"{folder} is a link; the Studio does not work through a link."
        if not problem and folder and os.path.lexists(folder) and not os.path.isdir(folder):
            problem = f"{folder} is a file, not a folder."

        repos: list[WorkspaceRepo] = []
        wanted: set[str] = set()
        for app in dom.apps:
            if app.kind != cf.KIND_REPO or app.name in wanted:
                continue
            wanted.add(app.name)
            fname = copy_folder_name(app.name, slug) if slug else ""
            dest = os.path.join(folder, fname) if folder else ""
            marker = read_marker(dest) if dest and not problem else None
            cloned = bool(marker and marker.get("slug") == slug
                          and marker.get("app") == app.name)
            reason = problem
            if not reason and not cloned:
                if not app.exists:
                    reason = ("the build checkout is not there yet: "
                              + (app.missing_reason or "nothing to copy from"))
                elif dest and os.path.lexists(dest):
                    reason = (f"{dest} already exists and was not made by the Studio; "
                              "move it away to make a fresh copy")
            remote = ""
            if cloned:
                got = marker.get("remote")
                remote = got if isinstance(got, str) and got else "origin"
            repos.append(WorkspaceRepo(app.name, fname, dest, app.path, bool(app.exists),
                                       cloned, reason, app.reasons, remote))

        extras: list[ExtraFolder] = []
        claimed: list[ExtraFolder] = []
        foreign: list[str] = []
        if folder and not problem and os.path.isdir(folder):
            for entry, path, marker in _scan(folder):
                if marker is None:
                    foreign.append(path)
                    continue
                if marker.get("slug") != slug:
                    foreign.append(path)
                    continue
                if marker["app"] in wanted and entry == copy_folder_name(marker["app"], slug):
                    continue
                if marker["app"] not in wanted:
                    owner = claimed_by(slug, marker["app"])
                    if owner and entry == copy_folder_name(marker["app"], slug):
                        claimed.append(ExtraFolder(
                            path, marker["app"], dom.name,
                            f"the saved mesh ‘{owner}’ still uses it"))
                        continue
                why = ("this domain no longer has " + marker["app"]
                       if marker["app"] not in wanted else
                       "a second copy of " + marker["app"])
                extras.append(ExtraFolder(path, marker["app"], dom.name, why))
        out.append(DomainWorkspace(dom.name, slug, folder, problem, tuple(repos),
                                   tuple(extras), tuple(foreign),
                                   claimed=tuple(claimed)))

    # Folders of domains that are no longer in the mesh: every marked copy is extra.
    if not root_problem and os.path.isdir(root) and not _is_link(root):
        for entry, path, _marker in _scan(root):
            if entry in seen_slugs or _is_link(path) or not os.path.isdir(path):
                continue
            extras = []
            claimed = []
            foreign = []
            for sub_entry, sub, marker in _scan(path):
                if marker is not None and marker.get("slug") == entry:
                    owner = claimed_by(entry, marker["app"])
                    if owner and sub_entry == copy_folder_name(marker["app"], entry):
                        claimed.append(ExtraFolder(
                            sub, marker["app"], marker["domain"],
                            f"the saved mesh ‘{owner}’ still uses it"))
                        continue
                    extras.append(ExtraFolder(
                        sub, marker["app"], marker["domain"],
                        f"{marker['domain']} is not a domain of this mesh, and no saved "
                        "mesh uses this copy"))
                else:
                    foreign.append(sub)
            if extras or foreign or claimed:
                name = (extras or claimed)[0].domain if (extras or claimed) else entry
                out.append(DomainWorkspace(name, entry, path, "", (), tuple(extras),
                                           tuple(foreign), in_mesh=False,
                                           claimed=tuple(claimed)))
    return WorkspacePlan(mesh, root, root_problem, tuple(out))


# ── making a copy ────────────────────────────────────────────────────────────────
@dataclass(frozen=True)
class CloneResult:
    app: str
    dest: str
    ok: bool
    message: str


def _refuse(repo: WorkspaceRepo, root: str) -> str:
    """Every reason not to clone, checked at the moment of cloning (the plan may be
    minutes old)."""
    if repo.cloned:
        return "already copied"
    if repo.reason:
        return repo.reason
    if not repo.dest or not repo.source:
        return "nothing to copy"
    if not os.path.isdir(repo.source):
        return f"{repo.source} is not there"
    link = _links_below(root, os.path.dirname(repo.dest))
    if link:
        return f"{link} is a link; nothing is made through a link"
    if os.path.lexists(repo.dest):
        return f"{repo.dest} already exists; nothing was changed"
    real_src = os.path.realpath(repo.source)
    real_dest = os.path.realpath(repo.dest)
    if real_dest == real_src or real_dest.startswith(real_src + os.sep):
        return "the copy would land inside its own source; nothing was made"
    if ".stack-src" in real_dest.split(os.sep):
        return "the copy would land inside a .stack-src, which make stack-clone resets"
    return ""


def clone_repo(repo: WorkspaceRepo, domain: DomainWorkspace, mesh: str, root: str,
               runner: Optional[GitRunner] = None) -> CloneResult:
    """``git clone`` the build checkout into the domain's folder, then name it for the
    domain: branch ``domain/<domain>``, ``.git/description``, ``hugmesh.*`` config, and
    the marker LAST (a copy whose naming failed has no marker, so it is never mistaken
    for a finished one and never offered for removal)."""
    run = runner or _run_git
    why = _refuse(repo, root)
    if why:
        return CloneResult(repo.app, repo.dest, False, why)
    try:
        os.makedirs(os.path.dirname(repo.dest), exist_ok=True)
    except OSError as exc:
        return CloneResult(repo.app, repo.dest, False, f"could not make the folder: {exc}")
    link = _links_below(root, os.path.dirname(repo.dest))
    if link:                                    # raced in between: refuse, make nothing
        return CloneResult(repo.app, repo.dest, False, f"{link} is a link")
    remote = remote_name(domain.slug)
    code, out = run(["clone", "--quiet", "--origin", remote, "--", repo.source,
                     repo.dest], None)
    if code != 0:
        return CloneResult(repo.app, repo.dest, False,
                           f"git clone failed: {out[-300:] or 'no output'}")
    for step in (["switch", "-c", f"domain/{domain.slug}"],
                 ["config", "hugmesh.domain", domain.name],
                 ["config", "hugmesh.app", repo.app],
                 ["config", "hugmesh.mesh", mesh],
                 ["config", "hugmesh.remote", remote]):
        code, out = run(step, repo.dest)
        if code != 0:
            return CloneResult(repo.app, repo.dest, False,
                               f"git {' '.join(step[:2])} failed in {repo.dest}: "
                               f"{out[-300:]}. The copy was left as it is, unmarked.")
    git_dir = os.path.join(repo.dest, ".git")
    if _is_link(git_dir) or not os.path.isdir(git_dir):
        return CloneResult(repo.app, repo.dest, False,
                           f"{repo.dest} has no .git folder of its own; left unmarked")
    try:
        with open(os.path.join(git_dir, "description"), "w", encoding="utf-8") as fh:
            fh.write(f"{repo.folder_name}: {repo.app} for the domain {domain.name} "
                     f"(mesh {mesh})\n")
    except OSError as exc:
        return CloneResult(repo.app, repo.dest, False, f"could not name the copy: {exc}")
    # What the copy's own git settings and hooks look like as made, so a later check
    # can tell a person's own hook or setting from what the clone wrote.
    settings, why = git_settings(repo.dest, run)
    if why:
        return CloneResult(repo.app, repo.dest, False,
                           f"{why} in {repo.dest}. The copy was left as it is, unmarked.")
    try:
        with open(os.path.join(git_dir, MARKER), "w", encoding="utf-8") as fh:
            json.dump({"domain": domain.name, "slug": domain.slug, "app": repo.app,
                       "mesh": mesh, "source": repo.source, "remote": remote,
                       "settings": settings}, fh, indent=1)
    except OSError as exc:
        return CloneResult(repo.app, repo.dest, False, f"could not name the copy: {exc}")
    return CloneResult(repo.app, repo.dest, True, f"copied to {repo.dest}")


def clone_missing(plan: WorkspacePlan, domain_name: str,
                  runner: Optional[GitRunner] = None,
                  progress: Optional[Callable[[int, int, str], None]] = None
                  ) -> "list[CloneResult]":
    """Clone every copy ``domain_name`` is missing, one after another."""
    dom = next((d for d in plan.domains if d.name == domain_name and d.in_mesh), None)
    if dom is None:
        return []
    todo = dom.missing()
    out = []
    for i, repo in enumerate(todo, 1):
        if progress:
            progress(i, len(todo), repo.app)
        out.append(clone_repo(repo, dom, plan.mesh, plan.root, runner))
    return out


# ── a copy's own git settings and hooks ───────────────────────────────────────────
#: The folders inside ``.git`` a person edits by hand: hooks (a pre-commit, a
#: commit-msg) and info (``info/exclude``, ``info/attributes``, a sparse-checkout list).
_SETTINGS_DIRS = ("hooks", "info")
#: Written by git itself (``update-server-info``), never by a person.
_SETTINGS_DERIVED = frozenset({"info/refs"})
_MAX_SETTINGS_FILES = 500


def _sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _settings_files(git_dir: str) -> "dict[str, str]":
    """``{path under .git: sha256}`` for every file under ``.git/hooks`` and
    ``.git/info``; a link is ``link:<target>`` and is never followed."""
    out: dict[str, str] = {}
    for sub in _SETTINGS_DIRS:
        top = os.path.join(git_dir, sub)
        if _is_link(top):
            try:
                out[sub] = "link:" + os.readlink(top)
            except OSError:
                out[sub] = "link:?"
            continue
        if not os.path.isdir(top):
            continue
        for dirpath, dirnames, filenames in os.walk(top):     # never follows a link
            for name in sorted(dirnames + filenames):
                full = os.path.join(dirpath, name)
                rel = os.path.relpath(full, git_dir).replace(os.sep, "/")
                if rel in _SETTINGS_DERIVED:
                    continue
                if _is_link(full):
                    try:
                        out[rel] = "link:" + os.readlink(full)
                    except OSError:
                        out[rel] = "link:?"
                elif os.path.isfile(full):
                    try:
                        out[rel] = _sha256(full)
                    except OSError:
                        out[rel] = "unreadable"
            if len(out) > _MAX_SETTINGS_FILES:
                return out
    return out


def _config_entries(path: str, run: GitRunner) -> "tuple[list[str] | None, str]":
    """The copy's OWN ``.git/config`` (``--local``: never the person's global one), one
    ``key\nvalue`` string per entry, sorted; None and why when git cannot list it."""
    code, out = run(["config", "--local", "--list", "--null"], path)
    if code != 0:
        return None, "git config --list failed"
    return sorted(e for e in out.split("\0") if e.strip()), ""


def git_settings(path: str, runner: Optional[GitRunner] = None
                 ) -> "tuple[dict, str]":
    """``({"config": [...], "files": {...}}, "")`` — a copy's own git settings and the
    files under its ``.git/hooks`` and ``.git/info``, as they are now — or
    ``({}, why)``. Recorded in the marker when the copy is made, compared before a
    removal is offered."""
    run = runner or _run_git
    entries, why = _config_entries(path, run)
    if entries is None:
        return {}, why
    return {"config": entries, "files": _settings_files(os.path.join(path, ".git"))}, ""


def _stock_entry(entry: str, remotes: "set[str]") -> bool:
    """For a copy made before settings were recorded: is this ``.git/config`` entry one
    a clone and the Studio write themselves?"""
    key = entry.split("\n", 1)[0].lower()
    if key.startswith(("core.", "extensions.", "hugmesh.")):
        return True
    m = re.fullmatch(r"remote\.(.+)\.(url|fetch)", key)
    if m:
        return m.group(1) in remotes
    m = re.fullmatch(r"branch\.(.+)\.(remote|merge)", key)
    return bool(m)


def _settings_changes(path: str, marker: "dict | None", run: GitRunner
                      ) -> "tuple[int, str]":
    """How many of the copy's own git settings, hooks and ``.git/info`` files differ
    from what was there when the Studio made it; ``(0, why)`` when it cannot tell."""
    entries, why = _config_entries(path, run)
    if entries is None:
        return 0, why
    files = _settings_files(os.path.join(path, ".git"))
    snap = (marker or {}).get("settings")
    if (isinstance(snap, dict) and isinstance(snap.get("config"), list)
            and isinstance(snap.get("files"), dict)):
        def by_key(items) -> "dict[str, list[str]]":
            out: dict[str, list[str]] = {}
            for e in items:
                if isinstance(e, str):
                    k, _, v = e.partition("\n")
                    out.setdefault(k.lower(), []).append(v)
            return out
        was, now = by_key(snap["config"]), by_key(entries)
        changed = sum(1 for k in set(was) | set(now) if was.get(k) != now.get(k))
        before = snap["files"]
        changed += sum(1 for k in set(before) | set(files)
                       if before.get(k) != files.get(k))
        return changed, ""
    # A copy made before its settings were recorded: anything a clone does not write
    # is the person's (a hook that is not a stock ``.sample``, a remote, a setting).
    remotes = {"origin", str((marker or {}).get("remote") or ""),
               str((marker or {}).get("slug") or "")} - {""}
    changed = sum(1 for e in entries if not _stock_entry(e, remotes))
    changed += sum(1 for rel, digest in files.items()
                   if rel.startswith("hooks/") and (not rel.endswith(".sample")
                                                    or digest.startswith("link:")))
    return changed, ""


def _not_in_build(path: str, source: str, run: GitRunner) -> "tuple[int, str]":
    """How many commits of the copy (every branch, tag and HEAD) the BUILD CHECKOUT it
    was made from does not have reachable from any of its refs NOW, or ``(0, why)``.

    The copy's own remote-tracking refs are not enough: work pushed to the build
    checkout and later lost there (a branch deleted, ``make stack-clone`` resetting
    it) still shows in the copy as pushed. A commit the build checkout no longer has
    at all counts as one (its history behind it is not counted)."""
    code, refs = run(["for-each-ref", "--format=%(objectname) %(*objectname)",
                      "refs/heads", "refs/tags"], path)
    if code != 0:
        return 0, "git for-each-ref failed"
    tips = {ln.split()[-1] for ln in refs.splitlines() if ln.split()}
    code, head = run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], path)
    if code == 0 and head.strip():
        tips.add(head.strip())
    tips = sorted(t for t in tips if re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", t))
    if not tips:
        return 0, ""
    if not source or _is_link(source) or not os.path.isdir(source):
        return 0, (f"the build checkout it was copied from ({source or 'not recorded'}) "
                   "is not there to compare with")
    code, count = run(["rev-list", "--count", *tips, "--not", "--all"], source)
    if code == 0 and count.strip().isdigit():
        return int(count.strip()), ""
    # Some tip is not in the build checkout at all: count those, and the rest as usual.
    present, missing = [], 0
    for tip in tips:
        c, _ = run(["cat-file", "-e", f"{tip}^{{commit}}"], source)
        if c == 0:
            present.append(tip)
        else:
            missing += 1
    if not present:
        return missing, ""
    code, count = run(["rev-list", "--count", *present, "--not", "--all"], source)
    if code != 0 or not count.strip().isdigit():
        return 0, "git rev-list failed in the build checkout"
    return missing + int(count.strip()), ""


# ── removing an extra copy ────────────────────────────────────────────────────────
@dataclass(frozen=True)
class ExtraStatus:
    """What removing a copy would lose, as git sees it. Every kind of local work keeps
    the copy: the Studio only ever removes a copy that is still a plain clone."""
    path: str
    #: files with uncommitted changes (tracked, or untracked and not ignored)
    dirty: int
    #: commits on ANY local branch, tag or HEAD that no remote of the copy has (work
    #: that exists nowhere else) — not only the checked-out branch; the stash's own
    #: commits are left out here and counted as ``stashed``
    unpushed: int
    error: str = ""
    #: entries in ``git stash list``
    stashed: int = 0
    #: ignored files or folders (a ``.env``, build output): not re-made by a clone
    ignored: int = 0
    #: other working trees (``git worktree add``) that live on this copy's ``.git``
    worktrees: int = 0
    #: tracked files git was told NOT to check for changes (``update-index
    #: --skip-worktree`` / ``--assume-unchanged``): an edit to one is invisible to
    #: ``git status``, so the copy cannot be shown to be plain
    hidden: int = 0
    #: commits the BUILD CHECKOUT it was copied from does not have now (pushed there
    #: once and since lost, or never pushed there)
    not_in_build: int = 0
    #: its own git settings, hooks or ``.git/info`` files that differ from what the
    #: Studio made (a pre-commit hook, an added remote, an ``info/exclude`` line)
    settings: int = 0

    @property
    def safe_to_remove(self) -> bool:
        return (not self.error and self.dirty == 0 and self.unpushed == 0
                and self.stashed == 0 and self.ignored == 0 and self.worktrees == 0
                and self.hidden == 0 and self.not_in_build == 0
                and self.settings == 0)

    def words(self) -> str:
        if self.error:
            return f"cannot be checked ({self.error}) — it will be kept"
        if not self.safe_to_remove:
            def n(count: int, one: str, many: str) -> str:
                return f"{count} {one if count == 1 else many}"
            bits = []
            if self.dirty:
                bits.append(n(self.dirty, "changed file", "changed files"))
            if self.unpushed:
                bits.append(n(self.unpushed, "commit", "commits")
                            + " found nowhere else (on any of its branches or tags)")
            if self.stashed:
                bits.append(n(self.stashed, "stashed change", "stashed changes"))
            if self.ignored:
                bits.append(n(self.ignored, "ignored file or folder",
                              "ignored files or folders")
                            + " (such as a .env or build output)")
            if self.worktrees:
                bits.append(n(self.worktrees, "other working tree", "other working trees")
                            + " made from it")
            if self.hidden:
                bits.append(n(self.hidden, "file", "files")
                            + " git is told not to check for changes (skip-worktree or "
                            "assume-unchanged)")
            if self.not_in_build:
                bits.append(n(self.not_in_build, "commit", "commits")
                            + " the build checkout it came from does not have now")
            if self.settings:
                bits.append(n(self.settings, "change", "changes")
                            + " to its own git hooks or settings (.git/hooks, "
                            ".git/config, .git/info)")
            return "holds " + ", ".join(bits) + " — it will be kept"
        return ("a plain copy: no edits, commits, stashes, ignored files, hooks or "
                "settings of its own, and the build checkout has every commit")


def extra_status(path: str, runner: Optional[GitRunner] = None) -> ExtraStatus:
    """What removing ``path`` would lose. Read-only. It looks at EVERYTHING a person can
    leave in a copy that a fresh clone would not bring back: changed and untracked files,
    ignored files (``status --ignored``: a ``.env`` is exactly the precious case),
    commits on every local branch and tag that no remote has (``rev-list --all --not
    --remotes`` without ``refs/stash``, not only HEAD), stash entries, and linked
    working trees. What it cannot see: a commit that NO ref points to any more (made on
    a detached HEAD and then left; only the reflog has it) — git warns about that when
    it happens. Files git was told not to check (skip-worktree, assume-unchanged) keep
    the copy too, since an edit to one cannot be seen.

    Two more checks look past what ``git status`` knows. Every commit of the copy must
    be reachable in the BUILD CHECKOUT it was made from as that checkout is NOW (the
    copy's remote-tracking refs can be stale: :func:`_not_in_build`). And its own git
    hooks, ``.git/config`` and ``.git/info`` files must be as the Studio made them
    (:func:`_settings_changes`, against the record in the marker); a person's
    pre-commit hook or an added remote keeps the copy."""
    run = runner or _run_git
    marker = read_marker(path)
    # ``--untracked-files=normal`` and ``--ignore-submodules=none`` on the command line
    # beat every config level: with ``status.showUntrackedFiles=no`` (the copy's own
    # config, or the person's global one) a brand-new file is otherwise invisible and
    # the copy would read "a plain copy" and be removed with it.
    code, porcelain = run(["status", "--porcelain", "--ignored", "--untracked-files=normal",
                           "--ignore-submodules=none"], path)
    if code != 0:
        return ExtraStatus(path, 0, 0, "git status failed")
    lines = [ln for ln in porcelain.splitlines() if ln.strip()]
    ignored = len([ln for ln in lines if ln.startswith("!!")])
    dirty = len(lines) - ignored
    code, count = run(["rev-list", "--count", "--exclude=refs/stash", "--all", "--not",
                       "--remotes"], path)
    if code != 0 or not count.strip().isdigit():
        return ExtraStatus(path, dirty, 0, "git rev-list failed", ignored=ignored)
    unpushed = int(count.strip())
    code, stashes = run(["stash", "list"], path)
    if code != 0:
        return ExtraStatus(path, dirty, unpushed, "git stash list failed", ignored=ignored)
    stashed = len([ln for ln in stashes.splitlines() if ln.strip()])
    code, trees = run(["worktree", "list", "--porcelain"], path)
    if code != 0:
        return ExtraStatus(path, dirty, unpushed, "git worktree list failed",
                           stashed=stashed, ignored=ignored)
    worktrees = max(0, len([ln for ln in trees.splitlines()
                            if ln.startswith("worktree ")]) - 1)
    # ``ls-files -v`` tags a skip-worktree file ``S`` and an assume-unchanged one with a
    # lower-case letter; ``git status`` never reports an edit to either.
    code, listing = run(["ls-files", "-v"], path)
    if code != 0:
        return ExtraStatus(path, dirty, unpushed, "git ls-files failed", stashed=stashed,
                           ignored=ignored, worktrees=worktrees)
    hidden = len([ln for ln in listing.splitlines()
                  if ln[:1] == "S" or (ln[:1].isalpha() and ln[:1].islower())])
    so_far = dict(stashed=stashed, ignored=ignored, worktrees=worktrees, hidden=hidden)
    settings, why = _settings_changes(path, marker, run)
    if why:
        return ExtraStatus(path, dirty, unpushed, why, **so_far)
    not_in_build, why = _not_in_build(path, str((marker or {}).get("source") or ""), run)
    if why:
        return ExtraStatus(path, dirty, unpushed, why, settings=settings, **so_far)
    return ExtraStatus(path, dirty, unpushed, not_in_build=not_in_build,
                       settings=settings, **so_far)


@dataclass(frozen=True)
class RemoveResult:
    path: str
    removed: bool
    message: str


def remove_extra(extra: ExtraFolder, plan: WorkspacePlan,
                 runner: Optional[GitRunner] = None) -> RemoveResult:
    """Remove ONE extra copy, re-checking everything first: it is still listed as extra
    in ``plan`` (re-planned by the caller just now), it is a real folder directly inside
    a real domain folder under the root, it still carries our marker for that domain,
    and it holds no edits or commits of its own."""
    path = extra.path
    listed = {x.path for x in plan.extras()}
    if path not in listed:
        return RemoveResult(path, False, "no longer an extra folder; kept")
    if plan.root_problem:
        return RemoveResult(path, False, plan.root_problem)
    if _is_link(path) or not os.path.isdir(path):
        return RemoveResult(path, False, "not a real folder; kept")
    link = _links_below(plan.root, path)
    if link:
        return RemoveResult(path, False, f"{link} is a link; kept")
    parent = os.path.dirname(os.path.abspath(path))
    if os.path.dirname(parent) != os.path.abspath(plan.root):
        return RemoveResult(path, False, "not directly inside a domain folder; kept")
    real_root = os.path.realpath(plan.root)
    if os.path.realpath(path) != os.path.join(real_root, os.path.basename(parent),
                                              os.path.basename(path)):
        return RemoveResult(path, False, "its real place is outside the copies folder; kept")
    marker = read_marker(path)
    if marker is None or marker.get("slug") != os.path.basename(parent):
        return RemoveResult(path, False, "not a copy the Studio made; kept")
    status = extra_status(path, runner)
    if not status.safe_to_remove:
        return RemoveResult(path, False, status.words())
    try:
        shutil.rmtree(path)
    except OSError as exc:
        return RemoveResult(path, False, f"could not remove it: {exc}")
    # An emptied folder of a domain that left the mesh goes too (never a folder with
    # anything else in it, and never through a link).
    try:
        if not os.listdir(parent) and not _is_link(parent):
            os.rmdir(parent)
    except OSError:
        pass
    return RemoveResult(path, True, "removed")


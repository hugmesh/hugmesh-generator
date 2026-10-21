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
  exact commit the mesh compiles). Its ``origin`` stays that build checkout, which is
  the honest name for where it came from; the local branch is ``domain/<domain>``,
  ``.git/description`` says "<app> for <domain>", and ``git config hugmesh.domain``
  / ``hugmesh.app`` / ``hugmesh.mesh`` carry the same facts for scripts.
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
refuses a copy that holds edits or commits the build checkout does not have.

SAFETY. No path is followed through a symbolic link: :func:`safe_folder_name` makes
names that cannot climb, every folder between the workspace root and a copy is checked
with ``lstat`` before anything is created or removed, a copy is never made inside a
``.stack-src`` or inside its own source, and ``shutil.rmtree`` (which does not follow
links inside the tree) only ever runs on a real, marked folder directly inside its
domain folder.
"""
from __future__ import annotations

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
]

#: The marker file inside a copy's ``.git`` folder (so ``git status`` never sees it).
MARKER = "hugmesh-workspace.json"
#: Under the Studio's state dir, beside ``agent-work`` (core/local_agent.py).
WORKSPACE_DIR = "domain-code"
#: The one sentence every screen shows about what a copy is for.
EDITS_NOTE = ("These copies are for working on each domain's apps. The mesh is still "
              "built from the source root above: an edit made in a copy reaches the "
              "mesh only once it is in that tree (push it, or pull it there).")

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


def plan_workspaces(generator_dir: str, source_mode: str, source_dir: str, domains,
                    mesh: str, *, state_root: Optional[str] = None,
                    environ=None, folder_map: "cf.CodeFolderMap | None" = None
                    ) -> WorkspacePlan:
    """The whole picture, read-only: for every domain row, the copies it should have,
    which exist, which cannot be made and why, and what is EXTRA. ``folder_map`` is the
    code-folder map for the same inputs when the caller already has it."""
    root = workspace_root(mesh, state_root)
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
            repos.append(WorkspaceRepo(app.name, fname, dest, app.path, bool(app.exists),
                                       cloned, reason, app.reasons))

        extras: list[ExtraFolder] = []
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
                why = ("this domain no longer has " + marker["app"]
                       if marker["app"] not in wanted else
                       "a second copy of " + marker["app"])
                extras.append(ExtraFolder(path, marker["app"], dom.name, why))
        out.append(DomainWorkspace(dom.name, slug, folder, problem, tuple(repos),
                                   tuple(extras), tuple(foreign)))

    # Folders of domains that are no longer in the mesh: every marked copy is extra.
    if not root_problem and os.path.isdir(root) and not _is_link(root):
        for entry, path, _marker in _scan(root):
            if entry in seen_slugs or _is_link(path) or not os.path.isdir(path):
                continue
            extras = []
            foreign = []
            for _e, sub, marker in _scan(path):
                if marker is not None and marker.get("slug") == entry:
                    extras.append(ExtraFolder(sub, marker["app"], marker["domain"],
                                              f"{marker['domain']} is no longer a domain "
                                              "of this mesh"))
                else:
                    foreign.append(sub)
            if extras or foreign:
                name = extras[0].domain if extras else entry
                out.append(DomainWorkspace(name, entry, path, "", (), tuple(extras),
                                           tuple(foreign), in_mesh=False))
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
    code, out = run(["clone", "--quiet", "--", repo.source, repo.dest], None)
    if code != 0:
        return CloneResult(repo.app, repo.dest, False,
                           f"git clone failed: {out[-300:] or 'no output'}")
    for step in (["switch", "-c", f"domain/{domain.slug}"],
                 ["config", "hugmesh.domain", domain.name],
                 ["config", "hugmesh.app", repo.app],
                 ["config", "hugmesh.mesh", mesh]):
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
        with open(os.path.join(git_dir, MARKER), "w", encoding="utf-8") as fh:
            json.dump({"domain": domain.name, "slug": domain.slug, "app": repo.app,
                       "mesh": mesh, "source": repo.source}, fh, indent=1)
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


# ── removing an extra copy ────────────────────────────────────────────────────────
@dataclass(frozen=True)
class ExtraStatus:
    path: str
    #: files with uncommitted changes (tracked or untracked)
    dirty: int
    #: commits no remote of the copy has (work that exists nowhere else)
    unpushed: int
    error: str = ""

    @property
    def safe_to_remove(self) -> bool:
        return not self.error and self.dirty == 0 and self.unpushed == 0

    def words(self) -> str:
        if self.error:
            return f"cannot be checked ({self.error}) — it will be kept"
        if self.dirty or self.unpushed:
            bits = []
            if self.dirty:
                bits.append(f"{self.dirty} changed file{'s' if self.dirty != 1 else ''}")
            if self.unpushed:
                bits.append(f"{self.unpushed} commit{'s' if self.unpushed != 1 else ''} "
                            "found nowhere else")
            return "holds " + " and ".join(bits) + " — it will be kept"
        return "no edits of its own"


def extra_status(path: str, runner: Optional[GitRunner] = None) -> ExtraStatus:
    """What removing ``path`` would lose. Read-only."""
    run = runner or _run_git
    code, porcelain = run(["status", "--porcelain"], path)
    if code != 0:
        return ExtraStatus(path, 0, 0, "git status failed")
    dirty = len([ln for ln in porcelain.splitlines() if ln.strip()])
    code, count = run(["rev-list", "--count", "HEAD", "--not", "--remotes"], path)
    if code != 0 or not count.strip().isdigit():
        return ExtraStatus(path, dirty, 0, "git rev-list failed")
    return ExtraStatus(path, dirty, int(count.strip()))


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


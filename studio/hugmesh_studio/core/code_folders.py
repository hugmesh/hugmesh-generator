"""Which git checkout each app of a generated local mesh builds from — the Qt-free
half of the Studio's "Code folders" block (issue #689; the running-mesh monitor of
#651 reuses this map and :mod:`open_path`).

THE API, kept small on purpose:

    code_folder_map(generator_dir, source_mode, source_dir, domains) -> CodeFolderMap
    stack_services(generator_dir)                                   -> services parsed
    source_root(generator_dir, source_mode, source_dir)             -> the root folder

A ``CodeFolderMap`` is one ``DomainFolders`` per domain row, each a tuple of
``AppFolder`` rows (the folder, whether it exists, why not, the compose services
built from it, why it is on this domain) plus plain-words ``notes`` for the things
that have no folder. The GUI renders it; nothing here touches Qt or a subprocess.

WHAT "THE APPS OF A DOMAIN" MEANS IN THIS CODE, and where it comes from:

* A domain row (``core.config.Domain`` on ``LocalMeshDomains.domains``) carries a
  name, a sign-in choice and ``optional_services`` — slugs from
  ``domain_services.DOMAIN_CATALOGUE`` that the Domain services step recorded.
* The local Docker lane builds from ``tests/stack/compose.local.yaml`` and the
  overlay files it ``include:``s — ``$(STACK_COMPOSE)`` in the Makefile. Every
  first-party ``context: ${STACK_SRC:-…}/hugmesh-<name>`` there is a PLATFORM app:
  none of them carries a ``profiles:`` key, so compose builds and starts every one
  regardless of which domains exist, and the gateways serve every domain from the
  same images. Those rows are therefore listed under EVERY domain — EXCEPT the ones
  that belong to one per-domain service (:func:`service_owners`: the federation rows
  of owncast, tube and the two character apps, and the Matrix/Mastodon front ends of
  :data:`UI_OWNERS`). A domain that did not choose that service does not have that
  app, so it gets no row and no folder; one note names what was left out (operator
  ask 2026-10-21: "any services a domain shouldn't have doesn't have those folders").
* The per-domain COPIES (a folder per domain, a clone per app, named for the
  domain) are :mod:`core.domain_workspaces`, which reads this map.
* A SELECTED optional service adds what its mechanism names
  (``core.local_services.LOCAL_SERVICES`` — the same catalogue the Services step
  reads):
    - a compose-PROFILE slug owns the services tagged with that profile (phpbb's
      profile builds ``hugmesh-forum-api``; akkoma's and tuwunel's run stock images
      and get a note instead of a row);
    - a FEDERATION slug owns the always-built services named after its module
      (``hugmesh-owncast-ui``, ``hugmesh-owncast-bff-api``, ``owncast-bff-db`` for
      ``owncast``) — compose.local.yaml's naming rule, which a test pins for every
      federation slug so a renamed service cannot silently drop out;
    - a Kubernetes-lane slug builds nothing here and says so.
* The FOLDER is the one the build reads (``LocalStackNode._build_env``):
  ``<source dir>/hugmesh-<name>`` in ``existing`` mode, ``./.stack-src/hugmesh-<name>``
  in ``clone`` mode (``STACK_SRC ?= $(CURDIR)/.stack-src``). The repo name is parsed
  with the SAME regex ``expected_build_contexts`` uses, so this can never list a
  folder compose would not resolve.

No PyYAML: the Studio does not depend on it, and the compose files are read with a
line parser that only wants three keys per service (``profiles``, ``context``,
``image``). ``expected_build_contexts`` is the cross-check a test holds it to.
"""
from __future__ import annotations

import os
import re
from dataclasses import dataclass

from . import local_services
from .config import has_external_signin, runs_own_casdoor
from .domain_services import normalise_slugs
from .e2e_catalogue import STACK_SRC_DIR
# THE one parse of a build context (see expected_build_contexts) — reused, not
# restated, so the folder rows and the "N build contexts" count cannot disagree.
from .local_mesh_bootstrap import _CONTEXT_RE as STACK_SRC_CONTEXT_RE

__all__ = [
    "StackService", "AppFolder", "DomainFolders", "CodeFolderMap",
    "KIND_REPO", "KIND_PATH", "KIND_IMAGE", "REASON_PLATFORM",
    "CLONE_MODE_NOTICE", "EXISTING_MODE_NOTICE", "NOT_DOWNLOADED_REASON",
    "NO_SOURCE_DIR_REASON", "UI_OWNERS",
    "compose_files", "stack_services", "source_root", "code_folder_map",
    "service_owners",
]

#: Where the local stack's compose files live, relative to the generator checkout.
STACK_DIR = os.path.join("tests", "stack")
COMPOSE_LOCAL = "compose.local.yaml"

KIND_REPO = "repo"      # a hugmesh-<name> checkout under the source root
KIND_PATH = "path"      # a folder elsewhere: inside this repo (tor), or GAMES_SRC
KIND_IMAGE = "image"    # a stock image — nothing to open

REASON_PLATFORM = "platform"

#: Always-built front ends that serve ONE per-domain service although compose builds
#: them with no profile (so the federation naming rule cannot see them): the Matrix
#: and Mastodon web apps are the faces of the ``tuwunel`` slug's SOCIAL tier
#: (compose.social-profile.yaml: tuwunel + the full Mastodon set), and the Mastodon
#: one also speaks to ``akkoma``, which serves the same Mastodon client API. A domain
#: that chose none of a row's owners does not have that app, so it gets no folder.
#: A test pins every name here against the real compose files.
UI_OWNERS: dict[str, tuple[str, ...]] = {
    "hugmesh-matrix-ui": ("tuwunel",),
    "hugmesh-mastodon-ui": ("tuwunel", "akkoma"),
}

#: The clone-mode sentence. VERIFIED against scripts/clone-all-repos.sh (read
#: 2026-10-07): ``checkout_is_disposable`` counts ``rev-list origin/<ref>..HEAD`` —
#: "Only COMMITTED local work counts. Working-tree edits are deliberately NOT
#: counted" — then the update path runs ``git checkout --force <ref>`` and
#: ``git reset --hard origin/<ref>`` on every disposable checkout, and "Untracked
#: files survive a reset anyway". A checkout that is ahead is reported KEPT and
#: left alone. ``existing`` mode sets STACK_NO_CLONE=1, so the script never runs.
CLONE_MODE_NOTICE = (
    "Download mode: ‘Generate & start’ first runs `make stack-clone`, which fetches "
    "every checkout under .stack-src and git-resets it to origin/main — uncommitted "
    "edits to tracked files there are LOST. Only a checkout holding local commits is "
    "kept as it is (untracked files survive). To keep edits, choose ‘Build from a "
    "source tree I already have’: that mode never fetches, updates or resets your "
    "checkouts.")
EXISTING_MODE_NOTICE = (
    "Your own tree: nothing here is fetched, updated or git-reset, so edits in these "
    "folders are exactly what the next build compiles.")

NOT_DOWNLOADED_REASON = (
    "not downloaded yet: ‘Download the source’ happens when ‘Generate & start’ runs "
    "make stack-clone (or run `make stack-clone` in the hugmesh-generator checkout)")
NO_SOURCE_DIR_REASON = (
    "no source directory chosen yet: pick one under ‘Build from a source tree I "
    "already have’")


@dataclass(frozen=True)
class StackService:
    """One compose service as the stack files declare it: its profile tags (empty =
    always on), its build context (raw, "" for a stock image) and its image."""
    name: str
    profiles: tuple[str, ...] = ()
    context: str = ""
    image: str = ""
    files: tuple[str, ...] = ()


@dataclass(frozen=True)
class AppFolder:
    """One row of a domain: a folder (or, for ``KIND_IMAGE``, the fact that there is
    none). ``reasons`` says why it is on this domain — ``platform`` for the apps
    every domain runs, ``selected: <slug>`` for a per-domain choice; a row can carry
    both (owncast's containers are platform apps that a selection also names)."""
    name: str
    kind: str
    path: str
    exists: bool
    missing_reason: str
    services: tuple[str, ...]
    reasons: tuple[str, ...]
    image: str = ""

    @property
    def openable(self) -> bool:
        return self.kind != KIND_IMAGE and self.exists

    def why(self) -> str:
        """One line for a tooltip: the services and the reasons."""
        return ("built for: " + ", ".join(self.services)
                + " — on this domain because: " + ", ".join(self.reasons))


@dataclass(frozen=True)
class DomainFolders:
    name: str
    apps: tuple[AppFolder, ...]
    notes: tuple[str, ...] = ()

    def openable_paths(self) -> tuple[str, ...]:
        """Every existing folder of this domain ONCE, in row order — what "Open all"
        opens (hugmesh-gateway is one folder however many services build from it)."""
        out: list[str] = []
        for app in self.apps:
            if app.openable and app.path not in out:
                out.append(app.path)
        return tuple(out)


@dataclass(frozen=True)
class CodeFolderMap:
    source_mode: str
    root: str
    root_exists: bool
    root_reason: str
    notice: str
    domains: tuple[DomainFolders, ...]


# ── the compose files, read the way compose reads them ───────────────────────────
_INCLUDE_PATH_RE = re.compile(r"^\s+-\s+path:\s*['\"]?([^'\"#\s]+)")
_SERVICE_RE = re.compile(r"^  ([A-Za-z0-9][A-Za-z0-9_.-]*):\s*(?:#.*)?$")
_KEY_RE = re.compile(r"^(\s+)([A-Za-z_]+):\s*(.*?)\s*$")
_LIST_ITEM_RE = re.compile(r"^\s+-\s*(.*?)\s*$")
_VAR_DEFAULT_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}")


def _unquote(value: str) -> str:
    value = value.split(" #", 1)[0].strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def _inline_list(value: str) -> list[str]:
    """``["a", "b"]`` / ``[a, b]`` -> ["a", "b"]; anything else -> []."""
    value = value.strip()
    if not (value.startswith("[") and value.endswith("]")):
        return []
    return [_unquote(x) for x in value[1:-1].split(",") if _unquote(x)]


def compose_files(generator_dir: str) -> list[str]:
    """compose.local.yaml plus every file its top-level ``include:`` names, in that
    order — exactly the set `docker compose -f compose.local.yaml` loads. A named
    file that does not exist is skipped (compose would refuse to start; here the
    honest answer is simply fewer services)."""
    stack = os.path.join(generator_dir, STACK_DIR)
    main = os.path.join(stack, COMPOSE_LOCAL)
    out = [main]
    try:
        with open(main, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return []
    in_include = False
    for line in lines:
        if line.startswith("include:"):
            in_include = True
            continue
        if in_include:
            if line and not line[0].isspace():
                in_include = False
                continue
            m = _INCLUDE_PATH_RE.match(line)
            if m:
                path = os.path.join(stack, m.group(1))
                if os.path.isfile(path) and path not in out:
                    out.append(path)
    return out


def _parse_services(path: str) -> list[StackService]:
    """The services of ONE compose file. Only the ``services:`` block is read;
    ``x-`` extension blocks (anchors) and ``include:`` are skipped."""
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return []
    out: list[StackService] = []
    in_services = False
    name = ""
    profiles: list[str] = []
    context = image = ""
    collecting_profiles = False

    def flush() -> None:
        if name:
            out.append(StackService(name, tuple(profiles), context, image,
                                    (os.path.basename(path),)))

    for raw in lines:
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line[0].isspace():
            flush()
            name, profiles, context, image = "", [], "", ""
            in_services = line.startswith("services:")
            collecting_profiles = False
            continue
        if not in_services:
            continue
        m = _SERVICE_RE.match(line)
        if m:
            flush()
            name, profiles, context, image = m.group(1), [], "", ""
            collecting_profiles = False
            continue
        if collecting_profiles:
            item = _LIST_ITEM_RE.match(line)
            if item:
                if _unquote(item.group(1)):
                    profiles.append(_unquote(item.group(1)))
                continue
            collecting_profiles = False
        km = _KEY_RE.match(line)
        if not km or not name:
            continue
        key, value = km.group(2), km.group(3)
        if key == "profiles":
            inline = _inline_list(value)
            if inline:
                profiles.extend(inline)
            elif not _unquote(value):
                collecting_profiles = True
        elif key == "context":
            context = _unquote(value)
        elif key == "build" and _unquote(value) and not context:
            context = _unquote(value)          # the `build: ./dir` short form
        elif key == "image":
            image = _unquote(value)
    flush()
    return out


def stack_services(generator_dir: str) -> tuple[StackService, ...]:
    """Every service the local stack's compose files declare, merged by name across
    files: an overlay that re-declares a service (compose.social-profile.yaml tags
    compose.real.yaml's tuwunel with ``profiles: [social]``) ADDS to it."""
    merged: dict[str, StackService] = {}
    order: list[str] = []
    for path in compose_files(generator_dir):
        for svc in _parse_services(path):
            prev = merged.get(svc.name)
            if prev is None:
                merged[svc.name] = svc
                order.append(svc.name)
                continue
            merged[svc.name] = StackService(
                svc.name,
                prev.profiles + tuple(p for p in svc.profiles if p not in prev.profiles),
                prev.context or svc.context,
                prev.image or svc.image,
                prev.files + svc.files)
    return tuple(merged[n] for n in order)


# ── folders ──────────────────────────────────────────────────────────────────────
def source_root(generator_dir: str, source_mode: str, source_dir: str,
                environ=None) -> str:
    """The directory compose resolves ``${STACK_SRC}`` to: the operator's tree in
    ``existing`` mode ("" until one is typed), ``<generator>/.stack-src`` in clone
    mode — the Makefile's ``STACK_SRC ?= $(CURDIR)/.stack-src``. The Studio sets no
    STACK_SRC in clone mode, but it does not remove one the operator exported, and
    ``?=`` keeps an existing value: so a non-empty STACK_SRC in ``environ`` (the
    process environment by default) IS the clone-mode root, exactly as the build
    sees it. A relative one is read against the generator checkout, where make runs.

    The ``existing`` spelling is EXACTLY ``LocalStackNode._build_env``'s
    ``os.path.abspath(source_dir.strip())`` — no ``~`` expansion, because the build
    does none: a typed ``~/src`` reaches make as ``<cwd>/~/src``, and the coverage
    line on the same step tests the raw text too. Expanding it here would send the
    operator to a folder the build never reads."""
    if source_mode == "existing":
        sd = (source_dir or "").strip()
        return os.path.abspath(sd) if sd else ""
    environ = os.environ if environ is None else environ
    inherited = (environ.get("STACK_SRC") or "").strip()
    if inherited:
        return os.path.abspath(os.path.join(os.path.abspath(generator_dir), inherited))
    return os.path.join(os.path.abspath(generator_dir), STACK_SRC_DIR)


def _expand(value: str, environ) -> str:
    """``${VAR:-default}`` the way compose expands it for a build context."""
    def sub(m):
        return (environ.get(m.group(1)) or m.group(2) or "")
    return _VAR_DEFAULT_RE.sub(sub, value)


def _context_folder(context: str, generator_dir: str, root: str, environ):
    """``(kind, name, path)`` for a raw compose ``context`` value."""
    m = STACK_SRC_CONTEXT_RE.match(context)
    if m:
        name = m.group(1)
        return KIND_REPO, name, (os.path.join(root, name) if root else "")
    expanded = _expand(context, environ)
    path = os.path.normpath(os.path.join(generator_dir, STACK_DIR, expanded)) \
        if not os.path.isabs(expanded) else os.path.normpath(expanded)
    path = os.path.abspath(path)
    # A folder inside this repo is named by where it sits ("specs/cluster/…/worker"):
    # its bare basename ("worker", "image") says nothing and two of them could collide.
    gen = os.path.abspath(generator_dir)
    if path == gen or not path.startswith(gen + os.sep):
        name = os.path.basename(path.rstrip(os.sep)) or path
    else:
        name = os.path.relpath(path, gen)
    return KIND_PATH, name, path


def _missing_reason(kind: str, name: str, path: str, source_mode: str,
                    root: str) -> str:
    if kind == KIND_REPO:
        if source_mode == "existing":
            return NO_SOURCE_DIR_REASON if not root else f"no {name} checkout in {root}"
        return NOT_DOWNLOADED_REASON
    return f"{path} does not exist"


def _short_image(image: str) -> str:
    """``repo/name:tag@sha256:…`` -> ``repo/name:tag`` — a digest says nothing to a
    person reading a note."""
    return (image or "").split("@", 1)[0]


def _field(row, key: str, default=None):
    """A Domain dataclass attribute or a saved-record dict key, whichever ``row`` is."""
    if isinstance(row, dict):
        return row.get(key, default)
    return getattr(row, key, default)


def _federation_services(services, module: str) -> list[StackService]:
    """The always-on services named after a federation module — compose.local.yaml's
    rule: ``hugmesh-<module>-<role>`` for the built images, ``<module>-<role>`` for
    their stock backing services."""
    out = []
    for svc in services:
        bare = svc.name[len("hugmesh-"):] if svc.name.startswith("hugmesh-") else svc.name
        if bare == module or bare.startswith(module + "-"):
            out.append(svc)
    return out


def service_owners(services) -> dict[str, tuple[str, ...]]:
    """``compose service name -> the per-domain slugs that own it`` for the
    always-built (platform) services that belong to ONE per-domain choice: the
    federation rows named after a per-domain slug's module (owncast, tube, the two
    character apps) and the front ends in :data:`UI_OWNERS`. A service with no entry
    here belongs to every domain. Only per-DOMAIN slugs count: the mesh-plane ones
    (wiki, tor, ...) are the whole mesh's, never one domain's."""
    owners: dict[str, list[str]] = {}
    platform = [s for s in services if not s.profiles]
    for slug in local_services.domain_local_slugs():
        svc_def = local_services.by_slug(slug)
        if svc_def is None or not svc_def.is_federation():
            continue
        for svc in _federation_services(platform, svc_def.module):
            owners.setdefault(svc.name, [])
            if slug not in owners[svc.name]:
                owners[svc.name].append(slug)
    for name, slugs in UI_OWNERS.items():
        if any(s.name == name for s in platform):
            row = owners.setdefault(name, [])
            row.extend(x for x in slugs if x not in row)
    return {k: tuple(v) for k, v in owners.items()}


def code_folder_map(generator_dir: str, source_mode: str, source_dir: str,
                    domains, environ=None) -> CodeFolderMap:
    """The whole map for ``domains`` (Domain rows, or saved-record dicts with the
    same keys). See the module docstring for what lands on a domain and why."""
    environ = os.environ if environ is None else environ
    generator_dir = os.path.abspath(generator_dir)
    root = source_root(generator_dir, source_mode, source_dir, environ)
    root_exists = bool(root) and os.path.isdir(root)
    if root_exists:
        root_reason = ""
    elif source_mode == "existing":
        root_reason = (NO_SOURCE_DIR_REASON if not root
                       else f"{root} is a file, not a folder" if os.path.exists(root)
                       else f"{root} does not exist")
        if root and (source_dir or "").strip().startswith("~"):
            root_reason += (" — the build does not expand ‘~’, so type the full "
                            "path (for example /home/you/src)")
    else:
        root_reason = NOT_DOWNLOADED_REASON
    notice = EXISTING_MODE_NOTICE if source_mode == "existing" else CLONE_MODE_NOTICE

    services = stack_services(generator_dir)
    platform = [s for s in services if not s.profiles]
    owners = service_owners(services)

    def folder_rows(picked: list[tuple[StackService, str]]):
        """``[(service, reason), ...]`` -> rows keyed by folder, plus image notes."""
        rows: dict[str, dict] = {}
        images: list[tuple[str, str, str]] = []     # (service, image, reason)
        for svc, reason in picked:
            if not svc.context:
                images.append((svc.name, svc.image, reason))
                continue
            kind, name, path = _context_folder(svc.context, generator_dir, root, environ)
            key = path or name
            row = rows.setdefault(key, {"name": name, "kind": kind, "path": path,
                                        "services": [], "reasons": []})
            if svc.name not in row["services"]:
                row["services"].append(svc.name)
            if reason not in row["reasons"]:
                row["reasons"].append(reason)
        apps = []
        for row in rows.values():
            exists = bool(row["path"]) and os.path.isdir(row["path"])
            apps.append(AppFolder(
                name=row["name"], kind=row["kind"], path=row["path"], exists=exists,
                missing_reason="" if exists else _missing_reason(
                    row["kind"], row["name"], row["path"], source_mode, root),
                services=tuple(row["services"]), reasons=tuple(row["reasons"])))
        return apps, images

    out: list[DomainFolders] = []
    for dom in domains or ():
        dname = (_field(dom, "name", "") or "").strip()
        if not dname:
            continue
        chosen = normalise_slugs(_field(dom, "optional_services", []) or [])
        # A platform app that belongs to ONE per-domain service is this domain's only
        # when the domain chose that service: compose still builds it for the whole
        # mesh, but a domain that did not pick owncast has no owncast app, so it gets
        # no owncast folder (and no copy of one, core/domain_workspaces.py).
        picked: list[tuple[StackService, str]] = []
        not_chosen: dict[str, list[str]] = {}
        for s in platform:
            own = owners.get(s.name, ())
            if not own or any(o in chosen for o in own):
                picked.append((s, REASON_PLATFORM))
                picked.extend((s, f"selected: {o}") for o in own if o in chosen)
            elif s.context:                    # a stock backing DB has no folder anyway
                not_chosen.setdefault(" or ".join(own), []).append(s.name)
        notes: list[str] = []
        for slug in chosen:
            svc_def = local_services.by_slug(slug)
            reason = f"selected: {slug}"
            if svc_def is None:
                notes.append(f"{slug}: not a service this local mesh knows — no folder")
                continue
            if svc_def.is_kind():
                notes.append(f"{slug}: runs on the Kubernetes (DevOps) lane, nothing "
                             "is built for it here — no folder")
                continue
            if svc_def.is_profile():
                matches = [s for s in services if svc_def.profile in s.profiles]
                if not matches:
                    notes.append(f"{slug}: no compose service carries profile "
                                 f"‘{svc_def.profile}’ — nothing to open")
            else:
                matches = _federation_services(platform, svc_def.module)
                if not matches:
                    notes.append(f"{slug}: no compose service is named after its "
                                 f"federation module ‘{svc_def.module}’ — nothing to "
                                 "open")
            picked.extend((s, reason) for s in matches)
        apps, images = folder_rows(picked)
        # Stock images: a SELECTED service that yields no folder at all (akkoma,
        # tuwunel) gets a line naming its images — the operator picked it and should
        # learn there is nothing to open. A selection that does have a folder says
        # nothing about its backing database; and the platform's own stock images
        # are one summary line.
        with_folder = {r for a in apps for r in a.reasons}
        selected_images: dict[str, list[str]] = {}
        platform_images: list[str] = []
        for _svc_name, image, reason in images:
            shown = _short_image(image)
            if reason == REASON_PLATFORM:
                if shown and shown not in platform_images:
                    platform_images.append(shown)
            elif reason not in with_folder:
                names = selected_images.setdefault(reason, [])
                if shown and shown not in names:
                    names.append(shown)
        for reason, names in selected_images.items():
            slug = reason[len("selected: "):]
            notes.append(f"{slug}: runs stock images only ({', '.join(names)}) — no "
                         "source folder")
        if runs_own_casdoor(dom):
            notes.append("Own sign-in: a Casdoor of its own (stock image) — no "
                         "source folder")
        elif has_external_signin(dom):
            notes.append("Own sign-in: an outside sign-in service this domain trusts "
                         "— nothing of it runs here, no source folder")
        if not_chosen:
            parts = [f"{what} ({', '.join(sorted(n[len('hugmesh-'):] if n.startswith('hugmesh-') else n for n in names))})"
                     for what, names in sorted(not_chosen.items())]
            notes.append("Not chosen for this domain, so no folder: " + "; ".join(parts)
                         + ". The mesh still builds these apps for the domains that "
                         "chose them.")
        if platform_images:
            shown = ", ".join(sorted(platform_images)[:6])
            more = len(platform_images) - min(6, len(platform_images))
            notes.append(f"Also runs {len(platform_images)} stock image"
                         f"{'s' if len(platform_images) != 1 else ''} with no source "
                         f"folder: {shown}{f', +{more} more' if more else ''}")
        out.append(DomainFolders(dname, tuple(apps), tuple(notes)))
    return CodeFolderMap(source_mode, root, root_exists, root_reason, notice, tuple(out))

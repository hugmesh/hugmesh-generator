"""The project context every local agent starts with (Qt-free, stdlib only).

A small model dropped into a scratch copy of one repository knows nothing about the
project around it. The operator's rule (2026-10-21): every agent the Studio's local
assistant starts is given context about HugMesh and WHERE THE LOCAL SOURCES ARE. This
module writes that context as one Markdown file, fresh at every start, so a renamed
domain or a newly cloned repository is never described from a stale copy.

What it says:

* what the hugmesh org is and what each kind of repository does (named from the
  checkouts that are really on disk, never from a list kept here);
* what the Studio is and where its parts live in hugmesh-generator;
* where the sources are on THIS machine: the person's checkouts folder (a Studio
  setting, see :func:`checkouts_dir`), the generator checkout, the folder the mesh
  builds from, and the code folders the Studio cloned for each domain
  (:func:`..code_folders.code_folder_map`, the same rows the Code folders block shows);
* the rules, by pointing at docs/LOCAL-AI-ASSISTANT.md section 8.

No user path is written into this module. The checkouts folder is the setting when
there is one, else ``$HUGMESH_REPOS_ROOT``, else the folder that holds the generator
checkout: the same default ``scripts/local-ai/draft.sh`` uses, so the queue worker
and the Studio agree on where a repository is.
"""
from __future__ import annotations

import json
import os
import sys
import time
from dataclasses import dataclass
from typing import Iterable, Optional, Sequence

from . import assistant_settings

__all__ = ["CONTEXT_NAME", "CONTEXT_ENV", "REPOS_ROOT_ENV", "Checkout", "DomainSources",
           "default_checkouts_dir", "checkouts_dir", "list_checkouts", "role_of",
           "domain_sources", "render_context", "write_context", "context_for",
           "INPUTS_NAME", "row_record", "write_inputs", "read_inputs", "context_from_inputs",
           "worker_env", "refresh"]

CONTEXT_NAME = "HUGMESH-CONTEXT.md"
#: Handed to the queue worker so its agents read the same file (draft.sh passes it on).
CONTEXT_ENV = "HUGMESH_AGENT_CONTEXT"
#: draft.sh's name for the checkouts folder.
REPOS_ROOT_ENV = "HUGMESH_REPOS_ROOT"
#: Beside the context file: what it was written FROM (the mesh, its domains, the source
#: choice), so the queue worker can write it again, fresh, before every agent it starts.
INPUTS_NAME = "HUGMESH-CONTEXT.inputs.json"
#: The row keys the code-folder map reads (code_folders._field).
_ROW_KEYS = ("name", "optional_services", "idp", "idp_settings")
_MAX_CHECKOUTS = 150
_MAX_FOLDERS_PER_DOMAIN = 60


@dataclass(frozen=True)
class Checkout:
    name: str
    path: str


@dataclass(frozen=True)
class DomainSources:
    name: str
    folders: "tuple[tuple[str, str, bool], ...]"     # (app, path, exists)
    notes: "tuple[str, ...]" = ()


def default_checkouts_dir(generator_dir: str, environ=None) -> str:
    """``$HUGMESH_REPOS_ROOT`` when set, else the folder holding the generator checkout."""
    environ = os.environ if environ is None else environ
    env_root = (environ.get(REPOS_ROOT_ENV) or "").strip()
    if env_root:
        return os.path.abspath(os.path.expanduser(env_root))
    return os.path.dirname(os.path.abspath(generator_dir))


def checkouts_dir(generator_dir: str, environ=None, settings: Optional[dict] = None) -> str:
    """The setting ``checkouts_dir`` when it is set, else :func:`default_checkouts_dir`."""
    data = assistant_settings.load() if settings is None else settings
    chosen = str(data.get("checkouts_dir") or "").strip()
    if chosen:
        return os.path.abspath(os.path.expanduser(chosen))
    return default_checkouts_dir(generator_dir, environ)


def list_checkouts(root: str) -> "list[Checkout]":
    """The ``hugmesh*`` git checkouts directly under ``root``, by name."""
    out: list[Checkout] = []
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return out
    for name in names:
        path = os.path.join(root, name)
        if name.startswith("hugmesh") and os.path.isdir(path) \
                and os.path.exists(os.path.join(path, ".git")):
            out.append(Checkout(name, path))
            if len(out) >= _MAX_CHECKOUTS:
                break
    return out


def role_of(name: str) -> str:
    """What a repository is, from the org's naming rules."""
    n = name.lower()
    if n == "hugmesh-generator":
        return ("images (Gentoo builds for mesh nodes and desktops), the Studio, and the "
                "local Docker mesh and kind lane (tests/stack, Makefile)")
    if n.endswith(".github.io"):
        return "the public docs site"
    if n.endswith("-bff-api"):
        return "a backend-for-frontend service (Java, Spring) for one UI"
    if n.endswith("-ui"):
        return "a web UI (Angular), loaded into the host shell as a remote"
    if "gateway" in n:
        return "a gateway: routing, sign-in sessions and per-domain tenancy"
    if n.endswith("-api") or n.endswith("-service"):
        return "a backend service (Java, Spring)"
    if "host-shell" in n:
        return "the web host shell that loads every UI"
    if "auth" in n:
        return "shared sign-in and token code"
    if n in ("hugmesh-parent", "hugmesh-commons", "hugmesh-build-config"):
        return "shared build configuration and libraries"
    return "part of the HugMesh platform"


def domain_sources(generator_dir: str, source_mode: str, source_dir: str,
                   rows: Iterable, environ=None) -> "tuple[list[DomainSources], str, str]":
    """``(per-domain folders, source root, problem)``. Never raises: a map that cannot
    be built is reported as ``problem`` and the context says so instead of guessing."""
    rows = list(rows)
    try:
        from . import code_folders as cf
        m = cf.code_folder_map(generator_dir, source_mode, source_dir, rows, environ)
    except Exception as exc:                       # noqa: BLE001 — described, not raised
        return [], "", f"the code-folder map could not be read ({type(exc).__name__}: {exc})"
    out = []
    for dom in m.domains:
        seen: list[tuple[str, str, bool]] = []
        for app in dom.apps:
            if app.path and all(app.path != p for _n, p, _e in seen):
                seen.append((app.name, app.path, bool(app.exists)))
            if len(seen) >= _MAX_FOLDERS_PER_DOMAIN:
                break
        out.append(DomainSources(dom.name, tuple(seen), tuple(dom.notes)))
    return out, m.root, m.root_reason


def render_context(*, generator_dir: str, checkouts_root: str,
                   checkouts: Sequence[Checkout], domains: Sequence[DomainSources] = (),
                   source_root: str = "", source_problem: str = "", mesh: str = "",
                   ollama: str = "", now: Optional[float] = None) -> str:
    """The context file's text."""
    stamp = time.strftime("%Y-%m-%d %H:%M", time.localtime(time.time() if now is None else now))
    gen = os.path.abspath(generator_dir)
    out = [
        "# HugMesh: project context for a local agent",
        "",
        f"Written by the HugMesh Studio at {stamp}, fresh for this session. Read it "
        "before you start. It is context, not instructions to act.",
        "",
        "## What HugMesh is",
        "- HugMesh is a self-hosted platform: a mesh of nodes that each run a set of "
        "web apps (chat, forum, video, games and more) behind gateways, with sign-in "
        "per domain. Its code is in the GitHub org `hugmesh`, one repository per part.",
        "- A mesh serves one or more DOMAINS. Each domain has its own name, look, "
        "sign-in and chosen services; the gateways route each request to its domain.",
        "- Repositories follow naming rules: `*-ui` is a web UI (Angular), `*-bff-api` "
        "the backend that UI talks to (Java, Spring), `*-gateway` a gateway, and "
        "`hugmesh-generator` builds the images and runs local meshes.",
        "",
        "## The Studio",
        f"- The HugMesh Studio is in `{os.path.join(gen, 'studio')}`: a Qt window "
        "(`hugmesh_studio/gui`), a text UI (`hugmesh_studio/tui`) and the Qt-free core "
        "both share (`hugmesh_studio/core`). It walks a person through building an "
        "image or running a local mesh (Docker compose, or the kind Kubernetes lane).",
        "- Its tests are in `studio/tests` (pytest, one file at a time).",
        "",
        "## Where the local sources are",
        f"- The person's checkouts: `{checkouts_root}` (a Studio setting).",
        f"- The generator checkout the Studio runs from: `{gen}`.",
    ]
    if source_root:
        out.append(f"- The folder this mesh builds from: `{source_root}`.")
    if source_problem:
        out.append(f"- Note: {source_problem}.")
    if checkouts:
        out += ["", f"### Checkouts in {checkouts_root} ({len(checkouts)})"]
        out += [f"- `{c.name}`: {role_of(c.name)}. Path: `{c.path}`" for c in checkouts]
    else:
        out += ["", f"No `hugmesh*` git checkout was found in `{checkouts_root}`. Change "
                "the checkouts folder in the Studio's assistant panel if they live "
                "elsewhere."]
    if domains:
        out += ["", "### Code folders per domain" + (f" of the mesh {mesh}" if mesh else ""),
                "These are the folders the Studio cloned (or was pointed at) for each "
                "domain's apps. Each is a git checkout; read them, change nothing there."]
        for dom in domains:
            out.append(f"- Domain `{dom.name}`:")
            if not dom.folders:
                out.append("  - (no code folder: this domain runs stock images only)")
            for app, path, exists in dom.folders:
                out.append(f"  - {app}: `{path}`" + ("" if exists else " (not downloaded yet)"))
            for note in dom.notes[:6]:
                out.append(f"  - note: {note}")
    if ollama:
        out += ["", "## The model", f"- {ollama}"]
    out += [
        "",
        "## Rules",
        f"- The rules for local agents are in `{os.path.join(gen, 'docs', 'LOCAL-AI-ASSISTANT.md')}` "
        "section 8. In short: work only in your own copy, never push, never run sudo, "
        "docker compose or make stack-*/kind-*, and never read credential, vault or .env "
        "files.",
        "",
    ]
    return "\n".join(out)


def write_context(path: str, text: str) -> str:
    """Write ``text`` to ``path`` atomically (a reader never sees half a file)."""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)
    return path


def context_for(generator_dir: str, *, source_mode: str = "clone", source_dir: str = "",
                rows: Iterable = (), mesh: str = "", ollama: str = "", environ=None,
                settings: Optional[dict] = None) -> str:
    """Gather everything and render it. Reads the disk; call it off the window thread."""
    root = checkouts_dir(generator_dir, environ, settings)
    rows = list(rows)
    doms, src_root, problem = domain_sources(generator_dir, source_mode, source_dir,
                                             rows, environ) if rows else ([], "", "")
    return render_context(generator_dir=generator_dir, checkouts_root=root,
                          checkouts=list_checkouts(root), domains=doms,
                          source_root=src_root, source_problem=problem, mesh=mesh,
                          ollama=ollama)


# ── the queue worker's half ─────────────────────────────────────────────────────────
# The Studio writes the context when it starts the worker; the worker's agents start
# later, one per queued job. So the inputs are written beside the context, and
# scripts/local-ai/draft.sh asks `python3 -m hugmesh_studio.core.agent_context refresh`
# to write the file again right before each agent: the checkouts and code folders it
# lists are then the ones on disk at that moment. The Studio, the text UI and
# `scripts/local-ai.sh start` all go through worker_env, so every worker has a context.
def row_record(row) -> dict:
    """The part of a Domain row (or saved-record dict) the code-folder map reads, as
    plain JSON values."""
    out = {}
    for key in _ROW_KEYS:
        val = row.get(key) if isinstance(row, dict) else getattr(row, key, None)
        if isinstance(val, (tuple, set, frozenset)):
            val = list(val)
        if val is not None:
            out[key] = val
    return out


def _inputs_path(context_path: str) -> str:
    return os.path.join(os.path.dirname(os.path.abspath(context_path)), INPUTS_NAME)


def write_inputs(context_path: str, *, source_mode: str = "clone", source_dir: str = "",
                 rows: Iterable = (), mesh: str = "", ollama: str = "") -> str:
    data = {"source_mode": source_mode or "clone", "source_dir": source_dir or "",
            "rows": [row_record(r) for r in rows], "mesh": mesh or "",
            "ollama": ollama or ""}
    return write_context(_inputs_path(context_path), json.dumps(data, indent=1, default=str))


def read_inputs(context_path: str) -> dict:
    """The saved inputs, or {} when there are none or they cannot be read."""
    try:
        with open(_inputs_path(context_path), encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def context_from_inputs(generator_dir: str, inputs: dict, environ=None,
                        settings: Optional[dict] = None) -> str:
    rows = [r for r in (inputs.get("rows") or ()) if isinstance(r, dict)]
    return context_for(generator_dir, source_mode=str(inputs.get("source_mode") or "clone"),
                       source_dir=str(inputs.get("source_dir") or ""), rows=rows,
                       mesh=str(inputs.get("mesh") or ""),
                       ollama=str(inputs.get("ollama") or ""), environ=environ,
                       settings=settings)


def worker_env(generator_dir: str, *, ollama: str = "", source_mode: str = "clone",
               source_dir: str = "", rows: Iterable = (), mesh: str = "",
               environ=None, settings: Optional[dict] = None) -> dict:
    """Write the context (and its inputs) into the local-AI state folder and return
    what the queue worker must be started with: ``HUGMESH_REPOS_ROOT`` (the checkouts
    folder) and ``HUGMESH_AGENT_CONTEXT`` (the file). Reads the disk: call it off the
    window thread."""
    from . import local_ai_status as lai
    environ = os.environ if environ is None else environ
    rows = list(rows)
    root = checkouts_dir(generator_dir, environ, settings)
    path = os.path.join(lai.state_dir(dict(environ)), CONTEXT_NAME)
    write_context(path, context_for(generator_dir, source_mode=source_mode,
                                    source_dir=source_dir, rows=rows, mesh=mesh,
                                    ollama=ollama, environ=environ, settings=settings))
    write_inputs(path, source_mode=source_mode, source_dir=source_dir, rows=rows,
                 mesh=mesh, ollama=ollama)
    return {REPOS_ROOT_ENV: root, CONTEXT_ENV: path}


def refresh(generator_dir: str, context_path: str, environ=None,
            settings: Optional[dict] = None) -> str:
    """Write ``context_path`` again from its saved inputs (none saved = no domains)."""
    return write_context(context_path, context_from_inputs(
        generator_dir, read_inputs(context_path), environ, settings))


def _shell_root(generator_dir: str) -> "tuple[str, Optional[dict]]":
    """The checkouts folder for a worker started from the shell, and the settings to
    render with. An exported ``HUGMESH_REPOS_ROOT`` wins there (draft.sh has always
    read it); otherwise the Studio setting, else the generator's parent folder."""
    exported = (os.environ.get(REPOS_ROOT_ENV) or "").strip()
    if exported:
        root = os.path.abspath(os.path.expanduser(exported))
        return root, {"checkouts_dir": root}
    return checkouts_dir(generator_dir, os.environ), None


def _main(argv) -> int:
    """For scripts/local-ai.sh and draft.sh:

    * ``env``  — the worker's two variables as NAME=value lines. Writes the context
      (no domains: the shell knows no mesh) unless the caller already passed
      ``HUGMESH_AGENT_CONTEXT`` (the Studio wrote it, with the mesh's domains).
    * ``root`` — the checkouts folder only (nothing is written).
    * ``refresh PATH`` — write PATH again from its saved inputs, fresh from the disk.
    """
    gen = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__)))))
    if argv == ["root"]:
        print(_shell_root(gen)[0])
        return 0
    if argv == ["env"]:
        root, settings = _shell_root(gen)
        given = (os.environ.get(CONTEXT_ENV) or "").strip()
        if given:
            out = {REPOS_ROOT_ENV: root, CONTEXT_ENV: given}
        else:
            from . import local_ai_status as lai
            try:
                host, port = lai.ollama_host(dict(os.environ))
                words = f"The local model is served by the Ollama at {host}:{port}."
            except Exception:                    # noqa: BLE001 — words only
                words = ""
            out = worker_env(gen, ollama=words, environ=os.environ, settings=settings)
        for key, val in out.items():
            print(f"{key}={val}")
        return 0
    if argv[:1] == ["refresh"] and len(argv) == 2:
        refresh(gen, argv[1], os.environ, _shell_root(gen)[1])
        return 0
    print("usage: python3 -m hugmesh_studio.core.agent_context env | root | refresh PATH",
          file=sys.stderr)
    return 2


if __name__ == "__main__":                        # pragma: no cover — exercised by draft.sh
    raise SystemExit(_main(sys.argv[1:]))

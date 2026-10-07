"""Start a local AI coding agent on a mesh's own code — Qt-free (issue #695).

The Studio's local-mesh build screens (the Docker mesh and the kind DevOps lane)
offer a card, "Work on this mesh with a local AI agent". This module is everything
that card does that is not drawing: finding out what is installed, choosing an
agent and a model, making a copy of one app's repository that cannot push, writing
the brief the agent starts from, and opening a terminal window that runs it.

It does exactly what ``docs/LOCAL-AI-ASSISTANT.md`` tells a person to do (section 6.1
the no-remote scratch clone, 6.2 ``ollama launch claude --model <model>``, 6.5 the
starting brief, 8 the safety rules). The doc stays the source of the rules: a test
reads it and checks every "never run" item is in the brief.

THE API, in the order a press uses it:

    probe()                      -> Probe        what is installed and answering
    diagnose(probe, ...)         -> [Problem]    one plain-words problem + fix each
    choose_defaults(probe)       -> (agent, model)
    prepare(...)                 -> Plan         decided, nothing written yet
    create_scratch(plan.scratch) -> ScratchClone the clone exists, with no remote
    launch(plan, ...)            -> LaunchResult a terminal opened, or the command

WHAT IS STRIPPED, AND WHERE. A command that merely inherits the Studio's environment
would hand the agent every token the Studio was started with. Three places have to
agree, and one of them is easy to miss:

* ``build_env`` is an ALLOWLIST (PATH, HOME, USER, LANG, LC_*, TERM, the display and
  session variables, XDG_*, and OLLAMA_HOST only when it points at this machine).
  Nothing else is copied, so GH_TOKEN, GITHUB_TOKEN, registry and cloud tokens,
  SSH_AUTH_SOCK and ARGOCD_* are never passed on by name.
* The Popen environment is not enough on its own. gnome-terminal, xfce4-terminal and
  often konsole hand the new window to a terminal server that is already running, and
  that server starts the shell with ITS environment. So the command the terminal runs
  is ``env -i <allowlist> ollama launch ...`` — the agent's environment is built
  inside the window, whatever the server held.
* The wrapper shell is ``bash --noprofile --norc``. A login shell would re-read the
  profile, and on a machine that exports a token there, put it back.

What this does NOT remove: ``DBUS_SESSION_BUS_ADDRESS`` is on the allowlist (a
terminal needs it), so a keyring that answers on the session bus is still reachable
from the agent. The doc says the same about a no-remote clone: it takes away the
convenience of pushing, not the ability. The protection that counts is that the person
reads each command the agent asks to run.

No auto-approve flag is ever passed (``FORBIDDEN_FLAGS``), including ``ollama launch
-y/--yes``, which answers the launcher's own confirmations without asking.
"""
from __future__ import annotations

import ipaddress
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Callable, Optional, Sequence

from . import platform_info
from .state_paths import state_dir
# ONE grace period for a terminal that has to answer "I took it" — the number the
# browser and folder openers already use, not a second guess at it.
from .login_preview import _OPENER_WAIT_S as TERMINAL_WAIT_S

__all__ = [
    "DOC_PATH", "LANE_DOCKER", "LANE_KIND", "AGENTS", "DOC_MODELS", "PREFERRED_MODEL",
    "PREPARED_MODEL", "FORBIDDEN_FLAGS", "ENV_ALLOW_EXACT", "ENV_ALLOW_PREFIXES",
    "RULES", "TERMINALS",
    "ModelInfo", "Probe", "Problem", "SourceInfo", "ScratchSpec", "ScratchClone",
    "Plan", "LaunchResult", "Host", "ScratchError", "write_brief",
    "ollama_target", "build_env", "probe", "diagnose", "choose_defaults",
    "inspect_source", "prepare_scratch", "create_scratch", "make_scratch_clone",
    "kind_image_repos", "render_brief", "prepare", "launch", "forbidden_in",
]

DOC_PATH = "docs/LOCAL-AI-ASSISTANT.md"
LANE_DOCKER = "docker"
LANE_KIND = "kind"

DEFAULT_PORT = 11434
LOOPBACK_DEFAULT = f"127.0.0.1:{DEFAULT_PORT}"
HTTP_TIMEOUT_S = 2.0
#: A server with hundreds of models would turn one probe into hundreds of requests.
MAX_SHOW_CALLS = 40

#: The agents ``ollama launch`` can start that this card offers, and the command each
#: needs on PATH. ``prompt`` says how the brief reaches the agent: "positional" is the
#: form verified in the doc (section 6.2: ``ollama launch claude --model M -- "..."``);
#: "file" means the agent is started without an opening message and the window prints
#: where the brief is, because how the other agents take an opening message was not
#: checked on this machine. ``ollama launch --help`` lists more; add them when checked.
AGENTS: dict[str, dict] = {
    "claude": {"command": "claude", "prompt": "positional", "label": "Claude Code"},
    "opencode": {"command": "opencode", "prompt": "file", "label": "OpenCode"},
    "codex": {"command": "codex", "prompt": "file", "label": "Codex"},
}

#: A model the mesh's own LOCAL-AGENTS lane prepares (scripts/local-ai-agents.sh), when
#: it is pulled. Preferred over everything else.
PREPARED_MODEL = "hugmesh-agent"
#: The model the doc verified an agent on (section 6.2).
PREFERRED_MODEL = "qwen3:8b"
#: Every model the doc's tables name, Tier A then Tier B, in the doc's order. A pulled
#: one with the tools capability is chosen before an arbitrary one.
DOC_MODELS = (
    "qwen3:8b", "qwen2.5-coder:7b", "ornith:9b", "lfm2.5:8b", "gpt-oss:20b",
    "qwen3-coder:30b", "north-mini-code-1.0", "laguna-xs-2.1", "ornith:35b",
)

#: Flags that answer a prompt, or approve a tool call, without the person. None of
#: them is ever put in an argv here, and ``prepare`` refuses to build one that has any.
FORBIDDEN_FLAGS = frozenset({
    "-y", "--yes", "--experimental-yolo", "--yolo", "--dangerously-skip-permissions",
    "--allow-dangerously-skip-permissions", "--auto-approve", "--full-auto",
    "--dangerously-bypass-approvals-and-sandbox",
})

#: What the launch environment may contain. Anything not named here is dropped.
ENV_ALLOW_EXACT = frozenset({
    "PATH", "HOME", "USER", "LANG", "TERM", "DISPLAY", "WAYLAND_DISPLAY",
    "DBUS_SESSION_BUS_ADDRESS",
})
ENV_ALLOW_PREFIXES = ("LC_", "XDG_")

#: The doc's section 6.5 rules plus section 8, as the brief states them. Each line is
#: pinned against the doc by a test, so editing the doc and not this (or the reverse)
#: fails loudly.
RULES = (
    "Work only in this directory. It is a copy with no remote; nothing you do here "
    "reaches the real folder or the running mesh.",
    "Never run: git push, sudo, docker compose up/down, make stack-* or make kind-*, "
    "or anything that deletes outside this directory.",
    "Do not add a git remote, log in to anything, or read .e2e-credentials, vault "
    "files or .env files.",
    "Keep each task to one file or one failing test; read big files in ranges.",
    "End every task with: what you changed, what you ran and its result, and what you "
    "did NOT verify.",
    "Do not claim a test passed unless you ran it and saw it pass.",
)


# ── the Ollama server ────────────────────────────────────────────────────────────
def ollama_target(environ=None) -> "tuple[str, int, str]":
    """``(host, port, note)`` for the server to talk to.

    ``OLLAMA_HOST`` is honoured ONLY when it names this machine (127.0.0.0/8, ::1 or
    ``localhost``). The Ollama API has no login: sending prompts and code to a
    non-loopback address is the exact thing the doc's section 8 forbids, so a remote
    value is ignored — and said so in ``note`` — rather than used."""
    environ = os.environ if environ is None else environ
    raw = (environ.get("OLLAMA_HOST") or "").strip()
    default = ("127.0.0.1", DEFAULT_PORT, "")
    if not raw:
        return default
    text = raw
    if "://" in text:
        text = text.split("://", 1)[1]
    text = text.split("/", 1)[0]
    host, port = text, DEFAULT_PORT
    if text.startswith("["):                       # [::1]:11434
        end = text.find("]")
        host = text[1:end] if end > 0 else text
        rest = text[end + 1:] if end > 0 else ""
        if rest.startswith(":") and rest[1:].isdigit():
            port = int(rest[1:])
    elif text.count(":") == 1:
        h, _, p = text.partition(":")
        host = h
        if p.isdigit():
            port = int(p)
    host = host.strip()
    if host == "":                                  # ":11434" — the client means this machine
        return ("127.0.0.1", port, "")
    loopback = host.lower() == "localhost"
    if not loopback:
        try:
            loopback = ipaddress.ip_address(host).is_loopback
        except ValueError:
            loopback = False
    if loopback:
        return (host, port, "")
    return ("127.0.0.1", DEFAULT_PORT,
            f"OLLAMA_HOST is set to {raw}, which is not this machine; it is ignored "
            "because the Ollama API has no login (docs section 8). Using "
            f"{LOOPBACK_DEFAULT}.")


def _hostport(host: str, port: int) -> str:
    return f"[{host}]:{port}" if ":" in host else f"{host}:{port}"


def build_env(environ=None, *, terminal: bool = False) -> "dict[str, str]":
    """The environment a launched process may have: the allowlist, nothing else.

    ``terminal=True`` is for the terminal emulator's own process and adds
    ``XAUTHORITY`` (a path, not a secret; some X11 sessions need it to open a window).
    The agent's environment never gets it."""
    environ = os.environ if environ is None else environ
    out: dict[str, str] = {}
    for key, value in environ.items():
        if key in ENV_ALLOW_EXACT or key.startswith(ENV_ALLOW_PREFIXES):
            out[key] = value
    if terminal and environ.get("XAUTHORITY"):
        out["XAUTHORITY"] = environ["XAUTHORITY"]
    host, port, _note = ollama_target(environ)
    if (environ.get("OLLAMA_HOST") or "").strip() and _note == "":
        out["OLLAMA_HOST"] = _hostport(host, port)
    else:
        out.pop("OLLAMA_HOST", None)
    return out


Fetch = Callable[..., "tuple[int, bytes]"]


def _http(method: str, url: str, body=None, timeout: float = HTTP_TIMEOUT_S):
    """One request to the server. Proxies are bypassed on purpose: a corporate proxy
    variable must never route a loopback request, or the prompts, away from here."""
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(
        url, data=data, method=method,
        headers={"Content-Type": "application/json"} if data is not None else {})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=timeout) as resp:
            return resp.status, resp.read(4_000_000)
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read(4_000_000)


@dataclass(frozen=True)
class ModelInfo:
    name: str
    tools: bool
    #: Runs on Ollama's servers, not this machine (a ``-cloud`` tag, or an entry that
    #: names a remote host). Never offered: the prompt and the code would leave the PC.
    cloud: bool = False
    size_bytes: int = 0


@dataclass(frozen=True)
class Probe:
    """What is on this machine right now. Plain data; ``diagnose`` reads it."""
    ollama_path: str = ""
    server: str = LOOPBACK_DEFAULT
    server_up: bool = False
    server_error: str = ""
    host_note: str = ""
    models: "tuple[ModelInfo, ...]" = ()
    #: agent name -> full path of the command it needs ("" when not installed)
    agents: "dict[str, str]" = field(default_factory=dict)

    @property
    def usable_models(self) -> "tuple[ModelInfo, ...]":
        """Models with the tools capability that run on this machine."""
        return tuple(m for m in self.models if m.tools and not m.cloud)

    @property
    def local_models(self) -> "tuple[ModelInfo, ...]":
        return tuple(m for m in self.models if not m.cloud)


def _is_cloud(name: str, entry: dict) -> bool:
    if entry.get("remote_host") or entry.get("remote_model"):
        return True
    low = name.lower()
    return low.endswith("-cloud") or low.endswith(":cloud")


def probe(environ=None, *, which: "Callable[[str], Optional[str]]" = shutil.which,
          fetch: Optional[Fetch] = None) -> Probe:
    """Ask the machine. Read-only: GET /api/tags and, for a server that does not list
    capabilities there, POST /api/show. Never generates anything, never raises."""
    environ = os.environ if environ is None else environ
    fetch = fetch or _http
    path_env = environ.get("PATH")
    find = (lambda cmd: which(cmd, path=path_env)) if path_env and which is shutil.which \
        else which
    ollama_path = find("ollama") or ""
    agents = {name: (find(spec["command"]) or "") for name, spec in AGENTS.items()}
    host, port, note = ollama_target(environ)
    server = _hostport(host, port)
    base = f"http://{server}"
    try:
        status, raw = fetch("GET", base + "/api/tags", None, HTTP_TIMEOUT_S)
    except (OSError, ValueError) as exc:           # refused, timed out, no route
        return Probe(ollama_path, server, False, _short_error(exc), note, (), agents)
    if status != 200:
        return Probe(ollama_path, server, False,
                     f"answered HTTP {status} to /api/tags", note, (), agents)
    try:
        entries = json.loads(raw.decode("utf-8", "replace")).get("models") or []
        if not isinstance(entries, list):
            raise ValueError("models is not a list")
    except (ValueError, AttributeError):
        return Probe(ollama_path, server, False,
                     "answered, but not with an Ollama model list", note, (), agents)
    models: list[ModelInfo] = []
    show_calls = 0
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        name = str(entry.get("name") or entry.get("model") or "")
        if not name:
            continue
        caps = entry.get("capabilities")
        if not isinstance(caps, list) and show_calls < MAX_SHOW_CALLS:
            show_calls += 1
            caps = _show_capabilities(fetch, base, name)
        models.append(ModelInfo(
            name=name, tools="tools" in (caps or []), cloud=_is_cloud(name, entry),
            size_bytes=int(entry.get("size") or 0)))
    return Probe(ollama_path, server, True, "", note, tuple(models), agents)


def _show_capabilities(fetch: Fetch, base: str, name: str) -> "list[str]":
    try:
        status, raw = fetch("POST", base + "/api/show", {"model": name}, HTTP_TIMEOUT_S)
        if status != 200:
            return []
        caps = json.loads(raw.decode("utf-8", "replace")).get("capabilities")
        return [str(c) for c in caps] if isinstance(caps, list) else []
    except (OSError, ValueError, AttributeError):
        return []


def _short_error(exc: BaseException) -> str:
    reason = getattr(exc, "reason", exc)
    text = str(reason) or type(reason).__name__
    return text if len(text) <= 120 else text[:117] + "..."


# ── plain-words problems ─────────────────────────────────────────────────────────
@dataclass(frozen=True)
class Problem:
    """One thing that stops a start: what is wrong, how to fix it, where the doc says
    more. Written for a person who has never run Ollama."""
    code: str
    what: str
    fix: str
    doc: str                     # path#anchor inside the repository

    def text(self) -> str:
        return f"{self.what} {self.fix}"


def _doc(anchor: str) -> str:
    return f"{DOC_PATH}#{anchor}"


def diagnose(pr: Probe, agent: str = "claude", model: str = "",
             source: "Optional[SourceInfo]" = None) -> "list[Problem]":
    """Every reason a start cannot happen, first prerequisite first. Empty = ready.

    The order is the order a person fixes them in: the program, then the server, then
    a model, then the agent, then the folder."""
    out: list[Problem] = []
    if not pr.ollama_path:
        out.append(Problem(
            "ollama_missing",
            "Ollama is not installed: no `ollama` command was found.",
            "Install it (docs section 2), then press Re-check.",
            _doc("2-install-ollama-cli")))
    if not pr.server_up:
        why = f" ({pr.server_error})" if pr.server_error else ""
        out.append(Problem(
            "server_down",
            f"The Ollama server is not answering on {pr.server}{why}.",
            "Start it on this machine only: OLLAMA_HOST=127.0.0.1:11434 "
            "OLLAMA_CONTEXT_LENGTH=32768 setsid ollama serve >~/.cache/ollama-serve.log "
            "2>&1 &  (docs section 3), then press Re-check.",
            _doc("3-start-the-server")))
    else:
        local = pr.local_models
        if not local:
            cloud = len(pr.models) - len(local)
            extra = (f" ({cloud} cloud model(s) are ignored: they run on Ollama's "
                     "servers, not this PC.)" if cloud else "")
            out.append(Problem(
                "no_models", "The server answers, but no model is pulled." + extra,
                f"Pull one that can use tools, for example `ollama pull "
                f"{PREFERRED_MODEL}` (docs section 4), then press Re-check.",
                _doc("4-pick-a-model")))
        elif not pr.usable_models:
            names = ", ".join(m.name for m in local[:4]) + (", ..." if len(local) > 4 else "")
            out.append(Problem(
                "no_tools_model",
                f"None of the pulled models ({names}) has the tools capability, which "
                "an agent needs to read files and run commands.",
                f"Pull one that does, for example `ollama pull {PREFERRED_MODEL}` "
                "(docs section 4), then press Re-check.",
                _doc("4-pick-a-model")))
        elif model:
            chosen = next((m for m in pr.models if m.name == model), None)
            if chosen is None:
                out.append(Problem(
                    "model_gone", f"The model {model} is not pulled any more.",
                    "Pick another from the list, or press Re-check.",
                    _doc("4-pick-a-model")))
            elif chosen.cloud:
                out.append(Problem(
                    "model_cloud",
                    f"{model} runs on Ollama's servers, not on this PC.",
                    "Pick a local model: the prompt and the code would leave the "
                    "machine otherwise (docs section 4).", _doc("4-pick-a-model")))
            elif not chosen.tools:
                out.append(Problem(
                    "model_no_tools",
                    f"{model} does not have the tools capability, so it cannot drive "
                    "an agent.", "Pick a model marked with tools.",
                    _doc("4-pick-a-model")))
    spec = AGENTS.get(agent)
    if spec is None:
        out.append(Problem("agent_unknown", f"{agent} is not an agent this card starts.",
                           "Pick one from the list.", _doc("63-other-assistants")))
    elif not pr.agents.get(agent):
        out.append(Problem(
            "agent_missing",
            f"The `{spec['command']}` command is not installed, and "
            f"`ollama launch {agent}` needs it.",
            f"Install {spec['label']} so `{spec['command']}` is on your PATH "
            "(docs section 6.2), then press Re-check.",
            _doc("62-claude-code-on-the-local-model-verified")))
    if source is not None and not source.ok:
        out.append(Problem("source", source.reason,
                           "Pick another app, or download / point at the source first.",
                           _doc("61-give-the-assistant-a-copy-never-your-working-checkout")))
    return out


def choose_defaults(pr: Probe, agent: str = "", model: str = "") -> "tuple[str, str]":
    """``(agent, model)``. Anything passed in is kept if it is usable.

    Agent: claude (what the doc verified), else the first installed one, else claude
    (so the problem names the command to install). Model: ``hugmesh-agent`` when
    pulled; else the first of the doc's models that is pulled with tools; else the
    first pulled model with tools; else ""."""
    if agent not in AGENTS:
        installed = [a for a in AGENTS if pr.agents.get(a)]
        agent = "claude" if (not installed or pr.agents.get("claude")) else installed[0]
    usable = {m.name: m for m in pr.usable_models}
    if model and model in usable:
        return agent, model
    for name in usable:
        if _base(name) == PREPARED_MODEL:
            return agent, name
    for wanted in DOC_MODELS:
        for name in usable:
            if name == wanted or (":" not in wanted and _base(name) == wanted):
                return agent, name
    for name in usable:
        return agent, name
    return agent, ""


def _base(name: str) -> str:
    return name.split(":", 1)[0]


# ── the scratch clone ────────────────────────────────────────────────────────────
class ScratchError(Exception):
    """A scratch clone could not be made; the message says why, in plain words."""


GitRunner = Callable[[Sequence[str], Optional[str]], "tuple[int, str]"]


def _git_env() -> "dict[str, str]":
    env = build_env()
    env["GIT_TERMINAL_PROMPT"] = "0"
    return env


def _run_git(args: Sequence[str], cwd: Optional[str] = None) -> "tuple[int, str]":
    """Run git with the stripped environment — a clone of a local path asks for no
    credentials, and a git hook or credential helper must find none to hand out."""
    try:
        proc = subprocess.run(
            ["git", *args], cwd=cwd, env=_git_env(), stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=600)
    except (OSError, subprocess.SubprocessError) as exc:
        return 127, f"git could not run: {exc}"
    return proc.returncode, proc.stdout.decode("utf-8", "replace").strip()


@dataclass(frozen=True)
class SourceInfo:
    path: str
    ok: bool
    reason: str = ""
    head_sha: str = ""
    #: the branch name, or "(detached)" — informational, the clone works from either
    branch: str = ""
    #: tracked or untracked files with uncommitted changes in the REAL folder. A clone
    #: carries committed state only, so these are not in the agent's copy.
    dirty_files: int = 0


def inspect_source(path: str, runner: Optional[GitRunner] = None) -> SourceInfo:
    """Is ``path`` a git repository with at least one commit? Read-only."""
    run = runner or _run_git
    if not path:
        return SourceInfo(path, False, "No folder is known for this app yet.")
    if not os.path.isdir(path):
        return SourceInfo(path, False, f"{path} does not exist yet.")
    code, out = run(["rev-parse", "--is-inside-work-tree"], path)
    if code != 0 or out.strip() != "true":
        return SourceInfo(path, False,
                          f"{path} is not a git repository, so it cannot be copied "
                          "for an agent (a plain folder has no history to branch).")
    code, top = run(["rev-parse", "--show-toplevel"], path)
    if code == 0 and top.strip() and os.path.realpath(top.strip()) != os.path.realpath(path):
        return SourceInfo(path, False,
                          f"{path} is inside the git repository {top.strip()} but is not "
                          "its top folder; a copy would be the whole repository. Point at "
                          "the repository's own folder.")
    code, sha = run(["rev-parse", "--verify", "HEAD"], path)
    if code != 0 or not re.fullmatch(r"[0-9a-f]{40,64}", sha.strip()):
        return SourceInfo(path, False, f"{path} is a git repository with no commits yet.")
    _c, branch = run(["symbolic-ref", "--short", "-q", "HEAD"], path)
    _c, porcelain = run(["status", "--porcelain"], path)
    dirty = len([ln for ln in porcelain.splitlines() if ln.strip()])
    return SourceInfo(path, True, "", sha.strip(), branch.strip() or "(detached)", dirty)


@dataclass(frozen=True)
class ScratchSpec:
    """Where the copy will go and what it will be called. Decided without writing."""
    source: SourceInfo
    dest: str
    branch: str
    brief_path: str
    #: an existing clone that is clean, has no remote and was made from the source's
    #: current commit — used as it is
    reuse: bool = False


@dataclass(frozen=True)
class ScratchClone:
    path: str
    branch: str
    base_sha: str
    reused: bool


def _slug(text: str, fallback: str) -> str:
    out = re.sub(r"[^A-Za-z0-9._-]+", "-", (text or "").strip()).strip("-.")
    return out or fallback


def agent_work_dir(mesh: str, state_root: Optional[str] = None) -> str:
    """``<state dir>/agent-work/<mesh>``: under the Studio's state, never /tmp and
    never inside a ``.stack-src`` (which ``make stack-clone`` rewrites)."""
    return os.path.join(state_root or state_dir(), "agent-work", _slug(mesh, "mesh"))


def prepare_scratch(source: str, mesh: str, repo: str, *, state_root: Optional[str] = None,
                    runner: Optional[GitRunner] = None,
                    now: Optional[Callable[[], float]] = None) -> ScratchSpec:
    """Decide the destination. Read-only apart from git reads; raises ScratchError
    when the source cannot be copied.

    An existing clone is reused only when it is clean (no uncommitted or untracked
    files), has no remote (one that reappeared means someone added a way to push), and
    was cloned from the source's CURRENT commit (otherwise the agent would read an old
    snapshot). Otherwise the next numbered name is used; nothing is deleted."""
    run = runner or _run_git
    info = inspect_source(source, run)
    if not info.ok:
        raise ScratchError(info.reason)
    base_dir = agent_work_dir(mesh, state_root)
    name = _slug(repo or os.path.basename(source.rstrip(os.sep)), "repo")
    real_source = os.path.realpath(source)
    stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime((now or time.time)()))
    n = 1
    while True:
        leaf = name if n == 1 else f"{name}-{n}"
        dest = os.path.join(base_dir, leaf)
        if os.path.realpath(dest).startswith(real_source + os.sep) or \
                os.path.realpath(dest) == real_source:
            raise ScratchError("The Studio's state folder is inside the source folder; "
                               "a copy cannot be made there.")
        brief = os.path.join(base_dir, f"{leaf}.brief.md")
        if not os.path.exists(dest):
            return ScratchSpec(info, dest, f"lm/{stamp}", brief, False)
        if _reusable(dest, info.head_sha, run):
            _c, branch = run(["symbolic-ref", "--short", "-q", "HEAD"], dest)
            return ScratchSpec(info, dest, branch.strip() or f"lm/{stamp}", brief, True)
        n += 1
        if n > 99:
            raise ScratchError(f"{base_dir} already holds 99 copies of {name}; remove "
                               "the old ones you no longer need and try again.")


def _reusable(dest: str, head_sha: str, run: GitRunner) -> bool:
    if not os.path.isdir(dest):
        return False
    code, out = run(["rev-parse", "--is-inside-work-tree"], dest)
    if code != 0 or out.strip() != "true":
        return False
    code, remotes = run(["remote"], dest)
    if code != 0 or remotes.strip():
        return False
    code, porcelain = run(["status", "--porcelain"], dest)
    if code != 0 or porcelain.strip():
        return False
    code, base = run(["config", "--get", "lm.base"], dest)
    return code == 0 and base.strip() == head_sha


def create_scratch(spec: ScratchSpec, runner: Optional[GitRunner] = None) -> ScratchClone:
    """Make the copy (or accept the reusable one). The order is the doc's, and the
    remote is removed BEFORE anything else can touch the copy (docs section 6.1)."""
    run = runner or _run_git
    if spec.reuse:
        return ScratchClone(spec.dest, spec.branch, spec.source.head_sha, True)
    if os.path.exists(spec.dest):
        raise ScratchError(f"{spec.dest} already exists; nothing was changed.")
    os.makedirs(os.path.dirname(spec.dest), exist_ok=True)
    code, out = run(["clone", "--no-hardlinks", "--", spec.source.path, spec.dest], None)
    if code != 0:
        raise ScratchError(f"git clone failed: {out[-300:] or 'no output'}")
    for step in (["remote", "remove", "origin"],
                 ["switch", "-c", spec.branch],
                 ["config", "lm.base", spec.source.head_sha]):
        code, out = run(step, spec.dest)
        if code != 0:
            raise ScratchError(
                f"git {' '.join(step[:2])} failed in {spec.dest}: {out[-300:]}. The "
                "copy was left in place and must not be used until it is checked "
                "(it may still have its remote).")
    code, remotes = run(["remote"], spec.dest)
    if code != 0 or remotes.strip():
        raise ScratchError(f"{spec.dest} still has a remote ({remotes.strip()}); "
                           "it was not used.")
    return ScratchClone(spec.dest, spec.branch, spec.source.head_sha, False)


def make_scratch_clone(source: str, mesh: str, repo: str, *, state_root: Optional[str] = None,
                       runner: Optional[GitRunner] = None,
                       now: Optional[Callable[[], float]] = None) -> ScratchClone:
    """``git clone --no-hardlinks``, ``git remote remove origin``, ``git switch -c
    lm/<timestamp>`` — the three steps of docs section 6.1, with the refusals."""
    spec = prepare_scratch(source, mesh, repo, state_root=state_root, runner=runner, now=now)
    return create_scratch(spec, runner)


# ── the brief ────────────────────────────────────────────────────────────────────
_KIND_IMAGE_RE = re.compile(r'^\s*"(hugmesh-[A-Za-z0-9._-]+)=', re.M)


def kind_image_repos(generator_dir: str) -> "frozenset[str]":
    """The repos ``make kind-images ONLY=<repo>`` knows, read from the script that
    enforces it (an unknown name is refused there). Empty when the script is absent."""
    path = os.path.join(generator_dir or "", "scripts", "kind-load-images.sh")
    try:
        with open(path, encoding="utf-8") as fh:
            return frozenset(_KIND_IMAGE_RE.findall(fh.read()))
    except OSError:
        return frozenset()


def _rebuild_lines(lane: str, repo: str, kind_repos: "frozenset[str]", source_mode: str,
                   cluster: str) -> "list[str]":
    """How this repo's change gets onto the running mesh. Every target named here was
    read in the Makefile and scripts/kind-load-images.sh; ones that do not exist yet
    are not named."""
    if lane == LANE_KIND:
        lines = []
        if repo in kind_repos:
            lines.append(
                f"- On the kind lane ({cluster or 'hugmesh-local'}) the person rebuilds "
                f"ONE image from the hugmesh-generator checkout with: make kind-images "
                f"ONLY={repo}")
            lines.append(
                "- That command builds and loads the image but does NOT restart the "
                "pods that use it: they keep the old image until the person restarts "
                "them.")
        elif not kind_repos:
            lines.append(
                "- The list of images `make kind-images` builds could not be read from "
                "this Studio's generator checkout. Do not guess a command; tell the "
                "person which repository you changed.")
        else:
            lines.append(
                f"- {repo} is not one of the images `make kind-images` builds, so "
                "`ONLY=` would refuse it. Say so; do not guess another command.")
    else:
        lines = [
            "- The Docker lane has no single-service rebuild target in this repository: "
            "`make stack-build` builds every service and `make stack-up` builds and "
            "starts the whole stack. Both are for the person to run, not you.",
        ]
    if source_mode == "clone":
        lines.append(
            "- The mesh builds from .stack-src. Both lanes run `make stack-clone` first, "
            "which resets .stack-src checkouts that have no local commits, so a change "
            "must be committed there or applied to the person's own tree to survive.")
    else:
        lines.append("- The mesh builds from the person's own source tree, which the "
                     "Studio never fetches or resets.")
    return lines


def render_brief(*, lane: str, mesh: str, domains: Sequence[str], doors: Sequence[str],
                 repo: str, clone: str, branch: str, base_sha: str, source: str,
                 source_root: str, source_mode: str, source_dirty: int,
                 kind_repos: "frozenset[str]" = frozenset(), cluster: str = "",
                 first_task: str = "") -> str:
    """The text the session starts from (docs section 6.5, filled with real values)."""
    lane_word = ("kind (a local Kubernetes cluster" + (f" named {cluster}" if cluster else "")
                 + ")") if lane == LANE_KIND else "Docker (docker compose on this machine)"
    out = [
        "You are a small local model working in a scratch clone of one HugMesh "
        "repository, with no remote. A person will review everything you do.",
        "",
        "Where you are",
        f"- Work only in {clone} (repository {repo}, branch {branch}). It is a copy of "
        f"{source} made from commit {base_sha[:12]}; nothing you do here changes the "
        "real folder or the running mesh.",
    ]
    if source_dirty:
        out.append(f"- The real folder had {source_dirty} uncommitted change(s) when "
                   "this copy was made. They are NOT in your copy: you see only what "
                   "was committed.")
    origin = ("downloaded by the Studio into .stack-src" if source_mode == "clone"
              else "the person's own source tree")
    out += [
        f"- The code the mesh really builds from is under {source_root or 'the source folder'} "
        f"({origin}). It is read-only context: read it if you must, edit nothing there.",
        "",
        "The mesh",
        f"- Lane: {lane_word}.",
        f"- Mesh: {mesh or 'a local mesh'}.",
    ]
    if domains:
        out.append("- Domains: " + ", ".join(domains) + ".")
    if doors:
        out.append("- Doors: " + "; ".join(doors) + ".")
    out.append("- The Studio's running-mesh table lists the live doors and pods.")
    out += ["", "How a change gets onto the running mesh (the person does this, not you)"]
    out += _rebuild_lines(lane, repo, kind_repos, source_mode, cluster)
    out.append(f"- To hand a result back, leave it committed on {branch}. The person "
               f"reads `git diff {base_sha[:12]}..HEAD` and applies it to the real "
               "folder (`git format-patch` here, `git am` there).")
    out += ["", "Rules"]
    out += [f"- {rule}" for rule in RULES]
    out += ["", "First task: " + (first_task or
            "say in two sentences what this repository is (read its README), then "
            "wait for the person to tell you what to change. Do not start before.")]
    return "\n".join(out) + "\n"


# ── the plan ─────────────────────────────────────────────────────────────────────
@dataclass(frozen=True)
class Plan:
    """Everything a launch needs, decided. Nothing has been written yet."""
    agent: str
    model: str
    lane: str
    argv: "tuple[str, ...]"            # the ollama command, without the brief word
    uses_brief_argument: bool
    scratch: ScratchSpec
    brief: str
    env: "dict[str, str]"
    #: the whole line a terminal runs (cd, env -i ..., ollama launch ...)
    shell_command: str
    #: the same steps as a script a person can paste: clone, no remote, branch, launch
    paste_text: str
    title: str

    @property
    def cwd(self) -> str:
        return self.scratch.dest


def write_brief(plan: Plan) -> str:
    """Save the brief next to the copy (NOT inside it: an untracked file in the clone
    would make it look like it holds uncommitted work). Returns the path."""
    path = plan.scratch.brief_path
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(plan.brief)
    return path


def forbidden_in(argv: Sequence[str]) -> "list[str]":
    return [a for a in argv if a in FORBIDDEN_FLAGS]


def _env_prefix(env: "dict[str, str]") -> str:
    return "env -i " + " ".join(shlex.quote(f"{k}={v}") for k, v in sorted(env.items()))


def prepare(*, lane: str, mesh: str, domains: Sequence[str], doors: Sequence[str],
            repo: str, source: str, source_root: str, source_mode: str,
            generator_dir: str, pr: Probe, agent: str = "", model: str = "",
            environ=None, state_root: Optional[str] = None,
            runner: Optional[GitRunner] = None,
            now: Optional[Callable[[], float]] = None,
            kind_cluster: str = "") -> Plan:
    """Decide the launch for one app. Raises ScratchError when the source cannot be
    copied and ValueError when no agent or model can be chosen (``diagnose`` names why
    first; the card does not offer Start in those states)."""
    agent, model = choose_defaults(pr, agent, model)
    if not model:
        raise ValueError("no pulled model has the tools capability")
    spec = prepare_scratch(source, mesh, repo, state_root=state_root, runner=runner, now=now)
    env = build_env(environ)
    argv = ("ollama", "launch", agent, "--model", model)
    bad = forbidden_in(argv)
    if bad:                                           # a defect here, never a setting
        raise ValueError(f"refusing to build a command with {bad}")
    positional = AGENTS[agent]["prompt"] == "positional"
    brief = render_brief(
        lane=lane, mesh=mesh, domains=list(domains), doors=list(doors), repo=repo,
        clone=spec.dest, branch=spec.branch, base_sha=spec.source.head_sha,
        source=spec.source.path, source_root=source_root, source_mode=source_mode,
        source_dirty=spec.source.dirty_files, kind_repos=kind_image_repos(generator_dir),
        cluster=kind_cluster)
    launch_words = list(argv)
    if positional:
        launch_words += ["--", '"$(cat ' + shlex.quote(spec.brief_path) + ')"']
    # shlex.quote everything except the one deliberate command substitution
    quoted = " ".join(w if w.startswith('"$(cat') else shlex.quote(w) for w in launch_words)
    if positional:
        banner = ""
    else:
        banner = (f"printf '%s\\n' {shlex.quote('Brief for this session: ' + spec.brief_path)} "
                  f"{shlex.quote('Tell the agent to read that file first.')}; ")
    run_line = f"{banner}{_env_prefix(env)} {quoted}"
    shell_command = (
        f"cd {shlex.quote(spec.dest)} && {run_line}; st=$?; "
        "printf '\\n[agent exited with status %s - press Enter to close this window]\\n' "
        '"$st"; read -r _')
    setup = [
        f"git clone --no-hardlinks -- {shlex.quote(spec.source.path)} {shlex.quote(spec.dest)}",
        f"cd {shlex.quote(spec.dest)}",
        "git remote remove origin",
        f"git switch -c {shlex.quote(spec.branch)}",
    ] if not spec.reuse else [f"cd {shlex.quote(spec.dest)}"]
    paste_text = "\n".join(setup + [run_line]) + "\n"
    title = f"{AGENTS[agent]['label']} on {model} (local) - {repo}"
    return Plan(agent, model, lane, argv, positional, spec, brief, env, shell_command,
                paste_text, title)


# ── the terminal ─────────────────────────────────────────────────────────────────
#: Terminals tried in this order. Each entry builds the argv that runs ``bash
#: --noprofile --norc -c <command>`` in a new window with ``cwd`` as its folder. The
#: server-less flags (--disable-server, --separate) matter: they make the window a child
#: of THIS launch rather than of a server that already holds an environment.
def _t_xfce4(title, cwd, inner):
    return ["xfce4-terminal", "--disable-server", "--title", title,
            "--working-directory", cwd, "-x", *inner]


def _t_konsole(title, cwd, inner):
    return ["konsole", "--separate", "--workdir", cwd, "-p", f"tabtitle={title}",
            "-e", *inner]


def _t_kitty(title, cwd, inner):
    return ["kitty", "--title", title, "--directory", cwd, *inner]


def _t_gnome(title, cwd, inner):
    return ["gnome-terminal", f"--title={title}", f"--working-directory={cwd}", "--", *inner]


def _t_alacritty(title, cwd, inner):
    return ["alacritty", "--title", title, "--working-directory", cwd, "-e", *inner]


def _t_foot(title, cwd, inner):
    return ["foot", "--title", title, "--working-directory", cwd, *inner]


def _t_xterm(title, cwd, inner):
    return ["xterm", "-T", title, "-e", *inner]


def _t_alt(title, cwd, inner):
    return ["x-terminal-emulator", "-e", *inner]


TERMINALS: "tuple[tuple[str, Callable], ...]" = (
    ("xfce4-terminal", _t_xfce4), ("konsole", _t_konsole), ("kitty", _t_kitty),
    ("gnome-terminal", _t_gnome), ("alacritty", _t_alacritty), ("foot", _t_foot),
    ("xterm", _t_xterm), ("x-terminal-emulator", _t_alt),
)

#: ``run(argv, cwd, env) -> exit code, or None while it is still running after the
#: grace``. A launch failure reads as 127.
TerminalRunner = Callable[[Sequence[str], str, "dict[str, str]"], "Optional[int]"]


def _spawn_and_wait(argv, cwd, env):
    try:
        proc = subprocess.Popen(
            list(argv), cwd=cwd, env=env, stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        return 127
    try:
        return proc.wait(timeout=TERMINAL_WAIT_S)
    except subprocess.TimeoutExpired:
        # Not killed: a terminal still running IS the window we just opened.
        return None


@dataclass(frozen=True)
class Host:
    """The machine facts ``launch`` needs, replaceable by a test."""
    kind: str                       # "linux" | "wsl" | "windows" | "darwin"
    which: Callable[[str], Optional[str]] = shutil.which
    run: TerminalRunner = _spawn_and_wait
    environ: "dict[str, str]" = field(default_factory=lambda: dict(os.environ), repr=False)

    @classmethod
    def detect(cls) -> "Host":
        if os.name == "nt":
            return cls("windows")
        if sys.platform == "darwin":
            return cls("darwin")
        wsl, _ver = platform_info.detect_wsl()
        return cls("wsl" if wsl else "linux")


@dataclass(frozen=True)
class LaunchResult:
    opened: bool
    #: True when a terminal accepted the request (exit 0, or still running after the
    #: grace) — the same standard the folder and browser openers use. It is not proof
    #: that a window is on screen; the card says "look for the window".
    verified: bool
    terminal: str
    reason: str
    #: always set: the lines to paste into a shell if nothing opened
    command: str
    tried: "tuple[str, ...]" = ()


def launch(plan: Plan, host: Optional[Host] = None) -> LaunchResult:
    """Open a terminal window running the plan. The scratch clone must exist already
    (``create_scratch``). Never raises; on any failure the result carries the command
    for the person to run themselves."""
    host = host or Host.detect()
    paste = plan.paste_text
    if host.kind == "windows":
        return LaunchResult(False, False, "", "The Studio does not open a window on "
                            "Windows: the launch line needs a POSIX shell. Run the Studio "
                            "inside WSL2, or follow docs section 6 by hand.", paste)
    if host.kind == "darwin":
        return LaunchResult(False, False, "", "The Studio does not open a window on "
                            "macOS. Run the lines below in a Terminal window.", paste)
    env = host.environ
    if not (env.get("DISPLAY") or env.get("WAYLAND_DISPLAY")):
        where = ("WSL2 without a Linux desktop (WSLg)" if host.kind == "wsl"
                 else "no desktop session (DISPLAY and WAYLAND_DISPLAY are both unset)")
        return LaunchResult(False, False, "", f"No window can open: {where}. Run the "
                            "lines below in a terminal.", paste)
    inner = ["bash", "--noprofile", "--norc", "-c", plan.shell_command]
    term_env = build_env(env, terminal=True)
    tried: list[str] = []
    for name, build in TERMINALS:
        exe = host.which(name)
        if not exe:
            continue
        argv = build(plan.title, plan.cwd, inner)
        argv[0] = exe
        code = host.run(argv, plan.cwd, term_env)
        if code is None or code == 0:
            how = ("still running after %gs (it is the window)" % TERMINAL_WAIT_S
                   if code is None else "exited 0 after taking the request")
            return LaunchResult(True, True, name, f"{name} {how}", paste, tuple(tried))
        tried.append(f"{name} exited {code}")
    reason = ("no terminal took the request (" + "; ".join(tried) + ")" if tried
              else "no terminal emulator was found (looked for "
              + ", ".join(n for n, _ in TERMINALS) + ")")
    return LaunchResult(False, False, "", reason, paste, tuple(tried))

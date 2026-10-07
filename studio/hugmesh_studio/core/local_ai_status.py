"""What the local AI is doing right now, and a way to talk to it (Qt-free, stdlib only).

One module for three faces. The Studio window's prompt dock, the terminal UI's Local AI
screen and the plain command line (``--local-ai-status``, ``--local-ai-prompt``) all
read the same snapshot and call the same :func:`send_prompt`, and ``scripts/local-ai.sh``
runs this module for its ``status``, ``prompt`` and ``chat`` commands. A number that
differs between the faces would be a bug, so there is only one place it is computed.

THE STATE DIRECTORY. The worker that ``scripts/local-ai.sh`` starts writes everything
it does under ONE directory, and this module only reads it::

    $HUGMESH_LOCAL_AI_DIR, else $XDG_STATE_HOME/hugmesh/local-ai,
    else ~/.local/state/hugmesh/local-ai
        queue/{pending,running,done,logs}   one ``<stamp>-<name>.job`` file per job
        drafts/<repo>-<n>/{issue.md,agent.log,draft.diff,STATUS}
        status.json                          the worker's heartbeat (see below)
        worker.pid, ollama.pid

THE HEARTBEAT RULE. ``status.json`` carries a heartbeat the worker rewrites every few
seconds. A job in ``queue/running`` counts as running only while that heartbeat is
fresh and the recorded process is alive. A worker that was killed leaves a stale
``status.json`` and a stranded job file behind, and reading those as "running" would
tell the operator work is happening when nothing is. Such a job is reported as
``stalled`` instead.

LOOPBACK ONLY. Everything here talks to Ollama on this machine. ``OLLAMA_HOST`` is
honoured only when it names a loopback address; any other value is refused before a
socket is opened, system proxy settings are ignored, and redirects are not followed.
No account, no hosted service and no key is involved.
"""
from __future__ import annotations

import ipaddress
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass, field
from typing import Callable, Iterable

__all__ = [
    "quick_snapshot", "quick_line",
    "DEFAULT_HOST", "DEFAULT_MODEL", "DOC", "STALE_AFTER", "LocalAIError", "NotLoopback",
    "Job", "Snapshot", "StartResult", "state_dir", "ollama_host", "base_url",
    "read_snapshot", "summary_line", "send_prompt", "pick_model", "write_status",
    "start_assistant", "chat_loop", "format_status", "commands",
]

STATE_ENV = "HUGMESH_LOCAL_AI_DIR"
HOST_ENV = "OLLAMA_HOST"
MODEL_ENV = "LOCAL_AI_MODEL"
CTX_ENV = "LOCAL_AI_CTX"

DEFAULT_HOST = "127.0.0.1:11434"
DEFAULT_MODEL = "qwen3:8b"
DEFAULT_CTX = 16384

#: Seconds without a heartbeat after which a worker is no longer trusted. The worker
#: writes every 5 s, so this tolerates several missed beats and a slow disk.
STALE_AFTER = 30.0

DOC = "docs/LOCAL-AI-ASSISTANT.md"

#: Draft states (the first word of a draft's ``STATUS`` file) that mean it is over.
_OVER = ("applied", "does-not-apply", "no-diff", "no-issue", "no-ollama", "no-model",
         "no-checkout", "error")


class LocalAIError(RuntimeError):
    """A failure with a message fit to show a person as it stands."""


class NotLoopback(LocalAIError):
    """``OLLAMA_HOST`` names an address that is not on this machine."""


# ── the state directory ──────────────────────────────────────────────────────────────
def state_dir(env: dict | None = None) -> str:
    """Where the local-AI worker keeps its state (same rule as scripts/local-ai.sh)."""
    env = os.environ if env is None else env
    explicit = env.get(STATE_ENV)
    if explicit:
        return explicit
    base = env.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "hugmesh", "local-ai")


# ── the loopback rule ────────────────────────────────────────────────────────────────
def ollama_host(env: dict | None = None) -> tuple[str, int]:
    """``(host, port)`` of the Ollama to talk to, loopback only.

    Accepts the spellings Ollama itself accepts (``127.0.0.1:11434``, ``localhost``,
    ``http://[::1]:11434``, ``:11434``). No name is ever resolved: ``localhost`` is
    mapped to 127.0.0.1 here, and every other name is refused, because a name that
    resolves differently on the next lookup is not a loopback guarantee.

    :raises NotLoopback: for anything that is not 127.0.0.0/8 or ``::1``.
    """
    env = os.environ if env is None else env
    raw = (env.get(HOST_ENV) or "").strip() or DEFAULT_HOST
    shown = raw
    if "://" in raw:
        scheme, _, raw = raw.partition("://")
        if scheme.lower() != "http":
            raise NotLoopback(f"{HOST_ENV}={shown} is not a plain http address on this "
                              "machine; the local assistant talks to a local Ollama only.")
    raw = raw.split("/", 1)[0]
    host, port = raw, "11434"
    if raw.startswith("["):                                  # [::1]:11434
        end = raw.find("]")
        host = raw[1:end] if end > 0 else raw
        rest = raw[end + 1:] if end > 0 else ""
        if rest.startswith(":"):
            port = rest[1:] or port
    elif raw.count(":") == 1:                                # name-or-v4:port
        host, port = raw.split(":")
    elif raw.count(":") > 1:                                 # bare ::1
        host = raw
    host = host or "127.0.0.1"
    if host.lower() == "localhost":
        host = "127.0.0.1"
    try:
        loop = ipaddress.ip_address(host).is_loopback
    except ValueError:
        loop = False
    if not loop:
        raise NotLoopback(
            f"{HOST_ENV}={shown} is not a loopback address. The local assistant only talks "
            "to an Ollama on this machine: unset it, or use 127.0.0.1:11434.")
    try:
        number = int(port)
        if not 0 < number < 65536:
            raise ValueError(port)
    except ValueError:
        raise NotLoopback(f"{HOST_ENV}={shown} has no usable port.") from None
    return host, number


def _hostport(host: str, port: int) -> str:
    return f"[{host}]:{port}" if ":" in host else f"{host}:{port}"


def base_url(env: dict | None = None) -> str:
    host, port = ollama_host(env)
    return "http://" + _hostport(host, port)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """A loopback server must not be able to bounce a request off this machine."""

    def redirect_request(self, *_a, **_k):                   # noqa: D401
        return None


def _opener() -> urllib.request.OpenerDirector:
    # ProxyHandler({}) = ignore http_proxy/HTTP_PROXY: a request to 127.0.0.1 must not
    # be handed to a proxy that sits on another machine.
    return urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())


def _get_json(env: dict | None, path: str, timeout: float) -> dict:
    with _opener().open(base_url(env) + path, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace") or "{}")


# ── the snapshot ─────────────────────────────────────────────────────────────────────
@dataclass
class Job:
    """One row of "current work": a queued/running job, a draft, or a Studio build."""
    kind: str                    # "queue" | "draft" | "build"
    id: str
    title: str
    state: str                   # pending running stalled applied does-not-apply ...
    detail: str = ""
    path: str = ""               # the draft directory, job file or build directory
    diff_path: str = ""          # a non-empty draft.diff, when there is one
    updated: float = 0.0


@dataclass
class Snapshot:
    taken: float = 0.0
    state_dir: str = ""
    host: str = ""                       # "" when OLLAMA_HOST was refused
    ollama_installed: bool = False
    ollama_up: bool = False
    models: list = field(default_factory=list)
    loaded: list = field(default_factory=list)
    worker: str = "stopped"              # running | stalled | stopped
    worker_pid: int = 0
    heartbeat_age: float | None = None   # seconds, None = never beat
    counts: dict = field(default_factory=dict)
    jobs: list = field(default_factory=list)
    problem: str = ""
    fix: str = ""
    doc: str = DOC
    summary: str = ""
    checked: bool = True                 # False: built from status.json, no request was made

    @property
    def ok(self) -> bool:
        return not self.problem

    def to_dict(self) -> dict:
        d = asdict(self)
        d["schema"] = 1
        d["ok"] = self.ok
        return d

    def of_kind(self, kind: str) -> list:
        return [j for j in self.jobs if j.kind == kind]


def _read_text(path: str, limit: int = 4000) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read(limit)
    except OSError:
        return ""


def _read_json(path: str) -> dict:
    try:
        data = json.loads(_read_text(path, 1 << 20) or "{}")
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def _pid_alive(pid: int, needle: str = "") -> bool:
    """True when ``pid`` exists and (where /proc says so) is still OUR process: a pid
    that the system reused for something else must not make a dead worker look alive."""
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    if needle:
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as fh:
                return needle.encode() in fh.read()
        except OSError:
            return True              # no /proc (macOS, Windows): the signal check stands
    return True


def _dir_names(path: str, suffix: str = "") -> list:
    try:
        return sorted(n for n in os.listdir(path) if n.endswith(suffix))
    except OSError:
        return []


def _job_title(name: str, content: str) -> str:
    parts = content.split()
    if len(parts) == 3 and parts[0] == "draft":
        return f"draft {parts[1]}#{parts[2]}"
    return name


def _queue_jobs(root: str, worker_alive: bool) -> tuple[list, dict]:
    jobs, counts = [], {"pending": 0, "running": 0, "stalled": 0, "done": 0, "failed": 0}
    q = os.path.join(root, "queue")
    for state in ("pending", "running"):
        for fn in _dir_names(os.path.join(q, state), ".job"):
            path = os.path.join(q, state, fn)
            shown = state
            if state == "running":
                shown = "running" if worker_alive else "stalled"
            counts[shown] += 1
            try:
                updated = os.path.getmtime(path)
            except OSError:
                updated = 0.0
            jobs.append(Job("queue", fn[:-4], _job_title(fn[:-4], _read_text(path).strip()),
                            shown, path=path, updated=updated))
    done = _dir_names(os.path.join(q, "done"), ".result")
    counts["done"] = len(done)
    for fn in done:
        if _read_text(os.path.join(q, "done", fn), 200).startswith("rc=") and \
                not _read_text(os.path.join(q, "done", fn), 200).startswith("rc=0"):
            counts["failed"] += 1
    return jobs, counts


def _drafts(root: str) -> list:
    base = os.path.join(root, "drafts")
    rows = []
    for name in _dir_names(base):
        d = os.path.join(base, name)
        status_path = os.path.join(d, "STATUS")
        if not os.path.isfile(status_path):
            continue
        first = (_read_text(status_path, 400).strip().splitlines() or [""])[0]
        word, _, rest = first.partition(" ")
        diff = os.path.join(d, "draft.diff")
        try:
            has_diff = os.path.getsize(diff) > 0
            updated = os.path.getmtime(status_path)
        except OSError:
            has_diff, updated = False, 0.0
        title = ""
        for line in _read_text(os.path.join(d, "issue.md"), 400).splitlines():
            if line.startswith("# "):
                title = line[2:].strip()
                break
        rows.append(Job("draft", name, (name + "  " + title).strip(), word or "unknown",
                        rest.strip(), d, diff if has_diff else "", updated))
    rows.sort(key=lambda j: j.updated, reverse=True)
    return rows[:50]


def _studio_builds() -> list:
    """The Studio's own builds that are running right now (read from its session records,
    so a build started by another Studio window or the terminal UI shows up too)."""
    try:
        from . import build_sessions
        sessions = build_sessions.load_all()
        return [Job("build", s.id, s.label or s.id, "running",
                    f"started {s.started or s.created or '?'}", s.workdir,
                    updated=0.0)
                for s in sessions if build_sessions.is_active(s)][:10]
    except Exception:                                        # an unreadable record is not news
        return []


def _probe(env: dict | None, timeout: float) -> tuple[bool, list, list, str]:
    """``(up, installed models, loaded models, refusal)`` — never raises."""
    try:
        tags = _get_json(env, "/api/tags", timeout)
    except NotLoopback as exc:
        return False, [], [], str(exc)
    except (OSError, ValueError, urllib.error.URLError):
        return False, [], [], ""
    models = [m.get("name", "") for m in tags.get("models", []) if isinstance(m, dict)]
    try:
        ps = _get_json(env, "/api/ps", timeout)
        loaded = [m.get("name", "") for m in ps.get("models", []) if isinstance(m, dict)]
    except (OSError, ValueError, urllib.error.URLError):
        loaded = []
    return True, [m for m in models if m], [m for m in loaded if m], ""


def read_snapshot(env: dict | None = None, *, now: float | None = None,
                  probe: Callable[[], tuple] | None = None,
                  builds: Callable[[], list] | None = None,
                  timeout: float = 2.0) -> Snapshot:
    """Read the local-AI state directory, ask the loopback Ollama what it has loaded
    and list the Studio's running builds. Never raises.

    ``probe`` and ``builds`` replace the two outside lookups (tests, and callers that
    already hold the answer); ``now`` pins the clock for the heartbeat rule.
    """
    env = os.environ if env is None else env
    now = time.time() if now is None else now
    root = state_dir(env)
    snap = Snapshot(taken=now, state_dir=root)
    snap.ollama_installed = shutil.which("ollama") is not None
    try:
        snap.host = _hostport(*ollama_host(env))
    except NotLoopback as exc:
        snap.problem = str(exc)
        snap.fix = f"Unset {HOST_ENV}, or set it to 127.0.0.1:11434."
    if snap.host:
        up, models, loaded, _refusal = (probe() if probe else _probe(env, timeout))
        snap.ollama_up, snap.models, snap.loaded = bool(up), list(models), list(loaded)

    st = _read_json(os.path.join(root, "status.json"))
    pid = st.get("pid") if isinstance(st.get("pid"), int) else 0
    beat = st.get("heartbeat") if isinstance(st.get("heartbeat"), (int, float)) else None
    snap.worker_pid = pid
    snap.heartbeat_age = None if beat is None else max(0.0, now - float(beat))
    alive = _pid_alive(pid, "local-ai") if pid else False
    if alive and snap.heartbeat_age is not None and snap.heartbeat_age <= STALE_AFTER:
        snap.worker = "running"
    elif alive:
        snap.worker = "stalled"
    else:
        snap.worker = "stopped"

    queue_jobs, counts = _queue_jobs(root, snap.worker == "running")
    drafts = _drafts(root)
    builds_rows = (builds() if builds else _studio_builds())
    counts["drafts"] = len(drafts)
    counts["builds"] = len(builds_rows)
    snap.counts = counts
    snap.jobs = queue_jobs + drafts + list(builds_rows)

    if not snap.problem:
        if not snap.ollama_up:
            if snap.ollama_installed:
                snap.problem = f"Ollama is installed but is not answering on {snap.host}."
                snap.fix = "Start it with: scripts/local-ai.sh up"
            else:
                snap.problem = "Ollama is not installed on this machine."
                snap.fix = ("Install it (see the link), then run: scripts/local-ai.sh up")
        elif not snap.models:
            snap.problem = "Ollama is running but no model is pulled."
            snap.fix = f"Pull one: ollama pull {DEFAULT_MODEL}"
    snap.summary = summary_line(snap)
    return snap


def quick_snapshot(env: dict | None = None, *, now: float | None = None) -> Snapshot:
    """A snapshot that makes NO network call: the worker's last ``status.json`` stands in
    for the probe. For a status line that is redrawn on every screen of a terminal
    session, where a fresh HTTP request each time would be slow and would make a test
    depend on the host it runs on. The Local AI screen takes the live one instead."""
    env = os.environ if env is None else env
    st = _read_json(os.path.join(state_dir(env), "status.json"))
    loaded = [m for m in (st.get("model_loaded") or []) if isinstance(m, str)]
    up = bool(st.get("ollama_up"))
    snap = read_snapshot(env, now=now, builds=lambda: [],
                         probe=lambda: (up, loaded or (["(unknown)"] if up else []), loaded, ""))
    snap.checked = False
    return snap


def quick_line(env: dict | None = None, *, now: float | None = None) -> str:
    """One line for a terminal's bottom row: what ``quick_snapshot`` knows, honest about
    not having asked the server just now."""
    snap = quick_snapshot(env, now=now)
    if snap.worker == "stopped" and not snap.ollama_up:
        pending = snap.counts.get("pending", 0)
        return ("Local AI: not running" + (f", {pending} queued" if pending else "")
                + " (local-ai: check it, start it, ask it)")
    return snap.summary


def summary_line(s: Snapshot) -> str:
    """The one-line status: ``Local AI: ready, qwen3:8b loaded, 2 queued, 1 running``."""
    if s.problem and not s.ollama_up:
        what = s.problem.split(". ")[0].rstrip(".")
        return f"Local AI: {what}"
    bits = ["ready" if s.models else "no model pulled"]
    bits.append((" + ".join(s.loaded) + " loaded") if s.loaded else "no model loaded")
    pending = s.counts.get("pending", 0)
    running = s.counts.get("running", 0) + s.counts.get("builds", 0)
    stalled = s.counts.get("stalled", 0)
    if pending:
        bits.append(f"{pending} queued")
    if running:
        bits.append(f"{running} running")
    if stalled:
        bits.append(f"{stalled} stalled (worker not beating)")
    if not (pending or running or stalled):
        bits.append("idle")
    elif pending and s.worker != "running":
        bits.append("worker stopped" if s.worker == "stopped" else "worker stalled")
    return "Local AI: " + ", ".join(bits)


def commands(generator_dir: str = ".") -> dict:
    """The exact commands a person can run, for screens that cannot start them."""
    script = os.path.join(os.path.abspath(generator_dir), "scripts", "local-ai.sh")
    return {"start": f"{script} start", "chat": f"{script} chat",
            "watch": f"{script} watch", "todo": f"{script} todo 6 --watch",
            "stop": f"{script} stop"}


def format_status(s: Snapshot) -> str:
    """The plain-text screen shared by the command line, the text UI and ``watch``."""
    lines = [s.summary, ""]
    lines.append(f"  server   {s.host or '(refused)'} "
                 + ("answering" if s.ollama_up else "not answering"))
    lines.append("  models   " + (", ".join(s.models) if s.models else "(none pulled)"))
    lines.append("  loaded   " + (", ".join(s.loaded) if s.loaded else "(none)"))
    beat = "never" if s.heartbeat_age is None else f"{int(s.heartbeat_age)}s ago"
    lines.append(f"  worker   {s.worker}" + (f" (pid {s.worker_pid})" if s.worker_pid else "")
                 + f", last heartbeat {beat}")
    c = s.counts
    lines.append(f"  queue    pending {c.get('pending', 0)}, running {c.get('running', 0)}, "
                 f"stalled {c.get('stalled', 0)}, done {c.get('done', 0)}")
    for kind, head in (("queue", "queued and running jobs"), ("build", "Studio builds running")):
        rows = s.of_kind(kind)
        if rows:
            lines += ["", head + ":"]
            lines += [f"  {j.state:<9} {j.title}" for j in rows]
    drafts = s.of_kind("draft")
    if drafts:
        lines += ["", "drafts (newest first; review the diff yourself):"]
        for j in drafts[:12]:
            tail = f"  [{j.detail}]" if j.detail else ""
            lines.append(f"  {j.state:<14} {j.title[:70]}{tail}")
    lines += ["", f"  state    {s.state_dir}"]
    if s.problem:
        lines += ["", "Problem: " + s.problem, "  Fix:   " + s.fix, "  See:   " + s.doc]
    return "\n".join(lines)


# ── the worker's heartbeat ───────────────────────────────────────────────────────────
def write_status(pid: int, running: str = "", env: dict | None = None,
                 now: float | None = None) -> str:
    """Rewrite ``status.json`` (atomically). Called by the worker every few seconds."""
    env = os.environ if env is None else env
    root = state_dir(env)
    os.makedirs(root, exist_ok=True)
    snap = read_snapshot(env, now=now, builds=lambda: [])
    now = snap.taken
    body = {"pid": pid, "heartbeat": now,
            "heartbeat_iso": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now)),
            "ollama_up": snap.ollama_up, "model_loaded": snap.loaded,
            "running": running, "counts": snap.counts}
    path = os.path.join(root, "status.json")
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(body, fh, sort_keys=True)
    os.replace(tmp, path)
    return path


# ── talking to the model ─────────────────────────────────────────────────────────────
def pick_model(env: dict | None = None, available: Iterable[str] | None = None) -> str:
    """``$LOCAL_AI_MODEL``, else qwen3:8b when pulled, else the first pulled model."""
    env = os.environ if env is None else env
    asked = (env.get(MODEL_ENV) or "").strip()
    if asked:
        return asked
    names = [n for n in (available or []) if n]
    if DEFAULT_MODEL in names or not names:
        return DEFAULT_MODEL
    usable = [n for n in names if "embed" not in n.lower()]
    return (usable or names)[0]


def _down_message(env: dict | None) -> str:
    host = _hostport(*ollama_host(env))
    return (f"Ollama is not answering on {host}. Start it with scripts/local-ai.sh up "
            f"(see {DOC}).")


def send_prompt(text: str, model: str | None = None, *, env: dict | None = None,
                timeout: float = 120.0, total_timeout: float = 900.0,
                on_chunk: Callable[[str], None] | None = None,
                history: list | None = None, system: str | None = None,
                should_stop: Callable[[], bool] | None = None,
                options: dict | None = None) -> str:
    """Ask the loopback Ollama and return the whole answer.

    The answer streams: ``on_chunk`` gets each piece as it arrives, so a screen can show
    it growing. ``timeout`` is the longest silence tolerated between pieces and
    ``total_timeout`` the longest the whole answer may take. ``should_stop`` is polled
    between pieces; when it turns true the partial answer is returned. Thinking mode is
    off: the person asked a question, not for the model's notes.

    :raises LocalAIError: with a sentence that says what to do (down, no such model,
        refused host, timeout). :raises NotLoopback: for a non-loopback ``OLLAMA_HOST``.
    """
    env = os.environ if env is None else env
    url = base_url(env)                                     # the loopback rule, first
    if not model:
        try:
            tags = _get_json(env, "/api/tags", 5).get("models") or []
        except (OSError, ValueError, urllib.error.URLError):
            raise LocalAIError(_down_message(env)) from None
        model = pick_model(env, [m.get("name", "") for m in tags if isinstance(m, dict)])
    messages = ([{"role": "system", "content": system}] if system else []) \
        + list(history or []) + [{"role": "user", "content": text}]
    opts = {"num_ctx": int(env.get(CTX_ENV) or DEFAULT_CTX), "temperature": 0.2}
    opts.update(options or {})
    body = json.dumps({"model": model, "messages": messages, "stream": True,
                       "think": False, "options": opts}).encode()
    req = urllib.request.Request(url + "/api/chat", body,
                                 {"Content-Type": "application/json"})
    deadline = time.monotonic() + total_timeout
    out: list[str] = []
    try:
        with _opener().open(req, timeout=timeout) as resp:
            for raw in resp:
                if should_stop is not None and should_stop():
                    break
                if time.monotonic() > deadline:
                    raise LocalAIError(f"The model took longer than {int(total_timeout)} "
                                       "seconds to answer; stopped waiting.")
                if not raw.strip():
                    continue
                try:
                    piece = json.loads(raw)
                except ValueError:
                    continue
                if piece.get("error"):
                    raise LocalAIError(f"Ollama said: {piece['error']}")
                chunk = (piece.get("message") or {}).get("content") or ""
                if chunk:
                    out.append(chunk)
                    if on_chunk is not None:
                        on_chunk(chunk)
                if piece.get("done"):
                    break
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            raise LocalAIError(f"The model {model} is not pulled. Run: ollama pull {model}") from None
        raise LocalAIError(f"Ollama answered HTTP {exc.code}.") from None
    except TimeoutError:
        raise LocalAIError(f"No answer for {int(timeout)} seconds; the model may still be "
                           "loading. Try again in a minute.") from None
    except (urllib.error.URLError, OSError) as exc:
        if "timed out" in str(exc):
            raise LocalAIError(f"No answer for {int(timeout)} seconds; the model may still "
                               "be loading. Try again in a minute.") from None
        raise LocalAIError(_down_message(env)) from None
    return "".join(out)


# ── starting the assistant ───────────────────────────────────────────────────────────
@dataclass
class StartResult:
    ok: bool
    message: str
    command: str = ""


def start_assistant(generator_dir: str, *, env: dict | None = None,
                    spawn: Callable | None = None) -> StartResult:
    """Start the loopback Ollama and the queue worker, detached, and return at once.

    Runs ``scripts/local-ai.sh start``. The caller does not wait: the snapshot shows the
    server come up. MERGE POINT: the local-agent card (hugmesh-generator#695) adds a
    terminal launcher for an interactive agent chat; when that lands it owns "open a
    chat window" and this keeps only the server-and-worker half.
    """
    env = dict(os.environ if env is None else env)
    script = os.path.join(generator_dir, "scripts", "local-ai.sh")
    cmd = commands(generator_dir)["start"]
    if not os.path.isfile(script):
        return StartResult(False, f"{script} is missing; run it from a hugmesh-generator "
                                  f"checkout (see {DOC}).", cmd)
    root = state_dir(env)
    try:
        os.makedirs(root, exist_ok=True)
        log = open(os.path.join(root, "start.log"), "ab")
    except OSError as exc:
        return StartResult(False, f"Cannot write {root}: {exc}", cmd)
    try:
        (spawn or subprocess.Popen)(
            ["bash", script, "start"], stdin=subprocess.DEVNULL, stdout=log, stderr=log,
            env=env, start_new_session=True)
    except OSError as exc:
        return StartResult(False, f"Could not start it: {exc}. Run it yourself: {cmd}", cmd)
    finally:
        log.close()
    return StartResult(True, "Starting the local assistant; the status line updates "
                             "when the server answers.", cmd)


# ── an interactive prompt loop ───────────────────────────────────────────────────────
def chat_loop(inp, out, env: dict | None = None, model: str | None = None) -> int:
    """A prompt loop against the local model. ``/quit`` leaves, ``/clear`` forgets."""
    env = os.environ if env is None else env
    try:
        _get_json(env, "/api/tags", 5)
    except NotLoopback as exc:
        print(str(exc), file=out)
        return 1
    except (OSError, ValueError, urllib.error.URLError):
        print(_down_message(env), file=out)
        return 1
    history: list = []
    shown = model or env.get(MODEL_ENV) or DEFAULT_MODEL
    print(f"Local AI chat with {shown}. Everything stays on this machine. "
          "/clear forgets the conversation, /quit leaves.", file=out)
    while True:
        out.write("> ")
        out.flush()
        line = inp.readline()
        if line == "":
            print(file=out)
            return 0
        line = line.strip()
        if line in ("/quit", "/exit", "/q"):
            return 0
        if line == "/clear":
            history.clear()
            print("(forgotten)", file=out)
            continue
        if not line:
            continue
        try:
            answer = send_prompt(line, model, env=env, history=history,
                                 on_chunk=lambda c: (out.write(c), out.flush()))
        except LocalAIError as exc:
            print(f"\n{exc}", file=out)
            continue
        print(file=out)
        history += [{"role": "user", "content": line},
                    {"role": "assistant", "content": answer}]
        del history[:-40]


# ── python -m hugmesh_studio.core.local_ai_status ────────────────────────────────────
def main(argv: list | None = None, *, out=None, err=None, inp=None) -> int:
    """The command line behind ``scripts/local-ai.sh`` and the Studio's flags."""
    out = out or sys.stdout
    err = err or sys.stderr
    inp = inp or sys.stdin
    args = list(sys.argv[1:] if argv is None else argv)
    cmd = args.pop(0) if args else "status"
    if cmd == "status":
        snap = read_snapshot()
        if "--brief" in args:
            print(snap.summary, file=out)
            return 0 if snap.ok else 1
        print(json.dumps(snap.to_dict(), sort_keys=True) if "--json" in args
              else format_status(snap), file=out)
        return 0 if snap.ok else 1
    if cmd == "prompt":
        text = " ".join(a for a in args if not a.startswith("--model="))
        model = next((a.split("=", 1)[1] for a in args if a.startswith("--model=")), None)
        if not text.strip():
            print("usage: prompt TEXT", file=err)
            return 2
        try:
            send_prompt(text, model, on_chunk=lambda c: (out.write(c), out.flush()))
        except LocalAIError as exc:
            print(str(exc), file=err)
            return 1
        print(file=out)
        return 0
    if cmd == "chat":
        return chat_loop(inp, out)
    if cmd == "host":                                        # for the shell: host:port, checked
        try:
            print(_hostport(*ollama_host()), file=out)
        except NotLoopback as exc:
            print(str(exc), file=err)
            return 2
        return 0
    if cmd == "dir":
        print(state_dir(), file=out)
        return 0
    if cmd == "ping":                                        # 0 = the loopback Ollama answers
        try:
            _get_json(None, "/api/tags", 3)
        except (LocalAIError, OSError, ValueError, urllib.error.URLError):
            return 1
        return 0
    if cmd == "write-status":
        pid = int(args[0]) if args and args[0].isdigit() else os.getpid()
        write_status(pid, args[1] if len(args) > 1 else "")
        return 0
    print("usage: local_ai_status [status [--json] | prompt TEXT | chat | host | dir | "
          "ping | write-status PID [JOB]]", file=err)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())

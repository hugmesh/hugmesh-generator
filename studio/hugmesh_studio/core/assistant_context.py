"""Where the person is, and what the local assistant may never see (Qt-free, stdlib only).

The Studio's local assistant answers from three things: a primer about HugMesh
(core/agent_context.primer_text), snippets of the project's own docs
(core/assistant_docs) and the facts of the page the person is on. This module is the
third one, and the privacy wall every fact and every log line passes through.

TWO HALVES, SO THE WINDOW THREAD NEVER READS A FILE. :class:`Where` is frozen. The
PAGE half (face, page title, step, the domain on screen, the tab, the brand rows, the
domain rows, what the dock already knows is running) is cheap attribute reads the
window thread does when the person presses Send. The STATE half (:func:`build_rows`,
:func:`mesh_rows`, :func:`assistant_rows`, :func:`code_rows`) reads files and is
collected on the worker thread right before the question goes out, each collector
under a one-second wall budget (:func:`collect`); a slow or failing collector yields
one row "(unavailable)", never a stall. :meth:`Where.with_state` completes the object.

NOTHING SECRET ENTERS. Every row goes through :func:`scrub_rows`: a key that matches
:data:`SECRET_KEY_RE` keeps its name and loses its value ("(set, never shown)"), and
every value goes through :func:`redact`, which blanks the shapes secrets take in a log
(private-key blocks, bearer tokens, ``password=...``, Tailscale and GitHub and AWS and
Vault tokens, JWTs, database URLs with credentials). :func:`render_where` asserts that
what it renders is what ``redact`` would leave. Files that hold secrets are listed in
:data:`DENY_PATHS` and :func:`is_denied_path` says whether a path is one of them; the
docs index, the code-edit module and the collectors here call it before opening
anything. The local-only folder (``~/.local/share/hugmesh-local-only``) is named here
ONLY to be refused: nothing in this package opens it.
"""
from __future__ import annotations

import fnmatch
import math
import os
import re
import threading
import time
from dataclasses import dataclass, field, replace
from typing import Any, Callable, Iterable, Optional

__all__ = [
    "Where", "Row", "tokens", "render_where", "redact", "scrub_rows", "DENY_PATHS",
    "DENY_BASENAME_GLOBS", "SECRET_KEY_RE", "is_denied_path", "denied_reason",
    "build_rows", "mesh_rows", "assistant_rows", "code_rows", "collect", "COLLECT_BUDGET_S",
    "FACE_WORDS", "UNAVAILABLE", "domain_rows_from", "brand_rows_from",
    "SECRET_FIELD_NAMES", "WHERE_TOKEN_CAP",
]

#: One token estimate for every budget in the assistant: paths and JSON tokenise
#: worse than prose, and chars/4 under-counts them, so this is deliberately generous.
#: Ollama truncates from the FRONT (the primer) when ``num_ctx`` is exceeded, so an
#: estimate that is too low is the dangerous direction.
def tokens(text: str) -> int:
    return int(math.ceil(len(text or "") / 3.2))


WHERE_TOKEN_CAP = 500
COLLECT_BUDGET_S = 1.0
UNAVAILABLE = "(unavailable)"
NEVER_SHOWN = "(set, never shown)"
FACE_WORDS = {"gui": "Studio window (gui)", "tui": "terminal (tui)", "cli": "command line (cli)"}

#: ImageConfig / bootstrap keys that never enter a Where even when they are not
#: secret by name: bulky (a whole stylesheet) or key material by role.
SECRET_FIELD_NAMES: tuple[str, ...] = (
    "auth_key", "egress_vpn_conf", "login_theme_css", "login_look", "keyzip", "keys_usb",
    "secureboot_key", "local_pass", "luks_pass", "user_password", "root_password",
    "vault_token", "idp_client_secret", "secret_files",
)

#: A key whose VALUE is never rendered (the name is kept so the model knows it is set).
SECRET_KEY_RE = re.compile(
    r"(pass(word)?|passwd|secret|token|auth_?key|api_?key|private|unseal|kubeconfig|luks"
    r"|jwks_?secret|client_secret|cookie|session_id)", re.I)

# ── the deny-list ────────────────────────────────────────────────────────────────────
#: (pattern, what it is). Patterns are relative to a ROOT the caller names (the generator
#: checkout, the Studio state dir, the home dir, a build workdir) or absolute with ``~``.
#: ``**`` means "anywhere below". Matched by realpath prefix or by basename glob
#: (:func:`is_denied_path`). docs/LOCAL-AI-ASSISTANT.md section 12 lists every entry
#: and a test keeps the two equal.
DENY_PATHS: tuple[tuple[str, str], ...] = (
    ("<generator>/keys-out/**", "generated node keys"),
    ("<generator>/keys-*/", "generated node keys (any keys-* folder)"),
    ("<generator>/.e2e-credentials", "e2e account credentials"),
    ("<generator>/tests/stack/.env", "the local stack's environment"),
    ("~/.hugmesh/mesh-node/.env", "the mesh node's environment"),
    ("~/.hugmesh/keyzip/**", "admin key-zips"),
    ("~/.config/hugmesh-studio/local-login/roles.json", "local sign-in roles"),
    ("<state>/**/secrets.json", "a build's secrets"),
    ("<workdir>/secrets.json", "a build's secrets"),
    ("<workdir>/report.json", "a build's report (carries seeded credentials)"),
    ("<workdir>/.cli.json", "a build's argv (carries secrets)"),
    ("**/vault/token", "a Vault token"),
    ("**/vault/unseal-key", "a Vault unseal key"),
    ("*.kubeconfig", "a cluster credential"),
    ("$KUBECONFIG", "the cluster credential the shell names"),
    ("**/*.pem", "key or certificate material"),
    ("**/*.key", "key material"),
    ("**/id_*", "SSH keys"),
    ("**/.env", "an environment file"),
    ("~/.local/share/hugmesh-local-only/**", "the operator's local-only folder"),
    ("<secret_files>/**", "a secret-files staging folder"),
    ("<egress_vpn_conf>", "the egress VPN provider file"),
)

#: Basenames refused wherever they are (derived from DENY_PATHS, kept explicit so a
#: test can plant one of each).
DENY_BASENAME_GLOBS: tuple[str, ...] = (
    "secrets.json", "report.json", ".cli.json", "*.kubeconfig", "*.pem", "*.key", "id_*",
    ".env", ".e2e-credentials", "roles.json",
)
_DENY_DIR_WORDS: tuple[str, ...] = ("keys-out", "keyzip", "hugmesh-local-only", "secret-files",
                                    "secret_files")
_DENY_TAILS: tuple[str, ...] = (os.path.join("vault", "token"), os.path.join("vault", "unseal-key"),
                                os.path.join("local-login", "roles.json"),
                                os.path.join("mesh-node", ".env"),
                                os.path.join("tests", "stack", ".env"))


def _real(path: str) -> str:
    try:
        return os.path.realpath(os.path.expanduser(path))
    except (OSError, ValueError):
        return path


def denied_reason(path: str, *, generator_dir: str = "", state_dir: str = "",
                  extra: Iterable[str] = (), environ: Optional[dict] = None) -> str:
    """Why ``path`` must not be opened ("" when it may be). ``extra`` names more
    refused files or folders (an ``egress_vpn_conf``, a secret-files staging dir)."""
    environ = os.environ if environ is None else environ
    if not path:
        return ""
    real = _real(path)
    base = os.path.basename(real.rstrip(os.sep))
    for glob in DENY_BASENAME_GLOBS:
        if fnmatch.fnmatchcase(base, glob):
            return f"{base} holds secrets"
    parts = real.split(os.sep)
    for word in _DENY_DIR_WORDS:
        if word in parts:
            return f"{word} holds secrets"
    if any(p.startswith("keys-") for p in parts[:-1]) or base.startswith("keys-"):
        return "a keys-* folder holds generated node keys"
    for tail in _DENY_TAILS:
        if real.endswith(os.sep + tail) or real == tail:
            return f"{tail} holds secrets"
    kube = (environ.get("KUBECONFIG") or "").strip()
    for cand in [c for c in kube.split(os.pathsep) if c]:
        if real == _real(cand):
            return "the cluster credential the shell names holds secrets"
    for cand in extra:
        if cand:
            c = _real(cand)
            if real == c or real.startswith(c.rstrip(os.sep) + os.sep):
                return "that file holds secrets"
    return ""


def is_denied_path(path: str, **kw) -> bool:
    """True when the assistant must not open ``path`` (see :data:`DENY_PATHS`)."""
    return bool(denied_reason(path, **kw))


# ── redaction ────────────────────────────────────────────────────────────────────────
_REDACT_RULES: tuple[tuple[re.Pattern, str], ...] = (
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----",
                re.S), "[redacted private key]"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----[^\n]*"), "[redacted private key]"),
    (re.compile(r"Bearer [A-Za-z0-9._\-]+"), "Bearer [redacted]"),
    (re.compile(r"(?i)\b(password|passwd|secret|token|api[_-]?key|auth[_-]?key|authkey"
                r"|client_secret|ts_authkey|tskey)\s*[=:]\s*(?!\[redacted\]|\(set,)\S+"),
     r"\1=[redacted]"),
    (re.compile(r"tskey-[a-z]+-[A-Za-z0-9\-]+"), "[redacted]"),
    (re.compile(r"ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}"), "[redacted]"),
    (re.compile(r"AKIA[0-9A-Z]{16}"), "[redacted]"),
    (re.compile(r"hvs\.[A-Za-z0-9]{20,}"), "[redacted]"),
    (re.compile(r"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"), "[redacted]"),
    (re.compile(r"(postgres(?:ql)?://[^:/\s]+:)[^@\s]+@"), r"\1[redacted]@"),
    (re.compile(r"(r2dbc:[^\s:]*:[^@\s/]*?)(?<=:)[^@\s]+@"), r"\1[redacted]@"),
    (re.compile(r"/home/[^/\s]+/\.local/share/hugmesh-local-only[^\s]*"), "[redacted path]"),
    (re.compile(r"\b(e2e-[a-z0-9_-]+)\s*/\s*\S+"), r"\1 / [redacted]"),
)


def redact(text: str) -> str:
    """Blank every secret shape in ``text``. Idempotent; keeps the line count."""
    if not text:
        return text or ""
    out = text
    for rx, repl in _REDACT_RULES:
        out = rx.sub(repl, out)
    if out.count("\n") != text.count("\n"):
        # a multi-line key block was collapsed: pad so callers that count lines agree
        out += "\n" * (text.count("\n") - out.count("\n"))
    return out


# ── rows ─────────────────────────────────────────────────────────────────────────────
Row = tuple  # (label, value)


def _scrub_value(key: str, value: Any) -> str:
    if SECRET_KEY_RE.search(key or "") or key in SECRET_FIELD_NAMES:
        return NEVER_SHOWN
    if isinstance(value, (list, tuple, set, frozenset)):
        value = ", ".join(str(v) for v in value) or "none"
    elif isinstance(value, bool):
        value = "on" if value else "off"
    elif value is None or value == "":
        value = "not set"
    return redact(str(value))


def scrub_rows(rows: Iterable[tuple]) -> "tuple[tuple[str, str], ...]":
    """``[(key, value)] -> ((key, safe value), ...)``: secret keys lose their value,
    every value is redacted, every value is a string."""
    out = []
    for item in rows:
        try:
            key, value = item[0], item[1]
        except (TypeError, IndexError):
            continue
        out.append((str(key), _scrub_value(str(key), value)))
    return tuple(out)


def _get(obj, key: str, default=None):
    if isinstance(obj, dict):
        return obj.get(key, default)
    return getattr(obj, key, default)


def domain_rows_from(domains, *, own_name: str = "") -> "tuple[tuple[str, str], ...]":
    """One row per domain from Domain rows or record dicts: name, services, sign-in
    words, Tor, VPN/egress choices. Never a secret: ``idp_settings`` is reduced to the
    provider word."""
    rows = []
    for d in domains or ():
        name = str(_get(d, "name", "") or "").strip()
        if not name:
            continue
        services = _get(d, "optional_services", None)
        if services is None:
            services = _get(d, "services", [])
        idp = str(_get(d, "idp", "") or "superdomain")
        settings = _get(d, "idp_settings", {}) or {}
        provider = str(_get(settings, "provider", "") or "")
        signin = ("through the mesh's sign-in" if idp != "own"
                  else f"its own {provider or 'casdoor'} sign-in")
        ways = _get(d, "ways", {}) or {}
        tailnet = _get(ways, "tailnet", None)
        egress = _get(ways, "egress", None)
        egress_mode = (_get(egress, "mode", "") if isinstance(egress, dict) else "") or "inherit"
        tail = "inherit" if not isinstance(tailnet, bool) else ("on" if tailnet else "off")
        look = _get(d, "look", {}) or {}
        bits = [f"services {', '.join(services) if services else 'none'}", signin,
                f"Tor {'on' if _get(d, 'tor', False) else 'off'}",
                f"VPN {tail}", f"egress {egress_mode}"]
        if look:
            bits.append("own look: " + ", ".join(f"{k}={v}" for k, v in sorted(look.items())
                                                 if isinstance(v, (str, int)) and len(str(v)) < 40))
        own = " (the mesh's own domain)" if own_name and name == own_name else ""
        rows.append((f"domain {name}{own}", "; ".join(bits)))
    return scrub_rows(rows)


def brand_rows_from(record_or_cfg) -> "tuple[tuple[str, str], ...]":
    """The brand facts: title, id, organisation, public name — from a BrandRecord-like
    object, a superbrand, or an ImageConfig (``brand`` field)."""
    if record_or_cfg is None:
        return ()
    sb = _get(record_or_cfg, "sb", None) or _get(record_or_cfg, "superbrand", None) or record_or_cfg
    title = _get(sb, "title", "") or _get(record_or_cfg, "title", "")
    ident = _get(sb, "id", "") or _get(record_or_cfg, "brand", "") or _get(record_or_cfg, "id", "")
    org = _get(sb, "org", "") or _get(sb, "organisation", "") or _get(record_or_cfg, "org", "")
    public = _get(sb, "public_name", "") or _get(sb, "name", "")
    if not (title or ident):
        return scrub_rows([("brand", "not set yet")])
    words = str(title or ident)
    if ident and ident != title:
        words += f" ({ident}"
        words += f", {org})" if org else ")"
    elif org:
        words += f" ({org})"
    if public:
        words += f", public name {public}"
    return scrub_rows([("brand", words)])


# ── the object ───────────────────────────────────────────────────────────────────────
@dataclass(frozen=True)
class Where:
    """The person's position. See the module docstring for the two halves."""
    face: str = "gui"                      # gui | tui | cli
    slug: str = ""                         # wizard / journey page slug ("" unknown)
    title: str = ""
    subtitle: str = ""
    mode: str = "docker"                   # cfg.mode or "docker" (the local mesh)
    step_index: int = 0                    # 1-based among the pages this mode visits
    step_total: int = 0
    domain: str = ""                       # the domain on screen
    own_domain: bool = False
    tab: str = ""                          # identity | look | services | ways | ""
    route: str = ""                        # image | docker | fleet | ""
    brand: "tuple[tuple[str, str], ...]" = ()
    domains: "tuple[tuple[str, str], ...]" = ()
    activity: "tuple[tuple[str, str], ...]" = ()   # what the dock already knows (mesh up, verb, builds)
    state: "tuple[tuple[str, str], ...]" = ()      # the worker-collected half
    question: str = ""                     # the question this Where was built for (actions read it)

    def with_state(self, rows: Iterable[tuple]) -> "Where":
        return replace(self, state=scrub_rows(rows))

    def with_page(self, **kw) -> "Where":
        return replace(self, **kw)

    @property
    def tab_word(self) -> str:
        return {"identity": "Identity", "look": "Look", "services": "Services",
                "ways": "Ways"}.get(self.tab, "")


def _domain_words(w: Where) -> str:
    if not w.domain:
        return ""
    kind = "the mesh's own domain" if w.own_domain else "a domain under it"
    tab = f" — tab: {w.tab_word}" if w.tab_word else ""
    return f"{w.domain} ({kind}){tab}"


def render_where(where: Where) -> str:
    """The flat ``# Where the person is`` block, <= :data:`WHERE_TOKEN_CAP` tokens."""
    w = where
    lines = [f"- face: {FACE_WORDS.get(w.face, w.face)}"]
    page = w.title or w.slug or "unknown page"
    step = f" (step {w.step_index} of {w.step_total} for {w.mode})" if w.step_total else ""
    sub = f" — {w.subtitle}" if w.subtitle else ""
    lines.append(f"- page: {page}{step}{sub}")
    if w.route:
        lines.append(f"- route: {w.route}")
    dom = _domain_words(w)
    if dom:
        lines.append(f"- domain on screen: {dom}")
    for key, val in w.brand or (("brand", "not set yet"),):
        lines.append(f"- {key}: {val}")
    if w.domains:
        lines.append(f"- domains: {len(w.domains)}")
        lines += [f"  - {k}: {v}" for k, v in w.domains]
    else:
        lines.append("- domains: none yet")
    for key, val in w.activity:
        lines.append(f"- {key}: {val}")
    for key, val in w.state:
        lines.append(f"- {key}: {val}")
    text = "\n".join(redact(ln) for ln in lines)
    # the cap: drop domain detail lines first, then state rows, never the page line
    while tokens(text) > WHERE_TOKEN_CAP and len(lines) > 2:
        cut = next((i for i, ln in enumerate(lines) if ln.startswith("  - ")), None)
        if cut is None:
            cut = len(lines) - 1
        lines.pop(cut)
        text = "\n".join(redact(ln) for ln in lines)
    assert redact(text) == text, "render_where must leave nothing redact would change"
    return text


# ── the state collectors (worker thread; files only) ─────────────────────────────────
_TAIL_LINES = 12
_TAIL_CHARS = 160


def build_rows(state_dir: str) -> "list[tuple[str, str]]":
    """The Studio's build sessions: running ones, and the last failed one's error tail
    (redacted, capped). Reads build_sessions' records only."""
    from . import build_sessions as bs
    try:
        env_before = os.environ.get("HUGMESH_STUDIO_STATE_DIR")
        sessions = bs.load_all() if (not state_dir or env_before == state_dir) else _load_sessions_at(state_dir)
    except Exception as exc:                 # noqa: BLE001 — described, not raised
        return [("build", f"{UNAVAILABLE} ({type(exc).__name__})")]
    rows: list = []
    running = [s for s in sessions if getattr(s, "status", "") == "running"]
    failed = [s for s in sessions if getattr(s, "status", "") == "failed"]
    if running:
        s = running[0]
        rows.append(("build", f"{s.label or s.id} running; images "
                              f"{', '.join(str(i) for i in (s.images or [])) or 'n/a'}"))
        pct = _build_percent(s)
        if pct:
            rows.append(("build progress", pct))
    else:
        rows.append(("build", "none running"))
    if failed:
        s = failed[0]
        rows.append(("last failed build", f"{s.label or s.id}; images "
                                          f"{', '.join(str(i) for i in (s.images or [])) or 'n/a'}"
                                          + (f"; log {s.log_path}" if s.log_path else "")))
        tail = _error_tail(s)
        if tail:
            rows.append(("last error lines (redacted)", " | ".join(tail)))
    return rows


def _load_sessions_at(state_dir: str) -> list:
    """Read ``<state_dir>/sessions/*.json`` without touching the process environment."""
    import json
    from . import build_sessions as bs
    out = []
    base = os.path.join(state_dir, "sessions")
    try:
        names = sorted(os.listdir(base), reverse=True)
    except OSError:
        return out
    for name in names:
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(base, name), encoding="utf-8") as fh:
                out.append(bs.BuildSession.from_dict(json.load(fh)))
        except (OSError, ValueError, TypeError):
            continue
    return out


def _error_tail(session) -> "list[str]":
    tail = getattr(session, "error_tail", None) or {}
    lines: list = []
    if isinstance(tail, dict):
        for image, ls in tail.items():
            for ln in (ls or [])[-_TAIL_LINES:]:
                lines.append(f"[{image}] {ln}")
    elif isinstance(tail, list):
        lines = [str(x) for x in tail]
    lines = lines[-_TAIL_LINES:]
    return [redact(str(ln))[:_TAIL_CHARS] for ln in lines]


def _build_percent(session) -> str:
    import json
    workdir = getattr(session, "workdir", "") or ""
    if not workdir:
        return ""
    path = os.path.join(workdir, "build-status.json")
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return ""
    if isinstance(data, dict):
        pct = data.get("percent", data.get("progress"))
        stage = data.get("stage") or data.get("phase") or ""
        if pct is not None:
            return f"{pct}%" + (f" ({stage})" if stage else "")
    return ""


def mesh_rows(state_dir: str) -> "list[tuple[str, str]]":
    """The local mesh's last run log (name and its last redacted line)."""
    logs = os.path.join(state_dir or "", "logs")
    try:
        names = sorted(n for n in os.listdir(logs) if n.endswith((".log", ".txt")))
    except OSError:
        return [("local mesh log", "none yet")]
    if not names:
        return [("local mesh log", "none yet")]
    last = names[-1]
    path = os.path.join(logs, last)
    line = ""
    try:
        with open(path, "rb") as fh:
            fh.seek(max(0, os.path.getsize(path) - 4096))
            data = fh.read().decode("utf-8", "replace").strip().splitlines()
            line = data[-1] if data else ""
    except OSError:
        pass
    return [("local mesh log", last + (f" — last line: {redact(line)[:_TAIL_CHARS]}" if line else ""))]


def assistant_rows(env: Optional[dict] = None) -> "list[tuple[str, str]]":
    """The model the faces would pick, which Ollama, and the context size (env and
    settings-file reads only; no request)."""
    from . import local_ai_status as lai
    env = dict(os.environ if env is None else env)
    model = lai.pick_model(env, [])
    try:
        host = lai._hostport(*lai.ollama_host(env))
    except Exception:                        # noqa: BLE001
        host = "(refused)"
    try:
        from . import ollama_docker as odk
        which = odk.current_mode()
    except Exception:                        # noqa: BLE001
        which = "system"
    try:
        ctx = lai._context_size(env)
    except Exception:                        # noqa: BLE001
        ctx = lai.DEFAULT_CTX
    return [("assistant", f"{model} on the {which} Ollama at {host}, context {ctx} tokens; "
                          "everything stays on this machine")]


def code_rows(generator_dir: str, source_mode: str, source_dir: str, domains, mesh: str,
              *, state_root: Optional[str] = None, environ=None) -> "list[tuple[str, str]]":
    """The per-domain code folders the Studio made (present or missing), from
    domain_workspaces.plan_workspaces. Never raises."""
    try:
        from . import domain_workspaces as dw
        plan = dw.plan_workspaces(generator_dir, source_mode, source_dir, list(domains or ()),
                                  mesh, state_root=state_root, environ=environ, claims={})
    except Exception as exc:                 # noqa: BLE001
        return [("code folders", f"{UNAVAILABLE} ({type(exc).__name__})")]
    rows = []
    for dom in getattr(plan, "domains", ()) or ():
        for repo in getattr(dom, "repos", ()) or ():
            exists = bool(getattr(repo, "cloned", False))
            rows.append((f"code folder {getattr(repo, 'app', '?')}-{getattr(dom, 'name', '?')}",
                         f"{'present' if exists else 'missing'}: {getattr(repo, 'dest', '')}"))
    return rows or [("code folders", "none for this mesh")]


def collect(collectors: "list[tuple[str, Callable[[], list]]]",
            budget: float = COLLECT_BUDGET_S) -> "list[tuple[str, str]]":
    """Run every collector on its own daemon thread, each under ``budget`` seconds of
    wall time; a slow or raising one yields ``(name, "(unavailable)")``. Files only:
    a collector that would open a socket does not belong here."""
    results: dict = {}
    threads = []
    for name, fn in collectors:
        def run(name=name, fn=fn):
            try:
                results[name] = list(fn())
            except Exception as exc:         # noqa: BLE001
                results[name] = [(name, f"{UNAVAILABLE} ({type(exc).__name__})")]
        t = threading.Thread(target=run, name=f"assistant-collect-{name}", daemon=True)
        t.start()
        threads.append((name, t))
    deadline = time.monotonic() + budget
    for name, t in threads:
        t.join(max(0.0, deadline - time.monotonic()))
    rows: list = []
    for name, _t in threads:
        rows += results.get(name) or [(name, UNAVAILABLE)]
    return list(scrub_rows(rows))

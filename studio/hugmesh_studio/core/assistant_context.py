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
    "Where", "Row", "tokens", "render_where", "redact", "redact_lines", "scrub_rows", "DENY_PATHS",
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
#: Secret words that are also the start or end of ordinary ones ("passed", "bypass",
#: "passthrough", "unsealed"): matched only where no letter touches them, so the
#: Studio's own spellings LUKS_PASS=, --luks-pass, local_pass=, unseal_key= and
#: VAULT_UNSEAL_KEY= are caught and the ordinary words are not (PR #832 review).
_WHOLE_WORDS = r"(?<![a-zA-Z])(?:pass|unseal)(?![a-zA-Z])"
#: The words that make a key secret, wherever they sit in it: ``POSTGRES_PASSWORD``,
#: ``CASDOOR_CLIENT_SECRET``, ``x-api-key``, ``PrivateKey``, ``aws_secret_access_key``.
#: (``\b`` does NOT fire after ``_``, so a rule anchored on ``\bpassword`` skipped every
#: prefixed env var: PR #832 review.)
_SECRET_WORDS = (r"(?:password|passwd|passphrase|pwd|secret|token|api[_-]?key|apikey"
                 r"|auth[_-]?key|authkey|private[_-]?key|privkey|access[_-]?key|client[_-]?key"
                 r"|preshared[_-]?key|credentials?|tskey|" + _WHOLE_WORDS + r")")
#: A key holding one of them (an optional quote around it, as JSON writes it); a plural
#: "tokens" (a model's context size) is not a secret.
_SECRET_KEY = r"[\w.-]*" + _SECRET_WORDS + r"[\w.-]*(?<![tT][oO][kK][eE][nN][sS])"
_NOT_YET = r"(?!\[redacted|\(set,)"


def _value(bare: str) -> str:
    """A secret's value, in one of three spellings.

    ESCAPED (JSON inside a string, as a log or ``kubectl`` prints it): ``\\"...\\"``,
    with any run of backslashes before the quote. It runs to the SAME run and quote; a
    longer or shorter run before a quote is the value's own escaped quote, so it goes
    on. ``msg="{\\"password\\": \\"a b\\"}"`` sent its whole value to the model
    before (PR #832 review).

    QUOTED (``$'..'`` too), it runs to the matching quote (a backslash escapes one),
    spaces and all: a stop at the first space sent the rest of a passphrase such as
    {"admin_password": "horse CANARY staple"} to the model (PR #832 review). An
    unterminated quote runs to the end of the line, never past it (the line count
    holds), and a backslash that is the line's last character is part of the value: a
    log line cut after one sent its whole secret (PR #832 round 3).

    BARE, it is ``bare``: it stops at whitespace (``a=b c=d`` is two pairs), so an
    unquoted ``secret = two words`` loses only its first word. A bare value may hold a
    quote after its first character and a backslash-escaped space (``printf %q``)."""
    return (r"(?:(?P<bs>\\+)(?P<eq>[\"'])(?!\[redacted|\(set,)"
            r"(?:(?!(?P=bs)(?P=eq))\\+[\"']|\\+(?![\\\"'])|[^\\\n])+"
            r"(?:(?P<eclose>(?P=bs)(?P=eq))|(?=\n)|$)"
            r"|(?P<pre>\$?)(?P<q>[\"'])(?!\[redacted|\(set,)"
            r"(?:\\[^\n]|\\(?=\n|$)|(?!(?P=q))[^\\\n])+"
            r"(?:(?P<close>(?P=q))|(?=\n)|$)"
            r"|(?![\\$]*[\"'])(?=[^\s\"'])" + bare + r")")


#: A bare value: one word. A backslash takes the next character with it (``horse\ x``
#: from ``printf %q``), and one that ends the line is still the value's.
_VALUE = _value(r"(?:\\[^\n]?|[^\s,;&}\\])+")


def _blank(m: "re.Match") -> str:
    """The [redacted] stand-in for a :data:`_VALUE` match, keeping its quotes."""
    if m.group("eq"):
        return m.group("bs") + m.group("eq") + "[redacted]" + (m.group("eclose") or "")
    q = m.group("q")
    if not q:
        return "[redacted]"
    return (m.group("pre") or "") + q + "[redacted]" + (m.group("close") or "")


def _blank_block(m: "re.Match") -> str:
    """A YAML block scalar under a secret key: every line of it, keeping the count."""
    body = re.sub(r"(?m)^([ \t]*)\S[^\n]*", r"\1[redacted]", m.group(4))
    return m.group(1) + m.group(2) + "[redacted]" + m.group(3) + body


_REDACT_RULES: tuple[tuple[re.Pattern, Any], ...] = (
    # key blocks: whole, a BEGIN line on its own, and a bare base64 body line (a log
    # printed line by line, or a tail that cut the BEGIN line off)
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY(?: BLOCK)?-----.*?-----END [A-Z ]*PRIVATE KEY(?: BLOCK)?-----",
                re.S), lambda m: "[redacted private key]" + "\n" * m.group(0).count("\n")),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY(?: BLOCK)?-----[^\n]*"), "[redacted private key]"),
    # a tail that starts inside a key: every base64-only line (any length, so the short
    # last body line too) that runs up to an END line
    (re.compile(r"(?m)^[ \t]*[A-Za-z0-9+/]{4,}={0,2}[ \t]*$"
                r"(?=\n(?:[ \t]*[A-Za-z0-9+/]{4,}={0,2}[ \t]*\n)*-----END [A-Z ]*PRIVATE KEY)"),
     "[redacted key material]"),
    (re.compile(r"(?m)^(\[[^\]\n]*\][ \t]*)?[ \t]*(?=[^\n]*[A-Z])(?=[^\n]*[a-z])(?=[^\n]*[0-9])"
                r"[A-Za-z0-9+/]{40,}={0,2}[ \t]*$"), r"\1[redacted key material]"),
    # headers
    (re.compile(r"Bearer [A-Za-z0-9._\-+/=]+"), "Bearer [redacted]"),
    (re.compile(r"(?i)(authorization:[ \t]*basic)[ \t]+" + _NOT_YET + r"\S+"), r"\1 [redacted]"),
    (re.compile(r"(?i)\b((?:set-)?cookie:[ \t]*)(?![ \t])" + _NOT_YET + r"[^\n]+"), r"\1[redacted]"),
    # Vault's init output
    (re.compile(r"(?i)\b(unseal key[ \t]*\d*[ \t]*(?:\([^)\n]*\)[ \t]*)?:[ \t]*)" + _NOT_YET + r"\S+"),
     r"\1[redacted]"),
    (re.compile(r"(?i)\b(vault[ \t]+operator[ \t]+unseal\b(?:[ \t]+-[\w-]+(?:=\S*)?)*[ \t]+)(?!-)"
                + _NOT_YET + r"\S+"), r"\1[redacted]"),
    # credentials in any URL (postgres, redis, mongodb, https, ...)
    (re.compile(r"(?i)\b([a-z][a-z0-9+.-]*://[^:/@\s]*:)" + _NOT_YET + r"[^@\s/]+@"), r"\1[redacted]@"),
    (re.compile(r"(r2dbc:[^\s:]*:[^@\s/]*?)(?<=:)" + _NOT_YET + r"[^@\s]+@"), r"\1[redacted]@"),
    # command-line flags: --password X, --admin-password=X, --client-secret X ...
    (re.compile(r"(?i)(?<![\w-])(--?[\w-]*(?:password|passwd|passphrase|secret|token|api-?key|auth-?key"
                r"|" + _WHOLE_WORDS + r")[\w-]*)(?<!tokens)([ \t]+|=)(?!-)" + _NOT_YET +
                _value(r"(?:\\[^\n]?|[^\s\\])+")),
     lambda m: m.group(1) + m.group(2) + _blank(m)),
    (re.compile(r"(?i)\b(mysql|mariadb|mysqldump|mysqladmin)\b([^\n]*?[ \t])-p(?![ \t])" + _NOT_YET + r"\S+"),
     r"\1\2-p[redacted]"),
    # SQL a database init log echoes: CREATE ROLE x PASSWORD 'v', IDENTIFIED BY 'v'
    (re.compile(r"(?i)\b(password|identified[ \t]+by)([ \t]+)(['\"])" + _NOT_YET +
                r"(?:\3\3|\\[^\n]|\\(?=\n|$)|(?!\3)[^\\\n])*(?:\3|(?=\n)|$)"),
     r"\1\2\3[redacted]\3"),
    # a YAML block scalar under a secret key (``secret: |`` and its indented lines)
    (re.compile(r"(?im)^([ \t]*)((?:-[ \t]+)?[\"']?" + _SECRET_KEY + r"[\"']?[ \t]*:[ \t]*)"
                r"[|>][-+0-9]*[ \t]*(?:#[^\n]*)?(\n|$)((?:[ \t]*\n|\1[ \t]+[^\n]*(?:\n|$))*)"),
     _blank_block),
    # key = value, key: value, "key": "value", export KEY=value
    (re.compile(r"(?i)(\\*[\"']|)(" + _SECRET_KEY + r")\1([ \t]*[=:][ \t]*)" + _NOT_YET + _VALUE),
     lambda m: m.group(1) + m.group(2) + m.group(1) + m.group(3) + _blank(m)),
    # token shapes on their own
    (re.compile(r"(?:tskey|hskey)-[a-z]+-[A-Za-z0-9\-]+"), "[redacted]"),
    (re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}"), "[redacted]"),
    (re.compile(r"AKIA[0-9A-Z]{16}"), "[redacted]"),
    (re.compile(r"\bhv[sbr]\.[A-Za-z0-9_-]{4,}"), "[redacted]"),
    (re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"), "[redacted]"),
    (re.compile(r"\bsk-[A-Za-z0-9_-]{20,}"), "[redacted]"),
    (re.compile(r"eyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{3,}"), "[redacted]"),
    (re.compile(r"/home/[^/\s]+/\.local/share/hugmesh-local-only[^\s]*"), "[redacted path]"),
    (re.compile(r"\b(e2e-[a-z0-9_-]+)\s*/\s*" + _NOT_YET + r"\S+"), r"\1 / [redacted]"),
    (re.compile(r"\be2e-pass\b(?:[ \t]+\S+)?"), "[redacted]"),
)


def redact_lines(lines: Iterable) -> "list[str]":
    """Redact a run of log lines AS ONE TEXT, then split it again: a private key printed
    line by line has its BEGIN, body and END on separate lines, and a per-line pass
    blanked only the BEGIN line (PR #832 review)."""
    lines = [str(x) for x in lines]
    if not lines:
        return []
    out = redact("\n".join(lines)).split("\n")
    # a blanked key block keeps its line breaks (redact keeps the line count): those
    # now-empty lines carry nothing, so they are dropped here
    return [ln for ln, was in zip(out, lines) if ln.strip() or not was.strip()]


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
    current: "tuple[tuple[str, str], ...]" = ()    # option key -> value on screen (assistant_actions.current_values)

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
    # each image's lines are redacted as ONE text before the tail is cut (redact_lines)
    if isinstance(tail, dict):
        for image, ls in tail.items():
            for ln in redact_lines(ls or [])[-_TAIL_LINES:]:
                lines.append(f"[{image}] {ln}")
    elif isinstance(tail, list):
        lines = redact_lines(tail)
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
            # the whole read redacted as one text (a key block spans lines), then the last
            data = redact(fh.read().decode("utf-8", "replace")).strip().splitlines()
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

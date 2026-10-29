"""Offline retrieval over the project's own docs (Qt-free, stdlib only).

The local assistant answers from the generator checkout's Markdown: the Studio
walkthrough, the wizard flow, the per-feature docs. Nothing here needs a network, an
embedding model or a third-party library: the docs are split on their headings, scored
with BM25 over plain word tokens, and the best few sections go into the prompt.

ALLOWLIST, NOT "EVERYTHING UNDER docs/". :data:`ALLOWLIST` names the files that are
written for a person using the Studio, each with a weight; :data:`EXCLUDE` names what
is never indexed (hand-offs, roadmaps, audit findings, machine-written inventories).
README.md is indexed by heading (only the sections a person building an image reads).
A file missing on disk is skipped and listed in ``Index.missing``: an installed Studio
may ship WITHOUT docs/ at all, and then every answer says so in its Sources line
instead of pretending.

CHUNKS. A ``##``/``###`` section is one chunk; a section over 700 tokens is split on
blank lines into 300-700-token parts that share the ``file#heading`` id. Each chunk
knows its file, heading, text, weight and token count (:func:`tokens` is the one
estimate the whole assistant uses).

RANKING. BM25 (k1 1.2, b 0.75) with an English stop-list, times the file weight, plus
1.5 when the page title the person is on equals the chunk heading (the walkthrough's
``###`` headings ARE the Qt page titles; :data:`TITLE_ALIASES` covers the few that
differ) and 0.5 when the question names a word of the heading.

CACHE. ``<state dir>/assistant/docs-index.json`` keyed by (mtime, size) of every
allowlisted file; rebuilt only when a key changes. Building the index over this corpus
takes well under two seconds; the dock does it on its worker thread, the text UI and
the command line on first use.

COMMANDS THE DOCS DO NOT CONTAIN. :func:`commands_in` pulls every ``make <target>``,
``scripts/<x>``, ``ollama ...``, ``docker compose ...`` and ``git <verb>`` out of a
text; :func:`unverified_commands` lists those in an answer that no retrieved snippet
(and not the primer) spells. The faces print them after the Sources line, so an
invented command is flagged in words, not trusted.
"""
from __future__ import annotations

import json
import math
import os
import re
import time
from collections import Counter
from dataclasses import dataclass, field
from typing import Iterable, Optional

from .assistant_context import is_denied_path, tokens

__all__ = [
    "ALLOWLIST", "EXCLUDE", "README_SECTIONS", "TITLE_ALIASES", "Chunk", "Index",
    "generator_dir", "chunk_markdown", "build_index", "load_index", "retrieve",
    "sources_line", "commands_in", "unverified_commands", "NO_DOCS_SOURCES",
    "NO_CHUNKS_SOURCES", "cache_path", "fallback_text",
]

GENERATOR_ENV = "HUGMESH_GENERATOR_DIR"

#: (relative path, weight). Weight 1.0 = written for a Studio user; 0.5 = reference.
ALLOWLIST: tuple[tuple[str, float], ...] = (
    ("docs/STUDIO-WALKTHROUGH.md", 1.0),
    ("docs/STUDIO-WIZARD-FLOW.md", 1.0),
    ("studio/README.md", 1.0),
    ("docs/LOCAL-AI-ASSISTANT.md", 0.9),
    ("docs/SERVE-YOUR-MESH.md", 1.0),
    ("docs/FIRST-RUN.md", 1.0),
    ("docs/STUDIO-INSTALLERS.md", 1.0),
    ("docs/RESOURCE-LIMITS.md", 1.0),
    ("docs/BRAND-MODEL.md", 1.0),
    ("docs/BRANDING.md", 1.0),
    ("docs/LOGIN-THEME.md", 1.0),
    ("docs/IDENTITY-PROVIDERS.md", 1.0),
    ("docs/DOMAIN-IDP.md", 1.0),
    ("docs/OPTIONAL-SERVICES.md", 1.0),
    ("docs/EGRESS-VPN.md", 1.0),
    ("docs/TOR-HIDDEN-SERVICE.md", 1.0),
    ("docs/GO-LIVE-WIZARD.md", 1.0),
    ("docs/GOLIVE-ORG-EXPORT.md", 1.0),
    ("docs/CLOUD-DEPLOY.md", 1.0),
    ("docs/CLOUD-IMAGE-PACKAGING.md", 1.0),
    ("docs/MDM.md", 1.0),
    ("docs/ENCRYPTION-AT-REST.md", 1.0),
    ("docs/CLIENT-IMAGES.md", 1.0),
    ("docs/STANDALONE-DESKTOP.md", 1.0),
    ("docs/EDGE-AI.md", 1.0),
    ("docs/ADMIN-CONSOLES.md", 1.0),
    ("docs/README.md", 1.0),
    ("docs/LOCAL-STACK.md", 0.9),
    ("docs/RUNNING.md", 0.5),
    ("README.md", 0.5),
    ("docs/ARCHITECTURE.md", 0.5),
    ("docs/LOCAL-TESTING.md", 0.5),
    ("docs/BUILD-MATRIX.md", 0.5),
    ("docs/SECURITY.md", 0.5),
)

#: Headings of README.md that are indexed (anything else in it is not).
README_SECTIONS: tuple[str, ...] = ("Quick start", "Images", "Build ENV", "Rebranding",
                                    "USB KEYS", "Build options", "Repositories")
#: Headings never indexed, in any file (section-level filter, case-insensitive prefix).
EXCLUDED_HEADINGS: tuple[str, ...] = ("Current State", "Roadmap")
#: docs/LOCAL-AI-ASSISTANT.md sections left out (the code-assistant and GPU-node
#: how-tos are for a developer, and would teach the model commands to run).
EXCLUDED_IN_FILE: dict[str, tuple[str, ...]] = {
    "docs/LOCAL-AI-ASSISTANT.md": ("6.", "7."),
}

#: Never indexed, whatever a future allowlist says (names and prefixes under docs/).
EXCLUDE: tuple[str, ...] = (
    "HANDOFF", "SUPERSEDED-BRANCHES", "ORG-MOVE-TODO", "ROADMAP", "PHASE5-DECISIONS",
    "KIND-SSO-E2E-FINDINGS", "FINAL-E2E-SWEEP-MATRIX", "PYTHON-TARGETS-SEED-DRIFT",
    "PLATFORM-BUILD-UNIFORMITY", "BINPKG-", "SHARED-BINPKG", "CLUSTER-HARDENING-PLAN",
    "DB-HARDENING-RUNBOOK", "POSTGRES-HARDENING", "CRYPTO-AUDIT", "PENTEST-SCHEDULES",
    "MFA-ROLLOUT", "GROUP-CALL-SFU", "LORAWAN-MESH-SYNC", "PACKAGE-FLAG-BADGES",
    "IMAGE-INVENTORY", "IMAGE-GEN-PROGRESS", "MESH-TEMPLATING", "FEDERATION-EXAMPLES",
    "DEVOPS", "selinux-module-loading", "manual-test-evidence/", "roadmap-todos.tsv",
    "schemas/", "catalog/", "FINDINGS.md", "SURVEY", "studio/packaging/",
)

#: Qt page title (or slug) -> the walkthrough heading that describes it.
TITLE_ALIASES: dict[str, str] = {
    "welcome": 'Welcome — "HugMesh Image Studio"',
    "Welcome": 'Welcome — "HugMesh Image Studio"',
    "sessions": "Prior sessions — only if you asked for it",
    "Prior sessions": "Prior sessions — only if you asked for it",
    "mode": "What do you want to build?",
    "localmesh": "Local Docker mesh",
    "Local Docker mesh": "Local Docker mesh",
    "phone": "MDM phone",
    "quest": "MDM Quest headset",
    "deploy": "Cloud deploy",
    "e2e": "Run e2e tests",
    "qemu": "QEMU device tests",
    "meshemu": "Mesh emulation",
    "localcloud": "Create nodes for local cloud",
    "idp": "Identity provider",
    "role": "Target machine & image type — standalone and cloud",
    "Target machine & image type": "Target machine & image type — standalone and cloud",
    "worklist": "Choose the images to build — mesh only",
    "Choose the images to build": "Choose the images to build — mesh only",
    "hardware": "Target hardware — standalone and cloud",
    "branding": "Branding",
    "network": "Domain, Mesh, and Services — every mode",
    "keyzip": "Load your admin config (key-zip or link) — cloud and mesh",
    "domains_choice": "Domains — mesh only",
    "domains": "Domains & their services",
    "domain_services": "Domain services",
    "users_choice": "Users — generated accounts, or your own",
    "users": "Superusers & domain users",
    "system": "System identity",
    "vault": "Secrets store — mesh only",
    "Secrets store": "Secrets store — mesh only",
    "home": "Home folder, encryption & login",
    "build": "Build",
    "launch": "Build",
    "progress": "Building",
    "review": "Review",
}
for _slug in ("localmesh_choice", "localmesh_join", "localmesh_env", "localmesh_domains",
              "localmesh_domain_services", "localmesh_source", "localmesh_services",
              "localmesh_idp", "localmesh_overlay", "localmesh_review"):
    TITLE_ALIASES.setdefault(_slug, "Local Docker mesh")

NO_DOCS_SOURCES = "Sources: none (no docs folder on this machine)"
NO_CHUNKS_SOURCES = "Sources: none (answered from the primer and this page's facts only)"

_STOP = frozenset("""a an and are as at be but by can do does for from has have how i if in
into is it its of on or that the then there these this to was we what when where which
who will with you your not no yes also any all more one two up down out over under
""".split())
_TOKEN_RE = re.compile(r"[a-z0-9][a-z0-9_.\-]{1,}")
_HEADING_RE = re.compile(r"^(#{2,3})\s+(.*?)\s*#*\s*$")
_K1, _B = 1.2, 0.75
MAX_CHUNK_TOKENS = 700
MIN_PART_TOKENS = 300
SCHEMA = 2


@dataclass(frozen=True)
class Chunk:
    id: str                 # "file#heading" (+ " (part n)" when split)
    file: str               # relative path
    heading: str
    text: str
    weight: float
    tokens: int
    part: int = 0

    @property
    def basename(self) -> str:
        return os.path.basename(self.file)

    @property
    def label(self) -> str:
        return f"{self.basename} § {self.heading}"


@dataclass
class Index:
    chunks: "list[Chunk]" = field(default_factory=list)
    keys: "dict[str, list]" = field(default_factory=dict)      # path -> [mtime, size]
    missing: "list[str]" = field(default_factory=list)
    generator_dir: str = ""
    built_at: float = 0.0
    # derived (not cached)
    _df: Counter = field(default_factory=Counter, repr=False)
    _tf: "list[Counter]" = field(default_factory=list, repr=False)
    _len: "list[int]" = field(default_factory=list, repr=False)
    _avg: float = field(default=1.0, repr=False)

    @property
    def empty(self) -> bool:
        return not self.chunks

    def prepare(self) -> "Index":
        self._tf = [Counter(_words(c.heading + " " + c.text)) for c in self.chunks]
        self._len = [max(1, sum(t.values())) for t in self._tf]
        self._avg = (sum(self._len) / len(self._len)) if self._len else 1.0
        self._df = Counter()
        for t in self._tf:
            self._df.update(t.keys())
        return self


def generator_dir(start: Optional[str] = None, environ: Optional[dict] = None) -> str:
    """The generator checkout to read docs from: ``$HUGMESH_GENERATOR_DIR`` when set,
    else ``start``, else the checkout this package lives in."""
    environ = os.environ if environ is None else environ
    env = (environ.get(GENERATOR_ENV) or "").strip()
    if env:
        return os.path.abspath(os.path.expanduser(env))
    if start:
        return os.path.abspath(start)
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.dirname(os.path.dirname(os.path.dirname(here)))


def _words(text: str) -> "list[str]":
    return [w for w in _TOKEN_RE.findall((text or "").lower()) if w not in _STOP]


def _excluded_file(rel: str) -> bool:
    base = os.path.basename(rel)
    for word in EXCLUDE:
        if word.endswith("/") and rel.startswith(("docs/" + word, word)):
            return True
        if base.startswith(word) or (word in rel and word.endswith("/")):
            return True
    return False


def _section_allowed(rel: str, heading: str) -> bool:
    h = heading.strip()
    if any(h.lower().startswith(x.lower()) for x in EXCLUDED_HEADINGS):
        return False
    for prefix in EXCLUDED_IN_FILE.get(rel, ()):
        if h.startswith(prefix):
            return False
    if rel == "README.md":
        return any(h.lower().startswith(s.lower()) for s in README_SECTIONS)
    return True


def _split_long(text: str) -> "list[str]":
    """Split a section over MAX_CHUNK_TOKENS on blank lines into 300-700 token parts."""
    if tokens(text) <= MAX_CHUNK_TOKENS:
        return [text]
    paras = [p for p in re.split(r"\n\s*\n", text) if p.strip()]
    parts, cur = [], ""
    for p in paras:
        cand = (cur + "\n\n" + p) if cur else p
        if tokens(cand) > MAX_CHUNK_TOKENS and tokens(cur) >= MIN_PART_TOKENS:
            parts.append(cur)
            cur = p
        else:
            cur = cand
        while tokens(cur) > MAX_CHUNK_TOKENS:            # one huge paragraph: cut by lines
            lines = cur.split("\n")
            head, rest, i = "", lines, 0
            while i < len(lines) and tokens("\n".join(lines[:i + 1])) <= MAX_CHUNK_TOKENS:
                i += 1
            i = max(1, i)
            parts.append("\n".join(lines[:i]))
            cur = "\n".join(lines[i:])
    if cur.strip():
        if parts and tokens(cur) < MIN_PART_TOKENS and tokens(parts[-1] + "\n\n" + cur) <= MAX_CHUNK_TOKENS:
            parts[-1] += "\n\n" + cur
        else:
            parts.append(cur)
    return parts or [text]


def chunk_markdown(rel: str, text: str, weight: float = 1.0) -> "list[Chunk]":
    """Split one file on its ``##``/``###`` headings (the text before the first heading
    is the chunk "(top)"), filtering sections :func:`_section_allowed` refuses."""
    out: list = []
    heading, buf = "(top)", []

    def flush():
        body = "\n".join(buf).strip()
        if not body or not _section_allowed(rel, heading):
            return
        parts = _split_long(body)
        for n, part in enumerate(parts):
            cid = f"{rel}#{heading}" + (f" (part {n + 1})" if len(parts) > 1 else "")
            out.append(Chunk(cid, rel, heading, part, weight, tokens(part), n))

    in_fence = False
    for line in text.splitlines():
        if line.startswith("```"):
            in_fence = not in_fence
        m = None if in_fence else _HEADING_RE.match(line)
        if m:
            flush()
            heading, buf = m.group(2).strip(), []
        else:
            buf.append(line)
    flush()
    return out


def _keys_for(gen: str) -> "tuple[dict, list]":
    keys, missing = {}, []
    for rel, _w in ALLOWLIST:
        path = os.path.join(gen, rel)
        if _excluded_file(rel) or is_denied_path(path, generator_dir=gen):
            continue
        try:
            st = os.stat(path)
        except OSError:
            missing.append(rel)
            continue
        keys[rel] = [int(st.st_mtime), int(st.st_size)]
    return keys, missing


def build_index(gen: Optional[str] = None) -> Index:
    gen = generator_dir(gen)
    keys, missing = _keys_for(gen)
    idx = Index(generator_dir=gen, keys=keys, missing=missing, built_at=time.time())
    for rel, weight in ALLOWLIST:
        if rel not in keys:
            continue
        try:
            with open(os.path.join(gen, rel), encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            idx.missing.append(rel)
            continue
        idx.chunks += chunk_markdown(rel, text, weight)
    return idx.prepare()


def cache_path(state_dir: Optional[str] = None) -> str:
    if state_dir is None:
        from . import state_paths
        state_dir = state_paths.state_dir()
    return os.path.join(state_dir, "assistant", "docs-index.json")


def _to_json(idx: Index) -> dict:
    return {"schema": SCHEMA, "generator_dir": idx.generator_dir, "keys": idx.keys,
            "missing": idx.missing, "built_at": idx.built_at,
            "chunks": [[c.id, c.file, c.heading, c.text, c.weight, c.tokens, c.part]
                       for c in idx.chunks]}


def _from_json(data: dict) -> Optional[Index]:
    if not isinstance(data, dict) or data.get("schema") != SCHEMA:
        return None
    try:
        idx = Index(generator_dir=str(data.get("generator_dir") or ""),
                    keys={str(k): list(v) for k, v in dict(data.get("keys") or {}).items()},
                    missing=[str(m) for m in data.get("missing") or []],
                    built_at=float(data.get("built_at") or 0))
        idx.chunks = [Chunk(str(a), str(b), str(c), str(d), float(e), int(f), int(g))
                      for a, b, c, d, e, f, g in data.get("chunks") or []]
    except (TypeError, ValueError):
        return None
    return idx.prepare()


def load_index(gen: Optional[str] = None, *, state_dir: Optional[str] = None,
               write: bool = True) -> Index:
    """The cached index when every allowlisted file's (mtime, size) still matches,
    else a fresh one (written back when ``write``). Never raises."""
    gen = generator_dir(gen)
    try:
        path = cache_path(state_dir)
    except Exception:                        # noqa: BLE001 — no state dir: no cache
        path = ""
    keys, _missing = _keys_for(gen)
    if path:
        try:
            with open(path, encoding="utf-8") as fh:
                cached = _from_json(json.load(fh))
            if cached is not None and cached.generator_dir == gen and cached.keys == keys:
                return cached
        except (OSError, ValueError):
            pass
    idx = build_index(gen)
    if path and write:
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            tmp = f"{path}.{os.getpid()}.tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(_to_json(idx), fh)
            os.replace(tmp, path)
        except OSError:
            pass
    return idx


# ── ranking ──────────────────────────────────────────────────────────────────────────
def _bm25(idx: Index, query: "list[str]", i: int) -> float:
    tf, n = idx._tf[i], len(idx.chunks)
    score = 0.0
    for q in query:
        f = tf.get(q, 0)
        if not f:
            continue
        df = idx._df.get(q, 0)
        idf = math.log(1 + (n - df + 0.5) / (df + 0.5))
        score += idf * (f * (_K1 + 1)) / (f + _K1 * (1 - _B + _B * idx._len[i] / idx._avg))
    return score


def _title_for(where) -> str:
    title = (getattr(where, "title", "") or "").strip()
    slug = (getattr(where, "slug", "") or "").strip()
    return TITLE_ALIASES.get(title) or TITLE_ALIASES.get(slug) or title


def scored(idx: Index, question: str, where=None) -> "list[tuple[float, Chunk]]":
    """Every chunk with its score, best first (deterministic: ties by id)."""
    query = _words(question)
    page_heading = _title_for(where).lower() if where is not None else ""
    qwords = set(query)
    rows = []
    for i, c in enumerate(idx.chunks):
        s = _bm25(idx, query, i) * c.weight
        if page_heading and c.heading.lower() == page_heading:
            s += 1.5
        if qwords & set(_words(c.heading)):
            s += 0.5
        if s > 0:
            rows.append((s, c))
    rows.sort(key=lambda r: (-r[0], r[1].id))
    return rows


def retrieve(question: str, where=None, *, index: Optional[Index] = None,
             gen: Optional[str] = None, budget_tokens: int = 3500, k: int = 5) -> "list[Chunk]":
    """Top-``k`` chunks under ``budget_tokens``, never two parts of one heading unless
    budget remains after the top-k distinct headings."""
    idx = index if index is not None else load_index(gen)
    if idx.empty:
        return []
    ranked = scored(idx, question, where)
    out, used, seen = [], 0, set()
    for _s, c in ranked:
        key = (c.file, c.heading)
        if key in seen or len(out) >= k or used + c.tokens > budget_tokens:
            continue
        out.append(c)
        used += c.tokens
        seen.add(key)
    # the page's own section is always worth having: the person is standing on it
    page_heading = _title_for(where).lower() if where is not None else ""
    if page_heading and not any(c.heading.lower() == page_heading for c in out):
        own = next((c for _s, c in ranked if c.heading.lower() == page_heading), None)
        if own is not None and used + own.tokens <= budget_tokens:
            if len(out) >= k:
                used -= out[-1].tokens
                out.pop()
            out.append(own)
            used += own.tokens
            seen.add((own.file, own.heading))
    for _s, c in ranked:                           # second parts, if room is left
        if len(out) >= k or c in out or used + c.tokens > budget_tokens:
            continue
        if (c.file, c.heading) in seen and c.part:
            out.append(c)
            used += c.tokens
    return out


def sources_line(chunks: Iterable[Chunk], *, index: Optional[Index] = None) -> str:
    """``Sources: STUDIO-WALKTHROUGH.md § Domain services; ...`` — never from the model."""
    labels = []
    for c in chunks:
        if c.label not in labels:
            labels.append(c.label)
    if labels:
        return "Sources: " + "; ".join(labels)
    if index is not None and index.empty:
        return NO_DOCS_SOURCES
    return NO_CHUNKS_SOURCES


def fallback_text(chunks: Iterable[Chunk], primer: str = "", *, index: Optional[Index] = None) -> str:
    """What a face shows when no model answers: the top chunks' ids and the first 300
    characters of the best one; with no docs at all, the primer's first paragraph."""
    chunks = list(chunks)
    if not chunks:
        para = (primer or "").strip().split("\n\n")[0].strip()
        if index is not None and index.empty:
            return "Without a model I can still say this much: " + para if para else \
                "Without a model there is nothing to show: no docs folder on this machine."
        return "Without a model I can still say this much: " + para if para else ""
    best = chunks[0]
    ids = "; ".join(c.label for c in chunks[:2])
    snippet = " ".join(best.text.split())[:300]
    return f"Without a model I can still show the docs: {ids} — “{snippet}”"


# ── commands ─────────────────────────────────────────────────────────────────────────
_CMD_RE = re.compile(
    r"(?:(?<=^)|(?<=[\s`$>]))"
    r"((?:make\s+[A-Za-z0-9_.\-]+)"
    r"|(?:\./scripts/[A-Za-z0-9_./\-]+(?:\s+[A-Za-z0-9_.\-=]+)*)"
    r"|(?:scripts/[A-Za-z0-9_./\-]+(?:\s+[A-Za-z0-9_.\-=]+)*)"
    r"|(?:ollama\s+(?:pull|run|serve|list|ps|rm|stop|show|create)(?:\s+[A-Za-z0-9_.:\-]+)?)"
    r"|(?:docker\s+compose(?:\s+[A-Za-z0-9_.\-]+)*)"
    r"|(?:git\s+(?:clone|pull|push|commit|checkout|reset|rebase|merge|fetch|add|status|log|diff)"
    r"(?:\s+[A-Za-z0-9_./:@\-]+)*))", re.M)
_BOUND = ("Run", "The", "Then", "Use", "and", "or", "to", "then", "when", "if")


def commands_in(text: str) -> "set[str]":
    """Every command-looking token sequence in ``text``, whitespace-normalised."""
    out = set()
    for m in _CMD_RE.finditer(text or ""):
        words = m.group(1).split()
        # a sentence that follows the command is not part of it: stop at a capitalised
        # or connective word after the second token
        kept = [words[0]]
        for w in words[1:]:
            if w in _BOUND or (w[:1].isupper() and len(kept) > 1):
                break
            kept.append(w.rstrip(".,;:)"))
        out.add(" ".join(kept))
    return out


def unverified_commands(answer: str, chunks: Iterable[Chunk], primer: str = "") -> "list[str]":
    """Commands in ``answer`` that no retrieved chunk nor the primer spells verbatim."""
    allowed_text = " ".join(" ".join(c.text.split()) for c in chunks) + " " + " ".join((primer or "").split())
    allowed = commands_in(allowed_text)
    out = []
    for cmd in sorted(commands_in(answer)):
        if cmd in allowed or any(a.startswith(cmd + " ") or cmd.startswith(a + " ") for a in allowed):
            continue
        if cmd not in out:
            out.append(cmd)
    return out

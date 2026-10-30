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
``scripts/<x>``, ``./x.sh``, ``ollama ...``, ``docker``/``docker-compose``/``podman``
with any subcommand, ``kubectl``, ``helm``, ``kind``, ``systemctl``/``rc-service``,
``sudo``, ``rm``, ``dd``, ``mkfs`` and ``git <verb>`` out of prose, plus EVERY line of a
fenced shell block and every inline code span that starts with a program
(:func:`code_commands`); :func:`unverified_commands` lists those in an answer that no
retrieved snippet (and not the primer) spells. The faces print them after the Sources
line, so an invented command is flagged in words, not trusted.

COMMANDS THAT DELETE DATA. :func:`destructive_commands` finds rm -r/-f, every docker
prune, docker rm/rmi, compose down -v, dd of=, mkfs, git clean/reset --hard, kubectl
delete and the like in the raw answer; the faces put assistant_prompt's
DESTRUCTIVE_WARNING above such an answer whatever the docs say. A wipe/reset question
(:func:`is_reset_question`) always retrieves the documented ways (RESET_ANCHORS).
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
    "NO_CHUNKS_SOURCES", "cache_path", "fallback_text", "code_commands",
    "destructive_commands", "COMMAND_WORDS", "RESET_WORDS", "RESET_ANCHORS", "is_reset_question",
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
#: how-tos are for a developer, and would teach the model commands to run; 12.11 lists
#: the delete commands the warning is for, which the model must never be shown).
EXCLUDED_IN_FILE: dict[str, tuple[str, ...]] = {
    "docs/LOCAL-AI-ASSISTANT.md": ("6.", "7.", "12.11", "12.12"),
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
    "build": "Review",                       # gui/pages/build.py's title is "Review"
    "launch": "Build",                       # gui/pages/launch.py's title is "Build"
    "progress": "Building",
    "review": "Review",
    "HugMesh Image Studio": 'Welcome — "HugMesh Image Studio"',
    "Home Folder, Encryption, and Login": "Home folder, encryption & login",
    "Target hardware": "Target hardware — standalone and cloud",
    "Load your admin config (key-zip or link)": "Load your admin config (key-zip or link) — cloud and mesh",
    "Bring-up and monitor": "Local Docker mesh",
    "Domain, Mesh, and Services": "Domain, Mesh, and Services — every mode",
    "Domains": "Domains — mesh only",
    "Users": "Users — generated accounts, or your own",
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
#: A chunk scoring under this share of the best one is left out (precision over padding).
MIN_RELATIVE_SCORE = 0.3
#: A file's text before its first heading is an introduction, not an answer.
TOP_PENALTY = 0.6
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
    """The ONE walkthrough heading for the page (for callers that want a string)."""
    heads = _headings_for(where)
    return heads[0] if heads else ""


def _headings_for(where) -> "list[str]":
    """Every heading that may describe the page: the title's alias, the slug's alias,
    the title itself (a page whose title IS a walkthrough heading needs no alias)."""
    if where is None:
        return []
    title = (getattr(where, "title", "") or "").strip()
    slug = (getattr(where, "slug", "") or "").strip()
    out = []
    for cand in (TITLE_ALIASES.get(title), TITLE_ALIASES.get(slug), title):
        if cand and cand not in out:
            out.append(cand)
    return out


#: A question about wiping, resetting or cleaning the local mesh. Its answer is in the
#: docs (the Studio's Stop & clean Docker… and Stop mesh buttons, make stack-down and
#: stack-halt), but a "wipe everything" question shares few words with that paragraph,
#: so a small model left without it invented rm -rf and docker system prune (PR #832,
#: round 6). Such a question is searched with the paragraph's own words added.
RESET_WORDS = re.compile(
    r"\b(?:wip(?:e|es|ed|ing)|reset(?:s|ting)?|clean(?:s|ed|ing|up)?|clear(?:s|ed|ing)? out|"
    r"purg(?:e|es|ed|ing)|nuk(?:e|es|ed|ing)|eras(?:e|es|ed|ing)|destroy(?:s|ed|ing)?|"
    r"tear(?:s|ing)? (?:it |everything |the \w+ )?down|teardown|start(?:ing)? (?:over|again|"
    r"(?:completely |totally |all )?(?:fresh|from scratch|clean))|from scratch|fresh start|"
    r"blow (?:it |everything )?away|get rid of|delete (?:it all|everything|all)|remove "
    r"(?:it all|everything|all)|factory)\b", re.I)
#: For such a question, the chunks holding these words are always sent: the paragraph
#: that names the destructive button (STUDIO-WALKTHROUGH.md, Local Docker mesh traps)
#: and the documented stack-down line (LOCAL-STACK.md). A doc edit that drops either
#: phrase fails tests/test_assistant_docs.py rather than silently losing the answer.
RESET_ANCHORS = ("Stop & clean Docker…** is the destructive one",
                 "make stack-down # stop + drop volumes")
RESET_EXPANSION = ("stop clean docker destructive volumes images removes confirms "
                   "stack-down stack-halt drop volumes keeps identity rooms accounts")


#: ... about the mesh or its data as a whole: "reset the root password", "get rid of
#: the forum" and "clean up old build sessions" are not, and pinning the destructive
#: button's paragraph first would point them at it.
RESET_SCOPE = re.compile(
    r"\b(?:mesh|docker|stack|containers?|volumes?|images?|everything|all (?:of )?(?:its |the |my )?"
    r"data|whole|setup|from scratch|fresh|start(?:ing)? (?:over|again)|completely|entirely)\b", re.I)
RESET_NOT = re.compile(
    r"\b(?:pass(?:word|phrase)s?|keys?|tokens?|secrets?|colou?rs?|themes?|services?|forums?|"
    r"chat|sign-?in|logo|brand(?:ing)?|look|tips?|settings? for (?:this|the) domain)\b", re.I)


def is_reset_question(question: str) -> bool:
    """True for a wipe/reset/clean/start-fresh question about the mesh or its data
    (:data:`RESET_WORDS` and :data:`RESET_SCOPE`, never :data:`RESET_NOT`)."""
    q = question or ""
    return bool(RESET_WORDS.search(q) and RESET_SCOPE.search(q) and not RESET_NOT.search(q))


def scored(idx: Index, question: str, where=None) -> "list[tuple[float, Chunk]]":
    """Every chunk with its score, best first (deterministic: ties by id)."""
    query = _words(question)
    if is_reset_question(question):
        query += _words(RESET_EXPANSION)
    page_headings = {h.lower() for h in _headings_for(where)}
    qwords = set(query)
    rows = []
    for i, c in enumerate(idx.chunks):
        s = _bm25(idx, query, i) * c.weight
        if c.heading == "(top)":
            s *= TOP_PENALTY                 # a file's preamble is rarely the answer
        if page_headings and c.heading.lower() in page_headings:
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
    best = ranked[0][0] if ranked else 0.0
    out, used, seen = [], 0, set()
    for s, c in ranked:
        key = (c.file, c.heading)
        if key in seen or len(out) >= k or used + c.tokens > budget_tokens:
            continue
        if s < best * MIN_RELATIVE_SCORE:    # a weak match pads the Sources line with noise
            break
        out.append(c)
        used += c.tokens
        seen.add(key)
    # the page's own section is always worth having: the person is standing on it
    page_headings = {h.lower() for h in _headings_for(where)}
    if page_headings and not any(c.heading.lower() in page_headings for c in out):
        own = next((c for _s, c in ranked if c.heading.lower() in page_headings), None)
        if own is not None and used + own.tokens <= budget_tokens:
            if len(out) >= k:
                used -= out[-1].tokens
                out.pop()
            out.append(own)
            used += own.tokens
            seen.add((own.file, own.heading))
    for s, c in ranked:                            # second parts, if room is left
        if len(out) >= k or c in out or used + c.tokens > budget_tokens or s < best * MIN_RELATIVE_SCORE:
            continue
        if (c.file, c.heading) in seen and c.part:
            out.append(c)
            used += c.tokens
    if is_reset_question(question):
        # the documented ways to wipe the mesh, always (see RESET_ANCHORS)
        for anchor in RESET_ANCHORS:
            if any(anchor in " ".join(c.text.split()) for c in out):
                continue
            pick = next((c for _s, c in ranked if anchor in " ".join(c.text.split())), None) or \
                next((c for c in idx.chunks if anchor in " ".join(c.text.split())), None)
            if pick is None:
                continue
            while out and (len(out) >= k or used + pick.tokens > budget_tokens):
                used -= out[-1].tokens
                out.pop()
            if used + pick.tokens <= budget_tokens:
                out.append(pick)
                used += pick.tokens
    # the page's own section reads first: a small model weighs the first snippet most;
    # for a wipe/reset question the destructive-button paragraph reads before it
    reset = is_reset_question(question)

    def order(c):
        if reset and any(a in " ".join(c.text.split()) for a in RESET_ANCHORS[:1]):
            return 0
        return 1 if c.heading.lower() in page_headings else 2
    out.sort(key=order)
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
_ARG = r"(?:[ \t]+(?![A-Z])[A-Za-z0-9_./:@\-=]+(?<![.;,]))*"
# a destructive line's arguments: paths with ~ and $, globs, $(...) substitutions
_PARG = r"(?:[ \t]+(?![A-Z])[A-Za-z0-9_./:@\-=~$*{}()\"'+%]+(?<![.;,]))*"
_GIT_VERBS = ("clone|pull|push|commit|checkout|reset|rebase|merge|fetch|add|status|log|diff|"
              "init|clean|stash|branch|remote|config|switch|restore|rm|mv|tag|worktree|"
              "submodule|cherry-pick|revert|show|gc|prune|filter-branch|update-ref")
# "make sure you have a backup" is English, not a make target (a footer once listed
# "make sure" as a command the docs lack)
_MAKE_PROSE = ("sure", "certain", "it", "this", "that", "these", "those", "them", "the", "a",
               "an", "your", "you", "any", "all", "one", "some", "changes", "use",
               "sense", "room", "space", "note", "everything", "things", "copies", "backups")
_CMD_RE = re.compile(
    r"(?:(?<=^)|(?<=[\s`$>]))"
    r"((?:make\s+(?!(?:" + "|".join(_MAKE_PROSE) + r")\b)[a-z0-9_.\-]+(?<![.;,]))"
    r"|(?:\./scripts/[A-Za-z0-9_./\-]+(?<![.;,])" + _ARG + r")"
    r"|(?:scripts/[A-Za-z0-9_./\-]+(?<![.;,])" + _ARG + r")"
    r"|(?:\./[A-Za-z0-9_.\-][A-Za-z0-9_./\-]*\.(?:sh|py)" + _ARG + r")"
    r"|(?:(?:bash|sh)\s+[A-Za-z0-9_./\-]+\.sh" + _ARG + r")"
    r"|(?:ollama\s+(?:pull|run|serve|list|ps|rm|stop|show|create)(?:[ \t]+[A-Za-z0-9_.:\-]+(?<![.;,]))?)"
    r"|(?:(?:docker|podman)(?:-compose)?\s+[a-z][a-z\-]*" + _PARG + r")"
    r"|(?:(?:kubectl|helm)\s+-{0,2}[a-z][a-z\-]*" + _PARG + r")"
    r"|(?:kind\s+(?:create|delete|get|load|export)" + _PARG + r")"
    r"|(?:(?:systemctl|rc-service|rc-update|service)\s+[A-Za-z0-9_.@\-]+" + _PARG + r")"
    r"|(?:sudo\s+[A-Za-z0-9_./\-]+" + _PARG + r")"
    r"|(?:rm\s+(?:-[A-Za-z]+|--[a-z\-]+|[~/.$])" + r"[^\s`]*" + _PARG + r")"
    r"|(?:dd\s+(?:if|of|bs)=\S+" + _PARG + r")"
    r"|(?:(?:mkfs(?:\.[a-z0-9]+)?|wipefs|shred|sgdisk|blkdiscard)\s+\S+" + _PARG + r")"
    r"|(?:git\s+(?:" + _GIT_VERBS + r")" + _ARG + r"))", re.M)
# a sentence that follows the command is not part of it: these words end it
_BOUND = frozenset(("Run", "The", "Then", "Use", "and", "or", "to", "then", "when", "if",
                    "it", "is", "are", "the", "a", "an", "that", "this", "these", "those",
                    "they", "you", "your", "will", "would", "can", "which", "with", "for",
                    "in", "on", "of", "from", "by", "as", "so", "but", "not", "be", "was",
                    "we", "its", "their", "first", "after", "before", "again", "also",
                    "command", "commands", "button", "page", "step"))

#: The first words that make a code span or a fenced line a command a person could paste.
COMMAND_WORDS = frozenset("""
rm rmdir sudo su doas docker docker-compose podman podman-compose kubectl helm kind k3s minikube
git make systemctl rc-service rc-update service dd wipefs shred fdisk parted sgdisk
blkdiscard mount umount losetup chmod chown chattr mv cp ln curl wget pip pip3 pipx
python python3 npm npx yarn pnpm apt apt-get dnf yum zypper pacman emerge brew winget
choco snap flatpak ollama tailscale headscale vault kill pkill killall reboot shutdown
poweroff iptables nft ufw firewall-cmd ssh scp rsync tar find truncate cd export source
bash sh zsh journalctl openssl gh cargo go java mvn gradle tor qemu-img virsh crontab
passwd useradd usermod userdel mkdir touch tee xargs eval exec setfacl ip
wsl wsl.exe rd del erase dropdb createdb psql mysql powershell pwsh cmd diskpart
""".split())
_SHELL_TAGS = frozenset(("", "sh", "bash", "shell", "console", "zsh", "fish", "terminal",
                         "shell-session", "shellsession", "cmd", "bat", "powershell", "ps1",
                         "pwsh", "ps"))
_TEXT_TAGS = frozenset(("text", "txt", "plaintext", "plain", "output"))
_FENCE_RE = re.compile(r"^[ \t]*(`{3,}|~{3,})[ \t]*([A-Za-z0-9_+.\-]*)[ \t]*$")
_SPAN_RE = re.compile(r"(?<!`)`([^`\n]+)`(?!`)")
_SEG_SPLIT_RE = re.compile(r"\s*(?:&&|\|\||;|(?<![|])\|(?![|]))\s*")
_ENV_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=\S*$")


def _first_word(seg: str) -> str:
    """The program a segment runs: past ``sudo`` and ``VAR=value`` prefixes."""
    words = seg.split()
    while words and (words[0] in ("sudo", "doas", "env", "exec", "time", "nohup")
                     or _ENV_ASSIGN_RE.match(words[0])):
        words = words[1:]
    return words[0] if words else ""


#: a PowerShell cmdlet (Remove-Item, Format-Volume, Stop-Service): Verb-Noun
_CMDLET_RE = re.compile(r"^[A-Z][a-z]+-[A-Z][A-Za-z]+$")


def _is_program(word: str) -> bool:
    w = word.strip("\"'")
    if not w:
        return False
    return (w in COMMAND_WORDS or w.lower() in COMMAND_WORDS or w.startswith("mkfs")
            or w.startswith("./") or bool(_CMDLET_RE.match(w))
            or w.endswith(".sh") or w.startswith("scripts/") or w.startswith("~/")
            or (w.startswith("/") and "/bin/" in w))


def _segments(line: str) -> "list[str]":
    out = []
    for seg in _SEG_SPLIT_RE.split(line):
        seg = " ".join(seg.split())
        if seg:
            out.append(seg)
    return out


def code_commands(text: str) -> "list[str]":
    """Every command a person could paste from the CODE in ``text``: each line of a
    fenced shell block (untagged, sh, bash, console, ...; a ``text`` fence only where
    the line starts with a known program), split at ``&&``, ``||``, ``;`` and ``|``,
    and each inline code span that starts with a known program. Comments, prompts
    (``$ ``) and line continuations are handled; change/diff/json/yaml fences are not
    commands. In order of appearance, whitespace-normalised."""
    out: list = []

    def add(seg: str, strict: bool) -> None:
        seg = seg.strip()
        if not seg or seg in out:
            return
        first = _first_word(seg)
        if strict and not _is_program(first):
            return
        if not strict and (not first or first.startswith("#")):
            return
        out.append(seg)

    lines = (text or "").split("\n")
    fence = None                                  # (marker, tag) while inside a block
    pending = ""
    for raw in lines:
        m = _FENCE_RE.match(raw)
        if fence is None:
            if m:
                fence = (m.group(1)[0], m.group(2).lower())
                pending = ""
                continue
            for sm in _SPAN_RE.finditer(raw):
                span = sm.group(1).strip()
                if span.startswith("$ "):
                    span = span[2:]
                if len(span.split()) < 2 and not _is_program(span.split()[0] if span.split() else ""):
                    continue
                if len(span.split()) < 2 and _first_word(span) in COMMAND_WORDS:
                    continue                      # `docker` alone names a tool, it runs nothing
                for seg in _segments(span):
                    add(seg, True)
            continue
        if m and m.group(1)[0] == fence[0] and not m.group(2):
            fence = None
            continue
        tag = fence[1]
        if tag not in _SHELL_TAGS and tag not in _TEXT_TAGS:
            continue
        line = raw.strip()
        if pending:
            line = pending + " " + line
            pending = ""
        if line.endswith("\\"):
            pending = line[:-1].strip()
            continue
        if line.startswith("$ ") or line.startswith("> ") or line.startswith("% "):
            line = line[2:].strip()
        elif line.startswith("#"):
            continue                              # a comment (or a root prompt: never mind)
        line = re.sub(r"\s+#\s.*$", "", line)   # a trailing comment
        for seg in _segments(line):
            add(seg, tag in _TEXT_TAGS)
    return out


def commands_in(text: str) -> "set[str]":
    """Every command-looking token sequence in ``text``, whitespace-normalised: the
    command patterns anywhere in prose, plus every command in code
    (:func:`code_commands`)."""
    out = set()
    for m in _CMD_RE.finditer(text or ""):
        words = m.group(1).split()
        # a sentence that follows the command is not part of it: stop at a capitalised
        # or connective word after the second token
        kept = [words[0]]
        for w in words[1:]:
            if w in _BOUND or (w[:1].isupper() and len(kept) > 1):
                break
            kept.append(w.rstrip(".,;:)") if not w.endswith("))") and "$(" not in w else w)
        out.add(" ".join(kept))
    out.update(code_commands(text))
    out.update(destructive_commands(text))  # a delete command is always a command
    return out


# ── commands that destroy data ───────────────────────────────────────────────────────
# Checked on the RAW answer, never through commands_in (whose argument rules stop at a
# ``$(`` or a capital and would cut ``docker rm -f $(docker ps -aq)`` short). Shown with
# a warning whether or not a doc spells the same command: an answer that tells a person
# to delete things gets the warning, always.
_PRE = r"(?<![\w./\-])"
# a program in command position: a line (after a prompt), a code span, after && ; | (
# or sudo; prose ("shred the notes", "truncate the log") is not a command
_CMDPOS = r"(?:^[ \t]*(?:[$#>%][ \t]+)?|[`;&|(][ \t]*|\bsudo[ \t]+)"
# ... and its argument is not the next word of a sentence ("mkfs is the tool ...")
_NOT_PROSE = (r"(?!(?:is|are|was|were|the|a|an|and|or|to|can|will|would|tool|command|"
              r"program|utility|deletes?|removes?|erases?|formats?|cmdlet)\b)")
#: (kind, pattern): each kind gets its own sentence in the warning
#: (assistant_prompt.danger_banner), so an answer that removes an Ollama model is not
#: pointed at the Docker button.
_DESTRUCTIVE_KINDS = (
    ("mesh", _PRE + r"(?:docker|podman)(?:\s+(?:system|volume|image|container|network|builder|buildx|pod))?\s+prune\b"),
    ("mesh", _PRE + r"(?:docker|podman)\s+(?:volume|image|container|network|pod)\s+rm\b"),
    ("mesh", _PRE + r"(?:docker|podman)\s+(?:rm|rmi)\b"),
    ("mesh", _PRE + r"podman\s+system\s+reset\b"),
    ("mesh", _PRE + r"(?:docker\s+compose|docker-compose|podman-compose|podman\s+compose)\b[^\n`]*?\bdown\b[^\n`]*?(?<!\S)(?:-v|--volumes|--rmi)\b"),
    ("mesh", _PRE + r"(?:docker\s+compose|docker-compose|podman-compose|podman\s+compose)\b[^\n`]*?(?<!\S)(?:-v|--volumes)\b[^\n`]*?\bdown\b"),
    ("mesh", _PRE + r"(?:docker\s+compose|docker-compose|podman-compose|podman\s+compose)\b[^\n`]*?\srm\b"),
    ("cluster", _PRE + r"kubectl\s+(?:[^\n`]*\s)?delete\b"),
    ("cluster", _PRE + r"helm\s+(?:uninstall|delete)\b"),
    ("cluster", _PRE + r"kind\s+delete\b"),
    ("cluster", _PRE + r"minikube\s+delete\b"),
    ("model", _PRE + r"ollama\s+(?:rm|remove)(?![\w-])"),
    ("wsl", r"(?i:" + _PRE + r"wsl(?:\.exe)?\s+(?:[^\n`]*\s)?--unregister\b)"),
    ("app", _PRE + r"flatpak\s+(?:uninstall|remove)\b[^\n`]*--delete-data\b"),
    ("app", _PRE + r"snap\s+remove\b[^\n`]*--purge\b"),
    ("database", _CMDPOS + r"dropdb\s+" + _NOT_PROSE + r"\S"),
    ("database", _PRE + r"dropdb\s+-\S"),
    ("database", r"(?i:\bdrop\s+(?:database|schema|table)\b)"),
    ("database", r"\b(?:TRUNCATE\s+TABLE|DELETE\s+FROM)\b"),   # upper case: SQL, not "delete from the list"
    ("database", _PRE + r"mysqladmin\s+[^\n`]*\bdrop\b"),
    ("disk", _PRE + r"dd\s+[^\n`]*\bof="),
    ("disk", _PRE + r"(?:mkfs(?:\.[a-z0-9]+)?|wipefs|blkdiscard)\s+[^\n`]*?(?:/dev/|<\w|\$\w)"),
    ("disk", _CMDPOS + r"(?:mkfs(?:\.[a-z0-9]+)?|wipefs|blkdiscard)\s+" + _NOT_PROSE + r"\S"),
    ("disk", _PRE + r"sgdisk\s+[^\n`]*(?:-Z|--zap)"),
    ("disk", r"(?i:" + _PRE + r"(?:Format-Volume|Clear-Disk|Initialize-Disk)\b)"),
    ("files", _PRE + r"find\s+[^\n`]*\s-(?:delete\b|exec\s+rm\b)"),
    ("files", _PRE + r"xargs\s+(?:-\S+\s+)*(?:sudo\s+)?rm\b"),
    ("files", _PRE + r"rm\s+(?:-[A-Za-z]*[rRf][A-Za-z]*|--recursive|--force|--no-preserve-root)\b"),
    ("files", _PRE + r"rm\s+(?:-[A-Za-z]+\s+)*[~/$.*]"),
    # rm in command position on a path
    ("files", _CMDPOS + r"rm[ \t]+(?:-|[~/.$*]|[^\s`]*[/.])"),
    # PowerShell and cmd.exe: Remove-Item (and its aliases) of anything, rd/rmdir /s,
    # del/erase /s
    ("files", r"(?i:" + _PRE + r"Remove-Item\s+(?:-|[$\"'~./\\]|[a-z]:))"),
    ("files", r"(?i:" + _CMDPOS + r"Remove-Item(?:\s+" + _NOT_PROSE + r"\S|\s*$|\s*`))"),
    ("files", r"(?i:" + _PRE + r"(?:ri|rm|del|erase|rmdir|rd)\s+[^\n`]*?(?<!\S)-(?:Recurse|Force)\b)"),
    ("files", r"(?i:" + _PRE + r"(?:rmdir|rd)\s+(?:/[a-z]\s+)*/s\b)"),
    ("files", r"(?i:" + _PRE + r"(?:del|erase)\s+(?:/[a-z]\s+)*/[sq]\b)"),
    ("files", _PRE + r"shred\s+(?:-\S|[/~$<]|\S*/)"),
    ("files", _CMDPOS + r"shred\s+" + _NOT_PROSE + r"\S"),
    ("files", _PRE + r"truncate\s+(?:-s|--size)(?:\s*|=)\S"),
    ("files", _CMDPOS + r"truncate\s+" + _NOT_PROSE + r"\S"),
    ("git", _PRE + r"git\s+clean\s+(?:-[a-z]*[fdx][a-z]*)"),
    ("git", _PRE + r"git\s+reset\s+(?:[^\n`]*\s)?--hard\b"),
    ("git", _PRE + r"git\s+push\s+(?:[^\n`]*\s)?(?:-f|--force|--force-with-lease|--mirror)\b"),
    ("git", _PRE + r"git\s+checkout\s+(?:-f\b|--\s+\.)"),
    ("git", _PRE + r"git\s+branch\s+-D\b"),
    ("git", _PRE + r"git\s+stash\s+(?:drop|clear)\b"),
)
_DESTRUCTIVE_RES = tuple((kind, re.compile(x, re.M)) for kind, x in _DESTRUCTIVE_KINDS)
#: The order the warning names them in.
DESTRUCTIVE_KIND_ORDER = ("wsl", "disk", "files", "mesh", "cluster", "database", "model",
                          "app", "git")


# `docker rm -f x` is a Docker command, not a file one: its warning names the Docker ways
_TOOL_BEFORE_RE = re.compile(r"(?:docker|podman|compose|docker-compose|podman-compose|volume|"
                             r"image|container|network|pod)\s+$")


def _destructive_hits(text: str) -> "list[tuple[str, str]]":
    """``(kind, fragment)`` for each line or code span of ``text`` that deletes data."""
    out: list = []
    # a command continued on the next line is one line here
    joined = re.sub(r"[ \t]*\\\r?\n[ \t]*", " ", text or "")
    for line in joined.split("\n"):
        done: set = set()               # one fragment per kind per line, every kind
        for kind, rx in _DESTRUCTIVE_RES:
            if kind in done:
                continue
            m = next((x for x in rx.finditer(line)
                      if not (kind == "files" and _TOOL_BEFORE_RE.search(line[:x.start()]))), None)
            if not m:
                continue
            done.add(kind)
            # the command from where it starts to the end of its code span or line
            start = m.start()
            pre = re.search(r"(?:sudo|doas)\s+$", line[:start])
            tail = line[pre.start() if pre else start:].lstrip("`;&|( \t$#>%")
            cut = tail.find("`")
            frag = " ".join((tail[:cut] if cut > 0 else tail).split()).rstrip(".,;:")
            if len(frag) > 90:
                frag = frag[:89] + "…"
            if frag and all(frag != f for _, f in out):
                out.append((kind, frag))
            elif frag and kind not in (k for k, _ in out):
                out.append((kind, ""))      # the same text, a second kind: counted, not listed
    return out


def destructive_commands(text: str) -> "list[str]":
    """The lines (or code spans) of ``text`` that run a command which deletes data,
    fenced, in a code span or on a bare line: rm -r/-f or rm of a path, xargs rm,
    find -delete, shred, truncate, PowerShell Remove-Item, rd/rmdir /s, del /s, every
    docker/podman prune, docker rm/rmi, docker/podman volume rm, podman system reset,
    compose down -v, kubectl delete, helm uninstall, kind delete, minikube delete,
    ollama rm, wsl --unregister, flatpak uninstall --delete-data, dropdb, DROP DATABASE,
    dd of=, mkfs, wipefs, Format-Volume, git clean/reset --hard/push --force. Each is
    returned once, trimmed to its line, in order of appearance."""
    return [f for _, f in _destructive_hits(text) if f]


def destructive_kinds(text: str) -> "list[str]":
    """What the delete commands in ``text`` delete, in :data:`DESTRUCTIVE_KIND_ORDER`:
    ``wsl`` (a whole WSL distro), ``disk``, ``files``, ``mesh`` (Docker/Podman
    containers, images, volumes), ``cluster`` (Kubernetes), ``database``, ``model``
    (an Ollama model), ``app`` (an app's data), ``git`` (uncommitted work)."""
    seen = {k for k, _ in _destructive_hits(text)}
    return [k for k in DESTRUCTIVE_KIND_ORDER if k in seen]


def unverified_commands(answer: str, chunks: Iterable[Chunk], primer: str = "") -> "list[str]":
    """Commands in ``answer`` that no retrieved chunk nor the primer spells verbatim."""
    raw = [c.text for c in chunks] + [primer or ""]
    allowed_text = " ".join(" ".join(t.split()) for t in raw)
    allowed = commands_in(allowed_text)
    for t in raw:                       # the docs' own fenced lines, with their newlines
        allowed.update(code_commands(t))
    padded = f" {allowed_text} "
    out = []
    for cmd in sorted(commands_in(answer)):
        if cmd in allowed or any(a.startswith(cmd + " ") or cmd.startswith(a + " ") for a in allowed):
            continue
        if f" {cmd} " in padded or f"`{cmd}`" in padded or f" {cmd}`" in padded:
            continue                    # spelled verbatim in a snippet or the primer
        if cmd not in out:
            out.append(cmd)
    return out

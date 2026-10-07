#!/usr/bin/env bash
# test-local-ai-primer.sh — the mesh primer that the local Ollama models start from only states
# things the repository backs, stays inside a small model's budget, and is what the models are
# built from.
#
# WHY. local-ai/primer.md is put in front of four local models (scripts/local-ai-agents.sh). A
# small model repeats what it is told, so a primer that names a make target that was renamed, a
# path that moved or a variable nobody reads teaches the model a command that fails, and nobody
# reads the model's system prompt to notice. The primer also has to stay short: past the model's
# budget the beginning is silently cut. This suite is the check that keeps both true as the
# repository moves.
#
# THE RULES (each run on the live tree, then on doctored copies that must be caught):
#   (a) every `make <target>` in the primer and the role files is a target in the Makefile;
#   (a2) every UPPER_CASE_NAME with an underscore, and every hugmesh-<repo> name, exists in the
#        repository (a variable somewhere, a repo in scripts/clone-all-repos.sh);
#   (b) every repository path the text names exists in the tree (.stack-src is untracked and is
#       allowed by name);
#   (c) the primer is inside its byte and token budgets, and its measured token count is not stale;
#   (d) no secret-shaped string, no absolute home path, no account name, no model or tool name;
#   (e) each role Modelfile parses: one FROM, only PARAMETER names Ollama accepts, a closed
#       SYSTEM block, and the context and temperature the design sets;
#   (f) `scripts/local-ai-agents.sh create --dry-run <name>` prints exactly the role file's lines
#       (FROM resolved), the marker, and SYSTEM = primer + blank line + role text. The expected
#       text is built HERE from the files, not by the script's own functions;
#   (g) the three role files carry the front matter the coding-agent harness reads;
#   (h) every evaluation question has an expected word that is in the primer or the repository and
#       is NOT already in the question.
#
# Offline: python3 and bash only, no Ollama, no network. Run: bash tests/scripts/test-local-ai-primer.sh
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

# ── recorded budgets ─────────────────────────────────────────────────────────
# BYTE_LIMIT / TOKEN_BUDGET: the design's budget is 2500 tokens; 10240 bytes is that at roughly
# four bytes a token with room to spare.
# MEASURED_*: counted on 2026-10-07 with Ollama 0.40.0 through POST /api/generate {"raw": true,
# "num_predict": 1} on the primer text alone (everything before the SOURCES comment, trailing
# blank lines removed, one final newline): prompt_eval_count was 1473 for 6065 bytes, the same on
# qwen3:8b and qwen2.5-coder:7b and the same on a second run. Re-measure with
# `scripts/local-ai-agents.sh test --tokens` after any edit that moves the size by more than
# STALE_PERCENT, and update both numbers (the check below fails until you do).
BYTE_LIMIT=10240
TOKEN_BUDGET=2500
MEASURED_TOKENS=1473
MEASURED_BYTES=6065
STALE_PERCENT=15

T=$(mktemp -d "${TMPDIR:-/tmp}/local-ai-primer.XXXXXX"); trap 'rm -rf "$T"' EXIT

# ── the checker: prints one line per violation, "(x) message"; nothing = clean ───────────────
cat > "$T/chk.py" <<'PY'
import os, re, subprocess, sys

repo, ai, script, corpus_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
BYTE_LIMIT, TOKEN_BUDGET, MEAS_TOK, MEAS_BYTES, STALE = (int(x) for x in sys.argv[5:10])
CUT = "<!-- SOURCES"
MODELS = {  # name: (num_ctx, temperature)
    "hugmesh-agent": ("32768", "0.2"), "hugmesh-coder": ("16384", "0.2"),
    "hugmesh-reviewer": ("16384", "0.1"), "hugmesh-triage": ("16384", "0.1")}
ROLES = ["mesh-builder", "mesh-tester", "mesh-reviewer"]
READ_ONLY_ROLES = {"mesh-tester", "mesh-reviewer"}
# PARAMETER names `ollama create` accepted on Ollama 0.40.0 (tried one at a time); it refused
# tfs_z ("unknown parameter") and typical_p ("deprecated").
PARAMS = {"num_ctx", "temperature", "top_p", "top_k", "repeat_penalty", "num_predict", "seed",
          "stop", "min_p", "num_keep", "presence_penalty", "frequency_penalty", "mirostat",
          "num_gpu", "num_thread", "num_batch"}
DIRECTIVES = {"FROM", "PARAMETER", "SYSTEM", "LICENSE", "TEMPLATE", "MESSAGE", "ADAPTER"}
HARNESS_TOOLS = {"Read", "Grep", "Glob", "Edit", "Write", "Bash", "WebFetch", "WebSearch",
                 "Task", "TodoWrite", "NotebookEdit"}
MARKER = ("hugmesh-local-ai: prepared by scripts/local-ai-agents.sh from local-ai/primer.md. "
          "The base model's own licence still applies to the weights.")
out = []
def bad(rule, msg): out.append("(%s) %s" % (rule, msg))

def read(p):
    with open(p, encoding="utf-8", errors="replace") as fh:
        return fh.read()

def exists(p):
    return os.path.exists(p)

# ── inputs ──
primer_path = os.path.join(ai, "primer.md")
if not exists(primer_path):
    print("(a) no primer at %s" % primer_path); sys.exit(0)
raw = read(primer_path)
cut_lines = [i for i, l in enumerate(raw.split("\n")) if l.startswith(CUT)]
if len(cut_lines) != 1:
    bad("k", "the primer needs exactly one line starting %r (the sources comment), found %d" % (CUT, len(cut_lines)))
lines = raw.split("\n")
body = "\n".join(lines[:cut_lines[0]] if cut_lines else lines).rstrip() + "\n"
sources = "\n".join(lines[cut_lines[0]:]) if cut_lines else ""
if cut_lines and (not sources.rstrip().endswith("-->") or len([l for l in sources.split("\n") if l.strip()]) < 6):
    bad("k", "the sources comment must end with --> and quote at least five backing sources")

role_texts = {}
for r in ROLES:
    p = os.path.join(ai, "agents", r + ".md")
    role_texts[r] = read(p) if exists(p) else None
modelfiles = {}
for m in MODELS:
    p = os.path.join(ai, "modelfiles", m + ".Modelfile")
    modelfiles[m] = read(p) if exists(p) else None
    if modelfiles[m] is None:
        bad("e", "missing %s" % p)

scan_text = body + "\n".join(t for t in role_texts.values() if t) + "\n".join(
    t for t in modelfiles.values() if t)

# ── (a) make targets ──
mk = read(os.path.join(repo, "Makefile")) if exists(os.path.join(repo, "Makefile")) else ""
targets = set()
for l in mk.split("\n"):
    m = re.match(r"^([A-Za-z0-9_.%/ -]+?)\s*:(?!=)", l)
    if m and not l.startswith(("\t", "#", ".PHONY")):
        targets.update(m.group(1).split())
for t, star in sorted(set(re.findall(r"\bmake ([A-Za-z0-9][A-Za-z0-9_-]*)(\*?)", scan_text))):
    if star:
        if not any(x.startswith(t) for x in targets):
            bad("a", "the text says `make %s*` but the Makefile has no target starting %s" % (t, t))
    elif t not in targets:
        bad("a", "the text says `make %s` but the Makefile has no target %s" % (t, t))

# ── (a2) variables and repo names ──
_corpus = None
def in_repo(needle):
    """Is this text anywhere in the repository's own text files? The corpus is built once per run of
    this suite (see build-corpus below) so there is no git, no grep and no per-needle file walk."""
    global _corpus
    if _corpus is None:
        _corpus = read(corpus_path)
    return needle in _corpus

# Words that look like variables but are product or protocol names, not things this repo reads.
VAR_OK = {"GH_TOKEN"}
for v in sorted(set(re.findall(r"\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b", scan_text)) - VAR_OK):
    if not in_repo(v):
        bad("a2", "the text names %s but nothing in the repository mentions it" % v)
repos = set()
cl = os.path.join(repo, "scripts", "clone-all-repos.sh")
if exists(cl):
    inside = False
    for l in read(cl).split("\n"):
        if l.startswith("REPOS=("):
            inside = True; continue
        if inside and l.strip() == ")":
            break
        m = re.match(r"^\s+(hugmesh-[a-z0-9-]+)\s*$", l)
        if inside and m:
            repos.add(m.group(1))
repos.add("hugmesh-generator")
for name in sorted(set(re.findall(r"\bhugmesh-[a-z0-9]+(?:-[a-z0-9]+)*\b", scan_text))):
    if name in repos or name in MODELS or name in ("hugmesh-local-ai",):
        continue
    bad("a2", "the text names %s, which is not a repository in scripts/clone-all-repos.sh" % name)

# ── (b) paths ──
tops = {n for n in os.listdir(repo) if not n.startswith(".git")}
def path_ok(tok):
    tok = tok.rstrip(".,;:)\"'`")
    if not tok or any(c in tok for c in "<>*${}|") or tok.startswith(("http", "~", "/")):
        return None
    if tok.startswith("./"):
        tok = tok[2:]
    if tok.startswith(".stack-src"):
        return None
    first = tok.split("/")[0]
    if "/" in tok and first in tops:
        return exists(os.path.join(repo, tok))
    if "/" not in tok and re.search(r"\.(sh|py|yaml|yml|md)$", tok):
        return exists(os.path.join(repo, tok)) or exists(os.path.join(repo, "scripts", tok))
    return None
seen = set()
for tok in re.split(r"[\s`(]+", scan_text + "\n" + sources):
    r = path_ok(tok)
    if r is False and tok not in seen:
        seen.add(tok)
        bad("b", "the text names the path %s, which is not in the tree" % tok.rstrip(".,;:)\"'`"))

# ── (c) budgets ──
nbytes = len(body.encode("utf-8"))
est = nbytes * MEAS_TOK / float(MEAS_BYTES)
if nbytes > BYTE_LIMIT:
    bad("c", "the primer is %d bytes, over the %d byte limit" % (nbytes, BYTE_LIMIT))
if est > TOKEN_BUDGET:
    bad("c", "the primer is about %d tokens (scaled from the measured %d for %d bytes), over the %d token budget" % (est, MEAS_TOK, MEAS_BYTES, TOKEN_BUDGET))
if abs(nbytes - MEAS_BYTES) * 100 > STALE * MEAS_BYTES:
    bad("c", "the primer is %d bytes but the recorded measurement is for %d bytes (more than %d%% apart): re-measure with `scripts/local-ai-agents.sh test --tokens` and update MEASURED_TOKENS and MEASURED_BYTES" % (nbytes, MEAS_BYTES, STALE))
if MEAS_TOK > TOKEN_BUDGET:
    bad("c", "the recorded measurement (%d tokens) is itself over the budget" % MEAS_TOK)

# ── (d) secrets, home paths, accounts, names ──
SECRET = [r"gh[pousr]_[A-Za-z0-9]{20,}", r"github_pat_[A-Za-z0-9_]{20,}", r"AKIA[0-9A-Z]{16}",
          r"-----BEGIN [A-Z ]*PRIVATE KEY", r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}",
          r"xox[baprs]-[A-Za-z0-9-]{10,}", r"\b[0-9a-fA-F]{32,}\b", r"\b[A-Za-z0-9+/]{40,}={0,2}\b",
          r"(?i)\b(password|passwd|secret|token|apikey|api_key)\s*[:=]\s*['\"]?[A-Za-z0-9+/_.-]{12,}"]
HOME = [r"/home/[A-Za-z0-9_.-]+", r"/Users/[A-Za-z0-9_.-]+", r"[A-Za-z]:\\Users\\", r"/root/", r"\.hugmesh-wt"]
ACCOUNT = [r"(?i)usidiamond", r"(?i)\bmagus\b", r"(?i)maguscrowley", r"(?i)@gmail\.com", r"(?i)snapdragon"]
ATTRIB = [r"(?i)co-authored-by", r"(?i)generated with", r"(?i)\bclaude\b", r"(?i)anthropic", r"(?i)\bsonnet\b",
          r"(?i)\bopus\b", r"(?i)\bfable\b", "\U0001F916"]
all_ai_files = []
for d, dn, fn in os.walk(ai):
    for f in fn:
        all_ai_files.append(os.path.join(d, f))
for f in sorted(all_ai_files):
    t = read(f); rel = os.path.relpath(f, ai)
    for pat in SECRET + HOME + ACCOUNT:
        m = re.search(pat, t)
        if m:
            bad("d", "%s contains %r (matches %s)" % (rel, m.group(0)[:24] + ("..." if len(m.group(0)) > 24 else ""), pat[:30]))
    if rel == "primer.md" or rel.startswith(("modelfiles/", "agents/")):
        for pat in ATTRIB:
            m = re.search(pat, t)
            if m:
                bad("d", "%s contains %r, a model, tool or attribution name that must not be in the prepared text" % (rel, m.group(0)))
if '"""' in body or any('"""' in (t or "").replace('SYSTEM """', "").replace('\n"""', "") for t in role_texts.values()):
    bad("i", 'a triple quote in the primer or a role file would close the SYSTEM block early')

# ── (e) Modelfiles ──
def parse_modelfile(name, text):
    """returns (header_lines, role_text) or None after recording problems"""
    ls = text.split("\n")
    if ls and ls[-1] == "":
        ls = ls[:-1]
    froms, params, header, role, state = 0, {}, [], [], 0
    for i, l in enumerate(ls):
        if state == 1:
            if l == '"""':
                state = 2
            else:
                role.append(l)
            continue
        if state == 2:
            if l.strip() and not l.startswith("#"):
                bad("e", "%s has text after the closed SYSTEM block: %r" % (name, l[:40]))
            header.append(l)
            continue
        if not l.strip() or l.startswith("#"):
            header.append(l); continue
        word = l.split(None, 1)[0]
        if word not in DIRECTIVES:
            bad("e", "%s line %d: %r is not a Modelfile directive" % (name, i + 1, word)); continue
        if l == 'SYSTEM """':
            state = 1; continue
        header.append(l)
        if word == "FROM":
            froms += 1
            if len(l.split()) != 2:
                bad("e", "%s: FROM needs exactly one model name" % name)
        elif word == "PARAMETER":
            p = l.split()
            if len(p) < 3:
                bad("e", "%s: PARAMETER line without a value: %r" % (name, l))
            else:
                if p[1] not in PARAMS:
                    bad("e", "%s: PARAMETER %s is not one Ollama accepts" % (name, p[1]))
                params.setdefault(p[1], []).append(p[2])
        elif word == "SYSTEM":
            bad("e", "%s: SYSTEM must open with a line that is exactly SYSTEM \"\"\"" % name)
    if froms != 1:
        bad("e", "%s must have exactly one FROM line, has %d" % (name, froms))
    if state != 2:
        bad("e", "%s has no closed SYSTEM block (an opening line SYSTEM \"\"\" and a closing line \"\"\")" % name)
        return None
    want = MODELS[name]
    if params.get("num_ctx") != [want[0]]:
        bad("e", "%s: num_ctx must be %s, found %s" % (name, want[0], params.get("num_ctx")))
    if params.get("temperature") != [want[1]]:
        bad("e", "%s: temperature must be %s, found %s" % (name, want[1], params.get("temperature")))
    if "top_p" not in params:
        bad("e", "%s: top_p is not set" % name)
    role_text = "\n".join(role).strip("\n")
    if not role_text.strip():
        bad("e", "%s: the SYSTEM block is empty" % name)
    return header, role_text

parsed = {}
for name, text in modelfiles.items():
    if text is not None:
        r = parse_modelfile(name, text)
        if r:
            parsed[name] = r

# ── (f) the script's output equals primer + role ──
def run(args, env_extra=None):
    env = dict(os.environ); env["LOCAL_AI_DIR"] = ai
    env["PATH"] = os.environ["CHK_STUB_BIN"] + os.pathsep + env["PATH"]; env["STUB_STATE"] = os.environ["CHK_STUB_STATE"]
    env.pop("BASE_AGENT", None); env.pop("BASE_CODER", None)
    env.update(env_extra or {})
    return subprocess.run(["bash", script] + args, capture_output=True, text=True, env=env)

def expected(name, base=None):
    header, role = parsed[name]
    h = list(header)
    if base:
        h = [("FROM " + base) if l.startswith("FROM ") else l for l in h]
    return "\n".join(h) + "\nLICENSE \"\"\"" + MARKER + "\"\"\"\nSYSTEM \"\"\"\n" + body.rstrip("\n") + "\n\n" + role + "\n\"\"\"\n"

SKIP_F = "f" in os.environ.get("CHK_SKIP", "")   # a control aimed at another rule skips the ~16 script runs
QUICK_F = os.environ.get("CHK_F_QUICK") == "1"   # a control aimed at the script itself needs one model, not four
for name in ([] if SKIP_F else sorted(parsed)[:1] if QUICK_F else sorted(parsed)):
    r = run(["create", "--dry-run", name])
    if r.returncode != 0:
        bad("f", "create --dry-run %s exited %d: %s" % (name, r.returncode, r.stderr.strip()[:120])); continue
    if r.stdout != expected(name):
        bad("f", "create --dry-run %s differs from the role file plus the primer plus the role text" % name)
    r2 = run(["print", name])
    if r2.stdout != r.stdout:
        bad("f", "print %s differs from create --dry-run %s" % (name, name))
if parsed and not SKIP_F:
    r = run(["print", "primer"])
    if r.stdout != body:
        bad("f", "print primer differs from the primer text")
    # A base override may change the FROM line and nothing else.
    for name, var in (("hugmesh-agent", "BASE_AGENT"), ("hugmesh-reviewer", "BASE_AGENT"), ("hugmesh-triage", "BASE_AGENT"), ("hugmesh-coder", "BASE_CODER")):
        if name in parsed and not QUICK_F:
            r = run(["create", "--dry-run", name], {var: "example-base:70b"})
            if r.stdout != expected(name, "example-base:70b"):
                bad("f", "%s=example-base:70b did not change only the FROM line of %s" % (var, name))
    r = run(["create", "--dry-run", "hugmesh-nope"])
    if r.returncode != 2 or "unknown model" not in r.stderr:
        bad("f", "create --dry-run did not refuse (exit 2) a model name outside the four it manages")
    r = run(["remove", "hugmesh-nope"], {"OLLAMA_HOST": "127.0.0.1:1"})
    if r.returncode != 2 or "manages only" not in r.stderr:
        bad("f", "remove did not refuse (exit 2) a model name outside the four it manages")
    for host in ("192.0.2.7:11434", "0.0.0.0:11434", "127.example.com:11434", "localhost.example.com:11434",
                 "10.0.0.5", "http://[2001:db8::1]:11434", "127.0.0.1.example.com"):
        r = run(["list"], {"OLLAMA_HOST": host})
        if r.returncode != 2 or "loopback" not in r.stderr:
            bad("f", "OLLAMA_HOST=%s was not refused with the word 'loopback'" % host)
    for host in ("127.0.0.1:11434", "localhost:11434", "http://127.0.0.1:11434", "[::1]:11434", "127.1.2.3"):
        r = run(["list"], {"OLLAMA_HOST": host})
        if "loopback" in r.stderr:
            bad("f", "OLLAMA_HOST=%s is loopback but was refused" % host)
if not os.access(os.path.join(repo, "scripts", "local-ai-agents.sh"), os.X_OK):
    bad("f", "scripts/local-ai-agents.sh is not executable")

# ── (g) role files ──
for r in ROLES:
    t = role_texts[r]
    if t is None:
        bad("g", "missing agents/%s.md" % r); continue
    ls = t.split("\n")
    if not ls or ls[0] != "---" or "---" not in ls[1:]:
        bad("g", "%s.md needs a front matter block opened and closed by a line of ---" % r); continue
    end = ls.index("---", 1)
    fm = {}
    for l in ls[1:end]:
        m = re.match(r"^([a-z]+):\s*(.*)$", l)
        if m:
            fm[m.group(1)] = m.group(2).strip()
        elif l.strip():
            bad("g", "%s.md front matter line is not `key: value`: %r" % (r, l[:40]))
    if fm.get("name") != r or not re.match(r"^[a-z][a-z0-9-]*$", fm.get("name", "")):
        bad("g", "%s.md name must be %r" % (r, r))
    if not fm.get("description") or len(fm["description"]) > 400:
        bad("g", "%s.md needs a description of at most 400 characters" % r)
    tools = [x.strip() for x in fm.get("tools", "").split(",") if x.strip()]
    if not tools:
        bad("g", "%s.md lists no tools" % r)
    for x in tools:
        if x not in HARNESS_TOOLS:
            bad("g", "%s.md lists %r, which is not a tool name the harness has" % (r, x))
    if r in READ_ONLY_ROLES and {"Edit", "Write", "NotebookEdit"} & set(tools):
        bad("g", "%s.md is a read-only role but lists an editing tool" % r)
    if not "\n".join(ls[end + 1:]).strip():
        bad("g", "%s.md has no body after the front matter" % r)

# ── (h) questions ──
qp = os.path.join(ai, "eval", "questions.tsv")
def norm(s):
    return re.sub(r"\s+", " ", s.lower().replace("`", "").replace("*", "")).strip()
if not exists(qp):
    bad("h", "no eval/questions.tsv")
else:
    qs, ids = [], set()
    for l in read(qp).split("\n"):
        if not l.strip() or l.startswith("#") or l.startswith("id\t"):
            continue
        parts = l.split("\t")
        if len(parts) != 3 or not all(p.strip() for p in parts):
            bad("h", "bad question line (need id, question, expect): %r" % l[:50]); continue
        if parts[0] in ids:
            bad("h", "duplicate question id %s" % parts[0])
        ids.add(parts[0]); qs.append(parts)
    if len(qs) < 14:
        bad("h", "need at least 14 questions, found %d" % len(qs))
    nb = norm(body)
    for qid, q, expect in qs:
        for term in expect.split("&&"):
            for alt in term.split("||"):
                for piece in alt.split(">>"):
                    w = norm(piece)
                    if not w:
                        bad("h", "%s has an empty expected word" % qid); continue
                    if w in norm(q):
                        bad("h", "%s: the expected word %r is already in the question" % (qid, w))
                    if w not in nb and not in_repo(piece.strip()) and not in_repo(w):
                        bad("h", "%s: the expected word %r is in neither the primer nor the repository" % (qid, w))

print("\n".join(out))
PY

# One text corpus of the repository's own files (Makefile, scripts, tests, studio, docs, specs; text
# only, no vendored trees) for the "is this word anywhere in the repository" questions. local-ai/ is
# NOT in it, so the primer cannot vouch for itself.
python3 - "$REPO" "$T/corpus.txt" <<'PY'
import os, sys
repo, dst = sys.argv[1], sys.argv[2]
skip = {".git", "node_modules", "__pycache__", ".venv", "venv"}
with open(dst, "w", encoding="utf-8", errors="replace") as out:
    for top in ("Makefile", "scripts", "tests", "studio", "docs", "specs"):
        p = os.path.join(repo, top)
        files = [p] if os.path.isfile(p) else []
        for d, dn, fn in os.walk(p):
            dn[:] = [x for x in dn if x not in skip]
            files += [os.path.join(d, f) for f in fn]
        for f in files:
            try:
                if os.path.getsize(f) > 2000000:
                    continue
                b = open(f, "rb").read()
            except OSError:
                continue
            if b"\0" in b:      # a binary file: not text to search
                continue
            out.write(b.decode("utf-8", "replace") + "\n")
PY

problems() { # <localai dir> [script] -> violations on stdout
  python3 "$T/chk.py" "$REPO" "$1" "${2:-$REPO/scripts/local-ai-agents.sh}" "$T/corpus.txt" \
    "$BYTE_LIMIT" "$TOKEN_BUDGET" "$MEASURED_TOKENS" "$MEASURED_BYTES" "$STALE_PERCENT"
}

# A stand-in `ollama` (state in a folder): the checker puts it first on PATH so no check can reach a real
# server, and the section further down drives create / list / remove through it.
mkdir -p "$T/bin" "$T/state"
cat > "$T/bin/ollama" <<'STUB'
#!/usr/bin/env bash
S="${STUB_STATE:?}"; touch "$S/models" "$S/calls"; mkdir -p "$S/license" "$S/created"
has() { grep -Fx -e "$1" -e "${1%:latest}" "$S/models" >/dev/null; }
case "$1" in
  list) echo "NAME ID SIZE MODIFIED"; while read -r n; do case "$n" in *:*) echo "$n abc 1.0 GB now" ;; *) echo "$n:latest abc 1.0 GB now" ;; esac; done < "$S/models" ;;
  show) has "$2" || exit 1
        if [ "${3:-}" = "--license" ]; then cat "$S/license/${2%:latest}" 2>/dev/null; fi ;;
  create) echo "create $2" >> "$S/calls"; cp "$4" "$S/created/$2"
          sed -n 's/^LICENSE """\(.*\)"""$/\1/p' "$4" > "$S/license/$2"
          has "$2" || echo "$2" >> "$S/models" ;;
  rm) echo "rm $2" >> "$S/calls"; grep -Fxv -e "$2" "$S/models" > "$S/models.new"; mv "$S/models.new" "$S/models" ;;
  *) echo "stub: unsupported $*" >&2; exit 9 ;;
esac
STUB
chmod +x "$T/bin/ollama"
export CHK_STUB_BIN="$T/bin" CHK_STUB_STATE="$T/state"

echo "== live tree"
out=$(problems "$REPO/local-ai")
if [ -z "$out" ]; then ok "primer, Modelfiles, role files, questions and the script's dry-run all check out"
else printf '%s\n' "$out" | sed 's/^/  FAIL live: /'; F=$((F+1)); fi

# ── the script's create / list / remove against a stand-in `ollama` ──────────────────────────
# What the script promises about a real Ollama cannot be run without one, so these run the real
# script against a stub that keeps its models in a folder. They cover: no pull when a base is
# missing (the exact pull command is printed), no overwriting and no deleting of a model this
# script did not make, and only the four managed names ever reach `ollama rm`.
stub_reset() { rm -rf "$T/state"; mkdir -p "$T/state/license"; : > "$T/state/models"; : > "$T/state/calls"; for m in "$@"; do echo "$m" >> "$T/state/models"; done; }
stub_run() { PATH="$T/bin:$PATH" STUB_STATE="$T/state" OLLAMA_HOST=127.0.0.1:11434 bash "$REPO/scripts/local-ai-agents.sh" "$@"; }
calls() { grep -c "^$1" "$T/state/calls" || true; }
echo "== the script against a stub ollama"

stub_reset
stub_run create >"$T/o" 2>"$T/e"; rc=$?
if [ "$rc" = 3 ] && grep -F "ollama pull qwen3:8b" "$T/e" >/dev/null && [ "$(calls create)" = 0 ]; then ok "create with the base missing stops with the exact pull command and creates nothing"
else bad "create with the base missing: rc=$rc, $(head -c 200 "$T/e")"; fi

stub_reset qwen3:8b qwen2.5-coder:7b hugmesh-reviewer
stub_run create >"$T/o" 2>"$T/e"; rc=$?
if [ "$rc" = 4 ] && grep -F "hugmesh-reviewer" "$T/e" >/dev/null && [ "$(calls create)" = 0 ]; then ok "create refuses to overwrite a model of the same name it did not make, and creates nothing at all"
else bad "create over a foreign hugmesh-reviewer: rc=$rc creates=$(calls create)"; fi

stub_reset qwen3:8b qwen2.5-coder:7b
stub_run create >"$T/o" 2>"$T/e"; rc=$?
same=1
for m in hugmesh-agent hugmesh-coder hugmesh-reviewer hugmesh-triage; do
  bash "$REPO/scripts/local-ai-agents.sh" create --dry-run "$m" 2>/dev/null | cmp -s - "$T/state/created/$m" || same=0
done
if [ "$rc" = 0 ] && [ "$(calls create)" = 4 ] && [ "$same" = 1 ]; then ok "create builds all four, each from exactly the dry-run Modelfile"
else bad "create of all four: rc=$rc creates=$(calls create) same=$same"; fi
stub_run create >"$T/o" 2>"$T/e"; rc=$?
if [ "$rc" = 0 ] && [ "$(calls create)" = 8 ]; then ok "running create again rebuilds the same four (idempotent)"; else bad "second create: rc=$rc creates=$(calls create)"; fi
stub_run list >"$T/o" 2>"$T/e"
if [ "$(grep -c 'made by this script' "$T/o")" = 4 ]; then ok "list reports the four as made by this script"; else bad "list output: $(cat "$T/o")"; fi

rm -f "$T/state/license/hugmesh-triage"          # now a model of that name that "someone else made"
: > "$T/state/calls"
stub_run remove >"$T/o" 2>"$T/e"; rc=$?
if [ "$rc" = 0 ] && [ "$(calls rm)" = 3 ] && ! grep -F "rm hugmesh-triage" "$T/state/calls" >/dev/null && grep -F "NOT removed" "$T/o" >/dev/null; then ok "remove deletes the three it made and leaves the one it did not"
else bad "remove: rc=$rc rm-calls=$(calls rm) out=$(cat "$T/o")"; fi
: > "$T/state/calls"
stub_run remove qwen3:8b >"$T/o" 2>"$T/e"; rc=$?
if [ "$rc" = 2 ] && [ "$(calls rm)" = 0 ]; then ok "remove refuses a name outside the four, and never calls ollama rm"; else bad "remove qwen3:8b: rc=$rc rm-calls=$(calls rm)"; fi

stub_reset qwen3:8b qwen2.5-coder:7b
BASE_AGENT=bigger:70b stub_run create hugmesh-agent >"$T/o" 2>"$T/e"; rc=$?
if [ "$rc" = 3 ] && grep -F "ollama pull bigger:70b" "$T/e" >/dev/null; then ok "BASE_AGENT names the pull command for the bigger base"; else bad "BASE_AGENT missing base: rc=$rc $(head -c 200 "$T/e")"; fi
stub_reset qwen3:8b bigger:70b
BASE_AGENT=bigger:70b stub_run create hugmesh-triage >"$T/o" 2>"$T/e"; rc=$?
if [ "$rc" = 0 ] && grep -x "FROM bigger:70b" "$T/state/created/hugmesh-triage" >/dev/null; then ok "BASE_AGENT puts the bigger base in the FROM line"; else bad "BASE_AGENT present base: rc=$rc"; fi

# ── negative controls: each doctored copy of local-ai/ must be caught by the rule it breaks ──
fresh() { rm -rf "$T/d"; mkdir -p "$T/d"; cp -r "$REPO/local-ai/." "$T/d/"; }
expect_caught() { # <rule letter> <why>   (uses $T/d; the dry-run rule (f) is skipped unless it is the one under test)
  local out skip=f; [ "$1" = f ] && skip=""
  out=$(CHK_SKIP="$skip" problems "$T/d")
  if printf '%s\n' "$out" | grep -F "($1)" >/dev/null; then ok "negative control: $2 — caught by ($1)"
  else bad "negative control: $2 — NOT caught by ($1)"; printf '%s\n' "$out" | sed 's/^/       saw: /' | head -3; fi
}
primer_insert() { # <text>: add a line to the primer, above the sources comment
  python3 - "$T/d/primer.md" "$1" <<'PY'
import sys
p, add = sys.argv[1], sys.argv[2]
s = open(p).read(); i = s.index("<!-- SOURCES")
open(p, "w").write(s[:i] + add + "\n\n" + s[i:])
PY
}
echo "== negative controls"
fresh; primer_insert "- Run make no-such-target to start over."; expect_caught a "a make target that does not exist"
fresh; primer_insert "- Read docs/NO-SUCH-FILE.md first."; expect_caught b "a path that does not exist"
fresh; primer_insert "- See scripts/no-such-script.sh."; expect_caught b "a script that does not exist"
fresh; primer_insert "- Set $(printf FROBNICATE_%s THE_MESH)=1 first."; expect_caught a2 "a variable nothing in the repository reads"
fresh; primer_insert "- Clone hugmesh-nonexistent-api next."; expect_caught a2 "a repository that is not in the clone list"
fresh; python3 - "$T/d/primer.md" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read(); i = s.index("<!-- SOURCES")
filler = "".join("- Padding line %d says nothing new about the mesh at all.\n" % n for n in range(300))
open(p, "w").write(s[:i] + filler + "\n" + s[i:])
PY
expect_caught c "an oversize primer"
fresh; primer_insert "$(python3 -c 'print("- A moderately longer note about the lanes. " * 30)')"; expect_caught c "growth past the measured size without a re-measure"
fresh; primer_insert "- The CI token is $(printf 'ghp_%s' 0123456789abcdefghijABCDEFGHIJ012345) so use it."; expect_caught d "a token-shaped string"
fresh; primer_insert "- password: hunter2hunter2hunter2"; expect_caught d "a password assignment"
fresh; primer_insert "- The checkout lives in /home/someone/Github."; expect_caught d "an absolute home path"
fresh; primer_insert "- Ask UsiDiamond before merging."; expect_caught d "an account name"
fresh; primer_insert "- Commits end with Co-Authored-By."; expect_caught d "an attribution phrase"
fresh; primer_insert '- Use """ to quote.'; expect_caught i "a triple quote that would close the SYSTEM block"
fresh; sed -i '/^FROM /d' "$T/d/modelfiles/hugmesh-agent.Modelfile"; expect_caught e "a Modelfile without FROM"
fresh; sed -i 's/^PARAMETER top_p 0.9/PARAMETER tfs_z 0.9/' "$T/d/modelfiles/hugmesh-coder.Modelfile"; expect_caught e "a PARAMETER Ollama refuses"
fresh; sed -i '$d' "$T/d/modelfiles/hugmesh-triage.Modelfile"; expect_caught e "a SYSTEM block that is never closed"
fresh; sed -i 's/^PARAMETER num_ctx 32768/PARAMETER num_ctx 4096/' "$T/d/modelfiles/hugmesh-agent.Modelfile"; expect_caught e "a context window other than the designed one"
fresh; sed -i 's/^PARAMETER temperature 0.1/PARAMETER temperature 0.9/' "$T/d/modelfiles/hugmesh-reviewer.Modelfile"; expect_caught e "a temperature other than the designed one"
fresh; sed -i '1d' "$T/d/agents/mesh-builder.md"; expect_caught g "a role file with no front matter"
fresh; sed -i 's/^tools: .*/tools: Read, Teleport/' "$T/d/agents/mesh-tester.md"; expect_caught g "a tool name the harness does not have"
fresh; sed -i 's/^tools: Read, Grep, Glob, Bash/tools: Read, Grep, Glob, Edit, Bash/' "$T/d/agents/mesh-reviewer.md"; expect_caught g "an editing tool on a read-only role"
fresh; sed -i 's/^name: mesh-tester/name: tester/' "$T/d/agents/mesh-tester.md"; expect_caught g "a role file whose name differs from its file"
fresh; printf 'qx\tWhat is made by make kind-images?\tkind-images\n' >> "$T/d/eval/questions.tsv"; expect_caught h "an expected word already in the question"
fresh; printf 'qy\tWhat colour is the front door?\t%s\n' "$(printf 'purple-%s' unicorn-xyz)" >> "$T/d/eval/questions.tsv"; expect_caught h "an expected word found nowhere"
fresh; python3 - "$T/d/eval/questions.tsv" <<'PY'
import sys
p = sys.argv[1]; ls = open(p).read().split("\n")
keep, n = [], 0
for l in ls:
    if l and not l.startswith("#") and not l.startswith("id\t"):
        n += 1
        if n > 10: continue
    keep.append(l)
open(p, "w").write("\n".join(keep))
PY
expect_caught h "too few questions"
# the dry-run rule: a script that drops the role paragraph, and one that drops the primer
SYS_LINE="printf 'SYSTEM \"\"\"\\n%s\\n\\n%s\\n\"\"\"\\n' \"\${primer}\" \"\${role}\""
variant() { # <out> <old> <new>: copy the script with one exact string replaced; non-zero if nothing changed
  python3 - "$REPO/scripts/local-ai-agents.sh" "$1" "$2" "$3" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
if old not in s:
    sys.exit(1)
open(dst, "w").write(s.replace(old, new, 1))
PY
}
for v in role primer; do
  fresh
  if [ "$v" = role ]; then new="printf 'SYSTEM \"\"\"\\n%s\\n\"\"\"\\n' \"\${primer}\""
  else new="printf 'SYSTEM \"\"\"\\n%s\\n\"\"\"\\n' \"\${role}\""; fi
  if ! variant "$T/variant.sh" "$SYS_LINE" "$new"; then bad "negative control setup: the line to break in the script was not found ($v)"; continue; fi
  out=$(CHK_F_QUICK=1 problems "$T/d" "$T/variant.sh")
  if printf '%s\n' "$out" | grep -F "(f)" >/dev/null; then ok "negative control: a script that drops the $v text — caught by (f)"
  else bad "negative control: a script that drops the $v text — NOT caught by (f)"; fi
done
fresh
if ! variant "$T/variant.sh" '*) [[ "${host}" =~ ^127(\.[0-9]{1,3}){3}$ ]] \' '*) true \'; then bad "negative control setup: the loopback line was not found"
else out=$(CHK_F_QUICK=1 problems "$T/d" "$T/variant.sh"); if printf '%s\n' "$out" | grep -F "(f)" >/dev/null; then ok "negative control: a script that accepts any OLLAMA_HOST — caught by (f)"; else bad "negative control: a script that accepts any OLLAMA_HOST — NOT caught by (f)"; fi; fi

# a harmless edit must stay clean (the checker is not just always-failing)
fresh; primer_insert "- One more harmless sentence about the lanes."
out=$(problems "$T/d")
if [ -z "$out" ]; then ok "negative control: a harmless added sentence — clean"; else bad "a harmless added sentence was flagged: $out"; fi

echo; echo "== local-ai primer: $P passed, $F failed =="
[ "$F" -eq 0 ]

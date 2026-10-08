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
#   (h) every evaluation question has an expected word that is in the PRIMER (not merely somewhere in
#       the repository, which let a question become unanswerable from the primer unnoticed) and is NOT
#       already in the question.
#   (j) fact anchors: claims the primer makes about what a command does, where a service listens, which
#       repositories are Java or Angular, what is safe to run, are each tied to an exact primer phrase
#       and a pattern in the repository file that backs them, so a swapped meaning or a changed port is
#       caught, not only a renamed target;
#   (m) coverage: every sentence of the primer overlaps an anchor, or is listed with a reason in
#       UNANCHORED (the three instructions to the model that state no fact). A new sentence therefore
#       cannot be added without either backing it or saying why it needs none.
#   and, outside the checker: the `test` subcommand (scorer, table, totals, verdict, which model each
#   column asks) is run against a stub of the Ollama API and against four copies of the script with
#   one planted defect each.
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

# ── (j) fact anchors: what the primer SAYS about a name, not just that the name exists ──
# Rules (a) to (b) only prove that a target, variable, repository or path exists. A primer that swaps
# what make stack-halt and make stack-down do passes all of them. Each anchor below is a triple:
# a phrase the primer must contain word for word (so an edit to the claim is noticed), the repository
# file that backs it, and a pattern that file must match (whitespace runs count as one space). The
# phrase pins the primer's wording; the pattern pins the repository's truth; change either and this
# rule goes red until a person reads both again.
def squash(s):
    return re.sub(r"\s+", " ", s)
ANCHORS = [
    ("make stack-halt stops and keeps the data; make stack-down deletes the volumes", "Makefile", r"stack-halt: ## stop the local stack but KEEP its data"),
    ("make stack-halt stops and keeps the data; make stack-down deletes the volumes", "Makefile", r"stack-down: ## stop the local stack and DROP ITS VOLUMES"),
    ("Front door http://localhost:8088", "docs/LOCAL-STACK.md", r"\*\*http://localhost:8088\*\* \(the fe-gateway front door"),
    ("https://localhost:8488 is its TLS twin", "docs/LOCAL-STACK.md", r"HTTPS twin \*\*https://localhost:8488\*\*"),
    ("Only the fe-gateway is published to the host", "docs/LOCAL-STACK.md", r"Only the fe-gateway is published to the"),
    ("make stack-seed is required afterwards: sign-in fails until it has run", "docs/LOCAL-STACK.md", r"make stack-seed +# REQUIRED for real SSO login"),
    ("make view LANE=compose or LANE=kind", "Makefile", r"view: ## serve the local front doors in the browser \(LANE=kind\|kind-svc\|compose"),
    ("(WireGuard is 1420)", "scripts/kind-load-images.sh", r"WireGuard is 1420"),
    ("IPv6 is not the cause", "scripts/kind-load-images.sh", r"IPv6 look like the culprit\. It is not"),
    ("Set BUILD_NETWORK=host for make kind-images", "scripts/kind-load-images.sh", r"Use BUILD_NETWORK=host"),
    ("Order: make kind-up, then make kind-images, then make kind-doctor to check it, then make kind-e2e for the sign-in test", "specs/cluster/bootstrap/kind-local/README.md", r"is `kind-up` THEN `kind-images`"),
    ("Order: make kind-up, then make kind-images, then make kind-doctor to check it, then make kind-e2e for the sign-in test", "Makefile", r"kind-doctor: ## is the kind cluster capable of running the mesh"),
    ("Order: make kind-up, then make kind-images, then make kind-doctor to check it, then make kind-e2e for the sign-in test", "Makefile", r"kind-e2e: playwright-deps ## run the native-login e2e"),
    ("make kind-tor publishes a .onion and runs after make kind-up", "Makefile", r"kind-tor: ## publish the kind front door as a v3 \.onion .*run after kind-up"),
    ("make kind-images ONLY=hugmesh-host-shell (a comma list is accepted; an unknown name fails)", "Makefile", r"kind-images: stack-clone .*\(ONLY=repo\[,repo\] for a subset\)"),
    ("make kind-images ONLY=hugmesh-host-shell (a comma list is accepted; an unknown name fails)", "scripts/kind-load-images.sh", r"ONLY: unknown image"),
    ("make kind-images runs make stack-clone first", "Makefile", r"kind-images: stack-clone "),
    ("make kind-halt stops without deleting; make kind-down deletes the cluster", "Makefile", r"kind-halt: ## stop the DevOps lane WITHOUT deleting it"),
    ("make kind-halt stops without deleting; make kind-down deletes the cluster", "Makefile", r"kind-down: ## delete the kind cluster"),
    ("make stack-clone runs git reset --hard on each checkout", "scripts/clone-all-repos.sh", r"reset --hard --quiet \"origin/\$\{GIT_REF\}\""),
    ("(a checkout with local commits is kept, not updated)", "scripts/clone-all-repos.sh", r"KEPT: \$\{repo\} has local work not in"),
    ("The second sets STACK_NO_CLONE=1, so your checkouts are never fetched or reset", "docs/STUDIO-WALKTHROUGH.md", r"sets `STACK_NO_CLONE=1`, so your checkouts are never fetched, updated or `git reset`"),
    ("The second sets STACK_NO_CLONE=1, so your checkouts are never fetched or reset", "Makefile", r"stack-clone: ## .*\(idempotent; STACK_NO_CLONE=1 skips\)"),
    ("Java: ./mvnw -B verify (some repos add -s settings.xml)", "docs/LOCAL-AI-ASSISTANT.md", r"`\./mvnw -B verify` \(some repos pass `-s settings\.xml`"),
    ("Angular: npm ci && npm run build && npm test -- --watch=false", "docs/LOCAL-AI-ASSISTANT.md", r"`npm ci && npm run build && npm test -- --watch=false`"),
    ("Studio: cd studio && HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen python -m pytest -q tests/<file>.py", "docs/LOCAL-AI-ASSISTANT.md", r"`HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen python -m pytest -q tests/<file>\.py`"),
    ("make stack-e2e-bdd-check is the offline check to run before committing a .feature file", "Makefile", r"stack-e2e-bdd-check: ## STARTS NOTHING"),
    ("run with make stack-e2e-bdd against a live stack", "Makefile", r"stack-e2e-bdd: ## run the GHERKIN e2e lane \(BDD_ENV=docker\|kind\|qemu; docker needs stack-up \+ stack-seed\)"),
    ("up -d --build hugmesh-user-bff-api", "tests/stack/compose.local.yaml", r"compose\.local\.yaml up -d --build"),
    ("A cold Java build needs make stack-m2-bootstrap once", "docs/LOCAL-STACK.md", r"run \*\*`make stack-m2-bootstrap` once first\*\*"),
    ("make stack-m2-check refreshes it", "Makefile", r"re-running stack-m2-bootstrap"),
    ("Repair with bash scripts/patch-stack-src.sh", "scripts/kind-load-images.sh", r"Repair with: bash scripts/patch-stack-src\.sh"),
    ("a linked git worktree (its .git is a file) cannot be served: run from a full clone or export ARGOCD_REPO_TOKEN", "specs/cluster/bootstrap/kind-local/bootstrap-kind.sh", r"A linked worktree's \.git is a FILE"),
    ("a linked git worktree (its .git is a file) cannot be served: run from a full clone or export ARGOCD_REPO_TOKEN", "specs/cluster/bootstrap/kind-local/bootstrap-kind.sh", r"OVERRIDE — ARGOCD_REPO_TOKEN"),
    ("so other routes answer 503 behind a live route", "specs/cluster/bootstrap/kind-local/README.md", r"answer \*\*503 behind a live"),
    ("make kind-doctor reports this and never repairs", "specs/cluster/bootstrap/kind-local/README.md", r"It reports and exits non-zero; it never repairs"),
    ("scripts/studio-launch.sh --detect only reports what the host has", "scripts/studio-launch.sh", r"--detect +print the DETECT report and exit"),
    ("Every command under scripts/ must be named in docs/", "tests/scripts/test-docs-command-coverage.sh", r"every user-facing command under scripts/ must be # reachable from docs/"),
    ("No modal dialogs in Studio page logic", "studio/tests/test_devops_halt_controls.py", r"NO MODALS IN PAGE LOGIC"),
    ("tests/stack/up.sh starts only a mock lane with fake back-ends", "docs/LOCAL-STACK.md", r"The mock lane is untouched, because it runs no gateway at all"),
    # Added after a reviewer reversed the safety rules, the repo-kind lists and the node-image warning
    # and the guard stayed green: every sentence below used to be checked for names only.
    ("hugmesh-generator is the hub: Makefile, scripts/, tests/, docs/, specs/ (cluster manifests), studio/ (the desktop wizard, Python and Qt) and the image builders build-*-stage4.sh.", "README.md", r"Crossdev / native build scripts that produce \*\*hardened Gentoo images\*\*"),
    ("hugmesh-generator is the hub: Makefile, scripts/, tests/, docs/, specs/ (cluster manifests), studio/ (the desktop wizard, Python and Qt) and the image builders build-*-stage4.sh.", "scripts/clone-all-repos.sh", r"hugmesh-generator # itself is the repo this script ships in — it carries the cluster manifests"),
    ("A new guard must be shown failing: give it negative controls (a doctored input it must catch) and mutation-check it by breaking the production file and watching it go red.", "tests/scripts/test-kind-doctor.sh", r"THE MUTATION BATTERY"),
    ("A new guard must be shown failing: give it negative controls (a doctored input it must catch) and mutation-check it by breaking the production file and watching it go red.", "tests/scripts/test-guard-integrity.sh", r"NEGATIVE CONTROLS"),
    ("Every app is its own repo named hugmesh-<name>.", "scripts/clone-all-repos.sh", r"BOTH the remote repo name AND the directory name"),
    ("Java: hugmesh-gateway, hugmesh-user-bff-api, hugmesh-admin-bff-api, hugmesh-federation-api.", "scripts/clone-all-repos.sh", r"Gateways \(ONE image, run 3x as pki/be/fe via SPRING_APPLICATION_NAME\) ── hugmesh-gateway # ── Spring backend services ── hugmesh-federation-api hugmesh-admin-bff-api hugmesh-mod-bff-api hugmesh-user-bff-api"),
    ("Angular: hugmesh-host-shell, hugmesh-login-ui, hugmesh-admin-ui, hugmesh-user-ui.", "scripts/clone-all-repos.sh", r"Angular host \+ federated remotes \(each Dockerfile -> nginx\) ── .*? hugmesh-host-shell hugmesh-admin-ui hugmesh-mod-ui hugmesh-user-ui hugmesh-login-ui"),
    ("scripts/clone-all-repos.sh (run by make stack-clone) clones them into .stack-src/hugmesh-<name>.", "Makefile", r"GIT_REF='\$\(GIT_REF\)' \\ bash scripts/clone-all-repos\.sh"),
    ("The compose stack and make kind-images both build from there.", "tests/stack/compose.local.yaml", r"context: \$\{STACK_SRC:-\.\./\.\./\.stack-src\}/hugmesh-gateway"),
    ("The compose stack and make kind-images both build from there.", "scripts/kind-load-images.sh", r"STACK_SRC=\"\$\{STACK_SRC:-\$\{REPO_ROOT\}/\.stack-src\}\""),
    ("Do not edit .stack-src.", "scripts/patch-stack-src.sh", r"never hand-edit a sibling checkout"),
    ("Never hand-edit a repo under .stack-src to get the local stack to build. Add an idempotent patch function to scripts/patch-stack-src.sh instead.", "scripts/patch-stack-src.sh", r"never hand-edit a sibling checkout; # add an idempotent patch function here instead"),
    ("Work in a scratch clone with no remote.", "docs/LOCAL-AI-ASSISTANT.md", r"The assistant gets a scratch clone \*\*with no remote\*\*"),
    ("Work in a scratch clone with no remote.", "docs/LOCAL-AI-ASSISTANT.md", r"git remote remove origin +# no remote: git push has nowhere to go"),
    ("The Studio \"Repo source\" setting is either download and update into .stack-src (the default) or your own folder of hugmesh-<name> checkouts.", "docs/STUDIO-WALKTHROUGH.md", r"\*\*Repo source\*\* — download and update every repo into `\./\.stack-src` \(the default\), or point at a tree of `hugmesh-<name>` checkouts"),
    ("Docker compose stack (every service on one machine).", "docs/LOCAL-STACK.md", r"# Run the ENTIRE HugMesh stack locally \(docker-compose\)"),
    ("make stack-up builds and starts it.", "Makefile", r"stack-up: stack-clone .*## clone -> build -> run the FULL stack"),
    ("make stack-ps lists containers, make stack-logs follows them, make stack-e2e runs the browser tests.", "Makefile", r"stack-ps: ## list the local stack's containers"),
    ("make stack-ps lists containers, make stack-logs follows them, make stack-e2e runs the browser tests.", "Makefile", r"stack-logs: ## tail logs from the running local stack"),
    ("make stack-ps lists containers, make stack-logs follows them, make stack-e2e runs the browser tests.", "Makefile", r"stack-e2e: ## run the Playwright e2e suite against the RUNNING local stack"),
    ("Java services also need the Maven registry flags the Makefile adds, so when unsure use make stack-up.", "Makefile", r"STACK_M2_FLAGS = \$\(if \$\(wildcard \$\(STACK_M2_ENV\)\),--env-file \$\(STACK_M2_ENV\) -f \$\(STACK_M2_COMPOSE\),\)"),
    ("kind cluster (a slice of the real GitOps cluster).", "specs/cluster/bootstrap/kind-local/README.md", r"It is a slice, not a small > production cluster"),
    ("Studio (Python, in studio/): the wizard that builds images and starts a local mesh.", "studio/README.md", r"Calamares-style wizard"),
    ("Studio (Python, in studio/): the wizard that builds images and starts a local mesh.", "studio/README.md", r"local Docker mesh"),
    ("It wraps the two lanes above and starts nothing until a button is pressed.", "docs/STUDIO-WALKTHROUGH.md", r"Nothing runs until you press a button"),
    ("It wraps the two lanes above and starts nothing until a button is pressed.", "docs/STUDIO-WALKTHROUGH.md", r"\"Stop mesh\" runs `make stack-halt`"),
    ("It wraps the two lanes above and starts nothing until a button is pressed.", "docs/STUDIO-WALKTHROUGH.md", r"DevOps lane.*kind-halt"),
    ("Node images (Gentoo): build-x86-host-stage4.sh, build-rpi5-stage4.sh, make local.", "docs/ARCHITECTURE.md", r"All nodes are hardened Gentoo"),
    ("Node images (Gentoo): build-x86-host-stage4.sh, build-rpi5-stage4.sh, make local.", "docs/LOCAL-TESTING.md", r"make local +# builds the whole fleet for the LAN \.test domain"),
    ("They take hours and need privileges. Do not run them.", "docs/STUDIO-WALKTHROUGH.md", r"An image build takes hours"),
    ("They take hours and need privileges. Do not run them.", "README.md", r"\*\*x86_64 host image\*\* \(native, \*\*root\*\* required\)"),
    ("Guards in hugmesh-generator: bash tests/scripts/test-<name>.sh.", "docs/LOCAL-AI-ASSISTANT.md", r"\| Shell and guards \(generator\) \| `bash tests/scripts/test-<name>\.sh` \|"),
    ("They print PASS or FAIL lines and exit non-zero on failure.", "tests/scripts/test-docs-command-coverage.sh", r"ok\(\) +\{ echo \" +PASS"),
    ("They print PASS or FAIL lines and exit non-zero on failure.", "tests/scripts/test-docs-command-coverage.sh", r"bad\(\) \{ echo \" +FAIL"),
    ("Use an inline label and an explicit second click.", "studio/tests/test_pages_e2e_environment.py", r"use an inline label; exec\(\) only from a button click"),
    ("Secrets never go in a prompt, a commit or a doc. Do not read .e2e-credentials, vault files or .env files.", "docs/LOCAL-AI-ASSISTANT.md", r"\*\*No secrets in prompts\.\*\* `\.e2e-credentials`, vault files and `\.env` files stay out"),
    ("No git push, no sudo, no force.", "docs/LOCAL-AI-ASSISTANT.md", r"Never run: git push, sudo,"),
    ("Do not run make stack-down, make kind-down, make kind-up or make stack-up unless you were told to.", "docs/LOCAL-AI-ASSISTANT.md", r"docker compose up/down, make stack-\* or make kind-\*"),
    ("End every task with what you changed, what you ran and its result, and what you did NOT verify.", "docs/LOCAL-AI-ASSISTANT.md", r"End every task with: what you changed, what you ran and its result, and what you did NOT verify"),
    ("A Maven build that dies after about 11 minutes", "scripts/kind-load-images.sh", r"build will fail ~11 minutes from now"),
    ("in central\" means a git update reverted the local patches in .stack-src.", "scripts/kind-load-images.sh", r"The \.stack-src patches were reverted by a git update"),
    ("make kind-up needs read access to the GitOps repo.", "specs/cluster/bootstrap/kind-local/bootstrap-kind.sh", r"a private one needs the token"),
    ("kind loads images straight into its node and never pulls from Harbor.", "docs/KIND-SSO-E2E-FINDINGS.md", r"\*\*The kind lane never pulls from Harbor at all\*\*"),
    ("kind loads images straight into its node and never pulls from Harbor.", "docs/KIND-SSO-E2E-FINDINGS.md", r"`kind load` side-loads every first-party image"),
    ("A kind cluster can list as Ready while pods sit in ImagePullBackOff because make kind-images never ran.", "Makefile", r"`make # kind-images` had never run so no first-party image existed in the node at all"),
    ("A kind cluster can list as Ready while pods sit in ImagePullBackOff because make kind-images never ran.", "Makefile", r"Nineteen pods were in ImagePullBackOff"),
]
nbody = squash(body)
file_cache = {}
for phrase, rel, pat in ANCHORS:
    if squash(phrase) not in nbody:
        bad("j", "the primer no longer says %r; this fact was checked against %s, so re-read both before changing the anchor" % (phrase[:60], rel)); continue
    if rel not in file_cache:
        fp = os.path.join(repo, rel)
        file_cache[rel] = squash(read(fp)) if exists(fp) else None
    if file_cache[rel] is None:
        bad("j", "%s backs the primer's %r but is not in the tree" % (rel, phrase[:50]))
    elif not re.search(pat, file_cache[rel]):
        bad("j", "%s no longer says what the primer's %r relies on (pattern %r)" % (rel, phrase[:50], pat[:70]))

# ── (m) coverage: every sentence is anchored or says why it is not ──
# Anchors only protect the sentences they name, so a new fact added without one would again be checked
# for names alone. Every sentence of the primer must overlap an anchor phrase above, or appear in
# UNANCHORED with the reason; a sentence that is in neither turns this red, and so does an UNANCHORED
# entry that no longer matches a sentence (it would otherwise hide a later edit).
UNANCHORED = {
    "You are a local model helping on HugMesh, a self-hosted mesh of services (gateways, back-end services, web apps, identity, chat) that one person can run on their own machine.": "scene-setting for the model; it names no command, path or value",
    "Use only facts from this primer or from files you have read.": "an instruction to the model, not a claim about the repository",
    "When you do not know, say so and name the file or command that would tell you.": "an instruction to the model, not a claim about the repository",
}
def sentence_list(text):
    for line in text.split("\n"):
        t = squash(line).strip()
        if not t or t.startswith("#"):
            continue
        t = re.sub(r"^(- |\d+\. )", "", t)
        pos = 0
        for sent in re.split(r"(?<=[^.]\.)\s+(?=[A-Z])", t):
            if sent.strip():
                yield t, sent.strip()
phrases = sorted({squash(p) for p, _, _ in ANCHORS})
seen_unanchored = set()
for line, sent in sentence_list(body):
    a = line.index(sent)
    b = a + len(sent)
    hit = False
    for ph in phrases:
        i = line.find(ph)
        while i != -1:
            if i < b and i + len(ph) > a:
                hit = True; break
            i = line.find(ph, i + 1)
        if hit: break
    if sent in UNANCHORED:
        seen_unanchored.add(sent)
        if hit:
            bad("m", "%r is listed as unanchored but an anchor now covers it; delete it from UNANCHORED" % sent[:60])
    elif not hit:
        bad("m", "the primer sentence %r has no anchor; add an ANCHORS entry tying it to the repository file that backs it, or list it in UNANCHORED with the reason" % sent[:70])
for sent in UNANCHORED:
    if sent not in seen_unanchored:
        bad("m", "UNANCHORED lists %r, which is no longer a primer sentence" % sent[:60])

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
                    # In the PRIMER, not merely somewhere in the repository: a word the primer no longer
                    # says makes the question unanswerable from it, and the score would then measure luck.
                    if w not in nb:
                        bad("h", "%s: the expected word %r is not in the primer" % (qid, w))

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
# (j) fact anchors. Each of these edits keeps every NAME the primer uses and changes only what it
# says about them, which is exactly what rules (a) to (b) cannot see. The first six are the edits
# a reviewer tried by hand against the earlier guard; all six used to pass.
primer_sub() { # <old> <new>: replace one exact string in the primer body; non-zero if it is not there
  python3 - "$T/d/primer.md" "$1" "$2" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
i = s.index("<!-- SOURCES")
if old not in s[:i]:
    sys.exit(1)
open(p, "w").write(s[:i].replace(old, new, 1) + s[i:])
PY
}
anchor_control() { # <why> <old> <new>
  fresh
  if ! primer_sub "$2" "$3"; then bad "negative control setup: the primer has no text '$2' ($1)"; return; fi
  expect_caught j "$1"
}
anchor_control "the front door port changed" "Front door http://localhost:8088" "Front door http://localhost:9999"
anchor_control "stack-halt and stack-down swapped" "make stack-halt stops and keeps the data; make stack-down deletes the volumes" "make stack-down stops and keeps the data; make stack-halt deletes the volumes"
anchor_control "the tunnel MTU changed" "(WireGuard is 1420)" "(WireGuard is 9000)"
anchor_control "stack-clone said to run another git command" "make stack-clone runs git reset --hard on each checkout" "make stack-clone runs git clean on each checkout"
anchor_control "the kind order reversed" "Order: make kind-up, then make kind-images, then make kind-doctor" "Order: make kind-doctor, then make kind-images, then make kind-up"
anchor_control "the Java test command changed" "Java: ./mvnw -B verify" "Java: ./mvnw -B clean"
anchor_control "kind-halt and kind-down swapped" "make kind-halt stops without deleting; make kind-down deletes the cluster" "make kind-down stops without deleting; make kind-halt deletes the cluster"
# The mutations a reviewer kept green on the first version of this guard: the house rules, the repo-kind
# lists, the node-image warning and the scratch-clone sentence. Each one flips the meaning and keeps every name.
anchor_control "the scratch-clone sentence lost its 'no remote'" "Work in a scratch clone with no remote." "Work in a scratch clone."
anchor_control "the no-push, no-sudo rule turned into permission" "No git push, no sudo, no force." "Feel free to git push and use sudo."
anchor_control "the node-image warning reversed" "They take hours and need privileges. Do not run them." "They take seconds and need nothing. Run them freely."
anchor_control "the Do-not-run list for stack-down turned into advice to run them" "Do not run make stack-down, make kind-down, make kind-up or make stack-up unless you were told to." "Run make stack-down, make kind-down, make kind-up and make stack-up whenever you like."
fresh; primer_sub "Java: hugmesh-gateway, " "Java: " && primer_sub "Angular: hugmesh-host-shell" "Angular: hugmesh-gateway, hugmesh-host-shell" && expect_caught j "the gateway moved from the Java list to the Angular list" || bad "negative control setup: the repo-kind lists were not found"
# (h) now needs the expected word in the PRIMER: dropping 'no remote' makes scratch-clone unanswerable from it,
# which the old rule (any repository file would do) let through.
fresh; primer_sub "Work in a scratch clone with no remote." "Work in a scratch clone." && expect_caught h "a question whose expected word the primer no longer says" || bad "negative control setup: no scratch-clone sentence"
# (m) a sentence nobody anchored, and an exemption that no longer matches anything.
fresh; primer_insert "- Run make kind-images before anything else on a new PC."; expect_caught m "a new unanchored sentence"
fresh; primer_sub "Use only facts from this primer or from files you have read. " "" && expect_caught m "an exemption left behind after its sentence was deleted" || bad "negative control setup: no exemption sentence"
# The other side of an anchor: the repository stops saying what the primer relies on. The file is
# doctored in a copy of the tree (every other entry is a symlink to the real one).
doctor_repo() { # <relative file> <old> <new>
  python3 - "$REPO" "$T/r" "$1" "$2" "$3" <<'PY'
import os, shutil, sys
repo, dst, rel, old, new = sys.argv[1:6]
shutil.rmtree(dst, ignore_errors=True); os.makedirs(dst)
def mirror(src, out, parts):
    for n in os.listdir(src):
        if n == ".git":
            continue
        sp, op = os.path.join(src, n), os.path.join(out, n)
        if parts and n == parts[0]:
            if len(parts) == 1:
                t = open(sp, encoding="utf-8", errors="replace").read()
                if old not in t:
                    sys.exit("setup: %r is not in %s" % (old, rel))
                open(op, "w", encoding="utf-8").write(t.replace(old, new, 1))
            else:
                os.makedirs(op); mirror(sp, op, parts[1:])
        else:
            os.symlink(sp, op)
mirror(repo, dst, rel.split("/"))
PY
}
repo_control() { # <why> <file> <old> <new>
  if ! doctor_repo "$2" "$3" "$4"; then bad "negative control setup: could not doctor $2 ($1)"; return; fi
  out=$(CHK_SKIP=f python3 "$T/chk.py" "$T/r" "$REPO/local-ai" "$REPO/scripts/local-ai-agents.sh" "$T/corpus.txt" \
    "$BYTE_LIMIT" "$TOKEN_BUDGET" "$MEASURED_TOKENS" "$MEASURED_BYTES" "$STALE_PERCENT")
  if printf '%s\n' "$out" | grep -F "(j)" >/dev/null; then ok "negative control: $1 — caught by (j)"
  else bad "negative control: $1 — NOT caught by (j)"; printf '%s\n' "$out" | sed 's/^/       saw: /' | head -3; fi
}
repo_control "the Makefile no longer says stack-halt keeps the data" Makefile "stack-halt: ## stop the local stack but KEEP its data" "stack-halt: ## stop the local stack and drop its data"
repo_control "the local-stack doc moved the front door" docs/LOCAL-STACK.md "**http://localhost:8088** (the fe-gateway front door" "**http://localhost:9999** (the fe-gateway front door"
repo_control "the image script no longer states the tunnel MTU" scripts/kind-load-images.sh "WireGuard is 1420" "WireGuard is 9000"
repo_control "the clone script no longer groups the gateway with the Spring services" scripts/clone-all-repos.sh "# ── Spring backend services ──" "# ── Angular services ──"
repo_control "the Makefile no longer says make stack-up is the full clone-build-run" Makefile "## clone -> build -> run the FULL stack" "## do something else entirely"
repo_control "the README of the kind lane no longer calls the cluster a slice" specs/cluster/bootstrap/kind-local/README.md "It is a slice, not a small" "It is a whole production"
repo_control "the kind README no longer states the order" specs/cluster/bootstrap/kind-local/README.md '`kind-up` THEN `kind-images`' '`kind-images` THEN `kind-up`'

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

# ── help: the usage text is the whole header comment, not its first dozen lines ─────────────────────
# usage() once printed a fixed line range, which stopped after the first of the four models and cut off
# the WHY and WHAT IT WILL NOT DO sections. The expected text is read from the script's leading comment
# block HERE, with its own rule (everything from line 2 to the first line that is not a comment).
echo "== help"
want=$(python3 - "$REPO/scripts/local-ai-agents.sh" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split("\n")[1:]
out = []
for l in lines:
    if not l.startswith("#"):
        break
    out.append(re.sub(r"^# ?", "", l))
print("\n".join(out))
PY
)
for how in help --help -h ""; do
  got=$(bash "$REPO/scripts/local-ai-agents.sh" $how 2>&1); rc=$?
  want_rc=0; [ -z "$how" ] && want_rc=2
  missing=""
  for w in hugmesh-agent hugmesh-coder hugmesh-reviewer hugmesh-triage "WHY ONE PRIMER" "WHAT IT WILL NOT DO" "A SYSTEM BLOCK IS NOT ALWAYS SENT" "Env:"; do
    printf '%s\n' "$got" | grep -F -e "$w" >/dev/null || missing="$missing [$w]"
  done
  if [ "$rc" = "$want_rc" ] && [ "$got" = "$want" ] && [ -z "$missing" ]; then ok "'${how:-no argument}' prints the whole header (all four models and every section) and exits $want_rc"
  else bad "'${how:-no argument}': rc=$rc (wanted $want_rc), $(printf '%s\n' "$got" | wc -l) lines against $(printf '%s\n' "$want" | wc -l), missing:$missing"; fi
done
bash "$REPO/scripts/local-ai-agents.sh" frobnicate >"$T/o" 2>"$T/e"; rc=$?
if [ "$rc" = 2 ] && grep -F "unknown subcommand 'frobnicate'" "$T/e" >/dev/null && grep -F "hugmesh-triage" "$T/e" >/dev/null; then ok "an unknown subcommand exits 2, names itself and prints the full usage on stderr"
else bad "unknown subcommand: rc=$rc, $(head -c 200 "$T/e")"; fi

# ── `test`: the scorer, the table, the verdict and the base column, against a stub Ollama API ──────
# The prepared-versus-base comparison is the evidence behind the word "prepared", so the code that
# produces it is checked here with no Ollama at all: a small HTTP server answers /api/version and
# /api/chat from a fixed table and logs every request, and `test` runs against it with a fixed
# questions file. The table, the totals and the verdict are compared line for line, then the same
# checks are run against copies of the script with one defect planted in each of four places
# (the scorer needs EVERY term, the order marker >> is honoured, the verdict needs a strictly higher
# score, the base column asks the BASE model) and each copy must fail at least one check.
echo "== the scorer and the verdict against a stub API"
cat > "$T/api-stub.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
state = os.environ["STUB_DIR"]
BASE, PREP = "qwen3:8b", "hugmesh-agent"
def answer(model, system, q):
    if open(os.path.join(state, "mode")).read().strip() == "same":
        return "alpha beta one two y same"
    if system:                      # a caller's own system message replaces the Modelfile's text
        return "irrelevant"
    if model == PREP:
        return {"q-and": "Alpha and BETA", "q-order": "one, then two", "q-or": "y",
                "q-md": "**`Same`**"}[q]
    return {"q-and": "alpha only", "q-order": "two, then one", "q-or": "z",
            "q-md": "same"}[q]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        self._send({"version": "0.0-stub"})
    def do_POST(self):
        d = json.loads(self.rfile.read(int(self.headers["content-length"])))
        msgs = d["messages"]
        system = next((m["content"] for m in msgs if m["role"] == "system"), "")
        q = next(m["content"] for m in msgs if m["role"] == "user")
        with open(os.path.join(state, "requests"), "a") as fh:
            fh.write("%s\t%s\t%s\n" % (d["model"], "system" if system else "none", q))
        self._send({"message": {"content": answer(d["model"], system, q)}})
srv = HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(state, "port"), "w").write(str(srv.server_port))
srv.serve_forever()
PY
printf 'id\tquestion\texpect\nq-and\tq-and\talpha && beta\nq-order\tq-order\tone >> two\nq-or\tq-or\tx || y\nq-md\tq-md\tsame\n' > "$T/stub-questions.tsv"
mkdir -p "$T/api"; : > "$T/api/requests"; echo differ > "$T/api/mode"
STUB_DIR="$T/api" python3 "$T/api-stub.py" & API_PID=$!
trap 'kill "$API_PID" 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 1 50); do [ -s "$T/api/port" ] && break; sleep 0.1; done
API_PORT=$(cat "$T/api/port" 2>/dev/null || true)
stub_reset qwen3:8b hugmesh-agent
api_test() { # <script> [args]: run `test` against the stub API; stdout to $T/o, stderr to $T/e
  local sc="$1"; shift
  PATH="$T/bin:$PATH" STUB_STATE="$T/state" OLLAMA_HOST="127.0.0.1:${API_PORT}" LOCAL_AI_DIR="$REPO/local-ai" \
    bash "$sc" test --questions "$T/stub-questions.tsv" "$@" >"$T/o" 2>"$T/e"
}
api_checks() { # <script> <label>: prints one line per failed check; empty = all held
  local sc="$1" rc cnt n
  echo differ > "$T/api/mode"; : > "$T/api/requests"
  api_test "$sc" --out "$T/api/out.tsv"; rc=$?
  [ "$rc" = 0 ] || echo "test exited $rc: $(head -c 150 "$T/e")"
  grep -Fx '| id | base | prepared | prepared+own system message |' "$T/o" >/dev/null || echo "header line differs"
  for row in '| q-and | FAIL | pass | FAIL |' '| q-order | FAIL | pass | FAIL |' '| q-or | FAIL | pass | FAIL |' '| q-md | pass | pass | FAIL |'; do
    grep -Fx "$row" "$T/o" >/dev/null || echo "row missing: $row"
  done
  grep -Fx '| **total** | **1/4** | **4/4** | **0/4** |' "$T/o" >/dev/null || echo "totals differ: $(grep -F total "$T/o")"
  grep -Fx 'VERDICT: prepared 4/4 vs base 1/4: prepared answered more correctly' "$T/o" >/dev/null || echo "verdict differs: $(grep -F VERDICT "$T/o")"
  grep -F 'GAP: ' "$T/o" | grep -F 'prepared scored 0/4' >/dev/null || echo "gap line differs"
  # which model each column asked, and with what system message
  n=$(grep -c "^qwen3:8b	none	" "$T/api/requests") ; [ "$n" = 4 ] || echo "base column: $n unprepared requests to the base model, wanted 4"
  n=$(grep -c "^hugmesh-agent	none	" "$T/api/requests"); [ "$n" = 4 ] || echo "prepared column: $n requests, wanted 4"
  n=$(grep -c "^hugmesh-agent	system	" "$T/api/requests"); [ "$n" = 4 ] || echo "own-system column: $n requests, wanted 4"
  n=$(grep -c "^qwen3:8b	system	" "$T/api/requests"); [ "$n" = 0 ] || echo "the base was sent a system message $n times"
  [ "$(grep -c . "$T/api/out.tsv" 2>/dev/null)" = 13 ] || echo "--out file does not hold a header and 12 answers"
  # a model that scores no better than the base must not be called better, and --strict must say so
  echo same > "$T/api/mode"
  api_test "$sc" --strict; rc=$?
  [ "$rc" = 1 ] || echo "equal scores with --strict exited $rc, wanted 1"
  grep -Fx 'VERDICT: prepared 4/4 vs base 4/4: prepared did NOT answer more correctly than the base' "$T/o" >/dev/null || echo "equal-score verdict differs: $(grep -F VERDICT "$T/o")"
  echo differ > "$T/api/mode"
  api_test "$sc" --strict; rc=$?
  [ "$rc" = 0 ] || echo "a better prepared model with --strict exited $rc, wanted 0"
}
if [ -z "$API_PORT" ]; then bad "the stub API did not start"
else
  fails=$(api_checks "$REPO/scripts/local-ai-agents.sh")
  if [ -z "$fails" ]; then ok "test prints the table, totals, verdict and gap exactly, asks the right model in each column, and honours --strict"
  else bad "test against the stub API: $(printf '%s' "$fails" | tr '\n' ';')"; fi
  battery() { # <why> <old> <new>
    if ! variant "$T/variant.sh" "$2" "$3"; then bad "negative control setup: the line to break in the script was not found ($1)"; return; fi
    fails=$(api_checks "$T/variant.sh")
    if [ -n "$fails" ]; then ok "negative control: $1 — caught ($(printf '%s' "$fails" | head -1 | cut -c1-70))"
    else bad "negative control: $1 — NOT caught"; fi
  }
  battery "a scorer that needs only ONE of the required terms" 'return all(any(found(text, seq) for seq in alts) for alts in terms)' 'return any(any(found(text, seq) for seq in alts) for alts in terms)'
  battery "a scorer that ignores the >> order" 'pos = i + len(part)' 'pos = 0'
  battery "a verdict that accepts a tie" 'better = totals[1] > totals[0]' 'better = totals[1] >= totals[0]'
  battery "a base column that asks the prepared model" 'columns = [("base", base, None), ("prepared", model, None)]' 'columns = [("base", model, None), ("prepared", model, None)]'
fi
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
trap 'rm -rf "$T"' EXIT

# a harmless edit must stay clean (the checker is not just always-failing)
fresh; primer_sub "Do not run them." "Do  not  run them."; primer_sub "make stack-ps lists containers," "make stack-ps lists  containers,"
out=$(problems "$T/d")
if [ -z "$out" ]; then ok "negative control: doubled spaces — clean"; else bad "a doubled space was flagged: $out"; fi

echo; echo "== local-ai primer: $P passed, $F failed =="
[ "$F" -eq 0 ]

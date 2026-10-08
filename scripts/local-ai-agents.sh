#!/usr/bin/env bash
# local-ai-agents.sh — build Ollama models that already know this mesh, from one vetted primer.
#
#   scripts/local-ai-agents.sh create [--dry-run] [name ...]   build (or rebuild) the models
#   scripts/local-ai-agents.sh list                            which of them exist on this PC
#   scripts/local-ai-agents.sh remove [name ...]               delete the ones this script made
#   scripts/local-ai-agents.sh test [options]                  prepared model vs plain base, scored
#   scripts/local-ai-agents.sh print <name>                    show a model's Modelfile, the primer
#                                                              or a role file
#
# Models (all names start with hugmesh-):
#   hugmesh-agent     tool-driven work in a scratch clone      base qwen3:8b          (BASE_AGENT)
#   hugmesh-coder     one-file code edits in a chat            base qwen2.5-coder:7b  (BASE_CODER)
#   hugmesh-reviewer  reviews a diff as file:line - problem    base qwen3:8b          (BASE_AGENT)
#   hugmesh-triage    reads a failing log: cause, class, next  base qwen3:8b          (BASE_AGENT)
#
# WHY ONE PRIMER, ASSEMBLED AT CREATE TIME. local-ai/primer.md is the product: a short, checked
# description of this mesh (repositories, the lanes and their commands, test commands, house rules,
# documented traps). Each local-ai/modelfiles/<name>.Modelfile holds only the base, the parameters
# and a role paragraph. This script puts the primer in front of the role paragraph inside the
# Modelfile's SYSTEM block, so the primer is written once and cannot drift between the four.
# tests/scripts/test-local-ai-primer.sh checks every make target, variable, repository and path the
# primer names, and, for its load-bearing claims, what the primer says about them.
#
# WHAT IT WILL NOT DO. It never pulls: a missing base stops with the exact `ollama pull` command
# (an `ollama create` on a base that is not on disk would download it). It talks only to a
# loopback Ollama (OLLAMA_HOST must be 127.0.0.1, localhost or ::1). It deletes and overwrites
# only the four names above, and only when the model carries the marker this script writes into
# it; a model of the same name that someone else made is left alone and named in the message.
#
# A SYSTEM BLOCK IS NOT ALWAYS SENT. Ollama uses the Modelfile's SYSTEM text only when a request
# has no system message of its own. A coding-agent harness (ollama launch claude ...) sends one,
# so under a harness the primer does NOT arrive through the model: print it into the scratch
# clone's CLAUDE.md instead (`print primer`). `test` measures both cases.
#
# Env: BASE_AGENT, BASE_CODER (a bigger base), OLLAMA_HOST (loopback only), LOCAL_AI_DIR (another
# local-ai/ tree, used by the guard's negative controls), TMPDIR.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
LOCAL_AI="${LOCAL_AI_DIR:-${REPO_ROOT}/local-ai}"
PRIMER="${LOCAL_AI}/primer.md"
MODELFILES="${LOCAL_AI}/modelfiles"
ROLE_FILES="${LOCAL_AI}/agents"

MODELS=(hugmesh-agent hugmesh-coder hugmesh-reviewer hugmesh-triage)
# Written into each model's licence text; `remove` and `create` look for the id before they touch
# a model, which is how "never delete a model this script did not create" is enforced.
MARKER_ID="hugmesh-local-ai:"
MARKER="${MARKER_ID} prepared by scripts/local-ai-agents.sh from local-ai/primer.md. The base model's own licence still applies to the weights."
PRIMER_CUT='<!-- SOURCES'

die() { echo "local-ai-agents: $1" >&2; exit "${2:-1}"; }

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

known_model() { # <name>
  local m
  for m in "${MODELS[@]}"; do [ "$m" = "$1" ] && return 0; done
  return 1
}

# base for a model: the env override when set, else the FROM line of its role Modelfile.
base_of() { # <name>
  local name="$1" override="" rf="${MODELFILES}/$1.Modelfile"
  case "${name}" in
    hugmesh-coder) override="${BASE_CODER:-}" ;;
    *)             override="${BASE_AGENT:-}" ;;
  esac
  if [ -n "${override}" ]; then printf '%s\n' "${override}"; return 0; fi
  [ -f "${rf}" ] || die "no Modelfile for ${name} at ${rf}" 2
  awk '/^FROM /{print $2; exit}' "${rf}"
}

# The primer as it is used: everything before the first line that starts the SOURCES comment,
# without trailing blank lines. $(...) drops the trailing newlines.
primer_text() {
  [ -f "${PRIMER}" ] || die "no primer at ${PRIMER}" 2
  awk -v cut="${PRIMER_CUT}" '
    index($0, cut) == 1 {exit}
    $0 == ""            {blank++; next}
    {while (blank > 0) {print ""; blank--} print}
  ' "${PRIMER}"
}

# The role paragraph of a Modelfile: the lines between `SYSTEM """` and the closing `"""`.
role_text() { # <name>
  awk '
    state == 0 && $0 == "SYSTEM \"\"\"" {state = 1; next}
    state == 1 && $0 == "\"\"\""         {state = 2; next}
    state == 1                           {print}
  ' "${MODELFILES}/$1.Modelfile"
}

# Everything outside the SYSTEM block, with FROM replaced by the resolved base.
header_text() { # <name> <base>
  awk -v base="$2" '
    state == 0 && $0 == "SYSTEM \"\"\"" {state = 1; next}
    state == 1 && $0 == "\"\"\""         {state = 2; next}
    state == 1                           {next}
    /^FROM /                             {print "FROM " base; next}
    {print}
  ' "${MODELFILES}/$1.Modelfile"
}

# The Modelfile `create` hands to ollama, and `--dry-run` / `print` show: the role file's own lines
# (FROM resolved), the marker, then SYSTEM = primer, a blank line, the role paragraph.
assemble() { # <name>
  local name="$1" base primer role
  known_model "${name}" || die "unknown model '${name}'. Known: ${MODELS[*]}" 2
  [ -f "${MODELFILES}/${name}.Modelfile" ] || die "no Modelfile for ${name}" 2
  base="$(base_of "${name}")"
  primer="$(primer_text)"
  role="$(role_text "${name}" | sed '/./,$!d')"
  [ -n "${primer}" ] || die "the primer is empty" 2
  [ -n "${role}" ] || die "${name}.Modelfile has no SYSTEM block" 2
  case "${primer}${role}" in
    *'"""'*) die "a triple quote in the primer or role text would close the SYSTEM block early" 2 ;;
  esac
  header_text "${name}" "${base}"
  printf 'LICENSE """%s"""\n' "${MARKER}"
  printf 'SYSTEM """\n%s\n\n%s\n"""\n' "${primer}" "${role}"
}

# ── the loopback rule ────────────────────────────────────────────────────────
# The Ollama API has no login, so this script talks to a server on this machine only. Anything
# else (0.0.0.0, a LAN address, a hostname) is refused rather than guessed at.
OLLAMA_URL=""
require_loopback() {
  local raw="${OLLAMA_HOST:-127.0.0.1:11434}" hostport host port
  hostport="${raw#http://}"; hostport="${hostport#https://}"; hostport="${hostport%%/*}"
  case "${hostport}" in
    \[*\]*) host="${hostport%%]*}"; host="${host#[}"; port="${hostport##*]}"; port="${port#:}" ;;
    *:*)    host="${hostport%%:*}"; port="${hostport##*:}" ;;
    *)      host="${hostport}"; port="" ;;
  esac
  # Four dotted numbers starting 127, not a name that merely begins "127." (DNS allows one).
  case "${host}" in
    localhost|::1) ;;
    *) [[ "${host}" =~ ^127(\.[0-9]{1,3}){3}$ ]] \
         || die "OLLAMA_HOST='${raw}' is not loopback. Use 127.0.0.1:11434 (the API has no login; see docs/LOCAL-AI-ASSISTANT.md section 8)." 2 ;;
  esac
  [ -n "${port}" ] || port=11434
  case "${host}" in ::1) host="[::1]" ;; esac
  OLLAMA_URL="http://${host}:${port}"
  export OLLAMA_HOST="${host}:${port}"
}

need_ollama() {
  require_loopback
  command -v ollama >/dev/null 2>&1 || die "ollama is not installed (docs/LOCAL-AI-ASSISTANT.md section 2)" 3
  ollama list >/dev/null 2>&1 || die "no Ollama answering on ${OLLAMA_HOST} (start it: docs/LOCAL-AI-ASSISTANT.md section 3)" 3
}

have_model() { ollama show "$1" >/dev/null 2>&1; }

# True when the model carries this script's marker. grep reads to the end (no -q) so that the
# writer on the other side of the pipe never gets SIGPIPE under pipefail.
is_ours() {
  ollama show "$1" --license 2>/dev/null | grep -F "${MARKER_ID}" >/dev/null
}

# ── create ───────────────────────────────────────────────────────────────────
cmd_create() {
  local dry=0 names=() a name base tmp
  for a in "$@"; do
    case "${a}" in
      --dry-run) dry=1 ;;
      -*) die "create: unknown option ${a}" 2 ;;
      *) names+=("${a}") ;;
    esac
  done
  [ "${#names[@]}" -gt 0 ] || names=("${MODELS[@]}")
  for name in "${names[@]}"; do known_model "${name}" || die "unknown model '${name}'. Known: ${MODELS[*]}" 2; done

  if [ "${dry}" = 1 ]; then
    # No ollama, no network: show exactly what would be sent. The banner goes to stderr so that
    # stdout is the Modelfile and nothing else.
    for name in "${names[@]}"; do
      echo "# --dry-run: ${name}" >&2
      assemble "${name}"
    done
    return 0
  fi

  need_ollama
  # Check every base and every name BEFORE creating anything, so a refusal leaves no half-built set.
  for name in "${names[@]}"; do
    base="$(base_of "${name}")"
    have_model "${base}" || die "the base model ${base} is not on this PC. Pull it first: ollama pull ${base}" 3
    if have_model "${name}" && ! is_ours "${name}"; then
      die "a model called ${name} already exists and was not made by this script; leaving it alone. Rename or remove it yourself, then run create again." 4
    fi
  done
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/local-ai-agents.XXXXXX")"
  trap "rm -rf '${tmp}'" EXIT
  for name in "${names[@]}"; do
    base="$(base_of "${name}")"
    assemble "${name}" > "${tmp}/${name}.Modelfile"
    echo "==> ${name} (base ${base})"
    ollama create "${name}" -f "${tmp}/${name}.Modelfile"
  done
  echo "==> done. Try: ollama run hugmesh-agent --think=false \"How do I rebuild one image on kind?\""
}

# ── list ─────────────────────────────────────────────────────────────────────
cmd_list() {
  local name row who
  need_ollama
  printf '%-18s %-8s %s\n' MODEL STATE DETAIL
  for name in "${MODELS[@]}"; do
    if have_model "${name}"; then
      if is_ours "${name}"; then who="made by this script"; else who="NOT made by this script (left alone)"; fi
      row="$(ollama list | awk -v n="${name}:latest" '$1 == n {print $3, $4}')"
      printf '%-18s %-8s %s, %s\n' "${name}" present "${row:-size unknown}" "${who}"
    else
      printf '%-18s %-8s %s\n' "${name}" missing "scripts/local-ai-agents.sh create ${name}"
    fi
  done
}

# ── remove ───────────────────────────────────────────────────────────────────
cmd_remove() {
  local names=("$@") name
  [ "${#names[@]}" -gt 0 ] || names=("${MODELS[@]}")
  for name in "${names[@]}"; do known_model "${name}" || die "refusing to remove '${name}': this script manages only ${MODELS[*]}" 2; done
  need_ollama
  for name in "${names[@]}"; do
    if ! have_model "${name}"; then echo "${name}: not present"; continue; fi
    if ! is_ours "${name}"; then echo "${name}: present but not made by this script; NOT removed"; continue; fi
    ollama rm "${name}"
  done
}

# ── print ────────────────────────────────────────────────────────────────────
cmd_print() {
  local what="${1:-}"
  [ -n "${what}" ] || die "print: give a model name, 'primer' or a role file name (${MODELS[*]} | primer | mesh-builder | mesh-tester | mesh-reviewer)" 2
  case "${what}" in
    primer) primer_text ;;
    mesh-builder|mesh-tester|mesh-reviewer) cat "${ROLE_FILES}/${what}.md" ;;
    *) assemble "${what}" ;;
  esac
}

# The primer's size in the base model's own tokens: the primer text alone, sent raw (no chat
# template) so the count is the primer's and nothing else. The number goes into the guard's
# MEASURED_TOKENS (tests/scripts/test-local-ai-primer.sh). A cached prompt can report fewer tokens,
# so the request is made twice and both counts are printed.
count_primer_tokens() { # <base model>
  local text
  text="$(primer_text)"
  PRIMER_BODY="${text}" QA_URL="${OLLAMA_URL}" QA_BASE="$1" python3 - <<'PY'
import json, os, urllib.request
url, base = os.environ["QA_URL"], os.environ["QA_BASE"]
body = os.environ["PRIMER_BODY"].rstrip("\n") + "\n"
counts = []
for _ in range(2):
    req = urllib.request.Request(url + "/api/generate", data=json.dumps({
        "model": base, "prompt": body, "raw": True, "stream": False,
        "options": {"num_predict": 1, "num_ctx": 8192, "temperature": 0}}).encode(),
        headers={"content-type": "application/json"})
    counts.append(json.load(urllib.request.urlopen(req, timeout=600)).get("prompt_eval_count"))
ver = json.load(urllib.request.urlopen(url + "/api/version", timeout=30)).get("version", "?")
print("primer: %d bytes, %s tokens (second run %s) on %s, Ollama %s" % (len(body.encode()), counts[0], counts[1], base, ver))
PY
}

# ── test: prepared vs plain base ─────────────────────────────────────────────
# Same questions, same options, no system message, one request at a time (the GPU is shared).
# Three columns: the plain base; the prepared model; the prepared model when the caller sends its
# own generic system message (which replaces the Modelfile's SYSTEM text, so it shows what a
# harness that sends one gets). The score is a substring check, not a judgement: see the questions
# file header for the syntax.
cmd_test() {
  local model="hugmesh-agent" base="" questions="${LOCAL_AI}/eval/questions.tsv" out="" ctx=16384 npred=200 limit=0 strict=0 generic=1 tokens=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --model) model="${2:?--model needs a name}"; shift 2 ;;
      --base) base="${2:?--base needs a model}"; shift 2 ;;
      --questions) questions="${2:?--questions needs a file}"; shift 2 ;;
      --out) out="${2:?--out needs a file}"; shift 2 ;;
      --num-ctx) ctx="${2:?}"; shift 2 ;;
      --num-predict) npred="${2:?}"; shift 2 ;;
      --limit) limit="${2:?}"; shift 2 ;;
      --no-generic) generic=0; shift ;;
      --tokens) tokens=1; shift ;;
      --strict) strict=1; shift ;;
      *) die "test: unknown option $1" 2 ;;
    esac
  done
  known_model "${model}" || die "unknown model '${model}'. Known: ${MODELS[*]}" 2
  [ -n "${base}" ] || base="$(base_of "${model}")"
  [ -f "${questions}" ] || die "no questions file at ${questions}" 2
  need_ollama
  have_model "${model}" || die "${model} does not exist yet: scripts/local-ai-agents.sh create ${model}" 3
  have_model "${base}" || die "the base model ${base} is not on this PC: ollama pull ${base}" 3
  command -v python3 >/dev/null 2>&1 || die "python3 is required for the scorer" 3
  if [ "${tokens}" = 1 ]; then count_primer_tokens "${base}"; return 0; fi

  QA_URL="${OLLAMA_URL}" QA_MODEL="${model}" QA_BASE="${base}" QA_Q="${questions}" QA_OUT="${out}" \
  QA_CTX="${ctx}" QA_NPRED="${npred}" QA_LIMIT="${limit}" QA_STRICT="${strict}" QA_GENERIC="${generic}" \
  python3 - <<'PY'
import json, os, re, sys, time, urllib.request

url = os.environ["QA_URL"]; model = os.environ["QA_MODEL"]; base = os.environ["QA_BASE"]
ctx = int(os.environ["QA_CTX"]); npred = int(os.environ["QA_NPRED"]); limit = int(os.environ["QA_LIMIT"])
generic = os.environ["QA_GENERIC"] == "1"
GENERIC_SYSTEM = "You are a helpful assistant."

def norm(s):
    # Markdown emphasis and code ticks must not hide a correct answer from a substring check.
    s = s.lower().replace("`", "").replace("*", "")
    return re.sub(r"\s+", " ", s).strip()

def parse_expect(spec):
    # "a || b && c" = (a or b) and c; "a >> b" = b appears after a.
    return [[[norm(p) for p in alt.split(">>")] for alt in term.split("||") if alt.strip()]
            for term in spec.split("&&") if term.strip()]

def found(text, seq):
    pos = 0
    for part in seq:
        i = text.find(part, pos)
        if i < 0:
            return False
        pos = i + len(part)
    return True

def scored(answer, terms):
    text = norm(answer)
    return all(any(found(text, seq) for seq in alts) for alts in terms)

def post(path, body):
    req = urllib.request.Request(url + path, data=json.dumps(body).encode(),
                                 headers={"content-type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=600))

def ask(name, question, system):
    msgs = ([{"role": "system", "content": system}] if system else []) + [{"role": "user", "content": question}]
    d = post("/api/chat", {"model": name, "stream": False, "think": False, "keep_alive": "10m",
                           "messages": msgs,
                           "options": {"temperature": 0, "seed": 0, "num_predict": npred, "num_ctx": ctx}})
    return d["message"]["content"]

rows = []
for line in open(os.environ["QA_Q"], encoding="utf-8"):
    line = line.rstrip("\n")
    if not line.strip() or line.startswith("#"):
        continue
    parts = line.split("\t")
    if len(parts) != 3 or parts[0] == "id":
        if parts[0] == "id":
            continue
        sys.exit("bad questions line (need id<TAB>question<TAB>expect): %r" % line)
    rows.append(parts)
if limit:
    rows = rows[:limit]

version = json.load(urllib.request.urlopen(url + "/api/version", timeout=30)).get("version", "?")
columns = [("base", base, None), ("prepared", model, None)]
if generic:
    columns.append(("prepared+own system message", model, GENERIC_SYSTEM))
totals = [0] * len(columns)
out_rows = []
print("# prepared %s vs base %s, Ollama %s, %s, num_ctx %d, num_predict %d, temperature 0, think off, no system message"
      % (model, base, version, time.strftime("%Y-%m-%d"), ctx, npred))
header = "| id | " + " | ".join(c[0] for c in columns) + " |"
print(header); print("|" + "---|" * (len(columns) + 1))
for qid, question, expect in rows:
    terms = parse_expect(expect)
    cells = []
    for i, (label, name, system) in enumerate(columns):
        ans = ask(name, question, system)
        ok = scored(ans, terms)
        totals[i] += 1 if ok else 0
        cells.append("pass" if ok else "FAIL")
        out_rows.append((qid, label, "pass" if ok else "fail", ans.replace("\n", " ")[:400]))
    print("| %s | %s |" % (qid, " | ".join(cells)))
    sys.stdout.flush()
n = len(rows)
print("| **total** | " + " | ".join("**%d/%d**" % (t, n) for t in totals) + " |")
better = totals[1] > totals[0]
print("VERDICT: prepared %d/%d vs base %d/%d: %s" % (totals[1], n, totals[0], n,
      "prepared answered more correctly" if better else "prepared did NOT answer more correctly than the base"))
if generic:
    print("GAP: with a system message of the caller's own, prepared scored %d/%d (the Modelfile SYSTEM text is replaced, not added to)" % (totals[2], n))
if os.environ.get("QA_OUT"):
    with open(os.environ["QA_OUT"], "w", encoding="utf-8") as fh:
        fh.write("id\tcolumn\tresult\tanswer_start\n")
        for r in out_rows:
            fh.write("\t".join(r) + "\n")
sys.exit(0 if (better or os.environ["QA_STRICT"] != "1") else 1)
PY
}

main() {
  local sub="${1:-}"
  [ "$#" -gt 0 ] && shift
  case "${sub}" in
    create) cmd_create "$@" ;;
    list) cmd_list ;;
    remove) cmd_remove "$@" ;;
    test) cmd_test "$@" ;;
    print) cmd_print "$@" ;;
    -h|--help|help|"") usage; [ -n "${sub}" ] || exit 2 ;;
    *) usage >&2; die "unknown subcommand '${sub}'" 2 ;;
  esac
}
main "$@"

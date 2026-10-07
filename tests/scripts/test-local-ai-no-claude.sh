#!/usr/bin/env bash
# test-local-ai-no-claude.sh — the local-AI tooling must run with NO Claude program,
# NO Anthropic service and NO API key, and must never reach for one on its own.
#
# THE RULE (operator request, hugmesh-generator#698): everything that runs work on a
# local model works from commands shipped in this repository, without Claude. The one
# thing allowed to name the Claude program is scripts/local-ai/agent-explicit.sh, which
# runs only when the person sets AGENT=claude themselves.
#
# TWO KINDS OF PROOF, because each alone is blind:
#
# 1. STATIC. No file under scripts/local-ai*, and no Studio module whose name contains
#    local_ai, mentions claude, anthropic or an api key — except the one listed
#    exemption, each with a reason. A text scan cannot see a command assembled at run
#    time, so it is paired with:
# 2. DYNAMIC. The real scripts run end to end (status, prompt, todo, draft, the queue
#    worker, stop) twice: once on a PATH where no `claude` exists at all (the "no
#    dependency" proof), and once on a PATH where a decoy `claude` that records its
#    own execution comes FIRST (the "never calls it" proof: a script that merely
#    tolerates a missing claude would still run the decoy). The decoy is shown to work
#    first, and AGENT=claude is shown to reach the explicit branch, so a silent
#    decoy cannot make this pass for nothing.
#
# NEGATIVE CONTROLS: doctored copies of the tree (a claude call outside the branch, an
# Anthropic mention in a Studio module, an api key variable, a new file in the glob, a
# NUL byte that makes grep skip a whole file, a stale exemption, the exemption
# removed) must each be caught. A scan that has never been seen to fire is a wish.
#
# No network: the "model" is a loopback HTTP server written below, `gh` and `ollama`
# are stubs, and the repository the drafts work on is a throw-away fixture. Needs
# bash, python3 and git.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$(cd "${HERE}/../.." && pwd)"
. "${HERE}/../lib/guard-preflight.sh"
guard_require_tools bash python3 git sed grep tr find sort

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
has() { grep -Eq -- "$2" <<<"$1"; }       # a here-string, not a pipe: no SIGPIPE race under pipefail

WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() {
    if [ -n "${LA_STATE:-}" ] && [ -d "${LA_STATE}" ]; then
        env HUGMESH_LOCAL_AI_DIR="${LA_STATE}" bash "${GEN}/scripts/local-ai.sh" stop >/dev/null 2>&1
    fi
    [ -n "${SERVER_PID}" ] && kill "${SERVER_PID}" 2>/dev/null
    rm -rf "${WORK}"
}
trap cleanup EXIT

# ═════════════════════════════════════════════════════════════════════════════
# 1. STATIC SCAN
# ═════════════════════════════════════════════════════════════════════════════
PATTERN='claude|anthropic|api[_ .-]?key'
# path|reason, one per line. An entry is checked: the file must exist and must really
# contain a match (a stale entry is a finding) — it is a statement, not a permission slip.
EXEMPT_TEXT='
scripts/local-ai/agent-explicit.sh|the single explicit AGENT=claude branch: draft.py hands over to it only when the person sets AGENT themselves
'

scan_files() {   # ROOT -> the files the rule covers, one per line
    local root="$1"
    {
        ls "${root}/scripts/local-ai.sh" "${root}/scripts/local-ai-bench.sh" 2>/dev/null
        find "${root}/scripts/local-ai" -type f -not -path '*__pycache__*' 2>/dev/null
        find "${root}/studio/hugmesh_studio" -type f -name '*local_ai*' -name '*.py' \
            -not -path '*__pycache__*' 2>/dev/null
    } | sort -u
}

scan() {   # ROOT EXEMPT_TEXT -> one finding per line; nothing = clean
    local root="$1" exempt="$2" f rel reason line hit
    local listed=""
    while IFS='|' read -r rel reason; do
        [ -n "${rel}" ] || continue
        [ -n "${reason}" ] || echo "BAD EXEMPTION ${rel}: no reason given"
        listed="${listed}${rel}"$'\n'
        if [ ! -f "${root}/${rel}" ]; then
            echo "STALE EXEMPTION ${rel}: file does not exist"
        elif ! grep -aiEq -- "${PATTERN}" "${root}/${rel}"; then
            echo "STALE EXEMPTION ${rel}: file no longer mentions anything, drop the entry"
        fi
    done <<<"${exempt}"
    while IFS= read -r f; do
        [ -n "${f}" ] || continue
        rel="${f#"${root}"/}"
        # grep -a: one NUL byte makes plain grep skip the whole file and exit 1, which is
        # indistinguishable from "no match". Refuse such a file outright.
        if [ "$(LC_ALL=C tr -d '\0' <"${f}" | wc -c)" != "$(wc -c <"${f}")" ]; then
            echo "NUL BYTE ${rel}: a text scan cannot be trusted on this file"
            continue
        fi
        if grep -qxF -- "${rel}" <<<"${listed}"; then continue; fi
        hit="$(grep -aniE -- "${PATTERN}" "${f}" || true)"
        while IFS= read -r line; do
            [ -n "${line}" ] && echo "${rel}:${line}"
        done <<<"${hit}"
    done < <(scan_files "${root}")
}

mirror() {   # ROOT DEST -> copy the covered files, same relative paths
    local root="$1" dest="$2" f rel
    while IFS= read -r f; do
        [ -n "${f}" ] || continue
        rel="${f#"${root}"/}"
        mkdir -p "${dest}/$(dirname "${rel}")"
        cp "${f}" "${dest}/${rel}"
    done < <(scan_files "${root}")
}

echo "-- 1) static: nothing but the explicit branch names the Claude program --"
nfiles="$(scan_files "${GEN}" | wc -l)"
[ "${nfiles}" -ge 9 ] && ok "scan covers ${nfiles} files (not a vacuous scan)" \
    || bad "scan covers only ${nfiles} files: the glob matched almost nothing"
for must in scripts/local-ai.sh scripts/local-ai/draft.sh scripts/local-ai/draft.py \
            scripts/local-ai/worker.sh scripts/local-ai/agent-explicit.sh \
            studio/hugmesh_studio/core/local_ai_status.py; do
    grep -qxF -- "${GEN}/${must}" <<<"$(scan_files "${GEN}")" && ok "scan covers ${must}" \
        || bad "scan does not cover ${must}"
done
out="$(scan "${GEN}" "${EXEMPT_TEXT}")"
[ -z "${out}" ] && ok "no mention outside the listed exemption" \
    || { bad "mentions outside the explicit branch:"; echo "${out}" | sed 's/^/         /'; }

echo "-- 1b) negative controls: each doctored tree must be caught --"
M="${WORK}/mut"
mutate() {   # NAME FILE-REL APPENDED-TEXT WANTED-REGEX [EXEMPT]
    local name="$1" rel="$2" text="$3" want="$4" exempt="${5-${EXEMPT_TEXT}}"
    rm -rf "${M}"; mkdir -p "${M}"; mirror "${GEN}" "${M}"
    mkdir -p "${M}/$(dirname "${rel}")"
    printf '%s\n' "${text}" >>"${M}/${rel}"
    local r; r="$(scan "${M}" "${exempt}")"
    if has "${r}" "${want}"; then ok "caught: ${name}"; else bad "NOT caught: ${name}"; fi
}
mutate "a claude call in scripts/local-ai.sh" scripts/local-ai.sh \
    'claude -p "summarise" >/dev/null' 'scripts/local-ai.sh:[0-9]+:'
mutate "an Anthropic mention in a Studio module" studio/hugmesh_studio/core/local_ai_status.py \
    '# talks to the Anthropic service' 'local_ai_status.py:[0-9]+:'
mutate "an API key variable in a script" scripts/local-ai/worker.sh \
    'export API_KEY=abc' 'worker.sh:[0-9]+:'
mutate "a brand-new file in the covered glob" scripts/local-ai/extra.sh \
    'exec claude "$@"' 'extra.sh:[0-9]+:'
mutate "the exemption removed while the file still mentions claude" scripts/local-ai/agent-explicit.sh \
    '# claude' 'agent-explicit.sh:[0-9]+:' ''
mutate "a stale exemption (listed, but the file mentions nothing)" scripts/local-ai/issues.py \
    '# harmless' 'STALE EXEMPTION scripts/local-ai/issues.py' \
    "${EXEMPT_TEXT}"$'scripts/local-ai/issues.py|an exemption for a file that never mentions it\n'
# bash cannot hold a NUL in a variable, so this control writes it straight to the file
rm -rf "${M}"; mkdir -p "${M}"; mirror "${GEN}" "${M}"
printf 'x\000 claude -p y\n' >>"${M}/scripts/local-ai/draft.sh"
has "$(scan "${M}" "${EXEMPT_TEXT}")" 'NUL BYTE scripts/local-ai/draft.sh' \
    && ok "caught: a NUL byte hiding a mention from grep" || bad "NOT caught: a NUL byte hiding a mention from grep"
mutate "an exemption without a reason" scripts/local-ai/agent-explicit.sh \
    '# claude' 'BAD EXEMPTION' $'scripts/local-ai/agent-explicit.sh|\n'

echo "-- 1c) the Studio and the script agree where the state directory is --"
for envset in "HUGMESH_LOCAL_AI_DIR=${WORK}/explicit" "XDG_STATE_HOME=${WORK}/xdg" "NONE=1"; do
    sh_dir="$(env -u HUGMESH_LOCAL_AI_DIR -u XDG_STATE_HOME HOME="${WORK}/h" ${envset} bash -c ". '${GEN}/scripts/local-ai/_local-ai-lib.sh'; echo \"\${LA_DIR}\"")"
    py_dir="$(env -u HUGMESH_LOCAL_AI_DIR -u XDG_STATE_HOME HOME="${WORK}/h" ${envset} PYTHONPATH="${GEN}/studio" python3 -m hugmesh_studio.core.local_ai_status dir)"
    [ "${sh_dir}" = "${py_dir}" ] && ok "state dir agrees (${envset%%=*}): ${sh_dir#"${WORK}"/}" \
        || bad "state dir differs (${envset%%=*}): script=${sh_dir} studio=${py_dir}"
done

# ═════════════════════════════════════════════════════════════════════════════
# 2. DYNAMIC: the real scripts, a fake model, a fixture repository
# ═════════════════════════════════════════════════════════════════════════════
LOG="${WORK}/log"; STUBS="${WORK}/stubs"; CANARY="${WORK}/canary"; TOOLS="${WORK}/tools"
REPOS="${WORK}/repos"; HOMEDIR="${WORK}/home"
mkdir -p "${LOG}" "${STUBS}" "${CANARY}" "${TOOLS}" "${REPOS}" "${HOMEDIR}"

# The fake model: loopback only, answers by the mode in ${LOG}/mode.
cat >"${WORK}/fake-ollama.py" <<'PY'
import http.server, json, os, sys
LOG = sys.argv[1]
GOOD = ("Here is the fix:\n```diff\n--- a/hello.txt\n+++ b/hello.txt\n@@ -1,3 +1,3 @@\n"
        " alpha\n-beta\n+BETA\n gamma\n```\n")
BAD = "--- a/hello.txt\n+++ b/hello.txt\n@@ -1,2 +1,2 @@\n nothing like the file\n-missing line\n+other\n"
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, body, ctype="application/json"):
        self.send_response(200); self.send_header("Content-Type", ctype); self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        with open(os.path.join(LOG, "gets.log"), "a") as fh: fh.write(self.path + "\n")
        if self.path == "/api/tags": self._send(json.dumps({"models": [{"name": "qwen3:8b"}]}).encode())
        elif self.path == "/api/ps": self._send(json.dumps({"models": [{"name": "qwen3:8b"}]}).encode())
        else: self.send_error(404)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        req = json.loads(self.rfile.read(n) or b"{}")
        with open(os.path.join(LOG, "requests.jsonl"), "a") as fh: fh.write(json.dumps(req) + "\n")
        msgs = req.get("messages", [])
        system = next((m["content"] for m in msgs if m["role"] == "system"), "")
        if "unified diff" in system:
            try: mode = open(os.path.join(LOG, "mode")).read().strip()
            except OSError: mode = "good"
            text = {"good": GOOD, "bad": BAD, "nochange": "NO CHANGE: needs a live mesh"}.get(mode, "")
        else:
            text = "pong from the fake model"
        out = b"".join(json.dumps({"message": {"role": "assistant", "content": t}, "done": False}).encode() + b"\n"
                       for t in (text[:20], text[20:]))
        out += json.dumps({"done": True}).encode() + b"\n"
        self._send(out, "application/x-ndjson")
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(os.path.join(LOG, "port"), "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 "${WORK}/fake-ollama.py" "${LOG}" >/dev/null 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do [ -s "${LOG}/port" ] && break; sleep 0.1; done
PORT="$(cat "${LOG}/port" 2>/dev/null || true)"
[ -n "${PORT}" ] || { bad "the fake model server did not start"; echo "== ${pass} passed, ${fail} failed =="; exit 1; }

# A PATH of symlinks to the few tools the scripts use, so "claude is not installed" is a
# fact of the test and not an accident of this machine.
PY_REAL="$(python3 -c 'import sys; print(sys.executable)')"
for t in bash sh env sed tr cat head tail date sleep seq ls sort wc mkdir rm mv cp dirname basename \
         timeout kill setsid nohup grep awk chmod touch id uname mktemp find xargs tee cut readlink \
         ps hostname stat ln git true false test clear; do
    p="$(command -v "${t}" 2>/dev/null || true)"
    [ -n "${p}" ] && [ -x "${p}" ] && ln -sf "${p}" "${TOOLS}/${t}"
done
ln -sf "${PY_REAL}" "${TOOLS}/python3"

# stubs: gh (canned issues), ollama (records its arguments; "launch opencode" acts like an
# agent that edits the worktree and records the environment it was given)
cat >"${STUBS}/gh" <<GH
#!/bin/sh
echo "\$*" >>"${LOG}/gh.calls"
case "\$1 \$2" in
  "issue view") printf '%s\n' '{"title":"Fix beta in hello.txt","body":"Please change \`beta\` to BETA in hello.txt","comments":[{"author":{"login":"op"},"body":"later comment"}]}' ;;
  "issue list") printf '[{"number":1,"title":"small one","body":"short","labels":[]},{"number":2,"title":"manual one","body":"x","labels":[{"name":"manual-test"}]},{"number":3,"title":"big one","body":"%s","labels":[]},{"number":4,"title":"second small","body":"a little longer text","labels":[]}]\n' "\$(head -c 3000 /dev/zero | tr '\\0' x)" ;;
  *) exit 1 ;;
esac
GH
cat >"${STUBS}/ollama" <<OL
#!/bin/sh
echo "\$*" >>"${LOG}/ollama.argv"
if [ "\$1 \$2" = "launch opencode" ]; then
  env | sort >"${LOG}/agent-env.txt"
  pwd >"${LOG}/agent-cwd.txt"
  echo agent-line >>hello.txt
fi
exit 0
OL
printf '#!/bin/sh\nexit 0\n' >"${STUBS}/opencode"
printf '#!/bin/sh\ntouch "%s/claude-was-run"\nexit 0\n' "${LOG}" >"${CANARY}/claude"
chmod +x "${STUBS}"/* "${CANARY}/claude"

P_NO="${STUBS}:${TOOLS}"                 # no claude anywhere
P_DECOY="${CANARY}:${STUBS}:${TOOLS}"    # a decoy claude, first on PATH

echo "-- 2) the test's own instruments work --"
if PATH="${P_NO}" command -v claude >/dev/null 2>&1; then bad "PATH 'no claude' still finds a claude"; else ok "the bare PATH has no claude command"; fi
PATH="${P_DECOY}" claude; [ -e "${LOG}/claude-was-run" ] && ok "the decoy claude records being run" \
    || bad "the decoy claude did not record a run: the never-calls proof would be vacuous"
rm -f "${LOG}/claude-was-run"

# the fixture repository: origin/main exists, hello.txt has three lines
FIX_SRC="${WORK}/fixture-src"
git init -q -b main "${FIX_SRC}" 2>/dev/null || { git init -q "${FIX_SRC}"; git -C "${FIX_SRC}" checkout -q -b main; }
printf 'alpha\nbeta\ngamma\n' >"${FIX_SRC}/hello.txt"
git -C "${FIX_SRC}" add hello.txt
git -C "${FIX_SRC}" -c user.name=t -c user.email=t@example.invalid commit -q -m fixture
git clone -q --bare "${FIX_SRC}" "${WORK}/fixture-origin.git"
git clone -q "${WORK}/fixture-origin.git" "${REPOS}/hugmesh-fixture"
git -C "${REPOS}/hugmesh-fixture" remote set-head origin main >/dev/null 2>&1

LA_STATE="${WORK}/state"
la() {   # run a command in a clean environment pointed at the fakes; PATHV picks the PATH
    env -i PATH="${PATHV}" HOME="${HOMEDIR}" LANG=C.UTF-8 TERM=dumb \
        HUGMESH_LOCAL_AI_DIR="${LA_STATE}" HUGMESH_STUDIO_STATE_DIR="${WORK}/studio-state" \
        HUGMESH_REPOS_ROOT="${REPOS}" OLLAMA_HOST="127.0.0.1:${PORT}" "$@"
}
status_word() { head -c 200 "${LA_STATE}/drafts/$1/STATUS" 2>/dev/null | cut -d' ' -f1; }

battery() {   # LABEL — the same commands on whichever PATHV is set
    local label="$1" out rc
    rm -rf "${LA_STATE}"; rm -f "${LOG}/mode" "${LOG}/ollama.argv" "${LOG}/claude-was-run"
    out="$(la bash "${GEN}/scripts/local-ai.sh" status 2>&1)"; rc=$?
    [ "${rc}" -eq 0 ] && has "${out}" 'Local AI: ready, qwen3:8b loaded, idle' \
        && ok "[${label}] status: ready, model loaded, idle" || bad "[${label}] status rc=${rc}: ${out}"
    out="$(la bash "${GEN}/scripts/local-ai.sh" status --json 2>&1)"
    if python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d["ok"] and d["worker"]=="stopped" and d["schema"]==1 else 1)' "${out}" 2>/dev/null; then
        ok "[${label}] status --json is valid and says ok, worker stopped"
    else bad "[${label}] status --json: ${out}"; fi
    out="$(la bash "${GEN}/scripts/local-ai.sh" prompt "say pong" 2>&1)"
    has "${out}" 'pong from the fake model' && ok "[${label}] prompt answers from the loopback model" \
        || bad "[${label}] prompt: ${out}"
    out="$(la bash "${GEN}/scripts/local-ai.sh" todo 5 hugmesh-fixture --dry-run 2>&1)"
    if has "${out}" 'would queue hugmesh-fixture#1' && has "${out}" 'would queue hugmesh-fixture#4' \
       && ! has "${out}" '#2' && ! has "${out}" '#3'; then
        ok "[${label}] todo --dry-run picks the small open issues, skips manual and oversized"
    else bad "[${label}] todo --dry-run: ${out}"; fi

    printf good >"${LOG}/mode"
    la bash "${GEN}/scripts/local-ai.sh" draft hugmesh-fixture 1 >"${LOG}/draft.out" 2>&1; rc=$?
    w="$(status_word hugmesh-fixture-1)"
    [ "${rc}" -eq 0 ] && [ "${w}" = "applied" ] && ok "[${label}] draft with a good diff: STATUS applied" \
        || bad "[${label}] draft good: rc=${rc} STATUS=${w}: $(tail -5 "${LOG}/draft.out")"
    grep -q '^+BETA$' "${LA_STATE}/drafts/hugmesh-fixture-1/draft.diff" 2>/dev/null \
        && ok "[${label}] draft.diff holds the change" || bad "[${label}] draft.diff lacks the change"
    [ ! -e "${LA_STATE}/scratch/hugmesh-fixture-1" ] \
        && ok "[${label}] the scratch worktree is removed afterwards" || bad "[${label}] scratch worktree left behind"
    wt="$(git -C "${REPOS}/hugmesh-fixture" worktree list)"
    has "${wt}" 'scratch' && bad "[${label}] a scratch worktree is still registered in the source checkout" \
        || ok "[${label}] no scratch worktree stays registered in the source checkout"
    [ "$(git -C "${REPOS}/hugmesh-fixture" status --porcelain | wc -l)" -eq 0 ] \
        && ok "[${label}] the source checkout's own files were not touched" || bad "[${label}] source checkout was modified"

    printf bad >"${LOG}/mode"
    la bash "${GEN}/scripts/local-ai.sh" draft hugmesh-fixture 2 >/dev/null 2>&1
    [ "$(status_word hugmesh-fixture-2)" = "does-not-apply" ] \
        && ok "[${label}] a diff that does not match the file: STATUS does-not-apply" \
        || bad "[${label}] bad diff: STATUS=$(status_word hugmesh-fixture-2)"
    printf nochange >"${LOG}/mode"
    la bash "${GEN}/scripts/local-ai.sh" draft hugmesh-fixture 3 >/dev/null 2>&1
    [ "$(status_word hugmesh-fixture-3)" = "no-diff" ] \
        && ok "[${label}] the model declines (NO CHANGE): STATUS no-diff" \
        || bad "[${label}] nochange: STATUS=$(status_word hugmesh-fixture-3)"

    [ ! -e "${LOG}/claude-was-run" ] && ok "[${label}] the claude command was never run" \
        || bad "[${label}] a script RAN the claude command without AGENT=claude"
    if grep -q 'launch' "${LOG}/ollama.argv" 2>/dev/null; then
        bad "[${label}] a script asked ollama to launch an agent in the default mode: $(cat "${LOG}/ollama.argv")"
    else ok "[${label}] no agent was launched in the default mode"; fi
}

echo "-- 2a) the commands, on a PATH with no claude at all --"
PATHV="${P_NO}"; battery "no claude"
echo "-- 2b) the same commands, with a decoy claude first on PATH --"
PATHV="${P_DECOY}"; battery "decoy claude"

echo "-- 3) the queue worker, end to end --"
PATHV="${P_NO}"
rm -rf "${LA_STATE}"; printf good >"${LOG}/mode"
out="$(la bash "${GEN}/scripts/local-ai.sh" todo 2 hugmesh-fixture 2>&1)"
has "${out}" 'queued hugmesh-fixture#1' && has "${out}" 'worker (started|already)' \
    && ok "todo queues two jobs and starts the worker" || bad "todo: ${out}"
for _ in $(seq 1 90); do
    [ "$(status_word hugmesh-fixture-1)" = "applied" ] && [ "$(status_word hugmesh-fixture-4)" = "applied" ] && break
    sleep 1
done
[ "$(status_word hugmesh-fixture-1)" = "applied" ] && [ "$(status_word hugmesh-fixture-4)" = "applied" ] \
    && ok "the worker drafted both queued issues (STATUS applied)" \
    || bad "worker did not finish both drafts: 1=$(status_word hugmesh-fixture-1) 4=$(status_word hugmesh-fixture-4); log: $(tail -3 "${LA_STATE}/worker.log" 2>/dev/null)"
sj="$(la bash "${GEN}/scripts/local-ai.sh" status --json 2>&1)"
if python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d["worker"]=="running" and d["counts"]["done"]==2 and d["counts"]["pending"]==0 and d["heartbeat_age"] is not None and d["heartbeat_age"]<30 else 1)' "${sj}" 2>/dev/null; then
    ok "status --json: worker running with a fresh heartbeat, 2 done, 0 pending"
else bad "status --json while the worker runs: ${sj}"; fi
[ -s "${LA_STATE}/worker.pid" ] && ok "the worker keeps a pidfile" || bad "no worker.pid"
printf 'draft hugmesh-fixture 9; touch %s/injected\n' "${LOG}" >"${LA_STATE}/queue/pending/20990101-000000-evil.job"
for _ in $(seq 1 30); do [ -e "${LA_STATE}/queue/done/20990101-000000-evil.result" ] && break; sleep 1; done
[ ! -e "${LOG}/injected" ] && [ -e "${LA_STATE}/queue/done/20990101-000000-evil.result" ] \
    && has "$(cat "${LA_STATE}/queue/done/20990101-000000-evil.result")" '^rc=64' \
    && ok "a job line that is not 'draft REPO ISSUE' is refused, not executed" \
    || bad "the worker accepted a job line carrying a command"
out="$(la bash "${GEN}/scripts/local-ai.sh" stop 2>&1)"
has "${out}" 'worker stopped' && ok "stop ends the worker" || bad "stop: ${out}"
sj="$(la bash "${GEN}/scripts/local-ai.sh" status --json 2>&1)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d["worker"]=="stopped" else 1)' "${sj}" 2>/dev/null \
    && ok "after stop, status reports the worker stopped" || bad "after stop: ${sj}"
[ ! -e "${LOG}/claude-was-run" ] && ok "the worker run never touched claude" || bad "the worker ran claude"

echo "-- 4) a coding agent (AGENT=opencode) gets only the allowlisted environment --"
rm -rf "${LA_STATE}"; rm -f "${LOG}/ollama.argv"
la env AGENT=opencode GH_TOKEN=secret-a GITHUB_TOKEN=secret-b REGISTRY_TOKEN=secret-c SOME_OTHER=keep-out \
    bash "${GEN}/scripts/local-ai.sh" draft hugmesh-fixture 1 >"${LOG}/oc.out" 2>&1
[ "$(status_word hugmesh-fixture-1)" = "applied" ] && has "$(cat "${LOG}/ollama.argv" 2>/dev/null)" 'launch opencode --model qwen3:8b' \
    && ok "opencode mode launches the agent through ollama and records the diff" \
    || bad "opencode mode: STATUS=$(status_word hugmesh-fixture-1) argv=$(cat "${LOG}/ollama.argv" 2>/dev/null) out=$(tail -3 "${LOG}/oc.out")"
env_seen="$(cat "${LOG}/agent-env.txt" 2>/dev/null)"
if has "${env_seen}" 'secret-|SOME_OTHER|TOKEN'; then bad "the agent saw a variable outside the allowlist: $(grep -E 'secret-|SOME_OTHER|TOKEN' <<<"${env_seen}")"
else ok "no token or unlisted variable reaches the agent"; fi
extra="$(grep -Ev '^(PATH|HOME|LANG|TERM|OLLAMA_HOST|PWD|SHLVL|_|OLDPWD|GIT_[A-Z_0-9]+|GH_CONFIG_DIR)=' <<<"${env_seen}")"
[ -z "${extra}" ] && ok "the agent's environment is exactly the allowlist plus the push guards" \
    || bad "unexpected variables in the agent environment: ${extra}"
has "${env_seen}" "^OLLAMA_HOST=127\.0\.0\.1:${PORT}$" && ok "the agent is pointed at the loopback server" || bad "OLLAMA_HOST missing from the agent"
cwd="$(cat "${LOG}/agent-cwd.txt" 2>/dev/null)"
[ "${cwd}" = "${LA_STATE}/scratch/hugmesh-fixture-1" ] && ok "the agent ran inside the scratch worktree" \
    || bad "the agent's directory was ${cwd}"
mkdir -p "${WORK}/stubs-no-agent"
ln -sf "${STUBS}/gh" "${STUBS}/ollama" "${WORK}/stubs-no-agent/"
PATHV="${P_NO}" la env AGENT=opencode PATH="${WORK}/stubs-no-agent:${TOOLS}" bash "${GEN}/scripts/local-ai.sh" draft hugmesh-fixture 5 >/dev/null 2>&1
has "$(cat "${LA_STATE}/drafts/hugmesh-fixture-5/STATUS" 2>/dev/null)" '^error AGENT=opencode needs the opencode command' \
    && ok "AGENT=opencode without the command installed fails with a plain sentence" \
    || bad "opencode missing: $(cat "${LA_STATE}/drafts/hugmesh-fixture-5/STATUS" 2>/dev/null)"

echo "-- 5) AGENT=claude is the one door, and it works only when asked --"
rm -rf "${LA_STATE}"; rm -f "${LOG}/ollama.argv"
PATHV="${P_DECOY}" la env AGENT=claude bash "${GEN}/scripts/local-ai.sh" draft hugmesh-fixture 1 >/dev/null 2>&1
has "$(cat "${LOG}/ollama.argv" 2>/dev/null)" 'launch claude --model qwen3:8b' \
    && ok "AGENT=claude reaches the explicit branch (so the default-mode result above is not vacuous)" \
    || bad "AGENT=claude did not reach agent-explicit.sh: $(cat "${LOG}/ollama.argv" 2>/dev/null)"
rm -rf "${LA_STATE}"
PATHV="${P_NO}" la env AGENT=claude bash "${GEN}/scripts/local-ai.sh" draft hugmesh-fixture 1 >/dev/null 2>&1
has "$(cat "${LA_STATE}/drafts/hugmesh-fixture-1/STATUS" 2>/dev/null)" '^(error|no-diff)' \
    && ok "AGENT=claude with no claude installed does not pretend to have worked" \
    || bad "AGENT=claude without claude: $(cat "${LA_STATE}/drafts/hugmesh-fixture-1/STATUS" 2>/dev/null)"
rm -rf "${LA_STATE}"; rm -f "${LOG}/ollama.argv"
PATHV="${P_NO}" la env AGENT=bogus bash "${GEN}/scripts/local-ai.sh" draft hugmesh-fixture 1 >/dev/null 2>&1
! grep -q 'launch' "${LOG}/ollama.argv" 2>/dev/null \
    && ok "an unknown AGENT value is refused by the explicit script" || bad "unknown AGENT value was passed on"

echo "-- 6) loopback only: nothing leaves the machine --"
PATHV="${P_NO}"
t0=$SECONDS
out="$(la env OLLAMA_HOST=10.255.255.1:11434 bash "${GEN}/scripts/local-ai.sh" status 2>&1)"; rc=$?
[ "${rc}" -ne 0 ] && has "${out}" 'not a loopback address' && [ $((SECONDS - t0)) -lt 5 ] \
    && ok "status refuses a non-loopback OLLAMA_HOST at once (no connection attempted)" || bad "status with 10.255.255.1: rc=${rc} ${out}"
for h in 0.0.0.0:11434 192.168.1.5 http://example.com:11434 https://127.0.0.1:11434 localhost.evil.test; do
    out="$(la env OLLAMA_HOST="${h}" bash "${GEN}/scripts/local-ai.sh" up 2>&1)"; rc=$?
    [ "${rc}" -ne 0 ] && has "${out}" 'loopback|plain http' && ok "up refuses OLLAMA_HOST=${h}" || bad "up with ${h}: rc=${rc} ${out}"
done
out="$(la env OLLAMA_HOST="localhost:${PORT}" bash "${GEN}/scripts/local-ai.sh" prompt "say pong" 2>&1)"
has "${out}" 'pong' && ok "localhost is mapped to 127.0.0.1 and accepted" || bad "localhost: ${out}"
: >"${LOG}/gets.log"
out="$(la env HTTP_PROXY=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9 \
        bash "${GEN}/scripts/local-ai.sh" prompt "say pong" 2>&1)"
has "${out}" 'pong' && ok "a dead system proxy is ignored: the request goes straight to loopback" \
    || bad "proxy variables changed the route: ${out}"
rm -rf "${LA_STATE}"
la env OLLAMA_HOST=10.255.255.1:11434 bash "${GEN}/scripts/local-ai.sh" draft hugmesh-fixture 1 >/dev/null 2>&1
has "$(cat "${LA_STATE}/drafts/hugmesh-fixture-1/STATUS" 2>/dev/null)" '^no-ollama' \
    && ok "draft with a non-loopback OLLAMA_HOST stops with no-ollama" \
    || bad "draft with a remote host: $(cat "${LA_STATE}/drafts/hugmesh-fixture-1/STATUS" 2>/dev/null)"

echo "-- 7) a dead worker is never read as running; stop never signals a reused pid --"
rm -rf "${LA_STATE}"; mkdir -p "${LA_STATE}/queue/running" "${LA_STATE}/queue/pending"
dead="$(bash -c 'echo $$')"
now="$(date +%s)"
printf '{"pid": %s, "heartbeat": %s}' "${dead}" "${now}" >"${LA_STATE}/status.json"
printf 'draft hugmesh-fixture 7\n' >"${LA_STATE}/queue/running/20260101-000000-draft-hugmesh-fixture-7.job"
sj="$(la bash "${GEN}/scripts/local-ai.sh" status --json 2>&1)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); c=d["counts"]; sys.exit(0 if d["worker"]=="stopped" and c["running"]==0 and c["stalled"]==1 else 1)' "${sj}" 2>/dev/null \
    && ok "a fresh heartbeat from a dead pid, with a stranded job: worker stopped, job stalled, nothing running" \
    || bad "dead worker read as alive: ${sj}"
sleep 300 & unrelated=$!
echo "${unrelated}" >"${LA_STATE}/worker.pid"
out="$(la bash "${GEN}/scripts/local-ai.sh" stop 2>&1)"
if kill -0 "${unrelated}" 2>/dev/null && has "${out}" 'no worker is running'; then
    ok "stop leaves an unrelated process alone when its pid is in worker.pid"
else bad "stop signalled or mis-reported an unrelated pid: ${out}"; fi
kill "${unrelated}" 2>/dev/null

echo
echo "== ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]

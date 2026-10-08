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
[ "${nfiles}" -ge 11 ] && ok "scan covers ${nfiles} files (not a vacuous scan)" \
    || bad "scan covers only ${nfiles} files: the glob matched almost nothing"
for must in scripts/local-ai.sh scripts/local-ai/draft.sh scripts/local-ai/draft.py \
            scripts/local-ai/worker.sh scripts/local-ai/agent-explicit.sh \
            studio/hugmesh_studio/core/local_ai_status.py studio/hugmesh_studio/gui/_local_ai_dock.py \
            studio/hugmesh_studio/tui/local_ai.py; do
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
ESCAPE = "--- a/../x.txt\n+++ b/../x.txt\n@@ -1,1 +1,1 @@\n-a\n+b\n"
GITDIR = "--- a/.git/config\n+++ b/.git/config\n@@ -1,1 +1,1 @@\n-a\n+b\n"
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
            if mode == "slow":              # a model that never answers in time
                import time; time.sleep(60)
            text = {"good": GOOD, "bad": BAD, "nochange": "NO CHANGE: needs a live mesh",
                    "escape": ESCAPE, "gitdir": GITDIR}.get(mode, "NO CHANGE: slow")
        else:
            text = "pong from the fake model"
        out = b"".join(json.dumps({"message": {"role": "assistant", "content": t}, "done": False}).encode() + b"\n"
                       for t in (text[:20], text[20:]))
        out += json.dumps({"done": True}).encode() + b"\n"
        self._send(out, "application/x-ndjson")
srv = http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2]) if len(sys.argv) > 2 else 0), H)
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
# a gh that hangs, to stop a draft in the middle of reading its issue
if [ -e "${LOG}/gh-slow" ]; then echo \$\$ >"${LOG}/gh.pid"; exec sleep 60; fi
case "\$1 \$2" in
  "issue view") printf '%s\n' '{"title":"Fix beta in hello.txt","body":"Please change \`beta\` to BETA in hello.txt","comments":[{"author":{"login":"op"},"body":"later comment"}]}' ;;
  "issue list") printf '[{"number":1,"title":"small one","body":"short","labels":[]},{"number":2,"title":"manual one","body":"x","labels":[{"name":"manual-test"}]},{"number":3,"title":"big one","body":"%s","labels":[]},{"number":4,"title":"second small","body":"a little longer text","labels":[]}]\n' "\$(head -c 3000 /dev/zero | tr '\\0' x)" ;;
  *) exit 1 ;;
esac
GH
cat >"${STUBS}/ollama" <<OL
#!/bin/sh
echo "\$*" >>"${LOG}/ollama.argv"
if [ "\$1" = "serve" ]; then
  # a server that really answers on the port it was told to bind, after recording the
  # environment it was started with (OLLAMA_HOST must be loopback)
  env | sort >"${LOG}/serve-env.txt"
  mkdir -p "${WORK}/serve-log"
  case "\${OLLAMA_HOST##*:}" in ""|*[!0-9]*) exec sleep 300 ;; esac
  exec python3 "${WORK}/fake-ollama.py" "${WORK}/serve-log" "\${OLLAMA_HOST##*:}"
fi
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
alive() {   # PID is running and is not a zombie that nobody has reaped
    local p="$1" st
    { [ -n "${p}" ] && kill -0 "${p}" 2>/dev/null; } || return 1
    st="$(sed 's/.*) //' "/proc/${p}/stat" 2>/dev/null | cut -c1)"
    [ "${st}" != "Z" ]
}
hasf() { grep -Fq -- "$2" <<<"$1"; }   # fixed string, here-string (no pipe, no SIGPIPE race)
strays() {   # every live process that belongs to this test's state directory, one pid per line
    local d p
    for d in /proc/[0-9]*; do
        p="${d#/proc/}"; [ "${p}" = "$$" ] && continue
        alive "${p}" || continue
        if hasf "$(tr '\0' ' ' <"${d}/cmdline" 2>/dev/null)" "${LA_STATE}"; then echo "${p}"; continue; fi
        hasf "$(tr '\0' '\n' <"${d}/environ" 2>/dev/null)" "HUGMESH_LOCAL_AI_DIR=${LA_STATE}" && echo "${p}"
    done
}
wait_gone() {   # up to N seconds for strays to vanish; prints what is left
    local n="$1" left
    for _ in $(seq 1 $((n * 5))); do left="$(strays)"; [ -z "${left}" ] && return 0; sleep 0.2; done
    printf '%s\n' "${left}"; return 1
}

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
    git -C "${REPOS}/hugmesh-fixture" worktree prune
    git -C "${REPOS}/hugmesh-fixture" worktree add -q --detach "${WORK}/other-wt" origin/main 2>/dev/null
    rm -rf "${WORK}/other-wt"                                  # registered, folder gone
    git -C "${REPOS}/hugmesh-fixture" worktree add -q --detach "${LA_STATE}/scratch/hugmesh-fixture-1" origin/main 2>/dev/null
    rm -rf "${LA_STATE}/scratch/hugmesh-fixture-1"             # a crashed run's leftover: registered, folder gone
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

    # the checkout belongs to the person: a worktree of theirs whose folder is missing right now
    # (an unmounted path, say) must keep its registration, and a scratch entry that a crashed run
    # left registered-but-missing must not stop the next draft
    if [ -d "${REPOS}/hugmesh-fixture/.git/worktrees/other-wt" ]; then
        ok "[${label}] another worktree of the checkout, whose folder is missing, is still registered afterwards"
    else bad "[${label}] a draft pruned another worktree's registration from the person's checkout"; fi

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

    # a finished draft is not queued again; an issue nobody drafted still is
    out="$(la bash "${GEN}/scripts/local-ai.sh" todo 5 hugmesh-fixture --dry-run 2>&1)"
    if has "${out}" 'skip hugmesh-fixture#1 \(already drafted' && ! has "${out}" 'would queue hugmesh-fixture#1' \
       && has "${out}" 'would queue hugmesh-fixture#4'; then
        ok "[${label}] todo skips an issue that already has a draft and still offers one that has not"
    else bad "[${label}] todo skip: ${out}"; fi
    # the issue's comments are shown to the model: the docs say a later comment corrects the body
    has "$(cat "${LA_STATE}/drafts/hugmesh-fixture-1/issue.md" 2>/dev/null)" 'later comment' \
        && ok "[${label}] the issue text handed to the model includes its comments" \
        || bad "[${label}] issue.md lacks the issue's comment: $(cat "${LA_STATE}/drafts/hugmesh-fixture-1/issue.md" 2>/dev/null)"
    # names that could leave the state directory are refused before anything is made
    out="$(la bash "${GEN}/scripts/local-ai.sh" draft ../x 1 2>&1)"; rc=$?
    [ "${rc}" -eq 2 ] && [ ! -e "${LA_STATE}/x-1" ] && [ ! -e "${LA_STATE}/drafts/..-x-1" ] \
        && ok "[${label}] draft ../x 1 is refused (exit 2) and makes nothing" || bad "[${label}] draft ../x 1: rc=${rc} ${out}"
    out="$(la bash "${GEN}/scripts/local-ai.sh" draft .. 1 2>&1)"; rc=$?
    [ "${rc}" -eq 2 ] && [ ! -e "${LA_STATE}/drafts/..-1" ] \
        && ok "[${label}] a repository named '..' is refused (it would be the parent folder)" || bad "[${label}] draft .. 1: rc=${rc} ${out}"
    out="$(la bash "${GEN}/scripts/local-ai.sh" draft a..b 1 2>&1)"; rc=$?
    [ "${rc}" -eq 2 ] && ok "[${label}] a repository name with '..' inside it is refused" || bad "[${label}] draft a..b 1: rc=${rc} ${out}"
    out="$(la bash "${GEN}/scripts/local-ai.sh" draft -rf 1 2>&1)"; rc=$?
    [ "${rc}" -eq 2 ] && ok "[${label}] a repository name that starts with a dash is refused" || bad "[${label}] draft -rf: rc=${rc} ${out}"
    out="$(la bash "${GEN}/scripts/local-ai.sh" draft hugmesh-fixture 1x 2>&1)"; rc=$?
    [ "${rc}" -eq 2 ] && ok "[${label}] an issue number with a letter in it is refused" || bad "[${label}] draft 1x: rc=${rc} ${out}"
    out="$(la bash "${GEN}/scripts/local-ai.sh" todo "" --dry-run 2>&1)"; rc=$?
    [ "${rc}" -eq 2 ] && ! has "${out}" 'Traceback' \
        && ok "[${label}] todo with an empty argument says what is wrong (exit 2, no traceback)" || bad "[${label}] todo '': rc=${rc} ${out}"
    out="$(la bash "${GEN}/scripts/local-ai.sh" todo ../x --dry-run 2>&1)"; rc=$?
    [ "${rc}" -eq 2 ] && ! has "$(cat "${LOG}/gh.calls" 2>/dev/null)" '\.\./x' \
        && ok "[${label}] todo ../x is refused (exit 2) before gh is asked anything" || bad "[${label}] todo ../x: rc=${rc} ${out}"

    out="$(la bash "${GEN}/scripts/local-ai.sh" queue 2>&1)"
    has "${out}" '^pending: 0  running: 0  done: 0' && ok "[${label}] queue lists an empty queue" || bad "[${label}] queue: ${out}"
    out="$(printf 'hello\n/quit\n' | la bash "${GEN}/scripts/local-ai.sh" chat 2>&1)"
    has "${out}" 'pong from the fake model' && ok "[${label}] chat answers a typed line and leaves on /quit" || bad "[${label}] chat: ${out}"
    out="$(la timeout 3 bash "${GEN}/scripts/local-ai.sh" watch 2>&1 </dev/null)"
    has "${out}" 'Local AI: ready, qwen3:8b loaded, idle' && ok "[${label}] watch draws the dashboard (no watch(1) needed)" \
        || bad "[${label}] watch: ${out}"
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

# The worker, the server start and a stop are run on BOTH paths: with no claude anywhere, and
# with a decoy claude first on PATH. The decoy canary is removed right before each run and must
# be absent right after it, so a claude call that only the worker (or `start`, `stop`, `up`)
# makes, through a name built at run time that the static scan cannot see, is caught here.
worker_section() {   # LABEL
    local label="$1" out sj left
    rm -rf "${LA_STATE}"; printf good >"${LOG}/mode"; rm -f "${LOG}/claude-was-run"
    out="$(la bash "${GEN}/scripts/local-ai.sh" todo 2 hugmesh-fixture 2>&1)"
    has "${out}" 'queued hugmesh-fixture#1' && has "${out}" 'worker (started|already)' \
        && ok "[${label}] todo queues two jobs and starts the worker" || bad "[${label}] todo: ${out}"
    for _ in $(seq 1 90); do
        [ "$(status_word hugmesh-fixture-1)" = "applied" ] && [ "$(status_word hugmesh-fixture-4)" = "applied" ] && break
        sleep 1
    done
    [ "$(status_word hugmesh-fixture-1)" = "applied" ] && [ "$(status_word hugmesh-fixture-4)" = "applied" ] \
        && ok "[${label}] the worker drafted both queued issues (STATUS applied)" \
        || bad "[${label}] worker did not finish both drafts: 1=$(status_word hugmesh-fixture-1) 4=$(status_word hugmesh-fixture-4); log: $(tail -3 "${LA_STATE}/worker.log" 2>/dev/null)"
    # STATUS is written before draft.sh exits and before the worker files the result, so on a
    # busy machine "both applied" can be seen while one job is still under running/. Wait
    # (bounded) for the worker to finish filing both before the counts are read.
    for _ in $(seq 1 60); do
        [ "$(ls "${LA_STATE}/queue/done" 2>/dev/null | grep -c '\.result$')" -ge 2 ] \
            && [ -z "$(ls "${LA_STATE}/queue/running" 2>/dev/null)" ] && break
        sleep 0.5
    done
    sj="$(la bash "${GEN}/scripts/local-ai.sh" status --json 2>&1)"
    if python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d["worker"]=="running" and d["counts"]["done"]==2 and d["counts"]["pending"]==0 and d["heartbeat_age"] is not None and d["heartbeat_age"]<30 else 1)' "${sj}" 2>/dev/null; then
        ok "[${label}] status --json: worker running with a fresh heartbeat, 2 done, 0 pending"
    else bad "[${label}] status --json while the worker runs: ${sj}"; fi
    [ -s "${LA_STATE}/worker.pid" ] && ok "[${label}] the worker keeps a pidfile" || bad "[${label}] no worker.pid"
    printf 'draft hugmesh-fixture 9; touch %s/injected\n' "${LOG}" >"${LA_STATE}/queue/pending/20990101-000000-evil.job"
    printf 'draft ../x 9\n' >"${LA_STATE}/queue/pending/20990101-000001-escape.job"
    for _ in $(seq 1 30); do
        [ -e "${LA_STATE}/queue/done/20990101-000000-evil.result" ] && [ -e "${LA_STATE}/queue/done/20990101-000001-escape.result" ] && break
        sleep 1
    done
    [ ! -e "${LOG}/injected" ] && [ -e "${LA_STATE}/queue/done/20990101-000000-evil.result" ] \
        && has "$(cat "${LA_STATE}/queue/done/20990101-000000-evil.result")" '^rc=64' \
        && ok "[${label}] a job line that is not 'draft REPO ISSUE' is refused, not executed" \
        || bad "[${label}] the worker accepted a job line carrying a command"
    [ -e "${LA_STATE}/queue/done/20990101-000001-escape.result" ] \
        && has "$(cat "${LA_STATE}/queue/done/20990101-000001-escape.result")" '^rc=64' && [ ! -e "${LA_STATE}/x-9" ] \
        && ok "[${label}] a job naming a repository outside the state directory (../x) is refused" \
        || bad "[${label}] the worker accepted ../x: $(cat "${LA_STATE}/queue/done/20990101-000001-escape.result" 2>/dev/null)"
    out="$(la bash "${GEN}/scripts/local-ai.sh" stop 2>&1)"
    has "${out}" 'worker stopped' && ok "[${label}] stop ends the worker" || bad "[${label}] stop: ${out}"
    sj="$(la bash "${GEN}/scripts/local-ai.sh" status --json 2>&1)"
    python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d["worker"]=="stopped" else 1)' "${sj}" 2>/dev/null \
        && ok "[${label}] after stop, status reports the worker stopped" || bad "[${label}] after stop: ${sj}"
    # read the file itself: a worker that died would read as stopped through its pid alone
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["pid"]==0 and d["running"]=="" else 1)' "${LA_STATE}/status.json" 2>/dev/null \
        && ok "[${label}] a worker that stops on purpose writes pid 0 and no running job" \
        || bad "[${label}] status.json after stop: $(cat "${LA_STATE}/status.json" 2>/dev/null)"
    # `start` (server check + worker) and a second stop, still under the same PATH
    out="$(la bash "${GEN}/scripts/local-ai.sh" start 2>&1)"
    has "${out}" 'worker started' && ok "[${label}] start brings the worker up" || bad "[${label}] start: ${out}"
    la bash "${GEN}/scripts/local-ai.sh" stop >/dev/null 2>&1
    left="$(wait_gone 8)" && ok "[${label}] after stop no process of this state directory is left" \
        || bad "[${label}] processes left after stop: ${left}"
    [ ! -e "${LOG}/claude-was-run" ] && ok "[${label}] todo, the worker, start and stop never touched claude" \
        || bad "[${label}] the worker side ran the claude command"
}

echo "-- 3) the queue worker, end to end (no claude, then a decoy claude first on PATH) --"
PATHV="${P_NO}"; worker_section "no claude"
PATHV="${P_DECOY}"; worker_section "decoy claude"

# `up` starts the real server command (the stub), on loopback; `stop --server` must end THAT
# process, and only that one. The stub records the environment it was started with.
server_section() {   # LABEL
    local label="$1" out fp pid unrelated
    rm -rf "${LA_STATE}"; rm -f "${LOG}/serve-env.txt" "${LOG}/claude-was-run"
    fp="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
    out="$(la env OLLAMA_HOST="127.0.0.1:${fp}" bash "${GEN}/scripts/local-ai.sh" up 2>&1)"
    has "${out}" "ollama started on 127\\.0\\.0\\.1:${fp}" && ok "[${label}] up starts the server and waits until it answers" \
        || bad "[${label}] up: ${out}"
    has "$(cat "${LOG}/serve-env.txt" 2>/dev/null)" "^OLLAMA_HOST=127\\.0\\.0\\.1:${fp}\$" \
        && ok "[${label}] the server is started bound to loopback only" \
        || bad "[${label}] the server's OLLAMA_HOST was: $(grep -a '^OLLAMA_HOST' "${LOG}/serve-env.txt" 2>/dev/null)"
    pid="$(cat "${LA_STATE}/ollama.pid" 2>/dev/null)"
    if alive "${pid}" && has "$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null)" 'ollama'; then
        ok "[${label}] ollama.pid is the server process itself (pid ${pid})"
    else bad "[${label}] ollama.pid (${pid}) is not the server: $(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null)"; fi
    sleep 300 & unrelated=$!
    out="$(la env OLLAMA_HOST="127.0.0.1:${fp}" bash "${GEN}/scripts/local-ai.sh" stop --server 2>&1)"
    has "${out}" 'stopped the Ollama this script started' && ok "[${label}] stop --server says it stopped the server" \
        || bad "[${label}] stop --server: ${out}"
    for _ in $(seq 1 25); do alive "${pid}" || break; sleep 0.2; done
    ! alive "${pid}" && ok "[${label}] the server process is really gone after stop --server" \
        || bad "[${label}] the server (pid ${pid}) is still running after stop --server"
    alive "${unrelated}" && ok "[${label}] an unrelated process survives stop --server" || bad "[${label}] stop --server killed an unrelated process"
    kill "${unrelated}" 2>/dev/null; alive "${pid}" && kill "${pid}" 2>/dev/null
    # The case that matters: ollama.pid names a process that is NOT an Ollama (the real
    # server died and the pid was reused). stop --server must read its name and leave it be.
    sleep 300 & unrelated=$!
    echo "${unrelated}" >"${LA_STATE}/ollama.pid"
    out="$(la env OLLAMA_HOST="127.0.0.1:${fp}" bash "${GEN}/scripts/local-ai.sh" stop --server 2>&1)"
    sleep 0.5
    if alive "${unrelated}" && has "${out}" 'leaving any other one alone' && ! has "${out}" 'stopped the Ollama'; then
        ok "[${label}] a process that is not an Ollama survives stop --server even when ollama.pid names it"
    else bad "[${label}] stop --server signalled the process named in ollama.pid without checking what it is: ${out}"; fi
    kill "${unrelated}" 2>/dev/null
    [ ! -e "${LOG}/claude-was-run" ] && ok "[${label}] up and stop --server never touched claude" \
        || bad "[${label}] up or stop --server ran the claude command"
}
echo "-- 3a) up starts a loopback server; stop --server ends exactly that process --"
PATHV="${P_NO}"; server_section "no claude"
PATHV="${P_DECOY}"; server_section "decoy claude"

# A stop with a draft in flight must leave nothing running, hand the job back to the queue
# and not leave the draft saying "running". The draft is held at two different places: while
# gh reads the issue, and while the model thinks (the step run under timeout, which makes a
# process group of its own that a plain group kill does not reach).
inflight_section() {   # LABEL POINT(gh|model)
    local label="$1" point="$2" out left w
    rm -rf "${LA_STATE}"; rm -f "${LOG}/gh-slow" "${LOG}/gh.pid" "${LOG}/requests.jsonl" "${LOG}/claude-was-run"
    if [ "${point}" = gh ]; then touch "${LOG}/gh-slow"; printf good >"${LOG}/mode"; else printf slow >"${LOG}/mode"; fi
    la bash "${GEN}/scripts/local-ai.sh" draft --queue hugmesh-fixture 1 >/dev/null 2>&1
    la bash "${GEN}/scripts/local-ai.sh" worker >/dev/null 2>&1
    for _ in $(seq 1 60); do
        if [ "${point}" = gh ]; then alive "$(cat "${LOG}/gh.pid" 2>/dev/null)" && break
        else [ -s "${LOG}/requests.jsonl" ] && break; fi
        sleep 0.5
    done
    w="$(status_word hugmesh-fixture-1)"
    [ "${w}" = "running" ] && [ -n "$(strays)" ] && ok "[${label}] the draft is in flight (STATUS running, ${point} step holding it)" \
        || bad "[${label}] the draft never got into flight: STATUS=${w}"
    # the same draft asked for again while a live worker holds it is not queued a second time
    out="$(la bash "${GEN}/scripts/local-ai.sh" draft --queue hugmesh-fixture 1 2>&1)"
    has "${out}" '^already queued' && [ "$(ls "${LA_STATE}/queue/pending" | wc -l)" -eq 0 ] \
        && ok "[${label}] asking again for a draft a live worker is running queues nothing" \
        || bad "[${label}] a draft the worker holds was queued again: ${out}; pending=$(ls "${LA_STATE}/queue/pending" | wc -l)"
    sj="$(la bash "${GEN}/scripts/local-ai.sh" status --json 2>&1)"
    python3 -c 'import json,sys; d=json.loads(sys.argv[1]); r=[j for j in d["jobs"] if j["kind"]=="draft"]; sys.exit(0 if r and r[0]["state"]=="running" else 1)' "${sj}" 2>/dev/null \
        && ok "[${label}] while it works, the work list shows the draft as running" || bad "[${label}] work list while running: ${sj}"
    out="$(la bash "${GEN}/scripts/local-ai.sh" stop 2>&1)"
    has "${out}" 'worker stopped' && ok "[${label}] stop reports the worker stopped" || bad "[${label}] stop: ${out}"
    left="$(wait_gone 8)" && ok "[${label}] after stop NO process of the draft is left (draft.sh, ${point} step and children)" \
        || { bad "[${label}] processes left running after stop: $(for p in ${left}; do printf '%s:%s ' "${p}" "$(tr '\0' ' ' <"/proc/${p}/cmdline" 2>/dev/null | cut -c1-60)"; done)"
             for p in ${left}; do kill -KILL "${p}" 2>/dev/null; done; }
    [ "$(ls "${LA_STATE}/queue/pending" | wc -l)" -eq 1 ] && [ "$(ls "${LA_STATE}/queue/running" | wc -l)" -eq 0 ] \
        && ok "[${label}] the job in hand went back to queue/pending (nothing left under running)" \
        || bad "[${label}] queue after stop: pending=$(ls "${LA_STATE}/queue/pending" | wc -l) running=$(ls "${LA_STATE}/queue/running" | wc -l)"
    w="$(status_word hugmesh-fixture-1)"
    [ "${w}" = "queued" ] && ok "[${label}] the draft is back to STATUS queued, not left saying running" \
        || bad "[${label}] draft STATUS after stop: $(cat "${LA_STATE}/drafts/hugmesh-fixture-1/STATUS" 2>/dev/null)"
    sj="$(la bash "${GEN}/scripts/local-ai.sh" status 2>&1)"
    if has "${sj}" 'running +hugmesh-fixture-1' || has "${sj}" '^  running '; then bad "[${label}] status after stop still lists something as running: ${sj}"
    else ok "[${label}] after stop the status lists nothing as running"; fi
    rm -f "${LOG}/gh-slow"
    [ ! -e "${LOG}/claude-was-run" ] && ok "[${label}] the stop path never touched claude" || bad "[${label}] claude ran during the stop path"
}
echo "-- 3b0) stop with a draft in flight leaves nothing running --"
for PATHV in "${P_NO}" "${P_DECOY}"; do
    lbl="no claude"; [ "${PATHV}" = "${P_DECOY}" ] && lbl="decoy claude"
    inflight_section "${lbl}/gh" gh
    inflight_section "${lbl}/model" model
done
PATHV="${P_NO}"

echo "-- 3b1) a draft that says running with no process behind it is not work in progress --"
rm -rf "${LA_STATE}"; mkdir -p "${LA_STATE}/drafts/hugmesh-fixture-1"
printf 'running\n' >"${LA_STATE}/drafts/hugmesh-fixture-1/STATUS"
sj="$(la bash "${GEN}/scripts/local-ai.sh" status --json 2>&1)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); r=[j for j in d["jobs"] if j["kind"]=="draft"]; sys.exit(0 if r and r[0]["state"]=="stalled" else 1)' "${sj}" 2>/dev/null \
    && ok "a stranded 'running' draft is listed as stalled" || bad "a stranded running draft: ${sj}"
out="$(la bash "${GEN}/scripts/local-ai.sh" todo 1 hugmesh-fixture --dry-run 2>&1)"
has "${out}" 'would queue hugmesh-fixture#1' && ok "todo queues a stranded draft again instead of skipping it" || bad "todo on a stranded draft: ${out}"
printf 'applied files=1\n' >"${LA_STATE}/drafts/hugmesh-fixture-1/STATUS"
out="$(la bash "${GEN}/scripts/local-ai.sh" todo 1 hugmesh-fixture --dry-run 2>&1)"
has "${out}" 'skip hugmesh-fixture#1' && ok "todo still skips a finished draft" || bad "todo on a finished draft: ${out}"

echo "-- 3b1b) after a crash, todo really queues the stranded draft and a worker runs it --"
# A worker that died (kill -9, a restart) leaves its job under queue/running and the draft
# saying "running" with a dead pid. todo must put a NEW job in pending (the old one was
# never going to run), and the next worker must finish exactly one draft, not two.
for PATHV in "${P_NO}" "${P_DECOY}"; do
    lbl="no claude"; [ "${PATHV}" = "${P_DECOY}" ] && lbl="decoy claude"
    rm -rf "${LA_STATE}"; printf good >"${LOG}/mode"; rm -f "${LOG}/claude-was-run"
    mkdir -p "${LA_STATE}/drafts/hugmesh-fixture-1" "${LA_STATE}/queue/running" "${LA_STATE}/queue/pending"
    printf 'running\n' >"${LA_STATE}/drafts/hugmesh-fixture-1/STATUS"
    bash -c 'echo $$' >"${LA_STATE}/drafts/hugmesh-fixture-1/draft.pid"     # a pid that has exited
    printf 'draft hugmesh-fixture 1\n' >"${LA_STATE}/queue/running/20260101-000000-draft-hugmesh-fixture-1.job"
    # todo 1 picks the smallest open issue, #1, which is the stranded one
    out="$(la bash "${GEN}/scripts/local-ai.sh" todo 1 hugmesh-fixture 2>&1)"
    has "${out}" 'queued hugmesh-fixture#1' && ok "[${lbl}] todo reports the stranded draft as queued" \
        || bad "[${lbl}] todo on a stranded draft: ${out}"
    for _ in $(seq 1 90); do
        [ "$(status_word hugmesh-fixture-1)" = "applied" ] && [ -z "$(ls "${LA_STATE}/queue/running" 2>/dev/null)" ] \
            && [ -z "$(ls "${LA_STATE}/queue/pending" 2>/dev/null)" ] && break
        sleep 1
    done
    n_done="$(ls "${LA_STATE}/queue/done" 2>/dev/null | grep -c '\.result$')"
    [ "$(status_word hugmesh-fixture-1)" = "applied" ] && [ -z "$(ls "${LA_STATE}/queue/running" 2>/dev/null)" ] \
        && [ -z "$(ls "${LA_STATE}/queue/pending" 2>/dev/null)" ] && [ "${n_done}" -eq 1 ] \
        && ok "[${lbl}] the worker finished the stranded draft once: applied, nothing left under running or pending" \
        || bad "[${lbl}] stranded draft not finished: STATUS=$(status_word hugmesh-fixture-1) running=$(ls "${LA_STATE}/queue/running" 2>/dev/null) pending=$(ls "${LA_STATE}/queue/pending" 2>/dev/null) done=${n_done}; log: $(tail -4 "${LA_STATE}/worker.log" 2>/dev/null)"
    la bash "${GEN}/scripts/local-ai.sh" stop >/dev/null 2>&1
    wait_gone 8 >/dev/null
    [ ! -e "${LOG}/claude-was-run" ] || bad "[${lbl}] the crash-recovery path ran the claude command"
done
PATHV="${P_NO}"

echo "-- 3b1a) a new worker files a draft that had already finished, and leaves a live one alone --"
PATHV="${P_NO}"
# (a) the dead worker's draft had written its result before it died: drafting it again would
# waste a model run and overwrite the person's diff, so the worker only files the result
rm -rf "${LA_STATE}"; printf good >"${LOG}/mode"; rm -f "${LOG}/requests.jsonl"
mkdir -p "${LA_STATE}/drafts/hugmesh-fixture-1" "${LA_STATE}/queue/running" "${LA_STATE}/queue/pending"
printf 'applied files=1\n' >"${LA_STATE}/drafts/hugmesh-fixture-1/STATUS"
bash -c 'echo $$' >"${LA_STATE}/drafts/hugmesh-fixture-1/draft.pid"
printf 'draft hugmesh-fixture 1\n' >"${LA_STATE}/queue/running/20260101-000000-draft-hugmesh-fixture-1.job"
la bash "${GEN}/scripts/local-ai.sh" worker >/dev/null 2>&1
for _ in $(seq 1 30); do [ -e "${LA_STATE}/queue/done/20260101-000000-draft-hugmesh-fixture-1.result" ] && break; sleep 0.5; done
[ -e "${LA_STATE}/queue/done/20260101-000000-draft-hugmesh-fixture-1.result" ] \
    && [ -z "$(ls "${LA_STATE}/queue/running" "${LA_STATE}/queue/pending")" ] && [ ! -s "${LOG}/requests.jsonl" ] \
    && [ "$(status_word hugmesh-fixture-1)" = "applied" ] \
    && ok "a draft that had finished before the crash is filed as done, not drafted a second time" \
    || bad "finished-before-crash draft: running=$(ls "${LA_STATE}/queue/running") pending=$(ls "${LA_STATE}/queue/pending") STATUS=$(status_word hugmesh-fixture-1) requests=$(wc -l <"${LOG}/requests.jsonl" 2>/dev/null)"
la bash "${GEN}/scripts/local-ai.sh" stop >/dev/null 2>&1; wait_gone 8 >/dev/null
# (b) the dead worker's draft.sh is STILL working (it was detached): a second copy must not start
rm -rf "${LA_STATE}"; printf good >"${LOG}/mode"; rm -f "${LOG}/requests.jsonl"
mkdir -p "${LA_STATE}/drafts/hugmesh-fixture-1" "${LA_STATE}/queue/running" "${LA_STATE}/queue/pending"
python3 -c 'import time; time.sleep(120)' local-ai/draft.sh & live=$!
printf 'running\n' >"${LA_STATE}/drafts/hugmesh-fixture-1/STATUS"
echo "${live}" >"${LA_STATE}/drafts/hugmesh-fixture-1/draft.pid"
printf 'draft hugmesh-fixture 1\n' >"${LA_STATE}/queue/running/20260101-000000-draft-hugmesh-fixture-1.job"
la bash "${GEN}/scripts/local-ai.sh" worker >/dev/null 2>&1
sleep 12                                            # more than one idle cycle of the worker
[ -e "${LA_STATE}/queue/running/20260101-000000-draft-hugmesh-fixture-1.job" ] \
    && [ -z "$(ls "${LA_STATE}/queue/pending")" ] && [ ! -s "${LOG}/requests.jsonl" ] && [ "$(status_word hugmesh-fixture-1)" = "running" ] \
    && ok "a draft still running on its own after the worker died is left alone (no second copy)" \
    || bad "live draft was disturbed: running=$(ls "${LA_STATE}/queue/running") pending=$(ls "${LA_STATE}/queue/pending") STATUS=$(status_word hugmesh-fixture-1)"
kill "${live}" 2>/dev/null; wait "${live}" 2>/dev/null
# once that process is gone the worker takes the job back and runs it
for _ in $(seq 1 90); do [ "$(status_word hugmesh-fixture-1)" = "applied" ] && break; sleep 1; done
[ "$(status_word hugmesh-fixture-1)" = "applied" ] \
    && ok "when the leftover draft process ends, the worker takes its job back and finishes the draft" \
    || bad "leftover job not taken back after its process ended: STATUS=$(status_word hugmesh-fixture-1) running=$(ls "${LA_STATE}/queue/running")"
la bash "${GEN}/scripts/local-ai.sh" stop >/dev/null 2>&1; wait_gone 8 >/dev/null

echo "-- 3b1c) a job left under running with NO worker does not block queueing the same draft --"
rm -rf "${LA_STATE}"; mkdir -p "${LA_STATE}/queue/running" "${LA_STATE}/queue/pending"
printf 'draft hugmesh-fixture 1\n' >"${LA_STATE}/queue/running/20260101-000000-draft-hugmesh-fixture-1.job"
out="$(la bash "${GEN}/scripts/local-ai.sh" draft --queue hugmesh-fixture 1 2>&1)"
[ "$(ls "${LA_STATE}/queue/pending" | wc -l)" -eq 1 ] && has "${out}" '^queued ' \
    && ok "a leftover running job (no worker) is not taken for a queued one" || bad "leftover running job blocked the queue: ${out}"
out="$(la bash "${GEN}/scripts/local-ai.sh" draft --queue hugmesh-fixture 1 2>&1)"
[ "$(ls "${LA_STATE}/queue/pending" | wc -l)" -eq 1 ] && has "${out}" '^already queued' \
    && ok "asking twice for the same draft queues it once" || bad "the same draft was queued twice: ${out}"
printf 'draft hugmesh-fixture 2\n' >"${LA_STATE}/queue/pending/20260101-000001-other.job"
la bash "${GEN}/scripts/local-ai.sh" draft --queue hugmesh-fixture 1 >/dev/null 2>&1
[ "$(ls "${LA_STATE}/queue/pending" | wc -l)" -eq 2 ] \
    && ok "a different draft waiting in pending does not hide this one" || bad "queue size after the third ask: $(ls "${LA_STATE}/queue/pending" | wc -l)"

echo "-- 3b2) a status file that is old, or whose worker is gone, never says ready --"
rm -rf "${LA_STATE}"; mkdir -p "${LA_STATE}"
dead="$(bash -c 'echo $$')"
printf '{"pid": %s, "heartbeat": %s, "ollama_up": true, "model_loaded": ["qwen3:8b"]}' "${dead}" "$(( $(date +%s) - 3600 ))" >"${LA_STATE}/status.json"
out="$(PYTHONPATH="${GEN}/studio" HUGMESH_LOCAL_AI_DIR="${LA_STATE}" python3 -c 'from hugmesh_studio.core import local_ai_status as l; print(l.quick_line())')"
has "${out}" 'no worker running' && ! has "${out}" 'ready|loaded|idle' \
    && ok "the status line over an hour-old status.json says no worker, not ready" || bad "stale status.json line: ${out}"
printf '{"pid": 0, "heartbeat": %s, "ollama_up": true, "model_loaded": ["qwen3:8b"]}' "$(date +%s)" >"${LA_STATE}/status.json"
out="$(PYTHONPATH="${GEN}/studio" HUGMESH_LOCAL_AI_DIR="${LA_STATE}" python3 -c 'from hugmesh_studio.core import local_ai_status as l; print(l.quick_line())')"
has "${out}" 'no worker running' && ! has "${out}" 'ready|loaded|idle' \
    && ok "the status line right after a normal stop (pid 0) does not repeat the old server answer" || bad "stopped worker line: ${out}"

echo "-- 3b3) the draft refuses a diff that leaves the tree, and never keeps an old diff --"
for m in escape gitdir; do
    rm -rf "${LA_STATE}"; printf "${m}" >"${LOG}/mode"
    la bash "${GEN}/scripts/local-ai.sh" draft hugmesh-fixture 1 >/dev/null 2>&1
    has "$(cat "${LA_STATE}/drafts/hugmesh-fixture-1/STATUS" 2>/dev/null)" '^does-not-apply refused: the diff touches' \
        && [ ! -e "${LA_STATE}/scratch/x.txt" ] \
        && ok "a diff that edits ${m/escape/../x.txt} is refused by the path check, not applied" \
        || bad "unsafe diff (${m}): $(cat "${LA_STATE}/drafts/hugmesh-fixture-1/STATUS" 2>/dev/null)"
done
rm -rf "${LA_STATE}"; printf good >"${LOG}/mode"
la bash "${GEN}/scripts/local-ai.sh" draft hugmesh-fixture 1 >/dev/null 2>&1
[ -s "${LA_STATE}/drafts/hugmesh-fixture-1/draft.diff" ] || bad "setup: the good draft left no diff"
printf nochange >"${LOG}/mode"
la bash "${GEN}/scripts/local-ai.sh" draft hugmesh-fixture 1 >/dev/null 2>&1
[ "$(status_word hugmesh-fixture-1)" = "no-diff" ] && [ ! -s "${LA_STATE}/drafts/hugmesh-fixture-1/draft.diff" ] \
    && ok "re-running a draft empties the old diff, so no diff sits beside a no-diff status" \
    || bad "stale diff kept: STATUS=$(status_word hugmesh-fixture-1) diff bytes=$(wc -c <"${LA_STATE}/drafts/hugmesh-fixture-1/draft.diff")"
rm -rf "${LA_STATE}"; printf slow >"${LOG}/mode"; t0=$SECONDS
la env TODO_TIMEOUT=3 bash "${GEN}/scripts/local-ai.sh" draft hugmesh-fixture 1 >/dev/null 2>&1
[ $((SECONDS - t0)) -lt 25 ] && [ "$(status_word hugmesh-fixture-1)" != "running" ] \
    && ok "a model that never answers is cut off by the time limit ($((SECONDS - t0)) s)" \
    || bad "slow model: took $((SECONDS - t0)) s, STATUS=$(status_word hugmesh-fixture-1)"
printf good >"${LOG}/mode"

echo "-- 3b) the draft step itself starts from an empty environment --"
rm -rf "${LA_STATE}"; printf good >"${LOG}/mode"
PATHV="${P_NO}" la env GH_TOKEN=secret-a GITHUB_TOKEN=secret-b REGISTRY_TOKEN=secret-c SOME_OTHER=keep-out \
    bash "${GEN}/scripts/local-ai.sh" draft hugmesh-fixture 1 >/dev/null 2>&1
names="$(grep -a '^\[.*\] environment names:' "${LA_STATE}/drafts/hugmesh-fixture-1/agent.log" 2>/dev/null | head -1)"
if [ -z "${names}" ]; then bad "the draft step did not log the environment names it was handed"
elif has "${names}" 'TOKEN|SOME_OTHER'; then bad "the draft step inherited a variable outside the allowlist: ${names}"
else ok "the draft step was handed only: ${names#*names: }"; fi

echo "-- 3c) the files the model is shown: a path the issue names is found, ending or not --"
PICK="${WORK}/picker"; mkdir -p "${PICK}/specs/usr/sbin" "${PICK}/specs/selinux" "${PICK}/tests/qemu" "${PICK}/docs"
printf 'a\n' >"${PICK}/specs/usr/sbin/hugmesh-firewall-reconcile"
printf 'b\n' >"${PICK}/specs/selinux/hugmesh_tor.te"
printf 'c\n' >"${PICK}/tests/qemu/avc-workload.sh"
printf 'restart tor restart tor\n' >"${PICK}/docs/OTHER.md"
git -C "${PICK}" init -q . && git -C "${PICK}" add -A >/dev/null
picked="$(PYTHONDONTWRITEBYTECODE=1 python3 - "${GEN}/scripts/local-ai" "${PICK}" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import draft
issue = ("Three places say restart: `specs/usr/sbin/hugmesh-firewall-reconcile:13`, "
         "tests/qemu/avc-workload.sh:31 and specs/selinux/hugmesh_tor.te (authored).")
print("\n".join(draft.pick_files(sys.argv[2], issue)))
PYEOF
)"
for want in specs/usr/sbin/hugmesh-firewall-reconcile specs/selinux/hugmesh_tor.te tests/qemu/avc-workload.sh; do
    if has "${picked}" "(^|[[:space:]])${want}([[:space:]]|\$)"; then ok "the picker found ${want}"
    else bad "the picker missed ${want} (picked: $(tr '\n' ' ' <<<"${picked}"))"; fi
done

echo "-- 3d) extract_diff: a diff is taken from a reply only when it really is one --"
exd="$(PYTHONDONTWRITEBYTECODE=1 python3 - "${GEN}/scripts/local-ai" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import draft
fenced = "Sure:\n```diff\n--- a/f.txt\n+++ b/f.txt\n@@ -1 +1 @@\n-a\n+b\n```\nDone."
print("fenced", draft.extract_diff(fenced).startswith("--- a/f.txt\n+++ b/f.txt\n"))
print("fenced-clean", "```" not in draft.extract_diff(fenced) and "Done" not in draft.extract_diff(fenced))
print("no-plus-line", draft.extract_diff("--- a/f.txt\nthe rest is prose\n") == "")
print("prose", draft.extract_diff("I would change the file.\n") == "")
print("githeader", draft.extract_diff("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b\n").startswith("diff --git"))
print("crlf", draft.extract_diff("--- a/f\r\n+++ b/f\r\n@@ -1 +1 @@\r\n-a\r\n+b\r\n").startswith("--- a/f\n"))
PYEOF
)"
for want in fenced fenced-clean no-plus-line prose githeader crlf; do
    has "${exd}" "^${want} True\$" && ok "extract_diff: ${want}" || bad "extract_diff: ${want} (got: $(tr '\n' ' ' <<<"${exd}"))"
done

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
# draft.py on its own, handed a DIRTY environment: its agent environment is built from an
# allowlist too, so the guard does not rest on the caller having cleaned up first
DIRECT="${WORK}/direct"; mkdir -p "${DIRECT}/out"
git init -q "${DIRECT}/work" 2>/dev/null; printf 'alpha\nbeta\ngamma\n' >"${DIRECT}/work/hello.txt"
git -C "${DIRECT}/work" add hello.txt; git -C "${DIRECT}/work" -c user.name=t -c user.email=t@example.invalid commit -q -m x
printf '# Fix beta in hello.txt\n\nchange beta\n' >"${DIRECT}/out/issue.md"
env -i PATH="${P_NO}" HOME="${HOMEDIR}" GH_TOKEN=secret-a GITHUB_TOKEN=secret-b REGISTRY_TOKEN=secret-c SOME_OTHER=keep-out \
    OLLAMA_HOST="127.0.0.1:${PORT}" python3 "${GEN}/scripts/local-ai/draft.py" --repo x --issue 1 \
    --out "${DIRECT}/out" --work "${DIRECT}/work" --agent opencode --model qwen3:8b >/dev/null 2>&1
env_seen="$(cat "${LOG}/agent-env.txt" 2>/dev/null)"
if [ -z "${env_seen}" ]; then bad "draft.py with a dirty environment never reached the agent"
elif has "${env_seen}" 'secret-|SOME_OTHER|TOKEN'; then bad "draft.py handed the agent a variable outside the allowlist"
else ok "draft.py builds the agent environment from the allowlist even when called with a dirty one"; fi
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
has "$(cat "${LA_STATE}/drafts/hugmesh-fixture-1/STATUS" 2>/dev/null)" '^no-ollama OLLAMA_HOST is not a loopback address' \
    && ok "draft with a non-loopback OLLAMA_HOST stops with no-ollama, at the host check itself" \
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

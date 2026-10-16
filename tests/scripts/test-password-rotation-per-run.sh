#!/usr/bin/env bash
# test-password-rotation-per-run.sh — the e2e password ROTATES per run, and only there.
#
# THE DEFECT (operator report 2026-10-15). tests/stack/e2e-password.sh's contract
# says "random-per-run", but its only entry point resolved env -> the credentials
# file -> generate, and nothing ever started a new value: the operator's
# .e2e-credentials was dated 2026-08-27 and every run since reused it. The
# generator also stripped `/+=` out of a 32-char base64 string AFTER the fact,
# so roughly two values in three were shorter than 32 (that file held 28).
#
# This suite pins the fix, entirely offline against TEMP credentials files (it
# never reads or writes the checkout's own .e2e-credentials):
#
#   1. RUN START ROTATES: e2e_password_start_run twice -> two different values,
#      each exactly 32 chars of [A-Za-z0-9]; the file stays 0600; the superseded
#      value is kept in E2E_PASSWORD_PREVIOUS; other keys survive the rewrite.
#   2. ONE RUN, ONE VALUE: after a run start, a child that inherits the env, a
#      child with E2E_PASSWORD stripped (reads the file), a nested sub-seeder that
#      itself calls e2e_password_start_run, and `bash e2e-password.sh` executed
#      directly all see the SAME value, and none of them rewrites the file.
#   3. OPT-OUTS KEEP: E2E_PASSWORD_KEEP=1 keeps the file's value; an explicit
#      E2E_PASSWORD keeps the override and never writes it to the file.
#   4. REFUSALS: a present-but-unreadable file is refused (no rotation, no
#      clobber), and the history is capped at E2E_PASSWORD_HISTORY.
#   5. THE BOUNDARY IS WIRED: the three lane run-starts call
#      e2e_password_start_run; sub-seeders and consumers never do.
#   6. RECONCILE, NOT ONLY CREATE: seed-e2e.sh leg 2's Matrix reconcile, run
#      against a stub homeserver, moves a user off a previous run's password,
#      leaves a current one alone, and FAILS loudly on a password it does not know.
#   7. THE STUDIO KEEPS: compose "Add user" and saved-mesh restore pass
#      E2E_PASSWORD_KEEP=1, so adding one account cannot re-password every other.
#
# Proven to bite: tests/scripts/password_rotation_per_run_mutations.sh reverts each
# production line and demands RED.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
LIB="${REPO}/tests/stack/e2e-password.sh"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

for t in bash python3 curl jq awk openssl; do
  command -v "${t}" >/dev/null 2>&1 || { echo "  FAIL required tool missing: ${t}"; exit 1; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/e2epw-rot.XXXXXX")"
STUB_PID=""
cleanup() { [ -n "${STUB_PID}" ] && kill "${STUB_PID}" 2>/dev/null; rm -rf "${WORK}"; }
trap cleanup EXIT

# Every child runs with a CLEAN e2e environment: nothing the caller exported
# (an operator's E2E_PASSWORD, a KEEP flag) may leak into a case.
clean_env() { env -u E2E_PASSWORD -u E2E_PASSWORD_KEEP -u E2E_PASSWORD_PREVIOUS \
                  -u E2E_PASSWORD_HISTORY "$@"; }
# start_run <credfile> [VAR=val ...] -> prints the value the run started with
start_run() {
  local f="$1"; shift
  clean_env E2E_CREDENTIALS_FILE="${f}" "$@" bash -c '
    . "$1" || exit 9
    e2e_password_start_run || exit 8
    printf "%s" "${E2E_PASSWORD}"' _ "${LIB}"
}
keyof() { awk -F= -v k="$2" '$1==k { sub(/^[^=]*=/, ""); print }' "$1" | tail -n1; }
is32() { [[ "$1" =~ ^[A-Za-z0-9]{32}$ ]]; }

echo "== e2e password: rotate per run, one value per run =="

# ── 1. run start rotates ─────────────────────────────────────────────────────
echo "-- 1) every run start mints a NEW 32-char CSPRNG value --"
C1="${WORK}/c1"
printf 'E2E_TENANT2_PASSWORD=keepme\n' > "${C1}"; chmod 600 "${C1}"
V1="$(start_run "${C1}")" || bad "first run start failed (rc=$?)"
V2="$(start_run "${C1}")" || bad "second run start failed (rc=$?)"
if [ -n "${V1}" ] && [ -n "${V2}" ] && [ "${V1}" != "${V2}" ]; then
  ok "two run starts produced two different values"
else
  bad "two run starts produced the SAME value (or none): '${V1:0:4}…' vs '${V2:0:4}…' — the password does not rotate"
fi
if is32 "${V1}" && is32 "${V2}"; then ok "both values are exactly 32 chars of [A-Za-z0-9]"
else bad "a run-start value is not 32 alphanumeric chars (lengths ${#V1}, ${#V2})"; fi
[ "$(keyof "${C1}" E2E_PASSWORD)" = "${V2}" ] && ok "the file holds the latest run's value" \
  || bad "the file does not hold the value the run exported"
[ "$(keyof "${C1}" E2E_PASSWORD_PREVIOUS)" = "${V1}" ] && ok "the superseded value is kept in E2E_PASSWORD_PREVIOUS (for stores that need the old one)" \
  || bad "E2E_PASSWORD_PREVIOUS is '$(keyof "${C1}" E2E_PASSWORD_PREVIOUS | cut -c1-4)…', expected the first run's value"
[ "$(keyof "${C1}" E2E_TENANT2_PASSWORD)" = "keepme" ] && ok "other keys in the file survive the rotation" \
  || bad "the rotation dropped an unrelated key from the file"
[ "$(stat -c '%a' "${C1}")" = "600" ] && ok "the rewritten file is mode 600" \
  || bad "the rewritten file is mode $(stat -c '%a' "${C1}"), expected 600"
[ -z "$(find "${WORK}" -maxdepth 1 -name 'c1.*' -print -quit)" ] && ok "no temp file is left beside the credentials file" \
  || bad "a temp file was left beside the credentials file"

# The generator itself: many draws, every one exactly 32 alphanumeric, all distinct.
GEN="$(clean_env bash -c '. "$1"; for i in $(seq 1 300); do e2e_password_generate; echo; done' _ "${LIB}")"
nbad="$(printf '%s\n' "${GEN}" | grep -cvE '^[A-Za-z0-9]{32}$')"
nuniq="$(printf '%s\n' "${GEN}" | sort -u | grep -c .)"
[ "${nbad}" = "0" ] && ok "300 generator draws: every one is exactly 32 alphanumeric chars" \
  || bad "${nbad} of 300 generator draws are not 32 alphanumeric chars (the strip-after-the-fact shortening)"
[ "${nuniq}" = "300" ] && ok "300 generator draws are all distinct" || bad "only ${nuniq} of 300 draws are distinct"
# CSPRNG source only: the generator body may name openssl rand and /dev/urandom,
# and never $RANDOM, date or a PID.
GBODY="$(awk '/^e2e_password_generate\(\)/,/^}/' "${LIB}" | grep -v '^[[:space:]]*#')"
if printf '%s' "${GBODY}" | grep -F 'openssl rand' >/dev/null \
   && printf '%s' "${GBODY}" | grep -F '/dev/urandom' >/dev/null \
   && ! printf '%s' "${GBODY}" | grep -E '\$RANDOM|\$\$|\bdate\b|\$BASHPID' >/dev/null; then
  ok "the generator draws only from openssl rand / /dev/urandom"
else
  bad "the generator draws from something other than openssl rand / /dev/urandom"
fi

# ── 2. one run, one value ────────────────────────────────────────────────────
echo "-- 2) every process inside ONE run reads the SAME value --"
C2="${WORK}/c2"
OUT="$(clean_env E2E_CREDENTIALS_FILE="${C2}" bash -c '
  . "$1" || exit 9
  e2e_password_start_run || exit 8
  before="$(stat -c %Y.%i "${E2E_CREDENTIALS_FILE}")"
  echo "parent=${E2E_PASSWORD}"
  # a child that inherits the exported env and resolves like a consumer
  echo "child_env=$(bash -c ". \"$1\"; e2e_password_ensure; printf %s \"\${E2E_PASSWORD}\"" _ "$1")"
  # a child with E2E_PASSWORD stripped: must resolve from the FILE, not mint
  echo "child_file=$(env -u E2E_PASSWORD bash -c ". \"$1\"; e2e_password_ensure; printf %s \"\${E2E_PASSWORD}\"" _ "$1")"
  # a nested sub-seeder that (wrongly or not) calls the run start again: the
  # inherited value must win, never a second rotation inside one run
  echo "nested_start=$(bash -c ". \"$1\"; e2e_password_start_run; printf %s \"\${E2E_PASSWORD}\"" _ "$1")"
  # executing the library directly (the Makefile banner, mock-bff hint) never rotates
  echo "direct=$(env -u E2E_PASSWORD bash "$1")"
  echo "unchanged=$([ "$(stat -c %Y.%i "${E2E_CREDENTIALS_FILE}")" = "${before}" ] && echo yes || echo no)"
' _ "${LIB}")" || bad "the one-run harness failed: ${OUT}"
pv="$(printf '%s\n' "${OUT}" | sed -n 's/^parent=//p')"
for who in child_env child_file nested_start direct; do
  v="$(printf '%s\n' "${OUT}" | sed -n "s/^${who}=//p")"
  if [ -n "${pv}" ] && [ "${v}" = "${pv}" ]; then ok "${who}: same value as the run start"
  else bad "${who}: got '${v:0:4}…', the run started with '${pv:0:4}…' — one run split across two passwords"; fi
done
printf '%s\n' "${OUT}" | grep -x 'unchanged=yes' >/dev/null \
  && ok "no process after the run start rewrote the credentials file" \
  || bad "a process after the run start rewrote the credentials file"

# ── 3. opt-outs keep ─────────────────────────────────────────────────────────
echo "-- 3) E2E_PASSWORD_KEEP=1 and an explicit E2E_PASSWORD both keep --"
C3="${WORK}/c3"
K0="$(start_run "${C3}")"
K1="$(start_run "${C3}" E2E_PASSWORD_KEEP=1)" || bad "KEEP run start failed"
[ -n "${K0}" ] && [ "${K1}" = "${K0}" ] && ok "E2E_PASSWORD_KEEP=1: the run reuses the file's value" \
  || bad "E2E_PASSWORD_KEEP=1 still rotated ('${K0:0:4}…' -> '${K1:0:4}…')"
[ "$(keyof "${C3}" E2E_PASSWORD)" = "${K0}" ] && ok "E2E_PASSWORD_KEEP=1: the file is untouched" \
  || bad "E2E_PASSWORD_KEEP=1 rewrote the file"
C3b="${WORK}/c3b"
K2="$(start_run "${C3b}" E2E_PASSWORD_KEEP=1)"
is32 "${K2}" && [ -f "${C3b}" ] && ok "E2E_PASSWORD_KEEP=1 on a tree with no file still mints and persists one" \
  || bad "E2E_PASSWORD_KEEP=1 with no file did not mint a usable value"
O1="$(start_run "${C3}" E2E_PASSWORD=operator-override-value)"
[ "${O1}" = "operator-override-value" ] && ok "explicit E2E_PASSWORD: the override is kept" \
  || bad "explicit E2E_PASSWORD was replaced by '${O1:0:4}…'"
[ "$(keyof "${C3}" E2E_PASSWORD)" = "${K0}" ] && ! grep -F 'operator-override-value' "${C3}" >/dev/null \
  && ok "explicit E2E_PASSWORD: never written to the file, the file keeps its value" \
  || bad "explicit E2E_PASSWORD rewrote the credentials file"

# ── 4. refusals + history cap ────────────────────────────────────────────────
echo "-- 4) refusals and the history cap --"
if [ "$(id -u)" -ne 0 ]; then
  C4="${WORK}/c4"; printf 'E2E_PASSWORD=Unreadable0000000000000000000000\n' > "${C4}"; chmod 000 "${C4}"
  if start_run "${C4}" >/dev/null 2>"${WORK}/c4.err"; then
    bad "a present-but-unreadable file was rotated over instead of refused"
  else
    ok "a present-but-unreadable file is refused (no silent clobber)"
  fi
  # The writer refuses on its own too (any future caller that skips the read).
  if clean_env E2E_CREDENTIALS_FILE="${C4}" bash -c '. "$1"; e2e_password_write E2E_PASSWORD x' _ "${LIB}" 2>"${WORK}/c4w.err"; then
    bad "e2e_password_write replaced a present-but-unreadable file"
  elif grep -F 'not readable' "${WORK}/c4w.err" >/dev/null; then
    ok "e2e_password_write itself refuses a present-but-unreadable file, naming the fix"
  else
    bad "e2e_password_write failed on an unreadable file without the named-fix message: $(head -c 160 "${WORK}/c4w.err")"
  fi
  chmod 600 "${C4}"
  [ "$(keyof "${C4}" E2E_PASSWORD)" = "Unreadable0000000000000000000000" ] \
    && ok "...and the unreadable file was left exactly as it was" || bad "...but the unreadable file was replaced"
else
  ok "SKIP unreadable-file refusal: running as root, which can read a 000 file"
fi
C5="${WORK}/c5"
for _ in 1 2 3 4; do start_run "${C5}" E2E_PASSWORD_HISTORY=2 >/dev/null; done
nprev="$(keyof "${C5}" E2E_PASSWORD_PREVIOUS | tr ',' '\n' | grep -c .)"
[ "${nprev}" = "2" ] && ok "E2E_PASSWORD_PREVIOUS is capped at E2E_PASSWORD_HISTORY (2)" \
  || bad "E2E_PASSWORD_PREVIOUS holds ${nprev} values with E2E_PASSWORD_HISTORY=2"

# ── 5. the boundary is wired where a run starts, and nowhere else ────────────
echo "-- 5) the run boundary: lane run-starts rotate, nothing else does --"
code_of() { grep -v '^[[:space:]]*#' "$1"; }
for f in tests/stack/seed-e2e.sh specs/cluster/bootstrap/kind-local/bootstrap-kind.sh \
         tests/qemu/run-qemu-e2e.sh; do
  if code_of "${REPO}/${f}" | grep -E '^[[:space:]]*e2e_password_start_run\b' >/dev/null; then
    ok "${f} starts the run (calls e2e_password_start_run)"
  else
    bad "${f} does not call e2e_password_start_run — that lane never rotates"
  fi
done
for f in tests/qemu/seed-accounts.sh tests/e2e/run.sh tests/stack/up.sh tests/api/test-bff-admin.sh \
         tests/e2e/shot-harness/shots.sh tests/pentest/seed-personas.sh tests/stack/tor-domains-live-check.sh; do
  if code_of "${REPO}/${f}" | grep -F 'e2e_password_start_run' >/dev/null; then
    bad "${f} rotates the password, but it runs INSIDE a run (sub-seeder/consumer)"
  else
    ok "${f} does not rotate"
  fi
done
# The QEMU run start must come AFTER the --list / --dry-run exits (they seed nothing).
awk '/^if \$\{DRY_RUN\}; then/{d=NR} /^if \$\{LIST_ONLY\}; then/{l=NR} /^e2e_password_start_run/{s=NR}
     END{exit !(s && d && l && s>d && s>l)}' "${REPO}/tests/qemu/run-qemu-e2e.sh" \
  && ok "run-qemu-e2e.sh rotates only in run mode (after the --list and --dry-run exits)" \
  || bad "run-qemu-e2e.sh rotates before its --list/--dry-run exits"

# ── 6. Matrix reconcile against a stub homeserver ────────────────────────────
echo "-- 6) seed-e2e.sh leg 2 reconciles the Matrix password, not only creates --"
cat > "${WORK}/mstub.py" <<'PY'
import json, sys, secrets
from http.server import BaseHTTPRequestHandler, HTTPServer
users = json.load(open(sys.argv[1]))          # user -> password
tokens = {}
need_session = sys.argv[3] == "1"
swallow = sys.argv[3] == "2"                   # answers 200, persists nothing
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
        if self.path == "/_matrix/client/v3/login":
            u = body.get("identifier", {}).get("user")
            if u in users and users[u] == body.get("password"):
                t = secrets.token_hex(8); tokens[t] = u
                return self.send(200, {"access_token": t})
            return self.send(403, {"errcode": "M_FORBIDDEN"})
        if self.path == "/_matrix/client/v3/account/password":
            t = self.headers.get("authorization", "").removeprefix("Bearer ")
            u = tokens.get(t)
            if not u:
                return self.send(401, {"errcode": "M_MISSING_TOKEN"})
            auth = body.get("auth") or {}
            if need_session and not auth.get("session"):
                return self.send(401, {"session": "s1", "flows": [{"stages": ["m.login.password"]}]})
            if auth.get("type") != "m.login.password" or auth.get("password") != users[u]:
                return self.send(401, {"errcode": "M_FORBIDDEN"})
            if not swallow:
                users[u] = body["new_password"]
            json.dump(users, open(sys.argv[1], "w"))
            return self.send(200, {})
        self.send(404, {})
s = HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[2], "w").write(str(s.server_address[1]))
s.serve_forever()
PY
# Lift the two functions out of the REAL seed-e2e.sh (the shape test-guard's
# other extract-and-execute suites use), so this exercises production code.
awk '/^matrix_login_token\(\) \{/,/^}/' "${REPO}/tests/stack/seed-e2e.sh"        > "${WORK}/mfuncs.sh"
awk '/^matrix_reconcile_password\(\) \{/,/^}/' "${REPO}/tests/stack/seed-e2e.sh" >> "${WORK}/mfuncs.sh"
grep -F 'matrix_reconcile_password() {' "${WORK}/mfuncs.sh" >/dev/null \
  && grep -F 'matrix_login_token() {' "${WORK}/mfuncs.sh" >/dev/null \
  && ok "extracted matrix_login_token + matrix_reconcile_password from seed-e2e.sh" \
  || bad "seed-e2e.sh has no matrix_reconcile_password/matrix_login_token — leg 2 only CREATES users"

OLDPW="OldRunValue000000000000000000000"; NEWPW="NewRunValue111111111111111111111"
run_matrix() { # <need_session 0|1> <users-json> <previous-csv> -> rc; prints stub users after
  local ns="$1" uj="$2" prev="$3" port rc
  printf '%s' "${uj}" > "${WORK}/musers.json"; rm -f "${WORK}/mport"
  python3 "${WORK}/mstub.py" "${WORK}/musers.json" "${WORK}/mport" "${ns}" & STUB_PID=$!
  for _ in $(seq 1 50); do [ -s "${WORK}/mport" ] && break; sleep 0.1; done
  port="$(cat "${WORK}/mport" 2>/dev/null)"
  clean_env SYNAPSE_URL="http://127.0.0.1:${port}" E2E_PASSWORD="${NEWPW}" \
      E2E_PASSWORD_PREVIOUS="${prev}" E2E_CREDENTIALS_FILE="${WORK}/none" bash -c '
    set -euo pipefail
    log() { echo "[seed-e2e] $*"; }
    die() { echo "seed-e2e.sh: UNMET DEPENDENCY: $*" >&2; exit 2; }
    . "$1"
    matrix_reconcile_password e2e-mod
    matrix_reconcile_password e2e-user' _ "${WORK}/mfuncs.sh" > "${WORK}/mout" 2>&1
  rc=$?
  kill "${STUB_PID}" 2>/dev/null; wait "${STUB_PID}" 2>/dev/null; STUB_PID=""
  return "${rc}"
}
for ns in 0 1; do
  label="$([ "${ns}" = 1 ] && echo "server demands a UIAA session first" || echo "single-shot UIAA")"
  if run_matrix "${ns}" "{\"e2e-mod\":\"${OLDPW}\",\"e2e-user\":\"${NEWPW}\"}" "SomeOtherValue,${OLDPW}"; then
    if [ "$(jq -r '."e2e-mod"' "${WORK}/musers.json")" = "${NEWPW}" ]; then
      ok "(${label}) a user on a previous run's password is moved to this run's"
    else
      bad "(${label}) reconcile exited 0 but e2e-mod still holds the old password"
    fi
    [ "$(jq -r '."e2e-user"' "${WORK}/musers.json")" = "${NEWPW}" ] \
      && ok "(${label}) a user already on this run's password is left alone" \
      || bad "(${label}) a current user's password was changed"
  else
    bad "(${label}) reconcile FAILED for a user holding a remembered previous password: $(tail -n2 "${WORK}/mout")"
  fi
done
if run_matrix 0 "{\"e2e-mod\":\"ForgottenValue99999999999999999\",\"e2e-user\":\"${NEWPW}\"}" "${OLDPW}"; then
  bad "a user on a password nobody remembers was reported reconciled (rc 0)"
else
  grep -F 'E2E_PASSWORD_PREVIOUS' "${WORK}/mout" >/dev/null \
    && ok "a user on a password nobody remembers FAILS loudly and names the remedy" \
    || bad "the unknown-password failure does not explain itself: $(tail -n1 "${WORK}/mout")"
fi
if run_matrix 2 "{\"e2e-mod\":\"${OLDPW}\",\"e2e-user\":\"${NEWPW}\"}" "${OLDPW}"; then
  bad "a password change the server answered 200 but did not persist was reported reconciled"
else
  ok "a password change that did not persist FAILS (proved by logging in, not by the 200)"
fi
# ...and leg 2 actually CALLS it for both users before it logs in with the new value.
awk '/^matrix_register e2e-user$/{r=NR} /^matrix_reconcile_password e2e-mod$/{m=NR}
     /^matrix_reconcile_password e2e-user$/{u=NR} /^MOD_TOK=/{t=NR}
     END{exit !(r && m && u && t && m>r && u>r && t>m && t>u)}' "${REPO}/tests/stack/seed-e2e.sh" \
  && ok "leg 2 reconciles e2e-mod and e2e-user after registering and before logging in" \
  || bad "leg 2 does not reconcile both users between register and login"

# ── 7. the Studio keeps the run's password where it must ─────────────────────
echo "-- 7) Studio: Add user and saved-mesh restore never rotate --"
python3 - "${REPO}" <<'PY' && ok "compose Add user passes E2E_PASSWORD_KEEP=1 with EXTRA_ROLE_USERS" \
                         || bad "compose Add user re-runs stack-seed WITHOUT E2E_PASSWORD_KEEP=1: it re-passwords every persona"
import ast, sys
src = open(sys.argv[1] + "/studio/hugmesh_studio/gui/pages/localmesh.py", encoding="utf-8").read()
for node in ast.walk(ast.parse(src)):
    if isinstance(node, ast.Dict):
        keys = {k.value for k in node.keys if isinstance(k, ast.Constant)}
        if "EXTRA_ROLE_USERS" in keys:
            i = [k.value if isinstance(k, ast.Constant) else None for k in node.keys].index("E2E_PASSWORD_KEEP") \
                if "E2E_PASSWORD_KEEP" in keys else -1
            sys.exit(0 if i >= 0 and getattr(node.values[i], "value", None) == "1" else 1)
sys.exit(1)
PY
python3 - "${REPO}" <<'PY' && ok "saved-mesh restore_env sets E2E_PASSWORD_KEEP=1 beside the saved credentials copy" \
                         || bad "saved-mesh restore does not keep the record's password"
import ast, sys
src = open(sys.argv[1] + "/studio/hugmesh_studio/core/saved_meshes.py", encoding="utf-8").read()
fn = next(n for n in ast.walk(ast.parse(src)) if isinstance(n, ast.FunctionDef) and n.name == "restore_env")
for n in ast.walk(fn):
    if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Subscript) \
       and getattr(n.targets[0].slice, "value", None) == "E2E_PASSWORD_KEEP" \
       and getattr(n.value, "value", None) == "1":
        sys.exit(0)
sys.exit(1)
PY

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

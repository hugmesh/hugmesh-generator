#!/usr/bin/env bash
# test-derive-games-admin.sh — tests/stack/derive-games-admin.sh really derives
# ROLE_GAMES_ADMIN = ROLE_GAMES ∩ (ROLE_ADMIN ∪ ROLE_MOD), and is HONEST about
# every way a Casdoor write can silently not happen.
#
# WHAT IS ASSERTED
#   [fixture]   --fixture (no network at all) computes the intersection for a
#               three-user fixture: the one holder of games+admin and the one
#               holder of games+mod qualify, a games-only, an admin-only and a
#               mod-only user do not, a stale member is pruned. Counts and
#               handles are printed; nothing is written (no curl is even needed).
#   [live]      against tests/scripts/casdoor_stub.py in `ok` mode, seeded with
#               the four roles: the script logs in, writes EXACTLY the
#               intersection, reads it back, and a SECOND run reports "already ==".
#               The stub's journal proves exactly ONE update-role POST on the
#               first run and NONE on the second.
#   [dry-run]   --dry-run against the same live stub prints the plan and the
#               journal shows ZERO update-role POSTs.
#   [deny-login] a stub that refuses the admin login -> non-zero exit, no write.
#   [writes-vanish] a stub that answers ok/"Affected" and stores nothing -> the
#               read-back catches it, non-zero exit (the live Casdoor shape
#               manifests/casdoor/init-job.yaml documents).
#   [readback-denied] the verification read is denied -> non-zero exit, never
#               "membership did not change" dressed up as success.
#   [absent]    the derived role does not exist in Casdoor -> non-zero exit
#               naming the role, no write.
#   [secrets]   the admin password never appears on stdout or stderr in any run.
#
# NEGATIVE CONTROLS on the SCRIPT (break production, see red, restore — on a
# COPY, the file on disk is never modified): with the envelope check removed,
# deny-login would be reported as a successful derivation; with the read-back
# removed, writes-vanish would. Each mutated copy is PROVEN to differ from the
# original before it is run.
#
# Offline: python3 (stdlib) + bash + curl + jq. The stub binds 127.0.0.1 on an
# ephemeral port; no cluster, no docker, no egress.
# shellcheck disable=SC2015,SC2016  # A && ok || bad is the assertion idiom this repo's guards use; the sed
# expressions are deliberately single-quoted so the ${…} reach sed verbatim.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
SCRIPT="${HERE}/derive-games-admin.sh"
STUB="${REPO}/tests/scripts/casdoor_stub.py"

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

for t in python3 curl jq; do
  command -v "$t" >/dev/null 2>&1 || { echo "FATAL: $t required (refusing to skip)" >&2; exit 1; }
done
[ -x "${SCRIPT}" ] || { echo "FATAL: ${SCRIPT} is not executable" >&2; exit 1; }
[ -r "${STUB}" ] || { echo "FATAL: cannot read ${STUB}" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-derive-games-admin.XXXXXX")"
STUB_PID=""
stub_down() { if [ -n "${STUB_PID}" ]; then kill "${STUB_PID}" 2>/dev/null; wait "${STUB_PID}" 2>/dev/null; STUB_PID=""; fi; }
trap 'stub_down; rm -rf "${WORK}"' EXIT

# A password unlike casdoor's default, so a leak is recognisable.
ADMIN_PW="fixture-admin-pw-7c1e5b-never-printed"

# The four roles as the stub stores them ("<noun>:<owner>/<name>").
seed_json() { # <members-of-ROLE_GAMES_ADMIN as JSON array>
  jq -nc --argjson ga "$1" '{
    "role:hugmesh/ROLE_GAMES":       {owner:"hugmesh", name:"ROLE_GAMES",       displayName:"Games Member",
                                      users:["hugmesh/e2e-gamesonly","hugmesh/e2e-gamesadmin","hugmesh/mesh-operator"]},
    "role:hugmesh/ROLE_ADMIN":       {owner:"hugmesh", name:"ROLE_ADMIN",       users:["hugmesh/e2e-admin","hugmesh/e2e-gamesadmin","hugmesh/e2e-adminonly"]},
    "role:hugmesh/ROLE_MOD":         {owner:"hugmesh", name:"ROLE_MOD",         users:["hugmesh/e2e-mod","hugmesh/mesh-operator"]},
    "role:hugmesh/ROLE_GAMES_ADMIN": {owner:"hugmesh", name:"ROLE_GAMES_ADMIN", displayName:"Games Admin (derived)", users:$ga}
  }'
}

stub_up() { # <mode> <seed-file-or-empty> -> sets CASDOOR_URL, JOURNAL
  stub_down
  JOURNAL="${WORK}/journal.$1.$RANDOM"; : > "${JOURNAL}"
  local portfile
  portfile="${WORK}/port"; rm -f "${portfile}"
  STUB_MODE="$1" STUB_ADMIN_PASSWORD="${ADMIN_PW}" STUB_PORT_FILE="${portfile}" \
    STUB_JOURNAL="${JOURNAL}" STUB_SEED="${2:-}" python3 "${STUB}" >"${WORK}/stub.log" 2>&1 &
  STUB_PID=$!
  for _ in $(seq 1 50); do
    [ -s "${portfile}" ] && break
    sleep 0.1
  done
  [ -s "${portfile}" ] || { echo "FATAL: stub did not come up: $(cat "${WORK}/stub.log")" >&2; exit 1; }
  CASDOOR_URL="http://127.0.0.1:$(cat "${portfile}")"
}

# run_script <script> <outfile> [args...] -> exit code; env is the stub's.
run_script() {
  local s
  local out
  s="$1"; out="$2"; shift 2
  CASDOOR_URL="${CASDOOR_URL:-http://127.0.0.1:1}" CASDOOR_ADMIN_USER=admin \
    CASDOOR_ADMIN_PASS="${ADMIN_PW}" CASDOOR_ORG=hugmesh \
    bash "$s" "$@" >"${out}" 2>&1
}

# update-role POSTs the stub journaled (one JSON object per line, never a body).
journal_updates() { grep -c '"/api/update-role' "${JOURNAL}" 2>/dev/null || true; }

no_secret() { # <outfile>
  if grep -F -q -- "${ADMIN_PW}" "$1"; then bad "[secrets] the admin password reached the output ($1)"; else ok "[secrets] no password in output ($(basename "$1"))"; fi
}

echo "== derive-games-admin: ROLE_GAMES_ADMIN = ROLE_GAMES ∩ (ROLE_ADMIN ∪ ROLE_MOD) =="

# ── [fixture] ───────────────────────────────────────────────────────────────
cat > "${WORK}/fx.json" <<'EOF'
{"ROLE_GAMES":      ["hugmesh/e2e-gamesonly", "hugmesh/e2e-gamesadmin", "hugmesh/mesh-operator"],
 "ROLE_ADMIN":      ["hugmesh/e2e-admin", "hugmesh/e2e-gamesadmin", "hugmesh/e2e-adminonly"],
 "ROLE_MOD":        ["hugmesh/e2e-mod", "hugmesh/mesh-operator"],
 "ROLE_GAMES_ADMIN":["hugmesh/stale-admin"]}
EOF
if CASDOOR_URL="http://127.0.0.1:1" bash "${SCRIPT}" --fixture "${WORK}/fx.json" >"${WORK}/fx.out" 2>&1; then
  ok "[fixture] exits 0 with no network"
else
  bad "[fixture] exited $? : $(tail -2 "${WORK}/fx.out")"
fi
grep -q "would -> 2 member(s) (+2 added, -1 removed)" "${WORK}/fx.out" \
  && ok "[fixture] 2 qualify (+2 added, -1 removed)" || bad "[fixture] counts wrong: $(cat "${WORK}/fx.out")"
grep -q "members: hugmesh/e2e-gamesadmin, hugmesh/mesh-operator" "${WORK}/fx.out" \
  && ok "[fixture] games+admin and games+mod qualify" || bad "[fixture] wrong members: $(cat "${WORK}/fx.out")"
grep -q -- "- hugmesh/stale-admin" "${WORK}/fx.out" \
  && ok "[fixture] the stale member is pruned (default-deny)" || bad "[fixture] stale member not pruned"
for h in e2e-gamesonly e2e-adminonly "e2e-admin," "e2e-mod\b"; do
  if grep -E "members:|\+ " "${WORK}/fx.out" | grep -Eq "${h}"; then bad "[fixture] single-half holder ${h} qualified"; else ok "[fixture] ${h} (one half only) does not qualify"; fi
done
grep -q "DRY RUN: nothing written" "${WORK}/fx.out" && ok "[fixture] announces the dry run" || bad "[fixture] no dry-run notice"
# a fixture without the derived role must refuse
jq 'del(.ROLE_GAMES_ADMIN)' "${WORK}/fx.json" > "${WORK}/fx-nokey.json"
if bash "${SCRIPT}" --fixture "${WORK}/fx-nokey.json" >"${WORK}/fx-nokey.out" 2>&1; then
  bad "[fixture] a fixture with no ROLE_GAMES_ADMIN key was accepted"
else
  ok "[fixture] a fixture with no ROLE_GAMES_ADMIN key is refused: $(tail -1 "${WORK}/fx-nokey.out" | cut -c1-80)"
fi

# ── [live] ok mode ───────────────────────────────────────────────────────────
seed_json '["hugmesh/stale-admin"]' > "${WORK}/seed.json"
stub_up ok "${WORK}/seed.json"
if run_script "${SCRIPT}" "${WORK}/live1.out"; then ok "[live] first run exits 0"; else bad "[live] first run exited $?: $(tail -3 "${WORK}/live1.out")"; fi
grep -q "ROLE_GAMES_ADMIN -> 2 member(s) (+2 added, -1 removed)" "${WORK}/live1.out" \
  && ok "[live] wrote exactly the intersection (+2 -1)" || bad "[live] wrong summary: $(cat "${WORK}/live1.out")"
grep -q "verified by read-back" "${WORK}/live1.out" && ok "[live] announced only after read-back" || bad "[live] no read-back notice"
[ "$(journal_updates)" = "1" ] && ok "[live] exactly one update-role POST in the stub journal" || bad "[live] update-role POSTs: $(journal_updates) (want 1)"
grep -q '"/api/get-account' "${JOURNAL}" && ok "[live] the session was PROVEN via get-account, not assumed" || bad "[live] no get-account call"
no_secret "${WORK}/live1.out"
# second run: idempotent
if run_script "${SCRIPT}" "${WORK}/live2.out"; then ok "[live] second run exits 0"; else bad "[live] second run exited $?"; fi
grep -q "already == 2 member(s)" "${WORK}/live2.out" && ok "[live] second run is a no-op (already ==)" || bad "[live] second run not idempotent: $(cat "${WORK}/live2.out")"
[ "$(journal_updates)" = "1" ] && ok "[live] second run made NO write" || bad "[live] second run wrote again ($(journal_updates) POSTs)"

# ── [dry-run] against the live stub ─────────────────────────────────────────
stub_up ok "${WORK}/seed.json"
if run_script "${SCRIPT}" "${WORK}/dry.out" --dry-run; then ok "[dry-run] exits 0"; else bad "[dry-run] exited $?: $(tail -2 "${WORK}/dry.out")"; fi
grep -q "would -> 2 member(s) (+2 added, -1 removed)" "${WORK}/dry.out" && ok "[dry-run] prints the plan" || bad "[dry-run] no plan: $(cat "${WORK}/dry.out")"
[ "$(journal_updates)" = "0" ] && ok "[dry-run] ZERO update-role POSTs" || bad "[dry-run] wrote ($(journal_updates) POSTs)"
no_secret "${WORK}/dry.out"

# ── [deny-login] ────────────────────────────────────────────────────────────
stub_up deny-login "${WORK}/seed.json"
if run_script "${SCRIPT}" "${WORK}/deny.out"; then bad "[deny-login] exited 0 against a refused login"; else ok "[deny-login] non-zero exit: $(grep FATAL "${WORK}/deny.out" | head -1 | cut -c1-90)"; fi
[ "$(journal_updates)" = "0" ] && ok "[deny-login] no write attempted" || bad "[deny-login] wrote anyway"
no_secret "${WORK}/deny.out"

# ── [writes-vanish] ─────────────────────────────────────────────────────────
stub_up writes-vanish "${WORK}/seed.json"
if run_script "${SCRIPT}" "${WORK}/vanish.out"; then bad "[writes-vanish] exited 0 although nothing was stored"; else ok "[writes-vanish] non-zero exit: $(grep FATAL "${WORK}/vanish.out" | head -1 | cut -c1-90)"; fi
grep -q "did not change" "${WORK}/vanish.out" && ok "[writes-vanish] the read-back named the failure" || bad "[writes-vanish] wrong reason: $(tail -1 "${WORK}/vanish.out")"

# ── [readback-denied] ───────────────────────────────────────────────────────
stub_up readback-denied "${WORK}/seed.json"
if run_script "${SCRIPT}" "${WORK}/rbd.out"; then bad "[readback-denied] exited 0"; else ok "[readback-denied] non-zero exit: $(grep FATAL "${WORK}/rbd.out" | head -1 | cut -c1-90)"; fi
grep -q "did not report success" "${WORK}/rbd.out" && ok "[readback-denied] a denied read is a DENIAL, not an empty role" || bad "[readback-denied] wrong reason: $(tail -1 "${WORK}/rbd.out")"

# ── [absent] ────────────────────────────────────────────────────────────────
jq 'del(."role:hugmesh/ROLE_GAMES_ADMIN")' "${WORK}/seed.json" > "${WORK}/seed-absent.json"
stub_up ok "${WORK}/seed-absent.json"
if run_script "${SCRIPT}" "${WORK}/absent.out"; then bad "[absent] exited 0 with no ROLE_GAMES_ADMIN in Casdoor"; else ok "[absent] non-zero exit"; fi
grep -q "ROLE_GAMES_ADMIN does not exist" "${WORK}/absent.out" && ok "[absent] names the missing role" || bad "[absent] wrong reason: $(tail -1 "${WORK}/absent.out")"
[ "$(journal_updates)" = "0" ] && ok "[absent] no write attempted" || bad "[absent] wrote into a role that is not there"

# ── NEGATIVE CONTROLS on the script itself (copies; disk untouched) ─────────
echo
echo "-- negative controls: a broken script must turn these checks red --"
mutate() { # <sed-expr> <copy-path>
  cp "${SCRIPT}" "$2"
  sed -i -e "$1" "$2"
  if cmp -s "${SCRIPT}" "$2"; then echo "FATAL: mutation '$1' did not change the copy" >&2; exit 1; fi
}
# A refused LOGIN is fatal three times over — the envelope check on /api/login,
# the get-account session proof, and (every later read being denied) the
# absent-role refusal — so no single cut can make deny-login pass, and the
# controls below say so rather than pretend one did. The envelope check is
# ISOLATED where it IS the sole guard: a denied WRITE (deny-writes: reads work,
# update-role answers HTTP 200 + status error) with the read-back cut.
ENVELOPE_CUT='s/if \[ "\${status}" != "ok" \]; then/if false; then/'
READBACK_CUT='s/^if \[ "\${verified}" != "\$(printf .%s. "\${qualified}" | jq -c .sort.)" \]; then$/if false; then/'
SESSION_CUT='s/^  \[ "\${name}" = "\${CASDOOR_ADMIN_USER}" \] \\$/  true \\/'

# (a) deny-login with the envelope check AND the session proof cut: the
#     absent-role refusal (a denied get-role is data:null) must still refuse.
mutate "${ENVELOPE_CUT}" "${WORK}/mut-login.sh"
cp "${WORK}/mut-login.sh" "${WORK}/mut-login.step1.sh"
sed -i -e "${SESSION_CUT}" "${WORK}/mut-login.sh"
if cmp -s "${WORK}/mut-login.step1.sh" "${WORK}/mut-login.sh"; then echo "FATAL: the session-proof mutation did not change the copy" >&2; exit 1; fi
stub_up deny-login "${WORK}/seed.json"
if run_script "${WORK}/mut-login.sh" "${WORK}/mut-login.out"; then
  bad "negative control: with the envelope check + session proof cut, a refused login passed — the absent-role layer is NOT catching it"
else
  ok "negative control: with the envelope check + session proof cut, a refused login is STILL fatal (third layer: $(grep FATAL "${WORK}/mut-login.out" | head -1 | cut -c32-80))"
fi
# (b) deny-writes with ONLY the read-back cut: the envelope check must be the
#     one that refuses, naming the denied call.
mutate "${READBACK_CUT}" "${WORK}/mut-readback.sh"
stub_up deny-writes "${WORK}/seed.json"
if run_script "${WORK}/mut-readback.sh" "${WORK}/mut-denywrite.out"; then
  bad "negative control: with the read-back cut, a DENIED write passed — the envelope check is not catching it"
else
  if grep -q "update-role.*did not report success" "${WORK}/mut-denywrite.out"; then
    ok "negative control: with the read-back cut, the envelope check alone refuses a denied write"
  else
    bad "negative control: a denied write was refused for the wrong reason: $(grep FATAL "${WORK}/mut-denywrite.out" | head -1 | cut -c1-90)"
  fi
fi
# (c) deny-writes with the read-back AND the envelope check cut: the denied
#     write must now be reported as success — proving (b) was the envelope
#     check and not something else.
cp "${WORK}/mut-readback.sh" "${WORK}/mut-both.sh"
sed -i -e "${ENVELOPE_CUT}" "${WORK}/mut-both.sh"
if cmp -s "${WORK}/mut-readback.sh" "${WORK}/mut-both.sh"; then echo "FATAL: the envelope mutation did not change the copy" >&2; exit 1; fi
stub_up deny-writes "${WORK}/seed.json"
if run_script "${WORK}/mut-both.sh" "${WORK}/mut-both.out"; then
  ok "negative control: with the read-back AND envelope check cut, a denied write is reported as success — both checks are load-bearing"
else
  bad "negative control: the double cut still failed (the control cannot distinguish): $(grep FATAL "${WORK}/mut-both.out" | head -1 | cut -c1-90)"
fi
# (d) read-back verification removed: writes-vanish reads as a successful reconcile
stub_up writes-vanish "${WORK}/seed.json"
if run_script "${WORK}/mut-readback.sh" "${WORK}/mut-readback.out"; then
  ok "negative control: WITHOUT the read-back a vanished write is reported as success — the read-back is load-bearing"
else
  bad "negative control: the read-back mutation still failed (the control cannot distinguish): $(grep FATAL "${WORK}/mut-readback.out" | head -1 | cut -c1-90)"
fi
stub_down

echo
echo "== derive-games-admin: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]

#!/usr/bin/env bash
# =============================================================================
# test-seed-password-reconcile.sh — a re-seeded stack must CONVERGE on the
# run-state password, and a seed that could not must say so and fail.
#
# WHY THIS EXISTS (measured 2026-08-27, on main WITH the generated-password
# contract merged). A `docker stop` + compose recreate keeps the casdoor-pg
# named volume, so Casdoor kept the 32 identities of the morning's seed — done
# from a checkout whose credentials file held a DIFFERENT password. The next
# `SEED_COMPLETE_REGISTRATION=1 make stack-seed` generated a fresh
# .e2e-credentials, the apply hook logged "user X exists" and SKIPPED all 32
# (nothing in the compose seed chain could change an existing password), the
# JWT pre-mint printed "password grant unavailable" for what was actually
# wrong-credentials, leg 1c logged 19/19 "onboard: login -> 401" under a line
# that still began "leg 1c OK", the target exited 0, and the Makefile banner
# advertised a password that provably could not log in — then STATICALLY hinted
# "Re-run with SEED_COMPLETE_REGISTRATION=1" although the flag WAS set.
#
# Four defects, four guards, all offline (stub Casdoor + stub front door, the
# same harness style as test-casdoor-init-honesty.sh; no stack, no docker —
# `docker` is a PATH shim because seed-e2e.sh preflights the binary):
#
#   1. RECONCILE: tests/qemu/seed-accounts.sh's rendered apply hook must make
#      an EXISTING Casdoor user's password the rendered (run-state) value and
#      PROVE it. Proof is behavioural, through the stub's OAuth password grant,
#      which validates against the same store /api/set-password writes: a token
#      for the NEW password after the run + invalid_grant for the OLD one is
#      convergence; asserting on log text alone would pass a hook that
#      "reconciles" to the wrong value. The re-run and the noop-write shapes
#      are pinned too (idempotence, and set-password lying — the hook must
#      fail rather than announce an unverifiable rotation).
#   2. ATTRIBUTION: a zero-mint pre-mint summary must blame invalid_grant on
#      the CREDENTIALS and unsupported_grant_type on the GRANT CONFIG — the
#      old fixed string pointed every zero-mint at the grant config.
#   3. LEG-1C HONESTY: tests/stack/seed-e2e.sh run for real against the stubs;
#      when EVERY attempted onboard fails the seed must exit non-zero and name
#      the credential-mismatch cause; a PARTIAL failure stays non-fatal but
#      must never print under an "OK" label.
#   4. THE HINT: `make -n stack-seed` (behaviour: make's real expansion, no
#      execution) must show the "Re-run with SEED_COMPLETE_REGISTRATION=1"
#      hint ONLY when the flag is absent — in BOTH spellings (command line and
#      environment) when present.
#
# Secret discipline: the apply hook must not print either fixture password on
# any of its paths (the visibility half of the contract lives in the Makefile
# banner, which prints the resolved value DELIBERATELY — so the sweep covers
# the hook scenarios, not `make -n`).
#
# Needs bash, curl, jq, python3, make. Binds 127.0.0.1 ephemeral ports only.
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STUB="${REPO}/tests/scripts/casdoor_stub.py"
SEED_ACCOUNTS="${REPO}/tests/qemu/seed-accounts.sh"
SEED_E2E="${REPO}/tests/stack/seed-e2e.sh"

for t in bash curl jq python3 make; do
    command -v "${t}" >/dev/null 2>&1 || { echo "  FAIL required tool missing: ${t}"; exit 2; }
done
for f in "${STUB}" "${SEED_ACCOUNTS}" "${SEED_E2E}" "${REPO}/Makefile"; do
    [ -f "${f}" ] || { echo "  FAIL missing: ${f}"; exit 2; }
done

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

WORK="$(mktemp -d)"
STUB_PID=""; FD_PID=""
cleanup() {
    [ -n "${STUB_PID}" ] && kill "${STUB_PID}" 2>/dev/null
    [ -n "${FD_PID}" ]   && kill "${FD_PID}" 2>/dev/null
    rm -rf "${WORK}"
}
trap cleanup EXIT

# Distinctive fixture passwords, greppable verbatim by the secret sweep. OLD is
# "what the persisted casdoor volume holds", NEW is "what this run's
# .e2e-credentials resolved" — the exact pair of the 2026-08-27 incident.
OLD_PW="fixture-stale-volume-pw-3c71"
NEW_PW="fixture-runstate-pw-9d42"
# Never let the suite read or write the checkout's real run-state file
# (asserting on ambient state is the contract's own documented trap): every
# invocation below pins E2E_CREDENTIALS_FILE to a path that does not exist and
# passes E2E_PASSWORD explicitly, which short-circuits generation.
NO_CREDS="${WORK}/never-created-credentials"

# ── stub lifecycles ──────────────────────────────────────────────────────────
stub_up() { # <mode> <oauth-mode> [store-seed.json]
    stub_down
    rm -f "${WORK}/port" "${WORK}/journal"
    STUB_MODE="$1" STUB_OAUTH="$2" STUB_ADMIN_PASSWORD=123 STUB_ADMIN_USER=admin \
        STUB_SEED="${3:-}" \
        STUB_PORT_FILE="${WORK}/port" STUB_JOURNAL="${WORK}/journal" \
        python3 "${STUB}" >"${WORK}/stub.log" 2>&1 &
    STUB_PID=$!
    local i
    for i in $(seq 1 100); do
        [ -s "${WORK}/port" ] && { CASDOOR="http://127.0.0.1:$(cat "${WORK}/port")"; return 0; }
        kill -0 "${STUB_PID}" 2>/dev/null || break
        sleep 0.1
    done
    bad "stub Casdoor (mode $1/$2) did not come up: $(cat "${WORK}/stub.log" 2>/dev/null)"
    return 1
}
stub_down() {
    [ -n "${STUB_PID}" ] && { kill "${STUB_PID}" 2>/dev/null; wait "${STUB_PID}" 2>/dev/null; }
    STUB_PID=""
}

# The front-door stub: just enough /bff surface for seed-e2e.sh leg 1c. It
# VALIDATES the login password against FD_EXPECT_PASSWORD, so the positive
# scenario proves the seeder really sends the resolved run-state value, and
# setting FD_EXPECT_PASSWORD to the stale volume password reproduces the
# incident's uniform 401s without faking anything else. FD_FAIL_USER (optional)
# 401s exactly one username, for the partial-failure shape.
cat > "${WORK}/fd_stub.py" <<'PYFD'
import json, os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
EXPECT = os.environ.get("FD_EXPECT_PASSWORD", "")
FAIL_USER = os.environ.get("FD_FAIL_USER", "")
PORT_FILE = os.environ["FD_PORT_FILE"]
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, fmt, *args):
        pass
    def _reply(self, code):
        body = b"{}"
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        self._reply(200)
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path == "/bff/login":
            try:
                body = json.loads(raw or b"{}")
            except ValueError:
                body = {}
            user = body.get("username") or ""
            pw = body.get("password") or ""
            if (FAIL_USER and user == FAIL_USER) or pw != EXPECT or not pw:
                return self._reply(401)
            return self._reply(200)
        if self.path.startswith("/bff/register/complete") or self.path.startswith("/bff/provision/"):
            return self._reply(200)
        return self._reply(200)
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
tmp = PORT_FILE + ".tmp"
with open(tmp, "w") as fh:
    fh.write(str(srv.server_address[1]))
os.replace(tmp, PORT_FILE)
srv.serve_forever()
PYFD

fd_up() { # <expected-password> [fail-user]
    fd_down
    rm -f "${WORK}/fd_port"
    FD_EXPECT_PASSWORD="$1" FD_FAIL_USER="${2:-}" FD_PORT_FILE="${WORK}/fd_port" \
        python3 "${WORK}/fd_stub.py" >"${WORK}/fd.log" 2>&1 &
    FD_PID=$!
    local i
    for i in $(seq 1 100); do
        [ -s "${WORK}/fd_port" ] && { FRONT="http://127.0.0.1:$(cat "${WORK}/fd_port")"; return 0; }
        kill -0 "${FD_PID}" 2>/dev/null || break
        sleep 0.1
    done
    bad "front-door stub did not come up: $(cat "${WORK}/fd.log" 2>/dev/null)"
    return 1
}
fd_down() {
    [ -n "${FD_PID}" ] && { kill "${FD_PID}" 2>/dev/null; wait "${FD_PID}" 2>/dev/null; }
    FD_PID=""
}

# seed-e2e.sh preflights `command -v docker` and shells out for container
# discovery; a shim that answers nothing keeps every docker-dependent leg on
# its documented "not in this stack" path without a daemon anywhere near this
# suite.
mkdir -p "${WORK}/bin"
printf '#!/bin/sh\nexit 0\n' > "${WORK}/bin/docker"
chmod +x "${WORK}/bin/docker"

# ── the reduced matrix the hook scenarios use (mechanism, not roster) ────────
MATRIX="e2e-admin:ROLE_ADMIN,ROLE_USER:E2E_ADMIN_PASSWORD \
e2e-user:ROLE_USER:E2E_USER_PASSWORD \
e2e-matrix:ROLE_MATRIX,ROLE_USER:E2E_MATRIX_PASSWORD"

render() { # <dir>
    SYSTEMS_ROLE_USERS="${MATRIX}" E2E_PASSWORD="${NEW_PW}" \
    E2E_CREDENTIALS_FILE="${NO_CREDS}" \
        bash "${SEED_ACCOUNTS}" --roles "$1" >/dev/null 2>&1
}

RENDER="${WORK}/render"
if render "${RENDER}" && [ -x "${RENDER}/roles/apply-systems-roles.sh" ]; then
    ok "(0) seed-accounts.sh --roles rendered the reduced matrix + apply hook offline"
else
    bad "(0) could not render the role matrix (seed-accounts.sh --roles) — nothing below can run"
    echo "== seed password reconcile: ${P} passed, ${F} failed =="
    exit 1
fi

# STUB_SEED builders. Roles come from the render itself (the hook hard-fails on
# a role Casdoor does not hold, exactly like production); users optionally
# pre-exist holding the STALE password.
seed_roles_only() { # <out.json>
    jq '{ } + ( [ .roles[] | {("role:" + .owner + "/" + .name): {owner:.owner, name:.name, users:[]}} ] | add // {} )' \
        "${RENDER}/roles/casdoor-systems-roles.json" > "$1"
}
seed_roles_and_stale_users() { # <out.json> <stale-password>
    jq --arg pw "$2" '
        ( [ .roles[] | {("role:" + .owner + "/" + .name): {owner:.owner, name:.name, users:[]}} ] | add // {} )
        + ( [ .users[] | {("user:" + .owner + "/" + .name):
              {owner:.owner, name:.name, displayName:.displayName, id:("pre-uuid-" + .name), password:$pw}} ] | add // {} )' \
        "${RENDER}/roles/casdoor-systems-roles.json" > "$1"
}

run_hook() { # <extra env assignments...> — output -> ${WORK}/out, rc -> ${RC}
    env "$@" \
        CASDOOR_URL="${CASDOOR}" CASDOOR_ADMIN_USER=admin CASDOOR_ADMIN_PASS=123 \
        CASDOOR_ORG=hugmesh \
        PREMINT_DIR="${WORK}/jwt-cache" PREMINT_APP=app-user-bff \
        PREMINT_CLIENT_SECRET=dev-app-user-bff-secret \
        timeout 120 bash "${RENDER}/roles/apply-systems-roles.sh" >"${WORK}/out" 2>&1
    RC=$?
    cat "${WORK}/out" >>"${WORK}/sweep"
    return 0
}

# mint <username> <password> -> 0 iff the stub's password grant returns a token.
# This is the CONVERGENCE ORACLE: the stub validates the grant against the same
# store set-password/add-user write, so a token is proof of what is stored —
# not of what a log line claimed.
mint() {
    curl -s "${CASDOOR}/api/login/oauth/access_token" \
        -H 'content-type: application/x-www-form-urlencoded' \
        --data-urlencode "grant_type=password" \
        --data-urlencode "username=hugmesh/$1" \
        --data-urlencode "password=$2" \
        --data-urlencode "client_id=app-user-bff" \
        --data-urlencode "client_secret=dev-app-user-bff-secret" 2>/dev/null \
      | jq -e '.access_token // empty | length > 0' >/dev/null 2>&1
}

: > "${WORK}/sweep"

# ═════ 1. THE RECREATED STACK: existing users must converge on the render ════
seed_roles_and_stale_users "${WORK}/seed-stale.json" "${OLD_PW}"
if stub_up ok ok "${WORK}/seed-stale.json"; then
    if mint e2e-admin "${OLD_PW}"; then
        ok "(1) fixture sanity: the pre-seeded 'volume' really holds the stale password"
    else
        bad "(1) fixture sanity: the stale-password pre-seed did not take — scenario 1 would prove nothing"
    fi
    run_hook
    [ "${RC}" -eq 0 ] \
        && ok "(1) apply hook exits 0 against a stack whose users pre-exist with a stale password" \
        || bad "(1) apply hook failed (rc=${RC}) against pre-existing users: $(tail -3 "${WORK}/out")"
    if mint e2e-admin "${NEW_PW}" && mint e2e-user "${NEW_PW}" && mint e2e-matrix "${NEW_PW}"; then
        ok "(1) CONVERGED: after the run, every pre-existing user's stored password IS the rendered value (password grant mints)"
    else
        bad "(1) NOT converged: the rendered password cannot mint after the run — the 2026-08-27 shape (skip-on-exists) is back"
    fi
    if mint e2e-admin "${OLD_PW}"; then
        bad "(1) the STALE password still mints after the run — the store was never rotated"
    else
        ok "(1) the stale password no longer authenticates"
    fi
    grep -q "password rotated" "${WORK}/out" \
        && ok "(1) the hook SAYS it rotated (\"password rotated\")" \
        || bad "(1) the hook never reported the rotation it performed"
    grep -Eq "3 password\(s\) reconciled" "${WORK}/out" \
        && ok "(1) the user summary counts the reconciled credentials" \
        || bad "(1) the user summary does not count reconciliation: $(grep '^\[apply-roles\] users:' "${WORK}/out" || echo '(no summary line)')"
    grep -q "pre-mint: 3 of 3" "${WORK}/out" \
        && ok "(1) pre-mint 3 of 3 — a second, independent surface agrees the credentials converged" \
        || bad "(1) pre-mint did not reach 3/3 after reconcile: $(grep 'pre-mint' "${WORK}/out" || echo '(no pre-mint line)')"

    # ═════ 2. IDEMPOTENT RE-RUN: already-current must be success, not failure ═
    # The same hook again, against the SAME stub state (everything now holds the
    # rendered value). Casdoor REFUSES to re-set an identical password, so a
    # reconciler that treats that refusal as an error breaks every normal
    # re-seed — the trap the two-call apply_password contract exists to dodge.
    run_hook
    [ "${RC}" -eq 0 ] \
        && ok "(2) re-run exits 0 when every password is already the rendered value" \
        || bad "(2) re-run failed (rc=${RC}) — the already-current refusal is being scored as an error: $(tail -3 "${WORK}/out")"
    grep -q "password already current" "${WORK}/out" \
        && ok "(2) re-run reports \"already current\", not a rotation" \
        || bad "(2) re-run does not report already-current"
    grep -Eq "0 password\(s\) reconciled" "${WORK}/out" \
        && ok "(2) re-run counts zero reconciliations" \
        || bad "(2) re-run summary wrong: $(grep '^\[apply-roles\] users:' "${WORK}/out" || echo '(no summary line)')"
fi

# ═════ 3. THE LYING WRITE: set-password reports ok, persists nothing ═════════
seed_roles_and_stale_users "${WORK}/seed-stale2.json" "${OLD_PW}"
if stub_up setpw-noop ok "${WORK}/seed-stale2.json"; then
    run_hook
    [ "${RC}" -ne 0 ] \
        && ok "(3) a set-password that persists nothing fails the hook (rc=${RC}) instead of announcing a reconcile" \
        || bad "(3) the hook exited 0 while the store still holds the stale password — an unverifiable rotation was announced"
    grep -q "did NOT persist" "${WORK}/out" \
        && ok "(3) ...and the failure names the noop-write shape" \
        || bad "(3) the failure does not say the write failed to persist: $(tail -3 "${WORK}/out")"
fi

# ═════ 3b. THE DROPPED CREATE: add-user says Affected, no credential lands ═══
# The add branch's apply_password call is DEFENSIVE — a well-behaved add-user
# stores the body's password itself — so in a world where every create lands
# the credential, deleting that proof changes nothing any scenario above can
# see (measured: exactly that mutation SURVIVED the suite's first cut). Here
# the create drops the password field; only the add branch's rotate-and-prove
# can make these accounts able to log in, so the proof is load-bearing and its
# deletion goes red. Same oracle as scenario 1: a mint, never a log line.
seed_roles_only "${WORK}/seed-roles-drop.json"
if stub_up adduser-droppw ok "${WORK}/seed-roles-drop.json"; then
    run_hook
    [ "${RC}" -eq 0 ] \
        && ok "(3b) apply hook exits 0 when add-user drops the password (the add-branch reconcile repairs it)" \
        || bad "(3b) apply hook failed (rc=${RC}) on the dropped-create shape: $(tail -3 "${WORK}/out")"
    if mint e2e-admin "${NEW_PW}" && mint e2e-user "${NEW_PW}" && mint e2e-matrix "${NEW_PW}"; then
        ok "(3b) every freshly-created user's stored credential IS the rendered value (the add-branch proof caught the drop)"
    else
        bad "(3b) a freshly-created user cannot mint with the rendered password — the add branch assumed the create landed the credential"
    fi
    grep -q "password rotated" "${WORK}/out" \
        && ok "(3b) ...and the add path reported the repair (\"password rotated\", not \"already current\")" \
        || bad "(3b) the add path did not report repairing the dropped credential: $(grep 'add-user' "${WORK}/out" | head -3)"
fi

# ═════ 4. ZERO-MINT ATTRIBUTION: grant config vs wrong credentials ═══════════
seed_roles_only "${WORK}/seed-roles.json"
if stub_up ok unsupported "${WORK}/seed-roles.json"; then
    run_hook
    [ "${RC}" -eq 0 ] \
        && ok "(4a) an absent password grant stays non-fatal (a legitimate deployment state)" \
        || bad "(4a) hook failed (rc=${RC}) on a disabled password grant: $(tail -3 "${WORK}/out")"
    grep -q "unsupported_grant_type" "${WORK}/out" && ! grep -q "invalid_grant" "${WORK}/out" \
        && ok "(4a) zero-mint on unsupported_grant_type blames the GRANT CONFIG" \
        || bad "(4a) wrong attribution for a disabled grant: $(grep 'pre-mint' "${WORK}/out" || echo '(no pre-mint line)')"
fi
if stub_up ok invalid "${WORK}/seed-roles.json"; then
    run_hook
    [ "${RC}" -eq 0 ] || bad "(4b) hook failed (rc=${RC}) where only the pre-mint should degrade: $(tail -3 "${WORK}/out")"
    if grep -q "invalid_grant" "${WORK}/out" \
       && grep -q "run-state file" "${WORK}/out" \
       && ! grep -q "password grant unavailable" "${WORK}/out"; then
        ok "(4b) zero-mint on invalid_grant blames the CREDENTIALS and points at the run-state file — never \"password grant unavailable\""
    else
        bad "(4b) invalid_grant zero-mint is misattributed: $(grep 'pre-mint' "${WORK}/out" || echo '(no pre-mint line)')"
    fi
fi
stub_down

# ═════ 5. LEG 1C HONESTY: the real seed-e2e.sh against both stubs ════════════
# seed-e2e.sh creates the org, the roles and the app itself, so the stub starts
# with an EMPTY store — the fresh-volume case — and ensure_org/ensure_roles/
# ensure_app are exercised end-to-end too. The apply hook inside it then runs
# against users it just created, and leg 1c logs in through the front-door stub
# with the resolved run-state password.
run_seed_e2e_fresh() { # <fd-expected-password> [fail-user] — out -> ${WORK}/seedout, rc -> ${RC}
    local expect="$1" failuser="${2:-}"
    stub_up ok ok || return 1
    fd_up "${expect}" "${failuser}" || return 1
    rm -rf "${WORK}/seedwork"
    # SKIP_OVERRIDE (optional, callers set it as a prefix assignment) feeds
    # SEED_REGISTRATION_SKIP; empty falls through to the seed's own default
    # (its `:-` expansion treats empty as unset), so only 5d ever changes it.
    PATH="${WORK}/bin:${PATH}" \
    E2E_PASSWORD="${NEW_PW}" E2E_CREDENTIALS_FILE="${NO_CREDS}" \
    CASDOOR_URL="${CASDOOR}" FRONT_DOOR="${FRONT}" \
    SEED_CASDOOR_ONLY=1 SEED_COMPLETE_REGISTRATION=1 SEED_WAIT_S=10 \
    SEED_REGISTRATION_SKIP="${SKIP_OVERRIDE:-}" \
    SEED_WORKDIR="${WORK}/seedwork" \
        timeout 300 bash "${SEED_E2E}" >"${WORK}/seedout" 2>&1
    RC=$?
    fd_down
    return 0
}

# (5c) POSITIVE CONTROL FIRST: the front door accepts the run-state password →
# the whole seed passes and leg 1c reports OK. Without this, 5a/5b could pass
# on a seed that dies for an unrelated reason before leg 1c.
if run_seed_e2e_fresh "${NEW_PW}"; then
    [ "${RC}" -eq 0 ] \
        && ok "(5c) control: full offline seed run exits 0 when the front door accepts the resolved password" \
        || bad "(5c) control: the offline seed run failed (rc=${RC}) — 5a/5b below cannot be trusted: $(tail -5 "${WORK}/seedout")"
    grep -q "leg 1c OK" "${WORK}/seedout" \
        && ok "(5c) control: leg 1c reports OK with zero failures" \
        || bad "(5c) control: no 'leg 1c OK' on the happy path"
fi

# (5a) THE INCIDENT: the front door only accepts the STALE password (the
# recreated stack's Casdoor), so every onboard login 401s.
if run_seed_e2e_fresh "${OLD_PW}"; then
    [ "${RC}" -ne 0 ] \
        && ok "(5a) all-attempted-onboards-failed makes the seed exit non-zero (rc=${RC}) instead of 0" \
        || bad "(5a) 19x-401 shape STILL exits 0 — the banner after it would advertise a password that cannot log in"
    grep -q "leg 1c FAILED: all" "${WORK}/seedout" \
        && ok "(5a) ...and says plainly that ALL attempted onboards failed" \
        || bad "(5a) no unmistakable leg-1c failure line: $(grep -E 'leg 1c' "${WORK}/seedout" | tail -2 || echo '(none)')"
    grep -q "e2e-password.sh" "${WORK}/seedout" \
        && ok "(5a) ...and names the credential-mismatch cause (e2e-password.sh / run-state)" \
        || bad "(5a) the failure does not point at the password-contract mismatch"
    grep -q "leg 1c OK" "${WORK}/seedout" \
        && bad "(5a) 'leg 1c OK' still printed on a total failure" \
        || ok "(5a) no 'OK' label anywhere near the failure"
fi

# (5b) PARTIAL: one persona 401s, the rest onboard → non-fatal, but labelled
# PARTIAL, never OK.
if run_seed_e2e_fresh "${NEW_PW}" "e2e-admin"; then
    [ "${RC}" -eq 0 ] \
        && ok "(5b) a partial onboard failure stays non-fatal (identities are seeded; the operator can finish in the UI)" \
        || bad "(5b) a single failed persona now kills the whole seed (rc=${RC}) — over-correction: $(tail -3 "${WORK}/seedout")"
    grep -q "leg 1c PARTIAL" "${WORK}/seedout" && ! grep -q "leg 1c OK" "${WORK}/seedout" \
        && ok "(5b) ...and is labelled PARTIAL, not OK" \
        || bad "(5b) partial failure mislabelled: $(grep -E 'leg 1c (OK|PARTIAL)' "${WORK}/seedout" | tail -1 || echo '(no label)')"
fi

# (5d) ALL-GATED: every persona deliberately gated → ZERO attempted onboards,
# and zero attempted is NOT zero succeeded. The total-failure exit must demand
# an actual failed attempt (reg_fail>0), or a legitimately all-gated seed dies
# spuriously — the ungated edge of the same honesty rule 5a pins. The roster
# is derived from the seed's OWN render (the last run's workdir), never a
# second copy of the table; email-shaped fixtures are gated by shape anyway.
# The front door only accepts the STALE password here on purpose: if gating
# ever stopped short-circuiting before the login, every persona would 401 and
# this scenario would go red on that regression too.
ROSTER="$(jq -r '[.users[].name | select(contains("@") | not)] | join(" ")' \
            "${WORK}/seedwork/roles-render/roles/casdoor-systems-roles.json" 2>/dev/null || true)"
if [ -n "${ROSTER}" ]; then
    ok "(5d) fixture: derived the full persona roster from the seed's own render ($(echo ${ROSTER} | wc -w) name(s))"
else
    bad "(5d) could not derive the persona roster from ${WORK}/seedwork — the all-gated edge cannot be exercised"
fi
if [ -n "${ROSTER}" ] && SKIP_OVERRIDE="${ROSTER}" run_seed_e2e_fresh "${OLD_PW}"; then
    [ "${RC}" -eq 0 ] \
        && ok "(5d) an all-gated run (0 attempted, 0 failed) exits 0 — zero attempts is not a total failure" \
        || bad "(5d) an all-gated run exits ${RC} — the total-failure exit fires on ZERO attempts (spurious fatal): $(tail -3 "${WORK}/seedout")"
    grep -q "leg 1c OK: 0 onboarded" "${WORK}/seedout" \
        && ok "(5d) ...and reports 'leg 1c OK: 0 onboarded' with every persona left gated" \
        || bad "(5d) all-gated run mislabelled: $(grep -E 'leg 1c' "${WORK}/seedout" | tail -1 || echo '(no leg 1c line)')"
    grep -q "leg 1c FAILED" "${WORK}/seedout" \
        && bad "(5d) 'leg 1c FAILED' printed on a run that attempted nothing" \
        || ok "(5d) no failure banner on the all-gated run"
fi
stub_down

# ═════ 6. THE MAKEFILE HINT: printed only when the flag is really absent ═════
# `make -n` is make's REAL expansion of the recipe with nothing executed, so
# which variant appears is behaviour, not source text. The losing variant is
# absent from the expansion entirely (parse-time ifeq), which is what makes
# this assertable.
HINT="Re-run with SEED_COMPLETE_REGISTRATION=1"
STAGE2="Registration STAGE 2 ran in this seed"
m6a="$(cd "${REPO}" && timeout 60 make -n stack-seed 2>/dev/null)"
if printf '%s' "${m6a}" | grep -F "${HINT}" >/dev/null && ! printf '%s' "${m6a}" | grep -F "${STAGE2}" >/dev/null; then
    ok "(6a) without the flag, stack-seed ends with the re-run hint (and no stage-2 note)"
else
    bad "(6a) flag-absent variant wrong (hint missing, or stage-2 note leaking in)"
fi
m6b="$(cd "${REPO}" && timeout 60 make -n stack-seed SEED_COMPLETE_REGISTRATION=1 2>/dev/null)"
if ! printf '%s' "${m6b}" | grep -F "${HINT}" >/dev/null && printf '%s' "${m6b}" | grep -F "${STAGE2}" >/dev/null; then
    ok "(6b) with the flag on the COMMAND LINE, the re-run hint is gone and the stage-2 note is live"
else
    bad "(6b) the hint still prints when SEED_COMPLETE_REGISTRATION=1 is passed on the command line — the 2026-08-27 static-echo shape"
fi
m6c="$(cd "${REPO}" && SEED_COMPLETE_REGISTRATION=1 timeout 60 make -n stack-seed 2>/dev/null)"
if ! printf '%s' "${m6c}" | grep -F "${HINT}" >/dev/null && printf '%s' "${m6c}" | grep -F "${STAGE2}" >/dev/null; then
    ok "(6c) ...and the ENVIRONMENT spelling flips it identically"
else
    bad "(6c) the environment spelling does not flip the hint — only the command-line one does"
fi

# ═════ 7. SECRET SWEEP over every apply-hook path exercised above ════════════
if grep -qF "${OLD_PW}" "${WORK}/sweep" || grep -qF "${NEW_PW}" "${WORK}/sweep"; then
    bad "(7) a fixture password reached the apply hook's stdout/stderr"
else
    ok "(7) $(grep -c '' "${WORK}/sweep") captured hook output line(s), no password among them"
fi

echo
echo "== seed password reconcile: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

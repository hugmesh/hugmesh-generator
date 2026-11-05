#!/usr/bin/env bash
# test-seed-e2e-lockout.sh — tests/stack/seed-e2e.sh leg 1c names a Casdoor
# sign-in LOCKOUT, never retries a throttled account, and STOPS the seed on any
# FAILED onboard (hugmesh/hugmesh-generator#473, boxes 2 and 4, seed side).
#
# WHY. Casdoor bans an account after a handful of wrong passwords and then
# refuses EVERY login, the correct password included, with its i18n text
# "...entered the wrong password or code too many times, please wait for %d
# minutes...". user-bff relays that as 401 {"error":"invalid_credentials",
# "message":"<that text>"} — the SAME status a wrong password gets. The seeder
# used to read only the status, so a throttled account was reported as a
# wrong-password 401 whose documented remedy (re-seed, rotate E2E_PASSWORD) is
# exactly the wrong move inside the ban window. And a `leg 1c PARTIAL ... FAILED`
# used to exit 0, so `make stack-e2e` carried on against a half-seeded stack and
# the un-onboarded personas failed their specs far from the cause.
#
# HOW. The REAL seed-e2e.sh is run, end to end, against:
#   * tests/scripts/casdoor_stub.py in `ok` mode (leg 1 creates the org, roles,
#     app and personas for real, as test-seed-password-reconcile.sh does), and
#   * a `curl` SHIM first on PATH that intercepts only URLs under FRONT_DOOR —
#     `/` for the preflight, POST /bff/login answered per-username from a
#     scripted table (default: 200 when the password is the run's E2E_PASSWORD),
#     /bff/register/complete and /bff/provision/* -> 200 — journals every login
#     with its username, and exec's the real curl for everything else (every
#     Casdoor call). FRONT_DOOR is an unresolvable host, so a request the shim
#     fails to intercept is a loud 000, never a quiet pass.
#   * `docker` is a PATH shim (the seed preflights the binary; the social legs
#     are skipped with SEED_CASDOOR_ONLY=1, which still runs leg 1c).
#
# WHAT IS ASSERTED
#   [control]   every login 200 -> exit 0, "leg 1c OK", no LOCKOUT, no PARTIAL.
#   [lockout]   ONE persona answers 401 + the throttle text -> a LOCKOUT line
#               names it, says the account is throttled and the password must
#               NOT be rotated; the journal holds EXACTLY ONE login for it even
#               though the roster lists it twice (LOCAL_OPERATOR_USER is set to
#               the same handle, so leg 1c walks it a second time: the latch
#               refuses the second attempt and says so); the run is PARTIAL and
#               exits non-zero.
#   [wrong-pw]  the same persona answers 401 + "invalid credentials" -> NO
#               LOCKOUT line (a wrong password is not a lockout), the ordinary
#               "onboard: login for <u> -> 401" WARN, PARTIAL, non-zero exit.
#   [stop]      a PARTIAL ... FAILED leg exits 4 (distinct from the uniform-
#               failure 3), prints the stop line, and the seed does NOT reach
#               its SEED_CASDOOR_ONLY completion line.
#   [all-locked] EVERY login refused with the throttle text -> the total-failure
#               branch (exit 3) carries the do-NOT-rotate bullet.
#   [secrets]   the run password never appears in any captured output.
#
# NEGATIVE CONTROLS on the SEEDER (break production, see red, restore — on a
# COPY in a mirrored tree; the file on disk is never modified). Each mutated
# copy is PROVEN to differ from the original before it is run:
#   [mut-classifier] with the lockout marker unmatchable, the [lockout] run
#               prints no LOCKOUT line and the journal shows the second login.
#   [mut-exit]  with the PARTIAL exit removed, the [wrong-pw] run exits 0 and
#               reaches the completion line.
#
# Offline: bash, curl, jq, python3 (stdlib), coreutils timeout. The stub binds
# 127.0.0.1 on an ephemeral port; no stack, no docker daemon, no egress.
# shellcheck disable=SC2015  # A && ok || bad is the assertion idiom this repo's guards use.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
SEED_E2E="${HERE}/seed-e2e.sh"
STUB="${REPO}/tests/scripts/casdoor_stub.py"

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

for t in bash curl jq python3 timeout; do
  command -v "$t" >/dev/null 2>&1 || { echo "FATAL: $t required (refusing to skip)" >&2; exit 1; }
done
[ -r "${SEED_E2E}" ] || { echo "FATAL: cannot read ${SEED_E2E}" >&2; exit 1; }
[ -r "${STUB}" ]     || { echo "FATAL: cannot read ${STUB}" >&2; exit 1; }
REAL_CURL="$(command -v curl)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-seed-e2e-lockout.XXXXXX")"
STUB_PID=""
stub_down() { if [ -n "${STUB_PID}" ]; then kill "${STUB_PID}" 2>/dev/null; wait "${STUB_PID}" 2>/dev/null; STUB_PID=""; fi; }
trap 'stub_down; rm -rf "${WORK}"' EXIT

# A password unlike any default, greppable verbatim by the secret sweep.
PW="fixture-lockout-run-pw-5e1a-never-printed"
# Never read or write the checkout's real run-state file.
NO_CREDS="${WORK}/never-created-credentials"
# Unresolvable on purpose: anything the shim does not intercept dies loudly.
FD="http://front-door.shim.invalid"

# Casdoor's throttle text as user-bff relays it (tests/e2e/specs/helpers.ts
# describeLoginFailure; manifests/casdoor/init-job.yaml LOCKOUT_MARKER).
LOCK_BODY='{"error":"invalid_credentials","message":"You have entered the wrong password or code too many times, please wait for 15 minutes and try again"}'
WRONG_BODY='{"error":"invalid_credentials","message":"invalid credentials"}'

# ── the stub Casdoor (leg 1 runs for real against it) ────────────────────────
stub_up() {
  stub_down
  rm -f "${WORK}/port"
  STUB_MODE=ok STUB_OAUTH=ok STUB_ADMIN_PASSWORD=123 STUB_ADMIN_USER=admin \
  STUB_PORT_FILE="${WORK}/port" STUB_JOURNAL="${WORK}/casdoor.journal" \
    python3 "${STUB}" >"${WORK}/stub.log" 2>&1 &
  STUB_PID=$!
  local i
  for i in $(seq 1 100); do
    [ -s "${WORK}/port" ] && { CASDOOR="http://127.0.0.1:$(cat "${WORK}/port")"; return 0; }
    kill -0 "${STUB_PID}" 2>/dev/null || break
    sleep 0.1
  done
  bad "stub Casdoor did not come up: $(cat "${WORK}/stub.log" 2>/dev/null)"
  return 1
}

# ── the PATH shims ───────────────────────────────────────────────────────────
mkdir -p "${WORK}/bin"
printf '#!/bin/sh\nexit 0\n' > "${WORK}/bin/docker"
chmod +x "${WORK}/bin/docker"

# The curl shim. Reads SHIM_* from the environment seed-e2e.sh inherits:
#   SHIM_REAL_CURL    the curl to exec for every non-front-door URL
#   SHIM_FRONT_DOOR   the URL prefix to intercept
#   SHIM_JOURNAL      one "METHOD path username" line per intercepted request
#   SHIM_TABLE        TSV "username<TAB>code<TAB>body": a scripted login answer
#   SHIM_EXPECT_PASSWORD  the password that logs in when the table is silent
#   SHIM_LOCK_ALL=1   every login is refused with the throttle text
# Honours -o <file>, -w <fmt> (%{http_code}), -d <data>, -X <method>; every
# other option is skipped exactly as curl would consume it.
cat > "${WORK}/bin/curl" <<'SHIM'
#!/usr/bin/env bash
set -u
args=("$@"); url=""; out=""; wfmt=""; data=""; method="GET"; i=0
while [ "${i}" -lt "${#args[@]}" ]; do
  a="${args[$i]}"
  case "${a}" in
    -o) i=$((i+1)); out="${args[$i]}" ;;
    -w) i=$((i+1)); wfmt="${args[$i]}" ;;
    -d|--data|--data-raw|--data-binary) i=$((i+1)); data="${args[$i]}"; method="POST" ;;
    -X) i=$((i+1)); method="${args[$i]}" ;;
    -H|-c|-b|-u|--max-time|--connect-timeout|--retry|--cacert|--resolve) i=$((i+1)) ;;
    -*) ;;
    *) url="${a}" ;;
  esac
  i=$((i+1))
done
case "${url}" in "${SHIM_FRONT_DOOR}"*) ;; *) exec "${SHIM_REAL_CURL}" "$@" ;; esac
path="${url#"${SHIM_FRONT_DOOR}"}"
code=200; body='{}'
case "${path}" in
  /bff/login)
    user="$(printf '%s' "${data}" | jq -r '.username // ""' 2>/dev/null || true)"
    pw="$(printf '%s' "${data}" | jq -r '.password // ""' 2>/dev/null || true)"
    printf '%s %s %s\n' "${method}" "${path}" "${user}" >> "${SHIM_JOURNAL}"
    line=""
    [ -n "${SHIM_TABLE:-}" ] && [ -r "${SHIM_TABLE}" ] \
      && line="$(awk -F'\t' -v u="${user}" '$1==u {print; exit}' "${SHIM_TABLE}")"
    if [ "${SHIM_LOCK_ALL:-0}" = "1" ]; then
      code=401; body="${SHIM_LOCK_BODY}"
    elif [ -n "${line}" ]; then
      code="$(printf '%s\n' "${line}" | cut -f2)"; body="$(printf '%s\n' "${line}" | cut -f3-)"
    elif [ -z "${pw}" ] || [ "${pw}" != "${SHIM_EXPECT_PASSWORD}" ]; then
      code=401; body='{"error":"invalid_credentials","message":"invalid credentials"}'
    fi ;;
  /bff/register/complete|/bff/provision/*)
    printf '%s %s -\n' "${method}" "${path}" >> "${SHIM_JOURNAL}" ;;
  ""|/) ;;
  *) code=404; body='{"error":"shim: unmodelled front-door path"}' ;;
esac
if [ -n "${out}" ]; then printf '%s' "${body}" > "${out}"; else printf '%s' "${body}"; fi
[ -z "${wfmt}" ] || printf '%s' "${wfmt//%\{http_code\}/${code}}"
exit 0
SHIM
chmod +x "${WORK}/bin/curl"

# Sanity: the shim really answers a front-door login and really delegates the rest.
probe_out="$(SHIM_REAL_CURL="${REAL_CURL}" SHIM_FRONT_DOOR="${FD}" SHIM_JOURNAL="${WORK}/probe.journal" \
             SHIM_TABLE="" SHIM_EXPECT_PASSWORD="x" SHIM_LOCK_BODY="${LOCK_BODY}" \
             "${WORK}/bin/curl" -s -o "${WORK}/probe.body" -w '%{http_code}' -X POST "${FD}/bff/login" \
               -H 'content-type: application/json' -d '{"username":"probe","password":"x"}')"
[ "${probe_out}" = "200" ] && [ "$(cat "${WORK}/probe.journal")" = "POST /bff/login probe" ] \
  && ok "[shim] the curl shim answers a front-door login and journals it" \
  || bad "[shim] the curl shim did not answer/journal a front-door login (code='${probe_out}')"
probe_real="$(SHIM_REAL_CURL="${REAL_CURL}" SHIM_FRONT_DOOR="${FD}" SHIM_JOURNAL="${WORK}/probe.journal" \
              "${WORK}/bin/curl" --version 2>/dev/null | head -1)"
case "${probe_real}" in curl\ *) ok "[shim] non-front-door invocations reach the real curl" ;;
  *) bad "[shim] the shim swallowed a non-front-door invocation: '${probe_real}'" ;; esac

# ── running the seed ─────────────────────────────────────────────────────────
# run_seed <seed-script> <table-file-or-empty> [VAR=value ...]
# -> ${OUT} (combined output), ${JOURNAL}, ${RC}
run_seed() {
  local script="$1" table="$2"; shift 2
  stub_up || return 1
  OUT="${WORK}/seedout"; JOURNAL="${WORK}/fd.journal"
  : > "${JOURNAL}"; rm -rf "${WORK}/seedwork"
  env PATH="${WORK}/bin:${PATH}" \
    SHIM_REAL_CURL="${REAL_CURL}" SHIM_FRONT_DOOR="${FD}" SHIM_JOURNAL="${JOURNAL}" \
    SHIM_TABLE="${table}" SHIM_EXPECT_PASSWORD="${PW}" SHIM_LOCK_BODY="${LOCK_BODY}" \
    E2E_PASSWORD="${PW}" E2E_CREDENTIALS_FILE="${NO_CREDS}" \
    CASDOOR_URL="${CASDOOR}" FRONT_DOOR="${FD}" \
    SEED_CASDOOR_ONLY=1 SEED_COMPLETE_REGISTRATION=1 SEED_WAIT_S=10 \
    SEED_WORKDIR="${WORK}/seedwork" \
    "$@" timeout 300 bash "${script}" >"${OUT}" 2>&1
  RC=$?
  stub_down
  return 0
}
logins_for() { grep -c "^POST /bff/login $1\$" "${JOURNAL}" || true; }
has()  { grep -F -q -- "$1" "${OUT}"; }
# The duplicate-walk roster: the local-operator persona IS e2e-user, so leg 1c's
# loop reaches e2e-user twice (the base matrix and the operator extra). Harmless
# for the render (same handle, same password) and the only way to make the
# seeder attempt a second login for one account without touching its roster.
DUP=(LOCAL_OPERATOR_USER=e2e-user LOCAL_OPERATOR_ROLES=ROLE_USER)
COMPLETION_LINE="SEED_CASDOOR_ONLY=1 — Casdoor identity seeded"

# ═════ [control] every login 200 ═════════════════════════════════════════════
if run_seed "${SEED_E2E}" "" "${DUP[@]}"; then
  [ "${RC}" -eq 0 ] \
    && ok "[control] the offline seed exits 0 when every login is accepted (rc=0)" \
    || bad "[control] the offline seed failed (rc=${RC}) — the red cases below cannot be trusted: $(tail -5 "${OUT}")"
  has "leg 1c OK" && ! has "LOCKOUT: " && ! has "leg 1c PARTIAL" \
    && ok "[control] leg 1c OK, no LOCKOUT, no PARTIAL" \
    || bad "[control] unexpected leg 1c labels: $(grep -E 'leg 1c|LOCKOUT' "${OUT}" | tail -3)"
  [ "$(logins_for e2e-user)" = "2" ] \
    && ok "[control] fixture: the roster walks e2e-user twice (2 logins journaled)" \
    || bad "[control] fixture: expected 2 journaled logins for e2e-user, got $(logins_for e2e-user) — the latch case below could not distinguish a retry"
  has "${COMPLETION_LINE}" \
    && ok "[control] the seed reached its completion line" \
    || bad "[control] no completion line"
fi

# ═════ [lockout] one persona throttled ═══════════════════════════════════════
printf 'e2e-user\t401\t%s\n' "${LOCK_BODY}" > "${WORK}/table.lock"
if run_seed "${SEED_E2E}" "${WORK}/table.lock" "${DUP[@]}"; then
  has "LOCKOUT: e2e-user" \
    && ok "[lockout] a LOCKOUT line names the throttled persona" \
    || bad "[lockout] no 'LOCKOUT: e2e-user' line: $(grep -E 'e2e-user' "${OUT}" | head -3)"
  has "throttled" && has "must NOT be rotated" \
    && ok "[lockout] ...says the account is throttled and the password must NOT be rotated" \
    || bad "[lockout] the LOCKOUT line does not say throttled / must NOT be rotated: $(grep LOCKOUT "${OUT}" | head -1)"
  n="$(logins_for e2e-user)"
  [ "${n}" = "1" ] \
    && ok "[lockout] exactly ONE login attempt for e2e-user although the roster walks it twice (latched, no retry)" \
    || bad "[lockout] ${n} login attempt(s) for e2e-user — a throttled account was retried"
  has "not attempting another login" \
    && ok "[lockout] ...and the second walk says it was refused by the latch" \
    || bad "[lockout] no latch message on the second walk"
  [ "${RC}" -ne 0 ] \
    && ok "[lockout] the seed exits non-zero (rc=${RC})" \
    || bad "[lockout] the seed exited 0 with a throttled persona"
  has "leg 1c PARTIAL" && ! has "leg 1c OK" \
    && ok "[lockout] the leg is labelled PARTIAL, not OK" \
    || bad "[lockout] mislabelled: $(grep -E 'leg 1c' "${OUT}" | tail -1)"
  [ "$(logins_for e2e-admin)" = "1" ] \
    && ok "[lockout] other personas still attempted exactly once (e2e-admin)" \
    || bad "[lockout] e2e-admin logins: $(logins_for e2e-admin)"
fi

# ═════ [wrong-pw] a wrong-password 401 is NOT a lockout ══════════════════════
printf 'e2e-user\t401\t%s\n' "${WRONG_BODY}" > "${WORK}/table.wrong"
if run_seed "${SEED_E2E}" "${WORK}/table.wrong" "${DUP[@]}"; then
  ! has "LOCKOUT: " \
    && ok "[wrong-pw] no LOCKOUT line for a plain invalid_credentials 401" \
    || bad "[wrong-pw] a wrong password was classified as a lockout: $(grep LOCKOUT "${OUT}" | head -1)"
  has "onboard: login for e2e-user -> 401" \
    && ok "[wrong-pw] the ordinary status-coded WARN is printed instead" \
    || bad "[wrong-pw] no 'onboard: login for e2e-user -> 401' line"
  [ "$(logins_for e2e-user)" = "2" ] \
    && ok "[wrong-pw] no latch: the second walk attempts the login again (2 journaled)" \
    || bad "[wrong-pw] e2e-user logins: $(logins_for e2e-user) (a wrong password must not latch)"
  # ═════ [stop] a PARTIAL ... FAILED leg stops the seed ══════════════════════
  has "leg 1c PARTIAL" && has "FAILED" \
    && ok "[stop] the leg reports PARTIAL ... FAILED" \
    || bad "[stop] no PARTIAL ... FAILED line: $(grep -E 'leg 1c' "${OUT}" | tail -1)"
  [ "${RC}" -eq 4 ] \
    && ok "[stop] the seed exits 4 (PARTIAL stop; distinct from the uniform-failure 3)" \
    || bad "[stop] rc=${RC}, expected 4: $(tail -3 "${OUT}")"
  has "leg 1c PARTIAL FAILED" && has "half-seeded" \
    && ok "[stop] ...and says it stopped rather than continue against a half-seeded stack" \
    || bad "[stop] no stop line naming the half-seeded stack"
  ! has "${COMPLETION_LINE}" \
    && ok "[stop] the completion line was never reached" \
    || bad "[stop] the seed printed its completion line after a PARTIAL FAILED leg"
fi

# ═════ [all-locked] every login throttled -> total failure names the lockout ═
if run_seed "${SEED_E2E}" "" SHIM_LOCK_ALL=1; then
  [ "${RC}" -eq 3 ] \
    && ok "[all-locked] the uniform-failure exit (3) fires when every login is throttled" \
    || bad "[all-locked] rc=${RC}, expected 3"
  has "leg 1c FAILED: all" && has "LOCKOUT lines above" && has "do NOT rotate" \
    && ok "[all-locked] ...and its diagnosis carries the do-NOT-rotate bullet" \
    || bad "[all-locked] the total-failure diagnosis does not mention the lockouts: $(grep -E 'LOCKOUT lines|rotate' "${OUT}" | head -2)"
  n="$(grep -c '^POST /bff/login ' "${JOURNAL}" || true)"
  m="$(grep -c 'LOCKOUT: ' "${OUT}" || true)"
  [ "${n}" -gt 0 ] && [ "${n}" = "${m}" ] \
    && ok "[all-locked] one LOCKOUT line per attempted login (${n}), none retried" \
    || bad "[all-locked] ${n} login(s) journaled vs ${m} LOCKOUT line(s)"
fi

# ═════ [secrets] ═════════════════════════════════════════════════════════════
if grep -rqF -- "${PW}" "${WORK}/seedout" "${WORK}/fd.journal" 2>/dev/null; then
  bad "[secrets] the run password appeared in the captured output"
else
  ok "[secrets] the run password never appears in the captured output"
fi

# ═════ NEGATIVE CONTROLS: break the seeder on a COPY, demand red ═════════════
# seed-e2e.sh locates its helpers relative to itself (e2e-password.sh,
# derive-games-admin.sh, ../qemu/seed-accounts.sh, ../e2e-extra-personas.sh), so
# a mutated copy lives in a mirrored tree whose other files are symlinks.
MUT="${WORK}/mut"
mkdir -p "${MUT}/tests/stack"
for f in "${HERE}"/*; do
  [ "$(basename "${f}")" = "seed-e2e.sh" ] && continue
  ln -s "${f}" "${MUT}/tests/stack/$(basename "${f}")"
done
ln -s "${REPO}/tests/qemu" "${MUT}/tests/qemu"
ln -s "${REPO}/tests/e2e-extra-personas.sh" "${MUT}/tests/e2e-extra-personas.sh"
MUT_SEED="${MUT}/tests/stack/seed-e2e.sh"

mutate() { # <old> <new> -> writes ${MUT_SEED}; fails unless old occurs exactly once and the copy differs
  OLD="$1" NEW="$2" python3 - "${SEED_E2E}" "${MUT_SEED}" <<'PY' || return 1
import os, sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding='utf-8').read()
old, new = os.environ['OLD'], os.environ['NEW']
if s.count(old) != 1:
    sys.exit(1)
open(dst, 'w', encoding='utf-8').write(s.replace(old, new))
PY
  ! cmp -s "${SEED_E2E}" "${MUT_SEED}"
}

# [mut-classifier]: the marker can never match -> the lockout body is a plain 401.
if mutate 'CASDOOR_LOCKOUT_MARKER="too many times"' 'CASDOOR_LOCKOUT_MARKER="never-matches-any-body"'; then
  ok "[mut-classifier] mutated copy differs from production (classifier disabled)"
  if run_seed "${MUT_SEED}" "${WORK}/table.lock" "${DUP[@]}"; then
    ! has "LOCKOUT: e2e-user" && [ "$(logins_for e2e-user)" = "2" ] \
      && ok "[mut-classifier] without the classifier the lockout is unnamed and e2e-user is RETRIED — the [lockout] assertions catch this" \
      || bad "[mut-classifier] the mutated seeder still classified/latched (LOCKOUT: $(grep -c 'LOCKOUT: e2e-user' "${OUT}" || true), logins: $(logins_for e2e-user)) — the test is not pinning the classifier"
  fi
else
  bad "[mut-classifier] could not apply the mutation (marker definition not found exactly once)"
fi

# [mut-exit]: the PARTIAL stop removed -> the seed carries on and exits 0.
if mutate '    exit 4  # PARTIAL-FAILED-STOP' '    :  # PARTIAL-FAILED-STOP removed'; then
  ok "[mut-exit] mutated copy differs from production (PARTIAL exit removed)"
  if run_seed "${MUT_SEED}" "${WORK}/table.wrong" "${DUP[@]}"; then
    [ "${RC}" -eq 0 ] && has "${COMPLETION_LINE}" \
      && ok "[mut-exit] without the exit a PARTIAL FAILED leg runs to completion with rc=0 — the [stop] assertions catch this" \
      || bad "[mut-exit] the mutated seeder still stopped (rc=${RC}) — the test is not pinning the exit"
  fi
else
  bad "[mut-exit] could not apply the mutation (PARTIAL exit line not found exactly once)"
fi

echo
echo "== seed-e2e lockout + partial-stop: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]

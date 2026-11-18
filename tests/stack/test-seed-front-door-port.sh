#!/usr/bin/env bash
# =============================================================================
# test-seed-front-door-port.sh — tests/stack/seed-e2e.sh must look for the front door on
# the port the stack was STARTED on, not always on 8088.
#
# WHAT HAPPENED (2026-11-18). `make stack-up PUBLIC_HOST_PORT=18088 …` publishes the door on
# 18088, and `make stack-seed` prints "open http://localhost:$(PUBLIC_HOST_PORT)/login"
# from the same variable — but seed-e2e.sh took FRONT_DOOR from its own default,
# http://localhost:8088, and waited the full 180 s for a door that was never there
# ("front door http://localhost:8088/ is not answering ... bring the stack up first").
# The Studio never hit it because it sets FRONT_DOOR itself (images_mesh.py); a person
# running a second stack by hand did.
#
# WHAT THIS PINS: the FRONT_DOOR assignment, taken out of the real script and evaluated
#   (1) with nothing set                          -> http://localhost:8088
#   (2) with PUBLIC_HOST_PORT=18088               -> http://localhost:18088
#   (3) with FRONT_DOOR set, and a port as well   -> FRONT_DOOR wins, untouched
# It must find exactly ONE such assignment (a file that lost it, or grew a second, is a
# FAIL, not a pass). NEGATIVE CONTROL: SEED_FILE=<another copy> checks that copy instead;
# origin/main before this change is RED on case 2.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILE="${SEED_FILE:-${HERE}/seed-e2e.sh}"
P=0; F=0
ok()  { P=$((P+1)); echo "  PASS $*"; }
bad() { F=$((F+1)); echo "  FAIL $*"; }

[ -f "${FILE}" ] || { echo "  FAIL ${FILE} is not a file"; exit 2; }
lines="$(grep -E '^FRONT_DOOR="\$\{FRONT_DOOR:-' "${FILE}")"
n="$(printf '%s\n' "${lines}" | grep -c . )"
if [ "${n}" != 1 ]; then
  echo "  FAIL expected exactly one FRONT_DOOR default assignment in ${FILE}, found ${n}"
  echo; echo "0 passed, 1 failed"; exit 1
fi
ok "found exactly one FRONT_DOOR default assignment"

resolve() { # <env assignments...> -> the FRONT_DOOR the assignment yields
  env -i bash -c "$* ; ${lines} ; printf '%s' \"\${FRONT_DOOR}\""
}
check() { # <label> <want> <env assignments...>
  local label="$1" want="$2"; shift 2
  local got; got="$(resolve "$@")"
  [ "${got}" = "${want}" ] && ok "${label}: ${got}" || bad "${label}: got '${got}', want '${want}'"
}

check "nothing set"                          "http://localhost:8088"  ":"
check "PUBLIC_HOST_PORT=18088"               "http://localhost:18088" "export PUBLIC_HOST_PORT=18088"
check "FRONT_DOOR wins over a port"          "http://door.example:9"  "export FRONT_DOOR=http://door.example:9 PUBLIC_HOST_PORT=18088"
check "empty PUBLIC_HOST_PORT falls back"    "http://localhost:8088"  "export PUBLIC_HOST_PORT="

echo
echo "${P} passed, ${F} failed"
[ "${F}" -eq 0 ] || exit 1
exit 0

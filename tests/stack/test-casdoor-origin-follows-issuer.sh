#!/usr/bin/env bash
# =============================================================================
# test-casdoor-origin-follows-issuer.sh — the compose Casdoor must stamp the SAME issuer
# the services require, in test AND in prod.
#
# WHAT HAPPENED (2026-11-18, measured on a local `ENV=prod` stack). compose.real.yaml pinned
# Casdoor's `origin` to the literal http://localhost:8000. Under ENV=prod the Makefile hands
# every service CASDOOR_ISSUER_URI=https://id.<DOMAIN>, so sign-in answered 200 and then
# every authenticated call was 401:
#     www-authenticate: Bearer error="invalid_token",
#                       error_description="The iss claim is not valid"
# `origin` now reads CASDOOR_ISSUER_URI and falls back to the old literal, so a test-mode
# stack renders byte-identically and a prod one stamps what its services check.
#
# WHAT THIS PINS (offline, no docker):
#   (1) the casdoor service has exactly one `origin:` line and it is the expression
#       "${CASDOOR_ISSUER_URI:-http://localhost:8000}" (the variable the services get);
#   (2) evaluated with the variable unset it is http://localhost:8000 (test mode unchanged),
#       and with https://id.example.test it is that value (prod follows);
#   (3) the Makefile's compose environment still passes CASDOOR_ISSUER_URI='$(CASDOOR_ISSUER)'
#       (if that pairing were renamed, the origin would silently fall back to the literal).
# Zero matches is FAIL, never a pass. NEGATIVE CONTROL: COMPOSE_FILE_UNDER_TEST=<copy>
# and MAKEFILE_UNDER_TEST=<copy>; origin/main before this change is RED on (1).
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="${COMPOSE_FILE_UNDER_TEST:-${HERE}/compose.real.yaml}"
MAKEFILE="${MAKEFILE_UNDER_TEST:-${HERE}/../../Makefile}"
P=0; F=0
ok()  { P=$((P+1)); echo "  PASS $*"; }
bad() { F=$((F+1)); echo "  FAIL $*"; }

[ -f "${COMPOSE}" ] && [ -f "${MAKEFILE}" ] || { echo "  FAIL compose file or Makefile missing"; exit 2; }

# the casdoor service block: from "  casdoor:" to the next service at the same indent
block="$(awk '/^  casdoor:/{f=1;next} f&&/^  [a-z0-9-]+:/{exit} f' "${COMPOSE}")"
[ -n "${block}" ] && ok "found the casdoor service block" || { bad "no casdoor service block in ${COMPOSE}"; echo; echo "${P} passed, ${F} failed"; exit 1; }

lines="$(printf '%s\n' "${block}" | grep -E '^\s+origin:')"
n="$(printf '%s\n' "${lines}" | grep -c .)"
[ "${n}" = 1 ] && ok "exactly one origin line" || bad "expected one origin line in the casdoor block, found ${n}"

want='origin: "${CASDOOR_ISSUER_URI:-http://localhost:8000}"'
got="$(printf '%s' "${lines}" | sed -E 's/^[[:space:]]+//')"
[ "${got}" = "${want}" ] && ok "origin is the CASDOOR_ISSUER_URI expression" || bad "origin is '${got}', want '${want}'"

expr="${got#origin: }"; expr="${expr#\"}"; expr="${expr%\"}"
test_val="$(env -u CASDOOR_ISSUER_URI bash -c "printf '%s' \"${expr}\"")"
prod_val="$(CASDOOR_ISSUER_URI=https://id.example.test bash -c "printf '%s' \"${expr}\"")"
[ "${test_val}" = "http://localhost:8000" ] && ok "unset -> ${test_val} (test mode unchanged)" || bad "unset gave '${test_val}'"
[ "${prod_val}" = "https://id.example.test" ] && ok "set -> ${prod_val} (prod follows)" || bad "set gave '${prod_val}'"

if grep -qE "CASDOOR_ISSUER_URI='\\\$\(CASDOOR_ISSUER\)'" "${MAKEFILE}"; then
  ok "the Makefile still passes CASDOOR_ISSUER_URI='\$(CASDOOR_ISSUER)' to compose"
else
  bad "the Makefile no longer passes CASDOOR_ISSUER_URI='\$(CASDOOR_ISSUER)': origin would fall back to the literal"
fi

echo
echo "${P} passed, ${F} failed"
[ "${F}" -eq 0 ] || exit 1
exit 0

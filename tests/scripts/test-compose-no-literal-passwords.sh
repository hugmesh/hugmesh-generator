#!/usr/bin/env bash
# test-compose-no-literal-passwords.sh — no tests/stack/compose*.yaml spells a password.
#
# hugmesh-generator#857: the local stack's compose files carried 28 literal password
# values, 26 of them equal to the role's own name (POSTGRES_PASSWORD: adminbff for
# role adminbff, and so on). A Postgres volume keeps the value it was initialised
# with, and `make lan-*` serves the stack on the LAN. Every password now comes from
# the gitignored tests/stack/.env (tests/stack/gen-stack-db-env.sh writes it) as
# ${KEY:?...}, so a missing value stops compose instead of falling back to a word in
# the file. This guard keeps it that way.
#
# Proves, with python3 stdlib only (no PyYAML, no docker, no network):
#   (1) every tests/stack/compose*.yaml (a glob: a NEW compose file is covered the day
#       it lands) has no literal value in a password field: mapping entries (block and
#       flow style), shell/env-list/libpq assignments, URL userinfo, and ${VAR:-x}
#       defaults; and it checked enough fields not to be vacuous;
#   (2) the scanner's name allowlist (non-credential fields such as a boolean flag)
#       has no stale entry;
#   (3) NEGATIVE CONTROLS: each defect shape planted in a fixture is reported, and
#       its line number is the planted line;
#   (4) POSITIVE CONTROLS: the allowed shapes (${VAR:?msg}, ${VAR:-}, ${VAR:+x},
#       $${VAR} in a command, comments) are not reported;
#   (5) planting a literal back into a COPY of the real compose.local.yaml, or adding
#       a new compose file with one, turns the real-tree check red.
# The scanner never prints a value, only file:line and the field name.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
SCAN="${HERE}/compose_literal_passwords.py"
STACK="${REPO}/tests/stack"

P=0; F=0
ok()  { echo "  ok   $*"; P=$((P + 1)); }
bad() { echo "  FAIL $*"; F=$((F + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 2; }
[ -f "${SCAN}" ] || { echo "  FAIL scanner ${SCAN} missing"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "== tests/stack/compose*.yaml: no literal password values =="

echo "-- 1) the real tree --"
shopt -s nullglob
files=("${STACK}"/compose*.yaml)
shopt -u nullglob
if [ "${#files[@]}" -ge 10 ]; then ok "${#files[@]} compose files found by the glob"; else bad "only ${#files[@]} compose files found (expected >= 10)"; fi
out="$(python3 "${SCAN}" --count "${files[@]}" 2>&1)"; rc=$?
summary="$(tail -1 <<<"${out}")"
if [ "${rc}" -eq 0 ]; then
  ok "no literal password in any of them (${summary})"
else
  bad "literal password(s) found (rc=${rc}):"
  sed 's/^/         /' <<<"${out}"
fi
checked="$(sed -n 's/.*checked=\([0-9]*\).*/\1/p' <<<"${summary}")"
# 50 at 2026-11-04 (13 Postgres roles x their consumers, the svc password, the
# route-access key). A scanner that silently matched nothing would pass (1) above.
if [ "${checked:-0}" -ge 40 ]; then ok "vacuity floor: ${checked} password fields checked (>= 40)"; else bad "only ${checked:-0} password fields checked: the scanner is not seeing the files"; fi

echo "-- 2) the allowlist does not rot --"
stale="$(sed -n 's/.*allow_stale=\(.*\)$/\1/p' <<<"${summary}")"
if [ -z "${stale}" ]; then ok "every allowlisted non-credential field still occurs"; else bad "allowlist entries that no longer occur: ${stale}"; fi

echo "-- 3) negative controls: every planted shape is reported --"
# One fixture per shape; the planted line is line 3 of each.
plant() { # plant <name> <line>: a 4-line fixture with <line> as line 3
  printf 'services:\n  x:\n%s\n    image: postgres:16-alpine\n' "$2" > "${WORK}/neg-$1.yaml"
}
printf 'services:\n  x:\n    environment:\n      POSTGRES_PASSWORD: hunter2\n' > "${WORK}/neg-block.yaml"
plant flow         '    environment: { POSTGRES_DB: a, POSTGRES_USER: a, POSTGRES_PASSWORD: a }'
plant flowquoted   '    environment: { "POSTGRES_PASSWORD": "a" }'
plant default      '    environment: { SVC_PASSWORD: "${SVC_PASSWORD:-dev-svc-password}" }'
plant defaultbare  '      SVC_PASSWORD: ${SVC_PASSWORD:-dev-svc-password}'
plant envlist      '      - POSTGRES_PASSWORD=hunter2'
plant libpq        '      dataSourceName: "user=casdoor password=casdoor host=casdoor-db"'
plant url          '      SPRING_R2DBC_URL: "r2dbc:postgresql://adminbff:adminbff@admin-bff-db:5432/adminbff"'
plant command      '        PGPASSWORD=adminbff psql -h admin-bff-db -U adminbff -c "SELECT 1"'
plant dbpass       '      DB_PASS: threewizards'
plant passwd       '      SD_DBPASSWD: phpbb'
plant lower        '      password: hunter2'
plant mixed        '      PGPASSWORD: "${PREFIX}literal"'
plant numeric      '      POSTGRES_PASSWORD: 12345'
for f in "${WORK}"/neg-*.yaml; do
  name="$(basename "${f}" .yaml)"; name="${name#neg-}"
  want=3; [ "${name}" = block ] && want=4
  o="$(python3 "${SCAN}" "${f}" 2>&1)"; rc=$?
  if [ "${rc}" -eq 1 ] && grep -E ":${want}: literal password" <<<"${o}" >/dev/null; then
    ok "${name}: reported at line ${want}"
  else
    bad "${name}: NOT reported (rc=${rc}): ${o:-<no output>}"
  fi
  if grep -E 'hunter2|adminbff:adminbff|dev-svc-password|threewizards|12345' <<<"${o}" >/dev/null; then
    bad "${name}: the scanner printed the planted VALUE"
  fi
done

echo "-- 4) positive controls: allowed shapes are not reported --"
cat > "${WORK}/pos.yaml" <<'EOF'
# POSTGRES_PASSWORD: commented-out literal is not a value
services:
  x:
    environment: { POSTGRES_DB: a, POSTGRES_USER: a, POSTGRES_PASSWORD: "${A_DB_PASSWORD:?run tests/stack/gen-stack-db-env.sh (make stack-up does)}" }
  y:
    environment:
      POSTGRES_PASSWORD: ${B_DB_PASSWORD:?run tests/stack/gen-stack-db-env.sh (make stack-up does)}
      SPRING_R2DBC_PASSWORD: ${B_DB_PASSWORD:?missing}  # an inline comment: hunter2
      ROUTE_ACCESS_R2DBC_URL: "r2dbc:postgresql://gateway:${ROUTE_ACCESS_DB_PASSWORD:-}@route-access-db:5432/gateway"
      ROUTE_ACCESS_DB_PASSWORD_SET: ${ROUTE_ACCESS_DB_PASSWORD:+yes}
      DB_PASS: "${C_DB_PASSWORD?unset}"
      OTHER_PASSWORD: ${OTHER_PASSWORD}
      EMPTY_PASSWORD:
      CASDOOR_PASSWORD_RESET_ENABLED: ${CASDOOR_PASSWORD_RESET_ENABLED:-false}
      dataSourceName: "user=casdoor password=${CASDOOR_DB_PASSWORD:?missing} host=casdoor-db"
    command:
      - /bin/sh
      - -c
      - |
        PGPASSWORD="$${POSTGRES_PASSWORD}" exec psql -h 127.0.0.1 -U x
        PGPASSWORD=$$POSTGRES_PASSWORD psql -U x
EOF
o="$(python3 "${SCAN}" --count "${WORK}/pos.yaml" 2>&1)"; rc=$?
pchecked="$(sed -n 's/.*checked=\([0-9]*\).*/\1/p' <<<"$(tail -1 <<<"${o}")")"
if [ "${rc}" -eq 0 ]; then ok "no allowed shape is reported"; else bad "allowed shapes reported (rc=${rc}): $(head -3 <<<"${o}" | tr '\n' '|')"; fi
if [ "${pchecked:-0}" -ge 10 ]; then ok "the positive fixture's ${pchecked} fields were all checked, not skipped"; else bad "only ${pchecked:-0} fields of the positive fixture were checked"; fi

echo "-- 5) a literal planted into the REAL files turns the check red --"
mkdir -p "${WORK}/stack"
cp "${files[@]}" "${WORK}/stack/"
python3 - "${WORK}/stack/compose.local.yaml" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s2, n = re.subn(r"(SPRING_R2DBC_PASSWORD: )\$\{ADMIN_BFF_DB_PASSWORD:\?[^}]*\}", r"\1adminbff", s, count=1)
if n != 1:
    sys.exit("could not plant: no ADMIN_BFF_DB_PASSWORD consumer found")
open(p, "w", encoding="utf-8").write(s2)
PY
plant_rc=$?
o="$(python3 "${SCAN}" "${WORK}"/stack/compose*.yaml 2>&1)"; rc=$?
if [ "${plant_rc}" -eq 0 ] && [ "${rc}" -eq 1 ] && grep -F 'compose.local.yaml' <<<"${o}" | grep -F 'SPRING_R2DBC_PASSWORD' >/dev/null; then
  ok "a role-name literal put back into compose.local.yaml is reported"
else
  bad "planted literal in compose.local.yaml not reported (plant rc=${plant_rc}, scan rc=${rc})"
fi
cp "${files[@]}" "${WORK}/stack/"
printf 'services:\n  new-db:\n    environment:\n      POSTGRES_PASSWORD: newdb\n' > "${WORK}/stack/compose.zz-new.yaml"
shopt -s nullglob; wf=("${WORK}"/stack/compose*.yaml); shopt -u nullglob
o="$(python3 "${SCAN}" "${wf[@]}" 2>&1)"; rc=$?
if [ "${rc}" -eq 1 ] && grep -F 'compose.zz-new.yaml:4' <<<"${o}" >/dev/null; then ok "a NEW compose file with a literal is caught by the glob"; else bad "a new compose file's literal was missed (rc=${rc})"; fi

echo
echo "${P} passed, ${F} failed"
[ "${F}" -eq 0 ]

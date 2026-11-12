#!/usr/bin/env bash
# Mutation battery for test-stack-idp-exposure.sh (NEW-15). BREAKS PRODUCTION — the
# compose files, the Studio's own-Casdoor overlay template, seed-e2e.sh,
# derive-games-admin.sh and gen-casdoor-admin-env.sh — runs the suite, and demands RED.
# Every mutation is verified to have ACTUALLY changed its file first: a replacement that
# matched nothing reads exactly like an uncaught mutant.
#
# ⚠ It edits the tree IN PLACE and restores it on EXIT (the seed_password_reconcile_
# mutations.sh convention); a KILLED battery may not revert: `git status` this tree
# before trusting any later run in it.
#
#   bash tests/scripts/stack_idp_exposure_mutations.sh
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUITE="${REPO}/tests/scripts/test-stack-idp-exposure.sh"
REAL="${REPO}/tests/stack/compose.real.yaml"
BRANDB="${REPO}/tests/stack/compose.brand-b.yaml"
ALT="${REPO}/tests/stack/compose.alt-social.yaml"
OWN="${REPO}/studio/hugmesh_studio/core/own_casdoor.py"
SE="${REPO}/tests/stack/seed-e2e.sh"
DG="${REPO}/tests/stack/derive-games-admin.sh"
GEN="${REPO}/tests/stack/gen-casdoor-admin-env.sh"
FILES=("${REAL}" "${BRANDB}" "${ALT}" "${OWN}" "${SE}" "${DG}" "${GEN}")

BAK="$(mktemp -d)"
for i in "${!FILES[@]}"; do cp -p "${FILES[$i]}" "${BAK}/${i}"; done
restore() { local i; for i in "${!FILES[@]}"; do cp -p "${BAK}/${i}" "${FILES[$i]}"; done; }
trap 'restore; rm -rf "${BAK}"' EXIT

SURVIVED=0; CAUGHT=0
mutate() { # mutate NAME TARGET OLD NEW — exactly-once replacement, run the suite, demand RED
  local name="$1" target="$2" i ref=""
  restore
  OLD="$3" NEW="$4" python3 - "${target}" <<'PY' || { printf '  ERROR    %s: mutation did not apply (old text not found exactly once)\n' "${name}"; SURVIVED=$((SURVIVED+1)); return; }
import os, sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
old, new = os.environ['OLD'], os.environ['NEW']
if s.count(old) != 1:
    sys.exit(1)
open(p, 'w', encoding='utf-8').write(s.replace(old, new))
PY
  for i in "${!FILES[@]}"; do [ "${FILES[$i]}" = "${target}" ] && ref="${BAK}/${i}"; done
  if [ -z "${ref}" ] || cmp -s "${target}" "${ref}"; then
    printf '  ERROR    %s: file unchanged after mutation\n' "${name}"; SURVIVED=$((SURVIVED+1)); return
  fi
  if bash "${SUITE}" </dev/null >/dev/null 2>&1; then
    printf '  SURVIVED %s  <-- the suite passed on broken production\n' "${name}"; SURVIVED=$((SURVIVED+1))
  else
    printf '  caught   %s\n' "${name}"; CAUGHT=$((CAUGHT+1))
  fi
}

echo "== mutation battery: stack identity-provider exposure (NEW-15) =="

# ── the publishes ────────────────────────────────────────────────────────────
mutate "X1  casdoor published on every interface again (the defect verbatim)" "${REAL}" \
'    ports: ["${STACK_BIND_ADDR:-127.0.0.1}:8000:8000"]' \
'    ports: ["8000:8000"]'
mutate "X2  tuwunel's bind variable loses its loopback default" "${REAL}" \
'    ports: ["${STACK_BIND_ADDR:-127.0.0.1}:8008:8008"]' \
'    ports: ["${STACK_BIND_ADDR}:8008:8008"]'
mutate "X3  brand-B casdoor defaults to 0.0.0.0" "${BRANDB}" \
'      - "${STACK_BIND_ADDR:-127.0.0.1}:8001:8000"' \
'      - "${STACK_BIND_ADDR:-0.0.0.0}:8001:8000"'
mutate "X4  phpBB published on every interface" "${ALT}" \
'    ports: ["${STACK_BIND_ADDR:-127.0.0.1}:8081:8080"]' \
'    ports: ["8081:8080"]'
mutate "X5  the Studio's per-domain Casdoor template loses its host IP" "${OWN}" \
'      - "${{STACK_BIND_ADDR:-127.0.0.1}}:{port}:8000"' \
'      - "{port}:8000"'

# ── the seed ─────────────────────────────────────────────────────────────────
mutate "X6  seed-e2e.sh defaults the admin password to the factory value again" "${SE}" \
'CASDOOR_ADMIN_PASS="${CASDOOR_ADMIN_PASS:-}"' \
'CASDOOR_ADMIN_PASS="${CASDOOR_ADMIN_PASS:-123}"'
mutate "X7  the seed never falls back to the factory default (no move)" "${SE}" \
'  if ! casdoor_try_login "${base}" "${CASDOOR_BOOTSTRAP_PASSWORD}" "${CJ}"; then' \
'  if true; then'
mutate "X8  set-password skipped (reports a move that never happened)" "${SE}" \
'          | curl -s --max-time 15 -b "${CJ}" -c "${CJ}" -X POST "${base}/api/set-password" \' \
'          | cat >/dev/null; printf '"'"'{"status":"ok"}'"'"' || curl -s --max-time 15 -b "${CJ}" -c "${CJ}" -X POST "${base}/api/set-password" \'
mutate "X9  the factory-default-refused proof deleted" "${SE}" \
'  if casdoor_try_login "${base}" "${CASDOOR_BOOTSTRAP_PASSWORD}" "${probe}"; then' \
'  if false; then'
mutate "X10 the admin lockout is no longer classified" "${SE}" \
'CASDOOR_ADMIN_LOCKOUT_MARKER="too many times"' \
'CASDOOR_ADMIN_LOCKOUT_MARKER="never-matches-any-message"'
mutate "X11 an exported factory default is accepted" "${SE}" \
'[ "${CASDOOR_ADMIN_PASS}" != "${CASDOOR_BOOTSTRAP_PASSWORD}" ] \' \
'true || [ "${CASDOOR_ADMIN_PASS}" != "${CASDOOR_BOOTSTRAP_PASSWORD}" ] \'
mutate "X12 the admin session is no longer proven by get-account" "${SE}" \
'  [ "${name}" = "${CASDOOR_ADMIN_USER}" ] \
    || die "Casdoor at ${base} accepted the admin login, but the session resolves to' \
'  true \
    || die "Casdoor at ${base} accepted the admin login, but the session resolves to'

# ── derive and the generator ─────────────────────────────────────────────────
mutate "X13 derive-games-admin.sh defaults to the factory value again" "${DG}" \
'CASDOOR_ADMIN_PASS="${CASDOOR_ADMIN_PASS:-}"' \
'CASDOOR_ADMIN_PASS="${CASDOOR_ADMIN_PASS:-123}"'
mutate "X14 derive-games-admin.sh MINTS instead of reading" "${DG}" \
'gen-casdoor-admin-env.sh" --read)" \' \
'gen-casdoor-admin-env.sh" --print)" \'
mutate "X15 the generator rotates on every run" "${GEN}" \
'if [ -z "${val}" ]; then
  val="$(mint)"' \
'if true; then
  val="$(mint)"'
mutate "X16 the generator hands out a factory-default value from the file" "${GEN}" \
'  [ "$1" != "${FACTORY_DEFAULT}" ]' \
'  true'
mutate "X17 the generator leaves the file world-readable" "${GEN}" \
'chmod 600 "${ENV_FILE}" 2>/dev/null || true' \
'chmod 644 "${ENV_FILE}" 2>/dev/null || true'

# ── positive control: the restored tree must be green ────────────────────────
restore
for i in "${!FILES[@]}"; do
  cmp -s "${FILES[$i]}" "${BAK}/${i}" || { echo "  ERROR    restore left ${FILES[$i]} differing"; SURVIVED=$((SURVIVED+1)); }
done
if bash "${SUITE}" </dev/null >/dev/null 2>&1; then
  printf '  control  restored tree is green, every mutation was reverted\n'
else
  printf '  ERROR    the RESTORED tree fails the suite\n'; SURVIVED=$((SURVIVED+1))
fi

echo
echo "== battery: ${CAUGHT} caught, ${SURVIVED} survived/errored =="
[ "${SURVIVED}" -eq 0 ]

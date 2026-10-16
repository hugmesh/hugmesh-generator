#!/usr/bin/env bash
# Mutation battery for test-password-rotation-per-run.sh. BREAKS PRODUCTION — the
# password library, the three lane run-starts, a sub-seeder, seed-e2e.sh's
# Matrix reconcile and the two Studio keep-paths — runs the suite, and demands
# RED for each (the seed_password_reconcile_mutations.sh convention). Every
# mutation is verified to have ACTUALLY changed its file first: a replacement
# that matched nothing reads exactly like an uncaught mutant.
#
# M1 is THE 2026-10-15 DEFECT verbatim: the run start resolves instead of
# rotating, so one password serves every run forever.
#
# ⚠ A KILLED battery does not revert (the restore runs on EXIT): `git status`
# this tree before trusting any later run in it.
#
#   bash tests/scripts/password_rotation_per_run_mutations.sh
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUITE="${REPO}/tests/scripts/test-password-rotation-per-run.sh"
LIB=tests/stack/e2e-password.sh
SE=tests/stack/seed-e2e.sh
BK=specs/cluster/bootstrap/kind-local/bootstrap-kind.sh
QE=tests/qemu/run-qemu-e2e.sh
SA=tests/qemu/seed-accounts.sh
LM=studio/hugmesh_studio/gui/pages/localmesh.py
SM=studio/hugmesh_studio/core/saved_meshes.py
FILES=("${LIB}" "${SE}" "${BK}" "${QE}" "${SA}" "${LM}" "${SM}")

BAK="$(mktemp -d "${TMPDIR:-/tmp}/e2epw-mut.XXXXXX")"
for f in "${FILES[@]}"; do mkdir -p "${BAK}/$(dirname "${f}")"; cp -p "${REPO}/${f}" "${BAK}/${f}"; done
restore() { for f in "${FILES[@]}"; do cp -p "${BAK}/${f}" "${REPO}/${f}"; done; }
trap 'restore; rm -rf "${BAK}"' EXIT

SURVIVED=0; CAUGHT=0
mutate() { # mutate NAME FILE OLD NEW — exactly-once replacement, run suite, demand RED
  local name="$1" rel="$2"
  restore
  OLD="$3" NEW="$4" python3 - "${REPO}/${rel}" <<'PY' || { printf '  ERROR    %s: mutation did not apply (old text not found exactly once)\n' "${name}"; SURVIVED=$((SURVIVED+1)); return; }
import os, sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
old, new = os.environ['OLD'], os.environ['NEW']
if s.count(old) != 1:
    sys.exit(1)
open(p, 'w', encoding='utf-8').write(s.replace(old, new))
PY
  if cmp -s "${REPO}/${rel}" "${BAK}/${rel}"; then
    printf '  ERROR    %s: file unchanged after mutation\n' "${name}"; SURVIVED=$((SURVIVED+1)); return
  fi
  if bash "${SUITE}" >/dev/null 2>&1; then
    printf '  SURVIVED %s  <-- the suite passed on broken production\n' "${name}"
    SURVIVED=$((SURVIVED+1))
  else
    printf '  caught   %s\n' "${name}"
    CAUGHT=$((CAUGHT+1))
  fi
}

echo "== mutation battery: e2e password rotation =="
restore
if ! bash "${SUITE}" >/dev/null 2>&1; then
  echo "  ERROR the suite is RED on the unmutated tree — fix that first"; exit 1
fi

mutate "M1 the 2026-10-15 defect: run start reuses the file (never rotates)" "${LIB}" \
  'if [ "${E2E_PASSWORD_KEEP:-0}" = "1" ]; then' 'if true; then'
mutate "M2 E2E_PASSWORD_KEEP=1 ignored (always rotates)" "${LIB}" \
  'if [ "${E2E_PASSWORD_KEEP:-0}" = "1" ]; then' 'if [ "${E2E_PASSWORD_KEEP:-0}" = "never" ]; then'
mutate "M3 explicit/inherited E2E_PASSWORD ignored by the run start" "${LIB}" \
  $'e2e_password_start_run() {\n  if [ -n "${E2E_PASSWORD:-}" ]; then' $'e2e_password_start_run() {\n  if false; then'
mutate "M4 old generator (strip after the fact, fallback only when EMPTY: short values)" "${LIB}" \
  $'    val="$(openssl rand -base64 48 2>/dev/null | tr -dc \'A-Za-z0-9\' | head -c 32)"\n  fi\n  if [ "${#val}" -ne 32 ]; then' \
  $'    val="$(openssl rand -base64 24 2>/dev/null | tr -d \'\\n/+=\')"\n  fi\n  if [ -z "${val}" ]; then'
mutate "M5 rewritten file left world-readable" "${LIB}" \
  'chmod 600 "${tmp}" || exit 1' 'chmod 644 "${tmp}" || exit 1'
mutate "M6 present-but-unreadable file not refused" "${LIB}" \
  $'    e2e_password_read E2E_PASSWORD >/dev/null   # prints the named-fix message\n    return 1' \
  $'    : # refusal removed'
mutate "M7 superseded value not kept in E2E_PASSWORD_PREVIOUS" "${LIB}" \
  'e2e_password_write E2E_PASSWORD "${generated}" E2E_PASSWORD_PREVIOUS "${hist}"' \
  'e2e_password_write E2E_PASSWORD "${generated}"'
mutate "M8 history not capped" "${LIB}" \
  '[ "${n}" -lt "${E2E_PASSWORD_HISTORY}" ] || break' ':'
mutate "M9 compose lane resolves instead of starting a run" "${SE}" \
  'e2e_password_start_run || die' 'e2e_password_ensure || die'
mutate "M10 kind lane resolves instead of starting a run" "${BK}" \
  $'  e2e_password_start_run \\\n' $'  e2e_password_ensure \\\n'
mutate "M11 QEMU lane resolves instead of starting a run" "${QE}" \
  $'e2e_password_start_run \\\n' $'e2e_password_ensure \\\n'
mutate "M12 a sub-seeder rotates inside the run" "${SA}" \
  $'e2e_password_ensure \\\n' $'e2e_password_start_run \\\n'
mutate "M13 leg 2 no longer reconciles e2e-mod (create-only)" "${SE}" \
  $'matrix_reconcile_password e2e-mod\n' ''
mutate "M14 Matrix reconcile ignores the previous values" "${SE}" \
  'for old in ${E2E_PASSWORD_PREVIOUS//,/ }; do' 'for old in ; do'
mutate "M15 Matrix reconcile never retries with the UIAA session" "${SE}" \
  'if [ "${code}" = "401" ]; then' 'if false; then'
mutate "M16 Matrix reconcile reports success without proving the new value logs in" "${SE}" \
  $'    if [ -n "$(matrix_login_token "${u}" "${E2E_PASSWORD}")" ]; then\n      log "matrix user ${u}: password reconciled' \
  $'    if true; then\n      log "matrix user ${u}: password reconciled'
mutate "M17 Studio compose Add user rotates every persona" "${LM}" \
  $',\n               "E2E_PASSWORD_KEEP": "1"}' '}'
mutate "M18 Studio saved-mesh restore rotates the record's password" "${SM}" \
  '        env["E2E_PASSWORD_KEEP"] = "1"' '        pass'

restore
for f in "${FILES[@]}"; do
  cmp -s "${REPO}/${f}" "${BAK}/${f}" || { echo "  ERROR ${f} was not restored"; SURVIVED=$((SURVIVED+1)); }
done
echo "== ${CAUGHT} caught, ${SURVIVED} survived/errored =="
[ "${SURVIVED}" -eq 0 ]

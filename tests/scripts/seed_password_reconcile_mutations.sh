#!/usr/bin/env bash
# Mutation battery for test-seed-password-reconcile.sh. BREAKS PRODUCTION —
# tests/qemu/seed-accounts.sh, tests/stack/seed-e2e.sh and the Makefile — runs
# the suite, and demands RED. A guard nobody has broken on purpose is a guard
# nobody has tested (the loop_preflight_mutations.sh convention). Every
# mutation is verified to have ACTUALLY changed its file first: a replacement
# that matched nothing reads exactly like an uncaught mutant and would send
# someone hardening a guard that was already fine.
#
# M1 is THE 2026-08-27 INCIDENT verbatim: restore skip-on-exists and the suite
# must fail, because a recreated stack's users then keep a stale password while
# every log line stays green.
#
# ⚠ A KILLED battery does not revert (the byte-identity check is the LAST
# thing to run): `git status` this tree before trusting any later run in it.
#
#   bash tests/scripts/seed_password_reconcile_mutations.sh
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SA="${REPO}/tests/qemu/seed-accounts.sh"
SE="${REPO}/tests/stack/seed-e2e.sh"
MK="${REPO}/Makefile"
SUITE="${REPO}/tests/scripts/test-seed-password-reconcile.sh"

BAK="$(mktemp -d)"
cp "${SA}" "${BAK}/sa"; cp "${SE}" "${BAK}/se"; cp "${MK}" "${BAK}/mk"
restore() { cp "${BAK}/sa" "${SA}"; cp "${BAK}/se" "${SE}"; cp "${BAK}/mk" "${MK}"; }
trap 'restore; rm -rf "${BAK}"' EXIT

SURVIVED=0; CAUGHT=0
mutate() { # mutate NAME TARGET OLD NEW — apply exactly-once replacement, run suite, demand RED
    local name="$1" target="$2"
    restore
    OLD="$3" NEW="$4" python3 - "${target}" <<'PY' || { printf '  ERROR    %s: mutation did not apply (old text not found exactly once)\n' "${name}"; SURVIVED=$((SURVIVED+1)); return; }
import os, sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
old, new = os.environ['OLD'], os.environ['NEW']
if s.count(old) != 1:
    sys.exit(1)
open(p, 'w', encoding='utf-8').write(s.replace(old, new))
PY
    # The file must actually differ, or "survived" would mean "never broken".
    local ref
    case "${target}" in
        "${SA}") ref="${BAK}/sa" ;; "${SE}") ref="${BAK}/se" ;; *) ref="${BAK}/mk" ;;
    esac
    if cmp -s "${target}" "${ref}"; then
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

echo "== mutation battery: seed password reconcile =="

# ── seed-accounts.sh (the rendered apply hook) ───────────────────────────────
mutate "M1  skip-on-exists restored (the 2026-08-27 incident verbatim)" "${SA}" \
'    verb="$(apply_password "${ORG}" "${name}" "${pass}")"
    log "user ${name} exists (password ${verb})"
    already=$((already+1))
    [ "${verb}" = "rotated" ] && rotated=$((rotated+1))
    continue' \
'    log "user ${name} exists"
    already=$((already+1))
    continue'

mutate "M2  apply_password verification pass deleted" "${SA}" \
'  if casdoor_setpw "${owner}" "${name}" "${pw}"; then
    die "set-password for ${owner}/${name} reported success but Casdoor accepted the identical write a second time — the password did NOT persist (the setpw-noop shape)"
  fi
  [[ "${SETPW_MSG}" == *"${PASSWORD_ALREADY_SET}"* ]] \
    || die "set-password for ${owner}/${name}: verification expected Casdoor'\''s already-current refusal but got: ${SETPW_MSG}"
  printf '\''%s'\'' "${verb}"' \
'  printf '\''%s'\'' "${verb}"'

mutate "M3  already-current refusal text mismatched (typo)" "${SA}" \
'PASSWORD_ALREADY_SET="must be different from your current password"' \
'PASSWORD_ALREADY_SET="must be different from your previous password"'

mutate "M8  reconciles to the WRONG value (username, not the render)" "${SA}" \
'  if [ -n "${exists}" ]; then
    verb="$(apply_password "${ORG}" "${name}" "${pass}")"' \
'  if [ -n "${exists}" ]; then
    verb="$(apply_password "${ORG}" "${name}" "${name}")"'

mutate "M10 rotation counter never incremented" "${SA}" \
'    [ "${verb}" = "rotated" ] && rotated=$((rotated+1))' \
'    :'

mutate "M11 casdoor_setpw ignores the response envelope" "${SA}" \
'  [ "${status}" = "ok" ]
}

# Casdoor REFUSES a set-password' \
'  true
}

# Casdoor REFUSES a set-password'

mutate "M14 pre-mint OAuth error codes no longer recorded" "${SA}" \
'    printf '\''%s\n'\'' "${err:-no-oauth-error-body}" >> "${WORK}/premint-errors"' \
'    :'

mutate "M4  invalid_grant zero-mint collapsed into the generic message" "${SA}" \
'    *" invalid_grant "*)' \
'    *" never-match-xyzzy "*)'

# ── seed-e2e.sh (leg 1c honesty) ─────────────────────────────────────────────
mutate "M5  total-failure exit swallowed (falls through to PARTIAL)" "${SE}" \
'    exit 3' \
'    :'

mutate "M12 total-failure exits 0 (dishonest exit status)" "${SE}" \
'    exit 3' \
'    exit 0'

mutate "M9  total-failure condition can never fire" "${SE}" \
'  if [ "${reg_fail}" -gt 0 ] && [ "${reg_ok}" -eq 0 ]; then' \
'  if [ "${reg_fail}" -gt 999 ] && [ "${reg_ok}" -eq 0 ]; then'

mutate "M6  partial failure relabelled OK" "${SE}" \
'log "leg 1c PARTIAL: ${reg_ok} onboarded, ${reg_gated} left gated on purpose (${SEED_REGISTRATION_SKIP}), ${reg_fail} FAILED"' \
'log "leg 1c OK: ${reg_ok} onboarded, ${reg_gated} left gated on purpose (${SEED_REGISTRATION_SKIP}), ${reg_fail} FAILED"'

# ── Makefile (the SEED_COMPLETE_REGISTRATION hint) ───────────────────────────
mutate "M7  the flag never selects the stage-2 note (hint back to static)" "${MK}" \
'ifeq ($(SEED_COMPLETE_REGISTRATION),1)' \
'ifeq ($(SEED_COMPLETE_REGISTRATION),never)'

mutate "M13 the stage-2 note is ALWAYS selected (hint never prints)" "${MK}" \
'ifeq ($(SEED_COMPLETE_REGISTRATION),1)' \
'ifeq (1,1)'

# ── positive control: the restored tree must be green ────────────────────────
restore
if ! cmp -s "${SA}" "${BAK}/sa" || ! cmp -s "${SE}" "${BAK}/se" || ! cmp -s "${MK}" "${BAK}/mk"; then
    echo "  ERROR    restore left production differing from its backup"
    SURVIVED=$((SURVIVED+1))
fi
if bash "${SUITE}" >/dev/null 2>&1; then
    printf '  control  restored tree is green, every mutation was reverted\n'
else
    printf '  ERROR    the RESTORED tree fails the suite — restoration is broken\n'
    SURVIVED=$((SURVIVED+1))
fi

echo
echo "== battery: ${CAUGHT} caught, ${SURVIVED} survived/errored =="
[ "${SURVIVED}" -eq 0 ]

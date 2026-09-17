#!/usr/bin/env bash
# test-e2e-spec-symbol-resolution.sh
#
# A SPEC MUST IMPORT EVERY LOCAL HELPER IT CALLS.
#
# hugmesh-generator#305: specs/15-rbac-per-realm-login.spec.ts called
# `loginPassword()` in a default parameter while importing `sharedPassword`.
# TypeScript is never compiled in this lane — Playwright transpiles each module
# on its own and resolves no cross-file name — so the module loaded fine and
# every test in it died at CALL time with
#
#     ReferenceError: loginPassword is not defined
#
# from 2026-08-27 until #305. Four zero assertions, reported as four failures
# that looked like stack trouble.
#
# WHY NOTHING ELSE SAW IT, measured on the tree that carried the bug:
#   * test-e2e-enumeration-without-credentials.sh was 3 passed / 0 failed —
#     `playwright test --list` imports the module but never EVALUATES a default
#     parameter, so the bad expression was never reached.
#   * there is no tsconfig.json under tests/e2e and no typecheck anywhere in the
#     lane, so tsc's TS2304 never ran. (Borrowing a tsc does reproduce it:
#     `specs/15-rbac-per-realm-login.spec.ts(36,77): error TS2304: Cannot find
#     name 'loginPassword'.`)
#   * a grep for the name succeeds — in the very file missing its import.
#
# So this guard asks the one question those three cannot: is every project
# symbol a file USES actually BOUND in that file? No toolchain, no node_modules,
# no network — it reads source, so it runs in the shell-suite images too.
#
# Section 2 is a MUTATION BATTERY. A checker that reports "clean" is worthless
# until you have watched it go red on the defect it exists for, so this rebuilds
# the #305 shape (and four neighbours) in a throwaway copy and fails if any of
# them slips through — and fails just as hard if a comment-only or string-only
# mention is reported, because a guard that cries wolf gets switched off.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
E2E="${REPO}/tests/e2e"
CHECKER="${HERE}/e2e_spec_symbol_resolution.py"

P=0; F=0; S=0
ok()   { echo "  ok   $*"; P=$((P + 1)); }
bad()  { echo "  FAIL $*"; F=$((F + 1)); }
skip() { echo "  SKIP $*"; S=$((S + 1)); }

echo "== e2e spec symbol resolution =="

if [ ! -f "${CHECKER}" ]; then
  echo "  FAIL ${CHECKER##*/} is missing — this suite asserted NOTHING"
  echo
  echo "== 0 passed, 1 failed, 0 skipped =="
  exit 1
fi

# ── 1. the live tree resolves ────────────────────────────────────────────────
echo "-- 1. every local symbol used under tests/e2e/{specs,steps} is bound --"
out="$(python3 "${CHECKER}" "${E2E}" 2>&1)"
rc=$?
if [ "${rc}" -eq 2 ]; then
  # Exit 2 is the vacuity floor inside the checker: too few files, or an empty
  # export vocabulary. It is a FAILURE, never a quiet pass.
  bad "the scan could not run, so it asserted nothing:
$(echo "${out}" | sed 's/^/      /')"
elif [ "${rc}" -ne 0 ]; then
  bad "undefined local reference(s) — these die at CALL time with ReferenceError,
       and neither --list nor any grep can see them:
$(echo "${out}" | sed 's/^/      /')
       => import the name in that file (see specs/helpers.ts for what it re-exports)."
else
  bad_line="$(echo "${out}" | grep -a '^clean:' || true)"
  if [ -z "${bad_line}" ]; then
    bad "checker exited 0 without its 'clean:' summary — refusing to read silence as a pass. Output was:
$(echo "${out}" | sed 's/^/      /')"
  else
    ok "${bad_line#clean: }"
  fi
fi

# ── 2. mutation battery ──────────────────────────────────────────────────────
# Five mutations: three MUST be caught, two MUST NOT be reported. Each one is
# applied to a throwaway copy, and each is verified to have actually changed the
# file before its verdict is believed — a no-op sed that "passes" is the classic
# way a battery reports strength it does not have.
echo "-- 2. mutation battery: break it on purpose and watch it go red --"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
WORK="${TMP}/e2e"
mkdir -p "${WORK}"
cp -r "${E2E}/specs" "${E2E}/steps" "${WORK}/" 2>/dev/null

run_checker() { python3 "${CHECKER}" "${WORK}" 2>&1; }

# $1 label  $2 file (relative to ${WORK})  $3 python mutator  $4 expect: catch|silent  $5 needle
mutate() {
  local label
  local rel
  local mutator
  local expect
  local needle
  label="$1"; rel="$2"; mutator="$3"; expect="$4"; needle="$5"
  local f="${WORK}/${rel}"
  if [ ! -f "${f}" ]; then
    bad "M:${label} — ${rel} is missing from the copy; mutation NOT applied, nothing proved"
    return
  fi
  cp "${f}" "${f}.orig"
  python3 -c "${mutator}" "${f}"
  if cmp -s "${f}" "${f}.orig"; then
    mv "${f}.orig" "${f}"
    bad "M:${label} — the mutation changed NOTHING (source drifted?); this leg proved nothing"
    return
  fi
  local mout
  mout="$(run_checker)"
  local mrc=$?
  mv "${f}.orig" "${f}"
  if [ "${expect}" = "catch" ]; then
    if [ "${mrc}" -eq 1 ] && echo "${mout}" | grep -a -- "${needle}" >/dev/null; then
      ok "M:${label} — caught ($(echo "${mout}" | grep -a -- "${needle}" | head -n1))"
    else
      bad "M:${label} — NOT caught (rc=${mrc}). The guard is blind to this shape. Output:
$(echo "${mout}" | sed 's/^/      /')"
    fi
  else
    if [ "${mrc}" -eq 0 ]; then
      ok "M:${label} — correctly silent (a mention that is not a use)"
    else
      bad "M:${label} — FALSE POSITIVE (rc=${mrc}); a guard that cries wolf gets switched off. Output:
$(echo "${mout}" | sed 's/^/      /')"
    fi
  fi
}

# M1 — the exact #305 defect: import the wrong sibling name, keep the call.
mutate "305-verbatim" "specs/15-rbac-per-realm-login.spec.ts" \
'import sys,re
p=sys.argv[1]; s=open(p).read()
s=s.replace("systemsUser, loginPassword,", "systemsUser, sharedPassword,")
open(p,"w").write(s)' \
  catch "15-rbac-per-realm-login.spec.ts"

# M2 — a name dropped from an existing import list, call left behind.
mutate "dropped-import" "specs/04-five-users.spec.ts" \
'import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("onboard, loginPassword, shot", "onboard, shot")
open(p,"w").write(s)' \
  catch "loginPassword"

# M3 — a use that only ever appears inside a template substitution. Blanking
# `${...}` along with the literal text around it would hide this whole class.
mutate "template-substitution" "specs/01-frontpage.spec.ts" \
'import sys
p=sys.argv[1]; s=open(p).read()
s = s + "\nconst _m3 = `pw=${loginPassword()}`;\n"
open(p,"w").write(s)' \
  catch "loginPassword"

# M4 — a COMMENT-only mention. Must stay silent: spec 13, 29 and 33 all name
# sharedPassword() in prose, and reporting those would drown the real signal.
mutate "comment-only" "specs/01-frontpage.spec.ts" \
'import sys
p=sys.argv[1]; s=open(p).read()
s = s + "\n// loginPassword() and onboard() are discussed here, never called.\n/* swarmPassword() too */\n"
open(p,"w").write(s)' \
  silent ""

# M5 — a STRING-only mention, including one inside a template literal.
mutate "string-only" "specs/01-frontpage.spec.ts" \
'import sys
p=sys.argv[1]; s=open(p).read()
s = s + "\nconst _m5a = \"loginPassword\";\nconst _m5b = 1 ? `call onboard() first` : `or swarmPassword`;\n"
open(p,"w").write(s)' \
  silent ""

# ── 3. the vacuity floor is real ─────────────────────────────────────────────
# Without this, deleting the specs makes the guard green forever.
echo "-- 3. an empty tree must FAIL the scan, not pass it --"
EMPTY="${TMP}/empty"
mkdir -p "${EMPTY}/specs" "${EMPTY}/steps"
cp "${E2E}/specs/helpers.ts" "${EMPTY}/specs/" 2>/dev/null
vout="$(python3 "${CHECKER}" "${EMPTY}" 2>&1)"
vrc=$?
if [ "${vrc}" -eq 2 ] && echo "${vout}" | grep -a 'SCAN-FAILED' >/dev/null; then
  ok "a near-empty tree exits 2 with SCAN-FAILED ($(echo "${vout}" | head -n1))"
else
  bad "a near-empty tree exited ${vrc} — the vacuity floor is gone, so deleting the specs would read as a clean pass. Output:
$(echo "${vout}" | sed 's/^/      /')"
fi

echo
echo "== ${P} passed, ${F} failed, ${S} skipped =="
[ "${F}" -eq 0 ] || exit 1
exit 0

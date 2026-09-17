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
# Five mutations: three MUST add a finding, two MUST add none. Each one is
# applied to a throwaway copy, and each is verified to have actually changed the
# file before its verdict is believed — a no-op sed that "passes" is the classic
# way a battery reports strength it does not have.
#
# EVERY verdict below is taken against a BASELINE measured on the un-mutated copy,
# never against an absolute exit code. That matters: if the tree already carries
# an offender — a half-finished edit, a sibling lane's in-flight change, or
# someone reverting the #305 import to see this suite work — an absolute `rc == 0`
# turns the two SILENT legs into "FALSE POSITIVE: a guard that cries wolf gets
# switched off", which accuses the checker of a fault that is really the reader's
# own tree, and sends them after the wrong thing. Judged on what each mutation
# ADDS, the same dirty tree reports the truth: the pre-existing finding is
# section 1's business, and these five legs still answer their own question.
# Symmetrically, a "catch" leg must produce a NEW finding matching its needle —
# an offender that was already there must not be able to certify a mutation.
echo "-- 2. mutation battery: break it on purpose and watch it go red --"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
WORK="${TMP}/e2e"
mkdir -p "${WORK}"
cp -r "${E2E}/specs" "${E2E}/steps" "${WORK}/" 2>/dev/null

# Offenders go to stdout one per line; the `clean:` summary goes to stderr. So
# stdout alone IS the finding set, and an empty one means "no offenders".
BASE="${TMP}/baseline.txt"
BASE_ERR="${TMP}/baseline.err"
python3 "${CHECKER}" "${WORK}" >"${BASE}" 2>"${BASE_ERR}"
BASE_RC=$?
LC_ALL=C sort -o "${BASE}" "${BASE}"
BASE_N="$(wc -l <"${BASE}" | tr -d ' ')"
if [ "${BASE_RC}" -eq 2 ]; then
  # Without a baseline every leg below would silently compare against an empty
  # set and the three catch legs would read as "NOT caught". Say so once, here.
  bad "the battery's OWN baseline scan failed (exit 2) — no verdict below can mean anything:
$(sed 's/^/      /' "${BASE_ERR}")"
elif [ "${BASE_RC}" -eq 1 ]; then
  echo "  note the throwaway copy already carries ${BASE_N} finding(s); section 1 owns"
  echo "       those. Every leg below is judged on what it ADDS to that set."
fi

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
    bad "M:${label} — the mutation changed NOTHING, so this leg proved nothing.
       Either ${rel} drifted away from the shape this mutator edits, or the tree
       ALREADY carries the mutated state (e.g. the #305 import reverted by hand).
       Re-read the mutator against the file before trusting any other leg."
    return
  fi
  local mfile="${TMP}/mutant.txt"
  local added="${TMP}/added.txt"
  python3 "${CHECKER}" "${WORK}" >"${mfile}" 2>/dev/null
  local mrc=$?
  LC_ALL=C sort -o "${mfile}" "${mfile}"
  # comm -13 = lines in the MUTANT set that are not in the BASELINE set, i.e.
  # exactly the findings this mutation is responsible for.
  comm -13 "${BASE}" "${mfile}" >"${added}"
  local nadd
  nadd="$(wc -l <"${added}" | tr -d ' ')"
  mv "${f}.orig" "${f}"
  if [ "${expect}" = "catch" ]; then
    local hit
    hit="$(grep -a -- "${needle}" "${added}" | head -n1 || true)"
    if [ -n "${hit}" ]; then
      ok "M:${label} — caught (NEW finding: ${hit})"
    else
      bad "M:${label} — NOT caught: the mutation added ${nadd} finding(s) (rc=${mrc}),
       none of them matching '${needle}'. The guard is blind to this shape. Added:
$(sed 's/^/      /' "${added}")"
    fi
  else
    if [ "${nadd}" -eq 0 ]; then
      ok "M:${label} — correctly silent (a mention that is not a use; it added 0 findings)"
    else
      bad "M:${label} — FALSE POSITIVE: this mention is not a use, yet the checker
       ADDED ${nadd} finding(s) that the un-mutated copy did not have. A guard
       that cries wolf gets switched off. Added:
$(sed 's/^/      /' "${added}")"
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

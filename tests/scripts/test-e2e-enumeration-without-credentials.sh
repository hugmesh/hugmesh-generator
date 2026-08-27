#!/usr/bin/env bash
# test-e2e-enumeration-without-credentials.sh
#
# READING THE SUITE MUST NOT REQUIRE A SEEDED STACK.
#
# `playwright test --list` starts no browser and contacts nothing — it only
# imports the spec modules and reports what it found. The Studio's e2e feature
# tree is built on exactly that: an operator opens it to see WHAT the suite
# covers, typically before any mesh is up.
#
# sharedPassword() throws when nothing has seeded a credential, and that is
# correct — a guessable literal that still authenticates and goes green is the
# bug the random-per-run password work removed. The defect was WHERE it was
# called: at MODULE SCOPE, so the throw fired at IMPORT time and enumeration
# died with 0 suites and 21 errors on a tree nobody had seeded.
#
# This guard pins BOTH halves, because fixing either one alone is a regression:
#   1. enumeration works with NO credential anywhere, and
#   2. the no-literal contract still holds — a password is still resolved by
#      throwing, never by falling back to something guessable.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
E2E="${REPO}/tests/e2e"

P=0; F=0; S=0
ok()   { echo "  ok   $*"; P=$((P + 1)); }
bad()  { echo "  FAIL $*"; F=$((F + 1)); }
skip() { echo "  SKIP $*"; S=$((S + 1)); }

echo "== e2e enumeration without credentials =="

# ── 1. no module-scope credential resolution ─────────────────────────────────
# The static half: it runs everywhere, including CI images with no node_modules,
# where the runtime leg below cannot. A module-scope `const X = sharedPassword()`
# is the exact shape that broke enumeration.
echo "-- 1. no spec resolves a credential at module scope --"
scanned=0
offenders=""
while IFS= read -r f; do
  scanned=$((scanned + 1))
  # Module scope == column 0. An indented call is inside a function or a getter,
  # which is what we WANT, so anchor at the start of the line.
  hits="$(grep -nE '^(export )?(const|let|var) [A-Za-z_][A-Za-z0-9_]* *= *(sharedPassword|passwordFor|swarmPassword)\(' "$f" || true)"
  if [ -n "${hits}" ]; then
    offenders="${offenders}
    ${f#"${REPO}/"}:
$(echo "${hits}" | sed 's/^/      /')"
  fi
done < <(find "${E2E}/specs" "${E2E}/steps" -name '*.ts' -type f 2>/dev/null)

# VACUITY FLOOR: a find that matched nothing would report a clean pass forever.
if [ "${scanned}" -lt 20 ]; then
  bad "only ${scanned} .ts file(s) scanned under tests/e2e/{specs,steps} — expected 20+; the scan found nothing to check, so its verdict is meaningless"
elif [ -n "${offenders}" ]; then
  bad "credential resolved at MODULE SCOPE (fires at import, so --list dies):${offenders}
       => make it lazy: a function, a getter, or a default parameter (defaults
          evaluate at CALL time). See loginPassword() in specs/rbac-roles.ts."
else
  ok "${scanned} spec/step file(s) scanned, none resolves a credential at module scope"
fi

# ── 2. the no-literal contract still holds ───────────────────────────────────
# Making enumeration work by handing out a default password would "fix" leg 1
# and reintroduce the very bug the throw exists to prevent.
echo "-- 2. the contract: resolution still THROWS, never a literal --"
RR="${E2E}/specs/rbac-roles.ts"
if [ ! -f "${RR}" ]; then
  bad "specs/rbac-roles.ts is missing — cannot check the contract"
else
  body="$(awk '/^export function sharedPassword\(\)/,/^}/' "${RR}")"
  if [ -z "${body}" ]; then
    bad "could not extract sharedPassword() from rbac-roles.ts (shape drift?) — NOT asserting a contract we could not read"
  elif ! echo "${body}" | grep -q 'throw new Error'; then
    bad "sharedPassword() no longer throws — a resolution that cannot fail means something guessable now authenticates"
  elif echo "${body}" | grep -qE "\?\? *'[^']+'|\|\| *'[^']+'|return *'[^']+'"; then
    bad "sharedPassword() has a LITERAL fallback — that is the retired 'e2e-pass' bug returning:
$(echo "${body}" | grep -nE "\?\? *'[^']+'|\|\| *'[^']+'|return *'[^']+'" | sed 's/^/      /')"
  else
    ok "sharedPassword() still throws and carries no literal fallback"
  fi
fi

# ── 3. the real thing: enumerate with nothing seeded ─────────────────────────
# Needs an installed node_modules, which CI's shell-suite images do not carry.
# SKIPS LOUDLY there and is counted as a skip, never as a pass.
echo "-- 3. playwright --list with NO credential --"
NM="${E2E_NODE_MODULES:-${E2E}/node_modules}"
if [ ! -x "${NM}/.bin/playwright" ]; then
  skip "no Playwright at ${NM}/.bin/playwright — set E2E_NODE_MODULES=<installed tests/e2e/node_modules> to run the real enumeration leg (nothing in section 3 was asserted)"
else
  TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
  LIVE="${TMP}/live"; mkdir -p "${LIVE}"
  # A COPY, so a listing can never touch the repo's tests/e2e — and so the
  # helpers' walk-up for .e2e-credentials cannot reach the repo root either,
  # which is the whole point: this must work with nothing seeded anywhere.
  cp -r "${E2E}/specs" "${E2E}/reporters" "${E2E}/playwright.config.ts" \
        "${E2E}/package.json" "${LIVE}/" 2>/dev/null
  ln -snf "${NM}" "${LIVE}/node_modules"
  listing="${TMP}/listing.json"
  ( cd "${LIVE}" \
      && env -u E2E_PASSWORD -u E2E_CREDENTIALS_FILE \
             SNAP_REPORT_DIR="${TMP}/rep" SNAP_BASE_URL='https://127.0.0.1:1/' \
             ./node_modules/.bin/playwright test -c playwright.config.ts \
             --list --reporter=json ) >"${listing}" 2>"${TMP}/listing.err"
  rc=$?
  n="$(python3 - "${listing}" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print("%d %d" % (len(d.get("suites") or []), len(d.get("errors") or [])))
except Exception:
    print("-1 -1")
PY
)"
  suites="${n%% *}"; errs="${n##* }"
  if [ "${rc}" -ne 0 ]; then
    bad "playwright --list exited ${rc} with NO credential (suites=${suites} errors=${errs}) — enumeration must not need a seeded stack; first error:
$(python3 -c "
import json,sys
try:
    e=(json.load(open('${listing}')).get('errors') or [])
    print('      ' + ((e[0].get('message') or '').splitlines() or [''])[0][:200] if e else '      <none>')
except Exception: print('      <unreadable>')
")"
  elif [ "${suites:-0}" -lt 20 ]; then
    # An empty listing exits 0. Without this floor, deleting every spec passes.
    bad "playwright --list exited 0 but enumerated only ${suites} spec file(s) — expected 20+; an empty listing must not read as success"
  elif [ "${errs:-0}" -ne 0 ]; then
    bad "playwright --list enumerated ${suites} spec file(s) but reported ${errs} error(s) — a partial listing is not a pass"
  else
    ok "enumerated ${suites} spec file(s) with no credential, no browser and no stack"
  fi
fi

echo
echo "== ${P} passed, ${F} failed, ${S} skipped =="
[ "${F}" -eq 0 ] || exit 1
exit 0

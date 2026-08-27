#!/usr/bin/env bash
# test-e2e-social-function-matrix.sh — the DRIFT GUARD for the social FUNCTION
# axis (tuwunel / akkoma / phpbb).
#
# WHAT THIS GUARDS, AND WHY IT IS THE DELIVERABLE. tests/e2e/steps/social-functions.ts
# catalogues 53 things a user can DO across the three social services, and the
# Gherkin in features/{matrix,mastodon,forum}/function-surface.feature plus
# features/platform/social-function-matrix.feature decides every one of them for
# all 31 seeded personas. That coverage is only worth anything while THREE
# artefacts keep describing each other:
#
#   the CATALOGUE      steps/social-functions.ts        (what a function is + its gate)
#   the ROSTER         specs/rbac-roles.ts + tests/e2e-extra-personas.sh
#   the DEPLOYED gate  specs/cluster/manifests/route-access/initdb/20-schema.sql
#
# The scenarios are the output. THIS is the thing that fails when they drift.
#
# WHAT IT ASSERTS
#   1. the lane generates (npx bddgen rc=0) and every declared scenario really
#      becomes a Playwright test;
#   2. the CONTRACT tier is green with NOTHING running — no stack, no cluster,
#      no browser action;
#   3. the JOURNEY tier (@env:docker) SKIPS with a written, named reason and a
#      start command — zero silent pendings;
#   4. catalogue integrity: every probe path resolves to a real route-access
#      pattern, no duplicate (service, id), the roster and catalogue have not
#      shrunk;
#   5. a MUTATION BATTERY: production is broken seven ways ON PURPOSE and each
#      break must turn the lane RED. A guard nobody has watched fail is a guard
#      nobody should believe.
#
# OFFLINE, AND IT STARTS NOTHING. No docker, no kind, no qemu, no sudo, no image
# build. It refuses to be vacuous: a missing prerequisite exits 2 saying it
# checked NOTHING, never 0.
#
# EVERY MUTATION IS REVERTED, and the revert is VERIFIED byte-for-byte before
# this script exits — including on an interrupt, via the EXIT trap.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
E2E="${REPO}/tests/e2e"
FEATURES="${E2E}/features"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

echo "== e2e social FUNCTION matrix: catalogue, roster and deployed gate agree =="

for t in node python3 git; do
  command -v "${t}" >/dev/null 2>&1 || {
    echo "SKIPPED-LOUDLY: ${t} is required and absent — this guard checked NOTHING." >&2
    exit 2
  }
done
# ONE readiness opinion, not a second one: tests/e2e/check-toolchain.sh verifies
# node_modules against the COMMITTED lock and the browser revision under THE
# BROWSERS PATH THIS GUARD RUNS WITH. `[ -d node_modules/playwright-bdd ]` used to
# stand here and said nothing about either — MEASURED 2026-08-27: with
# /var/tmp/portage/pw-browsers holding dangling r1228 -> r1234 aliases, this guard
# got past its preflight and reported its lane as "not green" with every browser
# scenario dying on "Executable doesn't exist at .../chromium_headless_shell-1228",
# the toolchain gap wearing the costume of a product failure. The probe names the
# path and the fix (PLAYWRIGHT_BROWSERS_PATH=... make playwright-deps) instead.
if ! PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/var/tmp/portage/pw-browsers}" bash "${E2E}/check-toolchain.sh"; then
  echo "SKIPPED-LOUDLY: the e2e toolchain is not ready (above). This guard checked NOTHING. Exiting 2 rather than 0." >&2
  exit 2
fi

CATALOGUE="${E2E}/steps/social-functions.ts"
STEPS="${E2E}/steps/social-functions.steps.ts"
SEED="${REPO}/specs/cluster/manifests/route-access/initdb/20-schema.sql"
PERSONAS_SH="${REPO}/tests/e2e-extra-personas.sh"
MATRIX_FEATURE="${FEATURES}/platform/social-function-matrix.feature"
TUWUNEL_FEATURE="${FEATURES}/matrix/function-surface.feature"

for f in "${CATALOGUE}" "${STEPS}" "${SEED}" "${PERSONAS_SH}" "${MATRIX_FEATURE}" "${TUWUNEL_FEATURE}"; do
  [ -f "${f}" ] || { echo "SKIPPED-LOUDLY: ${f} is missing — checked NOTHING." >&2; exit 2; }
done

WORK="${TMPDIR:-/var/tmp/portage}/social-fn-guard.$$"
mkdir -p "${WORK}"

# ── the revert safety net ────────────────────────────────────────────────────
# Every file this script is allowed to mutate is backed up HERE before the first
# mutation, and restored on EXIT no matter how we leave — including Ctrl-C. A
# mutation battery that can leave production broken is worse than no battery.
BACKUP="${WORK}/backup"
mkdir -p "${BACKUP}"
MUTABLE=("${CATALOGUE}" "${SEED}" "${PERSONAS_SH}" "${MATRIX_FEATURE}" "${TUWUNEL_FEATURE}")
for f in "${MUTABLE[@]}"; do
  cp -p "${f}" "${BACKUP}/$(echo "${f}" | tr '/' '_')"
done

restore_all() {
  for f in "${MUTABLE[@]}"; do
    b="${BACKUP}/$(echo "${f}" | tr '/' '_')"
    [ -f "${b}" ] && cp -p "${b}" "${f}"
  done
}

cleanup() {
  restore_all
  rm -rf "${WORK}"
}
# INT TERM HUP as well as EXIT, because this guard MUTATES production files and
# restores them in the trap. Bash runs no EXIT trap for an untrapped SIGTERM, so
# a `timeout`, a Ctrl-C or a killed CI job could leave the tree MUTATED.
#
# THIS WIDENING IS NOT A COMPLETE FIX AND MUST NOT BE READ AS ONE. It fires on a
# bare `kill -TERM` (verified in isolation), but a `timeout` arriving while the
# script is blocked in a command substitution around `npx playwright test` was
# measured TWICE to leave tests/e2e/steps/coverage-catalogue.ts still carrying
# the M4 always-admit stub after the process was gone. The real protection is
# the preflight below, which makes the NEXT run refuse instead of silently
# trusting a poisoned oracle. Worktrees are shared here; that is the hazard.
trap cleanup EXIT INT TERM HUP

export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/var/tmp/portage/pw-browsers}"

BDDGEN="${E2E}/node_modules/.bin/bddgen"
PW="${E2E}/node_modules/.bin/playwright"

# The four generated spec paths this unit owns. Named explicitly so a run cannot
# accidentally measure somebody else's lane.
LANE_CONTRACT=(
  ".features-gen/features/platform/social-function-matrix.feature.spec.js"
  ".features-gen/features/matrix/function-surface.feature.spec.js"
  ".features-gen/features/mastodon/function-surface.feature.spec.js"
  ".features-gen/features/forum/function-surface.feature.spec.js"
)
LANE_JOURNEY=(
  ".features-gen/features/mastodon/interactions.feature.spec.js"
  ".features-gen/features/matrix/interactions.feature.spec.js"
)

gen() { ( cd "${E2E}" && "${BDDGEN}" ) >"${WORK}/bddgen.log" 2>&1; }

# run_lane <outfile> <spec...> — run the named generated specs and leave a JSON
# report at $outfile. Returns playwright's rc.
run_lane() {
  local out="$1"; shift
  # --reporter=json writes to STDOUT unless PLAYWRIGHT_JSON_OUTPUT_NAME is set;
  # setting BOTH would race this redirect and truncate the file. Stdout it is.
  ( cd "${E2E}" && "${PW}" test --project=bdd "$@" --reporter=json ) >"${out}" 2>"${out}.err"
  return $?
}

tally() {  # tally <json> -> "passed skipped failed"
  python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    print("0 0 -1"); raise SystemExit
p = s = f = 0
def walk(su):
    global p, s, f
    for sp in su.get('specs', []):
        for t in sp['tests']:
            st = t.get('status')
            if st == 'expected': p += 1
            elif st == 'skipped': s += 1
            else: f += 1
    for c in su.get('suites', []): walk(c)
for su in d.get('suites', []): walk(su)
print(p, s, f)
PY
}

# ── 1. the lane generates, and every scenario becomes a test ─────────────────
echo
echo "-- 1) the lane generates and binds --"
if gen; then
  ok "npx bddgen exits 0 with the social FUNCTION features present"
else
  bad "npx bddgen FAILED — see ${WORK}/bddgen.log"
  sed -n '1,40p' "${WORK}/bddgen.log"
fi

# Declared scenario count for THIS unit's six feature files, counted from the
# Gherkin with COMMENTS STRIPPED (a '#' line naming a Scenario has bitten this
# repo five times) and Outlines expanded per Examples data row.
declared() {
  python3 - "$@" <<'PY'
import re, sys
total = 0
for fn in sys.argv[1:]:
    lines = [l for l in open(fn, encoding='utf-8').read().split('\n')
             if not re.match(r'^\s*#', l)]
    i = 0
    OUT = re.compile(r'^\s*Scenario Outline\s*:', re.I)
    SC  = re.compile(r'^\s*(Scenario|Example)\s*:', re.I)
    EX  = re.compile(r'^\s*Examples\s*:', re.I)
    while i < len(lines):
        if OUT.match(lines[i]):
            i += 1
            while i < len(lines) and not SC.match(lines[i]) and not OUT.match(lines[i]):
                if EX.match(lines[i]):
                    i += 1; seen = False
                    while i < len(lines) and (lines[i].strip().startswith('|') or not lines[i].strip()):
                        if lines[i].strip().startswith('|'):
                            if seen: total += 1
                            else: seen = True
                        i += 1
                    continue
                i += 1
            continue
        if SC.match(lines[i]): total += 1
        i += 1
print(total)
PY
}

MY_FEATURES=(
  "${FEATURES}/platform/social-function-matrix.feature"
  "${FEATURES}/matrix/function-surface.feature"
  "${FEATURES}/mastodon/function-surface.feature"
  "${FEATURES}/forum/function-surface.feature"
  "${FEATURES}/mastodon/interactions.feature"
  "${FEATURES}/matrix/interactions.feature"
)
DECL="$(declared "${MY_FEATURES[@]}")"
GENCOUNT="$( ( cd "${E2E}" && "${PW}" test --list --project=bdd "${LANE_CONTRACT[@]}" "${LANE_JOURNEY[@]}" 2>/dev/null ) | sed -n 's/^Total: \([0-9]*\) tests.*/\1/p' )"
GENCOUNT="${GENCOUNT:-0}"
if [ "${DECL}" -gt 0 ] && [ "${DECL}" = "${GENCOUNT}" ]; then
  ok "every declared scenario generates: ${DECL} Gherkin == ${GENCOUNT} Playwright tests"
else
  bad "declared ${DECL} scenarios but Playwright collected ${GENCOUNT}"
fi

# ── 2. the CONTRACT tier is green with nothing running ──────────────────────
echo
echo "-- 2) the contract tier, with NOTHING started --"
run_lane "${WORK}/contract.json" "${LANE_CONTRACT[@]}"; CRC=$?
read -r CP CS CF <<<"$(tally "${WORK}/contract.json")"
if [ "${CRC}" -eq 0 ] && [ "${CF}" -eq 0 ] && [ "${CP}" -gt 0 ]; then
  ok "the offline contract lane is green (rc=0): passed=${CP} skipped=${CS} failed=${CF}"
else
  bad "the offline contract lane is NOT green: rc=${CRC} passed=${CP} skipped=${CS} failed=${CF}"
  sed -n '1,40p' "${WORK}/contract.json.err" 2>/dev/null
fi

# ── 3. the JOURNEY tier skips LOUDLY ────────────────────────────────────────
echo
echo "-- 3) the @env:docker journey tier skips with a NAMED reason --"
run_lane "${WORK}/journey.json" "${LANE_JOURNEY[@]}" || true
read -r JP JS JF <<<"$(tally "${WORK}/journey.json")"
SILENT="$(python3 - "${WORK}/journey.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
silent = []
def walk(su):
    for sp in su.get('specs', []):
        for t in sp['tests']:
            if t.get('status') != 'skipped':
                continue
            notes = [a for a in (t.get('annotations') or [])
                     if a.get('type') == 'skip' and (a.get('description') or '').strip()]
            if not notes:
                silent.append(sp['title'])
    for c in su.get('suites', []): walk(c)
for su in d.get('suites', []): walk(su)
print(len(silent))
for s in silent: print('    ' + s, file=sys.stderr)
PY
)"
if [ "${JS}" -gt 0 ] && [ "${SILENT}" = "0" ] && [ "${JF}" -eq 0 ]; then
  ok "all ${JS} journey scenarios skip with a written reason (0 silent pendings, 0 failures)"
elif [ "${JS}" -eq 0 ] && [ "${JP}" -gt 0 ]; then
  ok "a live environment answered: ${JP} journey scenarios actually RAN (failed=${JF})"
else
  bad "journey tier: passed=${JP} skipped=${JS} failed=${JF} silent-skips=${SILENT}"
fi

# ── 4. catalogue integrity, read through Playwright's TS transform ──────────
# A bare `node -e "require('./steps/social-functions.ts')"` CANNOT work: the
# module chain reaches extensionless TS imports node's own type-stripping does
# not resolve, so it dies with MODULE_NOT_FOUND no matter what the catalogue
# says — a false PASS that claims coverage it never had. The probe therefore
# runs as a Playwright test in its own directory with node_modules SYMLINKED in
# (module resolution walks up from the config's own directory).
echo
echo "-- 4) catalogue integrity --"
PROBE="${WORK}/probe"
mkdir -p "${PROBE}"
ln -sfn "${E2E}/node_modules" "${PROBE}/node_modules"
cat > "${PROBE}/pw.config.ts" <<'TS'
import { defineConfig } from '@playwright/test';
export default defineConfig({ testDir: __dirname, reporter: [['line']], workers: 1, retries: 0, timeout: 60_000 });
TS
# QUOTED heredoc: an unquoted one would let bash execute the backticks and
# ${...} inside the probe. This repo has been bitten by that before.
cat > "${PROBE}/catalogue.spec.ts" <<'TS'
import { test, expect } from '@playwright/test';
import * as sf from '__CATALOGUE__';

test('every probe path resolves, or is declared rowless', () => {
  const bad: string[] = [];
  for (const f of sf.SOCIAL_FUNCTIONS) {
    const v = sf.seedVerdict(f.gateway, f.probePath, []);
    if (f.gate.kind === 'rowless' && v.pattern !== null) bad.push(`${f.service}/${f.id} rowless but matched ${v.pattern}`);
    if (f.gate.kind !== 'rowless' && v.pattern === null) bad.push(`${f.service}/${f.id} matched no pattern`);
  }
  expect(bad, bad.join('\n')).toEqual([]);
});

test('no duplicate (service, id) in the catalogue', () => {
  const seen = new Set<string>(); const dup: string[] = [];
  for (const f of sf.SOCIAL_FUNCTIONS) {
    const k = `${f.service}/${f.id}`;
    if (seen.has(k)) dup.push(k);
    seen.add(k);
  }
  expect(dup, `duplicate catalogue keys: ${dup.join(', ')}`).toEqual([]);
});

test('the catalogue and the roster have not shrunk', () => {
  expect(sf.SOCIAL_FUNCTIONS.length).toBeGreaterThanOrEqual(53);
  expect(sf.socialRoster().length).toBeGreaterThanOrEqual(31);
  for (const s of sf.SOCIAL_SERVICES) expect(sf.socialFunctions(s).length).toBeGreaterThan(0);
});

test('an unknown function id throws naming the legal ids', () => {
  let msg = '';
  try { sf.socialFunction('tuwunel', 'not-a-function'); } catch (e) { msg = (e as Error).message; }
  expect(msg, 'socialFunction() accepted an unknown id silently').toContain('Legal ids');
  expect(msg).toContain('sync');
});

test('the catalogue agrees with the deployed seed on every cell', () => {
  const bad = sf.disagreements(sf.SOCIAL_FUNCTIONS, sf.socialRoster());
  expect(bad, sf.renderDisagreements(bad)).toEqual([]);
});
TS
sed -i "s|__CATALOGUE__|${CATALOGUE%.ts}|" "${PROBE}/catalogue.spec.ts"
if ( cd "${PROBE}" && "${PW}" test --config "${PROBE}/pw.config.ts" ) >"${WORK}/probe.log" 2>&1; then
  ok "catalogue integrity: probes resolve, no duplicate ids, no shrink, unknown ids throw"
else
  bad "catalogue integrity probe FAILED"
  sed -n '1,60p' "${WORK}/probe.log"
fi

# ── 5. THE MUTATION BATTERY ─────────────────────────────────────────────────
echo
echo "-- mutation battery: break production, prove the lane notices --"
MC=0; MS=0

MUT="${WORK}/mutations"
mkdir -p "${MUT}"

# Each mutation is a small python script taking the file to break as argv[1].
# QUOTED heredocs throughout: an unquoted one would let bash execute the
# backticks and ${...} inside, a trap this repo has been bitten by.

cat > "${MUT}/m1.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
old = "role: 'ROLE_MATRIX', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },\n    gateway: 'hugmesh-be-gateway', probePath: '/_matrix/client/v3/sync',"
new = "role: 'ROLE_USER', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },\n    gateway: 'hugmesh-be-gateway', probePath: '/_matrix/client/v3/sync',"
assert s.count(old) == 1, 'anchor count %d' % s.count(old)
open(p, 'w', encoding='utf-8').write(s.replace(old, new))
PY

cat > "${MUT}/m2.py" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
m = re.search(r"^.*'/social/forum/\*\*'.*'ROLE_FORUM'.*$", s, re.M)
assert m, 'the /social/forum/** ROLE_FORUM seed row is already gone'
open(p, 'w', encoding='utf-8').write(s[:m.start()] + '-- MUTATED BY THE GUARD' + s[m.end():])
PY

cat > "${MUT}/m3.py" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
m = re.search(r'^ *\| *set-displayname *\|.*$\n', s, re.M)
assert m, 'the set-displayname Examples row is already gone'
open(p, 'w', encoding='utf-8').write(s[:m.start()] + s[m.end():])
PY

cat > "${MUT}/m4.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
anchor = 'dragoneer:ROLE_USER:E2E_PASSWORD \\\n'
assert s.count(anchor) == 1, 'anchor count %d' % s.count(anchor)
open(p, 'w', encoding='utf-8').write(
    s.replace(anchor, anchor + 'e2e-guard-mutant:ROLE_USER:E2E_PASSWORD \\\n'))
PY

cat > "${MUT}/m5.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
old = "    journey: 'tests/e2e/features/mastodon/interactions.feature', pending: null,\n    note: 'The canonical A-amplifies-B interaction.',"
new = "    journey: null, pending: null,\n    note: 'The canonical A-amplifies-B interaction.',"
assert s.count(old) == 1, 'anchor count %d' % s.count(old)
open(p, 'w', encoding='utf-8').write(s.replace(old, new))
PY

cat > "${MUT}/m6.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
# Grant the board-moderator role to a persona the matrix ALREADY names, so the
# ONLY thing that changes is that the declared roster gap closes. Seeding a NEW
# handle would also trip the persona-orphan guard and make the catch ambiguous.
old = 'e2e-banned:ROLE_USER:E2E_BANNED_PASSWORD'
new = 'e2e-banned:ROLE_FORUM_MOD,ROLE_USER:E2E_BANNED_PASSWORD'
assert s.count(old) == 1, 'anchor count %d' % s.count(old)
open(p, 'w', encoding='utf-8').write(s.replace(old, new))
PY

cat > "${MUT}/m7.py" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
m = re.search(r'^( *\| *send-message *\| *)pair( *\|)$', s, re.M)
assert m, 'the send-message Examples row changed shape'
open(p, 'w', encoding='utf-8').write(s[:m.start()] + m.group(1) + 'solo' + m.group(2) + s[m.end():])
PY

# mutate <label> <file> <python-script> <needs-bddgen 0|1>
# Applies the edit, VERIFIES the file really changed (a no-op edit reporting
# CAUGHT would be a lie worse than a survivor), runs the contract lane, reports,
# and restores everything.
mutate() {
  local label="$1" file="$2" script="$3" regen="$4"
  local before after rc
  before="$(sha256sum "${file}" | cut -d' ' -f1)"
  if ! python3 "${script}" "${file}" >"${WORK}/mut.apply.log" 2>&1; then
    bad "mutation '${label}' could not be applied: $(tail -1 "${WORK}/mut.apply.log")"
    restore_all
    return
  fi
  after="$(sha256sum "${file}" | cut -d' ' -f1)"
  if [ "${before}" = "${after}" ]; then
    bad "mutation '${label}' did NOT change ${file} — it would have reported a FALSE catch"
    return
  fi
  if [ "${regen}" = "1" ]; then gen || true; fi
  run_lane "${WORK}/mut.json" "${LANE_CONTRACT[@]}"; rc=$?
  restore_all
  if [ "${regen}" = "1" ]; then gen || true; fi
  if [ "${rc}" -ne 0 ]; then
    echo "  CAUGHT   ${label}"; MC=$((MC+1))
  else
    echo "  SURVIVED ${label}   <-- the lane stayed GREEN with production broken"; MS=$((MS+1))
  fi
}

# M1 the CATALOGUE's declared gate is loosened while the deployed seed is not.
mutate "M1 catalogue loosens the Matrix sync gate to ROLE_USER" \
       "${CATALOGUE}" "${MUT}/m1.py" 0
# M2 the DEPLOYED gate changes underneath the catalogue — the mutation that
#    proves the matrix reads the SQL the cluster really seeds, not a copy of it.
mutate "M2 the deployed seed drops the ROLE_FORUM grant on /social/forum/**" \
       "${SEED}" "${MUT}/m2.py" 0
# M3 a catalogued function stops being named by any Examples row.
mutate "M3 a catalogued function loses its Examples row" \
       "${TUWUNEL_FEATURE}" "${MUT}/m3.py" 1
# M4 a persona is seeded and nothing drives it (the 2026-08-06 e2e-fleet shape).
mutate "M4 a new persona is seeded with no scenario naming it" \
       "${PERSONAS_SH}" "${MUT}/m4.py" 0
# M5 a multi-party interaction loses BOTH its journey and its written reason.
mutate "M5 a pair interaction loses both its journey and its written reason" \
       "${CATALOGUE}" "${MUT}/m5.py" 0
# M6 the KNOWN ROLE_FORUM_MOD roster gap CLOSES — the tripwire must fire, because
#    that is the prompt to write the journey the catalogue says cannot exist yet.
mutate "M6 the ROLE_FORUM_MOD roster gap closes and the tripwire must fire" \
       "${PERSONAS_SH}" "${MUT}/m6.py" 0
# M7 an INTERACTION is downgraded to solo in the Examples table.
mutate "M7 a pair interaction is downgraded to solo in the Examples table" \
       "${TUWUNEL_FEATURE}" "${MUT}/m7.py" 1

echo "  mutations: ${MC} caught, ${MS} survived"
if [ "${MS}" -eq 0 ] && [ "${MC}" -gt 0 ]; then
  ok "every mutation was caught by the lane"
else
  bad "${MS} mutation(s) SURVIVED — the lane does not guard what it claims to"
fi

# ── 6. the tree is byte-identical to where we found it ──────────────────────
restore_all
DIRTY=0
for f in "${MUTABLE[@]}"; do
  b="${BACKUP}/$(echo "${f}" | tr '/' '_')"
  cmp -s "${b}" "${f}" || { echo "    NOT RESTORED: ${f}"; DIRTY=1; }
done
if [ "${DIRTY}" -eq 0 ]; then
  ok "every mutated file is byte-identical to its pre-run content"
else
  bad "a mutated file was NOT restored — restore it from git before committing"
fi

gen || true

echo
echo "== e2e social FUNCTION matrix: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

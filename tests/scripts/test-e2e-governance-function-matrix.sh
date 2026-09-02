#!/usr/bin/env bash
# test-e2e-governance-function-matrix.sh — the gate for the governance FUNCTION tier.
#
# SIBLING TO test-e2e-gherkin-harness.sh and test-e2e-env-interface-dimensions.sh,
# not a replacement. Those prove every .feature generates and runs, and that the
# env/interface axes leave the right evidence. This one proves the thing built on
# top of them actually decides something:
#
#   1. the governance lane GENERATES and runs GREEN with NOTHING started, and
#      every skip carries a named reason (no silent pendings);
#   2. the matrix is not vacuous — 34 identities x 33 functions = 1122 decisions,
#      with BOTH admissions and refusals present, and zero disagreement between
#      the catalogue's hand-declared keying and the shipped route-access seed;
#   3. the transcribed decision engine is EXECUTED against the real oracle over
#      thousands of triples (a transcription that is never run against its source
#      drifts silently — that bug already shipped once here);
#   4. two INDEPENDENT parsers of 20-schema.sql (the TypeScript catalogue and
#      tests/scripts/governance-route-rows.sh) agree on the row count, so a
#      parser that stops matching cannot take the whole matrix quiet;
#   5. the drift guard bites: a catalogued function, identity or console that no
#      scenario reaches turns the lane RED.
#
# MUTATION BATTERY. Checks 1-5 are re-run with production DELIBERATELY BROKEN,
# NINE ways, and each must turn the lane RED. A guard that has never been seen to
# fail is a guard nobody has tested. Every mutation is applied to the REAL tree in
# THIS WORKTREE with a backup, is PROVEN to have changed the file, and the tree is
# restored on EXIT via trap — the final check asserts the byte fingerprint matches
# what it was before the run, so a half-restored tree is a failure rather than a
# surprise for whoever runs next.
#
# FILES THE BATTERY TOUCHES (all restored, all verified):
#   specs/cluster/manifests/route-access/initdb/20-schema.sql
#   tests/e2e/specs/rbac-route-access.ts
#   tests/e2e/specs/rbac-route-access.seed.ts   (M8's target since main GENERATED it)
#   tests/e2e/specs/rbac-roles.ts
#   tests/e2e-extra-personas.sh
#   tests/e2e/steps/governance.ts
#   tests/e2e/features/rbac/governance-function-matrix.feature
#
# OFFLINE. Starts NOTHING: no stack, no cluster, no emulator, no image build, no
# sudo. Every assertion is a pure function over files that ship in the repo, so
# the pass condition is the same with all three environments down.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
E2E="${REPO}/tests/e2e"
LANE=".features-gen/features/rbac/governance"
SEED="specs/cluster/manifests/route-access/initdb/20-schema.sql"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

echo "== e2e governance FUNCTION matrix: consoles, tiers, refusals, drift =="

# ── preconditions: refuse to be vacuous ──────────────────────────────────────
for t in node python3 git bash md5sum; do
  command -v "${t}" >/dev/null 2>&1 || {
    echo "SKIPPED-LOUDLY: ${t} is required and absent — this guard checked NOTHING." >&2
    exit 2
  }
done
# ONE readiness opinion, not a second one: tests/e2e/check-toolchain.sh verifies
# node_modules against the COMMITTED lock and the browser revision under the
# SAME resolution the lane runs with — the caller's PLAYWRIGHT_BROWSERS_PATH if
# they set it, otherwise Playwright's own store (~/.cache/ms-playwright).
# `[ -d node_modules/playwright-bdd ]` used to stand here and said nothing about
# either — MEASURED 2026-08-27: with /var/tmp/portage/pw-browsers holding
# dangling r1228 -> r1234 aliases, this guard got past its preflight and
# reported its lane as "not green" with every browser scenario dying on
# "Executable doesn't exist", the toolchain gap wearing the costume of a
# product failure.
# This guard NEVER defaults PLAYWRIGHT_BROWSERS_PATH. Until
# fix/pw-browsers-never-default it pinned /var/tmp/portage/pw-browsers when the
# variable was unset — a host-local farm of symlinks into
# ~/.cache/ms-playwright that DANGLES after any `npx playwright install`
# garbage-collects the revision it points at (see
# reference_hugmesh_pw_browsers_symlink_farm) — so on a box whose real store
# was READY it manufactured a red toolchain verdict, and its fix line told the
# operator to reinstall INTO the farm. Probe under caller resolution instead,
# exactly as test-e2e-coverage-matrix.sh does; the one-launch preflight below
# proves a browser actually starts before the lane may.
if ! bash "${E2E}/check-toolchain.sh"; then
  echo "SKIPPED-LOUDLY: the e2e toolchain is not ready (above). This guard checked NOTHING. Exiting 2 rather than 0." >&2
  exit 2
fi

# ── PREFLIGHT: ONE REAL LAUNCH BEFORE THE LANE MAY TRY ───────────────────────
# One page.goto('about:blank') through the SAME resolution the lane uses
# (ported from test-e2e-coverage-matrix.sh). When the browser cannot launch,
# every scenario fails the same way and the run reads like a product collapse
# when it is a toolchain gap. Refuse in seconds instead.
PWPRE="$(mktemp -d "${TMPDIR:-/tmp}/pw-preflight.XXXXXX")"
# node_modules SYMLINKED beside the config: module resolution walks up from the
# CONFIG's own directory, so a bare scratch dir cannot even import
# '@playwright/test'. MEASURED 2026-09-01 on a READY toolchain: without this
# link the preflight died on "Cannot find module '@playwright/test' ... Require
# stack: /tmp/pw-preflight.*/pw.config.ts" — a preflight failing for its OWN
# reasons is exactly the false red it exists to prevent. outputDir lives inside
# the scratch dir too: Playwright otherwise writes test-results/.last-run.json
# relative to the invoking cwd. rm -rf below unlinks the symlink, never its target.
ln -sfn "${E2E}/node_modules" "${PWPRE}/node_modules"
cat > "${PWPRE}/pw.config.ts" <<'TS'
import { defineConfig } from '@playwright/test';
import * as path from 'node:path';
export default defineConfig({
  testDir: __dirname, outputDir: path.join(__dirname, 'pw-out'),
  reporter: [['line']], workers: 1, retries: 0, timeout: 120_000,
});
TS
cat > "${PWPRE}/preflight.spec.ts" <<'TS'
import { test } from '@playwright/test';
test('the browser launches', async ({ page }) => { await page.goto('about:blank'); });
TS
if ! ( cd "${PWPRE}" && npx --prefix "${E2E}" playwright test -c "${PWPRE}/pw.config.ts" preflight.spec.ts --reporter=line ) \
     > "${PWPRE}/preflight.out" 2>&1; then
  echo "SKIPPED-LOUDLY: the browser cannot launch — one page.goto('about:blank') failed:" >&2
  sed -n '1,25p' "${PWPRE}/preflight.out" >&2
  echo "" >&2
  echo "PLAYWRIGHT_BROWSERS_PATH is ${PLAYWRIGHT_BROWSERS_PATH:-unset (playwright resolves its own store)} — if you set" >&2
  echo "it, unset it or point it at a store that actually holds this playwright's" >&2
  echo "revision. Install with: make playwright-deps" >&2
  echo "  [or: (cd tests/e2e && npx playwright install chromium)]" >&2
  echo "This guard checked NOTHING — the lane would have failed every scenario on" >&2
  echo "the toolchain, not on the product. Exiting 2 rather than 0 or a false red." >&2
  rm -rf "${PWPRE}"
  exit 2
fi
rm -rf "${PWPRE}"
[ -f "${REPO}/${SEED}" ] || {
  echo "SKIPPED-LOUDLY: the AUTHORITATIVE route-access seed ${SEED} is missing." >&2
  echo "The whole FUNCTION tier decides against it. Exiting 2." >&2
  exit 2
}

WORK="${TMPDIR:-/var/tmp/portage}/gov-matrix-guard.$$"
mkdir -p "${WORK}"

# Byte fingerprint of everything the battery may touch, taken BEFORE anything is
# broken. The last check diffs against this.
MUTABLE=(
  "${SEED}"
  "tests/e2e/specs/rbac-route-access.ts"
  "tests/e2e/specs/rbac-route-access.seed.ts"
  "tests/e2e/specs/rbac-roles.ts"
  "tests/e2e-extra-personas.sh"
  "tests/e2e/steps/governance.ts"
  "tests/e2e/steps/governance.steps.ts"
  "tests/e2e/features/rbac/governance-function-matrix.feature"
  "tests/e2e/features/rbac/governance-tier-refusal.feature"
  "tests/e2e/features/rbac/governance-drift-guard.feature"
  "tests/e2e/features/rbac/governance-evidence-environments.feature"
)
fingerprint() { ( cd "${REPO}" && md5sum "${MUTABLE[@]}" ); }
fingerprint > "${WORK}/before.md5"

BACKUP="${WORK}/backup"; mkdir -p "${BACKUP}"
MUTATED=()
save_file() {
  local rel="$1" dest
  dest="${BACKUP}/$(echo "${rel}" | tr '/' '_')"
  [ -f "${dest}" ] || cp "${REPO}/${rel}" "${dest}"
  MUTATED+=("${rel}")
}
restore_all() {
  local rel dest
  for rel in "${MUTATED[@]+"${MUTATED[@]}"}"; do
    dest="${BACKUP}/$(echo "${rel}" | tr '/' '_')"
    [ -f "${dest}" ] && cp "${dest}" "${REPO}/${rel}"
  done
  MUTATED=()
}
cleanup() { restore_all; rm -rf "${WORK}"; }
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

# mutate <relpath> — reads a python patch on stdin and PROVES the file changed.
# A mutation that silently failed to apply would make this guard look like it
# caught something it never saw.
mutate() {
  local rel="$1" before after
  before="$(md5sum "${REPO}/${rel}" | cut -d' ' -f1)"
  save_file "${rel}"
  python3 - "${REPO}/${rel}" || { echo "    !! patch script failed for ${rel}" >&2; return 1; }
  after="$(md5sum "${REPO}/${rel}" | cut -d' ' -f1)"
  if [ "${before}" = "${after}" ]; then
    echo "    !! mutation did NOT change ${rel} — the guard would be testing nothing" >&2
    return 1
  fi
  return 0
}

# pw runs a tool from E2E with the browser resolved exactly as the caller's
# environment does — PLAYWRIGHT_BROWSERS_PATH is never defaulted (see the
# preflight above, which proved that resolution launches).
pw() { ( cd "${E2E}" && "$@" ); }

regen() { ( cd "${E2E}" && ./node_modules/.bin/bddgen >"${WORK}/bddgen.out" 2>&1 ); }

# run_lane <label> -> echoes the playwright exit code, writes $WORK/<label>.json
run_lane() {
  local label="$1"
  ( cd "${E2E}" && \
    SNAP_REPORT_DIR="${WORK}/${label}" \
    SNAP_RUN_ID="${label}" \
    PLAYWRIGHT_JSON_OUTPUT_NAME="${WORK}/${label}.json" \
    ./node_modules/.bin/playwright test --project=bdd --retries=0 --reporter=json "${LANE}" \
      >"${WORK}/${label}.out" 2>&1 )
  echo "$?"
}

# ── 0. generation ────────────────────────────────────────────────────────────
if regen; then
  ok "npx bddgen exits 0 with the governance function tier present"
else
  bad "npx bddgen FAILED — see ${WORK}/bddgen.out"
  sed -n '1,20p' "${WORK}/bddgen.out" >&2
fi

GEN_COUNT="$(find "${E2E}/.features-gen/features/rbac" -name 'governance-*.spec.js' 2>/dev/null | wc -l)"
if [ "${GEN_COUNT}" -eq 4 ]; then
  ok "all 4 governance feature files generated"
else
  bad "expected 4 generated governance specs, found ${GEN_COUNT} — a .feature that stops generating is invisible, not red"
fi

# ── 1. the lane is green with NOTHING started, and no skip is silent ─────────
BASE_RC="$(run_lane baseline)"
if [ "${BASE_RC}" -eq 0 ]; then
  ok "the governance lane is green (rc=0) with NOTHING started"
else
  bad "baseline lane rc=${BASE_RC} (expected 0) — see ${WORK}/baseline.out"
  grep -viE 'npm notice' "${WORK}/baseline.out" | tail -25 >&2
fi

cat > "${WORK}/analyse.py" <<'PY'
import json, os, sys

report, ledger_dir, mode = sys.argv[1], sys.argv[2], sys.argv[3]
problems, notes = [], []

def specs(node):
    for s in node.get('suites', []) or []:
        yield from specs(s)
    for sp in node.get('specs', []) or []:
        yield sp

try:
    rep = json.load(open(report))
except Exception as e:
    print("ANALYSE-ERROR cannot read report %s: %s" % (report, e))
    sys.exit(3)

passed = skipped = failed = 0
silent = []
for root in rep.get('suites', []):
    for sp in specs(root):
        for t in sp.get('tests', []):
            st = t['results'][0]['status']
            if st == 'skipped':
                skipped += 1
                reason = ' '.join(
                    a.get('description') or '' for a in (t.get('annotations') or []))
                if not reason.strip():
                    silent.append(sp['title'])
            elif st in ('passed', 'expected'):
                passed += 1
            else:
                failed += 1

notes.append("passed=%d skipped=%d failed=%d" % (passed, skipped, failed))
if silent:
    problems.append("SILENT SKIP (no reason recorded): %s" % '; '.join(silent[:5]))

def ledger(name):
    p = os.path.join(ledger_dir, name + '.json')
    if not os.path.exists(p):
        problems.append("ledger %s.json was never written — the scenario that writes it did not run" % name)
        return None
    try:
        return json.load(open(p))
    except Exception as e:
        problems.append("ledger %s.json is not JSON: %s" % (name, e))
        return None

if mode == 'full':
    if passed < 150:
        problems.append("only %d scenarios passed; the governance lane is >= 150" % passed)

    m = ledger('matrix')
    if m is not None:
        notes.append("matrix cells=%d allow=%d deny=%d identities=%d functions=%d"
                     % (m['cells'], m['allow'], m['deny'], m['identities'], m['functions']))
        if m['cells'] != m['identities'] * m['functions']:
            problems.append("matrix is not a full cross product: %d cells for %d x %d"
                            % (m['cells'], m['identities'], m['functions']))
        if m['cells'] < 1000:
            problems.append("matrix decided only %d cells" % m['cells'])
        if m['allow'] == 0 or m['deny'] == 0:
            problems.append("matrix is degenerate: allow=%d deny=%d" % (m['allow'], m['deny']))
        if m['mismatches']:
            problems.append("matrix mismatches: %s" % m['mismatches'][:3])

    e = ledger('engine-equivalence')
    if e is not None:
        notes.append("engine equivalence triples=%d disagreements=%d"
                     % (e['triples'], len(e['disagreements'])))
        if e['triples'] < 1000:
            problems.append("equivalence corpus is only %d triples" % e['triples'])
        if e['disagreements']:
            problems.append("engine disagreements: %s" % e['disagreements'][:2])

    g = ledger('mirror-gaps')
    if g is not None:
        notes.append("seed rows=%d mirror rows=%d unmirrored governance patterns=%d"
                     % (g['seedRows'], g['mirrorRows'], len(g['gaps'])))

    o = ledger('mirror-overgrants')
    if o is not None and o['overGrants']:
        problems.append("mirror over-grants: %s" % o['overGrants'][:2])

    d = ledger('drift-functions')
    if d is not None:
        notes.append("drift: %d functions checked across %d feature files"
                     % (d['functions'], d['featureFiles']))
        if d['missing']:
            problems.append("unexercised functions: %s" % d['missing'][:3])

    i = ledger('drift-identities')
    if i is not None and i['missing']:
        problems.append("unexercised identities: %s" % i['missing'][:3])

    s = ledger('swarm-representation')
    if s is not None:
        notes.append("swarm representatives=%d uncovered=%d"
                     % (len(s['representatives']), len(s['uncovered'])))

print("NOTES " + " | ".join(notes))
for p in problems:
    print("PROBLEM " + p)
sys.exit(1 if problems else 0)
PY

analyse() {
  python3 "${WORK}/analyse.py" "${WORK}/$1.json" "${WORK}/$1/governance-ledger/$1" "$2" \
    > "${WORK}/$1.analysis" 2>&1
  local rc=$?
  sed -n 's/^NOTES /       /p' "${WORK}/$1.analysis"
  return ${rc}
}

if analyse baseline full; then
  ok "the governance matrix is complete, non-degenerate, and agrees with the seed"
else
  bad "baseline analysis found problems:"
  sed -n 's/^PROBLEM /       /p' "${WORK}/baseline.analysis" >&2
fi

# ── 2. two INDEPENDENT readings of the seed agree ────────────────────────────
# tests/scripts/governance-route-rows.sh parses 20-schema.sql in python; the
# TypeScript catalogue parses it again in node. If those two ever disagree about
# how many rows the file holds, one of them has silently stopped matching — and
# the one that stops matching is the one that makes every DENY pass for free.
CLI_ROWS="$(bash "${REPO}/tests/scripts/governance-route-rows.sh" 2>/dev/null \
            | python3 -c 'import json,sys; print(json.load(sys.stdin)["totalRows"])' 2>/dev/null)"
TS_ROWS="$(python3 -c "
import json,sys
d=json.load(open('${WORK}/baseline/governance-ledger/baseline/mirror-gaps.json'))
print(d['seedRows'])
" 2>/dev/null)"
if [ -n "${CLI_ROWS}" ] && [ "${CLI_ROWS}" = "${TS_ROWS}" ]; then
  ok "two independent parsers agree the seed holds ${CLI_ROWS} route rows"
else
  bad "seed row count DISAGREES: governance-route-rows.sh says '${CLI_ROWS}', the TypeScript catalogue says '${TS_ROWS}'"
fi

CLI_JSON_RC=0
bash "${REPO}/tests/scripts/governance-route-rows.sh" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["governancePatterns"] > 10 else 1)' \
  || CLI_JSON_RC=$?
if [ "${CLI_JSON_RC}" -eq 0 ]; then
  ok "the CLI governance view emits one line of JSON naming >10 governance patterns"
else
  bad "the CLI governance view did not emit usable JSON (rc=${CLI_JSON_RC})"
fi

# ── 3. THE MUTATION BATTERY ──────────────────────────────────────────────────
echo "-- mutation battery (each must turn the governance lane RED) --"
CAUGHT=0; SURVIVED=0

# expect_red <label> <description>
expect_red() {
  local label="$1" desc="$2" rc
  regen >/dev/null 2>&1
  rc="$(run_lane "${label}")"
  if [ "${rc}" -ne 0 ]; then
    echo "  CAUGHT ${label}: ${desc}"
    CAUGHT=$((CAUGHT+1))
  else
    echo "  SURVIVED ${label}: ${desc} — the lane stayed GREEN"
    SURVIVED=$((SURVIVED+1))
  fi
  restore_all
  regen >/dev/null 2>&1
}

# M1 — WIDEN the seed: give ROLE_ADMIN a browser row under the superadmin prefix.
#      The exact down-cascade the superadmin tier exists to forbid.
if mutate "${SEED}" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
anchor = "  ('hugmesh-fe-gateway',  '/bff/admin/**',"
i = s.index(anchor)
s = s[:i] + "  ('hugmesh-fe-gateway',  '/bff/superadmin/**',      'ROLE_ADMIN',       true),\n" + s[i:]
open(p, 'w').write(s)
PY
then expect_red M1 "seed widened: fe-gateway /bff/superadmin/** granted to ROLE_ADMIN"
else bad "M1 could not be applied"; fi

# M2 — NARROW the seed: drop the ROLE_FLEET_ADMIN row, the only one in the mesh.
if mutate "${SEED}" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
s2 = re.sub(r"\n\s*\('hugmesh-fe-gateway',\s*'/bff/admin/phone-fleet/\*\*',\s*'ROLE_FLEET_ADMIN'[^\n]*", "", s, count=1)
assert s2 != s, "the ROLE_FLEET_ADMIN row was not found"
open(p, 'w').write(s2)
PY
then expect_red M2 "seed narrowed: the only ROLE_FLEET_ADMIN row deleted"
else bad "M2 could not be applied"; fi

# M3 — THE TRANSCRIPTION TRAP: measure a glob the way a transcriber slips.
#      Identical for glob-vs-glob, INVERTED for exact-vs-glob.
#
#      RE-BASED 2026-08-26. It used to patch "prefix.length * 2" -> "pattern.length
#      * 2", which was the exact bug fix/superadmin-route-access-row found. main
#      then rewrote the oracle to score by the RAW url_pattern length, patternScore
#      was re-transcribed to match, and that string stopped existing — the mutation
#      died with "M3 could not be applied", which is a mutation proving NOTHING and
#      it took the battery's CAUGHT>=9 floor down with it. The slip is the same slip
#      re-based on the current formula: measure the STRIPPED prefix instead of the
#      pattern. '/api/federation/vanity/**' then scores 22 rather than 25 and ties
#      with the literal '/api/federation/vanity', so both rows land at the winning
#      pattern and a ROLE_USER caller is admitted where the oracle admits only
#      ROLE_SUPERADMIN.
if mutate "tests/e2e/steps/governance.ts" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = """  if (pattern.endsWith('/**')) {
    const prefix = pattern.slice(0, -3);
    const matched = p === prefix || p.startsWith(prefix + '/');
    return { matched, specificity: matched ? score : -1 };
  }"""
new = """  if (pattern.endsWith('/**')) {
    const prefix = pattern.slice(0, -3);
    const matched = p === prefix || p.startsWith(prefix + '/');
    return { matched, specificity: matched ? prefix.length : -1 };
  }"""
assert old in s
open(p, 'w').write(s.replace(old, new, 1))
PY
then expect_red M3 "decision engine: glob specificity measured from the STRIPPED prefix (inverts exact-vs-glob only)"
else bad "M3 could not be applied"; fi

# M4 — DRIFT: a catalogued function no scenario reaches. The whole point of the
#      guard: adding a catalogue row must not silently read as coverage.
if mutate "tests/e2e/steps/governance.ts" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
anchor = "];\n\nconst FN_BY_ID"
extra = """  {
    id: 'mutation-probe-surface', name: 'a function nothing tests',
    console: 'admin', gateway: 'hugmesh-fe-gateway',
    probePath: '/bff/admin/usage-mutation-probe', governingPattern: '/bff/admin/**',
    keyedOn: ['ROLE_ADMIN'],
    note: 'INSERTED BY THE MUTATION BATTERY — must never survive a run.',
  },
"""
i = s.index(anchor)
open(p, 'w').write(s[:i] + extra + s[i:])
PY
then expect_red M4 "catalogue drift: a governance function no scenario names"
else bad "M4 could not be applied"; fi

# M5 — DRIFT, identity side: a seeded persona no scenario names.
if mutate "tests/e2e-extra-personas.sh" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "dragoneer:ROLE_USER:E2E_PASSWORD \\\n"
assert old in s
open(p, 'w').write(s.replace(old, old + "mutation-probe-persona:ROLE_ADMIN,ROLE_USER:E2E_PASSWORD \\\n", 1))
PY
then expect_red M5 "roster drift: a seeded identity no scenario names"
else bad "M5 could not be applied"; fi

# M6 — COMMENT-TOKEN INVERSION. Demote a function's real Examples rows to a
#      comment. If the drift guard counted comments, this would stay GREEN — the
#      exact false green this repo has produced five times.
if mutate "tests/e2e/features/rbac/governance-function-matrix.feature" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
before = s
for row in ("      | e2e-admin | ALLOW    | wiki-admin       |\n",
            "      | e2e-mod   | DENY     | wiki-admin       |\n"):
    assert row in s, row
    s = s.replace(row, "      # " + row.strip() + "\n", 1)
assert s != before
open(p, 'w').write(s)
PY
then expect_red M6 "comment-token inversion: wiki-admin named ONLY inside a comment"
else bad "M6 could not be applied"; fi

# M7 — SUBSTRING FALSE-GREEN. Remove EVERY direct naming of admin-workload-console
#      from BOTH governance features, leaving it present only as a substring of
#      superadmin-workload-console. A plain includes() would certify it as covered.
#      (The first cut of this mutation edited ONE file and the id survived in the
#      other, so the battery reported a SURVIVOR that was the mutation's fault and
#      not the guard's. Both files, or the mutation proves nothing.)
M7_OK=1
for M7F in tests/e2e/features/rbac/governance-function-matrix.feature \
           tests/e2e/features/rbac/governance-tier-refusal.feature; do
  mutate "${M7F}" <<'M7PY' || M7_OK=0
import sys
p = sys.argv[1]; s = open(p).read()
out, dropped = [], 0
for line in s.split('\n'):
    st = line.strip()
    if st.startswith('|') and 'admin-workload-console' in st and 'superadmin-workload-console' not in st:
        dropped += 1
        continue
    out.append(line)
assert dropped >= 1, "no admin-workload-console row found in %s" % p
open(p, 'w').write('\n'.join(out))
M7PY
done
if [ "${M7_OK}" -eq 1 ]; then
  expect_red M7 "substring false-green: admin-workload-console left only as a substring of the superadmin one"
else
  bad "M7 could not be applied"
  restore_all; regen >/dev/null 2>&1
fi

# M8 — MIRROR OVER-GRANT, the dangerous direction: the TS mirror grants a route
#      the shipped seed does not, so an ALLOW would certify a shut door.
#
#      THE TARGET FILE MOVED (2026-08-26). specs/rbac-route-access.ts used to hold
#      the rows inline and this mutation anchored on its "  // superadmin-gateway"
#      comment. main then split the oracle: rbac-route-access.ts re-exports the
#      GENERATED rbac-route-access.seed.ts, that comment is in neither file, and
#      the patch died with "substring not found" — an unapplied mutation proves
#      nothing and silently dropped the battery below its CAUGHT floor. The anchor
#      is now the generated array's opening line, and the row carries `allow`
#      because RouteRule requires it.
if mutate "tests/e2e/specs/rbac-route-access.seed.ts" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
anchor = "export const ROUTE_ACCESS_SEED: readonly RouteRule[] = [\n"
i = s.index(anchor) + len(anchor)
extra = ("  { gateway: 'hugmesh-fe-gateway', urlPattern: '/mutation-probe/**', "
         "role: 'ROLE_USER', allow: true },\n")
open(p, 'w').write(s[:i] + extra + s[i:])
PY
then expect_red M8 "route mirror grants /mutation-probe/** which the shipped seed does not"
else bad "M8 could not be applied"; fi

# M9 — SWARM REPRESENTATION. Give one swarm member a role its tier representative
#      does not hold, so the 3-stands-for-126 shortcut silently loses coverage.
if mutate "tests/e2e/specs/rbac-roles.ts" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "      roles: ['ROLE_USER', 'ROLE_MATRIX', 'ROLE_MASTODON'],"
assert old in s
new = "      roles: i === 7 ? ['ROLE_USER', 'ROLE_MATRIX', 'ROLE_MASTODON', 'ROLE_ADMIN'] : ['ROLE_USER', 'ROLE_MATRIX', 'ROLE_MASTODON'],"
open(p, 'w').write(s.replace(old, new, 1))
PY
then expect_red M9 "swarm member 007 given ROLE_ADMIN; its tier representative no longer stands for it"
else bad "M9 could not be applied"; fi

echo "  mutations: ${CAUGHT} caught, ${SURVIVED} survived"
if [ "${SURVIVED}" -eq 0 ] && [ "${CAUGHT}" -ge 9 ]; then
  ok "every designed mutation turned the governance lane RED"
else
  bad "${SURVIVED} mutation(s) SURVIVED — those defects would ship green"
fi

# ── 4. the tree is exactly as we found it ────────────────────────────────────
fingerprint > "${WORK}/after.md5"
if diff -q "${WORK}/before.md5" "${WORK}/after.md5" >/dev/null 2>&1; then
  ok "every mutation was reverted (the mutable set is byte-identical to pre-run)"
else
  bad "THE TREE WAS LEFT MUTATED — diff:"
  diff "${WORK}/before.md5" "${WORK}/after.md5" >&2 || true
fi

# ── 5. the lane is green again after the battery ─────────────────────────────
FINAL_RC="$(run_lane final)"
if [ "${FINAL_RC}" -eq 0 ] && analyse final full; then
  ok "the governance lane is green again after the battery"
else
  bad "the lane did not recover (rc=${FINAL_RC}) — see ${WORK}/final.out"
  sed -n 's/^PROBLEM /       /p' "${WORK}/final.analysis" 2>/dev/null >&2
fi

echo "== e2e governance FUNCTION matrix: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

#!/usr/bin/env bash
# test-e2e-func-media-games.sh — the gate for the FUNCTION axis of owncast, tube,
# games, character-studio and character-forge.
#
# THIRD SIBLING. test-e2e-gherkin-harness.sh proves every .feature generates and
# runs. test-e2e-env-interface-dimensions.sh proves the env/interface axes mean
# something. This one proves the FUNCTION census and the derived access matrix
# are load-bearing rather than decorative:
#
#   1. the whole media/games function lane is GREEN with nothing started — it is
#      offline by construction, so a red here is a real regression and never
#      "the stack is down";
#   2. every catalogued function is named by a scenario (the census), and the
#      census can actually FAIL;
#   3. the access matrix is DERIVED from the two seeded rosters, so seeding one
#      more persona moves it — that is the generative half of the coverage and
#      the mutation battery proves it moves;
#   4. the three-way agreement between a feature file, the function catalogue and
#      the committed route-access seed really is three-way: breaking ANY ONE of
#      the three turns the lane red;
#   5. the cli and studio scenarios in this domain produce real evidence rows.
#
# MUTATION BATTERY. Eight mutations, applied to the REAL tree with a backup and
# restored by an EXIT trap. Each must turn the lane RED; each is verified to have
# actually changed the file (a mutation that silently did nothing would "pass"
# by proving the guard notices a change that was never made). The final check
# asserts the tree is byte-identical to how it started.
#
# OFFLINE. Starts NOTHING: no stack, no cluster, no emulator, no image build.
#
# NOT IN .github/workflows/shell-suites.yml, deliberately. That job runs on the
# `bash:5` image and this script needs node + the Playwright install + a Qt6
# binding for the studio leg — the same reason test-e2e-gherkin-harness.sh and
# test-e2e-env-interface-dimensions.sh are not in it either. It belongs wherever
# `make playwright-deps` has run; wiring all three together is an integration job,
# not this unit's to do unilaterally.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
E2E="${REPO}/tests/e2e"

# PRECONDITIONS: refuse to be RED for the wrong reason, and never to be green for
# no reason. MEASURED at the 2026-08-26 integration with tests/e2e/node_modules
# moved aside: this suite was the ONLY one of the nine e2e guards without this
# block, and it exited 1 — indistinguishable from a real drift finding — where its
# eight siblings exit 2 naming the missing install. Its own header already said it
# "needs node + the Playwright install + a Qt6 binding"; this is that sentence made
# executable. Exit 2 is never mistaken for a pass and never mistaken for a failure.
for t in node python3 git; do
  command -v "${t}" >/dev/null 2>&1 || {
    echo "SKIPPED-LOUDLY: ${t} is required and absent — this guard checked NOTHING." >&2
    echo "Exiting 2 rather than 0." >&2
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
  // The SAME launch flags tests/e2e/playwright.config.ts gives the lane. A bare
  // config would ask a DIFFERENT question than the lane does: on a box with no
  // user namespaces (root, or a hardened container) chromium refuses to start
  // without --no-sandbox, so the preflight would manufacture an exit-2 for a
  // browser the lane starts fine — the same wrong-question shape this guard
  // exists to remove. The lane's WebRTC fake-media flags are not copied: this
  // spec only does page.goto('about:blank') and touches no media device.
  use: { launchOptions: { args: ['--no-sandbox', '--disable-dev-shm-usage'] } },
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

CATALOGUE="${E2E}/steps/function-catalogue.ts"
PERSONAS="${REPO}/tests/e2e-extra-personas.sh"
SEED_SQL="${REPO}/specs/cluster/manifests/route-access/initdb/20-schema.sql"
OWNCAST_FEATURE="${E2E}/features/uncovered-services/owncast-functions.feature"

# The five generated specs this lane owns.
LANE_SPECS=(
  ".features-gen/features/uncovered-services/media-games-function-matrix.feature.spec.js"
  ".features-gen/features/uncovered-services/owncast-functions.feature.spec.js"
  ".features-gen/features/uncovered-services/tube-functions.feature.spec.js"
  ".features-gen/features/uncovered-services/games-functions.feature.spec.js"
  ".features-gen/features/uncovered-services/character-functions.feature.spec.js"
)

# PLAYWRIGHT_BROWSERS_PATH is deliberately NOT set or defaulted here: the lane
# resolves the browser exactly as the caller's environment does (see the
# preflight above, which proved that resolution launches).

PASSED=0
FAILED=0
pass() { printf '  PASS %s\n' "$*"; PASSED=$((PASSED + 1)); }
fail() { printf '  FAIL %s\n' "$*"; FAILED=$((FAILED + 1)); }
info() { printf '       %s\n' "$*"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fmg-guard.XXXXXX")"
BACKUP="${WORK}/backup"
mkdir -p "${BACKUP}"

# Every file the battery is allowed to touch, backed up BEFORE anything runs so
# the trap can restore from a known-good copy rather than from git (which would
# also revert whatever else the operator had in flight).
CHARACTER_FEATURE="${E2E}/features/uncovered-services/character-functions.feature"
MUTABLE=("${CATALOGUE}" "${PERSONAS}" "${SEED_SQL}" "${OWNCAST_FEATURE}" "${CHARACTER_FEATURE}")
for f in "${MUTABLE[@]}"; do
  cp "${f}" "${BACKUP}/$(basename "${f}")"
done

restore_all() {
  for f in "${MUTABLE[@]}"; do
    cp "${BACKUP}/$(basename "${f}")" "${f}"
  done
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
trap 'restore_all; rm -rf "${WORK}"' EXIT INT TERM HUP

# ── helpers ─────────────────────────────────────────────────────────────────

# Regenerate. NEVER call this while a test run is in flight — .features-gen is
# shared mutable state and regenerating under a running suite silently
# invalidates it.
regen() {
  ( cd "${E2E}" && npx bddgen >"${WORK}/bddgen.log" 2>&1 )
}

# Run the lane. Echoes "passed=<n> failed=<n> skipped=<n>"; returns the runner's
# own exit code. SNAP_REPORT_DIR is redirected into the scratch dir so a guard
# run never writes evidence into the working tree.
run_lane() {
  local outfile="$1"
  local rc=0
  ( cd "${E2E}" \
    && SNAP_REPORT_DIR="${WORK}/report" \
       SNAP_RUN_ID="fmg-guard-$$" \
       npx playwright test --project=bdd "${LANE_SPECS[@]}" --reporter=json \
       >"${outfile}" 2>"${WORK}/lane.err" ) || rc=$?
  return "${rc}"
}

# Read the counts out of a JSON report without a JSON dependency in the shell.
lane_counts() {
  local outfile="$1"
  node -e '
    const fs = require("fs");
    let r;
    try { r = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); }
    catch (e) { console.log("passed=0 failed=0 skipped=0 parse-error"); process.exit(0); }
    let passed = 0, failed = 0, skipped = 0;
    const walk = (s) => {
      (s.suites || []).forEach(walk);
      (s.specs || []).forEach((sp) => sp.tests.forEach((t) => t.results.forEach((res) => {
        if (res.status === "passed") passed++;
        else if (res.status === "skipped") skipped++;
        else failed++;
      })));
    };
    (r.suites || []).forEach(walk);
    console.log(`passed=${passed} failed=${failed} skipped=${skipped}`);
  ' "${outfile}"
}

lane_failed_count() {
  lane_counts "$1" | sed -n 's/.*failed=\([0-9]*\).*/\1/p'
}

# Apply a mutation, PROVE the file really changed, run the lane, restore.
# Prints CAUGHT / SURVIVED. A mutation whose sed matched nothing is reported as
# BROKEN rather than counted either way — a no-op mutation that "passes" is the
# way a mutation battery lies to its author.
CAUGHT=0
SURVIVED=0
BROKEN=0
mutate() {
  local label="$1"; shift
  local target="$1"; shift
  local needs_regen="$1"; shift
  # remaining args: the mutation command, run with "$@"
  local before after rc failed
  before="$(cksum <"${target}")"
  "$@"
  after="$(cksum <"${target}")"
  if [ "${before}" = "${after}" ]; then
    printf '  BROKEN   %s (the mutation changed nothing — it proves nothing)\n' "${label}"
    BROKEN=$((BROKEN + 1))
    restore_all
    return
  fi
  if [ "${needs_regen}" = "regen" ]; then
    regen || true
  fi
  rc=0
  run_lane "${WORK}/mut.json" || rc=$?
  failed="$(lane_failed_count "${WORK}/mut.json")"
  restore_all
  if [ "${needs_regen}" = "regen" ]; then
    regen || true
  fi
  if [ "${rc}" -ne 0 ] && [ "${failed:-0}" -gt 0 ]; then
    printf '  CAUGHT   %s (%s failing)\n' "${label}" "${failed}"
    CAUGHT=$((CAUGHT + 1))
  else
    printf '  SURVIVED %s — the lane stayed green with production broken\n' "${label}"
    SURVIVED=$((SURVIVED + 1))
  fi
}

echo "== e2e media/games FUNCTION axis: census, gates, derived access matrix =="

# ── 0. generation ───────────────────────────────────────────────────────────
if regen; then
  pass "npx bddgen exits 0 with the function-axis features present"
else
  fail "npx bddgen FAILED — see ${WORK}/bddgen.log"
  sed -n '1,20p' "${WORK}/bddgen.log" || true
fi

LANE_TOTAL=0
for spec in "${LANE_SPECS[@]}"; do
  n="$( ( cd "${E2E}" && npx playwright test --list --project=bdd "${spec}" 2>/dev/null ) | grep -c '^  \[bdd\]' || true )"
  info "$(basename "${spec}" .feature.spec.js): ${n} scenario(s)"
  LANE_TOTAL=$((LANE_TOTAL + n))
done
if [ "${LANE_TOTAL}" -ge 100 ]; then
  pass "the function lane generates ${LANE_TOTAL} scenarios"
else
  fail "the function lane generated only ${LANE_TOTAL} scenarios (expected >= 100)"
fi

# ── 1. the lane is green offline ────────────────────────────────────────────
rc=0
run_lane "${WORK}/base.json" || rc=$?
BASE="$(lane_counts "${WORK}/base.json")"
BASE_FAILED="$(lane_failed_count "${WORK}/base.json")"
info "${BASE}"
if [ "${rc}" -eq 0 ] && [ "${BASE_FAILED:-1}" -eq 0 ]; then
  pass "the media/games function lane is green (rc=0) with NOTHING started"
else
  fail "the function lane is RED with nothing started (rc=${rc}, ${BASE})"
  sed -n '1,40p' "${WORK}/lane.err" || true
fi

# ── 2. every skip carries a named reason ────────────────────────────────────
SILENT="$(node -e '
  const fs = require("fs");
  const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  let silent = 0;
  const walk = (s) => {
    (s.suites || []).forEach(walk);
    (s.specs || []).forEach((sp) => sp.tests.forEach((t) => t.results.forEach((res) => {
      if (res.status !== "skipped") return;
      const ann = (t.annotations || []).concat(res.annotations || []);
      if (!ann.some((a) => a.description && a.description.trim())) silent++;
    })));
  };
  (r.suites || []).forEach(walk);
  console.log(silent);
' "${WORK}/base.json")"
if [ "${SILENT}" = "0" ]; then
  pass "no silent skip: every skipped scenario in this lane names its reason"
else
  fail "${SILENT} scenario(s) skipped with NO reason — a silent skip is worse than a failure"
fi

# ── 3. the lane's own evidence really lands ─────────────────────────────────
MANIFEST="$(find "${WORK}/report" -name manifest.jsonl -print -quit 2>/dev/null || true)"
if [ -n "${MANIFEST}" ] && [ -s "${MANIFEST}" ]; then
  KINDS="$(sed -n 's/.*"kind": *"\([a-z-]*\)".*/\1/p' "${MANIFEST}" | sort -u | tr '\n' ',' | sed 's/,$//')"
  info "artefact kinds recorded: ${KINDS}"
  MISSING=0
  case "${KINDS}" in
    *transcript*) ;;
    *) MISSING=1 ;;
  esac
  case "${KINDS}" in
    *widget-grab*) ;;
    *) MISSING=1 ;;
  esac
  if [ "${MISSING}" -eq 0 ]; then
    pass "this lane's cli and studio scenarios wrote real transcript + widget-grab evidence"
  else
    fail "this lane recorded kinds [${KINDS}] — expected at least transcript and widget-grab"
  fi
else
  fail "no manifest.jsonl under ${WORK}/report — the lane produced no evidence at all"
fi

# ── the mutation battery ────────────────────────────────────────────────────
echo
echo "-- mutation battery: break production, prove the lane notices --"

# M1 — a catalogued function nobody wrote a scenario for. THE census mutation.
m1() {
  perl -0pi -e "s/  \{\n    service: 'owncast', id: 'console',/  {\n    service: 'owncast', id: 'never-written',\n    name: 'x', gateway: 'hugmesh-fe-gateway', pattern: '\\/owncast\\/**',\n    gateRole: 'ROLE_OWNCAST', driveability: 'ui', blockedBy: '', note: 'mutation',\n  },\n  {\n    service: 'owncast', id: 'console',/" "${CATALOGUE}"
}
mutate "M1 a catalogued function with no scenario slips past the census" "${CATALOGUE}" norgen m1

# M2 — the catalogue disagrees with the feature file about the gate ROLE.
m2() { sed -i "s/gateRole: 'ROLE_ADMIN',/gateRole: 'ROLE_MOD',/" "${CATALOGUE}"; }
mutate "M2 catalogue gate role silently disagrees with the feature file" "${CATALOGUE}" norgen m2

# M3 — the catalogue disagrees with the feature file about the SURFACE.
m3() { sed -i "s#pattern: '/bff/owncast/admin/\*\*'#pattern: '/bff/owncast/**'#" "${CATALOGUE}"; }
mutate "M3 catalogue surface silently disagrees with the feature file" "${CATALOGUE}" norgen m3

# M4 — THE GENERATIVE ONE. Seed a persona holding ROLE_OWNCAST. The written
# matrix does not move; the derived one does; the zero-audience tripwires fire.
# This is the whole claim of the design, tested by making it come true.
m4() {
  sed -i 's#^e2e-banned:ROLE_USER:E2E_BANNED_PASSWORD \\#e2e-banned:ROLE_USER:E2E_BANNED_PASSWORD \\\ne2e-owncast:ROLE_OWNCAST,ROLE_USER:E2E_OWNCAST_PASSWORD \\#' "${PERSONAS}"
}
mutate "M4 a newly seeded ROLE_OWNCAST persona leaves the access matrix unmoved" "${PERSONAS}" norgen m4

# M5 — the catalogue's driveability verdict flips without the Gherkin noticing.
m5() { sed -i "0,/driveability: 'no-audience'/s//driveability: 'ui'/" "${CATALOGUE}"; }
mutate "M5 a pending function is quietly re-rated drivable" "${CATALOGUE}" norgen m5

# M6 — the ROUTE-ACCESS SEED loses the row a function depends on. The gateway is
# default-deny, so this is a 403 for everyone; the feature file and the catalogue
# would still agree with each other perfectly.
m6() {
  sed -i "s#^  ('hugmesh-fe-gateway',  '/bff/owncast/admin/\*\*',  'ROLE_ADMIN',   true),#  -- MUTATED: row removed#" "${SEED_SQL}"
}
mutate "M6 the route-access seed drops the row a function's gate depends on" "${SEED_SQL}" norgen m6

# M7 — COMMENT-TOKEN INVERSION, the trap that has bitten this repo five times.
# Move the only live @function:moderate tags into a comment. If the census
# counted comments, coverage would look untouched.
m7() {
  # Move the tag into a COMMENT line while leaving every other tag on the
  # scenario untouched — @env:docker in particular, so the driven scenarios keep
  # skipping and cannot make this mutation look "caught" for the wrong reason.
  sed -i 's/^  @function:moderate \(.*\)$/  # hidden: @function:moderate\n  \1/' "${OWNCAST_FEATURE}"
  sed -i 's/@function:moderate @service:owncast/@service:owncast/g' "${OWNCAST_FEATURE}"
}
mutate "M7 a @function: tag hidden inside a Gherkin comment still counts as coverage" "${OWNCAST_FEATURE}" regen m7

# M8 — the SERVICE SCOPING of the census. Two services here catalogue a function
# called 'open'. Re-point character-studio's open scenarios at character-forge and
# a census that only collected function IDS would stay green while character-studio
# lost its only 'open' coverage.
m8() {
  sed -i 's/@function:open @service:character-studio/@function:open @service:character-forge/g' \
    "${E2E}/features/uncovered-services/character-functions.feature"
}
mutate "M8 a function tagged for the WRONG service still counts as that service's coverage" \
  "${E2E}/features/uncovered-services/character-functions.feature" regen m8

printf '  mutations: %s caught, %s survived, %s broken\n' "${CAUGHT}" "${SURVIVED}" "${BROKEN}"
if [ "${SURVIVED}" -eq 0 ] && [ "${BROKEN}" -eq 0 ]; then
  pass "every mutation was caught, and every mutation really changed its file"
else
  fail "${SURVIVED} mutation(s) survived and ${BROKEN} did nothing at all"
fi

# ── the tree must be exactly as we found it ─────────────────────────────────
restore_all
regen || true
DIRTY=0
for f in "${MUTABLE[@]}"; do
  if ! cmp -s "${BACKUP}/$(basename "${f}")" "${f}"; then
    fail "NOT RESTORED: ${f}"
    DIRTY=1
  fi
done
if [ "${DIRTY}" -eq 0 ]; then
  pass "every mutated file is byte-identical to how this script found it"
fi

echo
printf '== e2e media/games FUNCTION axis: %s passed, %s failed ==\n' "${PASSED}" "${FAILED}"
[ "${FAILED}" -eq 0 ]

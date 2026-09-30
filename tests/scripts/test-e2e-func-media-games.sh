#!/usr/bin/env bash
# test-e2e-func-media-games.sh — the gate for the FUNCTION axis of owncast, tube,
# games, character-studio and character-forge.
#
# THIRD SIBLING. test-e2e-gherkin-harness.sh proves every .feature generates and
# runs. test-e2e-env-interface-dimensions.sh proves the env/interface axes mean
# something. This one proves the FUNCTION census and the derived access matrix
# are load-bearing rather than decorative:
#
#   1. the whole media/games function lane is GREEN with nothing started, and
#      what happens when a stack IS reachable is decided by whether this box
#      holds an e2e credential (decision 64, generator#562; corrected 2026-09-18
#      and again 2026-09-23 from the earlier, FALSE "offline by construction"
#      claim this line made). This suite STARTS nothing itself, but it is not
#      airtight-offline: `tests/e2e/steps/dimensions.ts`'s environment probe is
#      a real HTTP GET against the compose door, so on a box where the
#      operator's own `hugmesh-local` stack (or any other reachable one)
#      happens to be up, `@env:docker`-tagged scenarios correctly switch from
#      SKIPPING to RUNNING FOR REAL. Those scenarios sign in for real, so this
#      suite resolves a credential EXACTLY the way `tests/stack/seed-e2e.sh`
#      does (env override, else the run-state file, else generate) with ONE
#      change: the generate step is redirected to a RUN-LOCAL file (below), so
#      the operator's own `.e2e-credentials` is READ but never WRITTEN. Three
#      regimes, and the docstring promises only what each one delivers:
#        (a) an operator credential (E2E_PASSWORD exported, or a run-state
#            file that `make stack-seed` wrote) AND a reachable door: the
#            `@env:docker` scenarios run against the live stack as themselves.
#            Green iff the product is; a red here is a product regression OR a
#            stale credential (a run-state file that no longer matches the
#            stack's Casdoor — the same ~30-failed-logins exposure seed-e2e.sh's
#            own leg 1c names), and the lane's per-scenario errors tell which.
#        (b) NO operator credential: a run-local one is generated so nothing
#            can throw, and — because a freshly generated credential
#            authenticates NOWHERE by construction — every environment door
#            probe is pinned to a closed loopback port, so `@env:*` scenarios
#            SKIP with a named reason even when a stack is up, instead of
#            hammering a live Casdoor with ~30 x retries wrong-password logins
#            per lane run (x9 lane runs per guard run) to report a red the code
#            already predicts. Green with nothing started.
#        (c) door unreachable: the `@env:*` scenarios skip with a named reason
#            exactly as before. Green with nothing started.
#      The pre-#562 behaviour — throwing identically on all 60 affected
#      scenarios the moment a real door answered — is gone in every regime;
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
# OFFLINE-SAFE, NOT OFFLINE-ONLY. Starts NOTHING itself: no stack, no cluster,
# no emulator, no image build. It DOES, however, notice and use a stack that is
# ALREADY running for an unrelated reason — but ONLY when this box holds an
# operator credential for it (regime (a) above); without one it pins the door
# probes closed and stays offline in effect (regime (b)). That is a property of
# the scenarios it runs plus the credential resolution below, not of this
# wrapper alone. `make stack-seed` is NEVER invoked here: it would rewrite the
# operator's `.e2e-credentials` and reseed their live identities under a new
# password — a side effect no guard may have. If you want regime (a), seed the
# stack yourself first (`make stack-seed`) or export E2E_PASSWORD.
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
# Armed IMMEDIATELY, before anything is written under ${WORK}: the self-seed
# block below may persist a run-local credential there, and the full
# restore-and-remove trap is armed only after the mutable files are backed up
# (further down). A run killed between the two used to leak a mode-600
# credential file in TMPDIR — found for real after the 2026-09-18 session
# death. The later EXIT `trap` REPLACES this one; it also removes ${WORK}.
# The signal traps EXIT rather than clean up in place — see the full trap below
# for why a handler that returns is worse than no handler.
trap 'rm -rf "${WORK}"' EXIT
trap 'exit 143' INT TERM HUP
BACKUP="${WORK}/backup"
mkdir -p "${BACKUP}"

# ── credential resolution: read-only, then RUN-LOCAL (decision 64, generator#562)
# generator#562's chosen option: "such suites call make stack-seed (or resolve
# credentials the same way) themselves before asserting anything, so 'the stack
# happens to be up' degrades to a normal green run instead of a credentials
# throw". `make stack-seed` itself is never invoked here (see the header), so
# this resolves credentials the SAME WAY it does, via the one shared generator
# (tests/stack/e2e-password.sh, SOURCED per its own contract, never executed),
# with its precedence kept intact and its WRITE redirected:
#
#   1. E2E_PASSWORD already exported          -> used as is (provenance: env)
#   2. the run-state file, READ ONLY           -> used as is (provenance: file)
#        the operator's own E2E_CREDENTIALS_FILE if they exported one, else the
#        default ${REPO}/.e2e-credentials that `make stack-seed` writes. Read via
#        e2e_password_read(), which never writes; the file is byte-identical
#        after this block whether or not it holds the key. This is the step
#        that makes regime (a) a normal, authenticated run from a seeded
#        checkout — the first cut of this fix overrode the path unconditionally
#        and so could never authenticate against the operator's own stack.
#   3. nobody has one                          -> GENERATE (provenance: generated)
#        via e2e_password_ensure() with E2E_CREDENTIALS_FILE pointed at THIS
#        run's scratch dir, never the default path — a guard must never write the
#        operator's file (tests/stack/e2e-password.sh: "NEVER commit a real
#        value"; the standing rule on this repo: never execute e2e-password.sh
#        directly, never touch the operator's .e2e-credentials). ${WORK} is
#        removed by the EXIT trap armed right after mktemp above, so this
#        credential never outlives the run it was generated for.
#
# A generated credential is registered against NO account (that is full persona
# seeding, tests/stack/seed-e2e.sh, deliberately NOT a guard's job), so in that
# case every environment door probe is pinned to a closed loopback port below:
# `@env:*` scenarios then skip with a named reason instead of each spending
# ~90 s x retries on a sign-in that can only 401 — and instead of tripping
# whatever failed-sign-in limit the live Casdoor applies to the e2e-* personas.
# The pin URL carries the reason in its path so the JSON skip annotation names
# it. Playwright's own SNAP_BASE_URL is NOT touched: the probe merely falls back
# to it, and the offline scenarios never navigate.
#
# Every source+call happens inside a `$( … )` command-substitution subshell, not
# at this script's top level: e2e-password.sh's own preamble sets
# `set -uo pipefail`, and sourcing it directly here would leak `pipefail` into
# the REST of this script's shell options for every command after this point —
# a behaviour change to code this change has nothing to do with. A `$( … )`
# subshell forks, so any `set` change inside it dies with the subshell; only
# the printed value crosses back via stdout.
E2E_CREDENTIAL_PROVENANCE=""
if [ -n "${E2E_PASSWORD:-}" ]; then
  export E2E_PASSWORD
  E2E_CREDENTIAL_PROVENANCE="env"
else
  # 2. run-state file, read only. rc 1 = present but unreadable (a root-owned
  # file from a sudo QEMU run): e2e_password_read prints the fix and this
  # guard falls through to a run-local credential rather than dying on it.
  CRED_CANDIDATE="${E2E_CREDENTIALS_FILE:-${REPO}/.e2e-credentials}"
  read_rc=0
  E2E_PASSWORD="$(
    export E2E_CREDENTIALS_FILE="${CRED_CANDIDATE}"
    # shellcheck source=../stack/e2e-password.sh
    . "${REPO}/tests/stack/e2e-password.sh"
    e2e_password_read E2E_PASSWORD
  )" || read_rc=$?
  if [ "${read_rc}" -eq 0 ] && [ -n "${E2E_PASSWORD}" ]; then
    export E2E_PASSWORD
    E2E_CREDENTIAL_PROVENANCE="file"
  fi
fi
if [ -z "${E2E_CREDENTIAL_PROVENANCE}" ]; then
  # 3. generate, run-local. Overrides any operator-exported E2E_CREDENTIALS_FILE
  # from here on — it held no usable key (or was unreadable), and the one thing
  # this guard must never do is write to it.
  E2E_CREDENTIALS_FILE="${WORK}/.e2e-credentials"
  export E2E_CREDENTIALS_FILE
  E2E_PASSWORD="$(
    # shellcheck source=../stack/e2e-password.sh
    . "${REPO}/tests/stack/e2e-password.sh"
    e2e_password_ensure >&2 || exit 1
    printf '%s' "${E2E_PASSWORD}"
  )"
  if [ $? -eq 0 ] && [ -n "${E2E_PASSWORD}" ]; then
    export E2E_PASSWORD
    E2E_CREDENTIAL_PROVENANCE="generated"
  else
    echo "test-e2e-func-media-games.sh: could not self-seed a run-local E2E_PASSWORD (see the message above from tests/stack/e2e-password.sh)." >&2
    echo "This guard checked NOTHING. Exiting 2 rather than letting every scenario fail identically on a missing credential." >&2
    exit 2
  fi
fi
case "${E2E_CREDENTIAL_PROVENANCE}" in
  env)
    info "e2e credential: E2E_PASSWORD from the environment (nothing written); a reachable stack's @env:* scenarios will sign in with it"
    ;;
  file)
    info "e2e credential: E2E_PASSWORD read from ${CRED_CANDIDATE} (read only, file untouched); a reachable stack's @env:* scenarios will sign in with it"
    ;;
  generated)
    info "e2e credential: none on this box (no E2E_PASSWORD, no key in ${CRED_CANDIDATE}) — generated a run-local one at ${E2E_CREDENTIALS_FILE} (mode 600, removed with \${WORK} on exit), never the operator's ${REPO}/.e2e-credentials"
    NO_CRED_PIN="http://127.0.0.1:1/no-e2e-credential-on-this-box"
    for knob in SNAP_ENV_DOCKER_BASE_URL SNAP_ENV_QEMU_BASE_URL SNAP_ENV_KIND_PROBE_URL; do
      if [ -n "${!knob:-}" ] && [ "${!knob}" != "${NO_CRED_PIN}" ]; then
        info "  overriding ${knob}=${!knob}: a generated credential cannot sign in there"
      fi
    done
    export SNAP_ENV_DOCKER_BASE_URL="${NO_CRED_PIN}"
    export SNAP_ENV_QEMU_BASE_URL="${NO_CRED_PIN}"
    export SNAP_ENV_KIND_PROBE_URL="${NO_CRED_PIN}/"
    info "  every @env:* door probe is pinned to ${NO_CRED_PIN} — those scenarios SKIP (named reason) even if a stack is up; to run them for real: make stack-seed, or export E2E_PASSWORD"
    ;;
esac

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
#
# THE SIGNAL HANDLERS MUST EXIT, NOT RETURN. Until 2026-09-23 all four signals
# shared the cleanup handler above, and a trapped signal does not end a bash
# script: MEASURED with an external `kill -TERM` during the base lane run — the
# handler restored the tree and deleted ${WORK} (backups included), then the
# script CONTINUED into the battery, applied M1 to function-catalogue.ts, and
# every later restore_all failed on the missing backup, so the tree stayed
# mutated after the run ended, and the NEXT run reported base failures against
# a poisoned catalogue. Exiting from the signal trap runs the EXIT trap exactly
# once, with the backups still present. 143 = 128 + SIGTERM, the code a shell
# reports for the untrapped case.
trap 'restore_all; rm -rf "${WORK}"' EXIT
trap 'exit 143' INT TERM HUP

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

# EVERY `node -e` this suite captures goes through here, and never through a bare
# `node`. #316: with FORCE_COLOR inherited from whatever launched the suite, node
# runs a NON-STRING argument to console.log through util.inspect WITH COLOURS, so a
# captured count comes back wrapped in ANSI:
#
#   $ FORCE_COLOR=3 node -e 'console.log(0)'         | cat -v   ->  ^[[33m0^[[39m
#   $ FORCE_COLOR=3 node -e 'console.log(String(0))' | cat -v   ->  0
#   $ env -u FORCE_COLOR node -e 'console.log(0)'    | cat -v   ->  0
#
# and `[ "${X}" = "0" ]` then takes the wrong arm. Measured on this tree: the whole
# suite was 6 passed / 1 failed / rc=1 under FORCE_COLOR=3 and 7 passed / 0 failed
# / rc=0 without it — the same tree, the same commit, a verdict decided by an
# ambient variable.
#
# It errs LOUD at the one site that has it today, but the shape errs SILENT
# wherever an `= "0"` gates a PASS arm, so this is fixed as a class and not as a
# line. Two independent belts, because either alone is one refactor from gone:
#   * the call sites below print STRINGS (a string argument is never inspected);
#   * this helper pins the colour environment, so a future `console.log(<Number>)`
#     added here cannot reintroduce it.
# NO_COLOR as well as FORCE_COLOR=0: they are separate switches in node, and a
# future node could honour one without the other.
node_quiet() { FORCE_COLOR=0 NO_COLOR=1 node "$@"; }

# Read the counts out of a JSON report without a JSON dependency in the shell.
lane_counts() {
  local outfile="$1"
  node_quiet -e '
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
  # CAUGHT means the mutant added failures ON TOP OF the base run's — a battery
  # run against an already-red base (regime (a) with a stale credential, say)
  # would otherwise credit every mutant for the base's own failures.
  if [ "${rc}" -ne 0 ] && [ "${failed:-0}" -gt "${BASE_FAILED:-0}" ]; then
    printf '  CAUGHT   %s (%s failing, base %s)\n' "${label}" "${failed}" "${BASE_FAILED:-0}"
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
SILENT="$(node_quiet -e '
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
  // String(), not the bare Number: console.log of a non-string is util.inspect-ed,
  // and inspect COLOURS under an inherited FORCE_COLOR. See node_quiet above (#316).
  console.log(String(silent));
' "${WORK}/base.json")"
# The captured value must be a plain integer BEFORE it is compared. A count that
# arrived wrapped in ANSI (or empty, because node died) equals neither "0" nor any
# number, so a bare `= "0"` would silently take the fail arm for a reason that has
# nothing to do with skips — and the mirror-image shape, `= "0"` gating a PASS,
# would take the pass arm. Assert the SHAPE, then the VALUE. `cat -v` so a reader
# sees the escapes instead of a message that has already eaten them.
case "${SILENT}" in
  ''|*[!0-9]*)
    fail "the silent-skip count came back as '$(printf '%s' "${SILENT}" | cat -v)', which is not a plain integer — the capture itself is broken (an inherited FORCE_COLOR/NO_COLOR, or node failing), so the comparison below would be meaningless. See #316."
    ;;
  *)
    if [ "${SILENT}" -eq 0 ]; then
      pass "no silent skip: every skipped scenario in this lane names its reason"
    else
      fail "${SILENT} scenario(s) skipped with NO reason — a silent skip is worse than a failure"
    fi
    ;;
esac

# ── 2b. this suite's own capture is immune to a hostile FORCE_COLOR ─────────
# The check above decides a verdict from a value captured out of node. #316 was
# that verdict being decided by an environment variable nobody in this repo sets:
# FORCE_COLOR arrives from whatever launched the suite (several agent and CI
# harnesses export it), and under it node colours a console.log of a NON-string.
# So the immunity is asserted here directly, with the hostile value forced ON,
# rather than left to whoever happens to run the suite.
#
# CONTROL FIRST, so this can never be vacuously green: if a bare `node -e
# 'console.log(0)'` does NOT colour under FORCE_COLOR=3 on this host, the probe
# below proves nothing and says so. That is reported as INFO, not as a failure —
# a node build that stopped colouring is not this suite's regression.
RAW_PROBE="$(FORCE_COLOR=3 node -e 'console.log(0)' 2>/dev/null | cat -v)"
if [ "${RAW_PROBE}" = "0" ]; then
  info "control: this host's node does not colour console.log(<Number>) under FORCE_COLOR=3 (got '${RAW_PROBE}'), so the immunity check below is VACUOUS here — it cannot fail on this host."
else
  info "control: a bare node -e 'console.log(0)' under FORCE_COLOR=3 prints '${RAW_PROBE}' — the hazard is live on this host, so the check below is load-bearing."
fi
QUIET_PROBE="$(FORCE_COLOR=3 NO_COLOR= node_quiet -e 'console.log(String(0))' 2>/dev/null | cat -v)"
if [ "${QUIET_PROBE}" = "0" ]; then
  pass "captures are colour-immune: with FORCE_COLOR=3 forced ON, this suite's own node capture still yields a bare '0' (#316)"
else
  fail "this suite's node capture is NOT colour-immune — with FORCE_COLOR=3 it yielded '${QUIET_PROBE}', not '0'. Every count this suite compares is decided by an inherited environment variable (#316)."
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

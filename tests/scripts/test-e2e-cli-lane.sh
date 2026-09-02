#!/usr/bin/env bash
# test-e2e-cli-lane.sh — the gate for the ONE CLI entry point of the e2e suite.
#
# SIBLING TO test-e2e-gherkin-harness.sh (every .feature generates and runs) and
# test-e2e-env-interface-dimensions.sh (the two axes mean something). This one
# proves the thing a human actually types works:
#
#   1. tests/e2e/run.sh FORWARDS the environment. Not "mentions it" -- forwards
#      it: a stub `npx` on PATH records the argv and the environment it was
#      really handed, and the assertions read THAT. Grepping the script for
#      'SNAP_ENV' proves a token is present, not that it reaches the runner, and
#      is exactly the check that would stay green through every mutation below.
#   2. it FORWARDS the selection -- the tag expression to the generator
#      (bddgen --tags) and the feature path to the runner, translated from the
#      source path an operator types to the generated mirror playwright collects.
#   3. it PROPAGATES THE EXIT CODE. An exit-code-swallowing test lane is the
#      worst outcome available here: everything looks green forever. The stub is
#      made to fail and run.sh must fail with the same code, and a failed
#      generation must stop the run instead of collecting a smaller suite.
#   4. the bash environment table and steps/dimensions.ts's ENVIRONMENT_DEFS
#      resolve every mesh to the SAME base URL. Two resolvers for one fact drift
#      silently: the CLI points chromium at one mesh while the skip reasons name
#      another. And the docker door is ONE knob (PUBLIC_HTTPS_PORT): both sides
#      must FOLLOW it, the help text must advertise the same door, and the
#      bundled-browser docker path must hand the container the same door — a
#      recording `docker` stub reads the argv, because run.sh carried THREE
#      copies of that fallback and all three had drifted to 8443 (the port
#      INSIDE the tls-front container; on a dev box, the kind node) while the
#      TypeScript said 8488. Sites 2 and 3 were invisible to the --print-command
#      comparison alone.
#   5. `--evidence` reads the manifest and summarises it per env / per
#      interface, counts from the ROWS, and NEVER reports an empty success.
#   6. the CLI feature lane itself is green offline, and the whole Gherkin suite
#      still generates and is collected.
#
# MUTATION BATTERY. Eleven mutations, each breaking production on purpose, each
# required to turn a NAMED check red. Every mutation is applied to the real tree
# with a backup, proven to have changed the file, and restored on EXIT via trap;
# the last check asserts the tree is byte-identical to how it started.
#
# OFFLINE. STARTS NOTHING. No stack, no cluster, no emulator, no sudo, no image
# build. Every command it runs is a dry-run, a plan, or a stub.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
E2E="${REPO}/tests/e2e"
RUN_SH="${E2E}/run.sh"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

echo "== e2e CLI lane: one entry point, forwarded, honest about its exit code =="

# ── preconditions: refuse to be vacuous ──────────────────────────────────────
for t in node python3 git bash make; do
  command -v "${t}" >/dev/null 2>&1 || {
    echo "SKIPPED-LOUDLY: ${t} is required and absent — this guard checked NOTHING." >&2
    exit 2
  }
done
[ -f "${RUN_SH}" ] || {
  echo "SKIPPED-LOUDLY: ${RUN_SH} is missing — there is no entry point to gate." >&2
  exit 2
}
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

WORK="${TMPDIR:-/var/tmp/portage}/cli-lane-guard.$$"
mkdir -p "${WORK}"

# Byte fingerprint of everything the battery may touch, taken BEFORE anything is
# broken. The final check diffs against it.
FILES_UNDER_TEST=(tests/e2e/run.sh tests/e2e/evidence-report.mjs tests/e2e/print-plan.mjs)
tree_fingerprint() {
  ( cd "${REPO}" && md5sum "${FILES_UNDER_TEST[@]}" )
}
tree_fingerprint > "${WORK}/tree-before.md5"

BACKUP="${WORK}/backup"; mkdir -p "${BACKUP}"
MUTATED=()
save_file() {
  local rel dest
  rel="$1"
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

# mutate <relpath>  (python patch on stdin) — applies it and PROVES the file
# really changed. A mutation that silently failed to apply would make this guard
# look like it caught something it never saw.
mutate() {
  local rel before after
  rel="$1"
  before="$(md5sum "${REPO}/${rel}" | cut -d' ' -f1)"
  save_file "${rel}"
  python3 - "${REPO}/${rel}" || return 1
  after="$(md5sum "${REPO}/${rel}" | cut -d' ' -f1)"
  if [ "${before}" = "${after}" ]; then
    echo "    !! mutation did NOT change ${rel} — the guard would be testing nothing" >&2
    return 1
  fi
  return 0
}

# ── the stub ─────────────────────────────────────────────────────────────────
# A fake `npx` that records the argv it was handed AND the environment it was
# handed it in, then exits with a code the caller chooses. This is the whole
# reason the guard can tell "forwarded" from "mentioned".
STUB_DIR="${WORK}/stub"; mkdir -p "${STUB_DIR}"
cat > "${STUB_DIR}/npx" <<'STUB'
#!/usr/bin/env bash
# Recording stub. Never runs anything.
{
  echo "INVOCATION"
  for a in "$@"; do printf 'ARG\t%s\n' "${a}"; done
  printf 'ENV\tSNAP_ENV\t%s\n'           "${SNAP_ENV-<unset>}"
  printf 'ENV\tSNAP_BASE_URL\t%s\n'      "${SNAP_BASE_URL-<unset>}"
  printf 'ENV\tSNAP_HOST_RESOLVER\t%s\n' "${SNAP_HOST_RESOLVER-<unset>}"
  printf 'ENV\tSNAP_REPORT_DIR\t%s\n'    "${SNAP_REPORT_DIR-<unset>}"
  printf 'ENV\tSNAP_RUN_ID\t%s\n'        "${SNAP_RUN_ID-<unset>}"
  echo "END"
} >> "${STUB_LOG}"
case "${1-}" in
  bddgen)     exit "${STUB_BDDGEN_RC:-0}" ;;
  playwright) exit "${STUB_PW_RC:-0}" ;;
esac
exit 0
STUB
chmod +x "${STUB_DIR}/npx"

# stub_run <logfile> <args...> -> echoes run.sh's exit code
stub_run() {
  local log
  log="$1"; shift
  : > "${log}"
  ( cd "${REPO}" && \
    STUB_LOG="${log}" \
    STUB_BDDGEN_RC="${STUB_BDDGEN_RC:-0}" STUB_PW_RC="${STUB_PW_RC:-0}" \
    PATH="${STUB_DIR}:${PATH}" \
    E2E_PASSWORD="${E2E_PASSWORD:-cli-lane-stub-never-authenticates-anything}" \
    SNAP_EVIDENCE_SUMMARY=0 \
    bash "${RUN_SH}" "$@" >"${log}.out" 2>&1 )
  local rc=$?
  # DID IT REACH THE RUNNER AT ALL? Every assertion downstream reads this log via
  # stub_args/stub_env, and both answer "" for a log that was never written. An ""
  # compares unequal to every expectation, so a run.sh that exits BEFORE invoking
  # npx does not make those checks fail honestly — it makes them report confident,
  # WRONG verdicts about forwarding and exit codes that were never exercised.
  #
  # This is not hypothetical: run.sh grew a MODE=run credential gate that exits 1
  # before npx, and this lane sets no credential, so all of sections 1-3 silently
  # measured nothing. The loudest false verdict was "run.sh SWALLOWS the runner's
  # exit code — the lane can never go red", which is alarming, actionable and
  # untrue.
  #
  # A deliberate failure still records: STUB_BDDGEN_RC=5 invokes bddgen (1
  # INVOCATION) and only then stops. So ZERO invocations means run.sh never got
  # that far, which is always a defect in the guard's setup, never a finding.
  if ! grep -q '^INVOCATION$' "${log}" 2>/dev/null; then
    STUB_RUN_NEVER_REACHED="${STUB_RUN_NEVER_REACHED}${STUB_RUN_NEVER_REACHED:+ }${log##*/}"
    echo "  FAIL run.sh exited ${rc} WITHOUT invoking the runner (${log##*/}); the" >&2
    echo "       recording is empty, so nothing below it measured anything. First" >&2
    echo "       lines of its output:" >&2
    sed -n '1,4p' "${log}.out" 2>/dev/null | sed 's/^/         /' >&2
  fi
  echo "${rc}"
}

# The log is a flat record; these read one invocation out of it. `tool` is the
# first ARG of an invocation (bddgen / playwright).
# stub_args <log> <tool>  -> one argument per line
stub_args() {
  awk -v want="$2" '
    /^INVOCATION$/ { n=0; delete a; first=""; next }
    /^ARG\t/       { v=substr($0,5); n++; a[n]=v; if (n==1) first=v; next }
    /^END$/        { if (first==want) { for (i=1;i<=n;i++) print a[i] } ; next }
  ' "$1"
}
# stub_env <log> <tool> <VAR> -> the value that invocation saw
stub_env() {
  awk -v want="$2" -v var="$3" -F'\t' '
    /^INVOCATION$/ { first=""; delete e; next }
    /^ARG\t/       { if (first=="") first=$2; next }
    /^ENV\t/       { e[$2]=$3; next }
    /^END$/        { if (first==want) print e[var]; next }
  ' "$1"
}
stub_count() {  # how many invocations of <tool>
  stub_args "$1" "$2" | grep -c "^$2\$"
}
# NOT `grep -Fxq`: -q exits on the first match and SIGPIPEs the writer, which
# under `set -o pipefail` turns a FOUND match into a FAILED pipeline. Draining
# into /dev/null costs nothing here and cannot misreport.
has_line() {  # has_line <needle> ; stdin is the list
  grep -Fx -- "$1" >/dev/null
}

# ── 1. environment forwarding ────────────────────────────────────────────────
echo
STUB_RUN_NEVER_REACHED=""
echo "-- 1. does --env reach the runner? (stub npx records argv + env) --"
# The docker expectation is DERIVED from the Makefile's `PUBLIC_HTTPS_PORT ?= <n>`
# (the one knob compose.local.yaml publishes as `${PUBLIC_HTTPS_PORT:-8488}:8443`),
# never written here as a literal. Until 2026-09-01 this line said 8443 — the
# same drifted value run.sh had — so check 1 stayed green while the CLI pointed
# chromium at the kind node; a guard that carries its own copy of the fallback
# agrees with the defect. kind's door is kind-local.yaml's hostPort and qemu's is
# run-qemu-e2e.sh's forwarded UI_PORT default; both really are 8443.
MAKEFILE_HTTPS_PORT="$(sed -n 's/^PUBLIC_HTTPS_PORT[[:space:]]*?=[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' "${REPO}/Makefile" | head -1)"
[ -n "${MAKEFILE_HTTPS_PORT}" ] || {
  echo "SKIPPED-LOUDLY: the Makefile declares no \`PUBLIC_HTTPS_PORT ?= <n>\` — the docker expectation cannot be derived, and a literal here is how this guard last agreed with the defect. Exiting 2." >&2
  exit 2
}
env_expect_docker="https://localhost:${MAKEFILE_HTTPS_PORT}"
env_expect_kind="https://hugmesh.net:8443"
env_expect_qemu="https://localhost:8443"

check_env_forwarding() {  # -> 0 when every environment forwards correctly
    local bad_any e want log seen_env seen_url
    bad_any=0
    for e in docker kind qemu; do
      log="${WORK}/env-${e}.log"
      # Clear the ambient values so both resolvers start from the documented
      # defaults; an exported SNAP_BASE_URL on the operator's shell would
      # otherwise be mistaken for run.sh's own answer.
      ( unset SNAP_BASE_URL SNAP_ENV SNAP_ENV_DOCKER_BASE_URL SNAP_ENV_KIND_BASE_URL \
              SNAP_ENV_QEMU_BASE_URL SNAP_HOST_RESOLVER UI_PORT SNAP_QEMU_UI_PORT PUBLIC_HTTPS_PORT
        stub_run "${log}" --bdd --env "${e}" >/dev/null )
      seen_env="$(stub_env "${log}" playwright SNAP_ENV)"
      seen_url="$(stub_env "${log}" playwright SNAP_BASE_URL)"
      eval "want=\${env_expect_${e}}"
      if [ "${seen_env}" != "${e}" ]; then
        echo "    ${e}: playwright was run with SNAP_ENV='${seen_env}' (wanted '${e}')" >&2
        bad_any=1
      fi
      if [ "${seen_url}" != "${want}" ]; then
        echo "    ${e}: playwright was run with SNAP_BASE_URL='${seen_url}' (wanted '${want}')" >&2
        bad_any=1
      fi
    done
    # kind additionally needs the chromium resolver map; without it the browser
    # cannot reach an Ingress that matches on Host.
    seen_url="$(stub_env "${WORK}/env-kind.log" playwright SNAP_HOST_RESOLVER)"
    case "${seen_url}" in
      *hugmesh.net*) : ;;
      *) echo "    kind: SNAP_HOST_RESOLVER was '${seen_url}' — chromium cannot reach the Ingress" >&2
         bad_any=1 ;;
    esac
    return "${bad_any}"
}

if check_env_forwarding; then
  ok "--env docker|kind|qemu each reach the runner as SNAP_ENV + SNAP_BASE_URL"
else
  bad "the environment is NOT forwarded to the runner"
fi

# 1b. THE LEGACY INVOCATION. tests/e2e/run-all.sh and tests/qemu/run-qemu-e2e.sh
# both call `run.sh <playwright args>` with none of the new flags and must keep
# getting exactly the old run: the handwritten specs, no bdd project, no
# generation step, and SNAP_ENV left alone so nothing is availability-gated.
# A change that started injecting --project=bdd here would silently stop those
# two callers from running the 33 specs they exist to run.
check_legacy_passthrough() {
    local log n
    log="${WORK}/legacy.log"
    ( unset SNAP_ENV; stub_run "${log}" --reporter=list specs/01-front-page.spec.ts >/dev/null )
    n="$(stub_count "${log}" bddgen)"
    if [ "${n}" != "0" ]; then
      echo "    a legacy invocation ran bddgen ${n} time(s)" >&2; return 1
    fi
    if stub_args "${log}" playwright | has_line "--project=bdd"; then
      echo "    a legacy invocation was forced onto --project=bdd" >&2; return 1
    fi
    stub_args "${log}" playwright | has_line "specs/01-front-page.spec.ts" || {
      echo "    the caller's own playwright argument never arrived" >&2; return 1; }
    stub_args "${log}" playwright | has_line "--reporter=list" || {
      echo "    the caller's --reporter was dropped" >&2; return 1; }
    if [ "$(stub_env "${log}" playwright SNAP_ENV)" != "<unset>" ]; then
      echo "    a legacy invocation pinned SNAP_ENV, which availability-gates scenarios" >&2
      return 1
    fi
    return 0
}
if check_legacy_passthrough; then
  ok "a legacy invocation still forwards its args verbatim: no bddgen, no bdd project, no SNAP_ENV"
else
  bad "the legacy invocation changed — run-all.sh / run-qemu-e2e.sh would stop running the specs"
  stub_args "${WORK}/legacy.log" playwright | sed 's/^/      argv: /' >&2
fi

# ── 2. selection forwarding ──────────────────────────────────────────────────
echo
echo "-- 2. do --features and --tags reach the runner and the generator? --"

check_feature_forwarding() {
    local log
    log="${WORK}/sel-features.log"
    stub_run "${log}" --bdd --features cli/ >/dev/null
    stub_args "${log}" playwright | has_line ".features-gen/features/cli/"
}
check_tag_forwarding() {
    local log
    log="${WORK}/sel-tags.log"
    stub_run "${log}" --bdd --tags '@interface:cli' >/dev/null
    stub_args "${log}" bddgen | has_line "--tags" \
      && stub_args "${log}" bddgen | has_line "@interface:cli"
}
check_lane_forwarding() {
    local log
    log="${WORK}/sel-lane.log"
    stub_run "${log}" --bdd >/dev/null
    stub_args "${log}" playwright | has_line "--project=bdd"
}

if check_feature_forwarding; then
  ok "--features cli/ reaches playwright as .features-gen/features/cli/"
else
  bad "the feature selection never reached playwright"
  stub_args "${WORK}/sel-features.log" playwright | sed 's/^/      argv: /' >&2
fi
if check_tag_forwarding; then
  ok "--tags reaches bddgen (the generator), which is what filters scenarios"
else
  bad "the tag expression never reached bddgen"
  stub_args "${WORK}/sel-tags.log" bddgen | sed 's/^/      argv: /' >&2
fi
if check_lane_forwarding; then
  ok "--bdd reaches playwright as --project=bdd"
else
  bad "--bdd did not select the bdd project"
fi

# ── 3. exit codes ────────────────────────────────────────────────────────────
echo
echo "-- 3. is the exit code the truth? --"

check_exit_propagation() {
    local rc
    rc="$( STUB_PW_RC=3 stub_run "${WORK}/rc3.log" --bdd )"
    [ "${rc}" = "3" ] || { echo "    playwright exited 3, run.sh exited ${rc}" >&2; return 1; }
    rc="$( STUB_PW_RC=0 stub_run "${WORK}/rc0.log" --bdd )"
    [ "${rc}" = "0" ] || { echo "    playwright exited 0, run.sh exited ${rc}" >&2; return 1; }
    return 0
}
check_gen_failure_stops_the_run() {
    local rc n
    rc="$( STUB_BDDGEN_RC=5 stub_run "${WORK}/genfail.log" --bdd )"
    if [ "${rc}" = "0" ]; then
      echo "    bddgen exited 5 and run.sh still exited 0" >&2; return 1
    fi
    n="$(stub_count "${WORK}/genfail.log" playwright)"
    if [ "${n}" != "0" ]; then
      echo "    bddgen FAILED but playwright was still invoked ${n} time(s) — the lane" >&2
      echo "    would collect a smaller suite and look green" >&2
      return 1
    fi
    return 0
}

if check_exit_propagation; then
  ok "run.sh exits with the runner's real exit code (3 stays 3, 0 stays 0)"
else
  bad "run.sh SWALLOWS the runner's exit code — the lane can never go red"
fi
if check_gen_failure_stops_the_run; then
  ok "a failed generation aborts the run instead of running a partial suite"
else
  bad "a failed bddgen did not stop the run"
fi

# ── 4. one fact, one answer: bash vs dimensions.ts ───────────────────────────
echo
echo "-- 4. do run.sh and steps/dimensions.ts agree on every mesh? --"
VOCAB="${WORK}/vocab"; mkdir -p "${VOCAB}"
ln -sfn "${E2E}/node_modules" "${VOCAB}/node_modules"
cat > "${VOCAB}/pw.config.ts" <<'TS'
import { defineConfig } from '@playwright/test';
export default defineConfig({
  testDir: __dirname, reporter: [['list']], workers: 1, retries: 0, timeout: 30_000,
});
TS
# QUOTED heredoc: an unquoted one would let bash execute the backticks and
# ${...} below, a trap this repo has already been bitten by.
cat > "${VOCAB}/agree.spec.ts" <<'TS'
import { test, expect } from '@playwright/test';
import { writeFileSync } from 'node:fs';
import { ENVIRONMENTS, environmentBaseUrl } from '__DIMENSIONS__';

// The bash side resolved these in the SAME cleared environment; if the two
// tables ever disagree the CLI drives one mesh while the harness describes
// another, and nothing anywhere says so.
test('run.sh and ENVIRONMENT_DEFS resolve every mesh to the same base URL', () => {
  const fromBash = JSON.parse(process.env.BASH_RESOLVED || '{}') as Record<string, string>;
  expect(Object.keys(fromBash).sort(), 'run.sh knows a different set of meshes')
    .toEqual([...ENVIRONMENTS].sort());
  const fromTs: Record<string, string> = {};
  for (const e of ENVIRONMENTS) fromTs[e] = environmentBaseUrl(e);
  // Recorded for the mutation battery: a mutant run.sh is compared against THIS
  // answer without a second playwright launch (the TypeScript is not what mutates).
  if (process.env.TS_RESOLVED_OUT) writeFileSync(process.env.TS_RESOLVED_OUT, JSON.stringify(fromTs));
  for (const e of ENVIRONMENTS) {
    expect(fromBash[e], `tests/e2e/run.sh --env ${e} vs ENVIRONMENT_DEFS.${e}.baseUrl()`)
      .toBe(fromTs[e]);
  }
});

// The docker door is ONE knob (PUBLIC_HTTPS_PORT), and both resolvers must
// FOLLOW it. Agreeing on the default alone is also satisfied by two matching
// literals — precisely the pair that drifted to 8443 — so this is the check that
// proves the indirection is live. baseUrl() resolves fresh on every call, which
// is why setting the knob here, inside the test, is honoured.
test('run.sh and ENVIRONMENT_DEFS both follow PUBLIC_HTTPS_PORT for the docker mesh', () => {
  const port = process.env.OVERRIDE_PORT || '';
  expect(port, 'the guard passed no OVERRIDE_PORT — this test would compare nothing').not.toBe('');
  const fromBash = JSON.parse(process.env.BASH_RESOLVED_OVERRIDE || '{}') as Record<string, string>;
  process.env.PUBLIC_HTTPS_PORT = port;
  expect(fromBash.docker, `tests/e2e/run.sh --env docker under PUBLIC_HTTPS_PORT=${port}`)
    .toBe(environmentBaseUrl('docker'));
  expect(fromBash.docker, 'neither resolver moved with the knob — the indirection is decorative')
    .toContain(`:${port}`);
});
TS
sed -i "s#__DIMENSIONS__#${E2E}/steps/dimensions#" "${VOCAB}/agree.spec.ts"

# Every resolution below runs in a CLEARED environment: an exported SNAP_BASE_URL
# or PUBLIC_HTTPS_PORT on the operator's shell would otherwise be mistaken for
# run.sh's own answer. [port] is the one knob, exported on purpose.
CLEAR_ENV='unset SNAP_BASE_URL SNAP_ENV SNAP_ENV_DOCKER_BASE_URL SNAP_ENV_KIND_BASE_URL SNAP_ENV_QEMU_BASE_URL SNAP_HOST_RESOLVER UI_PORT SNAP_QEMU_UI_PORT PUBLIC_HTTPS_PORT'
OVERRIDE_PORT=9999

# bash_url <env> [port] -> the baseUrl run.sh --print-command resolves
bash_url() {
    local e port
    e="$1"; port="${2-}"
    ( eval "${CLEAR_ENV}"
      if [ -n "${port}" ]; then export PUBLIC_HTTPS_PORT="${port}"; fi
      cd "${REPO}" && bash "${RUN_SH}" --print-command --env "${e}" 2>/dev/null \
      | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const l=s.trim().split("\n").filter(Boolean).pop()||"{}";process.stdout.write(JSON.parse(l).baseUrl||"")})' )
}
# collect_bash_urls [port] -> {"docker":"…","kind":"…","qemu":"…"}
collect_bash_urls() {
    local e url out
    out="{"
    for e in docker kind qemu; do
      url="$(bash_url "${e}" "${1-}")"
      out="${out}\"${e}\":\"${url}\","
    done
    echo "${out%,}}"
}
# ts_url <env> -> what ENVIRONMENT_DEFS answered in the agree run (recorded there)
ts_url() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' \
      "${VOCAB}/ts-resolved.json" "$1" 2>/dev/null
}

BASH_URLS=""
check_tables_agree() {  # -> 0 when both resolvers agree, by default AND under the knob
    local urls urls9
    urls="$(collect_bash_urls)"
    urls9="$(collect_bash_urls "${OVERRIDE_PORT}")"
    BASH_URLS="${urls}"
    rm -f "${VOCAB}/ts-resolved.json"
    # The agree spec launches NO browser; PLAYWRIGHT_BROWSERS_PATH is inherited
    # from the caller untouched, never defaulted here.
    ( eval "${CLEAR_ENV}"
      cd "${E2E}" && BASH_RESOLVED="${urls}" BASH_RESOLVED_OVERRIDE="${urls9}" \
      OVERRIDE_PORT="${OVERRIDE_PORT}" TS_RESOLVED_OUT="${VOCAB}/ts-resolved.json" \
      npx playwright test -c "${VOCAB}/pw.config.ts" >"${WORK}/agree.out" 2>&1 )
}
if check_tables_agree; then
  ok "the bash env table and ENVIRONMENT_DEFS resolve identically, and both follow PUBLIC_HTTPS_PORT: ${BASH_URLS}"
else
  bad "run.sh and steps/dimensions.ts DISAGREE about where a mesh is:"
  grep -viE 'npm notice' "${WORK}/agree.out" | tail -20 >&2
fi

# 4b. The usage text is the third resolver a human reads. It must advertise the
# door the table resolves (not a literal that reads right and points at the kind
# node), and it must move with the knob — which is what proves it is derived.
check_help_names_the_door() {
    local want help
    want="$(bash_url docker)"
    [ -n "${want}" ] || { echo "    --env docker resolved to nothing; the help check has no reference" >&2; return 1; }
    help="$( eval "${CLEAR_ENV}"; cd "${REPO}" && bash "${RUN_SH}" --help 2>&1 )"
    case "${help}" in
      *"${want}"*) : ;;
      *) echo "    --help does not advertise ${want} (what --env docker resolves); it says:" >&2
         printf '%s\n' "${help}" | grep -n 'default' -A1 | sed 's/^/      /' >&2
         return 1 ;;
    esac
    want="https://localhost:${OVERRIDE_PORT}"
    help="$( eval "${CLEAR_ENV}"; export PUBLIC_HTTPS_PORT="${OVERRIDE_PORT}"; cd "${REPO}" && bash "${RUN_SH}" --help 2>&1 )"
    case "${help}" in
      *"${want}"*) return 0 ;;
      *) echo "    under PUBLIC_HTTPS_PORT=${OVERRIDE_PORT} --help still does not say ${want} — the default it prints is a literal" >&2
         return 1 ;;
    esac
}
if check_help_names_the_door; then
  ok "--help advertises the same docker door the table resolves, and follows PUBLIC_HTTPS_PORT"
else
  bad "the usage text names a different docker door than the resolver"
fi

# 4c. The bundled-browser path. When hugmeshgames-e2e:latest exists, a legacy
# invocation runs INSIDE a container that sees only what -e hands it, so run.sh
# resolves the docker door on the host and passes it as SNAP_BASE_URL. That
# argv is the third copy of the fallback and the one no --print-command shows.
# A recording `docker` stub, on PATH only for THIS check (it would hijack every
# legacy stub_run above), says the image exists and records `docker run`'s argv.
DOCKER_STUB_DIR="${WORK}/docker-stub"; mkdir -p "${DOCKER_STUB_DIR}"
cat > "${DOCKER_STUB_DIR}/docker" <<'STUB'
#!/usr/bin/env bash
# Recording stub: `image inspect` says the image EXISTS; `run` records its argv
# and runs nothing.
case "${1-}" in
  image) exit 0 ;;
  run) { echo "DOCKER-RUN"; for a in "$@"; do printf 'ARG\t%s\n' "${a}"; done; echo "END"; } >> "${DOCKER_STUB_LOG}"
       exit 0 ;;
esac
exit 0
STUB
chmod +x "${DOCKER_STUB_DIR}/docker"
# docker_path_url <log> [port|SNAP_BASE_URL=<url>] -> the SNAP_BASE_URL the container was handed
docker_path_url() {
    local log knob
    log="$1"; knob="${2-}"
    : > "${log}"
    ( eval "${CLEAR_ENV}"
      case "${knob}" in
        SNAP_BASE_URL=*) export SNAP_BASE_URL="${knob#SNAP_BASE_URL=}" ;;
        ?*)              export PUBLIC_HTTPS_PORT="${knob}" ;;
      esac
      cd "${REPO}" && DOCKER_STUB_LOG="${log}" PATH="${DOCKER_STUB_DIR}:${STUB_DIR}:${PATH}" \
        E2E_PASSWORD="cli-lane-stub-never-authenticates-anything" SNAP_EVIDENCE_SUMMARY=0 \
        bash "${RUN_SH}" --reporter=list specs/01-front-page.spec.ts >"${log}.out" 2>&1 )
    grep -c '^DOCKER-RUN$' "${log}" >/dev/null 2>&1 || {
      echo "    the bundled-browser path never ran \`docker run\` (see ${log}.out)" >&2; return 1; }
    awk -F'\t' '/^ARG\t/ && $2 ~ /^SNAP_BASE_URL=/ { sub(/^SNAP_BASE_URL=/, "", $2); print $2; exit }' "${log}"
}
check_docker_path_door() {
    local seen want
    seen="$(docker_path_url "${WORK}/docker-path.log")" || return 1
    want="$(bash_url docker)"
    [ -n "${seen}" ] || { echo "    docker run was handed no SNAP_BASE_URL at all" >&2; return 1; }
    [ "${seen}" = "${want}" ] || {
      echo "    docker run was handed SNAP_BASE_URL='${seen}' while --env docker resolves '${want}'" >&2; return 1; }
    seen="$(docker_path_url "${WORK}/docker-path-knob.log" "${OVERRIDE_PORT}")" || return 1
    [ "${seen}" = "https://localhost:${OVERRIDE_PORT}" ] || {
      echo "    under PUBLIC_HTTPS_PORT=${OVERRIDE_PORT} the container was handed '${seen}' — a literal, not the knob" >&2; return 1; }
    # …and a caller's own SNAP_BASE_URL is forwarded untouched (the legacy contract).
    seen="$(docker_path_url "${WORK}/docker-path-caller.log" "SNAP_BASE_URL=https://caller.example:1")" || return 1
    [ "${seen}" = "https://caller.example:1" ] || {
      echo "    the caller's SNAP_BASE_URL was rewritten to '${seen}'" >&2; return 1; }
    return 0
}
if check_docker_path_door; then
  ok "the bundled-browser docker path hands the container the same docker door (and a caller's SNAP_BASE_URL untouched)"
else
  bad "the docker-image path hands the container a DIFFERENT docker door than --env docker resolves"
fi

# ── 5. the evidence summary ──────────────────────────────────────────────────
echo
echo "-- 5. is the evidence manifest reachable, correct, and never vacuously green? --"
# A HAND-WRITTEN manifest, not one captured from a run: validating a reader
# against output produced by the same code path proves nothing.
EVDIR="${WORK}/ev/bdd-steps/fixture-run"
mkdir -p "${EVDIR}"
: > "${EVDIR}/a.png"; : > "${EVDIR}/b.cli.json"; : > "${EVDIR}/c.studio.png"
cat > "${EVDIR}/manifest.json" <<'JSON'
{
  "schema": "hugmesh.bdd.evidence-manifest/1",
  "runId": "fixture-run",
  "root": "IGNORED",
  "generatedAt": "2026-01-01T00:00:00.000Z",
  "counts": { "artefacts": 999, "failed": 999, "byEnv": {"lies": 999},
              "byInterface": {"lies": 999}, "byKind": {"lies": 999} },
  "artefacts": [
    {"env":"docker","interface":"browser","feature":"f","scenario":"s1","step":"x","ordinal":1,
     "role":null,"service":"gateway","platform":null,"layer":"ui","failed":false,
     "kind":"screenshot","path":"a.png","sidecar":"a.json","bytes":1,"at":"t","note":""},
    {"env":"kind","interface":"cli","feature":"f","scenario":"s2","step":"y","ordinal":1,
     "role":null,"service":null,"platform":null,"layer":null,"failed":true,
     "kind":"transcript","path":"b.cli.json","sidecar":"b.json","bytes":1,"at":"t","note":""},
    {"env":"qemu","interface":"studio","feature":"g","scenario":"s3","step":"z","ordinal":1,
     "role":null,"service":null,"platform":null,"layer":null,"failed":false,
     "kind":"widget-grab","path":"c.studio.png","sidecar":"c.json","bytes":1,"at":"t","note":""}
  ]
}
JSON
# The counts block above is DELIBERATELY WRONG (999s). The summary must count
# the rows itself; echoing manifest.counts back would make a miscounted index
# agree with itself forever.

evidence_json() {  # evidence_json <report-dir> <run-id>
  ( cd "${REPO}" && bash "${RUN_SH}" --evidence --json --report-dir "$1" --run-id "$2" 2>/dev/null )
}
check_evidence_summary() {
    # Through a FILE, never an interpolated heredoc: an unquoted heredoc would
    # let bash execute anything $-like or backticked inside the JSON.
    evidence_json "${WORK}/ev" fixture-run > "${WORK}/ev-summary.json"
    python3 - "${WORK}/ev-summary.json" <<'PY'
import json, sys
try:
    s = json.load(open(sys.argv[1]))
except Exception as e:
    print("    evidence --json did not emit JSON: %s" % e); sys.exit(1)
want = {
  "counts.artefacts": 3, "counts.failed": 1, "counts.missingOnDisk": 0,
  "scenarios": 3, "features": 2,
}
bad = []
for k, v in want.items():
    cur = s
    for part in k.split('.'):
        cur = cur.get(part) if isinstance(cur, dict) else None
    if cur != v:
        bad.append("%s = %r (wanted %r)" % (k, cur, v))
for axis, wanted in (("byEnv", {"docker":1,"kind":1,"qemu":1}),
                     ("byInterface", {"browser":1,"cli":1,"studio":1}),
                     ("byKind", {"screenshot":1,"transcript":1,"widget-grab":1})):
    got = s.get("counts", {}).get(axis)
    if got != wanted:
        bad.append("counts.%s = %r (wanted %r)" % (axis, got, wanted))
for b in bad:
    print("    " + b)
sys.exit(1 if bad else 0)
PY
}
if check_evidence_summary; then
  ok "--evidence counts the ROWS per env / per interface / per kind (not the index's own tally)"
else
  bad "the evidence summary does not report what the manifest actually holds"
fi

check_evidence_refuses_nothing() {
    local rc
    ( cd "${REPO}" && bash "${RUN_SH}" --evidence \
        --report-dir "${WORK}/no-such-report-dir" --run-id nothing >"${WORK}/ev-missing.out" 2>&1 )
    rc=$?
    if [ "${rc}" -eq 0 ]; then
      echo "    an ABSENT evidence dir was reported as success (rc=0)" >&2; return 1
    fi
    grep -F "no evidence directory" "${WORK}/ev-missing.out" >/dev/null || {
      echo "    the failure does not say what was missing:" >&2
      sed -n '1,4p' "${WORK}/ev-missing.out" >&2; return 1; }
    # …and an index that points at files nobody can open must also fail.
    mkdir -p "${WORK}/ev2/bdd-steps/ghost-run"
    sed 's/"path":"a.png"/"path":"gone.png"/' "${EVDIR}/manifest.json" \
      > "${WORK}/ev2/bdd-steps/ghost-run/manifest.json"
    ( cd "${REPO}" && bash "${RUN_SH}" --evidence \
        --report-dir "${WORK}/ev2" --run-id ghost-run >"${WORK}/ev-ghost.out" 2>&1 )
    rc=$?
    if [ "${rc}" -eq 0 ]; then
      echo "    a manifest row pointing at a MISSING file was reported as success" >&2; return 1
    fi
    return 0
}
if check_evidence_refuses_nothing; then
  ok "--evidence refuses an empty success and refuses an index full of missing files"
else
  bad "--evidence can report success having found nothing"
fi

# ── 6. the real lane still generates, is collected, and is green offline ─────
echo
echo "-- 6. the real thing (no stubs): generate, collect, run the cli lane --"
( cd "${E2E}" && \
  npx bddgen >"${WORK}/bddgen.out" 2>&1 )
if [ $? -eq 0 ]; then
  ok "npx bddgen exits 0 with the cli lane present"
else
  bad "npx bddgen FAILED — see ${WORK}/bddgen.out"
  grep -viE 'npm notice' "${WORK}/bddgen.out" | tail -20 >&2
fi

( cd "${E2E}" && \
  npx playwright test --list --project=bdd --reporter=line >"${WORK}/list.out" 2>&1 )
CLI_COLLECTED="$(grep -c 'features/cli/' "${WORK}/list.out")"
if [ "${CLI_COLLECTED}" -ge 17 ]; then
  ok "playwright collects ${CLI_COLLECTED} scenario(s) from features/cli/"
else
  bad "playwright collected only ${CLI_COLLECTED} scenario(s) from features/cli/ (expected >= 17)"
fi

( cd "${E2E}" && \
  SNAP_REPORT_DIR="${WORK}/lane" SNAP_RUN_ID=cli-lane-guard \
  npx playwright test --project=bdd .features-gen/features/cli/ --reporter=line \
    >"${WORK}/lane.out" 2>&1 )
LANE_RC=$?
if [ "${LANE_RC}" -eq 0 ]; then
  ok "the cli feature lane is green (rc=0) with NOTHING started"
else
  bad "the cli feature lane rc=${LANE_RC} — see ${WORK}/lane.out"
  grep -viE 'npm notice' "${WORK}/lane.out" | tail -25 >&2
fi
# …and it left real evidence, reachable through the same entry point.
if EV="$(evidence_json "${WORK}/lane" cli-lane-guard)" && \
   echo "${EV}" | python3 -c 'import json,sys; s=json.load(sys.stdin); sys.exit(0 if s["counts"]["byInterface"].get("cli",0) > 0 and s["counts"]["missingOnDisk"]==0 else 1)'; then
  ok "that run's evidence is reachable from the CLI and every row is on disk"
else
  bad "the cli lane ran but its evidence is not reachable/complete: ${EV:-<no output>}"
fi

# ── 7. MUTATION BATTERY ──────────────────────────────────────────────────────
echo
echo "-- mutation battery: break production, prove the guard notices --"
CAUGHT=0; SURVIVED=0
mut_result() {
  if [ "$2" -eq 1 ]; then
    echo "  CAUGHT   $1"; CAUGHT=$((CAUGHT+1))
  else
    echo "  SURVIVED $1  <-- $3"; SURVIVED=$((SURVIVED+1)); F=$((F+1))
  fi
}

# M1 — the environment is never exported, so the runner drives the default mesh.
if mutate tests/e2e/run.sh <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('  export SNAP_ENV="${ENV_ID}"\n', '  : # M1: env not forwarded\n')
open(p, 'w').write(s)
PY
then
  if check_env_forwarding >/dev/null 2>&1; then
    mut_result "M1 --env is not exported to the runner" 0 "check 1 stayed green"
  else
    mut_result "M1 --env is not exported to the runner" 1
  fi
else
  mut_result "M1 --env is not exported to the runner" 0 "mutation did not apply"
fi
restore_all

# M2 — the feature selection is dropped, so playwright runs the whole suite.
if mutate tests/e2e/run.sh <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('PW_ARGV+=("${SELECTED[@]+"${SELECTED[@]}"}")',
              ': # M2: feature selection dropped')
open(p, 'w').write(s)
PY
then
  if check_feature_forwarding >/dev/null 2>&1; then
    mut_result "M2 --features never reaches playwright" 0 "check 2 stayed green"
  else
    mut_result "M2 --features never reaches playwright" 1
  fi
else
  mut_result "M2 --features never reaches playwright" 0 "mutation did not apply"
fi
restore_all

# M3 — THE WORST ONE. The runner's exit code is swallowed and every run is green.
if mutate tests/e2e/run.sh <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('exit "${rc}"\n', 'exit 0  # M3: exit code swallowed\n')
open(p, 'w').write(s)
PY
then
  if check_exit_propagation >/dev/null 2>&1; then
    mut_result "M3 the runner's exit code is swallowed" 0 "check 3 stayed green"
  else
    mut_result "M3 the runner's exit code is swallowed" 1
  fi
else
  mut_result "M3 the runner's exit code is swallowed" 0 "mutation did not apply"
fi
restore_all

# M4 — the tag expression is dropped, so a narrowed run silently runs everything.
if mutate tests/e2e/run.sh <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('[ -z "${TAGS}" ] || GEN_ARGV+=(--tags "${TAGS}")',
              ': # M4: tags dropped')
open(p, 'w').write(s)
PY
then
  if check_tag_forwarding >/dev/null 2>&1; then
    mut_result "M4 --tags never reaches bddgen" 0 "check 2 stayed green"
  else
    mut_result "M4 --tags never reaches bddgen" 1
  fi
else
  mut_result "M4 --tags never reaches bddgen" 0 "mutation did not apply"
fi
restore_all

# M5 — a failed generation is ignored and a PARTIAL suite runs, looking green.
if mutate tests/e2e/run.sh <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
# Built by joining single-quoted lines: the anchor ENDS in a double quote, and
# wrapping that in a python triple-double-quoted literal terminates it early.
old = '\n'.join([
    '    echo "        generated lane collects fewer scenarios and looks green." >&2',
    '    exit "${rc}"',
])
assert old in s, "M5 anchor missing"
new = '\n'.join([
    '    echo "        generated lane collects fewer scenarios and looks green." >&2',
    '    :  # M5: complain, then run anyway',
])
s = s.replace(old, new)
open(p, 'w').write(s)
PY
then
  if check_gen_failure_stops_the_run >/dev/null 2>&1; then
    mut_result "M5 a failed bddgen no longer stops the run" 0 "check 3b stayed green"
  else
    mut_result "M5 a failed bddgen no longer stops the run" 1
  fi
else
  mut_result "M5 a failed bddgen no longer stops the run" 0 "mutation did not apply"
fi
restore_all

# M6 — the summariser reports an absent run as a clean, empty success.
if mutate tests/e2e/evidence-report.mjs <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "const fail = (msg) => {\n  process.stderr.write(`evidence: ${msg}\\n`);\n  process.exit(3);\n};"
assert old in s, "M6 anchor missing"
s = s.replace(old, "const fail = (msg) => {\n  process.stdout.write(`evidence: nothing recorded (${msg.split('\\n')[0]})\\n`);\n  process.exit(0);  // M6: empty success\n};")
open(p, 'w').write(s)
PY
then
  if check_evidence_refuses_nothing >/dev/null 2>&1; then
    mut_result "M6 an empty evidence dir is reported as success" 0 "check 5b stayed green"
  else
    mut_result "M6 an empty evidence dir is reported as success" 1
  fi
else
  mut_result "M6 an empty evidence dir is reported as success" 0 "mutation did not apply"
fi
restore_all

# M7 — the summary echoes the index's OWN counts back instead of counting rows,
# so a manifest that miscounts itself is confirmed by its own summary.
if mutate tests/e2e/evidence-report.mjs <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "    byEnv: tally((r) => r.env),"
assert old in s, "M7 anchor missing"
s = s.replace(old, "    byEnv: (manifest.counts || {}).byEnv || {},  // M7: trust the index")
open(p, 'w').write(s)
PY
then
  if check_evidence_summary >/dev/null 2>&1; then
    mut_result "M7 the summary trusts the index's own tally" 0 "check 5 stayed green"
  else
    mut_result "M7 the summary trusts the index's own tally" 1
  fi
else
  mut_result "M7 the summary trusts the index's own tally" 0 "mutation did not apply"
fi
restore_all

# M8 — the bdd project is forced on every run, so run-all.sh and
# run-qemu-e2e.sh silently stop running the 33 handwritten specs.
if mutate tests/e2e/run.sh <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = 'if [ "${LANE}" = "bdd" ]; then PW_ARGV+=(--project=bdd); fi'
assert old in s, "M8 anchor missing"
s = s.replace(old, 'PW_ARGV+=(--project=bdd)  # M8: always the bdd lane')
open(p, 'w').write(s)
PY
then
  if check_legacy_passthrough >/dev/null 2>&1; then
    mut_result "M8 every run is forced onto the bdd project" 0 "check 1b stayed green"
  else
    mut_result "M8 every run is forced onto the bdd project" 1
  fi
else
  mut_result "M8 every run is forced onto the bdd project" 0 "mutation did not apply"
fi
restore_all

# M9 — the env table's docker door goes back to the literal that drifted. The
# TypeScript did not change, so the recorded ENVIRONMENT_DEFS answer is the
# reference; a second playwright launch would measure the same thing slower.
if mutate tests/e2e/run.sh <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = 'docker) url="${SNAP_ENV_DOCKER_BASE_URL:-${SNAP_BASE_URL:-${DOCKER_DEFAULT_BASE_URL}}}" ;;'
assert s.count(old) == 1, "M9 anchor not unique: %d" % s.count(old)
s = s.replace(old, 'docker) url="${SNAP_ENV_DOCKER_BASE_URL:-${SNAP_BASE_URL:-https://localhost:8443}}" ;;  # M9')
open(p, 'w').write(s)
PY
then
  if [ -n "$(ts_url docker)" ] && [ "$(bash_url docker)" != "$(ts_url docker)" ]; then
    mut_result "M9 the env table's docker door is a literal 8443 again" 1
  else
    mut_result "M9 the env table's docker door is a literal 8443 again" 0 "check 4 stayed green (bash=$(bash_url docker) ts=$(ts_url docker))"
  fi
else
  mut_result "M9 the env table's docker door is a literal 8443 again" 0 "mutation did not apply"
fi
restore_all

# M10 — the usage text advertises the literal while the table resolves the knob.
if mutate tests/e2e/run.sh <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '  __DOCKER_DEFAULT_BASE_URL__ '
assert s.count(old) == 1, "M10 anchor not unique: %d" % s.count(old)
s = s.replace(old, '  https://localhost:8443 ')
open(p, 'w').write(s)
PY
then
  if check_help_names_the_door >/dev/null 2>&1; then
    mut_result "M10 the usage text names a literal docker door" 0 "check 4b stayed green"
  else
    mut_result "M10 the usage text names a literal docker door" 1
  fi
else
  mut_result "M10 the usage text names a literal docker door" 0 "mutation did not apply"
fi
restore_all

# M11 — the bundled-browser path hands the container the literal.
if mutate tests/e2e/run.sh <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '-e SNAP_BASE_URL="${SNAP_BASE_URL:-$(env_base_url docker)}"'
assert s.count(old) == 1, "M11 anchor not unique: %d" % s.count(old)
s = s.replace(old, '-e SNAP_BASE_URL="${SNAP_BASE_URL:-https://localhost:8443}"')
open(p, 'w').write(s)
PY
then
  if check_docker_path_door >/dev/null 2>&1; then
    mut_result "M11 the docker-image path hands the container a literal 8443" 0 "check 4c stayed green"
  else
    mut_result "M11 the docker-image path hands the container a literal 8443" 1
  fi
else
  mut_result "M11 the docker-image path hands the container a literal 8443" 0 "mutation did not apply"
fi
restore_all

echo "  mutations: ${CAUGHT} caught, ${SURVIVED} survived"

# ── 8. the tree is exactly as we found it ────────────────────────────────────
tree_fingerprint > "${WORK}/tree-after.md5"
if diff -q "${WORK}/tree-before.md5" "${WORK}/tree-after.md5" >/dev/null; then
  ok "every mutation was reverted (the files under test are byte-identical to pre-run)"
else
  bad "THE TREE IS NOT RESTORED — a mutation is still on disk:"
  diff "${WORK}/tree-before.md5" "${WORK}/tree-after.md5" >&2
fi

echo
echo "-- every stub_run reached the runner (else nothing above measured anything) --"
if [ -n "${STUB_RUN_NEVER_REACHED}" ]; then
  bad "run.sh exited before invoking the runner in: ${STUB_RUN_NEVER_REACHED}
       => stub_args/stub_env answer \"\" for an unwritten log, and \"\" compares
          unequal to every expectation, so the checks above did not fail honestly —
          they reported verdicts about a run that never happened. Fix the setup
          before believing anything this suite said."
else
  ok "every stub_run invoked the runner, so the recordings the checks read are real"
fi

echo
echo "== e2e CLI lane: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ] || exit 1
exit 0

#!/usr/bin/env bash
# test-e2e-coverage-matrix.sh — THE DRIFT GUARD for the generative coverage
# matrix (tests/e2e/features/coverage/, emitted by tests/e2e/tools/emit-coverage-matrix.ts).
#
# THIRD SIBLING to test-e2e-gherkin-harness.sh (every .feature generates and
# runs) and test-e2e-env-interface-dimensions.sh (the env/interface axes mean
# something). This one proves the MATRIX is complete and stays complete:
#
#   A. the committed features are EXACTLY what the catalogues emit today, so a
#      catalogue change that was never re-emitted — or a hand edit to a generated
#      file — is caught before it can pass for coverage;
#   B. every PERSONA in the roster has scenarios that actually GENERATE;
#   C. every SERVICE in SERVICES has scenarios that actually generate;
#   D. every FUNCTION in the catalogue has scenarios that actually generate;
#   E. every PERSONA x SERVICE pair carries an expected-OUTCOME assertion
#      (admitted | refused), not merely a page-loaded assertion;
#   F. the reverse direction — no generated scenario names a persona, service or
#      function the catalogues no longer carry.
#
# HOW B-F ARE DERIVED. The expected sets are computed FROM THE CATALOGUES at
# guard time (steps/coverage-catalogue.ts, steps/dimensions.ts) and compared with
# the titles `npx playwright test --list --project=bdd` actually reports. Nothing
# here restates a hard-coded list: that is the exact vacuity that lets a registry
# grow while its guard proves nothing. Measured by EXECUTION (what generates),
# never by reading the .feature files.
#
# MUTATION BATTERY. Six mutations, each applied to the REAL tree with a backup
# and restored on EXIT via trap. Every one must turn this guard RED; the final
# check asserts the tree is byte-identical to how it started, so a half-restored
# tree is a failure rather than a surprise for the next agent.
#
# KILL SEMANTICS (measured 2026-08-27; this file's own harness,
# tests/scripts/test-e2e-coverage-matrix-harness.sh, proves them by sending the
# kill). The old shape — `trap cleanup EXIT INT TERM HUP` where cleanup removed
# the scratch dir and RETURNED — made a `timeout` mid-lane produce a run that
# BLUNDERED ON without its scratch dir: "rc=''" for the lane, six "patch did not
# apply" survivors and "THE TREE WAS NOT FULLY RESTORED — No such file or
# directory", every word of it about the guard's own bookkeeping. Two rules now:
#   * every long-running child runs in the BACKGROUND under `wait`, because bash
#     defers signal traps while blocked on a foreground child (a command
#     substitution included) — a TERM used to sit queued behind minutes of lane;
#   * the signal handler stops the in-flight child subtree, RESTORES the tree,
#     VERIFIES the restore against the pre-run fingerprint, says so, removes the
#     scratch dir and EXITS 128+signum. It never returns into the script.
# A SIGKILL still cannot be caught; the poisoned-tree preflight below is what
# protects the NEXT run in that case.
#
# OFFLINE. Starts NOTHING — no stack, no cluster, no emulator, no image build,
# no sudo. Every assertion reads a committed file or runs the Gherkin lane, which
# is itself stack-free.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
E2E="${REPO}/tests/e2e"
COVERAGE_DIR="${E2E}/features/coverage"
CATALOGUE="${E2E}/steps/coverage-catalogue.ts"
EMITTER="${E2E}/tools/emit-coverage-matrix.ts"

# WHERE THE BROWSER LIVES. This guard NEVER defaults PLAYWRIGHT_BROWSERS_PATH.
# It once pinned /var/tmp/portage/pw-browsers "because six siblings did" — a
# host-local symlink farm that DANGLES after any `npx playwright install`
# garbage-collects the revision it points at (see
# reference_hugmesh_pw_browsers_symlink_farm). Measured 2026-08-27 on this box:
# with the dangling pin, the 124-cell wiki spec took 101.6s (every cell
# `browserType.launch: Executable doesn't exist`, TWICE each under the config's
# retries:1) versus 15.2s green with the variable simply unset — extrapolated
# over the 2105-cell lane that is ~29 minutes of red about the toolchain, which
# is exactly the >25-minute timeout kill this note replaces. The variable is
# honoured ONLY if the caller set it; otherwise Playwright resolves its own
# store (~/.cache/ms-playwright), exactly as `make stack-e2e-bdd` does. The
# preflight below proves ONE launch before the lane may start.

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

echo "== e2e coverage matrix: every persona x every function x every service =="

# ── preconditions: refuse to be vacuous ──────────────────────────────────────
for t in node python3 git bash; do
  command -v "${t}" >/dev/null 2>&1 || {
    echo "SKIPPED-LOUDLY: ${t} is required and absent — this guard checked NOTHING." >&2
    exit 2
  }
done
# ONE readiness opinion, not a second one: tests/e2e/check-toolchain.sh verifies
# node_modules against the COMMITTED lock and the browser revision under the
# SAME resolution the lane runs with — the caller's PLAYWRIGHT_BROWSERS_PATH if
# they set it, otherwise Playwright's own store — because this guard no longer
# defaults the variable (see WHERE THE BROWSER LIVES above). The probe call
# carried `:-/var/tmp/portage/pw-browsers` when it landed (true of the OLD guard,
# which pinned that path); with the pin gone from the lane, pinning it in the
# probe would refuse a green lane over a store the lane never touches — the
# wrong-question shape. `[ -d node_modules/playwright-bdd ]` used to stand here
# and said nothing about the lock or the browser — MEASURED 2026-08-27: dangling
# r1228 -> r1234 aliases got past it and every browser scenario died on
# "Executable doesn't exist", the toolchain gap wearing the costume of a product
# failure. In the HARNESS's scratch tree this probe is a stub (exit 0), exactly
# like the playwright beside it — the harness grades this guard's orchestration,
# not the box's toolchain.
if ! bash "${E2E}/check-toolchain.sh"; then
  echo "SKIPPED-LOUDLY: the e2e toolchain is not ready (above). This guard checked NOTHING. Exiting 2 rather than 0." >&2
  exit 2
fi
for f in "${CATALOGUE}" "${EMITTER}" "${E2E}/gen-coverage-matrix.sh"; do
  [ -f "${f}" ] || {
    echo "SKIPPED-LOUDLY: ${f} is missing; there is nothing to guard. Exiting 2." >&2
    exit 2
  }
done

WORK="${TMPDIR:-/var/tmp/portage}/coverage-matrix-guard.$$"
mkdir -p "${WORK}"

# Byte fingerprint of every file the battery may touch, taken BEFORE anything is
# broken. The last check diffs against it — and so does the SIGNAL handler,
# before the scratch dir (and this fingerprint with it) is removed.
tree_fingerprint() {
  ( cd "${REPO}" \
    && find tests/e2e/steps tests/e2e/tools tests/e2e/features/coverage -type f \
         \( -name '*.ts' -o -name '*.feature' \) | sort | xargs md5sum
    md5sum tests/e2e-extra-personas.sh )
}
tree_fingerprint > "${WORK}/tree-before.md5"

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

# ── run children in the BACKGROUND, wait interruptibly ───────────────────────
# bash runs a signal trap only after the current FOREGROUND child completes, and
# `rc="$(run_lane …)"` was exactly that: a TERM arriving mid-lane waited out the
# lane (or, under `timeout`, the process group died around the still-blocked
# script). `wait` on a background child, by contrast, returns the moment a
# trapped signal lands. RUN_RC carries the child's status; CHILD is what the
# signal handler stops.
CHILD=""
RUN_RC=0
run_bg() {
  local log="$1"; shift
  "$@" > "${log}" 2>&1 & CHILD=$!
  RUN_RC=0
  wait "${CHILD}" || RUN_RC=$?
  CHILD=""
}
_in_e2e()    ( cd "${E2E}" && "$@" )
_in_bridge() ( cd "${BRIDGE}" && "$@" )

# TERM the whole subtree, deepest first: the direct child is a subshell whose
# npx/node grandchildren would otherwise be orphaned mid-write.
kill_tree() {
  local pid="$1" c
  if command -v pgrep >/dev/null 2>&1; then
    for c in $(pgrep -P "${pid}" 2>/dev/null); do kill_tree "${c}"; done
  fi
  kill -TERM "${pid}" 2>/dev/null || true
}

# The one path a kill takes. Restore FIRST, verify the restore, say so, and only
# then remove the scratch dir — the order matters, because the fingerprint the
# verification needs lives inside it. Never returns.
on_signal() {
  local name="$1" num="$2"
  trap '' INT TERM HUP EXIT
  echo ""
  echo "KILLED BY SIG${name} — stopping the in-flight lane and restoring the tree."
  if [ -n "${CHILD}" ]; then
    kill_tree "${CHILD}"
    wait "${CHILD}" 2>/dev/null || true
    CHILD=""
  fi
  restore_all
  if tree_fingerprint 2>/dev/null | diff -q "${WORK}/tree-before.md5" - >/dev/null 2>&1; then
    echo "the guarded tree is byte-identical to pre-run — restored under the kill."
  else
    echo "RESTORE UNDER THE KILL DID NOT VERIFY — check the mutation targets with:"
    echo "    git -C ${REPO} status ${MUTATION_TARGETS[*]-}"
  fi
  rm -rf "${WORK}"
  echo "NOTHING WAS VERIFIED by this run: it was killed, not failed."
  exit $((128 + num))
}
trap 'on_signal INT 2'   INT
trap 'on_signal TERM 15' TERM
trap 'on_signal HUP 1'   HUP
trap cleanup EXIT

# ── PREFLIGHT: REFUSE TO RUN ON A TREE A PREVIOUS RUN POISONED ───────────────
# The battery mutates these files. A SIGKILL (which no trap can catch) — or the
# pre-2026-08-27 trap shape — can leave them mutated with no marker, and every
# clause below would then be evaluated against a broken oracle. The M4 stub in
# particular makes seedDecision() admit EVERYONE, which does not fail loudly:
# the emit-vs-committed diff goes red for reasons that read like ordinary drift,
# and a reader "fixes" it by re-emitting, baking the poison into the tree.
#
# So: before touching anything, require every mutation target to match git HEAD.
# This does not detect a *legitimate* uncommitted edit, and it must not — it
# names the files and tells you how to check, rather than reverting work.
MUTATION_TARGETS=(
  tests/e2e-extra-personas.sh
  tests/e2e/steps/dimensions.ts
  tests/e2e/steps/coverage-catalogue.ts
  tests/e2e/features/coverage/access-matrix-wiki.feature
)
preflight_clean_tree() {
  git -C "${REPO}" rev-parse --git-dir >/dev/null 2>&1 || return 0
  local dirty=() rel
  for rel in "${MUTATION_TARGETS[@]}"; do
    git -C "${REPO}" diff --quiet HEAD -- "${rel}" 2>/dev/null || dirty+=("${rel}")
  done
  [ "${#dirty[@]}" -eq 0 ] && return 0
  echo "REFUSING TO RUN: ${#dirty[@]} file(s) this guard mutates differ from git HEAD:" >&2
  for rel in "${dirty[@]}"; do echo "    ${rel}" >&2; done
  echo "" >&2
  echo "If these are YOUR edits, commit or stash them and re-run." >&2
  echo "If you did not edit them, a PREVIOUS RUN OF THIS GUARD WAS KILLED before" >&2
  echo "it restored them — check for the always-admit stub with:" >&2
  echo "    grep -n \"why: 'M4'\" tests/e2e/steps/coverage-catalogue.ts" >&2
  echo "and restore with:  git -C ${REPO} checkout -- ${MUTATION_TARGETS[*]}" >&2
  echo "" >&2
  echo "Exiting 2. NOTHING WAS CHECKED — running on a poisoned oracle would be" >&2
  echo "worse than not running at all." >&2
  return 1
}
preflight_clean_tree || exit 2


# mutate <relpath> <python-patch-file> — apply and PROVE the file changed. A
# mutation that silently failed to apply would report a false CAUGHT, which is
# worse than a survivor because it claims coverage that does not exist.
mutate() {
  local rel="$1" patch="$2" before after
  save_file "${rel}"
  before="$(md5sum "${REPO}/${rel}" | cut -d' ' -f1)"
  python3 "${patch}" "${REPO}/${rel}" || return 1
  after="$(md5sum "${REPO}/${rel}" | cut -d' ' -f1)"
  [ "${before}" != "${after}" ] || {
    echo "  MUTATION DID NOT APPLY to ${rel} — the anchor text moved. This mutation"
    echo "  proves NOTHING; treat it as a survivor and fix the patch." >&2
    return 1
  }
  return 0
}

# ── the TS bridge ────────────────────────────────────────────────────────────
# node cannot load the catalogue: steps/dimensions.ts imports '../specs/rbac-roles'
# extensionless and node's type-stripping resolves .ts as ESM, which has no
# extension search (measured on node v26.7.0). Playwright's TypeScript transform
# resolves it exactly as the suite does. Config + spec live in $WORK with
# node_modules SYMLINKED beside them, because module resolution walks up from the
# CONFIG's own directory.
BRIDGE="${WORK}/bridge"; mkdir -p "${BRIDGE}"
ln -sfn "${E2E}/node_modules" "${BRIDGE}/node_modules"
# outputDir inside the scratch dir: Playwright otherwise writes
# test-results/.last-run.json relative to the invoking cwd, littering the repo.
cat > "${BRIDGE}/pw.config.ts" <<'TS'
import { defineConfig } from '@playwright/test';
import * as path from 'node:path';
export default defineConfig({
  testDir: __dirname, outputDir: path.join(__dirname, 'pw-out'),
  reporter: [['dot']], workers: 1, retries: 0, timeout: 120_000,
});
TS
# QUOTED heredoc + sed'd placeholders — an unquoted one would let bash execute
# the backticks and ${...} inside the TypeScript below.
cat > "${BRIDGE}/dump.spec.ts" <<'TS'
import { test } from '@playwright/test';
import * as fs from 'node:fs';
import { SERVICES } from '__DIMENSIONS__';
import { roster, FUNCTIONS, coverageCells, functionsForService } from '__CATALOGUE__';

test('dump the expected coverage set', () => {
  const services = SERVICES.map((s: any) => s.id);
  const personas = roster().map((p: any) => p.handle);
  const functions = FUNCTIONS.map((f: any) => f.id);
  const cells = coverageCells().map((c: any) => `${c.handle}|${c.functionId}|${c.outcome}`);
  const pairs: string[] = [];
  for (const p of personas) {
    for (const s of services) {
      if (functionsForService(s).length > 0) pairs.push(`${p}|${s}`);
    }
  }
  fs.writeFileSync('__OUT__', JSON.stringify(
    { services, personas, functions, cells, pairs }, null, 1));
});
TS
sed -i -e "s|__DIMENSIONS__|${E2E}/steps/dimensions|" \
       -e "s|__CATALOGUE__|${E2E}/steps/coverage-catalogue|" \
       -e "s|__OUT__|${WORK}/expected.json|" "${BRIDGE}/dump.spec.ts"

# ── PREFLIGHT: ONE REAL LAUNCH BEFORE 2105 CELLS MAY TRY ─────────────────────
# One page.goto('about:blank') through the same resolution the lane uses. When
# the browser cannot launch, every cell of the lane fails the same way — twice
# each under the config's retries:1 — and the run reports ~29 minutes of red
# that reads like a total coverage collapse but is a tooling gap (measured
# 2026-08-27, 0.82s/cell dead vs 0.12s/cell green). Refuse in seconds instead.
cat > "${BRIDGE}/preflight.spec.ts" <<'TS'
import { test } from '@playwright/test';
test('the browser launches', async ({ page }) => { await page.goto('about:blank'); });
TS
run_bg "${WORK}/preflight.out" _in_bridge \
  npx --prefix "${E2E}" playwright test -c "${BRIDGE}/pw.config.ts" preflight.spec.ts --reporter=line
if [ "${RUN_RC}" != "0" ]; then
  echo "SKIPPED-LOUDLY: the browser cannot launch — one page.goto('about:blank') failed:" >&2
  sed -n '1,25p' "${WORK}/preflight.out" >&2
  echo "" >&2
  echo "PLAYWRIGHT_BROWSERS_PATH is ${PLAYWRIGHT_BROWSERS_PATH:-unset (playwright resolves its own store)} — if you set" >&2
  echo "it, unset it or point it at a store that actually holds this playwright's" >&2
  echo "revision. Install with: make playwright-deps" >&2
  echo "  [or: (cd tests/e2e && npx playwright install chromium)]" >&2
  echo "This guard checked NOTHING — the lane would have failed all 2105 cells on" >&2
  echo "the toolchain, not on coverage. Exiting 2 rather than 0 or a false red." >&2
  exit 2
fi

dump_expected() {
  rm -f "${WORK}/expected.json"
  run_bg "${WORK}/dump.out" _in_bridge \
    npx --prefix "${E2E}" playwright test -c "${BRIDGE}/pw.config.ts" dump.spec.ts --reporter=dot
  [ -s "${WORK}/expected.json" ]
}

# ── the generated listing — what ACTUALLY generates ──────────────────────────
regen_and_list() {
  local rc
  run_bg "${WORK}/bddgen.out" _in_e2e npx bddgen
  rc="${RUN_RC}"
  run_bg "${WORK}/list.out" _in_e2e npx playwright test --list --project=bdd
  return "${rc}"
}

# compare_sets — the four drift clauses plus the reverse direction, in python so
# the set algebra is exact rather than grep-shaped.
compare_sets() {
  python3 - "${WORK}/expected.json" "${WORK}/list.out" <<'PY'
import json, re, sys
exp = json.load(open(sys.argv[1]))
titles = open(sys.argv[2], encoding='utf-8', errors='replace').read().splitlines()

seen_roles, seen_services, seen_funcs = set(), set(), set()
seen_cells, seen_pairs = set(), set()
# Emitted outline titles read:
#   <role> is <outcome> at <function> @role:<role> @service:<svc> @layer:… @coverage-matrix
cell_re = re.compile(r'\bis (admitted|refused) at (\S+) @role:(\S+) @service:(\S+)')
for line in titles:
    for m in re.finditer(r'@role:([^\s]+)', line):
        seen_roles.add(m.group(1))
    for m in re.finditer(r'@service:([^\s]+)', line):
        seen_services.add(m.group(1))
    for m in cell_re.finditer(line):
        outcome, fn, role, svc = m.groups()
        seen_funcs.add(fn)
        seen_cells.add(f'{role}|{fn}|{outcome}')
        seen_pairs.add(f'{role}|{svc}')
    # function ids also appear in the function-catalogue outline titles
    for m in re.finditer(r'the (\S+\.\S+) function is catalogued', line):
        seen_funcs.add(m.group(1))

problems = []
def cmp(label, expected, seen, forward_only=False):
    missing = sorted(set(expected) - set(seen))
    extra   = sorted(set(seen) - set(expected))
    if missing:
        problems.append(f'{label}: {len(missing)} catalogued but NO scenario generates for them: '
                        + ', '.join(missing[:12]) + (' …' if len(missing) > 12 else ''))
    if extra and not forward_only:
        problems.append(f'{label}: {len(extra)} generated scenario(s) name something the '
                        f'catalogue no longer carries: '
                        + ', '.join(extra[:12]) + (' …' if len(extra) > 12 else ''))

cmp('PERSONA',  exp['personas'],  seen_roles,  forward_only=True)   # other features tag roles too
cmp('SERVICE',  exp['services'],  seen_services, forward_only=True) # ditto
cmp('FUNCTION', exp['functions'], seen_funcs)
cmp('PERSONA x SERVICE outcome assertion', exp['pairs'], seen_pairs)
cmp('CELL (persona x function x outcome)', exp['cells'], seen_cells)

print(f'COUNT personas={len(exp["personas"])} services={len(exp["services"])} '
      f'functions={len(exp["functions"])} pairs={len(exp["pairs"])} cells={len(exp["cells"])}')
print(f'COUNT generated-cells={len(seen_cells)} generated-pairs={len(seen_pairs)} '
      f'generated-functions={len(seen_funcs)}')
for p in problems:
    print('PROBLEM ' + p)
sys.exit(1 if problems else 0)
PY
}

# emit_and_diff <tag> — re-emit into a scratch dir and diff against the
# committed tree. Verdict in EMIT_R (a global, not an echo: a command
# substitution is a foreground child, and a foreground child is where a signal
# waits — see the run_bg note above).
EMIT_R=""
emit_and_diff() {
  local tag="$1" out
  out="${WORK}/emitted.${tag}"
  rm -rf "${out}"; mkdir -p "${out}"
  run_bg "${WORK}/emit.${tag}.out" bash "${E2E}/gen-coverage-matrix.sh" --out "${out}"
  if [ "${RUN_RC}" != "0" ]; then
    EMIT_R="EMIT-FAILED"
    return 2
  fi
  if diff -ruq "${COVERAGE_DIR}" "${out}" > "${WORK}/diff.${tag}.out" 2>&1; then
    EMIT_R="IDENTICAL"; return 0
  fi
  EMIT_R="DIFFERS"; return 1
}

# run_lane <tag> <glob…> — run part of the Gherkin lane; rc in LANE_RC.
# --retries=0 OVERRIDES the config's retries:1 on purpose: this guard grades
# red/green, and a retry only doubles the time a red lane takes to say so
# (measured doing exactly that, 2x on all 2105 cells).
LANE_RC=""
_lane() {
  local tag="$1"; shift
  cd "${E2E}" && SNAP_REPORT_DIR="${WORK}/rep-${tag}" SNAP_CLI_PNG=0 \
    npx playwright test --project=bdd "$@" --retries=0 --reporter=line
}
run_lane() {
  local tag="$1"; shift
  run_bg "${WORK}/run.${tag}.out" _lane "${tag}" "$@"
  LANE_RC="${RUN_RC}"
}
# How many times a lane failed to LAUNCH a browser rather than failing a cell.
# A red lane whose reds are launch failures proves nothing about coverage, so
# the battery refuses to count one as a CAUGHT.
launch_failures() { grep -c "browserType.launch" "${WORK}/run.$1.out" 2>/dev/null || true; }
# Playwright's line reporter colorises even into a redirected file (measured on
# this box: the summary line arrives as ESC[1A ESC[2K ESC[31m'  124 failed'…),
# so every ^-anchored match on lane output must strip ANSI first. Unstripped,
# the old guard read failed='' from a 124-failure lane and graded M4 SURVIVED —
# and printed an empty summary for a green one.
strip_ansi() { sed -e $'s/\x1b\[[0-9;]*[A-Za-z]//g' "${WORK}/run.$1.out" 2>/dev/null || true; }
lane_failed_count() { strip_ansi "$1" | sed -n 's/^ *\([0-9][0-9]*\) failed.*/\1/p' | tail -1; }

# ═════════════════════════════════════════════════════════════════════════════
# 1. BASELINE — the committed matrix is exactly what the catalogues emit
# ═════════════════════════════════════════════════════════════════════════════
emit_and_diff base || true
r="${EMIT_R}"
if [ "${r}" = "IDENTICAL" ]; then
  ok "the committed features/coverage/ tree is byte-identical to a fresh emit"
else
  bad "features/coverage/ has DRIFTED from the catalogues (${r}) — re-emit with"
  bad "  bash tests/e2e/gen-coverage-matrix.sh"
  sed -n '1,20p' "${WORK}/diff.base.out" >&2
fi

# ═════════════════════════════════════════════════════════════════════════════
# 2. GENERATION — bddgen accepts the matrix and the lane really appears
# ═════════════════════════════════════════════════════════════════════════════
if regen_and_list; then
  TOTAL="$(sed -n 's/^Total: \([0-9]*\) tests.*/\1/p' "${WORK}/list.out" | tail -1)"
  COVER="$(grep -c 'features/coverage/' "${WORK}/list.out" || true)"
  if [ -n "${TOTAL:-}" ] && [ "${TOTAL}" -ge 460 ] && [ "${COVER}" -gt 0 ]; then
    ok "npx bddgen rc=0; ${TOTAL} tests generate, ${COVER} of them from features/coverage/"
  else
    bad "the generated lane looks wrong: Total='${TOTAL:-?}' coverage-tests='${COVER}'"
    tail -20 "${WORK}/list.out" >&2
  fi
else
  bad "npx bddgen FAILED — the matrix does not generate at all"
  tail -30 "${WORK}/bddgen.out" >&2
fi

# ═════════════════════════════════════════════════════════════════════════════
# 3. THE FOUR DRIFT CLAUSES, derived from the catalogues, compared to what generates
# ═════════════════════════════════════════════════════════════════════════════
if dump_expected; then
  if compare_sets > "${WORK}/sets.out" 2>&1; then
    ok "every catalogued persona / service / function / persona-service pair has a"
    ok "  scenario that GENERATES, and nothing generates for a catalogue entry that is gone"
    sed -n 's/^COUNT /       /p' "${WORK}/sets.out"
  else
    bad "coverage drift:"
    sed -n 's/^PROBLEM /       /p' "${WORK}/sets.out" >&2
    sed -n 's/^COUNT /       /p' "${WORK}/sets.out" >&2
  fi
else
  bad "could not dump the expected coverage set from the catalogues"
  tail -20 "${WORK}/dump.out" >&2
fi

# ═════════════════════════════════════════════════════════════════════════════
# 4. THE LANE IS GREEN WITH NOTHING RUNNING
# ═════════════════════════════════════════════════════════════════════════════
# The whole matrix is stack-free by construction, so "green with nothing started"
# is the correct expectation — except the 9 env x interface cells, which SKIP
# (loudly, naming what to start) because no mesh is up. Set COVERAGE_MATRIX_FULL=0
# to run only the representative subset when iterating; the default is the whole
# lane, because a subset is how a matrix stays 40% true.
if [ "${COVERAGE_MATRIX_FULL:-1}" = "1" ]; then
  LANE=('.features-gen/features/coverage/')
  LANE_LABEL="the whole coverage lane"
else
  LANE=('.features-gen/features/coverage/access-matrix-wiki.feature.spec.js'
        '.features-gen/features/coverage/function-catalogue.feature.spec.js'
        '.features-gen/features/coverage/roster-coverage.feature.spec.js')
  LANE_LABEL="the coverage SUBSET (COVERAGE_MATRIX_FULL=0)"
fi
run_lane base "${LANE[@]}"
rc="${LANE_RC}"
SUMMARY="$(strip_ansi base | grep -E ' [0-9]+ (passed|failed|skipped)' | tr -d '\n')"
if [ "${rc}" = "0" ] && [ -z "$(lane_failed_count base)" ]; then
  ok "${LANE_LABEL} is GREEN with nothing started —${SUMMARY}"
else
  bad "${LANE_LABEL} is not green (rc=${rc}, launch failures=$(launch_failures base)) —${SUMMARY}"
  grep -E '✘|Error:|expect\(' "${WORK}/run.base.out" | head -20 >&2
fi

# ═════════════════════════════════════════════════════════════════════════════
# 5. MUTATION BATTERY — break production and prove each break is CAUGHT
# ═════════════════════════════════════════════════════════════════════════════
echo "-- mutation battery --"
CAUGHT=0; SURVIVED=0
caught()   { echo "  CAUGHT   $*"; CAUGHT=$((CAUGHT+1)); }
survived() { echo "  SURVIVED $*"; SURVIVED=$((SURVIVED+1)); }

# ── M1: a persona is added to the roster and nobody re-emits ────────────────
cat > "${WORK}/m1.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('dragoneer:ROLE_USER:E2E_PASSWORD \\',
              'dragoneer:ROLE_USER:E2E_PASSWORD \\\nm1-ghost-persona:ROLE_ADMIN,ROLE_USER:E2E_PASSWORD \\')
open(p, 'w').write(s)
PY
if mutate tests/e2e-extra-personas.sh "${WORK}/m1.py"; then
  emit_and_diff m1 || true
  r="${EMIT_R}"; ds=1
  dump_expected && compare_sets > "${WORK}/sets.m1" 2>&1 && ds=0
  if [ "${r}" != "IDENTICAL" ] && [ "${ds}" != "0" ]; then
    caught "M1 a new persona with no scenario (emit diff: ${r}; drift clause: RED)"
  else
    survived "M1 new persona (emit diff: ${r}; drift clause rc=${ds})"
  fi
else
  survived "M1 (patch did not apply)"
fi
restore_all

# ── M2: a service is added to SERVICES and nobody catalogues functions for it ─
cat > "${WORK}/m2.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
anchor = "const SERVICE_BY_ID = new Map("
new = ("""  {
    id: 'm2-ghost-service', name: 'M2 ghost service',
    uiPath: '/m2', bffPrefix: '/bff/m2', pinned: false,
    accessRole: null, note: 'mutation M2',
  },
];

""")
i = s.index(anchor)
j = s.rindex('];', 0, i)
s = s[:j] + new + s[i:]
open(p, 'w').write(s)
PY
if mutate tests/e2e/steps/dimensions.ts "${WORK}/m2.py"; then
  emit_and_diff m2 || true
  r="${EMIT_R}"; ds=1
  dump_expected && compare_sets > "${WORK}/sets.m2" 2>&1 && ds=0
  # The emitter REFUSES to emit a service with no functions, so EMIT-FAILED is a
  # catch (loudly), and so is a plain diff.
  if [ "${r}" != "IDENTICAL" ] || [ "${ds}" != "0" ]; then
    caught "M2 a new service with no functions (emit: ${r}; drift clause rc=${ds})"
  else
    survived "M2 new service (emit: ${r}; drift clause rc=${ds})"
  fi
else
  survived "M2 (patch did not apply)"
fi
restore_all

# ── M3: a function is DELETED from the catalogue but its scenarios remain ────
# The bidirectional half. The committed features still name wiki.history, so the
# reverse clause must fire AND the lane must go red at run time.
cat > "${WORK}/m3.py" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
m = re.search(r"  \{ id: 'wiki\.history'.*?\n(?=  \{ id: )", s, re.S)
if not m:
    sys.exit('anchor wiki.history not found')
open(p, 'w').write(s[:m.start()] + s[m.end():])
PY
if mutate tests/e2e/steps/coverage-catalogue.ts "${WORK}/m3.py"; then
  ds=1
  dump_expected && compare_sets > "${WORK}/sets.m3" 2>&1 && ds=0
  run_lane m3 '.features-gen/features/coverage/access-matrix-wiki.feature.spec.js'
  rc="${LANE_RC}"; lf="$(launch_failures m3)"
  if [ "${ds}" != "0" ] && [ "${rc}" != "0" ] && [ "${lf}" = "0" ]; then
    caught "M3 a deleted function whose scenarios survive (reverse clause RED, lane rc=${rc})"
  else
    survived "M3 deleted function (reverse clause rc=${ds}, lane rc=${rc}, launch failures=${lf})"
  fi
else
  survived "M3 (patch did not apply)"
fi
restore_all

# ── M4: the ORACLE always says 'admitted' ───────────────────────────────────
# The anti-tautology mutation. A step that recomputed the expectation and
# compared it with itself would SURVIVE this; only a step comparing against the
# literal pinned in the committed .feature can catch it.
cat > "${WORK}/m4.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
anchor = "export function seedDecision(gateway: GatewayName, target: string, roles: readonly string[]): Decision {"
i = s.index(anchor) + len(anchor)
s = s[:i] + "\n  return { outcome: 'admitted', pattern: '/**', grantedRoles: [], why: 'M4' };" + s[i:]
open(p, 'w').write(s)
PY
if mutate tests/e2e/steps/coverage-catalogue.ts "${WORK}/m4.py"; then
  run_lane m4 '.features-gen/features/coverage/access-matrix-wiki.feature.spec.js'
  rc="${LANE_RC}"; lf="$(launch_failures m4)"
  nfail="$(lane_failed_count m4)"
  if [ "${rc}" != "0" ] && [ "${nfail:-0}" -gt 0 ] && [ "${lf}" = "0" ]; then
    caught "M4 an oracle that admits everyone (${nfail} cells RED)"
  else
    survived "M4 always-admitted oracle (rc=${rc}, failed=${nfail:-0}, launch failures=${lf})"
  fi
else
  survived "M4 (patch did not apply)"
fi
restore_all

# ── M5: a function's probe path is silently re-pointed ──────────────────────
# The dangerous shape: the OUTCOME can stay the same while a different rule does
# the deciding. Only the `pattern` assertion catches it.
cat > "${WORK}/m5.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "gateway: FE, probePath: '/bff/wiki/pages/home', evidence: 'asserted',"
new = "gateway: FE, probePath: '/bff/wiki/admin/pages/home', evidence: 'asserted',"
if old not in s: sys.exit('anchor wiki.edit probePath not found')
open(p, 'w').write(s.replace(old, new, 1))
PY
if mutate tests/e2e/steps/coverage-catalogue.ts "${WORK}/m5.py"; then
  emit_and_diff m5 || true
  r="${EMIT_R}"
  run_lane m5 '.features-gen/features/coverage/access-matrix-wiki.feature.spec.js'
  rc="${LANE_RC}"; lf="$(launch_failures m5)"
  if [ "${r}" != "IDENTICAL" ] && [ "${rc}" != "0" ] && [ "${lf}" = "0" ]; then
    caught "M5 a re-pointed probe path (emit diff: ${r}, lane rc=${rc})"
  else
    survived "M5 re-pointed probe path (emit diff: ${r}, lane rc=${rc}, launch failures=${lf})"
  fi
else
  survived "M5 (patch did not apply)"
fi
restore_all

# ── M6: somebody hand-edits an outcome in a GENERATED feature ───────────────
cat > "${WORK}/m6.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "| admin@hugmesh.net            | wiki.administer | admitted |"
new = "| admin@hugmesh.net            | wiki.administer | refused  |"
if old not in s: sys.exit('anchor row not found')
open(p, 'w').write(s.replace(old, new, 1))
PY
if mutate tests/e2e/features/coverage/access-matrix-wiki.feature "${WORK}/m6.py"; then
  emit_and_diff m6 || true
  r="${EMIT_R}"
  run_bg "${WORK}/bddgen.m6.out" _in_e2e npx bddgen
  run_lane m6 '.features-gen/features/coverage/access-matrix-wiki.feature.spec.js'
  rc="${LANE_RC}"; lf="$(launch_failures m6)"
  if [ "${r}" != "IDENTICAL" ] && [ "${rc}" != "0" ] && [ "${lf}" = "0" ]; then
    caught "M6 a hand-edited outcome cell (emit diff: ${r}, lane rc=${rc})"
  else
    survived "M6 hand-edited outcome (emit diff: ${r}, lane rc=${rc}, launch failures=${lf})"
  fi
else
  survived "M6 (patch did not apply)"
fi
restore_all
run_bg "${WORK}/bddgen.restore.out" _in_e2e npx bddgen

echo "  mutations: ${CAUGHT} caught, ${SURVIVED} survived"
[ "${SURVIVED}" -eq 0 ] || F=$((F+1))

# ═════════════════════════════════════════════════════════════════════════════
# 6. THE TREE IS BACK — a half-restored tree is a failure, not a surprise
# ═════════════════════════════════════════════════════════════════════════════
tree_fingerprint > "${WORK}/tree-after.md5"
if diff -q "${WORK}/tree-before.md5" "${WORK}/tree-after.md5" >/dev/null 2>&1; then
  ok "every mutation was reverted (the guarded tree is byte-identical to pre-run)"
else
  bad "THE TREE WAS NOT FULLY RESTORED — diff the md5 lists:"
  diff "${WORK}/tree-before.md5" "${WORK}/tree-after.md5" >&2 || true
fi

echo "== e2e coverage matrix: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

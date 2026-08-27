#!/usr/bin/env bash
# test-e2e-env-interface-dimensions.sh — the gate for the ENVIRONMENT and
# INTERFACE axes and for the evidence they produce.
#
# SIBLING TO test-e2e-gherkin-harness.sh, not a replacement. That one proves
# every .feature generates and runs. This one proves the two axes added on top
# actually mean something:
#
#   1. every legal env / interface value resolves, and an UNKNOWN one fails
#      LOUDLY naming the legal set — never silently accepted;
#   2. an environment that is not serving makes its scenarios SKIP WITH A REASON
#      naming what to start, and can never make them PASS;
#   3. each interface writes its own kind of evidence — PNG for browser,
#      TRANSCRIPT for cli, Qt WIDGET GRAB for studio — and the transcript
#      carries the REAL exit code;
#   4. the evidence manifest is written, every row points at a file that exists,
#      and every file on disk has a row (no artefact omitted);
#   5. the manifest, a transcript and a sidecar all validate against the PINNED
#      fixture tests/e2e/evidence-manifest.schema.json — hand-written, NEVER
#      regenerated from a run, because validating output against a schema
#      derived from that same output is circular and proves nothing.
#
# MUTATION BATTERY. Checks 1-5 are re-run with production DELIBERATELY BROKEN,
# five ways, and each mutation must turn the suite RED. A guard that has never
# been seen to fail is a guard nobody has tested. Every mutation is applied to
# the REAL tree with a backup, and the tree is restored on EXIT via trap — the
# final check asserts `git diff` is clean, so a half-restored tree is itself a
# failure rather than a surprise for the next agent.
#
# OFFLINE. Starts NOTHING. Probes only. The three environments are expected to
# be down and the suite is designed to be green with all three down: the
# environment scenarios SKIP, and skipping loudly is the pass condition.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
E2E="${REPO}/tests/e2e"
FEATURE_REL=".features-gen/features/platform/"
SCHEMA="${E2E}/evidence-manifest.schema.json"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

echo "== e2e env x interface: axes resolve, evidence lands, manifest holds =="

# ── preconditions: refuse to be vacuous ──────────────────────────────────────
for t in node python3 git bash; do
  command -v "${t}" >/dev/null 2>&1 || {
    echo "SKIPPED-LOUDLY: ${t} is required and absent — this guard checked NOTHING." >&2
    exit 2
  }
done
if [ ! -d "${E2E}/node_modules/playwright-bdd" ]; then
  echo "SKIPPED-LOUDLY: ${E2E}/node_modules/playwright-bdd is missing — run" >&2
  echo "  (cd ${E2E} && npm install)   [or: make playwright-deps]" >&2
  echo "This guard checked NOTHING. Exiting 2 rather than 0." >&2
  exit 2
fi
[ -f "${SCHEMA}" ] || {
  echo "SKIPPED-LOUDLY: the PINNED manifest schema ${SCHEMA} is missing." >&2
  echo "Without the fixture there is no non-circular oracle. Exiting 2." >&2
  exit 2
}

WORK="${TMPDIR:-/var/tmp/portage}/env-iface-guard.$$"
mkdir -p "${WORK}"

# The baseline lane is analysed in `full` mode, which REQUIRES a widget-grab and
# a studio interface row. On a host with no Qt6 binding the studio scenario
# skips (correctly, with a reason) and full mode would then report a PROBLEM —
# failing the guard for an ABSENT PREREQUISITE rather than for a defect. Decide
# that up front and say so, loudly, with the exact install command. Exit 2, not
# 0: a guard that checked nothing must never be mistaken for a pass.
if ! QT_QPA_PLATFORM=offscreen python3 "${E2E}/studio-driver.py" --self-check \
     >"${WORK}/studio-selfcheck.out" 2>&1; then
  echo "SKIPPED-LOUDLY: no usable Qt6 binding, so the 'studio' interface cannot be" >&2
  echo "  exercised and this guard would fail for a missing prerequisite rather" >&2
  echo "  than for a defect. Install PySide6 or PyQt6 (pip install -r studio/requirements.txt)" >&2
  echo "  or point SNAP_STUDIO_PYTHON at an interpreter that has one." >&2
  sed -n '1,10p' "${WORK}/studio-selfcheck.out" >&2
  echo "This guard checked NOTHING. Exiting 2 rather than 0." >&2
  exit 2
fi

# Byte fingerprint of every file the mutation battery is allowed to touch, taken
# BEFORE anything is broken. The final check diffs against this.
tree_fingerprint() {
  ( cd "${REPO}" && find tests/e2e/steps -type f -name '*.ts' | sort | xargs md5sum )
}
tree_fingerprint > "${WORK}/tree-before.md5"

# ── mutation bookkeeping ─────────────────────────────────────────────────────
# Every file we are about to break is backed up here and restored on EXIT, even
# on an interrupt. Restoring is not best-effort: the last check verifies it.
BACKUP="${WORK}/backup"
mkdir -p "${BACKUP}"
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

# mutate <relpath> <python-expression-file> — applies a python patch and PROVES
# the file actually changed. A mutation that silently failed to apply would make
# the guard look like it caught something it never saw.
mutate() {
  local rel="$1" before after
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

# run_lane <label> -> writes $WORK/<label>.json ; echoes the playwright exit code
run_lane() {
  local label="$1"
  ( cd "${E2E}" && \
    PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/var/tmp/portage/pw-browsers}" \
    SNAP_REPORT_DIR="${WORK}/${label}" \
    SNAP_RUN_ID="${label}" \
    PLAYWRIGHT_JSON_OUTPUT_NAME="${WORK}/${label}.json" \
    npx playwright test --project=bdd --reporter=json "${FEATURE_REL}" \
      >"${WORK}/${label}.out" 2>&1 )
  echo "$?"
}

regen() {
  ( cd "${E2E}" && npx bddgen >"${WORK}/bddgen.out" 2>&1 )
}

# ── 0. generation still works and the count is intact ────────────────────────
if regen; then
  ok "npx bddgen exits 0 with the env/interface axes present"
else
  bad "npx bddgen FAILED — see ${WORK}/bddgen.out"
  sed -n '1,20p' "${WORK}/bddgen.out" >&2
fi

# ── 1. the baseline lane: 4 pass, 3 skip, every skip with a reason ───────────
BASE_RC="$(run_lane baseline)"
if [ "${BASE_RC}" -eq 0 ]; then
  ok "the env/interface feature lane is green (rc=0) with NOTHING started"
else
  bad "baseline lane rc=${BASE_RC} (expected 0) — see ${WORK}/baseline.out"
  grep -viE 'npm notice' "${WORK}/baseline.out" | tail -25 >&2
fi

# The analyser is used by the baseline AND by every mutation, so it is written
# once here. It reads ONLY the playwright JSON report and the on-disk evidence.
cat > "${WORK}/analyse.py" <<'PY'
import json, os, sys

report, run_dir, schema_path, mode = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
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
skips_without_reason = []
env_scenarios = {}
for root in rep.get('suites', []):
    for sp in specs(root):
        for t in sp.get('tests', []):
            st = t['results'][0]['status']
            title = sp['title']
            if st == 'skipped':
                skipped += 1
                reason = ''
                for a in (t.get('annotations') or []):
                    if a.get('type') == 'skip':
                        reason = a.get('description') or ''
                if not reason.strip():
                    skips_without_reason.append(title)
            elif st in ('passed', 'expected'):
                passed += 1
            else:
                failed += 1
            for tag in ('docker', 'kind', 'qemu'):
                if ('@env:' + tag) in title:
                    env_scenarios.setdefault(tag, []).append(st)

notes.append("passed=%d skipped=%d failed=%d" % (passed, skipped, failed))
# The per-environment verdict, as a stable single line. M2 compares this against
# the baseline's: with the availability gate disabled the @env scenarios stop
# skipping, and THAT difference — not a vague "something went red" — is what
# proves the mutation was noticed.
notes.append("envstatus=%s" % ",".join(
    "%s:%s" % (tag, "/".join(sorted(set(sts))))
    for tag, sts in sorted(env_scenarios.items())) or "<none>")

# Every environment scenario must SKIP while its environment is DOWN. Passing is
# the failure mode this whole design exists to prevent — but "down" is a fact
# about the host, not an assumption this analyser may make. SERVING_ENVS carries
# the MEASURED set (the suite asks production's environmentAvailability()); an
# environment that is genuinely up is SUPPOSED to make its scenarios pass, and
# flagging that is a false finding. See block 0b of the calling suite.
serving = set((os.environ.get("SERVING_ENVS") or "").split())
notes.append("serving=%s" % (",".join(sorted(serving)) or "<none>"))
for tag, statuses in sorted(env_scenarios.items()):
    if tag in serving:
        continue
    for st in statuses:
        if st in ('passed', 'expected'):
            problems.append("@env:%s scenario PASSED while the environment is down "
                            "— it must skip with a reason" % tag)
if skips_without_reason:
    problems.append("skipped with NO reason: %s" % ", ".join(skips_without_reason))

# ── evidence on disk ────────────────────────────────────────────────────────
manifest_path = os.path.join(run_dir, 'manifest.json')
schema = json.load(open(schema_path))

def typecheck(value, spec):
    alts = spec.split('|')
    for a in alts:
        if a == 'null' and value is None: return True
        if a == 'string' and isinstance(value, str): return True
        if a == 'number' and isinstance(value, (int, float)) and not isinstance(value, bool): return True
        if a == 'boolean' and isinstance(value, bool): return True
        if a == 'object' and isinstance(value, dict): return True
        if a == 'array' and isinstance(value, list): return True
    return False

if not os.path.exists(manifest_path):
    problems.append("NO MANIFEST at %s" % manifest_path)
    man = None
else:
    man = json.load(open(manifest_path))
    for key, spec in schema['top_level']['required'].items():
        if key not in man:
            problems.append("manifest missing top-level key '%s'" % key)
        elif not typecheck(man[key], spec):
            problems.append("manifest['%s'] is %r, expected %s" % (key, type(man[key]).__name__, spec))
    if man.get('schema') != schema['schema']:
        problems.append("manifest schema is %r, pinned fixture says %r"
                        % (man.get('schema'), schema['schema']))
    for key, spec in schema['counts']['required'].items():
        if key not in man.get('counts', {}):
            problems.append("manifest.counts missing '%s'" % key)

if man is not None:
    rows = man.get('artefacts', [])
    notes.append("manifest rows=%d" % len(rows))
    if not rows:
        problems.append("manifest lists ZERO artefacts")
    req = schema['record']['required']
    enums = schema['record']['enums']
    seen_ifaces, seen_kinds = set(), set()
    listed = set()
    for r in rows:
        for key, spec in req.items():
            if key not in r:
                problems.append("manifest row missing field '%s' (step %r)" % (key, r.get('step')))
            elif not typecheck(r[key], spec):
                problems.append("manifest row field '%s' is %r, expected %s"
                                % (key, r.get(key), spec))
        for key, allowed in enums.items():
            if key in r and r[key] not in allowed:
                problems.append("manifest row '%s'=%r not in %s" % (key, r[key], allowed))
        seen_ifaces.add(r.get('interface'))
        seen_kinds.add(r.get('kind'))
        p = r.get('path') or ''
        if p:
            listed.add(os.path.normpath(os.path.join(run_dir, p)))
            if not os.path.exists(os.path.join(run_dir, p)):
                problems.append("manifest row points at a MISSING file: %s" % p)

    # ── no artefact omitted ────────────────────────────────────────────────
    # Every evidence file on disk must have a row. This is the direction a
    # manifest silently shrinks in: the writer drops one and the index still
    # validates perfectly against itself.
    on_disk = set()
    for dirpath, _dirs, files in os.walk(run_dir):
        if os.path.basename(dirpath) == '.driver-tmp':
            continue
        for fn in files:
            if fn in ('manifest.json', 'manifest.jsonl'):
                continue
            full = os.path.normpath(os.path.join(dirpath, fn))
            # sidecars are referenced by `sidecar`, not `path`; they are indexed
            # through their artefact's row, so they are not required to appear
            # as a `path`. Everything else must.
            if fn.endswith('.json') and not fn.endswith('.cli.json') \
                                    and not fn.endswith('.studio.json'):
                continue
            on_disk.add(full)
    orphans = sorted(on_disk - listed)
    if orphans:
        problems.append("%d artefact(s) on disk with NO manifest row: %s"
                        % (len(orphans), ", ".join(os.path.basename(o) for o in orphans[:5])))

    if mode == 'full':
        for want in ('browser', 'cli', 'studio'):
            if want not in seen_ifaces:
                problems.append("no evidence recorded for the '%s' interface" % want)
        for want in ('screenshot', 'transcript', 'widget-grab'):
            if want not in seen_kinds:
                problems.append("no '%s' artefact in the manifest" % want)
    notes.append("interfaces=%s" % ",".join(sorted(x for x in seen_ifaces if x)))
    notes.append("kinds=%s" % ",".join(sorted(x for x in seen_kinds if x)))

# ── the transcript and sidecar contracts ────────────────────────────────────
tre = schema['transcript']['required']
sre = schema['sidecar']['required']
tcount = scount = 0
real_exit_seen = False
for dirpath, _d, files in os.walk(run_dir):
    for fn in files:
        full = os.path.join(dirpath, fn)
        if fn.endswith('.cli.json'):
            tcount += 1
            t = json.load(open(full))
            for key, spec in tre.items():
                if key not in t:
                    problems.append("transcript %s missing '%s'" % (fn, key))
                elif not typecheck(t[key], spec):
                    problems.append("transcript %s field '%s' is %r, expected %s"
                                    % (fn, key, t.get(key), spec))
            if t.get('exitCode') not in (0, None):
                real_exit_seen = True
        elif fn.endswith('.json') and not fn.endswith('.studio.json') \
                                  and fn not in ('manifest.json',):
            s = json.load(open(full))
            if 'step' in s and 'ordinal' in s:
                scount += 1
                for key, spec in sre.items():
                    if key not in s:
                        problems.append("sidecar %s missing '%s'" % (fn, key))
                    elif not typecheck(s[key], spec):
                        problems.append("sidecar %s field '%s' is %r, expected %s"
                                        % (fn, key, s.get(key), spec))
notes.append("transcripts=%d sidecars=%d" % (tcount, scount))

if mode == 'full':
    if tcount == 0:
        problems.append("no cli transcript was written at all")
    if not real_exit_seen:
        problems.append("no transcript carried a NON-ZERO exit code — the lane is "
                        "supposed to run a command that exits 7, so an all-zero "
                        "set means exit codes are being laundered")

for n in notes:
    print("NOTE %s" % n)
for p in problems:
    print("PROBLEM %s" % p)
sys.exit(1 if problems else 0)
PY

analyse() {  # analyse <label> <mode>  -> rc 0 clean, 1 problems
  # SERVING_ENVS is the MEASURED set (see block 0b). The analyser grades
  # "must skip" only for environments it has been told are down; without it the
  # analyser was asserting an assumption.
  SERVING_ENVS="${SERVING_ENVS:-}" \
  python3 "${WORK}/analyse.py" \
    "${WORK}/$1.json" "${WORK}/$1/bdd-steps/$1" "${SCHEMA}" "$2" \
    >"${WORK}/$1.analysis" 2>&1
}

# ── 0b. WHICH ENVIRONMENTS ARE ACTUALLY SERVING ──────────────────────────────
# THIS BLOCK EXISTS BECAUSE THE SUITE USED TO ASSUME THE ANSWER. Its header says
# "the three environments are expected to be down and the suite is designed to be
# green with all three down" — and nothing enforced or measured that. MEASURED
# 2026-08-27, with the compose stack up (`make stack-up ENV=test`, 41 containers,
# https://localhost:8488/ -> 200), this suite reported:
#
#   FAIL baseline evidence/manifest problems:
#        @env:docker scenario PASSED while the environment is down — it must skip
#   SURVIVED M7 docker accepts the kind node's ingress as the compose stack
#
# BOTH were false. The @env:docker scenario passed because the mesh was genuinely
# up — the correct outcome — and M7 "survived" only because its catch condition
# compares the mutated per-environment status against the baseline's, and with
# docker already `passed` at baseline the mutation cannot change it. So the guard
# went RED exactly when the lane it grades was WORKING, and accused a fix that had
# just landed (PR #203) of not working. A false finding is worse than no finding:
# it sends the next reader to debug correct code.
#
# The availability is taken from PRODUCTION — `environmentAvailability()` in
# steps/dimensions.ts, the same function the harness itself gates scenarios on —
# so this is a measurement, never a second implementation that can disagree.
PROBE="${WORK}/probe"
mkdir -p "${PROBE}"
ln -sfn "${E2E}/node_modules" "${PROBE}/node_modules"
cat > "${PROBE}/pw.config.ts" <<'TS'
import { defineConfig } from '@playwright/test';
export default defineConfig({
  testDir: __dirname, reporter: [['list']], workers: 1, retries: 0, timeout: 60_000,
});
TS
# QUOTED heredoc + a sed'd placeholder, the vocab lane's rule: an unquoted one
# would let bash expand the ${...} in the spec.
cat > "${PROBE}/serving.spec.ts" <<'TS'
import { test } from '@playwright/test';
import * as fs from 'node:fs';
import * as d from '__DIMENSIONS__';

test('measure which environments are serving right now', async () => {
  const out: Record<string, unknown> = {};
  for (const id of d.ENVIRONMENTS) {
    const a = await d.environmentAvailability(id, true);
    out[id] = { available: !!a.available, reason: a.reason, detail: a.detail };
  }
  const dest = process.env.SNAP_SERVING_OUT;
  if (dest) fs.writeFileSync(dest, JSON.stringify(out, null, 2));
});
TS
sed -i "s#__DIMENSIONS__#${E2E}/steps/dimensions#" "${PROBE}/serving.spec.ts"

SERVING_JSON="${WORK}/serving.json"
( cd "${E2E}" && \
  SNAP_SERVING_OUT="${SERVING_JSON}" \
  PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/var/tmp/portage/pw-browsers}" \
  npx playwright test -c "${PROBE}/pw.config.ts" >"${WORK}/serving.out" 2>&1 )
if [ -s "${SERVING_JSON}" ]; then
  SERVING_ENVS="$(python3 - "${SERVING_JSON}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(" ".join(sorted(k for k, v in d.items() if v.get("available"))))
PY
)"
  ok "measured which environments are serving: ${SERVING_ENVS:-<none — all three are down>}"
else
  # A measurement that did not happen must not be reported as "all down" — that
  # is the assumption this block replaces. Refuse instead.
  bad "could not measure environment availability (see ${WORK}/serving.out) — this "\
"guard cannot tell a correct PASS from a silent one without it"
  SERVING_ENVS="<unmeasured>"
fi
export SERVING_ENVS

if analyse baseline full; then
  ok "baseline evidence is complete and matches the PINNED schema"
  sed -n 's/^NOTE /       /p' "${WORK}/baseline.analysis"
else
  bad "baseline evidence/manifest problems:"
  sed -n 's/^PROBLEM /       /p' "${WORK}/baseline.analysis" >&2
  sed -n 's/^ANALYSE-ERROR /       /p' "${WORK}/baseline.analysis" >&2
fi

# ── 2. every legal value resolves; unknown values throw naming the legal set ──
# Run through PLAYWRIGHT's TypeScript transform, not a bare `node require()`.
# steps/dimensions.ts imports '../specs/rbac-roles' extensionless, which node's
# own type-stripping cannot resolve — a bare require() therefore dies with
# MODULE_NOT_FOUND and exits non-zero NO MATTER WHAT THE VOCABULARY DOES. That
# is how the first version of this guard reported M1 as CAUGHT while never
# loading the module at all: a false CAUGHT is worse than a survivor, because it
# claims coverage that does not exist.
#
# The config and spec live in $WORK with a SYMLINKED node_modules (module
# resolution walks up from the config's own directory, so a config outside
# tests/e2e cannot otherwise find @playwright/test). Nothing is written into the
# repo tree.
VOCAB="${WORK}/vocab"
mkdir -p "${VOCAB}"
ln -sfn "${E2E}/node_modules" "${VOCAB}/node_modules"

cat > "${VOCAB}/pw.config.ts" <<'TS'
import { defineConfig } from '@playwright/test';
export default defineConfig({
  testDir: __dirname, reporter: [['list']], workers: 1, retries: 0, timeout: 30_000,
});
TS

# QUOTED heredoc + a sed'd placeholder. An unquoted heredoc would let bash
# execute the backticks and ${...} in the spec below — a trap this repo has
# already been bitten by.
cat > "${VOCAB}/vocab.spec.ts" <<'TS'
import { test, expect } from '@playwright/test';
import * as d from '__DIMENSIONS__';

test('every legal environment resolves to itself and yields a real base URL', () => {
  expect(d.ENVIRONMENTS.length, 'ENVIRONMENTS is empty').toBeGreaterThan(0);
  for (const e of d.ENVIRONMENTS) {
    const def = d.environment(e);
    expect(def?.id, `environment('${e}') did not resolve to itself`).toBe(e);
    expect(d.environmentBaseUrl(e), `environment('${e}') base URL`).toMatch(/^https?:\/\//);
    expect(def.startHint.trim(), `environment('${e}') has no startHint to quote in a skip`)
      .not.toBe('');
    const t = def.probeTarget();
    expect(t.url, `environment('${e}') probe target`).toMatch(/^https?:\/\//);
  }
});

test('every legal interface resolves to itself and declares its evidence kind', () => {
  for (const i of d.INTERFACES) {
    const def = d.interfaceDef(i);
    expect(def?.id, `interfaceDef('${i}') did not resolve to itself`).toBe(i);
    expect(['screenshot', 'transcript', 'widget-grab'],
      `interfaceDef('${i}').primaryEvidence`).toContain(def.primaryEvidence);
  }
});

// The property M1 attacks. An unknown value must THROW, and the message must
// name every legal value — a bare "invalid environment" sends the reader to the
// source instead of fixing the tag in two seconds.
function mustThrowNaming(fn: () => unknown, label: string, legal: readonly string[]) {
  let threw = false; let msg = '';
  try { fn(); } catch (e) { threw = true; msg = (e as Error).message; }
  expect(threw, `${label} did NOT throw — an unknown value was accepted silently`).toBe(true);
  for (const v of legal) {
    expect(msg, `${label} threw but the message never names '${v}'`).toContain(v);
  }
}

test('an unknown environment throws naming every legal environment', () => {
  mustThrowNaming(() => d.environment('kubernetes'), "environment('kubernetes')", d.ENVIRONMENTS);
  mustThrowNaming(() => d.environmentBaseUrl('compose'), "environmentBaseUrl('compose')", d.ENVIRONMENTS);
});

test('an unknown interface throws naming every legal interface', () => {
  mustThrowNaming(() => d.interfaceDef('curl'), "interfaceDef('curl')", d.INTERFACES);
});

// …and through the SAME path a .feature tag actually takes, so a tag typo dies
// in the fixture rather than driving the wrong mesh.
test('an unknown @env: / @interface: tag throws at resolve time', () => {
  mustThrowNaming(() => d.resolveDimensions(['@env:kubernetes'], 'x'),
    '@env:kubernetes tag', d.ENVIRONMENTS);
  mustThrowNaming(() => d.resolveDimensions(['@interface:curl'], 'x'),
    '@interface:curl tag', d.INTERFACES);
});

// BACKWARD COMPATIBILITY, asserted rather than hoped for. The 453 pre-existing
// scenarios declare no axes; if `env` stopped being undefined for them they
// would become availability-gated and 130 honest failures would turn into 130
// green-looking skips.
test('an untagged scenario keeps todays behaviour: env undefined, docker + browser', () => {
  const empty = d.resolveDimensions([], 'plain scenario');
  expect(empty.env, 'an untagged scenario must NOT declare an env').toBeUndefined();
  expect(empty.interface, 'an untagged scenario must NOT declare an interface').toBeUndefined();
  expect(d.envOf(empty), 'default environment').toBe('docker');
  expect(d.interfaceOf(empty), 'default interface').toBe('browser');
});

// THE SHARED-PORT VETO. docker, kind and qemu all default to host port 8443
// (the compose stack publishes it, kind-local.yaml maps 443->8443 onto it, and
// run-qemu-e2e.sh's UI_PORT defaults to it). An HTTP probe alone therefore
// cannot tell "the emulated device is serving" from "something else is". This
// test stands a stranger on a port, points @env:qemu at it, and requires the
// probe to STILL report unavailable because no emulator process exists.
// Measured on this host: :8443 is currently held by the kind node container.
test('@env:qemu is unavailable when nothing is emulating, even if the port answers', async () => {
  const { execFileSync } = await import('node:child_process');
  let emulatorRunning = true;
  try {
    execFileSync('pgrep', ['^qemu-system-'], { stdio: 'ignore' });
  } catch (e) {
    if ((e as { status?: number }).status === 1) emulatorRunning = false;
  }
  test.skip(emulatorRunning,
    'a qemu-system-* process IS running on this host, so the negative this test '
    + 'asserts cannot be established. Stop the emulator to run this check.');

  const http = await import('node:http');
  const srv = http.createServer((_req, res) => { res.writeHead(200); res.end('not a device'); });
  await new Promise<void>((r) => srv.listen(0, '127.0.0.1', () => r()));
  const port = (srv.address() as { port: number }).port;
  try {
    process.env.SNAP_ENV_QEMU_BASE_URL = `http://127.0.0.1:${port}`;
    // force=true: the probe cache must not answer for a world we just changed.
    const a = await d.environmentAvailability('qemu', true);
    expect(a.available,
      `a plain HTTP server on :${port} was accepted as an emulated device — the `
      + 'qemu scenario would have driven a stranger while claiming to test a device')
      .toBe(false);
    expect(a.reason, 'the skip reason must name what to start').toContain('run-qemu-e2e.sh');
  } finally {
    delete process.env.SNAP_ENV_QEMU_BASE_URL;
    d.resetEnvironmentProbeCache();
    await new Promise<void>((r) => srv.close(() => r()));
  }
});

test('a declared axis is parsed from both the tag list and the scenario title', () => {
  expect(d.resolveDimensions(['@env:kind'], 'x').env).toBe('kind');
  expect(d.resolveDimensions([], 'a scenario @interface:studio').interface).toBe('studio');
  // The title is the more specific, per-example value and must win.
  expect(d.resolveDimensions(['@env:docker'], 'outline @env:qemu').env).toBe('qemu');
});
TS
sed -i "s#__DIMENSIONS__#${E2E}/steps/dimensions#" "${VOCAB}/vocab.spec.ts"

vocab_lane() {
  ( cd "${E2E}" && \
    PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/var/tmp/portage/pw-browsers}" \
    npx playwright test -c "${VOCAB}/pw.config.ts" >"${WORK}/$1.out" 2>&1 )
}

if vocab_lane vocab; then
  ok "every legal env/interface resolves; unknown values throw naming the legal set"
else
  bad "env/interface vocabulary problems:"
  grep -viE 'npm notice' "${WORK}/vocab.out" | tail -30 >&2
fi

# ── 3. MUTATION BATTERY ──────────────────────────────────────────────────────
# Each mutation breaks production on purpose and MUST turn the guard red.
echo
echo "-- mutation battery: break production, prove the guard notices --"

CAUGHT=0; SURVIVED=0; NOT_RUNNABLE=0
mut_result() {  # mut_result <name> <caught:0|1> <detail>
  if [ "$2" -eq 1 ]; then
    echo "  CAUGHT   $1"; CAUGHT=$((CAUGHT+1))
  else
    echo "  SURVIVED $1  <-- $3"; SURVIVED=$((SURVIVED+1)); F=$((F+1))
  fi
}
# A THIRD verdict, and the reason this file needed one. Some mutations are only
# OBSERVABLE in a particular host state — M2 and M7 both compare a mutated
# per-environment status line against the baseline's, which can only differ for
# an environment that was DOWN at baseline. Run with that environment UP and the
# comparison is blind, and the old two-valued reporting called that SURVIVED:
# a fix that works, reported as a defect. Neither CAUGHT nor SURVIVED is true
# there. Say so, and make the suite exit 2 (this file's established
# "SKIPPED-LOUDLY, checked less than it claims" status) rather than 0 or a
# misleading 1.
mut_not_runnable() {  # mut_not_runnable <name> <why>
  echo "  NOT-RUNNABLE $1"
  echo "               $2"
  NOT_RUNNABLE=$((NOT_RUNNABLE+1))
}
env_is_serving() {  # env_is_serving <tag>
  case " ${SERVING_ENVS:-} " in (*" $1 "*) return 0 ;; esac
  return 1
}

# M1 — unknown env accepted silently.
if mutate tests/e2e/steps/dimensions.ts <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "  if (!isEnvironment(id)) {"
new = "  if (false && !isEnvironment(id)) {"
assert s.count(old) == 1, "anchor for M1 not unique: %d" % s.count(old)
open(p, 'w').write(s.replace(old, new))
PY
then
  if vocab_lane m1; then
    mut_result "M1 unknown env accepted silently" 0 "vocabulary check still passed"
  else
    mut_result "M1 unknown env accepted silently" 1 ""
  fi
else
  bad "M1 could not be applied"; fi
restore_all

# M2 — an unavailable environment PASSES instead of skipping.
# THE CATCH CONDITION IS SPECIFIC, not "something went red". With the
# availability gate disabled the three @env scenarios stop skipping; the guard
# asserts exactly that, by comparing the per-environment status line against the
# baseline's. A previous version of this block asked an undefined function and
# then reported CAUGHT down BOTH branches of its if — a mutation that can only
# be reported as caught tests nothing.
BASE_ENVSTATUS="$(sed -n 's/^NOTE envstatus=//p' "${WORK}/baseline.analysis" | head -1)"
if [ -z "${BASE_ENVSTATUS}" ]; then
  bad "M2 cannot run: the baseline analysis emitted no envstatus line"
elif env_is_serving docker && env_is_serving kind && env_is_serving qemu; then
  mut_not_runnable "M2 unavailable env passes instead of skipping" \
    "all three environments are serving (${SERVING_ENVS}), so no scenario skips at baseline and disabling the availability gate cannot change the status line"
elif mutate tests/e2e/steps/world.ts <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "    if (!availability.available) {"
new = "    if (false && !availability.available) {"
assert s.count(old) == 1, "anchor for M2 not unique: %d" % s.count(old)
open(p, 'w').write(s.replace(old, new))
PY
then
  regen >/dev/null 2>&1
  run_lane m2 >/dev/null
  analyse m2 lite || true
  M2_ENVSTATUS="$(sed -n 's/^NOTE envstatus=//p' "${WORK}/m2.analysis" | head -1)"
  if [ "${M2_ENVSTATUS}" = "${BASE_ENVSTATUS}" ]; then
    mut_result "M2 unavailable env passes instead of skipping" 0 \
      "the @env scenarios still reported '${M2_ENVSTATUS}' with the availability gate disabled"
  else
    mut_result "M2 unavailable env passes instead of skipping" 1 ""
    echo "             baseline envstatus: ${BASE_ENVSTATUS}"
    echo "             mutated  envstatus: ${M2_ENVSTATUS}"
  fi
else
  bad "M2 could not be applied"; fi
restore_all

# M3 — the sidecar drops env/interface.
if mutate tests/e2e/steps/world.ts <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = """    env: envOf(dimensions),
    interface: interfaceOf(dimensions),"""
new = """    // MUTATION: env/interface dropped from the sidecar
"""
assert s.count(old) == 1, "anchor for M3 not unique: %d" % s.count(old)
open(p, 'w').write(s.replace(old, new))
PY
then
  regen >/dev/null 2>&1
  run_lane m3 >/dev/null
  if analyse m3 lite; then
    mut_result "M3 sidecar drops env/interface" 0 "schema check accepted a sidecar with no env/interface"
  else
    mut_result "M3 sidecar drops env/interface" 1 ""
  fi
else
  bad "M3 could not be applied"; fi
restore_all

# M4 — the manifest omits an artefact that exists on disk.
if mutate tests/e2e/steps/evidence.ts <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "      rows.push(record(meta, 'screenshot', pngAbs, sidecar));"
new = "      /* MUTATION: screenshot written to disk but never indexed */"
assert s.count(old) == 1, "anchor for M4 not unique: %d" % s.count(old)
open(p, 'w').write(s.replace(old, new))
PY
then
  regen >/dev/null 2>&1
  run_lane m4 >/dev/null
  if analyse m4 lite; then
    mut_result "M4 manifest omits an artefact that exists on disk" 0 "orphan artefacts not noticed"
  else
    mut_result "M4 manifest omits an artefact that exists on disk" 1 ""
  fi
else
  bad "M4 could not be applied"; fi
restore_all

# M5 — cli evidence records exit code 0 regardless of the real one.
if mutate tests/e2e/steps/runners.ts <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "    exitCode: r.status,"
# The honest mutation an author would actually write by accident.
new = "    exitCode: 0,"
assert s.count(old) == 1, "anchor for M5 not unique: %d" % s.count(old)
open(p, 'w').write(s.replace(old, new))
PY
then
  regen >/dev/null 2>&1
  M5_RC="$(run_lane m5)"
  analyse m5 full || true
  if [ "${M5_RC}" -ne 0 ] || grep -q "PROBLEM" "${WORK}/m5.analysis"; then
    mut_result "M5 cli transcript reports exit 0 regardless of the real code" 1 ""
  else
    mut_result "M5 cli transcript reports exit 0 regardless of the real code" 0 \
      "the lane stayed green with every exit code laundered to 0"
  fi
else
  bad "M5 could not be applied"; fi
restore_all

# M6 — the qemu probe trusts whatever answers on the shared port.
# Without the process veto, ANY server on 8443 (today: the kind node container)
# is accepted as an emulated device, and a @env:qemu scenario silently drives it.
if mutate tests/e2e/steps/dimensions.ts <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "  if (def.id === 'qemu' && qemuRunning() === false) {"
new = "  if (false && def.id === 'qemu' && qemuRunning() === false) {"
assert s.count(old) == 1, "anchor for M6 not unique: %d" % s.count(old)
open(p, 'w').write(s.replace(old, new))
PY
then
  if vocab_lane m6; then
    mut_result "M6 qemu accepts any server on the shared port as a device" 0 \
      "a plain HTTP server was accepted as an emulated device"
  else
    mut_result "M6 qemu accepts any server on the shared port as a device" 1 ""
  fi
else
  bad "M6 could not be applied"; fi
restore_all

# M7 — an UNPROTECTED port collision on the docker probe. Sibling of M6.
#
# Two edits, one defect. The defect is "docker trusts whatever answers on a port it
# does not own". Observing it needs the collision to EXIST, and after the port fix
# docker asks :8488 where nothing on this host replies — so the first edit is SETUP
# that points docker back at the shared :8443 (which the kind node publishes here),
# and the second is the defect itself, removing the owner check.
#
# Doing only the setup would leave the guard correctly GREEN (docker skips, because
# the owner check catches it) and report SURVIVED against a working fix — which is
# what a first draft of this block did.
#
# Both halves were live at once before today: the fallback said 8443 AND the owner
# check existed only on the probe's failure branch. Measured then: "4 passed, 1
# failed — @env:docker scenario PASSED while the environment is down".
if [ -z "${BASE_ENVSTATUS}" ]; then
  bad "M7 cannot run: the baseline analysis emitted no envstatus line"
elif env_is_serving docker; then
  # The mutation makes docker report AVAILABLE off a foreign owner. If docker is
  # ALREADY available the status line reads `docker:passed` before and after, and
  # a comparison that cannot move is not a test. MEASURED 2026-08-27: this exact
  # state reported "SURVIVED" against the freshly-landed fix.
  mut_not_runnable "M7 docker accepts the kind node's ingress as the compose stack" \
    "the docker environment is SERVING, so its baseline status is already 'passed' and the mutation cannot change it — stop the compose stack (make stack-halt) to exercise this one"
elif mutate tests/e2e/steps/dimensions.ts <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()

# SETUP: put docker back on the shared port so a collision can happen at all.
setup_old = "        || `https://localhost:${process.env.PUBLIC_HTTPS_PORT || '8488'}`,"
setup_new = "        || 'https://localhost:8443',"
assert s.count(setup_old) == 1, "M7 setup anchor not unique: %d" % s.count(setup_old)
s = s.replace(setup_old, setup_new)

# THE DEFECT: both probe branches carry the identical condition, so anchor on the
# SUCCESS branch's preceding comment. A non-unique anchor must refuse rather than
# mutate whichever site it reaches first.
old = ("    // its pgrep gate above; docker had nothing equivalent.\n"
       "    if (owner && def.id !== 'kind' && /control-plane/.test(owner)) {")
new = ("    // its pgrep gate above; docker had nothing equivalent.\n"
       "    if (false && owner && def.id !== 'kind' && /control-plane/.test(owner)) {")
assert s.count(old) == 1, "anchor for M7 not unique: %d" % s.count(old)
open(p, 'w').write(s.replace(old, new))
PY
then
  regen >/dev/null 2>&1
  run_lane m7 >/dev/null
  analyse m7 lite || true
  M7_ENVSTATUS="$(sed -n 's/^NOTE envstatus=//p' "${WORK}/m7.analysis" | head -1)"
  if [ "${M7_ENVSTATUS}" = "${BASE_ENVSTATUS}" ]; then
    mut_result "M7 docker accepts the kind node's ingress as the compose stack" 0 \
      "the @env scenarios still reported '${M7_ENVSTATUS}' with docker back on :8443 and the owner check disabled"
  else
    mut_result "M7 docker accepts the kind node's ingress as the compose stack" 1 ""
    echo "             baseline envstatus: ${BASE_ENVSTATUS}"
    echo "             mutated  envstatus: ${M7_ENVSTATUS}"
  fi
else
  bad "M7 could not be applied"; fi
restore_all

if [ "${NOT_RUNNABLE}" -gt 0 ]; then
  echo "  mutations: ${CAUGHT} caught, ${SURVIVED} survived, ${NOT_RUNNABLE} NOT RUNNABLE in this host state"
else
  echo "  mutations: ${CAUGHT} caught, ${SURVIVED} survived"
fi

# ── 4. the tree is back exactly as it was ────────────────────────────────────
regen >/dev/null 2>&1
# Byte-identical to how THIS RUN found the tree — NOT `git diff`, which compares
# against the index and would be red for any uncommitted work in steps/ and
# green only by accident. A half-restored tree must be this guard's own failure,
# never a surprise for whoever runs next.
if diff -u "${WORK}/tree-before.md5" <(tree_fingerprint) >"${WORK}/tree-diff" 2>&1; then
  ok "every mutation was reverted (tests/e2e/steps/ is byte-identical to pre-run)"
else
  bad "THE TREE IS STILL MUTATED — tests/e2e/steps/ differs from how this run found it:"
  cat "${WORK}/tree-diff" >&2
fi

echo
if [ "${F}" -eq 0 ] && [ "${NOT_RUNNABLE}" -gt 0 ]; then
  echo "== e2e env x interface: ${P} passed, 0 failed, ${NOT_RUNNABLE} mutation(s) NOT RUNNABLE =="
  echo "   SKIPPED-LOUDLY: this run could not exercise the availability half of the"
  echo "   battery, because the environment(s) it needs DOWN are serving:"
  echo "     serving now: ${SERVING_ENVS:-<none>}"
  echo "   Exiting 2 rather than 0 — a green here would claim coverage this run did"
  echo "   not have. Nothing is wrong with the tree; re-run with the mesh stopped."
  exit 2
fi
echo "== e2e env x interface: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

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
# OFFLINE. Starts NO MESH. It MEASURES which of the three environments are
# serving (block 0b) rather than assuming; with all three down the environment
# scenarios SKIP, and skipping loudly is the pass condition. The one thing it
# does start is M7's stand-in: a throwaway container on a loopback port that
# plays the foreign owner the docker probe must veto — built by the guard so the
# mutation is observable in EVERY host state, and removed on exit (see M7).
#
# HOST STATE IS NOT AN INPUT. Every verdict here is either measured or reported
# as NOT-RUNNABLE with the command that would make it runnable. The two times
# this file assumed the host (PR #208: "the mesh is down"; today: "the kind node
# holds :8443 and the browsers live under /var/tmp/portage/pw-browsers") it went
# RED against correct code, and a false finding sends the next reader to debug
# a fix that works.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
E2E="${REPO}/tests/e2e"
# THE ONE FEATURE THIS GUARD GRADES. Not the platform/ directory: another feature
# (social-function-matrix, the drift guard) landed beside it after this file was
# written, and grading a whole directory made this guard's verdict depend on a
# suite it does not own — its 40 scenarios were in every lane and every failure
# of theirs would have been reported here as an env/interface defect. The file
# name is what `npx bddgen` emits for platform/env-interface-evidence.feature.
FEATURE_REL=".features-gen/features/platform/env-interface-evidence.feature.spec.js"
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
# ONE readiness opinion, not a second one: tests/e2e/check-toolchain.sh verifies
# node_modules against the COMMITTED lock and the browser revision under THE
# BROWSERS PATH THIS GUARD RUNS WITH. `[ -d node_modules/playwright-bdd ]` used to
# stand here and said nothing about either — MEASURED 2026-08-27: with
# /var/tmp/portage/pw-browsers holding dangling r1228 -> r1234 aliases, this guard
# got past its preflight and reported its lane as "not green" with every browser
# scenario dying on "Executable doesn't exist at .../chromium_headless_shell-1228",
# the toolchain gap wearing the costume of a product failure. The probe names the
# path and the fix (PLAYWRIGHT_BROWSERS_PATH=... make playwright-deps) instead.
# The probe sees the AMBIENT browsers path — PLAYWRIGHT_BROWSERS_PATH only if
# the caller set it, Playwright's default cache otherwise — because that is
# exactly how the lane below resolves browsers since the forced
# /var/tmp/portage/pw-browsers override was dropped (see THE BROWSER MUST
# LAUNCH below); probing a path the lane no longer uses would be a second,
# wrong opinion.
if ! bash "${E2E}/check-toolchain.sh"; then
  echo "SKIPPED-LOUDLY: the e2e toolchain is not ready (above). This guard checked NOTHING. Exiting 2 rather than 0." >&2
  exit 2
fi
[ -f "${SCHEMA}" ] || {
  echo "SKIPPED-LOUDLY: the PINNED manifest schema ${SCHEMA} is missing." >&2
  echo "Without the fixture there is no non-circular oracle. Exiting 2." >&2
  exit 2
}

WORK="${TMPDIR:-/var/tmp/portage}/env-iface-guard.$$"
mkdir -p "${WORK}"
# The FULL cleanup (mutation restore + stand-in stop) is armed further down,
# after the helpers it calls exist. Until then, guard the work dir itself: a
# SIGTERM/SIGINT during the studio self-check or the browser preflight must not
# leak env-iface-guard.<pid> under ${TMPDIR:-/var/tmp/portage} (one such stale
# dir from a killed pre-fix run was found on this box). Two rules, both load-
# bearing and both replaced by the full trap below (bash traps do not stack):
#   * cleanup lives on EXIT only;
#   * the signal traps EXIT rather than fall through. A bash signal trap that
#     does not exit lets the script RESUME after the handler — measured here:
#     a plain `trap 'rm -rf $WORK' EXIT INT TERM HUP` took a SIGTERM at t=4s,
#     deleted WORK, kept running, and the battery then mutated production with
#     its bookkeeping directory gone — four steps/*.ts files were left mutated
#     on disk. Exiting turns the signal into a normal EXIT-trap teardown.
trap 'rm -rf "${WORK}"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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

# THE BROWSER MUST LAUNCH, and that is a prerequisite, not a finding. The bdd
# project opens a page for every scenario, so a browser that cannot launch turns
# every scenario RED and "baseline lane rc=1" then reads as a product defect.
# MEASURED 2026-08-27: this file forced PLAYWRIGHT_BROWSERS_PATH to
# /var/tmp/portage/pw-browsers — a per-host farm of symlinks into
# ~/.cache/ms-playwright that pointed at a Chromium revision a later
# `npx playwright install` had garbage-collected — and reported
# "FAIL baseline lane rc=1" plus nine manifest problems ("manifest lists ZERO
# artefacts", "no cli transcript was written at all", ...) against a lane that
# was rc=0, 44 passed 3 skipped, 67 manifest rows, the moment the override was
# dropped. Every failure came from one line:
#   browserType.launch: Executable doesn't exist at /var/tmp/portage/pw-browsers/...
# So: resolve browsers exactly as the lane does — Playwright's own resolver,
# honouring PLAYWRIGHT_BROWSERS_PATH ONLY IF THE CALLER SET IT — and launch one
# page through the same headless channel the bdd project uses. If that fails,
# exit 2 naming the install command; never grade a lane that cannot open a page.
PREFLIGHT="${WORK}/preflight"
mkdir -p "${PREFLIGHT}"
ln -sfn "${E2E}/node_modules" "${PREFLIGHT}/node_modules"
cat > "${PREFLIGHT}/pw.config.ts" <<'TS'
import { defineConfig, devices } from '@playwright/test';
export default defineConfig({
  testDir: __dirname, reporter: [['list']], workers: 1, retries: 0, timeout: 60_000,
  use: { ...devices['Desktop Chrome'] },
});
TS
cat > "${PREFLIGHT}/launch.spec.ts" <<'TS'
import { test } from '@playwright/test';
test('the headless browser the bdd project launches is installed', async ({ page }) => {
  await page.goto('about:blank');
});
TS
if ! ( cd "${E2E}" && npx playwright test -c "${PREFLIGHT}/pw.config.ts" \
         >"${WORK}/preflight.out" 2>&1 ); then
  echo "SKIPPED-LOUDLY: the headless browser cannot launch, so every bdd scenario" >&2
  echo "  would fail before reaching a step and this guard would report a product" >&2
  echo "  defect that is really a missing prerequisite. Install it with:" >&2
  echo "    (cd ${E2E} && npx playwright install chromium)   [or: make playwright-deps]" >&2
  if [ -n "${PLAYWRIGHT_BROWSERS_PATH:-}" ]; then
    echo "  NOTE PLAYWRIGHT_BROWSERS_PATH=${PLAYWRIGHT_BROWSERS_PATH} is set in this" >&2
    echo "  environment, so Playwright looks THERE and not in ~/.cache/ms-playwright." >&2
  fi
  grep -m1 -E "Executable doesn't exist|browserType.launch|Error:" "${WORK}/preflight.out" >&2
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

# m7_standin_stop is defined much further down (with the M7 rewrite); an exit
# taken BEFORE that definition runs — a signal during the baseline lane, or any
# early failure — must not abort cleanup on `command not found` and leak WORK
# (measured: a SIGTERM at t=4s did exactly that). Guard the call.
#
# kill_tree: on a signal, bash 5.3 runs the trap WITHOUT waiting for a lane's
# `( cd ... && npx playwright test ... )` subshell (measured in an xtrace:
# `exit 143` fired 1.2s into vocab_lane m1's npx). The orphaned node/browser
# tree then keeps writing under WORK while `rm -rf` walks it, and whatever it
# recreates behind the walk survives as a leaked dir (measured: one kill in
# five leaked baseline/ fragments). TERM the descendants children-first, then
# remove — and re-check once, because rm against a dying writer is a race.
# pgrep -P is by parent pid (no -f), so it cannot self-match.
kill_tree() {
  local p
  for p in $(pgrep -P "$1" 2>/dev/null || true); do kill_tree "${p}"; done
  [ "$1" != "$$" ] && kill -TERM "$1" 2>/dev/null
  return 0
}
cleanup() {
  restore_all
  if declare -F m7_standin_stop >/dev/null; then m7_standin_stop; fi
  local p
  for p in $(pgrep -P $$ 2>/dev/null || true); do kill_tree "${p}"; done
  rm -rf "${WORK}" 2>/dev/null
  if [ -d "${WORK}" ]; then sleep 1; rm -rf "${WORK}" 2>/dev/null; fi
  return 0
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
trap cleanup EXIT
# The signal traps EXIT so the EXIT trap runs cleanup exactly once; a handler
# that falls through would let the script RESUME past the teardown (measured —
# see the early trap above) and re-mutate with its backups already deleted.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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

# run_lane <label> [VAR=value ...] -> writes $WORK/<label>.json ; echoes the
# playwright exit code. Extra VAR=value arguments are put in the lane's
# environment (M7 points the docker probe at its stand-in this way). No
# PLAYWRIGHT_BROWSERS_PATH is set here: the lane resolves browsers exactly as
# `make stack-e2e-bdd` does, and the preflight above has already proven that
# resolution launches.
run_lane() {
  local label="$1"; shift
  ( cd "${E2E}" && \
    env "$@" \
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

# ── 1. the baseline lane: 4 pass, 3 skip (mesh down), every skip with a reason ─
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

# measure_serving <label> [VAR=value ...] -> $WORK/serving-<label>.json
# Runs production's environmentAvailability() for all three environments in a
# fresh process (so no probe cache can answer for a world that changed), with
# any VAR=value placed in that process's environment. Used for the baseline
# measurement and re-used by M7 for its control.
measure_serving() {
  local label="$1"; shift
  ( cd "${E2E}" && \
    env "$@" SNAP_SERVING_OUT="${WORK}/serving-${label}.json" \
    npx playwright test -c "${PROBE}/pw.config.ts" >"${WORK}/serving-${label}.out" 2>&1 )
}

measure_serving baseline
SERVING_JSON="${WORK}/serving-baseline.json"
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
  bad "could not measure environment availability (see ${WORK}/serving-baseline.out) — this "\
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
NOT_RUNNABLE_WHY=()
mut_not_runnable() {  # mut_not_runnable <name> <why>
  echo "  NOT-RUNNABLE $1"
  echo "               $2"
  NOT_RUNNABLE=$((NOT_RUNNABLE+1))
  NOT_RUNNABLE_WHY+=("$1: $2")
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

# M7 — docker trusts whatever answers on a port it does not own. Sibling of M6.
#
# THE DEFECT: the docker probe's SUCCESS branch took any HTTP status line as
# "the compose stack answered", even when `docker ps` said the port was published
# by the KIND node (PR #202/#203 added the owner check). Observing the defect
# needs a FOREIGN OWNER to exist: a container whose name matches /control-plane/,
# publishing a host port, answering HTTP.
#
# Until today this block BORROWED that owner from the host: it edited docker's
# fallback back to :8443 and relied on the kind node happening to be Up there.
# MEASURED 2026-08-27 on a host where the kind node was gone (`docker ps -a` did
# not list it; nothing on :8443): ECONNREFUSED on both sides of the mutation, the
# status line read `docker:skipped` both times, and the guard reported SURVIVED
# against a fix that works — the mirror image of the false verdict #208 removed
# for the mesh-UP state. A mutation that is only observable in one host state,
# graded in another, is not a test.
#
# So the guard now BUILDS the collision instead of hoping for it: a throwaway
# container named e2eguard-m7-<pid>-control-plane publishes a FREE LOOPBACK port
# (127.0.0.1 only, never 0.0.0.0) and answers HTTP; the docker probe is pointed
# at it through SNAP_ENV_DOCKER_BASE_URL — the same override the harness itself
# honours, and it beats SNAP_BASE_URL — so no setup edit to production is needed
# and the mutation IS the defect. That makes M7 observable in every host state:
# nothing up, kind only, compose only.
#
# TWO measurements, both required:
#   CONTROL  production UNMUTATED must veto the stand-in (verdict=foreign-owner).
#            If it does not, either the stand-in is not what `docker ps` shows or
#            the owner check is already broken. Both are RED, and neither is
#            CAUGHT — a control that fails is reported as a failure of its own.
#   MUTATED  with the owner check disabled the @env:docker scenario must stop
#            skipping: it drives the stand-in and passes, which is exactly the
#            silent pass this mutation exists to demonstrate.
#
# The container is removed right after M7, and by the EXIT trap on any signal.
# It needs a reachable docker daemon and a local image that can serve HTTP
# (E2EGUARD_M7_IMAGE, default python:3.12-slim — the pre-merge debian job's
# image; alpine:3 will not do, its busybox has no httpd applet). Without either
# M7 is NOT-RUNNABLE and the run exits 2 naming the command. Nothing is pulled.
M7_IMAGE="${E2EGUARD_M7_IMAGE:-python:3.12-slim}"
M7_NAME="e2eguard-m7-$$-control-plane"
m7_standin_stop() { docker rm -f "${M7_NAME}" >/dev/null 2>&1 || true; }
m7_standin_start() {  # -> echoes the loopback port on success, nothing on failure
  # A run killed with SIGKILL runs no trap; its stand-in would still be here.
  # Sweep only OUR naming shape, never anything else on the host.
  docker ps -a --format '{{.Names}}' 2>/dev/null \
    | grep -E '^e2eguard-m7-[0-9]+-control-plane$' \
    | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker run -d --name "${M7_NAME}" -p 127.0.0.1::80 "${M7_IMAGE}" \
    python3 -m http.server 80 --bind 0.0.0.0 -d /tmp \
    >/dev/null 2>"${WORK}/m7-standin.err" || return 1
  local port="" i
  port="$(docker port "${M7_NAME}" 80/tcp 2>/dev/null | sed -n 's/.*://p' | head -1)"
  [ -n "${port}" ] || return 1
  # Wait for an HTTP answer, not a TCP accept: docker's userland proxy accepts
  # before the server inside is listening. Any status code counts.
  for i in $(seq 1 50); do
    if python3 - "${port}" <<'PY' >/dev/null 2>&1
import sys, urllib.request, urllib.error
try:
    urllib.request.urlopen("http://127.0.0.1:%s/" % sys.argv[1], timeout=2)
except urllib.error.HTTPError:
    pass
PY
    then echo "${port}"; return 0; fi
    sleep 0.2
  done
  return 1
}

if [ -z "${BASE_ENVSTATUS}" ]; then
  bad "M7 cannot run: the baseline analysis emitted no envstatus line"
elif ! docker ps >/dev/null 2>&1; then
  mut_not_runnable "M7 docker accepts a foreign port owner as the compose stack" \
    "no reachable docker daemon, so the guard cannot stand up the foreign-owner container the mutation needs (start dockerd, or run this on a host with docker)"
elif ! docker image inspect "${M7_IMAGE}" >/dev/null 2>&1; then
  mut_not_runnable "M7 docker accepts a foreign port owner as the compose stack" \
    "image ${M7_IMAGE} is not present locally and this guard pulls nothing — run: docker pull ${M7_IMAGE}   (or set E2EGUARD_M7_IMAGE to a local image that has python3)"
else
  M7_PORT="$(m7_standin_start)"
  if [ -z "${M7_PORT}" ]; then
    bad "M7 stand-in container ${M7_NAME} (${M7_IMAGE}) did not come up answering HTTP — see ${WORK}/m7-standin.err"
    sed -n '1,5p' "${WORK}/m7-standin.err" >&2
  else
    M7_URL="http://127.0.0.1:${M7_PORT}"
    M7_OWNER="$(docker ps --format '{{.Names}}\t{{.Ports}}' | grep -F ":${M7_PORT}->" | cut -f1 | head -1)"
    echo "  M7 stand-in: ${M7_NAME} publishes ${M7_URL} (docker ps owner: ${M7_OWNER:-<none>})"
    # CONTROL: unmutated production, docker probe aimed at the stand-in.
    measure_serving m7-control "SNAP_ENV_DOCKER_BASE_URL=${M7_URL}"
    M7_CONTROL="$(python3 - "${WORK}/serving-m7-control.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1])).get("docker", {})
ok = (not d.get("available")) and ("verdict=foreign-owner" in (d.get("detail") or ""))
print("ok" if ok else "bad")
print("available=%s detail=%s" % (d.get("available"), d.get("detail")))
PY
)"
    if [ "$(printf '%s\n' "${M7_CONTROL}" | sed -n 1p)" != "ok" ]; then
      bad "M7 CONTROL failed: UNMUTATED production did not veto the stand-in as a foreign owner — either 'docker ps' does not show ${M7_NAME} publishing :${M7_PORT}, or the owner check in steps/dimensions.ts is already broken. Not graded as CAUGHT."
      echo "       $(printf '%s\n' "${M7_CONTROL}" | sed -n 2p)" >&2
    elif mutate tests/e2e/steps/dimensions.ts <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
# THE DEFECT, and only the defect: both probe branches carry the identical
# condition, so anchor on the SUCCESS branch's preceding comment. A non-unique
# anchor must refuse rather than mutate whichever site it reaches first.
old = ("    // its pgrep gate above; docker had nothing equivalent.\n"
       "    if (owner && def.id !== 'kind' && /control-plane/.test(owner)) {")
new = ("    // its pgrep gate above; docker had nothing equivalent.\n"
       "    if (false && owner && def.id !== 'kind' && /control-plane/.test(owner)) {")
assert s.count(old) == 1, "anchor for M7 not unique: %d" % s.count(old)
open(p, 'w').write(s.replace(old, new))
PY
    then
      regen >/dev/null 2>&1
      run_lane m7 "SNAP_ENV_DOCKER_BASE_URL=${M7_URL}" >/dev/null
      analyse m7 lite || true
      M7_ENVSTATUS="$(sed -n 's/^NOTE envstatus=//p' "${WORK}/m7.analysis" | head -1)"
      M7_DOCKER="$(printf '%s\n' "${M7_ENVSTATUS}" | tr ',' '\n' | sed -n 's/^docker://p')"
      if [ -z "${M7_DOCKER}" ] || [ "${M7_DOCKER}" = "skipped" ]; then
        mut_result "M7 docker accepts a foreign port owner as the compose stack" 0 \
          "with the owner check disabled and docker aimed at the stand-in, the @env:docker scenario still reported '${M7_DOCKER:-<absent>}' (envstatus '${M7_ENVSTATUS}')"
      else
        mut_result "M7 docker accepts a foreign port owner as the compose stack" 1 ""
        echo "             control  (owner check intact):   docker unavailable, verdict=foreign-owner"
        echo "             mutated  (owner check disabled): docker:${M7_DOCKER}   (envstatus ${M7_ENVSTATUS})"
      fi
    else
      bad "M7 could not be applied"; fi
  fi
  restore_all
  m7_standin_stop
fi

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
  echo "   SKIPPED-LOUDLY: this run could not exercise part of the mutation battery"
  echo "   in this host state (serving now: ${SERVING_ENVS:-<none>}):"
  for why in "${NOT_RUNNABLE_WHY[@]+"${NOT_RUNNABLE_WHY[@]}"}"; do
    echo "     - ${why}"
  done
  echo "   Exiting 2 rather than 0 — a green here would claim coverage this run did"
  echo "   not have. Nothing is wrong with the tree; re-run in the named host state."
  exit 2
fi
echo "== e2e env x interface: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

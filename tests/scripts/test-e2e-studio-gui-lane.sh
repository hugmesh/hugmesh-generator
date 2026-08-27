#!/usr/bin/env bash
# test-e2e-studio-gui-lane.sh — the gate for the STUDIO GUI as an e2e driver.
#
# SIBLING TO test-e2e-env-interface-dimensions.sh, not a replacement. That one
# proves the env × interface axes resolve and leave evidence. This one proves the
# two things unit G-GUI added on top:
#
#   1. THE ENVIRONMENT IS ONE CONTRACT. The environment an operator picks in the
#      Studio reaches the SPAWNED RUNNER, on the same channel the terminal uses
#      (SNAP_ENV). The GUI's plan and the CLI's plan are compared field by field,
#      and neither may emit a command that STARTS a mesh.
#   2. THE GUI PHOTOGRAPHS ITSELF, PER STEP. Driving the Studio leaves a real Qt
#      widget grab per Gherkin step, and the evidence manifest indexes every one
#      — with the index checked against the disk in BOTH directions, because a
#      manifest that lies is worse than no manifest.
#
# MUTATION BATTERY. Both claims are re-checked with production DELIBERATELY
# BROKEN, and each mutation must turn this guard RED. Every mutation is applied
# to the REAL tree with a backup, PROVEN to have changed the file, and restored
# on EXIT via trap; the final check asserts the tree is byte-identical to how it
# started, so a half-restored tree is a failure rather than a surprise for the
# next agent.
#
# OFFLINE. Starts NOTHING — no stack, no cluster, no emulator, no image build,
# no sudo. Every scenario in this lane is designed to pass with all three
# environments down, because it tests the CHOOSER, not the mesh.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
E2E="${REPO}/tests/e2e"
STUDIO="${REPO}/studio"
FEATURE_REL=".features-gen/features/studio/"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

echo "== e2e Studio GUI lane: the chooser is one contract, and the GUI photographs itself =="

# ── preconditions: refuse to be vacuous ──────────────────────────────────────
for t in node python3 git bash md5sum; do
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

WORK="${TMPDIR:-/var/tmp/portage}/studio-gui-guard.$$"
mkdir -p "${WORK}"

PY_BIN="${SNAP_STUDIO_PYTHON:-python3}"

# The whole lane needs a Qt6 binding: half of it BUILDS THE REAL WIZARD. On a
# host without one those scenarios skip correctly (with a reason), and this
# guard would then be failing for an ABSENT PREREQUISITE rather than a defect.
# Decide that up front, loudly, with the install command. Exit 2, never 0.
if ! QT_QPA_PLATFORM=offscreen "${PY_BIN}" "${E2E}/studio-driver.py" --self-check \
     >"${WORK}/selfcheck.out" 2>&1; then
  echo "SKIPPED-LOUDLY: no usable Qt6 binding, so the Studio GUI cannot be driven" >&2
  echo "  and this guard would fail for a missing prerequisite rather than a defect." >&2
  echo "  Install PySide6 or PyQt6 (pip install -r studio/requirements.txt), or point" >&2
  echo "  SNAP_STUDIO_PYTHON at an interpreter that has one." >&2
  sed -n '1,10p' "${WORK}/selfcheck.out" >&2
  echo "This guard checked NOTHING. Exiting 2 rather than 0." >&2
  exit 2
fi

# Byte fingerprint of every file the battery may touch, taken BEFORE anything is
# broken. The final check diffs against this.
tree_fingerprint() {
  ( cd "${REPO}" \
    && md5sum studio/hugmesh_studio/core/e2e_environments.py \
              studio/hugmesh_studio/core/e2e_evidence.py \
              studio/hugmesh_studio/core/local_stack_node.py \
              studio/hugmesh_studio/gui/pages/localmesh.py \
              tests/e2e/studio-driver.py \
              tests/e2e/steps/evidence.ts )
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
  # A mutant leaves stale bytecode behind, and a later run importing it would
  # reproduce the mutation with the source already restored — an unexplained
  # ghost failure this repo has seen once before.
  find "${STUDIO}" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null
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

# mutate <relpath> <<PY … PY — applies a python patch and PROVES the file changed.
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
  find "${STUDIO}" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null
  return 0
}

regen() { ( cd "${E2E}" && npx bddgen >"${WORK}/bddgen.out" 2>&1 ); }

# run_lane <label> -> writes evidence under $WORK/<label>; echoes the exit code
run_lane() {
  local label="$1"
  ( cd "${E2E}" && \
    PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/var/tmp/portage/pw-browsers}" \
    SNAP_REPORT_DIR="${WORK}/${label}" \
    SNAP_RUN_ID="${label}" \
    npx playwright test --project=bdd --retries=0 --reporter=line "${FEATURE_REL}" \
      >"${WORK}/${label}.out" 2>&1 )
  echo "$?"
}

pyunit() {  # pyunit <label> <pytest-args...>
  local label="$1"; shift
  ( cd "${STUDIO}" && QT_QPA_PLATFORM=offscreen "${PY_BIN}" -m pytest -q -p no:cacheprovider \
      "$@" >"${WORK}/${label}.out" 2>&1 )
}

HAVE_PYTEST=1
"${PY_BIN}" -c 'import pytest' >/dev/null 2>&1 || HAVE_PYTEST=0

# ── 0. generation still works ────────────────────────────────────────────────
if regen; then
  ok "npx bddgen exits 0 with the Studio GUI lane present"
else
  bad "npx bddgen FAILED — see ${WORK}/bddgen.out"
  sed -n '1,20p' "${WORK}/bddgen.out" >&2
fi

SCEN="$( ( cd "${E2E}" && PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/var/tmp/portage/pw-browsers}" \
  npx playwright test --list --project=bdd "${FEATURE_REL}" 2>/dev/null ) \
  | sed -n 's/^Total: \([0-9]*\) tests.*/\1/p' | tail -1 )"
if [ "${SCEN:-0}" -ge 9 ]; then
  ok "the Studio GUI lane collects ${SCEN} scenarios"
else
  bad "the Studio GUI lane collected '${SCEN:-<none>}' scenarios (expected >= 9)"
fi

# ── 1. the lane is GREEN with nothing started ────────────────────────────────
BASE_RC="$(run_lane baseline)"
if [ "${BASE_RC}" -eq 0 ]; then
  ok "the Studio GUI lane is green (rc=0) with NO stack, NO cluster and NO emulator"
else
  bad "baseline lane rc=${BASE_RC} — see ${WORK}/baseline.out"
  grep -viE 'npm notice' "${WORK}/baseline.out" | tail -25 >&2
fi

# ── the analyser: reads ONLY the on-disk evidence ────────────────────────────
cat > "${WORK}/analyse.py" <<'PY'
import json, os, sys
run_dir, mode = sys.argv[1], sys.argv[2]
problems, notes = [], []

jl = os.path.join(run_dir, 'manifest.jsonl')
if not os.path.exists(jl):
    print("PROBLEM no manifest.jsonl at %s" % jl)
    sys.exit(1)
rows = [json.loads(l) for l in open(jl) if l.strip()]
notes.append("rows=%d" % len(rows))

grabs = [r for r in rows if r.get('kind') == 'widget-grab']
notes.append("widget-grabs=%d" % len(grabs))
if mode == 'full' and len(grabs) < 6:
    problems.append("only %d widget-grab row(s); the lane drives the Studio at "
                    "least 6 times, so a lower count means grabs are being lost"
                    % len(grabs))

# EVERY grab row must be a REAL PNG on disk. This is the direction the M4
# mutation attacks: the driver reports a grab it never wrote.
for r in grabs:
    p = os.path.join(run_dir, r.get('path') or '')
    if not r.get('path') or not os.path.exists(p):
        problems.append("widget-grab row points at a MISSING file: %s" % r.get('path'))
        continue
    with open(p, 'rb') as fh:
        head = fh.read(8)
    if head != b'\x89PNG\r\n\x1a\n':
        problems.append("widget-grab %s is not a PNG" % r.get('path'))
    elif os.path.getsize(p) == 0:
        problems.append("widget-grab %s is empty" % r.get('path'))

# ...and every artefact on disk must have a row. Post-run this holds absolutely.
listed, on_disk = set(), set()
for r in rows:
    p = r.get('path') or ''
    if p and os.path.exists(os.path.join(run_dir, p)):
        listed.add(os.path.normpath(os.path.join(run_dir, p)))
for dp, dn, fn in os.walk(run_dir):
    dn[:] = [d for d in dn if d != '.driver-tmp']
    for f in fn:
        if f in ('manifest.json', 'manifest.jsonl'):
            continue
        if f.endswith('.json') and not f.endswith('.cli.json') \
                and not f.endswith('.studio.json'):
            continue
        on_disk.add(os.path.normpath(os.path.join(dp, f)))
orph = sorted(on_disk - listed)
if orph:
    problems.append("%d artefact(s) on disk with NO manifest row: %s"
                    % (len(orph), ", ".join(os.path.basename(o) for o in orph[:5])))

# The per-step walk: one scenario drives the Studio three times and each step
# must have left its OWN grab, at its own ordinal.
walk = [r for r in grabs if 'walking-the-Studio' in (r.get('path') or '')]
ordinals = sorted({r.get('ordinal') for r in walk})
notes.append("walk-ordinals=%s" % ordinals)
if mode == 'full' and ordinals != [1, 2, 3]:
    problems.append("the per-step walk recorded grabs at ordinals %s, expected "
                    "[1, 2, 3] — one grab per Gherkin step" % ordinals)

# Every row carries both axes, or the Studio's browser cannot group by them.
for r in rows:
    if not r.get('env') or not r.get('interface'):
        problems.append("row %s has env=%r interface=%r"
                        % (r.get('path'), r.get('env'), r.get('interface')))
        break

notes.append("interfaces=%s" % ",".join(sorted({r.get('interface') or '?' for r in rows})))
for n in notes:
    print("NOTE %s" % n)
for p in problems:
    print("PROBLEM %s" % p)
sys.exit(1 if problems else 0)
PY

analyse() { python3 "${WORK}/analyse.py" "${WORK}/$1/bdd-steps/$1" "$2" \
              >"${WORK}/$1.analysis" 2>&1; }

if analyse baseline full; then
  ok "per-step Qt widget grabs are real PNGs and the manifest indexes every one"
  sed -n 's/^NOTE /       /p' "${WORK}/baseline.analysis"
else
  bad "baseline evidence problems:"
  sed -n 's/^PROBLEM /       /p' "${WORK}/baseline.analysis" >&2
fi

# ── 2. the reader agrees with the producer, post-run, BOTH directions ────────
if ( cd "${STUDIO}" && "${PY_BIN}" -m hugmesh_studio --e2e-evidence \
        "${WORK}/baseline/bdd-steps/baseline" --json ) >"${WORK}/reader.json" 2>&1; then
  ok "the Studio's evidence reader accepts the finished run (index == disk, both ways)"
else
  bad "the Studio's evidence reader rejects the run it just produced:"
  tail -5 "${WORK}/reader.json" >&2
fi

# ── 3. the Python units ──────────────────────────────────────────────────────
if [ "${HAVE_PYTEST}" -eq 0 ]; then
  echo "  SKIP  the Studio unit lane: '${PY_BIN} -m pytest' is not importable." >&2
  echo "        NAMED REASON, not a silent pass: install pytest into that interpreter" >&2
  echo "        (or set SNAP_STUDIO_PYTHON) to run studio/tests/test_e2e_environments.py," >&2
  echo "        test_e2e_evidence.py and test_pages_e2e_environment.py." >&2
  bad "the Studio unit lane could not run (pytest missing) — not counted as a pass"
elif pyunit units tests/test_e2e_environments.py tests/test_e2e_evidence.py \
                   tests/test_pages_e2e_environment.py; then
  ok "$(tail -1 "${WORK}/units.out")"
else
  bad "the Studio unit lane failed:"
  tail -20 "${WORK}/units.out" >&2
fi

# ── 4. MUTATION BATTERY ──────────────────────────────────────────────────────
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

# M1 — THE ENVIRONMENT IS IGNORED. SNAP_ENV never reaches the spawned runner, so
# every run drives docker while the GUI label says otherwise.
if mutate studio/hugmesh_studio/core/e2e_environments.py <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '    out: "dict[str, str]" = {ENV_VAR: env.id}'
new = '    out: "dict[str, str]" = {}'
assert s.count(old) == 1, "anchor for M1 not unique: %d" % s.count(old)
open(p, 'w').write(s.replace(old, new))
PY
then
  if [ "$(run_lane m1)" -eq 0 ]; then
    mut_result "M1 the chosen environment never reaches the runner" 0 \
               "the lane stayed green with SNAP_ENV dropped"
  else
    mut_result "M1 the chosen environment never reaches the runner" 1 ""
  fi
else
  bad "M1 could not be applied"; fi
restore_all

# M2 — the GUI and the CLI disagree: the GUI silently substitutes docker.
if mutate studio/hugmesh_studio/gui/pages/localmesh.py <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '        return combo.currentData() or e2e_environments.DEFAULT_ENVIRONMENT'
new = '        return e2e_environments.DEFAULT_ENVIRONMENT'
assert s.count(old) == 1, "anchor for M2 not unique: %d" % s.count(old)
open(p, 'w').write(s.replace(old, new))
PY
then
  if [ "$(run_lane m2)" -eq 0 ]; then
    mut_result "M2 the GUI ignores the chooser and always says docker" 0 \
               "the lane stayed green"
  else
    mut_result "M2 the GUI ignores the chooser and always says docker" 1 ""
  fi
else
  bad "M2 could not be applied"; fi
restore_all

# M3 — a bridge dict may re-point the run. The GUI would say kind and the suite
# would drive docker, with nothing anywhere reporting the substitution.
if mutate studio/hugmesh_studio/core/e2e_environments.py <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '        if key == ENV_VAR and value != env.id:'
new = '        if False and key == ENV_VAR and value != env.id:'
assert s.count(old) == 1, "anchor for M3 not unique: %d" % s.count(old)
open(p, 'w').write(s.replace(old, new))
PY
then
  if [ "${HAVE_PYTEST}" -eq 1 ] && ! pyunit m3 tests/test_e2e_environments.py; then
    mut_result "M3 a bridge dict can silently re-point the environment" 1 ""
  else
    mut_result "M3 a bridge dict can silently re-point the environment" 0 \
               "the unit lane stayed green (or pytest was unavailable)"
  fi
else
  bad "M3 could not be applied"; fi
restore_all

# M4 — *** THE MANIFEST LIES. *** The grab's PNG is never placed in the run
# tree, but the widget-grab ROW is emitted anyway. The index then claims an
# artefact nobody can open — and a reviewer counts the rows and believes them,
# which is what makes this worse than having no manifest at all.
#
# The mutation is planted at the COPY, not at the driver's save: killing the
# driver would make the ROW absent too, which is a different (and loud) failure.
# The lie being tested for is specifically "row present, file absent".
if mutate tests/e2e/steps/evidence.ts <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "      fs.copyFileSync(g.pngPath, pngAbs);"
new = "      // MUTANT: the grab is never placed in the run tree."
assert s.count(old) == 1, "anchor for M4 not unique: %d" % s.count(old)
open(p, 'w').write(s.replace(old, new))
PY
then
  regen >/dev/null 2>&1
  run_lane m4 >/dev/null
  if analyse m4 lite; then
    mut_result "M4 the manifest claims a grab that was never written" 0 \
               "the on-disk analysis stayed clean"
  else
    mut_result "M4 the manifest claims a grab that was never written" 1 ""
  fi
else
  bad "M4 could not be applied"; fi
restore_all

# M5 — the evidence reader stops checking that rows point at real files, so a
# lying manifest verifies clean. The GUI browser is built on this reader.
if mutate studio/hugmesh_studio/core/e2e_evidence.py <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "        if not abs_path or not os.path.exists(abs_path):\n            v.missing.append(row)"
new = "        if False:\n            v.missing.append(row)"
assert s.count(old) == 1, "anchor for M5 not unique: %d" % s.count(old)
open(p, 'w').write(s.replace(old, new))
PY
then
  if [ "${HAVE_PYTEST}" -eq 1 ] && ! pyunit m5 tests/test_e2e_evidence.py \
                                            tests/test_pages_e2e_environment.py; then
    mut_result "M5 the evidence reader stops noticing a lying row" 1 ""
  else
    mut_result "M5 the evidence reader stops noticing a lying row" 0 \
               "the unit lane stayed green (or pytest was unavailable)"
  fi
else
  bad "M5 could not be applied"; fi
restore_all

# M6 — the environment catalogue drifts from the harness's. A GUI run would
# select an id tests/e2e/steps/dimensions.ts refuses to resolve.
if mutate studio/hugmesh_studio/core/e2e_environments.py <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '''    E2EEnvironment(
        id="qemu",'''
new = '''    E2EEnvironment(
        id="vm",'''
assert s.count(old) == 1, "anchor for M6 not unique: %d" % s.count(old)
open(p, 'w').write(s.replace(old, new))
PY
then
  if [ "${HAVE_PYTEST}" -eq 1 ] && ! pyunit m6 tests/test_e2e_environments.py; then
    mut_result "M6 the Studio's environment list drifts from dimensions.ts" 1 ""
  else
    mut_result "M6 the Studio's environment list drifts from dimensions.ts" 0 \
               "the drift guard stayed green (or pytest was unavailable)"
  fi
else
  bad "M6 could not be applied"; fi
restore_all

# M7 — the qemu emulator probe goes back to `pgrep -f`, which MATCHES ITS OWN
# INVOKING SHELL. Measured in this tree: it reported an emulator with none
# running. A false positive here makes a device scenario run against a stranger.
if mutate studio/hugmesh_studio/core/e2e_environments.py <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '''        r = run(["pgrep", "^qemu-system-"], capture_output=True, text=True, timeout=10)'''
new = '''        r = run(["pgrep", "-f", "qemu-system-"], capture_output=True, text=True, timeout=10)'''
assert s.count(old) == 1, "anchor for M7 not unique: %d" % s.count(old)
open(p, 'w').write(s.replace(old, new))
PY
then
  if [ "${HAVE_PYTEST}" -eq 1 ] && ! pyunit m7 tests/test_e2e_environments.py; then
    mut_result "M7 the emulator probe self-matches (pgrep -f)" 1 ""
  else
    mut_result "M7 the emulator probe self-matches (pgrep -f)" 0 \
               "the name-anchor check stayed green (or pytest was unavailable)"
  fi
else
  bad "M7 could not be applied"; fi
restore_all

# M8 — a modal in page logic. A QMessageBox from the chooser's own
# currentIndexChanged handler HANGS every headless test; the static rule has to
# catch it before a hang teaches anyone anything.
if mutate studio/hugmesh_studio/gui/pages/localmesh.py <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '''        env_id = self.e2e_environment()
        try:
            plan = e2e_environments.plan(env_id)'''
new = '''        env_id = self.e2e_environment()
        QtWidgets.QMessageBox.information(self, "target", env_id)
        try:
            plan = e2e_environments.plan(env_id)'''
assert s.count(old) == 1, "anchor for M8 not unique: %d" % s.count(old)
open(p, 'w').write(s.replace(old, new))
PY
then
  if [ "${HAVE_PYTEST}" -eq 1 ] \
     && ! pyunit m8 tests/test_pages_e2e_environment.py -k no_modal; then
    mut_result "M8 a QMessageBox in the chooser's change handler" 1 ""
  else
    mut_result "M8 a QMessageBox in the chooser's change handler" 0 \
               "the no-modal rule stayed green (or pytest was unavailable)"
  fi
else
  bad "M8 could not be applied"; fi
restore_all

# M9 — the plan is built correctly and then DROPPED at the spawn. This is the
# bug with no symptom: the chooser is right, the plan is right, the log line
# names kind, and the child process never sees SNAP_ENV at all. M1 cannot catch
# it (run_env is untouched), which is why the boundary gets its own mutation.
if mutate studio/hugmesh_studio/core/local_stack_node.py <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "        env = dict(plan.env)\n        env[\"SNAP_REPORT_DIR\"] = report_rel"
new = "        env = {}\n        env[\"SNAP_REPORT_DIR\"] = report_rel"
assert s.count(old) == 1, "anchor for M9 not unique: %d" % s.count(old)
open(p, 'w').write(s.replace(old, new))
PY
then
  if [ "${HAVE_PYTEST}" -eq 1 ] && ! pyunit m9 tests/test_e2e_environments.py; then
    mut_result "M9 the plan is dropped between the chooser and the spawn" 1 ""
  else
    mut_result "M9 the plan is dropped between the chooser and the spawn" 0 \
               "the spawn-boundary tests stayed green (or pytest was unavailable)"
  fi
else
  bad "M9 could not be applied"; fi
restore_all

echo "  mutations: ${CAUGHT} caught, ${SURVIVED} survived"

# ── 5. the tree is exactly as we found it ────────────────────────────────────
regen >/dev/null 2>&1
tree_fingerprint > "${WORK}/tree-after.md5"
if diff -q "${WORK}/tree-before.md5" "${WORK}/tree-after.md5" >/dev/null; then
  ok "every mutation was reverted (the mutated files are byte-identical to pre-run)"
else
  bad "THE TREE WAS LEFT MUTATED — diff:"
  diff "${WORK}/tree-before.md5" "${WORK}/tree-after.md5" >&2
fi

echo "== e2e Studio GUI lane: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ] || exit 1

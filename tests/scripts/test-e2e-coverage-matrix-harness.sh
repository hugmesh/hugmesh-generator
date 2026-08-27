#!/usr/bin/env bash
# test-e2e-coverage-matrix-harness.sh — THE GUARD OVER tests/scripts/test-e2e-coverage-matrix.sh.
#
# That guard is the coverage matrix's drift gate: it re-emits, diffs, runs the
# 2105-cell Gherkin lane and then breaks production six ways. It takes minutes
# and needs a real chromium, so nothing gates IT — and on 2026-08-27 it lied in
# two ways nobody could see from its exit status (both MEASURED, log:
# offline2-stack-e2e-coverage-check.log and the wiki-spec timings below):
#
#   * it pinned PLAYWRIGHT_BROWSERS_PATH to a dangling symlink farm, so every
#     cell failed with `browserType.launch: Executable doesn't exist`, twice
#     each under the config's retries:1 — 0.82s/cell dead vs 0.12s/cell green
#     (124-cell wiki spec: 101.6s vs 15.2s), ~29 minutes of red about the
#     toolchain extrapolated over the lane, which is the >25-minute run a
#     coordinator timeout then killed;
#   * that timeout's SIGTERM ran the trap, which removed the scratch dir and
#     RETURNED, so the script blundered on without it: rc='' for the lane, six
#     "patch did not apply" survivors and "THE TREE WAS NOT FULLY RESTORED —
#     No such file or directory" — three false FAILs about its own bookkeeping,
#     none about coverage.
#
# This suite drives THE GUARD ITSELF, copied into a scratch git tree beside the
# real catalogues and features it mutates, with a STUB playwright/bddgen in a
# stub node_modules: no browser, no node_modules install, no mesh, seconds. It
# proves by execution (a kill it sends, a stub that records every argv):
#
#   1. a browser that cannot launch is refused in the PREFLIGHT — exit 2,
#      SKIPPED-LOUDLY, naming the executable and `make playwright-deps` — and
#      the lane is never invoked;
#   2. SIGTERM while a mutation is planted and the lane is in flight: the child
#      is stopped (not waited out), the tree is byte-identical again, the
#      scratch dir and fingerprint are gone, the exit is 143, the output says
#      so, and the next run's poisoned-tree preflight does not refuse;
#   3. the lane runs with --retries=0;
#   4. a lane that fails only because the browser could not launch is
#      SURVIVED, never CAUGHT;
#   5. a negative control: the old trap shape (handler RETURNS) makes probe 2
#      fail, so probe 2 can go red.
#
# OFFLINE. Starts nothing, installs nothing (npm_config_yes=false makes npx
# refuse to fetch if the stub were ever not found). Needs bash, node+npx (the
# guard's own precondition), python3, git.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
GUARD="${REPO}/tests/scripts/test-e2e-coverage-matrix.sh"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

echo "== e2e coverage matrix HARNESS: the drift guard refuses a dead browser and survives a kill =="

for t in node npx python3 git bash md5sum; do
  command -v "${t}" >/dev/null 2>&1 || {
    echo "SKIPPED-LOUDLY: ${t} is required and absent — this harness checked NOTHING. Exiting 2." >&2
    exit 2
  }
done
for f in "${GUARD}" "${REPO}/tests/e2e-extra-personas.sh" "${REPO}/tests/e2e/steps/coverage-catalogue.ts" \
         "${REPO}/tests/e2e/steps/dimensions.ts" "${REPO}/tests/e2e/tools/emit-coverage-matrix.ts" \
         "${REPO}/tests/e2e/gen-coverage-matrix.sh" \
         "${REPO}/tests/e2e/features/coverage/access-matrix-wiki.feature"; do
  [ -f "${f}" ] || { echo "SKIPPED-LOUDLY: ${f} is missing; nothing to harness. Exiting 2." >&2; exit 2; }
done

export npm_config_yes=false
export npm_config_update_notifier=false

SCRATCH="${TMPDIR:-/var/tmp/portage}/coverage-harness.$$"
mkdir -p "${SCRATCH}/tmp"
# Anything still carrying the scratch path in its argv is a child some probe
# left behind; the last probe asserts there are none, and EXIT cleans up anyway.
leftovers() { pgrep -f "${SCRATCH}" 2>/dev/null || true; }
cleanup() {
  local p
  for p in $(leftovers); do kill -KILL "${p}" 2>/dev/null; done
  rm -rf "${SCRATCH}"
}
trap cleanup EXIT INT TERM HUP

# ── the scratch tree: the REAL files the guard mutates, in a git repo ───────
S="${SCRATCH}/repo"
mkdir -p "${S}/tests/scripts" "${S}/tests/e2e/features"
cp "${GUARD}" "${S}/tests/scripts/"
cp "${REPO}/tests/e2e-extra-personas.sh" "${S}/tests/"
cp -r "${REPO}/tests/e2e/steps" "${REPO}/tests/e2e/tools" "${S}/tests/e2e/"
cp "${REPO}/tests/e2e/gen-coverage-matrix.sh" "${S}/tests/e2e/"
cp -r "${REPO}/tests/e2e/features/coverage" "${S}/tests/e2e/features/"
git -C "${S}" init -q
git -C "${S}" -c user.name=harness -c user.email=harness@localhost add -A
git -C "${S}" -c user.name=harness -c user.email=harness@localhost commit -q -m base

TARGETS=(
  tests/e2e-extra-personas.sh
  tests/e2e/steps/dimensions.ts
  tests/e2e/steps/coverage-catalogue.ts
  tests/e2e/features/coverage/access-matrix-wiki.feature
)
fingerprint() { ( cd "${S}" && md5sum "${TARGETS[@]}" ); }
ORIGINAL="$(fingerprint)"

# ── the stub toolchain ──────────────────────────────────────────────────────
NM="${S}/tests/e2e/node_modules"
mkdir -p "${NM}/.bin" "${NM}/playwright-bdd" "${NM}/@playwright/test"
STUB_LOG="${SCRATCH}/stub.log"
cat > "${NM}/.bin/playwright" <<'STUB'
#!/usr/bin/env bash
# stub playwright: records every argv in STUB_LOG, simulates a lane.
#   STUB_LAUNCH_FAIL=1            every run fails like a missing chromium
#   STUB_LAUNCH_FAIL_MATCH=<str>  only runs whose argv contains <str> do
#   STUB_LANE_SLEEP=<s>           a --project=bdd run takes <s> seconds
set -u
log="${STUB_LOG:?}"
echo "START $*" >> "${log}"
s=
trap '[ -n "${s}" ] && kill "${s}" 2>/dev/null; echo "TERM $*" >> "${log}"; exit 143' TERM INT
case " $* " in
  *" --list "*)
    echo "Total: 2105 tests in 15 files"
    echo "  [bdd] › .features-gen/features/coverage/stub.feature.spec.js:1:1 › stub"
    echo "END $*" >> "${log}"; exit 0 ;;
esac
fail=0
[ "${STUB_LAUNCH_FAIL:-0}" = "1" ] && fail=1
if [ -n "${STUB_LAUNCH_FAIL_MATCH:-}" ]; then
  case " $* " in *"${STUB_LAUNCH_FAIL_MATCH}"*) fail=1 ;; esac
fi
if [ "${fail}" = "1" ]; then
  echo "  1) stub › the browser launches"
  echo "    Error: browserType.launch: Executable doesn't exist at /nowhere/chromium_headless_shell-0/chrome-headless-shell"
  echo "  1 failed"
  echo "END $*" >> "${log}"; exit 1
fi
case " $* " in
  *" --project=bdd "*)
    n="${STUB_LANE_SLEEP:-0}"
    if [ "${n}" -gt 0 ]; then sleep "${n}" & s=$!; wait "${s}"; fi
    echo "  124 passed (1s)"
    echo "END $*" >> "${log}"; exit 0 ;;
esac
echo "  1 passed (1s)"
echo "END $*" >> "${log}"; exit 0
STUB
printf '#!/usr/bin/env bash\necho "START bddgen $*" >> "${STUB_LOG:?}"\nexit 0\n' > "${NM}/.bin/bddgen"
chmod +x "${NM}/.bin/playwright" "${NM}/.bin/bddgen"
# The guard's first preflight is tests/e2e/check-toolchain.sh (one readiness
# opinion for the whole e2e tree). Here it is a stub like the playwright beside
# it: this harness grades the guard's ORCHESTRATION — refusal, kill, grading —
# not the box's toolchain, and the real probe would (correctly) refuse a scratch
# tree whose node_modules is four stub files.
printf '#!/usr/bin/env bash\necho "START check-toolchain $*" >> "${STUB_LOG:?}"\nexit 0\n' > "${S}/tests/e2e/check-toolchain.sh"
chmod +x "${S}/tests/e2e/check-toolchain.sh"

# run_guard <guard-file> <label> [VAR=value…] — start the guard in the
# background against the scratch tree. Sets GPID and GOUT.
GPID=; GOUT=
run_guard() {
  local guard="$1" label="$2"; shift 2
  GOUT="${SCRATCH}/${label}.out"
  : > "${STUB_LOG}"
  env "$@" STUB_LOG="${STUB_LOG}" TMPDIR="${SCRATCH}/tmp" bash "${guard}" > "${GOUT}" 2>&1 &
  GPID=$!
}
count() { grep -c -e "$1" "$2" 2>/dev/null || true; }
# lane_starts / lane_ends — the stub's records of REAL lane runs: --project=bdd
# without --list (the listing in step 2 is not a run).
lane_lines() { grep -e "$1" "${STUB_LOG}" 2>/dev/null | grep -v -e '--list' | grep -c -e '' || true; }
now() { date +%s; }

# ═════════════════════════════════════════════════════════════════════════════
# 1. A DEAD BROWSER IS REFUSED IN SECONDS, BEFORE THE LANE
# ═════════════════════════════════════════════════════════════════════════════
t0="$(now)"
run_guard "${S}/tests/scripts/test-e2e-coverage-matrix.sh" t1 STUB_LAUNCH_FAIL=1
wait "${GPID}"; rc=$?
dt=$(( $(now) - t0 ))
if [ "${rc}" = "2" ]; then
  ok "a browser that cannot launch -> exit 2 (${dt}s)"
else
  bad "a browser that cannot launch -> rc=${rc}, expected 2 (${dt}s) — see ${GOUT}"
fi
[ "$(count 'SKIPPED-LOUDLY' "${GOUT}")" -gt 0 ] \
  && ok "  and it says SKIPPED-LOUDLY" || bad "  no SKIPPED-LOUDLY line"
[ "$(count "Executable doesn't exist" "${GOUT}")" -gt 0 ] \
  && ok "  naming the executable Playwright looked for" || bad "  the executable path is not named"
[ "$(count 'make playwright-deps' "${GOUT}")" -gt 0 ] \
  && ok "  and the target that installs it" || bad "  'make playwright-deps' is not named"
[ "$(lane_lines 'START.*--project=bdd')" -eq 0 ] \
  && ok "  the lane was never invoked" || bad "  the lane RAN despite the dead browser"
[ "${dt}" -lt 60 ] && ok "  within a minute (${dt}s), not a 25-minute red run" || bad "  took ${dt}s"

# ═════════════════════════════════════════════════════════════════════════════
# 2. SIGTERM MID-BATTERY: CHILD STOPPED, TREE RESTORED, HONEST EXIT
# ═════════════════════════════════════════════════════════════════════════════
# kill_probe <guard-file> <label> — 0 when every kill assertion holds; the
# failing assertion's name is in KILL_WHY. Shared with the negative control.
KILL_WHY=
kill_probe() {
  local guard="$1" label="$2" i rc tk dk
  KILL_WHY=
  run_guard "${guard}" "${label}" STUB_LANE_SLEEP=8
  # Wait for M3: coverage-catalogue.ts mutated AND its lane in flight.
  for i in $(seq 1 180); do
    if [ "$(fingerprint)" != "${ORIGINAL}" ] \
       && [ "$(count 'START.*--project=bdd.*access-matrix-wiki' "${STUB_LOG}")" -gt 0 ]; then break; fi
    kill -0 "${GPID}" 2>/dev/null || { wait "${GPID}"; KILL_WHY="guard exited (rc=$?) before M3 planted a mutation"; return 1; }
    sleep 1
  done
  [ "$(fingerprint)" != "${ORIGINAL}" ] || { KILL_WHY="no mutation planted within 180s"; return 1; }
  kill -TERM "${GPID}"; tk="$(now)"
  wait "${GPID}"; rc=$?
  dk=$(( $(now) - tk ))
  KILL_RC="${rc}"; KILL_SECS="${dk}"
  [ "${rc}" = "143" ] || { KILL_WHY="rc=${rc}, expected 143"; return 1; }
  [ "$(fingerprint)" = "${ORIGINAL}" ] || { KILL_WHY="the tree is NOT byte-identical after the kill"; return 1; }
  [ -z "$(git -C "${S}" status --porcelain -- "${TARGETS[@]}")" ] \
    || { KILL_WHY="git sees the mutation targets modified: the next run would refuse"; return 1; }
  [ -z "$(ls -d "${SCRATCH}"/tmp/coverage-matrix-guard.* 2>/dev/null)" ] \
    || { KILL_WHY="the scratch dir / fingerprint survived the kill"; return 1; }
  [ "$(count 'KILLED BY SIGTERM' "${GOUT}")" -gt 0 ] || { KILL_WHY="no 'KILLED BY SIGTERM' line"; return 1; }
  [ "$(count 'byte-identical' "${GOUT}")" -gt 0 ] || { KILL_WHY="no restore verdict in the output"; return 1; }
  [ "$(count 'No such file or directory' "${GOUT}")" -eq 0 ] \
    || { KILL_WHY="'No such file or directory' — the script ran on after its scratch dir was removed"; return 1; }
  [ "$(lane_lines 'START.*--project=bdd')" -gt "$(lane_lines 'END.*--project=bdd')" ] \
    || { KILL_WHY="the in-flight lane ran to completion: the kill was waited out, not acted on"; return 1; }
  [ "${dk}" -le 5 ] || { KILL_WHY="took ${dk}s from SIGTERM to exit (the trap was deferred?)"; return 1; }
  [ -z "$(leftovers)" ] || { KILL_WHY="orphaned child process(es): $(leftovers | tr '\n' ' ')"; return 1; }
  return 0
}
if kill_probe "${S}/tests/scripts/test-e2e-coverage-matrix.sh" t2; then
  ok "SIGTERM mid-battery: child stopped, tree restored, scratch gone, exit 143 in ${KILL_SECS}s, no orphans, no 'No such file'"
else
  bad "SIGTERM mid-battery: ${KILL_WHY} — see ${GOUT}"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 3. THE LANE RUNS WITHOUT RETRIES
# ═════════════════════════════════════════════════════════════════════════════
lanes="$(lane_lines 'START.*--project=bdd')"
noretry="$(lane_lines 'START.*--project=bdd.*--retries=0')"
if [ "${lanes}" -gt 0 ] && [ "${lanes}" = "${noretry}" ]; then
  ok "every lane invocation carries --retries=0 (${lanes} of ${lanes})"
else
  bad "lane invocations with --retries=0: ${noretry} of ${lanes}"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 4. A LANE RED ONLY BECAUSE THE BROWSER DIED IS NOT A CATCH
# ═════════════════════════════════════════════════════════════════════════════
run_guard "${S}/tests/scripts/test-e2e-coverage-matrix.sh" t4 STUB_LAUNCH_FAIL_MATCH=access-matrix-wiki
wait "${GPID}"; rc=$?
[ "$(count '== e2e coverage matrix: .* failed ==' "${GOUT}")" -gt 0 ] \
  && ok "a full run reaches its verdict line (rc=${rc})" || bad "no verdict line — see ${GOUT}"
for m in M4 M6; do
  if [ "$(count "CAUGHT   ${m}" "${GOUT}")" -eq 0 ] && [ "$(count "SURVIVED ${m}" "${GOUT}")" -gt 0 ]; then
    ok "  ${m} with a browser-launch failure in its lane is SURVIVED, not CAUGHT"
  else
    bad "  ${m} was reported CAUGHT on a lane that only failed to launch a browser"
  fi
done
[ "$(count 'launch failures=1' "${GOUT}")" -gt 0 ] \
  && ok "  and the verdict says why (launch failures=1)" || bad "  the verdict does not name the launch failure"
[ "$(fingerprint)" = "${ORIGINAL}" ] \
  && ok "  the tree is byte-identical after a run that finished" || bad "  the tree differs after a finished run"

# ═════════════════════════════════════════════════════════════════════════════
# 5. NEGATIVE CONTROL — the old trap shape must make probe 2 go red
# ═════════════════════════════════════════════════════════════════════════════
MUT="${S}/tests/scripts/mutant.sh"
sed 's/^  exit \$((128 + num))$/  return 0/' "${S}/tests/scripts/test-e2e-coverage-matrix.sh" > "${MUT}"
if cmp -s "${MUT}" "${S}/tests/scripts/test-e2e-coverage-matrix.sh"; then
  bad "negative control: the mutation did not apply (anchor moved) — it proves nothing"
elif kill_probe "${MUT}" t5; then
  bad "negative control: a handler that RETURNS passed the kill probe — the probe cannot go red"
else
  ok "negative control: a handler that RETURNS fails the kill probe (${KILL_WHY})"
fi
# The mutant may still be running (its handler returned): stop it before reporting.
for p in $(leftovers); do kill -KILL "${p}" 2>/dev/null; done
kill -KILL "${GPID}" 2>/dev/null; wait "${GPID}" 2>/dev/null

echo "== e2e coverage matrix HARNESS: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

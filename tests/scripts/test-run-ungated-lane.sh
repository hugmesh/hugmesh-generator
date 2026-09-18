#!/usr/bin/env bash
# test-run-ungated-lane.sh — pins tests/scripts/run-ungated-lane.sh, the runner
# behind `make e2e-ungated` (hugmesh-generator#246).
#
# WHY THIS EXISTS. The runner is the ONLY thing standing between `make
# e2e-ungated` and the operator's live hugmesh-local stack, and until 2026-09-16
# nothing in the repo tested it: a skeptic pass deleted both its refusals (the
# exit-3 live-footprint refusal and the exit-4 before/after census) and every
# guard the runner's author had cited stayed green. The same pass found the
# runner failing OPEN two ways — a `docker ps` that ERRORED read as "no
# containers", and a run in which every suite skipped exited 0. All three are
# fixed in the runner; this suite is what keeps them fixed.
#
# WHAT IT ASSERTS. The runner is executed against a SYNTHETIC tree (a stub
# test-guard-integrity.sh carrying a PREMERGE_UNGATED array, stub suites that
# exit 0/1/2/7 and record that they ran) under a PATH that contains ONLY the
# tools the runner needs plus, per case, stub `docker` / `kind` binaries whose
# behaviour is set by a state directory. No real suite, no real docker, no real
# kind, no network, no cluster, nothing under tests/e2e.
#   1. selection is DERIVED from the array: all = every entry, e2e = only the
#      /test-e2e-/ entries, comments stripped, and the array's close paren is
#      honoured even when indented (an unanchored parser ran on into the NEXT
#      array and selected a suite from it — measured 2026-09-16). THE DEFAULT IS
#      `all` (decision 32c on #347, 2026-09-17: 22, not the 8 that shipped), so
#      the default selection includes the non-e2e entry and `e2e` is the opt-in.
#   2. a bogus E2E_UNGATED_SET and a guard without the array both refuse (exit 1)
#      rather than running a guessed subset
#   3. exit 0/1/2/3/other classify as PASS/FAIL/SKIP/INCOMPLETE/ERROR, a missing
#      file is an ERROR, the lane exits 1 on any FAIL/INCOMPLETE/ERROR, evidence
#      lands as run.log plus one path-named .log per suite, the non-e2e entry IS
#      run by default (32c) and is NOT run under the explicit E2E_UNGATED_SET=e2e.
#      THE INCOMPLETE BUCKET (exit 3) exists because decision 32c pulled suites
#      into the default set that use exit 3 as a documented third verdict
#      ("the suite ran and could not reach part of what it asserts"); the runner
#      used to print "ERROR … (exit 3)" for them, which reads as a crash and
#      collides with the LANE's own exit 3. It is red, and a lane whose only
#      non-green suite is INCOMPLETE still exits 1.
#   4. green+skip exits 0; E2E_UNGATED_STRICT=1 makes it 1
#   5. VACUITY FLOOR: every suite skipped exits 6, STRICT or not
#   6. a live footprint (prefix-matched container, or the kind cluster) REFUSES
#      with exit 3 BEFORE creating the evidence dir or running anything;
#      `x-hugmesh-local-y` is not a match, `hugmesh-localfoo` is. BOTH watched
#      prefixes count (decision 32a on #347): a hugmesh-real container ALONE
#      refuses, which is the case that shipped broken — a standalone
#      `hugmesh-real` compose project was invisible and a real run started the
#      suites beside it (hugmesh-generator#397). An EMPTY watch list refuses
#      (exit 1) rather than censusing nothing. The watch list is matched
#      LITERALLY: it is neither glob-expanded against the caller's working
#      directory nor used as a regex, so the rendered `[…]` label always names
#      exactly what was censused.
#   7. THERE IS NO OVERRIDE (decision 32b on #347): E2E_UNGATED_ALLOW_LIVE_STACK
#      is not read at all, so setting it beside a live footprint still refuses
#      with exit 3 and the runner's source (comment-stripped) never names it.
#      The before/after census OUTLIVED the override and now means something
#      sharper: the before-census is always empty when the lane proceeds, so a
#      non-empty after-census is a suite that BROUGHT a watched footprint up.
#      Exit 4, both censuses printed, under either watched prefix.
#   8. FAIL-CLOSED CENSUS: docker or kind present but FAILING refuses with exit
#      5, override or not, and the dry run says so; a failing after-census also
#      exits 5 (LANE UNVERIFIABLE); a box with neither tool installed proceeds
#   9. an unwritable evidence dir refuses (exit 1) instead of classifying every
#      suite FAIL without running it
#  10. E2E_UNGATED_SUITE_TIMEOUT kills a hung suite (exit 124 -> ERROR, lane 1)
#      and rejects a non-numeric value
#  12. SIGNAL TRAP (hugmesh-generator#397 item 2): a TERM delivered mid-run
#      makes the lane print "INTERRUPTED (SIGTERM)", mark its evidence directory
#      PARTIAL and exit 7, instead of dying silently with no verdict table.
#  11. the runner's source, comment-stripped, carries no teardown verb, no
#      `| grep -q`, and no two-assignment `local` (the bash 5.3 trap); the
#      Makefile target is the runner alone with no prerequisite, and no CI file
#      names `make e2e-ungated` or the runner
#
# NEGATIVE CONTROLS. The battery is re-run against MUTATED copies of the runner
# — the exit-3 refusal deleted, the exit-4 census deleted, the fail-open census
# restored, the vacuity floor removed, the default set narrowed back to e2e, the
# paren anchor loosened, the removed
# ALLOW_LIVE_STACK override reinstated, the watch list narrowed back to
# hugmesh-local alone, the empty-watch-list guard dropped, the mkdir check
# dropped, the timeout branch dropped, the INCOMPLETE bucket folded back into
# ERROR, the literal prefix match turned back into an unquoted glob + a grep
# regex, the signal trap deleted — and each mutation must make at
# least one assertion go red. A mutation that does not change the file is
# itself a failure. The real runner is never written to.
#
# OFFLINE. bash + python3 + GNU coreutils (`timeout`). Debian job image. A
# missing prerequisite exits 2 saying it checked NOTHING, never 0.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
RUNNER="${REPO}/tests/scripts/run-ungated-lane.sh"

[ -f "${RUNNER}" ] || {
  echo "  SKIPPED-LOUDLY missing input ${RUNNER} — this guard checked NOTHING"; exit 2; }
for b in python3 timeout mktemp awk sed grep sort tr head cut tail tee date mkdir rm dirname sleep; do
  command -v "${b}" >/dev/null 2>&1 || {
    echo "  SKIPPED-LOUDLY '${b}' is not on PATH — this guard checked NOTHING"; exit 2; }
done

P=0; F=0
QUIET=0
CF=0
ok()  { CP=$((CP+1)); [ "${QUIET}" = "1" ] || { echo "  PASS $*"; P=$((P+1)); }; }
bad() { CF=$((CF+1)); [ "${QUIET}" = "1" ] || { echo "  FAIL $*"; F=$((F+1)); }; }
CP=0

echo "== run-ungated-lane pin: the e2e-ungated runner refuses, classifies and censuses as documented =="

SCRATCH="$(mktemp -d -t run-ungated-lane-pin.XXXXXX)"
cleanup() { rm -rf "${SCRATCH}"; }
trap cleanup EXIT INT TERM

# ── a minimal PATH: exactly the tools the runner needs, nothing else ─────────
# Real docker/kind must NOT be reachable from the runner under test, so PATH is
# rebuilt from symlinks rather than inherited. `command -v docker` inside the
# runner then finds the stub or nothing.
MINBIN="${SCRATCH}/minbin"
mkdir -p "${MINBIN}" "${SCRATCH}/tmp"
for b in bash awk sed grep sort tr head cut tail tee date mkdir rm mktemp timeout dirname sleep cat env python3; do
  ln -s "$(command -v "${b}")" "${MINBIN}/${b}"
done

# ── the synthetic tree ───────────────────────────────────────────────────────
# write_tree <dir> <profile>   profiles: full | greenskip | allskip | single | mutator | censusdrop | sleeper
write_tree() {
  local tree
  local profile
  local entries
  tree="$1"
  profile="$2"
  rm -rf "${tree}"
  mkdir -p "${tree}/tests/scripts" "${tree}/tests/stack" "${tree}/tests/other"
  cp "${RUNNER}" "${tree}/tests/scripts/run-ungated-lane.sh"
  case "${profile}" in
    full)       entries="tests/scripts/test-e2e-green.sh tests/scripts/test-e2e-red.sh tests/scripts/test-e2e-skip.sh tests/scripts/test-e2e-crash.sh tests/scripts/test-e2e-missing.sh tests/scripts/test-e2e-incomplete.sh tests/stack/test-not-e2e.sh" ;;
    greenskip)  entries="tests/scripts/test-e2e-green.sh tests/scripts/test-e2e-skip.sh" ;;
    allskip)    entries="tests/scripts/test-e2e-skip.sh tests/scripts/test-e2e-skip2.sh" ;;
    single)     entries="tests/scripts/test-e2e-green.sh" ;;
    incomplete) entries="tests/scripts/test-e2e-green.sh tests/scripts/test-e2e-incomplete.sh" ;;
    mutator)    entries="tests/scripts/test-e2e-green.sh tests/scripts/test-e2e-mutator.sh" ;;
    censusdrop) entries="tests/scripts/test-e2e-green.sh tests/scripts/test-e2e-censusdrop.sh" ;;
    sleeper)    entries="tests/scripts/test-e2e-sleeper.sh" ;;
    *) echo "write_tree: unknown profile ${profile}" >&2; return 1 ;;
  esac
  {
    printf '%s\n' '#!/usr/bin/env bash' '# stub guard for the runner pin'
    printf '%s\n' 'OTHER_ARRAY=(' '  tests/other/test-e2e-should-not-be-selected.sh' ')'
    printf '%s\n' 'PREMERGE_UNGATED=(' '  # a comment line inside the array'
    for e in ${entries}; do printf '  %s   # why it is ungated\n' "${e}"; done
    printf '%s\n' '' '  )'   # INDENTED close paren, on purpose (assertion 1)
    printf '%s\n' 'TRAILING_ARRAY=(' '  tests/other/test-e2e-trailing.sh' ')'
  } >"${tree}/tests/scripts/test-guard-integrity.sh"
  # stub suites: each records that it ran, then exits as named
  stub() {  # stub <rel> <body>
    printf '#!/usr/bin/env bash\necho "${0##*/}" >>"${RAN_LOG}"\n%s\n' "$2" >"${tree}/$1"
  }
  stub tests/scripts/test-e2e-green.sh      'echo green; exit 0'
  stub tests/scripts/test-e2e-red.sh        'echo "  FAIL something"; exit 1'
  stub tests/scripts/test-e2e-skip.sh       'echo "SKIPPED-LOUDLY no toolchain"; exit 2'
  stub tests/scripts/test-e2e-skip2.sh      'echo "SKIPPED-LOUDLY no toolchain either"; exit 2'
  stub tests/scripts/test-e2e-crash.sh      'echo crash; exit 7'
  # exit 3 = the third documented verdict several PREMERGE_UNGATED suites use:
  # the suite RAN and could not reach part of what it asserts.
  stub tests/scripts/test-e2e-incomplete.sh 'echo "  RESULT: 30 passed, 0 failed, COMPILE SIDE NOT CHECKED (exit 3)"; exit 3'
  stub tests/stack/test-not-e2e.sh          'echo not-e2e; exit 0'
  stub tests/other/test-e2e-trailing.sh     'echo trailing; exit 0'
  stub tests/scripts/test-e2e-mutator.sh    'printf "%s\\n" hugmesh-local-evil-new hugmesh-real-evil-new >>"${STUB_STATE}/docker.names"; exit 0'
  stub tests/scripts/test-e2e-censusdrop.sh 'echo error >"${STUB_STATE}/docker.mode"; exit 0'
  stub tests/scripts/test-e2e-sleeper.sh    'sleep 5; exit 0'
  # (test-e2e-missing.sh is deliberately NOT written)
}

# ── stub docker / kind, driven by a state dir ────────────────────────────────
# docker.mode: ok | error      docker.names: one container name per line
# kind.mode:   ok | error      kind.clusters: one cluster name per line
STUBBIN="${SCRATCH}/stubbin"
mkdir -p "${STUBBIN}"
cat >"${STUBBIN}/docker" <<'SH'
#!/usr/bin/env bash
mode="$(cat "${STUB_STATE}/docker.mode" 2>/dev/null || echo ok)"
if [ "${mode}" = "error" ]; then
  echo "permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock" >&2
  exit 1
fi
cat "${STUB_STATE}/docker.names" 2>/dev/null
exit 0
SH
cat >"${STUBBIN}/kind" <<'SH'
#!/usr/bin/env bash
mode="$(cat "${STUB_STATE}/kind.mode" 2>/dev/null || echo ok)"
if [ "${mode}" = "error" ]; then
  echo "ERROR: failed to list clusters: exec: \"docker\": executable file not found" >&2
  exit 1
fi
cat "${STUB_STATE}/kind.clusters" 2>/dev/null
exit 0
SH
chmod +x "${STUBBIN}/docker" "${STUBBIN}/kind"

# run_lane <tree> <tools:none|stubs> <outfile> [VAR=value ...]  -> sets RC
# Every run gets a FRESH state dir and a FRESH log root; a case that wants a
# footprint writes the state files before calling.
STATE=""
LOGS=""
RAN=""
new_state() {
  STATE="$(mktemp -d -p "${SCRATCH}" state.XXXXXX)"
  LOGS="${SCRATCH}/logs-$(basename "${STATE}")"
  RAN="${STATE}/ran.log"
}
RC=0
# LANE_CWD: the directory the runner is invoked FROM. It matters for exactly one
# case — a watch-list entry carrying a glob metacharacter must not be expanded
# against whatever happens to be lying in the caller's cwd — so it defaults to
# the scratch root and is set deliberately where that is the point.
LANE_CWD=""
run_lane() {
  local tree
  local tools
  local out
  local path
  local cwd
  tree="$1"; tools="$2"; out="$3"; shift 3
  if [ "${tools}" = "stubs" ]; then path="${STUBBIN}:${MINBIN}"; else path="${MINBIN}"; fi
  cwd="${LANE_CWD:-${SCRATCH}}"
  RC=0
  ( cd "${cwd}" && env -i PATH="${path}" HOME="${SCRATCH}" TMPDIR="${SCRATCH}/tmp" \
      STUB_STATE="${STATE}" RAN_LOG="${RAN}" E2E_UNGATED_LOG_DIR="${LOGS}" "$@" \
      bash "${tree}/tests/scripts/run-ungated-lane.sh" ) >"${out}" 2>&1 </dev/null || RC=$?
}
# Same, in the BACKGROUND, so a case can signal the lane mid-run. Sets LANE_PID.
LANE_PID=0
run_lane_bg() {
  local tree
  local tools
  local out
  local path
  tree="$1"; tools="$2"; out="$3"; shift 3
  if [ "${tools}" = "stubs" ]; then path="${STUBBIN}:${MINBIN}"; else path="${MINBIN}"; fi
  RC=0
  env -i PATH="${path}" HOME="${SCRATCH}" TMPDIR="${SCRATCH}/tmp" \
      STUB_STATE="${STATE}" RAN_LOG="${RAN}" E2E_UNGATED_LOG_DIR="${LOGS}" "$@" \
      bash "${tree}/tests/scripts/run-ungated-lane.sh" >"${out}" 2>&1 </dev/null &
  LANE_PID=$!
}
# wait_for <file> <text> <tenths> — poll until the runner has reached a point
wait_for() {
  local f
  local txt
  local n
  local i
  f="$1"; txt="$2"; n="$3"; i=0
  while [ "${i}" -lt "${n}" ]; do
    grep -a -F -- "${txt}" "${f}" >/dev/null 2>&1 && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
has()   { grep -a -F -- "$2" "$1" >/dev/null; }
count() { grep -a -c -F -- "$2" "$1" 2>/dev/null || true; }

# ── the battery, as a function so the negative controls can re-run it ───────
# CASES=... limits which cases run (space-separated names); default all.
case_selected() { case " ${CASES:-all} " in *" all "*|*" $1 "*) return 0;; *) return 1;; esac; }

battery() {
  local T
  local O
  T="${SCRATCH}/tree-$$-${RANDOM}"

  # 1. selection ────────────────────────────────────────────────────────────
  if case_selected selection; then
    write_tree "${T}" full; new_state; O="${STATE}/dry.out"
    run_lane "${T}" none "${O}" E2E_UNGATED_DRY_RUN=1
    [ "${RC}" = "0" ] && ok "dry run exits 0" || bad "dry run exited ${RC}, expected 0"
    # DECISION 32c: with NO E2E_UNGATED_SET in the environment the selection is
    # every entry. Flip the default back to e2e and these two go red.
    has "${O}" "set   : all (7 of 7 PREMERGE_UNGATED suites)" \
      && ok "the DEFAULT selection is every entry, 7 of 7 (32c: 22, not 8)" \
      || bad "default selection wrong: $(grep -a 'set   :' "${O}")"
    has "${O}" "     tests/stack/test-not-e2e.sh" \
      && ok "the default selection includes the non-e2e entry (32c)" \
      || bad "the default selection excluded the non-e2e entry"
    for s in green red skip crash missing incomplete; do
      has "${O}" "     tests/scripts/test-e2e-${s}.sh" && ok "dry run lists test-e2e-${s}.sh" || bad "dry run does not list test-e2e-${s}.sh"
    done
    has "${O}" "test-e2e-trailing.sh" && bad "parser ran past the INDENTED close paren into TRAILING_ARRAY" || ok "the indented close paren ends the array (TRAILING_ARRAY not read)"
    has "${O}" "should-not-be-selected" && bad "parser picked up an entry from the array BEFORE PREMERGE_UNGATED" || ok "the preceding array is not read"
    has "${O}" "live footprint [hugmesh-local, hugmesh-real]: none — a real run would proceed" && ok "dry run with no docker/kind on PATH reports no footprint, naming BOTH watched prefixes" || bad "dry run footprint line wrong: $(grep -a footprint "${O}")"
    [ -e "${RAN}" ] && bad "dry run EXECUTED a suite" || ok "dry run executed nothing"
    [ -e "${LOGS}" ] && bad "dry run created the evidence dir" || ok "dry run created no evidence dir"
    new_state; O="${STATE}/dry-e2e.out"
    run_lane "${T}" none "${O}" E2E_UNGATED_DRY_RUN=1 E2E_UNGATED_SET=e2e
    has "${O}" "set   : e2e (6 of 7 PREMERGE_UNGATED suites)" \
      && ok "the explicit e2e opt-in is 6 of 7 (the /test-e2e-/ entries, comments stripped)" \
      || bad "e2e selection count wrong: $(grep -a 'set   :' "${O}")"
    has "${O}" "test-not-e2e.sh" && bad "the e2e opt-in swept in the non-e2e entry" || ok "the e2e opt-in excludes tests/stack/test-not-e2e.sh"
    new_state; O="${STATE}/dryall.out"
    run_lane "${T}" none "${O}" E2E_UNGATED_DRY_RUN=1 E2E_UNGATED_SET=all
    has "${O}" "set   : all (7 of 7 PREMERGE_UNGATED suites)" && has "${O}" "tests/stack/test-not-e2e.sh" \
      && ok "an explicit SET=all selects every entry including the non-e2e one" || bad "SET=all selection wrong: $(grep -a 'set   :' "${O}")"
    new_state; O="${STATE}/bogus.out"
    run_lane "${T}" none "${O}" E2E_UNGATED_SET=bogus
    [ "${RC}" = "1" ] && has "${O}" "REFUSED" && ok "a bogus E2E_UNGATED_SET refuses with exit 1" || bad "bogus set: rc ${RC}"
    printf '#!/usr/bin/env bash\nNOT_THE_ARRAY=(\n  x\n)\n' >"${T}/tests/scripts/test-guard-integrity.sh"
    new_state; O="${STATE}/noarray.out"
    run_lane "${T}" none "${O}"
    [ "${RC}" = "1" ] && has "${O}" "parsed ZERO entries" && ok "a guard without PREMERGE_UNGATED refuses with exit 1 (no guessed subset)" || bad "no-array: rc ${RC}"
    [ -e "${RAN}" ] && bad "no-array run EXECUTED a suite" || ok "no-array run executed nothing"
  fi

  # 3. classification + evidence ───────────────────────────────────────────
  if case_selected classify; then
    write_tree "${T}" full; new_state; O="${STATE}/full.out"
    run_lane "${T}" none "${O}"
    [ "${RC}" = "1" ] && ok "a lane with a FAIL and ERRORs exits 1" || bad "full lane rc ${RC}, expected 1"
    has "${O}" "PASS   tests/scripts/test-e2e-green.sh"  && ok "exit 0 -> PASS"  || bad "green not PASS"
    has "${O}" "FAIL   tests/scripts/test-e2e-red.sh"    && ok "exit 1 -> FAIL"  || bad "red not FAIL"
    has "${O}" "SKIP   tests/scripts/test-e2e-skip.sh"   && ok "exit 2 -> SKIP"  || bad "skip not SKIP"
    has "${O}" "ERROR  tests/scripts/test-e2e-crash.sh   (exit 7)" && ok "exit 7 -> ERROR (exit 7)" || bad "crash not ERROR"
    # exit 3 is INCOMPLETE, not ERROR: the suite ran and reported a documented
    # partial verdict. Fold the bucket back into ERROR and these two go red.
    has "${O}" "INCOMPLETE tests/scripts/test-e2e-incomplete.sh   (exit 3:" \
      && ok "exit 3 -> INCOMPLETE (not ERROR, and not the lane's own exit-3 refusal)" \
      || bad "exit 3 not INCOMPLETE: $(grep -a 'test-e2e-incomplete' "${O}" | head -n 1)"
    has "${O}" "ERROR  tests/scripts/test-e2e-incomplete.sh" && bad "an exit-3 suite is still classified ERROR" || ok "an exit-3 suite is not classified ERROR"
    has "${O}" "ERROR  tests/scripts/test-e2e-missing.sh  (no such file" && ok "a missing suite -> ERROR (no such file)" || bad "missing not ERROR"
    has "${O}" "PASS   tests/stack/test-not-e2e.sh" && ok "the non-e2e entry RUNS in the default set (32c)" || bad "the non-e2e entry did not run by default"
    has "${O}" "== RESULT: 2 passed, 1 failed, 1 skipped, 1 incomplete, 2 errored (of 7) ==" && ok "RESULT line counts 2/1/1/1/2 of 7, incomplete counted separately" || bad "RESULT line wrong: $(grep -a 'RESULT' "${O}")"
    grep -a -E '^ *\| +FAIL something' "${O}" >/dev/null && ok "a red suite's tail is inlined" || bad "red tail not inlined"
    [ -e "${RAN}" ] && grep -a -x 'test-e2e-green.sh' "${RAN}" >/dev/null && grep -a -x 'test-e2e-crash.sh' "${RAN}" >/dev/null \
      && ok "the stub suites really ran (ran.log)" || bad "ran.log missing green/crash"
    grep -a 'test-not-e2e' "${RAN}" >/dev/null && ok "ran.log confirms the non-e2e entry really ran by default (32c)" || bad "the non-e2e entry did not run by default"
    local d
    d="$(ls -d "${LOGS}"/*/ 2>/dev/null | head -n1)"
    [ -n "${d}" ] && [ -f "${d}/run.log" ] && ok "evidence dir exists with run.log" || bad "no evidence dir / run.log under ${LOGS}"
    [ -n "${d}" ] && [ -f "${d}/tests_scripts_test-e2e-green.log" ] && [ -f "${d}/tests_scripts_test-e2e-red.log" ] \
      && ok "per-suite logs are named from the full path (tests_scripts_test-e2e-green.log)" || bad "per-suite logs missing or misnamed: $(ls "${d}" 2>/dev/null | tr '\n' ' ')"
    [ -n "${d}" ] && grep -a 'FAIL   tests/scripts/test-e2e-red.sh' "${d}/run.log" >/dev/null && ok "run.log carries the verdicts" || bad "run.log lacks the verdicts"
    has "${O}" "studio python: python3 (SNAP_STUDIO_PYTHON unset" && ok "the header names the Studio interpreter it ran with (unset)" || bad "no studio python line"
    new_state; O="${STATE}/e2eonly.out"
    run_lane "${T}" none "${O}" E2E_UNGATED_SET=e2e
    has "${O}" "== RESULT: 1 passed, 1 failed, 1 skipped, 1 incomplete, 2 errored (of 6) ==" && ok "the explicit e2e opt-in still runs only its 6" || bad "e2e opt-in RESULT wrong: $(grep -a 'RESULT' "${O}")"
    grep -a 'test-not-e2e' "${RAN}" >/dev/null && bad "the non-e2e entry was RUN under E2E_UNGATED_SET=e2e" || ok "the non-e2e entry is not run under the e2e opt-in"
    new_state; O="${STATE}/snap.out"
    run_lane "${T}" none "${O}" SNAP_STUDIO_PYTHON=/opt/venv/bin/python
    has "${O}" "studio python: /opt/venv/bin/python" && ok "SNAP_STUDIO_PYTHON is printed when set" || bad "SNAP_STUDIO_PYTHON not echoed"
  fi

  # 3b. an INCOMPLETE suite is red ON ITS OWN ──────────────────────────────
  # The point of the bucket is that it is NOT a SKIP: a lane whose only
  # non-green suite ran and could not finish what it asserts is red, and STRICT
  # has nothing to do with it.
  if case_selected incomplete; then
    write_tree "${T}" incomplete; new_state; O="${STATE}/inc.out"
    run_lane "${T}" none "${O}"
    [ "${RC}" = "1" ] && ok "green + INCOMPLETE exits 1 (an exit-3 suite is red, not tolerated like a skip)" \
      || bad "green+incomplete rc ${RC}, expected 1"
    has "${O}" "INCOMPLETE tests/scripts/test-e2e-incomplete.sh" \
      && ok "the verdict table names it INCOMPLETE" || bad "no INCOMPLETE verdict line: $(grep -a 'incomplete' "${O}" | head -n 1)"
    has "${O}" "1 incomplete" && ok "the RESULT line counts it as incomplete, not as errored" || bad "RESULT line does not count incomplete: $(grep -a 'RESULT' "${O}")"
    grep -a -E '^ *\| +RESULT: 30 passed' "${O}" >/dev/null && ok "an INCOMPLETE suite's tail is inlined like a red one" || bad "incomplete tail not inlined"
    new_state; O="${STATE}/inc-strict0.out"
    run_lane "${T}" none "${O}" E2E_UNGATED_STRICT=0
    [ "${RC}" = "1" ] && ok "STRICT=0 does not make an INCOMPLETE tolerable" || bad "incomplete under STRICT=0: rc ${RC}, expected 1"
  fi

  # 4/5. skips, strict, vacuity ────────────────────────────────────────────
  if case_selected skips; then
    write_tree "${T}" greenskip; new_state; O="${STATE}/gs.out"
    run_lane "${T}" none "${O}"
    [ "${RC}" = "0" ] && ok "green + skip exits 0 (skips tolerated)" || bad "green+skip rc ${RC}"
    new_state; O="${STATE}/gs-strict.out"
    run_lane "${T}" none "${O}" E2E_UNGATED_STRICT=1
    [ "${RC}" = "1" ] && has "${O}" "E2E_UNGATED_STRICT=1 and 1 suite(s) skipped" && ok "green + skip exits 1 under STRICT=1" || bad "strict rc ${RC}"
  fi
  if case_selected vacuous; then
    write_tree "${T}" allskip; new_state; O="${STATE}/allskip.out"
    run_lane "${T}" none "${O}"
    [ "${RC}" = "6" ] && has "${O}" "VACUOUS: 2 suite(s) were selected and NOT ONE passed" \
      && ok "every suite skipped -> exit 6 VACUOUS (not green), STRICT unset" || bad "all-skip rc ${RC} (expected 6): $(grep -a 'RESULT\|VACUOUS' "${O}" | tr '\n' ' ')"
    new_state; O="${STATE}/allskip-strict.out"
    run_lane "${T}" none "${O}" E2E_UNGATED_STRICT=1
    [ "${RC}" != "0" ] && ok "every suite skipped under STRICT=1 is non-zero (${RC})" || bad "all-skip STRICT rc 0"
  fi

  # 6. refusal on a live footprint ────────────────────────────────────────
  if case_selected refuse; then
    write_tree "${T}" full; new_state
    printf '%s\n' hugmesh-local-control-plane other-thing x-hugmesh-local-y hugmesh-localfoo hugmesh-real-casdoor-1 >"${STATE}/docker.names"
    printf '%s\n' hugmesh-local >"${STATE}/kind.clusters"
    O="${STATE}/refuse.out"
    run_lane "${T}" stubs "${O}"
    [ "${RC}" = "3" ] && ok "a live hugmesh-local footprint refuses with exit 3" || bad "footprint present: rc ${RC}, expected 3"
    has "${O}" "REFUSED: a live footprint [hugmesh-local, hugmesh-real] is up on this box" && ok "refusal names itself and BOTH watched prefixes" || bad "no refusal banner: $(head -n 1 "${O}")"
    has "${O}" "  hugmesh-real-casdoor-1" && ok "a hugmesh-real container is listed alongside the hugmesh-local ones" || bad "hugmesh-real container not listed"
    has "${O}" "  hugmesh-local-control-plane" && has "${O}" "  kind-cluster:hugmesh-local" && ok "refusal lists the container AND the kind cluster" || bad "refusal listing incomplete"
    has "${O}" "  hugmesh-localfoo" && ok "prefix match: hugmesh-localfoo counts" || bad "hugmesh-localfoo not counted"
    has "${O}" "x-hugmesh-local-y" && bad "x-hugmesh-local-y counted (not a prefix match)" || ok "x-hugmesh-local-y is not a prefix match"
    has "${O}" "other-thing" && bad "an unrelated container was listed" || ok "unrelated containers are not listed"
    has "${O}" "no ungated suite starts a stack" && bad "the refusal still repeats the FALSE 'no suite starts a stack' claim" || ok "the refusal text does not claim that no suite starts anything"
    has "${O}" "e2eguard-m7" && ok "the refusal tells the truth about the one throwaway container" || bad "the refusal does not mention the M7 stand-in"
    [ -e "${RAN}" ] && bad "a suite RAN despite the refusal" || ok "nothing ran under the refusal"
    [ -e "${LOGS}" ] && bad "the refusal created the evidence dir" || ok "the refusal created no evidence dir"
    O="${STATE}/refuse-dry.out"
    run_lane "${T}" stubs "${O}" E2E_UNGATED_DRY_RUN=1
    [ "${RC}" = "0" ] && has "${O}" "PRESENT — a real run would REFUSE (exit 3)" && ok "dry run reports the footprint and the refusal it would make" || bad "dry run with footprint: rc ${RC}"
    # DECISION 32a REGRESSION CASE. A standalone hugmesh-real compose project
    # and NOTHING hugmesh-local. This is the exact state that shipped broken:
    # the dry run said "none — a real run would proceed" and a real invocation
    # started the suites. Narrow the watch list back to hugmesh-local and these
    # four assertions go red.
    new_state
    printf '%s\n' hugmesh-real-casdoor-1 hugmesh-real-tuwunel-1 other-thing >"${STATE}/docker.names"
    : >"${STATE}/kind.clusters"
    O="${STATE}/realonly.out"
    run_lane "${T}" stubs "${O}"
    [ "${RC}" = "3" ] && ok "a hugmesh-real footprint ALONE refuses with exit 3 (32a)" || bad "hugmesh-real alone: rc ${RC}, expected 3"
    has "${O}" "  hugmesh-real-casdoor-1" && has "${O}" "  hugmesh-real-tuwunel-1" && ok "the refusal lists the hugmesh-real containers" || bad "hugmesh-real containers not listed"
    [ -e "${RAN}" ] && bad "a suite RAN beside a standalone hugmesh-real project" || ok "nothing ran beside a standalone hugmesh-real project"
    O="${STATE}/realonly-dry.out"
    run_lane "${T}" stubs "${O}" E2E_UNGATED_DRY_RUN=1
    has "${O}" "PRESENT — a real run would REFUSE (exit 3)" && ok "the dry run sees the hugmesh-real project (it said 'none' before 32a)" || bad "dry run blind to hugmesh-real: $(grep -a footprint "${O}")"
    # an EMPTY watch list must refuse, not census nothing
    new_state; printf '%s\n' hugmesh-local-control-plane >"${STATE}/docker.names"; : >"${STATE}/kind.clusters"
    O="${STATE}/emptyprefix.out"
    run_lane "${T}" stubs "${O}" E2E_UNGATED_LIVE_PREFIX=" "
    if [ "${RC}" = "1" ] && has "${O}" "E2E_UNGATED_LIVE_PREFIX is empty"; then
      ok "an empty watch list refuses (exit 1) instead of censusing nothing"
    else
      # BOTH halves are reported: "rc 1, expected 1" alone reads as
      # self-contradictory when it is the refusal TEXT that went missing.
      bad "empty prefix: rc ${RC} (expected 1), refusal text $(has "${O}" "E2E_UNGATED_LIVE_PREFIX is empty" && echo present || echo MISSING)"
    fi
    [ -e "${RAN}" ] && bad "a suite ran under an empty watch list" || ok "nothing ran under an empty watch list"
    # kind cluster alone
    new_state; : >"${STATE}/docker.names"; printf '%s\n' hugmesh-local >"${STATE}/kind.clusters"; O="${STATE}/kindonly.out"
    run_lane "${T}" stubs "${O}"
    [ "${RC}" = "3" ] && has "${O}" "kind-cluster:hugmesh-local" && ok "the kind cluster alone is a footprint" || bad "kind-only: rc ${RC}"
    # neither: proceeds
    new_state; : >"${STATE}/docker.names"; : >"${STATE}/kind.clusters"; O="${STATE}/clear.out"
    run_lane "${T}" stubs "${O}"
    [ "${RC}" = "1" ] && has "${O}" "live stack   : none detected" && ok "docker+kind present and EMPTY -> proceeds (rc from the suites)" || bad "clear footprint: rc ${RC}"
  fi

  # 6b. the watch list is matched LITERALLY ────────────────────────────────
  # Two shapes, both measured on the real runner before the fix:
  #   (a) an unquoted `for pfx in ${LIVE_PREFIX}` glob-expands the watch list
  #       against the CALLER's working directory, so the rendered [..] label
  #       stops describing what was censused;
  #   (b) `grep "^${pfx}"` treats the prefix as a REGEX, so a `.` matches any
  #       character.
  # Neither is reachable with the default prefixes, which is exactly why a
  # control is needed: nothing else in this battery would notice.
  if case_selected literal; then
    write_tree "${T}" single; new_state
    # (a) a cwd carrying a file whose name is a PREFIX of a live container
    local GD
    GD="${STATE}/globdir"
    mkdir -p "${GD}"
    : >"${GD}/zz-victim"
    printf '%s\n' zz-victim-1 >"${STATE}/docker.names"; : >"${STATE}/kind.clusters"
    O="${STATE}/glob.out"
    LANE_CWD="${GD}"
    run_lane "${T}" stubs "${O}" E2E_UNGATED_LIVE_PREFIX="zz*"
    LANE_CWD=""
    [ "${RC}" != "3" ] \
      && ok "the watch list is not glob-expanded against the caller's cwd (a 'zz*' entry did not become the file 'zz-victim')" \
      || bad "the watch list was glob-expanded: rc 3 on a container the literal prefix 'zz*' does not match"
    has "${O}" "live stack   : none detected (no zz* container or kind cluster)" \
      && ok "the banner names the watch list exactly as given" || bad "banner label wrong: $(grep -a 'live stack' "${O}" | head -n 1)"
    O="${STATE}/glob-dry.out"
    LANE_CWD="${GD}"
    run_lane "${T}" stubs "${O}" E2E_UNGATED_LIVE_PREFIX="zz*" E2E_UNGATED_DRY_RUN=1
    LANE_CWD=""
    has "${O}" "live footprint [zz*]: none" \
      && ok "the dry run renders the watch list as given and censuses the same thing" \
      || bad "dry-run label wrong: $(grep -a footprint "${O}" | head -n 1)"
    # (b) a '.' in a prefix must be a dot, not 'any character'
    new_state
    printf '%s\n' hugmeshXlocal-1 >"${STATE}/docker.names"; : >"${STATE}/kind.clusters"
    O="${STATE}/regex.out"
    run_lane "${T}" stubs "${O}" E2E_UNGATED_LIVE_PREFIX="hugmesh.local"
    [ "${RC}" != "3" ] \
      && ok "a '.' in a watch-list entry is a literal dot, not a regex wildcard" \
      || bad "the watch list was used as a REGEX: 'hugmesh.local' matched hugmeshXlocal-1"
    # and the literal form still matches what it should
    new_state
    printf '%s\n' hugmesh.local-1 other >"${STATE}/docker.names"; : >"${STATE}/kind.clusters"
    O="${STATE}/regex2.out"
    run_lane "${T}" stubs "${O}" E2E_UNGATED_LIVE_PREFIX="hugmesh.local"
    [ "${RC}" = "3" ] && has "${O}" "  hugmesh.local-1" \
      && ok "the literal prefix still matches the container it names" || bad "literal prefix missed its own container: rc ${RC}"
  fi

  # 7. NO override, and the after-census that outlived it ──────────────────
  if case_selected aftercensus; then
    # DECISION 32b. The variable is gone. Setting it beside a live footprint
    # must still refuse — reinstate the override and these two go red.
    write_tree "${T}" single; new_state
    printf '%s\n' hugmesh-local-control-plane >"${STATE}/docker.names"; : >"${STATE}/kind.clusters"
    O="${STATE}/ov.out"
    run_lane "${T}" stubs "${O}" E2E_UNGATED_ALLOW_LIVE_STACK=1
    [ "${RC}" = "3" ] && ok "E2E_UNGATED_ALLOW_LIVE_STACK=1 does NOT let the lane run beside a footprint (32b: the override is gone)" || bad "ALLOW_LIVE_STACK=1 beside a footprint: rc ${RC}, expected 3"
    has "${O}" "THERE IS NO OVERRIDE" && ok "the refusal says plainly that there is no override" || bad "the refusal still offers an escape hatch"
    has "${O}" "E2E_UNGATED_ALLOW_LIVE_STACK=1 make e2e-ungated" && bad "the refusal still advertises the removed override" || ok "the refusal no longer advertises the removed override"
    [ -e "${RAN}" ] && bad "a suite RAN with ALLOW_LIVE_STACK=1 beside a footprint" || ok "nothing ran with ALLOW_LIVE_STACK=1 beside a footprint"
    # the before/after census, on an EMPTY before — a suite brings a watched
    # footprint UP mid-run, under either prefix
    write_tree "${T}" mutator; new_state
    : >"${STATE}/docker.names"; : >"${STATE}/kind.clusters"
    O="${STATE}/moved.out"
    run_lane "${T}" stubs "${O}"
    [ "${RC}" = "4" ] && ok "a suite that BRINGS a watched footprint up mid-run -> exit 4" || bad "footprint arrived mid-run: rc ${RC}, expected 4"
    has "${O}" "LANE VIOLATION" && has "${O}" "after : hugmesh-local-evil-new hugmesh-real-evil-new" \
      && ok "the violation prints both censuses, and the AFTER census watches both prefixes" || bad "violation censuses missing: $(grep -a 'before:\|after :' "${O}" | tr '\n' ' ')"
    has "${O}" "before-census was EMPTY" && ok "the violation says the before-census was empty (no override to blame)" || bad "the violation still blames an override"
  fi

  # 8. fail-closed census ─────────────────────────────────────────────────
  if case_selected census; then
    write_tree "${T}" single; new_state
    echo error >"${STATE}/docker.mode"; : >"${STATE}/kind.clusters"
    O="${STATE}/derr.out"
    run_lane "${T}" stubs "${O}"
    [ "${RC}" = "5" ] && ok "docker present but FAILING -> exit 5 (not 'none detected')" || bad "docker error: rc ${RC}, expected 5"
    has "${O}" "could not be determined" && has "${O}" "docker ps failed: permission denied" && ok "the refusal quotes docker's error" || bad "census error text missing"
    has "${O}" "none detected" && bad "a failing census was reported as none detected" || ok "no 'none detected' on a failing census"
    [ -e "${RAN}" ] && bad "a suite RAN on an undeterminable footprint" || ok "nothing ran on an undeterminable footprint"
    O="${STATE}/derr-ov.out"
    run_lane "${T}" stubs "${O}" E2E_UNGATED_ALLOW_LIVE_STACK=1
    [ "${RC}" = "5" ] && ok "a stray E2E_UNGATED_ALLOW_LIVE_STACK=1 does not bypass exit 5 (32b: it is not read at all)" || bad "ALLOW_LIVE_STACK=1 bypassed the census error: rc ${RC}"
    O="${STATE}/derr-dry.out"
    run_lane "${T}" stubs "${O}" E2E_UNGATED_DRY_RUN=1
    has "${O}" "UNDETERMINABLE — a real run would REFUSE (exit 5)" && ok "dry run reports UNDETERMINABLE" || bad "dry run on a failing census: $(grep -a footprint "${O}")"
    new_state; : >"${STATE}/docker.names"; echo error >"${STATE}/kind.mode"; O="${STATE}/kerr.out"
    run_lane "${T}" stubs "${O}"
    [ "${RC}" = "5" ] && has "${O}" "kind get clusters failed" && ok "kind present but FAILING -> exit 5" || bad "kind error: rc ${RC}"
    write_tree "${T}" censusdrop; new_state; : >"${STATE}/docker.names"; : >"${STATE}/kind.clusters"; O="${STATE}/after.out"
    run_lane "${T}" stubs "${O}"
    [ "${RC}" = "5" ] && has "${O}" "LANE UNVERIFIABLE" && ok "a failing AFTER-census -> exit 5 LANE UNVERIFIABLE" || bad "after-census error: rc ${RC}"
  fi

  # 9. unwritable evidence dir ─────────────────────────────────────────────
  if case_selected mkdir; then
    write_tree "${T}" single; new_state
    : >"${STATE}/afile"; LOGS="${STATE}/afile/sub"; O="${STATE}/mkdir.out"
    run_lane "${T}" none "${O}"
    [ "${RC}" = "1" ] && has "${O}" "cannot create the evidence directory" && ok "an unwritable evidence dir refuses (exit 1) before running anything" || bad "mkdir failure: rc ${RC}: $(tail -n 3 "${O}" | tr '\n' ' ')"
    has "${O}" "== RESULT:" && bad "suites were classified despite the unwritable evidence dir" || ok "no verdict table on an unwritable evidence dir"
    [ -e "${RAN}" ] && bad "a suite ran despite the unwritable evidence dir" || ok "nothing ran on an unwritable evidence dir"
  fi

  # 10. per-suite timeout ─────────────────────────────────────────────────
  if case_selected timeout; then
    write_tree "${T}" sleeper; new_state; O="${STATE}/to.out"
    run_lane "${T}" none "${O}" E2E_UNGATED_SUITE_TIMEOUT=1
    [ "${RC}" = "1" ] && has "${O}" "(exit 124: killed at the 1s suite timeout)" && ok "a hung suite is killed at the timeout and counted as ERROR (lane 1)" || bad "timeout: rc ${RC}: $(grep -a 'sleeper' "${O}" | head -n 2 | tr '\n' ' ')"
    new_state; O="${STATE}/to-bad.out"
    run_lane "${T}" none "${O}" E2E_UNGATED_SUITE_TIMEOUT=soon
    [ "${RC}" = "1" ] && has "${O}" "must be a whole number" && ok "a non-numeric timeout refuses" || bad "bad timeout value: rc ${RC}"
  fi

  # 12. the signal trap (hugmesh-generator#397, item 2) ────────────────────
  # Before this the lane died where it stood: no verdict table, an evidence
  # directory that looked complete. The suite is given a 1s timeout so the
  # pending trap is acted on quickly — bash runs a trap only when the FOREGROUND
  # command returns, which is itself part of what is documented.
  if case_selected signal; then
    write_tree "${T}" sleeper; new_state; O="${STATE}/sig.out"
    run_lane_bg "${T}" none "${O}" E2E_UNGATED_SUITE_TIMEOUT=1
    if wait_for "${O}" "---- tests/scripts/test-e2e-sleeper.sh ----" 100; then
      kill -TERM "${LANE_PID}" 2>/dev/null
      RC=0; wait "${LANE_PID}" || RC=$?
      [ "${RC}" = "7" ] && ok "a TERM mid-run exits 7 (not a silent death)" || bad "TERM mid-run: rc ${RC}, expected 7"
      has "${O}" "== INTERRUPTED (SIGTERM) ==" && ok "the interrupt names itself and the signal" || bad "no INTERRUPTED banner: $(tail -n 3 "${O}" | tr '\n' ' ')"
      has "${O}" "(PARTIAL — the lane did not finish)" && ok "the evidence directory is marked PARTIAL" || bad "the evidence dir is not marked PARTIAL"
      has "${O}" "Nothing was torn down" && ok "the interrupt says plainly that it tore nothing down" || bad "the interrupt does not say it tore nothing down"
      has "${O}" "casdoor-jwtcustom-test" && ok "the interrupt warns about the fixed-name containers a signalled run can strand" || bad "the interrupt does not warn about the casdoor containers"
      local sd
      sd="$(ls -d "${LOGS}"/*/ 2>/dev/null | head -n1)"
      [ -n "${sd}" ] && grep -a -F "INTERRUPTED" "${sd}/run.log" >/dev/null \
        && ok "run.log carries the interruption (the evidence dir is not silently partial)" \
        || bad "run.log does not record the interruption"
    else
      bad "the lane never reached the sleeper suite — the signal case asserted NOTHING"
      kill -TERM "${LANE_PID}" 2>/dev/null || true
      wait "${LANE_PID}" 2>/dev/null || true
    fi
  fi

  # 11. source sweeps ─────────────────────────────────────────────────────
  if case_selected source; then
    local src
    src="$(sed -e 's/#.*$//' "${T}/tests/scripts/run-ungated-lane.sh")"
    printf '%s\n' "${src}" | grep -aE 'docker +(stop|rm|kill)|kind +delete|stack-down|stack-halt|compose +down' >/dev/null \
      && bad "the runner carries a teardown verb" || ok "no teardown verb in the runner (comment-stripped)"
    printf '%s\n' "${src}" | grep -aE '\| *grep +-[a-zA-Z]*q' >/dev/null && bad "the runner pipes into grep -q" || ok "no '| grep -q' in the runner"
    printf '%s\n' "${src}" | grep -aE '^[[:space:]]*local [a-zA-Z_]+=[^ ]* +[a-zA-Z_]+=' >/dev/null && bad "a two-assignment 'local' (bash 5.3 set -u trap)" || ok "every 'local' declares one name (bash 5.3 trap absent)"
    printf '%s\n' "${src}" | grep -a 'CENSUS-ERROR' >/dev/null && ok "the census emits CENSUS-ERROR lines (fail-closed path present)" || bad "no CENSUS-ERROR path in the runner"
    printf '%s\n' "${src}" | grep -aE 'for pfx in \$\{LIVE_PREFIX\}' >/dev/null \
      && bad "the runner still iterates an UNQUOTED \${LIVE_PREFIX} (pathname expansion)" \
      || ok "no unquoted \${LIVE_PREFIX} iteration in the runner (the watch list cannot glob)"
    printf '%s\n' "${src}" | grep -a "trap 'on_signal" >/dev/null \
      && ok "the runner installs a signal trap (#397 item 2)" || bad "the runner installs no signal trap"
    printf '%s\n' "${src}" | grep -a 'E2E_UNGATED_ALLOW_LIVE_STACK' >/dev/null \
      && bad "the runner still READS E2E_UNGATED_ALLOW_LIVE_STACK (32b: it was removed)" \
      || ok "the runner never reads E2E_UNGATED_ALLOW_LIVE_STACK (comment-stripped; 32b)"
  fi
}

# ── run the battery for real ─────────────────────────────────────────────────
battery

# ── the Makefile / CI shape ──────────────────────────────────────────────────
MK="${REPO}/Makefile"
if [ -f "${MK}" ]; then
  grep -a '^e2e-ungated:' "${MK}" | grep -a -v '^e2e-ungated: *##' >/dev/null && bad "e2e-ungated has a prerequisite" || ok "e2e-ungated has no prerequisite"
  awk '/^e2e-ungated:/{f=1;next} f&&/^\t/{print;exit}' "${MK}" | grep -a -x $'\tbash tests/scripts/run-ungated-lane.sh' >/dev/null \
    && ok "the e2e-ungated recipe is the runner alone" || bad "the e2e-ungated recipe is not 'bash tests/scripts/run-ungated-lane.sh'"
  grep -a -v '^\.PHONY' "${MK}" | grep -a -E '^[a-zA-Z0-9_.-]+:.*[[:space:]]e2e-ungated([[:space:]]|$)' >/dev/null && bad "another target lists e2e-ungated as a prerequisite" || ok "no target depends on e2e-ungated"
else
  bad "Makefile not found"
fi
CI_HITS="$(grep -a -l -E 'make e2e-ungated|scripts/run-ungated-lane\.sh' "${REPO}"/.github/workflows/*.yml "${REPO}/.gitlab-ci.yml" 2>/dev/null | grep -a -v '^$' || true)"
[ -z "${CI_HITS}" ] && ok "no CI file invokes make e2e-ungated or the runner" || bad "a CI file names the lane: ${CI_HITS}"

# ── negative controls: mutate the RUNNER COPY, expect a red ─────────────────
MC=0; MS=0
mutate() {  # mutate <label> <cases> <python-source-transform>
  local label
  local cases
  local py
  local before
  local after
  label="$1"; cases="$2"; py="$3"
  MUT_RUNNER="${SCRATCH}/mutant.sh"
  cp "${RUNNER}" "${MUT_RUNNER}"
  before="$(cksum <"${MUT_RUNNER}")"
  MUT_FILE="${MUT_RUNNER}" python3 -c "${py}" || { bad "mutation '${label}' could not be applied"; MS=$((MS+1)); return; }
  after="$(cksum <"${MUT_RUNNER}")"
  if [ "${before}" = "${after}" ]; then
    bad "mutation '${label}' did NOT change the runner — the control proves nothing"; MS=$((MS+1)); return
  fi
  # run the named cases against the mutant, quietly
  local saved
  saved="${RUNNER}"
  RUNNER="${MUT_RUNNER}"
  QUIET=1; CF=0; CP=0; CASES="${cases}"
  battery
  QUIET=0; CASES="all"
  RUNNER="${saved}"
  if [ "${CF}" -gt 0 ]; then
    echo "  caught    mutation: ${label} (${CF} assertion(s) went red)"; MC=$((MC+1))
  else
    echo "  SURVIVED  mutation: ${label} — nothing went red"; MS=$((MS+1))
  fi
}
PYHDR='import os,re,sys
p=os.environ["MUT_FILE"]; s=open(p,encoding="utf-8").read(); o=s
'
PYFTR='
open(p,"w",encoding="utf-8").write(s)'

mutate "the exit-3 live-footprint refusal is deleted" "refuse" "${PYHDR}"'
s=re.sub(r"\nif \[ -n \"\$\{FOOTPRINT_BEFORE\}\" \]; then\n.*?\n  exit 3\nfi\n", "\n", s, count=1, flags=re.S)'"${PYFTR}"

mutate "the exit-4 before/after census is deleted" "aftercensus" "${PYHDR}"'
s=re.sub(r"\nif \[ \"\$\{FOOTPRINT_BEFORE\}\" != \"\$\{FOOTPRINT_AFTER\}\" \]; then\n.*?\n  exit 4\nfi\n", "\n", s, count=1, flags=re.S)'"${PYFTR}"

mutate "the census fails OPEN again (docker error read as empty)" "census" "${PYHDR}"'
s=s.replace("errs=\"${errs}CENSUS-ERROR docker ps failed", ": # errs=\"${errs}CENSUS-ERROR docker ps failed", 1)'"${PYFTR}"

mutate "the vacuity floor (exit 6) is removed" "vacuous" "${PYHDR}"'
s=re.sub(r"\nif \[ \"\$\{PASS\}\" -eq 0 \]; then\n.*?\n  exit 6\nfi\n", "\n", s, count=1, flags=re.S)'"${PYFTR}"

mutate "the array close-paren anchor is loosened to column 0" "selection" "${PYHDR}"'
s=s.replace("/^[[:space:]]*\\)[[:space:]]*$/{f=0}", "/^\\)/{f=0}", 1)'"${PYFTR}"

mutate "the default set narrows back to e2e (32c reverted)" "selection classify" "${PYHDR}"'
s=s.replace("UNGATED_DEFAULT_SET=\"all\"", "UNGATED_DEFAULT_SET=\"e2e\"", 1)'"${PYFTR}"

mutate "the E2E_UNGATED_ALLOW_LIVE_STACK override is reinstated (32b reverted)" "aftercensus" "${PYHDR}"'
s=s.replace("LIVE_PREFIX=\"${E2E_UNGATED_LIVE_PREFIX:-${UNGATED_DEFAULT_LIVE_PREFIXES}}\"",
            "LIVE_PREFIX=\"${E2E_UNGATED_LIVE_PREFIX:-${UNGATED_DEFAULT_LIVE_PREFIXES}}\"\nALLOW_LIVE=\"${E2E_UNGATED_ALLOW_LIVE_STACK:-0}\"", 1)
s=s.replace("if [ -n \"${FOOTPRINT_BEFORE}\" ]; then\n  printf",
            "if [ -n \"${FOOTPRINT_BEFORE}\" ] && [ \"${ALLOW_LIVE}\" != \"1\" ]; then\n  printf", 1)'"${PYFTR}"

mutate "the watch list narrows back to hugmesh-local alone (32a reverted)" "refuse" "${PYHDR}"'
s=s.replace("UNGATED_DEFAULT_LIVE_PREFIXES=\"hugmesh-local hugmesh-real\"", "UNGATED_DEFAULT_LIVE_PREFIXES=\"hugmesh-local\"", 1)'"${PYFTR}"

mutate "the empty-watch-list guard is dropped (census fails open)" "refuse" "${PYHDR}"'
s=re.sub(r"\nif \[ -z \"\$\(printf .%s. \"\$\{LIVE_PREFIX\}\" \| tr -d .\[:space:\].\)\" \]; then\n.*?\nfi\n", "\n", s, count=1, flags=re.S)'"${PYFTR}"

mutate "the evidence-dir mkdir check is dropped" "mkdir" "${PYHDR}"'
s=s.replace("mkdir -p \"${RUN_DIR}\" || die 1 \"cannot create the evidence directory ${RUN_DIR} — nothing was run\"", "mkdir -p \"${RUN_DIR}\" 2>/dev/null", 1)
s=s.replace(": >\"${RUN_LOG}\" || die 1 \"cannot write ${RUN_LOG} — nothing was run\"", ": >\"${RUN_LOG}\" 2>/dev/null", 1)'"${PYFTR}"

mutate "the INCOMPLETE (exit 3) bucket is folded back into ERROR" "classify incomplete" "${PYHDR}"'
s=re.sub(r"\n    # exit 3 is a THIRD documented verdict.*?INC=\$\(\(INC \+ 1\)\) ;;\n", "\n", s, count=1, flags=re.S)
s=s.replace("[ \"${INC}\"  -gt 0 ] && exit 1\n", "", 1)'"${PYFTR}"

mutate "the watch list is iterated UNQUOTED again (pathname expansion)" "literal" "${PYHDR}"'
s=s.replace("${LIVE_PREFIXES[@]+\"${LIVE_PREFIXES[@]}\"}", "${LIVE_PREFIX}")'"${PYFTR}"

mutate "the prefix is matched as a grep REGEX again, not literally" "literal" "${PYHDR}"'
NEW = ("      for pfx in ${LIVE_PREFIX}; do\n"
       "        hits=\"$(printf \"%s\\n\" \"${out}\" | grep -a \"^${pfx}\" || true)\"\n"
       "        [ -n \"${hits}\" ] && names=\"${names}${hits}\n\"\n"
       "      done\n")
s=re.sub(r"      while IFS= read -r nm; do.*?      done <<<\"\$\{out\}\"\n", lambda m: NEW, s, count=1, flags=re.S)
s=s.replace("  local nm", "  local nm\n  local hits", 1)'"${PYFTR}"

mutate "the signal trap is deleted (#397 item 2 reverted)" "signal" "${PYHDR}"'
s=re.sub(r"\ntrap .on_signal INT.  INT\ntrap .on_signal TERM. TERM\ntrap .on_signal HUP.  HUP\n", "\n", s, count=1)'"${PYFTR}"

mutate "the per-suite timeout branch is dropped" "timeout" "${PYHDR}"'
s=s.replace("timeout --foreground \"${SUITE_TIMEOUT}\" bash \"${abs}\"", "bash \"${abs}\"", 1)'"${PYFTR}"

echo "  mutations: ${MC} caught, ${MS} survived"
if [ "${MS}" -eq 0 ] && [ "${MC}" -gt 0 ]; then
  ok "every mutation was caught — this pin is not vacuous"
else
  bad "${MS} mutation(s) SURVIVED — this pin does not pin what it claims to"
fi

# ── the real runner is untouched ─────────────────────────────────────────────
if [ -z "$(git -C "${REPO}" status --porcelain -- tests/scripts/run-ungated-lane.sh 2>/dev/null)" ]; then
  ok "tests/scripts/run-ungated-lane.sh is unmodified by this run (only scratch copies were mutated)"
else
  echo "  NOTE tests/scripts/run-ungated-lane.sh has uncommitted changes; this guard never writes there," \
       "so they are the caller's own edits"
  ok "this guard mutated only its scratch copies"
fi

echo
echo "== run-ungated-lane pin: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

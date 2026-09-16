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
#   1. selection is DERIVED from the array: e2e = the /test-e2e-/ entries, all =
#      every entry, comments stripped, and the array's close paren is honoured
#      even when indented (an unanchored parser ran on into the NEXT array and
#      selected a suite from it — measured 2026-09-16)
#   2. a bogus E2E_UNGATED_SET and a guard without the array both refuse (exit 1)
#      rather than running a guessed subset
#   3. exit 0/1/2/other classify as PASS/FAIL/SKIP/ERROR, a missing file is an
#      ERROR, the lane exits 1 on any FAIL/ERROR, evidence lands as run.log plus
#      one path-named .log per suite, and the non-e2e entry is not run
#   4. green+skip exits 0; E2E_UNGATED_STRICT=1 makes it 1
#   5. VACUITY FLOOR: every suite skipped exits 6, STRICT or not
#   6. a live footprint (prefix-matched container, or the kind cluster) REFUSES
#      with exit 3 BEFORE creating the evidence dir or running anything;
#      `x-hugmesh-local-y` is not a match, `hugmesh-localfoo` is
#   7. E2E_UNGATED_ALLOW_LIVE_STACK=1 proceeds beside a stable footprint (exit
#      0) and exits 4 when a suite moves it mid-run, printing both censuses
#   8. FAIL-CLOSED CENSUS: docker or kind present but FAILING refuses with exit
#      5, override or not, and the dry run says so; a failing after-census also
#      exits 5 (LANE UNVERIFIABLE); a box with neither tool installed proceeds
#   9. an unwritable evidence dir refuses (exit 1) instead of classifying every
#      suite FAIL without running it
#  10. E2E_UNGATED_SUITE_TIMEOUT kills a hung suite (exit 124 -> ERROR, lane 1)
#      and rejects a non-numeric value
#  11. the runner's source, comment-stripped, carries no teardown verb, no
#      `| grep -q`, and no two-assignment `local` (the bash 5.3 trap); the
#      Makefile target is the runner alone with no prerequisite, and no CI file
#      names `make e2e-ungated` or the runner
#
# NEGATIVE CONTROLS. The battery is re-run against MUTATED copies of the runner
# — the exit-3 refusal deleted, the exit-4 census deleted, the fail-open census
# restored, the vacuity floor removed, the paren anchor loosened, the mkdir
# check dropped, the timeout branch dropped — and each mutation must make at
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
# write_tree <dir> <profile>   profiles: full | greenskip | allskip | override | mutator | censusdrop | sleeper
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
    full)       entries="tests/scripts/test-e2e-green.sh tests/scripts/test-e2e-red.sh tests/scripts/test-e2e-skip.sh tests/scripts/test-e2e-crash.sh tests/scripts/test-e2e-missing.sh tests/stack/test-not-e2e.sh" ;;
    greenskip)  entries="tests/scripts/test-e2e-green.sh tests/scripts/test-e2e-skip.sh" ;;
    allskip)    entries="tests/scripts/test-e2e-skip.sh tests/scripts/test-e2e-skip2.sh" ;;
    override)   entries="tests/scripts/test-e2e-green.sh" ;;
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
  stub tests/stack/test-not-e2e.sh          'echo not-e2e; exit 0'
  stub tests/other/test-e2e-trailing.sh     'echo trailing; exit 0'
  stub tests/scripts/test-e2e-mutator.sh    'echo hugmesh-local-evil-new >>"${STUB_STATE}/docker.names"; exit 0'
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
run_lane() {
  local tree
  local tools
  local out
  local path
  tree="$1"; tools="$2"; out="$3"; shift 3
  if [ "${tools}" = "stubs" ]; then path="${STUBBIN}:${MINBIN}"; else path="${MINBIN}"; fi
  RC=0
  env -i PATH="${path}" HOME="${SCRATCH}" TMPDIR="${SCRATCH}/tmp" \
      STUB_STATE="${STATE}" RAN_LOG="${RAN}" E2E_UNGATED_LOG_DIR="${LOGS}" "$@" \
      bash "${tree}/tests/scripts/run-ungated-lane.sh" >"${out}" 2>&1 </dev/null || RC=$?
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
    has "${O}" "set   : e2e (5 of 6 PREMERGE_UNGATED suites)" \
      && ok "e2e selection is 5 of 6 (the /test-e2e-/ entries, comments stripped)" \
      || bad "e2e selection count wrong: $(grep -a 'set   :' "${O}")"
    for s in green red skip crash missing; do
      has "${O}" "     tests/scripts/test-e2e-${s}.sh" && ok "dry run lists test-e2e-${s}.sh" || bad "dry run does not list test-e2e-${s}.sh"
    done
    has "${O}" "test-not-e2e.sh" && bad "e2e selection swept in the non-e2e entry" || ok "e2e selection excludes tests/stack/test-not-e2e.sh"
    has "${O}" "test-e2e-trailing.sh" && bad "parser ran past the INDENTED close paren into TRAILING_ARRAY" || ok "the indented close paren ends the array (TRAILING_ARRAY not read)"
    has "${O}" "should-not-be-selected" && bad "parser picked up an entry from the array BEFORE PREMERGE_UNGATED" || ok "the preceding array is not read"
    has "${O}" "footprint: none — a real run would proceed" && ok "dry run with no docker/kind on PATH reports no footprint" || bad "dry run footprint line wrong"
    [ -e "${RAN}" ] && bad "dry run EXECUTED a suite" || ok "dry run executed nothing"
    [ -e "${LOGS}" ] && bad "dry run created the evidence dir" || ok "dry run created no evidence dir"
    new_state; O="${STATE}/dryall.out"
    run_lane "${T}" none "${O}" E2E_UNGATED_DRY_RUN=1 E2E_UNGATED_SET=all
    has "${O}" "set   : all (6 of 6 PREMERGE_UNGATED suites)" && has "${O}" "tests/stack/test-not-e2e.sh" \
      && ok "SET=all selects every entry including the non-e2e one" || bad "SET=all selection wrong: $(grep -a 'set   :' "${O}")"
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
    has "${O}" "ERROR  tests/scripts/test-e2e-missing.sh  (no such file" && ok "a missing suite -> ERROR (no such file)" || bad "missing not ERROR"
    has "${O}" "== RESULT: 1 passed, 1 failed, 1 skipped, 2 errored (of 5) ==" && ok "RESULT line counts 1/1/1/2 of 5" || bad "RESULT line wrong: $(grep -a 'RESULT' "${O}")"
    grep -a -E '^ *\| +FAIL something' "${O}" >/dev/null && ok "a red suite's tail is inlined" || bad "red tail not inlined"
    [ -e "${RAN}" ] && grep -a -x 'test-e2e-green.sh' "${RAN}" >/dev/null && grep -a -x 'test-e2e-crash.sh' "${RAN}" >/dev/null \
      && ok "the stub suites really ran (ran.log)" || bad "ran.log missing green/crash"
    grep -a 'test-not-e2e' "${RAN}" >/dev/null && bad "the non-e2e entry was RUN in the e2e set" || ok "the non-e2e entry was not run"
    local d
    d="$(ls -d "${LOGS}"/*/ 2>/dev/null | head -n1)"
    [ -n "${d}" ] && [ -f "${d}/run.log" ] && ok "evidence dir exists with run.log" || bad "no evidence dir / run.log under ${LOGS}"
    [ -n "${d}" ] && [ -f "${d}/tests_scripts_test-e2e-green.log" ] && [ -f "${d}/tests_scripts_test-e2e-red.log" ] \
      && ok "per-suite logs are named from the full path (tests_scripts_test-e2e-green.log)" || bad "per-suite logs missing or misnamed: $(ls "${d}" 2>/dev/null | tr '\n' ' ')"
    [ -n "${d}" ] && grep -a 'FAIL   tests/scripts/test-e2e-red.sh' "${d}/run.log" >/dev/null && ok "run.log carries the verdicts" || bad "run.log lacks the verdicts"
    has "${O}" "studio python: python3 (SNAP_STUDIO_PYTHON unset" && ok "the header names the Studio interpreter it ran with (unset)" || bad "no studio python line"
    new_state; O="${STATE}/snap.out"
    run_lane "${T}" none "${O}" SNAP_STUDIO_PYTHON=/opt/venv/bin/python
    has "${O}" "studio python: /opt/venv/bin/python" && ok "SNAP_STUDIO_PYTHON is printed when set" || bad "SNAP_STUDIO_PYTHON not echoed"
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
    printf '%s\n' hugmesh-local-control-plane other-thing x-hugmesh-local-y hugmesh-localfoo >"${STATE}/docker.names"
    printf '%s\n' hugmesh-local >"${STATE}/kind.clusters"
    O="${STATE}/refuse.out"
    run_lane "${T}" stubs "${O}"
    [ "${RC}" = "3" ] && ok "a live hugmesh-local footprint refuses with exit 3" || bad "footprint present: rc ${RC}, expected 3"
    has "${O}" "REFUSED: a live 'hugmesh-local' footprint is up on this box" && ok "refusal names itself" || bad "no refusal banner"
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
    # kind cluster alone
    new_state; : >"${STATE}/docker.names"; printf '%s\n' hugmesh-local >"${STATE}/kind.clusters"; O="${STATE}/kindonly.out"
    run_lane "${T}" stubs "${O}"
    [ "${RC}" = "3" ] && has "${O}" "kind-cluster:hugmesh-local" && ok "the kind cluster alone is a footprint" || bad "kind-only: rc ${RC}"
    # neither: proceeds
    new_state; : >"${STATE}/docker.names"; : >"${STATE}/kind.clusters"; O="${STATE}/clear.out"
    run_lane "${T}" stubs "${O}"
    [ "${RC}" = "1" ] && has "${O}" "live stack   : none detected" && ok "docker+kind present and EMPTY -> proceeds (rc from the suites)" || bad "clear footprint: rc ${RC}"
  fi

  # 7. override ────────────────────────────────────────────────────────────
  if case_selected override; then
    write_tree "${T}" override; new_state
    printf '%s\n' hugmesh-local-control-plane >"${STATE}/docker.names"; : >"${STATE}/kind.clusters"
    O="${STATE}/ov.out"
    run_lane "${T}" stubs "${O}" E2E_UNGATED_ALLOW_LIVE_STACK=1
    [ "${RC}" = "0" ] && has "${O}" "OVERRIDDEN — proceeding beside hugmesh-local-control-plane" && ok "override + stable footprint -> proceeds, exit 0" || bad "override stable: rc ${RC}"
    write_tree "${T}" mutator; new_state
    printf '%s\n' hugmesh-local-control-plane >"${STATE}/docker.names"; : >"${STATE}/kind.clusters"
    O="${STATE}/ov-moved.out"
    run_lane "${T}" stubs "${O}" E2E_UNGATED_ALLOW_LIVE_STACK=1
    [ "${RC}" = "4" ] && ok "override + footprint moved mid-run -> exit 4" || bad "override moved: rc ${RC}, expected 4"
    has "${O}" "LANE VIOLATION" && has "${O}" "before: hugmesh-local-control-plane" && has "${O}" "after : hugmesh-local-control-plane hugmesh-local-evil-new" \
      && ok "the violation prints both censuses" || bad "violation censuses missing: $(grep -a 'before:\|after :' "${O}" | tr '\n' ' ')"
  fi

  # 8. fail-closed census ─────────────────────────────────────────────────
  if case_selected census; then
    write_tree "${T}" override; new_state
    echo error >"${STATE}/docker.mode"; : >"${STATE}/kind.clusters"
    O="${STATE}/derr.out"
    run_lane "${T}" stubs "${O}"
    [ "${RC}" = "5" ] && ok "docker present but FAILING -> exit 5 (not 'none detected')" || bad "docker error: rc ${RC}, expected 5"
    has "${O}" "could not be determined" && has "${O}" "docker ps failed: permission denied" && ok "the refusal quotes docker's error" || bad "census error text missing"
    has "${O}" "none detected" && bad "a failing census was reported as none detected" || ok "no 'none detected' on a failing census"
    [ -e "${RAN}" ] && bad "a suite RAN on an undeterminable footprint" || ok "nothing ran on an undeterminable footprint"
    O="${STATE}/derr-ov.out"
    run_lane "${T}" stubs "${O}" E2E_UNGATED_ALLOW_LIVE_STACK=1
    [ "${RC}" = "5" ] && ok "the override does NOT bypass exit 5" || bad "override bypassed the census error: rc ${RC}"
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
    write_tree "${T}" override; new_state
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

  # 11. source sweeps ─────────────────────────────────────────────────────
  if case_selected source; then
    local src
    src="$(sed -e 's/#.*$//' "${T}/tests/scripts/run-ungated-lane.sh")"
    printf '%s\n' "${src}" | grep -aE 'docker +(stop|rm|kill)|kind +delete|stack-down|stack-halt|compose +down' >/dev/null \
      && bad "the runner carries a teardown verb" || ok "no teardown verb in the runner (comment-stripped)"
    printf '%s\n' "${src}" | grep -aE '\| *grep +-[a-zA-Z]*q' >/dev/null && bad "the runner pipes into grep -q" || ok "no '| grep -q' in the runner"
    printf '%s\n' "${src}" | grep -aE '^[[:space:]]*local [a-zA-Z_]+=[^ ]* +[a-zA-Z_]+=' >/dev/null && bad "a two-assignment 'local' (bash 5.3 set -u trap)" || ok "every 'local' declares one name (bash 5.3 trap absent)"
    printf '%s\n' "${src}" | grep -a 'CENSUS-ERROR' >/dev/null && ok "the census emits CENSUS-ERROR lines (fail-closed path present)" || bad "no CENSUS-ERROR path in the runner"
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
s=re.sub(r"\nif \[ -n \"\$\{FOOTPRINT_BEFORE\}\" \] && \[ \"\$\{ALLOW_LIVE\}\" != \"1\" \]; then\n.*?\n  exit 3\nfi\n", "\n", s, count=1, flags=re.S)'"${PYFTR}"

mutate "the exit-4 before/after census is deleted" "override" "${PYHDR}"'
s=re.sub(r"\nif \[ \"\$\{FOOTPRINT_BEFORE\}\" != \"\$\{FOOTPRINT_AFTER\}\" \]; then\n.*?\n  exit 4\nfi\n", "\n", s, count=1, flags=re.S)'"${PYFTR}"

mutate "the census fails OPEN again (docker error read as empty)" "census" "${PYHDR}"'
s=s.replace("errs=\"${errs}CENSUS-ERROR docker ps failed", ": # errs=\"${errs}CENSUS-ERROR docker ps failed", 1)'"${PYFTR}"

mutate "the vacuity floor (exit 6) is removed" "vacuous" "${PYHDR}"'
s=re.sub(r"\nif \[ \"\$\{PASS\}\" -eq 0 \]; then\n.*?\n  exit 6\nfi\n", "\n", s, count=1, flags=re.S)'"${PYFTR}"

mutate "the array close-paren anchor is loosened to column 0" "selection" "${PYHDR}"'
s=s.replace("/^[[:space:]]*\\)[[:space:]]*$/{f=0}", "/^\\)/{f=0}", 1)'"${PYFTR}"

mutate "the evidence-dir mkdir check is dropped" "mkdir" "${PYHDR}"'
s=s.replace("mkdir -p \"${RUN_DIR}\" || die 1 \"cannot create the evidence directory ${RUN_DIR} — nothing was run\"", "mkdir -p \"${RUN_DIR}\" 2>/dev/null", 1)
s=s.replace(": >\"${RUN_LOG}\" || die 1 \"cannot write ${RUN_LOG} — nothing was run\"", ": >\"${RUN_LOG}\" 2>/dev/null", 1)'"${PYFTR}"

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

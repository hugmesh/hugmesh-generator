#!/usr/bin/env bash
# run-ungated-lane.sh — the routinely-executed home for the PREMERGE_UNGATED suites.
#
# WHY THIS EXISTS (hugmesh-generator#246). A set of suites is deliberately exempt
# from the pre-merge gate: they need node_modules + chromium + Qt6 (or a live
# cluster) that no shell-suites CI image carries, so gating them would only gate
# a job that always skips. The consequence is that they ran "when someone
# remembered". This is the thing that remembers — ONE command, on the one box
# that has the toolchain, run WHEN A HUMAN ASKS.
#
# IT IS A MAKE TARGET AND NOTHING ELSE, deliberately: no cron entry, no systemd
# timer, no CI job. `make e2e-ungated` is the only caller. Operator decision on
# #246, 2026-09-10: "yes, make it a make target."
#
# THE LIST IS NOT COPIED. Both sets are DERIVED at run time from the
# PREMERGE_UNGATED array in tests/scripts/test-guard-integrity.sh, which is the
# single place this repo records which suites are exempt and why. A second
# hand-maintained copy in the Makefile would drift the first time a suite was
# exempted or gated, and would drift silently — the failure mode this repo keeps
# re-learning about. If the array cannot be parsed, this script FAILS (exit 1)
# rather than running a guessed subset.
#
#   E2E_UNGATED_SET=e2e   (default)  the tests/scripts/test-e2e-*.sh entries —
#                                    the browser/Qt family #246 was written about
#                                    (8 of 22 when this was written; the runner
#                                    prints the live count every run)
#   E2E_UNGATED_DRY_RUN=1            print the selection and whether a real run
#                                    would be allowed beside whatever is up, then
#                                    stop. Executes no suite. This is how you
#                                    verify the wiring without a twenty-minute lane.
#   E2E_UNGATED_SET=all              every PREMERGE_UNGATED entry, which
#                                    additionally sweeps in the stack, kind,
#                                    casdoor, pentest, eso and liquibase suites
#                                    that are ungated for their OWN reasons and
#                                    are NOT what #246 asked for
#   E2E_UNGATED_STRICT=1             a SKIPPED-LOUDLY exit 2 counts as red
#   E2E_UNGATED_SUITE_TIMEOUT=<sec>  kill a suite that runs longer than this
#                                    (exit 124 -> ERROR). Unset/0 = no limit.
#                                    None of the suites carries a timeout of its
#                                    own, so a hung one otherwise hangs the lane.
#   E2E_UNGATED_LOG_DIR=<dir>        relocate the dated evidence directory
#   E2E_UNGATED_LIVE_PREFIX="a b"    replace the watched project prefixes. A
#                                    SPACE-SEPARATED LIST; the default is
#                                    "hugmesh-local hugmesh-real". An EMPTY
#                                    value is refused (exit 1) rather than
#                                    silently watching nothing — with a list,
#                                    an empty one iterates zero times and the
#                                    census would fail OPEN.
#   SNAP_STUDIO_PYTHON=<python>      NOT this runner's variable, but the one that
#                                    decides whether the default set can be green
#                                    on this box: test-e2e-studio-gui-lane.sh
#                                    (:127) drives the Studio unit lane with
#                                    `${SNAP_STUDIO_PYTHON:-python3}`, and when
#                                    that interpreter lacks pytest the suite goes
#                                    RED ("the Studio unit lane could not run") —
#                                    not SKIP. On a box whose system python3 has
#                                    no pytest, run
#                                        SNAP_STUDIO_PYTHON=studio/.venv/bin/python make e2e-ungated
#                                    The runner passes the environment through
#                                    untouched and prints the value it ran with.
#
# DURATION, measured 2026-09-16 on the operator's box with the toolchain present:
# the default set takes ~21 minutes (coverage-matrix alone ~9 min). It is not a
# two-minute smoke.
#
# THE LIVE STACK IS NOT TOUCHED. #246's third bullet: the lane must never disturb
# the operator's live hugmesh-local stack. This script therefore:
#   * REFUSES TO START (exit 3) when a live footprint is present under ANY of
#     the watched prefixes — by default BOTH hugmesh-local AND hugmesh-real
#     (operator decision 32a on #347, 2026-09-17). A footprint is a kind cluster
#     whose name IS a watched prefix, or any docker container whose name BEGINS
#     with one (a compose project and a kind node both use the project name as
#     that prefix). It says what it found and stops.
#
#     WHY BOTH. tests/stack/compose.real.yaml is `name: hugmesh-real` and has a
#     standalone bring-up path (tests/stack/up-real.sh); it is only an `include:`
#     of compose.local.yaml when you come in through `make stack-up`. Taken
#     alone it is its own project, so its containers are hugmesh-real-* and a
#     hugmesh-local-only census could not see them. Measured on main @ c00ddf78
#     with a PATH-shadowed docker reporting hugmesh-real-casdoor-1 and
#     hugmesh-real-tuwunel-1: the dry run said "none — a real run would proceed"
#     and a real invocation started the suites (hugmesh-generator#397).
#   * REFUSES TO START (exit 5) when the footprint CANNOT BE DETERMINED — docker
#     or kind is installed but the census command fails (dead daemon, socket
#     permission denied, broken kubeconfig). A census that errors is NOT an
#     empty census: before 2026-09-16 the two were indistinguishable and the lane
#     proceeded on a dead daemon. A box with neither tool installed has no
#     footprint, which IS an empty census and proceeds.
#   * never runs `stack-down`, `stack-halt`, `kind delete`, `docker stop/rm` or
#     any other teardown, in any mode, for any reason. It only ever invokes the
#     suites named in the array.
#   * HAS NO OVERRIDE. Operator decision 32b on #347, 2026-09-17: the
#     E2E_UNGATED_ALLOW_LIVE_STACK=1 escape hatch is REMOVED. #246 asked for a
#     Make target, not an escape hatch; the override was the implementer's own
#     design call. There is now no value of any variable that lets this lane run
#     beside a watched footprint — bring the stack down yourself, or narrow
#     E2E_UNGATED_LIVE_PREFIX deliberately to a list that does not name it.
#   * still censuses the footprint BEFORE and AFTER the run and goes red (exit 4)
#     if it changed, or (exit 5) if the after-census cannot be taken. Without the
#     override the before-census is always EMPTY when the lane proceeds, so this
#     check now means something narrower and sharper: a suite in the set BROUGHT
#     a watched footprint UP while the lane ran. That is exactly the arrival
#     #246's third bullet forbids, and it is why the check outlived the override.
#
# WHAT THE SUITES THEMSELVES START — MEASURED 2026-09-16, comment-stripped, over
# all 22 PREMERGE_UNGATED entries (this paragraph replaces one written on
# 2026-09-10 that said "none of the 22 brings a stack up", which was FALSE on the
# tree it was written against; a skeptic pass caught it):
#   * ONE suite in the DEFAULT set starts a container:
#     tests/scripts/test-e2e-env-interface-dimensions.sh's M7 control
#     (m7_standin_start, :1006) runs
#         docker run -d --name e2eguard-m7-<pid>-control-plane -p 127.0.0.1::80 python:3.12-slim
#     as a loopback http.server stand-in and removes ONLY that naming shape
#     (`^e2eguard-m7-[0-9]+-control-plane$`, :999/:1003-1005). It is
#     self-contained, cannot reach a hugmesh-local container, and the census
#     above does not count it (wrong prefix) — a real run on 2026-09-16 saw it
#     start and remove itself with the footprint unchanged.
#   * everything else is a READ: `docker ps` (the same suite), `docker compose
#     config` (tests/stack/test-web-locales-wiring.sh), `kubectl` against
#     whatever context is current (test-kind-metrics-api.sh,
#     test-selected-services-only.sh — SET=all only), plus one throwaway node
#     fixture on its own loopback port (tests/pentest/nuclei/test-templates.sh).
# The refusal is a floor, not a diagnosis: it is here so that a future suite
# which DOES start something with the live prefix cannot arrive quietly.
#
# EXIT CODES, per suite and overall. The suites already distinguish these and
# the distinction is the whole point of a routine run — a lane that cannot tell
# "red" from "the toolchain is missing" trains everyone to ignore it.
#   0  PASS   the suite ran and was green
#   1  FAIL   the suite ran and was red            -> lane exits 1
#   2  SKIP   SKIPPED-LOUDLY, prerequisite missing -> lane exits 0 unless
#             E2E_UNGATED_STRICT=1, which makes any SKIP red
#   *  ERROR  anything else (crash, 124 timeout, 126/127) -> lane exits 1
# The lane's own verdicts:
#   3  refused: a live footprint under a watched prefix was detected
#   4  the footprint changed while the lane ran (a suite brought one up)
#   5  refused: the footprint could not be determined (census tool failed)
#   6  VACUOUS: suites were selected and NOT ONE passed (every one skipped). A
#      lane that asserted nothing is not green, STRICT or not — on a checkout
#      without tests/e2e/node_modules this is what `make e2e-ungated` prints,
#      and before 2026-09-16 it exited 0.
#
# EVIDENCE. One dated directory per run under tests/.ungated-lane/ (gitignored
# run-state of one machine, never shared — the tests/stack/.run/ precedent), NOT
# under out/, which is the generator's product tree. Each suite gets its own
# .log named after its full path (tests_scripts_test-e2e-cli-lane.log), so two
# suites with the same basename in different directories cannot share one;
# run.log carries the verdict table. E2E_UNGATED_LOG_DIR relocates it.
#
# PINNED BY tests/scripts/test-run-ungated-lane.sh (pre-merge gated): a stub
# battery that runs THIS file against a synthetic tree and PATH-shadowed
# docker/kind, and re-runs it against mutated copies of this file (refusal
# deleted, census fail-open restored, vacuity floor removed, paren anchor
# loosened) to prove each protection is load-bearing. Change a behaviour here
# and that suite is where it goes red.
#
# This file is a RUNNER, not a suite: it is named run-*.sh so the test-*.sh /
# *_test.sh census in test-guard-integrity.sh does not count it as a suite and
# inflate the coverage denominator with something that has no assertions of its
# own.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
GUARD="${HERE}/test-guard-integrity.sh"

SET_NAME="${E2E_UNGATED_SET:-e2e}"
STRICT="${E2E_UNGATED_STRICT:-0}"
# DECISION 32a (#347, 2026-09-17): BOTH live shapes by default, not just the
# one #246 named. A space-separated LIST; see the header.
UNGATED_DEFAULT_LIVE_PREFIXES="hugmesh-local hugmesh-real"
LIVE_PREFIX="${E2E_UNGATED_LIVE_PREFIX:-${UNGATED_DEFAULT_LIVE_PREFIXES}}"
# Rendered for the messages below: "hugmesh-local, hugmesh-real".
LIVE_PREFIX_SHOWN="$(printf '%s' "${LIVE_PREFIX}" | tr -s '[:space:]' ' ' \
                    | sed -e 's/^ //' -e 's/ $//' -e 's/ /, /g')"
SUITE_TIMEOUT="${E2E_UNGATED_SUITE_TIMEOUT:-0}"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_ROOT="${E2E_UNGATED_LOG_DIR:-${REPO}/tests/.ungated-lane}"
RUN_DIR="${LOG_ROOT}/${RUN_ID}"
RUN_LOG="${RUN_DIR}/run.log"

# bash 5.3 dies on `local a=$1 b=$a` under set -u (every name is localised BEFORE
# the assignments run), so every helper below declares one name per `local`.
say() {
  local msg
  msg="$*"
  printf '%s\n' "${msg}"
  [ -n "${RUN_LOG:-}" ] && [ -d "${RUN_DIR:-}" ] && printf '%s\n' "${msg}" >>"${RUN_LOG}"
  return 0
}

die() {
  local code
  code="$1"
  shift
  say "REFUSED: $*"
  exit "${code}"
}

# ── the live hugmesh-local footprint ─────────────────────────────────────────
# READ ONLY. `docker ps` and `kind get clusters` observe; neither changes
# anything. Both tools are optional: a box WITHOUT docker or WITHOUT kind simply
# has no footprint, which is not an error. A box WITH the tool whose census
# command FAILS is a different thing: the footprint is then unknown, and unknown
# is not "none". Such a failure is reported as a line beginning CENSUS-ERROR so
# the caller can refuse (exit 5) instead of reading it as an empty census.
live_footprint() {
  local names
  local errs
  local out
  local errf
  local pfx
  local hits
  names=""
  errs=""
  errf="$(mktemp -t ungated-census.XXXXXX)"
  if command -v docker >/dev/null 2>&1; then
    if out="$(docker ps --format '{{.Names}}' 2>"${errf}")"; then
      for pfx in ${LIVE_PREFIX}; do
        hits="$(printf '%s\n' "${out}" | grep -a "^${pfx}" || true)"
        [ -n "${hits}" ] && names="${names}${hits}"$'\n'
      done
    else
      errs="${errs}CENSUS-ERROR docker ps failed: $(head -n 1 "${errf}" | cut -c1-160)"$'\n'
    fi
  fi
  if command -v kind >/dev/null 2>&1; then
    if out="$(kind get clusters 2>"${errf}")"; then
      for pfx in ${LIVE_PREFIX}; do
        if printf '%s\n' "${out}" | grep -ax "${pfx}" >/dev/null; then
          names="${names}kind-cluster:${pfx}"$'\n'
        fi
      done
    else
      errs="${errs}CENSUS-ERROR kind get clusters failed: $(head -n 1 "${errf}" | cut -c1-160)"$'\n'
    fi
  fi
  rm -f "${errf}"
  # sort -u, not sort: one container can match two prefixes when one is a prefix
  # of the other, and a duplicate would make the before/after comparison lie.
  printf '%s\n' "${names}" | grep -a . | sort -u || true
  printf '%s' "${errs}"
}

# Split a live_footprint() result into its two halves.
census_errors() { printf '%s\n' "$1" | grep -a  '^CENSUS-ERROR ' || true; }
census_names()  { printf '%s\n' "$1" | grep -av '^CENSUS-ERROR ' | grep -a . || true; }

# ── the suite list, derived from PREMERGE_UNGATED ────────────────────────────
# Comments inside the array carry the per-suite exemption reasons, so they are
# stripped here; blank lines go with them. `grep -a` throughout: a single NUL
# byte makes GNU grep skip a whole file and exit 1, which is indistinguishable
# from an honest miss, and this list is load-bearing. The closing paren is
# matched with optional leading whitespace: anchored on column 0 only, an
# indented `)` let the parser run on into the NEXT array (measured 2026-09-16).
[ -r "${GUARD}" ] || die 1 "cannot read ${GUARD} — the PREMERGE_UNGATED list has no source"

ALL_UNGATED="$(awk '/^PREMERGE_UNGATED=\(/{f=1;next} /^[[:space:]]*\)[[:space:]]*$/{f=0} f' "${GUARD}" \
               | sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
               | grep -a . || true)"

if [ -z "${ALL_UNGATED}" ]; then
  die 1 "parsed ZERO entries out of PREMERGE_UNGATED in ${GUARD} — refusing to run a guessed subset"
fi

case "${SET_NAME}" in
  e2e) SUITES="$(printf '%s\n' "${ALL_UNGATED}" | grep -a '/test-e2e-' || true)" ;;
  all) SUITES="${ALL_UNGATED}" ;;
  *)   die 1 "E2E_UNGATED_SET must be 'e2e' (default, the test-e2e-* browser/Qt suites) or 'all'; got '${SET_NAME}'" ;;
esac

if [ -z "${SUITES}" ]; then
  die 1 "the '${SET_NAME}' selection matched no entry in PREMERGE_UNGATED"
fi

TOTAL="$(printf '%s\n' "${SUITES}" | grep -ac . || true)"
UNGATED_TOTAL="$(printf '%s\n' "${ALL_UNGATED}" | grep -ac . || true)"

# An empty watch list is not "watch nothing" — the census loop would iterate zero
# times and report an empty footprint on a box with the stack up. That is the
# fail-open shape this runner exists to refuse, so it is refused here.
if [ -z "$(printf '%s' "${LIVE_PREFIX}" | tr -d '[:space:]')" ]; then
  die 1 "E2E_UNGATED_LIVE_PREFIX is empty — there would be nothing to census, and an empty census is not an empty footprint. Name at least one project prefix, or unset it for the default (${UNGATED_DEFAULT_LIVE_PREFIXES})."
fi

case "${SUITE_TIMEOUT}" in
  ''|*[!0-9]*) die 1 "E2E_UNGATED_SUITE_TIMEOUT must be a whole number of seconds; got '${SUITE_TIMEOUT}'" ;;
esac
if [ "${SUITE_TIMEOUT}" != "0" ] && ! command -v timeout >/dev/null 2>&1; then
  die 1 "E2E_UNGATED_SUITE_TIMEOUT=${SUITE_TIMEOUT} but no 'timeout' binary is on PATH"
fi

# ── refuse before doing anything ─────────────────────────────────────────────
CENSUS_BEFORE="$(live_footprint)"
CENSUS_ERR="$(census_errors "${CENSUS_BEFORE}")"
FOOTPRINT_BEFORE="$(census_names "${CENSUS_BEFORE}")"

# E2E_UNGATED_DRY_RUN=1 answers "what would this run, and would it be allowed to?"
# and then stops. It executes NO suite, starts nothing and touches nothing, which
# is why it is answered BEFORE the refusal below rather than after: on a box where
# the live stack is up, being told the selection is exactly the thing you want,
# and the refusal is the answer it prints rather than an obstacle to printing it.
if [ "${E2E_UNGATED_DRY_RUN:-0}" = "1" ]; then
  printf '%s\n' "== ungated lane — DRY RUN, nothing was executed =="
  printf '%s\n' "   set   : ${SET_NAME} (${TOTAL} of ${UNGATED_TOTAL} PREMERGE_UNGATED suites)"
  printf '%s\n' "   source: ${GUARD} (PREMERGE_UNGATED)"
  printf '%s\n' "   suites:"
  printf '%s\n' "${SUITES}" | sed 's/^/     /'
  if [ -n "${CENSUS_ERR}" ]; then
    printf '%s\n' "   live footprint [${LIVE_PREFIX_SHOWN}]: UNDETERMINABLE — a real run would REFUSE (exit 5)"
    printf '%s\n' "${CENSUS_ERR}" | sed 's/^/     /'
  elif [ -z "${FOOTPRINT_BEFORE}" ]; then
    printf '%s\n' "   live footprint [${LIVE_PREFIX_SHOWN}]: none — a real run would proceed"
  else
    printf '%s\n' "   live footprint [${LIVE_PREFIX_SHOWN}]: PRESENT — a real run would REFUSE (exit 3)"
    printf '     %s\n' ${FOOTPRINT_BEFORE}
  fi
  exit 0
fi

if [ -n "${CENSUS_ERR}" ]; then
  printf '%s\n' "REFUSED: the live footprint [${LIVE_PREFIX_SHOWN}] on this box could not be determined:"
  printf '%s\n' "${CENSUS_ERR}" | sed 's/^/  /'
  printf '%s\n' "  A census that errors is not an empty census. Nothing was started and nothing"
  printf '%s\n' "  was stopped, and there is no override to wave this through — see decision 32b."
  printf '%s\n' "  Fix the tool (or uninstall it, if this box really has no docker/kind) and re-run."
  exit 5
fi

if [ -n "${FOOTPRINT_BEFORE}" ]; then
  printf '%s\n' "REFUSED: a live footprint [${LIVE_PREFIX_SHOWN}] is up on this box:"
  printf '  %s\n' ${FOOTPRINT_BEFORE}
  printf '%s\n' "  This lane will not run beside it. Nothing was started and nothing was stopped."
  printf '%s\n' "  THERE IS NO OVERRIDE (operator decision 32b on #347, 2026-09-17: #246 asked"
  printf '%s\n' "  for a Make target, not an escape hatch). Bring the stack down yourself and"
  printf '%s\n' "  re-run, or — if you have read the header and decided a particular project is"
  printf '%s\n' "  not worth protecting — name a narrower watch list deliberately:"
  printf '%s\n' "      E2E_UNGATED_LIVE_PREFIX=\"<the prefixes you still want refused>\" make e2e-ungated"
  printf '%s\n' "  For what the suites themselves start, read the header of"
  printf '%s\n' "  tests/scripts/run-ungated-lane.sh: one suite in the default set runs a"
  printf '%s\n' "  throwaway python:3.12-slim http.server named e2eguard-m7-* and removes it,"
  printf '%s\n' "  tests/casdoor/test-jwt-custom-token.sh starts casdoor-pg and"
  printf '%s\n' "  casdoor-jwtcustom-test and removes them, the rest only read, and the lane"
  printf '%s\n' "  itself never tears anything down."
  exit 3
fi

mkdir -p "${RUN_DIR}" || die 1 "cannot create the evidence directory ${RUN_DIR} — nothing was run"
: >"${RUN_LOG}" || die 1 "cannot write ${RUN_LOG} — nothing was run"

say "== ungated lane ${RUN_ID} =="
say "   set          : ${SET_NAME} (${TOTAL} of ${UNGATED_TOTAL} PREMERGE_UNGATED suites)"
say "   repo         : ${REPO}"
say "   evidence     : ${RUN_DIR}"
say "   strict-skips : ${STRICT}"
say "   suite-timeout: ${SUITE_TIMEOUT}s (0 = none)"
say "   studio python: ${SNAP_STUDIO_PYTHON:-python3 (SNAP_STUDIO_PYTHON unset; the Studio GUI lane goes RED, not SKIP, if it lacks pytest)}"
# With the override gone (32b) the lane only ever gets here on an EMPTY census,
# so this is a statement of fact, not a branch.
say "   live stack   : none detected (no ${LIVE_PREFIX_SHOWN} container or kind cluster)"
say ""

PASS=0
FAIL=0
SKIP=0
ERR=0
VERDICTS=""

for rel in ${SUITES}; do
  abs="${REPO}/${rel}"
  # log name from the FULL path, so tests/a/test-x.sh and tests/b/test-x.sh
  # cannot share one file
  base="$(printf '%s' "${rel%.sh}" | tr '/' '_')"
  slog="${RUN_DIR}/${base}.log"
  if [ ! -f "${abs}" ]; then
    say "ERROR  ${rel}  (no such file — PREMERGE_UNGATED names a suite that is gone)"
    VERDICTS="${VERDICTS}ERROR  ${rel}"$'\n'
    ERR=$((ERR + 1))
    continue
  fi
  say "---- ${rel} ----"
  # cd into the repo: several suites resolve paths from $PWD as well as from
  # their own location. The exit code is CAPTURED, never allowed to end the lane
  # — the whole point of a routine run is to learn about all of them at once.
  # (This script sets -u only, never -e, precisely so a red suite is data.)
  rc=0
  if [ "${SUITE_TIMEOUT}" != "0" ]; then
    ( cd "${REPO}" && timeout --foreground "${SUITE_TIMEOUT}" bash "${abs}" ) >"${slog}" 2>&1 </dev/null || rc=$?
  else
    ( cd "${REPO}" && bash "${abs}" ) >"${slog}" 2>&1 </dev/null || rc=$?
  fi
  case "${rc}" in
    0) say "PASS   ${rel}"                    ; VERDICTS="${VERDICTS}PASS   ${rel}"$'\n'   ; PASS=$((PASS + 1)) ;;
    1) say "FAIL   ${rel}   -> ${slog}"       ; VERDICTS="${VERDICTS}FAIL   ${rel}"$'\n'   ; FAIL=$((FAIL + 1)) ;;
    2) say "SKIP   ${rel}   (SKIPPED-LOUDLY; prerequisite missing) -> ${slog}"
       VERDICTS="${VERDICTS}SKIP   ${rel}"$'\n'                                            ; SKIP=$((SKIP + 1)) ;;
    124) say "ERROR  ${rel}   (exit 124: killed at the ${SUITE_TIMEOUT}s suite timeout) -> ${slog}"
       VERDICTS="${VERDICTS}ERROR  ${rel} (timeout)"$'\n'                                  ; ERR=$((ERR + 1)) ;;
    *) say "ERROR  ${rel}   (exit ${rc}) -> ${slog}"
       VERDICTS="${VERDICTS}ERROR  ${rel} (exit ${rc})"$'\n'                               ; ERR=$((ERR + 1)) ;;
  esac
  # the last few lines of a red suite, inline, so the terminal is useful without
  # opening the log
  if [ "${rc}" != "0" ] && [ "${rc}" != "2" ]; then
    tail -n 12 "${slog}" 2>/dev/null | sed 's/^/       | /' | tee -a "${RUN_LOG}"
  fi
done

CENSUS_AFTER="$(live_footprint)"
CENSUS_ERR_AFTER="$(census_errors "${CENSUS_AFTER}")"
FOOTPRINT_AFTER="$(census_names "${CENSUS_AFTER}")"

say ""
say "== verdicts =="
printf '%s' "${VERDICTS}" | sed 's/^/  /' | tee -a "${RUN_LOG}"
say ""
say "== RESULT: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped, ${ERR} errored (of ${TOTAL}) =="
say "   evidence: ${RUN_DIR}"

if [ -n "${CENSUS_ERR_AFTER}" ]; then
  say ""
  say "LANE UNVERIFIABLE: the footprint [${LIVE_PREFIX_SHOWN}] could not be re-censused after the run:"
  printf '%s\n' "${CENSUS_ERR_AFTER}" | sed 's/^/   /' | tee -a "${RUN_LOG}"
  say "   The before-census was: $(printf '%s' "${FOOTPRINT_BEFORE:-<empty>}" | tr '\n' ' ')"
  say "   Whether the lane touched the live stack cannot be shown either way; treat the"
  say "   run as unproven and fix the census tool before the next one."
  exit 5
fi

if [ "${FOOTPRINT_BEFORE}" != "${FOOTPRINT_AFTER}" ]; then
  say ""
  say "LANE VIOLATION: the footprint [${LIVE_PREFIX_SHOWN}] CHANGED while the lane ran."
  say "   before: $(printf '%s' "${FOOTPRINT_BEFORE}" | tr '\n' ' ')"
  say "   after : $(printf '%s' "${FOOTPRINT_AFTER}"  | tr '\n' ' ')"
  say "   The before-census was EMPTY (the lane cannot start otherwise — there is no"
  say "   override since decision 32b), so a suite in the '${SET_NAME}' set BROUGHT a"
  say "   watched footprint UP. That is the thing #246 said must never happen; fix the"
  say "   suite, do not relax this check."
  exit 4
fi

[ "${FAIL}" -gt 0 ] && exit 1
[ "${ERR}"  -gt 0 ] && exit 1
if [ "${SKIP}" -gt 0 ] && [ "${STRICT}" = "1" ]; then
  say "E2E_UNGATED_STRICT=1 and ${SKIP} suite(s) skipped — reporting red."
  exit 1
fi
if [ "${PASS}" -eq 0 ]; then
  say ""
  say "VACUOUS: ${TOTAL} suite(s) were selected and NOT ONE passed — every one skipped."
  say "   This lane asserted nothing, so it is not green. The usual cause is a checkout"
  say "   without tests/e2e/node_modules, chromium or Qt6; each skipped log above names"
  say "   the missing prerequisite."
  exit 6
fi
exit 0

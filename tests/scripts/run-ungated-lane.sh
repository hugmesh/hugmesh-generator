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
#   E2E_UNGATED_SET=e2e   (default)  the 8 tests/scripts/test-e2e-*.sh entries —
#                                    the browser/Qt family #246 was written about
#   E2E_UNGATED_DRY_RUN=1            print the selection and whether a real run
#                                    would be allowed beside whatever is up, then
#                                    stop. Executes no suite. This is how you
#                                    verify the wiring without a ten-minute lane.
#   E2E_UNGATED_SET=all              every PREMERGE_UNGATED entry (22 today),
#                                    which additionally sweeps in the stack,
#                                    kind, casdoor, pentest, eso and liquibase
#                                    suites that are ungated for their OWN
#                                    reasons and are NOT what #246 asked for
#
# THE LIVE STACK IS NOT TOUCHED. #246's third bullet: the lane must never disturb
# the operator's live hugmesh-local stack. This script therefore:
#   * REFUSES TO START (exit 3) when a live hugmesh-local footprint is present —
#     a kind cluster named hugmesh-local, or any docker container whose name
#     begins with hugmesh-local (the compose project and the kind node both use
#     that prefix). It says what it found and stops.
#   * never runs `stack-down`, `stack-halt`, `kind delete`, `docker stop/rm` or
#     any other teardown, in any mode, for any reason. It only ever invokes the
#     suites named in the array.
#   * when a human overrides the refusal with E2E_UNGATED_ALLOW_LIVE_STACK=1,
#     takes a census of that footprint BEFORE and AFTER the run and goes red if
#     it changed. The override is trusted to be deliberate; it is not trusted to
#     be harmless.
#
# MEASURED 2026-09-10 on this tree, and it is why the override exists: none of
# the 22 brings a stack up. Comment-stripped, the only docker/kubectl verbs in
# the whole set are reads — `docker ps` (test-e2e-env-interface-dimensions.sh),
# `docker compose config` (tests/stack/test-web-locales-wiring.sh), `kubectl`
# against whatever cluster is current (test-kind-metrics-api.sh,
# test-selected-services-only.sh) — plus one throwaway node fixture on its own
# port (tests/pentest/nuclei/test-templates.sh). The refusal is a floor, not a
# diagnosis: it is here so that a future suite which DOES start something cannot
# arrive quietly.
#
# EXIT CODES, per suite and overall. The suites already distinguish these and
# the distinction is the whole point of a routine run — a lane that cannot tell
# "red" from "the toolchain is missing" trains everyone to ignore it.
#   0  PASS   the suite ran and was green
#   1  FAIL   the suite ran and was red            -> lane exits 1
#   2  SKIP   SKIPPED-LOUDLY, prerequisite missing -> lane exits 0 unless
#             E2E_UNGATED_STRICT=1, which makes any SKIP red
#   *  ERROR  anything else (crash, 126/127)       -> lane exits 1
# The lane's own refusals: 3 = live hugmesh-local footprint detected,
# 4 = the footprint changed under an override.
#
# EVIDENCE. One dated directory per run under tests/.ungated-lane/ (gitignored
# run-state of one machine, never shared — the tests/stack/.run/ precedent), NOT
# under out/, which is the generator's product tree. Each suite gets its own
# .log; run.log carries the verdict table. E2E_UNGATED_LOG_DIR relocates it.
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
ALLOW_LIVE="${E2E_UNGATED_ALLOW_LIVE_STACK:-0}"
LIVE_PREFIX="${E2E_UNGATED_LIVE_PREFIX:-hugmesh-local}"

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
# anything. Both are optional: a box without docker or without kind simply has no
# footprint, which is not an error.
live_footprint() {
  local names
  names=""
  if command -v docker >/dev/null 2>&1; then
    names="$(docker ps --format '{{.Names}}' 2>/dev/null \
             | grep -a "^${LIVE_PREFIX}" || true)"
  fi
  if command -v kind >/dev/null 2>&1; then
    local clusters
    clusters="$(kind get clusters 2>/dev/null | grep -ax "${LIVE_PREFIX}" || true)"
    [ -n "${clusters}" ] && names="${names}"$'\n'"kind-cluster:${LIVE_PREFIX}"
  fi
  printf '%s\n' "${names}" | grep -a . | sort || true
}

# ── the suite list, derived from PREMERGE_UNGATED ────────────────────────────
# Comments inside the array carry the per-suite exemption reasons, so they are
# stripped here; blank lines go with them. `grep -a` throughout: a single NUL
# byte makes GNU grep skip a whole file and exit 1, which is indistinguishable
# from an honest miss, and this list is load-bearing.
[ -r "${GUARD}" ] || die 1 "cannot read ${GUARD} — the PREMERGE_UNGATED list has no source"

ALL_UNGATED="$(awk '/^PREMERGE_UNGATED=\(/{f=1;next} /^\)/{f=0} f' "${GUARD}" \
               | sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
               | grep -a . || true)"

if [ -z "${ALL_UNGATED}" ]; then
  die 1 "parsed ZERO entries out of PREMERGE_UNGATED in ${GUARD} — refusing to run a guessed subset"
fi

case "${SET_NAME}" in
  e2e) SUITES="$(printf '%s\n' "${ALL_UNGATED}" | grep -a '/test-e2e-' || true)" ;;
  all) SUITES="${ALL_UNGATED}" ;;
  *)   die 1 "E2E_UNGATED_SET must be 'e2e' (default, the 8 browser/Qt suites) or 'all'; got '${SET_NAME}'" ;;
esac

if [ -z "${SUITES}" ]; then
  die 1 "the '${SET_NAME}' selection matched no entry in PREMERGE_UNGATED"
fi

TOTAL="$(printf '%s\n' "${SUITES}" | grep -ac . || true)"
UNGATED_TOTAL="$(printf '%s\n' "${ALL_UNGATED}" | grep -ac . || true)"

# ── refuse before doing anything ─────────────────────────────────────────────
FOOTPRINT_BEFORE="$(live_footprint)"

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
  if [ -z "${FOOTPRINT_BEFORE}" ]; then
    printf '%s\n' "   live '${LIVE_PREFIX}' footprint: none — a real run would proceed"
  elif [ "${ALLOW_LIVE}" = "1" ]; then
    printf '%s\n' "   live '${LIVE_PREFIX}' footprint: PRESENT, override set — a real run would proceed and census it"
    printf '     %s\n' ${FOOTPRINT_BEFORE}
  else
    printf '%s\n' "   live '${LIVE_PREFIX}' footprint: PRESENT — a real run would REFUSE (exit 3)"
    printf '     %s\n' ${FOOTPRINT_BEFORE}
  fi
  exit 0
fi

if [ -n "${FOOTPRINT_BEFORE}" ] && [ "${ALLOW_LIVE}" != "1" ]; then
  printf '%s\n' "REFUSED: a live '${LIVE_PREFIX}' footprint is up on this box:"
  printf '  %s\n' ${FOOTPRINT_BEFORE}
  printf '%s\n' "  This lane will not run beside it. Nothing was started and nothing was stopped."
  printf '%s\n' "  Bring it down yourself if you want the lane, or — having read the header's"
  printf '%s\n' "  measurement that no ungated suite starts a stack — re-run with:"
  printf '%s\n' "      E2E_UNGATED_ALLOW_LIVE_STACK=1 make e2e-ungated"
  printf '%s\n' "  which keeps every other protection and additionally fails the run if the"
  printf '%s\n' "  footprint above changes while the lane is running."
  exit 3
fi

mkdir -p "${RUN_DIR}"
: >"${RUN_LOG}"

say "== ungated lane ${RUN_ID} =="
say "   set          : ${SET_NAME} (${TOTAL} of ${UNGATED_TOTAL} PREMERGE_UNGATED suites)"
say "   repo         : ${REPO}"
say "   evidence     : ${RUN_DIR}"
say "   strict-skips : ${STRICT}"
if [ -n "${FOOTPRINT_BEFORE}" ]; then
  say "   live stack   : OVERRIDDEN — proceeding beside $(printf '%s' "${FOOTPRINT_BEFORE}" | tr '\n' ' ')"
else
  say "   live stack   : none detected (no '${LIVE_PREFIX}' container or kind cluster)"
fi
say ""

PASS=0
FAIL=0
SKIP=0
ERR=0
VERDICTS=""

for rel in ${SUITES}; do
  abs="${REPO}/${rel}"
  base="$(basename "${rel}" .sh)"
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
  ( cd "${REPO}" && bash "${abs}" ) >"${slog}" 2>&1 || rc=$?
  case "${rc}" in
    0) say "PASS   ${rel}"                    ; VERDICTS="${VERDICTS}PASS   ${rel}"$'\n'   ; PASS=$((PASS + 1)) ;;
    1) say "FAIL   ${rel}   -> ${slog}"       ; VERDICTS="${VERDICTS}FAIL   ${rel}"$'\n'   ; FAIL=$((FAIL + 1)) ;;
    2) say "SKIP   ${rel}   (SKIPPED-LOUDLY; prerequisite missing) -> ${slog}"
       VERDICTS="${VERDICTS}SKIP   ${rel}"$'\n'                                            ; SKIP=$((SKIP + 1)) ;;
    *) say "ERROR  ${rel}   (exit ${rc}) -> ${slog}"
       VERDICTS="${VERDICTS}ERROR  ${rel} (exit ${rc})"$'\n'                               ; ERR=$((ERR + 1)) ;;
  esac
  # the last few lines of a red suite, inline, so the terminal is useful without
  # opening the log
  if [ "${rc}" != "0" ] && [ "${rc}" != "2" ]; then
    tail -n 12 "${slog}" 2>/dev/null | sed 's/^/       | /' | tee -a "${RUN_LOG}"
  fi
done

FOOTPRINT_AFTER="$(live_footprint)"

say ""
say "== verdicts =="
printf '%s' "${VERDICTS}" | sed 's/^/  /' | tee -a "${RUN_LOG}"
say ""
say "== RESULT: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped, ${ERR} errored (of ${TOTAL}) =="
say "   evidence: ${RUN_DIR}"

if [ "${FOOTPRINT_BEFORE}" != "${FOOTPRINT_AFTER}" ]; then
  say ""
  say "LANE VIOLATION: the '${LIVE_PREFIX}' footprint CHANGED while the lane ran."
  say "   before: $(printf '%s' "${FOOTPRINT_BEFORE}" | tr '\n' ' ')"
  say "   after : $(printf '%s' "${FOOTPRINT_AFTER}"  | tr '\n' ' ')"
  say "   Some suite in the '${SET_NAME}' set touched the live stack. That is the"
  say "   thing #246 said must never happen; fix the suite, do not relax this check."
  exit 4
fi

[ "${FAIL}" -gt 0 ] && exit 1
[ "${ERR}"  -gt 0 ] && exit 1
if [ "${SKIP}" -gt 0 ] && [ "${STRICT}" = "1" ]; then
  say "E2E_UNGATED_STRICT=1 and ${SKIP} suite(s) skipped — reporting red."
  exit 1
fi
exit 0

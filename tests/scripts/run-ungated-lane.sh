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
#   E2E_UNGATED_SET=all   (DEFAULT)  every PREMERGE_UNGATED entry — 24 of 24
#                                    today; the runner prints the live count
#                                    every run and hardcodes no number. Operator
#                                    decision 32c on #347, 2026-09-17: the
#                                    default is 22, NOT the 8 that shipped. It
#                                    therefore sweeps in the stack, kind,
#                                    casdoor, pentest, eso and liquibase suites
#                                    that are ungated for their OWN reasons and
#                                    were NOT what #246 asked for. See WHAT THIS
#                                    DEFAULT COSTS, below.
#   E2E_UNGATED_SET=e2e              only the tests/scripts/test-e2e-*.sh
#                                    entries — the browser/Qt family #246 was
#                                    written about, 8 of 22 today. This is the
#                                    old default and is now an explicit opt-in.
#   E2E_UNGATED_DRY_RUN=1            print the selection and whether a real run
#                                    would be allowed beside whatever is up, then
#                                    stop. Executes no suite. This is how you
#                                    verify the wiring without a twenty-minute lane.
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
# DURATION. The E2E_UNGATED_SET=e2e subset was measured 2026-09-16 on the
# operator's box with the toolchain present: ~21 minutes, coverage-matrix alone
# ~9 min. THE 22-SUITE DEFAULT HAS NOT BEEN TIMED END TO END — it is that ~21
# minutes plus fourteen more suites, so treat it as "longer than twenty minutes,
# upper bound unmeasured" until somebody runs it and replaces this sentence with
# a number. It is not a two-minute smoke either way. Even the suite-by-suite
# SHAPE of a real 22-suite run is unknown: nobody has run the lane to completion
# since the default moved (the refusal fires while the operator's hugmesh-local
# cluster is up, which is correct and is also why it cannot be exercised here),
# tests/pentest/nuclei/test-templates.sh SKIPs on this box for want of nuclei
# v3.9.0, and tests/casdoor/test-jwt-custom-token.sh has never been run by
# anyone measuring this default.
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
#   * tests/scripts/test-e2e-env-interface-dimensions.sh's M7 control
#     (m7_standin_start, :1006) runs
#         docker run -d --name e2eguard-m7-<pid>-control-plane -p 127.0.0.1::80 python:3.12-slim
#     as a loopback http.server stand-in and removes ONLY that naming shape
#     (`^e2eguard-m7-[0-9]+-control-plane$`, :999/:1003-1005). It is
#     self-contained, cannot reach a hugmesh-local container, and the census
#     above does not count it (wrong prefix) — a real run on 2026-09-16 saw it
#     start and remove itself with the footprint unchanged.
#   * tests/casdoor/test-jwt-custom-token.sh starts TWO containers on a private
#     network — `casdoor-pg` (postgres) and `casdoor-jwtcustom-test`
#     (casbin/casdoor) — and removes both plus the network in an EXIT trap. Its
#     names are FIXED, not pid-suffixed, so two concurrent runs of this lane
#     collide and a run killed before its trap leaves them behind for the next
#     one to trip over. This suite was NOT in the default set before decision
#     32c; it is now.
#   * everything else is a READ: `docker ps` (the M7 suite), `docker compose
#     config` (tests/stack/test-web-locales-wiring.sh), `kubectl` against
#     whatever context is current (test-kind-metrics-api.sh, which SKIPS unless
#     a kind cluster named hugmesh-local is up — and the refusal above means it
#     can therefore only ever SKIP in this lane), plus one throwaway node
#     fixture on its own loopback port (tests/pentest/nuclei/test-templates.sh).
#     tests/scripts/test-selected-services-only.sh is static analysis of the
#     boot scripts; the `kubectl apply` strings in it are the text it inspects,
#     not commands it runs.
# The refusal is a floor, not a diagnosis: it is here so that a future suite
# which DOES start something with the live prefix cannot arrive quietly.
#
# WHAT THE 32c DEFAULT COSTS — RE-MEASURED 2026-09-17, recorded rather than
# worked around. Widening the default from the 8 browser/Qt suites to all 22
# pulls in suites that were ungated for reasons of their OWN, not for a missing
# toolchain.
#
# THE FIRST DRAFT OF THIS PARAGRAPH SAID "three of the fourteen", from three
# suites run inside a git worktree. That number was WRONG and a skeptic pass
# caught it. Half of these suites change verdict with their checkout's POSITION:
# they look for a sibling checkout at ${REPO}/.., or for ${REPO}/.stack-src, and
# a worktree under /home/magus/.hugmesh-wt-* has neither, so they report
# INCOMPLETE there and pass in the real tree. tests/stack/test-gateway-auth-flag-parity.sh
# was named as one of the three reds and is GREEN in the real position — it was
# a measurement artefact, not a defect. Do not re-measure this list from a
# worktree.
#
# ALL FOURTEEN, one at a time, from a checkout whose siblings and .stack-src
# resolve exactly as they do in the operator's own tree:
#     tests/scripts/test-selected-services-only.sh         rc=1  58 passed, 5 failed
#     tests/scripts/test-optional-service-slug-closure.sh  rc=1  the admin-bff registry parsed ZERO entries
#         (that was the checker's own stale regex, fixed by #584 on 2026-09-23; it is
#         still rc=1, now on two real controller facts filed as hugmesh-admin-bff-api#106)
#     tests/scripts/test-liquibase-grant-roles.sh          rc=1  2 of its own negative controls got rc=0 where they demand 3
#     tests/egress-vpn/test-secret-contract.sh             rc=1  52 passed, 1 failed (UN-ASSERTED contract copy)
#     tests/scripts/test-eso-target-collisions.sh          rc=1  cassandra 12.3.11 will not render, so the inventory is empty
#     tests/device-registry/test-layer-a-headscale-acl.sh  rc=3  INCOMPLETE: HeadscaleAclCompiler.java is not in the sibling checkout
#     tests/pentest/nuclei/test-templates.sh               rc=2  SKIP, nuclei v3.9.0 is not installed here
#     tests/scripts/test-kind-metrics-api.sh               rc=0  ONLY because a kind cluster is up; see below
#     tests/scripts/test-federation-module-slugs.sh        rc=0
#     tests/scripts/test-service-env-contract.sh           rc=0
#     tests/stack/test-gateway-auth-flag-parity.sh         rc=0
#     tests/stack/test-m2-bootstrap.sh                     rc=0
#     tests/stack/test-web-locales-wiring.sh               rc=0
#     tests/casdoor/test-jwt-custom-token.sh               NOT RUN — it starts two containers (see the inventory above), so its
#                                                          verdict in this lane is still unknown to everybody
#
# SO: FIVE red and ONE incomplete out of the thirteen that were measured, with
# the fourteenth unmeasured — not three. Each of the six is a REAL platform or
# checkout defect naming itself, not a suite bug (.gitlab-ci.yml documents the
# selected-services job as "RED on today's main … five checks, each naming a
# live defect"; the others say so in their own headers). A suite that exits
# non-zero makes the LANE exit 1, so `make e2e-ungated` is RED BY DEFAULT until
# those defects are fixed, and its red cannot distinguish "something broke" from
# "the known six". That is the cost of the operator's answer to decision 32c and
# it is theirs to carry; do NOT narrow the default back to make the lane green.
# If it needs to be actionable before those defects land, the honest shapes are
# an explicit expected-red allowlist in this runner or fixing the six — both are
# decisions nobody has made.
#
# TWO ENTRIES ABOVE ARE NOT WHAT THEY LOOK LIKE INSIDE A REAL LANE RUN:
#   * test-kind-metrics-api.sh is rc=0 only because the operator's hugmesh-local
#     kind cluster is up while it is run DIRECTLY. Inside this lane that state
#     is exactly the state the exit-3 refusal forbids, so in a lane run this
#     suite can only ever SKIP. Its rc=0 above is not a lane verdict.
#   * test-layer-a-headscale-acl.sh exits 3, which this runner classifies as
#     INCOMPLETE — see the EXIT CODES block below for why that verdict had to be
#     added, and why it is still red.
#
# EXIT CODES, per suite and overall. The suites already distinguish these and
# the distinction is the whole point of a routine run — a lane that cannot tell
# "red" from "the toolchain is missing" trains everyone to ignore it.
#   0  PASS        the suite ran and was green
#   1  FAIL        the suite ran and was red            -> lane exits 1
#   2  SKIP        SKIPPED-LOUDLY, prerequisite missing -> lane exits 0 unless
#                  E2E_UNGATED_STRICT=1, which makes any SKIP red
#   3  INCOMPLETE  the suite RAN, asserted some of what it claims to and could
#                  not reach the rest, and says so rather than passing on the
#                  part it did check -> lane exits 1. THIS VERDICT WAS ADDED
#                  BECAUSE OF DECISION 32c. Before it the runner had no third
#                  red-ish bucket and printed "ERROR … (exit 3)", which reads as
#                  a crash, for a suite that ran perfectly; and it collided in
#                  the reader's eye with the LANE's own exit 3 ("refused beside a
#                  live stack") two lines below. At least three suites the 22
#                  default pulls in document exit 3 this way in their own
#                  headers: tests/device-registry/test-layer-a-headscale-acl.sh
#                  (:365 "INCOMPLETE (exit 3), never a silent skip"),
#                  tests/egress-vpn/test-secret-contract.sh (:542/:572/:593
#                  "INCOMPLETE … This is a FAILURE, not a skip") and
#                  tests/scripts/test-federation-module-slugs.sh (:250). It is
#                  RED, never tolerated the way a SKIP is, and STRICT does not
#                  enter into it.
#   *  ERROR       anything else (crash, 124 timeout, 126/127) -> lane exits 1
# The lane's own verdicts:
#   3  refused: a live footprint under a watched prefix was detected
#   4  the footprint changed while the lane ran (a suite brought one up)
#   5  refused: the footprint could not be determined (census tool failed)
#   6  VACUOUS: suites were selected and NOT ONE passed (every one skipped). A
#      lane that asserted nothing is not green, STRICT or not — on a checkout
#      without tests/e2e/node_modules this is what `make e2e-ungated` prints,
#      and before 2026-09-16 it exited 0.
#   7  INTERRUPTED: SIGINT/SIGTERM/SIGHUP reached the lane. It prints the
#      verdicts it had reached, marks the evidence directory PARTIAL, and tears
#      NOTHING down — same as every other path. (hugmesh-generator#397 item 2:
#      before this the lane died silently mid-suite, leaving a dated directory
#      with no run.log verdict table and no statement of where it stopped.)
#      NOTE, measured not assumed: bash runs a trap only when the FOREGROUND
#      command returns, so a `kill -TERM` aimed at this PID alone is acted on
#      when the suite that is running finishes or is killed by
#      E2E_UNGATED_SUITE_TIMEOUT, not instantly. A ctrl-C at a terminal reaches
#      the whole foreground process group, so the suite dies at once and its own
#      EXIT trap runs; a signal aimed at this PID alone does NOT reach the
#      suite, and tests/casdoor/test-jwt-custom-token.sh leaves casdoor-pg and
#      casdoor-jwtcustom-test behind in exactly that case. The handler says so.
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
# loosened, the 32a watch list narrowed back, the 32b override reinstated, the
# 32c default narrowed back, the empty-watch-list guard dropped, the INCOMPLETE
# bucket folded back into ERROR, the literal prefix match turned back into a
# glob, the signal trap deleted) to prove each protection is load-bearing.
# Change a behaviour here and that suite is where it goes red.
#
# This file is a RUNNER, not a suite: it is named run-*.sh so the test-*.sh /
# *_test.sh census in test-guard-integrity.sh does not count it as a suite and
# inflate the coverage denominator with something that has no assertions of its
# own.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
GUARD="${HERE}/test-guard-integrity.sh"

# DECISION 32c (#347, 2026-09-17): the DEFAULT SPEC COUNT is 22, not the 8
# that shipped — i.e. the default selection is every PREMERGE_UNGATED entry.
# This is the one place the default lives; everything else derives or prints it.
UNGATED_DEFAULT_SET="all"
SET_NAME="${E2E_UNGATED_SET:-${UNGATED_DEFAULT_SET}}"
STRICT="${E2E_UNGATED_STRICT:-0}"
# DECISION 32a (#347, 2026-09-17): BOTH live shapes by default, not just the
# one #246 named. A space-separated LIST; see the header.
UNGATED_DEFAULT_LIVE_PREFIXES="hugmesh-local hugmesh-real"
LIVE_PREFIX="${E2E_UNGATED_LIVE_PREFIX:-${UNGATED_DEFAULT_LIVE_PREFIXES}}"
# Split ONCE, here, with `read -a`: it splits on IFS and does NOT glob, whereas
# an unquoted `for pfx in ${LIVE_PREFIX}` is subject to pathname expansion. That
# is not theoretical — measured 2026-09-17 from the repo root,
# E2E_UNGATED_LIVE_PREFIX='M*' censused the glob-expanded `Makefile` while the
# rendered label still said `[M*]`, i.e. the message did not describe what was
# censused. The prefixes are also matched LITERALLY below (a `case` pattern from
# a quoted expansion, and `=` for kind), never as a regex: `grep "^${pfx}"` made
# a `.` or a `[` in a custom prefix match more than the caller asked for.
read -r -a LIVE_PREFIXES <<<"${LIVE_PREFIX}"
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
  local nm
  names=""
  errs=""
  errf="$(mktemp -t ungated-census.XXXXXX)"
  if command -v docker >/dev/null 2>&1; then
    if out="$(docker ps --format '{{.Names}}' 2>"${errf}")"; then
      while IFS= read -r nm; do
        [ -n "${nm}" ] || continue
        for pfx in ${LIVE_PREFIXES[@]+"${LIVE_PREFIXES[@]}"}; do
          # quoted expansion inside a case pattern = a LITERAL string; the
          # trailing * is the only wildcard, so this is an exact prefix match
          case "${nm}" in "${pfx}"*) names="${names}${nm}"$'\n'; break ;; esac
        done
      done <<<"${out}"
    else
      errs="${errs}CENSUS-ERROR docker ps failed: $(head -n 1 "${errf}" | cut -c1-160)"$'\n'
    fi
  fi
  if command -v kind >/dev/null 2>&1; then
    if out="$(kind get clusters 2>"${errf}")"; then
      while IFS= read -r nm; do
        [ -n "${nm}" ] || continue
        for pfx in ${LIVE_PREFIXES[@]+"${LIVE_PREFIXES[@]}"}; do
          # a kind cluster is matched EXACTLY, and by string equality rather
          # than by grep, for the same literal-vs-regex reason
          [ "${nm}" = "${pfx}" ] && { names="${names}kind-cluster:${pfx}"$'\n'; break; }
        done
      done <<<"${out}"
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
  *)   die 1 "E2E_UNGATED_SET must be 'all' (the default since decision 32c: every PREMERGE_UNGATED entry) or 'e2e' (only the test-e2e-* browser/Qt suites); got '${SET_NAME}'" ;;
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

PASS=0
FAIL=0
SKIP=0
INC=0
ERR=0
VERDICTS=""

# ── the signal trap (hugmesh-generator#397, item 2) ──────────────────────────
# Before this the lane died where it stood on INT/TERM/HUP: no verdict table in
# run.log, a dated evidence directory that looked complete, and no statement of
# where it stopped. It now prints what it had reached and marks the directory
# PARTIAL. It tears NOTHING down here either — that is true of every path in
# this file, and an interrupt is the last moment to start making exceptions.
# Installed AFTER the counters exist so the handler can read them, and after the
# evidence directory exists so say() can write to run.log.
LANE_SIGNALLED=0
on_signal() {
  local sig
  sig="$1"
  # a second signal while the handler runs must not re-enter it
  [ "${LANE_SIGNALLED}" = "1" ] && exit 7
  LANE_SIGNALLED=1
  trap - INT TERM HUP
  say ""
  say "== INTERRUPTED (SIG${sig}) =="
  say "   reached: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped, ${INC} incomplete, ${ERR} errored (of ${TOTAL})"
  if [ -n "${VERDICTS}" ]; then
    say "== verdicts so far =="
    printf '%s' "${VERDICTS}" | sed 's/^/  /' | tee -a "${RUN_LOG}"
  else
    say "   no suite had finished."
  fi
  say "   evidence: ${RUN_DIR}   (PARTIAL — the lane did not finish)"
  say "   Nothing was torn down: this lane stops no container and no cluster on"
  say "   any path, including this one."
  say "   If you signalled this PID alone rather than the foreground process"
  say "   group, the suite that was running did NOT get the signal and its own"
  say "   EXIT trap has not fired — tests/casdoor/test-jwt-custom-token.sh"
  say "   leaves casdoor-pg and casdoor-jwtcustom-test behind in exactly that"
  say "   case, and their names are fixed."
  exit 7
}
trap 'on_signal INT'  INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP'  HUP

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
    # exit 3 is a THIRD documented verdict in several of the suites decision 32c
    # pulled into the default set: the suite RAN, asserted part of what it
    # claims to, and refuses to report the rest as checked. "ERROR (exit 3)"
    # described that as a crash and collided with this lane's own exit 3. It is
    # still RED — a lane exit of 1 — and STRICT has nothing to do with it.
    3) say "INCOMPLETE ${rel}   (exit 3: the suite ran and could not reach part of what it asserts) -> ${slog}"
       VERDICTS="${VERDICTS}INCOMPLETE ${rel}"$'\n'                                        ; INC=$((INC + 1)) ;;
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
say "== RESULT: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped, ${INC} incomplete, ${ERR} errored (of ${TOTAL}) =="
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
[ "${INC}"  -gt 0 ] && exit 1
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

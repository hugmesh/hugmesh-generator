#!/usr/bin/env bash
# run.sh — THE ONE command line for this repo's Playwright e2e, legacy specs and
# Gherkin lane alike, against any of the three meshes.
#
# WHY THIS GREW. There were already two divergent invocations of one suite (this
# script for the handwritten specs; the Makefile's stack-e2e-bdd recipe for the
# Gherkin lane) and the operator asked for a third and fourth — kind and qemu,
# from the CLI, with evidence. Four invocation paths that drift is a defect this
# repo has been bitten by before, so the Makefile targets now DELEGATE here and
# this file is the only place that knows how to spell a run.
#
# BACKWARD COMPATIBILITY IS ASSERTED, NOT HOPED FOR. With no new flag this
# script behaves EXACTLY as it did: docker image if present, host npx otherwise,
# every argument forwarded to playwright verbatim, SNAP_BASE_URL untouched, and
# the process exit code is playwright's. tests/qemu/run-qemu-e2e.sh and
# tests/e2e/run-all.sh both call it that way and are unchanged.
#   tests/scripts/test-e2e-cli-lane.sh is the gate; it drives this script with a
#   stub `npx` on PATH and reads the ARGV that really came out, because grepping
#   a script for a token proves the token is present, not that it is forwarded.
#
# THIS SCRIPT STARTS NOTHING. Not a compose stack, not a kind cluster, not an
# emulator. It resolves where a mesh WOULD be, tells you exactly what to run to
# bring it up, and lets the suite skip loudly. `--print-command` shows the whole
# plan without executing any of it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

# ── defaults: the pre-existing behaviour, spelled out ────────────────────────
LANE=legacy          # legacy = today's run (both projects, testDir ./specs + bdd)
MODE=run             # run | list | gen | print | evidence
ENV_ID=""            # empty = do not touch SNAP_BASE_URL / SNAP_ENV at all
TAGS=""
JSON=0
GENERATE=""          # "" = decided by lane; 1/0 = forced
FEATURES=()
PW_ARGS=()
IMAGE="${PW_IMAGE:-hugmeshgames-e2e:latest}"

usage() {
  cat <<'USAGE'
Usage: tests/e2e/run.sh [options] [-- ] [playwright args...]

  Runs this repo's Playwright e2e. With NO options it behaves exactly as it
  always has: the whole suite against SNAP_BASE_URL (default
  https://localhost:8443), every argument forwarded to playwright.

Lane
  --bdd                    run the GHERKIN lane only (--project=bdd), compiling
                           tests/e2e/features/**/*.feature with bddgen first
  --tags <expr>            Gherkin tag expression (bddgen --tags); implies --bdd
                           e.g. '@interface:cli', '@env:qemu and not @wip'
  --features <path>        restrict to a feature path; repeatable; implies --bdd
                           'features/cli/', 'cli/' and 'cli/x.feature' all work

Environment (which mesh)   THIS SCRIPT NEVER STARTS ONE
  --env docker             the local docker compose stack (tests/stack)
                             start: make stack-up ENV=test  (then: make stack-seed)
  --env kind               the local devops kind cluster (kind-hugmesh-local)
                             start: make kind-images && make kind-up
  --env qemu               a QEMU-emulated device
                             start: bash tests/qemu/run-qemu-e2e.sh --target x86 --img <image>
  (omit --env to leave SNAP_BASE_URL/SNAP_ENV exactly as the caller set them)

Modes
  --gen                    compile the features and stop
  --list                   list the collected tests and stop (runs nothing)
  --print-command          print the whole plan as JSON and stop (executes nothing)
  --evidence               summarise THIS run dir's evidence manifest and stop
  --json                   machine-readable output for --evidence

Evidence
  --report-dir <dir>       SNAP_REPORT_DIR  (junit/json/summary + bdd-steps/)
  --run-id <id>            SNAP_RUN_ID      (the per-run evidence subdirectory)
  after a run, the evidence summary is printed automatically;
  SNAP_EVIDENCE_SUMMARY=0 turns that off.

  -h, --help               this text
USAGE
}

die() { echo "run.sh: $*" >&2; exit 2; }

# ── environment table ────────────────────────────────────────────────────────
# The SAME env vars and the SAME defaults as tests/e2e/steps/dimensions.ts's
# ENVIRONMENT_DEFS. Two resolvers for one fact is a drift risk, so the guard
# asserts they agree by RESOLVING BOTH and comparing, rather than by trusting
# this comment.
env_base_url() {
  local id="$1"
  local url=""
  case "${id}" in
    docker) url="${SNAP_ENV_DOCKER_BASE_URL:-${SNAP_BASE_URL:-https://localhost:8443}}" ;;
    kind)   url="${SNAP_ENV_KIND_BASE_URL:-https://hugmesh.net:8443}" ;;
    qemu)   url="${SNAP_ENV_QEMU_BASE_URL:-https://localhost:${SNAP_QEMU_UI_PORT:-${UI_PORT:-8443}}}" ;;
    *)      return 1 ;;
  esac
  echo "${url}" | sed 's:/*$::'
}

env_start_hint() {
  case "$1" in
    docker) echo 'make stack-up ENV=test   (then: make stack-seed)' ;;
    kind)   echo 'make kind-images && make kind-up   (bootstrap-kind.sh, KIND_PROFILE=sso)' ;;
    qemu)   echo 'bash tests/qemu/run-qemu-e2e.sh --target x86 --img <image>   (or --target pi); the forwarded UI port is --ui-port, default 8443' ;;
  esac
}

LEGAL_ENVS='docker, kind, qemu'

# ── argument parsing ─────────────────────────────────────────────────────────
# Anything this script does not recognise is a playwright argument, which is how
# every existing caller keeps working.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --bdd|--gherkin)   LANE=bdd; shift ;;
    --env)             [ "$#" -ge 2 ] || die "--env needs a value (${LEGAL_ENVS})"
                       ENV_ID="$2"; shift 2 ;;
    --env=*)           ENV_ID="${1#--env=}"; shift ;;
    --tags)            [ "$#" -ge 2 ] || die "--tags needs a tag expression"
                       TAGS="$2"; LANE=bdd; shift 2 ;;
    --tags=*)          TAGS="${1#--tags=}"; LANE=bdd; shift ;;
    --features)        [ "$#" -ge 2 ] || die "--features needs a path"
                       FEATURES+=("$2"); LANE=bdd; shift 2 ;;
    --features=*)      FEATURES+=("${1#--features=}"); LANE=bdd; shift ;;
    --gen)             MODE=gen; LANE=bdd; shift ;;
    --list)            MODE=list; shift ;;
    --print-command)   MODE=print; shift ;;
    --evidence)        MODE=evidence; shift ;;
    --json)            JSON=1; shift ;;
    --report-dir)      [ "$#" -ge 2 ] || die "--report-dir needs a directory"
                       export SNAP_REPORT_DIR="$2"; shift 2 ;;
    --report-dir=*)    export SNAP_REPORT_DIR="${1#--report-dir=}"; shift ;;
    --run-id)          [ "$#" -ge 2 ] || die "--run-id needs an id"
                       export SNAP_RUN_ID="$2"; shift 2 ;;
    --run-id=*)        export SNAP_RUN_ID="${1#--run-id=}"; shift ;;
    -h|--help)         usage; exit 0 ;;
    --)                shift; while [ "$#" -gt 0 ]; do PW_ARGS+=("$1"); shift; done ;;
    *)                 PW_ARGS+=("$1"); shift ;;
  esac
done

# ── environment forwarding ───────────────────────────────────────────────────
# An unknown value dies here NAMING THE LEGAL SET, the same contract
# steps/dimensions.ts holds. A typo'd --env must never silently fall through to
# the default mesh and produce a green run against the wrong thing.
ENV_BASE_URL=""
ENV_HINT=""
if [ -n "${ENV_ID}" ]; then
  ENV_BASE_URL="$(env_base_url "${ENV_ID}")" \
    || die "unknown --env ${ENV_ID}. Legal environments: ${LEGAL_ENVS}. (The same set steps/dimensions.ts ENVIRONMENTS spells; 'compose', 'k8s' and 'vm' are deliberately NOT accepted.)"
  ENV_HINT="$(env_start_hint "${ENV_ID}")"
  export SNAP_ENV="${ENV_ID}"
  export SNAP_BASE_URL="${ENV_BASE_URL}"
  # The kind ingress matches on Host and hugmesh.net does not resolve on a dev
  # box, so chromium needs the resolver map `make kind-e2e` already passes.
  # Set, never overwritten: an operator who exported their own map means it.
  if [ "${ENV_ID}" = "kind" ] && [ -z "${SNAP_HOST_RESOLVER:-}" ]; then
    export SNAP_HOST_RESOLVER='MAP hugmesh.net 127.0.0.1, MAP *.hugmesh.net 127.0.0.1'
  fi
fi

# ── feature selection ────────────────────────────────────────────────────────
# A feature path the operator types is a SOURCE path ('features/cli/'); what
# playwright collects is the GENERATED mirror under .features-gen/. Translating
# here is what lets `--features cli/` mean the obvious thing.
GEN_DIR=".features-gen"
SELECTED=()
for f in "${FEATURES[@]+"${FEATURES[@]}"}"; do
  case "${f}" in
    ${GEN_DIR}/*) SELECTED+=("${f}") ;;
    features/*)   SELECTED+=("${GEN_DIR}/${f}") ;;
    /*)           SELECTED+=("${f}") ;;
    *)            SELECTED+=("${GEN_DIR}/features/${f}") ;;
  esac
done

# ── what would run ───────────────────────────────────────────────────────────
[ -n "${GENERATE}" ] || { if [ "${LANE}" = "bdd" ]; then GENERATE=1; else GENERATE=0; fi; }

GEN_ARGV=(npx bddgen test)
[ -z "${TAGS}" ] || GEN_ARGV+=(--tags "${TAGS}")

# `[ x ] && cmd` is NOT used below: under `set -e` a false test makes the whole
# list return 1 and kills the script. Every conditional here is a real `if`.
PW_ARGV=(npx playwright test -c playwright.config.ts)
if [ "${LANE}" = "bdd" ]; then PW_ARGV+=(--project=bdd); fi
if [ "${MODE}" = "list" ]; then PW_ARGV+=(--list); fi
PW_ARGV+=("${PW_ARGS[@]+"${PW_ARGS[@]}"}")
PW_ARGV+=("${SELECTED[@]+"${SELECTED[@]}"}")

REPORT_DIR="${SNAP_REPORT_DIR:-test-results}"
RUN_ID="${SNAP_RUN_ID:-dev}"

# ── --evidence / post-run summary ────────────────────────────────────────────
evidence_report() {
  local extra=()
  if [ "${JSON}" -eq 1 ]; then extra+=(--json); fi
  node "${HERE}/evidence-report.mjs" \
    --report-dir "${REPORT_DIR}" --run-id "${RUN_ID}" --cwd "${HERE}" \
    "${extra[@]+"${extra[@]}"}"
}

if [ "${MODE}" = "evidence" ]; then
  evidence_report
  exit $?
fi

if [ "${MODE}" = "print" ]; then
  # A plan, as JSON, with nothing executed. Built with node so the quoting is
  # somebody else's problem; argv arrives on stdin as NUL-free lines because a
  # newline in a playwright argument is not a thing this suite has ever had.
  {
    printf 'ENV_ID\t%s\n' "${ENV_ID}"
    printf 'BASE_URL\t%s\n' "${ENV_BASE_URL}"
    printf 'HINT\t%s\n' "${ENV_HINT}"
    printf 'LANE\t%s\n' "${LANE}"
    printf 'GENERATE\t%s\n' "${GENERATE}"
    printf 'TAGS\t%s\n' "${TAGS}"
    printf 'REPORT_DIR\t%s\n' "${REPORT_DIR}"
    printf 'RUN_ID\t%s\n' "${RUN_ID}"
    printf 'HOST_RESOLVER\t%s\n' "${SNAP_HOST_RESOLVER:-}"
    for a in "${SELECTED[@]+"${SELECTED[@]}"}"; do printf 'FEATURE\t%s\n' "${a}"; done
    for a in "${GEN_ARGV[@]}"; do printf 'GENARGV\t%s\n' "${a}"; done
    for a in "${PW_ARGV[@]}"; do printf 'ARGV\t%s\n' "${a}"; done
  } | node "${HERE}/print-plan.mjs"
  exit 0
fi

# ── execution ────────────────────────────────────────────────────────────────
if [ "${GENERATE}" -eq 1 ]; then
  # bddgen is missingSteps:fail-on-gen. A failure here means a .feature binds to
  # a step nobody defines, and running anyway would collect a SMALLER suite and
  # look green. Refuse, loudly, with the generator's own exit code.
  ( cd "${HERE}" && "${GEN_ARGV[@]}" ) || {
    rc=$?
    echo "run.sh: bddgen FAILED (rc=${rc}). NOT running the suite — a partially" >&2
    echo "        generated lane collects fewer scenarios and looks green." >&2
    exit "${rc}"
  }
fi
if [ "${MODE}" = "gen" ]; then exit 0; fi

if [ -n "${ENV_ID}" ]; then
  echo "==> env=${ENV_ID}  base=${ENV_BASE_URL}"
  echo "    (not started by this script; to bring it up: ${ENV_HINT})"
fi

# ── the seeded password, RESOLVED, never generated (kept from main) ───────────
# This lane drives an ALREADY-RUNNING stack, so the password must be the one that
# stack was seeded with; minting a fresh one here would simply not match and every
# login would fail for a reason nothing names. Env, else the run-state file, else
# stop and say what to run.
#
# Only for MODE=run: --print-command/list/gen execute nothing and must not demand
# a credential. And it must be passed EXPLICITLY into the container — the docker
# invocation below mounts only ${HERE} at /work/e2e, so a repo-root
# .e2e-credentials is invisible inside and the helpers' walk-up cannot reach it.
if [ "${MODE}" = "run" ] && [ -z "${E2E_PASSWORD:-}" ]; then
  . "${HERE}/../stack/e2e-password.sh"
  E2E_PASSWORD="$(e2e_password_read E2E_PASSWORD)" || exit 1
  export E2E_PASSWORD
fi
if [ "${MODE}" = "run" ] && [ -z "${E2E_PASSWORD:-}" ]; then
  echo "run.sh: no e2e password resolved (checked \$E2E_PASSWORD and ${E2E_CREDENTIALS_FILE:-<repo>/.e2e-credentials})." >&2
  echo "  This lane drives an already-running stack, so it will not mint one." >&2
  echo "  Seed the stack first: make stack-seed" >&2
  exit 1
fi

mkdir -p "${HERE}/screenshots"

# The bundled-browser docker image is a BROWSERS image with only tests/e2e
# mounted. The Gherkin lane's cli and studio interfaces shell out to the repo
# (make targets, python3 -m hugmesh_studio), so it cannot host that lane. Say so
# instead of running a crippled suite that skips half its interfaces.
USE_DOCKER=0
if [ "${LANE}" != "bdd" ] && docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  USE_DOCKER=1
elif [ "${LANE}" = "bdd" ] && docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  echo "==> ${IMAGE} exists but the Gherkin lane runs on the HOST: its cli/studio" >&2
  echo "    interfaces drive repo commands the browsers image does not carry." >&2
fi

set +e
if [ "${USE_DOCKER}" -eq 1 ]; then
  docker run --rm --network host --ipc=host \
    -v "${HERE}:/work/e2e" -w /work/e2e \
    -e SNAP_BASE_URL="${SNAP_BASE_URL:-https://localhost:8443}" -e SNAP_SHOTS=/work/e2e/screenshots \
    -e E2E_PASSWORD="${E2E_PASSWORD:-}" \
    "${IMAGE}" "${PW_ARGV[@]}"
else
  ( cd "${HERE}" && SNAP_SHOTS="${SNAP_SHOTS:-${HERE}/screenshots}" "${PW_ARGV[@]}" )
fi
rc=$?
set -e

# The summary is a courtesy. It must never change the verdict: `rc` is captured
# above and is what this script exits with, whatever the reporter does. An
# exit-code-swallowing test lane is the worst outcome available here, so the
# guard plants exactly that mutation and requires it to go red.
if [ "${LANE}" = "bdd" ] && [ "${MODE}" = "run" ] && [ "${SNAP_EVIDENCE_SUMMARY:-1}" != "0" ]; then
  echo
  evidence_report || true
fi

exit "${rc}"

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
VIA="${E2E_VIA:-}"   # "" = the mesh's own door; onion = through Tor (see --via)
IMAGE="${PW_IMAGE:-hugmeshgames-e2e:latest}"

# ── the docker mesh's host door: ONE knob, the same one the TypeScript reads ──
# tests/stack/compose.local.yaml publishes `${PUBLIC_HTTPS_PORT:-8488}:8443`, so
# 8443 is the port INSIDE the tls-front container and the door on the HOST is
# PUBLIC_HTTPS_PORT (Makefile: `PUBLIC_HTTPS_PORT ?= 8488`, threaded into the
# stack through STACK_ENV and into the suite by `make stack-e2e*`). This is the
# identical expression steps/dimensions.ts ENVIRONMENT_DEFS.docker.baseUrl() and
# playwright.config.ts baseURL fall back to, so the resolvers can only drift
# together. Until 2026-09-01 this script said 8443 in THREE places — the usage
# text, the env table below, the bundled-browser docker path — and on a box that
# also runs the kind lane :8443 is the KIND node's nginx, so the bare fallback did
# not knock on a closed door, it named a DIFFERENT MESH (404 from kind, while the
# compose stack answered on 8488). Every run through the Makefile sets
# SNAP_BASE_URL and was always right; only the bare fallbacks were wrong.
#   tests/scripts/test-e2e-cli-lane.sh resolves this table against ENVIRONMENT_DEFS,
#   reads the help text, and records the argv the docker path is handed;
#   tests/scripts/test-e2e-docker-base-url-parity.sh derives the port from the
#   Makefile and executes this script against it.
DOCKER_HOST_PORT="${PUBLIC_HTTPS_PORT:-8488}"
DOCKER_DEFAULT_BASE_URL="https://localhost:${DOCKER_HOST_PORT}"

usage() {
  # A QUOTED heredoc, then ONE placeholder substituted by bash itself: an
  # unquoted heredoc would expand every $ and backtick in the text, a trap this
  # repo has already been bitten by. `local` first, assignment second — bash 5.3
  # dies under set -u on `local a=$x b=$a`.
  local text
  text="$(cat <<'USAGE'
Usage: tests/e2e/run.sh [options] [-- ] [playwright args...]

  Runs this repo's Playwright e2e. With NO options it behaves exactly as it
  always has: the whole suite against SNAP_BASE_URL (default
  __DOCKER_DEFAULT_BASE_URL__ — the compose stack's PUBLIC_HTTPS_PORT host door;
  8443 is the port INSIDE its tls-front container), every argument forwarded
  to playwright.

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

Front door (how the browser reaches the mesh)
  --via onion              the docker stack's Tor .onion, THROUGH TOR: the
                           browser dials https://<onion>/ via the SOCKS5 proxy
                           hugmesh-tor-client publishes. Runs ONLY the
                           @via:onion @env:docker scenarios (implies --bdd
                           --env docker).
                             start: make stack-up TOR=1  (then: make stack-seed)
                           onion:  SNAP_ONION_BASE_URL, else the hostname in
                                   SNAP_ONION_HOSTNAME_FILE (default
                                   tests/stack/tor-onion/hostname)
                           proxy:  SNAP_PROXY, else
                                   socks5://127.0.0.1:${TOR_SOCKS_HOST_PORT:-9050}
                           (E2E_VIA=onion is the same switch)
  --via onion --env kind   the KIND lane's .onion (make kind-tor, #577), THROUGH
                           the host tor scripts/kind-tor.sh runs. Runs ONLY the
                           @via:onion @env:kind scenarios.
                             start: make kind-up && make kind-images && make kind-tor
                           onion:  SNAP_ONION_BASE_URL, else `scripts/kind-tor.sh
                                   onion` (which refuses a leftover hostname)
                           proxy:  SNAP_PROXY, else `scripts/kind-tor.sh socks`

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
)"
  printf '%s\n' "${text//__DOCKER_DEFAULT_BASE_URL__/${DOCKER_DEFAULT_BASE_URL}}"
}

die() { echo "run.sh: $*" >&2; exit 2; }

# ── environment table ────────────────────────────────────────────────────────
# The SAME env vars and the SAME defaults as tests/e2e/steps/dimensions.ts's
# ENVIRONMENT_DEFS. Two resolvers for one fact is a drift risk, so the guard
# asserts they agree by RESOLVING BOTH and comparing, rather than by trusting
# this comment. The docker door is DOCKER_DEFAULT_BASE_URL (above), never a
# literal here: the literal is exactly what drifted to 8443.
env_base_url() {
  local id="$1"
  local url=""
  case "${id}" in
    docker) url="${SNAP_ENV_DOCKER_BASE_URL:-${SNAP_BASE_URL:-${DOCKER_DEFAULT_BASE_URL}}}" ;;
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
    --via)             [ "$#" -ge 2 ] || die "--via needs a value (onion)"
                       VIA="$2"; shift 2 ;;
    --via=*)           VIA="${1#--via=}"; shift ;;
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

# ── the front door: --via onion ──────────────────────────────────────────────
# The docker stack's Tor onion (make stack-up TOR=1), reached THROUGH TOR, the
# way a Tor Browser user reaches it (hugmesh-generator#576). Four decisions here,
# each one a trap somebody would otherwise fall into:
#
#  * SNAP_BASE_URL stays the stack's LOCAL door. The @env:docker availability
#    probe (steps/dimensions.ts probeRequest) is a plain Node request with no
#    proxy; pointed at the onion it could never answer, and the scenario would
#    skip with "start the stack" against a running stack. The onion travels as
#    SNAP_ONION_BASE_URL, which only the @via:onion steps read.
#  * The URL is https://<onion>/, never http. The gateway's CSP carries
#    upgrade-insecure-requests: a page entered over http:// has every
#    subresource and fetch() upgraded to https:// (measured 2026-09-23 over a
#    live onion: the script died ERR_SOCKS_CONNECTION_FAILED with :443 absent,
#    the fetch died ERR_FAILED cross-origin with :443 present), so an http entry
#    tests nothing the SPA can do. The onion's :443 is the TLS front.
#  * Only @via:onion @env:docker scenarios run. Every other scenario builds its
#    contexts without the proxy, and a lane that ran them "over Tor" would really
#    have run them over localhost. @env:docker because this is the COMPOSE
#    stack's onion: the kind lane's own @via:onion scenario (#577, @env:kind)
#    would only skip here, and a skip fails this lane (see the summary check
#    below). Both tags are AND-ed onto any --tags given.
#  * `--env kind` selects the KIND lane's onion instead (#577, `make kind-tor`):
#    a HOST tor (scripts/kind-tor.sh) fronting the kind node, the @via:onion
#    @env:kind scenario, and SNAP_BASE_URL left at the kind lane's LOCAL door for
#    the same probe reason as above. The onion and the proxy come from
#    kind-tor.sh itself, which answers only while its tor is alive, so there is
#    no hostname file here to go stale. Every other rule — https only, the
#    summary verdict below — is shared.
#  * A missing or malformed onion is a hard stop for a RUN (exit 2, naming what
#    to start). --list / --gen / --print-command execute nothing, so they do not
#    demand one.
ONION_BASE_URL=""
ONION_PROXY=""
ONION_NOTE=""
onion_from_file() {
  local f raw base
  f="$1"
  [ -s "${f}" ] || return 1
  raw="$(tr -d '[:space:]' < "${f}")"
  base="${raw%.onion}"
  case "${base}" in *[!a-z2-7]*|'') return 1 ;; esac
  if [ "${base}" = "${raw}" ] || [ "${#base}" -ne 56 ]; then return 1; fi
  echo "https://${raw}"
}
if [ -n "${VIA}" ]; then
  case "${VIA}" in
    onion) ;;
    *) die "unknown --via ${VIA}. Legal front doors: onion (omit --via for the mesh's own door)." ;;
  esac
  if [ -z "${ENV_ID}" ]; then ENV_ID=docker; fi
  if [ "${ENV_ID}" != "docker" ] && [ "${ENV_ID}" != "kind" ]; then
    die "--via onion is the DOCKER stack's door (make stack-up TOR=1) or the KIND lane's (make kind-tor); --env ${ENV_ID} has no Tor front door."
  fi
  LANE=bdd
  if [ "${ENV_ID}" = "kind" ]; then
    if [ -z "${TAGS}" ]; then TAGS='@via:onion and @env:kind'; else TAGS="(${TAGS}) and @via:onion and @env:kind"; fi
  else
  if [ -z "${TAGS}" ]; then TAGS='@via:onion and @env:docker'; else TAGS="(${TAGS}) and @via:onion and @env:docker"; fi
  fi
  ONION_FILE="${SNAP_ONION_HOSTNAME_FILE:-${REPO}/tests/stack/tor-onion/hostname}"
  if [ -n "${SNAP_ONION_BASE_URL:-}" ]; then
    ONION_BASE_URL="$(echo "${SNAP_ONION_BASE_URL}" | sed 's:/*$::')"
  elif [ "${ENV_ID}" = "kind" ]; then
    # kind-tor.sh `onion` refuses unless ITS tor is alive: no stale readout.
    if kind_onion="$(bash "${REPO}/scripts/kind-tor.sh" onion 2>/dev/null)"; then
      ONION_BASE_URL="https://${kind_onion}"
    else
      ONION_BASE_URL=""
      ONION_NOTE="the kind lane's tor is not running — start it: make kind-tor (after make kind-up)"
    fi
  elif ONION_BASE_URL="$(onion_from_file "${ONION_FILE}")"; then
    :
  else
    ONION_BASE_URL=""
    ONION_NOTE="no v3 onion hostname in ${ONION_FILE} — start it: make stack-up TOR=1 (then: make stack-seed)"
  fi
  case "${ONION_BASE_URL}" in
    ''|https://*.onion) ;;
    *) die "SNAP_ONION_BASE_URL=${ONION_BASE_URL} is not https://<v3>.onion — an http:// entry is upgraded by the gateway's CSP and tests nothing (see --help)." ;;
  esac
  if [ "${ENV_ID}" = "kind" ] && [ -z "${SNAP_PROXY:-}" ]; then
    ONION_PROXY="$(bash "${REPO}/scripts/kind-tor.sh" socks)"
  else
  ONION_PROXY="${SNAP_PROXY:-socks5://127.0.0.1:${TOR_SOCKS_HOST_PORT:-9050}}"
  fi
  case "${ONION_PROXY}" in
    socks5://*) ;;
    *) die "SNAP_PROXY=${ONION_PROXY} must be socks5://host:port — a .onion only resolves inside Tor." ;;
  esac
  if [ "${MODE}" = "run" ] && [ -z "${ONION_BASE_URL}" ]; then
    die "--via onion: ${ONION_NOTE}"
  fi
  # The hostname file is removed when hugmesh-tor starts and stops (#581), but a
  # container killed without SIGTERM leaves it behind. When docker can answer,
  # refuse a readout no running container is serving — the same rule as
  # `make stack-onion` — rather than spend ten minutes of Tor retries on it.
  if [ "${MODE}" = "run" ] && [ "${ENV_ID}" = "docker" ] && [ -z "${SNAP_ONION_BASE_URL:-}" ] && command -v docker >/dev/null 2>&1; then
    if [ -z "$(docker ps -q --filter label=com.docker.compose.service=hugmesh-tor --filter status=running 2>/dev/null)" ]; then
      die "--via onion: ${ONION_FILE} names ${ONION_BASE_URL} but no hugmesh-tor container is running — a stale readout. Start it: make stack-up TOR=1"
    fi
  fi
  export SNAP_ONION_BASE_URL="${ONION_BASE_URL}"
  export SNAP_PROXY="${ONION_PROXY}"
fi

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
    printf 'VIA\t%s\n' "${VIA}"
    printf 'ONION_BASE_URL\t%s\n' "${ONION_BASE_URL}"
    printf 'PROXY\t%s\n' "${ONION_PROXY}"
    printf 'ONION_NOTE\t%s\n' "${ONION_NOTE}"
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
if [ -n "${VIA}" ]; then
  echo "==> via=${VIA}  onion=${ONION_BASE_URL}  proxy=${ONION_PROXY}  tags=${TAGS}"
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

# The Tor lane runs exactly the @via:onion scenario(s), so EVERY skip path — the
# @env:docker probe missing the local door, an onion env that never reached the
# steps, a tag that matched nothing — would otherwise exit 0 having tested
# nothing. Its verdict therefore also reads the run's own summary.json (removed
# first, so a previous run's file cannot answer for this one): at least one
# scenario PASSED and none was skipped, or the lane FAILS.
ONION_SUMMARY=""
if [ -n "${VIA}" ] && [ "${MODE}" = "run" ]; then
  case "${REPORT_DIR}" in
    /*) ONION_SUMMARY="${REPORT_DIR}/summary.json" ;;
    *)  ONION_SUMMARY="${HERE}/${REPORT_DIR}/summary.json" ;;
  esac
  rm -f "${ONION_SUMMARY}"
fi

set +e
if [ "${USE_DOCKER}" -eq 1 ]; then
  # The container sees ONLY what -e hands it — PUBLIC_HTTPS_PORT does not cross
  # in — so the docker door is resolved HERE, through the same table --env uses,
  # and passed as the one variable playwright.config.ts and dimensions.ts read
  # first. A caller's own SNAP_BASE_URL is forwarded untouched.
  docker run --rm --network host --ipc=host \
    -v "${HERE}:/work/e2e" -w /work/e2e \
    -e SNAP_BASE_URL="${SNAP_BASE_URL:-$(env_base_url docker)}" -e SNAP_SHOTS=/work/e2e/screenshots \
    -e E2E_PASSWORD="${E2E_PASSWORD:-}" \
    "${IMAGE}" "${PW_ARGV[@]}"
else
  ( cd "${HERE}" && SNAP_SHOTS="${SNAP_SHOTS:-${HERE}/screenshots}" "${PW_ARGV[@]}" )
fi
rc=$?
set -e

if [ -n "${ONION_SUMMARY}" ] && [ "${rc}" -eq 0 ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "run.sh: --via onion: python3 is needed to read ${ONION_SUMMARY}; the Tor lane's verdict is UNKNOWN, so it FAILS." >&2
    rc=1
  elif ! python3 - "${ONION_SUMMARY}" <<'ONION_PY'
import json, sys
path = sys.argv[1]
try:
    s = json.load(open(path, encoding="utf-8"))
    t = s["testTotals"]
    passed, skipped, failed = int(t["passed"]), int(t["skipped"]), int(t["failed"])
except Exception as exc:  # noqa: BLE001 - any unreadable summary is a FAIL
    print("run.sh: --via onion: no readable summary at %s (%s) — nothing proves a "
          "scenario ran over Tor, so the lane FAILS." % (path, exc), file=sys.stderr)
    sys.exit(1)
if passed >= 1 and skipped == 0 and failed == 0:
    sys.exit(0)
why = sorted({str(x.get("skipReason") or "") for x in (s.get("tests") or [])
              if x.get("status") == "skipped"} - {""})
print("run.sh: --via onion executed %d passed / %d skipped / %d failed — the Tor lane "
      "must PASS at least one @via:onion scenario and skip none, so it FAILS.%s"
      % (passed, skipped, failed,
         "".join("\n    skipped: " + w for w in why)), file=sys.stderr)
sys.exit(1)
ONION_PY
  then
    rc=1
  fi
fi

# The summary is a courtesy. It must never change the verdict: `rc` is captured
# above and is what this script exits with, whatever the reporter does. An
# exit-code-swallowing test lane is the worst outcome available here, so the
# guard plants exactly that mutation and requires it to go red.
if [ "${LANE}" = "bdd" ] && [ "${MODE}" = "run" ] && [ "${SNAP_EVIDENCE_SUMMARY:-1}" != "0" ]; then
  echo
  evidence_report || true
fi

exit "${rc}"

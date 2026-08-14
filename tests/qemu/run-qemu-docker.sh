#!/usr/bin/env bash
# run-qemu-docker.sh — run the QEMU emulated-device tests CONTAINERIZED, one
# container per platform/role row, against images built in ANY build session.
#
# This is the supported entry point for the containerized harness; the container
# side is tests/qemu/docker-entrypoint.sh (see docker/Dockerfile.qemu-runner for
# why a container is involved at all: the launchers need root for losetup -P, and
# `docker` group membership grants that without an interactive sudo password).
#
# It does NOT reimplement any test logic. It resolves a session's artifacts,
# decides which rows are runnable, and fans containers out with a concurrency
# cap. Everything inside the guest is still tests/qemu/assertions.sh.
#
# ORDERING: Pi rows run FIRST (the Pi is the reference device and the slowest —
# aarch64 has no KVM on an x86_64 host, so it is pure TCG emulation), then the
# other ARM platforms, then x86 (which gets KVM and is comparatively quick).
#
# Examples:
#   ./tests/qemu/run-qemu-docker.sh --list
#   ./tests/qemu/run-qemu-docker.sh --platform rpi5
#   ./tests/qemu/run-qemu-docker.sh --session out/sessions/20260807-071119-5c1ccb --jobs 2
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

IMAGE_TAG="${IMAGE_TAG:-hugmesh-qemu-runner:latest}"
SESSION=""
ARTIFACTS=""
WORK="${REPO_DIR}/out/qemu-runs"
PLATFORM_FILTER=""
ROLE_FILTER=""
ONLY=""
MODE="golden"
JOBS="2"
MEM="2048"
SMP="2"
TIMEOUT="2400"
LIST_ONLY=false
FORCE_BUILD=false
KEEP=false

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'; YEL=$'\033[0;33m'; RST=$'\033[0m'
info() { echo "${GREEN}[qemu-docker]${RST} $*"; }
step() { echo "${CYAN}==> $*${RST}"; }
warn() { echo "${YEL}[qemu-docker] WARN:${RST} $*" >&2; }
die()  { echo "${RED}[qemu-docker] ERROR:${RST} $*" >&2; exit 1; }

usage() {
cat <<EOF
Usage: $0 [OPTIONS]

  --session DIR     build-session dir holding the artifacts.
                    Default: newest non-empty dir under out/sessions/
  --artifacts DIR   explicit artifacts dir (wins over --session)
  --work DIR        writable scratch for decompressed images/overlays/results.
                    Default: ${WORK}
  --platform P      only this platform (rpi5|x86|frite|jetson|orangepi*)
  --role R          only this role (pki|backend|frontend|be|fe|omnibus|...)
  --only PAT        substring filter on the "<platform>/<role>" label
  --mode M          golden (default; boots the real .img) | stage4
  -j, --jobs N      concurrent emulated devices. Default: ${JOBS}
  --mem MB          guest RAM per device. Default: ${MEM}
  --smp N           guest vCPUs per device. Default: ${SMP}
  -t, --timeout SEC guest SSH wait. Default: ${TIMEOUT}
  --list            enumerate the rows that WOULD run, then exit
  --build-image     (re)build the runner image before running
  --keep            keep per-run scratch dirs
  -h, --help
EOF
exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --session)      SESSION="$2"; shift 2 ;;
        --artifacts)    ARTIFACTS="$2"; shift 2 ;;
        --work)         WORK="$2"; shift 2 ;;
        --platform)     PLATFORM_FILTER="$2"; shift 2 ;;
        --role)         ROLE_FILTER="$2"; shift 2 ;;
        --only)         ONLY="$2"; shift 2 ;;
        --mode)         MODE="$2"; shift 2 ;;
        -j|--jobs)      JOBS="$2"; shift 2 ;;
        --mem)          MEM="$2"; shift 2 ;;
        --smp)          SMP="$2"; shift 2 ;;
        -t|--timeout)   TIMEOUT="$2"; shift 2 ;;
        --list)         LIST_ONLY=true; shift ;;
        --build-image)  FORCE_BUILD=true; shift ;;
        --keep)         KEEP=true; shift ;;
        -h|--help)      usage 0 ;;
        *)              echo "Unknown arg: $1" >&2; usage 1 ;;
    esac
done

command -v docker >/dev/null || die "docker not found"
docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon (is your user in the 'docker' group?)"

# ── Resolve the artifacts dir ───────────────────────────────────────────────
# A build SESSION is out/sessions/<stamp>/; several are usually empty shells
# (a session dir is minted at wizard time, before any artifact lands), so
# "newest" means newest that actually holds an image.
newest_session_with_images() {
    local d
    while IFS= read -r d; do
        if compgen -G "${d}/*.img" >/dev/null 2>&1 || compgen -G "${d}/*.img.xz" >/dev/null 2>&1; then
            printf '%s\n' "${d}"; return 0
        fi
    done < <(ls -1dt "${REPO_DIR}"/out/sessions/*/ 2>/dev/null)
    return 1
}

if [ -z "${ARTIFACTS}" ]; then
    if [ -z "${SESSION}" ]; then
        SESSION="$(newest_session_with_images || true)"
        [ -n "${SESSION}" ] || die "no build session under out/sessions/ holds a .img or .img.xz — build first, or pass --artifacts DIR"
    fi
    ARTIFACTS="${SESSION}"
fi
ARTIFACTS="$(readlink -f "${ARTIFACTS}")"
[ -d "${ARTIFACTS}" ] || die "artifacts dir not found: ${ARTIFACTS}"
mkdir -p "${WORK}"
WORK="$(readlink -f "${WORK}")"

# ── Discover runnable rows from the artifacts actually present ──────────────
# Artifact naming: hugmesh-<platform>-<arch>-<role>-<env>-<stamp>.img[.xz]
# <role> may itself contain '-' (standalone-thin), so parse from BOTH ends:
# fields 1..2 are hugmesh+platform, the arch follows, and the last two fields
# before the extension are <env>-<stamp>.
discover_rows() {
    local f base rest platform arch role env stamp prefer
    local -a _fields
    for f in "${ARTIFACTS}"/*.img "${ARTIFACTS}"/*.img.xz; do
        [ -e "${f}" ] || continue
        base="$(basename "${f}")"
        base="${base%.xz}"; base="${base%.img}"
        case "${base}" in *kernel*|*initramfs*|*initrd*|*squashfs*) continue ;; esac
        [[ "${base}" == hugmesh-* ]] || continue
        # Match the Python contract (studio/hugmesh_studio/core/qemu_tests.py
        # parse_artifact_name): hugmesh+platform+arch+<role...>+env+stamp is at
        # least 6 '-'-separated fields. Without this guard the both-ends strip
        # below happily "parses" a too-short name (e.g. hugmesh-x86-be.img)
        # into role==env, where the Python side refuses it — the divergence
        # studio/tests/test_qemu_tests.py had to carve out.
        IFS='-' read -r -a _fields <<< "${base}"
        [ "${#_fields[@]}" -ge 6 ] || continue
        rest="${base#hugmesh-}"
        platform="${rest%%-*}"; rest="${rest#*-}"
        arch="${rest%%-*}";     rest="${rest#*-}"
        # rest is now "<role>-<env>-<stamp>"; strip the two trailing fields.
        rest="${rest%-*}"          # drop <stamp>
        env="${rest##*-}"          # <env>
        role="${rest%-*}"          # <role>, '-' and all
        [ -n "${platform}" ] && [ -n "${role}" ] || continue
        stamp="${base##*-}"
        # Emit the sort key first, strip it after collapsing. Field 2 is
        # "1" for a decompressed .img so it outranks its own .img.xz.
        case "${f}" in *.xz) prefer=0 ;; *) prefer=1 ;; esac
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${stamp}" "${prefer}" "${platform}" "${role}" "${env}" "${f}"
    done
}

# ONE row per platform/role — newest stamp, then decompressed-over-compressed.
#
# Without this the same artifact present as BOTH .img and .img.xz enumerated
# TWICE and the runner booted it twice, re-expanding 9-20GB for the duplicate;
# and every superseded rebuild of a role kept its own row. The tie-break matches
# studio/hugmesh_studio/core/qemu_tests.py discover_rows() so the GUI and the
# CLI can never disagree about which artifact a green result refers to.
collapse_rows() {
    sort -t$'\t' -k3,3 -k4,4 -k1,1r -k2,2r \
        | awk -F'\t' '{ key = $3 "/" $4 } !seen[key]++ { print $3 "\t" $4 "\t" $5 "\t" $6 }'
}

# Pi first, then other ARM, then x86 (see the ORDERING note in the header).
platform_rank() {
    case "$1" in
        rpi5|rpi4|rpi3) echo 0 ;;
        x86)            echo 2 ;;
        *)              echo 1 ;;
    esac
}

ROWS=()
while IFS=$'\t' read -r platform role env img; do
    [ -n "${platform}" ] || continue
    [ -z "${PLATFORM_FILTER}" ] || [ "${platform}" = "${PLATFORM_FILTER}" ] || continue
    [ -z "${ROLE_FILTER}" ]     || [ "${role}" = "${ROLE_FILTER}" ]         || continue
    [ -z "${ONLY}" ]            || [[ "${platform}/${role}" == *"${ONLY}"* ]] || continue
    ROWS+=("$(platform_rank "${platform}")|${platform}|${role}|${env}|${img}")
done < <(discover_rows | collapse_rows)

[ "${#ROWS[@]}" -gt 0 ] || die "no runnable rows found in ${ARTIFACTS} (filters: platform='${PLATFORM_FILTER}' role='${ROLE_FILTER}' only='${ONLY}')"

IFS=$'\n' ROWS=($(printf '%s\n' "${ROWS[@]}" | sort -t'|' -k1,1n -k2,2 -k3,3)); unset IFS

echo "======================================================================"
echo " QEMU containerized emulated-device tests"
echo " artifacts : ${ARTIFACTS}"
echo " work      : ${WORK}"
echo " mode      : ${MODE}    jobs: ${JOBS}    mem: ${MEM}M    smp: ${SMP}"
echo "======================================================================"
printf '%-4s %-14s %-22s %-6s %s\n' "#" "PLATFORM" "ROLE" "ENV" "IMAGE"
i=0
for r in "${ROWS[@]}"; do
    IFS='|' read -r _rank platform role env img <<< "${r}"
    i=$((i+1))
    printf '%-4s %-14s %-22s %-6s %s\n' "${i}" "${platform}" "${role}" "${env}" "$(basename "${img}")"
done
echo "----------------------------------------------------------------------"
echo "${#ROWS[@]} row(s) runnable"

if ${LIST_ONLY}; then
    echo "(--list: enumerated only, nothing booted)"
    exit 0
fi

# ── Build the runner image ──────────────────────────────────────────────────
if ${FORCE_BUILD} || ! docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1; then
    step "Building ${IMAGE_TAG}"
    docker build -f "${REPO_DIR}/docker/Dockerfile.qemu-runner" -t "${IMAGE_TAG}" "${REPO_DIR}" \
        || die "failed to build ${IMAGE_TAG}"
else
    info "reusing existing image ${IMAGE_TAG} (--build-image to rebuild)"
fi

RESULT_DIR="${WORK}/results"
mkdir -p "${RESULT_DIR}"

# KVM helps x86 enormously and does nothing for aarch64 on an x86_64 host; pass
# it through only when the device is actually usable by this user.
KVM_ARGS=()
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then KVM_ARGS=(--device /dev/kvm); fi

run_row() {
    local platform="$1" role="$2" img="$3"
    local label="${platform}/${role}"
    local safe; safe="$(echo "${label}" | tr '/+' '__')"
    local name="hugmesh-qemu-${safe}-$$"
    local log="${WORK}/${safe}.log"

    # --privileged: losetup -P inside. Container-local networking only, so the
    # guest's forwarded ports never collide with anything on the host.
    docker run --rm --privileged "${KVM_ARGS[@]}" \
        --name "${name}" \
        -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
        -v "${REPO_DIR}":/src:ro \
        -v "${ARTIFACTS}":/artifacts:ro \
        -v "${WORK}":/work \
        "${IMAGE_TAG}" \
        --platform "${platform}" --role "${role}" --mode "${MODE}" \
        --img "/artifacts/$(basename "${img}")" \
        --mem "${MEM}" --smp "${SMP}" --timeout "${TIMEOUT}" \
        --label "${label}" $( ${KEEP} && echo --keep ) \
        > "${log}" 2>&1
    local rc=$?
    if [ "${rc}" -eq 0 ]; then
        echo "${GREEN}[PASS]${RST} ${label}  (log: ${log})"
    else
        echo "${RED}[FAIL]${RST} ${label}  rc=${rc}  (log: ${log})"
    fi
    return "${rc}"
}

# Result path for a row — MUST match docker-entrypoint.sh's RESULT_JSON.
row_result_json() { printf '%s/%s.json\n' "${RESULT_DIR}" "$(echo "$1" | tr '/+' '__')"; }

# Purge THIS run's rows before booting anything. ${WORK} is deliberately
# persistent (it caches multi-GB decompressed images), so results/ accumulates
# every row ever run — across sessions, artifacts and days. Without this purge a
# row whose container dies before emit_result leaves its PREVIOUS verdict on
# disk, and the summary below reports that stale PASS as this run's outcome.
# Only this run's rows are removed: results for rows outside the current filters
# are left alone, and the summary no longer reads them either.
for r in "${ROWS[@]}"; do
    IFS='|' read -r _rank platform role env img <<< "${r}"
    rm -f "$(row_result_json "${platform}/${role}")"
done

step "Running ${#ROWS[@]} row(s), ${JOBS} at a time"
FAILED=0
running=0
for r in "${ROWS[@]}"; do
    IFS='|' read -r _rank platform role env img <<< "${r}"
    run_row "${platform}" "${role}" "${img}" &
    running=$((running+1))
    if [ "${running}" -ge "${JOBS}" ]; then
        wait -n 2>/dev/null || FAILED=$((FAILED+1))
        running=$((running-1))
    fi
done
while [ "${running}" -gt 0 ]; do
    wait -n 2>/dev/null || FAILED=$((FAILED+1))
    running=$((running-1))
done

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "======================================================================"
echo " RESULTS"
echo "======================================================================"
printf '%-24s %-8s %-6s %-6s %s\n' "LABEL" "STATUS" "PASS" "FAIL" "DETAIL"
# Iterate THIS RUN'S ROWS — never a glob of the results dir. A glob tabulates
# every row ever run into this persistent ${WORK}, so `--platform rpi5 --role pki`
# used to print a table of eight rows from two different artifact generations and
# compute passed/total across all of them. Driving from ROWS also means a row that
# produced no JSON is visible as NO RESULT instead of vanishing from the count.
total=0; passed=0
for r in "${ROWS[@]}"; do
    IFS='|' read -r _rank platform role env img <<< "${r}"
    lbl="${platform}/${role}"
    j="$(row_result_json "${lbl}")"
    total=$((total+1))
    if [ ! -e "${j}" ]; then
        # The container never emitted a verdict (crash, kill, cancel, OOM).
        printf '%-24s %-8s %-6s %-6s %s\n' "${lbl}" "NO-RESULT" "-" "-" \
            "container wrote no result JSON"
        continue
    fi
    st="$(jq  -r '.status' "${j}" 2>/dev/null || echo '?')"
    p="$(jq   -r '.assertions_passed' "${j}" 2>/dev/null || echo '?')"
    f="$(jq   -r '.assertions_failed' "${j}" 2>/dev/null || echo '?')"
    d="$(jq   -r '.detail' "${j}" 2>/dev/null || echo '')"
    [ "${st}" = "PASS" ] && passed=$((passed+1))
    printf '%-24s %-8s %-6s %-6s %s\n' "${lbl}" "${st}" "${p}" "${f}" "${d}"
done
echo "----------------------------------------------------------------------"
echo "${passed}/${total} row(s) passed; results: ${RESULT_DIR}"
[ "${FAILED}" -eq 0 ] && [ "${passed}" -eq "${total}" ]

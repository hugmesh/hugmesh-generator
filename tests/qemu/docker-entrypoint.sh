#!/usr/bin/env bash
# docker-entrypoint.sh — runs INSIDE the hugmesh-qemu-runner container (see
# docker/Dockerfile.qemu-runner). One container == one emulated device == one
# platform/role row of the test matrix.
#
# WHY A CONTAINER AT ALL
# ----------------------
# Every step below needs root: losetup -P to lift the kernel out of the golden
# .img's boot partition, and (in stage4 mode) mkfs.ext4 + an xattr-preserving
# stage4 untar. A --privileged container is root for anyone in the `docker`
# group, so the Studio and CI can run the full matrix with NO interactive sudo.
#
# WHAT IT REUSES (deliberately: no test logic is reimplemented here)
#   tests/qemu/launch-pi.sh / launch-arm.sh / launch-x86.sh   boot the golden .img
#   tests/qemu/run-qemu-test.sh                              stage4 provisioning test
#   tests/qemu/make-test-keys.sh                             FAT32 KEYS disk
#   tests/qemu/assertions.sh                                 the in-guest assertions
# This script only RESOLVES artifacts, supplies the kernel the launchers cannot
# find in a session dir, and drives ssh-wait -> assert -> teardown.
#
# TWO MODES
#   --mode golden  (default) boot the REAL shipped .img with a synthetic KEYS
#                  disk and assert first-boot provisioning on the actual
#                  artifact a user would flash. This is the emulated-DEVICE test.
#   --mode stage4  delegate to run-qemu-test.sh, which fabricates a throwaway
#                  ext4 from the .stage4.tar.xz instead. Narrower (it never
#                  exercises the partition layout/bootloader path) but it is the
#                  pre-existing harness, kept reachable for comparison.
#
# MOUNT CONTRACT
#   /src        repo, read-only   (tests/qemu/*.sh + specs/)
#   /artifacts  images, read-only (.img, .img.xz, .stage4.tar.xz)
#   /work       writable scratch  (decompressed .img, overlays, console, result)
#
# NETWORKING: the guest forwards stay container-local and are never published,
# so a developer's live hugmesh-local stack keeps :8080/:8443 uncontested. The
# ONE exception is --keep-alive, where run-qemu-docker.sh publishes THIS
# container's ssh forward on a loopback-only host port from 22300-22399. The
# guest's :8080/:8443 forwards are still never published, so the live stack
# stays uncontested either way.
#
# --keep-alive: DEVICES YOU CAN LOG INTO
# --------------------------------------
# Default behaviour is unchanged — assert, power the guest off, exit, container
# gone. With --keep-alive the guest is left RUNNING after the assertions and
# this script blocks until the container is stopped, having published a device
# record under ${WORK}/devices/ that tells the Studio everything it needs to
# open a terminal on the device: the loopback ssh port, the HOST-side path to
# the login key, which logins actually exist, and qemu's QMP socket.
set -uo pipefail

SRC="${SRC:-/src}"
ARTIFACTS="${ARTIFACTS:-/artifacts}"
WORK="${WORK:-/work}"
QEMU_DIR="${SRC}/tests/qemu"

PLATFORM="rpi5"
ROLE="pki"
MODE="golden"
BOARD=""
IMG=""
STAGE4=""
MEM="2048"
SMP="2"
TIMEOUT="2400"
# Wall clock for the POST-boot phase. ${TIMEOUT} only covers the ssh-wait loop;
# see the timeout(1) wrapper on the assertion ssh below for why this exists.
ASSERT_TIMEOUT="900"
SSH_PORT="2222"
UI_PORT="8443"
SSH_USER="tester"
KEEP=false
LABEL=""

KEEP_ALIVE=false
# Extra wheel logins to create on the guest, one per --extra-user. The Studio's
# per-device user dropdown can only offer accounts that really exist, so this
# list and the record's "users" array are the same list by construction.
EXTRA_USERS=()
# QMP socket for the launcher (A5). Empty = the launcher keeps -monitor none,
# exactly as today.
QMP_SOCK=""
# Host side of the /work bind mount. The device record must carry HOST paths:
# the Studio runs on the host, where this container's /work does not exist, so
# a /work/... ssh key path would be unusable to it. --host-work is the argv
# spelling, HOST_WORK the environment one; both mean the same thing.
HOST_WORK="${HOST_WORK:-}"
# Host side of the /artifacts bind mount, same convention. The device record's
# "artifacts" field is the contract a per-device Start needs: to boot this row
# again, the starter must point run-qemu-docker.sh at the SAME artifacts dir
# the device came from, and "/artifacts" names nothing on the host.
HOST_ARTIFACTS="${HOST_ARTIFACTS:-}"
# Loopback host port run-qemu-docker.sh published this container's ssh forward
# on; 0 when nothing was published. Recorded here, never bound here — the port
# is chosen and bound OUTSIDE, so this value can only ever arrive from the
# caller. The two spellings are `-e SSH_HOST_PORT=<port>` alongside the matching
# `-p 127.0.0.1:<port>:${SSH_PORT}`, and `--ssh-host-port <port>`. Nothing inside
# this container can derive it: the guest forward is always ${SSH_PORT} in here,
# and the published host port is not visible from within.
SSH_HOST_PORT="${SSH_HOST_PORT:-0}"
# This container's docker NAME, exactly as the runner passed it to `docker run
# --name`. The Studio both stops the container by this string and matches live
# devices against `docker ps --format '{{.Names}}'`, so it has to BE the name.
#
# There is deliberately no fallback to /etc/hostname: docker seeds a container's
# hostname from the short container ID unless --hostname says otherwise, and an
# ID never appears in a name listing. `docker stop` would still accept it, but
# every name-matching consumer would conclude the device is gone. If nobody
# tells us the name we record the empty string and warn — visibly wrong beats
# plausibly wrong.
CONTAINER_NAME="${CONTAINER_NAME:-}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'; YEL=$'\033[0;33m'; RST=$'\033[0m'
info() { echo "${GREEN}[qemu-docker]${RST} $*"; }
step() { echo "${CYAN}==> $*${RST}"; }
warn() { echo "${YEL}[qemu-docker] WARN:${RST} $*" >&2; }
die()  { echo "${RED}[qemu-docker] ERROR:${RST} $*" >&2; emit_result "ERROR" "$*"; exit 1; }

usage() {
cat <<EOF
Usage: docker run --rm --privileged --device /dev/kvm \\
         -v REPO:/src:ro -v IMAGES:/artifacts:ro -v WORK:/work \\
         hugmesh-qemu-runner:latest [OPTIONS]

  --platform P     rpi5 | x86 | frite | jetson | orangepi5 | orangepizero2 |
                   orangepizero2w | orangepizero3 | orangepi3-lts | orangepi4-lts
  --board B        board id for the multi-board ARM platforms (launch-arm.sh)
  --role ROLE      image role (pki|backend|frontend|be|fe|be+gpu|omnibus|desktop|...)
  --mode M         golden (default) | stage4
  --img FILE       explicit image under /artifacts (else autodetect by platform+role)
  --stage4 FILE    explicit stage4 under /artifacts (stage4 mode; else autodetect)
  --mem MB         guest RAM. Default: ${MEM}
  --smp N          guest vCPUs. Default: ${SMP}
  --timeout SEC    seconds to wait for guest SSH. Default: ${TIMEOUT}
  --assert-timeout SEC
                   wall clock for the in-guest assertion ssh (SIGTERM, then
                   SIGKILL 30s later). Used verbatim — never clamped.
                   Default: ${ASSERT_TIMEOUT}
  --label NAME     result label (default: <platform>/<role>)
  --keep           keep the scratch run dir
  -h, --help

Interactive devices (golden mode only; everything below is off by default):
  --keep-alive     do NOT power the guest off after the assertions. Leave qemu
                   running, publish a device record under <work>/devices/, and
                   block until this container is stopped.
  --extra-user N   repeatable. Create wheel user N on the guest alongside
                   '${SSH_USER}', with the same throwaway login key.
  --host-work PATH host side of the /work bind mount, so the device record can
                   name HOST paths the Studio can actually open.
                   Env: HOST_WORK.
  --host-artifacts PATH
                   host side of the /artifacts bind mount, so the record's
                   "artifacts" field names the dir a per-device restart must be
                   pointed at. Env: HOST_ARTIFACTS.
  --ssh-host-port P
                   loopback host port the guest's ssh was published on; goes
                   into the device record verbatim. 0 = not published.
                   Env: SSH_HOST_PORT.
  --container NAME the name this container was started with (docker run --name),
                   recorded verbatim so the Studio can match and stop it.
                   Env: CONTAINER_NAME. Unset = recorded as "" (see the WARN).
  --qmp PATH       qemu QMP unix socket, passed through to the launcher.
                   Implied by --keep-alive; without either, qemu keeps
                   -monitor none and the launcher argv is unchanged.
EOF
exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform) PLATFORM="$2"; shift 2 ;;
        --board)    BOARD="$2"; shift 2 ;;
        --role)     ROLE="$2"; shift 2 ;;
        --mode)     MODE="$2"; shift 2 ;;
        --img)      IMG="$2"; shift 2 ;;
        --stage4)   STAGE4="$2"; shift 2 ;;
        --mem)      MEM="$2"; shift 2 ;;
        --smp)      SMP="$2"; shift 2 ;;
        --timeout)  TIMEOUT="$2"; shift 2 ;;
        --assert-timeout) ASSERT_TIMEOUT="$2"; shift 2 ;;
        --label)    LABEL="$2"; shift 2 ;;
        --keep)     KEEP=true; shift ;;
        --keep-alive)    KEEP_ALIVE=true; shift ;;
        --extra-user)    EXTRA_USERS+=("$2"); shift 2 ;;
        --host-work)     HOST_WORK="$2"; shift 2 ;;
        --host-artifacts) HOST_ARTIFACTS="$2"; shift 2 ;;
        --ssh-host-port) SSH_HOST_PORT="$2"; shift 2 ;;
        --container)     CONTAINER_NAME="$2"; shift 2 ;;
        --qmp)           QMP_SOCK="$2"; shift 2 ;;
        -h|--help)  usage 0 ;;
        *)          echo "Unknown arg: $1" >&2; usage 1 ;;
    esac
done

[ -n "${LABEL}" ] || LABEL="${PLATFORM}/${ROLE}"
RUN_DIR="${WORK}/runs/$(echo "${LABEL}" | tr '/+' '__')"
RESULT_DIR="${WORK}/results"
RESULT_JSON="${RESULT_DIR}/$(echo "${LABEL}" | tr '/+' '__').json"
# Same safe-label rule as RESULT_JSON above, deliberately: the Studio pairs a
# device with its result row by that filename.
DEVICES_DIR="${WORK}/devices"
DEVICE_JSON="${DEVICES_DIR}/$(echo "${LABEL}" | tr '/+' '__').json"
# NB ${DEVICES_DIR} is NOT created here. Only --keep-alive has a record to put
# in it, and a default run must leave exactly the same tree behind as before.
mkdir -p "${RUN_DIR}" "${RESULT_DIR}" "${WORK}/images"

STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
START_S=${SECONDS}

# Everything this container writes into the bind-mounted /work lands root-owned,
# because the container runs as root. The invoking user then cannot read its own
# console.log or delete the scratch dir without sudo — the very thing this
# harness exists to avoid. Hand ownership back on the way out, mirroring the
# HOST_UID convention the Makefile already uses for the dockerized build.
HOST_UID="${HOST_UID:-}"
HOST_GID="${HOST_GID:-}"
reown() {
    [ -n "${HOST_UID}" ] || return 0
    chown -R "${HOST_UID}:${HOST_GID:-${HOST_UID}}" \
        "${RUN_DIR}" "${RESULT_DIR}" "${WORK}/images" 2>/dev/null || true
}
trap reown EXIT

# emit_result STATUS DETAIL [PASS] [FAIL] — one machine-readable row per run, so
# the Studio can render the matrix without scraping console text.
emit_result() {
    local status="$1" detail="${2:-}" pass="${3:-0}" fail="${4:-0}"
    mkdir -p "${RESULT_DIR}" 2>/dev/null || true
    cat > "${RESULT_JSON}" <<EOF
{
  "label": "${LABEL}",
  "platform": "${PLATFORM}",
  "board": "${BOARD}",
  "role": "${ROLE}",
  "mode": "${MODE}",
  "status": "${status}",
  "detail": $(printf '%s' "${detail}" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/'),
  "assertions_passed": ${pass},
  "assertions_failed": ${fail},
  "image": "${IMG}",
  "started_at": "${STARTED_AT}",
  "duration_s": $((SECONDS - START_S))
}
EOF
}

# ── The device registry (--keep-alive only) ─────────────────────────────────
# emit_result says how a row FINISHED; this says a device is UP and how to get
# into it. The Studio polls ${WORK}/devices/ and drives ssh/qemu from what it
# finds, so every path in here has to be a HOST path: /work exists only inside
# this container, and an ssh key path the Studio cannot open is worthless.
host_path() {
    local p="${1:-}"
    # The /artifacts mapping first: ${ARTIFACTS} is never under ${WORK}, so the
    # two prefixes cannot shadow each other, but checking it before the
    # HOST_WORK bail-out means a caller that supplied ONLY --host-artifacts
    # still gets its artifacts paths mapped.
    if [ -n "${HOST_ARTIFACTS}" ]; then
        case "${p}" in
            "${ARTIFACTS}")   printf '%s\n' "${HOST_ARTIFACTS}"; return 0 ;;
            "${ARTIFACTS}"/*) printf '%s\n' "${HOST_ARTIFACTS}/${p#"${ARTIFACTS}"/}"; return 0 ;;
        esac
    fi
    # No HOST_WORK => emit the container path unchanged. It is wrong for the
    # Studio, but it is honest and greppable, which beats a fabricated path.
    [ -n "${HOST_WORK}" ] || { printf '%s\n' "${p}"; return 0; }
    case "${p}" in
        "${WORK}")   printf '%s\n' "${HOST_WORK}" ;;
        "${WORK}"/*) printf '%s\n' "${HOST_WORK}/${p#"${WORK}"/}" ;;
        *)           printf '%s\n' "${p}" ;;
    esac
}

# Same escape ORDER as emit_result's detail (backslash first, then quote) but
# done with bash substitution rather than sed, because an EMPTY value here is
# routine, not hypothetical: "board" is "" for every platform except the
# multi-board ARM ones, and "qmp" is "" whenever --qmp was not passed. Piping ""
# into sed feeds it ZERO lines, so `s/^/"/` never runs and the field comes out
# bare — `"board": ,` — which is not JSON, and the Studio drops records it
# cannot parse. Substitution has no such edge and forks nothing.
json_str() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "${s}"
}

# write_device_record STATE — booting|running|assertions|stopped
#
# "artifacts" and "image" are the per-device START contract: together with
# "label" they are everything a restarter needs to boot this row again —
# `run-qemu-docker.sh --artifacts <artifacts> --only-exact <label>`. "image" is
# the basename of the image THIS qemu is actually booting (for a compressed
# artifact that is the decompressed copy under <work>/images/, which is also
# what the cache sweep protects while this container exists). The first record
# is written in state "booting" the moment qemu launches — minutes before the
# guest answers ssh on TCG — so a row killed during boot still leaves a
# findable, stoppable device behind instead of tonight's zero-trace exit 143s.
write_device_record() {
    local state="$1" users_json="" u
    mkdir -p "${DEVICES_DIR}" 2>/dev/null || true
    for u in "${GUEST_USERS[@]}"; do
        users_json="${users_json:+${users_json}, }$(json_str "${u}")"
    done
    # Hand the KEY over BEFORE publishing the record, not after. The record is
    # the announcement ("this device is running, here is the key"), so anything
    # it points at has to be usable by the time a reader can see it. Doing it
    # afterwards leaves a window — small, but the wrong way round — in which the
    # Studio can read state=running and then fail to open a root-owned key. The
    # record itself is chowned below, once it exists.
    if [ -n "${HOST_UID}" ] && [ -f "${SSHKEY}" ]; then
        chown "${HOST_UID}:${HOST_GID:-${HOST_UID}}" \
            "${SSHKEY}" "${SSHKEY}.pub" 2>/dev/null || true
        chmod 600 "${SSHKEY}" 2>/dev/null || true
    fi
    # `|| warn` is load-bearing, not decoration. The prologue is `set -uo
    # pipefail` with no -e, so the call sites before the assertions run with
    # errexit OFF — but golden mode switches it ON right after the assertion
    # pipeline and never switches it back, and one call site sits in there,
    # between the assertions and emit_result. If a failed write aborted this
    # function at THAT one, the script would die at exactly the point the file
    # already has a fix for, leaving the PREVIOUS run's verdict on disk to be
    # reported as this one's.
    cat > "${DEVICE_JSON}" <<EOF || warn "could not write device record ${DEVICE_JSON}"
{
  "label": $(json_str "${LABEL}"),
  "platform": $(json_str "${PLATFORM}"),
  "role": $(json_str "${ROLE}"),
  "board": $(json_str "${BOARD}"),
  "container": $(json_str "${CONTAINER_NAME}"),
  "ssh_host_port": ${SSH_HOST_PORT},
  "ssh_user": $(json_str "${SSH_USER}"),
  "ssh_key": $(json_str "$(host_path "${SSHKEY}")"),
  "users": [${users_json}],
  "qmp": $(json_str "$(host_path "${QMP_SOCK}")"),
  "artifacts": $(json_str "$(host_path "${ARTIFACTS}")"),
  "image": $(json_str "$(basename "${IMG}")"),
  "state": $(json_str "${state}"),
  "started_at": $(json_str "${STARTED_AT}")
}
EOF
    # Everything this container writes into /work lands root-owned, and reown()
    # only fixes that on the way OUT — which under --keep-alive is hours away,
    # whenever the operator finally stops the device. Both the record and the
    # things it POINTS AT are consumed while the container is still alive, so
    # hand them over here — same HOST_UID convention, just earlier.
    #
    # The private key is the one that cannot wait — it is handed over ABOVE, before
    # the record announcing it exists. "ssh_key" in that record is advertised as a
    # HOST path and the Studio runs as the operator, so a root-owned key would be
    # EACCES for the entire lifetime of a device this very record calls "running":
    # the single-button ssh would fail from the first click to the last. chown does
    # not change the mode, and ssh(1) rejects a private key any other account can
    # read, so it stays 0600; the chmod states that rather than relying on
    # ssh-keygen's creation mode from a distance.
    #
    # What is left here is the record itself (it has to exist before it can be
    # chowned) plus the two directories BELOW the bind mount that root created on
    # the way to the key: owning the key is not enough to open it. With ${WORK}
    # itself already host-owned, that makes every component of the advertised path
    # the operator's, whatever umask was in force.
    #
    # Spelled as `if`, NOT `[ -n ... ] && chown ...`: that list evaluates to
    # false whenever HOST_UID is unset — the normal case for a bare `docker run`
    # of this entrypoint, which the usage above documents as supported — and
    # under errexit a false list aborts the function before `return 0`.
    if [ -n "${HOST_UID}" ]; then
        chown "${HOST_UID}:${HOST_GID:-${HOST_UID}}" \
            "${DEVICES_DIR}" "${DEVICE_JSON}" \
            "${WORK}/runs" "${RUN_DIR}" 2>/dev/null || true
    fi
    # Never let a bookkeeping failure take the run down: this is called from
    # cleanup() and from stretches where errexit is ON.
    return 0
}

# Both timeouts reach $((...)) arithmetic (the ssh-wait deadline) or timeout(1).
# Under `set -u` a non-numeric value in arithmetic is a FATAL bash error, not a
# catchable one: `--timeout abc` kills the process at the deadline line with
# "abc: unbound variable", past every emit_result, so the row surfaces only as
# run-qemu-docker.sh's "container wrote no result JSON" with no cause recorded.
# Checked HERE — after emit_result is defined, since die() calls it — so a typo
# is an ERROR row instead of a silent NO-RESULT.
[[ "${TIMEOUT}" =~ ^[0-9]+$ ]] \
    || die "--timeout must be a whole number of seconds, got '${TIMEOUT}'"
[[ "${ASSERT_TIMEOUT}" =~ ^[0-9]+$ ]] \
    || die "--assert-timeout must be a whole number of seconds, got '${ASSERT_TIMEOUT}'"

# ssh_host_port is emitted as a BARE JSON number. Anything non-numeric makes the
# whole record unparseable, and the Studio skips records it cannot parse — so a
# typo here would silently cost the operator the device rather than the port.
[[ "${SSH_HOST_PORT}" =~ ^[0-9]+$ ]] \
    || die "--ssh-host-port must be a whole number, got '${SSH_HOST_PORT}'"
# ...and "numeric" is not the same as "valid JSON". `022` satisfies the pattern
# above but emits `"ssh_host_port": 022`, which json.loads rejects outright —
# costing the whole record, exactly the failure the comment above warns about.
# `10#` forces base 10 so a leading zero is stripped rather than read as octal
# (a bare $((022)) would silently yield 18). The range check is the same guard
# in the other direction: a port over 65535 can never have been bound, so a
# record claiming one would send the Studio's terminal button at nothing.
SSH_HOST_PORT=$((10#${SSH_HOST_PORT}))
[ "${SSH_HOST_PORT}" -le 65535 ] \
    || die "--ssh-host-port must be 0-65535, got '${SSH_HOST_PORT}'"

# ── Which logins will exist on the guest ────────────────────────────────────
# Checked here, next to the other argv checks, because an --extra-user name is
# interpolated into THREE places at once: a JSON string in the KEYS payload,
# useradd(8) in the guest, and the device record. A name carrying a quote or a
# shell metacharacter would corrupt the payload instead of failing loudly, and
# the failure would surface a boot later as "user missing". Restrict it to a
# portable login name up front.
GUEST_USERS=("${SSH_USER}")
_extra_ok=()
for _u in "${EXTRA_USERS[@]}"; do
    [[ "${_u}" =~ ^[a-z_][a-z0-9_-]*$ ]] \
        || die "--extra-user '${_u}' is not a valid login name (want [a-z_][a-z0-9_-]*)"
    _dup=false
    for _g in "${GUEST_USERS[@]}"; do
        [ "${_g}" = "${_u}" ] && _dup=true
    done
    if ${_dup}; then
        warn "--extra-user ${_u}: already on the guest, ignoring the duplicate"
        continue
    fi
    _extra_ok+=("${_u}")
    GUEST_USERS+=("${_u}")
done
EXTRA_USERS=("${_extra_ok[@]}")

# Rejected HERE rather than in the stage4 block below, which only runs after the
# image has been resolved and a compressed one decompressed — up to a 20GB xz
# pass before telling the operator the flag combination can never work. stage4
# hands its whole qemu to run-qemu-test.sh, which tears the guest down itself,
# so there is no device left for this script to keep alive or advertise.
if ${KEEP_ALIVE} && [ "${MODE}" = "stage4" ]; then
    die "--keep-alive is golden-mode only (stage4 delegates its qemu to run-qemu-test.sh); re-run with --mode golden"
fi

# The three things only the CALLER can know. None is fatal — the record is still
# written, and every field the caller did supply is still right — but each one
# costs the operator a specific capability, so name the capability rather than
# letting the Studio present a button that cannot work. A hand-run `docker run`
# of this entrypoint is supported and will legitimately hit all three.
if ${KEEP_ALIVE} && [ -z "${HOST_WORK}" ]; then
    warn "--keep-alive without --host-work/HOST_WORK: ssh_key and qmp in the device record will be CONTAINER paths (${WORK}/...) and unusable from the host"
fi

if ${KEEP_ALIVE} && [ "${SSH_HOST_PORT}" -eq 0 ]; then
    # The one that silently kills the whole point of --keep-alive: nothing
    # published means nothing to ssh TO, and 0 is a legal recorded value, so the
    # Studio's only correct response is to disable the terminal button. That is
    # indistinguishable from a broken device unless we say so here.
    warn "--keep-alive without --ssh-host-port/SSH_HOST_PORT: the record will say ssh_host_port 0, i.e. NO login is possible and the Studio's terminal button stays disabled. Publish the guest forward with 'docker run -p 127.0.0.1:<port>:${SSH_PORT}' and pass the same <port> here."
fi

if ${KEEP_ALIVE} && [ -z "${CONTAINER_NAME}" ]; then
    warn "--keep-alive without --container/CONTAINER_NAME: the record's \"container\" will be empty, so the Studio cannot match this device against 'docker ps' and will treat it as stopped. Pass the same NAME that 'docker run --name' was given."
fi

# ── Resolve the image ───────────────────────────────────────────────────────
# The builders name artifacts hugmesh-<platform>-<arch>-<role>-<env>-<ts>.img[.xz];
# a session dir holds several roles, so match the role explicitly before falling
# back to "any image for this platform".
autodetect_img() {
    local c
    for c in \
        "${ARTIFACTS}"/hugmesh-"${PLATFORM}"-*-"${ROLE}"-*.img \
        "${ARTIFACTS}"/hugmesh-"${PLATFORM}"-*-"${ROLE}"-*.img.xz \
        "${ARTIFACTS}"/hugmesh-"${PLATFORM}"-*.img \
        "${ARTIFACTS}"/hugmesh-"${PLATFORM}"-*.img.xz ; do
        c="$(ls -1t ${c} 2>/dev/null | grep -ivE '(kernel|initramfs|initrd|squashfs)' | head -1 || true)"
        [ -n "${c}" ] && { printf '%s\n' "${c}"; return 0; }
    done
    return 1
}

autodetect_stage4() {
    local c
    for c in \
        "${ARTIFACTS}"/hugmesh-"${PLATFORM}"-*-"${ROLE}"-*.stage4.tar.xz \
        "${ARTIFACTS}"/*-"${ROLE}"-*.stage4.tar.xz ; do
        c="$(ls -1t ${c} 2>/dev/null | head -1 || true)"
        [ -n "${c}" ] && { printf '%s\n' "${c}"; return 0; }
    done
    return 1
}

[ -d "${QEMU_DIR}" ] || die "repo not mounted at ${SRC} (need ${QEMU_DIR})"

if [ -z "${IMG}" ]; then
    IMG="$(autodetect_img || true)"
fi
[ -n "${IMG}" ] && [ -f "${IMG}" ] || die "no image for ${PLATFORM}/${ROLE} under ${ARTIFACTS}"

# Decompress .img.xz once into the writable work dir; /artifacts is read-only and
# a 9.5-20GB decompress is far too slow to repeat per run, so this is cached and
# reused across runs (and across Studio invocations that share the work dir).
if [[ "${IMG}" == *.img.xz ]]; then
    RAW="${WORK}/images/$(basename "${IMG}" .xz)"
    if [ ! -s "${RAW}" ]; then
        step "Decompressing $(basename "${IMG}") -> $(basename "${RAW}")"
        # --memlimit-mt-decompress: unbounded -T0 ballooned to ~7.2GiB RSS on a
        # high-core host and got SIGKILLed by the global OOM killer when two rows
        # decompressed concurrently (observed as x86_fe "decompress failed" with
        # an intact archive). Bounding the threaded decoder makes xz drop to
        # fewer threads instead of dying.
        #
        # NB the flag name: xz 5.4 (Debian bookworm) spells this
        # --memlimit-mt-decompress. There is no --memlimit-threading here, and an
        # unknown option is a hard error, so this silently became a 100% failure
        # for every compressed row until it was corrected.
        # Clear any partial file from an earlier killed run: it is truncated garbage,
        # and leaving it costs disk while telling the next run nothing (the guard
        # above tests ${RAW}, not ${RAW}.part, so a stale .part is never reused —
        # only leaked).
        rm -f "${RAW}.part"
        xz -dc -T0 --memlimit-mt-decompress=2GiB "${IMG}" > "${RAW}.part" \
            || { rm -f "${RAW}.part"; die "decompress failed"; }
        mv "${RAW}.part" "${RAW}"
    else
        info "reusing cached decompressed image: $(basename "${RAW}")"
    fi
    IMG="${RAW}"
fi
info "image : ${IMG}"

# ── stage4 mode: hand off to the pre-existing harness ───────────────────────
if [ "${MODE}" = "stage4" ]; then
    [ "${PLATFORM}" = "rpi5" ] || die "stage4 mode is aarch64/Pi-only (run-qemu-test.sh hardcodes qemu-system-aarch64); use --mode golden for ${PLATFORM}"
    [ -n "${STAGE4}" ] || STAGE4="$(autodetect_stage4 || true)"
    [ -n "${STAGE4}" ] && [ -f "${STAGE4}" ] || die "no stage4 for ${ROLE} under ${ARTIFACTS}"
    info "stage4: ${STAGE4}"
fi

# ── Kernel: lift it out of the golden image (this is why we need root) ──────
# A build SESSION dir ships only the artifacts — there is no sysroot/ or isoroot/
# for the launchers to autodetect a kernel from, and launch-pi.sh's own
# --kernel-from-img refuses to run unprivileged (launch-pi.sh:199). Inside this
# container we ARE root, so do the extraction here and hand the launcher an
# explicit --kernel.
KERNEL=""
# Mount each partition BY BYTE OFFSET rather than via /dev/loopNpM.
#
# `losetup -P` inside a container scans the partition table but the per-partition
# device nodes never appear: the kernel creates them on the HOST devtmpfs, which
# is not this container's /dev. The table itself is perfectly readable, so we ask
# sfdisk for each partition's start/size and let mount's own loop setup apply the
# offset. Same result, no partition device nodes required — and it behaves
# identically on the host, so there is one code path, not a container special case.
extract_kernel() {
    local want="$1" mnt found="" start size
    mnt="${RUN_DIR}/boot-mnt"; mkdir -p "${mnt}"
    umount "${mnt}" 2>/dev/null || true

    # fd 9 -> a lock file on the SHARED /work volume: every runner container of
    # a parallel matrix run opens the same inode, so flock(9) serializes the
    # loop-claim critical section HOST-WIDE (the containers share the host's
    # loop-device pool, not its /dev). The subshell this function runs in (it
    # is always called via command substitution) closes the fd on return.
    exec 9>"${WORK}/.loop-mount.lock"

    while read -r start size; do
        [ -n "${start}" ] && [ -n "${size}" ] || continue
        [ "${size}" -gt 0 ] 2>/dev/null || continue

        # Retry: loop devices are a HOST-WIDE resource shared by every runner
        # container, and mount's auto-allocation is find-free-then-claim, which
        # races when several rows start at once — the loser gets EBUSY. Without
        # this, running the matrix with --jobs >1 fails rows non-deterministically
        # while the same row passes when run alone. The flock makes the claim
        # deterministic; the sleep-retry stays as a belt-and-suspenders backstop
        # (and still recovers if the lock cannot be taken at all).
        local attempt=0 mounted=false
        while [ "${attempt}" -lt 10 ]; do
            flock -w 120 9 2>/dev/null || true
            if mount -o "ro,offset=$((start * 512)),sizelimit=$((size * 512))" \
                     "${IMG}" "${mnt}" 2>/dev/null; then
                flock -u 9 2>/dev/null || true
                mounted=true; break
            fi
            flock -u 9 2>/dev/null || true
            attempt=$((attempt + 1))
            sleep $((RANDOM % 3 + 1))
        done
        ${mounted} || continue
        for cand in "${mnt}/${want}" "${mnt}/boot/${want}" \
                    "${mnt}/Image" "${mnt}/boot/Image"; do
            if [ -f "${cand}" ]; then
                cp "${cand}" "${RUN_DIR}/${want}" 2>/dev/null && found="${RUN_DIR}/${want}"
                break
            fi
        done
        umount "${mnt}" 2>/dev/null || true
        [ -n "${found}" ] && break
    done < <(sfdisk -d "${IMG}" 2>/dev/null \
             | sed -n 's/.*start=[[:space:]]*\([0-9]\+\).*size=[[:space:]]*\([0-9]\+\).*/\1 \2/p')

    [ -n "${found}" ] || return 1
    printf '%s\n' "${found}"
}

case "${PLATFORM}" in
    x86) : ;;  # self-boots through OVMF/UEFI — no external kernel needed
    rpi5)
        step "Extracting kernel_2712.img from the golden image (offset mount)"
        KERNEL="$(extract_kernel kernel_2712.img)" \
            || die "could not extract kernel_2712.img from ${IMG}"
        info "kernel: ${KERNEL}"
        ;;
    *)
        step "Extracting Image from the golden image (offset mount)"
        KERNEL="$(extract_kernel Image)" \
            || die "could not extract kernel Image from ${IMG}"
        info "kernel: ${KERNEL}"
        ;;
esac

# ── stage4 mode delegates entirely to run-qemu-test.sh ──────────────────────
if [ "${MODE}" = "stage4" ]; then
    step "Delegating to run-qemu-test.sh (stage4 provisioning test)"
    set +e
    bash "${QEMU_DIR}/run-qemu-test.sh" \
        --role "${ROLE}" --kernel "${KERNEL}" --stage4 "${STAGE4}" \
        --test-dir "${RUN_DIR}/stage4-test" \
        --mem "${MEM}" --smp "${SMP}" --ssh-port "${SSH_PORT}" \
        --timeout "${TIMEOUT}" $( ${KEEP} && echo --keep ) 2>&1 | tee "${RUN_DIR}/stage4.log"
    rc=${PIPESTATUS[0]}
    set -e
    # '|| true' is load-bearing, NOT defensive noise — see the twin at the golden
    # path below: under `set -e` + pipefail these assignments ABORT the script
    # whenever the log has no RESULT line, skipping every emit_result and leaving
    # the row's previous result JSON in place to be reported as this run's.
    p="$(grep -oE 'RESULT: [0-9]+ passed' "${RUN_DIR}/stage4.log" | grep -oE '[0-9]+' | head -1 || true)"
    f="$(grep -oE '[0-9]+ failed'         "${RUN_DIR}/stage4.log" | grep -oE '[0-9]+' | head -1 || true)"
    if [ "${rc}" -eq 0 ]; then emit_result PASS "stage4 provisioning test passed" "${p:-0}" "${f:-0}"
    else                       emit_result FAIL "run-qemu-test.sh rc=${rc}"       "${p:-0}" "${f:-0}"; fi
    exit "${rc}"
fi

# ── golden mode ─────────────────────────────────────────────────────────────
# Build the throwaway login key + the FAT32 KEYS disk the first-boot
# keys-provision engine consumes. Payload shape mirrors run-qemu-test.sh so the
# SAME assertions.sh applies to both modes.
step "Generating login key + KEYS provisioning payload"
SSHKEY="${RUN_DIR}/id_ed25519"
rm -f "${SSHKEY}" "${SSHKEY}.pub"
ssh-keygen -t ed25519 -N '' -C "qemu-docker@${LABEL}" -f "${SSHKEY}" >/dev/null \
    || die "ssh-keygen failed"
PUBKEY="$(cat "${SSHKEY}.pub")"

KEYS_SRC="${RUN_DIR}/keys"; rm -rf "${KEYS_SRC}"; mkdir -p "${KEYS_SRC}/ssh" "${KEYS_SRC}/headscale"
[ -f "${SRC}/specs/etc/headscale/config.yaml" ] \
    && cp "${SRC}/specs/etc/headscale/config.yaml" "${KEYS_SRC}/headscale/config.yaml"

# --extra-user accounts, appended to the SAME users.json that already creates
# ${SSH_USER}, because that is the file the guest will actually read:
# provision_users() (specs/etc/keys-provision/provision.sh:272) takes its .users
# array from ${BASE}/users.json, and drops back to the manifest — provision.json
# — ONLY when users.json is absent (provision.sh:273-274). This script always
# writes users.json, so users.json always wins that `[ -f ]` test and an account
# added to provision.json instead would never be created on the guest.
#
# Each entry deliberately mirrors ${SSH_USER}'s, with two deliberate differences:
#   * no "uid" — provision.sh passes -u to useradd only when uid is non-empty
#     (provision.sh:326), so useradd allocates the next free one and nothing
#     collides with ${SSH_USER}'s pinned 1000.
#   * sudo_nopasswd stays true because these accounts get NO password at all.
#     The superuser route is `ssh -t ... sudo -i`, and a password-prompting
#     sudo rule would make that unusable rather than merely inconvenient.
# Root ssh is NOT enabled for any of them: sshd sets PermitRootLogin no and
# assertions.sh:204 asserts it.
EXTRA_USERS_JSON=""
for _u in "${EXTRA_USERS[@]}"; do
    EXTRA_USERS_JSON+=",
    {
      \"name\": \"${_u}\",
      \"comment\": \"QEMU containerized device test user (--extra-user)\",
      \"groups\": [\"wheel\", \"audio\", \"video\", \"usb\"],
      \"shell\": \"/bin/bash\",
      \"sudo\": true,
      \"sudo_nopasswd\": true,
      \"ssh_authorized_keys\": [\"${PUBKEY}\"]
    }"
done

cat > "${KEYS_SRC}/users.json" <<EOF
{
  "users": [
    {
      "name": "${SSH_USER}",
      "comment": "QEMU containerized device test user",
      "groups": ["wheel", "audio", "video", "usb"],
      "shell": "/bin/bash",
      "uid": 1000,
      "sudo": true,
      "sudo_nopasswd": true,
      "ssh_authorized_keys": ["${PUBKEY}"]
    }${EXTRA_USERS_JSON}
  ],
  "root": { "ssh_authorized_keys": ["${PUBKEY}"] }
}
EOF

# headscale is a ROLE-specific service: the builders link it into the default
# runlevel ONLY for the identity/control roles — rpi5: pki|generic
# (build-rpi5-stage4.sh:3842-3845) and x86: pki|omnibus (ROLE_HEADSCALE,
# build-x86-host-stage4.sh:1239/1256) — and explicitly REMOVE the symlink for
# every other role (build-rpi5-stage4.sh:3906-3908). A payload that says
# enabled:true for EVERY role asserts a service the product deliberately does
# not run on workers, which failed the headscale assertions on all four rpi5
# rows (matrix triage 2026-08-13). Keep the payload role-accurate instead.
HS_ENABLED=false
case "${ROLE}" in
    pki|generic|omnibus) HS_ENABLED=true ;;
esac

cat > "${KEYS_SRC}/provision.json" <<EOF
{
  "version": 1,
  "hostname": "hugmesh-${ROLE}-qemu",
  "timezone": "UTC",
  "headscale": { "enabled": ${HS_ENABLED}, "config_file": "headscale/config.yaml" },
  "tailscale": { "enabled": false },
  "kubernetes": { "role": "control-plane", "bootstrap": false },
  "hugmesh": { "role": "${ROLE}", "cluster_domain": "hugmesh.local",
               "gitops": { "enabled": false } }
}
EOF

KEYS_IMG="${RUN_DIR}/keys.img"
bash "${QEMU_DIR}/make-test-keys.sh" "${KEYS_SRC}" "${KEYS_IMG}" 64 \
    || die "make-test-keys.sh failed"

# ── Boot via the platform's own launcher (unmodified) ───────────────────────
LAUNCH_RUN_DIR="${RUN_DIR}/launch"
PIDFILE="${LAUNCH_RUN_DIR}/qemu.pid"
CONSOLE="${LAUNCH_RUN_DIR}/console.log"
mkdir -p "${LAUNCH_RUN_DIR}"

# A5: qemu gets a QMP socket only when one is asked for. --keep-alive implies it
# — a device you cannot pause or power down is only half a device — but with
# neither flag ${QMP_SOCK} stays empty, the launcher argv below is character-
# for-character what it was, and qemu keeps running -monitor none.
# The socket goes under the /work bind mount because the socket's PATH is what
# the record advertises; a unix socket anywhere else in this container's
# filesystem could not even be named to the host. Connecting to it is a
# different matter and NOT something this script arranges: qemu creates it
# root-owned, so callers reach it through `docker exec` on this container.
#
# This is a passthrough and nothing more. In particular it does not alter reset
# semantics: launch-pi.sh, launch-arm.sh and launch-x86.sh each put -no-reboot in
# their qemu argv unconditionally, and qemu documents -no-reboot as "exit instead
# of rebooting", so what a QMP system_reset does to the guest is decided by the
# launcher argv and by whoever sends the command, not here.
if ${KEEP_ALIVE} && [ -z "${QMP_SOCK}" ]; then
    QMP_SOCK="${LAUNCH_RUN_DIR}/qmp.sock"
fi

step "Booting ${PLATFORM}/${ROLE} (mem=${MEM}M smp=${SMP})"
case "${PLATFORM}" in
    rpi5)
        bash "${QEMU_DIR}/launch-pi.sh" \
            --img "${IMG}" --kernel "${KERNEL}" --keys-img "${KEYS_IMG}" \
            --run-dir "${LAUNCH_RUN_DIR}" --keep \
            --mem "${MEM}" --smp "${SMP}" \
            --ssh-port "${SSH_PORT}" --ui-port "${UI_PORT}" \
            --timeout "${TIMEOUT}" ${QMP_SOCK:+--qmp "${QMP_SOCK}"} 2>&1 | tee "${RUN_DIR}/launch.log"
        lrc=${PIPESTATUS[0]}
        ;;
    x86)
        # /dev/kvm is passed through when available; launch-x86.sh's accel=kvm:tcg
        # already degrades to TCG on its own if the device is absent/unusable.
        bash "${QEMU_DIR}/launch-x86.sh" \
            --img "${IMG}" --keys-img "${KEYS_IMG}" \
            --run-dir "${LAUNCH_RUN_DIR}" --keep \
            --mem "${MEM}" --smp "${SMP}" \
            --ssh-port "${SSH_PORT}" --ui-port "${UI_PORT}" \
            --timeout "${TIMEOUT}" ${QMP_SOCK:+--qmp "${QMP_SOCK}"} 2>&1 | tee "${RUN_DIR}/launch.log"
        lrc=${PIPESTATUS[0]}
        ;;
    *)
        bash "${QEMU_DIR}/launch-arm.sh" \
            --platform "${PLATFORM}" ${BOARD:+--board "${BOARD}"} \
            --img "${IMG}" --kernel "${KERNEL}" --keys-img "${KEYS_IMG}" \
            --run-dir "${LAUNCH_RUN_DIR}" --keep \
            --mem "${MEM}" --smp "${SMP}" \
            --ssh-port "${SSH_PORT}" --ui-port "${UI_PORT}" \
            --timeout "${TIMEOUT}" ${QMP_SOCK:+--qmp "${QMP_SOCK}"} 2>&1 | tee "${RUN_DIR}/launch.log"
        lrc=${PIPESTATUS[0]}
        ;;
esac
[ "${lrc}" -eq 0 ] || die "launcher exited ${lrc} (see ${RUN_DIR}/launch.log)"

# NB: this REPLACES the earlier `trap reown EXIT`, so it must call reown itself —
# otherwise the run's artifacts stay root-owned on the host.
cleanup() {
    # Best effort, and deliberately FIRST: whatever brought us here — docker
    # stop, a die() below, qemu dying on its own — the guest is about to go
    # away, and the Studio reads any state but "stopped" as a device it can
    # still ssh into. A stale "running" record would offer the operator a
    # terminal button that connects to nothing.
    if ${KEEP_ALIVE} && [ -f "${DEVICE_JSON}" ]; then
        write_device_record stopped
    fi
    [ -f "${PIDFILE}" ] && kill "$(cat "${PIDFILE}")" 2>/dev/null || true
    ${KEEP} || rm -f "${RUN_DIR}"/launch/run.qcow2 2>/dev/null || true
    reown
}
trap cleanup EXIT

# Publish the BOOTING record now that qemu is actually running — deliberately
# after the cleanup trap above, so no exit from here on can leave a record
# behind that cleanup() will not flip to "stopped". Before this record existed
# a device killed during its (minutes-long, TCG) boot vanished without trace:
# no registry entry, no verdict, and its port claim leaked because nothing
# named a container to reconcile against. The record is rewritten as the state
# advances: booting -> running -> assertions -> running -> stopped.
if ${KEEP_ALIVE}; then
    write_device_record booting
    info "device record (booting): ${DEVICE_JSON}"
fi

# ── Wait for the guest, then assert ─────────────────────────────────────────
SSH_OPTS=(-i "${SSHKEY}" -p "${SSH_PORT}"
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=5 -o LogLevel=ERROR)

# A `docker stop` (or a Studio cancel, or a ctrl-C through `docker run -it`)
# that lands during the ssh wait used to leave NOTHING: bash has no default
# TERM/INT handling that runs the EXIT trap, so the container died at exit 143
# with no result JSON, no console tail, and — under --keep-alive — a port claim
# still naming it (2026-08-19: x86/be and x86/pki, both killed mid-boot, both
# invisible to the summary except as "container wrote no result JSON", claims
# 22303/22309 leaked). The verdict is written FIRST, then the same cleanup that
# any other exit runs, then the signal is re-raised so the wait status still
# says what happened. This shim is exec'd as PID 1, and PID 1 does receive
# signals it has handlers for; the loop below sleeps in the BACKGROUND so
# delivery is never deferred past docker's 10s SIGKILL grace.
sshwait_on_signal() {
    local sig="$1"
    warn "received SIG${sig} while waiting for guest SSH — writing the FAIL verdict this row would otherwise lose"
    echo "----- last 80 lines of console -----"
    tail -n 80 "${CONSOLE}" 2>/dev/null || true
    emit_result FAIL "killed while waiting for guest SSH (SIG${sig})"
    trap - TERM INT EXIT
    cleanup
    # Re-raise so the wait status reports the signal — except as PID 1, where
    # the kernel discards a default-disposition signal a process sends itself,
    # so the 128+signo convention is spelled out as the fallback. Never 0.
    kill -s "${sig}" $$
    if [ "${sig}" = "INT" ]; then exit 130; else exit 143; fi
}
trap 'sshwait_on_signal TERM' TERM
trap 'sshwait_on_signal INT'  INT

step "Waiting up to ${TIMEOUT}s for guest SSH (${SSH_USER}@localhost:${SSH_PORT})"
deadline=$((SECONDS + TIMEOUT)); up=false
while [ "${SECONDS}" -lt "${deadline}" ]; do
    if [ -f "${PIDFILE}" ] && ! kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; then
        warn "QEMU exited early"; break
    fi
    if ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" true 2>/dev/null; then up=true; break; fi
    # Background + wait, not a plain sleep: bash defers a trap until the
    # current FOREGROUND child returns, and 5s of deferral is half of docker
    # stop's grace window (see keepalive_wait below for the same pattern).
    sleep 5 & wait $! 2>/dev/null || true
done

if ! ${up}; then
    echo "----- last 80 lines of console -----"
    tail -n 80 "${CONSOLE}" 2>/dev/null || true
    emit_result FAIL "guest did not reach SSH within ${TIMEOUT}s"
    exit 1
fi
# The ssh wait is over: this trap's verdict text would be a lie from here on,
# and every later phase is timeout-bounded and writes its own emit_result.
trap - TERM INT
info "SSH is up; running assertions"

# A2: publish the device the moment it answers, BEFORE the assertions — they are
# the long pole (minutes on TCG), and a device the operator cannot open a
# terminal on until they finish is a device that looks broken for most of its
# life. The record is rewritten as the state changes; it is not append-only.
if ${KEEP_ALIVE}; then
    write_device_record running
    info "device record: ${DEVICE_JSON}"
    info "  logins: ${GUEST_USERS[*]}"
    if [ "${SSH_HOST_PORT}" -eq 0 ]; then
        info "  ssh   : none — nothing was published (see the WARN above)"
    else
        info "  ssh   : -i $(host_path "${SSHKEY}") -p ${SSH_HOST_PORT} <login>@127.0.0.1"
    fi
fi

step "Running assertions.sh in the guest (wall clock: ${ASSERT_TIMEOUT}s)"
if ${KEEP_ALIVE}; then write_device_record assertions; fi
# THE ONLY wall clock over the post-boot phase. ${TIMEOUT} bounds the ssh-wait
# loop above and stops the moment SSH answers; SSH_OPTS carries ConnectTimeout=5,
# which bounds the TCP connect and NOTHING after the handshake. So a guest that
# wedges mid-assertion (TCG livelock, a check that blocks on a dead service)
# pins this container forever while holding one of the very few --jobs slots.
#
# -k 30 is not optional: plain `timeout` sends SIGTERM and then waits for the
# child indefinitely, so if the ssh client is itself the thing that will not
# die, the bound is defeated. After SIGTERM it gets 30s, then SIGKILL.
#
# Sizing (measured, this machine's out/qemu-runs/results/*.json): of the rows
# that got as far as RUNNING assertions, duration_s was 90/93/93 for the three
# that passed and 260 for the slowest, rpi5/pki. Those numbers cover the WHOLE
# row — boot, ssh wait, assertions, diagnostics — so the assertion ssh alone is
# strictly under them. (The 2426-2783s rows in that same directory are boot
# timeouts; they never reached this phase, and ${TIMEOUT} already bounds them.)
# 900s is ~3.5x the slowest whole row that ever asserted, which is the margin a
# healthy but slow TCG/ARM row needs. --assert-timeout is used verbatim if an
# operator disagrees: no floor, no clamp, in either direction.
#
# RETRIES, and only for the transport. ssh reports its OWN failures as 255 —
# never the streamed script's, whose exits are 0/1 — so 255 here means the
# connection could not be held: a guest still settling after boot (sshd
# restarted under it), or a banner exchange that timed out (both rpi5 rows on
# 2026-08-19 died exactly there: "Connection timed out during banner exchange"
# is the LAST line of their assertions.log). Those deserve another attempt
# before a FAIL; a real verdict (0/1) or a timeout kill (124/137) never
# retries. Each attempt overwrites assertions.log via tee, so the graded log is
# always the last attempt's. ConnectTimeout is raised to 15s for this one ssh,
# and it goes BEFORE ${SSH_OPTS[@]}: ssh keeps the FIRST value it obtains for
# an option, so appended after the array it would silently lose to the 5.
set +e
ASSERT_ATTEMPTS=0
while :; do
    ASSERT_ATTEMPTS=$((ASSERT_ATTEMPTS + 1))
    timeout -k 30 "${ASSERT_TIMEOUT}" \
        ssh -o ConnectTimeout=15 "${SSH_OPTS[@]}" "${SSH_USER}@localhost" 'sudo bash -s' \
        < "${QEMU_DIR}/assertions.sh" 2>&1 | tee "${RUN_DIR}/assertions.log"
    ARC=${PIPESTATUS[0]}
    [ "${ARC}" -eq 255 ] || break
    [ "${ASSERT_ATTEMPTS}" -lt 3 ] || break
    warn "assertion ssh could not hold a connection (rc=255, attempt ${ASSERT_ATTEMPTS}/3); retrying in $((ASSERT_ATTEMPTS * 5))s"
    sleep $((ASSERT_ATTEMPTS * 5))
done
set -e

# Assertions are over (passed, failed or killed — the device is up either way,
# and a FAILED row is exactly the one an operator wants a terminal on).
# write_device_record always returns 0, which matters: errexit is ON from here
# to the end of the script, and this must never become another statement that
# can abort the run before emit_result.
if ${KEEP_ALIVE}; then write_device_record running; fi

# ── Guest diagnostics: pin failures that die INSIDE the guest ───────────────
# The rpi5/pki row really fails to start headscale, but the guest's log files
# were unreadable from the host (root-owned ext4 inside the golden image), so
# the exact error was never pinned. Pull the provisioning + headscale logs out
# over the SSH channel we already hold, into the row's run dir, before the
# guest is powered off.
# TODO(pki/headscale): suspected OpenRC inception — keys-provision's start()
# inline-starts headscale while the declared init ordering also runs
# keys-provision BEFORE headscale. Fixing that is an IMAGE-side change (only
# matters after a rebuild) and is deliberately deferred until these captured
# logs pin the exact startup error.
#
# Every ssh below is timeout-wrapped for the same reason as the assertion ssh:
# ConnectTimeout=5 does not bound an established session, and these run in
# EXACTLY the state where a hang is likely — a guest that just failed or timed
# out. The bound can be tight here because each call already ends in `|| true`:
# the cost of a spurious timeout is one missing diagnostic file, never the
# verdict. Bounds the whole teardown at 4 x (60 + 5) here plus 65s for the
# poweroff below, i.e. 325s, where it was previously unbounded.
step "Collecting guest diagnostics into ${RUN_DIR}"
for gf in /var/log/keys-provision.log /var/log/headscale.err /var/log/headscale.log; do
    timeout -k 5 60 ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" "sudo cat ${gf}" \
        > "${RUN_DIR}/guest$(echo "${gf}" | tr '/' '_')" 2>/dev/null || true
done
timeout -k 5 60 ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" \
    'sudo rc-service headscale status 2>&1; echo "--- rc-update ---"; sudo rc-update show default 2>&1' \
    > "${RUN_DIR}/guest_headscale-status.txt" 2>/dev/null || true
# NetworkManager state: several boot-time failures (a guest that answers ssh on
# the slirp NIC but never brings its provisioned connections up, or an rc
# service stuck in 'starting') are only diagnosable from the NM/OpenRC side,
# and those logs are as unreadable from the host as the headscale ones above.
# Same shape as every other diagnostic here: timeout-bounded, best-effort,
# `|| true` throughout — a missing tool prints its own error into the capture
# instead of failing the harvest.
timeout -k 5 60 ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" \
    'sudo rc-status 2>&1; echo "--- nmcli general status ---"; sudo nmcli general status 2>&1 || true; echo "--- nmcli device ---"; sudo nmcli device 2>&1 || true; echo "--- rc.log tail ---"; sudo tail -n 200 /var/log/rc.log 2>&1 || true; echo "--- NetworkManager syslog ---"; sudo grep -ah NetworkManager /var/log/messages /var/log/syslog 2>/dev/null | tail -n 100 || true' \
    > "${RUN_DIR}/guest_networkmanager-status.txt" 2>/dev/null || true

if ${KEEP_ALIVE}; then
    info "keep-alive: ${LABEL} stays up — not powering the guest down"
else
    step "Powering down guest"
    # `sudo poweroff` legitimately tears the channel down under ssh's feet, so this
    # call's own failure has always been ignored — but "ignored" is not "bounded",
    # and a guest that accepts the command and then never closes the socket left it
    # blocking forever. The qcow2 overlay is discarded by cleanup() either way.
    timeout -k 5 60 ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" 'sudo poweroff' 2>/dev/null || true
    sleep 3
fi

# emit_assertion_verdict — grade ${ARC} + the assertions.log into the row's
# result JSON, and correct ${ARC} when the two disagree. A function (a) so the
# grading is one auditable unit and (b) so tests/qemu/verdict_test.sh can
# extract and drive it hermetically, the way devices_test.sh drives the port
# allocator. Always returns 0: errexit is ON at the call site and this must
# never be the statement that aborts the run after the verdict is written.
emit_assertion_verdict() {
    local log="${RUN_DIR}/assertions.log" note=""
    [ "${ASSERT_ATTEMPTS:-1}" -gt 1 ] && note=" (ssh attempts: ${ASSERT_ATTEMPTS})"
    # '|| true' is load-bearing: under `set -e` + pipefail a log with no
    # "RESULT: N passed" line would make these assignments ABORT the script —
    # past both emit_result calls — leaving the row's PREVIOUS result JSON on
    # disk to be reported as this run's.
    PASSED="$(grep -oE 'RESULT: [0-9]+ passed' "${log}" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
    FAILED="$(grep -oE '[0-9]+ failed'          "${log}" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
    if [ "${ARC}" -eq 0 ] && ! grep -q '== RESULT:' "${log}" 2>/dev/null; then
        # THE VERDICT LINE IS PART OF THE CONTRACT. assertions.sh is STREAMED
        # into `bash -s`, so anything in it that reads stdin can eat the rest of
        # the script and bash then EOF-exits 0 with the run incomplete — which
        # is exactly how ausearch turned six 2026-08-19 rows holding 9-12 real
        # FAILs each into "PASS": every one of their logs stops dead at the
        # '-- AVC harvest' header. ssh saying 0 is therefore only believed when
        # the script's own last line ('== RESULT: N passed, M failed ==') made
        # it out; otherwise the row FAILS and says why.
        warn "${LABEL}: DEVICE TEST FAILED — ssh exited 0 but assertions.sh never printed its RESULT line (truncated run graded as PASS is the 2026-08-19 defect)"
        emit_result FAIL "assertions did not complete (no RESULT line)${note}" "${PASSED:-0}" "${FAILED:-0}"
        ARC=1
    elif [ "${ARC}" -eq 0 ]; then
        info "${GREEN}${LABEL}: DEVICE TEST PASSED${RST} (${PASSED:-?} assertions)"
        emit_result PASS "all assertions passed${note}" "${PASSED:-0}" "${FAILED:-0}"
    elif [ "${ARC}" -eq 124 ] || [ "${ARC}" -eq 137 ]; then
        # timeout(1) reports 124 when SIGTERM was enough and 137 when it had to
        # escalate to SIGKILL. Neither can come from the guest here: assertions.sh
        # ends in `[ "${FAIL}" -eq 0 ]`, so its only exit codes are 0 and 1, and ssh
        # reports its own transport failures as 255. A row that hits this is a HANG,
        # not a failed assertion — say so, with whatever partial counts the log held,
        # rather than filing it under the generic "assertions failed".
        warn "${LABEL}: DEVICE TEST TIMED OUT after ${ASSERT_TIMEOUT}s (rc=${ARC})"
        emit_result FAIL "assertion ssh exceeded its ${ASSERT_TIMEOUT}s wall clock; killed${note}" \
            "${PASSED:-0}" "${FAILED:-0}"
    elif [ "${ARC}" -eq 255 ]; then
        # The transport never held, through every retry above. Distinct from
        # "assertions failed" because nothing was asserted at all.
        warn "${LABEL}: DEVICE TEST FAILED — assertion ssh could not hold a connection (rc=255)"
        emit_result FAIL "assertion ssh could not connect${note:- (ssh attempts: ${ASSERT_ATTEMPTS:-1})}" \
            "${PASSED:-0}" "${FAILED:-0}"
    else
        warn "${LABEL}: DEVICE TEST FAILED (${FAILED:-?} assertions failed)"
        emit_result FAIL "assertions failed${note}" "${PASSED:-0}" "${FAILED:-0}"
    fi
    return 0
}
emit_assertion_verdict

# ── keep-alive: hold the container open ─────────────────────────────────────
# The verdict is already on disk above, so the matrix reports this row normally
# whether or not anyone ever logs in. All that is left is to not exit: PID 1
# returning is what ends the container, and with it qemu and the ssh port.
KEEPALIVE_STOP=false
keepalive_wait() {
    local nap
    # `docker stop` sends SIGTERM to PID 1 and SIGKILLs 10s later. bash defers a
    # trap until the current FOREGROUND child returns, so a plain `sleep 30`
    # here would swallow SIGTERM well past that grace window and the container
    # would be killed outright — skipping cleanup(), leaving a record that still
    # advertises a device which no longer exists. Sleeping in the BACKGROUND and
    # waiting on the job lets the trap run the moment the signal lands.
    trap 'KEEPALIVE_STOP=true' TERM INT
    while ! ${KEEPALIVE_STOP}; do
        # Also stop waiting if qemu died without us: a guest powered off from
        # the inside, or an OOM kill. Holding the container open around a dead
        # guest just burns a --jobs slot.
        if [ -f "${PIDFILE}" ] && ! kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; then
            warn "qemu exited on its own — ending keep-alive"
            break
        fi
        sleep 5 &
        nap=$!
        # wait(1) reports 128+signo when a trap interrupts it. That is the
        # normal stop path, not a failure — and errexit is ON here.
        wait "${nap}" 2>/dev/null || true
    done
    return 0
}

if ${KEEP_ALIVE}; then
    if [ -n "${CONTAINER_NAME}" ]; then
        step "keep-alive: ${LABEL} is up. Stop it with: docker stop ${CONTAINER_NAME}"
    else
        step "keep-alive: ${LABEL} is up. Stop it with: docker stop <this container>"
    fi
    keepalive_wait
    info "keep-alive: stopping ${LABEL}"
fi
exit "${ARC}"

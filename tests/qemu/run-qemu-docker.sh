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
# KEEP-ALIVE / DEVICE CONTROL PLANE
# ---------------------------------
# By default a row boots, asserts, powers the guest off and the container exits —
# that is the test. With --keep-alive the devices are left RUNNING instead, their
# ssh is published on loopback, and docker-entrypoint.sh writes one JSON record
# per device under ${WORK}/devices/. That registry is the whole interface the
# Studio needs to open a terminal on a device (studio/hugmesh_studio/core/
# qemu_devices.py reads it), which is why the --devices/--stop-device/
# --stop-all-devices/--qmp subcommands below boot nothing at all: they are a
# control plane over containers a PREVIOUS invocation started.
#
# THE HOST PORT IS ALLOCATED HERE AND NOWHERE ELSE. Only this script can pick a
# free host port, because only it talks to the host's docker; the entrypoint
# inside the container cannot see the host's port space at all. So the chosen
# port is BOTH published (-p 127.0.0.1:<port>:2222) AND handed to the entrypoint
# (-e SSH_HOST_PORT=<port>) so it can write it into the record the Studio reads.
# Same for the container name (-e CONTAINER_NAME): inside a container
# /etc/hostname is the short container ID, which no `docker ps` name matches.
#
# --qmp reset IS DESTRUCTIVE and is labelled that way everywhere it appears.
# tests/qemu/launch-{pi,arm,x86}.sh all boot qemu with -no-reboot, under which a
# reset request makes QEMU EXIT instead of rebooting — so a QMP system_reset
# kills the guest. Verified here against qemu-system-x86_64 10.2.3: with
# -no-reboot the process was gone one second after system_reset answered
# {"return": {}}; the same qemu without -no-reboot survived it. Dropping
# -no-reboot is not this script's call — the launchers hardcode it and the
# assertion path shares them — so the verb keeps QEMU's own name and the runner
# says out loud what it does.
#
# PAUSE AND SAVE (--save-device)
# ------------------------------
# Pause a running device and copy its whole disk to a standalone qcow2 the
# operator keeps. Three things about it are not obvious and are load-bearing:
#
#   * IT CANNOT BE DONE WITH qemu-img. While the device is up QEMU holds a write
#     lock on the run overlay AND on the golden .img behind it, so an external
#     `qemu-img convert`/`commit` fails outright with `Failed to get "write"
#     lock` — 100% of the time, not intermittently. The copy therefore goes
#     through QEMU itself: blockdev-add the target, blockdev-backup sync=full,
#     wait for the job's completion EVENT. Measured on qemu 10.2.3 against a
#     qcow2-over-raw chain, which is exactly the chain the launchers build.
#   * THE RESULT IS STANDALONE AND MERGED: no backing file, carrying the
#     overlay's delta on top of the golden's data. That is what makes it a copy
#     of "everything" rather than a diff that is useless without the artifact.
#   * block-commit IS NOT OFFERED, by design. It writes the overlay INTO the
#     golden build artifact and then drops the overlay from the chain, so every
#     later guest write in that session lands on the shared artifact — verified
#     (0xaa became 0xbb in the golden, and query-block reported the backing file
#     as the golden with no overlay left). It is irreversible and it poisons
#     every future run of that image, so there is no flag and no code path for
#     it here. --overwrite NEVER means that: it means replacing a previous SAVE.
#
# The copy is CRASH-CONSISTENT and the runner says so rather than claiming more:
# the guest is flushed over ssh when it is reachable, then paused with QMP
# `stop`, which is a pulled plug as far as the guest is concerned. Afterwards
# the device is returned to the run state it was ALREADY in — a device the
# operator had paused by hand stays paused.
#
# Examples:
#   ./tests/qemu/run-qemu-docker.sh --list
#   ./tests/qemu/run-qemu-docker.sh --platform rpi5
#   ./tests/qemu/run-qemu-docker.sh --session out/sessions/20260807-071119-5c1ccb --jobs 2
#   ./tests/qemu/run-qemu-docker.sh --platform rpi5 --keep-alive --extra-user alice
#   ./tests/qemu/run-qemu-docker.sh --devices
#   ./tests/qemu/run-qemu-docker.sh --qmp rpi5/pki pause
#   ./tests/qemu/run-qemu-docker.sh --save-device rpi5/pki
#   ./tests/qemu/run-qemu-docker.sh --save-device rpi5/pki --overwrite
#   ./tests/qemu/run-qemu-docker.sh --list-saves rpi5/pki
#   ./tests/qemu/run-qemu-docker.sh --stop-all-devices
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# THE role vocabulary (scripts/_roles-lib.sh). This script parses a role out of an
# ARTIFACT FILENAME, and its Python twin (studio/hugmesh_studio/core/qemu_tests.py
# parse_artifact_name) does the same thing independently — so both must canonicalize,
# or an image built before the vocabulary converged reads as `be` here and `backend`
# there and the runner boots the wrong image for a row. studio/tests/test_qemu_tests.py
# ::test_shell_and_python_agree_on_row_discovery is what catches that divergence.
# shellcheck source=scripts/_roles-lib.sh
source "${REPO_DIR}/scripts/_roles-lib.sh"

IMAGE_TAG="${IMAGE_TAG:-hugmesh-qemu-runner:latest}"
SESSION=""
ARTIFACTS=""
WORK="${REPO_DIR}/out/qemu-runs"
PLATFORM_FILTER=""
ROLE_FILTER=""
ONLY=""
# Exact "<platform>/<role>" equality, for callers that mean ONE row and cannot
# afford substring surprises: --only be matches be, be+gpu AND be-ha, which is
# fine for a human and wrong for a per-device Start button.
ONLY_EXACT=""
MODE="golden"
JOBS="2"
# Cap (GiB) on the decompressed-image cache under ${WORK}/images, enforced by
# cache_sweep below. 0 = unbounded, the historical behaviour.
CACHE_MAX_GB="0"
# How long a started keep-alive row may gate admission of the next one before
# the stagger lets it through anyway (see admission_poll). Env-overridable so
# the hermetic tests need not wait two real minutes.
ADMIT_STAGGER="${ADMIT_STAGGER:-120}"
MEM="2048"
SMP="2"
TIMEOUT="2400"
# Empty = let docker-entrypoint.sh's own default stand. Deliberately NOT mirrored
# as a number here: this script only forwards what the operator actually asked
# for, so the default lives in exactly one file and cannot drift between them.
ASSERT_TIMEOUT=""
LIST_ONLY=false
FORCE_BUILD=false
KEEP=false
KEEP_ALIVE=false
# ── Shared-L2 mesh lane (issue #48 phase 4) — --keep-alive only, default-off ──
# A fleet of keep-alive devices is a fleet of ISLANDS today: each guest sits
# behind its own slirp user-net, every one of them believing it is 10.0.2.15,
# with no path to any other. --mesh-net gives the fleet a second NIC on ONE
# broadcast domain, so the emulated mesh can actually form a cluster.
#
# Two things are needed and neither is invented here:
#   * the L2 itself — a per-session docker BRIDGE network every device
#     container joins. Containers on one bridge share an L2, which is what makes
#     QEMU's UDP-multicast socket netdev reach the other guests at all;
#   * the identities — MAC and static IP per row, from the PLANNER's identity
#     file (studio/hugmesh_studio/core/mesh_emulation.py identities). One source
#     of identities, so the address the Studio shows is the address the guest
#     configures.
MESH_NET=""                    # SPEC (ADDR:PORT|mcast=|listen=|connect=) or "auto"
IDENTITIES=""                  # the planner's identity file
# Per-session bridge name. Prefixed like the containers, and for the same
# reason: it is the ONLY test that decides whether this script may delete a
# docker network, and the operator's live stack has networks of its own.
MESH_NAME_PREFIX="hugmesh-qemu-mesh-"
MESH_NET_NAME=""               # resolved from the session hash at start time
# Extra wheel logins to add to the guest payload. Empty by default so a run with
# no --extra-user forwards nothing and the payload stays exactly what it is today.
EXTRA_USERS=()
# Device control-plane subcommand, if any. Set => boot nothing, act on the
# containers a previous --keep-alive run left up, exit.
DEV_ACTION=""
DEV_LABEL=""
DEV_QMP_CMD=""

# ── Pause-and-save knobs ────────────────────────────────────────────────────
# Empty = pick a NEW timestamped copy under ${WORK}/saves (see save_pick_target).
DEV_SAVE_TO=""
# OFF by default and armed only by an explicit --overwrite, because the flag's
# whole job is to permit destroying a copy the operator already has: the target
# is recreated BEFORE the block job starts, so a failure half way through leaves
# neither the old copy nor a complete new one.
DEV_SAVE_OVERWRITE=false
# Wall clock for the whole blockdev-backup conversation, host side. Generous on
# purpose: `sync=full` copies everything the source reads as ALLOCATED, and the
# real goldens are allocated in full (see the note beside SAVES_DIR), so a save is
# a multi-GB copy at TCG speed rather than the small delta a sparse test image
# suggests. --save-timeout overrides it verbatim.
DEV_SAVE_TIMEOUT="3600"
# The QMP name of the disk being saved. All three launchers spell the guest's
# root disk `-drive file=...,if=none,id=hd0` — launch-pi.sh:254, launch-x86.sh:230,
# launch-arm.sh:307 — and blockdev-backup accepts that BlockBackend name as its
# `device`. It is deliberately NOT the KEYS disk (id=keys), which is a synthetic
# read-only provisioning payload this harness fabricates per run.
SAVE_DRIVE="hd0"
# The transient target node and job. Both are fixed strings, never operator text:
# they end up inside the QMP arguments object, and node-names are constrained to
# [A-Za-z0-9-._] by QEMU anyway.
SAVE_NODE="hugmesh-save-tgt"
SAVE_JOB="hugmesh-save"
# The alarm the five-verb --qmp path has always run under, now named because the
# save path needs a much longer one for the same client.
QMP_TIMEOUT=15

# Host ports published for keep-alive devices. Loopback ONLY, and a private range
# with nothing else in it: the operator runs a live hugmesh stack on this machine
# and the container header (docker/Dockerfile.qemu-runner "NETWORKING NOTE") is
# explicit that the harness has always stayed off :8080/:8443. Publishing at all
# is new, so the range is the guard rail that keeps that promise true.
DEV_PORT_MIN=22300
DEV_PORT_MAX=22399
# The port the guest's :22 is forwarded to INSIDE the container: docker-entrypoint.sh
# SSH_PORT, which it hands to launch-*.sh --ssh-port, which spells it
# `hostfwd=tcp::<port>-:22`. That forward has no bind address, so it listens on all
# of the container's interfaces — which is exactly why `-p 127.0.0.1:<host>:2222`
# can reach it while the guest itself stays unreachable from outside this host.
GUEST_SSH_PORT=2222
# Keep-alive containers are named per ROW, not per PID like the test containers
# below. --stop-device and --qmp run in a LATER invocation of this script and have
# to find the container again; a name derived from $$ would be unfindable, and a
# second --keep-alive run of the same row would silently start a rival container
# fighting the first one for the same registry record and run dir.
DEV_NAME_PREFIX="hugmesh-qemu-dev-"

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
  --only-exact L    exact "<platform>/<role>" equality — ONE row, no substring
                    surprises ("x86/be" never drags in be+gpu/be-ha). This is
                    the spelling a per-device Start uses.
  --mode M          golden (default; boots the real .img) | stage4
  -j, --jobs N      concurrent emulated devices. 0 = UNGATED: start every row at
                    once, no admission gate at all (see --keep-alive below for
                    what that gate does). Default: ${JOBS}
  --cache-max-gb N  bound the decompressed-image cache (<work>/images) to N GiB,
                    evicting least-recently-touched images first. NEVER deletes
                    a .part mid-decompress, an image referenced by a device
                    record whose container still exists, or this run's own
                    rows. 0 (default) = unbounded, the historical behaviour.
  --mem MB          guest RAM per device. Default: ${MEM}
  --smp N           guest vCPUs per device. Default: ${SMP}
  -t, --timeout SEC guest SSH wait. Default: ${TIMEOUT}
  --assert-timeout SEC
                    wall clock for the in-guest assertion ssh, forwarded to the
                    container. Used verbatim, never clamped. Unset = the
                    entrypoint's own default.
  --list            enumerate the rows that WOULD run, then exit
  --build-image     (re)build the runner image before running
  --keep            keep per-run scratch dirs
  --keep-alive      leave every device RUNNING after its assertions instead of
                    powering it off, publish its ssh on a free loopback port in
                    ${DEV_PORT_MIN}-${DEV_PORT_MAX}, and write the device registry the
                    Studio reads. -j/--jobs is an ADMISSION GATE here: at most
                    N rows boot at once, each admitting the next when its
                    registry record appears or after ${ADMIT_STAGGER}s, whichever is
                    first. --jobs 0 starts everything at once (the old, ungated
                    fan-out that ran 3 TCG + 7 KVM guests simultaneously).
  --extra-user NAME additional wheel login on the guest, repeatable. Forwarded to
                    the container payload. Root ssh stays off (assertions.sh
                    asserts PermitRootLogin no), so a superuser shell is one of
                    these logins plus 'sudo -i'.
  -h, --help

Shared-L2 mesh (--keep-alive only; both flags off by default, and a run without
them starts exactly the containers it always did):
  --mesh-net SPEC   put every device on ONE shared L2 so the guests can reach
                    each other: a per-session docker bridge network joins the
                    containers, and each guest gets a second virtio NIC on a
                    QEMU socket netdev over it. SPEC is the launchers' own
                    grammar (ADDR:PORT multicast, or mcast=/listen=/connect=),
                    or 'auto' to take the SPEC from the identity file. The
                    bridge is created idempotently and removed by
                    --stop-all-devices once its last member is gone.
  --identities FILE the planner's identity file — the ONE source of the fleet's
                    MACs and IPs. Required by --mesh-net (this script never
                    mints an identity of its own). Mint it with:
                      PYTHONPATH=studio python3 -m \\
                        hugmesh_studio.core.mesh_emulation identities --out FILE

Device subcommands. These boot, build and decompress NOTHING, and are safe to
run while a matrix or a set of devices is up:
  --devices             print the device registry as one JSON array, then exit
  --stop-device LABEL   stop one device ("rpi5/pki", or "rpi5_pki" as filed)
  --stop-all-devices    stop every device container this harness started
  --qmp LABEL CMD       drive a running device's QEMU monitor over its QMP
                        socket, via 'docker exec' on that device's container.
                        CMD: pause | resume | powerdown | status | reset
                        reset is DESTRUCTIVE: the launchers boot with -no-reboot,
                        under which QEMU EXITS on a reset instead of rebooting,
                        so the guest goes down and has to be started again.

Pause and save. The device is flushed, PAUSED, copied through QEMU's own block
layer and then returned to the run state it was already in. The copy is
crash-consistent, standalone (no backing file) and merged (the run overlay's
delta on top of the golden's data). The golden build artifact is NEVER written:
  --save-device LABEL   save LABEL's disk. Default target is a NEW timestamped
                        copy, so repeated saves never destroy an earlier one.
  --save-to PATH        explicit target. A bare name lands in <work>/saves/;
                        must stay under --work and must end in .qcow2.
  --overwrite           permit REPLACING an existing copy. Off unless asked for.
                        With no --save-to it targets this device's newest
                        existing save — "the existing copy in the session".
                        It never means writing into the golden image.
  --save-timeout SEC    wall clock for the copy. Default: ${DEV_SAVE_TIMEOUT}
  --list-saves LABEL    print the saves that exist for LABEL, as a JSON array
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
        --only-exact)   [ $# -ge 2 ] || { echo "--only-exact needs a platform/role label" >&2; usage 1; }
                        ONLY_EXACT="$2"; shift 2 ;;
        --mode)         MODE="$2"; shift 2 ;;
        -j|--jobs)      JOBS="$2"; shift 2 ;;
        --cache-max-gb) [ $# -ge 2 ] || { echo "--cache-max-gb needs a number of GiB" >&2; usage 1; }
                        CACHE_MAX_GB="$2"; shift 2 ;;
        --mem)          MEM="$2"; shift 2 ;;
        --smp)          SMP="$2"; shift 2 ;;
        -t|--timeout)   TIMEOUT="$2"; shift 2 ;;
        --assert-timeout) ASSERT_TIMEOUT="$2"; shift 2 ;;
        --list)         LIST_ONLY=true; shift ;;
        --build-image)  FORCE_BUILD=true; shift ;;
        --keep)         KEEP=true; shift ;;
        --keep-alive)   KEEP_ALIVE=true; shift ;;
        # The new options check their operands before indexing: under `set -u` a
        # missing "$2"/"$3" aborts with "unbound variable", which names the
        # shell's problem rather than the operator's.
        --extra-user)   [ $# -ge 2 ] || { echo "--extra-user needs a login name" >&2; usage 1; }
                        EXTRA_USERS+=("$2"); shift 2 ;;
        --mesh-net)     [ $# -ge 2 ] || { echo "--mesh-net needs a SPEC (ADDR:PORT, mcast=/listen=/connect=, or 'auto')" >&2; usage 1; }
                        MESH_NET="$2"; shift 2 ;;
        --identities)   [ $# -ge 2 ] || { echo "--identities needs a path to the planner's identity file" >&2; usage 1; }
                        IDENTITIES="$2"; shift 2 ;;
        --devices)          DEV_ACTION="devices"; shift ;;
        --stop-device)      [ $# -ge 2 ] || { echo "--stop-device needs a device label" >&2; usage 1; }
                            DEV_ACTION="stop"; DEV_LABEL="$2"; shift 2 ;;
        --stop-all-devices) DEV_ACTION="stop-all"; shift ;;
        --qmp)          [ $# -ge 3 ] || { echo "--qmp needs LABEL and a command" >&2; usage 1; }
                        DEV_ACTION="qmp"; DEV_LABEL="$2"; DEV_QMP_CMD="$3"; shift 3 ;;
        --save-device)  [ $# -ge 2 ] || { echo "--save-device needs a device label" >&2; usage 1; }
                        DEV_ACTION="save"; DEV_LABEL="$2"; shift 2 ;;
        --list-saves)   [ $# -ge 2 ] || { echo "--list-saves needs a device label" >&2; usage 1; }
                        DEV_ACTION="list-saves"; DEV_LABEL="$2"; shift 2 ;;
        --save-to)      [ $# -ge 2 ] || { echo "--save-to needs a path" >&2; usage 1; }
                        DEV_SAVE_TO="$2"; shift 2 ;;
        --save-timeout) [ $# -ge 2 ] || { echo "--save-timeout needs a number of seconds" >&2; usage 1; }
                        DEV_SAVE_TIMEOUT="$2"; shift 2 ;;
        --overwrite)    DEV_SAVE_OVERWRITE=true; shift ;;
        -h|--help)      usage 0 ;;
        *)              echo "Unknown arg: $1" >&2; usage 1 ;;
    esac
done

# Fail here rather than once per container. The entrypoint validates these too,
# but only after the artifacts are mounted and one ERROR row per container has
# been written; and a value containing whitespace would word-split on the way
# into the argv below and come back as "Unknown arg" instead of the real cause.
[ -z "${ASSERT_TIMEOUT}" ] || [[ "${ASSERT_TIMEOUT}" =~ ^[0-9]+$ ]] \
    || die "--assert-timeout must be a whole number of seconds, got '${ASSERT_TIMEOUT}'"

# Same class of check, and the same reason: this one reaches the perl client's
# `alarm`, where a non-numeric value would be read as 0 — i.e. no alarm at all,
# so a wedged block job would hang the Studio's save button forever instead of
# failing.
[[ "${DEV_SAVE_TIMEOUT}" =~ ^[0-9]+$ ]] && [ "${DEV_SAVE_TIMEOUT}" -gt 0 ] \
    || die "--save-timeout must be a positive whole number of seconds, got '${DEV_SAVE_TIMEOUT}'"

# Both reach bash arithmetic: a typo would be a fatal "unbound variable"-class
# error at the point of use rather than a named refusal here.
[[ "${CACHE_MAX_GB}" =~ ^[0-9]+$ ]] \
    || die "--cache-max-gb must be a whole number of GiB (0 = unbounded), got '${CACHE_MAX_GB}'"
[[ "${JOBS}" =~ ^[0-9]+$ ]] \
    || die "--jobs must be a whole number (0 = ungated in --keep-alive mode), got '${JOBS}'"

# Same reasoning one step further: an --extra-user value is not just an argv item
# here, it becomes a LOGIN NAME created on the guest. Reject anything useradd
# would refuse (or that would word-split on the way into the container argv) at
# the entry point, where the operator can still see which value was wrong.
for _u in "${EXTRA_USERS[@]}"; do
    [[ "${_u}" =~ ^[a-z_][a-z0-9_-]*$ ]] \
        || die "--extra-user must be a valid unix login (^[a-z_][a-z0-9_-]*$), got '${_u}'"
done
unset _u

# ── The mesh lane's own preconditions, all fail-closed ──────────────────────
# Checked here, before docker is touched, so a mistyped mesh flag costs an error
# message rather than a half-attached fleet: the failure mode of getting this
# wrong is a device on a wire with no address (or worse, two devices sharing
# one), and neither announces itself — the guest simply cannot be reached by its
# peers while looking perfectly healthy over its loopback ssh.
if [ -n "${MESH_NET}" ]; then
    ${KEEP_ALIVE} || die "--mesh-net is a --keep-alive lane: the test lane powers every guest off after its assertions, so there is no standing fleet to put on a shared L2"
    [ -n "${IDENTITIES}" ] || die \
        "--mesh-net needs --identities FILE: the MACs and IPs come from the planner, never from here. Mint one with: PYTHONPATH=studio python3 -m hugmesh_studio.core.mesh_emulation identities --out FILE"
    # Same grammar as launch-*.sh --mesh-net, checked here as well because this
    # SPEC reaches THREE launchers and a rejection deep inside one container is
    # a line in `docker logs`, not on the operator's terminal.
    case "${MESH_NET}" in
        auto) ;;
        mcast=*:*|listen=*:*|connect=*:*) ;;
        *=*) die "--mesh-net mode must be mcast=/listen=/connect= (got: ${MESH_NET})" ;;
        *:*) ;;
        *)   die "--mesh-net wants ADDR:PORT (mcast), mcast=A:P/listen=H:P/connect=H:P, or 'auto' (got: ${MESH_NET})" ;;
    esac
elif [ -n "${IDENTITIES}" ]; then
    die "--identities does nothing without --mesh-net (it is that lane's identity source)"
fi

# ── The planner's identity file, read ONCE into per-label lookups ────────────
# label -> mac / ip / prefix, plus the file's own L2 SPEC. Associative arrays
# because rows are addressed by label everywhere else in this script, and a
# device whose label is missing from the file is a device this lane refuses to
# start rather than one it starts unaddressed.
declare -A MESH_MAC_FOR=() MESH_IP_FOR=() MESH_PLEN_FOR=()
MESH_FILE_NET=""

# The parse and the per-row sanity check live in tests/qemu/mesh-identities.sh,
# sourced by BOTH lanes that read this file — the 3-node driver and this fleet
# runner. Two readers of one identity file is one file with two meanings.
# Spelled as an `if`, not `[ -f ] && . || die`: that list would also fire the die
# when the sourced file's LAST command returned non-zero, i.e. blame a missing
# file for something else entirely.
if [ -f "${SCRIPT_DIR}/mesh-identities.sh" ]; then
    # shellcheck source=tests/qemu/mesh-identities.sh
    . "${SCRIPT_DIR}/mesh-identities.sh"
else
    die "missing ${SCRIPT_DIR}/mesh-identities.sh (the identity-file reader)"
fi

load_mesh_identities() { # <file>
    local f="$1" label mac ip plen net rows=0 why lines
    # Read the WHOLE file before believing any of it: the reader fails as a unit
    # (a row it cannot vouch for is not emitted), and consuming its output
    # through a pipe would both hide that exit status and fill these arrays in a
    # subshell, where they would vanish at the next line.
    lines="$(mesh_identity_lines "${f}")" \
        || die "--identities ${f} is not usable (see the reason above)"
    [ -n "${lines}" ] || die "--identities ${f}: no usable rows"
    while IFS='|' read -r label mac ip plen net; do
        [ -n "${label}${mac}" ] || continue
        why="$(mesh_identity_check_row "${label}" "${mac}" "${ip}" "${plen}")" \
            || die "identities ${f}: ${why}"
        [ -z "${MESH_MAC_FOR[${label}]:-}" ] \
            || die "identities ${f}: two rows both claim to be '${label}'"
        MESH_MAC_FOR["${label}"]="${mac}"
        MESH_IP_FOR["${label}"]="${ip}"
        MESH_PLEN_FOR["${label}"]="${plen}"
        [ -n "${MESH_FILE_NET}" ] || MESH_FILE_NET="${net}"
        [ "${net}" = "${MESH_FILE_NET}" ] \
            || die "identities ${f} (${label}): mesh_net '${net}' differs from '${MESH_FILE_NET}' — these rows are not on one L2"
        rows=$((rows + 1))
    done <<< "${lines}"
    [ "${rows}" -gt 0 ] || die "identities ${f}: no usable rows"
    if [ "${MESH_NET}" = "auto" ]; then
        [ -n "${MESH_FILE_NET}" ] || die \
            "--mesh-net auto, but ${f} names no mesh_net to take the L2 SPEC from"
        MESH_NET="${MESH_FILE_NET}"
    fi
    info "mesh identities: ${rows} row(s) from ${f}; shared L2 ${MESH_NET}"
}
[ -z "${MESH_NET}" ] || load_mesh_identities "${IDENTITIES}"

# ══ Device control plane (registry, ssh publishing, QMP) ════════════════════
# Everything down to the dispatch below works on ${WORK}/devices/<label>.json,
# the per-device record docker-entrypoint.sh writes in --keep-alive mode. The
# Studio reads those records directly (studio/hugmesh_studio/core/qemu_devices.py);
# the subcommands here are the same control plane for the command line, and for
# the Studio's stop/QMP buttons, which shell out to this script.

safe_label() { printf '%s\n' "$1" | tr '/+' '__'; }   # same rule as RESULT_JSON

# The two directories the control plane owns, derived from whichever ${WORK} the
# caller ended up with. A2 fixes the registry as ${WORK}/devices/<safe>.json and
# NOTHING else: consumers iterate that directory and open every entry, so a lock
# dir in there is an IsADirectoryError for a reader that does not filter on
# ".json". The port locks therefore live beside it, not inside it.
set_device_paths() {
    DEVICES_DIR="${WORK}/devices"
    PORTLOCK_DIR="${WORK}/.portlocks"
    # Saves live under ${WORK} for two independent reasons, both measured:
    # ${WORK} is the one host directory the device container has WRITE access to
    # (it is the /work bind mount; /src and /artifacts are :ro), and on this
    # machine it sits on /home — 667G free — while / is 84% full and has hit
    # 100% before.
    #
    # AND A SAVE IS BIG. `blockdev-backup sync=full` copies everything the source
    # reads as ALLOCATED, and every golden under ${WORK}/images is allocated in
    # FULL: docker-entrypoint.sh decompresses with `xz -dc … > "${RAW}.part"`, and
    # a plain redirect writes zeros rather than punching holes. Measured on this
    # host: all 7 goldens are 100% allocated, 9.5G (rpi5) to 20.5G (x86 omnibus).
    # So one save of x86/omnibus is ~20.5G and the default is a NEW file each time.
    # A sparse synthetic image suggests otherwise and is misleading — do not repeat
    # the "a save only costs what the guest used" claim from it.
    SAVES_DIR="${WORK}/saves"
}

# A JSON string literal. Used for values that go into a QMP arguments object —
# in practice a save target's filename, which is operator input via --save-to.
# Same escape ORDER as docker-entrypoint.sh json_str (backslash first, then
# quote), and for the same reason: doing it the other way round double-escapes
# the backslashes it just inserted.
json_str() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "${s}"
}

need_docker() {
    command -v docker >/dev/null || die "docker not found"
    docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon (is your user in the 'docker' group?)"
}

# python3 does the JSON work for the subcommands below, on the HOST. It is not a
# new dependency in practice — the Studio that consumes this registry IS a python
# app — and it reads and REWRITES records (state -> stopped) atomically, which is
# more than the jq the summary already uses would do for us. The QMP client is a
# separate question and a separate interpreter: it runs inside the container,
# where there is no python3 at all (see QMP_PERL).
need_python() {
    command -v python3 >/dev/null || die "python3 not found (needed for the device subcommands)"
}

device_record_path() {
    local label="$1" p
    p="${DEVICES_DIR}/$(safe_label "${label}").json"
    [ -f "${p}" ] && { printf '%s\n' "${p}"; return 0; }
    # Accept the on-disk spelling too, for anyone who read the name off the
    # directory listing ("rpi5_pki") instead of the label ("rpi5/pki").
    p="${DEVICES_DIR}/${label}.json"
    [ -f "${p}" ] && { printf '%s\n' "${p}"; return 0; }
    return 1
}

# record_field FILE KEY -> value on stdout, empty if the record is unreadable.
record_field() {
    need_python
    python3 - "$1" "$2" <<'PYFIELD'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        rec = json.load(fh)
except (OSError, ValueError):
    sys.exit(0)
if not isinstance(rec, dict):
    sys.exit(0)
val = rec.get(sys.argv[2], "")
sys.stdout.write("" if val is None else str(val))
PYFIELD
}

registry_containers() {
    [ -d "${DEVICES_DIR}" ] || return 0
    need_python
    python3 - "${DEVICES_DIR}" <<'PYNAMES'
import json, os, sys
for name in sorted(os.listdir(sys.argv[1])):
    if not name.endswith(".json"):
        continue
    try:
        with open(os.path.join(sys.argv[1], name), "r", encoding="utf-8") as fh:
            rec = json.load(fh)
    except (OSError, ValueError):
        continue
    if isinstance(rec, dict) and rec.get("container"):
        print(rec["container"])
PYNAMES
}

# Flip one record to state "stopped". Best effort on purpose: the record is
# written from INSIDE the container, so its ownership on the host is the
# entrypoint's business, not this script's; the replacement goes through a rename
# in the registry DIRECTORY (created host-side by the keep-alive path below),
# which is the part this script can rely on. Correctness does not depend on it
# working — cmd_devices reconciles against `docker ps` on the way out regardless
# — it just keeps the file honest for readers that do not, such as
# core/qemu_devices.py discover_devices().
mark_record_stopped() {
    [ -f "$1" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    python3 - "$1" <<'PYSTOP'
import json, os, sys
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        rec = json.load(fh)
except (OSError, ValueError):
    sys.exit(0)
if not isinstance(rec, dict) or rec.get("state") == "stopped":
    sys.exit(0)
rec["state"] = "stopped"
tmp = "%s.tmp.%d" % (path, os.getpid())   # pid-tagged: two stops can overlap
try:
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(rec, fh, indent=2)
        fh.write("\n")
    # Atomic: --devices in another process may be reading this very file, and a
    # truncated record there would be indistinguishable from a corrupt one.
    os.replace(tmp, path)
except OSError:
    try:
        os.unlink(tmp)
    except OSError:
        pass
PYSTOP
}

cmd_devices() {
    need_python
    local answered=0 names=""
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        names="$(docker ps --format '{{.Names}}' 2>/dev/null)"; answered=1
    fi
    DOCKER_ANSWERED="${answered}" RUNNING_NAMES="${names}" \
    python3 - "${DEVICES_DIR}" <<'PYDEV'
import json, os, sys

devices_dir = sys.argv[1]
answered = os.environ.get("DOCKER_ANSWERED") == "1"
running = {n for n in os.environ.get("RUNNING_NAMES", "").splitlines() if n}

out = []
try:
    entries = sorted(os.listdir(devices_dir))
except OSError:
    entries = []                       # no devices dir yet: an empty array, not an error
for name in entries:
    if not name.endswith(".json"):
        continue
    try:
        with open(os.path.join(devices_dir, name), "r", encoding="utf-8") as fh:
            rec = json.load(fh)
    except (OSError, ValueError):
        continue                       # torn or hand-mangled record: skip it, never abort
    if not isinstance(rec, dict):
        continue
    # Reconcile against reality, downgrade only. A container that was killed
    # (docker kill, OOM, daemon restart) never gets to rewrite its own record, so
    # a stale "running" would have the Studio offer a shell into a device that is
    # gone. Only trust this when the daemon actually answered.
    if answered and rec.get("state") not in ("stopped", "") \
            and rec.get("container") not in running:
        rec["state"] = "stopped"
    out.append(rec)
out.sort(key=lambda r: str(r.get("started_at") or ""), reverse=True)   # newest first
json.dump(out, sys.stdout, indent=2)
sys.stdout.write("\n")
PYDEV
}

# ONE ownership test, applied to EVERY docker verb this script aims at a
# container name that came out of a data file.
#
# The operator's live hugmesh stack runs on this same machine: a hand-edited,
# truncated or stale record naming one of ITS containers must not be able to turn
# --stop-all-devices into an outage — nor `--qmp` into a root `docker exec` on a
# production container. Every container we start is named ${DEV_NAME_PREFIX}<row>,
# so the prefix is a complete and cheap test, and it is cheap enough that there
# is no excuse for applying it to only one of the two call sites.
own_container() {
    local name="$1" verb="$2" label="${3:-}"
    case "${name}" in
        "${DEV_NAME_PREFIX}"*) return 0 ;;
    esac
    warn "refusing to ${verb} '${name}'${label:+ (${label})}: not a ${DEV_NAME_PREFIX}* container started by this harness"
    return 1
}

# Is this container up right now? One question, one place — asked by the device
# start path, by --qmp before it execs, and again after a destructive reset.
container_is_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]
}

# Stop exactly one container, refusing anything this harness did not start.
stop_one_container() {
    local name="$1" label="${2:-}"
    own_container "${name}" "stop" "${label}" || return 1
    docker stop "${name}" >/dev/null 2>&1 || return 1
    return 0
}

# ── The mesh L2: ONE docker bridge network per session ──────────────────────
# Why a docker network at all, when the guests talk over QEMU's own socket
# netdev? Because that netdev is UDP multicast between the CONTAINERS: each
# qemu joins the group from inside its container, and two containers only share
# a broadcast domain if they share a bridge. On the default bridge they would
# also see every unrelated container on this workstation — including the
# operator's live stack — so the fleet gets its own.
#
# One per SESSION, named from a hash of the session so two sessions emulated at
# once are two separate wires (their identity plans use different subnets and L2
# SPECs; sharing a bridge would still put both sets of ARP on one segment).
MESH_NET_LABEL="hugmesh-qemu-mesh=1"

mesh_network_name() { # <session name> -> the bridge name for that session
    local s="$1" h=""
    if command -v sha256sum >/dev/null 2>&1; then
        h="$(printf '%s' "${s}" | sha256sum 2>/dev/null | cut -c1-8)"
    fi
    if [ -z "${h}" ] && command -v python3 >/dev/null 2>&1; then
        h="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest()[:8])' "${s}" 2>/dev/null)"
    fi
    [ -n "${h}" ] || return 1
    printf '%s%s\n' "${MESH_NAME_PREFIX}" "${h}"
}

# The same ownership test own_container applies to containers, applied to
# networks — and for a sharper reason: removing the wrong docker network
# disconnects whatever is on it, and the operator's live hugmesh stack has
# networks of its own on this machine.
own_network() {
    local name="$1" verb="$2"
    case "${name}" in
        "${MESH_NAME_PREFIX}"*) return 0 ;;
    esac
    warn "refusing to ${verb} network '${name}': not a ${MESH_NAME_PREFIX}* network created by this harness"
    return 1
}

# Idempotent by construction: inspect, create, and if the create lost a race with
# a concurrent run, inspect again. Never `rm` first — the network may already
# have this fleet's other devices attached.
mesh_network_ensure() { # <name>
    local name="$1"
    docker network inspect "${name}" >/dev/null 2>&1 && return 0
    own_network "${name}" "create" || return 1
    docker network create --driver bridge --label "${MESH_NET_LABEL}" \
        "${name}" >/dev/null 2>&1 && return 0
    docker network inspect "${name}" >/dev/null 2>&1
}

# How many containers are attached RIGHT NOW. docker releases a container's
# endpoint when it stops, so this is 0 for a fleet that has been stopped even
# though the containers themselves are kept around for their logs.
mesh_network_members() { # <name> -> count, empty when the network is unknown
    docker network inspect -f '{{len .Containers}}' "$1" 2>/dev/null
}

# Remove every mesh bridge whose last member is gone. Called from
# --stop-all-devices ("leave nothing of the fleet behind") — a bridge with
# members is LEFT ALONE, so stopping one session's fleet never cuts another's.
sweep_mesh_networks() {
    local name n
    command -v docker >/dev/null 2>&1 || return 0
    docker info >/dev/null 2>&1 || return 0        # daemon silent: never guess
    while IFS= read -r name; do
        [ -n "${name}" ] || continue
        own_network "${name}" "remove" || continue
        n="$(mesh_network_members "${name}")"
        [[ "${n}" =~ ^[0-9]+$ ]] || continue
        [ "${n}" -eq 0 ] || continue
        docker network rm "${name}" >/dev/null 2>&1 \
            && info "removed the mesh network ${name} (its last device is gone)"
    done < <(docker network ls --filter "label=${MESH_NET_LABEL}" \
                 --format '{{.Name}}' 2>/dev/null)
    return 0
}

# ── Host-port allocation ────────────────────────────────────────────────────
# A device's host ssh port is allocated HERE, and it has to be exclusive in two
# directions at once:
#
#   * WITHIN one run. Rows are started one after another in this same process,
#     and nothing observable changes between them fast enough to be a reliable
#     signal — `docker run -d` returns before the guest exists, and a published
#     port does not necessarily appear in `ss` at all (with the daemon started
#     --userland-proxy=false, publishing is DNAT with no listening socket on the
#     host). So this process remembers what it has handed out: DEV_PORTS_TAKEN.
#   * ACROSS concurrent runs and across invocations. A second run of this script
#     (or the Studio's per-device start button) must not pick a port that a
#     device from another run is already using. That is what the claim
#     directories under ${WORK}/.portlocks are for, plus docker's own published-
#     port table, which is authoritative for every container the daemon runs.
#
# Docker refusing a duplicate bind is the LAST line, not the mechanism: it costs
# a container create+remove per collision, and there are 33 rows in the matrix.
DEV_PORTS_TAKEN=()

# Every host port docker has published, straight from the daemon that owns them.
# `{{.Ports}}` is e.g. "127.0.0.1:22300->2222/tcp, 0.0.0.0:8080->80/tcp"; the
# last colon before "->" starts the host port. This covers the operator's live
# stack as well as our own devices, and it works with or without the userland
# proxy because it asks docker rather than the kernel.
docker_published_ports() {
    docker ps --format '{{.Ports}}' 2>/dev/null | tr ',' '\n' \
        | sed -n 's/.*:\([0-9][0-9]*\)->.*/\1/p'
}

# A claim is a DIRECTORY: mkdir(2) either creates it or fails, with no window
# between test and create, so two runs starting in the same second cannot both
# believe they own a port. The claim then names its container, and is held for as
# long as that container runs — not just for the instant of choosing — because
# the port stays bound for exactly that long.
claim_port() {
    local p="$1" owner="$2"
    local dir="${PORTLOCK_DIR}/${p}"
    mkdir -p "${PORTLOCK_DIR}" 2>/dev/null || return 1
    if mkdir "${dir}" 2>/dev/null; then
        printf '%s\n' "${owner}" > "${dir}/owner" 2>/dev/null || true
        return 0
    fi
    port_claim_is_stale "${p}" || return 1
    # Stale: the container that held it is gone. Two racers can both reclaim
    # here; that costs one rejected `docker run` and a retry, never a wrong bind,
    # because a stale claim by definition guards a port nothing is bound to.
    rm -f "${dir}/owner" 2>/dev/null || true
    rmdir "${dir}" 2>/dev/null || true
    mkdir "${dir}" 2>/dev/null || return 1
    printf '%s\n' "${owner}" > "${dir}/owner" 2>/dev/null || true
    return 0
}

# Held claims must not outlive their container, or a crashed run burns a port
# until someone deletes ${WORK}. The holder is named in the claim's "owner" file,
# and that name is checked against the daemon.
port_claim_is_stale() {
    local dir="${PORTLOCK_DIR}/$1" owner
    owner="$(cat "${dir}/owner" 2>/dev/null || true)"
    if [ -n "${owner}" ]; then
        # Only the daemon can answer this, so when it does not answer at all the
        # conservative reading is "still held" — never steal a claim blind.
        docker info >/dev/null 2>&1 || return 1
        docker ps --format '{{.Names}}' 2>/dev/null | grep -xF "${owner}" >/dev/null && return 1
        return 0
    fi
    # No owner recorded: a claim caught between mkdir and `docker run`. Age it
    # out so a run killed inside that window cannot hold the port forever.
    [ -n "$(find "${dir}" -maxdepth 0 -mmin +5 2>/dev/null)" ]
}

# Drop a claim, but only one this device actually owns: a stale record naming
# someone else's port must not be able to hand a LIVE port to the next run.
release_port() {
    local p="$1" owner="${2:-}" held
    local dir="${PORTLOCK_DIR}/${p}"
    [ -d "${dir}" ] || return 0
    held="$(cat "${dir}/owner" 2>/dev/null || true)"
    if [ -n "${owner}" ] && [ -n "${held}" ] && [ "${held}" != "${owner}" ]; then
        return 0
    fi
    rm -f "${dir}/owner" 2>/dev/null || true
    rmdir "${dir}" 2>/dev/null || true
    return 0
}

# The claim belonging to a device record, released when that device is stopped.
release_port_for_record() {
    local rec="$1" port
    port="$(record_field "${rec}" ssh_host_port)"
    [[ "${port}" =~ ^[0-9]+$ ]] || return 0
    [ "${port}" -gt 0 ] || return 0            # 0 = the device published nothing
    release_port "${port}" "$(record_field "${rec}" container)"
}

# Drop every port claim whose owner container no longer exists. claim_port
# already reclaims a stale claim lazily when that exact port is re-picked, but
# a claim for a port nothing happens to pick again is held forever: a row
# killed BEFORE its record landed (docker stop during boot) had nothing for
# reconcile_stopped_records to release, which is how claims 22303/22309 leaked
# on 2026-08-19 — their rows (x86/be, x86/pki) died at exit 143 pre-
# registration. --stop-all-devices means "leave nothing of the fleet behind",
# so it sweeps these too. port_claim_is_stale carries the safety: an owner the
# daemon still lists is NEVER swept, and when docker does not answer, nothing
# is.
sweep_stale_portlocks() {
    local dir p swept=0
    [ -d "${PORTLOCK_DIR}" ] || return 0
    for dir in "${PORTLOCK_DIR}"/*/; do
        [ -d "${dir}" ] || continue
        p="$(basename "${dir}")"
        port_claim_is_stale "${p}" || continue
        rm -f "${dir}owner" 2>/dev/null || true
        rmdir "${dir}" 2>/dev/null || true
        info "released stale port claim ${p} (its owner container is gone)"
        swept=$((swept+1))
    done
    return 0
}

# Mark every record whose container is no longer running. Used after a stop, so
# the registry agrees with docker even for readers that never ask docker.
reconcile_stopped_records() {
    local running rec cname
    running="$(docker ps --format '{{.Names}}' 2>/dev/null)"
    for rec in "${DEVICES_DIR}"/*.json; do
        [ -f "${rec}" ] || continue
        cname="$(record_field "${rec}" container)"
        [ -n "${cname}" ] || continue
        grep -qxF "${cname}" <<< "${running}" && continue
        mark_record_stopped "${rec}"
        release_port_for_record "${rec}"
    done
}

cmd_stop_device() {
    local label="$1" rec name
    need_docker
    rec="$(device_record_path "${label}")" \
        || die "no device record for '${label}' under ${DEVICES_DIR} (--devices to list what is there)"
    name="$(record_field "${rec}" container)"
    [ -n "${name}" ] || die "device record ${rec} names no container"
    # `docker stop`, not `docker rm`: the exited container's `docker logs` is the
    # only post-mortem a keep-alive device has (its console never reached a
    # terminal, it was started detached). The next --keep-alive run of the same
    # row clears it out of the way.
    stop_one_container "${name}" "${label}" \
        || die "could not stop container ${name} for ${label} (already gone? --devices to check)"
    mark_record_stopped "${rec}"
    release_port_for_record "${rec}"
    info "stopped ${label} (container ${name})"
}

cmd_stop_all() {
    need_docker
    local names name stopped=0
    # Union of the registry and a name-prefix scan. A device whose record never
    # landed still has a container burning host CPU — the entrypoint only writes
    # the record once the guest answers ssh, and TCG guests take minutes to get
    # there — and "stop every device" has to mean every device.
    names="$( { docker ps --format '{{.Names}}' --filter "name=^${DEV_NAME_PREFIX}" 2>/dev/null
                registry_containers; } | sort -u )"
    if [ -z "${names}" ]; then
        info "no device containers to stop"
        # Nothing running is EXACTLY when leaked claims are all that is left —
        # tonight's 22303/22309 outlived rows that never even registered.
        sweep_stale_portlocks
        # ...and the same is true of an empty mesh bridge: the fleet it was
        # created for is gone, so the wire goes with it.
        sweep_mesh_networks
        return 0
    fi
    while IFS= read -r name; do
        [ -n "${name}" ] || continue
        stop_one_container "${name}" || continue
        info "stopped container ${name}"
        stopped=$((stopped+1))
    done <<< "${names}"
    reconcile_stopped_records
    # Claims from rows killed before their record ever landed have no record to
    # release through; sweep them by asking docker directly.
    sweep_stale_portlocks
    # The mesh bridges last exactly as long as the fleet on them. Stopping the
    # containers releases their endpoints, so any bridge that is now empty is
    # this run's leftover; one that still has members belongs to a fleet this
    # sweep did not stop and is left standing.
    sweep_mesh_networks
    info "${stopped} device container(s) stopped"
}

# ── QMP ─────────────────────────────────────────────────────────────────────
# The names the operator types are not the names QEMU answers to.
qmp_command_for() {
    case "$1" in
        pause)     printf 'stop\n' ;;
        resume)    printf 'cont\n' ;;
        reset)     printf 'system_reset\n' ;;
        powerdown) printf 'system_powerdown\n' ;;
        status)    printf 'query-status\n' ;;
        *)         return 1 ;;
    esac
}

# The registry records HOST paths so the Studio can use them directly (the
# entrypoint resolves them through HOST_WORK before writing), but a record
# written without HOST_WORK carries the CONTAINER path instead. Either way the
# bytes are the same file — /work IS ${WORK} — so mapping a host path back is
# just a prefix swap, and a path that is already container-side passes through.
container_path_for() {
    case "$1" in
        "${WORK}"/*) printf '%s\n' "/work/${1#${WORK}/}" ;;
        *)           printf '%s\n' "$1" ;;
    esac
}

# The QMP client, in perl, executed INSIDE the device container by `docker exec`.
#
# WHY NOT FROM THE HOST. qemu creates its QMP socket mode 0750 (checked here
# against qemu-system-x86_64 10.2.3: srwxr-x---) owned by the user it runs as —
# and in this harness that user is root inside the container. connect(2) on a
# unix socket needs write permission, so the operator's uid is locked out of a
# path it can otherwise see perfectly well through the /work bind mount.
# `docker exec` runs as root in that container, which is the whole reason
# core/qemu_devices.py's qmp_argv() shells out to this script instead of opening
# the socket itself: this is the one place in the system that can talk to it.
#
# WHY PERL. docker/Dockerfile.qemu-runner installs no python3, no socat and no
# netcat, and bash cannot open an AF_UNIX socket at all — but perl is Essential
# in Debian, so the bookworm-slim base the image is built FROM already has it,
# Socket module included. Checked by running this exact program inside
# debian:bookworm-slim against a live qemu QMP socket: query-status answered
# {"return": {"status": "prelaunch", "running": false}} and a bogus verb answered
# {"error": {"class": "CommandNotFound", ...}} with exit 1.
#
# The program is passed as ONE argv element to `docker exec ... perl -e`, with
# the socket path and the QMP steps as its own arguments — no `sh -c`, so nothing
# from a record or a label is ever parsed as shell. ${cmd} is interpolated into
# the JSON, and that is safe for one specific reason: it is never operator text,
# only one of the five literals qmp_command_for() emits or one of the fixed
# block-layer verbs cmd_save_device() spells out.
#
# TWO THINGS A SAVE NEEDS THAT A PAUSE DOES NOT, and why the client grew rather
# than being duplicated:
#   * ARGUMENTS. blockdev-add has to be told the target's filename and driver;
#     `{"execute":"blockdev-add"}` on its own is a parameter error.
#   * EVENT WAITING. blockdev-backup answers {"return": {}} the instant the job
#     is QUEUED and copies afterwards, so a client that stops at the reply
#     reports a completed save that has copied nothing. The outcome arrives
#     later, asynchronously, as BLOCK_JOB_COMPLETED.
# A step is therefore three argv elements — CMD, ARGUMENTS-JSON (or "-"), EVENTS
# (or "-") — and several steps run down ONE connection. That last part is not a
# convenience: QEMU delivers an event to the monitors connected AT THE TIME, so
# issuing blockdev-backup, disconnecting and reconnecting to listen would miss
# BLOCK_JOB_COMPLETED entirely and then sit until the alarm.
#
# The five-verb path is the same program called with one argument-less,
# event-less step, so pause/resume/reset/powerdown/status keep byte-identical
# output and exit codes and there is no second copy of the protocol to drift.
QMP_PERL="$(cat <<'PERLQMP'
use strict; use warnings; use Socket;
# argv: SOCKET TIMEOUT_SECONDS then N x (CMD ARGUMENTS_JSON|- EVENT[,EVENT]|-)
my $path = shift @ARGV;
my $tmo  = shift @ARGV;
$SIG{ALRM} = sub { print STDERR "qmp: timed out talking to $path\n"; exit 4 };
# ONE alarm over the whole conversation, event waits included: a block job that
# never completes must not be able to pin the caller forever.
alarm $tmo;
socket(my $S, AF_UNIX, SOCK_STREAM, 0) or do { print STDERR "qmp: socket(): $!\n"; exit 4 };
connect($S, sockaddr_un($path)) or do { print STDERR "qmp: cannot connect to $path: $!\n"; exit 3 };
select((select($S), $| = 1)[0]);
# QMP is one JSON message per line, and it interleaves asynchronous EVENTS with
# command replies, so read past anything that is not an answer: an event object
# carries "event"/"data" and neither of the keys matched here.
sub reply { while (my $l = <$S>) { return $l if $l =~ /"(?:return|error)"\s*:/ } return undef }
# The mirror image: read past replies and unrelated events until one of the
# named events shows up. JOB_STATUS_CHANGE fires several times per block job and
# is exactly what has to be stepped over here.
sub await_event {
    my ($alt) = @_;
    while (my $l = <$S>) { return $l if $l =~ /"event"\s*:\s*"(?:$alt)"/ }
    return undef;
}
print $S "{\"execute\":\"qmp_capabilities\"}\n";
defined reply() or do { print STDERR "qmp: no reply to qmp_capabilities\n"; exit 4 };
while (@ARGV >= 3) {
    my ($cmd, $args, $ev) = splice(@ARGV, 0, 3);
    print $S ($args eq '-' ? "{\"execute\":\"$cmd\"}\n"
                           : "{\"execute\":\"$cmd\",\"arguments\":$args}\n");
    my $r = reply();
    defined $r or do { print STDERR "qmp: no reply to $cmd\n"; exit 4 };
    print $r;
    # Stop at the first error rather than firing the rest of the sequence at a
    # monitor that has already refused a step: with blockdev-add failed there is
    # no target node for blockdev-backup to write into.
    exit 1 if $r =~ /"error"\s*:/;
    next if $ev eq '-';
    my $e = await_event(join('|', map { quotemeta } split(/,/, $ev)));
    defined $e or do { print STDERR "qmp: no $ev event after $cmd\n"; exit 4 };
    print $e;
}
exit 0;
PERLQMP
)"

# One QMP conversation of one or more steps. Exit status is the perl client's:
# 0 = QMP returned, 1 = QMP error, 3 = could not connect, 4 = protocol/timeout.
# docker reports its OWN failures in the 125-127 range (126/127 = it could not
# exec the command), which cmd_qmp translates below rather than passing off as a
# QMP error.
# qmp_exec NAME CONTAINER_SOCKET TIMEOUT  CMD ARGS EVENTS  [CMD ARGS EVENTS ...]
qmp_exec() {
    local name="$1" csock="$2" tmo="$3"
    shift 3
    docker exec -u 0 "${name}" perl -e "${QMP_PERL}" "${csock}" "${tmo}" "$@"
}

cmd_qmp() {
    local label="$1" action="$2" qcmd rec sock csock name rc waited
    qcmd="$(qmp_command_for "${action}")" \
        || die "unknown --qmp command '${action}' (pause|resume|reset|powerdown|status)"
    rec="$(device_record_path "${label}")" \
        || die "no device record for '${label}' under ${DEVICES_DIR} (--devices to list what is there)"
    sock="$(record_field "${rec}" qmp)"
    [ -n "${sock}" ] || die "device '${label}' has no qmp socket recorded (started without --keep-alive?)"
    name="$(record_field "${rec}" container)"
    [ -n "${name}" ] || die "device record ${rec} names no container"
    need_docker
    # Same guard as stop_one_container, and for a sharper reason: this ends in a
    # root `docker exec`, and the name came out of a file on disk.
    own_container "${name}" "talk QMP to" "${label}" || return 1
    container_is_running "${name}" \
        || die "device '${label}' is not running (container ${name}); --devices to check, or start it again with --keep-alive --only '${label}'"
    # The record advertises HOST paths, because everything else that reads it
    # runs on the host. This is the one consumer that runs INSIDE the container.
    csock="$(container_path_for "${sock}")"

    if [ "${action}" = "reset" ]; then
        warn "reset is DESTRUCTIVE: ${label} boots with -no-reboot, so QEMU EXITS on system_reset instead of rebooting. The guest goes DOWN."
    fi
    # One step, no arguments, no event to wait for — the shape the five verbs
    # have always had, and ${QMP_TIMEOUT} is the 15s alarm they have always run
    # under.
    qmp_exec "${name}" "${csock}" "${QMP_TIMEOUT}" "${qcmd}" - -; rc=$?
    case "${rc}" in
        12[567]) warn "docker exec could not run perl in ${name} (rc=${rc}); the runner image is expected to provide it" ;;
    esac
    if [ "${action}" != "reset" ] || [ "${rc}" -ne 0 ]; then
        return "${rc}"
    fi

    # Report what the reset actually did rather than leaving a "running" record
    # behind a dead guest. docker-entrypoint.sh's keep-alive hold ends when its
    # qemu is gone, so the container normally follows within seconds; if it has
    # not gone after 15s, say exactly that instead of guessing.
    for (( waited=0; waited<15; waited++ )); do
        container_is_running "${name}" || break
        sleep 1
    done
    if container_is_running "${name}"; then
        warn "${label}: system_reset issued, but container ${name} is still up after 15s — check '--devices'"
    else
        mark_record_stopped "${rec}"
        release_port_for_record "${rec}"
        info "${label} is DOWN: qemu exited on system_reset. Start it again with --keep-alive --only '${label}'"
    fi
    return 0
}

# ── Pause and save ──────────────────────────────────────────────────────────
# See the PAUSE AND SAVE block in the header for WHY this is a QMP block job and
# not a qemu-img call, and for why block-commit is absent.

# qmp_parse MODE — reads a qmp_exec transcript on stdin (one JSON object per
# line) and answers one question about it. Parsing happens HOST-side in python3,
# which the device subcommands already require, because the alternative is
# grepping numbers out of single-line JSON: `qemu-img info --output=json` was
# checked here and its FIRST "virtual-size" is the file's 393216-byte physical
# size, not the 67108864-byte guest disk — precisely the kind of near-miss that
# would size a save target too small and truncate the copy.
#
# `python3 -c "${VAR}"`, NOT the `python3 - <<'EOF'` spelling the rest of this
# file uses, and the difference is not cosmetic: a heredoc IS the process's
# stdin, so a program fed that way cannot also read the piped transcript. Every
# other python helper here takes its input from argv or a file and never noticed.
QMP_PARSE_PY="$(cat <<'PYQMP'
import json, sys

mode, drive = sys.argv[1], sys.argv[2]

def objects():
    for line in sys.stdin.read().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            yield json.loads(line)
        except ValueError:
            continue                      # a warning or a torn line: never fatal

if mode == "status":
    # query-status' .return.status — "running", "paused", "prelaunch", ...
    for obj in objects():
        ret = obj.get("return")
        if isinstance(ret, dict) and "status" in ret:
            sys.stdout.write(str(ret["status"]))
            sys.exit(0)
    sys.exit(1)

if mode == "size":
    # The GUEST-visible size of the drive being saved. blockdev-backup refuses a
    # target smaller than the source, and a target LARGER would silently produce
    # an image whose geometry no longer matches the device.
    for obj in objects():
        ret = obj.get("return")
        if not isinstance(ret, list):
            continue
        for blk in ret:
            if not isinstance(blk, dict) or blk.get("device") != drive:
                continue
            size = ((blk.get("inserted") or {}).get("image") or {}).get("virtual-size")
            if isinstance(size, int) and size > 0:
                sys.stdout.write(str(size))
                sys.exit(0)
    sys.exit(1)

if mode == "job":
    # The three ways a finished block job can still mean "no usable save" (C9).
    for obj in objects():
        if obj.get("event") != "BLOCK_JOB_COMPLETED":
            continue
        data = obj.get("data") or {}
        if data.get("error"):
            sys.stderr.write("block job reported an error: %s\n" % data["error"])
            sys.exit(1)
        off, ln = data.get("offset"), data.get("len")
        if off != ln:
            sys.stderr.write("PARTIAL COPY: %s of %s bytes were copied\n" % (off, ln))
            sys.exit(1)
        sys.stdout.write(str(ln))
        sys.exit(0)
    sys.stderr.write("no BLOCK_JOB_COMPLETED event in the QMP transcript\n")
    sys.exit(1)

sys.exit(2)
PYQMP
)"

qmp_parse() {
    need_python
    python3 -c "${QMP_PARSE_PY}" "$1" "${SAVE_DRIVE}"
}

# Flush the guest before it is paused. QMP `stop` alone gives a CRASH-consistent
# image — a pulled plug — so anything still in the guest's page cache is lost.
# The device already has ssh (that is what the keep-alive registry is for), so
# ask it to sync first. Deliberately BEST EFFORT and never fatal: a device that
# failed its assertions, or one started without a published port, is exactly the
# device an operator most wants a copy of. When it cannot be done, say so
# instead of quietly downgrading what the save is worth.
save_flush_guest() {
    local rec="$1" label="$2" port user key
    port="$(record_field "${rec}" ssh_host_port)"
    user="$(record_field "${rec}" ssh_user)"
    key="$(record_field  "${rec}" ssh_key)"
    if ! [[ "${port}" =~ ^[0-9]+$ ]] || [ "${port}" -eq 0 ] \
       || [ -z "${user}" ] || [ ! -f "${key}" ]; then
        warn "${label}: no usable ssh in the device record — NOT flushing the guest; the copy is crash-consistent only"
        return 0
    fi
    command -v ssh >/dev/null 2>&1 || {
        warn "${label}: no ssh on this host — NOT flushing the guest; the copy is crash-consistent only"
        return 0
    }
    # Same options as the Studio's own device shell (studio/hugmesh_studio/core/
    # qemu_devices.py SSH_OPTIONS, :65) plus BatchMode, because this one runs
    # unattended and must never stop on a prompt. Plain `sync`, not `sudo sync`:
    # sync(2) flushes ALL filesystems and needs no privilege, so this stays clear
    # of sudo and of the pty that would come with it.
    if timeout -k 5 30 ssh -i "${key}" -p "${port}" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR \
            "${user}@127.0.0.1" 'sync' >/dev/null 2>&1; then
        info "${label}: guest filesystems flushed (sync) before the pause"
    else
        warn "${label}: the guest did not answer 'sync' — the copy is crash-consistent only"
    fi
    return 0
}

# The newest save that already exists for a device, or empty. This is what
# --overwrite means with no --save-to: "the existing copy in the session".
# newest_save_for SAFE LABEL — the file "--overwrite" replaces.
#
# It MUST agree with --list-saves, or the operator overwrites something they were
# never shown. It did not: this globbed names while cmd_list_saves filtered by the
# sidecar's label, so a save made with `--save-to another-name.qcow2` was listed for
# the device but invisible here — a repeat-overwrite workflow then accumulated files
# while destroying an older copy silently. The name glob also crossed devices: the
# pattern `<safe>-*` matches `x_y-z`'s saves when asked for `x_y`.
#
# So the sidecar is authoritative, exactly as it is for listing, and the name glob is
# only the fallback for saves written before sidecars existed.
newest_save_for() {
    local safe="$1" label="$2" f meta owner newest=""
    for f in $(ls -1t "${SAVES_DIR}"/*.qcow2 2>/dev/null); do
        meta="${f}.json"
        if [ -f "${meta}" ]; then
            owner="$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("label",""))
except Exception:
    print("")' "${meta}" 2>/dev/null)"
            [ "${owner}" = "${label}" ] || continue
        else
            # No sidecar: fall back to the name, but anchored so `x_y` cannot claim
            # `x_y-z`'s files — the stamp suffix is digits/T/Z, never another label.
            case "${f##*/}" in
                "${safe}.qcow2") ;;
                "${safe}"-[0-9]*) ;;
                *) continue ;;
            esac
        fi
        newest="${f}"; break
    done
    printf '%s\n' "${newest}"
}

# save_check_target PATH — die() unless PATH is a legal place to put a save.
#
# The single most important rule in this whole feature: THE GOLDEN BUILD
# ARTIFACT IS NEVER A TARGET. It is shared by every run, every session and every
# other device, and overwriting it would be both irreversible and invisible
# until some later run booted garbage. The /artifacts mount is read-only, which
# stops the obvious spelling, but ${WORK}/images holds the DECOMPRESSED copies
# of those same artifacts on a writable mount — so that directory is named here
# explicitly rather than trusted to a mount flag.
save_check_target() {
    local target="$1" arts
    case "${target}" in
        *[[:cntrl:]]*) die "--save-to must not contain control characters" ;;
    esac
    [[ "${target}" == *.qcow2 ]] \
        || die "--save-to must name a .qcow2 file (the save is a qcow2, and the suffix keeps this from landing on a log, a record or an .img): '${target}'"
    # Under ${WORK} is not a preference: /work is the only writable mount the
    # device container has, and it is qemu INSIDE that container that creates
    # and writes the file. A path outside it cannot be written at all.
    case "${target}/" in
        "${WORK}"/*) : ;;
        *) die "--save-to must be under the work dir (${WORK}); the device container can only write there. Got: ${target}" ;;
    esac
    case "${target}/" in
        "${WORK}"/images/*)
            die "REFUSING to save onto ${target}: ${WORK}/images holds the decompressed GOLDEN images, which every run and every session boots from" ;;
        "${WORK}"/runs/*)
            die "REFUSING to save onto ${target}: ${WORK}/runs holds the LIVE run overlays — that is the disk being copied, and the device is still writing to it" ;;
        "${WORK}"/devices/*|"${WORK}"/results/*|"${WORK}"/.portlocks/*)
            die "REFUSING to save onto ${target}: that directory is harness bookkeeping, not storage" ;;
    esac
    # --artifacts/--session are not resolved on this path (the device
    # subcommands deliberately run before artifact resolution), so this only
    # fires when the operator named one explicitly on the same command line.
    # It costs nothing and covers an artifacts dir that lives under ${WORK}.
    if [ -n "${ARTIFACTS}" ]; then
        arts="$(readlink -m "${ARTIFACTS}")"
        case "${target}/" in
            "${arts}"/*) die "REFUSING to save into the artifacts dir ${arts}: that is where the golden build images live" ;;
        esac
    fi
}

# save_pick_target SAFE LABEL — resolve the target path, honouring --save-to and
# --overwrite, and refuse to clobber anything the operator did not ask to lose.
# LABEL is needed as well as SAFE because --overwrite resolves through the saves'
# sidecars, which record the real label, not the filesystem-safe spelling.
save_pick_target() {
    local safe="$1" label="$2" target=""
    if [ -n "${DEV_SAVE_TO}" ]; then
        # A bare name is a convenience, not a special case: it lands in the same
        # ${SAVES_DIR} the defaults use, so `--save-to before-upgrade.qcow2`
        # behaves the way it reads.
        case "${DEV_SAVE_TO}" in
            /*) target="${DEV_SAVE_TO}" ;;
            *)  target="${SAVES_DIR}/${DEV_SAVE_TO}" ;;
        esac
    elif ${DEV_SAVE_OVERWRITE}; then
        target="$(newest_save_for "${safe}" "${label}")"
        # >&2 is load-bearing: this function's STDOUT is the chosen path, read
        # through a command substitution. An info line on stdout would be
        # prepended to the path and the save would land somewhere absurd.
        [ -n "${target}" ] \
            || info "--overwrite: ${safe} has no earlier save to replace — writing a new one" >&2
    fi
    # Default, and the fallback for --overwrite with nothing to overwrite: a NEW
    # timestamped copy. Defaulting to a fresh name is what keeps "save" from
    # being a destructive verb — repeated saves accumulate instead of eating one
    # another, and losing a copy always takes an explicit --overwrite.
    # %Y%m%dT%H%M%SZ, matching core/qemu_devices.SAVE_STAMP_FORMAT and the build
    # artifacts' own stamp. The two spellings were allowed to differ once ('-' sorts
    # before 'T'), so a saves/ dir holding both ordered wrongly by name — which is the
    # single property the stamp was chosen for.
    [ -n "${target}" ] || target="${SAVES_DIR}/${safe}-$(date -u +%Y%m%dT%H%M%SZ).qcow2"
    target="$(readlink -m "${target}")"
    save_check_target "${target}"
    if [ -e "${target}" ] && ! ${DEV_SAVE_OVERWRITE}; then
        die "a save already exists at ${target}; pass --overwrite to replace it, or --save-to a different name"
    fi
    printf '%s\n' "${target}"
}

# Restore the run state the device was in BEFORE the save. Never an unconditional
# `cont`: an operator who had paused a device by hand and then took a copy of it
# must not find it running again afterwards.
save_restore_state() {
    local name="$1" csock="$2" prior="$3" label="$4"
    if [ "${prior}" = "running" ]; then
        if qmp_exec "${name}" "${csock}" "${QMP_TIMEOUT}" cont - - >/dev/null; then
            info "${label}: resumed (it was running before the save)"
        else
            warn "${label}: could NOT resume the device after the save — it is still PAUSED. Resume it with: $0 --work '${WORK}' --qmp '${label}' resume"
        fi
    else
        # Covers "paused" and every other not-running state QEMU reports
        # ("prelaunch", "suspended", ...), which is why it does not say "paused".
        info "${label}: left exactly as it was — the device was not running before the save (${prior:-unknown})"
    fi
}

cmd_save_device() {
    local label="$1" rec sock csock name safe target ctarget prior size copied out rc
    local save_free_bytes

    need_docker
    need_python
    rec="$(device_record_path "${label}")" \
        || die "no device record for '${label}' under ${DEVICES_DIR} (--devices to list what is there)"
    sock="$(record_field "${rec}" qmp)"
    [ -n "${sock}" ] || die "device '${label}' has no qmp socket recorded (started without --keep-alive?)"
    name="$(record_field "${rec}" container)"
    [ -n "${name}" ] || die "device record ${rec} names no container"
    # Identical guard, and identical reason, to cmd_qmp: everything below ends in
    # a root `docker exec` on a name that came out of a file on disk, and the
    # operator's live hugmesh stack runs on this same machine.
    own_container "${name}" "save the disk of" "${label}" || return 1
    container_is_running "${name}" \
        || die "device '${label}' is not running (container ${name}) — there is no live disk to copy; --devices to check"
    csock="$(container_path_for "${sock}")"

    safe="$(safe_label "${label}")"
    # HOST-side, so the directory belongs to the operator before root ever writes
    # into it — the same ordering docker-entrypoint.sh uses for the registry dir.
    mkdir -p "${SAVES_DIR}" || die "cannot create ${SAVES_DIR}"
    target="$(save_pick_target "${safe}" "${label}")" || exit 1
    ctarget="$(container_path_for "${target}")"

    if [ -e "${target}" ]; then
        # Said before anything is touched, because it is already true by then:
        # the target is recreated before the copy starts, so from here on the
        # old copy is gone whether or not the new one finishes.
        warn "${label}: OVERWRITING the existing save ${target} — the previous copy is discarded as soon as the copy begins"
    fi
    step "Saving ${label} -> ${target}"

    # 1. Flush, 2. read the state we must restore, 3. pause. In that order: the
    # sync has to reach a guest that is still running.
    save_flush_guest "${rec}" "${label}"

    out="$(qmp_exec "${name}" "${csock}" "${QMP_TIMEOUT}" query-status - -)"; rc=$?
    case "${rc}" in
        12[567]) die "docker exec could not run perl in ${name} (rc=${rc}); the runner image is expected to provide it" ;;
    esac
    [ "${rc}" -eq 0 ] || die "${label}: could not read the device's run state (rc=${rc}); nothing was changed"
    prior="$(printf '%s\n' "${out}" | qmp_parse status)"
    # Not a formality. Every later decision hangs off this word: an unreadable
    # state would skip the `stop` below — copying a disk the guest is still
    # writing to — and then report a save that looks exactly like a good one.
    # Nothing has been touched yet, so refusing here costs nothing.
    [ -n "${prior}" ] \
        || die "${label}: could not read the device's run state from query-status; refusing to copy a disk that may still be being written. Nothing was changed."
    info "${label}: run state before the save: ${prior}"

    if [ "${prior}" = "running" ]; then
        qmp_exec "${name}" "${csock}" "${QMP_TIMEOUT}" stop - - >/dev/null \
            || die "${label}: QMP stop failed; the device was NOT paused and nothing was copied"
        info "${label}: PAUSED for the copy (crash-consistent: the guest sees this as a pulled plug)"
    fi

    # From here until the copy is detached, an interrupted run would leave the
    # operator's device PAUSED with no indication why — the Studio's Save button has
    # an explicit Cancel, so this is a first-class action, not a hypothetical. The
    # script has no other traps, so this one is installed for exactly this window and
    # removed at the end of it. It undoes the same three things the failure path does,
    # in the same order, and then re-raises so the exit status still reports a signal.
    save_on_signal() {
        local sig="$1"
        warn "${label}: interrupted by SIG${sig} mid-save — putting the device back"
        qmp_exec "${name}" "${csock}" "${QMP_TIMEOUT}" \
            block-job-cancel "{\"device\":\"${SAVE_JOB}\"}" BLOCK_JOB_CANCELLED \
            >/dev/null 2>&1 || true
        qmp_exec "${name}" "${csock}" "${QMP_TIMEOUT}" \
            blockdev-del "{\"node-name\":\"${SAVE_NODE}\"}" - >/dev/null 2>&1 || true
        # Rename before restoring: a half-written .qcow2 left under its final name is
        # the worst outcome in the contract — --list-saves would offer it and it would
        # open. The chown matters too, or the operator cannot even delete it.
        docker exec -u 0 "${name}" sh -c \
            'test -e "$1" && mv -f "$1" "$1.partial" && chown "$2" "$1.partial"' _ \
            "${ctarget}" "$(id -u):$(id -g)" >/dev/null 2>&1 || true
        save_restore_state "${name}" "${csock}" "${prior}" "${label}"
        warn "${label}: any partial copy is at ${target}.partial and must not be trusted"
        trap - INT TERM
        kill -s "${sig}" $$
    }
    trap 'save_on_signal TERM' TERM
    trap 'save_on_signal INT'  INT

    # 4. The target has to exist, and at exactly the guest disk's size, before
    # blockdev-add can open it. qemu-img lives in the runner image
    # (docker/Dockerfile.qemu-runner:40) and runs INSIDE the container because
    # that is where the writable /work mount and the tool both are.
    out="$(qmp_exec "${name}" "${csock}" "${QMP_TIMEOUT}" query-block - -)"; rc=$?
    if [ "${rc}" -ne 0 ]; then
        save_restore_state "${name}" "${csock}" "${prior}" "${label}"
        die "${label}: query-block failed (rc=${rc}); nothing was copied"
    fi
    size="$(printf '%s\n' "${out}" | qmp_parse size)"
    if ! [[ "${size}" =~ ^[0-9]+$ ]]; then
        save_restore_state "${name}" "${csock}" "${prior}" "${label}"
        die "${label}: could not determine the size of drive '${SAVE_DRIVE}' from query-block; nothing was copied"
    fi
    info "${label}: guest disk is ${size} bytes ($((size / 1024 / 1024)) MiB) on drive '${SAVE_DRIVE}'"

    # Refuse before pausing turns into a half-filled filesystem. A save is NOT the
    # small delta a sparse test image suggests: sync=full copies every cluster the
    # source reads as allocated and the goldens are allocated in full, so budget the
    # whole virtual size. Running the host out of space mid-copy would leave a giant
    # .partial AND take down anything else writing there — on this workstation that
    # has meant the mesh's own volumes.
    save_free_bytes="$(df -PB1 "${SAVES_DIR}" 2>/dev/null | awk 'NR==2{print $4}')"
    if [[ "${save_free_bytes}" =~ ^[0-9]+$ ]] && [ "${save_free_bytes}" -lt "${size}" ]; then
        save_restore_state "${name}" "${csock}" "${prior}" "${label}"
        trap - INT TERM
        die "${label}: not enough space for this save. It needs up to ${size} bytes ($((size / 1024 / 1024 / 1024)) GiB — a save is the disk's FULL size, not just what the guest wrote) and $(df -h "${SAVES_DIR}" 2>/dev/null | awk 'NR==2{print $6}') has only $(df -h "${SAVES_DIR}" 2>/dev/null | awk 'NR==2{print $4}') free. Delete old saves (--list-saves ${label}) or pass --save-to on a bigger filesystem."
    fi

    if ! docker exec -u 0 "${name}" qemu-img create -f qcow2 "${ctarget}" "${size}" >/dev/null; then
        save_restore_state "${name}" "${csock}" "${prior}" "${label}"
        trap - INT TERM
        die "${label}: could not create the save target ${target}"
    fi

    # 5. THE COPY. One connection, because BLOCK_JOB_COMPLETED is delivered to
    # whoever is connected when the job ends (see the QMP_PERL header). sync=full
    # is what makes the result standalone and merged rather than a diff against
    # the golden: the source's whole visible content is written to the target,
    # and the target has no backing file of its own.
    out="$(qmp_exec "${name}" "${csock}" "${DEV_SAVE_TIMEOUT}" \
        blockdev-add "{\"driver\":\"qcow2\",\"node-name\":\"${SAVE_NODE}\",\"file\":{\"driver\":\"file\",\"filename\":$(json_str "${ctarget}")}}" - \
        blockdev-backup "{\"device\":\"${SAVE_DRIVE}\",\"target\":\"${SAVE_NODE}\",\"sync\":\"full\",\"job-id\":\"${SAVE_JOB}\"}" BLOCK_JOB_COMPLETED \
        blockdev-del "{\"node-name\":\"${SAVE_NODE}\"}" -)"
    rc=$?
    # Quote the whole conversation back. This is the one step with no other
    # witness — the block job runs inside QEMU and leaves nothing in a log.
    [ -z "${out}" ] || printf '%s\n' "${out}" | sed 's/^/    qmp: /'

    copied=""
    if [ "${rc}" -eq 0 ]; then
        copied="$(printf '%s\n' "${out}" | qmp_parse job)" || rc=9
    fi

    if [ "${rc}" -ne 0 ]; then
        # The target node and possibly a live job are still attached to a device
        # the operator will want to keep using, so tear them down before saying
        # anything else. They fail harmlessly when the step that would have created
        # them never ran.
        #
        # WAIT FOR THE CANCEL. block-job-cancel returns the moment the request is
        # accepted and the job unwinds asynchronously, so a blockdev-del fired
        # straight after it runs while the node is still in use, fails, and — being
        # silenced — leaves ${SAVE_NODE} attached. The NEXT save then dies on
        # `Duplicate nodes with node-name='hugmesh-save-tgt'` while blaming a
        # partial copy, and only the third attempt succeeds. Blocking on
        # BLOCK_JOB_CANCELLED is what makes the delete meet a free node.
        qmp_exec "${name}" "${csock}" "${QMP_TIMEOUT}" \
            block-job-cancel "{\"device\":\"${SAVE_JOB}\"}" BLOCK_JOB_CANCELLED \
            >/dev/null 2>&1
        # Not silenced: if the node really is still attached the next save is the
        # one that pays, so say it here where the cause is still on screen.
        if ! qmp_exec "${name}" "${csock}" "${QMP_TIMEOUT}" \
                blockdev-del "{\"node-name\":\"${SAVE_NODE}\"}" - >/dev/null 2>&1; then
            warn "${label}: could not detach the save node ${SAVE_NODE}. If the next save fails with \"Duplicate nodes\", stop and restart this device to clear it."
        fi
        # A half-copied file that still ends in .qcow2 is the worst outcome of
        # all: --list-saves would offer it, and it would open. Rename it out of
        # the way, in the container, where it is still root-owned.
        docker exec -u 0 "${name}" sh -c \
            'test -e "$1" && mv -f "$1" "$1.partial" && chown "$2" "$1.partial"' _ \
            "${ctarget}" "$(id -u):$(id -g)" >/dev/null 2>&1 || true
        save_restore_state "${name}" "${csock}" "${prior}" "${label}"
        die "${label}: THE SAVE FAILED (rc=${rc}). Any partial copy was renamed to ${target}.partial and must not be trusted."
    fi

    # 6. The copy is complete and detached, so the device can run again. Do this
    # FIRST, before the bookkeeping below: every extra step here is time the
    # operator's device spends frozen for no remaining reason.
    save_restore_state "${name}" "${csock}" "${prior}" "${label}"
    # The guest is back; from here an interrupt costs bookkeeping, not a frozen
    # device, so the window the trap guards is over.
    trap - INT TERM

    # 7. Hand the file to the host operator. qemu created it as root inside the
    # container, and the Studio that will list and open it runs as the invoking
    # user on the host — the same defect class the ssh key already has a fix for
    # in docker-entrypoint.sh write_device_record (:282-286). Doing it here, not
    # at container exit, because under --keep-alive that exit is hours away.
    docker exec -u 0 "${name}" chown "$(id -u):$(id -g)" "${ctarget}" >/dev/null 2>&1 \
        || warn "${label}: the save could not be chowned to the host user; you may need sudo to read ${target}"

    save_write_sidecar "${target}" "${label}" "${size}" "${copied}" "${prior}"

    info "${label}: SAVED ${copied} bytes of guest disk"
    info "  file        : ${target}"
    # Report what it ACTUALLY cost, and never dress it up. `sync=full` copies every
    # cluster the source reads as allocated, and the goldens are allocated in full,
    # so this is normally GB-scale rather than the delta a sparse image implies.
    info "  on disk     : $( { du -h "${target}" 2>/dev/null || echo '?'; } | cut -f1)  (of ${size} bytes virtual; saves are not sparse — see below)"
    info "  free after  : $( { df -h "${SAVES_DIR}" 2>/dev/null | awk 'NR==2{print $4" on "$6}'; } || echo '?')"
    info "  consistency : crash-consistent"
    info "  standalone  : yes — no backing file; it holds the run overlay's changes merged over the golden image's data"
    info "  golden      : untouched"
    return 0
}

# A sidecar next to each save, so a later --list-saves (and the Studio behind it)
# can say what a file IS without opening it: which device it came from, when,
# and how consistent it is. Written host-side after the chown, in python3 for
# the escaping — a label contains a '/' and a path can contain anything.
save_write_sidecar() {
    local target="$1" label="$2" size="$3" copied="$4" prior="$5"
    need_python
    SAVE_LABEL="${label}" SAVE_SIZE="${size}" SAVE_COPIED="${copied}" \
    SAVE_PRIOR="${prior}" SAVE_DRIVE_NAME="${SAVE_DRIVE}" \
    python3 - "${target}" <<'PYSIDE' || warn "could not write the save sidecar for $1"
import datetime, json, os, sys

target = sys.argv[1]
rec = {
    "label": os.environ.get("SAVE_LABEL", ""),
    "target": target,
    "drive": os.environ.get("SAVE_DRIVE_NAME", ""),
    "virtual_size": int(os.environ.get("SAVE_SIZE") or 0),
    "bytes_copied": int(os.environ.get("SAVE_COPIED") or 0),
    "device_state_before": os.environ.get("SAVE_PRIOR", ""),
    # Stated in the file itself so nobody has to remember it later: QMP `stop`
    # is a pulled plug from the guest's point of view.
    "consistency": "crash-consistent",
    "method": "qmp blockdev-backup sync=full",
    "standalone": True,
    "created_at": datetime.datetime.now(datetime.timezone.utc)
                          .strftime("%Y-%m-%dT%H:%M:%SZ"),
}
tmp = "%s.tmp.%d" % (target + ".json", os.getpid())
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(rec, fh, indent=2)
    fh.write("\n")
os.replace(tmp, target + ".json")          # atomic: --list-saves may be reading
PYSIDE
}

cmd_list_saves() {
    local label="$1" safe
    need_python
    safe="$(safe_label "${label}")"
    # An empty array for a device that has never been saved, never an error:
    # this is the question the Studio asks before it has anything to show.
    SAVE_LABEL="${label}" SAVE_SAFE="${safe}" python3 - "${SAVES_DIR}" <<'PYLIST'
import datetime, json, os, sys

saves_dir = sys.argv[1]
label = os.environ.get("SAVE_LABEL", "")
safe = os.environ.get("SAVE_SAFE", "")

try:
    entries = sorted(os.listdir(saves_dir))
except OSError:
    entries = []

out = []
# Orphaned partial copies are reported ALONGSIDE the saves, never as saves. A failed
# or interrupted save renames its target to <name>.partial, and that file is the same
# size as the save would have been — which on real images is 9.5-20.5 GB. Nothing
# deletes them, so a listing that silently omitted them would leave the operator
# looking at "3 saves" while the directory held six files. `partial: true` is how a
# caller tells them apart; nothing here removes anything on its own, because deleting
# an operator's data as a side effect of LISTING it would be its own defect.
partials = []
for name in entries:
    if name.endswith(".qcow2.partial"):
        ppath = os.path.join(saves_dir, name)
        base = name[:-len(".partial")]
        owns = base == safe + ".qcow2" or base.startswith(safe + "-")
        try:
            pst = os.stat(ppath)
        except OSError:
            continue
        if owns:
            partials.append({
                "path": ppath,
                "label": label,
                "file_bytes": pst.st_size,
                "modified_at": datetime.datetime.fromtimestamp(
                    pst.st_mtime, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "partial": True,
                "has_metadata": False,
            })
        continue
    if not name.endswith(".qcow2"):        # .json sidecars are not saves
        continue
    path = os.path.join(saves_dir, name)
    side = {}
    try:
        with open(path + ".json", "r", encoding="utf-8") as fh:
            loaded = json.load(fh)
        if isinstance(loaded, dict):
            side = loaded
    except (OSError, ValueError):
        side = {}
    # The sidecar is authoritative about which device a save came from, because
    # --save-to lets an operator name a file anything at all. The filename rule
    # is only the fallback for a save whose sidecar is missing or unreadable.
    if side:
        if side.get("label") != label:
            continue
    elif not (name == safe + ".qcow2" or name.startswith(safe + "-")):
        continue
    try:
        st = os.stat(path)
    except OSError:
        continue
    rec = dict(side)
    rec["path"] = path
    rec["file_bytes"] = st.st_size
    rec["modified_at"] = datetime.datetime.fromtimestamp(
        st.st_mtime, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    rec["label"] = side.get("label", label)
    rec["has_metadata"] = bool(side)
    out.append(rec)

for rec in out:
    rec["partial"] = False
out.extend(partials)
out.sort(key=lambda r: str(r.get("modified_at") or ""), reverse=True)  # newest first
json.dump(out, sys.stdout, indent=2)
sys.stdout.write("\n")
PYLIST
}

if [ -n "${DEV_ACTION}" ]; then
    # These run BEFORE artifact resolution and before the docker-daemon probe on
    # purpose. Artifact resolution die()s when the newest session holds no image,
    # which has nothing to do with stopping a device that is already running; and
    # --devices is a plain file read that must still work with docker stopped.
    # readlink -m, not -f: --devices on a work dir that was never created should
    # print [] rather than fail, and must not create the directory as a side
    # effect of being asked a read-only question.
    WORK="$(readlink -m "${WORK}")"
    set_device_paths
    # --overwrite and --save-to only mean anything to --save-device. Silently
    # ignoring them is how an operator ends up believing a copy was replaced
    # when it never was, so say it out loud instead.
    if [ "${DEV_ACTION}" != "save" ]; then
        ${DEV_SAVE_OVERWRITE} && warn "--overwrite only applies to --save-device; ignoring it"
        [ -z "${DEV_SAVE_TO}" ] || warn "--save-to only applies to --save-device; ignoring it"
    fi
    case "${DEV_ACTION}" in
        devices)    cmd_devices ;;
        stop)       cmd_stop_device "${DEV_LABEL}" ;;
        stop-all)   cmd_stop_all ;;
        qmp)        cmd_qmp "${DEV_LABEL}" "${DEV_QMP_CMD}" ;;
        save)       cmd_save_device "${DEV_LABEL}" ;;
        list-saves) cmd_list_saves "${DEV_LABEL}" ;;
        *)          die "internal: unknown device action '${DEV_ACTION}'" ;;
    esac
    exit $?
fi

command -v docker >/dev/null || die "docker not found"
docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon (is your user in the 'docker' group?)"

# ── Discover runnable rows from the artifacts actually present ──────────────
# Artifact naming: <brand>-<platform>-<arch>-<role>-<env>-<stamp>.img[.xz]
# <role> may itself contain '-' (standalone-thin), so parse from BOTH ends:
# fields 1..2 are brand+platform, the arch follows, and the last two fields
# before the extension are <env>-<stamp>.
#
# THE FIRST FIELD IS THE BRAND AND IT IS NOT ALWAYS "hugmesh". The builders name
# artifacts ${BRAND}-… (build-rpi5-stage4.sh IMG_PATH, build-x86-host-stage4.sh
# IMG_PATH) and BRAND is whatever --brand the build ran under: hugmesh only by
# default, sdhm for the operator's own mesh, gentoo for an unaffiliated build.
# This loop used to require the literal `hugmesh-` prefix, so a finished branded
# mesh listed ZERO rows here and the Studio's picker (which mirrors this rule in
# qemu_tests.parse_artifact_name) showed no session at all.
#
# What still rejects a foreign .img is the SHAPE, not the brand: six
# '-'-separated fields and a trailing YYYYmmddTHHMMSSZ build stamp. Without the
# field count the both-ends strip below happily "parses" a too-short name (e.g.
# hugmesh-x86-be.img) into role==env; without the stamp anchor an arbitrary
# six-word .img sitting in the dir would become a bootable row.
discover_rows() {
    # Optional DIR argument so the SESSION PICKER can ask the same question
    # this function answers ("does this dir hold a runnable row?") instead of
    # keeping a second, looser rule of its own. Defaults to ${ARTIFACTS} for
    # the main enumeration below.
    local dir="${1:-${ARTIFACTS}}"
    local f base rest platform arch role env stamp prefer
    local -a _fields
    for f in "${dir}"/*.img "${dir}"/*.img.xz; do
        [ -e "${f}" ] || continue
        # A ZERO-BYTE .img is the builder's pre-partition placeholder from a run
        # that was killed; booting it fails, and counting it makes an aborted
        # build read as complete. Python applies the same rule (qemu_tests
        # discover_rows, os.path.getsize).
        [ -s "${f}" ] || continue
        base="$(basename "${f}")"
        base="${base%.xz}"; base="${base%.img}"
        case "${base}" in *kernel*|*initramfs*|*initrd*|*squashfs*) continue ;; esac
        # Match the Python contract (studio/hugmesh_studio/core/qemu_tests.py
        # parse_artifact_name / _split_artifact_name).
        IFS='-' read -r -a _fields <<< "${base}"
        [ "${#_fields[@]}" -ge 6 ] || continue
        stamp="${base##*-}"
        [[ "${stamp}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || continue
        rest="${base#*-}"          # drop <brand>, whatever it is
        platform="${rest%%-*}"; rest="${rest#*-}"
        arch="${rest%%-*}";     rest="${rest#*-}"
        # rest is now "<role>-<env>-<stamp>"; strip the two trailing fields.
        rest="${rest%-*}"          # drop <stamp>
        env="${rest##*-}"          # <env>
        role="${rest%-*}"          # <role>, '-' and all
        [ -n "${platform}" ] && [ -n "${role}" ] || continue
        # Fold an older spelling baked into the FILENAME (be / fe / be+gpu / host /
        # edge_ai). The file itself is never renamed — it is an already-emitted
        # artifact — but the ROW must carry one spelling, the same one the Python
        # twin produces.
        role="$(hugmesh_role_canonicalize "${role}" || printf '%s' "${role}")"
        # Emit the sort key first, strip it after collapsing. Field 2 is
        # "1" for a decompressed .img so it outranks its own .img.xz.
        case "${f}" in *.xz) prefer=0 ;; *) prefer=1 ;; esac
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${stamp}" "${prefer}" "${platform}" "${role}" "${env}" "${f}"
    done
}

# ── Resolve the artifacts dir ───────────────────────────────────────────────
# A build SESSION is out/sessions/<stamp>/; several are usually empty shells
# (a session dir is minted at wizard time, before any artifact lands), so
# "newest" means newest that actually holds an image.
# "Holds an image" must mean exactly what discover_rows means by it, or this
# picker selects a session the row loop then refuses and the run dies at
# "no runnable rows found" WITHOUT falling through to the older session that
# holds a finished build — the very "your completed build is invisible" symptom
# this resolver exists to prevent. Bare existence is not enough: a killed build
# leaves a ZERO-BYTE .img placeholder behind, and a name that carries no
# YYYYmmddTHHMMSSZ stamp is not an artifact we can boot. So ask discover_rows.
# (Capture into a variable rather than `| grep -q`: pipefail is set, and a
# SIGPIPE'd producer makes a FOUND match report failure.)
newest_session_with_images() {
    local d rows
    while IFS= read -r d; do
        rows="$(discover_rows "${d}")"
        if [ -n "${rows}" ]; then
            printf '%s\n' "${d}"; return 0
        fi
    done < <(ls -1dt "${REPO_DIR}"/out/sessions/*/ 2>/dev/null)
    return 1
}

if [ -z "${ARTIFACTS}" ]; then
    if [ -z "${SESSION}" ]; then
        SESSION="$(newest_session_with_images || true)"
        [ -n "${SESSION}" ] || die "no build session under out/sessions/ holds a bootable image — build first, or pass --artifacts DIR. (A zero-byte .img from a killed build, or a name with no YYYYmmddTHHMMSSZ stamp, does not count.)"
    fi
    ARTIFACTS="${SESSION}"
fi
ARTIFACTS="$(readlink -f "${ARTIFACTS}")"
[ -d "${ARTIFACTS}" ] || die "artifacts dir not found: ${ARTIFACTS}"
mkdir -p "${WORK}"
WORK="$(readlink -f "${WORK}")"

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

# row_matches_filters PLATFORM ROLE — every row filter in one place. --only
# stays a SUBSTRING on the label (the human spelling); --only-exact is full
# equality, because "x86/be" as a substring also matches x86/be+gpu and
# x86/be-ha, and a per-device Start that boots two extra 20G guests as a side
# effect is not a Start button.
row_matches_filters() {
    local platform="$1" role="$2"
    [ -z "${PLATFORM_FILTER}" ] || [ "${platform}" = "${PLATFORM_FILTER}" ]    || return 1
    [ -z "${ROLE_FILTER}" ]     || [ "${role}" = "${ROLE_FILTER}" ]            || return 1
    [ -z "${ONLY}" ]            || [[ "${platform}/${role}" == *"${ONLY}"* ]]  || return 1
    [ -z "${ONLY_EXACT}" ]      || [ "${platform}/${role}" = "${ONLY_EXACT}" ] || return 1
    return 0
}

ROWS=()
while IFS=$'\t' read -r platform role env img; do
    [ -n "${platform}" ] || continue
    row_matches_filters "${platform}" "${role}" || continue
    ROWS+=("$(platform_rank "${platform}")|${platform}|${role}|${env}|${img}")
done < <(discover_rows | collapse_rows)

[ "${#ROWS[@]}" -gt 0 ] || die "no runnable rows found in ${ARTIFACTS} (filters: platform='${PLATFORM_FILTER}' role='${ROLE_FILTER}' only='${ONLY}' only-exact='${ONLY_EXACT}')"

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
    #
    # --assert-timeout is forwarded as a FLAG on purpose. This docker run passes
    # exactly two -e (HOST_UID/HOST_GID) and docker inherits nothing else from
    # the invoking shell, so a knob exposed only as an environment variable in
    # docker-entrypoint.sh would be unreachable from every supported entry
    # point: Makefile `qemu-docker` and the Studio (core/qemu_tests.py
    # runner_command) both exec THIS script and can only ever add argv.
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
        ${ASSERT_TIMEOUT:+--assert-timeout "${ASSERT_TIMEOUT}"} \
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

# ── Bound the decompressed-image cache ──────────────────────────────────────
# docker-entrypoint.sh expands every .img.xz row to ${WORK}/images/<name>.img
# and nothing has ever deleted one: the entrypoint only removes the .part of the
# decompress it is itself about to redo, and neither this script nor the Studio
# touches that directory at all. Measured here before this change:
# `du -sh out/qemu-runs/images` = 118G — 7 raw images (9.5G for an rpi5 role,
# 16.5-20.5G for the x86 ones) plus one orphaned 16.5G probe.part.
#
# It never shrinks, and an age-out would not shrink it either: every rebuild
# emits a NEW timestamped artifact, so the next run decompresses a NEW entry and
# strands the previous one the same minute — the stranded copy is days away from
# being "old" while the disk is already gone.
#
# POLICY. Charge this run's own images to the budget first (they are exempt from
# deletion — see below), then walk everything else newest-first and delete once
# the running total passes the cap. Ordering key is decompress time, which is
# the correct order here precisely because the superseded copy is always the
# older one. After a sweep the cache holds at most max(cap, this run's images);
# growth is therefore bounded by ONE run's working set instead of by every run
# ever made against this ${WORK}. --cache-max-gb 0 restores the old behaviour.
#
# WHY THE SWEEP LIVES HERE AND NOT IN THE ENTRYPOINT: run_row fans containers
# out ${JOBS} at a time over a shared ${WORK}, and a container can only know its
# OWN image — a sibling's entry would be deletable in the window between that
# sibling's cache-hit test and its boot. This sweep runs in the main process at
# points where no container of this run is alive, with a spare-list covering
# every row, so neither race exists. Two consequences, stated plainly: a bare
# `docker run` of the entrypoint (documented in its usage) still reclaims
# nothing, and two CONCURRENT invocations of this script against the same --work
# can still delete each other's cached images — the loser re-decompresses, which
# costs time, not correctness, since /artifacts is read-only and untouched.

# The basenames under ${WORK}/images that cache_sweep must NEVER delete, one
# per line. Two sources:
#   * this run's own rows: the decompressed spelling of every .img.xz row (what
#     the entrypoint is about to create or reuse), plus plain-.img basenames for
#     completeness — those boot straight from /artifacts and simply never match;
#   * every image a device record points at while that record's container still
#     EXISTS (docker ps -a, not just running: a stopped keep-alive device can be
#     started again and its overlay still backs onto the decompressed golden by
#     absolute path). When docker does not answer, every record-referenced image
#     is protected — never steal blind.
# Records are files this harness itself writes (json_str-escaped, one key per
# line), so the sed field-pluck is exact for them; python is deliberately not
# required on this path.
cache_protected_names() {
    local r img rec image cname existing
    for r in "${ROWS[@]}"; do
        IFS='|' read -r _ _ _ _ img <<< "${r}"
        case "${img}" in
            *.img.xz) printf '%s\n' "$(basename "${img}" .xz)" ;;
            *)        printf '%s\n' "$(basename "${img}")" ;;
        esac
    done
    [ -d "${DEVICES_DIR}" ] || return 0
    if docker info >/dev/null 2>&1; then
        existing="$(docker ps -a --format '{{.Names}}' 2>/dev/null)"
        for rec in "${DEVICES_DIR}"/*.json; do
            [ -f "${rec}" ] || continue
            image="$(sed -n 's/^ *"image": *"\([^"]*\)".*$/\1/p' "${rec}" | head -1)"
            [ -n "${image}" ] || continue
            cname="$(sed -n 's/^ *"container": *"\([^"]*\)".*$/\1/p' "${rec}" | head -1)"
            [ -n "${cname}" ] || continue
            grep -qxF "${cname}" <<< "${existing}" || continue
            printf '%s\n' "${image}"
        done
    else
        for rec in "${DEVICES_DIR}"/*.json; do
            [ -f "${rec}" ] || continue
            sed -n 's/^ *"image": *"\([^"]*\)".*$/\1/p' "${rec}" | head -1
        done
    fi
    return 0
}

cache_sweep() {
    # 0 = unbounded: the historical behaviour, byte for byte — nothing is
    # deleted, not even a stale .part.
    [ "${CACHE_MAX_GB}" -gt 0 ] || return 0
    local imgdir="${WORK}/images"
    [ -d "${imgdir}" ] || return 0
    local budget=$((CACHE_MAX_GB * 1024 * 1024 * 1024)) total=0
    local protected f base mtime size path

    # Orphaned .part files first, budget or no budget. A LIVE decompress
    # rewrites its .part's mtime continuously (xz streams into it), so one
    # untouched for an hour can only be the leavings of a killed run — a 16.5G
    # probe.part sat here from 2026-08-13 with nothing ever going to reclaim
    # it. A .part younger than that is potentially another invocation's
    # in-flight decompress and is never touched.
    for f in "${imgdir}"/*.part; do
        [ -e "${f}" ] || continue
        [ -n "$(find "${f}" -maxdepth 0 -mmin +60 2>/dev/null)" ] || continue
        info "cache: removing orphaned stale $(basename "${f}") ($(du -h "${f}" 2>/dev/null | cut -f1 || echo '?'))"
        rm -f "${f}"
    done

    protected="$(cache_protected_names)"

    # Pass 1: charge every protected image that exists to the budget FIRST.
    # They are exempt from deletion whatever they cost, which is why the cache
    # can legitimately hold max(cap, this run's images) after a sweep.
    for f in "${imgdir}"/*; do
        [ -f "${f}" ] || continue
        case "${f}" in *.part) continue ;; esac
        base="${f##*/}"
        grep -qxF "${base}" <<< "${protected}" || continue
        size="$(stat -c '%s' "${f}" 2>/dev/null || echo 0)"
        total=$((total + size))
    done

    # Pass 2: everything else, newest mtime first; evict once the running
    # total would pass the cap. Newest-first is the LRU half: the files that
    # fit under the cap are the most recently touched ones.
    while read -r mtime size path; do
        [ -n "${path}" ] || continue
        base="${path##*/}"
        grep -qxF "${base}" <<< "${protected}" && continue
        if [ $((total + size)) -gt "${budget}" ]; then
            info "cache: evicting ${base} ($(( size / 1024 / 1024 / 1024 ))G, over the ${CACHE_MAX_GB}G cap)"
            rm -f "${path}"
        else
            total=$((total + size))
        fi
    done < <(
        for f in "${imgdir}"/*; do
            [ -f "${f}" ] || continue
            case "${f}" in *.part) continue ;; esac
            stat -c '%Y %s %n' "${f}" 2>/dev/null
        done | sort -rn -k1,1
    )
    return 0
}


# ── Keep-alive: start the devices and leave them up ─────────────────────────
# A test run boots, asserts and powers the guest off; --keep-alive starts the
# same container with the same arguments plus --keep-alive, publishes its ssh,
# and returns. Nothing below waits: the guests are minutes from answering ssh
# (aarch64 is pure TCG on this host) and the point of the mode is that the
# operator gets the prompt back and drives the devices from the Studio.
set_device_paths

# Sweep BEFORE the decompress fan-out (both the test path and keep-alive pass
# through here): with the cap in force, the space the new rows are about to
# decompress into is reclaimed from superseded images now, not after the fan-out
# has already filled the disk.
cache_sweep

port_free() {
    local p="$1"
    # ss sees a listener on ANY address, which matters because the thing we must
    # never collide with (the operator's live stack) binds 0.0.0.0, not loopback.
    if command -v ss >/dev/null 2>&1; then
        ss -H -ltn "sport = :${p}" 2>/dev/null | grep . >/dev/null && return 1
        return 0
    fi
    # No iproute2: a connect probe still catches anything actually accepting.
    # bash's /dev/tcp is a builtin, so this adds no dependency of its own.
    if (exec 3<>"/dev/tcp/127.0.0.1/${p}") 2>/dev/null; then return 1; fi
    return 0
}

# The ports still worth trying, best first. Three independent exclusions, none
# of which is sufficient alone (see the DEV_PORTS_TAKEN block above): what this
# process has already handed out, what docker has published for ANY container,
# and what something on the host is listening on.
candidate_ports() {
    local busy p
    busy=" ${DEV_PORTS_TAKEN[*]-} $(docker_published_ports | tr '\n' ' ') "
    for (( p=DEV_PORT_MIN; p<=DEV_PORT_MAX; p++ )); do
        case "${busy}" in *" ${p} "*) continue ;; esac
        port_free "${p}" || continue
        printf '%s\n' "${p}"
    done
}

# --extra-user has no environment spelling, so it has to be argv. That is safe
# for the entrypoint that will actually run: docker/Dockerfile.qemu-runner's shim
# prefers the bind-mounted /src copy, which is THIS checkout's, over the baked
# one. Every name was validated against ^[a-z_][a-z0-9_-]*$ at parse time.
EXTRA_USER_ARGS=()
for _u in "${EXTRA_USERS[@]}"; do EXTRA_USER_ARGS+=(--extra-user "${_u}"); done
unset _u

start_device_row() {
    local platform="$1" role="$2" img="$3"
    local label="${platform}/${role}"
    local safe; safe="$(safe_label "${label}")"
    local name="${DEV_NAME_PREFIX}${safe}"
    # `chosen` is set ONLY once docker has actually bound the port, so no exit
    # from the loop below can be mistaken for a successful start.
    local port err rc chosen=""
    local mesh_mac="" mesh_ip="" mesh_plen=""
    # The mesh lane's per-row additions to `docker run`, in ONE array expanded at
    # ONE place below. Empty unless --mesh-net was given, which is what keeps a
    # normal run's docker argv byte-for-byte what it has always been.
    local mesh_args=()

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -xF "${name}" >/dev/null; then
        warn "${label} is already up as ${name} — leaving it alone (--stop-device '${label}' first to replace it)"
        return 0
    fi
    # An exited container of this name is kept on purpose by --stop-device (its
    # `docker logs` is the only post-mortem a detached device has). Now that the
    # row is being started again, that copy is in the way of the name.
    docker rm "${name}" >/dev/null 2>&1 || true
    # The row's previous registry record is stale by definition here (no
    # container of this name is running), and the admission gate reads "this
    # row's record appeared" as boot progress — so clear the old one now,
    # before it can impersonate the record the new container will write.
    rm -f "${DEVICES_DIR}/${safe}.json" 2>/dev/null || true

    # This row's identity on the shared L2, looked up ONCE. A row the identity
    # file does not cover cannot be given an address, and a device on a shared L2
    # with no address is not a mesh member — it is a guest that comes up and
    # answers nobody. Refuse the row and name it, rather than starting a fleet
    # that is quietly one node short of the cluster it is meant to form.
    if [ -n "${MESH_NET}" ]; then
        mesh_mac="${MESH_MAC_FOR[${label}]:-}"
        mesh_ip="${MESH_IP_FOR[${label}]:-}"
        mesh_plen="${MESH_PLEN_FOR[${label}]:-24}"
        if [ -z "${mesh_mac}" ] || [ -z "${mesh_ip}" ]; then
            warn "${label}: the identity file names no mac/ip for this row, so it has no address on the shared L2 — replan the session so the file covers every row (not starting it)"
            return 1
        fi
        mesh_args=(--network "${MESH_NET_NAME}"
                   -e MESH_NET="${MESH_NET}"
                   -e MESH_MAC="${mesh_mac}"
                   -e MESH_IP="${mesh_ip}"
                   -e MESH_PREFIX_LEN="${mesh_plen}")
    fi

    while IFS= read -r port; do
        # Belt and braces. The candidate list is generated from the range, but
        # this is the single line that decides what gets bound on the host, and
        # the one promise that must never break is that it is neither :8080 nor
        # :8443 nor anything else the live stack might want.
        if [ "${port}" -lt "${DEV_PORT_MIN}" ] || [ "${port}" -gt "${DEV_PORT_MAX}" ]; then
            warn "refusing to publish out-of-range port ${port}"; continue
        fi
        claim_port "${port}" "${name}" || continue

        # THE PORT GOES IN TWICE, and both halves are load-bearing:
        #   -p 127.0.0.1:<port>:2222  makes it reachable from the host, loopback
        #                             only, so an emulated device is never exposed
        #                             off this workstation;
        #   -e SSH_HOST_PORT=<port>   tells the entrypoint which number to write
        #                             into the device record. Nothing inside the
        #                             container can work it out: the guest forward
        #                             is on ${GUEST_SSH_PORT} in there, and the
        #                             host side of a published port is invisible to
        #                             it. Without this the record says 0, and
        #                             core/qemu_devices.py ssh_argv() then builds
        #                             `ssh -p 0` — a terminal button that cannot
        #                             connect to anything.
        # -e CONTAINER_NAME is the same shape of problem: /etc/hostname inside a
        # container is the short container ID, and A2's "container" field has to
        # be the NAME, or --stop-device and the `docker ps` reconciliation in
        # cmd_devices can never match a record to its container.
        # docker-entrypoint.sh takes HOST_UID, HOST_GID, HOST_WORK,
        # HOST_ARTIFACTS, SSH_HOST_PORT and CONTAINER_NAME from the environment
        # (HOST_ARTIFACTS is how the record's "artifacts" field can name the
        # HOST dir a per-device restart must be pointed back at); most also have
        # flag spellings (--host-work/--host-artifacts/--ssh-host-port/
        # --container). The env spelling is
        # used wherever there is a choice because an unread variable costs
        # nothing, while an option the entrypoint does not know is fatal to it —
        # its argument loop ends in `echo "Unknown arg"; usage 1`. --keep-alive
        # and --extra-user have no env spelling, so they must be argv; that is
        # safe because Dockerfile.qemu-runner's shim prefers the /src copy
        # mounted just below, which is THIS checkout's entrypoint.
        #
        # -d, and no --rm: the container has to outlive this script, and a
        # stopped device keeps its logs. --keep because the run dir holds the ssh
        # key the Studio logs in with and the qcow2 the guest is still writing to;
        # the entrypoint's cleanup deletes that overlay without it.
        err="$(docker run -d --privileged "${KVM_ARGS[@]}" \
            --name "${name}" \
            -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
            -e HOST_WORK="${WORK}" \
            -e HOST_ARTIFACTS="${ARTIFACTS}" \
            -e SSH_HOST_PORT="${port}" \
            -e CONTAINER_NAME="${name}" \
            "${mesh_args[@]}" \
            -p "127.0.0.1:${port}:${GUEST_SSH_PORT}" \
            -v "${REPO_DIR}":/src:ro \
            -v "${ARTIFACTS}":/artifacts:ro \
            -v "${WORK}":/work \
            "${IMAGE_TAG}" \
            --platform "${platform}" --role "${role}" --mode "${MODE}" \
            --img "/artifacts/$(basename "${img}")" \
            --mem "${MEM}" --smp "${SMP}" --timeout "${TIMEOUT}" \
            ${ASSERT_TIMEOUT:+--assert-timeout "${ASSERT_TIMEOUT}"} \
            --label "${label}" --keep --keep-alive \
            "${EXTRA_USER_ARGS[@]}" 2>&1)"
        rc=$?
        if [ "${rc}" -eq 0 ]; then
            # The claim STAYS for as long as the container does — it is what
            # keeps the next row, and a concurrent run, off this port. It is
            # dropped by --stop-device/--stop-all-devices, or reclaimed by
            # claim_port once the container it names is gone.
            chosen="${port}"
            DEV_PORTS_TAKEN+=("${port}")
            break
        fi
        release_port "${port}" "${name}"

        # A bind failure is the one outcome worth retrying: something took the
        # port between the probe and the bind. Anything else is a real error and
        # retrying it 100 times would only bury the message.
        docker rm -f "${name}" >/dev/null 2>&1 || true
        case "${err}" in
            *"already allocated"*|*"address already in use"*|*"port is already"*|*"bind for"*)
                warn "${label}: 127.0.0.1:${port} was taken between probe and bind; trying the next port"
                continue ;;
            *)
                warn "${label}: docker run failed: ${err}"
                return 1 ;;
        esac
    done < <(candidate_ports)

    if [ -z "${chosen}" ]; then
        warn "${label}: no free port in ${DEV_PORT_MIN}-${DEV_PORT_MAX} (all $((DEV_PORT_MAX - DEV_PORT_MIN + 1)) taken or claimed by a concurrent run)"
        return 1
    fi

    # `docker run -d` returns as soon as the container STARTS, so an entrypoint
    # that rejects its arguments exits a second later and the operator is left
    # holding a container id and no explanation — the container's output went to
    # `docker logs`, not to this terminal. Look again and quote it back.
    sleep 1
    if ! container_is_running "${name}"; then
        warn "${label}: container ${name} exited immediately. Its last words:"
        docker logs --tail 20 "${name}" 2>&1 | sed 's/^/    /' >&2
        release_port "${chosen}" "${name}"
        return 1
    fi
    if [ -n "${MESH_NET}" ]; then
        printf '%-24s %-32s %-22s %s\n' "${label}" "${name}" \
            "127.0.0.1:${chosen}" "${mesh_ip}/${mesh_plen} ${mesh_mac}"
    else
        printf '%-24s %-32s %s\n' "${label}" "${name}" "127.0.0.1:${chosen}"
    fi
    return 0
}

# ── Loop-device preflight ───────────────────────────────────────────────────
# WHAT WAS OBSERVED (2026-08-26). `--jobs 2` over rpi5: pki PASSED, backend and
# frontend both died in extract_kernel ("could not extract kernel_2712.img"),
# reproducibly, while the SAME rows passed when run one at a time. The images,
# the partition tables and the flock were all fine.
#
# ROOT CAUSE — the host boots with NO loop devices at all. This box has
# /sys/module/loop/parameters/max_loop = 0, so devtmpfs carries only
# /dev/loop-control until something issues LOOP_CTL_GET_FREE; the kernel then
# materialises /dev/loop0 ON THE HOST devtmpfs at that instant. A container's
# /dev is a CREATION-TIME SNAPSHOT of what the daemon assembles — a container
# started BEFORE that instant can never see the node, no matter how privileged
# it is, and `mount -o offset=` inside it has no loop device to claim. Confirmed
# by birth times: loop-control 10:02:33 (boot), loop0 11:27:36, and the backend
# container's image was ready at 11:27:35.94 — 1.06s too early.
#
# That also explains why the bug reads as flaky: pki went first, ITS mount is
# what created loop0, and every failing run leaves the node behind. After two
# failures the host had loop0 AND loop1 and the matrix "started passing" with
# nothing fixed. A harness that heals itself into green is the worst kind.
#
# THE FIX. Force the nodes to exist on the HOST before any row's container is
# created, so every later /dev snapshot contains them. `losetup -f` alone will
# NOT do it: it returns an already-free device without allocating a new one, so
# on a host with one free loop0 it creates nothing. The nodes only appear when
# the kernel is OBLIGED to allocate them — attach ${want} throwaway files
# SIMULTANEOUSLY (each attach holds its device, so the next -f must allocate a
# fresh one), then detach them all. The attach needs CAP_SYS_ADMIN, which this
# script does not have, so it happens in ONE short-lived privileged container
# with the host's /dev bind-mounted in: -v /dev:/dev is load-bearing, both so
# losetup can open the node it just asked for and so the nodes it creates land
# on the host devtmpfs rather than in a container-private tmpfs.
#
# Never fatal. A host that refuses is a host where the matrix MIGHT still work
# (one free node is enough when the mounts serialize on the flock), so this
# warns loudly, names what it could not do, and lets the run proceed.

# Where the loop nodes are counted. A TEST SEAM, and a necessary one: this host
# has already healed itself into having loop0+loop1, so a regression test that
# counted the REAL /dev would take the "already enough" early return and prove
# nothing at all. Production never sets it.
LOOP_DEV_DIR="${LOOP_DEV_DIR:-/dev}"
# Upper bound on the preflight. One row needs one loop device at a time and
# extract_kernel serializes the claim host-wide on ${WORK}/.loop-mount.lock, so
# a 20-row matrix does not need 20 nodes — this is headroom, not a quota.
LOOP_PREFLIGHT_MAX="${LOOP_PREFLIGHT_MAX:-8}"

loop_node_count() {
    local n
    local f
    n=0
    for f in "${LOOP_DEV_DIR}"/loop[0-9]*; do
        # An unmatched glob comes back as the literal pattern; -e rejects it.
        # -e rather than -b so the test seam can use a directory of plain files.
        [ -e "${f}" ] || continue
        # PARTITION NODES ARE NOT LOOP DEVICES. `loop[0-9]*` is loop + a digit +
        # ANYTHING, so it also matches /dev/loop0p1, and those are not
        # hypothetical here: extract_kernel's whole job is `losetup -P` on a
        # multi-partition golden image, and -P materialises loop0p1..p3 on the
        # HOST devtmpfs — the same devtmpfs-is-global fact this entire fix rests
        # on. Concurrent runs against one --work are supported, so run B would
        # count run A's partition nodes: a host with ONE loop device would look
        # like four, take the have>=want early return, print the reassuring
        # "already on the host", create nothing, and leave run B's rows to die in
        # extract_kernel exactly as before — the guard reporting success at
        # precisely the moment it is needed. Only `loop` followed by digits ALL
        # THE WAY is a device; loop10 counts, loop0p1 does not.
        case "${f##*/}" in loop*[!0-9]*) continue ;; esac
        n=$((n + 1))
    done
    printf '%s\n' "${n}"
}

ensure_loop_devices() { # ensure_loop_devices WANT
    local want
    local have
    local rc
    want="${1:-2}"
    [ "${want}" -ge 2 ] || want=2
    [ "${want}" -le "${LOOP_PREFLIGHT_MAX}" ] || want="${LOOP_PREFLIGHT_MAX}"
    have="$(loop_node_count)"
    if [ "${have}" -ge "${want}" ]; then
        info "loop preflight: ${have} loop node(s) already on the host (want ${want})"
        return 0
    fi
    step "Loop-device preflight: host shows ${have} loop node(s), forcing ${want}"
    if ! command -v docker >/dev/null; then
        warn "LOOP PREFLIGHT SKIPPED: no docker to run the privileged attach in — rows may fail in extract_kernel with 'could not extract kernel' on a host whose /dev has no loop node yet"
        return 0
    fi
    rc=0
    # `_` is argv[0] for the -c script, so "${want}" arrives as $1 inside it.
    docker run --rm --privileged -v /dev:/dev --entrypoint /bin/bash \
        "${IMAGE_TAG}" -c '
            set -u
            want="$1"; i=0; held=""
            while [ "${i}" -lt "${want}" ]; do
                f="$(mktemp)" || break
                truncate -s 1M "${f}" 2>/dev/null \
                    || dd if=/dev/zero of="${f}" bs=1M count=1 2>/dev/null \
                    || break
                # --show prints the node; each attach HOLDS it, which is what
                # obliges the kernel to allocate a fresh one on the next pass.
                d="$(losetup -f --show "${f}" 2>/dev/null)" || break
                [ -n "${d}" ] || break
                held="${held} ${d}"
                i=$((i + 1))
            done
            for d in ${held}; do losetup -d "${d}" 2>/dev/null || true; done
            [ "${i}" -ge "${want}" ]
        ' _ "${want}" >/dev/null 2>&1 || rc=$?
    # Believe the NODE COUNT, not the exit code. The container can fail on its
    # last attach having already created three nodes, and that is a success for
    # our purposes; it can also exit 0 in some future rewrite without having
    # created anything. Only the post-condition on the host says which happened.
    have="$(loop_node_count)"
    if [ "${have}" -ge "${want}" ]; then
        info "loop preflight: ${have} loop node(s) now visible on the host devtmpfs"
        return 0
    fi
    warn "LOOP PREFLIGHT INCOMPLETE: wanted ${want} loop node(s), host shows ${have} (privileged attach rc=${rc}). Rows may fail in extract_kernel with 'could not extract kernel' — a container created before a node exists can never see it. Workaround: 'sudo modprobe loop max_loop=${want}' or run the matrix with --jobs 1."
    return 0
}

# ── Keep-alive boot admission ────────────────────────────────────────────────
# `docker run -d` returns instantly, so the old keep-alive loop started EVERY
# row's guest within seconds of each other — on 2026-08-19 that was 10 VMs at
# once (3 pure-TCG rpi5 + 7 KVM x86) on one workstation, and both rpi5 rows
# then missed their ssh deadline ("Connection timed out during banner exchange"),
# which an ungated fan-out is the most plausible cause of. --jobs therefore
# gates ADMISSION here: at most ${JOBS} rows may be mid-boot at once, where
# "mid-boot" ends when the row's registry record appears (the entrypoint writes
# it in state "booting" the moment qemu launches — i.e. its decompress and
# kernel extraction, the expensive serialized part, are behind it) or when the
# row has been pending ${ADMIT_STAGGER}s, whichever is first. --jobs 0 is the
# old all-at-once behaviour, by request only.
#
# PENDING_SINCE maps a pending row's record path -> the epoch second it
# started. admission_poll is the single-step primitive (and the unit
# verdict_test.sh drives): drop every pending row that has resolved, then
# answer whether a new row may start.
declare -A PENDING_SINCE=()

admission_poll() {
    local now rec since
    now="$(date +%s)"
    for rec in "${!PENDING_SINCE[@]}"; do
        since="${PENDING_SINCE[${rec}]}"
        if [ -f "${rec}" ] || [ $((now - since)) -ge "${ADMIT_STAGGER}" ]; then
            unset "PENDING_SINCE[${rec}]"
        fi
    done
    [ "${#PENDING_SINCE[@]}" -lt "${JOBS}" ]
}

admission_wait() {
    [ "${JOBS}" -gt 0 ] || return 0     # --jobs 0: ungated, the old behaviour
    while ! admission_poll; do sleep 5; done
    return 0
}

# EVERY container of this run is created below this line — the keep-alive fan-out
# immediately after it and the plain one further down — which is the whole point
# of doing it here: /dev is snapshotted at container CREATION, so a node that
# does not exist by now is a node those containers can never see. Asked for one
# per row (capped), never fatal.
ensure_loop_devices "${#ROWS[@]}"

if ${KEEP_ALIVE}; then
    # Create the registry directory HOST-side, before any container can. Records
    # are written from inside the container; a directory owned by the invoking
    # user is what lets --stop-device replace one atomically (rename needs write
    # permission on the DIRECTORY, not on the file), and it saves the operator a
    # sudo to clean out ${WORK}.
    mkdir -p "${DEVICES_DIR}"
    step "Starting ${#ROWS[@]} device(s), ssh published on 127.0.0.1:${DEV_PORT_MIN}-${DEV_PORT_MAX}"
    # The shared L2 has to exist before the first container joins it: docker
    # would refuse `--network` for a network that is not there, and a fleet
    # half of which fell back to the default bridge is a fleet with two wires.
    if [ -n "${MESH_NET}" ]; then
        MESH_NET_NAME="$(mesh_network_name "$(basename "${ARTIFACTS}")")" \
            || die "cannot derive a mesh network name (no sha256sum and no python3 to hash the session with)"
        mesh_network_ensure "${MESH_NET_NAME}" \
            || die "could not create the shared mesh network ${MESH_NET_NAME} — the devices would have no L2 to meet on"
        info "mesh L2: docker bridge ${MESH_NET_NAME} carrying qemu socket netdev ${MESH_NET}; identities from ${IDENTITIES}"
    fi
    if [ "${JOBS}" -gt 0 ]; then
        info "boot admission: at most ${JOBS} device(s) mid-boot at once — a row admits the next when its registry record appears, or after ${ADMIT_STAGGER}s (--jobs 0 for the old ungated all-at-once fan-out)"
    else
        info "--jobs 0: starting all ${#ROWS[@]} devices at once, ungated"
    fi
    if [ -n "${MESH_NET}" ]; then
        printf '%-24s %-32s %-22s %s\n' "LABEL" "CONTAINER" "SSH" "MESH"
    else
        printf '%-24s %-32s %s\n' "LABEL" "CONTAINER" "SSH"
    fi
    STARTED=0; DEV_FAILED=0
    for r in "${ROWS[@]}"; do
        IFS='|' read -r _rank platform role env img <<< "${r}"
        admission_wait
        if start_device_row "${platform}" "${role}" "${img}"; then
            STARTED=$((STARTED+1))
            PENDING_SINCE["${DEVICES_DIR}/$(safe_label "${platform}/${role}").json"]="$(date +%s)"
        else
            DEV_FAILED=$((DEV_FAILED+1))
        fi
    done
    echo "----------------------------------------------------------------------"
    echo "${STARTED} device(s) starting, ${DEV_FAILED} failed to start"
    # Said plainly because it is the one surprise of this mode: the guests are
    # still booting. A record appears in state "booting" once its row's qemu
    # launches (decompress first — minutes for a fresh .img.xz) and flips to
    # "running" when the guest answers ssh; a device is only reachable then.
    echo "Devices are BOOTING; records land in ${DEVICES_DIR} as each row's qemu launches (state \"booting\"), and turn \"running\" when the guest answers ssh."
    echo "  $0 --work '${WORK}' --devices"
    echo "  $0 --work '${WORK}' --qmp <label> status"
    echo "  $0 --work '${WORK}' --stop-all-devices"
    [ "${DEV_FAILED}" -eq 0 ]
    exit $?
fi

# fan_out_rows — start every row in ${ROWS[@]}, at most ${JOBS} at a time, and
# leave the number of failed rows in ${FAILED}.
#
# A function so tests/qemu/loop_preflight_test.sh can drive the gate itself with
# a stub `docker` on PATH instead of inferring it from the source. ${FAILED} and
# ${running} are deliberately NOT `local`: the summary below reads ${FAILED}.
fan_out_rows() {
    local r
    local platform role env img _rank
    FAILED=0
    running=0
    for r in "${ROWS[@]}"; do
        IFS='|' read -r _rank platform role env img <<< "${r}"
        run_row "${platform}" "${role}" "${img}" &
        running=$((running+1))
        # `[ "${JOBS}" -gt 0 ] &&` IS THE FIX (2026-08-26). --jobs is documented
        # in the usage text as "0 = ungated, everything at once" and admission_wait
        # implements exactly that for the keep-alive lane. Here the bare
        # `running >= JOBS` test read 1 >= 0 as TRUE on the very first row, so it
        # waited for that row before starting the next: --jobs 0 FULLY SERIALIZED
        # the matrix — the exact opposite of what it promises, and the slowest
        # possible run of an option an operator reaches for to go faster. Nothing
        # complained, because a serialized matrix is merely slow, not red.
        if [ "${JOBS}" -gt 0 ] && [ "${running}" -ge "${JOBS}" ]; then
            wait -n 2>/dev/null || FAILED=$((FAILED+1))
            running=$((running-1))
        fi
    done
    while [ "${running}" -gt 0 ]; do
        wait -n 2>/dev/null || FAILED=$((FAILED+1))
        running=$((running-1))
    done
    return 0
}

if [ "${JOBS}" -gt 0 ]; then
    step "Running ${#ROWS[@]} row(s), ${JOBS} at a time"
else
    step "Running ${#ROWS[@]} row(s), all at once (--jobs 0: ungated)"
fi
# ${FAILED} and ${running} are set by fan_out_rows itself (they are globals on
# purpose — the summary below reads ${FAILED}).
fan_out_rows

# Second sweep, now that every container has been waited for. The pre-run sweep
# could not charge this run's fresh decompresses to the budget (they did not
# exist yet), so without this the disk those newly-created entries pushed over
# the cap is not handed back until the NEXT invocation, which may be days away —
# i.e. the space is held for exactly as long as it is useless. This run's own
# images are still spared, so an immediate re-run of the same rows stays cached.
cache_sweep

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

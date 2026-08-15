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
# so a developer's live hugmesh-local stack keeps :8080/:8443 uncontested.
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
        -h|--help)  usage 0 ;;
        *)          echo "Unknown arg: $1" >&2; usage 1 ;;
    esac
done

[ -n "${LABEL}" ] || LABEL="${PLATFORM}/${ROLE}"
RUN_DIR="${WORK}/runs/$(echo "${LABEL}" | tr '/+' '__')"
RESULT_DIR="${WORK}/results"
RESULT_JSON="${RESULT_DIR}/$(echo "${LABEL}" | tr '/+' '__').json"
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
# --kernel-from-img refuses to run unprivileged (launch-pi.sh:195). Inside this
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
    }
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

step "Booting ${PLATFORM}/${ROLE} (mem=${MEM}M smp=${SMP})"
case "${PLATFORM}" in
    rpi5)
        bash "${QEMU_DIR}/launch-pi.sh" \
            --img "${IMG}" --kernel "${KERNEL}" --keys-img "${KEYS_IMG}" \
            --run-dir "${LAUNCH_RUN_DIR}" --keep \
            --mem "${MEM}" --smp "${SMP}" \
            --ssh-port "${SSH_PORT}" --ui-port "${UI_PORT}" \
            --timeout "${TIMEOUT}" 2>&1 | tee "${RUN_DIR}/launch.log"
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
            --timeout "${TIMEOUT}" 2>&1 | tee "${RUN_DIR}/launch.log"
        lrc=${PIPESTATUS[0]}
        ;;
    *)
        bash "${QEMU_DIR}/launch-arm.sh" \
            --platform "${PLATFORM}" ${BOARD:+--board "${BOARD}"} \
            --img "${IMG}" --kernel "${KERNEL}" --keys-img "${KEYS_IMG}" \
            --run-dir "${LAUNCH_RUN_DIR}" --keep \
            --mem "${MEM}" --smp "${SMP}" \
            --ssh-port "${SSH_PORT}" --ui-port "${UI_PORT}" \
            --timeout "${TIMEOUT}" 2>&1 | tee "${RUN_DIR}/launch.log"
        lrc=${PIPESTATUS[0]}
        ;;
esac
[ "${lrc}" -eq 0 ] || die "launcher exited ${lrc} (see ${RUN_DIR}/launch.log)"

# NB: this REPLACES the earlier `trap reown EXIT`, so it must call reown itself —
# otherwise the run's artifacts stay root-owned on the host.
cleanup() {
    [ -f "${PIDFILE}" ] && kill "$(cat "${PIDFILE}")" 2>/dev/null || true
    ${KEEP} || rm -f "${RUN_DIR}"/launch/run.qcow2 2>/dev/null || true
    reown
}
trap cleanup EXIT

# ── Wait for the guest, then assert ─────────────────────────────────────────
SSH_OPTS=(-i "${SSHKEY}" -p "${SSH_PORT}"
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=5 -o LogLevel=ERROR)

step "Waiting up to ${TIMEOUT}s for guest SSH (${SSH_USER}@localhost:${SSH_PORT})"
deadline=$((SECONDS + TIMEOUT)); up=false
while [ "${SECONDS}" -lt "${deadline}" ]; do
    if [ -f "${PIDFILE}" ] && ! kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; then
        warn "QEMU exited early"; break
    fi
    if ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" true 2>/dev/null; then up=true; break; fi
    sleep 5
done

if ! ${up}; then
    echo "----- last 80 lines of console -----"
    tail -n 80 "${CONSOLE}" 2>/dev/null || true
    emit_result FAIL "guest did not reach SSH within ${TIMEOUT}s"
    exit 1
fi
info "SSH is up; running assertions"

step "Running assertions.sh in the guest (wall clock: ${ASSERT_TIMEOUT}s)"
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
set +e
timeout -k 30 "${ASSERT_TIMEOUT}" \
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" 'sudo bash -s' \
    < "${QEMU_DIR}/assertions.sh" 2>&1 | tee "${RUN_DIR}/assertions.log"
ARC=${PIPESTATUS[0]}
set -e

# '|| true' is load-bearing. The prologue is `set -uo pipefail` WITHOUT -e, but
# errexit is switched on three lines up — so under pipefail a log with no
# "RESULT: N passed" line makes this pipeline exit 1, the assignment inherits
# that status, and errexit KILLS THE SCRIPT RIGHT HERE: past the diagnostics,
# past both emit_result calls, past the `exit ${ARC}`. The container exits 1
# while ${WORK}/results/<label>.json still holds the PREVIOUS run's verdict,
# which the CLI summary and the Studio grid then report as this run's — a stale
# green for a row that never finished. Exactly the case this fires on is the one
# that matters: a guest that panics or drops SSH part-way through assertions.sh.
PASSED="$(grep -oE 'RESULT: [0-9]+ passed' "${RUN_DIR}/assertions.log" | grep -oE '[0-9]+' | head -1 || true)"
FAILED="$(grep -oE '[0-9]+ failed'          "${RUN_DIR}/assertions.log" | grep -oE '[0-9]+' | head -1 || true)"

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

step "Powering down guest"
# `sudo poweroff` legitimately tears the channel down under ssh's feet, so this
# call's own failure has always been ignored — but "ignored" is not "bounded",
# and a guest that accepts the command and then never closes the socket left it
# blocking forever. The qcow2 overlay is discarded by cleanup() either way.
timeout -k 5 60 ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" 'sudo poweroff' 2>/dev/null || true
sleep 3

if [ "${ARC}" -eq 0 ]; then
    info "${GREEN}${LABEL}: DEVICE TEST PASSED${RST} (${PASSED:-?} assertions)"
    emit_result PASS "all assertions passed" "${PASSED:-0}" "${FAILED:-0}"
elif [ "${ARC}" -eq 124 ] || [ "${ARC}" -eq 137 ]; then
    # timeout(1) reports 124 when SIGTERM was enough and 137 when it had to
    # escalate to SIGKILL. Neither can come from the guest here: assertions.sh
    # ends in `[ "${FAIL}" -eq 0 ]`, so its only exit codes are 0 and 1, and ssh
    # reports its own transport failures as 255. A row that hits this is a HANG,
    # not a failed assertion — say so, with whatever partial counts the log held,
    # rather than filing it under the generic "assertions failed".
    warn "${LABEL}: DEVICE TEST TIMED OUT after ${ASSERT_TIMEOUT}s (rc=${ARC})"
    emit_result FAIL "assertion ssh exceeded its ${ASSERT_TIMEOUT}s wall clock; killed" \
        "${PASSED:-0}" "${FAILED:-0}"
else
    warn "${LABEL}: DEVICE TEST FAILED (${FAILED:-?} assertions failed)"
    emit_result FAIL "assertions failed" "${PASSED:-0}" "${FAILED:-0}"
fi
exit "${ARC}"

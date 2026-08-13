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
        # --memlimit-threading: unbounded -T0 ballooned to ~7.2GiB RSS on a
        # high-core host and got SIGKILLed by the global OOM killer when two rows
        # decompressed concurrently (observed as x86_fe "decompress failed" with
        # an intact archive). Bounding the threaded decoder makes xz drop to
        # fewer threads instead of dying.
        xz -dc -T0 --memlimit-threading=2GiB "${IMG}" > "${RAW}.part" \
            || die "decompress failed"
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

    while read -r start size; do
        [ -n "${start}" ] && [ -n "${size}" ] || continue
        [ "${size}" -gt 0 ] 2>/dev/null || continue

        # Retry: loop devices are a HOST-WIDE resource shared by every runner
        # container, and mount's auto-allocation is find-free-then-claim, which
        # races when several rows start at once — the loser gets EBUSY. Without
        # this, running the matrix with --jobs >1 fails rows non-deterministically
        # while the same row passes when run alone.
        local attempt=0 mounted=false
        while [ "${attempt}" -lt 10 ]; do
            if mount -o "ro,offset=$((start * 512)),sizelimit=$((size * 512))" \
                     "${IMG}" "${mnt}" 2>/dev/null; then
                mounted=true; break
            fi
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
        step "Extracting kernel_2712.img from the golden image (losetup -P)"
        KERNEL="$(extract_kernel kernel_2712.img)" \
            || die "could not extract kernel_2712.img from ${IMG}"
        info "kernel: ${KERNEL}"
        ;;
    *)
        step "Extracting Image from the golden image (losetup -P)"
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
    p="$(grep -oE 'RESULT: [0-9]+ passed' "${RUN_DIR}/stage4.log" | grep -oE '[0-9]+' | head -1)"
    f="$(grep -oE '[0-9]+ failed'         "${RUN_DIR}/stage4.log" | grep -oE '[0-9]+' | head -1)"
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

cat > "${KEYS_SRC}/provision.json" <<EOF
{
  "version": 1,
  "hostname": "hugmesh-${ROLE}-qemu",
  "timezone": "UTC",
  "headscale": { "enabled": true, "config_file": "headscale/config.yaml" },
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

step "Running assertions.sh in the guest"
set +e
ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" 'sudo bash -s' \
    < "${QEMU_DIR}/assertions.sh" 2>&1 | tee "${RUN_DIR}/assertions.log"
ARC=${PIPESTATUS[0]}
set -e

PASSED="$(grep -oE 'RESULT: [0-9]+ passed' "${RUN_DIR}/assertions.log" | grep -oE '[0-9]+' | head -1)"
FAILED="$(grep -oE '[0-9]+ failed'          "${RUN_DIR}/assertions.log" | grep -oE '[0-9]+' | head -1)"

step "Powering down guest"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" 'sudo poweroff' 2>/dev/null || true
sleep 3

if [ "${ARC}" -eq 0 ]; then
    info "${GREEN}${LABEL}: DEVICE TEST PASSED${RST} (${PASSED:-?} assertions)"
    emit_result PASS "all assertions passed" "${PASSED:-0}" "${FAILED:-0}"
else
    warn "${LABEL}: DEVICE TEST FAILED (${FAILED:-?} assertions failed)"
    emit_result FAIL "assertions failed" "${PASSED:-0}" "${FAILED:-0}"
fi
exit "${ARC}"

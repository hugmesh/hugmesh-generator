#!/usr/bin/env bash
# windows-studio-e2e.sh — boot a MINIMAL Windows desktop under QEMU and prove the SHIPPED
# Windows launcher (studio/snapdragon-studio.bat -> `python -m snapdragon_studio %*`) runs
# there and emits a builder command. This is the Windows leg of the Studio's headless
# self-test: `--print-command` returns before app.py imports Qt, so it needs no display in
# the guest (the build-matrix GUI column relies on the same property).
#
# We cannot ship a Windows image, so the guest is OPERATOR-PROVIDED (see README.md,
# "Windows Studio .bat e2e"): a minimal Windows desktop qcow2 with Python 3.10+ on PATH,
# autologon, and a Startup / SetupComplete hook that runs `D:\run-selftest.bat` off the
# injected payload disk. The whole studio/ tree + a tiny guest runner are packed into a
# FAT "payload" disk (a stock Windows guest has no virtio-9p driver, so a shared FAT is the
# transport); the guest runs the .bat, writes a MARKER back to the FAT, and powers off; the
# host reads the marker back with mtools and decides pass/fail.
#
# DARK-GATED: the real boot needs WINDOWS_QEMU_IMAGE (+ qemu/OVMF/mtools). Without them the
# script SKIPS cleanly (exit 0) — mirroring the IMAGEGEN_KIND_E2E dark-e2e idiom.
#   --dry-run  pack + validate the payload FAT (and the guest runner) WITHOUT booting —
#              the arg-parse/packing half is testable with no qemu and no Windows image
#              (like verify-client.sh --dry-run). Needs only mtools + mkfs.vfat.
#
# Usage:  ./windows-studio-e2e.sh [--dry-run] [--timeout SECONDS] [--keep]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STUDIO_DIR="${REPO_DIR}/studio"

DRY_RUN=false
KEEP=false
TIMEOUT="${TIMEOUT:-600}"        # generous: a cold Windows boot + Python launch under TCG

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=true; shift ;;
        --timeout)  TIMEOUT="$2"; shift 2 ;;
        --keep)     KEEP=true; shift ;;
        -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

have() { command -v "$1" >/dev/null 2>&1; }

skip() { echo "SKIP: $*"; exit 0; }

# ── payload FAT: the whole studio/ tree + a guest runner the Startup hook launches ─────
GUEST_RUNNER='@echo off
REM run-selftest.bat — the payload-disk entrypoint the Windows guest Startup hook runs.
REM Exercises the SHIPPED launcher headlessly and round-trips a MARKER back through the
REM shared FAT so the host can verify it after power-off.
cd /d "%~dp0studio"
call snapdragon-studio.bat --print-command --backend native > MARKER.txt 2>&1
echo EXITCODE=%ERRORLEVEL%>> MARKER.txt
shutdown /s /t 0'

stage_payload() {   # $1 = staging dir
    local dest="$1"
    rm -rf "${dest}"; mkdir -p "${dest}/studio"
    # the launcher + the whole package (exclude caches / the venv / build junk); the
    # .bat runs `python -m snapdragon_studio`, so the package must be importable from
    # studio/ in the guest.
    rsync -a --exclude '__pycache__' --exclude '*.pyc' --exclude '.pytest_cache' \
        "${STUDIO_DIR}/snapdragon_studio" "${STUDIO_DIR}/snapdragon-studio.bat" \
        "${STUDIO_DIR}/requirements.txt" "${dest}/studio/"
    printf '%s\r\n' "${GUEST_RUNNER}" > "${dest}/run-selftest.bat"
    # fail LOUD if the runner or the shipped launcher lost their entrypoint before we ever boot.
    grep -q 'python -m snapdragon_studio' "${dest}/studio/snapdragon-studio.bat" \
        || { echo "payload validation FAILED: shipped .bat lost its entrypoint" >&2; exit 1; }
    grep -q 'snapdragon-studio.bat --print-command' "${dest}/run-selftest.bat" \
        || { echo "payload validation FAILED: guest runner lost its --print-command call" >&2; exit 1; }
}

pack_fat() {        # $1 = staging dir, $2 = output image
    local src="$1" out="$2"
    rm -f "${out}"
    truncate -s 256M "${out}"
    mkfs.vfat -F 32 -n WINSTUDIO "${out}" >/dev/null
    ( cd "${src}" && for e in *; do mcopy -s -i "${out}" "${e}" "::/"; done )
}

# ── --dry-run: pack + read the runner back off the FAT, no qemu, no Windows image ──────
if ${DRY_RUN}; then
    have mkfs.vfat && have mcopy || skip "install sys-fs/dosfstools + sys-fs/mtools to pack the payload FAT"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/winstudio-dry.XXXXXX")"
    trap '${KEEP} || rm -rf "${WORK}"' EXIT
    stage_payload "${WORK}/payload"
    pack_fat "${WORK}/payload" "${WORK}/payload.fat"
    # round-trip proof: the guest runner + the shipped launcher are really IN the FAT and
    # readable back (the same mtools read-back the post-boot verdict uses).
    mcopy -i "${WORK}/payload.fat" "::/run-selftest.bat" "${WORK}/rb-runner.bat"
    mcopy -i "${WORK}/payload.fat" "::/studio/snapdragon-studio.bat" "${WORK}/rb-launcher.bat"
    grep -q 'snapdragon-studio.bat --print-command' "${WORK}/rb-runner.bat"
    grep -q 'python -m snapdragon_studio' "${WORK}/rb-launcher.bat"
    echo "PASS (--dry-run): payload FAT packs and the guest runner + shipped launcher round-trip."
    exit 0
fi

# ── real boot: DARK GATE ───────────────────────────────────────────────────────────────
[ -n "${WINDOWS_QEMU_IMAGE:-}" ] && [ -r "${WINDOWS_QEMU_IMAGE:-}" ] \
    || skip "set WINDOWS_QEMU_IMAGE (+ qemu/OVMF) to run the Windows .bat e2e"
have qemu-system-x86_64 && have qemu-img \
    || skip "set WINDOWS_QEMU_IMAGE (+ qemu/OVMF) to run the Windows .bat e2e"
have mkfs.vfat && have mcopy \
    || skip "set WINDOWS_QEMU_IMAGE (+ qemu/OVMF) to run the Windows .bat e2e"

# OVMF discovery (same for-loop probe as qemu-boot-test.sh — a plain `ls | head` trips
# pipefail when a candidate is missing).
OVMF=""
for _c in /usr/share/edk2-ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE*.fd \
          /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/edk2/OvmfX64/OVMF_CODE.fd; do
    [ -f "${_c}" ] && { OVMF="${_c}"; break; }
done
[ -n "${OVMF}" ] || skip "set WINDOWS_QEMU_IMAGE (+ qemu/OVMF) to run the Windows .bat e2e"
OVMF_VARS_SRC=""
for _v in "$(dirname "${OVMF}")/OVMF_VARS.fd" /usr/share/edk2-ovmf/OVMF_VARS.fd \
          /usr/share/OVMF/OVMF_VARS*.fd /usr/share/edk2/OvmfX64/OVMF_VARS.fd; do
    [ -f "${_v}" ] && { OVMF_VARS_SRC="${_v}"; break; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/winstudio.XXXXXX")"
trap '${KEEP} || rm -rf "${WORK}"' EXIT
echo "  work dir: ${WORK}"

# stage + pack the payload FAT
stage_payload "${WORK}/payload"
pack_fat "${WORK}/payload" "${WORK}/payload.fat"

# never mutate the operator's base image — boot a throwaway qcow2 overlay on top of it.
OVERLAY="${WORK}/overlay.qcow2"
qemu-img create -f qcow2 -b "${WINDOWS_QEMU_IMAGE}" -F qcow2 "${OVERLAY}" >/dev/null 2>&1 \
    || qemu-img create -f qcow2 -b "${WINDOWS_QEMU_IMAGE}" "${OVERLAY}" >/dev/null
VARS="${WORK}/OVMF_VARS.fd"; cp "${OVMF_VARS_SRC:-${OVMF}}" "${VARS}"
SERIAL="${WORK}/serial.log"
VNC_PORT=$(( (RANDOM % 50) + 10 ))
KVM=(); [ -e /dev/kvm ] && KVM=(-enable-kvm -cpu host)

echo "  QEMU booting Windows guest; serial -> ${SERIAL}; VNC :${VNC_PORT} (connect to inspect)"
timeout "${TIMEOUT}" qemu-system-x86_64 \
    "${KVM[@]}" -m 4096 -smp 2 \
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF}" \
    -drive "if=pflash,format=raw,file=${VARS}" \
    -drive "file=${OVERLAY},if=virtio,format=qcow2" \
    -drive "file=${WORK}/payload.fat,format=raw,if=ide" \
    -display none -serial "file:${SERIAL}" -vnc ":${VNC_PORT}" -no-reboot \
    >/dev/null 2>&1 || true   # the guest self-shuts-down on completion (marker-then-verdict)

# ── read the MARKER back off the payload FAT (non-root mtools) and decide the verdict ──
MARKER="${WORK}/MARKER.txt"
echo "── verdict ──"
if ! mcopy -i "${WORK}/payload.fat" "::/studio/MARKER.txt" "${MARKER}" 2>/dev/null; then
    echo "INCONCLUSIVE: no MARKER.txt on the payload disk — the guest Startup hook may not"
    echo "  have run D:\\run-selftest.bat (autologon/Startup not configured?), or Windows"
    echo "  never reached the desktop within ${TIMEOUT}s. Inspect via VNC :${VNC_PORT} / the"
    echo "  serial log:"
    tail -n 25 "${SERIAL}" 2>/dev/null || true
    exit 1
fi
echo "── MARKER.txt ──"; cat "${MARKER}"
if grep -q 'EXITCODE=0' "${MARKER}" \
   && grep -qE 'build-(x86-host|rpi5|frite|jetson|orangepi5|orangepi-zero2)-stage4\.sh' "${MARKER}"; then
    echo "PASS: the shipped snapdragon-studio.bat ran in the Windows guest and emitted a builder command."
    exit 0
fi
echo "FAIL: MARKER present but missing EXITCODE=0 and/or a builder command."
echo "── serial log tail ──"; tail -n 25 "${SERIAL}" 2>/dev/null || true
exit 1

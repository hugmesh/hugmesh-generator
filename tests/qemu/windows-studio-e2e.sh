#!/usr/bin/env bash
# windows-studio-e2e.sh — boot a MINIMAL Windows desktop under QEMU and prove the SHIPPED
# Windows launcher (studio/hugmesh-studio.bat -> `python -m hugmesh_studio %*`) runs
# there and emits a builder command. This is the Windows leg of the Studio's headless
# self-test: `--print-command` returns before app.py imports Qt, so it needs no display in
# the guest (the build-matrix GUI column relies on the same property).
#
# We cannot ship a Windows image, so the guest is OPERATOR-PROVIDED (see README.md,
# "Windows Studio .bat e2e"): a minimal Windows desktop qcow2 with Python 3.10+ on PATH,
# autologon, and a Startup / SetupComplete hook that runs `D:\run-selftest.bat` off the
# injected payload disk. The whole studio/ tree + a tiny guest runner are packed into a
# FAT "payload" disk (a stock Windows guest has no virtio-9p driver, so a shared FAT is the
# transport); the guest runs the .bat, writes markers back to the FAT, and powers off; the
# host reads the markers back with mtools and decides pass/fail.
#
# The runner has TWO legs (both required for a PASS; no new guest prerequisites, so
# existing operator images keep passing):
#   1. DETECT leg: `hugmesh-studio.bat /detect > DETECT.txt` — the guided
#      bootstrapper's report mode (never prompts, never installs). Expected in the guest:
#      DETECT_EXITCODE=0, `DETECT python=found` (Python on PATH is part of the operator
#      image contract above), a DEFINITE pyside6/docker verdict either way (the minimal
#      image usually reports missing for both — a docker-equipped image must also pass),
#      and a winget line.
#   2. MARKER leg (the UNCHANGED #345 contract): `hugmesh-studio.bat --print-command
#      --backend native > MARKER.txt` must exit 0 and emit a builder command — proving
#      the bootstrapped .bat still honors the byte-compatible headless launch line.
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
REM Leg 1: the bootstrapper DETECT report (/detect never prompts, never installs).
REM Leg 2 (the unchanged #345 contract): exercise the SHIPPED launcher headlessly.
REM Both round-trip through the shared FAT so the host can verify after power-off.
REM Redirect-first form below is load-bearing: real cmd.exe parses a digit immediately
REM before a redirect operator as a stream handle even mid-token, so an echo whose
REM expanded tail is `...=0` followed directly by the append operator EATS the 0
REM (handle 0 gets redirected; the token never lands in the file). wine cmd does NOT
REM reproduce this, so only the static guards (stage_payload + test_bat_bootstrap.py)
REM catch a regression before a real boot.
cd /d "%~dp0studio"
call hugmesh-studio.bat /detect > DETECT.txt 2>&1
>> DETECT.txt echo DETECT_EXITCODE=%ERRORLEVEL%
call hugmesh-studio.bat --print-command --backend native > MARKER.txt 2>&1
>> MARKER.txt echo EXITCODE=%ERRORLEVEL%
shutdown /s /t 0'

stage_payload() {   # $1 = staging dir
    local dest="$1"
    rm -rf "${dest}"; mkdir -p "${dest}/studio"
    # the launcher + the whole package (exclude caches / the venv / build junk); the
    # .bat runs `python -m hugmesh_studio`, so the package must be importable from
    # studio/ in the guest.
    rsync -a --exclude '__pycache__' --exclude '*.pyc' --exclude '.pytest_cache' \
        "${STUDIO_DIR}/hugmesh_studio" "${STUDIO_DIR}/hugmesh-studio.bat" \
        "${STUDIO_DIR}/requirements.txt" "${dest}/studio/"
    # every line CRLF: cmd is CRLF-native and the shipped .bat is goto-heavy (cmd's label
    # scanner breaks on LF), so the runner is written the same way for consistency.
    printf '%s\n' "${GUEST_RUNNER}" | sed 's/$/\r/' > "${dest}/run-selftest.bat"
    # fail LOUD if the runner or the shipped launcher lost their entrypoint before we ever boot.
    grep -q 'python -m hugmesh_studio' "${dest}/studio/hugmesh-studio.bat" \
        || { echo "payload validation FAILED: shipped .bat lost its entrypoint" >&2; exit 1; }
    grep -q 'hugmesh-studio.bat --print-command' "${dest}/run-selftest.bat" \
        || { echo "payload validation FAILED: guest runner lost its --print-command call" >&2; exit 1; }
    # the bootstrap-detect leg: runner calls /detect; the shipped .bat still carries the
    # DETECT vocabulary and the pinned winget IDs (the same lines test_bat_bootstrap.py pins).
    grep -q 'hugmesh-studio.bat /detect' "${dest}/run-selftest.bat" \
        || { echo "payload validation FAILED: guest runner lost its /detect leg" >&2; exit 1; }
    grep -q 'DETECT python=' "${dest}/studio/hugmesh-studio.bat" \
        || { echo "payload validation FAILED: shipped .bat lost its DETECT report" >&2; exit 1; }
    grep -q 'set "WINGET_PYTHON_ID=Python.Python.3.12"' "${dest}/studio/hugmesh-studio.bat" \
        || { echo "payload validation FAILED: shipped .bat lost its pinned Python winget ID" >&2; exit 1; }
    grep -q 'set "WINGET_DOCKER_ID=Docker.DockerDesktop"' "${dest}/studio/hugmesh-studio.bat" \
        || { echo "payload validation FAILED: shipped .bat lost its pinned Docker winget ID" >&2; exit 1; }
    # CRLF guard: an LF-normalized .bat would boot but die at the first goto label.
    grep -qU $'\r' "${dest}/studio/hugmesh-studio.bat" \
        || { echo "payload validation FAILED: shipped .bat is not CRLF (goto labels would break)" >&2; exit 1; }
    # digit-eating-redirect guard: `...%ERRORLEVEL%>> file` loses the digit on REAL
    # cmd.exe (digit-before->> parses as a stream handle); wine's cmd does not reproduce
    # the quirk, so this static check is the only pre-boot net. Redirect-first form
    # (`>> file echo ...%ERRORLEVEL%`) is required in the guest runner.
    if grep -q '%>' "${dest}/run-selftest.bat"; then
        echo "payload validation FAILED: guest runner has a '%>' redirect (real cmd eats the expanded digit; use the redirect-first form)" >&2
        exit 1
    fi
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
    mcopy -i "${WORK}/payload.fat" "::/studio/hugmesh-studio.bat" "${WORK}/rb-launcher.bat"
    grep -q 'hugmesh-studio.bat --print-command' "${WORK}/rb-runner.bat"
    grep -q 'python -m hugmesh_studio' "${WORK}/rb-launcher.bat"
    # the detect leg survives the FAT round-trip too (same greps as stage_payload, read
    # back off the packed image — the packing half of the new leg, zero qemu needed).
    grep -q 'hugmesh-studio.bat /detect' "${WORK}/rb-runner.bat"
    grep -q 'DETECT python=' "${WORK}/rb-launcher.bat"
    grep -q 'WINGET_PYTHON_ID=Python.Python.3.12' "${WORK}/rb-launcher.bat"
    grep -q 'WINGET_DOCKER_ID=Docker.DockerDesktop' "${WORK}/rb-launcher.bat"
    echo "PASS (--dry-run): payload FAT packs; the guest runner (detect + marker legs) and"
    echo "  the shipped launcher (entrypoint, DETECT report, pinned winget IDs) round-trip."
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
if ! grep -q 'EXITCODE=0' "${MARKER}" \
   || ! grep -qE 'build-(x86-host|rpi5|frite|jetson|orangepi5|orangepi-zero2|orangepi-zero2w|orangepi-zero3|orangepi3-lts|orangepi4-lts)-stage4\.sh' "${MARKER}"; then
    echo "FAIL: MARKER present but missing EXITCODE=0 and/or a builder command."
    echo "── serial log tail ──"; tail -n 25 "${SERIAL}" 2>/dev/null || true
    exit 1
fi

# ── detect leg: the bootstrapper's /detect report is part of the pass now ──────────────
DETECT="${WORK}/DETECT.txt"
if ! mcopy -i "${WORK}/payload.fat" "::/studio/DETECT.txt" "${DETECT}" 2>/dev/null; then
    echo "FAIL: MARKER passed but DETECT.txt is missing from the payload disk — the guest"
    echo "  runner's /detect leg did not run (it executes BEFORE the marker leg, so this"
    echo "  points at the shipped .bat crashing on /detect, not at the guest hook)."
    exit 1
fi
echo "── DETECT.txt ──"; cat "${DETECT}"
DETECT_FAIL=""
grep -q  'DETECT_EXITCODE=0'                "${DETECT}" || DETECT_FAIL="${DETECT_FAIL} DETECT_EXITCODE=0"
grep -q  'DETECT python=found'              "${DETECT}" || DETECT_FAIL="${DETECT_FAIL} python=found"
grep -qE 'DETECT pyside6=(found|missing)'   "${DETECT}" || DETECT_FAIL="${DETECT_FAIL} pyside6-verdict"
grep -qE 'DETECT docker=(found|missing)'    "${DETECT}" || DETECT_FAIL="${DETECT_FAIL} docker-verdict"
grep -q  'DETECT winget='                   "${DETECT}" || DETECT_FAIL="${DETECT_FAIL} winget-verdict"
if [ -n "${DETECT_FAIL}" ]; then
    echo "FAIL: the launcher ran but the /detect report is missing:${DETECT_FAIL}"
    echo "  (python=found is an operator-image contract — Python 3.10+ on PATH; pyside6/"
    echo "  docker only need a DEFINITE verdict either way — missing is fine on a minimal image.)"
    exit 1
fi
echo "PASS: the shipped hugmesh-studio.bat ran in the Windows guest — /detect reported"
echo "  correctly AND the headless launch emitted a builder command."
exit 0

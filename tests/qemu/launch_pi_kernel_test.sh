#!/usr/bin/env bash
# launch_pi_kernel_test.sh — HERMETIC tests for launch-pi.sh --kernel-from-img.
# Boots nothing, starts no container, needs no root and touches no loop device:
# it builds a REAL DOS-partitioned FAT disk with mformat + mcopy, sed-extracts
# the two extractor functions out of launch-pi.sh (the devices_test.sh /
# verdict_test.sh pattern), and drives the whole launcher with stubs on PATH.
#
#   bash tests/qemu/launch_pi_kernel_test.sh
#
# WHY THIS FILE EXISTS (2026-08-26). launch-pi.sh's --kernel-from-img opened with
#
#     [ "$(id -u)" -eq 0 ] || die "--kernel-from-img needs root (losetup -P)"
#     LOOP="$(losetup -P --show -f "${IMG}")"
#     mount "${LOOP}p1" ...
#
# which can NEVER work inside the runner container — not even as root, which is
# what that refusal message implied was sufficient. `losetup -P` makes the KERNEL
# scan the partition table and create /dev/loopNpM on the HOST devtmpfs; a
# container's /dev is a creation-time SNAPSHOT of the host's nodes, so a node
# born after the container started is invisible inside it and the mount ENOENTs.
# The launcher then reported that as "could not mount image boot partition" — an
# image defect that was never in the image. docker-entrypoint.sh has carried a
# comment stating this directly above its own extractor for as long as that
# extractor existed; the launcher never got the memo.
#
# WHAT THE STUBS PROVE. losetup / mount / umount are stubbed on PATH to append to
# a witness file and exit non-zero with a loud message, so ANY use of the loop
# path is a hard test failure rather than a slow fallback that quietly works on a
# developer box. `id` is stubbed to report uid 1000 as well: the CI container job
# runs as root, and without that stub a root CI could satisfy the privileged
# fallback and hide a regression that a real unprivileged user would hit. With
# both stubs in place, the privileged pass is provably unreachable and every
# extraction below is the mountless mtools pass.
#
# WHAT IT DOES NOT PROVE. Nothing here boots a guest or runs QEMU: qemu-img and
# qemu-system-aarch64 are stubs, so this says nothing about whether the extracted
# kernel actually boots — only that the bytes handed to -kernel are the bytes on
# the image's FAT partition. It also does not exercise a real container.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER="${HERE}/launch-pi.sh"
[ -f "${LAUNCHER}" ] || { echo "cannot find ${LAUNCHER}" >&2; exit 2; }

PASS=0; FAIL=0
_ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
_bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
eq() { if [ "$1" = "$2" ]; then _ok "$3"; else _bad "$3 (got '$1', want '$2')"; fi; }

# NO SILENT SKIPS. mtools is the whole point of the fix; without it there is
# nothing to test and exiting 0 would look exactly like a pass.
MISSING=""
for t in mformat mcopy minfo sfdisk cmp; do
    command -v "${t}" >/dev/null 2>&1 || MISSING="${MISSING} ${t}"
done
if [ -n "${MISSING}" ]; then
    echo "SKIPPING LOUDLY — launch_pi_kernel_test.sh cannot run: missing${MISSING}." >&2
    echo "  mtools (mformat/mcopy/minfo) + util-linux (sfdisk) + diffutils (cmp) are" >&2
    echo "  required to build the fixture image this suite asserts against." >&2
    exit 2
fi

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
BIN="${TMP}/bin"; mkdir -p "${BIN}"
WITNESS="${TMP}/loop-path-used.txt"; : > "${WITNESS}"

# ── Stubs ───────────────────────────────────────────────────────────────────
# Fail LOUDLY, and leave a trace: a test that merely "still passed" while the
# loop path ran would not be measuring the fix at all.
for s in losetup mount umount; do
    cat > "${BIN}/${s}" <<STUB
#!/bin/sh
echo "LOOP-PATH-USED: ${s} \$*" >> "\${LOOP_WITNESS}"
echo "STUB ${s}: the loop/mount path must not run — it cannot work in a container" >&2
exit 97
STUB
    chmod +x "${BIN}/${s}"
done
# uid 1000 no matter who really runs this (the CI container job is root).
cat > "${BIN}/id" <<'STUB'
#!/bin/sh
[ "${1:-}" = "-u" ] && { echo 1000; exit 0; }
# Delegate anything else to the real binary BY PATH, never by name: calling `id`
# here would re-enter this stub. alpine (the CI image) keeps busybox's id in
# /usr/bin, Gentoo in /usr/bin too, but /bin is checked for older layouts.
for real in /usr/bin/id /bin/id; do
    [ -x "${real}" ] && exec "${real}" "$@"
done
echo "id stub: no real id binary found" >&2
exit 2
STUB
chmod +x "${BIN}/id"
# qemu-img: 'create ... OUT' materialises OUT; 'resize' is a no-op.
cat > "${BIN}/qemu-img" <<'STUB'
#!/bin/sh
case "${1:-}" in
  create) shift; out=""; for a in "$@"; do out="$a"; done; : > "${out}" ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "${BIN}/qemu-img"
# qemu-system-aarch64: record argv one arg per line, boot nothing.
cat > "${BIN}/qemu-system-aarch64" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" > "${QEMU_ARGV}"
exit 0
STUB
chmod +x "${BIN}/qemu-system-aarch64"

# ── Fixture: a real DOS-partitioned disk with a FAT32 boot partition ────────
# p1 = FAT (type c) at sector 2048, p2 = "linux" (type 83) left as raw zeros so
# minfo genuinely rejects it — the same shape as a Pi image (p1 boot, p2 ext4).
KSRC="${TMP}/kernel-source.bin"
head -c 200000 /dev/urandom > "${KSRC}"

mk_img() { # mk_img OUT DESTPATH SRC [swap]   DESTPATH e.g. ::kernel_2712.img
    local out; out="$1"
    local dest; dest="$2"
    local src; src="$3"
    local swap; swap="${4:-no}"
    local p1s p2s off
    rm -f "${out}"; truncate -s 96M "${out}"
    if [ "${swap}" = "swap" ]; then
        # FAT is the SECOND partition: proves the scan does not assume p1.
        p1s=2048; p2s=67584; off=$((p2s * 512))
        printf 'label: dos\nunit: sectors\n\nstart=%d, size=65536, type=83\nstart=%d, size=65536, type=c\n' \
            "${p1s}" "${p2s}" | sfdisk "${out}" >/dev/null 2>&1
    else
        p1s=2048; off=$((p1s * 512))
        printf 'label: dos\nunit: sectors\n\nstart=%d, size=65536, type=c, bootable\nstart=67584, size=65536, type=83\n' \
            "${p1s}" | sfdisk "${out}" >/dev/null 2>&1
    fi
    MTOOLS_SKIP_CHECK=1 mformat -i "${out}@@${off}" -T 65536 -h 64 -s 32 -v RPI_BOOT :: \
        || { echo "fixture mformat failed for ${out}" >&2; exit 2; }
    case "${dest}" in
        ::boot/*) MTOOLS_SKIP_CHECK=1 mmd -i "${out}@@${off}" ::boot || exit 2 ;;
    esac
    [ "${dest}" = "NONE" ] && return 0
    MTOOLS_SKIP_CHECK=1 mcopy -n -i "${out}@@${off}" "${src}" "${dest}" \
        || { echo "fixture mcopy failed for ${out} ${dest}" >&2; exit 2; }
    return 0
}

IMG_OK="${TMP}/ok.img";       mk_img "${IMG_OK}"    '::kernel_2712.img'      "${KSRC}"
IMG_SUB="${TMP}/sub.img";     mk_img "${IMG_SUB}"   '::boot/kernel_2712.img' "${KSRC}"
IMG_SWAP="${TMP}/swap.img";   mk_img "${IMG_SWAP}"  '::kernel_2712.img'      "${KSRC}" swap
IMG_EMPTY="${TMP}/empty.img"; mk_img "${IMG_EMPTY}" 'NONE'                   "${KSRC}"
: > "${TMP}/zero.bin"
IMG_ZERO="${TMP}/zero.img";   mk_img "${IMG_ZERO}"  '::kernel_2712.img'      "${TMP}/zero.bin"

# ══ 1. the extractor itself, sed-extracted and driven directly ══════════════
echo "extract_kernel_mtools — unprivileged, mountless, byte-exact"
FNS="${TMP}/fns.sh"; : > "${FNS}"
extract_fn() { # extract_fn NAME
    sed -n "/^$1() {/,/^}/p" "${LAUNCHER}" >> "${FNS}"
    grep -q "^$1() {" "${FNS}" \
        || { echo "could not sed-extract $1 from ${LAUNCHER}" >&2; exit 2; }
}
extract_fn partition_offsets
extract_fn extract_kernel_mtools

run_extract() { # run_extract IMGFILE -> prints the returned path (empty on failure)
    local img; img="$1"
    local rdir; rdir="${TMP}/xrun"
    rm -rf "${rdir}"; mkdir -p "${rdir}"
    ( set -euo pipefail
      PATH="${BIN}:${PATH}"; export PATH
      LOOP_WITNESS="${WITNESS}"; export LOOP_WITNESS
      IMG="${img}"; RUN_DIR="${rdir}"
      # shellcheck disable=SC1090
      source "${FNS}"
      extract_kernel_mtools "kernel_2712.img" || true
    )
}

got="$(run_extract "${IMG_OK}")"
if [ -n "${got}" ] && [ -f "${got}" ]; then
    _ok "a FAT p1 image yields a kernel path (${got##*/})"
    if cmp -s "${KSRC}" "${got}"; then
        _ok "the extracted kernel is BYTE-IDENTICAL to the one on the FAT partition"
    else
        _bad "the extracted kernel differs from the source ($(wc -c < "${KSRC}") vs $(wc -c < "${got}") bytes)"
    fi
else
    _bad "no kernel extracted from the FAT p1 fixture (got '${got}')"
fi

got="$(run_extract "${IMG_SUB}")"
if [ -n "${got}" ] && cmp -s "${KSRC}" "${got}"; then
    _ok "::boot/kernel_2712.img (kernel in a subdirectory) is found too"
else
    _bad "the ::boot/ candidate path was not searched (got '${got}')"
fi

got="$(run_extract "${IMG_SWAP}")"
if [ -n "${got}" ] && cmp -s "${KSRC}" "${got}"; then
    _ok "a non-FAT p1 is skipped and the FAT p2 is still scanned"
else
    _bad "the scan gave up on the first non-FAT partition (got '${got}')"
fi

# THE zero-byte rule. mcopy "succeeds" on an empty file; QEMU accepts an empty
# -kernel and then simply never boots, so a miss reported here is a one-second
# failure instead of an unexplained TCG boot timeout ~40 minutes later.
got="$(run_extract "${IMG_ZERO}")"
eq "${got}" "" "a ZERO-BYTE ::kernel_2712.img is rejected, not returned as a hit"
if [ -e "${TMP}/xrun/kernel_2712.img" ]; then
    _bad "the rejected zero-byte file was left in RUN_DIR for a later pass to find"
else
    _ok "…and the zero-byte artefact is removed rather than left behind"
fi

got="$(run_extract "${IMG_EMPTY}")"
eq "${got}" "" "an image with a FAT partition but no kernel returns a clean miss"

# The failure mode the zero-byte guard CANNOT see: mcopy dying part way through
# leaves a TRUNCATED but non-empty file, and `mcopy ... || continue` never looks
# at it. Only the cleanup on the miss path stops that being handed to the next
# reader as a kernel. Stubbed, because provoking a real partial mcopy would mean
# corrupting a FAT mid-copy — the behaviour under test is what the function does
# with a non-zero mcopy that already wrote bytes, not how mcopy fails.
MCBIN="${TMP}/mcbin"; mkdir -p "${MCBIN}"
cat > "${MCBIN}/mcopy" <<'STUB'
#!/bin/sh
# Emulate a copy interrupted after the first block: write, then fail.
dest=""
for a in "$@"; do dest="$a"; done
printf 'PARTIALPARTIALPARTIAL' > "${dest}"
exit 1
STUB
chmod +x "${MCBIN}/mcopy"
rdir="${TMP}/partial"; rm -rf "${rdir}"; mkdir -p "${rdir}"
got="$( set -uo pipefail
        PATH="${MCBIN}:${BIN}:${PATH}"; export PATH
        LOOP_WITNESS="${WITNESS}"; export LOOP_WITNESS
        IMG="${IMG_OK}"; RUN_DIR="${rdir}"
        # shellcheck disable=SC1090
        source "${FNS}"
        extract_kernel_mtools "kernel_2712.img" || true )"
eq "${got}" "" "an mcopy that FAILS after writing bytes is a miss, not a hit"
if [ -e "${rdir}/kernel_2712.img" ]; then
    _bad "the truncated file mcopy left behind is still in RUN_DIR ($(wc -c < "${rdir}/kernel_2712.img") bytes)"
else
    _ok "…and the truncated leftover is cleaned up on the miss path"
fi

# ══ 2. end to end: the launcher itself, as a non-root user ═════════════════
echo
echo "launch-pi.sh --kernel-from-img — end to end, uid 1000, loop tools stubbed to fail"

# NB: this sets LAST_RC / LAST_OUT rather than printing, and is therefore called
# WITHOUT a command substitution. A `$(run_launcher ...)` wrapper runs the whole
# function in a subshell, where the exit code it records dies with that subshell —
# the first version of this file did exactly that and tripped over an unbound
# LAST_RC one line later.
LAST_RC=0; LAST_OUT=""
run_launcher() { # run_launcher IMGFILE RUNDIRNAME -> sets LAST_RC, LAST_OUT
    local img; img="$1"
    local name; name="$2"
    local rdir; rdir="${TMP}/${name}"
    rm -rf "${rdir}"
    QEMU_ARGV_FILE="${TMP}/${name}.argv"; rm -f "${QEMU_ARGV_FILE}"
    PATH="${BIN}:${PATH}" LOOP_WITNESS="${WITNESS}" QEMU_ARGV="${QEMU_ARGV_FILE}" \
        bash "${LAUNCHER}" --img "${img}" --kernel-from-img \
             --run-dir "${rdir}" --work-dir "${TMP}/nowhere" > "${TMP}/${name}.out" 2>&1
    LAST_RC=$?
    LAST_OUT="$(cat "${TMP}/${name}.out")"
}

run_launcher "${IMG_OK}" e2e; out="${LAST_OUT}"
eq "${LAST_RC}" "0" "the launcher exits 0 for a normal Pi image WITHOUT root"
if [ -f "${TMP}/e2e.argv" ]; then
    _ok "QEMU was invoked (argv recorded)"
    # The value of -kernel is the line AFTER the '-kernel' line in the argv dump.
    kpath="$(awk '/^-kernel$/{getline; print; exit}' "${TMP}/e2e.argv")"
    if [ -n "${kpath}" ] && [ -f "${kpath}" ]; then
        _ok "-kernel points at a real file (${kpath##*/})"
        if cmp -s "${KSRC}" "${kpath}"; then
            _ok "the bytes handed to -kernel are the bytes on the image's FAT partition"
        else
            _bad "-kernel got the wrong bytes (differs from the fixture kernel)"
        fi
    else
        _bad "-kernel argument missing or not a file (got '${kpath}')"
    fi
else
    _bad "QEMU was never invoked — the launcher died before boot: ${out}"
fi
case "${out}" in
    *"needs root"*) _bad "the launcher still refuses --kernel-from-img with a 'needs root' message" ;;
    *)              _ok  "no 'needs root' refusal on the FAT path" ;;
esac

# The zero-byte candidate must never reach QEMU.
run_launcher "${IMG_ZERO}" zero; out="${LAST_OUT}"
if [ "${LAST_RC}" -ne 0 ]; then
    _ok "a zero-byte kernel candidate makes the launcher FAIL rather than boot"
else
    _bad "the launcher exited 0 on a zero-byte kernel candidate"
fi
if [ -f "${TMP}/zero.argv" ]; then
    _bad "QEMU was launched with the zero-byte kernel (an empty -kernel is a silent boot hang)"
else
    _ok "…and QEMU was never invoked with it"
fi

# The refusal must name the CONTAINER case, not just 'needs root'.
run_launcher "${IMG_EMPTY}" norm; out="${LAST_OUT}"
if [ "${LAST_RC}" -ne 0 ]; then
    _ok "an image with no kernel at all is refused"
else
    _bad "an image with no kernel at all was accepted"
fi
case "${out}" in
    *"IN A CONTAINER"*) _ok "the refusal names the CONTAINER case explicitly" ;;
    *) _bad "the refusal does not mention containers at all: ${out}" ;;
esac
case "${out}" in
    *"CAP_SYS_ADMIN"*|*"creation-time snapshot"*)
        _ok "…and says WHY a container cannot reach the privileged fallback" ;;
    *) _bad "the refusal names containers but not why root alone does not help there" ;;
esac

# ══ 3. the loop path never ran ═════════════════════════════════════════════
echo
echo "loop/mount stubs"
if [ -s "${WITNESS}" ]; then
    _bad "the loop/mount path RAN: $(tr '\n' ';' < "${WITNESS}")"
else
    _ok "losetup / mount / umount were never invoked by any of the runs above"
fi

# ══ 4. wiring: the loop idiom is gone from EXECUTABLE code ═════════════════
# COMMENT-STRIPPED. The fix deliberately keeps a long prose note that quotes the
# old `losetup -P` / ${LOOP}p1 lines verbatim, so a naive grep over the raw file
# would report the defect as still present — prose naming a token has inverted
# exactly this kind of check in this repo before. Only FULL-LINE comments are
# stripped (a line whose first non-blank character is '#'); trailing-# stripping
# would mangle ${#QMP_SOCK} and is not needed, because the note is a full-line
# block. The stripped text is written to a FILE and grepped as a file argument:
# `| grep -q` under pipefail reports a FOUND match as a failure when -q's early
# exit SIGPIPEs the upstream stage.
echo
echo "wiring (comments stripped)"
CODE="${TMP}/launch-pi.code"
sed -e '/^[[:space:]]*#/d' "${LAUNCHER}" > "${CODE}"
if grep -q 'losetup' "${CODE}"; then
    _bad "losetup is still called in executable code: $(grep -n losetup "${CODE}" | head -2 | tr '\n' ' ')"
else
    _ok "no losetup call survives in executable code"
fi
if grep -qE '\$\{LOOP\}p[0-9]|/dev/loop[0-9]*p[0-9]' "${CODE}"; then
    _bad "a per-partition loop node (\${LOOP}pN) is still referenced in executable code"
else
    _ok "no per-partition loop device node is referenced in executable code"
fi
if grep -q 'mcopy -n -i' "${CODE}"; then
    _ok "the mtools byte-offset idiom is present in executable code"
else
    _bad "the mtools idiom is missing — only a comment mentions it"
fi
if grep -qE 'id -u.*\|\|[[:space:]]*die' "${CODE}"; then
    _bad "a bare 'id -u ... || die' root gate is back on the extraction path"
else
    _ok "no unconditional uid-0 gate guards --kernel-from-img"
fi

echo
echo "== RESULT: ${PASS} passed, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ]

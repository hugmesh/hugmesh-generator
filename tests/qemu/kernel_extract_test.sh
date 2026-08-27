#!/usr/bin/env bash
# kernel_extract_test.sh — HERMETIC tests for extract_kernel().
#
#   bash tests/qemu/kernel_extract_test.sh
#
# Boots nothing, starts no container, needs NO ROOT: extract_kernel /
# extract_kernel_mtools / partition_offsets are sed-extracted from
# docker-entrypoint.sh (the verdict_test.sh pattern) and driven against a real
# 40 MB DOS-partitioned disk built here with mformat + mcopy.
#
# WHY THIS FILE EXISTS. On 2026-08-26 `run-qemu-docker.sh --platform rpi5
# --jobs 2` reported rpi5/backend and rpi5/frontend as ERROR "could not extract
# kernel_2712.img" while rpi5/pki — which ran alone in the third slot — passed
# 44 assertions. All three images were fine: each held an identical 31033856-byte
# kernel_2712.img on an identically laid out FAT32 partition, and each of the two
# "broken" ones passed 42 and 41 assertions when re-run on its own. The harness
# was grading how many rows shared the host.
#
# The cause was the span of the loop-mount critical section. `mount -o loop`
# claims a loop device for the LIFETIME of the mount, but the code released the
# flock the instant the mount call returned, so a second container was admitted
# while the first still held the device. That only survives where the kernel can
# hand out another loop device, and inside a container it usually cannot: with
# /sys/module/loop/parameters/max_loop = 0 each new /dev/loopN is created on the
# HOST devtmpfs, which the container's /dev never sees. A host whose only node is
# /dev/loop0 therefore has exactly one claim to give, and the loser fails.
#
# The fix has two halves and this file pins BOTH:
#   1. an mtools first pass that reads the FAT partition at a byte offset and so
#      needs no loop device, no mount, no privilege and no lock whatsoever;
#   2. the loop-mount fallback now holds the lock across mount -> copy -> umount.
# Test 2 is the one that matters: it fails a `mount` stub loudly, so if the
# mtools pass is ever removed or stops matching, the suite goes red instead of
# silently going back to being single-threaded.
set -uo pipefail

# Every grep that reads from a PIPE below drains with >/dev/null rather than
# using -q. `grep -q` exits the moment it matches, which SIGPIPEs the upstream
# stage; combined with the pipefail above that reports a FOUND match as a FAILED
# pipeline. It is load-bearing, not style: test 7 passed against the host's GNU
# grep and failed against alpine's busybox grep, which is the worst shape a
# guard can have. (grep -q reading a FILE argument has no upstream and is fine.)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="${HERE}/docker-entrypoint.sh"
[ -f "${ENTRYPOINT}" ] || { echo "cannot find ${ENTRYPOINT}" >&2; exit 2; }

for t in mformat mcopy minfo sfdisk; do
    command -v "${t}" >/dev/null 2>&1 || {
        # Not a silent skip: an environment without mtools cannot run the code
        # path this file exists to protect, and saying "ok" there is exactly the
        # vacuous pass the harness has been bitten by before.
        echo "SKIP-FATAL: ${t} not on PATH — these tests cannot verify anything" >&2
        exit 2
    }
done

PASS=0; FAIL=0
_ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
_bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

extract() { # extract FILE FUNCNAME OUT — die if the function is not found
    sed -n "/^$2() {/,/^}/p" "$1" >> "$3"
    grep -q "^$2() {" "$3" || { echo "could not extract $2 from $1" >&2; exit 2; }
}

# ── the unit under test, lifted verbatim ───────────────────────────────────
LIB="${TMP}/lib.sh"
: > "${LIB}"
extract "${ENTRYPOINT}" partition_offsets      "${LIB}"
extract "${ENTRYPOINT}" extract_kernel_mtools  "${LIB}"
extract "${ENTRYPOINT}" extract_kernel         "${LIB}"

# ── a real disk: DOS table, one FAT partition at sector 2048, kernel inside ──
# Mirrors the Pi builders' layout (start=2048, type=c) so the offset arithmetic
# under test is the arithmetic that runs in production.
DISK="${TMP}/disk.img"
KERNEL_SRC="${TMP}/kernel-src.bin"
head -c 262144 /dev/urandom > "${KERNEL_SRC}"
truncate -s 40M "${DISK}"
sfdisk --no-tell-kernel "${DISK}" >/dev/null 2>&1 <<'SFD'
label: dos
start=2048, size=32768, type=c
SFD
mformat -i "${DISK}@@1048576" -T 32768 :: 2>/dev/null \
    || { echo "could not mformat the test disk" >&2; exit 2; }
mcopy -n -i "${DISK}@@1048576" "${KERNEL_SRC}" ::kernel_2712.img 2>/dev/null \
    || { echo "could not seed kernel_2712.img into the test disk" >&2; exit 2; }

# A stub `mount`/`umount`/`losetup` that FAILS LOUDLY and records the attempt.
# Any use of the loop path is a test failure, not a fallback: the whole point of
# the mtools pass is that it never needs one.
mkdir -p "${TMP}/bin"
for prog in mount umount losetup; do
    cat > "${TMP}/bin/${prog}" <<EOF
#!/bin/sh
echo "${prog} \$*" >> "${TMP}/loop-attempts.log"
exit 1
EOF
    chmod +x "${TMP}/bin/${prog}"
done

run_extract() { # run_extract RUNDIR WANT -> prints the produced path
    local rundir="$1" want="$2"
    mkdir -p "${rundir}"
    (
        set -uo pipefail
        # shellcheck source=/dev/null
        . "${LIB}"
        IMG="${DISK}"; RUN_DIR="${rundir}"; WORK="${TMP}/work"
        mkdir -p "${WORK}"
        PATH="${TMP}/bin:${PATH}"
        extract_kernel "${want}"
    )
}

# ══ 1. partition_offsets reads the table the Pi builders write ══════════════
echo "partition_offsets"
offs="$( ( . "${LIB}"; IMG="${DISK}"; partition_offsets ) 2>/dev/null )"
[ "${offs}" = "2048 32768" ] \
    && _ok "reports 'start size' in sectors for the FAT partition" \
    || _bad "expected '2048 32768', got '${offs}'"

# ══ 2. extraction works with NO loop device and NO privileges ═══════════════
# This is the regression that broke rpi5/backend + rpi5/frontend. mount is
# stubbed to fail, so a green result here proves the mtools pass carried it.
echo "extract_kernel — no loop device, no root"
: > "${TMP}/loop-attempts.log"
got="$(run_extract "${TMP}/r1" kernel_2712.img 2>/dev/null)"
if [ -n "${got}" ] && [ -f "${got}" ] && cmp -s "${got}" "${KERNEL_SRC}"; then
    _ok "extracts kernel_2712.img byte-identically"
else
    _bad "did not extract kernel_2712.img (got '${got}')"
fi
if [ -s "${TMP}/loop-attempts.log" ]; then
    _bad "touched the loop path: $(tr '\n' ';' < "${TMP}/loop-attempts.log")"
else
    _ok "never invoked mount/umount/losetup"
fi
[ "$(id -u)" -ne 0 ] \
    && _ok "ran as an unprivileged uid ($(id -u)) — no root needed" \
    || _ok "ran as root (cannot prove the unprivileged case from here)"

# ══ 3. concurrency: the property the whole bug was about ═══════════════════
# Eight simultaneous extractions of the same image. Under the old loop-mount
# code this is exactly the shape that failed: one winner, the rest ERROR.
echo "extract_kernel — 8 concurrent extractions"
: > "${TMP}/loop-attempts.log"
pids=(); for i in $(seq 1 8); do
    ( run_extract "${TMP}/c${i}" kernel_2712.img >"${TMP}/c${i}.out" 2>/dev/null ) &
    pids+=("$!")
done
for p in "${pids[@]}"; do wait "${p}"; done
okc=0
for i in $(seq 1 8); do
    f="${TMP}/c${i}/kernel_2712.img"
    [ -s "${f}" ] && cmp -s "${f}" "${KERNEL_SRC}" && okc=$((okc+1))
done
[ "${okc}" -eq 8 ] \
    && _ok "all 8 produced a byte-identical kernel" \
    || _bad "only ${okc}/8 concurrent extractions succeeded"

# ══ 4. a missing kernel is still a failure (no false PASS) ═════════════════
echo "extract_kernel — absent kernel"
if run_extract "${TMP}/r2" definitely-not-here.img >/dev/null 2>&1; then
    _bad "returned success for a file that is not on the image"
else
    _ok "returns non-zero when the wanted file is absent"
fi

# ══ 5. a zero-byte hit is a miss, not a kernel ════════════════════════════
# Without this guard QEMU is handed an empty -kernel and the row fails ~20
# minutes later as an unexplained boot timeout instead of here, in one second.
echo "extract_kernel — zero-byte candidate"
mcopy -n -i "${DISK}@@1048576" /dev/null ::empty.img 2>/dev/null
if run_extract "${TMP}/r3" empty.img >/dev/null 2>&1; then
    _bad "accepted a zero-byte file as a kernel"
else
    _ok "rejects a zero-byte candidate"
fi

# ══ 6. the loop fallback holds its lock across mount -> umount ════════════
# BEHAVIOURAL, not textual. A source-order grep cannot answer this: `break`
# leaves the retry loop, so the legitimate mount-FAILED release sits between the
# success branch and the umount in the text while never running on the success
# path. So stub the whole syscall crew and assert the ORDER OF ACTUAL CALLS.
#
# mcopy/minfo are stubbed to fail, which is what forces the fallback to run at
# all — without that the mtools pass answers first and this test would pass
# vacuously no matter what the loop code did.
echo "loop fallback — lock span (behavioural)"
mkdir -p "${TMP}/fbin"
SEQ="${TMP}/callseq.log"
cat > "${TMP}/fbin/flock" <<EOF
#!/bin/sh
echo "flock \$*" >> "${SEQ}"
exit 0
EOF
cat > "${TMP}/fbin/mount" <<EOF
#!/bin/sh
echo "mount" >> "${SEQ}"
for last; do :; done
mkdir -p "\${last}"
head -c 4096 /dev/urandom > "\${last}/kernel_2712.img"
exit 0
EOF
cat > "${TMP}/fbin/umount" <<EOF
#!/bin/sh
echo "umount" >> "${SEQ}"
exit 0
EOF
for stub in mcopy minfo; do
    cat > "${TMP}/fbin/${stub}" <<EOF
#!/bin/sh
exit 1
EOF
done
chmod +x "${TMP}/fbin"/*
: > "${SEQ}"
(
    set -uo pipefail
    # shellcheck source=/dev/null
    . "${LIB}"
    IMG="${DISK}"; RUN_DIR="${TMP}/r6"; WORK="${TMP}/work6"
    mkdir -p "${RUN_DIR}" "${WORK}"
    PATH="${TMP}/fbin:${PATH}"
    extract_kernel kernel_2712.img
) >/dev/null 2>&1
seq_txt="$(tr '\n' '|' < "${SEQ}")"
if ! grep -q 'mount' "${SEQ}"; then
    _bad "the loop fallback never ran — test 6 proves nothing (seq: ${seq_txt})"
else
    _ok "loop fallback exercised (mcopy stubbed to fail)"
    # Everything strictly between the mount and the umount must be lock-free.
    between="$(awk '/^mount$/{f=1;next} /^umount$/{f=0} f' "${SEQ}")"
    if printf '%s\n' "${between}" | grep -F 'flock -u' >/dev/null; then
        _bad "lock released between mount and umount — the original defect (seq: ${seq_txt})"
    else
        _ok "no release between mount and umount"
    fi
    # And it must be released after the umount, or the next partition deadlocks.
    awk '/^umount$/{f=1;next} f' "${SEQ}" | grep -F 'flock -u' >/dev/null \
        && _ok "released after umount" \
        || _bad "never released after umount — a second partition would block (seq: ${seq_txt})"
    # The acquire must precede the mount, or the section is not serialized.
    awk '/^mount$/{exit} /flock -w/{found=1} END{exit !found}' "${SEQ}" \
        && _ok "acquired before mount" \
        || _bad "mounted without acquiring the lock first (seq: ${seq_txt})"
fi

# ══ 7. mtools pass is reachable from extract_kernel ══════════════════════
# Cheap wiring check: the fix is worthless if the fast path is defined but the
# caller never reaches it (the 'inert wiring' failure mode this repo keeps
# hitting). Comments are stripped first — prose naming the function has
# inverted exactly this kind of check here three times.
echo "wiring"
sed -n '/^extract_kernel() {/,/^}/p' "${ENTRYPOINT}" | grep -v '^[[:space:]]*#' \
    | grep -F 'extract_kernel_mtools' >/dev/null \
    && _ok "extract_kernel actually calls extract_kernel_mtools (code, not comment)" \
    || _bad "extract_kernel never calls the mtools pass"

echo
echo "== RESULT: ${PASS} passed, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ]

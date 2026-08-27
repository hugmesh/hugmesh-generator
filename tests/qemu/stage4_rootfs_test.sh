#!/usr/bin/env bash
# stage4_rootfs_test.sh — HERMETIC tests for the stage4 rootfs lane.
#
#   bash tests/qemu/stage4_rootfs_test.sh
#
# Boots nothing, needs no root, mounts nothing (that is half the point).
# build_rootfs() is sed-extracted out of run-qemu-test.sh in the
# verdict_test.sh/devices_test.sh style and driven against tiny fixture
# tarballs, with `mount`/`umount`/`losetup` STUBBED ON PATH so that any attempt
# to use one is a loud, recorded failure rather than a silent success on a
# developer box that happens to be root.
#
# WHY THIS FILE EXISTS
# --------------------
# Two defects in the same six lines of run-qemu-test.sh, both fixed 2026-08-26:
#
#  1. The rootfs was built with `mkfs.ext4` + `mount -o loop` + `tar`, none of
#     them error-checked, with no lock and no retry around the loop allocation,
#     and it HELD that loop device for the whole boot+assert window (up to
#     TIMEOUT=1800s). /dev/loop* is host-wide even from inside a --privileged
#     container, and run-qemu-docker.sh fans several rows out at once. A `mount`
#     that failed put the tar on the container's own filesystem instead, left
#     the rootfs image the empty ext4 mkfs had just made, and the boot failure
#     that followed pointed nowhere near here.
#
#  2. The xattr-preserving tar was `2>/dev/null || <plain tar>`. A stage4
#     extracted WITHOUT its security.selinux labels was indistinguishable from a
#     good one — and the ~10 SELinux assertions in assertions.sh then graded
#     that unlabelled rootfs and PASSED it: getenforce answers, semodule -l
#     lists every module, the mode matches, no load-failed marker. A clean sweep
#     of green over a filesystem where SELinux is grading nothing at all.
#
# ...and three defects an adversarial review then found in the FIRST cut of this
# very unit, all fixed and all covered here:
#
#  3. This suite sed-extracts build_rootfs() and drives it itself, so nothing in
#     the repo pinned that run-qemu-test.sh still CALLS it, or calls it with the
#     arguments in the right order. Deleting the call line outright (the runner
#     then boots QEMU against an unbuilt rootfs) was 38/0 GREEN; swapping arg1
#     and arg2 (making `truncate -s 6G` land on the stage4 tarball) was 38/0
#     GREEN. Section 1b executes the runner's own call line and closes both.
#  4. assertions.sh's reader ladder was gated on tool PRESENCE, not on tool
#     SUCCESS, so a getfattr that existed but could not answer FAILed the new
#     precondition on a rootfs secon would have read fine. Section 4 legs (f)-(i).
#  5. The secon rung was mis-spelled and exercised by nothing. Section 4 legs
#     (g), (g2) and (j).
#
# Every check below has a mutation twin that must FAIL. Section 5 goes further
# and mutates a COPY of assertions.sh (never the committed file) to demonstrate
# the vacuity itself: with the new precondition deleted, the SELinux block
# passes on a completely unlabelled tree.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${HERE}/run-qemu-test.sh"
ASSERTIONS="${HERE}/assertions.sh"
for f in "${RUNNER}" "${ASSERTIONS}"; do
    [ -f "${f}" ] || { echo "cannot find ${f}" >&2; exit 2; }
done

PASS=0; FAIL=0
_ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
_bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
eq() { if [ "$1" = "$2" ]; then _ok "$3"; else _bad "$3 (got '$1', want '$2')"; fi; }

# NO SILENT SKIPS: this suite needs e2fsprogs to mean anything at all. Missing
# tools abort with a named reason and a nonzero status — never a quiet exit 0.
for t in tar truncate mkfs.ext4 debugfs sed sort; do
    command -v "${t}" >/dev/null 2>&1 \
        || { echo "SKIPPING LOUDLY: required tool '${t}' is not on PATH; this suite cannot run" >&2; exit 2; }
done
REAL_MKFS="$(command -v mkfs.ext4)"
HAVE_SETFATTR=0
command -v setfattr >/dev/null 2>&1 && HAVE_SETFATTR=1

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

echo "── 0. both files parse (bash -n) ──"
for f in "${RUNNER}" "${ASSERTIONS}"; do
    if bash -n "${f}" 2>/dev/null; then _ok "bash -n $(basename "${f}")"; else _bad "bash -n $(basename "${f}")"; fi
done

# ══ 1. STATIC: the loop device is gone from run-qemu-test.sh entirely ════════
echo
echo "1. run-qemu-test.sh contains no mount/umount/losetup at all (comments stripped)"
# COMMENTS ARE STRIPPED FIRST. This repo has inverted exactly this kind of check
# four times by counting a token that appeared only in prose — and the fix here
# is *documented* in a long comment that names `mount -o loop` several times, so
# an unstripped grep would report the defect as still present. The strings in
# the executable text were deliberately worded to avoid the bare tokens too.
stripped="${TMP}/runner-nocomments.sh"
sed -e 's/[[:space:]]#.*$//' -e '/^[[:space:]]*#/d' "${RUNNER}" > "${stripped}"
hits="$(grep -cE '\bmount\b|\bumount\b|\blosetup\b|-o loop' "${stripped}" || true)"
eq "${hits}" "0" "no mount/umount/losetup token survives comment-stripping"
# ...and the replacement is really there.
if grep -E 'mkfs\.ext4 .*-d ' "${stripped}" >/dev/null; then
    _ok "the rootfs is populated with 'mkfs.ext4 -d'"
else
    _bad "no 'mkfs.ext4 -d' in the executable text — the loop-free path is missing"
fi
# Comment-stripping mutation: prove the strip is what makes the count honest.
raw_hits="$(grep -cE '\bmount\b|\bumount\b|\blosetup\b|-o loop' "${RUNNER}" || true)"
if [ "${raw_hits}" -gt 0 ]; then
    _ok "MUTATION CONTROL: the same grep WITHOUT stripping finds ${raw_hits} prose hit(s), i.e. the strip is load-bearing"
else
    _bad "MUTATION CONTROL failed: the unstripped grep found nothing, so this test proves nothing about stripping"
fi


# ══ 1b. THE CALL SITE ITSELF ════════════════════════════════════════════════
echo
echo "1b. run-qemu-test.sh actually CALLS build_rootfs, with the arguments in order"
# WHY THIS SECTION EXISTS — it is a green-test-that-proved-nothing, found in review.
# Sections 2-4 sed-extract build_rootfs() and drive it from HERE, which proves the
# FUNCTION works and says nothing whatsoever about the runner still calling it.
# A reviewer deleted the single call line outright: run-qemu-test.sh then built no
# rootfs at all and booted QEMU against an empty rootfs.img — and this suite still
# printed "38 passed, 0 failed", rc=0. Swapping the first two arguments
# (a realistic refactor slip, which makes `truncate -s 6G` land on the STAGE4
# TARBALL) was green too. The static leg above could not see either mutation
# because `mkfs.ext4 -d` lives inside the function body, which both mutants keep.
# This is new surface: before this commit the mkfs/tar were inline top-level
# statements and there was no call site to lose.
call_lines="$(grep -E '^build_rootfs([[:space:]]|$)' "${stripped}" || true)"
n_calls="$(printf '%s' "${call_lines}" | grep -c . || true)"
eq "${n_calls}" "1" "exactly one top-level build_rootfs call survives comment-stripping"
# The literal shape, so a rename of any of the three variables is loud too.
if grep -E '^build_rootfs "\$\{ROOTFS\}" "\$\{STAGE4\}" "\$\{TEST_DIR\}/' "${stripped}" >/dev/null; then
    _ok "the call site reads: build_rootfs \"\${ROOTFS}\" \"\${STAGE4}\" \"\${TEST_DIR}/…\""
else
    _bad "no 'build_rootfs \"\${ROOTFS}\" \"\${STAGE4}\" \"\${TEST_DIR}/…' call in the executable text (got: ${call_lines:-<nothing>})"
fi
# ...and \${ROOTFS} — arg1 — is the very file QEMU is told to boot, so arg1/arg2
# being the right way round is not a naming convention, it is the boot artefact.
if grep -F -- '-drive file="${ROOTFS}",format=raw' "${stripped}" >/dev/null; then
    _ok "\${ROOTFS} (arg1) is the image QEMU boots from"
else
    _bad "\${ROOTFS} is not the -drive QEMU boots — arg1 no longer means what this section assumes"
fi

# EXECUTABLE LEG: run the runner's OWN call line, with a recording stub standing
# in for build_rootfs and sentinel values for the three variables, then assert on
# what the call actually passed. Unlike the greps, this cannot be satisfied by a
# token sitting in a comment, and it fails when the line is gone.
CALLREC="${TMP}/callsite.args"
exec_callsite() {  # exec_callsite "<shell line>" -> writes argc then argv to CALLREC
    rm -f "${CALLREC}"
    (
        set -u
        ROOTFS="/sentinel/rootfs.img"
        STAGE4="/sentinel/stage4.tar.xz"
        TEST_DIR="/sentinel/testdir"
        build_rootfs() { printf '%s\n' "$#" "$@" > "${CALLREC}"; }
        eval "$1"
    ) >/dev/null 2>&1 || true
}
call_line="$(printf '%s\n' "${call_lines}" | sed -n '1p')"
exec_callsite "${call_line}"
if [ -s "${CALLREC}" ]; then
    _ok "the runner's own call line executes and reaches build_rootfs"
else
    _bad "NOTHING CALLS build_rootfs: the runner would boot QEMU against an unbuilt rootfs, and every test below would still pass"
fi
c_argc="$(sed -n '1p' "${CALLREC}" 2>/dev/null || true)"
c_a1="$(sed -n '2p' "${CALLREC}" 2>/dev/null || true)"
c_a2="$(sed -n '3p' "${CALLREC}" 2>/dev/null || true)"
c_a3="$(sed -n '4p' "${CALLREC}" 2>/dev/null || true)"
eq "${c_argc}" "3"                     "build_rootfs is called with exactly 3 arguments"
eq "${c_a1}" "/sentinel/rootfs.img"    "arg1 is \${ROOTFS} — the image truncate/mkfs write and QEMU boots"
eq "${c_a2}" "/sentinel/stage4.tar.xz" "arg2 is \${STAGE4} — the tarball; swapped, 'truncate -s 6G' would land on the stage4"
case "${c_a3}" in
    /sentinel/testdir/*) _ok "arg3 is a staging directory under \${TEST_DIR}" ;;
    *)                   _bad "arg3 is not under \${TEST_DIR} (got '${c_a3}')" ;;
esac
# The call must also come BEFORE the boot, not after it.
l_call="$(grep -n -E '^build_rootfs([[:space:]]|$)' "${stripped}" | cut -d: -f1 | sed -n '1p')"
l_boot="$(grep -n -E '^qemu-system-' "${stripped}" | cut -d: -f1 | sed -n '1p')"
if [ -n "${l_call}" ] && [ -n "${l_boot}" ] && [ "${l_call}" -lt "${l_boot}" ]; then
    _ok "the rootfs is built before QEMU is launched (line ${l_call} < ${l_boot})"
else
    _bad "call/boot ordering broken (call=${l_call:-none} boot=${l_boot:-none})"
fi

# MUTATION TWINS for the leg above — the reviewer's two mutations, run here.
exec_callsite ""
if [ -s "${CALLREC}" ]; then
    _bad "MUTATION SURVIVED: a deleted call site still recorded a call to build_rootfs"
else
    _ok "MUTATION CAUGHT: with the call line deleted, nothing reaches build_rootfs"
fi
exec_callsite 'build_rootfs "${STAGE4}" "${ROOTFS}" "${TEST_DIR}/rootfs-stage"'
swap_a1="$(sed -n '2p' "${CALLREC}" 2>/dev/null || true)"
if [ "${swap_a1}" = "/sentinel/rootfs.img" ]; then
    _bad "MUTATION SURVIVED: the swapped call still presented \${ROOTFS} as arg1"
else
    _ok "MUTATION CAUGHT: swapping the first two arguments is visible here (arg1='${swap_a1}')"
fi
# ══ 2. Fixtures + stubs ═════════════════════════════════════════════════════
# A stage4 fixture is a tarball with the handful of paths build_rootfs() and its
# postconditions actually touch. When setfattr is available the fixture also
# carries a user.* xattr, which travels the SAME tar --xattrs-include / mkfs -d
# path the real security.selinux labels do (security.* cannot be set without
# root, so user.* is the honest stand-in for the plumbing; the label semantics
# themselves are covered in section 4 against assertions.sh).
make_stage4() { # make_stage4 NAME [--no-init] [--empty] [--only-sh]
    local name; local root; local no_init; local empty; local only_sh
    name="$1"; shift
    no_init=0; empty=0; only_sh=0
    while [ $# -gt 0 ]; do
        case "$1" in --no-init) no_init=1 ;; --empty) empty=1 ;; --only-sh) only_sh=1 ;; esac
        shift
    done
    root="${TMP}/src-${name}"
    rm -rf "${root}"; mkdir -p "${root}"
    if [ "${empty}" = 1 ]; then
        # A tarball of nothing at all: this is what the image looks like when the
        # untar landed somewhere other than the tree mkfs is about to copy —
        # exactly the shape of the old lost-loop-mount defect.
        :
    elif [ "${only_sh}" = 1 ]; then
        # No /sbin/init, no /etc/passwd: only /bin/sh. Proves the postcondition
        # probes a LIST and does not pin one path name.
        mkdir -p "${root}/bin"; printf '#!/bin/sh\n' > "${root}/bin/sh"
    else
        mkdir -p "${root}/sbin" "${root}/etc"
        printf 'root:x:0:0::/root:/bin/bash\n'        > "${root}/etc/passwd"
        printf 'id:3:initdefault:\n'                  > "${root}/etc/inittab"
        printf '/dev/mmcblk0p2 / ext4 defaults 0 1\n' > "${root}/etc/fstab"
        [ "${no_init}" = 1 ] || printf '#!/bin/sh\nexec /sbin/openrc-init\n' > "${root}/sbin/init"
        if [ "${HAVE_SETFATTR}" = 1 ]; then
            setfattr -n user.hugmesh_stage4_probe -v "system_u:object_r:passwd_file_t:s0" "${root}/etc/passwd" 2>/dev/null || true
            [ "${no_init}" = 1 ] || setfattr -n user.hugmesh_stage4_probe -v "system_u:object_r:init_exec_t:s0" "${root}/sbin/init" 2>/dev/null || true
        fi
    fi
    tar --xattrs --xattrs-include='*.*' -cpf "${TMP}/${name}.tar" -C "${root}" .
    printf '%s' "${TMP}/${name}.tar"
}

# Stubs that make ANY use of the loop-mount path a loud, recorded failure.
STUBS="${TMP}/stubs"; mkdir -p "${STUBS}"
TRIPWIRE="${TMP}/loop-tripwire"
for t in mount umount losetup; do
    cat > "${STUBS}/${t}" <<EOF
#!/bin/sh
echo "LOOP TRIPWIRE: ${t} \$*" >> "${TRIPWIRE}"
echo "stage4 rootfs construction called ${t} — the loop-free path is broken" >&2
exit 97
EOF
    chmod +x "${STUBS}/${t}"
done

# Extract build_rootfs() from the runner. Its body holds a quoted heredoc whose
# terminator sits at column 0, but no line inside it starts with '}', so the
# plain sed range ends on the function's own closing brace.
FN="${TMP}/build_rootfs.sh"
sed -n '/^build_rootfs() {/,/^}/p' "${RUNNER}" > "${FN}"
grep -q '^build_rootfs() {' "${FN}" || { echo "could not extract build_rootfs from ${RUNNER}" >&2; exit 2; }
grep -q '^}$'               "${FN}" || { echo "build_rootfs extraction is truncated"        >&2; exit 2; }

# run_build STAGE4 OUTNAME [EXTRA_PATH_DIR] -> prints "rc=<n>" then stdout+stderr
run_build() {
    local tarball; local out; local extra
    tarball="$1"; out="$2"; extra="${3:-}"
    local combined
    combined="${STUBS}"
    [ -n "${extra}" ] && combined="${extra}:${STUBS}"
    (
        set -euo pipefail
        PATH="${combined}:${PATH}"
        KEEP=false
        ROOTFS_SIZE=64M
        RED=''; GREEN=''; CYAN=''; YEL=''; RST=''
        info() { echo "[info] $*"; }
        warn() { echo "[warn] $*" >&2; }
        step() { echo "[step] $*"; }
        die()  { echo "[die] $*" >&2; exit 1; }
        # shellcheck disable=SC1090
        source "${FN}"
        build_rootfs "${TMP}/${out}.img" "${tarball}" "${TMP}/${out}-stage"
    ) 2>&1
    echo "rc=$?"
}

# ══ 3. The happy path: a real ext4 image, no mount, real postconditions ══════
echo
echo "2. build_rootfs builds a populated ext4 image WITHOUT mounting anything"
good="$(make_stage4 good)"
: > "${TRIPWIRE}"
out="$(run_build "${good}" good)"
echo "${out}" | grep '^rc=0$' >/dev/null && _ok "build_rootfs succeeded" \
    || _bad "build_rootfs failed: ${out}"
[ ! -s "${TRIPWIRE}" ] && _ok "mount/umount/losetup were never invoked (stub tripwire empty)" \
    || _bad "LOOP TRIPWIRE FIRED: $(cat "${TRIPWIRE}")"

# POSTCONDITIONS ON THE RENDERED ARTEFACT, not on build_rootfs's exit code.
img="${TMP}/good.img"
dbg() { debugfs -R "$1" "${img}" 2>/dev/null; }
dbg 'stat /sbin/init'  | grep -E '^Inode: [0-9]+' >/dev/null && _ok "/sbin/init is in the image"  || _bad "/sbin/init missing from the image"
dbg 'stat /etc/passwd' | grep -E '^Inode: [0-9]+' >/dev/null && _ok "/etc/passwd is in the image" || _bad "/etc/passwd missing from the image"
# The QEMU fstab must have REPLACED the stage4's mmcblk one — a rewrite that
# silently no-opped would boot the guest against a device that does not exist.
fstab_body="$(debugfs -R 'cat /etc/fstab' "${img}" 2>/dev/null)"
echo "${fstab_body}" | grep '/dev/vda' >/dev/null && _ok "the QEMU /dev/vda fstab was written into the image" \
    || _bad "image fstab is not the QEMU one (got: ${fstab_body})"
echo "${fstab_body}" | grep 'mmcblk' >/dev/null && _bad "the stage4's mmcblk fstab survived into the image" \
    || _ok "the stage4's mmcblk fstab did not survive"
inittab_body="$(debugfs -R 'cat /etc/inittab' "${img}" 2>/dev/null)"
echo "${inittab_body}" | grep 'ttyAMA0' >/dev/null && _ok "the serial getty line was appended to /etc/inittab" \
    || _bad "no ttyAMA0 line in the image's inittab"
# The xattr plumbing, end to end: tarball -> staging dir -> mkfs.ext4 -d -> image.
if [ "${HAVE_SETFATTR}" = 1 ]; then
    if debugfs -R 'ea_list /etc/passwd' "${img}" 2>/dev/null | grep 'user.hugmesh_stage4_probe' >/dev/null; then
        _ok "extended attributes survive tar -> staging dir -> mkfs.ext4 -d -> image"
    else
        _bad "xattrs were LOST somewhere in the loop-free path — SELinux labels would be lost the same way"
    fi
else
    _bad "SKIPPING LOUDLY: setfattr absent, so the xattr-survival leg did not run (install sys-apps/attr)"
fi

# ══ 4. build_rootfs mutations: each guard must be able to fire ══════════════
echo
echo "3. build_rootfs MUTATIONS — every guard must be able to FAIL"

# (a) mkfs.ext4 that ignores -d: the image is created, valid, and EMPTY. This is
#     precisely the shape of the old defect (a real filesystem, no content) and
#     it is what the debugfs postconditions exist to catch.
mstub="${TMP}/mstub"; mkdir -p "${mstub}"
cat > "${mstub}/mkfs.ext4" <<EOF
#!/bin/sh
# drop '-d <dir>' and hand the rest to the real mke2fs
args=""; skip=0
for a in "\$@"; do
    if [ "\${skip}" = 1 ]; then skip=0; continue; fi
    if [ "\${a}" = "-d" ]; then skip=1; continue; fi
    args="\${args} \${a}"
done
exec "${REAL_MKFS}" \${args}
EOF
chmod +x "${mstub}/mkfs.ext4"
out="$(run_build "${good}" empty "${mstub}")"
echo "${out}" | grep '^rc=0$' >/dev/null \
    && _bad "MUTATION SURVIVED: an mkfs that ignored -d produced an EMPTY rootfs and build_rootfs returned 0" \
    || _ok "MUTATION CAUGHT: an mkfs that ignores -d is caught by the debugfs postcondition"
echo "${out}" | grep 'mkfs.ext4 -d copied nothing at all' >/dev/null \
    && _ok "…and it fails with the named postcondition, not a bare nonzero exit" \
    || _bad "…but the failure was not the named copied-nothing postcondition: ${out}"

# (b) e2fsprogs too old for -d: refuse LOUDLY, do not silently fall back.
vstub="${TMP}/vstub"; mkdir -p "${vstub}"
cat > "${vstub}/mkfs.ext4" <<'EOF'
#!/bin/sh
case " $* " in *" -V "*) echo "mke2fs 1.42.13 (17-May-2015)"; exit 0 ;; esac
echo "mkfs.ext4 stub: should never be reached with a too-old version" >&2
exit 91
EOF
chmod +x "${vstub}/mkfs.ext4"
out="$(run_build "${good}" oldver "${vstub}")"
echo "${out}" | grep '^rc=0$' >/dev/null \
    && _bad "MUTATION SURVIVED: e2fsprogs 1.42.13 was accepted for mkfs.ext4 -d" \
    || _ok "MUTATION CAUGHT: e2fsprogs older than 1.43 is refused"
echo "${out}" | grep 'too old for' >/dev/null && _ok "…with the version named in the message" \
    || _bad "…but the message did not name the version problem: ${out}"
[ ! -s "${TRIPWIRE}" ] && _ok "…and it did NOT fall back to a loop mount" \
    || _bad "…but something reached for the loop path: $(cat "${TRIPWIRE}")"

# (c) the stage4 unpacked NOTHING: mkfs still builds a valid ext4 holding only
#     the fstab/inittab this script wrote, and the image would boot to a kernel
#     panic. The postcondition must refuse it.
emptyt="$(make_stage4 emptyt --empty)"
out="$(run_build "${emptyt}" emptyt)"
echo "${out}" | grep '^rc=0$' >/dev/null \
    && _bad "MUTATION SURVIVED: an EMPTY stage4 produced a bootable-looking rootfs" \
    || _ok "MUTATION CAUGHT: an empty stage4 fails the populated-postcondition"
echo "${out}" | grep 'contains NONE of' >/dev/null \
    && _ok "…and names every path it looked for" \
    || _bad "…but the message did not name the probe list: ${out}"

# (c2) NEGATIVE CONTROL for (c): the postcondition probes a LIST, so a rootfs
#      with /bin/sh but no /sbin/init and no /etc/passwd must still PASS. A
#      guard that pinned one path name would turn a healthy usrmerge image into
#      a fatal error, and this is the leg that would catch that over-tightening.
onlysh="$(make_stage4 onlysh --only-sh)"
out="$(run_build "${onlysh}" onlysh)"
echo "${out}" | grep '^rc=0$' >/dev/null \
    && _ok "a rootfs whose only probe hit is /bin/sh still builds (the probe is a list)" \
    || _bad "the probe list is pinned too tightly — /bin/sh alone was rejected: ${out}"

# (c3) THE LABEL PROBE MUST READ A STAGE4-OWNED FILE, NOT ONE THIS SCRIPT WROTE.
#      security.* xattrs cannot be set without root, so a debugfs stub answers
#      `ea_list` per path: the label lives on /sbin/init (which came out of the
#      tarball) and NOT on /etc/fstab (which build_rootfs writes itself). A
#      probe pointed at /etc/fstab would report a perfectly labelled rootfs as
#      UNLABELLED on every single run, and the warning would stop meaning
#      anything. `stat` is delegated to the real debugfs so the postconditions
#      above still run for real.
dstub="${TMP}/dstub"; mkdir -p "${dstub}"
cat > "${dstub}/debugfs" <<EOF
#!/bin/sh
# argv: -R "<cmd> <path>" <image>
if [ "\$1" = "-R" ]; then
    cmd="\$2"
    case "\${cmd}" in
        "ea_list "*)
            path="\${cmd#ea_list }"
            echo "Extended attributes:"
            [ "\${path}" = "\${STUB_LABELLED_PATH:-/sbin/init}" ] && \
                echo '  security.selinux (26) = "system_u:object_r:init_exec_t:s0"'
            exit 0 ;;
    esac
fi
exec "$(command -v debugfs)" "\$@"
EOF
chmod +x "${dstub}/debugfs"
export STUB_LABELLED_PATH=/sbin/init
out="$(run_build "${good}" labelled "${dstub}")"
echo "${out}" | grep 'rootfs carries security.selinux (checked on /sbin/init' >/dev/null \
    && _ok "the label probe reads a stage4-owned file and reports the rootfs labelled" \
    || _bad "the label probe did not confirm the label on the stage4-owned file: ${out}"
echo "${out}" | grep 'ROOTFS IS UNLABELLED' >/dev/null \
    && _bad "MUTATION SURVIVED: a labelled rootfs was still reported UNLABELLED" \
    || _ok "…and does not cry wolf on a labelled rootfs"
# The twin: move the label onto /etc/fstab only (the file build_rootfs writes).
# A probe that read THAT file would call this rootfs labelled; the real one must
# still say UNLABELLED, because nothing out of the tarball carries a label.
export STUB_LABELLED_PATH=/etc/fstab
out="$(run_build "${good}" mislabelled "${dstub}")"
echo "${out}" | grep 'ROOTFS IS UNLABELLED' >/dev/null \
    && _ok "MUTATION CAUGHT: a label on the host-written /etc/fstab does not count as a labelled rootfs" \
    || _bad "MUTATION SURVIVED: the label probe was satisfied by a file this script wrote itself: ${out}"
unset STUB_LABELLED_PATH

# (d) the xattr tar fails: the fallback must be LOUD and must replay tar's own
#     stderr. This is the exact line that used to be `2>/dev/null`.
tstub="${TMP}/tstub"; mkdir -p "${tstub}"
cat > "${tstub}/tar" <<EOF
#!/bin/sh
case " \$* " in
    *" --xattrs-include=*.* "*)
        echo "tar: cannot set extended attribute security.selinux: Operation not supported" >&2
        exit 2 ;;
esac
exec "$(command -v tar)" "\$@"
EOF
chmod +x "${tstub}/tar"
out="$(run_build "${good}" fallback "${tstub}")"
echo "${out}" | grep '^rc=0$' >/dev/null && _ok "the plain-tar fallback still produces a bootable rootfs" \
    || _bad "the plain-tar fallback broke the build: ${out}"
echo "${out}" | grep 'XATTR-PRESERVING EXTRACTION FAILED' >/dev/null \
    && _ok "MUTATION CAUGHT: the silent xattr fallback is now announced" \
    || _bad "MUTATION SURVIVED: the xattr fallback was taken silently"
echo "${out}" | grep 'Operation not supported' >/dev/null \
    && _ok "…and tar's own stderr is replayed, not discarded" \
    || _bad "…but tar's stderr was still swallowed: ${out}"
echo "${out}" | grep 'ROOTFS IS UNLABELLED' >/dev/null \
    && _ok "…and the unlabelled result is called out by name" \
    || _bad "…but the unlabelled rootfs was not announced"

# (e) both tars fail: fatal, named.
t2stub="${TMP}/t2stub"; mkdir -p "${t2stub}"
cat > "${t2stub}/tar" <<'EOF'
#!/bin/sh
case " $* " in *" -xpf "*) echo "tar: Unexpected EOF in archive" >&2; exit 2 ;; esac
exit 0
EOF
chmod +x "${t2stub}/tar"
out="$(run_build "${good}" bothfail "${t2stub}")"
echo "${out}" | grep 'plain stage4 extraction failed too' >/dev/null \
    && _ok "MUTATION CAUGHT: a completely unreadable stage4 is fatal and named" \
    || _bad "MUTATION SURVIVED: a broken stage4 did not produce the named fatal error: ${out}"

# ══ 5. assertions.sh: the rootfs-is-labelled precondition ═══════════════════
echo
echo "4. assertions.sh — the SELinux precondition, and the vacuity it closes"
# Stub the label reader. security.* xattrs cannot be set without root, so the
# stub answers from a '<file>.selabel' sidecar: present => that label, absent =>
# exit 1, exactly as getfattr behaves for a missing attribute.
astub="${TMP}/astub"; mkdir -p "${astub}"
cat > "${astub}/getfattr" <<'EOF'
#!/bin/sh
for a in "$@"; do f="${a}"; done
[ -f "${f}.selabel" ] || exit 1
printf '%s' "$(cat "${f}.selabel")"
EOF
cat > "${astub}/getenforce" <<'EOF'
#!/bin/sh
echo "${STUB_MODE:-Permissive}"
EOF
cat > "${astub}/semodule" <<'EOF'
#!/bin/sh
cat "${STUB_SEMODULE_L:?}"
EOF
chmod +x "${astub}/getfattr" "${astub}/getenforce" "${astub}/semodule"

fx="${TMP}/fx"; mkdir -p "${fx}"
: > "${fx}/init"
printf 'SELINUX=permissive\nSELINUXTYPE=mcs\n' > "${fx}/selinux-config"
printf 'hugmesh_vpn\n'            > "${fx}/manifest.list"
printf 'hugmesh_vpn\t1.0\nbase\t1.0\n' > "${fx}/semodule-l.txt"
printf 'hugmesh_vpn loaded\n'     > "${fx}/status.txt"
: > "${fx}/built-marker"

# run_assertions <assertions-file> <probe-path> [READER_STUB_DIR] -> full output
# A third argument prepends a directory AHEAD of ${astub}, so a leg can shadow
# the default getfattr reader (or shadow this host's REAL getfattr, which is on
# PATH here) with a reader ladder of its own choosing.
run_assertions() {
    local _p
    _p="${astub}:${PATH}"
    [ -n "${3:-}" ] && _p="$3:${_p}"
    PATH="${_p}" \
    STUB_SEMODULE_L="${fx}/semodule-l.txt" STUB_MODE=Permissive \
    SELINUX_XATTR_PROBE="$2" \
    SELINUX_MODULES_LIST="${fx}/manifest.list" \
    SELINUX_MODULES_STATUS="${fx}/status.txt" \
    SELINUX_CONFIG="${fx}/selinux-config" \
    SELINUX_BUILT_MARKER="${fx}/built-marker" \
    SELINUX_LOAD_FAILED_MARKER="${fx}/no-such-marker" \
    SELINUX_EXPECTED_MODE=permissive \
    AVC_REPORT_GUEST="${TMP}/guest-avc.txt" \
    KEYS_LABEL="STAGE4TEST-NO-SUCH-LABEL" \
        bash "$1" 2>&1 || true
}
PRECOND_LINE='rootfs carries SELinux labels on disk'

# (a) properly labelled -> PASS
printf 'system_u:object_r:init_exec_t:s0' > "${fx}/init.selabel"
out="$(run_assertions "${ASSERTIONS}" "${fx}/init")"
echo "${out}" | grep "PASS  ${PRECOND_LINE}" >/dev/null \
    && _ok "a labelled rootfs PASSes the precondition" \
    || _bad "a labelled rootfs did not PASS the precondition"

# (b) no security.selinux at all -> FAIL  (the unlabelled-fallback case)
rm -f "${fx}/init.selabel"
out="$(run_assertions "${ASSERTIONS}" "${fx}/init")"
echo "${out}" | grep "FAIL  ${PRECOND_LINE}" >/dev/null \
    && _ok "MUTATION CAUGHT: an UNLABELLED rootfs FAILs the precondition" \
    || _bad "MUTATION SURVIVED: an unlabelled rootfs did not FAIL the precondition"

# (c) unlabeled_t -> FAIL (what a live policy reports for an unlabelled file)
printf 'system_u:object_r:unlabeled_t:s0' > "${fx}/init.selabel"
out="$(run_assertions "${ASSERTIONS}" "${fx}/init")"
echo "${out}" | grep "FAIL  ${PRECOND_LINE}" >/dev/null \
    && _ok "MUTATION CAUGHT: an unlabeled_t context FAILs the precondition" \
    || _bad "MUTATION SURVIVED: unlabeled_t was accepted as a real label"

# (d) probe path does not exist -> FAIL, not a skip
out="$(run_assertions "${ASSERTIONS}" "${TMP}/definitely-not-a-file")"
echo "${out}" | grep "FAIL  ${PRECOND_LINE}" >/dev/null \
    && _ok "MUTATION CAUGHT: an unreadable probe path FAILs rather than skipping" \
    || _bad "MUTATION SURVIVED: an unreadable probe path did not FAIL"

# ── THE READER LADDER (getfattr -> secon -> ls -Zd) ─────────────────────────
# Two review findings live here, and neither was covered by legs (a)-(d) above,
# because every one of those runs with a getfattr that ANSWERS:
#
#  1. The ladder used to be gated on tool PRESENCE, not on tool SUCCESS — the
#     getfattr rung did `getfattr …; return 0` unconditionally. A getfattr that
#     exists but cannot answer (EOPNOTSUPP, attr built without the security
#     namespace, a bind-mounted path) therefore returned EMPTY and FAILed the
#     precondition on a rootfs secon would have called perfectly labelled;
#     secon and ls -Z were never consulted.
#  2. The secon rung was spelled `secon --file --rawcontext -- FILE`, which
#     hands secon a file literally named --rawcontext (--file takes the filename
#     as its OWN argument), with a flag spelling that does not exist — and even
#     parsed, secon's default output is multi-line "user: …/role: …/type: …",
#     which the *:*:*: case below would never have matched. Nothing exercised
#     the rung, so nothing said so. This matters more than the getfattr rung on
#     a real image: sys-apps/policycoreutils (secon) is in EVERY
#     specs-*/portage/packages.list and sys-apps/attr (getfattr) is in NONE.
#
# The secon stub below is deliberately STRICT about argv — it emulates the real
# option grammar and rejects anything else — so the old spelling cannot pass it.
# REAL secon is not installed on this host and was NOT executed; these legs pin
# the invocation against that emulated grammar, and the ladder is written to
# fall through to ls -Zd if a live secon disagrees with it anyway.
rl="${TMP}/readers"; mkdir -p "${rl}"
cat > "${rl}/getfattr" <<'EOF'
#!/bin/sh
# present on PATH, cannot answer — the exact shape of review finding #1
echo "getfattr: /: Operation not supported" >&2
exit 1
EOF
cat > "${rl}/secon" <<'EOF'
#!/bin/sh
# Emulate policycoreutils' secon argv grammar: -f/--file takes the FILENAME as
# its own argument, -R/--raw selects raw single-line output, anything else is an
# error. STUB_SECON_SHAPE: raw (supports --raw) | norawopt (--raw is invalid,
# only the default multi-line output) | fail (cannot answer at all).
shape="${STUB_SECON_SHAPE:-raw}"
[ "${shape}" = fail ] && exit 1
raw=0; file=""
while [ $# -gt 0 ]; do
    case "$1" in
        -R|--raw)
            [ "${shape}" = norawopt ] && { echo "secon: unrecognized option '$1'" >&2; exit 1; }
            raw=1 ;;
        -f|--file) shift; file="$1" ;;
        *) echo "secon: bad argument '$1'" >&2; exit 1 ;;
    esac
    shift
done
[ -n "${file}" ] || exit 1
[ -f "${file}.selabel" ] || exit 1
ctx="$(cat "${file}.selabel")"
if [ "${raw}" = 1 ]; then printf '%s\n' "${ctx}"; exit 0; fi
printf 'user: %s\nrole: %s\ntype: %s\nrange: %s\n' \
    "$(printf '%s' "${ctx}" | cut -d: -f1)" "$(printf '%s' "${ctx}" | cut -d: -f2)" \
    "$(printf '%s' "${ctx}" | cut -d: -f3)" "$(printf '%s' "${ctx}" | cut -d: -f4-)"
EOF
# The ls rung must be SILENT for legs (f)/(g)/(g2), or it answers in secon's
# place and masks a broken secon rung: with an answering ls in this dir, a
# mutation that deleted the multi-line reassembly entirely stayed GREEN. Only
# leg (h) installs an ls that can answer.
cat > "${rl}/ls" <<'EOF'
#!/bin/sh
case " $* " in *" -Zd "*) for a in "$@"; do f="${a}"; done; printf '? %s\n' "${f}"; exit 0 ;; esac
exec REAL_LS_PATH "$@"
EOF
sed -i "s#REAL_LS_PATH#$(command -v ls)#" "${rl}/ls"
chmod +x "${rl}/getfattr" "${rl}/secon" "${rl}/ls"

# _rl_verdict <probe> -> "PASS <label>" / "FAIL <label>" for the precondition
# line only. The whole assertions.sh transcript is ~40 lines; embedding it in a
# failure message buries the one line that matters (and its own "RESULT:" line
# confused a mutation-battery scraper).
_rl_verdict() {
    run_assertions "${ASSERTIONS}" "$1" "${rl}" \
        | sed -n "s/^  \\(PASS\\|FAIL\\)  ${PRECOND_LINE}.*label:'\\([^']*\\)'.*$/\\1 \\2/p"
}

printf 'system_u:object_r:init_exec_t:s0' > "${fx}/init.selabel"

# (f) getfattr present but FAILING, secon supports --raw -> the ladder must fall
#     through to secon and PASS. This is the reviewer's exact reproduction.
export STUB_SECON_SHAPE=raw
v="$(_rl_verdict "${fx}/init")"
case "${v}" in
    "PASS system_u:object_r:init_exec_t:s0")
        _ok "MUTATION CAUGHT: a getfattr that EXISTS but cannot answer falls through to secon (--raw)" ;;
    *)  _bad "MUTATION SURVIVED: a failing getfattr short-circuits the ladder; secon was never consulted (verdict: '${v:-<no precondition line>}')" ;;
esac

# (g) same, but this secon rejects --raw and only speaks its default multi-line
#     "user: …/role: …/type: …/range: …" output. The rung must reassemble it.
#     The ls rung is silent here, so ONLY secon can satisfy this leg.
export STUB_SECON_SHAPE=norawopt
v="$(_rl_verdict "${fx}/init")"
case "${v}" in
    "PASS system_u:object_r:init_exec_t:s0")
        _ok "the secon rung reassembles secon's DEFAULT multi-line output into a real context" ;;
    PASS*) _bad "the secon rung PASSed with the wrong context '${v}' — it is not reading secon's output" ;;
    *)     _bad "the secon rung cannot read secon's default output, so the rung is dead code (verdict: '${v:-<no precondition line>}')" ;;
esac

# (g2) NEGATIVE CONTROL for (f)/(g): the secon rung must not rubber-stamp. Same
#      ladder, unlabeled_t on the sidecar -> FAIL.
printf 'system_u:object_r:unlabeled_t:s0' > "${fx}/init.selabel"
v="$(_rl_verdict "${fx}/init")"
case "${v}" in
    FAIL*) _ok "MUTATION CAUGHT: the secon rung reports unlabeled_t as UNLABELLED" ;;
    *)     _bad "MUTATION SURVIVED: the secon rung rubber-stamped an unlabeled_t file (verdict: '${v:-<no precondition line>}')" ;;
esac
printf 'system_u:object_r:init_exec_t:s0' > "${fx}/init.selabel"

# (h) getfattr AND secon both fail -> rung 3, ls -Zd, must still answer.
export STUB_SECON_SHAPE=fail
cat > "${rl}/ls" <<'EOF'
#!/bin/sh
case " $* " in
    *" -Zd "*)
        for a in "$@"; do f="${a}"; done
        if [ -f "${f}.selabel" ]; then printf '%s %s\n' "$(cat "${f}.selabel")" "${f}"
        else printf '? %s\n' "${f}"; fi
        exit 0 ;;
esac
exec REAL_LS_PATH "$@"
EOF
sed -i "s#REAL_LS_PATH#$(command -v ls)#" "${rl}/ls"
chmod +x "${rl}/ls"
v="$(_rl_verdict "${fx}/init")"
case "${v}" in
    "PASS system_u:object_r:init_exec_t:s0")
        _ok "with getfattr AND secon both failing, the ls -Zd rung answers" ;;
    *)  _bad "the ls -Zd rung is unreachable — the ladder stops at the first installed tool (verdict: '${v:-<no precondition line>}')" ;;
esac

# (i) NO reader can answer at all -> FAIL, never a silent skip. (The implementer
#     disclosed this branch as untested; it is tested now.)
cat > "${rl}/ls" <<'EOF'
#!/bin/sh
case " $* " in *" -Zd "*) echo "ls: cannot get security context" >&2; exit 1 ;; esac
exec REAL_LS_PATH "$@"
EOF
sed -i "s#REAL_LS_PATH#$(command -v ls)#" "${rl}/ls"
chmod +x "${rl}/ls"
v="$(_rl_verdict "${fx}/init")"
case "${v}" in
    FAIL*) _ok "no reader can answer at all -> the precondition FAILs (no silent skip)" ;;
    *)     _bad "a rootfs with no readable label did not FAIL (verdict: '${v:-<no precondition line>}')" ;;
esac
unset STUB_SECON_SHAPE

# (j) STATIC: the old wrong secon spelling must be gone from the EXECUTABLE text.
#     Comments stripped first — the prose above and in assertions.sh names the
#     bad spelling several times, and this repo has inverted exactly this kind
#     of count by grepping a token that only ever appeared in a comment.
a_stripped="${TMP}/assertions-nocomments.sh"
sed -e 's/[[:space:]]#.*$//' -e '/^[[:space:]]*#/d' "${ASSERTIONS}" > "${a_stripped}"
rawopt_hits="$(grep -c -- '--rawcontext' "${a_stripped}" || true)"
eq "${rawopt_hits}" "0" "no '--rawcontext' survives comment-stripping in assertions.sh"
a_raw_hits="$(grep -c -- '--rawcontext' "${ASSERTIONS}" || true)"
if [ "${a_raw_hits}" -gt 0 ]; then
    _ok "MUTATION CONTROL: the same grep unstripped finds ${a_raw_hits} prose hit(s), so the strip is load-bearing"
else
    _bad "MUTATION CONTROL failed: unstripped grep found nothing, so the leg above proves nothing"
fi
if grep -E 'secon .*--file "\$\{?1\}?"' "${a_stripped}" >/dev/null; then
    _ok "secon is invoked as 'secon [--raw] --file FILE' (the filename is --file's own argument)"
else
    _bad "the secon rung no longer passes the file as --file's argument"
fi
# (e) THE VACUITY ITSELF. Delete the precondition from a COPY of assertions.sh
#     (the committed file is never touched) and re-run against the same
#     unlabelled tree: every SELinux check below still passes. That is the state
#     the 2026-08-14 33/33 rows were in.
rm -f "${fx}/init.selabel"
mutant="${TMP}/assertions-no-precond.sh"
grep -v "${PRECOND_LINE}" "${ASSERTIONS}" | sed '/^    .\[ "${_slx_labelled}" = 1 \]./d' > "${mutant}"
bash -n "${mutant}" 2>/dev/null || { echo "mutant copy does not parse; adjust the deletion" >&2; }
mut_out="$(run_assertions "${mutant}" "${fx}/init")"
if echo "${mut_out}" | grep "${PRECOND_LINE}" >/dev/null; then
    _bad "the mutant still contains the precondition — this leg proves nothing"
else
    _ok "mutant copy really has the precondition removed"
fi
# Count the PASSes first: "zero FAILs" would be worth nothing if the block had
# not run at all — that is the very failure mode this whole unit is about.
mut_selinux_pass="$(echo "${mut_out}" | grep -c 'PASS  SELinux loaded\|PASS  getenforce matches\|PASS  node-policy module\|PASS  provision recorded\|PASS  no selinux-load-failed' || true)"
mut_selinux_fails="$(echo "${mut_out}" | grep -c 'FAIL  SELinux loaded\|FAIL  getenforce matches\|FAIL  node-policy module\|FAIL  provision recorded\|FAIL  no selinux-load-failed' || true)"
eq "${mut_selinux_pass}" "5" \
   "the mutant's SELinux block really ran (5 PASS lines, so the next assertion is not vacuous)"
eq "${mut_selinux_fails}" "0" \
   "VACUITY DEMONSTRATED: without the precondition, every SELinux check passes on an UNLABELLED tree"
# ...and with the precondition restored, the same unlabelled tree is caught.
real_out="$(run_assertions "${ASSERTIONS}" "${fx}/init")"
echo "${real_out}" | grep "FAIL  ${PRECOND_LINE}" >/dev/null \
    && _ok "…and the committed assertions.sh catches exactly that tree" \
    || _bad "…but the committed assertions.sh did not catch it"

# The precondition must run BEFORE the SELinux block it protects, or a reader
# scanning the log sees ten PASSes first and stops there.
l_pre="$(grep -n "${PRECOND_LINE}" "${ASSERTIONS}" | cut -d: -f1 | head -1)"
l_blk="$(grep -n 'check "SELinux loaded (enforcing or permissive)"' "${ASSERTIONS}" | cut -d: -f1 | head -1)"
if [ -n "${l_pre}" ] && [ -n "${l_blk}" ] && [ "${l_pre}" -lt "${l_blk}" ]; then
    _ok "the precondition is asserted before the SELinux block (line ${l_pre} < ${l_blk})"
else
    _bad "precondition ordering broken (precond=${l_pre:-none} block=${l_blk:-none})"
fi

echo
echo "== RESULT: ${PASS} passed, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ] || exit 1

#!/usr/bin/env bash
# display_argv_test.sh — HERMETIC argv assertions for the launchers' display door
# (launch-x86.sh / launch-arm.sh / launch-pi.sh --display spice ...). Boots
# nothing, starts no container, needs no root and no QEMU: qemu-system-* and
# qemu-img are stubs on PATH that record the argv one element per line, and the
# whole launcher is driven end to end against fixture files.
#
#   bash tests/qemu/display_argv_test.sh
#   DISPLAY_ARGV_LAUNCHER_DIR=/elsewhere/tests/qemu bash tests/qemu/display_argv_test.sh
#
# WHAT IT PROVES (and what a mutation must break):
#   1. BYTE-IDENTICAL DEFAULT. With none of the new flags, each launcher's argv is
#      exactly the pinned golden list below. Not "contains no display token" — the
#      WHOLE argv, element for element, so a stray device that leaked into the
#      default path shows up as a diff. A deliberate change to a launcher's
#      default argv must update the golden here, on purpose, in the same PR.
#   2. ADDS ONLY. The --display spice argv with the display elements removed is
#      the default argv again: the door is a pure addition (x86 --gpu is the one
#      documented exception, asserted separately).
#   3. THE DOOR. -object secret (file=, never password=), -spice with
#      password-secret= and the vdagent virtserialport, qemu-xhci+usb-tablet+
#      usb-kbd, the per-platform GPU (x86: -vga none + virtio-vga; aarch64:
#      virtio-gpu-pci,edid=on), -display none and -daemonize kept.
#   4. LOOPBACK DEFAULT. addr=127.0.0.1 unless --display-listen says otherwise.
#   5. THE SECRET NEVER LEAVES THE FILE. A canary password is written to the
#      secret file; it must appear in NEITHER the argv NOR the launcher's
#      stdout/stderr. Only the file's path may be printed.
#   6. REFUSALS. --display spice without --spice-port / --display-secret, an
#      empty secret file, a secret over SPICE's 60-byte ticket limit, display
#      flags without --display, an unknown mode, a --vnc-socket path over 107
#      bytes: every one exits non-zero BEFORE QEMU.
#   7. launch-arm.sh --virt-dtb drops -dtb (and only -dtb); --dtb with it refuses;
#      no --dtb at all gives the same argv (-dtb is opt-in since #879).
#   8. DRIFT GUARD. The display block is the same text in all three launchers
#      apart from the one DISPLAY_GPU_ARGS line.
#   9. windows-studio-e2e.sh's inspection VNC binds 127.0.0.1, not a bare :N.
#
# WHAT IT DOES NOT PROVE. Nothing here runs QEMU: whether the container's
# qemu-system-* accepts these options, whether a guest shows a desktop on the
# virtio-vga, and whether remote-viewer resizes it, are the runner/guest groups'
# live proofs, not this file's.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LDIR="${DISPLAY_ARGV_LAUNCHER_DIR:-${HERE}}"
for l in launch-x86.sh launch-arm.sh launch-pi.sh; do
    [ -f "${LDIR}/${l}" ] || { echo "cannot find ${LDIR}/${l}" >&2; exit 2; }
done

PASS=0; FAIL=0
_ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
_bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
eq() { if [ "$1" = "$2" ]; then _ok "$3"; else _bad "$3 (got '$1', want '$2')"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
BIN="${TMP}/bin"; mkdir -p "${BIN}"

# ── Stubs: record argv, boot nothing ─────────────────────────────────────────
for q in qemu-system-x86_64 qemu-system-aarch64; do
    cat > "${BIN}/${q}" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" > "${QEMU_ARGV}"
exit 0
STUB
    chmod +x "${BIN}/${q}"
done
cat > "${BIN}/qemu-img" <<'STUB'
#!/bin/sh
case "${1:-}" in
  create) shift; out=""; for a in "$@"; do out="$a"; done; : > "${out}" ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "${BIN}/qemu-img"

# ── Fixtures ─────────────────────────────────────────────────────────────────
IMG="${TMP}/golden.img";        head -c 4096 /dev/urandom > "${IMG}"
CODE="${TMP}/OVMF_CODE.fd";     echo code > "${CODE}"
VARS="${TMP}/OVMF_VARS.fd";     echo vars > "${VARS}"
KERNEL="${TMP}/Image";          echo kernel > "${KERNEL}"
DTBF="${TMP}/board.dtb";        echo dtb > "${DTBF}"
PIKERNEL="${TMP}/kernel_2712.img"; echo pikernel > "${PIKERNEL}"
# The canary: a password that must never be seen anywhere but inside this file.
CANARY="CANARY-7f3a9c1e5b2d-NEVER-PRINT-ME"
SECRET="${TMP}/display.secret"; printf '%s' "${CANARY}" > "${SECRET}"; chmod 600 "${SECRET}"
EMPTYSECRET="${TMP}/empty.secret"; : > "${EMPTYSECRET}"
# 61 bytes: one over spice-server's ticket limit (QEMU 7.2 would accept the file
# and then refuse every connection, silently).
LONGSECRET="${TMP}/long.secret"; head -c 61 /dev/zero | tr '\0' 'a' > "${LONGSECRET}"
# Exactly 60 bytes is the largest ticket SPICE honours; it must still boot.
MAXSECRET="${TMP}/max.secret"; head -c 60 /dev/zero | tr '\0' 'b' > "${MAXSECRET}"

LAST_RC=0; LAST_OUT=""; LAST_ARGV=""
run_launcher() { # run_launcher NAME LAUNCHER [args...] -> LAST_RC, LAST_OUT, LAST_ARGV (file)
    local name; name="$1"; shift
    local launcher; launcher="$1"; shift
    local rdir; rdir="${TMP}/run-${name}"
    rm -rf "${rdir}"
    LAST_ARGV="${TMP}/${name}.argv"; rm -f "${LAST_ARGV}"
    PATH="${BIN}:${PATH}" QEMU_ARGV="${LAST_ARGV}" \
        bash "${LDIR}/${launcher}" --run-dir "${rdir}" --work-dir "${TMP}/nowhere" "$@" \
        > "${TMP}/${name}.out" 2>&1
    LAST_RC=$?
    LAST_OUT="$(cat "${TMP}/${name}.out")"
}
# One argv element per line; an element is matched WHOLE (grep -x), so
# `-device virtio-gpu-pci` and `-device virtio-gpu-pci,edid=on` are different.
has_elem()  { grep -qxF -- "$2" "$1"; }
# "A then B as consecutive elements" — the flag and its value.
has_pair()  { awk -v a="$2" -v b="$3" 'prev==a && $0==b {f=1} {prev=$0} END{exit f?0:1}' "$1"; }
count_elem(){ grep -cxF -- "$2" "$1" || true; }

# Per-launcher baseline flags: everything host-dependent pinned so the golden is
# the same on a KVM box, in CI and in a container.
X86=(--img "${IMG}" --ovmf-code "${CODE}" --ovmf-vars "${VARS}" --accel tcg --cpu max)
ARM=(--platform frite --board la-frite --img "${IMG}" --kernel "${KERNEL}" --dtb "${DTBF}")
ARMV=(--platform frite --board la-frite --img "${IMG}" --kernel "${KERNEL}")   # no --dtb: lets --virt-dtb apply
PI=(--img "${IMG}" --kernel "${PIKERNEL}")
DISP=(--display spice --spice-port 5930 --display-secret "${SECRET}")

# ── 1) Byte-identical default argv ───────────────────────────────────────────
golden_x86() { # RUNDIR
cat <<EOF
-machine
q35,accel=tcg
-cpu
max
-smp
4
-m
4096
-no-reboot
-drive
if=pflash,format=raw,readonly=on,file=${CODE}
-drive
if=pflash,format=raw,file=$1/OVMF_VARS.fd
-drive
file=$1/run.qcow2,format=qcow2,if=none,id=hd0
-device
virtio-blk-pci,drive=hd0
-netdev
user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::8443-:443,hostfwd=tcp::8080-:80,hostfwd=tcp::6443-:6443,hostfwd=tcp::8081-:8080
-device
virtio-net-pci,netdev=net0
-pidfile
$1/qemu.pid
-display
none
-serial
file:$1/console.log
-monitor
none
-daemonize
EOF
}
golden_a64() { # RUNDIR CPU KERNEL [DTB] — the -append value is checked separately
cat <<EOF
-machine
virt,gic-version=3
-cpu
$2
-smp
2
-m
2048
-no-reboot
-kernel
$3
EOF
[ -n "${4:-}" ] && printf -- '-dtb\n%s\n' "$4"
cat <<EOF
-append
@APPEND@
-drive
file=$1/run.qcow2,format=qcow2,if=none,id=hd0
-device
virtio-blk-pci,drive=hd0
-netdev
user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::8443-:443,hostfwd=tcp::8080-:80,hostfwd=tcp::6443-:6443,hostfwd=tcp::8081-:8080
-device
virtio-net-pci,netdev=net0
-pidfile
$1/qemu.pid
-display
none
-serial
file:$1/console.log
-monitor
none
-daemonize
EOF
}
# Compare an argv dump against a golden, element for element. '@APPEND@' in the
# golden stands for the one value (the aarch64 kernel cmdline) that is checked
# by prefix instead; every other element must match exactly.
argv_matches_golden() { # ARGVFILE GOLDENFILE LABEL
    local got want label; got="$1"; want="$2"; label="$3"
    cat "${want}" > "${TMP}/golden.want"
    local -a g; mapfile -t g < "${TMP}/golden.want"
    local -a a; mapfile -t a < "${got}"
    local i; : > "${TMP}/golden.got"
    for ((i=0; i<${#a[@]}; i++)); do
        if [ "${g[i]:-}" = "@APPEND@" ]; then printf '@APPEND@\n' >> "${TMP}/golden.got"
        else printf '%s\n' "${a[i]}" >> "${TMP}/golden.got"; fi
    done
    if diff -u "${TMP}/golden.want" "${TMP}/golden.got" > "${TMP}/golden.diff"; then
        _ok "${label}: argv is byte-identical to the golden (${#a[@]} elements)"
    else
        _bad "${label}: argv DIFFERS from the golden:"; sed 's/^/        /' "${TMP}/golden.diff" >&2
    fi
}

echo "== 1) default argv is byte-identical (no display flag) =="
run_launcher x86-def launch-x86.sh "${X86[@]}"
eq "${LAST_RC}" "0" "x86: default launch exits 0"
golden_x86 "${TMP}/run-x86-def" > "${TMP}/x86.golden"
argv_matches_golden "${LAST_ARGV}" "${TMP}/x86.golden" "x86"
X86_DEF="${LAST_ARGV}"

run_launcher arm-def launch-arm.sh "${ARM[@]}"
eq "${LAST_RC}" "0" "arm: default launch exits 0"
golden_a64 "${TMP}/run-arm-def" cortex-a53 "${KERNEL}" "${DTBF}" > "${TMP}/arm.golden"
argv_matches_golden "${LAST_ARGV}" "${TMP}/arm.golden" "arm"
ARM_DEF="${LAST_ARGV}"
app="$(awk '/^-append$/{getline; print; exit}' "${ARM_DEF}")"
case "${app}" in
    "root=/dev/vda2 rootfstype=ext4 rw rootwait console=ttyAMA0,115200 net.ifnames=0 "*) _ok "arm: -append keeps its root=/console= head" ;;
    *) _bad "arm: -append head changed: ${app}" ;;
esac

run_launcher pi-def launch-pi.sh "${PI[@]}"
eq "${LAST_RC}" "0" "pi: default launch exits 0"
golden_a64 "${TMP}/run-pi-def" cortex-a76 "${PIKERNEL}" > "${TMP}/pi.golden"
argv_matches_golden "${LAST_ARGV}" "${TMP}/pi.golden" "pi"
PI_DEF="${LAST_ARGV}"

for f in "${X86_DEF}" "${ARM_DEF}" "${PI_DEF}"; do
    for tok in -spice -object -vga -vnc -chardev spicevmc,id=vdagent,name=vdagent qemu-xhci usb-tablet usb-kbd virtio-serial-pci virtio-vga virtio-gpu-pci,edid=on; do
        if has_elem "${f}" "${tok}"; then _bad "$(basename "${f}"): default argv carries display element '${tok}'"; fi
    done
done
_ok "no display element in any default argv (checked 12 tokens x 3 launchers)"

# ── 2 + 3) The door, and "adds only" ─────────────────────────────────────────
echo "== 2) --display spice adds the door, and only the door =="
# Elements the door adds (flag/value pairs as two lines each), common to all three.
DOOR_COMMON=(
    -object "secret,id=hmdisp,file=${SECRET},format=raw"
    -spice  "port=5930,addr=127.0.0.1,password-secret=hmdisp,agent-mouse=on"
    -device virtio-serial-pci
    -chardev spicevmc,id=vdagent,name=vdagent
    -device virtserialport,chardev=vdagent,name=com.redhat.spice.0
    -device qemu-xhci
    -device usb-tablet
    -device usb-kbd
)
check_door() { # ARGVFILE LABEL GPU-PAIRS...
    local f label; f="$1"; label="$2"; shift 2
    local i
    for ((i=0; i<${#DOOR_COMMON[@]}; i+=2)); do
        has_pair "${f}" "${DOOR_COMMON[i]}" "${DOOR_COMMON[i+1]}" \
            && _ok "${label}: ${DOOR_COMMON[i]} ${DOOR_COMMON[i+1]}" \
            || _bad "${label}: missing ${DOOR_COMMON[i]} ${DOOR_COMMON[i+1]}"
    done
    while [ $# -ge 2 ]; do
        has_pair "${f}" "$1" "$2" && _ok "${label}: $1 $2" || _bad "${label}: missing $1 $2"
        shift 2
    done
    has_pair "${f}" -display none && _ok "${label}: -display none kept" || _bad "${label}: -display none lost"
    has_elem "${f}" -daemonize    && _ok "${label}: -daemonize kept"    || _bad "${label}: -daemonize lost"
    # password= as an OPTION (not password-secret=) must never appear in any element.
    if grep -qE '(^|,)password=' "${f}"; then _bad "${label}: a password= option is in the argv"; else _ok "${label}: no password= option anywhere in argv"; fi
    if grep -qF -- "${CANARY}" "${f}"; then _bad "${label}: THE SECRET IS IN THE ARGV"; else _ok "${label}: the secret's value is not in the argv"; fi
}
# Remove the door's flag/value pairs from a display-mode argv. A pair is dropped
# only when the flag AND the value that follows it match, so `-device` lines the
# default argv owns (virtio-blk-pci, virtio-net-pci) are untouched.
strip_door() { # ARGVFILE OUT GPU-PAIRS...
    local f out; f="$1"; out="$2"; shift 2
    local -a drop=("${DOOR_COMMON[@]}" "$@")
    local -a lines
    mapfile -t lines < "${f}"
    : > "${out}"
    local i j n hit; n=${#lines[@]}
    for ((i=0; i<n; i++)); do
        hit=0
        for ((j=0; j<${#drop[@]}; j+=2)); do
            if [ "${lines[i]}" = "${drop[j]}" ] && [ $((i+1)) -lt "${n}" ] && [ "${lines[i+1]}" = "${drop[j+1]}" ]; then
                hit=1; break
            fi
        done
        if [ "${hit}" -eq 1 ]; then i=$((i+1)); continue; fi
        printf '%s\n' "${lines[i]}" >> "${out}"
    done
}
# Run dirs differ between two runs; normalise them before diffing.
norm_rundir() { sed "s#${TMP}/run-[a-z0-9-]*#RUNDIR#g" "$1"; }
adds_only() { # DISPARGV DEFARGV LABEL GPU-PAIRS...
    local d b label; d="$1"; b="$2"; label="$3"; shift 3
    strip_door "${d}" "${TMP}/stripped.argv" "$@"
    if diff -u <(norm_rundir "${b}") <(norm_rundir "${TMP}/stripped.argv") > "${TMP}/adds.diff"; then
        _ok "${label}: display argv minus the door == default argv (adds only)"
    else
        _bad "${label}: the door changed something beyond its own elements:"; sed 's/^/        /' "${TMP}/adds.diff" >&2
    fi
}

run_launcher x86-disp launch-x86.sh "${X86[@]}" "${DISP[@]}"
eq "${LAST_RC}" "0" "x86: --display spice exits 0"
check_door "${LAST_ARGV}" "x86" -vga none -device virtio-vga
if has_elem "${LAST_ARGV}" virtio-gpu-pci; then _bad "x86: a bare virtio-gpu-pci rides along with virtio-vga"; else _ok "x86: no extra virtio-gpu-pci beside virtio-vga"; fi
adds_only "${LAST_ARGV}" "${X86_DEF}" "x86" -vga none -device virtio-vga
case "${LAST_OUT}" in
    *"display: spice on 127.0.0.1:5930 (password in ${SECRET})"*) _ok "x86: prints 'display: spice on ADDR:N (password in FILE)'" ;;
    *) _bad "x86: the display info line is missing or misspelt" ;;
esac
if grep -qF -- "${CANARY}" "${TMP}/x86-disp.out"; then _bad "x86: THE SECRET IS IN THE LAUNCHER OUTPUT"; else _ok "x86: the secret's value is not in the launcher output"; fi

run_launcher arm-disp launch-arm.sh "${ARM[@]}" "${DISP[@]}"
eq "${LAST_RC}" "0" "arm: --display spice exits 0"
check_door "${LAST_ARGV}" "arm" -device virtio-gpu-pci,edid=on
if has_elem "${LAST_ARGV}" virtio-vga; then _bad "arm: x86's virtio-vga leaked into the aarch64 argv"; else _ok "arm: no virtio-vga on aarch64"; fi
adds_only "${LAST_ARGV}" "${ARM_DEF}" "arm" -device virtio-gpu-pci,edid=on
if grep -qF -- "${CANARY}" "${TMP}/arm-disp.out"; then _bad "arm: THE SECRET IS IN THE LAUNCHER OUTPUT"; else _ok "arm: the secret's value is not in the launcher output"; fi

run_launcher pi-disp launch-pi.sh "${PI[@]}" "${DISP[@]}"
eq "${LAST_RC}" "0" "pi: --display spice exits 0"
check_door "${LAST_ARGV}" "pi" -device virtio-gpu-pci,edid=on
adds_only "${LAST_ARGV}" "${PI_DEF}" "pi" -device virtio-gpu-pci,edid=on
if grep -qF -- "${CANARY}" "${TMP}/pi-disp.out"; then _bad "pi: THE SECRET IS IN THE LAUNCHER OUTPUT"; else _ok "pi: the secret's value is not in the launcher output"; fi

echo "== 2b) x86 --gpu: default adds virtio-gpu-pci, display mode folds it into virtio-vga =="
run_launcher x86-gpu launch-x86.sh "${X86[@]}" --gpu
eq "$(count_elem "${LAST_ARGV}" virtio-gpu-pci)" "1" "x86 --gpu (no display): one bare virtio-gpu-pci, as before"
run_launcher x86-gpu-disp launch-x86.sh "${X86[@]}" --gpu "${DISP[@]}"
eq "${LAST_RC}" "0" "x86 --gpu --display spice exits 0"
eq "$(count_elem "${LAST_ARGV}" virtio-gpu-pci)" "0" "x86 --gpu --display spice: NO bare virtio-gpu-pci (virtio-vga replaces it)"
has_pair "${LAST_ARGV}" -device virtio-vga && _ok "x86 --gpu --display spice: virtio-vga present" || _bad "x86 --gpu --display spice: virtio-vga missing"

# ── 4) Listen address ────────────────────────────────────────────────────────
echo "== 4) listen address: loopback by default, --display-listen honoured =="
run_launcher x86-listen launch-x86.sh "${X86[@]}" "${DISP[@]}" --display-listen 0.0.0.0
has_pair "${LAST_ARGV}" -spice "port=5930,addr=0.0.0.0,password-secret=hmdisp,agent-mouse=on" \
    && _ok "--display-listen 0.0.0.0 reaches -spice addr= (the in-container case)" \
    || _bad "--display-listen 0.0.0.0 was not honoured"
run_launcher x86-port launch-x86.sh "${X86[@]}" --display spice --spice-port 5931 --display-secret "${SECRET}"
has_pair "${LAST_ARGV}" -spice "port=5931,addr=127.0.0.1,password-secret=hmdisp,agent-mouse=on" \
    && _ok "--spice-port reaches -spice port= and addr defaults to 127.0.0.1" \
    || _bad "--spice-port 5931 / default addr not honoured"

# ── 5) VNC fallback door ─────────────────────────────────────────────────────
echo "== 5) --vnc-socket: unix socket + the same secret, 107-byte AF_UNIX check =="
VSOCK="${TMP}/vnc.sock"
run_launcher x86-vnc launch-x86.sh "${X86[@]}" "${DISP[@]}" --vnc-socket "${VSOCK}"
eq "${LAST_RC}" "0" "x86: --vnc-socket exits 0"
has_pair "${LAST_ARGV}" -object "secret,id=hmvnc,file=${SECRET},format=raw" && _ok "vnc: hmvnc secret object from the same file" || _bad "vnc: hmvnc secret object missing"
has_pair "${LAST_ARGV}" -vnc "unix:${VSOCK},password-secret=hmvnc" && _ok "vnc: -vnc unix:SOCK,password-secret=hmvnc" || _bad "vnc: -vnc line wrong"
if grep -qE '^unix:.*,password=' "${LAST_ARGV}"; then _bad "vnc: password= on the -vnc line"; else _ok "vnc: no password= on the -vnc line"; fi
run_launcher x86-novnc launch-x86.sh "${X86[@]}" "${DISP[@]}"
if has_elem "${LAST_ARGV}" -vnc; then _bad "vnc: -vnc present without --vnc-socket"; else _ok "vnc: no -vnc without --vnc-socket"; fi
LONG="${TMP}/$(printf 'x%.0s' $(seq 1 120))/vnc.sock"
run_launcher x86-vnclong launch-x86.sh "${X86[@]}" "${DISP[@]}" --vnc-socket "${LONG}"
if [ "${LAST_RC}" -ne 0 ] && [ ! -f "${LAST_ARGV}" ]; then _ok "vnc: a ${#LONG}-byte socket path is refused before QEMU runs"; else _bad "vnc: a ${#LONG}-byte socket path was not refused (rc=${LAST_RC})"; fi
case "${LAST_OUT}" in *"107"*) _ok "vnc: the refusal names the 107-byte limit" ;; *) _bad "vnc: the refusal does not name the limit" ;; esac

# ── 6) Refusals ──────────────────────────────────────────────────────────────
echo "== 6) refusals happen before QEMU =="
refuses() { # LABEL LAUNCHER args...
    local label; label="$1"; shift
    run_launcher "ref-${PASS}${FAIL}" "$@"
    if [ "${LAST_RC}" -ne 0 ] && [ ! -f "${LAST_ARGV}" ]; then _ok "refuses: ${label}"; else _bad "accepted: ${label} (rc=${LAST_RC}, qemu invoked=$([ -f "${LAST_ARGV}" ] && echo yes || echo no))"; fi
}
for L in launch-x86.sh launch-arm.sh launch-pi.sh; do
    case "${L}" in launch-x86.sh) B=("${X86[@]}") ;; launch-arm.sh) B=("${ARM[@]}") ;; *) B=("${PI[@]}") ;; esac
    refuses "${L}: --display spice without --spice-port"     "${L}" "${B[@]}" --display spice --display-secret "${SECRET}"
    refuses "${L}: --display spice without --display-secret" "${L}" "${B[@]}" --display spice --spice-port 5930
    refuses "${L}: --display spice with an EMPTY secret file" "${L}" "${B[@]}" --display spice --spice-port 5930 --display-secret "${EMPTYSECRET}"
    refuses "${L}: --display spice with a missing secret file" "${L}" "${B[@]}" --display spice --spice-port 5930 --display-secret "${TMP}/nope.secret"
    refuses "${L}: --display spice with a 61-byte secret (over SPICE's 60-byte ticket)" "${L}" "${B[@]}" --display spice --spice-port 5930 --display-secret "${LONGSECRET}"
    run_launcher "max-${L}" "${L}" "${B[@]}" --display spice --spice-port 5930 --display-secret "${MAXSECRET}"
    eq "${LAST_RC}" "0" "${L}: a 60-byte secret (the SPICE maximum) still boots"
    refuses "${L}: --spice-port without --display"            "${L}" "${B[@]}" --spice-port 5930
    refuses "${L}: --display-secret without --display"        "${L}" "${B[@]}" --display-secret "${SECRET}"
    refuses "${L}: --vnc-socket without --display"            "${L}" "${B[@]}" --vnc-socket "${VSOCK}"
    refuses "${L}: --display bogus"                           "${L}" "${B[@]}" --display bogus --spice-port 5930 --display-secret "${SECRET}"
    refuses "${L}: --spice-port 70000"                        "${L}" "${B[@]}" --display spice --spice-port 70000 --display-secret "${SECRET}"
    refuses "${L}: --spice-port abc"                          "${L}" "${B[@]}" --display spice --spice-port abc --display-secret "${SECRET}"
    refuses "${L}: --display-listen ''"                       "${L}" "${B[@]}" "${DISP[@]}" --display-listen ""
done
# --display none with nothing else is the default and must still boot.
run_launcher x86-none launch-x86.sh "${X86[@]}" --display none
eq "${LAST_RC}" "0" "x86: explicit --display none exits 0"
argv_matches_golden "${LAST_ARGV}" <(golden_x86 "${TMP}/run-x86-none") "x86 --display none"

# ── 7) launch-arm.sh --virt-dtb ──────────────────────────────────────────────
echo "== 7) launch-arm.sh --virt-dtb omits -dtb and nothing else =="
run_launcher arm-virt launch-arm.sh "${ARMV[@]}" --virt-dtb
eq "${LAST_RC}" "0" "arm --virt-dtb exits 0 with no board DTB on disk"
if has_elem "${LAST_ARGV}" -dtb; then _bad "arm --virt-dtb: -dtb still in argv"; else _ok "arm --virt-dtb: no -dtb"; fi
golden_a64 "${TMP}/run-arm-virt" cortex-a53 "${KERNEL}" > "${TMP}/armv.golden"
argv_matches_golden "${LAST_ARGV}" "${TMP}/armv.golden" "arm --virt-dtb"
case "${LAST_OUT}" in *"QEMU generates the virt DTB"*) _ok "arm --virt-dtb: says so in the dtb info line" ;; *) _bad "arm --virt-dtb: info line does not say the DTB is generated" ;; esac
run_launcher arm-virt-disp launch-arm.sh "${ARMV[@]}" --virt-dtb "${DISP[@]}"
eq "${LAST_RC}" "0" "arm --virt-dtb --display spice exits 0"
has_pair "${LAST_ARGV}" -device virtio-gpu-pci,edid=on && _ok "arm --virt-dtb --display spice: virtio-gpu-pci,edid=on" || _bad "arm --virt-dtb --display spice: gpu missing"
refuses "arm: --virt-dtb together with --dtb" launch-arm.sh "${ARM[@]}" --virt-dtb
# #879: -dtb is opt-in, so no --dtb is the same argv as --virt-dtb (QEMU's own
# virt DT); --virt-dtb only states that default and refuses an explicit --dtb.
run_launcher arm-nodtb launch-arm.sh "${ARMV[@]}"
eq "${LAST_RC}" "0" "arm without --dtb boots on QEMU's virt DTB (no board DTB on disk needed)"
if has_elem "${LAST_ARGV}" -dtb; then _bad "arm without --dtb: -dtb in argv"; else _ok "arm without --dtb: no -dtb"; fi
golden_a64 "${TMP}/run-arm-nodtb" cortex-a53 "${KERNEL}" > "${TMP}/armnodtb.golden"
argv_matches_golden "${LAST_ARGV}" "${TMP}/armnodtb.golden" "arm without --dtb"

# ── 8) Drift guard: one block, three launchers ───────────────────────────────
echo "== 8) the display block is identical across the three launchers =="
for L in launch-x86.sh launch-arm.sh launch-pi.sh; do
    sed -n '/^# Optional display door\. ONE door/,/^esac$/p' "${LDIR}/${L}" | grep -v '^DISPLAY_GPU_ARGS=' > "${TMP}/${L}.block"
    [ -s "${TMP}/${L}.block" ] || _bad "${L}: display block not found"
done
if cmp -s "${TMP}/launch-x86.sh.block" "${TMP}/launch-arm.sh.block" && cmp -s "${TMP}/launch-x86.sh.block" "${TMP}/launch-pi.sh.block"; then
    _ok "display block identical in x86/arm/pi apart from DISPLAY_GPU_ARGS ($(wc -l < "${TMP}/launch-x86.sh.block") lines)"
else
    _bad "display block drifted between launchers"; diff "${TMP}/launch-x86.sh.block" "${TMP}/launch-arm.sh.block" >&2 | head -20; diff "${TMP}/launch-x86.sh.block" "${TMP}/launch-pi.sh.block" >&2 | head -20
fi
eq "$(grep -c '^DISPLAY_GPU_ARGS=(-vga none -device virtio-vga)$' "${LDIR}/launch-x86.sh")" "1" "x86 DISPLAY_GPU_ARGS is -vga none + virtio-vga"
eq "$(grep -c '^DISPLAY_GPU_ARGS=(-device virtio-gpu-pci,edid=on)$' "${LDIR}/launch-arm.sh")" "1" "arm DISPLAY_GPU_ARGS is virtio-gpu-pci,edid=on"
eq "$(grep -c '^DISPLAY_GPU_ARGS=(-device virtio-gpu-pci,edid=on)$' "${LDIR}/launch-pi.sh")" "1" "pi DISPLAY_GPU_ARGS is virtio-gpu-pci,edid=on"
# Static: the only password-bearing SPICE/VNC options are password-secret=.
for L in launch-x86.sh launch-arm.sh launch-pi.sh; do
    # Comments may NAME the forbidden spelling; code may not carry it.
    n="$(grep -vE '^[[:space:]]*#' "${LDIR}/${L}" | grep -cE '(^|[ ,"])password=' || true)"
    eq "${n}" "0" "${L}: no 'password=' option spelled in code (only password-secret=)"
    n="$(grep -c 'DISPLAY_LISTEN="127.0.0.1"' "${LDIR}/${L}" || true)"
    eq "${n}" "1" "${L}: the listen default is 127.0.0.1"
done

# ── 9) windows-studio-e2e.sh's VNC door is loopback-only ─────────────────────
echo "== 9) windows-studio-e2e.sh inspection VNC binds 127.0.0.1 =="
W="${LDIR}/windows-studio-e2e.sh"
if [ -f "${W}" ]; then
    if grep -qE -- '-vnc "?:\$\{?VNC_PORT' "${W}"; then _bad "windows-studio-e2e.sh: bare -vnc :N (0.0.0.0, no password)"; else _ok "windows-studio-e2e.sh: no bare -vnc :N"; fi
    if grep -qF -- '-vnc "127.0.0.1:${VNC_PORT}"' "${W}"; then _ok "windows-studio-e2e.sh: -vnc 127.0.0.1:N"; else _bad "windows-studio-e2e.sh: loopback -vnc line missing"; fi
else
    _ok "windows-studio-e2e.sh absent in ${LDIR}; nothing to check"
fi

echo
echo "== display_argv_test: ${PASS} passed, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ]

#!/usr/bin/env bash
# no_egress_argv_test.sh — HERMETIC argv assertions for the launchers' --no-egress
# switch (launch-x86.sh / launch-arm.sh / launch-pi.sh). Boots nothing and needs no
# QEMU or root: qemu-system-* and qemu-img are stubs on PATH that record the argv,
# the same way display_argv_test.sh drives the launchers.
#
# Why the switch exists: booting an image with its REAL KEYS disk (production keys,
# tunnel/tailnet credentials) through these launchers gave the guest unrestricted
# slirp egress, and every port forward (22/443/80/6443/8080) listened on ALL host
# interfaces. There was no way to say "this guest must reach nothing".
#
# WHAT IT PROVES:
#   1. Default unchanged: without --no-egress, no restrict= and the forwards keep
#      their all-interfaces spelling (display_argv_test.sh pins the whole argv).
#   2. --no-egress: the slirp netdev carries restrict=on, and EVERY hostfwd binds
#      127.0.0.1; the count of forwards is unchanged.
#   3. --no-egress + --mesh-net: multicast gets localaddr=127.0.0.1 (stays on
#      this host), listen=/connect= on 127.0.0.1 pass, on any other address the
#      launcher refuses BEFORE QEMU, and a foreign localaddr is refused.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0
_ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
_bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
BIN="${TMP}/bin"; mkdir -p "${BIN}"
for q in qemu-system-x86_64 qemu-system-aarch64; do
    printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "${QEMU_ARGV}"\nexit 0\n' > "${BIN}/${q}"
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

IMG="${TMP}/golden.img";         head -c 4096 /dev/urandom > "${IMG}"
CODE="${TMP}/OVMF_CODE.fd";      echo code > "${CODE}"
VARS="${TMP}/OVMF_VARS.fd";      echo vars > "${VARS}"
KERNEL="${TMP}/Image";           echo kernel > "${KERNEL}"
DTBF="${TMP}/board.dtb";         echo dtb > "${DTBF}"
PIKERNEL="${TMP}/kernel_2712.img"; echo pikernel > "${PIKERNEL}"

X86=(--img "${IMG}" --ovmf-code "${CODE}" --ovmf-vars "${VARS}" --accel tcg --cpu max)
ARM=(--platform frite --board la-frite --img "${IMG}" --kernel "${KERNEL}" --dtb "${DTBF}")
PI=(--img "${IMG}" --kernel "${PIKERNEL}")

RC=0
ARGV=""
run() { # run NAME LAUNCHER [args...] -> RC, ARGV (file)
    local name="$1"; shift
    local launcher="$1"; shift
    ARGV="${TMP}/${name}.argv"; rm -f "${ARGV}"
    PATH="${BIN}:${PATH}" QEMU_ARGV="${ARGV}" \
        bash "${HERE}/${launcher}" --run-dir "${TMP}/run-${name}" --work-dir "${TMP}/nowhere" "$@" \
        > "${TMP}/${name}.out" 2>&1
    RC=$?
}
# The value after the first `-netdev` whose value starts with $2.
netdev() { awk -v p="$2" 'prev=="-netdev" && index($0,p)==1 {print; exit} {prev=$0}' "$1"; }

for spec in "x86:launch-x86.sh" "arm:launch-arm.sh" "pi:launch-pi.sh"; do
    tag="${spec%%:*}"; l="${spec#*:}"
    case "${tag}" in x86) base=("${X86[@]}") ;; arm) base=("${ARM[@]}") ;; pi) base=("${PI[@]}") ;; esac
    echo "== ${l} =="

    run "${tag}-default" "${l}" "${base[@]}"
    nd="$(netdev "${ARGV}" user,id=net0)"
    if [ "${RC}" = 0 ] && [ -n "${nd}" ]; then
        case "${nd}" in *restrict=*) _bad "${l}: the DEFAULT netdev changed (has restrict=): ${nd}" ;;
            *) _ok "${l}: default netdev has no restrict= (unchanged)" ;; esac
    else _bad "${l}: the default launch failed (rc=${RC})"; fi
    n_default="$(printf '%s' "${nd}" | grep -o 'hostfwd=' | wc -l)"

    run "${tag}-noegress" "${l}" "${base[@]}" --no-egress
    nd="$(netdev "${ARGV}" user,id=net0)"
    if [ "${RC}" != 0 ] || [ -z "${nd}" ]; then
        _bad "${l}: --no-egress launch failed (rc=${RC}): $(tail -2 "${TMP}/${tag}-noegress.out" | tr '\n' ' ')"
        continue
    fi
    case ",${nd}," in *,restrict=on,*) _ok "${l}: --no-egress sets restrict=on" ;;
        *) _bad "${l}: --no-egress netdev has no restrict=on: ${nd}" ;; esac
    n_all="$(printf '%s' "${nd}" | grep -o 'hostfwd=tcp:[^,]*' | wc -l)"
    n_lo="$(printf '%s' "${nd}" | grep -o 'hostfwd=tcp:127\.0\.0\.1:[0-9]*-:[0-9]*' | wc -l)"
    if [ "${n_all}" -gt 0 ] && [ "${n_all}" = "${n_lo}" ] && [ "${n_all}" = "${n_default}" ]; then
        _ok "${l}: --no-egress binds all ${n_all} forwards to 127.0.0.1"
    else _bad "${l}: --no-egress forwards not all on 127.0.0.1 (${n_lo} of ${n_all}, default had ${n_default}): ${nd}"; fi

    run "${tag}-mcast" "${l}" "${base[@]}" --no-egress --mesh-net 230.0.0.1:1234 --mesh-id 2
    md="$(netdev "${ARGV}" socket,id=mesh0)"
    case "${RC}:${md}" in
        0:*,mcast=230.0.0.1:1234,localaddr=127.0.0.1) _ok "${l}: --no-egress keeps the multicast mesh on loopback" ;;
        *) _bad "${l}: --no-egress multicast mesh not pinned to loopback (rc=${RC}): ${md}" ;;
    esac
    run "${tag}-mcast-plain" "${l}" "${base[@]}" --mesh-net 230.0.0.1:1234 --mesh-id 2
    md="$(netdev "${ARGV}" socket,id=mesh0)"
    case "${md}" in *localaddr=*) _bad "${l}: the default multicast mesh changed: ${md}" ;;
        *) _ok "${l}: without --no-egress the multicast mesh is unchanged" ;; esac
    run "${tag}-listen-lo" "${l}" "${base[@]}" --no-egress --mesh-net listen=127.0.0.1:5555 --mesh-id 2
    [ "${RC}" = 0 ] && _ok "${l}: --no-egress accepts listen=127.0.0.1" \
        || _bad "${l}: --no-egress refused listen=127.0.0.1 (rc=${RC})"
    for bad in listen=0.0.0.0:5555 connect=192.0.2.10:5555 listen=:5555 "mcast=230.0.0.1:1234,localaddr=192.0.2.10"; do
        run "${tag}-refuse" "${l}" "${base[@]}" --no-egress --mesh-net "${bad}" --mesh-id 2
        if [ "${RC}" != 0 ] && [ ! -s "${ARGV}" ]; then _ok "${l}: --no-egress refuses --mesh-net ${bad} before QEMU"
        else _bad "${l}: --no-egress let --mesh-net ${bad} through (rc=${RC})"; fi
    done
done

echo "== no_egress_argv_test: ${PASS} passed, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ]

#!/usr/bin/env bash
# test-btf-kconfig-resolve.sh — does the BTF block in a hardened-k8s.config fragment
# actually SURVIVE `make olddefconfig` on a real kernel tree?
#
# test-btf-pahole-pairing.sh (pure text, runs everywhere) proves the fragment, the
# package lists and the builder guards agree with each other. It cannot prove that
# Kconfig keeps the symbols: DEBUG_INFO_BTF has a dependency chain (DEBUG_INFO, a
# DWARF choice, pahole >= 1.22 at configure time, no struct randomisation) and a
# broken link in it makes olddefconfig drop BTF with no message. This script resolves
# the real fragment against a real tree and reads the answer out of .config.
#
# NEEDS a kernel SOURCE tree, so it is NOT part of the offline static lint set and it
# does NOT skip silently: with no tree it exits 2.
#
#   tests/scripts/test-btf-kconfig-resolve.sh <kernel-source-tree>
#
# It resolves specs-x86/kernel/hardened-k8s.config against that tree's x86 `make
# defconfig`. It proves NOTHING about the rpi5 fragment, and there is deliberately no
# arm64 mode: the image builds from raspberrypi-sources and its own board defconfig,
# and against the mainline arm64 defconfig even the already-merged CONFIG_BPF_LSM line
# is pruned (CONFIG_KPROBES is off there, so BPF_EVENTS and BPF_LSM do not resolve),
# which would grade the wrong kernel. build-rpi5-stage4.sh's post-olddefconfig guard is
# what enforces BTF on the real tree.
#
# The tree is only read: everything is built out of tree (O=) under ${TMPDIR:-/var/tmp},
# so point TMPDIR at a filesystem with room. Needs gcc, make, flex, bison and pahole.
#
# Three resolves per run, because a test that cannot fail proves nothing:
#   1) the fragment as shipped          -> BTF, BTF_MODULES, BPF_LSM and bpf in CONFIG_LSM
#   2) same, pahole made unavailable    -> BTF must be DROPPED (control: pahole matters)
#   3) same, RANDSTRUCT_FULL added      -> BTF must be DROPPED (control: the trade-off)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

TREE="${1:-}"
if [ -z "${TREE}" ] || [ ! -f "${TREE}/scripts/config" ] || [ ! -f "${TREE}/Makefile" ]; then
    echo "  FAIL usage: $0 <kernel-source-tree>  (no usable tree: '${TREE}')"
    exit 2
fi
FRAG="${REPO}/specs-x86/kernel/hardened-k8s.config"
for t in gcc make flex bison pahole; do
    command -v "${t}" >/dev/null 2>&1 || { echo "  FAIL ${t} not installed (Kconfig needs it to resolve)"; exit 2; }
done
[ -f "${FRAG}" ] || { echo "  FAIL fragment ${FRAG} missing"; exit 2; }

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

WORK="$(mktemp -d "${TMPDIR:-/var/tmp}/btf-resolve.XXXXXX")" || exit 2
trap 'rm -rf "${WORK}"' EXIT

# resolve <name> <pahole-binary> [extra scripts/config args...]
# Mirrors the builders: defconfig, apply each non-comment fragment line through
# scripts/config, olddefconfig. Leaves ${WORK}/<name>/.config.
resolve() {
    local name="$1" pahole="$2"; shift 2
    local out="${WORK}/${name}" line action rest
    mkdir -p "${out}"
    make -s -C "${TREE}" O="${out}" PAHOLE="${pahole}" defconfig >/dev/null 2>&1 \
        || { bad "${name}: make defconfig failed on ${TREE}"; return 1; }
    while IFS= read -r line; do
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        read -r action rest <<< "${line}"
        eval "${TREE}/scripts/config --file ${out}/.config --${action} ${rest}"
    done < "${FRAG}"
    local extra
    for extra in "$@"; do
        eval "${TREE}/scripts/config --file ${out}/.config ${extra}"
    done
    make -s -C "${TREE}" O="${out}" PAHOLE="${pahole}" olddefconfig >/dev/null 2>&1 \
        || { bad "${name}: make olddefconfig failed on ${TREE}"; return 1; }
}
val() { sed -n "s/^$2=\(.*\)\$/\1/p" "${WORK}/$1/.config"; }

echo "== BTF survives olddefconfig: x86 fragment vs ${TREE} =="

echo "-- 1) the fragment as shipped --"
if resolve shipped pahole; then
    [ "$(val shipped CONFIG_DEBUG_INFO_BTF)" = y ] \
        && ok "CONFIG_DEBUG_INFO_BTF=y after olddefconfig" || bad "CONFIG_DEBUG_INFO_BTF dropped by olddefconfig"
    [ "$(val shipped CONFIG_DEBUG_INFO_BTF_MODULES)" = y ] \
        && ok "CONFIG_DEBUG_INFO_BTF_MODULES=y after olddefconfig" || bad "CONFIG_DEBUG_INFO_BTF_MODULES dropped by olddefconfig"
    [ "$(val shipped CONFIG_BPF_LSM)" = y ] \
        && ok "CONFIG_BPF_LSM=y after olddefconfig" || bad "CONFIG_BPF_LSM dropped by olddefconfig"
    case ",$(val shipped CONFIG_LSM | tr -d '"')," in
        *,bpf,*) ok "CONFIG_LSM still names bpf: $(val shipped CONFIG_LSM)" ;;
        *)       bad "CONFIG_LSM lost bpf: $(val shipped CONFIG_LSM)" ;;
    esac
    pv="$(val shipped CONFIG_PAHOLE_VERSION)"
    if [ -n "${pv}" ] && [ "${pv}" -ge 122 ] 2>/dev/null; then
        ok "CONFIG_PAHOLE_VERSION=${pv} (BTF needs >= 122)"
    else
        bad "CONFIG_PAHOLE_VERSION='${pv}' (BTF needs >= 122)"
    fi
fi

echo "-- 2) control: pahole unavailable at configure time drops BTF --"
if resolve nopahole /nonexistent/pahole; then
    [ "$(val nopahole CONFIG_DEBUG_INFO_BTF)" != y ] \
        && ok "without pahole CONFIG_DEBUG_INFO_BTF is dropped (so the builder guard has something to catch)" \
        || bad "BTF survived with no pahole — this resolve cannot tell a pahole-less build from a good one"
fi

echo "-- 3) control: struct layout randomisation drops BTF --"
if resolve randstruct pahole "--enable CONFIG_RANDSTRUCT_FULL"; then
    [ "$(val randstruct CONFIG_DEBUG_INFO_BTF)" != y ] \
        && ok "with RANDSTRUCT_FULL CONFIG_DEBUG_INFO_BTF is dropped (randstruct and bpf-LSM enforcement are mutually exclusive)" \
        || bad "BTF survived RANDSTRUCT_FULL — the trade-off documented in the fragment is not what this tree does"
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

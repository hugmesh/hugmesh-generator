#!/usr/bin/env bash
# test-x86-kernel-net-symbols.sh — offline fragment-lint for the x86 kernel
# hardened-k8s.config netfilter/NAT/eBPF surface that makes k8s Service
# networking (ClusterIP / kube-proxy / CNI overlay / NetworkPolicy) work.
#
# REQUIREMENT: specs-x86/kernel/hardened-k8s.config used to be a TRUNCATED copy of
# the Pi reference (specs-rpi5/kernel/hardened-k8s.config) — it had the CORE
# enablers but was MISSING the entire xtables match/target layer, the nft NAT/MASQ/
# CT expressions, NF_NAT_MASQUERADE, the IPv6 netfilter tables, and IP_NF_MANGLE.
# That left ClusterIP/NodePort/MASQUERADE/dual-stack/NetworkPolicy DEAD on x86.
#
# This test proves WITHOUT a cross-build that:
#   1) the x86 fragment carries every required arch-neutral net/cgroup/overlay/bpf
#      symbol as `enable` (=> CONFIG_FOO=y), the SAME load-bearing set the build
#      guard asserts post-olddefconfig;
#   2) NO ARM/Pi-only symbol leaked into the x86 fragment (RP1/VC4/V3D/PL011/
#      ARM64_*/CRYPTO_AES_ARM64_CE/NET_9P*);
#   3) BTF stays OUT of BOTH fragments (eBPF CO-RE is a separate, toolchain-gated
#      follow-up — adding it without dev-util/pahole breaks the build);
#   4) the build guard in build-x86-host-stage4.sh (and its Pi mirror) greps the
#      FULL load-bearing set (guard == fragment, NOT a subset — olddefconfig
#      prunes per-leaf), so an olddefconfig prune of ANY required symbol FAILS
#      the build instead of silently shipping a dead-network/dead-IPC kernel;
#   5) the x86 and Pi guards cover an IDENTICAL symbol set (no mirror drift).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
X86_FRAG="${REPO}/specs-x86/kernel/hardened-k8s.config"
PI_FRAG="${REPO}/specs-rpi5/kernel/hardened-k8s.config"
X86_BUILD="${REPO}/build-x86-host-stage4.sh"
PI_BUILD="${REPO}/build-rpi5-stage4.sh"
for f in "${X86_FRAG}" "${PI_FRAG}" "${X86_BUILD}" "${PI_BUILD}"; do
    [ -f "${f}" ] || { echo "  FAIL missing ${f}"; exit 1; }
done

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

echo "== x86 kernel k8s-networking fragment lint =="

# ── 1) Every required arch-neutral net symbol is `enable` (=y) in the x86 frag ──
# This list is the canonical source of truth: it is the union of the 34 symbols
# the fix adds, plus the POSIX_MQUEUE container-IPC parity symbol. The build
# guard (item 4) must assert the FULL set — NOT a subset — because olddefconfig
# prunes per-leaf, so item 4 below asserts guard==fragment coverage.
REQUIRED_NET=(
  CONFIG_NETFILTER_XTABLES
  CONFIG_NETFILTER_XT_MATCH_ADDRTYPE
  CONFIG_NETFILTER_XT_MATCH_COMMENT
  CONFIG_NETFILTER_XT_MATCH_CONNTRACK
  CONFIG_NETFILTER_XT_MATCH_MARK
  CONFIG_NETFILTER_XT_MATCH_MULTIPORT
  CONFIG_NETFILTER_XT_MATCH_STATISTIC
  CONFIG_NETFILTER_XT_TARGET_MARK
  CONFIG_NETFILTER_XT_TARGET_MASQUERADE
  CONFIG_NETFILTER_XT_TARGET_REDIRECT
  CONFIG_NETFILTER_XTABLES_LEGACY
  CONFIG_IP_NF_IPTABLES_LEGACY
  CONFIG_IP6_NF_IPTABLES_LEGACY
  CONFIG_IP_NF_MANGLE
  CONFIG_NF_NAT_MASQUERADE
  CONFIG_NF_TABLES_IPV4
  CONFIG_NF_TABLES_IPV6
  CONFIG_NFT_NAT
  CONFIG_NFT_MASQ
  CONFIG_NFT_CT
  CONFIG_IP6_NF_IPTABLES
  CONFIG_IP6_NF_FILTER
  CONFIG_IP6_NF_NAT
  CONFIG_IP6_NF_MANGLE
  CONFIG_VLAN_8021Q
  CONFIG_NET_L3_MASTER_DEV
  CONFIG_NET_SCH_HTB
  CONFIG_NET_CLS_CGROUP
  CONFIG_CGROUP_NET_CLASSID
  CONFIG_CGROUP_NET_PRIO
  CONFIG_CGROUP_HUGETLB
  CONFIG_CGROUP_PERF
  CONFIG_CGROUP_WRITEBACK
  CONFIG_FAIR_GROUP_SCHED
  CONFIG_OVERLAY_FS_REDIRECT_DIR
  CONFIG_OVERLAY_FS_INDEX
  CONFIG_BPF_EVENTS
  CONFIG_POSIX_MQUEUE
)
miss=0
for s in "${REQUIRED_NET[@]}"; do
    grep -q "^enable ${s}\$" "${X86_FRAG}" || { bad "x86 fragment missing required net symbol: ${s}"; miss=$((miss+1)); }
done
[ "${miss}" -eq 0 ] && ok "x86 fragment carries all ${#REQUIRED_NET[@]} required net/cgroup/overlay/bpf symbols as =y"

# Sanity: every required symbol is ALSO =y on the Pi reference (this fix mirrors it).
pmiss=0
for s in "${REQUIRED_NET[@]}"; do
    grep -q "^enable ${s}\$" "${PI_FRAG}" || { bad "Pi reference missing ${s} (drift — the x86 fix should mirror the Pi)"; pmiss=$((pmiss+1)); }
done
[ "${pmiss}" -eq 0 ] && ok "all required symbols are also =y on the Pi reference fragment (no x86↔Pi drift)"

# ── 2) NO ARM/Pi-only symbol leaked into the x86 fragment ─────────────────────
ARM_ONLY=(
  CONFIG_PCIE_BRCMSTB CONFIG_RP1_PIO CONFIG_DRM_V3D CONFIG_DRM_VC4
  CONFIG_VIDEO_RP1_CFE CONFIG_I2C_DESIGNWARE_PLATFORM CONFIG_SPI_DW_MMIO
  CONFIG_PINCTRL_RP1 CONFIG_SENSORS_RP1_ADC CONFIG_USB_XHCI_PCI
  CONFIG_ARM64_BTI CONFIG_ARM64_PTR_AUTH CONFIG_ARM64_MTE
  CONFIG_CRYPTO_AES_ARM64_CE_BLK CONFIG_SERIAL_AMBA_PL011
  CONFIG_SERIAL_AMBA_PL011_CONSOLE CONFIG_RTC_DRV_PL031
  CONFIG_NET_9P CONFIG_NET_9P_VIRTIO CONFIG_9P_FS
)
leak=0
for s in "${ARM_ONLY[@]}"; do
    grep -qE "^(enable|disable|set-str|set-val) ${s}( |\$)" "${X86_FRAG}" && { bad "ARM/Pi-only symbol leaked into x86 fragment: ${s}"; leak=$((leak+1)); }
done
[ "${leak}" -eq 0 ] && ok "no ARM/Pi-only symbol leaked into the x86 fragment"
# Spot-check the x86 crypto path stayed AES-NI (NOT the ARM64 CE block cipher).
grep -q "^enable CONFIG_CRYPTO_AES_NI_INTEL\$" "${X86_FRAG}" \
    && ok "x86 AES path is CRYPTO_AES_NI_INTEL (ARM64 CE block cipher correctly excluded)" \
    || bad "x86 fragment lost CONFIG_CRYPTO_AES_NI_INTEL"

# ── 3) BTF stays OUT of BOTH fragments (separate toolchain-gated follow-up) ────
btf=0
for f in "${X86_FRAG}" "${PI_FRAG}"; do
    grep -qE "^enable (CONFIG_DEBUG_INFO_BTF|CONFIG_DEBUG_INFO_BTF_MODULES|CONFIG_DEBUG_INFO)\$" "${f}" \
        && { bad "BTF/DEBUG_INFO enabled in ${f} — needs dev-util/pahole; must be a SEPARATE PR"; btf=$((btf+1)); }
done
[ "${btf}" -eq 0 ] && ok "BTF/DEBUG_INFO absent from both fragments (eBPF CO-RE deferred to a pahole-gated follow-up)"

# ── 4) Each build guard greps the FULL load-bearing set (guard == fragment) ───
# olddefconfig prunes per-LEAF, so a surviving parent does NOT protect a dropped
# leaf. A representative SUBSET guard would let an unguarded leaf prune through
# silently — the exact bug this PR exists to stop. So every symbol REQUIRED_NET
# declares (the single source of truth above) MUST appear in BOTH builders'
# `for must in … ; do … exit 1 … done` k8s-node-kernel guard loop. This catches
# future drift in either direction: a symbol added to the fragment/REQUIRED_NET
# but not the guard, or a guard symbol silently dropped.
#
# extract_guard <build-file> — prints the text of the netfilter/NAT guard loop
# (from its `for must in CONFIG_NETFILTER_XTABLES` line through the matching
# `done`), with the shell line-continuation backslashes stripped so each symbol
# token stands alone. Works for both the x86 chroot-heredoc guard (\${must}) and
# the Pi direct-host guard (${must}); we only read the `must in` token list.
extract_guard(){
    awk '/for must in CONFIG_NETFILTER_XTABLES/{g=1} g{print} g&&/done/{exit}' "$1" \
        | tr -d '\\'
}
for build in "${X86_BUILD}" "${PI_BUILD}"; do
    gmiss=0
    guard="$(extract_guard "${build}")"
    [ -n "${guard}" ] || { bad "$(basename "${build}") has no k8s-node-kernel 'for must in' guard loop"; gmiss=$((gmiss+1)); }
    for s in "${REQUIRED_NET[@]}"; do
        # Word-boundary match so CONFIG_NF_NAT does not falsely satisfy
        # CONFIG_NF_NAT_MASQUERADE (substring), and vice-versa.
        echo "${guard}" | grep -qwF "${s}" \
            || { bad "$(basename "${build}") guard does NOT assert required symbol: ${s} (guard must cover the FULL fragment set, not a subset)"; gmiss=$((gmiss+1)); }
    done
    # The guard must actually FAIL the build (exit 1) on a missing symbol, and
    # name it as a k8s node kernel option in the error message.
    echo "${guard}" | grep -qE 'k8s node kernel option .* not enabled after olddefconfig' \
        || { bad "$(basename "${build}") has no fail-closed k8s-node-kernel guard message"; gmiss=$((gmiss+1)); }
    echo "${guard}" | grep -q 'exit 1' || { bad "$(basename "${build}") guard does not exit 1"; gmiss=$((gmiss+1)); }
    [ "${gmiss}" -eq 0 ] && ok "$(basename "${build}") guard asserts ALL ${#REQUIRED_NET[@]} required symbols post-olddefconfig (fail-closed, no subset gap)"
done

# ── 5) Both guards are IDENTICAL in coverage (modulo escaping) ────────────────
# Compare the SORTED set of CONFIG_ tokens each guard's `must in` list contains.
guard_symbols(){ extract_guard "$1" | grep -oE 'CONFIG_[A-Z0-9_]+' | sort -u; }
if diff <(guard_symbols "${X86_BUILD}") <(guard_symbols "${PI_BUILD}") >/dev/null; then
    ok "x86 and Pi guards cover an IDENTICAL symbol set (modulo \${must}/\\\${must} escaping)"
else
    bad "x86 and Pi guard symbol sets DIFFER:"; diff <(guard_symbols "${X86_BUILD}") <(guard_symbols "${PI_BUILD}") | sed 's/^/    /'
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

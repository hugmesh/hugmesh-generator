#!/bin/bash
# _x86-kernel-asserts.sh <role-k8s> [kernel-tree] — the x86 kernel's post-olddefconfig
# hardening asserts, as ONE list with two callers:
#
#   * build-x86-host-stage4.sh, inside the kernel chroot, right after `make olddefconfig`
#     (the builder copies this file to <sysroot>/tmp and runs it there);
#   * scripts/kernel-reconfig-x86.sh apply, after the operator's menuconfig edit has been
#     olddefconfig'd — the same chroot, the same tree, the same refusals.
#
# It used to live inline in the builder's unquoted <<CHROOT heredoc (every runtime `$`
# written `\$`). Moved here, not copied, so an edited config can never pass a SHORTER
# assert list than the one a fresh build passes. tests/scripts/test-x86-kernel-net-symbols.sh,
# test-lsm-posture-honesty.sh and test-btf-pahole-pairing.sh read the x86 guard from this
# file; tests/scripts/test-kernel-reconfig-x86.sh executes it against real .config files.
#
# <role-k8s> is the builder's ROLE_K8S (none | init | join | single-node ...): only
# `none` skips the k8s Service-networking guard. Exit 0 = every assert passed; exit 1
# names the first symbol that did not survive. Reads ./.config in [kernel-tree]
# (default /usr/src/linux). Writes nothing.
set -eo pipefail
ROLE_K8S="${1:?usage: _x86-kernel-asserts.sh <role-k8s> [kernel-tree]}"
cd "${2:-/usr/src/linux}"
[ -f .config ] || { echo "[build-x86] ERROR: no .config in $(pwd) — nothing to assert"; exit 1; }
# Refuse to ship a kernel that silently lost its hardening (e.g. a symbol that
# olddefconfig pruned for an unmet dep). Stable, long-standing KSPP/LSM symbols.
for must in CONFIG_SECURITY_SELINUX CONFIG_STACKPROTECTOR_STRONG CONFIG_FORTIFY_SOURCE CONFIG_HARDENED_USERCOPY; do
    grep -q "^${must}=y" .config || { echo "[build-x86] ERROR: hardened kernel option ${must} not enabled after olddefconfig"; exit 1; }
done
# BOOT-CRITICAL (live ISO + SELinux enforcing): SQUASHFS_XATTR must survive olddefconfig.
# The live squashfs pack PRESERVES security.selinux xattrs (mksquashfs by default, the
# tar2sqfs fallback via tar --xattrs), and since #503 the sysroot is LABELLED at build
# time: slx_label_tree (scripts/_selinux-policy-lib.sh) runs setfiles into it before
# the stage4 tar and again before the squash, and live_label_gate reads the packed
# image back. Nothing relies on a first-boot relabel any more (that one needs KEYS).
# SQUASHFS_XATTR is therefore load-bearing: without it the kernel drops the labels ("squashfs: Xattrs in
# filesystem, these will be ignored") — and on a labeled squashfs that unlabels the
# live root and the enforcing boot DEADLOCKS at OpenRC init-early (proven via QEMU:
# enforcing hangs, enforcing=0 reaches agetty). SQUASHFS_XATTR depends on SQUASHFS,
# so a pruned dep would silently re-strip the labels — fail closed here.
grep -q "^CONFIG_SQUASHFS_XATTR=y" .config || { echo "[build-x86] ERROR: CONFIG_SQUASHFS_XATTR not enabled after olddefconfig — live SELinux-enforcing boot would hang (unlabeled squashfs root)"; exit 1; }
# BOOT-CRITICAL: refuse to ship a kernel whose k8s Service-networking surface
# silently lost a netfilter/NAT/eBPF symbol. The x86 fragment used to be a
# TRUNCATED copy of the Pi one (no xtables match/target layer, no nft NAT/MASQ,
# no NF_NAT_MASQUERADE, no IPv6 nf tables, no IP_NF_MANGLE) which left ClusterIP/
# kube-proxy/MASQUERADE/dual-stack/NetworkPolicy DEAD. Even with the fragment
# fixed, `make olddefconfig` (above) will SILENTLY DROP any symbol whose parent
# dep is unmet on the x86_64 defconfig base — no error, no diff. This loop is the
# only thing that turns that silent prune into a BUILD FAILURE naming the symbol.
# This list is the FULL load-bearing set the fragment adds — NOT a representative
# subset. olddefconfig prunes per-LEAF: a parent (e.g. NETFILTER_XTABLES) can
# survive while a leaf (e.g. NETFILTER_XT_TARGET_REDIRECT, IP6_NF_FILTER,
# NETFILTER_XT_MATCH_MARK/MULTIPORT/STATISTIC, NETFILTER_XT_TARGET_MARK) gets
# silently dropped — shipping a dead path. Asserting only a subset would let such
# a leaf prune through, which is exactly the class of bug this guard exists to
# stop. Keep this list IDENTICAL (modulo shell-var escaping) to the
# build-rpi5-stage4.sh mirror and in sync with
# tests/scripts/test-x86-kernel-net-symbols.sh (which asserts guard==fragment).
# This guard asserts the FULL k8s Service-networking surface (kube-proxy xtables /
# nft NAT / IPVS / CNI overlay / cgroup). It is REQUIRED for a cluster node, but a
# standalone DESKTOP (ROLE_K8S=none) is not a k8s node — it doesn't run kube-proxy
# and legitimately has no k8s fragment, so olddefconfig prunes the legacy xtables
# leaves (e.g. IP_NF_MANGLE, whose legacy parent isn't enabled on the desktop). Skip
# the k8s assertion for non-k8s roles; firewalld (nftables) + docker get the symbols
# they need from hardened-k8s.config regardless, and the hardening/LSM guards below
# still run for every role.
if [ "${ROLE_K8S}" != none ]; then
for must in CONFIG_NETFILTER_XTABLES \
            CONFIG_NETFILTER_XT_MATCH_ADDRTYPE CONFIG_NETFILTER_XT_MATCH_COMMENT \
            CONFIG_NETFILTER_XT_MATCH_CONNTRACK CONFIG_NETFILTER_XT_MATCH_MARK \
            CONFIG_NETFILTER_XT_MATCH_MULTIPORT CONFIG_NETFILTER_XT_MATCH_STATISTIC \
            CONFIG_NETFILTER_XT_TARGET_MARK CONFIG_NETFILTER_XT_TARGET_MASQUERADE \
            CONFIG_NETFILTER_XT_TARGET_REDIRECT \
            CONFIG_NETFILTER_XTABLES_LEGACY CONFIG_IP_NF_IPTABLES_LEGACY \
            CONFIG_IP6_NF_IPTABLES_LEGACY \
            CONFIG_IP_NF_MANGLE CONFIG_NF_NAT CONFIG_NF_NAT_MASQUERADE \
            CONFIG_NF_TABLES CONFIG_NF_TABLES_IPV4 CONFIG_NF_TABLES_IPV6 \
            CONFIG_NF_TABLES_INET \
            CONFIG_NFT_NAT CONFIG_NFT_MASQ CONFIG_NFT_CT \
            CONFIG_IP6_NF_IPTABLES CONFIG_IP6_NF_FILTER CONFIG_IP6_NF_NAT \
            CONFIG_IP6_NF_MANGLE \
            CONFIG_VLAN_8021Q CONFIG_NET_L3_MASTER_DEV CONFIG_NET_SCH_HTB \
            CONFIG_NET_CLS_CGROUP \
            CONFIG_IP_VS CONFIG_VXLAN CONFIG_VETH CONFIG_BRIDGE \
            CONFIG_OVERLAY_FS CONFIG_OVERLAY_FS_REDIRECT_DIR CONFIG_OVERLAY_FS_INDEX \
            CONFIG_CGROUP_NET_CLASSID CONFIG_CGROUP_NET_PRIO CONFIG_CGROUP_HUGETLB \
            CONFIG_CGROUP_PERF CONFIG_CGROUP_WRITEBACK \
            CONFIG_FAIR_GROUP_SCHED \
            CONFIG_BPF_SYSCALL CONFIG_BPF_EVENTS \
            CONFIG_POSIX_MQUEUE; do
    grep -q "^${must}=y" .config || { echo "[build-x86] ERROR: k8s node kernel option ${must} not enabled after olddefconfig (Service/kube-proxy/CNI/container-runtime would be impaired)"; exit 1; }
done
else
    echo "[build-x86] Standalone/non-k8s role (ROLE_K8S=none): skipping the k8s Service-networking kernel guard"
fi
# HOST-FIREWALL kernel guard — EVERY role, k8s or not. The k8s guard above is
# skipped for ROLE_K8S=none, but the host rulesets are not k8s-only: a node runs
# hugmesh-firewall-reconcile + hugmesh-coturn-firewall, and a client desktop built
# with --with-sunshine runs hugmesh-sunshine-firewall. All of them load a
# 'table inet ...', and nf_tables_newtable() refuses a family the kernel was not
# built with (EOPNOTSUPP) — so a kernel without NF_TABLES_INET boots with NO host
# backstop at all. That shipped: the 2026-10-30 backend/frontend/backend-gpu ISOs
# logged "Could not process rule: Operation not supported" for both tables on
# every boot, and the x86_64 defconfig base carries no nf_tables of its own, so
# the fragment is the only source. NFT_CT backs the coturn backstop's
# 'ct state established,related accept' (without it that table is refused too).
for must in CONFIG_NF_TABLES CONFIG_NF_TABLES_INET CONFIG_NF_TABLES_IPV4 CONFIG_NF_TABLES_IPV6 CONFIG_NFT_CT; do
    grep -q "^${must}=y" .config || { echo "[build-x86] ERROR: host-firewall kernel option ${must} not enabled after olddefconfig — every 'table inet' host ruleset (release gate, coturn backstop, sunshine fence) would be refused with EOPNOTSUPP and the node would boot with NO host firewall"; exit 1; }
done
# SELinux only activates if CONFIG_LSM is a clean, well-formed string. lockdown is
# listed FIRST so it engages before any other LSM; a stray quote or wrong order here
# would silently ship SELinux or lockdown DISABLED. Assert the exact intended value.
grep -q '^CONFIG_LSM="lockdown,yama,selinux,bpf"$' .config || { echo "[build-x86] ERROR: CONFIG_LSM malformed (expected lockdown,yama,selinux,bpf); lockdown/SELinux would not activate"; exit 1; }
# ...and every NAME in that string must have its module COMPILED IN. Asserting the
# string alone is structurally blind to the failure that actually shipped: the
# kernel does not diagnose an LSM name it cannot resolve, it initializes a SHORTER
# stack and boots on. The 2026-08-14 pki image asked for
#   lsm=lockdown,yama,selinux,bpf
# and dmesg answered
#   LSM: initializing lsm=lockdown,capability,selinux
# because CONFIG_SECURITY_YAMA and CONFIG_BPF_LSM were never set — two LSMs that
# were pure decoration in the config, the cmdline, the grub.cfg and the signed UKI.
# So derive the required symbols FROM the string: adding a name to CONFIG_LSM
# without its enabling symbol now fails the build instead of shipping a lie.
for _l in $(sed -n 's/^CONFIG_LSM="\(.*\)"$/\1/p' .config | tr ',' ' '); do
    case "${_l}" in
        capability) continue ;;                      # always built in with CONFIG_SECURITY
        lockdown)   _sym=CONFIG_SECURITY_LOCKDOWN_LSM ;;
        yama)       _sym=CONFIG_SECURITY_YAMA ;;
        selinux)    _sym=CONFIG_SECURITY_SELINUX ;;
        bpf)        _sym=CONFIG_BPF_LSM ;;
        apparmor)   _sym=CONFIG_SECURITY_APPARMOR ;;
        loadpin)    _sym=CONFIG_SECURITY_LOADPIN ;;
        safesetid)  _sym=CONFIG_SECURITY_SAFESETID ;;
        landlock)   _sym=CONFIG_SECURITY_LANDLOCK ;;
        integrity)  _sym=CONFIG_INTEGRITY ;;
        *) echo "[build-x86] ERROR: CONFIG_LSM names '${_l}', which this guard cannot verify — add its enabling CONFIG_* symbol to the case above"; exit 1 ;;
    esac
    grep -q "^${_sym}=y$" .config || { echo "[build-x86] ERROR: CONFIG_LSM names '${_l}' but ${_sym} is not =y after olddefconfig — the kernel would SILENTLY DROP it from the LSM stack"; exit 1; }
done
# BTF is what lets a BPF_PROG_TYPE_LSM program attach to the bpf LSM that CONFIG_LSM
# names. olddefconfig drops CONFIG_DEBUG_INFO_BTF silently when dev-util/pahole is
# missing at configure time or when a struct-randomisation choice is on, so assert it
# survived rather than ship a kernel whose bpf LSM registers but cannot enforce.
for must in CONFIG_DEBUG_INFO_BTF CONFIG_DEBUG_INFO_BTF_MODULES; do
    grep -q "^${must}=y$" .config || { echo "[build-x86] ERROR: ${must} not enabled after olddefconfig — dev-util/pahole missing at configure time, or struct layout randomisation is on (BTF depends on it being off); a BPF_PROG_TYPE_LSM program could not attach"; exit 1; }
done

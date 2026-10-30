#!/usr/bin/env bash
# test-x86-boot-firewall-snort.sh — pins the three defects the 2026-10-30 x86
# ISO boot tests (backend / frontend / backend-gpu) found on EVERY boot:
#
#   (1) FIREWALL. Both host backstops (hugmesh_release_gate, hugmesh_coturn_relay)
#       failed `nft -f` with "Could not process rule: Operation not supported" —
#       even for the empty `table inet X {}`. The built kernel's .config read
#       "# CONFIG_NF_TABLES_INET is not set": the x86_64 defconfig base carries no
#       nf_tables, the fragment never asked for the inet family, and the kernel's
#       nf_tables_newtable() answers EOPNOTSUPP for a family it was not built with.
#       The reconcilers then logged "keeping the existing ruleset (fail-closed)"
#       and exited 0 — with NO ruleset loaded, i.e. fail-OPEN, and the OpenRC
#       oneshot showed [ ok ].
#   (2) SNORT. "ERROR: snort failed to start": the package conf.d names
#       SNORT_IFACE="eth1" (no image has one), and /usr/bin/snort NEEDS
#       libdaq.so.2 while net-libs/daq was never installed (the ebuild only
#       BDEPENDs it; a binpkg merge never pulls a BDEPEND).
#   (3) HOSTNAME. backend-gpu booted as the legacy "hugmesh-host" while every
#       other node booted as hugmesh-<role>.
#
# Sections:
#   A  every nft feature the SHIPPED rulesets use (rendered by running the real
#      renderers against an nft stub, not grepped from source) has its kernel
#      symbol enabled in the x86 AND Pi fragments and asserted by a build guard
#      that runs for EVERY role (the x86 k8s guard skips ROLE_K8S=none);
#   B  the reconcilers are honest: no table live => ERROR + .unprotected mark +
#      exit 1; failed reload over a live table => keep it, exit 0; success is
#      confirmed with `nft list table` and clears the mark; nft missing => exit 1;
#   C  snort: uplink resolution (stubbed `ip` + fake sysfs), the shipped conf.d,
#      the DAQ config, and net-libs/daq riding the SAME PKGS gate as snort;
#   D  hostname: every x86 cluster-node role bakes ${BRAND}-${ROLE}.
#
# Offline, no root, no network; bash + coreutils + awk + python3 (stdlib).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
X86_FRAG="${REPO}/specs-x86/kernel/hardened-k8s.config"
PI_FRAG="${REPO}/specs-rpi5/kernel/hardened-k8s.config"
X86_BUILD="${REPO}/build-x86-host-stage4.sh"
PI_BUILD="${REPO}/build-rpi5-stage4.sh"
GATE="${REPO}/specs/usr/sbin/hugmesh-firewall-reconcile"
COTURN="${REPO}/specs/usr/sbin/hugmesh-coturn-firewall"
SUNSHINE="${REPO}/specs/usr/sbin/hugmesh-sunshine-firewall"
VPNMARK="${REPO}/specs/usr/sbin/hugmesh-vpn-mark"
GATE_INIT="${REPO}/specs/etc/init.d/hugmesh-firewall-reconcile"
COTURN_INIT="${REPO}/specs/etc/init.d/hugmesh-coturn-firewall"
UPLINK="${REPO}/specs/usr/lib/hugmesh/snort-uplink"
SNORT_CONFD="${REPO}/specs/etc/conf.d/snort"
SNORT_CONF="${REPO}/specs/etc/snort/snort.conf"
ROLES_LIB="${REPO}/scripts/_roles-lib.sh"
CATALOG_PY="${REPO}/studio/hugmesh_studio/core/package_catalog.py"
for f in "${X86_FRAG}" "${PI_FRAG}" "${X86_BUILD}" "${PI_BUILD}" "${GATE}" "${COTURN}" \
         "${SUNSHINE}" "${VPNMARK}" "${GATE_INIT}" "${COTURN_INIT}" "${UPLINK}" \
         "${SNORT_CONFD}" "${SNORT_CONF}" "${ROLES_LIB}" "${CATALOG_PY}"; do
    [ -f "${f}" ] || { echo "  FAIL missing SUT: ${f}"; exit 1; }
done

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

W="$(mktemp -d)"; trap 'rm -rf "${W}"' EXIT

# A minimal PATH of real tools, so "nft missing" really means missing even on a
# host (or CI image) that has /usr/sbin/nft installed.
SYS="${W}/sysbin"; mkdir -p "${SYS}"
for t in bash sh date mktemp cat rm mkdir cp tr head dirname awk grep sed sort xargs paste printf env ls wc echo; do
    # type -P: the FILE, even for names bash also has as builtins (echo, printf) —
    # xargs and env exec the file, and would fail without it.
    p="$(type -P "${t}" 2>/dev/null)" && [ -n "${p}" ] && ln -sf "${p}" "${SYS}/${t}"
done

# nft stub. NFT_LOAD=ok|fail  NFT_LIST=present|absent  NFT_CAPTURE=<dir> (each
# `-f` ruleset is copied there, numbered).
STUB="${W}/stub"; mkdir -p "${STUB}"
cat > "${STUB}/nft" <<'EOF'
#!/bin/bash
if [ "$1" = "-f" ]; then
    if [ -n "${NFT_CAPTURE:-}" ]; then
        n=$(ls "${NFT_CAPTURE}" 2>/dev/null | wc -l)
        cp "$2" "${NFT_CAPTURE}/r$((n + 1)).nft"
    fi
    if [ "${NFT_LOAD:-ok}" = ok ]; then exit 0; fi
    echo "${2}:9:1-35: Error: Could not process rule: Operation not supported" >&2
    exit 1
fi
if [ "$1" = "list" ]; then [ "${NFT_LIST:-present}" = present ]; exit $?; fi
if [ "$1" = "delete" ]; then exit 0; fi
exit 0
EOF
chmod +x "${STUB}/nft"

# ═════════════════════════════════════════════════════════════════════════════
echo "== A) every nft feature the shipped rulesets use is in the kernel =="
CAP="${W}/rendered"; mkdir -p "${CAP}"
ST="${W}/state"; mkdir -p "${ST}"
rg_env=(HUGMESH_RELEASE_STATE_FILE="${ST}/release-state" HUGMESH_GO_LIVE_MARKER="${ST}/go-live"
        HUGMESH_RELEASE_GATE_RULESET="${ST}/nftables.conf" HUGMESH_FIREWALL_HEALTH_DIR="${ST}/health")
# release gate: INTERNAL then PUBLIC
env "${rg_env[@]}" NFT_CAPTURE="${CAP}" PATH="${STUB}:${SYS}" bash "${GATE}" >/dev/null 2>&1
touch "${ST}/go-live"
env "${rg_env[@]}" NFT_CAPTURE="${CAP}" PATH="${STUB}:${SYS}" bash "${GATE}" >/dev/null 2>&1
# coturn: CLOSED then OPEN
env HUGMESH_COTURN_PUBLIC_MARKER="${ST}/coturn-public" HUGMESH_FIREWALL_HEALTH_DIR="${ST}/health" \
    NFT_CAPTURE="${CAP}" PATH="${STUB}:${SYS}" bash "${COTURN}" >/dev/null 2>&1
touch "${ST}/coturn-public"
env HUGMESH_COTURN_PUBLIC_MARKER="${ST}/coturn-public" HUGMESH_FIREWALL_HEALTH_DIR="${ST}/health" \
    NFT_CAPTURE="${CAP}" PATH="${STUB}:${SYS}" bash "${COTURN}" >/dev/null 2>&1
# sunshine fence
env HUGMESH_SUNSHINE_FENCE_STATE="${ST}/sunshine.state" NFT_CAPTURE="${CAP}" PATH="${STUB}:${SYS}" \
    bash "${SUNSHINE}" >/dev/null 2>&1
# vpn-mark with one marked slug and one running in-CIDR pod (so the mark rule renders)
cat > "${STUB}/kubectl" <<'EOF'
#!/bin/bash
case " $* " in
    *" label "*) exit 0 ;;
    *"app.kubernetes.io/name=svc1"*) printf 'pod-a 10.244.1.5 Running\n'; exit 0 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "${STUB}/kubectl"
echo "svc1" > "${ST}/marked"
env MARKED_SERVICES="${ST}/marked" VM_NFT="${STUB}/nft" VM_KUBECTL="${STUB}/kubectl" \
    NFT_CAPTURE="${CAP}" PATH="${STUB}:${SYS}" bash "${VPNMARK}" apply >/dev/null 2>&1

nrend="$(ls "${CAP}" | wc -l)"
# 2 gate + 2 coturn + 1 sunshine + 1 vpn-mark. Fewer means a renderer stopped
# rendering and everything below would pass VACUOUSLY over a smaller corpus.
if [ "${nrend}" -ge 6 ]; then
    ok "rendered ${nrend} rulesets from the 4 shipped renderers (gate x2, coturn x2, sunshine, vpn-mark)"
else
    bad "only ${nrend} rulesets rendered (want >= 6) — the feature scan below would be vacuous"
fi
grep -lq 'hugmesh_vpn' "${CAP}"/*.nft 2>/dev/null && grep -q 'meta mark set' "${CAP}"/*.nft \
    && ok "vpn-mark rendered its mark rule (meta mark set) — the corpus is not just empty tables" \
    || bad "vpn-mark ruleset (with its 'meta mark set' rule) missing from the rendered corpus"

# Strip comments, then map each feature present to the kernel symbol(s) it needs.
# Core expressions (payload/cmp/meta/counter/lookup/range/immediate/bitwise/
# byteorder/dynset/objref) are built into NF_TABLES itself in 6.x and need no map.
body="$(cat "${CAP}"/*.nft | sed -e 's/#.*$//')"
need=(CONFIG_NF_TABLES)
feat(){ # $1 = ERE over the rule text, rest = required symbols
    local re="$1"; shift
    if grep -Eq "${re}" <<<"${body}"; then need+=("$@"); fi
}
feat '(^|[[:space:]])table[[:space:]]+inet[[:space:]]'     CONFIG_NF_TABLES_INET CONFIG_NF_TABLES_IPV4 CONFIG_NF_TABLES_IPV6
feat '(^|[[:space:]])table[[:space:]]+ip[[:space:]]'       CONFIG_NF_TABLES_IPV4
feat '(^|[[:space:]])table[[:space:]]+ip6[[:space:]]'      CONFIG_NF_TABLES_IPV6
feat '(^|[[:space:]])table[[:space:]]+bridge[[:space:]]'   CONFIG_NF_TABLES_BRIDGE
feat '(^|[[:space:]])table[[:space:]]+netdev[[:space:]]'   CONFIG_NF_TABLES_NETDEV
feat '(^|[[:space:]])table[[:space:]]+arp[[:space:]]'      CONFIG_NF_TABLES_ARP
feat '(^|[[:space:]])ct[[:space:]]+(state|status|mark|zone|direction|helper|original|reply|label|expectation)' CONFIG_NFT_CT
feat '(^|[[:space:]])ct[[:space:]]+count'                  CONFIG_NFT_CONNLIMIT
feat 'type[[:space:]]+nat[[:space:]]+hook|(^|[[:space:]])(snat|dnat)[[:space:]]' CONFIG_NFT_NAT
feat '(^|[[:space:]])masquerade([[:space:];]|$)'           CONFIG_NFT_MASQ
feat '(^|[[:space:]])redirect([[:space:];]|$)'             CONFIG_NFT_REDIR
feat '(^|[[:space:]])fib[[:space:]]'                       CONFIG_NFT_FIB_INET CONFIG_NFT_FIB_IPV4 CONFIG_NFT_FIB_IPV6
feat '(^|[[:space:]])reject([[:space:];]|$)'               CONFIG_NFT_REJECT
feat '(^|[[:space:]])limit[[:space:]]+rate'                CONFIG_NFT_LIMIT
feat '(^|[[:space:]])log([[:space:];]|$)'                  CONFIG_NFT_LOG
feat '(^|[[:space:]])quota[[:space:]]'                     CONFIG_NFT_QUOTA
feat '(^|[[:space:]])numgen[[:space:]]'                    CONFIG_NFT_NUMGEN
feat '(^|[[:space:]])(jhash|symhash)[[:space:]]'           CONFIG_NFT_HASH
feat '(^|[[:space:]])socket[[:space:]]'                    CONFIG_NFT_SOCKET
feat '(^|[[:space:]])tproxy[[:space:]]'                    CONFIG_NFT_TPROXY
feat '(^|[[:space:]])queue([[:space:];]|$)'                CONFIG_NFT_QUEUE
mapfile -t need < <(printf '%s\n' "${need[@]}" | sort -u)
grep -Eq '(^|[[:space:]])table[[:space:]]+inet[[:space:]]' <<<"${body}" \
    && ok "the corpus uses 'table inet' (the family the 2026-10-30 kernel lacked)" \
    || bad "no 'table inet' in the rendered corpus — the renderers changed shape; re-derive this suite"
echo "     features need: ${need[*]}"

# The x86 ALL-ROLES host-firewall guard: the `for must in CONFIG_NF_TABLES ...`
# loop that sits OUTSIDE the ROLE_K8S if-block (the k8s guard is skipped for
# ROLE_K8S=none, yet a client desktop with --with-sunshine loads a 'table inet').
hfw_guard="$(awk '/^# HOST-FIREWALL kernel guard/{g=1} g{print} g&&/^done$/{exit}' "${X86_BUILD}")"
[ -n "${hfw_guard}" ] && ok "x86 builder carries the all-roles HOST-FIREWALL kernel guard block" \
    || bad "x86 builder has no '# HOST-FIREWALL kernel guard' block"
# It must not be nested in the k8s guard's `if [ "${ROLE_K8S}" != none ]`: the line
# after the k8s branch's closing `fi` must lead into it.
python3 - "${X86_BUILD}" <<'PY' && ok "the x86 HOST-FIREWALL guard runs for EVERY role (after the ROLE_K8S if/else/fi, not inside it)" || bad "the x86 HOST-FIREWALL guard is nested inside the ROLE_K8S branch (standalone/sunshine desktops would skip it)"
import sys
L = open(sys.argv[1]).read().split("\n")
i = next(n for n, l in enumerate(L) if l.startswith("# HOST-FIREWALL kernel guard"))
k = next(n for n, l in enumerate(L) if 'skipping the k8s Service-networking kernel guard' in l)
assert k < i, "guard precedes the k8s branch"
between = [l for l in L[k + 1:i] if l.strip()]
assert between == ["fi"], between
PY
grep -q 'exit 1' <<<"${hfw_guard}" && grep -q 'not enabled after olddefconfig' <<<"${hfw_guard}" \
    && ok "the HOST-FIREWALL guard fails the build (exit 1) naming the pruned symbol" \
    || bad "the HOST-FIREWALL guard does not fail the build"
pi_guard="$(awk '/for must in CONFIG_NETFILTER_XTABLES/{g=1} g{print} g&&/done/{exit}' "${PI_BUILD}" | tr -d '\\')"
for s in "${need[@]}"; do
    miss=""
    grep -qx "enable ${s}" "${X86_FRAG}" || miss="${miss} x86-fragment"
    grep -qx "enable ${s}" "${PI_FRAG}"  || miss="${miss} pi-fragment"
    grep -qwF "${s}" <<<"${hfw_guard}" || miss="${miss} x86-all-roles-guard"
    grep -qwF "${s}" <<<"${pi_guard}" || miss="${miss} pi-guard"
    [ -z "${miss}" ] && ok "${s}: enabled in both fragments + asserted by the x86 all-roles AND Pi guards" \
        || bad "${s} (used by a shipped ruleset) missing from:${miss}"
done

# ═════════════════════════════════════════════════════════════════════════════
echo "== B) the reconcilers are honest about a MISSING ruleset =="
# run_rc <script> <case-dir> [VAR=val ...] — runs with the stub, prints exit code.
run_rc(){
    local script="$1" d="$2"; shift 2
    mkdir -p "${d}"
    env HUGMESH_RELEASE_STATE_FILE="${d}/release-state" HUGMESH_GO_LIVE_MARKER="${d}/go-live" \
        HUGMESH_RELEASE_GATE_RULESET="${d}/nftables.conf" HUGMESH_COTURN_PUBLIC_MARKER="${d}/coturn-public" \
        HUGMESH_FIREWALL_HEALTH_DIR="${d}/health" "$@" bash "${script}" > "${d}/out" 2>&1
    echo $?
}
for pair in "release-gate:${GATE}:hugmesh_release_gate" "coturn:${COTURN}:hugmesh_coturn_relay"; do
    name="${pair%%:*}"; rest="${pair#*:}"; script="${rest%%:*}"; table="${rest##*:}"
    mark_rel="health/${table}.unprotected"

    # B1: the 2026-10-30 boot — load refused, NO table of ours exists.
    d="${W}/b-${name}-absent"
    rc="$(run_rc "${script}" "${d}" PATH="${STUB}:${SYS}" NFT_LOAD=fail NFT_LIST=absent)"
    [ "${rc}" = 1 ] && ok "${name}: load refused + NO table => exit 1 (the oneshot goes red)" \
        || bad "${name}: load refused + NO table => exit ${rc} (want 1 — exit 0 is the fail-open lie that shipped)"
    [ -s "${d}/${mark_rel}" ] && grep -q "^table=inet ${table}$" "${d}/${mark_rel}" \
        && ok "${name}: writes the ${table}.unprotected node-health mark" \
        || bad "${name}: no ${mark_rel} mark written"
    grep -q 'UNPROTECTED' "${d}/out" && ! grep -q 'keeping the existing ruleset' "${d}/out" \
        && ok "${name}: logs UNPROTECTED, never 'keeping the existing ruleset (fail-closed)'" \
        || bad "${name}: log still claims fail-closed with nothing loaded ($(tr '\n' ' ' < "${d}/out" | cut -c1-160))"
    grep -q 'Operation not supported' "${d}/out" \
        && ok "${name}: the kernel's refusal reason is carried into the log" \
        || bad "${name}: nft's error text was dropped from the log"

    # B2: reload refused, but an EARLIER table is live => keep it, exit 0, no mark.
    d="${W}/b-${name}-present"
    rc="$(run_rc "${script}" "${d}" PATH="${STUB}:${SYS}" NFT_LOAD=fail NFT_LIST=present)"
    [ "${rc}" = 0 ] && [ ! -e "${d}/${mark_rel}" ] && grep -q 'keeping the existing ruleset' "${d}/out" \
        && ok "${name}: reload refused over a LIVE table => keeps it, exit 0, no unhealthy mark" \
        || bad "${name}: reload refused over a live table => rc=${rc}, mark=$([ -e "${d}/${mark_rel}" ] && echo yes || echo no) (want 0/no)"

    # B3: success clears a stale mark.
    d="${W}/b-${name}-ok"; mkdir -p "${d}/health"; echo stale > "${d}/${mark_rel}"
    rc="$(run_rc "${script}" "${d}" PATH="${STUB}:${SYS}" NFT_LOAD=ok NFT_LIST=present)"
    [ "${rc}" = 0 ] && [ ! -e "${d}/${mark_rel}" ] \
        && ok "${name}: a confirmed load exits 0 and CLEARS the unhealthy mark" \
        || bad "${name}: a confirmed load => rc=${rc}, mark still present=$([ -e "${d}/${mark_rel}" ] && echo yes || echo no)"

    # B4: nft says success but the table is not there => not trusted.
    d="${W}/b-${name}-ghost"
    rc="$(run_rc "${script}" "${d}" PATH="${STUB}:${SYS}" NFT_LOAD=ok NFT_LIST=absent)"
    [ "${rc}" = 1 ] && [ -s "${d}/${mark_rel}" ] \
        && ok "${name}: 'success' with no table afterwards is NOT trusted (exit 1 + mark)" \
        || bad "${name}: 'success' with no table afterwards => rc=${rc} (want 1 + mark)"

    # B5: nft missing entirely => no backstop => exit 1 + mark.
    d="${W}/b-${name}-nonft"
    rc="$(run_rc "${script}" "${d}" PATH="${SYS}")"
    [ "${rc}" = 1 ] && [ -s "${d}/${mark_rel}" ] \
        && ok "${name}: nft missing => exit 1 + mark (was a silent exit 0)" \
        || bad "${name}: nft missing => rc=${rc}, mark=$([ -s "${d}/${mark_rel}" ] && echo yes || echo no) (want 1/yes)"
done
# coturn's firewalld layer must still run when only nft is missing (it is the
# PRIMARY filter on x86 prod), and the script must still exit 1 afterwards.
cat > "${STUB}/firewall-cmd" <<'EOF'
#!/bin/bash
case "$1" in --state) exit 0 ;; --get-default-zone) echo drop; exit 0 ;; esac
for a in "$@"; do case "$a" in --query-port=*|--add-port=*|--remove-port=*) echo "$a" >> "${FWCMD_LOG}" ;; esac; done
exit 1
EOF
chmod +x "${STUB}/firewall-cmd"
FWB="${W}/fwonly"; mkdir -p "${FWB}"; ln -sf "${STUB}/firewall-cmd" "${FWB}/firewall-cmd"
d="${W}/b-coturn-fwonly"
rc="$(run_rc "${COTURN}" "${d}" PATH="${FWB}:${SYS}" FWCMD_LOG="${W}/fwcmd.log")"
[ "${rc}" = 1 ] && grep -q -- '--query-port=3478/udp' "${W}/fwcmd.log" 2>/dev/null \
    && ok "coturn: nft missing still reconciles the firewalld layer, then exits 1" \
    || bad "coturn: nft missing => rc=${rc}, firewalld reconciled=$([ -s "${W}/fwcmd.log" ] && echo yes || echo no) (want 1/yes)"
# The init scripts must not call a failed start "existing ruleset preserved".
for f in "${GATE_INIT}" "${COTURN_INIT}"; do
    m="$(grep -E '^[[:space:]]*eend ' "${f}")"
    grep -q 'UNPROTECTED\|NOT fail-closed' <<<"${m}" && ! grep -qi 'preserved' <<<"${m}" \
        && ok "$(basename "${f}"): the red eend message says UNPROTECTED, not 'preserved'" \
        || bad "$(basename "${f}"): eend message still claims the ruleset was preserved: ${m}"
done

# ═════════════════════════════════════════════════════════════════════════════
echo "== C) snort starts on a fresh node =="
SN="${W}/snort"; mkdir -p "${SN}/bin" "${SN}/sys" "${SN}/pid"
cat > "${SN}/bin/ip" <<'EOF'
#!/bin/bash
# IP_V4_DEFAULT / IP_V6_DEFAULT: the "dev" of each family's default route, or empty.
fam="$1"; shift
[ "$*" = "route show default" ] || exit 1
case "${fam}" in
    -4) [ -n "${IP_V4_DEFAULT:-}" ] && echo "default via 10.0.2.2 dev ${IP_V4_DEFAULT} proto dhcp src 10.0.2.15 metric 100" ;;
    -6) [ -n "${IP_V6_DEFAULT:-}" ] && echo "default via fe80::2 dev ${IP_V6_DEFAULT} proto ra metric 100 pref medium" ;;
esac
exit 0
EOF
chmod +x "${SN}/bin/ip"
mknic(){ mkdir -p "${SN}/sys/$1"; echo "$2" > "${SN}/sys/$1/operstate"; [ "${3:-phys}" = phys ] && mkdir -p "${SN}/sys/$1/device"; return 0; }
upl(){ # $1 = pin, rest = VAR=val
    local pin="$1"; shift
    env HUGMESH_SNORT_IFACE_STATE="${SN}/iface" HUGMESH_SNORT_PIDDIR="${SN}/pid" HUGMESH_SYSFS_NET="${SN}/sys" \
        PATH="${SN}/bin:${SYS}" "$@" sh "${UPLINK}" "${pin}" 2>/dev/null
}
mknic lo unknown virt; mknic enp0s2 up; mknic tailscale0 up virt; mknic eno1 down
got="$(upl auto IP_V4_DEFAULT=enp0s2)"
[ "${got}" = enp0s2 ] && ok "uplink: the IPv4 default-route device (QEMU virtio enp0s2)" || bad "uplink: v4 default enp0s2 => '${got}'"
rm -f "${SN}/iface"
got="$(upl auto IP_V4_DEFAULT=tailscale0 IP_V6_DEFAULT=enp0s2)"
[ "${got}" = enp0s2 ] && ok "uplink: a tailnet exit-node default (tailscale0) is skipped for the real NIC" || bad "uplink: tailscale0 default => '${got}' (want enp0s2)"
rm -f "${SN}/iface"
got="$(upl auto)"
[ "${got}" = enp0s2 ] && ok "uplink: no route yet => the first UP physical NIC" || bad "uplink: no route => '${got}' (want enp0s2)"
rm -f "${SN}/iface"; rm -rf "${SN}/sys/enp0s2"
got="$(upl auto)"
[ "${got}" = any ] && ok "uplink: nothing usable => 'any' (degraded but starts), never a guessed name" || bad "uplink: nothing usable => '${got}' (want any)"
rm -f "${SN}/iface"; mknic enp0s2 up
got="$(upl enp9s0 IP_V4_DEFAULT=enp0s2)"
[ "${got}" = enp9s0 ] && ok "uplink: an operator pin (SNORT_IFACE_PIN) wins" || bad "uplink: pin enp9s0 => '${got}'"
got="$(upl 'eth0;rm -rf /' IP_V4_DEFAULT=enp0s2)"
[ "${got}" = enp0s2 ] && ok "uplink: a malformed pin is ignored (never reaches 'snort -i' or a pidfile path)" || bad "uplink: malformed pin => '${got}'"
# running instance: started on enp0s2, route then moved to eno1 => stop must still find snort_enp0s2.pid
rm -f "${SN}/iface"; upl auto IP_V4_DEFAULT=enp0s2 >/dev/null; : > "${SN}/pid/snort_enp0s2.pid"
got="$(upl auto IP_V4_DEFAULT=eno1)"
[ "${got}" = enp0s2 ] && ok "uplink: while snort runs, stop/reload resolve the interface it was STARTED on" || bad "uplink: running on enp0s2, route moved => '${got}' (stop would miss the pidfile)"
rm -f "${SN}/pid/snort_enp0s2.pid"
got="$(upl auto IP_V4_DEFAULT=eno1)"
[ "${got}" = eno1 ] && ok "uplink: once stopped (no pidfile) the recorded name is not reused" || bad "uplink: stale record => '${got}' (want eno1)"
# The shipped conf.d, sourced the way openrc-run sources it.
confd_copy="${W}/confd"; sed "s|/usr/lib/hugmesh/snort-uplink|${UPLINK}|" "${SNORT_CONFD}" > "${confd_copy}"
rm -f "${SN}/iface"
got="$(env HUGMESH_SNORT_IFACE_STATE="${SN}/iface" HUGMESH_SNORT_PIDDIR="${SN}/pid" HUGMESH_SYSFS_NET="${SN}/sys" \
       IP_V4_DEFAULT=enp0s2 PATH="${SN}/bin:${SYS}" sh -c '. "$1"; printf "%s|%s" "${SNORT_IFACE}" "${SNORT_CONF}"' _ "${confd_copy}")"
[ "${got}" = "enp0s2|/etc/snort/snort.conf" ] && ok "conf.d/snort (sourced): SNORT_IFACE=enp0s2, SNORT_CONF=/etc/snort/snort.conf" \
    || bad "conf.d/snort sourced => '${got}'"
grep -Eq '^[[:space:]]*SNORT_IFACE="?eth[0-9]' "${SNORT_CONFD}" && bad "conf.d/snort hardcodes an ethN interface" \
    || ok "conf.d/snort hardcodes no ethN interface"
grep -qE '^config daq: pcap$' "${SNORT_CONF}" && grep -qE '^config daq_dir: /usr/lib64/daq$' "${SNORT_CONF}" \
    && grep -qE '^config daq_mode: passive$' "${SNORT_CONF}" \
    && ok "snort.conf pins DAQ pcap (opens 'any') from /usr/lib64/daq, passive" \
    || bad "snort.conf lacks 'config daq: pcap' / daq_dir /usr/lib64/daq / daq_mode passive"
grep -qE '^config daq: afpacket' "${SNORT_CONF}" && bad "snort.conf selects afpacket, which cannot open the 'any' fallback" \
    || ok "snort.conf does not select afpacket (incompatible with the 'any' fallback)"
# net-libs/daq rides the SAME gate as net-analyzer/snort (one PKGS line).
sline="$(grep -E '^\$\{SNORT_IDS\}[[:space:]]+&& PKGS=' "${X86_BUILD}")"
grep -q 'net-analyzer/snort' <<<"${sline}" && grep -qw 'net-libs/daq' <<<"${sline}" \
    && ok "x86 builder: net-libs/daq is added on the SAME --snort gate as net-analyzer/snort" \
    || bad "x86 builder: the snort PKGS line does not carry net-libs/daq: ${sline:-<none>}"
python3 - "${CATALOG_PY}" <<'PY' && ok "Studio package catalog: the snort option adds net-libs/daq too" || bad "Studio package catalog: snort adhoc atoms lack net-libs/daq (catalog drifts from the builder)"
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'AdhocAdd\("snort",[^)]*\(([^)]*)\)', s)
assert m and "net-libs/daq" in m.group(1) and "net-analyzer/snort" in m.group(1), m and m.group(1)
PY
# ...and the builder stages our conf.d + the helper inside the snort block.
sblock="$(awk '/^if \$\{SNORT_IDS\}; then$/{g=1} g{print} g&&/^fi$/{exit}' "${X86_BUILD}")"
grep -q 'etc/conf.d/snort"' <<<"${sblock}" && grep -q 'usr/lib/hugmesh/snort-uplink"' <<<"${sblock}" \
    && grep -q 'chmod +x "${SYSROOT}/usr/lib/hugmesh/snort-uplink"' <<<"${sblock}" \
    && ok "x86 builder: the snort block stages conf.d/snort + an executable snort-uplink" \
    || bad "x86 builder: the snort block does not stage conf.d/snort and snort-uplink"

# ═════════════════════════════════════════════════════════════════════════════
echo "== D) every x86 cluster node bakes its ROLE as the hostname =="
hn_bad=0
for r in $(bash -c '. "$1"; echo "${HUGMESH_ROLES_NODE}"' _ "${ROLES_LIB}"); do
    bash -c '. "$1"; hugmesh_role_is_valid "$2" x86 2>/dev/null || case " ${HUGMESH_ROLES_X86} " in *" $2 "*) ;; *) exit 3 ;; esac' _ "${ROLES_LIB}" "${r}" 2>/dev/null
    [ $? -eq 3 ] && continue
    got="$(bash -c '. "$1"; hugmesh_role_hostname x86 "$2" hugmesh' _ "${ROLES_LIB}" "${r}")"
    if [ "${got}" = "hugmesh-${r}" ]; then :; else bad "x86 ${r} bakes hostname '${got}' (want hugmesh-${r})"; hn_bad=$((hn_bad+1)); fi
done
[ "${hn_bad}" -eq 0 ] && ok "every x86 cluster-node role bakes hugmesh-<role> (backend-gpu is hugmesh-backend-gpu, not the legacy hugmesh-host)"
grep -qE '^x86:backend-gpu=' "${ROLES_LIB}" && bad "_roles-lib.sh still carries an x86:backend-gpu hostname exception" \
    || ok "_roles-lib.sh carries no x86:backend-gpu hostname exception"
grep -q '_plan HOSTNAME.*BRAND}-host' "${X86_BUILD}" && bad "x86 builder's plan line still falls back to \${BRAND}-host" \
    || ok "x86 builder's plan line derives the hostname (no \${BRAND}-host literal)"

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

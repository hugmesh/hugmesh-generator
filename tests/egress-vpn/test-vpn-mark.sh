#!/usr/bin/env bash
# test-vpn-mark.sh — unit test for /usr/sbin/hugmesh-vpn-mark (the egress-VPN
# packet-marking leg: marked-services -> fwmark 0x76 nft rules + vpn-egress pod
# labels) and its wiring into the runner/reconcile flows.
#
# Proves, WITHOUT root / a cluster / real nft (recording fake `nft` + `kubectl`
# binaries, the same tool-stub approach as test-split-tunnel.sh's fake `ip`):
#   * apply renders ONE atomic create+flush+redefine transaction for
#     `table inet hugmesh_vpn` only: prerouting/mangle chain, early `return`
#     carve-outs for pod/service/tailnet destinations, and an `ip saddr` set of
#     the resolved RUNNING pod IPs marked `meta mark set 0x76`;
#   * non-Running pods and pods whose IP is OUTSIDE the pod CIDR (hostNetwork/
#     node IP) are NEVER marked;
#   * marks are installed BEFORE any pod is labelled (no loosened-but-uncaptured
#     window), and re-runs are idempotent (byte-identical ruleset);
#   * a MALFORMED marked-services row aborts with ZERO mutation (fail-closed);
#   * a labelling failure rolls back to the fully-cleared state (no half-marked
#     state survives an error);
#   * clear removes the labels and then the whole hugmesh_vpn table; an empty
#     marked-services set clears too;
#   * the runner's `down` invokes the marker's clear BEFORE tearing the routing
#     down, and the reconcile agent invokes apply/clear at the right steps.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MARK="${REPO}/specs/usr/sbin/hugmesh-vpn-mark"
RUNNER="${REPO}/specs/usr/sbin/hugmesh-vpn-runner"
RECONCILE="${REPO}/specs/usr/sbin/hugmesh-vpn-reconcile"
[ -f "${MARK}" ] || { echo "  FAIL marker missing: ${MARK}"; exit 1; }

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bin"
ORDER="${WORK}/order.log"

# ── Fake `nft`: records every invocation + the -f transaction body; keeps a
# present/absent marker so list/delete behave like the real table lifecycle. ──
cat > "${WORK}/bin/fake-nft" <<EOF
#!/usr/bin/env bash
echo "nft \$*" >> "${ORDER}"
case "\$1" in
    -f)     [ -f "${WORK}/fail-nft" ] && { echo "fake-nft: rejected" >&2; exit 1; }
            cp "\$2" "${WORK}/ruleset.last"; : > "${WORK}/nft-present" ;;
    list)   [ -f "${WORK}/nft-present" ] || exit 1 ;;
    delete) rm -f "${WORK}/nft-present" ;;
esac
exit 0
EOF

# ── Fake `kubectl`: serves pod fixtures per label selector, records labelling,
# optionally fails label ADDS (=true) to drive the rollback path. ─────────────
cat > "${WORK}/bin/fake-kubectl" <<EOF
#!/usr/bin/env bash
echo "kubectl \$*" >> "${ORDER}"
verb=""; sel=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        get|label) [ -z "\${verb}" ] && verb="\$1" ;;
        -l)        shift; sel="\$1" ;;
    esac
    shift
done
if [ "\${verb}" = "label" ]; then
    # fail-label-add drives the rollback path: label ADDS (=true) fail, label
    # REMOVES (key-) still succeed so the rollback itself can complete.
    if [ -f "${WORK}/fail-label-add" ] && tail -1 "${ORDER}" | grep -- '=true' >/dev/null; then
        exit 1
    fi
    exit 0
fi
case "\${sel}" in
    app.kubernetes.io/name=coturn)  printf 'coturn-abc 10.244.1.5 Running\ncoturn-xyz 10.244.1.6 Running\n' ;;
    app.kubernetes.io/name=akkoma)  printf 'akkoma-1 10.244.2.9 Running\nakkoma-old 10.244.2.8 Succeeded\n' ;;
    app.kubernetes.io/name=badpods) printf 'bad-1 192.168.1.10 Running\n' ;;
    hugmesh.net/vpn-egress=true*) cat "${WORK}/stale" 2>/dev/null || true ;;
esac
exit 0
EOF
chmod +x "${WORK}/bin/fake-nft" "${WORK}/bin/fake-kubectl"

run_mark() {  # $1 = subcommand
    MARKED_SERVICES="${WORK}/marked-services" \
    VM_NFT="${WORK}/bin/fake-nft" VM_KUBECTL="${WORK}/bin/fake-kubectl" \
    KUBECONFIG_OVERRIDE=/dev/null \
        bash "${MARK}" "$1" >/dev/null 2>&1
}
reset_order() { : > "${ORDER}"; }
RULESET="${WORK}/ruleset.last"

echo "== hugmesh-vpn-mark packet-marking unit test =="

# ── apply: fixture marked-services -> expected nft ruleset + labels ───────────
printf 'coturn,akkoma\n' > "${WORK}/marked-services"
reset_order
run_mark apply && ok "apply exits 0 on a valid marked-services set" || bad "apply failed on a valid set"

grep -qE 'table inet hugmesh_vpn \{\}' "${RULESET}" && grep -q 'flush table inet hugmesh_vpn' "${RULESET}" \
    && ok "one transaction: create-if-missing + flush + redefine (idempotent by construction)" \
    || bad "missing create/flush preamble in the ruleset"
grep -qE 'type filter hook prerouting priority mangle' "${RULESET}" \
    && ok "chain hooks prerouting at mangle priority (mark exists before the routing decision)" \
    || bad "wrong/missing prerouting hook"
grep -qE 'ip daddr 10\.244\.0\.0/16 return' "${RULESET}" \
    && grep -qE 'ip daddr 10\.96\.0\.0/12 return' "${RULESET}" \
    && grep -qE 'ip daddr 100\.64\.0\.0/10 return' "${RULESET}" \
    && ok "cluster + tailnet destinations return early (mirror of the ip-rule carve-outs)" \
    || bad "missing a daddr carve-out"
grep -qE 'ip saddr \{ [^}]*10\.244\.1\.5' "${RULESET}" \
    && grep -qE '10\.244\.1\.6' "${RULESET}" && grep -qE '10\.244\.2\.9' "${RULESET}" \
    && ok "resolved RUNNING pod IPs land in the saddr set" || bad "a running pod IP is missing from the set"
grep -qE 'meta mark set 0x76' "${RULESET}" \
    && ok "matching egress packets are marked 0x76" || bad "missing meta mark set 0x76"
grep -q '10\.244\.2\.8' "${RULESET}" \
    && bad "non-Running pod (Succeeded) was marked" || ok "non-Running pod excluded from the set"
stray="$(grep -E '^[[:space:]]*(table|flush)' "${RULESET}" | grep -v 'hugmesh_vpn' || true)"
if [ -z "${stray}" ] && ! grep -q 'flush ruleset' "${RULESET}"; then
    ok "only table inet hugmesh_vpn is touched (no flush ruleset, no other table)"
else
    bad "ruleset touches beyond hugmesh_vpn: ${stray:-flush ruleset}"
fi

# marks BEFORE labels: the nft -f line precedes the first label add.
nft_line="$(grep -n '^nft -f' "${ORDER}" | head -1 | cut -d: -f1)"
lbl_line="$(grep -n 'label pod .*=true' "${ORDER}" | head -1 | cut -d: -f1)"
if [ -n "${nft_line}" ] && [ -n "${lbl_line}" ] && [ "${nft_line}" -lt "${lbl_line}" ]; then
    ok "marks installed BEFORE labels (no loosened-but-uncaptured pod)"
else
    bad "labels applied before marks (nft@${nft_line:-none} label@${lbl_line:-none})"
fi
grep -q 'label pod coturn-abc hugmesh.net/vpn-egress=true --overwrite' "${ORDER}" \
    && grep -q 'label pod akkoma-1 hugmesh.net/vpn-egress=true --overwrite' "${ORDER}" \
    && ok "assigned pods labelled vpn-egress=true (the NetworkPolicy loosen)" || bad "missing a label add"
grep -q 'label pod akkoma-old' "${ORDER}" \
    && bad "labelled a non-Running pod" || ok "non-Running pod not labelled"

# ── idempotency: a second apply produces a byte-identical transaction ─────────
cp "${RULESET}" "${WORK}/ruleset.first"
reset_order
run_mark apply && ok "re-apply exits 0" || bad "re-apply failed"
cmp -s "${WORK}/ruleset.first" "${RULESET}" \
    && ok "idempotent: re-run renders a byte-identical ruleset" || bad "re-run diverged"

# ── out-of-CIDR pod IP (hostNetwork/node IP) is refused ───────────────────────
printf 'badpods\n' > "${WORK}/marked-services"
reset_order
run_mark apply && ok "apply tolerates a slug whose pods are out-of-CIDR" || bad "apply failed on out-of-CIDR pods"
grep -q '192\.168\.1\.10' "${RULESET}" \
    && bad "node-range IP was marked (would drag host egress into the VPN)" \
    || ok "out-of-pod-CIDR IP refused (node IP never marked)"

# ── fail-closed: a malformed row aborts with ZERO mutation ────────────────────
printf 'coturn,bad;slug!\n' > "${WORK}/marked-services"
reset_order
if run_mark apply; then bad "apply ACCEPTED a malformed marked-services row"; else
    ok "apply rejects a malformed marked-services row"
fi
[ -s "${ORDER}" ] && bad "malformed row still mutated (nft/kubectl were invoked): $(head -1 "${ORDER}")" \
    || ok "malformed row => ZERO nft/kubectl invocations (no half-marked state)"

# ── label failure rolls back to the fully-cleared state ───────────────────────
printf 'coturn\n' > "${WORK}/marked-services"
: > "${WORK}/fail-label-add"
reset_order
if run_mark apply; then bad "apply exited 0 despite a labelling failure"; else
    ok "apply fails when labelling fails"
fi
grep -q 'nft delete table inet hugmesh_vpn' "${ORDER}" \
    && ok "rollback: the mark table is deleted after the failed label" || bad "no rollback delete recorded"
[ -f "${WORK}/nft-present" ] && bad "half-marked state survived the rollback" \
    || ok "no half-marked state after the rollback (table gone, labels off)"
rm -f "${WORK}/fail-label-add"

# ── clear: unlabels (stale pods included) then deletes the whole table ────────
printf 'coturn\n' > "${WORK}/marked-services"
reset_order
run_mark apply >/dev/null 2>&1 || true
printf 'akkoma-1\n' > "${WORK}/stale"
reset_order
run_mark clear && ok "clear exits 0" || bad "clear failed"
grep -q 'label pod akkoma-1 hugmesh.net/vpn-egress-' "${ORDER}" \
    && ok "clear removes the vpn-egress label (NetworkPolicy re-locks the pod)" || bad "clear did not unlabel"
grep -q 'nft delete table inet hugmesh_vpn' "${ORDER}" \
    && ok "clear deletes table inet hugmesh_vpn (teardown removes ALL hugmesh-vpn rules)" || bad "clear left the table"
unlbl_line="$(grep -n 'vpn-egress-' "${ORDER}" | head -1 | cut -d: -f1)"
del_line="$(grep -n 'nft delete table' "${ORDER}" | head -1 | cut -d: -f1)"
if [ -n "${unlbl_line}" ] && [ -n "${del_line}" ] && [ "${unlbl_line}" -lt "${del_line}" ]; then
    ok "clear unlabels BEFORE dropping the marks (never loosened-and-unmarked)"
else
    bad "clear dropped the marks before the labels came off"
fi
rm -f "${WORK}/stale"

# ── empty marked-services set clears ──────────────────────────────────────────
run_mark apply >/dev/null 2>&1 || true          # re-establish the table
: > "${WORK}/marked-services"
reset_order
run_mark apply && ok "apply on an EMPTY set exits 0" || bad "apply on an empty set failed"
[ -f "${WORK}/nft-present" ] && bad "empty set left the mark table installed" \
    || ok "empty set == clear (table removed)"

# ── runner integration: `down` clears marks BEFORE the routing teardown ───────
cat > "${WORK}/bin/fake-marker" <<EOF
#!/usr/bin/env bash
echo "marker \$*" >> "${ORDER}"
exit 0
EOF
cat > "${WORK}/bin/fake-ip" <<EOF
#!/usr/bin/env bash
echo "ip \$*" >> "${ORDER}"
exit 0
EOF
chmod +x "${WORK}/bin/fake-marker" "${WORK}/bin/fake-ip"
reset_order
IP_CMD="${WORK}/bin/fake-ip" MARKER_CMD="${WORK}/bin/fake-marker" VPN_ETC="${WORK}/vpn" \
    bash "${RUNNER}" down >/dev/null 2>&1 || true
mark_line="$(grep -n '^marker clear' "${ORDER}" | head -1 | cut -d: -f1)"
ip_line="$(grep -n '^ip ' "${ORDER}" | head -1 | cut -d: -f1)"
if [ -n "${mark_line}" ] && [ -n "${ip_line}" ] && [ "${mark_line}" -lt "${ip_line}" ]; then
    ok "runner down: marker clear runs BEFORE the ip-rule/table teardown"
else
    bad "runner down did not clear marks first (marker@${mark_line:-none} ip@${ip_line:-none})"
fi

# ── reconcile + builder wiring (source-level, mirrors the gate test's greps) ──
grep -Fq 'MARKER="/usr/sbin/hugmesh-vpn-mark"' "${RECONCILE}" \
    && grep -Fq '"${MARKER}" apply' "${RECONCILE}" \
    && ok "reconcile invokes the marker apply after tunnel-up" || bad "reconcile missing the marker apply"
grep -Fq '"${MARKER}" clear' "${RECONCILE}" \
    && ok "reconcile clears marks on the empty-export teardown" || bad "reconcile missing the teardown clear"
missing=""
for b in "${REPO}"/build-frite-stage4.sh "${REPO}"/build-jetson-stage4.sh \
         "${REPO}"/build-orangepi-zero2-stage4.sh "${REPO}"/build-orangepi-zero2w-stage4.sh \
         "${REPO}"/build-orangepi-zero3-stage4.sh "${REPO}"/build-orangepi3-lts-stage4.sh \
         "${REPO}"/build-orangepi4-lts-stage4.sh "${REPO}"/build-orangepi5-stage4.sh \
         "${REPO}"/build-rpi5-stage4.sh; do
    grep -Fq 'usr/sbin/hugmesh-vpn-mark' "${b}" || missing="${missing} $(basename "${b}")"
done
[ -z "${missing}" ] && ok "all 9 node builders stage hugmesh-vpn-mark (parity)" \
    || bad "builders missing the marker staging:${missing}"

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

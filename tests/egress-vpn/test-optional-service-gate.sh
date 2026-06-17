#!/usr/bin/env bash
# test-optional-service-gate.sh — unit test for the egress-vpn OPTIONAL-SERVICE
# gate in build-rpi5-stage4.sh (PR6).
#
# Proves, WITHOUT a full cross-build, the DEFAULT-OFF gate behaviours by sourcing
# the REAL helper functions (_opt_selected, _opt_drop_kustomize_line) extracted
# from the builder + reproducing the egress-vpn gate branch + the node-package
# filter against a sandbox tree:
#   * egress-vpn registered in optional-services.yaml as default: off;
#   * NOT selected => the NetworkPolicy interaction file + its kustomization line
#     are PRUNED, and net-vpn/{wireguard-tools,openvpn} are dropped from the node
#     package set;
#   * selected => the NetworkPolicy interaction is KEPT, the packages survive, and
#     the reconcile service is linked into the default runlevel.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILDER="${REPO}/build-rpi5-stage4.sh"
REG="${REPO}/specs/cluster/optional-services.yaml"
[ -f "${BUILDER}" ] || { echo "  FAIL builder missing"; exit 1; }

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# ── Extract the REAL helper functions from the builder (so the test tracks them). ─
# _opt_selected + _opt_drop_kustomize_line are small, dependency-free functions.
extract_fn() { awk "/^$1\(\) \{/{p=1} p{print} /^\}/{if(p){exit}}" "${BUILDER}"; }
eval "$(extract_fn _opt_selected)"
eval "$(extract_fn _opt_drop_kustomize_line)"
type _opt_selected >/dev/null 2>&1 || { echo "  FAIL could not extract _opt_selected"; exit 1; }
type _opt_drop_kustomize_line >/dev/null 2>&1 || { echo "  FAIL could not extract _opt_drop_kustomize_line"; exit 1; }

echo "== egress-vpn optional-service gate unit test =="

# ── Registry: egress-vpn present + default off ────────────────────────────────
if command -v python3 >/dev/null; then
  python3 - "${REG}" <<'PY' && ok "registered in optional-services.yaml as default: off" || bad "egress-vpn not registered default:off"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
svcs = {s["slug"]: s for s in d["spec"]["services"]}
ev = svcs.get("egress-vpn")
assert ev is not None, "egress-vpn slug missing"
# YAML `off` parses to False.
assert ev["default"] in (False, "off"), f"default not off: {ev['default']!r}"
assert ev.get("scope") == "node", "scope not node"
assert "net-vpn/wireguard-tools" in ev.get("nodePackages", []), "nodePackages missing wireguard-tools"
assert "snapdragon-vpn-reconcile" in ev.get("nodeServices", []), "nodeServices missing reconcile"
sys.exit(0)
PY
else
  echo "  SKIP registry assertion (no python3)"
fi

# Reproduce the egress-vpn gate branch (mirrors the builder's case + filter).
gate_egress_vpn() {  # $1 = OPTIONAL_SERVICES string ; uses ${tree}
    OPTIONAL_SERVICES="$1"
    if ! _opt_selected egress-vpn; then
        rm -f "${tree}/manifests/networkpolicy/egress-vpn-interaction.yaml"
        _opt_drop_kustomize_line "${tree}/manifests/networkpolicy/kustomization.yaml" egress-vpn-interaction.yaml
    fi
}
filter_pkgs() {  # $1 = OPTIONAL_SERVICES ; reads STAGE4_PACKAGES[], prints kept
    OPTIONAL_SERVICES="$1"
    local kept=() p
    if ! _opt_selected egress-vpn; then
        for p in "${STAGE4_PACKAGES[@]}"; do
            case "${p}" in net-vpn/wireguard-tools|net-vpn/openvpn) ;; *) kept+=("${p}");; esac
        done
    else
        kept=("${STAGE4_PACKAGES[@]}")
    fi
    printf '%s\n' "${kept[@]}"
}

seed_tree() {
    tree="${WORK}/tree-$1"; rm -rf "${tree}"
    mkdir -p "${tree}/manifests/networkpolicy"
    printf 'placeholder\n' > "${tree}/manifests/networkpolicy/egress-vpn-interaction.yaml"
    cat > "${tree}/manifests/networkpolicy/kustomization.yaml" <<'K'
resources:
  - tier-ingress.yaml
  - homeserver-egress.yaml
  - egress-vpn-interaction.yaml
K
}

STAGE4_PACKAGES=(net-misc/networkmanager net-vpn/wireguard-tools net-vpn/openvpn sys-cluster/kubelet)

# ── NOT selected => prune NetworkPolicy + drop packages ───────────────────────
seed_tree off
gate_egress_vpn "akkoma tuwunel"
[ ! -f "${tree}/manifests/networkpolicy/egress-vpn-interaction.yaml" ] \
    && ok "NOT selected: NetworkPolicy interaction file pruned" || bad "interaction file survived"
grep -q 'egress-vpn-interaction.yaml' "${tree}/manifests/networkpolicy/kustomization.yaml" \
    && bad "kustomization line survived" || ok "NOT selected: kustomization line dropped"
# the other resources remain.
grep -q 'homeserver-egress.yaml' "${tree}/manifests/networkpolicy/kustomization.yaml" \
    && ok "NOT selected: unrelated kustomization resources kept" || bad "dropped an unrelated resource"

kept="$(filter_pkgs 'akkoma tuwunel')"
echo "${kept}" | grep -q 'net-vpn/wireguard-tools' && bad "wireguard-tools survived the prune" || ok "NOT selected: net-vpn/wireguard-tools pruned"
echo "${kept}" | grep -q 'net-vpn/openvpn' && bad "openvpn survived the prune" || ok "NOT selected: net-vpn/openvpn pruned"
echo "${kept}" | grep -q 'sys-cluster/kubelet' && ok "NOT selected: unrelated package kept" || bad "dropped an unrelated package"

# ── selected => keep NetworkPolicy + packages ─────────────────────────────────
seed_tree on
gate_egress_vpn "akkoma egress-vpn"
[ -f "${tree}/manifests/networkpolicy/egress-vpn-interaction.yaml" ] \
    && ok "selected: NetworkPolicy interaction file kept" || bad "interaction file was pruned despite selection"
grep -q 'egress-vpn-interaction.yaml' "${tree}/manifests/networkpolicy/kustomization.yaml" \
    && ok "selected: kustomization line kept" || bad "kustomization line dropped despite selection"

kept="$(filter_pkgs 'akkoma egress-vpn')"
echo "${kept}" | grep -q 'net-vpn/wireguard-tools' && ok "selected: net-vpn/wireguard-tools kept" || bad "wireguard-tools pruned despite selection"
echo "${kept}" | grep -q 'net-vpn/openvpn' && ok "selected: net-vpn/openvpn kept" || bad "openvpn pruned despite selection"

# ── builder wires the reconcile service link only when selected ───────────────
# (assert the conditional + the runlevel link exist in the builder source).
grep -q '_opt_selected egress-vpn' "${BUILDER}" && ok "builder gates the reconcile link on _opt_selected egress-vpn" || bad "builder missing the egress-vpn service-link gate"
grep -q 'DEFAULT_SVCS+=(snapdragon-vpn-reconcile)' "${BUILDER}" && ok "builder links snapdragon-vpn-reconcile when selected" || bad "builder missing the reconcile runlevel link"

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

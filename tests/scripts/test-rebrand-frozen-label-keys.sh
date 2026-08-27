#!/usr/bin/env bash
# test-rebrand-frozen-label-keys.sh — the rebrand sed chain must leave FROZEN label
# keys literal in EVERY boundary shape the baked tree actually carries, including
# KEY=VALUE, while still rebranding everything it is meant to rebrand.
#
# THE DEFECT THIS PINS (found 2026-08-27 by a content-level audit; reproduced on
# main 8165b81a with the real function before the fix). All ten build-*-stage4.sh
# carry a copy of rebrand_sysroot(), whose sed chain hides the frozen label-key
# namespace `hugmesh.net/<suffix>` behind a sentinel when it is preceded by a
# "structural boundary" (line-start, space, {, (, comma, quote, backtick), rebrands
# hosts/URLs/emails in the middle, then restores the sentinel. That class did NOT
# contain `=`. specs/cluster/egress-vpn-secret-contract.env is a KEY=VALUE file:
#
#     EGRESS_VPN_SECRET_SELECTOR=hugmesh.net/optional-service=egress-vpn
#     EGRESS_VPN_NODE_LABEL=hugmesh.net/egress-vpn
#
# so on every build with a non-default domain/org/brand both lines were rewritten
# to <org>.net/... while the manifests' `nodeSelector: hugmesh.net/egress-vpn` and
# the projector's SECRET_SEL stayed literal. The env contract and the manifests it
# is "the ONE source of truth" for disagreed on a frozen key, on every fork build,
# and nothing measured it: no test fed an =-preceded key through the chain.
# scripts/tooling/tokens.json (frozen_protocol_constants.label_key_namespaces =
# ["hugmesh.net/"]) says these "must stay literal in every emitted repo".
#
# WHAT THIS SUITE DOES. For EACH builder it extracts the REAL rebrand_sysroot()
# (+ the real _sed_rep_escape it calls) with the test-idp-builder-functions.sh
# idiom, points it at a fixture sysroot and asserts, per builder:
#   * the REAL egress-vpn contract file (copied from specs/cluster) keeps every
#     KEY=hugmesh.net/... line byte-for-byte;
#   * the REAL secret-projector DaemonSet keeps its nodeSelector key and SECRET_SEL,
#     and — the disagreement the defect produced — contract == manifest afterwards;
#   * a boundary MATRIX: every frozen-KEY shape (line-start, space, {, (, comma,
#     quote, backtick, EQUALS, a --flag=) stays literal, and every rebrandable shape
#     (dot/slash-preceded hosts, bare hosts incl. `HOST=hugmesh.net` with no slash,
#     registry project, compound `hugmesh-*` names, the brand title) is rewritten
#     to the expected value — so the fix cannot over-protect;
#   * no sentinel leaks (`@@SDSYSKEY@@` never survives);
#   * the default-branding path is a byte no-op.
# The fixture is checked for NON-VACUITY first: if it carries no =-preceded frozen
# key, the suite fails rather than passing on nothing. And the builder list is
# checked against the tree: a build-*-stage4.sh that defines rebrand_sysroot but is
# not listed here is a failure, so a new board cannot slip out of coverage.
#
# Runs ANYWHERE with bash + sed + awk — NO cross-build, NO root, NO network.
# Mutation-tested (see the commit that added it): removing `=` from ONE builder's
# class, from all ten, dropping the fixture's `=` lines, over-protecting `/`, and
# dropping the domain rule are each caught.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

# Extract a shell function body verbatim from a builder (the idp suite's idiom).
extract_fn() { awk "/^$1\\(\\) \\{/{p=1} p{print} /^\\}/{if(p){exit}}" "$2"; }

# Harmless stubs for the builder helpers rebrand_sysroot calls.
info() { :; }
warn() { :; }
err()  { echo "ERR: $*" >&2; }
banner() { :; }

# EXPLICIT list, never a glob — and the census check right below makes sure the
# list and the tree agree, so a new builder is an error rather than a silent gap.
BUILDERS=(
  build-frite-stage4.sh
  build-jetson-stage4.sh
  build-orangepi-zero2-stage4.sh
  build-orangepi-zero2w-stage4.sh
  build-orangepi-zero3-stage4.sh
  build-orangepi3-lts-stage4.sh
  build-orangepi4-lts-stage4.sh
  build-orangepi5-stage4.sh
  build-rpi5-stage4.sh
  build-x86-host-stage4.sh
)

echo "== census: every builder that defines rebrand_sysroot is covered =="
for b in "${REPO}"/build-*-stage4.sh; do
  bn="$(basename "${b}")"
  grep -q '^rebrand_sysroot() {' "${b}" || continue
  listed=0
  for x in "${BUILDERS[@]}"; do [ "${x}" = "${bn}" ] && listed=1; done
  [ "${listed}" -eq 1 ] && ok "census: ${bn} is in the covered list" \
    || bad "census: ${bn} defines rebrand_sysroot but is NOT covered by this suite"
done

CONTRACT="${REPO}/specs/cluster/egress-vpn-secret-contract.env"
DAEMONSET="${REPO}/specs/cluster/manifests/egress-vpn/secret-projector-daemonset.yaml"
[ -f "${CONTRACT}" ]  || { bad "missing ${CONTRACT}"; }
[ -f "${DAEMONSET}" ] || { bad "missing ${DAEMONSET}"; }

# ── the boundary matrix ───────────────────────────────────────────────────────
# KEEP: frozen label-KEY shapes; must come out byte-identical.
KEEP=(
  'hugmesh.net/egress-vpn: "true"'
  '  hugmesh.net/optional-service: egress-vpn'
  'apiVersion: hugmesh.net/v1'
  '{hugmesh.net/compute: gpu}'
  '(hugmesh.net/storage)'
  'a,hugmesh.net/vpn-config-domain'
  '"hugmesh.net/optional-service=egress-vpn"'
  "'hugmesh.net/vpn-egress'"
  '`hugmesh.net/egress-vpn`'
  'EGRESS_VPN_NODE_LABEL=hugmesh.net/egress-vpn'
  'EGRESS_VPN_SECRET_SELECTOR=hugmesh.net/optional-service=egress-vpn'
  '--selector=hugmesh.net/optional-service=egress-vpn'
)
# REWRITE: rebrandable shapes -> what they must become under the test branding
# (BRAND=acme, BRAND_TITLE="Acme Mesh", CLUSTER_DOMAIN=example.org, ORG=hugmesh).
# ORG is left at its default on purpose: the chain's generic `hugmesh -> ORG` rule
# runs BEFORE the domain/brand rules and would otherwise consume them, which is a
# separate (pre-existing) ordering question this suite does not adjudicate. The
# =-preceded cases are the ones that prove the `=` sentinel is scoped to the
# `hugmesh.net/` KEY form and does not stop legitimate rewrites.
REWRITE_IN=(
  'issuer: https://id.hugmesh.net/login'
  'URL=https://hugmesh.net/path'
  'HOST=hugmesh.net'
  'MAIL=admin@hugmesh.net'
  'hugmesh.net is the apex'
  'image: registry.hugmesh.net/hugmesh/admin-bff-api:main'
  'name: hugmesh-host-shell'
  'title: HugMesh Systems'
)
REWRITE_OUT=(
  'issuer: https://id.example.org/login'
  'URL=https://example.org/path'
  'HOST=example.org'
  'MAIL=admin@example.org'
  'example.org is the apex'
  'image: registry.example.org/acme/admin-bff-api:main'
  'name: acme-host-shell'
  'title: Acme Mesh'
)

# The nodeSelector KEY of the projector DaemonSet: first non-comment line after
# `nodeSelector:`, up to the colon.
ds_node_selector_key() {
  awk '/^[[:space:]]*nodeSelector:/{p=1; next} p && !/^[[:space:]]*#/{sub(/^[[:space:]]+/,""); sub(/:.*$/,""); print; exit}' "$1"
}
ds_secret_sel() {
  sed -n 's/.*name: SECRET_SEL,[[:space:]]*value: "\([^"]*\)".*/\1/p' "$1" | awk 'NR==1'
}
env_value() { # KEY file
  sed -n "s/^$1=//p" "$2" | awk 'NR==1'
}

# Build the fixture sysroot. Every builder walks ${SYSROOT}/etc/hugmesh; the cluster
# builders (rpi5, x86) also walk ${SYSROOT}/var/lib/hugmesh/cluster, where the real
# contract is baked wholesale — so the same fixture goes under BOTH roots.
make_fixture() { # sysroot
  local r
  for r in "$1/etc/hugmesh/rebrand-fixture" "$1/var/lib/hugmesh/cluster/rebrand-fixture"; do
    mkdir -p "${r}"
    cp "${CONTRACT}"  "${r}/egress-vpn-secret-contract.env"
    cp "${DAEMONSET}" "${r}/secret-projector-daemonset.yaml"
    printf '%s\n' "${KEEP[@]}"        > "${r}/matrix-keep.txt"
    printf '%s\n' "${REWRITE_IN[@]}"  > "${r}/matrix-rewrite.txt"
  done
}

# ── non-vacuity: the fixture MUST carry =-preceded frozen keys ───────────────
echo "== fixture is not vacuous =="
FX="$(mktemp -d)"; make_fixture "${FX}"
n_contract="$(grep -c '^[A-Z_][A-Z0-9_]*=hugmesh\.net/' "${FX}/etc/hugmesh/rebrand-fixture/egress-vpn-secret-contract.env")"
n_matrix="$(grep -c '=hugmesh\.net/' "${FX}/etc/hugmesh/rebrand-fixture/matrix-keep.txt")"
[ "${n_contract}" -ge 1 ] && ok "real contract carries ${n_contract} KEY=hugmesh.net/... line(s)" \
  || bad "real contract carries NO KEY=hugmesh.net/... line — this suite would test nothing (vacuous)"
[ "${n_matrix}" -ge 1 ] && ok "matrix carries ${n_matrix} =-preceded frozen key(s)" \
  || bad "matrix carries NO =-preceded frozen key — the defect shape is not being fed through"
[ "${#REWRITE_IN[@]}" -eq "${#REWRITE_OUT[@]}" ] && ok "rewrite matrix is paired (${#REWRITE_IN[@]} cases)" \
  || bad "rewrite matrix in/out lengths differ"
# The contract lines this suite expects to survive, read from the REAL file so the
# assertion tracks it rather than a copy.
mapfile -t CONTRACT_KEY_LINES < <(grep '^[A-Z_][A-Z0-9_]*=hugmesh\.net/' "${CONTRACT}")
rm -rf "${FX}"

for BUILDER in "${BUILDERS[@]}"; do
  echo "== ${BUILDER}: rebrand_sysroot keeps frozen keys and rebrands the rest =="
  B="${REPO}/${BUILDER}"
  [ -f "${B}" ] || { bad "${BUILDER} missing"; continue; }
  for fn in _sed_rep_escape rebrand_sysroot; do
    src="$(extract_fn "${fn}" "${B}")"
    [ -n "${src}" ] || { bad "${BUILDER}: could not extract ${fn}"; continue 2; }
    eval "${src}"
  done
  type rebrand_sysroot >/dev/null 2>&1 || { bad "${BUILDER}: rebrand_sysroot not loaded"; continue; }
  walks_cluster=0
  printf '%s' "$(extract_fn rebrand_sysroot "${B}")" | grep 'var/lib/hugmesh/cluster' >/dev/null && walks_cluster=1

  # ── default branding: byte no-op ──────────────────────────────────────────
  SYSROOT="$(mktemp -d)"; make_fixture "${SYSROOT}"
  before="$(find "${SYSROOT}" -type f | sort | xargs cat | cksum)"
  BRAND=hugmesh BRAND_TITLE="HugMesh Systems" CLUSTER_DOMAIN=hugmesh.net ORG=hugmesh \
    GAMES_DOMAIN=games.hugmesh.net rebrand_sysroot
  after="$(find "${SYSROOT}" -type f | sort | xargs cat | cksum)"
  [ "${before}" = "${after}" ] && ok "${BUILDER}: default branding is a byte no-op" \
    || bad "${BUILDER}: default branding MUTATED the fixture"
  rm -rf "${SYSROOT}"

  # ── non-default branding ──────────────────────────────────────────────────
  SYSROOT="$(mktemp -d)"; make_fixture "${SYSROOT}"
  BRAND=acme BRAND_TITLE="Acme Mesh" CLUSTER_DOMAIN=example.org ORG=hugmesh \
    GAMES_DOMAIN=games.example.org rebrand_sysroot
  roots=("${SYSROOT}/etc/hugmesh/rebrand-fixture")
  [ "${walks_cluster}" -eq 1 ] && roots+=("${SYSROOT}/var/lib/hugmesh/cluster/rebrand-fixture")
  for r in "${roots[@]}"; do
    tag="${BUILDER}:${r#${SYSROOT}/}"
    # the real contract: every KEY=hugmesh.net/... line survives verbatim
    for line in "${CONTRACT_KEY_LINES[@]}"; do
      grep -qxF -- "${line}" "${r}/egress-vpn-secret-contract.env" \
        && ok "${tag}: contract keeps '${line}'" \
        || bad "${tag}: contract LOST '${line}' -> now: $(grep -F "${line%%=*}=" "${r}/egress-vpn-secret-contract.env" | awk 'NR==1')"
    done
    # the real manifest keeps its frozen keys...
    ds_key="$(ds_node_selector_key "${r}/secret-projector-daemonset.yaml")"
    ds_sel="$(ds_secret_sel "${r}/secret-projector-daemonset.yaml")"
    case "${ds_key}" in hugmesh.net/*) ok "${tag}: daemonset nodeSelector key stays '${ds_key}'" ;;
      *) bad "${tag}: daemonset nodeSelector key became '${ds_key}'" ;; esac
    case "${ds_sel}" in hugmesh.net/*) ok "${tag}: daemonset SECRET_SEL stays '${ds_sel}'" ;;
      *) bad "${tag}: daemonset SECRET_SEL became '${ds_sel}'" ;; esac
    # ...and the contract AGREES with it (the disagreement the defect produced)
    c_label="$(env_value EGRESS_VPN_NODE_LABEL "${r}/egress-vpn-secret-contract.env")"
    c_sel="$(env_value EGRESS_VPN_SECRET_SELECTOR "${r}/egress-vpn-secret-contract.env")"
    [ -n "${c_label}" ] && [ "${c_label}" = "${ds_key}" ] \
      && ok "${tag}: contract EGRESS_VPN_NODE_LABEL == daemonset nodeSelector key after rebrand" \
      || bad "${tag}: contract EGRESS_VPN_NODE_LABEL='${c_label}' != daemonset nodeSelector key '${ds_key}' after rebrand"
    [ -n "${c_sel}" ] && [ "${c_sel}" = "${ds_sel}" ] \
      && ok "${tag}: contract EGRESS_VPN_SECRET_SELECTOR == daemonset SECRET_SEL after rebrand" \
      || bad "${tag}: contract EGRESS_VPN_SECRET_SELECTOR='${c_sel}' != daemonset SECRET_SEL '${ds_sel}' after rebrand"
    # the KEEP matrix: byte-identical
    i=0
    while IFS= read -r got; do
      want="${KEEP[$i]}"
      [ "${got}" = "${want}" ] && ok "${tag}: keeps   '${want}'" \
        || bad "${tag}: frozen key '${want}' became '${got}'"
      i=$((i+1))
    done < "${r}/matrix-keep.txt"
    [ "${i}" -eq "${#KEEP[@]}" ] || bad "${tag}: keep matrix has ${i} lines, expected ${#KEEP[@]}"
    # the REWRITE matrix: each line becomes exactly its expected form
    i=0
    while IFS= read -r got; do
      want="${REWRITE_OUT[$i]}"
      [ "${got}" = "${want}" ] && ok "${tag}: rewrites '${REWRITE_IN[$i]}' -> '${want}'" \
        || bad "${tag}: '${REWRITE_IN[$i]}' became '${got}', expected '${want}'"
      i=$((i+1))
    done < "${r}/matrix-rewrite.txt"
    [ "${i}" -eq "${#REWRITE_IN[@]}" ] || bad "${tag}: rewrite matrix has ${i} lines, expected ${#REWRITE_IN[@]}"
    # the sentinel never leaks
    if grep -r 'SDSYSKEY' "${r}" >/dev/null; then bad "${tag}: sentinel @@SDSYSKEY@@ leaked into the output"
    else ok "${tag}: no sentinel leak"; fi
  done
  rm -rf "${SYSROOT}"
done

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

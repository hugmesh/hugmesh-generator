#!/usr/bin/env bash
# test-rebrand-frozen-label-keys.sh — the rebrand sed chain must leave FROZEN
# protocol identity literal in EVERY shape the baked tree actually carries, under
# EVERY branding knob (including a non-default --org), while still rebranding
# everything it is meant to rebrand.
#
# THE DEFECTS THIS PINS (2026-08-27, content-level audit + skeptic review). All
# ten build-*-stage4.sh carry a copy of rebrand_sysroot(), whose sed chain hides
# the frozen label-key namespace `hugmesh.net/<suffix>` behind a sentinel when it
# is preceded by a "structural boundary", rebrands hosts/URLs/emails in the
# middle, then restores the sentinel.
#   1. The class did NOT contain `=`. specs/cluster/egress-vpn-secret-contract.env
#      is a KEY=VALUE file (EGRESS_VPN_NODE_LABEL=hugmesh.net/egress-vpn, …), so
#      on every non-default build both lines were rewritten while the manifests'
#      `nodeSelector: hugmesh.net/egress-vpn` stayed literal: the contract and the
#      manifests it is "the ONE source of truth" for disagreed on a frozen key.
#   2. RULE ORDER: the catch-all `hugmesh -> ORG` ran BEFORE the domain / registry
#      / brand rules, so with a non-default --org (Studio passes it from the
#      profile) every `hugmesh.net` host became `<org>.net` and CLUSTER_DOMAIN,
#      HARBOR_PROJECT and BRAND were silently ignored. Correct only when ORG=hugmesh.
#   3. The CRD API group `platform.hugmesh.net` (apiVersion / apiGroups / ArgoCD
#      ignoreDifferences group / the CRD's own name) was rebranded as if it were a
#      host, although hugmesh-admin-bff-api compiles it in (Fabric8
#      .withGroup("platform.hugmesh.net")) — a rebranded CRD 404s that client.
#   4. The escaped-dot spelling a kubectl jsonpath needs
#      (`{.metadata.annotations.hugmesh\.net/seam-probe}`, real:
#      specs/cluster/manifests/prod-hygiene/validate-prod-hygiene.sh) escaped the
#      sentinel and was eaten by the org rule under a non-default --org.
# scripts/tooling/tokens.json frozen_protocol_constants is the contract
# (label_key_namespaces + api_groups: "must stay literal in every emitted repo").
#
# WHAT THIS SUITE DOES. For EACH builder it extracts the REAL rebrand_sysroot()
# (+ the real _sed_rep_escape it calls), points it at a fixture sysroot and runs
# THREE passes — default branding (must be a byte no-op), a custom brand/domain
# with the default org, and a custom brand/domain with a CUSTOM org — asserting:
#   * the REAL egress-vpn contract, DaemonSet, prod-hygiene validator, CRD and
#     RBAC (copied from specs/cluster) keep every frozen line byte-for-byte, and
#     contract == DaemonSet afterwards (the disagreement defect 1 produced);
#   * a KEEP matrix: every frozen shape (line-start, space, {, (, comma, quote,
#     backtick, EQUALS, --flag=, escaped dot, the API group in four spellings, and
#     the documented `=hugmesh.net/<path>` consequence) is byte-identical;
#   * a REWRITE matrix: every rebrandable shape (dot/slash-preceded hosts, bare
#     hosts incl. `HOST=hugmesh.net`, registry project, compound `hugmesh-*`,
#     the brand title, the GitHub org path, bare org tokens) becomes exactly its
#     expected value — under BOTH orgs, so the fix cannot over-protect and the
#     explicit knobs win over the catch-all;
#   * no sentinel leaks (`@@SDSYS…@@` never survives).
# The fixture is checked for NON-VACUITY first (no =-preceded key, no API-group
# line, no escaped-dot line in the real files => FAIL, not a pass on nothing), and
# the builder list is checked against the tree: a build-*-stage4.sh that defines
# rebrand_sysroot but is not listed here is a failure.
#
# Every builder walks ${SYSROOT}/etc/hugmesh; jetson, rpi5 and x86 ALSO walk
# ${SYSROOT}/var/lib/hugmesh/cluster (where specs/cluster is baked wholesale) —
# detected per builder from the real function, and the fixture sits under both.
#
# Runs ANYWHERE with bash + sed + awk — NO cross-build, NO root, NO network.
# Mutation-tested (see the commits that added and extended it): removing `=` from
# one builder or all ten, moving the org rule back up, dropping either new
# sentinel or its restore, over-protecting `/`, dropping the domain/brand/
# registry/line-start rules, dropping a builder from the list and hollowing the
# fixture are each caught.
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

# ── the REAL files that carry frozen identity, and the line pattern each must keep ─
CLUSTER="${REPO}/specs/cluster"
CONTRACT="${CLUSTER}/egress-vpn-secret-contract.env"
DAEMONSET="${CLUSTER}/manifests/egress-vpn/secret-projector-daemonset.yaml"
HYGIENE="${CLUSTER}/manifests/prod-hygiene/validate-prod-hygiene.sh"
CRD="${CLUSTER}/manifests/optional-services-operator/crd-optionalservice.yaml"
RBAC="${CLUSTER}/manifests/optional-services-operator/rbac.yaml"
for f in "${CONTRACT}" "${DAEMONSET}" "${HYGIENE}" "${CRD}" "${RBAC}"; do
  [ -f "${f}" ] || bad "missing ${f}"
done
# name|grep -E pattern of the lines that must survive verbatim (read from the REAL
# file at run time, so the assertion tracks the file rather than a copy).
REAL_FROZEN=(
  "egress-vpn-secret-contract.env|^[A-Z_][A-Z0-9_]*=hugmesh\\.net/"
  "validate-prod-hygiene.sh|hugmesh\\\\\\.net/"
  "crd-optionalservice.yaml|platform\\.hugmesh\\.net"
  "rbac.yaml|platform\\.hugmesh\\.net"
)

# ── the boundary matrix ───────────────────────────────────────────────────────
# KEEP: frozen shapes; must come out byte-identical under every branding.
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
  '--selector=hugmesh.net/a=1,hugmesh.net/b=2'
  # the escaped-dot spelling a kubectl jsonpath needs (real: validate-prod-hygiene.sh)
  "-o jsonpath='{.metadata.annotations.hugmesh\\.net/seam-probe}'"
  # the CRD API group, compiled into hugmesh-admin-bff-api — every spelling in the tree
  'apiVersion: platform.hugmesh.net/v1alpha1'
  'apiGroups: ["platform.hugmesh.net"]'
  '    group: platform.hugmesh.net'
  '  name: optionalservices.platform.hugmesh.net'
  # DOCUMENTED consequence of `=` in the class (not a goal): `=hugmesh.net/<path>`
  # reads as a KEY. Zero real instances (census 2026-08-27); a bare host with a
  # path after `=` must be written as a URL (`URL=https://hugmesh.net/path` below
  # rebrands). Pinned so a change to that behaviour is deliberate, not accidental.
  'BASE=hugmesh.net/api'
)
# REWRITE: rebrandable shapes. The INPUT is the same for both non-default passes;
# the expected OUTPUT differs only where the org token itself appears.
#   pass A: BRAND=acme BRAND_TITLE="Acme Mesh" CLUSTER_DOMAIN=example.org ORG=hugmesh
#   pass B: same, ORG=acmeorg  — the explicit knobs must win over the catch-all,
#           and the frozen matrix must hold exactly as under pass A.
# (The games host is builder-divergent by design — only rpi5/x86 carry the
# GAMES_DOMAIN rules — so it is not in the matrix.)
REWRITE_IN=(
  'issuer: https://id.hugmesh.net/login'
  'URL=https://hugmesh.net/path'
  'HOST=hugmesh.net'
  'MAIL=admin@hugmesh.net'
  'hugmesh.net is the apex'
  'image: registry.hugmesh.net/hugmesh/admin-bff-api:main'
  'name: hugmesh-host-shell'
  'title: HugMesh Systems'
  'repoURL: https://github.com/hugmesh/hugmesh-generator.git'
  'namespace: hugmesh'
  'ns: hugmesh-policy'
)
REWRITE_OUT_A=(
  'issuer: https://id.example.org/login'
  'URL=https://example.org/path'
  'HOST=example.org'
  'MAIL=admin@example.org'
  'example.org is the apex'
  'image: registry.example.org/acme/admin-bff-api:main'
  'name: acme-host-shell'
  'title: Acme Mesh'
  'repoURL: https://github.com/hugmesh/acme-generator.git'
  'namespace: hugmesh'
  'ns: acme-policy'
)
REWRITE_OUT_B=(
  'issuer: https://id.example.org/login'
  'URL=https://example.org/path'
  'HOST=example.org'
  'MAIL=admin@example.org'
  'example.org is the apex'
  'image: registry.example.org/acme/admin-bff-api:main'
  'name: acme-host-shell'
  'title: Acme Mesh'
  'repoURL: https://github.com/acmeorg/acme-generator.git'
  'namespace: acmeorg'
  'ns: acme-policy'
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

# Build the fixture sysroot under BOTH roots a builder may walk.
make_fixture() { # sysroot
  local r
  for r in "$1/etc/hugmesh/rebrand-fixture" "$1/var/lib/hugmesh/cluster/rebrand-fixture"; do
    mkdir -p "${r}"
    cp "${CONTRACT}"  "${r}/egress-vpn-secret-contract.env"
    cp "${DAEMONSET}" "${r}/secret-projector-daemonset.yaml"
    cp "${HYGIENE}"   "${r}/validate-prod-hygiene.sh"
    cp "${CRD}"       "${r}/crd-optionalservice.yaml"
    cp "${RBAC}"      "${r}/rbac.yaml"
    printf '%s\n' "${KEEP[@]}"        > "${r}/matrix-keep.txt"
    printf '%s\n' "${REWRITE_IN[@]}"  > "${r}/matrix-rewrite.txt"
  done
}

# ── non-vacuity: the fixture MUST carry every defect shape ───────────────────
echo "== fixture is not vacuous =="
declare -A REAL_LINES   # name -> newline-joined frozen lines read from the REAL file
for spec in "${REAL_FROZEN[@]}"; do
  name="${spec%%|*}"; pat="${spec#*|}"
  case "${name}" in
    egress-vpn-secret-contract.env) src="${CONTRACT}" ;;
    validate-prod-hygiene.sh)       src="${HYGIENE}" ;;
    crd-optionalservice.yaml)       src="${CRD}" ;;
    rbac.yaml)                      src="${RBAC}" ;;
  esac
  lines="$(grep -E -- "${pat}" "${src}" 2>/dev/null)"
  n=0; [ -n "${lines}" ] && n="$(printf '%s\n' "${lines}" | wc -l)"
  [ "${n}" -ge 1 ] && ok "real ${name} carries ${n} frozen line(s) matching ${pat}" \
    || bad "real ${name} carries NO line matching ${pat} — this suite would test nothing for it (vacuous)"
  REAL_LINES["${name}"]="${lines}"
done
n_keep_eq="$(printf '%s\n' "${KEEP[@]}" | grep -c '=hugmesh\.net/')"
n_keep_api="$(printf '%s\n' "${KEEP[@]}" | grep -c 'platform\.hugmesh\.net')"
n_keep_esc="$(printf '%s\n' "${KEEP[@]}" | grep -c 'hugmesh\\\.net/')"
[ "${n_keep_eq}" -ge 1 ] && ok "keep matrix carries ${n_keep_eq} =-preceded frozen key(s)" \
  || bad "keep matrix carries NO =-preceded frozen key — defect 1's shape is not being fed through"
[ "${n_keep_api}" -ge 1 ] && ok "keep matrix carries ${n_keep_api} API-group line(s)" \
  || bad "keep matrix carries NO platform.hugmesh.net line — defect 3's shape is not being fed through"
[ "${n_keep_esc}" -ge 1 ] && ok "keep matrix carries ${n_keep_esc} escaped-dot line(s)" \
  || bad "keep matrix carries NO escaped-dot line — defect 4's shape is not being fed through"
[ "${#REWRITE_IN[@]}" -eq "${#REWRITE_OUT_A[@]}" ] && [ "${#REWRITE_IN[@]}" -eq "${#REWRITE_OUT_B[@]}" ] \
  && ok "rewrite matrix is paired (${#REWRITE_IN[@]} cases, two org passes)" \
  || bad "rewrite matrix in/out lengths differ"
n_org_diff=0
for i in "${!REWRITE_OUT_A[@]}"; do [ "${REWRITE_OUT_A[$i]}" != "${REWRITE_OUT_B[$i]}" ] && n_org_diff=$((n_org_diff+1)); done
[ "${n_org_diff}" -ge 1 ] && ok "rewrite matrix has ${n_org_diff} org-sensitive case(s) (the custom-org pass is not a copy of pass A)" \
  || bad "rewrite matrix has no org-sensitive case — the custom-org pass would prove nothing about the org rule"

# Assert one fixture root after a non-default pass.
check_root() { # tag root out_array_name
  local tag="$1"
  local r="$2"
  local -n want_out="$3"
  local name spec line got want i ds_key ds_sel c_label c_sel
  # the REAL files: every frozen line survives verbatim
  for spec in "${REAL_FROZEN[@]}"; do
    name="${spec%%|*}"
    while IFS= read -r line; do
      [ -n "${line}" ] || continue
      if grep -qxF -- "${line}" "${r}/${name}"; then ok "${tag}: ${name} keeps '${line}'"
      else bad "${tag}: ${name} LOST '${line}'"; fi
    done <<< "${REAL_LINES[${name}]}"
  done
  # the real DaemonSet keeps its frozen keys...
  ds_key="$(ds_node_selector_key "${r}/secret-projector-daemonset.yaml")"
  ds_sel="$(ds_secret_sel "${r}/secret-projector-daemonset.yaml")"
  case "${ds_key}" in hugmesh.net/*) ok "${tag}: daemonset nodeSelector key stays '${ds_key}'" ;;
    *) bad "${tag}: daemonset nodeSelector key became '${ds_key}'" ;; esac
  case "${ds_sel}" in hugmesh.net/*) ok "${tag}: daemonset SECRET_SEL stays '${ds_sel}'" ;;
    *) bad "${tag}: daemonset SECRET_SEL became '${ds_sel}'" ;; esac
  # ...and the contract AGREES with it (the disagreement defect 1 produced)
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
      || bad "${tag}: frozen '${want}' became '${got}'"
    i=$((i+1))
  done < "${r}/matrix-keep.txt"
  [ "${i}" -eq "${#KEEP[@]}" ] || bad "${tag}: keep matrix has ${i} lines, expected ${#KEEP[@]}"
  # the REWRITE matrix: each line becomes exactly its expected form
  i=0
  while IFS= read -r got; do
    want="${want_out[$i]}"
    [ "${got}" = "${want}" ] && ok "${tag}: rewrites '${REWRITE_IN[$i]}' -> '${want}'" \
      || bad "${tag}: '${REWRITE_IN[$i]}' became '${got}', expected '${want}'"
    i=$((i+1))
  done < "${r}/matrix-rewrite.txt"
  [ "${i}" -eq "${#REWRITE_IN[@]}" ] || bad "${tag}: rewrite matrix has ${i} lines, expected ${#REWRITE_IN[@]}"
  # no sentinel leaks (any of them)
  if grep -r '@@SDSYS' "${r}" >/dev/null; then bad "${tag}: a @@SDSYS…@@ sentinel leaked into the output"
  else ok "${tag}: no sentinel leak"; fi
}

for BUILDER in "${BUILDERS[@]}"; do
  echo "== ${BUILDER}: rebrand_sysroot keeps frozen identity and rebrands the rest =="
  B="${REPO}/${BUILDER}"
  [ -f "${B}" ] || { bad "${BUILDER} missing"; continue; }
  for fn in _sed_rep_escape rebrand_sysroot; do
    src="$(extract_fn "${fn}" "${B}")"
    [ -n "${src}" ] || { bad "${BUILDER}: could not extract ${fn}"; continue 2; }
    eval "${src}"
  done
  type rebrand_sysroot >/dev/null 2>&1 || { bad "${BUILDER}: rebrand_sysroot not loaded"; continue; }
  # Which roots the REAL function walks — read from its CODE, comments stripped
  # (the builders' comment block names both roots in prose).
  walks_cluster=0
  printf '%s\n' "$(extract_fn rebrand_sysroot "${B}")" | grep -v '^[[:space:]]*#' | grep 'var/lib/hugmesh/cluster' >/dev/null && walks_cluster=1

  # ── default branding: byte no-op ──────────────────────────────────────────
  SYSROOT="$(mktemp -d)"; make_fixture "${SYSROOT}"
  before="$(find "${SYSROOT}" -type f | sort | xargs cat | cksum)"
  BRAND=hugmesh BRAND_TITLE="HugMesh Systems" CLUSTER_DOMAIN=hugmesh.net ORG=hugmesh \
    GAMES_DOMAIN=games.hugmesh.net rebrand_sysroot
  after="$(find "${SYSROOT}" -type f | sort | xargs cat | cksum)"
  [ "${before}" = "${after}" ] && ok "${BUILDER}: default branding is a byte no-op" \
    || bad "${BUILDER}: default branding MUTATED the fixture"
  rm -rf "${SYSROOT}"

  # ── pass A: custom brand/domain, default org ──────────────────────────────
  # ── pass B: custom brand/domain AND a custom org ──────────────────────────
  for pass in A B; do
    case "${pass}" in A) orgv=hugmesh ;; B) orgv=acmeorg ;; esac
    SYSROOT="$(mktemp -d)"; make_fixture "${SYSROOT}"
    BRAND=acme BRAND_TITLE="Acme Mesh" CLUSTER_DOMAIN=example.org ORG="${orgv}" \
      GAMES_DOMAIN=games.example.org rebrand_sysroot
    roots=("${SYSROOT}/etc/hugmesh/rebrand-fixture")
    [ "${walks_cluster}" -eq 1 ] && roots+=("${SYSROOT}/var/lib/hugmesh/cluster/rebrand-fixture")
    for r in "${roots[@]}"; do
      check_root "${BUILDER}[org=${orgv}]:${r#${SYSROOT}/}" "${r}" "REWRITE_OUT_${pass}"
    done
    rm -rf "${SYSROOT}"
  done
done

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

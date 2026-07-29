#!/usr/bin/env bash
# test-brand-path-validation.sh — offline regression test for the brand-repo /
# keystore / reconcile / mesh-node path + template validation hardening.
#
# Covers the generator-shell sweep findings:
#   #4  scripts/gen-keystores.sh        — multi-domain brand/domain slug from
#       domains.conf must be slug/DNS-validated before it builds a ROOT mkdir/rm
#       path (path traversal otherwise).
#   #8  generate-brand-repos.sh         — BRAND from the (signed-but-content-
#       unvalidated) export must be slug-allowlisted before rm -rf/mkdir/file
#       writes; BRAND_OUT must resolve under OUT_DIR.
#   #12 generate-brand-repos.sh         — brand/org/domain land on a `sed s|…|RHS|`
#       replacement: escape + reject sed/shell metacharacters.
#   #13 specs/usr/sbin/hugmesh-domain-reconcile — fail-closed CONTENT gate
#       (entry_fields_ok) after jq extraction.
#   #15 generate-brand-repos.sh         — validate every sourced var
#       (BRAND/ORG/CLUSTER_DOMAIN/HEADSCALE_URL/MESH_TAG/BRAND_TITLE).
#   #18 clients/docker-mesh-node/install.sh — role/name/image written into the
#       dot-sourced launch.env must be validated + single-quote-escaped.
#
# In every case we assert BOTH: the injection/traversal input is REJECTED, AND a
# legitimate value (brand hugmesh, domain hugmesh.systems, role admin) still
# PASSES. Runs ANYWHERE with bash + sed (no root, no network, no crypto needed —
# the validation gates fire before any openssl/keytool work).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEN_BRAND="${REPO}/generate-brand-repos.sh"
GEN_KS="${REPO}/scripts/gen-keystores.sh"
AGENT="${REPO}/specs/usr/sbin/hugmesh-domain-reconcile"
INSTALL="${REPO}/clients/docker-mesh-node/install.sh"

for f in "${GEN_BRAND}" "${GEN_KS}" "${AGENT}" "${INSTALL}"; do
  [ -r "${f}" ] || { echo "  FAIL missing target: ${f}"; exit 1; }
done

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
W="$(mktemp -d)"; trap 'rm -rf "${W}" 2>/dev/null' EXIT

echo "== brand/keystore/reconcile/mesh path+template validation regression =="

# ── helper: write a brand profile for generate-brand-repos.sh ─────────────────
write_prof() {
  # $1=file  then KEY=VALUE-style overrides via the named vars below
  cat > "$1" <<EOF
BRAND=${PB_BRAND}
BRAND_TITLE="${PB_TITLE}"
ORG=${PB_ORG}
CLUSTER_DOMAIN=${PB_DOMAIN}
HEADSCALE_URL=${PB_HS}
MESH_TAG=${PB_MESH}
EOF
}
reset_prof() {
  PB_BRAND=hugmesh
  PB_TITLE="HugMesh Systems"
  PB_ORG=HugMesh
  PB_DOMAIN=hugmesh.systems
  PB_HS=https://headscale.hugmesh.systems
  PB_MESH=tag:hugmesh
}

# ─────────────────────────────────────────────────────────────────────────────
# #8/#12/#15 generate-brand-repos.sh
# ─────────────────────────────────────────────────────────────────────────────
echo "-- #8/#12/#15 generate-brand-repos.sh --"

# (clean) legit values MUST render 12 templates
reset_prof; write_prof "${W}/clean.conf"
if bash "${GEN_BRAND}" "${W}/clean.conf" --out-dir "${W}/out" >/dev/null 2>"${W}/e" \
   && [ -d "${W}/out/hugmesh-gitops/apps" ]; then
  ok "clean brand profile renders (hugmesh / hugmesh.systems)"
else
  bad "clean brand profile was rejected:"; sed 's/^/      /' "${W}/e"
fi

# (#8 traversal) BRAND='../../etc/cron.d/x' MUST be rejected, nothing outside out/
reset_prof; PB_BRAND='../../etc/cron.d/x'; write_prof "${W}/trav.conf"
if bash "${GEN_BRAND}" "${W}/trav.conf" --out-dir "${W}/out" >/dev/null 2>"${W}/e"; then
  bad "#8 path-traversal BRAND was ACCEPTED"
else
  grep -q "invalid BRAND" "${W}/e" && ok "#8 path-traversal BRAND rejected" \
    || bad "#8 rejected but not by the BRAND gate"
fi

# (#12 sed/shell injection via BRAND_TITLE) MUST be rejected
reset_prof; PB_TITLE='X|g;s|keepme|PWNED'; write_prof "${W}/sed.conf"
bash "${GEN_BRAND}" "${W}/sed.conf" --out-dir "${W}/out" >/dev/null 2>&1 \
  && bad "#12 sed-metachar BRAND_TITLE was ACCEPTED" \
  || ok "#12 sed-metachar BRAND_TITLE rejected"

# (#12 literal ampersand — sed whole-match re-injection) MUST be rejected
reset_prof; PB_TITLE='AT&T Brand'; write_prof "${W}/amp.conf"
bash "${GEN_BRAND}" "${W}/amp.conf" --out-dir "${W}/out" >/dev/null 2>&1 \
  && bad "#12 ampersand BRAND_TITLE was ACCEPTED" \
  || ok "#12 ampersand BRAND_TITLE rejected"

# (#15 bad CLUSTER_DOMAIN) MUST be rejected
reset_prof; PB_DOMAIN='ev/il.test'; write_prof "${W}/dom.conf"
bash "${GEN_BRAND}" "${W}/dom.conf" --out-dir "${W}/out" >/dev/null 2>"${W}/e"
[ $? -ne 0 ] && grep -q "invalid CLUSTER_DOMAIN" "${W}/e" \
  && ok "#15 bad CLUSTER_DOMAIN rejected" || bad "#15 bad CLUSTER_DOMAIN ACCEPTED"

# (#15 bad MESH_TAG) MUST be rejected
reset_prof; PB_MESH='tag:a|b'; write_prof "${W}/mesh.conf"
bash "${GEN_BRAND}" "${W}/mesh.conf" --out-dir "${W}/out" >/dev/null 2>&1 \
  && bad "#15 bad MESH_TAG ACCEPTED" || ok "#15 bad MESH_TAG rejected"

# ─────────────────────────────────────────────────────────────────────────────
# #4 scripts/gen-keystores.sh — domains.conf row slug/DNS validation
# ─────────────────────────────────────────────────────────────────────────────
echo "-- #4 gen-keystores.sh domains.conf slug/DNS validation --"

# (traversal brand) row 'acme.test  ../../../etc/cron.d' MUST be rejected before crypto
printf 'acme.test\t../../../etc/cron.d\n' > "${W}/ks-trav.conf"
DOMAINS_CONF="${W}/ks-trav.conf" bash "${GEN_KS}" "${W}/ks1" >/dev/null 2>"${W}/e"
[ $? -ne 0 ] && grep -q "invalid brand slug" "${W}/e" \
  && ok "#4 path-traversal brand slug rejected" || bad "#4 traversal brand slug ACCEPTED"

# (slash domain) MUST be rejected
printf 'ev/il.test\tacme\n' > "${W}/ks-dom.conf"
DOMAINS_CONF="${W}/ks-dom.conf" bash "${GEN_KS}" "${W}/ks2" >/dev/null 2>"${W}/e"
[ $? -ne 0 ] && grep -q "invalid domain" "${W}/e" \
  && ok "#4 slash-in-domain rejected" || bad "#4 slash-in-domain ACCEPTED"

# (clean rows) must PASS validation (it then proceeds into provisioning — we only
# assert validation did NOT reject; openssl/keytool may be absent, that's fine).
printf 'acme.test\tacme\nfoo.example\tfoo\n' > "${W}/ks-clean.conf"
DOMAINS_CONF="${W}/ks-clean.conf" timeout 8 bash "${GEN_KS}" "${W}/ks3" >/dev/null 2>"${W}/e"
grep -q "ERROR: invalid" "${W}/e" \
  && bad "#4 clean multi-domain rows wrongly rejected" \
  || ok "#4 clean multi-domain rows pass validation"

# ─────────────────────────────────────────────────────────────────────────────
# #13 hugmesh-domain-reconcile — fail-closed content gate (entry_fields_ok)
# ─────────────────────────────────────────────────────────────────────────────
echo "-- #13 hugmesh-domain-reconcile entry_fields_ok --"
# Source the agent (it guards main() under [ BASH_SOURCE == 0 ]) to unit-test the gate.
# shellcheck source=/dev/null
( . "${AGENT}" 2>/dev/null
  rc=0
  entry_fields_ok "hugmesh" "hugmesh.systems" "HugMesh" "tag:hugmesh" 2>/dev/null || rc=1
  exit $rc )
[ $? -eq 0 ] && ok "#13 clean entry accepted" || bad "#13 clean entry wrongly rejected"

( . "${AGENT}" 2>/dev/null; entry_fields_ok "../../etc/cron.d/x" "acme.test" "acme" "tag:acme" 2>/dev/null )
[ $? -ne 0 ] && ok "#13 traversal brand entry rejected" || bad "#13 traversal brand entry ACCEPTED"

( . "${AGENT}" 2>/dev/null; entry_fields_ok "acme" "ev/il.test" "acme" "tag:acme" 2>/dev/null )
[ $? -ne 0 ] && ok "#13 slash-domain entry rejected" || bad "#13 slash-domain entry ACCEPTED"

( . "${AGENT}" 2>/dev/null; entry_fields_ok "acme" "acme.test" "a|d s/x/y" "tag:acme" 2>/dev/null )
[ $? -ne 0 ] && ok "#13 sed-metachar org entry rejected" || bad "#13 sed-metachar org entry ACCEPTED"

# ─────────────────────────────────────────────────────────────────────────────
# #18 clients/docker-mesh-node/install.sh — launch.env validate + safe-quote
# ─────────────────────────────────────────────────────────────────────────────
echo "-- #18 docker-mesh-node install.sh launch.env --"
MW="${W}/mesh"; mkdir -p "${MW}/keys" "${MW}/home"
run_install() { # args... ; uses isolated HOME/XDG
  ( export HOME="${MW}/home" XDG_CONFIG_HOME="${MW}/cfg" XDG_DATA_HOME="${MW}/data"
    sh "${INSTALL}" --keys "${MW}/keys" "$@" ) 2>"${W}/e" >/dev/null
}

run_install --role 'user$(touch ${W}/ROLE_PWNED)'
[ $? -ne 0 ] && [ ! -e "${W}/ROLE_PWNED" ] && ok "#18 injection --role rejected" \
  || bad "#18 injection --role ACCEPTED"

run_install --role user --name 'h; rm -rf x'
[ $? -ne 0 ] && ok "#18 injection --name rejected" || bad "#18 injection --name ACCEPTED"

run_install --role user --image 'img$(id)'
[ $? -ne 0 ] && ok "#18 injection --image rejected" || bad "#18 injection --image ACCEPTED"

# clean install MUST succeed AND produce a launch.env that is safe to dot-source.
run_install --role admin --name node-1 --image ghcr.io/hugmesh/mesh:1.2
CFG="${MW}/cfg/hugmesh-mesh/launch.env"
if [ $? -eq 0 ] && [ -f "${CFG}" ]; then
  ok "#18 clean install succeeds"
  # source it and assert no code executed + literal values preserved
  out="$( ( . "${CFG}"; printf '%s|%s|%s' "${ROLE:-}" "${NAME:-}" "${IMAGE:-}" ) )"
  [ "${out}" = "admin|node-1|ghcr.io/hugmesh/mesh:1.2" ] \
    && ok "#18 launch.env dot-sources to literal values" \
    || bad "#18 launch.env sourced to '${out}'"
else
  bad "#18 clean install failed:"; sed 's/^/      /' "${W}/e"
fi

echo ""
# render-handlebars.sh (opt-in `--engine handlebars`) must apply the SAME brand-scalar guards
# as the default sed engine (generate-brand-repos.sh), else a hostile CLUSTER_DOMAIN injects
# into the noEscape:true gateway route/host render. The script's own node/handlebars-installed
# check precedes its guards, so drive the extracted guard block directly (the guards are what we
# assert are present + fail-closed).
echo "-- render-handlebars.sh brand-scalar guards (parity with the sed engine) --"
RH="${REPO}/scripts/tooling/render-handlebars.sh"
if [ -r "${RH}" ] && grep -q '_hbdie' "${RH}"; then
  awk '/^_DNS_LABEL=/{f=1} f{print} /must be single-line/{c++} c&&/^fi$/{exit}' "${RH}" > "${W}/rhguards.sh"
  ( BRAND=acme BRAND_TITLE=Acme ORG=acme HEADSCALE_URL= MESH_TAG=; CLUSTER_DOMAIN=$'evil.com\n  extraHosts: [x]'
    source "${W}/rhguards.sh" ) >"${W}/ro" 2>"${W}/re"
  [ $? -ne 0 ] && grep -q "invalid CLUSTER_DOMAIN" "${W}/re" \
    && ok "render-handlebars newline CLUSTER_DOMAIN rejected (parity with sed engine)" \
    || bad "render-handlebars newline CLUSTER_DOMAIN ACCEPTED (opt-in engine still injectable)"
  ( BRAND=hugmesh BRAND_TITLE=HugMesh ORG=hugmesh CLUSTER_DOMAIN=hugmesh.systems \
    HEADSCALE_URL= MESH_TAG=; source "${W}/rhguards.sh" ) >"${W}/ro2" 2>"${W}/re2"
  [ $? -eq 0 ] && ok "render-handlebars legit brand accepted" \
    || bad "render-handlebars legit brand REJECTED: $(cat "${W}/re2")"
else
  bad "render-handlebars.sh brand-scalar guards not found (the injection fix is missing)"
fi

echo ""
echo "== brand path-validation regression: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

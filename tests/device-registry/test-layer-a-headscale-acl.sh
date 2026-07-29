#!/usr/bin/env bash
# test-layer-a-headscale-acl.sh — executable ALLOW+DENY role matrix for the
# Layer-A device-license-registry headscale SSH ACL (PR6). Backs the Gherkin
# scenarios in layer-a-headscale-ssh-acl.feature.
#
# WHAT IT DOES (runs ANYWHERE with bash + jq + openssl + awk — no live headscale,
# no BFF): it RENDERS the real policy by SOURCING the real renderer functions
# (render_policy / dev_tag_for_fp / sanitise_tag) out of
# specs/usr/sbin/gen-headscale-policy.sh (its main() is guarded behind a
# BASH_SOURCE check, so sourcing does NOT run the fetch/verify/apply flow), feeds
# them a synthetic signed-export BODY, and then evaluates the rendered ssh[]
# block against headscale's documented SSH semantics: SSH is DEFAULT-DENY and
# ONLY the listed accepts apply. An edge (src, dstNode, asUser) is ALLOWED iff
# some rendered ssh accept has the matching src, a dst tag the dstNode carries,
# and asUser in users[].
#
# HONESTY: this models headscale's policy semantics; it does NOT prove a live
# control node enforces them. That + forged-tag REJECTION + real :22 default-deny
# are NEEDS-HEADSCALE (see the PR body matrix). The SOURCE side is ADVISORY until
# OIDC (every edge src is tag:hugmesh); these assertions are the DESTINATION
# cut + default-deny that ship now.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RENDERER="${REPO}/specs/usr/sbin/gen-headscale-policy.sh"
TMPL="${REPO}/specs/etc/headscale/policy.hujson.tmpl"
BOOTSTRAP="${REPO}/specs/etc/headscale/policy.bootstrap.hujson"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
strip(){ sed -e 's#//.*$##' "$1"; }   # strip hujson comments -> strict JSON

command -v jq >/dev/null      || { echo "jq required"; exit 2; }
command -v openssl >/dev/null || { echo "openssl required"; exit 2; }

# Source the real renderer functions (main is guarded out when sourced).
NODE_ENV=/dev/null
# shellcheck source=/dev/null
. "${RENDERER}"
# render_policy reads these globals (normally set by _init from node.env).
POLICY_TMPL="${TMPL}"
TS_SSH_USER="superadmin"
MESH_ID="east-01"
MESH_TAG="tag:mesh_$(sanitise_tag "${MESH_ID}")"

# ── Synthetic VERIFIED export body (post-#28 shape: ADMIN licenses only; core
# nodes ABSENT). alice holds a DEVICE license on node-a (fpA, own-domain) and a
# DOMAIN license on node-b (fpB). core-1 (fpCORE) + other-domain node-z (fpZ) are
# deliberately NOT present (the BFF compile excludes them).
EXPORT="$(mktemp)"; trap 'rm -f "${EXPORT}" "${RENDERED}" 2>/dev/null' EXIT
cat > "${EXPORT}" <<'JSON'
{ "signed": true, "signature":"x", "body": {
  "meshId":"east-01", "generation": 11,
  "operators": [
    {"operator":"alice","machineKeyFp":"fpA","hostname":"node-a","keyFingerprints":["SHA256:ka"],"via":"DEVICE-LICENSE"},
    {"operator":"alice","machineKeyFp":"fpB","hostname":"node-b","keyFingerprints":["SHA256:ka"],"via":"DOMAIN-LICENSE"}
  ] } }
JSON

RENDERED="$(mktemp)"
render_policy "${EXPORT}" "${RENDERED}" || { echo "render_policy FAILED"; exit 1; }

# dst tags for the nodes under test (same hash the renderer + forcetags use).
TAG_A="tag:$(dev_tag_for_fp fpA)"
TAG_B="tag:$(dev_tag_for_fp fpB)"
TAG_CORE="tag:$(dev_tag_for_fp fpCORE)"
TAG_Z="tag:$(dev_tag_for_fp fpZ)"

# ── headscale-SSH evaluator: ALLOW iff a rendered ssh accept matches
# (src, one of dstTags the node carries, asUser). Default-deny otherwise.
# Args: <src-identity> <asUser> <space-separated dst tags the dst node carries>
ssh_allowed() {
    local src="$1" asuser="$2"; shift 2
    local nodetags="$*"
    strip "${RENDERED}" | jq -e --arg src "${src}" --arg u "${asuser}" --arg nt "${nodetags}" '
        ($nt | split(" ")) as $carried
        | [ .ssh[]
            | select(.action=="accept")
            | select(.src | index($src))
            | select(.users | index($u))
            | select([.dst[] as $d | $carried | index($d)] | any) ]
        | length > 0
    ' >/dev/null 2>&1
}

echo "== Layer-A headscale SSH ACL — ALLOW+DENY role matrix =="
echo "-- rendered policy shape --"
strip "${RENDERED}" | jq -e . >/dev/null 2>&1 && ok "rendered policy is valid JSON" || bad "rendered policy not JSON"
grep -q '@@' "${RENDERED}" && bad "rendered policy has leftover @@ markers" || ok "no leftover @@ markers"

echo "-- Scenario: licensed admin -> licensed own-domain node:22 (ALLOW) --"
# node-a carries its server-forced tag:dev_<fpA>; src is the advisory tag:hugmesh.
if ssh_allowed "tag:hugmesh" "superadmin" "${TAG_A} tag:hugmesh ${MESH_TAG}"; then
    ok "admin reaches own-domain node-a:22 (edge to ${TAG_A} present)"
else bad "admin should reach node-a:22"; fi
if ssh_allowed "tag:hugmesh" "superadmin" "${TAG_B} tag:hugmesh ${MESH_TAG}"; then
    ok "admin reaches own-domain node-b:22 (DOMAIN-LICENSE edge present)"
else bad "admin should reach node-b:22"; fi

echo "-- Scenario: admin -> superadmin/core node:22 (DENY, node absent from export) --"
# core-1 is NOT in the export, so no tag:dev_<fpCORE> edge exists. It carries only
# tag:hugmesh + tag:mesh (+ would carry tag:superadmin-reachability via mesh).
if ssh_allowed "tag:hugmesh" "superadmin" "${TAG_CORE} tag:hugmesh ${MESH_TAG}"; then
    bad "admin must NOT reach core node:22"
else ok "admin denied to core node:22 (no export edge -> default-deny)"; fi

echo "-- Scenario: admin -> other-domain node:22 (DENY, no license) --"
if ssh_allowed "tag:hugmesh" "superadmin" "${TAG_Z} tag:hugmesh ${MESH_TAG}"; then
    bad "admin must NOT reach other-domain node:22"
else ok "admin denied to other-domain node-z:22 (no export edge -> default-deny)"; fi

echo "-- Scenario: SUPERADMIN -> ALL mesh nodes:22 (ALLOW via tag:mesh) --"
# tag:superadmin is force-assigned to the superadmin operator; every node carries
# tag:mesh_east-01. core-1 (no export edge) is reachable ONLY this way.
for n in "core-1=${TAG_CORE}" "node-a=${TAG_A}" "node-z=${TAG_Z}"; do
    nm="${n%%=*}"; nt="${n#*=}"
    if ssh_allowed "tag:superadmin" "superadmin" "${nt} ${MESH_TAG} tag:hugmesh"; then
        ok "superadmin reaches ${nm}:22 via tag:mesh (incl. core node the export omits)"
    else bad "superadmin should reach ${nm}:22 via tag:mesh"; fi
done

echo "-- Scenario: SUPERADMIN reach is mesh-scoped (cross-mesh DENY) --"
# A node in a DIFFERENT mesh would carry tag:mesh_west-02, not tag:mesh_east-01.
if ssh_allowed "tag:superadmin" "superadmin" "tag:mesh_west-02 tag:hugmesh"; then
    bad "superadmin must NOT reach a node only in another mesh"
else ok "superadmin denied to a node tagged only tag:mesh_west-02 (mesh-scoped)"; fi

echo "-- Scenario: non-:22 fleet traffic rides the CIDR data-plane only --"
strip "${RENDERED}" | jq -e '[.acls[] | select(.dst[]? == "10.244.0.0/16:*")] | length == 1' >/dev/null \
    && ok "CIDR pod/service data-plane rule kept (k8s, not SSH)" || bad "CIDR data-plane rule missing"
strip "${RENDERED}" | jq -e '[.acls[] | select(.dst[]? == "tag:hugmesh:*")] | length == 0' >/dev/null \
    && ok "NO any-to-any tag:hugmesh -> tag:hugmesh:* rule (the :22 hole is gone)" || bad "any-to-any rule present"

echo "-- Scenario: tag:hugmesh is no longer an SSH dst --"
strip "${RENDERED}" | jq -e '[.ssh[] | select(.dst[0]? == "tag:hugmesh")] | length == 0' >/dev/null \
    && ok "tag:hugmesh removed as an ssh dst (only tag:dev_/tag:mesh_ remain)" || bad "tag:hugmesh still an ssh dst"

echo "-- Scenario: server-forced dst tags are control-owned (FIX-SERVERTAG) --"
strip "${RENDERED}" | jq -e '.tagOwners["tag:superadmin"] == ["hugmesh"]' >/dev/null \
    && ok "tag:superadmin owned by control 'hugmesh' user only" || bad "tag:superadmin owner wrong"
strip "${RENDERED}" | jq -e --arg t "${TAG_A}" '.tagOwners[$t] == ["hugmesh"]' >/dev/null \
    && ok "tag:dev_<fpA> owned by control 'hugmesh' user only (not self-applyable)" || bad "tag:dev owner wrong"

echo "-- Scenario: EMPTY export still emits the SUPERADMIN mesh rule (never all-deny-superadmin) --"
EEMPTY="$(mktemp)"; printf '%s' '{"signed":true,"signature":"x","body":{"meshId":"east-01","generation":12,"operators":[]}}' > "${EEMPTY}"
REMPTY="$(mktemp)"
if render_policy "${EEMPTY}" "${REMPTY}"; then
    n=$(strip "${REMPTY}" | jq '[.ssh[] | select(.src[0]=="tag:superadmin")] | length')
    t=$(strip "${REMPTY}" | jq '.ssh | length')
    { [ "${n}" = 1 ] && [ "${t}" = 1 ]; } && ok "empty export -> ssh[] is exactly the SUPERADMIN mesh rule" || bad "empty export ssh[] wrong (sup=${n} total=${t})"
else bad "render_policy failed on empty export"; fi
rm -f "${EEMPTY}" "${REMPTY}"

echo "-- Scenario: bootstrap policy drops the any-to-any :22 hole pre-export --"
strip "${BOOTSTRAP}" | jq -e '[.acls[] | select(.dst[]? == "tag:hugmesh:*")] | length == 0' >/dev/null \
    && ok "bootstrap policy has NO any-to-any rule" || bad "bootstrap any-to-any rule present"
strip "${BOOTSTRAP}" | jq -e '[.acls[] | select(.dst[]? == "10.244.0.0/16:*")] | length == 1' >/dev/null \
    && ok "bootstrap policy keeps the CIDR data-plane rule" || bad "bootstrap CIDR rule missing"
grep -q '@@TS_SSH_USER@@' "${BOOTSTRAP}" \
    && ok "bootstrap policy carries the conservative @@TS_SSH_USER@@ ssh accept" || bad "bootstrap ssh accept missing"

echo
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

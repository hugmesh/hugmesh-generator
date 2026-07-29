#!/usr/bin/env bash
# test-registry-allow-deny.sh — the executable ALLOW+DENY ROLE MATRIX for the
# device-license registry SSH boundary (device-registry PR6). Backs the Gherkin
# scenarios in tests/device-registry/registry-allow-deny.feature.
#
# WHAT IT DOES (runs ANYWHERE with bash + jq + openssl + base64 + awk — NO live
# mesh, NO live sshd, NO live headscale, NO BFF). It evaluates the ONE auth
# predicate from the VERIFIED DESIGN (hugmesh-device-license-registry memory):
#
#   SUPERADMIN -> ALLOW iff P's node ∈ D.mesh_id AND offered key K enrolled to P.
#   ADMIN      -> DENY  if D.owner_type=='SUPERADMIN';
#                 DENY  if D.domain ≠ DOMAIN_P;
#                 else ALLOW iff ∃ active license l: l.operator==P AND
#                       K ∈ l.key_fingerprints AND
#                       (DEVICE: l.device_id==D.id  OR  DOMAIN: l.target_domain==D.domain).
#   MOD/USER   -> DENY.
#
# against BOTH fail-closed enforcement layers, driven from ONE signed export:
#
#   * LAYER B (per-node sshd) — REAL: it RUNS the actual
#       specs/usr/sbin/hugmesh-authorized-keys-lookup against a per-test
#       fake-root (the script's absolute paths are rewritten under $LKROOT so the
#       UNPRIVILEGED test can stage node.env + the baked pubkey + the signed export
#       cache). The lookup's own verify (sourced from the REAL
#       specs/usr/lib/hugmesh/registry-verify.sh), monotonic-rollback guard,
#       mesh guard, per-node fp match, per-key %f pin, and fail-closed empty-on-
#       error deny are exercised end to end. The signed export is a REAL detached
#       Ed25519 signature over the REAL canonical bytes (we mint a throwaway
#       keypair and bake only its PUBLIC half — exactly the node format).
#
#   * LAYER A (headscale policy) — REAL render: it SOURCES the real renderer
#       functions (render_policy / dev_tag_for_fp / sanitise_tag) from
#       specs/usr/sbin/gen-headscale-policy.sh (main() guarded behind a BASH_SOURCE
#       check) and evaluates the rendered ssh[] against headscale's default-deny
#       SSH semantics, identical to test-layer-a-headscale-acl.sh.
#
# HONESTY (modeled-vs-needs-live-mesh): each assertion is tagged in its banner.
#   [REAL-LAYER-B]   runs the real lookup script + real verify lib.
#   [REAL-LAYER-A]   runs the real policy renderer.
#   [MODEL]          evaluates the predicate against constructed state where the
#                    real enforcement is a LIVE-only behaviour we cannot exercise
#                    off-node (MOD/USER have no unscoped-export entry to drive a
#                    lookup with; the forged-advertise live REJECTION, genuine :22
#                    unreachability, and precise live session-kill need a booted
#                    node + control plane). These are called out, never hidden.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOOKUP_SRC="${REPO}/specs/usr/sbin/hugmesh-authorized-keys-lookup"
VERIFY_LIB="${REPO}/specs/usr/lib/hugmesh/registry-verify.sh"
RENDERER="${REPO}/specs/usr/sbin/gen-headscale-policy.sh"
TMPL="${REPO}/specs/etc/headscale/policy.hujson.tmpl"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

command -v jq      >/dev/null || { echo "jq required";      exit 2; }
command -v openssl >/dev/null || { echo "openssl required"; exit 2; }
command -v base64  >/dev/null || { echo "base64 required";  exit 2; }
command -v awk     >/dev/null || { echo "awk required";     exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT

# ── One throwaway registry signing keypair. We bake ONLY the PUBLIC half (base64
# X.509 SPKI DER — exactly RegistrySigner.publicKeyBase64() / the node file
# registry-pub.ed25519). The private half stays in $WORK and signs the synthetic
# exports; it is NEVER baked. A SECOND, DIFFERENT keypair models a rotated/foreign
# signing key whose public half was NOT re-baked (fleet-lockout fail-closed). ─────
GOOD_PRIV="${WORK}/registry-priv.pem"
GOOD_PUB_B64="${WORK}/registry-pub.ed25519"
FOREIGN_PRIV="${WORK}/foreign-priv.pem"
openssl genpkey -algorithm ed25519 -out "${GOOD_PRIV}"    2>/dev/null || { echo "keygen failed"; exit 2; }
openssl genpkey -algorithm ed25519 -out "${FOREIGN_PRIV}" 2>/dev/null || { echo "keygen failed"; exit 2; }
openssl pkey -in "${GOOD_PRIV}" -pubout -outform DER 2>/dev/null | base64 -w0 > "${GOOD_PUB_B64}"

# ── canonical_bytes_local: reconstruct the EXACT signed bytes for a body the SAME
# way registry-verify.sh canonical_bytes() does (v1\n, mesh=\n, generation=\n, then
# sorted TAB lines op=\tfp=\thost=\tvia=\tkeys=). We feed it the body JSON directly.
canon_for_body() {  # <body.json> -> stdout canonical bytes
    jq -j -e '
        . as $b
        | "v1\n"
        + "mesh=" + (($b.meshId // "")|tostring) + "\n"
        + "generation=" + (($b.generation // 0)|tostring) + "\n"
        + ( ([$b.operators[]?
              | "op=" + (.operator // "")
              + "\tfp=" + (.machineKeyFp // "")
              + "\thost=" + (.hostname // "")
              + "\tvia=" + (.via // "")
              + "\tkeys=" + ((.keyFingerprints // []) | join(","))
              + "\n"
            ]) | add // "" )
    ' "$1" 2>/dev/null
}

# sign_export <body.json> <priv.pem> -> stdout signed-envelope JSON (signed+sig+body)
sign_export() {
    local body="$1" priv="$2" canon sig
    canon="${WORK}/canon.$$.$RANDOM"
    canon_for_body "${body}" > "${canon}" || { rm -f "${canon}"; return 1; }
    sig="$(openssl pkeyutl -sign -inkey "${priv}" -rawin -in "${canon}" 2>/dev/null | base64 -w0)"
    rm -f "${canon}"
    [ -n "${sig}" ] || return 1
    jq -c --arg sig "${sig}" --slurpfile b "${body}" '{signed:true, signature:$sig, body:$b[0]}' <<<'{}'
}

# ── Layer-B fake-root harness: rewrite the lookup's absolute path constants under a
# per-test $LKROOT so an UNPRIVILEGED test can stage the node files and RUN THE REAL
# SCRIPT. Returns the lookup's stdout (an authorized_keys line == ALLOW; empty == DENY).
build_lookup() {  # builds $WORK/lookup.sh once
    sed -e "s#\"/etc/hugmesh#\"${LKROOT}/etc/hugmesh#g" \
        -e "s#\"/var/lib/hugmesh#\"${LKROOT}/var/lib/hugmesh#g" \
        -e "s#\"/usr/lib/hugmesh#\"${LKROOT}/usr/lib/hugmesh#g" \
        "${LOOKUP_SRC}" > "${WORK}/lookup.sh"
    chmod +x "${WORK}/lookup.sh"
}
# stage_node <machine_key_fp> <mesh_id> <pub_b64_file> <signed_export.json> <last_good|"">
stage_node() {
    rm -rf "${LKROOT}"
    mkdir -p "${LKROOT}/etc/hugmesh/registry" \
             "${LKROOT}/var/lib/hugmesh/device-registry" \
             "${LKROOT}/usr/lib/hugmesh"
    cp "${VERIFY_LIB}" "${LKROOT}/usr/lib/hugmesh/registry-verify.sh"
    printf 'MACHINE_KEY_FP=%s\nMESH_ID=%s\n' "$1" "$2" > "${LKROOT}/etc/hugmesh/registry/node.env"
    cp "$3" "${LKROOT}/etc/hugmesh/registry/registry-pub.ed25519"
    cp "$4" "${LKROOT}/var/lib/hugmesh/device-registry/export.json"
    if [ -n "${5:-}" ]; then printf '%s\n' "$5" > "${LKROOT}/var/lib/hugmesh/device-registry/last-good-generation"; fi
    build_lookup
}
# lookup_allows <login_user> <offered_fp> <type> <keyblob> -> rc 0 == ALLOW (non-empty), 1 == DENY
lookup_allows() {
    local out; out="$("${WORK}/lookup.sh" "$1" "$2" "$3" "$4" 2>/dev/null)"
    [ -n "${out}" ]
}
LKROOT="${WORK}/lkroot"

# ── Build the canonical VERIFIED export body (post-#28 shape: ADMIN licenses ONLY;
# superadmin/core + other-domain nodes ABSENT by BFF compile). alice holds a
# DEVICE license on node-a (fpA, own-domain) pinning SHA256:ka, and a DOMAIN
# license that pins SHA256:ka onto node-b (fpB). core-1 (fpCORE), other-domain
# node-z (fpZ), and unlicensed own-domain node-u (fpU) are deliberately NOT here.
BODY_G11="${WORK}/body11.json"
cat > "${BODY_G11}" <<'JSON'
{ "meshId":"east-01", "generation":11, "operators":[
  {"operator":"alice","machineKeyFp":"fpA","hostname":"node-a","via":"DEVICE-LICENSE","keyFingerprints":["SHA256:ka"]},
  {"operator":"alice","machineKeyFp":"fpB","hostname":"node-b","via":"DOMAIN-LICENSE","keyFingerprints":["SHA256:ka"]}
] }
JSON
EXPORT_G11="${WORK}/export11.json"
sign_export "${BODY_G11}" "${GOOD_PRIV}" > "${EXPORT_G11}" || { echo "sign g11 failed"; exit 2; }

echo "== Device-license registry — ALLOW+DENY role matrix =="
echo "-- sanity: the REAL verify lib accepts our REAL sig over the REAL canonical bytes --"
# shellcheck source=/dev/null
. "${VERIFY_LIB}"
if verify_export "${EXPORT_G11}" "${GOOD_PUB_B64}"; then ok "[REAL] verify_export accepts the signed gen=11 export (sig+canonical+baked-pub round-trip)"
else bad "[REAL] verify_export should accept a correctly-signed export"; fi

# ───────────────────────────────────────────────────────────────────────────────
echo
echo "== LAYER B (per-node sshd) — REAL lookup script ============================"

echo "-- Case 1: ADMIN -> own LICENSED device (DEVICE-LICENSE) on :22 (ALLOW) [REAL-LAYER-B] --"
stage_node "fpA" "east-01" "${GOOD_PUB_B64}" "${EXPORT_G11}" "11"
if lookup_allows "adminuser" "SHA256:ka" "ssh-ed25519" "AAAAKEYBLOBka"; then
    ok "alice's pinned key SHA256:ka authorises on node-a (fpA) — lookup emitted the offered key"
else bad "alice SHOULD be allowed onto her own licensed device node-a"; fi
echo "-- Case 1b: same predicate via a DOMAIN-LICENSE pin onto node-b (ALLOW) [REAL-LAYER-B] --"
stage_node "fpB" "east-01" "${GOOD_PUB_B64}" "${EXPORT_G11}" "11"
if lookup_allows "adminuser" "SHA256:ka" "ssh-ed25519" "AAAAKEYBLOBka"; then
    ok "DOMAIN-LICENSE pins SHA256:ka onto node-b (fpB) — lookup ALLOW"
else bad "DOMAIN-LICENSE should authorise alice onto node-b"; fi

echo "-- Case 2: ADMIN -> SUPERADMIN-owned / CORE node on :22 (DENY) [REAL-LAYER-B] --"
# A core node owner_type=SUPERADMIN is NEVER registry-enforced (no lookup installed)
# AND never appears in the export. We model the export-absence on a node that WOULD
# (incorrectly) run a lookup: with no entry for fpCORE, the lookup denies. There is
# also no admin key baked. This is the export-skips-it half; the never-installed
# half is the provision-class invariant asserted in Case 2c.
stage_node "fpCORE" "east-01" "${GOOD_PUB_B64}" "${EXPORT_G11}" "11"
if lookup_allows "adminuser" "SHA256:ka" "ssh-ed25519" "AAAAKEYBLOBka"; then
    bad "ADMIN must NOT reach a core node — export carries no fpCORE entry"
else ok "core node fpCORE absent from export -> lookup empty -> DENY (no admin key + export skips it)"; fi

echo "-- Case 3: ADMIN -> OTHER-domain node on :22 (DENY) [REAL-LAYER-B] --"
# node-z resides in another domain; the BFF compile never emits a cross-domain edge
# (l.target_domain==D.domain==DOMAIN_P fails), so fpZ is absent => deny.
stage_node "fpZ" "east-01" "${GOOD_PUB_B64}" "${EXPORT_G11}" "11"
if lookup_allows "adminuser" "SHA256:ka" "ssh-ed25519" "AAAAKEYBLOBka"; then
    bad "ADMIN must NOT reach an other-domain node fpZ"
else ok "other-domain node fpZ absent from export -> DENY (cross-domain isolation at compile)"; fi

echo "-- Case 4: ADMIN -> UNLICENSED own-domain node on :22 (DENY) [REAL-LAYER-B] --"
# node-u is own-domain + registry-enforced but alice holds NO license for it: no
# entry for fpU => default-deny is the steady state.
stage_node "fpU" "east-01" "${GOOD_PUB_B64}" "${EXPORT_G11}" "11"
if lookup_allows "adminuser" "SHA256:ka" "ssh-ed25519" "AAAAKEYBLOBka"; then
    bad "ADMIN must NOT reach an UNLICENSED own-domain node fpU"
else ok "no license pins any key onto fpU -> DENY (default-deny steady state)"; fi

echo "-- Case 5: the pinned-key %f MUST match — right node, WRONG offered key (DENY) [REAL-LAYER-B] --"
# alice IS licensed on node-a, but offers a key whose fingerprint is not pinned.
stage_node "fpA" "east-01" "${GOOD_PUB_B64}" "${EXPORT_G11}" "11"
if lookup_allows "adminuser" "SHA256:NOTPINNED" "ssh-ed25519" "AAAAKEYBLOBxx"; then
    bad "an unpinned offered key MUST be denied even on a licensed node (FIX-PINKEY)"
else ok "offered %f=SHA256:NOTPINNED not in entry.keyFingerprints -> DENY (per-key pin holds)"; fi

echo "-- Case 6: REVOKE -> next-higher generation drops the pin (DENY) [REAL-LAYER-B] --"
# gen=12 export = alice's license on node-a REVOKED (operators[] no longer pins
# node-a for her). The sync agent only writes forward (strict gen>last-good); the
# next auth re-runs the lookup against the new cache => deny.
BODY_G12="${WORK}/body12.json"
cat > "${BODY_G12}" <<'JSON'
{ "meshId":"east-01", "generation":12, "operators":[
  {"operator":"alice","machineKeyFp":"fpB","hostname":"node-b","via":"DOMAIN-LICENSE","keyFingerprints":["SHA256:ka"]}
] }
JSON
EXPORT_G12="${WORK}/export12.json"
sign_export "${BODY_G12}" "${GOOD_PRIV}" > "${EXPORT_G12}" || { echo "sign g12 failed"; exit 2; }
stage_node "fpA" "east-01" "${GOOD_PUB_B64}" "${EXPORT_G12}" "12"
if lookup_allows "adminuser" "SHA256:ka" "ssh-ed25519" "AAAAKEYBLOBka"; then
    bad "after revoke (gen=12 drops node-a for alice) the lookup MUST deny"
else ok "revoke @ gen=12 -> fpA no longer pinned -> next auth re-check DENIES (FIX-REVOKE convergence)"; fi
echo "   (NOTE: the LIVE kill of an already-established session is best-effort in the"
echo "    sync agent's revoked_session_sweep; the AUTHORITATIVE cut is this per-auth"
echo "    re-check, which IS exercised here. [MODEL: live-kill needs a booted node])"

echo "-- Case 7: UNSIGNED export (signed=false / null sig) REJECT -> fail-closed [REAL-LAYER-B] --"
UNSIGNED="${WORK}/unsigned.json"
jq -c '{signed:false, signature:null, body:.}' "${BODY_G11}" > "${UNSIGNED}"
stage_node "fpA" "east-01" "${GOOD_PUB_B64}" "${UNSIGNED}" "11"
if lookup_allows "adminuser" "SHA256:ka" "ssh-ed25519" "AAAAKEYBLOBka"; then
    bad "an UNSIGNED export must be rejected (fail-closed)"
else ok "unsigned export -> verify_export fails -> lookup empty -> DENY (fail-closed)"; fi

echo "-- Case 8: TAMPERED body (sig no longer covers it) REJECT -> fail-closed [REAL-LAYER-B] --"
TAMPERED="${WORK}/tampered.json"
# keep the valid gen=11 signature but inject an extra operator pinning fpA for mallory.
jq -c '.body.operators += [{"operator":"mallory","machineKeyFp":"fpA","hostname":"node-a","via":"DEVICE-LICENSE","keyFingerprints":["SHA256:evil"]}]' "${EXPORT_G11}" > "${TAMPERED}"
stage_node "fpA" "east-01" "${GOOD_PUB_B64}" "${TAMPERED}" "11"
if lookup_allows "adminuser" "SHA256:evil" "ssh-ed25519" "AAAAKEYBLOBevil"; then
    bad "a TAMPERED body must fail signature verify (no forged grant)"
else ok "tampered body -> canonical bytes change -> Ed25519 verify fails -> DENY (fail-closed)"; fi

echo "-- Case 9: ROLLBACK (cache gen < recorded last-good) REJECT -> keep last-good [REAL-LAYER-B] --"
# A correctly-signed but OLD export (gen=11) presented when last-good already = 20
# (an attacker replays a pre-revoke generation). The lookup's own gen<last-good
# guard rejects it even though the signature is valid.
stage_node "fpA" "east-01" "${GOOD_PUB_B64}" "${EXPORT_G11}" "20"
if lookup_allows "adminuser" "SHA256:ka" "ssh-ed25519" "AAAAKEYBLOBka"; then
    bad "a rolled-back cache (gen=11 < last-good=20) must be rejected"
else ok "cache gen=11 < last-good=20 -> rollback guard DENIES (fail-closed to last-good)"; fi
echo "   -- and the SYNC agent's STRICT gen>last-good acceptance guard (gen<=last-good REJECT) [REAL] --"
if check_monotonic 11 <(printf '11\n'); then bad "sync agent must REJECT gen==last-good (strict >)"
else ok "check_monotonic: gen=11 == last-good=11 REJECTED by sync (strict-monotonic, no replay)"; fi
if check_monotonic 12 <(printf '11\n'); then ok "check_monotonic: gen=12 > last-good=11 ACCEPTED forward step"
else bad "sync agent should accept a forward generation"; fi

echo "-- Case 10: FOREIGN/ROTATED signing key whose public half was NOT re-baked REJECT [REAL-LAYER-B] --"
# Sign a perfectly-formed export with a DIFFERENT private key; the node still bakes
# the OLD public half. This is the rotation-without-rebake fleet-lockout case.
FOREIGN_EXPORT="${WORK}/foreign.json"
sign_export "${BODY_G11}" "${FOREIGN_PRIV}" > "${FOREIGN_EXPORT}" || { echo "sign foreign failed"; exit 2; }
stage_node "fpA" "east-01" "${GOOD_PUB_B64}" "${FOREIGN_EXPORT}" "11"
if lookup_allows "adminuser" "SHA256:ka" "ssh-ed25519" "AAAAKEYBLOBka"; then
    bad "an export signed by a NON-baked key must be rejected"
else ok "foreign-key signature -> verify against baked pub fails -> DENY (rotation w/o rebake = fail-closed; see runbook)"; fi

echo "-- Case 11: MESH MISMATCH — a valid export for ANOTHER mesh must not authorise [REAL-LAYER-B] --"
BODY_WEST="${WORK}/bodywest.json"
sed 's/east-01/west-02/' "${BODY_G11}" > "${BODY_WEST}"
EXPORT_WEST="${WORK}/exportwest.json"
sign_export "${BODY_WEST}" "${GOOD_PRIV}" > "${EXPORT_WEST}" || { echo "sign west failed"; exit 2; }
stage_node "fpA" "east-01" "${GOOD_PUB_B64}" "${EXPORT_WEST}" "11"  # node baked mesh=east-01
if lookup_allows "adminuser" "SHA256:ka" "ssh-ed25519" "AAAAKEYBLOBka"; then
    bad "a west-02 export must not authorise on an east-01 node"
else ok "export mesh=west-02 != baked mesh=east-01 -> DENY (mesh guard)"; fi

echo "-- Case 12: baked-key-after-AuthorizedKeysFile-none — the cmd is the SOLE source [MODEL-config] --"
# The lookup CANNOT OR against any file: device-registry.conf sets AuthorizedKeysFile
# none. We assert the shipped drop-in encodes that contract (the live 'a stale baked
# key is ignored' behaviour is sshd's, needs a booted node).
DROPIN="${REPO}/specs/etc/ssh/sshd_config.d/device-registry.conf"
if grep -Eq '^[[:space:]]*AuthorizedKeysFile[[:space:]]+none[[:space:]]*$' "${DROPIN}" \
   && grep -Eq '^[[:space:]]*AuthorizedKeysCommand[[:space:]]+/usr/sbin/hugmesh-authorized-keys-lookup' "${DROPIN}" \
   && grep -Eq '^[[:space:]]*AuthorizedKeysCommandUser[[:space:]]+nobody' "${DROPIN}"; then
    ok "device-registry.conf: AuthorizedKeysFile none + AuthorizedKeysCommand(lookup) + User nobody (FIX-AUTHKEYSFILE-NONE)"
else bad "device-registry.conf must make the lookup the SOLE key source (none + command + nobody)"; fi
echo "   ([MODEL] that a booted sshd with this drop-in ignores any stale baked"
echo "    authorized_keys is sshd semantics — NEEDS-LIVE-NODE; the contract is asserted here.)"

# ───────────────────────────────────────────────────────────────────────────────
echo
echo "== LAYER A (headscale SSH ACL) — REAL policy render ========================"
# Source the real renderer functions (main guarded out when sourced).
NODE_ENV=/dev/null
# shellcheck source=/dev/null
. "${RENDERER}"
POLICY_TMPL="${TMPL}"
TS_SSH_USER="superadmin"
MESH_ID="east-01"
MESH_TAG="tag:mesh_$(sanitise_tag "${MESH_ID}")"
strip(){ sed -e 's#//.*$##' "$1"; }

LA_EXPORT="${WORK}/la-export.json"
cat > "${LA_EXPORT}" <<'JSON'
{ "signed": true, "signature":"x", "body": {
  "meshId":"east-01", "generation": 11,
  "operators": [
    {"operator":"alice","machineKeyFp":"fpA","hostname":"node-a","keyFingerprints":["SHA256:ka"],"via":"DEVICE-LICENSE"},
    {"operator":"alice","machineKeyFp":"fpB","hostname":"node-b","keyFingerprints":["SHA256:ka"],"via":"DOMAIN-LICENSE"}
  ] } }
JSON
LA_RENDERED="${WORK}/la-rendered.hujson"
render_policy "${LA_EXPORT}" "${LA_RENDERED}" || { echo "render_policy FAILED"; exit 1; }

TAG_A="tag:$(dev_tag_for_fp fpA)"
TAG_CORE="tag:$(dev_tag_for_fp fpCORE)"
TAG_Z="tag:$(dev_tag_for_fp fpZ)"

# headscale-SSH evaluator (default-deny; ALLOW iff a rendered accept matches src+dst+user).
ssh_allowed() {
    local src="$1" asuser="$2"; shift 2
    local nodetags="$*"
    strip "${LA_RENDERED}" | jq -e --arg src "${src}" --arg u "${asuser}" --arg nt "${nodetags}" '
        ($nt | split(" ")) as $carried
        | [ .ssh[] | select(.action=="accept")
            | select(.src | index($src)) | select(.users | index($u))
            | select([.dst[] as $d | $carried | index($d)] | any) ]
        | length > 0' >/dev/null 2>&1
}

echo "-- Case 13: ADMIN -> own licensed node-a (ALLOW) [REAL-LAYER-A] --"
if ssh_allowed "tag:hugmesh" "superadmin" "${TAG_A} tag:hugmesh ${MESH_TAG}"; then
    ok "rendered ssh edge to ${TAG_A} present -> admin reaches node-a:22"
else bad "admin should reach node-a:22"; fi

echo "-- Case 14: ADMIN -> SUPERADMIN/core node (DENY: export omits it) [REAL-LAYER-A] --"
if ssh_allowed "tag:hugmesh" "superadmin" "${TAG_CORE} tag:hugmesh ${MESH_TAG}"; then
    bad "admin must NOT reach a core node"
else ok "no tag:dev_<fpCORE> edge -> default-deny -> admin DENIED to core node:22"; fi

echo "-- Case 15: ADMIN -> OTHER-domain node (DENY) [REAL-LAYER-A] --"
if ssh_allowed "tag:hugmesh" "superadmin" "${TAG_Z} tag:hugmesh ${MESH_TAG}"; then
    bad "admin must NOT reach an other-domain node"
else ok "no tag:dev_<fpZ> edge -> default-deny -> admin DENIED to node-z:22"; fi

echo "-- Case 16: SUPERADMIN in-mesh -> ALL mesh nodes incl. core (ALLOW via tag:mesh) [REAL-LAYER-A] --"
allsup=1
for nt in "${TAG_CORE}" "${TAG_A}" "${TAG_Z}"; do
    ssh_allowed "tag:superadmin" "superadmin" "${nt} ${MESH_TAG} tag:hugmesh" || allsup=0
done
[ "${allsup}" = 1 ] && ok "superadmin reaches core/node-a/node-z:22 via tag:mesh_east-01 (incl. nodes the export omits)" \
                     || bad "superadmin should reach every in-mesh node via tag:mesh"

echo "-- Case 17: SUPERADMIN NOT in mesh -> DENY (cross-mesh / un-meshed) [REAL-LAYER-A] --"
# A node NOT force-tagged tag:mesh_east-01 (e.g. only tag:mesh_west-02, or never
# enrolled so carrying neither) is unreachable by the mesh-scoped superadmin rule.
if ssh_allowed "tag:superadmin" "superadmin" "tag:mesh_west-02 tag:hugmesh"; then
    bad "superadmin must NOT reach a node outside its mesh"
else ok "node lacks tag:mesh_east-01 -> superadmin DENIED (mesh-membership is the precondition)"; fi

echo "-- Case 18: FORGED TAG — server-assigned dst tags are control-owned, not self-applyable [REAL-LAYER-A] --"
# A node self-advertising tag:dev_<otherfp> cannot win: the dst tags live in
# tagOwners under the control 'hugmesh' user only; the LIVE override (forced tag
# beats --advertise-tags) is a NEEDS-HEADSCALE assertion, but the policy ENCODES
# the non-self-applyability here.
ownerok=1
strip "${LA_RENDERED}" | jq -e --arg t "${TAG_A}" '.tagOwners[$t] == ["hugmesh"]' >/dev/null 2>&1 || ownerok=0
strip "${LA_RENDERED}" | jq -e '.tagOwners["tag:superadmin"] == ["hugmesh"]' >/dev/null 2>&1 || ownerok=0
[ "${ownerok}" = 1 ] && ok "tag:dev_<fpA> + tag:superadmin owned by control 'hugmesh' only -> a node cannot self-advertise a forged dst" \
                     || bad "server-forced dst tags must be control-owned in tagOwners"
echo "   ([MODEL] that a LIVE headscale REJECTS a forged --advertise-tags and the"
echo "    forced tag WINS is NEEDS-HEADSCALE; the non-self-applyable ownership is asserted here.)"

# ───────────────────────────────────────────────────────────────────────────────
echo
echo "== MOD / USER roles ========================================================"
echo "-- Case 19: MOD -> any node (DENY) [MODEL] --"
echo "-- Case 20: USER -> any node (DENY) [MODEL] --"
# MOD/USER are not operators in ANY license row, so the unscoped signed export
# carries NO entry for them on ANY node — there is literally no entry to drive a
# real lookup with, which IS the deny: the predicate is MOD/USER->DENY, total.
# We assert the structural invariant: NO operator in the export maps to a mod/user
# principal, and a lookup offering a non-pinned key on a licensed node denies
# (already shown Case 5). The role-derivation itself is a BFF-compile property
# (unscoped export can't see roles -> it only ever compiles ADMIN licenses).
modusr_ok=1
jq -e '[.body.operators[]?.via] | all(. == "DEVICE-LICENSE" or . == "DOMAIN-LICENSE")' "${EXPORT_G11}" >/dev/null 2>&1 || modusr_ok=0
[ "${modusr_ok}" = 1 ] && ok "every export entry is an ADMIN DEVICE/DOMAIN license — no MOD/USER (or SUPERADMIN) entry exists to authorise -> DENY by absence" \
                       || bad "export must carry ONLY ADMIN licenses (post-#28 compile)"
echo "   ([MODEL] MOD/USER never enrol an SSH license, so there is no row + no export"
echo "    entry; the live 'a mod's key is refused at :22' is the same default-deny as"
echo "    Case 4/5, driven there. The role gate is the BFF grant path, not the node.)"

echo
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

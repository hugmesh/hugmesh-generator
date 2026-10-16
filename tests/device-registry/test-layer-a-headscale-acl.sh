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
#
# ── PART 2 (2026-07-30): THE COMPILE-SIDE RECONCILIATION ──────────────────────
# Layer-A has TWO would-be writers of one headscale policy: the node-side
# renderer above (LIVE on every control node) and hugmesh-admin-bff-api's
# HeadscaleAclCompiler + reconcile loop (SHIPS DARK behind
# app.registry.headscale-acl.enabled=false). Nothing made them agree, and they
# did not: the dark compiler addressed nodes by a tag no node carries, emitted an
# empty acls[] that would have blanked the k8s data-plane rule, omitted the
# always-on SUPERADMIN mesh rule and the tagOwners, named operator groups
# headscale does not know, pointed its base-url at a namespace this platform does
# not have, and would have PUT a DB-mode-only policy at a headscale running
# policy mode:file. Whoever eventually flips that switch must not walk into any
# of that, so this gate now asserts BOTH sides against each other.
#
# The cross-repo half follows lint:reserved-prefixes' idiom (the repo's other
# code-copy gate): the sibling checkout is supplied by the CI job, and an ABSENT
# sibling exits 3 INCOMPLETE rather than printing [SKIP] and going green — a
# silently-skipped assertion is exactly how a live drift sat on a green main
# before. Point it at a checkout with LAYERA_BFF_ROOT (or LAYERA_SIBLING_ROOT,
# which holds a <root>/hugmesh-admin-bff-api clone).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RENDERER="${REPO}/specs/usr/sbin/gen-headscale-policy.sh"
FORCETAGS_SRC="${REPO}/specs/usr/sbin/hugmesh-headscale-forcetags"
TMPL="${REPO}/specs/etc/headscale/policy.hujson.tmpl"
BOOTSTRAP="${REPO}/specs/etc/headscale/policy.bootstrap.hujson"
HS_CONFIG="${REPO}/specs/etc/headscale/config.yaml"
HS_SERVICE="${REPO}/specs/cluster/manifests/headscale/service.yaml"
HS_SVC_APP="${REPO}/specs/cluster/apps/07-headscale-svc.yaml"
PROVISION="${REPO}/specs/etc/keys-provision/provision.sh"

# Where the sibling hugmesh-admin-bff-api checkout lives (the BFF-side compiler).
SIBLING_ROOT="${LAYERA_SIBLING_ROOT:-${REPO}/.layera-siblings}"
BFF_ROOT="${LAYERA_BFF_ROOT:-${SIBLING_ROOT}/hugmesh-admin-bff-api}"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
strip(){ sed -e 's#//.*$##' "$1"; }   # strip hujson comments -> strict JSON
# The EXECUTABLE lines of a Java file: javadoc/block-comment continuation lines and
# whole-line // comments removed. The reconciliation checks below assert what the
# compiler DOES, so a shape named only in a regression note must not trip them (and,
# conversely, cannot be used to hide a live emission).
java_code(){ grep -v -E '^[[:space:]]*(/?\*|//)' "$1"; }

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

# ══════════════════════════════════════════════════════════════════════════════
# PART 1b — THE APPLY LEG: policy set -> restart -> ready -> force tags
# ══════════════════════════════════════════════════════════════════════════════
# The fleet ships headscale policy.mode:file, where `headscale policy set` is
# REFUSED and the file is read at STARTUP only. The recurring writer used to throw
# that error away and never reload, so the pki node rewrote policy.hujson every
# minute while the running headscale kept serving the old one. These cases drive the
# REAL apply_policy / retry_pending against stub `headscale` + `rc-service` binaries.
echo
echo "== Layer-A apply leg — a refused 'policy set' must restart headscale, and a failed apply must be retried =="

APPLY_ROOT="$(mktemp -d)"
trap 'rm -rf "${APPLY_ROOT}" 2>/dev/null; rm -f "${EXPORT}" "${RENDERED}" 2>/dev/null' EXIT

# One case = one fresh state dir with stub binaries. Behaviour is switched by files
# in ${STUB}: mode_db (policy set succeeds), restart_fail (rc-service exits 1),
# reject (headscale does not come back up when its policy file contains REJECTME),
# slow_restarts (holds N: the first N restarts do not come up in time, restart N+1 does).
REAL_MV="$(command -v mv)"
apply_new_case() {
    CASE="${APPLY_ROOT}/$1"; STUB="${CASE}/bin"; mkdir -p "${STUB}" "${CASE}/cache" "${CASE}/etc"
    : > "${CASE}/calls"
    cat > "${STUB}/headscale" <<STUBEOF
#!/bin/bash
case "\$1 \$2" in
  "policy set")
      echo "policy-set" >> "${CASE}/calls"
      [ -e "${STUB}/mode_db" ] && exit 0
      echo "Failed to set ACL Policy: rpc error: code = Unknown desc = update is disabled for modes other than 'database'" >&2
      exit 1 ;;
  "nodes list") [ -e "${STUB}/up" ] ;;
esac
STUBEOF
    cat > "${STUB}/rc-service" <<STUBEOF
#!/bin/bash
echo "restart \$*" >> "${CASE}/calls"
[ -e "${STUB}/restart_fail" ] && exit 1
# slow_restarts holds N: the first N restarts leave headscale down (a LATE start, not a
# rejected policy); restart N+1 brings it up.
if [ -s "${STUB}/slow_restarts" ] && [ "\$(grep -c '^restart' "${CASE}/calls")" -le "\$(cat "${STUB}/slow_restarts")" ]; then
    rm -f "${STUB}/up"; exit 0
fi
if [ -e "${STUB}/reject" ] && grep -F REJECTME "${CASE}/etc/policy.hujson" >/dev/null 2>&1; then
    rm -f "${STUB}/up"
else
    : > "${STUB}/up"
fi
exit 0
STUBEOF
    # install_fail: the final mv of a policy into place fails (disk full / read-only
    # /etc/headscale), whoever runs the test (a chmod would not stop root).
    cat > "${STUB}/mv" <<STUBEOF
#!/bin/bash
if [ -e "${STUB}/install_fail" ]; then for a in "\$@"; do last="\$a"; done; [ "\$last" = "${CASE}/etc/policy.hujson" ] && exit 1; fi
exec ${REAL_MV} "\$@"
STUBEOF
    printf '#!/bin/bash\necho forcetags >> "%s/calls"\n' "${CASE}" > "${STUB}/forcetags"
    printf '#!/bin/bash\nexit 0\n' > "${STUB}/logger"
    chmod +x "${STUB}"/*
    : > "${STUB}/up"
    printf '%s\n' '{"acls":[],"note":"OLD"}' > "${CASE}/etc/policy.hujson"
    printf '%s\n' '{"acls":[],"note":"NEW"}' > "${CASE}/new.hujson"
}
# Run one command (an apply_policy / retry_pending call) against the case, in a
# subshell so the overridden globals never leak. Output lands in ${CASE}/out.
apply_run() {
    ( PATH="${STUB}:${PATH}"
      POLICY_OUT="${CASE}/etc/policy.hujson"; CACHE_DIR="${CASE}/cache"
      APPLIED_MARK="${CASE}/cache/applied-policy-hash"; FORCETAGS="${STUB}/forcetags"
      ALARM_MARK="${CASE}/cache/apply-failed"; PENDING_POLICY="${CASE}/cache/pending-policy.hujson"
      PENDING_TRIES="${CASE}/cache/pending-tries"
      EXPORT_JSON="${CASE}/cache/export.json"; LAST_GOOD="${CASE}/cache/last-good-generation"
      HS_READY_TRIES=3; HS_READY_SLEEP=0
      "$@" ) >> "${CASE}/out" 2>&1
}
n_calls() { grep -c -F -- "$1" "${CASE}/calls" 2>/dev/null; }
hash_of() { sha256sum "$1" | awk '{print $1}'; }

echo "-- Scenario: mode:file refuses 'policy set' -> error is logged, headscale restarted, tags forced, applied marker written --"
apply_new_case file_mode
apply_run apply_policy "${CASE}/new.hujson"
grep -F "update is disabled for modes other than 'database'" "${CASE}/out" >/dev/null \
    && ok "the real 'policy set' refusal text reaches the log (stderr is captured, not discarded)" \
    || bad "the 'policy set' refusal text is NOT in the log — stderr is still being thrown away"
[ "$(n_calls 'restart headscale restart')" = 1 ] \
    && ok "headscale is restarted exactly once so the rewritten policy.hujson is loaded" \
    || bad "headscale was not restarted after the refused 'policy set' (restarts: $(n_calls 'restart headscale restart')) — the running server keeps the old policy"
cmp -s "${CASE}/etc/policy.hujson" "${CASE}/new.hujson" \
    && ok "the new policy is the one installed on disk" || bad "policy.hujson does not hold the rendered policy"
[ "$(n_calls forcetags)" = 1 ] \
    && ok "force-tags runs once, after headscale answers" || bad "force-tags did not run exactly once (ran $(n_calls forcetags))"
[ "$(cat "${CASE}/cache/applied-policy-hash" 2>/dev/null)" = "$(hash_of "${CASE}/new.hujson")" ] \
    && ok "applied marker records the hash of the policy now loaded" || bad "applied marker missing or wrong after a successful restart"

echo "-- Scenario: the same policy on the next tick is a no-op (no restart storm every 60s) --"
apply_run apply_policy "${CASE}/new.hujson"
[ "$(n_calls 'restart headscale restart')" = 1 ] && [ "$(n_calls policy-set)" = 1 ] && [ "$(n_calls forcetags)" = 1 ] \
    && ok "an unchanged, already-applied policy triggers no policy set, no restart, no force-tags" \
    || bad "an unchanged policy re-applied (set=$(n_calls policy-set) restart=$(n_calls 'restart headscale restart') tags=$(n_calls forcetags))"

echo "-- Scenario: database mode accepts 'policy set' -> no restart --"
apply_new_case db_mode; : > "${STUB}/mode_db"
apply_run apply_policy "${CASE}/new.hujson"
[ "$(n_calls policy-set)" = 1 ] && [ "$(n_calls 'restart headscale restart')" = 0 ] \
    && ok "when 'policy set' succeeds headscale is NOT restarted" \
    || bad "database mode restarted headscale anyway (set=$(n_calls policy-set) restart=$(n_calls 'restart headscale restart'))"
[ "$(n_calls forcetags)" = 1 ] && [ -s "${CASE}/cache/applied-policy-hash" ] \
    && ok "database mode still force-tags and records the applied marker" || bad "database mode skipped force-tags or the marker"

echo "-- Scenario: the restart FAILS on tick 1 -> not marked applied, retried on tick 2 --"
apply_new_case restart_fails; : > "${STUB}/restart_fail"
apply_run apply_policy "${CASE}/new.hujson"
grep -F "restart FAILED" "${CASE}/out" >/dev/null \
    && ok "a failed restart is reported loudly" || bad "a failed restart was not reported"
[ ! -e "${CASE}/cache/applied-policy-hash" ] && [ "$(n_calls forcetags)" = 0 ] \
    && ok "a failed restart leaves NO applied marker and does not force tags" \
    || bad "a failed restart was recorded as applied"
rm -f "${STUB}/restart_fail"
apply_run retry_pending
[ "$(n_calls 'restart headscale restart')" = 2 ] && [ "$(cat "${CASE}/cache/applied-policy-hash" 2>/dev/null)" = "$(hash_of "${CASE}/new.hujson")" ] \
    && ok "tick 2 retries the activation WITHOUT a fresh export (the cursor already advanced) and succeeds" \
    || bad "the failed apply was never retried (restarts: $(n_calls 'restart headscale restart'))"
[ "$(n_calls forcetags)" = 1 ] \
    && ok "force-tags runs once the retry lands" || bad "force-tags did not run after the retry"
apply_run retry_pending
[ "$(n_calls 'restart headscale restart')" = 2 ] \
    && ok "once applied, retry_pending is a no-op" || bad "retry_pending restarted headscale again after a successful apply"

echo "-- Scenario: apply_policy itself also retries an on-disk-but-unapplied policy --"
apply_new_case retry_via_apply; : > "${STUB}/restart_fail"
apply_run apply_policy "${CASE}/new.hujson"
rm -f "${STUB}/restart_fail"
apply_run apply_policy "${CASE}/new.hujson"
[ "$(n_calls 'restart headscale restart')" = 2 ] && [ -s "${CASE}/cache/applied-policy-hash" ] \
    && ok "an identical re-render is NOT skipped just because the file is already on disk" \
    || bad "an identical re-render was skipped although the policy was never applied"

echo "-- Scenario: the entrypoint runs the pending-retry before it fetches --"
awk '/^main\(\)/{m=1} m' "${RENDERER}" | grep -F 'retry_pending' >/dev/null \
    && ok "main() calls retry_pending (the fetch path alone cannot retry: its cursor already advanced)" \
    || bad "main() never calls retry_pending — a failed apply would wait for the next export generation"

echo "-- Scenario: headscale rejects the new policy at startup -> rolled back to the previous policy --"
apply_new_case rejected; : > "${STUB}/reject"
printf '%s\n' '{"acls":[],"note":"REJECTME"}' > "${CASE}/new.hujson"
apply_run apply_policy "${CASE}/new.hujson"
grep -F OLD "${CASE}/etc/policy.hujson" >/dev/null && ! grep -F REJECTME "${CASE}/etc/policy.hujson" >/dev/null \
    && ok "the previous policy.hujson is restored" || bad "the rejected policy was left on disk"
[ -e "${STUB}/up" ] && [ "$(n_calls 'restart headscale restart')" = 3 ] \
    && ok "headscale is restarted twice on the rejected policy (a late start gets a second try), then once more on the restored policy, and is up" \
    || bad "headscale was left down after rejecting the policy"
[ "$(n_calls forcetags)" = 0 ] \
    && ok "tags are not forced on a policy headscale rejected" || bad "force-tags ran for a rejected policy"
[ "$(cat "${CASE}/cache/applied-policy-hash" 2>/dev/null)" = "$(hash_of "${CASE}/etc/policy.hujson")" ] \
    && ok "applied marker names the restored policy, so retry_pending does not flap" || bad "applied marker does not match the restored policy"

# ── The REVOCATION must survive a failed or late apply ─────────────────────────
# Finding headscale-acl-relocation-revocation-lag. The rollback above used to restore
# the previous policy VERBATIM. When the new generation REVOKED an operator, that put
# the revoked operator's ssh edge back, marked it applied, and (the export cursor
# having advanced) nothing ever fetched that generation again: the revocation stayed
# un-applied until some LATER generation, silently. Same outcome when headscale was
# only slow to start. The cases below pin the fail-CLOSED behaviour.
echo "-- Scenario: a REVOKED edge is never served again after headscale refuses the new policy --"
EDGE() { jq -cn --arg d "$1" --arg s "$2" '{action:"accept",src:[$s],dst:[$d],users:["admin"]}'; }
E_SUP="$(EDGE tag:mesh_east-01 tag:superadmin)"; E_ALICE="$(EDGE tag:dev_alice tag:hugmesh)"; E_BOB="$(EDGE tag:dev_bob tag:hugmesh)"
E_CAROL="$(EDGE tag:dev_carol tag:hugmesh)"
# policy <note> <edge>... -> a policy whose ssh[] holds exactly those edges
mkpol() { local note="$1"; shift; printf '%s\n' "$@" | jq -s --arg n "${note}" '{acls:[],note:$n,ssh:.}'; }
# does the policy file grant ssh to <dst tag>?
serves() { jq -e --arg d "$2" 'any(.ssh[]?; .dst == [$d])' "$1" >/dev/null 2>&1; }
revocation_case() {     # <name> <new-note> <new edges...>: OLD = sup+alice+bob, running; NEW = the arguments
    apply_new_case "$1"; local note="$2"; shift 2
    mkpol OLD "${E_SUP}" "${E_ALICE}" "${E_BOB}" > "${CASE}/etc/policy.hujson"
    mkpol "${note}" "$@" > "${CASE}/new.hujson"
}
revocation_case revoke_rejected REJECTME "${E_SUP}" "${E_ALICE}"; : > "${STUB}/reject"
apply_run apply_policy "${CASE}/new.hujson"
serves "${CASE}/etc/policy.hujson" tag:dev_bob \
    && bad "EXPLOIT: bob's edge was revoked by the export but headscale was left serving it after the apply failed" \
    || ok "bob's revoked edge is NOT served after headscale refused the new policy"
serves "${CASE}/etc/policy.hujson" tag:dev_alice && serves "${CASE}/etc/policy.hujson" tag:mesh_east-01 \
    && ok "edges the new policy keeps (alice, the superadmin mesh edge) are still served" \
    || bad "the fallback dropped an edge the new policy still carries"
[ -e "${STUB}/up" ] && ok "headscale is up on the narrowed fallback" || bad "headscale was left down"
grep -F REJECTME "${CASE}/etc/policy.hujson" >/dev/null \
    && bad "the refused policy was left on disk" || ok "the refused policy is not the one on disk"
[ -s "${CASE}/cache/apply-failed" ] && grep -q '^since=' "${CASE}/cache/apply-failed" \
    && ok "an ALARM file is raised (a revocation is not in force)" || bad "no alarm was raised for the failed apply"
cmp -s "${CASE}/cache/pending-policy.hujson" "${CASE}/new.hujson" \
    && ok "the refused policy is kept as pending, to be retried" || bad "the refused policy was dropped (only a later export generation could bring it back)"
[ "$(cat "${CASE}/cache/applied-policy-hash" 2>/dev/null)" = "$(hash_of "${CASE}/etc/policy.hujson")" ] \
    && ok "applied marker names the fallback now running" || bad "applied marker does not match the running fallback"

echo "-- Scenario: the refusal persists -> bounded retries, the alarm stays, bob stays revoked --"
for _t in 1 2 3; do apply_run retry_pending; done
restarts_after_cap="$(n_calls 'restart headscale restart')"
apply_run retry_pending; apply_run retry_pending
[ "$(n_calls 'restart headscale restart')" = "${restarts_after_cap}" ] \
    && ok "after ${HS_PENDING_RETRIES:-3} retries a refused policy stops restarting headscale every tick" \
    || bad "a refused policy keeps restarting headscale every tick (restarts $(n_calls 'restart headscale restart'), was ${restarts_after_cap})"
[ "${restarts_after_cap}" -gt 3 ] && ok "the refused policy WAS retried on later ticks (restarts: ${restarts_after_cap})" || bad "the refused policy was never retried"
[ -s "${CASE}/cache/apply-failed" ] && ok "the alarm survives every tick while the policy is still refused" || bad "the alarm was cleared though the policy is still refused"
serves "${CASE}/etc/policy.hujson" tag:dev_bob && bad "bob's revoked edge came back during the retries" || ok "bob stays revoked through the retries"
[ -e "${STUB}/up" ] && ok "headscale is still up after the retries" || bad "a retry left headscale down"

echo "-- Scenario: the refusal was transient -> a later tick applies the policy and clears the alarm --"
revocation_case revoke_transient REJECTME "${E_SUP}" "${E_ALICE}"; : > "${STUB}/reject"
apply_run apply_policy "${CASE}/new.hujson"
rm -f "${STUB}/reject"
apply_run retry_pending
cmp -s "${CASE}/etc/policy.hujson" "${CASE}/new.hujson" && [ "$(cat "${CASE}/cache/applied-policy-hash")" = "$(hash_of "${CASE}/new.hujson")" ] \
    && ok "the retry loads the exported policy (no new export generation needed)" || bad "the retry did not load the exported policy"
[ ! -e "${CASE}/cache/apply-failed" ] && [ ! -e "${CASE}/cache/pending-policy.hujson" ] \
    && ok "alarm and pending policy are cleared once the policy is loaded" || bad "alarm or pending policy left behind after a successful retry"
[ "$(n_calls forcetags)" = 1 ] && ok "force-tags runs once, for the policy that actually loaded" || bad "force-tags ran $(n_calls forcetags) time(s)"
serves "${CASE}/etc/policy.hujson" tag:dev_bob && bad "bob served after the retry" || ok "bob is revoked after the retry"

echo "-- Scenario: a newer export generation supersedes the pending policy and clears the alarm --"
revocation_case revoke_superseded REJECTME "${E_SUP}" "${E_ALICE}"; : > "${STUB}/reject"
apply_run apply_policy "${CASE}/new.hujson"
mkpol GEN3 "${E_SUP}" "${E_ALICE}" "${E_CAROL}" > "${CASE}/gen3.hujson"
apply_run apply_policy "${CASE}/gen3.hujson"
cmp -s "${CASE}/etc/policy.hujson" "${CASE}/gen3.hujson" && [ ! -e "${CASE}/cache/apply-failed" ] && [ ! -e "${CASE}/cache/pending-policy.hujson" ] \
    && ok "a later generation that loads replaces the fallback, drops the pending policy and clears the alarm" \
    || bad "the alarm or the stale pending policy outlived a generation that loaded"

echo "-- Scenario: headscale is only LATE (first restart not up in time) -> the policy is loaded, not rolled back --"
revocation_case revoke_late GOOD "${E_SUP}" "${E_ALICE}"; echo 1 > "${STUB}/slow_restarts"
apply_run apply_policy "${CASE}/new.hujson"
cmp -s "${CASE}/etc/policy.hujson" "${CASE}/new.hujson" \
    && ok "a slow first start does not roll the new policy back" || bad "a late start rolled the revocation back to the previous policy"
[ "$(n_calls 'restart headscale restart')" = 2 ] && [ -e "${STUB}/up" ] \
    && ok "headscale was restarted a second time and came up on the new policy" || bad "no second restart for a late start (restarts $(n_calls 'restart headscale restart'))"
[ ! -e "${CASE}/cache/apply-failed" ] && [ "$(n_calls forcetags)" = 1 ] \
    && ok "a late-but-successful apply raises no alarm and forces tags" || bad "alarm raised, or tags not forced, for a late-but-successful apply"
serves "${CASE}/etc/policy.hujson" tag:dev_bob && bad "bob served after a late apply" || ok "bob is revoked after a late apply"

echo "-- Scenario: a start later than every attempt is a rejection: fail closed, not rolled back --"
revocation_case revoke_very_late GOOD "${E_SUP}" "${E_ALICE}"; echo 2 > "${STUB}/slow_restarts"
apply_run apply_policy "${CASE}/new.hujson"
serves "${CASE}/etc/policy.hujson" tag:dev_bob \
    && bad "bob served after headscale missed every start window" || ok "bob is not served after headscale missed every start window"
[ -s "${CASE}/cache/apply-failed" ] && ok "the missed start window raises the alarm" || bad "no alarm for a missed start window"

echo "-- Scenario: nothing was revoked -> the fallback is the previous policy, byte for byte --"
apply_new_case rejected_no_revocation; : > "${STUB}/reject"
mkpol OLD "${E_SUP}" "${E_ALICE}" > "${CASE}/etc/policy.hujson"; cp "${CASE}/etc/policy.hujson" "${CASE}/old.copy"
mkpol REJECTME "${E_SUP}" "${E_ALICE}" "${E_BOB}" > "${CASE}/new.hujson"
apply_run apply_policy "${CASE}/new.hujson"
cmp -s "${CASE}/etc/policy.hujson" "${CASE}/old.copy" && ok "an addition-only refused policy falls back to the previous file unchanged" || bad "the fallback rewrote a policy nothing was revoked from"
[ -s "${CASE}/cache/apply-failed" ] && ok "a refused policy raises the alarm even when nothing was revoked" || bad "no alarm for a refused policy"

echo "-- Scenario: the superadmin break-glass edge is kept even when the refused policy lacks it --"
revocation_case revoke_nosup REJECTME "${E_ALICE}"; : > "${STUB}/reject"
apply_run apply_policy "${CASE}/new.hujson"
serves "${CASE}/etc/policy.hujson" tag:mesh_east-01 && serves "${CASE}/etc/policy.hujson" tag:dev_alice && ! serves "${CASE}/etc/policy.hujson" tag:dev_bob \
    && ok "fallback = previous minus revoked edges, superadmin mesh edge retained" || bad "fallback lost the superadmin edge or kept a revoked one"

echo "-- Scenario: the previous policy cannot be narrowed -> it is NOT restored (fail closed) --"
revocation_case unnarrowable REJECTME "${E_SUP}" "${E_ALICE}"; : > "${STUB}/reject"
printf 'this is not json\n' >> "${CASE}/etc/policy.hujson"     # OLD (sup+alice+bob) plus trailing garbage
apply_run apply_policy "${CASE}/new.hujson"
grep -F dev_bob "${CASE}/etc/policy.hujson" >/dev/null \
    && bad "EXPLOIT: a previous policy that could not be narrowed was restored with bob's revoked edge" \
    || ok "a previous policy that cannot be narrowed is not restored, so bob's revoked edge is not put back"
grep -F REJECTME "${CASE}/etc/policy.hujson" >/dev/null && grep -F 'NOT restored' "${CASE}/cache/apply-failed" >/dev/null \
    && ok "the refused policy stays on disk and the alarm says the previous policy was not restored" \
    || bad "no fail-closed alarm for an unnarrowable previous policy"
cmp -s "${CASE}/cache/pending-policy.hujson" "${CASE}/new.hujson" \
    && ok "the refused policy is kept as pending" || bad "the refused policy was not kept as pending"
for _t in 1 2 3 4 5 6; do apply_run retry_pending; done
r_now="$(n_calls 'restart headscale restart')"; apply_run retry_pending; apply_run retry_pending
[ "$(n_calls 'restart headscale restart')" = "${r_now}" ] \
    && ok "the refused policy left on disk is retried a bounded number of ticks, not restarted every tick (restarts: ${r_now})" \
    || bad "a refused policy left on disk restarts headscale every tick (restarts $(n_calls 'restart headscale restart'), was ${r_now})"
[ -s "${CASE}/cache/apply-failed" ] && ! grep -F dev_bob "${CASE}/etc/policy.hujson" >/dev/null \
    && ok "the alarm stays raised and bob stays off through the retries" || bad "alarm cleared, or bob back, during the retries"

echo "-- Scenario: the narrowing needs no temp file (TMPDIR unusable) --"
revocation_case revoke_no_tmpdir REJECTME "${E_SUP}" "${E_ALICE}"; : > "${STUB}/reject"
TMPDIR=/nonexistent apply_run apply_policy "${CASE}/new.hujson"
serves "${CASE}/etc/policy.hujson" tag:dev_bob \
    && bad "EXPLOIT: with TMPDIR unusable the previous policy ran UNNARROWED and bob was served" \
    || ok "with TMPDIR unusable bob's revoked edge is still removed"
serves "${CASE}/etc/policy.hujson" tag:dev_alice && [ -e "${STUB}/up" ] && [ -s "${CASE}/cache/apply-failed" ] \
    && ok "alice is still served, headscale is up, and the alarm is raised" || bad "the TMPDIR-unusable fallback lost alice, left headscale down, or raised no alarm"
rm -f "${STUB}/reject"; TMPDIR=/nonexistent apply_run retry_pending
cmp -s "${CASE}/etc/policy.hujson" "${CASE}/new.hujson" && [ ! -e "${CASE}/cache/apply-failed" ] \
    && ok "with TMPDIR unusable the pending policy is still retried and loads" \
    || bad "with TMPDIR unusable retry_pending never retried the pending policy"

echo "-- Scenario: the refused policy does not parse -> the fallback keeps only break-glass --"
revocation_case rejected_garbage REJECTME "${E_SUP}" "${E_ALICE}"; : > "${STUB}/reject"
printf '%s\n' '{"acls":[],"note":"REJECTME", not json' > "${CASE}/new.hujson"
apply_run apply_policy "${CASE}/new.hujson"
serves "${CASE}/etc/policy.hujson" tag:mesh_east-01 && ! serves "${CASE}/etc/policy.hujson" tag:dev_alice && ! serves "${CASE}/etc/policy.hujson" tag:dev_bob \
    && ok "an unparseable refused policy leaves only the superadmin edge running" \
    || bad "an unparseable refused policy kept a non-break-glass edge, or lost the superadmin edge"

echo "-- Scenario: the fallback comes up only on a LATER tick -> the alarm is NOT cleared --"
revocation_case revoke_fallback_late REJECTME "${E_SUP}" "${E_ALICE}"; : > "${STUB}/reject"; echo 4 > "${STUB}/slow_restarts"
apply_run apply_policy "${CASE}/new.hujson"
[ ! -e "${STUB}/up" ] && [ -s "${CASE}/cache/apply-failed" ] && ok "tick 1: the fallback did not start in time, alarm raised" || bad "tick 1 did not reproduce a down fallback"
apply_run retry_pending
[ -e "${STUB}/up" ] && ! serves "${CASE}/etc/policy.hujson" tag:dev_bob \
    && ok "tick 2: the fallback is up and bob is not served" || bad "tick 2: the fallback did not come up, or serves bob"
[ -s "${CASE}/cache/apply-failed" ] && cmp -s "${CASE}/cache/pending-policy.hujson" "${CASE}/new.hujson" \
    && ok "loading the FALLBACK keeps the alarm and the pending policy (the exported policy was never loaded)" \
    || bad "EXPLOIT: the alarm was cleared and the pending policy dropped when only the fallback loaded"
grep -F 'alarm cleared' "${CASE}/out" >/dev/null \
    && bad "the log claims the exported policy was applied when only the fallback loaded" \
    || ok "the log does not claim the exported policy was applied"
rm -f "${STUB}/reject"; apply_run retry_pending
cmp -s "${CASE}/etc/policy.hujson" "${CASE}/new.hujson" && [ ! -e "${CASE}/cache/apply-failed" ] && [ ! -e "${CASE}/cache/pending-policy.hujson" ] \
    && ok "tick 3: the pending policy loads and only then is the alarm cleared" || bad "tick 3: the pending policy did not load or the alarm was not cleared"

echo "-- Scenario: a newer refused generation supersedes a pending one -> neither revoked edge comes back --"
revocation_case revoke_twice REJECTME "${E_SUP}" "${E_ALICE}"; : > "${STUB}/reject"; echo 4 > "${STUB}/slow_restarts"
apply_run apply_policy "${CASE}/new.hujson"; apply_run retry_pending
mkpol REJECTME2 "${E_SUP}" > "${CASE}/gen3.hujson"     # REJECTME2 also contains REJECTME: refused too
apply_run apply_policy "${CASE}/gen3.hujson"
for _t in 1 2 3 4; do apply_run retry_pending; done
! serves "${CASE}/etc/policy.hujson" tag:dev_bob && ! serves "${CASE}/etc/policy.hujson" tag:dev_alice && serves "${CASE}/etc/policy.hujson" tag:mesh_east-01 \
    && ok "after a superseding refused generation neither bob nor alice is served (the stale pending policy is never re-installed)" \
    || bad "EXPLOIT: a stale pending policy came back over a newer generation"
cmp -s "${CASE}/cache/pending-policy.hujson" "${CASE}/gen3.hujson" && [ -s "${CASE}/cache/apply-failed" ] \
    && ok "the pending policy is the newer generation and the alarm stays" || bad "the pending policy is not the newer generation, or the alarm was cleared"

echo "-- Scenario: the policy cannot be installed into /etc/headscale -> alarm, pending, cursor held --"
revocation_case install_fails GOOD "${E_SUP}" "${E_ALICE}"; : > "${STUB}/install_fail"
hash_of "${CASE}/etc/policy.hujson" > "${CASE}/cache/applied-policy-hash"   # OLD is what runs
printf '5\n' > "${CASE}/cache/last-good-generation"; printf '{}\n' > "${CASE}/export6.json"
apply_run install_generation "${CASE}/export6.json" "${CASE}/new.hujson" 6
[ -s "${CASE}/cache/apply-failed" ] \
    && ok "a failed install raises the alarm (the running policy still has bob)" \
    || bad "EXPLOIT: a failed install of a revoking policy raised no alarm"
cmp -s "${CASE}/cache/pending-policy.hujson" "${CASE}/new.hujson" \
    && ok "the policy that could not be installed is kept as pending" || bad "the policy that could not be installed was dropped"
[ "$(cat "${CASE}/cache/last-good-generation")" = 5 ] \
    && ok "the export cursor is NOT advanced past a generation whose policy was not installed" \
    || bad "EXPLOIT: the cursor advanced past a generation whose policy was never installed"
for _t in 1 2 3 4 5; do apply_run retry_pending; done
[ -s "${CASE}/cache/apply-failed" ] && [ -f "${CASE}/cache/pending-policy.hujson" ] \
    && ok "a lasting install failure keeps the alarm and the pending policy through 5 ticks" || bad "a lasting install failure dropped the alarm or pending policy"
rm -f "${STUB}/install_fail"; apply_run retry_pending
cmp -s "${CASE}/etc/policy.hujson" "${CASE}/new.hujson" && ! serves "${CASE}/etc/policy.hujson" tag:dev_bob && [ ! -e "${CASE}/cache/apply-failed" ] \
    && ok "once /etc/headscale is writable again the pending policy is installed, bob is revoked, the alarm clears" \
    || bad "the pending policy was not installed after the install failure ended (install failures must not burn the retry cap)"
apply_run install_generation "${CASE}/export6.json" "${CASE}/new.hujson" 6
[ "$(cat "${CASE}/cache/last-good-generation")" = 6 ] \
    && ok "the cursor advances once the generation's policy is installed" || bad "the cursor did not advance after a successful install"

echo "-- Scenario: the restart command itself fails on a revocation -> alarm, then cleared when the retry lands --"
revocation_case revoke_restart_fails GOOD "${E_SUP}" "${E_ALICE}"; : > "${STUB}/restart_fail"
apply_run apply_policy "${CASE}/new.hujson"
[ -s "${CASE}/cache/apply-failed" ] && ok "a failed restart raises the alarm (the running policy still has bob)" || bad "a failed restart raised no alarm"
rm -f "${STUB}/restart_fail"; apply_run retry_pending
[ ! -e "${CASE}/cache/apply-failed" ] && ok "the alarm is cleared when the retry applies the policy" || bad "alarm left raised after the retry applied the policy"

echo "-- Scenario: the export now matches what runs -> a stale alarm is cleared --"
revocation_case stale_alarm GOOD "${E_SUP}" "${E_ALICE}"
apply_run apply_policy "${CASE}/new.hujson"
printf 'since=x\n' > "${CASE}/cache/apply-failed"; cp "${CASE}/new.hujson" "${CASE}/cache/pending-policy.hujson"
apply_run apply_policy "${CASE}/new.hujson"
[ ! -e "${CASE}/cache/apply-failed" ] && [ ! -e "${CASE}/cache/pending-policy.hujson" ] \
    && ok "an unchanged, applied policy clears a stale alarm and pending policy" || bad "stale alarm survived an unchanged, applied policy"

echo "-- Scenario: no previous policy and headscale never answers -> alarm, no crash --"
apply_new_case first_ever; : > "${STUB}/reject"; rm -f "${CASE}/etc/policy.hujson"
printf '%s\n' '{"acls":[],"note":"REJECTME"}' > "${CASE}/new.hujson"
apply_run apply_policy "${CASE}/new.hujson"
[ -s "${CASE}/cache/apply-failed" ] && ok "a first-ever refused policy raises the alarm" || bad "no alarm for a first-ever refused policy"

# ══════════════════════════════════════════════════════════════════════════════
# PART 2 — COMPILE-SIDE RECONCILIATION (node renderer vs the DARK BFF compiler)
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "== Layer-A compile-side reconciliation — the node side is the truth =="

# ── 2a. Pin the NODE-SIDE facts the BFF has to agree with. These come out of THIS
# repo, so they cannot go stale relative to the assertions below.
echo "-- node-side ground truth --"

# The single-writer question: headscale's policy mode.
HS_MODE="$(awk '/^policy:/{p=1;next} p&&/^[^[:space:]]/{p=0} p&&/^[[:space:]]*mode:/{print $2;exit}' "${HS_CONFIG}" 2>/dev/null)"
if [ -n "${HS_MODE}" ]; then
    ok "headscale policy mode read from config.yaml: '${HS_MODE}'"
else
    bad "could not read policy.mode from ${HS_CONFIG}"; HS_MODE="file"
fi
# The renderer only works in file mode (`headscale policy set -f`); assert the two agree.
if [ "${HS_MODE}" = "file" ]; then
    grep -q 'headscale policy set -f' "${RENDERER}" \
        && ok "node renderer applies with 'headscale policy set -f' (consistent with mode:file)" \
        || bad "mode:file but the renderer does not run 'headscale policy set -f'"
else
    bad "headscale policy mode is '${HS_MODE}', not 'file' — the node-side renderer's single-writer assumption no longer holds; re-read gen-headscale-policy.sh before trusting this gate"
fi

# The in-cluster address the BFF must dial (it is NOT ns 'headscale').
HS_NS="$(awk '/^[[:space:]]*namespace:[[:space:]]*/{print $2; exit}' "${HS_SERVICE}" 2>/dev/null)"
HS_SVC="$(awk '/^[[:space:]]*name:[[:space:]]*/{print $2; exit}' "${HS_SERVICE}" 2>/dev/null)"
HS_PORT="$(awk '/^[[:space:]]*port:[[:space:]]*/{print $2; exit}' "${HS_SERVICE}" 2>/dev/null)"
EXPECT_BASE_URL="http://${HS_SVC}.${HS_NS}.svc.cluster.local:${HS_PORT}"
if [ -n "${HS_NS}" ] && [ -n "${HS_SVC}" ] && [ -n "${HS_PORT}" ]; then
    ok "headscale in-cluster address from the manifest: ${EXPECT_BASE_URL}"
else
    bad "could not derive the headscale Service address from ${HS_SERVICE}"
fi
grep -q "namespace: ${HS_NS}" "${HS_SVC_APP}" \
    && ok "the headscale-svc Application deploys into the same namespace (${HS_NS})" \
    || bad "07-headscale-svc.yaml destination namespace != the Service's namespace (${HS_NS})"

# ── The privileged node-local unix account every `users` entry must name.
#
# THE NODE SIDE IS THE TRUTH, so the expectation is PARSED out of provision.sh's
# resolve_ssh_user() and never spelled here. (2026-07-30 adversarial verification killed
# the previous form: `awk '…{print "admin"; exit}'` PRINTED the literal on match and the
# next line assigned the same literal on no-match, so EXPECT_SSH_USER was the constant
# "admin" whatever provision.sh said. Renaming the fleet's privileged account on the node
# side left this gate at 52 passed / 0 failed while the BFF kept compiling edges for an
# account the node no longer grants. The parser below reads the VALUE; a provision.sh that
# says "operator" makes every ssh-user assertion below demand "operator".)
#
# Grammar matched: the guarded literal fallback inside the function body, i.e.
#   { [ -z "${u}" ] || [ "${u}" = "null" ]; } && u="admin"
# `[^"$]` deliberately excludes command substitutions, so the two `u="$(…)"` lookups above
# it (node.env, then users.json) cannot be mistaken for the fallback.
EXPECT_SSH_USER="$(awk '
    /^resolve_ssh_user\(\)/ { inf = 1; next }
    inf && /^}/             { exit }
    inf && /&&[[:space:]]*u="[^"$]+"/ {
        line = $0
        sub(/^.*&&[[:space:]]*u="/, "", line)
        sub(/".*$/, "", line)
        print line
        exit
    }
' "${PROVISION}" 2>/dev/null)"
if [ -n "${EXPECT_SSH_USER}" ]; then
    ok "node-side ssh account PARSED from provision.sh resolve_ssh_user(): '${EXPECT_SSH_USER}'"
else
    bad "could not parse resolve_ssh_user()'s literal fallback account out of ${PROVISION} — every ssh-user assertion below would be unanchored, so this gate refuses to guess. Fix the parser or the function, do not hard-code the account here"
    EXPECT_SSH_USER="__UNPARSED__"
fi

# The renderer's own fallback is what lands in TS_SSH_USER when provision.sh staged nothing;
# it must be that SAME account. Parsed (not grepped for a literal) for the same reason.
RENDERER_SSH_USER="$(awk '
    /TS_SSH_USER="[^"$]+"/ {
        line = $0
        sub(/^.*TS_SSH_USER="/, "", line)
        sub(/".*$/, "", line)
        print line
        exit
    }
' "${RENDERER}" 2>/dev/null)"
if [ -n "${RENDERER_SSH_USER}" ] && [ "${RENDERER_SSH_USER}" = "${EXPECT_SSH_USER}" ]; then
    ok "renderer ssh-user fallback is '${RENDERER_SSH_USER}' (same as provision.sh resolve_ssh_user)"
else
    bad "renderer ssh-user fallback is '${RENDERER_SSH_USER:-<unparsed>}' but provision.sh resolve_ssh_user falls back to '${EXPECT_SSH_USER}' — a node provisioned without an explicit tailscale.ssh_user would render edges for an account it does not grant"
fi

# The fp->tag mapping, computed by the REAL shell function, for a fixed vector.
VEC_FP="fpA"
VEC_TAG="$(dev_tag_for_fp "${VEC_FP}")"
# ...and the tag PREFIX, taken from that same real output (everything up to and including
# the first '_'), so the BFF-side prefix assertions below are anchored to what the live
# shell actually emits rather than to a literal typed into this gate.
EXPECT_DEV_PREFIX="${VEC_TAG%%_*}_"
EXPECT_NODE_TAG_PREFIX="tag:${EXPECT_DEV_PREFIX}"
if [ "${VEC_TAG}" = "dev_084628ddb3aa" ]; then
    ok "dev_tag_for_fp('${VEC_FP}') = ${VEC_TAG} (the pinned cross-repo vector)"
else
    bad "dev_tag_for_fp('${VEC_FP}') = '${VEC_TAG}', expected dev_084628ddb3aa — the fp->tag mapping changed; it MUST be changed in all THREE implementations (gen-headscale-policy.sh, hugmesh-headscale-forcetags, HeadscaleAclCompiler.java)"
fi
# The forcetags copy must stay byte-identical to the renderer's.
if diff <(awk '/^dev_tag_for_fp\(\)/,/^}/' "${RENDERER}") \
        <(awk '/^dev_tag_for_fp\(\)/,/^}/' "${FORCETAGS_SRC}") >/dev/null 2>&1; then
    ok "hugmesh-headscale-forcetags carries a byte-identical dev_tag_for_fp"
else
    bad "dev_tag_for_fp DRIFTED between gen-headscale-policy.sh and hugmesh-headscale-forcetags (forced tag != rendered dst => nodes unreachable)"
fi

# ── 2a-bis. FULL-DOCUMENT PARITY against the shared golden.
#
# The greps below prove the compiler MENTIONS the right shapes. This block proves the
# stronger thing: for one canonical export, the LIVE node-side renderer emits EXACTLY
# the checked-in golden document — and hugmesh-admin-bff-api's HeadscaleAclParityTest
# independently asserts its compiler emits the SAME golden from the SAME fixture. So
# the two writers are pinned field-for-field without either repo needing the other's
# toolchain (no JVM here, no shell there). The link between the two halves is the
# byte-identity of the fixture copies, asserted in 2b.
echo "-- full-document parity vs the shared golden --"
FIXDIR="${REPO}/tests/device-registry/fixtures"
PARITY_PARAMS="${FIXDIR}/layer-a-parity-params.env"
PARITY_EXPORT="${FIXDIR}/layer-a-parity-export.json"
PARITY_GOLDEN="${FIXDIR}/layer-a-parity-policy.golden.json"
if [ -r "${PARITY_PARAMS}" ] && [ -r "${PARITY_EXPORT}" ] && [ -r "${PARITY_GOLDEN}" ]; then
    # Render with the SHARED params (the two inputs that live outside the signed export).
    # shellcheck source=/dev/null
    . "${PARITY_PARAMS}"
    _saved_user="${TS_SSH_USER}"; _saved_tag="${MESH_TAG}"
    MESH_TAG="tag:mesh_$(sanitise_tag "${MESH_ID}")"
    PARITY_OUT="$(mktemp)"
    if render_policy "${PARITY_EXPORT}" "${PARITY_OUT}"; then
        if diff -u "${PARITY_GOLDEN}" <(strip "${PARITY_OUT}" | jq -S .) >/dev/null 2>&1; then
            ok "node renderer reproduces layer-a-parity-policy.golden.json exactly"
        else
            bad "node renderer NO LONGER matches the golden — the Layer-A policy document changed; regenerate the golden IN BOTH REPOS and re-review, this is a live-mesh-shape change"
            diff -u "${PARITY_GOLDEN}" <(strip "${PARITY_OUT}" | jq -S .) | head -30 | sed 's/^/      /'
        fi
    else
        bad "render_policy failed on the parity fixture"
    fi
    rm -f "${PARITY_OUT}"
    TS_SSH_USER="${_saved_user}"; MESH_TAG="${_saved_tag}"

    # TAG SHAPE, bound to an EMITTED DOCUMENT rather than to source text. Every per-node ssh
    # dst in the shared golden must be `tag:` + the REAL shell dev_tag_for_fp of one of the
    # fingerprints the shared export licenses, and every licensed fingerprint must appear.
    # Because the BFF's HeadscaleAclParityTest holds its compiler to this SAME golden and 2b
    # asserts the two copies are byte-identical, this pins the Java emission too — without a
    # JVM here, and without trusting any grep over Java source.
    GOLDEN_NODE_DSTS="$(jq -r '[.ssh[] | select(.src[0]=="tag:hugmesh") | .dst[]] | sort | .[]' "${PARITY_GOLDEN}" 2>/dev/null)"
    EXPECT_NODE_DSTS="$(jq -r '[.body.operators[]?.machineKeyFp] | unique | .[]' "${PARITY_EXPORT}" 2>/dev/null \
        | while read -r _fp; do [ -n "${_fp}" ] && echo "tag:$(dev_tag_for_fp "${_fp}")"; done | sort)"
    if [ -n "${EXPECT_NODE_DSTS}" ] && [ "${GOLDEN_NODE_DSTS}" = "${EXPECT_NODE_DSTS}" ]; then
        ok "golden's per-node ssh dst tags are exactly tag:<dev_tag_for_fp> of the export's licensed fingerprints"
    else
        bad "golden's per-node ssh dst tags != tag:<dev_tag_for_fp> of the export's fingerprints (golden: $(echo "${GOLDEN_NODE_DSTS}" | tr '\n' ' ')| expected: $(echo "${EXPECT_NODE_DSTS}" | tr '\n' ' ')) — the document both writers are gated against no longer addresses nodes by the tag the force-tagger assigns"
    fi
    if [ -n "${GOLDEN_NODE_DSTS}" ] && ! printf '%s\n' "${GOLDEN_NODE_DSTS}" | grep -v "^${EXPECT_NODE_TAG_PREFIX}" >/dev/null; then
        ok "every per-node dst in the golden carries the ${EXPECT_NODE_TAG_PREFIX} prefix"
    else
        bad "a per-node dst in the golden does not start with ${EXPECT_NODE_TAG_PREFIX}"
    fi
else
    bad "the shared parity fixtures are missing from ${FIXDIR} — full-document parity is unproven"
fi

# ── 2b. The BFF-side compiler must describe the SAME mesh. INCOMPLETE (exit 3),
# never a silent skip, when the sibling checkout is not supplied.
echo "-- BFF compile side (hugmesh-admin-bff-api) --"
BFF_DEV="${BFF_ROOT}/src/main/java/net/hugmesh/adminbff/device"
BFF_COMPILER="${BFF_DEV}/HeadscaleAclCompiler.java"
BFF_PROPS="${BFF_DEV}/HeadscaleAclProperties.java"
BFF_CONFIG="${BFF_DEV}/HeadscaleAclConfig.java"
BFF_YML="${BFF_ROOT}/src/main/resources/application.yml"
BFF_COMPILER_TEST="${BFF_ROOT}/src/test/java/net/hugmesh/adminbff/device/HeadscaleAclCompilerTest.java"

if [ ! -r "${BFF_COMPILER}" ]; then
    echo
    echo "  INCOMPLETE: the hugmesh-admin-bff-api checkout carrying the Layer-A compiler is"
    echo "  absent (looked for ${BFF_COMPILER})."
    echo "  This gate's compile-side half is the half that matters: the node renderer is LIVE"
    echo "  and the BFF compiler is the dark would-be replacement writer, so an unchecked"
    echo "  compiler is exactly the drift that breaks the mesh on the day someone flips"
    echo "  app.registry.headscale-acl.enabled=true. Refusing to report PASS without it."
    echo "  Supply it with LAYERA_BFF_ROOT=<checkout> or clone into ${SIBLING_ROOT}."
    echo
    echo "== RESULT: ${P} passed, ${F} failed, COMPILE SIDE NOT CHECKED (exit 3) =="
    exit 3
fi
for f in "${BFF_PROPS}" "${BFF_CONFIG}" "${BFF_YML}" "${BFF_COMPILER_TEST}"; do
    [ -r "${f}" ] || { echo "  INCOMPLETE: ${f} missing from the sibling checkout"; exit 3; }
done
ok "sibling hugmesh-admin-bff-api checkout present (${BFF_ROOT})"

# The two halves of the golden contract are only one contract if both repos hold the
# SAME bytes. hugmesh-admin-bff-api's HeadscaleAclParityTest asserts its compiler
# reproduces its copy of the golden; this asserts its copy IS our copy.
BFF_FIX="${BFF_ROOT}/src/test/resources/layer-a"
for f in layer-a-parity-params.env layer-a-parity-export.json layer-a-parity-policy.golden.json; do
    if [ ! -r "${BFF_FIX}/${f}" ]; then
        bad "the BFF checkout is missing its copy of ${f} — its parity test cannot be asserting the same document"
    elif cmp -s "${FIXDIR}/${f}" "${BFF_FIX}/${f}"; then
        ok "parity fixture ${f} is byte-identical in both repos"
    else
        bad "parity fixture ${f} DIFFERS between hugmesh-generator and hugmesh-admin-bff-api — the two writers are being gated against DIFFERENT documents, so their agreement is unproven"
    fi
done
grep -Fq 'layer-a-parity-policy.golden.json' "${BFF_ROOT}/src/test/java/net/hugmesh/adminbff/device/HeadscaleAclParityTest.java" 2>/dev/null \
    && ok "BFF HeadscaleAclParityTest asserts against the shared golden" \
    || bad "BFF has no HeadscaleAclParityTest asserting the shared golden — full-document parity is only proven on the node side"

# (b) TAG SHAPE — the compiler must address nodes by the SERVER-FORCED dev tag.
#
# Two assertions, because the first one alone was VACUOUS until 2026-07-30: NODE_TAG_PREFIX
# was declared but never read (nodeTagFor spelled the tag a second way, TAG_PREFIX +
# devTagFor(fp)), so the constant this gate pins could be set back to the dead "tag:node-"
# and not one byte of the compiled policy changed — all 39 BFF tests stayed green. Pinning
# a value is only worth anything if the emission path reads it.
if grep -Fq "DEV_TAG_PREFIX = \"${EXPECT_DEV_PREFIX}\"" "${BFF_COMPILER}" \
   && grep -Fq 'NODE_TAG_PREFIX = TAG_PREFIX + DEV_TAG_PREFIX' "${BFF_COMPILER}"; then
    ok "compiler NODE_TAG_PREFIX composes to ${EXPECT_NODE_TAG_PREFIX} (matches the tag dev_tag_for_fp force-assigns)"
else
    bad "compiler NODE_TAG_PREFIX does not compose to ${EXPECT_NODE_TAG_PREFIX} (expected TAG_PREFIX + DEV_TAG_PREFIX with DEV_TAG_PREFIX = \"${EXPECT_DEV_PREFIX}\", derived from this repo's dev_tag_for_fp) — a pushed policy would name tags NO node carries (every SSH edge dead)"
fi
# ...and the constant must be LOAD-BEARING: the method that builds every emitted dst tag
# has to read it. A constant no emission path reads is decoration, not a contract.
NODE_TAG_FN="$(awk '/static String nodeTagFor\(/{p=1} p{print} p&&/^[[:space:]]*}[[:space:]]*$/{exit}' "${BFF_COMPILER}")"
printf '%s\n' "${NODE_TAG_FN}" | grep -v -E '^[[:space:]]*(/?\*|//)' | grep -F 'NODE_TAG_PREFIX' >/dev/null \
    && ok "NODE_TAG_PREFIX is LOAD-BEARING: nodeTagFor() builds the emitted dst tag out of it" \
    || bad "NODE_TAG_PREFIX is INERT — nodeTagFor() does not read it, so the constant asserted above has zero effect on the emitted policy (it can say anything and every edge still compiles the same). Build the tag from the constant; do not spell it a second way"
java_code "${BFF_COMPILER}" | grep -F 'tag:node-' >/dev/null \
    && bad "compiler CODE still emits the tag:node-<fp> shape — no node carries it" \
    || ok "no tag:node- shape in compiler code (any mention is a regression note only)"
grep -Fq "${VEC_TAG}" "${BFF_COMPILER_TEST}" \
    && ok "BFF compiler test pins the SAME fp->tag vector (${VEC_TAG}) this shell computed" \
    || bad "BFF compiler test does not pin ${VEC_TAG} — the two dev-tag implementations are unverified against each other"

# (c) DATA-PLANE ACL — the compiled acls[] must keep the k8s CIDR rule.
grep -Fq '10.244.0.0/16' "${BFF_COMPILER}" && grep -Fq '10.96.0.0/12' "${BFF_COMPILER}" \
    && ok "compiler carries both k8s data-plane CIDRs (10.244.0.0/16 + 10.96.0.0/12)" \
    || bad "compiler is missing the k8s data-plane CIDRs — an enabled push would BLANK cross-node pod/ClusterIP reachability fleet-wide"
grep -Fq 'acls[]: kept empty' "${BFF_COMPILER}" \
    && bad "compiler still declares 'acls[]: kept empty' — the data-plane rule would be dropped" \
    || ok "compiler no longer keeps acls[] empty"
# ...and it is not enough for the CIDRs to exist as constants; a rule must be ADDED.
java_code "${BFF_COMPILER}" | grep -F 'acls.add(' >/dev/null \
    && ok "compiler CODE actually adds a rule into acls[] (not just declaring the CIDRs)" \
    || bad "compiler declares the CIDRs but never adds a rule to acls[] — the emitted acls[] is still empty"

# The always-on SUPERADMIN mesh rule + control-owned dst tags [FIX-SERVERTAG].
grep -Fq 'tag:superadmin' "${BFF_COMPILER}" && grep -Fq 'tag:mesh_' "${BFF_COMPILER}" \
    && ok "compiler declares tag:superadmin + tag:mesh_ (the SUPERADMIN mesh rule's parts)" \
    || bad "compiler omits tag:superadmin / tag:mesh_ — a push would cut superadmin off from the core nodes the export deliberately omits"
java_code "${BFF_COMPILER}" | grep -F 'sshRule(SUPERADMIN_TAG' >/dev/null \
    && ok "compiler CODE adds the SUPERADMIN mesh edge into ssh[]" \
    || bad "compiler never adds the SUPERADMIN mesh edge to ssh[] — superadmin loses its ONLY reach to core nodes on the first push"
grep -Fq '"tagOwners"' "${BFF_COMPILER}" \
    && ok "compiler emits tagOwners (dst tags stay control-owned, not self-applyable)" \
    || bad "compiler emits no tagOwners — [FIX-SERVERTAG] re-opens (a node could self-advertise a dst tag)"
java_code "${BFF_COMPILER}" | grep -F 'group:op-' >/dev/null \
    && bad "compiler CODE still emits group:op-<operator> src — headscale has no per-operator identity (FIX-OIDC-USERS deferred); those principals do not exist" \
    || ok "compiler emits no fictional group:op-* principals"

# (d) BASE-URL — must name the namespace the Service is actually in.
if grep -Fq "${EXPECT_BASE_URL}" "${BFF_PROPS}" && grep -Fq "${EXPECT_BASE_URL}" "${BFF_YML}"; then
    ok "BFF base-url default is ${EXPECT_BASE_URL} in both the properties class and application.yml"
else
    bad "BFF base-url default != ${EXPECT_BASE_URL} (derived from ${HS_SERVICE}) in HeadscaleAclProperties.java and/or application.yml"
fi
java_code "${BFF_PROPS}" | grep -F 'headscale.headscale.svc' >/dev/null \
    && bad "HeadscaleAclProperties CODE still names the nonexistent headscale.headscale.svc namespace" \
    || ok "no stale headscale.headscale.svc default in HeadscaleAclProperties code"

# (a) POLICY MODE — the mismatch must fail loudly, not no-op.
if grep -Fq "policyMode = \"${HS_MODE}\"" "${BFF_PROPS}"; then
    ok "BFF declared policy-mode default is '${HS_MODE}' — the mode this fleet actually ships"
else
    bad "BFF policy-mode default != '${HS_MODE}' (specs/etc/headscale/config.yaml). A default that lies about the target lets an enabled push 4xx silently forever"
fi
grep -Fq "APP_REGISTRY_HEADSCALE_ACL_POLICY_MODE:${HS_MODE}" "${BFF_YML}" \
    && ok "application.yml policy-mode default agrees (${HS_MODE})" \
    || bad "application.yml policy-mode default != ${HS_MODE}"
grep -Fq 'POLICY-MODE MISMATCH' "${BFF_CONFIG}" \
    && ok "HeadscaleAclConfig refuses to wire the push client on a policy-mode mismatch" \
    || bad "HeadscaleAclConfig has no policy-mode guard — enabling the push against a mode:file headscale would be a permanent SILENT no-op (4xx per tick, nothing applied)"
grep -Eq 'throw new IllegalStateException' "${BFF_CONFIG}" \
    && ok "the mismatch is a THROW (fails the context at wiring time), not a log line" \
    || bad "the policy-mode mismatch does not throw — it must fail loudly and early"

# ssh `users`: the compiled rules must open the session as the account the node
# renderer resolves, not a headscale autogroup.
grep -Fq "sshUser = \"${EXPECT_SSH_USER}\"" "${BFF_PROPS}" \
    && ok "BFF ssh-user default is '${EXPECT_SSH_USER}' (same fallback as provision.sh resolve_ssh_user)" \
    || bad "BFF ssh-user default != '${EXPECT_SSH_USER}' — compiled edges would open as an account the node does not grant"
grep -Fq "APP_REGISTRY_HEADSCALE_ACL_SSH_USER:${EXPECT_SSH_USER}" "${BFF_YML}" \
    && ok "application.yml ssh-user default agrees (${EXPECT_SSH_USER})" \
    || bad "application.yml ssh-user default != ${EXPECT_SSH_USER} (provision.sh resolve_ssh_user) — the deployed default would name an account the node does not grant"
java_code "${BFF_COMPILER}" | grep -F "? \"${EXPECT_SSH_USER}\" : sshUser" >/dev/null \
    && ok "compiler's blank-input ssh-user fallback is also '${EXPECT_SSH_USER}'" \
    || bad "compiler's blank-input ssh-user fallback != '${EXPECT_SSH_USER}' — a blank/absent config would silently compile edges for a different account than the node grants"
java_code "${BFF_COMPILER}" | grep -F 'autogroup:nonroot' >/dev/null \
    && bad "compiler CODE still hard-codes users:[autogroup:nonroot]; the renderer uses the resolved TS_SSH_USER" \
    || ok "compiler no longer hard-codes autogroup:nonroot as the ssh user"

# THE PUSH ITSELF MUST STILL BE OFF. This gate defuses the footgun; it does not
# fire the gun. Enabling is cluster-gated (live CANONICAL-FP confirmation + an
# API key + the file-vs-DB single-writer decision).
grep -Fq 'enabled = false' "${BFF_PROPS}" \
    && ok "the push leg is still DISABLED by default (enabled=false)" \
    || bad "app.registry.headscale-acl.enabled no longer defaults to false — the dark leg must stay dark"
grep -Fq 'APP_REGISTRY_HEADSCALE_ACL_ENABLED:false' "${BFF_YML}" \
    && ok "application.yml keeps the push disabled by default" \
    || bad "application.yml no longer disables the push by default"

echo
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

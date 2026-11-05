#!/usr/bin/env bash
# test-headscale-security-tag-owners.sh — no user that a pre-auth key is minted for
# may own a SECURITY tag in any headscale policy this repo ships or renders.
#
# WHY. headscale 0.23 (the version every image pins) gives a node the UNION of the
# tags the control node forces on it and every tag the node advertises whose
# tagOwners entry names the node's own user. A forced tag does NOT cancel a different
# advertised one. Every pre-auth key HugMesh mints (keys-provision from
# provision.json, the Studio's --mint, the web issuer) is for a membership user
# ("hugmesh" on every provisioned mesh; the Studio has no default and mints for the
# user the admin names), so a security tag owned by "hugmesh" is a tag any key holder can claim by
# advertising it. tag:superadmin is the SSH source of the always-emitted superadmin
# rule (dst tag:mesh_<id>, which every node carries), so claiming it is SSH as the
# privileged user on every node. The fix is ownership, not forcing: security tags
# (tag:superadmin, tag:mesh_*, tag:dev_*, tag:dom_*) get an EMPTY owner list, and
# only `headscale nodes tag` (hugmesh-headscale-forcetags) assigns them — that path
# does not consult tagOwners.
#
# WHAT IT CHECKS (offline: bash + jq + openssl + awk + git):
#   1. the set of key-minting users, read from where keys are minted (provision.json
#      templates, the Studio's DEFAULT_MINT_USER if it has one — else proof that it
#      refuses to mint for an unnamed user — literal `preauthkeys create --user`
#      lines in tracked files) — never assumed; an empty set fails (vacuity floor);
#   2. every shipped policy file + the policy the REAL renderer produces + the shared
#      Layer-A parity golden: each security tag has an EMPTY owner list, so no
#      key-minting user (or group) owns one; tag:superadmin and tag:mesh_<id> are
#      declared; the membership user still owns tag:hugmesh (or joins break);
#   3. keys-provision's guard (headscale_policy_owned_security_tags) flags an owned
#      security tag, passes a clean policy, reports an unparseable one as unreadable,
#      and provision_headscale actually calls it;
#   4. NEGATIVE CONTROLS: a renderer template with tag:superadmin given back to
#      "hugmesh", and a renderer that gives tag:dev_* an owner, are both caught by the
#      same check — so a green run is not a vacuous one.
# The live proof that headscale really refuses a self-advertised tag:superadmin under
# this policy is test-headscale-security-tag-live.sh (needs docker).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RENDERER="${REPO}/specs/usr/sbin/gen-headscale-policy.sh"
TMPL="${REPO}/specs/etc/headscale/policy.hujson.tmpl"
PROVISION="${REPO}/specs/etc/keys-provision/provision.sh"
MESH_TOKEN="${REPO}/studio/hugmesh_studio/core/mesh_token.py"
GOLDEN="${REPO}/tests/device-registry/fixtures/layer-a-parity-policy.golden.json"
POLICIES=(
    "specs/etc/headscale/policy.bootstrap.hujson"
    "specs/etc/headscale/policy.hujson"
    "keys-template/headscale/policy.hujson"
)

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
strip() { sed -e 's#//.*$##' "$1"; }   # the hujson line-comment strip the tooling uses

for t in jq openssl awk git; do
    command -v "$t" >/dev/null 2>&1 || { echo "SKIPPED-LOUDLY: $t is required and absent — this guard checked NOTHING"; exit 2; }
done

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

SEC_RE='^tag:(superadmin$|mesh_|dev_|dom_)'

# owners_of_security_tags <policy-json-file>: prints "<tag> <owners-json>" for every
# security tag with a NON-empty owner list; rc 1 if the file does not parse.
owners_of_security_tags() {
    strip "$1" | jq -er --arg re "${SEC_RE}" '
        (.tagOwners // {}) | if type == "object" then . else error("tagOwners not an object") end
        | to_entries[] | select(.key | test($re)) | select((.value // []) | length > 0)
        | "\(.key) \(.value | tojson)"' 2>/dev/null
    local rc=$?
    [ "${rc}" -eq 0 ] || [ "${rc}" -eq 4 ]
}

# ── 1. who are keys minted for? ──────────────────────────────────────────────
echo "== key-minting users =="
MINTERS="${WORK}/minters"; : > "${MINTERS}"
for f in "${REPO}"/keys-template/provision.json "${REPO}"/keys-template/examples/*.json; do
    [ -f "$f" ] || continue
    jq -r '(.headscale.users // [])[]?, ((.headscale.preauthkeys // [])[]?.user // empty)' "$f" 2>/dev/null >> "${MINTERS}"
done
studio_user="$(sed -n 's/^DEFAULT_MINT_USER = "\([^"]*\)".*/\1/p' "${MESH_TOKEN}")"
# The Studio has no default mint user: mint_preauth_key refuses an unnamed one, so it
# adds no implicit minter. A default that comes back is read and checked like any other.
mint_body="$(awk '/^def mint_preauth_key\(/{p=1;next} p&&/^def /{exit} p' "${MESH_TOKEN}" | grep -v -E '^[[:space:]]*#')"
if [ -n "${studio_user}" ]; then
    echo "${studio_user}" >> "${MINTERS}"
    ok "Studio DEFAULT_MINT_USER read from mesh_token.py (${studio_user})"
elif grep -q -E '^DEFAULT_MINT_USER\b' "${MESH_TOKEN}"; then
    bad "DEFAULT_MINT_USER is in ${MESH_TOKEN} but its value could not be read — refusing to guess who the Studio mints for"
elif grep -q -E '^[[:space:]]+if not user:' <<< "${mint_body}" \
     && grep -q -E 'raise TokenError\("invalid", f"No headscale user was named' <<< "${mint_body}"; then
    ok "Studio has no default mint user: mint_preauth_key refuses an unnamed user"
else
    bad "${MESH_TOKEN} has neither a readable DEFAULT_MINT_USER nor a refusal of an unnamed user — refusing to guess who the Studio mints for"
fi
# Literal `preauthkeys create --user <name>` in any tracked file (docs, READMEs, test
# harnesses). -a: one NUL byte would otherwise make grep skip a whole file silently.
git -C "${REPO}" ls-files -z | (cd "${REPO}" && xargs -0 grep -a -h -o -E 'preauthkeys create[^|;&]*--user[ =]"?[A-Za-z0-9][A-Za-z0-9_.-]*' 2>/dev/null) \
    | sed -E 's/.*--user[ =]"?//' >> "${MINTERS}"
sort -u "${MINTERS}" -o "${MINTERS}"
sed -i '/^$/d;/^null$/d' "${MINTERS}"
n_minters="$(wc -l < "${MINTERS}" | tr -d ' ')"
if [ "${n_minters}" -ge 1 ] && grep -qx hugmesh "${MINTERS}"; then
    ok "key-minting users found: $(tr '\n' ' ' < "${MINTERS}")"
else
    bad "no key-minting users found, or 'hugmesh' missing (got: $(tr '\n' ' ' < "${MINTERS}")) — every check below would be vacuous"
fi

# check_policy <label> <file>: the full contract for one policy document.
check_policy() {
    local label="$1" f="$2" owned
    if ! strip "$f" | jq -e 'type == "object"' >/dev/null 2>&1; then
        bad "${label}: does not parse as JSON after comment strip"; return
    fi
    if owned="$(owners_of_security_tags "$f")" && [ -z "${owned}" ]; then
        ok "${label}: every security tag has an EMPTY owner list"
    else
        bad "${label}: security tag(s) with an owner — $(printf '%s' "${owned}" | tr '\n' ';')"
    fi
    # Belt and braces, by NAME: no key-minting user and no group owns a security tag.
    local hits
    hits="$(strip "$f" | jq -r --arg re "${SEC_RE}" --rawfile m "${MINTERS}" '
        ($m | split("\n") | map(select(length > 0))) as $minters
        | (.tagOwners // {}) | to_entries[] | select(.key | test($re))
        | . as $e | (.value // [])[] | select(. as $o | ($minters | index($o)) or startswith("group:") or startswith("autogroup:"))
        | "\($e.key)<-\(.)"' 2>/dev/null)"
    [ -z "${hits}" ] && ok "${label}: no key-minting user or group owns a security tag" \
        || bad "${label}: key-minting principal owns a security tag: $(printf '%s' "${hits}" | tr '\n' ' ')"
    # ...and every key-minting user IS the membership user: it owns tag:hugmesh, or a
    # node joining with its key cannot carry the membership tag (and a minter that is
    # not the membership user is a user nobody reviewed the ownership of).
    local nonmember
    nonmember="$(strip "$f" | jq -r --rawfile m "${MINTERS}" '
        (.tagOwners["tag:hugmesh"] // []) as $own
        | $m | split("\n") | map(select(length > 0))[] | select(. as $u | ($own | index($u)) | not)' 2>/dev/null)"
    if [ -z "${nonmember}" ] && strip "$f" | jq -e '.tagOwners["tag:hugmesh"] | index("hugmesh")' >/dev/null 2>&1; then
        ok "${label}: every key-minting user owns the membership tag tag:hugmesh"
    else
        bad "${label}: key-minting user(s) that do not own tag:hugmesh: '${nonmember}' — keys are minted for a user that is not the membership user"
    fi
}

# ── 2. the shipped policy files ──────────────────────────────────────────────
echo "== shipped policy files =="
for rel in "${POLICIES[@]}"; do
    [ -f "${REPO}/${rel}" ] || { bad "${rel} missing"; continue; }
    check_policy "${rel}" "${REPO}/${rel}"
done
strip "${REPO}/specs/etc/headscale/policy.bootstrap.hujson" | jq -e '.tagOwners["tag:superadmin"] == []' >/dev/null 2>&1 \
    && ok "bootstrap declares tag:superadmin ownerless" || bad "bootstrap does not declare tag:superadmin with an empty owner list"

# ── 2b. the policy the REAL renderer produces ────────────────────────────────
echo "== rendered policy (real render_policy) =="
NODE_ENV=/dev/null
# shellcheck source=/dev/null
. "${RENDERER}"
POLICY_TMPL="${TMPL}"; TS_SSH_USER="superadmin"; MESH_ID="east-01"
MESH_TAG="tag:mesh_$(sanitise_tag "${MESH_ID}")"
EXPORT="${WORK}/export.json"
printf '%s' '{"signed":true,"signature":"x","body":{"meshId":"east-01","generation":3,"operators":[
  {"operator":"alice","machineKeyFp":"fpA","hostname":"a","keyFingerprints":["SHA256:k"],"via":"DEVICE-LICENSE"},
  {"operator":"bob","machineKeyFp":"fpB","hostname":"b","keyFingerprints":["SHA256:k"],"via":"DOMAIN-LICENSE"}]}}' > "${EXPORT}"
RENDERED="${WORK}/rendered.hujson"
if render_policy "${EXPORT}" "${RENDERED}"; then
    check_policy "rendered" "${RENDERED}"
    TAG_A="tag:$(dev_tag_for_fp fpA)"; TAG_B="tag:$(dev_tag_for_fp fpB)"
    for t in tag:superadmin "${MESH_TAG}" "${TAG_A}" "${TAG_B}"; do
        strip "${RENDERED}" | jq -e --arg t "$t" '.tagOwners | has($t) and .[$t] == []' >/dev/null 2>&1 \
            && ok "rendered: ${t} declared with an EMPTY owner list" \
            || bad "rendered: ${t} is not declared ownerless"
    done
    # every security tag the ssh[] block names must be declared ownerless (a later
    # edit that adds a new security tag to the rules must bring its declaration).
    undeclared="$(strip "${RENDERED}" | jq -r --arg re "${SEC_RE}" '
        .tagOwners as $o | [.ssh[]? | (.src[]?, .dst[]?)] | unique[]
        | select(test($re)) | select(($o | has(.)) | not)' 2>/dev/null)"
    [ -z "${undeclared}" ] && ok "rendered: every security tag in ssh[] is declared" \
        || bad "rendered: security tag(s) used in ssh[] but not declared ownerless: ${undeclared}"
else
    bad "render_policy failed on a synthetic export"
fi

# ── 2c. the shared Layer-A parity golden ─────────────────────────────────────
echo "== Layer-A parity golden =="
[ -f "${GOLDEN}" ] && check_policy "parity golden" "${GOLDEN}" || bad "parity golden missing"

# ── 3. keys-provision's guard ────────────────────────────────────────────────
echo "== keys-provision guard =="
GUARD_SRC="$(awk '/^headscale_policy_owned_security_tags\(\)/,/^}/' "${PROVISION}")"
if [ -n "${GUARD_SRC}" ]; then
    eval "${GUARD_SRC}"
    printf '%s' '{"tagOwners":{"tag:hugmesh":["hugmesh"],"tag:superadmin":["hugmesh"],"tag:dom_x":[]}}' > "${WORK}/owned.json"
    printf '%s' '{bad json' > "${WORK}/broken.json"
    out="$(headscale_policy_owned_security_tags "${WORK}/owned.json")" && [ "${out}" = "tag:superadmin" ] \
        && ok "guard flags an owned tag:superadmin (and only it)" || bad "guard missed an owned tag:superadmin (got '${out}')"
    out="$(headscale_policy_owned_security_tags "${REPO}/specs/etc/headscale/policy.bootstrap.hujson")" && [ -z "${out}" ] \
        && ok "guard passes the shipped bootstrap policy" || bad "guard rejects the shipped bootstrap policy ('${out}') — every first boot would fall into the narrowing branch"
    if headscale_policy_owned_security_tags "${WORK}/broken.json" >/dev/null; then
        bad "guard reports an unparseable policy as clean (fails OPEN)"
    else ok "guard reports an unparseable policy as unreadable (fails closed)"; fi
else
    bad "headscale_policy_owned_security_tags() not found in ${PROVISION}"
fi
PH_BODY="$(awk '/^provision_headscale\(\) \{/{p=1} p{print} p&&/^}/{exit}' "${PROVISION}" | grep -v -E '^[[:space:]]*#')"
grep -q 'headscale_policy_owned_security_tags "\${policy_file}"' <<< "${PH_BODY}" \
    && ok "provision_headscale checks the policy it is about to load" \
    || bad "provision_headscale never calls the security-tag owner guard on the policy it loads"

# ── 4. NEGATIVE CONTROLS ─────────────────────────────────────────────────────
echo "== negative controls =="
MUT_TMPL="${WORK}/mut.tmpl"
sed 's/"tag:superadmin": \[\]/"tag:superadmin": ["hugmesh"]/' "${TMPL}" > "${MUT_TMPL}"
if cmp -s "${TMPL}" "${MUT_TMPL}"; then
    bad "negative control could not plant tag:superadmin's owner (template shape changed?) — the check is unproven"
else
    POLICY_TMPL="${MUT_TMPL}"
    if render_policy "${EXPORT}" "${WORK}/mut1.hujson" && ! { o="$(owners_of_security_tags "${WORK}/mut1.hujson")" && [ -z "$o" ]; }; then
        ok "a template that gives tag:superadmin back to 'hugmesh' is caught"
    else bad "a template that gives tag:superadmin to 'hugmesh' was NOT caught"; fi
    POLICY_TMPL="${TMPL}"
fi
MUT_RENDERER="${WORK}/mut-renderer.sh"
sed 's/\\"tag:\${short}\\": \[\]/\\"tag:${short}\\": [\\"hugmesh\\"]/' "${RENDERER}" > "${MUT_RENDERER}"
if cmp -s "${RENDERER}" "${MUT_RENDERER}"; then
    bad "negative control could not plant a tag:dev_* owner in the renderer (shape changed?) — the check is unproven"
else
    if ( . "${MUT_RENDERER}"; POLICY_TMPL="${TMPL}"; render_policy "${EXPORT}" "${WORK}/mut2.hujson" ) \
       && ! { o="$(owners_of_security_tags "${WORK}/mut2.hujson")" && [ -z "$o" ]; }; then
        ok "a renderer that gives tag:dev_* an owner is caught"
    else bad "a renderer that gives tag:dev_* an owner was NOT caught"; fi
fi

echo
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

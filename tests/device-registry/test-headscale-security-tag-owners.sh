#!/usr/bin/env bash
# test-headscale-security-tag-owners.sh — no user that a pre-auth key is minted for
# may own a SECURITY tag in any headscale policy this repo ships or renders.
#
# WHY. headscale 0.23 (the version every image pins) gives a node the UNION of the
# tags the control node forces on it and every tag the node advertises whose
# tagOwners entry names the node's own user. A forced tag does NOT cancel a different
# advertised one. Every pre-auth key HugMesh mints (keys-provision from
# provision.json, the Studio's --mint, the web issuer) is for a membership user
# ("hugmesh" on every provisioned mesh; the Studio mints for the user the admin names,
# else the headscale container's net.hugmesh.headscale.user label, else
# DEFAULT_MINT_USER), so a security tag owned by "hugmesh" is a tag any key holder can claim by
# advertising it. tag:superadmin is the SSH source of the always-emitted superadmin
# rule (dst tag:mesh_<id>, which every node carries), so claiming it is SSH as the
# privileged user on every node. The fix is ownership, not forcing: security tags
# (tag:superadmin, tag:mesh_*, tag:dev_*, tag:dom_*) get an EMPTY owner list, and
# only `headscale nodes tag` (hugmesh-headscale-forcetags) assigns them — that path
# does not consult tagOwners.
#
# WHAT IT CHECKS (offline: bash + jq + openssl + awk + git):
#   1. the set of key-minting users, read from where keys are minted (provision.json
#      templates, the Studio's DEFAULT_MINT_USER, the net.hugmesh.headscale.user
#      labels in tests/stack/compose*.yaml the Studio defaults to, literal
#      `preauthkeys create --user` lines in tracked files) — never assumed; an empty
#      set fails (vacuity floor);
#   2. every shipped policy file + the policy the REAL renderer produces + the shared
#      Layer-A parity golden: each security tag has an EMPTY owner list, so no
#      key-minting user (or group) owns one; tag:superadmin and tag:mesh_<id> are
#      declared; the membership user still owns tag:hugmesh (or joins break);
#   3. keys-provision's guard (headscale_policy_owned_security_tags) flags an owned
#      security tag, passes a clean policy, reports an unparseable one as unreadable,
#      and provision_headscale actually calls it;
#   4. NEGATIVE CONTROLS: a renderer template with tag:superadmin given back to
#      "hugmesh", and a renderer that gives tag:dev_* an owner, are both caught by the
#      same check — so a green run is not a vacuous one;
#   5. Tailscale SSH SOURCES. Tailscale SSH answers :22 itself, so whoever an ssh rule
#      names as src gets a session as the privileged user; tag:hugmesh (and the role
#      tags, autogroup:member, "*", the "hugmesh" user) is every node holding a
#      pre-auth key. So: every ssh src in every shipped/rendered/golden policy is
#      tag:superadmin, the one :22 accept in acls is from tag:superadmin only, and
#      keys-provision's stick guard (headscale_policy_unprivileged_ssh_sources /
#      headscale_guard_ssh_sources) flags and narrows every other source under every
#      spelling headscale reads, on the policy AND on the bootstrap it falls back on.
#      Negative controls put tag:hugmesh back as a source and require a failure.
# The live proof that headscale really refuses a self-advertised tag:superadmin under
# this policy, and that only the force-tagged superadmin gets a Tailscale SSH session,
# is test-headscale-security-tag-live.sh (needs docker).
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
# Unless the admin names a user, the Studio mints for the headscale container's
# net.hugmesh.headscale.user label, else DEFAULT_MINT_USER: both are minters.
if [ -n "${studio_user}" ]; then
    echo "${studio_user}" >> "${MINTERS}"
    ok "Studio DEFAULT_MINT_USER read from mesh_token.py (${studio_user})"
else
    bad "${MESH_TOKEN} has no readable DEFAULT_MINT_USER — refusing to guess who the Studio mints for"
fi
label_users="$(cat "${REPO}"/tests/stack/compose*.yaml 2>/dev/null \
    | sed -n -E 's/^[[:space:]]*-?[[:space:]]*"?net\.hugmesh\.headscale\.user"?[[:space:]]*[:=][[:space:]]*"?([A-Za-z0-9][A-Za-z0-9_.-]*)"?[[:space:]]*$/\1/p')"
if [ -n "${label_users}" ]; then
    printf '%s\n' "${label_users}" >> "${MINTERS}"
    ok "headscale user label(s) the Studio defaults to: $(printf '%s' "${label_users}" | tr '\n' ' ')"
elif grep -q -s 'net\.hugmesh\.headscale\.user' "${REPO}"/tests/stack/compose*.yaml; then
    bad "a net.hugmesh.headscale.user label in tests/stack/compose*.yaml could not be read — refusing to guess who the Studio mints for"
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

# ── 5. Tailscale SSH sources ─────────────────────────────────────────────────
echo "== Tailscale SSH sources =="
# ssh_contract <label> <file>: every ssh src is tag:superadmin, there is at least one
# ssh rule (or this check is vacuous), tag:superadmin is declared ownerless (headscale
# 0.23 builds no map while a rule names an undeclared, unforced tag), and every acls
# entry but the CIDR data-plane rule is a :22-only accept from tag:superadmin, of
# which there is exactly one (without it the ssh rules are unreachable: measured).
ssh_contract() {
    local label="$1" f="$2" bad_src n22
    if ! strip "$f" | jq -e '(.ssh | type) == "array" and (.ssh | length) > 0' >/dev/null 2>&1; then
        bad "${label}: no ssh rule to check (the source check would be vacuous)"; return
    fi
    bad_src="$(strip "$f" | jq -r '[.ssh[] | (.src // [])[] | select(. != "tag:superadmin")] | unique[]' 2>/dev/null)"
    [ -z "${bad_src}" ] && ok "${label}: every ssh rule's src is tag:superadmin only" \
        || bad "${label}: ssh rule(s) grant a session to a non-privileged source: $(printf '%s' "${bad_src}" | tr '\n' ' ')"
    strip "$f" | jq -e '.tagOwners["tag:superadmin"] == []' >/dev/null 2>&1 \
        && ok "${label}: tag:superadmin (the ssh source) is declared with an EMPTY owner list" \
        || bad "${label}: tag:superadmin is not declared ownerless — either claimable or, undeclared, every node's map fails"
    n22="$(strip "$f" | jq '[.acls[] | select(.dst != ["10.244.0.0/16:*", "10.96.0.0/12:*"])] as $o
        | if all($o[]; .action == "accept" and .src == ["tag:superadmin"] and (.dst | length) > 0
                        and all(.dst[]; endswith(":22"))) then ($o | length) else -1 end' 2>/dev/null)"
    case "${n22}" in
        1)  ok "${label}: the only acl beside the CIDR rule is a :22 accept from tag:superadmin (the session can be reached, by nobody else)" ;;
        0)  bad "${label}: no :22 accept for tag:superadmin — every Tailscale SSH session times out at the packet filter" ;;
        -1) bad "${label}: an acl beside the CIDR rule is not a :22-only accept from tag:superadmin" ;;
        *)  bad "${label}: expected exactly one superadmin :22 accept, found '${n22}'" ;;
    esac
}
for rel in "${POLICIES[@]}"; do
    [ -f "${REPO}/${rel}" ] && ssh_contract "${rel}" "${REPO}/${rel}"
done
[ -f "${RENDERED}" ] && ssh_contract "rendered" "${RENDERED}" || bad "no rendered policy to check"
[ -f "${GOLDEN}" ] && ssh_contract "parity golden" "${GOLDEN}"

echo "== keys-provision ssh-source guard =="
SSH_GUARD_SRC="$(for fn in headscale_policy_unprivileged_ssh_sources headscale_policy_narrow_ssh_sources headscale_guard_ssh_sources; do
    awk -v f="${fn}()" 'index($0, f) == 1 {p=1} p {print} p && /^}/ {exit}' "${PROVISION}"; done)"
if grep -q '^headscale_guard_ssh_sources()' <<< "${SSH_GUARD_SRC}" \
   && grep -q '^headscale_policy_narrow_ssh_sources()' <<< "${SSH_GUARD_SRC}" \
   && grep -q '^headscale_policy_unprivileged_ssh_sources()' <<< "${SSH_GUARD_SRC}"; then
    log()  { :; }; warn() { :; }
    eval "${SSH_GUARD_SRC}"
    G="${WORK}/sshguard"; mkdir -p "${G}"
    # srcs_of <json-text>: what the guard reports, space-joined; "UNREADABLE" when it says rc 1.
    srcs_of() {
        printf '%s' "$1" > "${G}/p.json"
        local o; o="$(headscale_policy_unprivileged_ssh_sources "${G}/p.json")" || { echo UNREADABLE; return; }
        printf '%s' "${o}" | tr '\n' ' ' | sed 's/ $//'
    }
    expect() { # <label> <expected> <json>
        local got; got="$(srcs_of "$3")"
        [ "${got}" = "$2" ] && ok "guard: $1 -> '${2:-clean}'" || bad "guard: $1 -> expected '${2:-clean}', got '${got}'"
    }
    expect "only tag:superadmin"                 ""                 '{"ssh":[{"action":"accept","src":["tag:superadmin"],"dst":["tag:hugmesh"],"users":["a"]}]}'
    expect "tag:hugmesh (main's shape)"          "tag:hugmesh"      '{"ssh":[{"action":"accept","src":["tag:hugmesh"],"dst":["tag:hugmesh"],"users":["a"]}]}'
    expect "autogroup:member beside superadmin"  "autogroup:member" '{"ssh":[{"src":["autogroup:member","tag:superadmin"]}]}'
    expect "a self-applied role tag"             "tag:pki"          '{"ssh":[{"action":"check","src":["tag:pki"]}]}'
    expect "the wildcard"                        "*"                '{"ssh":[{"src":["*"]}]}'
    expect "the membership user and a group"     "group:ops hugmesh" '{"ssh":[{"src":["hugmesh"]},{"src":["group:ops"]}]}'
    expect "ownerless but forced on every node"  "tag:mesh_east-01" '{"ssh":[{"src":["tag:mesh_east-01"]}]}'
    expect "an \"SSH\" member headscale also reads" "tag:pki"       '{"ssh":[{"src":["tag:superadmin"]}],"SSH":[{"Src":["tag:pki"]}]}'
    expect "the first of two ssh members"        "*"                '{"ssh":[{"src":["*"]}],"ssh":[{"src":["tag:superadmin"]}]}'
    expect "the first of two src members"        "hugmesh"          '{"ssh":[{"src":["hugmesh"],"src":["tag:superadmin"]}]}'
    expect "no ssh member at all"                ""                 '{"acls":[]}'
    expect "a non-ASCII top-level name"          UNREADABLE         "$(printf '{"\xc5\xbfsh":[{"src":["tag:hugmesh"]}]}')"
    expect "a non-ASCII rule member name"        UNREADABLE         "$(printf '{"ssh":[{"\xc5\xbfrc":["tag:hugmesh"]}]}')"
    expect "src as a bare string"                UNREADABLE         '{"ssh":[{"src":"tag:hugmesh"}]}'
    expect "ssh as an object"                    UNREADABLE         '{"ssh":{"x":{"src":["tag:hugmesh"]}}}'
    expect "a // inside a string"                UNREADABLE         '{"ssh":[{"src":["tag:superadmin"],"x":"//","SRC":["tag:hugmesh"]}]}'
    expect "unparseable text"                    UNREADABLE         '{bad'
    expect "an empty file"                       UNREADABLE         ''
    for rel in "${POLICIES[@]}"; do
        o="$(headscale_policy_unprivileged_ssh_sources "${REPO}/${rel}")" && [ -z "${o}" ] \
            && ok "guard passes the shipped ${rel}" || bad "guard rejects the shipped ${rel} ('${o}')"
    done
    # narrowing keeps everything but the bad sources
    printf '%s' '{"acls":[{"action":"accept","src":["tag:hugmesh"],"dst":["10.244.0.0/16:*"]}],"SSH":[{"Src":["tag:pki","tag:superadmin"],"dst":["tag:hugmesh"],"users":["a"]},{"src":["*"]}],"ssh":[{"src":["tag:hugmesh"],"users":["a"]}]}' > "${G}/n.json"
    if headscale_policy_narrow_ssh_sources "${G}/n.json" \
       && jq -e '.SSH == [{"Src":["tag:superadmin"],"dst":["tag:hugmesh"],"users":["a"]}] and .ssh == []
                 and .acls == [{"action":"accept","src":["tag:hugmesh"],"dst":["10.244.0.0/16:*"]}]' "${G}/n.json" >/dev/null; then
        ok "narrowing keeps only tag:superadmin sources, drops rules left with none, leaves acls alone"
    else bad "narrowing produced $(jq -c . "${G}/n.json" 2>/dev/null)"; fi
    printf '%s' '{bad' > "${G}/n2.json"
    if headscale_policy_narrow_ssh_sources "${G}/n2.json"; then bad "narrowing 'succeeded' on unparseable text"
    elif [ "$(cat "${G}/n2.json")" = '{bad' ] && [ -z "$(find "${G}" -name 'n2.json.ssh-narrowed.*')" ]; then
        ok "narrowing an unparseable policy fails, leaves the file untouched and no temp file"
    else bad "a failed narrowing changed the file or left a temp file"; fi

    # headscale_guard_ssh_sources end to end, against throwaway policy/bootstrap files.
    MAIN_SHAPE='{"tagOwners":{"tag:hugmesh":["hugmesh"],"tag:superadmin":[]},"acls":[],"ssh":[{"action":"accept","src":["tag:hugmesh"],"dst":["tag:hugmesh"],"users":["admin"]}]}'
    # Each case gets its own directory (${C}); nothing is reused or removed.
    n_case=0
    case_dir() { n_case=$((n_case + 1)); C="${G}/case${n_case}"; mkdir -p "${C}"; }
    clean_now() { o="$(headscale_policy_unprivileged_ssh_sources "$1")" && [ -z "${o}" ]; }
    case_dir; printf '%s' "${MAIN_SHAPE}" > "${C}/policy.hujson"; cp "${REPO}/specs/etc/headscale/policy.bootstrap.hujson" "${C}/boot.hujson"
    headscale_guard_ssh_sources "${C}/policy.hujson" "${C}/boot.hujson"
    cmp -s "${C}/policy.hujson" "${REPO}/specs/etc/headscale/policy.bootstrap.hujson" \
        && ok "stick policy granting SSH to tag:hugmesh -> the clean bootstrap is staged instead" \
        || bad "stick policy granting SSH to tag:hugmesh was not replaced by the bootstrap"
    case_dir; printf '%s' "${MAIN_SHAPE}" > "${C}/policy.hujson"; printf '%s' "${MAIN_SHAPE}" > "${C}/boot.hujson"
    headscale_guard_ssh_sources "${C}/policy.hujson" "${C}/boot.hujson"
    clean_now "${C}/policy.hujson" && clean_now "${C}/boot.hujson" \
        && ok "a stick that also ships its own member-SSH bootstrap: both end up naming tag:superadmin only" \
        || bad "a stick-supplied member-SSH bootstrap survived the guard (the owner check falls back on it)"
    case_dir; printf '%s' '{bad' > "${C}/policy.hujson"; cp "${REPO}/specs/etc/headscale/policy.bootstrap.hujson" "${C}/boot.hujson"
    headscale_guard_ssh_sources "${C}/policy.hujson" "${C}/boot.hujson"
    cmp -s "${C}/policy.hujson" "${REPO}/specs/etc/headscale/policy.bootstrap.hujson" \
        && ok "an unreadable stick policy -> the clean bootstrap is staged" || bad "an unreadable stick policy was kept although a clean bootstrap exists"
    case_dir; cp "${REPO}/keys-template/headscale/policy.hujson" "${C}/policy.hujson"; cp "${REPO}/specs/etc/headscale/policy.bootstrap.hujson" "${C}/boot.hujson"
    headscale_guard_ssh_sources "${C}/policy.hujson" "${C}/boot.hujson"
    cmp -s "${C}/policy.hujson" "${REPO}/keys-template/headscale/policy.hujson" \
        && ok "the shipped keys-template policy is loaded as is (byte for byte)" || bad "the guard rewrote a clean keys-template policy"
    case_dir; printf '%s' "${MAIN_SHAPE}" > "${C}/policy.hujson"
    headscale_guard_ssh_sources "${C}/policy.hujson" "${C}/boot.hujson"
    clean_now "${C}/policy.hujson" && jq -e '.ssh == [] and .tagOwners["tag:superadmin"] == []' "${C}/policy.hujson" >/dev/null 2>&1 \
        && ok "no bootstrap at all -> the stick policy itself is narrowed" || bad "with no bootstrap the member-SSH policy was left as is"
    case_dir; printf '%s' "${MAIN_SHAPE}" > "${C}/policy.hujson"; printf '%s' '{bad' > "${C}/boot.hujson"
    headscale_guard_ssh_sources "${C}/policy.hujson" "${C}/boot.hujson"
    [ ! -e "${C}/boot.hujson" ] && [ -e "${C}/boot.hujson.refused" ] && clean_now "${C}/policy.hujson" \
        && ok "an unreadable bootstrap is set aside (nothing falls back on it) and the policy is narrowed" \
        || bad "an unreadable bootstrap stayed in place, or the policy was not narrowed"
else
    bad "the ssh-source guard functions are not all in ${PROVISION}"
fi
# The call: provision_headscale runs the guard on the policy it loads and on the
# bootstrap, BEFORE the owner check (whose bootstrap fallback must already be clean).
call_ln="$(grep -n 'headscale_guard_ssh_sources /etc/headscale/policy.hujson /etc/headscale/policy.bootstrap.hujson' <<< "${PH_BODY}" | head -1 | cut -d: -f1)"
owner_ln="$(grep -n 'headscale_policy_owned_security_tags "\${policy_file}"' <<< "${PH_BODY}" | head -1 | cut -d: -f1)"
if [ -n "${call_ln}" ] && [ -n "${owner_ln}" ] && [ "${call_ln}" -lt "${owner_ln}" ]; then
    ok "provision_headscale runs the ssh-source guard on policy.hujson + the bootstrap, before the owner check"
else bad "provision_headscale does not run headscale_guard_ssh_sources before the owner check (guard line '${call_ln}', owner line '${owner_ln}')"; fi

echo "== negative controls (ssh sources) =="
MUT_R="${WORK}/mut-ssh-renderer.sh"
sed 's/^SSH_SRC="tag:superadmin"$/SSH_SRC="tag:hugmesh"/' "${RENDERER}" > "${MUT_R}"
if cmp -s "${RENDERER}" "${MUT_R}"; then
    bad "negative control could not plant tag:hugmesh as the renderer's ssh source (shape changed?) — the check is unproven"
elif ( . "${MUT_R}"; POLICY_TMPL="${TMPL}"; render_policy "${EXPORT}" "${WORK}/mut3.hujson" ) \
     && [ -n "$(strip "${WORK}/mut3.hujson" | jq -r '[.ssh[] | .src[] | select(. != "tag:superadmin")] | .[]')" ]; then
    ok "a renderer whose ssh source is tag:hugmesh is caught"
else bad "a renderer whose ssh source is tag:hugmesh was NOT caught"; fi
sed 's/"src": \["tag:superadmin"\],/"src": ["tag:hugmesh"],/' "${REPO}/keys-template/headscale/policy.hujson" > "${WORK}/mut-stick.hujson"
if cmp -s "${REPO}/keys-template/headscale/policy.hujson" "${WORK}/mut-stick.hujson"; then
    bad "negative control could not plant tag:hugmesh as the stick policy's ssh source — the check is unproven"
else
    o="$(headscale_policy_unprivileged_ssh_sources "${WORK}/mut-stick.hujson")" && [ "${o}" = "tag:hugmesh" ] \
        && ok "a stick policy with tag:hugmesh as its ssh source is flagged by the guard" \
        || bad "a stick policy with tag:hugmesh as its ssh source was NOT flagged (got '${o}')"
fi

echo
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

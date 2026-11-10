#!/usr/bin/env bash
# test-headscale-tag-ownership.sh — a node must NOT be able to give itself a
# server-forced tag, proven against a REAL headscale and REAL tailscale clients.
#
# THE DEFECT THIS GUARDS (measured on main, headscale 0.23.0)
# -----------------------------------------------------------
# headscale 0.23 accepts a tag a node advertises (--advertise-tags) when the node's
# USER is listed among that tag's tagOwners. Every HugMesh node registers as the one
# "hugmesh" headscale user. The policy listed tag:superadmin, and every rendered
# tag:dev_<fp>, as owned by ["hugmesh"], so ANY node could claim them. A node that
# advertised tag:superadmin got valid_tags=[tag:hugmesh, tag:superadmin], and the
# 0.23 SSH compiler then listed it as a principal of the always-emitted
#     {src:[tag:superadmin], dst:[tag:mesh_<id>], users:[<privileged user>]}
# rule on every mesh node. Valid self-advertised tags count in that evaluator even
# when the node also carries forced tags.
#
# THE FIX: every server-forced tag is listed with the EMPTY owner list [], an owner
# no node registers under. Forced tags (a preauth key's tags, `headscale nodes tag
# -t`, which hugmesh-headscale-forcetags uses) bypass tagOwners, so they still apply.
# tag:hugmesh and the role tags pki/be/fe/host stay owned by "hugmesh": nodes apply
# them to themselves by design.
#
# WHAT THIS RUNS
# --------------
# Three throwaway headscale instances (one docker network, unique names, no host
# ports, all removed on exit), each with userspace tailscale clients:
#   1. the policy the REAL renderer emits (gen-headscale-policy.sh render_policy
#      over the shared parity export), loaded as raw hujson:
#        - headscale starts with it (the rendered policy loads);
#        - a node joining before ANY node is force-tagged still reaches Running (the
#          superadmin rule's tag:mesh_<id> is listed, so map updates do not fail);
#        - that node self-advertises tag:superadmin, tag:dev_<fp>, tag:mesh_<id>
#          and tag:dom_* and every one lands in invalid_tags. tag:superadmin goes
#          through the stock `tailscale up --advertise-tags`. The stock CLI refuses
#          '_' in a tag name, so the underscore tags go in through tailscaled's
#          LocalAPI (PATCH /localapi/v0/prefs, which does not check the charset),
#          as root on any node can do;
#        - the key's tag (tag:hugmesh) is still applied as a forced tag;
#        - it is NOT an SSH principal on a tag:mesh_ node, and no ssh rule
#          targets it for the dst tags it advertised;
#        - `headscale nodes tag -t ...,tag:superadmin` still works with owner []
#          and makes it a principal (the force-tagger's path);
#        - a preauth key carrying tag:superadmin forces it too (so the key minters,
#          not tagOwners, are what keep tag:superadmin off keys).
#   2. the baked bootstrap policy: it loads and refuses a self-advertised
#      tag:superadmin.
#   3. CONTROL: policy 1 with tag:superadmin and tag:dev_* owned by ["hugmesh"]
#      again, as on main. The defect MUST reproduce (both tags valid, an SSH
#      principal of the superadmin rule, an ssh rule targeting the masquerading
#      node), or this suite cannot tell the fix from its absence and fails.
#
# Needs docker + jq. Missing tooling FAILS (tests/lib/guard-preflight.sh), never
# skips. Images default to the fleet pins (brand.conf.example HEADSCALE_VERSION /
# TAILSCALE_VERSION); override with HS_IMAGE / TS_IMAGE / CURL_IMAGE (the LocalAPI
# client). The suite prints no key.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RENDERER="${REPO}/specs/usr/sbin/gen-headscale-policy.sh"
TMPL="${REPO}/specs/etc/headscale/policy.hujson.tmpl"
BOOTSTRAP="${REPO}/specs/etc/headscale/policy.bootstrap.hujson"
FIXDIR="${REPO}/tests/device-registry/fixtures"
PARITY_PARAMS="${FIXDIR}/layer-a-parity-params.env"
PARITY_EXPORT="${FIXDIR}/layer-a-parity-export.json"
BRAND_EXAMPLE="${REPO}/brand.conf.example"

. "${REPO}/tests/lib/guard-preflight.sh"
guard_require_tools docker jq sed awk grep
docker info >/dev/null 2>&1 || guard_require_capability "no usable docker daemon"

# Source the REAL renderer (its main is guarded out when sourced). It sets its own
# `set -uo pipefail`; the counters below are defined after it so nothing clobbers them.
NODE_ENV=/dev/null
# shellcheck source=/dev/null
. "${RENDERER}"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
note(){ echo "  NOTE $*"; }

pin_of() {
    local k
    k="$1"
    sed -n "s/^${k}=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "${BRAND_EXAMPLE}" | head -1
}
HS_PIN="$(pin_of HEADSCALE_VERSION)"
TS_PIN="$(pin_of TAILSCALE_VERSION)"
HS_IMAGE="${HS_IMAGE:-headscale/headscale:${HS_PIN:-0.23.0}}"
TS_IMAGE="${TS_IMAGE:-tailscale/tailscale:v${TS_PIN:-1.78.1}}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.11.1}"

ensure_image() {
    local img
    img="$1"
    docker image inspect "${img}" >/dev/null 2>&1 && return 0
    docker pull -q "${img}" >/dev/null 2>&1 && return 0
    guard_require_capability "cannot find or pull ${img}"
}
ensure_image "${HS_IMAGE}"
ensure_image "${TS_IMAGE}"
ensure_image "${CURL_IMAGE}"

RUN_ID="hm-g5tag-$$-${RANDOM}"
NET="${RUN_ID}-net"
WORK="$(mktemp -d)"
CONTAINERS=()
VOLUMES=()
cleanup() {
    local c
    for c in "${CONTAINERS[@]}"; do docker rm -f "${c}" >/dev/null 2>&1 || true; done
    for c in "${VOLUMES[@]}"; do docker volume rm "${c}" >/dev/null 2>&1 || true; done
    docker network rm "${NET}" >/dev/null 2>&1 || true
    rm -rf "${WORK}"
}
trap cleanup EXIT
docker network create "${NET}" >/dev/null || guard_require_capability "cannot create a docker network"

echo "== headscale tag ownership: ${HS_IMAGE} + ${TS_IMAGE} (run ${RUN_ID}) =="

# ── Policies under test ───────────────────────────────────────────────────────
# shellcheck source=/dev/null
. "${PARITY_PARAMS}"
POLICY_TMPL="${TMPL}"
MESH_TAG="tag:mesh_$(sanitise_tag "${MESH_ID}")"
DEV_TAG="tag:$(dev_tag_for_fp fpA)"
DOM_TAG="tag:dom_example-org"
SSH_USER="${TS_SSH_USER}"

POL_FIXED="${WORK}/rendered.hujson"
POL_BOOT="${WORK}/bootstrap.hujson"
POL_CONTROL="${WORK}/control.json"
# The control is main's ownership: tag:superadmin and tag:dev_* owned by "hugmesh".
if render_policy "${PARITY_EXPORT}" "${POL_FIXED}"; then
    ok "the real renderer renders the parity export (mesh ${MESH_TAG}, dev ${DEV_TAG})"
else
    bad "render_policy failed on the parity export — nothing below can run"
    echo "== RESULT: ${P} passed, ${F} failed =="
    exit 1
fi
sed -e "s/@@TS_SSH_USER@@/${SSH_USER}/g" "${BOOTSTRAP}" > "${POL_BOOT}"
sed -e 's#//.*$##' "${POL_FIXED}" | jq '.tagOwners |= with_entries(if .key == "tag:superadmin" or (.key | startswith("tag:dev_")) then .value = ["hugmesh"] else . end)' > "${POL_CONTROL}" \
    || { bad "could not build the control policy"; exit 1; }

# ── Helpers ───────────────────────────────────────────────────────────────────
HS=""        # current headscale container name

hs() { docker exec "${HS}" headscale "$@"; }

# hs_start <label> <policy file>: a fresh headscale, policy mode file, sqlite on
# tmpfs, embedded DERP only (no internet), no published port. Config and policy go
# in with `docker cp`, so no host path is bind-mounted.
hs_start() {
    local label pol dir i
    label="$1"; pol="$2"
    HS="${RUN_ID}-hs-${label}"
    dir="${WORK}/${label}"
    mkdir -p "${dir}"
    cp "${pol}" "${dir}/policy.hujson"
    cat > "${dir}/config.yaml" <<EOF
server_url: http://${HS}:8080
listen_addr: 0.0.0.0:8080
metrics_listen_addr: 127.0.0.1:9090
grpc_listen_addr: 127.0.0.1:50443
grpc_allow_insecure: false
noise:
  private_key_path: /var/lib/headscale/noise_private.key
policy:
  mode: file
  path: /etc/headscale/policy.hujson
prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
  allocation: sequential
derp:
  server:
    enabled: true
    region_id: 999
    region_code: local
    region_name: local
    stun_listen_addr: 0.0.0.0:3478
    private_key_path: /var/lib/headscale/derp_server_private.key
    automatically_add_embedded_derp_region: true
  urls: []
  paths: []
  auto_update_enabled: false
disable_check_updates: true
database:
  type: sqlite
  sqlite:
    path: /var/lib/headscale/db.sqlite
log:
  level: info
dns:
  magic_dns: false
  base_domain: headnet.internal
  nameservers:
    global: []
unix_socket: /var/run/headscale/headscale.sock
unix_socket_permission: "0770"
EOF
    CONTAINERS+=("${HS}")
    docker create --name "${HS}" --network "${NET}" \
        --tmpfs /var/lib/headscale --tmpfs /var/run/headscale \
        "${HS_IMAGE}" serve >/dev/null || return 1
    docker cp "${dir}/." "${HS}:/etc/headscale" >/dev/null || return 1
    docker start "${HS}" >/dev/null || return 1
    for i in $(seq 1 30); do
        hs users list >/dev/null 2>&1 && break
        sleep 1
    done
    if ! hs users list >/dev/null 2>&1; then
        echo "      headscale log (errors only):"
        docker logs "${HS}" 2>&1 | grep -E ' (ERR|FTL|WRN) |error' | tail -8 | sed 's/^/        /'
        return 1
    fi
    hs users create hugmesh >/dev/null 2>&1 || return 1
    return 0
}

hs_stop() {
    docker rm -f "${HS}" >/dev/null 2>&1 || true
}

# mint_key <comma tags>: prints the key on stdout for capture ONLY (never echoed).
mint_key() {
    local tags
    tags="$1"
    hs preauthkeys create -u hugmesh --expiration 1h --tags "${tags}" -o json 2>/dev/null | jq -r '.key // empty'
}

# ts_join <hostname> <key> <advertise-tags>: a userspace tailscale client; returns
# 0 once its backend is Running (map updates are being served), 1 otherwise.
ts_join() {
    local host key adv c i st out
    host="$1"; key="$2"; adv="$3"
    c="${RUN_ID}-ts-${host}"
    CONTAINERS+=("${c}")
    VOLUMES+=("${c}-sock")
    docker volume create "${c}-sock" >/dev/null || return 1
    docker run -d --name "${c}" --network "${NET}" -v "${c}-sock:/var/run/tailscale" \
        --entrypoint /usr/local/bin/tailscaled \
        "${TS_IMAGE}" --tun=userspace-networking --state=mem: >/dev/null || return 1
    for i in $(seq 1 10); do
        docker exec "${c}" tailscale status --json >/dev/null 2>&1 && break
        # NeedsLogin answers with rc!=0 but JSON; any answer means tailscaled is up.
        docker exec "${c}" tailscale status --json 2>/dev/null | jq -e .BackendState >/dev/null 2>&1 && break
        sleep 1
    done
    out="$(docker exec "${c}" tailscale up --login-server "http://${HS}:8080" --auth-key "${key}" \
        --hostname "${host}" --advertise-tags="${adv}" --timeout 30s 2>&1)" || true
    for i in $(seq 1 20); do
        st="$(docker exec "${c}" tailscale status --json 2>/dev/null | jq -r '.BackendState // empty')"
        [ "${st}" = "Running" ] && return 0
        sleep 1
    done
    echo "      ${host}: backend '${st:-none}'; tailscale up said: ${out//${key}/<redacted>}" | head -3
    echo "      headscale log (errors only):"
    docker logs "${HS}" 2>&1 | grep -E ' (ERR|FTL) ' | sed -E 's/^[^ ]+ //' | sort | uniq -c | tail -4 | sed 's/^/        /'
    return 1
}

# lapi_advertise <host> <tag>...: set AdvertiseTags through tailscaled's LocalAPI,
# which (unlike the CLI) does not refuse '_' in a tag name. Root on a node can do
# this; it is what a client that skips the CLI check sends.
lapi_advertise() {
    local host body
    host="$1"; shift
    body="$(jq -cn '{AdvertiseTagsSet: true, AdvertiseTags: $ARGS.positional}' --args "$@")"
    docker run --rm --user 0 -v "${RUN_ID}-ts-${host}-sock:/var/run/tailscale" "${CURL_IMAGE}" \
        -sS -f --unix-socket /var/run/tailscale/tailscaled.sock -H 'Sec-Tailscale: localapi' \
        -X PATCH http://local-tailscaled.sock/localapi/v0/prefs -d "${body}" 2>/dev/null \
        | jq -c '.AdvertiseTags // []'
}

node_json() {
    hs nodes list -o json 2>/dev/null | jq -c --arg n "$1" '[.[] | select(.given_name == $n)][0] // empty'
}
node_id()  { node_json "$1" | jq -r '.id // empty'; }
node_ips() { node_json "$1" | jq -r '.ip_addresses[]?'; }
# tags_of <host> <forced_tags|valid_tags|invalid_tags>: sorted, one per line
tags_of()  { node_json "$1" | jq -r --arg f "$2" '(.[$f] // []) | sort | .[]'; }

# ssh_principals <host>: the nodeIPs any ssh rule in <host>'s own netmap admits.
ssh_principals() {
    docker exec "${RUN_ID}-ts-$1" tailscale debug netmap 2>/dev/null \
        | jq -r '[.SSHPolicy.rules[]?.principals[]?.nodeIP // empty] | unique | .[]'
}
ssh_rule_count() {
    docker exec "${RUN_ID}-ts-$1" tailscale debug netmap 2>/dev/null \
        | jq -r '[.SSHPolicy.rules[]?] | length'
}

# admits <victim> <attacker>: true iff any of attacker's IPs is a principal on victim.
admits() {
    local p ip
    p="$(ssh_principals "$1")"
    while IFS= read -r ip; do
        [ -n "${ip}" ] || continue
        printf '%s\n' "${p}" | grep -Fx -- "${ip}" >/dev/null && return 0
    done <<< "$(node_ips "$2")"
    return 1
}

# wait_until <seconds> <cmd...>: poll a predicate (netmap updates are asynchronous).
wait_until() {
    local n i
    n="$1"; shift
    for i in $(seq 1 "${n}"); do
        "$@" && return 0
        sleep 1
    done
    return 1
}
not_admits() { ! admits "$@"; }
# headscale_sees <host> <field> <tag>: the tag shows up in that node's field.
headscale_sees() { contains_line "$(tags_of "$1" "$2")" "$3"; }
has_ssh_rules() { [ "$(ssh_rule_count "$1")" -gt 0 ] 2>/dev/null; }

contains_line() { printf '%s\n' "$1" | grep -Fx -- "$2" >/dev/null; }

# ── 1. The rendered policy ────────────────────────────────────────────────────
echo
echo "-- 1. the policy gen-headscale-policy.sh renders --"
if hs_start fixed "${POL_FIXED}"; then
    ok "headscale ${HS_IMAGE##*:} starts with the rendered policy (raw hujson, comments included)"
    K="$(mint_key tag:hugmesh)"
    if [ -z "${K}" ]; then
        bad "could not mint a tag:hugmesh preauth key"
    elif ts_join attacker "${K}" "tag:hugmesh,tag:superadmin"; then
        ok "a node joining before ANY node is force-tagged reaches Running (the superadmin rule's ${MESH_TAG} resolves)"
        ADV="$(lapi_advertise attacker tag:hugmesh tag:superadmin "${DEV_TAG}" "${MESH_TAG}" "${DOM_TAG}")"
        if printf '%s' "${ADV}" | jq -e --arg d "${DEV_TAG}" 'index($d) != null' >/dev/null 2>&1; then
            ok "the attacker now advertises ${DEV_TAG}, ${MESH_TAG} and ${DOM_TAG} too (LocalAPI prefs)"
        else
            bad "could not make the attacker advertise the underscore tags through the LocalAPI (got: ${ADV:-nothing})"
        fi
        wait_until 15 headscale_sees attacker invalid_tags "${DEV_TAG}" >/dev/null || true
        INV="$(tags_of attacker invalid_tags)"
        for t in tag:superadmin "${DEV_TAG}" "${MESH_TAG}" "${DOM_TAG}"; do
            if contains_line "${INV}" "${t}"; then
                ok "self-advertised ${t} lands in invalid_tags"
            else
                bad "self-advertised ${t} is NOT in invalid_tags (invalid=[$(echo ${INV})], valid=[$(echo $(tags_of attacker valid_tags))]) — a node can give itself that tag"
            fi
        done
        VAL="$(tags_of attacker valid_tags)"
        [ "${VAL}" = "tag:hugmesh" ] \
            && ok "valid_tags is exactly [tag:hugmesh] (tag:hugmesh stays self-applied)" \
            || bad "valid_tags is [$(echo ${VAL})], expected exactly [tag:hugmesh]"
        FRC="$(tags_of attacker forced_tags)"
        [ "${FRC}" = "tag:hugmesh" ] \
            && ok "the preauth key's tag is applied as a forced tag (forced_tags=[tag:hugmesh])" \
            || bad "forced_tags is [$(echo ${FRC})], expected the key's [tag:hugmesh]"
    else
        bad "a node joining the rendered policy never reached Running — map updates are failing"
    fi

    K="$(mint_key tag:hugmesh)"
    if [ -n "${K}" ] && ts_join victim "${K}" "tag:hugmesh"; then
        VID="$(node_id victim)"
        if hs nodes tag -i "${VID}" -t "tag:hugmesh,${MESH_TAG}" >/dev/null 2>&1; then
            ok "headscale nodes tag -t tag:hugmesh,${MESH_TAG} succeeds (the force-tagger's call)"
        else
            bad "headscale nodes tag -t ...,${MESH_TAG} failed"
        fi
        FRC="$(tags_of victim forced_tags)"
        contains_line "${FRC}" "${MESH_TAG}" \
            && ok "forced ${MESH_TAG} is applied to the victim although its owner list is []" \
            || bad "forced ${MESH_TAG} not applied (forced=[$(echo ${FRC})])"
        if wait_until 20 has_ssh_rules victim; then
            ok "the victim's netmap carries the superadmin ssh rule"
            if wait_until 5 not_admits victim attacker; then
                ok "the self-advertised tag:superadmin node is NOT an ssh principal on the ${MESH_TAG} node"
            else
                bad "the self-advertised tag:superadmin node IS an ssh principal on the ${MESH_TAG} node (principals: $(echo $(ssh_principals victim)))"
            fi
        else
            bad "the victim's netmap has no ssh rule for the superadmin rule's ${MESH_TAG} dst"
        fi
        n="$(ssh_rule_count attacker)"
        [ "${n}" = "0" ] \
            && ok "no ssh rule targets the attacker for the ${DEV_TAG}/${MESH_TAG} it advertised (0 rules in its netmap)" \
            || bad "the attacker's netmap carries ${n:-?} ssh rule(s) — a self-advertised dst tag was honoured"

        AID="$(node_id attacker)"
        if [ -n "${AID}" ] && hs nodes tag -i "${AID}" -t "tag:hugmesh,tag:superadmin" >/dev/null 2>&1; then
            ok "headscale nodes tag -t tag:hugmesh,tag:superadmin succeeds with tag:superadmin's owner list []"
            FRC="$(tags_of attacker forced_tags)"
            contains_line "${FRC}" "tag:superadmin" \
                && ok "the forced tag:superadmin is applied" \
                || bad "forced tag:superadmin not applied (forced=[$(echo ${FRC})])"
            if wait_until 20 admits victim attacker; then
                ok "a FORCED tag:superadmin makes the node an ssh principal on the ${MESH_TAG} node (the intended path still works)"
            else
                bad "a forced tag:superadmin is not an ssh principal on the ${MESH_TAG} node — the superadmin rule is dead"
            fi
        else
            bad "headscale nodes tag -t tag:hugmesh,tag:superadmin failed with owner [] (hugmesh-headscale-forcetags relies on it)"
        fi
    else
        bad "the victim node never reached Running"
    fi

    K="$(mint_key tag:hugmesh,tag:superadmin)"
    if [ -z "${K}" ]; then
        note "headscale refused to mint a tag:superadmin preauth key"
    elif ts_join keyforced "${K}" "tag:hugmesh"; then
        FRC="$(tags_of keyforced forced_tags)"
        if contains_line "${FRC}" "tag:superadmin"; then
            ok "a preauth key's tags are forced past an owner list of [] too (forced=[$(echo ${FRC})])"
            note "so headscale does NOT stop a tag:superadmin KEY: the minters must only ever ask for tag:hugmesh (+ a role tag)"
        else
            bad "a key carrying tag:superadmin did not force it (forced=[$(echo ${FRC})])"
        fi
    else
        bad "the key-forced node never reached Running"
    fi
    hs_stop
else
    bad "headscale did not start with the rendered policy — the policy does not load"
fi

# ── 2. The bootstrap policy ───────────────────────────────────────────────────
echo
echo "-- 2. policy.bootstrap.hujson --"
if hs_start boot "${POL_BOOT}"; then
    ok "headscale starts with the bootstrap policy (@@TS_SSH_USER@@ -> ${SSH_USER})"
    K="$(mint_key tag:hugmesh)"
    if [ -n "${K}" ] && ts_join bootnode "${K}" "tag:hugmesh,tag:superadmin"; then
        INV="$(tags_of bootnode invalid_tags)"
        contains_line "${INV}" "tag:superadmin" \
            && ok "the bootstrap policy refuses a self-advertised tag:superadmin (invalid_tags)" \
            || bad "the bootstrap policy accepts a self-advertised tag:superadmin (valid=[$(echo $(tags_of bootnode valid_tags))])"
    else
        bad "a node never reached Running under the bootstrap policy"
    fi
    hs_stop
else
    bad "headscale did not start with the bootstrap policy"
fi

# ── 3. CONTROL: the defect must reproduce with the old owner ──────────────────
echo
echo "-- 3. control: tag:superadmin + tag:dev_* owned by [\"hugmesh\"] (main before the fix) --"
if hs_start control "${POL_CONTROL}"; then
    K="$(mint_key tag:hugmesh)"
    K2="$(mint_key tag:hugmesh)"
    if [ -n "${K}" ] && [ -n "${K2}" ] && ts_join cvictim "${K2}" "tag:hugmesh" \
       && ts_join cattacker "${K}" "tag:hugmesh,tag:superadmin"; then
        hs nodes tag -i "$(node_id cvictim)" -t "tag:hugmesh,${MESH_TAG}" >/dev/null 2>&1 || true
        lapi_advertise cattacker tag:hugmesh tag:superadmin "${DEV_TAG}" >/dev/null
        wait_until 15 headscale_sees cattacker valid_tags "${DEV_TAG}" >/dev/null || true
        VAL="$(tags_of cattacker valid_tags)"
        FRC="$(tags_of cattacker forced_tags)"
        for t in tag:superadmin "${DEV_TAG}"; do
            if contains_line "${VAL}" "${t}"; then
                ok "control reproduces the defect: self-advertised ${t} is VALID under owner [\"hugmesh\"] (forced=[$(echo ${FRC})])"
            else
                bad "control did NOT reproduce the defect for ${t} (valid=[$(echo ${VAL})]) — this suite cannot tell the fix from its absence"
            fi
        done
        if wait_until 20 admits cvictim cattacker; then
            ok "control: the self-advertised node IS an ssh principal of the superadmin rule (the severity: valid self-advertised tags count although the node carries forced tags)"
        else
            bad "control: the self-advertised node is not an ssh principal — the battery does not discriminate"
        fi
        if wait_until 20 has_ssh_rules cattacker; then
            ok "control: an ssh rule now targets the node masquerading as ${DEV_TAG} (it would receive that node's ssh sessions)"
        else
            bad "control: no ssh rule targets the masquerading node — the dst half of the battery does not discriminate"
        fi
    else
        bad "control nodes never reached Running"
    fi
    hs_stop
else
    bad "headscale did not start with the control policy"
fi

echo
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

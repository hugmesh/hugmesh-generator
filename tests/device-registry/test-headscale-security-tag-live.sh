#!/usr/bin/env bash
# test-headscale-security-tag-live.sh — against the headscale the images PIN and stock
# tailscale clients, a node joining with a membership pre-auth key cannot give itself
# a security tag, and the control node can still force one.
#
# WHY. headscale 0.23 gives a node the UNION of its forced tags and every tag it
# advertises whose tagOwners entry names the node's own user; a forced tag does not
# cancel a different advertised one. So the ONLY thing standing between a pre-auth
# key holder and tag:superadmin (the SSH source of the superadmin rule on every node)
# is that no user owns that tag. test-headscale-security-tag-owners.sh checks the
# policy text; this suite checks what the real server does with it.
#
# WHAT IT DOES (throwaway containers on a private --internal docker network, unique
# names, all removed on exit; images resolved from the pins in
# build-x86-host-stage4.sh):
#   A. renders the policy with the REAL gen-headscale-policy.sh render_policy and
#      loads it (policy.mode: file) into headscale; creates the membership user
#      "hugmesh" and mints a reusable key for it (the key is never printed);
#   B. joins three stock clients with that key: member (tag:hugmesh), attacker
#      (tag:hugmesh,tag:superadmin), admin (tag:hugmesh). Asserts the attacker's
#      tag:superadmin is INVALID and the member's tag:hugmesh is valid;
#   C. forces tags exactly as hugmesh-headscale-forcetags does (`headscale nodes tag`):
#      tag:mesh_<id> on every node, tag:superadmin on admin only. Asserts admin
#      carries it, the attacker still does not, and the superadmin SSH rule the
#      member receives in its netmap names the admin's IPs and NOT the attacker's.
#      Also asserts headscale logged no "isn't owned by a TagOwner" map failures;
#   D. a key minted WITH --tags tag:superadmin forces that tag on whoever joins with
#      it — the reason the Studio's minting refuses access tags;
#   E. the baked BOOTSTRAP policy, loaded the same way, also refuses the attacker;
#   F. NEGATIVE CONTROL: the rendered policy with tag:superadmin given back to
#      "hugmesh" — the attacker DOES get the tag. Without this the suite could pass
#      on a server that ignores advertised tags entirely.
#
# EXIT: 0 all passed; 1 an assertion failed; 2 could not run (no docker daemon, an
# image could not be pulled, headscale never came up) — a job FAILURE, never a skip.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RENDERER="${REPO}/specs/usr/sbin/gen-headscale-policy.sh"
TMPL="${REPO}/specs/etc/headscale/policy.hujson.tmpl"
BOOTSTRAP="${REPO}/specs/etc/headscale/policy.bootstrap.hujson"
PIN_SRC="${REPO}/build-x86-host-stage4.sh"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
cannot() { echo "CANNOT RUN: $*"; exit 2; }

for t in docker jq openssl awk; do command -v "$t" >/dev/null 2>&1 || cannot "$t is required"; done
docker info >/dev/null 2>&1 || cannot "no usable docker daemon"

HS_VER="$(sed -n 's/^HEADSCALE_VERSION="\([0-9.]*\)".*/\1/p' "${PIN_SRC}" | head -1)"
TS_VER="$(sed -n 's/^TAILSCALE_VERSION="\([0-9.]*\)".*/\1/p' "${PIN_SRC}" | head -1)"
[ -n "${HS_VER}" ] && [ -n "${TS_VER}" ] || cannot "could not read the HEADSCALE_VERSION / TAILSCALE_VERSION pins from ${PIN_SRC}"
HS_IMAGE="headscale/headscale:${HS_VER}"
TS_IMAGE="tailscale/tailscale:v${TS_VER}"
echo "== pinned: ${HS_IMAGE} + ${TS_IMAGE} =="
for img in "${HS_IMAGE}" "${TS_IMAGE}"; do
    docker image inspect "${img}" >/dev/null 2>&1 || docker pull -q "${img}" >/dev/null 2>&1 || cannot "could not pull ${img}"
done

SFX="hstag-live-$$-${RANDOM}"
NET="${SFX}-net"; HS="${SFX}-hs"
WORK="$(mktemp -d)"
NODES=()
cleanup() {
    local c
    for c in "${HS}" "${NODES[@]}"; do docker rm -fv "${c}" >/dev/null 2>&1; done
    docker network rm "${NET}" >/dev/null 2>&1
    # headscale wrote its db as root inside the container; remove it the same way.
    docker run --rm -v "${WORK}:/w" --entrypoint /bin/sh "${TS_IMAGE}" -c 'rm -rf /w/* /w/.[!.]*' >/dev/null 2>&1
    rm -rf "${WORK}" 2>/dev/null
}
trap cleanup EXIT

# ── A. the policy, rendered by the real renderer ─────────────────────────────
NODE_ENV=/dev/null
# shellcheck source=/dev/null
. "${RENDERER}"
POLICY_TMPL="${TMPL}"; TS_SSH_USER="superadmin"; MESH_ID="live-01"
MESH_TAG="tag:mesh_$(sanitise_tag "${MESH_ID}")"
printf '%s' '{"signed":true,"signature":"x","body":{"meshId":"live-01","generation":1,"operators":[
  {"operator":"alice","machineKeyFp":"fpA","hostname":"a","keyFingerprints":["SHA256:k"],"via":"DEVICE-LICENSE"}]}}' > "${WORK}/export.json"
render_policy "${WORK}/export.json" "${WORK}/rendered.hujson" || cannot "render_policy failed"

mkdir -p "${WORK}/etc" "${WORK}/data" "${WORK}/run"
chmod 0777 "${WORK}/data" "${WORK}/run"
cat > "${WORK}/etc/config.yaml" <<YAML
server_url: http://${HS}:8080
listen_addr: 0.0.0.0:8080
metrics_listen_addr: 127.0.0.1:9090
grpc_listen_addr: 127.0.0.1:50443
grpc_allow_insecure: false
noise:
  private_key_path: /var/lib/headscale/noise_private.key
prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
  allocation: sequential
derp:
  server:
    enabled: true
    region_id: 999
    region_code: "live"
    region_name: "live-embedded"
    stun_listen_addr: "0.0.0.0:3478"
    private_key_path: /var/lib/headscale/derp_server_private.key
  urls: []
  auto_update_enabled: false
  update_frequency: 24h
disable_check_updates: true
ephemeral_node_inactivity_timeout: 30m
database:
  type: sqlite
  sqlite:
    path: /var/lib/headscale/db.sqlite
log:
  level: info
  format: text
dns:
  magic_dns: false
  base_domain: live.internal
policy:
  mode: file
  path: /etc/headscale/policy.hujson
unix_socket: /run/headscale/headscale.sock
unix_socket_permission: "0770"
YAML

hs() { docker exec "${HS}" headscale "$@"; }
use_policy() { cp -f "$1" "${WORK}/etc/policy.hujson"; }
wait_hs() {
    local i
    for i in $(seq 1 45); do hs users list >/dev/null 2>&1 && return 0; sleep 1; done
    return 1
}
nodes_json() { hs nodes list -o json 2>/dev/null; }
node_field() { # <given_name> <jq field>
    nodes_json | jq -c --arg n "$1" ".[] | select(.given_name==\$n) | ($2 // [])" 2>/dev/null
}
has_tag() { # <given_name> <valid_tags|forced_tags|invalid_tags> <tag>
    node_field "$1" ".$2" | jq -e --arg t "$3" 'index($t) != null' >/dev/null 2>&1
}
join() { # <name> <env-file> [advertise-tags]
    local name="$1" envf="$2" tags="${3:-}" args="--login-server=http://${HS}:8080 --hostname=$1"
    [ -n "${tags}" ] && args="${args} --advertise-tags=${tags}"
    NODES+=("${SFX}-${name}")
    docker run -d --name "${SFX}-${name}" --network "${NET}" --env-file "${envf}" \
        -e TS_USERSPACE=true -e TS_STATE_DIR=/tmp/ts -e TS_EXTRA_ARGS="${args}" "${TS_IMAGE}" >/dev/null
}
wait_nodes() { # <count>
    local i n
    for i in $(seq 1 60); do
        n="$(nodes_json | jq 'length' 2>/dev/null)"; [ "${n:-0}" -ge "$1" ] && return 0; sleep 1
    done
    return 1
}
mint_env() { # <out-env-file> [extra preauthkeys args...]
    local out="$1"; shift
    ( umask 077; hs preauthkeys create --user hugmesh --expiration 1h "$@" 2>/dev/null | tail -1 | sed 's/^/TS_AUTHKEY=/' > "${out}" )
    grep -qE '^TS_AUTHKEY=.{16,}$' "${out}"
}
ssh_principals() { # <container>: IPs named by the SSH rules in its netmap
    docker exec "$1" tailscale debug netmap 2>/dev/null \
        | jq -r '[.SSHPolicy.rules[]? | .principals[]? | .nodeIP // empty] | unique[]' 2>/dev/null
}
ip4_of() { node_field "$1" '.ip_addresses' | jq -r '.[0] // empty'; }

use_policy "${WORK}/rendered.hujson"
docker network create --internal "${NET}" >/dev/null || cannot "could not create a private docker network"
docker run -d --name "${HS}" --network "${NET}" -v "${WORK}/etc:/etc/headscale:ro" \
    -v "${WORK}/data:/var/lib/headscale" -v "${WORK}/run:/run/headscale" "${HS_IMAGE}" serve >/dev/null \
    || cannot "headscale container did not start"
wait_hs || { docker logs "${HS}" 2>&1 | tail -5; cannot "headscale never answered (did it reject the rendered policy?)"; }
ok "headscale ${HS_VER} loaded the rendered policy (policy.mode: file)"
hs users create hugmesh >/dev/null 2>&1 || cannot "could not create the membership user"
mint_env "${WORK}/member.env" --reusable || cannot "could not mint a membership pre-auth key"

# ── B. join with the membership key ──────────────────────────────────────────
echo "== B. self-advertised tags under the rendered policy =="
join member   "${WORK}/member.env" "tag:hugmesh"
join attacker "${WORK}/member.env" "tag:hugmesh,tag:superadmin"
join admin    "${WORK}/member.env" "tag:hugmesh"
wait_nodes 3 || { docker logs "${SFX}-attacker" 2>&1 | tail -3; cannot "the three clients never registered"; }
has_tag member valid_tags tag:hugmesh \
    && ok "member's self-advertised tag:hugmesh is valid (membership still works)" \
    || bad "member's tag:hugmesh is not valid — the membership user no longer owns it"
if has_tag attacker valid_tags tag:superadmin; then
    bad "attacker self-advertised tag:superadmin and headscale GRANTED it"
else ok "attacker's self-advertised tag:superadmin is not granted"; fi
has_tag attacker invalid_tags tag:superadmin \
    && ok "headscale lists the attacker's tag:superadmin as INVALID" \
    || bad "the attacker's tag:superadmin is not listed invalid (got $(node_field attacker .invalid_tags))"

# ── C. force tags as hugmesh-headscale-forcetags does ────────────────────────
echo "== C. server-forced tags =="
idof() { nodes_json | jq -r --arg n "$1" '.[] | select(.given_name==$n) | .id'; }
hs nodes tag -i "$(idof member)"   -t "${MESH_TAG}" >/dev/null 2>&1 || bad "could not force ${MESH_TAG} on member"
hs nodes tag -i "$(idof attacker)" -t "${MESH_TAG}" >/dev/null 2>&1 || bad "could not force ${MESH_TAG} on attacker"
hs nodes tag -i "$(idof admin)"    -t "${MESH_TAG},tag:superadmin" >/dev/null 2>&1 || bad "could not force tag:superadmin on admin"
has_tag admin forced_tags tag:superadmin \
    && ok "forcing assigns tag:superadmin although no user owns it (forced tags bypass tagOwners)" \
    || bad "admin does not carry the forced tag:superadmin"
if has_tag attacker valid_tags tag:superadmin || has_tag attacker forced_tags tag:superadmin; then
    bad "after the force pass the attacker carries tag:superadmin"
else ok "after the force pass the attacker still lacks tag:superadmin"; fi
ADMIN_IP="$(ip4_of admin)"; ATT_IP="$(ip4_of attacker)"
princ=""
for i in $(seq 1 30); do
    princ="$(ssh_principals "${SFX}-member")"
    grep -Fxq -- "${ADMIN_IP}" <<< "${princ}" && break
    sleep 1
done
if [ -n "${ADMIN_IP}" ] && grep -Fxq -- "${ADMIN_IP}" <<< "${princ}"; then
    ok "the member's netmap SSH rules name the force-tagged admin (${ADMIN_IP})"
else bad "the member's netmap SSH rules never named the admin (${ADMIN_IP}); got: $(printf '%s' "${princ}" | tr '\n' ' ')"; fi
if [ -n "${ATT_IP}" ] && grep -Fxq -- "${ATT_IP}" <<< "${princ}"; then
    bad "the member's netmap SSH rules name the ATTACKER (${ATT_IP}) — SSH as the privileged user"
else ok "the member's netmap SSH rules do not name the attacker (${ATT_IP})"; fi
# Captured to a file first: `docker logs | grep -q` under pipefail reports a FOUND
# match as a miss whenever grep exits before docker logs finishes writing (SIGPIPE).
docker logs "${HS}" > "${WORK}/hs.log" 2>&1
if grep -q "isn't owned by a TagOwner" "${WORK}/hs.log"; then
    bad "headscale failed map updates over an undeclared tag ($(grep -m1 -o "tag:[a-z0-9_-]* isn't owned[^\"]*" "${WORK}/hs.log"))"
else ok "no map update failed over an undeclared tag (tag:mesh_<id> is declared)"; fi

# ── D. a key's own tags become forced tags ───────────────────────────────────
echo "== D. tags carried by a pre-auth key =="
if mint_env "${WORK}/tagged.env" --tags tag:superadmin; then
    join keytagged "${WORK}/tagged.env"
    wait_nodes 4 || cannot "the key-tagged client never registered"
    has_tag keytagged forced_tags tag:superadmin \
        && ok "a key minted with --tags tag:superadmin forces it on the joiner (why issuers must refuse access tags)" \
        || bad "a key's --tags did not become forced tags (got $(node_field keytagged .forced_tags)) — re-check why mint_preauth_key refuses them"
else bad "could not mint a key with --tags"; fi

# ── E/F. other policies, same server, same nodes ─────────────────────────────
reload() { # <policy file>: file mode reads the policy at startup only
    use_policy "$1"; docker restart "${HS}" >/dev/null 2>&1; wait_hs
}
echo "== E. the baked bootstrap policy =="
sed 's/@@TS_SSH_USER@@/superadmin/g' "${BOOTSTRAP}" > "${WORK}/bootstrap.hujson"
if reload "${WORK}/bootstrap.hujson"; then
    ok "headscale loaded the bootstrap policy"
    if has_tag attacker valid_tags tag:superadmin; then bad "bootstrap policy GRANTS the attacker's self-advertised tag:superadmin"
    else ok "bootstrap policy refuses the attacker's tag:superadmin"; fi
else bad "headscale did not come back on the bootstrap policy"; fi

echo "== F. negative control: tag:superadmin owned by the membership user =="
sed -e 's#//.*$##' "${WORK}/rendered.hujson" | jq '.tagOwners["tag:superadmin"] = ["hugmesh"]' > "${WORK}/owned.hujson"
if reload "${WORK}/owned.hujson"; then
    has_tag attacker valid_tags tag:superadmin \
        && ok "with an owner, the same self-advertised tag:superadmin IS granted — the check above can see the hole" \
        || bad "negative control: headscale did not grant an OWNED advertised tag — this suite cannot tell fixed from broken"
else bad "headscale did not come back on the negative-control policy"; fi

echo
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

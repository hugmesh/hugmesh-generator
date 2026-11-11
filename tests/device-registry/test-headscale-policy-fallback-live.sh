#!/usr/bin/env bash
# test-headscale-policy-fallback-live.sh — against the headscale the images PIN and
# stock tailscale clients: the deny-all policy keys-provision falls back to really
# starts and really grants nothing, and the two policy spellings its owner check used
# to miss really do hand out tag:superadmin.
#
# WHY. keys-provision's headscale step (provision_headscale) now FAILS CLOSED: a policy
# it cannot narrow, one it cannot read, and no policy at all are replaced by the static
# text of headscale_deny_all_policy. test-headscale-policy-fallback.sh proves offline
# that every branch stages it; this suite proves the text does what it says on the
# server that will read it:
#   A. headscale starts on it (policy.mode: file). headscale 0.23 refuses an "empty
#      policy" and does not start at all, which is why the text carries one empty group;
#   B. two clients joining with a membership key and advertising tag:hugmesh and
#      tag:superadmin get NO valid tag, and their packet filter is EMPTY (no traffic);
#   C. CONTROL: a policy that grants node-to-node traffic (tag:hugmesh owned, one
#      tag:hugmesh -> tag:hugmesh:* rule), same server: node a's tag:hugmesh becomes
#      valid and a client joining now gets a non-empty packet filter — so B can see a
#      grant when there is one (a fresh join, because a client that was connected
#      before the restart can take minutes to fetch its next map on a busy host). (The baked
#      bootstrap cannot serve here: its only rule targets the pod/service CIDRs, and
#      headscale sends a node only the rules whose destination is that node.)
#   D. a policy whose owners sit under "TagOwners", and one whose owners sit in the
#      first of two "tagOwners" members, each make the self-advertised tag:superadmin
#      VALID — and keys-provision's headscale_policy_owned_security_tags flags both
#      (the old `.tagOwners` jq read called both clean);
#   E. CONTROL: the same deny-all text with its group removed is refused as an empty
#      policy and headscale does not start.
# Throwaway containers on a private --internal docker network, unique names, all removed
# on exit; images from the pins in build-x86-host-stage4.sh; no key is printed.
#
# EXIT: 0 all passed; 1 an assertion failed; 2 could not run (no docker daemon, an image
# could not be pulled, headscale never came up) — a job FAILURE, never a skip.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROVISION="${HS_FALLBACK_PROVISION:-${REPO}/specs/etc/keys-provision/provision.sh}"   # mutation battery seam
PIN_SRC="${REPO}/build-x86-host-stage4.sh"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
cannot() { echo "CANNOT RUN: $*"; exit 2; }

for t in docker jq awk sed; do command -v "$t" >/dev/null 2>&1 || cannot "$t is required"; done
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

SFX="hsfb-live-$$-${RANDOM}"
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

# ── the deny-all text and the owner check, cut out of the real provision.sh ──
extract() { awk -v fn="$1" '$0 ~ "^" fn "\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "${PROVISION}"; }
DENY_SRC="$(extract headscale_deny_all_policy)"
GUARD_SRC="$(extract headscale_policy_owned_security_tags)"
[ -n "${DENY_SRC}" ] || cannot "headscale_deny_all_policy() not found in ${PROVISION}"
[ -n "${GUARD_SRC}" ] || cannot "headscale_policy_owned_security_tags() not found in ${PROVISION}"
eval "${DENY_SRC}"; eval "${GUARD_SRC}"
headscale_deny_all_policy > "${WORK}/denyall.hujson" || cannot "headscale_deny_all_policy failed"
# Control E's policy. A deny-all text that already lacks its group is not a reason to
# stop: A below then shows what headscale does with it.
sed -e 's#//.*$##' "${WORK}/denyall.hujson" | jq 'del(.groups)' > "${WORK}/denyall-nogroup.hujson" 2>/dev/null \
    || cannot "could not build the group-less control policy (the deny-all text does not parse)"
cat > "${WORK}/grant.hujson" <<'EOF'
{
  "tagOwners": { "tag:hugmesh": ["hugmesh"], "tag:superadmin": [] },
  "acls": [ { "action": "accept", "src": ["tag:hugmesh"], "dst": ["tag:hugmesh:*"] } ]
}
EOF
cat > "${WORK}/case.hujson" <<'EOF'
{
  "TagOwners": { "tag:hugmesh": ["hugmesh"], "tag:superadmin": ["hugmesh"] },
  "acls": [ { "action": "accept", "src": ["tag:hugmesh"], "dst": ["10.244.0.0/16:*"] } ]
}
EOF
cat > "${WORK}/dup.hujson" <<'EOF'
{
  "tagOwners": { "tag:hugmesh": ["hugmesh"], "tag:superadmin": ["hugmesh"] },
  "acls": [ { "action": "accept", "src": ["tag:hugmesh"], "dst": ["10.244.0.0/16:*"] } ],
  "tagOwners": { "tag:hugmesh": ["hugmesh"] }
}
EOF

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
    for _ in $(seq 1 45); do hs users list >/dev/null 2>&1 && return 0; sleep 1; done
    return 1
}
nodes_json() { # retried: one slow `docker exec` on a busy host must not read as "no nodes"
    local out
    for _ in 1 2 3 4 5; do
        out="$(hs nodes list -o json 2>/dev/null)"
        printf '%s' "${out}" | jq -e 'type == "array"' >/dev/null 2>&1 && { printf '%s' "${out}"; return 0; }
        sleep 1
    done
    return 1
}
node_field() { # <given_name> <jq field>
    nodes_json | jq -c --arg n "$1" ".[] | select(.given_name==\$n) | ($2 // [])" 2>/dev/null
}
has_tag() { # <given_name> <valid_tags|invalid_tags> <tag>
    node_field "$1" ".$2" | jq -e --arg t "$3" 'index($t) != null' >/dev/null 2>&1
}
join() { # <name> <env-file> <advertise-tags>
    NODES+=("${SFX}-$1")
    docker run -d --name "${SFX}-$1" --network "${NET}" --env-file "$2" \
        -e TS_USERSPACE=true -e TS_STATE_DIR=/tmp/ts \
        -e TS_EXTRA_ARGS="--login-server=http://${HS}:8080 --hostname=$1 --advertise-tags=$3" "${TS_IMAGE}" >/dev/null
}
wait_nodes() { # <count>
    local n
    for _ in $(seq 1 60); do
        n="$(nodes_json | jq 'length' 2>/dev/null)"; [ "${n:-0}" -ge "$1" ] && return 0; sleep 1
    done
    return 1
}
# packet filter rule count in a client's current netmap (empty = nothing reaches it)
filter_len() { docker exec "$1" tailscale debug netmap 2>/dev/null | jq '(.PacketFilter // []) | length' 2>/dev/null; }
reload() { # <policy file>: file mode reads the policy at startup only
    use_policy "$1"; docker restart -t 2 "${HS}" >/dev/null 2>&1; wait_hs
}

# ── A. headscale starts on the deny-all policy ───────────────────────────────
echo "== A. the deny-all policy loads =="
use_policy "${WORK}/denyall.hujson"
docker network create --internal "${NET}" >/dev/null || cannot "could not create a private docker network"
docker run -d --name "${HS}" --network "${NET}" -v "${WORK}/etc:/etc/headscale:ro" \
    -v "${WORK}/data:/var/lib/headscale" -v "${WORK}/run:/run/headscale" "${HS_IMAGE}" serve >/dev/null \
    || cannot "headscale container did not start"
if wait_hs; then ok "headscale ${HS_VER} starts on keys-provision's deny-all policy (policy.mode: file)"
else docker logs "${HS}" > "${WORK}/hs.log" 2>&1; tail -3 "${WORK}/hs.log"; bad "headscale ${HS_VER} did NOT start on the deny-all policy — the fallback would take the control plane down"
    echo; echo "== RESULT: ${P} passed, ${F} failed =="; exit 1; fi
# Retried: right after startup a busy host can refuse the first CLI call or two.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    hs users list -o json 2>/dev/null | jq -e 'any(.[]; .name == "hugmesh")' >/dev/null 2>&1 && break
    hs users create hugmesh >/dev/null 2>&1 || sleep 2
done
hs users list -o json 2>/dev/null | jq -e 'any(.[]; .name == "hugmesh")' >/dev/null 2>&1 || cannot "could not create the membership user"
for _ in 1 2 3 4 5; do
    ( umask 077; hs preauthkeys create --user hugmesh --reusable --expiration 1h 2>/dev/null | tail -1 | sed 's/^/TS_AUTHKEY=/' > "${WORK}/member.env" )
    grep -qE '^TS_AUTHKEY=.{16,}$' "${WORK}/member.env" && break
    sleep 2
done
grep -qE '^TS_AUTHKEY=.{16,}$' "${WORK}/member.env" || cannot "could not mint a membership pre-auth key"

# ── B. it grants nothing ─────────────────────────────────────────────────────
echo "== B. nodes under the deny-all policy =="
join a "${WORK}/member.env" "tag:hugmesh,tag:superadmin"
join b "${WORK}/member.env" "tag:hugmesh,tag:superadmin"
wait_nodes 2 || cannot "the two clients never registered"
for n in a b; do
    if has_tag "${n}" valid_tags tag:superadmin || has_tag "${n}" valid_tags tag:hugmesh; then
        bad "node ${n}: a self-advertised tag is VALID under the deny-all policy ($(node_field "${n}" .valid_tags))"
    else ok "node ${n}: no self-advertised tag is valid (tag:superadmin and tag:hugmesh refused)"; fi
done
has_tag a invalid_tags tag:superadmin && ok "headscale lists node a's tag:superadmin as INVALID" \
    || bad "node a's tag:superadmin is not listed invalid (got $(node_field a .invalid_tags))"
# Read the filter only from a map that already lists node b as a peer, so an early,
# partial map cannot pass for an empty filter.
fl=""
for _ in $(seq 1 90); do
    docker exec "${SFX}-a" tailscale debug netmap 2>/dev/null | jq -e '(.Peers // []) | length >= 1' >/dev/null 2>&1 \
        && { fl="$(filter_len "${SFX}-a")"; break; }
    sleep 1
done
[ "${fl}" = 0 ] && ok "node a's packet filter is EMPTY although node b is its peer (no node reaches it)" \
    || bad "node a's packet filter is not empty under the deny-all policy (rules: ${fl:-no map listing node b})"

# ── C. CONTROL: a policy that grants something shows up as a grant ──────────
echo "== C. control: a policy that grants node-to-node traffic =="
if reload "${WORK}/grant.hujson"; then
    has_tag a valid_tags tag:hugmesh && ok "control: under a granting policy node a's tag:hugmesh IS valid" \
        || bad "control: tag:hugmesh not valid under a granting policy — B's tag check cannot see a grant"
    join c "${WORK}/member.env" "tag:hugmesh"
    wait_nodes 3 || cannot "the control client never registered"
    fl=""
    for _ in $(seq 1 90); do fl="$(filter_len "${SFX}-c")"; [ "${fl:-0}" -gt 0 ] 2>/dev/null && break; sleep 1; done
    [ "${fl:-0}" -gt 0 ] 2>/dev/null && ok "control: under a granting policy a joining node's packet filter has ${fl} rule(s)" \
        || bad "control: a joining node's packet filter stayed empty under a granting policy — B's filter check cannot see a grant"
else bad "headscale did not come back on the granting control policy"; fi

# ── D. the spellings the old owner check missed ─────────────────────────────
echo "== D. owners headscale reads but a plain .tagOwners query does not =="
for kind in case dup; do
    if reload "${WORK}/${kind}.hujson"; then
        has_tag a valid_tags tag:superadmin \
            && ok "${kind}: headscale GRANTS node a's self-advertised tag:superadmin under this spelling" \
            || bad "${kind}: headscale did not grant tag:superadmin — this fixture does not model a real hole"
    else bad "${kind}: headscale did not come back on the fixture policy"; fi
    old="$(sed -e 's#//.*$##' "${WORK}/${kind}.hujson" | jq -r '(.tagOwners // {}) | to_entries[] | select(.key | test("^tag:(superadmin$|mesh_|dev_|dom_)")) | select((.value // []) | length > 0) | .key' 2>/dev/null)"
    [ -z "${old}" ] && ok "${kind}: the old .tagOwners read calls it clean (the miss this fixes)" \
        || bad "${kind}: the old .tagOwners read already flags it ('${old}') — fixture does not model the miss"
    out="$(headscale_policy_owned_security_tags "${WORK}/${kind}.hujson")" && [ "${out}" = "tag:superadmin" ] \
        && ok "${kind}: keys-provision's owner check flags tag:superadmin" \
        || bad "${kind}: keys-provision's owner check misses it (got '${out:-<unreadable or clean>}')"
done

# ── E. CONTROL: why the deny-all text carries a group ───────────────────────
echo "== E. control: the deny-all text without its group =="
use_policy "${WORK}/denyall-nogroup.hujson"
docker restart -t 2 "${HS}" >/dev/null 2>&1
up=0
for _ in $(seq 1 15); do hs users list >/dev/null 2>&1 && { up=1; break; }; sleep 1; done
# Captured to a file first: `docker logs | grep -q` under pipefail can report a found
# match as a miss (SIGPIPE).
docker logs "${HS}" > "${WORK}/hs.log" 2>&1
if [ "${up}" = 0 ] && grep -q 'empty policy' "${WORK}/hs.log"; then
    ok "control: without the group headscale refuses it as an 'empty policy' and does not start"
else bad "control: the group-less text was not refused as an empty policy (up=${up}) — the group may no longer be needed, re-check"; fi

echo
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

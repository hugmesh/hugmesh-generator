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
#   F. the CONFIG GATE (headscale_effective_policy_path) against the binary, as a
#      differential over a battery of config.yaml spellings: for each, what
#      `headscale serve` really loads (its debug log), what `headscale dumpConfig`
#      reports, and the gate's verdict. The gate may accept a config only when serve
#      loads /etc/headscale/policy.hujson; dumpConfig must agree with serve on every
#      case; and the rows of fixtures/headscale-config-policy-variants.tsv (which the
#      offline suite replays) must be what dumpConfig really says;
#   G. end to end on the real provision_headscale with the binary answering
#      dumpConfig: a KEYS-stick config.yaml that redirects the policy to a stick
#      acl.hujson owning tag:superadmin, and one with no policy section, are refused
#      (headscale not started, health marked). CONTROLS: with the gate switched off
#      the same sticks really start headscale on the stick's acl.hujson (a node's
#      self-advertised tag:superadmin is VALID) and on no policy (allow-all), while
#      the keys-template config passes the gate and its node's tag:superadmin is not
#      valid. A refused sandbox no longer starts at all (its config is set aside, so a
#      later `rc-service headscale restart` cannot bring it up). And the CP DNS trap: a
#      stick config whose policy: block sits between publish_cp_dns_record's marker
#      lines passes the first gate, comes out of that rewrite with no policy.path, and
#      is refused by the second gate before the restart (CONTROL: without it, serve on
#      the rewritten config loads no policy).
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
BNODES=()
cleanup() {
    local c
    for c in "${HS}" "${NODES[@]}" "${BNODES[@]}"; do docker rm -fv "${c}" >/dev/null 2>&1; done
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

# ── F. the CONFIG GATE against the binary: serve vs dumpConfig vs the gate ──
echo "== F. config.yaml spellings: what serve loads, what dumpConfig says, the gate's verdict =="
VARIANTS="${REPO}/tests/device-registry/fixtures/headscale-config-policy-variants.tsv"
[ -f "${VARIANTS}" ] || cannot "${VARIANTS} not found"
EFF_SRC="$(extract headscale_effective_policy_path)"
[ -n "${EFF_SRC}" ] || cannot "headscale_effective_policy_path() not found in ${PROVISION}"
# The gate's /etc/headscale is ${GATE_DIR} here (one case directory at a time).
eval "$(printf '%s\n' "${EFF_SRC}" | sed 's#/etc/headscale#${GATE_DIR}#g')"
timeout() { shift; "$@"; }
# `headscale` for the gate: the pinned binary with the case directory as its /etc/headscale.
# Its dump names container paths; they are mapped back onto the case directory, which IS
# that /etc/headscale.
headscale() {
    [ "$1" = dumpConfig ] || return 0
    docker run --rm --network none -v "${GATE_DIR}:/etc/headscale" "${HS_IMAGE}" "$@" >/dev/null 2>&1
    [ ! -f "${GATE_DIR}/config.dump.yaml" ] \
        || sed -i "s#^    path: /etc/headscale/#    path: ${GATE_DIR}/#" "${GATE_DIR}/config.dump.yaml"
    return 0
}
cat > "${WORK}/owned-acl.hujson" <<'EOF'
{
  // a KEYS-stick acl.hujson that owns the security tag (the redirect target)
  "groups": { "group:stick": [] },
  "tagOwners": { "tag:hugmesh": ["hugmesh"], "tag:superadmin": ["hugmesh"] },
  "acls": [ { "action": "accept", "src": ["tag:hugmesh"], "dst": ["10.244.0.0/16:*"] } ]
}
EOF
# The suite's own config with debug logging (serve then logs the policy file it loads).
sed 's/^  level: info$/  level: debug/' "${WORK}/etc/config.yaml" > "${WORK}/base-debug.yaml"
grep -q '^  level: debug$' "${WORK}/base-debug.yaml" || cannot "could not switch the battery config to debug logging"
[ "$(grep -c -x -e 'policy:' -e '  mode: file' -e '  path: /etc/headscale/policy.hujson' "${WORK}/base-debug.yaml")" = 3 ] \
    || cannot "the battery config does not carry the canonical policy block"
base_nopol() { sed '/^policy:$/,/^  path: /d' "${WORK}/base-debug.yaml"; }
BATTERY="${WORK}/battery"; mkdir -p "${BATTERY}"
CASES=()
mkcase() { # <name> [extra file name] ; config.yaml on stdin
    local d="${BATTERY}/$1"
    mkdir -p "${d}"; chmod 0777 "${d}"
    cat > "${d}/config.yaml"
    cp "${WORK}/denyall.hujson" "${d}/policy.hujson"
    cp "${WORK}/owned-acl.hujson" "${d}/acl.hujson"
    CASES+=("$1")
}
# name -> expected gate verdict (accept|refuse) and, for the TSV rows, the dump they record.
# (mkcase reads stdin through a redirect, never as the last stage of a pipeline: that
# runs it in a subshell and loses the case.)
declare -A EXPECT TSV_DUMP SERVE
while IFS=$'\t' read -r vname vsed vmode vpath; do
    case "${vname}" in ''|\#*) continue ;; esac
    mkcase "tsv-${vname}" < <(sed -e "${vsed}" "${WORK}/base-debug.yaml")
    TSV_DUMP["tsv-${vname}"]="${vmode} ${vpath}"
    if [ "${vname}" = canonical ]; then EXPECT["tsv-${vname}"]=accept; else EXPECT["tsv-${vname}"]=refuse; fi
done < "${VARIANTS}"
[ "${#TSV_DUMP[@]}" -ge 5 ] || cannot "only ${#TSV_DUMP[@]} rows read from ${VARIANTS}"
ACL=/etc/headscale/acl.hujson; CANON=/etc/headscale/policy.hujson
mkcase upper-key < <(base_nopol; printf 'Policy:\n  mode: file\n  path: %s\n' "${ACL}");              EXPECT[upper-key]=refuse
mkcase dotted-override < <(cat "${WORK}/base-debug.yaml"; printf 'POLICY.PATH: %s\n' "${ACL}");    EXPECT[dotted-override]=refuse
mkcase merge-key < <(base_nopol; printf 'xanchor: &a\n  path: %s\npolicy:\n  <<: *a\n  mode: file\n' "${ACL}"); EXPECT[merge-key]=refuse
mkcase ls-break < <(base_nopol; printf 'zz: 1\342\200\250policy:\n  mode: file\n  path: %s\n' "${ACL}");  EXPECT[ls-break]=refuse
mkcase nel-break < <(base_nopol; printf 'zz: 1\302\205policy:\n  mode: file\n  path: %s\n' "${ACL}");   EXPECT[nel-break]=refuse
mkcase cr-break < <(base_nopol; printf 'zz: 1\rpolicy:\r  mode: file\r  path: %s\n' "${ACL}");        EXPECT[cr-break]=refuse
mkcase bom-first < <(printf '\357\273\277policy:\n  mode: file\n  path: %s\n' "${ACL}"; base_nopol);   EXPECT[bom-first]=refuse
mkcase flow-map < <(base_nopol; printf 'policy: {mode: file, path: %s}\n' "${ACL}");                EXPECT[flow-map]=refuse
# A canonical-looking block that a multi-line quoted scalar swallows: no policy at all.
mkcase quote-swallow < <(base_nopol; printf 'zz: "abc\npolicy:\n  mode: file\n  path: %s\n"\n' "${CANON}"); EXPECT[quote-swallow]=refuse
# A canonical block in a SECOND YAML document, which headscale never reads.
mkcase second-doc < <(base_nopol; printf -- '---\npolicy:\n  mode: file\n  path: %s\n' "${CANON}");  EXPECT[second-doc]=refuse
# config.json beside a canonical config.yaml: headscale reads the json.
mkcase json-first < "${WORK}/base-debug.yaml"; EXPECT[json-first]=refuse
cat > "${BATTERY}/json-first/config.json" <<JSON
{"server_url": "http://${HS}:8080", "listen_addr": "0.0.0.0:8080", "metrics_listen_addr": "127.0.0.1:9090",
 "grpc_listen_addr": "127.0.0.1:50443", "noise": {"private_key_path": "/var/lib/headscale/noise_private.key"},
 "prefixes": {"v4": "100.64.0.0/10", "v6": "fd7a:115c:a1e0::/48", "allocation": "sequential"},
 "derp": {"server": {"enabled": true, "region_id": 999, "region_code": "live", "region_name": "live-embedded",
   "stun_listen_addr": "0.0.0.0:3478", "private_key_path": "/var/lib/headscale/derp_server_private.key"},
   "urls": [], "auto_update_enabled": false},
 "disable_check_updates": true, "database": {"type": "sqlite", "sqlite": {"path": "/var/lib/headscale/db.sqlite"}},
 "log": {"level": "debug", "format": "text"}, "dns": {"magic_dns": false, "base_domain": "live.internal"},
 "policy": {"mode": "file", "path": "${ACL}"}, "unix_socket": "/run/headscale/headscale.sock"}
JSON
# Benign spellings of the canonical policy: the gate must not refuse these.
mkcase benign-quoted < <(base_nopol; printf "policy: # the checked file\n    mode: 'file'\n    path: \"%s\"   # keys-provision\n" "${CANON}"); EXPECT[benign-quoted]=accept
mkcase benign-dotted < <(base_nopol; printf 'policy.mode: file\npolicy.path: %s\n' "${CANON}");     EXPECT[benign-dotted]=accept

# serve_loads <case dir>: PATH=<file> (the policy file serve loaded) | NONE (it started
# with no policy file: allow-all in file mode, the database in database mode) | FATAL.
BN=0
serve_loads() {
    local name data st="" p
    BN=$((BN + 1)); name="${SFX}-b${BN}"; data="${WORK}/bdata.${BN}"
    mkdir -p "${data}" "${data}.run"; chmod 0777 "${data}" "${data}.run"
    BNODES+=("${name}")
    docker run -d --name "${name}" --network none -v "$1:/etc/headscale:ro" -v "${data}:/var/lib/headscale" \
        -v "${data}.run:/run/headscale" "${HS_IMAGE}" serve >/dev/null 2>&1 || { echo FATAL; return; }
    # Up to 120 s (a loaded CI runner was measured 7x slower); the loop leaves as soon as
    # serve has read its policy, started serving, or exited.
    for _ in $(seq 1 240); do
        docker logs "${name}" > "${data}.log" 2>&1
        grep -q -e 'Loading ACL policy from path' -e 'listening and serving HTTP' "${data}.log" && break
        [ "$(docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null)" = true ] || { st=exited; break; }
        sleep 0.5
    done
    docker logs "${name}" > "${data}.log" 2>&1
    docker rm -fv "${name}" >/dev/null 2>&1
    p="$(sed -n 's/.*Loading ACL policy from path.* path=//p' "${data}.log" | head -1)"
    case "${p}" in \"*) p="${p#\"}"; p="${p%%\"*}" ;; *) p="${p%% *}" ;; esac
    if [ -n "${p}" ]; then echo "PATH=${p}"
    elif grep -q 'listening and serving HTTP' "${data}.log"; then echo NONE
    else echo "FATAL$( [ -n "${st}" ] && echo " (exited)")"; fi
}
# dump_says <case dir>: "<mode> <path|->" from the binary's own dumpConfig, the path
# resolved the way serve resolves it (relative to the config directory).
dump_says() {
    local d="$1" m p
    rm -f "${d}/config.dump.yaml" 2>/dev/null
    docker run --rm --network none -v "${d}:/etc/headscale" "${HS_IMAGE}" dumpConfig -o json >/dev/null 2>&1
    [ -s "${d}/config.dump.yaml" ] || { echo "NO-DUMP"; return; }
    m="$(awk '/^policy:$/{b=1;next} /^[^ ]/{b=0} b&&/^    mode: /{print substr($0,11)}' "${d}/config.dump.yaml")"
    p="$(awk '/^policy:$/{b=1;next} /^[^ ]/{b=0} b&&/^    path: /{print substr($0,11)}' "${d}/config.dump.yaml")"
    rm -f "${d}/config.dump.yaml" 2>/dev/null
    case "${p}" in \"*\") p="${p#\"}"; p="${p%\"}" ;; esac
    echo "${m:-?} ${p:--}"
}
for c in "${CASES[@]}"; do
    d="${BATTERY}/${c}"
    S="$(serve_loads "${d}")"; SERVE["${c}"]="${S}"
    D="$(dump_says "${d}")"
    GATE_DIR="${d}"; G="$(headscale_effective_policy_path)"; grc=$?
    if [ "${grc}" = 0 ] && [ "${G}" = "${d}/policy.hujson" ]; then V=accept; else V=refuse; fi
    echo "   ${c}: serve=${S} | dumpConfig=${D} | gate=${V}$( [ "${V}" = refuse ] && printf ' (%s)' "$(printf '%s' "${G}" | head -c 110)")"
    # 1. soundness: an accepted config is one serve really loads the checked file from
    if [ "${V}" = accept ]; then
        [ "${S}" = "PATH=${CANON}" ] && ok "${c}: the gate accepts it and serve loads ${CANON}" \
            || bad "${c}: the gate ACCEPTS it but serve loads ${S}"
    fi
    # 2. the gate's verdict is the expected one
    [ "${V}" = "${EXPECT[${c}]}" ] && ok "${c}: the gate's verdict is ${V}" || bad "${c}: the gate's verdict is ${V}, expected ${EXPECT[${c}]}"
    # 3. dumpConfig is a faithful oracle: it names what serve loads
    dm="${D%% *}"; dp="${D#* }"
    case "${dp}" in -|/*) ;; *) dp="/etc/headscale/${dp}" ;; esac
    if [ "${S}" = "PATH=${dp}" ] && [ "${dm}" = file ]; then ok "${c}: dumpConfig names the file serve loads (${dp})"
    elif [ "${S}" = NONE ] && { [ "${dp}" = - ] || [ "${dm}" = database ]; }; then ok "${c}: dumpConfig and serve agree: no policy file (${D})"
    else bad "${c}: dumpConfig says '${D}' but serve loads ${S}"; fi
    # 4. the offline suite replays the TSV rows: they must be what the binary says
    if [ -n "${TSV_DUMP[${c}]:-}" ]; then
        [ "${D}" = "${TSV_DUMP[${c}]}" ] && ok "${c}: dumpConfig matches the variants table ('${D}')" \
            || bad "${c}: dumpConfig says '${D}', the variants table (replayed offline) says '${TSV_DUMP[${c}]}'"
    fi
    [ ! -e "${d}/config.dump.yaml" ] || bad "${c}: the gate left its configuration dump behind"
done
# The cases the gate exists for are real: serve loads the stick's acl.hujson, or nothing.
for c in tsv-redirect upper-key dotted-override merge-key ls-break nel-break cr-break bom-first flow-map json-first; do
    [ "${SERVE[${c}]}" = "PATH=${ACL}" ] && ok "${c}: real — serve loads the stick's ${ACL}" \
        || bad "${c}: serve does not load ${ACL} (${SERVE[${c}]}) — this case does not model a redirect"
done
for c in tsv-nopolicy tsv-database quote-swallow second-doc; do
    [ "${SERVE[${c}]}" = NONE ] && ok "${c}: real — serve starts with no policy file" \
        || bad "${c}: serve does not start policy-less (${SERVE[${c}]}) — this case does not model allow-all"
done

# ── G. end to end: the real provision_headscale, the binary answering dumpConfig ──
echo "== G. provision_headscale end to end: stick configs against the pinned binary =="
E2E_SRC="${WORK}/provision-extract.sh"; : > "${E2E_SRC}"
for fn in headscale_policy_owned_security_tags headscale_deny_all_policy headscale_stage_deny_all_policy \
          headscale_policy_unprotected headscale_effective_policy_path headscale_config_gate \
          headscale_refuse_config provision_headscale publish_cp_dns_record; do
    body="$(extract "${fn}")"; [ -n "${body}" ] || cannot "${fn}() not found in ${PROVISION}"
    printf '%s\n\n' "${body}" >> "${E2E_SRC}"
done
sed -i -E 's#(^|[^A-Za-z0-9_}])/(etc/headscale|var/lib/headscale|run/headscale|var/log/headscale|run/hugmesh)#\1${HSB}/\2#g' "${E2E_SRC}"
leftover="$(sed 's#/dev/null##g' "${E2E_SRC}" | grep -nE '(^|[^A-Za-z0-9_}.])/(etc|var|run|usr|opt|root|home|boot|srv|dev|sys|proc)/' \
    | grep -vE '^[0-9]+:[[:space:]]*(#|//)')"
[ -z "${leftover}" ] || cannot "provision_headscale names a path this suite does not sandbox: ${leftover}"
# publish_cp_dns_record's python edits config.yaml through a literal the sandbox variable
# does not reach; point it at the sandbox through the environment.
[ "$(grep -c 'p = "${HSB}/etc/headscale/config.yaml"' "${E2E_SRC}")" = 1 ] || cannot "publish_cp_dns_record's config.yaml literal not found once"
sed -i 's#p = "${HSB}/etc/headscale/config.yaml"#p = __import__("os").environ["HSB"] + "/etc/headscale/config.yaml"#' "${E2E_SRC}"
printf '{"headscale":{"enabled":true}}\n' > "${WORK}/e2e-provision.json"
STICK_TEMPLATE="${WORK}/base-debug.yaml"
sed -e "$(awk -F'\t' '$1=="redirect"{print $2}' "${VARIANTS}")" "${STICK_TEMPLATE}" > "${WORK}/stick-redirect.yaml"
sed -e "$(awk -F'\t' '$1=="nopolicy"{print $2}' "${VARIANTS}")" "${STICK_TEMPLATE}" > "${WORK}/stick-nopolicy.yaml"
cmp -s "${STICK_TEMPLATE}" "${WORK}/stick-redirect.yaml" && cannot "the redirect variant did not change the stick config"
cmp -s "${STICK_TEMPLATE}" "${WORK}/stick-nopolicy.yaml" && cannot "the nopolicy variant did not change the stick config"
NOGATE='headscale_effective_policy_path() { echo "${HSB}/etc/headscale/policy.hujson"; }'
e2e_run() { # <name> <stick config.yaml> [extra shell] -> SB
    local sb="${WORK}/e2e-$1"
    mkdir -p "${sb}/keys/headscale" "${sb}/etc/headscale" "${sb}/var/lib/headscale" "${sb}/run/headscale"
    chmod 0777 "${sb}/etc/headscale" "${sb}/var/lib/headscale" "${sb}/run/headscale"
    cp "${WORK}/etc/config.yaml" "${sb}/etc/headscale/config.yaml"                     # the image's baked config
    cp "${REPO}/specs/etc/headscale/policy.bootstrap.hujson" "${sb}/etc/headscale/policy.bootstrap.hujson"
    cp "$2" "${sb}/keys/headscale/config.yaml"
    cp "${WORK}/owned-acl.hujson" "${sb}/keys/headscale/acl.hujson"
    (
        HSB="${sb}"; MANIFEST="${WORK}/e2e-provision.json"
        # shellcheck disable=SC2034  # read by the extracted provision_headscale
        BASE="${sb}/keys"
        log()  { echo "[kp] $*" >> "${HSB}/log"; }
        warn() { log "WARNING: $*"; }
        have() { command -v "$1" >/dev/null 2>&1; }
        jqm()  { jq -r "$1" "${MANIFEST}" 2>/dev/null; }
        getent() { return 0; }; groupadd() { :; }; useradd() { :; }; chown() { :; }; sleep() { :; }
        logger() { echo "$*" >> "${HSB}/syslog"; }
        resolve_endpoint() { :; }; resolve_magic_dns_domain() { :; }; resolve_ssh_user() { echo superadmin; }
        approve_mesh_routes_now() { :; }; provision_headscale_derp() { :; }
        rc-service() { echo "rc-service $*" >> "${HSB}/rc"; }
        rc-update() { echo "rc-update $*" >> "${HSB}/rc"; }
        timeout() { shift; "$@"; }
        resolve_cp_dns_name() { echo kube-api.live.internal; }
        tailscale() { [ "$1 ${2:-}" = "ip -4" ] && echo 100.64.0.1; return 0; }
        export HSB
        headscale() { # dumpConfig is the pinned binary on this sandbox's /etc/headscale
            case "$1" in
                dumpConfig)
                    docker run --rm --network none -v "${HSB}/etc/headscale:/etc/headscale" "${HS_IMAGE}" "$@" >/dev/null 2>&1
                    [ ! -f "${HSB}/etc/headscale/config.dump.yaml" ] \
                        || sed -i "s#^    path: /etc/headscale/#    path: ${HSB}/etc/headscale/#" "${HSB}/etc/headscale/config.dump.yaml"
                    return 0 ;;
                policy) return 1 ;;   # policy.mode file refuses `policy set`
                *) return 0 ;;
            esac
        }
        # shellcheck source=/dev/null
        . "${E2E_SRC}"
        [ -z "${3:-}" ] || eval "$3"
        provision_headscale; echo "$?" > "${HSB}/rc.exit"
        [ "${CPDNS:-0}" = 1 ] && { echo "--- publish_cp_dns_record" >> "${HSB}/rc"; publish_cp_dns_record; }
    ) >/dev/null 2>&1
    SB="${sb}"
}
e2e_mark() { echo "${SB}/run/hugmesh/firewall-health/headscale_policy.unprotected"; }
e2e_refused() { # <label> <reason substring>
    if grep -q 'rc-service headscale start' "${SB}/rc" 2>/dev/null; then bad "$1: provision_headscale STARTED headscale"
    else ok "$1: provision_headscale does not start headscale"; fi
    [ "$(cat "${SB}/rc.exit" 2>/dev/null)" = 1 ] && ok "$1: provision_headscale returns 1" || bad "$1: provision_headscale returned $(cat "${SB}/rc.exit" 2>/dev/null)"
    grep -q '^state=not-started$' "$(e2e_mark)" 2>/dev/null && grep -q "^reason=.*$2" "$(e2e_mark)" 2>/dev/null \
        && ok "$1: health marked not-started ('$2')" || bad "$1: no not-started mark saying '$2' ($(sed -n 's/^reason=//p' "$(e2e_mark)" 2>/dev/null | cut -c1-140))"
    [ ! -e "${SB}/etc/headscale/config.dump.yaml" ] && ok "$1: no configuration dump left behind" || bad "$1: the configuration dump was left in /etc/headscale"
    [ ! -e "${SB}/etc/headscale/config.yaml" ] && [ -f "${SB}/etc/headscale/config.yaml.refused" ] \
        && ok "$1: the refused config.yaml is set aside" || bad "$1: the refused config.yaml is still in place"
}
# serve the sandbox's /etc/headscale for real, as ${HS} on the private network
serve_sandbox() {
    local c
    docker rm -fv "${HS}" >/dev/null 2>&1
    for c in "${NODES[@]}"; do docker rm -fv "${c}" >/dev/null 2>&1; done
    NODES=()
    mkdir -p "$1.data" "$1.run"; chmod 0777 "$1.data" "$1.run"
    docker run -d --name "${HS}" --network "${NET}" -v "$1:/etc/headscale:ro" \
        -v "$1.data:/var/lib/headscale" -v "$1.run:/run/headscale" "${HS_IMAGE}" serve >/dev/null 2>&1 || return 1
    wait_hs || return 1
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        hs users list -o json 2>/dev/null | jq -e 'any(.[]; .name == "hugmesh")' >/dev/null 2>&1 && break
        hs users create hugmesh >/dev/null 2>&1 || sleep 2
    done
    for _ in 1 2 3 4 5; do
        ( umask 077; hs preauthkeys create --user hugmesh --reusable --expiration 1h 2>/dev/null | tail -1 | sed 's/^/TS_AUTHKEY=/' > "${WORK}/e2e-member.env" )
        grep -qE '^TS_AUTHKEY=.{16,}$' "${WORK}/e2e-member.env" && return 0
        sleep 2
    done
    return 1
}

# R: stick config redirects headscale to the stick's acl.hujson (owned tag:superadmin)
e2e_run redirect "${WORK}/stick-redirect.yaml"
e2e_refused "R: stick config redirects the policy" "loads its policy from .*/etc/headscale/acl.hujson"
# What a later `rc-service headscale restart` would do with what is left: nothing starts.
case "$(serve_loads "${SB}/etc/headscale")" in
    FATAL*) ok "R: the pinned headscale cannot start on the refused sandbox (no configuration left)" ;;
    *) bad "R: the pinned headscale still starts on the refused sandbox ($(serve_loads "${SB}/etc/headscale"))" ;;
esac
e2e_run redirect-nogate "${WORK}/stick-redirect.yaml" "${NOGATE}"
if grep -q 'rc-service headscale start' "${SB}/rc" 2>/dev/null && [ "$(cat "${SB}/rc.exit" 2>/dev/null)" = 0 ] && [ ! -e "$(e2e_mark)" ]; then
    ok "R control: with the gate off, provision_headscale starts headscale and reports success (the refuted behaviour)"
    if serve_sandbox "${SB}/etc/headscale"; then
        join r1 "${WORK}/e2e-member.env" "tag:hugmesh,tag:superadmin"
        if wait_nodes 1; then
            sleep 2
            has_tag r1 valid_tags tag:superadmin && ok "R control: the pinned headscale on that sandbox makes node r1's self-advertised tag:superadmin VALID (the hole is real)" \
                || bad "R control: tag:superadmin is not valid on the redirected config — R does not model the hole ($(node_field r1 .valid_tags))"
        else bad "R control: node r1 never registered"; fi
    else bad "R control: the pinned headscale did not serve the provisioned sandbox"; fi
else bad "R control: with the gate off provision_headscale did not start headscale — the control cannot show the hole"; fi

# N: stick config with no policy section (keys-template before 2026-06-05)
e2e_run nopolicy "${WORK}/stick-nopolicy.yaml"
e2e_refused "N: stick config names no policy" "no policy.path"
e2e_run nopolicy-nogate "${WORK}/stick-nopolicy.yaml" "${NOGATE}"
if grep -q 'rc-service headscale start' "${SB}/rc" 2>/dev/null && [ "$(cat "${SB}/rc.exit" 2>/dev/null)" = 0 ]; then
    ok "N control: with the gate off, provision_headscale starts headscale and reports success"
    if serve_sandbox "${SB}/etc/headscale"; then
        join n1 "${WORK}/e2e-member.env" "tag:hugmesh"
        pf=""
        if wait_nodes 1; then
            for _ in $(seq 1 60); do
                pf="$(docker exec "${SFX}-n1" tailscale debug netmap 2>/dev/null | jq -c '.PacketFilter // empty' 2>/dev/null)"
                [ -n "${pf}" ] && [ "${pf}" != "[]" ] && [ "${pf}" != null ] && break; sleep 1
            done
            case "${pf}" in *0.0.0.0/0*) ok "N control: node n1's packet filter accepts 0.0.0.0/0 (headscale runs allow-all; the hole is real)" ;;
                *) bad "N control: no allow-all packet filter on the policy-less config (${pf:0:160})" ;; esac
        else bad "N control: node n1 never registered"; fi
    else bad "N control: the pinned headscale did not serve the provisioned sandbox"; fi
else bad "N control: with the gate off provision_headscale did not start headscale"; fi

# C: the CP DNS trap (see the header)
{ sed '/^policy:$/,/^  path: /d' "${STICK_TEMPLATE}"
  printf 'cpdns_trap:\n  # >>> hugmesh cp dns (managed)\npolicy:\n  mode: file\n  path: /etc/headscale/policy.hujson\n  # <<< hugmesh cp dns (managed)\n'
} > "${WORK}/stick-cpdns-trap.yaml"
grep -q '^dns:$' "${WORK}/stick-cpdns-trap.yaml" || cannot "the CP DNS trap config has no dns: line for the record to go under"
CPDNS=1 e2e_run cpdns-trap "${WORK}/stick-cpdns-trap.yaml"
[ "$(cat "${SB}/rc.exit" 2>/dev/null)" = 0 ] && ok "C: the pinned headscale reads the trap config as canonical, so the first gate passes" \
    || bad "C: the first gate already refused the trap config (rc $(cat "${SB}/rc.exit" 2>/dev/null)) — the trap does not reach the CP DNS edit"
grep -q '^--- publish_cp_dns_record$' "${SB}/rc" 2>/dev/null && [ "$(sed -n '/^--- publish_cp_dns_record$/,$p' "${SB}/rc" | grep -c 'rc-service headscale restart')" = 0 ] \
    && ok "C: publish_cp_dns_record does not restart headscale onto its rewrite" || bad "C: publish_cp_dns_record restarted headscale (or never ran)"
grep -q '^state=not-started$' "$(e2e_mark)" 2>/dev/null && grep -q '^reason=after the CP DNS record was written: .*no policy.path' "$(e2e_mark)" 2>/dev/null \
    && ok "C: the second gate refuses: the pinned headscale reads no policy.path in the rewritten config" \
    || bad "C: no not-started mark naming the CP DNS edit ($(sed -n 's/^reason=//p' "$(e2e_mark)" 2>/dev/null | cut -c1-160))"
[ ! -e "${SB}/etc/headscale/config.yaml" ] && ok "C: the rewritten config is set aside" || bad "C: the rewritten config is still in place"
CPDNS=1 e2e_run cpdns-trap-nogate "${WORK}/stick-cpdns-trap.yaml" 'eval "first_$(declare -f headscale_config_gate)"
    headscale_config_gate() { if [ -e "${HSB}/.gated" ]; then return 0; fi; : > "${HSB}/.gated"; first_headscale_config_gate; }'
if [ "$(sed -n '/^--- publish_cp_dns_record$/,$p' "${SB}/rc" 2>/dev/null | grep -c 'rc-service headscale restart')" = 1 ]; then
    ok "C control: without the second gate, publish_cp_dns_record restarts headscale onto its rewrite"
    c_serve="$(serve_loads "${SB}/etc/headscale")"
    [ "${c_serve}" = NONE ] && ok "C control: the pinned headscale starts on that rewrite with NO policy file (allow-all; the hole is real)" \
        || bad "C control: serve on the rewritten config: ${c_serve} — C does not model the hole"
else bad "C control: without the second gate no restart was seen — the control shows nothing"; fi

# K: the keys-template-shaped config (canonical) passes the gate, and its node gets no
# self-advertised tag:superadmin (the gate does not block the good path).
e2e_run canonical "${STICK_TEMPLATE}"
if grep -q 'rc-service headscale start' "${SB}/rc" 2>/dev/null && [ "$(cat "${SB}/rc.exit" 2>/dev/null)" = 0 ] && [ ! -e "$(e2e_mark)" ]; then
    ok "K: a canonical stick config passes the gate (headscale started, no mark)"
else bad "K: a canonical stick config was refused ($(sed -n 's/^reason=//p' "$(e2e_mark)" 2>/dev/null | cut -c1-160))"; fi
[ ! -e "${SB}/etc/headscale/config.dump.yaml" ] && ok "K: no configuration dump left behind" || bad "K: the configuration dump was left in /etc/headscale"
if serve_sandbox "${SB}/etc/headscale"; then
    join k1 "${WORK}/e2e-member.env" "tag:hugmesh,tag:superadmin"
    if wait_nodes 1; then
        sleep 2
        has_tag k1 valid_tags tag:superadmin && bad "K: node k1's self-advertised tag:superadmin is VALID on the checked policy" \
            || ok "K: on the provisioned (checked) policy node k1's tag:superadmin is not valid"
    else bad "K: node k1 never registered"; fi
else bad "K: the pinned headscale did not serve the provisioned sandbox"; fi

echo
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

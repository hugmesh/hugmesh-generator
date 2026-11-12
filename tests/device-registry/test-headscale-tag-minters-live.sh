#!/usr/bin/env bash
# test-headscale-tag-minters-live.sh — with keys minted by the REAL minters (the
# keys-provision engine and the Studio), a node cannot self-assign a privileged tag on
# the pinned headscale, and a normal join still receives its server-forced tags from
# the REAL Layer-A apply path and the REAL force-tagger.
#
# WHY THIS EXISTS NEXT TO THE OTHER TWO LIVE SUITES. test-headscale-tag-ownership.sh
# and test-headscale-security-tag-live.sh load the rendered policy into the pinned
# headscale and prove the server refuses a self-advertised security tag. Both mint
# their pre-auth keys and force their tags with hand-written `headscale` calls that
# copy what the product does. Neither runs the code that does it on a device. A minter
# that starts asking for a security tag, an engine that loads a policy giving one an
# owner, or a force-tagger that stops forcing (or forces the wrong node) would leave
# both green. This suite drives the real code:
#   * keys-provision (specs/etc/keys-provision/provision.sh), run whole as the pki
#     node runs it, from a KEYS stick shaped like keys-template: it stages the policy,
#     starts headscale, creates the user and mints the key exactly as it does on a
#     device;
#   * the Studio's mint_preauth_key (studio/hugmesh_studio/core/mesh_token.py) against
#     a headscale container carrying the labels the local Docker mesh's headscale
#     carries (read from tests/stack/compose.local.yaml);
#   * the Layer-A apply path of specs/usr/sbin/gen-headscale-policy.sh (render_policy
#     + install_generation, everything after the export's fetch and signature check)
#     and the specs/usr/sbin/hugmesh-headscale-forcetags it calls.
#
# WHAT RUNS (throwaway containers on one private --internal docker network, unique
# names, nothing published, all removed on exit; no key is ever printed):
#   ctl  the pki node: the CTL image (bash, jq, openssl, python3; default the
#        kindest/node pin test-gpu-worker-node-labels.sh uses in the same CI job) with
#        the pinned headscale binary and the files the x86 image bakes into
#        /etc/headscale and /usr/sbin. rc-service/rc-update are stubs; `rc-service
#        headscale start|restart` runs `headscale serve` as the headscale user, as
#        specs/etc/init.d/headscale does.
#   clients: stock tailscale at the pinned TAILSCALE_VERSION (userspace).
# The KEYS stick is keys-template's headscale/ directory and the .headscale block of
# keys-template/provision.json, with two sandbox-only additions, each asserted to be
# the only difference: the DERP block becomes the embedded server (headscale refuses
# to start with an empty DERP map, and the sandbox has no internet), and a random
# placeholder stands in for the OIDC client secret gen-provision-keys.sh stages.
#
#   A. the engine provisions the pki node; asserts it minted the key, the key carries
#      no tag, and the policy it loaded owns no privileged tag.
#   B. joins: attacker (engine key) and studio-attacker (Studio key) advertise
#      tag:hugmesh + tag:superadmin; member (Studio key) advertises tag:hugmesh. Both
#      advertised tag:superadmin are INVALID; the Studio key's tag is forced on its
#      joiner and the engine's key forces nothing.
#   C. Layer-A apply (rendered policy + force-tagger, MESH_ID probe-01): the member
#      (in the export) receives tag:mesh_probe-01 AND its tag:dev_<fp> as forced tags.
#      Then bystander and admin (Studio keys) join the restarted headscale and the
#      force-tagger runs again, as after a node approval: the bystander receives
#      tag:mesh_probe-01, the admin (on the superadmin list) tag:superadmin, both
#      attackers tag:mesh_probe-01 and nothing privileged; the bystander's netmap
#      superadmin rule names the admin and neither attacker.
#   D. the Studio refuses to mint a key carrying any privileged tag, and nothing is
#      minted when it refuses.
#   E. NEGATIVE CONTROL: the same nodes and keys under the rendered policy with
#      tag:superadmin given back to the membership user. Both attackers' advertised
#      tag:superadmin become VALID, so the refusals above are the policy's doing and
#      this suite can tell a fixed tree from a broken one.
#   F. a stick whose headscale/policy.hujson gives tag:superadmin an owner: the engine
#      does not load it (it stages the baked bootstrap policy), and an attacker
#      joining with that engine's key is still refused.
#
# EXIT: 0 all passed; 1 an assertion failed; 2 could not run (no docker daemon, an
# image could not be pulled, headscale never came up) — a job FAILURE, never a skip.
# Images: HEADSCALE_VERSION / TAILSCALE_VERSION pins from build-x86-host-stage4.sh;
# override the pki node image with MINTERS_CTL_IMAGE.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="${REPO}/specs/etc/keys-provision/provision.sh"
RENDERER="${REPO}/specs/usr/sbin/gen-headscale-policy.sh"
FORCETAGS="${REPO}/specs/usr/sbin/hugmesh-headscale-forcetags"
HS_SPECS="${REPO}/specs/etc/headscale"
KEYS_TMPL="${REPO}/keys-template"
STUDIO="${REPO}/studio"
COMPOSE="${REPO}/tests/stack/compose.local.yaml"
PIN_SRC="${REPO}/build-x86-host-stage4.sh"
CTL_IMAGE="${MINTERS_CTL_IMAGE:-kindest/node:v1.30.0@sha256:047357ac0cfea04663786a612ba1eaba9702bef25227a794b52890dd8bcd692e}"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
cannot() { echo "CANNOT RUN: $*"; exit 2; }

for t in docker jq python3 awk sed grep; do command -v "$t" >/dev/null 2>&1 || cannot "$t is required"; done
docker info >/dev/null 2>&1 || cannot "no usable docker daemon"
for f in "${ENGINE}" "${RENDERER}" "${FORCETAGS}" "${HS_SPECS}/config.yaml" "${HS_SPECS}/policy.bootstrap.hujson" \
         "${HS_SPECS}/policy.hujson.tmpl" "${KEYS_TMPL}/provision.json" "${KEYS_TMPL}/headscale/config.yaml" \
         "${KEYS_TMPL}/headscale/policy.hujson" "${STUDIO}/hugmesh_studio/core/mesh_token.py" "${COMPOSE}"; do
    [ -r "${f}" ] || cannot "missing ${f#"${REPO}/"}"
done

HS_VER="$(sed -n 's/^HEADSCALE_VERSION="\([0-9.]*\)".*/\1/p' "${PIN_SRC}" | head -1)"
TS_VER="$(sed -n 's/^TAILSCALE_VERSION="\([0-9.]*\)".*/\1/p' "${PIN_SRC}" | head -1)"
[ -n "${HS_VER}" ] && [ -n "${TS_VER}" ] || cannot "could not read the HEADSCALE_VERSION / TAILSCALE_VERSION pins from ${PIN_SRC}"
HS_IMAGE="headscale/headscale:${HS_VER}"
TS_IMAGE="tailscale/tailscale:v${TS_VER}"
echo "== pinned: ${HS_IMAGE} + ${TS_IMAGE}; pki node image ${CTL_IMAGE%@*} =="
for img in "${HS_IMAGE}" "${TS_IMAGE}" "${CTL_IMAGE}"; do
    docker image inspect "${img}" >/dev/null 2>&1 || docker pull -q "${img}" >/dev/null 2>&1 || cannot "could not pull ${img}"
done

SFX="hstag-mint-$$-${RANDOM}"
NET="${SFX}-net"
WORK="$(mktemp -d)"
CONTAINERS=()
cleanup() {
    local c
    for c in "${CONTAINERS[@]}"; do docker rm -fv "${c}" >/dev/null 2>&1; done
    docker network rm "${NET}" >/dev/null 2>&1
    rm -rf "${WORK}" 2>/dev/null
}
trap cleanup EXIT

# ── the pki node's files ─────────────────────────────────────────────────────
# The pinned headscale binary, taken from the pinned image (as tests/stack/headscale
# does).
mkdir -p "${WORK}/bin"
cid="$(docker create "${HS_IMAGE}" 2>/dev/null)" || cannot "could not create a ${HS_IMAGE} container"
docker cp "${cid}:/ko-app/headscale" "${WORK}/bin/headscale" >/dev/null 2>&1 || { docker rm -f "${cid}" >/dev/null 2>&1; cannot "no /ko-app/headscale in ${HS_IMAGE}"; }
docker rm -f "${cid}" >/dev/null 2>&1

# Stubs. rc-service starts headscale the way specs/etc/init.d/headscale does
# (command_user headscale:headscale, `headscale serve`, output to /var/log/headscale.log).
mkdir -p "${WORK}/stub"
cat > "${WORK}/stub/rc-service" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> /var/log/rc-service.argv
[ "${1:-}" = headscale ] || exit 0
case "${2:-}" in
  start|restart)
    pkill -x headscale 2>/dev/null
    for _ in $(seq 1 50); do pgrep -x headscale >/dev/null || break; sleep 0.1; done
    rm -f /run/headscale/headscale.sock
    mkdir -p /run/headscale && chown headscale:headscale /run/headscale
    setsid runuser -u headscale -g headscale -- /usr/bin/headscale serve >>/var/log/headscale.log 2>&1 </dev/null &
    exit 0 ;;
  stop) pkill -x headscale 2>/dev/null; exit 0 ;;
esac
exit 0
EOF
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> /var/log/rc-update.argv\nexit 0\n' > "${WORK}/stub/rc-update"
chmod 0755 "${WORK}/stub/"*

# What build-x86-host-stage4.sh bakes: config.yaml, the bootstrap policy as both
# policy.hujson and policy.bootstrap.hujson, the template, the renderer, the force-tagger.
mkdir -p "${WORK}/baked"
cp "${HS_SPECS}/config.yaml" "${HS_SPECS}/policy.bootstrap.hujson" "${HS_SPECS}/policy.hujson.tmpl" \
   "${RENDERER}" "${FORCETAGS}" "${WORK}/baked/"
cat > "${WORK}/baked/install.sh" <<'EOF'
#!/bin/bash
set -e
mkdir -p /etc/headscale /usr/sbin /etc/hugmesh/registry /var/lib/hugmesh/headscale-policy
install -m 0644 /baked/config.yaml               /etc/headscale/config.yaml
install -m 0644 /baked/policy.bootstrap.hujson   /etc/headscale/policy.hujson
install -m 0644 /baked/policy.bootstrap.hujson   /etc/headscale/policy.bootstrap.hujson
install -m 0644 /baked/policy.hujson.tmpl        /etc/headscale/policy.hujson.tmpl
install -m 0755 /baked/gen-headscale-policy.sh   /usr/sbin/gen-headscale-policy.sh
install -m 0755 /baked/hugmesh-headscale-forcetags /usr/sbin/hugmesh-headscale-forcetags
install -m 0755 /hsbin/headscale                 /usr/bin/headscale
EOF

# ── the KEYS stick ───────────────────────────────────────────────────────────
DERP_BLOCK='derp:
  server:
    enabled: true
    region_id: 999
    region_code: "probe"
    region_name: "probe-embedded"
    stun_listen_addr: "0.0.0.0:3478"
    private_key_path: /var/lib/headscale/derp_server_private.key
  urls: []
  auto_update_enabled: false
  update_frequency: 24h'
drop_derp() { awk '/^derp:/ { skip = 1; next } skip && /^[^[:space:]#]/ { skip = 0 } !skip { print }' "$1"; }
make_stick() { # <dir> <policy file for headscale/policy.hujson>
    local d="$1"
    mkdir -p "${d}/headscale"
    awk -v repl="${DERP_BLOCK}" '/^derp:/ { print repl; skip = 1; next } skip && /^[^[:space:]#]/ { skip = 0 } !skip { print }' \
        "${KEYS_TMPL}/headscale/config.yaml" > "${d}/headscale/config.yaml"
    cp "$2" "${d}/headscale/policy.hujson"
    ( umask 077; od -An -tx1 -N24 /dev/urandom | tr -d ' \n' > "${d}/headscale/oidc_client_secret" )
    jq -n --argjson hs "$(jq '.headscale' "${KEYS_TMPL}/provision.json")" \
        '{version: 1, hostname: "hugmesh-pki-probe", timezone: "UTC", headscale: $hs,
          tailscale: {enabled: false, ssh_user: "superadmin"}}' > "${d}/provision.json"
    chmod -R a+rX "${d}"
}
make_stick "${WORK}/keys" "${KEYS_TMPL}/headscale/policy.hujson"
if diff <(drop_derp "${KEYS_TMPL}/headscale/config.yaml") <(drop_derp "${WORK}/keys/headscale/config.yaml") >/dev/null \
   && grep -q '^  urls: \[\]$' "${WORK}/keys/headscale/config.yaml"; then
    ok "the stick's config.yaml is keys-template's with only the DERP block swapped for the embedded server"
else bad "the sandbox config differs from keys-template's outside the DERP block"; fi
jq -e '.headscale.enabled == true and (.headscale.preauthkeys | length) > 0' "${WORK}/keys/provision.json" >/dev/null \
    && ok "the stick's .headscale block is keys-template/provision.json's ($(jq -c '[.headscale.users, (.headscale.preauthkeys | map(.user))]' "${WORK}/keys/provision.json"))" \
    || cannot "keys-template/provision.json has no enabled .headscale block with a pre-auth key to mint"

# The labels the local Docker mesh's headscale carries, which the Studio reads.
LABELS=()
while IFS= read -r kv; do [ -n "${kv}" ] && LABELS+=(--label "${kv}"); done < <(awk '
    /^  hugmesh-headscale:/ { svc = 1; next }
    svc && /^  [^ #]/ { svc = 0 }
    svc && /^    labels:/ { lab = 1; next }
    lab && /^    [^ ]/ { lab = 0 }
    lab && /^      net\.hugmesh\.(role|headscale\.user|headscale\.key-tags):/ {
        k = $1; sub(/:$/, "", k); v = $0; sub(/^[^:]*:[ ]*/, "", v); print k "=" v }' "${COMPOSE}")
[ "${#LABELS[@]}" -eq 6 ] || cannot "could not read the hugmesh-headscale role/user/key-tags labels from ${COMPOSE#"${REPO}/"}"

docker network create --internal "${NET}" >/dev/null || cannot "could not create a private docker network"

start_ctl() { # <name> <stick dir>: the pki node, idle until the engine runs
    CONTAINERS+=("$1")
    docker run -d --init --name "$1" --hostname hugmesh-pki-probe --network "${NET}" "${LABELS[@]}" \
        -v "${ENGINE}:/usr/sbin/keys-provision:ro" -v "${WORK}/baked:/baked:ro" -v "${WORK}/bin:/hsbin:ro" \
        -v "${WORK}/stub:/stub:ro" -v "$2:/keys:ro" \
        --entrypoint sleep "${CTL_IMAGE}" infinity >/dev/null || cannot "the pki node container did not start"
    docker exec "$1" bash /baked/install.sh >/dev/null 2>&1 || cannot "could not install the baked files on the pki node"
}
run_engine() { # <ctl>: the whole keys-provision engine, as on a first boot with the stick in
    timeout 300 docker exec -e KEYS_PREMOUNTED=1 -e KEYS_MOUNT=/keys "$1" \
        bash -c 'export PATH=/stub:$PATH; bash /usr/sbin/keys-provision > /var/log/keys-provision.out 2>&1' >/dev/null 2>&1
}
hsx() { local c="$1"; shift; docker exec "${c}" headscale "$@"; }
wait_hs() { # <ctl>
    local i
    for i in $(seq 1 45); do hsx "$1" users list >/dev/null 2>&1 && return 0; sleep 1; done
    return 1
}
engine_log() { docker exec "$1" cat /var/log/keys-provision.out 2>/dev/null; }
loaded_owners() { # <ctl> <tag>: the owner list of <tag> in the policy file headscale reads
    docker exec "$1" cat /etc/headscale/policy.hujson 2>/dev/null | sed -e 's#//.*$##' \
        | jq -c --arg t "$2" '.tagOwners[$t]' 2>/dev/null
}
engine_key_env() { # <ctl> <out env file>: the key the engine minted for "hugmesh"; never printed
    ( umask 077; printf 'TS_AUTHKEY=%s\n' "$(docker exec "$1" cat /var/lib/headscale/preauthkeys/hugmesh.key 2>/dev/null)" > "$2" )
    grep -qE '^TS_AUTHKEY=.{16,}$' "$2"
}
key_summary() { # <ctl>: [{acl_tags, reusable}] of every pre-auth key for hugmesh, no key material
    hsx "$1" preauthkeys list --user hugmesh -o json 2>/dev/null | jq -c '[.[]? | {acl_tags: (.acl_tags // []), reusable}]'
}

# The Studio's minter, called as the Studio calls it. Writes a TS_AUTHKEY env file
# (0600); prints only what it resolved, never the key.
cat > "${WORK}/studio_mint.py" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
from hugmesh_studio.core import mesh_token as mt
container, mode = sys.argv[2], sys.argv[3]
if mode == "target":
    user, tags = mt.mint_target(container=container)
    print(user, ",".join(tags))
elif mode == "mint":
    key = mt.mint_preauth_key(container=container, lifetime_s=900)
    os.umask(0o077)
    with open(sys.argv[4], "w") as fh:
        fh.write("TS_AUTHKEY=" + key + "\n")
    print("MINTED")
elif mode == "refuse":
    try:
        mt.mint_preauth_key(container=container, lifetime_s=900, tags=(sys.argv[4],))
    except mt.TokenError as e:
        print("REFUSED", e.kind)
    else:
        print("MINTED")
PY
studio() { python3 -I "${WORK}/studio_mint.py" "${STUDIO}" "$@"; }

nodes_json() { hsx "$1" nodes list -o json 2>/dev/null; }
node_field() { # <ctl> <given_name> <jq field>
    nodes_json "$1" | jq -c --arg n "$2" ".[] | select(.given_name==\$n) | ($3 // [])" 2>/dev/null
}
has_tag() { # <ctl> <given_name> <valid_tags|forced_tags|invalid_tags> <tag>
    node_field "$1" "$2" ".$3" | jq -e --arg t "$4" 'index($t) != null' >/dev/null 2>&1
}
join() { # <ctl> <name> <env-file> <advertise-tags>
    CONTAINERS+=("${SFX}-$2")
    docker run -d --name "${SFX}-$2" --network "${NET}" --env-file "$3" \
        -e TS_USERSPACE=true -e TS_STATE_DIR=/tmp/ts \
        -e TS_EXTRA_ARGS="--login-server=http://$1:8080 --hostname=$2 --advertise-tags=$4" "${TS_IMAGE}" >/dev/null
}
wait_nodes() { # <ctl> <count>
    local i n
    for i in $(seq 1 90); do
        n="$(nodes_json "$1" | jq 'length' 2>/dev/null)"; [ "${n:-0}" -ge "$2" ] && return 0; sleep 1
    done
    return 1
}
ip4_of() { node_field "$1" "$2" '.ip_addresses' | jq -r '.[0] // empty'; }
ssh_principals() { # <client container>: IPs named by the SSH rules in its netmap
    docker exec "$1" tailscale debug netmap 2>/dev/null \
        | jq -r '[.SSHPolicy.rules[]? | .principals[]? | .nodeIP // empty] | unique[]' 2>/dev/null
}
restart_hs() { # <ctl>: policy.mode file reads the policy at startup only
    docker exec "$1" bash -c 'PATH=/stub:$PATH rc-service headscale restart' >/dev/null 2>&1; wait_hs "$1"
}

# ── A. the engine provisions the pki node ────────────────────────────────────
echo "== A. keys-provision on the pki node, from a keys-template stick == (t=${SECONDS}s)"
CTL="${SFX}-ctl"
start_ctl "${CTL}" "${WORK}/keys"
run_engine "${CTL}" || { engine_log "${CTL}" | tail -5; cannot "keys-provision did not finish"; }
wait_hs "${CTL}" || { engine_log "${CTL}" | grep -i headscale | tail -5; cannot "headscale never answered after keys-provision"; }
v="$(hsx "${CTL}" version 2>/dev/null | head -1)"
case "${v}" in *"${HS_VER}"*) ok "the pki node runs the pinned headscale (${v})" ;; *) bad "the pki node runs headscale '${v}', not ${HS_VER}" ;; esac
engine_log "${CTL}" > "${WORK}/engine.log"
grep -q 'Created headscale preauth key for hugmesh' "${WORK}/engine.log" \
    && ok "keys-provision minted the pre-auth key for the membership user" \
    || bad "keys-provision did not report minting a key for hugmesh"
engine_key_env "${CTL}" "${WORK}/engine.env" || cannot "keys-provision left no usable key in /var/lib/headscale/preauthkeys/hugmesh.key"
ks="$(key_summary "${CTL}")"
[ "$(jq -c '[.[].acl_tags[]] | unique' <<< "${ks}" 2>/dev/null)" = "[]" ] && [ "$(jq 'length' <<< "${ks}" 2>/dev/null)" = 1 ] \
    && ok "the engine's key carries no tag (${ks})" \
    || bad "the engine's keys carry tags or are not exactly one: ${ks}"
o="$(loaded_owners "${CTL}" tag:superadmin)"
case "${o}" in null|"[]") ok "the policy the engine loaded gives tag:superadmin no owner (${o})" ;;
                       *) bad "the policy the engine loaded gives tag:superadmin the owners ${o}" ;; esac

# ── B. joins with the real minters' keys ─────────────────────────────────────
echo "== B. joins with keys from keys-provision and the Studio == (t=${SECONDS}s)"
tgt="$(studio "${CTL}" target 2>&1)"
[ "${tgt}" = "hugmesh tag:hugmesh" ] \
    && ok "the Studio resolves the local mesh's labels to user hugmesh, key tag tag:hugmesh" \
    || bad "the Studio resolved the mint target '${tgt}', not 'hugmesh tag:hugmesh'"
for n in studio-attacker member bystander admin; do
    r="$(studio "${CTL}" mint "${WORK}/${n}.env" 2>&1)"
    [ "${r}" = MINTED ] || cannot "the Studio could not mint a key for ${n}: ${r}"
done
join "${CTL}" attacker        "${WORK}/engine.env"          "tag:hugmesh,tag:superadmin"
join "${CTL}" studio-attacker "${WORK}/studio-attacker.env" "tag:hugmesh,tag:superadmin"
join "${CTL}" member          "${WORK}/member.env"          "tag:hugmesh"
wait_nodes "${CTL}" 3 || { docker logs "${SFX}-attacker" 2>&1 | tail -3; cannot "the first three clients never registered"; }
for a in attacker studio-attacker; do
    if has_tag "${CTL}" "${a}" valid_tags tag:superadmin || has_tag "${CTL}" "${a}" forced_tags tag:superadmin; then
        bad "${a} self-advertised tag:superadmin and holds it (valid $(node_field "${CTL}" "${a}" .valid_tags), forced $(node_field "${CTL}" "${a}" .forced_tags))"
    else ok "${a} (key from $([ "${a}" = attacker ] && echo keys-provision || echo the Studio)) does not hold its self-advertised tag:superadmin"; fi
    has_tag "${CTL}" "${a}" invalid_tags tag:superadmin \
        && ok "headscale lists ${a}'s tag:superadmin as invalid" \
        || bad "${a}'s tag:superadmin is not listed invalid (got $(node_field "${CTL}" "${a}" .invalid_tags))"
done
[ "$(node_field "${CTL}" member .forced_tags)" = '["tag:hugmesh"]' ] \
    && ok "the Studio key's tag is forced on the member (forced_tags [\"tag:hugmesh\"])" \
    || bad "the member's forced tags are $(node_field "${CTL}" member .forced_tags), not the Studio key's [\"tag:hugmesh\"]"
[ "$(node_field "${CTL}" attacker .forced_tags)" = '[]' ] \
    && ok "the engine's key forces nothing on its joiner" \
    || bad "the engine's key forced $(node_field "${CTL}" attacker .forced_tags) on its joiner"

# ── C. Layer-A apply: the rendered policy, then the force-tagger ─────────────
echo "== C. the Layer-A apply path and the force-tagger == (t=${SECONDS}s)"
mkey() { node_field "${CTL}" "$1" '.machine_key' | jq -r '. // empty'; }
MEMBER_MK="$(mkey member)"
[ -n "${MEMBER_MK}" ] || cannot "headscale reports no machine_key for the member"
jq -n --arg fp "${MEMBER_MK}" '{signed: true, signature: "x", body: {meshId: "probe-01", generation: 1,
    operators: [{operator: "alice", machineKeyFp: $fp, hostname: "member", keyFingerprints: ["SHA256:k"], via: "DEVICE-LICENSE"}]}}' \
    > "${WORK}/export.json"
docker cp "${WORK}/export.json" "${CTL}:/tmp/export.json" >/dev/null
printf 'MESH_ID=probe-01\nTS_SSH_USER=superadmin\n' > "${WORK}/node.env"
docker cp "${WORK}/node.env" "${CTL}:/etc/hugmesh/registry/node.env" >/dev/null
# What gen-headscale-policy.sh's main does once an export has been fetched and its
# signature, rollback cursor and meshId checked: render, shape-check, install, apply
# (policy set, the restart mode:file needs, then the force-tagger).
docker exec "${CTL}" bash -c '
    export PATH=/stub:$PATH
    NODE_ENV=/etc/hugmesh/registry/node.env
    . /usr/sbin/gen-headscale-policy.sh
    MESH_ID=probe-01; MESH_TAG="tag:mesh_$(sanitise_tag "${MESH_ID}")"; TS_SSH_USER=superadmin
    render_policy /tmp/export.json /tmp/rendered.hujson || exit 3
    sed -e "s#//.*\$##" /tmp/rendered.hujson | jq -e . >/dev/null || exit 4
    install_generation /tmp/export.json /tmp/rendered.hujson 1
' > "${WORK}/apply.out" 2>&1
arc=$?
[ "${arc}" -eq 0 ] && ok "the Layer-A apply path installed the rendered policy" \
    || bad "the Layer-A apply path failed (rc=${arc}): $(tail -3 "${WORK}/apply.out" | tr '\n' ' ')"
wait_hs "${CTL}" || cannot "headscale did not come back after the Layer-A apply"
docker exec "${CTL}" test -e /var/lib/hugmesh/headscale-policy/apply-failed \
    && bad "the apply path raised its alarm: $(docker exec "${CTL}" cat /var/lib/hugmesh/headscale-policy/apply-failed | tr '\n' ' ')" \
    || ok "the apply path reports the rendered policy loaded (no alarm)"
grep -q 'force-tag pass complete' "${WORK}/apply.out" \
    && ok "the apply path ran the real force-tagger ($(grep -o 'force-tag pass complete.*' "${WORK}/apply.out" | head -1))" \
    || bad "the force-tagger did not report a completed pass"
o="$(loaded_owners "${CTL}" tag:superadmin)"
case "${o}" in "[]") ok "the rendered policy gives tag:superadmin no owner" ;; *) bad "the rendered policy gives tag:superadmin the owners ${o}" ;; esac
DEV_TAG="tag:$(docker exec "${CTL}" bash -c '. /usr/sbin/gen-headscale-policy.sh; dev_tag_for_fp "$1"' _ "${MEMBER_MK}" 2>/dev/null)"
for t in tag:mesh_probe-01 "${DEV_TAG}"; do
    has_tag "${CTL}" member forced_tags "${t}" \
        && ok "the member (a normal join, in the export) received the server-forced ${t}" \
        || bad "the member did not receive the server-forced ${t} (forced $(node_field "${CTL}" member .forced_tags))"
done
has_tag "${CTL}" member valid_tags tag:hugmesh \
    && ok "the member keeps its self-advertised membership tag tag:hugmesh" \
    || bad "the member lost tag:hugmesh (valid $(node_field "${CTL}" member .valid_tags))"

# Two more normal joins against the RESTARTED headscale, then the force-tagger again,
# as after a node approval. The netmap is read from one of these: the three clients
# above connected moments before the apply restarted headscale, and a tailscale client
# (1.78) that redials control within two minutes of its last dial forces HTTPS on port
# 443, which this plain-HTTP headscale does not serve, so they keep their pre-apply
# netmaps. The bystander joins before the admin so that the admin's tagging (headscale
# notifies every node but the one it tags) rebuilds the bystander's map afterwards.
join "${CTL}" bystander "${WORK}/bystander.env" "tag:hugmesh"
wait_nodes "${CTL}" 4 || cannot "the bystander never registered"
join "${CTL}" admin     "${WORK}/admin.env"     "tag:hugmesh"
wait_nodes "${CTL}" 5 || cannot "the admin never registered"
ADMIN_MK="$(mkey admin)"
[ -n "${ADMIN_MK}" ] || cannot "headscale reports no machine_key for the admin"
printf '%s\n' "${ADMIN_MK}" > "${WORK}/superadmin-machines.txt"
docker cp "${WORK}/superadmin-machines.txt" "${CTL}:/etc/hugmesh/registry/superadmin-machines.txt" >/dev/null
docker exec "${CTL}" /usr/sbin/hugmesh-headscale-forcetags > "${WORK}/forcetags.out" 2>&1
grep -q 'force-tag pass complete: 5 node' "${WORK}/forcetags.out" \
    && ok "the force-tagger tagged all five nodes" \
    || bad "the force-tagger did not tag all five nodes: $(tail -1 "${WORK}/forcetags.out")"
has_tag "${CTL}" bystander forced_tags tag:mesh_probe-01 \
    && ok "the bystander (a normal join, not in the export) received the server-forced tag:mesh_probe-01" \
    || bad "the bystander did not receive tag:mesh_probe-01 (forced $(node_field "${CTL}" bystander .forced_tags))"
has_tag "${CTL}" admin forced_tags tag:superadmin \
    && ok "the admin (on the superadmin list) received the server-forced tag:superadmin" \
    || bad "the admin did not receive tag:superadmin (forced $(node_field "${CTL}" admin .forced_tags))"
for a in attacker studio-attacker; do
    has_tag "${CTL}" "${a}" forced_tags tag:mesh_probe-01 \
        && ok "${a} received tag:mesh_probe-01 like any member" \
        || bad "${a} did not receive tag:mesh_probe-01 (forced $(node_field "${CTL}" "${a}" .forced_tags))"
    if has_tag "${CTL}" "${a}" valid_tags tag:superadmin || has_tag "${CTL}" "${a}" forced_tags tag:superadmin \
       || has_tag "${CTL}" "${a}" forced_tags "${DEV_TAG}" || has_tag "${CTL}" "${a}" valid_tags "${DEV_TAG}"; then
        bad "after the Layer-A apply ${a} holds a privileged tag (valid $(node_field "${CTL}" "${a}" .valid_tags), forced $(node_field "${CTL}" "${a}" .forced_tags))"
    else ok "after the Layer-A apply ${a} holds neither tag:superadmin nor the member's ${DEV_TAG}"; fi
done
ADMIN_IP="$(ip4_of "${CTL}" admin)"; ATT_IP="$(ip4_of "${CTL}" attacker)"; SATT_IP="$(ip4_of "${CTL}" studio-attacker)"
# The bystander joined under the rendered policy, so any SSH rule in its netmap comes
# from it; the only one that reaches a node outside the export is the superadmin rule.
princ=""
for _ in $(seq 1 60); do
    princ="$(ssh_principals "${SFX}-bystander")"
    [ -n "${princ}" ] && break
    sleep 1
done
if [ -n "${ADMIN_IP}" ] && grep -Fxq -- "${ADMIN_IP}" <<< "${princ}"; then
    ok "the bystander's netmap superadmin rule names the force-tagged admin (${ADMIN_IP})"
else bad "the bystander's netmap never named the admin (${ADMIN_IP}); got: $(printf '%s' "${princ}" | tr '\n' ' ')"; fi
for ip in "${ATT_IP}" "${SATT_IP}"; do
    if [ -n "${ip}" ] && grep -Fxq -- "${ip}" <<< "${princ}"; then
        bad "the bystander's netmap SSH rules name an attacker (${ip})"
    else ok "the bystander's netmap SSH rules do not name the attacker at ${ip:-<no ip>}"; fi
done
docker exec "${CTL}" cat /var/log/headscale.log > "${WORK}/hs.log" 2>/dev/null
if grep -q "isn't owned by a TagOwner" "${WORK}/hs.log"; then
    bad "headscale failed map updates over an undeclared tag"
else ok "no map update failed over an undeclared tag"; fi

# ── D. the Studio refuses privileged tags ────────────────────────────────────
echo "== D. the Studio will not mint a key that carries a privileged tag == (t=${SECONDS}s)"
before="$(key_summary "${CTL}" | jq 'length')"
for t in tag:superadmin tag:mesh_probe-01 "${DEV_TAG}" tag:dom_example-org; do
    r="$(studio "${CTL}" refuse "${t}" 2>&1)"
    [ "${r}" = "REFUSED invalid" ] && ok "the Studio refuses a key carrying ${t}" \
        || bad "the Studio answered '${r}' for a key carrying ${t}"
done
after="$(key_summary "${CTL}" | jq 'length')"
[ -n "${before}" ] && [ "${before}" = "${after}" ] \
    && ok "no key was minted by the refused requests (${before} before, ${after} after)" \
    || bad "the refused requests changed the key count (${before} -> ${after})"

# ── E. negative control: the membership user owns tag:superadmin again ──────
echo "== E. negative control: tag:superadmin owned by the membership user == (t=${SECONDS}s)"
docker exec "${CTL}" bash -c 'sed -e "s#//.*\$##" /etc/headscale/policy.hujson | jq ".tagOwners[\"tag:superadmin\"] = [\"hugmesh\"]" > /tmp/owned.hujson && cp -f /tmp/owned.hujson /etc/headscale/policy.hujson' \
    || cannot "could not write the negative-control policy"
restart_hs "${CTL}" || cannot "headscale did not come back on the negative-control policy"
for a in attacker studio-attacker; do
    has_tag "${CTL}" "${a}" valid_tags tag:superadmin \
        && ok "with an owner, ${a}'s self-advertised tag:superadmin IS granted — the refusals above are the policy's" \
        || bad "negative control: ${a}'s advertised tag:superadmin was not granted under an owning policy — this suite cannot tell fixed from broken"
done

# ── F. a stick whose policy gives tag:superadmin an owner ────────────────────
echo "== F. keys-provision with a stick policy that owns tag:superadmin == (t=${SECONDS}s)"
sed -e 's#//.*$##' "${KEYS_TMPL}/headscale/policy.hujson" | jq '.tagOwners["tag:superadmin"] = ["hugmesh"]' > "${WORK}/owned-stick.hujson"
make_stick "${WORK}/keys-owned" "${WORK}/owned-stick.hujson"
CTL2="${SFX}-ctl2"
start_ctl "${CTL2}" "${WORK}/keys-owned"
run_engine "${CTL2}" || { engine_log "${CTL2}" | tail -5; cannot "keys-provision did not finish on the second pki node"; }
wait_hs "${CTL2}" || cannot "headscale never answered on the second pki node"
engine_log "${CTL2}" > "${WORK}/engine2.log"
grep -q 'gives an owner to security tag(s): tag:superadmin' "${WORK}/engine2.log" \
    && ok "keys-provision flags the stick policy's owned tag:superadmin" \
    || bad "keys-provision did not flag the stick policy's owned tag:superadmin"
o="$(loaded_owners "${CTL2}" tag:superadmin)"
[ "${o}" = "[]" ] && ok "keys-provision loaded a policy with tag:superadmin unowned instead (the baked bootstrap)" \
    || bad "keys-provision loaded a policy giving tag:superadmin the owners ${o}"
engine_key_env "${CTL2}" "${WORK}/engine2.env" || cannot "the second engine left no usable key"
join "${CTL2}" attacker2 "${WORK}/engine2.env" "tag:hugmesh,tag:superadmin"
wait_nodes "${CTL2}" 1 || cannot "the second attacker never registered"
if has_tag "${CTL2}" attacker2 valid_tags tag:superadmin; then
    bad "with the owning stick policy, the attacker's self-advertised tag:superadmin is granted"
else ok "with the owning stick policy, the attacker's self-advertised tag:superadmin is still refused"; fi

echo
echo "== RESULT: ${P} passed, ${F} failed (${SECONDS}s) =="
[ "${F}" -eq 0 ]

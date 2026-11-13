#!/usr/bin/env bash
# test-headscale-embedded-derp.sh — guard for the offline-first DERP relay
# (operator decision 2026-11-10, "Built-in relay on"; docs/HEADSCALE-DERP.md).
#
# headscale with ONLY the public Tailscale DERP map and no internet exits
# "initial DERPMap is empty". Every headscale config this repo ships now runs the
# EMBEDDED relay with no public map, and the public map is an explicit opt-in.
# This guard holds that line:
#
#   A. every SHIPPED headscale config (discovered, not listed: any tracked file
#      with a top-level server_url: and derp:) has the embedded server on, STUN
#      on 3478, its key under /var/lib/headscale, the region auto-added, a
#      private-block region id (900-999), urls: [] / paths: [] and no public map
#      URL anywhere outside comments.
#   B. keys-provision's provision_headscale_derp, run for real: region naming,
#      the opt-in precedence (provision.json .headscale.public_derp beats the
#      baked marker, an explicit false included), the STUN hand-off marker.
#   C. the node firewall (hugmesh-coturn-firewall) run against nft/firewall-cmd
#      stubs: the STUN marker admits EXACTLY one `udp dport 3478 accept` line
#      ahead of the drops and one firewalld 3478/udp, nothing else; a malformed
#      marker admits nothing.
#   D. option parity: every builder parses --headscale-public-derp and bakes the
#      marker; gen-provision-keys.sh, the Makefile, the Studio and the local
#      stack carry the same knob (the gen-provision-keys and local-stack renders
#      are run, not grepped).
#   E. negative controls: each mutation of a copy of the tree must turn A-D red.
#
# Offline, no docker. The live proof (pinned headscale on an --internal docker
# network) is tests/scripts/test-headscale-embedded-derp-live.sh.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELF="${REPO}/tests/scripts/test-headscale-embedded-derp.sh"
ROOT="${DERP_GUARD_ROOT:-${REPO}}"
. "${REPO}/tests/lib/guard-preflight.sh"
guard_require_tools python3 jq awk sed

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
PUBLIC_URL="https://controlplane.tailscale.com/derpmap/default"
python3 -c 'import yaml' 2>/dev/null || guard_require_capability "python3 PyYAML is missing (the config checks parse YAML)"

# ── A. every shipped headscale config ────────────────────────────────────────
echo "-- A. shipped headscale configs: embedded relay on, no public map --"
if [ "${ROOT}" = "${REPO}" ] && git -C "${ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "${ROOT}" ls-files > "${WORK}/files"
else
    (cd "${ROOT}" && find . -type f | sed 's|^\./||') > "${WORK}/files"
fi
: > "${WORK}/configs"
while IFS= read -r f; do
    case "${f}" in *.yaml|*.yml|*.tmpl) ;; *) continue ;; esac
    case "${f}" in tests/stack/.uidist/*|out/*) continue ;; esac
    [ -f "${ROOT}/${f}" ] || continue
    grep -a -E '^server_url:' "${ROOT}/${f}" >/dev/null 2>&1 || continue
    grep -a -E '^derp:' "${ROOT}/${f}" >/dev/null 2>&1 || continue
    echo "${f}" >> "${WORK}/configs"
done < "${WORK}/files"
for must in specs/etc/headscale/config.yaml keys-template/headscale/config.yaml tests/stack/headscale/config.yaml.tmpl; do
    grep -a -x -F "${must}" "${WORK}/configs" >/dev/null \
        && ok "discovered shipped config ${must}" \
        || bad "discovery missed ${must} (or it no longer has server_url:/derp:) — the checks below would be blind to it"
done
while IFS= read -r f; do
    python3 - "${ROOT}/${f}" "${f}" "${PUBLIC_URL}" <<'PY'
import re, sys, yaml
path, name, public = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
def res(cond, msg):
    print(("  PASS " if cond else "  FAIL ") + name + ": " + msg)
# The local-stack template carries an @@MARKER@@ splice point; YAML cannot parse a
# plain scalar that starts with '@', so stand a URL in for it.
c = yaml.safe_load(re.sub(r"@@[A-Z_]+@@", "http://marker.invalid", text))
d = (c or {}).get("derp") or {}
s = d.get("server") or {}
res(s.get("enabled") is True, "derp.server.enabled is true (got %r)" % s.get("enabled"))
rid = s.get("region_id")
res(isinstance(rid, int) and 900 <= rid <= 999, "derp.server.region_id is in the private 900-999 block (got %r)" % rid)
for k in ("region_code", "region_name"):
    res(isinstance(s.get(k), str) and s.get(k).strip() != "", "derp.server.%s is set" % k)
stun = str(s.get("stun_listen_addr") or "")
res(stun.rsplit(":", 1)[-1] == "3478", "derp.server.stun_listen_addr listens on 3478 (got %r)" % stun)
pk = str(s.get("private_key_path") or "")
res(pk.startswith("/var/lib/headscale/") and pk != "/var/lib/headscale/noise_private.key",
    "derp.server.private_key_path persists under /var/lib/headscale, apart from the noise key (got %r)" % pk)
res(s.get("automatically_add_embedded_derp_region") is True, "derp.server.automatically_add_embedded_derp_region is true")
res("ipv4" not in s and "ipv6" not in s, "derp.server ipv4/ipv6 left unset (clients resolve the server_url host)")
res(d.get("urls") == [], "derp.urls is [] (no public map by default; got %r)" % d.get("urls"))
res(d.get("paths") in ([], None), "derp.paths is empty (got %r)" % d.get("paths"))
res(d.get("auto_update_enabled") is False, "derp.auto_update_enabled is false (nothing to fetch; got %r)" % d.get("auto_update_enabled"))
code = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
res(public not in code and "controlplane.tailscale.com" not in code,
    "no public Tailscale DERP map URL outside comments")
PY
done < "${WORK}/configs" > "${WORK}/a.out" 2>&1
while IFS= read -r l; do
    case "${l}" in "  PASS "*) ok "${l#  PASS }" ;; "  FAIL "*) bad "${l#  FAIL }" ;; *) bad "config check crashed: ${l}" ;; esac
done < "${WORK}/a.out"

# ── B. keys-provision: provision_headscale_derp, run for real ────────────────
echo "-- B. keys-provision provision_headscale_derp --"
PROV="${ROOT}/specs/etc/keys-provision/provision.sh"
awk '/^# ── headscale DERP relay: offline-first/{f=1} /^provision_headscale\(\) \{/{f=0} f' "${PROV}" > "${WORK}/derp-fns.sh"
if grep -a -E '^provision_headscale_derp\(\) \{' "${WORK}/derp-fns.sh" >/dev/null; then
    ok "provision.sh defines provision_headscale_derp ahead of provision_headscale"
else
    bad "provision.sh has no provision_headscale_derp block ahead of provision_headscale"
fi
awk '/^provision_headscale\(\) \{/{f=1} f&&/^}/{exit} f' "${PROV}" > "${WORK}/ph.sh"
awk '/^provision_headscale_config\(\) \{/{f=1} f&&/^}/{exit} f' "${PROV}" > "${WORK}/phc.sh"
if grep -a -E '^[[:space:]]+\[ -f /etc/headscale/config\.yaml \] && provision_headscale_config /etc/headscale/config\.yaml$' "${WORK}/ph.sh" >/dev/null \
   && grep -a -E '^[[:space:]]+provision_headscale_derp "\$\{cfg\}"$' "${WORK}/phc.sh" >/dev/null \
   && grep -a -E '^[[:space:]]+provision_headscale_tls "\$\{cfg\}" "\$\{endpoint\}"$' "${WORK}/phc.sh" >/dev/null; then
    ok "provision_headscale runs provision_headscale_config on /etc/headscale/config.yaml, which runs the TLS and DERP steps"
else
    bad "provision_headscale no longer runs provision_headscale_config -> provision_headscale_tls + provision_headscale_derp"
fi
grep -a -F 'rm -f "${HEADSCALE_DERP_STUN_MARKER}"' "${WORK}/ph.sh" >/dev/null \
    && ok "a node with headscale disabled drops the STUN marker" \
    || bad "the headscale-disabled path leaves a stale STUN marker behind"
cat > "${WORK}/b-run.sh" <<'EOF'
# usage: b-run.sh <fns> <config> <provision.json> <public-marker-content|-> <stun-marker>
set -uo pipefail
log()  { echo "[log] $*"; }; warn() { echo "[warn] $*"; }
jqm()  { jq -r "$1" "${MANIFEST}" 2>/dev/null; }
. "$1"
HEADSCALE_PUBLIC_DERP_MARKER="$3.public-marker"; HEADSCALE_DERP_STUN_MARKER="$5"; MANIFEST="$3"
if [ "$4" = "-" ]; then rm -f "${HEADSCALE_PUBLIC_DERP_MARKER}"; else printf '%s\n' "$4" > "${HEADSCALE_PUBLIC_DERP_MARKER}"; fi
provision_headscale_derp "$2"
EOF
derp_case() {  # derp_case <label> <src-config> <provision.json body> <marker|-> -> prints "code|name|urls|auto|stun"
    local d="${WORK}/b-$1"
    mkdir -p "${d}"
    cp "$2" "${d}/config.yaml"
    printf '%s\n' "$3" > "${d}/provision.json"
    bash "${WORK}/b-run.sh" "${WORK}/derp-fns.sh" "${d}/config.yaml" "${d}/provision.json" "$4" "${d}/stun" > "${d}/log" 2>&1
    python3 - "${d}/config.yaml" "${d}/stun" <<'PY'
import os, sys, yaml
d = (yaml.safe_load(open(sys.argv[1])) or {}).get("derp") or {}
s = d.get("server") or {}
stun = open(sys.argv[2]).read().strip() if os.path.exists(sys.argv[2]) else "-"
print("%s|%s|%s|%s|%s" % (s.get("region_code"), s.get("region_name"), ",".join(d.get("urls") or []) or "[]",
                          d.get("auto_update_enabled"), stun))
PY
}
for src in specs/etc/headscale/config.yaml keys-template/headscale/config.yaml; do
    s="${ROOT}/${src}"
    got="$(derp_case def "${s}" '{"hugmesh":{"cluster_domain":"Acme.Example"}}' -)"
    [ "${got}" = "acme|acme.example embedded relay|[]|False|3478" ] \
        && ok "${src}: default = region named from the cluster domain, no public map, STUN 3478 handed over" \
        || bad "${src}: default render wrong (got ${got})"
    got="$(derp_case json "${s}" '{"headscale":{"public_derp":true}}' -)"
    [ "${got}" = "hugmesh|hugmesh embedded relay|${PUBLIC_URL}|True|3478" ] \
        && ok "${src}: provision.json .headscale.public_derp=true adds the public map + auto-update" \
        || bad "${src}: KEYS opt-in wrong (got ${got})"
    got="$(derp_case mark "${s}" '{}' true)"
    [ "${got}" = "hugmesh|hugmesh embedded relay|${PUBLIC_URL}|True|3478" ] \
        && ok "${src}: the baked /etc/hugmesh/headscale-public-derp marker opts in" \
        || bad "${src}: baked-marker opt-in wrong (got ${got})"
    got="$(derp_case jfalse "${s}" '{"headscale":{"public_derp":false}}' true)"
    [ "${got}" = "hugmesh|hugmesh embedded relay|[]|False|3478" ] \
        && ok "${src}: an explicit provision.json false outranks the baked marker" \
        || bad "${src}: explicit false lost to the marker (got ${got}) — jq's // treats false as absent"
    got="$(derp_case bogus "${s}" '{"hugmesh":{"cluster_domain":"evil\"|x"}}' -)"
    [ "${got}" = "hugmesh|hugmesh embedded relay|[]|False|3478" ] \
        && ok "${src}: a malformed cluster domain keeps the baked region name (fail-closed)" \
        || bad "${src}: malformed domain reached the config (got ${got})"
done
mkdir -p "${WORK}/b-off"
sed -e '/^derp:/,/^[a-z]/ s/^    enabled: true/    enabled: false/' "${ROOT}/specs/etc/headscale/config.yaml" > "${WORK}/b-off/src.yaml"
echo stale > "${WORK}/b-off/stun"
got="$(derp_case off "${WORK}/b-off/src.yaml" '{}' -)"
case "${got}" in *"|[]|False|3478") ok "embedded server off with no DERP map of its own is turned back on (headscale would refuse to start)" ;;
                 *) bad "embedded server off + no map left as is (got ${got})" ;; esac
mkdir -p "${WORK}/b-own"
sed -e '/^derp:/,/^[a-z]/ s/^    enabled: true/    enabled: false/' -e 's|^  urls: \[\]$|  urls: ["https://derp.example.test/map.json"]|' \
    "${ROOT}/specs/etc/headscale/config.yaml" > "${WORK}/b-own/src.yaml"
echo stale > "${WORK}/b-own/stun"
got="$(derp_case own "${WORK}/b-own/src.yaml" '{}' -)"
case "${got}" in *"|https://derp.example.test/map.json|False|-") ok "embedded server off WITH relays of its own stays off, and no STUN port is handed to the firewall" ;;
                 *) bad "an operator's own-relay config (embedded off) was changed or still hands over STUN (got ${got})" ;; esac
mkdir -p "${WORK}/b-custom"
sed -e 's|^  urls: \[\]$|  urls: ["https://derp.example.test/map.json"]|' "${ROOT}/specs/etc/headscale/config.yaml" > "${WORK}/b-custom/src.yaml"
got="$(derp_case custom "${WORK}/b-custom/src.yaml" '{"headscale":{"public_derp":true}}' -)"
case "${got}" in *"|https://derp.example.test/map.json,${PUBLIC_URL}|True|3478") ok "an operator's own derp.urls are kept, the opt-in adds the public map after them" ;;
                 *) bad "the opt-in lost an operator's derp.urls or did not add the public map (got ${got})" ;; esac
got="$(derp_case custom2 "${WORK}/b-custom/src.yaml" '{"headscale":{"public_derp":false}}' -)"
case "${got}" in *"|https://derp.example.test/map.json|False|3478") ok "...and opt-in off leaves an operator's own derp.urls as written" ;;
                 *) bad "opt-in off changed an operator's derp.urls (got ${got})" ;; esac
# Declarative: the opt-in turned off on a config it had turned on takes the public map out.
mkdir -p "${WORK}/b-sticky"
cp "${ROOT}/specs/etc/headscale/config.yaml" "${WORK}/b-sticky/config.yaml"
printf '%s\n' '{"headscale":{"public_derp":true}}' > "${WORK}/b-sticky/on.json"
printf '%s\n' '{"headscale":{"public_derp":false}}' > "${WORK}/b-sticky/off.json"
bash "${WORK}/b-run.sh" "${WORK}/derp-fns.sh" "${WORK}/b-sticky/config.yaml" "${WORK}/b-sticky/on.json" - "${WORK}/b-sticky/stun" > "${WORK}/b-sticky/on.log" 2>&1
bash "${WORK}/b-run.sh" "${WORK}/derp-fns.sh" "${WORK}/b-sticky/config.yaml" "${WORK}/b-sticky/off.json" - "${WORK}/b-sticky/stun" > "${WORK}/b-sticky/off.log" 2>&1
if grep -a -F "${PUBLIC_URL}" "${WORK}/b-sticky/config.yaml" >/dev/null || grep -a -E '^  auto_update_enabled: true' "${WORK}/b-sticky/config.yaml" >/dev/null; then
    bad "opt-in on then off on the same config left the public map (or auto-update) in place"
else
    ok "opt-in on then off on the same config: the public map and auto-update are taken back out (declarative)"
fi
# The pre-2026-11-10 KEYS shape (embedded off, only the public map) is migrated.
mkdir -p "${WORK}/b-old"
cat > "${WORK}/b-old/src.yaml" <<YAML
server_url: http://placeholder:8080
listen_addr: 0.0.0.0:8080
derp:
  server:
    enabled: false
  urls:
    - ${PUBLIC_URL}
  auto_update_enabled: true
  update_frequency: 24h

# a column-0 comment that belongs to the next key
disable_check_updates: true
YAML
got="$(derp_case old "${WORK}/b-old/src.yaml" '{}' -)"
[ "${got}" = "hugmesh|hugmesh embedded relay|[]|False|3478" ] \
    && ok "an old-shape KEYS config (embedded off, public map only) is migrated: embedded on, no public map, STUN 3478" \
    || bad "old-shape KEYS config not migrated (got ${got})"
cmp -s "${WORK}/b-old/src.yaml" "${WORK}/b-old/config.yaml.derp.bak" \
    && ok "...and the config as it was is kept in <config>.derp.bak" || bad "no faithful .derp.bak of the migrated config"
python3 - "${WORK}/b-old/config.yaml" <<'PY2' && ok "...and everything outside the derp: block survives (the next key keeps its comment)" || bad "the migration damaged the rest of the config"
import sys, yaml
t = open(sys.argv[1]).read()
c = yaml.safe_load(t)
assert c["disable_check_updates"] is True and c["listen_addr"] == "0.0.0.0:8080"
assert "# a column-0 comment that belongs to the next key\ndisable_check_updates: true" in t
PY2
cp "${WORK}/b-old/config.yaml" "${WORK}/b-old/again.yaml"
derp_case again "${WORK}/b-old/again.yaml" '{}' - >/dev/null
cmp -s "${WORK}/b-old/again.yaml" "${WORK}/b-again/config.yaml" && [ ! -e "${WORK}/b-again/config.yaml.derp.bak" ] \
    && ok "the rendered block is a fixed point (a second run changes nothing and keeps no .bak)" \
    || bad "a second render changed the config again"

# ── B2. keys-provision: HTTPS for the embedded relay, run for real ───────────
echo "-- B2. keys-provision provision_headscale_tls / resolve_endpoint / control-URL checks --"
command -v openssl >/dev/null 2>&1 || guard_require_capability "openssl is missing (the TLS checks issue real certificates)"
T="${WORK}/tls"; mkdir -p "${T}/stick/certs" "${T}/other"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj "/CN=guard mesh CA" \
    -keyout "${T}/stick/certs/cluster-ca.key" -out "${T}/stick/certs/cluster-ca.crt" >/dev/null 2>&1
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj "/CN=another CA" \
    -keyout "${T}/other/ca.key" -out "${T}/other/ca.crt" >/dev/null 2>&1
printf '%s\n' '{"hugmesh":{"cluster_domain":"acme.example"},"nodes":[{"name":"hm-pki","ip":"10.0.0.10","role":"pki"}]}' > "${T}/stick/provision.json"
{
    # resolve_control_endpoint calls the LAN-first helpers #1004 added; extract them too
    for fn in resolve_endpoint resolve_control_endpoint ipv4_literal resolve_pki_lan_ip node_is_public \
              control_endpoint_mesh_is_live; do sed -n "/^${fn}() {/,/^}/p" "${PROV}"; done
} > "${WORK}/ep-fns.sh"
cat > "${T}/run.sh" <<'EOF'
# usage: run.sh <fns> <ep-fns> <config> <stick> <server_url> <out-dir>
set -uo pipefail
log()  { echo "[log] $*"; }; warn() { echo "[warn] $*"; }
jqm()  { jq -r "$1" "${MANIFEST}" 2>/dev/null; }
. "$1"; . "$2"
BASE="$4"; MANIFEST="$4/provision.json"
HEADSCALE_TLS_CERT="$6/tls.crt"; HEADSCALE_TLS_KEY="$6/tls.key"
HEADSCALE_TLS_INSTALLED_CA_CRT=/nonexistent-ca.crt; HEADSCALE_TLS_INSTALLED_CA_KEY=/nonexistent-ca.key
HEADSCALE_PUBLIC_DERP_MARKER="$6/pub"; HEADSCALE_DERP_STUN_MARKER="$6/stun"
EP="$5"; resolve_endpoint() { echo "${EP}"; }
resolve_magic_dns_domain() { :; }
# A fixed node, not the host running this guard: one LAN address, no loopback in the
# interface list (so loopback in the certificate is the issuer's doing), no tailnet yet.
ip() { printf '%s\n' "2: eth0    inet 10.20.30.40/24 brd 10.20.30.255 scope global eth0" "2: eth0    inet6 fe80::1/64 scope link"; }
hostname() { echo hm-node; }
tailscale() { return 1; }
provision_headscale_config "$3"
EOF
tls_case() {  # tls_case <label> <server_url> [stick dir] -> "<served server_url>|<tls_cert_path>"
    local d="${T}/$1" stick="${3:-${T}/stick}"
    mkdir -p "${d}"
    cp "${ROOT}/specs/etc/headscale/config.yaml" "${d}/config.yaml"
    bash "${T}/run.sh" "${WORK}/derp-fns.sh" "${WORK}/ep-fns.sh" "${d}/config.yaml" "${stick}" "$2" "${d}" > "${d}/log" 2>&1
    printf '%s|%s\n' "$(sed -n 's/^server_url:[[:space:]]*//p' "${d}/config.yaml")" "$(sed -n 's/^tls_cert_path:[[:space:]]*//p' "${d}/config.yaml" | tr -d '"')"
}
got="$(tls_case def https://10.20.30.40:8080)"
[ "${got}" = "https://10.20.30.40:8080|${T}/def/tls.crt" ] \
    && ok "https://<LAN IP>:<listen port>: headscale serves TLS itself (tls_cert_path set, server_url kept)" \
    || bad "default https server_url not served with TLS (got ${got}): $(grep -E 'TLS' "${T}/def/log" | tr '\n' ' ')"
openssl verify -CAfile "${T}/stick/certs/cluster-ca.crt" "${T}/def/tls.crt" >/dev/null 2>&1 \
    && ok "...with a serving certificate issued from the stick's mesh CA" || bad "the serving certificate does not chain to the stick's CA"
for want in 10.20.30.40 127.0.0.1 10.0.0.10; do
    openssl x509 -in "${T}/def/tls.crt" -noout -checkip "${want}" 2>/dev/null | grep -F 'does match' >/dev/null \
        && ok "...naming IP ${want}" || bad "the serving certificate does not name IP ${want}"
done
openssl x509 -in "${T}/def/tls.crt" -noout -checkhost headscale.hugmesh-pki.svc.cluster.local 2>/dev/null | grep -F 'does match' >/dev/null \
    && ok "...and the in-cluster headscale Service name (an in-cluster https client can verify it)" \
    || bad "the serving certificate does not name headscale.hugmesh-pki.svc.cluster.local"
openssl x509 -in "${T}/def/tls.crt" -noout -checkhost hm-node 2>/dev/null | grep -F 'does match' >/dev/null \
  && ! openssl x509 -in "${T}/def/tls.crt" -noout -ext subjectAltName 2>/dev/null | grep -i 'FE80' >/dev/null \
    && ok "...and the host name, but no link-local address (no client can dial one without a zone)" \
    || bad "the serving certificate's names are off: $(openssl x509 -in "${T}/def/tls.crt" -noout -ext subjectAltName 2>/dev/null | tail -1)"
openssl x509 -in "${T}/def/tls.crt" -noout -ext extendedKeyUsage,basicConstraints 2>/dev/null | tr -d ' \n' | grep -F 'TLSWebServerAuthentication' \
  | grep -F 'CA:FALSE' >/dev/null && ok "...as a serverAuth leaf (CA:FALSE)" || bad "the serving certificate is not a serverAuth leaf"
[ "$(stat -c %a "${T}/def/tls.key" 2>/dev/null)" = 600 ] && ok "...whose key is 0600" || bad "the serving key is not 0600"
got="$(tls_case http http://10.20.30.40:8080)"
{ [ "${got}" = "http://10.20.30.40:8080|" ] && grep -F 'embedded DERP relay is NOT usable' "${T}/http/log" >/dev/null; } \
    && ok "an explicit http:// server_url is honoured (no TLS) and the relay limit is said" \
    || bad "explicit http:// handled wrongly (got ${got})"
got="$(tls_case front https://scale.acme.example)"
{ [ "${got}" = "https://scale.acme.example|" ] && grep -F 'names a TLS front' "${T}/front/log" >/dev/null; } \
    && ok "https:// on another port (a TLS front): headscale stays plain behind it" \
    || bad "a TLS-front server_url handled wrongly (got ${got})"
mkdir -p "${T}/nostick"; cp "${T}/stick/provision.json" "${T}/nostick/"
got="$(tls_case noca https://10.20.30.40:8080 "${T}/nostick")"
{ [ "${got}" = "http://10.20.30.40:8080|" ] && grep -F 'NO serving certificate' "${T}/noca/log" >/dev/null; } \
    && ok "no CA key and no pre-issued certificate: plain http at the same address, said loudly (never a dead https URL)" \
    || bad "no-material fallback wrong (got ${got})"
mkdir -p "${T}/mismatch/certs"; cp "${T}/stick/provision.json" "${T}/mismatch/"
cp "${T}/stick/certs/cluster-ca.crt" "${T}/mismatch/certs/"; cp "${T}/other/ca.key" "${T}/mismatch/certs/cluster-ca.key"
got="$(tls_case mism https://10.20.30.40:8080 "${T}/mismatch")"
[ "${got}" = "http://10.20.30.40:8080|" ] && grep -F 'is not the key of' "${T}/mism/log" >/dev/null \
    && ok "a CA key that is not the CA certificate's key is refused" || bad "a mismatched CA key was used (got ${got})"
mkdir -p "${T}/pre/headscale"; cp "${T}/stick/provision.json" "${T}/pre/"
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=pre -keyout "${T}/pre/headscale/tls.key" -out "${T}/pre/csr" >/dev/null 2>&1
printf 'subjectAltName=IP:10.20.30.40,IP:127.0.0.1\n' > "${T}/pre/ext"
openssl x509 -req -in "${T}/pre/csr" -CA "${T}/stick/certs/cluster-ca.crt" -CAkey "${T}/stick/certs/cluster-ca.key" -set_serial 9 -days 5 \
    -extfile "${T}/pre/ext" -out "${T}/pre/headscale/tls.crt" >/dev/null 2>&1
got="$(tls_case prein https://10.20.30.40:8080 "${T}/pre")"
[ "${got}" = "https://10.20.30.40:8080|${T}/prein/tls.crt" ] && cmp -s "${T}/pre/headscale/tls.crt" "${T}/prein/tls.crt" \
    && ok "no CA key but a pre-issued headscale/tls.crt naming the host: that pair is served" \
    || bad "a covering pre-issued certificate was not used (got ${got})"
got="$(tls_case preout https://10.20.30.99:8080 "${T}/pre")"
[ "${got}" = "http://10.20.30.99:8080|" ] && grep -F 'does not name 10.20.30.99' "${T}/preout/log" >/dev/null \
    && ok "a pre-issued certificate that does not name the host is not served (plain http, said)" \
    || bad "a non-covering pre-issued certificate handled wrongly (got ${got})"
cp "${ROOT}/specs/etc/headscale/config.yaml" "${T}/own.yaml"
sed -i 's|^tls_cert_path:.*|tls_cert_path: /etc/headscale/own.crt|' "${T}/own.yaml"
mkdir -p "${T}/own"; cp "${T}/own.yaml" "${T}/own/config.yaml"
bash "${T}/run.sh" "${WORK}/derp-fns.sh" "${WORK}/ep-fns.sh" "${T}/own/config.yaml" "${T}/stick" https://10.20.30.40:8080 "${T}/own" > "${T}/own/log" 2>&1
grep -E '^tls_cert_path: /etc/headscale/own.crt$' "${T}/own/config.yaml" >/dev/null && [ ! -e "${T}/own/tls.crt" ] \
    && ok "a config that names its own certificate is left as written" || bad "an operator's own tls_cert_path was overridden"
# resolve_endpoint / resolve_control_endpoint defaults: https.
ep="$( log() { :; }; jqm() { jq -r "$1" "${MANIFEST}" 2>/dev/null; }; . "${WORK}/ep-fns.sh"
       resolve_lan_ip() { echo 192.168.5.6; }; MANIFEST=/dev/null; resolve_endpoint )"
[ "${ep}" = "https://192.168.5.6:8080" ] && ok "resolve_endpoint's default is https://<LAN IP>:8080" || bad "resolve_endpoint default is '${ep}'"
# A worker's default (the pki node in .nodes[]) dials http:// since #1004 (LAN-first,
# tests/scripts/test-control-endpoint-lan-first.sh): control_url_tls_migrate then moves
# it to https:// when the pki node's headscale serves TLS, which this suite's section
# A/B proves it does by default, and keeps it joining when that node has no certificate.
ep="$( log() { :; }; warn() { :; }; jqm() { jq -r "$1" "${MANIFEST}" 2>/dev/null; }; . "${WORK}/ep-fns.sh"
       MANIFEST="${T}/stick/provision.json"; resolve_control_endpoint )"
[ "${ep}" = "http://10.0.0.10:8080" ] && ok "resolve_control_endpoint's default (the pki node in .nodes[]) is http://, upgraded by control_url_tls_migrate" \
    || bad "resolve_control_endpoint default is '${ep}'"
grep -a -F 'control_url_tls_migrate "${login}"' "${PROV}" >/dev/null \
    && ok "the login URL goes through control_url_tls_migrate (http:// -> https:// when TLS answers)" \
    || bad "the login URL no longer passes through control_url_tls_migrate"
# publish_cp_dns_record's re-issue: the tailnet address joins the certificate before the restart.
(
    log() { :; }; warn() { echo "[warn] $*"; }; jqm() { jq -r "$1" "${MANIFEST}" 2>/dev/null; }
    . "${WORK}/derp-fns.sh"
    BASE="${T}/stick"; MANIFEST="${T}/stick/provision.json"
    HEADSCALE_TLS_CERT="${T}/def/tls.crt"; HEADSCALE_TLS_KEY="${T}/def/tls.key"
    HEADSCALE_TLS_INSTALLED_CA_CRT=/nonexistent-ca.crt; HEADSCALE_TLS_INSTALLED_CA_KEY=/nonexistent-ca.key
    ip() { printf '%s\n' "2: eth0    inet 10.20.30.40/24 scope global eth0"; }; hostname() { echo hm-node; }; tailscale() { return 1; }
    HEADSCALE_CONFIG="${T}/def/config.yaml" headscale_tls_cover_address 100.64.0.7
) > "${T}/cover.log" 2>&1
openssl x509 -in "${T}/def/tls.crt" -noout -checkip 100.64.0.7 2>/dev/null | grep -F 'does match' >/dev/null \
  && openssl x509 -in "${T}/def/tls.crt" -noout -checkip 10.20.30.40 2>/dev/null | grep -F 'does match' >/dev/null \
    && ok "headscale_tls_cover_address re-issues with the tailnet address (and keeps the server_url host)" \
    || bad "the tailnet address was not added: $(tr '\n' ' ' < "${T}/cover.log")"
grep -a -E '^[[:space:]]+headscale_tls_cover_address "\$\{tip\}"' "${PROV}" >/dev/null \
    && ok "publish_cp_dns_record calls headscale_tls_cover_address before its headscale restart" \
    || bad "publish_cp_dns_record never adds the tailnet address to the certificate"

# ── C. node firewall: exactly 3478/udp, nothing else ─────────────────────────
echo "-- C. hugmesh-coturn-firewall admits the STUN port and nothing else --"
FW="${ROOT}/specs/usr/sbin/hugmesh-coturn-firewall"
mkdir -p "${WORK}/fw/bin"
cat > "${WORK}/fw/bin/nft" <<'EOF'
#!/bin/bash
[ "$1" = "-f" ] && cp "$2" "${NFT_CAPTURE:-/dev/null}"
exit 0
EOF
cat > "${WORK}/fw/bin/firewall-cmd" <<'EOF'
#!/bin/bash
case "$1" in
  --state) exit 0 ;;
  --get-default-zone) echo drop; exit 0 ;;
esac
for a in "$@"; do case "$a" in
  --query-port=*)  grep -a -E "^(ADD|REMOVE) ${a#--query-port=}\$" "${FWCMD_LOG:-/dev/null}" 2>/dev/null | tail -1 | grep -a '^ADD' >/dev/null; exit $? ;;
  --add-port=*)    echo "ADD ${a#--add-port=}"       >> "${FWCMD_LOG:-/dev/null}"; exit 0 ;;
  --remove-port=*) echo "REMOVE ${a#--remove-port=}" >> "${FWCMD_LOG:-/dev/null}"; exit 0 ;;
esac; done
exit 0
EOF
chmod +x "${WORK}/fw/bin/nft" "${WORK}/fw/bin/firewall-cmd"
fw_run() {  # fw_run <label> <stun-marker-content|-> <coturn-public: yes|no>
    # One fixed marker location for every run, so the rendered rulesets differ only
    # by what the markers SAY; comments and blank lines are not rules.
    local d="${WORK}/fw/$1" m="${WORK}/fw/m"
    mkdir -p "${d}" "${m}"
    : > "${d}/fw.log"
    if [ "$2" = "-" ]; then rm -f "${m}/stun"; else printf '%s\n' "$2" > "${m}/stun"; fi
    if [ "$3" = yes ]; then touch "${m}/public"; else rm -f "${m}/public"; fi
    NFT_CAPTURE="${d}/rules.nft" FWCMD_LOG="${FW_SHARED_LOG:-${d}/fw.log}" PATH="${WORK}/fw/bin:${PATH}" \
        HUGMESH_COTURN_PUBLIC_MARKER="${m}/public" HUGMESH_HEADSCALE_STUN_MARKER="${m}/stun" \
        HUGMESH_HEADSCALE_STUN_FW_STATE="${FW_STATE:-${d}/stun-fw-state}" \
        HUGMESH_FIREWALL_HEALTH_DIR="${d}/health" bash "${FW}" > "${d}/out" 2>&1
    sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "${d}/rules.nft" > "${d}/rules.body" 2>/dev/null || : > "${d}/rules.body"
}
fw_run none - no
fw_run stun 3478 no
fw_run bad '3478; tcp dport 22 accept' no
fw_run both 3478 yes
grep -a -E 'udp dport \{ 3478, 5349 \} drop' "${WORK}/fw/none/rules.body" >/dev/null \
    && ok "no marker: the coturn backstop still drops 3478/udp (unchanged default)" \
    || bad "no marker: the default coturn drops are gone"
grep -a -E 'dport 3478 accept' "${WORK}/fw/none/rules.body" >/dev/null \
    && bad "no marker: 3478 is admitted anyway" || ok "no marker: nothing admits 3478"
diff "${WORK}/fw/none/rules.body" "${WORK}/fw/stun/rules.body" | grep -a -E '^[<>]' > "${WORK}/fw/delta" || true
if [ "$(wc -l < "${WORK}/fw/delta")" -eq 1 ] && grep -a -E '^> +udp dport 3478 accept$' "${WORK}/fw/delta" >/dev/null; then
    ok "STUN marker adds EXACTLY one rule: udp dport 3478 accept"
else
    bad "STUN marker changed the ruleset by more (or other) than one udp 3478 accept: $(tr '\n' ' ' < "${WORK}/fw/delta")"
fi
acc="$(grep -a -n -E 'udp dport 3478 accept' "${WORK}/fw/stun/rules.body" | head -1 | cut -d: -f1)"
drp="$(grep -a -n -E 'udp dport \{ 3478, 5349 \} drop' "${WORK}/fw/stun/rules.body" | head -1 | cut -d: -f1)"
if [ -n "${acc}" ] && [ -n "${drp}" ] && [ "${acc}" -lt "${drp}" ]; then
    ok "the STUN accept sits ahead of the coturn drops (first match wins)"
else
    bad "the STUN accept is missing or after the drop (accept@${acc:-none} drop@${drp:-none})"
fi
if grep -a -x 'ADD 3478/udp' "${WORK}/fw/stun/fw.log" >/dev/null \
   && [ "$(grep -a -c '^ADD ' "${WORK}/fw/stun/fw.log")" -eq 1 ] \
   && ! grep -a -x 'REMOVE 3478/udp' "${WORK}/fw/stun/fw.log" >/dev/null; then
    ok "firewalld: the marker admits 3478/udp, only it, and the coturn pass does not remove it"
else
    bad "firewalld admission wrong: $(tr '\n' ' ' < "${WORK}/fw/stun/fw.log")"
fi
if cmp -s "${WORK}/fw/none/rules.body" "${WORK}/fw/bad/rules.body" && ! grep -a '^ADD ' "${WORK}/fw/bad/fw.log" >/dev/null; then
    ok "a malformed STUN marker admits nothing (fail-closed)"
else
    bad "a malformed STUN marker changed the firewall"
fi
grep -a -F 'both want 3478/udp' "${WORK}/fw/both/out" >/dev/null \
    && ok "coturn-public + headscale STUN on one node is called out" \
    || bad "coturn-public + headscale STUN on one node passes silently"
# firewalld across marker changes (one stateful zone): 3478, then 3479, then no marker.
FW_SHARED_LOG="${WORK}/fw/seq.log"; FW_STATE="${WORK}/fw/seq.state"; : > "${FW_SHARED_LOG}"
fw_run seq1 3478 no; fw_run seq2 3479 no
fw_admitted() { grep -a -E "^(ADD|REMOVE) $1\$" "${FW_SHARED_LOG}" | tail -1 | grep -a '^ADD' >/dev/null; }
if fw_admitted 3479/udp && ! fw_admitted 3478/udp; then
    ok "firewalld: a moved STUN port (3478 -> 3479) admits the new port and takes the old one back out"
else
    bad "firewalld after 3478 -> 3479: $(tr '\n' ' ' < "${FW_SHARED_LOG}")"
fi
fw_run seq3 - no
if ! fw_admitted 3479/udp && ! fw_admitted 3478/udp && [ ! -e "${FW_STATE}" ]; then
    ok "firewalld: a removed marker takes the last admitted STUN port back out (no stale port)"
else
    bad "firewalld after the marker went away: $(tr '\n' ' ' < "${FW_SHARED_LOG}")"
fi
: > "${FW_SHARED_LOG}"; rm -f "${FW_STATE}"
fw_run seq4 3478 yes; fw_run seq5 3479 yes
fw_admitted 3478/udp && fw_admitted 3479/udp \
    && ok "firewalld: a STUN port that coturn-public also owns (3478) is NOT removed when headscale's moves" \
    || bad "firewalld removed coturn's 3478/udp along with headscale's old STUN port: $(tr '\n' ' ' < "${FW_SHARED_LOG}")"
unset FW_SHARED_LOG FW_STATE

# ── D. option parity ─────────────────────────────────────────────────────────
echo "-- D. --headscale-public-derp / HEADSCALE_PUBLIC_DERP parity --"
nb=0
for b in "${ROOT}"/build-*-stage4.sh; do
    [ -f "${b}" ] || continue
    nb=$((nb+1)); n="$(basename "${b}")"
    miss=""
    grep -a -F -- '--headscale-public-derp) HEADSCALE_PUBLIC_DERP=true; shift ;;' "${b}" >/dev/null || miss="${miss} parse"
    grep -a -F 'HEADSCALE_PUBLIC_DERP="${HEADSCALE_PUBLIC_DERP:-false}"' "${b}" >/dev/null || miss="${miss} default"
    grep -a -F 'err "HEADSCALE_PUBLIC_DERP must be true or false' "${b}" >/dev/null || miss="${miss} check"
    grep -a -F 'echo true > "${SYSROOT}/etc/hugmesh/headscale-public-derp"' "${b}" >/dev/null || miss="${miss} bake"
    grep -a -E '^ +--headscale-public-derp( |$)' "${b}" >/dev/null || miss="${miss} usage"
    [ -z "${miss}" ] && ok "${n}: parses, checks, documents and bakes --headscale-public-derp" \
                     || bad "${n}: --headscale-public-derp incomplete (missing:${miss})"
done
[ "${nb}" -ge 10 ] && ok "all ${nb} builders checked" || bad "only ${nb} builders found (expected 10)"
GPK="${ROOT}/scripts/gen-provision-keys.sh"
grep -a -F -- '--headscale-public-derp) HEADSCALE_PUBLIC_DERP=true; shift ;;' "${GPK}" >/dev/null \
  && grep -a -F 'd.setdefault("headscale", {})["public_derp"] = True' "${GPK}" >/dev/null \
    && ok "gen-provision-keys.sh parses --headscale-public-derp and stamps .headscale.public_derp" \
    || bad "gen-provision-keys.sh lacks the opt-in"
MK="${ROOT}/Makefile"
grep -a -F 'BRAND_ENV += HEADSCALE_PUBLIC_DERP=$(HEADSCALE_PUBLIC_DERP)' "${MK}" >/dev/null \
  && grep -a -E "^BRAND_PASS :=.* HEADSCALE_PUBLIC_DERP='\\\$\(HEADSCALE_PUBLIC_DERP\)' " "${MK}" >/dev/null \
  && grep -a -E "^STACK_HEADSCALE_ENV :=.*HEADSCALE_PUBLIC_DERP='\\\$\(HEADSCALE_PUBLIC_DERP\)'" "${MK}" >/dev/null \
    && ok "Makefile threads HEADSCALE_PUBLIC_DERP to the builders, the docker re-invoke and the local stack" \
    || bad "Makefile does not thread HEADSCALE_PUBLIC_DERP everywhere"
SC="${ROOT}/studio/hugmesh_studio/core/config.py"
grep -a -E '^    headscale_public_derp: bool = False' "${SC}" >/dev/null \
  && grep -a -F '"headscale_public_derp": _ALL_PLATFORMS' "${SC}" >/dev/null \
  && grep -a -F 'a += ["--headscale-public-derp"]' "${SC}" >/dev/null \
    && ok "Studio: headscale_public_derp (default off, every platform) emits --headscale-public-derp" \
    || bad "Studio option missing or not emitted"
grep -a -F 'HEADSCALE_PUBLIC_DERP: ${HEADSCALE_PUBLIC_DERP:-false}' "${ROOT}/tests/stack/compose.local.yaml" >/dev/null \
    && ok "local stack compose passes HEADSCALE_PUBLIC_DERP (default false) to hugmesh-headscale" \
    || bad "local stack compose does not pass HEADSCALE_PUBLIC_DERP"
# The local stack's render, run: default keeps urls: [], the opt-in adds the map.
EP="${ROOT}/tests/stack/headscale/entrypoint.sh"
awk '/^render_config\(\) \{/{f=1} f{print} f&&/^}/{exit}' "${EP}" > "${WORK}/rc.sh"
for want in false true; do
    out="${WORK}/stack-${want}.yaml"
    ( log() { :; }; die() { echo "DIE $*"; exit 1; }
      . "${WORK}/rc.sh"
      CONFIG_TMPL="${ROOT}/tests/stack/headscale/config.yaml.tmpl" CONFIG_OUT="${out}" \
          SERVER_URL="https://hs.example.test:8488" PUBLIC_DERP="${want}"
      render_config ) > "${WORK}/stack-${want}.log" 2>&1
    urls="$(python3 -c 'import sys,yaml; print(",".join((yaml.safe_load(open(sys.argv[1]))["derp"].get("urls") or [])) or "[]")' "${out}" 2>/dev/null)"
    if [ "${want}" = false ]; then
        [ "${urls}" = "[]" ] && ok "local stack render: default keeps urls: []" || bad "local stack default render has urls=${urls:-unreadable}"
    else
        [ "${urls}" = "${PUBLIC_URL}" ] && ok "local stack render: HEADSCALE_PUBLIC_DERP=true adds the public map" \
                                       || bad "local stack opt-in render has urls=${urls:-unreadable}"
    fi
done
# gen-provision-keys.sh, run (main tree only: it needs the whole template tree).
if [ "${ROOT}" = "${REPO}" ] && command -v openssl >/dev/null 2>&1 && command -v ssh-keygen >/dev/null 2>&1 \
   && command -v keytool >/dev/null 2>&1; then
    for v in on off; do
        flag=""; [ "${v}" = on ] && flag="--headscale-public-derp"
        NONINTERACTIVE=1 HEADSCALE_PUBLIC_DERP= bash "${GPK}" -o "${WORK}/gpk-${v}" --random --no-device-ssh ${flag} \
            > "${WORK}/gpk-${v}.log" 2>&1 || bad "gen-provision-keys.sh (${v}) failed: $(tail -2 "${WORK}/gpk-${v}.log" | tr '\n' ' ')"
    done
    [ "$(jq -c '.headscale.public_derp' "${WORK}/gpk-on/provision.json" 2>/dev/null)" = "true" ] \
        && ok "gen-provision-keys.sh --headscale-public-derp stamps .headscale.public_derp=true" \
        || bad "gen-provision-keys.sh --headscale-public-derp did not stamp the opt-in"
    [ "$(jq -c '.headscale.public_derp' "${WORK}/gpk-off/provision.json" 2>/dev/null)" = "null" ] \
        && ok "gen-provision-keys.sh without the flag writes no public_derp key (a baked marker still decides)" \
        || bad "gen-provision-keys.sh without the flag wrote a public_derp value"
    HEADSCALE_PUBLIC_DERP=maybe NONINTERACTIVE=1 bash "${GPK}" -o "${WORK}/gpk-bad" --random --no-device-ssh > "${WORK}/gpk-bad.log" 2>&1 \
        && bad "gen-provision-keys.sh accepted HEADSCALE_PUBLIC_DERP=maybe" \
        || ok "gen-provision-keys.sh refuses HEADSCALE_PUBLIC_DERP=maybe"
    # headscale's serving certificate: the default pki stick carries the CA key (first
    # boot issues it), so nothing is pre-issued; an external CA kept OFF the stick gets
    # it here, for the manifest's addresses plus HEADSCALE_TLS_SANS.
    [ -f "${WORK}/gpk-off/certs/cluster-ca.key" ] && [ ! -e "${WORK}/gpk-off/headscale/tls.crt" ] \
        && ok "gen-provision-keys.sh (default pki): the stick carries its mesh CA key, nothing pre-issued" \
        || bad "gen-provision-keys.sh (default pki): CA key $(ls "${WORK}/gpk-off/certs" 2>&1 | tr '\n' ' '), tls.crt $(ls "${WORK}/gpk-off/headscale" 2>&1 | tr '\n' ' ')"
    mkdir -p "${WORK}/extca"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj "/CN=external CA" \
        -keyout "${WORK}/extca/ca.key" -out "${WORK}/extca/ca.crt" >/dev/null 2>&1
    NONINTERACTIVE=1 HEADSCALE_TLS_SANS="192.168.7.5, pki.lan" HEADSCALE_URL= bash "${GPK}" -o "${WORK}/gpk-ext" --random --no-device-ssh \
        --ca-cert "${WORK}/extca/ca.crt" --ca-key "${WORK}/extca/ca.key" > "${WORK}/gpk-ext.log" 2>&1 \
        || bad "gen-provision-keys.sh (external CA) failed: $(tail -2 "${WORK}/gpk-ext.log" | tr '\n' ' ')"
    if [ ! -e "${WORK}/gpk-ext/certs/cluster-ca.key" ] \
       && openssl verify -CAfile "${WORK}/extca/ca.crt" "${WORK}/gpk-ext/headscale/tls.crt" >/dev/null 2>&1 \
       && openssl x509 -in "${WORK}/gpk-ext/headscale/tls.crt" -noout -checkip 192.168.7.5 | grep -F 'does match' >/dev/null \
       && openssl x509 -in "${WORK}/gpk-ext/headscale/tls.crt" -noout -checkip 127.0.0.1 | grep -F 'does match' >/dev/null \
       && openssl x509 -in "${WORK}/gpk-ext/headscale/tls.crt" -noout -checkip 10.0.0.10 | grep -F 'does match' >/dev/null \
       && [ "$(stat -c %a "${WORK}/gpk-ext/headscale/tls.key")" = 600 ]; then
        ok "gen-provision-keys.sh (external CA off the stick): headscale/tls.{crt,key} issued from that CA for HEADSCALE_TLS_SANS, the .nodes[] pki IP and loopback"
    else
        bad "gen-provision-keys.sh (external CA): no usable pre-issued headscale certificate: $(grep -A1 'headscale TLS' "${WORK}/gpk-ext.log" | tr '\n' ' ')"
    fi
    NONINTERACTIVE=1 bash "${GPK}" -r host -o "${WORK}/gpk-w" --random --no-device-ssh > "${WORK}/gpk-w.log" 2>&1
    grep -F 'certs/cluster-ca.crt is REQUIRED to join the mesh' "${WORK}/gpk-w.log" >/dev/null \
        && ok "gen-provision-keys.sh (worker, no --ca-cert) says the mesh CA is REQUIRED to join" \
        || bad "gen-provision-keys.sh (worker) does not say the mesh CA is required"

elif [ "${ROOT}" = "${REPO}" ]; then
    guard_require_capability "openssl/ssh-keygen/keytool missing — gen-provision-keys.sh cannot be run"
fi

# build-all-roles.sh hands the pki stick's CA CERTIFICATE to every other keys folder
# (its block, run on folders shaped like gen-provision-keys.sh output).
awk '/^    # ── The mesh CA on every other stick/{f=1} f&&/^fi$/{exit} f' "${ROOT}/scripts/build-all-roles.sh" > "${WORK}/bar.sh"
mkdir -p "${WORK}/bar/keys-pki/certs" "${WORK}/bar/keys-backend" "${WORK}/bar/keys-frite"
cp "${T}/stick/certs/cluster-ca.crt" "${T}/stick/certs/cluster-ca.key" "${WORK}/bar/keys-pki/certs/"
( WORK_DIR="${WORK}/bar"; . "${WORK}/bar.sh" ) > "${WORK}/bar.log" 2>&1
if grep -a -F 'The mesh CA on every other stick' "${WORK}/bar.sh" >/dev/null \
   && cmp -s "${WORK}/bar/keys-pki/certs/cluster-ca.crt" "${WORK}/bar/keys-backend/certs/cluster-ca.crt" \
   && cmp -s "${WORK}/bar/keys-pki/certs/cluster-ca.crt" "${WORK}/bar/keys-frite/certs/cluster-ca.crt" \
   && ! grep -rla -- 'PRIVATE KEY' "${WORK}/bar/keys-backend/certs" "${WORK}/bar/keys-frite/certs" >/dev/null 2>&1; then
    ok "build-all-roles.sh: every non-pki keys folder gets the pki stick's CA certificate (and no key)"
else
    bad "build-all-roles.sh did not hand the mesh CA on: $(tr '\n' ' ' < "${WORK}/bar.log")"
fi

# ── F. who can reach the relay ───────────────────────────────────────────────
# headscale 0.23's embedded relay has no client verification (no verify_clients), so
# whoever reaches /derp can relay through it. The shipped doors must not hand it out.
echo "-- F. /derp is not published beyond the mesh --"
FRONT="${ROOT}/tests/stack/tls-front/default.conf"
python3 - "${FRONT}" <<'PY2' > "${WORK}/f.out" 2>&1
import ipaddress, re, sys
t = open(sys.argv[1]).read()
def res(c, m): print(("  PASS " if c else "  FAIL ") + m)
blk = re.search(r"server_name\s+~\^hs\\\.;(.*?)\n\}", t, re.S)
res(blk is not None, "local-stack front: the hs.<domain> server block is found")
b = blk.group(1) if blk else ""
loc = re.search(r"location\s+\^~\s+/derp\s*\{(.*?)\}", b, re.S)
res(loc is not None, "local-stack front: /derp has its own location in the hs.<domain> block")
body = loc.group(1) if loc else ""
rules = re.findall(r"^\s*(allow|deny)\s+([^;]+);", body, re.M)
res(bool(rules) and rules[-1] == ("deny", "all"), "local-stack front: /derp ends in `deny all`")
private = [ipaddress.ip_network(n) for n in ("127.0.0.0/8", "::1/128", "10.0.0.0/8", "172.16.0.0/12",
           "192.168.0.0/16", "100.64.0.0/10", "fc00::/7", "fe80::/10")]
bad_allow = []
for a, v in rules:
    if a != "allow": continue
    try:
        n = ipaddress.ip_network(v.strip(), strict=False)
        if not any(n.version == p.version and n.subnet_of(p) for p in private): bad_allow.append(v)
    except ValueError:
        bad_allow.append(v)
res(bool(rules) and not bad_allow, "local-stack front: /derp admits only loopback, private LAN, tailnet and ULA/link-local sources%s" % (
    "" if not bad_allow else " (also: %s)" % ", ".join(bad_allow)))
res("proxy_pass" in body, "local-stack front: /derp still reaches headscale for those sources")
PY2
while IFS= read -r l; do
    case "${l}" in "  PASS "*) ok "${l#  PASS }" ;; "  FAIL "*) bad "${l#  FAIL }" ;; *) bad "front check crashed: ${l}" ;; esac
done < "${WORK}/f.out"
# The cluster facade (scale.<domain> -> gateways -> headscale) refuses /derp today (the pki
# gateway requires ROLE_SUPERADMIN on the headscale route's Host). Nothing in the cluster
# manifests may route /derp, and no route-access row may open it to the public.
if [ -d "${ROOT}/specs/cluster" ]; then
    hits="$(grep -a -r -n -E '(^|[^A-Za-z0-9_-])/derp([/"'"'"' *]|$)' "${ROOT}/specs/cluster" 2>/dev/null | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*(#|--)' | head -3)"
    [ -z "${hits}" ] && ok "cluster manifests: no route or rule names /derp (the facade does not publish the relay)" \
                     || bad "cluster manifests route /derp: ${hits}"
    SQL="${ROOT}/specs/cluster/manifests/route-access/initdb/20-schema.sql"
    python3 - "${SQL}" <<'PY2' > "${WORK}/f2.out" 2>&1
import re, sys
rows = re.findall(r"\(\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*(true|false)\s*\)", open(sys.argv[1]).read())
def ant(p):
    r = re.escape(p).replace(r"\*\*", ".*").replace(r"\*", "[^/]*")
    return re.compile("^" + r + "$")
openers = ["%s %s" % (g, u) for g, u, role, allow in rows
           if g == "hugmesh-pki-gateway" and role == "PUBLIC" and allow == "true"
           and any(ant(u).match(x) for x in ("/derp", "/derp/probe", "/ts2021"))]
print(("  PASS " if rows and not openers else "  FAIL ") + "route-access seed: no PUBLIC row on the pki gateway matches /derp or /ts2021 (%d rows read%s)" % (
    len(rows), "" if not openers else "; openers: " + ", ".join(openers)))
PY2
    while IFS= read -r l; do
        case "${l}" in "  PASS "*) ok "${l#  PASS }" ;; "  FAIL "*) bad "${l#  FAIL }" ;; *) bad "route-access check crashed: ${l}" ;; esac
    done < "${WORK}/f2.out"
fi

# ── E. negative controls ─────────────────────────────────────────────────────
if [ -z "${DERP_GUARD_NO_CONTROLS:-}" ]; then
    echo "-- E. negative controls: each mutation must turn the guard red --"
    mktree() {
        local d="$1" f
        while IFS= read -r f; do
            mkdir -p "${d}/$(dirname "${f}")"; cp -p "${REPO}/${f}" "${d}/${f}" || return 1
        done <<EOF
specs/etc/headscale/config.yaml
keys-template/headscale/config.yaml
tests/stack/headscale/config.yaml.tmpl
tests/stack/headscale/entrypoint.sh
tests/stack/compose.local.yaml
specs/etc/keys-provision/provision.sh
specs/usr/sbin/hugmesh-coturn-firewall
scripts/gen-provision-keys.sh
scripts/build-all-roles.sh
tests/stack/tls-front/default.conf
specs/cluster/manifests/route-access/initdb/20-schema.sql
Makefile
studio/hugmesh_studio/core/config.py
EOF
        for f in "${REPO}"/build-*-stage4.sh; do cp -p "${f}" "${d}/" || return 1; done
    }
    child() { DERP_GUARD_ROOT="$1" DERP_GUARD_NO_CONTROLS=1 bash "${SELF}" </dev/null 2>&1; }
    pos="${WORK}/ctl-pos"
    if mktree "${pos}" && child "${pos}" > "${WORK}/ctl-pos.log"; then
        ok "positive control: an unmutated copy of the tree passes"
    else
        bad "positive control: an unmutated copy FAILS (the controls below would prove nothing): $(grep -a FAIL "${WORK}/ctl-pos.log" | head -3 | tr '\n' ' ')"
    fi
    n=0
    control() {  # control <label> <file> <old> <new>
        local d="${WORK}/ctl-$((n+=1))"
        mktree "${d}" || { bad "control '$1': could not build the tree"; return; }
        if ! python3 - "${d}/$2" "$3" "$4" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(p, encoding="utf-8").read()
if t.count(old) < 1:
    sys.exit(1)
open(p, "w", encoding="utf-8").write(t.replace(old, new, 1))
PY
        then bad "control '$1': mutation anchor not found in $2 (the control is stale)"; return; fi
        if child "${d}" > "${d}.log"; then
            bad "control '$1' did NOT bite (the guard stayed green)"
        else
            ok "control bites: $1  [red on: $(grep -a 'FAIL' "${d}.log" | head -1 | sed 's/^ *FAIL //' | cut -c1-110)]"
        fi
    }
    NL=$'\n'
    control "node config turns the embedded server off" specs/etc/headscale/config.yaml \
        "  server:${NL}    enabled: true" "  server:${NL}    enabled: false"
    control "KEYS template re-lists the public map" keys-template/headscale/config.yaml \
        "  urls: []" "  urls:${NL}    - ${PUBLIC_URL}"
    control "local-stack template moves STUN off 3478" tests/stack/headscale/config.yaml.tmpl \
        'stun_listen_addr: "0.0.0.0:3478"' 'stun_listen_addr: "0.0.0.0:3479"'
    control "opt-in resolver back to jq // (explicit false lost)" specs/etc/keys-provision/provision.sh \
        "if .headscale.public_derp == null then \"\" else (.headscale.public_derp | tostring) end" '.headscale.public_derp // ""'
    control "provision_headscale_config stops calling the DERP step" specs/etc/keys-provision/provision.sh \
        '    provision_headscale_derp "${cfg}"' '    : provision_headscale_derp'
    control "provision_headscale stops running the config stage" specs/etc/keys-provision/provision.sh \
        '    [ -f /etc/headscale/config.yaml ] && provision_headscale_config /etc/headscale/config.yaml' '    :'
    control "firewall drops the STUN carve-out" specs/usr/sbin/hugmesh-coturn-firewall \
        "\${HS_STUN_RULE}${NL}\${DROP_RULES}" "\${DROP_RULES}"
    control "firewall widens the carve-out to TCP as well" specs/usr/sbin/hugmesh-coturn-firewall \
        'udp dport ${HS_STUN_PORT} accept' 'meta l4proto { tcp, udp } th dport ${HS_STUN_PORT} accept'
    control "firewall accepts a malformed marker" specs/usr/sbin/hugmesh-coturn-firewall \
        'if [[ "${_hs_port}" =~ ^[0-9]{1,5}$ ]] && [ "${_hs_port}" -ge 1 ] && [ "${_hs_port}" -le 65535 ]; then' 'if [ -n "${_hs_port}" ]; then'
    control "an ARM builder forgets the flag" build-orangepi5-stage4.sh \
        "--headscale-public-derp) HEADSCALE_PUBLIC_DERP=true; shift ;;" ""
    control "Studio stops emitting the flag" studio/hugmesh_studio/core/config.py \
        'a += ["--headscale-public-derp"]' 'a += []'
    control "local stack opt-in stops swapping urls" tests/stack/headscale/entrypoint.sh \
        "    if [ \"\${PUBLIC_DERP}\" = true ]; then" "    if false; then"
    control "resolve_endpoint's default goes back to http://" specs/etc/keys-provision/provision.sh \
        '[ -n "${lan}" ] && ep="https://${lan}:8080"' '[ -n "${lan}" ] && ep="http://${lan}:8080"'
    control "headscale stops serving TLS for the default URL" specs/etc/keys-provision/provision.sh \
        '    if headscale_tls_material "${host}"; then' '    if false; then'
    control "the certificate stops naming loopback" specs/etc/keys-provision/provision.sh \
        "printf '%s\\n' \"\$1\" 127.0.0.1 ::1 localhost" "printf '%s\\n' \"\$1\" ::1 localhost"
    control "the no-certificate fallback keeps a dead https URL" specs/etc/keys-provision/provision.sh \
        '    HEADSCALE_SERVED_URL="http://${hp}:${lport}"' '    HEADSCALE_SERVED_URL="https://${hp}:${lport}"'
    control "a mismatched CA key is accepted (digest of nothing == digest of nothing)" specs/etc/keys-provision/provision.sh \
        '[[ "${a}" == *"BEGIN PUBLIC KEY"* ]] && [ "${a}" = "${b}" ]' '[ "${a}" = "${a}" ]'
    control "opt-in off stops removing the public map" specs/etc/keys-provision/provision.sh \
        'own_urls = [u for u in urls if u != public]' 'own_urls = list(urls)'
    control "old-shape configs are no longer migrated" specs/etc/keys-provision/provision.sh \
        'if not enabled and not (own_urls or paths):' 'if False:'
    control "firewalld keeps a stale STUN port" specs/usr/sbin/hugmesh-coturn-firewall \
        'if [[ "${HS_FW_PREV}" =~ ^[0-9]{1,5}/udp$ ]] && [ "${HS_FW_PREV}" != "${HS_FW_PORT}" ]; then' 'if false; then'
    control "the local-stack front publishes /derp to every source" tests/stack/tls-front/default.conf \
        "        deny all;${NL}        proxy_pass http://\$headscale:8080\$request_uri;" "        allow all;${NL}        proxy_pass http://\$headscale:8080\$request_uri;"
    control "build-all-roles stops handing the mesh CA on" scripts/build-all-roles.sh \
        '            [ -f "${_kd}certs/cluster-ca.crt" ] && continue' '            continue'
    control "a route-access row opens the pki gateway's /derp to the public" specs/cluster/manifests/route-access/initdb/20-schema.sql \
        "  ('hugmesh-pki-gateway', '/login/**',             'PUBLIC', true),  -- public" "  ('hugmesh-pki-gateway', '/login/**',             'PUBLIC', true),  -- public${NL}  ('hugmesh-pki-gateway', '/derp/**',              'PUBLIC', true),"
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

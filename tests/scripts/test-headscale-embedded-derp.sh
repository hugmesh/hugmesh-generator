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
grep -a -E '^[[:space:]]+provision_headscale_derp /etc/headscale/config\.yaml' "${WORK}/ph.sh" >/dev/null \
    && ok "provision_headscale runs provision_headscale_derp on /etc/headscale/config.yaml" \
    || bad "provision_headscale never runs provision_headscale_derp"
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
case "${got}" in *"|-") ok "embedded server off => no STUN marker (nothing for the firewall to admit)" ;;
                 *) bad "embedded server off still hands a STUN port to the firewall (got ${got})" ;; esac
grep -a -F 'initial DERPMap is empty' "${WORK}/b-off/log" >/dev/null \
    && ok "embedded server off with no DERP map is called out (headscale would refuse to start)" \
    || bad "embedded server off + no map passes silently"
mkdir -p "${WORK}/b-custom"
sed -e 's|^  urls: \[\]$|  urls: ["https://derp.example.test/map.json"]|' "${ROOT}/specs/etc/headscale/config.yaml" > "${WORK}/b-custom/src.yaml"
got="$(derp_case custom "${WORK}/b-custom/src.yaml" '{"headscale":{"public_derp":true}}' -)"
case "${got}" in *"|https://derp.example.test/map.json|False|3478") ok "an operator's own derp.urls list is left as written under the opt-in" ;;
                 *) bad "the opt-in clobbered an operator's derp.urls list (got ${got})" ;; esac

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
  --query-port=*)  grep -a "ADD ${a#--query-port=}\$" "${FWCMD_LOG:-/dev/null}" >/dev/null 2>&1; exit $? ;;
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
    NFT_CAPTURE="${d}/rules.nft" FWCMD_LOG="${d}/fw.log" PATH="${WORK}/fw/bin:${PATH}" \
        HUGMESH_COTURN_PUBLIC_MARKER="${m}/public" HUGMESH_HEADSCALE_STUN_MARKER="${m}/stun" \
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
  && grep -a -F "HEADSCALE_PUBLIC_DERP='\$(HEADSCALE_PUBLIC_DERP)' ENV=" "${MK}" >/dev/null \
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
elif [ "${ROOT}" = "${REPO}" ]; then
    guard_require_capability "openssl/ssh-keygen/keytool missing — gen-provision-keys.sh cannot be run"
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
    control "provision_headscale stops calling the DERP step" specs/etc/keys-provision/provision.sh \
        "        provision_headscale_derp /etc/headscale/config.yaml" "        : provision_headscale_derp"
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
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

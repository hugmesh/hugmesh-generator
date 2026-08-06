#!/usr/bin/env bash
# test-coturn-optional-service.sh — unit test for the coturn (TURN/STUN) OPTIONAL
# service: it RENDERS, it is GATED OFF BY DEFAULT (inert), and tuwunel's TURN config
# is DARK and references the SAME ESO secret (no literal, no drift).
#
# REQUIREMENT (this PR): add coturn as a DEFAULT-OFF optional service that relays
# Matrix WebRTC A/V, mirroring the existing optional-service pattern, SAFE-BY-DEFAULT
# (everything off/inert so a default build is byte-identical to mainline). This test
# proves the three load-bearing properties WITHOUT a live cluster:
#   1) the coturn manifest renders (kustomize build) with the per-app SA, the unique
#      MCS level s0:c67, the upstream image pin, the STUN/TURN ports + relay window,
#      a secret-free turnserver.conf, and the public-ingress NetworkPolicy;
#   2) the optional toggle GATES it OFF by default — registry default:off, the
#      installed-services ConfigMap coturn:"false", the 13a ApplicationSet element
#      installed:"false", NO baked bootstrap Application (anubis runtime-only pattern)
#      — so ArgoCD creates nothing and the service is inert;
#   3) tuwunel's TURN config references the SAME ESO secret (coturn-shared-secret)
#      and ships DARK: turn_secret = "" in the toml + an optional:true env override,
#      so when coturn is off tuwunel returns empty TURN creds (host-only ICE).
#
# Pure-render + static assertions; no build-script edits, no secrets. Arch-neutral.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${REPO}/specs/cluster"
REG="${SRC}/optional-services.yaml"
COTURN_DIR="${SRC}/manifests/coturn"
ESO="${SRC}/manifests/external-secrets/coturn-externalsecrets.yaml"
APPSET="${SRC}/apps/13a-optional-services.yaml"
CM="${SRC}/manifests/policy/installed-services-configmap.yaml"
TUWUNEL="${SRC}/manifests/tuwunel/tuwunel.yaml"
SECMD="${REPO}/docs/SECURITY.md"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

echo "== coturn OPTIONAL service unit test =="

KZ=""
command -v kustomize >/dev/null 2>&1 && KZ="kustomize build"
[ -z "${KZ}" ] && command -v kubectl >/dev/null 2>&1 && KZ="kubectl kustomize"

# ── 1) RENDER: the coturn manifest builds + carries its contract ───────────────
echo "-- 1) coturn manifest renders + carries SA / MCS / ports / secret-free conf --"
if [ -n "${KZ}" ]; then
  RENDER="$(${KZ} "${COTURN_DIR}" 2>/tmp/coturn-kz.err)"
  if [ -n "${RENDER}" ]; then
    ok "coturn kustomize build succeeds"
    grep -qE 'image: coturn/coturn:[0-9]' <<<"${RENDER}"          && ok "render: upstream image coturn/coturn pinned to a version tag" || bad "render: coturn image not pinned"
    grep -q 'serviceAccountName: sa-coturn' <<<"${RENDER}"        && ok "render: pod runs as the dedicated SA sa-coturn" || bad "render: sa-coturn not wired on the pod"
    grep -q 'level: s0:c67' <<<"${RENDER}"                        && ok "render: seLinuxOptions level s0:c67 (unique MCS)" || bad "render: s0:c67 MCS level missing"
    grep -q 'secretName: coturn-shared-secret' <<<"${RENDER}"     && ok "render: shared secret mounted from Secret coturn-shared-secret" || bad "render: coturn-shared-secret not mounted"
    grep -qE 'containerPort: 3478' <<<"${RENDER}"                 && ok "render: STUN/TURN port 3478 exposed" || bad "render: 3478 missing"
    grep -qE 'containerPort: 5349' <<<"${RENDER}"                 && ok "render: TLS-STUN port 5349 exposed" || bad "render: 5349 missing"
    grep -q 'endPort: 49200' <<<"${RENDER}"                       && ok "render: relay window upper bound exposed in NetworkPolicy" || bad "render: relay window endPort missing"
    grep -q 'kind: NetworkPolicy' <<<"${RENDER}"                  && ok "render: NetworkPolicy present (public STUN/TURN ingress + relay egress)" || bad "render: NetworkPolicy missing"
    grep -q 'kind: Service' <<<"${RENDER}"                        && ok "render: Service present" || bad "render: Service missing"
    # SECRET-FREE conf: turnserver.conf must declare use-auth-secret but NEVER carry
    # a literal static-auth-secret VALUE. The ONLY allowed occurrence is the runtime
    # append `static-auth-secret=$(cat /run/secrets/...)` (reads the mounted Secret).
    # A literal would be `static-auth-secret=<base64/hex chars>` with no $(...).
    grep -q 'use-auth-secret' <<<"${RENDER}"                      && ok "render: turnserver.conf uses REST long-term-credential mode" || bad "render: use-auth-secret missing"
    if grep -nE 'static-auth-secret[[:space:]]*=' <<<"${RENDER}" | grep -vE 'static-auth-secret=\$\(cat ' | grep -qE 'static-auth-secret[[:space:]]*=[[:space:]]*[A-Za-z0-9+/=]'; then
      bad "SECURITY: a literal static-auth-secret VALUE is baked into the manifest"
    else
      ok "render: NO literal static-auth-secret value (only the runtime \$(cat ...) append)"
    fi
  else
    bad "coturn kustomize build produced no output ($(tr -d '\n' </tmp/coturn-kz.err | cut -c1-200))"
  fi
else
  echo "  SKIP render assertions (no kustomize/kubectl)"
  # Fall back to source-level checks so the contract is still asserted.
  grep -q 'image: coturn/coturn' "${COTURN_DIR}/deployment.yaml" && ok "src: coturn image present" || bad "src: coturn image missing"
  grep -q 'level: "s0:c67"' "${COTURN_DIR}/deployment.yaml"      && ok "src: s0:c67 MCS level present" || bad "src: s0:c67 missing"
fi

# ── 1b) the ESO secret is a Vault REFERENCE, never a literal ───────────────────
echo "-- 1b) ESO shared-secret is a Vault reference (no literal) --"
[ -f "${ESO}" ] && ok "coturn-externalsecrets.yaml exists" || bad "coturn ESO file missing"
grep -q 'kind: ExternalSecret' "${ESO}"                       && ok "ESO: ExternalSecret CRD" || bad "ESO: not an ExternalSecret"
grep -q 'key: hugmesh/coturn-shared-secret' "${ESO}"       && ok "ESO: references Vault path hugmesh/coturn-shared-secret" || bad "ESO: Vault path ref missing"
# A literal would be a long inline base64/hex value on a secret-ish key; the
# legitimate lines are short refs (secretKey: secret / property: secret / key: <path>).
if grep -nE '(static-auth-secret|secretKey|property)[[:space:]]*[:=][[:space:]]*"?[A-Za-z0-9+/]{20,}' "${ESO}" | grep -qv '#'; then
  bad "SECURITY: ESO file appears to carry a literal secret value"
else
  ok "ESO: no literal secret value (reference only)"
fi

# ── 2) GATED OFF BY DEFAULT: registry / ConfigMap / 13a / no baked Application ──
echo "-- 2) coturn is GATED OFF by default (inert) --"
if command -v python3 >/dev/null 2>&1; then
  python3 - "${REG}" <<'PY' && ok "registry: coturn registered, default:off, apps:[] (runtime-only)" || bad "registry: coturn entry wrong"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
svc = {s["slug"]: s for s in d["spec"]["services"]}
c = svc["coturn"]
assert c["default"] in (False, "off"), f"default={c['default']!r}"
assert c.get("apps") in ([], None), f"apps={c.get('apps')!r} (must be [] — runtime-only, no baked Application)"
assert c["namespace"] == "hugmesh-backend", f"ns={c['namespace']!r} (must share tuwunel's ns)"
assert c["esoFile"].endswith("coturn-externalsecrets.yaml"), c["esoFile"]
PY
else
  grep -qE '^[[:space:]]*-[[:space:]]*slug:[[:space:]]*coturn' "${REG}" && ok "registry: coturn slug present" || bad "registry: coturn slug missing"
fi

# installed-services ConfigMap baseline = "false" (safe default; builders don't rewrite it).
grep -qE '^[[:space:]]*coturn:[[:space:]]*"false"' "${CM}" \
  && ok "ConfigMap: coturn baseline \"false\" (safe default — ApplicationSet creates nothing)" || bad "ConfigMap: coturn not \"false\""

# 13a ApplicationSet element exists + installed:"false" (so the selector drops it).
grep -qE '\{[[:space:]]*slug:[[:space:]]*coturn[[:space:]]*,.*installed:[[:space:]]*"false"' "${APPSET}" \
  && ok "13a: coturn element present + installed:\"false\" (selector keeps only true)" || bad "13a: coturn element missing or not false"
grep -qE '\{[[:space:]]*slug:[[:space:]]*coturn[[:space:]]*,.*path:[[:space:]]*specs/cluster/manifests/coturn' "${APPSET}" \
  && ok "13a: coturn element points at specs/cluster/manifests/coturn" || bad "13a: coturn path wrong"

# NO baked bootstrap Application (anubis runtime-only pattern): nothing in apps/ may
# reference the coturn manifest dir as a bootstrap Application source path.
if grep -rlE 'path:[[:space:]]*specs/cluster/manifests/coturn' "${SRC}/apps/" 2>/dev/null | grep -qv '13a-optional-services.yaml'; then
  bad "a baked Application sources manifests/coturn (must be runtime-only via 13a)"
else
  ok "no baked bootstrap Application for coturn (runtime-only via 13a — genuinely default-off)"
fi

# ── 3) tuwunel TURN config is DARK + references the SAME ESO secret ────────────
echo "-- 3) tuwunel TURN config is DARK and shares the coturn ESO secret --"
grep -q 'turn_uris' "${TUWUNEL}"                              && ok "tuwunel: turn_uris present (advertises the relay when live)" || bad "tuwunel: turn_uris missing"
grep -qE 'turn_secret[[:space:]]*=[[:space:]]*""' "${TUWUNEL}" && ok "tuwunel: turn_secret = \"\" in the toml (DARK switch)" || bad "tuwunel: turn_secret not empty in the toml"
grep -q 'TUWUNEL_TURN_SECRET' "${TUWUNEL}"                    && ok "tuwunel: TUWUNEL_TURN_SECRET env override wired" || bad "tuwunel: TUWUNEL_TURN_SECRET env missing"
# the env sources the SAME shared Secret, optional:true (so tuwunel starts when coturn is OFF).
python3 - "${TUWUNEL}" <<'PY' 2>/dev/null && ok "tuwunel: TUWUNEL_TURN_SECRET <- Secret coturn-shared-secret (optional:true) — same secret, dark when absent" || bad "tuwunel: TURN secret env not optional-sourced from coturn-shared-secret"
import sys, yaml
ok = False
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if not isinstance(doc, dict) or doc.get("kind") != "Deployment": continue
    for c in doc["spec"]["template"]["spec"]["containers"]:
        for e in c.get("env", []):
            if e.get("name") == "TUWUNEL_TURN_SECRET":
                skr = e.get("valueFrom", {}).get("secretKeyRef", {})
                if skr.get("name") == "coturn-shared-secret" and skr.get("key") == "secret" and skr.get("optional") is True:
                    ok = True
assert ok, "TUWUNEL_TURN_SECRET must be an optional:true secretKeyRef to coturn-shared-secret/secret"
PY
# literal-secret guard on tuwunel.toml TURN keys.
grep -qE 'turn_secret[[:space:]]*=[[:space:]]*"[^"]+"' "${TUWUNEL}" && bad "SECURITY: tuwunel.toml has a non-empty literal turn_secret" || ok "tuwunel: no literal turn_secret (dark + ESO-injected only)"

# ── 4) SELinux matrix sync: coturn row with s0:c67 + sa-coturn ─────────────────
echo "-- 4) SELinux MCS matrix sync (docs/SECURITY.md §3) --"
grep -qiE '\|[[:space:]]*coturn.*\|[[:space:]]*`?sa-coturn`?[[:space:]]*\|.*`?s0:c67`?' "${SECMD}" \
  && ok "SECURITY.md §3: coturn row present (sa-coturn + s0:c67)" || bad "SECURITY.md §3: coturn matrix row missing/mismatched"
# uniqueness: s0:c67 used exactly once in the matrix.
n="$(grep -oE 's0:c67' "${SECMD}" | wc -l | tr -d ' ')"
[ "${n}" -ge 1 ] && ok "SECURITY.md: s0:c67 allocated to coturn" || bad "SECURITY.md: s0:c67 not allocated"

# ── 5) artefact integrity (the surviving optional registry + ConfigMap parse) ──
echo "-- 5) artefact integrity --"
if command -v python3 >/dev/null 2>&1; then
  python3 - "${CM}" "${APPSET}" "${REG}" <<'PY' && ok "installed-services ConfigMap (+ services.json) + 13a + registry parse" || bad "an artefact failed to parse"
import sys, yaml, json
cm = yaml.safe_load(open(sys.argv[1]))
sj = json.loads(cm["data"]["services.json"])
assert any(s["slug"] == "coturn" for s in sj), "services.json missing coturn entry"
list(yaml.safe_load_all(open(sys.argv[2])))
yaml.safe_load(open(sys.argv[3]))
PY
fi

# ── 6) PUBLIC reachability layer (manifests/coturn-public) — OPT-IN + DARK ────
# The overlay adds hostNetwork + the external-ip/turn-uris knobs + the turns:
# cert; the BASE + tuwunel reference them only through optional seams. These
# assertions pin BOTH directions: dark defaults unchanged with the knobs off,
# and the overlay rendering the reachability/TLS/turn_uris wiring when on.
echo "-- 6) coturn-public overlay: dark defaults + knob-on rendering --"
PUB_DIR="${SRC}/manifests/coturn-public"
PKI="${SRC}/manifests/vault-pki/pki-init-configmap.yaml"
FW="${REPO}/specs/usr/sbin/hugmesh-coturn-firewall"
GOLIVE="${REPO}/specs/usr/sbin/hugmesh-go-live"

# 6a) DARK DEFAULTS: the registry/13a/ConfigMap gates are untouched by the
# public layer (still installed:"false"/coturn:"false", element path still the
# BASE dir), and the base render carries NO hostNetwork and NO tls-secret
# requirement (the coturn-tls volume must be optional:true).
grep -qE '\{[[:space:]]*slug:[[:space:]]*coturn[[:space:]]*,.*path:[[:space:]]*specs/cluster/manifests/coturn[[:space:]]*,' "${APPSET}" \
  && ok "dark: 13a coturn element still points at the BASE dir (overlay is repoint-only)" || bad "dark: 13a coturn element no longer points at manifests/coturn"
if [ -n "${KZ}" ]; then
  BASE_RENDER="$(${KZ} "${COTURN_DIR}" 2>/dev/null)"
  grep -q 'hostNetwork' <<<"${BASE_RENDER}" \
    && bad "dark: BASE render carries hostNetwork (must live ONLY in the overlay)" \
    || ok "dark: BASE render has no hostNetwork (in-cluster only)"
  # The base REFERENCES coturn-public-config (an optional:true configMapKeyRef);
  # what it must never do is SHIP the object. Grepping the name alone cannot tell
  # those apart, so parse the render and look for the ConfigMap itself.
  BASE_RENDER_F="$(mktemp)"; printf '%s\n' "${BASE_RENDER}" > "${BASE_RENDER_F}"
  python3 - "${BASE_RENDER_F}" <<'PY' && ok "dark: BASE render does not ship the coturn-public-config OBJECT (knob refs are optional:true)" || bad "dark: BASE render ships the coturn-public-config ConfigMap (overlay-only)"
import sys, yaml
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if isinstance(doc, dict) and doc.get("kind") == "ConfigMap" \
       and doc.get("metadata", {}).get("name") == "coturn-public-config":
        sys.exit(1)
PY
  rm -f "${BASE_RENDER_F}"
fi
python3 - "${COTURN_DIR}/deployment.yaml" <<'PY' && ok "dark: base tls volume + external-ip knob are optional:true seams" || bad "dark: base optional seams wrong (a missing overlay would break the pod)"
import sys, yaml
tls_opt = env_opt = False
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if not isinstance(doc, dict) or doc.get("kind") != "Deployment": continue
    spec = doc["spec"]["template"]["spec"]
    for v in spec.get("volumes", []):
        s = v.get("secret", {})
        if s.get("secretName") == "coturn-tls" and s.get("optional") is True: tls_opt = True
    for c in spec["containers"]:
        for e in c.get("env", []):
            if e.get("name") == "COTURN_EXTERNAL_IP_OVERRIDE":
                ref = e.get("valueFrom", {}).get("configMapKeyRef", {})
                if ref.get("name") == "coturn-public-config" and ref.get("optional") is True: env_opt = True
assert tls_opt, "coturn-tls volume must be secret+optional:true"
assert env_opt, "COTURN_EXTERNAL_IP_OVERRIDE must be an optional:true configMapKeyRef to coturn-public-config"
PY

# tuwunel: the toml turn_uris DEFAULT is byte-identical to the in-cluster svc
# URI set (the dark contract of the public parameterization), and the override
# env is an optional:true ref to the overlay's ConfigMap.
grep -qF 'turn_uris = ["turn:coturn.hugmesh-backend.svc.cluster.local:3478?transport=udp", "turn:coturn.hugmesh-backend.svc.cluster.local:3478?transport=tcp"]' "${TUWUNEL}" \
  && ok "dark: tuwunel toml turn_uris default is the EXACT in-cluster URI set (byte-identical)" \
  || bad "dark: tuwunel toml turn_uris default drifted from the in-cluster svc URI set"
python3 - "${TUWUNEL}" <<'PY' && ok "tuwunel: TUWUNEL_TURN_URIS <- coturn-public-config/turn-uris (optional:true) — dark when the overlay is off" || bad "tuwunel: TUWUNEL_TURN_URIS not an optional:true configMapKeyRef to coturn-public-config"
import sys, yaml
found = False
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if not isinstance(doc, dict) or doc.get("kind") != "Deployment": continue
    for c in doc["spec"]["template"]["spec"]["containers"]:
        for e in c.get("env", []):
            if e.get("name") == "TUWUNEL_TURN_URIS":
                ref = e.get("valueFrom", {}).get("configMapKeyRef", {})
                if ref.get("name") == "coturn-public-config" and ref.get("key") == "turn-uris" and ref.get("optional") is True:
                    found = True
assert found
PY

# 6b) KNOB-ON: the overlay renders hostNetwork + the knobs + the turns: cert,
# and preserves the base's shared-secret parity (same Secret, same MCS).
if [ -n "${KZ}" ]; then
  PUB_RENDER="$(${KZ} "${PUB_DIR}" 2>/tmp/coturn-pub-kz.err)"
  if [ -n "${PUB_RENDER}" ]; then
    ok "coturn-public kustomize build succeeds"
    grep -q 'hostNetwork: true' <<<"${PUB_RENDER}"                 && ok "overlay: hostNetwork:true (1:1 relay-window exposure — NodePort cannot remap TURN)" || bad "overlay: hostNetwork missing"
    grep -q 'dnsPolicy: ClusterFirstWithHostNet' <<<"${PUB_RENDER}" && ok "overlay: dnsPolicy ClusterFirstWithHostNet (lan-dns hostNetwork idiom)" || bad "overlay: dnsPolicy missing"
    grep -q 'name: coturn-public-config' <<<"${PUB_RENDER}"        && ok "overlay: coturn-public-config knobs ship" || bad "overlay: coturn-public-config missing"
    grep -q 'external-ip:' <<<"${PUB_RENDER}"                      && ok "overlay: external-ip NAT knob present" || bad "overlay: external-ip knob missing"
    grep -q 'turns:turn.hugmesh.systems:5349' <<<"${PUB_RENDER}"   && ok "overlay: turn-uris carries the public turns: URI for turn.<domain>" || bad "overlay: public turns: URI missing"
    grep -q 'common_name: turn.hugmesh.systems' <<<"${PUB_RENDER}" && ok "overlay: coturn-tls issued for CN turn.<domain> (Vault-PKI loop)" || bad "overlay: turn.<domain> CN missing"
    grep -q 'path: pki_int/issue/coturn' <<<"${PUB_RENDER}"        && ok "overlay: cert minted via pki_int/issue/coturn (same per-domain CA loop)" || bad "overlay: pki_int/issue/coturn path missing"
    grep -q 'secretName: coturn-shared-secret' <<<"${PUB_RENDER}"  && ok "overlay: shared-secret parity preserved (same Secret coturn-shared-secret)" || bad "overlay: shared secret lost in the overlay"
    grep -q 'level: s0:c67' <<<"${PUB_RENDER}"                     && ok "overlay: MCS s0:c67 preserved" || bad "overlay: s0:c67 lost in the overlay"
  else
    bad "coturn-public kustomize build produced no output ($(tr -d '\n' </tmp/coturn-pub-kz.err | cut -c1-200))"
  fi
else
  echo "  SKIP overlay render assertions (no kustomize/kubectl)"
  grep -q 'hostNetwork: true' "${PUB_DIR}/deployment-hostnetwork.yaml" && ok "src: overlay hostNetwork patch present" || bad "src: overlay hostNetwork patch missing"
fi
# The invariant is that an ISSUING ROLE NAMED coturn EXISTS, not that a
# particular line of a particular loop is present. The previous form grepped for
# the literal word-list of one loop, so it went green on a tree whose PKI
# bootstrap did not parse at all (#527 re-introduced a dead loop; init-pki.sh was
# invalid bash and created ZERO roles, and this assertion still passed). Assert
# the role, and let the SAN-coverage gate own whether it can issue the names the
# ExternalSecret asks for.
if grep -qE '\$\{PKI\}/roles/coturn' "${PKI}"; then
  ok "vault-pki: an issuing role named coturn is created"
else
  bad "vault-pki: no coturn issuing role — pki_int/issue/coturn would 404"
fi
# ...and the bootstrap must be RUNNABLE. A syntax error anywhere in init-pki.sh
# means no roles at all, which every static grep above would happily miss.
PKI_SH="$(mktemp)"
python3 - "${PKI}" > "${PKI_SH}" <<'EXTRACT'
import sys, yaml
print(yaml.safe_load(open(sys.argv[1]))["data"]["init-pki.sh"])
EXTRACT
if bash -n "${PKI_SH}" 2>/dev/null; then
  ok "vault-pki: init-pki.sh is valid bash (it would actually run)"
else
  bad "vault-pki: init-pki.sh does NOT parse — the init Job creates zero roles"
fi
rm -f "${PKI_SH}"

# 6b') BEHAVIOURAL — the pod's OWN start script is what actually decides whether
# external-ip is overridden and whether the turns: cert lines exist. Static YAML
# assertions cannot see a `${VAR:-default}` typo, so extract the container's
# args verbatim and RUN them against a fake secret/cert tree in all three states.
python3 - "${COTURN_DIR}/deployment.yaml" > /tmp/coturn-start.sh <<'PY'
import sys, yaml
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if isinstance(doc, dict) and doc.get("kind") == "Deployment":
        for c in doc["spec"]["template"]["spec"]["containers"]:
            if c["name"] == "coturn":
                sys.stdout.write(c["args"][0])
PY
CT="$(mktemp -d)"
mkdir -p "${CT}/etc/coturn" "${CT}/run/coturn" "${CT}/run/secrets/coturn" "${CT}/run/secrets/coturn-tls"
printf 'realm=example.org\nlistening-port=3478\n' > "${CT}/etc/coturn/turnserver.conf"
printf 'SHARED-SECRET-VALUE\n' > "${CT}/run/secrets/coturn/secret"
# Neuter the exec (no turnserver binary here) and re-root every absolute path.
_coturn_run() {  # $1=outfile ; env comes from the caller
  sed -e "s#^\(CONF=\)/run#\1${CT}/run#" \
      -e "s#/etc/coturn/turnserver.conf#${CT}/etc/coturn/turnserver.conf#g" \
      -e "s#/run/secrets/#${CT}/run/secrets/#g" \
      -e 's#^ *exec turnserver.*#:#' /tmp/coturn-start.sh > "${CT}/start.sh"
  ( cd "${CT}" && bash "${CT}/start.sh" ) >/dev/null 2>&1
  cp "${CT}/run/coturn/turnserver.conf" "$1"
}
COTURN_EXTERNAL_IP=10.9.8.7 _coturn_run "${CT}/dark.conf"
grep -qx 'external-ip=10.9.8.7' "${CT}/dark.conf" \
  && ok "conf(run): knobs OFF -> external-ip falls back to the downward-API hostIP" || bad "conf(run): hostIP fallback broken"
grep -q '^cert=' "${CT}/dark.conf" || grep -q '^pkey=' "${CT}/dark.conf" \
  && bad "conf(run): knobs OFF but cert=/pkey= were appended (TLS must stay un-provisioned)" \
  || ok "conf(run): knobs OFF -> NO cert=/pkey= lines (dark, byte-equivalent to pre-overlay)"
# The ConfigMap ships external-ip: "" by default — an EMPTY override must NOT
# win, or the overlay would advertise `external-ip=` and coturn would refuse it.
COTURN_EXTERNAL_IP=10.9.8.7 COTURN_EXTERNAL_IP_OVERRIDE="" _coturn_run "${CT}/empty.conf"
grep -qx 'external-ip=10.9.8.7' "${CT}/empty.conf" \
  && ok "conf(run): overlay ON with an EMPTY external-ip knob -> still the hostIP (documented default)" \
  || bad "conf(run): empty external-ip knob overrode the hostIP (would advertise 'external-ip=')"
# NAT pair form (the upstream <public>/<private> syntax) must pass through verbatim.
printf 'CERT\n' > "${CT}/run/secrets/coturn-tls/tls.crt"; printf 'KEY\n' > "${CT}/run/secrets/coturn-tls/tls.key"
COTURN_EXTERNAL_IP=10.9.8.7 COTURN_EXTERNAL_IP_OVERRIDE="203.0.113.10/172.17.19.101" _coturn_run "${CT}/on.conf"
grep -qx 'external-ip=203.0.113.10/172.17.19.101' "${CT}/on.conf" \
  && ok "conf(run): knob ON -> external-ip is the NAT pair verbatim (upstream public/private form)" || bad "conf(run): external-ip override not applied verbatim"
grep -qx "cert=${CT}/run/secrets/coturn-tls/tls.crt" "${CT}/on.conf" && grep -qx "pkey=${CT}/run/secrets/coturn-tls/tls.key" "${CT}/on.conf" \
  && ok "conf(run): coturn-tls present -> cert=/pkey= appended (upstream option names) for turns:/5349" || bad "conf(run): cert=/pkey= not appended when the TLS Secret exists"
rm -rf "${CT}" /tmp/coturn-start.sh

# 6b'') RELAY-WINDOW PARITY — the window is written in FOUR places that must not
# drift: turnserver.conf min/max-port, the NetworkPolicy ingress range, the node
# firewall's defaults, and the turn-uris/doc story. Pin the first three together.
NP="${COTURN_DIR}/network-policy.yaml"
CONF_MIN="$(grep -oE '^[[:space:]]*min-port=[0-9]+' "${COTURN_DIR}/deployment.yaml" | grep -oE '[0-9]+')"
CONF_MAX="$(grep -oE '^[[:space:]]*max-port=[0-9]+' "${COTURN_DIR}/deployment.yaml" | grep -oE '[0-9]+')"
NP_MIN="$(grep -oE 'port: [0-9]+, endPort: [0-9]+' "${NP}" | grep -oE '[0-9]+' | head -1)"
NP_MAX="$(grep -oE 'port: [0-9]+, endPort: [0-9]+' "${NP}" | grep -oE '[0-9]+' | tail -1)"
FW_MIN="$(grep -oE 'HUGMESH_COTURN_RELAY_MIN:-[0-9]+' "${FW}" | grep -oE '[0-9]+')"
FW_MAX="$(grep -oE 'HUGMESH_COTURN_RELAY_MAX:-[0-9]+' "${FW}" | grep -oE '[0-9]+')"
if [ -n "${CONF_MIN}" ] && [ "${CONF_MIN}" = "${NP_MIN}" ] && [ "${CONF_MIN}" = "${FW_MIN}" ] \
   && [ -n "${CONF_MAX}" ] && [ "${CONF_MAX}" = "${NP_MAX}" ] && [ "${CONF_MAX}" = "${FW_MAX}" ]; then
  ok "relay window ${CONF_MIN}-${CONF_MAX} agrees across turnserver.conf + NetworkPolicy + hugmesh-coturn-firewall"
else
  bad "relay window DRIFT: conf=${CONF_MIN}-${CONF_MAX} netpol=${NP_MIN}-${NP_MAX} firewall=${FW_MIN}-${FW_MAX} (a relayed call would be dropped by whichever layer is narrower)"
fi

# 6c) node firewall: hugmesh-coturn-firewall is marker-gated on BOTH layers
# (own nftables backstop + firewalld runtime admission), covers the full TURN
# port set, and is baked + rc-enabled by BOTH cluster builders.
[ -x "${FW}" ] && ok "hugmesh-coturn-firewall exists + executable" || bad "hugmesh-coturn-firewall missing"
grep -q '/etc/hugmesh/coturn-public' "${FW}"        && ok "firewall: gated on the coturn-public marker" || bad "firewall: marker gate missing"
grep -q 'hugmesh_coturn_relay' "${FW}"              && ok "firewall: owns its OWN nftables table (never another's)" || bad "firewall: own-table name missing"
grep -qE '3478' "${FW}" && grep -qE '5349' "${FW}" && grep -qE '49152.*49200|RELAY_MIN.*49152' "${FW}" \
  && ok "firewall: full TURN port set (3478/5349 + relay window)" || bad "firewall: TURN port set incomplete"
grep -q 'ct state established,related accept' "${FW}" \
  && ok "firewall: conntrack accept precedes the drops (relay window overlaps the ephemeral range)" || bad "firewall: missing established/related accept — closed posture would eat unrelated UDP replies"
for f in "${REPO}/specs/etc/init.d/hugmesh-coturn-firewall" "${REPO}/specs/etc/cron.d/hugmesh-coturn-firewall"; do
  [ -f "${f}" ] && ok "firewall: $(basename "$(dirname "${f}")")/hugmesh-coturn-firewall ships" || bad "firewall: ${f} missing"
done
for b in build-x86-host-stage4.sh build-rpi5-stage4.sh; do
  grep -q 'usr/sbin/hugmesh-coturn-firewall' "${REPO}/${b}" \
    && ok "firewall: ${b} bakes hugmesh-coturn-firewall" || bad "firewall: ${b} does not bake hugmesh-coturn-firewall"
  grep -qE 'SVCS.*hugmesh-coturn-firewall' "${REPO}/${b}" \
    && ok "firewall: ${b} rc-enables hugmesh-coturn-firewall" || bad "firewall: ${b} does not rc-enable it"
done

# BEHAVIOURAL: run the reconcile against nft/firewall-cmd shims and assert the
# marker actually gates — absent => drops rendered + no firewalld adds;
# present => no drops + the exact port set admitted.
FWT="$(mktemp -d)"
cat > "${FWT}/nft" <<'EOF'
#!/bin/bash
[ "$1" = "-f" ] && cp "$2" "${NFT_CAPTURE:-/dev/null}"
exit 0
EOF
cat > "${FWT}/firewall-cmd" <<'EOF'
#!/bin/bash
case "$1" in
  --state) exit 0 ;;
  --get-default-zone) echo drop; exit 0 ;;
esac
for a in "$@"; do case "$a" in
  --query-port=*)  grep -q "ADD ${a#--query-port=}\$" "${FWCMD_LOG:-/dev/null}" 2>/dev/null; exit $? ;;
  --add-port=*)    echo "ADD ${a#--add-port=}"       >> "${FWCMD_LOG:-/dev/null}"; exit 0 ;;
  --remove-port=*) echo "REMOVE ${a#--remove-port=}" >> "${FWCMD_LOG:-/dev/null}"; exit 0 ;;
esac; done
exit 0
EOF
chmod +x "${FWT}/nft" "${FWT}/firewall-cmd"
: > "${FWT}/fw.log"
NFT_CAPTURE="${FWT}/closed.nft" FWCMD_LOG="${FWT}/fw.log" PATH="${FWT}:${PATH}" \
  HUGMESH_COTURN_PUBLIC_MARKER="${FWT}/marker" bash "${FW}" >/dev/null 2>&1
grep -qE 'udp dport \{ 3478, 5349 \} drop' "${FWT}/closed.nft" && grep -qE 'udp dport 49152-49200 drop' "${FWT}/closed.nft" \
  && ok "firewall(run): marker ABSENT renders the closed backstop (TURN ports dropped)" || bad "firewall(run): closed posture missing its drops"
grep -q '^ADD ' "${FWT}/fw.log" \
  && bad "firewall(run): marker ABSENT but firewalld ports were ADDED (gate broken)" \
  || ok "firewall(run): marker ABSENT admits nothing through firewalld"
touch "${FWT}/marker"
NFT_CAPTURE="${FWT}/open.nft" FWCMD_LOG="${FWT}/fw.log" PATH="${FWT}:${PATH}" \
  HUGMESH_COTURN_PUBLIC_MARKER="${FWT}/marker" bash "${FW}" >/dev/null 2>&1
grep -qE 'dport.*drop' "${FWT}/open.nft" \
  && bad "firewall(run): marker PRESENT still renders drops (public mode dead)" \
  || ok "firewall(run): marker PRESENT lifts the backstop drops"
for p in 3478/udp 3478/tcp 5349/udp 5349/tcp 49152-49200/udp; do
  grep -q "ADD ${p}\$" "${FWT}/fw.log" || { bad "firewall(run): marker PRESENT did not admit ${p}"; break; }
done
grep -q "ADD 49152-49200/udp\$" "${FWT}/fw.log" && ok "firewall(run): marker PRESENT admits the full TURN port set through firewalld"
rm -rf "${FWT}"

# 6d) DNS: hugmesh-go-live appends `turn` to the derived hostnames ONLY when
# the coturn-public marker is present (dark default byte-identical), and the
# provider record emit refuses a tunnel CNAME for turn.<domain>.
grep -q 'COTURN_PUBLIC_MARKER' "${GOLIVE}" && grep -qE 'GL_SUBDOMAINS.*turn|turn.*GL_SUBDOMAINS' "${GOLIVE}" \
  && ok "go-live: turn label derivation is coturn-public-marker gated" || bad "go-live: marker-gated turn derivation missing"
GLT="$(mktemp -d)"; mkdir -p "${GLT}/etc" "${GLT}/off" "${GLT}/on" "${GLT}/cf"
echo example.org > "${GLT}/etc/cluster-domain"
_gl_plan() {  # $1=out-dir, rest=extra flags
  local out="$1"; shift
  GL_ETC_HUGMESH="${GLT}/etc" GL_PROVIDERS_LIB="${REPO}/specs/usr/lib/hugmesh/go-live-providers.sh" \
    bash "${GOLIVE}" plan --out-dir "${out}" "$@" >/dev/null 2>&1
}
_gl_plan "${GLT}/off" --provider byo-domain --ingress-ip 203.0.113.10
# A plan that never ran would make the "no turn record" assertion below pass
# VACUOUSLY, so require the artifact first.
[ -s "${GLT}/off/records.txt" ] \
  && ok "go-live(run): marker-ABSENT plan actually emitted a record set (no vacuous pass below)" \
  || bad "go-live(run): marker-ABSENT plan produced no records.txt — the dark assertion below would be vacuous"
grep -q 'turn\.example\.org' "${GLT}/off/records.txt" 2>/dev/null \
  && bad "go-live(run): marker ABSENT but turn.<domain> emitted (dark default broken)" \
  || ok "go-live(run): marker ABSENT emits NO turn record (byte-identical dark records)"
touch "${GLT}/etc/coturn-public"
_gl_plan "${GLT}/on" --provider byo-domain --tunnel-cname tun.example.net --turn-ip 198.51.100.9
grep -qE 'turn\.example\.org\.\s+A\s+198\.51\.100\.9' "${GLT}/on/records.txt" 2>/dev/null \
  && ok "go-live(run): marker PRESENT emits turn.<domain> as a DIRECT A at --turn-ip (the RELAY node, not the ingress node)" \
  || bad "go-live(run): turn record missing / not pointed at --turn-ip with the marker present"
grep -E 'turn\.example\.org' "${GLT}/on/records.txt" 2>/dev/null | grep -q 'CNAME' \
  && bad "go-live(run): turn.<domain> got the tunnel CNAME (TURN cannot ride an HTTP tunnel)" \
  || ok "go-live(run): turn.<domain> refuses the tunnel CNAME"
# Cloudflare Tunnel emits its OWN record set (it never calls _glp_record_for for
# the CNAME rows), so the turn. exception has to hold there INDEPENDENTLY: a
# proxied CNAME at turn. advertises a relay that answers no STUN packet at all.
_gl_plan "${GLT}/cf" --provider cloudflare-tunnel --tunnel-cname abc.cfargotunnel.com --turn-ip 198.51.100.9
grep -qE '^A,turn\.example\.org,198\.51\.100\.9,[0-9]+,false$' "${GLT}/cf/records.csv" 2>/dev/null \
  && ok "go-live(run): cloudflare-tunnel emits turn.<domain> as an UNPROXIED A at the relay node" \
  || bad "go-live(run): cloudflare-tunnel turn.<domain> is not an unproxied A row"
grep -E '^CNAME,turn\.example\.org' "${GLT}/cf/records.csv" 2>/dev/null \
  && bad "go-live(run): cloudflare-tunnel routed turn.<domain> through the tunnel CNAME (TURN is raw UDP/TCP — the tunnel is an HTTP edge)" \
  || ok "go-live(run): cloudflare-tunnel never CNAMEs turn.<domain> at the tunnel"
rm -rf "${GLT}"

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

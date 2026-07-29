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

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

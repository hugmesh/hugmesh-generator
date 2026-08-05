#!/usr/bin/env bash
# test-cluster-manifest-integrity.sh — static referential-integrity gate over
# specs/cluster. Pure PyYAML + bash; no cluster, no kubectl, no network.
#
# WHY THIS EXISTS. Three PRs landing into the same slug area in the same week
# (#451 mesh-bff, #456 character-forge, the rebrand) produced a class of defect
# that NOTHING in CI could see, because every existing gate either reads one file
# in isolation or greps for a string:
#
#   1. secretstore.yaml stopped being valid YAML at all — a merge spliced three
#      ExternalSecrets INTO the middle of another document's `dataFrom: extract:`
#      block, leaving an orphan `key: hugmesh/casdoor-apps` past the end of file.
#      That file is resources[0] of the external-secrets kustomization, so NOT
#      ONE ExternalSecret in the cluster could be created — no DB passwords, no
#      Casdoor app secrets, no mTLS certs for any tier. The platform cannot boot.
#   2. pki-externalsecrets.yaml fused two Kubernetes objects into one document:
#      duplicate `apiVersion`/`kind`/`metadata`/`spec` keys, and THREE `metadata:`
#      keys in one ExternalSecret. PyYAML/kustomize last-wins silently dropped
#      the mesh-bff mTLS pair and relocated the character-forge one into a
#      namespace that does not exist. A plain safe_load does NOT notice this.
#   3. Objects, Argo destinations and gateway route URIs pointed at namespace
#      `snapdragon-backend`, which the rebrand deleted; the route-access seed
#      carried rows for gateway id `snapdragon-fe-gateway`, which no longer
#      exists, so /bff/mesh/** was default-denied for every ROLE_MESH holder.
#   4. The Vault PKI role loop was two `for app in ...` headers line-continued
#      into one, so bash put the literal words `for`, `app` and `in` in the word
#      list and vault-pki-init minted three junk cluster-CA issuing roles.
#      `bash -n` passes — reserved words are ordinary words inside a for-list.
#   5. mesh-bff-db mounted `mesh-bff-db-mtls` `optional: true` while no
#      ExternalSecret anywhere produced it: a silently cleartext Postgres.
#   6. The mesh-bff and character-forge slugs both claimed SELinux MCS
#      categories s0:c80 and s0:c81 in the SAME namespace, voiding the
#      per-workload isolation docs/SECURITY.md §3 declares as a contract.
#   7. mesh-bff-db was in NEITHER half of the ADR-32 DB isolation pair (no
#      per-pod db-ingress policy, and not excluded from the broad tier-ingress
#      admittance), so it was reachable on 5432 from every backend and frontend
#      pod — past the mesh BFF and its ROLE_MESH gateway floor.
#   8. The SERVICE-only `/…/internal/**` ingest receivers were externally
#      reachable through the fe-gateway. Three comments in the tree asserted they
#      were "NOT routed here"; all three were matched by a live `**` route
#      predicate, and route-access decides on the LONGEST matching pattern — so
#      /bff/user/internal/** fell through to the `/bff/user/** ROLE_USER` floor,
#      /bff/mesh/internal/** to `/bff/mesh/** ROLE_MESH`, and /bff/internal/**
#      had no row at all (decide() => NO_RULE => FORWARDED on the coarse
#      authenticated() floor, into a prefix admin-bff permitAll()s app-side).
#   9. casdoor/init-data-configmap.yaml carried an init_data.json that DOES NOT
#      PARSE — the same #451 merge concatenated the entire pre-rebrand
#      `owner: "snapdragon"` roles array in front of the rebranded one, leaving
#      what had been that array's last element as an interior element with no
#      trailing comma ("Expecting ',' delimiter: line 42 column 5"). Casdoor
#      imports the file wholesale on boot, so the WHOLE identity seed — the
#      organization, every role including ROLE_IMAGE_BUILDER, every svc-* user —
#      was silently skipped. The ConfigMap around it is flawless YAML, so check
#      (1) passed it happily: a ConfigMap value is a FILE in another language and
#      nothing in this gate had ever looked inside one.
#
# Each numbered check below fails on at least one of those, and each carries a
# NEGATIVE CONTROL: the same assertion is re-run against a deliberately-corrupted
# staged copy of the tree and MUST fail there, so a green run cannot be vacuous.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "  FAIL PyYAML not available (pip install pyyaml)"; exit 1; }

CHECKER="$(dirname "${BASH_SOURCE[0]}")/cluster_manifest_integrity.py"
[ -f "${CHECKER}" ] || { echo "  FAIL missing checker: ${CHECKER}"; exit 1; }

echo "== cluster manifest referential-integrity gate =="
echo "-- positive: the repo's own specs/cluster must pass every check --"
python3 "${CHECKER}" "${REPO}/specs/cluster"
RC=$?
if [ "${RC}" -ne 0 ]; then
  echo
  echo "== cluster manifest integrity: FAIL (see above) =="
  exit 1
fi

# ── NEGATIVE CONTROLS ────────────────────────────────────────────────────────
# Stage a copy of specs/cluster, inject ONE defect of each class, and require the
# corresponding check to bite. Without these the whole gate could be a no-op.
echo
echo "-- negative controls: each injected defect must be caught --"
NEG_P=0; NEG_F=0
neg_ok(){ echo "  PASS negative control: $*"; NEG_P=$((NEG_P+1)); }
neg_bad(){ echo "  FAIL negative control: $*"; NEG_F=$((NEG_F+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# $1 = human label, $2 = expected check-id substring in the failure output,
# $3 = a shell snippet run with $T = the staged tree root, which injects the defect.
expect_catch() {
  local label="$1" want="$2" inject="$3"
  local T="${WORK}/tree"
  rm -rf "${T}"; cp -r "${REPO}/specs/cluster" "${T}"
  ( T="${T}"; eval "${inject}" ) || { neg_bad "${label} (injection itself failed)"; return; }
  local out rc
  out="$(python3 "${CHECKER}" "${T}" 2>&1)"; rc=$?
  # -F: the check ids contain [] and -, which grep would read as a bracket range.
  if [ "${rc}" -ne 0 ] && grep -qF "  FAIL ${want}" <<<"${out}"; then
    neg_ok "${label} -> caught by ${want}"
  else
    neg_bad "${label} NOT caught (rc=${rc}); wanted ${want}. Output:"
    sed 's/^/        /' <<<"${out}" | tail -20
  fi
}

# (1) a document spliced into another's block => not valid YAML at all.
expect_catch "unparseable YAML (spliced document, orphan trailing key)" "[yaml-parse]" '
  printf "        key: hugmesh/casdoor-apps\n" >> "$T/manifests/external-secrets/secretstore.yaml"
'
# (2) two objects fused into one document => duplicate top-level keys, last wins.
expect_catch "duplicate keys (two objects fused into one document)" "[yaml-duplicate-key]" '
  python3 - "$T" <<PY
import sys,io
p=sys.argv[1]+"/manifests/external-secrets/pki-externalsecrets.yaml"
s=open(p,encoding="utf-8").read()
# drop the "---" separating the wiki-bff-db VaultDynamicSecret from its
# ExternalSecret: exactly the shape the real merge produced.
s=s.replace("""      tokenSecretRef: { name: vault-token, key: token }
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata: { name: wiki-bff-db-mtls, namespace: hugmesh-backend }""","""      tokenSecretRef: { name: vault-token, key: token }
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata: { name: wiki-bff-db-mtls, namespace: hugmesh-backend }""",1)
open(p,"w",encoding="utf-8").write(s)
PY
'
# (3a) an object parked in a namespace nothing creates.
expect_catch "object in a namespace the platform never creates" "[namespace]" '
  sed -i "s/namespace: hugmesh-backend$/namespace: snapdragon-backend/" \
      "$T/manifests/mesh-bff-api/service.yaml"
'
# (3b) a gateway route uri pointing into a dead namespace.
expect_catch "gateway route uri into a dead namespace" "[namespace]" '
  sed -i "s|hugmesh-mesh-bff-api.hugmesh-backend.svc.cluster.local|hugmesh-mesh-bff-api.snapdragon-backend.svc.cluster.local|" \
      "$T/apps/20-gateway-fe.yaml"
'
# (3c) a gateway route uri whose Service does not exist.
expect_catch "gateway route uri with no such Service" "[route-service]" '
  sed -i "s|uri: https://hugmesh-mesh-bff-api.hugmesh-backend|uri: https://hugmesh-mesh-bff-api-typo.hugmesh-backend|" \
      "$T/apps/20-gateway-fe.yaml"
'
# (3d) a route-access seed row keyed to a gateway id that does not exist.
expect_catch "route-access row for a nonexistent gateway id" "[route-access-gateway]" '
  python3 - "$T" <<PY
import sys
p=sys.argv[1]+"/manifests/route-access/initdb/20-schema.sql"
s=open(p,encoding="utf-8").read()
s=s.replace("(\x27hugmesh-fe-gateway\x27,  \x27/bff/mesh/**\x27",
            "(\x27snapdragon-fe-gateway\x27,  \x27/bff/mesh/**\x27",1)
open(p,"w",encoding="utf-8").write(s)
PY
'
# (4) the exact bash bug: two `for app in` headers line-continued into one list.
expect_catch "pki-init role loop fused into one for-list (junk roles for/app/in)" "[pki-roles]" '
  python3 - "$T" <<PY
import sys
p=sys.argv[1]+"/manifests/vault-pki/pki-init-configmap.yaml"
s=open(p,encoding="utf-8").read()
s=s.replace("    for app in hugmesh-pki-gateway",
            "    for app in snapdragon-pki-gateway snapdragon-be-gateway \\\\\n"
            "    for app in hugmesh-pki-gateway",1)
open(p,"w",encoding="utf-8").write(s)
PY
'
# (5) a pod mounting an *-mtls Secret that no ExternalSecret produces.
expect_catch "pod mounts an *-mtls Secret nothing provisions" "[mtls-secret]" '
  python3 - "$T" <<PY
import sys
p=sys.argv[1]+"/manifests/external-secrets/pki-externalsecrets.yaml"
s=open(p,encoding="utf-8").read()
s=s.replace("    name: mesh-bff-db-mtls\n    creationPolicy: Owner",
            "    name: mesh-bff-db-mtls-RENAMED\n    creationPolicy: Owner",1)
open(p,"w",encoding="utf-8").write(s)
PY
'
# (6) two distinct workloads sharing one SELinux MCS category.
expect_catch "two workloads sharing an SELinux MCS category" "[mcs]" '
  sed -i "s/level: \"s0:c82\"/level: \"s0:c80\"/" \
      "$T/manifests/character-forge-bff-db/deployment.yaml"
'
# (7a) a Postgres pod with no per-pod db-ingress policy at all.
expect_catch "Postgres pod with no per-pod db-ingress policy" "[db-isolation]" '
  python3 - "$T" <<PY
import sys
p=sys.argv[1]+"/manifests/networkpolicy/db-ingress.yaml"
s=open(p,encoding="utf-8").read()
s=s.replace("    matchLabels: { app: mesh-bff-db }",
            "    matchLabels: { app: mesh-bff-db-TYPO }",1)
open(p,"w",encoding="utf-8").write(s)
PY
'
# (7b) a Postgres pod re-admitted by the broad tier policy (half the pair only).
expect_catch "Postgres pod left out of the tier-ingress NotIn exclusion" "[db-isolation]" '
  sed -i "s/, mesh-bff-db,/,/" "$T/manifests/networkpolicy/tier-ingress.yaml"
'
# (8a) a SERVICE-only internal receiver left governed only by its tier floor: the
#      deciding longest-match rule becomes an ALLOW, so every holder of that tier
#      role reaches the internal ingest from outside.
expect_catch "internal ingest left on its tier ALLOW floor (deny row removed)" "[internal-surface]" '
  sed -i "/\x27\/bff\/mesh\/internal\/\*\*\x27/d" \
      "$T/manifests/route-access/initdb/20-schema.sql"
'
# (8b) an internal receiver with NO governing row at all — weaker still, because
#      decide() returns NO_RULE and the gateway FORWARDS on the authenticated()
#      floor rather than default-denying.
expect_catch "internal ingest with no route-access row at all (NO_RULE => forwarded)" "[internal-surface]" '
  sed -i "/\x27\/bff\/internal\/\*\*\x27/d" \
      "$T/manifests/route-access/initdb/20-schema.sql"
'
# (8c) a NEWLY wired internal receiver, discovered from its in-cluster URL alone
#      (no allowlist entry) — proves the check is not a hard-coded probe list.
expect_catch "newly wired internal receiver discovered from its in-cluster URL" "[internal-surface]" '
  python3 - "$T" <<PY
import sys
p=sys.argv[1]+"/manifests/meshbridge/deployment.yaml"
s=open(p,encoding="utf-8").read()
s=s.replace("            - { name: MESHBRIDGE_REG_POLL_SECONDS, value: \"60\" }",
            "            - { name: MESHBRIDGE_NEW_SINK_URL, value: \"https://hugmesh-wiki-bff-api.hugmesh-backend.svc.cluster.local:8080/bff/wiki/internal/ingest\" }\n"
            "            - { name: MESHBRIDGE_REG_POLL_SECONDS, value: \"60\" }",1)
open(p,"w",encoding="utf-8").write(s)
PY
'

# (9a) THE SHIPPED DEFECT, re-injected: one interior array element in the Casdoor
#      seed loses its trailing comma. The ConfigMap stays perfectly valid YAML —
#      only the embedded document breaks — so [yaml-parse] must NOT be what
#      catches it.
expect_catch "Casdoor seed: interior role entry loses its trailing comma" "[json-parse]" '
  python3 - "$T" <<PY
import sys
p=sys.argv[1]+"/manifests/casdoor/init-data-configmap.yaml"
s=open(p,encoding="utf-8").read()
old="\"name\": \"ROLE_IMAGE_BUILDER\", \"displayName\": \"Image Builder\",       \"users\": [], \"roles\": [], \"domains\": [], \"isEnabled\": true },"
assert s.count(old)==1, "injection anchor matched %d times, not 1" % s.count(old)
open(p,"w",encoding="utf-8").write(s.replace(old, old[:-1], 1))
PY
'
# (9b) A DIFFERENT break class (unquoted property name) in a DIFFERENT ConfigMap,
#      under a DIFFERENT key name. Nothing about the check is keyed to the Casdoor
#      seed: any `*.json` value in any ConfigMap gets the same protection free.
expect_catch "edge-ai catalog.json: unquoted property name (different file, different key)" "[json-parse]" '
  python3 - "$T" <<PY
import sys
p=sys.argv[1]+"/manifests/edge-ai/models-configmap.yaml"
s=open(p,encoding="utf-8").read()
assert s.count("\"vramGiB\": 3,")==1
open(p,"w",encoding="utf-8").write(s.replace("\"vramGiB\": 3,", "vramGiB: 3,", 1))
PY
'
# (9c) A THIRD ConfigMap, and the OTHER half of the check: JSON that parses fine
#      but silently last-wins away a duplicated object key — the embedded-document
#      twin of the [yaml-duplicate-key] class in (2).
expect_catch "meshbridge devices.json: duplicate object key (parses, silently last-wins)" "[json-duplicate-key]" '
  python3 - "$T" <<PY
import sys
p=sys.argv[1]+"/manifests/meshbridge/devices-configmap.yaml"
s=open(p,encoding="utf-8").read()
assert s.count("{ \"devices\": [] }")==1
open(p,"w",encoding="utf-8").write(s.replace("{ \"devices\": [] }", "{ \"devices\": [], \"devices\": [] }", 1))
PY
'

echo
echo "== negative controls: ${NEG_P} passed, ${NEG_F} failed =="
[ "${NEG_F}" -eq 0 ] || exit 1
echo "== cluster manifest integrity: PASS =="
exit 0

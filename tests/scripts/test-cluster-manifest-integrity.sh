#!/usr/bin/env bash
# test-cluster-manifest-integrity.sh — static referential-integrity gate over
# specs/cluster. Pure PyYAML + bash; no cluster, no network. kubectl is optional:
# when it is on PATH, [image-pin] also renders every kustomization (see (21)).
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
#   3. Objects, Argo destinations and gateway route URIs pointed at a namespace
#      the rebrand deleted; the route-access seed carried rows for a gateway id
#      that no longer exists, so /bff/mesh/** was default-denied for every
#      ROLE_MESH holder.
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
#      `owner:` roles array in front of the rebranded one, leaving
#      what had been that array's last element as an interior element with no
#      trailing comma ("Expecting ',' delimiter: line 42 column 5"). Casdoor
#      imports the file wholesale on boot, so the WHOLE identity seed — the
#      organization, every role including ROLE_IMAGE_BUILDER, every svc-* user —
#      was silently skipped. The ConfigMap around it is flawless YAML, so check
#      (1) passed it happily: a ConfigMap value is a FILE in another language and
#      nothing in this gate had ever looked inside one.
#
#  10. The SUPERADMIN Service Catalog console shipped with four of its five links
#      present and the middle one MISSING. A federation descriptor named a Service;
#      a superadmin-gateway route forwarded to that Service; a route-access row
#      gated its path ROLE_SUPERADMIN; docs/SECURITY.md reserved its SA + MCS
#      category. There was no Deployment and no Service, so every request to the
#      console 503'd at the gateway. Worse, the ONE check that could have seen it —
#      [route-service] — had been taught to EXEMPT that exact Service with the
#      rationale "rendered by the service-catalog-builder ApplicationSet (apps/54)".
#      apps/54 is `kind: Application`, NOT an ApplicationSet, and its kustomization
#      renders a Namespace and a NetworkPolicy. Every clause of that rationale was
#      false; the gate ran, PASSED, and counted the route as resolved. The exemption
#      is deleted, and [federation-remote] now walks the whole chain from the
#      descriptor outward: Service -> backing workload -> the Application that syncs
#      its directory -> the gateway route at mountAt -> the route-access row.
#  11. That console's gateway route ALSO shipped with no StripPrefix. The remote is a
#      standalone nginx with <base href="/"> and an SPA `try_files ... /index.html`,
#      so /superadmin/service-catalog/remoteEntry.json comes back as index.html with
#      HTTP 200 and Content-Type text/html; native federation JSON.parses that HTML
#      and the page renders BLANK — a 200, not a 404, which is why review does not
#      catch it. apps/20-gateway-fe.yaml carried exactly this on EVERY micro-frontend
#      remote for years before it was found.
#  12. manifests/service-catalog-builder/kaniko-build-job.template.yaml mounts the
#      Secret `service-catalog-builder-registry` NON-optionally and nothing created
#      it. A non-optional secret volume is a hard kubelet precondition, so a real
#      build would have been created successfully and then sat in ContainerCreating/
#      FailedMount for its whole activeDeadlineSeconds (1800s) — a silent half-hour
#      hang, not an error the calling effector could surface. Because the Job is a
#      TEMPLATE, ArgoCD never applies it, so nothing else here could see it.
#  13. docs/SECURITY.md had RESERVED s0:c49 for that console before its Deployment
#      existed. edge-ai-analysis later took c49 as "next free" — correctly, by the
#      only evidence available to it: a scan of the live manifests, where nothing
#      carried c49. [mcs] could not see the clash either, because it compares
#      WORKLOADS and a reservation with no Deployment is not one. The durable defect
#      was that edge-ai-analysis had NO ROW in the matrix at all, so it was invisible
#      to the next "next free" scan.
#
# ── FOUND BY REVIEW OF 10-13, 2026-08-26 — THE GUARDS THEMSELVES WERE THE DEFECT ──
# An adversarial reviewer re-broke production against the first cut of 10-13 and
# four of the breakages went undetected. Those are 14-17; 18-19 are two mutations
# the first cut had DECLARED as surviving and left open.
#
#  14. [remote-strip-prefix] REPORTED A PASS WHILE ITS OWN DEFECT WAS PRESENT.
#      It discovered a "remote" only via a FederationModuleRegistration descriptor
#      (1 in the tree) or a workload whose HTTP probe path ends in /remoteEntry.json
#      (2: character-forge, character-studio). The other EIGHT micro-frontend routes
#      on apps/20-gateway-fe.yaml — matrix-ui, mastodon-ui, forum-ui, login-ui,
#      admin-ui, mod-ui, user-ui, api-docs — name remoteEntry.json only in header
#      COMMENTS, so they were invisible. Deleting the StripPrefix from /admin/** and
#      /social/matrix/** left the gate at "21 checks passed, 0 findings". Discovery
#      is now the TIER (any gateway route into a namespace where a descriptor/probe
#      DID find a bundle root), with two derived exclusions — apex-served and
#      self-served-prefix — both PRINTED by name on the pass line.
#  15. COMMENT-TOKEN INVERSION, the house trap, inside [federation-remote] step (e):
#      it re.search()ed the RAW text of 20-schema.sql for `('<gw>', '<pattern>',`
#      with no anchor and no comment stripping. Turning the row into
#      `-- DISABLED ('hugmesh-superadmin-gateway', ...` satisfied the check while
#      initdb never seeds it, decide() returns NO_RULE, and the tailnet-only
#      SUPERADMIN remote is forwarded on the coarse authenticated() floor. The
#      file's OWN older parsers (ROW_RE) were comment-safe; the new one was not.
#  16. TWO SILENT ESCAPE HATCHES IN [build-template-secret]. (a) it collected only
#      NON-optional mounts, so one added `optional: true` line dropped the kaniko
#      push credential out of the checked set — the pass line shrank from "all 2" to
#      "all 1" and nothing failed, though kaniko then starts with no
#      /kaniko/.docker/config.json and the push 401s. (b) `if not refs: continue`
#      skipped a whole directory in silence, so deleting the credential volume
#      outright was cheaper than renaming it.
#  17. "A YAML FILE EXISTS ON DISK" WAS TREATED AS "THE SECRET IS PROVISIONED".
#      Deleting ONLY the line that wires the new ExternalSecret into
#      external-secrets/kustomization.yaml left the gate green: ArgoCD would never
#      apply it, the Secret would never materialise, and the build pod would hang in
#      ContainerCreating for its full 1800s deadline — defect 12, restored. This is
#      the standard [federation-remote] step (c) already stated out loud.
#  18. A CROSS-NAMESPACE GATEWAY ROUTE ONTO A DEFAULT-DENIED POD. k8s NetworkPolicy
#      is additive with no deny, so the moment any Ingress policy selects a pod only
#      the union of the selecting from-sets can reach it. Deleting
#      manifests/networkpolicy/superadmin-ui-ingress.yaml was free. Closing this
#      found THREE more live instances nothing had ever checked: superadmin-gateway
#      (hugmesh-pki) -> admin-bff-api and -> federation-api, both blocked by the
#      hugmesh-backend tier from-set, and the fe-gateway's four matrix/mastodon
#      routes onto the homeserver mTLS proxies, which homeserver-isolation.yaml
#      admits only from hugmesh-backend pods. See
#      manifests/networkpolicy/gateway-crossns-ingress.yaml.
#  19. THE SERVICEACCOUNT COLUMN OF docs/SECURITY.md §3 WAS PROSE. [mcs-documented]
#      pinned the SELinux half of the identity matrix; changing a Deployment's
#      serviceAccountName off the RESERVED name, deleting the line, or deleting the
#      ServiceAccount object all cost nothing.
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

# [mcs-documented] compares the tree against docs/SECURITY.md, which lives OUTSIDE
# the tree. The negative controls stage a copy of specs/cluster alone, so the
# checker's default <root>/../../docs cannot resolve there and the check would fail
# in EVERY staged run — noise that would train people to ignore it. Point it at the
# real docs dir; a control that needs a MUTATED docs tree overrides this by writing
# its path into ${WORK}/docsdir (see the [mcs-documented] rationale control).
export HUGMESH_DOCS_DIR="${REPO}/docs"
# [relay-host] also reads the brand twin templates/apps/20-gateway-be.yaml.hbs, which
# lives outside the staged specs/cluster copy; same arrangement as the docs dir (a
# control that needs a MUTATED template writes its path into ${WORK}/tpldir).
export HUGMESH_TEMPLATES_DIR="${REPO}/templates"
[ -f "${HUGMESH_DOCS_DIR}/SECURITY.md" ] || {
  echo "  FAIL cannot find ${HUGMESH_DOCS_DIR}/SECURITY.md — [mcs-documented] has no authority to compare against"; exit 1; }

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
# [image-pin]'s kubectl render cross-check is switched off for the controls: each
# control must be caught by the STATIC reader alone (CI has no kubectl), and a
# render per control would add minutes. (21-render) tests the render path itself.
export HUGMESH_IMAGE_PIN_RENDER=0
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
  rm -f "${WORK}/docsdir" "${WORK}/tpldir"
  local before after
  before="$(find "${T}" -type f -exec md5sum {} + | sort | md5sum)"
  ( T="${T}"; WORK="${WORK}"; REPO="${REPO}"; eval "${inject}" ) \
    || { neg_bad "${label} (injection itself failed)"; return; }
  after="$(find "${T}" -type f -exec md5sum {} + | sort | md5sum)"
  # An injection that matched nothing is the classic way one of these controls goes
  # quietly vacuous (see control (4)'s asserted anchor and (3a)'s never-existent
  # namespace). A control whose sed silently no-op'd would run, find no defect, and
  # report the GATE as broken while the gate was fine — or, worse, be "fixed" by
  # relaxing the gate. So the tree MUST actually differ, unless the control
  # deliberately mutates something outside the tree and says so via ${WORK}/docsdir.
  local docs="${HUGMESH_DOCS_DIR}"
  [ -f "${WORK}/docsdir" ] && docs="$(cat "${WORK}/docsdir")"
  local tpl="${HUGMESH_TEMPLATES_DIR}"
  [ -f "${WORK}/tpldir" ] && tpl="$(cat "${WORK}/tpldir")"
  if [ "${before}" = "${after}" ] && [ ! -f "${WORK}/docsdir" ] && [ ! -f "${WORK}/tpldir" ]; then
    neg_bad "${label} (INJECTION CHANGED NOTHING — the anchor has drifted; this control proves nothing)"
    return
  fi
  local out rc
  out="$(HUGMESH_DOCS_DIR="${docs}" HUGMESH_TEMPLATES_DIR="${tpl}" python3 "${CHECKER}" "${T}" 2>&1)"; rc=$?
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
#      The planted namespace is deliberately a name NO brand ever had. These three
#      controls used to plant the retired brand's namespace / gateway id, so a rename
#      sweep collapsed each sed into `s/X/X/` — a no-op that still runs, leaving the
#      control reporting the GATE as broken while the gate was fine. A never-existent
#      name cannot be renamed into a live one by the next sweep.
expect_catch "object in a namespace the platform never creates" "[namespace]" '
  sed -i "s/namespace: hugmesh-backend$/namespace: nosuch-backend/" \
      "$T/manifests/mesh-bff-api/service.yaml"
'
# (3b) a gateway route uri pointing into a dead namespace.
expect_catch "gateway route uri into a dead namespace" "[namespace]" '
  sed -i "s|hugmesh-mesh-bff-api.hugmesh-backend.svc.cluster.local|hugmesh-mesh-bff-api.nosuch-backend.svc.cluster.local|" \
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
            "(\x27nosuch-fe-gateway\x27,  \x27/bff/mesh/**\x27",1)
open(p,"w",encoding="utf-8").write(s)
PY
'
# (4) the exact bash bug: two `for entry in` headers line-continued into one list.
#     The anchor is ASSERTED, because this control silently no-op'd (and stayed
#     "green") the day the loop was reshaped from `for app in <name>` to
#     `for entry in <role>:<service>.<namespace>` — an injection that matches
#     nothing proves nothing.
expect_catch "pki-init role loop fused into one for-list (junk roles for/entry/in)" "[pki-roles]" '
  python3 - "$T" <<"PY"
import sys
p=sys.argv[1]+"/manifests/vault-pki/pki-init-configmap.yaml"
s=open(p,encoding="utf-8").read()
anchor="    for entry in hugmesh-pki-gateway:"
assert s.count(anchor)==1, "for-entry loop anchor matched %d times, not 1" % s.count(anchor)
fused=("    for entry in hugmesh-pki-gateway:hugmesh-pki-gateway.hugmesh-pki \\\n"
       "    for entry in hugmesh-pki-gateway:")
open(p,"w",encoding="utf-8").write(s.replace(anchor,fused,1))
PY
'
# (4b) hugmesh-generator#622: the be gateway headscale-forward relay loses its
#      PreserveHostHeader filter, so the pki gateway sees its own Service DNS name
#      and Host=scale.<domain> can never match its headscale route.
expect_catch "be headscale-forward relay without PreserveHostHeader" "[relay-host]" '
  python3 - "$T" <<PY
import sys
p=sys.argv[1]+"/apps/20-gateway-be.yaml"
s=open(p,encoding="utf-8").read()
assert s.count("              - PreserveHostHeader\n")==1
open(p,"w",encoding="utf-8").write(s.replace("              - PreserveHostHeader\n","              - AddRequestHeader=X-Relay, 1\n",1))
PY
'
# (4c) ...and the same drift in the brand twin, which is outside the staged tree.
expect_catch "brand template headscale-forward relay without PreserveHostHeader" "[relay-host]" '
  rm -rf "$WORK/mtpl"; cp -r "$REPO/templates" "$WORK/mtpl"
  sed -i "s/^              - PreserveHostHeader$/              - AddRequestHeader=X-Relay, 1/" "$WORK/mtpl/apps/20-gateway-be.yaml.hbs"
  ! grep -q "PreserveHostHeader" "$WORK/mtpl/apps/20-gateway-be.yaml.hbs"
  printf "%s" "$WORK/mtpl" > "$WORK/tpldir"
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
# (7c) a per-pod policy that selects the DB pod on the EGRESS axis only. Ingress and
#      Egress are independent axes, so such a policy proves NOTHING about who may dial
#      5432 — but a checker that reads podSelector without reading policyTypes counts it
#      as the isolation and passes. Real risk, not hypothetical: networkpolicy/
#      db-egress.yaml selects all five backend DB pods on exactly that axis.
expect_catch "per-pod policy on the EGRESS axis only counted as ingress isolation" "[db-isolation]" '
  python3 - "$T" <<PY
import sys
p=sys.argv[1]+"/manifests/networkpolicy/db-ingress.yaml"
s=open(p,encoding="utf-8").read()
old="""
  name: db-ingress-mesh-bff-db
  namespace: hugmesh-backend
  labels: { app: mesh-bff-db, app.kubernetes.io/part-of: hugmesh.net }
spec:
  podSelector:
    matchLabels: { app: mesh-bff-db }
  policyTypes: [Ingress]"""
assert old in s, "anchor drifted"
s=s.replace(old, old.replace("policyTypes: [Ingress]", "policyTypes: [Egress]"), 1)
open(p,"w",encoding="utf-8").write(s)
PY
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

# (10a) the admin-bff MFA factor-key ref regressing to optional:true — the exact
#       revert of the required posture docs/MFA-ROLLOUT.md §4.1 documents. Every
#       gate passed green on this plant before [mfa-factor-key] existed.
expect_catch "APP_MFA_FACTOR_KEY secretKeyRef regressed to optional:true" "[mfa-factor-key]" '
  python3 - "$T" <<PY
import sys
p=sys.argv[1]+"/manifests/admin-bff-api/deployment.yaml"
s=open(p,encoding="utf-8").read()
old="""                secretKeyRef:
                  name: admin-bff-mfa
                  key: factor-key"""
assert old in s, "factor-key ref anchor missing"
s=s.replace(old, old+"\n                  optional: true",1)
open(p,"w",encoding="utf-8").write(s)
PY
'
# (10b) a typo'd key on a Secret an ExternalSecret really declares — the key can
#       never exist, so a REQUIRED ref parks the pod in CreateContainerConfigError
#       forever. Gate 3 accepted exactly this plant (factor-keyX) before [secret-key].
expect_catch "secretKeyRef key that the ExternalSecret never materializes" "[secret-key]" '
  sed -i "s/^\(                  key: factor-key\)$/\1X/" \
      "$T/manifests/admin-bff-api/deployment.yaml"
'
# (10c) the APP_MFA_FACTOR_KEY env deleted outright — the posture pin must notice
#       it has NOTHING to hold, or the whole [mfa-factor-key] check is vacuous the
#       day someone renames the env var.
expect_catch "APP_MFA_FACTOR_KEY env var deleted (posture pin must not go vacuous)" "[mfa-factor-key]" '
  python3 - "$T" <<PY
import sys,re
p=sys.argv[1]+"/manifests/admin-bff-api/deployment.yaml"
s=open(p,encoding="utf-8").read()
pat=re.compile(r"            - name: APP_MFA_FACTOR_KEY\n(?:              .*\n)+?                  key: factor-key\n")
assert pat.search(s), "factor-key env block anchor missing"
open(p,"w",encoding="utf-8").write(pat.sub("",s,count=1))
PY
'

# (11a) the kopia repo-password ExternalSecret sourcing a Vault property nothing
#       seeds — ESO never syncs, the Secret never materializes, and Velero quietly
#       keys every kopia repo with upstream's WELL-KNOWN static default password.
expect_catch "velero repo-password ES sources a Vault property nothing seeds" "[velero-repo-credentials]" '
  python3 - "$T" <<PY
import sys
p=sys.argv[1]+"/manifests/external-secrets/velero-externalsecrets.yaml"
s=open(p,encoding="utf-8").read()
old="remoteRef: { key: hugmesh/velero, property: repo_password }"
assert s.count(old)==1, "repo_password remoteRef anchor matched %d times, not 1" % s.count(old)
open(p,"w",encoding="utf-8").write(s.replace(old, old.replace("repo_password","repo_passwordX"),1))
PY
'
# (11b) the recurring-schedule template wired into the ACTIVE kustomization — the
#       exact one-line "helpful cleanup" that would make a default sync start
#       applying a Schedule the feature contract ships dark.
expect_catch "velero Schedule template uncommented into the active kustomization" "[velero-schedule-dark]" '
  sed -i "s|^  # - schedule-template.yaml$|  - schedule-template.yaml|" \
      "$T/manifests/velero/kustomization.yaml"
  grep -q "^  - schedule-template.yaml$" "$T/manifests/velero/kustomization.yaml"
'
# (11c) the template regressing to paused:false — gate 2 of the double-dark
#       contract; an operator who later uncomments the resource line would get
#       real nightly backups instead of an inert paused Schedule.
expect_catch "velero Schedule template regressed to paused:false" "[velero-schedule-dark]" '
  sed -i "s/^  paused: true$/  paused: false/" \
      "$T/manifests/velero/schedule-template.yaml"
  grep -q "^  paused: false$" "$T/manifests/velero/schedule-template.yaml"
'

# A Deployment an HPA scales must not pin spec.replicas — both write that field,
# so GitOps and the autoscaler overwrite each other forever. Measured on kind
# 2026-08-22: seven Deployments at generation ~950-964 after 38h, one rewrite
# every ~2.4 minutes, Applications permanently OutOfSync while every pod was
# Running and healthy. Nothing looked wrong except a sync status that never
# cleared, which is exactly why this needs a guard and not a code review.
expect_catch "a Deployment re-pins replicas the HPA owns" "[hpa-replicas]" '
  sed -i "0,/^spec:$/s//spec:\n  replicas: 1/" \
      "$T/manifests/admin-bff-api/deployment.yaml"
  grep -q "^  replicas: 1$" "$T/manifests/admin-bff-api/deployment.yaml"
'

# ── (11b) THE CHAT3D GAMES ORIGIN (hugmesh-generator#470) ────────────────────
# The matrix-ui Deployment states HUG_GAMES_URL, and it must be the host the be
# gateway routes to the games portal. Two defects, one control each, plus a control
# that the check does not bite a profile that does not install games.
expect_catch "matrix-ui HUG_GAMES_URL env deleted while games is installed" "[games-origin]" '
  sed -i "/name: HUG_GAMES_URL/d" "$T/manifests/social-ui/deployment.yaml"
  ! grep -qE "^[[:space:]]*- \{ name: HUG_GAMES_URL" "$T/manifests/social-ui/deployment.yaml"
'
expect_catch "HUG_GAMES_URL names a different host than the gateway games route" "[games-origin]" '
  sed -i "s#value: \"https://games.hugmesh.net\" }#value: \"https://games.elsewhere.example\" }#" \
      "$T/manifests/social-ui/deployment.yaml"
  grep -q "games.elsewhere.example" "$T/manifests/social-ui/deployment.yaml"
'
# The gateway host moved but the manifest literal did not (a repo-tree edit of one
# side only; this checks the tree, not what a builder bakes or what ArgoCD serves).
expect_catch "gateway games host rewritten while the matrix-ui literal is left behind" "[games-origin]" '
  sed -i "s#games\\.hugmesh\\.net#games.acme.example#g" "$T/apps/20-gateway-be.yaml"
  grep -q "host: games.acme.example" "$T/apps/20-gateway-be.yaml"
'
# NOT vacuous the other way: a profile with no games Application is not asked for
# an origin. Stage it, drop 50-games.yaml and the env, and require a clean verdict.
{
  T="${WORK}/tree"; rm -rf "${T}"; cp -r "${REPO}/specs/cluster" "${T}"
  rm -f "${T}/apps/50-games.yaml"
  sed -i "/name: HUG_GAMES_URL/d" "${T}/manifests/social-ui/deployment.yaml"
  out="$(HUGMESH_DOCS_DIR="${HUGMESH_DOCS_DIR}" HUGMESH_TEMPLATES_DIR="${HUGMESH_TEMPLATES_DIR}" python3 "${CHECKER}" "${T}" 2>&1 || true)"
  if grep -qF "  PASS [games-origin]" <<<"${out}" && ! grep -qF "  FAIL [games-origin]" <<<"${out}"; then
    neg_ok "no games Application and no env -> [games-origin] passes (not asked for an origin)"
  else
    neg_bad "a profile without games was asked for a games origin (or the check vanished):"
    grep -F "[games-origin]" <<<"${out}" | sed 's/^/        /'
  fi
}

# ── (12) THE SUPERADMIN SERVICE CATALOG CHAIN ────────────────────────────────
# (12a) THE SHIPPED DEFECT, re-injected: the console's Service deleted. Before this
#       PR the ROUTE_SERVICE_ALLOW set exempted exactly this Service ("rendered by
#       the service-catalog-builder ApplicationSet") and [route-service] reported a
#       clean pass with the Service absent. With the false exemption gone it bites.
expect_catch "superadmin service-catalog Service deleted (the exemption that hid it is gone)" "[route-service]" '
  python3 - "$T" <<SCPY
import sys
p=sys.argv[1]+"/manifests/superadmin-service-catalog-ui/deployment.yaml"
s=open(p,encoding="utf-8").read()
i=s.index("apiVersion: v1\nkind: Service")
open(p,"w",encoding="utf-8").write(s[:s.rindex("---",0,i)])
SCPY
'
# (12b) …and the descriptor-driven chain catches the SAME deletion independently, so
#       the console stays covered even if a route allowlist entry is ever re-added.
expect_catch "the same deleted Service, caught from the federation descriptor" "[federation-remote]" '
  python3 - "$T" <<SCPY
import sys
p=sys.argv[1]+"/manifests/superadmin-service-catalog-ui/deployment.yaml"
s=open(p,encoding="utf-8").read()
i=s.index("apiVersion: v1\nkind: Service")
open(p,"w",encoding="utf-8").write(s[:s.rindex("---",0,i)])
SCPY
'
# (12c) the Service kept, the Deployment deleted: a Service with no endpoints looks
#       perfectly healthy in `kubectl get svc` and refuses every connection.
expect_catch "remote Service with no backing workload (no endpoints)" "[federation-remote]" '
  python3 - "$T" <<SCPY
import sys
p=sys.argv[1]+"/manifests/superadmin-service-catalog-ui/deployment.yaml"
s=open(p,encoding="utf-8").read()
i=s.index("apiVersion: apps/v1\nkind: Deployment"); j=s.index("apiVersion: v1\nkind: Service")
open(p,"w",encoding="utf-8").write(s[:i]+s[j:])
SCPY
'
# (12d) manifests present and correct, but NO Application syncs the directory —
#       correct YAML that ArgoCD never applies is indistinguishable from no YAML.
expect_catch "remote manifest dir that no Application syncs" "[federation-remote]" '
  rm "$T/apps/49d-superadmin-service-catalog-ui.yaml"
'
# (12e) the descriptor mountAt drifts away from the gateway route — the exact
#       three-way disagreement this PR reconciled (descriptor + route-access said
#       /superadmin/service-catalog while docs/ARCHITECTURE.md said /appstore).
expect_catch "descriptor mountAt drifts off the gateway route" "[federation-remote]" '
  sed -i "s|^  mountAt: /superadmin/service-catalog$|  mountAt: /appstore|" \
      "$T/manifests/federation-api/register-superadmin-service-catalog.descriptor.yaml"
  grep -q "^  mountAt: /appstore$" "$T/manifests/federation-api/register-superadmin-service-catalog.descriptor.yaml"
'
# (12f) the descriptor advertises a port the Service does not serve. That URL is
#       handed to the browser verbatim, so it is a connection refused at runtime.
expect_catch "descriptor remoteEntry port the Service does not expose" "[federation-remote]" '
  sed -i "s|svc.cluster.local:8080/remoteEntry.json|svc.cluster.local:8081/remoteEntry.json|" \
      "$T/manifests/federation-api/register-superadmin-service-catalog.descriptor.yaml"
  grep -q "svc.cluster.local:8081/remoteEntry.json" "$T/manifests/federation-api/register-superadmin-service-catalog.descriptor.yaml"
'
# (12g) the route-access row for the mountAt removed: decide() returns NO_RULE and the
#       gateway FORWARDS an internal/SUPERADMIN remote on the authenticated() floor.
expect_catch "mountAt route-access row deleted (NO_RULE => forwarded)" "[federation-remote]" '
  sed -i "/superadmin\/service-catalog\/\*\*/d" \
      "$T/manifests/route-access/initdb/20-schema.sql"
'

# ── (13) THE STRIP-PREFIX / BLANK-PAGE CLASS ─────────────────────────────────
# (13a) THE SHIPPED DEFECT, re-injected: the console route with no StripPrefix. The
#       page renders BLANK on an HTTP 200, which is why this needs a gate, not a
#       reviewer.
expect_catch "federation remote route with no StripPrefix (blank page on a 200)" "[remote-strip-prefix]" '
  python3 - "$T" <<SCPY
import sys
p=sys.argv[1]+"/apps/22-gateway-superadmin.yaml"
s=open(p,encoding="utf-8").read()
i=s.index("          - id: superadmin-service-catalog-ui")
j=s.index("          - id: superadmin-federation")
blk=s[i:j]
assert "StripPrefix=2" in blk, "the console route no longer carries StripPrefix=2"
open(p,"w",encoding="utf-8").write(s[:i]+blk[:blk.index("            filters:")]+s[j:])
SCPY
'
# (13b) the strip present but OFF BY ONE. Stripping too few leaves a prefix the
#       container has no files under — the same index.html-with-200 outcome as (13a).
expect_catch "federation remote route strips the wrong depth (2 -> 1)" "[remote-strip-prefix]" '
  sed -i "s/^              - StripPrefix=2$/              - StripPrefix=1/" \
      "$T/apps/22-gateway-superadmin.yaml"
  grep -q "^              - StripPrefix=1$" "$T/apps/22-gateway-superadmin.yaml"
'
# (13c) a DIFFERENT remote on a DIFFERENT gateway, discovered by its own
#       /remoteEntry.json probe rather than by any descriptor — proves the check is
#       derived, not a list of this feature's routes.
expect_catch "character-forge route loses ITS strip (different gateway, discovered by probe)" "[remote-strip-prefix]" '
  python3 - "$T" <<SCPY
import sys
p=sys.argv[1]+"/apps/20-gateway-fe.yaml"
s=open(p,encoding="utf-8").read()
old="""            path: /character-forge/**
            filters:
              - StripPrefix=1
"""
assert s.count(old)==1, "character-forge route anchor matched %d times, not 1" % s.count(old)
open(p,"w",encoding="utf-8").write(s.replace(old,"            path: /character-forge/**\n",1))
SCPY
'

# ── (14) THE BUILD-TEMPLATE SECRET CLASS ─────────────────────────────────────
# (14a) THE DERIVATION PROOF: rename the Secret in the KANIKO TEMPLATE ONLY. The
#       ExternalSecret is untouched and still perfectly valid; only the template now
#       asks for a name nothing provides. A check that hardcoded the Secret name
#       would stay green here — that is the whole difference between a guard and a
#       restatement of a literal.
expect_catch "kaniko template renames its Secret (nothing else changes)" "[build-template-secret]" '
  sed -i "s/^            secretName: service-catalog-registry-credentials$/            secretName: service-catalog-registry-credentials-RENAMED/" \
      "$T/manifests/service-catalog-builder/kaniko-build-job.template.yaml"
  grep -q "secretName: service-catalog-registry-credentials-RENAMED" \
      "$T/manifests/service-catalog-builder/kaniko-build-job.template.yaml"
'
# (14b) the other direction — THE SHIPPED DEFECT re-injected: no ExternalSecret, the
#       template still mounting the Secret non-optionally. A real build hangs in
#       ContainerCreating for its full 1800s deadline and reports nothing.
expect_catch "the builder push ExternalSecret removed (template mount left dangling)" "[build-template-secret]" '
  python3 - "$T" <<SCPY
import sys
p=sys.argv[1]+"/manifests/external-secrets/service-catalog-builder-externalsecrets.yaml"
s=open(p,encoding="utf-8").read()
old="    name: service-catalog-registry-credentials\n    creationPolicy: Owner"
assert s.count(old)==1, "ES target anchor matched %d times, not 1" % s.count(old)
s=s.replace(old,"    name: service-catalog-registry-credentials-X\n    creationPolicy: Owner",1)
s=s.replace("  name: service-catalog-registry-credentials\n","  name: service-catalog-registry-credentials-X\n",1)
open(p,"w",encoding="utf-8").write(s)
SCPY
'

# ── (15) THE UNLISTED-MCS-CATEGORY CLASS ─────────────────────────────────────
# (15a) a workload takes a category that appears in NO row of the identity matrix —
#       exactly the state edge-ai-analysis was in when it squatted the reserved c49.
expect_catch "workload claims an MCS category the SECURITY.md matrix never lists" "[mcs-documented]" '
  sed -i "s/^          level: \"s0:c49\"$/          level: \"s0:c99\"/" \
      "$T/manifests/superadmin-service-catalog-ui/deployment.yaml"
  grep -q "s0:c99" "$T/manifests/superadmin-service-catalog-ui/deployment.yaml"
'
# (15b) the console takes the category edge-ai-analysis was MOVED to — the plain
#       collision, which [mcs] (not [mcs-documented]) must be the one to catch.
expect_catch "console re-collides with edge-ai-analysis on s0:c87" "[mcs]" '
  sed -i "s/^          level: \"s0:c49\"$/          level: \"s0:c87\"/" \
      "$T/manifests/superadmin-service-catalog-ui/deployment.yaml"
  grep -q "s0:c87" "$T/manifests/superadmin-service-catalog-ui/deployment.yaml"
'
# (15c) AN EXEMPTION WHOSE RATIONALE STOPS BEING TRUE. This gate lost weeks to a
#       false exemption rationale (see WHY #10), so MCS_DOC_EXEMPT entries are
#       self-verifying: the named evidence file must actually discuss the level. Here
#       the TREE is untouched and the DOCS are mutated instead — the one control that
#       legitimately changes nothing under $T, which is why it writes ${WORK}/docsdir.
expect_catch "an MCS exemption whose stated evidence no longer mentions the level" "[mcs-documented]" '
  rm -rf "$WORK/mdocs"; cp -r "$REPO/docs" "$WORK/mdocs"
  sed -i "s|s0:c85/s0:c86|s0:cXX/s0:cYY|g" "$WORK/mdocs/DOMAIN-IDP.md"
  grep -q "s0:cXX/s0:cYY" "$WORK/mdocs/DOMAIN-IDP.md"
  printf "%s" "$WORK/mdocs" > "$WORK/docsdir"
'

# ── (16) THE REVIEW FINDINGS OF 2026-08-26, EACH AS ITS OWN CONTROL ──────────
# An adversarial reviewer re-broke production against the first cut of checks
# 12-15 and four mutations survived. Each one is a control below, so the same
# hand cannot pass twice.

# (16a) THE HEADLINE. Delete the StripPrefix from /admin/** — a micro-frontend route
#       with NO descriptor and NO /remoteEntry.json probe, i.e. the MAJORITY in-repo
#       shape. The first cut discovered remotes only two ways and found 3 of 11, so
#       this exact deletion (the shipped defect class, on the gateway the fix commit
#       said carried it "for years") left the gate at 21/0. Discovery is now the TIER.
expect_catch "strip deleted from a route with NO descriptor and NO probe (/admin/**)" "[remote-strip-prefix]" '
  python3 - "$T" <<SCPY
import sys
p=sys.argv[1]+"/apps/20-gateway-fe.yaml"
s=open(p,encoding="utf-8").read()
old="""            path: /admin/**
            filters:
              - StripPrefix=1
"""
assert s.count(old)==1, "admin-ui route anchor matched %d times, not 1" % s.count(old)
open(p,"w",encoding="utf-8").write(s.replace(old,"            path: /admin/**\n",1))
SCPY
'
# (16b) …and the same on /social/matrix/**, the other route the reviewer broke. Two
#       different depths (1 and 2) so an off-by-one in the widening cannot pass both.
expect_catch "strip deleted from /social/matrix/** (depth 2, comment-only remote)" "[remote-strip-prefix]" '
  python3 - "$T" <<SCPY
import sys
p=sys.argv[1]+"/apps/20-gateway-fe.yaml"
s=open(p,encoding="utf-8").read()
old="""            path: /social/matrix/**
            filters:
              - StripPrefix=2
"""
assert s.count(old)==1, "matrix-ui route anchor matched %d times, not 1" % s.count(old)
open(p,"w",encoding="utf-8").write(s.replace(old,"            path: /social/matrix/**\n",1))
SCPY
'
# (16c) THE APEX EXCLUSION IS DERIVED, NOT LISTED. remote-deeplink-to-host-shell
#       forwards eight remote paths to the host shell WITHOUT a strip, and correctly
#       so: the shell is mounted at `/` and owns the whole path. The check knows that
#       only because the same Service is also this gateway's `/**` target. Remove the
#       apex route and those eight must immediately become strip-failures — otherwise
#       the exclusion is a hardcoded blind spot wearing a derivation's clothes.
expect_catch "host-shell loses its apex /** route (the strip exclusion must stop applying)" "[remote-strip-prefix]" '
  python3 - "$T" <<SCPY
import sys
p=sys.argv[1]+"/apps/20-gateway-fe.yaml"
s=open(p,encoding="utf-8").read()
old="""          - id: frontend-host
            uri: http://hugmesh-host-shell.hugmesh-frontend.svc.cluster.local:80
            path: /**
"""
assert s.count(old)==1, "frontend-host route anchor matched %d times, not 1" % s.count(old)
open(p,"w",encoding="utf-8").write(s.replace(old,"",1))
SCPY
'
# (16d) THE SELF-SERVED EXCLUSION IS READ OUT OF THE NGINX CONFIG, NOT THE NAME.
#       /_fragments/** must NOT strip, because manifests/remote-fragment/nginx.conf
#       really does serve content-addressed bundles under /_fragments/. Rename those
#       location blocks and the same route must become a strip-failure.
expect_catch "remote-fragment nginx stops serving /_fragments (its skip must stop applying)" "[remote-strip-prefix]" '
  sed -i "s|location ~\* \^/_fragments/|location ~* ^/nolonger/|; s|location /_fragments/ {|location /nolonger/ {|" \
      "$T/manifests/remote-fragment/nginx.conf"
  grep -c "_fragments" "$T/manifests/remote-fragment/nginx.conf" >/dev/null
  ! grep -q "location.*_fragments" "$T/manifests/remote-fragment/nginx.conf"
'
# (16e) A CORRECTLY-STRIPPED ROUTE POINTED AT THE WRONG REMOTE — declared as a
#       surviving mutation in the first cut. StripPrefix=2 is exactly as valid
#       forwarding /social/matrix/** to the Mastodon shell as to the Matrix one; the
#       Service exists, the pod is healthy, and the user simply gets the wrong app.
expect_catch "correctly-stripped /social/matrix/** pointed at the MASTODON remote" "[remote-route-target]" '
  python3 - "$T" <<SCPY
import sys
p=sys.argv[1]+"/apps/20-gateway-fe.yaml"
s=open(p,encoding="utf-8").read()
old="""          - id: matrix-ui
            uri: http://hugmesh-matrix-ui.hugmesh-frontend.svc.cluster.local:80
            path: /social/matrix/**"""
assert s.count(old)==1, "matrix-ui uri anchor matched %d times, not 1" % s.count(old)
open(p,"w",encoding="utf-8").write(s.replace(
    old, old.replace("hugmesh-matrix-ui.hugmesh-frontend","hugmesh-mastodon-ui.hugmesh-frontend"),1))
SCPY
'
# (16f) COMMENT-TOKEN INVERSION, the house trap. Control (12g) only ever DELETED the
#       route-access row; the reviewer COMMENTED IT OUT instead and step (e) — which
#       re.search()ed the raw file text with no anchor — accepted `-- DISABLED (...`
#       as proof of the very row whose absence it exists to report. initdb never runs
#       a commented row: decide() returns NO_RULE and the tailnet-only SUPERADMIN
#       remote is forwarded on the coarse authenticated() floor.
expect_catch "mountAt route-access row COMMENTED OUT rather than deleted" "[federation-remote]" '
  python3 - "$T" <<SCPY
import sys
p=sys.argv[1]+"/manifests/route-access/initdb/20-schema.sql"
lines=open(p,encoding="utf-8").read().splitlines(True)
n=0
for i,l in enumerate(lines):
    if "\x27/superadmin/service-catalog/**\x27" in l and l.lstrip().startswith("("):
        lines[i]="  -- DISABLED "+l.lstrip(); n+=1
assert n==1, "expected exactly 1 seed row to comment out, found %d" % n
open(p,"w",encoding="utf-8").write("".join(lines))
SCPY
'
# (16g) `optional: true` AS A SILENT ESCAPE HATCH. The first cut collected only
#       NON-optional mounts, so one added line dropped the kaniko push credential out
#       of the checked set: the pass line went from "all 2" to "all 1" and nothing
#       failed. Here the shipped defect (no ExternalSecret) is re-injected WITH the
#       optional flag — which does not make the build work, it only moves the death
#       from FailedMount to a 401 after a full image build.
expect_catch "push credential marked optional:true AND its ExternalSecret removed" "[build-template-secret]" '
  python3 - "$T" <<SCPY
import sys, os
p=sys.argv[1]+"/manifests/service-catalog-builder/kaniko-build-job.template.yaml"
s=open(p,encoding="utf-8").read()
old="            secretName: service-catalog-registry-credentials\n"
assert s.count(old)==1, "secretName anchor matched %d times, not 1" % s.count(old)
open(p,"w",encoding="utf-8").write(s.replace(old, old+"            optional: true\n",1))
os.remove(sys.argv[1]+"/manifests/external-secrets/service-catalog-builder-externalsecrets.yaml")
SCPY
'
# (16h) DELETING THE VOLUME MUST NOT BE CHEAPER THAN RENAMING IT. `if not refs:
#       continue` skipped a whole directory in silence, so removing the credential
#       outright was a free pass. A container running `--destination=` PUSHES, and a
#       push with no credential 401s after building the whole image.
expect_catch "kaniko push template loses its credential volume entirely" "[build-template-secret]" '
  python3 - "$T" <<SCPY
import sys
p=sys.argv[1]+"/manifests/service-catalog-builder/kaniko-build-job.template.yaml"
s=open(p,encoding="utf-8").read()
vol="""        - name: docker-config
          secret:
            secretName: service-catalog-registry-credentials
            items:
              - key: config.json
                path: config.json
"""
mnt="""            - name: docker-config
              mountPath: /kaniko/.docker
              readOnly: true
"""
assert s.count(vol)==1 and s.count(mnt)==1, "volume/mount anchors drifted"
open(p,"w",encoding="utf-8").write(s.replace(vol,"",1).replace(mnt,"",1))
SCPY
'
# (16i) "A FILE EXISTS ON DISK" IS NOT "THE SECRET IS PROVISIONED". Delete ONLY the
#       kustomization line that wires the new ExternalSecret in — the file stays,
#       perfectly valid — and ArgoCD never applies it, the Secret never materialises,
#       and the build pod hangs in ContainerCreating for its full 1800s deadline.
#       That is defect 12, restored, and the first cut could not see it.
expect_catch "builder ExternalSecret un-wired from kustomization (file kept)" "[build-template-secret]" '
  sed -i "/^  - service-catalog-builder-externalsecrets.yaml/d" \
      "$T/manifests/external-secrets/kustomization.yaml"
  ! grep -q "^  - service-catalog-builder-externalsecrets.yaml" \
      "$T/manifests/external-secrets/kustomization.yaml"
'

# ── (17) THE CROSS-NAMESPACE NETWORKPOLICY CLASS ─────────────────────────────
# (17a) THE SHIPPED-SHAPED DEFECT, and a declared surviving mutation of the first
#       cut: delete the per-pod ingress policy and the console pod runs Ready,
#       healthy and clean in `kubectl get` while every request through its gateway
#       dies in the CNI — no event, no restart, no pod-side log.
expect_catch "the console ingress NetworkPolicy deleted (silent CNI black hole)" "[gateway-netpol]" '
  rm "$T/manifests/networkpolicy/superadmin-ui-ingress.yaml"
  sed -i "/^  - superadmin-ui-ingress.yaml/d" "$T/manifests/networkpolicy/kustomization.yaml"
'
# (17b) …and the same defect the QUIET way: keep the file, delete only the line that
#       wires it into the kustomization. Same standard as (16i) — a policy nothing
#       renders protects nothing.
expect_catch "the console ingress policy un-wired from kustomization (file kept)" "[gateway-netpol]" '
  sed -i "/^  - superadmin-ui-ingress.yaml/d" "$T/manifests/networkpolicy/kustomization.yaml"
  ! grep -q "^  - superadmin-ui-ingress.yaml" "$T/manifests/networkpolicy/kustomization.yaml"
'

# ── (18) THE SERVICEACCOUNT HALF OF THE IDENTITY MATRIX ──────────────────────
# (18a) A declared surviving mutation of the first cut: the Deployment drifts off the
#       ServiceAccount docs/SECURITY.md §3 RESERVES for it. The SA is the pod's
#       cluster identity — its RBAC, its token audience, the subject every
#       RoleBinding names — and nothing mechanical pinned that column.
expect_catch "Deployment drifts off the reserved sa-service-catalog-ui" "[workload-sa]" '
  sed -i "s/^      serviceAccountName: sa-service-catalog-ui$/      serviceAccountName: default/" \
      "$T/manifests/superadmin-service-catalog-ui/deployment.yaml"
  grep -q "^      serviceAccountName: default$" \
      "$T/manifests/superadmin-service-catalog-ui/deployment.yaml"
'
# (18b) the other end of the same binding: the ServiceAccount object deleted while the
#       Deployment still names it. The kubelet refuses the pod outright — a failure
#       with no container log to explain it.
expect_catch "reserved ServiceAccount deleted, binding left dangling" "[workload-sa]" '
  rm "$T/manifests/superadmin-service-catalog-ui/service-account.yaml"
  sed -i "/^  - service-account.yaml/d" "$T/manifests/superadmin-service-catalog-ui/kustomization.yaml"
'

# ── (19) THE VACUITY / FUTURE-REMOTE CONTROLS ────────────────────────────────
# (19a) THE CLAIM THE REVIEWER CALLED UNSUPPORTED, NOW MEASURED. Add a remote the
#       way the repo actually adds them — a plain nginx Deployment + Service in the
#       frontend tier, NO FederationModuleRegistration descriptor and NO
#       /remoteEntry.json probe — plus its gateway route with no StripPrefix. Under
#       the first cut's two-way discovery this was invisible; it must now bite the
#       day the route lands.
expect_catch "a NEW tier remote + route added with no StripPrefix (future-remote coverage)" "[remote-strip-prefix]" '
  python3 - "$T" <<SCPY
import sys
d=sys.argv[1]
open(d+"/manifests/mod-ui/zz-new-remote.yaml","w",encoding="utf-8").write("""apiVersion: apps/v1
kind: Deployment
metadata: { name: hugmesh-widget-ui, namespace: hugmesh-frontend, labels: { app: hugmesh-widget-ui } }
spec:
  selector: { matchLabels: { app: hugmesh-widget-ui } }
  template:
    metadata: { labels: { app: hugmesh-widget-ui } }
    spec:
      containers:
        - name: web
          image: hugmesh/widget-ui:dev
          ports: [{ name: http, containerPort: 80 }]
---
apiVersion: v1
kind: Service
metadata: { name: hugmesh-widget-ui, namespace: hugmesh-frontend }
spec: { selector: { app: hugmesh-widget-ui }, ports: [{ name: http, port: 80, targetPort: http }] }
""")
k=d+"/manifests/mod-ui/kustomization.yaml"
s=open(k,encoding="utf-8").read()
assert s.count("resources:\n")==1, "mod-ui kustomization resources: anchor drifted"
open(k,"w",encoding="utf-8").write(s.replace("resources:\n","resources:\n  - zz-new-remote.yaml\n",1))
p=d+"/apps/20-gateway-fe.yaml"
s=open(p,encoding="utf-8").read()
old="          - id: api-docs\n"
assert s.count(old)==1, "api-docs route anchor matched %d times, not 1" % s.count(old)
open(p,"w",encoding="utf-8").write(s.replace(old,"""          - id: widget-ui
            uri: http://hugmesh-widget-ui.hugmesh-frontend.svc.cluster.local:80
            path: /widget/**
"""+old,1))
SCPY
'
# (19b) BOTH discovery seeds killed at once (descriptor kind renamed AND both
#       /remoteEntry.json probes retargeted). The tier can no longer be derived, so
#       [remote-strip-prefix] must say so LOUDLY rather than report a clean pass over
#       an empty set — the exact way this check was hollow before.
expect_catch "every remote-discovery seed removed (the tier check must not go vacuous)" "[remote-strip-prefix]" '
  sed -i "s/^kind: FederationModuleRegistration$/kind: FederationModuleRegistrationX/" \
      "$T/manifests/federation-api/register-superadmin-service-catalog.descriptor.yaml"
  sed -i "s|path: /remoteEntry.json|path: /healthz|g" \
      "$T/manifests/character-forge/deployment.yaml" "$T/manifests/character-studio/deployment.yaml"
  ! grep -q "remoteEntry.json, port" "$T/manifests/character-forge/deployment.yaml"
'
# (19c) EVERY NetworkPolicy in the tree neutralised. With nothing default-denied there
#       is nothing to admit, so [gateway-netpol] has no claim left — and must report
#       that instead of a pass.
expect_catch "every NetworkPolicy neutralised (the netpol check must not go vacuous)" "[gateway-netpol]" '
  python3 - "$T" <<SCPY
import sys, os
n=0
for dp,_dn,fns in os.walk(sys.argv[1]):
    for f in fns:
        if not f.endswith((".yaml",".yml")): continue
        p=os.path.join(dp,f)
        t=open(p,encoding="utf-8",errors="replace").read()
        if "kind: NetworkPolicy" in t:
            open(p,"w",encoding="utf-8").write(t.replace("kind: NetworkPolicy","kind: NetworkPolicyX"))
            n+=1
assert n > 0, "no NetworkPolicy manifests found to neutralise"
SCPY
'
# (19d) THE AUTHORITY EDITED INSTEAD OF THE ARTEFACT. Rename the ServiceAccount cell
#       in the docs/SECURITY.md §3 row while the Deployment keeps binding the real
#       one. Enforcing the matrix in one direction only would let this un-enforce the
#       row in silence — the same move that voided the s0:c49 reservation. Like
#       control (15c), this mutates the DOCS and not the tree, so it declares that
#       via ${WORK}/docsdir.
expect_catch "the matrix ServiceAccount cell renamed while the manifest keeps the real SA" "[workload-sa]" '
  rm -rf "$WORK/mdocs"; cp -r "$REPO/docs" "$WORK/mdocs"
  sed -i "s/\`sa-service-catalog-ui\`/\`sa-catalog-console\`/" "$WORK/mdocs/SECURITY.md"
  grep -q "sa-catalog-console" "$WORK/mdocs/SECURITY.md"
  printf "%s" "$WORK/mdocs" > "$WORK/docsdir"
'

# ── (20) IMAGE PINS: no floating tag; a third-party image carries a digest ────
# The shipped defect: owncast/kustomization.yaml said `newTag: latest` (rendered:
# image: owncast/owncast:latest) and tube's nginx was a bare mutable tag; this gate
# never read a kustomization's `images:` list. Every control below is one SPELLING of
# the same hole, each asserting its own anchor so none can silently match nothing.
imgswap() {  # <file under $T> <old, must occur exactly once> <new>
  python3 - "$T/$1" "$2" "$3" <<"PY"
import sys
p, old, new = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
assert s.count(old) == 1, "anchor %r matched %d times, not 1" % (old, s.count(old))
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
}
OC_PIN='newTag: 0.3.0, digest: sha256:0f35b568b1098d2badbde2dbf3c73a902009c95eb687c647edea04d6da079a78 }'
NG_PIN='newTag: "1.27-alpine", digest: sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10 }'
# (20a) THE EXACT SHIPPED DEFECT.
expect_catch "owncast upstream image pinned to newTag: latest" "[image-pin]" '
  imgswap manifests/owncast/kustomization.yaml "${OC_PIN}" "newTag: latest }"
  grep -q "newTag: latest }" "$T/manifests/owncast/kustomization.yaml"
'
# (20b) case spelling of the same tag.
expect_catch "owncast upstream image pinned to newTag: Latest (case)" "[image-pin]" '
  imgswap manifests/owncast/kustomization.yaml "${OC_PIN}" "newTag: Latest }"
'
# (20c) :latest even WITH a digest is still refused (the tag is what a reader trusts).
expect_catch "newTag: latest kept alongside a digest" "[image-pin]" '
  imgswap manifests/owncast/kustomization.yaml "newTag: 0.3.0, digest" "newTag: latest, digest"
'
# (20d) empty tag, and (20e) no tag at all: both are an implicit :latest.
expect_catch "owncast upstream image newTag empty" "[image-pin]" '
  imgswap manifests/owncast/kustomization.yaml "${OC_PIN}" "newTag: \"\" }"
'
expect_catch "owncast upstream image has no newTag and no digest" "[image-pin]" '
  imgswap manifests/owncast/kustomization.yaml ", ${OC_PIN}" " }"
'
# (20f) a version tag with no digest on a third-party image (the tube/nginx shape).
expect_catch "tube nginx tag without a digest" "[image-pin]" '
  imgswap manifests/tube/kustomization.yaml ", digest: sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10 }" " }"
'
# (20g) a digest that pins nothing: truncated, uppercase algorithm, placeholder.
expect_catch "digest one hex character short" "[image-pin]" '
  imgswap manifests/tube/kustomization.yaml "17a54ef4b76fb8e2f2a10 }" "17a54ef4b76fb8e2f2a1 }"
'
expect_catch "digest algorithm in upper case" "[image-pin]" '
  imgswap manifests/tube/kustomization.yaml "digest: sha256:" "digest: SHA256:"
'
expect_catch "placeholder all-zero digest" "[image-pin]" '
  imgswap manifests/tube/kustomization.yaml "sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10" "sha256:0000000000000000000000000000000000000000000000000000000000000000"
'
# (20h) a floating NAME that is not a version, even with a digest.
expect_catch "third-party tag is a floating name (stable) with a digest" "[image-pin]" '
  imgswap manifests/owncast/kustomization.yaml "newTag: 0.3.0, digest" "newTag: stable, digest"
'
# (20i) YAML turns an unquoted 1.30 into the float 1.3 -> a different image.
expect_catch "unquoted numeric newTag (YAML float)" "[image-pin]" '
  imgswap manifests/tube/kustomization.yaml "newTag: \"1.27-alpine\"" "newTag: 1.27"
'
# (20j) a workload spelled :latest literally, behind a rewrite that would hide it
#       from a check that only reads kustomizations.
expect_catch "Deployment container image written :latest" "[image-pin]" '
  imgswap manifests/tube/deployment.yaml "          image: nginx" "          image: nginx:latest"
'
# (20k) a bare third-party image no kustomization rewrites: implicit :latest.
expect_catch "Deployment image untagged and not rewritten by any kustomization" "[image-pin]" '
  imgswap manifests/owncast/deployment.yaml "          image: owncast/owncast" "          image: owncast/owncast-extra"
'
# (20l) the known-gaps list cannot outlive its gap: give coturn a digest and the
#       entry must be reported stale.
expect_catch "a KNOWN_GAPS entry that has gained a digest is reported stale" "[image-pin]" '
  imgswap manifests/coturn/kustomization.yaml "newTag: 4.6.2 }" "newTag: 4.6.2, digest: sha256:1111111111111111111111111111111111111111111111111111111111111112 }"
'
# (20m) NOT VACUOUS: with every kustomize `images:` list neutralised the check has
#       nothing to read and must say so rather than pass.
expect_catch "every kustomize images: list neutralised (the pin check must not go vacuous)" "[image-pin]" '
  python3 - "$T" <<"PY"
import os, sys
n = 0
for dp, _d, fns in os.walk(sys.argv[1]):
    for f in fns:
        if f == "kustomization.yaml":
            p = os.path.join(dp, f)
            t = open(p, encoding="utf-8").read()
            if "\nimages:" in t:
                open(p, "w", encoding="utf-8").write(t.replace("\nimages:", "\nimagesX:"))
                n += 1
assert n > 0, "no kustomization with images: found"
PY
'

# ── (21) IMAGE PINS, round 2: each place the checker lists as setting an image ──
# A review got a mutable image past (20) three ways, each rendering a floating tag
# with the gate green: a raw `image: owncast/owncast:stable`, a `kind: Component`
# carrying `newTag: latest`, and a JSON6902 patch setting `owncast/owncast:develop`.
# The negative controls run with HUGMESH_IMAGE_PIN_RENDER=0 (exported above), so each
# one proves the STATIC reader alone catches it (the python:3-slim CI image has no
# kubectl); (21-render) below proves the kubectl render cross-check catches the
# same three on its own.
OC_ENTRY='  - { name: owncast/owncast, newName: owncast/owncast, newTag: 0.3.0, digest: sha256:0f35b568b1098d2badbde2dbf3c73a902009c95eb687c647edea04d6da079a78 }
'
oc_drop_entry() { imgswap manifests/owncast/kustomization.yaml "${OC_ENTRY}" ""; }
# Dropping the owncast entry also leaves the deployment's bare owncast/owncast
# unrewritten, which (20) already refuses; a control that drops it must therefore
# want its OWN finding line, or it would pass for that other reason.
ipw() { printf '%-24s %s' '[image-pin]' "$1"; }
# (21a) THE REPORTED EXPLOIT 1: a floating non-latest tag in a raw workload.
for tag in stable edge mainline develop STABLE nightly 1.2-stable 6.6-24.04_edge; do
expect_catch "raw workload image owncast/owncast:${tag} with the images: entry removed" "[image-pin]" "
  oc_drop_entry
  imgswap manifests/owncast/deployment.yaml '          image: owncast/owncast
' '          image: owncast/owncast:${tag}
'
"
done
# (21b) raw :latest in any case, with a digest too (the tag is what a reader trusts).
expect_catch "raw workload image owncast/owncast:Latest@digest" "[image-pin]" '
  oc_drop_entry
  imgswap manifests/owncast/deployment.yaml "          image: owncast/owncast
" "          image: owncast/owncast:Latest@sha256:0f35b568b1098d2badbde2dbf3c73a902009c95eb687c647edea04d6da079a78
"
'
# (21c) the digest ratchet: a NEW third-party ref with a version tag and no digest.
expect_catch "raw workload image owncast/owncast:0.3.0 (version tag, no digest, not in the ratchet)" "[image-pin]" '
  oc_drop_entry
  imgswap manifests/owncast/deployment.yaml "          image: owncast/owncast
" "          image: owncast/owncast:0.3.0
"
'
# (21d) the shipped squid channel tag with its digest removed.
expect_catch "egress-proxy squid channel tag _edge without its digest" "[image-pin]" '
  imgswap manifests/egress-proxy/egress-proxy.yaml "6.6-24.04_edge@sha256:8a3baed477e2c282ab8aa5edad442f69873246964f225c5c2ae8364b6610963c" "6.6-24.04_edge"
'
# (21e) THE REPORTED EXPLOIT 2: a kustomize Component carrying newTag: latest.
expect_catch "kind: Component images: entry newTag: latest, pulled in via components:" "[image-pin]" '
  oc_drop_entry
  imgswap manifests/owncast/deployment.yaml "          image: owncast/owncast
" "          image: owncast/owncast:0.3.0
"
  mkdir "$T/manifests/owncast/pin"
  printf "apiVersion: kustomize.config.k8s.io/v1alpha1\nkind: Component\nimages:\n  - {name: owncast/owncast, newName: owncast/owncast, newTag: latest}\n" > "$T/manifests/owncast/pin/kustomization.yaml"
  printf "components:\n  - pin\n" >> "$T/manifests/owncast/kustomization.yaml"
'
# (21f) THE REPORTED EXPLOIT 3: an inline JSON6902 patch replacing the image.
OC_JSONPATCH='patches:
  - target: {kind: Deployment, name: hugmesh-owncast}
    patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/image
        value: owncast/owncast:develop
'
expect_catch "inline JSON6902 patch replaces the owncast image with :develop" "$(ipw "manifests/owncast/kustomization.yaml (patch): image 'owncast/owncast:develop'")" '
  oc_drop_entry
  printf "%s" "${OC_JSONPATCH}" >> "$T/manifests/owncast/kustomization.yaml"
'
# (21g) the same op from a patch FILE (a JSON6902 file is a YAML list, not a doc).
expect_catch "JSON6902 patch file sets owncast/owncast:latest" "[image-pin]" '
  printf -- "- op: replace\n  path: /spec/template/spec/containers/0/image\n  value: owncast/owncast:latest\n" > "$T/manifests/owncast/img-patch.yaml"
  printf "patches:\n  - target: {kind: Deployment, name: hugmesh-owncast}\n    path: img-patch.yaml\n" >> "$T/manifests/owncast/kustomization.yaml"
'
# (21h) a JSON6902 op that ADDS a whole container carrying a mutable image.
expect_catch "JSON6902 add of a whole sidecar container on :latest" "[image-pin]" '
  printf "patches:\n  - target: {kind: Deployment, name: hugmesh-owncast}\n    patch: |-\n      - op: add\n        path: /spec/template/spec/containers/-\n        value: {name: side, image: \"busybox:latest\"}\n" >> "$T/manifests/owncast/kustomization.yaml"
'
# (21i) a copy/move onto an image path takes its value from elsewhere: fail closed.
expect_catch "JSON6902 copy onto an image path (unreadable value, fail closed)" "[image-pin]" '
  printf "patches:\n  - target: {kind: Deployment, name: hugmesh-owncast}\n    patch: |-\n      - op: copy\n        from: /metadata/annotations/img\n        path: /spec/template/spec/containers/0/image\n" >> "$T/manifests/owncast/kustomization.yaml"
'
# (21j) an inline strategic-merge patch (patchesStrategicMerge string form).
expect_catch "inline patchesStrategicMerge sets owncast/owncast:edge" "$(ipw "manifests/owncast/kustomization.yaml (patch): image 'owncast/owncast:edge'")" '
  oc_drop_entry
  printf "patchesStrategicMerge:\n  - |-\n    apiVersion: apps/v1\n    kind: Deployment\n    metadata: {name: hugmesh-owncast}\n    spec:\n      template:\n        spec:\n          containers:\n            - {name: owncast, image: \"owncast/owncast:edge\"}\n" >> "$T/manifests/owncast/kustomization.yaml"
'
# (21k) a patch file that does not exist cannot be checked: fail closed.
expect_catch "patch by path to a file that is not there (fail closed)" "[image-pin]" '
  printf "patches:\n  - target: {kind: Deployment, name: hugmesh-owncast}\n    path: no-such-patch.yaml\n" >> "$T/manifests/owncast/kustomization.yaml"
'
# (21l) replacements that write an image field: fail closed.
expect_catch "replacements: target fieldPath names the container image (fail closed)" "$(ipw "manifests/owncast/kustomization.yaml: a \`replacements:\` entry writes an image field")" '
  printf "replacements:\n  - source: {kind: ConfigMap, name: x, fieldPath: data.img}\n    targets:\n      - select: {kind: Deployment}\n        fieldPaths:\n          - \"spec.template.spec.containers.[name=owncast].image\"\n" >> "$T/manifests/owncast/kustomization.yaml"
'
# (21m) a transformer plugin (an ImageTagTransformer config, say): fail closed.
expect_catch "kustomization uses transformers: (unreadable output, fail closed)" "[image-pin]" '
  printf "transformers:\n  - tag.yaml\n" >> "$T/manifests/owncast/kustomization.yaml"
'
# (21n) an Argo Application kustomize.images override.
expect_catch "Argo Application kustomize.images override to :latest" "[image-pin]" '
  imgswap apps/12-cloudflared.yaml "    kustomize:
" "    kustomize:
      images: [\"owncast/owncast=owncast/owncast:latest\"]
"
'
# (21o) a helm values image tag (the velero chart values).
expect_catch "helm values image tag set to latest (velero)" "[image-pin]" '
  imgswap apps/55-velero.yaml "          tag: v1.18.1" "          tag: latest"
'
# (21p) YAML embedded in a ConfigMap string: the local-path helper pod template.
expect_catch "local-path helper-pod template back to an untagged busybox" "[image-pin]" '
  imgswap manifests/local-path/local-path.yaml "image: busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e" "image: busybox"
'
# (21q) a variable substitution in an image cannot be read: fail closed.
expect_catch "image ref built from a \$(VAR) substitution" "[image-pin]" '
  imgswap manifests/media-poisoner/deployment.yaml "image: busybox:1.37" "image: busybox:\$(TAG)"
'
# (21r) another directory includes the owncast Deployment by file without the
#       rewrite: the untagged owncast/owncast reaches a render unrewritten.
expect_catch "foreign kustomization includes owncast/deployment.yaml without rewriting it" "[image-pin]" '
  mkdir "$T/manifests/owncast-copy"
  printf "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n  - ../owncast/deployment.yaml\n" > "$T/manifests/owncast-copy/kustomization.yaml"
'
# (21s) the raw ratchet cannot outlive its gap: busybox:1.37 has one user; give it a
#       digest and the RAW_DIGEST_KNOWN_GAPS entry must be reported stale.
expect_catch "a RAW_DIGEST_KNOWN_GAPS entry nothing relies on any more is reported stale" "[image-pin]" '
  imgswap manifests/media-poisoner/deployment.yaml "image: busybox:1.37" "image: busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
'

# (21t) kustomize also reads an extensionless `Kustomization` file: refused, not skipped.
expect_catch "extensionless Kustomization file (unread by the static reader, fail closed)" "$(ipw "manifests/owncast/Kustomization: a kustomization in an extensionless")" '
  printf "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nimages:\n  - {name: owncast/owncast, newTag: latest}\n" > "$T/manifests/owncast/Kustomization"
'
# (21u) a remote resource pulls images in from outside the tree (and ?ref= moves).
expect_catch "remote git resource with ?ref=main (fail closed)" "$(ipw "manifests/owncast/kustomization.yaml: \`resources:\` pulls in the REMOTE")" '
  imgswap manifests/owncast/kustomization.yaml "  - deployment.yaml
" "  - deployment.yaml
  - github.com/example/deploy//owncast?ref=main
"
'
# (21v) a bare hugmesh/ entry with no newName pulls from Docker Hub: third-party rules.
expect_catch "bare hugmesh/owncast-ui entry with no newName and a floating tag" "$(ipw "manifests/owncast/kustomization.yaml: image hugmesh/owncast-ui (third-party) has tag 'edge'")" '
  imgswap manifests/owncast/kustomization.yaml "{ name: hugmesh/owncast-ui, newName: registry.hugmesh.net/hugmesh/hugmesh-owncast-ui, newTag: main }" "{ name: hugmesh/owncast-ui, newTag: edge }"
'
# (21w) an unrewritten bare hugmesh/ ref in a workload, same reason.
expect_catch "unrewritten bare hugmesh/ workload image on :edge" "$(ipw "manifests/owncast/deployment.yaml: image 'hugmesh/owncast-ui-extra:edge'")" '
  imgswap manifests/owncast/deployment.yaml "image: hugmesh/owncast-ui
" "image: hugmesh/owncast-ui-extra:edge
"
'
# (21x) nesting past the walker depth is a finding, not a silent stop.
expect_catch "image nested deeper than the walker reads (fail closed)" "$(ipw "a document nests deeper than")" '
  python3 - "$T/manifests/owncast/deep.yaml" <<"PY"
import sys, yaml
node = {"image": "owncast/owncast:latest"}
for i in range(70):
    node = {"k%d" % i: node}
node.update({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "deep"}})
open(sys.argv[1], "w").write(yaml.safe_dump(node))
PY
'

# ── (22) IMAGE PINS, round 3: four more ways a mutable image got past (21) ──────
# A review got a mutable image past round 2 with the gate green, static AND render:
#   (a) a ConfigMap value holding SINGLE-LINE JSON (local-path-provisioner reads
#       helperPod.yaml as YAML, and YAML accepts JSON): the embedded-string reader
#       only parsed strings containing a newline, and the render pass used the same
#       reader; the same hole through a configMapGenerator literal;
#   (b) IMAGE_DIGEST_KNOWN_GAPS was keyed by directory BASENAME and image name with
#       no tag, so coturn could be retagged to the floating major "4", and any other
#       directory named coturn inherited the exemption;
#   (c) an Argo helm source's `parameters:` (applied on top of values) were never
#       read, and a helm `image: {tag: latest}` with no repository was dropped.
# Each control below is one of those inputs or another spelling of the same hole.
lp_helper() {  # <replacement line for the helperPod.yaml key>: drop the block scalar
  python3 - "$T/manifests/local-path/local-path.yaml" "$1" <<"PY"
import sys
p, new = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
i = s.index("  helperPod.yaml: |-\n")
lines = s[i:].split("\n")
j = 1
while j < len(lines) and (lines[j].startswith("    ") or lines[j] == ""):
    j += 1
assert j > 5, "helperPod.yaml block not found"
open(p, "w", encoding="utf-8").write(s[:i] + new + "\n" + "\n".join(lines[j:]))
PY
}
LP_WANT="$(ipw "manifests/local-path/local-path.yaml: image 'busybox:latest'")"
# (22a) THE REPORTED EXPLOIT: single-line JSON pod template in the ConfigMap.
expect_catch "single-line JSON helperPod.yaml with busybox:latest" "${LP_WANT}" '
  lp_helper "  helperPod.yaml: '"'"'{\"apiVersion\":\"v1\",\"kind\":\"Pod\",\"metadata\":{\"name\":\"helper-pod\"},\"spec\":{\"containers\":[{\"name\":\"helper-pod\",\"image\":\"busybox:latest\"}]}}'"'"'"
'
# (22b) the key spelled with a JSON/YAML unicode escape, so the text never says "image".
expect_catch "single-line JSON helperPod.yaml with an escaped \\u0069mage key" "${LP_WANT}" '
  lp_helper "  helperPod.yaml: '"'"'{\"spec\":{\"containers\":[{\"name\":\"h\",\"\\u0069mage\":\"busybox:latest\"}]}}'"'"'"
'
# (22c) JSON with a tab between tokens: PyYAML refuses it, a JSON consumer does not.
expect_catch "single-line JSON helperPod.yaml with a tab PyYAML cannot scan" "${LP_WANT}" '
  lp_helper "  helperPod.yaml: \"{\\\"spec\\\":{\\\"containers\\\":[{\\\"name\\\":\\\"h\\\",\\t\\\"image\\\":\\\"busybox:latest\\\"}]}}\""
'
# (22d) a duplicated key: last-wins would show only the pinned value.
expect_catch "embedded JSON with a duplicate image key (shadowed :latest)" "${LP_WANT}" '
  lp_helper "  helperPod.yaml: '"'"'{\"spec\":{\"containers\":[{\"name\":\"h\",\"image\":\"busybox:latest\",\"image\":\"busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e\"}]}}'"'"'"
'
# (22e) a script in a ConfigMap value that pulls an image (text backstop).
expect_catch "ConfigMap script value runs kubectl run --image=busybox:latest" "${LP_WANT}" '
  imgswap manifests/local-path/local-path.yaml "  helperPod.yaml: |-
" "  probe.sh: \"kubectl run probe --restart=Never --image=busybox:latest -- true\"
  helperPod.yaml: |-
"
'
GEN_POD='{"apiVersion":"v1","kind":"Pod","spec":{"containers":[{"name":"h","image":"busybox:latest"}]}}'
export GEN_POD
# (22f) THE REPORTED EXPLOIT, generator spelling: a configMapGenerator literal.
expect_catch "configMapGenerator literal holds a pod spec on busybox:latest" "$(ipw "manifests/owncast/kustomization.yaml (configMapGenerator helper literal): image 'busybox:latest'")" '
  printf "configMapGenerator:\n  - name: helper\n    literals:\n      - '"'"'helperPod.yaml=%s'"'"'\n" "${GEN_POD}" >> "$T/manifests/owncast/kustomization.yaml"
'
# (22g) the same through a generator FILE with an extension no YAML walk reads.
expect_catch "configMapGenerator files: helper.json holds busybox:latest" "$(ipw "manifests/owncast/kustomization.yaml (configMapGenerator helper file helper.json): image 'busybox:latest'")" '
  printf "%s\n" "${GEN_POD}" > "$T/manifests/owncast/helper.json"
  printf "configMapGenerator:\n  - name: helper\n    files:\n      - helperPod.yaml=helper.json\n" >> "$T/manifests/owncast/kustomization.yaml"
'
# (22h) an envs file value, and (22i) a secretGenerator literal.
expect_catch "configMapGenerator envs: value holds busybox:latest" "$(ipw "manifests/owncast/kustomization.yaml (configMapGenerator helper env file helper.env): image 'busybox:latest'")" '
  printf "POD=%s\n" "${GEN_POD}" > "$T/manifests/owncast/helper.env"
  printf "configMapGenerator:\n  - name: helper\n    envs:\n      - helper.env\n" >> "$T/manifests/owncast/kustomization.yaml"
'
expect_catch "secretGenerator literal holds busybox:latest" "$(ipw "manifests/owncast/kustomization.yaml (secretGenerator helper literal): image 'busybox:latest'")" '
  printf "secretGenerator:\n  - name: helper\n    literals:\n      - '"'"'pod=%s'"'"'\n" "${GEN_POD}" >> "$T/manifests/owncast/kustomization.yaml"
'
# (22j) a generator file that is not there cannot be checked: fail closed.
expect_catch "configMapGenerator file that does not exist (fail closed)" "$(ipw "manifests/owncast/kustomization.yaml: \`configMapGenerator\` file no-such.json cannot be read")" '
  printf "configMapGenerator:\n  - name: helper\n    files:\n      - no-such.json\n" >> "$T/manifests/owncast/kustomization.yaml"
'
# (22k) THE REPORTED EXPLOIT: a known-gap entry retagged to a floating major.
expect_catch "coturn retagged 4.6.2 -> \"4\" with no digest" "$(ipw "manifests/coturn/kustomization.yaml: image coturn/coturn (third-party) is pinned by tag '4' only")" '
  imgswap manifests/coturn/kustomization.yaml "newTag: 4.6.2 }" "newTag: \"4\" }"
'
# (22l) another directory with the same basename does not inherit the gap entry.
expect_catch "a second directory named coturn does not inherit the known-gap entry" "$(ipw "manifests/extra/coturn/kustomization.yaml: image coturn/coturn (third-party) is pinned by tag '4.6.2' only")" '
  mkdir -p "$T/manifests/extra"; cp -r "$T/manifests/coturn" "$T/manifests/extra/coturn"
'
# (22m) THE REPORTED EXPLOIT: an Argo helm parameter overriding the tag.
HP_ANCHOR='    helm:
      releaseName: velero
'
expect_catch "Argo helm.parameters image.tag=latest (velero)" "$(ipw "apps/55-velero.yaml (helm.parameters override): image 'velero/velero:latest'")" '
  imgswap apps/55-velero.yaml "${HP_ANCHOR}" "${HP_ANCHOR}      parameters:
        - name: image.tag
          value: latest
"
'
# (22n) the list-index spelling of a parameter.
expect_catch "Argo helm.parameters initContainers[0].image=...:latest" "$(ipw "apps/55-velero.yaml (helm.parameters override): image 'velero/velero-plugin-for-aws:latest'")" '
  imgswap apps/55-velero.yaml "${HP_ANCHOR}" "${HP_ANCHOR}      parameters:
        - name: initContainers[0].image
          value: velero/velero-plugin-for-aws:latest
"
'
# (22o) a parameter on an image path this check cannot apply: fail closed.
expect_catch "Argo helm parameter with an unreadable image path (fail closed)" "$(ipw "apps/55-velero.yaml: helm parameter")" '
  imgswap apps/55-velero.yaml "${HP_ANCHOR}" "${HP_ANCHOR}      parameters:
        - name: \"image.tag[\"
          value: latest
"
'
# (22p) valueFiles / (22q) fileParameters: values from outside this tree, fail closed.
expect_catch "Argo helm valueFiles (unread values, fail closed)" "$(ipw "apps/55-velero.yaml: an Argo helm source sets \`valueFiles:\`")" '
  imgswap apps/55-velero.yaml "${HP_ANCHOR}" "${HP_ANCHOR}      valueFiles: [values-latest.yaml]
"
'
expect_catch "Argo helm fileParameters (unread values, fail closed)" "$(ipw "apps/55-velero.yaml: an Argo helm source sets \`fileParameters:\`")" '
  imgswap apps/55-velero.yaml "${HP_ANCHOR}" "${HP_ANCHOR}      fileParameters:
        - {name: image.tag, path: tag.txt}
"
'
# (22r) THE REPORTED EXPLOIT: a tag-only helm image map over a chart default.
expect_catch "helm values kubectl: {image: {tag: latest}} with no repository" "$(ipw "apps/55-velero.yaml: a helm image map {'tag': 'latest'} sets a tag/digest but no repository")" '
  imgswap apps/55-velero.yaml "        installCRDs: true
" "        installCRDs: true
        kubectl:
          image:
            tag: latest
"
'
# (22s) the same tag-only override arriving through a parameter.
expect_catch "Argo helm.parameters kubectl.image.tag (tag-only override, fail closed)" "$(ipw "apps/55-velero.yaml: a helm image map {'tag': 'v1.31.0'} sets a tag/digest but no repository")" '
  imgswap apps/55-velero.yaml "${HP_ANCHOR}" "${HP_ANCHOR}      parameters:
        - name: kubectl.image.tag
          value: v1.31.0
"
'
# (22t) a non-string helm tag (YAML reads 1.30 as 1.3).
expect_catch "helm values image tag unquoted number" "$(ipw "apps/55-velero.yaml: a helm image map sets tag 1.3")" '
  imgswap apps/55-velero.yaml "          tag: v1.18.1" "          tag: 1.30"
'
# (22u) a ref inside a STRING gets no `images:` rewrite exemption: kustomize rewrites
#       container image fields, never text in a ConfigMap value, so a bare busybox in
#       the helper-pod template is pulled as busybox:latest even when the directory's
#       kustomization rewrites the name busybox. (22u-render) shows the render agrees.
LP_REWRITE='printf "images:\n  - {name: busybox, newName: busybox, newTag: \"1.37\", digest: sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e}\n" >> "$T/manifests/local-path/kustomization.yaml"
  imgswap manifests/local-path/local-path.yaml "image: busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e" "image: busybox"'
expect_catch "bare busybox in a ConfigMap template behind an images: rewrite of busybox" "$(ipw "manifests/local-path/local-path.yaml: image 'busybox' has no tag")" "${LP_REWRITE}"

# ── (23) IMAGE PINS, round 4: files and spellings round 3 never read ──────────
# A review got a mutable image past round 3 with the gate green, static AND render:
#   (a) `--image curlimages/curl:latest` (a SPACE, not `=`) in the prod-hygiene script
#       that a configMapGenerator ships: kubectl reads it the same, the text backstop
#       did not, and it reverted round 3's own curl pin;
#   (b) the local-path helperPod.yaml moved from ConfigMap `data:` to `binaryData:`
#       (base64): the kubelet projects the decoded file, nothing here decoded it;
#   (c) a literal image in charts/hugmesh-gateway/templates: chart templates were
#       skipped and helm was never rendered, yet apps/20-gateway-* ship that chart;
#   (d) a new apps/*.json file: the apps root is `directory: recurse: true`, which
#       applies .json, and only .yaml/.yml were read;
#   (e) `image: !!binary <base64>`: PyYAML returns bytes and the walk dropped them;
# plus two placeholder skips ({{ }} ApplicationSet values, and any ref containing the
# word REPLACE_WITH_). Each control below is one of those inputs or another spelling.
PH=manifests/prod-hygiene/validate-prod-hygiene.sh
CURL_PIN='--image=curlimages/curl:8.10.1@sha256:d9b4541e214bcd85196d6e92e2753ac6d0ea699f0af5741f8c6cccbfcf00ef4b'
ph_want() { ipw "manifests/prod-hygiene/kustomization.yaml (configMapGenerator prod-hygiene-script file validate-prod-hygiene.sh): image '$1'"; }
# (23a) THE REPORTED EXPLOIT: the curl pin reverted with a space-separated --image.
expect_catch "space-separated --image curlimages/curl:latest (round 3's pin reverted)" "$(ph_want curlimages/curl:latest)" '
  imgswap "${PH}" "${CURL_PIN}" "--image curlimages/curl:latest"
'
# (23b) THE REPORTED EXPLOIT: a new kubectl run line with a space-separated --image.
expect_catch "appended kubectl run --image busybox:latest" "$(ph_want busybox:latest)" '
  printf "\nkubectl -n \"\$NS\" run r4-probe --image busybox:latest --restart=Never -- true\n" >> "$T/${PH}"
'
# (23c) a tab and double quotes; (23d) a backslash-newline continuation.
expect_catch "--image<TAB>\"busybox:latest\"" "$(ph_want busybox:latest)" '
  printf "\nkubectl run p --image\t\"busybox:latest\" -- true\n" >> "$T/${PH}"
'
expect_catch "--image split over a backslash-newline continuation" "$(ph_want busybox:latest)" '
  printf "\nkubectl run p \\\\\n  --image \\\\\n  busybox:latest -- true\n" >> "$T/${PH}"
'
# (23e) a shell variable the check cannot expand: fail closed, not skipped.
expect_catch "--image \"\$PROBE_IMG\" (unreadable variable, fail closed)" "$(ph_want '$PROBE_IMG') contains a variable substitution" '
  printf "\nkubectl run p --image \"\$PROBE_IMG\" -- true\n" >> "$T/${PH}"
'
# (23f) kubectl set image, with a selector flag whose value is not an image.
expect_catch "kubectl set image deploy/web -l app=web web=busybox:latest" "$(ph_want busybox:latest)" '
  printf "\nkubectl -n x set image deploy/web -l app=web web=busybox:latest\n" >> "$T/${PH}"
'
# (23g) a valid mutable tag that merely contains the word REPLACE_WITH_.
expect_catch "curlimages/curl:REPLACE_WITH_ANY is judged, not skipped as a placeholder" "$(ph_want curlimages/curl:REPLACE_WITH_ANY) is third-party with tag" '
  imgswap "${PH}" "${CURL_PIN}" "--image=curlimages/curl:REPLACE_WITH_ANY"
'
lp_b64() {  # <mode: image|bad|binary>: move helperPod.yaml from data: into binaryData:
  python3 - "$T/manifests/local-path/local-path.yaml" "$1" <<"PY"
import base64, re, sys
p, mode = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
start = s.index("  helperPod.yaml: |-\n")
end = len(s.rstrip("\n"))
body = "\n".join(l[4:] for l in s[start:end].split("\n")[1:])
new = re.sub(r"busybox:1\.37@sha256:[0-9a-f]{64}", "busybox:latest", body)
assert new != body, "helper-pod image anchor not found"
val = {"image": base64.b64encode(new.encode()).decode(),
       "bad": "\"%%not-base64%%\"",
       "binary": base64.b64encode(b"\xff\xfe\x00image: busybox:latest").decode()}[mode]
open(p, "w", encoding="utf-8").write(s[:start] + "binaryData:\n  helperPod.yaml: " + val + "\n")
PY
}
# (23h) THE REPORTED EXPLOIT: the helper pod base64-encoded in binaryData.
expect_catch "ConfigMap binaryData helperPod.yaml (base64) on busybox:latest" "${LP_WANT}" 'lp_b64 image'
# (23i) base64 that does not decode, and (23j) bytes that are not text: fail closed.
expect_catch "ConfigMap binaryData that is not base64 (fail closed)" "$(ipw "manifests/local-path/local-path.yaml: ConfigMap binaryData key 'helperPod.yaml' is not valid base64")" 'lp_b64 bad'
expect_catch "ConfigMap binaryData that is not UTF-8 text (fail closed)" "$(ipw "manifests/local-path/local-path.yaml: ConfigMap binaryData key 'helperPod.yaml' decodes to binary that is not UTF-8 text")" 'lp_b64 binary'
# (23k) the same through a Secret's data (base64 by definition).
expect_catch "Secret data (base64) holding a pod spec on busybox:latest" "$(ipw "apps/99-probe-secret.yaml: image 'busybox:latest'")" '
  printf "apiVersion: v1\nkind: Secret\nmetadata: {name: probe, namespace: devops}\ndata:\n  pod.json: %s\n" "$(printf "%s" "${GEN_POD}" | base64 -w0)" > "$T/apps/99-probe-secret.yaml"
'
GW_TPL=charts/hugmesh-gateway/templates/deployment.yaml
GW_IMG_LINE='          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          command:'
# (23l) THE REPORTED EXPLOIT: a literal image in an in-tree chart template.
expect_catch "chart template literal image busybox:latest (charts/hugmesh-gateway)" "$(ipw "${GW_TPL} (chart file, read as text): image 'busybox:latest'")" '
  python3 - "$T/${GW_TPL}" <<"PY"
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
old = "          image: \"{{ .Values.image.repository }}:{{ .Values.image.tag }}\""
assert s.count(old) == 2, s.count(old)
open(p, "w", encoding="utf-8").write(s.replace(old, "          image: \"busybox:latest\"", 1))
PY
'
# (23m) a template expression on an image line that is not a values image map: refused.
expect_catch "chart template image built from .Chart.AppVersion (fail closed)" "$(ipw "${GW_TPL} (chart file, read as text): image 'busybox:{{' contains a template expression")" '
  python3 - "$T/${GW_TPL}" <<"PY"
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
old = "          image: \"{{ .Values.image.repository }}:{{ .Values.image.tag }}\""
assert s.count(old) == 2, s.count(old)
open(p, "w", encoding="utf-8").write(s.replace(old, "          image: \"busybox:{{ .Chart.AppVersion }}\"", 1))
PY
'
# (23n) a chart's values.yaml is not a catalog descriptor: a string image there is judged.
expect_catch "chart values.yaml top-level image: busybox:latest" "$(ipw "charts/hugmesh-gateway/values.yaml: image 'busybox:latest'")" '
  imgswap charts/hugmesh-gateway/values.yaml "image:
  repository: registry.hugmesh.net/hugmesh/hugmesh-gateway
  tag: dev
  pullPolicy: IfNotPresent
" "image: busybox:latest
"
'
# (23o) a file a template can embed with .Files.Get (not under templates/).
expect_catch "chart files/probe.sh runs --image busybox:latest" "$(ipw "charts/hugmesh-gateway/files/probe.sh (chart file, read as text): image 'busybox:latest'")" '
  mkdir -p "$T/charts/hugmesh-gateway/files"
  printf "#!/bin/sh\nkubectl run p --image busybox:latest\n" > "$T/charts/hugmesh-gateway/files/probe.sh"
'
JOB_JSON='{"apiVersion":"batch/v1","kind":"Job","metadata":{"name":"r4-probe","namespace":"devops"},"spec":{"template":{"spec":{"restartPolicy":"Never","containers":[{"name":"p","image":"busybox:latest"}]}}}}'
export JOB_JSON
# (23p) THE REPORTED EXPLOIT: a .json manifest under the recurse:true apps root.
expect_catch "apps/99-probe.json Job on busybox:latest" "$(ipw "apps/99-probe.json: image 'busybox:latest'")" '
  printf "%s\n" "${JOB_JSON}" > "$T/apps/99-probe.json"
'
# (23q) a JSON array of objects, and (23r) an upper-case extension.
expect_catch "apps/99-probe-list.json (a JSON array) Job on busybox:latest" "$(ipw "apps/99-probe-list.json: image 'busybox:latest'")" '
  printf "[%s]\n" "${JOB_JSON}" > "$T/apps/99-probe-list.json"
'
expect_catch "apps/99-probe.YAML (upper-case extension) Job on busybox:latest" "$(ipw "apps/99-probe.YAML: image 'busybox:latest'")" '
  printf "%s\n" "${JOB_JSON}" > "$T/apps/99-probe.YAML"
'
# (23s) JSON that does not parse, (23t) Jsonnet, (23u) a symlink: fail closed.
expect_catch "apps/99-bad.json does not parse (fail closed)" "$(ipw "apps/99-bad.json: JSON that does not parse")" '
  printf "{\"kind\": \"Job\",\n" > "$T/apps/99-bad.json"
'
expect_catch "apps/99-probe.jsonnet (fail closed)" "$(ipw "apps/99-probe.jsonnet: a Jsonnet file")" '
  printf "{ kind: \"Job\" }\n" > "$T/apps/99-probe.jsonnet"
'
# The symlink itself is not a regular file, so the md5 guard cannot see it: the
# injection also drops a note file next to it, which no check reads.
expect_catch "apps/99-link.yaml is a symlink (fail closed)" "$(ipw "apps/99-link.yaml: a symlink")" '
  ln -s ../manifests/owncast/deployment.yaml "$T/apps/99-link.yaml"
  printf "symlink control\n" > "$T/apps/99-link.note"
'
# (23v) a kustomize resource file with an extension the walk does not read.
expect_catch "kustomize resource probe.txt holds a Job on busybox:latest" "$(ipw "manifests/owncast/kustomization.yaml (resource manifests/owncast/probe.txt): image 'busybox:latest'")" '
  printf "%s\n" "${JOB_JSON}" > "$T/manifests/owncast/probe.txt"
  imgswap manifests/owncast/kustomization.yaml "  - deployment.yaml
" "  - deployment.yaml
  - probe.txt
"
'
# (23w) an Argo source in this repo that applies a path outside specs/cluster, and
# (23x) the same through an ApplicationSet list element.
expect_catch "Argo Application path outside specs/cluster (fail closed)" "$(ipw "apps/99-outside.yaml: an Argo source in this repo applies 'templates/apps'")" '
  printf "apiVersion: argoproj.io/v1alpha1\nkind: Application\nmetadata: {name: outside, namespace: devops}\nspec:\n  project: default\n  source: {repoURL: https://github.com/hugmesh/hugmesh-generator.git, targetRevision: main, path: templates/apps}\n  destination: {server: https://kubernetes.default.svc, namespace: devops}\n" > "$T/apps/99-outside.yaml"
'
expect_catch "ApplicationSet list element path outside specs/cluster (fail closed)" "$(ipw "apps/13a-optional-services.yaml: an Argo source in this repo applies 'templates/owncast'")" '
  imgswap apps/13a-optional-services.yaml "path: specs/cluster/manifests/owncast," "path: templates/owncast,"
'
# (23y) THE REPORTED EXPLOIT: a !!binary image under apps/, and (23z) in a kustomize dir.
expect_catch "image: !!binary (busybox:latest) in apps/" "$(ipw "apps/99-probe-bin.yaml: image 'busybox:latest'")" '
  printf "apiVersion: batch/v1\nkind: Job\nmetadata: {name: p, namespace: devops}\nspec:\n  template:\n    spec:\n      restartPolicy: Never\n      containers:\n        - name: p\n          image: !!binary YnVzeWJveDpsYXRlc3Q=\n" > "$T/apps/99-probe-bin.yaml"
'
expect_catch "image: !!binary (busybox:latest) behind an images: rewrite (static mode)" "$(ipw "manifests/owncast/deployment.yaml: image 'busybox:latest'")" '
  imgswap manifests/owncast/deployment.yaml "          image: hugmesh/owncast-ui
" "          image: !!binary YnVzeWJveDpsYXRlc3Q=
"
'
# (23aa) an image of any other type cannot be judged: fail closed.
expect_catch "image: 42 (not a string, fail closed)" "$(ipw "manifests/owncast/deployment.yaml: an \`image:\` value 42 is a int")" '
  imgswap manifests/owncast/deployment.yaml "          image: hugmesh/owncast-ui
" "          image: 42
"
'
# (23ab) THE REPORTED CONCERN: an ApplicationSet {{ }} value is refused, not skipped.
expect_catch "ApplicationSet kustomize.images owncast/owncast={{ .img }} (fail closed)" "$(ipw "apps/99-probe-set.yaml (kustomize.images override 'owncast/owncast={{ .img }}'): image '{{ .img }}' contains a template expression")" '
  printf "apiVersion: argoproj.io/v1alpha1\nkind: ApplicationSet\nmetadata: {name: p, namespace: devops}\nspec:\n  goTemplate: true\n  generators:\n    - list:\n        elements:\n          - {img: \"owncast/owncast:latest\"}\n  template:\n    metadata: {name: p}\n    spec:\n      project: default\n      source:\n        repoURL: https://github.com/hugmesh/hugmesh-generator.git\n        targetRevision: main\n        path: specs/cluster/manifests/owncast\n        kustomize:\n          images: [\"owncast/owncast={{ .img }}\"]\n      destination: {server: https://kubernetes.default.svc, namespace: hugmesh-owncast}\n" > "$T/apps/99-probe-set.yaml"
'
# (23ac) an embedded YAML image behind a tag PyYAML refuses (a consumer may not).
expect_catch "embedded helperPod.yaml image: !custom busybox:latest (text backstop)" "${LP_WANT}" '
  imgswap manifests/local-path/local-path.yaml "image: busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e" "image: !custom busybox:latest"
'

# (23ad) an image under a key not named `image`: CNPG-style imageName, (23ae) an env
# entry named *_IMAGE, (23af) an env-style HELPER_IMAGE= assignment in a script.
expect_catch "imageName: postgres:latest (a key not named image)" "$(ipw "apps/99-probe-cnpg.yaml: image 'postgres:latest'")" '
  printf "apiVersion: postgresql.cnpg.io/v1\nkind: Cluster\nmetadata: {name: p, namespace: devops}\nspec:\n  instances: 1\n  imageName: postgres:latest\n" > "$T/apps/99-probe-cnpg.yaml"
'
expect_catch "env {name: HELPER_IMAGE, value: busybox:latest}" "$(ipw "manifests/owncast/deployment.yaml: image 'busybox:latest'")" '
  imgswap manifests/owncast/deployment.yaml "          image: hugmesh/owncast-ui
" "          image: hugmesh/owncast-ui
          env:
            - {name: HELPER_IMAGE, value: \"busybox:latest\"}
"
'
expect_catch "script HELPER_IMAGE=busybox:latest (env-style assignment)" "$(ph_want busybox:latest)" '
  printf "\nHELPER_IMAGE=busybox:latest\n" >> "$T/${PH}"
'
# ── (24) IMAGE PINS, round 5: what Argo renders, what Go's YAML reads, what a shell
# joins ──────────────────────────────────────────────────────────────────────────
# A review got a mutable image past round 4 with the gate green, static AND render:
#   (a) an in-tree chart template whose key is split by an empty action
#       (`ima{{""}}ge:`) or escaped (`"im\x61ge":`), inside an `if` on
#       .Release.Namespace that the gate's own helm render (no --namespace) skipped;
#   (b) a repository-only helm image map (`image: {repository: busybox}`), read as
#       "no ref" though the chart's default tag is pulled for it; the same through a
#       `./specs/cluster/...` path and an ApplicationSet, neither of which was rendered;
#   (c) YAML under a tag PyYAML refuses (`!x`) and go-yaml accepts, which hid a whole
#       helm values string or helper-pod spec from the walk;
#   (d) kubectl `--overrides` / `--override-type`, `--ima""ge`, and `--image` and its
#       value as two items of an args list;
#   (e) Argo fields never read: kustomize.components outside the tree, a pinned
#       targetRevision, a helm parameter NAME with a comma;
#   (f) static-only: a CRD `container.image` credited to an `images:` rewrite that
#       kustomize never applies to it, a Chart.yaml dependency, and remote kustomize
#       resources spelled without `://`.
R5_TPL=charts/hugmesh-gateway/templates/r5-probe.yaml
r5tpl() {  # <container line(s)> [condition]: write a probe Pod template into the chart
  { [ -n "${2:-}" ] && printf '{{- if %s }}\n' "$2"
    printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: r5-probe\nspec:\n  containers:\n    - name: p\n%s\n' "$1"
    [ -n "${2:-}" ] && printf '{{- end }}\n'; true; } > "$T/${R5_TPL}"
}
ph_want_r5() { ipw "manifests/prod-hygiene/kustomization.yaml (configMapGenerator prod-hygiene-script file validate-prod-hygiene.sh): $1"; }
tplw() { ipw "${R5_TPL} (chart template): line $1: $2"; }
# (24a) THE REPORTED EXPLOIT n1: an action splitting the key, behind a namespace test.
expect_catch "chart template key split by an empty action: ima{{\"\"}}ge" "$(tplw 8 'a template action joined to a word')" '
  r5tpl "      ima{{\"\"}}ge: busybox:latest"
'
expect_catch "chart template key joined across a newline by {{- \"\" -}} trimming" "$(tplw 9 'a template action joined to a word')" '
  r5tpl "      ima
{{- \"\" -}}
      ge: busybox:latest"
'
expect_catch "chart template branch on .Release.Namespace (render state the gate cannot reproduce)" "$(tplw 1 "the action '{{- if ne .Release.Namespace \"default\" }}' reads render state")" '
  r5tpl "      image: registry.hugmesh.net/hugmesh/hugmesh-gateway:dev" "ne .Release.Namespace \"default\""
'
expect_catch "chart template branch on .Capabilities.APIVersions.Has" "$(tplw 1 "the action '{{- if .Capabilities.APIVersions.Has \"r5/v1\" }}' reads render state")" '
  r5tpl "      image: registry.hugmesh.net/hugmesh/hugmesh-gateway:dev" ".Capabilities.APIVersions.Has \"r5/v1\""
'
# (24b) THE REPORTED EXPLOIT n2/n2b: a YAML-escaped key; the text read decodes it.
expect_catch "chart template \"im\\x61ge\": busybox:latest (escape decoded)" "$(ipw "${R5_TPL} (chart file, read as text): image 'busybox:latest'")" '
  r5tpl "      \"im\\x61ge\": \"busybox:latest\""
'
expect_catch "chart template key spelled with an escape (fail closed)" "$(tplw 8 'a YAML key spelled with a backslash escape')" '
  r5tpl "      \"im\\x61ge\": \"registry.hugmesh.net/hugmesh/hugmesh-gateway:dev\""
'
# (24c) other ways a template assembles text: a key that IS an action, a function
# outside the modelled set, printf joining two values, a literal carrying a colon.
expect_catch "chart template key written by an action" "$(tplw 8 'a YAML key written by a template action')" '
  r5tpl "      {{ .Values.instance.name }}: busybox:latest"
'
expect_catch "chart template function tpl (not modelled, fail closed)" "$(tplw 9 "template function 'tpl' is not one this check models")" '
  r5tpl "      image: registry.hugmesh.net/hugmesh/hugmesh-gateway:dev
      args: [{{ tpl .Values.instance.name . }}]"
'
expect_catch "chart template printf joining two values" "$(tplw 9 'print/printf joins more than one value')" '
  r5tpl "      image: registry.hugmesh.net/hugmesh/hugmesh-gateway:dev
      args: [{{ printf \"%s%s\" .Values.instance.name .Release.Name }}]"
'
expect_catch "chart template literal with a colon in an action" "$(tplw 9 "the string literal '\"ge: busybox\"' in a template action")" '
  r5tpl "      image: registry.hugmesh.net/hugmesh/hugmesh-gateway:dev
      args: [{{ print \"ge: busybox\" }}]"
'
# (24d) THE REPORTED EXPLOIT n3/n3b/n4: a repository-only helm image map.
R5_REPO_ONLY='      values: |
        image:
          repository: busybox
        instance:
'
expect_catch "Argo helm values image: {repository: busybox} with no tag (chart default tag)" "$(ipw "apps/20-gateway-pki.yaml: a helm image map sets repository 'busybox' but no tag or digest")" '
  imgswap apps/20-gateway-pki.yaml "      values: |
        instance:
" "${R5_REPO_ONLY}"
'
export R5_REPO_ONLY
R5_APPSET='apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata: {name: r5-probe, namespace: devops}
spec:
  goTemplate: true
  generators:
    - list:
        elements:
          - {slug: probe}
  template:
    metadata: {name: "r5-{{ .slug }}"}
    spec:
      project: default
      source:
        repoURL: https://github.com/hugmesh/hugmesh-generator.git
        targetRevision: main
        path: specs/cluster/charts/hugmesh-gateway
        helm:
          releaseName: r5-probe
          valuesObject:
            image: {repository: busybox}
      destination: {server: https://kubernetes.default.svc, namespace: hugmesh-fe}
'
export R5_APPSET
expect_catch "ApplicationSet over the in-tree chart, valuesObject image.repository busybox" "$(ipw "apps/99-r5-set.yaml: a helm image map sets repository 'busybox' but no tag or digest")" '
  printf "%s" "${R5_APPSET}" > "$T/apps/99-r5-set.yaml"
'
expect_catch "ApplicationSet with a git generator over the in-tree chart (fail closed)" "$(ipw "apps/99-r5-set.yaml: ApplicationSet 'r5-probe' over this repo uses a generator other than \`list\`")" '
  printf "%s" "${R5_APPSET}" | python3 -c "import sys; s=sys.stdin.read(); o=\"    - list:\n        elements:\n          - {slug: probe}\n\"; assert o in s; sys.stdout.write(s.replace(o, \"    - git: {repoURL: https://github.com/hugmesh/hugmesh-generator.git, revision: main, directories: [{path: x}]}\n\").replace(\"image: {repository: busybox}\", \"replicaCount: 1\"))" > "$T/apps/99-r5-set.yaml"
'
# (24e) THE REPORTED EXPLOIT n5: an unknown YAML tag no longer hides helm values.
R5_VELERO='apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: r5-velero, namespace: devops}
spec:
  project: default
  source:
    repoURL: https://vmware-tanzu.github.io/helm-charts
    chart: velero
    targetRevision: 8.0.0
    helm:
      values: |
        r5note: !x unread
        image:
          repository: velero/velero
          tag: latest
  destination: {server: https://kubernetes.default.svc, namespace: velero}
'
export R5_VELERO
expect_catch "helm values string with an unknown !x tag (go-yaml reads it)" "$(ipw "apps/99-r5-velero.yaml: image 'velero/velero:latest'")" '
  printf "%s" "${R5_VELERO}" > "$T/apps/99-r5-velero.yaml"
'
expect_catch "helm values string that does not parse (fail closed)" "$(ipw "apps/99-r5-velero.yaml: Argo helm.values does not parse")" '
  printf "%s" "${R5_VELERO}" | sed "s/r5note: !x unread/r5note: [unclosed/" > "$T/apps/99-r5-velero.yaml"
'
expect_catch "ConfigMap values.yaml with an unknown !x tag over a helm image map (structure only)" "$(ipw "apps/99-r5-cm.yaml: image 'velero/velero:latest'")" '
  printf "apiVersion: v1\nkind: ConfigMap\nmetadata: {name: r5-values, namespace: devops}\ndata:\n  values.yaml: |\n    r5note: !x unread\n    image:\n      repository: velero/velero\n      tag: latest\n" > "$T/apps/99-r5-cm.yaml"
'
# (24f) THE REPORTED EXPLOIT n9: helperPod.yaml with `metadata: !x` and an escaped key.
expect_catch "helperPod.yaml metadata: !x with \"im\\x61ge\": busybox:latest" "${LP_WANT}" '
  python3 - "$T/manifests/local-path/local-path.yaml" <<"PY"
import re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
i = s.index("  helperPod.yaml: |-\n"); blk = s[i:]
new = re.sub(r"(\n\s*)image: (\S*busybox\S*)", lambda m: m.group(1) + "\"im\\x61ge\": \"busybox:latest\"", blk, count=1)
a = "\n    metadata:\n      name: helper-pod\n"
assert a in new and new != blk
open(p, "w", encoding="utf-8").write(s[:i] + new.replace(a, "\n    metadata: !x\n      name: helper-pod\n", 1))
PY
'
# (24g) THE REPORTED EXPLOITS n6/n7/n8: kubectl spellings in the prod-hygiene script.
expect_catch "kubectl run --override-type=json --overrides (JSON patch onto the image)" "$(ph_want_r5 "a string passes kubectl --overrides")" '
  printf "\nkubectl -n \"\$NS\" run r5-probe --restart=Never ${CURL_PIN} --override-type=json --overrides='"'"'[{\"op\":\"replace\",\"path\":\"/spec/containers/0/image\",\"value\":\"busybox:latest\"}]'"'"' -- true\n" >> "$T/${PH}"
'
expect_catch "kubectl run --overrides with a \\u0061 escape in the image key" "$(ph_want busybox:latest)" '
  printf "\nkubectl -n x run r5-probe ${CURL_PIN} --overrides='"'"'{\"spec\":{\"containers\":[{\"name\":\"r5-probe\",\"im\\\\u0061ge\":\"busybox:latest\"}]}}'"'"' -- true\n" >> "$T/${PH}"
'
expect_catch "--ima\"\"ge=busybox:latest (shell joins the quotes)" "$(ph_want busybox:latest)" '
  printf "\nkubectl -n x run r5-probe --restart=Never --ima\"\"ge=busybox:latest -- true\n" >> "$T/${PH}"
'
expect_catch "--\"\$F\"=busybox:latest (flag name from a variable, fail closed)" "$(ph_want_r5 "a string passes a command-line flag whose name is assembled")" '
  printf "\nkubectl -n x run r5-probe --\"\$F\"=busybox:latest -- true\n" >> "$T/${PH}"
'
expect_catch "kubectl patch --type json onto a container image path (fail closed)" "$(ph_want_r5 "a string holds a JSON patch op onto an image path")" '
  printf "\nkubectl -n x patch deploy/web --type json -p '"'"'[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"busybox:latest\"}]'"'"'\n" >> "$T/${PH}"
'
# (24h) THE REPORTED EXPLOIT n13: --image and its value as two items of an args list.
expect_catch "initContainer args [\"--image\", \"busybox:latest\"] (argv list)" "$(ipw "manifests/prod-hygiene/job.yaml: image 'busybox:latest'")" '
  python3 - "$T/manifests/prod-hygiene/job.yaml" <<"PY"
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
a = "      containers:\n        - name: gate\n"
assert s.count(a) == 1
s = s.replace(a, "      initContainers:\n        - name: r5-probe\n          image: docker.io/bitnamilegacy/kubectl:1.31\n          command: [\"kubectl\"]\n          args: [\"-n\", \"hugmesh-system\", \"run\", \"r5-probe\", \"--restart=Never\", \"--image\", \"busybox:latest\", \"--\", \"true\"]\n" + a)
open(p, "w", encoding="utf-8").write(s)
PY
'
# (24i) THE REPORTED EXPLOITS n10/n11/n14: Argo fields the gate never read.
R5_EDGE='apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: r5-edge-ai, namespace: devops}
spec:
  project: default
  source:
    repoURL: https://github.com/hugmesh/hugmesh-generator.git
    targetRevision: main
    path: specs/cluster/manifests/edge-ai
  destination: {server: https://kubernetes.default.svc, namespace: hugmesh-inference}
'
export R5_EDGE
expect_catch "Argo kustomize.components outside specs/cluster (fail closed)" "$(ipw "apps/99-r5-comp.yaml: Argo kustomize component '../../../../tests/r5-comp' is not a directory under specs/cluster")" '
  printf "%s    kustomize:\n      components: [../../../../tests/r5-comp]\n" "$(printf "%s" "${R5_EDGE}" | sed "/^  destination/d")
" > "$T/apps/99-r5-comp.yaml"
  printf "  destination: {server: https://kubernetes.default.svc, namespace: hugmesh-inference}\n" >> "$T/apps/99-r5-comp.yaml"
'
expect_catch "Argo kustomize key the check does not model (fail closed)" "$(ipw "apps/99-r5-comp.yaml: Argo kustomize key 'r5Unknown' is not one this check models")" '
  printf "%s    kustomize:\n      r5Unknown: true\n" "$(printf "%s" "${R5_EDGE}" | sed "/^  destination/d")
" > "$T/apps/99-r5-comp.yaml"
  printf "  destination: {server: https://kubernetes.default.svc, namespace: hugmesh-inference}\n" >> "$T/apps/99-r5-comp.yaml"
'
expect_catch "Argo app on this repo with targetRevision ae585a51 (an old commit)" "$(ipw "apps/99-r5-rev.yaml: an Argo source in this repo pins targetRevision 'ae585a51'")" '
  printf "%s" "${R5_EDGE}" | sed "s/targetRevision: main/targetRevision: ae585a51/" > "$T/apps/99-r5-rev.yaml"
'
expect_catch "helm parameter name image.tag=latest,image.pullPolicy (comma in the NAME)" "$(ipw "apps/55-velero.yaml: helm parameter name 'image.tag=latest,image.pullPolicy' holds an unescaped")" '
  imgswap apps/55-velero.yaml "    helm:
" "    helm:
      parameters:
        - name: \"image.tag=latest,image.pullPolicy\"
          value: Always
"
'
# (24j) static-only in round 4: a CRD field kustomize's images: never rewrites.
expect_catch "WorkflowTemplate container.image ollama/ollama behind an images: entry it does not get" "$(ipw "manifests/edge-ai/r5-workflow.yaml: image 'ollama/ollama' has no tag")" '
  printf "apiVersion: argoproj.io/v1alpha1\nkind: WorkflowTemplate\nmetadata: {name: r5-probe}\nspec:\n  entrypoint: main\n  templates:\n    - name: main\n      container: {image: ollama/ollama, command: [\"true\"]}\n" > "$T/manifests/edge-ai/r5-workflow.yaml"
  imgswap manifests/edge-ai/kustomization.yaml "
resources:
" "
resources:
  - r5-workflow.yaml
"
'
expect_catch "Chart.yaml dependencies: on a remote chart (fail closed)" "$(ipw "charts/hugmesh-gateway/Chart.yaml: declares chart \`dependencies:\`")" '
  printf "dependencies:\n  - name: r5-sub\n    repository: https://charts.example.org/r5\n    version: \"*\"\n" >> "$T/charts/hugmesh-gateway/Chart.yaml"
'
expect_catch "kustomize resource git::github.com/... (remote without ://)" "$(ipw "manifests/edge-ai/kustomization.yaml: \`resources:\` pulls in the REMOTE 'git::github.com/kubernetes-sigs/kustomize//examples/helloWorld': it is not a file or directory")" '
  imgswap manifests/edge-ai/kustomization.yaml "
resources:
" "
resources:
  - git::github.com/kubernetes-sigs/kustomize//examples/helloWorld
"
'
expect_catch "kustomize resource github.com:org/repo//dir (remote, scp-style)" "$(ipw "manifests/edge-ai/kustomization.yaml: \`resources:\` pulls in the REMOTE 'github.com:kubernetes-sigs/kustomize//examples/helloWorld': it is not a file or directory")" '
  imgswap manifests/edge-ai/kustomization.yaml "
resources:
" "
resources:
  - github.com:kubernetes-sigs/kustomize//examples/helloWorld
"
'

# (21-render) the kubectl render cross-check catches the three reported exploits ON
# ITS OWN: the staged tree is rendered and judged without the static reader.
render_catch() {  # <label> <injection> [image name prefix, default owncast/owncast]
  local label="$1" inject="$2" prefix="${3:-owncast/owncast}" T="${WORK}/tree"
  rm -rf "${T}"; cp -r "${REPO}/specs/cluster" "${T}"
  ( T="${T}"; eval "${inject}" ) || { neg_bad "${label} (injection failed)"; return; }
  local out
  if out="$(HUGMESH_IMAGE_PIN_RENDER=1 python3 - "$(dirname "${CHECKER}")" "${T}" "${prefix}" <<"PY" 2>&1
import sys
sys.path.insert(0, sys.argv[1])
import cluster_manifest_integrity as m
rendered, why = m._render_refs(sys.argv[2])
assert rendered is not None, "render did not run: %s" % why
bad = sorted({r for refs in rendered.values() for r in refs
              if r.startswith(sys.argv[3]) and m._judge_ref(r, set())})
assert bad, "no mutable %s ref in the render" % sys.argv[3]
print(" ".join(bad))
PY
)"; then neg_ok "${label} -> render cross-check caught ${out}"
  else neg_bad "${label} NOT caught by the render cross-check: ${out}"; fi
}
if command -v kubectl >/dev/null 2>&1; then
  render_catch "render: raw owncast/owncast:stable" '
    oc_drop_entry; imgswap manifests/owncast/deployment.yaml "          image: owncast/owncast
" "          image: owncast/owncast:stable
"'
  render_catch "render: Component newTag latest" '
    oc_drop_entry; mkdir "$T/manifests/owncast/pin"
    printf "apiVersion: kustomize.config.k8s.io/v1alpha1\nkind: Component\nimages:\n  - {name: owncast/owncast, newName: owncast/owncast, newTag: latest}\n" > "$T/manifests/owncast/pin/kustomization.yaml"
    printf "components:\n  - pin\n" >> "$T/manifests/owncast/kustomization.yaml"'
  render_catch "render: JSON6902 patch :develop" '
    oc_drop_entry; printf "%s" "${OC_JSONPATCH}" >> "$T/manifests/owncast/kustomization.yaml"'
  # (22-render) round 3: a single-line JSON ConfigMap value and a generator literal.
  render_catch "render: single-line JSON helperPod.yaml busybox:latest" '
    lp_helper "  helperPod.yaml: '"'"'{\"apiVersion\":\"v1\",\"kind\":\"Pod\",\"metadata\":{\"name\":\"helper-pod\"},\"spec\":{\"containers\":[{\"name\":\"helper-pod\",\"image\":\"busybox:latest\"}]}}'"'"'"' busybox
  render_catch "render: configMapGenerator literal busybox:latest" '
    printf "configMapGenerator:\n  - name: helper\n    literals:\n      - '"'"'helperPod.yaml=%s'"'"'\n" "${GEN_POD}" >> "$T/manifests/owncast/kustomization.yaml"' busybox
  render_catch "render: bare busybox in the helper-pod template is not rewritten by images:" "${LP_REWRITE}" busybox
  # (23-render) round 4: the binaryData helper pod is decoded in the render pass too.
  render_catch "render: ConfigMap binaryData helperPod.yaml busybox:latest" 'lp_b64 image' busybox
else
  echo "  NOTE (21-render) NOT run: kubectl is not on PATH, so the render cross-check is untested here"
fi

# (23-helm) with helm on PATH the in-tree chart is rendered with each Argo app's values
# and the output judged, independently of the text read of its templates.
helm_render_catch() {  # <label> <injection> <image name prefix>
  local label="$1" inject="$2" prefix="$3" T="${WORK}/tree"
  rm -rf "${T}"; cp -r "${REPO}/specs/cluster" "${T}"
  ( T="${T}"; eval "${inject}" ) || { neg_bad "${label} (injection failed)"; return; }
  local out
  if out="$(HUGMESH_IMAGE_PIN_RENDER=1 python3 - "$(dirname "${CHECKER}")" "${T}" "${prefix}" <<"PY" 2>&1
import sys
sys.path.insert(0, sys.argv[1])
import cluster_manifest_integrity as m
rendered, why = m._helm_render_refs(sys.argv[2])
assert rendered is not None, "helm render did not run: %s" % why
bad = sorted({"%s: %s" % (k, r) for k, refs in rendered.items()
              for r in refs if r.startswith(sys.argv[3]) and m._judge_ref(r, set())})
assert bad, "no mutable %s ref in the helm render" % sys.argv[3]
print("; ".join(bad))
PY
)"; then neg_ok "${label} -> helm render caught ${out}"
  else neg_bad "${label} NOT caught by the helm render: ${out}"; fi
}
GW_LITERAL='python3 - "$T/${GW_TPL}" <<"PY"
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
old = "          image: \"{{ .Values.image.repository }}:{{ .Values.image.tag }}\""
assert s.count(old) == 2, s.count(old)
open(p, "w", encoding="utf-8").write(s.replace(old, "          image: \"busybox:latest\"", 1))
PY'
if command -v helm >/dev/null 2>&1; then
  helm_render_catch "helm render: literal busybox:latest in the gateway chart template" "${GW_LITERAL}" busybox
  helm_render_catch "helm render: an Argo app parameter image.tag=latest on the gateway chart" '
    imgswap apps/20-gateway-pki.yaml "      releaseName: hugmesh-pki-gateway
" "      releaseName: hugmesh-pki-gateway
      parameters:
        - {name: image.tag, value: latest}
"' registry.hugmesh.net/hugmesh/hugmesh-gateway
  # (24-helm) round 5: rendered the way Argo CD renders it. --namespace is the
  # destination namespace (n1), a `./specs/cluster/...` path is the same chart (n3),
  # and a list ApplicationSet is expanded and rendered per element (n4).
  helm_render_catch "helm render: template behind if ne .Release.Namespace \"default\" (Argo passes --namespace)" '
    r5tpl "      image: busybox:latest" "ne .Release.Namespace \"default\""' busybox
  helm_render_catch "helm render: app path ./specs/cluster/charts/hugmesh-gateway + image.repository busybox" '
    imgswap apps/20-gateway-pki.yaml "    path: specs/cluster/charts/hugmesh-gateway
" "    path: ./specs/cluster/charts/hugmesh-gateway
"
    imgswap apps/20-gateway-pki.yaml "      values: |
        instance:
" "${R5_REPO_ONLY}"' busybox
  helm_render_catch "helm render: list ApplicationSet over the in-tree chart, valuesObject image.repository busybox" '
    printf "%s" "${R5_APPSET}" > "$T/apps/99-r5-set.yaml"' busybox
else
  echo "  NOTE (23-helm) NOT run: helm is not on PATH, so the helm render is untested here"
fi

echo
echo "== negative controls: ${NEG_P} passed, ${NEG_F} failed =="
[ "${NEG_F}" -eq 0 ] || exit 1
echo "== cluster manifest integrity: PASS =="
exit 0

#!/usr/bin/env bash
# test-mdm-manifests-render.sh — kustomize render + invariant test for the two
# server-side MDM manifest sets: specs/cluster/manifests/headwind/ (Headwind MDM
# console + its Postgres) and specs/cluster/manifests/attestation-server/
# (GrapheneOS AttestationServer fork-pinned build). Mirrors
# tests/stack/test-coturn-optional-service.sh's pure-render approach: kustomize
# build (or kubectl kustomize) + static assertions on the RENDERED stream — no
# cluster, no docker build, no network.
#
# Proves (all against the RENDER, so kustomization wiring is part of the SUT):
#   (1) both kustomizations RENDER without error (resources + configMapGenerator
#       + the imagePullSecrets patches all resolve);
#   (2) SA ownership: headwind's render carries sa-headwind AND sa-headwind-db,
#       attestation-server's carries sa-attestation-server — and neither render
#       leaks the other's SAs (per-app identity boundary, docs/SECURITY.md §3);
#   (3) both custom-image Deployments (headwind, attestation-server) pin the
#       pod to runAsUser/runAsGroup 1000 + runAsNonRoot (matches the images'
#       baked uid-1000 users; the attestation smtp-seeder's deliberate
#       root override stays confined to that one sidecar);
#   (4) the headwind Service exposes 8080 (console) + 31000 (MQTT) and EVERY
#       Service in both renders is ClusterIP — no NodePort/LoadBalancer/nodePort
#       anywhere (tailnet-only posture; MQTT external reach is documented
#       DEFERRED work, not an invented NodePort);
#   (5) PROTOCOL=http in the headwind ConfigMap (gateway-terminated TLS — the
#       upstream https/self-signed-JKS default must stay overridden);
#   (6) ADMIN_EMAIL comes from Secret headwind-admin/email, and the DEAD
#       HEADWIND_ADMIN_USERNAME/HEADWIND_ADMIN_PASSWORD vars stay REMOVED
#       (regression guard — they were confirmed never read by the entrypoint);
#   (7) attestation-server probes are tcpSocket (NOT httpGet — upstream has
#       ZERO GET handlers, so an httpGet probe can never succeed), the
#       smtp-config-seeder sidecar is present + fed from Secret
#       attestation-server-smtp, and the app images follow the
#       registry.hugmesh.systems/hugmesh/... convention;
#   (8) NEGATIVE CONTROLS, staged copies only (the repo tree is never mutated):
#       a bogus resource entry makes the render FAIL nonzero (the render gate
#       bites), and a staged PROTOCOL:https copy makes assertion (5) FAIL (the
#       invariant checks are not tautologies).
#
# SKIPs (exit 0) when no renderer (kustomize/kubectl) is available.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HW_DIR="${REPO}/specs/cluster/manifests/headwind"
ATT_DIR="${REPO}/specs/cluster/manifests/attestation-server"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

echo "== MDM manifests render + invariants (headwind + attestation-server) =="

KZ=""
command -v kustomize >/dev/null 2>&1 && KZ="kustomize build"
[ -z "${KZ}" ] && command -v kubectl >/dev/null 2>&1 && KZ="kubectl kustomize"
[ -z "${KZ}" ] && { echo "SKIP: need kustomize or kubectl"; exit 0; }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT

# ── helpers: multi-doc split + kind/name doc lookup ───────────────────────────
split_docs() { # <render-file> <prefix> — one doc per <prefix>-N file
  local n=0 out="$2-0" line
  : > "${out}"
  while IFS= read -r line; do
    if [ "${line}" = "---" ]; then n=$((n+1)); out="$2-${n}"; : > "${out}"; continue; fi
    printf '%s\n' "${line}" >> "${out}"
  done < "$1"
}
find_doc() { # <prefix> <Kind> <metadata.name> — echoes the doc file, rc 1 if absent
  local f
  for f in "$1"-*; do
    [ -f "${f}" ] || continue
    if grep -qx "kind: $2" "${f}" && grep -qx "  name: $3" "${f}"; then
      echo "${f}"; return 0
    fi
  done
  return 1
}

# ── 1) both kustomizations render ─────────────────────────────────────────────
echo "-- 1) render --"
if ${KZ} "${HW_DIR}" > "${WORK}/hw.yaml" 2>"${WORK}/hw.err" && [ -s "${WORK}/hw.yaml" ]; then
  ok "(1) headwind/ renders (${KZ})"
else
  bad "(1) headwind/ render FAILED: $(tr -d '\n' <"${WORK}/hw.err" | cut -c1-200)"
  echo "== RESULT: ${P} passed, ${F} failed =="; exit 1
fi
if ${KZ} "${ATT_DIR}" > "${WORK}/att.yaml" 2>"${WORK}/att.err" && [ -s "${WORK}/att.yaml" ]; then
  ok "(1) attestation-server/ renders (${KZ})"
else
  bad "(1) attestation-server/ render FAILED: $(tr -d '\n' <"${WORK}/att.err" | cut -c1-200)"
  echo "== RESULT: ${P} passed, ${F} failed =="; exit 1
fi
split_docs "${WORK}/hw.yaml"  "${WORK}/hw-doc"
split_docs "${WORK}/att.yaml" "${WORK}/att-doc"

# ── 2) ServiceAccount ownership across the two sets ───────────────────────────
echo "-- 2) ServiceAccounts (per-app identity, right kustomization owns each) --"
find_doc "${WORK}/hw-doc" ServiceAccount sa-headwind >/dev/null \
  && ok "(2) headwind render owns ServiceAccount sa-headwind" || bad "(2) sa-headwind missing from headwind render"
find_doc "${WORK}/hw-doc" ServiceAccount sa-headwind-db >/dev/null \
  && ok "(2) headwind render owns ServiceAccount sa-headwind-db" || bad "(2) sa-headwind-db missing from headwind render"
find_doc "${WORK}/att-doc" ServiceAccount sa-attestation-server >/dev/null \
  && ok "(2) attestation render owns ServiceAccount sa-attestation-server" || bad "(2) sa-attestation-server missing from attestation render"
grep -q 'sa-attestation-server' "${WORK}/hw.yaml" \
  && bad "(2) BOUNDARY: headwind render leaks sa-attestation-server" \
  || ok "(2) headwind render does NOT carry attestation's SA (boundary intact)"
grep -qE 'sa-headwind' "${WORK}/att.yaml" \
  && bad "(2) BOUNDARY: attestation render leaks a headwind SA" \
  || ok "(2) attestation render does NOT carry headwind's SAs (boundary intact)"
# token automount stays OFF on all three (defence-in-depth; none needs the k8s API)
[ "$(grep -c 'automountServiceAccountToken: false' "${WORK}/hw.yaml" "${WORK}/att.yaml" | awk -F: '{s+=$2} END{print s}')" -ge 3 ] \
  && ok "(2) all 3 SAs keep automountServiceAccountToken: false" \
  || bad "(2) an SA re-enabled token automount"

# ── 3) runAsUser 1000 on both custom-image Deployments ────────────────────────
echo "-- 3) rootless posture (uid 1000 pods) --"
HW_DEP="$(find_doc "${WORK}/hw-doc" Deployment headwind)" || { bad "(3) headwind Deployment missing"; HW_DEP=/dev/null; }
ATT_DEP="$(find_doc "${WORK}/att-doc" Deployment attestation-server)" || { bad "(3) attestation-server Deployment missing"; ATT_DEP=/dev/null; }
grep -q 'runAsUser: 1000' "${HW_DEP}" && grep -q 'runAsNonRoot: true' "${HW_DEP}" \
  && ok "(3) headwind Deployment: runAsNonRoot + runAsUser 1000 (matches the image's uid-1000 hmdm user)" \
  || bad "(3) headwind Deployment lost the uid-1000 pod securityContext"
grep -q 'runAsUser: 0' "${HW_DEP}" \
  && bad "(3) headwind Deployment contains a root (runAsUser: 0) override" \
  || ok "(3) headwind Deployment has NO root override anywhere"
grep -q 'runAsUser: 1000' "${ATT_DEP}" && grep -q 'runAsNonRoot: true' "${ATT_DEP}" \
  && ok "(3) attestation-server Deployment: runAsNonRoot + runAsUser 1000 (image's uid-1000 attestation user)" \
  || bad "(3) attestation-server Deployment lost the uid-1000 pod securityContext"
# the ONE deliberate root override is the apk-needing smtp seeder sidecar — exactly one
[ "$(grep -c 'runAsUser: 0' "${ATT_DEP}")" -eq 1 ] \
  && ok "(3) attestation render's single root override stays confined to the smtp-config-seeder sidecar" \
  || bad "(3) unexpected runAsUser: 0 count in the attestation Deployment ($(grep -c 'runAsUser: 0' "${ATT_DEP}"))"

# ── 4) Services: ClusterIP-only, headwind exposes 8080 + 31000 ────────────────
echo "-- 4) Services (tailnet-only ClusterIP posture) --"
HW_SVC="$(find_doc "${WORK}/hw-doc" Service headwind)" || { bad "(4) headwind Service missing"; HW_SVC=/dev/null; }
grep -q 'type: ClusterIP' "${HW_SVC}" && grep -q 'port: 8080' "${HW_SVC}" && grep -q 'port: 31000' "${HW_SVC}" \
  && ok "(4) headwind Service: ClusterIP with 8080 (console) + 31000 (MQTT)" \
  || bad "(4) headwind Service ports/type wrong"
ATT_SVC="$(find_doc "${WORK}/att-doc" Service attestation-server)" || { bad "(4) attestation Service missing"; ATT_SVC=/dev/null; }
grep -q 'type: ClusterIP' "${ATT_SVC}" && grep -q 'port: 8080' "${ATT_SVC}" \
  && ok "(4) attestation-server Service: ClusterIP with 8080" \
  || bad "(4) attestation-server Service ports/type wrong"
if grep -qE 'type: (NodePort|LoadBalancer)|nodePort:' "${WORK}/hw.yaml" "${WORK}/att.yaml"; then
  bad "(4) a NodePort/LoadBalancer/nodePort leaked into an MDM render (tailnet-only posture broken)"
else
  ok "(4) NO NodePort/LoadBalancer/nodePort anywhere in either render"
fi

# ── 5) PROTOCOL=http in the headwind ConfigMap ────────────────────────────────
echo "-- 5) headwind ConfigMap protocol --"
check_protocol_http() { # <prefix> — rc 0 iff headwind-config carries PROTOCOL: http
  local cm
  cm="$(find_doc "$1" ConfigMap headwind-config)" || return 1
  grep -qx '  PROTOCOL: http' "${cm}"
}
check_protocol_http "${WORK}/hw-doc" \
  && ok "(5) headwind-config PROTOCOL: http (gateway-terminated TLS; upstream https default stays overridden)" \
  || bad "(5) headwind-config PROTOCOL is not http"
# the generated initdb ConfigMap keeps its FIXED name (disableNameSuffixHash)
HW_INITDB="$(find_doc "${WORK}/hw-doc" ConfigMap headwind-db-initdb)" \
  && grep -q '00-hardening.sql' "${HW_INITDB}" \
  && ok "(5) configMapGenerator output headwind-db-initdb rendered, hash-suffix-free, carrying 00-hardening.sql" \
  || bad "(5) headwind-db-initdb ConfigMap missing/renamed/empty"

# ── 6) admin provisioning: ADMIN_EMAIL from Secret; dead vars stay dead ───────
echo "-- 6) headwind admin provisioning env --"
grep -A4 'name: ADMIN_EMAIL' "${HW_DEP}" | grep -q 'name: headwind-admin' \
  && ok "(6) ADMIN_EMAIL <- secretKeyRef headwind-admin (the ONLY admin-provisioning env the entrypoint honors)" \
  || bad "(6) ADMIN_EMAIL not sourced from Secret headwind-admin"
if grep -qE 'HEADWIND_ADMIN_(USERNAME|PASSWORD)' "${WORK}/hw.yaml" "${WORK}/att.yaml"; then
  bad "(6) REGRESSION: dead HEADWIND_ADMIN_USERNAME/PASSWORD vars re-appeared in a render"
else
  ok "(6) no HEADWIND_ADMIN_USERNAME/HEADWIND_ADMIN_PASSWORD anywhere (removed-as-dead stays removed)"
fi

# ── 7) attestation-server specifics: probes, seeder, image convention ─────────
echo "-- 7) attestation-server probes / sidecar / images --"
[ "$(grep -c 'tcpSocket:' "${ATT_DEP}")" -ge 2 ] \
  && ok "(7) attestation-server readiness+liveness are tcpSocket" \
  || bad "(7) attestation-server tcpSocket probes missing"
grep -q 'httpGet' "${WORK}/att.yaml" \
  && bad "(7) an httpGet probe appeared in the attestation render (upstream serves NO GET routes — it would never pass)" \
  || ok "(7) NO httpGet anywhere in the attestation render (upstream is POST-only)"
grep -q 'name: smtp-config-seeder' "${ATT_DEP}" \
  && ok "(7) smtp-config-seeder sidecar present" \
  || bad "(7) smtp-config-seeder sidecar missing"
grep -A2 'secretRef:' "${ATT_DEP}" | grep -q 'name: attestation-server-smtp' \
  && ok "(7) seeder is fed from Secret attestation-server-smtp (envFrom)" \
  || bad "(7) seeder's attestation-server-smtp secretRef missing"
grep -q 'image: registry.hugmesh.systems/hugmesh/hugmesh-attestation-server:main' "${ATT_DEP}" \
  && ok "(7) app image follows registry.hugmesh.systems/hugmesh/... (built-from-source convention)" \
  || bad "(7) attestation-server image ref off-convention"
grep -q 'image: registry.hugmesh.systems/hugmesh/hugmesh-headwind:main' "${HW_DEP}" \
  && ok "(7) headwind image follows registry.hugmesh.systems/hugmesh/... (built-from-source convention)" \
  || bad "(7) headwind image ref off-convention"
# the harbor pull-secret patches in both kustomizations actually landed
grep -q 'harbor-registry' "${HW_DEP}" && grep -q 'harbor-registry' "${ATT_DEP}" \
  && ok "(7) imagePullSecrets harbor-registry patch applied to BOTH Deployments" \
  || bad "(7) an imagePullSecrets patch did not land"
# known flagged gap stays version-pinned while it exists (no :latest drift)
grep -q 'image: alpine:3\.20' "${ATT_DEP}" \
  && ok "(7) seeder sidecar image stays the pinned alpine:3.20 (documented TODO, not :latest)" \
  || bad "(7) seeder sidecar image changed — re-check the documented alpine TODO"

# ── 8) NEGATIVE CONTROLS (staged copies; the repo tree is never touched) ──────
echo "-- 8) negative controls: the gates actually bite --"
# 8a) bogus resource entry -> render fails nonzero
cp -a "${HW_DIR}" "${WORK}/hw-broken"
sed -i 's|^resources:|resources:\n  - bogus-missing-file.yaml|' "${WORK}/hw-broken/kustomization.yaml"
if ${KZ} "${WORK}/hw-broken" > "${WORK}/hw-broken.yaml" 2>"${WORK}/hw-broken.err"; then
  bad "(8a) render gate VACUOUS: a bogus resource entry still rendered rc=0"
else
  ok "(8a) render gate bites: bogus resource entry -> ${KZ} fails nonzero"
fi
grep -q 'bogus-missing-file' "${WORK}/hw-broken.err" \
  && ok "(8a) failure names the missing resource (actionable error)" \
  || bad "(8a) render error is silent about the bogus resource: $(tr -d '\n' <"${WORK}/hw-broken.err" | cut -c1-160)"
# 8b) the PROTOCOL invariant is not a tautology: a staged https copy FAILS it
cp -a "${HW_DIR}" "${WORK}/hw-https"
sed -i 's/^  PROTOCOL: http$/  PROTOCOL: https/' "${WORK}/hw-https/headwind.yaml"
if ${KZ} "${WORK}/hw-https" > "${WORK}/hw-https.yaml" 2>/dev/null; then
  split_docs "${WORK}/hw-https.yaml" "${WORK}/hwm-doc"
  if check_protocol_http "${WORK}/hwm-doc"; then
    bad "(8b) PROTOCOL invariant VACUOUS: it passed on a PROTOCOL:https mutant"
  else
    ok "(8b) PROTOCOL invariant bites: the staged https mutant FAILS check (5)"
  fi
else
  bad "(8b) https mutant unexpectedly failed to render (control not exercised)"
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

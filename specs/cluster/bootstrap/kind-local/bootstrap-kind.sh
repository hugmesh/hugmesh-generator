#!/bin/bash
# bootstrap-kind.sh — reusable LOCAL kind bring-up for a CURATED slice of the
# Snapdragon GitOps tree: Vault + Vault-PKI + Casdoor (+ its dedicated
# casdoor-pg Postgres) + Harbor (+ harbor-provision), and everything those
# transitively need (namespaces, local-path storage, ArgoCD itself, External
# Secrets Operator + its Vault ClusterSecretStore config, ingress-nginx
# (internal)). See README.md in this directory for the full scope rationale —
# in short: the root app-of-apps (specs/cluster/app-of-apps.yaml) syncs ALL 81
# Applications under specs/cluster/apps (the entire platform: GitLab,
# Cassandra, all 4 gateways, Matrix/Mastodon, games, media-poisoner, ...) and
# that is deliberately too much for a validation pass of just the identity/
# registry stack. This script applies ONLY the curated subset directly with
# kubectl (skipping the root app-of-apps step entirely).
#
# Idempotent: safe to re-run against the same cluster (skips cluster creation,
# reuses an already-initialized Vault, re-applies everything else via
# `kubectl apply`).
#
# Targets the CORE reference "snapdragon.systems" apps/ tree (specs/cluster/
# apps/*.yaml as committed on the GitOps repo), NOT a brand-templated tenant
# (templates/apps/*.hbs + brands/*.conf render OTHER tenant domains from these
# same core apps — this script intentionally does not touch that templating
# layer; it validates the reference cluster the templates are derived from).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"       # specs/cluster (this dir is specs/cluster/bootstrap/kind-local)
REPO_ROOT="$(cd "${CLUSTER_DIR}/../.." && pwd)"        # repo root (for `git show <branch>:<path>`)

CLUSTER_NAME="${KIND_CLUSTER_NAME:-snapdragon-local}"
ARGOCD_VERSION="${ARGOCD_VERSION:-stable}"
ARGOCD_NS="${ARGOCD_NS:-devops}"
REPO="${SNAPDRAGON_GITOPS_REPO:-https://github.com/Snapdragon-Systems/snapdragon-generator.git}"
REV="${SNAPDRAGON_GITOPS_REV:-main}"
# The Harbor migration (registry.snapdragon.systems cutover) is not yet merged
# to main (open draft PR, branch below). Its Application objects + the
# manifests they point at only exist on this branch today. Once that PR
# merges, set HARBOR_BRANCH=main (or just drop the override block below
# entirely — git-show against main will then return the same content the
# other Applications already read straight from $CLUSTER_DIR).
HARBOR_BRANCH="${HARBOR_BRANCH:-feat/harbor-registry-migration}"
# manifests/vault/deployment.yaml's vault-tls-init init container fix (the
# hashicorp/vault image has no openssl binary at all — see the comment on that
# container) lands on this same branch, alongside this bootstrap tooling, not
# yet on `main`. Same pattern as HARBOR_BRANCH above: once this branch merges,
# drop VAULT_BRANCH (or set it to `main`) and Vault is read straight from
# $REV like every other non-Harbor Application again.
VAULT_BRANCH="${VAULT_BRANCH:-feat/kind-local-bringup}"
SKIP_VAULT_BOOTSTRAP="${SKIP_VAULT_BOOTSTRAP:-0}"

log() { echo "==> $*"; }
warn() { echo "    WARN: $*" >&2; }

for bin in kind kubectl docker git jq; do
  command -v "${bin}" >/dev/null 2>&1 || { echo "missing required tool: ${bin}" >&2; exit 1; }
done

# ─────────────────────────────────────────────────────────────────────────
# 1) kind cluster (idempotent)
# ─────────────────────────────────────────────────────────────────────────
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  log "kind cluster '${CLUSTER_NAME}' already exists — reusing it"
else
  log "Creating kind cluster '${CLUSTER_NAME}'"
  kind create cluster --name "${CLUSTER_NAME}" --config "${SCRIPT_DIR}/kind-local.yaml"
fi
kind export kubeconfig --name "${CLUSTER_NAME}" >/dev/null
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

kubectl version >/dev/null 2>&1 || { echo "cluster not reachable after kind create/export" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────────
# 2) Label the single node with every capability the curated app subset
#    needs. Discovered by grepping the actual manifests (not guessed):
#      - snapdragon.systems/pki=true         (vault, vault-pki-init, casdoor +
#        casdoor-pg, harbor + harbor-provision — all pinned to the pki node)
#      - snapdragon.systems/local-path=true  (the local-path-provisioner
#        DaemonSet; every PVC above is carved from the snapdragon-local SC)
#    kubernetes.io/arch=amd64 is already correct on a kind/amd64 host. Nothing
#    in this curated subset needs snapdragon.systems/backend or a
#    snapdragon.systems/role=pki style label (checked — only the two above).
# ─────────────────────────────────────────────────────────────────────────
NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
log "Labeling node '${NODE}' (pki=true, local-path=true)"
kubectl label node "${NODE}" \
  snapdragon.systems/pki=true \
  snapdragon.systems/local-path=true \
  --overwrite >/dev/null

# ─────────────────────────────────────────────────────────────────────────
# 3) Namespaces (plain kubectl apply, not an Application)
# ─────────────────────────────────────────────────────────────────────────
log "Namespaces"
kubectl apply -f "${CLUSTER_DIR}/namespaces/namespaces.yaml"

# ─────────────────────────────────────────────────────────────────────────
# 4) Local storage. On kind this works AS-IS once the node carries
#    snapdragon.systems/local-path=true — the provisioner just mkdir -p's
#    /mnt/data/local-path + /mnt/usb/local-path INSIDE the kind node
#    container's own filesystem; no real block devices needed.
# ─────────────────────────────────────────────────────────────────────────
log "Local storage (snapdragon-local StorageClass)"
kubectl apply -k "${CLUSTER_DIR}/manifests/local-path"

# snapdragon-local sets itself as the cluster-default StorageClass
# (storageclass.kubernetes.io/is-default-class: "true"). kind's own built-in
# class ("standard") is ALSO marked default, and having two default
# StorageClasses makes any unqualified PVC (no storageClassName) ambiguous —
# the PVC admission controller errors instead of picking one. Resolve it by
# stripping the default annotation from kind's "standard" class rather than
# touching snapdragon-local (every real-cluster PVC in this repo already pins
# storageClassName: snapdragon-local explicitly, so this only affects
# hypothetical unqualified PVCs on this dev cluster).
if kubectl get storageclass standard >/dev/null 2>&1; then
  IS_DEFAULT="$(kubectl get storageclass standard -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null || true)"
  if [ "${IS_DEFAULT}" = "true" ]; then
    log "Removing default-class annotation from kind's built-in 'standard' StorageClass (avoid two defaults)"
    kubectl patch storageclass standard -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' >/dev/null
  fi
fi

# ─────────────────────────────────────────────────────────────────────────
# 5) ArgoCD — reuse bootstrap.sh's install + re-namespace + amd64-pin logic.
#    Deliberately do NOT apply bootstrap.sh's root app-of-apps step (that
#    pulls in all 81 Applications); we apply our curated subset directly
#    below instead.
# ─────────────────────────────────────────────────────────────────────────
log "Installing ArgoCD (${ARGOCD_VERSION}) into namespace '${ARGOCD_NS}'"
# --server-side (not plain `apply`): the upstream install.yaml's
# `applicationsets.argoproj.io` CRD has a schema large enough that the
# client-side kubectl.kubernetes.io/last-applied-configuration annotation
# kubectl apply would normally stamp on it overflows the 256KiB annotation
# value limit ("metadata.annotations: Too long"). Server-side apply doesn't
# use that annotation at all, so it doesn't hit the limit; --force-conflicts
# makes re-runs (idempotency) safe even if a previous run used plain apply.
curl -fsSL "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" \
  | sed "s/namespace: argocd/namespace: ${ARGOCD_NS}/g" \
  | kubectl apply -n "${ARGOCD_NS}" --server-side --force-conflicts -f -

log "Pinning ArgoCD components to kubernetes.io/arch=amd64 (matches the real x86_64-only ArgoCD host)"
PATCH='{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/arch":"amd64"}}}}}'
while read -r kind_ name; do
  [ -n "${name}" ] || continue
  kubectl -n "${ARGOCD_NS}" patch "${kind_}" "${name}" --type merge -p "${PATCH}" >/dev/null 2>&1 || true
done < <(kubectl -n "${ARGOCD_NS}" get deploy,statefulset -o jsonpath='{range .items[*]}{.kind}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null)

log "Waiting for ArgoCD to be ready"
kubectl -n "${ARGOCD_NS}" rollout status deploy/argocd-repo-server --timeout=300s
kubectl -n "${ARGOCD_NS}" rollout status deploy/argocd-applicationset-controller --timeout=180s || true

# ─────────────────────────────────────────────────────────────────────────
# 5b) Repo credentials. snapdragon-generator is a PRIVATE GitHub repo — every
#     git-path Application below (Vault, vault-pki, ESO config, Casdoor,
#     harbor-provision) fails to sync with "authentication required:
#     Repository not found" unless ArgoCD's repo-server has a credential for
#     it. The real cluster provisions this out-of-band (keys-provision); for
#     local dev there's no such side-channel, so this is STRICTLY OPT-IN:
#     this script never invokes `gh` (or anything else) to obtain a token on
#     its own — it only acts if the caller explicitly exports
#     ARGOCD_REPO_TOKEN. That keeps "run this script" from silently
#     materializing a live personal credential into cluster storage as a
#     side effect; the operator has to deliberately choose to hand one over.
#       export ARGOCD_REPO_TOKEN="$(GH_TOKEN= gh auth token)"   # e.g.
#     A fine-grained PAT with read-only access to just this repo is
#     preferable to a personal `gh` token for anything longer-lived than a
#     throwaway kind cluster.
# ─────────────────────────────────────────────────────────────────────────
if [ -n "${ARGOCD_REPO_TOKEN:-}" ]; then
  log "Registering ArgoCD repo credential for ${REPO} (from \$ARGOCD_REPO_TOKEN, never printed)"
  kubectl -n "${ARGOCD_NS}" create secret generic snapdragon-generator-repo \
    --from-literal=type=git \
    --from-literal=url="${REPO}" \
    --from-literal=username=x-access-token \
    --from-literal=password="${ARGOCD_REPO_TOKEN}" \
    --dry-run=client -o yaml \
    | kubectl label --local -f - "argocd.argoproj.io/secret-type=repository" --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null
else
  warn "\$ARGOCD_REPO_TOKEN not set — every git-path Application below will fail to sync against the private snapdragon-generator repo with 'authentication required'. Re-run with ARGOCD_REPO_TOKEN=<a token with read access to this repo> to fix (see README.md)."
fi

# ─────────────────────────────────────────────────────────────────────────
# 6) The curated Application subset — applied directly with kubectl, NOT via
#    the root app-of-apps. Cross-Application sync-wave ordering (the
#    argocd.argoproj.io/sync-wave annotations on individual Applications) is
#    only enforced by ArgoCD when Applications are children of a common
#    parent app-of-apps; applied standalone like this they sync independently
#    and concurrently. That's fine here: every hook Job below is
#    idempotent/retrying (backoffLimit, PostSync re-run on selfHeal), so the
#    curated set converges even without strict cross-app ordering — it just
#    may take a couple of reconcile loops.
#
#    Non-Harbor apps (Vault, vault-pki, ESO controller + config, Casdoor,
#    ingress-nginx-internal) exist on `main` unmodified — read straight from
#    this checkout so local edits/forks are picked up naturally, and repoint
#    repoURL/targetRevision at $REPO/$REV like bootstrap.sh's own app-of-apps
#    step does (so this also works against a fork).
#
#    Harbor's two Applications (03a-harbor.yaml, 03b-harbor-provision.yaml)
#    do not exist on main at all yet — fetched from $HARBOR_BRANCH via
#    `git show`. 03b's manifests (specs/cluster/manifests/harbor/*) ALSO only
#    exist on $HARBOR_BRANCH, so its targetRevision is overridden from `main`
#    to $HARBOR_BRANCH so ArgoCD's controller fetches the right content live.
#    03a sources a Helm chart (helm.goharbor.io), not a git path in this repo,
#    so it needs no such override — only fetching the Application object
#    itself from the branch that defines it.
# ─────────────────────────────────────────────────────────────────────────
apply_core_app() {
  local file="$1"
  log "Applying (main) specs/cluster/apps/${file}"
  sed -e "s#repoURL: https://github.com/Snapdragon-Systems/snapdragon-generator.git#repoURL: ${REPO}#" \
      -e "s#targetRevision: main#targetRevision: ${REV}#" \
      "${CLUSTER_DIR}/apps/${file}" | kubectl apply -f -
}

CORE_APPS=(
  06-vault-pki.yaml                # vault-pki-init PostSync hook Job
  03-external-secrets.yaml         # ESO controller + CRDs (Helm chart)
  04-external-secrets-config.yaml  # ClusterSecretStore "snapdragon-vault" + ExternalSecrets
  11-ingress-nginx-internal.yaml   # nginx-internal (LAN/VPN-only) — Harbor's Ingress uses this class
  05-casdoor.yaml                  # Casdoor + its dedicated casdoor-pg Postgres
)
for f in "${CORE_APPS[@]}"; do
  apply_core_app "${f}"
done

# Vault (02-vault.yaml) is fetched from $VAULT_BRANCH, not $REV, same reason
# and same mechanism as Harbor below: manifests/vault/deployment.yaml's
# vault-tls-init openssl fix only exists on that branch until it merges to
# main. The Application object itself is unchanged/identical on both
# branches — only its targetRevision needs the override so ArgoCD's
# controller fetches manifests/vault content from the branch with the fix.
git -C "${REPO_ROOT}" fetch -q origin "${VAULT_BRANCH}" 2>/dev/null || true
vault_ref() {
  if git -C "${REPO_ROOT}" rev-parse --verify -q "${VAULT_BRANCH}" >/dev/null; then
    echo "${VAULT_BRANCH}"
  else
    echo "origin/${VAULT_BRANCH}"
  fi
}
VREF="$(vault_ref)"
log "Applying (${VREF}) specs/cluster/apps/02-vault.yaml (targetRevision overridden: main -> ${VAULT_BRANCH}, picks up the vault-tls-init openssl fix)"
git -C "${REPO_ROOT}" show "${VREF}:specs/cluster/apps/02-vault.yaml" \
  | sed -e "s#targetRevision: main#targetRevision: ${VAULT_BRANCH}#" \
        -e "s#repoURL: https://github.com/Snapdragon-Systems/snapdragon-generator.git#repoURL: ${REPO}#" \
  | kubectl apply -f -

log "Fetching Harbor Applications from branch '${HARBOR_BRANCH}' (not yet merged to main)"
git -C "${REPO_ROOT}" fetch -q origin "${HARBOR_BRANCH}" 2>/dev/null || true
harbor_ref() {
  # Prefer a local ref if this checkout already has the branch; fall back to
  # origin/<branch>. Works whether HARBOR_BRANCH is a real branch or (once
  # the migration merges) just "main".
  if git -C "${REPO_ROOT}" rev-parse --verify -q "${HARBOR_BRANCH}" >/dev/null; then
    echo "${HARBOR_BRANCH}"
  else
    echo "origin/${HARBOR_BRANCH}"
  fi
}
HREF="$(harbor_ref)"

log "Applying (${HREF}) specs/cluster/apps/03a-harbor.yaml (Helm chart Application, no targetRevision override needed)"
git -C "${REPO_ROOT}" show "${HREF}:specs/cluster/apps/03a-harbor.yaml" | kubectl apply -f -

log "Applying (${HREF}) specs/cluster/apps/03b-harbor-provision.yaml (targetRevision overridden: main -> ${HARBOR_BRANCH})"
git -C "${REPO_ROOT}" show "${HREF}:specs/cluster/apps/03b-harbor-provision.yaml" \
  | sed -e "s#targetRevision: main#targetRevision: ${HARBOR_BRANCH}#" \
        -e "s#repoURL: https://github.com/Snapdragon-Systems/snapdragon-generator.git#repoURL: ${REPO}#" \
  | kubectl apply -f -

# Explicitly NOT applied (deliberately out of scope for this validation pass —
# see README.md): apps/00-cassandra.yaml, apps/03-gitlab.yaml, both gateway
# apps (20-gateway-*, 22-gateway-superadmin), Matrix (30-tuwunel), Mastodon
# (30-akkoma), games (50-games, 06-casdoor-games), media-poisoner, and every
# other Application under specs/cluster/apps not listed above.

# ─────────────────────────────────────────────────────────────────────────
# 7) Wait (best-effort) for the curated Applications to reach Synced/Healthy.
#    Not fatal on timeout — full end-to-end convergence (esp. Harbor, which
#    is missing its Vault-issued TLS secret until the migration branch's ESO
#    config also lands) is a separate validation pass; this just gives
#    visibility into how far things got.
# ─────────────────────────────────────────────────────────────────────────
APP_NAMES=(vault vault-pki external-secrets external-secrets-config ingress-nginx-internal casdoor harbor harbor-provision)
log "Waiting up to 5m for curated Applications to reach Synced/Healthy (best-effort)"
deadline=$((SECONDS + 300))
while [ "${SECONDS}" -lt "${deadline}" ]; do
  all_done=1
  for a in "${APP_NAMES[@]}"; do
    sync="$(kubectl -n "${ARGOCD_NS}" get application "${a}" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(kubectl -n "${ARGOCD_NS}" get application "${a}" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    [ "${sync}" = "Synced" ] && [ "${health}" = "Healthy" ] || all_done=0
  done
  [ "${all_done}" -eq 1 ] && break
  sleep 5
done
log "Application status:"
kubectl -n "${ARGOCD_NS}" get applications.argoproj.io "${APP_NAMES[@]}" \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>/dev/null || true

if [ "${SKIP_VAULT_BOOTSTRAP}" = "1" ]; then
  log "SKIP_VAULT_BOOTSTRAP=1 — skipping the Vault init/unseal/PKI sequence. Done."
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────
# 8) LOCAL-DEV-ONLY: Vault init + unseal + PKI bootstrap.
#
#    The real Vault (manifests/vault) is a persistent Raft StatefulSet, NOT
#    dev-mode and NOT auto-initialized — `vault operator init` is documented
#    as a one-time, by-hand OPERATOR step in keys-template/vault/README.md,
#    normally followed by writing the unseal key + root token to the offline
#    KEYS USB stick. There is no USB stick here, so this step replicates the
#    SAME manual sequence programmatically, generating FRESH key material
#    every time it runs against a cluster that isn't already initialized —
#    nothing is hardcoded, nothing is persisted outside this cluster's own
#    Secrets. This does NOT touch the real KEYS-USB provisioning flow; it is
#    local-dev-only plumbing to get PKI issuing roles usable for validation.
# ─────────────────────────────────────────────────────────────────────────
log "Waiting for vault-0 pod to be Running"
kubectl -n vault wait --for=condition=PodScheduled pod/vault-0 --timeout=180s >/dev/null 2>&1 || true
for i in $(seq 1 60); do
  phase="$(kubectl -n vault get pod vault-0 -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [ "${phase}" = "Running" ] && break
  sleep 5
done
if [ "${phase:-}" != "Running" ]; then
  warn "vault-0 never reached Running (phase='${phase:-unknown}') — skipping Vault init/unseal/PKI bootstrap. Re-run this script once it comes up."
  exit 0
fi

VEXEC=(kubectl -n vault exec vault-0 -c vault --)

STATUS_JSON="$("${VEXEC[@]}" vault status -format=json 2>/dev/null || true)"
INITIALIZED="$(printf '%s' "${STATUS_JSON}" | jq -r '.initialized // false' 2>/dev/null || echo false)"

if [ "${INITIALIZED}" = "true" ]; then
  log "Vault already initialized (idempotent re-run) — checking seal status only"
  SEALED="$(printf '%s' "${STATUS_JSON}" | jq -r '.sealed // true')"
  if [ "${SEALED}" = "true" ]; then
    if kubectl -n vault get secret vault-unseal >/dev/null 2>&1; then
      log "Vault sealed — resubmitting the unseal key from the existing vault-unseal Secret"
      KEY="$(kubectl -n vault get secret vault-unseal -o jsonpath='{.data.unseal-key}' | base64 -d)"
      "${VEXEC[@]}" vault operator unseal "${KEY}" >/dev/null
    else
      warn "Vault is sealed and initialized but no local vault-unseal Secret exists (state from a previous run/cluster) — unseal it by hand (see keys-template/vault/README.md)."
    fi
  else
    log "Vault already unsealed"
  fi
else
  log "Vault not initialized — running the one-time 'vault operator init -key-shares=1 -key-threshold=1' (LOCAL DEV ONLY: single Shamir share, no HA custody)"
  INIT_JSON="$("${VEXEC[@]}" vault operator init -key-shares=1 -key-threshold=1 -format=json)"
  UNSEAL_KEY="$(printf '%s' "${INIT_JSON}" | jq -r '.unseal_keys_b64[0]')"
  ROOT_TOKEN="$(printf '%s' "${INIT_JSON}" | jq -r '.root_token')"

  log "Unsealing Vault"
  "${VEXEC[@]}" vault operator unseal "${UNSEAL_KEY}" >/dev/null

  log "Seeding LOCAL-DEV Secrets (fresh key material, generated just now — never committed anywhere)"
  # vault-unseal (ns vault): the auto-unseal sidecar's key, so a pod restart
  # comes back unattended exactly like the real USB-KEYS-seeded flow.
  kubectl -n vault create secret generic vault-unseal \
    --from-literal=unseal-key="${UNSEAL_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # vault-bootstrap (ns vault): the token vault-pki-init's PostSync hook Job
  # reads (VAULT_TOKEN, optional:true).
  kubectl -n vault create secret generic vault-bootstrap \
    --from-literal=token="${ROOT_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # vault-token (ns external-secrets): the ClusterSecretStore "snapdragon-vault"
  # auth Secret, so ESO can actually reach Vault (KV + the PKI issue paths the
  # per-app mTLS ExternalSecrets use) instead of just having Vault up unused.
  kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n external-secrets create secret generic vault-token \
    --from-literal=token="${ROOT_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  echo
  echo "    LOCAL-DEV Vault root token (also stored in Secret vault/vault-bootstrap): ${ROOT_TOKEN}"
  echo "    LOCAL-DEV Vault unseal key (also stored in Secret vault/vault-unseal):    ${UNSEAL_KEY}"
  echo "    These are throwaway, freshly-generated for THIS kind cluster only — never reuse them anywhere real."
  echo
fi

# Re-run vault-pki-init now that the vault-bootstrap token exists. It's a
# PostSync ArgoCD hook Job (hook-delete-policy: BeforeHookCreation), so a
# plain re-apply of its manifests recreates+reruns it directly (bypassing the
# need to force an ArgoCD resync) — same content ArgoCD already owns/manages.
log "Re-running vault-pki-init (bootstraps pki_int + per-app issuing roles)"
kubectl -n vault delete job vault-pki-init --ignore-not-found >/dev/null
kubectl apply -k "${CLUSTER_DIR}/manifests/vault-pki" >/dev/null
kubectl -n vault wait --for=condition=complete job/vault-pki-init --timeout=180s \
  || warn "vault-pki-init did not complete within 180s — check 'kubectl -n vault logs job/vault-pki-init'"

log "Done. Cluster '${CLUSTER_NAME}' is left running for the next validation step."
echo "    kubeconfig context: kind-${CLUSTER_NAME}"
echo "    ArgoCD admin password: kubectl -n ${ARGOCD_NS} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo "    Tear down: kind delete cluster --name ${CLUSTER_NAME}"

#!/bin/bash
# bootstrap-kind.sh — reusable LOCAL kind bring-up for a CURATED slice of the
# HugMesh GitOps tree: Vault + Vault-PKI + Casdoor (+ its dedicated
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
# Idempotent: safe to re-run against the same cluster — skips cluster creation,
# keeps an existing cluster-ca Secret, reuses an already-initialized Vault, keeps
# an already-seeded Vault KV (seed-vault-kv.sh; see below), and re-applies
# everything else via `kubectl apply`.
#
# That KV clause is load-bearing, not decorative. Until it existed the "safe to
# re-run" claim was FALSE and destructive under KIND_PROFILE=sso: the KV step
# re-ran scripts/gen-cluster-secrets.sh, which mints every password
# unconditionally with `openssl rand` and overwrites Vault, while the Postgres
# instances kept the FIRST run's passwords (initdb only runs on an empty PGDATA).
# A second `make kind-up` therefore wedged the cluster it claimed to converge —
# `password authentication failed for user "userbff"`. KIND_KV_RESEED=1 is the
# deliberate, destructive re-mint (fresh cluster / wiped PVCs only).
#
# Targets the CORE reference "hugmesh.systems" apps/ tree (specs/cluster/
# apps/*.yaml as committed on the GitOps repo), NOT a brand-templated tenant
# (templates/apps/*.hbs + brands/*.conf render OTHER tenant domains from these
# same core apps — this script intentionally does not touch that templating
# layer; it validates the reference cluster the templates are derived from).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"       # specs/cluster (this dir is specs/cluster/bootstrap/kind-local)
REPO_ROOT="$(cd "${CLUSTER_DIR}/../.." && pwd)"        # repo root (for `git show <branch>:<path>`)

CLUSTER_NAME="${KIND_CLUSTER_NAME:-hugmesh-local}"
ARGOCD_VERSION="${ARGOCD_VERSION:-stable}"
ARGOCD_NS="${ARGOCD_NS:-devops}"
REPO="${HUGMESH_GITOPS_REPO:-https://github.com/hugmesh/hugmesh-generator.git}"
REV="${HUGMESH_GITOPS_REV:-main}"
# Both former branch overrides (the Harbor migration and the vault-tls-init
# openssl fix) have since MERGED to main — apps/03a+03b and the fixed
# manifests/vault/deployment.yaml are read straight from $REV like everything
# else. The override machinery below is kept so a future not-yet-merged
# Application can be validated the same way, but the defaults are now main.
HARBOR_BRANCH="${HARBOR_BRANCH:-main}"
VAULT_BRANCH="${VAULT_BRANCH:-main}"
SKIP_VAULT_BOOTSTRAP="${SKIP_VAULT_BOOTSTRAP:-0}"
# KIND_PROFILE=core (default) brings up the original curated identity/registry
# slice. KIND_PROFILE=sso ADDITIONALLY brings up the native-login path — the
# fe-gateway + admin/user BFFs (+ their Postgres), route-access seed, Cassandra,
# the Angular host shell and the login/social UI remotes — then seeds Vault KV
# (gen-cluster-secrets.sh ONLINE mode through an exec shim into vault-0) and the
# deterministic e2e identity catalogue (tests/qemu/seed-accounts.sh --roles), so
# tests/e2e/specs/27-native-login.spec.ts can run against this cluster from the
# host (`make kind-e2e` at the repo root drives the whole flow). First-party
# images are NOT pulled from Harbor here — `make kind-images` builds them from
# the sibling repos and `kind load`s them under the exact rendered refs.
KIND_PROFILE="${KIND_PROFILE:-core}"
case "${KIND_PROFILE}" in core|sso) ;; *) echo "KIND_PROFILE must be 'core' or 'sso' (got '${KIND_PROFILE}')" >&2; exit 1 ;; esac

log() { echo "==> $*"; }
# Recreate a completed/failed Job. `kubectl delete job` BLOCKS on the pod's
# grace period, and a Job pod wedged in Terminating never releases it — observed
# hanging 30+ minutes on a clean bring-up, after which the hard wait below can
# never pass because the Job it waits for was never recreated. Force the
# deletion, do not wait on it, and then block until the object is genuinely gone
# so the re-apply cannot race a still-terminating predecessor.
recreate_job() { # <namespace> <job> <kustomize-dir>
  local ns="$1" job="$2" dir="$3" i
  kubectl -n "${ns}" delete job "${job}" --ignore-not-found --force --grace-period=0 --wait=false >/dev/null 2>&1 || true
  kubectl -n "${ns}" delete pods -l "job-name=${job}" --ignore-not-found --force --grace-period=0 --wait=false >/dev/null 2>&1 || true
  for i in $(seq 1 60); do
    kubectl -n "${ns}" get job "${job}" >/dev/null 2>&1 || break
    sleep 2
  done
  kubectl apply -k "${dir}" >/dev/null
}


warn() { echo "    WARN: $*" >&2; }

# openssl is not optional: step 3b mints the local-dev CA with it, and the mTLS
# post-condition at the end verifies an issued certificate with it. It used to be
# an undeclared dependency discovered halfway through a bring-up.
for bin in kind kubectl docker git jq openssl base64; do
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
#        DaemonSet; every PVC above is carved from the hugmesh-local SC)
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
if [ "${KIND_PROFILE}" = "sso" ]; then
  # The SSO slice adds workloads pinned to the backend tier (BFFs, their
  # Postgres) and the frontend tier (host shell, login/social UI remotes) —
  # same single-node collapse as pki/local-path above. Cassandra is the one
  # workload in the slice that pins the ROLE-shaped label
  # (snapdragon.systems/role: pki), not a capability=true label — the core
  # profile's "nothing needs role=pki" note holds only for the core subset.
  log "Labeling node '${NODE}' (backend=true, frontend=true, role=pki — KIND_PROFILE=sso)"
  kubectl label node "${NODE}" \
    snapdragon.systems/backend=true \
    snapdragon.systems/frontend=true \
    snapdragon.systems/role=pki \
    --overwrite >/dev/null
fi

# ─────────────────────────────────────────────────────────────────────────
# 3) Namespaces (plain kubectl apply, not an Application)
# ─────────────────────────────────────────────────────────────────────────
log "Namespaces"
kubectl apply -f "${CLUSTER_DIR}/namespaces/namespaces.yaml"

# ─────────────────────────────────────────────────────────────────────────
# 3b) LOCAL-DEV cluster CA. On a real node the `cluster-ca` Secret is
#     provisioned OFFLINE by keys-provision from the KEYS USB
#     (certs/cluster-ca.*); every consumer mounts it optional:true so pods
#     START without it — and then vault-pki-init spins forever ("Error
#     loading CA File: /ca/tls.crt") because its VAULT_CACERT never appears,
#     while vault-tls-init has already fallen back to a self-signed listener
#     cert the missing CA could never verify anyway. There is no USB here:
#     mint a throwaway CA (fresh key material per cluster, like the Vault
#     init below) and create the Secret in every consuming namespace BEFORE
#     the apps sync, so vault-tls-init signs its listener cert from it and
#     the pki-init chain is self-consistent.
# ─────────────────────────────────────────────────────────────────────────
if ! kubectl -n vault get secret cluster-ca >/dev/null 2>&1; then
  log "Minting LOCAL-DEV cluster CA (throwaway, this cluster only) + cluster-ca Secrets"
  CA_DIR="$(mktemp -d)"
  openssl req -x509 -newkey rsa:4096 -nodes -days 825 -sha384 \
    -subj "/CN=hugmesh kind local dev CA" \
    -keyout "${CA_DIR}/tls.key" -out "${CA_DIR}/tls.crt" >/dev/null 2>&1
  for ns in vault hugmesh-pki hugmesh-backend hugmesh-frontend external-secrets devops; do
    kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl -n "${ns}" create secret tls cluster-ca \
      --cert="${CA_DIR}/tls.crt" --key="${CA_DIR}/tls.key" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  done
  rm -rf "${CA_DIR}"
else
  log "cluster-ca Secret already present — keeping it (idempotent re-run)"
fi

# ─────────────────────────────────────────────────────────────────────────
# 4) Local storage. On kind this works AS-IS once the node carries
#    snapdragon.systems/local-path=true — the provisioner just mkdir -p's
#    /mnt/data/local-path + /mnt/usb/local-path INSIDE the kind node
#    container's own filesystem; no real block devices needed.
# ─────────────────────────────────────────────────────────────────────────
log "Local storage (hugmesh-local StorageClass)"
kubectl apply -k "${CLUSTER_DIR}/manifests/local-path"

# hugmesh-local sets itself as the cluster-default StorageClass
# (storageclass.kubernetes.io/is-default-class: "true"). kind's own built-in
# class ("standard") is ALSO marked default, and having two default
# StorageClasses makes any unqualified PVC (no storageClassName) ambiguous —
# the PVC admission controller errors instead of picking one. Resolve it by
# stripping the default annotation from kind's "standard" class rather than
# touching hugmesh-local (every real-cluster PVC in this repo already pins
# storageClassName: hugmesh-local explicitly, so this only affects
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
# 5b) Repo credentials. hugmesh-generator is a PRIVATE GitHub repo — every
#     git-path Application below (Vault, vault-pki, ESO config, Casdoor,
#     harbor-provision) fails to sync with "authentication required:
#     Repository not found" unless ArgoCD's repo-server has a credential for
#     it. The real cluster registers this same credential on its OWN bootstrap
#     path (../bootstrap.sh), with the token sourced out-of-band from the
#     offline KEYS USB (KEYS/gitops/repo-token) by keys-provision, which exports
#     it as ARGOCD_REPO_TOKEN — keys-provision does NOT materialize the Secret
#     itself. For local dev there's no such side-channel, so this is STRICTLY
#     OPT-IN:
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
  kubectl -n "${ARGOCD_NS}" create secret generic hugmesh-generator-repo \
    --from-literal=type=git \
    --from-literal=url="${REPO}" \
    --from-literal=username=x-access-token \
    --from-literal=password="${ARGOCD_REPO_TOKEN}" \
    --dry-run=client -o yaml \
    | kubectl label --local -f - "argocd.argoproj.io/secret-type=repository" --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null
else
  warn "\$ARGOCD_REPO_TOKEN not set — every git-path Application below will fail to sync against the private hugmesh-generator repo with 'authentication required'. Re-run with ARGOCD_REPO_TOKEN=<a token with read access to this repo> to fix (see README.md)."
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
  sed -e "s#repoURL: https://github.com/hugmesh/hugmesh-generator.git#repoURL: ${REPO}#" \
      -e "s#targetRevision: main#targetRevision: ${REV}#" \
      "${CLUSTER_DIR}/apps/${file}" | kubectl apply -f -
}

CORE_APPS=(
  06-vault-pki.yaml                # vault-pki-init PostSync hook Job
  03-external-secrets.yaml         # ESO controller + CRDs (Helm chart)
  04-external-secrets-config.yaml  # ClusterSecretStore "hugmesh-vault" + ExternalSecrets
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
        -e "s#repoURL: https://github.com/hugmesh/hugmesh-generator.git#repoURL: ${REPO}#" \
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
        -e "s#repoURL: https://github.com/hugmesh/hugmesh-generator.git#repoURL: ${REPO}#" \
  | kubectl apply -f -

# Explicitly NOT applied under KIND_PROFILE=core (deliberately out of scope
# for the identity/registry validation pass — see README.md): apps/
# 00-cassandra.yaml, apps/03-gitlab.yaml, the gateway apps, Matrix
# (30-tuwunel), Mastodon (30-akkoma), games (50-games, 06-casdoor-games),
# media-poisoner, and every other Application under specs/cluster/apps not
# listed above.

# ─────────────────────────────────────────────────────────────────────────
# 6b) KIND_PROFILE=sso — the native-login slice on top of the core. Everything
#     tests/e2e/specs/27-native-login.spec.ts touches: the fe-gateway front
#     door (chart Ingress), the route-access seed DB (permitAll /bff/login
#     row), admin-bff (bff_ session custody + /bff/internal back-channel) +
#     user-bff (the /bff/login relocation) with their Postgres, Cassandra
#     (gateway revocation list / URL registry), the Angular host shell and the
#     login/social UI remotes. First-party images must ALREADY be loaded into
#     the kind node under their rendered refs (`make kind-images`) — nothing
#     here can pull them from the in-cluster Harbor.
# ─────────────────────────────────────────────────────────────────────────
SSO_APPS=(
  00-cassandra.yaml       # gateway backing store (the Bitnami Helm CHART only)
  # 00b-cassandra-init.yaml is NOT optional and NOT a nicety. apps/00-cassandra.yaml
  # installs the Bitnami chart, which ships PasswordAuthenticator ON and with no
  # application keyspaces and no roles but the `cassandra` superuser. The keyspace
  # + least-privilege-role bootstrap lives in a SEPARATE Application because a Helm
  # -sourced Application has no `path:` for extra git-managed manifests.
  #
  # Omitting it here deployed a Cassandra that no gateway could ever authenticate
  # against. Observed live: `DESC KEYSPACES` returned system keyspaces only and
  # `LIST ROLES` returned exactly one row (`cassandra`), so fe-gateway crash-looped
  # on `Provided username fe_gw_cass and/or password are incorrect` — which reads
  # like a rotated-password problem and is really a role that was never created.
  # apps/00b-cassandra-init.yaml says so itself: "until this Job runs there is no
  # combination of settings under which a gateway can start".
  00b-cassandra-init.yaml # keyspaces + per-app roles + grants (sync-wave 1)
  06-route-access-db.yaml # gateway_route_access seed incl. permitAll /bff/login
  20-gateway-fe.yaml      # fe-gateway chart (front door + Ingress)
  30-admin-bff-db.yaml
  31-admin-bff-api.yaml   # session custody + internal-token back-channel
  34-user-bff-db.yaml
  37-user-bff-api.yaml    # POST /bff/login (native-login relocation)
  40-frontend.yaml        # Angular host shell (snapdragon-systems-web)
  45-social-ui.yaml       # login-ui remote (+ matrix/mastodon/admin remotes)
)
if [ "${KIND_PROFILE}" = "sso" ]; then
  for f in "${SSO_APPS[@]}"; do
    apply_core_app "${f}"
  done
  # The fe-gateway chart's Ingress ships className "nginx" (the real cluster's
  # public controller). kind runs ONLY ingress-nginx-internal, which registers
  # class "nginx-internal" — without this override the Ingress is admitted by
  # nothing and the host ports mapped by kind-local.yaml never route. A helm
  # parameter (not a values edit) so the committed chart stays untouched.
  log "Overriding fe-gateway ingress.className -> nginx-internal (kind has no public controller)"
  kubectl -n "${ARGOCD_NS}" patch application hugmesh-gateway-fe --type merge -p \
    '{"spec":{"source":{"helm":{"parameters":[{"name":"ingress.className","value":"nginx-internal"}]}}}}' >/dev/null
fi

# ─────────────────────────────────────────────────────────────────────────
# 7) Wait (best-effort) for the curated Applications to reach Synced/Healthy.
#    Not fatal on timeout — full end-to-end convergence (esp. Harbor, which
#    is missing its Vault-issued TLS secret until the migration branch's ESO
#    config also lands) is a separate validation pass; this just gives
#    visibility into how far things got.
# ─────────────────────────────────────────────────────────────────────────
APP_NAMES=(vault vault-pki external-secrets external-secrets-config ingress-nginx-internal casdoor harbor harbor-provision)
if [ "${KIND_PROFILE}" = "sso" ]; then
  # cassandra-init belongs here, not just in SSO_APPS. It is what actually makes
  # Cassandra usable (keyspaces + per-app roles + grants); the `cassandra` entry
  # above only covers the Bitnami chart. Omitting it from the wait list meant the
  # bring-up neither waited for the bootstrap Job nor listed it in the closing
  # status table — so a Cassandra with no roles looked, from the bootstrap's own
  # output, exactly like a healthy one, and the failure surfaced much later as an
  # unrelated-looking gateway auth error.
  APP_NAMES+=(cassandra cassandra-init route-access-db hugmesh-gateway-fe admin-bff-db admin-bff-api user-bff-db user-bff-api snapdragon-systems-web hugmesh-social-ui)
fi
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
  if [ "${KIND_PROFILE}" = "sso" ]; then
    echo "KIND_PROFILE=sso needs the Vault bootstrap (KV seeding feeds every ESO Secret the login path reads) — unset SKIP_VAULT_BOOTSTRAP" >&2
    exit 1
  fi
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
  # eso-provider-refs: conditional-ok a root token exists exactly once, at `vault operator init`, and cannot be re-derived afterwards. Whoever initialized this Vault wrote it here (this branch, or the KEYS custody on the real-node path), so on the already-initialized branch it is a precondition rather than something to create. If it is genuinely gone the root token is gone with it, and the read-back at the KV seed below stops the run with that exact message instead of guessing.
  kubectl -n vault create secret generic vault-bootstrap \
    --from-literal=token="${ROOT_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # vault-token (ns external-secrets): the ClusterSecretStore "hugmesh-vault"
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

# ─────────────────────────────────────────────────────────────────────────
# 8b) PER-NAMESPACE GENERATOR CREDENTIALS (vault-ca + vault-token).
#
#     The 29 VaultDynamicSecret generators in specs/cluster/manifests (23 in
#     hugmesh-backend, 5 in hugmesh-pki, 1 in hugmesh-frontend) are what mint
#     EVERY mTLS identity in the mesh. Each one declares
#
#         provider:
#           caProvider: { type: Secret, name: vault-ca, key: ca.crt }
#           auth: { tokenSecretRef: { name: vault-token, key: token } }
#
#     BOTH of those resolve in the GENERATOR'S OWN NAMESPACE and nowhere else.
#     ESO passes resolvers.EmptyStoreKind for generators, and
#     pkg/utils/resolvers/secret_ref.go only honours a cross-namespace
#     ref.Namespace when storeKind == ClusterSecretStoreKind — the constant is
#     documented upstream as "not cluster-scoped, hence resources cannot be
#     resolved across namespaces". So the ClusterSecretStore's own
#     external-secrets/vault-token does NOT serve them, and there is no way to
#     point them at one central copy: the Secrets must exist per namespace.
#
#     Neither existed. This bootstrap minted cluster-ca (below, step 3b) and one
#     external-secrets/vault-token (above) and stopped there, so all 26
#     generator-backed ExternalSecrets sat in SecretSyncedError with
#     `cannot get Kubernetes secret "vault-ca": secrets "vault-ca" not found`,
#     no *-mtls Secret was ever created, and every pod mounting one (both
#     gateways, every BFF, the DB TLS sidecars, harbor, coturn) hung in Init:0/1
#     on `MountVolume.SetUp failed for volume "pki"`. Not one certificate had
#     ever been issued in a kind cluster.
#
#     The offline/real-node path (specs/etc/keys-provision/provision.sh) already
#     seeds both into exactly these namespaces from the USB KEYS stick; only the
#     kind path was missing them. This block closes that gap so the two delivery
#     paths agree.
#
#     vault-ca carries ONLY the PUBLIC CA certificate (cluster-ca's tls.crt
#     republished under the key name `ca.crt` that caProvider asks for). Nothing
#     here is committed to git — both values are read back from the live cluster,
#     so this is correct whether the CA was minted by step 3b or provisioned
#     offline. Derived, not hardcoded: a checked-in certificate would be wrong
#     for every freshly bootstrapped cluster, which fails TLS verification
#     instead — the same outage wearing a different error message.
#
#     On the PRIVATE key: this block does not move it, and does not need to —
#     caProvider only ever wants the public cert. That is a property of THIS
#     block and not of the cluster, and it would be false to claim more: step 3b
#     above deliberately creates the FULL `cluster-ca` kubernetes.io/tls Secret
#     (tls.crt AND tls.key) in six namespaces — vault, hugmesh-pki,
#     hugmesh-backend, hugmesh-frontend, external-secrets, devops — because
#     vault-pki-init imports the CA key into Vault's pki_int and vault-tls-init
#     signs the listener cert with it. That is a throwaway local-dev CA whose key
#     material is generated fresh per cluster and never leaves it, but "the CA
#     private key stays in the vault namespace" is simply not true here, and a
#     design rationale resting on it would be resting on nothing.
# ─────────────────────────────────────────────────────────────────────────
log "Seeding per-namespace generator credentials (vault-ca + vault-token)"

GEN_NAMESPACES="hugmesh-pki hugmesh-backend hugmesh-frontend"

# The CA that actually signs Vault's listener cert. vault-tls-init copies this
# very file to /vault/tls/ca.crt when it signs, so trusting it is trusting the
# real chain rather than an assumption about one.
GEN_CA_CRT="$(kubectl -n vault get secret cluster-ca -o jsonpath='{.data.tls\.crt}' 2>/dev/null || true)"
# The token the generators authenticate to Vault with — the same one the
# ClusterSecretStore already uses.
GEN_TOKEN="$(kubectl -n external-secrets get secret vault-token -o jsonpath='{.data.token}' 2>/dev/null || true)"

if [ -z "${GEN_CA_CRT}" ]; then
  echo "vault/cluster-ca has no tls.crt — the mTLS generators cannot verify Vault's TLS and no certificate would ever be issued. Refusing to continue with a half-provisioned PKI." >&2
  exit 1
fi

# FALLBACK, not an abort. external-secrets/vault-token is created in exactly ONE
# place — the not-initialized `else` branch of step 8 above — so a run against an
# ALREADY-INITIALIZED Vault never creates it. The first cut of this block simply
# `exit 1`-ed there, which killed the whole bring-up (vault-pki-init, casdoor-init
# and the entire SSO slice, all of which follow) over a Secret the script is
# perfectly able to reconstruct: vault/vault-bootstrap holds the SAME root token
# and this script already reads it 60 lines below to seed Vault KV. Verified on
# kind-hugmesh-local: vault/vault-bootstrap.token, external-secrets/vault-token
# .token and hugmesh-backend/vault-token.token are byte-identical.
#
# The recovery is deliberately FLAT — read, fail hard on the spot if there is
# genuinely no token anywhere, then create — rather than nesting the create
# inside a second `if [ -n … ]`. Nested, the only statement that creates
# external-secrets/vault-token would still sit two branches deep and
# tests/scripts/eso_provider_refs.py would still, correctly, report that nothing
# creates it on the default path.
if [ -z "${GEN_TOKEN}" ]; then
  GEN_TOKEN="$(kubectl -n vault get secret vault-bootstrap -o jsonpath='{.data.token}' 2>/dev/null || true)"
  [ -n "${GEN_TOKEN}" ] || { echo "neither external-secrets/vault-token nor vault/vault-bootstrap carries a Vault token — the mTLS generators cannot authenticate to Vault and nothing below can seed KV either. This means no run has ever initialized this Vault (or its Secrets were deleted): tear the cluster down and re-bootstrap, or restore vault/vault-bootstrap from the KEYS custody." >&2; exit 1; }
  log "  external-secrets/vault-token absent (Vault was already initialized, so the branch that creates it did not run) — recovering the same root token from vault/vault-bootstrap"
  # Backfill it too. Without it the ClusterSecretStore "hugmesh-vault" cannot
  # authenticate either, so every KV-backed ExternalSecret is as dead as the
  # generators were — the same outage one layer over.
  kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: vault-token
  namespace: external-secrets
type: Opaque
data:
  token: ${GEN_TOKEN}
EOF
  log "  external-secrets/vault-token restored for the ClusterSecretStore"
fi

for ns in ${GEN_NAMESPACES}; do
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # Built as literal Secret manifests so the base64 values move across without
  # ever being written to disk or echoed to the log.
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: vault-ca
  namespace: ${ns}
type: Opaque
data:
  ca.crt: ${GEN_CA_CRT}
---
apiVersion: v1
kind: Secret
metadata:
  name: vault-token
  namespace: ${ns}
type: Opaque
data:
  token: ${GEN_TOKEN}
EOF
  log "  ${ns}: vault-ca (public CA cert) + vault-token ready"
done
unset GEN_TOKEN

# Re-run vault-pki-init now that the vault-bootstrap token exists. It's a
# PostSync ArgoCD hook Job (hook-delete-policy: BeforeHookCreation), so a
# plain re-apply of its manifests recreates+reruns it directly (bypassing the
# need to force an ArgoCD resync) — same content ArgoCD already owns/manages.
log "Re-running vault-pki-init (bootstraps pki_int + per-app issuing roles)"
recreate_job vault vault-pki-init "${CLUSTER_DIR}/manifests/vault-pki"
kubectl -n vault wait --for=condition=complete job/vault-pki-init --timeout=180s \
  || warn "vault-pki-init did not complete within 180s — check 'kubectl -n vault logs job/vault-pki-init'"

if [ "${KIND_PROFILE}" = "sso" ]; then
  # ───────────────────────────────────────────────────────────────────────
  # 9) Vault KV seeding (SSO profile). Every Secret the login path consumes
  #    (casdoor admin/db creds, the per-app client secrets — casdoor-init and
  #    user-bff read the SAME hugmesh/casdoor-apps path, so one write aligns
  #    both sides — the BFF DB creds, the AES custody key, the internal
  #    back-channel token) is ESO-materialized from Vault KV. scripts/
  #    gen-cluster-secrets.sh already writes exactly these paths in its ONLINE
  #    mode; the only kind-specific part is reaching Vault: no host `vault`
  #    CLI or cert plumbing needed — a PATH shim execs the CLI already inside
  #    vault-0 (VAULT_SKIP_VERIFY because the in-pod loopback hostname is not
  #    a SAN on the vault-tls-init cert; the token never leaves kubectl exec).
  # ───────────────────────────────────────────────────────────────────────
  # HARD gate on vault-pki-init: the KV seed below is useless until Vault is
  # reachable over the cluster-ca chain, and 403s taught us the soft 180s
  # warn above is not enough — a still-running pki-init means the engine
  # setup (and any policy work) hasn't happened yet.
  log "Waiting (hard) for vault-pki-init before seeding KV"
  kubectl -n vault wait --for=condition=complete job/vault-pki-init --timeout=600s \
    || { echo "vault-pki-init never completed — cannot seed KV (kubectl -n vault logs job/vault-pki-init)" >&2; exit 1; }

  log "Seeding Vault KV for the SSO slice (seed-vault-kv.sh -> gen-cluster-secrets.sh ONLINE via vault-0 exec shim)"
  ROOT_TOKEN="$(kubectl -n vault get secret vault-bootstrap -o jsonpath='{.data.token}' | base64 -d)"
  [ -n "${ROOT_TOKEN}" ] || { echo "vault-bootstrap Secret missing/empty — cannot seed KV" >&2; exit 1; }
  # KV v2 at mount "secret" is a FIXED contract (keys-template/vault/README.md:
  # the ESO ClusterSecretStore reads provider vault, KV v2, mount `secret`) —
  # but NOTHING in-tree mounts it; on a real cluster that is part of the
  # by-hand `vault operator init` sequence. Mount it here, idempotently.
  if ! kubectl -n vault exec vault-0 -c vault -- env \
        VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true VAULT_TOKEN="${ROOT_TOKEN}" \
        vault secrets list -format=json 2>/dev/null | jq -e '."secret/"' >/dev/null; then
    log "Mounting KV v2 at secret/ (the ESO ClusterSecretStore's fixed contract)"
    kubectl -n vault exec vault-0 -c vault -- env \
      VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true VAULT_TOKEN="${ROOT_TOKEN}" \
      vault secrets enable -path=secret -version=2 kv
  fi
  SHIM_DIR="$(mktemp -d)"
  cat > "${SHIM_DIR}/vault" <<'SHIM'
#!/bin/bash
exec kubectl -n vault exec -i vault-0 -c vault -- env \
  VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
  VAULT_TOKEN="${VAULT_TOKEN}" vault "$@"
SHIM
  chmod +x "${SHIM_DIR}/vault"
  # VAULT_ADDR only gates the script's online mode — the shim always talks to
  # the in-pod loopback listener regardless of its value.
  #
  # NOT gen-cluster-secrets.sh directly: it mints EVERY password unconditionally
  # (`openssl rand` + `vault kv put`), so a second run rotates credentials that
  # the already-initialized Postgres volumes will never re-read (initdb only runs
  # on an empty PGDATA) and the BFFs come back with
  # `password authentication failed for user "userbff"`. seed-vault-kv.sh adds
  # the already-done guard its neighbours here (cluster-CA, Vault init, KV mount)
  # all have; KIND_KV_RESEED=1 is the deliberate, destructive override.
  PATH="${SHIM_DIR}:${PATH}" VAULT_ADDR="https://in-cluster-via-exec-shim" VAULT_TOKEN="${ROOT_TOKEN}" \
    REPO_ROOT="${REPO_ROOT}" BRAND="${BRAND:-hugmesh}" \
    bash "${SCRIPT_DIR}/seed-vault-kv.sh" --out "${SHIM_DIR}/bundle"
  rm -rf "${SHIM_DIR}"

  # ───────────────────────────────────────────────────────────────────────
  # 10) Wait for the casdoor-init seed Job (same gate the in-cluster
  #     test-runner orchestrator enforces), then seed the deterministic e2e
  #     identity catalogue against the live Casdoor: seed-accounts.sh --roles
  #     renders apply-systems-roles.sh (idempotent add-user/update-role over
  #     the Casdoor API) — run it through a short-lived port-forward.
  #     casdoor-init may have already run and failed before the KV seed above
  #     landed its Secrets — retrigger it once, same recreate idiom as
  #     vault-pki-init.
  # ───────────────────────────────────────────────────────────────────────
  log "Re-running casdoor-init now that Vault KV + ESO secrets exist"
  recreate_job hugmesh-pki casdoor-init "${CLUSTER_DIR}/manifests/casdoor"
  kubectl -n hugmesh-pki wait --for=condition=complete job/casdoor-init --timeout=600s \
    || { warn "casdoor-init did not complete — 'kubectl -n hugmesh-pki logs job/casdoor-init'"; exit 1; }

  log "Seeding e2e identities (seed-accounts.sh --roles) against the kind Casdoor"
  SEED_DIR="$(mktemp -d)"
  # THE EXTRAS ARE NOT OPTIONAL. seed-accounts.sh's built-in catalogue covers the
  # base role matrix only; the personas specs 13/15/17/29 and the ad-hoc UI suite
  # sign in as (e2e-fleet, e2e-superadmin, e2e-banned, the @gmail.com handles,
  # dragoneer, rbac-*) live in tests/e2e-extra-personas.sh. The compose lane had
  # always applied them and this lane never had, so a fully working cluster still
  # answered spec 29 with "native login e2e-fleet -> 401" — a persona that had
  # simply never been created, reading exactly like a broken login.
  # shellcheck source=../../../../tests/e2e-extra-personas.sh
  . "${REPO_ROOT}/tests/e2e-extra-personas.sh"
  EXTRA_ROLE_USERS="${E2E_EXTRA_PERSONAS}" \
    bash "${REPO_ROOT}/tests/qemu/seed-accounts.sh" --roles "${SEED_DIR}"
  kubectl -n hugmesh-pki port-forward svc/casdoor 18000:8000 >/dev/null 2>&1 &
  PF_PID=$!
  trap 'kill "${PF_PID}" 2>/dev/null || true' EXIT
  for i in $(seq 1 20); do
    curl -sf http://127.0.0.1:18000/api/health >/dev/null 2>&1 && break
    sleep 2
  done
  # apply-systems-roles.sh logs in as the Casdoor built-in admin. That password
  # is NOT a fixed dev constant — gen-cluster-secrets.sh generated it into
  # secret/<brand>/casdoor during the KV seed above (property
  # admin_password_plain; the sibling admin_password is the hashed form Casdoor
  # stores). Read it back from Vault rather than re-deriving it, so the seed
  # always uses the password this cluster actually has.
  CASDOOR_ADMIN_PASS="$(kubectl -n vault exec vault-0 -c vault -- env \
      VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true VAULT_TOKEN="${ROOT_TOKEN}" \
      vault kv get -field=admin_password_plain "secret/${BRAND:-hugmesh}/casdoor" 2>/dev/null)"
  [ -n "${CASDOOR_ADMIN_PASS}" ] || { echo "could not read the Casdoor admin password from Vault — cannot seed identities" >&2; exit 1; }
  # apply-systems-roles.sh checks every Casdoor response ENVELOPE (.status), not
  # just the HTTP code — Casdoor answers a DENIED call with HTTP 200 +
  # {"status":"error"}, so the previous `curl -sf` hook could (and did) run the
  # entire seed unauthenticated and still exit 0. A WRONG admin password is the
  # documented fresh-cluster state, so this must fail loudly rather than
  # "succeed" against nothing.
  CASDOOR_URL="http://127.0.0.1:18000" CASDOOR_ADMIN_PASS="${CASDOOR_ADMIN_PASS}" \
    bash "${SEED_DIR}/roles/apply-systems-roles.sh"
  # POSITIVE POST-CONDITION: re-authenticate from scratch and read the catalogue
  # back. The hook reporting on its own work is not evidence; this is. Without
  # it the bootstrap can print "SSO slice seeded." over an empty Casdoor.
  log "Verifying the identity seed actually landed (independent read-back)"
  CASDOOR_URL="http://127.0.0.1:18000" CASDOOR_ADMIN_PASS="${CASDOOR_ADMIN_PASS}" \
    bash "${SCRIPT_DIR}/verify-seeded-identities.sh" "${SEED_DIR}/roles"
  kill "${PF_PID}" 2>/dev/null || true
  trap - EXIT
  # test-seed-passwords: the same deterministic-password Secret the in-cluster
  # test Jobs envFrom (optional). Host-side playwright reads the E2E_* env
  # directly, but create it anyway so a later in-cluster runner finds it.
  kubectl -n hugmesh-frontend create secret generic test-seed-passwords \
    --from-literal=E2E_PASSWORD="${E2E_PASSWORD:-e2e-pass}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  rm -rf "${SEED_DIR}"

  echo
  # Reached only after apply-systems-roles.sh AND verify-seeded-identities.sh
  # both succeeded, so this line is a claim the script has evidence for.
  log "SSO slice seeded (identity catalogue read back and verified). Host entry: https://hugmesh.systems via 127.0.0.1:8443 (kind-local.yaml port map)"
  echo "    e2e:  make kind-e2e   (repo root — resolver-maps hugmesh.systems -> 127.0.0.1, runs spec 27)"
fi

# ─────────────────────────────────────────────────────────────────────────
# 12) POSITIVE POST-CONDITION FOR mTLS ISSUANCE.
#
#     Step 8b seeds vault-ca and vault-token and then says "ready". That is the
#     hook reporting on its own work. It is not evidence that a certificate was
#     issued, and until this block existed the script printed "Done." over a
#     cluster in which NOT ONE mTLS certificate had ever been minted — which is
#     precisely the outage 8b was written for. A bring-up that cannot detect its
#     own headline failure is a bring-up that will ship it again.
#
#     Same posture as the identity read-back above: enumerate what the REPO says
#     should exist, wait for it, then verify the RESULT independently — a real
#     X.509 leaf, in date, whose private key matches it, chaining to the cluster
#     CA the truststores use. Secret existence alone would pass on an empty file.
#
#     THE DENOMINATOR COMES FROM THE REPO, NOT THE CLUSTER.
#     The first cut of this block enumerated the generator-backed ExternalSecrets
#     the LIVE CLUSTER declared and verified those. That makes the one failure
#     mode it most needs to see invisible: if the ExternalSecret ITSELF never
#     lands, it is absent from the enumeration too, so the denominator shrinks
#     with the failure and the check only fails at exactly zero. Measured on the
#     live kind cluster: the repo declares 29 VaultDynamicSecret generators under
#     specs/cluster, the cluster carried 26, and the block cheerfully reported
#     "mTLS verified: 26/26" and printed Done. A post-condition whose denominator
#     is supplied by the thing under test is not a post-condition.
#
#     So: the expected set is read out of the manifests. A generator the repo
#     declares and the cluster does not carry is a FAILURE — unless the manifest
#     that declares it says, in the source and with a reason, that it is not
#     delivered by default. That marker is itself checked: it may not sit on a
#     generator that IS live (a stale exemption would mask the next regression),
#     and a marker with no usable reason is not an exemption.
# ─────────────────────────────────────────────────────────────────────────
verify_mtls_issuance() {
  local deadline_s="${MTLS_VERIFY_TIMEOUT:-600}"
  local spec_dir="${MTLS_SPEC_DIR:-${CLUSTER_DIR:-}}"
  local targets n_targets i tmp ca_file ns sec es subject issuer
  local missing="" rc=0 verified=0 sample=""
  local declared n_declared live_keys gen file reason key live
  local undelivered="" stale="" badreason="" n_expected=0 n_exempt=0

  # ── what the REPO declares must be issued ─────────────────────────────
  # Both metadata spellings in use are handled (flow `metadata: { name: x,
  # namespace: y }` — 27 of them — and the block form the two dark overlays
  # use). The opt-out marker is scoped to the YAML DOCUMENT it appears in, so it
  # cannot drift onto a neighbouring generator in the same file.
  if [ -z "${spec_dir}" ] || [ ! -d "${spec_dir}" ]; then
    echo "mTLS post-condition FAILED: cannot read the manifest tree (MTLS_SPEC_DIR/CLUSTER_DIR='${spec_dir}'), so the set of generators that OUGHT to be issued is unknown. An unverifiable post-condition is a failure, not a pass." >&2
    return 1
  fi
  declared="$(find "${spec_dir}" -type f \( -name '*.yaml' -o -name '*.yml' \) -exec awk '
      function emit() {
        if (ingen && nm != "" && ns != "") {
          printf "%s\t%s\t%s\t%s\n", ns, nm, FILENAME, doc_reason
          ingen = 0; inmeta = 0; nm = ""; ns = ""
        }
      }
      FNR == 1 { doc_reason = ""; ingen = 0; inmeta = 0; nm = ""; ns = "" }
      /^---[ \t]*$/ { doc_reason = ""; ingen = 0; inmeta = 0; nm = ""; ns = ""; next }
      /^[ \t]*#[ \t]*mtls-issuance:[ \t]*not-delivered/ {
        i = index($0, "not-delivered") + 13
        doc_reason = substr($0, i)
        gsub(/^[ \t]+|[ \t]+$/, "", doc_reason)
        next
      }
      /^kind:[ \t]*VaultDynamicSecret[ \t]*$/ { ingen = 1; nm = ""; ns = ""; next }
      ingen && /^metadata:[ \t]*\{/ {
        line = $0
        if (match(line, /[{,][ \t]*name:[ \t]*[A-Za-z0-9._-]+/)) {
          nm = substr(line, RSTART, RLENGTH); sub(/^[{,][ \t]*name:[ \t]*/, "", nm)
        }
        if (match(line, /[{,][ \t]*namespace:[ \t]*[A-Za-z0-9._-]+/)) {
          ns = substr(line, RSTART, RLENGTH); sub(/^[{,][ \t]*namespace:[ \t]*/, "", ns)
        }
        emit(); next
      }
      ingen && /^metadata:[ \t]*$/ { inmeta = 1; next }
      inmeta && /^[ \t]+name:[ \t]*[A-Za-z0-9._-]+[ \t]*$/ { nm = $2; emit(); next }
      inmeta && /^[ \t]+namespace:[ \t]*[A-Za-z0-9._-]+[ \t]*$/ { ns = $2; emit(); next }
      inmeta && /^[^ \t#]/ { inmeta = 0; ingen = 0 }
    ' {} + 2>/dev/null | sort -u)"
  n_declared="$(printf '%s' "${declared}" | grep -c . || true)"
  if [ "${n_declared}" -eq 0 ]; then
    echo "mTLS post-condition FAILED: not one VaultDynamicSecret generator was found under ${spec_dir}. Either the manifests moved or this scan is broken; either way the expected set is empty and everything would pass vacuously." >&2
    return 1
  fi

  # ── what the CLUSTER actually carries ─────────────────────────────────
  # Keyed by <namespace>/<generator name> so it can be matched against the repo
  # declaration above, not merely counted against itself.
  targets="$(kubectl get externalsecrets.external-secrets.io -A -o json 2>/dev/null \
    | jq -r '.items[]
             | . as $es
             | [ $es.spec.dataFrom[]? | select(.sourceRef.generatorRef != null)
                 | .sourceRef.generatorRef.name ] as $g
             | select(($g | length) > 0)
             | "\($es.metadata.namespace) \($es.spec.target.name // $es.metadata.name) \($es.metadata.name) \($g[0])"' \
    2>/dev/null || true)"
  n_targets="$(printf '%s' "${targets}" | grep -c . || true)"
  if [ "${n_targets}" -eq 0 ]; then
    echo "mTLS post-condition: NOT ONE generator-backed ExternalSecret exists in this cluster, while the repo declares ${n_declared}. Either the external-secrets CRDs never installed or 04-external-secrets-config.yaml never synced — so the vault-ca/vault-token seeding above served nothing and this check verified nothing. That is a failure, not a pass." >&2
    return 1
  fi
  live_keys=" $(printf '%s\n' "${targets}" | awk 'NF {print $1 "/" $4}' | tr '\n' ' ')"

  # ── repo vs cluster ───────────────────────────────────────────────────
  while IFS="$(printf '\t')" read -r ns gen file reason; do
    [ -n "${ns}" ] || continue
    key="${ns}/${gen}"
    case "${live_keys}" in
      *" ${key} "*) live=1 ;;
      *)            live=0 ;;
    esac
    if [ -n "${reason}" ]; then
      # An exemption is a reviewed claim: it must state one, and it may not sit
      # on a generator the cluster DOES carry — that would silently absorb the
      # next delivery regression instead of reporting it.
      if [ "${#reason}" -lt 24 ]; then
        badreason="${badreason}
      ${key} (${file}): ${reason}"
      elif [ "${live}" -eq 1 ]; then
        stale="${stale}
      ${key} (${file})"
      else
        n_exempt=$(( n_exempt + 1 ))
        log "  not-delivered by declaration: ${key} — ${reason}"
      fi
      continue
    fi
    n_expected=$(( n_expected + 1 ))
    [ "${live}" -eq 1 ] || undelivered="${undelivered}
      ${key} declared in ${file}"
  done <<< "${declared}"

  if [ -n "${badreason}" ]; then
    echo "mTLS post-condition FAILED: an \`mtls-issuance: not-delivered\` marker with no usable reason (needs >=24 characters):${badreason}" >&2
    return 1
  fi
  if [ -n "${stale}" ]; then
    echo "mTLS post-condition FAILED: these generators carry an \`mtls-issuance: not-delivered\` marker but the cluster DOES carry them, so the marker is stale and would mask the next delivery failure:${stale}" >&2
    return 1
  fi
  if [ -n "${undelivered}" ]; then
    echo "mTLS post-condition FAILED: the repo declares generators that never reached the cluster, so no ExternalSecret and no certificate exists for them:${undelivered}" >&2
    echo "    This is invisible to any check that counts what the CLUSTER declares — the denominator shrinks with the failure. Diagnose with:" >&2
    echo "      kubectl -n devops get applications -o wide      # a SyncError leaves resources untracked" >&2
    echo "      grep -n resources -A40 ${spec_dir}/manifests/external-secrets/kustomization.yaml" >&2
    echo "    A manifest that is genuinely not delivered by default must say so where it is declared:" >&2
    echo "      # mtls-issuance: not-delivered <why, and where the design says so>" >&2
    return 1
  fi

  log "Verifying mTLS issuance (${n_declared} generator(s) declared in ${spec_dir##*/}: ${n_expected} expected, ${n_exempt} declared not-delivered; ${n_targets} generator-backed ExternalSecret(s) live) — independent read-back"

  # Wait for the target Secrets to materialize.
  for i in $(seq 1 $(( deadline_s / 5 ))); do
    missing=""
    while read -r ns sec es gen; do
      [ -n "${ns}" ] || continue
      kubectl -n "${ns}" get secret "${sec}" >/dev/null 2>&1 || missing="${missing} ${ns}/${sec}"
    done <<< "${targets}"
    [ -z "${missing}" ] && break
    sleep 5
  done
  if [ -n "${missing}" ]; then
    echo "mTLS post-condition FAILED: after ${deadline_s}s these generator-backed Secrets were never issued:${missing}" >&2
    echo "    This is the exact shape of the outage step 8b exists to prevent. Diagnose with:" >&2
    echo "      kubectl get externalsecrets -A | grep -v SecretSynced\$" >&2
    echo "      kubectl -n external-secrets logs deploy/external-secrets | tail -50" >&2
    return 1
  fi

  # The anchor the truststores use — read back from the cluster, not assumed.
  tmp="$(mktemp -d)"; ca_file="${tmp}/ca.crt"
  kubectl -n vault get secret cluster-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > "${ca_file}"
  [ -s "${ca_file}" ] || { echo "mTLS post-condition FAILED: vault/cluster-ca carries no tls.crt to verify against" >&2; rm -rf "${tmp}"; return 1; }

  while read -r ns sec es gen; do
    [ -n "${ns}" ] || continue
    kubectl -n "${ns}" get secret "${sec}" -o jsonpath='{.data.tls\.crt}' | base64 -d > "${tmp}/leaf.crt" 2>/dev/null || true
    kubectl -n "${ns}" get secret "${sec}" -o jsonpath='{.data.tls\.key}' | base64 -d > "${tmp}/leaf.key" 2>/dev/null || true
    if [ ! -s "${tmp}/leaf.crt" ]; then
      echo "    ${ns}/${sec}: EXISTS BUT CARRIES NO tls.crt — an empty Secret is not an issued certificate" >&2
      rc=1; continue
    fi
    subject="$(openssl x509 -in "${tmp}/leaf.crt" -noout -subject 2>/dev/null || true)"
    if [ -z "${subject}" ]; then
      echo "    ${ns}/${sec}: tls.crt is not a parseable X.509 certificate" >&2
      rc=1; continue
    fi
    if ! openssl x509 -in "${tmp}/leaf.crt" -noout -checkend 0 >/dev/null 2>&1; then
      echo "    ${ns}/${sec}: certificate is already expired" >&2
      rc=1; continue
    fi
    # The key must belong to the cert: a leaf paired with someone else's key
    # mounts fine and then fails every handshake.
    if [ ! -s "${tmp}/leaf.key" ] || \
       [ "$(openssl x509 -in "${tmp}/leaf.crt" -noout -pubkey 2>/dev/null)" != \
         "$(openssl pkey -in "${tmp}/leaf.key" -pubout 2>/dev/null)" ]; then
      echo "    ${ns}/${sec}: tls.key does not match tls.crt" >&2
      rc=1; continue
    fi
    if ! openssl verify -CAfile "${ca_file}" "${tmp}/leaf.crt" >/dev/null 2>&1; then
      issuer="$(openssl x509 -in "${tmp}/leaf.crt" -noout -issuer 2>/dev/null || true)"
      echo "    ${ns}/${sec}: does NOT chain to vault/cluster-ca (${issuer}) — the workloads' truststore will reject it" >&2
      rc=1; continue
    fi
    verified=$(( verified + 1 ))
    [ -n "${sample}" ] || sample="${ns}/${sec}: ${subject} / $(openssl x509 -in "${tmp}/leaf.crt" -noout -issuer 2>/dev/null)"
  done <<< "${targets}"
  rm -rf "${tmp}"

  if [ "${rc}" -ne 0 ] || [ "${verified}" -ne "${n_targets}" ]; then
    echo "mTLS post-condition FAILED: ${verified}/${n_targets} generator-issued certificates verified." >&2
    return 1
  fi
  log "  mTLS verified: ${verified}/${n_targets} certificates issued, in date, key-matched and chaining to vault/cluster-ca"
  echo "    e.g. ${sample}"
}

verify_mtls_issuance || {
  echo "Refusing to report a successful bring-up: no verified mTLS certificate. Every pod that mounts a *-mtls Secret will hang in Init:0/1 on 'MountVolume.SetUp failed for volume \"pki\"'." >&2
  exit 1
}

# Reached only after verify_mtls_issuance() proved a real, chaining certificate
# exists — so, like the SSO line above, this is a claim with evidence behind it.
log "Done. Cluster '${CLUSTER_NAME}' is left running for the next validation step."
echo "    kubeconfig context: kind-${CLUSTER_NAME}"
echo "    ArgoCD admin password: kubectl -n ${ARGOCD_NS} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo "    Tear down: kind delete cluster --name ${CLUSTER_NAME}"

#!/bin/bash
# bootstrap.sh — install ArgoCD + the HugMesh app-of-apps on the cluster.
# Runs on the pki control-plane node (invoked by keys-provision when
# hugmesh.gitops.enabled=true, or by hand). Idempotent.
set -euo pipefail

CLUSTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"

ARGOCD_VERSION="${ARGOCD_VERSION:-stable}"
ARGOCD_NS="${ARGOCD_NS:-devops}"
REPO="${HUGMESH_GITOPS_REPO:-https://github.com/hugmesh-net/hugmesh-generator.git}"
REV="${HUGMESH_GITOPS_REV:-main}"

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
kubectl version >/dev/null 2>&1 || { echo "no reachable cluster (KUBECONFIG=${KUBECONFIG})" >&2; exit 1; }

echo "==> Namespaces"
kubectl apply -f "${CLUSTER_DIR}/namespaces/namespaces.yaml"

# ── Local storage from the x86 host's disks + attached USB ─────────
# A local-path StorageClass backed by the device disk (/mnt/data) and the
# attached USB (/mnt/usb), pinned to the amd64 host. Applied before ArgoCD so
# ArgoCD (and every cluster PVC) can provision onto those disks.
echo "==> Local storage (device disk + USB) on the x86 host"
kubectl apply -k "${CLUSTER_DIR}/manifests/local-path" 2>/dev/null \
    || kubectl apply -f "${CLUSTER_DIR}/manifests/local-path" || true

echo "==> Installing ArgoCD (${ARGOCD_VERSION}) into namespace '${ARGOCD_NS}'"
# Re-namespace the upstream install (it hardcodes 'argocd' in CRB subjects) and
# apply into ${ARGOCD_NS} (devops).
curl -fsSL "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" \
    | sed "s/namespace: argocd/namespace: ${ARGOCD_NS}/g" \
    | kubectl apply -n "${ARGOCD_NS}" -f -

# ── ArgoCD runs ONLY on the x86_64 host (the Pis are arm64) ────────
# Hard nodeSelector kubernetes.io/arch=amd64 on every ArgoCD workload, and use
# the local (device+USB) StorageClass for any ArgoCD PVC (e.g. redis-ha).
echo "==> Pinning ALL ArgoCD components to the x86_64 host (kubernetes.io/arch=amd64)"
PATCH='{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/arch":"amd64"}}}}}'
while read -r kind name; do
    [ -n "${name}" ] || continue
    kubectl -n "${ARGOCD_NS}" patch "${kind}" "${name}" --type merge -p "${PATCH}" 2>/dev/null \
        && echo "   pinned ${kind}/${name}" || true
done < <(kubectl -n "${ARGOCD_NS}" get deploy,statefulset -o jsonpath='{range .items[*]}{.kind}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null)

echo "==> Waiting for ArgoCD to be ready"
kubectl -n "${ARGOCD_NS}" rollout status deploy/argocd-repo-server --timeout=300s || true

# ── ArgoCD repository credential (PRIVATE GitOps repo) ─────────────
# hugmesh-generator is a PRIVATE GitHub repo, so ArgoCD's repo-server needs a
# credential or EVERY git-path Application (vault, casdoor, harbor-provision,
# forgejo, the app-of-apps itself) fails to sync with "authentication required:
# Repository not found". Register it HERE — BEFORE the app-of-apps apply below —
# so the very first reconcile can already clone (placing it after would leave
# the initial reconcile 401ing until a later retry). Promoted verbatim from the
# kind-local dev pattern (bootstrap/kind-local/bootstrap-kind.sh, section "5b").
#
# The token is sourced OUT-OF-BAND, the same house way every other real-path
# secret arrives: keys-provision (specs/etc/keys-provision/provision.sh) reads a
# fine-grained read-only PAT from the offline KEYS USB (KEYS/gitops/repo-token,
# SAME custody as vault/token + certs/cluster-ca.key + luks.key — NEVER git) and
# exports it as ARGOCD_REPO_TOKEN before invoking this script. It is NEVER
# hardcoded, NEVER defaulted, and NEVER printed. Absent => fail closed (below),
# so the gap is surfaced loudly instead of silently producing non-syncing apps.
# A PUBLIC fork that needs no credential opts out with ARGOCD_REPO_PUBLIC=1.
if [ -n "${ARGOCD_REPO_TOKEN:-}" ]; then
    echo "==> Registering ArgoCD repo credential for ${REPO} (from \$ARGOCD_REPO_TOKEN, never printed)"
    kubectl -n "${ARGOCD_NS}" create secret generic hugmesh-generator-repo \
        --from-literal=type=git \
        --from-literal=url="${REPO}" \
        --from-literal=username=x-access-token \
        --from-literal=password="${ARGOCD_REPO_TOKEN}" \
        --dry-run=client -o yaml \
        | kubectl label --local -f - "argocd.argoproj.io/secret-type=repository" --dry-run=client -o yaml \
        | kubectl apply -f -
elif [ "${ARGOCD_REPO_PUBLIC:-0}" = "1" ]; then
    echo "==> ARGOCD_REPO_PUBLIC=1 — treating ${REPO} as PUBLIC; registering NO ArgoCD repository credential"
else
    echo "FATAL: ARGOCD_REPO_TOKEN not set; the private repo ${REPO} needs an ArgoCD repository credential or every git-path Application (vault, casdoor, harbor-provision, forgejo, app-of-apps) will fail to sync with 'authentication required: Repository not found'." >&2
    echo "       Provision it the house way: write a fine-grained read-only GitHub PAT (repo:read on hugmesh-generator only) to the offline KEYS USB at KEYS/gitops/repo-token (same custody as vault/token); keys-provision exports it as ARGOCD_REPO_TOKEN before running this script. For a PUBLIC fork that needs no credential, re-run with ARGOCD_REPO_PUBLIC=1." >&2
    exit 1
fi

echo "==> Applying root app-of-apps (ns=${ARGOCD_NS} repo=${REPO} rev=${REV})"
sed -e "s#repoURL: https://github.com/hugmesh-net/hugmesh-generator.git#repoURL: ${REPO}#" \
    -e "s#targetRevision: main#targetRevision: ${REV}#" \
    "${CLUSTER_DIR}/app-of-apps.yaml" | kubectl apply -f -

# headscale runs as a HOST OpenRC service on the pki node (it must be up for nodes
# to join the VPN independently of k8s). Point the selector-less headscale Service
# (apps/07-headscale-svc.yaml) at the pki node's internal IP so the pki gateway can
# reach it. The node IP is per-deployment, so inject the Endpoints here.
echo "==> headscale Endpoints (host service on the pki node)"
PKI_IP="$(kubectl get node -l snapdragon.systems/pki=true -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)"
[ -n "${PKI_IP}" ] || PKI_IP="$(kubectl get node "$(hostname)" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)"
if [ -n "${PKI_IP}" ]; then
    kubectl apply -f - <<EOF && echo "   headscale -> ${PKI_IP}:8080" || true
apiVersion: v1
kind: Endpoints
metadata:
  name: headscale
  namespace: hugmesh-pki
subsets:
  - addresses:
      - ip: ${PKI_IP}
    ports:
      - name: http
        port: 8080
EOF
else
    echo "   WARN: could not resolve pki node InternalIP; create the headscale Endpoints by hand"
fi

# ── LAN wildcard DNS — inject the ingress node IP (ENV=test only) ──────────────
# The lan-dns CoreDNS resolver answers *.<domain> with an ingress node's LAN IP.
# WHICH node depends on RELEASE_STATE (baked at /etc/hugmesh/release-state,
# mirroring the /etc/hugmesh/cluster-domain bake):
#   * public  -> the BACKEND node (the router's 80/443 target; the public
#     ingress-nginx, apps/10-ingress-nginx.yaml, is pinned there).
#   * internal (DEFAULT) -> the PKI node instead. gate_env_apps() prunes
#     10-ingress-nginx.yaml entirely when RELEASE_STATE!=public, so EVERY
#     surviving public-facing route is served ONLY by the internal
#     ingress-nginx on the pki node (apps/11-ingress-nginx-internal.yaml) —
#     answering with the backend IP would 404/timeout every LAN name.
# The IP is per-deployment, so patch the placeholder __LAN_INGRESS_IP__ in the
# lan-dns-corefile ConfigMap here — mirroring the headscale PKI_IP injection
# above (REUSED here rather than re-queried). No-op in ENV=prod images (the
# lan-dns app is pruned, so the ConfigMap never exists). Idempotent: re-derives
# and re-patches the live IP every run.
echo "==> lan-dns wildcard resolver (ingress node IP; gated on RELEASE_STATE)"
RELEASE_STATE="internal"
[ -r /etc/hugmesh/release-state ] && RELEASE_STATE="$(cat /etc/hugmesh/release-state 2>/dev/null || echo internal)"
BACKEND_IP="$(kubectl get node -l snapdragon.systems/backend=true -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)"
[ -n "${BACKEND_IP}" ] || BACKEND_IP="$(kubectl get node "$(hostname)" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)"
if [ "${RELEASE_STATE}" = "public" ]; then
    NODE_KIND="backend"
    LAN_IP="${BACKEND_IP}"
else
    # internal-only: the PKI node (already resolved above for headscale) is
    # the sole surviving public-facing ingress; fall back to BACKEND_IP only
    # if the pki node's IP could not be resolved (best-effort, never worse
    # than the pre-RELEASE_STATE behaviour).
    NODE_KIND="pki"
    LAN_IP="${PKI_IP:-${BACKEND_IP}}"
fi
if [ -n "${LAN_IP}" ] && kubectl -n kube-system get configmap lan-dns-corefile >/dev/null 2>&1; then
    # Swap the placeholder (or a previously-injected A-record IP) for the current
    # ingress node IP, re-apply, and restart CoreDNS to reload. The two A-record
    # forms are: the literal __LAN_INGRESS_IP__ token (first boot) and an already
    # injected dotted-quad after "60 IN A " (re-run / IP changed).
    COREFILE="$(kubectl -n kube-system get configmap lan-dns-corefile -o jsonpath='{.data.Corefile}')"
    NEW_COREFILE="$(printf '%s' "${COREFILE}" \
        | sed -E "s/(60 IN A )(__LAN_INGRESS_IP__|([0-9]{1,3}\.){3}[0-9]{1,3})/\1${LAN_IP}/g")"
    kubectl -n kube-system create configmap lan-dns-corefile \
        --from-literal=Corefile="${NEW_COREFILE}" \
        --dry-run=client -o yaml | kubectl apply -f - \
        && echo "   lan-dns *.<domain> -> ${LAN_IP} (RELEASE_STATE=${RELEASE_STATE}, ${NODE_KIND} node)" || true
    kubectl -n kube-system rollout restart deploy/lan-dns >/dev/null 2>&1 || true
elif kubectl -n kube-system get configmap lan-dns-corefile >/dev/null 2>&1; then
    echo "   WARN: lan-dns present but could not resolve the ${NODE_KIND} node InternalIP; patch __LAN_INGRESS_IP__ by hand"
else
    echo "   (lan-dns not deployed — ENV=prod image, or app pruned; skipping)"
fi

echo "==> Done. ArgoCD (in '${ARGOCD_NS}', x86-only) will now sync every Application under specs/cluster/apps."
echo "    argocd admin password: kubectl -n ${ARGOCD_NS} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"

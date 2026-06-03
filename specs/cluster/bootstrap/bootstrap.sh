#!/bin/bash
# bootstrap.sh — install ArgoCD + the Snapdragon app-of-apps on the cluster.
# Runs on the pki control-plane node (invoked by keys-provision when
# snapdragon.gitops.enabled=true, or by hand). Idempotent.
set -euo pipefail

CLUSTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"

ARGOCD_VERSION="${ARGOCD_VERSION:-stable}"
REPO="${SNAPDRAGON_GITOPS_REPO:-https://github.com/Snapdragon-Systems/snapdragon-generator.git}"
REV="${SNAPDRAGON_GITOPS_REV:-main}"

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
kubectl version >/dev/null 2>&1 || { echo "no reachable cluster (KUBECONFIG=${KUBECONFIG})" >&2; exit 1; }

echo "==> Namespaces"
kubectl apply -f "${CLUSTER_DIR}/namespaces/namespaces.yaml"

echo "==> Installing ArgoCD (${ARGOCD_VERSION})"
kubectl apply -n argocd \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

# Prefer to run ArgoCD on the x86_64 worker if one is labelled for it.
if kubectl get nodes -l snapdragon.systems/compute=gpu -o name | grep -q node; then
    echo "==> Pinning ArgoCD to the x86_64 worker"
    for d in argocd-server argocd-repo-server argocd-application-controller argocd-applicationset-controller; do
        kubectl -n argocd patch deploy "${d}" --type merge \
            -p '{"spec":{"template":{"spec":{"nodeSelector":{"snapdragon.systems/compute":"gpu"}}}}}' 2>/dev/null || true
    done
fi

echo "==> Waiting for ArgoCD to be ready"
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s || true

echo "==> Applying root app-of-apps (repo=${REPO} rev=${REV})"
sed -e "s#repoURL: https://github.com/Snapdragon-Systems/snapdragon-generator.git#repoURL: ${REPO}#" \
    -e "s#targetRevision: main#targetRevision: ${REV}#" \
    "${CLUSTER_DIR}/app-of-apps.yaml" | kubectl apply -f -

echo "==> Done. ArgoCD will now sync every Application under specs/cluster/apps."
echo "    argocd admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"

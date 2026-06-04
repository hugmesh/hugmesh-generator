#!/bin/bash
# bootstrap.sh — install ArgoCD + the Snapdragon app-of-apps on the cluster.
# Runs on the pki control-plane node (invoked by keys-provision when
# snapdragon.gitops.enabled=true, or by hand). Idempotent.
set -euo pipefail

CLUSTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"

ARGOCD_VERSION="${ARGOCD_VERSION:-stable}"
ARGOCD_NS="${ARGOCD_NS:-devops}"
REPO="${SNAPDRAGON_GITOPS_REPO:-https://github.com/Snapdragon-Systems/snapdragon-generator.git}"
REV="${SNAPDRAGON_GITOPS_REV:-main}"

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

echo "==> Applying root app-of-apps (ns=${ARGOCD_NS} repo=${REPO} rev=${REV})"
sed -e "s#repoURL: https://github.com/Snapdragon-Systems/snapdragon-generator.git#repoURL: ${REPO}#" \
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
  namespace: snapdragon-pki
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

echo "==> Done. ArgoCD (in '${ARGOCD_NS}', x86-only) will now sync every Application under specs/cluster/apps."
echo "    argocd admin password: kubectl -n ${ARGOCD_NS} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"

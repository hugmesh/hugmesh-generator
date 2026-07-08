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

# ── LAN wildcard DNS — inject the ingress node IP (ENV=test only) ──────────────
# The lan-dns CoreDNS resolver answers *.<domain> with an ingress node's LAN IP.
# WHICH node depends on RELEASE_STATE (baked at /etc/snapdragon/release-state,
# mirroring the /etc/snapdragon/cluster-domain bake):
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
[ -r /etc/snapdragon/release-state ] && RELEASE_STATE="$(cat /etc/snapdragon/release-state 2>/dev/null || echo internal)"
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

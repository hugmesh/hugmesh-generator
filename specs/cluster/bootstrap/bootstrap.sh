#!/bin/bash
# bootstrap.sh — install ArgoCD + the HugMesh app-of-apps on the cluster.
# Runs on the pki control-plane node (invoked by keys-provision when
# hugmesh.gitops.enabled=true, or by hand). Idempotent.
set -euo pipefail

CLUSTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"

ARGOCD_VERSION="${ARGOCD_VERSION:-stable}"
ARGOCD_NS="${ARGOCD_NS:-devops}"
REPO="${HUGMESH_GITOPS_REPO:-https://github.com/hugmesh/hugmesh-generator.git}"
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

# ─────────────────────────────────────────────────────────────────────────
# THE APPLICATION SET THIS DEVICE RUNS — the BAKED tree, not the repo.
# ─────────────────────────────────────────────────────────────────────────
# Until 2026-08-26 this step was a single `kubectl apply` of
# ${CLUSTER_DIR}/app-of-apps.yaml with repoURL/targetRevision sed-substituted.
# That root Application carries
#     source: {repoURL: .../hugmesh-generator.git, targetRevision: main,
#              path: specs/cluster/apps, directory: {recurse: true}}
# so ArgoCD instantiated every Application under specs/cluster/apps AS IT EXISTS
# ON GITHUB. Nothing in this script, and nothing in
# specs/etc/keys-provision/provision.sh, ever read the baked
# /var/lib/hugmesh/cluster/apps tree at all.
#
# OBSERVED CONSEQUENCE (the reason this block exists): EVERY build-time gate that
# edits the baked tree was INERT on a real device — not merely incomplete, inert.
#   * gate_optional_services() in build-rpi5-stage4.sh / build-x86-host-stage4.sh
#     `rm -f`s apps/30-tuwunel.yaml, apps/30-phpbb.yaml, apps/50-games.yaml, …
#     for every slug not in OPTIONAL_SERVICES. A device built with
#     `--optional-services akkoma` still got tuwunel, phpbb, games, owncast and
#     tube, because ArgoCD read those filenames from GitHub main.
#   * gate_env_apps() prunes 10-ingress-nginx.yaml / 09-lan-dns.yaml /
#     12-cloudflared.yaml / 99-test-runner.yaml the same way — same inertness.
#   * The gates ALSO edit apps files IN PLACE (_opt_drop_route removes a deleted
#     upstream's HTTP routes from apps/20-gateway-be.yaml; _opt_drop_extrahost
#     removes its vhost). A repo-sourced 20-gateway-be.yaml keeps those routes,
#     which is the 502-to-a-nonexistent-upstream the gate's own comment warns
#     about.
# The operator requirement — "images with services selected only start those
# services" — could not hold under that topology by construction.
#
# THE FIX: apply the BAKED, GATED Application files directly, exactly the way
# bootstrap/kind-local/bootstrap-kind.sh's apply_core_app() already applies its
# curated subset — same repoURL/targetRevision sed, so a fork/mirror override
# still works. The device then runs the Application set its own image was built
# with, and the in-file edits (dropped routes, dropped extraHosts, baked domains)
# are the ones that reach the cluster.
#
# WHAT THIS DELIBERATELY GIVES UP, and why that is the right trade:
#   * app-of-apps PRUNE. The root's `prune: true` would delete an Application
#     whose file vanished from git. Applied directly, a file removed from a LATER
#     image is not retro-deleted from a running cluster. The baked tree is
#     immutable for the life of an image, so within one image there is nothing to
#     prune; across images the operator re-provisions.
#   * app-of-apps SELFHEAL of the Application OBJECTS themselves. Each child
#     Application still carries its OWN `syncPolicy.automated {prune, selfHeal}`
#     (see apps/30-tuwunel.yaml et al), so every WORKLOAD still self-heals — only
#     the Application object is no longer re-asserted. The re-assert path is
#     OPERATOR-INITIATED, not automatic: this script's only caller is
#     provision_hugmesh() in specs/etc/keys-provision/provision.sh, whose main()
#     short-circuits on /var/lib/keys-provision/done — after first boot it re-runs
#     only with the KEYS USB inserted AND .provision-force on it (or KEYS_FORCE=1).
#     No timer, no periodic unit. So an Application OBJECT deleted on a live
#     cluster stays gone until the operator re-provisions. (Corrected 2026-08-26
#     after review; the line here used to claim keys-provision re-runs it, full
#     stop, which described a loop that does not exist.)
#   * CROSS-APPLICATION SYNC-WAVE ordering, which ArgoCD only enforces for
#     children of a common parent. bootstrap-kind.sh made and documented this
#     same trade: every hook Job here is idempotent/retrying, so the set
#     converges in a couple of reconcile loops instead of one ordered pass.
#   * The root's `ignoreDifferences` keystone (the admin-bff
#     OptionalServiceReconciler's single-writer claim on the optional-services
#     ApplicationSet element list) becomes MOOT rather than lost: with no root
#     selfHealing 13a-optional-services.yaml, nothing reverts the runtime write.
#
# ESCAPE HATCH: HUGMESH_GITOPS_ROOT_RECURSE=1 restores the old repo-recursing
# root. It is the RIGHT choice for a cluster deliberately driven from a git
# branch — and the WRONG one for a gated image, so it says so out loud.
# HUGMESH_APPLY_RETRIES / HUGMESH_APPLY_BACKOFF: bounded retry for a TRANSIENT
# API error. Overridable only so the guard suite can drive the exhausted-retry
# path without sleeping; the defaults are what a device runs.
APPLY_RETRIES="${HUGMESH_APPLY_RETRIES:-3}"
APPLY_BACKOFF="${HUGMESH_APPLY_BACKOFF:-2}"
apply_baked_app() {
    # Same substitution the root apply used, and the same one
    # kind-local/bootstrap-kind.sh:apply_core_app() performs. The fork/mirror
    # override (HUGMESH_GITOPS_REPO / HUGMESH_GITOPS_REV, patched onto a device
    # via /etc/hugmesh/gitops.env) is applied HERE and nowhere else — if this
    # substitution regresses, all 74 Applications point at the upstream PRIVATE
    # repo and every one of them fails to sync with "authentication required".
    # tests/cluster/test-bootstrap-applies-baked-apps.sh section 1e asserts it.
    #
    # BOUNDED RETRY (added 2026-08-26 after review): this loop went from ONE
    # apply to ~74 sequential ones, so a single transient API error (throttle, a
    # webhook still coming up, a controller restart) that used to be an
    # all-or-nothing failure now aborts the run after an ARBITRARY PREFIX of the
    # set has already been applied. Retry a few times before giving up; a
    # manifest that fails EVERY attempt is still FATAL below.
    local _f="$1" _try _rc
    _try=1
    while : ; do
        set +e
        sed -e "s#repoURL: https://github.com/hugmesh/hugmesh-generator.git#repoURL: ${REPO}#" \
            -e "s#targetRevision: main#targetRevision: ${REV}#" \
            "${_f}" | kubectl apply -f -
        _rc=$?
        set -e
        [ "${_rc}" -ne 0 ] || return 0
        [ "${_try}" -lt "${APPLY_RETRIES}" ] || return "${_rc}"
        echo "   transient failure applying $(basename "${_f}") (rc=${_rc}); retry $((_try + 1))/${APPLY_RETRIES} in ${APPLY_BACKOFF}s" >&2
        [ "${APPLY_BACKOFF}" -eq 0 ] || sleep "${APPLY_BACKOFF}"
        _try=$((_try + 1))
    done
}

if [ "${HUGMESH_GITOPS_ROOT_RECURSE:-0}" = "1" ]; then
    echo "==> HUGMESH_GITOPS_ROOT_RECURSE=1 — applying the repo-recursing root app-of-apps (ns=${ARGOCD_NS} repo=${REPO} rev=${REV})"
    echo "    WARNING: this root syncs specs/cluster/apps FROM ${REPO}@${REV}. Every build-time"
    echo "    prune baked into ${CLUSTER_DIR}/apps (optional-services + ENV gates) is IGNORED —"
    echo "    a service deselected at build time WILL be installed from the repo."
    sed -e "s#repoURL: https://github.com/hugmesh/hugmesh-generator.git#repoURL: ${REPO}#" \
        -e "s#targetRevision: main#targetRevision: ${REV}#" \
        "${CLUSTER_DIR}/app-of-apps.yaml" | kubectl apply -f -
else
    echo "==> Applying the BAKED Application set from ${CLUSTER_DIR}/apps (repo=${REPO} rev=${REV})"
    [ -d "${CLUSTER_DIR}/apps" ] || {
        echo "FATAL: no baked Application tree at ${CLUSTER_DIR}/apps — this image's GitOps payload is incomplete; nothing would be deployed." >&2
        exit 1
    }
    # ── Retire a recursing root left by an EARLIER bootstrap of this cluster ──
    # A cluster first bootstrapped before this change still owns a `hugmesh-root`
    # Application recursing the repo; leaving it would immediately re-create every
    # Application this device deliberately does not ship, and selfHeal would fight
    # the direct applies forever. Delete it ORPHANING its children.
    #
    # THIS IS THE MOST DESTRUCTIVE LINE IN THIS SCRIPT AND IT FAILS **CLOSED**.
    # ArgoCD's `resources-finalizer.argocd.argoproj.io` makes a delete of the root
    # CASCADE-DELETE every resource the root manages — i.e. the ENTIRE PLATFORM.
    # The finalizer must therefore be STRIPPED FIRST, and until 2026-08-26 that
    # strip was `>/dev/null 2>&1 || true`: an RBAC denial, a conflict or an API
    # hiccup was SWALLOWED and control fell straight through to the delete with
    # the cascade finalizer still attached. Reviewed and fixed:
    #   * the patch's own rc is checked, AND
    #   * the POST-CONDITION is re-read from the API — `.metadata.finalizers` must
    #     come back EMPTY from a get that itself SUCCEEDS. A get that fails (RBAC,
    #     unreachable API) is NOT read as "no finalizers"; it aborts.
    #   * only then is the delete issued, with --cascade=orphan, and ITS rc is
    #     FATAL too — a retirement that silently failed leaves the recursing root
    #     alive to selfHeal against these direct applies forever, which is the
    #     exact scenario this block exists to prevent.
    # Never `|| true` anything in here again.
    # Guarded on the source path so this can only ever touch the recursing root,
    # never an operator's differently-scoped app of the same name.
    if [ "$(kubectl -n "${ARGOCD_NS}" get application hugmesh-root -o jsonpath='{.spec.source.path}' 2>/dev/null)" = "specs/cluster/apps" ]; then
        echo "   retiring the pre-existing repo-recursing root Application 'hugmesh-root' (children ORPHANED, not deleted)"
        if ! kubectl -n "${ARGOCD_NS}" patch application hugmesh-root --type merge \
                 -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1; then
            echo "FATAL: could not strip the resources-finalizer from Application/hugmesh-root in ns ${ARGOCD_NS} (kubectl patch failed). REFUSING to delete it: with that finalizer attached ArgoCD would CASCADE-DELETE every resource the root manages — the entire platform. Fix the permission/conflict and re-run; nothing has been changed." >&2
            exit 1
        fi
        # POST-CONDITION, not the patch's exit code: re-read it.
        if ! _root_fin="$(kubectl -n "${ARGOCD_NS}" get application hugmesh-root \
                              -o jsonpath='{.metadata.finalizers}' 2>/dev/null)"; then
            echo "FATAL: could not VERIFY that Application/hugmesh-root's finalizers were stripped (kubectl get failed). REFUSING to delete it — an unverified strip is treated as a live cascade finalizer. Nothing has been changed." >&2
            exit 1
        fi
        case "${_root_fin}" in
            ''|'[]') : ;;
            *)
                echo "FATAL: Application/hugmesh-root STILL carries finalizers ${_root_fin} after the strip. REFUSING to delete it — deleting now would CASCADE-DELETE every resource the root manages (the entire platform). Nothing has been changed." >&2
                exit 1 ;;
        esac
        if ! kubectl -n "${ARGOCD_NS}" delete application hugmesh-root \
                 --cascade=orphan --ignore-not-found >/dev/null 2>&1; then
            echo "FATAL: failed to delete the retired repo-recursing root Application/hugmesh-root. It is still live and will selfHeal the whole repo apps/ tree back over this device's baked set — refusing to report success." >&2
            exit 1
        fi
        echo "   retired hugmesh-root (finalizers verified stripped, children orphaned)"
    fi
    # ── The argoproj CRDs must be ESTABLISHED before ~74 Applications are applied ──
    # The ArgoCD readiness wait above is best-effort (`rollout status ... || true`),
    # so this loop can start while applications.argoproj.io is still being
    # registered. One apply was all-or-nothing; ~74 sequential ones are not, and a
    # "no matches for kind Application" on manifest 3 of 74 leaves a HALF-DEPLOYED
    # cluster that provision.sh only `|| warn`s about. Note `kubectl wait` ERRORS
    # OUT IMMEDIATELY ("no matching resources found") when the CRD does not exist
    # yet — it does not wait for it to appear — so poll for existence first.
    _wait_crd() {
        local _crd="$1" _budget _end
        _budget="${HUGMESH_CRD_TIMEOUT:-120}"
        _end=$((SECONDS + _budget))
        while : ; do
            if kubectl get "crd/${_crd}" >/dev/null 2>&1 \
               && kubectl wait --for=condition=established --timeout=30s "crd/${_crd}" >/dev/null 2>&1; then
                return 0
            fi
            [ "${SECONDS}" -lt "${_end}" ] || return 1
            sleep 3
        done
    }
    for _crd in applications.argoproj.io applicationsets.argoproj.io; do
        if _wait_crd "${_crd}"; then
            echo "   CRD ${_crd} is Established"
        else
            echo "FATAL: CRD ${_crd} was not Established within ${HUGMESH_CRD_TIMEOUT:-120}s of the ArgoCD install — applying this image's baked Application set now would fail partway through and leave a HALF-DEPLOYED cluster. Nothing was applied." >&2
            exit 1
        fi
    done
    _applied=0
    _failed=0
    _failed_files=""
    for _app in "${CLUSTER_DIR}"/apps/*.yaml; do
        [ -e "${_app}" ] || continue
        case "$(basename "${_app}")" in
            # The ALTERNATIVE waved root (apps/00-app-of-apps-waved.yaml) is
            # itself a `directory.recurse` Application over specs/cluster/apps on
            # GitHub — applying it here would re-import the whole unpruned repo
            # tree and undo this entire block. It stays what its own header says
            # it is: a root you point a bootstrap at DELIBERATELY, never one that
            # rides along with the baked set. gate_env_apps() already prunes it
            # from prod images; skipping it by name covers the test images where
            # it survives.
            00-app-of-apps-waved.yaml)
                echo "   skipping $(basename "${_app}") (alternative repo-recursing root; apply it deliberately, not here)"
                continue ;;
        esac
        if apply_baked_app "${_app}"; then
            _applied=$((_applied + 1))
        else
            _failed=$((_failed + 1))
            _failed_files="${_failed_files} $(basename "${_app}")"
            echo "   ERROR: failed to apply $(basename "${_app}") after ${APPLY_RETRIES} attempt(s)" >&2
        fi
    done
    # POST-CONDITION, not an exit code. An empty or unreadable apps/ directory
    # would otherwise walk the loop zero times and report success — the silent
    # no-op class this repo keeps getting bitten by.
    [ "${_applied}" -gt 0 ] || {
        echo "FATAL: ${CLUSTER_DIR}/apps contained no applicable Application manifests — nothing was deployed." >&2
        exit 1
    }
    echo "   applied ${_applied} baked Application manifest(s), ${_failed} failed"
    [ "${_failed}" -eq 0 ] || {
        echo "FATAL: ${_failed} baked Application manifest(s) failed to apply —${_failed_files} — the deployed set does NOT match this image, and an arbitrary PREFIX of it is already live on the cluster." >&2
        exit 1
    }
fi

# headscale runs as a HOST OpenRC service on the pki node (it must be up for nodes
# to join the VPN independently of k8s). Point the selector-less headscale Service
# (apps/07-headscale-svc.yaml) at the pki node's internal IP so the pki gateway can
# reach it. The node IP is per-deployment, so inject the Endpoints here.
echo "==> headscale Endpoints (host service on the pki node)"
PKI_IP="$(kubectl get node -l hugmesh.net/pki=true -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)"
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
BACKEND_IP="$(kubectl get node -l hugmesh.net/backend=true -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)"
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

if [ "${HUGMESH_GITOPS_ROOT_RECURSE:-0}" = "1" ]; then
    echo "==> Done. ArgoCD (in '${ARGOCD_NS}', x86-only) will now sync every Application under specs/cluster/apps of ${REPO}@${REV} — NOT the baked, gated tree."
else
    echo "==> Done. ArgoCD (in '${ARGOCD_NS}', x86-only) will now reconcile the ${_applied} Application(s) baked into this image at ${CLUSTER_DIR}/apps."
fi
echo "    argocd admin password: kubectl -n ${ARGOCD_NS} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"

#!/usr/bin/env bash
# registry-mirror.sh — host-side registry mirror for the emulated-cluster lane
# (issue #516, decisions 97a = B and 97b = C).
#
# WHY. An emulated node only goes Ready once it has a CNI, and the CNI is Calico
# installed by the Tigera operator, which ArgoCD installs (specs/cluster/apps/
# 01-calico.yaml). So Ready on an emulated cluster needs the Calico images, the
# Tigera operator chart AND ArgoCD's own images inside the guests. The operator
# chose (97a) a mirror on the HOST, pre-filled before a run, over baking the
# images into the node image or trusting the guests to pull over NAT (the kind
# node has already been seen failing to resolve quay.io). This script is that
# mirror: one registry:2 container on the host, filled with exactly the set
# below, plus the chart pushed into the same registry as an OCI artifact.
#
# WHERE THE GUESTS REACH IT. launch-x86.sh gives every guest a QEMU user-mode
# NIC (`-netdev user`, no `restrict=`); from inside that NIC the host's loopback
# is 10.0.2.2. So a registry bound to 127.0.0.1:PORT on the host is
# 10.0.2.2:PORT to every guest, with no new routing. The --mesh-net L2 is a
# QEMU socket/mcast wire the HOST HAS NO INTERFACE ON, so the mirror is NOT
# reachable over --mesh-net today; that would need a host-side attach (a tap or
# a fourth socket peer) that does not exist yet. This script says so rather
# than pretend.
#
# THE IMAGE SET (the "what does the mirror serve" answer, recorded here and in
# the --dry-run output):
#   * Calico ${CALICO_VERSION}: the chart version ArgoCD resolves for 01-calico's
#     `targetRevision: v3.29.x` (the newest v3.29 patch in the Tigera chart index),
#     its Tigera operator image (from that chart's values.yaml), and the Linux,
#     non-FIPS component images the operator deploys by default (the operator's
#     own pkg/components/calico.go; CalicoRegistry = docker.io/).
#   * ArgoCD ${ARGOCD_VERSION}: the three images its upstream install.yaml names
#     (bootstrap.sh's ARGOCD_VERSION is the single source of the version).
#   * The tigera-operator Helm chart itself (sha256-pinned tarball).
#
# DRIFT GUARDS (fail closed, in EVERY mode — --dry-run included):
#   * the baked CALICO_VERSION must satisfy 01-calico.yaml's targetRevision; bump
#     the spec to v3.30.x and this script refuses until the set is re-resolved;
#   * the baked ARGOCD_VERSION must equal bootstrap.sh's default; bump ArgoCD and
#     this script refuses until dex/redis are re-read from the new install.yaml;
#   * every Calico component image carries exactly CALICO_VERSION;
#   * no two images collapse onto one mirror path (the registry has one namespace).
#   On a live fill it ALSO checks the downloaded chart's sha256, that the chart's
#   values.yaml names the baked operator version, and that ArgoCD's install.yaml
#   names no image the set does not carry.
#
# MODES:
#   --dry-run | list   print the image set + guest address. No docker, no pull,
#                      no network, no files written. CI-green hermetic path.
#   up                 start the registry container (reused if already ours) and
#                      fill it. Needs docker, helm, and one of skopeo/crane/docker
#                      for the copies (skopeo/crane keep every platform; the docker
#                      fallback copies the host's architecture only).
#   down               remove the mirror container — ONLY when it carries this
#                      script's label (never somebody else's container by name).
#   hosts-toml DIR     write containerd certs.d/<registry>/hosts.toml stanzas that
#                      point each upstream at the mirror's guest address.
#
# Hermetic-test seams (mirrors mesh-cluster.sh's MESH_*_CMD):
#   MIRROR_DOCKER_CMD  replaces `docker`
#   MIRROR_COPY_CMD    replaces the image copy (argv: SRC DST)
#   MIRROR_HELM_CMD    replaces `helm`
#   MIRROR_FETCH_CMD   replaces `curl -fsSL URL -o OUT` (argv: URL OUT)
#
#   tests/qemu/registry-mirror.sh --dry-run
#   tests/qemu/registry-mirror.sh up            # then: HUGMESH_QEMU_MESH=1 make qemu-mesh
#   tests/qemu/registry-mirror.sh down
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ── The baked, resolved set ──────────────────────────────────────────────────
# Re-resolve ALL of these together when a guard below refuses: the chart index
# (https://docs.tigera.io/calico/charts/index.yaml) for the newest patch inside
# the spec's range, that chart's values.yaml for tigeraOperator.version, and
# ArgoCD's manifests/install.yaml at the new tag for its image lines.
CALICO_VERSION="v3.29.7"
TIGERA_OPERATOR_VERSION="v1.36.16"
CALICO_CHART_URL="https://github.com/projectcalico/calico/releases/download/${CALICO_VERSION}/tigera-operator-${CALICO_VERSION}.tgz"
CALICO_CHART_SHA256="ecf3dd86970d215ffef7f85e6830935292c002279861f1cad4ba40660d423cb9"
CALICO_COMPONENTS=(node cni kube-controllers typha pod2daemon-flexvol csi
                   node-driver-registrar apiserver key-cert-provisioner)
ARGOCD_VERSION="v3.5.3"
ARGOCD_EXTRA_IMAGES=(ghcr.io/dexidp/dex:v2.45.1
                     public.ecr.aws/docker/library/redis:8.2.3-alpine)
REGISTRY_IMAGE="docker.io/library/registry:2.8.3"

# ── Defaults ─────────────────────────────────────────────────────────────────
CALICO_SPEC="${REPO_DIR}/specs/cluster/apps/01-calico.yaml"
ARGOCD_BOOTSTRAP="${REPO_DIR}/specs/cluster/bootstrap/bootstrap.sh"
STATE_DIR="${REPO_DIR}/out/qemu-mirror"
NAME="hugmesh-qemu-registry-mirror"
LABEL="hugmesh-qemu-mirror=1"
BIND="127.0.0.1"
PORT="5000"
GUEST_HOST="10.0.2.2"           # the host's loopback as a user-mode-NIC guest sees it
MODE=""
HOSTS_DIR=""

usage() {
cat <<EOF
Usage: $0 [--dry-run | list | up | down | hosts-toml DIR] [OPTIONS]

  Host-side registry mirror for the emulated cluster: Calico ${CALICO_VERSION}
  (+ Tigera operator ${TIGERA_OPERATOR_VERSION} and its chart) and ArgoCD
  ${ARGOCD_VERSION}, served where the guests' user-mode NIC reaches the host.

      --dry-run, list    print the image set; pull nothing, write nothing
      up                 start + fill the mirror (docker, helm, skopeo|crane|docker)
      down               remove the mirror container (only if it is ours)
      hosts-toml DIR     write containerd hosts.toml stanzas under DIR
      --port N           host port (guests dial ${GUEST_HOST}:N). Default: ${PORT}
      --bind ADDR        host bind address. Default: ${BIND}
      --name NAME        container name. Default: ${NAME}
      --state-dir D      registry storage + fetched files. Default: ${STATE_DIR}
      --calico-spec F    the pinned Calico Application. Default: specs/cluster/apps/01-calico.yaml
      --argocd-bootstrap F  the file that pins ARGOCD_VERSION. Default: specs/cluster/bootstrap/bootstrap.sh
  -h, --help             this help
EOF
exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run|list)     MODE="list"; shift ;;
        up|down)            MODE="$1"; shift ;;
        hosts-toml)         MODE="hosts-toml"; HOSTS_DIR="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
        --port)             PORT="$2"; shift 2 ;;
        --bind)             BIND="$2"; shift 2 ;;
        --name)             NAME="$2"; shift 2 ;;
        --state-dir)        STATE_DIR="$2"; shift 2 ;;
        --calico-spec)      CALICO_SPEC="$2"; shift 2 ;;
        --argocd-bootstrap) ARGOCD_BOOTSTRAP="$2"; shift 2 ;;
        -h|--help)          usage 0 ;;
        *) echo "Unknown arg: $1" >&2; usage 1 ;;
    esac
done
[ -n "${MODE}" ] || usage 1

info() { echo "[registry-mirror] $*"; }
die()  { echo "[registry-mirror] ERROR: $*" >&2; exit 1; }

[[ "${PORT}" =~ ^[0-9]+$ ]] && [ "${PORT}" -ge 1 ] && [ "${PORT}" -le 65535 ] \
    || die "--port wants 1-65535, got '${PORT}'"

# ── The image list: "SRC MIRROR_PATH" per line ───────────────────────────────
# MIRROR_PATH is SRC without its registry host: containerd's hosts.toml mirror
# asks the mirror for /v2/<path>/... with the upstream host stripped, so that is
# the path every image must be pushed to.
image_set() {
    local c
    printf '%s\n' "quay.io/tigera/operator:${TIGERA_OPERATOR_VERSION}"
    for c in "${CALICO_COMPONENTS[@]}"; do
        printf '%s\n' "docker.io/calico/${c}:${CALICO_VERSION}"
    done
    printf '%s\n' "quay.io/argoproj/argocd:${ARGOCD_VERSION}"
    printf '%s\n' "${ARGOCD_EXTRA_IMAGES[@]}"
}
mirror_path() { printf '%s\n' "${1#*/}"; }        # strip the registry host
registry_of() { printf '%s\n' "${1%%/*}"; }

# ── Drift guards (run in every mode) ─────────────────────────────────────────
# targetRevision "v3.29.x" -> ERE ^v3\.29\.[0-9]+$ ; an exact pin stays exact.
range_to_ere() {
    local r="$1"
    r="$(printf '%s' "${r}" | sed -e 's/\./\\./g' -e 's/\\\.x$/\\.[0-9]+/' -e 's/^/^/' -e 's/$/$/')"
    printf '%s\n' "${r}"
}
check_guards() {
    local rev ere pinned img tag dup
    [ -f "${CALICO_SPEC}" ] || die "Calico spec not found: ${CALICO_SPEC}"
    rev="$(sed -n 's/^[[:space:]]*targetRevision:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}.*/\1/p' "${CALICO_SPEC}" | head -n 1)"
    [ -n "${rev}" ] || die "no targetRevision in ${CALICO_SPEC}"
    ere="$(range_to_ere "${rev}")"
    [[ "${CALICO_VERSION}" =~ ${ere} ]] \
        || die "Calico drift: ${CALICO_SPEC} pins targetRevision ${rev}, but this mirror carries ${CALICO_VERSION} — re-resolve CALICO_VERSION, TIGERA_OPERATOR_VERSION and CALICO_CHART_SHA256 (see the baked-set comment)"
    CALICO_RANGE="${rev}"

    [ -f "${ARGOCD_BOOTSTRAP}" ] || die "ArgoCD bootstrap not found: ${ARGOCD_BOOTSTRAP}"
    pinned="$(sed -n 's/^ARGOCD_VERSION="\${ARGOCD_VERSION:-\([^}]*\)}".*/\1/p' "${ARGOCD_BOOTSTRAP}" | head -n 1)"
    [ -n "${pinned}" ] || die "no ARGOCD_VERSION default in ${ARGOCD_BOOTSTRAP}"
    [ "${pinned}" = "${ARGOCD_VERSION}" ] \
        || die "ArgoCD drift: ${ARGOCD_BOOTSTRAP} pins ${pinned}, but this mirror carries ${ARGOCD_VERSION} — re-read dex/redis from that tag's install.yaml"

    while IFS= read -r img; do
        case "${img}" in
            docker.io/calico/*)
                tag="${img##*:}"
                [ "${tag}" = "${CALICO_VERSION}" ] \
                    || die "Calico image ${img} is not at ${CALICO_VERSION}" ;;
        esac
    done < <(image_set)
    dup="$(image_set | while IFS= read -r img; do mirror_path "${img%:*}"; done | sort | uniq -d)"
    [ -z "${dup}" ] || die "two images share one mirror path: ${dup}"
}
check_guards

registries() { image_set | while IFS= read -r img; do registry_of "${img}"; done | sort -u; }
upstream_server() {
    case "$1" in
        docker.io) echo "https://registry-1.docker.io" ;;
        *)         echo "https://$1" ;;
    esac
}

# ── list / --dry-run ─────────────────────────────────────────────────────────
if [ "${MODE}" = "list" ]; then
    echo "registry-mirror PLAN — nothing pulled, nothing written"
    echo "calico : ${CALICO_VERSION} (satisfies ${CALICO_RANGE} in ${CALICO_SPEC#"${REPO_DIR}"/}); operator ${TIGERA_OPERATOR_VERSION}"
    echo "argocd : ${ARGOCD_VERSION} (= ARGOCD_VERSION in ${ARGOCD_BOOTSTRAP#"${REPO_DIR}"/})"
    image_set | while IFS= read -r img; do
        printf 'IMAGE  %-56s -> %s:%s/%s\n' "${img}" "${GUEST_HOST}" "${PORT}" "$(mirror_path "${img}")"
    done
    echo "CHART  tigera-operator ${CALICO_VERSION} (sha256 ${CALICO_CHART_SHA256}) -> oci://${GUEST_HOST}:${PORT}/charts/tigera-operator"
    echo "SERVE  host ${BIND}:${PORT} (container ${NAME}, ${REGISTRY_IMAGE}); guests dial ${GUEST_HOST}:${PORT} over the launcher's user-mode NIC"
    echo "NOTE   --mesh-net is a host-less socket L2: the mirror is NOT reachable over it until a host-side attach exists"
    echo "MIRRORS $(registries | tr '\n' ' ')(containerd hosts.toml via: $0 hosts-toml DIR)"
    echo "RESULT:  DRY-RUN $(image_set | wc -l | tr -d ' ') images + 1 chart (nothing pulled)"
    exit 0
fi

# ── hosts-toml DIR: the guest-side containerd wiring, written locally ────────
if [ "${MODE}" = "hosts-toml" ]; then
    [ -n "${HOSTS_DIR}" ] || die "hosts-toml wants a DIR"
    while IFS= read -r reg; do
        mkdir -p "${HOSTS_DIR}/${reg}" || die "cannot create ${HOSTS_DIR}/${reg}"
        cat > "${HOSTS_DIR}/${reg}/hosts.toml" <<EOF
# containerd mirror for ${reg} -> the host-side registry mirror (issue #516).
# Install under /etc/containerd/certs.d/${reg}/hosts.toml on the guest.
server = "$(upstream_server "${reg}")"

[host."http://${GUEST_HOST}:${PORT}"]
  capabilities = ["pull", "resolve"]
EOF
        info "wrote ${HOSTS_DIR}/${reg}/hosts.toml"
    done < <(registries)
    exit 0
fi

# ── Live modes: docker (and, for up, helm + a copier) ────────────────────────
dkr() { if [ -n "${MIRROR_DOCKER_CMD:-}" ]; then ${MIRROR_DOCKER_CMD} "$@"; else docker "$@"; fi; }
[ -n "${MIRROR_DOCKER_CMD:-}" ] || command -v docker >/dev/null 2>&1 \
    || die "docker is not on PATH — the mirror runs as a registry container (use --dry-run for the list)"

ours() { # true when a container NAME exists AND carries our label
    local v
    v="$(dkr inspect -f '{{index .Config.Labels "hugmesh-qemu-mirror"}}' "${NAME}" 2>/dev/null)" || return 1
    [ "${v}" = "1" ]
}

if [ "${MODE}" = "down" ]; then
    if ours; then
        dkr rm -f "${NAME}" >/dev/null || die "could not remove ${NAME}"
        info "removed ${NAME} (registry data kept under ${STATE_DIR}/registry)"
    elif dkr inspect "${NAME}" >/dev/null 2>&1; then
        die "a container named ${NAME} exists but is NOT this mirror (no ${LABEL} label) — left alone"
    else
        info "no ${NAME} container — nothing to do"
    fi
    exit 0
fi

# MODE = up
hlm() { if [ -n "${MIRROR_HELM_CMD:-}" ]; then ${MIRROR_HELM_CMD} "$@"; else helm "$@"; fi; }
fetch() { # URL OUT
    if [ -n "${MIRROR_FETCH_CMD:-}" ]; then ${MIRROR_FETCH_CMD} "$1" "$2"
    else curl -fsSL --retry 3 "$1" -o "$2"; fi
}
[ -n "${MIRROR_HELM_CMD:-}" ] || command -v helm >/dev/null 2>&1 \
    || die "helm is not on PATH — the tigera-operator chart is pushed into the mirror as an OCI artifact"
[ -n "${MIRROR_FETCH_CMD:-}" ] || command -v curl >/dev/null 2>&1 || die "curl is not on PATH"

COPIER=""
if [ -n "${MIRROR_COPY_CMD:-}" ]; then COPIER="seam"
elif command -v skopeo >/dev/null 2>&1; then COPIER="skopeo"
elif command -v crane >/dev/null 2>&1; then COPIER="crane"
else COPIER="docker"
     info "neither skopeo nor crane found: copying with docker pull/tag/push (HOST ARCHITECTURE ONLY — fine for x86 guests, not for an aarch64 lane)"
fi
copy_image() { # SRC DST
    case "${COPIER}" in
        seam)   ${MIRROR_COPY_CMD} "$1" "$2" ;;
        skopeo) skopeo copy --all --dest-tls-verify=false "docker://$1" "docker://$2" ;;
        crane)  crane copy --insecure "$1" "$2" ;;
        docker) dkr pull "$1" && dkr tag "$1" "$2" && dkr push "$2" ;;
    esac
}

mkdir -p "${STATE_DIR}/registry" "${STATE_DIR}/fetched" || die "cannot create ${STATE_DIR}"

# Every fill-time check runs BEFORE the registry container starts, so a stale
# set leaves nothing running behind it.
chart="${STATE_DIR}/fetched/tigera-operator-${CALICO_VERSION}.tgz"
fetch "${CALICO_CHART_URL}" "${chart}" || die "could not fetch ${CALICO_CHART_URL}"
got="$(sha256sum "${chart}" | awk '{print $1}')"
[ "${got}" = "${CALICO_CHART_SHA256}" ] \
    || die "chart sha256 ${got} != pinned ${CALICO_CHART_SHA256} (${CALICO_CHART_URL})"
opver="$(tar -xzOf "${chart}" tigera-operator/values.yaml 2>/dev/null \
    | awk '/^tigeraOperator:/ {s=1; next} /^[^[:space:]]/ {s=0} s && $1 == "version:" {print $2; exit}')"
[ "${opver}" = "${TIGERA_OPERATOR_VERSION}" ] \
    || die "the chart's values.yaml names operator '${opver}', the mirror carries ${TIGERA_OPERATOR_VERSION}"

# ArgoCD's install.yaml must name nothing the set lacks.
inst="${STATE_DIR}/fetched/argocd-install-${ARGOCD_VERSION}.yaml"
fetch "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" "${inst}" \
    || die "could not fetch ArgoCD ${ARGOCD_VERSION} install.yaml"
missing=""
SET="$(image_set)"
while IFS= read -r want; do
    [ -n "${want}" ] || continue
    # A here-string, not `image_set | grep -q`: under pipefail an early-exiting
    # grep can SIGPIPE the writer and report a FOUND line as missing.
    grep -xF -- "${want}" <<< "${SET}" >/dev/null 2>&1 || missing="${missing} ${want}"
done < <(sed -n 's/^[[:space:]]*image:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}.*/\1/p' "${inst}" | sort -u)
[ -z "${missing}" ] || die "ArgoCD ${ARGOCD_VERSION} install.yaml names image(s) the mirror does not carry:${missing}"

if ours; then
    info "reusing ${NAME}"
    dkr start "${NAME}" >/dev/null 2>&1 || true
elif dkr inspect "${NAME}" >/dev/null 2>&1; then
    die "a container named ${NAME} exists but is NOT this mirror (no ${LABEL} label) — pick another --name"
else
    info "starting ${NAME} on ${BIND}:${PORT}"
    dkr run -d --name "${NAME}" --label "${LABEL}" --restart no \
        -p "${BIND}:${PORT}:5000" -v "${STATE_DIR}/registry:/var/lib/registry" \
        "${REGISTRY_IMAGE}" >/dev/null || die "could not start the registry container"
fi
PUSH_HOST="localhost:${PORT}"
# A fresh registry:2 takes a moment to listen; pushing into a half-started
# container fails with a connection error that reads like a bad image.
tries=0
until fetch "http://${PUSH_HOST}/v2/" "${STATE_DIR}/fetched/.v2-probe" >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "${tries}" -lt 30 ] || die "the registry on ${PUSH_HOST} did not answer /v2/ within 30s"
    sleep 1
done

n=0
while IFS= read -r img; do
    dst="${PUSH_HOST}/$(mirror_path "${img}")"
    info "copy ${img} -> ${dst}"
    copy_image "${img}" "${dst}" || die "copy failed: ${img}"
    n=$((n + 1))
done < <(image_set)
hlm push "${chart}" "oci://${PUSH_HOST}/charts" --plain-http >/dev/null \
    || die "helm push of the tigera-operator chart failed"
image_set > "${STATE_DIR}/served.txt"
echo "chart oci://${GUEST_HOST}:${PORT}/charts/tigera-operator:${CALICO_VERSION}" >> "${STATE_DIR}/served.txt"
info "RESULT: UP ${n} images + 1 chart served on ${BIND}:${PORT} (guests: ${GUEST_HOST}:${PORT}; list in ${STATE_DIR}/served.txt)"

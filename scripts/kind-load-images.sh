#!/usr/bin/env bash
# kind-load-images.sh — build the first-party images the KIND_PROFILE=sso slice
# runs and load them into the kind node under the EXACT refs the rendered
# manifests pull. The cluster manifests rewrite every first-party image to
# registry.hugmesh.net/hugmesh/<repo>:main (kustomize `images:` blocks; the
# gateway chart pins :dev) and reference the in-cluster Harbor — which is empty
# on a fresh kind cluster, so ArgoCD would sit in ImagePullBackOff forever.
# `kind load` places each image directly into the node's containerd store where
# IfNotPresent finds it and no pull (or harbor-registry pull Secret) happens.
#
# Sources come from the SAME ./.stack-src tree the compose stack builds from
# (scripts/clone-all-repos.sh — idempotent clone/update to origin/main), so a
# kind run proves the same code the compose proof runs. `make kind-images`
# drives clone + this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STACK_SRC="${STACK_SRC:-${REPO_ROOT}/.stack-src}"
CLUSTER_NAME="${KIND_CLUSTER_NAME:-hugmesh-local}"
REGISTRY="registry.hugmesh.net/hugmesh"

for bin in docker kind; do
  command -v "${bin}" >/dev/null 2>&1 || { echo "missing required tool: ${bin}" >&2; exit 1; }
done
[ -d "${STACK_SRC}" ] || { echo "STACK_SRC ${STACK_SRC} missing — run 'make stack-clone' first" >&2; exit 1; }

# The three Java images resolve org-private systems.hugmesh artifacts through
# their committed settings.xml (${env.CI_API_V4_URL} group registry) — locally
# that is the m2-bootstrap static-registry container (tests/stack/
# m2-bootstrap.sh writes its bridge address into .m2-registry.env, the same
# file `make stack-build` threads into docker compose). BuildKit is required
# for their optional RUN --mount=type=secret.
export DOCKER_BUILDKIT=1
M2_ENV="${REPO_ROOT}/tests/stack/.m2-registry.env"
M2_ARGS=()
if [ -f "${M2_ENV}" ]; then
  # shellcheck disable=SC1090
  . "${M2_ENV}"
  M2_ARGS=(--build-arg "CI_API_V4_URL=${CI_API_V4_URL}" --build-arg "GITLAB_GROUP_ID=${GITLAB_GROUP_ID}")
else
  echo "WARN: ${M2_ENV} missing — Java builds will fail to resolve systems.hugmesh:*; run 'make stack-m2-bootstrap' first" >&2
fi

# repo dir (under STACK_SRC) -> rendered image ref. Tags mirror the manifests:
# kustomize rewrites first-party images to :main; the hugmesh-gateway chart
# values pin :dev. java=1 marks the builds that need the m2 registry args.
IMAGES=(
  "hugmesh-gateway=${REGISTRY}/hugmesh-gateway:dev=java"
  "hugmesh-user-bff-api=${REGISTRY}/hugmesh-user-bff-api:main=java"
  "hugmesh-admin-bff-api=${REGISTRY}/hugmesh-admin-bff-api:main=java"
  "hugmesh-host-shell=${REGISTRY}/hugmesh.net:main="
  "hugmesh-login-ui=${REGISTRY}/hugmesh-login-ui:main="
  "hugmesh-matrix-ui=${REGISTRY}/hugmesh-matrix-ui:main="
  "hugmesh-mastodon-ui=${REGISTRY}/hugmesh-mastodon-ui:main="
  "hugmesh-admin-ui=${REGISTRY}/hugmesh-admin-ui:main="
)

for triple in "${IMAGES[@]}"; do
  repo="${triple%%=*}"
  rest="${triple#*=}"
  ref="${rest%=*}"
  kind_flag="${rest##*=}"
  ctx="${STACK_SRC}/${repo}"
  [ -d "${ctx}" ] || { echo "source ${ctx} missing — run 'make stack-clone'" >&2; exit 1; }
  echo "==> Building ${ref} from ${ctx}"
  if [ "${kind_flag}" = "java" ]; then
    docker build "${M2_ARGS[@]}" -t "${ref}" "${ctx}"
  else
    docker build -t "${ref}" "${ctx}"
  fi
done

for triple in "${IMAGES[@]}"; do
  rest="${triple#*=}"
  ref="${rest%=*}"
  echo "==> kind load ${ref} -> ${CLUSTER_NAME}"
  kind load docker-image "${ref}" --name "${CLUSTER_NAME}"
done

echo "==> All SSO-slice images loaded into kind cluster '${CLUSTER_NAME}'"

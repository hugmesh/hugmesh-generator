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

# BUILD_NETWORK=host — build with the HOST network stack instead of docker's bridge.
#
# WHY: docker's default bridge is MTU 1500. If the host's default route is a tunnel
# with a smaller MTU — WireGuard is 1420, tailscale 1280 — every build pushes
# 1500-byte frames into it and the oversized ones are black-holed. DNS and small
# GETs still succeed, so the network looks healthy; only large TLS payloads hang,
# and `npm install` dies after ~80s with
#     npm error code ETIMEDOUT
#     npm error network request to https://registry.npmjs.org/... failed
#
# Measured on this host 2026-08-21 (default route wg-IS-US-1, mtu 1420, vs docker0
# mtu 1500):  default bridge 79.5s and FAILING  |  host network 0.42s.
#
# TWO TRAPS worth recording, because both look like the answer and are not:
#  * The DNS answer for registry.npmjs.org is AAAA-only and containers cannot route
#    v6, which makes IPv6 look like the culprit. It is not — forcing
#    NODE_OPTIONS=--dns-result-order=ipv4first still took 79.5s. It is framing, not
#    resolution.
#  * A custom `docker network create --opt com.docker.network.driver.mtu=1420` DOES
#    fix it for `docker run`, but BUILDKIT REJECTS a custom network name:
#      network mode "<name>" not supported by buildkit
#    Only host/none/default are accepted, so `host` is the usable knob here.
#
# Unset, nothing changes and the bridge is used exactly as before.
BUILD_NET_ARGS=()
if [ -n "${BUILD_NETWORK:-}" ]; then
  case "${BUILD_NETWORK}" in
    host|none|default) ;;
    *)
      echo "BUILD_NETWORK='${BUILD_NETWORK}': buildkit accepts only host, none or default." >&2
      echo "  A custom docker network fixes the MTU for 'docker run' but NOT for builds." >&2
      echo "  Use BUILD_NETWORK=host (see the comment above this check)." >&2
      exit 2 ;;
  esac
  BUILD_NET_ARGS=(--network "${BUILD_NETWORK}")
  echo "==> BUILD_NETWORK=${BUILD_NETWORK} (bypasses the docker bridge MTU)"
fi
M2_ENV="${REPO_ROOT}/tests/stack/.m2-registry.env"
M2_ARGS=()
if [ -f "${M2_ENV}" ]; then
  # shellcheck disable=SC1090
  . "${M2_ENV}"
  M2_ARGS=(--build-arg "CI_API_V4_URL=${CI_API_V4_URL}" --build-arg "GITLAB_GROUP_ID=${GITLAB_GROUP_ID}")
else
  echo "WARN: ${M2_ENV} missing — Java builds will fail to resolve systems.hugmesh:*; run 'make stack-m2-bootstrap' first" >&2
fi

# ── assert every Java checkout can actually SEE the private registry ──────────
#
# WHY THIS EXISTS. The three Java images depend on org-private net.hugmesh:*
# artifacts that are not on Maven Central. Nothing in the repos themselves knows
# about the local m2 registry — scripts/patch-stack-src.sh injects that wiring
# into ./.stack-src (a settings.xml `-s` thread for the eight BFF/federation
# repos, a whole ARG+settings injection for hugmesh-gateway, and a same-id
# mirror that neutralises Maven 3.9's http-blocker so a plain-HTTP registry
# resolves at all).
#
# THAT WIRING IS FRAGILE IN ONE SPECIFIC WAY, and it bit this lane on
# 2026-08-21: the patcher's "already patched" markers live in TRACKED files
# (Dockerfile, settings.xml), so any `git pull`/reset of a .stack-src checkout
# silently reverts every injection. The untracked artefact it wrote
# (hugmesh-local-settings.xml) SURVIVES the reset, so the tree looks patched to
# a human while being entirely unpatched to maven. Nine checkouts were in that
# state at once and nothing reported it.
#
# The symptom is maximally misleading — an ELEVEN MINUTE build that dies with
#   Could not find artifact net.hugmesh:hugmesh-commons:jar:2.1.0 in central
# naming only Maven Central, never the local registry, because `-s` was never
# threaded in and the registry was therefore never consulted. It reads like a
# broken dependency; it is a broken checkout.
#
# So: check the wiring in milliseconds and say exactly which command repairs it.
# Positive markers only — a checkout is wired iff its Dockerfile actually threads
# a settings file into maven AND that file exists on disk.
assert_maven_wired() { # <ctx> <repo>
  # NB: separate statements, not one `local a=.. b="${a}".. `. bash 5.3 localises
  # every name in a `local` list BEFORE running any assignment, so a later item
  # referencing an earlier one dies with "unbound variable" under `set -u`.
  local ctx="$1" repo="$2" settings=""
  local df="${ctx}/Dockerfile"
  if grep -q 'hugmesh-local-settings.xml' "${df}"; then
    settings="${ctx}/hugmesh-local-settings.xml"      # patcher-injected (gateway)
  elif grep -qE -- '-s[[:space:]]+settings\.xml' "${df}"; then
    settings="${ctx}/settings.xml"                    # committed (BFF siblings)
  else
    echo "${repo}: Dockerfile threads NO maven settings file, so the private" >&2
    echo "  net.hugmesh:* artifacts can only be looked for on Maven Central and the" >&2
    echo "  build will fail ~11 minutes from now with a misleading 'not in central'." >&2
    echo "  The .stack-src patches were reverted by a git update. Repair with:" >&2
    echo "      bash scripts/patch-stack-src.sh" >&2
    exit 2
  fi
  [ -f "${settings}" ] || {
    echo "${repo}: Dockerfile threads $(basename "${settings}") but that file is missing." >&2
    echo "  Repair with: bash scripts/patch-stack-src.sh" >&2
    exit 2
  }
  # Maven 3.9 ships a `maven-default-http-blocker` mirror that refuses EVERY
  # plain-http repository. The local registry container is plain http by design,
  # so a same-id override must be present or resolution dies even though the
  # repo IS declared. Only assert this when the registry we are pointing at is
  # actually http:// — an https registry (real GitLab CI) needs no override, and
  # demanding one there would be a false alarm.
  case "${CI_API_V4_URL:-}" in
    http://*)
      grep -q 'maven-default-http-blocker' "${settings}" || {
        echo "${repo}: $(basename "${settings}") has no maven-default-http-blocker override," >&2
        echo "  but CI_API_V4_URL=${CI_API_V4_URL} is plain http — maven 3.9 will refuse it." >&2
        echo "  Repair with: bash scripts/patch-stack-src.sh" >&2
        exit 2
      } ;;
  esac
}

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

# ONLY=<repo>[,<repo>...] — rebuild a SUBSET instead of all eight.
#
# Why this exists: iterating on one UI defect meant rebuilding every image,
# including the three Java ones, which dominates the loop and has nothing to do
# with the change. `make kind-images ONLY=hugmesh-host-shell` rebuilds and
# reloads just that one.
#
# FAIL-CLOSED on an unknown name. The tempting implementation — filter and carry
# on — turns a typo into a build that loads NOTHING and still exits 0, so the
# cluster keeps serving the old image while the operator believes they just
# shipped a fix. That failure is silent and expensive; an error is neither.
if [ -n "${ONLY:-}" ]; then
  known=()
  for triple in "${IMAGES[@]}"; do known+=("${triple%%=*}"); done
  selected=()
  IFS=',' read -r -a wanted <<< "${ONLY}"
  for want in "${wanted[@]}"; do
    want="$(echo "${want}" | tr -d '[:space:]')"
    [ -n "${want}" ] || continue
    hit=""
    for triple in "${IMAGES[@]}"; do
      [ "${triple%%=*}" = "${want}" ] && { selected+=("${triple}"); hit=1; break; }
    done
    [ -n "${hit}" ] || {
      echo "ONLY: unknown image '${want}'. Known: ${known[*]}" >&2; exit 2; }
  done
  [ "${#selected[@]}" -gt 0 ] || { echo "ONLY was set but selected nothing" >&2; exit 2; }
  IMAGES=("${selected[@]}")
  # Say what is NOT being rebuilt: a partial build that reads like a full one is
  # how a stale sibling image gets blamed on the change under test.
  echo "==> ONLY=${ONLY}: building ${#IMAGES[@]} of ${#known[@]} image(s)."
  echo "    NOT rebuilt (the cluster keeps whatever it already has):"
  for k in "${known[@]}"; do
    skip=1
    for triple in "${IMAGES[@]}"; do [ "${triple%%=*}" = "${k}" ] && skip=""; done
    [ -n "${skip}" ] && echo "      ${k}"
  done
fi

for triple in "${IMAGES[@]}"; do
  repo="${triple%%=*}"
  rest="${triple#*=}"
  ref="${rest%=*}"
  kind_flag="${rest##*=}"
  ctx="${STACK_SRC}/${repo}"
  [ -d "${ctx}" ] || { echo "source ${ctx} missing — run 'make stack-clone'" >&2; exit 1; }
  echo "==> Building ${ref} from ${ctx}"
  if [ "${kind_flag}" = "java" ]; then
    assert_maven_wired "${ctx}" "${repo}"
    docker build "${BUILD_NET_ARGS[@]}" "${M2_ARGS[@]}" -t "${ref}" "${ctx}"
  else
    docker build "${BUILD_NET_ARGS[@]}" -t "${ref}" "${ctx}"
  fi
done

for triple in "${IMAGES[@]}"; do
  rest="${triple#*=}"
  ref="${rest%=*}"
  echo "==> kind load ${ref} -> ${CLUSTER_NAME}"
  kind load docker-image "${ref}" --name "${CLUSTER_NAME}"
done

echo "==> All SSO-slice images loaded into kind cluster '${CLUSTER_NAME}'"

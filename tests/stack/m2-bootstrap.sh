#!/usr/bin/env bash
# m2-bootstrap.sh — build the PRIVATE systems.hugmesh Maven artifacts FROM
# SOURCE and serve them to `docker compose build` as a GitLab-shaped static
# Maven registry container. This is the COLD-BUILD prerequisite for the four
# Java services whose Dockerfiles resolve org-private artifacts
# (hugmesh-admin-bff-api, hugmesh-user-bff-api, hugmesh-mod-bff-api,
# hugmesh-federation-api): their committed settings.xml resolves
# systems.hugmesh:* from
#   ${env.CI_API_V4_URL}/groups/${env.GITLAB_GROUP_ID}/-/packages/maven
# which exists only in the org's GitLab. On a dev box with no GitLab access
# (or after a docker data-root wipe purged all images), `make stack-up` must
# cold-build those services — this script makes that possible offline-from-
# GitLab: everything is built from PUBLIC org sources (git clone by pinned
# commit), never vendored binaries.
#
# WHAT IT DOES (idempotent, safe to re-run):
#   1. Clones the four library repos at PINNED commits (the org repos carry no
#      git tags, so commits are pinned by SHA — each SHA is the commit whose
#      pom.xml carries exactly the version the services' poms require) into
#      ${M2_CACHE}/src and `mvn install`s them into ${M2_CACHE}/m2/repository
#      using the official maven Docker image (no host JDK/maven needed).
#      Artifacts already present in the cache are SKIPPED (no re-clone/re-build).
#   2. Starts a tiny static-file registry container (busybox httpd) with
#      m2/repository bind-mounted (ro) at /www/groups/<id>/-/packages/maven —
#      i.e. exactly the GitLab group-registry URL shape settings.xml expects.
#      The container lives on the DEFAULT docker bridge: on this class of host,
#      host-bound ports are NOT reachable from build containers, so the
#      registry must be a container and is addressed by its bridge IP.
#   3. Writes tests/stack/.m2-registry.env (gitignored) with CI_API_V4_URL +
#      GITLAB_GROUP_ID. `make stack-up`/`stack-build` auto-include
#      tests/stack/compose.m2-local.yaml + this env file whenever it exists,
#      threading both values as build args into the four services.
#
# The BuildKit half of the cold-build story (the Dockerfiles' RUN
# --mount=type=secret) is handled by the Makefile exporting DOCKER_BUILDKIT=1;
# the secret itself is OPTIONAL in every Dockerfile (guarded `if [ -f
# /run/secrets/ci_job_token ]`), and the static registry ignores auth headers,
# so no token — real or dummy — is ever needed locally.
#
# Env knobs:
#   M2_CACHE        (default ~/.cache/hugmesh-stack-maven) persistent cache:
#                   src/ (pinned clones) + m2/ (maven repo, container-written)
#   GIT_BASE        (default https://github.com/Snapdragon-Systems)
#   MAVEN_IMAGE     (default maven:3.9-eclipse-temurin-25 — the libs target
#                   maven.compiler.release=25)
#   REGISTRY_IMAGE  (default busybox:stable — httpd serves the static tree)
#   REGISTRY_NAME   (default hugmesh-m2-registry)
#   REGISTRY_PORT   (default 8080; in-container, never host-published)
#   GITLAB_GROUP_ID (default 1 — any value works, it only shapes the URL)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

M2_CACHE="${M2_CACHE:-${HOME}/.cache/hugmesh-stack-maven}"
GIT_BASE="${GIT_BASE:-https://github.com/Snapdragon-Systems}"
MAVEN_IMAGE="${MAVEN_IMAGE:-maven:3.9-eclipse-temurin-25}"
REGISTRY_IMAGE="${REGISTRY_IMAGE:-busybox:stable}"
REGISTRY_NAME="${REGISTRY_NAME:-hugmesh-m2-registry}"
REGISTRY_PORT="${REGISTRY_PORT:-8080}"
GITLAB_GROUP_ID="${GITLAB_GROUP_ID:-1}"
M2_ENV_FILE="${M2_ENV_FILE:-${HERE}/.m2-registry.env}"

# ── the pinned build matrix ────────────────────────────────────────────────────
# repo | commit SHA | artifactId | version | expected files (pom|jar|jar+tests)
#
# Version pins mirror what the SERVICES' current main poms require:
#   hugmesh-parent    2.7.0  — every Java service's <parent>
#   hugmesh-build-config 0.3.0 — managed by parent 2.7.0
#   hugmesh-commons   2.0.0  — incl. the -tests classifier jar (admin-bff's
#                                 test scope compiles against it even with
#                                 -DskipTests, which skips execution only)
#   hugmesh-auth-core 2.3.3  — user-bff-api main            (pre-PR#33 commit)
#   hugmesh-auth-core 2.3.4  — admin-bff-api main (auth-core PR#33, 2026-07-15)
# The org repos have NO git tags, hence SHA pins. Order matters: parent first
# (everything else's <parent>), then build-config/commons, then auth-core.
PINS=(
  "hugmesh-parent|989b2ab47699a408e88202ea01ab634f6be992d3|hugmesh-parent|2.7.0|pom"
  "hugmesh-build-config|7ef187d6d8b00761b2ab6f5f8e0b6f23851b32b8|hugmesh-build-config|0.3.0|jar"
  "hugmesh-commons|2f2768669302497e0c54638e7a9d093460723b13|hugmesh-commons|2.0.0|jar+tests"
  "hugmesh-auth-core|666f07bb2e4be03a0d46ce30cb52dac5599d86f4|hugmesh-auth-core|2.3.3|jar"
  "hugmesh-auth-core|792b8e11781c963f331ca67896c1071d57223475|hugmesh-auth-core|2.3.4|jar"
)

M2_REPO="${M2_CACHE}/m2/repository"
SRC_DIR="${M2_CACHE}/src"
SETTINGS="${M2_CACHE}/m2/settings-docker.xml"

mkdir -p "${SRC_DIR}" "${M2_CACHE}/m2"

# Maven settings used INSIDE the maven container: pin localRepository to the
# bind-mounted cache (/usr/share/maven/ref/repository — the maven image's
# reference-repo convention) so installs land in ${M2_CACHE}/m2/repository.
if [ ! -f "${SETTINGS}" ]; then
  cat > "${SETTINGS}" <<'EOF'
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
  xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0
                      https://maven.apache.org/xsd/settings-1.0.0.xsd">
  <localRepository>/usr/share/maven/ref/repository</localRepository>
</settings>
EOF
  echo "==> wrote ${SETTINGS}"
fi

have_artifact() { # artifactId version kind(pom|jar|jar+tests)
  local base="${M2_REPO}/systems/hugmesh/$1/$2/$1-$2"
  [ -f "${base}.pom" ] || return 1
  case "$3" in
    pom)       : ;;
    jar)       [ -f "${base}.jar" ] || return 1 ;;
    jar+tests) [ -f "${base}.jar" ] && [ -f "${base}-tests.jar" ] || return 1 ;;
  esac
}

ensure_src_at() { # repo sha -> checkout ${SRC_DIR}/<repo> at <sha> (detached)
  local dir="${SRC_DIR}/$1" sha="$2"
  if [ ! -d "${dir}/.git" ]; then
    git init -q "${dir}"
    git -C "${dir}" remote add origin "${GIT_BASE}/$1.git"
  fi
  if [ "$(git -C "${dir}" rev-parse HEAD 2>/dev/null || true)" = "${sha}" ]; then
    return 0
  fi
  echo "    fetching $1@${sha:0:12}"
  git -C "${dir}" fetch -q --depth 1 origin "${sha}"
  git -C "${dir}" checkout -q --detach "${sha}"
}

build_one() { # repo -> mvn install from ${SRC_DIR}/<repo> into the cached m2
  local dir="${SRC_DIR}/$1"
  # The container runs as root and writes the cache's m2/repository (root-owned
  # on disk — expected; the registry serves it read-only and the idempotency
  # probe above only needs world-read). -DskipTests skips test EXECUTION only:
  # test classes still compile, so commons' test-jar classifier is produced.
  docker run --rm \
    -v "${M2_CACHE}/m2:/usr/share/maven/ref" \
    -v "${dir}:/work" -w /work \
    "${MAVEN_IMAGE}" \
    mvn -B -ntp -s /usr/share/maven/ref/settings-docker.xml install -DskipTests
}

echo "==> Private-maven bootstrap (cache: ${M2_CACHE})"
built=0 skipped=0
for pin in "${PINS[@]}"; do
  IFS='|' read -r repo sha artifact version kind <<< "${pin}"
  if have_artifact "${artifact}" "${version}" "${kind}"; then
    echo "  == ${artifact} ${version}: already in the m2 cache (skipping clone+build)"
    skipped=$((skipped+1))
    continue
  fi
  echo "  ++ ${artifact} ${version}: building from source (${repo}@${sha:0:12})"
  ensure_src_at "${repo}" "${sha}"
  build_one "${repo}"
  have_artifact "${artifact}" "${version}" "${kind}" || {
    echo "ERROR: build finished but ${artifact} ${version} (${kind}) is still missing from ${M2_REPO}" >&2
    exit 1
  }
  built=$((built+1))
done
echo "==> Artifacts: ${built} built, ${skipped} already cached"

# ── the registry container ─────────────────────────────────────────────────────
# Keep an already-running registry (the bind mount picks up new artifacts live —
# and its bridge IP stays stable); (re)create it otherwise.
if [ "$(docker inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || true)" != "true" ]; then
  docker rm -f "${REGISTRY_NAME}" >/dev/null 2>&1 || true
  echo "==> Starting registry container ${REGISTRY_NAME} (${REGISTRY_IMAGE})"
  docker run -d --name "${REGISTRY_NAME}" --restart unless-stopped \
    -v "${M2_REPO}:/www/groups/${GITLAB_GROUP_ID}/-/packages/maven:ro" \
    "${REGISTRY_IMAGE}" httpd -f -p "${REGISTRY_PORT}" -h /www >/dev/null
else
  echo "==> Registry container ${REGISTRY_NAME} already running (kept)"
fi

# Range over Networks: newer docker engines no longer populate the legacy
# top-level .NetworkSettings.IPAddress key (map has no entry on docker 29).
REGISTRY_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${REGISTRY_NAME}")"
if [ -z "${REGISTRY_IP}" ]; then
  echo "ERROR: could not determine the registry container's bridge IP" >&2
  exit 1
fi
CI_API_V4_URL="http://${REGISTRY_IP}:${REGISTRY_PORT}"

# Self-check: the exact URL shape the services' settings.xml will GET.
CHECK_URL="${CI_API_V4_URL}/groups/${GITLAB_GROUP_ID}/-/packages/maven/systems/hugmesh/hugmesh-parent/2.7.0/hugmesh-parent-2.7.0.pom"
for _ in 1 2 3 4 5; do
  curl -sf -o /dev/null "${CHECK_URL}" && break
  sleep 1
done
curl -sf -o /dev/null "${CHECK_URL}" || {
  echo "ERROR: registry self-check failed: ${CHECK_URL}" >&2
  exit 1
}
echo "==> Registry self-check OK: ${CHECK_URL}"

# ── the env file compose interpolates the build args from ─────────────────────
{
  echo "# Generated by tests/stack/m2-bootstrap.sh — GITIGNORED, do not commit."
  echo "# Consumed by 'make stack-up'/'stack-build' via --env-file together with"
  echo "# tests/stack/compose.m2-local.yaml. Re-run 'make stack-m2-bootstrap' if"
  echo "# docker restarted (the registry bridge IP may change)."
  echo "CI_API_V4_URL=${CI_API_V4_URL}"
  echo "GITLAB_GROUP_ID=${GITLAB_GROUP_ID}"
} > "${M2_ENV_FILE}"
echo "==> Wrote ${M2_ENV_FILE}"
echo "==> Done. 'make stack-up' now auto-includes the m2 override for cold builds."

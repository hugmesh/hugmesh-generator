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
# Version pins mirror what the SERVICES' current main poms require (all four BFFs
# resolve systems.hugmesh:hugmesh-parent:2.8.0 after the Snapdragon->HugMesh rebrand;
# these SHAs are each sibling repo's current main, whose pom declares exactly the
# systems.hugmesh:* coordinate+version below — the pre-rebrand pins built
# systems.snapdragon:*@2.7.0 which no longer matches have_artifact's hugmesh path):
#   hugmesh-build-config 0.5.0 — parent's PMD/spotbugs ruleset plugin dep. It has NO
#                                 <parent> of its own, so it BUILDS FIRST (standalone).
#   hugmesh-parent    2.8.0  — every Java service's <parent>; its own build resolves
#                                 hugmesh-build-config, so build-config MUST precede it.
#   hugmesh-commons   2.1.0  — incl. the -tests classifier jar (admin-bff's test scope
#                                 compiles against it even with -DskipTests).
#   hugmesh-auth-core 2.4.2  — user-bff + admin-bff main. 2.4.2 = auth-core #42
#                                 (release re-pin after the MFA fixes #39-#41; the
#                                 2.4.2 coordinate exists BECAUSE 2.4.x-old was
#                                 published mutable — see that PR). This pin has now
#                                 drifted twice the same way (2.4.0 -> 2.4.1 ->
#                                 2.4.2): the consumers bump, the cold build dies at
#                                 user-bff with "Could not find artifact
#                                 systems.hugmesh:hugmesh-auth-core:jar:<new> in
#                                 gitlab-maven". tests/stack/test-m2-bootstrap.sh's
#                                 pin-drift guard exists for exactly this — keep it
#                                 in CI and run it after every auth-core release.
# The org repos have NO git tags, hence SHA pins. Order matters: build-config FIRST
# (parent's plugin dep), then parent (everything else's <parent>), then commons/auth-core.
PINS=(
  "hugmesh-build-config|7f5f643d8f08ced145569d3a9db6b4be8849516f|hugmesh-build-config|0.5.0|jar"
  "hugmesh-parent|389f34e98c6da846b21bda9e1553cf1418dc92eb|hugmesh-parent|2.8.0|pom"
  "hugmesh-commons|4eaeb58876fb389f8929caff99aae3a06de22586|hugmesh-commons|2.1.0|jar+tests"
  "hugmesh-auth-core|b50696be9ad769515c2bda7f5b29420f110a65dc|hugmesh-auth-core|2.4.2|jar"
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
  #
  # -Dhugmesh.analysis.skip=true is the parent POM's OWN single switch for the
  # spotbugs/pmd/checkstyle gates (all three use <skip>${hugmesh.analysis.skip}</skip>);
  # the standard per-plugin skip properties are IGNORED because the parent hardcodes
  # <skip> to this property. This is a cache-population build reproducing the artifacts
  # the org registry would serve — re-running a dependency's quality gates here is wrong
  # (and auth-core 2.4.0 has 8 latent spotbugs findings that would fail the cold-build).
  #
  # KEEP THIS COMMENT BLOCK ABOVE THE COMMAND. It used to sit BETWEEN the image
  # argument and `mvn`, inside the backslash continuation — which silently broke
  # cold bring-up entirely. A `\` continuation joins the next line, and that line
  # began with `#`, so bash read:
  #     docker run --rm -v … -v … -w /work "${MAVEN_IMAGE}"   # comment…
  # i.e. the container launched with NO mvn command (it ran the image's default
  # CMD), the logical line ENDED at the comment, and the `mvn … install` lines
  # below then executed as a SEPARATE command ON THE HOST — against
  # /usr/share/maven/ref/settings-docker.xml, a path that exists only inside the
  # container. Reproduced verbatim with stub docker/mvn (and /usr/bin/mvn IS
  # present on this host, so it really did run):
  #     DOCKER:--rm maven:image        HOSTMVN:-B install
  # So build_one could never populate the cache, `make stack-m2-bootstrap`
  # produced no artifacts, and every COLD `make stack-up` then failed at the
  # first private-maven consumer. `bash -n` does not catch this — it is valid
  # bash that means something else. tests/stack/test-m2-bootstrap.sh pins the
  # shape here AND lints the whole repo for the same class.
  docker run --rm \
    -v "${M2_CACHE}/m2:/usr/share/maven/ref" \
    -v "${dir}:/work" -w /work \
    "${MAVEN_IMAGE}" \
    mvn -B -ntp -s /usr/share/maven/ref/settings-docker.xml install -DskipTests \
        -Dhugmesh.analysis.skip=true
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
# The artifacts live in ${M2_REPO} on the HOST (mounted :ro); the container itself
# is stateless and disposable, so recreating it is always safe (loses nothing).
_start_registry() { # force-(re)create a fresh container from ${M2_REPO}
  docker rm -f "${REGISTRY_NAME}" >/dev/null 2>&1 || true
  echo "==> Starting registry container ${REGISTRY_NAME} (${REGISTRY_IMAGE})"
  # The empty-bind guard, NOT paranoia — a reboot reproduces it deterministically:
  # dockerd honours --restart unless-stopped within seconds of boot, BEFORE a
  # late-mounting /home (its own filesystem here) is up, so the bind grabs the
  # EMPTY underlay directory and the registry serves 404s for everything. Content
  # appearing on the real /home later never reaches the container: the bind was
  # resolved at container START. Waiting inside would therefore wait forever —
  # instead EXIT, so the restart policy retries; each retry re-resolves the bind,
  # and the first one after /home lands serves the real artifacts.
  docker run -d --name "${REGISTRY_NAME}" --restart unless-stopped \
    -v "${M2_REPO}:/www/groups/${GITLAB_GROUP_ID}/-/packages/maven:ro" \
    "${REGISTRY_IMAGE}" sh -c "\
      if [ -z \"\$(ls -A /www/groups/${GITLAB_GROUP_ID}/-/packages/maven 2>/dev/null)\" ]; then \
        echo 'bind mount is EMPTY (is /home mounted yet?) — exiting so the restart policy re-binds'; \
        exit 1; \
      fi; \
      exec httpd -f -p ${REGISTRY_PORT} -h /www" >/dev/null
}
# Range over Networks: newer docker engines no longer populate the legacy
# top-level .NetworkSettings.IPAddress key (map has no entry on docker 29).
_registry_ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${REGISTRY_NAME}"; }
# Self-check the EXACT URL shape the services' settings.xml will GET (5 quick tries).
CHECK_PATH="groups/${GITLAB_GROUP_ID}/-/packages/maven/systems/hugmesh/hugmesh-parent/2.8.0/hugmesh-parent-2.8.0.pom"
_registry_serves() { # $1 = base http://IP:PORT ; returns 0 iff the parent POM is served
  local _; for _ in 1 2 3 4 5; do curl -sf -o /dev/null "$1/${CHECK_PATH}" && return 0; sleep 1; done; return 1
}

# Keep an already-running registry (the bind mount picks up new artifacts live, and
# its bridge IP stays stable); (re)create it otherwise.
kept_registry=false
if [ "$(docker inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || true)" != "true" ]; then
  _start_registry
else
  echo "==> Registry container ${REGISTRY_NAME} already running (kept)"
  kept_registry=true
fi

_resolve_ip() { # sets REGISTRY_IP + CI_API_V4_URL, or exits
  REGISTRY_IP="$(_registry_ip)"
  if [ -z "${REGISTRY_IP}" ]; then
    echo "ERROR: could not determine the registry container's bridge IP" >&2
    exit 1
  fi
  CI_API_V4_URL="http://${REGISTRY_IP}:${REGISTRY_PORT}"
}
_resolve_ip

# A KEPT container that cannot serve the cached artifacts is stale — almost always
# its bind mount and/or bridge IP went stale across a docker DAEMON restart (the
# --restart container comes back up, but the IP the last bootstrap recorded in
# .m2-registry.env — and sometimes the mount — no longer hold). Recreate it ONCE
# (host artifacts are untouched) and re-check, rather than hard-failing and forcing
# the operator to `docker rm -f ${REGISTRY_NAME}` by hand.
if ! _registry_serves "${CI_API_V4_URL}"; then
  if [ "${kept_registry}" = true ]; then
    echo "==> Kept registry failed its self-check (stale after a docker restart?) — recreating once…" >&2
    _start_registry
    _resolve_ip
  fi
  _registry_serves "${CI_API_V4_URL}" || {
    echo "ERROR: registry self-check failed: ${CI_API_V4_URL}/${CHECK_PATH}" >&2
    exit 1
  }
fi
echo "==> Registry self-check OK: ${CI_API_V4_URL}/${CHECK_PATH}"

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

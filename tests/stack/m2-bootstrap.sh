#!/usr/bin/env bash
# m2-bootstrap.sh — build the PRIVATE net.hugmesh Maven artifacts FROM
# SOURCE and serve them to `docker compose build` as a GitLab-shaped static
# Maven registry container. This is the COLD-BUILD prerequisite for the four
# Java services whose Dockerfiles resolve org-private artifacts
# (hugmesh-admin-bff-api, hugmesh-user-bff-api, hugmesh-mod-bff-api,
# hugmesh-federation-api): their committed settings.xml resolves
# net.hugmesh:* from
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
#   GIT_BASE        (default https://github.com/hugmesh)
#   MAVEN_IMAGE     (default maven:3.9-eclipse-temurin-25 — the libs target
#                   maven.compiler.release=25)
#   REGISTRY_IMAGE  (default busybox:stable — httpd serves the static tree)
#   REGISTRY_NAME   (default hugmesh-m2-registry)
#   REGISTRY_PORT   (default 8080; in-container, never host-published)
#   GITLAB_GROUP_ID (default 1 — any value works, it only shapes the URL)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

M2_CACHE="${M2_CACHE:-${HOME}/.cache/hugmesh-stack-maven}"
GIT_BASE="${GIT_BASE:-https://github.com/hugmesh}"
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
# resolve net.hugmesh:hugmesh-parent:2.8.0 after the HugMesh rebrand;
# these SHAs are each sibling repo's current main, whose pom declares exactly the
# net.hugmesh:* coordinate+version below — the pre-rebrand pins built
# the retired coordinate at @2.7.0, which no longer matches have_artifact's hugmesh path):
#   hugmesh-build-config 0.5.0 — parent's PMD/spotbugs ruleset plugin dep. It has NO
#                                 <parent> of its own, so it BUILDS FIRST (standalone).
#   hugmesh-parent    2.8.0  — every Java service's <parent>; its own build resolves
#                                 hugmesh-build-config, so build-config MUST precede it.
#   hugmesh-commons   2.1.0  — incl. the -tests classifier jar (admin-bff's test scope
#                                 compiles against it even with -DskipTests).
#   hugmesh-auth-core 2.4.2  — user-bff main. 2.4.2 = auth-core #42
#                                 (release re-pin after the MFA fixes #39-#41; the
#                                 2.4.2 coordinate exists BECAUSE 2.4.x-old was
#                                 published mutable — see that PR).
#   hugmesh-auth-core 2.5.0  — admin-bff main (auth-core PR #12, tip of auth-core
#                                 main; its pom.xml declares
#                                 net.hugmesh:hugmesh-auth-core:2.5.0). 2.5.0 adds the
#                                 DOMAIN-SCOPED registration gate (auth-core issue #1 /
#                                 PR #8) that admin-bff's RegistrationDomainResolver
#                                 call sites now require.
#
#   TWO auth-core pins IS THE CORRECT STATE, not a leftover. The consumers are
#   separate repos on separate release cadences: admin-bff main asks for 2.5.0 and
#   user-bff main still asks for 2.4.2, so a cold build needs BOTH jars in the local
#   registry — dropping 2.4.2 would move the breakage from admin-bff to user-bff.
#   The PINS loop and have_artifact are both per-(artifact,version), so the same repo
#   appearing twice at two SHAs simply builds twice (ensure_src_at re-detaches).
#
#   THIS ARTIFACT HAS NOW DRIFTED FOUR TIMES THE SAME WAY (2.4.0 -> 2.4.1 -> 2.4.2 ->
#   2.5.0): the consumer bumps, the cold build dies with "Could not find artifact
#   net.hugmesh:hugmesh-auth-core:jar:<new> in gitlab-maven". The 2.5.0 round is the
#   one that proved the guard itself was blind — tests/stack/test-m2-bootstrap.sh's
#   pin-drift walker still filtered on the RETIRED groupId `systems.hugmesh` after the
#   rebrand moved every consumer pom to `net.hugmesh`, so with a fully populated
#   .stack-src it resolved ZERO coordinates and printed "every sibling-requested
#   version matches its pin". Keep that guard in CI and run it after every auth-core
#   release; the group it filters on is now DERIVED from this table's last field.
# The org repos have NO git tags, hence SHA pins. Order matters: build-config FIRST
# (parent's plugin dep), then parent (everything else's <parent>), then commons/auth-core.
PINS=(
  "hugmesh-build-config|5c02b991b5cde3957f0bb41679411596c467c7c3|hugmesh-build-config|0.5.0|jar|net/hugmesh"
  "hugmesh-parent|c31d9dc0998b901d73d900949ae207907cb5f524|hugmesh-parent|2.8.0|pom|net/hugmesh"
  # hugmesh-commons SHA bumped 2026-08-13 (5a48f7e: idempotent ROLE_ prefix in
  # CasdoorAuthorities — without it every hasRole() on the four resource-server
  # BFFs answered 403 because seeded Casdoor roles are literally named ROLE_*).
  # SAME VERSION 2.1.0, new bytes: consumer poms and the parent's managed
  # version both pin 2.1.0, and bumping to 2.1.1 would fan out through
  # hugmesh-parent + every consumer pom. On THIS throwaway local registry the
  # honest path is: delete the stale 2.1.0 from ${M2_CACHE} and re-run this
  # script (have_artifact skips by version, so a stale cache otherwise wins),
  # then rebuild consumers with --no-cache (their go-offline Docker layer holds
  # the OLD jar bytes otherwise).
  "hugmesh-commons|156b7687db7cb4287db73708d46404a8cb685b3f|hugmesh-commons|2.1.0|jar+tests|net/hugmesh"
  "hugmesh-auth-core|401ca9e38168791e5642125d96dd1f65487b8ff1|hugmesh-auth-core|2.4.2|jar|net/hugmesh"
  "hugmesh-auth-core|1578565de8c54f4358ef3f172ff95767223f3746|hugmesh-auth-core|2.5.0|jar|net/hugmesh"
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

have_artifact() { # artifactId version kind(pom|jar|jar+tests) groupPath
  # groupPath is passed per-artifact and NOT assumed. hugmesh-commons moved to
  # net.hugmesh first (completing the .net domain move) while build-config/
  # parent/auth-core still published as systems.hugmesh, so for a while the four
  # pins genuinely spanned TWO groups; all four are net.hugmesh today. Hard-coding
  # one group here made the script report a SUCCESSFUL build as "still missing",
  # because it looked for the jar under the group the artifact no longer
  # publishes to — keep this per-artifact so the next split cannot repeat it.
  local base="${M2_REPO}/${4}/$1/$2/$1-$2"
  [ -f "${base}.pom" ] || return 1
  case "$3" in
    pom)       : ;;
    jar)       [ -f "${base}.jar" ] || return 1 ;;
    jar+tests) [ -f "${base}.jar" ] && [ -f "${base}-tests.jar" ] || return 1 ;;
  esac
}

# M2_CHECK_PINS=1 — CHECK-ONLY MODE (used by `make stack-m2-check`). Answers one
# question and touches nothing: does the m2 cache hold EVERY artifact in PINS?
# Prints each missing coordinate and exits 1, or exits 0. Without it the compose
# lane re-ran this script only when the registry container was down or had moved
# IP, so a PINS bump (auth-core 2.5.0 being the live example) was never built on a
# box whose registry was already up, and `make stack-up` died on
# `Could not find artifact ...` until someone ran stack-m2-bootstrap by hand.
if [ "${M2_CHECK_PINS:-}" = "1" ]; then
  _missing=0
  for _pin in "${PINS[@]}"; do
    IFS='|' read -r _repo _sha _artifact _version _kind _group <<< "${_pin}"
    if ! have_artifact "${_artifact}" "${_version}" "${_kind}" "${_group}"; then
      echo "missing from ${M2_REPO}: ${_group}:${_artifact}:${_version} (${_kind})"
      _missing=$((_missing+1))
    fi
  done
  [ "${_missing}" -eq 0 ]
  exit $?
fi

ensure_src_at() { # repo sha -> checkout ${SRC_DIR}/<repo> at <sha> (detached)
  local dir="${SRC_DIR}/$1" sha="$2"
  if [ ! -d "${dir}/.git" ]; then
    git init -q "${dir}"
    git -C "${dir}" remote add origin "${GIT_BASE}/$1.git"
  fi
  # RECONCILE the remote on EVERY call, not just at clone time. The cache is
  # long-lived and GIT_BASE moved to github.com/hugmesh during the org move;
  # a clone created under the old base kept pointing there
  # forever, so pins from the NEW org could never be fetched and the failure read
  # as "not our ref <sha>" — a sha the new org's main was literally at. That took
  # down every Java image build, i.e. the local mesh could not build at all
  # (operator report 2026-08-14). Cheap, idempotent, and it makes the cache
  # follow GIT_BASE the way callers already assume it does.
  git -C "${dir}" remote set-url origin "${GIT_BASE}/$1.git"
  if [ "$(git -C "${dir}" rev-parse HEAD 2>/dev/null || true)" = "${sha}" ]; then
    return 0
  fi
  echo "    fetching $1@${sha:0:12}"
  # A BARE-SHA want is not universally served. GitHub refuses it unless the repo
  # enables uploadpack.allowReachableSHA1InWant, answering
  #   fatal: remote error: upload-pack: not our ref <sha>
  # EVEN WHEN the sha is the tip of main (verified: git ls-remote showed the exact
  # pinned sha on refs/heads/main while this fetch failed). That broke the whole
  # bootstrap — and with it every Java image, i.e. the local mesh could not build
  # at all (operator report 2026-08-14).
  #
  # So: try the cheap shallow SHA fetch, and fall back to fetching the branches
  # and checking the pinned sha out of them. The fallback is NOT shallow on
  # purpose — a --depth 1 branch fetch only carries each tip, so a pin that is
  # not currently a tip would still be missing, which is exactly the case a pin
  # exists to survive.
  if ! git -C "${dir}" fetch -q --depth 1 origin "${sha}" 2>/dev/null; then
    echo "    (bare-sha fetch refused by the server — fetching refs instead)"
    # The refused attempt can leave the clone SHALLOW, and a plain ref fetch into
    # a shallow clone still lacks the pinned commit's tree ("fatal: unable to read
    # tree"). Deepen when shallow — including a clone left shallow by an EARLIER
    # failed run, which is why this tests the repo's state rather than this run's.
    if [ "$(git -C "${dir}" rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
      git -C "${dir}" fetch -q --tags --unshallow origin '+refs/heads/*:refs/remotes/origin/*' \
        || git -C "${dir}" fetch -q --tags origin '+refs/heads/*:refs/remotes/origin/*'
    else
      git -C "${dir}" fetch -q --tags origin '+refs/heads/*:refs/remotes/origin/*'
    fi
  fi
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
  # `clean` is NOT decoration. This builds in the PERSISTENT per-repo directory
  # ${M2_CACHE}/src/<repo>, and since 2026-09-06 hugmesh-auth-core is pinned TWICE
  # (2.4.2 and 2.5.0, because admin-bff main and user-bff main are on different
  # releases). A cold run therefore re-detaches that one directory to the second
  # SHA and rebuilds it IN PLACE. Without `clean`, a class DELETED or RENAMED
  # between the two pinned SHAs survives in target/classes from the first build
  # and is packaged into the SECOND jar — a stale-class artifact that nothing
  # downstream can see, because the jar exists, has the right coordinate, and
  # `have_artifact` only checks that it is there. (Measured on today's two SHAs,
  # 401ca9e..1578565d is 6 added + 6 modified files with zero deletes/renames, so
  # the hazard is inert RIGHT NOW — inert by accident of that delta, not by
  # construction, which is exactly the kind of safety that stops being true
  # without anyone noticing.) The cost is nil in the common path: have_artifact
  # skips build_one entirely whenever the artifact is already cached, so this
  # only ever runs on a build that was going to be cold anyway.
  # tests/stack/test-m2-bootstrap.sh control (xiii) demands `clean` for as long as
  # any repo carries more than one pin.
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
    mvn -B -ntp -s /usr/share/maven/ref/settings-docker.xml clean install -DskipTests \
        -Dhugmesh.analysis.skip=true
}

echo "==> Private-maven bootstrap (cache: ${M2_CACHE})"
built=0 skipped=0
for pin in "${PINS[@]}"; do
  IFS='|' read -r repo sha artifact version kind group <<< "${pin}"
  if have_artifact "${artifact}" "${version}" "${kind}" "${group}"; then
    echo "  == ${artifact} ${version}: already in the m2 cache (skipping clone+build)"
    skipped=$((skipped+1))
    continue
  fi
  echo "  ++ ${artifact} ${version}: building from source (${repo}@${sha:0:12})"
  ensure_src_at "${repo}" "${sha}"
  build_one "${repo}"
  have_artifact "${artifact}" "${version}" "${kind}" "${group}" || {
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
# DERIVED FROM THE PIN, not restated. The hardcoded path still said `systems/hugmesh`
# after the Maven coordinates moved to `net/hugmesh` (the groupIds lagged the Java package
# move), so this probed a path nothing publishes and the self-check could NEVER pass:
# every cold bootstrap hit `exit 1` below -- and, when a healthy registry was being reused,
# needlessly tore it down and recreated it first before failing anyway.
#
# The parent POM is the right subject: it is what every service resolves first. Reading its
# coordinates out of PINS means a future rename moves the probe with it.
_check_path_from_pins() {
  local entry _repo _sha aid ver _pack gpath
  for entry in "${PINS[@]}"; do
    IFS='|' read -r _repo _sha aid ver _pack gpath <<<"${entry}"
    [ "${aid}" = "hugmesh-parent" ] || continue
    printf 'groups/%s/-/packages/maven/%s/%s/%s/%s-%s.pom' \
      "${GITLAB_GROUP_ID}" "${gpath}" "${aid}" "${ver}" "${aid}" "${ver}"
    return 0
  done
  return 1
}
CHECK_PATH="$(_check_path_from_pins)" || {
  echo "ERROR: no hugmesh-parent entry in PINS — cannot build the registry self-check URL" >&2
  exit 1
}
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

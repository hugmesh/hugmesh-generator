# Custom Akkoma image — upstream Akkoma + the Snapdragon ForceLocalForUsers MRF
# compiled in. This is the AUTHORITATIVE Mastodon-side leg of domain-lock: a plain
# akkoma:stable cannot enforce per-actor local-only delivery, so we ship a derived
# image with the custom MRF module baked into the release.
#
# ───────────────────────────────── AGPL ──────────────────────────────────────
# Akkoma is AGPL-3.0. This image is a DERIVATIVE WORK. Per AGPL §13 (network use),
# the complete corresponding source of the running server MUST be offered to every
# network user. The build therefore MUST:
#   1. pin the exact upstream Akkoma source ref (the digest below + its git tag),
#   2. publish THIS overlay (the Dockerfile + mrf/force_local_for_users_policy.ex),
#   3. surface an in-app source offer (a SOURCE_URL / repo link).
# See docs/DOMAIN-LOCK.md "AGPL source publication" for the publish checklist.
#
# ──────────────────────────────── PIN THE BASE ───────────────────────────────
# The base MUST be a pinned DIGEST (the prod-hygiene gate forbids floating
# :stable/:latest). Replace the placeholder digest below with the real
# `git.akkoma.dev/akkomagang/akkoma@sha256:...` for the chosen release, and keep
# AKKOMA_SOURCE_REF in lock-step (it is what the AGPL source offer points at).
#
# !!! SKELETON: the exact build layout of the upstream image (whether it ships a
# !!! compiled OTP release vs. a source tree, and the recompile incantation) is
# !!! version-specific. Two strategies are sketched below; pick the one matching
# !!! the pinned base and VALIDATE the recompile before production. The bake step
# !!! in build-x86-host-stage4.sh builds + pushes this to the registry.
ARG AKKOMA_BASE=git.akkoma.dev/akkomagang/akkoma@sha256:REPLACE_WITH_PINNED_AKKOMA_DIGEST
ARG AKKOMA_SOURCE_REF=REPLACE_WITH_AKKOMA_GIT_TAG

# ── Strategy A (source image): drop the module into the source tree and recompile
#    the release. Use when the pinned base is the Akkoma BUILD/source image. ──────
FROM ${AKKOMA_BASE} AS build
ARG AKKOMA_SOURCE_REF
LABEL org.opencontainers.image.title="snapdragon-akkoma" \
      org.opencontainers.image.description="Akkoma + ForceLocalForUsers MRF (domain-lock)" \
      org.opencontainers.image.licenses="AGPL-3.0-only" \
      systems.snapdragon.akkoma.source-ref="${AKKOMA_SOURCE_REF}"

# Akkoma source root inside the upstream image (commonly /opt/akkoma or the build
# /usr/src/akkoma — confirm for the pinned base).
ARG AKKOMA_SRC=/opt/akkoma

# Layer the custom MRF into the ActivityPub MRF source dir so `mix compile` /
# `mix release` picks it up. The module's defmodule namespace
# (Pleroma.Web.ActivityPub.MRF.ForceLocalForUsersPolicy) determines the path.
COPY mrf/force_local_for_users_policy.ex \
     ${AKKOMA_SRC}/lib/pleroma/web/activity_pub/mrf/force_local_for_users_policy.ex

# Recompile the release with the new module compiled in. (For an OTP-release base
# that ships NO source, switch to Strategy B below — recompiling needs the source
# image. Confirm MIX_ENV + the release task name for the pinned tag.)
WORKDIR ${AKKOMA_SRC}
RUN set -eux; \
    if command -v mix >/dev/null 2>&1; then \
      export MIX_ENV=prod; \
      mix deps.get --only prod || true; \
      mix compile; \
      mix release --overwrite; \
    else \
      echo "!!! base is a runtime/OTP-release image with no mix — use Strategy B (build stage from the akkoma source image)"; \
      exit 1; \
    fi

# ── Final runtime image = the recompiled release. ─────────────────────────────
# For a multi-stage build off a separate runtime base, COPY the built release out
# of `build` here. When the pinned base is itself the runtime+source image, the
# recompiled release above IS the final image and this can collapse to `build`.
FROM ${AKKOMA_BASE}
ARG AKKOMA_SOURCE_REF
LABEL org.opencontainers.image.licenses="AGPL-3.0-only" \
      systems.snapdragon.akkoma.source-ref="${AKKOMA_SOURCE_REF}"
COPY --from=build /opt/akkoma/_build /opt/akkoma/_build
COPY --from=build /opt/akkoma/lib/pleroma/web/activity_pub/mrf/force_local_for_users_policy.ex \
                  /opt/akkoma/lib/pleroma/web/activity_pub/mrf/force_local_for_users_policy.ex
# In-app AGPL source offer (a /static or env the instance surfaces to users).
ENV AKKOMA_SOURCE_URL="https://github.com/Snapdragon-Systems/snapdragon-generator/tree/main/specs/cluster/manifests/akkoma"

# syntax=docker/dockerfile:1
# hugmesh-akkoma: Akkoma built from upstream source at a pinned commit, with the
# HugMesh ForceLocalForUsers MRF compiled in. Published as ghcr.io/hugmesh/hugmesh-akkoma
# by .github/workflows/akkoma-release.yml (cosign keyless signature, build provenance
# and SPDX SBOM attestations); built without pushing by akkoma-image-ci.yml on PRs.
#
# Why we build it: upstream publishes no container image (its compose file builds
# locally and its CI publishes OTP release zips only), and the registry host the
# manifests used to name does not resolve. Operator decision 2026-11-11: build our
# own from the v3.20.1 tag.
#
# Reproducible inputs, every one pinned:
#   - upstream source: AKKOMA_COMMIT, fetched by commit id and checked after checkout
#     (git verifies the content against the id). AKKOMA_VERSION must match the
#     version mix.exs declares at that commit, so a bumped commit without a bumped
#     version (or the reverse) fails the build. images/akkoma/README.md says how to
#     move to a new upstream release.
#   - dependencies: upstream's mix.lock (hex checksums and git commit ids), with
#     --check-locked so a lock that would change fails the build. Hex itself is
#     pinned (HEX_VERSION).
#   - toolchain and runtime: both base images by index digest (multi-arch).
#   - Debian packages float within the pinned base's suite (security updates).
#
# ─────────────────────────────── AGPL-3.0 ────────────────────────────────────
# Akkoma is AGPL-3.0 and this image is a derivative work. The complete corresponding
# source is: upstream at AKKOMA_COMMIT (labels below) + this directory
# (images/akkoma/ in hugmesh/hugmesh-generator: this Dockerfile, hugmesh-env.sh and
# mrf/). AKKOMA_SOURCE_URL points network users at it. docs/DOMAIN-LOCK.md
# "AGPL source publication".
ARG ELIXIR_IMAGE=docker.io/hexpm/elixir:1.19.7-erlang-28.5.0.8-debian-trixie-20261104@sha256:b65cfd98907f86475c63441c8d4243c24880afa50bb769f9aaa9229ba30602ed
ARG RUNTIME_IMAGE=docker.io/library/debian:trixie-20261104-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2

# ── build: compile the OTP release ───────────────────────────────────────────
FROM ${ELIXIR_IMAGE} AS build
ARG AKKOMA_GIT_URL=https://akkoma.dev/AkkomaGang/akkoma.git
ARG AKKOMA_VERSION=3.20.1
ARG AKKOMA_COMMIT=98dd958886a8b0ef65d5bd827aba3789f1dc5116
ARG HEX_VERSION=2.7.0
ENV MIX_ENV=prod \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      build-essential cmake git ca-certificates libmagic-dev; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /src
# Fetch exactly AKKOMA_COMMIT (no branch or tag name is trusted), prove it, and
# prove mix.exs at that commit declares AKKOMA_VERSION. .git is removed afterwards
# so mix.exs's version/1 reports plain AKKOMA_VERSION instead of a describe string.
RUN set -eux; \
    git init -q .; \
    git fetch -q --depth 1 "$AKKOMA_GIT_URL" "$AKKOMA_COMMIT"; \
    git checkout -q --detach FETCH_HEAD; \
    test "$(git rev-parse HEAD)" = "$AKKOMA_COMMIT"; \
    grep -F "version: version(\"$AKKOMA_VERSION\")," mix.exs >/dev/null; \
    rm -rf .git

# HugMesh overlay. The MRF module is compiled into the release but does nothing
# unless config lists it under :mrf policies (it ships dark; docs/DOMAIN-LOCK.md).
COPY mrf/force_local_for_users_policy.ex lib/pleroma/web/activity_pub/mrf/force_local_for_users_policy.ex
COPY hugmesh-env.sh /tmp/hugmesh-env.sh
COPY hugmesh-vm.args /tmp/hugmesh-vm.args
RUN set -eux; \
    cat /tmp/hugmesh-env.sh >> rel/env.sh.eex; \
    cat /tmp/hugmesh-vm.args >> rel/vm.args.eex; \
    echo 'import Config' > config/prod.secret.exs

RUN set -eux; \
    mix local.hex "$HEX_VERSION" --force; \
    mix local.rebar --force; \
    mix deps.get --only prod --check-locked; \
    mix release --path /opt/akkoma; \
    rm -f /opt/akkoma/releases/COOKIE; \
    test -x /opt/akkoma/bin/pleroma; \
    test -x /opt/akkoma/bin/pleroma_ctl; \
    test "$(cut -d' ' -f2 /opt/akkoma/releases/start_erl.data)" = "$AKKOMA_VERSION"

# ── runtime ──────────────────────────────────────────────────────────────────
FROM ${RUNTIME_IMAGE}
ARG AKKOMA_VERSION=3.20.1
ARG AKKOMA_COMMIT=98dd958886a8b0ef65d5bd827aba3789f1dc5116
ARG AKKOMA_GIT_URL=https://akkoma.dev/AkkomaGang/akkoma.git
LABEL org.opencontainers.image.title="hugmesh-akkoma" \
      org.opencontainers.image.description="Akkoma built from upstream source, with the HugMesh ForceLocalForUsers MRF compiled in" \
      org.opencontainers.image.licenses="AGPL-3.0-only" \
      net.hugmesh.akkoma.upstream-version="${AKKOMA_VERSION}" \
      net.hugmesh.akkoma.upstream-commit="${AKKOMA_COMMIT}" \
      net.hugmesh.akkoma.upstream-source="${AKKOMA_GIT_URL}"

# The release carries its own ERTS. Runtime needs: OpenSSL (crypto, ssl), ncurses
# (the release's shell), libstdc++, libmagic (the majic NIF), exiftool (the
# Exiftool upload filters), ca-certificates (federation over TLS), curl (the
# HEALTHCHECK) and python3: the akkoma-admin-sync and akkoma-domainlock-sync Jobs
# (specs/cluster/manifests/akkoma/) run their stdlib-only reconcile script in THIS
# image, next to pleroma_ctl. ffmpeg and ImageMagick are left out on purpose: they
# serve only the media preview proxy and the AnalyzeMetadata filter, both off
# unless configured.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl libimage-exiftool-perl libmagic1t64 libncursesw6 \
      libssl3t64 libstdc++6 python3; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd --system --gid 1000 akkoma; \
    useradd --system --uid 1000 --gid akkoma --home-dir /var/lib/akkoma \
      --no-create-home --shell /usr/sbin/nologin akkoma; \
    install -d -o akkoma -g akkoma -m 0750 /var/lib/akkoma /var/lib/akkoma/uploads \
      /var/lib/akkoma/static /var/lib/akkoma/modules; \
    install -d -o root -g akkoma -m 0750 /etc/akkoma

# Release files are owned by root: the akkoma user can run them, never change them.
COPY --from=build --chown=root:root /opt/akkoma /opt/akkoma

# Release defaults (Pleroma.Config.Holder.release_defaults/0) already put uploads,
# static and modules under /var/lib/akkoma; config is read from
# /etc/akkoma/config.exs, which must not be world-readable or group-writable
# (Pleroma.Config.ReleaseRuntimeProvider refuses to start otherwise; mount it 0440
# with the pod's fsGroup 1000). RELEASE_TMP is where the release writes its
# generated sys.config and where hugmesh-env.sh keeps the per-container Erlang
# cookie: mount an emptyDir at /tmp under readOnlyRootFilesystem.
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/var/lib/akkoma \
    RELEASE_TMP=/tmp \
    ERL_EPMD_ADDRESS=127.0.0.1 \
    AKKOMA_CONFIG_PATH=/etc/akkoma/config.exs \
    AKKOMA_SOURCE_URL="https://github.com/hugmesh/hugmesh-generator/tree/main/images/akkoma"

USER 1000:1000
WORKDIR /var/lib/akkoma
EXPOSE 4000

# /api/v1/instance answers without auth once the endpoint is up (the cluster's
# readinessProbe uses the same path). Kubernetes ignores HEALTHCHECK; compose and
# docker run use it.
HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=5 \
  CMD curl -fsS -o /dev/null http://127.0.0.1:4000/api/v1/instance || exit 1

CMD ["/opt/akkoma/bin/pleroma", "start"]

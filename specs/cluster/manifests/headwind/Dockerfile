# snapdragon-headwind — build-from-source image for Headwind MDM (Apache-2.0),
# baked from the h-mdm/hmdm-server Maven reactor into a Tomcat9/JDK11 ROOT.war.
# Build + push to the mesh registry the deployment (headwind.yaml/kustomization.yaml)
# expects:
#   docker build -t registry.snapdragon.systems/snapdragon/snapdragon-headwind:main .
#   docker push  registry.snapdragon.systems/snapdragon/snapdragon-headwind:main
#
# WHY build-from-source (not upstream h-mdm/hmdm-docker's own recipe): that
# image curls an UNSIGNED prebuilt WAR from h-mdm.com at build time — pinning
# it by digest would only pin the download *recipe*, not the WAR's actual
# source provenance. See headwind.yaml's "WAR PROVENANCE" header comment for
# the full rationale.
#
# ─────────────────────── STATUS: STARTING POINT, NOT PROVEN ───────────────────
# This Dockerfile has NOT been test-built in this recon pass. Every path/file
# name below is believed-correct from reading the upstream source tree, not
# verified by a green `docker build`. Three real gaps before it can be trusted
# as CI-buildable:
#
#   1. BUILD-TIME EGRESS (NOT air-gap-friendly without a mirror): the reactor's
#      server/pom.xml runs the frontend-maven-plugin, which downloads Node 18 +
#      npm and runs `npm install` + `grunt` to bundle the AngularJS frontend —
#      there is no vendored node_modules checked into hmdm-server. Some Maven
#      deps also resolve through jitpack.io, not just Maven Central. Both need
#      real internet egress (or an internal npm/jitpack mirror) at image-build
#      time; this is a harder requirement than the platform's usual
#      Maven-Central-only builds.
#   2. UNVENDORED FILES: hmdm-docker's docker-entrypoint.sh (the env->ROOT.xml
#      templating logic headwind.yaml's ConfigMap/env block depends on) +
#      templates/conf/context_template.xml + tomcat_conf/server.xml are NOT
#      present anywhere in this repo. They must be fetched from the Apache-2.0
#      h-mdm/hmdm-docker repo (pinned ref) and vendored into a docker/ subdir
#      next to this Dockerfile (paths referenced below) before this build can
#      succeed — it will fail on the COPY steps until that happens.
#   3. The launcher.war output path (server/target/launcher.war) and the
#      ROOT.xml JDBC.*/SQL_*/PROTOCOL/BASE_DOMAIN env contract are read from
#      the upstream source tree, not confirmed by an actual build+boot.
#
# aapt (Android Asset Packaging Tool) is a RUNTIME dependency (hmdm's
# aapt.command config param parses uploaded APKs), not just a build tool —
# installed in the runtime stage below.

# ── stage 1: build (whole Maven reactor) ────────────────────────────────────
FROM maven:3.9-eclipse-temurin-11 AS builder
WORKDIR /src
# Expects the full h-mdm/hmdm-server reactor checkout at the build context root.
# Network required: Maven Central + jitpack.io + the npm registry (transitively,
# via frontend-maven-plugin — see gap #1 above).
COPY . .
RUN mvn -B -DskipTests install

# ── stage 2: runtime ─────────────────────────────────────────────────────────
FROM tomcat:9-jdk11-temurin-jammy
LABEL org.opencontainers.image.title="snapdragon-headwind" \
      org.opencontainers.image.description="Headwind MDM (Apache-2.0), build-from-source" \
      org.opencontainers.image.licenses="Apache-2.0"

# aapt = RUNTIME dep (APK metadata parsing, aapt.command). postgresql-client is
# for operator debugging against headwind-db, not consumed by hmdm itself.
# Explicit non-root user/group 1000 to match headwind.yaml's Deployment
# securityContext (runAsUser/runAsGroup/fsGroup: 1000) — mirrors phpbb.yaml's
# rootless rationale; stock tomcat:9-jdk11 images run as root otherwise.
RUN apt-get update \
    && apt-get install -y --no-install-recommends aapt postgresql-client \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 1000 hmdm \
    && useradd -u 1000 -g hmdm -M -d /usr/local/tomcat -s /usr/sbin/nologin hmdm

# TODO(unvendored — see gap #2 above): these three files do NOT exist in this
# repo yet. Fetch from the Apache-2.0 h-mdm/hmdm-docker repo (pin a ref) and
# vendor them into docker/ next to this Dockerfile before building — these
# COPY steps will fail until then.
COPY docker/docker-entrypoint.sh   /usr/local/bin/docker-entrypoint.sh
COPY docker/context_template.xml   /usr/local/tomcat/conf/context_template.xml
COPY docker/server.xml             /usr/local/tomcat/conf/server.xml
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Replace the stock Tomcat welcome ROOT with the built Headwind WAR.
RUN rm -rf /usr/local/tomcat/webapps/ROOT
COPY --from=builder /src/server/target/launcher.war /usr/local/tomcat/webapps/ROOT.war

RUN chown -R hmdm:hmdm /usr/local/tomcat
USER hmdm

# 8080 HTTP, 8443 HTTPS (unused — PROTOCOL=http forces the gateway-terminated
# path, see headwind.yaml's ConfigMap), 31000 embedded ActiveMQ/MQTT.
EXPOSE 8080 8443 31000

# ENTRYPOINT invocation is a best-guess mirror of hmdm-docker's own image
# (env-templating entrypoint that then execs Tomcat) — NOT verified against an
# actual build; confirm docker-entrypoint.sh's real exec line once vendored.
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["catalina.sh", "run"]

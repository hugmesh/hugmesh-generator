# hugmesh-headwind — build-from-source image for Headwind MDM (Apache-2.0),
# baked from the h-mdm/hmdm-server Maven reactor into a Tomcat9/JDK11 ROOT.war.
# Build + push to the mesh registry the deployment (headwind.yaml/kustomization.yaml)
# expects:
#   docker build -t registry.hugmesh.net/hugmesh/hugmesh-headwind:main .
#   docker push  registry.hugmesh.net/hugmesh/hugmesh-headwind:main
#
# WHY build-from-source (not upstream h-mdm/hmdm-docker's own recipe): that
# image curls an UNSIGNED prebuilt WAR from h-mdm.com at build time — pinning
# it by digest would only pin the download *recipe*, not the WAR's actual
# source provenance. See headwind.yaml's "WAR PROVENANCE" header comment for
# the full rationale.
#
# ─────────────────────── STATUS: PROVEN by a real `docker build` ──────────────
# Built green 2026-07-19 (948MB) against hmdm-server@daed2099 staged as the
# build context with this Dockerfile + docker/ copied in: full Maven reactor +
# frontend-maven-plugin (Node/npm/grunt AngularJS bundle) -> a real 43MB
# webapps/ROOT.war; smoke run confirms USER hmdm uid/gid 1000, the entrypoint
# rendering ROOT.xml (0600, XML-entity-escaped values — a password containing
# & | @ round-trips) + init.sql (ADMIN_EMAIL stamped, zero h-mdm.com URLs
# left), then waiting on Postgres. The first real build also caught the missing
# server/build.properties requirement (now vendored + build-time-randomized
# secrets — see below). Remaining operational notes:
#
#   1. BUILD-TIME EGRESS (NOT air-gap-friendly without a mirror): the reactor's
#      server/pom.xml runs the frontend-maven-plugin, which downloads Node 18 +
#      npm and runs `npm install` + `grunt` to bundle the AngularJS frontend —
#      there is no vendored node_modules checked into hmdm-server. Some Maven
#      deps also resolve through jitpack.io, not just Maven Central. Both need
#      real internet egress (or an internal npm/jitpack mirror) at image-build
#      time; this is a harder requirement than the platform's usual
#      Maven-Central-only builds.
#   2. RESOLVED — runtime files are VENDORED under docker/ (see
#      docker/README.md for the pinned h-mdm/hmdm-docker ref + provenance
#      table): the two Tomcat templates + log4j + the hmdm_init.en.sql seed +
#      recovery-mail templates verbatim, and a DERIVED docker-entrypoint.sh
#      (upstream's is the prebuilt-WAR/root/letsencrypt flow — unusable here;
#      the derivation header lists every divergence). The ROOT.xml
#      SQL_*/PROTOCOL/BASE_DOMAIN env contract headwind.yaml carries is now
#      CONFIRMED against the vendored context_template.xml.
#   3. RESOLVED — the launcher.war output path (server/target/launcher.war) is
#      CONFIRMED by the green reactor build (the runtime COPY --from=builder
#      succeeded and the smoke run shows the 43MB ROOT.war in webapps/).
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
# server/build.properties is REQUIRED by the reactor's copy-resources (first
# real build failed without it: "Error loading property file"). The vendored
# copy carries baked DEFAULTS only — every deployment-relevant key is overridden
# at runtime by the entrypoint-rendered ROOT.xml context. The two baked secrets
# (jwt.secretkey for console sessions, hash.secret) are randomized PER IMAGE
# BUILD here so no committed constant ever ships in a layer.
COPY docker/build.properties server/build.properties
RUN JWT=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n') \
    && HASH=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n') \
    && sed -i -e "s/^jwt.secretkey=RANDOMIZE-AT-IMAGE-BUILD/jwt.secretkey=${JWT}/" \
              -e "s/^hash.secret=RANDOMIZE-AT-IMAGE-BUILD/hash.secret=${HASH}/" \
              server/build.properties \
    && ! grep -q RANDOMIZE-AT-IMAGE-BUILD server/build.properties
RUN mvn -B -DskipTests install

# ── stage 2: runtime ─────────────────────────────────────────────────────────
FROM tomcat:9-jdk11-temurin-jammy
LABEL org.opencontainers.image.title="hugmesh-headwind" \
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

# Vendored runtime files (docker/ next to this Dockerfile — stage it into the
# build context alongside the hmdm-server checkout; provenance + pinned ref in
# docker/README.md). Templates land under /opt/hmdm/templates (the upstream
# TEMPLATE_DIR convention the entrypoint reads); server.xml replaces Tomcat's.
COPY docker/docker-entrypoint.sh   /usr/local/bin/docker-entrypoint.sh
COPY docker/templates/             /opt/hmdm/templates/
COPY docker/server.xml             /usr/local/tomcat/conf/server.xml
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
# /dev/urandom for SecureRandom at BUILD time (upstream's entrypoint edits the
# root-owned java.security at RUNTIME — impossible rootless; same effect here).
RUN sed -i 's|securerandom.source=file:/dev/random|securerandom.source=file:/dev/urandom|' \
        /opt/java/openjdk/conf/security/java.security

# Replace the stock Tomcat welcome ROOT with the built Headwind WAR.
RUN rm -rf /usr/local/tomcat/webapps/ROOT
COPY --from=builder /src/server/target/launcher.war /usr/local/tomcat/webapps/ROOT.war

RUN chown -R hmdm:hmdm /usr/local/tomcat /opt/hmdm
USER hmdm

# 8080 HTTP, 8443 HTTPS (unused — PROTOCOL=http forces the gateway-terminated
# path, see headwind.yaml's ConfigMap), 31000 embedded ActiveMQ/MQTT.
EXPOSE 8080 8443 31000

# The DERIVED entrypoint renders ROOT.xml + init.sql from the vendored
# templates, waits for Postgres, then exec's the CMD (upstream ran catalina
# un-exec'd; ours preserves PID-1 signal handling).
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["catalina.sh", "run"]

# specs/cluster/manifests/attestation-server/Dockerfile
#
# STATUS: BUILD STAGE PROVEN; runtime packaging not yet run. Grounded in real source reads of
# GrapheneOS/AttestationServer (commit 98b6c130, main). The build stage below was VERIFIED
# 2026-07-17 on the host (openjdk 25, Gradle wrapper 9.6.1): clone 98b6c130 --recurse-submodules,
# apply the DOMAIN + bind seds below, `./gradlew build` -> BUILD SUCCESSFUL in ~18s, producing
# build/libs/attestation-server.jar + the native libsqlite4java-linux-amd64-1.0.392.so + deps (the
# full deployable unit). So the source + our two patches compile cleanly. What remains UNproven:
# the runtime stage's image packaging (base image, non-root user, COPY of build/libs, ENTRYPOINT)
# has not been run as an actual `docker build` here — validate that before trusting it in a cluster.
#
# STRUCTURAL DIFFERENCE FROM headwind's Dockerfile: AttestationServer is a standalone Java app with
# its OWN embedded com.sun.net.httpserver.HttpServer (not a servlet-container WAR deploy like
# headwind's Tomcat). It is started directly via `java -jar`, no app server involved.
#
# ══════════════════════════ FORK COUPLING (READ BEFORE TOUCHING AUDITOR_* ARGS) ══════════════════════════
# DECISION 2026-07-17 (auditor-fork-decision.md): we are NOT interoperating with the stock GrapheneOS
# Auditor app. We fork+re-sign our OWN Auditor (systems.snapdragon.auditor, Track 2 of that decision),
# so THIS server must pin to OUR fork's identity, not upstream's. This is a deliberate override of
# AttestationServer's own upstream default (which pins to the stock Auditor's package/signer).
#
#   server AUDITOR_SIGNER_DIGEST  ===  our Auditor fork's release-signing-cert SHA-256  (Track 2 output)
#   server AUDITOR_PACKAGE        ===  our Auditor fork's applicationId (systems.snapdragon.auditor)
#   server ATTESTATION_DOMAIN     ===  fork DOMAIN  ===  attestation.snapdragon.systems (both sides)
#
# These are BUILT AND SET TOGETHER. If AUDITOR_SIGNER_DIGEST does not exactly equal the real fork
# release cert's SHA-256 digest, this server will REJECT EVERY ATTESTATION from our own app — there is
# no partial-credit or fallback path. AUDITOR_SIGNER_DIGEST below is a PLACEHOLDER
# (SET-FROM-FORK-RELEASE-CERT) until Track 2's signing key exists and a real release APK has been
# signed — do not ship this image to a cluster with the placeholder value still in place.
# ════════════════════════════════════════════════════════════════════════════════════════════════════════
#
# ---- Stage 1: build ----
FROM eclipse-temurin:25-jdk AS builder
WORKDIR /build

ARG ATTESTATION_COMMIT=98b6c130
ARG ATTESTATION_DOMAIN=attestation.snapdragon.systems
# Our Auditor fork's identity (see FORK COUPLING banner above). AUDITOR_SIGNER_DIGEST is a
# placeholder: SET-FROM-FORK-RELEASE-CERT — replace with
# `keytool -printcert -jarfile <fork-release.apk>` (or an equivalent apksigner cert-dump), SHA-256,
# uppercase hex, no colons — once Track 2 produces a real signed release build. Do not build a
# cluster-bound image with the placeholder still in place.
ARG AUDITOR_PACKAGE=systems.snapdragon.auditor
ARG AUDITOR_SIGNER_DIGEST=SET-FROM-FORK-RELEASE-CERT

RUN git clone --recurse-submodules https://github.com/GrapheneOS/AttestationServer.git . \
    && git checkout ${ATTESTATION_COMMIT}
# --recurse-submodules is REQUIRED: libs/sqlite4java-prebuilt (native .so dependency) is a git
# submodule (GrapheneOS/sqlite4java-prebuilt.git), not a Maven-Central artifact.

# Patch 1 (MANDATORY, per README.md's own self-hosting instructions): DOMAIN constant.
# AttestationServer.java:89 — `static final String DOMAIN = "attestation.app";`
# Used for Origin-header CSRF validation (PostHandler), the QR pairing payload
# (`<domain> <userId> <subscribeKey> <verifyInterval>`), and alert-email text.
RUN sed -i \
    "s|static final String DOMAIN = \"attestation.app\";|static final String DOMAIN = \"${ATTESTATION_DOMAIN}\";|" \
    src/main/java/app/attestation/server/AttestationServer.java \
    && grep -q "${ATTESTATION_DOMAIN}" src/main/java/app/attestation/server/AttestationServer.java

# Patch 2 (MANDATORY for THIS topology): bind-address.
# AttestationServer.java:895 — `HttpServer.create(new InetSocketAddress("::1", 8080), 4096)`
# Upstream hardcodes IPv6 LOOPBACK ONLY because upstream fronts it with an nginx sidecar in the SAME
# network namespace (systemd single-host deploy; nginx.conf:107-111, systemd unit IPAddressAllow=localhost).
# Our topology instead exposes a k8s Service pointed directly at this Deployment's pods (mirroring
# headwind's headwind-checkin Service pattern) — a DIFFERENT network namespace from the gateway — so
# the loopback-only bind is unreachable and must be widened.
# IF THIS EVER CHANGES to an in-pod nginx/gateway sidecar topology instead: DELETE this patch and
# leave the stock ::1 bind untouched — zero source changes needed in that topology (pod containers
# share one network namespace, so ::1 already works across sidecar<->app in the same pod).
RUN sed -i \
    's|new InetSocketAddress("::1", 8080)|new InetSocketAddress(8080)|' \
    src/main/java/app/attestation/server/AttestationServer.java \
    && grep -q 'new InetSocketAddress(8080)' src/main/java/app/attestation/server/AttestationServer.java

# Patch 3 (FORK OVERRIDE — see the FORK COUPLING banner at the top of this file) — Auditor app-identity
# pin constants, AttestationProtocol.java:164-172. Upstream's Phase-2-spec default was "leave
# unchanged" (interop with the STOCK Auditor app, signer 990E04F0864B19F14F84E0E432F7A393F297AB1
# 05A22C1E1B10B442A4A62C42C). auditor-fork-decision.md OVERRIDES that default: we fork+re-sign our own
# Auditor, so the server must instead accept OUR fork's package id + release signing cert digest.
#
# Only the RELEASE pin is repointed — we ship exactly one release variant (Track 2 does not build
# separate Play/debug flavors distributed to real devices), so _PLAY/_DEBUG are left at their stock
# upstream values: harmless dead pins that no real device of ours will ever present, and cheapest to
# keep in sync with any future upstream AttestationProtocol.java changes.
#
# Identifier names are source-confirmed (spec §3 table, real read of AttestationProtocol.java:164-172);
# the exact declaration syntax around each identifier (field type/visibility) is NOT independently
# re-verified in this pass — the sed below matches on the identifier + the known stock literal value
# only, and the grep -q afterward is the real gate: if upstream's declaration shape ever changes, this
# build fails LOUD instead of silently keeping the stock (wrong) pin.
RUN sed -i \
    "s|AUDITOR_APP_PACKAGE_NAME_RELEASE = \"app.attestation.auditor\"|AUDITOR_APP_PACKAGE_NAME_RELEASE = \"${AUDITOR_PACKAGE}\"|" \
    src/main/java/app/attestation/server/AttestationProtocol.java \
    && sed -i \
    "s|AUDITOR_APP_SIGNATURE_DIGEST_RELEASE = \"990E04F0864B19F14F84E0E432F7A393F297AB105A22C1E1B10B442A4A62C42C\"|AUDITOR_APP_SIGNATURE_DIGEST_RELEASE = \"${AUDITOR_SIGNER_DIGEST}\"|" \
    src/main/java/app/attestation/server/AttestationProtocol.java \
    && grep -q "${AUDITOR_PACKAGE}" src/main/java/app/attestation/server/AttestationProtocol.java \
    && grep -q "${AUDITOR_SIGNER_DIGEST}" src/main/java/app/attestation/server/AttestationProtocol.java
# NOTE: with the placeholder AUDITOR_SIGNER_DIGEST=SET-FROM-FORK-RELEASE-CERT still in ARG default
# above, this sed + grep pair still succeeds (it patches in the literal placeholder string) — the
# grep -q gate proves the SED APPLIED, it does NOT prove the digest is a REAL cert SHA-256. Re-run
# this build with a real --build-arg AUDITOR_SIGNER_DIGEST=<hex> once Track 2's fork is signed; do not
# treat a green build alone as proof the pin is correct.

RUN ./gradlew build --no-daemon
# CI-verified command (.github/workflows/build.yml): JDK 25 (Temurin), Gradle wrapper 9.6.1.
#
# IMPORTANT: this produces a THIN jar (manifest Class-Path attribute referencing sibling dependency
# jars BY FILENAME, resolved relative to the jar's own directory) plus a `copyJavaDeps` Gradle task
# (wired into `tasks.build`) that copies the full runtime classpath — including the native
# libsqlite4java-linux-amd64-1.0.392.so — into build/libs/ alongside attestation-server.jar.
# The ENTIRE build/libs/ directory is the deployable unit. Copying only attestation-server.jar (a
# very natural-looking mistake given its name) WILL fail at container startup with
# ClassNotFoundException / UnsatisfiedLinkError.

# ---- Stage 2: runtime ----
FROM eclipse-temurin:25-jre AS runtime

RUN groupadd -g 1000 attestation \
    && useradd -u 1000 -g attestation -M -s /usr/sbin/nologin attestation \
    && mkdir -p /app /data \
    && chown -R attestation:attestation /app /data

COPY --from=builder --chown=attestation:attestation /build/build/libs/ /app/

USER attestation
WORKDIR /data
EXPOSE 8080

# Standalone Java app with its own embedded HTTP server — run the jar directly, no app-server needed.
ENTRYPOINT ["java", "-jar", "/app/attestation-server.jar"]

# SMTP alert credentials are NOT read from env vars by this app — see the attestation-server-smtp
# ExternalSecret + smtp-config-seeder sidecar comments in attestation-server.yaml for how they are
# (best-effort) injected into the app's own SQLite Configuration table instead.
#
# No admin-credential env var exists or should be invented: /api/create-account is fully
# unauthenticated/self-service at the app layer (no invite code, no bootstrap gate). Gateway-side
# ROLE_SUPERADMIN gating on /attest/api/** is the ONLY protection against open self-signup.

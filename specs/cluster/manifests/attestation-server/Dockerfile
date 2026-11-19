# specs/cluster/manifests/attestation-server/Dockerfile
#
# STATUS: FULL IMAGE PROVEN — real `docker build` green + smoke-booted 2026-07-19 (507MB): the
# container starts as uid=1000(attestation), applies the SQLite schema ("Existing schema version: 1")
# and creates /data/attestation.db{,-shm,-wal} owned 1000:1000 with the native sqlite4java .so
# loading. The build stage was first proven on-host 2026-07-17 (openjdk 25, Gradle 9.6.1, ~18s).
# The first real docker builds also caught + fixed three packaging bugs: git absent from the temurin
# builder base; the runtime base's preexisting ubuntu UID/GID 1000 colliding with `attestation`; and
# Patch 3's digest sed assuming a single-line declaration (it is line-wrapped — see Patch 3).
# Still gated on operator custody: a REAL --build-arg AUDITOR_SIGNER_DIGEST (see FORK COUPLING).
#
# STRUCTURAL DIFFERENCE FROM headwind's Dockerfile: AttestationServer is a standalone Java app with
# its OWN embedded com.sun.net.httpserver.HttpServer (not a servlet-container WAR deploy like
# headwind's Tomcat). It is started directly via `java -jar`, no app server involved.
#
# ══════════════════════════ FORK COUPLING (READ BEFORE TOUCHING AUDITOR_* ARGS) ══════════════════════════
# DECISION 2026-07-17 (auditor-fork-decision.md): we are NOT interoperating with the stock GrapheneOS
# Auditor app. We fork+re-sign our OWN Auditor (systems.hugmesh.auditor, Track 2 of that decision),
# so THIS server must pin to OUR fork's identity, not upstream's. This is a deliberate override of
# AttestationServer's own upstream default (which pins to the stock Auditor's package/signer).
#
#   server AUDITOR_SIGNER_DIGEST  ===  our Auditor fork's release-signing-cert SHA-256  (Track 2 output)
#   server AUDITOR_PACKAGE        ===  our Auditor fork's applicationId (systems.hugmesh.auditor)
#   server ATTESTATION_DOMAIN     ===  fork DOMAIN  ===  attestation.hugmesh.net (both sides)
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

# git is NOT in the temurin base (first real build failed here: "git: not
# found") — needed for the pinned clone + its sqlite4java submodule.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ARG ATTESTATION_COMMIT=98b6c130
ARG ATTESTATION_DOMAIN=attestation.hugmesh.net
# Our Auditor fork's identity (see FORK COUPLING banner above). AUDITOR_SIGNER_DIGEST is a
# placeholder: SET-FROM-FORK-RELEASE-CERT — replace with
# `keytool -printcert -jarfile <fork-release.apk>` (or an equivalent apksigner cert-dump), SHA-256,
# uppercase hex, no colons — once Track 2 produces a real signed release build. Do not build a
# cluster-bound image with the placeholder still in place.
ARG AUDITOR_PACKAGE=systems.hugmesh.auditor
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
# Declaration shape CONFIRMED at 98b6c130 by the first real docker build (whose fail-loud grep gate
# caught the original single-line assumption): AUDITOR_APP_PACKAGE_NAME_RELEASE keeps `= "literal"` on
# ONE line, but AUDITOR_APP_SIGNATURE_DIGEST_RELEASE is LINE-WRAPPED (`... =` newline `"990E..."`,
# AttestationProtocol.java:167-168) — so the digest sed matches the unique stock digest LITERAL
# itself, not the declaration. The greps stay the real gate: if upstream reshapes either declaration
# again, this build fails LOUD instead of silently keeping the stock (wrong) pin.
RUN sed -i \
    "s|AUDITOR_APP_PACKAGE_NAME_RELEASE = \"app.attestation.auditor\"|AUDITOR_APP_PACKAGE_NAME_RELEASE = \"${AUDITOR_PACKAGE}\"|" \
    src/main/java/app/attestation/server/AttestationProtocol.java \
    && sed -i \
    "s|\"990E04F0864B19F14F84E0E432F7A393F297AB105A22C1E1B10B442A4A62C42C\"|\"${AUDITOR_SIGNER_DIGEST}\"|" \
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
# ---- Java4Shell (CVE-2026-114938): patched Java 25 runtime ------------------------------
# 25.0.5.1 fixes the heap overflow in the Base64 AVX-512 intrinsic, but eclipse-temurin:25-jre
# on Docker Hub still ships the vulnerable 25.0.5+8. Adoptium built Temurin 25.0.5.1+2 for
# linux x64 only, so arm64 gets a JRE linked (jlink, same module set as the base JRE) from
# Amazon Corretto 25.0.5.1.2, the same 25.0.5.1 security release. Both downloads are pinned to
# the vendors' published sha256. The runtime stage swaps this JRE in only while its base JRE
# is older. Remove this stage and the swap once eclipse-temurin:25-jre itself is >= 25.0.5.1.
FROM eclipse-temurin:25-jre AS jre-cve-2026-114938
ARG JRE_X64_URL=https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.5.1%2B2/OpenJDK25U-jre_x64_linux_hotspot_25.0.5.1_2.tar.gz
ARG JRE_X64_SHA256=2edef9e4f81ec5ee426d023336d4cfbd7b4644e99884e7a73a6a867b70b17acf
ARG JDK_AARCH64_URL=https://corretto.aws/downloads/resources/25.0.5.1.2/amazon-corretto-25.0.5.1.2-linux-aarch64.tar.gz
ARG JDK_AARCH64_SHA256=9370d3e5bcf0d165e6be4a78c3f6b57160af16d3033319af583800251eb91df2
RUN set -eu; \
    mkdir -p /opt/jre; \
    arch="$(dpkg --print-architecture)"; \
    case "${arch}" in \
      amd64) url="${JRE_X64_URL}"; sum="${JRE_X64_SHA256}" ;; \
      arm64) url="${JDK_AARCH64_URL}"; sum="${JDK_AARCH64_SHA256}" ;; \
      *) echo "jre-cve-2026-114938: no patched build for ${arch}; keeping the base JRE"; exit 0 ;; \
    esac; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    curl -fsSL --retry 3 -o /tmp/java.tar.gz "${url}"; \
    printf '%s  /tmp/java.tar.gz\n' "${sum}" > /tmp/java.sha256; \
    sha256sum -c /tmp/java.sha256; \
    mkdir /tmp/java; \
    tar -xzf /tmp/java.tar.gz -C /tmp/java --strip-components=1; \
    rmdir /opt/jre; \
    if [ "${arch}" = amd64 ]; then \
      mv /tmp/java /opt/jre; \
    else \
      java --list-modules > /tmp/modules; \
      modules="$(sed 's/@.*//' /tmp/modules | paste -sd, -)"; \
      [ -n "${modules}" ]; \
      /tmp/java/bin/jlink --add-modules "${modules}" --no-man-pages --no-header-files --output /opt/jre; \
      rm -rf /tmp/java /tmp/modules; \
    fi; \
    rm -f /tmp/java.tar.gz /tmp/java.sha256; \
    /opt/jre/bin/java -version

FROM eclipse-temurin:25-jre AS runtime
# Java4Shell (CVE-2026-114938): use the patched JRE from the stage above while the base JRE
# is older than 25.0.5.1 (a symlink, so the JRE is not copied a second time).
COPY --from=jre-cve-2026-114938 /opt/jre/ /opt/java/jre-25.0.5.1/
RUN base="$(sed -n 's/^JAVA_VERSION="\(.*\)"$/\1/p' /opt/java/openjdk/release)" \
    && printf '%s\n25.0.5.1\n' "${base}" > /tmp/jre-versions \
    && if [ -x /opt/java/jre-25.0.5.1/bin/java ] && [ "${base}" != 25.0.5.1 ] \
          && sort -V -C /tmp/jre-versions; then \
         rm -rf /opt/java/openjdk && ln -s jre-25.0.5.1 /opt/java/openjdk && ldconfig; \
       else \
         rm -rf /opt/java/jre-25.0.5.1; \
       fi \
    && rm -f /tmp/jre-versions \
    && java -version

# The Ubuntu-based temurin runtime ALREADY ships an `ubuntu` user at UID/GID
# 1000 (first real build failed on "GID '1000' already exists") — remove it and
# claim 1000 for `attestation`, keeping the image UID aligned with
# attestation-server.yaml's runAsUser/runAsGroup/fsGroup: 1000.
RUN userdel -r ubuntu 2>/dev/null || true \
    && groupdel ubuntu 2>/dev/null || true \
    && groupadd -g 1000 attestation \
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

# clients/hugmesh-auditor/build.Dockerfile
#
# STATUS: NOT BUILT. NOT BUILD-VERIFIED.
# Derived from a static read of GrapheneOS/Auditor's build.gradle.kts, CI
# workflow, and verification-metadata.xml — it has not been run end-to-end in
# this environment (no Android SDK / no egress-capable build host here).
# Treat every stage as a best-effort reconstruction to smoke-test, not a
# proven pipeline. In particular: the NDK-omission call, AGP/Gradle-wrapper
# auto-provisioning under a JDK 21 host, and the sdkmanager
# license-acceptance flow are all inferred from repo metadata, not observed
# in a successful build log. See README.md's honesty banner before shipping
# anything built from this file.
#
# WHAT THIS FILE DOES NOT DO (by design — secret hygiene):
#   - It does NOT sign the APK. It produces app-release-unsigned.apk only.
#   - It contains NO keystore, NO keystore.properties, NO `-alias`, NO
#     `signingConfig` reference of any kind. There is nothing here for a
#     `COPY` or secret-mount to leak, because signing material never enters
#     this build at all — signing is a SEPARATE step (sign-and-digest.sh) run
#     out-of-container against the offline release keystore (pki USB / Vault).
#     See README.md "Build + sign + distribute" for why this split exists.
#
# Build:
#   docker build -f build.Dockerfile \
#     --build-arg AUDITOR_COMMIT=<pinned-sha> \
#     -o out clients/hugmesh-auditor
#   -> out/app-release-unsigned.apk
#
# syntax=docker/dockerfile:1
FROM eclipse-temurin:21-jdk-jammy AS build

# --- Android SDK cmdline-tools ---
# Pulled from dl.google.com at build time — this stage needs EGRESS. If your
# build host is air-gapped, pre-stage the Android SDK and adapt this stage to
# COPY it in instead of curl'ing it.
ENV ANDROID_SDK_ROOT=/opt/android-sdk
RUN apt-get update && apt-get install -y --no-install-recommends unzip curl git openssl \
  && rm -rf /var/lib/apt/lists/*
RUN mkdir -p ${ANDROID_SDK_ROOT}/cmdline-tools \
  && curl -fsSL -o /tmp/cmdline-tools.zip \
       https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
  && unzip -q /tmp/cmdline-tools.zip -d ${ANDROID_SDK_ROOT}/cmdline-tools \
  && mv ${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools ${ANDROID_SDK_ROOT}/cmdline-tools/latest \
  && rm /tmp/cmdline-tools.zip
ENV PATH=${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${PATH}

RUN yes | sdkmanager --licenses \
  && sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.1.0"
# NDK intentionally OMITTED: build.gradle.kts declares ndkVersion="29.0.14206865"
# but a full-tree search of upstream (no CMakeLists.txt, no .cpp/.c, no
# jniLibs/externalNativeBuild) found ZERO native code — this app is pure
# Java/Kotlin. UNVERIFIED: if `assembleRelease` fails demanding the NDK anyway
# (e.g. a future upstream release adds native code), add:
#   sdkmanager "ndk;29.0.14206865"

# --- Clone at a PINNED commit (never `main` — reproducibility + auditability) ---
ARG AUDITOR_COMMIT=REPLACE-WITH-PINNED-COMMIT-SHA
WORKDIR /src
RUN git clone https://github.com/GrapheneOS/Auditor.git . \
  && git checkout "${AUDITOR_COMMIT}" \
  && if [ "${AUDITOR_COMMIT}" = "REPLACE-WITH-PINNED-COMMIT-SHA" ]; then \
       echo "ERROR: AUDITOR_COMMIT is still the placeholder — pin a real commit SHA (see patches.md) before building a release artifact." >&2; \
       exit 1; \
     fi

# --- Patch 1 (patches.md §1): RemoteVerifyJob DOMAIN constant ---
RUN sed -i 's/static final String DOMAIN = "attestation\.app";/static final String DOMAIN = "attestation.hugmesh.net";/' \
      app/src/main/java/app/attestation/auditor/RemoteVerifyJob.java \
  && grep -q 'attestation.hugmesh.net' app/src/main/java/app/attestation/auditor/RemoteVerifyJob.java

# --- Patch 2 (patches.md §2): network_security_config.xml hostname ---
RUN sed -i 's#<domain includeSubdomains="true">attestation\.app</domain>#<domain includeSubdomains="true">attestation.hugmesh.net</domain>#' \
      app/src/main/res/xml/network_security_config.xml \
  && grep -q 'attestation.hugmesh.net' app/src/main/res/xml/network_security_config.xml
# MANUAL STEP, NOT SCRIPTED HERE (CA-dependent — see patches.md §2): the
# <pin digest="SHA-256">...</pin> entries at lines 7-25 of the same file are
# STILL the inherited upstream Let's-Encrypt/ECDSA pins at this point in the
# build. If attestation.hugmesh.net's real certificate chain does not
# match them, every TLS connection this app makes will HARD-FAIL. Regenerate
# with (once, per real cert in the chain, BEFORE committing this patch set):
#   openssl s_client -connect attestation.hugmesh.net:443 -showcerts </dev/null \
#     | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der \
#     | openssl dgst -sha256 -binary | openssl enc -base64
# then hand-edit network_security_config.xml's <pin> values in this source
# tree (or bake a repo-local patched copy of the file and ADD it here) before
# this Dockerfile is trusted for a real release build.

# --- Patch 3 (patches.md §3): cosmetic links (safe to batch) ---
RUN sed -i 's#https://attestation\.app/about#https://attestation.hugmesh.net/about#' README.md \
  && sed -i 's#https://attestation\.app/donate#https://attestation.hugmesh.net/donate#' .github/FUNDING.yml || true

# --- Patch 4 (patches.md §4): applicationId (namespace left untouched) ---
RUN sed -i 's/applicationId = "app\.attestation\.auditor"/applicationId = "systems.hugmesh.auditor"/' \
      app/build.gradle.kts \
  && grep -q 'applicationId = "systems.hugmesh.auditor"' app/build.gradle.kts

# --- Patch 5 (patches.md §5, OPTIONAL local device-to-device audit identity) ---
# NOT applied by default — irrelevant to the remote-server flow this fork is
# built for, and it needs the release signing-cert digest (which does not
# exist until AFTER gen-auditor-signing-key.sh runs, out-of-container). If you
# need it, uncomment and pass --build-arg AUDITOR_SIGNER_DIGEST=<hex>:
# ARG AUDITOR_SIGNER_DIGEST
# RUN sed -i 's/AUDITOR_APP_PACKAGE_NAME_RELEASE = "app\.attestation\.auditor"/AUDITOR_APP_PACKAGE_NAME_RELEASE = "systems.hugmesh.auditor"/' \
#       app/src/main/java/app/attestation/auditor/AttestationProtocol.java \
#   && sed -i "s/AUDITOR_APP_SIGNATURE_DIGEST_RELEASE = \".*\"/AUDITOR_APP_SIGNATURE_DIGEST_RELEASE = \"${AUDITOR_SIGNER_DIGEST}\"/" \
#       app/src/main/java/app/attestation/auditor/AttestationProtocol.java

# --- Build: UNSIGNED release APK. No keystore, no signingConfig, no secrets. ---
# Upstream's release signingConfig only activates when a store-properties
# file naming a keystore is present in the tree (see patches.md / README.md
# "Signing story") — since we never place one here, `./gradlew assembleRelease`
# produces app/build/outputs/apk/release/app-release-unsigned.apk. This is
# intentional: this build stage must stay free of any store-properties file
# or signing material of any kind. Signing happens later, out-of-container,
# via sign-and-digest.sh against the offline release key (pki USB / Vault) —
# see README.md.
RUN ./gradlew assembleRelease --no-daemon
# CI reference (.github/workflows/build.yml): runs on JDK 21 (Temurin).
# app/build.gradle.kts pins a Java TOOLCHAIN of JavaLanguageVersion.of(17);
# Gradle auto-provisions/selects JDK 17 for compilation even from a JDK 21
# host JVM, so this base image matches upstream CI's own behavior, not a
# deviation. Gradle wrapper 9.6.1, AGP 9.0.0, compileSdk=36,
# buildToolsVersion="36.1.0". Dependency integrity: verify-metadata=true
# (SHA-512-pinned) but verify-signatures=false; repos locked to google() +
# mavenCentral() only. Reproducible-build status is UNRESOLVED (checksum
# pinning confirmed; no reproducible-build CI/verify script found) — do not
# claim reproducibility to downstream consumers of this fork without checking
# GrapheneOS's own release documentation directly.

RUN test -f app/build/outputs/apk/release/app-release-unsigned.apk \
  || (echo "ERROR: expected unsigned release APK not found — Gradle output layout may have changed upstream." >&2 && exit 1)

FROM scratch AS export
COPY --from=build /src/app/build/outputs/apk/release/app-release-unsigned.apk /app-release-unsigned.apk

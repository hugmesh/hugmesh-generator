# Snapdragon Auditor (fork of GrapheneOS/Auditor)

```
STATUS: NOT BUILT HERE. NOT BUILD-VERIFIED.
No app-release.apk exists in this repo or has been produced by this
environment. Building it needs the Android SDK (Temurin JDK + Android
cmdline-tools + an egress-capable build host), none of which is available in
this environment. Everything in this directory is scaffolding — patches,
build definition, signing scripts, and this runbook — for someone with a
real Android build environment to run end-to-end, verify, and sign. Treat
every claim below about what `assembleRelease` does as a best-effort
reconstruction from reading GrapheneOS/Auditor's source and CI config, not a
report of a build that actually ran. See "What has NOT been verified" below.
```

A fork of [GrapheneOS/Auditor](https://github.com/GrapheneOS/Auditor) (MIT
licensed), repointed at Snapdragon's own self-hosted `AttestationServer`
(`specs/cluster/manifests/attestation-server/`) at
`attestation.snapdragon.systems` instead of upstream's `attestation.app`,
built under Snapdragon's own `applicationId`
(`systems.snapdragon.auditor`), re-signed with a Snapdragon release key, and
distributed to managed phones via `scripts/phone-wizard.sh`'s existing
`adb install` + signer-pin mechanism.

This is the *fourth* client onboarding form in this repo, alongside the
appliance images, the client desktop images, and
[`clients/docker-mesh-node`](../docker-mesh-node) — but unlike those, it is
not something this repo builds from scratch: it is a **maintained fork of a
third-party Android app**, which is a fundamentally different (and heavier)
maintenance commitment. Read the next section before treating this as a
one-time task.

---

## Why this exists

Hardware attestation (Android KeyMint / SafetyNet-successor remote
attestation) needs two cooperating halves: a server that issues challenges
and verifies KeyMint certificate chains
(`specs/cluster/manifests/attestation-server/`), and a client app on the
device that performs the attestation and talks to that server. GrapheneOS's
Auditor is the reference client for this protocol — sovereign end-to-end
attestation means running BOTH halves ourselves rather than depending on
`attestation.app` (upstream's own hosted server) or trusting a
third-party-signed client talking to it. Track 1 (the server) and Track 2
(this fork) were built together for exactly that reason — see
`auditor-fork-decision.md` (2026-07-17) for the "commit to the full fork"
decision this component implements.

---

## The perpetual upstream-tracking maintenance burden (READ THIS)

**This is not a one-time fork.** Forking an actively-developed Android app
and repointing hardcoded identity constants means every upstream release is
a potential silent break. This is the single biggest ongoing cost of Track 2
— budget for it, don't treat this directory as "done" after the first build.

What can silently break on an upstream Auditor rebase:

1. **The `applicationId`/`namespace` split (`patches.md` §4).** This fork
   relies on upstream's manifest having NO `package=` attribute, so
   `applicationId` (Snapdragon's) and `namespace` (upstream's, left
   unchanged) can legally diverge without moving any Java source. If a
   future upstream release ADDS a manifest `package=` attribute, this
   assumption breaks and the applicationId patch needs to be re-derived
   entirely (likely a real Java-source/manifest rename instead of a
   one-line Gradle edit).
2. **`network_security_config.xml`'s pin-set (`patches.md` §2).** Upstream
   pins 6 SHA-256 values (Let's Encrypt roots + ECDSA backup keys) matched to
   `attestation.app`'s real certificate chain. Every time upstream rotates
   or adds to this pin-set (which tracks Let's Encrypt's own root rotation
   schedule, not something this fork controls), our regenerated
   `attestation.snapdragon.systems` pin-set needs re-validating against
   whatever changed — a stale pin-set means the app TLS-hard-fails against
   our own server with no obvious error.
3. **`RemoteVerifyJob`'s `DOMAIN`/`BASE_URL` handling** (`patches.md` §1) —
   if upstream restructures how `BASE_URL`/`CHALLENGE_URL`/`VERIFY_URL` are
   derived, or adds a port, the single-constant patch may no longer be
   sufficient.
4. **New `AUDITOR_APP_PACKAGE_NAME_*`/`SIGNATURE_DIGEST_*` build-type
   variants** (`patches.md` §5) — only relevant if the optional local-audit
   patch is ever adopted.

### Maintenance process (run on every upstream Auditor release)

1. `git fetch upstream main && git log <old-pinned-commit>..upstream/main --oneline`
   — review what changed.
2. Re-diff `patches.md`'s 4 mandatory patches (§1, §2, §3, §4) against the
   new tree BEFORE rebasing. Specifically re-check the two risks above:
   the applicationId/namespace split assumption, and whether the
   `network_security_config.xml` pin-set structure changed shape (not just
   values).
3. Update `AUDITOR_COMMIT` in `build.Dockerfile` to the new pinned SHA.
4. Re-apply the patches (the `sed`-based reapply in `build.Dockerfile` IS
   the intended maintenance mode — it is small and mechanical by design, not
   a manual merge each time). If a `sed`'s `grep -q` gate fails, that is the
   signal the source shape changed and the patch needs hand-updating, not
   silently skipping.
5. Re-run the build, re-verify with `apksigner verify --print-certs`,
   confirm the signing-cert digest is **UNCHANGED** (same keystore/alias) —
   see `COUPLING.md`; a digest change breaks update continuity for every
   device that already trusts the old one, and desyncs the
   AttestationServer's `AUDITOR_SIGNER_DIGEST` pin until that's updated too.
6. If the pin-set was touched upstream, re-verify
   `attestation.snapdragon.systems`'s certificate still chains under the
   fork's pins (or regenerate per `patches.md` §2).
7. Record the new pinned commit + sync date at the bottom of this section.

**Last synced against upstream:** not yet performed — this directory was
built from a static source read as of 2026-07-17 (exact commit SHA not
captured; see `build.Dockerfile`'s `AUDITOR_COMMIT` placeholder). Pin a real
commit and record the first real sync here.

---

## What is patched vs. upstream

See `patches.md` for the full file:line detail. Summary:

| # | What | Mandatory? |
|---|---|---|
| 1 | `RemoteVerifyJob.java` `DOMAIN` constant -> `attestation.snapdragon.systems` | Yes — this is the entire point of the fork |
| 2 | `network_security_config.xml` hostname + **certificate pin-set** | Yes — hostname is scripted; pin-set is a manual, CA-dependent regeneration |
| 3 | `README.md` / `.github/FUNDING.yml` cosmetic links | No, cosmetic only |
| 4 | `app/build.gradle.kts` `applicationId` -> `systems.snapdragon.auditor` (namespace untouched) | Yes |
| 5 | `AttestationProtocol.java` local device-to-device audit identity constants | No — only for local phone-to-phone QR audits, irrelevant to the remote-server flow; not applied by default |

---

## Build + sign + distribute + couple — the full runbook

### 1. Generate the release signing key (once, offline)

```sh
./gen-auditor-signing-key.sh
```

Mirrors `scripts/gen-keystores.sh`'s custody posture: the key is generated
OFFLINE (this script does no networking), on a machine intended to hold it
long-term, and is never committed. Move the resulting `.jks` (and its
password) to the **pki USB / Vault** — the same custody chain the cluster
CA key (`cluster-ca.key`) uses — immediately after generation. The script
prints the release-cert SHA-256 digest at the end; this is the value
`COUPLING.md` tracks.

### 2. Build the unsigned APK

```sh
docker build -f build.Dockerfile \
  --build-arg AUDITOR_COMMIT=<pinned-commit-sha> \
  -o out .
# -> out/app-release-unsigned.apk
```

`build.Dockerfile` clones GrapheneOS/Auditor at a **pinned commit**, applies
the mandatory patches (§1/§2-hostname/§3/§4 from `patches.md`), and runs
`./gradlew assembleRelease`. **No keystore of any kind is used or referenced
in this file** — see "Secret hygiene" below. Before trusting this build for
a real device population, also complete the manual pin-set regeneration
(`patches.md` §2) inside the cloned tree — the Dockerfile only patches the
hostname, not the pins, because the pins depend on
`attestation.snapdragon.systems`'s real certificate chain, which this
Dockerfile has no way to know at build time.

### 3. Sign the APK (offline, separately)

```sh
./sign-and-digest.sh \
  --unsigned out/app-release-unsigned.apk \
  --keystore /path/to/pki-usb/snapdragon-auditor-release.jks \
  --alias snapdragon-auditor \
  --out out/app-release.apk
```

Run this on the SAME offline machine (or with the pki USB / Vault keystore
mounted) — never copy the keystore onto a build server. It signs the APK
with `apksigner`, verifies the result, and prints the signer-cert digest
again as a cross-check against step 1's value — they must be identical.

### 4. Couple to the AttestationServer

Before either artifact ships to real devices, wire the digest from step 1/3
into the server side. See `COUPLING.md` for the full table and the exact
file to edit
(`specs/cluster/manifests/attestation-server/Dockerfile`'s
`AUDITOR_SIGNER_DIGEST` build ARG, currently the placeholder
`SET-FROM-FORK-RELEASE-CERT`).

### 5. Distribute to phones

Distribution is **already wired** — `scripts/phone-wizard.sh` (on `main`)
has `--tailscale-apk` (adb-installs an APK) and `--apk-signer-sha256` (pins
the expected signer cert digest, fail-closed on mismatch) for exactly this
kind of managed-app install; it currently uses that mechanism for the
Tailscale APK during `enroll`. Track 2 does not need to invent a new
install path:

```sh
# same mechanism phone-wizard already uses for the Tailscale APK —
# Phase 3 adds a dedicated --auditor-apk flag that reuses this exact code
# path (adb install -r + apksigner --print-certs signer-pin check,
# fail-closed on mismatch) rather than building a second install mechanism.
adb install -r out/app-release.apk
apksigner verify --print-certs out/app-release.apk   # confirm signer digest before/after
```

**Phase 3 (not built here):** wiring an `--auditor-apk <path>` flag into
`scripts/phone-wizard.sh` (alongside the existing `--tailscale-apk` /
`--apk-signer-sha256` flags) so `enroll`/`wizard` can install this fork the
same way it already installs Tailscale, with the same fail-closed signer-pin
enforcement. This directory only documents that mechanism and produces the
artifact it would consume — it does not modify `phone-wizard.sh`.

---

## Secret hygiene (read before touching this Dockerfile)

**The signing key never enters the container build.** This is deliberate,
not an oversight — a prior draft of this fork violated it by planning to
`COPY` the keystore into a build stage, which would have baked a long-term
signing key into an image layer (recoverable from any registry/cache holding
that layer, indefinitely). The design here avoids that entirely:

- `build.Dockerfile` produces `app-release-unsigned.apk` — no
  `keystore.properties`, no `.jks`, no `signingConfig` reference anywhere in
  that file. There is nothing to `COPY` or leak because signing material was
  never given to Docker in the first place.
- Signing (`sign-and-digest.sh`) runs **out-of-container**, directly against
  the offline keystore, on whatever machine/medium already holds it (pki USB
  / Vault-mounted). The keystore path is always a script argument — never
  hardcoded, never embedded, never logged.
- If in-container signing is ever genuinely required (e.g. a CI system that
  must sign as part of a pipeline), the only acceptable pattern is a
  BuildKit `--mount=type=secret` (`docker build --secret
  id=keystore,src=<path> ...`, referenced from a `RUN --mount=type=secret`
  step) — never `COPY`. That path is **not implemented here**; this
  directory's default and recommended posture is out-of-container signing,
  matching how `scripts/gen-keystores.sh` keeps the cluster CA key off every
  build/image entirely.

Verify this property yourself before trusting any change to
`build.Dockerfile`:

```sh
grep -i 'COPY.*\(jks\|keystore\|properties\)' build.Dockerfile   # must be empty
```

---

## What has NOT been verified (be honest about this)

- **The APK has not been built.** `build.Dockerfile` has not been run
  end-to-end in this environment — no Android SDK / no egress-capable build
  host here. The NDK-omission call, JDK-17-toolchain-under-JDK-21-host
  auto-provisioning, and the `sdkmanager --licenses` non-interactive flow
  are inferred from repo metadata (`build.gradle.kts`,
  `.github/workflows/build.yml`, `verification-metadata.xml`), not observed
  in a successful build log.
- **`AUDITOR_COMMIT` is a placeholder** (`REPLACE-WITH-PINNED-COMMIT-SHA` in
  `build.Dockerfile`) — no real commit has been pinned yet; the Dockerfile
  refuses to build past this placeholder.
- **The `network_security_config.xml` pin-set has not been regenerated**
  against `attestation.snapdragon.systems`'s real certificate chain — only
  the hostname is patched by `build.Dockerfile`. Whether the inherited
  Let's Encrypt pins happen to already work depends entirely on what CA
  actually issues that server's certificate, which was not checked here.
- **No signing key has been generated** — `gen-auditor-signing-key.sh` is
  ready to run but has not been run; there is no real
  `AUDITOR_SIGNER_DIGEST` value yet, which is why
  `specs/cluster/manifests/attestation-server/Dockerfile` still carries the
  `SET-FROM-FORK-RELEASE-CERT` placeholder (see `COUPLING.md`).
- **Reproducible-build status is unresolved** — upstream's dependency
  checksums are pinned (`verify-metadata=true`), but end-to-end build
  reproducibility was not independently confirmed.
- **`phone-wizard.sh`'s `--auditor-apk` flag does not exist yet** (Phase 3,
  explicitly out of scope for this directory — see "Distribute to phones"
  above).

---

## Files

| File | Purpose |
| --- | --- |
| `README.md` | This file — what this is, maintenance burden, full runbook |
| `patches.md` | Exact file:line source patches vs. upstream GrapheneOS/Auditor |
| `build.Dockerfile` | Multi-stage build: clone at a pinned commit, apply patches, `assembleRelease` -> UNSIGNED APK. No keystore anywhere. |
| `gen-auditor-signing-key.sh` | One-time, offline: generate the EC secp256r1 release signing key; print its SHA-256-of-DER-cert digest |
| `sign-and-digest.sh` | Sign the unsigned APK with the offline keystore; print + cross-check the signer digest |
| `COUPLING.md` | The exact checklist + file to edit to wire this fork's release-cert digest into the self-hosted AttestationServer |

## License

Upstream GrapheneOS/Auditor is MIT licensed; this fork inherits that license
for the patched source. Nothing in this directory (scripts, Dockerfile,
docs) changes that — only the constants listed in `patches.md` are altered
from upstream.

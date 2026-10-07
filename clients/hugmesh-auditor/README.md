# HugMesh Auditor (fork of GrapheneOS/Auditor)

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

This is a fork of [GrapheneOS/Auditor](https://github.com/GrapheneOS/Auditor)
(MIT licensed). It points at HugMesh's own self-hosted `AttestationServer`
(`specs/cluster/manifests/attestation-server/`) at `attestation.hugmesh.net`
instead of upstream's `attestation.app`. It builds under HugMesh's own
`applicationId` (`systems.hugmesh.auditor`), is re-signed with a HugMesh release
key, and reaches managed phones through `scripts/phone-wizard.sh`'s `adb
install` and signer-pin mechanism.

It is the *fourth* client onboarding form in this repo, beside the appliance
images, the client desktop images and
[`clients/docker-mesh-node`](../docker-mesh-node). Unlike those, this repo does
not build it from scratch. It is a **maintained fork of a third-party Android
app**, a heavier commitment. Read the next section before you treat it as a
one-time task.

---

## Why this exists

Hardware attestation (Android KeyMint remote attestation, the successor to
SafetyNet) needs two cooperating halves. A server issues challenges and verifies
KeyMint certificate chains (`specs/cluster/manifests/attestation-server/`). A
client app on the device performs the attestation and talks to that server.
GrapheneOS's Auditor is the reference client for this protocol. To attest
end to end on our own terms, we run BOTH halves. We then depend neither on
`attestation.app` (upstream's hosted server) nor on a third-party-signed client
talking to it. Track 1 (the server) and Track 2 (this fork) were built together
for that reason. The "commit to the full fork" decision this component
implements is recorded in `auditor-fork-decision.md` (2026-07-17); that file is
not in this repository.

---

## The perpetual upstream-tracking maintenance burden (READ THIS)

**This is not a one-time fork.** Forking an active Android app and repointing
its hardcoded identity constants means every upstream release can break the
fork without a sound. That is the biggest ongoing cost of Track 2. Budget for it.
Do not treat this directory as "done" after the first build.

What can break silently on an upstream Auditor rebase:

1. **The `applicationId`/`namespace` split (`patches.md` §4).** The fork relies
   on upstream's manifest having NO `package=` attribute. That lets
   `applicationId` (HugMesh's) and `namespace` (upstream's, unchanged) differ
   without moving any Java source. If a future upstream release ADDS a manifest
   `package=` attribute, the assumption fails. The applicationId patch then
   needs re-deriving, likely as a real Java-source and manifest rename instead
   of a one-line Gradle edit.
2. **The `network_security_config.xml` pin-set (`patches.md` §2).** Upstream
   pins 6 SHA-256 values (Let's Encrypt roots plus ECDSA backup keys) that match
   `attestation.app`'s real certificate chain. Upstream rotates or extends that
   pin-set on Let's Encrypt's own root schedule, which this fork does not
   control. Each time, re-check our regenerated `attestation.hugmesh.net`
   pin-set against the change. A stale pin-set makes the app fail TLS against
   our own server with no obvious error.
3. **`RemoteVerifyJob`'s `DOMAIN`/`BASE_URL` handling** (`patches.md` §1). If
   upstream changes how it derives `BASE_URL`/`CHALLENGE_URL`/`VERIFY_URL`, or
   adds a port, the single-constant patch may no longer be enough.
4. **New `AUDITOR_APP_PACKAGE_NAME_*`/`SIGNATURE_DIGEST_*` build-type variants**
   (`patches.md` §5). This matters only if you ever adopt the optional
   local-audit patch.

### Maintenance process (run on every upstream Auditor release)

1. `git fetch upstream main && git log <old-pinned-commit>..upstream/main --oneline`
   — review what changed.
2. Re-diff the four patches `build.Dockerfile` applies (`patches.md` §1, §2, §3,
   §4; §3 is cosmetic) against the new tree BEFORE rebasing. Re-check the two
   risks above in particular: the applicationId/namespace split, and whether the
   `network_security_config.xml` pin-set changed shape (not just values).
3. Update `AUDITOR_COMMIT` in `build.Dockerfile` to the new pinned SHA.
4. Re-apply the patches. The `sed`-based reapply in `build.Dockerfile` IS the
   maintenance mode; it is small and mechanical on purpose, not a manual merge
   each time. If a `sed`'s `grep -q` gate fails, the source shape changed and the
   patch needs a hand update. Never skip it silently.
5. Re-run the build and re-verify with `apksigner verify --print-certs`. Confirm
   the signing-cert digest is **UNCHANGED** (same keystore and alias); see
   `COUPLING.md`. A digest change breaks update continuity for every device that
   trusts the old one, and desyncs the AttestationServer's
   `AUDITOR_SIGNER_DIGEST` pin until you update that too.
6. If upstream touched the pin-set, re-verify that `attestation.hugmesh.net`'s
   certificate still chains under the fork's pins (or regenerate per
   `patches.md` §2).
7. Record the new pinned commit and sync date at the bottom of this section.

**Last synced against upstream:** not yet performed. This directory was built
from a static source read as of 2026-07-17 (exact commit SHA not captured; see
the `AUDITOR_COMMIT` placeholder in `build.Dockerfile`). Pin a real commit and
record the first real sync here.

---

## What is patched vs. upstream

See `patches.md` for the full file:line detail. Summary:

| # | What | Mandatory? |
|---|---|---|
| 1 | `RemoteVerifyJob.java` `DOMAIN` constant -> `attestation.hugmesh.net` | Yes — this is the entire point of the fork |
| 2 | `network_security_config.xml` hostname + **certificate pin-set** | Yes — hostname is scripted; pin-set is a manual, CA-dependent regeneration |
| 3 | `README.md` / `.github/FUNDING.yml` cosmetic links | No, cosmetic only |
| 4 | `app/build.gradle.kts` `applicationId` -> `systems.hugmesh.auditor` (namespace untouched) | Yes |
| 5 | `AttestationProtocol.java` local device-to-device audit identity constants | No — only for local phone-to-phone QR audits, irrelevant to the remote-server flow; not applied by default |

---

## Build + sign + distribute + couple — the full runbook

### 1. Generate the release signing key (once, offline)

```sh
./gen-auditor-signing-key.sh
```

This follows `scripts/gen-keystores.sh`'s custody rules. The script generates
the key OFFLINE (it does no networking), on a machine meant to hold it
long-term, and never commits it. Right after generation, move the `.jks` and its
password to the **pki USB / Vault**, the same custody chain the cluster CA key
(`cluster-ca.key`) uses. The script prints the release-cert SHA-256 digest at the
end. That is the value `COUPLING.md` tracks.

### 2. Build the unsigned APK

```sh
docker build -f build.Dockerfile \
  --build-arg AUDITOR_COMMIT=<pinned-commit-sha> \
  -o out .
# -> out/app-release-unsigned.apk
```

`build.Dockerfile` clones GrapheneOS/Auditor at a **pinned commit**, applies the
mandatory patches (§1/§2-hostname/§3/§4 from `patches.md`) and runs
`./gradlew assembleRelease`. **It uses and references no keystore of any kind**;
see "Secret hygiene" below. Before you trust this build for a real device
population, also do the manual pin-set regeneration (`patches.md` §2) inside the
cloned tree. The Dockerfile patches only the hostname, because the pins depend
on `attestation.hugmesh.net`'s real certificate chain, which it cannot know at
build time.

### 3. Sign the APK (offline, separately)

```sh
./sign-and-digest.sh \
  --unsigned out/app-release-unsigned.apk \
  --keystore /path/to/pki-usb/hugmesh-auditor-release.jks \
  --alias hugmesh-auditor \
  --out out/app-release.apk
```

Run this on the SAME offline machine (or with the pki USB / Vault keystore
mounted). Never copy the keystore onto a build server. The script signs the APK
with `apksigner`, verifies the result and prints the signer-cert digest again.
That digest must be identical to step 1's.

### 4. Couple to the AttestationServer

Before either artifact ships to real devices, wire the digest from step 1/3 into
the server side. `COUPLING.md` has the full table and the exact file to edit:
the `AUDITOR_SIGNER_DIGEST` build ARG in
`specs/cluster/manifests/attestation-server/Dockerfile`, currently the
placeholder `SET-FROM-FORK-RELEASE-CERT`.

### 5. Distribute to phones

Distribution is **already wired**. `scripts/phone-wizard.sh` has an `attest`
verb that installs this fork with `--auditor-apk <path>` and pins the signer
with `--auditor-signer-sha256 <hex>` (fail-closed on mismatch), then prints the
pairing runbook for the AttestationServer at `--attestation-url`. `make
phone-attest` wraps it (`AUDITOR_APK=`, `AUDITOR_SIGNER_SHA256=`,
`ATTESTATION_URL=`). The `wizard` verb runs `attest` as step 4 of 8, right
after `flash` (see [MDM.md](../../docs/MDM.md#attest--attestationserver-pairing-via-the-hugmesh-forked-auditor)).

```sh
scripts/phone-wizard.sh attest --serial <S> --auditor-apk out/app-release.apk \
  --auditor-signer-sha256 <fork-cert-sha256> --attestation-url <attestation-server-console-url>

# by hand, to check the signer digest before or after:
apksigner verify --print-certs out/app-release.apk
```

This directory produces the artifact `attest` consumes. It does not modify
`phone-wizard.sh`. The `attest` code path was written after the first draft of
this runbook. Like the APK itself, it has never run against a real phone and
AttestationServer pair.

---

## Secret hygiene (read before touching this Dockerfile)

**The signing key never enters the container build.** This is deliberate. An
earlier draft of this fork planned to `COPY` the keystore into a build stage.
That would have baked a long-term signing key into an image layer, and any
registry or cache holding the layer could recover it forever. This design avoids
that:

- `build.Dockerfile` produces `app-release-unsigned.apk`. It has no
  `keystore.properties`, no `.jks` and no `signingConfig` reference. Nothing
  can leak because signing material never reaches Docker.
- `sign-and-digest.sh` signs **out of the container**, directly against the
  offline keystore, on whatever machine or medium already holds it (pki USB or
  Vault mount). The keystore path is always a script argument. It is never
  hardcoded, embedded or logged.
- If you ever must sign inside a container (say, a CI system that signs as part
  of a pipeline), the only acceptable pattern is a BuildKit
  `--mount=type=secret` (`docker build --secret id=keystore,src=<path> ...`,
  read from a `RUN --mount=type=secret` step). Never `COPY`. **That path is not
  implemented here.** The default and recommended posture is out-of-container
  signing, as `scripts/gen-keystores.sh` keeps the cluster CA key off every
  build and image.

Check this yourself before you trust any change to `build.Dockerfile`:

```sh
grep -i 'COPY.*\(jks\|keystore\|properties\)' build.Dockerfile   # must be empty
```

---

## What has NOT been verified (be honest about this)

- **The APK has not been built.** Nobody has run `build.Dockerfile` end to end:
  this environment has no Android SDK and no egress-capable build host. The
  NDK omission, the JDK-17-toolchain-under-JDK-21-host auto-provisioning and the
  non-interactive `sdkmanager --licenses` flow are inferred from repo metadata
  (`build.gradle.kts`, `.github/workflows/build.yml`,
  `verification-metadata.xml`). No successful build log shows them.
- **`AUDITOR_COMMIT` is a placeholder** (`REPLACE-WITH-PINNED-COMMIT-SHA` in
  `build.Dockerfile`). No commit is pinned, and the Dockerfile refuses to build
  past the placeholder.
- **The `network_security_config.xml` pin-set has not been regenerated** against
  `attestation.hugmesh.net`'s real certificate chain. `build.Dockerfile` patches
  only the hostname. Whether the inherited Let's Encrypt pins already work
  depends on which CA issues that server's certificate. Nobody checked.
- **No signing key has been generated.** `gen-auditor-signing-key.sh` is ready
  and unrun. There is no real `AUDITOR_SIGNER_DIGEST` value yet, which is why
  `specs/cluster/manifests/attestation-server/Dockerfile` still carries the
  `SET-FROM-FORK-RELEASE-CERT` placeholder (see `COUPLING.md`).
- **Build reproducibility is unresolved.** Upstream pins its dependency
  checksums (`verify-metadata=true`), but nobody confirmed end-to-end
  reproducibility.
- **The `attest` verb has not been run against this fork's APK.** `--auditor-apk`
  exists in `scripts/phone-wizard.sh`, and its tests use mocked adb, but there
  is no real APK to install yet.

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

Upstream GrapheneOS/Auditor is MIT licensed. This fork inherits that license for
the patched source. Nothing in this directory (scripts, Dockerfile, docs)
changes that. Only the constants listed in `patches.md` differ from upstream.

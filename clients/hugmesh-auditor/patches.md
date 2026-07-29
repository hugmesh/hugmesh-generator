# HugMesh Auditor fork — exact source patches

STATUS: NOT BUILT, NOT BUILD-VERIFIED. These patches are derived from a static
source read of `https://github.com/GrapheneOS/Auditor` (`main`, as read
2026-07-17 — **pin the exact commit SHA in `build.Dockerfile`'s `AUDITOR_COMMIT`
ARG before building; it is a placeholder today**). They have not been applied
and compiled in this environment (no Android SDK here). Treat every entry as a
patch spec to smoke-test, not a proven diff. All paths are relative to a fresh
clone of the upstream repo.

`build.Dockerfile` applies patches 1, 3 and 4 below via `sed` automatically.
Patch 2's hostname half is sed'd too — its **pin-set is NOT scripted** and
needs a manual edit every time (see below). Patch 5 is optional and NOT
applied by `build.Dockerfile` by default.

---

## 1. Remote-attestation server domain (the flow this fork exists for)

| File | Line | Current | Patch |
|---|---|---|---|
| `app/src/main/java/app/attestation/auditor/RemoteVerifyJob.java` | 49 | `static final String DOMAIN = "attestation.app";` | `static final String DOMAIN = "attestation.hugmesh.systems";` |

Everything downstream of `DOMAIN` recomputes automatically — **do not**
hand-patch these separately:

- line 50: `BASE_URL = "https://" + DOMAIN + "/auditor/"`
- line 51: `CHALLENGE_URL = BASE_URL + "challenge"`
- line 52: `VERIFY_URL = BASE_URL + "verify"`
- `AttestationActivity.java:61`: `TUTORIAL_URL = "https://" + RemoteVerifyJob.DOMAIN + "/tutorial"`
- `AttestationActivity.java:121` (QR-pairing scan handler, `EnableRemoteVerify`,
  lines 118-139): `!RemoteVerifyJob.DOMAIN.equals(values[0])` — the acceptance
  check for the 4-field space-separated QR payload
  (`domain userId subscribeKey verifyInterval`). It automatically starts
  accepting `attestation.hugmesh.systems` once `DOMAIN` is patched — no
  separate edit needed.

HTTPS and port 443 are hardcoded (`"https://"` literal, no port anywhere ->
Java `URL` default 443). `DOMAIN = "host:port"` is theoretically parseable by
Java's `URL` but is untested upstream — do not rely on a non-standard port
without a smoke test.

---

## 2. `network_security_config.xml` — hostname AND pin-set (do not stop at the hostname)

| File | Line | Current | Patch |
|---|---|---|---|
| `app/src/main/res/xml/network_security_config.xml` | 5 | `<domain includeSubdomains="true">attestation.app</domain>` | `<domain includeSubdomains="true">attestation.hugmesh.systems</domain>` |

**CRITICAL — read this before shipping a build.** Lines 7-25 of the same
`<domain-config>` block pin 6 SHA-256 values (ISRG Root X1 / X2 / YE / YR —
all Let's Encrypt roots — plus two ECDSA secp256r1/secp384r1 "backup key"
pins). `cleartextTrafficPermitted="false"` is set on the same block.

**If `attestation.hugmesh.systems`'s real TLS certificate does not chain to
one of these exact pinned roots/keys, every connection TLS HARD-FAILS with a
pinning error** — even though the `<domain>` hostname text was correctly
patched. The app will look "installed and configured" and simply never be
able to reach the server. This is the #1 way this fork silently breaks.

Fix: regenerate the pin-set for the real chain actually served by
`attestation.hugmesh.systems` before shipping:

```bash
# Get the leaf cert's public-key pin (SHA-256 of the DER SubjectPublicKeyInfo,
# base64 — the format network_security_config.xml <pin digest="SHA-256"> expects).
openssl s_client -connect attestation.hugmesh.systems:443 -showcerts </dev/null 2>/dev/null \
  | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary | openssl enc -base64
```

Run this once per certificate in the real chain (leaf, intermediate(s), and —
for pin robustness across renewals — the issuing root or a documented backup
key), and replace the `<pin digest="SHA-256">...</pin>` values at lines 7-25
by hand. **This step is CA-dependent and cannot be scripted blindly.** If
`attestation.hugmesh.systems` chains to public Let's Encrypt roots (same as
upstream `attestation.app`), the inherited pins may already work unmodified.
If it chains to an internal/Vault PKI root (the pattern this platform uses
elsewhere), **the pins must be regenerated or the app will be permanently
unable to reach the server** — no error dialog will explain why; it will just
look like a dead network call.

Re-verify this section on every upstream rebase too (Let's Encrypt root
rotation is exactly the kind of thing that silently invalidates a stale
pin-set — see the maintenance section in `README.md`).

---

## 3. Cosmetic-only (safe to defer/batch — gate nothing)

| File | Line | Current |
|---|---|---|
| `README.md` | 1 | `See the overview of the project at https://attestation.app/about.` |
| `.github/FUNDING.yml` | 2 | `custom: https://attestation.app/donate` |

---

## 4. `applicationId` rename (package identity, NOT namespace)

| File | Line | Current | Patch |
|---|---|---|---|
| `app/build.gradle.kts` | 48 | `applicationId = "app.attestation.auditor"` | `applicationId = "systems.hugmesh.auditor"` |

**Leave `namespace = "app.attestation.auditor"` (line 45) unchanged.** The
manifest (`app/src/main/AndroidManifest.xml`) has no `package=` attribute, so
components (`.AttestationActivity`, `.QRScannerActivity`, `.BootReceiver`,
`.RemoteVerifyJob`, `.SubmitSampleJob`) resolve against `namespace`, not
`applicationId` — no Java source, package directories, or manifest entries
need to move. `applicationId != namespace` is a standard, fully-supported
Gradle/AGP pattern. IDE-only `tools:context` hints in
`activity_attestation.xml` / `content_attestation.xml` / `menu_attestation.xml`
still reference the old namespace-qualified class names — cosmetic, compiles
unchanged.

**Upstream-rebase risk (see README.md):** if a future upstream release adds a
manifest `package=` attribute, this applicationId/namespace split breaks and
this whole patch needs re-deriving — check for that on every rebase.

---

## 5. Local device-to-device QR audit identity (OPTIONAL — skip unless needed)

A **separate, third** hardcoded-identity mechanism from §1/§2. It does **not**
gate the `RemoteVerifyJob` -> `attestation.hugmesh.systems` remote-server
flow (`verifySerialized()` is called only from `AttestationActivity.java:339`,
the local on-device QR-scan-the-other-phone flow — never from
`RemoteVerifyJob.java`). **Irrelevant to the remote-server flow this fork is
built for — skip this patch entirely unless two fork copies must locally
QR-audit each other.** `build.Dockerfile` does NOT apply this patch by
default.

| File | Lines | Constant |
|---|---|---|
| `app/src/main/java/app/attestation/auditor/AttestationProtocol.java` | 230-238 | `AUDITOR_APP_PACKAGE_NAME_RELEASE = "app.attestation.auditor"` (+ `_PLAY`, `_DEBUG` variants) and matching `AUDITOR_APP_SIGNATURE_DIGEST_RELEASE/_PLAY/_DEBUG` hex constants, e.g. `RELEASE digest = "990E04F0864B19F14F84E0E432F7A393F297AB105A22C1E1B10B442A4A62C42C"` |

If two copies of the renamed fork need to locally QR-audit each other, patch:

```java
AUDITOR_APP_PACKAGE_NAME_RELEASE = "systems.hugmesh.auditor";
AUDITOR_APP_SIGNATURE_DIGEST_RELEASE = "<SHA-256 of the release signing cert, uppercase hex>"; // see gen-auditor-signing-key.sh
```

Both sides of every local-audit pair must run a build with this updated
constant — it is compiled in, not runtime-configurable (no
`BuildConfig.APPLICATION_ID` reference exists anywhere in the tree). Without
this patch, a renamed+re-signed fork throws
`GeneralSecurityException("invalid Auditor app package name: " + packageName)`
(`AttestationProtocol.java:575`) or `"invalid Auditor app signing key"`
(`:558`) when two fork copies try to audit each other locally — the
`RemoteVerifyJob` server path (§1) is unaffected either way.

This is the client-side twin of the *optional* local-audit constants in the
self-hosted AttestationServer's `AttestationProtocol.java:164-172`
(`specs/cluster/manifests/attestation-server/Dockerfile`) — that server-side
patch is about the **remote** attestation flow (mandatory, always patched);
this one is about **local device-to-device** audits (optional, off by
default). Don't confuse the two.

---

## Patch application order (as `build.Dockerfile` does it)

1. Clone at the pinned `AUDITOR_COMMIT`.
2. `sed` §1 (`RemoteVerifyJob.java` DOMAIN).
3. `sed` §2's hostname only (the pin-set is a **manual, CA-dependent step —
   not scripted**; the Dockerfile prints the regeneration command as a build
   log comment/warning).
4. `sed` §3 (cosmetic).
5. `sed` §4 (applicationId).
6. §5 is commented out / not applied.

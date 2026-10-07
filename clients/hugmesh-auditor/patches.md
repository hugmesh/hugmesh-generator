# HugMesh Auditor fork — exact source patches

STATUS: NOT BUILT, NOT BUILD-VERIFIED. These patches come from a static read of
`https://github.com/GrapheneOS/Auditor` (`main`, as read 2026-07-17 — **pin the
exact commit SHA in `build.Dockerfile`'s `AUDITOR_COMMIT` ARG before building;
it is a placeholder today**). Nobody has applied and compiled them here (no
Android SDK). Treat every entry as a patch spec to smoke-test, not a proven
diff. All paths are relative to a fresh clone of the upstream repo.

`build.Dockerfile` applies patches 1, 3 and 4 below via `sed`. It also applies
patch 2's hostname half. Patch 2's **pin-set is NOT scripted** and needs a
manual edit every time (see below). Patch 5 is optional, and `build.Dockerfile`
does NOT apply it by default.

---

## 1. Remote-attestation server domain (the flow this fork exists for)

| File | Line | Current | Patch |
|---|---|---|---|
| `app/src/main/java/app/attestation/auditor/RemoteVerifyJob.java` | 49 | `static final String DOMAIN = "attestation.app";` | `static final String DOMAIN = "attestation.hugmesh.net";` |

Everything downstream of `DOMAIN` recomputes. **Do not** hand-patch these:

- line 50: `BASE_URL = "https://" + DOMAIN + "/auditor/"`
- line 51: `CHALLENGE_URL = BASE_URL + "challenge"`
- line 52: `VERIFY_URL = BASE_URL + "verify"`
- `AttestationActivity.java:61`: `TUTORIAL_URL = "https://" + RemoteVerifyJob.DOMAIN + "/tutorial"`
- `AttestationActivity.java:121` (QR-pairing scan handler, `EnableRemoteVerify`,
  lines 118-139): `!RemoteVerifyJob.DOMAIN.equals(values[0])`. This is the
  acceptance check for the 4-field space-separated QR payload
  (`domain userId subscribeKey verifyInterval`). It accepts
  `attestation.hugmesh.net` as soon as `DOMAIN` is patched. It needs no separate
  edit.

HTTPS and port 443 are hardcoded (the `"https://"` literal, no port anywhere,
so Java's `URL` defaults to 443). `DOMAIN = "host:port"` should parse in Java's
`URL`, but upstream has not tested it. Do not rely on a non-standard port
without a smoke test.

---

## 2. `network_security_config.xml` — hostname AND pin-set (do not stop at the hostname)

| File | Line | Current | Patch |
|---|---|---|---|
| `app/src/main/res/xml/network_security_config.xml` | 5 | `<domain includeSubdomains="true">attestation.app</domain>` | `<domain includeSubdomains="true">attestation.hugmesh.net</domain>` |

**CRITICAL — read this before you ship a build.** Lines 7-25 of the same
`<domain-config>` block pin 6 SHA-256 values: ISRG Root X1 / X2 / YE / YR (all
Let's Encrypt roots) and two ECDSA secp256r1/secp384r1 "backup key" pins. The
same block sets `cleartextTrafficPermitted="false"`.

**If `attestation.hugmesh.net`'s real TLS certificate does not chain to one of
these exact pinned roots or keys, every connection TLS HARD-FAILS with a pinning
error.** That holds even though you patched the `<domain>` hostname correctly.
The app looks "installed and configured" and never reaches the server. This is
the #1 way the fork breaks silently.

The fix is to regenerate the pin-set for the chain `attestation.hugmesh.net`
really serves, before you ship:

```bash
# Get the leaf cert's public-key pin (SHA-256 of the DER SubjectPublicKeyInfo,
# base64 — the format network_security_config.xml <pin digest="SHA-256"> expects).
openssl s_client -connect attestation.hugmesh.net:443 -showcerts </dev/null 2>/dev/null \
  | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary | openssl enc -base64
```

Run it once per certificate in the real chain: the leaf, the intermediate(s)
and, for pin robustness across renewals, the issuing root or a documented backup
key. Replace the `<pin digest="SHA-256">...</pin>` values at lines 7-25 by hand.
**This step depends on the CA and cannot be scripted blindly.** If
`attestation.hugmesh.net` chains to public Let's Encrypt roots (as upstream's
`attestation.app` does), the inherited pins may work unmodified. If it chains to
an internal or Vault PKI root (the pattern this platform uses elsewhere), **you
must regenerate the pins, or the app can never reach the server**. No error
dialog will say why. It will look like a dead network call.

Re-verify this section on every upstream rebase too. A Let's Encrypt root
rotation is the kind of change that invalidates a stale pin-set without a sound
(see the maintenance section in `README.md`).

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
`applicationId`. No Java source, package directory or manifest entry needs to
move. `applicationId != namespace` is a standard, supported Gradle/AGP pattern.
The IDE-only `tools:context` hints in `activity_attestation.xml`,
`content_attestation.xml` and `menu_attestation.xml` still use the old
namespace-qualified class names. That is cosmetic, and the build compiles
unchanged.

**Upstream-rebase risk (see README.md):** if a future upstream release adds a
manifest `package=` attribute, the applicationId/namespace split breaks and this
whole patch needs re-deriving. Check for that on every rebase.

---

## 5. Local device-to-device QR audit identity (OPTIONAL — skip unless needed)

A **separate, third** hardcoded-identity mechanism, apart from §1 and §2. It does
**not** gate the `RemoteVerifyJob` -> `attestation.hugmesh.net` remote-server
flow. `verifySerialized()` is called only from `AttestationActivity.java:339`,
the local on-device flow where one phone scans the other's QR code, and never
from `RemoteVerifyJob.java`. **It is irrelevant to the remote-server flow this
fork is built for. Skip this patch entirely unless two fork copies must
locally QR-audit each other.** `build.Dockerfile` does NOT apply it by default.

| File | Lines | Constant |
|---|---|---|
| `app/src/main/java/app/attestation/auditor/AttestationProtocol.java` | 230-238 | `AUDITOR_APP_PACKAGE_NAME_RELEASE = "app.attestation.auditor"` (+ `_PLAY`, `_DEBUG` variants) and matching `AUDITOR_APP_SIGNATURE_DIGEST_RELEASE/_PLAY/_DEBUG` hex constants, e.g. `RELEASE digest = "990E04F0864B19F14F84E0E432F7A393F297AB105A22C1E1B10B442A4A62C42C"` |

If two copies of the renamed fork must locally QR-audit each other, patch:

```java
AUDITOR_APP_PACKAGE_NAME_RELEASE = "systems.hugmesh.auditor";
AUDITOR_APP_SIGNATURE_DIGEST_RELEASE = "<SHA-256 of the release signing cert, uppercase hex>"; // see gen-auditor-signing-key.sh
```

The digest declarations are line-wrapped upstream (`... _RELEASE =` on one line,
the quoted hex on the next). A one-line `sed` such as the commented-out Patch 5
block in `build.Dockerfile` (`AUDITOR_APP_SIGNATURE_DIGEST_RELEASE = ".*"`)
therefore matches nothing. Match the stock digest literal instead, the way the
server's `Dockerfile` does for its own copy of the constant.

Both sides of every local-audit pair must run a build with this updated
constant. It is compiled in and not configurable at run time (no
`BuildConfig.APPLICATION_ID` reference exists anywhere in the tree). Without
this patch, a renamed and re-signed fork throws
`GeneralSecurityException("invalid Auditor app package name: " + packageName)`
(`AttestationProtocol.java:575`) or `"invalid Auditor app signing key"` (`:558`)
when two fork copies audit each other locally. The `RemoteVerifyJob` server path
(§1) is unaffected either way.

This is the client-side twin of the *optional* local-audit constants in the
self-hosted AttestationServer's `AttestationProtocol.java:164-172`
(`specs/cluster/manifests/attestation-server/Dockerfile`). The server-side patch
serves the **remote** attestation flow (mandatory, always applied). This one
serves **local device-to-device** audits (optional, off by default). Do not
confuse the two.

---

## Patch application order (as `build.Dockerfile` does it)

1. Clone at the pinned `AUDITOR_COMMIT`.
2. `sed` §1 (`RemoteVerifyJob.java` DOMAIN).
3. `sed` §2's hostname only. The pin-set is a **manual step that depends on the
   CA and is not scripted**. The Dockerfile carries the regeneration command
   only as a `#` comment beside the hostname patch, and prints nothing at build
   time.
4. `sed` §3 (cosmetic).
5. `sed` §4 (applicationId).
6. §5 is commented out / not applied.

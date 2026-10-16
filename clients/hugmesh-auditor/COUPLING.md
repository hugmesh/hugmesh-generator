# Coupling checklist — HugMesh Auditor fork <-> self-hosted AttestationServer

Three identity bindings must agree between this Android client (the fork) and
the self-hosted AttestationServer backend
(`specs/cluster/manifests/attestation-server/`). If any one differs, the system
fails closed. The symptom is usually a silent connection failure or an
"attestation rejected" message that does not name the mismatch.

| # | Client side (this fork) | Server side (AttestationServer) | Failure mode if mismatched |
|---|---|---|---|
| 1 | `RemoteVerifyJob.DOMAIN` = `attestation.hugmesh.net` (`patches.md` §1) + `network_security_config.xml` hostname **and pin-set** (`patches.md` §2) | `AttestationServer.java`'s `DOMAIN` constant, sed'd via the `ATTESTATION_DOMAIN` build ARG in `specs/cluster/manifests/attestation-server/Dockerfile` (line 44: `ARG ATTESTATION_DOMAIN=attestation.hugmesh.net`) — plus the server's actual TLS cert must chain to whatever roots the fork's pin-set trusts | TLS handshake failure / certificate-pinning rejection — the app cannot reach the server at all. This is the #1 way the fork "looks installed but does nothing." |
| 2 | Release signing-cert SHA-256 digest, computed via `gen-auditor-signing-key.sh` (method a) and cross-checked via `sign-and-digest.sh` (method b) | `AttestationProtocol.java`'s `AUDITOR_APP_SIGNATURE_DIGEST_RELEASE`, sed'd via the `AUDITOR_SIGNER_DIGEST` build ARG in **`specs/cluster/manifests/attestation-server/Dockerfile` line 51** — currently the placeholder `ARG AUDITOR_SIGNER_DIGEST=SET-FROM-FORK-RELEASE-CERT` | Server rejects every attestation submission from this app as coming from an untrusted signer. This is a platform-level KeyMint `AttestationApplicationId` check the server validates on its own. There is no partial-credit or fallback path. A stale or placeholder digest means 100% of attestations fail, with no obvious client-side symptom. |
| 3 | `applicationId = "systems.hugmesh.auditor"` (`patches.md` §4) | `AttestationProtocol.java`'s `AUDITOR_APP_PACKAGE_NAME_RELEASE`, sed'd via the `AUDITOR_PACKAGE` build ARG in **`specs/cluster/manifests/attestation-server/Dockerfile` line 50** (`ARG AUDITOR_PACKAGE=systems.hugmesh.auditor`) | Server rejects attestations that report a package name it does not recognize. |

## The exact placeholder that must be replaced

**File:** `specs/cluster/manifests/attestation-server/Dockerfile`

```
ARG AUDITOR_PACKAGE=systems.hugmesh.auditor        # line 50 — already correct, matches patches.md §4
ARG AUDITOR_SIGNER_DIGEST=SET-FROM-FORK-RELEASE-CERT   # line 51 — PLACEHOLDER, replace with the real digest
```

`AUDITOR_PACKAGE` already matches the fork's `applicationId`. Leave it alone
once `patches.md` §4 is applied as written. `AUDITOR_SIGNER_DIGEST` is the one
value that does not exist until the signing key does. Do these steps in order:

1. Run `gen-auditor-signing-key.sh` (offline). It prints
   `AUDITOR_SIGNER_DIGEST=<HEX>`.
2. Rebuild the AttestationServer image with
   `--build-arg AUDITOR_SIGNER_DIGEST=<HEX>`. Do not ship a cluster-bound server
   image with the placeholder still in place. The server Dockerfile's own
   `grep -q` gate proves only that the sed *applied*, not that the digest is
   *real*; its comments say so.
3. Build the fork's unsigned APK (`build.Dockerfile`).
4. Sign it with the same key (`sign-and-digest.sh --keystore <the same .jks
   from step 1>`). It prints `AUDITOR_SIGNER_DIGEST=<HEX>` again. This value
   MUST equal step 1's. If it does not, someone used the wrong keystore or
   alias, and neither artifact should ship.
5. Set the SAME `<HEX>` as phone-wizard's `--auditor-signer-sha256` (the `attest`
   verb's pin; see `README.md`'s distribution section), so the install-time pin
   matches too.

## Domain coupling (row 1)

The fork's `RemoteVerifyJob.DOMAIN` (`patches.md` §1) and the server's
`ATTESTATION_DOMAIN` build ARG both default to the literal string
`attestation.hugmesh.net`. Apply the patch sets as written and this row
holds, with ONE manual step left: the fork's `network_security_config.xml`
pin-set (`patches.md` §2) must match `attestation.hugmesh.net`'s real
certificate chain. No build-arg sets it. You edit it by hand once, after you
know the real chain. Check it again on every upstream rebase, because a Let's
Encrypt root rotation upstream can invalidate it without a sound.

## Summary — do not ship any of these independently

Ship any ONE of {AttestationServer image, signed Auditor APK, phone-wizard
install} without checking this table against the CURRENT values of the other
two, and a working attestation flow breaks silently. Treat steps 1-5 as one
atomic release, not three independent ones.

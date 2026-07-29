# Coupling checklist — HugMesh Auditor fork <-> self-hosted AttestationServer

Three independent identity bindings must ALL agree between this Android
client (the fork) and the self-hosted AttestationServer backend
(`specs/cluster/manifests/attestation-server/`), or the system fails closed —
usually as a silent-looking connection or "attestation rejected" failure, not
a clear error pointing at the actual mismatch.

| # | Client side (this fork) | Server side (AttestationServer) | Failure mode if mismatched |
|---|---|---|---|
| 1 | `RemoteVerifyJob.DOMAIN` = `attestation.hugmesh.systems` (`patches.md` §1) + `network_security_config.xml` hostname **and pin-set** (`patches.md` §2) | `AttestationServer.java`'s `DOMAIN` constant, sed'd via the `ATTESTATION_DOMAIN` build ARG in `specs/cluster/manifests/attestation-server/Dockerfile` (line 34: `ARG ATTESTATION_DOMAIN=attestation.hugmesh.systems`) — plus the server's actual TLS cert must chain to whatever roots the fork's pin-set trusts | TLS handshake failure / certificate-pinning rejection — the app cannot reach the server at all. This is the #1 way the fork "looks installed but does nothing." |
| 2 | Release signing-cert SHA-256 digest, computed via `gen-auditor-signing-key.sh` (method a) and cross-checked via `sign-and-digest.sh` (method b) | `AttestationProtocol.java`'s `AUDITOR_APP_SIGNATURE_DIGEST_RELEASE`, sed'd via the `AUDITOR_SIGNER_DIGEST` build ARG in **`specs/cluster/manifests/attestation-server/Dockerfile` line 41** — currently the placeholder `ARG AUDITOR_SIGNER_DIGEST=SET-FROM-FORK-RELEASE-CERT` | Server rejects every attestation submission from this app as coming from an untrusted signer. This is a platform-level KeyMint `AttestationApplicationId` check the server independently validates — there is no partial-credit or fallback path. A stale/placeholder digest means 100% of attestations fail, with no obvious client-side symptom. |
| 3 | `applicationId = "systems.hugmesh.auditor"` (`patches.md` §4) | `AttestationProtocol.java`'s `AUDITOR_APP_PACKAGE_NAME_RELEASE`, sed'd via the `AUDITOR_PACKAGE` build ARG in **`specs/cluster/manifests/attestation-server/Dockerfile` line 40** (`ARG AUDITOR_PACKAGE=systems.hugmesh.auditor`) | Server rejects attestations reporting a package name it does not recognize as valid. |

## The exact placeholder that must be replaced

**File:** `specs/cluster/manifests/attestation-server/Dockerfile`

```
ARG AUDITOR_PACKAGE=systems.hugmesh.auditor        # line 40 — already correct, matches patches.md §4
ARG AUDITOR_SIGNER_DIGEST=SET-FROM-FORK-RELEASE-CERT   # line 41 — PLACEHOLDER, replace with the real digest
```

`AUDITOR_PACKAGE`'s default already matches this fork's `applicationId` — no
action needed there once patches.md §4 is applied as-is. `AUDITOR_SIGNER_DIGEST`
is the one value that does not exist until the signing key does. Sequence:

1. Run `gen-auditor-signing-key.sh` (offline). It prints
   `AUDITOR_SIGNER_DIGEST=<HEX>`.
2. Rebuild the AttestationServer image with
   `--build-arg AUDITOR_SIGNER_DIGEST=<HEX>` (replacing the placeholder — do
   not ship a cluster-bound server image with the placeholder still in
   place; the server Dockerfile's own `grep -q` gate only proves the sed
   *applied*, not that the digest is *real*, per its own comments).
3. Build the fork's unsigned APK (`build.Dockerfile`).
4. Sign it with the same key (`sign-and-digest.sh --keystore <the same .jks
   from step 1>`). It prints `AUDITOR_SIGNER_DIGEST=<HEX>` again — this MUST
   equal step 1's value. If it doesn't, the wrong keystore/alias was used
   somewhere and neither artifact should ship.
5. Set the SAME `<HEX>` as phone-wizard's `--apk-signer-sha256` (see
   `README.md`'s distribution section) so the install-time pin matches too.

## Domain coupling (row 1)

Both the fork's `RemoteVerifyJob.DOMAIN` (`patches.md` §1) and the server's
`ATTESTATION_DOMAIN` build ARG default to the literal string
`attestation.hugmesh.systems` already — this row is satisfied by applying
the patch sets as documented, with ONE remaining manual step: the fork's
`network_security_config.xml` pin-set (`patches.md` §2) must actually match
`attestation.hugmesh.systems`'s real certificate chain. That is not a
build-arg — it's a hand-edit gated on knowing the real cert chain, done once
(and re-verified on every upstream rebase, since a Let's-Encrypt root
rotation upstream can silently invalidate it).

## Summary — do not ship any of these independently

Building/shipping ANY ONE of {AttestationServer image, signed Auditor APK,
phone-wizard install} without re-checking this table against the CURRENT
values of the other two is how a previously-working attestation flow breaks
silently. Treat steps 1-5 above as one atomic release, not three independent
ones.

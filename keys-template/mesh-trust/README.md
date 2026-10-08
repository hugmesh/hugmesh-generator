# Foreign-mesh trust store — Phase 7 cross-mesh base admission (pubkeys ONLY)

This directory is the **out-of-band custody root** for the public verifying keys
of the **foreign meshes** whose code bases we are willing to ingest. It follows
the custody model of the device-registry `registry-pub.ed25519` exactly:
**pubkeys only**, **staged out-of-band**, **never a real key committed**,
**fail-closed when absent**.

## Layout

```
keys-template/mesh-trust/
  README.md                                  (this file — committed)
  <mesh-id>/foreign-provenance-pub.ed25519   (the foreign mesh's PROVENANCE
                                              signing PUBLIC half — base64 of the
                                              X.509 SubjectPublicKeyInfo DER, i.e.
                                              exactly the form registry-pub.ed25519
                                              uses. Staged OUT-OF-BAND, NOT committed.)
  example-mesh/foreign-provenance-pub.ed25519.example
                                             (a committed PLACEHOLDER — clearly an
                                              `.example`, never a real key.)
```

`<mesh-id>` is a strict DNS label. The gate rejects anything else, so the path can
never traverse. It matches the mesh id in `templates/mesh-trust/registry.json` and
in the foreign base's signed `.hugmesh-provenance.json` `base.meshId`.

## How it is used (the no-TOFU rule)

`scripts/ingest-foreign-base.sh` finds `<mesh-id>/foreign-provenance-pub.ed25519`
in this store and rebuilds the PEM (`base64 -d | openssl pkey -pubin -inform DER`).
It **checks that the key is an Ed25519 PUBLIC key** (openssl `-pubin` rejects a
private key, so a mistaken or hostile private key can never be used). Then it
verifies the foreign base's detached signature against **THIS staged key**, **never**
against any `publicKey` the base envelope advertises.

- **No trust-on-first-use.** A foreign mesh with **no entry here** has no pinned
  key, so the gate **fails closed**: an unknown mesh is never admitted. A mesh
  that is unknown, disabled or revoked in `registry.json` is refused too.
- **Admitting a new foreign mesh is a deliberate act.** Add its `registry.json`
  entry (pinned digest + minGeneration) **and** stage its public half here
  out-of-band. These are two independent additions, both intentional.
- **Rotation.** When a foreign mesh rotates its provenance signing key, re-stage
  the new public half here **before** it signs a base you mean to pull. A stale
  key fails closed: that mesh's bases are rejected until re-keyed.

## NEVER commit a real key

Real key files are **git-ignored** (the
`keys-template/mesh-trust/*/foreign-provenance-pub.ed25519` rule in `.gitignore`).
Only the `README.md` and the `*.example` placeholder are committed.
`scripts/secret-scan.sh` flags PEM and OpenSSH private-key headers only, so the
hard rule stands: **this store is pubkeys-only and out-of-band. Never place a
private key here.**

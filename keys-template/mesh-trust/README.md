# Foreign-mesh trust store — Phase 7 cross-mesh base admission (pubkeys ONLY)

This directory is the **out-of-band custody root** for the public verifying keys of
**foreign meshes** whose code bases we are willing to ingest. It mirrors the
device-registry `registry-pub.ed25519` custody model exactly: **pubkeys only**,
**staged out-of-band**, **never a real key committed**, **fail-closed when absent**.

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

`<mesh-id>` is a strict DNS label (the gate rejects anything else, so the path can
never traverse) and matches the mesh id in `templates/mesh-trust/registry.json` and
in the foreign base's signed `.hugmesh-provenance.json` `base.meshId`.

## How it is used (the no-TOFU rule)

`scripts/ingest-foreign-base.sh` resolves `<mesh-id>/foreign-provenance-pub.ed25519`
from this store, reconstructs the PEM (`base64 -d | openssl pkey -pubin -inform DER`),
**validates it is an Ed25519 PUBLIC key** (openssl `-pubin` rejects a private key —
so a mistaken/hostile private key can never be used), then verifies the foreign
base's detached signature against **THIS staged key** — **never** against any
`publicKey` the base envelope advertises.

- **No trust-on-first-use.** A foreign mesh with **no entry here** has no pinned key,
  so the gate **fails closed** — an unknown mesh is never admitted.
- **Admitting a new foreign mesh is a deliberate act:** add its `registry.json`
  entry (pinned digest + minGeneration) **and** stage its public half here
  out-of-band. Two independent additions, both intentional.
- **Rotation:** when a foreign mesh rotates its provenance signing key, the new
  public half must be re-staged here **before** it signs a base you intend to pull.
  A stale key fails closed (that mesh's bases are rejected until re-keyed).

## NEVER commit a real key

Real key files are **git-ignored** (see the `keys-template/mesh-trust/**` rule in
`.gitignore`). Only the `README.md` and the `*.example` placeholder are committed.
`scripts/secret-scan.sh` would catch a private key, but the hard rule stands:
**this store is pubkeys-only and out-of-band — never place a private key here.**

# Device-license registry — Layer-B node identity + verifying key (key-USB custody)

This directory carries the per-node material the Layer-B device-license-registry
sshd enforcement needs on an **ADMIN-owned / mesh-extension** node. It is populated
by `scripts/gen-provision-keys.sh --role mesh-extension` (the only role that emits
it) and consumed at
first boot by `provision_device_registry()` (in `specs/etc/keys-provision/provision.sh`).

**SUPERADMIN / primary / core roles emit and use NONE of this** — those nodes keep
the `#66` owner-key `authorized_keys` and rely on Layer-A headscale for
reachability. A core node is NOT a registry-enforced node by design (its export
entry does not exist, so an `AuthorizedKeysCommand` there would lock the owner
out).

## Files (ADMIN / mesh-extension only)

- **`registry-pub.ed25519`** — the BAKED public verifying half of the BFF
  registry-export signing key (base64 of the X.509 SubjectPublicKeyInfo DER, i.e.
  exactly `RegistrySigner.publicKeyBase64()` / `app.registry.public-key` on the
  admin-bff-api). The node verifies every fetched/cached signed export against THIS
  baked key — **never** against the `publicKey` field advertised inside the export
  envelope. Distributed OUT-OF-BAND onto the key-USB.

  **NEVER commit a real key here.** `keys-template/device-registry/` ships only
  this README. `gen-provision-keys.sh` writes a placeholder `registry-pub.ed25519`
  unless you pass `--registry-pub FILE` or set `REGISTRY_PUB`. The operator drops
  the brand's actual public half (from the superadmin who holds the private signing
  key) onto the physical key-USB. Once enforcement is on, a stale/missing baked key
  fails CLOSED (the node denies all SSH except console break-glass) — see the
  signing-key-rotation runbook below. Enforcement switches on at the first verified
  sync; until then the `#66` baked admin key still works.

- **`machine_key_fp`** — this node's stable headscale machine-key fingerprint (the
  node's self-identity; the export's `fp` field equals `device.machineKeyFp`). If
  the fingerprint is only minted at `tailscale up`, leave this empty and
  `provision_device_registry()` populates it POST-join (write-once), reading the
  local headscale/tailscale state. **It must be the SAME string the admin-bff-api
  stored in `device_registry.machine_key_fp`** — an fp-format mismatch fails closed
  (every operator denied). This alignment is the highest-risk integration point.

- **`mesh_id`** — this node's mesh id (matches `body.meshId` in the export and the
  `?mesh=` query). `provision_device_registry()` reads `provision.json`
  `.device_registry.mesh_id` first, then `.mesh.id`, and only then this file.

## Signing-key rotation runbook (operational dependency, out of Layer-B code scope)

When the superadmin rotates the BFF registry signing key, the public half here
MUST be re-baked onto every registry-enforced node's key-USB (or pushed via a
trusted channel) BEFORE the BFF starts signing with the new key. A node with a
stale `registry-pub.ed25519` rejects the new signed export (fail-closed) and is
reachable only via the console break-glass until re-keyed. Plan rotations as: bake
new pub half to all key-USBs → re-provision/refresh nodes → flip the BFF signing
key.

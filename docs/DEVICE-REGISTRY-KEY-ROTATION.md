# Device-Registry Signing-Key Rotation Runbook

Rotating the Ed25519 **signing key** that the admin-bff-api uses to sign the
device-license export. This is a superadmin operation. Read the whole runbook
before you start — the ORDER is load-bearing.

> One-line rule: **re-bake the new PUBLIC half onto every node's key-USB BEFORE
> the BFF signs with the new PRIVATE half.** A node that still bakes the old
> public half fails CLOSED against a new-key signature (SSH lockout to
> break-glass). Public-first, private-second, always.

---

## 1. What the key is and why rotation is dangerous

The device-license registry is enforced by two fail-closed layers, both driven
from ONE signed, unscoped per-mesh export (see the
`hugmesh-device-license-registry` memory and `tests/device-registry/`):

- **Layer B** — per-node sshd. `specs/usr/sbin/hugmesh-authorized-keys-lookup`
  is the SOLE key source (`AuthorizedKeysFile none`). It verifies the export's
  detached Ed25519 signature against the **baked public half** at
  `/etc/hugmesh/registry/registry-pub.ed25519` before authorising any key.
- **Layer A** — `specs/usr/sbin/gen-headscale-policy.sh` verifies the same
  signature on the control node before rendering the headscale SSH ACL.

Both verify against the **baked** public key (`registry-pub.ed25519`), **never**
the `publicKey` field advertised in the export envelope. That is the whole point:
an attacker who can serve an export cannot also swap the key it is checked
against. The baked key is the trust anchor.

`registry-pub.ed25519` is the **base64 of the X.509 SubjectPublicKeyInfo DER** of
the signing public half (exactly `RegistrySigner.publicKeyBase64()` /
`Base64(publicKey.getEncoded())`). It is a PUBLIC key — never a private key, never
a secret. It is world-readable on the node (`AuthorizedKeysCommandUser nobody`
reads it).

### Why rotation can brick the fleet

`verify_sig()` in `specs/usr/lib/hugmesh/registry-verify.sh` is **fail-closed**:
if the signature does not verify against the baked public key, it returns
non-zero, the lookup prints nothing, and sshd denies. So:

- If the BFF starts signing with `K_new` while a node still bakes `pub(K_old)`,
  **every** export that node fetches fails verification. The sync agent keeps the
  last-good cache (it never wipes), so the node enforces the **last** good license
  set for a while — but it can no longer pick up any change, and once that node's
  operators rotate their own SSH keys or a license changes, they are locked out.
  A node that had no cache yet (fresh provision) denies ALL SSH except break-glass.
- This is the **fleet-lockout / stranded-node** failure. It is exercised by
  `tests/device-registry/test-registry-allow-deny.sh` Case 10
  ("FOREIGN/ROTATED signing key whose public half was NOT re-baked REJECT").

There is no fail-open path by design. The mitigation is **ordering**, not a
softer check.

---

## 2. Pre-flight

- [ ] You are superadmin and on the tailnet-only superadmin console / control plane.
- [ ] You can physically (or via the provisioning pipeline) reach **every** node's
      key-USB, OR you accept that any node you cannot reach will be stranded and
      must be recovered via break-glass (section 6).
- [ ] You have an inventory of every node and which mesh it is in. The export is
      per-mesh; the signing key is fleet-wide (one BFF signer).
- [ ] You have generated the new keypair OFF the fleet and have:
      `pub(K_new)` as base64 SPKI DER (the `registry-pub.ed25519` format).
- [ ] Break-glass is understood and a console path exists (section 6). Do NOT
      disable break-glass during a rotation.
- [ ] You have recorded the current export **generation** per mesh (it must keep
      moving strictly forward — section 5).

### Generate the new keypair (off-fleet, e.g. on the superadmin console)

```sh
# New Ed25519 signing keypair. Keep the PRIVATE half OFF every node; it goes only
# into the BFF signer's secret store (never onto a key-USB, never world-readable).
openssl genpkey -algorithm ed25519 -out registry-signing-NEW.pem

# The PUBLIC half in the exact baked node format (base64 X.509 SPKI DER):
openssl pkey -in registry-signing-NEW.pem -pubout -outform DER \
  | base64 -w0 > registry-pub-NEW.ed25519
```

`registry-pub-NEW.ed25519` is what you bake onto every key-USB. The
`.pem` private half goes ONLY to the BFF.

---

## 3. The ordered rotation (public-first)

> Do these IN ORDER. Do not skip ahead to step 4 until step 3 is confirmed on
> **every** reachable node.

1. **Stage** `registry-pub-NEW.ed25519` for distribution. If you use the
   `--registry-pub FILE` / `REGISTRY_PUB` path in `scripts/gen-provision-keys.sh`,
   point it at the new file; the script normalises a PEM or raw base64 SPKI DER to
   the one-line baked format.

2. **Re-bake the PUBLIC half onto EVERY node's key-USB.** Replace
   `/etc/hugmesh/registry/registry-pub.ed25519` on each node with
   `registry-pub-NEW.ed25519`. This is a PUBLIC file; it carries no secret.
   - This step does **not** break anything yet: the BFF is still signing with
     `K_old`, and a node that has the NEW public key but receives an OLD-key
     signature will fail verification and **keep its last-good cache** (no new
     authorisations, but no lockout for already-pinned operators). That is why
     public-first is safe — the window between step 2 and step 4 is a
     "verification gap that fails to last-good", never a hard brick.

   > To make the window ZERO, support **dual-trust** during rotation if/when the
   > node verify path is extended to accept ANY of several baked public keys
   > (e.g. `registry-pub.d/*.ed25519`): bake `pub(K_new)` ALONGSIDE `pub(K_old)`,
   > so a node accepts both old and new signatures across the cutover, then drop
   > `pub(K_old)` after step 4. As shipped, the verify path takes a single
   > `registry-pub.ed25519`, so treat step 2->4 as the ordered single-key swap and
   > keep the window short. (Dual-trust is the recommended hardening; see the
   > follow-up note at the end.)

3. **Confirm the new public key landed on every reachable node.** Compare the
   on-node file to the new key:

   ```sh
   # On each node (or via your config tool). The fingerprint must match the NEW key.
   base64 -d /etc/hugmesh/registry/registry-pub.ed25519 \
     | openssl pkey -pubin -inform DER -outform DER 2>/dev/null \
     | openssl dgst -sha256
   ```

   Build the list of nodes that did NOT update. Each one will be **stranded** when
   you cut the signer over in step 4 — decide now whether to chase them down first
   or recover them via break-glass (section 6) afterward. Do NOT proceed to step 4
   leaving stranded nodes you cannot tolerate.

4. **Cut the BFF signer over to `K_new`.** Only after step 3 is confirmed: load
   `registry-signing-NEW.pem` (the PRIVATE half) into the admin-bff signer secret,
   restart/reload the signer, and make the BFF re-sign each mesh's export with the
   **next** generation (strictly greater than the current last-good — section 5).
   From this moment the BFF emits `K_new`-signed exports only.

5. **Force a re-sign + re-export per mesh** so every node fetches a fresh
   `K_new`-signed export. The sync agent runs on a 60s cron and at boot; a license
   edit or an explicit re-export bumps the generation and triggers push-with-ack.
   Confirm propagation (the superadmin UI shows pending/applied/failed per node,
   mirroring 009 propagation state).

6. **Verify acceptance on a canary node** before declaring done:
   - the sync log shows `accepted export gen=<new> mesh=<id>` (it verified against
     the freshly-baked `pub(K_new)`);
   - a licensed operator can SSH in;
   - a revoked/unlicensed operator is denied.
   Re-run the matrix harness off-node as a sanity check that the predicate is
   intact: `bash tests/device-registry/test-registry-allow-deny.sh`.

7. **Decommission `K_old`.** Once every node verifies `K_new` exports, remove the
   old private half from the BFF secret store and (if you used dual-trust) drop
   `pub(K_old)` from the key-USBs. Keep an offline copy of `pub(K_old)` only as
   long as you might need to read archived export signatures for audit.

---

## 4. The wrong order (do NOT do this)

Cutting the BFF signer to `K_new` (step 4) **before** re-baking the public half
(step 2) signs every export with a key NO node trusts. Every node fails
verification, keeps its last-good cache, and the moment any license/key changes
the affected operators are locked out — across the whole fleet at once. This is
the fleet-lockout. The runbook order exists specifically to make the failure mode
"verification gap that falls back to last-good" instead of "hard brick".

---

## 5. Monotonic-generation interaction

The export generation is a **strict-monotonic** counter, enforced independently of
the key:

- the SYNC agent (`hugmesh-device-registry-sync` via
  `check_monotonic` in `registry-verify.sh`) accepts a fetched export ONLY if
  `gen > last-good`;
- the LOOKUP rejects a CACHED export whose `gen < last-good` (rollback of the
  on-disk cache).

Rotation does **not** reset the generation. The new `K_new`-signed export MUST
carry a generation **strictly greater** than each mesh's current last-good. If a
rotation script naively re-emitted the same generation with a new signature, every
node would reject it as a non-forward step even after the public key is re-baked.
So:

- keep the generation counter monotonic across the key change — **never** rewind
  it, never re-use a number;
- the first `K_new` export per mesh = `last-good + 1` (or higher). Record the
  pre-rotation last-good per mesh in pre-flight so you can confirm the new export
  is genuinely forward.

A rolled-back generation is rejected REGARDLESS of which key signed it — see
matrix Case 9 (rollback) and the strict-`>` sync guard. Key rotation and rollback
protection are orthogonal and both fail-closed.

---

## 6. Break-glass recovery for a stranded node

A node is **stranded** if it bakes a public key that does not match what the BFF
now signs with (you cut over in step 4 before re-baking it, or it was unreachable
in step 2/3). Symptom: the sync log shows
`fetched export FAILED verification ... keeping cache`, no new authorisations land,
and once the last-good set no longer admits the operator they cannot SSH in
normally.

Recovery:

1. **Get on the node via break-glass.** Break-glass is a single physical key
   behind a console/loopback-only Match (`Match LocalAddress 127.0.0.1,::1`,
   default-OFF — the key file is absent until you place it). It bypasses the
   registry by design (audited, off by default). Use physical console access or
   the documented break-glass procedure to enable and use it; it does NOT depend
   on the registry signature, so a stranded node is still reachable this way.

2. **Re-bake the correct public half.** Replace
   `/etc/hugmesh/registry/registry-pub.ed25519` with the CURRENT
   `registry-pub-NEW.ed25519` (the key the BFF is now signing with). Confirm with
   the fingerprint check in step 3.

3. **Force a sync.** Run `hugmesh-device-registry-sync` (or wait for the 60s
   cron). It should now `accepted export gen=<new>` and converge. The two-phase
   bootstrap gate already flipped on this node, so enforcement resumes immediately.

4. **Disable break-glass again** (remove the break-glass key file / re-disable the
   Match) and record the event in the audit log.

If a node is stranded with NO valid cache at all (e.g. freshly provisioned with the
wrong public key), it denies all SSH except break-glass from the start — same
recovery: break-glass in, re-bake, sync.

> Prevention beats recovery: confirm step 3 ("new public key on every reachable
> node") before step 4. The only nodes that should ever need break-glass recovery
> are ones you knew were unreachable during the rotation.

---

## 7. Quick checklist

- [ ] New keypair generated off-fleet; private half ONLY to the BFF, public half
      in base64 SPKI DER form.
- [ ] **Public half re-baked onto EVERY reachable node's key-USB (step 2).**
- [ ] Fingerprint-verified on every node; stranded list recorded (step 3).
- [ ] **Only then** BFF signer cut over to the new private key (step 4).
- [ ] Per-mesh re-export at a strictly-forward generation; propagation confirmed
      (step 5).
- [ ] Canary node accepts new-key exports; licensed in, revoked out (step 6).
- [ ] Stranded nodes recovered via break-glass, then break-glass re-disabled
      (section 6).
- [ ] Old private key decommissioned; old public key kept only for audit (step 7).

## Hardening follow-up (recommended)

Extend the node verify path to trust **multiple** baked public keys during a
rotation window (e.g. a `registry-pub.d/` directory; accept a signature that
verifies against ANY baked key). That turns the step-2->step-4 window from
"verification gap (fail to last-good)" into a **zero-downtime overlap**: bake
`pub(K_new)` alongside `pub(K_old)`, cut the signer over, then drop `pub(K_old)`.
Until that lands, the single-key ordered swap in section 3 is the procedure, and
break-glass (section 6) is the safety net.

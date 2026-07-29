# Node Storage

Attach **additional storage** to a specific mesh node and let services use that space on
that node. Storage is **node-pinned**: a service placed on a pool runs on the node the disk
is attached to, and its volume binds there.

This is an **OPTIONAL, opt-in, add-by-command** feature. It ships **INERT**: with no pool
registered anywhere, the platform behaves exactly as before (the local-path provisioner keeps
its `DEFAULT_PATH` on the x86 host; the placement ApplicationSet has zero elements; the
control-plane tables are empty).

---

## What it is for

A node has spare disk capacity (an attached SSD/HDD, an extra NVMe) and you want a service —
Owncast media, LocalTube downloads, a cache, a forum's uploads — to use it **on that node**,
without re-architecting cluster-wide storage. You attach + register the disk as a *pool*, then
*assign* a service to it; the mesh schedules the service onto the pool's node and binds a
node-local PersistentVolume there.

---

## The model

| Concept | Where it lives | What it is |
|---|---|---|
| **pool** | `node_storage_pool` (admin-bff changelog 085) | an additional disk attached + registered to ONE node, with a capacity claim (`reserved_bytes`) and a node-local path (`pool_path`). |
| **assignment** | `storage_service_assignment` (085) | an explicit (pool × service) placement: which service is pinned to the pool's node + the PVC bound to the node-pinned PV. |
| **the export** | `GET /bff/admin/device-storage-pools/export?node=<fp>` | the signed, per-node truth the node-agent reconciles; carries ONLY that node's pools + assignments. |
| **provisioning** | `provision_storage` (keys-provision) | a pool is just a `.storage.devices[]` element with a `pool:{}` marker; FDE is reused verbatim. |
| **placement** | `apps/13b-node-storage.yaml` ApplicationSet | each ACTIVE assignment → one Application that injects `nodeAffinity` + a PVC. |

---

## Who can do it (the ownership ALLOW/DENY matrix)

Storage is **ADMIN-CAPABLE** (unlike SSH licensing, which is superadmin-only) but
**OWNERSHIP-gated** — the deliberate divergence:

| caller | node owner | node domain | result |
|---|---|---|---|
| SUPERADMIN | any | any | **ALLOW** (unrestricted) |
| ADMIN | ADMIN-owned | own residency | **ALLOW** |
| ADMIN | SUPERADMIN-owned | any | **DENY (403)** — superadmin-only |
| ADMIN | ADMIN-owned | another domain | **DENY (403)** — cross-domain |

Enforced in `NodeStorageService.denyReason` (admin-bff). The pool/assignment `domain` is
stamped from the **node's residency**, never the caller (`[FIX-NODEFAULT]`).

---

## Capacity

- Capacity is **WaitForFirstConsumer** (the `hugmesh-local` StorageClass) + an API guard:
  an assign is rejected (422) when `committed + requested > pool.reserved_bytes`, or when an
  `is_exclusive` pool already has an active assignment.
- The node-agent's `df` on the attached disk is **authoritative** over the operator's
  `reserved_bytes` claim (verified at reconcile).
- `is_exclusive` defaults true for video (one service per pool).

---

## End-to-end flow

1. **Attach** (admin UI → `POST .../{deviceId}/pools`): register the disk as a pool on a node
   you own. The control plane stamps the pool's residency from the node.
2. **Assign** (admin UI → `POST .../pools/{poolId}/assignments`): place a service on the pool
   (capacity-checked).
3. **Provision** (node-agent, on the node): the `hugmesh-node-storage-reconcile` agent
   (boot oneshot + 60s cron) fetches the **signed per-node export**, verifies it (detached
   Ed25519 over the canonical bytes against the baked key + strict-monotonic rollback guard —
   the SAME verifier as the device-license registry), then:
   - resolves the disk by serial via `lsblk`,
   - writes a `.storage.devices[]` `pool:{}` manifest and runs `provision_storage --pool`
     (LUKS2 FDE reused; the pool's crypttab/fstab get `,nofail`),
   - labels the node `hugmesh.systems/local-path=true`,
   - CAS-patches the local-path `nodePathMap` so THIS node serves PVs from the pool path.
4. **Place** (ArgoCD): the `13b-node-storage` ApplicationSet renders one Application per active
   assignment; it injects `nodeAffinity` (pin the pod to the pool's node) + a node-pinned PVC.
   `WaitForFirstConsumer` + the per-node `nodePathMap` entry + the `nodeAffinity` together
   guarantee the **PV binds on the correct node**.
5. **Revoke / detach** (admin UI): a CAS revoke drops the assignment from the active set → the
   ApplicationSet prunes the placement. A pool can be detached only once it has no active
   assignment.

---

## Local-path provisioner: DaemonSet on a label

The Rancher local-path-provisioner is a **DaemonSet** gated on
`nodeSelector: hugmesh.systems/local-path=true` (not a single Deployment). The control-plane
(x86 host) always carries that label, so the provisioner runs there exactly as before
(**full back-compat** — `DEFAULT_PATH` retained); a node-storage node gets the label when its
first pool is provisioned, so a provisioner instance + a per-node `nodePathMap` entry come up
there. local-path is a per-node provisioner keyed on the PV's selected node, so one instance
per local-path node is correct.

---

## Residuals & cautions (READ THIS)

- **Node-pinned PV = NO HA.** The data lives on ONE node's disk. If that disk/node is lost,
  the data is lost. **Scope node-pinned storage to REPLACEABLE data** (caches, media,
  downloads) — NOT a primary database. The admin UI **warns** when you assign a database-shaped
  service name to a pool.
- **Disk removal degrades, never bricks.** The pool's crypttab/fstab carry `,nofail`, so a
  removed disk degrades the pool (its PVs go unavailable) but the node still boots. The
  node-agent detects the mount-loss and acks `degraded` (the UI chip turns red). A
  `PodDisruptionBudget` (opt-in per placement) blocks a voluntary node drain from silently
  taking a placed service down.
- **Rebalancing a running stateful service = EXPLICIT downtime + manual.** The mesh only
  *recommends* a move; the operator confirms and runs the migration: **scale to 0 → rsync the
  old PV → re-point the assignment (revoke old + assign new) → scale back up**. NEVER silent
  auto-migration. See the `node-storage-migrate.yaml` Job stub (ships suspended/inert).
- **FDE key custody (MVP)** = a shared LUKS key + TPM2 enrolment (reused from
  `provision_storage` / `luks_open_or_format`). See `docs/ENCRYPTION-AT-REST.md`.
- **Single-issuer clusters** need `app.registry.allow-single-issuer=true` for device
  registration (inherited from the device-license registry guard, which already rejects a
  `default` residency so the per-domain wall is non-vacuous).

---

## Verification status (VERIFIED vs NEEDS-NODE)

- **VERIFIED off-node:** the admin-bff ownership matrix / capacity / export tests; the shell
  logic tests (`tests/node-storage/`): `provision_storage --pool`/`,nofail`, the node-agent
  verify (genuine accept; unsigned/tampered/foreign/rollback reject) + the `nodePathMap`
  CAS-patch (PV-binds-to-correct-node) + the pool-manifest build, and the 13b ApplicationSet
  structure/selector lever. The storage canonical-bytes reconstruction round-trips against the
  Java `NodeStorageExportService.canonicalBytes` shape.
- **NEEDS A BOOTED NODE:** end-to-end byte-equality with a live BFF `/export` payload; the real
  `provision_storage --pool` against a physical disk; the live PV bind + pod scheduling on the
  pool's node; the precise degraded/migration behaviour.

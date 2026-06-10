# Encryption at rest — every storage layer the cloud touches

Goal: **any storage used by the cloud is encrypted at rest, on any Pi5 or x86
node.** This documents the mechanism, key custody, and unlock flow for every
storage location this repo controls, plus the layers that cannot be encrypted
today (with the reason + mitigation).

Key custody is uniform and **never in git**: the offline **USB-KEYS** stick (the
same stick that carries the cluster CA and Vault seal material) and/or the node
**TPM2**. All key material is gitignored (`secrets/luks.key`,
`kubernetes/encryption-key`, `*.pem`, …).

## Storage map

| # | Storage location | What lives there | Mechanism | Key custody | Unlock flow | Status |
|---|------------------|------------------|-----------|-------------|-------------|--------|
| 1 | **Node data partition** (`/mnt/data`, attached NVMe/USB) | Cluster **PVCs**, relocated `containerd`/`kubelet` state, backups, **Vault** persistent storage (prod), and — by directory — **etcd** if relocated there | **LUKS2** `aes-xts-plain64`, 512-bit key, `sha512`/**argon2id** PBKDF (`cryptsetup luksFormat` in `keys-provision` → `provision_storage`) | USB-KEYS `secrets/luks.key` (recovery slot) + **TPM2** on x86 / TPM nodes | Boot: `/etc/crypttab` opens by UUID; TPM2 token unlocks (`tpm2-device=auto`), keyfile fallback. First boot: `provision_storage` luksFormats + opens + enrolls TPM2 | **Implemented** |
| 2 | **Kubernetes PVCs** (StorageClass `snapdragon-local`) | Postgres, Redis, Cassandra, ClickHouse, GitLab, etcd-backup PVs | **Inherited** from layer 1 — local-path just makes dirs under the LUKS `/mnt/data` | (inherits layer 1) | (inherits layer 1) | **Implemented** (by inheritance; annotated on the StorageClass) |
| 3 | **etcd Secrets** (kube-apiserver) | Every Kubernetes `Secret` object | **EncryptionConfiguration** `aescbc` (AES-256-CBC) provider; apiserver encrypts before writing to etcd | USB-KEYS `kubernetes/encryption-key` (shared across CPs) or minted on first CP | apiserver reads `/etc/kubernetes/encryption-config.yaml` (kubeadm `apiServer.extraArgs`/`extraVolumes`); `keys-provision` writes it before `kubeadm init`/`join` | **Implemented** |
| 4 | **etcd data dir at rest** (`/var/lib/etcd`) | The whole etcd KV (incl. non-Secret objects) | **Inherited** from layer 1 **when etcd is relocated onto `/mnt/data`** (`storage.devices[].use_for`); otherwise on the root partition (layer 6) | (inherits layer 1) | (inherits layer 1) | **Implemented when relocated** (else see layer 6) |
| 5 | **Vault storage** | Vault's own secret store | DEV: in-memory (nothing at rest). PROD: persistent storage on `/mnt/data` → **inherits layer 1 LUKS**; Vault seal/unseal keys stay on USB-KEYS, never git | USB-KEYS (seal keys) + layer 1 (storage) | Vault unseal at start; storage decrypts via layer 1 | **Implemented for the prod storage path** (DEV Vault is ephemeral by design) |
| 6 | **Node root partition** (`/`) | OS, `/etc/kubernetes`, kubelet certs, default `/var/lib/etcd` if not relocated | **Not yet LUKS** — see "Documented followup" | n/a | n/a | **Documented followup** |
| 7 | **Build artifacts** (`out/*.img`, `*.fs.tar.xz`) | Flashable node images | Encrypt the artifact host disk / transport; images carry NO secrets (all secrets arrive at first boot from USB-KEYS) | operator's build host | n/a | **Mitigated** (images are secret-free by design) |
| 8 | **USB-KEYS stick itself** | CA key, LUKS keyfile, etcd key, Vault token | Physically offline; FAT32 (mounted `ro,nosuid,nodev,noexec`). Optionally a LUKS-encrypted KEYS stick | physical custody | n/a | **Mitigated** (offline, physically controlled) |

## Unlock flow (first boot vs. every boot)

**First boot** (`keys-provision` → `provision_storage`, idempotent):
1. Resolve the LUKS keyfile (USB-KEYS `secrets/luks.key`).
2. For each `encrypt:true` device: `cryptsetup luksFormat` (only if `format:true`
   and not already LUKS — an existing LUKS volume is just **opened**, never
   reformatted, so re-provisioning never destroys data), `cryptsetup open` →
   `/dev/mapper/<name>`, write `/etc/crypttab`, install the recovery keyfile to
   `/etc/snapdragon/luks/<name>.key` (0600).
3. Best-effort **TPM2 enrolment** (`systemd-cryptenroll --tpm2-pcrs=7`, else
   `clevis luks bind tpm2`) so the node later unlocks without the USB; harmless
   no-op where no TPM/tool exists (USB keyfile remains the slot).
4. `mkfs` + mount the **mapper** device; fstab references it by UUID.

**Every boot**: `/etc/crypttab` opens each volume by UUID — TPM2 token first
(`tpm2-device=auto`), keyfile fallback — before fstab mounts it.

## Key custody summary (NONE in git)

| Key | Where | Used for |
|-----|-------|----------|
| `secrets/luks.key` | USB-KEYS (gitignored) | LUKS data-partition unlock (recovery slot) |
| TPM2-sealed LUKS key | node TPM (PCR7) | LUKS auto-unlock on x86 / TPM nodes |
| `kubernetes/encryption-key` | USB-KEYS (gitignored), shared across CPs | etcd Secret `aescbc` encryption |
| cluster CA key, Vault seal keys, Vault token | USB-KEYS / Vault | PKI + secret backend (pre-existing model) |

## Per-node defaults

- **x86 nodes**: TPM2 auto-unlock (`systemd-cryptenroll`) + USB-KEYS keyfile
  recovery. AES-NI hardware acceleration.
- **Pi5 nodes** (no on-board TPM): USB-KEYS keyfile is the unlock slot. A Pi with
  a TPM HAT uses `clevis`-tpm2 (kernel ships `KEYS`/`TRUSTED_KEYS` + ARM64 CE AES
  so no rebuild is needed). `luks_tpm2:true` in `provision.json` gates enrolment.

## Documented followup (NOT implemented, with reason)

- **Layer 6 — full root-partition (FDE) LUKS**. The node images are *flashed
  raw `.img`s* (FAT/ext4) with `growroot` expanding the root on first boot; there
  is no initramfs unlock stage in the current boot path, so encrypting `/`
  in-place would need an initramfs (clevis/`systemd-cryptsetup`) + a
  before-pivot unlock that does not exist yet — forcing it would brick boot.
  **Mitigation today**: every layer that holds *cluster data* (PVCs, relocated
  etcd, Vault prod storage, backups) is on the LUKS `/mnt/data` (layer 1), and
  etcd Secrets are independently encrypted (layer 3). **Migration path**: add a
  LUKS-root + initramfs unlock (TPM2/USB-KEYS) stage to the image builder, then
  relocate the remaining root-resident state. **`growroot` is already
  LUKS-aware** so this migration will not have to revisit the first-boot grow:
  when `/` resolves to a `/dev/mapper/*` device it grows the *backing* partition,
  runs `cryptsetup resize`, then `resize2fs` the mapper (partition → crypt
  container → filesystem). With today's plaintext root that code path is inert.
- **etcd not relocated → on root (layer 4/6)**. Relocate etcd onto `/mnt/data`
  via `storage.devices[].use_for` (or the root-FDE followup) for full-KV at-rest
  encryption. Secret objects are already encrypted regardless (layer 3).
- **KMS provider for etcd (Vault Transit)** instead of the static `aescbc` key.
  The `EncryptionConfiguration` provider can be swapped to `kms` once a
  Vault-Transit KMS plugin endpoint exists in-cluster; kept as a documented
  upgrade so bootstrap has no chicken-and-egg dependency on Vault.
- **DEV Vault is ephemeral** (in-memory) by design; the PROD HA Vault stores on
  the LUKS `/mnt/data` and is the supported at-rest path (layer 5).

## What was NOT weakened

No existing protection was removed. LUKS, the etcd EncryptionConfiguration, and
the StorageClass annotation are additive; the offline USB-KEYS custody model is
unchanged. Postgres stays on `scram-sha-256`.

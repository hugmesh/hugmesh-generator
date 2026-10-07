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
| 2 | **Kubernetes PVCs** (StorageClass `hugmesh-local`) | Postgres, Redis, Cassandra, ClickHouse, GitLab, etcd-backup PVs | **Inherited** from layer 1 — local-path just makes dirs under the LUKS `/mnt/data` | (inherits layer 1) | (inherits layer 1) | **Implemented** (by inheritance; annotated on the StorageClass) |
| 3 | **etcd Secrets** (kube-apiserver) | Every Kubernetes `Secret` object | **EncryptionConfiguration** `aescbc` (AES-256-CBC) provider; apiserver encrypts before writing to etcd | USB-KEYS `kubernetes/encryption-key` (shared across CPs) or minted on first CP | apiserver reads `/etc/kubernetes/encryption-config.yaml` (kubeadm `apiServer.extraArgs`/`extraVolumes`); `keys-provision` writes it before `kubeadm init`/`join` | **Implemented** |
| 4 | **etcd data dir at rest** (`/var/lib/etcd`) | The whole etcd KV (incl. non-Secret objects) | **Inherited** from layer 1 **when etcd is relocated onto `/mnt/data`** (`storage.devices[].use_for`); otherwise on the root partition (layer 6) | (inherits layer 1) | (inherits layer 1) | **Implemented when relocated** (else see layer 6) |
| 5 | **Vault storage** | Vault's own secret store (KV, `pki_int`, planned Transit-KMS) | **Raft integrated storage** on a PVC from StorageClass `hugmesh-local` → the Raft data dir (`/vault/data`) lands under the LUKS `/mnt/data` on the pki node → **inherits layer 1 LUKS**. Vault serves a **TLS listener** (cluster-CA-signed, self-signed bootstrap fallback). **Shamir** seal; the unseal key + bootstrap root token stay on USB-KEYS, never git | USB-KEYS (`vault/unseal-key` + `vault/token`) + layer 1 (storage) | `vault operator init` ONCE; the `vault-unseal` sidecar runs `vault operator unseal` from the mounted key on **every restart** (unattended); Raft state decrypts via layer 1 | **Implemented** (persistent + auto-unseal; was dev `server -dev` in-memory before) |
| 6 | **Node root partition** (`/`) | OS, `/etc/kubernetes`, kubelet certs, default `/var/lib/etcd` if not relocated | **Installer ISO only:** the builders' `--encrypt-root` flag (auto-on for standalone roles; it forces the installer ISO) makes the installer lay down a LUKS2 root. `specs-x86/installer/install-x86.sh` uses `aes-xts-plain64`, 512-bit, `sha512`/`argon2id`, with an unencrypted ESP at `/boot` and `dracut --add crypt` unlocking it in the initramfs. The rpi5, frite and orangepi installers also call `cryptsetup luksFormat`; the jetson tree has no installer script (`specs-jetson/installer/` holds only `TEGRAFLASH.md`). **Quick-flash raw `.img` files: not LUKS** — see "Documented followup" | root-unlock passphrase typed at install time (never baked); optional extra keyfile or FIDO2 keyslot | passphrase prompt at the initramfs (keyfile on the ESP if one was added) | **Partial** (installer path only; plaintext on a quick-flash `.img`) |
| 7 | **Build artifacts** (`out/*.img`, `*.fs.tar.xz`) | Flashable node images | Encrypt the artifact host disk / transport; images carry NO secrets (all secrets arrive at first boot from USB-KEYS) | operator's build host | n/a | **Mitigated** (images are secret-free by design) |
| 8 | **USB-KEYS stick itself** | CA key, LUKS keyfile, etcd key, Vault token | Physically offline; FAT32 (mounted `ro,nosuid,nodev,noexec`). Optionally a LUKS-encrypted KEYS stick | physical custody | n/a | **Mitigated** (offline, physically controlled) |

## Unlock flow (first boot vs. every boot)

**First boot** (`keys-provision` → `provision_storage`, idempotent):
1. Resolve the LUKS keyfile (USB-KEYS `secrets/luks.key`).
2. For each `encrypt:true` device: `cryptsetup luksFormat` (only if `format:true`
   and not already LUKS — an existing LUKS volume is just **opened**, never
   reformatted, so re-provisioning never destroys data), `cryptsetup open` →
   `/dev/mapper/<name>`, write `/etc/crypttab`, install the recovery keyfile to
   `/etc/hugmesh/luks/<name>.key` (0600).
3. Best-effort **TPM2 enrolment** (`systemd-cryptenroll --tpm2-pcrs=7`, else
   `clevis luks bind tpm2`) so the node later unlocks without the USB; harmless
   no-op where no TPM/tool exists (USB keyfile remains the slot). The manifest
   key `storage.luks_tpm2` (default `true`) turns it off.
4. `mkfs` + mount the **mapper** device; fstab references it by UUID.

**Every boot**: `/etc/crypttab` opens each volume by UUID — TPM2 token first
(`tpm2-device=auto`), keyfile fallback — before fstab mounts it.

**Plaintext fallbacks (read before trusting layer 1).** `luks_open_or_format()`
in `provision.sh` does not stop the provision when it cannot encrypt. It logs a
warning and returns the raw partition, so the device is used **unencrypted**,
when: `cryptsetup` is not installed; there is no LUKS keyfile
(`KEYS/secrets/luks.key`); the partition is not LUKS and `format` is not `true`
(it refuses to encrypt in place); `cryptsetup luksFormat` fails; or
`cryptsetup open` fails. Look for `PLAINTEXT` in the first-boot log on every
node.

## Key custody summary (NONE in git)

| Key | Where | Used for |
|-----|-------|----------|
| `secrets/luks.key` | USB-KEYS (gitignored) | LUKS data-partition unlock (recovery slot) |
| TPM2-sealed LUKS key | node TPM (PCR7) | LUKS auto-unlock on x86 / TPM nodes |
| `kubernetes/encryption-key` | USB-KEYS (gitignored), shared across CPs | etcd Secret `aescbc` encryption |
| `vault/unseal-key` | USB-KEYS (gitignored) | Persistent Vault Shamir unseal (auto-unseal sidecar) |
| `vault/token` | USB-KEYS (gitignored) | Vault bootstrap/root token (vault-pki-init + ESO token) |
| cluster CA key | USB-KEYS / Vault `pki_int` | PKI trust anchor (pre-existing model) |

## Per-node defaults

- **x86 nodes**: TPM2 auto-unlock (`systemd-cryptenroll`) + USB-KEYS keyfile
  recovery. AES-NI hardware acceleration.
- **Pi5 nodes** (no on-board TPM): USB-KEYS keyfile is the unlock slot. A Pi with
  a TPM HAT uses `clevis`-tpm2 (kernel ships `KEYS`/`TRUSTED_KEYS` + ARM64 CE AES
  so no rebuild is needed). `storage.luks_tpm2` in `provision.json` (default
  `true`) gates enrolment.

## Documented followup (NOT implemented, with reason)

- **Layer 6 — root-partition (FDE) LUKS for quick-flash images.** The installer
  path encrypts the root (layer 6 in the table). A *flashed raw `.img`* (FAT/ext4,
  `growroot` expanding the root on first boot) is still plaintext. Encrypting
  `/` of such an image in place would need an unlock stage before pivot, and a
  disk-boot artifact without a matching `initramfs-<kver>.img` has no `rd.luks`
  unlock at all (the x86 builder fails the build in that case). **Mitigation
  today**: every layer that holds *cluster data* (PVCs, relocated etcd, Vault prod
  storage, backups) is on the LUKS `/mnt/data` (layer 1), and etcd Secrets are
  independently encrypted (layer 3). **Migration path**: ship the encrypted
  installer layout as the only disk layout for cluster nodes, then relocate the
  remaining root-resident state. **`growroot` is already LUKS-aware**: when `/`
  resolves to a `/dev/mapper/*` device it grows the *backing* partition, runs
  `cryptsetup resize`, then `resize2fs` on the mapper (partition, then crypt
  container, then filesystem). That path runs on installer-encrypted systems and
  is inert on a plaintext root.
- **etcd not relocated → on root (layer 4/6)**. Relocate etcd onto `/mnt/data`
  via `storage.devices[].use_for` (or the root-FDE followup) for full-KV at-rest
  encryption. Secret objects are already encrypted regardless (layer 3).
- **KMS provider for etcd (Vault Transit)** instead of the static `aescbc` key.
  The `EncryptionConfiguration` provider can be swapped to `kms` once a
  Vault-Transit KMS plugin endpoint exists in-cluster; kept as a documented
  upgrade so bootstrap has no chicken-and-egg dependency on Vault.
- **Vault `pki_int` one-time re-init.** The previous dev Vault (`server -dev`)
  held NO durable state, so converting to the persistent Vault starts from an
  empty store: the `pki_int` engine + per-app issuing roles must be set up once
  against the fresh Vault. The existing `manifests/vault-pki` bootstrap Job does
  exactly this and is **idempotent** — it re-imports the cluster CA from the
  mounted `cluster-ca` Secret (provisioned offline from the USB stick) so issued
  leaf certs still chain to `certs/cluster-ca` and the existing truststores.
  ArgoCD re-runs it (PostSync hook) after Vault is initialized + unsealed; no
  manifest change is needed. See `keys-template/vault/README.md` for the one-time
  `vault operator init` (mint + persist the unseal key/root token to USB-KEYS).
- **Multi-replica Raft HA (Vault).** The persistent Vault runs a **single-node**
  Raft cluster today. On this single-control-plane topology the pki Pi is the
  availability floor, so multi-replica HA has limited value: persistent +
  auto-unseal (survives restart) is the real fix shipped now. Scaling Raft to 3
  replicas (with `retry_join`, an anti-affinity spread, and auto-unseal via a
  Transit/KMS seal so peers unseal without the operator) is a **documented
  follow-up** for when additional control-plane nodes exist.

## What was NOT weakened

No existing protection was removed. LUKS, the etcd EncryptionConfiguration, and
the StorageClass annotation are additive; the offline USB-KEYS custody model is
unchanged. Postgres stays on `scram-sha-256`.

# snapdragon-generator

Crossdev / native build scripts that produce **hardened Gentoo images** for the
Snapdragon cluster — three Raspberry Pi 5 (aarch64) role images plus an x86_64
GPU host — and the **GitOps payload** that runs Casdoor, tuwunel (Matrix) + Akkoma (fediverse), the
Spring APIs and snapdragon.games on them. Everything connects **behind
`snapdragon.systems`** through per-namespace Spring Cloud Gateways.

Every image boots, then provisions itself at first boot from a USB **FAT32
`KEYS` partition** (users, SSH keys, passwords, certificates, headscale/k8s
config, attached storage, backups) — see [`keys-template/`](keys-template/).

> **Read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full topology.**

All build output lands in a **git-ignored** work directory
(`rpi5-stage4-build/`, `x86-host-build/`).

## Images

| Image | Build command | Runs |
|---|---|---|
| **pki** (RPi 5) | `./build-rpi5-stage4.sh --role pki` | k8s control plane, headscale, Casdoor, Cassandra, pki-gateway |
| **backend** (RPi 5) | `./build-rpi5-stage4.sh --role backend` | tuwunel (Matrix) + Akkoma (fediverse), Spring APIs, DBs, be-gateway |
| **frontend** (RPi 5) | `./build-rpi5-stage4.sh --role frontend` | snapdragon.systems Angular host + social-ui, fe-gateway |
| **host** (x86_64) | `sudo ./build-x86-host-stage4.sh` | GPU worker: ArgoCD, snapdragon.games, backend capacity |

## Rebranding (brand profile)

Everything is **string-independent**: the default naming is `snapdragon` /
`snapdragon.systems`, but you can build ISOs for any brand/domain. Drop a
`brand.conf` (auto-detected in the CWD, or pass `--config FILE`) — a plain shell
file the builders source. Precedence is **built-in defaults < brand.conf < CLI
flags**, so an absent file changes nothing.

```bash
cp brand.conf.example brand.conf      # edit BRAND / BRAND_TITLE / ORG / CLUSTER_DOMAIN / default accounts
./build-rpi5-stage4.sh --role pki     # picks up brand.conf automatically
# or per-invocation, no file:
./build-rpi5-stage4.sh --role backend --brand acme --domain acme.example --org Acme-Inc --brand-title "Acme Corp"
```

At build time the baked cluster payload is rewritten — every namespace
(`acme-pki`/`acme-backend`/…), gateway name, ingress host (`matrix.acme.example`),
image org (`acme-inc/…`), title and hostname — from the snapdragon defaults to
your brand. (Internal install paths like `/var/lib/snapdragon` and the
provisioning JSON key are kept as the tool's vendor namespace.) `brand.conf` is
git-ignored since it can hold default passwords.

## Prerequisites (build host)

- **RPi 5 images** (cross-compiled, run with **sudo** — cross-emerge merges into
  the sysroot + writes host caches; fakeroot is not enough): `crossdev` with
  `aarch64-unknown-linux-gnu` built, plus `curl`, `tar`, `file`, `xorrisofs`
  (`dev-libs/libisoburn`). `crossdev --stable --target aarch64-unknown-linux-gnu`.
- **x86_64 host image** (native, **root** required): an amd64 Gentoo host with
  `grub`, `squashfs-tools`, `libisoburn` (for `grub-mkrescue`/`xorriso`).
- **QEMU test**: `app-emulation/qemu` (aarch64 target), `dosfstools`, `e2fsprogs`.

## Quick start — build locally on Gentoo (copy-paste)

Run the builds as **root** (the cross-emerge merges into the sysroot's package DB
and writes host caches; fakeroot is not enough). Artifacts land in the git-ignored
`./rpi5-stage4-build/` and `./x86-host-build/`.

```bash
# 0. Build-host prerequisites (one-time). RPi5 cross-toolchain + ISO tooling:
sudo emerge -an dev-libs/libisoburn app-arch/tar sys-apps/file net-misc/curl
sudo crossdev --stable --target aarch64-unknown-linux-gnu
#    x86_64 host image also needs:  sys-boot/grub sys-fs/squashfs-tools
#    QEMU integration test also needs:  app-emulation/qemu sys-fs/dosfstools sys-fs/e2fsprogs

# 1. Build the images (one bootable ISO per role)
sudo ./scripts/build-all-roles.sh -j "$(nproc)"          # all three Pi roles: pki, backend, frontend
sudo ./build-rpi5-stage4.sh --role pki -j "$(nproc)"     # …or just one Pi role
sudo ./build-x86-host-stage4.sh -j "$(nproc)"            # x86_64 GPU host (native amd64 Gentoo)

# 2. Cluster secrets + a per-node KEYS provisioning stick (users, SSH, certs, k8s join, GitOps)
./scripts/gen-cluster-secrets.sh                         # cluster-wide secrets (Vault + USB fallback) — once
./scripts/gen-provision-keys.sh -r pki -o keys-pki       # also: -r backend | -r frontend | -r host
sudo ./scripts/make-keys-usb.sh /dev/sdY keys-pki        # FAT32 stick labelled KEYS (one per node)

# 3. Flash the OS to each node's SD/NVMe (boot a Linux live env, mount the role's ISO)
sudo mount -o loop rpi5-stage4-build/gentoo-rpi5-arm64-pki-k8s-*.iso /mnt/iso
sudo /mnt/iso/install.sh /dev/sdX                        # SD card, or /dev/nvme0n1
sudo umount /mnt/iso
#    x86 host: boot the gentoo-x86-*.iso live image, then run  install-x86.sh /dev/sdX  from it.

# 4. Boot each node with its KEYS stick inserted — first boot self-provisions.

# 5. (optional) Integration-test an image under QEMU before flashing (root)
sudo ./tests/qemu/run-qemu-test.sh --role pki
```

## Generate the cluster

Boot the **pki** node first — it is the Kubernetes control plane. If its KEYS
manifest sets `snapdragon.gitops.enabled=true`, `keys-provision` runs `kubeadm init`
and the GitOps bootstrap automatically; otherwise run the bootstrap by hand on the
pki node:

```bash
# On the pki node, after kubeadm init:
export KUBECONFIG=/etc/kubernetes/admin.conf
sudo -E /var/lib/snapdragon/cluster/bootstrap/bootstrap.sh   # installs ArgoCD + the root app-of-apps

# Backend / frontend / x86-host nodes join automatically at first boot (the kubeadm
# join token rides on their KEYS stick) — or run  kubeadm join <pki>:6443 …  manually.

# Watch ArgoCD converge the platform (Calico, Vault+ESO, Casdoor, Cassandra, the three
# gateways behind ingress-nginx, Akkoma, tuwunel, Forgejo, the Spring APIs, the
# frontends, snapdragon.games):
kubectl -n devops get applications
kubectl get pods -A
# ArgoCD admin password:
kubectl -n devops get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

## USB KEYS provisioning

At first boot the `keys-provision` service finds the FAT32 `KEYS` partition,
mounts it read-only, and applies (all optional):

- **users** from `users.json` (groups, sudo, SSH keys, SHA-512 password hashes)
- **SSH** host keys + per-user `authorized_keys` (login is key-only)
- **hostname / timezone / Wi-Fi / NetworkManager** profiles
- **certificates** and arbitrary **files** at given paths
- **headscale** (control server) + **tailscale** (client, preauth-key join)
- **Kubernetes** PKI + kubeadm config; stage or run `kubeadm init`/`join`
- **attached storage** — mount M.2/NVMe or USB, relocate containerd/kubelet data
- **backups** — schedule etcd + PostgreSQL dumps to attached storage and/or
  an NFS/CIFS share
- **GitOps** — on the pki control plane, bootstrap ArgoCD + the app-of-apps

If no KEYS stick is present the image still boots and creates a fallback user so
you are never locked out. Full schema + examples: [`keys-template/`](keys-template/).

## Cluster / GitOps

The cluster manifests live in [`specs/cluster/`](specs/cluster/) and are baked
into every image at `/var/lib/snapdragon/cluster`. The pki node installs ArgoCD
and a root app-of-apps; ArgoCD syncs the `snapdragon-gateway` Helm chart (one
release per namespace, fronted by an **ingress-nginx** facade on the backend node),
Casdoor, Cassandra, **Akkoma** (fediverse) + **tuwunel** (Matrix), **Forgejo**
(in-cluster git on pki), the Spring APIs, the Angular frontend, the social-ui and
snapdragon.games. See [`specs/cluster/README.md`](specs/cluster/README.md).

## Secrets (Vault + USB)

Cluster secrets are generated by
[`scripts/gen-cluster-secrets.sh`](scripts/gen-cluster-secrets.sh) and pushed to
**HashiCorp Vault** (KV v2, mount `secret/`, base path `snapdragon/`, tracking
the brand slug). The **External Secrets Operator** syncs them into k8s via the
ClusterSecretStore **`snapdragon-vault`** (one ExternalSecret per Secret,
refreshed hourly) — the workloads keep their existing `secretKeyRef`s
(`casdoor-google`, `clickhouse-auth`, `uptrace-auth`). The same values are also
written to the KEYS stick at `vault/secrets.json` (with `vault/token` for online
sync) so `keys-provision` can create the Secrets offline — **Vault first, USB
fallback** — if Vault is unreachable. See [`specs/cluster/`](specs/cluster/).

## QEMU integration test

[`tests/qemu/run-qemu-test.sh`](tests/qemu/) boots a built image under
`qemu-system-aarch64 -M virt` with a synthetic FAT32 KEYS disk and asserts that
provisioning worked end-to-end (users, sshd, headscale, the k8s stack, the role
marker). See [`tests/qemu/README.md`](tests/qemu/README.md).

## Integration tests (UI E2E + boot emulation)

Two rootless test suites run on this machine with Docker:

### A. UI end-to-end (Playwright + generated certs)

Brings up a rootless stack — generated TLS certs + runtime values, plus
multi-user **mock** Matrix/Mastodon/BFF servers — serves the built Angular host
over HTTPS, and drives it with Playwright (browsers come from the local
`snapdragongames-e2e` image, so no browser download). It proves, with
screenshots in `tests/e2e/screenshots/`:

1. front page loads over the **generated certs + values**,
2. an admin (Casdoor admin role) manages the **Gmail + Discord allowlist**,
3. registration is **Google/Discord-only and allowlist-gated** (denied otherwise),
4. **two-stage registration** — Matrix/Mastodon stay locked until registration completes,
5. **five users** fully register and reach both services,
6. users **chat with each other** over Matrix and **post** to Mastodon through our UI.

```bash
# one-shot: build host, gen certs, up stack, run Playwright, screenshot, tear down
./tests/e2e/run-all.sh

# or, against an already-running stack (tests/stack/up.sh):
./tests/e2e/run.sh
```

> `tests/stack/mock-*.mjs` are fast in-memory test doubles. For full fidelity,
> `tests/stack/up-real.sh` brings up real Synapse + Casdoor + Mastodon (+ the
> platform Cassandra) from `compose.real.yaml` — it generates the Synapse config
> and Mastodon DB first, then `docker compose up -d`. Point the suite at it with
> `SNAP_BASE_URL=...` (and `REAL_MATRIX=1` for the UI), and tear it down with
> `tests/stack/down-real.sh`.

### B. First-boot provisioning emulation (one of each node kind)

Runs the **real** `keys-provision` engine inside a container against a generated
KEYS directory (no block device needed) for each role — `pki`, `backend`,
`frontend`, `host` — asserting users/SSH-keys/sudoers/host-keys/hostname/markers:

```bash
./tests/boot/emulate-firstboot.sh                 # all four roles
./tests/boot/emulate-firstboot.sh pki backend     # specific roles
```

> This validates the boot-time provisioning the images run; it does not boot the
> aarch64 kernel (that needs a built stage4 — see the QEMU section, which boots
> the produced Image under `-M virt`).

## Build options

Run `./build-rpi5-stage4.sh --help` (and `./build-x86-host-stage4.sh --help`)
for the full man-style reference. Highlights:

| Flag | Default | Description |
|---|---|---|
| `-r, --role` | `generic` | `pki` \| `backend` \| `frontend` (RPi). Sets hostname, services, GitOps payload. |
| `--cluster-domain` | `snapdragon.systems` | Base domain for gateways / Casdoor. |
| `-w, --work-dir` | `./rpi5-stage4-build` | Git-ignored output directory. |
| `-j, --jobs` | `$(nproc)` | Parallel emerge/make jobs. |
| `--headscale-version` / `--tailscale-version` | pinned | Mesh binary versions. |
| `--skip-mesh` / `--skip-tailscale` | off | Omit mesh VPN / tailscale client. |
| `--skip-kernel` / `--skip-iso` / `--skip-clean` / `--resume` | off | Build phases. |
| `--pcie-gen3` | off | Force PCIe Gen 3 for NVMe (RPi, test your drive). |

## Spec files

The specs are split by architecture, mirroring the same pattern for both
builders: `specs-rpi5/` (aarch64/RPi5-specific) and `specs-x86/` (amd64-specific)
each hold that arch's portage/kernel/boot/installer specs, while `specs/` holds
the **arch-agnostic** specs both builds share (the `etc/` services, the KEYS
provisioning engine, the backup engine, and the `cluster/` GitOps payload).

| Path | Purpose |
|---|---|
| `specs-rpi5/portage/*` | RPi5 portage config (make.conf, packages, profile, keywords, USE) |
| `specs-rpi5/kernel/hardened-k8s.config` | RPi kernel fragment (hardened + k8s + USB/VFAT + virtio) |
| `specs-rpi5/boot/{config.txt.tmpl,cmdline.txt}` | RPi firmware boot config + kernel command line |
| `specs-rpi5/etc/fstab` | RPi filesystem table (mounts the `/boot` firmware partition) |
| `specs-rpi5/installer/install.sh` | SD/NVMe installer (ships in the RPi5 ISO) |
| `specs-x86/**` | amd64 host portage/kernel/installer/grub specs |
| `specs/etc/keys-provision/provision.sh` | USB KEYS provisioning engine (shared) |
| `specs/etc/init.d/{containerd,kubelet,headscale,tailscaled,keys-provision}` | OpenRC services (shared) |
| `specs/etc/headscale/config.yaml` | Default headscale config (shared) |
| `specs/etc/kubernetes/*`, `specs/etc/containerd/config.toml` | k8s + CRI config (shared) |
| `specs/etc/local.d/01-firstboot.start.tmpl` | First-boot finaliser (fallback user, shared) |
| `specs/usr/local/sbin/snapdragon-backup` | etcd + PostgreSQL backup engine (shared) |
| `specs/cluster/**` | ArgoCD app-of-apps, gateway Helm chart, manifests, bootstrap (shared) |
| `keys-template/**` | The KEYS USB template + schema docs |

## Repositories

This repo is the image/infra layer; application code lives in sibling repos —
see the table in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). The new
[`snapdragon-social-ui`](https://github.com/Snapdragon-Systems/snapdragon-social-ui)
holds the Matrix + Mastodon Angular micro-frontends.

## Security notes

- SSH is key-only; provide a key via KEYS or use the console fallback user.
- Prefer `password_hash` over plaintext; generate with `gen-provision-keys.sh`.
- The KEYS stick holds the cluster CA, preauth and backup credentials — keep it
  offline once provisioning is done. Generated secrets and build output are
  git-ignored.

## License

MIT

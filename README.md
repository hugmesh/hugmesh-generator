# snapdragon-generator

Crossdev / native build scripts that produce **hardened Gentoo images** for the
Snapdragon cluster — three Raspberry Pi 5 (aarch64) role images plus an x86_64
GPU host — and the **GitOps payload** that runs Casdoor, tuwunel (Matrix) + Akkoma (fediverse), the
Spring APIs and snapdragon.games on them. Everything connects **behind
`snapdragon.systems`** through per-namespace Spring Cloud Gateways.

Every image boots, then provisions itself at first boot from a USB **FAT32
`KEYS` partition** (users, SSH keys, passwords, certificates, headscale/k8s
config, attached storage, backups) — see [`keys-template/`](keys-template/).

Every build is stamped with a **build ENV** — `test` (default, LAN-only) or
`prod` (real public domain) — baked into the image at creation. The simplest
way in is `make local` (a LAN `.test` fleet) or `make prod`; see
**[Build ENV](#build-env-testprod-baked-at-image-creation)** below.

> **Read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full topology
> and [`docs/LOCAL-TESTING.md`](docs/LOCAL-TESTING.md) for LAN testing.**

All build output lands in a **git-ignored** work directory (`./out` by default,
for both `make` and the scripts called directly; override with `WORK_DIR=` /
`-w`). The finished **products** (`.img`, `.iso`, `.fs.tar.xz`, `stage4-*`,
`keys-<role>/`) land directly in the work dir. Each arch's **heavy build tree**
(sysroot, distfiles, pkgdir, ISO staging) lives in a **per-arch subdirectory**
under it — `out/snap-build-pi5` (aarch64) and `out/snap-build-x86` (amd64) — so
the Pi and x86 builds **never share a sysroot**, even when the whole fleet builds
into one work dir via `make build-all`. Override a subdir name with
`--build-subdir NAME` (or `BUILD_SUBDIR=NAME`). `make clean` wipes the work dir,
subdirs included.

## Images

| Image | Build command | Runs |
|---|---|---|
| **pki** (RPi 5) | `./build-rpi5-stage4.sh --role pki` | k8s control plane, headscale, Casdoor, Cassandra, pki-gateway |
| **backend** (RPi 5) | `./build-rpi5-stage4.sh --role backend` | tuwunel (Matrix) + Akkoma (fediverse), Spring APIs, DBs, be-gateway, LAN wildcard DNS (test) |
| **frontend** (RPi 5) | `./build-rpi5-stage4.sh --role frontend` | snapdragon.systems Angular host + login/matrix/mastodon remotes, fe-gateway |
| **host** (x86_64) | `sudo ./build-x86-host-stage4.sh` | GPU worker: ArgoCD, snapdragon.games, backend capacity |

> The friendlier path is the **Makefile** (`make local` / `make prod` /
> `make build-all`), which dispatches the same builders inside a self-contained
> Docker builder — no host toolchain, no host sudo. See
> [Quick start](#quick-start) and [Build options](#build-options).

## Build ENV (`test`|`prod`) — baked at image creation

Each image is stamped with a **build ENV** at creation time, written to
`/etc/snapdragon/env` in the image and threaded through the whole build
(`--env test|prod` on every builder, `ENV=test|prod` through `make`). The ENV
bakes the right posture into the image — you do **not** flip it at runtime.

| | **`test`** (default) | **`prod`** |
|---|---|---|
| domain | `<brand>.test` (e.g. `snapdragon.test`) | the **real** domain (e.g. `snapdragon.systems`) |
| DNS mode | in-cluster **wildcard DNS** (`apps/09-lan-dns.yaml` kept — **only for a `.test` domain**) | public DNS / Cloudflare (`apps/12-cloudflared.yaml` kept) |
| the other DNS app | `12-cloudflared.yaml` **pruned** from the baked tree (and `09-lan-dns.yaml` is **also** pruned if the domain is **not** `.test`, so an `ENV=test` build on a real domain keeps neither edge) | `09-lan-dns.yaml` **pruned** from the baked tree |
| cloudflared / external-DNS / ACME | off | on (go-live edge; creds from the keys USB) |
| TLS | internal cluster CA only (Vault-PKI / self-signed root) | cluster CA **+** ACME/public (ACME is **additive**) |
| OAuth / SMTP | optional / absent → Casdoor **native** login, admin-approval registration | creds **expected** from the keys USB (still optional if absent) |
| build banner | quiet | **LOUD announced** (`BUILDING PROD IMAGE for <domain>`) |

The default is **`test`** (local-first / safe). `prod` is explicit and
announced because it bakes the real public domain. The builders prune the
ENV-irrelevant ArgoCD app from `/var/lib/snapdragon/cluster/apps` so ArgoCD only
ever syncs the right one for the baked ENV.

```bash
make local                                  # ENV=test + brands/local.conf (snapdragon.test) — LAN fleet
make prod                                   # ENV=prod, real domain (announced)
make build-all ENV=test BRAND=acme          # any brand, test
make build-all ENV=prod BRAND=acme DOMAIN=acme.example
./build-x86-host-stage4.sh --env test --config brands/local.conf --role be+gpu
./scripts/build-all-roles.sh --env prod
```

> Full reference: [`docs/LOCAL-TESTING.md`](docs/LOCAL-TESTING.md).

## LAN testing (no public internet, no Cloudflare)

An `ENV=test` fleet is **fully testable on a LAN before any public address**.
Two pieces make that work with zero internet:

1. **Cluster-served wildcard DNS.** Cluster *nodes* already resolve each other
   (`provision.sh` writes `/etc/hosts`), but LAN *clients* (your browser, the
   Playwright runner) are not on the mesh and have no record for `id.<domain>`,
   `api.<domain>`, `matrix.<domain>`, `mastodon.<domain>` or the apex.
   `apps/09-lan-dns.yaml` deploys a **CoreDNS** resolver (`manifests/lan-dns`)
   that runs `hostNetwork` on the **backend node** (the same node ingress-nginx
   binds `:80/:443` on) and binds host **`:53` (udp+tcp)**, answering every name
   under the brand domain with that node's LAN IP (injected by `bootstrap.sh`).
   Point your **router's DHCP DNS** (fleet-wide) or a single client's resolver
   at the **backend/ingress node `:53`** once, and every LAN device resolves
   `*.<domain>` → the cluster.

   ```bash
   # backend node IP (the one your router forwards 80/443 to):
   kubectl get node -l snapdragon.systems/backend=true \
     -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
   # point a client at it, then:
   dig @<BACKEND_IP> id.snapdragon.test +short      # -> the backend node IP
   curl -k https://id.snapdragon.test/              # reaches Casdoor via ingress
   ```

2. **Internal cluster-CA TLS.** All certs chain to the internal cluster CA
   (Vault-PKI / self-signed root) — **no ACME, no public CA, no internet**. This
   is the *same* offline issuer prod uses; prod merely **adds** the public edge.

So `ENV=test` needs **no public internet, no Cloudflare, no OAuth, no SMTP** —
just Casdoor's native login, the internal cluster CA, and the in-cluster
wildcard resolver. See [`docs/LOCAL-TESTING.md`](docs/LOCAL-TESTING.md).

## Rebranding (brand profiles in `brands/`)

Everything is **string-independent**: the default naming is `snapdragon` /
`snapdragon.systems`, but you can build images for any brand/domain. A **brand
profile** is a plain shell file the builders `source` (via `--config FILE`, or an
auto-detected `./brand.conf`). Precedence is **built-in defaults < profile < CLI
flags**, so an absent file changes nothing. See [`brands/README.md`](brands/).

Committed profiles live in [`brands/`](brands/):

| File | Contains |
|---|---|
| [`brands/local.conf`](brands/local.conf) | the **LAN `.test` profile** — `snapdragon.test`, `MAIL_PROVIDER=none`, OAuth/Cloudflare off, local-first mesh. Used by `make local`. |
| [`brands/example.conf`](brands/example.conf) | a complete, safe-to-commit example (`example.test`) to copy. |
| `brands/<yourbrand>.conf` | your brand's `BRAND` / `BRAND_TITLE` / `ORG` / `CLUSTER_DOMAIN` / `MAIL_PROVIDER` / mesh (no secrets). |
| `../brand.conf` *(gitignored)* | the same vars **with** real passwords/tokens. |

```bash
cp brands/example.conf brands/acme.conf   # edit BRAND / BRAND_TITLE / ORG / CLUSTER_DOMAIN / MAIL_PROVIDER
make build-all BRAND=acme                  # threads --config brands/acme.conf into every builder
make build-all BRAND=acme DOMAIN=acme.example   # DOMAIN= overrides the profile's CLUSTER_DOMAIN
# or directly, no make:
./build-rpi5-stage4.sh --config brands/acme.conf --role backend
./build-rpi5-stage4.sh --role backend --brand acme --domain acme.example --org Acme-Inc --brand-title "Acme Corp"
```

At build time the baked cluster payload is rewritten — every namespace
(`acme-pki`/`acme-backend`/…), gateway name, ingress host (`matrix.acme.example`),
image org (`acme-inc/…`), title and hostname — from the snapdragon defaults to
your brand. (Internal install paths like `/var/lib/snapdragon` and the
provisioning JSON key are kept as the tool's vendor namespace.) Never put real
secrets in a committed `brands/*.conf`; those go in the gitignored `./brand.conf`
or the environment.

## OAuth + mail (optional; native login by default)

Both OAuth and mail are **optional and absent by default**. With neither, the
platform falls back to **Casdoor's native user/pass login** and
**admin-approval** registration (no email verification) — exactly what an
`ENV=test` LAN fleet uses.

**OAuth federation providers (seeded into Casdoor when creds are present).**
The provider seeding in the Casdoor init jobs is **read-if-present, else
skipped** — an absent client secret no-ops the provider:

- **Systems realm** (`manifests/casdoor/init-job.yaml`): the **Google** OAuth
  provider, seeded from the `casdoor-google` Secret
  (Vault `secret/<brand>/casdoor: google_client_id/google_client_secret`).
- **Games realm** (`manifests/casdoor-games/init-job.yaml`): a **GitHub** OAuth
  provider that creates native games `player`s, seeded from `casdoor-games-github`
  (Vault `casdoor-games: github_client_id/github_client_secret`).

> The games realm is a **separate Casdoor** (org `threewizards`, issuer
> `id.<domain.games>`) from the platform realm (org `snapdragon`); see
> [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

**Mail (SMTP).** A `MAIL_PROVIDER` brand knob selects the mail posture;
`none` (the `brands/local.conf` default) disables mail entirely, which is the
typical local/test setting — registration stays admin-approval rather than
email-verify. Set it in your `brands/<x>.conf`:

```sh
MAIL_PROVIDER="none"       # none | smtp   (none = no mail; the LAN/test default)
```

**Credentials flow.** OAuth client IDs/secrets, cluster app secrets and the
Cloudflare go-live token are produced by
[`scripts/gen-cluster-secrets.sh`](scripts/gen-cluster-secrets.sh) and delivered
either online via **Vault → External Secrets Operator** or offline via the
**KEYS USB** (`KEYS/vault/secrets.json`, plus `KEYS/cloudflared/tunnel-token` for
the prod edge) — Vault first, USB fallback, all **read-if-present**. See
[`keys-template/vault/README.md`](keys-template/vault/) and
[`keys-template/cloudflared/README.md`](keys-template/cloudflared/).

## Prerequisites (build host)

- **RPi 5 images** (cross-compiled, run with **sudo** — cross-emerge merges into
  the sysroot + writes host caches; fakeroot is not enough): `crossdev` with
  `aarch64-unknown-linux-gnu` built, plus `curl`, `tar`, `file`, `xorrisofs`
  (`dev-libs/libisoburn`). `crossdev --stable --target aarch64-unknown-linux-gnu`.
- **x86_64 host image** (native, **root** required): an amd64 Gentoo host with
  `grub`, `squashfs-tools`, `libisoburn` (for `grub-mkrescue`/`xorriso`).
- **QEMU test**: `app-emulation/qemu` (aarch64 target), `dosfstools`, `e2fsprogs`.

## Quick start

### The easy path — `make` (Docker builder; no host toolchain, no sudo)

The Makefile is the front door. Its **default** build path runs inside a
self-contained Gentoo builder image (`Dockerfile.build`), so the host needs no
cross-toolchain and no sudo. Build the builder image once (LONG — it compiles
the aarch64 cross-toolchain), then build images:

```bash
make docker-image       # one-time: build the self-contained Gentoo builder image (LONG)

make local              # LAN .test fleet: ENV=test + brands/local.conf (snapdragon.test)
make prod               # PROD fleet: ENV=prod, real domain (announced)

make build-all          # the default fleet (3 Pi + x86 pki/be/fe/be+gpu), ENV defaults to test
make rpi                # all 3 Pi roles        make rpi-frontend     # one Pi role
make x86                # the 4 x86 roles       make x86-be+gpu       # one x86 role
make omnibus            # opt-in x86 all-in-one node
```

Products land in `./out` (gitignored). Run `make help` for every target. Use
`NATIVE=1` to run the scripts directly on a local Gentoo host instead of Docker.

### The native path — build on Gentoo (copy-paste)

Run the builds as **root** (the cross-emerge merges into the sysroot's package DB
and writes host caches; fakeroot is not enough). Artifacts land in the git-ignored
`./rpi5-stage4-build/` and `./x86-host-build/`.

Every artifact of one build run is **brand- and timestamp-named** so test vs prod
images are distinguishable and runs never clobber each other:

```
<brand>-<arch>-<role>-<env>-<UTC-stamp>.<ext>

# e.g. (test)  snapdragon-rpi5-arm64-frontend-test-20260610T193045Z.img
#      (prod)  snapdragon-x86-amd64-host-prod-20260610T193045Z.img
```

`<arch>` is `rpi5-arm64` or `x86-amd64`; `<env>` is `test` or `prod`; `<UTC-stamp>`
is `date -u +%Y%m%dT%H%M%SZ`, computed once per run so the `.img`, `.iso`,
`.stage4.tar.xz` and `.fs.tar.xz` all share it. The `make flash` / `make qemu`
targets and `flash-disk.sh` autodetect the newest matching image, so you rarely
type the full name.

```bash
# 0. Build-host prerequisites (one-time). RPi5 cross-toolchain + ISO tooling:
sudo emerge -an dev-libs/libisoburn app-arch/tar sys-apps/file net-misc/curl
sudo crossdev --stable --target aarch64-unknown-linux-gnu
#    x86_64 host image also needs:  sys-boot/grub sys-fs/squashfs-tools
#    QEMU integration test also needs:  app-emulation/qemu sys-fs/dosfstools sys-fs/e2fsprogs

# 1. Build the images (--env defaults to test; add --env prod for a go-live image)
sudo ./scripts/build-all-roles.sh -j "$(nproc)"          # all three Pi roles: pki, backend, frontend
sudo ./build-rpi5-stage4.sh --role pki -j "$(nproc)"     # …or just one Pi role
sudo ./build-x86-host-stage4.sh -j "$(nproc)"            # x86_64 GPU host (native amd64 Gentoo)

# 2. Cluster secrets + a per-node KEYS provisioning stick (users, SSH, certs, k8s join, GitOps)
./scripts/gen-cluster-secrets.sh                         # cluster-wide secrets (Vault + USB fallback) — once
./scripts/gen-provision-keys.sh -r pki -o keys-pki       # also: -r backend | -r frontend | -r host
sudo ./scripts/make-keys-usb.sh /dev/sdY keys-pki        # FAT32 stick labelled KEYS (one per node)

# 3. Flash the OS to each node's SD/NVMe (boot a Linux live env, mount the role's ISO)
sudo mount -o loop rpi5-stage4-build/snapdragon-rpi5-arm64-pki-*.iso /mnt/iso
sudo /mnt/iso/install.sh /dev/sdX                        # SD card, or /dev/nvme0n1
sudo umount /mnt/iso
#    x86 host: boot the snapdragon-x86-amd64-*.iso live image, then run  install-x86.sh /dev/sdX  from it.

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

> `bootstrap.sh` also injects the backend node's LAN IP into the resolver
> Corefile (`ENV=test` only) so the in-cluster wildcard DNS answers
> `*.<domain>` → that node. After bootstrap, point your router/clients at the
> backend node `:53` — see [LAN testing](#lan-testing-no-public-internet-no-cloudflare).

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
(in-cluster git on pki), the Spring APIs, the Angular host + federated remotes
(login/matrix/mastodon/admin) and snapdragon.games. In `ENV=test` it also syncs
the in-cluster wildcard-DNS resolver (`apps/09-lan-dns.yaml`); in `ENV=prod` the
cloudflared go-live edge instead. See
[`specs/cluster/README.md`](specs/cluster/README.md).

### Vanity subdomains (`<username>.snapdragon.systems`)

A user can serve their PUBLIC profile at `https://<username>.snapdragon.systems`.
The routing is:

```
*.snapdragon.systems  ──►  backend ingress  ──►  fe-gateway
   (wildcard DNS:                                  │  (apps/20-gateway-fe.yaml)
    lan-dns in test,                               │
    Cloudflare wildcard in prod)                   ▼
   Host=*.snapdragon.systems route  ──►  federation-api  (direct, no be-gateway)
   (SetPath=/api/federation/vanity,        GET /api/federation/vanity
    Host header preserved)                 resolves the PUBLIC profile fragment
                                           by the first DNS label of the Host
```

Three baked-in pieces make this work:

1. **Wildcard DNS already points `*.snapdragon.systems` at the backend ingress** —
   `manifests/lan-dns` answers the whole brand zone (apex + every subdomain) with
   the ingress IP in `ENV=test`; the Cloudflare wildcard does so in `ENV=prod`.
   The reserved service subdomains (`id. api. matrix. mastodon. scale. headscale.`)
   are fronted by the **be-gateway** ingress + cloudflared, not the fe-gateway.

2. **fe-gateway ingress admits the wildcard** — `apps/20-gateway-fe.yaml` adds
   `ingress.extraHosts: ["*.snapdragon.systems"]`, so the nginx Ingress accepts the
   vanity hosts and hands them to the gateway.

3. **A `Host=*.snapdragon.systems` gateway route, ordered for PRECEDENCE.** Spring
   Cloud Gateway matches routes **first-in-declared-order**, so the route is placed
   **after** the apex/path routes and **before** the `frontend-host` `Path=/**`
   catch-all. The `Host=*.<domain>` predicate matches `alice.<domain>` but **not**
   the apex `<domain>` (the `*` needs ≥1 label), so the apex still falls through to
   `frontend-host`; the reserved hosts never reach this gateway. The route rewrites
   the path to `/api/federation/vanity` (via `SetPath`) and forwards **directly to
   federation-api** (NOT via the be-gateway) with the **Host header preserved**, so
   federation extracts the username from the first DNS label
   (`VanityController.resolveByHost`) and returns the public profile-fragment
   descriptor. Direct (not via be-gateway) because the resolve is a **public read**
   (no JWT — it IS the public profile) and federation-api already `permitAll`s
   `GET /api/federation/vanity/**`; interposing the be-gateway would add an auth
   layer that 401s the anonymous request.

**Precedence summary (first-match wins, top to bottom):** the reserved service
subdomains (`id. api. matrix. mastodon. scale. headscale.`) are claimed by the
**be-gateway** ingress + the cloudflared rules *above* the wildcard, so they never
reach the fe-gateway. The apex `snapdragon.systems` is not matched by
`Host=*.<domain>` and falls through to `frontend-host`. Only the remaining
`<username>.<domain>` hosts hit the vanity route. The cloudflared `*.<domain>` rule
(`manifests/cloudflared`) is likewise ordered **after** the reserved hostnames and
**before** the 404 catch-all.

**Honest cross-service deferral (a THIRD repo).** The shared gateway image
(`snapdragon-gateway`) ends its `SecurityConfig` with `anyExchange().authenticated()`
and permits only a hardcoded `PUBLIC_PATHS` allowlist (`/api/auth`,
`/api/registration`, `/api/login`, the login/registration/banned remotes).
`/api/federation/vanity/**` is **not** in it, so the fe-gateway pod would itself
401 the anonymous vanity request before proxying. **To make the public vanity host
reachable, `/api/federation/vanity/**` (or a `Host=*.<domain>` public rule) must be
added to the gateway `PUBLIC_PATHS` in the `snapdragon-gateway` repo** — out of
scope for this generator/federation-api pass and documented as a deferral. The
generator side here (wildcard DNS already in place, fe-gateway ingress wildcard
host, the ordered `Host=*.<domain>` route to federation-api, the cloudflared
wildcard rule) is complete and renders clean (`helm template` /
`kubectl kustomize`).

The PUBLISH path (marking a user's profile fragment `visibility=public` when they
enable vanity in user-bff-api) and the SERVING page (the host shell that renders
the resolved fragment) are documented — including the honest cross-service
deferrals — in the
[snapdragon-federation-api README](https://github.com/Snapdragon-Systems/snapdragon-federation-api)
("Vanity subdomains" + "Deferred / stubbed").

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
| `--env test\|prod` | `test` | **Build ENV, baked into `/etc/snapdragon/env`.** `test` = LAN-only (wildcard DNS kept, cloudflared/ACME pruned, internal CA); `prod` = real public domain (cloudflared/ACME kept, announced banner). See [Build ENV](#build-env-testprod-baked-at-image-creation). |
| `-C, --config FILE` | auto `./brand.conf` | Source a brand profile (e.g. `brands/local.conf`). |
| `--cluster-domain` | `snapdragon.systems` | Base domain for gateways / Casdoor. |
| `-w, --work-dir` | `./rpi5-stage4-build` | Git-ignored output directory. |
| `-j, --jobs` | `$(nproc)` | Parallel emerge/make jobs. |
| `--headscale-version` / `--tailscale-version` | pinned | Mesh binary versions. |
| `--skip-mesh` / `--skip-tailscale` | off | Omit mesh VPN / tailscale client. |
| `--skip-kernel` / `--skip-iso` / `--skip-clean` / `--resume` | off | Build phases. |
| `--pcie-gen3` | off | Force PCIe Gen 3 for NVMe (RPi, test your drive). |

### `make` targets

`make` is the front door over the builders + tooling (run `make help` for the
live list). Common overrides: `ENV=test|prod`, `BRAND=`, `DOMAIN=`,
`HEADSCALE_URL=`, `WORK_DIR=`, `JOBS=`, `ROLE=`, `ARCH=x86|arm64`, `DEV=/dev/sdX`,
`IMG_FLAGS='--no-iso'`, `NATIVE=1`, `CA_CERT=`/`CA_KEY=`.

| Target | What it does |
|---|---|
| `make docker-image` (alias `docker`) | build the self-contained Gentoo builder image (LONG first time). |
| `make local` | ENV=test + `brands/local.conf` → the LAN `snapdragon.test` fleet. |
| `make prod` | ENV=prod, real domain (announced; creds from the keys USB). |
| `make build-all` / `make rebuild` | the default fleet (3 Pi + x86 pki/be/fe/be+gpu); `rebuild` wipes first. |
| `make rpi` / `make rpi-<role>` | all 3 Pi roles / one Pi role (`rpi-frontend`). |
| `make x86` / `make x86-<role>` | the 4 x86 roles / one (`x86-be+gpu`, `x86-pki`, `x86-omnibus`). |
| `make omnibus` | the opt-in x86 all-namespaces-on-one-node image. |
| `make flash DEV=/dev/sdX ROLE=frontend ARCH=arm64` | write a role image to a disk (`.img` preferred). |
| `make qemu` (`qemu-rpi` / `qemu-x86`) | boot a role image under QEMU (`ARCH=arm64`→Pi, `x86`→q35+OVMF). |
| `make e2e` | boot a role VM under QEMU and run the Playwright e2e with seeded accounts. |
| `make ci` / `make ci-quick` | full pipeline (rebuild fleet → e2e) / fast (build x86 be+gpu → e2e). |
| `make clean` | wipe the work dir. |

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
see the table in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). The
`snapdragon.systems` host shell federates the per-feature remotes
(`snapdragon-login-ui`, `snapdragon-matrix-ui`, `snapdragon-mastodon-ui`,
`snapdragon-admin-ui`) over module federation.

## CI

Continuous integration runs on **GitLab** ([`.gitlab-ci.yml`](.gitlab-ci.yml)):
GitHub is pull-mirrored into an in-cluster GitLab, and a privileged runner on
the x86 node builds the role ISOs + container images and delivers the ISOs as
generic-package release assets (latest-link path) for the admin UI's download
links. ISOs carry **no keys** — KEYS material is supplied from the USB at first
boot, never baked in or published.

> **GitHub Actions is intentionally absent** — Actions is billing-blocked
> org-wide (jobs fail at setup). Do **not** add `.github/workflows`; CI lives in
> GitLab.

## Security notes

- SSH is key-only; provide a key via KEYS or use the console fallback user.
- Prefer `password_hash` over plaintext; generate with `gen-provision-keys.sh`.
- The KEYS stick holds the cluster CA, preauth and backup credentials — keep it
  offline once provisioning is done. Generated secrets and build output are
  git-ignored.

## License

MIT

# RUNNING — build, key, flash and provision a HugMesh fleet

A single end-to-end runbook for a **new operator**. It walks the whole pipeline
in order: prerequisites → clone → configure (`brand.conf` + build knobs) → build
images → generate keys + a KEYS USB → flash → boot/provision → bring up the
cluster. Every command and flag here is taken straight from the scripts in this
repo; where a knob has subtleties, the relevant script is named so you can read
the source.

> New here? Read the top-level [`README.md`](../README.md) first for the
> what/why, then use this file as the do-it checklist. For the LAN-only flow see
> [`docs/LOCAL-TESTING.md`](LOCAL-TESTING.md); for the optional services
> (akkoma/tuwunel/phpbb/games) see [`docs/OPTIONAL-SERVICES.md`](OPTIONAL-SERVICES.md);
> for the all-in-x86 docker-compose stack (no hardware) see
> [`docs/LOCAL-STACK.md`](LOCAL-STACK.md).

The pipeline at a glance:

```
 prereqs → clone → brand.conf + knobs → BUILD images ──┐
                                                        │  (per arch: Pi5 aarch64 / x86 amd64)
 gen-cluster-secrets ─ gen-provision-keys ─ make-keys-usb (KEYS stick, one per node)
                                                        │
 flash-disk (OS .img/.iso to SD/USB/NVMe) ─ insert KEYS ─ BOOT (self-provisions)
                                                        │
 pki node first → ArgoCD app-of-apps → workers join → platform converges
```

There are **two front doors** to every build step:

- **`make`** (recommended) — runs the builders inside a self-contained Gentoo
  Docker builder image, so the host needs **no cross-toolchain and no sudo**.
- **the scripts directly** — `build-rpi5-stage4.sh` / `build-x86-host-stage4.sh`
  / `scripts/*.sh`, run as **root** on a Gentoo build host (`NATIVE=1` for `make`).

Both produce identical artifacts. This guide leads with `make` and gives the
direct-script equivalent at each step.

---

## 0. Prerequisites

### 0a. Docker path (recommended — any Linux host)

- **Docker** (the build runs privileged: it needs `/dev/loop` + `mount` to build
  the `.img`). That is the only host requirement for building.
- For **flash / QEMU** steps that touch real disks or KVM you still need the
  host tools below and root for the destructive operations.

Build the builder image once (LONG the first time — it compiles the aarch64
cross-toolchain):

```bash
make docker-image       # alias: make docker
```

After that, `make build-all` / `make rpi` / `make x86` / `make local` etc. all
run inside it automatically (`make` auto-builds the image if it is missing).

### 0b. Native path (build on a Gentoo host, as root)

Run the builders as **root** — the cross-emerge merges into the sysroot's
package DB and writes host caches, so real root is required (fakeroot is not
enough). One-time host packages:

```bash
# RPi5 (aarch64) cross-build + ISO tooling
sudo emerge -an dev-libs/libisoburn app-arch/tar sys-apps/file net-misc/curl
sudo crossdev --stable --target aarch64-unknown-linux-gnu

# x86_64 host image additionally needs
sudo emerge -an sys-boot/grub sys-fs/squashfs-tools     # grub-mkrescue / mksquashfs

# QEMU integration test additionally needs
sudo emerge -an app-emulation/qemu sys-fs/dosfstools sys-fs/e2fsprogs
```

### 0c. Tooling used by the key/secret/flash scripts (both paths)

These run on the **operator workstation** (no root except the destructive disk
writes):

- `gen-provision-keys.sh` — `openssl`, `ssh-keygen`, `python3`, `jq`
- `gen-cluster-secrets.sh` — `openssl`, `python3` (optional `vault` CLI for online push)
- `gen-keystores.sh` — `openssl`, `keytool` (JDK)
- `make-keys-usb.sh` / `flash-disk.sh` — `parted`, `mkfs.vfat`, `lsblk`, `dd`,
  `blkid`, `partprobe` (and **root** for the actual write)
- `clone-all-repos.sh` — `git`, and `gh` (logged in) **or** a token/VPN to the mirror

### 0d. NixOS / SteamOS / gaming distros (Studio wizard + menu, no `make` needed)

Just want the **Studio wizard** or the **ncurses menu** on a host where `python3` /
`make` are absent or the layout is non-FHS (NixOS, SteamOS / Steam Deck, Arch,
Debian/Ubuntu, Fedora)? Two **additive** front doors (they change nothing above):

- **Nix** — `flake.nix` / `shell.nix` supply python3 + PySide6 + make + whiptail:

  ```bash
  nix develop            # then: ./scripts/studio-launch.sh   or   make menu
  nix run .#studio       # launch the wizard directly (nix run .#menu for the menu)
  nix-shell              # non-flake parity (shell.nix)
  ```

- **Portable launcher** — `scripts/studio-launch.sh` detects the distro, uses the
  system Python when it can, else bootstraps a project-local venv (consent-gated),
  and exports `PYTHONPATH=$REPO/studio` so it runs from any directory:

  ```bash
  ./scripts/studio-launch.sh          # detect → offer a venv (y/N) → launch the wizard
  ./scripts/studio-launch.sh --detect # print the DETECT report and exit
  ./scripts/studio-launch.sh --menu   # hand off to the ncurses build menu
  ./scripts/studio-launch.sh --redo-first-run   # force the first-run bootstrap
  ```

  The first guided/menu run also performs a one-time, advisory-only bootstrap:
  `hugmesh-studio` / `hugmesh-build-menu` symlinks in `~/.local/bin` (no sudo),
  a `~/.hugmesh/studio/properties.json` with the resolved paths, and a fast
  doctor pass — see [`docs/FIRST-RUN.md`](FIRST-RUN.md).

See [`docs/NIXOS-STEAMOS.md`](NIXOS-STEAMOS.md) for per-distro copy-paste blocks
(SteamOS Desktop vs Game Mode, `QT_QPA_PLATFORM=xcb`, read-only rootfs, the
missing-`make` caveat for real builds).

---

## 1. Clone the generator

```bash
git clone https://github.com/hugmesh/hugmesh-generator
cd hugmesh-generator
```

All build output lands in a **git-ignored** work directory — `./out` by default
for both `make` and the scripts. Products (`.img`/`.iso`/`.fs.tar.xz`/`stage4-*`/
`keys-<role>/`) land directly in it; each arch's heavy build tree lives in a
per-arch subdir (`out/snap-build-pi5`, `out/snap-build-x86`) so the two arches
never share a sysroot.

> **Need every app repo too?** (only for the docker-compose local stack, not the
> image build): `make stack-clone` (wraps `scripts/clone-all-repos.sh`) clones
> the full first-party repo set into `./.stack-src`. `GIT_BASE=` points it at the
> internal GitLab mirror over the VPN; `GIT_REF=` picks the branch.

---

## 2. Configure — `brand.conf` + build knobs

Everything is string-independent. The default brand is `hugmesh` /
`hugmesh.net`; you can build for any brand/domain. Precedence is always
**built-in defaults < brand profile < CLI flags**, so an absent profile changes
nothing.

```bash
cp brand.conf.example brand.conf       # auto-detected ./brand.conf (gitignored — holds secrets)
# or, a committed (secret-free) profile under brands/:
cp brands/example.conf brands/acme.conf
```

`brand.conf` (and `brands/<x>.conf`) are plain shell files the builders
`source`. The knobs that matter for a run:

| Knob | Default | What it sets |
|---|---|---|
| `BRAND` | `hugmesh` | short slug → namespaces, gateway names, hostnames |
| `BRAND_TITLE` | `HugMesh Systems` | human title shown in UIs |
| `ORG` | `hugmesh` | GitHub org / container-image namespace |
| `CLUSTER_DOMAIN` | `hugmesh.net` | base domain (`id.`/`api.`/`matrix.`/`mastodon.` derived) |
| `OPTIONAL_SERVICES` | `akkoma tuwunel phpbb games` (all) | which optional services to bake (see §2a) |
| `GAMES_DOMAIN` | `games.<CLUSTER_DOMAIN>` | games portal host + OIDC issuer (see §2b) |
| `GROW_POLICY` | `fill` | first-boot root-grow policy baked into the `.img` (see §2c) |
| `DEFAULT_USER` / `DEFAULT_USER_PASS` / `ROOT_PASS` | `pi` / `raspberry` / `gentoo` | **fallback** console accounts when no KEYS stick is present — change for real builds |
| `ADMIN_EMAILS` | `admin@<domain>` | seeded Casdoor admin + BFF allowlist (the platform login admin; see §7d) |
| `MAIL_PROVIDER` | `protonmail` | SMTP preset; `none` disables mail (see §2d) |
| `TIMEZONE` | `UTC` | image timezone |
| `HEADSCALE_VERSION` / `TAILSCALE_VERSION` | pinned | mesh binary versions |
| `VAULT_ADDR` / `VAULT_KV_MOUNT` | empty / `secret` | online secret push (empty = offline/USB-only) |
| `CA_CERT` / `CA_KEY` / `CA_KEY_PASS` | unset | use an **existing** CA as the issuer instead of a self-signed root |

> **Secrets never go in a committed `brands/*.conf`.** Real SMTP/OAuth/Vault/CA
> passwords belong in the gitignored `./brand.conf`, the environment, or the KEYS
> USB. `brands/example.conf` and `brands/local.conf` are safe-to-commit examples.

### 2a. `OPTIONAL_SERVICES` — add/remove services per image

The four optional (non-architecture) services are `akkoma` (Mastodon/fediverse),
`tuwunel` (Matrix), `phpbb` (forum) and `games`. The builders **prune** any slug
not listed from the baked GitOps tree (Application YAMLs, gateway host routes,
route-access rows, the per-service ESO half — all enumerated by
`specs/cluster/optional-services.yaml`); the rest of the stack degrades gracefully
(greyed-out, never 502) when one is omitted. Built-in default is **all four on**.

```sh
# in brand.conf:
OPTIONAL_SERVICES="akkoma games"       # forum-less + Matrix-less appliance
```
```bash
# or on the CLI (overrides the profile):
./build-rpi5-stage4.sh --role backend --optional-services "akkoma games"
```

### 2b. `GAMES_DOMAIN` — games portal host

Games is served as a **subdomain** of the primary domain by default
(`games.<CLUSTER_DOMAIN>`) until the real `.games` TLD is obtained. This one value
drives every games host + the games-realm OIDC issuer/redirect (parameterized by
the builders + a casdoor-games re-seed on ArgoCD sync). Flip it to the TLD later:

```sh
GAMES_DOMAIN="hugmesh.games"        # brand.conf — or --games-domain on the CLI
```

See [`docs/OPTIONAL-SERVICES.md`](OPTIONAL-SERVICES.md) for the TLD-flip checklist
(new DNS zone + wildcard + cloudflared + public TLS).

### 2c. `GROW_POLICY` — first-boot disk grow

The `.img` is built **compact** (only root + boot), so it flashes fast and is not
padded to the target USB. On first boot the `growroot` service expands the last
partition per this policy:

| value | effect |
|---|---|
| `fill` (default) | expand root to fill the **whole** USB/SD/NVMe |
| `none` (`--no-grow`) | keep the compact flashed layout |
| `<size>` | cap the root, e.g. `16G`, `12000M`, `50%`; the rest is left free |

Set `GROW_POLICY=` in `brand.conf`, or `--grow <v>` / `--no-grow` on the CLI. You
can retune a single flashed medium without a rebuild via `growfs.conf` on the
boot/ESP partition or a `growfs=<v>` kernel cmdline token (precedence: cmdline >
boot `growfs.conf` > baked `/etc/growfs.conf` > built-in `fill`).

### 2d. Mail + OAuth (optional, absent by default)

With no SMTP creds and no OAuth creds the platform falls back to its **native
username/password login** (the first-party `login-ui` form → `POST /bff/login` →
user-bff → internal Casdoor credentials; the browser never touches Casdoor) **+
admin-approval registration** — exactly what a LAN/test fleet uses. `MAIL_PROVIDER` (`protonmail`|`gmail`|`outlook`|`smtp`|`none`) only selects
the host/port/TLS preset; nothing is wired until `gen-cluster-secrets.sh` has a
real `MAIL_USER`+`MAIL_PASSWORD`. The OAuth client ids/secrets (GitHub, Discord)
are secrets supplied via env or the KEYS USB, never a committed file. See the
[OAuth + mail](../README.md#oauth--mail-optional-native-login-by-default) section
of the README.

### 2e. Build ENV (`test` | `prod`) — baked at image creation

Orthogonal to the brand: each image is stamped with a build ENV at creation,
written to `/etc/hugmesh/env`. `--env test` (the **default**, LAN-first/safe)
keeps the cluster wildcard-DNS app and prunes cloudflared/ACME; `--env prod` bakes
the **real** public domain (keeps cloudflared/external-DNS/ACME, prunes LAN DNS)
and prints a LOUD announced banner. You do not flip it at runtime. Full table:
[README → Build ENV](../README.md#build-env-testprod-baked-at-image-creation).

---

## 3. Build the images

### 3·menu. Interactive console menu (easiest)

```bash
make menu          # or:  ./scripts/build-menu.sh
```

A terminal (whiptail/ncurses) front door over every build target below. It drives
the **same `make` targets**, so it works for **both** build paths — the Docker
builder (default) and the local `NATIVE=1` Gentoo path (toggle it under *Options →
Build path*). Pick a fleet/role, set ENV/brand/jobs, and it launches the build.

- **Live progress** — a monitor screen shows overall + per-role + current-package
  bars (parsed from the build log) plus a rolling log tail.
- **Quit without stopping** — builds run *detached* (`setsid`), so pressing `q`
  (or even closing the terminal) leaves the build running. Press `s` in the
  monitor to actually stop it.
- **Re-attach** — re-run `make menu` any time and it drops straight back into the
  live progress of a build already running — including one you started by hand
  (e.g. `sudo ./scripts/build-all-roles.sh …`).

No whiptail (e.g. inside the minimal Docker builder image, or a dumb terminal)?
It automatically falls back to a plain numbered-prompt menu (force it with
`NO_TUI=1`). Your last choices are remembered between runs.

A host-side Python twin, `python -m hugmesh_studio.tui` (the Studio parity TUI:
the guided journey — welcome screen, mode menu, Themes, create-nodes-for-local-cloud,
whole-mesh emulation, domains with per-domain Sign-in — plus `--sessions`
build-session review, `--worklist` table and `--meshemu` whole-mesh status
list), follows the same `NO_TUI` degradation rule;
its rich renderer is `dev-python/urwid` — ~arch on Gentoo, accepted with one line
(`echo "dev-python/urwid ~amd64" >> /etc/portage/package.accept_keywords/hugmesh-studio`)
— and entirely optional (see `studio/README.md`).

### 3·cli. Headless Studio faces — hardware scan + build-session history

Two Qt-free `python -m hugmesh_studio` faces close the last GUI-only gaps
(issue #49: everything the GUI can do must be a documented command). Each has a
`make` front (listed in `make help`); no display, no Qt binding needed:

```bash
make scan-hardware [JSON=1]      # = python -m hugmesh_studio --scan-hardware [--json]
    # probe THIS machine (CPU/GPUs/Wi-Fi/Bluetooth) and print the recommended
    # build settings — the same core scan the wizard's Hardware page runs
make sessions-list [JSON=1]      # = --list-sessions: one line per recorded build
    # session — id, date, roles, status, artifact count (newest first)
make sessions-show ID=… [JSON=1]        # = --show-session ID (full record)
make sessions-artifacts ID=… [JSON=1]   # = --session-artifacts ID
make sessions-delete ID=… YES=1 [ARTIFACTS=1]
    # = --delete-session ID --yes [--delete-artifacts] — REFUSES without YES=1,
    # never deletes an in-progress build, artifacts only on explicit ARTIFACTS=1
```

Full contract (exit codes, `--json` schemas): `studio/README.md` → "Two more
Qt-free headless faces".

### 3a. The roles

| Arch | Roles | Builder |
|---|---|---|
| **RPi5 (aarch64)** | `pki`, `backend`, `frontend` | `build-rpi5-stage4.sh --role <r>` |
| **x86_64 (amd64)** | `pki`, `backend`, `frontend`, `backend-gpu`, `omnibus` | `build-x86-host-stage4.sh --role <r>` |

Notes from the code:
- On x86, `be`=backend, `fe`=frontend; **`host` is an alias for `backend-gpu`** (the
  default x86 role, the GPU worker). `omnibus` is the opt-in all-namespaces-on-one
  node image.
- `build-all-roles.sh` builds **Pi `pki backend frontend` + x86 `pki backend frontend backend-gpu`**
  by default; the x86 `omnibus` is opt-in (`X86_OMNIBUS=1`, `X86_ALL=1`, or an
  explicit `X86_ROLES="…"`; `SKIP_X86=1` for Pi only).

### 3b. `make` (Docker builder)

```bash
make local                 # the LAN .test fleet: ENV=test + brands/local.conf (hugmesh.test)
make prod                  # the PROD fleet: ENV=prod, real domain (announced)

make build-all             # default fleet (3 Pi + x86 pki/backend/frontend/backend-gpu); ENV defaults to test
make rebuild               # wipe ./out first, then build the whole fleet
make rpi                   # all 3 Pi roles          make rpi-frontend    # one Pi role
make x86                   # the 4 x86 roles          make x86-backend-gpu      # one x86 role (also x86-pki, x86-omnibus)
make omnibus               # the opt-in x86 all-in-one node
```

Branding + ENV overrides thread through every target:

```bash
make build-all BRAND=acme DOMAIN=acme.example      # → --config brands/acme.conf --cluster-domain acme.example
make build-all ENV=prod BRAND=acme
make x86-backend-gpu IMG_FLAGS='--no-iso' JOBS=16        # img only, 16 jobs
make build-all NATIVE=1                              # run the scripts directly (local Gentoo / inside the builder)
```

Common `make` overrides: `ENV=test|prod`, `BRAND=`, `DOMAIN=`, `HEADSCALE_URL=`,
`WORK_DIR=`, `JOBS=`, `ROLE=`, `ARCH=x86|arm64`, `DEV=/dev/sdX`, `IMG_FLAGS=`,
`NATIVE=1`, `CA_CERT=`/`CA_KEY=`/`CA_KEY_PASS=`. `make help` lists every target.

> **Scratch space:** the heavy stage4 build wants tens of GB. Point `WORK_DIR=` at
> a roomy disk — e.g. a namespaced subdir of the portage scratch volume,
> `WORK_DIR=/var/tmp/portage/hugmesh-build` (its own subdir, so it never
> collides with portage's own per-package build dirs).

> **Hardened standalone NVIDIA desktops:** `make x86-standalone` (or `make menu` →
> Single role → x86 → standalone-thin/thick) builds the self-contained desktops —
> see [STANDALONE-DESKTOP.md](STANDALONE-DESKTOP.md).

### 3c. The scripts directly (native, root)

```bash
# all three Pi roles + the per-role keys folders, in one pass
sudo ./scripts/build-all-roles.sh -j "$(nproc)"

# …or one role at a time
sudo ./build-rpi5-stage4.sh --role pki -j "$(nproc)"           # Pi
sudo ./build-x86-host-stage4.sh --role backend-gpu -j "$(nproc)"    # x86 GPU host (native amd64 Gentoo)

# add ENV / brand / knobs (flags override the profile):
sudo ./build-rpi5-stage4.sh --role backend --env prod \
     --config brands/acme.conf --cluster-domain acme.example \
     --optional-services "akkoma games" --grow 32G
```

Pass-through args on `build-all-roles.sh` go to **both** builders, e.g.
`./scripts/build-all-roles.sh -j 16 --env prod --config brands/acme.conf`.

Full flag reference: `./build-rpi5-stage4.sh --help` and
`./build-x86-host-stage4.sh --help`. The most-used flags:

| Flag | Default | Notes |
|---|---|---|
| `-r, --role` | `generic` (Pi) / `backend-gpu` (x86) | sets hostname, services, GitOps payload |
| `--env test\|prod` | `test` | baked build ENV (see §2e) |
| `-C, --config FILE` | auto `./brand.conf` | source a brand profile |
| `--brand` / `--brand-title` / `--org` / `--cluster-domain` | profile/defaults | per-field rebrand overrides |
| `--optional-services "…"` | all four | prune optional services (see §2a) |
| `--games-domain` | `games.<domain>` | games host + OIDC issuer (see §2b) |
| `--grow fill\|none\|<size>` / `--no-grow` | `fill` | first-boot grow (see §2c) |
| `--img-size MiB` |9216 (Pi) / 8192 (x86) | compact ext4 root size |
| `-w, --work-dir` | `./out` | products dir |
| `-j, --jobs N` | `$(nproc)` | parallel emerge/make jobs |
| `--skip-mesh` / `--skip-tailscale` / `--skip-kernel` / `--skip-clean` / `--resume` | off | phases |
| `--enable-wifi` / `--enable-bluetooth` | **off** | WiFi + Bluetooth are **disabled by default** (rfkill block + blacklisted modules + no service); these re-enable them. Ethernet + the tailnet are unaffected. (env/brand.conf: `ENABLE_WIFI` / `ENABLE_BLUETOOTH`) |
| Pi: `--pcie-gen3`, `-c/--cpu`, `-d/--defconfig` | off / cortex-a76 / bcm2712 | board tuning |
| x86: `--installer-iso`, `--no-live-iso`, `--no-tar` | off / live ISO on / tar on | x86 artifacts |

> **Hardened radio defaults:** both builders disable **WiFi and Bluetooth** by
> default to shrink the attack surface — at first boot a `/etc/local.d` action
> `rfkill`-blocks both radios, their kernel modules are blacklisted
> (`/etc/modprobe.d/hugmesh-radio-blacklist.conf`), and no WiFi/Bluetooth
> service is enabled. **Ethernet + the Tailscale tailnet are never touched.**
> Re-enable per build with `--enable-wifi` / `--enable-bluetooth` (or
> `ENABLE_WIFI=true` / `ENABLE_BLUETOOTH=true` in `brand.conf`/env).

Artifacts are **brand- and UTC-timestamp-named** so test/prod runs never clobber:
`<brand>-<arch>-<role>-<env>-<UTC>.<ext>` (e.g.
`hugmesh-rpi5-arm64-frontend-test-20260610T193045Z.img`). The flash/QEMU
helpers autodetect the newest matching image, so you rarely type the full name.

### 3d. Frite light-desktop image (Libre Computer Le/La Frite)

An **opt-in, lean desktop client image** for the Amlogic arm64 **Libre Computer**
SBCs, built by `build-frite-stage4.sh`. It is **not** a cluster node and **not**
in the default fleet, but it reuses the same aarch64 cross path and the **same
mesh + KEYS-USB provisioning + hardened key-only SSH** as every other client
image — so a Frite **joins the same tailnet** and does **Casdoor login** exactly
like the Pi/x86 nodes, and honors the device-license SSH posture (no broad SSH).

```bash
make frite                                   # La Frite, BOTH live + installer (default)
make frite FRITE_BOARD=le-potato             # the pricier S905X sibling (has microSD)
make frite-live                              # LIVE image only        make frite-installer  # INSTALLER only
FRITE=1      ./scripts/build-all-roles.sh    # ALSO build the Frite alongside the fleet
FRITE_ONLY=1 ./scripts/build-all-roles.sh    # ONLY the Frite (skip Pi + x86)
# directly:
sudo ./build-frite-stage4.sh --board la-frite --flavor both
```

**Generation option — the knobs** (`brand.conf` or CLI; CLI wins):

| Knob | brand.conf / env | CLI flag | Values (default **bold**) |
|---|---|---|---|
| board variant | `FRITE_BOARD` | `--board` | **`la-frite`** (S805X) · `le-potato` (S905X) · `sweet-potato` (S905X-CC-V2) |
| live/installer | `FRITE_FLAVOR` | `--flavor` (`--live`/`--installer`) | **`both`** · `live` · `installer` |
| desktop set | — | `--desktop` | **`light`** (lean LXDE) · `none` (headless base) |
| prebuilt u-boot | `FRITE_UBOOT_URL` | `--uboot-url` | empty (provide a FIP-signed board image — see caveat) |
| (shared) | `--env`/`--brand`/`--cluster-domain`/`-H`/`-T`/`-u`/`--*-password`/`--skip-mesh`/`--enable-wifi`… | same as the other builders |

**Light desktop** = a lean **LXDE-class** stack (Openbox WM + LXpanel + PCManFM +
LightDM + a small browser), **not** the full Plasma + gaming stage4. The set
lives in `specs-frite/portage/packages-light-desktop.list`; the always-on base is
`specs-frite/portage/packages.list`. `--desktop none` ships the headless base.

**Board / boot-media reality:**

| Board | Board id | SoC | microSD? | LIVE root | INSTALLER target | u-boot |
|---|---|---|---|---|---|---|
| `la-frite` | AML-S805X-AC | S805X | **no** | **USB** | **eMMC** | SPI NOR (`libretech-ac`) |
| `le-potato` | AML-S905X-CC | S905X | yes | SD/USB | eMMC/SD | SD/eMMC (`libretech-cc`) |
| `sweet-potato` | AML-S905X-CC-V2 | S905X | yes | SD/USB | eMMC/SD | SD/eMMC/SPI (`libretech-cc-v2`) |

> **La Frite has NO microSD slot.** The LIVE image boots off **USB** (u-boot in
> **SPI NOR**); the INSTALLER (`install-frite.sh`) writes the desktop to the
> **eMMC** module. The **512 MB and 1 GB RAM SKUs are the SAME image** (RAM
> auto-detected; the 512 MB SKU leans on a zram swap configured at first boot).

**Flashing the Frite** (the artifacts are bootable ISO/live media — write with
`dd`, *not* `flash-disk.sh`, which is built for the partitioned Pi/x86 `.img`):

```bash
# LIVE off USB (La Frite has no SD):
sudo dd if=out/<brand>-frite-la-frite-arm64-desktop-test-<UTC>.live.iso of=/dev/sdX bs=4M status=progress conv=fsync
# INSTALLER: boot it off USB, then on the Frite run:
sudo install-frite.sh /dev/mmcblk0      # write the light desktop to the eMMC module
```

> **u-boot caveat (HONEST).** Amlogic GXL u-boot needs Amlogic's **proprietary
> FIP/BL31 blobs** to be flashable — mainline u-boot alone is not. The builder
> does **not** vendor those blobs (licensing). Provide a prebuilt, signed board
> image with `--uboot-url` (e.g. a [Tow-Boot](https://tow-boot.org) release for
> the board) and it is staged into the installer's `uboot/` for an optional SPI
> write; otherwise flash u-boot once with the vendor/Tow-Boot tooling and the
> images boot on top of it.

**VERIFIED here vs NEEDS REAL HARDWARE** (be honest about what was testable in CI
vs what needs a board + a full Gentoo cross-build):

- **VERIFIED (syntactic / structural):** `bash -n` on `build-frite-stage4.sh` +
  `install-frite.sh`; option/knob parsing and the board→DTB/defconfig/u-boot
  table; the `make frite*` targets and the `build-all-roles.sh` `FRITE=`/
  `FRITE_ONLY=` wiring; template rendering (extlinux/make.conf) with no leftover
  markers; that it reuses the shared `specs/` mesh + provisioning + sshd exactly
  like the Pi5 builder; that the **Pi5 and x86 paths are untouched** (additive).
- **NEEDS A REAL BOARD / FULL GENTOO BUILD:** the actual aarch64 cross-emerge of
  the LXDE stack; the mainline kernel build + the exact in-tree `meson-gxl-*.dtb`
  names for the chosen kernel; the u-boot FIP signing; booting the squashfs LIVE
  image off USB on a real La Frite; the eMMC install. These steps mirror the
  proven Pi5 flow but **cannot be end-to-end tested without the hardware.**

---

## 4. Generate cluster secrets

Cluster app secrets (Casdoor, ClickHouse, Uptrace, plus any mail/OAuth creds) are
produced once and delivered two ways: **online** to Vault (if `VAULT_ADDR` +
`VAULT_TOKEN` are set) and **always** as an offline USB bundle. Provisioning
prefers Vault first, USB fallback.

```bash
./scripts/gen-cluster-secrets.sh                 # writes keys-out/vault/{secrets.json,token}
# online too:
VAULT_ADDR=https://vault.acme.example VAULT_TOKEN=… ./scripts/gen-cluster-secrets.sh
```

`BRAND` / `CLUSTER_DOMAIN` / `VAULT_*` are read from `brand.conf`. The bundle is
picked up automatically when you build the KEYS stick (§6). To carry the optional
SMTP + GitHub/Discord OAuth creds, drop them where `gen-provision-keys.sh` writes
`keys-out/secrets/cluster-creds.json` (it is read here via `KEYS_FILE=`).

---

## 5. Generate per-node provisioning keys (`gen-provision-keys.sh`)

Each node boots and provisions itself from a FAT32 **KEYS** USB. Build one filled
KEYS directory per node from the template, generating an SSH keypair + SHA-512
password hashes and the JKS keystores/truststore.

```bash
# the control plane (FULL config + default user accounts + mTLS keystores)
./scripts/gen-provision-keys.sh -r pki -o keys-pki

# workers — KEYS ONLY (no users.json; break-glass root key + join material)
./scripts/gen-provision-keys.sh -r backend  -o keys-backend
./scripts/gen-provision-keys.sh -r frontend -o keys-frontend
./scripts/gen-provision-keys.sh -r host     -o keys-host
# an additional HA control-plane:
./scripts/gen-provision-keys.sh -r control-plane-additional -o keys-cp2
```

Roles: `pki | backend | frontend | host | control-plane-additional`. Options:

| Flag | Meaning |
|---|---|
| `-o, --out DIR` | output KEYS dir (default `keys-out`) |
| `-u, --admin NAME` | admin username (default `admin`) — the privileged login/SSH user (the superadmin on the primary images) |
| `--random` | random passwords instead of the 10s prompt — hashes are written to the KEYS config, NOT echoed in plaintext (use for non-interactive/CI) |
| `--root-password` | **also** generate a root password (default: NONE — root login is **LOCKED** on the image). When set it is stored salted+hashed in `users.json`, never printed. (env/brand.conf: `GEN_ROOT_PASSWORD=true`) |
| `--sudo-nopasswd` | make the privileged user's sudo NOPASSWD (default: sudo is **password-gated** by the device/superadmin password) |
| `--ca-cert` / `--ca-key` / `--ca-key-pass` | use an existing CA as the mTLS issuer (also seeds it as the kubeadm CA on the pki role) |
| `--keys-src DIR` | copy optional mail/OAuth creds from an existing KEYS tree |

> **Device-security hardening defaults** (key-gen + provisioning):
> - **Root password is OPT-IN.** By default no root password is generated and
>   `provision.sh` runs `passwd -l root` — root login is locked. Opt in with
>   `--root-password` / `GEN_ROOT_PASSWORD=true`. Passwords are **never** echoed
>   in plaintext (only salted+hashed in the KEYS `users.json`).
> - **The privileged user has sudo** — with root locked, sudo is the
>   superadmin/admin's escalation path. It is **password-gated** by default
>   (`--sudo-nopasswd` to relax). `provision.sh` writes `/etc/sudoers.d/10-<user>`.
> - **SSH over Tailscale, privileged-user-only.** gen-keys writes
>   `keys-<role>/ssh/<admin>_ed25519` — the **private** key stays on the KEYS USB
>   (off-image, gitignored via `*_ed25519`); its **public** key is baked into the
>   privileged user's `authorized_keys`. `tailscale up --ssh` + the headscale SSH
>   ACL (`headscale/policy.hujson`, scoped to `tailscale.ssh_user`) admit **only**
>   that user over the tailnet — root + others are denied. SSH in with
>   `ssh -i keys-<role>/ssh/<admin>_ed25519 <admin>@<tailnet-ip>`.

What each role gets:
- **pki** — `users.json` (the privileged admin/superadmin user, hashed + sudo;
  root **locked** unless `--root-password`), full `provision.json`, the
  per-service JKS keystores + `truststore.jks`, `certs/cluster-ca.{crt,key}`, and
  the optional `secrets/{mail.json,cluster-creds.json}`. Mail/OAuth prompts have a
  10s timeout; empty = disabled (`--random`/`NONINTERACTIVE=1` skips them).
- **workers** — no `users.json` (default accounts live only on the pki stick).
  Copy the cluster CA + truststore from the pki output onto each worker stick:
  `certs/cluster-ca.crt` and `keystores/truststore.jks`, and fill in the kubeadm
  join token + ca-cert-hash + the mesh authkey.

> Secret custody (NEVER in git): Vault `vault/token` + `vault/unseal-key`, the LUKS
> keyfile `secrets/luks.key`, and the cluster CA private key all ride only on the
> KEYS USB / Vault. See [`keys-template/`](../keys-template/),
> [`keys-template/vault/`](../keys-template/vault/),
> [`docs/ENCRYPTION-AT-REST.md`](ENCRYPTION-AT-REST.md).

Review `keys-<role>/provision.json` before writing the stick — it carries the
hostname, mesh endpoint, kubeadm role (`control-plane`/`worker`, `bootstrap`,
`first`), node inventory, storage/LUKS, backups, and the `hugmesh.gitops`
toggle. Schema + examples: [`keys-template/README.md`](../keys-template/README.md).

> The `build-all-roles.sh` run in §3c already generates `keys-pki`/`keys-backend`/
> `keys-frontend` in the work dir with `--random` (skip with `SKIP_KEYS=1`); re-run
> `gen-provision-keys.sh` by hand if you want interactive passwords or a host stick.

---

## 6. Write the KEYS USB (`make-keys-usb.sh`)

Format a USB as a single FAT32 partition labelled `KEYS` and copy a keys dir onto
it. **One stick per node.** Requires root (it partitions/formats a block device).

```bash
sudo ./scripts/make-keys-usb.sh /dev/sdY keys-pki          # format + copy
sudo ./scripts/make-keys-usb.sh /dev/sdY keys-backend
# update an existing stick without reformatting:
sudo ./scripts/make-keys-usb.sh --no-format /dev/sdY keys-pki
```

Pass the **whole disk** (`/dev/sdY`), not a partition; it prompts for a typed
confirmation before destroying it (`--label` changes the volume label). FAT can't
hold unix perms — provisioning re-applies them at boot, and READMEs are dropped.

---

## 7. Flash the OS + boot

### 7a. Flash with `flash-disk.sh` (or `make flash`)

`flash-disk.sh` writes a built OS artifact (`.img` preferred, `.iso` fallback)
whole-disk to the target. Arg-parsing, auto-detect and `--list` work **without
root**; only the destructive write needs root.

```bash
# see what would be flashed (no root):
./scripts/flash-disk.sh --role pki --arch arm64 --list

# auto-pick the newest pki .img and flash it
sudo ./scripts/flash-disk.sh --role pki --arch arm64 /dev/sda

# x86 host image to NVMe, no prompt
sudo ./scripts/flash-disk.sh --role backend-gpu --arch x86 --no-confirm /dev/nvme0n1

# also write a separate KEYS stick in the same run (different device!)
sudo ./scripts/flash-disk.sh --role backend --arch arm64 \
     --with-keys keys-backend --keys-dev /dev/sdb /dev/sda
```

Flags: `--role pki|backend|frontend|host|be|fe|omnibus` (`be`=backend,
`fe`=frontend), `--arch arm64|x86`, `--work-dir DIR`, `--artifact FILE` (skip
auto-pick), `--with-keys DIR` + `--keys-dev DEV`, `--no-confirm`, `--list`. The
`.img` is self-partitioning (PARTUUID root) and growroot expands the root to fill
the disk on first boot — one image boots from SD / USB / NVMe unchanged.

Via `make`: `make flash DEV=/dev/sdX ROLE=frontend ARCH=arm64`.

### 7b. Manual flash from the ISO (alternative)

If you built ISOs instead of `.img`:

```bash
# RPi5: loop-mount the role ISO and run the bundled installer
sudo mount -o loop out/hugmesh-rpi5-arm64-pki-*.iso /mnt/iso
sudo /mnt/iso/install.sh /dev/sdX           # SD card, or /dev/nvme0n1
sudo umount /mnt/iso

# x86: boot the live ISO (out/…-x86-amd64-*.iso) and run install-x86.sh /dev/sdX from it
```

### 7c. Boot — first-boot self-provisioning

Insert each node's KEYS stick and power on. The `keys-provision` service finds the
FAT32 `KEYS` partition, mounts it read-only, and applies (all optional): users,
SSH host keys + authorized_keys, hostname/timezone/Wi-Fi, certificates/files,
headscale+tailscale, the Kubernetes PKI + kubeadm init/join, attached
storage (LUKS), backups, and — on the pki node — the GitOps bootstrap. With no
KEYS stick the image still boots and creates the fallback console user, so you are
never locked out.

### 7d. Operator logins after boot

- **Node / SSH** — log in over SSH with the key from the KEYS stick
  (`ssh -i keys-pki/ssh/admin_ed25519 admin@<node>`); login is key-only. The
  console fallback user (`DEFAULT_USER`/`DEFAULT_USER_PASS`, `ROOT_PASS` from
  `brand.conf`) exists only when no KEYS stick is present.
- **ArgoCD** — the GitOps engine, over the VPN: get the initial admin password
  with the command in §8.
- **Casdoor (the platform identity admin)** — seeded from `ADMIN_EMAILS`
  (`brand.conf`); that account is the Casdoor admin and is on the BFF allowlist.
  With no OAuth/SMTP it uses native user/pass + admin-approval registration.

> Platform-level account model (superadmin → admin → mod → user, per-domain
> scoping, MFA) is enforced by the Casdoor seed data + the gateways/BFFs at
> runtime — it is **not** a generator build knob. The generator's job ends at
> seeding the `ADMIN_EMAILS` admin and shipping the GitOps payload; the role
> cascade is configured in the cluster manifests / app layer. See
> [`docs/ARCHITECTURE.md`](ARCHITECTURE.md) and the platform docs.

---

## 8. Bring up the cluster

Boot the **pki** node first — it is the Kubernetes control plane. If its KEYS
`provision.json` sets `hugmesh.gitops.enabled=true`, `keys-provision` runs
`kubeadm init` + the GitOps bootstrap automatically. Otherwise do it by hand:

```bash
# On the pki node, after kubeadm init:
export KUBECONFIG=/etc/kubernetes/admin.conf
sudo -E /var/lib/hugmesh/cluster/bootstrap/bootstrap.sh   # ArgoCD + the root app-of-apps

# backend / frontend / x86-host nodes join automatically at first boot
# (the kubeadm join token rides on their KEYS stick), or:
#   kubeadm join <pki>:6443 --token … --discovery-token-ca-cert-hash …

# watch ArgoCD converge the platform
kubectl -n devops get applications
kubectl get pods -A

# ArgoCD admin password:
kubectl -n devops get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

For an `ENV=test` LAN fleet, do the **one-time resolver step**: point your router
DHCP DNS (or one client) at the backend/ingress node `:53` so every device
resolves `*.<domain>` → the cluster. Full walkthrough:
[`docs/LOCAL-TESTING.md`](LOCAL-TESTING.md).

---

## 9. Per-arch quick recipes

### 9a. RPi5 (aarch64) — three Pis

```bash
# 1. build
make rpi                                      # or: sudo ./scripts/build-all-roles.sh SKIP_X86=1
# 2. secrets + keys
./scripts/gen-cluster-secrets.sh
./scripts/gen-provision-keys.sh -r pki      -o keys-pki
./scripts/gen-provision-keys.sh -r backend  -o keys-backend
./scripts/gen-provision-keys.sh -r frontend -o keys-frontend
# 3. KEYS sticks (one per node)
sudo ./scripts/make-keys-usb.sh /dev/sdY keys-pki        # repeat per node/stick
# 4. flash each SD/NVMe
sudo ./scripts/flash-disk.sh --role pki --arch arm64 /dev/sda
# 5. insert the matching KEYS stick, boot pki first, then the workers
```

Board tuning if you are not on a Pi 5: `-c cortex-a72 -d bcm2711_defconfig
--dtb-prefix bcm2711 --kernel-img kernel8.img` (RPi 4). `--pcie-gen3` forces
NVMe Gen 3 (test your drive first).

### 9b. x86_64 (amd64) — the GPU host / omnibus

```bash
# build the default GPU worker (host = backend-gpu)
make x86-backend-gpu                               # or: sudo ./build-x86-host-stage4.sh --role backend-gpu
# or the all-in-one single node:
make omnibus                                  # or: sudo ./build-x86-host-stage4.sh --role omnibus
# keys for an x86 worker use the matching gen-provision-keys role:
./scripts/gen-provision-keys.sh -r host -o keys-host         # backend-gpu worker
./scripts/gen-provision-keys.sh -r pki  -o keys-omnibus      # omnibus = single-node control plane
# flash + KEYS as above with --arch x86; the x86 .img is a UEFI GPT disk (ESP + ext4 root)
sudo ./scripts/flash-disk.sh --role backend-gpu --arch x86 /dev/nvme0n1
```

---

## 10. Validate before flashing (optional)

```bash
# QEMU integration test — boots a built image with a synthetic KEYS disk
sudo ./tests/qemu/run-qemu-test.sh --role pki
make qemu-rpi ROLE=frontend          # or qemu-x86 ROLE=backend-gpu

# first-boot provisioning emulation (no block device, no kernel boot)
./tests/boot/emulate-firstboot.sh                 # all four roles
./tests/boot/emulate-firstboot.sh pki backend     # specific roles
```

See the README's [QEMU](../README.md#qemu-integration-test) and
[Integration tests](../README.md#integration-tests-ui-e2e--boot-emulation)
sections.

---

## 11. CI (GitLab) and the org mirror

The image/ISO pipeline runs on **GitLab**, not GitHub Actions — because it needs the
privileged in-cluster runner, not because Actions is unavailable. (This document used
to say Actions was billing-blocked org-wide and that `.github/workflows` must not be
added; that is stale — Actions is enabled, and two narrow Studio workflows now live in
`.github/workflows/`. See the CI note in the README.) `.gitlab-ci.yml` runs on a privileged x86
runner: it builds the role ISOs + container images and delivers the ISOs as
generic-package release assets for the admin UI's download links. ISOs carry **no
keys** — KEYS material always comes from the USB at first boot.

```bash
# mirror every hugmesh GitHub repo into the internal GitLab (admin/CI):
GITLAB_TOKEN=… ./scripts/gitlab-mirror-org.sh
```

`gitlab-mirror-org.sh` creates a pull-mirror per repo (`mirror_trigger_builds=true`),
so CI builds from a complete in-VPN copy. See [`docs/DEVOPS.md`](DEVOPS.md).

---

## Troubleshooting quick hits

- **x86 build sits at ~0.5 % CPU, the package counter is frozen, the log stopped
  mid-line** → a distfile fetch is stalled (`ls -l <sysroot>/var/cache/distfiles/*.__download__`
  twice, 30 s apart: same size = wedged). The x86 spec bounds fetches to >= 10 KiB/s over
  60 s with curl's own retries, so this now resolves itself in minutes ([`SHARED-BINPKG.md`
  § Distfiles](SHARED-BINPKG.md#distfiles)); if it recurs, **never `rm` the `.__download__`**
  — portage has already respawned a fetcher onto that name and the deleted inode swallows
  the download. Kill the fetcher, or place a digest-verified file under the FINAL name.
- **`make` can't find the builder image** → `make docker-image` (LONG first run).
- **`build-rpi5-stage4.sh` fails early** → it must run as **root** with a built
  `crossdev aarch64-unknown-linux-gnu` toolchain (§0b). Use `--resume` to reuse a
  populated sysroot after a failure.
- **No artifact to flash** → `./scripts/flash-disk.sh --role <r> --arch <a> --list`
  shows the candidates and the resolved work dir; check `--arch`/`--role` and that
  the build wrote to that `--work-dir`.
- **Worker won't join** → confirm the kubeadm join token + ca-cert-hash in its
  `provision.json` are current, and that `certs/cluster-ca.crt` +
  `keystores/truststore.jks` were copied from the pki output onto its stick.
- **LAN clients can't resolve `*.<domain>`** → do the one-time resolver step
  (point DNS at the backend node `:53`); [`docs/LOCAL-TESTING.md`](LOCAL-TESTING.md).
- **Mail/OAuth not working** → they are absent by default; supply real creds via
  the KEYS USB / env and re-run `gen-cluster-secrets.sh`. Empty creds = native
  login + admin-approval, by design.

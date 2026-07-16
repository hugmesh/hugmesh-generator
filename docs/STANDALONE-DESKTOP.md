# Hardened standalone NVIDIA desktop images

The generator can build **self-contained hardened desktop** images that are NOT
mesh clients and NOT cluster nodes: no Tailscale/headscale, no Casdoor/OIDC SSO,
no Kubernetes/ArgoCD. A **normal local user** logs in at the lightdm greeter with
a password set at build time, the **installed system is LUKS2 full-disk
encrypted**, and an optional **separate data disk** (Steam library + a gocryptfs
Vaults store) is auto-detected and mounted at `/media`.

Three named variants:

| Role | Weight | Desktop | Default GPU |
|------|--------|---------|-------------|
| `standalone-thin`  | thin | LXDE / openbox | NVIDIA proprietary |
| `standalone-thick` | full | **most-capable KDE Plasma workstation** | NVIDIA proprietary |
| `standalone-unaffiliated` | full (thick) | KDE Plasma — **ZERO Snapdragon affiliation** (see below) | free / open (`all-free`) |

Each variant emits **all four artifacts**: a live ISO, the stage4 tarball, the
`.fs.tar.xz` filesystem tarball, and an **installer ISO** (which writes a
LUKS2-encrypted system to disk).

## Unaffiliated plain desktop (`standalone-unaffiliated`)

A **plain hardened Gentoo desktop with ZERO Snapdragon affiliation** — the
thick/Plasma weight of the standalone posture, with every trace of the platform
removed or neutralized. Nothing in the image names, brands, or phones home to
Snapdragon:

- **Neutral boot chain**: `GENTOO_LIVE` / `GENTOO_INSTALL` ISO volids,
  `gentoo.efi` UKI (with a `gentoo.install=` cmdline key), `GENTOO_ESP` /
  `GENTOO_ROOT` partition labels, neutral GRUB titles and Secure Boot cert
  subject ("Gentoo Linux").
- **Neutral installer / hostname / artifacts**: neutral installer UI text, a
  "Gentoo Installer" desktop entry, default hostname `gentoo-desktop`, and
  artifact filenames `gentoo-x86-amd64-standalone-unaffiliated-<env>-<ts>.*`.
- **No `snapdragon-*` tools or markers** (no `/etc/snapdragon` tree at all),
  **no bundled generator source**, **no k8s/mesh payload** (no
  containerd/kubelet/headscale/tailscale, no cluster GitOps tree, no
  keys-provision, no Casdoor SSO).

### Quick start

```sh
make x86-standalone-unaffiliated STANDALONE_FLAGS='--local-user alice --local-pass s3cret'
```

The role **presets everything** — combine it only with generic options
(`--local-user` / `--local-pass`, `--gpu-driver`, `--encrypt-root` + the
keyfile/YubiKey unlock factors, `--compress`, `--resume`, …).

### Composable: `--unaffiliated` on any client role

The posture is also an orthogonal flag: `--unaffiliated` folds onto any
desktop/client role (`laptop` / `chromebook` / `desktop` / `standalone-*`) and
forces the standalone posture plus the neutral identity. It is refused on
cluster-node roles (a cluster node is Snapdragon platform machinery by
definition).

### Hard conflicts (builder exits non-zero)

Unaffiliated means *no affiliation at all* — every flag that would bake a brand
identity, brand assets, Snapdragon source, or platform machinery into the image
is a **hard error**, not a silent override:

- **Brand identity**: `--brand` / `--brand-title` / `--org` — there is no brand,
  not even an explicit `--brand gentoo`; the builder forces the neutral
  identity itself.
- **Branding assets**: `--theme`, `--branding-dir`, `--wallpaper`,
  `--grub-background`, `--grub-theme`, `--login-background`, `--brand-logo`,
  `--accent-color`, `--color-scheme`, `--brand-locked`.
- **Platform machinery**: `--bundle-source`, `--home-seed-code`,
  `--with-tailscale`, `--with-sso`, `--person-role` / `--domains`.

### What survives, under neutral names

The functional (non-affiliating) machinery is kept — renamed so nothing on the
image says "snapdragon":

| Snapdragon builds | Unaffiliated build |
|---|---|
| `snapdragon-home-setup` + `/etc/snapdragon/home.conf` | `home-setup` + `/etc/gentoo/home.conf` (same create/adopt/archive/restore + eCryptfs machinery) |
| `snapdragon-media-detect` (default ON) | `media-detect` + `/etc/gentoo/media.conf` — **default OFF**; kept only with an explicit `--media-data` |
| `snapdragon-installer-autostart` / `snapdragon-calamares-install` | `gentoo-installer-autostart` / `gentoo-calamares-install` (same live-session Calamares/ncurses/CLI installer bridge) |
| LUKS2 FDE installer | unchanged — same installer, neutral UI text |
| `SNAPDRAGON_LIVE` / `SNAPDRAGON_INSTALL` volids | `GENTOO_LIVE` / `GENTOO_INSTALL` |
| `snapdragon.efi` UKI + `snapdragon.install=` cmdline key | `gentoo.efi` + `gentoo.install=` |

Everything below this section (GPU drivers, local user, FDE + unlock factors,
Secure Boot, home provisioning, `--kernel-builtin`, QEMU verification) applies
to the unaffiliated variant too, except where a flag is listed as a hard
conflict above.

**Verifying the neutrality guarantee.** [`scripts/verify-artifact-neutrality.sh`](../scripts/verify-artifact-neutrality.sh)
is a standalone, manually-run gate that checks a build-output directory (live
ISO, installer ISO, disk image, fs/stage4 tarballs, and the extracted sysroot)
against every property claimed above — neutral volids/labels/GRUB titles, no
`/etc/snapdragon` marker tree or bundled generator source, no k8s/mesh payload,
and an attributed raw-string sweep (Qualcomm Snapdragon driver strings in
kernel/firmware are expected and not a failure). Run it against the artifacts
produced by `make x86-standalone-unaffiliated`; see the script's own `--help`
for options.

## Quick start

```sh
# Build both variants (Docker builder; products land in ./out):
make x86-standalone STANDALONE_FLAGS='--local-user alice --local-pass s3cret'

# One variant, native build, custom options:
make x86-standalone-thick NATIVE=1 \
  STANDALONE_FLAGS='--local-user alice --local-pass s3cret --nvidia-driver proprietary --nvidia-cuda'

# Or drive it from the ncurses menu (collects user/password/NVIDIA/Steam/factors):
make menu      # → Single role → x86 → ★ standalone-thin / standalone-thick
```

The ncurses menu and the Studio GUI expose the **full option set** of this page —
not just the highlights (the all-options-in-all-menus rule,
[BUILD-MATRIX.md](BUILD-MATRIX.md)): GPU/Steam/media (`--media-label` too),
local user + never-persisted passwords, keyfile/YubiKey unlock factors, the
branding theme **plus the per-piece overrides** (wallpaper / GRUB + login
backgrounds / logo / accent / color scheme), home provisioning
(create/adopt/archive/restore + eCryptfs + seed-code), the installer front-ends
(`--installer-ui`), proxy/Snort/AIDE/`--kernel-builtin`/egress-VPN — and an
**extra-builder-flags escape hatch** so any remaining CLI flag stays reachable
without dropping to the shell.

One menu default to know about: **branded** standalone builds from the ncurses
menu start with `--theme boogiepop` preselected (the persisted `OPT_SA_THEME`
default in `scripts/build-menu.sh`; pick **None** under "Branding theme" for
the stock look), while the `standalone-unaffiliated` entry suppresses all
theming (`--theme` is a hard conflict there, so the menu hides the option and
never emits its persisted default). Direct `make` / CLI builds apply no theme
unless you pass one — see the Desktop branding section below.

Use the big scratch disk for the heavy build (namespaced; never touches portage's
own dirs):

```sh
make x86-standalone WORK_DIR=/var/tmp/portage/snapdragon-build NATIVE=1
```

## What each piece does

### GPU driver — all common cards, FREE drivers by default
`--gpu-driver VALUE` selects the GPU stack. **FREE (open) drivers are the default**
(no EULA, hardened). Only **NVIDIA** has a proprietary *display* driver; AMD/Intel
use the open display driver, and their "pro" options add the vendor's
proprietary/closed **compute + Vulkan** stack on top.

| `--gpu-driver` | VIDEO_CARDS | adds |
|---|---|---|
| `all-free` *(default)* | amdgpu radeonsi intel iris nouveau | — (any GPU; NVIDIA = nouveau) |
| `nvidia-free` | nouveau | — |
| `nvidia` | nouveau nvidia | `x11-drivers/nvidia-drivers` (NVIDIA-r2 EULA); nouveau blacklisted; `--nvidia-cuda` adds CUDA |
| `amd-free` (alias `ati-free`) | amdgpu radeonsi radeon | — |
| `amd-pro` | amdgpu radeonsi | `amdgpu-pro-vulkan` + `amdgpu-pro-opencl` + AMF (AMD-GPU-PRO-EULA) |
| `intel-free` | intel iris | — |
| `intel-pro` | intel iris | `intel-compute-runtime` + iHD media driver + `vpl-gpu-rt` |
| `none` | — | headless |

`--nvidia` is shorthand for `--gpu-driver nvidia`. Each vendor's proprietary
licence is accepted only for that build (`package.license/{nvidia,amd-pro}`).

### E-ink / e-paper displays
Client desktops also bake the mainline e-ink display drivers as kernel **modules**
(`kernel/eink.config`): `DRM_REPAPER` (Pervasive Displays), `FB_METRONOME`,
`FB_BROADSHEET`, `FB_AUO_K190X` — they cost nothing until an e-ink panel is attached.

### Local user with a password (no SSO)
`--local-user NAME` + `--local-pass PASS` create a normal user. The password is
hashed at build time (yescrypt `$y$` where the build host's libcrypt supports
it, SHA-512 crypt `$6$` fallback) — **the plaintext is never baked**.
With no `--local-pass`, a random one-time password is minted at first boot and
printed once to the console. `wheel` is the sudo path. `--skip-sso` removes the
Casdoor/OIDC desktop login from any client image (auto-on for standalone).

### LUKS2 full-disk encryption (installed system)
The **installer prompts for a system root-unlock passphrase** (distinct from the
login password) and LUKS2-encrypts the target root; it is entered on the target
and never baked into any artifact. Layout: an unencrypted ESP at `/boot` (so a
**single** passphrase unlocks at the initramfs) + a LUKS2 container for root.
`--luks-pass PASS` is an optional unattended convenience (written 0600 into the
installer tree only — loudly warned). Live ISO / `.img` / `.fs.tar.xz` stay
plaintext (they are ephemeral / flashed); FDE is applied at **install**.

### Optional keyfile / YubiKey unlock factor
- `--unlock-keyfile boot` — generate a keyfile added as a second LUKS keyslot
  (kept on the ESP; a copy is saved to `WORK_DIR` to stash on a KEYS USB).
- `--unlock-yubikey boot` — the installer enrolls a FIDO2 LUKS keyslot
  (`systemd-cryptenroll`; the key must be present at install).
- `…  login` — wires a PAM login factor (`pam_u2f` for YubiKey); enrollment
  (`pamu2fcfg`) runs at first login since the device must be present.

### Secure Boot + KEYS USB
Secure Boot is on by default (signed UKI + Microsoft shim). Point the build at the
host's existing signing key so the reinstalled machine boots under the key already
enrolled in its firmware:

```sh
--keys-usb '/run/media/you/USB'      # uses USB/Keys/kernel_key.{pem,der}
# or explicitly:
--secureboot-key KEY.pem --secureboot-cert CERT.der
```

### External media data device (Vaults + Steam) — default ON, optional
A **separate** data disk (kept across reinstalls) holds `Steam/` and a gocryptfs
`Vaults/` under `/media`. The installed system runs `snapdragon-media-detect` at
every boot, which finds that disk by LABEL (`--media-label`) or by scanning
attached non-root partitions for the marker dirs, mounts it at `/media` (nofail),
installs `gocryptfs` for the vault, and points Steam's library at `/media/Steam`.
The installer **refuses to erase** a target that carries the Steam/Vaults markers,
so a reinstall on the same host never wipes the data disk. Disable with
`--no-media-data`.

**Steam delivery** (`--steam`): the default is **`native`** —
`games-util/steam-launcher` from the steam-overlay, built with multilib
(`ABI_X86="64 32"`) and baked into the *gaming* desktops (standalone variants + the
full `desktop` role; the lean mesh laptop/chromebook clients are left out).
`~/.local/share/Steam` is symlinked to `/media/Steam` so the install/library lives
on the data disk. The build enables + syncs the steam-overlay in the chroot via
`eselect repository` (needs network; non-fatal — if it can't sync, rebuild with
`--steam flatpak`). `--steam flatpak` uses `com.valvesoftware.Steam` instead;
`--steam none` skips Steam.

### Seed from the running system + bake a home directory
```sh
# "copy all installed programs" from this Gentoo box into a package list:
scripts/seed-packages-from-running-system.sh --output seed.list
make x86-standalone-thick STANDALONE_FLAGS='--seed-packages-from seed.list'

# bundle your $HOME, unpacked into ONLY the new user's home at install:
scripts/archive-home.sh --user "$USER" --output home.tar.xz
make x86-standalone-thick STANDALONE_FLAGS='--include-home-archive home.tar.xz'
```

## Composability
The posture is also available as orthogonal flags on the `laptop`/`chromebook`/
`desktop` client roles, e.g.:

```sh
./build-x86-host-stage4.sh --role desktop --standalone --skip-sso \
  --nvidia-driver proprietary --encrypt-root --capable \
  --local-user alice --local-pass s3cret --installer-iso --live-iso
```

See `build-x86-host-stage4.sh --help` for the full flag list.

## ARM platforms (Frite, Raspberry Pi 5/4/3, Jetson, Orange Pi 5, Orange Pi Zero 2)

`--standalone`/`--local-user`/`--local-pass`/`--encrypt-root` are **not x86-only**
— every ARM builder **except Jetson** (see below) composes them onto its own
desktop-shaped role the same way x86 does, via `--role desktop --standalone`:

```sh
./build-frite-stage4.sh    --board la-frite --standalone --encrypt-root \
  --local-user alice --local-pass s3cret --flavor both
./build-rpi5-stage4.sh     --role desktop --standalone --encrypt-root \
  --local-user alice --local-pass s3cret                # add --board rpi4 | rpi3
./build-orangepi5-stage4.sh --board orange-pi-5-plus --standalone --encrypt-root \
  --local-user alice --local-pass s3cret --flavor both
```

`--standalone` cascades `SKIP_MESH=true SKIP_TAILSCALE=true` on every platform,
exactly like x86 — no mesh/tailnet/Casdoor SSO dependency either way.

### LUKS2 install model: cross-host vs. on-device

Two genuinely different install stories, both real, both correct for their
hardware:

| Platform | Format happens on | Unlock happens on | PBKDF cost pinned? |
|---|---|---|---|
| x86 | the target itself (installer boots on it) | same | no |
| Frite | the target itself (live→installer flow) | same | **no** |
| Orange Pi 5 / 5 Plus | the target itself (live→installer flow) | same | **no** |
| Orange Pi Zero 2 | the target itself (live→installer flow) | same | **no** |
| RPi5 (rpi5/rpi4/rpi3 boards) | a **build/dev host**, writing the SD card/eMMC | **the Pi**, a different machine | **yes** — `--pbkdf-memory 262144 --iter-time 2000 --pbkdf-parallel 4` |
| Jetson Orin | n/a — **`--encrypt-root` is blocked outright**, see below | n/a | n/a |

The rule: `cryptsetup luksFormat`'s `argon2id` cost auto-benchmark measures
*the machine running the format*. When that's also the machine that will
later unlock the disk (Frite/Orange Pi 5/Orange Pi Zero 2's on-device
live-then-install flow), the benchmark is trustworthy and pinning it would
only make first-unlock slower for no security benefit. When format and unlock
happen on **different** hardware (RPi5's installer runs on a dev host writing
media the Pi itself will later boot), an unpinned benchmark tunes the KDF cost
to the *wrong* machine — so RPi5 pins fixed, cross-platform-safe cost
parameters instead.

### Jetson: `--encrypt-root` is BLOCKED — a confirmed boot-chain break, not a deferred gap

Unlike every other platform, Jetson has **no live/installer split at all**
AND **no separate boot partition** — `build_img()` writes a single ext4
partition (`JETSON_ROOT`) that holds the *entire* filesystem, including
`/boot/extlinux/extlinux.conf`. The Orin's NVIDIA UEFI (`L4TLauncher`)
distro-boots that file by reading it directly off the raw partition, before
Linux or dracut ever run (`specs-jetson/boot/README.md`). LUKS2-encrypting
that single partition would make the firmware unable to parse a filesystem
there at all — it could never even locate a kernel to boot, regardless of
how correct the rest of the LUKS/dracut plumbing is. Every other platform in
this repo (RPi5/Frite/Orange Pi 5/Orange Pi Zero 2) avoids exactly this by
keeping an **unencrypted** boot partition split from the LUKS2 root.

This is a confirmed architectural fact (verified against this platform's own
boot documentation), not a hardware-unverified risk — so `build-jetson-stage4.sh`
hard-blocks `--encrypt-root` (and, by extension, `--standalone`, which forces
`--encrypt-root` on) with a clear error rather than silently producing an
image that cannot boot. Fixing this for real needs a separate unencrypted
boot partition (mirroring RPi5's split) — a distinct, larger undertaking of
its own, deliberately **not** attempted here. Until that lands, Jetson has
**no standalone/LUKS story at all** (on top of its pre-existing, separately
deferred no-live/installer-split gap).

### Orange Pi Zero 2: headless, so no lightdm/desktop session

Orange Pi Zero 2's `--standalone` composes onto its **`appliance`** role, not a
`desktop` role — this platform has no GPU-driven display path at all (the
Allwinner H616's display engine has no mainline kernel driver), so "local
user, no mesh" here means an SSH/console login on a headless box, not a
graphical greeter. Every other guarantee (LUKS2 FDE, local user + hashed
password, no mesh/SSO) still applies identically.

Because this is the only standalone-capable platform with **no GUI console at
all**, `--standalone` also writes a `00-standalone-password-auth.conf` sshd
drop-in that re-enables `PasswordAuthentication` for the local (non-root)
user — standalone mode has no mesh, so there is no KEYS-USB
`authorized_keys` distribution to provision an SSH key instead, and without
this override the local user's password would be unusable for login by any
means short of a physical serial-console cable. Root SSH login is
unaffected — it stays governed by `--permit-root-login`/`00-root-login.conf`
exactly as on every other platform.

### RPi 3: desktop-only board

`--board rpi3` on `build-rpi5-stage4.sh` **only** accepts `--role desktop` (1 GB
RAM has no headroom for the k8s cluster-node stack) — the builder hard-errors
on every other role for that board. This makes `--standalone` on Pi 3 a very
natural fit: the desktop role is the *only* role it builds, and standalone is
the desktop role's most complete configuration.

See each platform's own `--help` (or `specs-<platform>/README.md` for the
EXPERIMENTAL ones — Jetson, Orange Pi 5, Orange Pi Zero 2) for its full flag
list; the composability contract above is identical to x86's.

## Home directory provisioning

| `--home-mode` | What happens at install |
|---|---|
| `create`  | Fresh home for the local user (default when no archive). |
| `adopt`   | **Use an existing home already on a disk/USB in place** — the installer mounts `--home-device LABEL=…\|UUID=…\|/dev/…` at `/home` and **never formats it**, so an existing eCryptfs `.Private` survives (this host's separate `/home` partition, or a USB). |
| `archive` | Unpack a bundled `$HOME` tarball (`--include-home-archive`) — good for a laptop with no data disk. |
| `restore` | Decrypt + unpack an **encrypted full-home backup** (`--home-backup FILE\|auto`; `auto` scans attached USBs). |

- `--home-encrypted` layers **per-user eCryptfs on top of the LUKS2 root** (login-password unwrapped) — the same double-layer this build host uses. Adds the kernel `ecryptfs.config` + `ecryptfs-utils` + wires `pam_ecryptfs`.
- **Encrypted backup to a USB:** `scripts/archive-home.sh --user me --full --encrypt --output /run/media/USB/snapdragon-home-backup-me.tar.xz` (gpg AES256 / openssl). `--full` keeps your documents/media (drops only build/cache cruft); `--config-only` is the lean copy for bundling inside an ISO. Restore later with `--home-mode restore --home-backup auto`.

## Dockerized stack / mesh node in the home

`--home-seed-code repos|stack|mesh` drops the whole Snapdragon source + a
`docker-compose` runner into `~/snapdragon-stack`, so the box can run the entire
stack locally (`stack`) or join a tailnet as a dockerized mesh node (`mesh`):
`cd ~/snapdragon-stack && ./snapdragon-stack up` (or `mesh-up`).

## Mesh / SSO toggles, distfiles, live ISO

- `--with/--no-tailscale`, `--with/--no-sso` — force the tailnet agent / Casdoor login ON/OFF on any role.
- `--distdir DIR` (or auto-detect `/media/*`) — reuse a Gentoo distfiles cache from a mounted drive (read-only-USB safe) to skip re-downloads / build offline.
- `--live-toram` (default) — live ISO gets a **Copy to RAM (removable)** boot entry so the stick can be pulled after boot.

## Installers (live-ISO boot entries)

`--installer-ui cli|ncurses|calamares|all` (standalone defaults to `all`):
graphical **Calamares** (Qt; Ubuntu-style), **text/ncurses** (`install-x86.sh --interactive`),
and **unattended CLI** (`install-x86.sh --unattended`, reads the baked manifest).
`--cached` embeds the binpkg cache for **offline rebuild / fast reinstall**; `--uncached`
(default) is lean. `--bundle-source` (standalone default) ships the generator source +
`snapdragon-regenerate`, so the desktop can **build a fresh customized ISO**.

## Verifying images under emulation

`scripts/qemu-boot-test.sh` boots an artifact under QEMU/KVM with OVMF UEFI
(headless: serial→log, framebuffer→VNC) and reports pass/fail:

```
./scripts/qemu-boot-test.sh live    out/…standalone-thick.live.iso
./scripts/qemu-boot-test.sh install out/…standalone-thick.installer.iso
```

## Desktop branding (boot screen / login / wallpaper / colours)

Every desktop image (standalone **or** tailnet client; CLI, ncurses or graphical
install) can be branded. Assets flow through one applier — `snapdragon-branding` —
so the look is identical whether it was baked into the image or changed afterwards,
and the boot → login → desktop chain stays visually consistent.

### Build-time flags

| Flag | Effect |
|------|--------|
| `--theme NAME` | Apply a bundled preset from `specs-x86/branding/themes/NAME/` (ships **`boogiepop`**). |
| `--branding-dir DIR` | Apply a whole brand directory (overlays the preset). |
| `--wallpaper FILE` | Desktop wallpaper (also the fallback for the GRUB + login backgrounds). |
| `--grub-background FILE` | GRUB boot-menu background. |
| `--login-background FILE` | lightdm greeter (graphical login) background. |
| `--brand-logo FILE` | Brand logo (greeter / about). |
| `--accent-color '#RRGGBB'` | KDE accent colour. |
| `--color-scheme FILE.colors` | KDE colour scheme. |
| `--brand-locked` | Managed image: the **user cannot re-theme** (drops `/etc/snapdragon/branding.lock`). |

Precedence (later wins): `--theme` → `--branding-dir` → individual file flags →
`--accent-color`. A brand dir may contain `brand.conf`, `wallpaper.png`,
`grub-background.png`, `login-background.png`, `logo.png`, `colors.colors` (all
optional; `wallpaper.png` is the fallback for the two backgrounds).

No build channel applies a theme by itself **except the ncurses menu**: `make
menu` defaults branded standalone builds to `--theme boogiepop` — the dark
Boogiepop example theme (`specs-x86/branding/themes/boogiepop/`) — via the
persisted `OPT_SA_THEME` default in `scripts/build-menu.sh` (pick **None**
under "Branding theme" for the stock look). The direct channels bake no theme
unless you pass one explicitly: `make x86-standalone` / `make
x86-standalone-thick STANDALONE_FLAGS='--theme boogiepop'`, or a fleet run
(`scripts/build-all-roles.sh`; `X86_STANDALONE=1` appends the three standalone
variants to the role set, `X86_STANDALONE_ONLY=1` builds only them) with
`--theme boogiepop` in its pass-through builder args. The
`standalone-unaffiliated` role suppresses theming entirely: any `--theme` is a
hard conflict, the menu never emits its persisted theme default for it, and a
branded fleet run skips the unaffiliated role loudly (build it separately with
`make x86-standalone-unaffiliated`).

### Re-theming on the running desktop

`snapdragon-branding` stays on the installed system, so the user can change the look
later (unless `--brand-locked` was set at build time):

```
snapdragon-branding apply /path/to/branddir      # whole theme
snapdragon-branding set-wallpaper ~/Pictures/x.png
snapdragon-branding set-login-background x.png
snapdragon-branding set-grub-background x.png
snapdragon-branding set-accent '#3f5b8c'
snapdragon-branding show                          # current brand + lock state
snapdragon-branding lock | unlock                 # admin: freeze / release branding
```

Wallpaper + colour scheme are applied in-session by a one-shot login autostart
(`/etc/xdg/autostart/snapdragon-branding.desktop`) the first time a desktop starts,
then it steps aside so the user's own choices stick. The GRUB background + lightdm
greeter background are baked at build time so the very first boot is already branded.

## Egress VPN (NetworkManager)

A desktop / tailnet node can ship an **outbound** egress VPN that NetworkManager
manages. Split-tunnel by design: the VPN provides only the **default route** (public
Internet); the tailnet (`100.64.0.0/10`) and local LANs keep their more-specific
routes, so mesh / tailscale / LAN traffic stays **direct** and never tunnels.

| Flag | Effect |
|------|--------|
| `--egress-vpn FILE` | Bake a WireGuard `.conf` / OpenVPN `.ovpn` / NM `.nmconnection` into the image; first boot imports it into NetworkManager. |
| `--egress-vpn-locked` | **Managed node**: the VPN autoconnects and the user **cannot remove** it (an NM dispatcher re-asserts it if deleted). For tailscale-node images the admin controls egress. |

Without `--egress-vpn-locked` the user **adds/removes/toggles** it freely (the network
applet or `snapdragon-egress-vpn up|down|remove`). WireGuard is native to NM + the
kernel (a `CONFIG_WIREGUARD` fragment + `wireguard-tools` are added automatically);
OpenVPN pulls `networkmanager-openvpn` + `openvpn`.

```
snapdragon-egress-vpn status        # name / locked / present / state / staged conf
snapdragon-egress-vpn up | down     # toggle (down refused when locked, for non-root)
snapdragon-egress-vpn remove        # delete (refused when locked, for non-root)
```

## Monolithic kernel (`--kernel-builtin`)

`--kernel-builtin` compiles most in-tree kernel config **built-in (`=y`)** instead of as
loadable modules — a smaller attack surface that fits the hardened posture. The build
turns each fragment `module CONFIG_X` into `=y` and sweeps the base defconfig's `=m`
symbols to `=y`, **except** those in `specs-x86/kernel/keep-as-module.list` (out-of-tree
nvidia/zfs/vbox, firmware/load-order-sensitive radios, etc.). `CONFIG_MODULES` always
stays on so the out-of-tree `nvidia.ko` still loads (the "except where it inhibits
function" guard). `olddefconfig` drops any `=y` that can't satisfy a dependency, so the
sweep is safe. Add a symbol to `keep-as-module.list` if building it in breaks a machine.

## Hardware profiles + scanner

`specs-x86/hwprofiles/profiles.json` is a curated catalog of pre-supported machines — **all
Framework laptops**, the ASUS VivoBook F512DA, and best-selling Amazon/Best Buy/Costco/
Walmart laptops & gaming desktops. The Generator Studio shows them as a menu and can also
**scan the machine it's running on** (Linux `lspci`/sysfs, Windows PowerShell/CIM) to
auto-pick `--gpu-driver`, Wi-Fi/BT, and a profile.

## Generator Studio (cross-platform GUI)

`studio/` is a desktop app (Linux **and Windows**) that builds images with a Calamares-style
wizard instead of raw flags, and runs a **local mesh node** from the system tray. It drives
the build natively on Gentoo or via Docker elsewhere, covers the whole flag surface —
including a **role & platform picker** (both standalone variants, the client devices, every
cluster role, and the arm64 Frite / RPi5 family (rpi5/rpi4/rpi3 boards) / Jetson / Orange Pi 5 /
Orange Pi Zero 2 platforms), LUKS `--encrypt-root` + unlock factors,
Steam delivery and desktop weight — accepts an admin **key-zip**, and (superadmin) sets up
domains + users before building. Plaintext secrets (`--local-pass`/`--luks-pass`) are never
written to a saved config. See [studio/README.md](../studio/README.md).

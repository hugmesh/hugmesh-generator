# Per-user client device images (FD-04 … FD-09)

Status: **FD-04 shipped; later increments deferred.** This document is the staged
implementation plan for the per-user *client* device images, distinct from the
five Kubernetes **node** roles (`pki / be / fe / be+gpu / omnibus`). A *client* is
a **person's device** — a desktop that joins the Tailscale mesh and runs the
platform UI — not a cluster node.

> **See also: [STANDALONE-DESKTOP.md](STANDALONE-DESKTOP.md)** — the `standalone-thin`
> / `standalone-thick` roles build a **self-contained hardened NVIDIA desktop** with
> NO mesh and NO Casdoor SSO: a normal local user, LUKS2 full-disk encryption on
> install, optional keyfile/YubiKey unlock, and an auto-detected `/media` data disk
> (Steam + gocryptfs Vaults). Those are the *opposite* of the mesh-joined clients
> below; the `--standalone` / `--skip-sso` flags also compose onto these roles.

- **✅ shipped:** the x86 laptop / thin-Chromebook / superadmin-desktop client arms
  (FD-04, Increments 1 and 3), including the grub-mkimage / ESP fix (PR #93). The
  laptop client image has been QEMU-verified to the lightdm greeter + tailnet join
  (`tests/qemu/verify-client.sh`).
- **🔭 deferred / roadmap:** FD-07 (LUKS2-decrypt == Casdoor), FD-06 (VPN-lock /
  expiry), FD-08 (delegated ArgoCD pipeline), egress-VPN net atoms baking into the
  x86 client, and **desktop app governance** (per-license SSO-enforced sudo +
  admin-curated Plasma Discover store + user install-requests + admin
  remote-install over the device-SSH-license).

## Two orthogonal axes (do not overload `--role`)

- **node role** (existing): `pki|be|fe|be+gpu|omnibus` — k8s scheduling/compute. `ROLE`.
- **device class** (new): `laptop | chromebook | desktop` (thin laptop + thin
  Chromebook are the FD-04 defaults; full desktop is opt-in). A device class sets
  `ROLE_CLIENT=true`.
- **person role** (new): `user | mod | admin | superadmin` — the Casdoor identity
  the device boots as (FD-08). `PERSON_ROLE`.
- **domain(s)** (new): the device is tied at build time to one or more domains
  (FD-08); the artifact filename carries the (primary) domain tag.

A superadmin device is `device class × person_role=superadmin` and additionally
gets the FD-06 VPN-lock + expiry profile.

## Architecture (ADR-16)

Client images are **new `--role` arms on `build-x86-host-stage4.sh`**, NOT a new
script. Chromebook v1 boots via **coreboot-UEFI** (defer native depthcharge). The
arm reuses the proven `build-frite-stage4.sh` desktop patterns (LXDE/openbox +
lightdm + `display-manager`, the SHARED `specs/` mesh/provision/sshd block) but on
the native amd64 chroot build with grub-EFI.

## Increments

### 1 — x86 client desktop role arm (thin laptop) — THIS CHANGE
- `ROLE_CLIENT` intent + `laptop` (and `desktop` = full) arms in the role case
  block (`build-x86-host-stage4.sh` ~241-269). GPU=true, `ROLE_K8S=none`,
  `ROLE_HEADSCALE=false`.
- Client `SVCS`: drop `containerd/kubelet/headscale`; add
  `dbus elogind display-manager` + `tailscaled` (mirror frite ~668-681).
- Skip the k8s/cluster GitOps payload (`cp -r cluster` + `gate_*`, ~951-955) when
  `ROLE_CLIENT`.
- `specs-x86/portage/packages-desktop.list` (Xorg/openbox/lightdm + NetworkManager
  applet + firefox-bin + fonts + acpid + firewalld) appended for client roles;
  k8s atoms NOT emerged for clients (client base list).
- `specs-x86/kernel/desktop.config` (i915/amdgpu/nouveau KMS, evdev/HID, ALSA,
  NVMe/AHCI/XHCI, ACPI/backlight/thermal, microcode) appended for client roles.
- Desktop USE: a `@@CLIENT_USE@@` token in `make.conf.tmpl` (`X gtk dbus elogind`)
  set for client roles.
- `PERSON_ROLE` + `DOMAINS` build flags → `/etc/snapdragon/{identity-role,domains}`
  markers; `provision_client_identity()` applies them; person-role+domain in the
  artifact tag.
- **✅ DONE** — laptop image **QEMU-verified to the lightdm greeter + tailnet
  join** (`build-x86-host-stage4.sh --role laptop --person-role user --domains
  acme.example`); the grub-mkimage / ESP boot fix landed in PR #93. Verified via
  `tests/qemu/verify-client.sh`.

### 2 — FD-07 LUKS2 decrypt-to-desktop — 🔭 DEFERRED (roadmap)
- LUKS2 root in the installer/`build_img` (cryptsetup luksFormat aes-xts-plain64,
  argon2id — reuse `provision.sh` `luks_open_or_format` ~1358-1399), dracut
  `--add crypt`, `rd.luks.uuid` on the grub cmdline. `growroot` is already
  LUKS-aware (no change).
- "disk password == Casdoor login": **offline-escrowed keyslot** (no network at
  initramfs) — enroll a Casdoor-derived keyslot at provision time; TPM2/USB-KEYS
  recovery. PAM-OIDC for the post-unlock lightdm login. Auto-login decrypt→desktop
  unless MFA configured (greetd MFA greeter).

### 3 — FD-04 Chromebook arm + superadmin variants — DONE
- **Chromebook boot path:** already correct from Increment 1 — the `.img` installs
  GRUB-EFI `--removable --no-nvram` into `/EFI/BOOT/BOOTX64.EFI`, exactly the path a
  coreboot-UEFI (Tianocore payload, e.g. MrChromebox) Chromebook auto-boots. No
  NVRAM entry needed.
- **Chromebook kernel quirks:** new `specs-x86/kernel/chromebook.config`, appended
  on top of `desktop.config` ONLY for `--role chromebook`. Adds the chromebook
  peripherals a generic laptop image lacks: DesignWare I2C bus + I2C-HID, the
  I2C-attached touchpads (elan/atmel/cyapa), the I2S audio codecs + jack detect +
  Intel SOC machine drivers (max98090/ts3a227e/rt5677/da7219/SKL/SOF), the Chrome-EC
  sub-devices (charger/extcon/sensors), the on-board cr50 TPM, and pstore-RAM.
  (`desktop.config` already carries the EC core + EC keyboard + pstore + i801.)
- **superadmin device-password variant:** building with `--person-role superadmin`
  bakes the marker `/etc/snapdragon/device-password-required`. At first boot,
  keys-provision's `provision_device_password()` sets the superadmin account's local
  login password from a **salted+hashed** value on the KEYS USB
  (`.client.device_password_hash`, else `secrets/device-password.hash`). Plaintext
  NEVER touches git or the image (mirrors the Casdoor superadmin-seed custody); a
  non-crypt(3) value is refused. The hash applies to `resolve_ssh_user()` (the
  device's superadmin account). FD-07 LUKS keyslot enrollment from this same
  password is Increment 2; FD-06 VPN-lock/expiry is Increment 4.

### 4 — FD-06 VPN-locked, expiring superadmin field devices — 🔭 DEFERRED (roadmap)
- firewalld shields-up/panic default (allow only Tailscale + `superadmin.<domain>`
  per ADR-17), a desktop shield-state applet, generation-time `ending_at` →
  auto-revoke tailnet membership + ROLE_SUPERADMIN claim + short-lived device cert
  (reuse the ADR-23 lease effector + device-license registry transport; NEW
  enforcement class — the existing Layer-B skips superadmin nodes).

### 5 — FD-09 Docker mesh-node (Windows + Linux)
- A background single-container image (Tailscale + node agent) + Windows
  `.ps1/.cmd` and Linux `sh` wrappers, one-line Casdoor login, honoring the
  ADR-14 mesh-join latch + register-and-approve admission. **Not** `make stack-up`
  (that's the local-dev full-stack runner).

### 6 — FD-08 delegated build pipeline — 🔭 DEFERRED (roadmap)
- superadmin-owned, role-gated ArgoCD pipeline: admin **configures** a
  domain-scoped user-device request; the pipeline **executes** the privileged
  stage4 (admin never gets privileged build access or core secrets; ADR-12/ADR-24).

### 7 — Desktop app governance — 🔭 PLANNED (design + queued)
- Extends the shipped FD-04 client images with **per-license SSO-enforced sudo**
  (revocable at the IdP), an **admin-curated Plasma Discover store**
  (default-NONE, domain-locked Flatpak / OCI registry, `discover`-role gated),
  **user install-requests**, and **admin remote-install** (one-click + an in-UI
  SSH terminal over the device-SSH-license). Rides the existing device-SSH-license
  transport. Not yet implemented.

## Provisioning manifest additions (keys-provision)

```jsonc
"client": {
  "identity_role": "user|mod|admin|superadmin",   // FD-08 person role
  "domains": ["acme.example", "..."],              // FD-08 domain tie
  "primary_domain": "acme.example",
  "casdoor": { "issuer": "id.<primary_domain>", "client_id": "...", "pkce": true },
  // Increment 3: superadmin client variant only. crypt(3) hash (mkpasswd -m
  // sha512crypt / -m yescrypt). Plaintext NEVER in git/image. May instead live on
  // the KEYS USB at secrets/device-password.hash (manifest takes precedence).
  "device_password_hash": "$6$...."
}
```
The build bakes `/etc/snapdragon/{identity-role,domains,desktop-weight}` directly
(no provision step needed for those). For the superadmin variant the build also
bakes `/etc/snapdragon/device-password-required`, and `provision_device_password()`
(called after `provision_users`) applies `device_password_hash` to the superadmin
account at first boot. A later `provision_casdoor_desktop()` will wire the OIDC
desktop login + the FD-07 keyslot. `device_registry.image_type=="client"` already
exists (inventory only).

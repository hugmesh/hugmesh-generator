# Per-user client device images (FD-04 … FD-09)

Status: **FD-04 shipped; desktop app governance implemented (ships dark); other
later increments deferred.** This document is the staged
implementation plan for the per-user *client* device images, distinct from the
five Kubernetes **node** roles (`pki / backend / frontend / backend-gpu / omnibus`). A *client* is
a **person's device** — a desktop that joins the Tailscale mesh and runs the
platform UI — not a cluster node.

> **See also: [STANDALONE-DESKTOP.md](STANDALONE-DESKTOP.md)** — the `standalone-thin`
> / `standalone-thick` roles build a **self-contained hardened NVIDIA desktop** with
> NO mesh and NO Casdoor SSO: a normal local user, LUKS2 full-disk encryption on
> install, optional keyfile/YubiKey unlock, and an auto-detected `/media` data disk
> (Steam + gocryptfs Vaults). Those are the *opposite* of the mesh-joined clients
> below; the `--standalone` / `--skip-sso` flags also compose onto these roles.
> **This standalone posture is not x86-only** — `build-frite-stage4.sh`,
> `build-rpi5-stage4.sh` (rpi5/rpi4/rpi3 boards), `build-orangepi5-stage4.sh` and
> `build-orangepi4-lts-stage4.sh`
> all have their own `desktop` role composable with `--standalone --encrypt-root`,
> and `build-orangepi-zero2-stage4.sh` / `build-orangepi-zero2w-stage4.sh` /
> `build-orangepi-zero3-stage4.sh` / `build-orangepi3-lts-stage4.sh` have the
> same posture on their headless `appliance` role — see STANDALONE-DESKTOP.md's "ARM platforms" section.
> **`build-jetson-stage4.sh` is the one exception**: `--encrypt-root` (and
> `--standalone`, which forces it on) is hard-blocked outright on this platform —
> its single boot+root partition means the UEFI firmware can't find a kernel once
> that partition is LUKS2-encrypted — see STANDALONE-DESKTOP.md's Jetson section.
> These ARM `desktop` roles are a **separate, simpler**
> role namespace from this document's FD-04 client-device architecture below
> (no `PERSON_ROLE`/`DOMAINS`/Casdoor desktop governance) — they exist purely as
> the mount point for the standalone/LUKS posture on non-x86 hardware.
> The standalone path also includes an **unaffiliated** variant
> (`standalone-unaffiliated`, or `--unaffiliated` composed onto any client role):
> a plain hardened Gentoo desktop with **zero HugMesh affiliation** — neutral
> boot chain/installer/hostname/artifacts, no `hugmesh-*` tools or markers —
> see [STANDALONE-DESKTOP.md](STANDALONE-DESKTOP.md#unaffiliated-plain-desktop-standalone-unaffiliated).

- **✅ shipped:** the x86 laptop / thin-Chromebook / superadmin-desktop client arms
  (FD-04, Increments 1 and 3), including the grub-mkimage / ESP fix (PR #93). The
  laptop client image has been QEMU-verified to the lightdm greeter + tailnet join
  (`tests/qemu/verify-client.sh`).
- **🔭 deferred / roadmap:** FD-07 (LUKS2-decrypt == Casdoor), FD-06 (VPN-lock /
  expiry), FD-08 (delegated ArgoCD pipeline), egress-VPN net atoms baking into the
  x86 client.
- **✅ implemented, ships dark:** **desktop app governance** (per-license
  SSO-enforced sudo + admin-curated Plasma Discover store + user install-requests
  + admin remote-install over the device-SSH-license) — see Increment 7 below.

> **✅ All channels expose the client roles + the full option set.** The
> `laptop` / `chromebook` / `desktop` roles build identically from the CLI, the
> `make x86-<role>` targets, the ncurses menu (`make menu`) and the Studio GUI —
> and the menu/GUI now surface the **whole** client flag surface (desktop weight
> + Steam delivery, the opt-in `--with-sunshine` thin-desktop stream host
> (tailnet-only Sunshine for mesh headsets — see [MDM.md](MDM.md) "Thin
> desktop"), home provisioning create/adopt/archive/restore + eCryptfs,
> the per-piece branding overrides, `--installer-ui`, plus an extra-flags escape
> hatch for anything unfielded). This parity is enforced by the build-matrix
> harness (`make matrix-check`) — see [BUILD-MATRIX.md](BUILD-MATRIX.md).

## Two orthogonal axes (do not overload `--role`)

- **node role** (existing): `pki|backend|frontend|backend-gpu|omnibus` — k8s scheduling/compute. `ROLE`.
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
- `PERSON_ROLE` + `DOMAINS` build flags → `/etc/hugmesh/{identity-role,domains}`
  markers (baked directly by the build); `provision_desktop_governance()` (in
  `specs/etc/keys-provision/provision.sh`) reads the `domains` marker at first boot
  to render the Casdoor/OIDC desktop-governance tie; person-role+domain in the
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
  bakes the marker `/etc/hugmesh/device-password-required`. At first boot,
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
- **See also:** [`MDM.md`](MDM.md) — the **fourth onboarding form** (🚧): a GrapheneOS Pixel phone onboarded alongside the appliance images, these client desktops, and this FD-09 Docker mesh node; its `enroll` verb reuses this mesh node's `keys.example` keys-dir layout.

### 6 — FD-08 delegated build pipeline — 🔭 DEFERRED (roadmap)
- superadmin-owned, role-gated ArgoCD pipeline: admin **configures** a
  domain-scoped user-device request; the pipeline **executes** the privileged
  stage4 (admin never gets privileged build access or core secrets; ADR-12/ADR-24).

### 7 — Desktop app governance — ✅ IMPLEMENTED, ships dark
- Extends the shipped FD-04 client images with **per-license SSO-enforced sudo**
  (revocable at the IdP), an **admin-curated Plasma Discover store**
  (default-NONE, domain-locked Flatpak / OCI registry, `discover`-role gated),
  **user install-requests**, and **admin remote-install** (one-click + an in-UI
  SSH terminal over the device-SSH-license). Rides the existing device-SSH-license
  transport. The client-side provisioning lives here
  ([`specs/etc/hugmesh/desktop-governance/`](../specs/etc/hugmesh/desktop-governance/):
  polkit sudo rule, the desktop-sudo claim→group mapper + its 60s cron,
  Discover/Flatpak wiring, autostart SSO deposit scripts) and the server-side
  data/API is a full set of controllers in `hugmesh-admin-bff-api` (catalog,
  install-requests, remote-install, sudo entitlement/step-up, SSH terminal). It
  **ships dark**: the registry + SSH transport default to `Noop` client
  implementations gated by `app.desktop.registry.enabled=false` /
  `app.desktop.remote-install.enabled=false` (both default off), so a default
  deployment exposes none of this.
- **Sudo path (corrected 2026-08): a root claim→group MAPPER, not SSSD.** The
  original increment shipped an `/etc/sssd/conf.d` conf using `id_provider =
  oidc` + `oidc_groups_allowlist` + a `[domain/../local-groups]` section —
  syntax that exists in **no released SSSD** — and never installed sssd at all.
  Released SSSD's real OAuth2 support (`id_provider = idp`, added in 2.11.0 /
  2025-06-05) speaks only the **Keycloak / Entra ID REST APIs** (`idp_type`
  accepts exactly those two products), looks users and groups up *through those
  REST APIs* with its own service client, authenticates via the RFC-8628
  device-auth grant, and has **no token-claim→local-group mapping** — the whole
  documented option set is `idp_type` / `idp_client_id` / `idp_client_secret` /
  `idp_token_endpoint` / `idp_device_auth_endpoint` / `idp_userinfo_endpoint` /
  `idp_id_scope` / `idp_auth_scope` / `idp_request_timeout` / `idp_auto_refresh`
  / `idmap_range_*`, and none of it consumes a token the system did not itself
  obtain. 2.12.0 and 2.13.x (2.13.1 is current) added token caching/auto-refresh
  and an Entra endpoint knob, not claim mapping. The per-domain Casdoor issuer is
  unsupported, so no sssd.conf can deliver this leg. The working runtime is
  `sudo/desktop-sudo-mapper.py.tmpl` → `/etc/hugmesh/desktop-governance/
  desktop-sudo-mapper` (root, 0700) + `/etc/cron.d/hugmesh-desktop-sudo-mapper`
  (60s convergence floor, the `hugmesh-domain-reconcile` idiom): it verifies
  each session's deposited OIDC token against the issuer JWKS (RS256 signature
  via OIDC discovery with a last-good cache, `iss`/`aud`/`exp`, and the token's
  `name` claim must equal the local username) and converges local `desktop-sudo`
  membership to the verified claim set. polkit resolves groups through NSS at
  action time, so grant AND revocation bite the live session; classic sudoers
  is stripped on governed images, so polkit is the only escalation route.
  The runtime behind that is now DECLARED in the x86 CLIENT list
  (`specs-x86/portage/packages-desktop.list`, client-scoped exactly like
  `flatpak`/`discover`): **`sys-auth/polkit`** — the authority that reads the
  rules.d gate; it previously arrived only as an `lxde-base/lxsession`
  dependency, i.e. the sole sudo path hung off a transitive edge — and
  **`dev-lang/python`**, the mapper's stdlib-only interpreter. The 60s floor
  runs on the base `sys-process/cronie`, already enabled in the client runlevel.
  **No `sys-auth/sssd`, and no PAM or nsswitch changes**: `desktop-sudo` is a
  LOCAL group, so polkit resolves it through the stock `files` NSS source and
  nothing in the identity stack is touched (default-deny by construction).
  Everything renders only on a governed image with a valid domain (ships-dark).
  The SSO greeter/PAM **token producer** stays 🔭 DEFERRED with FD-07
  (Increment 2); until it lands the deposit path has no producer and the whole
  leg stays inert-by-default.

#### Go-live preconditions (the three dark flags)

Three admin-BFF flags decide whether the platform can open a shell on, or run an
install on, a tenant device. All three are **off**, and nothing here flips them.
They are now findable and overridable:

| Flag | Env var | admin-BFF property |
|---|---|---|
| live WebSocket terminal transport | `DEVICE_TERMINAL_ENABLED` | `app.device-terminal.enabled` |
| the real, host-key-pinned dial | `DEVICE_TERMINAL_DIAL_ENABLED` | `app.device-terminal.dial.enabled` |
| one-click Flatpak remote-install | `DESKTOP_REMOTE_INSTALL_ENABLED` | `app.desktop.remote-install.enabled` |

Where each is declared: the BFF's `application.yml` (all three, default `false`;
`app.desktop.remote-install.enabled` had **no** yaml entry before, only a bean
condition with `matchIfMissing = true`), the cluster Deployment
(`specs/cluster/manifests/admin-bff-api/deployment.yaml`, literal `"false"`), and
the compose stack (`tests/stack/compose.local.yaml`, `${NAME:-false}`, so setting
the variable in the environment `docker compose` runs under overrides it). On the
cluster the lever is editing the manifest value in a reviewed commit:
`apps/31-admin-bff-api.yaml` is `automated {prune, selfHeal}`, so `kubectl set
env` is reverted on the next reconcile.
`tests/desktop-governance/test-governance-flags-visible.sh` pins all of this and
goes red if a flag is removed, hardcoded, defaulted on, or set true on the cluster
without its mount. It is the review point: the commit that flips a flag updates it.

What each flag needs before it does anything:

1. **The dial flag carries a mandatory security re-review.** Flipping
   `DEVICE_TERMINAL_DIAL_ENABLED` replaces the fail-closed
   `UnconfiguredDeviceSshChannelFactory` with the sshj factory that opens SSH
   sessions from the BFF to tenant devices. The re-review comes **before** the
   flip; it is a precondition, not a follow-up. The terminal and the
   remote-install share this one trust path, so the remote-install flag adds no
   second one.
2. **`device_ssh_dial` rows must exist and be ACTIVE.** The factory refuses a
   device unless its row is `ACTIVE` **and** the host key the device presents
   matches the row's pinned `host_key_fp`. TOFU is forbidden: no auto-accept. A
   row carries `device_id` (one row per device), `dial_user`, `host_key_pub`,
   `host_key_fp` (a `SHA256:` pin; an MD5 pin cannot become ACTIVE), `dial_pub_fp`,
   `vault_ref` and `k8s_secret_name` (pointers, never key bytes),
   `seeded_by_build_id`, `generation`, and `status` in `PENDING | ACTIVE |
   REVOKED`. Rows are not written by hand: an image build seeds one as `PENDING`
   when its ingest reports the device's host key and dial public-key fingerprint,
   and a **SUPERADMIN** activates it with a step-up
   (`POST /bff/superadmin/desktop/dials/{deviceId}/activate`; `422` for an
   unpinned row or a `root`/blank dial user). Activation answers `503` while the
   dial flag is false, so rows can be seeded but not activated until after the
   flip. Revoke is allowed at any time. The 2026-08 audit found **zero rows** on
   the running mesh; with no desktop image ever built (the default
   `X86_ROLE_LIST` is `pki backend frontend backend-gpu`) nothing can have
   seeded one. Re-measure before relying on that.
3. **The per-device dial private key must be mounted into the BFF pod.** The
   factory reads `<key-mount-path>/<k8s_secret_name>/<key-file>` at dial time
   (default `/var/run/secrets/device-ssh-dial/device-ssh-<deviceId>/
   dial_private_key`). One ExternalSecret per device is rendered from
   `specs/cluster/manifests/external-secrets/device-ssh-externalsecret.tpl.yaml`
   (a template, not applied by any Application). **No manifest in this tree
   mounts those Secrets into the admin-BFF Deployment** (measured by grep,
   2026-10-14), so even with ACTIVE rows the dial fails closed on a missing key
   file. This is an open design item, not a flag: a static Deployment cannot name
   per-device volumes that are created dynamically.
4. **`DEVICE_TERMINAL_ENABLED` and `DESKTOP_REMOTE_INSTALL_ENABLED`** need nothing
   beyond 1 to 3, and are inert without them: the connect-time license and
   step-up re-checks always run, and with the dial seam unconfigured every dial
   attempt is refused. An admin-BFF image older than the `application.yml` entry
   silently ignores `DESKTOP_REMOTE_INSTALL_ENABLED`.
5. **A desktop image must exist.** The desktop boot-verify (Qt6/KF6 Discover
   pull, the `hugmesh-desktop` PKCE client, the desktop-sudo claim to polkit
   path) has never run, because no laptop / chromebook / desktop image has ever
   been built. The SSO-sudo leg also stays inert until the greeter / PAM token
   producer lands (FD-07 increment 2).

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
  "device_password_hash": "$y$...."   // any crypt(3) hash: $y$ yescrypt (preferred) or $6$ sha512crypt
}
```
The build bakes `/etc/hugmesh/{identity-role,domains,desktop-weight}` directly
(no provision step needed for those). For the superadmin variant the build also
bakes `/etc/hugmesh/device-password-required`, and `provision_device_password()`
(called after `provision_users`) applies `device_password_hash` to the superadmin
account at first boot. A later `provision_casdoor_desktop()` will wire the OIDC
desktop login + the FD-07 keyslot. `device_registry.image_type=="client"` already
exists (inventory only).

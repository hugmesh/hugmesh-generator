# Per-user client device images (FD-04 … FD-09)

Status: **FD-04 shipped; desktop app governance implemented (ships dark); other
later increments deferred.** This is the staged plan for the per-user *client*
device images. They differ from the Kubernetes **node** roles (`pki / backend /
frontend / backend-gpu / omnibus / edge-ai`). A *client* is **a person's
device**: a desktop that joins the Tailscale mesh and runs the platform UI. It
is not a cluster node.

> **See also: [STANDALONE-DESKTOP.md](STANDALONE-DESKTOP.md).** The
> `standalone-thin` / `standalone-thick` roles build a **self-contained hardened
> desktop** (free GPU drivers by default; proprietary NVIDIA is opt-in) with NO
> mesh and NO Casdoor SSO. They give you a normal local user, LUKS2 full-disk
> encryption on install, optional keyfile/YubiKey unlock, and an auto-detected
> `/media` data disk (Steam + gocryptfs Vaults). They are the *opposite* of the
> mesh-joined clients below. The `--standalone` / `--skip-sso` flags also
> compose onto the client roles.
>
> **The standalone posture is not x86-only.** The Frite, RPi5 (rpi5/rpi4/rpi3),
> Orange Pi 5 and Orange Pi 4 LTS builders each have a `desktop` role that
> composes with `--standalone --encrypt-root`. The Orange Pi Zero 2, Zero 2W,
> Zero 3 and 3 LTS builders have the same posture on their headless `appliance`
> role. See "ARM platforms" in STANDALONE-DESKTOP.md.
> **`build-jetson-stage4.sh` is the one exception.** It hard-blocks
> `--encrypt-root`, and `--standalone`, which forces it on, because its single
> boot+root partition cannot be LUKS2-encrypted and still boot. See the Jetson
> section of STANDALONE-DESKTOP.md.
> These ARM `desktop` roles form a **separate, simpler** role namespace from the
> FD-04 client-device architecture below. They have no `PERSON_ROLE`, no
> `DOMAINS` and no Casdoor desktop governance. They exist only as the mount
> point for the standalone/LUKS posture on non-x86 hardware.
>
> The standalone path also has an **unaffiliated** variant
> (`standalone-unaffiliated`, or `--unaffiliated` composed onto any client
> role): a plain hardened Gentoo desktop with **zero HugMesh affiliation**. It has
> a neutral boot chain, installer, hostname and artifact names, and no
> `hugmesh-*` tools or markers. See
> [STANDALONE-DESKTOP.md](STANDALONE-DESKTOP.md#unaffiliated-plain-desktop-standalone-unaffiliated).

- **✅ shipped:** the x86 laptop / thin-Chromebook / superadmin-desktop client arms
  (FD-04, Increments 1 and 3), including the grub-mkimage / ESP fix (merge
  55c3b705, branch `fix/client-images-grub-mkimage`). QEMU verified the laptop
  client image through to the lightdm greeter and the tailnet join
  (`tests/qemu/verify-client.sh`).
- **🔭 deferred / roadmap:** FD-07 (LUKS2-decrypt == Casdoor), FD-06 (VPN-lock /
  expiry), FD-08 (delegated ArgoCD pipeline).
- **✅ shipped, separately from FD-04:** the egress VPN. The x86 builder bakes
  `--egress-vpn` / `--egress-vpn-locked` into client desktop roles (see
  [STANDALONE-DESKTOP.md](STANDALONE-DESKTOP.md#egress-vpn-networkmanager)). An
  earlier version of this list named "egress-VPN net atoms baking into the x86
  client" as deferred. That is no longer true.
- **✅ implemented, ships dark:** **desktop app governance**: per-license
  SSO-enforced sudo, an admin-curated Plasma Discover store, user
  install-requests, and admin remote-install over the device-SSH-license. See
  Increment 7 below.

> **✅ Every channel exposes the client roles and the full option set.** The
> `laptop` / `chromebook` / `desktop` roles build the same way from the CLI, the
> `make x86-<role>` targets, the ncurses menu (`make menu`) and the Studio GUI.
> The menu and GUI now surface the **whole** client flag surface: desktop weight
> and Steam delivery; the opt-in `--with-sunshine` thin-desktop stream host
> (tailnet-only Sunshine for mesh headsets; see "Thin desktop" in
> [MDM.md](MDM.md)); home provisioning create/adopt/archive/restore plus
> eCryptfs; the per-piece branding overrides; `--installer-ui`; and an
> extra-flags escape hatch for anything unfielded. The build-matrix harness
> enforces this parity (`make matrix-check`; see
> [BUILD-MATRIX.md](BUILD-MATRIX.md)).

## Two orthogonal axes (do not overload `--role`)

- **node role** (existing): `pki|backend|frontend|backend-gpu|omnibus|edge-ai` — k8s scheduling/compute. `ROLE`.
- **device class** (new): `laptop | chromebook | desktop`. The thin laptop and
  thin Chromebook are the FD-04 defaults; the full desktop is opt-in. A device
  class sets `ROLE_CLIENT=true`.
- **person role** (new): `user | mod | admin | superadmin` — the Casdoor identity
  the device boots as (FD-08). `PERSON_ROLE`.
- **domain(s)** (new): the device is tied at build time to one or more domains
  (FD-08). The artifact filename carries the (primary) domain tag.

A superadmin device is `device class × person_role=superadmin`. It also gets the
FD-06 VPN-lock + expiry profile.

## Architecture (ADR-16)

Client images are **new `--role` arms on `build-x86-host-stage4.sh`**, not a new
script. Chromebook v1 boots through **coreboot-UEFI** (native depthcharge is
deferred). The arm reuses the proven desktop patterns of `build-frite-stage4.sh`
(LXDE/openbox, lightdm, `display-manager`, and the SHARED `specs/`
mesh/provision/sshd block), on the native amd64 chroot build with grub-EFI.

## Increments

### 1 — x86 client desktop role arm (thin laptop) — THIS CHANGE
- `ROLE_CLIENT` intent, plus `laptop` / `chromebook` (and `desktop` = full) arms
  in the role `case` block of `build-x86-host-stage4.sh`. GPU=true,
  `ROLE_K8S=none`, `ROLE_HEADSCALE=false`.
- Client `SVCS`: drop `containerd/kubelet/headscale`. Add
  `dbus elogind display-manager`, plus `tailscaled` unless `--skip-mesh` or
  `--skip-tailscale` (as the Frite builder does).
- When `ROLE_CLIENT`, skip the k8s/cluster GitOps payload (the cluster copy and
  the `gate_*` steps).
- Append `specs-x86/portage/packages-desktop.list` for client roles: Xorg,
  openbox/LXDE, lightdm, `nm-applet`, netsurf, fonts, acpid, firewalld, plus
  flatpak, Discover, polkit and python for desktop governance. k8s atoms are NOT
  emerged for clients (client base list).
- Append `specs-x86/kernel/desktop.config` for client roles: i915/amdgpu/nouveau
  KMS, evdev/HID, ALSA, NVMe/AHCI/XHCI, ACPI/backlight/thermal, microcode.
- Desktop USE: a `@@CLIENT_USE@@` token in `make.conf.tmpl` (`X gtk dbus elogind udev`)
  set for client roles.
- The `PERSON_ROLE` and `DOMAINS` build flags bake `/etc/hugmesh/{identity-role,domains}`
  markers directly. At first boot `provision_desktop_governance()` (in
  `specs/etc/keys-provision/provision.sh`) reads the `domains` marker to render
  the Casdoor/OIDC desktop-governance tie. The artifact tag carries person role
  and domain.
- **✅ DONE.** QEMU verified the laptop image through to the lightdm greeter and
  tailnet join (`build-x86-host-stage4.sh --role laptop --person-role user
  --domains acme.example`). The grub-mkimage / ESP boot fix landed in merge
  55c3b705. Verified by `tests/qemu/verify-client.sh`.

### 2 — FD-07 LUKS2 decrypt-to-desktop — 🔭 DEFERRED (roadmap)
**What shipped and what did not.** A LUKS2 root with its own unlock passphrase
(and optional keyfile or YubiKey factors) already ships as `--encrypt-root`; see
[STANDALONE-DESKTOP.md](STANDALONE-DESKTOP.md). What stays deferred is the part
below that binds the disk key to the Casdoor login.
- LUKS2 root in the installer/`build_img` (cryptsetup luksFormat aes-xts-plain64,
  argon2id — reuse `provision.sh` `luks_open_or_format`), dracut
  `--add crypt`, `rd.luks.uuid` on the grub cmdline. `growroot` is already
  LUKS-aware (no change).
- "Disk password == Casdoor login": an **offline-escrowed keyslot** (no network at
  initramfs). Enroll a Casdoor-derived keyslot at provision time, with TPM2 or
  USB-KEYS recovery. PAM-OIDC covers the lightdm login after unlock. Decrypt
  straight to the desktop (auto-login) unless MFA is configured (greetd MFA
  greeter).

### 3 — FD-04 Chromebook arm + superadmin variants — DONE
- **Chromebook boot path:** already correct from Increment 1. The `.img` installs
  GRUB-EFI `--removable --no-nvram` into `/EFI/BOOT/BOOTX64.EFI`, the path a
  coreboot-UEFI Chromebook (Tianocore payload, e.g. MrChromebox) auto-boots. No
  NVRAM entry needed.
- **Chromebook kernel quirks:** the new `specs-x86/kernel/chromebook.config` goes
  on top of `desktop.config` ONLY for `--role chromebook`. It adds the peripherals
  a generic laptop image lacks: the DesignWare I2C bus and I2C-HID; the
  I2C-attached touchpads (elan/atmel/cyapa); the I2S audio codecs, jack detect
  and Intel SOC machine drivers (max98090/ts3a227e/rt5677/da7219/SKL/SOF); the
  Chrome-EC sub-devices (charger/extcon/sensors); the on-board cr50 TPM; and
  pstore-RAM. (`desktop.config` already carries the EC core, EC keyboard, pstore
  and i801.)
- **Superadmin device-password variant:** `--person-role superadmin` bakes the
  marker `/etc/hugmesh/device-password-required`. At first boot keys-provision's
  `provision_device_password()` sets the superadmin account's local login
  password from a **salted+hashed** value on the KEYS USB
  (`.client.device_password_hash`, else `secrets/device-password.hash`). The
  plaintext NEVER touches git or the image (the same custody as the Casdoor
  superadmin seed). A value that is not crypt(3) is refused. The hash applies to
  `resolve_ssh_user()`, the device's superadmin account. FD-07 LUKS keyslot
  enrollment from this same password is Increment 2. FD-06 VPN-lock/expiry is
  Increment 4.

### 4 — FD-06 VPN-locked, expiring superadmin field devices — 🔭 DEFERRED (roadmap)
- A firewalld shields-up/panic default (allow only Tailscale and
  `superadmin.<domain>`, per ADR-17) and a desktop shield-state applet.
- A generation-time `ending_at` that auto-revokes tailnet membership, the
  ROLE_SUPERADMIN claim and a short-lived device cert. Reuse the ADR-23 lease
  effector and the device-license registry transport. This is a NEW enforcement
  class, because the existing Layer-B skips superadmin nodes.

### 5 — FD-09 Docker mesh-node (Windows + Linux)
- A background single-container image (Tailscale + node agent), with Windows
  `.ps1/.cmd` and Linux `sh` wrappers and a one-line Casdoor login. It honors the
  ADR-14 mesh-join latch and register-and-approve admission. It is **not**
  `make stack-up`, which is the local-dev full-stack runner.
- **See also:** [`MDM.md`](MDM.md), the **fourth onboarding form** (✅ shipped).
  A GrapheneOS Pixel phone is onboarded alongside the appliance images, these
  client desktops and this FD-09 Docker mesh node. Its `enroll` verb reuses this
  mesh node's `keys.example` keys-dir layout.

### 6 — FD-08 delegated build pipeline — 🔭 DEFERRED (roadmap)
- A superadmin-owned, role-gated ArgoCD pipeline. An admin **configures** a
  domain-scoped user-device request. The pipeline **executes** the privileged
  stage4. The admin never gets privileged build access or core secrets
  (ADR-12/ADR-24).

### 7 — Desktop app governance — ✅ IMPLEMENTED, ships dark
- Extends the shipped FD-04 client images with:
  - **per-license SSO-enforced sudo**, revocable at the IdP;
  - an **admin-curated Plasma Discover store** (default-NONE, domain-locked
    Flatpak / OCI registry, gated by the `discover` role);
  - **user install-requests**;
  - **admin remote-install**: one click, plus an in-UI SSH terminal over the
    device-SSH-license.

  It rides the existing device-SSH-license transport. The client-side
  provisioning lives in
  [`specs/etc/hugmesh/desktop-governance/`](../specs/etc/hugmesh/desktop-governance/):
  the polkit sudo rule, the desktop-sudo claim→group mapper and its 60s cron,
  the Discover/Flatpak wiring, and the autostart SSO deposit scripts. The
  server-side data and API are a full set of controllers in
  `hugmesh-admin-bff-api` (catalog, install-requests, remote-install, sudo
  entitlement/step-up, SSH terminal).

  It **ships dark.** The registry and the SSH transport default to `Noop` client
  implementations, gated by `app.desktop.registry.enabled=false` and
  `app.desktop.remote-install.enabled=false` (both default off). A default
  deployment exposes none of it.
- **Sudo path (corrected 2026-08): a root claim→group MAPPER, not SSSD.**
  - *What was wrong.* The original increment shipped an `/etc/sssd/conf.d` conf
    with `id_provider = oidc`, `oidc_groups_allowlist` and a
    `[domain/../local-groups]` section. That syntax exists in **no released
    SSSD**, and the increment never installed sssd at all.
  - *What SSSD really does.* Its OAuth2 support (`id_provider = idp`, added in
    2.11.0 / 2025-06-05) speaks only the **Keycloak / Entra ID REST APIs**
    (`idp_type` accepts exactly those two products). It looks up users and groups
    *through those REST APIs* with its own service client, authenticates through
    the RFC-8628 device-auth grant, and has **no token-claim→local-group
    mapping**. The whole documented option set is `idp_type` / `idp_client_id` /
    `idp_client_secret` / `idp_token_endpoint` / `idp_device_auth_endpoint` /
    `idp_userinfo_endpoint` / `idp_id_scope` / `idp_auth_scope` /
    `idp_request_timeout` / `idp_auto_refresh` / `idmap_range_*`. None of it
    consumes a token the system did not obtain itself. Versions 2.12.0 and 2.13.x
    (2.13.1 is current) added token caching, auto-refresh and an Entra endpoint
    knob, not claim mapping. The per-domain Casdoor issuer is unsupported, so no
    sssd.conf can deliver this leg.
  - *What runs instead.* `sudo/desktop-sudo-mapper.py.tmpl` →
    `/etc/hugmesh/desktop-governance/desktop-sudo-mapper` (root, 0700), plus
    `/etc/cron.d/hugmesh-desktop-sudo-mapper` (60s convergence floor, the
    `hugmesh-domain-reconcile` idiom). It verifies each session's deposited OIDC
    token against the issuer JWKS (RS256 signature via OIDC discovery with a
    last-good cache; `iss`/`aud`/`exp`; and the token's `name` claim must equal
    the local username). It then converges local `desktop-sudo` membership to the
    verified claim set. polkit resolves groups through NSS at action time, so
    both grant AND revocation bite the live session. Classic sudoers is stripped
    on governed images, so polkit is the only escalation route.
  - *Runtime packages.* The x86 CLIENT list
    (`specs-x86/portage/packages-desktop.list`, client-scoped like
    `flatpak`/`discover`) now declares **`sys-auth/polkit`**, the authority that
    reads the rules.d gate, and **`dev-lang/python`**, the mapper's stdlib-only
    interpreter. Polkit used to arrive only as an `lxde-base/lxsession`
    dependency, so the sole sudo path hung off a transitive edge. The 60s floor
    runs on the base `sys-process/cronie`, already enabled in the client
    runlevel.
  - *What does not change.* **No `sys-auth/sssd`, and no PAM or nsswitch
    changes.** `desktop-sudo` is a LOCAL group, so polkit resolves it through the
    stock `files` NSS source and nothing in the identity stack is touched
    (default-deny by construction). Everything renders only on a governed image
    with a valid domain (ships dark).
  - *The token producer.* It now exists as code
    (`specs/etc/hugmesh/desktop-governance/sso/hugmesh-sso-token.py.tmpl`): an
    RFC 8628 device-flow client for the seeded `hugmesh-desktop` public client,
    run by the session-start wrapper, writing the `oidc-token.src` drop the
    deposit reads, with an optional `pam_exec` logout clear. It is unit-tested
    end to end against the real deposit and mapper
    (`tests/desktop-governance/test-sso-token-producer.sh`) but has not been run
    against a live Casdoor or on an image, and a lightdm-greeter /
    password-grant PAM login (FD-07 proper) is still 🔭 DEFERRED. The whole leg
    stays inert until the governance flags flip and a governed image exists.

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
   when its ingest reports the device's host key and dial public-key fingerprint
   (the image-gen worker takes `DEVICE_ID` and `VAULT_REF` from the Job env and
   reports them back verbatim, and sends no `k8sSecretName`; it sends **no host
   key** today, `hostKeyPub`/`hostKeyFp` are null, because no channel carries a
   per-device host private key into a build, so no build seeds a row yet:
   hugmesh-admin-bff-api#53),
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
   been built. The SSO-sudo leg also stays inert until the SSO token producer
   (FD-07 increment 2, written but never run against a live Casdoor) has run on one.

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
The build bakes `/etc/hugmesh/{identity-role,domains,desktop-weight}` directly,
with no provision step for those. For the superadmin variant the build also
bakes `/etc/hugmesh/device-password-required`, and `provision_device_password()`
(called after `provision_users`) applies `device_password_hash` to the superadmin
account at first boot. A later `provision_casdoor_desktop()` will wire the OIDC
desktop login and the FD-07 keyslot. `device_registry.image_type=="client"`
already exists (inventory only).

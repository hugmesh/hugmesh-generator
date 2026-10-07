# Desktop app governance — client-image config templates

These are the **template** config files for the app-governance part of the FD-04
client images: the amd64 **laptop**, the thin **Chromebook** and the full
**desktop** variant. They are arch-agnostic, so they live in the shared
`specs/etc/hugmesh/...` tree. They are NOT in the protected `specs-x86/` portage
tree and NOT inline in `build-x86-host-stage4.sh`.

At **first boot**, `keys-provision`'s `provision_desktop_governance()`
(`specs/etc/keys-provision/provision.sh`) finds the node's own domain. It reads
`.client.primary_domain`, then `/etc/hugmesh/domains` (first or primary line),
then `.hugmesh.cluster_domain`. It then **renders** the NAMED config templates
(flatpakrepo, polkit, desktop-sudo mapper and its cron drop-in, bearer-forward)
into their live system locations and replaces the `@@CLUSTER_DOMAIN@@`
placeholder with the node's domain.

> **Delivery note (corrected).** The `provision_desktop_governance()` function
> renders only its *named* templates through `render_gov`. It has **no generic
> loop** and does **not** touch `/etc/xdg/autostart`. Neither the function nor
> the x86 builder (`build-x86-host-stage4.sh`) currently *bakes* this directory
> into the sysroot. Today the only working delivery is the **KEYS-USB
> fallback**: put `KEYS/desktop-governance/` on the (read-only) KEYS stick, and
> `provision_desktop_governance()` finds it through its
> `${BASE}/desktop-governance` branch. (A ready copy of the templates is in
> `keys-template/desktop-governance/`.) The earlier claim that "the build copies
> this whole dir into the sysroot" was stale and false.

The host is resolved at first boot from the baked domain marker. The config is
therefore correctly domain-parameterized whether or not `rebrand_sysroot` ran at
build time. A default-brand image still gets the right host, and a rebranded
image's `/etc/hugmesh/domains` already carries the brand domain.

## What gets configured (all DEFAULT-DENY / ships-dark)

1. **Plasma Discover / Flatpak → the admin-bff registry remote.** One Flatpak
   remote (`hugmesh-discover`) points at `https://api.<domain>/bff/desktop/registry`.
   **Flathub and every other default backend are disabled.** The remote is
   **empty by default**. Until a domain admin curates apps into the BFF registry
   (gated by the `discover` role), the store shows nothing. An empty store is the
   correct, non-error degrade state.

2. **PAM/polkit sudo gate via the `desktop-sudo` SSO claim — the SOLE sudo
   path.** The default is **NO sudo for anyone.** On a governed image the SSO
   claim is the only way to escalate.
   - `keys-provision` **suppresses** the per-user static
     `/etc/sudoers.d/10-<name>` grant and the standing `wheel`-group sudo that
     `provision_users` would otherwise write. A KEYS `sudo:true` means
     eligibility for the IdP claim, not a device-local sudoers entry.
     `provision_desktop_governance` also **strips any standing
     `sudoers.d`/`%wheel` grant** that already exists.
   - A polkit JS rule grants the admin/`exec` actions ONLY when the active
     session's user is in the `desktop-sudo` group.
   - The **desktop-sudo mapper** (root, 60s cron convergence floor) fills that
     group from the `desktop-sudo` claim or role in the session's deposited OIDC
     token for this domain. It first **verifies** the token against the issuer
     JWKS: RS256 signature, `iss`/`aud`/`exp`, and the token's `name` identity
     claim must equal the local username.
   - **Not SSSD.** Released SSSD's OAuth2 support (`id_provider = idp`, 2.11.0+)
     speaks only the Keycloak/Entra ID REST APIs through the device-auth grant.
     It has no token-claim→local-group mapping, so it cannot consume the
     deposited tokens of the per-domain Casdoor.
   - The admin-bff sudo-grant drives the claim at the IdP. **Revoking it at the
     IdP removes sudo at the deposited token's expiry at the latest, and logout
     removes it within the 60s cron floor.** Nothing on the device needs editing.
   - Runtime: `sys-auth/polkit` (the gate's authority) and `dev-lang/python` (the
     mapper) are declared in `specs-x86/portage/packages-desktop.list`, x86
     client only. The 60s floor rides the base `sys-process/cronie`. There is
     **no PAM module and no nsswitch change**: `desktop-sudo` is a LOCAL group,
     resolved by the stock `files` source.
   - `/run/user/<uid>/**` is user-writable and the mapper is root. So every
     component of the token path is opened `O_NOFOLLOW`, and the leaf must be a
     regular file opened `O_NONBLOCK`. A symlink cannot redirect root's read. A
     FIFO cannot wedge the run, and with it every pending revocation.

3. **SSO desktop-login bearer forwarded to the registry endpoint.** Discover's
   Flatpak backend reads the logged-in user's bearer token (deposited by the SSO
   desktop-login integration) and sends it on every request to the BFF registry.
   The BFF can then enforce the `discover` role, the domain lock and the
   enabled-only filter per user.

## Files

| template | rendered to | purpose |
|----------|-------------|---------|
| `flatpak/hugmesh-discover.flatpakrepo.tmpl` | `/etc/flatpak/remotes.d/hugmesh-discover.flatpakrepo` | the BFF-registry Flatpak remote (domain-parameterized) |
| `flatpak/flathub-disable.conf` | consumed by provisioning (removes/masks Flathub) | turn Flathub + default backends OFF |
| `polkit/49-hugmesh-desktop-sudo.rules` | `/etc/polkit-1/rules.d/49-hugmesh-desktop-sudo.rules` | sudo ONLY for the `desktop-sudo` group; else deny |
| `sudo/desktop-sudo-mapper.py.tmpl` | `/etc/hugmesh/desktop-governance/desktop-sudo-mapper` (0700) | JWKS-verified OIDC claim→group mapping (`desktop-sudo`), domain-parameterized issuer |
| `sudo/cron-desktop-sudo-mapper` | `/etc/cron.d/hugmesh-desktop-sudo-mapper` | the mapper's 60s convergence timer (grant within a minute; logout/expiry revocation floor) |
| `discover/bearer-forward.sh.tmpl` | `/etc/hugmesh/desktop-governance/bearer-forward.sh` (+ Flatpak `http.extra-headers`) | forward the SSO bearer to the registry host |

### GEN-SSO session-start (Seams #1 + #2)

These four NEW files close the two seams that were genuinely unwired. Nothing
deposited the OIDC token that bearer-forward reads (Seam #1), and nothing ran
bearer-forward at login (Seam #2). All four are **governed-gated + ships-dark**:
inert on an ungoverned image, or with no resolvable domain.

| template | rendered to | purpose |
|----------|-------------|---------|
| `discover/oidc-token-deposit.sh.tmpl` | `/etc/hugmesh/desktop-governance/oidc-token-deposit.sh` | **Seam #1.** Deposits the validated OIDC access token at `${XDG_RUNTIME_DIR}/hugmesh/oidc-token` (umask 077, pre-created 0600, never world-readable, never exported/logged). `--clear`/logout removes it. Token source: `HUGMESH_OIDC_ACCESS_TOKEN` (greeter/PAM-surfaced) or a user-private greeter drop; no source ⇒ empty store (fail closed). |
| `autostart/hugmesh-desktop-sso.desktop.tmpl` | `/etc/xdg/autostart/hugmesh-desktop-sso.desktop` | **Seam #2.** XDG autostart (no `OnlyShowIn` ⇒ honored by BOTH lxsession/LXDE and xfce4-session/XFCE) → the session-start wrapper. |
| `autostart/hugmesh-desktop-sso-start.sh.tmpl` | `/etc/hugmesh/desktop-governance/hugmesh-desktop-sso-start.sh` | Session-start wrapper: governed-gated; clears stale token/header first, installs an **LXDE/XFCE `~/.bash_logout` clear** (the merged bearer-forward's `plasma-workspace/shutdown/` hook is **Plasma-only and never fires on this image**), then chains deposit → bearer-forward once per login. |
| `autostart/session-install.sh.tmpl` | run as the KEYS `run[]` hook | Self-contained deployment glue (the no-`provision.sh`-edit vector): renders the three templates above with the SAME `@@CLUSTER_DOMAIN@@` substitution + fail-closed `[a-z0-9.-]` hostname validation + sed-escape as `provision.sh`, and publishes the `.desktop`. Idempotent, governed-gated, invalid-domain-refusing. |

### Session-start delivery (run[] hook)

`provision_desktop_governance()` is **protected**. It renders only its named
templates and has no `/etc/xdg/autostart` handling. A **KEYS `run[]` hook**
therefore deploys the three GEN-SSO templates. `keys-provision`'s
`provision_run_hooks()` runs that hook **as root at the end of first boot**
(with `KEYS_BASE` exported), **after** `provision_desktop_governance()` has run.
Wire it in the KEYS `provision.json`:

```json
"run": [ "desktop-governance/session-install.sh" ]
```

A ready-to-run `0755` copy lives at `keys-template/desktop-governance/session-install.sh`,
so that exact `run[]` entry resolves directly. We do **not** add the entry to the
shared `keys-template/provision.json` example: all node types use it, and JSON
has no comments.

### RESIDUAL #9a — `hugmesh-desktop` PKCE public client

The desktop-governance config points the desktop login at the `hugmesh-desktop`
client id (a PKCE public client). `casdoor-init` once did **not** seed it, so the
login could obtain no token, the `desktop-sudo` claim was never issuable, and
SSO-sudo was inert. That is fixed: `reconcile_desktop_client()` in
`specs/cluster/manifests/casdoor/init-job.yaml` seeds the client (PUBLIC client,
empty secret, PKCE, JWT tokens, native/loopback+OOB redirects,
`authorization_code`+`device_code`), and `init-data-configmap.yaml` seeds the
`desktop-sudo` role. The exact Casdoor object shape is version-specific. Validate
it against the deployed Casdoor.

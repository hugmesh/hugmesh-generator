# Desktop app governance — client-image config templates

These are the **template** config files for the desktop app-governance leg of the
FD-04 client images (amd64 **laptop** + thin **Chromebook**, and the full
**desktop** variant). They are arch-agnostic, so they live under the shared
`specs/etc/hugmesh/...` tree (NOT under the protected `specs-x86/` portage
tree and NOT inline in `build-x86-host-stage4.sh`).

At **first boot**, `keys-provision`'s `provision_desktop_governance()`
(`specs/etc/keys-provision/provision.sh`) reads the node's own domain from
`.client.primary_domain` → `/etc/hugmesh/domains` (first/primary line) →
`.hugmesh.cluster_domain` and **renders** the NAMED config templates
(flatpakrepo, polkit, desktop-sudo mapper + its cron drop-in, bearer-forward)
into their live system locations, substituting the `@@CLUSTER_DOMAIN@@`
placeholder with the node's domain.

> **Delivery note (corrected).** The `provision_desktop_governance()` function
> render_gov's only its *named* templates — it has **no generic loop** and
> does **not** touch `/etc/xdg/autostart`. Neither the function nor the x86
> builder (`build-x86-host-stage4.sh`) currently *bakes* this directory into the
> sysroot, so the only working delivery today is the **KEYS-USB fallback**: drop
> `KEYS/desktop-governance/` on the (read-only) KEYS stick and
> `provision_desktop_governance()` finds it via its `${BASE}/desktop-governance`
> branch. The earlier "the build copies this whole dir into the sysroot" claim
> was stale/false.

Because the host is resolved at first boot from the baked domain marker, the
config is correctly domain-parameterized whether or not `rebrand_sysroot` ran at
build time (a default-brand image still gets the right host, and a rebranded
image's `/etc/hugmesh/domains` already carries the brand domain).

## What gets configured (all DEFAULT-DENY / ships-dark)

1. **Plasma Discover / Flatpak → the admin-bff registry remote.** A single
   Flatpak remote (`hugmesh-discover`) points at
   `https://api.<domain>/bff/desktop/registry`. **Flathub and every other default
   backend are disabled.** The remote is **empty by default** — until a domain
   admin curates apps into the BFF registry (gated by the `discover` role), the
   store shows nothing. An empty store is the correct, non-error degrade state.

2. **PAM/polkit sudo gate via the `desktop-sudo` SSO claim — the SOLE sudo
   path.** Default = **NO sudo for anyone.** On a governed image the SSO claim is
   the only escalation route: `keys-provision` **suppresses the per-user static
   `/etc/sudoers.d/10-<name>` grant and the standing `wheel`-group sudo
   conferral** that `provision_users` would otherwise write (a KEYS `sudo:true`
   is treated as IdP-claim eligibility, not a device-local sudoers entry), and
   `provision_desktop_governance` additionally **strips any pre-existing standing
   `sudoers.d`/`%wheel` grant**. A polkit JS rule then grants the admin/`exec`
   actions ONLY when the active session's user is in the `desktop-sudo` group,
   which the **desktop-sudo mapper** (root, 60s cron convergence floor) populates
   from the `desktop-sudo` claim/role carried in the session's deposited OIDC
   token for this domain — after **verifying** the token against the issuer JWKS
   (RS256 signature, `iss`/`aud`/`exp`, and the token's `name` identity claim
   must equal the local username). **Not SSSD:** released SSSD's OAuth2 support
   (`id_provider = idp`, 2.11.0+) speaks only the Keycloak/Entra ID REST APIs
   via the device-auth grant and has no token-claim→local-group mapping, so it
   cannot consume the per-domain Casdoor's deposited tokens. The admin-bff
   sudo-grant drives the claim at the IdP; **revoking it at the IdP removes sudo
   at the deposited token's expiry at the latest, and logout removes it within
   the 60s cron floor** — nothing on the device needs editing.
   Runtime: `sys-auth/polkit` (the gate's authority) and `dev-lang/python` (the
   mapper) are declared in `specs-x86/portage/packages-desktop.list`, x86-client
   only; the 60s floor rides the base `sys-process/cronie`. **No PAM module and
   no nsswitch change** — `desktop-sudo` is a LOCAL group, resolved by the stock
   `files` source. Because `/run/user/<uid>/**` is user-writable while the mapper
   is root, every component of the token path is opened `O_NOFOLLOW` and the leaf
   must be a regular file opened `O_NONBLOCK` (a symlink cannot redirect root's
   read; a FIFO cannot wedge the run and with it every pending revocation).

3. **SSO desktop-login bearer forwarded to the registry endpoint.** Discover's
   Flatpak backend reads the logged-in user's bearer token (deposited by the
   SSO desktop-login integration) and sends it on every request to the BFF
   registry, so the BFF can enforce the `discover` role + domain lock + the
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

These four NEW files close the two genuinely-unwired seams: nothing deposited the
OIDC token bearer-forward reads (Seam #1), and bearer-forward was never invoked at
login (Seam #2). All are **governed-gated + ships-dark** (inert on an ungoverned
image / with no resolvable domain).

| template | rendered to | purpose |
|----------|-------------|---------|
| `discover/oidc-token-deposit.sh.tmpl` | `/etc/hugmesh/desktop-governance/oidc-token-deposit.sh` | **Seam #1.** Deposits the validated OIDC access token at `${XDG_RUNTIME_DIR}/hugmesh/oidc-token` (umask 077, pre-created 0600, never world-readable, never exported/logged). `--clear`/logout removes it. Token source: `HUGMESH_OIDC_ACCESS_TOKEN` (greeter/PAM-surfaced) or the user-private drop `oidc-token.src`, which `sso/hugmesh-sso-token` writes; no source ⇒ empty store (fail closed). `--clear` (session start) removes only the deposit, so a drop made before the session survives; `--clear-all` (logout) also removes the drop and the producer's refresh token. |
| `sso/hugmesh-sso-token.py.tmpl` | `/etc/hugmesh/desktop-governance/hugmesh-sso-token` | **The token producer** (FD-07 increment 2). RFC 8628 device-authorization flow against the `hugmesh-desktop` public client (the grant it is already seeded with; NOT the password grant, which the client does not have): shows a code + URL, polls, and writes the access token to the `oidc-token.src` drop (0600 in a 0700 dir, atomic, no symlink follow). `login [--if-needed]`, `refresh`, `clear`, `status`, `--pam` (pam_exec: `close_session` clears, everything else is a no-op that cannot fail a login). Run by the session-start wrapper before the deposit. It is not a trust anchor: the mapper re-verifies the token on every run. Rendered by `session-install.sh`. |
| `autostart/hugmesh-desktop-sso.desktop.tmpl` | `/etc/xdg/autostart/hugmesh-desktop-sso.desktop` | **Seam #2.** XDG autostart (no `OnlyShowIn` ⇒ honored by BOTH lxsession/LXDE and xfce4-session/XFCE) → the session-start wrapper. |
| `autostart/hugmesh-desktop-sso-start.sh.tmpl` | `/etc/hugmesh/desktop-governance/hugmesh-desktop-sso-start.sh` | Session-start wrapper: governed-gated; clears stale token/header first, installs an **LXDE/XFCE `~/.bash_logout` clear** (the merged bearer-forward's `plasma-workspace/shutdown/` hook is **Plasma-only and never fires on this image**), then chains deposit → bearer-forward once per login. |
| `autostart/session-install.sh.tmpl` | run as the KEYS `run[]` hook | Self-contained deployment glue (the no-`provision.sh`-edit vector): renders the templates above (producer, deposit, wrapper, autostart) with the SAME `@@CLUSTER_DOMAIN@@` substitution + fail-closed `[a-z0-9.-]` hostname validation + sed-escape as `provision.sh`, and publishes the `.desktop`. Idempotent, governed-gated, invalid-domain-refusing. |

### Token producer: contract, PAM hook, what is not proven

Contract with the consumers (pinned by `tests/desktop-governance/test-sso-token-producer.sh`,
which runs the REAL deposit and the REAL mapper on the producer's output): the
producer writes the raw access token (JWT-Custom RS256, `name` = the local
username, `aud` `hugmesh-desktop`, `roles` with `desktop-sudo`) to
`${XDG_RUNTIME_DIR}/hugmesh/oidc-token.src`. It refuses to store a token whose
`name` is not the local user or that is already expired, but it is not the
authority: the mapper re-verifies signature, `iss`, `aud`, `exp` and identity.

Optional PAM hook, NOT wired by anything in this repo (a change to a live
`/etc/pam.d` stack is for the image builder and needs a boot to prove). The
useful stage is logout, because the graphical session is not a login shell and
`~/.bash_logout` need not run:

    session optional pam_exec.so quiet seteuid /etc/hugmesh/desktop-governance/hugmesh-sso-token --pam

`close_session` clears the drop and the refresh token (closing one of a user's
several sessions revokes sudo for all of them until the next sign-in: fail
closed). `open_session` is a no-op. The device flow itself cannot run inside
`pam_exec`, which has no conversation, so sign-in happens in the user session via
the autostart wrapper, with a `zenity`/`yad`/`notify-send` prompt when a display
exists. A greeter or PAM stage that drops a valid token first is honoured
(`login --if-needed`).

NOT proven: that a live Casdoor serves `/api/device-auth` and the device-code
grant the way the fake issuer does (discovery is tried first, Casdoor's fixed
paths are the fallback); the lightdm greeter or any image boot; the prompt on a
real desktop. A password-based PAM module (disk/login password verified at the IdP)
would need the `hugmesh-desktop` client to gain the password grant and local
password == IdP password; that is a security decision, deliberately not made here.

### Session-start delivery (run[] hook)

`provision_desktop_governance()` is **protected** and renders only its named
templates with no `/etc/xdg/autostart` handling, so the three GEN-SSO templates are
deployed by a **KEYS `run[]` hook** that `keys-provision`'s `provision_run_hooks()`
runs **as root at end of first boot** (with `KEYS_BASE` exported), **after**
`provision_desktop_governance()` has run. Wire it in the KEYS `provision.json`:

```json
"run": [ "desktop-governance/session-install.sh" ]
```

A ready-to-run `0755` copy lives at `keys-template/desktop-governance/session-install.sh`
so that exact `run[]` entry resolves directly. (We do **not** add the entry to the
shared `keys-template/provision.json` example — it is used by all node types and
JSON has no comments.)

### RESIDUAL #9a — `hugmesh-desktop` PKCE public client

The desktop-governance config points the desktop login at the `hugmesh-desktop`
client id (a PKCE public client) but `casdoor-init` did **not** seed it — so the
login could obtain no token, the `desktop-sudo` claim was never issuable, and
SSO-sudo was inert. This PR adds `reconcile_desktop_client()` to
`specs/cluster/manifests/casdoor/init-job.yaml` (PUBLIC client, empty secret, PKCE,
JWT tokens, native/loopback+OOB redirects, `authorization_code`+`device_code`) and
seeds the `desktop-sudo` role in `init-data-configmap.yaml`. The exact Casdoor
object shape is version-specific — validate against the deployed Casdoor.

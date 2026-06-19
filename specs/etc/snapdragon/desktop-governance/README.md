# Desktop app governance — client-image config templates

These are the **template** config files for the desktop app-governance leg of the
FD-04 client images (amd64 **laptop** + thin **Chromebook**, and the full
**desktop** variant). They are arch-agnostic, so they live under the shared
`specs/etc/snapdragon/...` tree (NOT under the protected `specs-x86/` portage
tree and NOT inline in `build-x86-host-stage4.sh`).

At **first boot**, `keys-provision`'s `provision_desktop_governance()`
(`specs/etc/keys-provision/provision.sh`) reads the node's own domain from
`.client.primary_domain` → `/etc/snapdragon/domains` (first/primary line) →
`.snapdragon.cluster_domain` and **renders** the FOUR NAMED config templates
(flatpakrepo, polkit, sssd, bearer-forward) into their live system locations,
substituting the `@@CLUSTER_DOMAIN@@` placeholder with the node's domain.

> **Delivery note (corrected).** The `provision_desktop_governance()` function
> render_gov's only its four *named* templates — it has **no generic loop** and
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
image's `/etc/snapdragon/domains` already carries the brand domain).

## What gets configured (all DEFAULT-DENY / ships-dark)

1. **Plasma Discover / Flatpak → the admin-bff registry remote.** A single
   Flatpak remote (`snapdragon-discover`) points at
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
   which SSSD-OIDC populates from the `desktop-sudo` claim/role carried in the
   user's OIDC token for this domain. The admin-bff sudo-grant drives that claim
   at the IdP; **revoking it at the IdP removes sudo at the next login / token
   refresh** — nothing on the device needs editing.

3. **SSO desktop-login bearer forwarded to the registry endpoint.** Discover's
   Flatpak backend reads the logged-in user's bearer token (deposited by the
   SSO desktop-login integration) and sends it on every request to the BFF
   registry, so the BFF can enforce the `discover` role + domain lock + the
   enabled-only filter per user.

## Files

| template | rendered to | purpose |
|----------|-------------|---------|
| `flatpak/snapdragon-discover.flatpakrepo.tmpl` | `/etc/flatpak/remotes.d/snapdragon-discover.flatpakrepo` | the BFF-registry Flatpak remote (domain-parameterized) |
| `flatpak/flathub-disable.conf` | consumed by provisioning (removes/masks Flathub) | turn Flathub + default backends OFF |
| `polkit/49-snapdragon-desktop-sudo.rules` | `/etc/polkit-1/rules.d/49-snapdragon-desktop-sudo.rules` | sudo ONLY for the `desktop-sudo` group; else deny |
| `sssd/snapdragon-oidc.conf.tmpl` | `/etc/sssd/conf.d/snapdragon-oidc.conf` | OIDC claim→group mapping (`desktop-sudo`), domain-parameterized issuer |
| `discover/bearer-forward.sh.tmpl` | `/etc/snapdragon/desktop-governance/bearer-forward.sh` (+ Flatpak `http.extra-headers`) | forward the SSO bearer to the registry host |

### GEN-SSO session-start (Seams #1 + #2)

These four NEW files close the two genuinely-unwired seams: nothing deposited the
OIDC token bearer-forward reads (Seam #1), and bearer-forward was never invoked at
login (Seam #2). All are **governed-gated + ships-dark** (inert on an ungoverned
image / with no resolvable domain).

| template | rendered to | purpose |
|----------|-------------|---------|
| `discover/oidc-token-deposit.sh.tmpl` | `/etc/snapdragon/desktop-governance/oidc-token-deposit.sh` | **Seam #1.** Deposits the validated OIDC access token at `${XDG_RUNTIME_DIR}/snapdragon/oidc-token` (umask 077, pre-created 0600, never world-readable, never exported/logged). `--clear`/logout removes it. Token source: `SNAPDRAGON_OIDC_ACCESS_TOKEN` (greeter/PAM-surfaced) or a user-private greeter drop; no source ⇒ empty store (fail closed). |
| `autostart/snapdragon-desktop-sso.desktop.tmpl` | `/etc/xdg/autostart/snapdragon-desktop-sso.desktop` | **Seam #2.** XDG autostart (no `OnlyShowIn` ⇒ honored by BOTH lxsession/LXDE and xfce4-session/XFCE) → the session-start wrapper. |
| `autostart/snapdragon-desktop-sso-start.sh.tmpl` | `/etc/snapdragon/desktop-governance/snapdragon-desktop-sso-start.sh` | Session-start wrapper: governed-gated; clears stale token/header first, installs an **LXDE/XFCE `~/.bash_logout` clear** (the merged bearer-forward's `plasma-workspace/shutdown/` hook is **Plasma-only and never fires on this image**), then chains deposit → bearer-forward once per login. |
| `autostart/session-install.sh.tmpl` | run as the KEYS `run[]` hook | Self-contained deployment glue (the no-`provision.sh`-edit vector): renders the three templates above with the SAME `@@CLUSTER_DOMAIN@@` substitution + fail-closed `[a-z0-9.-]` hostname validation + sed-escape as `provision.sh`, and publishes the `.desktop`. Idempotent, governed-gated, invalid-domain-refusing. |

### Session-start delivery (run[] hook)

`provision_desktop_governance()` is **protected** and renders only its four named
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

### RESIDUAL #9a — `snapdragon-desktop` PKCE public client

The SSSD-OIDC conf points the desktop login at `oidc_client_id = snapdragon-desktop`
(a PKCE public client) but `casdoor-init` did **not** seed it — so the login could
obtain no token, the `desktop-sudo` claim was never issuable, and SSO-sudo was
inert. This PR adds `reconcile_desktop_client()` to
`specs/cluster/manifests/casdoor/init-job.yaml` (PUBLIC client, empty secret, PKCE,
JWT tokens, native/loopback+OOB redirects, `authorization_code`+`device_code`) and
seeds the `desktop-sudo` role in `init-data-configmap.yaml`. The exact Casdoor
object shape is version-specific — validate against the deployed Casdoor.

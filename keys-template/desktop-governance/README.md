# KEYS/desktop-governance/ — desktop app-governance config (OPTIONAL)

Drop this directory on the KEYS USB to enable **desktop app governance** on a
client desktop (laptop / chromebook / desktop) WITHOUT rebuilding the image.

At first boot `provision_desktop_governance()`
(`specs/etc/keys-provision/provision.sh`) checks for baked templates at
`/etc/hugmesh/desktop-governance/`; if absent, it uses **this** directory
(`KEYS/desktop-governance/`) instead, then renders the templates into their live
system locations, substituting the `@@CLUSTER_DOMAIN@@` placeholder with the
node's own domain (resolved from `.client.primary_domain` →
`/etc/hugmesh/domains` → `.hugmesh.cluster_domain`). STANDALONE images
(`/etc/hugmesh/standalone`) skip this step entirely.

## What it configures (all DEFAULT-DENY / ships-dark)

- **Discover → admin-bff registry remote** at `https://api.<domain>/bff/desktop/registry/`,
  with the `flathub`, `flathub-beta`, `gnome-nightly`, `kdeapps` and `fedora`
  remotes removed (`flatpak/flathub-disable.conf`). Empty until a domain admin
  curates apps (gated by the `discover` role). An empty store is the correct
  state, not an error.
- **polkit sudo gate — the SOLE sudo path on a governed image**: keys-provision
  suppresses the per-user static `/etc/sudoers.d` grant + standing `wheel`-group
  sudo (a KEYS `sudo:true` becomes IdP-claim eligibility, not a device sudoers
  entry) and strips any pre-existing standing grant, so sudo flows only through
  the `desktop-sudo` group, which the **desktop-sudo mapper** (root, 60s cron)
  populates from the JWKS-VERIFIED `desktop-sudo` OIDC claim in the session's
  deposited token for this domain. (Not SSSD: released SSSD's `id_provider=idp`
  speaks only Keycloak/Entra REST APIs and has no claim→group mapping.) The
  admin-bff sudo-grant drives the claim; revoke at the IdP → sudo gone at the
  deposited token's expiry; logout → gone within the 60s cron floor. Needs no
  PAM/nsswitch change (`desktop-sudo` is a local group); the image's polkit +
  python3 + cronie are all it runs on.
- **SSO bearer forwarded** to the registry host so Discover authenticates as the
  logged-in user.

## Not secrets

These files carry hosts and the `desktop-sudo` claim NAME only — never tokens or
keys. They may be copied as-is. The bearer token is deposited per-session by the
SSO desktop-login at runtime, never staged here; the mapper verifies it against
the issuer's PUBLIC JWKS (fetched at runtime, last-good cached).

## GEN-SSO session-start (Seams #1 + #2)

`provision_desktop_governance()` renders only the config templates above; it
does **not** deposit the OIDC token bearer-forward needs (Seam #1) nor invoke
bearer-forward at login (Seam #2). Those are delivered by these NEW files +
a KEYS `run[]` hook (all governed-gated + ships-dark):

- `discover/oidc-token-deposit.sh.tmpl` → deposits the SSO access token at
  `${XDG_RUNTIME_DIR}/hugmesh/oidc-token` (per-user, 0600, never exported,
  `--clear` on logout); inert when ungoverned / no token (empty store). It reads
  the token from `HUGMESH_OIDC_ACCESS_TOKEN` or `oidc-token.src` in the same
  directory. Nothing in this repo sets either, so until the SSO greeter does,
  the token is empty.
- `autostart/hugmesh-desktop-sso.desktop.tmpl` → XDG autostart (LXDE + XFCE,
  no `OnlyShowIn`) → the session-start wrapper.
- `autostart/hugmesh-desktop-sso-start.sh.tmpl` → session-start wrapper:
  clears stale token/header, installs an LXDE/XFCE `~/.bash_logout` clear (the
  merged bearer-forward's Plasma-only `shutdown/` hook never fires here), chains
  deposit → bearer-forward.
- `autostart/session-install.sh.tmpl` (+ a ready-to-run `session-install.sh` at
  this dir root) → renders the three templates and publishes the `.desktop`,
  resolving the domain from `/etc/hugmesh/domains`, else from the `Url=` of the
  rendered `hugmesh-discover.flatpakrepo`, with the SAME fail-closed `[a-z0-9.-]`
  validation as `provision.sh`.

### Wire the run[] hook

Add to your KEYS `provision.json` so it runs as root at end of first boot, after
`provision_desktop_governance()`:

```json
"run": [ "desktop-governance/session-install.sh" ]
```

### RESIDUAL #9a

The desktop SSO login uses the `hugmesh-desktop` client id (PKCE public
client). `casdoor-init` seeds that client (`specs/cluster/manifests/casdoor/init-job.yaml`,
`reconcile_desktop_client`) and the `desktop-sudo` role
(`init-data-configmap.yaml`); without them SSO-sudo is inert.

## Files

Mirror of `specs/etc/hugmesh/desktop-governance/`, plus the ready-to-run
`session-install.sh` — edit in place if a domain
needs a different store title / remote layout, but keep `@@CLUSTER_DOMAIN@@`
intact so first-boot domain substitution works.

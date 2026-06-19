# KEYS/desktop-governance/ — desktop app-governance config (OPTIONAL)

Drop this directory on the KEYS USB to enable **desktop app governance** on a
client desktop (laptop / chromebook / desktop) WITHOUT rebuilding the image.

At first boot `provision_desktop_governance()`
(`specs/etc/keys-provision/provision.sh`) checks for baked templates at
`/etc/snapdragon/desktop-governance/`; if absent, it uses **this** directory
(`KEYS/desktop-governance/`) instead, then renders the templates into their live
system locations, substituting the `@@CLUSTER_DOMAIN@@` placeholder with the
node's own domain (resolved from `.client.primary_domain` →
`/etc/snapdragon/domains` → `.snapdragon.cluster_domain`).

## What it configures (all DEFAULT-DENY / ships-dark)

- **Discover → admin-bff registry remote** at `https://api.<domain>/bff/desktop/registry/`,
  with **Flathub + every default backend disabled**. Empty until a domain admin
  curates apps (gated by the `discover` role). An empty store is the correct
  state, not an error.
- **polkit sudo gate — the SOLE sudo path on a governed image**: keys-provision
  suppresses the per-user static `/etc/sudoers.d` grant + standing `wheel`-group
  sudo (a KEYS `sudo:true` becomes IdP-claim eligibility, not a device sudoers
  entry) and strips any pre-existing standing grant, so sudo flows only through
  the `desktop-sudo` group, which SSSD-OIDC populates from the `desktop-sudo`
  OIDC claim for this domain. The admin-bff sudo-grant drives the claim; revoke
  at the IdP → sudo gone at next login.
- **SSO bearer forwarded** to the registry host so Discover authenticates as the
  logged-in user.

## Not secrets

These files carry hosts and the `desktop-sudo` claim NAME only — never tokens or
keys. They may be copied as-is. The bearer token is deposited per-session by the
SSO desktop-login at runtime, never staged here.

## GEN-SSO session-start (Seams #1 + #2)

`provision_desktop_governance()` renders only the four config templates above; it
does **not** deposit the OIDC token bearer-forward needs (Seam #1) nor invoke
bearer-forward at login (Seam #2). Those are delivered by these NEW files +
a KEYS `run[]` hook (all governed-gated + ships-dark):

- `discover/oidc-token-deposit.sh.tmpl` → deposits the SSO access token at
  `${XDG_RUNTIME_DIR}/snapdragon/oidc-token` (per-user, 0600, never exported,
  `--clear` on logout); inert when ungoverned / no token (empty store).
- `autostart/snapdragon-desktop-sso.desktop.tmpl` → XDG autostart (LXDE + XFCE,
  no `OnlyShowIn`) → the session-start wrapper.
- `autostart/snapdragon-desktop-sso-start.sh.tmpl` → session-start wrapper:
  clears stale token/header, installs an LXDE/XFCE `~/.bash_logout` clear (the
  merged bearer-forward's Plasma-only `shutdown/` hook never fires here), chains
  deposit → bearer-forward.
- `autostart/session-install.sh.tmpl` (+ a ready-to-run `session-install.sh` at
  this dir root) → renders the three templates and publishes the `.desktop`,
  with the SAME domain resolution + fail-closed `[a-z0-9.-]` validation as
  `provision.sh`.

### Wire the run[] hook

Add to your KEYS `provision.json` so it runs as root at end of first boot, after
`provision_desktop_governance()`:

```json
"run": [ "desktop-governance/session-install.sh" ]
```

### RESIDUAL #9a

The desktop SSO login uses `oidc_client_id = snapdragon-desktop` (PKCE public
client). This PR seeds that client + the `desktop-sudo` role in `casdoor-init`
(`specs/cluster/manifests/casdoor/`); without it SSO-sudo is inert.

## Files

Mirror of `specs/etc/snapdragon/desktop-governance/` — edit in place if a domain
needs a different store title / remote layout, but keep `@@CLUSTER_DOMAIN@@`
intact so first-boot domain substitution works.

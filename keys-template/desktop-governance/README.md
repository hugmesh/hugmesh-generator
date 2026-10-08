# KEYS/desktop-governance/ — desktop app-governance config (OPTIONAL)

Put this directory on the KEYS USB to turn on **desktop app governance** on a
client desktop (laptop / chromebook / desktop) without rebuilding the image.

At first boot `provision_desktop_governance()`
(`specs/etc/keys-provision/provision.sh`) looks for baked templates in
`/etc/hugmesh/desktop-governance/`. If they are absent, it uses **this**
directory (`KEYS/desktop-governance/`). It renders the templates into their live
system locations and replaces the `@@CLUSTER_DOMAIN@@` placeholder with the
node's own domain (resolved from `.client.primary_domain` →
`/etc/hugmesh/domains` → `.hugmesh.cluster_domain`). STANDALONE images
(`/etc/hugmesh/standalone`) skip this step entirely.

## What it configures (all DEFAULT-DENY / ships-dark)

- **Discover → admin-bff registry remote** at `https://api.<domain>/bff/desktop/registry/`.
  The `flathub`, `flathub-beta`, `gnome-nightly`, `kdeapps` and `fedora` remotes
  are removed (`flatpak/flathub-disable.conf`). The store stays empty until a
  domain admin curates apps (gated by the `discover` role). An empty store is the
  correct state, not an error.
- **polkit sudo gate — the SOLE sudo path on a governed image.** keys-provision
  suppresses the per-user static `/etc/sudoers.d` grant and the standing
  `wheel`-group sudo. A KEYS `sudo:true` then means eligibility through an IdP
  claim, not a sudoers entry. It also strips any standing grant already there.
  Sudo flows only through the `desktop-sudo` group. The **desktop-sudo mapper**
  (root, 60s cron) fills that group from the JWKS-VERIFIED `desktop-sudo` OIDC
  claim in the session's deposited token for this domain. (Not SSSD: released
  SSSD's `id_provider=idp` speaks only Keycloak/Entra REST APIs and has no
  claim→group mapping.) The admin-bff sudo-grant drives the claim. Revoke at the
  IdP and sudo ends when the deposited token expires. Logging out ends it within
  the 60s cron floor. No PAM/nsswitch change is needed (`desktop-sudo` is a local
  group). The image's polkit, python3 and cronie are all it runs on.
- **SSO bearer forwarded** to the registry host, so Discover authenticates as the
  logged-in user.

## Not secrets

These files hold hosts and the `desktop-sudo` claim NAME only, never tokens or
keys. Copy them as they are. The SSO desktop-login deposits the bearer token per
session at runtime. It is never staged here. The mapper checks it against the
issuer's PUBLIC JWKS (fetched at runtime, last-good cached).

## GEN-SSO session-start (Seams #1 + #2)

`provision_desktop_governance()` renders only the config templates above. It does
**not** deposit the OIDC token that bearer-forward needs (Seam #1), and it does
not invoke bearer-forward at login (Seam #2). These new files and a KEYS `run[]`
hook deliver both (all governed-gated and ships-dark):

- `discover/oidc-token-deposit.sh.tmpl` → deposits the SSO access token at
  `${XDG_RUNTIME_DIR}/hugmesh/oidc-token` (per-user, 0600, never exported,
  `--clear` on logout). Inert when ungoverned or when there is no token (empty
  store). It reads the token from `HUGMESH_OIDC_ACCESS_TOKEN` or `oidc-token.src`
  in the same directory. Nothing in this repo sets either, so until the SSO
  greeter does, the token is empty.
- `autostart/hugmesh-desktop-sso.desktop.tmpl` → XDG autostart (LXDE + XFCE, no
  `OnlyShowIn`) → the session-start wrapper.
- `autostart/hugmesh-desktop-sso-start.sh.tmpl` → session-start wrapper. It
  clears the stale token and header, installs an LXDE/XFCE `~/.bash_logout` clear
  (the merged bearer-forward's Plasma-only `shutdown/` hook never fires here), and
  chains deposit → bearer-forward.
- `autostart/session-install.sh.tmpl` (plus a ready-to-run `session-install.sh` at
  the root of this directory) → renders the three templates and publishes the
  `.desktop`. It resolves the domain from `/etc/hugmesh/domains`, else from the
  `Url=` of the rendered `hugmesh-discover.flatpakrepo`, with the SAME fail-closed
  `[a-z0-9.-]` validation as `provision.sh`.

### Wire the run[] hook

Add this to your KEYS `provision.json`. It runs as root at the end of first boot,
after `provision_desktop_governance()`:

```json
"run": [ "desktop-governance/session-install.sh" ]
```

### RESIDUAL #9a

The desktop SSO login uses the `hugmesh-desktop` client id (PKCE public client).
`casdoor-init` seeds that client (`specs/cluster/manifests/casdoor/init-job.yaml`,
`reconcile_desktop_client`) and the `desktop-sudo` role
(`init-data-configmap.yaml`). Without them SSO-sudo is inert.

## Files

Mirror of `specs/etc/hugmesh/desktop-governance/`, plus the ready-to-run
`session-install.sh`. Edit in place if a domain needs a different store title or
remote layout. Keep `@@CLUSTER_DOMAIN@@` intact, or first-boot domain
substitution breaks.

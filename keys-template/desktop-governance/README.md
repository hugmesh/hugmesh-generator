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
- **polkit sudo gate**: NO static sudoers; sudo only for the `desktop-sudo`
  group, which SSSD-OIDC populates from the `desktop-sudo` OIDC claim for this
  domain. The admin-bff sudo-grant drives the claim; revoke at the IdP → sudo
  gone at next login.
- **SSO bearer forwarded** to the registry host so Discover authenticates as the
  logged-in user.

## Not secrets

These files carry hosts and the `desktop-sudo` claim NAME only — never tokens or
keys. They may be copied as-is. The bearer token is deposited per-session by the
SSO desktop-login at runtime, never staged here.

## Files

Mirror of `specs/etc/snapdragon/desktop-governance/` — edit in place if a domain
needs a different store title / remote layout, but keep `@@CLUSTER_DOMAIN@@`
intact so first-boot domain substitution works.

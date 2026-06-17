# Desktop app governance — client-image config templates

These are the **template** config files for the desktop app-governance leg of the
FD-04 client images (amd64 **laptop** + thin **Chromebook**, and the full
**desktop** variant). They are arch-agnostic, so they live under the shared
`specs/etc/snapdragon/...` tree (NOT under the protected `specs-x86/` portage
tree and NOT inline in `build-x86-host-stage4.sh`).

The image build copies this whole directory into the sysroot at
`/etc/snapdragon/desktop-governance/` (see the `ROLE_CLIENT` leg of the build:
`provision_files` / the shared-specs copy step). At **first boot**,
`keys-provision`'s `provision_desktop_governance()`
(`specs/etc/keys-provision/provision.sh`) reads the node's own domain from
`/etc/snapdragon/domains` (one domain per line; the first/primary is used) and
**renders** these templates into their live system locations, substituting the
`@@CLUSTER_DOMAIN@@` placeholder with the node's domain.

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

2. **PAM/polkit sudo gate via the `desktop-sudo` SSO claim.** Default = **NO
   sudo for anyone.** There is **no static sudoers entry**. A polkit JS rule
   grants the admin/`exec` actions ONLY when the active session's user is in the
   `desktop-sudo` group, which SSSD-OIDC populates from the `desktop-sudo`
   claim/role carried in the user's OIDC token for this domain. The admin-bff
   sudo-grant drives that claim at the IdP; **revoking it at the IdP removes sudo
   at the next login / token refresh** — nothing on the device needs editing.

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

# KEYS / cloudflared — PROD go-live tunnel credentials (OPT-IN)

This folder carries the Cloudflare Tunnel credential for an **ENV=prod** image's
public edge (`apps/12-cloudflared.yaml` + `manifests/cloudflared/`). It is
**read-if-present**: absent => the cloudflared Deployment stays down harmlessly
and nothing else is affected. In **ENV=test** images the cloudflared app is
pruned at build time, so this folder is never consulted.

## What goes here

Pick ONE of the two cloudflared auth styles:

1. **Token tunnel (simplest).** Put the dashboard-issued tunnel token in
   `tunnel-token` (single line, no newline). keys-provision writes it to Vault at
   `secret/<brand>/cloudflared` under property `tunnel_token`; the
   `cloudflared-tunnel-token` ExternalSecret materializes it into the
   `TUNNEL_TOKEN` env the Deployment consumes.

2. **Named tunnel + credentials.json.** Put `credentials.json` (from
   `cloudflared tunnel create`) here and set the `tunnel:` / `credentials-file:`
   keys in `manifests/cloudflared/configmap.yaml`. Same Vault path; store the
   file's contents as the `credentials_json` property.

## Files

    tunnel-token            (SECRET — gitignored) the Cloudflare tunnel token
    credentials.json        (SECRET — gitignored) named-tunnel credentials (alt.)
    tunnel-token.example    committed placeholder showing the expected format

Real values are gitignored (`*.json`, and the `tunnel-token` patterns below);
only the `.example` placeholder is committed. NEVER commit a real token.

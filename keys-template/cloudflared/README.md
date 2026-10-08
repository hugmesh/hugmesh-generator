# KEYS / cloudflared — PROD go-live tunnel credentials (OPT-IN)

This folder carries the Cloudflare Tunnel credential for an **ENV=prod** image's
public edge (`apps/12-cloudflared.yaml` + `manifests/cloudflared/`). It is
**read-if-present**: absent => the cloudflared Deployment stays down harmlessly
and nothing else is affected. In **ENV=test** images the cloudflared app is
pruned at build time, so this folder is never consulted.

## What goes here

The Deployment supports ONE auth style today: the token tunnel.

1. **Token tunnel.** Put the dashboard-issued tunnel token in `tunnel-token`
   (single line, no newline). `hugmesh-go-live plan --provider cloudflare-tunnel
   --token-file FILE` stores a copy at `/etc/hugmesh/keys/cloudflared/tunnel-token`
   on the node (`--keys-dir` changes the base). **No script reads this file.** keys-provision does not touch
   `cloudflared/`, and nothing else copies it to Vault. An operator must store the
   token in Vault at `secret/<brand>/cloudflared`, property `tunnel_token`. The
   `cloudflared-tunnel-token` ExternalSecret then materializes it into the
   `TUNNEL_TOKEN` env the Deployment consumes.

2. **Named tunnel + credentials.json (NOT wired).** The ExternalSecret reads only
   `tunnel_token`, no `credentials_json` property exists, and the Deployment
   mounts only the `cloudflared-config` ConfigMap, not a credentials file. The
   commented `tunnel:` / `credentials-file:` keys in
   `manifests/cloudflared/configmap.yaml` are a placeholder for future work.

## Files

    tunnel-token            (SECRET — gitignored) the Cloudflare tunnel token
    credentials.json        (SECRET — gitignored) named-tunnel credentials (unused, see above)
    tunnel-token.example    committed placeholder showing the expected format

Real values are gitignored (`keys-template/cloudflared/tunnel-token` and
`credentials.json`, in the repo `.gitignore`); only the `.example` placeholder is
committed. NEVER commit a real token.

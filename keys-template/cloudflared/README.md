# KEYS / cloudflared — PROD go-live tunnel credentials (OPT-IN)

This folder holds the Cloudflare Tunnel credential for the public edge of an
**ENV=prod** image (`apps/12-cloudflared.yaml` and `manifests/cloudflared/`).
It is **read-if-present**. If it is absent, the cloudflared Deployment stays
down harmlessly and nothing else is affected. An **ENV=test** image prunes the
cloudflared app at build time, so it never consults this folder.

## What goes here

The Deployment supports ONE auth style today: the token tunnel.

1. **Token tunnel.** Put the dashboard-issued tunnel token in `tunnel-token`
   (single line, no newline). `hugmesh-go-live plan --provider cloudflare-tunnel
   --token-file FILE` stores a copy at `/etc/hugmesh/keys/cloudflared/tunnel-token`
   on the node (`--keys-dir` changes the base). **No script reads this file.**
   keys-provision does not touch `cloudflared/`, and nothing else copies it to
   Vault. An operator must store the token in Vault at
   `secret/<brand>/cloudflared`, property `tunnel_token`. The
   `cloudflared-tunnel-token` ExternalSecret then turns it into the `TUNNEL_TOKEN`
   env the Deployment reads.

2. **Named tunnel + credentials.json (NOT wired).** The ExternalSecret reads only
   `tunnel_token`. No `credentials_json` property exists. The Deployment mounts
   only the `cloudflared-config` ConfigMap, not a credentials file. The commented
   `tunnel:` / `credentials-file:` keys in `manifests/cloudflared/configmap.yaml`
   are a placeholder for future work.

## Files

    tunnel-token            (SECRET — gitignored) the Cloudflare tunnel token
    credentials.json        (SECRET — gitignored) named-tunnel credentials (unused, see above)
    tunnel-token.example    committed placeholder showing the expected format

The repo `.gitignore` ignores `keys-template/cloudflared/tunnel-token` and
`credentials.json`. Only the `.example` placeholder is committed. NEVER commit a
real token.

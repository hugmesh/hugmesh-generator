# KEYS / ddns — go-live Dynamic-DNS token (OPT-IN)

This folder holds the single update token that the go-live wizard's thin DDNS
driver uses (`hugmesh-go-live plan --provider duckdns`; see
`docs/GO-LIVE-WIZARD.md`). It is **read-if-present**: if it is absent, nothing
consults it. `hugmesh-go-live plan --token-file FILE` stores the token (mode
0600) at `/etc/hugmesh/keys/ddns/token` on the node (`--keys-dir` changes the
base). It stores nothing unless you pass `--token-file`.

## What goes here

One token in `token` (single line, no newline), for the service you chose with
`--ddns-service`:

1. **DuckDNS** — the account token from <https://www.duckdns.org/>.
2. **Cloudflare** — a zone-scoped API token (Zone.DNS Edit on the ONE zone) from
   the dashboard's API Tokens page.

The emitted updater script (`ddns-update.sh`, in the plan's `--out-dir`, default
`/var/lib/hugmesh/go-live/out`) reads this file at RUNTIME. The token is never
baked into the script, argv, or cron mail. The updater also needs
`--ddns-subdomain` and refuses to run without one.

## Files

    token            (SECRET — gitignored) the DuckDNS account / Cloudflare API token
    token.example    committed placeholder showing the expected format

Real values are gitignored (`keys-template/ddns/token`). Only the `.example`
placeholder is committed. NEVER commit a real token.

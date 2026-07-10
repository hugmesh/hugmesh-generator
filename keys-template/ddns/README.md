# KEYS / ddns — go-live Dynamic-DNS token (OPT-IN)

This folder carries the single update token the go-live wizard's thin DDNS
driver uses (`snapdragon-go-live plan --provider duckdns`, see
`docs/GO-LIVE-WIZARD.md`). It is **read-if-present**: absent => nothing consults
it. The wizard's `plan`/`commit` writes the token here itself (mode 0600) — you
normally never hand-edit this folder.

## What goes here

One token in `token` (single line, no newline), for whichever service you
picked with `--ddns-service`:

1. **DuckDNS** — the account token from <https://www.duckdns.org/>.
2. **Cloudflare** — a zone-scoped API token (Zone.DNS Edit on the ONE zone)
   from the dashboard's API Tokens page.

The emitted updater script (`out/go-live/ddns-update.sh`) reads this file at
RUNTIME — the token is never baked into the script, argv, or cron mail.

## Files

    token            (SECRET — gitignored) the DuckDNS account / Cloudflare API token
    token.example    committed placeholder showing the expected format

Real values are gitignored (`keys-template/ddns/token`); only the `.example`
placeholder is committed. NEVER commit a real token.

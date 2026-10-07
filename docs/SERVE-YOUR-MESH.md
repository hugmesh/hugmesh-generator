# Serve your mesh — from nothing to a reachable login page

This is the **end-to-end path**: generate an entire HugMesh platform from scratch,
serve it **locally**, then (optionally) expose it **publicly** over a Tor **.onion**, a
common **Dynamic-DNS** host, or a tunnel. It ties together two capabilities that already
exist but are reached from different places — the **Local Mesh** bring-up (local serving)
and **Go Live** (public exposure).

There are two independent axes; pick one from each:

| Axis | Options |
| --- | --- |
| **Environment** | `test` — LAN-only / offline (issuer `http://localhost:8000`, safe default) · `prod` — a real public domain (the production build) |
| **Public reach** | not exposed (LAN only) · **tor-onion** (v3 `.onion`) · **duckdns** (Dynamic DNS) · **cloudflare-tunnel** · **byo-domain** · **router-portforward** · **tailscale-funnel** |

---

## 1 — Generate everything and serve it locally

**Studio → Local Docker mesh → Generate** (nine steps; the last one holds the
**Generate && start** button), or the ncurses menu → *Local mesh — from scratch*,
or `make mesh-bootstrap-plan` then `make mesh-bootstrap-up`. See
[LOCAL-STACK.md](LOCAL-STACK.md).

This one action:

1. mints **all** credentials offline (Casdoor/DB/telemetry secrets + a fresh platform
   **superadmin**, password written only to the gitignored `keys-out/vault/secrets.json` — never logged);
2. brings up the **full platform stack** from `tests/stack/compose.local.yaml`
   (Casdoor + DB + gateway + every BFF + the UIs) via `make stack-up`;
3. **seeds** the superadmin so the login actually works.

Choose the **Environment**:

- **`test`** — LAN-only, no public domain, no tailnet. The safe default; the front door
  is served locally at `https://localhost:8488` (plain `http://localhost:8088` also works).
- **`prod`** — the **production build**: a real `cluster_domain` (required) drives the
  public Casdoor issuer, and a tailnet/headscale **auth key** attaches the mesh overlay.

> The bring-up is a real cold build (it clones the service repos and builds every image
> the first time), so the first `prod` run is long. The in-product **plan** preview lists
> exactly what will run before anything happens, and preflight fails fast with an
> actionable message if the host isn’t ready.

At the end the plan/log prints the **local front door URL** and the superadmin username.

---

## 2 — Expose it publicly (optional)

Local serving is done. To make the mesh reachable from outside the LAN, run
**Studio → Go Live** (or `hugmesh-go-live`; see [GO-LIVE-WIZARD.md](GO-LIVE-WIZARD.md)).
Every provider is **registry-driven**, so the same choices appear in the CLI, the ncurses
menu, and Studio:

- **`tor-onion`** — publish the fe-gateway as a **Tor v3 `.onion`**. No public IP, DNS, or
  open ports; reachable in Tor Browser. (You can also skip this step and just enable **Tor**
  directly in the from-scratch bring-up above — same result, reported at the end and via
  `make stack-onion`.) See [TOR-HIDDEN-SERVICE.md](TOR-HIDDEN-SERVICE.md).
  On the **local docker mesh** that is `make stack-up TOR=1`; `make stack-onion` then prints
  the address as **`https://<onion>/`**. Open it over https: that is a secure context
  (Chromium does not treat an http `.onion` as one), it matches the `:443` a real node
  publishes, and a mesh with user-bff's default `Secure` session cookie cannot keep you signed
  in over http. Tor Browser shows a certificate warning once, because the local TLS front's
  certificate cannot name an onion. (The SPA does boot over http; an older note here blamed
  the CSP for a blank shell, which the live stack disproved, hugmesh-generator#628.) `make stack-e2e-tor` signs a test persona in through that
  onion over the real Tor network.
- **`duckdns`** — a common **Dynamic-DNS** host (DuckDNS / Cloudflare-DDNS): a single-token
  updater + cron drop-in for a box on a **dynamic IP**, no dashboard fiddling.
- **`cloudflare-tunnel`** — a Zero-Trust tunnel with autofilled public hostnames, no
  inbound ports.
- **`byo-domain`** / **`router-portforward`** — bring your own domain / forward a port.
- **`tailscale-funnel`** — public HTTPS on the node's `<node>.<tailnet>.ts.net` name.
  It needs Tailscale proper: the default self-hosted headscale does not implement Funnel.

Go Live writes the provider’s config (tokens land 0600 in the keys tree, never in argv or
logs) and tells you the exact public address. Its dry run is `make go-live`.

---

## The whole thing, at a glance

```
        Studio · Local Mesh · “…from scratch”
        (or  make stack-up  /  ncurses bootstrap)
                          │
        mint all creds ──►│──► make stack-up ──► make stack-seed
                          │        (full platform stack, superadmin seeded)
                          ▼
                 SERVED LOCALLY  ── https://localhost:8488
                          │
                          │   (optional) Studio · Go Live
                          ▼
   ┌─────────────┬─────────────┬───────────────────┬──────────────┐
   │  tor-onion  │   duckdns   │ cloudflare-tunnel │  byo-domain  │  …
   │  v3 .onion  │ dynamic DNS │   zero-trust      │  own domain  │
   └─────────────┴─────────────┴───────────────────┴──────────────┘
                 PUBLICLY REACHABLE
```

## Previewing the themed platform first

Before you serve anything you can preview your brand theme across the platform:
**Studio → Branding / Login theme → “Preview the themed platform in your browser…”**. It
writes ONE self-contained page to `~/.cache/hugmesh-studio/preview/` and opens it in your
default browser: the **real** captured production login page (your derived theme
substituted in — the same `:root:root` token text that ships) beside a Matrix chat, an
Akkoma feed and a forum thread pane painted from the same `--sd-*` tokens. The three
non-login panes are *representative mockups* and say so in-pane — the live chat/feed/forum
UIs are separate Angular apps and only the login page has a captured snapshot. The result
note under the button always names the written file and the open mechanism used; if no
browser can be launched (or the launch could not be verified) open that file by hand.

## See also

- [LOCAL-STACK.md](LOCAL-STACK.md) — the local compose stack in depth.
- [GO-LIVE-WIZARD.md](GO-LIVE-WIZARD.md) — every Go Live provider + the registry model.
- [TOR-HIDDEN-SERVICE.md](TOR-HIDDEN-SERVICE.md) — the Tor onion service.
- [RUNNING.md](RUNNING.md) — running builds and the menus.

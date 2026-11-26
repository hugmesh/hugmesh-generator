# Go live when ready

A domain can be set, when its mesh's node images are built, to **go public on its own**
once the mesh has booted and its containers are healthy. No one has to run Go live
afterwards, and no one is asked to confirm. (hugmesh-generator#1201)

**Operator decision (2026-11-25):** choosing "Go live when ready" for a domain at build
time **is** the consent for that domain's unattended go-live. Every domain that is not
opted in keeps the interactive go-live, with its typed confirmation.

## Choosing it

On the **Domain services** step (GUI and TUI), every domain of an image build of a mesh
has a **Go live when ready** row under its Tor front door:

| Provider | What must already be true outside the mesh | API key |
|---|---|---|
| `cloudflare-tunnel` | the tunnel exists in your Cloudflare account | Cloudflare Tunnel token |
| `byo-domain` | the domain's DNS points at the mesh's public address | none |
| `duckdns` | the DuckDNS / Cloudflare name exists | DuckDNS or Cloudflare DDNS API token |
| `tailscale-funnel` | Funnel is allowed for the tailnet | none |
| `router-portforward` | your router forwards 80 and 443 to the public edge node | none |

`tor-onion` is not offered: an onion is reachable with the host internal and needs no
public flip. Use the domain's Tor front door for that.

- **GUI:** a provider picker (Off by default) and, for a provider that needs one, a
  masked API-key field. The field is cleared as soon as the key is taken.
- **TUI:** `go PROVIDER` or `go off`; `key` makes the next line hidden (masked in the
  full-screen face, read with getpass in the plain one) and takes it as the API key.

The setting is saved as `Domain.go_live` (or `cluster_domain_go_live` for the mesh's own
domain), only when it is on, and rides the mesh manifest.

## Where the API key goes

The key is **never** saved: not in a config file, a session record, the mesh manifest, a
builder argument, an image or a log line. It is held in the Studio's memory
(`core/golive_tokens.py`) until the KEYS sticks are made, then written as
`go-live/<domain>.token` (0700 folder, 0600 file) onto the stick of each node whose role
can be the public edge (`backend`, `backend-gpu`, `omnibus`, `edge-ai`). The pki stick
never carries it.

A provider that needs a key with none entered is a **blocking** problem on the Review
page. So is a build that makes no KEYS sticks at all, because the key could not reach
the node. Finding out on the node an hour after boot would be worse.

At first boot `provision_go_live_tokens` (`specs/etc/keys-provision/provision.sh`)
installs each key root-only under `/etc/hugmesh/go-live-tokens/`.

## What the image carries

The x86 and rpi5 builders take

```
--domain-go-live <domain>=<provider>      (repeatable; node roles only)
```

(the Studio passes it), print `PLAN_DOMAIN_GO_LIVE=<domain>:<provider>,…` in
`--print-plan`, and bake `/etc/hugmesh/domain-go-live`: one `<domain>=<provider>` per
line. Without the flag, no file is baked and the image is unchanged. A client or desktop
role refuses the flag. One library parses it for both builders:
`scripts/_domain-golive-lib.sh`.

## What happens on the node

`/usr/sbin/hugmesh-go-live-at-ready` runs at boot (OpenRC oneshot) and every minute
(`/etc/cron.d/hugmesh-go-live-at-ready`). For each domain in the file it:

1. **acts only on the public edge node**, the node labelled `hugmesh.net/backend=true`,
   where the public ingress-nginx runs. Every other node records `not-edge` and stays
   internal. (The pki node's internal ingress also listens on 443, so "has a 443
   listener" is not the test.)
2. **waits until the mesh is ready**: every pod in every namespace is Running with all
   containers ready (or Succeeded), **and** the domain's front door answers
   (`https://<domain>/` through this node's ingress returns 100–499). Both must hold for
   **two minutes** in a row; losing either restarts the wait.
3. **goes live through the canonical driver**: `hugmesh-go-live plan --provider P
   --domain D [--token-file …]` (the artifacts are kept under the state dir, and the
   token is stored where the provider reads it), then `hugmesh-go-live commit
   --provider P --domain D --persist-public -y`. Every refusal the driver owns still
   applies. The agent never writes the posture marker itself.
4. **does it once**. A domain that went live is `applied` and is never touched again, so
   a later `hugmesh-go-live rollback` (or the console's) is not overridden. A failing
   plan or commit is retried on the next run, up to 5 times, then the domain is
   `gave-up` and stays internal, with the reason.

State: `/var/lib/hugmesh/go-live-at-ready/<domain>.state`. Driver output:
`driver.log` in the same folder. Log: `/var/log/hugmesh-go-live-at-ready.log` (a line
only when a domain's state changes).

**On the node** (for an operator who ssh'es in), `hugmesh-go-live-at-ready --status`
lists every domain with its state and reason. The node's own go-live menu
(`hugmesh-go-live-menu`) has two entries: one shows that list, the other runs the
check now. Both read only the node's own files, never a Studio session.

## Limits (not done yet)

- **Provider-side setup is assumed.** The registrar DNS for `byo-domain`, the tunnel for
  `cloudflare-tunnel`, and the router forward are not created by the mesh, exactly as
  for a go-live recorded in the web console (`hugmesh-go-live-reconcile`).
- **The posture flip is host-wide.** Going live opens 80/443 on the edge node for every
  domain the ingress serves. A domain that was **not** opted in gets no public DNS from
  this, but the public ingress does not yet refuse it by Host header. A per-host public
  gate at the ingress is the follow-up.

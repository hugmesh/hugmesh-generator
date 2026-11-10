# headscale DERP relay: built in, offline-first

**Decision (operator, 2026-11-10: "Built-in relay on").** Every headscale this repo
ships runs headscale's **embedded DERP relay**, and the public Tailscale DERP map is
**off by default**. A mesh therefore starts and relays with no internet and sends no
DERP traffic to Tailscale's servers. A mesh that wants Tailscale's public relays as
well can opt in.

## Why

Before this change the node config (`specs/etc/headscale/config.yaml`) and the KEYS
template (`keys-template/headscale/config.yaml`) listed only
`https://controlplane.tailscale.com/derpmap/default` with `derp.server.enabled: false`.
With no internet, headscale 0.23 cannot fetch that map and refuses to start:

```
FTL ... Headscale ran into an error and had to shut down.
    error="initial DERPMap is empty, Headscale requires at least one entry"
```

So a pki node without internet had no tailnet control server at all. The local docker
mesh (`tests/stack/headscale/config.yaml.tmpl`) already ran the embedded relay for
the same reason; the node configs now match it.

## What ships

All three shipped configs carry this block (headscale 0.23.0, the version every
builder pins):

```yaml
derp:
  server:
    enabled: true
    region_id: 999
    region_code: "hugmesh"            # renamed per brand at first boot (below)
    region_name: "hugmesh embedded relay"
    stun_listen_addr: "0.0.0.0:3478"
    private_key_path: /var/lib/headscale/derp_server_private.key
    automatically_add_embedded_derp_region: true
  urls: []
  paths: []
  auto_update_enabled: false
  update_frequency: 24h
```

| File | Used by |
|---|---|
| `specs/etc/headscale/config.yaml` | baked into every node image as `/etc/headscale/config.yaml` |
| `keys-template/headscale/config.yaml` | copied onto the KEYS stick by `scripts/gen-provision-keys.sh`; replaces the baked file at first boot |
| `tests/stack/headscale/config.yaml.tmpl` | the local docker mesh (`make stack-up HEADSCALE=1`, see [`LOCAL-MESH-HEADSCALE.md`](LOCAL-MESH-HEADSCALE.md)) |

- **Region id 999** is in the 900–999 block Tailscale leaves for private regions, so
  it never collides with a public region when the opt-in adds the public map.
- **Region name.** At first boot keys-provision (`provision_headscale_derp` in
  `specs/etc/keys-provision/provision.sh`) renames the region from the brand's cluster
  domain (`provision.json .hugmesh.cluster_domain`, else `/etc/hugmesh/cluster-domain`):
  `region_code` is its first label and `region_name` is `"<domain> embedded relay"`. A
  value that is not a plain hostname is refused and the baked name stays.
- **`ipv4`/`ipv6` are not set.** Clients resolve the host in `server_url`: the pki
  node's LAN IP by default, the published name once there is one. Pinning the LAN IP
  would make clients behind a published name dial an address they cannot reach.
- **The DERP server key** is generated on first start at
  `/var/lib/headscale/derp_server_private.key`, next to the noise key, and survives
  reboots.

## How clients use it

headscale puts the region in every client's DERP map. The node in that region is the
`server_url` host, with `DERPPort` set to the `server_url` port and `STUNPort` 3478.

| Traffic | Where it goes | Port |
|---|---|---|
| DERP relay (TCP) | `/derp` on headscale's own HTTP listener, at the `server_url` host:port | **no new TCP port**: the existing `server_url` port (8080 on the LAN default, 443 behind a TLS front) |
| STUN (UDP) | the `server_url` host | **3478/udp** |

### Relaying needs an HTTPS `server_url`

Tailscale clients always speak TLS to a DERP node. Measured with headscale 0.23.0 and
tailscale 1.76.6 on an offline docker network:

- With the LAN default `server_url: http://<pki-ip>:8080`, headscale starts, the map
  holds the embedded region, STUN answers (`tailscale netcheck`: `UDP: true`, nearest
  DERP = the embedded relay) and peers on the same LAN connect directly. The relay
  itself is **not** usable: `tailscale debug derp 999` reports `tls: first record does
  not look like a TLS handshake`.
- With `server_url: https://<front>` and a TLS front that passes `Upgrade`/`Connection`
  through to headscale's `:8080` (the shape of the local stack's
  `tests/stack/tls-front/default.conf`), `tailscale debug derp 999` reports
  `Successfully established a DERP connection`, and two clients forced onto DERP ping
  each other `via DERP(<region>)`.

So on a LAN the embedded relay gives offline startup plus STUN, and peers talk
directly. To relay between peers that cannot reach each other directly (different
NATs), publish headscale behind a TLS front that passes HTTP/1.1 upgrades and set
`server_url` to it.

**The cluster facade does not do this today.** `scale.<domain>` on the cluster goes
ingress-nginx -> backend gateway -> pki gateway -> headscale. The pki gateway
(hugmesh-gateway `SecurityConfig`, decision 79) requires `ROLE_SUPERADMIN` on **every**
request to the headscale route's Host, so an anonymous tailscale client is refused
for the control channel (`/ts2021`) and for `/derp` alike. That is an existing
limit of the gateway, not something this change introduced or alters. A node that has to
relay across NATs needs a plain TLS front for headscale (like the local stack's)
instead of the gateway.

**STUN follows the `server_url` host.** Behind a front, STUN goes to the front's
address on 3478/udp. If the front does not forward UDP 3478 to the pki node, STUN goes
unanswered (`did not return a IPv4 STUN response`). Relaying still works; clients just
lose the NAT-mapping hint STUN gives them.

## The opt-in: also use Tailscale's public relays

One knob, four places to set it:

| Where | Spelling |
|---|---|
| any builder | `--headscale-public-derp` (or env / brand profile `HEADSCALE_PUBLIC_DERP=true`); bakes `/etc/hugmesh/headscale-public-derp` |
| `make` | `make … HEADSCALE_PUBLIC_DERP=true` (passed to the builders, the docker re-invoke and the local stack) |
| KEYS stick | `scripts/gen-provision-keys.sh --headscale-public-derp` (or `HEADSCALE_PUBLIC_DERP=true`); stamps `provision.json .headscale.public_derp: true` |
| Studio | Network page: "Also use Tailscale's public relays" (`headscale_public_derp`, every platform) |

Precedence at first boot: `provision.json .headscale.public_derp` (`true` **or**
`false`) beats the baked marker, which beats the default (off). When the opt-in is on,
keys-provision swaps the `urls: []` line for the public map and turns
`auto_update_enabled` on. The embedded region stays in the map either way, so an
opted-in mesh still starts offline: headscale logs that it could not fetch the public
map and carries on with the embedded region. A KEYS config that lists its **own**
`derp.urls` is left as written.

The local stack takes the same knob: `make stack-up HEADSCALE=1 HEADSCALE_PUBLIC_DERP=true`.

## Firewall

| Layer | What changes |
|---|---|
| node nftables (`hugmesh-coturn-firewall`, table `hugmesh_coturn_relay`) | Drops 3478/udp from non-tailnet sources by default on every node. keys-provision writes the embedded STUN port to `/etc/hugmesh/headscale-derp-stun`, only on a node whose headscale runs the embedded relay (the pki node). The script then adds exactly one rule ahead of the drops: `udp dport 3478 accept`. No TCP, no 5349, no relay window. A malformed marker admits nothing. |
| firewalld (where it runs) | The same single `3478/udp`, added to the default zone at runtime. The coturn pass never removes it while the marker is present. Node images ship firewalld but do not enable it; the nftables tables are the gate. |
| release gate (`hugmesh-firewall-reconcile`) | Unchanged. It only touches TCP 80/443. |
| k8s NetworkPolicy / Kyverno | Unchanged. headscale is a host OpenRC service on the pki node, not a pod. DERP-over-TCP rides the existing 8080 path, and STUN never enters the cluster. |

**Omnibus caveat.** On a node that is both the pki node and a coturn-public relay
(`/etc/hugmesh/coturn-public`, see [`COTURN.md`](COTURN.md)), coturn's hostNetwork pod and
headscale's STUN listener both want 3478/udp on the host. Only one can bind it.
headscale starts first at boot and keeps it, so the coturn pod cannot bind it.
`hugmesh-coturn-firewall` logs the clash.

## Outside this change

The tailscale **client** still tries Tailscale's log service (`log.tailscale.io`, via
its built-in bootstrap DNS) unless `tailscaled` runs with `--no-logs-no-support`. With
no internet that only fails, harmlessly. It is the client's own telemetry, not DERP, so
this change leaves it alone.

## Tests

- `tests/scripts/test-headscale-embedded-derp.sh` (offline; shell-suites debian job,
  GitLab orphan-guards-verify). It checks every shipped config (found by search, not
  from a fixed list) and runs `provision_headscale_derp` for real (naming, opt-in
  precedence, STUN hand-off). It runs the node firewall against stubs and checks that
  the STUN marker adds exactly one `udp dport 3478 accept` line. It also checks option
  parity across the 10 builders, gen-provision-keys (run), the Makefile, the Studio and
  the local stack (rendered), and ends with 11 negative controls.
- `tests/scripts/test-headscale-embedded-derp-live.sh` (docker job). It runs the pinned
  headscale and tailscale on an `--internal` network. A negative control shows the old
  config dying there. Then: the KEYS config starts, serves `/derp` (426) and
  `/derp/probe` (200), and hands a client a map holding only the embedded region plus
  a STUN answer. The opt-in starts offline too. Two clients relay `via DERP` through an
  nginx TLS front.

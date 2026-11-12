# headscale DERP relay: built in, offline-first

**Decision (operator, 2026-11-10: "Built-in relay on").** Every headscale this repo
ships runs headscale's **embedded DERP relay**, and the public Tailscale DERP map is
**off by default**. A pki node therefore starts, and relays between peers that cannot
reach each other directly, with no internet. headscale itself fetches no DERP map
and looks up no Tailscale name. A mesh that wants Tailscale's public relays as well
can opt in.

What this does **not** cover: a stock tailscale client still tries Tailscale's own
services (`log.tailscale.io`, and `controlplane.tailscale.com` /
`login.tailscale.com` in the stock container image) unless `tailscaled` runs with
`--no-logs-no-support`. Node images do not set that flag; see
[Outside this change](#outside-this-change).

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

Turning the embedded server on was half of it. Tailscale clients **only speak TLS** to
a DERP node, and headscale serves `/derp` on its own listener, at the `server_url`
host and port. On the old `http://<pki LAN IP>:8080` default the relay refused every
client (`tailscale debug derp 999`: `tls: first record does not look like a TLS
handshake`), so two peers with no direct path between them got no relay at all. That
is why the control URL is now **HTTPS by default** ([below](#https-what-makes-the-relay-work)).

## What ships

The three shipped configs carry this block (headscale 0.23.0, the version every
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

| File | Used by | Region names |
|---|---|---|
| `specs/etc/headscale/config.yaml` | baked into every node image as `/etc/headscale/config.yaml` | `hugmesh` / `hugmesh embedded relay`, renamed at first boot |
| `keys-template/headscale/config.yaml` | copied onto the KEYS stick by `scripts/gen-provision-keys.sh`; replaces the baked file at first boot | the same |
| `tests/stack/headscale/config.yaml.tmpl` | the local docker mesh (`make stack-up HEADSCALE=1`, see [`LOCAL-MESH-HEADSCALE.md`](LOCAL-MESH-HEADSCALE.md)) | its own: `hugmesh-local` / `HugMesh local mesh` |

- **Region id 999** is in the 900–999 block Tailscale leaves for private regions, so
  it never collides with a public region when the opt-in adds the public map.
- **Region name.** At first boot keys-provision (`provision_headscale_derp` in
  `specs/etc/keys-provision/provision.sh`) renames the node region from the brand's
  cluster domain (`provision.json .hugmesh.cluster_domain`, else
  `/etc/hugmesh/cluster-domain`): `region_code` is its first label and `region_name`
  is `"<domain> embedded relay"`. A value that is not a plain hostname is refused and
  the configured name stays.
- **`ipv4`/`ipv6` are not set.** Clients resolve the host in `server_url`: the pki
  node's LAN IP by default, the published name once there is one.
- **The DERP server key** is generated on first start at
  `/var/lib/headscale/derp_server_private.key`, next to the noise key, and survives
  reboots.

### keys-provision owns the `derp:` block

`provision_headscale_derp` re-renders the whole top-level `derp:` block of the live
config (baked or KEYS-supplied) on every provisioning run, from what the inputs say:

- **The embedded server is on.** A config that turns it off **and** lists DERP relays
  of its own (`derp.urls` other than the public map, or `derp.paths`) runs its own
  relays, and that choice is kept. Every other "off" is migrated. That includes the
  shape every KEYS stick written before 2026-11-10 carries (embedded off, only the
  public map), which would otherwise still exit `initial DERPMap is empty` offline.
- **The public map is listed exactly when the opt-in is on**, after any URLs of the
  operator's own. Turning the opt-in off takes it out again, with `auto_update_enabled`.
- `region_id` keeps a 900–999 value, else 999. `stun_listen_addr` and
  `private_key_path` keep the configured values. Unknown `derp.server` keys are kept.
- A rewrite that changes more than the region name first saves the file as it was to
  `<config>.derp.bak`, once, so the operator-written original is the copy kept.

## HTTPS: what makes the relay work

headscale puts the embedded region in every client's DERP map. The region's one node
is the `server_url` host, with `DERPPort` set to the `server_url` port and `STUNPort`
3478. So the relay is exactly as reachable as the control URL, and it needs TLS there.

### The default: headscale serves TLS itself

| Step | Where | What |
|---|---|---|
| control URL | `resolve_endpoint` | `https://<the node's primary LAN IPv4>:8080` unless `provision.json .headscale.server_url` / `.mesh.endpoint` or the baked `HEADSCALE_URL` say otherwise. Workers' default (`resolve_control_endpoint`, the pki node from `.nodes[]`) is https too. |
| certificate | `provision_headscale_tls` | Issued on every provisioning run from the **mesh CA on the pki stick**, `certs/cluster-ca.{crt,key}` (written there by `gen-keystores.sh` for every pki stick; or the copy `provision_certs` left in `/etc/ssl/keys`). EC P-256 leaf, `serverAuth`, 825 days, written to `/var/lib/headscale/tls.{crt,key}` (key 0600), and named in the config's `tls_cert_path` / `tls_key_path`. |
| names | `headscale_tls_sans` | The `server_url` host, every address on the node's interfaces (not link-local), `127.0.0.1`, `::1`, `localhost`, the host names, the pki address and name in `.nodes[]`, the override hosts, and the in-cluster Service name `headscale.hugmesh-pki.svc[.cluster.local]`. After the node's own `tailscale up`, `publish_cp_dns_record` re-issues it with the node's **tailnet address** before the headscale restart it already makes. |
| trust | `provision_certs` | Every node copies its stick's `certs/*.crt` into the system trust store and runs `update-ca-certificates`. That store is what tailscaled's Go TLS stack reads, for the control channel and for DERP. keys-provision runs before tailscaled starts (`before ... tailscaled` in its init script), so the first dial already sees the CA. |
| own client | `control_self_login_server` | The pki node's own tailscaled logs in at `https://127.0.0.1:<listen port>` (the certificate names loopback). tailscale derives the TLS port from the URL, so the "forced port-443 dial" lockout that led to the loopback login cannot strand it either. |

Measured (live suite section D, below): with sticks from `gen-provision-keys.sh` and
nothing edited by hand, keys-provision's own functions produce
`server_url: https://<LAN IP>:8080` and a certificate naming that IP, headscale 0.23.0
serves it offline, and two tailscale 1.78.1 clients on **separate networks with no path
between them** ping each other `via DERP(hugmesh)` and pass a TCP payload through the
relay, verifying an **IP-literal** DERP node against the mesh CA.

### Which listener does TLS: read from the `server_url`

| `server_url` | headscale's listener | The relay |
|---|---|---|
| `https://<host>:<listen port>` (the default) | TLS, with the certificate above | works |
| `https://<host>` or `https://<host>:<other port>` | plain HTTP: a **TLS front** terminates (the cluster facade, an operator's proxy) | works only if the front passes `/derp` with its `Upgrade` header |
| `http://...` (an explicit override) | plain HTTP, as asked | **does not work**; keys-provision says so |
| a config that names its own `tls_cert_path`, or `tls_letsencrypt_hostname` | left as written | the operator's certificate decides |

**No certificate to be had.** A stick with no mesh CA key and no pre-issued
`headscale/tls.crt` that names the host cannot get HTTPS. keys-provision then serves
**plain HTTP at the same address** (`http://<host>:8080`) and warns loudly. Nodes whose
login server is that `http://` URL join; the relay does not work. A worker given the
`https://` URL does **not** join: it is not downgraded, and its keys-provision says the
server answers only plain HTTP. The pki node never writes a dead `https://` URL into
its own `server_url`. The QEMU
harness's control row is this case (its stick carries no CA), so its fleet runs on
plain HTTP.

**An external CA kept off the stick.** With `--ca-cert/--ca-key` and no
`--ca-key-to-stick`, the CA key never reaches the pki stick, so
`gen-provision-keys.sh` issues `headscale/tls.{crt,key}` itself, for every address the
manifest already names (`.nodes[]` pki entry, `server_url`, `mesh.endpoint`,
`HEADSCALE_URL`, loopback) plus `HEADSCALE_TLS_SANS` (space- or comma-separated IPs and
names, e.g. the pki node's LAN address). keys-provision serves it when it names the
`server_url` host and is in date; otherwise the plain-HTTP fallback above applies.

### Every node needs the mesh CA

A node that does not trust the mesh CA cannot log in to an HTTPS control server it
cannot verify. The CA certificate reaches the other sticks this way:

| Path | How |
|---|---|
| `scripts/gen-provision-keys.sh -r <worker profile> --ca-cert <pki stick>/certs/cluster-ca.crt` | writes `certs/cluster-ca.crt` (certificate only). Without `--ca-cert` the worker output now says the CA is **required** to join. |
| `scripts/build-all-roles.sh` | after generating every keys folder, copies the pki folder's `certs/cluster-ca.crt` (certificate only, re-encoded by `openssl x509`) into every other keys folder that has none. Two pki folders with different CAs are called out. |
| Studio | with the Domain CA keys step, passes `--ca-cert` for every mesh node stick. Without it, the worklist run ends by copying the pki keys folder's CA certificate into every other keys folder that has none (`WorklistDriver._hand_mesh_ca_on`, the same hand-off as `build-all-roles.sh`). |
| by hand | copy the pki stick's `certs/cluster-ca.crt` into the other stick's `certs/`, as `gen-provision-keys.sh` already told you to. |

Clients that are **not** provisioned from a KEYS stick (a phone, a laptop joined by
hand) must have the mesh CA in their own trust store to use the LAN control URL, or
use a published name behind a front with a publicly trusted certificate.

### Existing sticks

- **pki stick.** Nothing to do. keys-provision issues the certificate from the stick's
  CA key on the next provisioning run and fills in `tls_cert_path` in whichever config
  is live, an old KEYS `headscale/config.yaml` included. Its old `derp:` block is
  migrated as described above.
- **Worker stick with `login_server: http://<pki>:<port>`** (the old default spelled
  out). `control_url_tls_migrate` checks the server before `tailscale up`: if it now
  answers HTTPS with a certificate the node trusts, the node logs in at
  `https://<pki>:<port>`. If it answers HTTPS with a certificate the node does **not**
  trust, the node logs in at https anyway and keys-provision says, loudly, that the
  mesh CA is missing from the stick. A server still on plain HTTP keeps the http URL. A
  server that does not answer yet is left as written. Only the TLS layer is asked; any
  HTTP status counts as an answer.

### Lifetime

The serving certificate is valid for 825 days (`HEADSCALE_TLS_DAYS`). It is re-issued
on every keys-provision run (a re-provision with `.provision-force` on the stick, or
`KEYS_FORCE=1`), never silently in between. Plan the re-provision before it expires; a
pki node whose certificate expired takes the mesh's control plane and relay with it.

## Who can use the relay

headscale 0.23 (and 0.26) has **no client verification for its embedded relay**:
there is no `verify_clients` key. Whoever can reach `/derp` can relay through it,
including clients of a different headscale that were handed this node in their own
DERP map. So:

- On a node, `/derp` is reachable exactly where the control port is (8080 on the LAN
  default). Do not publish that port beyond the mesh's own networks. A port-forward or
  an L4 proxy to the internet publishes an **open relay** along with the control server.
- The **local stack's TLS front** (`tests/stack/tls-front/default.conf`) answers
  `/derp` only for loopback, private LAN, tailnet (100.64.0.0/10) and IPv6 ULA /
  link-local sources, and 403s every other source (the live suite asks from a
  public-range network and gets 403). Its control channel is unchanged. The check is on
  the TCP peer address, so it only holds while the client's own address reaches nginx:
  a hop in between that connects from a private address (docker's userland proxy, the
  `TOR=1` tor container, an operator's reverse proxy) is let through.
- The **cluster facade** (`scale.<domain>`: ingress-nginx -> backend gateway -> pki
  gateway -> headscale) does not carry `/derp` today. The pki gateway
  (hugmesh-gateway `SecurityConfig`, decision 79) requires `ROLE_SUPERADMIN` on every
  request to the headscale route's Host, so an anonymous tailscale client is refused
  for `/ts2021` and `/derp` alike. `tests/scripts/test-headscale-embedded-derp.sh`
  fails if any cluster manifest routes `/derp` or a route-access row opens it on the
  pki gateway to the public. A mesh published through the facade sets `server_url` to
  the facade URL (port 443). headscale then stays plain HTTP behind it, and its relay
  does not reach clients that only see the facade. That is an existing gateway limit
  this change does not alter.

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
keys-provision lists the public map in `urls:` and turns `auto_update_enabled` on;
when it is off again, both come back out. The embedded region stays in the map either
way, so an opted-in mesh still starts offline: headscale logs that it could not fetch
the public map and carries on with the embedded region.

The local stack takes the same knob: `make stack-up HEADSCALE=1 HEADSCALE_PUBLIC_DERP=true`.

## Firewall

| Layer | What changes |
|---|---|
| node nftables (`hugmesh-coturn-firewall`, table `hugmesh_coturn_relay`) | Drops 3478/udp from non-tailnet sources by default on every node. keys-provision writes the embedded STUN port to `/etc/hugmesh/headscale-derp-stun`, only on a node whose headscale runs the embedded relay (the pki node). The script then adds exactly one rule ahead of the drops: `udp dport 3478 accept`. No TCP, no 5349, no relay window. A malformed marker admits nothing. |
| firewalld (where it runs) | The same single `3478/udp`, added to the default zone at runtime and recorded in `/var/lib/hugmesh/headscale-derp-stun.firewalld`. When the marker names another port, or goes away, the port admitted before is removed again, unless coturn-public owns it at that moment. Node images ship firewalld but do not enable it; the nftables tables are the gate. |
| release gate (`hugmesh-firewall-reconcile`) | Unchanged. It only touches TCP 80/443. |
| k8s NetworkPolicy / Kyverno | Unchanged. headscale is a host OpenRC service on the pki node, not a pod. DERP rides the existing 8080 listener, and STUN never enters the cluster. |

**Omnibus caveat: not supported on the default port.** An omnibus node is the pki node
and a backend node at once. If it is also made a coturn-public relay
(`/etc/hugmesh/coturn-public`, see [`COTURN.md`](COTURN.md)), coturn's hostNetwork pod
and headscale's STUN listener both want 3478/udp on the host. A STUN bind failure is
**fatal** to headscale 0.23. Measured: with 3478/udp already held, `headscale serve`
exits 1 with `FTL failed to open STUN listener: listen udp 0.0.0.0:3478: bind: address
already in use`. headscale usually binds first at boot, but it is restarted later (the
Layer-A policy sync restarts it on every policy change). A restart while coturn holds
the port takes the tailnet control server down. `hugmesh-coturn-firewall` logs the clash.

The fix: give that node a KEYS `headscale/config.yaml` with another
`stun_listen_addr` (for example `"0.0.0.0:3479"`). Clients take the STUN port from the
DERP map, so any free port works. keys-provision keeps that port when it renders the
block, writes it to `/etc/hugmesh/headscale-derp-stun`, and the firewall admits
whatever port that file names.

## Outside this change

- **Client telemetry.** A stock tailscale client still tries Tailscale's log service
  (`log.tailscale.io`, via its built-in bootstrap DNS) and, in the stock container
  image, `controlplane.tailscale.com` / `login.tailscale.com`, unless `tailscaled` runs
  with `--no-logs-no-support`. With no internet that only fails, harmlessly. It is the
  client's own traffic, not headscale's and not DERP; node images do not set the flag
  today (tracked as #965).
- **The QEMU harness** builds its own sticks with no mesh CA, so its fleet runs on the
  plain-HTTP fallback and does not exercise the HTTPS path; the live suite below does.
- **In-cluster plaintext callers of headscale.** The pki gateway's `headscale` route
  (`apps/20-gateway-pki.yaml`) and admin-bff's three headscale URLs
  (`APPSTORE_SCAFFOLD_HEADSCALE_URL`, `APP_REGISTRY_HEADSCALE_ACL_BASE_URL`,
  `APP_MESH_TOKEN_HEADSCALE_BASE_URL`) dial `http://headscale.hugmesh-pki.svc.cluster.local:8080`.
  On a pki node that serves TLS (the default) they get `400 Client sent an HTTP request
  to an HTTPS server`. Today that changes nothing that works: the admin-bff legs ship
  dark and the gateway route refuses anonymous tailscale clients. Before any of them is
  switched on it needs `https://` and the mesh CA in that caller's trust store. The
  certificate already names the Service. A mesh published through the facade sets
  `server_url` to the facade, and then headscale stays plain HTTP and these URLs work as
  written.
- **headscale's OIDC redirect URI** in Casdoor (`casdoor/init-job.yaml`) is the fixed
  `https://scale.<domain>/oidc/callback`. It already disagreed with the LAN `server_url`
  before this change (that file says so); the scheme change does not alter that.

## Tests

- `tests/scripts/test-headscale-embedded-derp.sh` (offline; shell-suites debian job,
  GitLab orphan-guards-verify):
  - A: every shipped config, found by search, not from a fixed list.
  - B: `provision_headscale_derp` run for real: naming, opt-in precedence, the
    declarative block (an old shape migrated with its `.derp.bak`, opt-in off removes
    the public map, an operator's own relays kept, a second render is a fixed point),
    and the STUN hand-off.
  - B2: `provision_headscale_tls` with real certificates. It covers the default, an
    explicit http URL, a TLS front, no material, a mismatched CA key, pre-issued
    certificates that do and do not name the host, an operator's own certificate, the
    `resolve_endpoint` / `resolve_control_endpoint` defaults and the tailnet re-issue.
  - C: the node firewall against stubs, including firewalld across marker changes.
  - D: option parity across the 10 builders, gen-provision-keys (run, including the
    external-CA pre-issue and the worker's CA warning), `build-all-roles.sh`'s CA
    hand-off, the Makefile, the Studio and the local stack. The Studio's own hand-off
    is `studio/tests/test_worklist_driver.py::test_mesh_ca_handed_to_every_other_stick`.
  - F: who can reach `/derp` (the local front's allow-list, the cluster manifests and
    the route-access seed).
  - E: negative controls; each mutation of a copy of the tree must turn it red.
- `tests/qemu/mesh_client_test.sh` E3b/E5: the worker-side migration
  (`control_url_tls_migrate` against a stubbed server) and the control node's https
  loopback login.
- `tests/scripts/test-headscale-embedded-derp-live.sh` (docker job). Pinned headscale
  and tailscale on `--internal` networks:
  - 0: the old shape dies offline when started as is, and starts once migrated.
  - A: the KEYS template starts, serves `/derp` and `/derp/probe`, and hands out a map
    with only the embedded region and a STUN answer. With an explicit `http://`
    `server_url`, the relay refuses.
  - B: the opt-in starts offline too.
  - C: two clients relay through the local stack's real TLS front.
  - D: the shipped node path with nothing edited by hand. It uses
    `gen-provision-keys.sh` sticks and keys-provision's own functions in the node's
    network namespace, which give an HTTPS `server_url` on the LAN IP and a
    certificate from the stick's CA. Two workers on split networks migrate their old
    `http://` URL, join and relay `via DERP(hugmesh)`, and a TCP payload crosses. A
    packet capture from before headscale starts sees no lookup of a Tailscale name
    from headscale and no off-net connection attempt; a positive control proves the
    capture sees both. The pki node's own client joins at `https://127.0.0.1:8080`.
    A worker whose stick lacks the CA is warned and does not join.

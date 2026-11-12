# coturn — TURN/STUN relay for Matrix (tuwunel) audio/video

> **Status: OPTIONAL service, DEFAULT-OFF, ships dark.** A default build deploys
> NO coturn pod and changes NOTHING for existing Matrix calls. Clients keep their
> current host-only ICE behaviour (`iceServers: []`). Turning coturn on is an
> explicit, reversible, per-domain runtime add.

## 1. What it is and why

[coturn](https://github.com/coturn/coturn) is a STUN/TURN server. For Matrix
voice and video (WebRTC), two clients first try to connect **peer-to-peer**. That
often fails (symmetric NAT, CGNAT, firewalls; the usual case on home networks). The
call then needs a **relay**: a public server both clients can reach that forwards
the media between them. coturn is that relay.

Without a TURN relay, a call with no direct path does not connect. coturn is what
makes Matrix A/V work across the public internet, not only on one LAN.

## 2. The credential flow (one shared secret)

coturn runs in **REST long-term-credential mode** (RFC 5766, the Matrix standard).
It does NOT use static usernames or passwords:

1. A client logs in and asks tuwunel `GET /_matrix/client/v3/voip/turnServer`.
2. tuwunel **mints a time-limited `username:password`** (an HMAC of an expiry and
   nonce, keyed by a **shared secret**) and returns it with the TURN URIs.
3. The client presents that credential to coturn.
4. coturn **validates** it with the **same shared secret**. There are no per-user
   accounts and no database. The credential expires (`turn_ttl`, 24 h here).

Steps 2 and 3 use the same secret, so coturn and tuwunel must both hold it. That is
why they share a namespace (`hugmesh-backend`):

```
Vault: secret/hugmesh/coturn-shared-secret  (property: secret)
   │  ESO (manifests/external-secrets/coturn-externalsecrets.yaml)
   ▼
k8s Secret coturn-shared-secret  (key: secret)   ← ONE source of truth
   ├── coturn   pod: appended to turnserver.conf as static-auth-secret  (validates)
   └── tuwunel  pod: env TUWUNEL_TURN_SECRET → turn_secret              (mints)
```

**No literal secret is ever committed.** The ExternalSecret only names the Vault
path. The admin or DevOps must provision `secret/hugmesh/coturn-shared-secret` in
Vault at bootstrap. Until then ESO leaves the Secret unmaterialised, and since
coturn is default-off, nothing breaks.

## 3. Safe-by-default / dark-gated

| Layer | Default-off behaviour |
|---|---|
| Registry (`optional-services.yaml`) | `coturn` `default: off`, `apps: []` (runtime-only, no baked Application). |
| ApplicationSet (`apps/13a`) | `coturn` element `installed: "false"` → ArgoCD creates nothing. |
| `installed-services` ConfigMap | `coturn: "false"` (the stage4 builders do **not** rewrite it — coturn is not in their hardcoded render loop, so the baseline holds). |
| tuwunel config | `turn_secret = ""` in `tuwunel.toml`; `TUWUNEL_TURN_SECRET` is an `optional: true` secret env. When the Secret is absent the env is unset, `turn_secret` stays empty, and `voip/turnServer` returns **empty** creds → clients fall back to `iceServers: []` (today's behaviour). |
| Matrix UI | When `voip/turnServer` is empty/404 the client MUST degrade to host-only ICE (no error). This is the existing behaviour — coturn-off is byte-identical to current `main`. |

The switch is `turn_secret`. Empty means dark. Populated means live. It is populated
**only** when coturn is deployed and the Vault path exists.

## 4. Enabling it (per-domain, on a live cluster)

1. Provision the shared secret in Vault:
   `vault kv put secret/hugmesh/coturn-shared-secret secret=<32+ random bytes>`
2. Flip the two runtime gates to `true`:
   - the `coturn` element in `specs/cluster/apps/13a-optional-services.yaml`
   - the `coturn` key in `specs/cluster/manifests/policy/installed-services-configmap.yaml`
3. ArgoCD syncs. ESO materialises `coturn-shared-secret`, the coturn pod starts,
   and tuwunel's `TUWUNEL_TURN_SECRET` picks up the same secret on its next roll.
4. Roll the tuwunel pod so it re-reads the now-present optional env (or wait for
   the next reconcile). `voip/turnServer` now returns live relay creds.

To remove it, flip both gates back to `false`. Calls revert to host-only.

## 5. Public reachability — OPT-IN overlay (`manifests/coturn-public`)

coturn helps only if clients can **reach** it. The base manifests ship an
in-cluster `ClusterIP` Service only. The **opt-in public-reachability layer** is
the sibling kustomize overlay
[`specs/cluster/manifests/coturn-public/`](../specs/cluster/manifests/coturn-public/)
plus one node-side marker. All of it is DARK by default. With the overlay off, the
base render, the tuwunel config and every baked image behave byte-identically to the
mainline before the overlay.

**Enable** (per-domain, on a live cluster; do steps 1-4 of §4 first):

1. **Repoint the 13a element.** Change the `path` of the `coturn` element in
   `specs/cluster/apps/13a-optional-services.yaml` from
   `specs/cluster/manifests/coturn` to `specs/cluster/manifests/coturn-public`.
   This is the cassandra-hardening "repoint the source path" idiom: one element, one
   Application, so base and overlay can never fight over the same objects.
   The overlay = the base **plus**:
   - `hostNetwork: true` on the coturn pod. **Why not NodePort:** kube-proxy's
     NodePort range (default 30000-32767) cannot claim 3478/5349. The relay window
     **cannot be port-remapped at all**: peers send straight to the
     `XOR-RELAYED-ADDRESS` ip:port coturn allocated, so every relay port must be
     reachable **1:1** at the advertised address. hostNetwork binds 3478/5349
     (UDP+TCP) and the whole `49152–49200/UDP` window on the node (the lan-dns
     hostNetwork idiom). A cloud `LoadBalancer` with UDP passthrough that maps all
     three ranges 1:1 also works (set its address as the `external-ip` override).
     The reference fleet has no cloud LB, so that option is documented, not shipped.
     To allow more concurrent calls, widen `min-port`/`max-port`, the NetworkPolicy
     window and `hugmesh-coturn-firewall`'s relay window together.
   - the **`coturn-public-config`** ConfigMap, with two knobs:
     - `external-ip`: empty means advertise the node `status.hostIP` (fine when the
       node holds the public IP). **Behind NAT, set the public IP**, in either
       upstream form verbatim: `203.0.113.10`, or the NAT pair
       `203.0.113.10/172.17.19.101` (public/private).
     - `turn-uris`: the public URI set tuwunel advertises instead of the
       in-cluster svc DNS name (default
       `turn:turn.<domain>:3478?transport=udp|tcp` + `turns:turn.<domain>:5349`).
       It is injected as `TUWUNEL_TURN_URIS` (optional env, the
       `TUWUNEL_TURN_SECRET` pattern). The toml default never changes. Roll the
       tuwunel pod after enabling.
   - the **`coturn-tls`** cert for `turns:`/5349, issued by Vault PKI for
     `turn.<domain>` through the same per-domain CA loop as every other endpoint
     (`pki_int/issue/coturn` role + VaultDynamicSecret → ESO →
     `kubernetes.io/tls`, mirroring `tuwunel-proxy-mtls`). The pod appends
     `cert=`/`pkey=` (the upstream turnserver.conf option names) only when the
     Secret exists. Fleet images trust the cluster CA. For arbitrary public
     clients, replace the Secret with an ACME or public cert. This is **additive**
     and never replaces the offline CA (the platform's standing ACME stance).

   **Which node is "the relay node"?** The pod keeps the base
   `nodeSelector hugmesh.net/backend: "true"` and `replicas: 1`. On a mesh with
   **one** backend node (the reference topology, the x86 host) that node is the
   relay. With **several** backend nodes the scheduler picks one, and the
   marker, DNS and `external-ip` must all name that same node. Pin it (add a
   `nodeName`, or a narrower `nodeSelector`, to the overlay patch) before you
   provision DNS. Otherwise a reschedule silently moves the relay away from the
   address clients were told to use.

   **What hostNetwork costs.** The pod NetworkPolicy
   (`../coturn/network-policy.yaml`) does **not** apply to host-network pods. With
   the overlay on, the node firewall (step 2) is the ingress enforcement point, and
   the `denied-peer-ip` lines in `turnserver.conf` are the **only** remaining
   relay-SSRF backstop. They matter more here, not less: on the node network
   `127.0.0.0/8` is the node's own loopback (kubelet, containerd). The shipped
   deny-set already covers loopback, link-local, RFC1918, the CGNAT tailnet range and
   their IPv6 twins. Do not narrow it.
2. **Open the node firewall.** Run `touch /etc/hugmesh/coturn-public` on the relay
   node. `hugmesh-coturn-firewall` (boot oneshot + 60s cron, baked on every
   cluster-node image) converges both layers:
   - **firewalld** (x86 images): adds `3478/udp+tcp 5349/udp+tcp
     49152-49200/udp` to the **default zone at runtime**. Prod bakes
     `DefaultZone=drop`, and explicitly added ports are accepted even in a
     `target=DROP` zone (the target only decides packets that match *no* rule).
     It never uses `--permanent`: a firewalld restart falls back to the hardened
     baked baseline and the next cron tick re-admits.
   - **its own nftables table** (`hugmesh_coturn_relay`): with the marker absent it
     **drops** the TURN port set (except established/related, loopback and the
     tailnet). This fail-closed gate covers TEST images, where firewalld defaults to
     `trusted`, and it is **the whole gate on ARM**, where `net-firewall/firewalld`
     is a deliberate exclusion (it does not cross-compile; see
     `specs-rpi5/portage/packages.list`).

   Delete the marker to close again (within 60s). To widen the relay window, edit
   `min-port`/`max-port`, the NetworkPolicy range **and**
   `HUGMESH_COTURN_RELAY_MIN/MAX` together. The test pins all three equal, because
   the narrowest layer silently decides how many calls can relay.
3. **Provision `turn.<domain>` DNS.** With the marker present, `hugmesh-go-live`
   adds `turn` to the derived hostname set, so every provider emit
   (records.txt/CSV/BIND zone) carries `turn.<domain>` with the other public
   hostnames. It is always a **direct, unproxied A/AAAA** record: never the tunnel
   CNAME, never orange-clouded, because TURN is raw UDP/TCP and cannot ride an HTTP
   tunnel or CDN proxy. The byo-domain **and** cloudflare-tunnel emits each enforce
   that on their own. Name the relay node with `--turn-ip` / `--turn-ipv6`. They
   default to `--ingress-ip` / `--ingress-ipv6`, which is right only when the relay
   *is* the ingress node:

   ```
   hugmesh-go-live plan --provider byo-domain \
       --ingress-ip <ingress-node-public-ip> --turn-ip <relay-node-public-ip>
   ```

## 6. Egress VPN interaction (optional)

coturn can use the per-service **egress VPN** (see
[`docs/EGRESS-VPN.md`](EGRESS-VPN.md)). When `egress-vpn` is selected **and** an
assignment names coturn, the reconcile agent labels the coturn pod
`hugmesh.net/vpn-egress=true`, and `egress-vpn-interaction.yaml` tunnels its direct
egress through `wg0`. coturn works **without** the VPN (it is a public relay, not
federated traffic), so the label is **optional**. coturn's own `network-policy.yaml`
always permits direct relay egress.

## 7. Deferred / out of scope

- **Public reachability is NO LONGER deferred.** It is the opt-in `coturn-public`
  overlay plus the `/etc/hugmesh/coturn-public` marker (§5). Some things stay with
  the operator, because they are facts about *your* network, not code: choosing and
  pinning the relay node, the NAT `external-ip` value, the `--turn-ip` the DNS record
  points at, and, for arbitrary public clients that do not trust the offline cluster
  CA, swapping `coturn-tls` for an ACME cert.
- **Cloud `LoadBalancer` exposure.** Documented in §5, not shipped: nothing to
  test it against.
- **Group-call SFU (designed, not built).** coturn is a 1:1/mesh relay only.
  Scalable **group** calls (MatrixRTC) need a separate **SFU** (LiveKit, decision
  102a). That is a new optional service, not this one. The client half is merged
  and dark in `hugmesh-matrix-ui`. The server half, its port plan next to this
  relay and how LiveKit can reuse this relay are in
  [`GROUP-CALL-SFU.md`](GROUP-CALL-SFU.md).
- **Matrix-UI ICE change.** The `hugmesh-matrix-ui` graceful degradation
  (`voip/turnServer` empty/404 → `iceServers: []`) is the existing behaviour. Any
  explicit UI fetch wiring is a separate PR in that repo.
- **Build-time prune branch.** coturn is RUNTIME-ONLY (the anubis pattern), so it
  needs no `gate_optional_services` case. You add or remove it only through the 13a
  element and the ConfigMap flag.

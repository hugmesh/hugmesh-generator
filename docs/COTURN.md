# coturn — TURN/STUN relay for Matrix (tuwunel) audio/video

> **Status: OPTIONAL service, DEFAULT-OFF, ships dark.** A default build deploys
> NO coturn pod and changes NOTHING for existing Matrix calls — clients keep their
> current host-only ICE behaviour (`iceServers: []`). Enabling coturn is an
> explicit, reversible, per-domain runtime add.

## 1. What it is and why

[coturn](https://github.com/coturn/coturn) is a STUN/TURN server. For Matrix
voice/video (WebRTC), two clients first try to connect **peer-to-peer**. When a
direct path fails (symmetric NAT, CGNAT, firewalls — the common case for home
networks), the call needs a **relay**: a public server both clients can reach that
forwards the media between them. coturn is that relay.

Without a TURN relay, calls that cannot establish a direct path simply fail to
connect. coturn is therefore the piece that makes Matrix A/V reliable across the
public internet rather than only on the same LAN.

## 2. The credential flow (one shared secret)

coturn runs in **REST long-term-credential mode** (RFC 5766 — the Matrix
standard), NOT static usernames/passwords:

1. A client logs in and asks tuwunel `GET /_matrix/client/v3/voip/turnServer`.
2. tuwunel **mints a time-limited `username:password`** (HMAC of an expiry +
   nonce, keyed by a **shared secret**) and returns it with the TURN URIs.
3. The client presents that credential to coturn.
4. coturn **validates** it using the **same shared secret** — no per-user
   accounts, no database. The credential expires (`turn_ttl`, 24 h here).

Because step 2 and step 3 use the **same secret**, coturn and tuwunel must both
hold it. That is why they live in the **same namespace** (`hugmesh-backend`):

```
Vault: secret/hugmesh/coturn-shared-secret  (property: secret)
   │  ESO (manifests/external-secrets/coturn-externalsecrets.yaml)
   ▼
k8s Secret coturn-shared-secret  (key: secret)   ← ONE source of truth
   ├── coturn   pod: appended to turnserver.conf as static-auth-secret  (validates)
   └── tuwunel  pod: env TUWUNEL_TURN_SECRET → turn_secret              (mints)
```

**No literal secret is ever committed.** The ExternalSecret only references the
Vault path; the admin/DevOps must provision `secret/hugmesh/coturn-shared-secret`
in Vault at bootstrap. Until then ESO leaves the Secret unmaterialised — and since
coturn is default-off, nothing is broken.

## 3. Safe-by-default / dark-gated

| Layer | Default-off behaviour |
|---|---|
| Registry (`optional-services.yaml`) | `coturn` `default: off`, `apps: []` (runtime-only, no baked Application). |
| ApplicationSet (`apps/13a`) | `coturn` element `installed: "false"` → ArgoCD creates nothing. |
| `installed-services` ConfigMap | `coturn: "false"` (the stage4 builders do **not** rewrite it — coturn is not in their hardcoded render loop, so the baseline holds). |
| tuwunel config | `turn_secret = ""` in `tuwunel.toml`; `TUWUNEL_TURN_SECRET` is an `optional: true` secret env. When the Secret is absent the env is unset, `turn_secret` stays empty, and `voip/turnServer` returns **empty** creds → clients fall back to `iceServers: []` (today's behaviour). |
| Matrix UI | When `voip/turnServer` is empty/404 the client MUST degrade to host-only ICE (no error). This is the existing behaviour — coturn-off is byte-identical to current `main`. |

The switch is `turn_secret`: empty = dark, populated = live. It is populated
**only** when both (a) coturn is deployed and (b) the Vault path exists.

## 4. Enabling it (per-domain, on a live cluster)

1. Provision the shared secret in Vault:
   `vault kv put secret/hugmesh/coturn-shared-secret secret=<32+ random bytes>`
2. Flip the two runtime gates to `true`:
   - the `coturn` element in `specs/cluster/apps/13a-optional-services.yaml`
   - the `coturn` key in `specs/cluster/manifests/policy/installed-services-configmap.yaml`
3. ArgoCD syncs: ESO materialises `coturn-shared-secret`, the coturn pod starts,
   and tuwunel's `TUWUNEL_TURN_SECRET` picks up the same secret on its next roll.
4. Roll the tuwunel pod so it re-reads the now-present optional env (or wait for
   the next reconcile). `voip/turnServer` now returns live relay creds.

Removing it reverses these (flip both gates to `false`); calls revert to host-only.

## 5. Public reachability — DEFERRED (operator / cluster-topology work)

coturn is only useful if clients can **reach** it on the public internet. The
manifests ship an in-cluster `ClusterIP` Service (so tuwunel can advertise the
DNS name) and a `NetworkPolicy` permitting public ingress on the STUN/TURN ports.
They do **not** wire up off-LAN reachability, which depends on the cluster's
network topology and is therefore left to the operator:

- **Port exposure.** STUN/TURN `3478` (UDP+TCP), TLS `5349` (UDP+TCP), and the
  relay window (`49152–49200/UDP`, deliberately small — widen `min-port`/`max-port`
  in `turnserver.conf` **and** the Service/NodePort list together) must be reachable
  from clients. Add a `NodePort` (UDP passthrough) or `LoadBalancer` Service, or a
  node-level port-forward, and open the firewall for the same ranges.
- **`external-ip`.** Relay candidates must advertise a **routable** address. The
  pod sets `external-ip` from the node `status.hostIP` (downward API) by default;
  behind NAT this must be the public IP. Set `turn_uris` (in `tuwunel.toml`) to the
  public address once known.
- **TLS for `turns:`/`5349`.** This deployment ships plain STUN/TURN; a public
  deployment should add a cert (`cert_file`/`pkey_file`) for `turns:`.

## 6. Egress VPN interaction (optional)

coturn is a candidate for the per-service **egress VPN** (see
[`docs/EGRESS-VPN.md`](EGRESS-VPN.md)). When `egress-vpn` is selected **and** an
assignment names coturn, the reconcile agent labels the coturn pod
`hugmesh.systems/vpn-egress=true` and `egress-vpn-interaction.yaml` tunnels its
direct egress through `wg0`. coturn works **without** the VPN (it is a public
relay, not federated traffic), so the label is **optional** — coturn's own
`network-policy.yaml` always permits direct relay egress.

## 7. Deferred / out of scope

- **Public reachability wiring** (NodePort/LoadBalancer + `external-ip` + firewall +
  `turns:` TLS) — §5, operator work.
- **Group-call SFU.** coturn is a 1:1/mesh relay only. Scalable **group** calls
  (MatrixRTC / Element Call) need a separate **SFU** (LiveKit / sfu-to-sfu); that
  is a future optional service, not this one.
- **Matrix-UI ICE change.** The `hugmesh-matrix-ui` graceful-degradation
  (`voip/turnServer` empty/404 → `iceServers: []`) is the existing behaviour; any
  explicit UI fetch wiring is a separate PR in that repo.
- **Build-time prune branch.** coturn is RUNTIME-ONLY (anubis pattern), so it needs
  no `gate_optional_services` case; it is added/removed purely via the 13a element +
  ConfigMap flag.

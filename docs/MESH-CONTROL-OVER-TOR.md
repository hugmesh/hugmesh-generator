# Mesh control over Tor (opt-in fallback)

A worker's first boot happens before go-live. At that point the mesh has no public DNS
name, no public IP and no port-forward. The default, `lan`, handles this on a shared
LAN: before go-live a worker dials the pki node at its fixed LAN address (see
[SECURITY.md](SECURITY.md#local-first-mesh-endpoint-no-public-domain-required)). This
page describes the **opt-in** alternative, for nodes that may not share the pki's LAN:
the pki's control plane is also reachable through a dedicated Tor onion service.

The opt-in is a **permanent fallback**, not a temporary handover:

- Every node dials **one stable name**, `https://<control_name>:8080`. The default
  name is `hs.<superdomain>`, for example `hs.hugmesh.internal`.
- On every node, `/etc/hosts` points that name at `127.77.0.1`.
- On a worker, a node-local relay listens on `127.77.0.1:8080`. It sends each
  connection, unread, to the pki on the LAN while the LAN answers, or otherwise to the
  pki's control onion through the node's own Tor client.
- TLS runs end to end between `tailscaled` and the pki's headscale, which serves TLS
  itself on 8080 with a mesh-CA certificate that names the control name.
- The DERP relay host follows `server_url`, so relayed traffic uses the same name and
  path.

The name never changes. No client ever needs `tailscale up --login-server …
--force-reauth`, and no server_url change ever strands a client's DERP. The
measurements below showed that both of those happen with a hand-over design.

## Choosing it

| Transport | What a worker does before go-live |
|---|---|
| `lan` (default) | Dials `https://<pki LAN address>:8080`. Nothing on this page applies. |
| `lan+onion` | Dials the control name. The relay prefers the pki on the LAN and falls back to the onion. |
| `onion` | Dials the control name. The relay always uses the onion. |

The transport is set in these places:

- **Studio, Network page (mesh only):** *How do new nodes reach the control plane on
  first boot?* and *Create the control-plane onion address on this computer (its key
  goes only onto the PKI stick)*. The Fleet page and the TUI Network step
  (`transport …` / `mint on`) carry the same two settings.
- **Builders:** `--mesh-control-transport lan|lan+onion|onion`, or env/brand.conf
  `MESH_CONTROL_TRANSPORT`. Only the x86 and rpi5 builders can bake Tor. The other
  eight builders parse the flag and refuse a Tor transport before doing any work.
- **KEYS:** `gen-provision-keys.sh` takes these flags:
  - `--mesh-control-transport`
  - `--mesh-control-name`
  - `--mesh-control-onion-dir DIR`: the same directory for every role's run.
  - `--mesh-control-onion-mint`: the consent.
  - `lan+onion` also needs `--pki-ip`.
- **Make:** `make build-all MESH_CONTROL_TRANSPORT=lan+onion MESH_CONTROL_ONION_MINT=1 PKI_LAN_IP=…`.

## Key custody (operator decision 2026-11-11)

The control onion key is **minted at KEYS time on the build host** and goes **onto the
pki stick only**, with mode `0600` under `headscale/control-onion/`. Worker sticks
carry only the public address in `provision.json .mesh.control_onion`. The rules:

- **Consent.** Minting happens only with explicit consent: `--mesh-control-onion-mint`
  on the command line, or the checkbox in the Studio.
- **How it is minted.** `tor` runs with `DisableNetwork 1`, so nothing leaves the
  computer. A container with tor can do it instead (`MESH_CONTROL_TOR_IMAGE`).
- **Never re-minted.** A run never mints over an existing address. Every role's run
  reuses the first run's directory.
- **Secret removed afterwards.** After every stick is made, the Studio and
  `build-all-roles.sh` delete the secret key from the build host. When you run
  `gen-provision-keys.sh` by hand, it tells you to delete it.
- **Remaking the pki stick.** A later pki stick then needs a new mint, so every stick
  must be made again.
- **Placement guard.** `gen-provision-keys.sh` refuses to write an onion secret key
  to any stick that is not the pki's.
- **On the pki.** keys-provision installs the key into `/var/lib/tor/hugmesh-control`
  (`0700`/`0600`, `tor:tor`). It refuses the key if the key's hostname does not match
  the onion address the sticks carry.

This is the one exception to the in-situ custody rule in
[TOR-HIDDEN-SERVICE.md](TOR-HIDDEN-SERVICE.md). Without it, workers cannot know the
onion before their own first boot.

## What runs on the nodes

**Every node in a Tor mode:**

- The managed `/etc/hosts` line: `127.77.0.1 <control_name> # hugmesh-mesh-control`.
- A managed block in `/etc/conf.d/tailscaled` that exports `TS_FORCE_NOISE_443=true`.
- **No proxy variable for `tailscaled`, ever.** An `HTTPS_PROXY` sends DNS queries
  for the onion name, with the search domain appended, to the LAN resolver, and makes
  Tailscale's bootstrap-DNS calls go out directly.
- `/etc/hugmesh/tor/mesh-control`, read by `hugmesh-tor-reconcile`. It adds a
  cookie-authenticated `ControlSocket` in the DataDirectory, used by the keeper's
  `SIGNAL NEWNYM`.
- When the tor optional service was not selected at build time, `mesh-control-only`
  as well, so the node publishes **no onion of its own**. A worker's torrc then has no
  `HiddenServiceDir`.

**On the pki only:**

- The control onion: `HiddenServicePort 8080 → 127.0.0.1:8080`, which is headscale's
  own listener. It is never the fe-gateway onion, because the pki gateway refuses
  anonymous `/ts2021` and `/derp`. It is never exported and never admitted as an
  Ingress host.
- **Port 8080, not 443.** ingress-nginx-internal binds `:443` (and its webhook
  `:8443`) on the pki's host network. A listener on a specific address cannot coexist
  with a wildcard listener on the same port; this was checked.
- **OIDC.** First sign-in uses the sticks' pre-auth keys. `hugmesh-headscale-oidc-defer`
  runs from cron every minute. It restarts headscale once the issuer's discovery
  document answers, because headscale 0.23 never retries a failed OIDC discovery.
  The issuer is **never** published over the onion; the gateways still validate one
  in-cluster `iss`.

**On a worker only:**

- `hugmesh-mesh-control-relay` (socat, OpenRC `supervise-daemon`).
- `hugmesh-mesh-control-keeper`, which every 20 s:
  - probes the LAN path (`lan-ok`, trusted for 60 s);
  - opens one stream to the onion on the relay's single SOCKS isolation user, which
    keeps the rendezvous circuit warm;
  - after 3 failures in a row, sends `SIGNAL NEWNYM`.
- Check the current state with `hugmesh-mesh-control-relay status`.

**The firewall.** The pki admits 8080/tcp from the RFC1918 ranges only, using the
same carve-out as `lan`.

## Measured (pinned headscale 0.23.0, tailscale 1.78.1; Tor 0.4.9.x from alpine 3.20)

The relay path was measured over the real Tor network with throwaway onions in a
test rig.

**Joins over the onion**
- Through a CONNECT proxy: 20 joins took 12.7–30.6 s, median 17.7 s, with the
  client's Tor already warm.
- With this relay and keeper: 15.0–36.4 s.
- With a fresh circuit per connection: joins missed tailscaled's ~5 s TLS budget. The
  single isolation user and the keeper exist because of this.

**Stalls**
- **3 of 23 proxy joins stalled.** Each logged repeated `fetch control key … context
  deadline exceeded`.
- One recovered by itself after 3 min 20 s.
- One stayed stuck until `SIGNAL NEWNYM`, then joined 78 s later.
- The keeper automates that NEWNYM. **The automation has not been live-measured
  against a real stall.**
- A Tor-only relay with no keeper livelocked for more than 253 s after Tor returned.
  With the keeper, that client was Running 24 s after it started.

**DERP over the onion**
- Through the relay: RTT 1.39/1.60/2.11 s (min/median/max, n=15).
- Through the CONNECT proxy: 1.67/2.08/3.58 s, with 16 of 20 pongs.

**Recovery and LAN**
- DERP came back about 20 s after a client Tor restart and about 23 s after a service
  Tor restart with the same key.
- Two peers that share a LAN went direct within 16 s (RTT 0–1 ms) while control
  stayed on Tor.

**Path switching (relay upstream only)**
- Onion to LAN: 6 s.
- LAN to onion: 12 s and 139 s. **The 139 s is unexplained.**

**Offline**
- With the client's Tor offline, a first-boot join over the LAN took 3.6 s. The onion
  never shortcuts over the LAN: Tor always needs the internet.

**Privacy**
- With this relay design: 0 DNS queries for the onion and 0 bootstrap-DNS attempts.
- Tailscale's captive-portal probe to `*.tailscale.com` remains in every mode. That
  needs its own decision.

**Non-443 control port** (measured locally for this change)
- Control and DERP worked on `https://<name>:<port>` through a socat relay on
  `127.77.0.1`, with and without `TS_FORCE_NOISE_443`.
- Joins took 3.4–4.0 s, and a ping was relayed via `DERP(hsonion)`.

## Not yet measured

- `tests/scripts/test-mesh-control-onion-live.sh` covers four cells:
  - LAN configured but unreachable;
  - LAN-direct under the relay;
  - the timed two-way switch;
  - the keeper's NEWNYM path after a 75 s Tor outage.

  It is opt-in, never default CI, because it publishes a throwaway onion. **It has
  not been run yet**, so those four cells are written but unmeasured with the shipped
  scripts.
- A full node boot from KEYS sticks in this mode (QEMU) has not been run.
- headscale starting while its own Tor is fully offline has not been measured.

## Trade-offs

- **Tor needs the internet.** An offline LAN still needs the LAN path, so prefer
  `lan+onion` over `onion`.
- **Latency.** Control is slower over Tor, and relayed traffic over the onion adds
  1.4–2.1 s per round trip. LAN peers still go direct.
- **Visibility.** Every node in a Tor mode runs a Tor client and is visibly a Tor
  user to its network.
- **The stall risk above.** The keeper is the mitigation, and it is not yet proven
  live.

## Offline guard

`tests/scripts/test-mesh-control-onion.sh` runs keys-provision, the relay, the Tor
reconcile and gen-provision-keys against stubs. It checks:

- `lan` stays byte-identical;
- no proxy variable reaches `tailscaled`;
- a worker publishes no onion;
- the pki installs only a matching key;
- all ten builders carry the flag in parity;
- twelve negative controls, each of which turns the guard red.

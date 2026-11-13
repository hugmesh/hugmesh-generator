# Mesh control over Tor (opt-in fallback)

A worker's first boot happens before go-live. At that point the mesh has no public DNS
name, no public IP and no port-forward. The default, `lan`, handles this on a shared
LAN: before go-live a worker dials the pki node at its fixed LAN address (see
[SECURITY.md](SECURITY.md#local-first-mesh-endpoint-no-public-domain-required)). This
page describes the **opt-in** alternative, for nodes that may not share the pki's LAN:
the pki's control plane is also reachable through a dedicated Tor onion service.

The opt-in is a **permanent fallback**, not a temporary handover:

- Every node dials **one stable name**, `https://<control_name>:7443`. The default
  name is `hs.<first superdomain label>-control.<rest>`: for the superdomain
  `hugmesh.internal` it is `hs.hugmesh-control.internal`.
- On every node, `/etc/hosts` points that name at `127.77.0.1`.
- On every node, a node-local relay listens on `127.77.0.1:7443` and passes each
  connection on, unread:
  - on a worker, to the pki's headscale on the LAN (`<pki LAN address>:8080`) while the
    LAN answers, or otherwise to the pki's control onion through the node's own Tor
    client;
  - on the pki itself, to headscale's own listener (`127.0.0.1:8080`).
- TLS runs end to end between `tailscaled` and the pki's headscale, which serves TLS
  itself on 8080 with a mesh-CA certificate that names the control name.
- The DERP relay host and port follow `server_url`, so relayed traffic uses the same
  name, port and path.

The name never changes. No client ever needs `tailscale up --login-server …
--force-reauth`, and no server_url change ever strands a client's DERP. The
measurements below showed that both of those happen with a hand-over design.

## Choosing it

| Transport | What a worker does before go-live |
|---|---|
| `lan` (default) | Dials `https://<pki LAN address>:8080`. Nothing on this page applies. |
| `lan+onion` | Dials the control name. The relay prefers the pki on the LAN and falls back to the onion. If the node cannot run the Tor path (no tor or socat on the image, no valid name or onion on the stick), it falls back to `lan`, loudly. |
| `onion` | Dials the control name. The relay always uses the onion. **Fails closed**: if the node cannot run the Tor path, it dials **nothing** — no LAN address, no baked URL, no `.nodes[]` row; `tailscaled` is stopped and taken out of the runlevel, and keys-provision says why. An explicit `.tailscale.login_server`, `.headscale.server_url` or `.mesh.endpoint` on the stick is the operator's and still wins. |

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
  - `--mesh-control-name` (optional; see below)
  - `--mesh-control-onion-dir DIR`: the same directory for every role's run.
  - `--mesh-control-onion-mint`: the consent.
  - `lan+onion` also needs `--pki-ip`.
- **Make:** `make build-all MESH_CONTROL_TRANSPORT=lan+onion MESH_CONTROL_ONION_MINT=1 PKI_LAN_IP=…`.

## The control name must lie outside the superdomain

headscale 0.23.0 **refuses to start** when its `server_url` contains its MagicDNS
`base_domain` (the superdomain). The check is a plain **substring** match on the whole
URL, not a match on DNS labels. Measured on the pinned image:

| server_url | base_domain | headscale 0.23.0 |
|---|---|---|
| `https://hs.hugmesh.internal:8080` | `hugmesh.internal` | exits: `server_url cannot contain the base_domain` |
| `https://hs.hugmesh.internal:8080` | `mesh.internal` | exits (substring) |
| `https://hs.internalx.lan:8080` | `internal` | exits (substring) |
| `https://hs.hugmesh-control.internal:8080` | `hugmesh.internal` | serves |
| `https://ab.cd:8080` | `internal` | serves |

The first release of this option made `hs.<superdomain>` the default, which is the first
row: the pki's headscale could not start, so no worker could join over either path.
The default is now `hs.<first label>-control.<rest>`, and the same rule is checked in
three places, each refusing with a sentence:

- `gen-provision-keys.sh`, before anything is built or minted: a given or derived name
  whose URL contains the superdomain is refused (for example `--mesh-control-name
  hs.hugmesh.internal`, or a superdomain such as `control.internal` whose derived name
  `hs.control-control.internal` still contains it);
- the Studio: the Network page shows the reason under the transport choice and will
  not continue, the TUI shows it, and the build preflight refuses it;
- keys-provision on the node: such a name is not used (`lan+onion` falls back to
  `lan`; `onion` fails closed).

`tests/scripts/test-mesh-control-headscale-start.sh` starts the pinned headscale on the
config keys-provision renders from a stick made with no `--mesh-control-name`, and
checks that keys-provision's rule gives headscale's own verdict.

## The control port: 7443, not 8080

The relay must listen on the URL's port at `127.77.0.1`, and a listener on one address
cannot coexist with a wildcard listener on the same port. Workers carry wildcard `:8080`
listeners: `lan-dns` (hostNetwork CoreDNS, `ENV=test` backend nodes) binds `health
:8080`. So the dial port is a dedicated one, **7443**:

- the URL, the DERP port, the relay's listener and the onion's virtual port are 7443;
- headscale keeps listening on 8080: the LAN upstream, the firewall's RFC1918 carve-out
  and `lan` (byte-identical) are unchanged;
- on the pki, the relay is a local forward `127.77.0.1:7443 → 127.0.0.1:8080`, and
  keys-provision keeps headscale serving TLS itself behind it (a TCP passthrough is
  not a TLS front);
- the control onion maps `7443 → 127.0.0.1:8080`.

`.mesh.control_port` overrides 7443; it is never 8080.

## Key custody (operator decision 2026-11-11)

The control onion key is **minted at KEYS time on the build host** and goes **onto the
pki stick only**, with mode `0600` under `headscale/control-onion/`. Worker sticks
carry only the public address in `provision.json .mesh.control_onion`. The rules:

- **Consent.** Minting happens only with explicit consent: `--mesh-control-onion-mint`
  on the command line, or the checkbox in the Studio.
- **How it is minted.** `tor` runs with `DisableNetwork 1`, so nothing leaves the
  computer. A container with tor can do it instead (`MESH_CONTROL_TOR_IMAGE`). The run
  waits for all three key files, then stops tor and judges the result by the files,
  never by tor's exit status: a stop that lands before tor installs its signal
  handlers exits 143, and that used to end the script with no message.
- **Never re-minted.** A run never mints over an existing address. Every role's run
  reuses the first run's directory.
- **Secret removed afterwards — only on evidence.** `build-all-roles.sh` and the Studio
  delete the secret key from the build host only when a stick made in that run holds a
  byte-identical copy. A run whose pki keys step failed or was stopped keeps it, so the
  re-run can still make the pki stick; `SKIP_KEYS=1` keeps it. When you run
  `gen-provision-keys.sh` by hand, it tells you to delete it.
- **Remaking the pki stick.** Once the secret is gone, a later pki stick needs a new
  mint, so every stick must be made again.
- **Placement guard.** `gen-provision-keys.sh` refuses to write an onion secret key
  to any stick that is not the pki's.
- **On the pki.** keys-provision installs the key into `/var/lib/tor/hugmesh-control`
  (`0700`/`0600`, `tor:tor`). It refuses the key if the key's hostname does not match
  the onion address the sticks carry.

This is the one exception to the in-situ custody rule in
[TOR-HIDDEN-SERVICE.md](TOR-HIDDEN-SERVICE.md). Without it, workers cannot know the
onion before their own first boot.

## Who can reach the control onion

**Anyone who knows the onion address reaches headscale's whole HTTP surface and its
embedded DERP relay through it.** That is an accepted risk of this option today; read
it before you choose a Tor transport.

- **The embedded DERP relay is open.** headscale 0.23 has no client verification for
  its relay (no `verify_clients`; see [HEADSCALE-DERP.md](HEADSCALE-DERP.md#who-can-use-the-relay)).
  Through the onion, a Tor client that holds no mesh key gets `101 Switching
  Protocols` on `/derp` and can relay through the pki.
- **The whole HTTP surface is published.** Measured through the onion from a Tor
  client with no mesh keys: `/derp/probe`, `/health`, `/key`, `/swagger`, `/windows`
  and `/apple` answer 200; `/api/v1/*` answers 401 (it needs an API key); `/ts2021`
  (registration) still needs a pre-auth key.
- **The LAN carve-out does not help.** The pki admits 8080 from RFC1918 sources only,
  but onion connections arrive at headscale from Tor on `127.0.0.1`, so that rule
  never applies to them.
- **The address is not a secret.** It is on every worker stick. keys-provision keeps
  the relay's `relay.conf` root-only (`0600`), and keys-provision, the relay and
  `gen-provision-keys.sh` log only its first 8 characters; it still exists in every
  stick and every worker's Tor state.

**What could narrow it, and why it is not done here:**

- headscale 0.23.0 has no setting that turns off routes such as `/swagger`, `/apple`
  or `/windows`, and none that verifies relay clients: the pinned binary carries no
  `verify_clients` key at all, and its only `disable_*` setting is
  `disable_check_updates`.
- A path filter would have to terminate TLS on the pki (the relay passes TLS through
  unread) and would still have to pass `/derp` — which is the open relay.
- **Tor v3 client authorization** would close the onion itself to anyone without a
  client key: the pki's Tor would list an authorized client (the minted directory
  already has an empty `authorized_clients/`), and every worker's Tor would hold the
  matching private key. That puts **a secret on every worker stick**, which is a key
  custody change. **It is an open operator decision**, not implemented.

## What runs on the nodes

**Every node in a Tor mode:**

- The managed `/etc/hosts` line: `127.77.0.1 <control_name> # hugmesh-mesh-control`.
- A managed block in `/etc/conf.d/tailscaled` that exports:
  - `TS_FORCE_NOISE_443=true`;
  - `TS_NO_LOGS_NO_SUPPORT=true` — no log upload to `log.tailscale.io` and no
    bootstrap-DNS dials to Tailscale's public DERP addresses (see *Privacy*). PR #965
    turns log upload off for every node in the init script; this block is the Tor-mode
    guarantee and does not wait for it. In `onion` mode the block stays even when the
    node fails closed;
  - `rc_need="hugmesh-mesh-control-relay"`: tailscaled starts only with the relay
    (see *Privacy*). Not written when the node fails closed, so an explicit login
    server on the stick can still start tailscaled.
- **No proxy variable for `tailscaled`, ever.** An `HTTPS_PROXY` sends DNS queries
  for the onion name, with the search domain appended, to the LAN resolver, and makes
  Tailscale's bootstrap-DNS calls go out directly.
- `hugmesh-mesh-control-relay` (socat, OpenRC `supervise-daemon`) on
  `127.77.0.1:7443`, configured by `/etc/hugmesh/mesh-control/relay.conf` (root-only).
- `/etc/hugmesh/tor/mesh-control`, read by `hugmesh-tor-reconcile`. It adds a
  cookie-authenticated `ControlSocket` in the DataDirectory, used by the keeper's
  `SIGNAL NEWNYM`.
- When the tor optional service was not selected at build time, `mesh-control-only`
  as well, so the node publishes **no onion of its own**. A worker's torrc then has no
  `HiddenServiceDir`.

**On the pki only:**

- The control onion: `HiddenServicePort 7443 → 127.0.0.1:8080`, which is headscale's
  own listener. It is never the fe-gateway onion, because the pki gateway refuses
  anonymous `/ts2021` and `/derp`. It is never exported and never admitted as an
  Ingress host.
- The relay as a local forward (`TRANSPORT=local`): `127.77.0.1:7443 → 127.0.0.1:8080`.
  No keeper.
- **No OIDC.** keys-provision removes the `oidc:` block from headscale's live config in
  a Tor mode: nodes join with the KEYS sticks' pre-auth keys (operator decision
  2026-11-11: first sign-in via pre-auth keys, no OIDC over the onion). OIDC could not
  complete through the control name anyway: headscale builds its redirect URI from
  `server_url` (`https://<control name>:7443/oidc/callback`), which Casdoor's init job
  does not register and which only provisioned nodes can resolve. Turning it on would
  need that redirect registered, a browser that resolves the control name and trusts
  the mesh CA, and an operator decision; none of that is done.

**On a worker only:**

- `hugmesh-mesh-control-keeper`, which every 20 s:
  - probes the LAN path (`lan-ok`, trusted for 60 s);
  - opens one stream to the onion on the relay's single SOCKS isolation user, which
    keeps the rendezvous circuit warm;
  - after 3 failures in a row, sends `SIGNAL NEWNYM`.
- Check the current state with `hugmesh-mesh-control-relay status`.

**The firewall.** The pki admits 8080/tcp from the RFC1918 ranges only, using the
same carve-out as `lan`. 7443 is loopback only.

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
- The keeper automates that NEWNYM. Its NEWNYM path is live-measured after a Tor
  outage (below); **it has not been measured against a real stuck-rendezvous stall.**
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

**Non-443 control port**
- Control and DERP worked on `https://<name>:<port>` through a socat relay on
  `127.77.0.1`, with and without `TS_FORCE_NOISE_443`.
- `tests/scripts/test-mesh-control-headscale-start.sh` (CI, host docker, no Tor): the
  pinned headscale starts on the rendered Tor-mode config, `/key` answers through the
  pki's local forward on 7443 with only the mesh CA trusted, and a worker with the
  shipped relay and keeper joins at `https://hs.hugmesh-control.internal:7443` over the
  LAN path and reaches the embedded DERP region on the same name and port.

## Privacy

What the relay design keeps off the network, and what it does not:

- **Measured with the relay:** 0 DNS queries for the onion name and 0 bootstrap-DNS
  attempts — **only with log upload off**. A refutation rig ran two onion-mode workers
  that differed only in that setting: without it, tailscaled made 264 bootstrap-DNS
  attempts (HTTPS to the public IPs of `derp*.tailscale.com`) and 176 DNS queries for
  `log.tailscale.io`; with it, 0 and 0. Those attempts leave **outside Tor** on a node
  with a default route. That is why the Tor-mode block exports
  `TS_NO_LOGS_NO_SUPPORT=true`; measured on the pinned 1.78.1 with no network, the
  variable alone takes tailscaled from 25 `log.tailscale.io` attempts and 24
  bootstrap-DNS dials to 0 and 0, the same as `--no-logs-no-support` (the flag only
  sets this variable).
- **Not covered — the relay must be listening.** When nothing answers on
  `127.77.0.1:7443` (the relay stopped, or not started yet), tailscaled 1.78.1's control
  client falls back to **bootstrap DNS for the control name**: HTTPS to the public IPs
  of `derp*.tailscale.com` with `?q=<control name>`, outside Tor, **even with
  `TS_NO_LOGS_NO_SUPPORT=true`** (measured on an offline network: 26 such attempts in
  60 s). With the relay listening and its upstream dead (the onion stalled, the LAN
  gone), the same measurement gives 0: only a refused TCP connection triggers the
  fallback. 1.78.1 has no setting that turns it off
  (`TS_DNSFALLBACK_DISABLE_RECURSIVE_RESOLVER` governs a different path). The
  mitigation: the managed block makes
  tailscaled **need** the relay (`rc_need="hugmesh-mesh-control-relay"`), the relay's
  OpenRC service starts before tailscaled, and `supervise-daemon` respawns it within
  2 s. A relay that crashes still leaves that window open. **Not verified on a real
  OpenRC:** the offline guard checks that the block carries `rc_need`; no node has
  booted with it.
- **Not covered — the captive-portal probe:** tailscaled's captive-portal probe (DNS
  and HTTP for `controlplane.tailscale.com` and `login.tailscale.com`) still runs in
  every mode, outside Tor. That needs its own decision (the same open question as
  PR #965).
- **Visibility:** every node in a Tor mode runs a Tor client and is visibly a Tor user
  to its network.

## Measured with the shipped scripts (live, 2026-11-12)

`tests/scripts/test-mesh-control-onion-live.sh` on the real Tor network: one throwaway
onion minted by `gen-provision-keys.sh` (default name `hs.hugmesh-control.internal`,
base_domain `hugmesh.internal`, port 7443), the shipped relay and keeper, pinned
headscale 0.23.0 and tailscale 1.78.1 with the shipped env block; every key deleted
afterwards. It is opt-in and never runs in default CI. Two complete runs:

| Cell | Run A | Run B |
|---|---|---|
| headscale starts on the Tor-mode config | yes | yes |
| off-LAN worker (LAN configured, unreachable): relay picks the onion, join time | 12.2 s | 205.9 s |
| two LAN workers join over the LAN under the relay | 3.3 s, 3.4 s | 3.3 s, 3.4 s |
| LAN peers go direct (`tailscale ping`) | 1 ms | 0 ms |
| off-LAN worker relays via DERP over the onion | 10/10 pongs | 10/10 pongs |
| LAN → onion: relay switches / peer reachable again | 14 s / +5 s | 4 s / +10 s |
| onion → LAN: relay switches back | 17 s | 12 s |
| keeper sends NEWNYM during a client Tor outage | not reached (75 s outage) | yes (170 s outage) |
| onion path recovers after the outage | 74 s | 116 s |
| outsider with only the address: `/derp/probe`, `/key`, `/swagger`, `/health` | — | 200 each |
| outsider `/derp` with `Upgrade: DERP` | — | `101 Switching Protocols` |

Notes:
- Run B's first onion join took 205.9 s: the stall measured before (a fresh onion,
  `fetch control key … context deadline exceeded`) recurred and cleared on its own.
- The keeper needs three failed onion probes in a row before NEWNYM. With the shipped
  timing (a probe of up to 25 s every 20 s) that is about 140 s of a dead onion path;
  a 75 s outage (run A, the test's first timing) never gets there. The NEWNYM path
  works; it has still not been measured against a real stuck-rendezvous stall.
- Run A also exposed two harness defects that are fixed in the script (Tor in the
  containers must own its own directories; a Tor config failure is a FAIL, not
  "no internet").

## Not yet measured

- A full node boot from KEYS sticks in this mode (QEMU) has not been run.
- headscale starting while its own Tor is fully offline has not been measured.
- The keeper's NEWNYM against a real stuck rendezvous circuit (see above).

## Known limits

- **The control name resolves only on nodes.** keys-provision writes the managed
  `/etc/hosts` line only on nodes provisioned from a KEYS stick. A phone or operator
  laptop that joins the mesh gets a DERP host it cannot resolve, so it has no relay
  through the embedded region. It still reaches peers directly, or through the public
  map if that is opted in.
- **Boot ordering is not boot-tested.** keys-provision starts the relay and the keeper
  (and runs the Tor reconcile) from inside its own run, before `tailscale up`. Their
  OpenRC services also declare `after keys-provision`. No full first boot in this mode
  has been run, so a wait like the one the tor-reconcile header describes for its
  oneshot is possible and unmeasured.
- **An interrupted run keeps the secret key.** If a Studio run or `build-all-roles.sh`
  is stopped before the pki stick is made, the control onion's secret key stays in the
  run's `mesh-control-onion` directory, by design (see *Key custody*). Delete it by hand
  once the pki stick exists.

## Trade-offs

- **Tor needs the internet.** An offline LAN still needs the LAN path, so prefer
  `lan+onion` over `onion`.
- **Latency.** Control is slower over Tor, and relayed traffic over the onion adds
  1.4–2.1 s per round trip. LAN peers still go direct.
- **Exposure.** The onion publishes headscale and an open DERP relay to anyone with
  the address (see *Who can reach the control onion*).
- **The stall risk above.** The keeper is the mitigation; its NEWNYM path works live,
  but not yet against a real stuck rendezvous circuit.

## Guards

- `tests/scripts/test-mesh-control-onion.sh` (offline; CI debian leg) runs
  keys-provision, the relay, the Tor reconcile, gen-provision-keys and
  build-all-roles' secret removal against stubs. It checks, among others:
  - `lan` stays byte-identical;
  - the default control name lies outside the MagicDNS domain, the clash rule is
    headscale's substring rule, and gen-provision-keys, keys-provision and the Studio
    derive the same name;
  - `onion` fails closed for every reason, and `provision_tailscale` never runs
    `tailscale up` then;
  - no proxy variable reaches `tailscaled`, and `TS_NO_LOGS_NO_SUPPORT` does;
  - headscale runs without OIDC in a Tor mode;
  - a worker publishes no onion, the pki installs only a matching key, and the
    reconcile maps 7443 onto headscale's 8080;
  - the mint survives a tor that exits 143 on SIGTERM;
  - the secret leaves the build host only on evidence;
  - all ten builders carry the flag in parity;
  - 31 negative controls, each of which turns the guard red.
- `tests/scripts/test-mesh-control-headscale-start.sh` (CI host-docker job) is
  described above; its negative control is round one's default pairing, which the
  pinned headscale refuses.

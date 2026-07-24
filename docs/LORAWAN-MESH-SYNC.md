# LoRaWAN for the platform: WAN reach + near-mesh sync (design)

STATUS: DESIGN-ONLY (phase 1 of 4). Nothing in this document is implemented;
every later phase ships dark behind the platform's usual gates. Companion to
`docs/MESHTASTIC-BRIDGE.md` (the LoRa-mesh / Meshtastic side, live today) —
this doc covers the OTHER LoRa technology: **LoRaWAN**, the star-topology,
network-server-managed WAN protocol, and answers two asks:

1. Can nodes with LoRaWAN — directly, via an attached device, or via a mesh
   peer that has it — "use the WAN to forward tailscale/k8s traffic"?
2. Let a domain's admin/superadmin configure LoRaWAN so a locally-near mesh
   keeps in sync over it.

The short honest answers: **(1) not as an IP data plane — physics forbids it;
the WAN for tailscale/k8s is the LoRaWAN *gateway's* IP backhaul, and this doc
designs exactly that split. (2) yes — as a compact, duty-cycle-budgeted sync
frame protocol, domain-configured via the existing two-key capability idiom.**

---

## 1. The physics, quantified (why no IP-over-LoRaWAN)

LoRaWAN frames are small and airtime is regulated. Representative numbers
(LoRaWAN 1.0.4 regional parameters; EU868 and US915):

| Region / DR | Spreading factor | Bit rate | Max app payload | Airtime, full frame |
|---|---|---|---|---|
| EU868 DR0 | SF12/125 kHz | ~250 bps | **51 B** | ~2.8 s |
| EU868 DR3 | SF9/125 kHz | ~1.76 kbps | 115 B | ~0.21 s |
| EU868 DR5 | SF7/125 kHz | ~5.47 kbps | 242 B | ~0.07 s |
| US915 DR0 | SF10/125 kHz | ~980 bps | **11 B** | ~0.4 s (dwell cap) |
| US915 DR3 | SF7/125 kHz | ~5.47 kbps | 242 B | ~0.07 s |

Regulatory/operational ceilings: **EU868 = 1 % duty cycle** per sub-band —
**36 s of airtime per hour, per device**. US915 has no duty cycle but a
400 ms per-channel dwell limit (which is what makes SF11/SF12 uplinks
non-compliant on 125 kHz there). Community fair-use (TTN) is stricter still:
~30 s uplink airtime **per day**.

Now the arithmetic the "forward tailscale over LoRaWAN" idea runs into:

- A minimal **TLS 1.3 handshake** (certificates included) is ~4–6 KB each
  way. At EU868 SF12 that is ≥ 120 × 51 B frames ≈ **5–6 minutes of raw
  airtime — versus a 36 s/hour budget: one handshake ≈ 9+ hours of duty
  budget**, before a single byte of application data.
- A **WireGuard/Tailscale** handshake is admirably small (148 B + 92 B ≈ one
  or two frames at DR3+) — but the *data plane* is not: persistent-keepalive
  alone (32 B every 25 s) consumes ~5 s/hour of SF9 airtime, an MTU-sized
  packet (1280–1420 B) cannot fit any LoRaWAN frame and **LoRaWAN has no
  fragmentation for application traffic**, and interactive IP (DNS + TCP
  handshakes + TLS) multiplies the handshake math above per connection.
- **Kubernetes control traffic** (kubelet ↔ apiserver: watches, status
  PATCHes, liveness) runs to tens of KB/minute *when idle*. That is 2–3
  orders of magnitude beyond any compliant LoRaWAN budget.

**Conclusion: LoRaWAN is a control/telemetry channel — kb/day, not kb/s.**
Anything shaped like a socket dies on contact. What survives: compact,
store-and-forward, latency-tolerant frames — exactly §4's sync protocol.

### What LoRaWAN is NOT for here

No tailnet packets. No kubelet/apiserver traffic. No images, no video, no
voice. No OTA firmware (a 1 MB image ≈ 20,000 frames — weeks of duty budget;
flash radios via the imaging pipeline instead, `firmware/README.md`). No
Matrix event stream mirroring (bridged chat TEXT only, budgeted, §4.3).

---

## 2. The three connectivity tiers (where the WAN really is)

The realistic deployment insight: **a LoRaWAN gateway site almost always has
real IP backhaul** — ethernet, LTE/5G, or satellite — because the gateway
must reach its network server. That backhaul, not LoRaWAN, is the WAN.

| Tier | Node's links | Tailnet / k8s participation | Sync participation |
|---|---|---|---|
| (a) IP backhaul (direct, or co-located with a LoRaWAN gateway) | ethernet/WiFi/cellular | **Full**: joins the Headscale tailnet normally (`keys-template/provision.json` roles/tags); a gateway-site platform node additionally advertises itself as a **Tailscale subnet router / exit node** for the site (`tailscale.up_args` tag advertising, the existing provision mechanism) so *other* IP devices at the site ride its backhaul | Full (it IS the sync relay) |
| (b) LoRaWAN only | a LoRaWAN end-device (attached serial module or co-packaged radio) | **None.** No kubelet join, no tailnet data plane. In `device_registry` terms the machine is a **far-edge device**: registered, owned, domain-stamped — but its `image_type`/classification marks it non-cluster (it never appears as a k8s Node, no dial-key SSH leg) | Sync frames only (§4): presence, chat relay, registration deltas, admission signals — Class A cadence |
| (c) Mesh-peer reach only | LoRa-mesh (Meshtastic) hops to a peer that is tier (a) or (b) | None | Store-and-forward via its mesh peers; the peer's meshbridge/LoRaWAN leg carries the frames onward |

The "use the WAN" ask is satisfied *architecturally*: tier-(a) gateway sites
**are** WAN on-ramps (subnet-router pattern — normal Tailscale, full speed),
and tiers (b)/(c) get the only thing the radio physics permits: sync.

---

## 3. Domain configuration (admin/superadmin)

### 3.1 Two-key capability, cloned from `domain_capability`

Capability **`lorawan-sync`** in admin-bff's existing `domain_capability`
table (the `user-mesh-devices` sibling — same superadmin `granted` + domain
admin `enabled` two-key row, same `' global'` kill-switch sentinel, same
`GET /bff/internal/domain-capabilities/{domain}/lorawan-sync` check idiom).
No new mechanism; one new capability key.

### 3.2 Network server: `chirpstack` optional service (or external NS)

A domain either runs the platform's NS or points at an external one:

- **Optional service `chirpstack`** (RUNTIME-ONLY, the coturn/meshbridge
  pattern: `apps/13a` element + `installed-services` flag, default off,
  namespace `snapdragon-backend`): ChirpStack v4 (integrated NS+AS, Rust) +
  its Gateway Bridge, backed by its own small Postgres + the cluster MQTT
  broker. Gateways at the sites point their packet-forwarder at the domain's
  Gateway Bridge endpoint.
- **External NS** (TTN/TTI, Helium, an existing ChirpStack): the domain
  config stores the NS's MQTT integration endpoint instead.

### 3.3 `lorawan_config` (admin-bff, desired-state row per domain)

```
lorawan_config:
  id, domain (UNIQUE), generation, updated_by, updated_at
  ns_kind        CHECK IN ('chirpstack','external')
  region_plan    CHECK IN ('EU868','US915','AU915','AS923', ...)
  mqtt_url       (the NS's MQTT integration endpoint)
  mqtt_creds_ref (Vault pointer — never a literal; ESO-materialized)
  app_id         (ChirpStack application id / TTN app id)
  join_keys_ref  (Vault pointer to the JoinEUI/AppKey material — see §5)
```

Superadmin PUTs `ns_kind/region`, domain admin manages the rest — mirroring
the node-storage "controller writes desired state only" split, with the usual
`@PreAuthorize` + ownership matrix and a signed export unnecessary (nothing
on-node consumes this; the consumer is in-cluster, §4.4).

---

## 4. The sync protocol ("keep a locally-near mesh in sync")

### 4.1 What syncs

Four frame families, all latency-tolerant, all idempotent at the receiver:

| Family | Payload | Direction | Cadence |
|---|---|---|---|
| PRESENCE | node id, battery, uptime, flags | up | 15 min jittered |
| CHAT | bridged room text (bounded, §4.3) | up + down | on demand, budgeted |
| REG-DELTA | mesh-device registration mapping changes (node id ↔ owner) | down | on change, coalesced |
| ADMIT | admission signal (a far-edge device announcing itself for the device-pending pick-list) | up | once + daily refresh |

### 4.2 Encoding: hand-packed structs, not CBOR

One byte of header (`version:4 | type:4`), then fixed fields, then payload.
Rationale: CBOR's map-key overhead (~40–60 % on frames this small) buys
schema flexibility we do not need — frame families are versioned in the
header nibble, and US915 DR0's **11-byte** floor makes every byte count
(PRESENCE must fit it: `1 hdr + 4 node + 1 battery + 2 uptime-h + 1 flags =
9 B` ✓). CHAT uses the remaining per-DR budget: `1 hdr + 4 src + 1 seq |
text[…]` — 45 B of text at EU868 DR0, 236 B at DR3+. Text chunking reuses
meshbridge's UTF-8-safe chunker with the per-DR budget in place of 233.

### 4.3 Duty-cycle budgets (worked, EU868 @ DR3/SF9, 1 %)

Per device: 36 s airtime/hour. A full 115 B DR3 frame ≈ 0.21 s; PRESENCE
(9 B) ≈ 0.08 s.

- 10-node site, presence @ 15 min: 4 × 0.08 s = **0.3 s/hr/device** — noise.
- CHAT design target: **≤ 100 full frames/day/device** (~21 s airtime) —
  inside EU duty *and* TTN fair-use. Enforced by a per-device token bucket in
  the bridge (burst 5, refill 100/day) + drop-oldest queue, mirroring
  meshbridge's existing pacing discipline. Class A downlink reality: a
  tier-(b) device receives CHAT/REG-DELTA **only after it uplinks** (RX
  windows) — sync latency is bounded by the presence cadence, and that is an
  accepted property, stated in the UI copy, not worked around.

### 4.4 Where it runs: meshbridge grows a fourth transport (recommended)

Two options were evaluated:

- **(A) `meshbridge` fourth transport `"lorawan"`** — a new link class beside
  `MqttMeshLink` in `specs/cluster/manifests/meshbridge/app/transports.py`.
  It reuses the existing hand-rolled asyncio MQTT client but speaks
  **ChirpStack's** integration topics/payloads, which differ from the
  Meshtastic-JSON ones the `mqtt` transport speaks today:
  `application/{app_id}/device/{dev_eui}/event/up` (JSON, base64 `data` =
  our packed frame) and `.../command/down` for queued downlinks — versus
  Meshtastic's `msh/<root>/2/json/...` text envelopes. Same event contract
  upward (`text`/`nodeinfo`-shaped events out of decoded sync frames), so
  the bridge core, identity model, room mapping and rate-limit machinery are
  all reused unchanged.
- (B) A separate `lorawan-sync` daemon — clean isolation, but duplicates the
  Matrix appservice leg, the user-bff/mesh-bff sync legs, the registration
  cache, and the ops surface for a protocol whose whole job is feeding the
  same rooms and directory.

**Recommendation: (A).** One daemon, one identity model, one place where
"mesh text becomes Matrix text" lives; the transport boundary is already the
right abstraction seam (three transports prove it). Device entry shape:

```json
{ "id": "lorawan-site-1", "transport": "lorawan",
  "host": "chirpstack-mqtt", "port": 1883,
  "appId": "…", "devEuiAllowlist": ["…"], "regionPlan": "EU868" }
```

### 4.5 The k8s/tailnet statement, restated as design

Tier-(b) far-edge devices **never** appear in the tailnet or the cluster.
What the platform gets instead — and what "keep in sync" means precisely —
is: their presence/battery in the mesh node directory (mesh-bff), their chat
on mesh-enabled Matrix rooms, their registration mapping current, and their
admission signals in the device-pending pick-list. The moment a site needs
more than that, the answer is a tier-(a) upgrade (give the site IP backhaul
and a subnet router), never a fatter LoRaWAN pipe.

---

## 5. Security

- **Key custody**: OTAA root keys (JoinEUI/DevEUI/AppKey) and the NS MQTT
  credentials live in Vault, ESO-materialized (`join_keys_ref` /
  `mqtt_creds_ref` pointers in `lorawan_config`) — never in git, rows, or
  pod specs. The `meshbridge-appservice` ESO precedent applies verbatim.
- **Identity honesty** (the MESHTASTIC-BRIDGE stance, unchanged): LoRaWAN
  session keys authenticate the *device* (DevEUI) to the NS — they do not
  authenticate the *person*. Sync-frame node ids remain radio-asserted;
  registered attribution stays a distinct `@mesh-*` virtual user with
  metadata badges, never a real account.
- **Replay**: LoRaWAN frame counters (strictly-monotonic, NS-enforced) plus
  our own per-family `seq` nibble in CHAT; receivers drop stale seqs — the
  same LRU discipline meshbridge applies to Meshtastic packet ids.
- **Confidentiality**: AppSKey end-to-end payload encryption NS↔device is
  native LoRaWAN; in-cluster legs ride the existing mTLS fabric.

---

## 6. LoRa-mesh (Meshtastic) vs LoRaWAN — when to reach for which

| | Meshtastic mesh (live today) | LoRaWAN (this design) |
|---|---|---|
| Topology | peer-to-peer mesh, multi-hop | star-of-stars via gateways |
| Infrastructure | none (radios only) | gateway + network server |
| Range model | hop-extended, organic | single-hop to gateway, planned |
| Payload | 233 B, own framing | 11–242 B by region/DR |
| Regulatory posture | ISM duty rules per preset | NS-enforced duty/dwell + fair-use |
| Best at | ad-hoc local chat mesh, no infra | fixed sites, sensors, far-edge sync at km scale |
| Platform integration | meshbridge transports `serial`/`tcp`/`mqtt` | meshbridge transport `lorawan` (§4.4) |

Both feed the same rooms, directory, and identity model — the user never
learns which radio technology carried a message, except in the per-message
metadata badge.

---

## 7. Phases

| Phase | Delivers | Repo seams |
|---|---|---|
| 1 (this doc) | design + budgets + decision record | `docs/LORAWAN-MESH-SYNC.md` |
| 2 | `chirpstack` optional service + `lorawan_config` + `lorawan-sync` capability key | generator (`manifests/chirpstack/`, registry/13a/flag, ESO), admin-bff (config table + controller + capability seed), admin-ui (config surface) |
| 3 | sync frames + the `lorawan` transport | generator `meshbridge/app/transports.py` (+ codec module + tests w/ mock ChirpStack MQTT), mesh-bff ingest untouched (same bridge-sync contract) |
| 4 | gateway-site subnet-router automation | keys-template/provision presets (`tag:lorawan-gw` + advertised routes), docs |

Each phase ships dark; a default build stays byte-identical until a
superadmin grants `lorawan-sync` and an admin enables it.

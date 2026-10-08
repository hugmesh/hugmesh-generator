# Meshtastic LoRa mesh ↔ Matrix bridge (`meshbridge`)

Attach LoRa mesh radios — USB-serial ("LoRa device attachments") or WiFi/TCP
("LoRa-WiFi devices", Meshtastic TCP API port 4403) — to the platform, and
bridge their text traffic into Matrix: a room can opt in to a mesh channel, and
messages arriving over the mesh appear in that room **as mesh users**. Platform
users can **register a mesh node id under their own name** so their radio's
messages are attributed to them; unregistered nodes appear as anonymous mesh
nodes. Matrix messages in mesh-enabled rooms are forwarded back out over the
radio, so off-grid mesh participants and Matrix participants share one
conversation.

OPTIONAL SERVICE, DEFAULT-OFF, RUNTIME-ONLY (the coturn pattern): no baked
bootstrap Application; wired solely through the `apps/13a` ApplicationSet
element + the `installed-services` ConfigMap flag (`meshbridge: "false"` by
default). A default build is byte-identical to a build without this feature.

## Architecture

```
LoRa radios ──RF──> Meshtastic device ──serial/TCP──┐
                                                    v
                          ┌──────────────────── meshbridge ─────────────────┐
                          │ transports: tcp (LoRa-WiFi), serial (USB), mqtt │
                          │ codec: minimal Meshtastic protobuf + framing    │
                          │ bridge core: rooms<->channels, identity,        │
                          │   dedupe/rate limits, 233-byte chunking         │
                          │ Matrix appservice: virtual @mesh-* users        │
                          └──┬────────────────────────────────▲─────────────┘
             CS API (as_token, ?user_id masquerade)           │ AS transactions push
                             v                                │ (PUT /_matrix/app/v1/…)
                    tuwunel:8008  (in-namespace, hugmesh-backend)
```

- **Appservice, not bot accounts.** tuwunel (Conduit-family) supports
  application services registered via the admin room (`!admin appservices
  register` + registration YAML in a code block — see
  `manifests/meshbridge/meshbridge-register-job.yaml`, twinned on the
  `tuwunel-admin-sync` PostSync Job). The bridge claims the **exclusive user
  namespace `@mesh-.*`**: the homeserver refuses normal registration of those
  localparts, so mesh identities cannot be squatted.
- **In-namespace CS access** (`tuwunel:8008`, like the admin-sync Job), not the
  mTLS `tuwunel-proxy:4443`: appservice tokens are not user-custody tokens and
  never transit the gateway, so the revocation-filter trade-off documented on
  the proxy does not apply.
- **Events reach the bridge by AS push**: tuwunel delivers room traffic for
  rooms any `@mesh-*` user (or the `@meshbridge` sender) is joined to, via
  `PUT /_matrix/app/v1/transactions/{txnId}` (hs_token-authenticated,
  txn-id-deduplicated).

## Identity model

| Mesh sender | Matrix identity | Display name |
|---|---|---|
| Node `!a1b2c3d4` registered by user `alice` | `@mesh-alice:<server>` | `<registered display name> (mesh)` |
| Unregistered node `!a1b2c3d4` | `@mesh-node-a1b2c3d4:<server>` | `<NODEINFO long name> · mesh !a1b2c3d4`, or `Mesh node !a1b2c3d4` before a name is heard |

Registration lives in **user-bff** (`POST/GET/DELETE /bff/user/mesh-devices` +
`PUT /{id}/visibility`, node id unique per platform, owner = validated JWT
subject, `active/revoked` moderation state). The bridge polls the internal
mapping (`GET /bff/user/internal/mesh-devices`, gated `ROLE_SERVICE` — the
bridge authenticates with a Casdoor client-credentials token and presents its
Vault-PKI mTLS client cert, since user-bff terminates client-auth TLS) every
60 s and keeps the last good copy on failure (fail-soft: attribution degrades
to anonymous, never blocks traffic). It pushes LoRa status (last-seen,
battery, SNR, hops) back on the same surface (`POST .../status`), which feeds
the per-device status + visibility feature (`private`/`friends`/`channels`).

**Attribution honesty:** LoRa node ids are radio-asserted and NOT
cryptographically authenticated — anyone with RF access can transmit as any
node number. Registered attribution therefore renders as a *distinct virtual
user* (`@mesh-alice`), never the user's real account, every bridged event
carries `com.hugmesh.mesh` metadata (`{node, device, channel, registered}`
plus `rssi`, `snr` and `hops` when known), and the UI badges mesh-origin messages "via LoRa mesh". Treat
mesh attribution as convenience, not authentication.

## Per-room opt-in

Room state event **`net.hugmesh.mesh.bridge`** (state key `""`,
power-level-gated like `net.hugmesh.vn.scene`; the canonical wire prefix
follows the `.net` domain move, and the bridge also HONORS the two legacy
spellings — post-squash `systems.hugmesh.mesh.bridge` and pre-rebrand
`systems.snapdragon.mesh.bridge` — on read, canonical winning when several
exist; only the canonical type is ever written):

```json
{ "enabled": true, "device": "default", "meshChannel": 0 }
```

The room-settings UI writes this and invites `@meshbridge:<server>`; the bridge
auto-joins on invite, reads the flag, and activates the (device, channel) ↔
room mapping. Disabling (or a malformed/underprivileged event — the bridge
re-checks the *sender's* power level) deactivates the mapping. The bridge
stays joined: `MatrixClient.leave` exists in `matrix_cs.py` and nothing calls it.
Messages only flow for rooms with a valid, enabled flag.

## Message flow rules

- **Mesh → Matrix**: `TEXT_MESSAGE_APP` packets on a mapped (device, channel) →
  posted to each mapped room as the sender's virtual user (registered → ensure
  profile/membership lazily: AS-register, set displayname, invite by
  `@meshbridge`, masquerade-join). Duplicate RF deliveries dropped via per-device
  packet-id LRU; per-node token bucket (burst 10 / 30 s) guards room flooding.
- **Matrix → mesh**: `m.text` / `m.emote` from non-`@mesh-*` senders in mapped
  rooms → `<displayname>: <body>` (emote: `* <displayname> <body>`), UTF-8
  safe-truncated into ≤ 233-byte chunks (`DATA_PAYLOAD_LEN`), broadcast
  (`to=0xFFFFFFFF, want_ack`) on the mapped channel. Per-device send queue is
  paced (min 2 s between transmits — LoRa airtime is scarce and duty-cycle
  regulated) and capped (50; oldest dropped with a log line).
- **Loop guards**: own-namespace senders skipped; AS transaction ids deduped;
  the bridge never re-forwards what it itself posted or transmitted.

## Device attachments

Devices are declared in the `meshbridge-devices` ConfigMap (key
`devices.json`), mounted into the pod:

```json
{ "devices": [
  { "id": "default",    "transport": "tcp",    "host": "10.20.0.50", "port": 4403 },
  { "id": "field-usb",  "transport": "serial", "path": "/dev/serial/by-id/usb-RAK_WisCore…-if00" },
  { "id": "wan-mesh",   "transport": "mqtt",   "host": "mqtt.lan", "port": 1883,
    "topicRoot": "msh/US", "channelName": "LongFast", "gatewayNodeNum": 2130636288 }
] }
```

- **`tcp` (LoRa-WiFi)** works from any node the pod schedules on (egress via the
  NetworkPolicy). Covers ESP32-class radios (Heltec V3, generic ESP32-S3+SX1262
  boards) exposing the Meshtastic TCP client API.
- **`mqtt` (WAN-linked / LoRaWAN-gateway-style mesh)** reaches a remote mesh
  through Meshtastic's MQTT **JSON** integration on the operator's broker:
  uplink `<topicRoot>/2/json/<channelName>/#`, downlink published to
  `<topicRoot>/2/json/mqtt/` as `{"from": <gatewayNodeNum>, "type":
  "sendtext", ...}`. The gateway device needs `json_enabled` and a
  `downlink_enabled` channel named `mqtt`. nRF52-class boards (Heltec T114,
  ELECROW ThinkNode M1) have no WiFi — they attach via `serial` locally or
  participate over RF through any such gateway.
- **`serial` (USB attachment)** additionally needs the device file: uncomment
  the hostPath volume + nodeSelector pin in `manifests/meshbridge/deployment.yaml`
  (example inline) so the pod lands on the frontend node the radio is plugged
  into. Ships commented-out; TCP-only by default.
- The connect handshake (`want_config_id` → `my_info`/`node_info*`/`channel*`
  → `config_complete_id`) seeds the node-name db and validates the configured
  channel; reconnect with exponential backoff; 60 s heartbeat keeps TCP alive.

Admin-driven per-node attachment follows the node-storage idiom in three parts. Two
exist in admin-bff: `/bff/admin/device-radios` (device_registry-linked rows) and a
SUPERADMIN-only signed per-node export (`GET /export?node=<machine_key_fp>`). The
third does not: no on-node reconcile agent reads the export and writes this
ConfigMap. The ConfigMap is the operator surface until it does.

## Secrets

`meshbridge-appservice` (ESO ← Vault `hugmesh/meshbridge-appservice`):
`as_token`, `hs_token` — the appservice registration pair (generate two long
random strings at provision time); `oidc_client_id`/`oidc_client_secret` — the
Casdoor client-credentials client (ROLE_SERVICE) for user-bff's internal
surface; optional `mqtt_password` for authenticated brokers. The user-bff leg
additionally presents a Vault-PKI mTLS client cert. No literal ever in git;
absent Vault path ⇒ Secret never materializes ⇒ pod stays Pending (service is
default-off anyway).

## Files

- `specs/cluster/manifests/meshbridge/` — kustomization (app ConfigMap via
  `configMapGenerator` from `app/*.py`), deployment + service, network policy,
  devices ConfigMap, appservice-registration PostSync Job.
- `specs/cluster/manifests/external-secrets/meshbridge-externalsecrets.yaml`
- `specs/cluster/optional-services.yaml` — registry entry (runtime-only,
  `dependsOn: tuwunel`).
- `specs/cluster/apps/13a-optional-services.yaml` + `manifests/policy/
  installed-services-configmap.yaml` — the runtime add/remove lever.
- `tests/meshbridge/` — stdlib-only codec conformance tests (`test_codec.py`) against
  wire-format vectors generated from the official protobufs and committed as fixtures
  (`gen_vectors.py`, `vectors/wire_vectors.json`). There is no mock radio, mock
  homeserver or bridge-level integration test here.

The bridge app is dependency-free Python 3.12 (stdlib only, `python:3.12-alpine`
base — the `tuwunel-admin-sync` precedent): a hand-written codec for the small
Meshtastic protobuf subset the bridge speaks (`app/meshtastic_codec.py`
documents field numbers; verified against protoc-generated reference vectors in
`tests/meshbridge/vectors/`), stream framing `0x94 0xC3 <len_be16> <protobuf>`
(max 512), shared by serial and TCP transports.

# Meshtastic LoRa mesh ↔ Matrix bridge (`meshbridge`)

Attach LoRa mesh radios to the platform and bridge their text traffic into Matrix. A radio
attaches by USB-serial ("LoRa device attachments"), by WiFi/TCP ("LoRa-WiFi devices",
Meshtastic TCP API port 4403), or through a WAN-linked mesh on an MQTT broker. A room opts
in to a mesh channel, and messages arriving over the mesh appear in that room **as mesh
users**. Platform users can **register a mesh node id under their own name**, so their
radio's messages carry their name. Unregistered nodes appear as anonymous mesh nodes.
Matrix messages in mesh-enabled rooms go back out over the radio, so off-grid mesh
participants and Matrix participants share one conversation.

OPTIONAL SERVICE, DEFAULT-OFF, RUNTIME-ONLY (the coturn pattern). It has no baked bootstrap
Application. It is wired only through the `apps/13a` ApplicationSet element and the
`installed-services` ConfigMap flag (`meshbridge: "false"` by default). A default build is
byte-identical to a build without this feature.

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

- **Appservice, not bot accounts.** tuwunel (Conduit-family) registers application
  services through the admin room (`!admin appservices register` + registration YAML in a
  code block). See `manifests/meshbridge/meshbridge-register-job.yaml`, twinned on the
  `tuwunel-admin-sync` PostSync Job. The bridge claims the **exclusive user namespace
  `@mesh-.*`**. The homeserver refuses normal registration of those localparts, so nobody
  can squat a mesh identity.
- **In-namespace CS access** (`tuwunel:8008`, like the admin-sync Job), not the mTLS
  `tuwunel-proxy:4443`. Appservice tokens are not user-custody tokens and never cross the
  gateway, so the revocation-filter trade-off documented on the proxy does not apply.
- **Events reach the bridge by AS push.** tuwunel delivers room traffic for rooms that any
  `@mesh-*` user (or the `@meshbridge` sender) has joined, via
  `PUT /_matrix/app/v1/transactions/{txnId}` (hs_token-authenticated, txn-id-deduplicated).

## Identity model

| Mesh sender | Matrix identity | Display name |
|---|---|---|
| Node `!a1b2c3d4` registered by user `alice` | `@mesh-alice:<server>` | `<registered display name> (mesh)` |
| Unregistered node `!a1b2c3d4` | `@mesh-node-a1b2c3d4:<server>` | `<NODEINFO long name> · mesh !a1b2c3d4`, or `Mesh node !a1b2c3d4` before a name is heard |

Registration lives in **user-bff** (`POST/GET/DELETE /bff/user/mesh-devices` +
`PUT /{id}/visibility`). A node id is unique per platform, the owner is the validated JWT
subject, and a device is `active` or `revoked` by moderation.

The bridge polls the internal mapping (`GET /bff/user/internal/mesh-devices`, gated
`ROLE_SERVICE`) every 60 s. It authenticates with a Casdoor client-credentials token and
presents its Vault-PKI mTLS client cert, because user-bff terminates client-auth TLS. On
failure it keeps the last good copy (fail-soft: attribution degrades to anonymous, traffic
never blocks). It pushes LoRa status (last-seen, battery, SNR, hops) back on the same surface
(`POST .../status`), which feeds the per-device status and visibility feature
(`private`/`friends`/`channels`).

**Attribution honesty:** LoRa node ids are radio-asserted and NOT cryptographically
authenticated. Anyone with RF access can transmit as any node number. So registered
attribution renders as a *distinct virtual user* (`@mesh-alice`), never the user's real
account. Every bridged event carries `com.hugmesh.mesh` metadata (`{node, device, channel,
registered}` plus `rssi`, `snr` and `hops` when known), and the UI badges mesh-origin
messages "via LoRa mesh". Treat mesh attribution as convenience, not authentication.

## Per-room opt-in

Room state event **`net.hugmesh.mesh.bridge`** (state key `""`, power-level-gated like
`net.hugmesh.vn.scene`). The canonical wire prefix follows the `.net` domain move. On read,
the bridge also HONORS the legacy post-squash spelling `systems.hugmesh.mesh.bridge`, and
the canonical one wins when both exist. Only the canonical type is ever written.

```json
{ "enabled": true, "device": "default", "meshChannel": 0 }
```

The room-settings UI writes this and invites `@meshbridge:<server>`. The bridge auto-joins
on invite, reads the flag, and activates the (device, channel) ↔ room mapping. A disabled,
malformed or underprivileged event deactivates the mapping (the bridge re-checks the
*sender's* power level). The bridge stays joined: `MatrixClient.leave` exists in
`matrix_cs.py` and nothing calls it. Messages flow only for rooms with a valid, enabled flag.

## Message flow rules

- **Mesh → Matrix**: `TEXT_MESSAGE_APP` packets on a mapped (device, channel) are posted to
  each mapped room as the sender's virtual user. The bridge first ensures that user's
  profile and membership lazily: AS-register, set displayname, invite by `@meshbridge`,
  masquerade-join. A per-device packet-id LRU drops duplicate RF deliveries.
  A per-node token bucket (burst 10 / 30 s) guards the room against flooding.
- **Matrix → mesh**: `m.text` / `m.emote` from non-`@mesh-*` senders in mapped rooms become
  `<displayname>: <body>` (emote: `* <displayname> <body>`). The text is UTF-8-safe
  truncated into chunks of ≤ 233 bytes (`DATA_PAYLOAD_LEN`) and broadcast
  (`to=0xFFFFFFFF, want_ack`) on the mapped channel. The per-device send queue is paced (at
  least 2 s between transmits; LoRa airtime is scarce and duty-cycle regulated) and capped at
  50 (the oldest is dropped with a log line).
- **Loop guards**: own-namespace senders are skipped, AS transaction ids are deduped, and the
  bridge never re-forwards what it posted or transmitted itself.

## Device attachments

Devices are declared in the `meshbridge-devices` ConfigMap (key `devices.json`), mounted
into the pod:

```json
{ "devices": [
  { "id": "default",    "transport": "tcp",    "host": "10.20.0.50", "port": 4403 },
  { "id": "field-usb",  "transport": "serial", "path": "/dev/serial/by-id/usb-RAK_WisCore…-if00" },
  { "id": "wan-mesh",   "transport": "mqtt",   "host": "mqtt.lan", "port": 1883,
    "topicRoot": "msh/US", "channelName": "LongFast", "gatewayNodeNum": 2130636288 }
] }
```

- **`tcp` (LoRa-WiFi)** works from any node the pod schedules on (egress via the
  NetworkPolicy). It covers ESP32-class radios (Heltec V3, generic ESP32-S3+SX1262 boards)
  that expose the Meshtastic TCP client API.
- **`mqtt` (WAN-linked / LoRaWAN-gateway-style mesh)** reaches a remote mesh through
  Meshtastic's MQTT **JSON** integration on the operator's broker. Uplink is
  `<topicRoot>/2/json/<channelName>/#`. Downlink is published to `<topicRoot>/2/json/mqtt/`
  as `{"from": <gatewayNodeNum>, "type": "sendtext", ...}`. The gateway device needs
  `json_enabled` and a `downlink_enabled` channel named `mqtt`. nRF52-class boards (Heltec
  T114, ELECROW ThinkNode M1) have no WiFi: attach them by `serial` locally, or let them
  join over RF through any such gateway.
- **`serial` (USB attachment)** also needs the device file. Uncomment the hostPath volume
  and the nodeSelector pin in `manifests/meshbridge/deployment.yaml` (example inline), so the
  pod lands on the frontend node the radio is plugged into. It ships commented out; the
  default is TCP-only.
- The connect handshake (`want_config_id` → `my_info`/`node_info*`/`channel*` →
  `config_complete_id`) seeds the node-name db and validates the configured channel. The
  link reconnects with exponential backoff, and a 60 s heartbeat keeps TCP alive.

Admin-driven per-node attachment follows the node-storage idiom in three parts. Two exist in
admin-bff: `/bff/admin/device-radios` (device_registry-linked rows) and a SUPERADMIN-only
signed per-node export (`GET /export?node=<machine_key_fp>`). The third does not: no on-node
reconcile agent reads the export and writes this ConfigMap. The ConfigMap is the operator
surface until it does.

## Secrets

`meshbridge-appservice` (ESO ← Vault `hugmesh/meshbridge-appservice`) holds:

- `as_token`, `hs_token` — the appservice registration pair (generate two long random
  strings at provision time);
- `oidc_client_id`, `oidc_client_secret` — the Casdoor client-credentials client
  (ROLE_SERVICE) for user-bff's internal surface;
- `mqtt_password` — optional, for authenticated brokers.

The user-bff leg also presents a Vault-PKI mTLS client cert. No literal ever lands in git. If
the Vault path is absent, the Secret never materializes and the pod stays Pending (the
service is default-off anyway).

## Files

- `specs/cluster/manifests/meshbridge/` — kustomization (app ConfigMap via
  `configMapGenerator` from `app/*.py`), deployment + service, network policy, devices
  ConfigMap, appservice-registration PostSync Job.
- `specs/cluster/manifests/external-secrets/meshbridge-externalsecrets.yaml`
- `specs/cluster/optional-services.yaml` — registry entry (runtime-only, `dependsOn: tuwunel`).
- `specs/cluster/apps/13a-optional-services.yaml` + `manifests/policy/
  installed-services-configmap.yaml` — the runtime add/remove lever.
- `tests/meshbridge/` — stdlib-only codec conformance tests (`test_codec.py`) against
  wire-format vectors generated from the official protobufs and committed as fixtures
  (`gen_vectors.py`, `vectors/wire_vectors.json`). There is no mock radio, mock homeserver
  or bridge-level integration test here.

The bridge app is dependency-free Python 3.12 (stdlib only, `python:3.12-alpine` base, the
`tuwunel-admin-sync` precedent). It has a hand-written codec for the small Meshtastic
protobuf subset the bridge speaks (`app/meshtastic_codec.py` documents field numbers; checked
against protoc-generated reference vectors in `tests/meshbridge/vectors/`). Stream framing is
`0x94 0xC3 <len_be16> <protobuf>` (max 512), shared by the serial and TCP transports.

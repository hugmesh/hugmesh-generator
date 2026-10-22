"""The bridge core: room mappings, mesh identities, and the two message
directions. Transport- and HTTP-agnostic — transports feed device events in,
the AS server feeds Matrix transactions in, and everything outbound goes
through the injected MatrixClient / UserBffClient / links, which is what makes
the whole core unit-testable with fakes (tests/meshbridge/).

Identity model (docs/MESHTASTIC-BRIDGE.md):
  registered node  -> @mesh-<owner localpart>   "<owner display> (mesh)"
  anonymous node   -> @mesh-node-<hex8>         "<long name> · mesh !<hex8>"
Registration rows come from user-bff (poll task, fail-soft last-good); LoRa
node ids are radio-asserted, so registered attribution is always a DISTINCT
virtual user and every bridged event carries com.hugmesh.mesh metadata.

Trust boundaries enforced here:
  - a room's mesh flag only counts when its SENDER held the power level the
    room requires for that state event (hostile/underprivileged flips ignored)
  - per-node token bucket (mesh -> Matrix floods), per-device pacing upstream
    in transports (Matrix -> mesh floods)
  - AS transactions and radio packet ids are deduplicated (both sides retry)
  - the bridge's own users/echoes are never re-forwarded in either direction
"""

from __future__ import annotations

import asyncio
import logging
import re
import time
from collections import OrderedDict, deque

import meshtastic_codec as codec
from matrix_cs import ClientError, MatrixError

log = logging.getLogger("meshbridge.core")

# Canonical wire name follows the .net domain move (the same reasoning as the
# Java package rename systems.hugmesh -> net.hugmesh). Rooms may still carry
# the OLDER post-squash systems.hugmesh spelling, so the bridge HONORS both on
# read. Precedence when a room carries both: canonical first, then the legacy
# one (refresh_room scans in MESH_STATE_TYPES order). Writers (the
# matrix-ui room-settings section) mint ONLY the canonical type.
MESH_STATE_TYPE = "net.hugmesh.mesh.bridge"
LEGACY_MESH_STATE_TYPES = ("systems.hugmesh.mesh.bridge",)
MESH_STATE_TYPES = (MESH_STATE_TYPE, *LEGACY_MESH_STATE_TYPES)
MESH_META_KEY = "com.hugmesh.mesh"

_DEVICE_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
_LOCALPART_SAFE_RE = re.compile(r"[^a-z0-9._=/-]")

NODE_BUCKET_CAPACITY = 10        # mesh->Matrix burst per node
NODE_BUCKET_WINDOW = 30.0        # seconds to fully refill
TXN_LRU = 128
PKT_LRU = 512
MAX_CHUNKS_PER_MESSAGE = 4       # Matrix->mesh airtime cap per message
PROFILE_CACHE_TTL = 600.0
ONLINE_WINDOW_SECONDS = 300      # "online" = heard in the last 5 minutes


def chunk_utf8(text: str, limit: int = codec.DATA_PAYLOAD_LEN,
               max_chunks: int = MAX_CHUNKS_PER_MESSAGE) -> list[bytes]:
    """Split text into <=limit-byte UTF-8 chunks on codepoint boundaries.
    Anything beyond max_chunks is dropped and the last chunk gets an ellipsis
    (LoRa airtime is the scarce resource, not Matrix history)."""
    raw = text.encode("utf-8")
    if len(raw) <= limit:
        return [raw]
    chunks: list[bytes] = []
    current = bytearray()
    for ch in text:
        b = ch.encode("utf-8")
        if len(current) + len(b) > limit:
            chunks.append(bytes(current))
            current = bytearray()
            if len(chunks) == max_chunks:
                break
        current.extend(b)
    else:
        if current:
            chunks.append(bytes(current))
    if len(chunks) >= max_chunks and (current or len(chunks) > max_chunks):
        marker = " …".encode("utf-8")
        last = chunks[max_chunks - 1]
        while len(last) + len(marker) > limit:
            # strip trailing codepoint bytes (continuation bytes start 0b10xxxxxx)
            cut = len(last) - 1
            while cut > 0 and (last[cut] & 0xC0) == 0x80:
                cut -= 1
            last = last[:cut]
        chunks = chunks[:max_chunks - 1] + [last + marker]
    return [c for c in chunks if c]


def parse_mesh_flag(raw: object) -> dict | None:
    """Tolerant parse of the room flag content — mirrors the matrix-ui clamps
    exactly, so both ends agree on what a malformed flag means."""
    if not isinstance(raw, dict):
        return None
    device = raw.get("device")
    if not isinstance(device, str) or not _DEVICE_ID_RE.match(device):
        device = "default"
    channel = raw.get("meshChannel")
    if not isinstance(channel, int) or isinstance(channel, bool):
        channel = 0
    channel = min(7, max(0, channel))
    return {"enabled": raw.get("enabled") is True, "device": device,
            "meshChannel": channel}


def sender_may_set_flag(state_events: list[dict], sender: str,
                        flag_type: str = MESH_STATE_TYPE) -> bool:
    """True when `sender` holds the room's required power level for the mesh
    flag state event (events[type] override, else state_default). `flag_type`
    is the SPELLING of the honored flag event — a legacy-named flag is gated by
    its own type's power-level entry, exactly as the homeserver enforced it
    when that event was accepted."""
    pl_content: dict = {}
    for e in state_events:
        if e.get("type") == "m.room.power_levels" and e.get("state_key", "") == "":
            content = e.get("content")
            if isinstance(content, dict):
                pl_content = content
            break
    users = pl_content.get("users") if isinstance(pl_content.get("users"), dict) else {}
    users_default = pl_content.get("users_default", 0)
    sender_level = users.get(sender, users_default)
    if not isinstance(sender_level, int):
        sender_level = 0
    events = pl_content.get("events") if isinstance(pl_content.get("events"), dict) else {}
    required = events.get(flag_type, pl_content.get("state_default", 50))
    if not isinstance(required, int):
        required = 50
    return sender_level >= required


class _TokenBucket:
    def __init__(self, capacity: int, window: float) -> None:
        self.capacity = capacity
        self.rate = capacity / window
        self.tokens = float(capacity)
        self.stamp = time.monotonic()

    def allow(self) -> bool:
        now = time.monotonic()
        self.tokens = min(self.capacity, self.tokens + (now - self.stamp) * self.rate)
        self.stamp = now
        if self.tokens >= 1:
            self.tokens -= 1
            return True
        return False


class _Lru:
    def __init__(self, cap: int) -> None:
        self.cap = cap
        self._d: OrderedDict = OrderedDict()

    def seen(self, key) -> bool:
        """True if key was already recorded; records it otherwise."""
        if key in self._d:
            self._d.move_to_end(key)
            return True
        self._d[key] = None
        if len(self._d) > self.cap:
            self._d.popitem(last=False)
        return False


class Bridge:
    def __init__(self, matrix, links: dict, userbff=None, *,
                 reg_poll_seconds: int = 60, status_push_seconds: int = 30) -> None:
        self.matrix = matrix
        self.links = links
        self.userbff = userbff
        self.reg_poll_seconds = reg_poll_seconds
        self.status_push_seconds = status_push_seconds

        self.mappings: dict[str, dict] = {}          # room_id -> validated flag
        self.registrations: dict[str, dict] = {}     # node_id -> mapping row
        self.node_db: dict[str, dict] = {}           # node_id -> live status
        self._txn_seen = _Lru(TXN_LRU)
        self._pkt_seen = _Lru(PKT_LRU)
        self._node_buckets: dict[str, _TokenBucket] = {}
        self._prepared: dict[str, str] = {}          # mesh localpart -> displayname set
        self._joined: set[tuple[str, str]] = set()   # (room_id, mxid) best-effort cache
        self._profiles: dict[str, tuple[float, str]] = {}  # mxid -> (ts, display)
        self._status_dirty: set[str] = set()
        self._encrypted_warned: set[str] = set()
        self._loop: asyncio.AbstractEventLoop | None = None
        self.started = time.monotonic()
        self.counters = {"mesh_to_matrix": 0, "matrix_to_mesh": 0,
                         "dropped_rate_limited": 0, "dropped_unmapped": 0}

    # ── bootstrap + background tasks ─────────────────────────────────────────

    async def bootstrap(self) -> None:
        """Rebuild room mappings from the bot's joined rooms (pod restart)."""
        try:
            rooms = await self.matrix.joined_rooms()
        except MatrixError as e:
            log.warning("bootstrap joined_rooms failed (%s) — continuing empty", e)
            return
        for room_id in rooms:
            await self.refresh_room(room_id)
        log.info("bootstrap: %d joined room(s), %d mesh-enabled",
                 len(rooms), len(self.mappings))

    async def run_registration_poller(self) -> None:
        while True:
            if self.userbff is not None:
                try:
                    rows = await self.userbff.fetch_mappings()
                    self.registrations = {r["nodeId"]: r for r in rows}
                    log.debug("registrations: %d row(s)", len(rows))
                except ClientError as e:
                    log.warning("registration poll failed (keeping %d last-good): %s",
                                len(self.registrations), e)
            await asyncio.sleep(self.reg_poll_seconds)

    async def run_status_pusher(self) -> None:
        while True:
            await asyncio.sleep(self.status_push_seconds)
            if self.userbff is None or not self._status_dirty:
                continue
            batch = []
            for node_id in list(self._status_dirty):
                if node_id not in self.registrations:
                    self._status_dirty.discard(node_id)
                    continue
                info = self.node_db.get(node_id)
                if not info:
                    self._status_dirty.discard(node_id)
                    continue
                batch.append({
                    "nodeId": node_id,
                    "lastSeenAt": info.get("last_heard_iso"),
                    "batteryPct": info.get("battery"),
                    "snr": info.get("snr"),
                    "hopsAway": info.get("hops"),
                    "viaDevice": info.get("via_device"),
                })
            if not batch:
                continue
            try:
                await self.userbff.push_status(batch)
                self._status_dirty.clear()
            except ClientError as e:
                log.warning("status push failed (%d row(s) kept dirty): %s",
                            len(batch), e)

    def health_snapshot(self) -> dict:
        return {
            "ok": True,
            "uptimeSeconds": int(time.monotonic() - self.started),
            "devices": [link.status() for link in self.links.values()],
            "meshRooms": len(self.mappings),
            "registrations": len(self.registrations),
            "nodesSeen": len(self.node_db),
            "counters": dict(self.counters),
        }

    # ── room mapping upkeep ──────────────────────────────────────────────────

    async def refresh_room(self, room_id: str) -> None:
        """Re-derive this room's mapping from full room state: flag content,
        flag SENDER power level, and the flag's device existing."""
        try:
            state = await self.matrix.room_state(room_id)
        except MatrixError as e:
            log.warning("room %s state fetch failed: %s", room_id, e)
            return
        # Canonical spelling wins; each legacy generation is honored only when
        # no newer-named flag exists (MESH_STATE_TYPES is precedence-ordered).
        flag_event = None
        for wanted in MESH_STATE_TYPES:
            for e in state:
                if e.get("type") == wanted and e.get("state_key", "") == "":
                    flag_event = e
                    break
            if flag_event is not None:
                break
        old = self.mappings.get(room_id)
        new = None
        if flag_event is not None:
            flag = parse_mesh_flag(flag_event.get("content"))
            if flag and flag["enabled"]:
                if not sender_may_set_flag(state, flag_event.get("sender", ""),
                                           flag_event.get("type", MESH_STATE_TYPE)):
                    log.warning("room %s: mesh flag from underprivileged sender %s "
                                "ignored", room_id, flag_event.get("sender"))
                elif flag["device"] not in self.links:
                    log.warning("room %s: mesh flag names unknown device %r",
                                room_id, flag["device"])
                else:
                    new = flag
        if new != old:
            if new:
                self.mappings[room_id] = new
                log.info("room %s mesh-enabled (device=%s ch=%d)",
                         room_id, new["device"], new["meshChannel"])
            else:
                self.mappings.pop(room_id, None)
                log.info("room %s mesh-disabled", room_id)

    def _rooms_for(self, device: str, channel: int) -> list[str]:
        return [room for room, m in self.mappings.items()
                if m["device"] == device and m["meshChannel"] == channel]

    # ── Matrix -> mesh ───────────────────────────────────────────────────────

    def attach_loop(self, loop: asyncio.AbstractEventLoop) -> None:
        """main.py hands over the running loop before the AS server starts —
        submit_transaction() is called from HTTP server threads."""
        self._loop = loop

    def submit_transaction(self, txn_id: str, events: list) -> None:
        """Thread-safe entry from the AS server; schedules async handling."""
        if self._loop is None:
            log.warning("transaction %s before loop attach — dropped "
                        "(homeserver will redeliver)", txn_id)
            return
        self._loop.call_soon_threadsafe(
            lambda: asyncio.ensure_future(self.on_transaction(txn_id, events)))

    async def on_transaction(self, txn_id: str, events: list) -> None:
        if self._txn_seen.seen(txn_id):
            return
        for event in events:
            if not isinstance(event, dict):
                continue
            try:
                await self._on_event(event)
            except (MatrixError, ClientError) as e:
                log.warning("event %s handling failed: %s",
                            event.get("event_id", "?"), e)

    async def _on_event(self, event: dict) -> None:
        etype = event.get("type")
        room_id = event.get("room_id", "")
        sender = event.get("sender", "")
        if not room_id:
            return
        if etype == "m.room.member" and event.get("state_key") == self.matrix.bot_mxid:
            membership = (event.get("content") or {}).get("membership")
            if membership == "invite":
                try:
                    await self.matrix.join(room_id)
                    log.info("joined %s on invite from %s", room_id, sender)
                except MatrixError as e:
                    log.warning("join %s failed: %s", room_id, e)
                    return
                await self.refresh_room(room_id)
            elif membership in ("leave", "ban"):
                self.mappings.pop(room_id, None)
                log.info("bot removed from %s (%s) — mapping dropped",
                         room_id, membership)
            return
        if etype in MESH_STATE_TYPES or etype == "m.room.power_levels":
            await self.refresh_room(room_id)
            return
        if etype == "m.room.encrypted":
            if room_id in self.mappings and room_id not in self._encrypted_warned:
                self._encrypted_warned.add(room_id)
                log.warning("room %s is encrypted — the mesh bridge cannot "
                            "forward E2EE messages", room_id)
            return
        if etype == "m.room.message":
            await self._on_matrix_message(room_id, sender, event)

    async def _on_matrix_message(self, room_id: str, sender: str, event: dict) -> None:
        mapping = self.mappings.get(room_id)
        if mapping is None:
            return
        if sender == self.matrix.bot_mxid or sender.startswith("@mesh-"):
            return  # never loop our own namespace back onto the air
        content = event.get("content") or {}
        msgtype = content.get("msgtype")
        body = content.get("body")
        if msgtype not in ("m.text", "m.emote") or not isinstance(body, str) or not body:
            return
        display = await self._display_for(sender)
        line = f"* {display} {body}" if msgtype == "m.emote" else f"{display}: {body}"
        link = self.links.get(mapping["device"])
        if link is None:
            self.counters["dropped_unmapped"] += 1
            return
        for chunk in chunk_utf8(line):
            await link.send_text(mapping["meshChannel"], chunk)
        self.counters["matrix_to_mesh"] += 1

    async def _display_for(self, mxid: str) -> str:
        cached = self._profiles.get(mxid)
        now = time.monotonic()
        if cached and now - cached[0] < PROFILE_CACHE_TTL:
            return cached[1]
        display = mxid.split(":", 1)[0].lstrip("@")
        try:
            payload = await self.matrix._call(  # noqa: SLF001 - deliberate thin reuse
                "GET", f"/_matrix/client/v3/profile/{mxid}/displayname")
            got = payload.get("displayname")
            if isinstance(got, str) and got.strip():
                display = got.strip()
        except MatrixError:
            pass  # profile-less users fall back to the localpart
        self._profiles[mxid] = (now, display)
        if len(self._profiles) > 512:
            self._profiles.pop(next(iter(self._profiles)))
        return display

    # ── mesh -> Matrix ───────────────────────────────────────────────────────

    async def on_device_event(self, evt: dict) -> None:
        kind = evt.get("kind")
        if kind == "text":
            await self._on_mesh_text(evt)
        elif kind == "nodeinfo":
            self._on_nodeinfo(evt)
        elif kind == "telemetry":
            self._on_telemetry(evt)
        elif kind == "link":
            log.info("device %s %s", evt.get("device"),
                     "connected" if evt.get("connected") else "disconnected")

    def _touch_node(self, node_id: str, device: str) -> dict:
        info = self.node_db.setdefault(node_id, {})
        info["last_heard"] = time.monotonic()
        info["last_heard_iso"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        info["via_device"] = device
        if node_id in self.registrations:
            self._status_dirty.add(node_id)
        return info

    def _on_nodeinfo(self, evt: dict) -> None:
        node_id = evt.get("node_id") or codec.node_id_from_num(evt.get("num", 0))
        info = self._touch_node(node_id, evt.get("device", ""))
        info["long_name"] = (evt.get("long_name") or "")[:64]
        info["short_name"] = (evt.get("short_name") or "")[:8]

    def _on_telemetry(self, evt: dict) -> None:
        node_id = codec.node_id_from_num(evt.get("from", 0))
        info = self._touch_node(node_id, evt.get("device", ""))
        battery = evt.get("battery")
        if isinstance(battery, int) and 0 <= battery <= 101:
            info["battery"] = battery

    async def _on_mesh_text(self, evt: dict) -> None:
        device = evt.get("device", "")
        channel = evt.get("channel", 0)
        src = evt.get("from", 0)
        text = evt.get("text", "")
        node_id = codec.node_id_from_num(src)
        pkt_id = evt.get("id") or 0
        if pkt_id and self._pkt_seen.seen((device, src, pkt_id)):
            return  # RF duplicate / gateway re-delivery
        info = self._touch_node(node_id, device)
        if isinstance(evt.get("snr"), (int, float)):
            info["snr"] = round(float(evt["snr"]), 2)
        if isinstance(evt.get("hops"), int):
            info["hops"] = evt["hops"]

        rooms = self._rooms_for(device, channel)
        if not rooms:
            self.counters["dropped_unmapped"] += 1
            return
        bucket = self._node_buckets.setdefault(
            node_id, _TokenBucket(NODE_BUCKET_CAPACITY, NODE_BUCKET_WINDOW))
        if not bucket.allow():
            self.counters["dropped_rate_limited"] += 1
            log.warning("node %s rate-limited (mesh->Matrix)", node_id)
            return

        reg = self.registrations.get(node_id)
        if reg:
            localpart = "mesh-" + self._safe_localpart(reg["localpart"])
            display = f"{reg['displayName']} (mesh)"
        else:
            localpart = f"mesh-node-{node_id[1:]}"
            long_name = info.get("long_name", "")
            display = (f"{long_name} · mesh {node_id}" if long_name
                       else f"Mesh node {node_id}")
        mxid = self.matrix.mesh_mxid(localpart)
        await self._prepare_user(localpart, mxid, display)

        content = {
            "msgtype": "m.text",
            "body": text,
            MESH_META_KEY: {
                "node": node_id,
                "device": device,
                "channel": channel,
                "registered": bool(reg),
                **({"rssi": evt["rssi"]} if isinstance(evt.get("rssi"), int) else {}),
                **({"snr": info["snr"]} if "snr" in info else {}),
                **({"hops": info["hops"]} if "hops" in info else {}),
            },
        }
        for room_id in rooms:
            try:
                await self._ensure_membership(room_id, mxid)
                await self.matrix.send_message(room_id, mxid, content)
                self.counters["mesh_to_matrix"] += 1
            except MatrixError as e:
                log.warning("deliver %s -> %s failed: %s", node_id, room_id, e)

    def _safe_localpart(self, localpart: str) -> str:
        cleaned = _LOCALPART_SAFE_RE.sub("", localpart.lower())
        return cleaned or "user"

    async def _prepare_user(self, localpart: str, mxid: str, display: str) -> None:
        if self._prepared.get(localpart) == display:
            return
        if localpart not in self._prepared:
            await self.matrix.ensure_registered(localpart)
        try:
            await self.matrix.set_displayname(mxid, display)
        except MatrixError as e:
            log.warning("set displayname %s failed: %s", mxid, e)
        self._prepared[localpart] = display

    async def _ensure_membership(self, room_id: str, mxid: str) -> None:
        if (room_id, mxid) in self._joined:
            return
        await self.matrix.invite(room_id, mxid)   # tolerant of already-in-room
        await self.matrix.join(room_id, user_id=mxid)
        self._joined.add((room_id, mxid))
        if len(self._joined) > 4096:
            self._joined.pop()

"""Device transports — one class per way a mesh can be attached to the bridge:

  TcpRadioLink     "LoRa-WiFi" radios: the Meshtastic client API over TCP :4403
  SerialRadioLink  USB LoRa attachments: same framed stream over a serial tty
  MqttMeshLink     WAN-linked / LoRaWAN-gateway-style meshes: the Meshtastic
                   MQTT *JSON* integration on the operator's broker

All three normalize inbound traffic to plain EVENT dicts handed to a single
async callback, and expose the same outbound `send_text(channel, payload)`;
the bridge core neither knows nor cares which transport a device uses.

Event shapes (all carry "device": <device id>):
  {"kind":"text", "channel":int, "from":int, "id":int, "text":str,
   "rssi":int|None, "snr":float|None, "hops":int|None}
  {"kind":"nodeinfo", "num":int, "node_id":"!hex8",
   "long_name":str, "short_name":str}
  {"kind":"telemetry", "from":int, "battery":int|None, "voltage":float|None}
  {"kind":"link", "connected":bool, "my_node_num":int|None}

Outbound sends are queued per device (cap OUT_QUEUE_MAX, oldest dropped with a
log line) and PACED (SEND_PACE_SECONDS apart): LoRa airtime is scarce and
duty-cycle regulated, so the bridge never bursts the radio. Reconnects use
exponential backoff and re-run the config handshake; each link keeps a small
"recently sent" list so its own transmissions echoed back (e.g. by an MQTT
gateway uplinking our downlink) are not re-bridged.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import struct
import time

import meshtastic_codec as codec

log = logging.getLogger("meshbridge.transports")

SEND_PACE_SECONDS = 2.0
OUT_QUEUE_MAX = 50
HEARTBEAT_SECONDS = 60
HANDSHAKE_TIMEOUT = 30
BACKOFF_START, BACKOFF_MAX = 1, 60
ECHO_TTL_SECONDS = 120
ECHO_MAX = 64


def _new_packet_id() -> int:
    """Random nonzero 32-bit seed; callers increment per send (the reference
    client's idiom — ids only need per-sender uniqueness over a short window)."""
    while True:
        v = int.from_bytes(os.urandom(4), "big") & 0xFFFFFFFF
        if v:
            return v


class _EchoGuard:
    """Remembers (channel, text) the link itself sent recently, so a gateway or
    radio echoing our own transmission back does not re-enter the bridge."""

    def __init__(self) -> None:
        self._sent: list[tuple[float, int, str]] = []

    def remember(self, channel: int, text: str) -> None:
        self._sent.append((time.monotonic(), channel, text))
        if len(self._sent) > ECHO_MAX:
            del self._sent[0: len(self._sent) - ECHO_MAX]

    def is_echo(self, channel: int, text: str) -> bool:
        cutoff = time.monotonic() - ECHO_TTL_SECONDS
        self._sent = [e for e in self._sent if e[0] >= cutoff]
        return any(c == channel and t == text for _, c, t in self._sent)


class BaseLink:
    """Shared shape: an outbound paced queue + a supervised run() loop."""

    def __init__(self, device_id: str, on_event) -> None:
        self.device_id = device_id
        self.on_event = on_event  # async callable(event_dict)
        self.connected = False
        self.my_node_num: int | None = None
        self._out: asyncio.Queue = asyncio.Queue(maxsize=OUT_QUEUE_MAX)
        self._echo = _EchoGuard()
        self._stopping = False

    # -- public API ------------------------------------------------------------

    async def send_text(self, channel: int, payload: bytes) -> None:
        """Queue one <=DATA_PAYLOAD_LEN chunk for transmission. Never blocks:
        when the queue is full the OLDEST entry is dropped (a stalled radio
        must not back-pressure Matrix)."""
        item = (int(channel), bytes(payload))
        try:
            self._out.put_nowait(item)
        except asyncio.QueueFull:
            try:
                dropped = self._out.get_nowait()
                log.warning("%s: send queue full, dropped oldest (ch%d, %dB)",
                            self.device_id, dropped[0], len(dropped[1]))
            except asyncio.QueueEmpty:  # pragma: no cover - race window only
                pass
            self._out.put_nowait(item)

    def status(self) -> dict:
        return {
            "device": self.device_id,
            "connected": self.connected,
            "myNodeNum": self.my_node_num,
            "outQueue": self._out.qsize(),
        }

    def stop(self) -> None:
        self._stopping = True

    async def run(self) -> None:
        """Supervise connect/serve with exponential backoff, forever."""
        backoff = BACKOFF_START
        while not self._stopping:
            try:
                await self._connect_and_serve()
                backoff = BACKOFF_START
            except asyncio.CancelledError:
                raise
            except Exception as e:
                log.warning("%s: link error: %s", self.device_id, e)
            if self.connected:
                self.connected = False
                await self._emit_link()
            if self._stopping:
                return
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, BACKOFF_MAX)

    # -- helpers for subclasses -------------------------------------------------

    async def _emit_link(self) -> None:
        await self.on_event({"kind": "link", "device": self.device_id,
                             "connected": self.connected,
                             "my_node_num": self.my_node_num})

    async def _connect_and_serve(self) -> None:  # pragma: no cover - abstract
        raise NotImplementedError


class _StreamRadioLink(BaseLink):
    """Common logic for the two framed-stream transports (TCP + serial):
    the want_config handshake, FromRadio event mapping, heartbeats, pacing."""

    def __init__(self, device_id: str, on_event) -> None:
        super().__init__(device_id, on_event)
        self._parser = codec.StreamParser()
        self._packet_id = _new_packet_id()
        self._config_done = asyncio.Event()

    # subclasses provide raw byte I/O
    async def _open(self) -> None:
        raise NotImplementedError

    async def _read_chunk(self) -> bytes:
        raise NotImplementedError

    async def _write(self, data: bytes) -> None:
        raise NotImplementedError

    async def _close(self) -> None:
        raise NotImplementedError

    async def _connect_and_serve(self) -> None:
        self._parser = codec.StreamParser()
        self._config_done = asyncio.Event()
        await self._open()
        try:
            # Wake a possibly-sleeping radio the way the reference client does
            # (a run of START2 bytes forces the deframer on the radio to resync),
            # then ask for the config + node-db dump.
            await self._write(bytes([codec.START2]) * 32)
            nonce = _new_packet_id()
            await self._write(codec.frame(codec.build_want_config(nonce)))

            reader = asyncio.create_task(self._read_loop())
            sender = asyncio.create_task(self._send_loop())
            beater = asyncio.create_task(self._heartbeat_loop())
            try:
                await asyncio.wait_for(self._config_done.wait(), HANDSHAKE_TIMEOUT)
                self.connected = True
                await self._emit_link()
                # serve until the read loop ends (EOF / link error)
                await reader
            finally:
                for t in (reader, sender, beater):
                    t.cancel()
                await asyncio.gather(reader, sender, beater, return_exceptions=True)
        finally:
            await self._close()

    async def _read_loop(self) -> None:
        while True:
            chunk = await self._read_chunk()
            if not chunk:
                raise ConnectionError("stream closed by radio")
            for payload in self._parser.feed(chunk):
                try:
                    msg = codec.parse_from_radio(payload)
                except codec.DecodeError as e:
                    log.warning("%s: undecodable frame (%s)", self.device_id, e)
                    continue
                await self._handle_from_radio(msg)

    async def _send_loop(self) -> None:
        while True:
            channel, payload = await self._out.get()
            self._packet_id = (self._packet_id + 1) & 0xFFFFFFFF or 1
            wire = codec.frame(codec.build_text_packet(channel, payload, self._packet_id))
            self._echo.remember(channel, payload.decode("utf-8", errors="replace"))
            await self._write(wire)
            await asyncio.sleep(SEND_PACE_SECONDS)

    async def _heartbeat_loop(self) -> None:
        while True:
            await asyncio.sleep(HEARTBEAT_SECONDS)
            await self._write(codec.frame(codec.build_heartbeat()))

    async def _handle_from_radio(self, msg: dict) -> None:
        if "my_info" in msg:
            self.my_node_num = msg["my_info"].get("my_node_num")
            return
        if "config_complete_id" in msg:
            self._config_done.set()
            return
        if "node_info" in msg:
            ni = msg["node_info"]
            user = ni.get("user") or {}
            num = ni.get("num")
            if num is None:
                return
            await self.on_event({
                "kind": "nodeinfo", "device": self.device_id, "num": num,
                "node_id": (user.get("id") or codec.node_id_from_num(num)).lower(),
                "long_name": user.get("long_name", ""),
                "short_name": user.get("short_name", ""),
            })
            return
        if "client_notification" in msg:
            note = msg["client_notification"]
            log.warning("%s: radio notification: %s", self.device_id,
                        note.get("message", ""))
            return
        if "queue_status" in msg:
            qs = msg["queue_status"]
            if qs.get("res", 0) != 0:
                log.warning("%s: radio enqueue failed res=%s", self.device_id,
                            qs.get("res"))
            return
        packet = msg.get("packet")
        if not packet:
            return
        decoded = packet.get("decoded")
        if not decoded:
            return  # encrypted-only packets are not bridgeable
        src = packet.get("from", 0)
        if self.my_node_num is not None and src == self.my_node_num:
            return  # our own radio's transmissions are never re-bridged
        port = decoded.get("portnum")
        if port == codec.PORT_TEXT_MESSAGE_APP:
            text = (decoded.get("payload") or b"").decode("utf-8", errors="replace")
            if not text or self._echo.is_echo(packet.get("channel", 0), text):
                return
            await self.on_event({
                "kind": "text", "device": self.device_id,
                "channel": packet.get("channel", 0), "from": src,
                "id": packet.get("id", 0), "text": text,
                "rssi": packet.get("rx_rssi"), "snr": packet.get("rx_snr"),
                "hops": self._hops(packet),
            })
        elif port == codec.PORT_TELEMETRY_APP:
            try:
                tel = codec.parse_telemetry(decoded.get("payload") or b"")
            except codec.DecodeError:
                return
            metrics = tel.get("device_metrics")
            if metrics:
                await self.on_event({
                    "kind": "telemetry", "device": self.device_id, "from": src,
                    "battery": metrics.get("battery_level"),
                    "voltage": metrics.get("voltage"),
                })

    @staticmethod
    def _hops(packet: dict) -> int | None:
        start, limit = packet.get("hop_start"), packet.get("hop_limit")
        if start is None or limit is None:
            return None
        hops = start - limit
        return hops if 0 <= hops <= 7 else None


class TcpRadioLink(_StreamRadioLink):
    """A LoRa-WiFi radio reachable over the Meshtastic TCP client API (:4403)."""

    def __init__(self, device_id: str, host: str, port: int, on_event) -> None:
        super().__init__(device_id, on_event)
        self.host, self.port = host, int(port)
        self._reader: asyncio.StreamReader | None = None
        self._writer: asyncio.StreamWriter | None = None

    async def _open(self) -> None:
        self._reader, self._writer = await asyncio.wait_for(
            asyncio.open_connection(self.host, self.port), 15)
        log.info("%s: connected tcp://%s:%d", self.device_id, self.host, self.port)

    async def _read_chunk(self) -> bytes:
        assert self._reader is not None
        return await self._reader.read(4096)

    async def _write(self, data: bytes) -> None:
        assert self._writer is not None
        self._writer.write(data)
        await self._writer.drain()

    async def _close(self) -> None:
        if self._writer is not None:
            self._writer.close()
            try:
                await self._writer.wait_closed()
            except Exception:  # noqa: BLE001 - best-effort close
                pass
        self._reader = self._writer = None


class SerialRadioLink(_StreamRadioLink):
    """A USB LoRa attachment: the same framed stream over a raw serial tty.
    termios setup is stdlib-only (no pyserial on the alpine image)."""

    BAUD_ATTR = "B115200"  # Meshtastic client API serial rate

    def __init__(self, device_id: str, path: str, on_event) -> None:
        super().__init__(device_id, on_event)
        self.path = path
        self._fd: int | None = None
        self._rx: asyncio.Queue = asyncio.Queue()

    async def _open(self) -> None:
        import termios

        fd = os.open(self.path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        try:
            attrs = termios.tcgetattr(fd)
            # cfmakeraw equivalent
            attrs[0] = 0                      # iflag
            attrs[1] = 0                      # oflag
            attrs[2] = (termios.CS8 | termios.CREAD | termios.CLOCAL)  # cflag
            attrs[3] = 0                      # lflag
            baud = getattr(termios, self.BAUD_ATTR)
            attrs[4] = attrs[5] = baud        # ispeed/ospeed
            attrs[6][termios.VMIN] = 0
            attrs[6][termios.VTIME] = 0
            termios.tcsetattr(fd, termios.TCSANOW, attrs)
        except Exception:
            os.close(fd)
            raise
        self._fd = fd
        loop = asyncio.get_running_loop()
        loop.add_reader(fd, self._on_readable)
        log.info("%s: opened serial %s", self.device_id, self.path)

    def _on_readable(self) -> None:
        assert self._fd is not None
        try:
            data = os.read(self._fd, 4096)
        except BlockingIOError:
            return
        except OSError as e:
            self._rx.put_nowait(e)
            return
        # empty read on a tty just means "nothing right now" — do not treat as EOF
        if data:
            self._rx.put_nowait(data)

    async def _read_chunk(self) -> bytes:
        item = await self._rx.get()
        if isinstance(item, Exception):
            raise ConnectionError(f"serial read failed: {item}")
        return item

    async def _write(self, data: bytes) -> None:
        assert self._fd is not None
        view = memoryview(data)
        while view:
            try:
                n = os.write(self._fd, view)
            except BlockingIOError:
                await asyncio.sleep(0.01)
                continue
            view = view[n:]

    async def _close(self) -> None:
        if self._fd is not None:
            try:
                asyncio.get_running_loop().remove_reader(self._fd)
            except Exception:  # noqa: BLE001
                pass
            try:
                os.close(self._fd)
            except OSError:
                pass
            self._fd = None


# ── MQTT (WAN-linked / LoRaWAN-gateway meshes) ────────────────────────────────

_MQTT_CONNECT, _MQTT_CONNACK = 0x10, 0x20
_MQTT_PUBLISH = 0x30
_MQTT_SUBSCRIBE, _MQTT_SUBACK = 0x82, 0x90
_MQTT_PINGREQ, _MQTT_PINGRESP = 0xC0, 0xD0
_MQTT_DISCONNECT = 0xE0
_MQTT_KEEPALIVE = 60


def _mqtt_string(s: str) -> bytes:
    raw = s.encode("utf-8")
    return struct.pack(">H", len(raw)) + raw


def _mqtt_remaining_length(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n % 128
        n //= 128
        out.append(b | 0x80 if n else b)
        if not n:
            return bytes(out)


class MqttMeshLink(BaseLink):
    """A mesh reached through Meshtastic's MQTT **JSON** integration — the way
    a mesh rides WAN/LoRaWAN-style gateway infrastructure. The gateway node
    needs `json_enabled` and (for downlink) a `downlink_enabled` channel named
    "mqtt" — see docs/MESHTASTIC-BRIDGE.md.

    Uplink:   subscribe  <topicRoot>/2/json/<channelName>/#
    Downlink: publish to <topicRoot>/2/json/mqtt/  {"from": <gatewayNodeNum>,
              "type": "sendtext", "payload": <text>, "channel": <idx>}

    The MQTT 3.1.1 client (QoS 0 only) is hand-rolled on asyncio streams —
    stdlib-only image, same reasoning as the protobuf codec.
    """

    def __init__(self, device_id: str, cfg: dict, on_event) -> None:
        super().__init__(device_id, on_event)
        self.host = cfg["host"]
        self.port = int(cfg.get("port", 1883))
        self.topic_root = cfg["topicRoot"].rstrip("/")
        self.channel_name = cfg.get("channelName", "LongFast")
        self.gateway_node_num = cfg.get("gatewayNodeNum")
        self.username = cfg.get("username")
        self.password = cfg.get("password")
        self.tls = bool(cfg.get("tls", False))
        self._reader: asyncio.StreamReader | None = None
        self._writer: asyncio.StreamWriter | None = None
        self._seen_ids: dict = {}  # uplink message id -> monotonic ts (dedupe)

    # -- connection ------------------------------------------------------------

    async def _connect_and_serve(self) -> None:
        ssl_ctx = None
        if self.tls:
            import ssl

            ssl_ctx = ssl.create_default_context()
        self._reader, self._writer = await asyncio.wait_for(
            asyncio.open_connection(self.host, self.port, ssl=ssl_ctx), 15)
        try:
            await self._send_connect()
            await self._expect_connack()
            await self._send_subscribe(f"{self.topic_root}/2/json/{self.channel_name}/#")
            self.connected = True
            self.my_node_num = self.gateway_node_num
            await self._emit_link()
            log.info("%s: mqtt connected %s:%d (%s)", self.device_id, self.host,
                     self.port, self.topic_root)

            sender = asyncio.create_task(self._send_loop())
            pinger = asyncio.create_task(self._ping_loop())
            try:
                await self._read_loop()
            finally:
                sender.cancel()
                pinger.cancel()
                await asyncio.gather(sender, pinger, return_exceptions=True)
        finally:
            if self._writer is not None:
                self._writer.close()
                try:
                    await self._writer.wait_closed()
                except Exception:  # noqa: BLE001
                    pass
            self._reader = self._writer = None

    async def _send_connect(self) -> None:
        flags = 0x02  # clean session
        payload = _mqtt_string(f"meshbridge-{self.device_id}")
        if self.username:
            flags |= 0x80
            payload += _mqtt_string(self.username)
            if self.password is not None:
                flags |= 0x40
                payload += _mqtt_string(self.password)
        var = _mqtt_string("MQTT") + bytes((4, flags)) + struct.pack(">H", _MQTT_KEEPALIVE)
        await self._raw(bytes((_MQTT_CONNECT,)) + _mqtt_remaining_length(len(var) + len(payload)) + var + payload)

    async def _expect_connack(self) -> None:
        ptype, body = await self._read_packet()
        if ptype != _MQTT_CONNACK or len(body) < 2 or body[1] != 0:
            raise ConnectionError(f"MQTT CONNACK refused (type={ptype:#x}, body={body.hex()})")

    async def _send_subscribe(self, topic: str) -> None:
        var = struct.pack(">H", 1) + _mqtt_string(topic) + b"\x00"  # pid=1, qos0
        await self._raw(bytes((_MQTT_SUBSCRIBE,)) + _mqtt_remaining_length(len(var)) + var)
        ptype, body = await self._read_packet()
        if ptype != _MQTT_SUBACK or (len(body) >= 3 and body[2] == 0x80):
            raise ConnectionError("MQTT SUBACK refused")

    async def _ping_loop(self) -> None:
        while True:
            await asyncio.sleep(_MQTT_KEEPALIVE // 2)
            await self._raw(bytes((_MQTT_PINGREQ, 0)))

    async def _raw(self, data: bytes) -> None:
        assert self._writer is not None
        self._writer.write(data)
        await self._writer.drain()

    async def _read_packet(self) -> tuple[int, bytes]:
        assert self._reader is not None
        head = await self._reader.readexactly(1)
        length, mult = 0, 1
        for _ in range(4):
            b = (await self._reader.readexactly(1))[0]
            length += (b & 0x7F) * mult
            if not b & 0x80:
                break
            mult *= 128
        else:
            raise ConnectionError("MQTT remaining-length overflow")
        body = await self._reader.readexactly(length) if length else b""
        return head[0], body

    # -- traffic ----------------------------------------------------------------

    async def _read_loop(self) -> None:
        while True:
            ptype, body = await self._read_packet()
            if ptype & 0xF0 == _MQTT_PUBLISH:
                if len(body) < 2:
                    continue
                tlen = struct.unpack(">H", body[:2])[0]
                payload = body[2 + tlen:]
                if (ptype & 0x06) >> 1:  # qos>0 carries a packet id we ignore
                    payload = payload[2:]
                await self._handle_uplink(payload)
            elif ptype == _MQTT_PINGRESP:
                continue

    async def _handle_uplink(self, raw: bytes) -> None:
        try:
            msg = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return
        if not isinstance(msg, dict):
            return
        mtype = msg.get("type")
        src = msg.get("from")
        if not isinstance(src, int):
            return
        # dedupe by uplink message id (a gateway may re-publish on reconnect)
        mid = msg.get("id")
        if isinstance(mid, int):
            now = time.monotonic()
            self._seen_ids = {k: v for k, v in self._seen_ids.items() if now - v < 600}
            if mid in self._seen_ids:
                return
            self._seen_ids[mid] = now
        payload = msg.get("payload")
        channel = msg.get("channel") if isinstance(msg.get("channel"), int) else 0

        if mtype == "text" and isinstance(payload, dict):
            text = payload.get("text")
            if not isinstance(text, str) or not text:
                return
            if src == self.gateway_node_num and self._echo.is_echo(channel, text):
                return  # the gateway uplinked our own downlink
            await self.on_event({
                "kind": "text", "device": self.device_id, "channel": channel,
                "from": src, "id": mid or 0, "text": text,
                "rssi": msg.get("rssi") if isinstance(msg.get("rssi"), int) else None,
                "snr": msg.get("snr") if isinstance(msg.get("snr"), (int, float)) else None,
                "hops": None,
            })
        elif mtype == "nodeinfo" and isinstance(payload, dict):
            node_id = payload.get("id")
            if not isinstance(node_id, str):
                node_id = codec.node_id_from_num(src)
            await self.on_event({
                "kind": "nodeinfo", "device": self.device_id, "num": src,
                "node_id": node_id.lower(),
                "long_name": str(payload.get("longname", "") or ""),
                "short_name": str(payload.get("shortname", "") or ""),
            })
        elif mtype == "telemetry" and isinstance(payload, dict):
            battery = payload.get("battery_level")
            voltage = payload.get("voltage")
            await self.on_event({
                "kind": "telemetry", "device": self.device_id, "from": src,
                "battery": battery if isinstance(battery, int) else None,
                "voltage": float(voltage) if isinstance(voltage, (int, float)) else None,
            })

    async def _send_loop(self) -> None:
        topic = f"{self.topic_root}/2/json/mqtt/"
        while True:
            channel, payload = await self._out.get()
            text = payload.decode("utf-8", errors="replace")
            if self.gateway_node_num is None:
                log.warning("%s: no gatewayNodeNum configured — dropping downlink",
                            self.device_id)
                continue
            body = json.dumps({
                "from": int(self.gateway_node_num),
                "type": "sendtext",
                "payload": text,
                "channel": int(channel),
            }).encode("utf-8")
            self._echo.remember(channel, text)
            var = _mqtt_string(topic)
            await self._raw(bytes((_MQTT_PUBLISH,)) + _mqtt_remaining_length(len(var) + len(body)) + var + body)
            await asyncio.sleep(SEND_PACE_SECONDS)


# ── factory ───────────────────────────────────────────────────────────────────

def build_link(cfg: dict, on_event) -> BaseLink:
    """Construct the right link for one devices.json entry. Raises ValueError
    on a malformed entry (main.py logs and skips it — one bad device must not
    take the bridge down)."""
    device_id = cfg.get("id")
    transport = cfg.get("transport")
    if not device_id or not isinstance(device_id, str):
        raise ValueError("device entry missing id")
    if transport == "tcp":
        if not cfg.get("host"):
            raise ValueError(f"{device_id}: tcp transport requires host")
        return TcpRadioLink(device_id, cfg["host"], cfg.get("port", 4403), on_event)
    if transport == "serial":
        if not cfg.get("path"):
            raise ValueError(f"{device_id}: serial transport requires path")
        return SerialRadioLink(device_id, cfg["path"], on_event)
    if transport == "mqtt":
        if not cfg.get("host") or not cfg.get("topicRoot"):
            raise ValueError(f"{device_id}: mqtt transport requires host + topicRoot")
        if cfg.get("passwordFile"):
            try:
                cfg = dict(cfg)
                cfg["password"] = open(cfg["passwordFile"]).read().strip()
            except OSError as e:
                raise ValueError(f"{device_id}: cannot read passwordFile: {e}") from e
        return MqttMeshLink(device_id, cfg, on_event)
    raise ValueError(f"{device_id}: unknown transport {transport!r}")

"""Minimal Meshtastic wire codec — stream framing + the protobuf subset the
bridge speaks. Pure stdlib (the bridge runs on python:3.12-alpine with no
site-packages), so the protobuf wire format is implemented by hand for exactly
the messages/fields we need.

PROVENANCE OF THE WIRE FACTS: field numbers, types and enum values below are
protocol facts of the published Meshtastic client API
(https://meshtastic.org/docs/development/reference/protobufs/). They are
locked by cross-decode test vectors generated from the official protobuf
definitions with protoc — see tests/meshbridge/vectors/wire_vectors.json and
tests/meshbridge/gen_vectors.py. Do NOT edit a field number without
regenerating the vectors; test_codec.py will catch drift.

Protobuf is forward-tolerant: unknown fields are skipped by wire type, so
decoding full-fat radio traffic (config dumps, telemetry, positions...) with
this subset is safe — unmodeled payload variants simply come back as an empty
dict from parse_from_radio(), which callers ignore.

STREAM FRAMING (shared by USB-serial and TCP "LoRa-WiFi" port 4403):
    0x94 0xC3 <len_hi> <len_lo> <protobuf payload>
with len big-endian and capped at 512 (MAX_TO_FROM_RADIO_SIZE). Bytes outside
frames are radio debug logs — discarded by resync, never an error.
"""

from __future__ import annotations

import struct

# ── protocol constants ────────────────────────────────────────────────────────

START1 = 0x94
START2 = 0xC3
MAX_FRAME_PAYLOAD = 512  # MAX_TO_FROM_RADIO_SIZE
HEADER_LEN = 4

# Data.payload byte cap for a single packet (mesh.proto Constants.DATA_PAYLOAD_LEN).
DATA_PAYLOAD_LEN = 233

# MeshPacket.to for broadcast.
BROADCAST_NUM = 0xFFFFFFFF

# PortNum values the bridge cares about (Data.portnum).
PORT_TEXT_MESSAGE_APP = 1
PORT_NODEINFO_APP = 4
PORT_TELEMETRY_APP = 67

# Channel.Role
CHANNEL_ROLE_DISABLED = 0
CHANNEL_ROLE_PRIMARY = 1
CHANNEL_ROLE_SECONDARY = 2


class DecodeError(ValueError):
    """A protobuf payload that cannot be a valid Meshtastic message."""


# ── schemas ───────────────────────────────────────────────────────────────────
# field number -> (name, kind[, nested schema name])
# kinds: uint    varint, unsigned
#        int32   varint, two's-complement signed (protobuf int32)
#        bool    varint, != 0
#        bytes   length-delimited, raw
#        string  length-delimited, utf-8 (undecodable -> replacement chars)
#        fixed32 32-bit little-endian unsigned
#        float   32-bit little-endian IEEE-754
#        msg     length-delimited nested message

_SCHEMAS: dict[str, dict[int, tuple]] = {
    "Data": {
        1: ("portnum", "uint"),
        2: ("payload", "bytes"),
        3: ("want_response", "bool"),
        4: ("dest", "fixed32"),
        5: ("source", "fixed32"),
        6: ("request_id", "fixed32"),
        7: ("reply_id", "fixed32"),
        8: ("emoji", "fixed32"),
    },
    "MeshPacket": {
        1: ("from", "fixed32"),
        2: ("to", "fixed32"),
        3: ("channel", "uint"),
        4: ("decoded", "msg", "Data"),
        5: ("encrypted", "bytes"),
        6: ("id", "fixed32"),
        7: ("rx_time", "fixed32"),
        8: ("rx_snr", "float"),
        9: ("hop_limit", "uint"),
        10: ("want_ack", "bool"),
        12: ("rx_rssi", "int32"),
        14: ("via_mqtt", "bool"),
        15: ("hop_start", "uint"),
    },
    "User": {
        1: ("id", "string"),
        2: ("long_name", "string"),
        3: ("short_name", "string"),
    },
    "NodeInfo": {
        1: ("num", "uint"),
        2: ("user", "msg", "User"),
        4: ("snr", "float"),
        5: ("last_heard", "fixed32"),
        7: ("channel", "uint"),
        8: ("via_mqtt", "bool"),
        9: ("hops_away", "uint"),
    },
    "MyNodeInfo": {
        1: ("my_node_num", "uint"),
    },
    "ChannelSettings": {
        2: ("psk", "bytes"),
        3: ("name", "string"),
        4: ("id", "fixed32"),
        5: ("uplink_enabled", "bool"),
        6: ("downlink_enabled", "bool"),
    },
    "Channel": {
        1: ("index", "int32"),
        2: ("settings", "msg", "ChannelSettings"),
        3: ("role", "uint"),
    },
    "LogRecord": {
        1: ("message", "string"),
        2: ("time", "fixed32"),
        3: ("source", "string"),
        4: ("level", "uint"),
    },
    "QueueStatus": {
        1: ("res", "int32"),
        2: ("free", "uint"),
        3: ("maxlen", "uint"),
        4: ("mesh_packet_id", "uint"),
    },
    "ClientNotification": {
        1: ("reply_id", "uint"),
        2: ("time", "fixed32"),
        3: ("level", "uint"),
        4: ("message", "string"),
    },
    "Heartbeat": {
        1: ("nonce", "uint"),
    },
    # Data.payload for PORT_TELEMETRY_APP (telemetry.proto) — only the device
    # metrics the LoRa-status feature surfaces (battery/uptime).
    "DeviceMetrics": {
        1: ("battery_level", "uint"),  # 0..100, 101 = powered
        2: ("voltage", "float"),
        5: ("uptime_seconds", "uint"),
    },
    "Telemetry": {
        1: ("time", "fixed32"),
        2: ("device_metrics", "msg", "DeviceMetrics"),
    },
    "FromRadio": {
        1: ("id", "uint"),
        2: ("packet", "msg", "MeshPacket"),
        3: ("my_info", "msg", "MyNodeInfo"),
        4: ("node_info", "msg", "NodeInfo"),
        6: ("log_record", "msg", "LogRecord"),
        7: ("config_complete_id", "uint"),
        8: ("rebooted", "bool"),
        10: ("channel", "msg", "Channel"),
        11: ("queue_status", "msg", "QueueStatus"),
        16: ("client_notification", "msg", "ClientNotification"),
    },
    "ToRadio": {
        1: ("packet", "msg", "MeshPacket"),
        3: ("want_config_id", "uint"),
        4: ("disconnect", "bool"),
        7: ("heartbeat", "msg", "Heartbeat"),
    },
}

# name -> (field number, kind[, nested]) per message, for encoding.
_BY_NAME: dict[str, dict[str, tuple]] = {
    msg: {spec[0]: (num, *spec[1:]) for num, spec in fields.items()}
    for msg, fields in _SCHEMAS.items()
}

_WT_VARINT, _WT_I64, _WT_LEN, _WT_I32 = 0, 1, 2, 5


# ── decoding ──────────────────────────────────────────────────────────────────

def _read_varint(buf: bytes, i: int) -> tuple[int, int]:
    """Decode a varint at buf[i:]; return (value, next index)."""
    result = 0
    shift = 0
    while True:
        if i >= len(buf):
            raise DecodeError("truncated varint")
        if shift > 63:
            raise DecodeError("varint too long")
        b = buf[i]
        i += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result & 0xFFFFFFFFFFFFFFFF, i
        shift += 7


def _decode(schema_name: str, buf: bytes, depth: int = 0) -> dict:
    """Decode `buf` against a schema. Unknown fields are skipped by wire type;
    unknown wire types (the deprecated group types) are a DecodeError."""
    if depth > 8:
        raise DecodeError("nesting too deep")
    schema = _SCHEMAS[schema_name]
    out: dict = {}
    i = 0
    while i < len(buf):
        tag, i = _read_varint(buf, i)
        field_num, wire_type = tag >> 3, tag & 0x07
        if field_num == 0:
            raise DecodeError("field number 0")

        if wire_type == _WT_VARINT:
            raw, i = _read_varint(buf, i)
            payload: object = raw
        elif wire_type == _WT_I32:
            if i + 4 > len(buf):
                raise DecodeError("truncated i32")
            payload = buf[i:i + 4]
            i += 4
        elif wire_type == _WT_I64:
            if i + 8 > len(buf):
                raise DecodeError("truncated i64")
            payload = buf[i:i + 8]
            i += 8
        elif wire_type == _WT_LEN:
            ln, i = _read_varint(buf, i)
            if ln > len(buf) - i:
                raise DecodeError("truncated length-delimited field")
            payload = buf[i:i + ln]
            i += ln
        else:
            raise DecodeError(f"unsupported wire type {wire_type}")

        spec = schema.get(field_num)
        if spec is None:
            continue  # forward compat: skip unmodeled fields
        name, kind = spec[0], spec[1]

        if kind == "uint" and wire_type == _WT_VARINT:
            out[name] = payload
        elif kind == "int32" and wire_type == _WT_VARINT:
            v = payload
            out[name] = v - (1 << 64) if v >= (1 << 63) else v
        elif kind == "bool" and wire_type == _WT_VARINT:
            out[name] = payload != 0
        elif kind == "fixed32" and wire_type == _WT_I32:
            out[name] = struct.unpack("<I", payload)[0]
        elif kind == "float" and wire_type == _WT_I32:
            out[name] = struct.unpack("<f", payload)[0]
        elif kind == "bytes" and wire_type == _WT_LEN:
            out[name] = bytes(payload)
        elif kind == "string" and wire_type == _WT_LEN:
            out[name] = payload.decode("utf-8", errors="replace")
        elif kind == "msg" and wire_type == _WT_LEN:
            out[name] = _decode(spec[2], payload, depth + 1)
        # else: wire type doesn't match the schema — a peer speaking a
        # different dialect; skip the field rather than failing the frame.
    return out


def parse_from_radio(buf: bytes) -> dict:
    """Decode a FromRadio frame payload into a plain dict."""
    return _decode("FromRadio", buf)


def parse_to_radio(buf: bytes) -> dict:
    """Decode a ToRadio frame payload (used by tests and the mock radio)."""
    return _decode("ToRadio", buf)


def parse_telemetry(buf: bytes) -> dict:
    """Decode a Data.payload carrying PORT_TELEMETRY_APP. Only device_metrics
    is modeled; environment/power/etc. variants decode to an empty dict."""
    return _decode("Telemetry", buf)


# ── encoding ──────────────────────────────────────────────────────────────────

def _write_varint(v: int) -> bytes:
    if v < 0:
        v &= 0xFFFFFFFFFFFFFFFF  # two's complement (protobuf int32/int64)
    out = bytearray()
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _encode(schema_name: str, values: dict) -> bytes:
    """Encode a dict against a schema. Fields are emitted in field-number
    order; zero/empty/None values are omitted (proto3 default semantics)."""
    by_name = _BY_NAME[schema_name]
    parts: list[tuple[int, bytes]] = []
    for name, value in values.items():
        spec = by_name.get(name)
        if spec is None:
            raise DecodeError(f"{schema_name} has no field {name!r}")
        num, kind = spec[0], spec[1]
        if value is None:
            continue
        if kind in ("uint", "int32"):
            if not value:
                continue
            parts.append((num, _write_varint(num << 3 | _WT_VARINT) + _write_varint(int(value))))
        elif kind == "bool":
            if not value:
                continue
            parts.append((num, _write_varint(num << 3 | _WT_VARINT) + b"\x01"))
        elif kind == "fixed32":
            if not value:
                continue
            parts.append((num, _write_varint(num << 3 | _WT_I32) + struct.pack("<I", value & 0xFFFFFFFF)))
        elif kind == "float":
            if not value:
                continue
            parts.append((num, _write_varint(num << 3 | _WT_I32) + struct.pack("<f", value)))
        elif kind in ("bytes", "string"):
            raw = value.encode("utf-8") if kind == "string" else bytes(value)
            if not raw:
                continue
            parts.append((num, _write_varint(num << 3 | _WT_LEN) + _write_varint(len(raw)) + raw))
        elif kind == "msg":
            raw = _encode(spec[2], value)
            # note: empty nested message IS emitted (e.g. ToRadio.heartbeat{})
            parts.append((num, _write_varint(num << 3 | _WT_LEN) + _write_varint(len(raw)) + raw))
    parts.sort(key=lambda p: p[0])
    return b"".join(p[1] for p in parts)


def encode_to_radio(values: dict) -> bytes:
    """Encode a ToRadio dict (see _SCHEMAS['ToRadio'] for accepted keys)."""
    return _encode("ToRadio", values)


def encode_from_radio(values: dict) -> bytes:
    """Encode a FromRadio dict (used by the mock radio in tests)."""
    return _encode("FromRadio", values)


# ── convenience builders ─────────────────────────────────────────────────────

def build_want_config(nonce: int) -> bytes:
    """ToRadio asking the radio to (re)send its config + node db."""
    return encode_to_radio({"want_config_id": nonce & 0xFFFFFFFF})


def build_heartbeat() -> bytes:
    """ToRadio keep-alive for stream transports."""
    return encode_to_radio({"heartbeat": {}})


def build_text_packet(
    channel: int,
    payload: bytes,
    packet_id: int,
    *,
    to: int = BROADCAST_NUM,
    hop_limit: int = 3,
    want_ack: bool = True,
) -> bytes:
    """ToRadio carrying one outbound text message. `payload` must already be
    UTF-8 and <= DATA_PAYLOAD_LEN bytes (the bridge chunks upstream)."""
    if len(payload) > DATA_PAYLOAD_LEN:
        raise ValueError(f"text payload {len(payload)} > {DATA_PAYLOAD_LEN}")
    return encode_to_radio({
        "packet": {
            "to": to,
            "channel": int(channel),
            "id": packet_id & 0xFFFFFFFF,
            "hop_limit": hop_limit,
            "want_ack": want_ack,
            "decoded": {
                "portnum": PORT_TEXT_MESSAGE_APP,
                "payload": payload,
            },
        }
    })


def node_id_from_num(num: int) -> str:
    """Canonical Meshtastic node id: '!' + 8 lowercase hex digits."""
    return f"!{num & 0xFFFFFFFF:08x}"


def num_from_node_id(node_id: str) -> int | None:
    """Parse '!a1b2c3d4' (or bare hex8) to a node number; None if malformed."""
    s = node_id.strip().lower()
    if s.startswith("!"):
        s = s[1:]
    if len(s) != 8:
        return None
    try:
        return int(s, 16)
    except ValueError:
        return None


# ── stream framing ────────────────────────────────────────────────────────────

def frame(payload: bytes) -> bytes:
    """Wrap a protobuf payload in the 0x94 0xC3 <len_be16> stream header."""
    if len(payload) > MAX_FRAME_PAYLOAD:
        raise ValueError(f"frame payload {len(payload)} > {MAX_FRAME_PAYLOAD}")
    return bytes((START1, START2, len(payload) >> 8, len(payload) & 0xFF)) + payload


class StreamParser:
    """Incremental deframer. feed() returns every complete protobuf payload
    found; garbage between frames (radio debug output on serial links) is
    discarded by resync, and an oversized length resyncs rather than erroring
    (matches the reference client's recovery behaviour)."""

    def __init__(self) -> None:
        self._buf = bytearray()
        self._garbage = 0  # bytes discarded since the last good frame

    @property
    def garbage_bytes(self) -> int:
        return self._garbage

    def feed(self, data: bytes) -> list[bytes]:
        self._buf.extend(data)
        frames: list[bytes] = []
        while True:
            # hunt for the frame header
            start = self._buf.find(bytes((START1, START2)))
            if start < 0:
                # keep a trailing lone 0x94 (could be a split header)
                keep = 1 if self._buf[-1:] == bytes((START1,)) else 0
                self._garbage += len(self._buf) - keep
                del self._buf[: len(self._buf) - keep]
                return frames
            if start:
                self._garbage += start
                del self._buf[:start]
            if len(self._buf) < HEADER_LEN:
                return frames
            length = (self._buf[2] << 8) | self._buf[3]
            if length > MAX_FRAME_PAYLOAD:
                # corrupt header: drop the two magic bytes and resync
                self._garbage += 2
                del self._buf[:2]
                continue
            if len(self._buf) < HEADER_LEN + length:
                return frames
            frames.append(bytes(self._buf[HEADER_LEN: HEADER_LEN + length]))
            del self._buf[: HEADER_LEN + length]

#!/usr/bin/env python3
"""Regenerate tests/meshbridge/vectors/wire_vectors.json — the cross-decode
vectors that lock the bridge's hand-written Meshtastic codec to the OFFICIAL
protobuf definitions.

This script is NOT run in CI (it needs the `protobuf` package + protoc output
of the real meshtastic .proto files); test_codec.py consumes the committed
JSON with the stdlib only. Regenerate when the codec's schema grows:

    python -m venv /tmp/mtvec && /tmp/mtvec/bin/pip install protobuf
    # fetch https://github.com/meshtastic/protobufs (meshtastic/*.proto), then:
    protoc --proto_path=<protodir> --python_out=<gendir> meshtastic/*.proto
    MESHTASTIC_GEN=<gendir> /tmp/mtvec/bin/python tests/meshbridge/gen_vectors.py

Every DECODE vector is: official-bindings-encoded bytes + the dict the bridge
codec must produce. Every ENCODE vector is: a bridge-codec input dict + the
bytes it produced AT GENERATION TIME, which were then decoded with the
official bindings and semantically verified — so the committed bytes are known
radio-compatible, and the test pins them against regression.

JSON cannot carry bytes: byte values appear as {"__bytes__": "<hex>"}.
"""

import json
import os
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
APP = HERE.parent.parent / "specs/cluster/manifests/meshbridge/app"
sys.path.insert(0, str(APP))
sys.path.insert(0, os.environ.get("MESHTASTIC_GEN", "."))

import meshtastic_codec as codec  # noqa: E402
from meshtastic import mesh_pb2, portnums_pb2, telemetry_pb2, channel_pb2  # noqa: E402


def jbytes(b: bytes) -> dict:
    return {"__bytes__": b.hex()}


def jsonable(v):
    if isinstance(v, bytes):
        return jbytes(v)
    if isinstance(v, dict):
        return {k: jsonable(x) for k, x in v.items()}
    return v


DECODE = []  # cases the bridge codec must decode to `expect`
ENCODE = []  # bridge-codec inputs pinned to their (official-verified) bytes


def decode_case(name: str, wire: bytes, expect: dict, parser: str = "FromRadio"):
    DECODE.append({"name": name, "parser": parser, "hex": wire.hex(),
                   "expect": jsonable(expect)})


# ── decode: text packet with full metadata ───────────────────────────────────
fr = mesh_pb2.FromRadio()
setattr(fr.packet, "from", 0xDEADBEEF)
fr.packet.to = 0xFFFFFFFF
fr.packet.channel = 2
fr.packet.id = 424242
fr.packet.rx_time = 1752600000
fr.packet.rx_snr = 7.25
fr.packet.hop_limit = 3
fr.packet.rx_rssi = -85
fr.packet.hop_start = 5
fr.packet.decoded.portnum = portnums_pb2.PortNum.TEXT_MESSAGE_APP
fr.packet.decoded.payload = "hello from the mesh ⚡".encode()
decode_case("text_packet_full_meta", fr.SerializeToString(), {
    "packet": {
        "from": 0xDEADBEEF, "to": 0xFFFFFFFF, "channel": 2, "id": 424242,
        "rx_time": 1752600000, "rx_snr": 7.25, "hop_limit": 3, "rx_rssi": -85,
        "hop_start": 5,
        "decoded": {"portnum": 1, "payload": "hello from the mesh ⚡".encode()},
    },
})

# ── decode: nodeinfo ─────────────────────────────────────────────────────────
fr = mesh_pb2.FromRadio()
fr.node_info.num = 305419896
fr.node_info.user.id = "!12345678"
fr.node_info.user.long_name = "Trail Node 7"
fr.node_info.user.short_name = "TN7"
fr.node_info.snr = -13.5
fr.node_info.hops_away = 2
fr.node_info.last_heard = 1752600123
decode_case("node_info", fr.SerializeToString(), {
    "node_info": {
        "num": 305419896, "snr": -13.5, "hops_away": 2, "last_heard": 1752600123,
        "user": {"id": "!12345678", "long_name": "Trail Node 7", "short_name": "TN7"},
    },
})

# ── decode: my_info / config_complete / rebooted ─────────────────────────────
fr = mesh_pb2.FromRadio(); fr.my_info.my_node_num = 0x0A0B0C0D
decode_case("my_info", fr.SerializeToString(), {"my_info": {"my_node_num": 0x0A0B0C0D}})
fr = mesh_pb2.FromRadio(); fr.config_complete_id = 0xCAFE
decode_case("config_complete", fr.SerializeToString(), {"config_complete_id": 0xCAFE})
fr = mesh_pb2.FromRadio(); fr.rebooted = True
decode_case("rebooted", fr.SerializeToString(), {"rebooted": True})

# ── decode: channel dump ─────────────────────────────────────────────────────
fr = mesh_pb2.FromRadio()
fr.channel.index = 1
fr.channel.role = channel_pb2.Channel.Role.SECONDARY
fr.channel.settings.name = "snapmesh"
fr.channel.settings.psk = b"\x01"
fr.channel.settings.downlink_enabled = True
decode_case("channel_secondary", fr.SerializeToString(), {
    "channel": {"index": 1, "role": 2,
                "settings": {"name": "snapmesh", "psk": b"\x01", "downlink_enabled": True}},
})

# ── decode: queue status with negative res (signed int32) ────────────────────
fr = mesh_pb2.FromRadio()
fr.queueStatus.res = -22
fr.queueStatus.free = 7
fr.queueStatus.maxlen = 16
fr.queueStatus.mesh_packet_id = 99
decode_case("queue_status_negative_res", fr.SerializeToString(), {
    "queue_status": {"res": -22, "free": 7, "maxlen": 16, "mesh_packet_id": 99},
})

# ── decode: unmodeled payload variant (config dump) → empty dict ─────────────
fr = mesh_pb2.FromRadio()
fr.config.device.role = 1
decode_case("unmodeled_config_variant", fr.SerializeToString(), {})

# ── decode: telemetry (battery) carried as Data.payload ──────────────────────
tel = telemetry_pb2.Telemetry()
tel.time = 1752600456
tel.device_metrics.battery_level = 87
tel.device_metrics.voltage = 3.875
tel.device_metrics.uptime_seconds = 3600
decode_case("telemetry_device_metrics", tel.SerializeToString(), {
    "time": 1752600456,
    "device_metrics": {"battery_level": 87, "voltage": 3.875, "uptime_seconds": 3600},
}, parser="Telemetry")

tel = telemetry_pb2.Telemetry()
tel.time = 1752600789
tel.environment_metrics.temperature = 21.5
decode_case("telemetry_unmodeled_variant", tel.SerializeToString(),
            {"time": 1752600789}, parser="Telemetry")

# ── decode: encrypted packet (no decoded) ────────────────────────────────────
fr = mesh_pb2.FromRadio()
setattr(fr.packet, "from", 0x01020304)
fr.packet.to = 0xFFFFFFFF
fr.packet.encrypted = b"\xde\xad\xbe\xef\x00\x01"
fr.packet.id = 7
decode_case("encrypted_packet", fr.SerializeToString(), {
    "packet": {"from": 0x01020304, "to": 0xFFFFFFFF, "id": 7,
               "encrypted": b"\xde\xad\xbe\xef\x00\x01"},
})


# ── encode direction: bridge-built ToRadio, official-verified ────────────────
def encode_case(name: str, wire: bytes, verify):
    """Decode `wire` (produced by the bridge codec) with the OFFICIAL bindings,
    run `verify(msg)` assertions, then pin the bytes."""
    msg = mesh_pb2.ToRadio()
    msg.ParseFromString(wire)
    verify(msg)
    ENCODE.append({"name": name, "hex": wire.hex()})


w = codec.build_text_packet(1, "[alice] hi mesh".encode(), 0x0000C0DE)
def _v_text(m):
    assert m.packet.decoded.portnum == portnums_pb2.PortNum.TEXT_MESSAGE_APP
    assert m.packet.decoded.payload == b"[alice] hi mesh"
    assert m.packet.to == 0xFFFFFFFF and m.packet.channel == 1
    assert m.packet.id == 0x0000C0DE and m.packet.hop_limit == 3 and m.packet.want_ack
encode_case("text_broadcast_ch1", w, _v_text)

w = codec.build_text_packet(0, "0-ch default".encode(), 1, want_ack=False, hop_limit=7)
def _v_text0(m):
    assert m.packet.channel == 0 and m.packet.hop_limit == 7 and not m.packet.want_ack
encode_case("text_ch0_no_ack", w, _v_text0)

w = codec.build_want_config(0xBEEF)
def _v_wc(m):
    assert m.want_config_id == 0xBEEF
encode_case("want_config", w, _v_wc)

w = codec.build_heartbeat()
def _v_hb(m):
    assert m.WhichOneof("payload_variant") == "heartbeat"
encode_case("heartbeat", w, _v_hb)


# ── sanity: run the bridge codec against every decode case before writing ────
def revive(v):
    if isinstance(v, dict):
        if set(v) == {"__bytes__"}:
            return bytes.fromhex(v["__bytes__"])
        return {k: revive(x) for k, x in v.items()}
    return v


PARSERS = {"FromRadio": codec.parse_from_radio, "Telemetry": codec.parse_telemetry}
for case in DECODE:
    got = PARSERS[case["parser"]](bytes.fromhex(case["hex"]))
    want = revive(case["expect"])
    assert got == want, f"{case['name']}: {got!r} != {want!r}"

out = HERE / "vectors" / "wire_vectors.json"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps({"decode": DECODE, "encode": ENCODE}, indent=2,
                          ensure_ascii=False) + "\n")
print(f"wrote {out} ({len(DECODE)} decode, {len(ENCODE)} encode cases)")

"""meshbridge entrypoint — config, wiring, lifecycle.

Env contract (kept in lockstep with manifests/meshbridge/deployment.yaml):
  MATRIX_URL                        in-namespace tuwunel CS endpoint
  MATRIX_SERVER_NAME                homeserver server_name
  MESHBRIDGE_LISTEN_PORT            AS transaction listener + /healthz
  MESHBRIDGE_SENDER_LOCALPART       bridge bot localpart
  MESHBRIDGE_AS_TOKEN_FILE / MESHBRIDGE_HS_TOKEN_FILE
  MESHBRIDGE_DEVICES_FILE           devices.json (see devices-configmap.yaml)
  MESHBRIDGE_USERBFF_MESH_DEVICES_URL   registration mapping + status ingest
  MESHBRIDGE_USERBFF_CLIENT_CERT_FILE / _KEY_FILE / _CA_FILE   mTLS client pair
  MESHBRIDGE_OIDC_TOKEN_URL / MESHBRIDGE_OIDC_CLIENT_ID_FILE /
  MESHBRIDGE_OIDC_CLIENT_SECRET_FILE    Casdoor client-credentials (ROLE_SERVICE)
  MESHBRIDGE_MESHBFF_SYNC_URL       OPTIONAL mesh-bff bridge-sync ingest; unset
                                    = skipped (mesh-bff is its own optional svc)
  MESHBRIDGE_REG_POLL_SECONDS / MESHBRIDGE_SYNC_PUSH_SECONDS / LOG_LEVEL

Every integration is fail-soft: a missing secret file or unreachable upstream
degrades that one function (logged loudly) — text bridging keeps running on
whatever legs remain. The pod only exits on SIGTERM.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import signal

import transports
from as_server import AsServer
from bridge import Bridge
from matrix_cs import CasdoorTokenSource, ClientError, MatrixClient, UserBffClient

log = logging.getLogger("meshbridge")


def _env(name: str, default: str) -> str:
    return os.environ.get(name, default)


def _read_secret(path: str, what: str) -> str | None:
    try:
        value = open(path).read().strip()
        return value or None
    except OSError as e:
        log.warning("%s not readable (%s): %s", what, path, e)
        return None


def _load_devices(path: str) -> list[dict]:
    try:
        raw = json.loads(open(path).read())
    except (OSError, json.JSONDecodeError) as e:
        log.warning("devices file %s unusable (%s) — starting with none", path, e)
        return []
    devices = raw.get("devices") if isinstance(raw, dict) else None
    return [d for d in devices if isinstance(d, dict)] if isinstance(devices, list) else []


def _build_userbff() -> UserBffClient | None:
    url = _env("MESHBRIDGE_USERBFF_MESH_DEVICES_URL", "")
    token_url = _env("MESHBRIDGE_OIDC_TOKEN_URL", "")
    client_id = _read_secret(
        _env("MESHBRIDGE_OIDC_CLIENT_ID_FILE", "/run/secrets/meshbridge/oidc_client_id"),
        "oidc client id")
    client_secret = _read_secret(
        _env("MESHBRIDGE_OIDC_CLIENT_SECRET_FILE", "/run/secrets/meshbridge/oidc_client_secret"),
        "oidc client secret")
    if not (url and token_url and client_id and client_secret):
        log.warning("user-bff leg not configured — mesh users will all appear "
                    "anonymous (no registrations, no status sync)")
        return None
    return UserBffClient(
        url,
        CasdoorTokenSource(token_url, client_id, client_secret),
        client_cert=os.environ.get("MESHBRIDGE_USERBFF_CLIENT_CERT_FILE"),
        client_key=os.environ.get("MESHBRIDGE_USERBFF_CLIENT_KEY_FILE"),
        ca_file=os.environ.get("MESHBRIDGE_USERBFF_CA_FILE"),
    )


class MeshBffSync(UserBffClient):
    """OPTIONAL second sync leg: pushes the full node-directory + mesh-room
    snapshot to mesh-bff's /bff/mesh/internal/bridge-sync (same SERVICE token
    + mTLS posture as the user-bff leg). The bridge stays fully functional
    without it — mesh-bff is a separate optional service."""

    async def push_snapshot(self, nodes: list[dict], rooms: list[dict]) -> None:
        await self._call("POST", self.base, {"nodes": nodes, "rooms": rooms})


async def _run() -> None:
    matrix_url = _env("MATRIX_URL", "http://tuwunel.snapdragon-backend.svc.cluster.local:8008")
    server_name = _env("MATRIX_SERVER_NAME", "snapdragon.systems")
    sender_localpart = _env("MESHBRIDGE_SENDER_LOCALPART", "meshbridge")
    listen_port = int(_env("MESHBRIDGE_LISTEN_PORT", "8009"))

    as_token = _read_secret(
        _env("MESHBRIDGE_AS_TOKEN_FILE", "/run/secrets/meshbridge/as_token"), "as_token")
    hs_token = _read_secret(
        _env("MESHBRIDGE_HS_TOKEN_FILE", "/run/secrets/meshbridge/hs_token"), "hs_token")
    if not as_token or not hs_token:
        # Without the AS pair there is no bridge at all; crash-loop visibly
        # rather than pretend (the Secret is ESO-managed — see the manifests).
        raise SystemExit("meshbridge: as_token/hs_token missing — cannot start")

    matrix = MatrixClient(matrix_url, as_token, server_name, sender_localpart)
    userbff = _build_userbff()
    bridge = Bridge(matrix, links={}, userbff=userbff,
                    reg_poll_seconds=int(_env("MESHBRIDGE_REG_POLL_SECONDS", "60")))

    loop = asyncio.get_running_loop()
    bridge.attach_loop(loop)

    async def on_event(evt: dict) -> None:
        await bridge.on_device_event(evt)

    devices = _load_devices(
        _env("MESHBRIDGE_DEVICES_FILE", "/etc/meshbridge/devices.json"))
    for cfg in devices:
        try:
            link = transports.build_link(cfg, on_event)
        except ValueError as e:
            log.error("device skipped: %s", e)
            continue
        bridge.links[link.device_id] = link
    log.info("configured %d device link(s): %s", len(bridge.links),
             ", ".join(bridge.links) or "none")

    server = AsServer(listen_port, hs_token, r"^@mesh-.*",
                      bridge.submit_transaction, bridge.health_snapshot)
    server.start()

    await bridge.bootstrap()

    tasks = [asyncio.create_task(link.run(), name=f"link:{device_id}")
             for device_id, link in bridge.links.items()]
    tasks.append(asyncio.create_task(bridge.run_registration_poller(), name="reg-poll"))
    tasks.append(asyncio.create_task(bridge.run_status_pusher(), name="status-push"))

    meshbff_url = _env("MESHBRIDGE_MESHBFF_SYNC_URL", "")
    if meshbff_url and userbff is not None:
        sync = MeshBffSync(meshbff_url, userbff.tokens,
                           client_cert=os.environ.get("MESHBRIDGE_USERBFF_CLIENT_CERT_FILE"),
                           client_key=os.environ.get("MESHBRIDGE_USERBFF_CLIENT_KEY_FILE"),
                           ca_file=os.environ.get("MESHBRIDGE_USERBFF_CA_FILE"))

        async def sync_loop() -> None:
            interval = int(_env("MESHBRIDGE_SYNC_PUSH_SECONDS", "60"))
            while True:
                await asyncio.sleep(interval)
                nodes = [{
                    "nodeId": node_id,
                    "longName": info.get("long_name"),
                    "shortName": info.get("short_name"),
                    "lastSeenAt": info.get("last_heard_iso"),
                    "batteryPct": info.get("battery"),
                    "snr": info.get("snr"),
                    "hopsAway": info.get("hops"),
                    "viaDevice": info.get("via_device"),
                } for node_id, info in bridge.node_db.items()]
                rooms = [{"roomId": room_id, "device": m["device"],
                          "meshChannel": m["meshChannel"]}
                         for room_id, m in bridge.mappings.items()]
                try:
                    await sync.push_snapshot(nodes, rooms)
                except ClientError as e:
                    log.warning("mesh-bff sync failed (retry next tick): %s", e)

        tasks.append(asyncio.create_task(sync_loop(), name="meshbff-sync"))

    stop = asyncio.Event()

    def _terminate() -> None:
        log.info("SIGTERM — shutting down")
        stop.set()

    loop.add_signal_handler(signal.SIGTERM, _terminate)
    loop.add_signal_handler(signal.SIGINT, _terminate)

    await stop.wait()
    for link in bridge.links.values():
        link.stop()
    server.stop()
    for task in tasks:
        task.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)


def main() -> None:
    logging.basicConfig(
        level=getattr(logging, _env("LOG_LEVEL", "INFO").upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    asyncio.run(_run())


if __name__ == "__main__":
    main()

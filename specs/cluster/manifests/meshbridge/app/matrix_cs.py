"""Outbound HTTP clients: the Matrix client-server API (as the appservice,
masquerading as @mesh-* virtual users), the Casdoor client-credentials token
source, and the user-bff internal mesh-devices client (mTLS + SERVICE JWT).

stdlib only: urllib does the I/O, hopped onto the event loop via
asyncio.to_thread (the bridge's request rate is tiny — worst case a handful of
in-flight calls; a thread per call is fine and keeps the loop pure).

Retry discipline: 429 respects retry_after_ms (bounded), transient transport
errors retry twice with a short pause, everything else surfaces immediately as
MatrixError/ClientError — callers are all fail-soft loops that keep last-good
state, so errors must be LOUD in logs but never fatal to the process.
"""

from __future__ import annotations

import asyncio
import json
import logging
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

log = logging.getLogger("meshbridge.matrix")

_TIMEOUT = 20
_MAX_429_RETRIES = 3
_MAX_TRANSPORT_RETRIES = 2


class MatrixError(Exception):
    def __init__(self, status: int, errcode: str, message: str) -> None:
        super().__init__(f"{status} {errcode}: {message}")
        self.status = status
        self.errcode = errcode


class ClientError(Exception):
    """Non-Matrix upstream failure (user-bff / Casdoor legs)."""


def _request(method: str, url: str, headers: dict, body: bytes | None,
             ssl_context: ssl.SSLContext | None = None) -> tuple[int, dict]:
    """Blocking HTTP round-trip -> (status, parsed-json-or-{}). Runs in a
    worker thread via asyncio.to_thread."""
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=_TIMEOUT, context=ssl_context) as r:
            raw = r.read()
            return r.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            payload = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            payload = {"error": raw[:200].decode("utf-8", "replace")}
        return e.code, payload


class MatrixClient:
    """Thin CS-API wrapper authenticated with the appservice as_token.
    `user_id=` masquerade makes calls act as a namespaced virtual user; without
    it, calls act as the bridge bot (@<sender_localpart>:<server>)."""

    def __init__(self, base_url: str, as_token: str, server_name: str,
                 sender_localpart: str) -> None:
        self.base = base_url.rstrip("/")
        self.server_name = server_name
        self.bot_mxid = f"@{sender_localpart}:{server_name}"
        self._headers = {"Authorization": f"Bearer {as_token}",
                         "Content-Type": "application/json"}
        self._txn = int(time.time() * 1000) & 0x7FFFFFFF

    def mesh_mxid(self, localpart: str) -> str:
        return f"@{localpart}:{self.server_name}"

    async def _call(self, method: str, path: str, *, body: dict | None = None,
                    user_id: str | None = None, ok_errcodes: tuple = ()) -> dict:
        query = f"?user_id={urllib.parse.quote(user_id)}" if user_id else ""
        url = f"{self.base}{path}{query}"
        raw = json.dumps(body).encode() if body is not None else None
        transport_left, limit_left = _MAX_TRANSPORT_RETRIES, _MAX_429_RETRIES
        while True:
            try:
                status, payload = await asyncio.to_thread(
                    _request, method, url, self._headers, raw)
            except (urllib.error.URLError, TimeoutError, OSError) as e:
                if transport_left <= 0:
                    raise MatrixError(0, "M_UNREACHABLE", str(e)) from e
                transport_left -= 1
                await asyncio.sleep(1)
                continue
            if status == 429 and limit_left > 0:
                limit_left -= 1
                wait = min(payload.get("retry_after_ms", 2000) / 1000.0, 30.0)
                await asyncio.sleep(wait)
                continue
            if 200 <= status < 300:
                return payload
            errcode = payload.get("errcode", "M_UNKNOWN")
            if errcode in ok_errcodes:
                return payload
            raise MatrixError(status, errcode, payload.get("error", ""))

    # -- virtual users -----------------------------------------------------------

    async def ensure_registered(self, localpart: str) -> None:
        """AS-register a namespaced user; already-exists is success."""
        await self._call("POST", "/_matrix/client/v3/register",
                         body={"type": "m.login.application_service",
                               "username": localpart},
                         ok_errcodes=("M_USER_IN_USE",))

    async def set_displayname(self, user_id: str, displayname: str) -> None:
        quoted = urllib.parse.quote(user_id)
        await self._call("PUT", f"/_matrix/client/v3/profile/{quoted}/displayname",
                         body={"displayname": displayname}, user_id=user_id)

    # -- membership ---------------------------------------------------------------

    async def invite(self, room_id: str, target_mxid: str) -> None:
        """Invite as the bridge bot; already-in-room shapes are success."""
        quoted = urllib.parse.quote(room_id)
        try:
            await self._call("POST", f"/_matrix/client/v3/rooms/{quoted}/invite",
                             body={"user_id": target_mxid})
        except MatrixError as e:
            # Conduit-family returns 403 M_FORBIDDEN for already-joined/invited;
            # treat as success (the goal state is reached).
            if e.status != 403:
                raise

    async def join(self, room_id: str, user_id: str | None = None) -> None:
        quoted = urllib.parse.quote(room_id)
        await self._call("POST", f"/_matrix/client/v3/rooms/{quoted}/join",
                         body={}, user_id=user_id)

    async def leave(self, room_id: str, user_id: str | None = None) -> None:
        quoted = urllib.parse.quote(room_id)
        await self._call("POST", f"/_matrix/client/v3/rooms/{quoted}/leave",
                         body={}, user_id=user_id, ok_errcodes=("M_FORBIDDEN",))

    async def joined_rooms(self) -> list[str]:
        payload = await self._call("GET", "/_matrix/client/v3/joined_rooms")
        rooms = payload.get("joined_rooms", [])
        return [r for r in rooms if isinstance(r, str)]

    # -- rooms ---------------------------------------------------------------------

    async def room_state(self, room_id: str) -> list[dict]:
        quoted = urllib.parse.quote(room_id)
        payload = await self._call("GET", f"/_matrix/client/v3/rooms/{quoted}/state")
        return payload if isinstance(payload, list) else []

    async def send_message(self, room_id: str, user_id: str, content: dict) -> str:
        self._txn += 1
        quoted = urllib.parse.quote(room_id)
        payload = await self._call(
            "PUT",
            f"/_matrix/client/v3/rooms/{quoted}/send/m.room.message/mb{self._txn}",
            body=content, user_id=user_id)
        return payload.get("event_id", "")

    async def send_state(self, room_id: str, event_type: str, state_key: str,
                         content: dict) -> None:
        quoted = urllib.parse.quote(room_id)
        qtype = urllib.parse.quote(event_type)
        qkey = urllib.parse.quote(state_key)
        await self._call("PUT",
                         f"/_matrix/client/v3/rooms/{quoted}/state/{qtype}/{qkey}",
                         body=content)


class CasdoorTokenSource:
    """Client-credentials token for user-bff's ROLE_SERVICE internal surface.
    Tokens are cached until 60s before expiry; a fetch failure raises
    ClientError (the caller keeps polling with last-good data)."""

    def __init__(self, token_url: str, client_id: str, client_secret: str) -> None:
        self.token_url = token_url
        self.client_id = client_id
        self.client_secret = client_secret
        self._token: str | None = None
        self._expires_at = 0.0

    def invalidate(self) -> None:
        self._token = None

    async def token(self) -> str:
        if self._token and time.monotonic() < self._expires_at:
            return self._token
        form = urllib.parse.urlencode({
            "grant_type": "client_credentials",
            "client_id": self.client_id,
            "client_secret": self.client_secret,
        }).encode()
        try:
            status, payload = await asyncio.to_thread(
                _request, "POST", self.token_url,
                {"Content-Type": "application/x-www-form-urlencoded"}, form)
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            raise ClientError(f"casdoor token fetch failed: {e}") from e
        token = payload.get("access_token")
        if status != 200 or not token:
            raise ClientError(f"casdoor token refused: {status}")
        self._token = token
        self._expires_at = time.monotonic() + max(int(payload.get("expires_in", 300)) - 60, 30)
        return token


class UserBffClient:
    """The bridge's leg to user-bff's SERVICE-gated internal surface:
      GET  <base>            -> registered-device mapping rows
      POST <base>/status     -> batch LoRa status updates
    user-bff terminates mTLS (client-auth=need), so requests present the
    bridge's Vault-PKI client cert alongside the SERVICE bearer."""

    def __init__(self, base_url: str, tokens: CasdoorTokenSource,
                 client_cert: str | None = None, client_key: str | None = None,
                 ca_file: str | None = None) -> None:
        self.base = base_url.rstrip("/")
        self.tokens = tokens
        self._ssl: ssl.SSLContext | None = None
        if base_url.startswith("https"):
            self._ssl = ssl.create_default_context(cafile=ca_file)
            if client_cert and client_key:
                self._ssl.load_cert_chain(client_cert, client_key)

    async def _call(self, method: str, url: str, body: dict | list | None = None):
        bearer = await self.tokens.token()
        raw = json.dumps(body).encode() if body is not None else None
        headers = {"Authorization": f"Bearer {bearer}",
                   "Content-Type": "application/json"}
        try:
            status, payload = await asyncio.to_thread(
                _request, method, url, headers, raw, self._ssl)
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            raise ClientError(f"user-bff unreachable: {e}") from e
        if status == 401:
            # token likely expired server-side early — refresh once
            self.tokens.invalidate()
            bearer = await self.tokens.token()
            headers["Authorization"] = f"Bearer {bearer}"
            try:
                status, payload = await asyncio.to_thread(
                    _request, method, url, headers, raw, self._ssl)
            except (urllib.error.URLError, TimeoutError, OSError) as e:
                raise ClientError(f"user-bff unreachable: {e}") from e
        if not 200 <= status < 300:
            raise ClientError(f"user-bff {method} {url.rsplit('/', 1)[-1]}: HTTP {status}")
        return payload

    async def fetch_mappings(self) -> list[dict]:
        """Rows: {nodeId, localpart, displayName, visibility} — active only."""
        payload = await self._call("GET", self.base)
        rows = payload if isinstance(payload, list) else payload.get("devices", [])
        out = []
        for row in rows if isinstance(rows, list) else []:
            if not isinstance(row, dict):
                continue
            node_id = row.get("nodeId")
            localpart = row.get("localpart")
            if isinstance(node_id, str) and isinstance(localpart, str) and localpart:
                out.append({
                    "nodeId": node_id.lower(),
                    "localpart": localpart,
                    "displayName": row.get("displayName") or localpart,
                    "visibility": row.get("visibility", "private"),
                })
        return out

    async def push_status(self, batch: list[dict]) -> None:
        if batch:
            await self._call("POST", f"{self.base}/status", batch)

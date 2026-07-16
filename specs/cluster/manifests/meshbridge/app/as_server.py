"""The appservice HTTP listener — what tuwunel pushes room traffic INTO, plus
the pod's /healthz. stdlib http.server on a daemon thread; handlers submit
work onto the asyncio loop and answer immediately (the AS API is retry-safe:
the homeserver redelivers a transaction until it gets a 200, and the bridge
core deduplicates by transaction id).

Auth: every /_matrix/app/** request must carry the hs_token (Authorization
Bearer per the current spec, ?access_token= accepted for older homeservers).
Wrong/missing token -> 403 M_FORBIDDEN, constant-time compare.

Endpoints:
  PUT  /_matrix/app/v1/transactions/{txnId}   (+ legacy /transactions/{txnId})
  GET  /_matrix/app/v1/users/{userId}         200 {} for @mesh-* (lazy-create
                                              is the bridge's job), else 404
  GET  /_matrix/app/v1/rooms/{alias}          404 (no room namespace)
  POST /_matrix/app/v1/ping                   200 {} (MSC2659 liveness)
  GET  /healthz                               unauthenticated pod health JSON
"""

from __future__ import annotations

import hmac
import json
import logging
import re
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log = logging.getLogger("meshbridge.as")

_MAX_BODY = 16 * 1024 * 1024  # a transaction batch is small; this is a hard cap
_TXN_RE = re.compile(r"^(?:/_matrix/app/v1)?/transactions/([^/]+)$")
_USER_RE = re.compile(r"^(?:/_matrix/app/v1)?/users/([^/]+)$")
_ROOM_RE = re.compile(r"^(?:/_matrix/app/v1)?/rooms/([^/]+)$")


class AsServer:
    """Owns the ThreadingHTTPServer; `submit_transaction(txn_id, events)` is
    called from server threads and must be thread-safe (main.py bridges it to
    the asyncio loop), `health_snapshot()` likewise."""

    def __init__(self, port: int, hs_token: str, user_namespace_re: str,
                 submit_transaction, health_snapshot) -> None:
        self.hs_token = hs_token
        self.user_ns = re.compile(user_namespace_re)
        self.submit_transaction = submit_transaction
        self.health_snapshot = health_snapshot
        outer = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            # -- plumbing ------------------------------------------------------

            def log_message(self, fmt, *args):  # noqa: N802 - stdlib name
                log.debug("as-http: " + fmt, *args)

            def _json(self, status: int, payload: dict) -> None:
                raw = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def _authed(self) -> bool:
                header = self.headers.get("Authorization", "")
                token = header[7:] if header.startswith("Bearer ") else ""
                if not token:
                    query = urllib.parse.urlparse(self.path).query
                    token = (urllib.parse.parse_qs(query).get("access_token") or [""])[0]
                return hmac.compare_digest(token, outer.hs_token)

            def _path(self) -> str:
                return urllib.parse.urlparse(self.path).path

            def _read_body(self) -> bytes | None:
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                except ValueError:
                    return None
                if length < 0 or length > _MAX_BODY:
                    return None
                return self.rfile.read(length)

            # -- verbs ---------------------------------------------------------

            def do_PUT(self):  # noqa: N802
                path = self._path()
                m = _TXN_RE.match(path)
                if not m:
                    return self._json(404, {"errcode": "M_UNRECOGNIZED",
                                            "error": "unknown endpoint"})
                if not self._authed():
                    return self._json(403, {"errcode": "M_FORBIDDEN",
                                            "error": "bad hs_token"})
                body = self._read_body()
                if body is None:
                    return self._json(413, {"errcode": "M_TOO_LARGE",
                                            "error": "transaction too large"})
                try:
                    events = json.loads(body or b"{}").get("events", [])
                except json.JSONDecodeError:
                    return self._json(400, {"errcode": "M_NOT_JSON",
                                            "error": "body is not JSON"})
                if not isinstance(events, list):
                    events = []
                txn_id = urllib.parse.unquote(m.group(1))
                outer.submit_transaction(txn_id, events)
                self._json(200, {})

            def do_GET(self):  # noqa: N802
                path = self._path()
                if path == "/healthz":
                    return self._json(200, outer.health_snapshot())
                if _USER_RE.match(path) or _ROOM_RE.match(path):
                    if not self._authed():
                        return self._json(403, {"errcode": "M_FORBIDDEN",
                                                "error": "bad hs_token"})
                m = _USER_RE.match(path)
                if m:
                    user_id = urllib.parse.unquote(m.group(1))
                    if outer.user_ns.match(user_id):
                        # claiming existence; the bridge lazily registers on use
                        return self._json(200, {})
                    return self._json(404, {"errcode": "M_NOT_FOUND",
                                            "error": "not in namespace"})
                if _ROOM_RE.match(path):
                    return self._json(404, {"errcode": "M_NOT_FOUND",
                                            "error": "no room namespace"})
                return self._json(404, {"errcode": "M_UNRECOGNIZED",
                                        "error": "unknown endpoint"})

            def do_POST(self):  # noqa: N802
                path = self._path()
                if path in ("/_matrix/app/v1/ping", "/ping"):
                    if not self._authed():
                        return self._json(403, {"errcode": "M_FORBIDDEN",
                                                "error": "bad hs_token"})
                    self._read_body()
                    return self._json(200, {})
                return self._json(404, {"errcode": "M_UNRECOGNIZED",
                                        "error": "unknown endpoint"})

        self._server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
        self.port = self._server.server_address[1]

    def start(self) -> None:
        thread = threading.Thread(target=self._server.serve_forever,
                                  name="as-http", daemon=True)
        thread.start()
        log.info("AS listener on :%d", self.port)

    def stop(self) -> None:
        self._server.shutdown()

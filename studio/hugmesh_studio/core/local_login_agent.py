"""Passwordless local-login loopback agent (generator/Studio-owned half).

Implements the generator side of the pinned wire contract "Passwordless
Local-Secrets Login (v1)": a tiny, dependency-light HTTP agent (stdlib only, no new
pip deps) that binds ``127.0.0.1:27621`` ONLY and vends locally-provisioned role
credentials to the brand login-ui running in the operator's browser. A trusted local
user can then pick a role card instead of typing a password; the browser posts the
vended ``{username, secret}`` to admin-bff's ``POST /bff/login/local``, which
validates them through Casdoor exactly like a typed password. The agent is NEVER
trusted as an auth authority — it is only a *source* for credential material the
generator already wrote to this machine's disk. All real auth still happens in
Casdoor via admin-bff (owned elsewhere; do not bypass).

Why this port (27621)?  Above the crowded dev band (3000/4200/5000/8080/9000) so it
never clashes with the Angular dev server or a running app; below both OS ephemeral
floors (Linux 32768, Windows 49152) so the kernel won't transiently hand it out; and
clear of common services (FlexLM 27000-27009, Steam 27015-27030, Mongo 27017). It is
FIXED — login-ui probes exactly ``http://127.0.0.1:27621`` (no port scanning). If the
bind fails, the agent exits non-zero and login-ui falls back to the password form.

SECURITY MODEL  (why a page on the public internet cannot use this agent)
-------------------------------------------------------------------------
* **Loopback-only bind.** The socket is opened on ``127.0.0.1``, NEVER ``0.0.0.0`` or
  a LAN interface, so nothing off-box can even connect.
* **OS-level peer-uid check (multi-user defense-in-depth).** A loopback bind still lets
  ANY local user connect to ``127.0.0.1:27621`` and forge the three request-controlled
  strings below (Origin, the custom header, Host). So on each accepted connection we ALSO
  verify — at the OS/socket layer, which a request cannot forge — that the connecting
  process's peer uid equals the agent's own uid, and drop the connection (before any
  route runs or any secret is touched) otherwise. This is ENFORCED on Linux (see
  :func:`_peer_uid`); on a platform with no reliable TCP peer-uid (macOS/*BSD/Windows) we
  FAIL OPEN with a documented one-time startup warning rather than silently pretending to
  check — the loopback bind + Origin allow-list + preflight header still apply there.
* **Exact-match Origin allow-list.** Every request must carry an ``Origin`` that is an
  EXACT (scheme+host+port) member of the allow-list (the brand login-ui origins from the
  manifest, PLUS the localhost dev origins only when dev mode is explicitly opted in —
  see below). No wildcards, no suffix matching. A missing or unlisted Origin => ``403``
  and the request STOPS before any role metadata or secret is touched.
* **Custom-header preflight requirement.** Both routes require ``X-HugMesh-Local:
  1``. That header is not CORS-safelisted, so a browser MUST send a CORS preflight
  (``OPTIONS``) first — a "simple request" (form POST, ``<img>``, ``sendBeacon``) can
  never reach a route. A request missing the header => ``403``.
* **Never** ``Access-Control-Allow-Origin: *``. We echo ONLY the exact matched origin.
* **DNS-rebinding defense.** The ``Host`` header must be exactly ``127.0.0.1:<port>``;
  a rebound hostname resolving to 127.0.0.1 (``Host: evil.example``) is rejected.
* **Single-use, short-TTL handoff.** ``POST /v1/handoff`` vends a role's secret at
  most once per ``GET /v1/roles`` probe (a fresh probe re-arms it) and stamps
  ``expiresAt = now + 30s`` so the browser submits immediately and never persists it.

ROUTES  (both require ``X-HugMesh-Local: 1``)
  * ``GET  /v1/roles``   -> metadata only, NEVER secrets.
  * ``POST /v1/handoff`` -> single-use, short-TTL credential handoff.

ON-DISK INTEGRATION POINT  (the roles manifest)
-----------------------------------------------
No local-login credential file existed before this feature, so this module DEFINES a
small, clearly-documented "local login roles manifest" as the integration point. The
generator/Studio WRITES it (see :meth:`RolesManifest.write`); this agent only READS
it. Default location ``default_manifest_path()`` (override with
``$HUGMESH_LOCAL_LOGIN_MANIFEST`` or the ``--login-manifest`` CLI flag). Shape
(version 1)::

    {
      "version": 1,
      "origins": ["https://login.acme.internal"],  // extra brand login-ui origins to ALLOW
      "devOrigins": false,                          // opt-in: also trust localhost:4200 dev origins
      "roles": [
        {
          "id": "brandowner",                       // stable role id (lookup + telemetry)
          "label": "Brand Owner",                   // human label for the picker card
          "brand": "acme",                          // brand slug
          "username": "brandowner@acme.local",      // Casdoor login name
          "secret": "<local-secret>"                // Casdoor-valid secret (NEVER in /v1/roles)
        }
      ]
    }

``origins`` is read ONCE at startup; a request can therefore never widen the allow-list.
The built-in localhost dev origins (``http://localhost:4200`` / ``http://127.0.0.1:4200``)
are NO LONGER trusted by default: a shipped production/standalone agent trusts ONLY the
brand ``origins`` from the manifest, so a random local page on the very common dev port
4200 is not a credential oracle. Local development re-enables them via an explicit opt-in
— the ``--dev`` CLI flag, the ``HUGMESH_LOCAL_LOGIN_DEV`` env var, or ``"devOrigins":
true`` in the manifest (also read ONCE at startup). ``roles`` is re-read on every
``/v1/roles`` probe so a rotated secret takes effect without restarting the agent. The
file holds plaintext secrets, so :meth:`RolesManifest.write` creates it mode 0600 and
the loader warns loudly if it is group/world readable on POSIX.
"""
from __future__ import annotations

import json
import os
import re
import socket
import struct
import sys
import threading
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ── wire-contract constants (do not drift from the pinned contract) ──────────
BIND_HOST = "127.0.0.1"          # loopback ONLY — never 0.0.0.0 / a LAN interface
PORT = 27621                     # FIXED (see module docstring for the justification)
AGENT_NAME = "hugmesh-local-login"
PROTOCOL_VERSION = 1
LOCAL_HEADER = "X-HugMesh-Local"    # required on both routes; forces a CORS preflight
HANDOFF_TTL_SECONDS = 30               # expiresAt = now + 30s
CORS_MAX_AGE = 600                     # Access-Control-Max-Age for the preflight
MAX_BODY = 64 * 1024                   # cap the POST body (roleId only — kept tiny)

# The Angular dev server on loopback. Trusted ONLY when dev mode is explicitly opted in
# (see DEV_ORIGINS_ENV / --dev / manifest "devOrigins") — NEVER by default, so a shipped
# production agent trusts only the brand "origins" from the manifest. Brand origins
# (https://login.<brand>.internal) come from the manifest's "origins" at startup.
DEV_ALLOWED_ORIGINS = ("http://localhost:4200", "http://127.0.0.1:4200")
# Env-var opt-in for the localhost dev origins above (truthy => trust them this run).
DEV_ORIGINS_ENV = "HUGMESH_LOCAL_LOGIN_DEV"

# An Origin is scheme://host[:port] with NO path, NO wildcard, NO userinfo. Used to
# reject anything unsafe a mis-written manifest might try to add to the allow-list.
_ORIGIN_RE = re.compile(r"^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$")
# A role id: a compact, safe token (it is a dict key and is echoed back verbatim).
_ROLE_ID_RE = re.compile(r"^[A-Za-z0-9._@-]{1,64}$")


def _log(msg: str) -> None:
    """Single-line stderr log. NEVER pass a secret / handoff body through here."""
    print(f"[local-login] {msg}", file=sys.stderr)


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _env_dev_enabled() -> bool:
    """True if the localhost dev origins are opted in via ``$HUGMESH_LOCAL_LOGIN_DEV``.

    A shipped production agent leaves this unset so the localhost dev origins stay
    untrusted; a developer exports ``HUGMESH_LOCAL_LOGIN_DEV=1`` to re-enable them.
    """
    return os.environ.get(DEV_ORIGINS_ENV, "").strip().lower() in ("1", "true", "yes", "on")


def default_manifest_path() -> str:
    """Where the generator writes / the agent reads the roles manifest.

    ``$HUGMESH_LOCAL_LOGIN_MANIFEST`` overrides; otherwise
    ``$XDG_CONFIG_HOME`` (or ``~/.config``)/hugmesh-studio/local-login/roles.json.
    """
    override = os.environ.get("HUGMESH_LOCAL_LOGIN_MANIFEST")
    if override:
        return override
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "hugmesh-studio", "local-login", "roles.json")


# ── manifest model ───────────────────────────────────────────────────────────
@dataclass
class Role:
    id: str
    label: str
    brand: str
    username: str
    secret: str          # NEVER exposed by GET /v1/roles; only by a single-use handoff

    def public(self) -> dict:
        """The secret-free view returned by GET /v1/roles."""
        return {"id": self.id, "label": self.label, "brand": self.brand}


@dataclass
class RolesManifest:
    roles: list = field(default_factory=list)
    origins: frozenset = field(default_factory=frozenset)   # EXTRA allowed origins
    dev_origins: bool = False                               # opt-in: also trust localhost:4200

    def write(self, path: str) -> str:
        """Write the manifest as mode-0600 JSON (it carries plaintext secrets).

        This is the generator/Studio-side producer API for the integration point.
        Created with O_CREAT|0600 so the secrets never briefly exist world-readable.
        """
        parent = os.path.dirname(os.path.abspath(path))
        os.makedirs(parent, exist_ok=True)
        data = {
            "version": PROTOCOL_VERSION,
            "origins": sorted(self.origins),
            "devOrigins": self.dev_origins,
            "roles": [asdict(r) for r in self.roles],
        }
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2)
        try:
            os.chmod(path, 0o600)   # tighten even if the file pre-existed with wider mode
        except OSError:
            pass
        return path


def _warn_if_world_readable(path: str) -> None:
    if os.name != "posix":
        return
    try:
        mode = os.stat(path).st_mode
    except OSError:
        return
    if mode & 0o077:
        _log(f"WARNING: manifest {path} is group/world readable (mode {oct(mode & 0o777)}); "
             "it holds plaintext login secrets — chmod 600 it")


def load_manifest(path: str) -> RolesManifest:
    """Read + validate the roles manifest. Missing/corrupt => an EMPTY manifest (the
    agent then serves no roles and login-ui degrades to the password form) rather than
    crashing. Malformed roles / origins are skipped with a loud warning."""
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return RolesManifest()
    except (OSError, ValueError) as e:
        _log(f"could not read manifest {path}: {e}; serving no roles")
        return RolesManifest()
    _warn_if_world_readable(path)
    if not isinstance(data, dict):
        _log(f"manifest {path} is not a JSON object; serving no roles")
        return RolesManifest()

    roles: list[Role] = []
    seen: set[str] = set()
    for raw in data.get("roles") or []:
        if not isinstance(raw, dict):
            continue
        rid = raw.get("id")
        if not isinstance(rid, str) or not _ROLE_ID_RE.fullmatch(rid):
            _log(f"skipping role with invalid id: {rid!r}")
            continue
        if rid in seen:
            _log(f"skipping duplicate role id: {rid!r}")
            continue
        fields = (raw.get("label"), raw.get("brand"), raw.get("username"), raw.get("secret"))
        if not all(isinstance(v, str) and v for v in fields):
            _log(f"skipping role {rid!r}: label/brand/username/secret must all be non-empty strings")
            continue
        label, brand, username, secret = fields
        roles.append(Role(id=rid, label=label, brand=brand, username=username, secret=secret))
        seen.add(rid)

    origins: set[str] = set()
    for o in data.get("origins") or []:
        if isinstance(o, str) and _ORIGIN_RE.fullmatch(o):
            origins.add(o)
        else:
            _log(f"skipping invalid manifest origin: {o!r}")
    # Strictly a JSON boolean true -> opt in to the localhost dev origins (never a
    # truthy string / number, so a mistyped value can't accidentally widen trust).
    dev_origins = data.get("devOrigins") is True
    return RolesManifest(roles=roles, origins=frozenset(origins), dev_origins=dev_origins)


# ── the agent (state + policy, transport-agnostic) ───────────────────────────
class LocalLoginAgent:
    """Holds the allow-list (fixed at startup) and the per-probe armed handoff state.

    Thread-safe: the HTTP server is threaded, so all mutable state is guarded by a
    lock. The Origin allow-list is intentionally NOT refreshed by a request — a
    request must never be able to widen the set of origins that can reach it.
    """

    def __init__(self, manifest_path: str, *, allow_dev_origins: bool = False):
        self.manifest_path = manifest_path
        self._lock = threading.Lock()
        m = load_manifest(manifest_path)
        # FINDING 2 (dev-origin gating): the localhost dev origins are trusted ONLY when
        # explicitly opted in — via this flag (CLI --dev), the HUGMESH_LOCAL_LOGIN_DEV
        # env var, or "devOrigins": true in the manifest. A shipped production agent
        # therefore trusts ONLY the brand origins from the manifest, never a random
        # localhost page on the very common dev port 4200. Resolved ONCE at startup (like
        # the origins themselves) so a request can never widen the allow-list.
        self.dev_origins_enabled = bool(allow_dev_origins or m.dev_origins or _env_dev_enabled())
        origins = set(m.origins)
        if self.dev_origins_enabled:
            origins |= set(DEV_ALLOWED_ORIGINS)
        self.allowed_origins = frozenset(origins)
        self._roles: dict[str, Role] = {r.id: r for r in m.roles}
        self._armed: set[str] = set()      # role ids currently vendable (one handoff each)

    def is_allowed_origin(self, origin) -> bool:
        """Exact (scheme+host+port) membership — no wildcard, no suffix match."""
        return isinstance(origin, str) and origin in self.allowed_origins

    def probe(self) -> list:
        """Re-read roles from disk, arm each for a single handoff, and return the
        PUBLIC (secret-free) role list. A fresh probe is what re-arms a consumed
        handoff, per the contract."""
        m = load_manifest(self.manifest_path)
        with self._lock:
            self._roles = {r.id: r for r in m.roles}
            self._armed = set(self._roles)
            return [r.public() for r in self._roles.values()]

    def vend(self, role_id: str) -> tuple[int, dict]:
        """Single-use handoff. Returns (http_status, json_payload).

        200 -> the credential handoff (consumes the arming for this role id).
        404 -> unknown role id.
        409 -> handoff already consumed since the last probe (re-probe to re-arm).
        """
        with self._lock:
            role = self._roles.get(role_id)
            if role is None:
                return 404, {"error": "unknown roleId"}
            if role_id not in self._armed:
                return 409, {"error": "handoff already consumed; re-probe GET /v1/roles to re-arm"}
            self._armed.discard(role_id)   # single-use: burn it inside the lock
            username, secret = role.username, role.secret
        expires = (_utcnow() + timedelta(seconds=HANDOFF_TTL_SECONDS)).strftime("%Y-%m-%dT%H:%M:%SZ")
        return 200, {"roleId": role_id, "username": username, "secret": secret, "expiresAt": expires}


# ── OS-level peer-uid authentication (FINDING 1: multi-user defense-in-depth) ──
def _proc_endpoint(addr) -> str | None:
    """Encode an IPv4 ``(host, port)`` sockaddr as the ``HEXADDR:HEXPORT`` token that
    ``/proc/net/tcp`` uses: the address in the kernel's native (little-endian on x86)
    byte order as 8 uppercase hex digits, then the port as 4. The agent binds IPv4
    loopback, so IPv4 fully covers every real connection; anything else -> ``None``."""
    try:
        host, port = addr[0], int(addr[1])
    except (TypeError, ValueError, IndexError):
        return None
    try:
        packed = socket.inet_aton(host)          # IPv4 dotted-quad only
    except OSError:
        return None
    return f"{int.from_bytes(packed, 'little'):08X}:{port:04X}"


_TCP_ESTABLISHED = "01"     # /proc/net/tcp "st" column value for an ESTABLISHED socket


def _proc_net_peer_uid(peer, local) -> int | None:
    """Resolve the uid owning the CLIENT side of a TCP connection via ``/proc/net/tcp``.

    ``peer``/``local`` are ``getpeername()``/``getsockname()`` for OUR accepted socket, so
    the connecting process's row has ``local_address == peer`` and ``rem_address ==
    local`` (a unique 4-tuple). That row's ``uid`` column is the connecting user.

    We only trust an ESTABLISHED (``st == 01``) row: when ``verify_request`` runs, a real
    request's peer socket is always ESTABLISHED, whereas a closing/closed peer shows up as
    TIME_WAIT etc. — which the kernel attributes to ``uid 0`` — so matching those would
    spuriously reject a fast same-uid client. Returns ``None`` if ``/proc`` is unavailable
    or no ESTABLISHED row matches; the caller then fails open (defense-in-depth: an
    uncertain lookup must never wrongly reject a peer)."""
    want_local = _proc_endpoint(peer)
    want_rem = _proc_endpoint(local)
    if want_local is None or want_rem is None:
        return None
    try:
        with open("/proc/net/tcp", encoding="ascii") as fh:
            next(fh, None)                       # skip the header row
            for line in fh:
                f = line.split()
                if (len(f) > 7 and f[1].upper() == want_local
                        and f[2].upper() == want_rem and f[3] == _TCP_ESTABLISHED):
                    try:
                        return int(f[7])         # the uid column
                    except ValueError:
                        return None
    except OSError:
        return None
    return None


def _peer_uid(conn) -> int | None:
    """Best-effort OS-level uid of the process on the other end of a loopback socket, or
    ``None`` when this platform exposes no reliable peer-uid for a TCP connection.

    Two mechanisms, in order:

    1. ``SO_PEERCRED`` (Linux). The canonical peer-credential getsockopt — but it is an
       AF_UNIX mechanism: on a TCP socket the kernel returns a sentinel ``uid = (uid_t)-1``
       (empirically ``-1`` here), so we only trust a value ``>= 0`` (which would cover an
       AF_UNIX transport if this agent were ever adapted to one) and otherwise fall
       through to the mechanism that actually works for TCP.
    2. ``/proc/net/tcp`` (Linux). The reliable peer-uid for a TCP loopback connection —
       see :func:`_proc_net_peer_uid`.

    On macOS/*BSD (no ``/proc``) and Windows there is no portable reliable equivalent for
    a TCP socket, so we return ``None`` and the caller documents the reduced guarantee.
    """
    peercred = getattr(socket, "SO_PEERCRED", None)
    if peercred is not None:
        try:
            raw = conn.getsockopt(socket.SOL_SOCKET, peercred, struct.calcsize("3i"))
            _pid, uid, _gid = struct.unpack("3i", raw)
            if uid >= 0:                         # valid only for an AF_UNIX peer; TCP -> -1
                return uid
        except (OSError, struct.error):
            pass
    try:
        peer, local = conn.getpeername(), conn.getsockname()
    except OSError:
        return None
    return _proc_net_peer_uid(peer, local)


# Whether THIS platform can enforce the peer-uid check for our TCP loopback socket.
# Linux (has os.getuid + /proc/net/tcp) => enforced; else the check fails open with a
# documented startup warning (see run()).
PEER_UID_ENFORCED = hasattr(os, "getuid") and os.path.exists("/proc/net/tcp")


# ── HTTP transport ───────────────────────────────────────────────────────────
class _Handler(BaseHTTPRequestHandler):
    # Do not leak the Python/version banner.
    server_version = f"{AGENT_NAME}/{PROTOCOL_VERSION}"
    sys_version = ""

    # -- helpers --------------------------------------------------------------
    def log_message(self, fmt, *args):    # route through our tagged stderr logger
        _log("%s %s" % (self.address_string(), fmt % args))

    def _cors(self, origin: str) -> None:
        """CORS headers for an ALLOWED origin. Echoes the exact origin — NEVER '*'."""
        self.send_header("Access-Control-Allow-Origin", origin)
        self.send_header("Vary", "Origin")
        self.send_header("Access-Control-Allow-Methods", "GET, POST")
        self.send_header("Access-Control-Allow-Headers", LOCAL_HEADER)
        self.send_header("Access-Control-Max-Age", str(CORS_MAX_AGE))

    def _send(self, code: int, payload: dict | None, origin: str | None = None) -> None:
        data = json.dumps(payload).encode("utf-8") if payload is not None else b""
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        if origin is not None:               # only for allowed origins
            self._cors(origin)
        self.end_headers()
        if data:
            self.wfile.write(data)

    def _guard_common(self):
        """Host + Origin checks that gate EVERY method, before any sensitive work.
        Returns (ok, origin). On failure a 403 is already sent (no CORS headers, so a
        disallowed origin's page can't even read the body)."""
        # DNS-rebinding defense: Host must be exactly the loopback literal we bound to.
        if self.headers.get("Host") != self.server.expected_host:   # type: ignore[attr-defined]
            self._send(403, {"error": "bad host"})
            return False, None
        origin = self.headers.get("Origin")
        if not self.server.agent.is_allowed_origin(origin):         # type: ignore[attr-defined]
            self._send(403, {"error": "origin not allowed"})
            return False, None
        return True, origin

    def _has_local_header(self) -> bool:
        return self.headers.get(LOCAL_HEADER) == "1"

    def _read_body(self, origin: str):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self._send(400, {"error": "bad Content-Length"}, origin=origin)
            return None
        if length < 0 or length > MAX_BODY:
            self._send(413, {"error": "body too large"}, origin=origin)
            return None
        return self.rfile.read(length)

    # -- methods --------------------------------------------------------------
    def do_OPTIONS(self):
        ok, origin = self._guard_common()
        if not ok:
            return
        # Preflight: the browser doesn't send X-HugMesh-Local here (it advertises it
        # in Access-Control-Request-Headers); we just answer with the allowed surface.
        self.send_response(204)
        self._cors(origin)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        ok, origin = self._guard_common()
        if not ok:
            return
        if not self._has_local_header():
            self._send(403, {"error": f"missing {LOCAL_HEADER} header"}, origin=origin)
            return
        if self.path.split("?", 1)[0] != "/v1/roles":
            self._send(404, {"error": "not found"}, origin=origin)
            return
        roles = self.server.agent.probe()       # type: ignore[attr-defined]
        self._send(200, {"agent": AGENT_NAME, "version": PROTOCOL_VERSION, "roles": roles},
                   origin=origin)

    def do_POST(self):
        ok, origin = self._guard_common()
        if not ok:
            return
        if not self._has_local_header():
            self._send(403, {"error": f"missing {LOCAL_HEADER} header"}, origin=origin)
            return
        if self.path.split("?", 1)[0] != "/v1/handoff":
            self._send(404, {"error": "not found"}, origin=origin)
            return
        body = self._read_body(origin)
        if body is None:
            return   # error already sent
        try:
            req = json.loads(body or b"{}")
        except ValueError:
            self._send(400, {"error": "invalid JSON body"}, origin=origin)
            return
        role_id = req.get("roleId") if isinstance(req, dict) else None
        if not isinstance(role_id, str) or not role_id:
            self._send(400, {"error": "roleId (string) required"}, origin=origin)
            return
        status, payload = self.server.agent.vend(role_id)    # type: ignore[attr-defined]
        self._send(status, payload, origin=origin)


class _LoopbackAuthServer(ThreadingHTTPServer):
    """ThreadingHTTPServer that ALSO enforces an OS-level peer-uid check (FINDING 1).

    A loopback bind plus the forgeable Origin / X-HugMesh-Local / Host headers is not
    enough on a MULTI-USER host: any local user can connect to 127.0.0.1:27621 and forge
    all three request-controlled strings. So on each accepted connection we verify the
    connecting socket's peer uid equals THIS process's uid, and drop the connection
    (before ``process_request`` runs, so no route/handler ever touches a secret) if it
    does not.

    ENFORCED where the OS exposes a reliable peer uid for a TCP loopback socket (Linux —
    see :func:`_peer_uid`). Where it does not (macOS/*BSD/Windows), we FAIL OPEN with a
    documented one-time startup warning (see :func:`run`) rather than silently pretending
    to check; the loopback bind + Origin allow-list + preflight header remain the
    guarantees there.
    """

    def verify_request(self, request, client_address):
        # socketserver calls this after get_request(); a False return shuts the
        # connection down before process_request(), so no handler runs for it.
        try:
            my_uid = os.getuid()
        except AttributeError:
            return True                       # no uid concept (Windows) -> documented fail-open
        peer = _peer_uid(request)
        if peer is None:
            return True                       # unknown peer uid -> documented fail-open
        if peer != my_uid:
            _log(f"rejecting loopback connection from uid {peer} "
                 f"(agent runs as uid {my_uid}): peer-uid mismatch")
            return False
        return True


def make_server(agent: LocalLoginAgent, host: str = BIND_HOST, port: int = PORT) -> ThreadingHTTPServer:
    """Bind the loopback server. Raises OSError if the bind fails (caller exits)."""
    httpd = _LoopbackAuthServer((host, port), _Handler)
    httpd.agent = agent                                    # type: ignore[attr-defined]
    # Expected Host = the loopback literal + the ACTUAL bound port (0 -> ephemeral in tests).
    httpd.expected_host = f"{host}:{httpd.server_address[1]}"   # type: ignore[attr-defined]
    return httpd


def run(manifest_path: str | None = None, host: str = BIND_HOST, port: int = PORT,
        *, allow_dev_origins: bool = False) -> int:
    """Load the manifest, bind loopback, and serve until interrupted. Returns a process
    exit code: 0 on clean shutdown, 1 if the bind failed (login-ui then falls back to
    the password form).

    ``allow_dev_origins`` (CLI ``--dev``) additionally trusts the localhost dev origins;
    it is OR-ed with the ``HUGMESH_LOCAL_LOGIN_DEV`` env var and the manifest's
    ``devOrigins`` flag. Leave it off for a shipped production build."""
    manifest_path = manifest_path or default_manifest_path()
    agent = LocalLoginAgent(manifest_path, allow_dev_origins=allow_dev_origins)
    try:
        httpd = make_server(agent, host, port)
    except OSError as e:
        _log(f"could not bind {host}:{port}: {e}; login-ui will fall back to the password form")
        return 1
    if not PEER_UID_ENFORCED:
        # FINDING 1 reduced-guarantee: document it loudly instead of silently no-op'ing.
        _log("WARNING: OS-level peer-uid authentication is unavailable on this platform; "
             "on a MULTI-USER host another local user could reach this loopback agent. The "
             "loopback bind, Origin allow-list and preflight header still apply.")
    if agent.dev_origins_enabled:
        _log("localhost dev origins ENABLED (--dev / HUGMESH_LOCAL_LOGIN_DEV / manifest "
             "devOrigins) — do NOT enable this in a shipped production build")
    _log(f"listening on http://{host}:{httpd.server_address[1]} "
         f"(manifest: {manifest_path}; {len(agent.allowed_origins)} allowed origin(s))")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        _log("shutting down")
    finally:
        httpd.shutdown()
        httpd.server_close()
    return 0

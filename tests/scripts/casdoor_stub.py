#!/usr/bin/env python3
"""A stub Casdoor, for tests/scripts/test-casdoor-init-honesty.sh.

It exists to reproduce, offline, the FAILURE SHAPES the real Casdoor produces —
the ones that let a completely failed `casdoor-init` run print success on the
first real cluster:

  * Casdoor answers an authorization denial, a bad login and a validation error
    alike with **HTTP 200** and `{"status":"error","msg":…}` in the body
    (routers/authz_filter.go denyRequest -> responseError). Nothing raises. A
    caller that only inspects the HTTP status sees success every time.
  * `{"status":"ok"}` is not proof a write landed: casdoor:3.80.0's
    /api/update-group returns `{"status":"ok","data":"Affected"}` while not
    persisting group membership at all (LIVE-VERIFIED — see the note in
    manifests/casdoor/init-job.yaml).
  * SERVER-SIDE STATE A PAYLOAD CANNOT INVENT. casdoor stamps a new user with a
    UUID `id`, and every organization gets the default account items in which
    "ID" has ModifyRule "Immutable" (object/init.go:53). /api/update-user with a
    payload built from scratch therefore looks like a request to change that UUID
    to "" and is REJECTED with "The ID is immutable." (object/user_util.go:
    553-559 -> object/organization.go:325-336). The bite is that this only
    happens on the SECOND and later runs — the first, against a user that does
    not exist yet, takes the add path and succeeds — so a reconciler with this
    bug looks perfect on a fresh cluster and fails on every ArgoCD re-sync
    afterwards. `ok` mode reproduces it (LIVE-REPRODUCED: casdoor-init hit
    exactly this on the kind cluster once the seed fix let it get that far).

Modes (STUB_MODE), each a shape observed or reasoned about on the live cluster:

  ok            a small in-memory Casdoor that actually stores objects.
  deny-login    /api/login and /api/get-account report an error; every other API
                answers "Please login first". THE LIVE SHAPE: the admin login
                failed, so every subsequent call ran anonymous and was denied.
  deny-writes   reads work, every add-*/update-*/set-password is denied.
  writes-vanish everything answers {"status":"ok"} and NOTHING is stored — the
                update-group shape, generalised.
  readback-denied
                the write answers {"status":"ok","data":"Unaffected"} and stores
                nothing, and the verification read that follows it is DENIED
                (HTTP 200 + {"status":"error"}). This separates a script that
                VERIFIES a write from one that merely re-reads and lets an
                error-swallowing helper turn the denial into "the object is
                empty" — which, when the write was a prune to empty, reads as
                "the write landed" and gets announced. Reads before the first
                write still work, so the script gets all the way to its write.
  setpw-noop    like `ok`, except /api/set-password reports success without
                changing the password.

/api/set-password models casdoor's own refusal to re-set a password that already
matches the stored one (object/check_password_complexity.go:104-124 ->
controllers/user.go:629-633). That refusal is the ONLY read-back a password has —
casdoor masks it as "***" on every read (object/user.go:678), which this stub does
too — so a stub that accepted the identical write twice would let a reconciler
"verify" a credential against nothing at all. A seeded user's "password" is the
value the "cluster" already holds, which is how the rotation scenarios start from
a superadmin carrying the PREVIOUS password.

STUB_SEED optionally names a JSON file of {"<noun>:<owner>/<name>": {object}}
loaded into the store before the first request, so a reconciler that only writes
when it finds existing objects (the derived-role sync Jobs read three roles and
write a fourth) actually reaches its write path instead of exiting early — a
scenario that never reached the write would "pass" every honesty assertion below
while proving nothing.

No dependencies beyond the stdlib, no network egress: it binds 127.0.0.1 on an
ephemeral port and writes the chosen port to STUB_PORT_FILE. Every request is
appended to STUB_JOURNAL as one JSON object per line so the harness can assert
which API calls a script actually made (never their bodies — a body would carry
the password this whole exercise exists to protect).
"""
import json
import os
import re
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODE = os.environ.get("STUB_MODE", "ok")
ADMIN_USER = os.environ.get("STUB_ADMIN_USER", "admin")
PORT_FILE = os.environ.get("STUB_PORT_FILE", "")
JOURNAL = os.environ.get("STUB_JOURNAL", "")

SEED_FILE = os.environ.get("STUB_SEED", "")

VALID_MODES = {"ok", "deny-login", "deny-writes", "writes-vanish",
               "readback-denied", "setpw-noop"}
if MODE not in VALID_MODES:
    sys.exit(f"casdoor_stub: unknown STUB_MODE {MODE!r} (want one of {sorted(VALID_MODES)})")

_lock = threading.Lock()
# The password the stub currently accepts for ADMIN_USER. Starts at whatever the
# harness says the "cluster" has (the casdoor bootstrap default, normally) and
# only moves through /api/set-password.
_password = os.environ.get("STUB_ADMIN_PASSWORD", "123")
_sessions = set()
_store = {}          # "<noun>:<owner>/<name>" -> object
# The password of every user OTHER than the built-in admin, "<owner>/<name>" ->
# value. Populated by add-user (casdoor hashes the body's password on create) and
# by /api/set-password, so the two ways a credential can reach casdoor are both
# modelled and a reconciler cannot tell them apart from the outside.
_user_passwords = {}
_counter = [0]
_wrote = [False]     # has any write been attempted yet (readback-denied mode)

# object/check_password_complexity.go:104-124 + controllers/user.go:629-633 —
# casdoor REFUSES a set-password whose new value already hashes to the stored one.
# That refusal is the only observable read-back a password has, so a stub that
# accepted the identical write twice would let a reconciler "verify" a rotation
# against nothing.
SAME_AS_CURRENT = "The new password must be different from your current password"

API_RE = re.compile(r"^/api/(get|add|update)-([a-z-]+)$")
# Endpoints reachable without a session, exactly like casdoor's own public set.
PUBLIC = {"/api/health", "/api/login"}


def _journal(entry):
    if not JOURNAL:
        return
    with _lock, open(JOURNAL, "a") as fh:
        fh.write(json.dumps(entry, sort_keys=True) + "\n")


def _ident(obj):
    return f"{obj.get('owner', '')}/{obj.get('name', '')}"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # keep the harness output readable
        pass

    # ── plumbing ────────────────────────────────────────────────────────────
    def _send(self, payload):
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for cookie in getattr(self, "_cookies", []):
            self.send_header("Set-Cookie", cookie)
        self.end_headers()
        self.wfile.write(body)

    def _ok(self, data=None, extra=None):
        payload = {"status": "ok", "msg": "", "data": data}
        payload.update(extra or {})
        self._send(payload)

    def _error(self, msg):
        # HTTP 200 with an error envelope — the whole point of this stub.
        self._send({"status": "error", "msg": msg, "data": None})

    def _authed(self):
        cookie = self.headers.get("Cookie") or ""
        return any(tok in cookie for tok in _sessions)

    def _read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    # ── routing ─────────────────────────────────────────────────────────────
    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def _dispatch(self, method):
        self._cookies = []
        parsed = urllib.parse.urlparse(self.path)
        path, query = parsed.path, urllib.parse.parse_qs(parsed.query)
        raw = self._read_body() if method == "POST" else b""
        ctype = self.headers.get("Content-Type") or ""
        if "x-www-form-urlencoded" in ctype:
            form = {k: v[0] for k, v in urllib.parse.parse_qs(raw.decode()).items()}
            body = None
        else:
            form = None
            try:
                body = json.loads(raw) if raw else None
            except ValueError:
                body = None
        # Field NAMES only — a value could be a password.
        _journal({"method": method, "path": path,
                  "fields": sorted((form or body or {}).keys())
                            if isinstance(form or body, dict) else []})

        if path == "/api/health":
            return self._ok("ok")
        if path == "/api/login":
            return self._login(body or {})
        if path not in PUBLIC and not self._authed():
            # casdoor's authz filter: HTTP 200, status error.
            return self._error("Unauthorized operation")
        if path == "/api/get-account":
            if MODE == "deny-login":
                return self._error("Please login first")
            return self._ok({"owner": "built-in", "name": ADMIN_USER, "isAdmin": True},
                            extra={"name": ADMIN_USER, "sub": f"built-in/{ADMIN_USER}"})
        if path == "/api/set-password":
            return self._set_password(form or {})
        m = API_RE.match(path)
        if not m:
            # An endpoint this stub does not model must FAIL, never quietly pass.
            return self._error(f"unmodelled endpoint {path}")
        return self._crud(m.group(1), m.group(2), query, body)

    # ── endpoints ───────────────────────────────────────────────────────────
    def _login(self, body):
        if MODE == "deny-login":
            return self._error("password is incorrect")
        with _lock:
            if body.get("username") != ADMIN_USER or body.get("password") != _password:
                return self._error("password is incorrect")
            _counter[0] += 1
            token = f"stub-session-{_counter[0]}"
            _sessions.add(token)
        self._cookies = [f"casdoor_session_id={token}; Path=/"]
        return self._ok(f"built-in/{ADMIN_USER}")

    def _set_password(self, form):
        if MODE == "deny-writes":
            return self._error("Unauthorized operation")
        with _lock:
            owner = form.get("userOwner") or ""
            name = form.get("userName") or ""
            new = form.get("newPassword") or ""
            ident = f"{owner}/{name}"
            # The built-in admin is the session credential and is kept separately;
            # any other account must EXIST, exactly as controllers/user.go:520-531
            # requires ("The user: %s doesn't exist").
            is_admin_account = (name == ADMIN_USER and owner in ("built-in", ""))
            if not is_admin_account and f"user:{ident}" not in _store:
                return self._error(f"The user: {ident} doesn't exist")
            current = _password if is_admin_account else _user_passwords.get(ident)
            old = form.get("oldPassword")
            # controllers/user.go:597-606: on the isAdmin branch the old password is
            # checked only when one is supplied. Every request this stub sees is
            # already an admin session (the authz gate above), so mirror that.
            if old and old != current:
                return self._error("old password is incorrect")
            if current is not None and new == current:
                return self._error(SAME_AS_CURRENT)
            if MODE in ("setpw-noop", "writes-vanish"):
                return self._ok()          # reports success, changes nothing
            if is_admin_account:
                globals()["_password"] = new or _password
                # A real password change invalidates nothing here, but the caller is
                # expected to re-login, so make the old cookies useless to be sure
                # it does. Only for the admin: casdoor invalidates the sessions of
                # the user whose password changed, not the operator's.
                _sessions.clear()
            else:
                _user_passwords[ident] = new
        return self._ok()

    def _crud(self, verb, noun, query, body):
        if verb == "get":
            if MODE == "readback-denied" and _wrote[0]:
                # The verification read after the write is denied. casdoor's own
                # GetRole answers ResponseOk(role) — data null — for an object that
                # does not exist, so status "error" here is a DENIAL and never an
                # absence: a caller that turns it into an empty object is inventing
                # a fact about the store.
                return self._error("Unauthorized operation")
            ident = (query.get("id") or [""])[0]
            with _lock:
                return self._ok(_store.get(f"{noun}:{ident}"))
        _wrote[0] = True
        if MODE == "deny-writes":
            return self._error("Unauthorized operation")
        if MODE == "writes-vanish":
            return self._ok("Affected")    # the update-group shape
        if MODE == "readback-denied":
            # wrapActionResponse()'s other success shape: reached the handler,
            # changed nothing, still status ok.
            return self._ok("Unaffected")
        obj = body if isinstance(body, dict) else {}
        ident = (query.get("id") or [None])[0] or _ident(obj)
        with _lock:
            key = f"{noun}:{ident}"
            if noun == "user":
                # casdoor stamps the id server-side; a caller cannot know it
                # without reading the object back first.
                if verb == "add":
                    obj = dict(obj)
                    _counter[0] += 1
                    obj.setdefault("id", f"stub-uuid-{_counter[0]}")
                    # AddUser hashes the body's password into the row
                    # (object/user.go:1029-1031 UpdateUserPassword), so a create
                    # DOES set the credential — which is why the shipped script's
                    # proof on the create path must come out "already the
                    # provisioned value" rather than "rotated".
                    if obj.get("password"):
                        _user_passwords[ident] = obj["password"]
                else:
                    stored_id = (_store.get(key) or {}).get("id")
                    if stored_id and obj.get("id") != stored_id:
                        # object/user_util.go:553-559 -> organization.go:325-336
                        return self._error("The ID is immutable.")
            # A password never survives a read: casdoor masks it as "***" on the
            # way out (object/user.go:678). Storing the real value would let a
            # script "verify" a credential by reading it back, which no real
            # deployment can do — the mask is exactly why apply_password() has to
            # prove itself through set-password's own refusal instead.
            if noun == "user" and "password" in obj:
                obj = dict(obj, password="***")
            _store[key] = obj
        return self._ok("Affected")


def main():
    if SEED_FILE:
        with open(SEED_FILE) as fh:
            seeded = json.load(fh)
        if not isinstance(seeded, dict) or not seeded:
            sys.exit(f"casdoor_stub: STUB_SEED {SEED_FILE} is not a non-empty object")
        # A seeded user's "password" is the credential the "cluster" already holds
        # — the shape a rotation has to overwrite. It moves into _user_passwords
        # and the stored row keeps only the mask, so nothing can be read back.
        for key, obj in seeded.items():
            if key.startswith("user:") and isinstance(obj, dict) and obj.get("password"):
                _user_passwords[key.split(":", 1)[1]] = obj["password"]
                seeded[key] = dict(obj, password="***")
        _store.update(seeded)
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    if PORT_FILE:
        tmp = PORT_FILE + ".tmp"
        with open(tmp, "w") as fh:
            fh.write(str(srv.server_address[1]))
        os.replace(tmp, PORT_FILE)   # atomic: the harness polls for this file
    srv.serve_forever()


if __name__ == "__main__":
    main()

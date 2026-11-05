"""Signed HugMesh tokens — how a mesh admin shares "join my mesh, in this domain, as
this role, with or without shell access" with someone whose tray then runs the node.

OPERATOR ASK (2026-11-04): "make sure that windows tray icon can run mesh appropriately
per access domain and role permissions as well as shell access permissions as
permitted when a hugmesh token is shared".

A token is one line of text::

    hugmesh-token-v1.<base64url payload JSON>.<base64url SSHSIG signature>

The payload carries the tailnet/headscale pre-auth key, the control-plane URL, the
access domain, the role (one of :data:`ROLES`), whether shell access is granted, an
expiry, and the issuer's ``ssh-ed25519`` public key. The signature is an OpenSSH
``SSHSIG`` (``ssh-keygen -Y sign``) over the exact payload bytes, in the namespace
:data:`NAMESPACE`. OpenSSH does the cryptography on both sides — it ships with
Windows 10/11 (``System32\\OpenSSH``) and with every HugMesh image — so the Studio
gains no crypto dependency and never implements a signature scheme itself.

WHAT THE TRAY ENFORCES with a verified token (:class:`GrantedMeshNode`):

* the token is re-verified at EVERY start: signature, a trusted issuer, not expired.
  A token whose issuer the operator has not trusted, or that has expired, refuses
  to start the node with a sentence saying which — it never falls back to an
  ambient ``TS_AUTHKEY``;
* ACCESS DOMAIN: the node joins ONLY the control plane inside the token's domain
  (the login server's host must be the domain or a name under it, checked at
  issue AND at verify), and its tailnet hostname carries the domain's first label;
* ROLE: only :data:`SHELL_ROLES` can hold shell access — the issuer refuses to sign
  shell for any other role and the verifier refuses a token that claims it;
* SHELL ACCESS: the node's Tailscale SSH server is switched on (``--ssh``) only when
  the token grants shell, and switched OFF explicitly (``--ssh=false``) otherwise,
  so a node that once ran with shell does not keep it from its saved state;
* the ``tailscale up`` arguments come from the token ALONE: an ambient
  ``TS_EXTRA_ARGS`` / ``HUGMESH_NODE_NAME`` cannot widen what the token grants.

WHAT IT CANNOT ENFORCE, said plainly: the person holding a token holds a real
pre-auth key and controls their own machine, so they could run ``tailscale`` by hand
with it. The authoritative gates stay SERVER-side — the pre-auth key's tags and the
headscale policy (``specs/usr/sbin/gen-headscale-policy.sh``: server-forced
``tag:dom_*`` tags, default-deny ``ssh[]``). The issuer CLI says so when it signs.
The token makes the tray do exactly what was granted and stops an edited token
(``"shell": true`` pasted in) from being honoured.

Resource limits (tray -> Resource limits) apply to a token-run node exactly as to any
other: :class:`GrantedMeshNode` inherits MeshNode's limits overlay.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import dataclasses
import hashlib
import json
import os
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit

from . import proc_text
from .config import PERSON_ROLE_CHOICES
from .mesh_node import MeshNode
from .state_paths import state_dir

FORMAT = "hugmesh-token-v1"

#: The SSHSIG namespace. A signature made for any other purpose (git commits, files)
#: with the same key does not verify as a token.
NAMESPACE = "hugmesh-mesh-token@hugmesh.org"

#: The roles a token can carry — the same four tiers as everywhere else in HugMesh.
ROLES = tuple(PERSON_ROLE_CHOICES)

#: The roles that may hold shell access. Matches the mesh's own SSH policy, where
#: shell on mesh nodes is an admin-plane right.
SHELL_ROLES = ("admin", "superadmin")

#: The longest a token may live. A shared token is a pre-auth key in transit.
MAX_LIFETIME_S = 90 * 24 * 3600

#: Clock skew tolerated on ``issued`` (the issuer's clock may run ahead).
_SKEW_S = 300

#: No real token was issued before this (2020-01-01 UTC).
_EARLIEST = 1577836800

_DOMAIN_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$")
_MESH_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
_ISSUER_RE = re.compile(r"^ssh-ed25519 [A-Za-z0-9+/]+={0,2}$")

TOKEN_FILE = "mesh-token"
ISSUERS_FILE = "mesh-token-issuers"
#: Beside the staged compose project: which credentials the node was started with.
IDENTITY_FILE = "mesh-identity.json"

ENV_EXTRA_ARGS = "TS_EXTRA_ARGS"
ENV_NODE_NAME = "HUGMESH_NODE_NAME"


class TokenError(ValueError):
    """A token that cannot be used. ``kind`` is one of ``malformed``, ``signature``,
    ``untrusted``, ``expired``, ``invalid``, ``tool``; ``str()`` is the sentence the
    tray shows."""

    def __init__(self, kind: str, message: str, *, issuer: str = ""):
        super().__init__(message)
        self.kind = kind
        self.issuer = issuer


@dataclasses.dataclass(frozen=True)
class MeshGrant:
    """What a token grants. ``auth_key`` is secret and never printed (see
    :meth:`describe`)."""
    mesh: str
    domain: str
    role: str
    shell: bool
    login_server: str
    auth_key: str
    expires: int
    issued: int
    issuer: str
    node_name: str = ""
    id: str = ""

    def describe(self) -> str:
        """One line for menus and the CLI — never the auth key."""
        shell = "shell access" if self.shell else "no shell access"
        return (f"{self.role} in {self.domain} (mesh {self.mesh}), {shell}, "
                f"expires {_when(self.expires)}")

    def short(self) -> str:
        """The few words the tray's status line has room for."""
        return f"{self.role} in {self.domain}, {'shell' if self.shell else 'no shell'}"

    def identity(self) -> str:
        """What the node's tailnet identity was created from. Two grants with the same
        identity can share the saved tailscale state; any other change (new key, role,
        domain, server, issuer) needs a fresh registration."""
        parts = (_issuer_key(self.issuer), self.mesh, self.domain, self.role,
                 self.login_server, self.id, self.auth_key)
        return "token:" + hashlib.sha256("\0".join(parts).encode()).hexdigest()[:24]

    def hostname(self, host: str | None = None) -> str:
        """The tailnet hostname: the token's node name, else this machine's name,
        with the access domain's first label appended. Lowercase ``[a-z0-9-]``,
        at most 63 characters (a DNS label), never starting or ending with ``-``."""
        suffix = "-" + (_label(self.domain.split(".", 1)[0])[:20].strip("-") or "mesh")
        base = _label(self.node_name or host or socket.gethostname()) or "hugmesh-node"
        return base[:63 - len(suffix)].strip("-") + suffix

    def extra_args(self) -> str:
        """The ``tailscale up`` arguments for this grant, and nothing else."""
        args = [f"--login-server={self.login_server}", "--accept-routes",
                "--ssh" if self.shell else "--ssh=false"]
        return " ".join(args)


def _when(ts: int) -> str:
    """A local date for a token time. A signed but absurd time (negative, far future)
    must not crash: Windows' localtime() raises OSError for anything before 1970."""
    try:
        return time.strftime("%Y-%m-%d %H:%M", time.localtime(ts))
    except (OSError, OverflowError, ValueError):
        return f"{ts} (Unix time)"


def _label(text: str) -> str:
    return re.sub(r"-{2,}", "-", re.sub(r"[^a-z0-9-]", "-", text.lower())).strip("-")


def _b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def _unb64u(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def _canonical(payload: dict) -> bytes:
    return json.dumps(payload, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=True).encode("ascii")


def fingerprint(issuer: str) -> str:
    """``SHA256:…`` exactly as ``ssh-keygen -lf`` prints it for this public key."""
    try:
        blob = base64.b64decode(issuer.split()[1], validate=True)
    except (IndexError, binascii.Error):
        return "(unreadable key)"
    return "SHA256:" + base64.b64encode(hashlib.sha256(blob).digest()).decode().rstrip("=")


def _issuer_key(issuer: str) -> str:
    """``type base64`` without a comment — what trust is keyed on."""
    return " ".join(issuer.split()[:2])


# ── field checks shared by issue and verify ──────────────────────────────────────────
def check_fields(g: MeshGrant, *, now: float | None = None) -> None:
    """Raise :class:`TokenError` (``invalid`` / ``expired``) unless every field of the
    grant is one this Studio will act on."""
    now = time.time() if now is None else now
    if not _MESH_RE.match(g.mesh):
        raise TokenError("invalid", f"The token's mesh name {g.mesh!r} is not a valid name.")
    if not _DOMAIN_RE.match(g.domain):
        raise TokenError("invalid", f"The token's access domain {g.domain!r} is not a domain name.")
    if g.role not in ROLES:
        raise TokenError("invalid", f"The token's role {g.role!r} is not one of "
                                    f"{', '.join(ROLES)}.")
    if g.shell and g.role not in SHELL_ROLES:
        raise TokenError("invalid", f"The token grants shell access to the role "
                                    f"{g.role!r}; only {' and '.join(SHELL_ROLES)} can "
                                    f"hold shell access, so it is refused.")
    # The URL lands in TS_EXTRA_ARGS, which the tailscale container word-splits: any
    # whitespace (or a path carrying it) would smuggle extra `tailscale up` flags in.
    if not re.fullmatch(r"https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?", g.login_server):
        raise TokenError("invalid", f"The token's login server {g.login_server!r} must be "
                                    f"an https:// URL with only a host and optional port.")
    parts = urlsplit(g.login_server)
    host = (parts.hostname or "").lower()
    if not host:
        raise TokenError("invalid", f"The token's login server {g.login_server!r} must be "
                                    f"an https:// URL.")
    if host != g.domain and not host.endswith("." + g.domain):
        raise TokenError("invalid", f"The token's login server {host} is outside its access "
                                    f"domain {g.domain}, so the node would join another "
                                    f"domain's control plane. It is refused.")
    if not g.auth_key or any(c.isspace() for c in g.auth_key):
        raise TokenError("invalid", "The token carries no usable pre-auth key.")
    if not _ISSUER_RE.match(_issuer_key(g.issuer)):
        raise TokenError("invalid", "The token's issuer is not an ssh-ed25519 public key.")
    if g.issued < _EARLIEST:
        raise TokenError("invalid", "The token's issue time is before 2020, so it is not a "
                                    "real token.")
    if g.expires - g.issued > MAX_LIFETIME_S or g.expires <= g.issued:
        raise TokenError("invalid", "The token's lifetime is not between a moment and "
                                    f"{MAX_LIFETIME_S // 86400} days.")
    if g.issued > now + _SKEW_S:
        raise TokenError("invalid", "The token was issued in the future; check this "
                                    "computer's clock.")
    if now >= g.expires:
        raise TokenError("expired", f"The HugMesh token expired at {_when(g.expires)}. Ask "
                                    f"its issuer for a new one.")
    if g.node_name and not _label(g.node_name):
        raise TokenError("invalid", f"The token's node name {g.node_name!r} is not usable.")


# ── OpenSSH (ssh-keygen -Y) ───────────────────────────────────────────────────────────
def ssh_keygen(osname: str | None = None) -> str:
    """The ssh-keygen to sign/verify with, or raise ``tool``."""
    found = shutil.which("ssh-keygen")
    if not found and (osname or os.name) == "nt":
        root = os.environ.get("SystemRoot", r"C:\Windows")
        candidate = os.path.join(root, "System32", "OpenSSH", "ssh-keygen.exe")
        if os.path.isfile(candidate):
            found = candidate
    if not found:
        raise TokenError("tool", "Checking a HugMesh token needs OpenSSH's ssh-keygen, which "
                                 "was not found. On Windows, add the optional feature "
                                 "\"OpenSSH Client\" (Settings > System > Optional features).")
    return found


def _run(argv: list[str], *, stdin: bytes | None = None, cwd: str | None = None):
    return subprocess.run(argv, input=stdin, capture_output=True, cwd=cwd, timeout=30)


def _payload(g: MeshGrant) -> dict:
    return {"format": FORMAT, **dataclasses.asdict(g)}


def issue(*, key_path: str, mesh: str, domain: str, role: str, shell: bool,
          login_server: str, auth_key: str, lifetime_s: int, node_name: str = "",
          now: float | None = None, keygen: str | None = None) -> str:
    """Sign a token with the issuer's ed25519 SSH key (its ``.pub`` must sit beside
    it). ssh-keygen may prompt for the key's passphrase on the terminal."""
    now = int(time.time() if now is None else now)
    pub_path = key_path + ".pub"
    try:
        with open(pub_path, encoding="utf-8") as fh:
            issuer = _issuer_key(fh.read().strip())
    except OSError as e:
        raise TokenError("tool", f"Could not read the issuer's public key {pub_path}: {e}")
    g = MeshGrant(mesh=mesh, domain=domain.lower().strip("."), role=role, shell=bool(shell),
                  login_server=login_server.rstrip("/"), auth_key=auth_key.strip(),
                  expires=now + int(lifetime_s), issued=now, issuer=issuer,
                  node_name=node_name, id=secrets.token_hex(8))
    check_fields(g, now=now)
    body = _canonical(_payload(g))
    keygen = keygen or ssh_keygen()
    with tempfile.TemporaryDirectory(prefix="hugmesh-token-") as tmp:
        data = os.path.join(tmp, "payload")
        with open(data, "wb") as fh:
            fh.write(body)
        # Not captured: ssh-keygen asks for a passphrase on the terminal when the key
        # has one, and a captured run would hang on that prompt.
        r = subprocess.run([keygen, "-Y", "sign", "-f", key_path, "-n", NAMESPACE, data],
                           timeout=300)
        if r.returncode != 0:
            raise TokenError("signature", "ssh-keygen could not sign the token (see its "
                                          "message above).")
        with open(data + ".sig", "rb") as fh:
            sig = fh.read()
    return f"{FORMAT}.{_b64u(body)}.{_b64u(sig)}"


def parse(token: str) -> tuple[MeshGrant, bytes, bytes]:
    """Split a token into (grant, payload bytes, signature bytes). No trust decided."""
    text = "".join(token.split())
    parts = text.split(".")
    if len(parts) != 3 or parts[0] != FORMAT:
        raise TokenError("malformed", "This is not a HugMesh token (it should start with "
                                      f"\"{FORMAT}.\").")
    try:
        body, sig = _unb64u(parts[1]), _unb64u(parts[2])
        data = json.loads(body.decode("ascii"))
    except (binascii.Error, ValueError, UnicodeDecodeError):
        raise TokenError("malformed", "The HugMesh token is damaged (it may have been cut "
                                      "off when it was copied).") from None
    if not isinstance(data, dict) or data.pop("format", None) != FORMAT:
        raise TokenError("malformed", "The HugMesh token's contents are not version 1.")
    fields = {f.name: f for f in dataclasses.fields(MeshGrant)}
    if set(data) - set(fields) or any(
            f.default is dataclasses.MISSING and n not in data for n, f in fields.items()):
        raise TokenError("malformed", "The HugMesh token has missing or unknown fields.")
    types = {"shell": bool, "expires": int, "issued": int}
    for name, value in data.items():
        want = types.get(name, str)
        if not isinstance(value, want) or (want is int and isinstance(value, bool)):
            raise TokenError("malformed", f"The HugMesh token's {name!r} has the wrong type.")
    if _canonical({"format": FORMAT, **data}) != body:
        raise TokenError("malformed", "The HugMesh token's contents are not in canonical "
                                      "form, so they cannot be the signed bytes.")
    return MeshGrant(**data), body, sig


def verify(token: str, *, trusted: set[str] | None = None, now: float | None = None,
           keygen: str | None = None) -> MeshGrant:
    """The grant of a token whose signature checks out against its issuer key, whose
    issuer is trusted, and whose fields are acceptable — else :class:`TokenError`."""
    g, body, sig = parse(token)
    issuer = _issuer_key(g.issuer)
    if not _ISSUER_RE.match(issuer):
        raise TokenError("invalid", "The token's issuer is not an ssh-ed25519 public key.")
    digest = hashlib.sha256(body + b"\0" + sig).digest()
    if digest not in _GOOD_SIGNATURES:
        _check_signature(body, sig, issuer, keygen or ssh_keygen())
        _GOOD_SIGNATURES.add(digest)
    check_fields(g, now=now)
    trusted = trusted_issuers() if trusted is None else trusted
    if issuer not in trusted:
        raise TokenError("untrusted", "The HugMesh token is signed by an issuer this "
                                      f"computer does not trust yet ({fingerprint(issuer)}). "
                                      "Compare that fingerprint with the one the issuer "
                                      "gave you, then trust it.", issuer=issuer)
    return g


#: sha256(payload, signature) of signatures ssh-keygen has already accepted. One
#: ssh-keygen run takes seconds on some Windows hosts (antivirus scans each start), and
#: the tray asks on every menu refresh. Only the SIGNATURE result is remembered: the
#: fields, the expiry and the trusted-issuer list are checked again on every call, and
#: the signed issuer key is part of the hashed payload.
_GOOD_SIGNATURES: set[bytes] = set()


def _check_signature(body: bytes, sig: bytes, issuer: str, keygen: str) -> None:
    with tempfile.TemporaryDirectory(prefix="hugmesh-token-") as tmp:
        signers = os.path.join(tmp, "allowed_signers")
        sigfile = os.path.join(tmp, "payload.sig")
        with open(signers, "w", encoding="ascii", newline="\n") as fh:
            fh.write(f'issuer namespaces="{NAMESPACE}" {issuer}\n')
        with open(sigfile, "wb") as fh:
            fh.write(sig)
        r = _run([keygen, "-Y", "verify", "-f", signers, "-I", "issuer", "-n", NAMESPACE,
                  "-s", sigfile], stdin=body, cwd=tmp)
    if r.returncode != 0:
        raise TokenError("signature", "The HugMesh token's signature does not match its "
                                      "contents: it was changed after it was signed, or "
                                      "it is not a real token.")


# ── on-disk state: trusted issuers + the imported token ─────────────────────────────
def _path(name: str) -> str:
    return os.path.join(state_dir(), name)


def _write_private(path: str, text: str) -> None:
    """Write a file only this user can read (0600 on POSIX; the per-user state dir's
    ACL on Windows)."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    os.replace(tmp, path)


def trusted_issuers() -> set[str]:
    try:
        with open(_path(ISSUERS_FILE), encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return set()
    return {_issuer_key(s) for s in lines if s.strip() and not s.lstrip().startswith("#")}


def trust_issuer(issuer: str) -> str:
    """Add an issuer public key to the trusted set; returns its fingerprint."""
    key = _issuer_key(issuer.strip())
    if not _ISSUER_RE.match(key):
        raise TokenError("invalid", "Only ssh-ed25519 public keys can be trusted as issuers.")
    keys = trusted_issuers() | {key}
    _write_private(_path(ISSUERS_FILE), "".join(f"{k}\n" for k in sorted(keys)))
    return fingerprint(key)


def distrust_issuer(issuer: str) -> None:
    keys = trusted_issuers() - {_issuer_key(issuer)}
    _write_private(_path(ISSUERS_FILE), "".join(f"{k}\n" for k in sorted(keys)))


def save_token(token: str) -> MeshGrant:
    """Verify, then keep the token for the tray. Nothing is kept if it fails."""
    g = verify(token)
    _write_private(_path(TOKEN_FILE), "".join(token.split()) + "\n")
    return g


def stored_token() -> str:
    try:
        with open(_path(TOKEN_FILE), encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def forget_token() -> None:
    try:
        os.remove(_path(TOKEN_FILE))
    except FileNotFoundError:
        pass


def load_grant() -> MeshGrant | None:
    """The stored token's grant, re-verified now; ``None`` when no token is stored.
    A stored token that no longer verifies raises :class:`TokenError`."""
    token = stored_token()
    return verify(token) if token else None


def import_token(text: str, confirm_trust) -> tuple[MeshGrant | None, str]:
    """Verify and keep ``text`` (the tray dialog's Import). ``confirm_trust(fingerprint)
    -> bool`` is asked only when the issuer is unknown. Returns (grant, "") or (None,
    the reason). Never raises, so a Qt slot can call it directly."""
    try:
        try:
            return save_token(text), ""
        except TokenError as e:
            if e.kind != "untrusted":
                return None, str(e)
            if not confirm_trust(fingerprint(e.issuer)):
                return None, "Not imported: the issuer was not trusted."
            trust_issuer(e.issuer)
        return save_token(text), ""
    except TokenError as e:
        return None, str(e)
    except Exception as e:
        return None, f"The token could not be imported: {e}"


def summary() -> str:
    """What the tray runs a mesh node under now, as one sentence."""
    if not stored_token():
        return "No HugMesh token imported. The mesh node uses TS_AUTHKEY, if it is set."
    try:
        g = load_grant()
    except Exception as e:
        return f"The imported token cannot be used: {e}"
    return f"Imported: {g.describe()}. Issuer {fingerprint(g.issuer)}."


# ── the tray's mesh node ─────────────────────────────────────────────────────────────
class GrantedMeshNode(MeshNode):
    """The tray's mesh node. With an imported token it runs ONLY as the token allows
    (see the module docstring); with none it is the plain MeshNode on ``TS_AUTHKEY``.
    """

    def __init__(self, generator_dir: str, workdir: str | None = None, *, load=None):
        super().__init__(generator_dir, workdir)
        self._load = load or load_grant
        self._active: MeshGrant | None = None

    def grant(self) -> tuple[MeshGrant | None, str]:
        """(grant, "") for a usable stored token, (None, "") for none, (None, why).
        Never raises: the tray asks this while it builds its menu."""
        try:
            return self._load(), ""
        except TokenError as e:
            return None, str(e)
        except Exception as e:           # a broken state dir must not take the tray down
            return None, f"The stored HugMesh token could not be read: {e}"

    # ── which credentials the node's tailnet identity came from ──────────────────
    # The tailscale container keeps its registration in the compose volume `tsstate`,
    # and a registered node ignores a NEW auth key (and refuses a new --login-server)
    # on the next `tailscale up`. So the credentials a node was started with are
    # recorded beside it, and starting with different ones drops that state first.
    def _identity_path(self) -> str:
        return os.path.join(self.workdir, IDENTITY_FILE)

    def _identity(self, g: MeshGrant | None) -> str:
        if g is not None:
            return g.identity()
        key = MeshNode._authkey(self)
        return "ts_authkey:" + hashlib.sha256(key.encode()).hexdigest()[:24] if key else ""

    def recorded(self) -> dict:
        """{"identity", "summary"} the running/last node was started with, or {}."""
        try:
            with open(self._identity_path(), encoding="utf-8") as fh:
                data = json.load(fh)
            return data if isinstance(data, dict) and data.get("identity") else {}
        except (OSError, ValueError):
            return {}

    def _record(self, g: MeshGrant | None) -> None:
        _write_private(self._identity_path(), json.dumps({
            "identity": self._identity(g),
            "summary": g.short() if g else "TS_AUTHKEY",
            "token": g is not None}))

    def _reset_state(self) -> tuple[bool, str]:
        """`compose down -v` on this node's own project: removes its container and
        its tsstate volume, so the next `up` registers afresh."""
        if not os.path.exists(os.path.join(self.workdir, "docker-compose.mesh.yml")):
            return True, ""
        try:
            r = subprocess.run(self._compose("down", "-v"), cwd=self.workdir, env=self._env(),
                               capture_output=True, text=True, **proc_text.TEXT_IO, timeout=300)
            return r.returncode == 0, (r.stderr or r.stdout).strip()
        except (OSError, subprocess.SubprocessError) as e:
            return False, str(e)

    def start(self) -> tuple[bool, str]:
        g, why = self.grant()
        if why:
            return False, why
        if g is None and not super()._authkey():
            return False, ("Import a HugMesh token first (tray menu > HugMesh token…), "
                           "or set TS_AUTHKEY to a tailnet/headscale auth key.")
        had = self.recorded().get("identity")
        staged = os.path.exists(os.path.join(self.workdir, "docker-compose.mesh.yml"))
        # Different credentials than the saved state was made with (or a token run
        # over state of unknown origin): register afresh, or the old grant stays.
        if staged and (had != self._identity(g) if had else g is not None):
            ok, out = self._reset_state()
            if not ok:
                return False, f"Could not clear the node's previous tailnet identity: {out}"
        self._active = g
        try:
            ok, out = super().start()
        finally:
            self._active = None
        if ok:
            self._record(g)
        return ok, out

    def apply_limits(self) -> tuple[bool, str]:
        """Re-apply the Resource limits to a RUNNING node now (compose recreates the
        container with the rewritten overlay). A stopped node picks them up at its
        next start, so there is nothing to do. A node started under OTHER credentials
        than the tray holds now is not restarted behind the operator's back."""
        if not self.status().running:
            return True, "not running"
        g, why = self.grant()
        if why or self.recorded().get("identity") != self._identity(g):
            return False, ("it was started under other credentials than the tray holds "
                           "now; stop and start it to apply the limits and the token")
        return self.start()

    def tray_note(self, running: bool) -> tuple[str, str]:
        """(status-line suffix, tooltip). A running node shows what it was STARTED
        with, and says when the stored token differs; a stopped one shows the stored
        token (or why it cannot be used)."""
        g, why = self.grant()
        rec = self.recorded() if running else {}
        if rec:
            suffix = f" — {rec.get('summary', '')}"
            if why or rec.get("identity") != self._identity(g):
                return (suffix + " (restart to apply the current token)",
                        why or "The tray holds other credentials than this node was "
                               "started with. Stop and start it to apply them.")
            return suffix, ""
        if why:
            return " — token unusable (hover for why)", why
        return (f" — {g.short()}", "") if g else ("", "")

    def enforce(self) -> str:
        """Stop a RUNNING node that was started under a token which has since been
        forgotten, expired or lost its issuer's trust. Docker's restart policy can
        bring such a node back (after a reboot) without the tray's start-time check,
        so the tray calls this whenever it refreshes. Returns what it did, or ""."""
        rec = self.recorded()
        if not rec.get("token"):
            return ""
        g, why = self.grant()
        if g is not None or not self.status().running:
            return ""
        ok, out = self.stop()
        reason = why or "The HugMesh token it was started with has been forgotten."
        return (f"Stopped the mesh node: {reason}" if ok
                else f"The mesh node should stop ({reason}) but stopping failed: {out}")

    def _authkey(self) -> str:
        if self._active is not None:
            return self._active.auth_key
        return super()._authkey()

    def _env(self) -> dict:
        env = super()._env()
        if self._active is not None:
            # The process env wins over the staged .env in compose interpolation, so
            # setting both here is what stops an ambient TS_EXTRA_ARGS from widening
            # the grant (adding --ssh, another --login-server, …).
            env[ENV_EXTRA_ARGS] = self._active.extra_args()
            env[ENV_NODE_NAME] = self._active.hostname()
        return env


# ── CLI: issue / show / trust ────────────────────────────────────────────────────────
_UNITS = {"m": 60, "h": 3600, "d": 86400}


def _lifetime(text: str) -> int:
    m = re.fullmatch(r"(\d+)([mhd])", text.strip())
    if not m:
        raise argparse.ArgumentTypeError("use a number and m, h or d, e.g. 7d")
    return int(m.group(1)) * _UNITS[m.group(2)]


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="python -m hugmesh_studio.core.mesh_token",
        description="Issue, inspect and trust signed HugMesh tokens.")
    sub = p.add_subparsers(dest="cmd", required=True)
    i = sub.add_parser("issue", help="sign a token with your ssh-ed25519 issuer key")
    i.add_argument("--key", required=True, help="the issuer's private ssh-ed25519 key "
                   "(its .pub must be beside it)")
    i.add_argument("--mesh", required=True)
    i.add_argument("--domain", required=True, help="the access domain")
    i.add_argument("--role", required=True, choices=ROLES)
    i.add_argument("--shell", action="store_true", help=f"grant shell access "
                   f"({' or '.join(SHELL_ROLES)} only)")
    i.add_argument("--login-server", required=True, help="https:// headscale URL inside "
                   "the domain")
    i.add_argument("--authkey-file", required=True, help="file holding the pre-auth key "
                   "(kept off the command line)")
    i.add_argument("--node-name", default="")
    i.add_argument("--expires", type=_lifetime, default=_lifetime("7d"),
                   help="lifetime such as 12h or 7d (default 7d, at most 90d)")
    s = sub.add_parser("show", help="verify a token and print what it grants")
    s.add_argument("token_file", help="file holding the token ('-' for stdin)")
    t = sub.add_parser("trust", help="trust an issuer's ssh-ed25519 public key")
    t.add_argument("pubkey_file")
    args = p.parse_args(argv)
    try:
        if args.cmd == "issue":
            with open(args.authkey_file, encoding="utf-8") as fh:
                auth_key = fh.read().strip()
            token = issue(key_path=args.key, mesh=args.mesh, domain=args.domain,
                          role=args.role, shell=args.shell, login_server=args.login_server,
                          auth_key=auth_key, lifetime_s=args.expires,
                          node_name=args.node_name)
            print(token)
            g, _, _ = parse(token)
            print(f"\nGrants: {g.describe()}\nIssuer: {fingerprint(g.issuer)} (give the "
                  f"recipient this fingerprint separately)\n"
                  f"The server still decides: create the pre-auth key with the tags for "
                  f"{g.domain} and {g.role}, and keep shell in the headscale ssh policy "
                  f"to match.", file=sys.stderr)
            return 0
        if args.cmd == "show":
            text = (sys.stdin.read() if args.token_file == "-"
                    else open(args.token_file, encoding="utf-8").read())
            g = verify(text)
            print(f"{g.describe()}\nissuer {fingerprint(g.issuer)}\n"
                  f"tailscale up {g.extra_args()} --hostname={g.hostname()}")
            return 0
        with open(args.pubkey_file, encoding="utf-8") as fh:
            print(f"trusted {trust_issuer(fh.read())}")
        return 0
    except (TokenError, OSError) as e:
        print(f"mesh-token: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

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
  issue AND at verify), and its tailnet hostname carries the domain's first label.
  The one exception is a Tor v3 onion login server (:func:`login_server_problem`):
  an onion has no place in DNS, so it cannot sit under the domain, and the issuer's
  signature over it is what binds it to the token;
* ROLE: only :data:`SHELL_ROLES` can hold shell access — the issuer refuses to sign
  shell for any other role and the verifier refuses a token that claims it;
* SHELL ACCESS: the node's Tailscale SSH server is switched on (``--ssh``) only when
  the token grants shell, and switched OFF explicitly (``--ssh=false``) otherwise,
  so a node that once ran with shell does not keep it from its saved state;
* the ``tailscale up`` arguments come from the token ALONE: an ambient
  ``TS_EXTRA_ARGS`` / ``HUGMESH_NODE_NAME`` cannot widen what the token grants.

WHAT IT CANNOT ENFORCE, said plainly: the person holding a token holds a real
pre-auth key and controls their own machine, so they could run ``tailscale`` by hand
with it. Role and domain are labels; the mesh decides what this node may do. The
pre-auth key only lets it join. The authoritative gates stay SERVER-side, in the
mesh's headscale policy (``specs/usr/sbin/gen-headscale-policy.sh``, with its
default-deny ``ssh[]``). The issuer CLI says so when it signs. The token makes the
tray do exactly what was granted and stops an edited token (``"shell": true`` pasted
in) from being honoured.

Resource limits (tray -> Resource limits) apply to a token-run node exactly as to any
other: :class:`GrantedMeshNode` inherits MeshNode's limits overlay.

ISSUING (OPERATOR ASK 2026-11-04: "make sure locally created mesh can also generate
tokens through both the web ui and the gui/tui/cli on all platforms"). The admin of a
mesh created with the Studio needs no SSH key of their own: :func:`ensure_issuer`
keeps one ``ssh-ed25519`` issuer key per mesh in the Studio state dir (created on
first use, trusted by this computer's own tray), and :func:`mint_preauth_key` asks
the mesh's running headscale container for a single-use pre-auth key. The headscale
user defaults to the one the container's ``net.hugmesh.headscale.user`` label names,
else the membership user ``hugmesh``, which owns no access tag (see
:func:`headscale_labels`); the admin may name another. The minted key is read from
headscale's output, never put on a command line or in a log; the one exception is
expiring a minted key that could not be put in a token (:func:`expire_preauth_key`
says how briefly it is visible). Minting needs a running headscale container, such as
the one the Studio's local Docker mesh runs; without one a pre-auth key is pasted or
read from a file.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import dataclasses
import functools
import getpass
import hashlib
import json
import os
import re
import secrets
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlsplit

from . import proc_text
from .config import PERSON_ROLE_CHOICES
from .mesh_node import IDENTITY_FILE, MeshNode
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

ENV_EXTRA_ARGS = "TS_EXTRA_ARGS"
ENV_NODE_NAME = "HUGMESH_NODE_NAME"


class TokenError(ValueError):
    """A token that cannot be used. ``kind`` is one of ``malformed``, ``signature``,
    ``untrusted``, ``expired``, ``invalid``, ``tool``; ``str()`` is the sentence the
    tray shows. ``choices``: the candidates when one must be named (several headscale
    containers)."""

    def __init__(self, kind: str, message: str, *, issuer: str = "",
                 choices: tuple[str, ...] = ()):
        super().__init__(message)
        self.kind = kind
        self.issuer = issuer
        self.choices = tuple(choices)


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
        shell = ("accepts SSH from the mesh" if self.shell
                 else "accepts no SSH from the mesh")
        return (f"{self.role} in {self.domain} (mesh {self.mesh}), {shell}, "
                f"expires {_when(self.expires)}")

    def short(self) -> str:
        """The few words the tray's status line has room for."""
        return f"{self.role} in {self.domain}, {'SSH in' if self.shell else 'no SSH in'}"

    def identity(self) -> str:
        """What the node's tailnet identity was created from. Two grants with the same
        identity can share the saved tailscale state; any other change (new key, role,
        domain, server, issuer) needs a fresh registration."""
        parts = (_issuer_key(self.issuer), self.mesh, self.domain, self.role,
                 self.login_server, self.id, self.auth_key)
        return "token:" + secret_digest("\0".join(parts))

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


#: A random per-install salt for :func:`secret_digest`, in the Studio state dir.
SALT_FILE = "mesh-identity-salt"
#: Beside a damaged salt file: the salt that replaces it (:func:`_load_or_create_salt`).
SALT_REPAIRED = ".repaired"


def secret_digest(secret: str) -> str:
    """A short comparable digest of a value that contains a pre-auth key, for the
    identity record beside the node. Never a fast plain hash of the secret: PBKDF2 with
    a per-install random salt, so the record (which only has to tell "same credentials"
    from "different credentials" on this computer) gives nothing to brute-force with.

    A digest compares only with one made under the SAME salt: the record beside the
    node carries :func:`salt_id`, and a record made under another salt is "cannot
    tell", never "different" (``GrantedMeshNode._compare``)."""
    return _pbkdf2(secret, _salt())


#: The salt each state dir's salt file held (or, unwritable, was drawn) the first time
#: this process asked: drawn or loaded ONCE per process, so every digest this process
#: makes compares with every other, even when the file cannot be written or is
#: deleted while the tray runs.
_SALTS: dict[str, bytes] = {}
_SALT_LOCK = threading.Lock()


def _salt() -> bytes:
    path = os.path.join(state_dir(), SALT_FILE)
    with _SALT_LOCK:
        salt = _SALTS.get(path)
        if salt is None:
            salt = _SALTS[path] = _load_or_create_salt(path)
        return salt


def salt_id() -> str:
    """A short public name for this process's salt, kept in the identity record so a
    record made under another salt is recognised as such. A hash of the salt alone
    (random bytes, no secret in it), in its own domain."""
    return hashlib.sha256(b"hugmesh-identity-salt\0" + _salt()).hexdigest()[:12]


def _read_salt(path: str) -> bytes:
    try:
        with open(path, encoding="ascii") as fh:
            salt = bytes.fromhex(fh.read().strip())
    except (OSError, ValueError):
        return b""
    return salt if len(salt) >= 16 else b""


def _load_or_create_salt(path: str, *, retries: int = 20, repair: bool = True) -> bytes:
    """The salt in ``path``, else a new one written there. The file is CREATED
    EXCLUSIVELY and with its content at once (:func:`_create_salt_file`), so two
    processes racing to create it cannot both win: the loser re-reads the file and
    takes the winner's salt. A damaged file is left as it is and the salt goes in a
    replacement file beside it (``SALT_REPAIRED``), created the same way, so that
    path has one winner too. An unwritable state dir keeps the new salt for this
    process only."""
    salt = _read_salt(path)
    if salt:
        return salt
    repaired = path + SALT_REPAIRED
    if repair:
        salt = _read_salt(repaired)     # an earlier process found the file damaged
        if salt:
            return salt
    new = secrets.token_bytes(32)
    try:
        _makedirs_private(os.path.dirname(path))
    except OSError:
        return new                # an unwritable state dir: this process's salt only
    made = _create_salt_file(path, new)
    if made is None:
        return new                # an unwritable state dir: this process's salt only
    if not made:
        # Another process is creating it (or made it a moment ago): take its salt.
        salt = _await_salt(path, retries)
        if salt:
            return salt
        # Still no salt in it: a damaged file, not a race. Replacing it in place could
        # not be left to exactly one process, so the salt goes beside it instead.
        if not repair:
            return new
        return _load_or_create_salt(repaired, retries=retries, repair=False)
    # Ours: read back, so what this process uses is what the file holds.
    return _await_salt(path, retries) or new


def _await_salt(path: str, retries: int) -> bytes:
    """The salt in ``path``, looking again briefly while it is absent or empty."""
    for _ in range(max(1, retries)):
        salt = _read_salt(path)
        if salt:
            return salt
        time.sleep(0.05)
    return b""


def _create_salt_file(path: str, salt: bytes) -> bool | None:
    """Create ``path`` holding ``salt`` unless a file is already there: written in full
    to a private temporary file beside it, then hard-linked into place (a link never
    replaces a file), so no process ever sees it empty or half written. True when it
    was created, False when a file was there already, None when it cannot be made.
    Where hard links are not supported it is created exclusively and then written."""
    text = (salt.hex() + "\n").encode("ascii")
    try:
        fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".", suffix=".tmp",
                                   dir=os.path.dirname(path))
    except OSError:
        return None
    try:
        try:
            os.write(fd, text)
        finally:
            os.close(fd)
        os.link(tmp, path)
        return True
    except FileExistsError:
        return False
    except OSError:
        pass                      # no hard links here (or the write failed): see below
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0),
                     0o600)
    except FileExistsError:
        return False
    except OSError:
        return None
    try:
        try:
            os.write(fd, text)
        finally:
            os.close(fd)
    except OSError:
        try:
            os.remove(path)       # no empty salt file left for the next process
        except OSError:
            pass
        return None
    return True


@functools.lru_cache(maxsize=16)
def _pbkdf2(secret: str, salt: bytes) -> str:
    # cached: the tray compares identities on every menu refresh
    return hashlib.pbkdf2_hmac("sha256", secret.encode(), salt, 100_000).hex()[:32]


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


# ── the login server: a host in the access domain, or a v3 onion ─────────────────────
#: How a login server is written, for the fields' placeholders, tooltips and help.
LOGIN_SERVER_FORMS = ("https://host[:port] inside the access domain, or a Tor v3 onion "
                      "http(s)://<56 characters>.onion[:port]")

#: A v3 onion for examples: made from a fixed made-up key (sha256 of "hugmesh example
#: onion login server"), so it passes the checksum but names no one's service.
ONION_EXAMPLE = "http://jhbnhua6kdvln3elglvmwjddbhqeobiunswe4xzu5xij2dlb2fwx6fad.onion"

#: Said next to an onion login server, by the CLI, the window and the text interface:
#: what the token cannot do on its own.
ONION_NOTE = ("An onion login server is reached over Tor: the joining computer's "
              "tailscale needs a route into Tor (the Studio's own mesh node does not set "
              "one up), and headscale must be published on that onion. The local Docker "
              "mesh's own .onion serves its web front door, not headscale.")

_DNS_LABEL_RE = re.compile(r"[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?")
_LOGIN_RE = re.compile(r"(https?)://([A-Za-z0-9.-]+)(?::([0-9]{1,5}))?/?")
_ONION_ALPHABET = frozenset("abcdefghijklmnopqrstuvwxyz234567")


def onion_problem(host: str) -> str:
    """Why ``host`` (ending in ``.onion``) is not a usable Tor v3 onion address, or "".
    A v3 address is 56 base32 characters encoding the service's ed25519 key, a
    two-byte checksum and the version byte 3 (Tor rend-spec-v3, "Encoding onion
    addresses"), so a mistyped character fails the checksum instead of naming some
    other service."""
    name = host.lower()[:-len(".onion")]
    if "." in name:
        # Names in front of the address (hs.<address>.onion) reach the same service:
        # Tor ignores them, and the service sees them in its Host header (which is how
        # the local mesh's front door picks headscale by its hs. name). Each must be a
        # DNS label; the address itself is the last one.
        front, _, name = name.rpartition(".")
        if not all(_DNS_LABEL_RE.fullmatch(p) for p in front.split(".")):
            return f"{host} has a name in front of the onion address that is not usable."
    bad = sorted(set(name) - _ONION_ALPHABET)
    if len(name) == 16 and not bad:
        return (f"{host} is a v2 onion address. Tor retired v2 onions in 2021; use the "
                f"service's v3 address (56 characters before .onion).")
    if len(name) != 56:
        return (f"{host} is not a Tor v3 onion address: it has {len(name)} characters "
                f"before .onion, and a v3 address has 56.")
    if bad:
        return (f"{host} is not a Tor v3 onion address: {''.join(bad)!r} is outside the "
                f"onion alphabet (the letters a-z and the digits 2-7).")
    raw = base64.b32decode(name.upper())
    key, checksum, version = raw[:32], raw[32:34], raw[34]
    if version != 3 or hashlib.sha3_256(
            b".onion checksum" + key + bytes([version])).digest()[:2] != checksum:
        return (f"{host} is not a Tor v3 onion address: its checksum does not match, so "
                f"a character is mistyped.")
    return ""


def is_onion_login(url: str) -> bool:
    """Whether ``url`` is a login server this module accepts AS an onion."""
    m = _LOGIN_RE.fullmatch(url or "")
    return bool(m) and m.group(2).lower().endswith(".onion") \
        and not onion_problem(m.group(2))


def login_server_problem(url: str, domain: str | None) -> str:
    """Why ``url`` cannot be a token's login server for the access ``domain``, or "".
    The one rule the issuer, the verifier and every face (window, text interface,
    command line) apply. ``domain=None`` checks the URL alone (a face asking while the
    access domain is still empty); the issuer and the verifier always pass it.

    * A host on the clear web: ``https://host[:port]`` with an optional trailing
      ``/``, host the access domain or a name under it (the node joins only its own
      domain's control plane).
    * A Tor v3 onion: ``http://`` or ``https://<56 characters>.onion[:port]``. Tor
      encrypts and authenticates the connection to the onion's own key, so ``http``
      is as private there as https is on the clear web; and an onion has no place in
      DNS, so it cannot sit "under" an access domain — the issuer's signature binds
      it to the token instead. Names in front of the address (``hs.<onion>.onion``)
      are allowed, as Tor allows them. A v2 address, a wrong length or alphabet or a
      mistyped character (the v3 checksum) is refused.

    Nothing else — no path, query or whitespace: the URL lands in ``TS_EXTRA_ARGS``,
    which the tailscale container word-splits, so whitespace (or a path carrying it)
    would smuggle extra ``tailscale up`` flags in."""
    what = f"The token's login server {url!r}"
    m = _LOGIN_RE.fullmatch(url or "")
    if not m:
        base = re.fullmatch(r"(https?://[A-Za-z0-9.-]+(?::[0-9]{1,5})?)(/[!-~]*)", url or "")
        drop = (f" Drop {base.group(2)!r}: use {base.group(1)}." if base
                and _LOGIN_RE.fullmatch(base.group(1)) else "")
        return (f"{what} must be {LOGIN_SERVER_FORMS}, with only a host and optional "
                f"port: no path, spaces or anything else.{drop}")
    scheme, host, port = m.group(1), m.group(2).lower(), m.group(3)
    if port is not None and not 0 < int(port) < 65536:
        return f"{what} names port {port}, which is not between 1 and 65535."
    if host.endswith(".onion"):
        why = onion_problem(host)
        return f"{what} is refused: {why}" if why else ""
    if scheme != "https":
        return (f"{what} must be an https:// URL with only a host and optional port "
                f"(plain http is accepted only for a Tor .onion, which Tor encrypts).")
    if domain is not None and host != domain and not host.endswith("." + domain):
        return (f"The token's login server {host} is outside its access domain {domain}, "
                f"so the node would join another domain's control plane. It is refused.")
    return ""


def login_server_hint(url: str, domain: str) -> str:
    """The line every face says under the login server as it is typed: why it is
    refused (:func:`login_server_problem`), else :data:`ONION_NOTE` for an onion, else
    "". The domain rule is left out while the access domain is still empty (issuing
    applies it all the same)."""
    url = (url or "").strip()
    if not url:
        return ""
    why = login_server_problem(url, (domain or "").strip() or None)
    if why:
        return why
    return ONION_NOTE if is_onion_login(url) else ""


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
    why = login_server_problem(g.login_server, g.domain)
    if why:
        raise TokenError("invalid", why)
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
    if found and not _supports_sshsig(found):
        raise TokenError("tool", f"This OpenSSH ({found}) is older than 8.0 and cannot sign "
                                 "or check HugMesh tokens (it has no `ssh-keygen -Y`). "
                                 "Update OpenSSH.")
    if not found:
        raise TokenError("tool", "Signing or checking a HugMesh token needs OpenSSH's "
                                 "ssh-keygen, which was not found. On Windows, add the "
                                 "optional feature \"OpenSSH Client\" (Settings > System > "
                                 "Optional features).")
    return found


_SSHSIG_SUPPORT: dict[str, bool] = {}


def _supports_sshsig(keygen: str) -> bool:
    """Does this ssh-keygen have ``-Y`` (OpenSSH 8.0+)? Asked once per binary. An old
    one rejects the option itself; a new one rejects only the made-up operation. Without
    this, a too-old OpenSSH made every token look forged ("signature does not match")."""
    if keygen not in _SSHSIG_SUPPORT:
        try:
            r = subprocess.run([keygen, "-Y", "hugmesh-probe"], capture_output=True,
                               timeout=30, **_no_window())
            text = (r.stderr + r.stdout).decode("utf-8", "replace").lower()
            _SSHSIG_SUPPORT[keygen] = not re.search(r"(illegal|unknown|invalid) option", text)
        except (OSError, subprocess.SubprocessError):
            return True          # cannot tell: let the real call speak for itself
    return _SSHSIG_SUPPORT[keygen]


def _run(argv: list[str], *, stdin: bytes | None = None, cwd: str | None = None):
    return subprocess.run(argv, input=stdin, capture_output=True, cwd=cwd, timeout=30)


def _no_window(osname: str | None = None) -> dict:
    """``creationflags`` for a captured child that must not flash a console window
    (Windows; the windowed Studio's own hook in no_console does the same, but the
    GUI/TUI call these directly and must not depend on it)."""
    if (osname or os.name) != "nt":
        return {}
    return {"creationflags": getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)}


def _tail(text, lines: int = 3, limit: int = 400) -> str:
    """The last few lines of a tool's message, for a one-sentence error."""
    if isinstance(text, bytes):
        text = text.decode("utf-8", "replace")
    kept = [s.strip() for s in (text or "").splitlines() if s.strip()][-lines:]
    out = " ".join(kept)
    return out[-limit:] if out else "(no message)"


def _payload(g: MeshGrant) -> dict:
    return {"format": FORMAT, **dataclasses.asdict(g)}


def _read_pub(key_path: str) -> str:
    """The issuer public key (``type base64``) of a private key, from its ``.pub``."""
    pub_path = key_path + ".pub"
    try:
        with open(pub_path, encoding="utf-8") as fh:
            return _issuer_key(fh.read().strip())
    except OSError as e:
        raise TokenError("tool", f"Could not read the issuer's public key {pub_path}: {e}")


def _new_grant(*, issuer: str, mesh: str, domain: str, role: str, shell: bool,
               login_server: str, auth_key: str, lifetime_s: int, node_name: str,
               now: int) -> MeshGrant:
    g = MeshGrant(mesh=mesh, domain=domain.lower().strip("."), role=role, shell=bool(shell),
                  login_server=login_server.rstrip("/"), auth_key=auth_key.strip(),
                  expires=now + int(lifetime_s), issued=now, issuer=issuer,
                  node_name=node_name, id=secrets.token_hex(8))
    check_fields(g, now=now)
    return g


def _sign(key_path: str, body: bytes, *, keygen: str, interactive: bool,
          namespace: str = NAMESPACE) -> bytes:
    """An SSHSIG over ``body``. Interactive: ssh-keygen shares the terminal, so it can
    ask for the key's passphrase (a captured run would hang on that prompt).
    Otherwise (GUI/TUI): output captured, no stdin, no console window, and the
    failure raises ``signature`` with ssh-keygen's own words."""
    with tempfile.TemporaryDirectory(prefix="hugmesh-token-") as tmp:
        data = os.path.join(tmp, "payload")
        with open(data, "wb") as fh:
            fh.write(body)
        argv = [keygen, "-Y", "sign", "-f", key_path, "-n", namespace, data]
        if interactive:
            r = subprocess.run(argv, timeout=300)
            if r.returncode != 0:
                raise TokenError("signature", "ssh-keygen could not sign the token (see "
                                              "its message above).")
        else:
            try:
                r = subprocess.run(argv, capture_output=True, stdin=subprocess.DEVNULL,
                                   timeout=60, **_no_window())
            except (OSError, subprocess.SubprocessError) as e:
                raise TokenError("signature", f"ssh-keygen could not sign the token: {e}")
            if r.returncode != 0:
                raise TokenError("signature", "ssh-keygen could not sign the token: "
                                              f"{_tail(r.stderr or r.stdout)}")
        with open(data + ".sig", "rb") as fh:
            return fh.read()


def issue(*, key_path: str, mesh: str, domain: str, role: str, shell: bool,
          login_server: str, auth_key: str, lifetime_s: int, node_name: str = "",
          now: float | None = None, keygen: str | None = None,
          interactive: bool = True) -> str:
    """Sign a token with the issuer's ed25519 SSH key (its ``.pub`` must sit beside
    it). With ``interactive`` (the CLI) ssh-keygen may prompt for the key's
    passphrase on the terminal; without it (the GUI/TUI, with a Studio issuer key,
    which has none) nothing can prompt and a failure carries ssh-keygen's message."""
    now = int(time.time() if now is None else now)
    g = _new_grant(issuer=_read_pub(key_path), mesh=mesh, domain=domain, role=role,
                   shell=shell, login_server=login_server, auth_key=auth_key,
                   lifetime_s=lifetime_s, node_name=node_name, now=now)
    body = _canonical(_payload(g))
    sig = _sign(key_path, body, keygen=keygen or ssh_keygen(), interactive=interactive)
    return f"{FORMAT}.{_b64u(body)}.{_b64u(sig)}"


# ── the Studio's own issuer key, one per mesh ───────────────────────────────────────
ISSUERS_DIR = "mesh-issuers"
ISSUER_KEY = "issuer_ed25519"

#: The self-check signs in its own namespace, so its throwaway signature can never be
#: mistaken for a token signature.
_SELF_CHECK_NAMESPACE = "hugmesh-issuer-self-check@hugmesh.org"


def issuer_dir(mesh: str) -> str:
    """Where the Studio keeps mesh ``mesh``'s issuer key."""
    if not _MESH_RE.match(mesh or ""):
        raise TokenError("invalid", f"{mesh!r} is not a valid mesh name (lower-case letters, "
                                    "digits and -, at most 63).")
    return os.path.join(state_dir(), ISSUERS_DIR, mesh)


def issuer_key_path(mesh: str) -> str:
    return os.path.join(issuer_dir(mesh), ISSUER_KEY)


def ensure_issuer(mesh: str, *, keygen: str | None = None,
                  osname: str | None = None) -> tuple[str, str, str]:
    """(private key path, public key line, fingerprint) of the Studio issuer key for
    ``mesh``, creating it when absent. A newly created key is also TRUSTED on this
    computer, so the admin's own tray accepts the tokens it signs; an existing key's
    trust is left as the operator set it.

    Creation is all or nothing: the key is made in a private scratch dir beside its
    place, self-checked and trusted there, and only then moved into place. A failure
    on the way leaves no key behind (and no trust), so the next call starts afresh
    rather than reusing a key that was never checked or trusted."""
    key = issuer_key_path(mesh)
    pub = key + ".pub"
    keygen = keygen or ssh_keygen()
    osname = osname or os.name
    _tighten_issuer_dirs(mesh, osname)
    if not os.path.isfile(key):
        # mesh-issuers/ AND mesh-issuers/<mesh>/ are private, not just the last one
        _makedirs_private(os.path.dirname(key), osname)
        if os.path.exists(pub):
            os.remove(pub)          # the public half of a key that is gone
        _create_issuer(mesh, key, keygen, osname)
    elif not os.path.isfile(pub):
        try:
            r = subprocess.run([keygen, "-y", "-f", key], capture_output=True,
                               stdin=subprocess.DEVNULL, timeout=60, **_no_window(osname))
        except (OSError, subprocess.SubprocessError) as e:
            raise TokenError("tool", f"Could not read the issuer key {key}: {e}")
        if r.returncode != 0:
            raise TokenError("tool", f"Could not read the issuer key {key}: "
                                     f"{_tail(r.stderr)}")
        with open(pub, "w", encoding="ascii", newline="\n") as fh:
            fh.write(r.stdout.decode("ascii", "replace").strip() + "\n")
    with open(pub, encoding="utf-8") as fh:
        line = fh.read().strip()
    if not _ISSUER_RE.match(_issuer_key(line)):
        raise TokenError("tool", f"The issuer key {pub} is not an ssh-ed25519 public key.")
    return key, line, fingerprint(line)


def _tighten_issuer_dirs(mesh: str, osname: str) -> None:
    """Make mesh-issuers/ and mesh-issuers/<mesh>/ 0700 on POSIX when they already
    exist (an earlier build created mesh-issuers/ 0755, which lists the mesh names) and
    belong to this user. Best effort: a folder it cannot change is left as it is.
    Windows: the per-user state dir's ACL applies."""
    if osname == "nt":
        return
    for d in (os.path.join(state_dir(), ISSUERS_DIR), issuer_dir(mesh)):
        try:
            st = os.lstat(d)
            if stat.S_ISDIR(st.st_mode) and st.st_uid == os.getuid() and st.st_mode & 0o077:
                os.chmod(d, 0o700)
        except OSError:
            pass


def _create_issuer(mesh: str, key: str, keygen: str, osname: str) -> None:
    """Make, self-check and trust a new issuer key, then move it to ``key`` (its
    ``.pub`` first, the private key last: the private key's presence is what says
    "created"). Any failure removes what was made and drops the trust it was given."""
    scratch = tempfile.mkdtemp(prefix=".new-", dir=os.path.dirname(key))
    new = os.path.join(scratch, ISSUER_KEY)
    trusted = ""
    try:
        try:
            r = subprocess.run([keygen, "-q", "-t", "ed25519", "-N", "", "-C",
                                f"hugmesh-issuer {mesh}", "-f", new], capture_output=True,
                               stdin=subprocess.DEVNULL, timeout=60, **_no_window(osname))
        except (OSError, subprocess.SubprocessError) as e:
            raise TokenError("tool", f"ssh-keygen could not create the issuer key for mesh "
                                     f"{mesh}: {e}")
        if r.returncode != 0 or not os.path.isfile(new) or not os.path.isfile(new + ".pub"):
            raise TokenError("tool", f"ssh-keygen could not create the issuer key for mesh "
                                     f"{mesh}: {_tail(r.stderr or r.stdout)}")
        if osname != "nt":
            os.chmod(new, 0o600)
        _self_check(new, keygen, osname)
        with open(new + ".pub", encoding="utf-8") as fh:
            line = fh.read().strip()
        if not _ISSUER_RE.match(_issuer_key(line)):
            raise TokenError("tool", f"ssh-keygen made an issuer key for mesh {mesh} whose "
                                     "public half is not an ssh-ed25519 key.")
        if _issuer_key(line) not in trusted_issuers():
            trust_issuer(line)
            trusted = line
        os.replace(new + ".pub", key + ".pub")
        os.replace(new, key)
    except BaseException:
        if trusted:
            try:
                distrust_issuer(trusted)
            except OSError:
                pass
        if not os.path.isfile(key):
            try:
                os.remove(key + ".pub")
            except OSError:
                pass
        raise
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def _self_check(key: str, keygen: str, osname: str, runner=subprocess.run) -> None:
    """Sign once with a fresh issuer key, so a key that cannot sign fails HERE with a
    reason rather than later in a dialog.

    Windows OpenSSH refuses a private key whose ACL lets anyone but the owner, SYSTEM
    and Administrators read it ("UNPROTECTED PRIVATE KEY FILE" / "Permissions ... are
    too open"). The per-user state dir normally passes, but a state dir moved under a
    shared folder inherits wider entries; then the key's inherited ACL is replaced by
    one entry for this user (icacls /inheritance:r /grant:r USER:F) and it is tried
    again."""
    try:
        _sign(key, b"hugmesh issuer self-check", keygen=keygen, interactive=False,
              namespace=_SELF_CHECK_NAMESPACE)
        return
    except TokenError as e:
        msg = str(e)
        if osname != "nt" or not re.search(r"(?i)permission|unprotected|too open", msg):
            raise TokenError("tool", f"The new issuer key cannot sign: {msg}")
    try:
        r = runner(["icacls", key, "/inheritance:r", "/grant:r", f"{getpass.getuser()}:F"],
                   capture_output=True, stdin=subprocess.DEVNULL, timeout=60,
                   **_no_window(osname))
        fixed = r.returncode == 0
    except (OSError, subprocess.SubprocessError):
        fixed = False
    if not fixed:
        raise TokenError("tool", f"The new issuer key {key} is readable by other accounts "
                                 "and its permissions could not be narrowed, so OpenSSH "
                                 "will not sign with it.")
    try:
        _sign(key, b"hugmesh issuer self-check", keygen=keygen, interactive=False,
              namespace=_SELF_CHECK_NAMESPACE)
    except TokenError as e:
        raise TokenError("tool", f"The new issuer key cannot sign: {e}")


# ── a pre-auth key from the mesh's own headscale ────────────────────────────────────
#: Tags a minted pre-auth key asks for when the headscale container's
#: ``net.hugmesh.headscale.key-tags`` label names none (the local Docker mesh's label
#: names the membership tag tag:hugmesh): none. Role and domain are labels; the mesh
#: decides what this node may do. The pre-auth key only lets it join. In the mesh's
#: headscale policy (specs/etc/headscale/policy.hujson.tmpl, rendered by
#: gen-headscale-policy.sh) the membership user "hugmesh" owns only the membership tags
#: (tag:hugmesh and the role tags), and the tags that gate access (tag:superadmin,
#: tag:mesh_*, tag:dev_*, tag:dom_*) are owned by NO user and SERVER-FORCED at approval
#: by hugmesh-headscale-forcetags. So no access tag is ever asked for, and the server
#: tags the node.
DEFAULT_MINT_TAGS: tuple[str, ...] = ()

#: The headscale user a minted key is for when neither the admin nor the headscale
#: container's ``net.hugmesh.headscale.user`` label names one: the membership user
#: HugMesh's headscale provisioning creates (keys-template/provision.json "users", and
#: the local Docker mesh's headscale), which owns no access tag.
DEFAULT_MINT_USER = "hugmesh"

#: The labels a HugMesh headscale container carries (tests/stack/compose.local.yaml).
HEADSCALE_ROLE_LABEL = "net.hugmesh.role=headscale"
HEADSCALE_USER_LABEL = "net.hugmesh.headscale.user"
HEADSCALE_KEY_TAGS_LABEL = "net.hugmesh.headscale.key-tags"

#: Tags a minted key may never carry. headscale 0.23 turns a pre-auth key's tags into
#: FORCED tags on the node that joins with it, and forced tags bypass tagOwners, so a
#: key minted with one of these hands its holder the access that tag grants
#: (tag:superadmin is the SSH source of the superadmin rule on every node). Only the
#: control node's force-tag pass assigns them.
SECURITY_TAG_RE = re.compile(r"^tag:(?:superadmin$|mesh_|dev_|dom_)")

#: What every face says about the headscale user a minted key is for: the default, and
#: when to name another (never a user that owns an access tag; the role is not a
#: headscale user either).
NAME_MINT_USER = (f"Default: the user the headscale container's {HEADSCALE_USER_LABEL} "
                  f"label names, else {DEFAULT_MINT_USER}, the membership user, which owns "
                  "no access tag. Name another only if your mesh sets one aside for "
                  "joining devices.")

#: One tag per entry: no comma, so a value cannot add a second tag to ``--tags a,b``.
_TAG_RE = re.compile(r"^tag:[a-z0-9][a-z0-9_-]{0,62}\Z")
#: A headscale user or a docker container name; never starts with "-", so it cannot be
#: read as an option. (``\Z``, not ``$``: a trailing newline is refused too.)
_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z")


def _docker(argv: list[str], runner, what: str):
    try:
        r = (runner or subprocess.run)(argv, capture_output=True, text=True, stdin=subprocess.DEVNULL,
                   timeout=60, **proc_text.TEXT_IO, **_no_window())
    except FileNotFoundError:
        raise TokenError("tool", "Minting a pre-auth key needs docker, which was not found.")
    except (OSError, subprocess.SubprocessError) as e:
        raise TokenError("tool", f"{what}: {e}")
    if r.returncode != 0:
        why = _tail(r.stderr) if (r.stderr or "").strip() else f"exit status {r.returncode}"
        raise TokenError("tool", f"{what}: {why}")
    return r


#: A container that IS headscale, not one beside it (headscale-ui, headscale-admin):
#: ``headscale``, or ``<project>-headscale`` / ``<project>_headscale``, with compose's
#: optional replica number.
_HEADSCALE_NAME_RE = re.compile(r"^(?:.*[-_])?headscale(?:[-_][0-9]+)?$")


def find_headscale_container(runner=None) -> str:
    """The running headscale container, else ``tool``. The one running container
    labelled ``net.hugmesh.role=headscale`` (as the local Docker mesh's is) wins; when
    none or several are, ``docker ps --filter name=headscale`` is asked. That matches
    substrings, so when it lists several, the one whose name is headscale itself (see
    ``_HEADSCALE_NAME_RE``) wins over its neighbours; when that still leaves zero or
    several, the error carries the names in ``choices``, the labelled ones included."""
    r = _docker(["docker", "ps", "--filter", f"label={HEADSCALE_ROLE_LABEL}", "--format",
                 "{{.Names}}"], runner, "docker could not list the running containers")
    labelled = sorted({s.strip() for s in (r.stdout or "").splitlines() if s.strip()})
    if len(labelled) == 1:
        return labelled[0]
    r = _docker(["docker", "ps", "--filter", "name=headscale", "--format", "{{.Names}}"],
                runner, "docker could not list the running containers")
    names = sorted({s.strip() for s in (r.stdout or "").splitlines() if s.strip()})
    if not names and not labelled:
        raise TokenError("tool", "No running headscale container was found (docker ps "
                                 f"--filter label={HEADSCALE_ROLE_LABEL} and --filter "
                                 "name=headscale listed none). Start the mesh, or name its "
                                 "headscale container.")
    exact = [n for n in names if _HEADSCALE_NAME_RE.match(n)]
    if len(names) == 1 or len(exact) == 1:
        return names[0] if len(names) == 1 else exact[0]
    # Several labelled ones are choices too, whatever their names.
    choices = tuple(sorted(set(labelled) | set(names)))
    raise TokenError("tool", f"Several running containers match headscale "
                             f"({', '.join(choices)}). Name the one to mint the key in.",
                     choices=choices)


def headscale_labels(container: str, runner=None) -> dict:
    """What the HugMesh labels on the headscale container ``container`` say about
    minting: ``{"user": "hugmesh", "key_tags": ("tag:hugmesh",)}``, each only when its
    label is there AND valid (a headscale user name; membership tags, one per comma,
    none of them a tag that grants access). Read with ``docker inspect``. Never raises:
    a container without these labels, or one docker cannot inspect, gives ``{}``, and an
    invalid label is left out whole, never half used."""
    if not isinstance(container, str) or not _NAME_RE.match(container):
        return {}
    try:
        r = _docker(["docker", "inspect", "--format", "{{json .Config.Labels}}", container],
                    runner, f"docker could not inspect {container}")
        labels = json.loads((r.stdout or "").strip() or "null")
    except (TokenError, ValueError):
        return {}
    if not isinstance(labels, dict):
        return {}
    out: dict = {}
    user = labels.get(HEADSCALE_USER_LABEL)
    if isinstance(user, str) and _NAME_RE.match(user):
        out["user"] = user
    raw = labels.get(HEADSCALE_KEY_TAGS_LABEL)
    if isinstance(raw, str):
        tags = tuple(t.strip() for t in raw.split(","))
        if all(_TAG_RE.match(t) and not SECURITY_TAG_RE.match(t) for t in tags):
            out["key_tags"] = tags
    return out


def _check_mint_user(user) -> None:
    if not isinstance(user, str) or not _NAME_RE.match(user):
        raise TokenError("invalid", f"{user!r} is not a headscale user name.")


def _check_mint_tags(tags: tuple[str, ...]) -> None:
    bad = [t for t in tags if not _TAG_RE.match(t)]
    if bad:
        raise TokenError("invalid", f"{', '.join(map(repr, bad))} is not a headscale tag "
                                    "(tag:name, lower-case).")
    forced = [t for t in tags if SECURITY_TAG_RE.match(t)]
    if forced:
        raise TokenError("invalid", f"{', '.join(map(repr, forced))} grants access, so a "
                                    "pre-auth key may not carry it: the key's tags are "
                                    "forced on whoever joins with it. The mesh's control "
                                    "node assigns access tags itself.")


def _check_container(container) -> None:
    if not isinstance(container, str) or not _NAME_RE.match(container):
        raise TokenError("invalid", f"{container!r} is not a container name.")


def mint_target(user: str = "", tags=None, *, container: str,
                runner=None) -> tuple[str, tuple[str, ...]]:
    """(user, tags) a key minted in ``container`` is for: ``user`` and ``tags`` when
    given (checked: an access tag is refused), else what the container's labels say
    (:func:`headscale_labels`), else :data:`DEFAULT_MINT_USER` and
    :data:`DEFAULT_MINT_TAGS`. The key-tags label is used only for a key minted for the
    label's own user; any other user with tags left out gets :data:`DEFAULT_MINT_TAGS`.
    The labels are read only when something is left out."""
    user = user or ""
    if user:
        _check_mint_user(user)
    if tags is not None:
        tags = tuple(tags)
        _check_mint_tags(tags)
    _check_container(container)
    if not user or tags is None:
        labels = headscale_labels(container, runner)
        user = user or labels.get("user") or DEFAULT_MINT_USER
        if tags is None:
            # The key-tags label is written for the label's own user (only that user
            # owns those tags in the policy, and a key's tags are forced on the node),
            # so it applies only to a key minted for that user.
            tags = (labels.get("key_tags", DEFAULT_MINT_TAGS)
                    if labels.get("user") and user == labels["user"] else DEFAULT_MINT_TAGS)
    # what the labels gave gets the same checks as given values
    _check_mint_user(user)
    _check_mint_tags(tags)
    return user, tags


def mint_preauth_key(*, user: str = "", tags=None, lifetime_s: int,
                     container: str = "", runner=None) -> str:
    """A new single-use headscale pre-auth key that expires after ``lifetime_s``,
    minted in the RUNNING headscale container ``container`` (found with ``docker ps``
    when ""), for ``user`` with ``tags``. Either left out ("" / None) comes from
    :func:`mint_target`: the container's labels, else ``hugmesh`` and no tags. The key
    is returned, never printed or logged."""
    if user:
        _check_mint_user(user)
    if tags is not None:
        tags = tuple(tags)
        _check_mint_tags(tags)
    if not 0 < int(lifetime_s) <= MAX_LIFETIME_S:
        raise TokenError("invalid", "A pre-auth key's lifetime must be between a moment and "
                                    f"{MAX_LIFETIME_S // 86400} days.")
    if container:
        _check_container(container)
    container = container or find_headscale_container(runner)
    # A FOUND name gets the same check as a given one (mint_target makes it before it
    # reads labels): docker ps output is not trusted to be a name that cannot be read
    # as an option.
    user, tags = mint_target(user, tags, container=container, runner=runner)
    argv = ["docker", "exec", container, "headscale", "preauthkeys", "create",
            "--user", user, "--expiration", f"{int(lifetime_s)}s"]
    if tags:
        argv += ["--tags", ",".join(tags)]
    r = _docker(argv, runner, f"headscale in {container} could not mint a pre-auth key for "
                              f"the user {user} (does that headscale user exist?)")
    lines = [s.strip() for s in (r.stdout or "").splitlines() if s.strip()]
    key = lines[-1] if lines else ""
    # Never echoed: if this line is not a key, the output may still hold one.
    if len(key) < 16 or any(c.isspace() for c in key):
        raise TokenError("tool", f"headscale in {container} did not print a pre-auth key, so "
                                 "no token was issued.")
    return key


def check_signing(key_path: str, *, keygen: str | None = None,
                  interactive: bool = False) -> None:
    """Sign a throwaway with ``key_path`` (in the self-check namespace, so it can never
    pass as a token), so a key that cannot sign — a mistyped passphrase, an ACL OpenSSH
    refuses, a timeout — fails BEFORE a pre-auth key is minted for its token."""
    _read_pub(key_path)
    _sign(key_path, b"hugmesh issuer self-check", keygen=keygen or ssh_keygen(),
          interactive=interactive, namespace=_SELF_CHECK_NAMESPACE)


def expire_preauth_key(key: str, *, user: str, container: str, runner=None) -> bool:
    """Expire a pre-auth key this Studio minted but could not put in a token. The key
    goes to the container on stdin, so it is not on the ``docker exec`` command line
    (this needs a shell in the container, as HugMesh's images have). Inside the
    container it IS an argument of ``headscale preauthkeys expire`` for as long as that
    runs, and a container's processes are processes of the host running docker, so for
    that moment the key is visible in that host's process list. It is a key that is
    being expired, from a run that has just failed. Returns whether it worked."""
    script = 'IFS= read -r k && exec headscale preauthkeys expire --user "$1" "$k"'
    try:
        r = (runner or subprocess.run)(
            ["docker", "exec", "-i", container, "sh", "-c", script, "sh", user],
            input=key + "\n", capture_output=True, text=True, timeout=60,
            **proc_text.TEXT_IO, **_no_window())
    except (OSError, subprocess.SubprocessError):
        return False
    return r.returncode == 0


def mint_and_issue(*, key_path: str, user: str = "", container: str = "",
                   tags=None, interactive: bool = False,
                   keygen: str | None = None, runner=None, **fields) -> tuple[str, str]:
    """(token, container): mint a single-use pre-auth key for the headscale ``user``
    with ``tags`` (either left out comes from :func:`mint_target`: the container's
    labels, else ``hugmesh`` and no tags) and sign a token carrying it.
    The issuer key is made to sign once FIRST, so the usual signing failures happen
    before anything exists on the server; if signing still fails after the mint, the
    minted key is expired, and the error says whether that worked. ``fields`` are
    :func:`issue`'s (mesh, domain, role, shell, login_server, lifetime_s, node_name),
    already checked by the caller."""
    if user:
        _check_mint_user(user)
    if tags is not None:
        tags = tuple(tags)
        _check_mint_tags(tags)
    if container:
        _check_container(container)
    container = container or find_headscale_container(runner)
    user, tags = mint_target(user, tags, container=container, runner=runner)
    check_signing(key_path, keygen=keygen, interactive=interactive)
    auth_key = mint_preauth_key(user=user, tags=tags, lifetime_s=fields["lifetime_s"],
                                container=container, runner=runner)
    try:
        return issue(key_path=key_path, auth_key=auth_key, interactive=interactive,
                     keygen=keygen, **fields), container
    except BaseException as e:
        if expire_preauth_key(auth_key, user=user, container=container, runner=runner):
            after = (f"The pre-auth key minted for it in {container} has been expired, so "
                     "nothing usable is left on the server.")
        else:
            after = (f"The pre-auth key minted for it in {container} (headscale user "
                     f"{user}) could not be expired and stays usable until it expires: "
                     f"expire it with headscale preauthkeys list / expire --user {user}.")
        if isinstance(e, TokenError):
            raise TokenError(e.kind, f"{e} {after}") from None
        if isinstance(e, Exception):
            raise TokenError("signature", f"The token could not be signed: {e}. "
                                          f"{after}") from None
        raise                       # Ctrl-C: the key was still expired above


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


def _makedirs_private(folder: str, osname: str | None = None) -> None:
    """``os.makedirs(folder)``, with EVERY directory it creates made 0700 on POSIX.
    makedirs applies its mode to the last directory only (and the umask narrows even
    that), so ``mesh-issuers/`` would otherwise be created 0755. Directories that
    already existed keep their mode. Windows: the per-user state dir's ACL applies."""
    created = []
    d = os.path.abspath(folder)
    while not os.path.isdir(d):
        created.append(d)
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    os.makedirs(folder, mode=0o700, exist_ok=True)
    if (osname or os.name) != "nt":
        for d in created:
            os.chmod(d, 0o700)


def _write_private(path: str, text: str) -> None:
    """Write a file only this user can read (0600 on POSIX; the per-user state dir's
    ACL on Windows). The TUI also saves a token to any path the user names, perhaps
    in a shared folder such as /tmp: so the temporary file has a random name and is
    created exclusively (mkstemp: O_EXCL, mode 0600), never opened over a file or a
    symlink someone else put there."""
    folder = os.path.dirname(path)
    os.makedirs(folder, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".", suffix=".tmp",
                               dir=folder)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


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


def token_stored() -> bool:
    """Whether a token file is kept at all, readable or not (what Forget removes)."""
    try:
        return os.path.isfile(_path(TOKEN_FILE))
    except Exception:            # noqa: BLE001 — a broken state dir is "none stored"
        return False


def stored_token() -> str:
    """The kept token's text, or "" when none is kept. A file that is not text (a
    damaged copy, not UTF-8) raises ``malformed``: it is a token that cannot be used,
    not an absent one, so the tray refuses to start rather than fall back to
    ``TS_AUTHKEY``, and the token dialog still opens to Forget it."""
    try:
        with open(_path(TOKEN_FILE), encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""
    except (UnicodeDecodeError, ValueError):
        raise TokenError("malformed", "The stored HugMesh token file is damaged (it is not "
                                      "text). Forget it and import the token again.") from None


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
    """What the tray runs a mesh node under now, as one sentence. Never raises: the
    token dialog (where Forget lives) opens with it."""
    try:
        g = load_grant()
    except Exception as e:       # noqa: BLE001 — a damaged file is still a sentence
        return f"The imported token cannot be used: {e}"
    if g is None:
        return "No HugMesh token imported. The mesh node uses TS_AUTHKEY, if it is set."
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
        g, why, _ = self._grant_state()
        return g, why

    def _grant_state(self) -> tuple[MeshGrant | None, str, bool]:
        """grant() plus whether a failure is DEFINITIVE (the token itself is bad) as
        opposed to passing (ssh-keygen missing or timing out, an unreadable file)."""
        try:
            return self._load(), "", True
        except TokenError as e:
            return None, str(e), e.kind != "tool"
        except Exception as e:           # a broken state dir must not take the tray down
            return None, f"The stored HugMesh token could not be read: {e}", False

    # ── which credentials the node's tailnet identity came from ──────────────────
    # The tailscale container keeps its registration in the compose project's volume
    # `tsstate` (hugmesh-mesh_tsstate: it outlives the workdir), and a registered node
    # ignores a NEW auth key (and refuses a new --login-server) on the next `tailscale
    # up`. So the credentials a node was started with are recorded beside it, and
    # starting with different ones drops that state first.
    def _identity_path(self) -> str:
        return os.path.join(self.workdir, IDENTITY_FILE)

    def _identity(self, g: MeshGrant | None) -> str:
        if g is not None:
            return g.identity()
        key = MeshNode._authkey(self)
        return "ts_authkey:" + secret_digest(key) if key else ""

    def recorded(self) -> dict:
        """What the running/last node was started with, or {} when this tray did not
        start it (another lane's start drops the record: MeshNode.start)."""
        try:
            with open(self._identity_path(), encoding="utf-8") as fh:
                data = json.load(fh)
            return data if isinstance(data, dict) and data.get("identity") else {}
        except (OSError, ValueError):
            return {}

    @staticmethod
    def _public(g: MeshGrant | None) -> str:
        """The NON-secret part of what the node was started with: a hash of the token's
        signed public fields (its random id included, so two tokens never share it), or
        "ts_authkey". Unlike ``identity`` it needs no salt, so it still compares when
        the salt the record was made under is gone."""
        if g is None:
            return "ts_authkey"
        parts = (_issuer_key(g.issuer), g.mesh, g.domain, g.role, str(g.shell),
                 g.login_server, g.node_name, g.id, str(g.issued), str(g.expires))
        return "token:" + hashlib.sha256("\0".join(parts).encode()).hexdigest()[:16]

    def _compare(self, rec: dict, g: MeshGrant | None) -> bool | None:
        """Was the node recorded in ``rec`` started with the credentials of ``g``?
        True / False, or None when this cannot be told: no record, or a record whose
        digest was made under ANOTHER salt (the salt file was lost, or the state dir
        cannot be written so each process draws its own). A digest from another salt
        never reads as "different": that is what used to wipe a node whose credentials
        had not changed and re-register it with its already-spent single-use key.
        Then only the public part speaks: a different token (or a switch between token
        and TS_AUTHKEY) is a change; the same token is the same; a TS_AUTHKEY whose
        key cannot be compared stays unknown (start() then keeps the record as it was,
        so a changed key is never re-recorded as the one the node runs under).

        A record from before the salt and the public part were kept is compared by its
        digest under the current salt (the salt file it was made under is usually still
        there), then by the token's expiry and issuer it always carried."""
        if not rec:
            return None
        if rec.get("salt") == salt_id():
            return rec.get("identity") == self._identity(g)
        public = rec.get("public")
        if public is None:          # a record from before the public part was kept
            if "salt" not in rec and rec.get("identity") == self._identity(g):
                return True
            if bool(rec.get("token")) != (g is not None):
                return False
            if g is not None and (rec.get("expires") != g.expires
                                  or rec.get("issuer") != _issuer_key(g.issuer)):
                return False
            return None
        if public != self._public(g):
            return False
        return True if g is not None else None

    def _record(self, g: MeshGrant | None, keep: dict | None = None) -> str:
        """Write the record; returns "" or why it could not be written. The token's
        expiry and issuer (neither is secret) let enforce() judge the token the node
        RUNS under, not whichever one is stored now. ``salt`` names the salt the
        identity digest was made under; ``public`` is :meth:`_public`. ``keep`` writes
        that earlier record back unchanged instead."""
        rec = keep or {"identity": self._identity(g), "salt": salt_id(),
                       "public": self._public(g),
                       "summary": g.short() if g else "TS_AUTHKEY", "token": g is not None}
        if g is not None and not keep:
            rec.update(expires=g.expires, issuer=_issuer_key(g.issuer))
        try:
            _write_private(self._identity_path(), json.dumps(rec))
            return ""
        except OSError as e:
            return str(e)

    def _reset_state(self) -> tuple[bool, str]:
        """`compose down -v` on this node's own project: removes its container and
        its tsstate volume, so the next `up` registers afresh."""
        try:
            r = subprocess.run(self._compose("down", "-v"), cwd=self.workdir, env=self._env(),
                               capture_output=True, text=True, **proc_text.TEXT_IO, timeout=300)
            return r.returncode == 0, (r.stderr or r.stdout).strip()
        except (OSError, subprocess.SubprocessError) as e:
            return False, str(e)

    def start(self) -> tuple[bool, str]:
        ok, why = MeshNode.available(self)
        if not ok:
            return False, why
        g, why = self.grant()
        if why:
            return False, why
        if g is None and not super()._authkey():
            return False, ("Import a HugMesh token first (tray menu > HugMesh token…), "
                           "or set TS_AUTHKEY to a tailnet/headscale auth key.")
        rec = self.recorded()
        same = self._compare(rec, g)
        # Staged first, so the project (and with it the volume) can be addressed even
        # when the workdir was deleted since the last run.
        self._stage()
        # Different credentials than the saved state was made with, or a token run over
        # state NO record describes (another lane's start, a deleted workdir): register
        # afresh, or the old registration stays. A record this tray cannot compare
        # (made under another salt) keeps the state and is re-recorded below: wiping it
        # would strand a node whose single-use key is already spent.
        reset = same is False or (not rec and g is not None)
        if reset:
            ok, out = self._reset_state()
            if not ok:
                return False, f"Could not clear the node's previous tailnet identity: {out}"
        self._active = g
        try:
            ok, out = super().start()
        finally:
            self._active = None
        # MeshNode.start drops the record before its `up`. What the state was made with
        # is still known, so it is written back whether or not `up` worked: a failed
        # restart must not leave state that no record describes, which the next start
        # would wipe and re-register with an already-spent single-use key.
        if rec and same is None and (g is None or not ok):
            # Not confirmed (a TS_AUTHKEY under another salt), or the state is untouched
            # by a failed `up`: the earlier record stands as it was.
            why = self._record(g, keep=rec)
        elif ok or reset or same:
            why = self._record(g)       # the state is now g's (or empty, then g's next)
        else:
            why = ""
        if ok and why:
            out = (f"{out}\n" if out else "") + (
                f"(Started, but its credentials could not be recorded: {why})")
        return ok, out

    def apply_limits(self) -> tuple[bool, str]:
        """Re-apply the Resource limits to a RUNNING node now (compose recreates the
        container with the rewritten overlay). A stopped node picks them up at its
        next start, so there is nothing to do. A node started under OTHER (or unknown)
        credentials than the tray holds now is not restarted behind the operator's back.
        One this tray started whose record it cannot compare (another salt, see
        :meth:`_compare`) is restarted: start() keeps its state for exactly that case."""
        if not self.status().running:
            return True, "not running"
        rec = self.recorded()
        if not rec:
            return False, ("it was not started from this tray, so its credentials are "
                           "unknown; stop and start it to apply the limits")
        g, why = self.grant()
        if why or self._compare(rec, g) is False:
            return False, ("it was started under other credentials than the tray holds "
                           "now; stop and start it to apply the limits and the token")
        return self.start()

    def tray_note(self, running: bool) -> tuple[str, str]:
        """(status-line suffix, tooltip). A running node shows what it was STARTED
        with, and says when the stored token differs; a stopped one shows the stored
        token (or why it cannot be used)."""
        g, why = self.grant()
        if running:
            rec = self.recorded()
            if not rec:
                return (" — started outside this tray (restart to apply)",
                        "This node was not started from the tray, so what it runs under "
                        "is unknown. Stop and start it here to run it as the tray says.")
            suffix = f" — {rec.get('summary', '')}"
            if why or self._compare(rec, g) is False:
                return (suffix + " (restart to apply the current token)",
                        why or "The tray holds other credentials than this node was "
                               "started with. Stop and start it to apply them.")
            return suffix, ""
        if why:
            return " — token unusable (hover for why)", why
        return (f" — {g.short()}", "") if g else ("", "")

    def enforce(self, now: float | None = None) -> str:
        """Stop a RUNNING node whose token no longer allows it: the token it was
        STARTED with has expired or its issuer is no longer trusted, or the stored
        token was forgotten or is definitively bad. A passing failure (ssh-keygen
        timing out) never stops a node. Docker's restart policy can bring a node back
        after a reboot without the tray's start-time check, so the tray calls this on
        a timer. Returns what it did, or ""."""
        rec = self.recorded()
        if not rec.get("token") or not self.status().running:
            return ""
        now = time.time() if now is None else now
        if isinstance(rec.get("expires"), int) and now >= rec["expires"]:
            reason = f"the HugMesh token it was started with expired at {_when(rec['expires'])}."
        elif rec.get("issuer") and rec["issuer"] not in trusted_issuers():
            reason = "the issuer of the HugMesh token it was started with is no longer trusted."
        else:
            g, why, definitive = self._grant_state()
            if g is not None or (why and not definitive):
                return ""
            reason = why or "the HugMesh token it was started with has been forgotten."
        ok, out = self.stop()
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

#: Said after every issued token, by the CLI, the window and the text interface.
SERVER_DECIDES = ("Role and domain are labels; the mesh decides what this node may do. "
                  "The pre-auth key only lets it join.")


def _lifetime(text: str) -> int:
    m = re.fullmatch(r"(\d+)([mhd])", text.strip())
    if not m:
        raise argparse.ArgumentTypeError("use a number and m, h or d, e.g. 7d")
    return int(m.group(1)) * _UNITS[m.group(2)]


def _cli_issue(args) -> int:
    fields = dict(mesh=args.mesh, domain=args.domain, role=args.role, shell=args.shell,
                  login_server=args.login_server, lifetime_s=args.expires,
                  node_name=args.node_name)
    # Every field checked BEFORE an issuer key is created or a pre-auth key is minted,
    # so a typo in --domain does not leave a minted key behind on the server (and
    # mint_and_issue makes the key sign once before it mints, for the same reason).
    _new_grant(issuer="ssh-ed25519 AAAA", auth_key="not-yet-minted", now=int(time.time()),
               **fields)
    if args.key:
        key_path, interactive = args.key, True
    else:
        existed = os.path.isfile(issuer_key_path(args.mesh))
        key_path, _, fp = ensure_issuer(args.mesh)
        interactive = False         # a Studio issuer key has no passphrase to ask for
        print(f"Issuer: this Studio's key for mesh {args.mesh}, {fp}"
              + ("" if existed else " (created now; this computer trusts it)"),
              file=sys.stderr)
    container, user, tags = "", "", ()
    if args.mint:
        # the defaults (the container's labels, else hugmesh) resolved here, so the
        # summary below names the user and tags the key was minted for
        container = args.headscale_container or find_headscale_container()
        user, tags = mint_target(args.headscale_user, args.tag or None,
                                 container=container)
        if interactive:
            print("Checking that the key can sign before a pre-auth key is minted: "
                  "ssh-keygen asks for its passphrase (if it has one) now, and again to "
                  "sign the token.", file=sys.stderr)
        token, container = mint_and_issue(
            key_path=key_path, user=user, container=container,
            tags=tags, interactive=interactive, **fields)
    else:
        with open(args.authkey_file, encoding="utf-8") as fh:
            auth_key = fh.read().strip()
        token = issue(key_path=key_path, auth_key=auth_key, interactive=interactive,
                      **fields)
    print(token)
    g, _, _ = parse(token)
    if args.mint:
        asked = ", ".join(tags) if tags else "no tags of its own"
        server = (f"The pre-auth key was minted in {container} for the headscale user "
                  f"{user}: single-use, expiring with the token, with {asked}. "
                  f"{SERVER_DECIDES}")
    else:
        server = SERVER_DECIDES
    if is_onion_login(g.login_server):
        server = f"{server}\n{ONION_NOTE}"
    print(f"\nGrants: {g.describe()}\nIssuer: {fingerprint(g.issuer)} (give the "
          f"recipient this fingerprint separately)\n{server}", file=sys.stderr)
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="python -m hugmesh_studio.core.mesh_token",
        description="Issue, inspect and trust signed HugMesh tokens.")
    sub = p.add_subparsers(dest="cmd", required=True)
    i = sub.add_parser("issue", help="sign a token with an ssh-ed25519 issuer key")
    i.add_argument("--key", default="", help="the issuer's private ssh-ed25519 key (its "
                   ".pub must be beside it); default: this Studio's issuer key for the "
                   "mesh, created on first use")
    i.add_argument("--mesh", required=True)
    i.add_argument("--domain", required=True, help="the access domain")
    i.add_argument("--role", required=True, choices=ROLES)
    i.add_argument("--shell", action="store_true", help=f"grant shell access "
                   f"({' or '.join(SHELL_ROLES)} only)")
    i.add_argument("--login-server", required=True, help="the headscale URL: "
                   + LOGIN_SERVER_FORMS)
    src = i.add_mutually_exclusive_group(required=True)
    src.add_argument("--authkey-file", help="file holding the pre-auth key (kept off the "
                     "command line)")
    src.add_argument("--mint", action="store_true", help="mint a single-use pre-auth key "
                     "in the mesh's running headscale container (docker exec)")
    i.add_argument("--headscale-container", default="", help="with --mint: the headscale "
                   "container (default: the one running container labelled "
                   f"{HEADSCALE_ROLE_LABEL}, else the one named like headscale)")
    i.add_argument("--headscale-user", default="", help="with --mint: the headscale user "
                   "the key is for (default: the headscale container's "
                   f"{HEADSCALE_USER_LABEL} label, else {DEFAULT_MINT_USER}; never a user "
                   "that owns an access tag)")
    i.add_argument("--tag", action="append", default=[], help="with --mint: a tag the key "
                   "asks for (repeatable, one tag each; default: the headscale container's "
                   f"{HEADSCALE_KEY_TAGS_LABEL} label for that label's own user, else none, "
                   "and the server tags the "
                   "node; access tags such as tag:superadmin are refused)")
    i.add_argument("--node-name", default="")
    i.add_argument("--expires", type=_lifetime, default=_lifetime("7d"),
                   help="lifetime such as 12h or 7d (default 7d, at most 90d)")
    s = sub.add_parser("show", help="verify a token and print what it grants")
    s.add_argument("token_file", help="file holding the token ('-' for stdin)")
    t = sub.add_parser("trust", help="trust an issuer's ssh-ed25519 public key")
    t.add_argument("pubkey_file")
    k = sub.add_parser("issuer", help="print this Studio's issuer public key and "
                       "fingerprint for a mesh (created on first use)")
    k.add_argument("--mesh", required=True)
    args = p.parse_args(argv)
    if args.cmd == "issue" and not args.mint and (
            args.headscale_container or args.headscale_user or args.tag):
        i.error("--headscale-container, --headscale-user and --tag go with --mint")
    # Checked here too, not only by mint_and_issue: that runs after the issuer key is
    # created, and nothing is created for a request that cannot be carried out.
    if args.cmd == "issue" and args.mint:
        if args.headscale_user and not _NAME_RE.match(args.headscale_user):
            i.error(f"{args.headscale_user!r} is not a headscale user name.")
        if args.headscale_container and not _NAME_RE.match(args.headscale_container):
            i.error(f"{args.headscale_container!r} is not a container name.")
        bad = [t for t in args.tag if not _TAG_RE.match(t)]
        if bad:
            i.error(f"{', '.join(map(repr, bad))} is not a headscale tag (tag:name, "
                    "lower-case).")
    try:
        if args.cmd == "issue":
            return _cli_issue(args)
        if args.cmd == "issuer":
            existed = os.path.isfile(issuer_key_path(args.mesh))
            key, line, fp = ensure_issuer(args.mesh)
            if not existed:
                print(f"Created the Studio issuer key for mesh {args.mesh} ({key}); this "
                      f"computer trusts it.", file=sys.stderr)
            print(f"{line}\n{fp}")
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
    from .entry import bootstrap as _bootstrap   # the Mac PATH hook: core/entry.py
    _bootstrap()
    raise SystemExit(main())

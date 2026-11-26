"""Provider API keys for "Go live when ready" (hugmesh-generator#1201), Qt-free.

OPERATOR ASK (2026-11-25): "a textbox to enter any api keys for cloudflare or other
services when the golive automatic is enabled in a mesh build".

A domain set to go live when ready through a provider that needs a secret (a Cloudflare
Tunnel token, a DuckDNS / Cloudflare-DDNS API token — ``config.GO_LIVE_TOKEN_PROMPTS``)
gets a masked field on the domain's step. The value follows the domain CA key's rules
(core/domain_ca_keys.py):

* it lives in THIS process only (:class:`TokenStore`) — never in a config file, a
  session record, a mesh manifest, a builder argument, an image, or a log line;
* it is written ONCE, onto the KEYS folder of each stick whose role can be the public
  edge (:func:`is_edge_role`: the roles labelled ``hugmesh.net/backend=true``), as
  ``go-live/<domain>.token`` (0700 dir, 0600 file) — :func:`write_tokens`, called by
  ``WorklistDriver._generate_keys`` after ``gen-provision-keys.sh`` succeeded;
* on the node, ``provision_go_live_tokens`` (specs/etc/keys-provision/provision.sh)
  installs it root-only and ``hugmesh-go-live-at-ready`` hands its PATH to
  ``hugmesh-go-live plan --token-file``.

A provider that needs a token but has none is a BLOCKING preflight problem
(:func:`missing_problems`): the domain could not go live, and finding that out on the
node an hour after boot is worse than finding it on the Review page.
"""
from __future__ import annotations

import os
import threading
from dataclasses import dataclass, field

from . import config, roles

__all__ = ["TokenStore", "store", "is_edge_role", "needs_token", "token_problem",
           "missing_problems", "write_tokens", "STICK_DIR", "EDGE_ROLES"]

#: The folder on a KEYS stick (and the name pattern provision.sh accepts).
STICK_DIR = "go-live"

#: Builder roles labelled hugmesh.net/backend=true — the only nodes the public
#: ingress-nginx runs on, so the only nodes hugmesh-go-live-at-ready acts on.
EDGE_ROLES = ("backend", "backend-gpu", "omnibus", "edge-ai")

#: A token is one line of printable ASCII; anything else is refused, not cleaned.
MAX_TOKEN_LEN = 4096


def is_edge_role(role: str, platform: str) -> bool:
    """Can a node of this Studio role/platform be the public edge?"""
    p = platform or "x86"
    if p not in ("x86", "rpi5"):
        return False
    try:
        r = roles.builder_role(role, p)
    except Exception:                       # noqa: BLE001 — an unknown role is not edge
        return False
    return r in EDGE_ROLES


def needs_token(provider: str) -> bool:
    return provider in config.GO_LIVE_TOKEN_PROMPTS


def token_problem(value: str) -> str:
    """'' when ``value`` can be written as a token file, else why not (never echoing it)."""
    v = (value or "").strip()
    if not v:
        return "the token is empty"
    if len(v) > MAX_TOKEN_LEN:
        return f"the token is longer than {MAX_TOKEN_LEN} characters"
    if any(ord(c) < 0x21 or ord(c) > 0x7e for c in v):
        return "the token has spaces, line breaks or non-ASCII characters"
    return ""


@dataclass
class TokenStore:
    """Domain -> token, in memory only. Thread-safe; nothing here is ever persisted."""
    _tokens: dict[str, str] = field(default_factory=dict)
    _guard: threading.Lock = field(default_factory=threading.Lock, repr=False)

    def set(self, domain: str, value: str) -> str:
        """Store ``value`` for ``domain``; returns the refusal ('' = stored). An empty
        value clears it."""
        v = (value or "").strip()
        with self._guard:
            if not v:
                self._tokens.pop(domain, None)
                return ""
            problem = token_problem(v)
            if problem:
                return problem
            self._tokens[domain] = v
            return ""

    def get(self, domain: str) -> str:
        with self._guard:
            return self._tokens.get(domain, "")

    def has(self, domain: str) -> bool:
        with self._guard:
            return domain in self._tokens

    def clear(self) -> None:
        with self._guard:
            self._tokens.clear()

    def __repr__(self) -> str:              # never the values
        with self._guard:
            return f"TokenStore(domains={sorted(self._tokens)})"


_STORE: TokenStore | None = None
_STORE_GUARD = threading.Lock()


def store() -> TokenStore:
    """The process store (one per Studio process; tests swap ``_STORE``)."""
    global _STORE
    with _STORE_GUARD:
        if _STORE is None:
            _STORE = TokenStore()
        return _STORE


def missing_problems(cfg, st: TokenStore | None = None) -> list[str]:
    """One BLOCKING sentence per go-live-when-ready domain whose provider needs a token
    that was not entered. Empty when every one is present (or none is needed)."""
    st = st or store()
    out = []
    for name, prov in cfg.go_live_domains():
        if needs_token(prov) and not st.has(name):
            out.append(f"{name} is set to go live when ready through {prov}, which needs "
                       f"a {config.GO_LIVE_TOKEN_PROMPTS[prov]}: enter it on the domain's "
                       f"step (it goes onto the KEYS sticks only, never into the image)")
    return out


def write_tokens(keys_dir: str, cfg, role: str, platform: str,
                 st: TokenStore | None = None) -> list[str]:
    """Write ``go-live/<domain>.token`` into ``keys_dir`` for each go-live-when-ready
    domain that has a token, when ``role`` can be the public edge. Returns the domains
    written (never the values). Raises OSError on a write failure."""
    if not is_edge_role(role, platform):
        return []
    st = st or store()
    pending = [(n, st.get(n)) for n, prov in cfg.go_live_domains()
               if needs_token(prov) and st.has(n)]
    if not pending:
        return []
    d = os.path.join(keys_dir, STICK_DIR)
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(d, 0o700)
    written = []
    for name, value in pending:
        path = os.path.join(d, f"{name}.token")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            os.write(fd, (value + "\n").encode("ascii"))
        finally:
            os.close(fd)
        os.chmod(path, 0o600)
        written.append(name)
    return written

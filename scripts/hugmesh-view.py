#!/usr/bin/env python3
"""hugmesh-view — open ANY HugMesh front door in THIS machine's browser.

    scripts/hugmesh-view.py trust                # trust the local CA (once)
    scripts/hugmesh-view.py list                 # what is mapped, and where
    scripts/hugmesh-view.py up                   # serve the host shell
    scripts/hugmesh-view.py up --lane compose    # serve the compose stack
    scripts/hugmesh-view.py up --lane kind-svc   # the internal UIs, opt-in
    scripts/hugmesh-view.py up --only app --only argocd
    scripts/hugmesh-view.py stop                 # tear a background session down
    scripts/hugmesh-view.py untrust              # remove the CA again

ONE DOOR BY DEFAULT
-------------------
`up` serves the HOST SHELL and nothing else. The shell is the product: every
other surface is meant to be reached THROUGH it as a federated remote, and a
row of side ports inviting you to open each service directly is how a
federation bug stays invisible until production. The internal UIs (ArgoCD,
Vault, Casdoor, Harbor) are still one flag away — `--lane kind-svc`, or
`--only <name>` — for when you are debugging the platform rather than using it.

THE FOUR THINGS THAT MAKE LOCAL BROWSING HARD (all of them, at once)
--------------------------------------------------------------------
1. Every front door routes by HOST HEADER. The kind ingress serves
   `hugmesh.net` and `*.hugmesh.net`; Harbor serves `registry.hugmesh.net`.
   `http://localhost:8080/` therefore 404s: the request arrives with the wrong
   Host, not with no route.
2. Those names do not resolve. The fix everyone reaches for — a line in
   /etc/hosts — needs root, and on a workstation with no admin password that is
   not a fix at all. NOTHING in this tool needs root.
3. The HTTPS door presents a SELF-SIGNED certificate AND sends
   `Strict-Transport-Security: max-age=31536000; includeSubDomains`. That pair
   is a NON-BYPASSABLE block in Chrome ("you cannot proceed"), and it poisons
   the whole domain in the browser's HSTS store for a year — including for any
   later, legitimate use of that name. Firefox is only marginally better.
4. Several UIs have no Ingress at all (argocd-server, casdoor, vault,
   harbor-portal are ClusterIP-only), so there is no door to point a Host
   header at until something forwards a port.

THE SHAPE THAT SOLVES ALL FOUR
------------------------------
The browser speaks **HTTPS to 127.0.0.1** against a certificate this tool mints
and this machine's own browsers trust — so the page is a genuine secure context
(service workers, WebCrypto, `Secure` cookies and SameSite=None all behave as
they will in production) with no warning to click through. THIS TOOL speaks
HTTPS upstream with the correct Host header, and rewrites the answer so the
round trip cannot escape.

Serving plaintext was the obvious way to dodge problem 3 and it is the wrong
trade: it makes the local page a NON-secure context, so the very browser
behaviour that breaks in production is exactly what local browsing cannot
reproduce. `trust` solves problem 3 properly instead — see THE CERTIFICATE
below. A plain-http request to a door's port is answered with a 308 to its
https URL, so an old bookmark still lands.

The rewrites:

  * `Location:` headers, absolute URLs in text/JSON/JS bodies and hostnames in
    the CSP are rewritten from `https://<mapped host>` to the loopback origin
    of WHICHEVER door serves that host — so an SSO bounce from the app to a
    second domain lands on the second door's port instead of a name the browser
    cannot resolve;
  * `Set-Cookie` loses only `Domain=` — a domain the browser never visited is
    silently discarded, which breaks the session in a way that looks like a
    login bug. `Secure` and `SameSite=None` are now PRESERVED: the loopback door
    is https, so they work here exactly as they will in the cluster, and a
    session that depends on them is tested rather than papered over;
  * `Strict-Transport-Security` is still dropped on the way down, and that is
    not vestigial — HSTS is scoped per HOST, not per port, so one pinned
    response on 127.0.0.1 would force every OTHER plain-http service on this
    workstation's loopback to https for a year. That is the same trap as
    problem 3, aimed at localhost;
  * the CSP keeps `upgrade-insecure-requests` (there is nothing left to
    upgrade), and its host sources are rewritten so an allow-list naming the
    real domain still allows the loopback door serving it.

THE CERTIFICATE
---------------
`hugmesh-view trust` mints a local CA under the state dir and installs it into
this user's OWN NSS trust stores — `~/.pki/nssdb` (Chrome/Chromium) and every
Firefox profile with a `cert9.db`. All of those are user-writable: like the rest
of this tool, it needs no root, and `untrust` removes it again.

That CA carries a critical `nameConstraints` extension permitting ONLY
`localhost`, `127.0.0.0/8` and `::1`. This matters: an unconstrained local CA in
a browser trust store can vouch for any site on the internet, so its private key
sitting in a state directory is a standing risk to every domain you browse.
Constrained, the worst it can forge is loopback — which is the only thing it is
for. The leaf is reissued automatically when it nears expiry; the CA is not
reinstalled behind your back, because touching a trust store is something you
should have asked for.

Requests going UP get `Host`, `X-Forwarded-Host`, `X-Forwarded-Proto` and a
`Referer`/`Origin` rewritten back to the real vhost, because a gateway that
believes it is being addressed as 127.0.0.1 emits absolute URLs that break the
next hop. `Accept-Encoding: identity` is forced: this proxy rewrites bodies, and
it must never be handed a `br`/`zstd` stream it cannot decode.

THREE LANES, ONE MECHANISM
--------------------------
kind      the ingress door (host-routed, https on the kind node's published
          8443) plus `kubectl port-forward` for the ClusterIP-only UIs. The
          port-forward's local port is EPHEMERAL and internal; the browser
          still talks to this tool, which is what gives ArgoCD its TLS
          termination (it 307-redirects http->https on any port it is given).
compose   tests/stack/compose.local.yaml's published front doors. Same
          treatment; the TLS door is fronted so the browser never meets the
          per-machine CA in tests/stack/.tls-front.
device    a keep-alive emulated device publishes ONLY ssh (127.0.0.1:22300-22399),
          so its web UI rides an `ssh -L` tunnel to the guest's own :443. The
          tunnel argv comes from studio's ONE author,
          hugmesh_studio.core.emulation.web_tunnel_argv — this file does not
          spell an ssh forward of its own.

WHAT IS CONFIGURATION AND WHAT IS CODE
--------------------------------------
Every domain, upstream and port lives in scripts/hugmesh-view.tsv. Adding a
domain is appending a row; moving a port off a collision is one env var
(`HUGMESH_VIEW_PORT_<NAME>`); pointing the whole tool at a different mesh is
`--catalog`. No mapping is hardcoded here.
The Studio also writes tests/stack/.looks/view.tsv (gitignored) with one compose-lane
row per added domain of the local stack, so `make view LANE=compose` opens each
domain by its own name; it is read only together with the shipped catalog.

NOT SUPPORTED, ON PURPOSE
-------------------------
WebSocket upgrades are not proxied (Vault's and ArgoCD's terminal panes will not
work through this tool; their HTTP UIs do). This is a loopback development aid:
it binds 127.0.0.1 only, disables upstream certificate verification by design,
and must never be exposed off the workstation.
"""
from __future__ import annotations

import argparse
import glob
import gzip
import http.server
import json
import os
import re
import shlex
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import zlib
from dataclasses import dataclass

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

#: Default catalog. `--catalog` / HUGMESH_VIEW_TSV point elsewhere (a brand's
#: own domain set, a second mesh, a test fixture).
DEFAULT_CATALOG = os.path.join(HERE, "hugmesh-view.tsv")

#: Rows GENERATED for the local stack's added domains (studio core/look_serving.py
#: writes it when the Studio starts a mesh with added domains, and removes it when
#: there are none; gitignored). Read together with the DEFAULT catalog only: a
#: `--catalog` of your own is taken exactly as written.
GENERATED_CATALOG = os.path.join(REPO, "tests", "stack", ".looks", "view.tsv")

#: Where a background session records its pids so `stop` can find them — and so
#: a CRASHED session's port-forwards can be swept instead of silently squatting
#: a port forever (an observed failure mode: a leftover `kubectl port-forward`
#: holds the port, the next run binds nothing, and the browser shows a door that
#: is not the door you think it is).
DEFAULT_STATE = os.path.join(REPO, "out", "hugmesh-view")

LOOPBACK = "127.0.0.1"

#: Hop-by-hop headers: they describe ONE connection, so they may not be relayed
#: in either direction.
HOP = frozenset({
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade",
})

#: Dropped on the way DOWN, on top of HOP. HSTS is the whole reason browsers get
#: stuck on this domain; the length/encoding are recomputed after the rewrite;
#: the pinning headers describe a certificate the browser never sees.
STRIP_DOWN = HOP | frozenset({
    "strict-transport-security", "content-encoding", "content-length",
    "public-key-pins", "public-key-pins-report-only",
})

#: Roles whose device carries the mesh's web front door, most-specific first.
#: Used only to resolve `device+https://@gateway` against the LIVE registry.
GATEWAY_ROLES = ("fe", "frontend", "gateway", "omnibus", "host")

_UPSTREAM_DIRECT = re.compile(r"^(https?)://([^/\s]+?)(?::(\d+))?/*$")
_UPSTREAM_K8S = re.compile(r"^k8s\+(https?)://([A-Za-z0-9-]+)/([A-Za-z0-9.-]+):(\d+)$")
_UPSTREAM_DEVICE = re.compile(r"^device\+(https?)://(\S+)$")
_ENV_REF = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}")


class ViewError(Exception):
    """Anything the operator can fix: a bad row, a busy port, a dead lane."""


# ── the catalog ───────────────────────────────────────────────────────────────

@dataclass
class Entry:
    name: str
    lane: str
    host: str          # "" when the door does not route by name
    upstream: str      # expanded, scheme picks the mechanism
    port: int          # loopback port the BROWSER opens
    path: str          # "/..." — the path worth opening
    lineno: int = 0

    @property
    def origin(self) -> str:
        return f"https://{LOOPBACK}:{self.port}"

    @property
    def url(self) -> str:
        return self.origin + self.path


def env_var_for(name: str) -> str:
    """The port-override env var for a row: `app` -> HUGMESH_VIEW_PORT_APP.

    Derived, never listed: a row added to the catalog gets its override for
    free, which is the point of the whole file.
    """
    slug = re.sub(r"[^A-Za-z0-9]", "_", name).upper()
    return f"HUGMESH_VIEW_PORT_{slug}"


def expand_env(text: str, env) -> str:
    """`${VAR}` / `${VAR:-default}` from the environment. Nothing else.

    Deliberately NOT a shell: the catalog is data, and a row must not be able to
    run a command. An unset `${VAR}` with no default is an error rather than an
    empty string, because silently expanding to `http://127.0.0.1:` yields a
    door that fails at connect time with nothing pointing back at the typo.
    """
    def one(m):
        val = env.get(m.group(1))
        if val is not None and val != "":
            return val
        if m.group(2) is not None:
            return m.group(2)
        raise ViewError(f"{m.group(0)} is unset and has no default")
    return _ENV_REF.sub(one, text)


def parse_catalog(text: str, env=None) -> list[Entry]:
    """Parse the TSV into entries, applying env expansion and port overrides.

    Fails CLOSED on a malformed row: a six-column contract that silently accepts
    five columns would map a door to whatever the shifted columns happened to
    spell, which is worse than not starting.
    """
    env = os.environ if env is None else env
    entries: list[Entry] = []
    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) != 6:
            raise ViewError(
                f"catalog line {lineno}: expected 6 TAB-separated columns, got "
                f"{len(cols)} — 'name<TAB>lane<TAB>host<TAB>upstream<TAB>"
                f"local_port<TAB>path'")
        name, lane, host, upstream, port_s, path = (c.strip() for c in cols)
        if not name or not lane or not upstream or not port_s:
            raise ViewError(f"catalog line {lineno}: empty name/lane/upstream/port")
        try:
            upstream = expand_env(upstream, env)
            host = expand_env(host, env)
        except ViewError as exc:
            raise ViewError(f"catalog line {lineno}: {exc}") from None

        override = env.get(env_var_for(name))
        chosen = override if override else port_s
        try:
            port = int(chosen)
        except ValueError:
            src = env_var_for(name) if override else f"line {lineno}"
            raise ViewError(f"catalog {src}: '{chosen}' is not a port number") from None
        if not 1 <= port <= 65535:
            raise ViewError(f"catalog line {lineno}: port {port} out of range")

        entries.append(Entry(
            name=name, lane=lane,
            host="" if host in ("-", "") else host,
            upstream=upstream, port=port,
            path="/" if path in ("-", "") else path,
            lineno=lineno))

    names = [e.name for e in entries]
    dupes = sorted({n for n in names if names.count(n) > 1})
    if dupes:
        raise ViewError(f"catalog: duplicate row name(s): {', '.join(dupes)}")
    return entries


def load_catalog(path: str, env=None) -> list[Entry]:
    if not os.path.isfile(path):
        raise ViewError(f"catalog not found: {path}")
    with open(path, encoding="utf-8") as fh:
        return parse_catalog(fh.read(), env)


def load_entries(path: str, env=None, generated: str | None = None) -> list[Entry]:
    """The catalog at ``path`` plus, when ``path`` is the shipped default, the
    generated per-domain rows (``GENERATED_CATALOG``) if that file exists. A row name
    in both is refused like any other duplicate: a generated row must never silently
    replace a shipped door."""
    entries = load_catalog(path, env)
    generated = GENERATED_CATALOG if generated is None else generated
    if (os.path.abspath(path) != os.path.abspath(DEFAULT_CATALOG)
            or not os.path.isfile(generated)):
        return entries
    try:
        extra = load_catalog(generated, env)
    except ViewError as exc:
        raise ViewError(f"{generated}: {exc}") from None
    names = [e.name for e in entries + extra]
    dupes = sorted({n for n in names if names.count(n) > 1})
    if dupes:
        raise ViewError(f"{generated}: row name(s) already in the catalog: "
                        f"{', '.join(dupes)}")
    return entries + extra


def select(entries: list[Entry], lane: str, only: list[str]) -> list[Entry]:
    """The rows a command acts on. `--only` wins over `--lane`."""
    if only:
        by_name = {e.name: e for e in entries}
        missing = [n for n in only if n not in by_name]
        if missing:
            raise ViewError(f"no such row(s): {', '.join(missing)} "
                            f"(have: {', '.join(sorted(by_name))})")
        return [by_name[n] for n in only]
    chosen = [e for e in entries if e.lane == lane]
    if not chosen:
        lanes = ", ".join(sorted({e.lane for e in entries}))
        raise ViewError(f"lane '{lane}' has no rows (have: {lanes})")
    return chosen


# ── port policy ───────────────────────────────────────────────────────────────

def port_is_free(port: int, host: str = LOOPBACK) -> bool:
    """Can the DOOR bind it? Not 'is something listening' — bind, because that is
    the syscall that will fail later, and it is the one that sees a port held by
    a process we cannot see in `ss`.

    SO_REUSEADDR is set for one reason and it is not tidiness: this probe has to
    predict `TLSServer.bind()`, and that inherits `allow_reuse_address = True`
    from ThreadingHTTPServer. Without the option here, the probe is STRICTER than
    the bind it predicts, so every door that has actually served traffic reports
    a false collision for the whole TIME_WAIT window (~60s on Linux): `make view`
    -> browse -> `make view-stop` -> `make view` failed with "port 9080 (app) is
    already in use — set HUGMESH_VIEW_PORT_APP=<free port>", advice that is
    simply wrong. Measured here as TIME-WAIT rows on the door's own port with
    nothing in `ss -ltn`. A port genuinely held by a LISTENING socket still
    fails to bind with the option set, which is what keeps the check real.

    ⚠ The pairing is the invariant, not the option: this probe must carry
    EXACTLY the reuse options the server sets. `TLSServer` leaves
    `allow_reuse_port = False`, so SO_REUSEADDR alone matches it today. If anyone
    ever sets `allow_reuse_port = True`, this probe needs SO_REUSEPORT too or it
    silently drifts back to predicting a different syscall than the one that
    runs — the same false-collision bug, reintroduced quietly.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind((host, port))
        return True
    except OSError:
        return False
    finally:
        sock.close()


def free_port() -> int:
    """An ephemeral loopback port for an INTERNAL hop (port-forward, ssh -L).

    Never for a browser-facing port: those are catalog policy. The bind/close
    race is acceptable here and only here, because a lost race shows up
    immediately as a failed health check on a hop we own, not as a door the
    operator was told to open.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.bind((LOOPBACK, 0))
        return sock.getsockname()[1]
    finally:
        sock.close()


def port_collisions(entries: list[Entry]) -> list[str]:
    """Every reason a set of rows cannot all bind — reported at once.

    Two independent failures, and they read differently on purpose: two ROWS
    claiming one port is a catalog problem, while a busy port is somebody
    else's process (very often a previous run of this very tool). Both name the
    exact env var that fixes them, because 'configurable' has to mean
    'fixable in one line', not 'editable if you find the file'.
    """
    problems: list[str] = []
    seen: dict[int, str] = {}
    for e in entries:
        if e.port in seen:
            problems.append(
                f"rows '{seen[e.port]}' and '{e.name}' both want port {e.port} — "
                f"set {env_var_for(e.name)}=<free port>")
        else:
            seen[e.port] = e.name
    for e in entries:
        if seen.get(e.port) == e.name and not port_is_free(e.port):
            problems.append(
                f"port {e.port} ({e.name}) is already in use — "
                f"set {env_var_for(e.name)}=<free port>")
    return problems


def wait_for_port(port: int, deadline: float, proc=None) -> bool:
    """Block until something accepts on the loopback port, or time runs out.

    `proc` short-circuits: a helper that has already exited is never going to
    open the port, and waiting the full timeout to say so hides the real error
    (a bad namespace, a missing kubeconfig, a refused ssh key).
    """
    while time.time() < deadline:
        if proc is not None and proc.poll() is not None:
            return False
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(0.5)
        try:
            sock.connect((LOOPBACK, port))
            return True
        except OSError:
            time.sleep(0.15)
        finally:
            sock.close()
    return False


# ── rewriting: the part that makes the round trip stay on loopback ────────────

def build_hostmap(entries: list[Entry],
                  owner: Entry | None = None) -> dict[str, str]:
    """hostname -> loopback authority, across ALL running rows.

    Cross-row on purpose: the app's SSO bounce to a second DOMAIN is exactly the
    redirect that escapes the tool, and it can only be caught by a map that
    knows the OTHER door's port.

    `owner` is the row this map will serve, and it wins for its OWN host. Two
    rows may legitimately share a host: the shipped catalog puts four rows on
    `hugmesh.net` (kind, compose-app, compose-tls, device), because the same mesh
    domain is reached by a different transport per lane — and `compose` runs a
    plaintext door and a TLS door on that host at once, on purpose. A plain
    `{e.host: ...}` comprehension collapses those to one entry and the LAST row
    parsed wins, so a door rewrote the links, `Location:` and CSP host-sources in
    its OWN responses to a DIFFERENT door's port: the browser got a page from
    door A whose every onward URL pointed at door B. Observed live — a body
    served from :9090 containing `href="https://127.0.0.1:9091/"`.

    Refusing to start on a duplicate host would fail loudly, but it would reject
    the catalog this tool ships with, so instead the door's own port simply wins
    for its own responses — the rule `make_redirect_handler` already follows via
    `entry.port`. Only a host that is NOT this door's own still resolves
    cross-row, which is the case the map exists for. Among other rows sharing a
    host the FIRST in catalog order wins, so the choice stays deterministic and
    reads off the file top-down instead of depending on parse order.
    """
    out: dict[str, str] = {}
    for e in entries:
        if e.host and e.host not in out:
            out[e.host] = f"{LOOPBACK}:{e.port}"
    if owner is not None and owner.host:
        out[owner.host] = f"{LOOPBACK}:{owner.port}"
    return out


def build_reverse(entries: list[Entry]) -> dict[str, str]:
    """loopback authority -> the real origin, for headers going UP."""
    out = {}
    for e in entries:
        if e.host:
            out[f"{LOOPBACK}:{e.port}"] = f"https://{e.host}"
    return out


def rewrite_text(text: str, hostmap: dict[str, str]) -> str:
    """Rewrite mapped hostnames in a body/header value to their loopback door.

    Boundary-anchored: `hugmesh.net` inside `id.hugmesh.net` or
    `hugmesh.net.example.org` is NOT this host, and rewriting it would corrupt a
    URL that was already correct. Longest host first so a subdomain row always
    wins over the apex row even where the boundaries would allow both.
    """
    for host in sorted(hostmap, key=len, reverse=True):
        auth = hostmap[host]
        esc = re.escape(host)
        text = re.sub(rf"https?://{esc}(?![A-Za-z0-9.-])", f"https://{auth}", text)
        text = re.sub(rf"(?<![A-Za-z0-9.:-])//{esc}(?![A-Za-z0-9.-])",
                      f"//{auth}", text)
    return text


def rewrite_cookie(value: str) -> str:
    """Make an upstream cookie survive on the loopback origin.

    ONE edit now, and deliberately only one. `Domain=` names a host the browser
    never visited, so the cookie is DISCARDED — the session then looks like a
    login bug rather than a proxy bug, and no amount of correct application code
    can save it.

    `Secure` and `SameSite=None` are left ALONE, which is the point of serving
    https here. Stripping them (as a plaintext door must) quietly converts the
    session into one with weaker flags than production will use, so a cookie
    that is going to be rejected in the cluster works perfectly on the
    workstation — the class of bug local browsing exists to catch.
    """
    return re.sub(r";\s*Domain=[^;]*", "", value, flags=re.I)


def rewrite_csp(value: str, hostmap: dict[str, str]) -> str:
    """Keep the policy INTACT; only re-point its host sources at the door.

    An allow-list that names the real domain must still allow the loopback door
    serving it, or the shell loads and its federated remotes are blocked — which
    presents as a blank page, not as a CSP error anyone thinks to look for.

    `upgrade-insecure-requests` is deliberately NOT stripped any more. The door
    is https, so there is nothing left for it to upgrade, and honouring the
    policy verbatim is what keeps the local page an honest rehearsal of the
    deployed one.
    """
    return rewrite_text(value, hostmap)


def rewrite_upward(value: str, reverse: dict[str, str]) -> str:
    """`Referer`/`Origin` back to the vhost the app believes it is.

    A gateway that sees `Origin: http://127.0.0.1:9080` against
    `Host: hugmesh.net` treats the request as cross-origin and rejects the form
    post — which is indistinguishable, from the browser, from bad credentials.
    """
    for auth, origin in reverse.items():
        value = value.replace(f"http://{auth}", origin)
        value = value.replace(f"https://{auth}", origin)
    return value


TEXTUAL = ("text/", "json", "javascript", "xml", "+json", "svg")


def is_textual(content_type: str) -> bool:
    ct = (content_type or "").lower()
    return any(t in ct for t in TEXTUAL)


def decompress(payload: bytes, encoding: str) -> bytes:
    enc = (encoding or "").lower().strip()
    if enc == "gzip":
        return gzip.decompress(payload)
    if enc in ("deflate", "zlib"):
        try:
            return zlib.decompress(payload)
        except zlib.error:
            return zlib.decompress(payload, -zlib.MAX_WBITS)
    return payload


# ── the local certificate authority ───────────────────────────────────────────

#: Nickname the CA is filed under in every NSS store. Also what `untrust` looks
#: for, so it must stay stable across versions of this tool.
CA_NICKNAME = "HugMesh local view CA"

#: The ONLY names this CA may vouch for. A local CA in a browser trust store is
#: a skeleton key for the whole web unless it is constrained; these three lines
#: are what make installing it a bounded act rather than a standing risk.
CA_NAME_CONSTRAINTS = (
    "critical,"
    "permitted;DNS:localhost,"
    "permitted;IP:127.0.0.0/255.0.0.0,"
    "permitted;IP:0:0:0:0:0:0:0:1/"
    "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"
)

#: Browsers reject server certificates with absurd lifetimes even from a local
#: root, and a short leaf keeps a leaked state dir from mattering for long.
LEAF_DAYS = 397
CA_DAYS = 3650

#: Reissue the leaf when it has less than this left, so a long-lived checkout
#: never greets you with an expired-certificate interstitial.
LEAF_RENEW_SECONDS = 30 * 86400


def cert_dir(state_dir: str) -> str:
    return os.path.join(state_dir, "tls")


def cert_paths(state_dir: str) -> dict[str, str]:
    d = cert_dir(state_dir)
    return {
        "dir": d,
        "ca_key": os.path.join(d, "ca.key"),
        "ca_crt": os.path.join(d, "ca.crt"),
        "key": os.path.join(d, "loopback.key"),
        "crt": os.path.join(d, "loopback.crt"),
    }


def _openssl(*argv: str, stdin: str | None = None) -> str:
    """Run openssl, raising a ViewError that names the failure.

    openssl is used rather than the `cryptography` package on purpose: this tool
    has no third-party imports anywhere else, and requiring a pip install to
    look at a login page would defeat the point.
    """
    proc = subprocess.run(("openssl",) + argv, input=stdin, text=True,
                          capture_output=True)
    if proc.returncode != 0:
        raise ViewError(f"openssl {argv[0]} failed:\n    "
                        + (proc.stderr or "").strip().replace("\n", "\n    "))
    return proc.stdout


def _cert_seconds_left(path: str) -> float:
    """Seconds until `path` expires; -1 if it is missing or unreadable."""
    if not os.path.exists(path):
        return -1.0
    try:
        out = _openssl("x509", "-in", path, "-noout", "-enddate")
    except ViewError:
        return -1.0
    stamp = out.strip().split("=", 1)[-1]
    for fmt in ("%b %d %H:%M:%S %Y %Z", "%b %d %H:%M:%S %Y"):
        try:
            expiry = time.strptime(stamp, fmt)
        except ValueError:
            continue
        return time.mktime(expiry) - time.time()
    return -1.0


def ensure_ca(state_dir: str, out=sys.stdout) -> dict[str, str]:
    """Mint the name-constrained CA if it is missing or expiring."""
    paths = cert_paths(state_dir)
    os.makedirs(paths["dir"], mode=0o700, exist_ok=True)
    fresh = (_cert_seconds_left(paths["ca_crt"]) > LEAF_RENEW_SECONDS
             and os.path.exists(paths["ca_key"]))
    if fresh:
        return paths
    print(f"  minting a loopback-only CA in {paths['dir']}", file=out)
    _openssl(
        "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes",
        "-days", str(CA_DAYS),
        "-keyout", paths["ca_key"], "-out", paths["ca_crt"],
        "-subj", f"/CN={CA_NICKNAME}",
        "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
        "-addext", "keyUsage=critical,keyCertSign,cRLSign",
        "-addext", f"nameConstraints={CA_NAME_CONSTRAINTS}",
    )
    os.chmod(paths["ca_key"], 0o600)
    # The leaf is only as fresh as its issuer: a new CA invalidates it.
    for stale in (paths["key"], paths["crt"]):
        try:
            os.unlink(stale)
        except OSError:
            pass
    return paths


def ensure_leaf(state_dir: str, out=sys.stdout) -> dict[str, str]:
    """Mint/renew the loopback server certificate under the CA."""
    paths = ensure_ca(state_dir, out)
    if _cert_seconds_left(paths["crt"]) > LEAF_RENEW_SECONDS \
            and os.path.exists(paths["key"]):
        return paths
    print("  issuing a loopback server certificate", file=out)
    csr = os.path.join(paths["dir"], "loopback.csr")
    ext = os.path.join(paths["dir"], "loopback.ext")
    # An IP SAN is not optional here: the browser is pointed at a literal
    # 127.0.0.1, and a certificate carrying only DNS:localhost does not match it.
    with open(ext, "w", encoding="utf-8") as fh:
        fh.write("basicConstraints=critical,CA:FALSE\n"
                 "keyUsage=critical,digitalSignature,keyEncipherment\n"
                 "extendedKeyUsage=serverAuth\n"
                 "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:0:0:0:0:0:0:0:1\n")
    try:
        _openssl("req", "-newkey", "rsa:2048", "-nodes",
                 "-keyout", paths["key"], "-out", csr, "-subj", "/CN=localhost")
        _openssl("x509", "-req", "-in", csr, "-sha256", "-days", str(LEAF_DAYS),
                 "-CA", paths["ca_crt"], "-CAkey", paths["ca_key"],
                 "-CAcreateserial", "-extfile", ext, "-out", paths["crt"])
    finally:
        for tmp in (csr, ext):
            try:
                os.unlink(tmp)
            except OSError:
                pass
    os.chmod(paths["key"], 0o600)
    # Prove the constraints do not reject our own leaf BEFORE a browser does:
    # a name-constrained CA that fails its own chain would show up only as an
    # unexplained interstitial, long after this ran.
    _openssl("verify", "-CAfile", paths["ca_crt"], paths["crt"])
    return paths


def ssl_context(state_dir: str, out=sys.stdout) -> ssl.SSLContext:
    paths = ensure_leaf(state_dir, out)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(paths["crt"], paths["key"])
    return ctx


# ── trusting it, in this user's own stores only ───────────────────────────────

def nss_stores() -> list[str]:
    """Every NSS database belonging to THIS user, as `certutil -d` arguments.

    Chrome/Chromium share ~/.pki/nssdb; Firefox keeps one per profile. All are
    user-owned, which is what keeps this tool root-free — the system bundle in
    /etc is never touched.
    """
    stores = []
    chrome = os.path.expanduser("~/.pki/nssdb")
    if os.path.isdir(chrome):
        stores.append(chrome)
    for db in sorted(glob.glob(os.path.expanduser(
            "~/.mozilla/firefox/*/cert9.db"))):
        stores.append(os.path.dirname(db))
    for db in sorted(glob.glob(os.path.expanduser(
            "~/.thunderbird/*/cert9.db"))):
        stores.append(os.path.dirname(db))
    return stores


def _certutil(*argv: str) -> subprocess.CompletedProcess:
    return subprocess.run(("certutil",) + argv, text=True, capture_output=True)


def is_trusted(store: str) -> bool:
    return _certutil("-d", f"sql:{store}", "-L",
                     "-n", CA_NICKNAME).returncode == 0


def cmd_trust(args, out=sys.stdout) -> int:
    if not shutil.which("certutil"):
        raise ViewError(
            "certutil not found — install nss-utils (Gentoo: dev-libs/nss, "
            "Debian: libnss3-tools). Without it the CA can be minted but not "
            "installed; you would have to add it in the browser's own "
            "certificate manager as a trusted authority.")
    paths = ensure_leaf(args.state, out)
    stores = nss_stores()
    if not stores:
        raise ViewError("no NSS trust store found under ~/.pki or ~/.mozilla — "
                        "start the browser once so it creates its profile")
    installed = 0
    for store in stores:
        if is_trusted(store):
            print(f"  already trusted: {store}", file=out)
            continue
        # "C,," = trusted CA for TLS servers only. Not "CT,C,C": this key has no
        # business signing email or code, and the constraint above is about
        # keeping its blast radius small.
        res = _certutil("-d", f"sql:{store}", "-A", "-t", "C,,",
                        "-n", CA_NICKNAME, "-i", paths["ca_crt"])
        if res.returncode != 0:
            print(f"  could NOT install into {store}: "
                  f"{(res.stderr or '').strip()}", file=out)
            continue
        installed += 1
        print(f"  trusted in {store}", file=out)
    print("", file=out)
    print(f"  CA: {paths['ca_crt']}", file=out)
    print("  constrained to localhost, 127.0.0.0/8 and ::1 — it cannot vouch "
          "for anything else.", file=out)
    if installed:
        print("  RESTART the browser: NSS reads its trust store at startup.",
              file=out)
    print("  remove it any time with `hugmesh-view.py untrust`.", file=out)
    return 0


def cmd_untrust(args, out=sys.stdout) -> int:
    if not shutil.which("certutil"):
        raise ViewError("certutil not found — nothing this tool can remove")
    removed = 0
    for store in nss_stores():
        if not is_trusted(store):
            continue
        res = _certutil("-d", f"sql:{store}", "-D", "-n", CA_NICKNAME)
        if res.returncode == 0:
            removed += 1
            print(f"  removed from {store}", file=out)
        else:
            print(f"  could NOT remove from {store}: "
                  f"{(res.stderr or '').strip()}", file=out)
    if not removed:
        print("  the CA was not installed in any store.", file=out)
    else:
        print("  RESTART the browser for it to take effect.", file=out)
    print(f"  the key material itself is still in {cert_dir(args.state)}; "
          f"delete that directory to destroy it.", file=out)
    return 0


def trust_warning(state_dir: str) -> str:
    """One line for `up` when the CA is minted but nothing trusts it yet."""
    stores = nss_stores()
    if stores and not any(is_trusted(s) for s in stores):
        return ("the local CA is not trusted by any browser here yet — run "
                "`hugmesh-view.py trust` (no root needed) or expect a warning")
    return ""


# ── the proxy ─────────────────────────────────────────────────────────────────

class NoFollowRedirects(urllib.request.HTTPRedirectHandler):
    """Hand a 3xx back to the BROWSER instead of chasing it inside the proxy.

    `urllib.request.urlopen` installs an HTTPRedirectHandler by default, so the
    proxy used to follow the upstream's redirects ITSELF — and that default is
    catastrophic here for the reason this whole tool exists. The `Location:` an
    SSO bounce sends back names a real domain (`https://hugmesh.net/login/`),
    and problem 2 in the header of this file is that those names DO NOT RESOLVE
    on this workstation. The follow therefore died inside `_relay` with
    `[Errno -5] No address associated with hostname`, the door answered 502, and
    it happened mid-login where it reads as a broken app rather than as a proxy
    that just tried to walk out to the internet on the user's behalf.

    It also made the `Location:` rewrite in `_relay` DEAD CODE: a redirect that
    has already been followed has no Location left to rewrite, so the one header
    the rewrite exists for was the one header it never saw.

    Returning None makes the redirect fall through to `http_error_default`,
    which raises HTTPError — already caught below with its headers and body
    intact — so the 3xx reaches the rewrite and then the browser. The browser is
    the RIGHT thing to follow it: it re-resolves against the rewritten loopback
    authority, which is exactly the SSO bounce this tool promises to keep on
    127.0.0.1.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def make_handler(entry: Entry, upstream: str, hostmap: dict[str, str],
                 reverse: dict[str, str], verbose: bool):
    """One handler class per door. Closure, not globals: the tool serves several
    doors in one process, and a module-level ARGS would make them share a Host.
    """
    class Proxy(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "hugmesh-view"
        timeout = 65

        def log_message(self, fmt, *a):  # noqa: A003 - base class name
            if verbose:
                sys.stderr.write(f"  [{entry.name}] {self.command} {self.path}\n")

        def _headers_up(self):
            out = {}
            for k, v in self.headers.items():
                lk = k.lower()
                if lk in HOP or lk == "host":
                    continue
                if lk == "accept-encoding":
                    continue          # forced to identity below
                if lk in ("referer", "origin"):
                    v = rewrite_upward(v, reverse)
                out[k] = v
            # This proxy REWRITES bodies, so it must never be handed a br/zstd
            # stream it cannot decode: the rewrite would silently no-op and the
            # browser would get a body whose Content-Encoding we just stripped.
            out["Accept-Encoding"] = "identity"
            if entry.host:
                out["Host"] = entry.host
                out["X-Forwarded-Host"] = entry.host
                out["X-Forwarded-Proto"] = "https"
            return out

        def _relay(self, body=None):
            url = upstream.rstrip("/") + self.path
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE   # self-signed dev cert, by design
            req = urllib.request.Request(url, data=body,
                                         headers=self._headers_up(),
                                         method=self.command)
            # build_opener, NOT urlopen: urlopen's default opener follows
            # redirects inside the proxy, which cannot work here and hid the
            # Location rewrite below. See NoFollowRedirects.
            opener = urllib.request.build_opener(
                urllib.request.HTTPSHandler(context=ctx), NoFollowRedirects)
            try:
                resp = opener.open(req, timeout=60)
                status, hdrs, payload = resp.status, resp.headers, resp.read()
            except urllib.error.HTTPError as exc:      # 3xx/4xx/5xx: bodies too
                status, hdrs, payload = exc.code, exc.headers, exc.read()
            except Exception as exc:                   # upstream down / TLS fail
                self._fail(f"hugmesh-view [{entry.name}]: upstream {url} "
                           f"failed: {exc}\n")
                return

            payload = decompress(payload, hdrs.get("Content-Encoding"))
            if is_textual(hdrs.get("Content-Type")):
                try:
                    payload = rewrite_text(payload.decode("utf-8"),
                                           hostmap).encode("utf-8")
                except UnicodeDecodeError:
                    pass

            bodyless = self.command == "HEAD" or status in (204, 304)
            self.send_response(status)
            for k, v in hdrs.items():
                lk = k.lower()
                if lk in STRIP_DOWN:
                    continue
                if lk == "location":
                    v = rewrite_text(v, hostmap)
                elif lk == "set-cookie":
                    v = rewrite_cookie(v)
                elif lk in ("content-security-policy",
                            "content-security-policy-report-only"):
                    v = rewrite_csp(v, hostmap)
                    if not v.strip():
                        continue
                self.send_header(k, v)
            if not bodyless:
                self.send_header("Content-Length", str(len(payload)))
            elif status not in (204, 304):
                self.send_header("Content-Length", "0")
            self.end_headers()
            if not bodyless:
                self.wfile.write(payload)

        def _fail(self, message: str):
            msg = message.encode()
            self.send_response(502)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)

        def _body(self):
            n = int(self.headers.get("Content-Length") or 0)
            return self.rfile.read(n) if n else None

        def do_GET(self):     self._relay()                 # noqa: E704
        def do_HEAD(self):    self._relay()                 # noqa: E704
        def do_POST(self):    self._relay(self._body())     # noqa: E704
        def do_PUT(self):     self._relay(self._body())     # noqa: E704
        def do_PATCH(self):   self._relay(self._body())     # noqa: E704
        def do_DELETE(self):  self._relay(self._body())     # noqa: E704
        def do_OPTIONS(self): self._relay()                 # noqa: E704

    return Proxy


def make_redirect_handler(entry: Entry):
    """Answers a PLAIN-http request on a door's https port with a 308.

    Without this the tool would simply refuse the connection and the browser
    would show a bare protocol error, which reads as "the mesh is down" rather
    than "wrong scheme" — and every bookmark and printed URL from the plaintext
    era would break silently. 308 rather than 301 because it preserves the
    method and body, so a form post that guessed http still completes.
    """
    class Redirect(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "hugmesh-view"

        def log_message(self, fmt, *a):  # noqa: A003 - base class name
            pass

        def _go(self):
            self.send_response(308)
            self.send_header("Location", f"https://{LOOPBACK}:{entry.port}"
                                         f"{self.path}")
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True

        do_GET = do_HEAD = do_POST = do_PUT = _go                # noqa: E305
        do_PATCH = do_DELETE = do_OPTIONS = _go

    return Redirect


class TLSServer(http.server.ThreadingHTTPServer):
    """An https door that still answers http on the same port.

    The scheme is decided by PEEKING one byte (0x16 = TLS handshake) and then
    choosing a handler class. That peek — and the handshake — happen in the
    WORKER thread, never in the accept loop: a browser preconnect that opens a
    socket and sends nothing is routine, and doing this in `get_request()` would
    let one such socket stall every other connection until it timed out.
    """

    daemon_threads = True

    def __init__(self, addr, handler, ssl_ctx: ssl.SSLContext,
                 redirect_handler, verbose: bool = False):
        self.ssl_ctx = ssl_ctx
        self.redirect_handler = redirect_handler
        self.verbose = verbose
        super().__init__(addr, handler)

    def finish_request(self, request, client_address):
        try:
            request.settimeout(30)
            head = request.recv(1, socket.MSG_PEEK)
        except OSError:
            return
        if head != b"\x16":
            self.redirect_handler(request, client_address, self)
            return
        try:
            request = self.ssl_ctx.wrap_socket(request, server_side=True)
        except (ssl.SSLError, OSError):
            return          # a scan, a stale session ticket, a closed tab
        try:
            self.RequestHandlerClass(request, client_address, self)
        finally:
            try:
                request.close()
            except OSError:
                pass

    def shutdown_request(self, request):
        # wrap_socket() DETACHES the socket we were handed, so the base class's
        # shutdown() on it raises EBADF. The real socket is closed above.
        try:
            super().shutdown_request(request)
        except OSError:
            pass

    def handle_error(self, request, client_address):
        # A browser closing a tab mid-response is not an error worth a traceback
        # on an operator's terminal; -v still shows them.
        if self.verbose:
            super().handle_error(request, client_address)


# ── the helper processes each lane needs ──────────────────────────────────────

@dataclass
class Child:
    """A helper process this session owns, and enough to kill it SAFELY.

    `marker` is what must appear in /proc/<pid>/cmdline before anything sends a
    signal: pids are reused, and a stale state file plus a reused pid is how a
    cleanup sweep turns into killing an unrelated process.
    """
    name: str
    kind: str
    pid: int
    marker: str
    port: int = 0


def _kubectl_argv(env) -> list[str]:
    return shlex.split(env.get("HUGMESH_VIEW_KUBECTL") or "kubectl")


def _ssh_bin(env) -> str:
    return env.get("HUGMESH_VIEW_SSH") or "ssh"


def start_port_forward(entry: Entry, ns: str, svc: str, remote: int, env,
                       timeout: float = 25.0):
    """`kubectl port-forward` for a ClusterIP-only service, on an EPHEMERAL port.

    kubectl is asked for `:<remote>` (empty local port) and its own
    `Forwarding from 127.0.0.1:NNNNN -> <remote>` line is parsed, rather than
    picking a port here and hoping: that closes the bind/exec race entirely and
    keeps the browser-facing port (catalog policy) separate from this internal
    hop (an implementation detail nobody should have to configure).
    """
    argv = _kubectl_argv(env) + ["port-forward", "-n", ns, f"svc/{svc}",
                                 f":{remote}"]
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True,
                            start_new_session=True)
    deadline = time.time() + timeout
    local = 0
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            break
        m = re.search(r"Forwarding from 127\.0\.0\.1:(\d+)", line)
        if m:
            local = int(m.group(1))
            break
    if not local:
        _reap(proc)
        raise ViewError(
            f"{entry.name}: `kubectl port-forward -n {ns} svc/{svc}` never "
            f"reported a local port (is the service up? is the context right?)")
    # Drain the rest so a chatty kubectl cannot fill its pipe and block.
    threading.Thread(target=_drain, args=(proc,), daemon=True).start()
    if not wait_for_port(local, deadline, proc):
        _reap(proc)
        raise ViewError(f"{entry.name}: port-forward to {ns}/{svc}:{remote} "
                        f"never accepted on 127.0.0.1:{local}")
    child = Child(name=entry.name, kind="port-forward", pid=proc.pid,
                  marker="port-forward", port=local)
    return proc, child


def _drain(proc):
    try:
        for _ in proc.stdout:
            pass
    except Exception:
        pass


def _reap(proc):
    try:
        proc.terminate()
        proc.wait(timeout=5)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass


def _studio_emulation():
    """Import studio's Qt-free emulation facade, or explain why we cannot.

    Imported LAZILY and only for the device lane: the kind and compose lanes
    must keep working in a checkout whose studio package is absent or broken.
    """
    studio = os.path.join(REPO, "studio")
    if studio not in sys.path:
        sys.path.insert(0, studio)
    try:
        from hugmesh_studio.core import emulation, qemu_devices
    except ImportError as exc:                       # pragma: no cover - env
        raise ViewError(f"device lane needs the studio package ({studio}): "
                        f"{exc}") from None
    return emulation, qemu_devices


def resolve_device(label: str, env):
    """The LIVE device record a `device+https://…` row points at.

    Fails closed on a mesh that is not up. That is the honest answer and the
    useful one: `state=stopped` for every device means the ssh port in the
    record is a port nothing is behind, and a tunnel to it would 'succeed' into
    a refused connection the browser reports as an empty page.
    """
    emulation, qemu_devices = _studio_emulation()
    work = env.get("HUGMESH_VIEW_WORK") or qemu_devices.default_work_dir(REPO)
    devices = qemu_devices.discover_devices(work)
    if not devices:
        raise ViewError(f"device lane: no device records under {work} — boot "
                        f"the mesh first (`make mesh-emu-up`)")
    running = [d for d in devices if d.is_running]
    if not running:
        states = ", ".join(f"{d.label}={d.state or 'unknown'}" for d in devices)
        raise ViewError(f"device lane: no RUNNING emulated device ({states}) — "
                        f"boot one with `make mesh-emu-up`")
    if label == "@gateway":
        for role in GATEWAY_ROLES:
            for dev in running:
                if dev.label.rsplit("/", 1)[-1] == role:
                    return emulation, dev
        if len(running) == 1:
            return emulation, running[0]
        raise ViewError(
            "device lane: @gateway is ambiguous — running devices are "
            + ", ".join(d.label for d in running)
            + "; name one in the catalog (device+https://<label>)")
    for dev in running:
        if dev.label == label:
            return emulation, dev
    raise ViewError(f"device lane: '{label}' is not running (running: "
                    + ", ".join(d.label for d in running) + ")")


def start_device_tunnel(entry: Entry, label: str, env, timeout: float = 25.0):
    """`ssh -L <ephemeral>:127.0.0.1:443` into a live emulated device.

    The argv comes from hugmesh_studio.core.emulation.web_tunnel_argv — studio's
    ONE web-tunnel author (PR #87) — so this tool cannot spell a forward that
    differs from the one the Studio's own button uses. Only argv[0] is
    substitutable, and only so the hermetic test can put a fake ssh on PATH.
    """
    emulation, dev = resolve_device(label, env)
    local = free_port()
    planned = _Planned(label=dev.label, ui_port=local)
    argv = list(emulation.web_tunnel_argv(dev, planned))
    argv[0] = _ssh_bin(env)
    proc = subprocess.Popen(argv, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, start_new_session=True)
    if not wait_for_port(local, time.time() + timeout, proc):
        _reap(proc)
        raise ViewError(f"{entry.name}: ssh tunnel to {dev.label} never "
                        f"accepted on 127.0.0.1:{local}")
    child = Child(name=entry.name, kind="ssh-tunnel", pid=proc.pid,
                  marker="-L", port=local)
    return proc, child


@dataclass
class _Planned:
    """The two fields web_tunnel_argv reads off a planned device.

    Duck-typed rather than a real PlannedDevice: this tool allocates the tunnel
    port itself (the catalog owns the BROWSER port, not the tunnel port), and
    constructing a whole mesh plan to carry two values would drag the planner,
    a build session and a discovery pass into a tool that needs none of them.
    """
    label: str
    ui_port: int


# ── session state (so a crashed run cannot leave a port squatted) ─────────────

def state_file(state_dir: str) -> str:
    return os.path.join(state_dir, "session.json")


def read_session(state_dir: str):
    try:
        with open(state_file(state_dir), encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def write_session(state_dir: str, data: dict):
    os.makedirs(state_dir, exist_ok=True)
    tmp = state_file(state_dir) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
    os.replace(tmp, state_file(state_dir))


def cmdline(pid: int) -> str:
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as fh:
            return fh.read().decode("utf-8", "replace").replace("\0", " ")
    except OSError:
        return ""


def pid_matches(pid: int, marker: str) -> bool:
    """Alive AND still the process we recorded.

    Both halves matter: `os.kill(pid, 0)` alone would happily confirm a REUSED
    pid, and a sweep that trusts it kills whatever inherited the number.
    """
    if pid <= 0:
        return False
    cmd = cmdline(pid)
    if cmd:
        return marker in cmd
    try:                                    # /proc unreadable: fall back
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def kill_pid(pid: int, marker: str) -> bool:
    if not pid_matches(pid, marker):
        return False
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        return False
    for _ in range(50):
        if not pid_matches(pid, marker):
            return True
        time.sleep(0.1)
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass
    return True


def sweep(state_dir: str, out=sys.stdout) -> tuple[int, bool]:
    """Kill a previous session's leftovers. Returns (killed, owner_alive).

    THE failure mode this exists for: the tool dies (crash, closed laptop, kill
    -9) and its `kubectl port-forward` children survive, holding the ports. The
    next run then binds nothing, the browser gets a door pointed at LAST run's
    service, and there is no error anywhere. So every run sweeps first, and a
    still-live owner is reported rather than fought over.
    """
    sess = read_session(state_dir)
    if not sess:
        return 0, False
    owner = int(sess.get("pid") or 0)
    if pid_matches(owner, sess.get("marker") or "hugmesh-view"):
        return 0, True
    killed = 0
    for child in sess.get("children") or []:
        if kill_pid(int(child.get("pid") or 0), child.get("marker") or ""):
            killed += 1
            print(f"  swept stale {child.get('kind')} for '{child.get('name')}' "
                  f"(pid {child.get('pid')})", file=out)
    try:
        os.unlink(state_file(state_dir))
    except OSError:
        pass
    return killed, False


# ── commands ──────────────────────────────────────────────────────────────────

def describe_upstream(entry: Entry) -> str:
    if entry.host:
        return f"{entry.upstream} (Host: {entry.host})"
    return entry.upstream


def print_table(entries: list[Entry], out=sys.stdout, header: str = ""):
    if header:
        print(header, file=out)
    rows = [("NAME", "LANE", "OPEN IN BROWSER", "UPSTREAM", "PORT OVERRIDE")]
    rows += [(e.name, e.lane, e.url, describe_upstream(e), env_var_for(e.name))
             for e in entries]
    widths = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
    for i, row in enumerate(rows):
        print("  " + "  ".join(c.ljust(widths[j])
                               for j, c in enumerate(row)).rstrip(), file=out)
        if i == 0:
            print("  " + "  ".join("-" * w for w in widths), file=out)


def cmd_list(args, entries: list[Entry], out=sys.stdout) -> int:
    chosen = entries if (not args.lane and not args.only) else \
        select(entries, args.lane or "kind", args.only)
    print_table(chosen, out, header="hugmesh-view — mapped front doors "
                                    f"({args.catalog}):")
    print("", file=out)
    print("  Add a domain: append a row to the catalog. Move a port: export the "
          "PORT OVERRIDE var.", file=out)
    return 0


def open_browser(url: str, env) -> None:
    """Hand the first door to a browser, if one is asked for.

    `$BROWSER` first (the operator's own choice), then firefox, then the usual
    chromium spellings — the tool never assumes Chrome exists, because on this
    workstation it does not.
    """
    candidates = []
    if env.get("BROWSER"):
        candidates.append(env["BROWSER"])
    candidates += ["firefox", "chromium", "chromium-browser", "google-chrome",
                   "google-chrome-stable"]
    for cand in candidates:
        argv = shlex.split(cand) + [url]
        try:
            subprocess.Popen(argv, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
            print(f"  opened {url} in {argv[0]}")
            return
        except (OSError, ValueError):
            continue
    print(f"  no browser found — open {url} yourself")


def cmd_up(args, entries: list[Entry], env, out=sys.stdout) -> int:
    chosen = select(entries, args.lane or "kind", args.only)

    killed, owner_alive = sweep(args.state, out)
    if owner_alive:
        sess = read_session(args.state) or {}
        raise ViewError(f"a hugmesh-view session is already running "
                        f"(pid {sess.get('pid')}) — `make view-stop` first")
    if killed:
        print(f"  ({killed} leftover helper(s) from a previous run swept)",
              file=out)

    problems = port_collisions(chosen)
    if problems:
        raise ViewError("port collisions:\n    " + "\n    ".join(problems))

    if args.background:
        return _spawn_background(args, out)

    servers, children, procs = [], [], []
    reverse = build_reverse(chosen)
    ctx = ssl_context(args.state, out)

    def shutdown(*_a):
        for srv in servers:
            try:
                srv.shutdown()
            except Exception:
                pass
        for proc in procs:
            _reap(proc)
        try:
            os.unlink(state_file(args.state))
        except OSError:
            pass

    try:
        for entry in chosen:
            upstream, child, proc = _prepare(entry, env)
            if child:
                children.append(child)
            if proc:
                procs.append(proc)
            # Per-door, not once for the whole lane: a row that shares its host
            # with another row must rewrite its own responses to its OWN port.
            handler = make_handler(entry, upstream,
                                   build_hostmap(chosen, entry), reverse,
                                   args.verbose)
            srv = TLSServer((LOOPBACK, entry.port), handler, ctx,
                            make_redirect_handler(entry), args.verbose)
            servers.append(srv)
            threading.Thread(target=srv.serve_forever, daemon=True).start()
    except Exception:
        shutdown()
        raise

    write_session(args.state, {
        "pid": os.getpid(),
        "marker": "hugmesh-view",
        "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "lane": args.lane or "kind",
        "children": [vars(c) for c in children],
        "doors": [{"name": e.name, "port": e.port, "url": e.url}
                  for e in chosen],
    })

    print_table(chosen, out, header="hugmesh-view is serving:")
    print("", file=out)
    print("  HTTPS on 127.0.0.1 under this machine's own loopback-only CA: a "
          "real\n  secure context, no DNS, no root — and http on the same port "
          "308s to https.", file=out)
    warning = trust_warning(args.state)
    if warning:
        print(f"  NOTE: {warning}", file=out)
    if args.open:
        open_browser(chosen[0].url, env)
    print("  Ctrl-C to stop.", file=out)
    out.flush()

    signal.signal(signal.SIGTERM, lambda *_a: (shutdown(), sys.exit(0)))
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        print("\n  stopping…", file=out)
    finally:
        shutdown()
    return 0


def _prepare(entry: Entry, env):
    """Whatever this row needs standing up before a proxy can front it."""
    m = _UPSTREAM_DIRECT.match(entry.upstream)
    if m:
        return entry.upstream.rstrip("/"), None, None
    m = _UPSTREAM_K8S.match(entry.upstream)
    if m:
        proc, child = start_port_forward(entry, m.group(2), m.group(3),
                                         int(m.group(4)), env)
        return f"{m.group(1)}://{LOOPBACK}:{child.port}", child, proc
    m = _UPSTREAM_DEVICE.match(entry.upstream)
    if m:
        proc, child = start_device_tunnel(entry, m.group(2), env)
        return f"{m.group(1)}://{LOOPBACK}:{child.port}", child, proc
    raise ViewError(f"{entry.name}: unrecognised upstream '{entry.upstream}' — "
                    f"expected http(s)://H:P, k8s+http(s)://NS/SVC:P or "
                    f"device+https://LABEL")


def _spawn_background(args, out=sys.stdout) -> int:
    """Re-exec this tool detached, then wait for it to report READY.

    Waiting on the STATE FILE rather than on a sleep is what makes `make view`
    honest: the table it prints is the table the running session actually
    bound, and a child that died during bring-up is reported with its log
    instead of a green message and no doors.
    """
    os.makedirs(args.state, exist_ok=True)
    log = os.path.join(args.state, "view.log")
    argv = [sys.executable, os.path.abspath(__file__), "up",
            "--catalog", args.catalog, "--state", args.state]
    if args.lane:
        argv += ["--lane", args.lane]
    for name in args.only:
        argv += ["--only", name]
    if args.verbose:
        argv.append("--verbose")
    with open(log, "w", encoding="utf-8") as fh:
        proc = subprocess.Popen(argv, stdout=fh, stderr=subprocess.STDOUT,
                                start_new_session=True)
    deadline = time.time() + 60
    while time.time() < deadline:
        sess = read_session(args.state)
        if sess and int(sess.get("pid") or 0) == proc.pid:
            print(f"  hugmesh-view running in the background (pid {proc.pid}); "
                  f"log: {log}", file=out)
            for door in sess.get("doors") or []:
                print(f"    {door['name']:<16} {door['url']}", file=out)
            print("  stop it with `make view-stop`.", file=out)
            return 0
        if proc.poll() is not None:
            try:
                with open(log, encoding="utf-8") as fh:
                    tail = fh.read().strip().splitlines()[-15:]
            except OSError:
                tail = []
            raise ViewError("background session exited during bring-up:\n    "
                            + "\n    ".join(tail))
        time.sleep(0.2)
    _reap(proc)
    raise ViewError(f"background session never became ready; see {log}")


def cmd_stop(args, out=sys.stdout) -> int:
    sess = read_session(args.state)
    if not sess:
        print("  no hugmesh-view session recorded — nothing to stop.", file=out)
        return 0
    stopped = 0
    for child in sess.get("children") or []:
        if kill_pid(int(child.get("pid") or 0), child.get("marker") or ""):
            stopped += 1
            print(f"  stopped {child.get('kind')} for '{child.get('name')}'",
                  file=out)
    if kill_pid(int(sess.get("pid") or 0), sess.get("marker") or "hugmesh-view"):
        stopped += 1
        print(f"  stopped hugmesh-view (pid {sess.get('pid')})", file=out)
    try:
        os.unlink(state_file(args.state))
    except OSError:
        pass
    if not stopped:
        print("  session record was stale — nothing was still running.", file=out)
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="hugmesh-view",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("command",
                   choices=("list", "up", "stop", "trust", "untrust"))
    p.add_argument("--catalog", default=os.environ.get("HUGMESH_VIEW_TSV")
                   or DEFAULT_CATALOG,
                   help="TSV of doors (default: scripts/hugmesh-view.tsv)")
    p.add_argument("--lane", default="",
                   help="kind | compose | device (default: kind)")
    p.add_argument("--only", action="append", default=[],
                   help="serve just this row (repeatable); wins over --lane")
    p.add_argument("--state", default=os.environ.get("HUGMESH_VIEW_STATE")
                   or DEFAULT_STATE,
                   help="where the session's pids are recorded")
    p.add_argument("--background", action="store_true",
                   help="detach and return; stop it with `stop`")
    p.add_argument("--open", action="store_true",
                   help="launch a browser at the first door")
    p.add_argument("--verbose", action="store_true")
    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    env = os.environ
    try:
        if args.command == "stop":
            return cmd_stop(args)
        if args.command == "trust":
            return cmd_trust(args)
        if args.command == "untrust":
            return cmd_untrust(args)
        entries = load_entries(args.catalog, env)
        if args.command == "list":
            return cmd_list(args, entries)
        return cmd_up(args, entries, env)
    except ViewError as exc:
        print(f"hugmesh-view: {exc}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())

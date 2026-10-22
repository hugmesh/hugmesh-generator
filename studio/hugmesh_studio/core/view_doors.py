"""The `make view` door catalog, read the way the Studio needs it — and NOTHING more.

WHY A SECOND PARSER. Every loopback door the browser may safely be pointed at —
which host header, which upstream, which 127.0.0.1 port — is POLICY, and it already
lives in one file: ``scripts/hugmesh-view.tsv``. The only other reader of that file
is ``scripts/hugmesh-view.py``, a 1500-line tool that also owns the TLS server, the
loopback CA, the port-forward children and the session sweep; importing it to reach
its 40-line parser would bind the GUI to a script path and drag ``http.server`` +
``ssl`` into every Studio import. So this module re-spells JUST the parser, under the
same six-column fail-closed contract, and ``tests/test_view_doors.py`` loads the
script BY PATH at test time and asserts the two agree row-for-row on the shipped
catalog. That drift test is what makes a second parser acceptable: the moment the
script's contract changes, the test names it.

WHAT IS DELIBERATELY NOT HERE. This module never starts a door, never spawns a
``kubectl port-forward`` and never binds a port. ``hugmesh-view.py`` owns a
session-owner guard (one ``up`` per state dir) and a sweep of its own children; a
second forwarder started from the GUI would fight it. The Studio only ever ASKS
(``live_doors``) and, on an explicit button press, runs the script itself.

Qt-free by construction (pinned by ``test_module_is_qt_free``): the monitor's core
must be unit-testable without a binding, and CI installs none.
"""
from __future__ import annotations

import json
import os
import re
import socket
from dataclasses import dataclass

#: Repo-relative paths — the same two the script defaults to (``DEFAULT_CATALOG``,
#: ``DEFAULT_STATE``), and the same env overrides its argparse honours, so what the
#: Studio reads is what ``make view`` served.
CATALOG_REL = os.path.join("scripts", "hugmesh-view.tsv")
#: The generated per-domain rows (core/look_serving.py); read only with the shipped
#: catalog, the script's GENERATED_CATALOG rule.
GENERATED_REL = os.path.join("tests", "stack", ".looks", "view.tsv")
STATE_REL = os.path.join("out", "hugmesh-view")
CATALOG_ENV = "HUGMESH_VIEW_TSV"
STATE_ENV = "HUGMESH_VIEW_STATE"

#: The marker a background session writes beside its pid; a pid whose cmdline no
#: longer carries it has been REUSED by something else and must not count as live.
SESSION_MARKER = "hugmesh-view"

LOOPBACK = "127.0.0.1"

_ENV_REF = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}")
_UPSTREAM_K8S = re.compile(r"^k8s\+(https?)://([A-Za-z0-9-]+)/([A-Za-z0-9.-]+):(\d+)$")
_UPSTREAM_DIRECT = re.compile(r"^(https?)://([^/\s]+?)(?::(\d+))?/*$")


class ViewDoorError(Exception):
    """A malformed catalog row or an unset ``${VAR}`` — something the operator fixes."""


@dataclass(frozen=True)
class ViewDoor:
    """One catalog row: a door ``make view`` CAN serve on ``https://127.0.0.1:<port>``."""
    name: str
    lane: str
    host: str          # "" when the door does not route by name
    upstream: str      # env-expanded; the scheme picks the mechanism
    port: int          # the loopback port the BROWSER opens
    path: str          # "/…" — the path worth opening

    @property
    def url(self) -> str:
        return f"https://{LOOPBACK}:{self.port}{self.path}"

    @property
    def k8s_target(self) -> tuple[str, str, str, int] | None:
        """``(scheme, namespace, service, port)`` for a ``k8s+`` upstream, else None."""
        m = _UPSTREAM_K8S.match(self.upstream)
        if not m:
            return None
        return m.group(1), m.group(2), m.group(3), int(m.group(4))

    @property
    def direct_target(self) -> tuple[str, str, int | None] | None:
        """``(scheme, host, port)`` for a plain ``http(s)://`` upstream, else None."""
        m = _UPSTREAM_DIRECT.match(self.upstream)
        if not m:
            return None
        return m.group(1), m.group(2), (int(m.group(3)) if m.group(3) else None)


def env_var_for(name: str) -> str:
    """The port-override env var for a row: ``app`` -> ``HUGMESH_VIEW_PORT_APP``."""
    slug = re.sub(r"[^A-Za-z0-9]", "_", name).upper()
    return f"HUGMESH_VIEW_PORT_{slug}"


def expand(text: str, env) -> str:
    """``${VAR}`` / ``${VAR:-default}`` from ``env``. Nothing else — never a shell.

    An unset ``${VAR}`` with no default RAISES rather than expanding to "": a door
    that reads ``https://127.0.0.1:`` fails at connect time with nothing pointing back
    at the typo, so the parser fails closed instead (the script's own rule)."""
    def one(m):
        val = env.get(m.group(1))
        if val is not None and val != "":
            return val
        if m.group(2) is not None:
            return m.group(2)
        raise ViewDoorError(f"{m.group(0)} is unset and has no default")
    return _ENV_REF.sub(one, text)


def parse(text: str, env=None) -> list[ViewDoor]:
    """The six-column contract, fail-closed — the script's ``parse_catalog`` re-spelt.

    A contract that silently accepted five columns would map a door to whatever the
    shifted columns happened to spell, which is worse than no door at all."""
    env = os.environ if env is None else env
    doors: list[ViewDoor] = []
    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) != 6:
            raise ViewDoorError(
                f"catalog line {lineno}: expected 6 TAB-separated columns, got "
                f"{len(cols)}")
        name, lane, host, upstream, port_s, path = (c.strip() for c in cols)
        if not name or not lane or not upstream or not port_s:
            raise ViewDoorError(f"catalog line {lineno}: empty name/lane/upstream/port")
        try:
            upstream = expand(upstream, env)
            host = expand(host, env)
        except ViewDoorError as exc:
            raise ViewDoorError(f"catalog line {lineno}: {exc}") from None
        override = env.get(env_var_for(name))
        chosen = override if override else port_s
        try:
            port = int(chosen)
        except ValueError:
            raise ViewDoorError(
                f"catalog line {lineno}: '{chosen}' is not a port number") from None
        if not 1 <= port <= 65535:
            raise ViewDoorError(f"catalog line {lineno}: port {port} out of range")
        doors.append(ViewDoor(
            name=name, lane=lane,
            host="" if host in ("-", "") else host,
            upstream=upstream, port=port,
            path="/" if path in ("-", "") else path))
    names = [d.name for d in doors]
    dupes = sorted({n for n in names if names.count(n) > 1})
    if dupes:
        raise ViewDoorError(f"catalog: duplicate row name(s): {', '.join(dupes)}")
    return doors


def catalog_path(generator_dir: str, env=None) -> str:
    env = os.environ if env is None else env
    return env.get(CATALOG_ENV) or os.path.join(generator_dir, CATALOG_REL)


def state_dir(generator_dir: str, env=None) -> str:
    env = os.environ if env is None else env
    return env.get(STATE_ENV) or os.path.join(generator_dir, STATE_REL)


def load(generator_dir: str, env=None) -> list[ViewDoor]:
    """The shipped catalog (or the ``HUGMESH_VIEW_TSV`` override), parsed. Raises
    ``ViewDoorError`` on a missing or malformed file — the caller degrades to
    "no door + why", never to a guessed port."""
    path = catalog_path(generator_dir, env)
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        raise ViewDoorError(f"catalog not readable: {path}: {exc}") from None
    return parse(text, env)


def load_with_generated(generator_dir: str, env=None) -> list[ViewDoor]:
    """:func:`load` plus the generated per-domain rows when the catalog is the shipped
    one and the file exists — what ``make view`` serves (the script's
    ``load_entries``). A row name in both is refused, never replaced."""
    doors = load(generator_dir, env)
    if (os.path.abspath(catalog_path(generator_dir, env))
            != os.path.abspath(os.path.join(generator_dir, CATALOG_REL))):
        return doors
    path = os.path.join(generator_dir, GENERATED_REL)
    if not os.path.isfile(path):
        return doors
    try:
        with open(path, encoding="utf-8") as fh:
            extra = parse(fh.read(), env)
    except OSError as exc:
        raise ViewDoorError(f"generated rows not readable: {path}: {exc}") from None
    except ViewDoorError as exc:
        raise ViewDoorError(f"{path}: {exc}") from None
    names = [d.name for d in doors + extra]
    dupes = sorted({n for n in names if names.count(n) > 1})
    if dupes:
        raise ViewDoorError(f"{path}: row name(s) already in the catalog: "
                            f"{', '.join(dupes)}")
    return doors + extra


def live_session(generator_dir: str, env=None) -> dict:
    """The background session's record (``out/hugmesh-view/session.json``), or ``{}``
    when there is none or it is unreadable. PRESENCE IS NOT LIVENESS — a crashed
    session leaves the file behind; see ``live_doors``."""
    path = os.path.join(state_dir(generator_dir, env), "session.json")
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _cmdline(pid: int) -> str:
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as fh:
            return fh.read().decode("utf-8", "replace").replace("\0", " ")
    except OSError:
        return ""


def pid_alive(pid: int, marker: str = SESSION_MARKER) -> bool:
    """Alive AND still the process that was recorded.

    ``os.kill(pid, 0)`` alone (the ``build_sessions._pid_alive`` shape) happily
    confirms a REUSED pid; where /proc is readable the marker check closes that."""
    if pid <= 0:
        return False
    cmd = _cmdline(pid)
    if cmd:
        return marker in cmd
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True         # exists but not ours — do not claim it died
    return True


def port_answers(port: int, host: str = LOOPBACK, timeout_s: float = 0.2) -> bool:
    """A bounded TCP connect — does SOMETHING accept on this loopback port right now?"""
    try:
        with socket.create_connection((host, int(port)), timeout=timeout_s):
            return True
    except (OSError, ValueError):
        return False


def live_doors(generator_dir: str, env=None, *, connect=port_answers,
               alive=pid_alive) -> dict[str, str]:
    """``{row name: url}`` for every door that is LIVE right now — the session's
    owner pid is alive AND the door's port accepts a connection. Empty otherwise.

    Both halves matter. A crashed session leaves ``session.json`` behind, so trusting
    the file alone would hand the browser a button to a dead port; and a live owner
    whose port-forward child died would do the same for one door. The connect is
    200 ms per door and there are at most a handful of rows, so this stays cheap
    enough for a 10 s poll — but it is still I/O, so callers run it off-thread."""
    sess = live_session(generator_dir, env)
    if not sess:
        return {}
    try:
        pid = int(sess.get("pid") or 0)
    except (TypeError, ValueError):
        return {}
    if not alive(pid, str(sess.get("marker") or SESSION_MARKER)):
        return {}
    out: dict[str, str] = {}
    for door in sess.get("doors") or []:
        if not isinstance(door, dict):
            continue
        name, url, port = door.get("name"), door.get("url"), door.get("port")
        if not name or not url or not port:
            continue
        try:
            if connect(int(port)):
                out[str(name)] = str(url)
        except (TypeError, ValueError):
            continue
    return out


def stale_session(generator_dir: str, env=None, *, alive=pid_alive) -> bool:
    """True when a session record exists but its owner is gone — the "a previous view
    session left state behind" case the monitor names, so the operator knows why
    every door is blocked and that pressing 'Open the browser door' will sweep it."""
    sess = live_session(generator_dir, env)
    if not sess:
        return False
    try:
        pid = int(sess.get("pid") or 0)
    except (TypeError, ValueError):
        return True
    return not alive(pid, str(sess.get("marker") or SESSION_MARKER))

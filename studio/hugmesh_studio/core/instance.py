"""Single-instance detection + a tiny launch-command channel (Qt-free, stdlib only).

Ask 16 needs an HONEST answer to "is a Studio GUI already open?" — not a guess. A
guess (a pid file, a window-title scan) is exactly the thing that blocks an operator
out of their own tool after a crash, so this module answers the question the only way
that cannot go stale: it tries to **talk to** the running instance over a socket. If
something answers ``PING`` with ``PONG``, a Studio is genuinely alive; anything else —
no socket, a dead socket left by a SIGKILL'd process, a permission error, an unknown
platform — reads as "no instance", and the caller opens normally. **The failure mode
is always to open, never to block.**

Endpoint, in preference order:

* **Linux abstract namespace** (``\\0hugmesh-studio.<hash>``). The kernel reclaims an
  abstract socket the instant the owning process dies, so a crashed Studio leaves
  NOTHING behind — there is no stale-lock case to get wrong at all.
* **Filesystem ``AF_UNIX``** under the state dir (other POSIX). A stale file CAN be
  left behind, so :meth:`InstanceServer.start` probes before binding and unlinks only
  a socket that provably nobody is listening on.
* **TCP loopback + a port file** (Windows, which has no usable ``AF_UNIX`` here).

The hash keys off ``$HUGMESH_STUDIO_STATE_DIR`` (the same override the tray's
``build_status_path`` and ``build_sessions.sessions_dir`` honour), so the test suite —
and two operators on one box with different state dirs — get genuinely separate
namespaces rather than fighting over one global name.

Commands are single ASCII lines. ``PING`` is answered by the listener thread itself;
every other command is pushed onto a :class:`queue.Queue` and acknowledged with
``OK`` — the GUI drains it on its own thread (``gui/shell.py`` uses a QTimer), so
nothing here ever touches a widget from a socket thread.

Bounded by construction: one line, 256 bytes, 2 s of patience. A confused peer costs
a socket timeout, never a hung launch.
"""
from __future__ import annotations

import hashlib
import os
import queue
import socket
import sys
import threading

__all__ = [
    "CMD_NEW_WINDOW", "CMD_RESET", "CMD_PING", "InstanceServer",
    "endpoint_name", "probe", "send", "state_dir",
]

# the commands the shell understands (ask 16's two dialog branches, plus the probe)
CMD_PING = "PING"
CMD_NEW_WINDOW = "NEW-WINDOW"
CMD_RESET = "RESET"

_PONG = "PONG"
_ACK = "OK"

_MAX_LINE = 256          # a command is one short ASCII token; anything longer is noise
_TIMEOUT = 2.0           # seconds — a confused peer costs a timeout, never a hang


def state_dir() -> str:
    """The Studio state dir — the SAME ``$HUGMESH_STUDIO_STATE_DIR`` override the tray
    and the session records honour, so a test's isolated state dir isolates the
    instance endpoint too."""
    return os.environ.get("HUGMESH_STUDIO_STATE_DIR") or os.path.join(
        os.path.expanduser("~"), ".hugmesh", "studio")


def _key() -> str:
    """A short stable hash of the state dir — the per-state-dir namespace key."""
    return hashlib.sha256(os.path.abspath(state_dir()).encode("utf-8")).hexdigest()[:16]


def _abstract_available() -> bool:
    """Linux abstract AF_UNIX namespace (leading NUL): no filesystem entry, and the
    kernel reclaims it when the owner dies — no stale sockets, ever."""
    return sys.platform.startswith("linux") and hasattr(socket, "AF_UNIX")


def endpoint_name() -> str:
    """A human-readable endpoint id — the abstract name, socket path, or ``tcp:<file>``
    port file. For diagnostics and tests; never parsed by this module."""
    if _abstract_available():
        return f"\0hugmesh-studio.{_key()}"
    if hasattr(socket, "AF_UNIX"):
        return os.path.join(state_dir(), f"instance-{_key()}.sock")
    return "tcp:" + os.path.join(state_dir(), f"instance-{_key()}.port")


def _port_file() -> str:
    return os.path.join(state_dir(), f"instance-{_key()}.port")


def _connect(timeout: float = _TIMEOUT):
    """Connect to a live instance, or return ``None``. NEVER raises: every failure —
    missing endpoint, dead socket, unreadable port file, unsupported platform — is
    "no instance", because the caller's correct response to all of them is identical
    (open normally)."""
    try:
        if _abstract_available():
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(timeout)
            s.connect(endpoint_name())
            return s
        if hasattr(socket, "AF_UNIX"):
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(timeout)
            s.connect(endpoint_name())
            return s
        with open(_port_file(), encoding="utf-8") as fh:
            port = int(fh.read().strip())
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(("127.0.0.1", port))
        return s
    except (OSError, ValueError):
        return None


def send(command: str, timeout: float = _TIMEOUT) -> str:
    """Send one command to the running instance and return its reply, or ``""`` when
    there is no instance / the exchange failed. Never raises."""
    s = _connect(timeout)
    if s is None:
        return ""
    try:
        s.sendall((command.strip() + "\n").encode("ascii", "replace"))
        return s.recv(_MAX_LINE).decode("ascii", "replace").strip()
    except OSError:
        return ""
    finally:
        try:
            s.close()
        except OSError:
            pass


def probe(timeout: float = _TIMEOUT) -> bool:
    """True IFF a Studio instance answered our ping. This is the honest detection the
    launch path gates on — a socket that exists but nobody is listening on, a hung
    peer, or an unknown platform all answer False, and the caller opens normally."""
    return send(CMD_PING, timeout) == _PONG


class InstanceServer:
    """The PRIMARY instance's listener.

    :meth:`start` returns True when this process became the primary (it now owns the
    endpoint) and False when a LIVE instance already holds it. A start() that fails
    for any other reason (no AF_UNIX, a read-only state dir, a bind race) also returns
    True: without a listener we cannot coordinate, and the operator must still get a
    Studio — so we degrade to "an ordinary, uncoordinated launch", never to a refusal.
    Check :attr:`listening` to tell the two Trues apart.
    """

    def __init__(self) -> None:
        self._sock: socket.socket | None = None
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self.commands: queue.Queue = queue.Queue()
        self.listening = False

    # ── lifecycle ────────────────────────────────────────────────────────────────
    def start(self) -> bool:
        """Become the primary if nobody else is. See the class docstring for the
        three-way outcome."""
        if probe():
            return False                      # a live instance answered — we are second
        try:
            self._bind()
        except OSError:
            # No endpoint is available (no AF_UNIX, unwritable state dir, lost race).
            # Degrade to an uncoordinated launch rather than block the operator.
            self._sock = None
            self.listening = False
            return True
        self.listening = True
        self._thread = threading.Thread(target=self._serve, name="hugmesh-instance",
                                        daemon=True)
        self._thread.start()
        return True

    def _bind(self) -> None:
        if _abstract_available():
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.bind(endpoint_name())           # abstract: nothing lands on disk
        elif hasattr(socket, "AF_UNIX"):
            path = endpoint_name()
            os.makedirs(os.path.dirname(path), exist_ok=True)
            # probe() already proved nobody is listening, so a leftover file here is a
            # crashed instance's corpse — and ONLY then is unlinking it safe.
            try:
                os.unlink(path)
            except OSError:
                pass
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.bind(path)
        else:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.bind(("127.0.0.1", 0))
            os.makedirs(state_dir(), exist_ok=True)
            tmp = f"{_port_file()}.{os.getpid()}.tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                fh.write(str(s.getsockname()[1]))
            os.replace(tmp, _port_file())
        s.listen(8)
        s.settimeout(0.25)                    # so _serve can notice _stop promptly
        self._sock = s

    def close(self) -> None:
        """Stop listening and release the endpoint. Idempotent, never raises."""
        self._stop.set()
        sock, self._sock = self._sock, None
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass
        if self.listening and not _abstract_available():
            for path in (endpoint_name(), _port_file()):
                if os.sep in path:
                    try:
                        os.unlink(path)
                    except OSError:
                        pass
        self.listening = False

    # ── listener thread ──────────────────────────────────────────────────────────
    def _serve(self) -> None:
        while not self._stop.is_set():
            sock = self._sock
            if sock is None:
                return
            try:
                conn, _addr = sock.accept()
            except socket.timeout:
                continue
            except OSError:
                return                        # closed under us — that is the stop signal
            with conn:
                try:
                    conn.settimeout(_TIMEOUT)
                    data = conn.recv(_MAX_LINE).decode("ascii", "replace").strip()
                    if data == CMD_PING:
                        conn.sendall((_PONG + "\n").encode("ascii"))
                    elif data:
                        # NEVER touch a widget here: this is a socket thread. Queue it
                        # and let the GUI thread drain (gui/shell.py's QTimer).
                        self.commands.put(data)
                        conn.sendall((_ACK + "\n").encode("ascii"))
                except OSError:
                    continue

    # ── GUI-thread drain ─────────────────────────────────────────────────────────
    def drain(self) -> list[str]:
        """Pop every queued command (GUI thread). Non-blocking; returns [] when idle."""
        out: list[str] = []
        while True:
            try:
                out.append(self.commands.get_nowait())
            except queue.Empty:
                return out

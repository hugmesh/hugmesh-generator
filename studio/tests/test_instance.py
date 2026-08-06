"""Single-instance detection (core/instance.py) — ask 16's "is a Studio already open?"

The whole point is that detection is HONEST: a live instance is detected by TALKING to
it, and every failure mode (no endpoint, a corpse socket, an unknown platform) reads as
"no instance" so the operator is never locked out of their own tool.

Qt-free: this module is stdlib sockets only, so these tests need no display and no
binding.
"""
import os
import socket
import threading

import pytest

from hugmesh_studio.core import instance


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def test_no_instance_probes_false():
    assert instance.probe(timeout=0.5) is False


def test_first_start_becomes_primary_and_answers_ping():
    srv = instance.InstanceServer()
    try:
        assert srv.start() is True
        assert srv.listening is True
        assert instance.probe(timeout=1.0) is True
    finally:
        srv.close()


def test_second_start_detects_the_live_primary():
    first = instance.InstanceServer()
    second = instance.InstanceServer()
    try:
        assert first.start() is True
        # a SECOND launch must see the first — this is the gate the launch dialog rides
        assert second.start() is False
        assert second.listening is False
    finally:
        second.close()
        first.close()


def test_closing_the_primary_releases_the_endpoint():
    first = instance.InstanceServer()
    assert first.start() is True
    assert instance.probe(timeout=1.0) is True
    first.close()
    assert instance.probe(timeout=0.5) is False
    # and a fresh launch becomes primary again
    second = instance.InstanceServer()
    try:
        assert second.start() is True
    finally:
        second.close()


def test_commands_reach_the_primary_and_drain_on_the_gui_thread():
    srv = instance.InstanceServer()
    try:
        assert srv.start() is True
        assert instance.send(instance.CMD_NEW_WINDOW, timeout=1.0) == "OK"
        assert instance.send(instance.CMD_RESET, timeout=1.0) == "OK"
        # PING is answered by the listener itself and must NOT enter the command queue
        assert instance.probe(timeout=1.0) is True
        got = srv.drain()
        assert got == [instance.CMD_NEW_WINDOW, instance.CMD_RESET]
        assert srv.drain() == []          # drained once, gone
    finally:
        srv.close()


def test_send_with_no_instance_is_empty_never_raises():
    assert instance.send(instance.CMD_NEW_WINDOW, timeout=0.5) == ""


@pytest.mark.skipif(not hasattr(socket, "AF_UNIX"), reason="AF_UNIX only")
def test_a_dead_socket_file_never_blocks_a_launch(monkeypatch, tmp_path):
    """A crashed Studio can leave a socket FILE behind on the non-abstract path. It
    must read as "no instance" (nobody is listening) and the next launch must bind
    straight over it — the stale-lock lockout this design exists to prevent."""
    monkeypatch.setattr(instance, "_abstract_available", lambda: False)
    path = instance.endpoint_name()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    corpse = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    corpse.bind(path)                      # bound, but NEVER listen()ed on: a corpse
    corpse.close()                         # ...and now the file is orphaned on disk
    assert os.path.exists(path)
    assert instance.probe(timeout=0.5) is False
    srv = instance.InstanceServer()
    try:
        assert srv.start() is True
        assert srv.listening is True
        assert instance.probe(timeout=1.0) is True
    finally:
        srv.close()


def test_detection_failure_degrades_to_open_normally(monkeypatch):
    """If the endpoint cannot be created at all (no AF_UNIX, unwritable state dir, a
    lost race), start() still returns True — the operator gets a Studio. It just says
    so honestly via .listening."""
    def boom(self):
        raise OSError("no endpoint available on this platform")
    monkeypatch.setattr(instance.InstanceServer, "_bind", boom)
    srv = instance.InstanceServer()
    try:
        assert srv.start() is True          # never blocks the operator
        assert srv.listening is False       # ...and never claims to be coordinating
    finally:
        srv.close()


def test_state_dir_scopes_the_endpoint(monkeypatch, tmp_path):
    """Two state dirs are two namespaces: an instance in one is invisible to the
    other (this is also what keeps the suite off the operator's real ~/.hugmesh)."""
    srv = instance.InstanceServer()
    try:
        assert srv.start() is True
        assert instance.probe(timeout=1.0) is True
        monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "other"))
        assert instance.probe(timeout=0.5) is False
    finally:
        srv.close()


def test_oversized_garbage_does_not_wedge_the_listener():
    srv = instance.InstanceServer()
    try:
        assert srv.start() is True
        s = instance._connect(1.0)
        assert s is not None
        s.sendall(b"X" * 4096)
        s.close()
        # the listener survives and still serves real commands
        assert instance.probe(timeout=1.0) is True
        assert instance.send(instance.CMD_RESET, timeout=1.0) == "OK"
    finally:
        srv.close()


def test_listener_thread_is_daemon_and_stops_on_close():
    srv = instance.InstanceServer()
    srv.start()
    thread = srv._thread
    assert thread is not None and thread.daemon
    srv.close()
    thread.join(timeout=3.0)
    assert not thread.is_alive()
    assert threading.active_count() >= 1

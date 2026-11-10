"""Bytes written by the Studio reach disk unchanged on Windows, and a dead build's pid
reads as dead there.

Found by running the MSI build on Windows 11 (2026-10-29):
  * ``os.open`` without ``O_BINARY`` gives a CRT text-mode fd, so ``os.write`` turned
    every 0x0A into 0x0D 0x0A: a held Secure Boot / KEYS USB DER key was corrupted on
    its way to the build, and run logs got ``\\r\\r\\n`` line endings.
  * ``build_sessions._pid_alive`` used ``os.kill(pid, 0)``, which on Windows is
    ``GenerateConsoleCtrlEvent(CTRL_C_EVENT)``: every pid read as alive, and from a
    console it sent Ctrl+C to the whole console group (it killed this test runner).
Both halves hold on POSIX too, where they were already true.
"""
from __future__ import annotations

import os
import subprocess
import sys

from hugmesh_studio.core import build_sessions, secret_files

#: Every byte value, and the two that text mode rewrites, twice over.
PAYLOAD = bytes(range(256)) + b"\n\r\n\x1a\n"


def test_held_secret_material_reaches_disk_byte_for_byte(tmp_path):
    path = tmp_path / "kernel_key.der"
    secret_files._write_0600(str(path), PAYLOAD)
    assert path.read_bytes() == PAYLOAD


def test_a_finished_pid_is_not_alive_and_ours_is():
    p = subprocess.Popen([sys.executable, "-c", "pass"])
    p.wait()
    assert build_sessions._pid_alive(os.getpid()) is True
    assert build_sessions._pid_alive(p.pid) is False


def test_a_private_dirs_owner_lock_holds_and_lets_go_on_this_platform(tmp_path,
                                                                     monkeypatch):
    """The owner lock (fcntl.flock on POSIX, msvcrt.locking on Windows) keeps the
    startup sweep off a live dir, and removal still works with the lock file open
    (Windows cannot delete an open file). PR #938 review, finding 4."""
    monkeypatch.setattr(secret_files.tempfile, "tempdir", str(tmp_path))
    held = secret_files.materialize([secret_files.HeldSecretFile(
        "sb_key", "db.der", "C:/x/db.der", (("db.der", PAYLOAD),), "0" * 64)])
    path, cleanup = secret_files.stage_local_pass("pw")
    roots = [held._root, os.path.dirname(path)]
    later = 10 ** 10                      # far past every grace period
    assert secret_files.sweep_stale_private_dirs(str(tmp_path), now=later) == []
    with open(held.paths["sb_key"], "rb") as fh:
        assert fh.read() == PAYLOAD
    held.cleanup()
    cleanup()
    assert not any(os.path.exists(r) for r in roots)
    # a dead owner's dir: the lock file is there and free
    stale = tmp_path / "hugmesh-held-keys-dead"
    stale.mkdir()
    (stale / secret_files.OWNER_LOCK).write_bytes(b"1\n")
    assert secret_files.sweep_stale_private_dirs(str(tmp_path), now=later) \
        == [str(stale)]
    assert not stale.exists()

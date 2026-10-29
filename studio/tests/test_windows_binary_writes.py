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

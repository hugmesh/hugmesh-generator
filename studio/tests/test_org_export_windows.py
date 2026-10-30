"""Org export from a native Windows Studio (issue #827 group 3). Qt-free, no network.

From Windows the export published a different repository than the source: CRLF line
endings (git archive under Git for Windows' core.autocrlf=true, and text-mode
rewrites), every x bit dropped, links turned into copies and Windows-illegal names
dropped. A second plan for the same domain also crashed, because rmtree could not
delete git's read-only objects.
"""
from __future__ import annotations

import io
import os
import stat
import sys
import tarfile

import pytest

from hugmesh_studio.core import org_export as oe


def _tar(members):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tf:
        for name, kind, payload, mode in members:
            ti = tarfile.TarInfo(name)
            ti.mode = mode
            if kind == "sym":
                ti.type, ti.linkname = tarfile.SYMTYPE, payload
                tf.addfile(ti)
            else:
                ti.size = len(payload)
                tf.addfile(ti, io.BytesIO(payload))
    return buf.getvalue()


class _Runner(oe.Runner):
    def __init__(self, tar_bytes):
        self.tar, self.argv = tar_bytes, []

    def run(self, argv, *, cwd=None, env=None, timeout=600):
        self.argv.append(list(argv))
        return oe.RunResult(0, self.tar, b"")


MEMBERS = [("mvnw", "file", b"#!/bin/sh\n", 0o755),
           ("README.md", "file", b"hi\n", 0o644),
           ("link", "sym", "README.md", 0o777),
           ("aux.txt", "file", b"x\n", 0o644),
           ("docs/what?.md", "file", b"x\n", 0o644)]


def test_git_archive_hands_over_the_committed_bytes(tmp_path):
    r = _Runner(_tar([MEMBERS[1]]))
    oe._snapshot(r, str(tmp_path), "HEAD", str(tmp_path / "w"))
    archive = next(a for a in r.argv if "archive" in a)
    assert archive[:5] == ["git", "-c", "core.autocrlf=false", "-c", "core.eol=lf"]


def test_on_windows_nothing_is_quietly_changed(tmp_path):
    meta: dict = {}
    wd = tmp_path / "w"
    files = oe._snapshot(_Runner(_tar(MEMBERS)), str(tmp_path), "HEAD", str(wd), meta,
                         osname="nt")
    assert files == ["README.md", "mvnw"]
    assert meta["executables"] == ["mvnw"]
    lost = dict(meta["lost"])
    assert set(lost) == {"link", "aux.txt", "docs/what?.md"}, lost
    assert not os.path.lexists(wd / "link")        # never written as a copy


def test_elsewhere_the_snapshot_is_unchanged(tmp_path):
    meta: dict = {}
    oe._snapshot(_Runner(_tar(MEMBERS[:2])), str(tmp_path), "HEAD", str(tmp_path / "w"),
                 meta, osname="posix")
    assert meta == {"executables": [], "lost": []}


@pytest.mark.parametrize("name,bad", [
    ("a/b.txt", False), ("CONTRIBUTING.md", False), ("console.log", False),
    ("con", True), ("x/NUL.txt", True), ("com1", True), ("a:b", True),
    ("trailing.", True), ("space /x", True), ("tab\there", True)])
def test_names_windows_cannot_hold(name, bad):
    assert oe._windows_cannot_hold(name) is bad


def test_rmtree_removes_read_only_files(tmp_path):
    d = tmp_path / "work" / ".git" / "objects" / "ab"
    d.mkdir(parents=True)
    f = d / "cdef"
    f.write_bytes(b"x")
    os.chmod(f, stat.S_IREAD)                         # how git writes its objects
    oe._rmtree(str(tmp_path / "work"))
    assert not (tmp_path / "work").exists()


def test_the_terminal_line_names_the_console_exe_when_frozen(monkeypatch, tmp_path):
    assert oe._studio_cli() == ["python3", "-m", "hugmesh_studio"]
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(sys, "executable", str(tmp_path / "hugmesh-studio.exe"))
    assert oe._studio_cli() == [str(tmp_path / "hugmesh-studio-cli.exe")]

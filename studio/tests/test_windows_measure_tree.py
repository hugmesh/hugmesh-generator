"""measure_tree counts a hard-linked file once on Windows too (part of the Windows contract).

Found 2026-11-13 on Windows 11: ``os.DirEntry.stat()`` there leaves ``st_nlink``,
``st_ino`` and ``st_dev`` at 0, so every name of a hard-linked file was counted again.
The measure is the space a ``--resume`` build is credited with, so it must never say
more than is there. The listing below hands back those zeroed fields on any host, so
this runs on Linux CI as well as on Windows.
"""
from __future__ import annotations

import os

import pytest

from hugmesh_studio.core import build_driver as bd

_CHUNK = 65536


def _file(path, chunks):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as fh:
        for _ in range(chunks):
            fh.write(os.urandom(_CHUNK))


class _WindowsLikeEntry:
    """An os.DirEntry whose stat() looks like a Windows directory listing's."""

    def __init__(self, entry):
        self._e = entry
        self.path, self.name = entry.path, entry.name

    def stat(self, *, follow_symlinks=True):
        st = self._e.stat(follow_symlinks=follow_symlinks)
        fields = list(st)
        fields[1] = 0          # st_ino
        fields[2] = 0          # st_dev
        fields[3] = 0          # st_nlink
        return os.stat_result(fields)

    def __getattr__(self, name):
        return getattr(self._e, name)


class _Listing:
    def __init__(self, it):
        self._it = it

    def __iter__(self):
        return (_WindowsLikeEntry(e) for e in self._it)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self._it.close()


def _windows_like_listing(monkeypatch):
    real = os.scandir
    monkeypatch.setattr(bd.os, "scandir", lambda p: _Listing(real(p)))


def _link_or_skip(src, dst):
    try:
        os.link(src, dst)
    except (OSError, NotImplementedError):
        pytest.skip("this filesystem cannot hard-link")


def test_a_hard_linked_file_counts_once_when_the_listing_has_no_link_count(
        tmp_path, monkeypatch):
    _file(tmp_path / "one" / "bin" / "busybox", chunks=16)
    _file(tmp_path / "two" / "bin" / "busybox", chunks=16)
    _link_or_skip(tmp_path / "two" / "bin" / "busybox", tmp_path / "two" / "bin" / "sh")
    _windows_like_listing(monkeypatch)
    one, two = (bd.measure_tree(str(tmp_path / n)).bytes for n in ("one", "two"))
    assert two < one + 16 * _CHUNK, (one, two)


def test_plain_files_still_count_in_full_with_that_listing(tmp_path, monkeypatch):
    _file(tmp_path / "t" / "a", chunks=4)
    _file(tmp_path / "t" / "sub" / "b", chunks=4)
    plain = bd.measure_tree(str(tmp_path / "t")).bytes
    _windows_like_listing(monkeypatch)
    assert bd.measure_tree(str(tmp_path / "t")).bytes == plain >= 8 * _CHUNK

"""Windows sweep, cluster c5: core/build_sessions delete paths and the record boundary.

* Deleting a session "and its artifacts" (CLI --delete-session --delete-artifacts, the
  TUI, the Sessions page, "Delete all finished") and deleting an unmanaged ``wl-*``
  tree used ``shutil.rmtree(ignore_errors=True)``. On native Windows a file with the
  read-only attribute (what a Docker build's 0444/0400 files become on the bind mount)
  cannot be unlinked, so the tree stayed while every front end reported it removed and
  the record — the only pointer to the leftover — was gone.
* A record whose ``images`` rows are not objects loaded as readable, then every
  listing ended in ``AttributeError: 'int' object has no attribute 'get'``.
"""
import json
import os
import shutil
import stat

import pytest

from hugmesh_studio.core import build_sessions as bs
from hugmesh_studio.core.config import ImageConfig
from hugmesh_studio.core.worklist import synthesize

windows_only = pytest.mark.skipif(os.name != "nt", reason="native Windows behaviour")


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def _finished_session(tmp_path):
    # a space and non-ASCII in the out dir, as under C:\Users\Jörg Müller\...
    out = tmp_path / "out dir Jörg"
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      brand="acme", output_dir=str(out))
    s = bs.new_session(synthesize(cfg), str(tmp_path))
    bs.start(s)
    bs.finish(s, "complete")
    return s


def _readonly_file(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(b"\x00image")
    os.chmod(path, stat.S_IREAD)        # the Windows read-only attribute
    return path


def _force_rmtree(path):
    """Test cleanup: whatever a failed case left must not break tmp_path removal."""
    if not os.path.lexists(path):
        return
    for root, dirs, files in os.walk(path):
        for name in dirs + files:
            os.chmod(os.path.join(root, name), stat.S_IWRITE | stat.S_IREAD | stat.S_IEXEC)
    shutil.rmtree(path)


# ── read-only files are removed with the tree ────────────────────────────────────────
def test_delete_with_artifacts_removes_read_only_files(tmp_path):
    s = _finished_session(tmp_path)
    ro = _readonly_file(os.path.join(s.workdir, "wl-standalone-thick.x86", "imgs",
                                     "readonly.img"))
    key = _readonly_file(os.path.join(s.workdir, "keys-standalone", "Keys",
                                      "kernel_key.pem"))
    try:
        assert bs.delete(s, remove_artifacts=True) is True
        assert not os.path.exists(ro) and not os.path.exists(key)
        assert not os.path.exists(s.workdir)
        assert not os.path.exists(s.path())
    finally:
        _force_rmtree(s.workdir)


def test_delete_unmanaged_removes_read_only_files(tmp_path):
    out = tmp_path / "out dir Jörg"
    ro = _readonly_file(str(out / "wl-backend.x86" / "sub" / "ro.txt"))
    try:
        found = bs.discover_unmanaged(str(out))
        assert len(found) == 1
        assert bs.delete_unmanaged(found[0]) is True
        assert not os.path.exists(ro)
        assert not (out / "wl-backend.x86").exists()
        assert bs.discover_unmanaged(str(out)) == []
    finally:
        _force_rmtree(str(out / "wl-backend.x86"))


def test_prune_with_artifacts_removes_read_only_files(tmp_path):
    s = _finished_session(tmp_path)
    ro = _readonly_file(os.path.join(s.workdir, "wl-x", "sysroot", "usr", "bin", "tool"))
    try:
        assert bs.prune(remove_artifacts=True) == (1, 0)
        assert not os.path.exists(ro) and not os.path.exists(s.workdir)
    finally:
        _force_rmtree(s.workdir)


@windows_only
def test_read_only_directory_is_removed_too(tmp_path):
    s = _finished_session(tmp_path)
    d = os.path.join(s.workdir, "wl-x", "etc")
    os.makedirs(d)
    os.chmod(d, stat.S_IREAD)
    try:
        assert bs.delete(s, remove_artifacts=True) is True
        assert not os.path.exists(s.workdir)
    finally:
        _force_rmtree(s.workdir)


# ── what cannot be removed is not reported as removed ────────────────────────────────
@windows_only
def test_delete_keeps_the_record_when_a_file_is_held_open(tmp_path):
    s = _finished_session(tmp_path)
    held = os.path.join(s.workdir, "wl-x", "disk.img")
    os.makedirs(os.path.dirname(held))
    fh = open(held, "wb")               # Python opens without FILE_SHARE_DELETE
    try:
        assert bs.delete(s, remove_artifacts=True) is False
        assert not bs.is_active(s)      # how callers tell this from "in progress"
        assert os.path.exists(s.path())                 # still listed, retry possible
        assert [r.id for r in bs.load_all()] == [s.id]
        assert bs.artifact_paths(s) == [os.path.join("wl-x", "disk.img")]
        assert bs.prune(remove_artifacts=True) == (0, 0)    # "Deleted 0" is true
    finally:
        fh.close()
    assert bs.delete(s, remove_artifacts=True) is True   # the retry now succeeds
    assert not os.path.exists(s.workdir) and not os.path.exists(s.path())


@windows_only
def test_delete_unmanaged_says_false_when_a_file_is_held_open(tmp_path):
    out = tmp_path / "out"
    held = out / "wl-backend.x86" / "x.img"
    held.parent.mkdir(parents=True)
    fh = open(held, "wb")
    try:
        assert bs.delete_unmanaged(bs.discover_unmanaged(str(out))[0]) is False
    finally:
        fh.close()


@windows_only
def test_posix_path_is_unchanged(tmp_path):
    """osname='posix' runs the old code: plain rmtree, record first, always True (on
    Linux the read-only file below is deleted; here it pins the gate)."""
    s = _finished_session(tmp_path)
    ro = _readonly_file(os.path.join(s.workdir, "a", "ro.img"))
    try:
        assert bs.delete(s, remove_artifacts=True, osname="posix") is True
        assert not os.path.exists(s.path())
        assert os.path.exists(ro)       # Windows refuses; the posix path does not retry
    finally:
        _force_rmtree(s.workdir)


# ── a record whose image rows are not objects is unreadable, not a crash ─────────────
def _write_record(rec):
    os.makedirs(bs.sessions_dir(), exist_ok=True)
    path = os.path.join(bs.sessions_dir(), f"{rec['id']}.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(rec, fh)
    return path


@pytest.mark.parametrize("images", [[1], ["x"], [{"id": "a"}, None], 7, {"id": "a"}])
def test_non_object_image_rows_make_the_record_unreadable(images):
    good = _write_record({"id": "20261030-010000-bbbbbb", "status": "complete",
                          "images": [{"id": "e1", "role": "backend"}]})
    bad = _write_record({"id": "20261030-020000-aaaaaa", "status": "complete",
                         "images": images})
    sessions, unreadable = bs.scan()
    assert [s.id for s in sessions] == ["20261030-010000-bbbbbb"]
    assert unreadable == [bad]
    assert bs.find("20261030-020000-aaaaaa") is None
    for s in sessions:                  # every presenter still works for the rest
        bs.format_session_line(s)
        bs.session_row(s)
        bs.session_haystack(s)
    assert os.path.exists(good)


def test_null_images_is_the_empty_default():
    s = bs.BuildSession.from_dict({"id": "x1", "status": "complete", "images": None})
    assert s.images == []
    assert "x1" in bs.format_session_line(s)

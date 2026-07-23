"""core/build_sessions — the durable build-session store (pure core, no Qt, no builds).

Pins the session-record lifecycle (start/update/finish + RESTART archiving), the
crash-honesty rules (a "running" record is never mutated; is_stale is a render hint),
corrupt-record tolerance, unmanaged wl-*.* discovery, and the dumb searchable
haystack/filter helpers the Welcome widget renders through.
"""
import json
import os
import socket
import subprocess
import sys

import pytest

from hugmesh_studio.core import build_sessions as bs
from hugmesh_studio.core.config import ImageConfig
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry, synthesize


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    # Same env override as tray.build_status_path — session records share the family.
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def _standalone_wl(tmp_path, **kw):
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      brand="acme", output_dir=str(tmp_path / "out"), **kw)
    return synthesize(cfg)


def _mesh_wl(tmp_path):
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                       output_dir=str(tmp_path / "out"))
    return WorklistConfig(base=base, entries=[
        WorklistEntry(role="pki", platform="x86"),
        WorklistEntry(role="be", platform="rpi5"),
    ])


# ── dirs / ids / labels ────────────────────────────────────────────────────────────────
def test_sessions_dir_honours_state_dir_env(tmp_path):
    assert bs.sessions_dir() == str(tmp_path / "state" / "sessions")


def test_session_workdir_layout(tmp_path):
    wd = bs.session_workdir(str(tmp_path / "out"), "20260715-120000-abcdef")
    assert wd == str(tmp_path / "out" / "sessions" / "20260715-120000-abcdef")


def test_new_session_ids_are_sortable_and_unique():
    a, b = bs.new_session_id(), bs.new_session_id()
    assert a != b
    assert len(a.split("-")) == 3


def test_derive_label_single_and_mesh(tmp_path):
    assert bs.derive_label(_standalone_wl(tmp_path)) == "standalone-thick · x86"
    assert bs.derive_label(_mesh_wl(tmp_path)) == "mesh · 2 images (x86, rpi5)"
    wl = synthesize(ImageConfig(mode="standalone", role="generic", platform="rpi5",
                                board="cm5-lite"))
    assert bs.derive_label(wl) == "generic · rpi5 · cm5-lite"


# ── lifecycle: start / update / finish ────────────────────────────────────────────────
def test_start_writes_running_record_and_finish_updates_it(tmp_path):
    wl = _standalone_wl(tmp_path, local_pass="hunter2")
    s = bs.new_session(wl, str(tmp_path / "gen"), backend="native")
    assert not os.path.exists(s.path())          # nothing written before dispatch
    bs.start(s)
    on_disk = bs.load(s.path())
    assert on_disk.status == "running"
    assert on_disk.pid == os.getpid()
    assert on_disk.hostname == socket.gethostname()
    assert on_disk.blanked_secrets == ["local_pass"]
    assert on_disk.config["schema"] == "hugmesh-worklist/v1"
    assert on_disk.config["base"]["local_pass"] == ""      # secrets blanked, like save
    assert on_disk.workdir == bs.session_workdir(str(tmp_path / "out"), s.id)
    assert on_disk.log_path == os.path.join(on_disk.workdir, "build.log")
    assert on_disk.images == [{"id": "standalone-thick.x86", "role": "standalone-thick",
                               "platform": "x86", "status": "queued",
                               "exit_code": None, "keys_ok": None,
                               "log": "build-standalone-thick.x86.log"}]

    bs.update_image(s, 0, status="failed", exit_code=2)
    bs.finish(s, "failed", {"standalone-thick.x86": ["boom line 1", "boom line 2"]})
    on_disk = bs.load(s.path())
    assert on_disk.status == "failed"
    assert on_disk.finished
    assert on_disk.images[0]["status"] == "failed"
    assert on_disk.images[0]["exit_code"] == 2
    assert on_disk.error_tail == {"standalone-thick.x86": ["boom line 1", "boom line 2"]}


def test_error_tail_capped_to_last_lines(tmp_path):
    s = bs.new_session(_standalone_wl(tmp_path), str(tmp_path))
    bs.finish(s, "failed", {"x": [f"l{i}" for i in range(100)]})
    tail = bs.load(s.path()).error_tail["x"]
    assert len(tail) == bs.ERROR_TAIL_LINES
    assert tail[-1] == "l99"


def test_restart_reuses_record_archives_history_and_counts(tmp_path):
    wl = _standalone_wl(tmp_path)
    s = bs.new_session(wl, str(tmp_path))
    bs.start(s)
    bs.update_image(s, 0, status="failed", exit_code=1)
    bs.finish(s, "failed", {"standalone-thick.x86": ["err"]})

    s2 = bs.new_session(wl, str(tmp_path), session_id=s.id)   # RESTART: same id
    assert s2.workdir == s.workdir                            # SAME session dir
    assert s2.images[0]["status"] == "queued"                 # fresh run state
    assert len(s2.history) == 1                               # prior truth kept
    assert s2.history[0]["status"] == "failed"
    assert s2.history[0]["error_tail"] == {"standalone-thick.x86": ["err"]}
    bs.start(s2)
    on_disk = bs.load(s2.path())
    assert on_disk.status == "running"
    assert on_disk.restarts == 1
    assert len(on_disk.runs) == 2


def test_overall_status():
    assert bs.overall_status(["ok", "ok"]) == "complete"
    assert bs.overall_status(["ok", "failed", "stopped"]) == "failed"
    assert bs.overall_status(["ok", "stopped"]) == "stopped"
    assert bs.overall_status([]) == "stopped"


# ── crash honesty / reads ─────────────────────────────────────────────────────────────
def test_load_all_newest_first_and_corrupt_records_surfaced(tmp_path):
    for _ in range(2):
        s = bs.new_session(_standalone_wl(tmp_path), str(tmp_path))
        bs.start(s)
    os.makedirs(bs.sessions_dir(), exist_ok=True)
    bad = os.path.join(bs.sessions_dir(), "00000000-000000-bad.json")
    with open(bad, "w", encoding="utf-8") as fh:
        fh.write("{not json")
    sessions, unreadable = bs.scan()
    assert len(sessions) == 2
    assert sessions[0].id >= sessions[1].id            # newest-first
    assert unreadable == [bad]
    assert bs.load_all() == sessions
    with open(bad, encoding="utf-8") as fh:            # never rewritten
        assert fh.read() == "{not json"


def test_is_stale_probes_pid_without_mutating(tmp_path):
    s = bs.new_session(_standalone_wl(tmp_path), str(tmp_path))
    bs.start(s)
    assert not bs.is_stale(s)                          # our own live pid
    proc = subprocess.Popen([sys.executable, "-c", "pass"])
    proc.wait()
    s.pid = proc.pid                                   # a genuinely dead pid
    assert bs.is_stale(s)
    s.hostname = "some-other-host"
    assert not bs.is_stale(s)                          # cannot probe another host
    assert bs.load(s.path()).status == "running"       # record NEVER mutated


def test_save_is_best_effort_never_raises(tmp_path, monkeypatch):
    s = bs.new_session(_standalone_wl(tmp_path), str(tmp_path))
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", "/proc/definitely/not/writable")
    bs.start(s)                                        # must not raise


# ── unmanaged discovery ───────────────────────────────────────────────────────────────
def test_discover_unmanaged_finds_wl_dirs_only(tmp_path):
    out = tmp_path / "out"
    (out / "wl-pki.x86").mkdir(parents=True)
    (out / "wl-be.rpi5").mkdir()
    (out / "keys-pki.x86").mkdir()                     # not a build tree
    (out / "wl-noplatform").mkdir()                    # no dot — not an entry id
    (out / "sessions" / "S1" / "wl-fe.x86").mkdir(parents=True)   # managed — skipped
    (out / "build.log").write_text("legacy shared log\n")
    found = bs.discover_unmanaged(str(out))
    assert sorted((u.role, u.platform) for u in found) == [("be", "rpi5"), ("pki", "x86")]
    for u in found:
        assert u.has_log
        assert u.log_path == str(out / "build.log")
    assert bs.discover_unmanaged(str(tmp_path / "missing")) == []


# ── deletion / cleanup ────────────────────────────────────────────────────────────────
def test_is_active_true_only_while_genuinely_running(tmp_path):
    s = bs.new_session(_standalone_wl(tmp_path), str(tmp_path))
    bs.start(s)
    assert bs.is_active(s)                             # running with our own live pid
    bs.finish(s, "complete")
    assert not bs.is_active(s)                         # terminal record


def test_is_session_workdir_shape_check(tmp_path):
    sid = "20260715-120000-abcdef"
    good = bs.session_workdir(str(tmp_path / "out"), sid)
    assert bs._is_session_workdir(good, sid)
    assert bs._is_session_workdir(good + "/", sid)                 # trailing slash ok
    assert not bs._is_session_workdir(str(tmp_path), sid)          # no sessions/ parent
    assert not bs._is_session_workdir(str(tmp_path / "out"), sid)  # basename != id
    assert not bs._is_session_workdir(good, "another-id")          # id mismatch


def test_delete_removes_record_and_drops_from_load_all(tmp_path):
    s = bs.new_session(_standalone_wl(tmp_path), str(tmp_path))
    bs.start(s)
    bs.finish(s, "complete")
    assert os.path.exists(s.path())
    assert bs.delete(s) is True
    assert not os.path.exists(s.path())
    assert bs.load_all() == []


def test_delete_refuses_a_running_session(tmp_path):
    s = bs.new_session(_standalone_wl(tmp_path), str(tmp_path))
    bs.start(s)                                        # running, our live pid -> active
    assert bs.delete(s) is False                       # never delete an in-progress build
    assert os.path.exists(s.path())                    # the file survives untouched


def test_delete_allows_a_stale_running_record(tmp_path):
    s = bs.new_session(_standalone_wl(tmp_path), str(tmp_path))
    bs.start(s)
    proc = subprocess.Popen([sys.executable, "-c", "pass"])
    proc.wait()
    s.pid = proc.pid                                   # a genuinely dead pid -> stale
    assert bs.is_stale(s) and not bs.is_active(s)
    assert bs.delete(s) is True                         # a crashed Studio is deletable
    assert not os.path.exists(s.path())


def test_delete_with_artifacts_rmtrees_the_session_workdir(tmp_path):
    s = bs.new_session(_standalone_wl(tmp_path), str(tmp_path))
    bs.start(s)
    bs.finish(s, "complete")
    os.makedirs(os.path.join(s.workdir, "wl-standalone-thick.x86"))
    assert os.path.isdir(s.workdir)
    assert bs.delete(s, remove_artifacts=True) is True
    assert not os.path.exists(s.path())
    assert not os.path.isdir(s.workdir)                # artifacts rmtree'd too


def test_delete_never_rmtrees_a_poisoned_workdir(tmp_path):
    s = bs.new_session(_standalone_wl(tmp_path), str(tmp_path))
    bs.start(s)
    bs.finish(s, "complete")
    poison = tmp_path / "precious"
    poison.mkdir()
    (poison / "keep.txt").write_text("do not delete")
    s.workdir = str(poison)                            # out-of-shape (tampered) path
    assert not bs._is_session_workdir(s.workdir, s.id)
    assert bs.delete(s, remove_artifacts=True) is True  # record removed regardless
    assert not os.path.exists(s.path())
    assert poison.is_dir() and (poison / "keep.txt").exists()   # NEVER rmtree'd


def test_delete_is_best_effort_on_missing_file(tmp_path):
    s = bs.new_session(_standalone_wl(tmp_path), str(tmp_path))
    s.status = bs.COMPLETE                             # terminal, but never persisted
    assert not os.path.exists(s.path())
    assert bs.delete(s) is True                         # must not raise on a gone file


def test_prune_deletes_terminal_and_skips_active(tmp_path):
    for _ in range(2):
        s = bs.new_session(_standalone_wl(tmp_path), str(tmp_path))
        bs.start(s)
        bs.finish(s, "complete")
    active = bs.new_session(_standalone_wl(tmp_path), str(tmp_path))
    bs.start(active)                                   # still running -> must be skipped
    deleted, skipped = bs.prune()
    assert (deleted, skipped) == (2, 1)
    assert [r.id for r in bs.load_all()] == [active.id]  # only the active one survives


def test_delete_path_removes_a_corrupt_record(tmp_path):
    os.makedirs(bs.sessions_dir(), exist_ok=True)
    bad = os.path.join(bs.sessions_dir(), "00000000-000000-bad.json")
    with open(bad, "w", encoding="utf-8") as fh:
        fh.write("{not json")
    assert bs.scan()[1] == [bad]                       # surfaced as unreadable
    bs.delete_path(bad)
    assert not os.path.exists(bad)
    bs.delete_path(bad)                                # best-effort: no raise once gone


def test_delete_unmanaged_rmtrees_a_wl_tree_only(tmp_path):
    out = tmp_path / "out"
    (out / "wl-pki.x86").mkdir(parents=True)
    found = bs.discover_unmanaged(str(out))
    assert len(found) == 1
    assert bs.delete_unmanaged(found[0]) is True
    assert not (out / "wl-pki.x86").exists()
    # a forged non-wl path (e.g. the shared out dir itself) is refused
    forged = bs.UnmanagedBuild(path=str(out), role="x", platform="x", mtime=0.0,
                               has_log=False, log_path="")
    assert bs.delete_unmanaged(forged) is False
    assert out.is_dir()


# ── search helpers ────────────────────────────────────────────────────────────────────
def test_haystack_and_matches(tmp_path):
    s = bs.new_session(_mesh_wl(tmp_path), str(tmp_path))
    bs.start(s)
    hay = bs.session_haystack(s)
    for needle in ("mesh", "pki", "rpi5", "running", s.started.lower()[:10]):
        assert needle in hay
    assert bs.matches(hay, "PKI rpi5")
    assert bs.matches(hay, "")
    assert not bs.matches(hay, "jetson")
    u = bs.UnmanagedBuild(path="/x/wl-pki.x86", role="pki", platform="x86",
                          mtime=0.0, has_log=False, log_path="")
    assert bs.matches(bs.unmanaged_haystack(u), "unknown pki")


# ── per-image logs (fix D): the builders' build-<entry-id>.log twin ───────────────────
def test_image_log_name_matches_builder_derivation(tmp_path):
    # The shell side derives IMAGE_LOG_FILE="${WORK_DIR}/build-${BUILD_SUBDIR#wl-}.log"
    # from the --build-subdir the driver already passes (wl-<entry-id>); the python
    # side must mint the identical basename for the session record.
    assert bs.image_log_name("edge_ai.jetson") == "build-edge_ai.jetson.log"
    assert bs.image_log_name("standalone-thick.x86") == "build-standalone-thick.x86.log"


def test_new_session_stamps_per_image_log_and_keeps_shared_log_path(tmp_path):
    wl = _mesh_wl(tmp_path)
    s = bs.new_session(wl, str(tmp_path / "gen"))
    # shared session log: semantics UNCHANGED (every existing reader keeps working)
    assert s.log_path == os.path.join(s.workdir, bs.LOG_NAME)
    assert bs.LOG_NAME == "build.log"
    # each image row carries its own on-disk log basename
    for row, entry in zip(s.images, wl.entries):
        assert row["log"] == f"build-{entry.id}.log"

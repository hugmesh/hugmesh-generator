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

from snapdragon_studio.core import build_sessions as bs
from snapdragon_studio.core.config import ImageConfig
from snapdragon_studio.core.worklist import WorklistConfig, WorklistEntry, synthesize


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    # Same env override as tray.build_status_path — session records share the family.
    monkeypatch.setenv("SNAPDRAGON_STUDIO_STATE_DIR", str(tmp_path / "state"))


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
    assert on_disk.config["schema"] == "snapdragon-worklist/v1"
    assert on_disk.config["base"]["local_pass"] == ""      # secrets blanked, like save
    assert on_disk.workdir == bs.session_workdir(str(tmp_path / "out"), s.id)
    assert on_disk.log_path == os.path.join(on_disk.workdir, "build.log")
    assert on_disk.images == [{"id": "standalone-thick.x86", "role": "standalone-thick",
                               "platform": "x86", "status": "queued",
                               "exit_code": None, "keys_ok": None}]

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
    monkeypatch.setenv("SNAPDRAGON_STUDIO_STATE_DIR", "/proc/definitely/not/writable")
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

"""tui — SESSIONS REVIEW over core.build_sessions, exercised through the PLAIN face.

Runs headlessly with urwid absent (plain.py never imports it): pins the crash-honest
display status, the artifact listing, delete-with-confirm (record-only vs artifacts,
refusal of an active build WITH the reason), and the read-only worklist table.
"""
import io
import os
import subprocess
import sys

import pytest

from hugmesh_studio.core import build_sessions as bs
from hugmesh_studio.core.config import ImageConfig
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry, synthesize
from hugmesh_studio.tui import app as tui_app
from hugmesh_studio.tui import model, plain


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    # Same env override as test_build_sessions — records and workdirs stay in tmp.
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def _standalone_wl(tmp_path):
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      brand="acme", output_dir=str(tmp_path / "out"))
    return synthesize(cfg)


def _mesh_wl(tmp_path):
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                       output_dir=str(tmp_path / "out"))
    return WorklistConfig(base=base, entries=[
        WorklistEntry(role="pki", platform="x86"),
        WorklistEntry(role="backend", platform="rpi5"),
    ])


def _finished(tmp_path, *, session_id, status="complete", wl=None):
    s = bs.new_session(wl or _standalone_wl(tmp_path), str(tmp_path),
                       session_id=session_id)
    bs.start(s)
    bs.finish(s, status)
    return s


def _run_plain(script: str) -> str:
    out = io.StringIO()
    assert plain.run_sessions_review(inp=io.StringIO(script), out=out) == 0
    return out.getvalue()


# ── model rows ──────────────────────────────────────────────────────────────────────
def test_session_rows_newest_first_with_status(tmp_path):
    _finished(tmp_path, session_id="20260101-000001-aaaaaa", status="complete")
    _finished(tmp_path, session_id="20260102-000001-bbbbbb", status="failed")
    rows, unreadable = model.session_rows()
    assert unreadable == []
    assert [r.session.id for r in rows] == [
        "20260102-000001-bbbbbb", "20260101-000001-aaaaaa"]
    assert [r.status for r in rows] == ["failed", "complete"]


def test_display_status_is_crash_honest_and_never_mutates(tmp_path):
    s = bs.new_session(_standalone_wl(tmp_path), str(tmp_path),
                       session_id="20260103-000001-cccccc")
    bs.start(s)
    assert model.display_status(s) == "running"        # our own live pid
    proc = subprocess.Popen([sys.executable, "-c", "pass"])
    proc.wait()
    s.pid = proc.pid                                   # a genuinely dead pid
    bs.save(s)
    (row,), _ = model.session_rows()
    assert row.status == model.STALE_STATUS
    assert bs.load(s.path()).status == "running"       # record NEVER rewritten


def test_artifact_entries_lists_workdir_honestly(tmp_path):
    s = _finished(tmp_path, session_id="20260104-000001-dddddd")
    assert model.artifact_entries(s) == []             # missing dir: no artifacts
    os.makedirs(os.path.join(s.workdir, "wl-standalone-thick.x86"))
    with open(os.path.join(s.workdir, "build.log"), "w", encoding="utf-8") as fh:
        fh.write("log\n")
    assert model.artifact_entries(s) == ["build.log", "wl-standalone-thick.x86/"]


def test_delete_refusal_only_for_active_sessions(tmp_path):
    done = _finished(tmp_path, session_id="20260105-000001-eeeeee")
    assert model.delete_refusal(done) is None
    live = bs.new_session(_standalone_wl(tmp_path), str(tmp_path),
                          session_id="20260105-000002-ffffff")
    bs.start(live)                                     # running with our live pid
    assert "running right now" in model.delete_refusal(live)


# ── plain face: list + inspect ──────────────────────────────────────────────────────
def test_plain_list_and_inspect_shows_detail(tmp_path):
    s = _finished(tmp_path, session_id="20260106-000001-abc123",
                  wl=_mesh_wl(tmp_path))
    os.makedirs(s.workdir)
    with open(os.path.join(s.workdir, "build.log"), "w", encoding="utf-8") as fh:
        fh.write("log\n")
    text = _run_plain("1\nq\n")
    assert "mesh · 2 images (x86, rpi5)" in text
    assert "session   20260106-000001-abc123" in text
    assert "pki.x86: pki · x86" in text
    assert "backend.rpi5: backend · rpi5" in text
    assert "  build.log" in text


def test_inspect_says_why_an_image_was_never_started(tmp_path, monkeypatch):
    """GUI/TUI parity for the free-space refusal (defect L4). An image the build runner
    refuses before dispatch is recorded ``failed (exit 1)``, and its reason is the
    ``!!`` line the runner wrote, which the session record's error tail keeps. The
    GUI's previous-builds list prints that tail. This face printed the status alone,
    so a terminal could not tell a refused image from a build that crashed.

    The refusal is made by the real runner here (1 GiB free: neither image is
    dispatched, so no builder is involved), not typed into the test."""
    import collections

    from hugmesh_studio.core import emulation_save, worklist_driver
    from hugmesh_studio.core.platform_info import HostInfo
    usage = collections.namedtuple("usage", "total used free")
    monkeypatch.setattr(emulation_save, "_disk_usage",
                        lambda _path: usage(1 << 42, 0, 1 << 30))
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                       brand_title="Acme", org="Acme-Inc", cluster_domain="acme.example",
                       superdomain="core.acme.internal", output_dir=str(tmp_path / "out"))
    wl = WorklistConfig(base=base, entries=[
        WorklistEntry(role="pki", platform="x86", hostname="n0"),
        WorklistEntry(role="backend", platform="rpi5", hostname="n1")])
    s = bs.new_session(wl, str(tmp_path), session_id="20260107-000001-abc123")
    bs.start(s)
    host = HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                    has_kvm=False, is_root=True, builder_image="hugmesh-builder")
    drv = worklist_driver.WorklistDriver(str(tmp_path), wl, host=host, workdir=s.workdir)
    tails: dict[str, list[str]] = {}
    drv.run_all(
        on_line=lambda i, ln: tails.setdefault(wl.entries[i].id, []).append(ln),
        on_entry_done=lambda i, code: bs.update_image(
            s, i, status=drv.results[i].status, exit_code=code))
    tails["backend.rpi5"].insert(0, "==> Preparing build directories")
    bs.finish(s, "failed", tails)

    text = _run_plain("1\nq\n")
    assert "pki.x86: pki · x86 — failed (exit 1)" in text
    assert f"  pki.x86 not started: not enough free disk space under {s.workdir}" in text
    assert "  backend.rpi5 not started: not enough free disk space" in text
    assert "1.0 GiB is free" in text
    assert "Preparing build directories" not in text       # builder output stays in the log
    # nothing to say, nothing printed: a clean session's detail is unchanged
    clean = _finished(tmp_path, session_id="20260107-000002-abc123")
    assert model.verdict_lines(clean) == []
    assert not any(ln.startswith("why") for ln in model.session_detail_lines(
        model.SessionRow(session=clean, status=clean.status)))
    # a verdict that does not name its image is led by the image id
    clean.error_tail = {"standalone-thick.x86": ["!! exit 137 — killed by its memory cap"]}
    assert model.verdict_lines(clean) == [
        "standalone-thick.x86: exit 137 — killed by its memory cap"]


def test_plain_list_surfaces_unreadable_records(tmp_path):
    os.makedirs(bs.sessions_dir(), exist_ok=True)
    bad = os.path.join(bs.sessions_dir(), "zz-corrupt.json")
    with open(bad, "w", encoding="utf-8") as fh:
        fh.write("{not json")
    text = _run_plain("q\n")
    assert f"unreadable record skipped: {bad}" in text


def test_plain_empty_state_says_so(tmp_path):
    assert "(no build sessions recorded yet)" in _run_plain("q\n")


# ── plain face: delete-with-confirm ─────────────────────────────────────────────────
def test_plain_delete_confirmed_record_only_keeps_artifacts(tmp_path):
    s = _finished(tmp_path, session_id="20260107-000001-abcdef")
    os.makedirs(s.workdir)
    marker = os.path.join(s.workdir, "artifact.img")
    with open(marker, "w", encoding="utf-8") as fh:
        fh.write("x")
    text = _run_plain("d 1\ny\nn\nq\n")                # yes record, no artifacts
    assert "deleted session 20260107-000001-abcdef (record only)." in text
    assert not os.path.exists(s.path())
    assert os.path.exists(marker)                      # artifacts kept


def test_plain_delete_confirmed_with_artifacts_removes_the_tree(tmp_path):
    s = _finished(tmp_path, session_id="20260108-000001-abcdef")
    os.makedirs(s.workdir)
    with open(os.path.join(s.workdir, "artifact.img"), "w", encoding="utf-8") as fh:
        fh.write("x")
    text = _run_plain("d 1\ny\ny\nq\n")                # yes record, yes artifacts
    assert "and its artifacts." in text
    assert not os.path.exists(s.path())
    assert not os.path.exists(s.workdir)


def test_plain_delete_declined_keeps_everything(tmp_path):
    s = _finished(tmp_path, session_id="20260109-000001-abcdef")
    text = _run_plain("d 1\nn\nq\n")
    assert "kept." in text
    assert os.path.exists(s.path())


def test_plain_delete_refuses_an_active_session_with_the_reason(tmp_path):
    s = bs.new_session(_standalone_wl(tmp_path), str(tmp_path),
                       session_id="20260110-000001-abcdef")
    bs.start(s)                                        # active: running, our live pid
    text = _run_plain("d 1\nq\n")
    assert "not deleted: this build is running right now" in text
    assert os.path.exists(s.path())                    # never removed underneath it


def test_plain_delete_rejects_a_bad_number(tmp_path):
    _finished(tmp_path, session_id="20260111-000001-abcdef")
    text = _run_plain("d 9\nq\n")
    assert "no such session number: 9" in text


# ── worklist table (read-only) ──────────────────────────────────────────────────────
def test_worklist_table_rows_from_a_mesh_session(tmp_path):
    s = _finished(tmp_path, session_id="20260112-000001-abcdef",
                  wl=_mesh_wl(tmp_path), status="failed")
    headers, rows = model.worklist_table(s)
    assert headers == ["#", "id", "role", "platform", "board/flavor", "status"]
    assert [r[1:4] for r in rows] == [
        ["pki.x86", "pki", "x86"], ["backend.rpi5", "backend", "rpi5"]]
    # statuses come from the per-image outcome records (still queued: no driver ran)
    assert all(r[5].startswith("queued") for r in rows)


def test_plain_worklist_command_prints_the_table(tmp_path):
    _finished(tmp_path, session_id="20260113-000001-abcdef", wl=_mesh_wl(tmp_path))
    text = _run_plain("w 1\nq\n")
    assert "id" in text and "platform" in text
    assert "pki.x86" in text and "backend.rpi5" in text


def test_main_worklist_flag_prints_headlessly(tmp_path, capsys):
    _finished(tmp_path, session_id="20260114-000001-abcdef", wl=_mesh_wl(tmp_path))
    out = io.StringIO()
    rc = tui_app.main(["--worklist", "20260114-000001-abcdef"],
                      inp=io.StringIO(""), out=out)
    assert rc == 0
    assert "pki.x86" in out.getvalue() and "backend.rpi5" in out.getvalue()

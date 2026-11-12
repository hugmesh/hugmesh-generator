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


def _corrupt(name: str = "zz-corrupt.json") -> str:
    os.makedirs(bs.sessions_dir(), exist_ok=True)
    bad = os.path.join(bs.sessions_dir(), name)
    with open(bad, "w", encoding="utf-8") as fh:
        fh.write("{not json")
    return bad


def test_plain_list_numbers_an_unreadable_record_after_the_sessions(tmp_path):
    # B-11: listed as a ROW of the one numbering (the GUI lists it), not "skipped"
    _finished(tmp_path, session_id="20260115-000001-abcdef")
    bad = _corrupt()
    text = _run_plain("q\n")
    assert "  2. ! unreadable record zz-corrupt.json — only delete applies" in text
    assert "skipped" not in text
    detail = _run_plain("2\nq\n")                 # NUMBER inspects it: the whole path
    assert f"record    {bad}" in detail
    assert "only delete (removing the file) applies" in detail


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


# ── B-11: an unreadable record is deletable from the TUI (the GUI deletes it) ───────
def test_plain_d_deletes_an_unreadable_record_after_a_confirm(tmp_path):
    s = _finished(tmp_path, session_id="20260116-000001-abcdef")
    bad = _corrupt()
    text = _run_plain("d 2\ny\nq\n")
    assert f"delete this unreadable record file {bad}? [y/N]" in text
    assert f"deleted the unreadable record {bad}." in text
    assert not os.path.exists(bad)
    assert os.path.exists(s.path())                    # the build next to it is untouched
    assert "unreadable record" not in text.rsplit("previous builds", 1)[1]


def test_plain_d_on_an_unreadable_record_declined_keeps_it(tmp_path):
    bad = _corrupt()
    text = _run_plain("d 1\nn\nq\n")
    assert "kept." in text
    assert os.path.exists(bad)


def test_plain_a_list_of_only_unreadable_records_is_still_deletable(tmp_path):
    bad = _corrupt()
    text = _run_plain("d 1\ny\nq\n")
    assert f"deleted the unreadable record {bad}." in text
    assert not os.path.exists(bad)


def test_plain_unreadable_delete_says_so_when_the_file_stays(tmp_path, monkeypatch):
    # delete_path swallows every error: the transcript must say what is TRUE after it
    bad = _corrupt()
    monkeypatch.setattr(bs, "delete_path", lambda _p: None)
    text = _run_plain("d 1\ny\nq\n")
    assert f"not deleted: {bad} is still there" in text
    assert "deleted the unreadable record" not in text


@pytest.mark.parametrize("verb, said", [("w", "worklist"), ("s", "restart"),
                                        ("e", "redo")])
def test_plain_other_verbs_on_an_unreadable_record_say_why_not(tmp_path, verb, said):
    _finished(tmp_path, session_id="20260117-000001-abcdef")
    bad = _corrupt()
    text = _run_plain(f"{verb} 2\nq\n")
    assert f"no {said} for an unreadable record: it could not be parsed" in text
    assert os.path.exists(bad)


# ── B-10: the GUI's other Previous-builds buttons ──────────────────────────────────
def test_plain_help_offers_restart_redo_and_delete_all(tmp_path):
    text = _run_plain("q\n")
    assert ("build actions: s NUMBER=restart · e NUMBER=redo (edit as new) · "
            "a=delete all finished") in text


def _active(tmp_path, session_id):
    s = bs.new_session(_standalone_wl(tmp_path), str(tmp_path), session_id=session_id)
    bs.start(s)                                        # running with our live pid
    return s


def _with_artifacts(s):
    os.makedirs(s.workdir, exist_ok=True)
    marker = os.path.join(s.workdir, "artifact.img")
    with open(marker, "w", encoding="utf-8") as fh:
        fh.write("x")
    return marker


def test_plain_delete_all_prunes_every_finished_record_and_keeps_the_running_one(
        tmp_path):
    done = _finished(tmp_path, session_id="20260118-000001-aaaaaa")
    failed = _finished(tmp_path, session_id="20260118-000002-bbbbbb", status="failed")
    live = _active(tmp_path, "20260118-000003-cccccc")
    marker = _with_artifacts(done)
    text = _run_plain("a\ny\nn\nq\n")              # yes records, NO artifacts
    assert ("Delete every finished build-session record? Sessions still running are "
            "kept. [y/N]") in text
    assert "Deleted 2; skipped 1 still running." in text
    assert not os.path.exists(done.path()) and not os.path.exists(failed.path())
    assert os.path.exists(live.path())                 # never removed underneath it
    assert os.path.exists(marker)                      # artifacts: an explicit opt-in


def test_plain_delete_all_with_artifacts_removes_the_trees(tmp_path):
    done = _finished(tmp_path, session_id="20260119-000001-aaaaaa")
    _with_artifacts(done)
    text = _run_plain("a\ny\ny\nq\n")
    assert "Deleted 1; skipped 0 still running." in text
    assert not os.path.exists(done.workdir)


def test_plain_delete_all_declined_keeps_everything(tmp_path):
    done = _finished(tmp_path, session_id="20260120-000001-aaaaaa")
    text = _run_plain("a\nn\nq\n")
    assert "kept." in text
    assert os.path.exists(done.path())


def test_plain_delete_all_with_nothing_recorded_says_so(tmp_path):
    text = _run_plain("a\nq\n")
    assert "nothing to delete: no readable build session is recorded." in text


def test_plain_restart_hands_over_and_never_touches_the_record(tmp_path):
    s = _finished(tmp_path, session_id="20260121-000001-aaaaaa", status="failed")
    _with_artifacts(s)
    before = bs.load(s.path()).to_dict()
    text = _run_plain("s 1\nq\n")
    assert f"Restart session {s.id} rebuilds into {s.workdir}" in text
    assert "The TUI does not run builds. Restart it from the GUI" in text
    assert bs.load(s.path()).to_dict() == before       # nothing dispatched, nothing written


def test_plain_restart_refuses_an_active_session_with_the_reason(tmp_path):
    _active(tmp_path, "20260122-000001-aaaaaa")
    text = _run_plain("s 1\nq\n")
    assert ("not restarted: This session appears to be running in another Studio "
            "process — stop it there first.") in text


def test_plain_restart_without_a_workdir_offers_redo_and_redo_starts_the_journey(
        tmp_path):
    s = _finished(tmp_path, session_id="20260123-000001-aaaaaa", wl=_mesh_wl(tmp_path))
    assert not os.path.isdir(s.workdir)
    text = _run_plain("s 1\ny\n\n")                 # take the Redo, then Enter on welcome
    assert f"not restarted: Its artifact directory no longer exists:\n{s.workdir}" in text
    assert "Load its config into the journey now (Redo)? [y/N]" in text
    assert f"loaded the configuration of session {s.id}" in text
    # the journey's mode menu marks the LOADED config's mode (mesh, not the default)
    assert " * 3. Mesh node" in text


def test_plain_redo_from_the_journey_loads_its_config_and_resumes_on_welcome(tmp_path):
    from hugmesh_studio.tui import journey as journey_mod
    s = _finished(tmp_path, session_id="20260124-000001-aaaaaa", wl=_mesh_wl(tmp_path))
    j = journey_mod.Journey(str(tmp_path))
    out = io.StringIO()
    assert plain.run_journey(io.StringIO("2\ne 1\n"), out, generator_dir=str(tmp_path),
                             journey=j) == 0
    assert j.cfg.mode == "mesh"
    assert [e.id for e in j.worklist.entries] == ["pki.x86", "backend.rpi5"]
    assert j.slug == "welcome"
    assert f"loaded the configuration of session {s.id}" in out.getvalue()


def test_plain_redo_says_which_secrets_were_not_saved(tmp_path):
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      brand="acme", output_dir=str(tmp_path / "out"),
                      local_pass="hunter2")
    s = _finished(tmp_path, session_id="20260125-000001-aaaaaa", wl=synthesize(cfg))
    assert s.blanked_secrets == ["local_pass"]
    text = _run_plain("e 1\n")
    assert ("! local-pass was NOT saved (plaintext secret) — re-enter it before "
            "building from this config") in text
    assert "hunter2" not in text


def test_plain_redo_refuses_a_fleet_run_with_the_reason(tmp_path):
    s = _finished(tmp_path, session_id="20260126-000001-aaaaaa")
    s.kind = "fleet"
    bs.save(s)
    text = _run_plain("e 1\nq\n")
    assert "not redone: a fleet run is redone in the GUI's fleet window" in text
    assert "HugMesh Image Studio" not in text           # no journey was started


def test_plain_restart_refuses_a_config_that_gained_an_unconfigured_domain(tmp_path):
    # the per-domain services arm of the GUI's gate (#495), on the face CI runs
    from hugmesh_studio.core import domain_services as ds
    from hugmesh_studio.core.config import Domain
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                       output_dir=str(tmp_path / "out"), additional_domains=True,
                       domains=[Domain(name="a.example")])
    ds.record_reviewed(base, ["a.example"])
    base.domains.append(Domain(name="late.example"))
    s = _finished(tmp_path, session_id="20260127-000001-aaaaaa",
                  wl=WorklistConfig(base=base, entries=[
                      WorklistEntry(role="pki", platform="x86")]))
    os.makedirs(s.workdir)
    text = _run_plain("s 1\nn\nq\n")
    assert "not restarted: " in text and "late.example" in text
    assert "The TUI does not run builds" not in text   # refused: no hand-over


# ── GUI-28 round 2: a REDO survives the default key path (Enter, Enter) ─────────────
def _mesh_with_a_late_domain(tmp_path):
    """A mesh of two images whose configuration gained a domain after its services were
    recorded — the record the restart gate refuses with "Use Redo instead"."""
    from hugmesh_studio.core import domain_services as ds
    from hugmesh_studio.core.config import Domain
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                       output_dir=str(tmp_path / "out"), additional_domains=True,
                       domains=[Domain(name="a.example")])
    ds.record_reviewed(base, ["a.example"])
    base.domains.append(Domain(name="late.example"))
    return WorklistConfig(base=base, entries=[
        WorklistEntry(role="pki", platform="x86"),
        WorklistEntry(role="backend", platform="rpi5")])


def _redone(tmp_path, wl, session_id):
    """A journey with ``wl``'s session REDONE into it — on welcome, as the verb leaves it."""
    from hugmesh_studio.tui import journey as journey_mod
    s = _finished(tmp_path, session_id=session_id, wl=wl)
    j = journey_mod.Journey(str(tmp_path))
    assert j.load_session(s) == ""
    assert j.slug == "welcome"
    return j


def test_redo_then_enter_on_the_mode_menu_keeps_the_mesh_and_its_worklist(tmp_path):
    # Enter on the mode menu was hard-wired to "standalone", whatever was loaded: the
    # default key path of the Redo verb (Enter on welcome, Enter on the menu) switched a
    # mesh to standalone, which drops its worklist and clears its domains. The GUI's
    # mode page re-selects the loaded configuration's card instead
    j = _redone(tmp_path, _mesh_with_a_late_domain(tmp_path), "20260128-000001-aaaaaa")
    j.feed("")                                         # welcome: Start building
    assert j.slug == "mode"
    j.feed("")                                         # the mode menu: Enter
    assert j.cfg.mode == "mesh"
    assert [e.id for e in j.worklist.entries] == ["pki.x86", "backend.rpi5"]
    assert [d.name for d in j.cfg.domains] == ["a.example", "late.example"]
    assert j.cfg.additional_domains is True
    assert j.slug == "idp"                             # the mesh chain, not Image role


def test_redo_then_enter_on_the_mode_menu_keeps_a_desktop_client_too(tmp_path):
    from hugmesh_studio.core.config import Domain, User
    cfg = ImageConfig(mode="cloud", role="laptop", platform="x86", brand="acme",
                      output_dir=str(tmp_path / "out"), keyzip="/keys/admin-keys.zip",
                      domains=[Domain(name="a.example")],
                      users=[User(username="alice", domain="a.example")])
    j = _redone(tmp_path, synthesize(cfg), "20260128-000002-aaaaaa")
    j.feed("")
    j.feed("")
    assert (j.cfg.mode, j.cfg.role) == ("cloud", "laptop")
    assert [d.name for d in j.cfg.domains] == ["a.example"]
    assert [u.username for u in j.cfg.users] == ["alice"]
    assert j.cfg.keyzip == "/keys/admin-keys.zip"
    assert j.slug == "role"


def test_a_config_holding_no_image_mode_falls_back_to_the_default_choice(tmp_path):
    # the GUI leaves its default card checked when it finds no card for cfg.mode; a
    # hand-edited mode must not reach commit_mode, which indexes the role table by it
    from types import SimpleNamespace

    from hugmesh_studio.tui import journey as journey_mod
    assert journey_mod.mode_enter_choice(SimpleNamespace(mode="banana")) == "standalone"
    assert journey_mod.mode_enter_choice(SimpleNamespace(mode="e2e")) == "standalone"
    for mode in ("mesh", "cloud", "standalone"):
        assert journey_mod.mode_enter_choice(SimpleNamespace(mode=mode)) == mode
    j = journey_mod.Journey(str(tmp_path))
    j.cfg.mode = "banana"
    j.feed("")
    j.feed("")                                         # Enter on the menu: no KeyError
    assert (j.cfg.mode, j.slug) == ("standalone", "role")


def test_redo_of_a_standalone_build_still_enters_the_standalone_chain(tmp_path):
    j = _redone(tmp_path, _standalone_wl(tmp_path), "20260128-000003-aaaaaa")
    j.feed("")
    j.feed("")
    assert (j.cfg.mode, j.cfg.role) == ("standalone", "standalone-thick")
    assert j.slug == "role"


def test_the_mode_menu_says_what_enter_takes_and_typing_a_number_still_switches(
        tmp_path):
    from hugmesh_studio.tui import journey as journey_mod
    fresh = journey_mod.Journey(str(tmp_path))
    fresh.feed("")
    assert fresh.prompt() == "mode (Enter=Standalone Gentoo desktop)> "
    assert [ln for ln in fresh.lines() if ln.startswith("(Enter = ")] == [
        "(Enter = Standalone Gentoo desktop — the default, by id; * marks the loaded "
        "config's mode)"]
    j = _redone(tmp_path, _mesh_with_a_late_domain(tmp_path), "20260128-000004-aaaaaa")
    # the Redo's own message says it, before the menu is even open
    assert "Enter on the mode menu keeps its mode (marked *)" in j.status
    j.feed("")
    # the prompt is on screen at every terminal size; the hint line under the ten cards
    # is not (it is below the fold at 80x24)
    assert j.prompt() == "mode (Enter=Mesh node)> "
    assert [ln for ln in j.lines() if ln.startswith("(Enter = ")] == [
        "(Enter = Mesh node — keeps the loaded config's mode, marked *; a NUMBER picks "
        "another)"]
    assert " * 3. Mesh node" in j.lines()
    j.feed("10")                                       # a typed number is a real switch
    assert j.cfg.mode == "standalone"
    assert j.cfg.domains == []                         # ...with the standalone clears


def test_plain_restart_refused_then_redo_then_enter_walks_the_loaded_mesh(tmp_path):
    # the route, key for key: `s 1` is refused and names Redo and the Domain services
    # step, y takes the Redo, then Enter on every screen. The walk has to reach that
    # step for the domain the refusal named, and end on a Build screen for the mesh
    s = _finished(tmp_path, session_id="20260128-000005-aaaaaa",
                  wl=_mesh_with_a_late_domain(tmp_path))
    os.makedirs(s.workdir)                 # the workdir is there: the services arm refuses
    out = io.StringIO()
    assert plain.run_sessions_review(inp=io.StringIO("s 1\ny\n" + "\n" * 30), out=out,
                                     generator_dir=str(tmp_path)) == 0
    text = out.getvalue()
    assert "not restarted: " in text and "Use Redo instead" in text
    assert "Load its config into the journey now (Redo)? [y/N]" in text
    assert f"loaded the configuration of session {s.id}" in text
    assert "mode (Enter=Mesh node)> " in text
    assert "Identity provider (mesh nodes)" in text    # Enter on the menu kept the mesh
    assert "Image role" not in text                    # ...and never the standalone chain
    assert "Still to go: late.example" in text         # the step the refusal promised
    assert "  mode      mesh" in text                  # the Build screen's summary
    assert "  worklist  2 image(s): pki.x86, backend.rpi5" in text
    assert "  domains   2" in text


# ── GUI-28 round 2: a fleet run's restart is the fleet window's, not the wizard's ───
def test_plain_restart_of_a_fleet_run_hands_over_to_the_fleet_window(tmp_path):
    # the GUI never asks "Rebuild into …? Existing artifacts will be reused/overwritten"
    # for a fleet run: it reopens the fleet window on its Review step, pinned to the
    # record, and "Build fleet now" there is the confirmation
    s = _finished(tmp_path, session_id="20260129-000001-aaaaaa", status="failed")
    s.kind = "fleet"
    bs.save(s)
    _with_artifacts(s)
    before = bs.load(s.path()).to_dict()
    text = _run_plain("s 1\nq\n")
    assert f"Restart session {s.id} is a fleet run" in text
    assert "‘Build fleet now’ there is the confirmation" in text
    assert s.workdir in text
    assert "rebuilds into" not in text
    assert "existing artifacts will be reused/overwritten" not in text
    assert ("The TUI does not run builds. Restart it from the GUI: python -m "
            "hugmesh_studio → Review prior sessions → select this build → Restart "
            "(its fleet window opens on the Review step, pinned to this record).") in text
    assert bs.load(s.path()).to_dict() == before       # a hand-over: nothing written


def test_a_wizard_restart_keeps_the_gui_confirmation_wording(tmp_path):
    # the non-fleet hand-over is unchanged by the fleet wording above
    s = _finished(tmp_path, session_id="20260129-000002-aaaaaa", status="failed")
    _with_artifacts(s)
    lines = model.restart_handover_lines(s)
    assert lines[0] == f"Restart session {s.id} rebuilds into {s.workdir}"
    assert lines[1] == "  existing artifacts will be reused/overwritten."
    assert "(the build starts on the Build progress page)." in lines[-1]

"""tui — the urwid face, run ONLY where urwid is importable (soft dependency).

The whole module skips when urwid is absent (importorskip), so the studio suite
stays green without it. Everything renders to an in-memory canvas — no terminal.
"""
import os

import pytest

urwid = pytest.importorskip("urwid")

from hugmesh_studio.core import build_sessions as bs                    # noqa: E402
from hugmesh_studio.core.config import ImageConfig                      # noqa: E402
from hugmesh_studio.core.worklist import (                              # noqa: E402
    WorklistConfig, WorklistEntry, synthesize)
from hugmesh_studio.tui import journey, urwid_ui                        # noqa: E402


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def _finished(tmp_path, *, session_id, status="complete", mesh=False):
    if mesh:
        base = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                           output_dir=str(tmp_path / "out"))
        wl = WorklistConfig(base=base, entries=[
            WorklistEntry(role="pki", platform="x86"),
            WorklistEntry(role="backend", platform="rpi5")])
    else:
        wl = synthesize(ImageConfig(mode="standalone", role="standalone-thick",
                                    platform="x86", brand="acme",
                                    output_dir=str(tmp_path / "out")))
    s = bs.new_session(wl, str(tmp_path), session_id=session_id)
    bs.start(s)
    bs.finish(s, status)
    return s


def _screen_text(widget) -> str:
    canvas = widget.render((100, 30))
    return "\n".join(line.decode("utf-8", "replace") for line in canvas.text)


def test_list_renders_sessions_and_unreadable_records(tmp_path):
    _finished(tmp_path, session_id="20260101-000001-aaaaaa")
    os.makedirs(bs.sessions_dir(), exist_ok=True)
    with open(os.path.join(bs.sessions_dir(), "zz-bad.json"), "w",
              encoding="utf-8") as fh:
        fh.write("{not json")
    app = urwid_ui.SessionsReview()
    text = _screen_text(app.frame)
    assert "20260101-000001-aaaaaa" in text
    assert "complete" in text
    assert "2. ! unreadable record zz-bad.json — only delete applies" in text
    assert "skipped" not in text


def test_detail_and_worklist_screens_render(tmp_path):
    _finished(tmp_path, session_id="20260102-000001-bbbbbb", mesh=True)
    app = urwid_ui.SessionsReview()
    app.show_detail(app.rows[0])
    text = _screen_text(app.frame)
    assert "session   20260102-000001-bbbbbb" in text
    assert "pki.x86: pki · x86" in text
    app.show_worklist(app.rows[0])
    text = _screen_text(app.frame)
    assert "board/flavor" in text and "backend.rpi5" in text


def test_delete_flow_confirms_twice_then_deletes(tmp_path):
    s = _finished(tmp_path, session_id="20260103-000001-cccccc")
    os.makedirs(s.workdir)
    marker = os.path.join(s.workdir, "artifact.img")
    with open(marker, "w", encoding="utf-8") as fh:
        fh.write("x")
    app = urwid_ui.SessionsReview()
    app.start_delete(app.rows[0])
    assert app.mode == "confirm"
    assert "Delete session 20260103-000001-cccccc" in _screen_text(app.frame)
    app._confirm_yes()                                 # record: yes → artifacts stage
    assert "ALSO delete its artifact tree" in _screen_text(app.frame)
    app._confirm_no()                                  # artifacts: no → record only
    assert not os.path.exists(s.path())
    assert os.path.exists(marker)
    assert "record only" in _screen_text(app.frame)


def test_delete_refuses_an_active_session_with_the_reason(tmp_path):
    wl = synthesize(ImageConfig(mode="standalone", role="standalone-thick",
                                platform="x86", brand="acme",
                                output_dir=str(tmp_path / "out")))
    s = bs.new_session(wl, str(tmp_path), session_id="20260104-000001-dddddd")
    bs.start(s)                                        # active: our own live pid
    app = urwid_ui.SessionsReview()
    app.start_delete(app.rows[0])
    assert app.mode == "list"                          # no confirm screen offered
    assert "not deleted" in _screen_text(app.frame)
    assert os.path.exists(s.path())


def test_q_on_the_list_exits_the_main_loop(tmp_path):
    app = urwid_ui.SessionsReview()
    with pytest.raises(urwid.ExitMainLoop):
        app.unhandled("q")


def test_q_on_a_subscreen_goes_back_not_out(tmp_path):
    _finished(tmp_path, session_id="20260105-000001-eeeeee")
    app = urwid_ui.SessionsReview()
    app.show_detail(app.rows[0])
    app.unhandled("q")                                 # back to the list, no exit
    assert app.mode == "list"


# ── the journey (urwid face): the same state machine, rendered to a canvas ──────────
def _typed(app, text: str) -> None:
    """Type a command line into the footer Edit and press Enter — the exact
    input path a terminal operator uses."""
    app.input.set_edit_text(text)
    app.unhandled("enter")


def test_journey_opens_on_the_welcome_screen(tmp_path):
    app = urwid_ui.JourneyApp(str(tmp_path))
    text = _screen_text(app.root)
    assert "HugMesh Studio — HugMesh Image Studio" in text
    assert "Start building" in text and "Review prior sessions" in text


def test_journey_enter_feeds_the_edit_line_into_the_state_machine(tmp_path):
    app = urwid_ui.JourneyApp(str(tmp_path))
    _typed(app, "")                                    # default: -> mode
    assert app.journey.slug == "mode"
    text = _screen_text(app.root)
    assert "What do you want to build?" in text
    assert "Mesh emulation" in text                    # the #69 card renders
    assert app.input.edit_text == ""                   # the line was consumed


def test_journey_mode_cards_are_reachable_by_paging_at_80x24(tmp_path):
    app = urwid_ui.JourneyApp(str(tmp_path))
    _typed(app, "")                                    # -> mode menu
    # the last CARD's own row ("10. Standalone Gentoo desktop"): its bare title is also
    # in the prompt, which names what Enter takes and is on screen at every size
    last = f"{len(journey.MODE_CHOICES)}. {journey.MODE_CHOICES[-1][1]}"
    size = (80, 24)
    first = "\n".join(ln.decode("utf-8", "replace")
                      for ln in app.root.render(size).text)
    assert last not in first                           # off-screen before paging
    for _ in range(5):
        app.root.keypress(size, "page down")
    text = "\n".join(ln.decode("utf-8", "replace")
                     for ln in app.root.render(size).text)
    assert last in text
    app.root.keypress(size, "page up")                 # and back up again
    app.root.keypress(size, "page up")
    app.root.keypress(size, "page up")
    app.root.keypress(size, "page up")
    app.root.keypress(size, "page up")
    back = "\n".join(ln.decode("utf-8", "replace")
                     for ln in app.root.render(size).text)
    assert "What do you want to build?" in back


def test_journey_sessions_entry_swaps_in_the_review_and_back(tmp_path):
    _finished(tmp_path, session_id="20260106-000001-ffffff")
    app = urwid_ui.JourneyApp(str(tmp_path))
    _typed(app, "2")                                   # Review prior sessions (card 2 of 2)
    assert app.sessions is not None
    assert "previous builds" in _screen_text(app.root)
    assert "20260106-000001-ffffff" in _screen_text(app.root)
    app.unhandled("q")                                 # the review's list-q: back
    assert app.sessions is None
    assert "Start building" in _screen_text(app.root)  # the journey resumed


def test_journey_q_exits_the_main_loop(tmp_path):
    app = urwid_ui.JourneyApp(str(tmp_path))
    with pytest.raises(urwid.ExitMainLoop):
        _typed(app, "q")


def test_journey_inline_status_renders_never_a_modal(tmp_path):
    app = urwid_ui.JourneyApp(str(tmp_path))
    _typed(app, "banana")
    assert "unrecognised" in _screen_text(app.root)


# ── GUI-28 (B-10/B-11): the list keys, driven the way an operator drives them ────────
_SIZE = (100, 30)


def _corrupt(name="zz-bad.json"):
    os.makedirs(bs.sessions_dir(), exist_ok=True)
    bad = os.path.join(bs.sessions_dir(), name)
    with open(bad, "w", encoding="utf-8") as fh:
        fh.write("{not json")
    return bad


def _focus(app, index):
    """Move the list's focus to entry ``index`` (0-based) with the arrow keys."""
    for _ in range(index):
        app.frame.keypress(_SIZE, "down")


def test_w_and_d_keys_on_the_list_do_not_crash(tmp_path):
    # ListBox.get_focus() is gone from current urwid: pressing d or w on the list raised
    # AttributeError out of unhandled_input, which kills the whole TUI
    _finished(tmp_path, session_id="20260107-000001-aaaaaa", mesh=True)
    app = urwid_ui.SessionsReview()
    app.unhandled("w")
    assert app.mode == "worklist"
    assert "backend.rpi5" in _screen_text(app.frame)
    app.unhandled("q")
    app.unhandled("d")
    assert app.mode == "confirm"


def test_an_unreadable_record_is_focusable_and_d_deletes_it(tmp_path):
    s = _finished(tmp_path, session_id="20260108-000001-aaaaaa")
    bad = _corrupt()
    app = urwid_ui.SessionsReview()
    _focus(app, 1)
    app.unhandled("d")
    assert app.mode == "confirm"
    assert "Delete this unreadable record file?" in _screen_text(app.frame)
    app._confirm_yes()
    assert not os.path.exists(bad)
    assert os.path.exists(s.path())
    assert "deleted the unreadable record" in _screen_text(app.frame)


def test_only_unreadable_records_are_still_reachable(tmp_path):
    # the "(no build sessions recorded yet)" line shifts every position by one
    bad = _corrupt()
    app = urwid_ui.SessionsReview()
    _focus(app, 1)
    app.unhandled("d")
    assert app.mode == "confirm"
    app._confirm_yes()
    assert not os.path.exists(bad)


def test_enter_on_an_unreadable_record_shows_it_and_d_there_deletes_it(tmp_path):
    bad = _corrupt()
    app = urwid_ui.SessionsReview()
    app.frame.keypress(_SIZE, "enter")
    assert app.mode == "detail"
    assert "only delete (removing the file) applies" in " ".join(
        _screen_text(app.frame).split())                # the sentence wraps at 100 cols
    app.unhandled("d")
    assert app.mode == "confirm"
    app._confirm_no()
    assert os.path.exists(bad)


def test_d_on_a_build_detail_never_deletes_an_unreadable_record_seen_earlier(tmp_path):
    _finished(tmp_path, session_id="20260109-000001-aaaaaa")
    bad = _corrupt()
    app = urwid_ui.SessionsReview()
    _focus(app, 1)
    app.frame.keypress(_SIZE, "enter")                 # the unreadable record's screen
    app.unhandled("q")
    app.show_detail(app.rows[0])                       # now a build's detail screen
    app.unhandled("d")
    assert app.mode == "detail"                        # nothing was asked
    assert os.path.exists(bad)


@pytest.mark.parametrize("key, said", [("w", "worklist"), ("s", "restart"),
                                       ("e", "redo")])
def test_build_keys_on_an_unreadable_record_say_why_not(tmp_path, key, said):
    bad = _corrupt()
    app = urwid_ui.SessionsReview()
    app.on_redo = lambda s: ""
    _focus(app, 1)
    app.unhandled(key)
    assert app.mode == "list"
    assert f"no {said} for an unreadable record" in _screen_text(app.frame)
    assert os.path.exists(bad)


def test_the_footer_offers_restart_redo_and_delete_all(tmp_path):
    app = urwid_ui.SessionsReview()
    assert "build actions: s=restart  e=redo (edit as new)  a=delete all finished" in \
        _screen_text(app.frame)


def test_a_deletes_all_finished_and_keeps_the_running_one(tmp_path):
    done = _finished(tmp_path, session_id="20260110-000001-aaaaaa")
    live = bs.new_session(synthesize(ImageConfig(
        mode="standalone", role="standalone-thick", platform="x86", brand="acme",
        output_dir=str(tmp_path / "out"))), str(tmp_path),
        session_id="20260110-000002-bbbbbb")
    bs.start(live)
    os.makedirs(done.workdir)
    app = urwid_ui.SessionsReview()
    app.unhandled("a")
    assert "Delete every finished build-session record?" in _screen_text(app.frame)
    app._confirm_yes()
    assert "ALSO delete their build artifacts on disk?" in _screen_text(app.frame)
    app._confirm_no()                                  # records yes, artifacts no
    assert not os.path.exists(done.path())
    assert os.path.isdir(done.workdir)
    assert os.path.exists(live.path())
    assert "Deleted 1; skipped 1 still running." in _screen_text(app.frame)


def test_s_hands_over_a_restart_and_writes_nothing(tmp_path):
    s = _finished(tmp_path, session_id="20260111-000001-aaaaaa", status="failed")
    os.makedirs(s.workdir)
    before = bs.load(s.path()).to_dict()
    app = urwid_ui.SessionsReview()
    app.unhandled("s")
    assert app.mode == "restart"
    text = _screen_text(app.frame)
    assert f"Restart session {s.id} rebuilds into" in text
    assert "The TUI does not run builds." in text
    assert bs.load(s.path()).to_dict() == before


def test_e_loads_the_config_into_the_journey_and_shows_it(tmp_path):
    s = _finished(tmp_path, session_id="20260112-000001-aaaaaa", mesh=True)
    app = urwid_ui.JourneyApp(str(tmp_path))
    _typed(app, "2")                                   # Review prior sessions
    app.unhandled("e")
    assert app.sessions is None                        # back on the journey
    assert app.journey.cfg.mode == "mesh"
    assert [e.id for e in app.journey.worklist.entries] == ["pki.x86", "backend.rpi5"]
    assert f"loaded the configuration of session {s.id}" in _screen_text(app.root)


def test_s_without_a_workdir_offers_redo_like_the_gui(tmp_path):
    s = _finished(tmp_path, session_id="20260113-000001-aaaaaa", mesh=True)
    app = urwid_ui.JourneyApp(str(tmp_path))
    _typed(app, "2")
    app.unhandled("s")
    assert "Load its config into the journey now (Redo)?" in _screen_text(app.root)
    app.sessions.review._confirm_yes()
    assert app.sessions is None
    assert f"loaded the configuration of session {s.id}" in _screen_text(app.root)


def test_sessions_only_quits_on_q_but_a_redo_hands_over_to_the_journey(tmp_path):
    _finished(tmp_path, session_id="20260114-000001-aaaaaa", mesh=True)
    app = urwid_ui.JourneyApp(str(tmp_path), sessions_only=True)
    assert "previous builds" in _screen_text(app.root)
    with pytest.raises(urwid.ExitMainLoop):
        app.unhandled("q")                             # `tui --sessions`: q quits
    app = urwid_ui.JourneyApp(str(tmp_path), sessions_only=True)
    app.unhandled("e")
    assert app.sessions is None and not app.sessions_only
    assert "Start building" in _screen_text(app.root)


# ── GUI-28 round 2: REDO on the default key path, keys sent the way MainLoop sends them ─
def _press(app, size, *keys):
    """Send keys as urwid's MainLoop does: the top widget first, and whatever it does
    not take goes to the app's ``unhandled_input``."""
    for key in keys:
        left = app.root.keypress(size, key)
        if left:
            app.unhandled(left)


def _text_at(app, size) -> str:
    return "\n".join(ln.decode("utf-8", "replace") for ln in app.root.render(size).text)


def _flat(text: str) -> str:
    """One line, single spaces: a sentence reads the same however the terminal wrapped it."""
    return " ".join(text.split())


def _mesh_with_a_late_domain(tmp_path, session_id):
    """A mesh of two images whose configuration gained a domain after its services were
    recorded, with its workdir present — the restart gate refuses it and names Redo."""
    from hugmesh_studio.core import domain_services as ds
    from hugmesh_studio.core.config import Domain
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                       output_dir=str(tmp_path / "out"), additional_domains=True,
                       domains=[Domain(name="a.example")])
    ds.record_reviewed(base, ["a.example"])
    base.domains.append(Domain(name="late.example"))
    s = bs.new_session(WorklistConfig(base=base, entries=[
        WorklistEntry(role="pki", platform="x86"),
        WorklistEntry(role="backend", platform="rpi5")]), str(tmp_path),
        session_id=session_id)
    bs.start(s)
    bs.finish(s, "complete")
    os.makedirs(s.workdir)
    return s


@pytest.mark.parametrize("size", [(80, 24), (132, 43)])
def test_restart_refused_then_redo_then_enter_keeps_the_mesh(tmp_path, size):
    # `tui --sessions`: s on the mesh is refused and names Redo; Yes takes it; then
    # Enter on welcome and Enter on the mode menu. That second Enter was hard-wired to
    # "standalone" and threw the loaded worklist and domains away
    _mesh_with_a_late_domain(tmp_path, "20260115-000001-aaaaaa")
    app = urwid_ui.JourneyApp(str(tmp_path), sessions_only=True)
    _press(app, size, "s")
    assert "Use Redo instead" in _flat(_text_at(app, size))
    _press(app, size, "down", "enter")                 # Yes (No has the focus)
    assert app.sessions is None                        # the journey owns the screen
    _press(app, size, "enter")                         # welcome: Start building
    assert app.journey.slug == "mode"
    menu = _text_at(app, size)
    assert " * 3. Mesh node" in menu
    assert "mode (Enter=Mesh node)>" in menu           # said without scrolling, any size
    _press(app, size, "enter")                         # the mode menu: Enter
    assert app.journey.cfg.mode == "mesh"
    assert [e.id for e in app.journey.worklist.entries] == ["pki.x86", "backend.rpi5"]
    assert [d.name for d in app.journey.cfg.domains] == ["a.example", "late.example"]
    assert "Identity provider (mesh nodes)" in _text_at(app, size)
    # ...and Enter on every step reaches the one the refusal named, for that domain
    for _ in journey.PAGE_ORDER:
        if app.journey.slug == "domain_services":
            break
        _press(app, size, "enter")
    assert app.journey.slug == "domain_services"
    assert any("Still to go: late.example" in ln for ln in app.journey.lines())


def test_typing_another_number_on_the_mode_menu_is_still_a_switch(tmp_path):
    _mesh_with_a_late_domain(tmp_path, "20260115-000002-aaaaaa")
    app = urwid_ui.JourneyApp(str(tmp_path), sessions_only=True)
    _press(app, _SIZE, "e", "enter", "1", "0", "enter")    # Redo, welcome, then "10"
    assert app.journey.cfg.mode == "standalone"
    assert app.journey.cfg.domains == []


def test_redo_shows_the_unsaved_secret_warning_without_scrolling_at_80x24(tmp_path):
    # the GUI raises this warning as a dialog. Here it is the last line of the welcome
    # screen, which is taller than an 80x24 terminal: it was two rows below the fold
    s = bs.new_session(synthesize(ImageConfig(
        mode="standalone", role="standalone-thick", platform="x86", brand="acme",
        output_dir=str(tmp_path / "out"), local_pass="hunter2")), str(tmp_path),
        session_id="20260115-000003-aaaaaa")
    bs.start(s)
    bs.finish(s, "complete")
    assert s.blanked_secrets == ["local_pass"]
    size = (80, 24)
    app = urwid_ui.JourneyApp(str(tmp_path), sessions_only=True)
    _press(app, size, "e")
    shown = _flat(_text_at(app, size))
    assert f"loaded the configuration of session {s.id}" in shown
    assert ("! local-pass was NOT saved (plaintext secret) — re-enter it before "
            "building from this config") in shown
    assert "hunter2" not in shown
    assert "welcome>" in shown                         # the prompt is still under it
    for _ in range(3):                                 # and the top is a Page Up away
        _press(app, size, "page up")
    assert "HugMesh is a self-hosted mesh" in _text_at(app, size)


def test_a_screen_without_a_message_still_opens_at_its_top_at_80x24(tmp_path):
    app = urwid_ui.JourneyApp(str(tmp_path))
    size = (80, 24)
    assert "HugMesh is a self-hosted mesh" in _text_at(app, size)
    _press(app, size, "enter")                         # the mode menu: ten cards
    first = _text_at(app, size)
    assert "Pick one." in first and "1. Local Docker mesh" in first


# ── GUI-28 round 2: the review's status line answers ONE screen ─────────────────────
def _a_refusal_on_the_list(tmp_path):
    """A review whose status line holds a refusal about its FIRST row (a running build);
    row 1 is a finished build with its workdir, row 2 an unreadable record."""
    done = _finished(tmp_path, session_id="20260116-000001-aaaaaa")
    os.makedirs(done.workdir)
    live = bs.new_session(synthesize(ImageConfig(
        mode="standalone", role="standalone-thick", platform="x86", brand="acme",
        output_dir=str(tmp_path / "out"))), str(tmp_path),
        session_id="20260116-000002-bbbbbb")
    bs.start(live)                                     # running: our own live pid
    _corrupt()
    app = urwid_ui.SessionsReview()
    assert [r.session.id for r in app.rows] == [live.id, done.id]
    app.unhandled("s")                                 # the running build: refused
    assert "not restarted: This session appears to be running" in _flat(
        _screen_text(app.frame))
    return app


@pytest.mark.parametrize("key, row, mode", [
    ("s", 1, "restart"), ("w", 1, "worklist"), ("d", 1, "confirm"), ("a", 1, "confirm"),
    ("enter", 1, "detail"), ("enter", 2, "detail"), ("d", 2, "confirm")])
def test_a_refusal_never_follows_the_person_onto_another_screen(tmp_path, key, row, mode):
    # "not restarted: … running in another Studio process" was said about ONE build and
    # then stayed under the hand-over, the worklist, the questions and the detail of
    # every other row, and under the list again after them
    app = _a_refusal_on_the_list(tmp_path)
    _focus(app, row)                                   # another row: a build, or the
    if key == "enter":                                 # unreadable record under it
        app.frame.keypress(_SIZE, "enter")
    else:
        app.unhandled(key)
    assert app.mode == mode
    assert "not restarted" not in _screen_text(app.frame)
    app.unhandled("q")                                 # back: the list is clean too
    assert app.mode == "list"
    assert "not restarted" not in _screen_text(app.frame)


def test_r_re_reads_the_list_and_drops_the_last_answer(tmp_path):
    app = _a_refusal_on_the_list(tmp_path)
    app.unhandled("r")
    assert app.mode == "list"
    assert "not restarted" not in _screen_text(app.frame)


def test_an_answer_stays_on_the_screen_it_was_said_on(tmp_path):
    # the other half of the rule: a result is still shown where it happened
    done = _finished(tmp_path, session_id="20260117-000001-aaaaaa")
    app = urwid_ui.SessionsReview()
    app.unhandled("d")
    app._confirm_yes()
    assert not os.path.exists(done.path())
    assert f"deleted session {done.id} (record only)." in _screen_text(app.frame)
    app.unhandled("a")                                 # nothing left: said on the list
    assert "nothing to delete" in _screen_text(app.frame)


def test_s_on_a_fleet_run_hands_over_to_the_fleet_window(tmp_path):
    s = _finished(tmp_path, session_id="20260118-000001-aaaaaa", status="failed")
    s.kind = "fleet"
    bs.save(s)
    os.makedirs(s.workdir)
    app = urwid_ui.SessionsReview()
    app.unhandled("s")
    assert app.mode == "restart"
    shown = _flat(_screen_text(app.frame))
    assert f"Restart session {s.id} is a fleet run" in shown
    assert "‘Build fleet now’ there is the confirmation" in shown
    assert "reused/overwritten" not in shown

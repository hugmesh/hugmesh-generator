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
from hugmesh_studio.tui import urwid_ui                                 # noqa: E402


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
    assert "unreadable record skipped" in text


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


def test_journey_sessions_entry_swaps_in_the_review_and_back(tmp_path):
    _finished(tmp_path, session_id="20260106-000001-ffffff")
    app = urwid_ui.JourneyApp(str(tmp_path))
    _typed(app, "3")                                   # Review prior sessions
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

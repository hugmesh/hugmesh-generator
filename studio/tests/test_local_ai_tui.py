"""The terminal faces and the command line: Local AI status line, screen and flags.

Three groups, each driven without a terminal and without the Ollama on the host:

  * PLAIN face (no urwid needed): the status line is printed above each prompt, the
    command ``local-ai`` opens the screen over whatever screen is up and ``q`` returns
    to exactly it, a question typed there is sent to the (fake) model and shown, and
    drawing the line makes no network call.
  * URWID face (skipped when urwid is not installed): the line is the bottom row of the
    window, F2 opens the screen, focus stays in the prompt so typing still works.
  * COMMAND LINE: ``--local-ai-status [--json]`` and ``--local-ai-prompt`` print what the
    dock shows and exit non-zero with a plain sentence when Ollama is down.
"""
import http.client
import io
import json
import os
import subprocess
import sys
import time

import pytest
from _local_ai_fake import FakeOllama

from hugmesh_studio.core import local_ai_status as lai
from hugmesh_studio.tui import journey, local_ai, plain

#: the real prompt function, taken before the autouse fixture below replaces it
REAL_SEND_PROMPT = lai.send_prompt


@pytest.fixture
def fake():
    f = FakeOllama()
    yield f
    f.close()


@pytest.fixture
def state(tmp_path, monkeypatch):
    d = tmp_path / "localai"
    monkeypatch.setenv("HUGMESH_LOCAL_AI_DIR", str(d))
    return str(d)


def write_status(state, pid, age=1.0, loaded=("qwen3:8b",), up=True):
    os.makedirs(state, exist_ok=True)
    with open(os.path.join(state, "status.json"), "w") as fh:
        json.dump({"pid": pid, "heartbeat": time.time() - age, "ollama_up": up,
                   "model_loaded": list(loaded)}, fh)


def queue_job(state, bucket, name, line="draft hugmesh-generator 5"):
    d = os.path.join(state, "queue", bucket)
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, name + ".job"), "w").write(line + "\n")


@pytest.fixture
def worker_proc():
    p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)", "local-ai-worker"])
    yield p
    p.kill()
    p.wait()


def fake_snapshot():
    s = lai.Snapshot(taken=time.time(), state_dir="/tmp/x", host="127.0.0.1:11434", ollama_up=True,
                     ollama_installed=True, models=["qwen3:8b"], loaded=["qwen3:8b"], worker="running",
                     worker_pid=3, heartbeat_age=1.0,
                     counts={"pending": 1, "running": 1, "stalled": 0, "done": 0, "drafts": 1, "builds": 0})
    s.jobs = [lai.Job("queue", "j", "draft hugmesh-generator#5", "running"),
              lai.Job("draft", "hugmesh-generator-4", "hugmesh-generator-4  A title", "applied")]
    s.summary = lai.summary_line(s)
    return s


@pytest.fixture(autouse=True)
def _no_real_ollama(monkeypatch):
    """Nothing here may reach the Ollama that runs on the host. Tests that exercise the
    real functions point OLLAMA_HOST at a fake instead."""
    real = lai.read_snapshot
    # quick_snapshot passes a `probe` (the worker's status.json) and must stay real; only a
    # live read, which would ask the host's Ollama, is faked
    monkeypatch.setattr(lai, "read_snapshot",
                        lambda *a, **k: real(*a, **k) if k.get("probe") else fake_snapshot())
    monkeypatch.setattr(lai, "send_prompt",
                        lambda text, *a, **k: "fake answer to: " + text)


def run_plain(script, generator_dir="."):
    out = io.StringIO()
    rc = plain.run_journey(inp=io.StringIO(script), out=out, generator_dir=generator_dir)
    return rc, out.getvalue()


# ── the status line ──────────────────────────────────────────────────────────────────
def test_the_line_says_no_worker_is_running_when_nothing_has_been_started(state):
    assert lai.quick_line() == "Local AI: no worker running"


def test_the_line_reads_the_workers_status_and_the_queue(state, worker_proc):
    write_status(state, worker_proc.pid)
    queue_job(state, "pending", "20260101-000001-draft-hugmesh-generator-5")
    queue_job(state, "pending", "20260101-000002-draft-hugmesh-generator-6", "draft hugmesh-generator 6")
    queue_job(state, "running", "20260101-000000-draft-hugmesh-generator-4", "draft hugmesh-generator 4")
    assert lai.quick_line() == "Local AI: ready, qwen3:8b loaded, 2 queued, 1 running"


def test_a_stalled_worker_is_not_shown_as_running(state, worker_proc):
    write_status(state, worker_proc.pid, age=lai.STALE_AFTER + 10)
    queue_job(state, "running", "20260101-000000-draft-hugmesh-generator-4", "draft hugmesh-generator 4")
    line = lai.quick_line()
    assert "stalled" in line and "1 running" not in line


def test_an_old_status_file_never_says_ready(state, worker_proc):
    """status.json is a witness only while its writer is alive and beating. One that is an
    hour old, or whose writer is gone, must not put 'ready, X loaded, idle' on the line."""
    dead = subprocess.Popen([sys.executable, "-c", "pass"])
    dead.wait()
    for pid, age in ((dead.pid, 3600.0), (dead.pid, 0.5), (0, 0.5), (worker_proc.pid, 3600.0)):
        write_status(state, pid, age=age, up=True, loaded=("qwen3:8b",))
        line = lai.quick_line()
        assert "ready" not in line and "loaded" not in line and "idle" not in line, (pid, age, line)
        assert "no worker running" in line or "stalled" in line, (pid, age, line)


def test_the_unknown_server_state_is_not_called_a_problem(state):
    """A stopped worker does not know whether Ollama is up, so the snapshot must not
    invent 'Ollama is not answering' either."""
    write_status(state, 0, age=3600.0, up=True)
    snap = lai.quick_snapshot()
    assert snap.ok and snap.checked is False and not snap.ollama_up


def test_a_stopped_worker_still_counts_what_is_waiting(state):
    write_status(state, 0, age=1.0, up=True)
    queue_job(state, "pending", "20260101-000001-draft-hugmesh-generator-5")
    assert lai.quick_line() == "Local AI: no worker running, 1 queued"


def test_drawing_the_line_makes_no_network_call(state, monkeypatch):
    import urllib.request

    def boom(*a, **k):
        raise AssertionError("the status line asked the network")
    monkeypatch.setattr(urllib.request.OpenerDirector, "open", boom)
    assert local_ai.status_line().startswith("Local AI:") and "[F2]" in local_ai.status_line()
    assert local_ai.plain_status_line().startswith("[Local AI:") and "local-ai" in local_ai.plain_status_line()


# ── the plain face ───────────────────────────────────────────────────────────────────
def test_plain_prints_the_status_line_above_every_prompt(state):
    rc, text = run_plain("\n")
    assert rc == 0
    lines = text.splitlines()
    i = next(n for n, ln in enumerate(lines) if ln.startswith("[Local AI:"))
    assert lines[i].endswith("type local-ai]")
    assert lines[i + 1].startswith("welcome> ")       # directly above the prompt


def test_the_local_ai_command_opens_the_screen_and_q_returns_to_where_you_were(state):
    rc, text = run_plain("local-ai\nq\n")
    assert rc == 0
    assert "Local AI\n" in text and "Local AI: ready, qwen3:8b loaded, 1 queued, 1 running" in text
    assert "local-ai> " in text
    assert text.count("welcome> ") == 2              # welcome, the screen, then welcome again
    assert "hugmesh-generator-4" in text and "applied" in text    # the work list


def test_the_screen_opens_over_a_deeper_screen_and_returns_to_it(state):
    j = journey.Journey(".")
    j.feed("1")                                       # welcome -> the mode menu
    title_before = j.title()
    j.feed("local-ai")
    assert j.title() == "Local AI"
    j.feed("q")
    assert j.title() == title_before and j.overlay is None and not j.done


def test_the_screen_opens_over_an_open_overlay_and_gives_it_back(state):
    j = journey.Journey(".")
    j.feed("1")
    from hugmesh_studio.tui.themes import ThemesScreen
    themes = ThemesScreen()
    j.open_overlay(themes)
    j.feed("local-ai")
    assert isinstance(j.screen(), local_ai.LocalAIScreen)
    j.feed("q")
    assert j.screen() is themes, "closing the Local AI screen must leave Themes open underneath"


def test_a_question_goes_to_the_local_model_and_the_answer_is_shown(state):
    rc, text = run_plain("local-ai\nwhat is a worktree\nq\n")
    assert "you: what is a worktree" in text and "ai:  fake answer to: what is a worktree" in text


def test_a_failing_model_is_a_message_not_a_crash(state, monkeypatch):
    def boom(*a, **k):
        raise lai.LocalAIError("Ollama is not answering on 127.0.0.1:11434. Start it with scripts/local-ai.sh up")
    monkeypatch.setattr(lai, "send_prompt", boom)
    rc, text = run_plain("local-ai\nhello\nq\n")
    assert rc == 0 and "scripts/local-ai.sh up" in text


def test_an_answer_cut_mid_stream_is_shown_inline_and_the_screen_keeps_working(state, monkeypatch):
    """``send_prompt`` wraps what it knows; the screen must still survive what it does
    not. An IncompleteRead (http.client's word for a stream cut inside a chunk) is not a
    LocalAIError and not an OSError: raised from the prompt function it used to escape
    ``feed`` and take the whole text-mode input loop down with a traceback."""
    def cut(*a, **k):
        raise http.client.IncompleteRead(b"Hel")
    monkeypatch.setattr(lai, "send_prompt", cut)
    rc, text = run_plain("local-ai\nhello\nr\nsecond\nq\n")
    assert rc == 0, "the input loop died on the model's failure"
    assert "IncompleteRead" in text, "the failure must be shown in words on the screen"
    assert text.count("local-ai> ") >= 4, "the screen must stay up and keep taking input"


def test_a_real_cut_stream_through_the_screen_is_one_sentence_not_a_traceback(state, fake, monkeypatch):
    """End to end: the screen's own prompt function, the real ``send_prompt``, a fake
    Ollama that drops the connection mid-chunk."""
    fake.cut_in_chunk = True
    monkeypatch.setenv("OLLAMA_HOST", fake.host)
    monkeypatch.setattr(lai, "send_prompt", REAL_SEND_PROMPT)
    rc, text = run_plain("local-ai\nhello\nq\n")
    assert rc == 0
    assert "cut off" in text and "Traceback" not in text and "IncompleteRead" not in text


def test_start_clear_and_refresh_on_the_screen():
    started = []
    snaps = []

    def snap_fn():
        snaps.append(1)
        return fake_snapshot()
    scr = local_ai.LocalAIScreen(snapshot_fn=snap_fn, prompt_fn=lambda t, h: "a",
                                 start_fn=lambda: started.append(1) or lai.StartResult(True, "Starting.", "x"))
    j = journey.Journey(".")
    scr._under = None
    j.open_overlay(scr)
    j.feed("start")
    assert started == [1] and "Starting." in "\n".join(j.lines())
    j.feed("r")
    assert len(snaps) == 2
    j.feed("question")
    assert scr.history and "ai:  a" in "\n".join(j.lines())
    j.feed("clear")
    assert scr.history == [] and scr.transcript == []
    bad = local_ai.LocalAIScreen(snapshot_fn=fake_snapshot,
                                 start_fn=lambda: lai.StartResult(False, "It is missing.", "/x/local-ai.sh start"))
    j.open_overlay(bad)
    j.feed("start")
    assert "Run it yourself: /x/local-ai.sh start" in "\n".join(j.lines())


def test_local_ai_is_not_a_value_a_step_can_swallow(state):
    """The command is global like q: typed on a screen that wants free text it still opens the
    screen rather than being taken as an answer."""
    j = journey.Journey(".")
    j.feed("local-ai")
    assert j.title() == "Local AI"


# ── every screen: the command opens the screen, q returns, nothing is swallowed ──────
def every_journey_slug():
    """Every screen the journey can show: the welcome, the mode menu, each wizard step,
    the side flows, the two expert entry points and the stubs for steps not ported yet."""
    return sorted(journey.Journey(".")._screens)


@pytest.mark.parametrize("slug", every_journey_slug())
def test_local_ai_opens_over_every_journey_screen_and_q_returns_to_it_unchanged(state, slug, monkeypatch):
    sent = []
    monkeypatch.setattr(lai, "send_prompt", lambda text, *a, **k: sent.append(text) or "a")
    j = journey.Journey(".")
    j.goto(slug)
    before = (j.slug, j.overlay, j.title(), j.prompt(), j.lines())
    for _ in range(2):                                  # twice: the second round proves nothing stuck
        j.feed("local-ai")
        assert isinstance(j.screen(), local_ai.LocalAIScreen) and not j.done, slug
        assert j.prompt() == "local-ai> "
        opened = j.screen()
        j.feed("local-ai")                              # again, on the screen itself
        assert j.screen() is opened, f"a second Local AI screen was opened on {slug}"
        assert "This is the Local AI screen" in "\n".join(j.lines())
        j.feed("q")
        assert not j.done, f"q on the Local AI screen quit the journey from {slug}"
        assert (j.slug, j.overlay, j.title(), j.prompt(), j.lines()) == before, slug
    assert sent == [], f"the word local-ai was sent to the model from {slug}: {sent}"


def test_local_ai_over_a_screen_in_a_sub_state_returns_to_that_sub_state(state):
    """A screen mid-flow (the e2e screen showing one environment's plan) is not reset by a
    detour to the Local AI screen: q lands on the same sub-state with the same lines."""
    j = journey.Journey(".")
    j.goto("e2e")
    j.feed("1")                                        # the first environment's plan
    assert "(q = back to the environment list)" in "\n".join(j.lines())
    before = (j.prompt(), j.lines())
    j.feed("local-ai")
    assert j.title() == "Local AI"
    j.feed("q")
    assert (j.prompt(), j.lines()) == before
    j.feed("q")                                        # the screen's own q still means its own back
    assert j.slug == "e2e" and "(q = back to the environment list)" not in "\n".join(j.lines())


def test_the_screen_reopened_from_itself_rereads_and_sends_nothing(state):
    reads, sent = [], []
    scr = local_ai.LocalAIScreen(snapshot_fn=lambda: reads.append(1) or fake_snapshot(),
                                 prompt_fn=lambda t, h: sent.append(t) or "a")
    j = journey.Journey(".")
    j.open_overlay(scr)
    assert reads == [1]
    j.feed("local-ai")
    assert j.screen() is scr and reads == [1, 1] and sent == []
    assert "This is the Local AI screen" in "\n".join(j.lines())
    j.feed("a real question")                          # the next line is a prompt again
    assert sent == ["a real question"]


def test_plain_sessions_review_shows_the_line_and_opens_the_screen_over_the_list(state, tmp_path, monkeypatch):
    """The previous-builds list is a screen too: the status line is on it, local-ai opens
    the screen, q returns to the list (not to the welcome), and the list still works."""
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "studio"))
    rc, text = run_plain("2\nlocal-ai\nlocal-ai\nhello\nq\nr\nq\nq\n")
    assert rc == 0
    lists = text.count("previous builds (newest first):")
    assert lists == 3, text                           # on entry, after the screen closed, after r
    assert text.count("local-ai> ") == 3                # the screen is redrawn before each prompt
    assert text.count("Local AI\n") == 3 and text.count("Local AI: ready, qwen3:8b loaded") == 3
    assert "ai:  fake answer to: hello" in text
    assert "This is the Local AI screen" in text        # the second local-ai re-read, no second screen
    i_list, i_ai, i_back = (text.index("previous builds"), text.index("Local AI\n"),
                            text.index("previous builds", text.index("Local AI\n")))
    assert i_list < i_ai < i_back
    assert text.count("welcome> ") == 2                 # welcome, then welcome again after the review's q
    lines = text.splitlines()
    helps = [n for n, ln in enumerate(lines) if "local-ai=the Local AI screen" in ln]
    assert len(helps) == 3, "the list's help line names the command each time the list is shown"
    for n in helps:                                     # the status line sits right under the list
        assert lines[n + 1].startswith("[Local AI:") and lines[n + 1].endswith("type local-ai]"), lines[n:n + 2]


def test_plain_sessions_review_standalone_opens_the_screen_too(state, tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "studio"))
    out = io.StringIO()
    rc = plain.run_sessions_review(inp=io.StringIO("local-ai\nq\nq\n"), out=out, generator_dir=".")
    text = out.getvalue()
    assert rc == 0 and "Local AI\n" in text and text.count("previous builds") == 2


def test_eof_on_the_screen_over_the_review_quits_cleanly(state, tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "studio"))
    out = io.StringIO()
    rc = plain.run_sessions_review(inp=io.StringIO("local-ai\n"), out=out)
    assert rc == 0 and "Local AI\n" in out.getvalue()


def test_standalone_host_drives_the_screen_without_a_journey():
    sent = []
    host = local_ai.Standalone(".", snapshot_fn=fake_snapshot, prompt_fn=lambda t, h: sent.append(t) or "ok")
    assert not host.is_open and host.lines() == []
    scr = host.open()
    assert host.is_open and host.title() == "Local AI" and host.prompt() == "local-ai> "
    assert host.open() is scr                          # opening again re-reads, same screen
    host.feed("local-ai")
    assert host.overlay is scr and sent == []
    host.feed("why")
    assert sent == ["why"] and "ai:  ok" in "\n".join(host.lines())
    host.feed("q")
    assert not host.is_open
    host.feed("ignored")                               # closed: nothing to feed, no crash
    assert sent == ["why"]


# ── the urwid face ───────────────────────────────────────────────────────────────────
try:
    import urwid
except ImportError:                        # the rich face is a soft dependency
    urwid = None
needs_urwid = pytest.mark.skipif(urwid is None, reason="urwid is not installed: the rich terminal face "
                                                     "is not testable here")


def screen_text(widget, cols=100, rows=30):
    canvas = widget.render((cols, rows))
    return [line.decode("utf-8", "replace") for line in canvas.text]


@needs_urwid
def test_urwid_has_the_status_line_on_the_bottom_row_and_keeps_typing_working(state):
    from hugmesh_studio.tui import urwid_ui
    app = urwid_ui.JourneyApp(".")
    rows = screen_text(app.frame)
    assert "Local AI:" in rows[-1] and "[F2]" in rows[-1], rows[-3:]
    assert rows[-2].startswith("welcome>") or "welcome>" in rows[-2]
    app.frame.keypress((100, 30), "x")                # focus is still in the prompt
    assert app.input.edit_text == "x"


@needs_urwid
def test_f2_opens_the_screen_and_q_goes_back(state):
    from hugmesh_studio.tui import urwid_ui
    app = urwid_ui.JourneyApp(".")
    app.unhandled("f2")
    assert app.journey.title() == "Local AI"
    text = "\n".join(screen_text(app.frame))
    assert "Local AI: ready, qwen3:8b loaded" in text and "local-ai>" in text
    assert "Local AI:" in screen_text(app.frame)[-1]
    app.feed("q")
    assert app.journey.title() == "HugMesh Image Studio"


@needs_urwid
def test_the_line_is_redrawn_by_the_timer_and_after_each_screen(state, worker_proc):
    from hugmesh_studio.tui import urwid_ui
    app = urwid_ui.JourneyApp(".")
    before = app.ai_line.text
    write_status(state, worker_proc.pid)
    queue_job(state, "pending", "20260101-000001-draft-hugmesh-generator-5")

    class Loop:
        alarms = []

        def set_alarm_in(self, secs, cb, data=None):
            self.alarms.append((secs, cb))
    loop = Loop()
    urwid_ui._with_ai_line_timer(loop, app)
    assert loop.alarms and loop.alarms[0][0] == 5
    loop.alarms[0][1](loop)
    assert app.ai_line.text != before and "1 queued" in app.ai_line.text
    assert len(loop.alarms) == 2                      # it re-arms itself


@needs_urwid
def test_the_sessions_review_shows_the_line_too(state, tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "studio"))
    from hugmesh_studio.tui import urwid_ui
    review = urwid_ui.SessionsReview()
    assert "Local AI:" in screen_text(review.frame)[-1]


@needs_urwid
@pytest.mark.parametrize("slug", every_journey_slug())
def test_f2_on_every_journey_screen_opens_the_screen_once_and_q_returns_with_typing_intact(state, slug, monkeypatch):
    """F2 on each screen of the urwid face: the screen opens over it, F2 again on the
    Local AI screen re-reads (one screen, nothing sent), q returns to the very same
    screen, and the next keystroke still lands in the prompt."""
    sent = []
    monkeypatch.setattr(lai, "send_prompt", lambda text, *a, **k: sent.append(text) or "a")
    from hugmesh_studio.tui import urwid_ui
    app = urwid_ui.JourneyApp(".")
    app.journey.goto(slug)
    app.sync()
    before = (app.journey.slug, app.journey.overlay, app.header.text, app.input.caption,
              screen_text(app.frame)[:-2])
    app.frame.keypress((100, 30), "x")                 # a half-typed answer ...
    app.unhandled("f2")
    assert app.journey.title() == "Local AI", slug
    opened = app.journey.screen()
    assert app.input.edit_text == "", "... is not carried onto the Local AI prompt"
    assert "local-ai>" in screen_text(app.frame)[-2], slug
    app.unhandled("f2")                                # F2 on the Local AI screen itself
    assert app.journey.screen() is opened, f"F2 opened a second Local AI screen on {slug}"
    assert "This is the Local AI screen" in "\n".join(screen_text(app.frame))
    app.frame.keypress((100, 30), "q")
    app.unhandled("enter")
    assert not app.journey.done and app.journey.screen() is not opened, slug
    assert (app.journey.slug, app.journey.overlay, app.header.text, app.input.caption,
            screen_text(app.frame)[:-2]) == before, slug
    app.frame.keypress((100, 30), "y")
    assert app.input.edit_text == "y", "typing after the return must land in the prompt"
    assert sent == [], f"F2 sent a question to the model from {slug}: {sent}"


@needs_urwid
def test_f2_on_the_previous_builds_list_opens_the_screen_over_it_and_q_returns_to_the_list(state, tmp_path, monkeypatch):
    """The review's footer shows [F2]; the key opens the Local AI screen OVER the list and
    q comes back to the list — not to the journey's welcome — with the journey unchanged."""
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "studio"))
    sent = []
    monkeypatch.setattr(lai, "send_prompt", lambda text, *a, **k: sent.append(text) or "a")
    from hugmesh_studio.tui import urwid_ui
    app = urwid_ui.JourneyApp(".")
    app.feed("2")                                      # welcome -> previous builds
    assert app.sessions is not None and "[F2]" in app.sessions.review.ai_line.text
    review_frame = app.sessions.review.frame
    app.unhandled("f2")
    assert app.sessions is not None, "F2 must not leave the review"
    assert app.sessions.panel is not None and app.root.original_widget is app.sessions.root
    assert app.sessions.root.original_widget is app.sessions.panel.frame
    text = "\n".join(screen_text(app.root))
    assert "HugMesh Studio — Local AI" in text and "local-ai>" in text and "Local AI: ready" in text
    assert app.journey.title() == "HugMesh Image Studio" and app.journey.overlay is None
    app.unhandled("f2")                                # again: one panel, a re-read, nothing sent
    assert app.sessions.panel is not None and "This is the Local AI screen" in "\n".join(screen_text(app.root))
    app.sessions.panel.input.set_edit_text("hello")
    app.unhandled("enter")
    assert sent == ["hello"] and "ai:  a" in "\n".join(screen_text(app.root))
    app.sessions.panel.input.set_edit_text("q")
    app.unhandled("enter")
    assert app.sessions is not None and app.sessions.panel is None
    assert app.root.original_widget is app.sessions.root and app.sessions.root.original_widget is review_frame
    assert "previous builds" in "\n".join(screen_text(app.root))
    app.unhandled("q")                                 # the review's own q: back to the journey
    assert app.sessions is None and app.journey.title() == "HugMesh Image Studio"
    assert app.journey.overlay is None and not app.journey.done


@needs_urwid
def test_f2_in_every_review_mode_opens_the_screen_and_drops_a_pending_delete_question(state, tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "studio"))
    from hugmesh_studio.tui import urwid_ui
    win = urwid_ui.SessionsWindow(".")
    for mode in ("list", "detail", "worklist", "confirm"):
        win.review.mode = mode
        win.review._confirm_row = object()
        win.unhandled("f2")
        assert win.panel is not None and win.review._confirm_row is None, mode
        win.panel.input.set_edit_text("q")
        win.unhandled("enter")
        assert win.panel is None and win.root.original_widget is win.review.frame, mode
        assert win.review.mode == mode                  # the review's own state is untouched


@needs_urwid
def test_the_standalone_review_offers_f2_and_it_works(state, tmp_path, monkeypatch):
    """`tui --sessions` on its own: the same key, the same screen, back to the same list."""
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "studio"))
    from hugmesh_studio.tui import urwid_ui
    win = urwid_ui.SessionsWindow(".")
    rows = screen_text(win.root)
    assert "Local AI:" in rows[-1] and "[F2]" in rows[-1]
    win.unhandled("f2")
    assert win.panel is not None and "Local AI: ready, qwen3:8b loaded" in "\n".join(screen_text(win.root))
    assert "Local AI:" in screen_text(win.root)[-1]    # the status line stays on the bottom row
    first = win.panel
    win.open_local_ai()                                # the review's own door, asked again: same panel
    assert win.panel is first and win.root.original_widget is first.frame
    win.unhandled("esc")                               # not a panel key: ignored, no crash, no close
    assert win.panel is not None
    win.panel.input.set_edit_text("q")
    win.unhandled("enter")
    assert win.panel is None and "previous builds" in "\n".join(screen_text(win.root))
    with pytest.raises(urwid.ExitMainLoop):            # the list's q still quits the standalone window
        win.unhandled("q")


@needs_urwid
def test_the_timer_redraws_the_line_on_the_panel_too(state, worker_proc, tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "studio"))
    from hugmesh_studio.tui import urwid_ui
    app = urwid_ui.JourneyApp(".")
    app.feed("2")
    app.unhandled("f2")
    write_status(state, worker_proc.pid)
    queue_job(state, "pending", "20260101-000001-draft-hugmesh-generator-5")
    app.refresh_ai_line()
    assert "1 queued" in app.sessions.panel.ai_line.text


def test_the_status_line_hint_can_be_left_off(state):
    assert "[F2]" in local_ai.status_line()
    assert "[F2]" not in local_ai.status_line(key_hint=False)

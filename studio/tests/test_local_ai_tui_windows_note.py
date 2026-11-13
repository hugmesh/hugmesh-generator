"""The Local AI text screen's reply stays in view under the Windows note (Windows contract).

Found 2026-11-13 on Windows 11: the seven-line "the queue worker needs WSL2" note sat
ABOVE the screen's reply, so in a 100x30 terminal no reply was on screen at all:
F2's "state re-read", a model's answer, ``pull``'s download consent. The note is
forced here on any host (``windows_worker_note("nt")``), so Linux CI proves it too.
"""
from __future__ import annotations

import time

import pytest

from hugmesh_studio.core import local_ai_status as lai
from hugmesh_studio.tui import journey, local_ai

try:
    import urwid  # noqa: F401
except ImportError:                       # the rich face is optional
    urwid = None

WIN_NOTE = lai.windows_worker_note("nt")
REAL_READ_SNAPSHOT = lai.read_snapshot


def _snapshot():
    s = lai.Snapshot(taken=time.time(), state_dir="/tmp/x", host="127.0.0.1:11434",
                     ollama_up=False, ollama_installed=False, models=[], loaded=[],
                     worker="stopped", worker_pid=0, heartbeat_age=None,
                     counts={"pending": 0, "running": 0, "stalled": 0, "done": 0,
                             "drafts": 0, "builds": 0})
    s.summary = lai.summary_line(s)
    return s


@pytest.fixture(autouse=True)
def _windows_note_and_no_ollama(tmp_path, monkeypatch):
    assert WIN_NOTE.count("\n") >= 0 and "WSL2" in WIN_NOTE
    monkeypatch.setenv("HUGMESH_LOCAL_AI_DIR", str(tmp_path / "localai"))
    monkeypatch.setattr(lai, "windows_worker_note", lambda *a, **k: WIN_NOTE)
    monkeypatch.setattr(lai, "read_snapshot",
                        lambda *a, **k: REAL_READ_SNAPSHOT(*a, **k) if k.get("probe")
                        else _snapshot())
    monkeypatch.setattr(lai, "send_prompt", lambda *a, **k: pytest.fail("no model call"))


def test_the_reply_comes_before_the_windows_note():
    j = journey.Journey(".")
    j.goto("build")
    j.feed("local-ai")
    j.feed("local-ai")
    text = "\n".join(j.lines())
    reply = text.index("This is the Local AI screen")
    note = text.index(WIN_NOTE.splitlines()[0])
    assert reply < note
    assert "Run it yourself:" not in text       # the bash lines stay replaced


@pytest.mark.skipif(urwid is None, reason="urwid is not installed")
@pytest.mark.parametrize("slug", ["welcome", "build", "branding", "local_mesh"])
def test_f2_twice_shows_its_reply_in_a_100x30_terminal(slug):
    from hugmesh_studio.tui import urwid_ui
    app = urwid_ui.JourneyApp(".")
    if slug in app.journey._screens:
        app.journey.goto(slug)
    app.sync()
    app.unhandled("f2")
    assert isinstance(app.journey.screen(), local_ai.LocalAIScreen)
    app.unhandled("f2")
    rows = [r.decode("utf-8", "replace") for r in app.frame.render((100, 30)).text]
    assert any("This is the Local AI screen" in r for r in rows), "\n".join(rows)

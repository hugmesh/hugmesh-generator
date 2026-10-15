"""core/local_ai_status.py — the snapshot reader, the loopback-only prompt, the heartbeat rule.

Qt-free. Every request goes to a throw-away HTTP server bound to 127.0.0.1 inside this
process, never to the Ollama that may be running on the host the tests run on: each
test points ``OLLAMA_HOST`` at the fake through the ``env`` it passes in.

What each group pins, and what breaks it:
  * the loopback rule — a non-loopback ``OLLAMA_HOST`` is refused BEFORE any socket
    opens, ``localhost`` is mapped to 127.0.0.1, system proxy variables and redirects
    are ignored (a request must not be able to leave the machine);
  * the heartbeat rule — a job in ``queue/running`` counts as running only while the
    worker's heartbeat is fresh and its pid is a live ``local-ai`` process;
  * the plain-words problems — each failure names its fix and the doc.
"""
import io
import json
import os
import subprocess
import sys
import http.client
import time

import pytest

from _local_ai_fake import FakeOllama
from hugmesh_studio.core import local_ai_status as lai


@pytest.fixture
def fake():
    f = FakeOllama()
    yield f
    f.close()


@pytest.fixture
def env(tmp_path, fake):
    """An environment that points everything at the fake and a throw-away state dir."""
    return {"HUGMESH_LOCAL_AI_DIR": str(tmp_path / "state"), "OLLAMA_HOST": fake.host,
            "PATH": os.environ.get("PATH", "")}


def no_builds():
    return []


@pytest.fixture
def worker_proc():
    """A live process whose command line contains ``local-ai`` (what the heartbeat rule
    looks for), standing in for scripts/local-ai/worker.sh."""
    p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)", "local-ai-worker"])
    yield p
    p.kill()
    p.wait()


def put_status(env, pid, age=1.0, now=None):
    root = lai.state_dir(env)
    os.makedirs(root, exist_ok=True)
    now = time.time() if now is None else now
    with open(os.path.join(root, "status.json"), "w") as fh:
        json.dump({"pid": pid, "heartbeat": now - age}, fh)
    return now


def put_job(env, state, name, line="draft hugmesh-generator 12"):
    d = os.path.join(lai.state_dir(env), "queue", state)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, name + ".job"), "w") as fh:
        fh.write(line + "\n")


def put_draft(env, name, status, diff="", issue="# A title\n\nbody"):
    d = os.path.join(lai.state_dir(env), "drafts", name)
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "STATUS"), "w").write(status + "\n")
    open(os.path.join(d, "draft.diff"), "w").write(diff)
    open(os.path.join(d, "issue.md"), "w").write(issue)
    return d


# ── the state directory ─────────────────────────────────────────────────────────────
def test_state_dir_rules(tmp_path):
    assert lai.state_dir({"HUGMESH_LOCAL_AI_DIR": "/x/y"}) == "/x/y"
    assert lai.state_dir({"XDG_STATE_HOME": "/s"}) == "/s/hugmesh/local-ai"
    assert lai.state_dir({"XDG_STATE_HOME": "", "HUGMESH_LOCAL_AI_DIR": ""}).endswith(
        os.path.join(".local", "state", "hugmesh", "local-ai"))


# ── the loopback rule ───────────────────────────────────────────────────────────────
@pytest.mark.parametrize("raw,want", [
    ("", ("127.0.0.1", 11434)), ("127.0.0.1", ("127.0.0.1", 11434)),
    ("127.0.0.1:8080", ("127.0.0.1", 8080)), ("localhost:9", ("127.0.0.1", 9)),
    ("http://localhost:11434", ("127.0.0.1", 11434)), ("[::1]:5", ("::1", 5)),
    ("::1", ("::1", 11434)), ("127.5.5.5:1", ("127.5.5.5", 1)), (":11434", ("127.0.0.1", 11434)),
    ("http://127.0.0.1:11434/", ("127.0.0.1", 11434)),
])
def test_loopback_spellings_are_accepted(raw, want):
    assert lai.ollama_host({"OLLAMA_HOST": raw}) == want


@pytest.mark.parametrize("raw", [
    "0.0.0.0", "0.0.0.0:11434", "192.168.1.5:11434", "10.0.0.1", "example.com",
    "localhost.evil.test", "https://127.0.0.1:11434", "ftp://127.0.0.1", "8.8.8.8:53",
    "127.0.0.1:99999", "127.0.0.1:abc", "[2001:db8::1]:11434",
])
def test_everything_else_is_refused(raw):
    with pytest.raises(lai.NotLoopback):
        lai.ollama_host({"OLLAMA_HOST": raw})


def test_refused_host_opens_no_socket(monkeypatch):
    """Not 'no data came back': no connection was ATTEMPTED."""
    import urllib.request

    def boom(*a, **k):
        raise AssertionError("a connection was attempted for a non-loopback host")
    monkeypatch.setattr(urllib.request.OpenerDirector, "open", boom)
    with pytest.raises(lai.NotLoopback):
        lai.send_prompt("hi", "qwen3:8b", env={"OLLAMA_HOST": "10.1.2.3:11434"})
    snap = lai.read_snapshot({"OLLAMA_HOST": "10.1.2.3:11434", "HUGMESH_LOCAL_AI_DIR": "/nonexistent"},
                             builds=no_builds)
    assert "loopback" in snap.problem and not snap.ollama_up and snap.host == ""


def test_system_proxy_settings_are_ignored(fake, env, monkeypatch):
    for k in ("HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"):
        monkeypatch.setenv(k, "http://127.0.0.1:9")          # a dead proxy
    assert lai.send_prompt("hi", "qwen3:8b", env=env) == "Hello there"
    assert any(r[1] == "/api/chat" for r in fake.requests)


def test_a_redirect_is_not_followed(fake, env):
    fake.redirect = True
    with pytest.raises(lai.LocalAIError):
        lai.send_prompt("hi", "qwen3:8b", env=env)
    # the only request the server saw is the one we made: the Location it gave was not followed
    assert [(r[0], r[1]) for r in fake.requests] == [("POST", "/api/chat")]


# ── the snapshot ────────────────────────────────────────────────────────────────────
def test_empty_state_dir_is_ready_and_idle(fake, env):
    snap = lai.read_snapshot(env, builds=no_builds)
    assert snap.ok and snap.ollama_up and snap.worker == "stopped"
    assert snap.summary == "Local AI: ready, qwen3:8b loaded, idle"
    assert snap.counts["pending"] == 0 and snap.jobs == []
    assert snap.host == fake.host
    json.dumps(snap.to_dict())                                # the --json shape serialises


def test_no_model_loaded_and_none_pulled(fake, env):
    fake.loaded = []
    assert lai.read_snapshot(env, builds=no_builds).summary == "Local AI: ready, no model loaded, idle"
    fake.models = []
    snap = lai.read_snapshot(env, builds=no_builds)
    assert not snap.ok and "no model is pulled" in snap.problem and "ollama pull" in snap.fix


def test_a_running_job_with_a_live_fresh_worker(fake, env, worker_proc):
    now = put_status(env, worker_proc.pid, age=2.0)
    put_job(env, "running", "20260101-000000-draft-hugmesh-generator-12")
    put_job(env, "pending", "20260101-000001-draft-hugmesh-generator-13", "draft hugmesh-generator 13")
    put_job(env, "pending", "20260101-000002-draft-hugmesh-generator-14", "draft hugmesh-generator 14")
    snap = lai.read_snapshot(env, now=now, builds=no_builds)
    assert snap.worker == "running"
    assert snap.counts["running"] == 1 and snap.counts["pending"] == 2 and snap.counts["stalled"] == 0
    assert snap.summary == "Local AI: ready, qwen3:8b loaded, 2 queued, 1 running"
    states = {j.title: j.state for j in snap.of_kind("queue")}
    assert states["draft hugmesh-generator#12"] == "running"


def test_a_stale_heartbeat_never_reads_as_running(fake, env, worker_proc):
    """Alive but silent for longer than STALE_AFTER: the job is stalled, and the summary
    says so instead of claiming work is happening."""
    now = put_status(env, worker_proc.pid, age=lai.STALE_AFTER + 5)
    put_job(env, "running", "20260101-000000-draft-hugmesh-generator-12")
    snap = lai.read_snapshot(env, now=now, builds=no_builds)
    assert snap.worker == "stalled"
    assert snap.counts["running"] == 0 and snap.counts["stalled"] == 1
    assert "running" not in snap.summary.replace("not beating", "") and "stalled" in snap.summary
    assert snap.of_kind("queue")[0].state == "stalled"


def test_a_fresh_heartbeat_from_a_dead_pid_is_not_running(fake, env):
    dead = subprocess.Popen([sys.executable, "-c", "pass"])
    dead.wait()
    now = put_status(env, dead.pid, age=0.5)
    put_job(env, "running", "20260101-000000-draft-hugmesh-generator-12")
    snap = lai.read_snapshot(env, now=now, builds=no_builds)
    assert snap.worker == "stopped" and snap.counts["running"] == 0 and snap.counts["stalled"] == 1


def test_a_reused_pid_is_not_our_worker(fake, env):
    """The pid is alive but belongs to something else (no 'local-ai' on its command
    line): pids get reused, so a pidfile alone must not make a dead worker look alive."""
    other = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
    try:
        now = put_status(env, other.pid, age=0.5)
        snap = lai.read_snapshot(env, now=now, builds=no_builds)
        assert snap.worker == "stopped"
    finally:
        other.kill()
        other.wait()


def test_pending_work_with_no_worker_says_so(fake, env):
    put_job(env, "pending", "20260101-000001-draft-hugmesh-generator-13", "draft hugmesh-generator 13")
    s = lai.read_snapshot(env, builds=no_builds).summary
    assert s == "Local AI: ready, qwen3:8b loaded, 1 queued, worker stopped"


def test_finished_drafts_are_listed_newest_first_with_their_status(fake, env):
    put_draft(env, "hugmesh-generator-1", "applied files=1 diff_lines=9", diff="--- a\n+++ b\n")
    time.sleep(0.02)
    put_draft(env, "hugmesh-generator-2", "does-not-apply error: patch failed: x:1")
    put_draft(env, "hugmesh-generator-3", "running")
    os.utime(os.path.join(lai.state_dir(env), "drafts", "hugmesh-generator-1", "STATUS"), (1, 1))
    snap = lai.read_snapshot(env, builds=no_builds)
    drafts = snap.of_kind("draft")
    assert [d.id for d in drafts][-1] == "hugmesh-generator-1"
    by = {d.id: d for d in drafts}
    assert by["hugmesh-generator-1"].state == "applied" and by["hugmesh-generator-1"].diff_path.endswith("draft.diff")
    assert by["hugmesh-generator-2"].state == "does-not-apply" and by["hugmesh-generator-2"].diff_path == ""
    assert "patch failed" in by["hugmesh-generator-2"].detail
    assert by["hugmesh-generator-1"].title.endswith("A title")
    assert snap.counts["drafts"] == 3


def test_a_draft_just_queued_with_no_diff_yet_is_still_the_newest(fake, env):
    """``todo`` writes STATUS before any draft.diff exists. The missing diff must not cost
    the draft its place: the list says newest first, and this one is the newest."""
    put_draft(env, "hugmesh-generator-1", "applied files=1 diff_lines=9", diff="--- a\n+++ b\n")
    d = os.path.join(lai.state_dir(env), "drafts", "hugmesh-generator-2")
    os.makedirs(d)
    open(os.path.join(d, "STATUS"), "w").write("queued\n")
    os.utime(os.path.join(lai.state_dir(env), "drafts", "hugmesh-generator-1", "STATUS"), (1, 1))
    drafts = lai.read_snapshot(env, builds=no_builds).of_kind("draft")
    assert [d.id for d in drafts] == ["hugmesh-generator-2", "hugmesh-generator-1"]
    assert drafts[0].state == "queued" and drafts[0].diff_path == ""


@pytest.fixture
def draft_proc():
    """A live process whose command line contains ``draft.sh``: what a draft in progress is."""
    p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)", "local-ai/draft.sh"])
    yield p
    p.kill()
    p.wait()


def test_a_draft_marked_running_with_no_live_process_is_stalled(fake, env, draft_proc):
    """STATUS 'running' is only a claim. With no draft.sh behind it (it was stopped or killed,
    the machine restarted) the list must not show it as work in progress."""
    d = put_draft(env, "hugmesh-generator-3", "running")
    snap = lai.read_snapshot(env, builds=no_builds)
    assert snap.of_kind("draft")[0].state == "stalled"
    dead = subprocess.Popen([sys.executable, "-c", "pass"])
    dead.wait()
    open(os.path.join(d, "draft.pid"), "w").write(str(dead.pid))
    assert lai.read_snapshot(env, builds=no_builds).of_kind("draft")[0].state == "stalled"
    open(os.path.join(d, "draft.pid"), "w").write(str(os.getpid()))     # alive, but not draft.sh
    assert lai.read_snapshot(env, builds=no_builds).of_kind("draft")[0].state == "stalled"
    open(os.path.join(d, "draft.pid"), "w").write(str(draft_proc.pid))
    assert lai.read_snapshot(env, builds=no_builds).of_kind("draft")[0].state == "running"


def test_a_finished_draft_keeps_its_own_word_whatever_draft_pid_says(fake, env):
    d = put_draft(env, "hugmesh-generator-4", "applied files=1")
    open(os.path.join(d, "draft.pid"), "w").write("1")
    assert lai.read_snapshot(env, builds=no_builds).of_kind("draft")[0].state == "applied"


def test_a_corrupt_status_file_is_treated_as_no_worker(fake, env):
    root = lai.state_dir(env)
    os.makedirs(root)
    open(os.path.join(root, "status.json"), "w").write("{not json")
    snap = lai.read_snapshot(env, builds=no_builds)
    assert snap.worker == "stopped" and snap.heartbeat_age is None and snap.ok


def test_studio_builds_are_listed_and_counted(fake, env):
    from hugmesh_studio.core.local_ai_status import Job
    snap = lai.read_snapshot(env, builds=lambda: [Job("build", "s1", "x86 server", "running")])
    assert snap.counts["builds"] == 1
    assert snap.summary.endswith("1 running")
    assert snap.of_kind("build")[0].title == "x86 server"


def test_active_studio_build_sessions_come_from_the_session_records(fake, env, tmp_path):
    from hugmesh_studio.core import build_sessions as bs
    s = bs.BuildSession(id="20260101-000000-abcd", label="mesh node", status=bs.RUNNING,
                        pid=os.getpid(), hostname=__import__("socket").gethostname(),
                        workdir=str(tmp_path / "w"))
    bs.save(s)
    done = bs.BuildSession(id="20260101-000001-efgh", label="old", status="complete")
    bs.save(done)
    snap = lai.read_snapshot(env)
    assert [j.id for j in snap.of_kind("build")] == [s.id]


def test_ollama_down_names_the_fix_and_the_doc(env, monkeypatch, tmp_path):
    env = dict(env, OLLAMA_HOST="127.0.0.1:1")                 # nothing listens on port 1
    monkeypatch.setattr(lai.shutil, "which", lambda name: "/usr/bin/ollama")
    snap = lai.read_snapshot(env, builds=no_builds, timeout=0.5)
    assert not snap.ok and not snap.ollama_up
    assert "not answering" in snap.problem and "scripts/local-ai.sh up" in snap.fix
    assert snap.doc.endswith("LOCAL-AI-ASSISTANT.md")
    assert snap.summary.startswith("Local AI: Ollama is installed but is not answering")


def test_ollama_not_installed_says_install_it(env, monkeypatch):
    env = dict(env, OLLAMA_HOST="127.0.0.1:1")
    monkeypatch.setattr(lai.shutil, "which", lambda name: None)
    snap = lai.read_snapshot(env, builds=no_builds, timeout=0.5)
    assert snap.problem == "Ollama is not installed on this machine."
    assert "Install" in snap.fix and snap.summary == "Local AI: Ollama is not installed on this machine"


def test_format_status_carries_the_problem_fix_and_link(env, monkeypatch):
    env = dict(env, OLLAMA_HOST="127.0.0.1:1")
    monkeypatch.setattr(lai.shutil, "which", lambda name: None)
    text = lai.format_status(lai.read_snapshot(env, builds=no_builds, timeout=0.5))
    assert "Problem: Ollama is not installed" in text and "Fix:" in text and "docs/LOCAL-AI-ASSISTANT.md" in text


# ── the heartbeat writer ────────────────────────────────────────────────────────────
def test_write_status_round_trips_through_the_reader(fake, env, worker_proc):
    path = lai.write_status(worker_proc.pid, "draft x#1", env)
    data = json.load(open(path))
    assert data["pid"] == worker_proc.pid and data["running"] == "draft x#1" and data["ollama_up"] is True
    assert data["model_loaded"] == ["qwen3:8b"]
    assert not [n for n in os.listdir(os.path.dirname(path)) if n.endswith(".tmp")]
    assert lai.read_snapshot(env, builds=no_builds).worker == "running"


# ── send_prompt ─────────────────────────────────────────────────────────────────────
def test_send_prompt_streams_and_returns_the_whole_answer(fake, env):
    got = []
    answer = lai.send_prompt("hello", "qwen3:8b", env=env, on_chunk=got.append,
                             history=[{"role": "user", "content": "earlier"}], system="be brief")
    assert answer == "Hello there" and got == ["Hel", "lo ", "there"]
    body = [r[2] for r in fake.requests if r[1] == "/api/chat"][0]
    assert body["stream"] is True and body["think"] is False and body["model"] == "qwen3:8b"
    assert [m["role"] for m in body["messages"]] == ["system", "user", "user"]
    assert body["messages"][-1]["content"] == "hello"
    assert body["options"]["num_ctx"] == lai.DEFAULT_CTX


def test_send_prompt_picks_a_model_when_none_is_named(fake, env):
    fake.models = [{"name": "other-embed"}, {"name": "qwen3:8b"}]
    lai.send_prompt("hi", None, env=env)
    assert [r[2]["model"] for r in fake.requests if r[1] == "/api/chat"] == ["qwen3:8b"]
    fake.models = [{"name": "nomic-embed-text"}, {"name": "tiny:1b"}]
    lai.send_prompt("hi", None, env=env)
    assert [r[2]["model"] for r in fake.requests if r[1] == "/api/chat"][-1] == "tiny:1b"
    assert lai.pick_model({"LOCAL_AI_MODEL": "mine:7b"}, ["qwen3:8b"]) == "mine:7b"


def test_send_prompt_explains_a_missing_model(fake, env):
    fake.chat_status = 404
    with pytest.raises(lai.LocalAIError, match="ollama pull qwen3:8b"):
        lai.send_prompt("hi", "qwen3:8b", env=env)


def test_send_prompt_reports_a_model_error_line(fake, env):
    fake.error_line = "out of memory"
    with pytest.raises(lai.LocalAIError, match="out of memory"):
        lai.send_prompt("hi", "qwen3:8b", env=env)


def test_send_prompt_when_ollama_is_down_says_how_to_start_it():
    with pytest.raises(lai.LocalAIError, match=r"scripts/local-ai\.sh up"):
        lai.send_prompt("hi", "qwen3:8b", env={"OLLAMA_HOST": "127.0.0.1:1"}, timeout=1)


def test_send_prompt_times_out_with_a_plain_sentence(fake, env):
    fake.stall = 1.5
    t0 = time.time()
    with pytest.raises(lai.LocalAIError, match="No answer for"):
        lai.send_prompt("hi", "qwen3:8b", env=env, timeout=0.3)
    assert time.time() - t0 < 1.4


def test_send_prompt_can_be_stopped_between_chunks(fake, env):
    got = []
    answer = lai.send_prompt("hi", "qwen3:8b", env=env, on_chunk=got.append,
                             should_stop=lambda: len(got) >= 1)
    assert answer == "Hel"


def test_a_stream_cut_inside_a_chunk_is_a_local_ai_error_not_a_bare_http_exception(fake, env):
    """The server dies mid-answer. http.client raises IncompleteRead there, which is an
    HTTPException and NOT an OSError, so the old ``except (URLError, OSError)`` let it
    escape to the caller as a raw traceback — out of the text screen's input loop, out of
    ``--local-ai-prompt``. It must come out as the one error type every caller catches,
    saying what happened and keeping the words that did arrive."""
    fake.cut_in_chunk = True
    got = []
    with pytest.raises(lai.LocalAIError, match="cut off") as info:
        lai.send_prompt("hi", "qwen3:8b", env=env, on_chunk=got.append)
    assert got == ["Hel", "lo "], "the pieces before the cut must still have been delivered"
    assert not isinstance(info.value, http.client.HTTPException)
    assert "Try again" in str(info.value)
    assert len([r for r in fake.requests if r[1] == "/api/chat"]) == 1, \
        "a cut stream is reported, never silently retried"


def test_a_stream_that_ends_without_done_is_not_passed_off_as_a_whole_answer(fake, env):
    """A cut BETWEEN chunks reaches http.client as a clean end of file (its readline
    peeks and swallows the IncompleteRead), so no exception is raised at all. Ollama
    always closes an answer with a ``done`` line; a stream that ends without one was cut."""
    fake.cut_between_chunks = True
    got = []
    with pytest.raises(lai.LocalAIError, match="cut off"):
        lai.send_prompt("hi", "qwen3:8b", env=env, on_chunk=got.append)
    assert got == ["Hel", "lo ", "there"]


def test_a_stream_line_that_is_json_but_not_an_object_is_skipped(fake, env):
    """Ollama sends one JSON object per line. A line that parses but is not an object
    (``[]``, ``3``, ``null``) used to escape as a bare AttributeError from ``.get``."""
    fake.odd_lines = ["[]", "3", "null", '"text"']
    assert lai.send_prompt("hi", "qwen3:8b", env=env) == "Hello there"


# ── a server that is up but not well ────────────────────────────────────────────────
# A loopback server that dies mid-reply on /api/tags (IncompleteRead) or that answers
# bytes that are not HTTP (BadStatusLine) raises http.client.HTTPException, which is NOT
# an OSError. Every /api/tags lookup must treat that like a server that is down: the
# reader promises never to raise, the worker's heartbeat must still be written (a live
# worker that stops beating is shown as stalled), and every face says the sentence
# with the fix instead of a traceback.
def half_dead(fake, how):
    setattr(fake, how, True)


@pytest.mark.parametrize("how", ["cut_tags", "garbage_tags"])
def test_a_server_that_dies_mid_reply_reads_as_not_answering_and_never_raises(fake, env, monkeypatch, how):
    half_dead(fake, how)
    monkeypatch.setattr(lai.shutil, "which", lambda name: "/usr/bin/ollama")
    snap = lai.read_snapshot(env, builds=no_builds, timeout=2)
    assert snap.ollama_up is False and not snap.ok
    assert "not answering" in snap.problem and "scripts/local-ai.sh up" in snap.fix
    assert snap.summary.startswith("Local AI: Ollama is installed but is not answering")


@pytest.mark.parametrize("how", ["cut_tags", "garbage_tags"])
def test_the_heartbeat_is_still_written_when_ollama_dies_mid_reply(fake, env, worker_proc, how):
    half_dead(fake, how)
    path = lai.write_status(worker_proc.pid, "draft x#1", env)
    assert os.path.isfile(path), "the worker's heartbeat was not written"
    data = json.load(open(path))
    assert data["pid"] == worker_proc.pid and data["ollama_up"] is False and data["running"] == "draft x#1"
    # and the reader, told the truth about the server, still sees the worker as alive
    assert lai.read_snapshot(env, builds=no_builds).worker == "running"


@pytest.mark.parametrize("how", ["cut_tags", "garbage_tags"])
def test_every_command_reports_a_half_dead_server_in_words(fake, env, monkeypatch, capsys, how):
    half_dead(fake, how)
    monkeypatch.setattr(lai.shutil, "which", lambda name: "/usr/bin/ollama")
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    assert lai.main(["status", "--brief"]) == 1
    assert capsys.readouterr().out.startswith("Local AI: Ollama is installed but is not answering")
    assert lai.main(["status"]) == 1
    assert "Problem: Ollama is installed but is not answering" in capsys.readouterr().out
    assert lai.main(["ping"]) == 1
    out = io.StringIO()
    assert lai.chat_loop(io.StringIO(""), out, env=env) == 1
    assert "local-ai.sh up" in out.getvalue()
    # a prompt with no model named asks /api/tags first: that lookup must fail in words too
    with pytest.raises(lai.LocalAIError, match=r"scripts/local-ai\.sh up"):
        lai.send_prompt("hi", None, env=env)


# ── starting the assistant ──────────────────────────────────────────────────────────
def test_start_assistant_runs_the_script_detached(tmp_path, env):
    gen = tmp_path / "gen"
    (gen / "scripts").mkdir(parents=True)
    (gen / "scripts" / "local-ai.sh").write_text("#!/bin/sh\n")
    calls = []

    def spawn(cmd, **kw):
        calls.append((cmd, kw))
    res = lai.start_assistant(str(gen), env=env, spawn=spawn)
    assert res.ok and res.command.endswith("local-ai.sh start")
    cmd, kw = calls[0]
    assert cmd == ["bash", str(gen / "scripts" / "local-ai.sh"), "start"]
    assert kw["start_new_session"] is True and kw["stdin"] == subprocess.DEVNULL
    assert kw["env"]["HUGMESH_LOCAL_AI_DIR"] == env["HUGMESH_LOCAL_AI_DIR"]


def test_start_assistant_says_what_is_wrong_instead_of_raising(tmp_path, env):
    res = lai.start_assistant(str(tmp_path / "nothing"), env=env)
    assert not res.ok and "missing" in res.message and "start" in res.command
    gen = tmp_path / "gen"
    (gen / "scripts").mkdir(parents=True)
    (gen / "scripts" / "local-ai.sh").write_text("")

    def spawn(cmd, **kw):
        raise OSError("no bash")
    res = lai.start_assistant(str(gen), env=env, spawn=spawn)
    assert not res.ok and "no bash" in res.message and res.command in res.message


# ── the prompt loop and the command line ────────────────────────────────────────────
def test_chat_loop_keeps_history_until_cleared(fake, env):
    out = io.StringIO()
    rc = lai.chat_loop(io.StringIO("first\n/clear\nsecond\n/quit\n"), out, env=env, model="qwen3:8b")
    assert rc == 0 and "Hello there" in out.getvalue() and "(forgotten)" in out.getvalue()
    bodies = [r[2] for r in fake.requests if r[1] == "/api/chat"]
    assert len(bodies) == 2 and len(bodies[1]["messages"]) == 1       # /clear dropped the first exchange


def test_chat_loop_when_down_returns_one_with_the_fix():
    out = io.StringIO()
    assert lai.chat_loop(io.StringIO(""), out, env={"OLLAMA_HOST": "127.0.0.1:1"}) == 1
    assert "local-ai.sh up" in out.getvalue()


def test_main_status_exit_codes_and_json(fake, env, monkeypatch, capsys):
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    assert lai.main(["status", "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["ok"] is True
    assert lai.main(["status", "--brief"]) == 0
    assert capsys.readouterr().out.startswith("Local AI: ready")
    monkeypatch.setenv("OLLAMA_HOST", "127.0.0.1:1")
    assert lai.main(["status"]) == 1
    assert "Problem:" in capsys.readouterr().out
    assert lai.main(["ping"]) == 1


def test_main_prompt_prints_the_answer_or_a_sentence_on_stderr(fake, env, monkeypatch, capsys):
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    assert lai.main(["prompt", "say", "hi"]) == 0
    assert capsys.readouterr().out.strip() == "Hello there"
    assert [r[2]["messages"][-1]["content"] for r in fake.requests if r[1] == "/api/chat"] == ["say hi"]
    monkeypatch.setenv("OLLAMA_HOST", "127.0.0.1:1")
    assert lai.main(["prompt", "x"]) == 1
    assert "local-ai.sh up" in capsys.readouterr().err
    monkeypatch.setenv("OLLAMA_HOST", "10.9.9.9")
    assert lai.main(["host"]) == 2
    assert "loopback" in capsys.readouterr().err


def test_the_module_runs_as_a_command_without_qt(fake, env):
    """scripts/local-ai.sh runs it this way; it must import with no Qt and no display."""
    r = subprocess.run([sys.executable, "-m", "hugmesh_studio.core.local_ai_status", "status", "--brief"],
                       env={**env, "PYTHONPATH": os.path.dirname(os.path.dirname(os.path.abspath(__file__)))},
                       capture_output=True, text=True, timeout=30)
    assert r.returncode == 0 and r.stdout.startswith("Local AI: ready"), r.stderr
    assert "PySide6" not in r.stderr and "PyQt6" not in r.stderr


def put_result(env, name, rc, line="draft hugmesh-generator 12"):
    d = os.path.join(lai.state_dir(env), "queue", "done")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, name + ".result"), "w") as fh:
        fh.write(f"rc={rc} secs=3\n{line}\n")


def test_finished_jobs_are_counted_and_the_failed_ones_are_counted_apart(fake, env, worker_proc):
    now = put_status(env, worker_proc.pid, age=1.0)
    put_result(env, "20260101-000000-draft-a-1", 0)
    put_result(env, "20260101-000001-draft-a-2", 0)
    put_result(env, "20260101-000002-draft-a-3", 1)
    put_result(env, "20260101-000003-draft-a-4", 64)
    snap = lai.read_snapshot(env, now=now, builds=no_builds)
    assert snap.counts["done"] == 4 and snap.counts["failed"] == 2
    assert "done 4" in lai.format_status(snap)


def test_the_status_line_without_a_server_check_still_counts_what_is_waiting(fake, env):
    """No worker is running, so the line does not ask the server; it must still tell the
    person how many jobs are waiting, and say why nothing is moving."""
    put_job(env, "pending", "20260101-000001-draft-hugmesh-generator-13", "draft hugmesh-generator 13")
    put_job(env, "pending", "20260101-000002-draft-hugmesh-generator-14", "draft hugmesh-generator 14")
    line = lai.quick_line(env)
    assert line == "Local AI: no worker running, 2 queued"


def test_a_stopped_worker_with_waiting_jobs_says_so_in_the_summary(fake, env):
    put_job(env, "pending", "20260101-000001-draft-hugmesh-generator-13", "draft hugmesh-generator 13")
    snap = lai.read_snapshot(env, builds=no_builds)
    assert snap.counts["pending"] == 1
    assert "1 queued" in snap.summary and "worker stopped" in snap.summary


# ── the pid probe on Windows ─────────────────────────────────────────────────────────
def test_on_windows_the_pid_probe_never_sends_a_signal(monkeypatch):
    """``os.kill(pid, 0)`` TERMINATES a process on Windows (any signal number but the two
    console events does). A status line that only wanted to know whether a stale pid was
    alive must never reach os.kill there; the question goes to the process API."""
    asked = []
    monkeypatch.setattr(lai.os, "kill", lambda *a: (_ for _ in ()).throw(
        AssertionError(f"os.kill{a} was called on the Windows path")))
    monkeypatch.setattr(lai, "_pid_alive_windows", lambda pid: asked.append(pid) or True)
    assert lai._pid_alive(4242, "local-ai", os_name="nt") is True
    assert asked == [4242]
    monkeypatch.setattr(lai, "_pid_alive_windows", lambda pid: asked.append(pid) or False)
    assert lai._pid_alive(4242, os_name="nt") is False
    assert lai._pid_alive(0, os_name="nt") is False and asked == [4242, 4242]


def test_on_posix_the_pid_probe_still_uses_the_zero_signal(monkeypatch):
    sent = []
    monkeypatch.setattr(lai.os, "kill", lambda pid, sig: sent.append((pid, sig)))
    monkeypatch.setattr(lai, "_pid_alive_windows", lambda pid: (_ for _ in ()).throw(
        AssertionError("the Windows probe ran on posix")))
    assert lai._pid_alive(os.getpid(), os_name="posix") is True
    assert sent == [(os.getpid(), 0)]


def test_the_windows_probe_fails_closed_where_there_is_no_windows_api():
    # on this (non-Windows) host ctypes has no windll: a dead answer, never an exception
    assert lai._pid_alive_windows(os.getpid()) is False


def test_the_real_os_name_is_used_when_none_is_injected(monkeypatch):
    seen = []
    monkeypatch.setattr(lai.os, "name", "nt")
    monkeypatch.setattr(lai, "_pid_alive_windows", lambda pid: seen.append(pid) or True)
    monkeypatch.setattr(lai.os, "kill", lambda *a: (_ for _ in ()).throw(AssertionError("os.kill on nt")))
    assert lai._pid_alive(7) is True and seen == [7]


# ── the suite's own isolation (tests/conftest.py: _inert_local_ai) ────────────────────
def test_by_default_a_probe_sees_no_server_and_an_empty_state_dir(tmp_path):
    """Under pytest the host's Ollama and the operator's queue are out of reach: a reader
    that takes the process environment sees "down" and an empty folder, whatever the host
    has running."""
    snap = lai.read_snapshot(builds=no_builds)
    assert not snap.ollama_up and snap.host == "127.0.0.1:1"
    assert snap.state_dir.startswith(str(tmp_path)) and snap.counts["pending"] == 0
    assert lai.quick_line() == "Local AI: no worker running"


def test_a_request_to_the_hosts_own_ollama_is_refused_and_reported(monkeypatch, _inert_local_ai):
    """The guard behind every other test here: a call that would reach 127.0.0.1:11434
    is stopped before a socket opens, raised as a failure naming the fixture, and put on
    record for the fixture's teardown check (which fails the test even when the code under
    test swallowed the raise)."""
    monkeypatch.setenv("OLLAMA_HOST", "127.0.0.1:11434")
    import urllib.request
    monkeypatch.setattr(urllib.request.OpenerDirector, "open",
                        lambda *a, **k: (_ for _ in ()).throw(AssertionError("a socket was opened")))
    with pytest.raises(AssertionError, match="reached the host's own Ollama.*_inert_local_ai"):
        lai._get_json(None, "/api/tags", 1)
    assert _inert_local_ai == ["http://127.0.0.1:11434/api/tags"]
    # the snapshot reader, which swallows a server that is down, does NOT swallow this:
    # the refusal comes through it, and the record grows either way
    with pytest.raises(AssertionError, match="reached the host's own Ollama"):
        lai.read_snapshot(builds=no_builds)
    assert len(_inert_local_ai) == 2
    _inert_local_ai.clear()        # this test exists to prove the record; do not fail on it


def test_a_fake_server_on_another_loopback_port_is_not_refused(fake, env):
    assert lai.read_snapshot(env, builds=no_builds).ollama_up

"""core/local_ai_models.py and core/flatpak_host.py: a model out of the box.

Qt-free. The operator's report (2026-11-09): "when starting the ai assistant it's not
loaded with a model on docker so it can't work on windows or linux on flatpack install
out of the box". These tests pin the answer:

  * NO MODEL -> AN OFFER. A server with nothing pulled is reported with an offer (model,
    size, which instance), a question is answered with :class:`NoModel` before a chat
    request that could only come back 404, and every by-hand line names the RIGHT
    instance (never ``ollama pull`` for the Studio's Docker Ollama).
  * THE PULL. Streamed from ``/api/pull`` on the loopback fake: progress, success saved
    as the choice, an ``{"error"}`` line under HTTP 200, cancel, a cut stream, refusals.
  * FREE SPACE. ``docker exec ... df`` in Docker mode, the models folder in system mode,
    and a refusal when the download would not fit.
  * THE COMMAND LINE and THE TEXT SCREEN ask first and show progress.
  * THE FLATPAK. The host's state folder is read, "not installed" is asked of the host,
    and an installed Studio with no checkout still starts Docker mode (what crosses to
    the host, and how: tests/test_local_ai_flatpak_bridge.py).

Every request goes to the fake on 127.0.0.1, never to an Ollama on the test host.
"""
import io
import os
import re
import subprocess
import types

import pytest

from _local_ai_fake import FakeOllama
from hugmesh_studio.core import assistant_settings
from hugmesh_studio.core import flatpak_host
from hugmesh_studio.core import local_ai_models as lam
from hugmesh_studio.core import local_ai_status as lai
from hugmesh_studio.core import ollama_docker as odk

GENERATOR_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DOC = os.path.join(GENERATOR_DIR, "docs", "LOCAL-AI-ASSISTANT.md")


@pytest.fixture
def fake():
    f = FakeOllama()
    f.models = []
    f.loaded = []
    yield f
    f.close()


@pytest.fixture
def env(tmp_path, fake):
    return {"HUGMESH_LOCAL_AI_DIR": str(tmp_path / "state"), "OLLAMA_HOST": fake.host,
            "PATH": os.environ.get("PATH", ""), "HOME": str(tmp_path)}


@pytest.fixture
def docker_env(tmp_path, fake):
    """The fake standing in for the Studio's Docker Ollama: its port IS the Docker port."""
    e = {"HUGMESH_LOCAL_AI_DIR": str(tmp_path / "state"),
         "HUGMESH_OLLAMA_DOCKER_PORT": str(fake.port), "PATH": os.environ.get("PATH", "")}
    return odk.assistant_env(odk.DOCKER, e)


@pytest.fixture
def not_flatpak(monkeypatch):
    monkeypatch.setattr(flatpak_host, "in_flatpak", lambda *a, **k: False)


def chat_requests(fake):
    return [r for r in fake.requests if r[1] == "/api/chat"]


# ── the table ────────────────────────────────────────────────────────────────────────
def test_every_offered_model_and_its_size_is_in_the_docs():
    text = open(DOC, encoding="utf-8").read()
    for choice in lam.CHOICES:
        assert f"`{choice.name}`" in text, choice.name
        assert lam.size_words(choice.bytes) in text, (choice.name, lam.size_words(choice.bytes))
    assert lam.RECOMMENDED.name == "qwen3:1.7b"
    assert lam.CLI_PULL.split()[-1] == "pull" and "scripts/local-ai.sh pull" in text


def test_sizes_read_the_way_ollama_lists_them():
    assert lam.size_words(1_359_293_444) == "1.4 GB"
    assert lam.size_words(522_640_096) == "523 MB"
    assert lam.size_words(None) == "size unknown"


# ── no model -> an offer ─────────────────────────────────────────────────────────────
def test_a_server_with_no_model_is_reported_with_an_offer_not_a_command_to_paste(env, not_flatpak):
    snap = lai.read_snapshot(env, builds=lambda: [], osname="posix")
    assert snap.ollama_up and snap.models == []
    assert snap.problem == "Ollama is running but no model is pulled."
    assert snap.offer == {"model": "qwen3:1.7b", "bytes": lam.RECOMMENDED.bytes, "docker": False}
    assert "scripts/local-ai.sh pull" in snap.fix and "ollama pull qwen3:1.7b" in snap.fix
    assert snap.to_dict()["offer"]["model"] == "qwen3:1.7b"
    assert "no model pulled" in snap.summary


def test_a_question_with_nothing_pulled_is_an_offer_and_no_chat_request(env, fake):
    with pytest.raises(lam.NoModel) as caught:
        lai.send_prompt("what is a mesh?", env=env)
    exc = caught.value
    assert isinstance(exc, lai.LocalAIError)              # every face's except still holds
    assert exc.offer["model"] == "qwen3:1.7b" and exc.offer["docker"] is False
    assert "No model is pulled into the Ollama on " + fake.host in str(exc)
    assert str(exc).endswith("By hand: ollama pull qwen3:1.7b.")
    assert chat_requests(fake) == []


def test_only_an_embedding_model_is_still_nothing_to_answer_with(env, fake):
    fake.models = [{"name": "nomic-embed-text:latest"}]
    with pytest.raises(lam.NoModel):
        lai.send_prompt("hi", env=env)
    assert chat_requests(fake) == []


def test_in_docker_mode_every_line_names_the_container_never_the_system_ollama(docker_env, fake):
    assert lam.is_docker(docker_env)
    with pytest.raises(lam.NoModel) as caught:
        lai.send_prompt("hi", env=docker_env)
    text = str(caught.value)
    assert "the Studio's Docker Ollama (hugmesh-studio-ollama)" in text
    assert "By hand: docker exec hugmesh-studio-ollama ollama pull qwen3:1.7b" in text
    assert caught.value.offer["docker"] is True
    snap = odk.adjust_snapshot(lai.read_snapshot(docker_env, builds=lambda: []), odk.DOCKER)
    assert "docker exec hugmesh-studio-ollama ollama pull qwen3:1.7b" in snap.fix
    assert not re.search(r"(^|[;:] )ollama pull", snap.fix), snap.fix
    for face in ("gui", "tui", "cli"):
        assert "docker exec" in lam.fix_words(snap.offer, face, docker_env)


def test_a_named_model_that_is_gone_is_reported_for_its_instance(docker_env, fake, monkeypatch):
    """The 404 branch: the person named a model (LOCAL_AI_MODEL) the container lacks."""
    fake.models = [{"name": "qwen3:1.7b"}]
    fake.chat_status = 404
    with pytest.raises(lam.NoModel) as caught:
        lai.send_prompt("hi", "qwen3:8b", env=docker_env)
    assert caught.value.gone and caught.value.offer["model"] == "qwen3:8b"
    assert "not pulled into the Studio's Docker Ollama" in str(caught.value)
    assert "docker exec hugmesh-studio-ollama ollama pull qwen3:8b" in str(caught.value)
    assert "Run: ollama pull" not in str(caught.value)


def test_each_face_says_its_own_action():
    offer = lam.offer_for({"OLLAMA_HOST": "127.0.0.1:11434"})
    assert lam.action_words(offer, "gui") == "Press Download below to fetch qwen3:1.7b (1.4 GB)."
    assert lam.action_words(offer, "tui") == "Type pull to download qwen3:1.7b (1.4 GB)."
    assert lam.action_words(offer, "cli") == \
        "Download qwen3:1.7b (1.4 GB) with: scripts/local-ai.sh pull."


# ── which model ──────────────────────────────────────────────────────────────────────
def test_pick_model_prefers_the_saved_choice_then_the_default_then_the_small_one():
    pulled = ["nomic-embed-text:latest", "llama3:8b", "qwen3:1.7b", "qwen3:8b"]
    assert lai.pick_model({}, pulled, saved="llama3:8b") == "llama3:8b"
    assert lai.pick_model({}, pulled, saved="gone:1b") == "qwen3:8b"        # not pulled: skipped
    assert lai.pick_model({}, ["qwen3:1.7b", "llama3:8b"], saved="") == "qwen3:1.7b"
    assert lai.pick_model({}, ["nomic-embed-text:latest", "llama3:8b"], saved="") == "llama3:8b"
    assert lai.pick_model({"LOCAL_AI_MODEL": "x:1"}, pulled, saved="llama3:8b") == "x:1"
    assert lai.pick_model({}, [], saved="") == lai.DEFAULT_MODEL


def test_the_saved_choice_is_read_from_the_dock_settings():
    assert "model" in assistant_settings.KEYS
    assert lam.save_choice("llama3:8b") and lam.saved_choice() == "llama3:8b"
    assert lai.pick_model({}, ["qwen3:8b", "llama3:8b"]) == "llama3:8b"


def test_the_agent_card_follows_the_saved_choice_when_it_can_use_tools():
    from hugmesh_studio.core import local_agent as la
    pr = la.Probe(ollama_path="/usr/bin/ollama", server_up=True, agents={"claude": "/c"},
                  models=(la.ModelInfo("qwen3:8b", tools=True), la.ModelInfo("qwen3:1.7b", tools=True),
                          la.ModelInfo("plain:1", tools=False)))
    assert la.choose_defaults(pr)[1] == "qwen3:8b"
    lam.save_choice("qwen3:1.7b")
    assert la.choose_defaults(pr)[1] == "qwen3:1.7b"
    lam.save_choice("plain:1")                              # no tools: not for an agent
    assert la.choose_defaults(pr)[1] == "qwen3:8b"


# ── the pull ─────────────────────────────────────────────────────────────────────────
def test_a_pull_streams_progress_saves_the_choice_and_the_model_is_then_used(env, fake):
    seen = []
    res = lam.pull("qwen3:1.7b", env, on_progress=seen.append)
    assert res.ok and not res.cancelled and "ready" in res.message
    method, path, body = [r for r in fake.requests if r[1] == "/api/pull"][0]
    assert method == "POST" and body["model"] == "qwen3:1.7b" and body["stream"] is True
    fractions = [p.fraction for p in seen if p.fraction is not None]
    assert fractions == sorted(fractions)                   # never runs back
    # the table's size is the denominator while it is larger than what the layers say
    assert seen[-1].total == lam.RECOMMENDED.bytes
    assert seen[0].words() == "pulling manifest"
    assert re.fullmatch(r"pulling \d+% \(0/1359 MB\)", seen[2].words())
    assert lam.saved_choice() == "qwen3:1.7b"
    # the next question goes to it, with no offer in the way
    fake.models = [{"name": "qwen3:1.7b"}]
    assert lai.send_prompt("hi", env=env) == "Hello there"
    assert chat_requests(fake)[-1][2]["model"] == "qwen3:1.7b"


def test_an_error_line_under_http_200_is_a_failure_in_words(env, fake):
    fake.pull_lines = [{"status": "pulling manifest"},
                       {"error": "pull model manifest: file does not exist"}]
    res = lam.pull("qwen3:17b", env)
    assert not res.ok and not res.cancelled
    assert "no model called qwen3:17b" in res.message and "file does not exist" in res.message
    assert lam.saved_choice() == ""


@pytest.mark.parametrize("code,words", [(500, "HTTP 500"), (412, "too old")])
def test_a_refused_pull_says_why(env, fake, code, words):
    fake.pull_status = code
    res = lam.pull("qwen3:1.7b", env)
    assert not res.ok and words in res.message


def test_a_stream_that_ends_without_success_is_not_called_done(env, fake):
    fake.pull_lines = fake.pull_lines[:3]
    res = lam.pull("qwen3:1.7b", env)
    assert not res.ok and "ended before Ollama said it was complete" in res.message
    assert lam.saved_choice() == ""


def test_cancel_closes_the_connection_and_the_server_stops_sending(env, fake):
    fake.pull_lines = [{"status": "pulling x", "digest": "d", "total": 100, "completed": i}
                       for i in range(200)] + [{"status": "success"}]
    fake.pull_delay = 0.01
    calls = []
    res = lam.pull("qwen3:1.7b", env, on_progress=calls.append,
                   should_stop=lambda: len(calls) >= 3)
    assert res.cancelled and not res.ok and "resumes" in res.message
    import time
    time.sleep(0.5)
    assert fake.pull_served < 200                             # the stream was cut, not drained
    assert {"name": "qwen3:1.7b"} not in fake.models


def test_a_server_that_is_down_and_a_host_off_this_machine(env, fake):
    fake.close()
    res = lam.pull("qwen3:1.7b", env)
    assert not res.ok and "not answering" in res.message
    res = lam.pull("qwen3:1.7b", {"OLLAMA_HOST": "10.0.0.5:11434"})
    assert not res.ok and "not a loopback address" in res.message


def test_the_status_line_shows_a_running_pull_and_then_how_it_ended(env, fake):
    fake.pull_delay = 0.05
    lines = []
    lam.pull("qwen3:1.7b", env, on_progress=lambda p: lines.append(lam.active_line()))
    assert any(ln.startswith("downloading qwen3:1.7b: ") for ln in lines)
    assert lam.active_line() == "qwen3:1.7b is downloaded and ready."
    assert lam.active_line(now=10 ** 9) == ""                 # long after: nothing


# ── free space ───────────────────────────────────────────────────────────────────────
def test_free_space_in_docker_mode_is_read_inside_the_models_volume(docker_env):
    calls = []

    def runner(argv, timeout):
        calls.append(list(argv))
        return 0, "   Avail\n123456789\n"
    assert lam.free_bytes(docker_env, runner=runner, container="throwaway") == 123456789
    assert calls == [["docker", "exec", "throwaway", "df", "-B1", "--output=avail", "/root/.ollama"]]
    assert lam.free_bytes(docker_env, runner=lambda a, t: (1, "no such container")) is None


def test_free_space_in_system_mode_is_the_models_folder(env, tmp_path):
    models = tmp_path / "models"
    models.mkdir()
    seen = []

    def usage(path):
        seen.append(path)
        return types.SimpleNamespace(free=42)
    assert lam.free_bytes(dict(env, OLLAMA_MODELS=str(models)), disk_usage=usage) == 42
    assert seen == [str(models)]


def test_a_download_that_would_not_fit_is_refused_in_words():
    assert lam.space_problem(lam.RECOMMENDED.bytes, 2_400_000_000) == ""
    said = lam.space_problem(lam.RECOMMENDED.bytes, 1_500_000_000)
    assert "Not enough free space" in said and "1.4 GB" in said and "1.5 GB" in said
    assert lam.space_problem(None, 1) == "" and lam.space_problem(1, None) == ""
    assert lam.consent_line("qwen3:1.7b", None) == "Download qwen3:1.7b (1.4 GB; free space unknown)?"


# ── the command line ─────────────────────────────────────────────────────────────────
def test_cli_pull_asks_first_and_a_no_downloads_nothing(env, fake):
    out, err = io.StringIO(), io.StringIO()
    rc = lam.main([], out=out, err=err, inp=io.StringIO("n\n"), env=env, free=lambda e: 50 * 10 ** 9)
    assert rc == 1 and "Nothing downloaded." in out.getvalue()
    assert "Download qwen3:1.7b (1.4 GB; 50.0 GB free)?" in out.getvalue()
    assert not [r for r in fake.requests if r[1] == "/api/pull"]


def test_cli_pull_yes_downloads_with_progress(env, fake):
    out, err = io.StringIO(), io.StringIO()
    rc = lam.main(["--yes"], out=out, err=err, env=env, free=lambda e: None)
    assert rc == 0, err.getvalue()
    assert "free space unknown" in out.getvalue() and "qwen3:1.7b is downloaded and ready." in out.getvalue()
    assert [r for r in fake.requests if r[1] == "/api/pull"]


def test_cli_pull_refuses_when_it_will_not_fit_and_when_the_server_is_down(env, fake):
    err = io.StringIO()
    assert lam.main(["qwen3:8b", "--yes"], out=io.StringIO(), err=err, env=env,
                    free=lambda e: 10 ** 9) == 1
    assert "Not enough free space" in err.getvalue()
    assert not [r for r in fake.requests if r[1] == "/api/pull"]
    fake.close()
    err = io.StringIO()
    assert lam.main(["--yes"], out=io.StringIO(), err=err, env=env) == 1
    assert "not answering" in err.getvalue()


def test_the_status_command_routes_pull(monkeypatch):
    seen = []
    monkeypatch.setattr(lam, "main", lambda args, **k: seen.append(args) or 0)
    assert lai.main(["pull", "qwen3:0.6b", "--yes"]) == 0
    assert seen == [["qwen3:0.6b", "--yes"]]
    script = open(os.path.join(GENERATOR_DIR, "scripts", "local-ai.sh"), encoding="utf-8").read()
    assert 'pull)          shift; la_py pull "$@" ;;' in script


def test_run_as_a_module_a_no_model_prompt_is_a_sentence_not_a_traceback(env, fake):
    """``python -m ...local_ai_status`` (what scripts/local-ai.sh runs) loads the file
    as ``__main__``; NoModel subclasses the package copy's LocalAIError. Found live on
    2026-11-09: the first run printed a traceback."""
    import sys
    studio = os.path.dirname(os.path.dirname(os.path.abspath(lai.__file__)))
    run_env = dict(os.environ, **env, PYTHONPATH=os.path.dirname(studio))
    p = subprocess.run([sys.executable, "-m", "hugmesh_studio.core.local_ai_status", "prompt", "hi"],
                       capture_output=True, text=True, env=run_env, timeout=60)
    assert p.returncode == 1, p.stderr
    assert "Traceback" not in p.stderr
    assert "No model is pulled" in p.stderr and "scripts/local-ai.sh pull" in p.stderr


def test_cli_prompt_and_chat_with_no_model_say_what_to_run(env, fake, monkeypatch):
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    out, err = io.StringIO(), io.StringIO()
    assert lai.main(["prompt", "hi"], out=out, err=err) == 1
    assert "No model is pulled" in err.getvalue() and "scripts/local-ai.sh pull" in err.getvalue()
    out = io.StringIO()
    assert lai.chat_loop(io.StringIO("hi\n"), out, env=env) == 1
    assert "scripts/local-ai.sh pull" in out.getvalue() and "docs QUESTION" in out.getvalue()
    assert chat_requests(fake) == []


# ── the text screen ──────────────────────────────────────────────────────────────────
class _Host:
    overlay = None
    slug = ""

    def screen_for(self, slug):
        return None


def test_the_text_screen_offers_asks_downloads_and_says_ask_again(env, fake, monkeypatch, not_flatpak):
    from hugmesh_studio.tui import local_ai as tui
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    screen = tui.LocalAIScreen(generator_dir=GENERATOR_DIR, free_fn=lambda e: 80 * 10 ** 9)
    host = _Host()
    screen.enter(host)
    text = "\n".join(screen.lines(host))
    assert "Type pull to download qwen3:1.7b (1.4 GB); by hand: ollama pull qwen3:1.7b." in text
    assert "pull [model]" in text                              # in the help
    screen.feed(host, "what is a brand?")
    assert "No model is pulled" in screen.message and "Type pull to download" in screen.message
    assert chat_requests(fake) == []
    screen.feed(host, "pull")
    assert screen.message.startswith("Download qwen3:1.7b (1.4 GB; 80.0 GB free)?")
    screen.feed(host, "n")
    assert screen.message == "Nothing downloaded." and not screen.pulling
    assert not [r for r in fake.requests if r[1] == "/api/pull"]
    screen.feed(host, "pull")
    screen.feed(host, "y")
    assert screen.wait_pull(10)
    assert "qwen3:1.7b is downloaded and ready. Ask again: what is a brand?" == screen.message
    assert "qwen3:1.7b is downloaded and ready." in tui.status_line()
    assert screen.snapshot.models == ["qwen3:1.7b"] and not screen.snapshot.offer


def test_the_text_screen_cancels_a_download_and_refuses_one_that_will_not_fit(env, fake, monkeypatch):
    from hugmesh_studio.tui import local_ai as tui
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    fake.pull_lines = [{"status": "pulling x", "digest": "d", "total": 100, "completed": i}
                       for i in range(400)] + [{"status": "success"}]
    fake.pull_delay = 0.01
    screen = tui.LocalAIScreen(generator_dir=GENERATOR_DIR, free_fn=lambda e: None)
    host = _Host()
    screen.enter(host)
    screen.feed(host, "pull qwen3:0.6b")
    assert "free space unknown" in screen.message
    screen.feed(host, "yes")
    assert screen.pulling
    screen.feed(host, "pull")                               # a second one is not started
    assert "Type cancel to stop it." in screen.message
    screen.feed(host, "cancel")
    assert screen.wait_pull(10)
    assert "Stopped downloading qwen3:0.6b" in screen.message
    small = tui.LocalAIScreen(generator_dir=GENERATOR_DIR, free_fn=lambda e: 10 ** 9)
    small.enter(host)
    small.feed(host, "pull qwen3:8b")
    assert "Not enough free space" in small.message and not small._pull_ask


# ── the Flatpak ──────────────────────────────────────────────────────────────────────


@pytest.mark.skipif(os.name == "nt", reason=(
    "Flatpak (Linux-only): the host's state folder is a POSIX path, os.path is ntpath on "
    "Windows"))
def test_a_flatpak_studio_reads_the_hosts_state_folder(monkeypatch):
    monkeypatch.setattr(flatpak_host, "in_flatpak", lambda *a, **k: True)
    sandbox = {"HOME": "/home/me", "XDG_STATE_HOME": "/home/me/.var/app/org.hugmesh.ImageStudio/.local/state"}
    env = odk.assistant_env(odk.SYSTEM, sandbox)
    assert env["HUGMESH_LOCAL_AI_DIR"] == "/home/me/.local/state/hugmesh/local-ai"
    assert lai.state_dir(env) == "/home/me/.local/state/hugmesh/local-ai"
    kept = odk.assistant_env(odk.SYSTEM, dict(sandbox, HUGMESH_LOCAL_AI_DIR="/mine"))
    assert kept["HUGMESH_LOCAL_AI_DIR"] == "/mine"
    monkeypatch.setattr(flatpak_host, "in_flatpak", lambda *a, **k: False)
    assert "HUGMESH_LOCAL_AI_DIR" not in odk.assistant_env(odk.SYSTEM, sandbox)


@pytest.mark.parametrize("host_has,words", [
    ("/usr/local/bin/ollama", "installed but is not answering"),
    ("", "not installed"),
])
def test_in_the_flatpak_not_installed_is_asked_of_the_host(monkeypatch, host_has, words):
    monkeypatch.setattr(flatpak_host, "in_flatpak", lambda *a, **k: True)
    monkeypatch.setattr(flatpak_host, "host_which", lambda cmd, **k: host_has or None)
    snap = lai.Snapshot(host="127.0.0.1:11434", ollama_up=False, ollama_installed=False,
                        problem="Ollama is not installed on this machine.",
                        fix="Install it (see the link), then run: scripts/local-ai.sh up")
    odk.adjust_snapshot(snap, odk.SYSTEM)
    assert words in snap.problem
    assert "scripts/local-ai.sh" not in snap.fix and "Docker" in snap.fix
    assert snap.ollama_installed is bool(host_has)


def test_outside_the_flatpak_system_mode_advice_is_left_alone(not_flatpak):
    snap = lai.Snapshot(ollama_up=False, problem="p", fix="f")
    assert odk.adjust_snapshot(snap, odk.SYSTEM).fix == "f"


def test_docker_mode_with_no_checkout_is_a_working_start(tmp_path):
    """An installed Studio (the Flatpak, a wheel) has no scripts/: the container answering
    is the assistant working, not a failed start."""
    res = odk.start_assistant(
        str(tmp_path / "no-checkout"), odk.DOCKER,
        starter=lambda runner, environ: odk.StartOutcome(True, "ok", ["docker", "start"]),
        ready=lambda env, timeout: True, osname="posix")
    assert res.ok and res.command == ""
    assert "the panel asks it directly" in res.message and "no-checkout" in res.message


def test_the_docs_say_what_crosses_to_the_host_and_how():
    """The Flatpak paragraph names the allowlist and the descriptor (the manifest's own
    comment about flatpak-spawn belongs to the Flatpak bridge PR, hugmesh-generator#936)."""
    text = open(DOC, encoding="utf-8").read()
    assert "HOST_ASSISTANT_ENV" in text and "--env-fd" in text

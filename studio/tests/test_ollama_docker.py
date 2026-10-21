"""The local assistant's Ollama in Docker: the container, and WHICH ENDPOINT IS CALLED.

core/ollama_docker.py, and every face that uses it. The inert-toggle rule
(memory: project_hugmesh_ai_cloak_lane) is the point of the second half: a choice on a
screen that changes nothing is worse than no choice, so these tests do not read the
setting back — they start two fake Ollama servers on loopback, one standing in for the
system instance and one for the container, and assert on the WIRE which one each call
reached in each mode:

  * the panel's prompt (``LocalAIDock.send``) and its status read;
  * the local-agent card's probe, and the ``OLLAMA_HOST`` in the launched agent's own
    ``env -i`` line (its ``Plan``);
  * the text UI's prompt;
  * the start request (the worker inherits ``OLLAMA_HOST`` from it).

The container half uses a scripted ``docker`` runner, so nothing here runs docker.
"""
import os
import time

import pytest
from _local_ai_fake import FakeOllama

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from hugmesh_studio.core import assistant_settings                        # noqa: E402
from hugmesh_studio.core import local_agent as la                         # noqa: E402
from hugmesh_studio.core import local_ai_status as lai                    # noqa: E402
from hugmesh_studio.core import ollama_docker as odk                      # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


class Docker:
    """A scripted ``docker``: answers by the first words of the argv, records each call."""

    def __init__(self, *, up=True, exists=False, running=False, runtimes='{"runc":{}}',
                 run_rc=0, run_out="abc123"):
        self.up, self.exists, self.running = up, exists, running
        self.runtimes, self.run_rc, self.run_out = runtimes, run_rc, run_out
        self.calls = []
        self.port = None                         # the host port the container publishes

    def __call__(self, argv, timeout):
        argv = list(argv)
        self.calls.append(argv)
        if not self.up:
            return 1, "Cannot connect to the Docker daemon at unix:///var/run/docker.sock"
        verb = argv[1]
        if verb == "version":
            return 0, "27.3.1\n"
        if verb == "info":
            return 0, self.runtimes + "\n"
        if verb == "inspect":
            if not self.exists:
                return 1, "Error: No such object: hugmesh-studio-ollama"
            if "PortBindings" in argv[3]:
                return 0, f"{self.port or ''} \n"
            return 0, f"{'true' if self.running else 'false'} {odk.IMAGE}\n"
        if verb == "run":
            if self.run_rc == 0:
                self.exists = self.running = True
                self.port = int(argv[argv.index("-p") + 1].split(":")[1])
            return self.run_rc, self.run_out
        if verb == "rm":
            self.exists = self.running = False
            self.port = None
            return 0, odk.CONTAINER
        if verb == "start":
            self.running = True
            return 0, odk.CONTAINER
        if verb == "stop":
            self.running = False
            return 0, odk.CONTAINER
        return 99, "unexpected " + " ".join(argv)


def nothing_listens(_h, _p):
    return False


# ── the container ────────────────────────────────────────────────────────────────────
def test_the_image_is_pinned_by_version_and_digest():
    for image in (odk.IMAGE, odk.IMAGE_ROCM):
        name, _, digest = image.partition("@")
        assert name.startswith("ollama/ollama:" + odk.IMAGE_VERSION), image
        assert digest.startswith("sha256:") and len(digest) == len("sha256:") + 64, image
    assert ":latest" not in odk.IMAGE


def test_the_run_binds_loopback_only_a_named_volume_and_never_11434():
    argv = odk.run_argv(odk.GpuChoice("cpu", (), odk.IMAGE, ""), 11435)
    assert argv[:3] == ["docker", "run", "-d"]
    assert "-p" in argv and argv[argv.index("-p") + 1] == "127.0.0.1:11435:11434"
    assert not [a for a in argv if a.startswith("0.0.0.0") or a == "11434:11434"]
    assert argv[argv.index("-v") + 1] == f"{odk.VOLUME}:/root/.ollama"
    assert argv[argv.index("--name") + 1] == odk.CONTAINER
    assert argv[-1] == odk.IMAGE
    assert "--gpus" not in argv
    with pytest.raises(ValueError):
        odk.run_argv(odk.GpuChoice("cpu", (), odk.IMAGE, ""), 11434)


def test_the_port_setting_can_move_but_never_onto_the_system_port():
    assert odk.docker_port({}) == 11435
    assert odk.docker_port({odk.PORT_ENV: "12000"}) == 12000
    for bad in ("11434", "80", "abc", "70000", ""):
        assert odk.docker_port({odk.PORT_ENV: bad}) == 11435, bad


@pytest.mark.parametrize("runtimes,cdi,amd,kind,flag", [
    ('{"nvidia":{},"runc":{}}', [], False, "nvidia", "--gpus"),
    ('{"runc":{}}', ["/etc/cdi/nvidia.yaml"], False, "nvidia", "--gpus"),
    ('{"runc":{}}', [], True, "amd", "/dev/kfd"),
    ('{"runc":{}}', [], False, "cpu", None),
])
def test_the_gpu_is_passed_through_only_when_docker_can_provide_it(runtimes, cdi, amd,
                                                                     kind, flag):
    docker = Docker(runtimes=runtimes)
    gpu = odk.detect_gpu(docker, exists=lambda p: amd and p in ("/dev/kfd", "/dev/dri"),
                         globber=lambda pat: [p for p in cdi if p.startswith(pat.split("*")[0])])
    assert gpu.kind == kind
    argv = odk.run_argv(gpu)
    if flag:
        assert flag in argv
    else:
        assert "--gpus" not in argv and "--device" not in argv
        assert "CPU only" in gpu.words
    assert (argv[-1] == odk.IMAGE_ROCM) == (kind == "amd")


def test_a_docker_daemon_that_does_not_answer_means_cpu_and_says_why():
    gpu = odk.detect_gpu(Docker(up=False), exists=lambda p: False, globber=lambda p: [])
    assert gpu.kind == "cpu" and "not answering" in gpu.words


def test_start_creates_a_missing_container_then_starts_a_stopped_one_and_leaves_a_running_one():
    docker = Docker()
    gpu = odk.GpuChoice("nvidia", ("--gpus", "all"), odk.IMAGE, "")
    res = odk.start(docker, gpu=gpu, environ={}, connect=nothing_listens)
    assert res.ok and res.argv[:2] == ["docker", "run"] and "--gpus" in res.argv
    docker.running = False                                   # stopped since
    res = odk.start(docker, gpu=gpu, environ={}, connect=nothing_listens)
    assert res.ok and res.argv == ["docker", "start", odk.CONTAINER]
    before = len(docker.calls)
    res = odk.start(docker, gpu=gpu, environ={}, connect=nothing_listens)
    assert res.ok and "already running" in res.message
    assert not [c for c in docker.calls[before:] if c[1] in ("run", "start")]


def test_a_changed_port_setting_makes_the_container_again_on_the_new_port():
    """A container keeps the port it was made with: after the port setting changed, a
    plain `docker start` would bring it back on the OLD port while everything here talks
    to the new one. Start makes it again (the models live in the volume)."""
    docker = Docker()
    gpu = odk.GpuChoice("cpu", (), odk.IMAGE, "")
    assert odk.start(docker, gpu=gpu, environ={}, connect=nothing_listens).ok
    assert docker.port == odk.DEFAULT_PORT and odk.bound_port(docker) == odk.DEFAULT_PORT
    for running in (False, True):                # stopped since, or still running
        docker.running = running
        moved = {odk.PORT_ENV: "11500"} if not running else {odk.PORT_ENV: "11501"}
        before = len(docker.calls)
        res = odk.start(docker, gpu=gpu, environ=moved, connect=nothing_listens)
        new = docker.calls[before:]
        assert res.ok and "moved from port" in res.message, res.message
        assert ["docker", "rm", "-f", odk.CONTAINER] in new
        assert new[-1][:2] == ["docker", "run"] and docker.port == int(moved[odk.PORT_ENV])
        assert ["docker", "start", odk.CONTAINER] not in new
    # the same port again: no remake
    docker.running = False
    before = len(docker.calls)
    res = odk.start(docker, gpu=gpu, environ={odk.PORT_ENV: "11501"}, connect=nothing_listens)
    assert res.ok and docker.calls[-1] == ["docker", "start", odk.CONTAINER]
    assert not [c for c in docker.calls[before:] if c[1] == "rm"]


def test_start_refuses_when_docker_is_down_or_the_port_is_someone_elses():
    res = odk.start(Docker(up=False), environ={}, connect=nothing_listens)
    assert not res.ok and "Docker is not answering" in res.message
    docker = Docker()
    res = odk.start(docker, environ={}, connect=lambda h, p: (h, p) == ("127.0.0.1", 11435))
    assert not res.ok and "Something else is already listening on 127.0.0.1:11435" in res.message
    assert not [c for c in docker.calls if c[1] in ("run", "start")], "started over a clash"


def test_a_failed_run_is_reported_with_dockers_own_last_line():
    docker = Docker(run_rc=125, run_out="pulling...\nError: no space left on device")
    res = odk.start(docker, gpu=odk.GpuChoice("cpu", (), odk.IMAGE, ""), environ={},
                    connect=nothing_listens)
    assert not res.ok and res.message.endswith("no space left on device")


def test_stop_keeps_the_models_volume():
    docker = Docker(exists=True, running=True)
    res = odk.stop(docker)
    assert res.ok and odk.VOLUME in res.message
    assert docker.calls[-1] == ["docker", "stop", odk.CONTAINER]
    assert not [c for c in docker.calls if "rm" in c or "volume" in c]


def test_wait_ready_polls_the_container_endpoint_until_it_answers():
    asked = []
    answers = iter([False, False, True])
    clock = iter(range(100))
    ok = odk.wait_ready({odk.PORT_ENV: "12345"}, 10, fetch=lambda u: asked.append(u) or next(answers),
                        sleep=lambda s: None, clock=lambda: next(clock))
    assert ok and set(asked) == {"http://127.0.0.1:12345/api/tags"} and len(asked) == 3


# ── the choice is saved, and every reader sees the same one ────────────────────────────
def test_the_mode_is_saved_and_unknown_values_read_as_system(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "s"))
    assert odk.current_mode() == odk.SYSTEM
    odk.set_mode(odk.DOCKER)
    assert odk.current_mode() == odk.DOCKER
    assistant_settings.update(expanded=True)               # another key: merged, not wiped
    assert odk.current_mode() == odk.DOCKER and assistant_settings.get("expanded") is True
    assistant_settings.update(ollama="bogus")
    assert odk.current_mode() == odk.SYSTEM
    with pytest.raises(ValueError):
        odk.set_mode("bogus")


def test_the_environment_switch_changes_only_ollama_host():
    base = {"PATH": "/bin", "OLLAMA_HOST": "127.0.0.1:9999", "X": "1"}
    assert odk.assistant_env(odk.SYSTEM, base) == base
    env = odk.assistant_env(odk.DOCKER, base)
    assert env["OLLAMA_HOST"] == "127.0.0.1:11435" and env["X"] == "1"
    assert base["OLLAMA_HOST"] == "127.0.0.1:9999", "the caller's environment was changed"
    # the loopback rule still holds for what docker mode produces
    assert lai.ollama_host(env) == ("127.0.0.1", 11435)


def test_docker_mode_rewrites_the_wrong_advice_in_a_snapshot():
    snap = lai.Snapshot(taken=0.0, ollama_installed=False, ollama_up=False,
                        problem="Ollama is not installed on this machine.", fix="Install it")
    odk.adjust_snapshot(snap, odk.DOCKER)
    assert "Docker Ollama is not answering" in snap.problem and "Start local assistant" in snap.fix
    snap = lai.Snapshot(taken=0.0, ollama_up=True, models=[])
    odk.adjust_snapshot(snap, odk.DOCKER)
    assert odk.pull_command(lai.DEFAULT_MODEL) in snap.fix
    untouched = lai.Snapshot(taken=0.0, problem="p", fix="f")
    assert odk.adjust_snapshot(untouched, odk.SYSTEM).problem == "p"


def test_starting_in_docker_mode_runs_the_container_first_then_the_worker_against_it():
    order = []

    def starter(runner, environ):
        order.append(("container", environ["OLLAMA_HOST"]))
        return odk.StartOutcome(True, "ok", ["docker", "run"])

    def ready(env, timeout):
        order.append(("ready", env["OLLAMA_HOST"]))
        return True

    real = lai.start_assistant
    try:
        lai.start_assistant = lambda gen, env=None, spawn=None: order.append(
            ("worker", env["OLLAMA_HOST"], env.get("HUGMESH_AGENT_CONTEXT"))) or lai.StartResult(True, "s")
        res = odk.start_assistant(GENERATOR_DIR, odk.DOCKER, environ={"PATH": "/bin"},
                                  extra_env={"HUGMESH_AGENT_CONTEXT": "/x/ctx.md"},
                                  starter=starter, ready=ready)
        assert res.ok
        assert order == [("container", "127.0.0.1:11435"), ("ready", "127.0.0.1:11435"),
                         ("worker", "127.0.0.1:11435", "/x/ctx.md")]
        order.clear()
        res = odk.start_assistant(GENERATOR_DIR, odk.SYSTEM, environ={"OLLAMA_HOST": "127.0.0.1:7"},
                                  starter=starter, ready=ready)
        assert order == [("worker", "127.0.0.1:7", None)], "system mode started a container"
        order.clear()
        res = odk.start_assistant(GENERATOR_DIR, odk.DOCKER, environ={},
                                  starter=lambda r, environ: odk.StartOutcome(False, "no docker"),
                                  ready=ready)
        assert not res.ok and "no docker" in res.message and order == []
        res = odk.start_assistant(GENERATOR_DIR, odk.DOCKER, environ={}, starter=starter,
                                  ready=lambda e, t: False, ready_timeout=3)
        assert not res.ok and "did not answer" in res.message
        assert not [o for o in order if o[0] == "worker"], "the worker started on a dead server"
    finally:
        lai.start_assistant = real


# ── THE INERT-TOGGLE PROOF: which endpoint each face really calls ──────────────────────
@pytest.fixture
def two_servers(monkeypatch):
    """One fake for the system Ollama ($OLLAMA_HOST), one for the container (its port
    set through the documented override)."""
    system, docker = FakeOllama(), FakeOllama()
    system.chunks, docker.chunks = ["from-system"], ["from-docker"]
    monkeypatch.setenv("OLLAMA_HOST", system.host)
    monkeypatch.setenv(odk.PORT_ENV, str(docker.port))
    yield system, docker
    system.close()
    docker.close()


def _paths(server):
    return [(m, p) for m, p, _b in server.requests]


@pytest.mark.parametrize("mode", [odk.SYSTEM, odk.DOCKER])
def test_the_status_read_and_the_prompt_reach_the_chosen_instance_only(two_servers, mode):
    system, docker = two_servers
    chosen, other = (system, docker) if mode == odk.SYSTEM else (docker, system)
    env = odk.assistant_env(mode)
    snap = lai.read_snapshot(env=env, builds=lambda: [])
    assert snap.ollama_up and snap.host.endswith(str(chosen.port))
    answer = lai.send_prompt("hi", env=env)
    assert answer == ("from-system" if mode == odk.SYSTEM else "from-docker")
    assert ("POST", "/api/chat") in _paths(chosen)
    assert _paths(other) == [], f"{mode} mode also reached the other instance"


@pytest.mark.parametrize("mode", [odk.SYSTEM, odk.DOCKER])
def test_the_panel_prompt_reaches_the_chosen_instance(qapp, two_servers, mode, monkeypatch,
                                                      tmp_path):
    from hugmesh_studio.gui import _local_ai_dock as dock_mod
    system, docker = two_servers
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "studio"))
    odk.set_mode(mode)
    dock = dock_mod.LocalAIDock(GENERATOR_DIR, auto_poll=False, expanded=True,
                                snapshot_fn=lambda: lai.Snapshot(taken=0.0), agent_card=False)
    dock.show()                                  # its drain timer runs while it is shown
    try:
        assert dock.ollama_mode == mode
        dock.prompt.setText("hello")
        assert dock.send()
        end = time.monotonic() + 10
        while dock._busy and time.monotonic() < end:
            qapp.processEvents()
            time.sleep(0.02)
        qapp.processEvents()
        text = dock.answer.toPlainText()
        chosen, other = (system, docker) if mode == odk.SYSTEM else (docker, system)
        assert ("from-system" if mode == odk.SYSTEM else "from-docker") in text, text
        assert ("POST", "/api/chat") in _paths(chosen) and _paths(other) == []
        # and the panel SAYS which one: the label names the endpoint that was called
        assert str(chosen.port) in dock.instance_label.text() or mode == odk.SYSTEM
    finally:
        dock.close()
        dock.deleteLater()


def test_switching_in_the_panel_moves_the_next_prompt_and_is_saved(qapp, two_servers,
                                                                  monkeypatch, tmp_path):
    from hugmesh_studio.gui import _local_ai_dock as dock_mod
    system, docker = two_servers
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "studio"))
    dock = dock_mod.LocalAIDock(GENERATOR_DIR, auto_poll=False, expanded=True,
                                snapshot_fn=lambda: lai.Snapshot(taken=0.0), agent_card=False)
    dock.show()                                  # its drain timer runs while it is shown
    try:
        assert dock.mode_system.isChecked() and dock.ollama_mode == odk.SYSTEM
        dock.mode_docker.setChecked(True)                 # what a click does
        assert dock.ollama_mode == odk.DOCKER and odk.current_mode() == odk.DOCKER
        assert f"127.0.0.1:{docker.port}" in dock.instance_label.text()
        dock.apply_snapshot(lai.Snapshot(taken=0.0, summary="Local AI: ready"))
        assert dock.summary.full_text() == "Local AI (Docker): ready", "the bar hides the instance"
        assert dock.docker_start_btn.isVisible() or not dock.isVisible()
        dock.prompt.setText("which?")
        dock.send()
        end = time.monotonic() + 10
        while dock._busy and time.monotonic() < end:
            qapp.processEvents()
            time.sleep(0.02)
        assert ("POST", "/api/chat") in _paths(docker) and _paths(system) == []
    finally:
        dock.close()
        dock.deleteLater()


@pytest.mark.parametrize("mode", [odk.SYSTEM, odk.DOCKER])
def test_the_agent_probe_and_the_launched_agent_use_the_chosen_instance(two_servers, mode,
                                                                       tmp_path):
    system, docker = two_servers
    chosen, other = (system, docker) if mode == odk.SYSTEM else (docker, system)
    chosen.models = [{"name": "qwen3:8b", "capabilities": ["tools"]}]
    env = odk.assistant_env(mode)
    pr = la.probe(environ=env)
    assert pr.server_up and pr.server.endswith(str(chosen.port))
    assert _paths(other) == []
    # the agent's own environment: the env -i line the terminal runs
    src = tmp_path / "hugmesh-x"
    src.mkdir()
    import subprocess
    for args in (["init", "-q", "-b", "main"], ["commit", "-q", "--allow-empty", "-m", "m"]):
        subprocess.run(["git", *args], cwd=src, check=True, capture_output=True,
                       env=dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
                                GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t"))
    plan = la.prepare(lane=la.LANE_DOCKER, mesh="m", domains=["m"], doors=[], repo="hugmesh-x",
                      source=str(src), source_root=str(tmp_path), source_mode="existing",
                      generator_dir=GENERATOR_DIR, pr=pr, environ=env,
                      state_root=str(tmp_path / "state"))
    assert plan.env["OLLAMA_HOST"].endswith(f":{chosen.port}")
    assert f"OLLAMA_HOST=127.0.0.1:{chosen.port}" in plan.run_line


def test_the_text_ui_prompt_follows_the_saved_choice(two_servers, monkeypatch, tmp_path):
    from hugmesh_studio.tui import local_ai as tui_local_ai
    system, docker = two_servers
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "studio"))
    host = tui_local_ai.Standalone(GENERATOR_DIR)
    screen = host.open()
    host.feed("ollama docker")
    assert odk.current_mode() == odk.DOCKER and f"127.0.0.1:{docker.port}" in screen.message
    host.feed("hi")
    assert "ai:  from-docker" in screen.transcript, (screen.transcript, screen.message)
    assert not [r for r in system.requests if r[1] == "/api/chat"]
    host.feed("ollama system")
    host.feed("hi again")
    assert "ai:  from-system" in screen.transcript
    host.feed("ollama sideways")
    assert "ollama docker, or ollama system" in screen.message


@pytest.fixture(scope="module")
def qapp():
    from hugmesh_studio.gui.qt import QtWidgets
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication(["t"])


def test_the_agent_card_in_the_panel_probes_and_plans_with_the_chosen_instance(
        qapp, monkeypatch, tmp_path):
    """The card is handed the panel's switch: its default look at the machine and the
    plan it builds both carry the chosen instance's address (the plan's env is what the
    launched agent's ``env -i`` line is built from)."""
    from hugmesh_studio.gui import _local_ai_dock as dock_mod
    from hugmesh_studio.gui.pages import _local_agent_widget as law
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "studio"))
    monkeypatch.setenv(odk.PORT_ENV, "12999")
    odk.set_mode(odk.DOCKER)
    probed, prepared = [], []
    monkeypatch.setattr(la, "probe", lambda environ=None, **k: probed.append(environ) or la.Probe())
    monkeypatch.setattr(la, "prepare", lambda **kw: prepared.append(kw) or "plan")
    dock = dock_mod.LocalAIDock(GENERATOR_DIR, auto_poll=False, expanded=False,
                                snapshot_fn=lambda: lai.Snapshot(taken=0.0))
    try:
        card = dock.agent_card
        card._prober()                                   # the default look
        assert probed and probed[-1]["OLLAMA_HOST"] == "127.0.0.1:12999"
        snap = card._snapshot()
        assert snap.env["OLLAMA_HOST"] == "127.0.0.1:12999"
        app = law.AppChoice("hugmesh-x", str(tmp_path / "hugmesh-x"), True)
        snap = law._Snapshot(snap.lane, app, "claude", "qwen3:8b", snap.ctx, la.Probe(), snap.env)
        card._prepare_plan(snap)
        assert prepared[-1]["environ"]["OLLAMA_HOST"] == "127.0.0.1:12999"
        assert "## Where the local sources are" in prepared[-1]["context_text"]
        # switching back moves both
        dock.mode_system.setChecked(True)
        card._prober()
        assert probed[-1].get("OLLAMA_HOST") == os.environ.get("OLLAMA_HOST")
        assert card._snapshot().env.get("OLLAMA_HOST") == os.environ.get("OLLAMA_HOST")
    finally:
        dock.close()
        dock.deleteLater()

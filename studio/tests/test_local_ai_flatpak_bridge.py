"""The local assistant inside the Flatpak: what crosses to the host, and what it says.

Qt-free. Two defects of hugmesh-generator#933 round 1, pinned:

  * SECRETS ON A COMMAND LINE. The start of ``scripts/local-ai.sh`` from the sandbox put
    every OLLAMA_* / LOCAL_AI_* / HUGMESH_* / AGENT* variable of the Studio's environment
    on the ``flatpak-spawn`` command line as ``--env=K=V``. That command line is readable
    by every user of the machine (ps, /proc/<pid>/cmdline is mode 444, and /proc has no
    hidepid), and the Studio's environment can hold HUGMESH_ADMIN_TOKEN,
    HUGMESH_GH_TOKEN, HUGMESH_STUDIO_SUDO_PASSWORD (core/askpass.py documents it) and
    OLLAMA_API_KEY. Now: an explicit allowlist (ollama_docker.HOST_ASSISTANT_ENV), handed
    over through ``--env-fd``; the tests read the descriptor and look for every fake
    secret in it and in the argv.
  * A SUMMARY THAT CONTRADICTS THE PROBLEM. read_snapshot writes the one-line summary
    from its own problem; the Docker and Flatpak adjusters rewrite the problem and left
    the summary saying "Ollama is not installed on this machine".

Every value here is fake. Nothing is spawned: Popen and run are replaced.
"""
import os
import subprocess

import pytest

from hugmesh_studio.core import flatpak_host
from hugmesh_studio.core import local_ai_status as lai
from hugmesh_studio.core import ollama_docker as odk

#: Fake credentials shaped like the ones the round-1 probe found on the argv.
FAKE_SECRETS = {
    "HUGMESH_ADMIN_TOKEN": "fake-admin-token-0001",
    "HUGMESH_GH_TOKEN": "fake-gh-token-0002",
    "HUGMESH_STUDIO_SUDO_PASSWORD": "fake-sudo-password-0003",
    "HUGMESH_MESH_SECRET": "fake-mesh-secret-0004",
    "OLLAMA_API_KEY": "fake-ollama-key-0005",
    "LOCAL_AI_PASSWORD": "fake-local-ai-password-0006",
    "AGENT_TOKEN": "fake-agent-token-0007",
    "GH_TOKEN": "fake-gh-0008",
}


@pytest.fixture
def inside_flatpak(monkeypatch):
    # /.flatpak-info does not exist on the test host; both module APIs read it through
    # flatpak_host.in_flatpak, so this is the sandbox as the code sees it.
    monkeypatch.setattr(flatpak_host, "in_flatpak", lambda *a, **k: True)


@pytest.fixture
def checkout(tmp_path):
    gen = tmp_path / "gen"
    (gen / "scripts").mkdir(parents=True)
    (gen / "scripts" / "local-ai.sh").write_text("#!/bin/bash\n")
    return gen


def _read_env_fd(argv):
    """The environment handed over on ``--env-fd=N``, as a dict (env -0 format)."""
    fds = [a for a in argv if a.startswith("--env-fd=")]
    assert len(fds) == 1, argv
    fd = int(fds[0].split("=", 1)[1])
    os.lseek(fd, 0, os.SEEK_SET)
    raw = b""
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        raw += chunk
    pairs = [p.decode() for p in raw.split(b"\0") if p]
    return dict(p.split("=", 1) for p in pairs)


def _assert_no_secret(argv, forwarded):
    for name, value in FAKE_SECRETS.items():
        assert not [a for a in argv if name in a or value in a], (name, argv)
        assert name not in forwarded and value not in forwarded.values(), (name, forwarded)
    assert not [a for a in argv if a.startswith("--env=")], argv


def test_starting_the_assistant_from_the_flatpak_puts_no_secret_on_any_argv(
        tmp_path, checkout, inside_flatpak, monkeypatch):
    seen = []

    class FakePopen:
        def __init__(self, argv, **kwargs):
            # read the descriptor NOW: it is closed once Popen returns
            forwarded = _read_env_fd(argv) if any(
                a.startswith("--env-fd=") for a in argv) else {}
            seen.append((list(argv), kwargs, forwarded))

    monkeypatch.setattr(subprocess, "Popen", FakePopen)
    environ = dict(FAKE_SECRETS, HOME=str(tmp_path), PATH="/app/bin:/usr/bin",
                   HUGMESH_LOCAL_AI_DIR=str(tmp_path / "state"), LOCAL_AI_MODEL="qwen3:1.7b",
                   XDG_STATE_HOME=str(tmp_path / ".var" / "state"))
    res = odk.start_assistant(str(checkout), odk.SYSTEM, environ=environ, osname="posix")
    assert res.ok, res.message
    assert len(seen) == 1
    argv, kwargs, forwarded = seen[0]
    # nothing secret anywhere; it runs on the host, the script last, from the checkout
    _assert_no_secret(argv, forwarded)
    assert argv[:2] == ["flatpak-spawn", "--host"]
    assert argv[-3:] == ["bash", str(checkout / "scripts" / "local-ai.sh"), "start"]
    assert f"--directory={checkout}" in argv
    # once the Flatpak's Popen hook is installed too (flatpak_host.install, #936), this
    # argv passes through it as it stands: it is already a flatpak-spawn command
    assert not flatpak_host.runs_on_host(argv)
    # what does cross is the allowlist, and what the host script needs is in it
    assert set(forwarded) <= set(odk.HOST_ASSISTANT_ENV), forwarded
    assert forwarded["HUGMESH_LOCAL_AI_DIR"] == str(tmp_path / "state")
    assert forwarded["LOCAL_AI_MODEL"] == "qwen3:1.7b"
    assert forwarded.get("OLLAMA_HOST") == environ.get("OLLAMA_HOST")
    assert "PATH" not in forwarded and "XDG_STATE_HOME" not in forwarded
    # and the descriptor really is handed to the child
    fd = int([a for a in argv if a.startswith("--env-fd=")][0].split("=", 1)[1])
    assert fd in kwargs["pass_fds"]


def test_docker_mode_start_from_the_flatpak_forwards_the_containers_address_only(
        tmp_path, checkout, inside_flatpak, monkeypatch):
    seen = []

    def popen(argv, **kwargs):
        seen.append((list(argv), _read_env_fd(argv)))

    environ = dict(FAKE_SECRETS, HOME=str(tmp_path), HUGMESH_LOCAL_AI_DIR=str(tmp_path / "s"))
    res = odk.start_assistant(
        str(checkout), odk.DOCKER, environ=environ, osname="posix", spawn=popen,
        starter=lambda runner, environ: odk.StartOutcome(True, "ok", ["docker", "start"]),
        ready=lambda env, timeout: True)
    assert res.ok, res.message
    argv, forwarded = seen[0]
    _assert_no_secret(argv, forwarded)
    assert forwarded["OLLAMA_HOST"] == odk.endpoint(odk.DOCKER, environ)


def test_the_allowlist_names_no_credential():
    for name in odk.HOST_ASSISTANT_ENV + odk.HOST_DOCKER_ENV:
        upper = name.upper()
        for word in ("TOKEN", "PASSWORD", "SECRET", "KEY", "CREDENTIAL", "PASS"):
            assert word not in upper, name
    assert odk.host_forward_env(dict(FAKE_SECRETS, OLLAMA_HOST="127.0.0.1:1")) == {
        "OLLAMA_HOST": "127.0.0.1:1"}


def test_outside_the_flatpak_the_script_inherits_the_environment_as_before(
        tmp_path, checkout, monkeypatch):
    monkeypatch.setattr(flatpak_host, "in_flatpak", lambda *a, **k: False)
    seen = []
    res = odk.start_assistant(str(checkout), odk.SYSTEM, osname="posix",
                              environ={"HUGMESH_LOCAL_AI_DIR": str(tmp_path / "s"), "X": "1"},
                              spawn=lambda argv, **kw: seen.append((argv, kw)))
    assert res.ok
    argv, kw = seen[0]
    assert argv == ["bash", str(checkout / "scripts" / "local-ai.sh"), "start"]
    assert kw["env"]["X"] == "1" and "pass_fds" not in kw


def test_docker_commands_from_the_flatpak_run_on_the_host_with_no_secret(
        tmp_path, inside_flatpak, monkeypatch):
    seen = []

    def run(argv, **kwargs):
        seen.append((list(argv), _read_env_fd(argv), kwargs))
        return subprocess.CompletedProcess(argv, 0, "29.9.0\n", "")

    for k, v in FAKE_SECRETS.items():
        monkeypatch.setenv(k, v)
    monkeypatch.setenv("DOCKER_HOST", "unix:///run/user/1000/docker.sock")
    for name in ("DOCKER_CONTEXT", "DOCKER_CONFIG"):       # the runner's own, if any
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr(subprocess, "run", run)
    assert odk._run(["docker", "version"]) == (0, "29.9.0\n")
    argv, forwarded, kwargs = seen[0]
    assert argv[:2] == ["flatpak-spawn", "--host"] and argv[-2:] == ["docker", "version"]
    assert f"--directory={tmp_path}" in argv
    _assert_no_secret(argv, forwarded)
    assert forwarded == {"DOCKER_HOST": "unix:///run/user/1000/docker.sock"}


def test_outside_the_flatpak_docker_runs_as_it_stands(monkeypatch):
    seen = []
    monkeypatch.setattr(flatpak_host, "in_flatpak", lambda *a, **k: False)
    monkeypatch.setattr(subprocess, "run", lambda argv, **kw: (
        seen.append(argv), subprocess.CompletedProcess(argv, 0, "ok", ""))[1])
    assert odk._run(["docker", "ps"]) == (0, "ok")
    assert seen == [["docker", "ps"]]


def test_a_host_without_ollama_is_asked_again_next_time(inside_flatpak, monkeypatch):
    answers = iter([("", 1), ("/usr/bin/ollama\n", 0)])
    calls = []

    def run(argv, **kw):
        calls.append(argv)
        out, code = next(answers)
        return subprocess.CompletedProcess(argv, code, out, "")

    monkeypatch.setattr(flatpak_host, "_WHICH_CACHE", {})
    monkeypatch.setattr(subprocess, "run", run)
    assert odk.host_has("ollama") is False
    assert odk.host_has("ollama") is True          # installed meanwhile: seen
    assert odk.host_has("ollama") is True and len(calls) == 2   # a "yes" is kept
    assert calls[0][:2] == ["flatpak-spawn", "--host"] and calls[0][-1] == "ollama"


# ── the summary follows the problem ──────────────────────────────────────────────────
def _down_snapshot(tmp_path, monkeypatch):
    """What read_snapshot says when nothing answers and this process sees no ollama."""
    monkeypatch.setattr(lai.shutil, "which", lambda name, *a, **k: None)
    env = {"HUGMESH_LOCAL_AI_DIR": str(tmp_path / "state"), "HOME": str(tmp_path)}
    snap = lai.read_snapshot(env, probe=lambda: (False, [], [], ""), builds=lambda: [],
                             osname="posix")
    assert snap.summary == "Local AI: Ollama is not installed on this machine"
    return snap


def test_docker_mode_summary_names_the_docker_ollama_not_a_missing_install(
        tmp_path, monkeypatch):
    monkeypatch.setattr(flatpak_host, "in_flatpak", lambda *a, **k: False)
    monkeypatch.delenv(odk.PORT_ENV, raising=False)
    snap = odk.adjust_snapshot(_down_snapshot(tmp_path, monkeypatch), odk.DOCKER)
    assert snap.problem == "The Studio's Docker Ollama is not answering on 127.0.0.1:11435."
    assert snap.summary == "Local AI: The Studio's Docker Ollama is not answering on 127.0.0.1:11435"
    assert "not installed" not in snap.summary


def test_flatpak_system_mode_summary_says_installed_but_stopped(
        tmp_path, inside_flatpak, monkeypatch):
    monkeypatch.setattr(flatpak_host, "host_which", lambda name, **k: "/usr/bin/ollama")
    snap = odk.adjust_snapshot(_down_snapshot(tmp_path, monkeypatch), odk.SYSTEM)
    assert snap.problem.startswith("Ollama is installed but is not answering on 127.0.0.1:11434")
    assert snap.summary == "Local AI: Ollama is installed but is not answering on 127.0.0.1:11434"
    assert "not installed" not in snap.summary


def test_flatpak_system_mode_with_no_host_ollama_keeps_saying_not_installed(
        tmp_path, inside_flatpak, monkeypatch):
    monkeypatch.setattr(flatpak_host, "host_which", lambda name, **k: None)
    snap = odk.adjust_snapshot(_down_snapshot(tmp_path, monkeypatch), odk.SYSTEM)
    assert snap.summary == "Local AI: Ollama is not installed on this machine"
    assert "Docker" in snap.fix


def test_docker_mode_no_model_summary_matches_the_problem(tmp_path, monkeypatch):
    monkeypatch.setattr(flatpak_host, "in_flatpak", lambda *a, **k: False)
    snap = lai.Snapshot(taken=0.0, ollama_up=True, models=[], host="127.0.0.1:11435",
                        problem="Ollama is running but no model is pulled.",
                        summary="stale")
    odk.adjust_snapshot(snap, odk.DOCKER)
    assert snap.summary.startswith("Local AI: no model pulled")

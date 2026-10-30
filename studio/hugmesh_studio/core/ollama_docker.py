"""Which Ollama the local assistant uses: the system one, or the Studio's own container.

Qt-free, stdlib only. The Studio dock, the text screen and their tests all go through
this module, so "which instance is in use" has one answer.

TWO MODES.

* ``system`` (the default, and what every earlier Studio did): the Ollama this machine
  already runs, at ``$OLLAMA_HOST`` or 127.0.0.1:11434. Nothing here touches it.
* ``docker``: a container the Studio starts on request, from a PINNED image, with

    - a loopback-only port, 127.0.0.1:11435 by default — never 11434, so it can run
      beside a system Ollama without either one taking the other's port;
    - a named volume (``hugmesh-studio-ollama-models``) for the pulled models, so a
      removed container does not throw the models away;
    - GPU passthrough only when Docker can actually provide it: ``--gpus all`` when
      the daemon lists the ``nvidia`` runtime or a CDI spec for nvidia.com/gpu exists,
      the ROCm image with ``/dev/kfd`` and ``/dev/dri`` when this is an AMD machine,
      and CPU otherwise (said in words, never hidden).

THE ONE SWITCH. :func:`assistant_env` turns a mode into the environment every caller
passes on: the dock's status read, its prompt, the start request, the local-agent probe
and the launched agent's own ``env -i`` line. In docker mode it sets ``OLLAMA_HOST`` to
the container's loopback port; in system mode it leaves the environment as it is. The
loopback rule of :mod:`.local_ai_status` still applies to both: nothing here can point
the assistant off this machine.

Nothing is started at import or when a mode is picked. :func:`start` runs ``docker run``
(or ``docker start`` for a stopped container) only when the person presses Start, and it
may take minutes the first time, because the image is about 3.8 GB.
"""
from __future__ import annotations

import glob
import json
import os
import socket
import subprocess
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Callable, Optional, Sequence

from . import assistant_settings, proc_text

__all__ = [
    "SYSTEM", "DOCKER", "MODES", "MODE_WORDS", "IMAGE", "IMAGE_ROCM", "IMAGE_VERSION",
    "CONTAINER", "VOLUME", "DEFAULT_PORT", "SYSTEM_PORT", "LABEL",
    "GpuChoice", "DockerState", "StartOutcome",
    "current_mode", "set_mode", "docker_port", "endpoint", "assistant_env",
    "detect_gpu", "run_argv", "bound_port", "port_problem", "state", "start", "stop",
    "wait_ready",
    "pull_command", "describe", "adjust_snapshot",
]

SYSTEM = "system"
DOCKER = "docker"
MODES = (SYSTEM, DOCKER)
MODE_WORDS = {
    SYSTEM: "The Ollama this machine runs",
    DOCKER: "The Studio's own Ollama in Docker",
}

#: Pinned by version AND digest (the multi-arch index, checked with
#: ``docker buildx imagetools inspect``). 0.40.0 was published 2026-10-06 and is the
#: same version as the system client this was written against.
IMAGE_VERSION = "0.40.0"
IMAGE = ("ollama/ollama:0.40.0@sha256:"
         "1bef639749741b375e9a1eb2c1346fb57ce52f5432de1f74846e44ccc18e1687")
IMAGE_ROCM = ("ollama/ollama:0.40.0-rocm@sha256:"
              "dece43fb29d6b365e68563434a855c040fe5dab8cd3c0c5a3836a889e4d89b7b")
CONTAINER = "hugmesh-studio-ollama"
VOLUME = "hugmesh-studio-ollama-models"
LABEL = "net.hugmesh.studio=local-ai-ollama"
SYSTEM_PORT = 11434
DEFAULT_PORT = 11435
#: The settings a person can override with an environment variable, for a host where
#: 11435 is taken. Must stay loopback-legal and must never be the system port.
PORT_ENV = "HUGMESH_OLLAMA_DOCKER_PORT"
#: The server settings ``scripts/local-ai.sh up`` gives the system Ollama, so the two
#: instances answer the same way (docs/LOCAL-AI-ASSISTANT.md section 3).
SERVER_ENV = (("OLLAMA_CONTEXT_LENGTH", "32768"), ("OLLAMA_FLASH_ATTENTION", "1"),
              ("OLLAMA_KV_CACHE_TYPE", "q8_0"))

Runner = Callable[[Sequence[str], float], "tuple[int, str]"]


def _run(argv: Sequence[str], timeout: float = 30.0) -> "tuple[int, str]":
    """Run a docker command; ``(exit code, stdout + stderr)``. Never raises."""
    try:
        # UTF-8 with replacement, never the code page: on native Windows text=True alone
        # decodes docker's output as cp1252, and a byte it cannot map raised past the
        # "never raises" promise (#827 group 4)
        p = subprocess.run(list(argv), capture_output=True, text=True, timeout=timeout,
                           stdin=subprocess.DEVNULL, **proc_text.TEXT_IO)
    except FileNotFoundError:
        return 127, f"{argv[0]}: command not found"
    except subprocess.TimeoutExpired:
        return 124, f"{' '.join(argv[:3])} did not finish in {int(timeout)} seconds"
    except OSError as exc:
        return 126, str(exc)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


# ── the choice ───────────────────────────────────────────────────────────────────────
def current_mode() -> str:
    """The saved choice, ``system`` when there is none or it is not one we know."""
    mode = assistant_settings.get("ollama", SYSTEM)
    return mode if mode in MODES else SYSTEM


def set_mode(mode: str) -> bool:
    if mode not in MODES:
        raise ValueError(f"unknown Ollama mode {mode!r}; use one of {MODES}")
    return assistant_settings.update(ollama=mode)


def docker_port(environ=None) -> int:
    """The container's loopback port: ``$HUGMESH_OLLAMA_DOCKER_PORT`` when it is a
    usable number other than 11434, else 11435."""
    environ = os.environ if environ is None else environ
    raw = (environ.get(PORT_ENV) or "").strip()
    if raw.isdigit() and 1024 <= int(raw) < 65536 and int(raw) != SYSTEM_PORT:
        return int(raw)
    return DEFAULT_PORT


def endpoint(mode: str, environ=None) -> str:
    """``host:port`` the assistant talks to in ``mode``. System mode reports what
    ``$OLLAMA_HOST`` says (or the default); it does not judge it — the loopback rule in
    local_ai_status does that, and refuses with a sentence."""
    environ = os.environ if environ is None else environ
    if mode == DOCKER:
        return f"127.0.0.1:{docker_port(environ)}"
    return (environ.get("OLLAMA_HOST") or "").strip() or f"127.0.0.1:{SYSTEM_PORT}"


def assistant_env(mode: str, environ=None) -> dict:
    """The environment every assistant call runs with in ``mode`` (a copy; the
    Studio's own environment is never changed)."""
    env = dict(os.environ if environ is None else environ)
    if mode == DOCKER:
        env["OLLAMA_HOST"] = endpoint(DOCKER, env)
    return env


# ── the GPU ──────────────────────────────────────────────────────────────────────────
@dataclass(frozen=True)
class GpuChoice:
    kind: str                  # "nvidia" | "amd" | "cpu"
    flags: "tuple[str, ...]"
    image: str
    words: str


def detect_gpu(runner: Optional[Runner] = None, *, exists=os.path.exists,
               globber=glob.glob) -> GpuChoice:
    """What GPU the container can be given. Read-only: ``docker info`` and a look at
    /etc/cdi and /dev. Passthrough is offered only when Docker can really provide it,
    because ``--gpus all`` on a daemon without the NVIDIA runtime fails the run."""
    run = runner or _run
    rc, out = run(["docker", "info", "--format", "{{json .Runtimes}}"], 15.0)
    runtimes: dict = {}
    if rc == 0:
        try:
            parsed = json.loads(out.strip().splitlines()[-1] if out.strip() else "{}")
            runtimes = parsed if isinstance(parsed, dict) else {}
        except ValueError:
            runtimes = {}
    cdi = [p for d in ("/etc/cdi", "/var/run/cdi") for p in globber(os.path.join(d, "*.y*ml"))
           if "nvidia" in os.path.basename(p).lower()]
    if "nvidia" in runtimes or cdi:
        how = "the nvidia runtime" if "nvidia" in runtimes else "a CDI spec"
        return GpuChoice("nvidia", ("--gpus", "all"), IMAGE,
                         f"NVIDIA GPU passed through (Docker has {how}).")
    if exists("/dev/kfd") and exists("/dev/dri"):
        return GpuChoice("amd", ("--device", "/dev/kfd", "--device", "/dev/dri",
                                 "--group-add", "video"), IMAGE_ROCM,
                         "AMD GPU passed through (ROCm image).")
    why = ("Docker is not answering" if rc != 0 else
           "Docker has no GPU runtime (install the NVIDIA container toolkit to use one)")
    return GpuChoice("cpu", (), IMAGE, f"CPU only: {why}. Answers will be slower.")


# ── the container ────────────────────────────────────────────────────────────────────
def run_argv(gpu: GpuChoice, port: int = DEFAULT_PORT) -> "list[str]":
    """The ``docker run`` that creates the container. Port bound to 127.0.0.1 ONLY:
    the Ollama API has no login (docs/LOCAL-AI-ASSISTANT.md section 8)."""
    if port == SYSTEM_PORT:
        raise ValueError("the Docker Ollama must not take the system Ollama's port 11434")
    argv = ["docker", "run", "-d", "--name", CONTAINER, "--label", LABEL,
            "-p", f"127.0.0.1:{port}:11434", "-v", f"{VOLUME}:/root/.ollama"]
    for key, value in SERVER_ENV:
        argv += ["-e", f"{key}={value}"]
    argv += list(gpu.flags)
    argv.append(gpu.image)
    return argv


@dataclass(frozen=True)
class DockerState:
    docker_ok: bool
    exists: bool = False
    running: bool = False
    image: str = ""
    error: str = ""


def state(runner: Optional[Runner] = None) -> DockerState:
    run = runner or _run
    rc, out = run(["docker", "version", "--format", "{{.Server.Version}}"], 15.0)
    if rc != 0:
        return DockerState(False, error=(out.strip().splitlines() or ["docker is not answering"])[-1])
    rc, out = run(["docker", "inspect", "--format", "{{.State.Running}} {{.Config.Image}}",
                   CONTAINER], 15.0)
    if rc != 0:
        return DockerState(True)
    words = out.strip().split(None, 1)
    return DockerState(True, True, bool(words) and words[0] == "true",
                       words[1] if len(words) > 1 else "")


def bound_port(runner: Optional[Runner] = None) -> Optional[int]:
    """The host port the existing container publishes 11434 on, or None when that
    cannot be read (no container, an old docker, a container made by hand)."""
    run = runner or _run
    rc, out = run(["docker", "inspect", "--format",
                   '{{range (index .HostConfig.PortBindings "11434/tcp")}}{{.HostPort}} {{end}}',
                   CONTAINER], 15.0)
    if rc != 0:
        return None
    words = out.split()
    return int(words[0]) if words and words[0].isdigit() else None


def port_problem(port: int, ours_running: bool, *, connect=None) -> str:
    """A sentence when ``port`` cannot be ours, else "". Something answering on the
    port while our container is NOT running is somebody else's server."""
    if port == SYSTEM_PORT:
        return "Port 11434 belongs to the system Ollama; the Docker one uses another port."
    if ours_running:
        return ""
    probe = connect or _connects
    if probe("127.0.0.1", port):
        return (f"Something else is already listening on 127.0.0.1:{port}. Stop it, or set "
                f"{PORT_ENV} to a free port and restart the Studio.")
    return ""


def _connects(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), timeout=0.5):
            return True
    except OSError:
        return False


@dataclass
class StartOutcome:
    ok: bool
    message: str
    argv: "list[str]" = field(default_factory=list)


def start(runner: Optional[Runner] = None, *, gpu: Optional[GpuChoice] = None,
          environ=None, connect=None) -> StartOutcome:
    """Make the container run. Blocking (a first start pulls the image): call it off
    the window thread. Creates it when missing, starts it when stopped, and leaves a
    running one alone."""
    run = runner or _run
    port = docker_port(environ)
    st = state(run)
    if not st.docker_ok:
        return StartOutcome(False, f"Docker is not answering ({st.error}). Start Docker, "
                                   "or switch back to the system Ollama.")
    moved = ""
    if st.exists:
        # A container made while another port was set keeps that port for life: a plain
        # `docker start` would bring it back on the OLD port while everything here talks
        # to the new one. Make it again (the models are in the volume, not in it).
        was = bound_port(run)
        if was is not None and was != port:
            rc, out = run(["docker", "rm", "-f", CONTAINER], 60.0)
            if rc != 0:
                last = (out.strip().splitlines() or ["(no output)"])[-1]
                return StartOutcome(False, f"The Docker Ollama is on port {was}, not {port}, "
                                           f"and could not be removed to move it: {last}",
                                    ["docker", "rm", "-f", CONTAINER])
            moved = f" (moved from port {was}; its models stay in the {VOLUME} volume)"
            st = DockerState(True)
    if st.running:
        return StartOutcome(True, f"The Docker Ollama is already running on 127.0.0.1:{port}.")
    clash = port_problem(port, False, connect=connect)
    if clash:
        return StartOutcome(False, clash)
    if st.exists:
        argv = ["docker", "start", CONTAINER]
        rc, out = run(argv, 120.0)
    else:
        argv = run_argv(gpu or detect_gpu(run), port)
        rc, out = run(argv, 1800.0)              # the first run pulls ~3.8 GB
    if rc != 0:
        last = (out.strip().splitlines() or ["(no output)"])[-1]
        return StartOutcome(False, f"docker could not start the Ollama container: {last}", argv)
    return StartOutcome(True, f"Started the Docker Ollama on 127.0.0.1:{port}{moved}.", argv)


def stop(runner: Optional[Runner] = None) -> StartOutcome:
    """Stop the container; the models volume stays."""
    run = runner or _run
    argv = ["docker", "stop", CONTAINER]
    rc, out = run(argv, 60.0)
    if rc != 0:
        last = (out.strip().splitlines() or ["(no output)"])[-1]
        return StartOutcome(False, f"Could not stop {CONTAINER}: {last}", argv)
    return StartOutcome(True, "Stopped the Docker Ollama. Its models stay in the "
                              f"{VOLUME} volume.", argv)


def wait_ready(environ=None, timeout: float = 60.0, *, fetch=None,
               sleep=time.sleep, clock=time.monotonic) -> bool:
    """Wait until the Docker Ollama answers ``/api/tags`` (True) or ``timeout`` passes."""
    url = f"http://{endpoint(DOCKER, environ)}/api/tags"
    get = fetch or _get
    end = clock() + timeout
    while True:
        if get(url):
            return True
        if clock() >= end:
            return False
        sleep(1.0)


def _get(url: str) -> bool:
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(url, timeout=2.0) as resp:
            return resp.status == 200
    except (OSError, ValueError, urllib.error.URLError):
        return False


def pull_command(model: str) -> str:
    return f"docker exec {CONTAINER} ollama pull {model}"


def describe(mode: str, environ=None) -> str:
    """One line for a screen: which instance is in use and where."""
    where = endpoint(mode, environ)
    if mode == DOCKER:
        return (f"In use: {MODE_WORDS[DOCKER]} ({CONTAINER}, {IMAGE.split('@')[0]}) on "
                f"{where}; models in the {VOLUME} volume.")
    return f"In use: {MODE_WORDS[SYSTEM]}, on {where}."


def adjust_snapshot(snap, mode: str, generator_dir: str = "."):
    """Rewrite a local-AI snapshot's problem and fix for docker mode, where "install
    Ollama" and "scripts/local-ai.sh up" are the wrong advice. Returns the snapshot."""
    if mode != DOCKER or snap is None:
        return snap
    if not getattr(snap, "ollama_up", False) and not getattr(snap, "problem", "").startswith(
            "OLLAMA_HOST"):
        snap.problem = (f"The Studio's Docker Ollama is not answering on "
                        f"{endpoint(DOCKER)}.")
        snap.fix = ("Press Start local assistant: it starts the container (the first start "
                    "downloads the image, about 3.8 GB).")
    elif getattr(snap, "ollama_up", False) and not getattr(snap, "models", None):
        from .local_ai_status import DEFAULT_MODEL
        snap.problem = "The Docker Ollama is running but no model is pulled into it."
        snap.fix = f"Pull one: {pull_command(DEFAULT_MODEL)}"
    return snap


def start_assistant(generator_dir: str, mode: str, *, environ=None, extra_env=None,
                    runner: Optional[Runner] = None, starter=None, ready=None,
                    ready_timeout: float = 90.0, osname: Optional[str] = None):
    """Start the local assistant against the instance ``mode`` names. Blocking: call it
    off the window thread. Returns a :class:`..local_ai_status.StartResult`.

    Docker mode makes the container run and answer FIRST, then runs the same
    ``scripts/local-ai.sh start`` as system mode with ``OLLAMA_HOST`` pointing at the
    container: that script's ``up`` sees an Ollama answering and starts none of its
    own, and the queue worker it starts inherits the address. ``extra_env`` carries the
    agent context and the checkouts folder (core/agent_context.py) to the worker.

    On native Windows the script cannot run (it is bash): System mode refuses in words,
    and Docker mode starts the container, waits for it, and says the panel can use it
    while the queue worker stays off."""
    from . import local_ai_status as lai
    windows = bool(lai.windows_refusal(osname))
    env = assistant_env(mode, environ)
    env.update(extra_env or {})
    if mode == DOCKER:
        res = (starter or start)(runner, environ=env)
        if not res.ok:
            return lai.StartResult(False, res.message, " ".join(res.argv) or
                                   f"docker start {CONTAINER}")
        if not (ready or wait_ready)(env, ready_timeout):
            return lai.StartResult(
                False, f"The Docker Ollama was started but did not answer on "
                       f"{endpoint(DOCKER, env)} within {int(ready_timeout)} seconds "
                       f"(see: docker logs {CONTAINER}).", f"docker logs {CONTAINER}")
        if windows:
            return lai.StartResult(
                True, f"The Studio's own Ollama is answering on {endpoint(DOCKER, env)}, and "
                      f"the panel asks it directly. The queue worker was not started: it is "
                      f"the bash script scripts/local-ai.sh, which the Windows build of the "
                      f"Studio cannot run (run the Studio inside WSL2 for it).", "")
    res = lai.start_assistant(generator_dir, env=env, osname=osname)
    if mode == DOCKER and not res.ok:
        # the "run it yourself" line must name the Docker instance, not the system one
        res = lai.StartResult(res.ok, res.message.replace(
            lai.commands(generator_dir)["start"],
            lai.commands(generator_dir, endpoint(DOCKER, env))["start"]),
            lai.commands(generator_dir, endpoint(DOCKER, env))["start"])
    return res


def commands_for(generator_dir: str, mode: Optional[str] = None, environ=None) -> dict:
    """``local_ai_status.commands`` for the instance ``mode`` names (the saved choice
    when None): in Docker mode each command carries that instance's OLLAMA_HOST."""
    from . import local_ai_status as lai
    mode = current_mode() if mode is None else mode
    host = endpoint(DOCKER, environ) if mode == DOCKER else ""
    return lai.commands(generator_dir, host)

"""The Flatpak's route to the host (core/flatpak_host.py) and what the capability
checks say inside the sandbox (core/platform_info.py). Qt-free.

The installed 0.4.1 Studio saw no Docker on a host running Docker 29.9.0: nothing called
flatpak-spawn --host, although the manifest granted it. These tests run the Popen hook
for real against a stand-in ``flatpak-spawn`` that records what it was asked and then
runs the command, so what crosses the bridge (argv, working directory, environment,
extra descriptors) is observed, not assumed.
"""
from __future__ import annotations

import ast
import json
import os
import shutil
import subprocess
import sys

import pytest

from hugmesh_studio.core import flatpak_host, platform_info
from hugmesh_studio.core.platform_info import HostInfo

PACKAGE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "hugmesh_studio")

needs_posix = pytest.mark.skipif(sys.platform == "win32" or not shutil.which("sh"),
                                 reason="runs a POSIX stand-in for flatpak-spawn")


# ---------------------------------------------------------------------------------------
# Which commands cross
# ---------------------------------------------------------------------------------------
@pytest.mark.parametrize("argv, host", [
    (["docker", "info"], True),
    (["/usr/bin/docker", "info"], True),
    (["make", "stack-up"], True),
    (["git", "status"], True),
    (["qemu-system-x86_64", "-m", "2G"], True),
    (["qemu-system-aarch64"], True),
    (["kubectl", "get", "pods"], True),
    (["bash", "/home/op/gen/tests/qemu/run-qemu-docker.sh", "--artifacts", "x"], True),
    (["bash", "-c", "make view"], True),
    (["bash", "-lc", "docker ps"], True),
    (["./build-x86-host-stage4.sh", "-w", "out"], True),
    (["/home/op/gen/scripts/flash-disk.sh"], True),
    # stays in the sandbox
    (["bash", "-n", "/home/op/gen/scripts/x.sh"], False),   # a syntax check runs nothing
    (["bash", "/app/lib/python3.13/site-packages/hugmesh_studio/core/_roles-lib.sh"], False),
    (["bash", "-c", "source /app/lib/x.sh; f"], False),
    ([sys.executable, "-m", "hugmesh_studio", "--askpass"], False),
    (["python3", "-c", "print(1)"], False),
    (["flatpak-spawn", "--host", "true"], False),
    (["xdg-open", "https://example.org"], False),            # the portal handles it
    (["/usr/bin/env"], False),
    ([], False),
])
def test_runs_on_host(argv, host):
    assert flatpak_host.runs_on_host(argv) is host


def test_every_tool_the_studio_probes_for_is_routed_to_the_host():
    """Derived from the source: each ``shutil.which("<name>")`` the Studio makes is a
    host tool (or one of the two the sandbox itself provides), so a probe added later
    for a new tool cannot silently look inside the sandbox and report it missing."""
    sandbox_provides = {"bash": "the generator scripts are routed by their path instead",
                        "python3": "the Studio's own interpreter",
                        "wslpath": "WSL only, never inside a Flatpak",
                        "explorer.exe": "WSL only, never inside a Flatpak"}
    probed: dict[str, str] = {}
    for directory, _dirs, files in os.walk(PACKAGE):
        for name in files:
            if not name.endswith(".py"):
                continue
            path = os.path.join(directory, name)
            with open(path, encoding="utf-8") as fh:
                tree = ast.parse(fh.read())
            for node in ast.walk(tree):
                if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                        and node.func.attr == "which" and node.args
                        and isinstance(node.args[0], ast.Constant)
                        and isinstance(node.args[0].value, str)):
                    probed.setdefault(node.args[0].value, f"{name}:{node.lineno}")
    assert {"docker", "make", "git", "kubectl"} <= set(probed), (
        f"test premise: the scan found the Studio's probes ({sorted(probed)})")
    stray = {tool: where for tool, where in probed.items()
             if tool not in sandbox_provides and not flatpak_host._matches_host_tool(tool)}
    assert not stray, (f"the Studio probes for {stray}, which flatpak_host.HOST_TOOLS does "
                       "not route to the host: inside the Flatpak the probe would say "
                       "'not installed' on a host that has it")


def test_host_env_drops_what_only_describes_the_sandbox():
    env = {"PATH": "/app/bin:/usr/bin", "PYTHONPATH": "/app/lib", "LD_LIBRARY_PATH": "/app",
           "XDG_DATA_HOME": "/home/op/.var/app/x/data", "FLATPAK_ID": "org.x",
           "HOME": "/home/op", "DOCKER_HOST": "unix:///run/docker.sock", "SECRET": "s"}
    assert flatpak_host.host_env(env) == {"HOME": "/home/op",
                                          "DOCKER_HOST": "unix:///run/docker.sock",
                                          "SECRET": "s"}


def test_host_argv_carries_the_directory_and_extra_path_entries():
    argv = flatpak_host.host_argv(["kind", "get", "clusters"], cwd="/home/op/gen", env_fd=7,
                                  forward_fds=(9,),
                                  env={"PATH": "/app/bin:/usr/bin:/home/op/tools/bin"})
    assert argv[:5] == ["flatpak-spawn", "--host", "--directory=/home/op/gen",
                        "--env-fd=7", "--forward-fd=9"]
    assert argv[5:9] == ["sh", "-c", 'PATH="$0:$PATH"; exec "$@"', "/home/op/tools/bin"]
    assert argv[9:] == ["kind", "get", "clusters"]
    plain = flatpak_host.host_argv(["docker", "info"], cwd="/x", env={"PATH": "/usr/bin"})
    assert plain == ["flatpak-spawn", "--host", "--directory=/x", "docker", "info"]


# ---------------------------------------------------------------------------------------
# The hook, run for real against a stand-in flatpak-spawn
# ---------------------------------------------------------------------------------------
_FAKE_SPAWN = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
record = {"argv": args, "env_fd": None, "env": None, "directory": None}
while args and args[0].startswith("--"):
    opt = args.pop(0)
    if opt.startswith("--env-fd="):
        fd = int(opt.split("=", 1)[1])
        data = os.read(fd, 1 << 20)
        record["env"] = dict(item.decode().split("=", 1) for item in data.split(b"\0") if item)
    elif opt.startswith("--directory="):
        record["directory"] = opt.split("=", 1)[1]
with open(os.environ["FAKE_SPAWN_LOG"], "a") as fh:
    fh.write(json.dumps(record) + "\n")
if args == ["true"]:
    sys.exit(int(os.environ.get("FAKE_SPAWN_TRUE_EXIT", "0")))
os.chdir(record["directory"] or ".")
env = dict(record["env"] or {})
env["PATH"] = os.environ["FAKE_HOST_PATH"]
os.execvpe(args[0], args, env)
'''


@pytest.fixture
def sandbox(tmp_path, monkeypatch):
    """A pretend Flatpak: /.flatpak-info stand-in, a flatpak-spawn on PATH, a HOME."""
    info = tmp_path / "flatpak-info"
    info.write_text("[Application]\nname=org.hugmesh.ImageStudio\n")
    bin_dir = tmp_path / "sandbox-bin"
    bin_dir.mkdir()
    spawn = bin_dir / "flatpak-spawn"
    spawn.write_text(_FAKE_SPAWN.replace("/usr/bin/env python3", sys.executable))
    spawn.chmod(0o755)
    host_bin = tmp_path / "host-bin"
    host_bin.mkdir()
    docker = host_bin / "docker"
    docker.write_text('#!/bin/sh\necho "docker $* from $PWD SECRET=$SECRET"\n')
    docker.chmod(0o755)
    log = tmp_path / "spawn.log"
    monkeypatch.setenv("FAKE_SPAWN_LOG", str(log))
    (host_bin / "sh").symlink_to(shutil.which("sh"))   # the pretend host has sh, docker
    monkeypatch.setenv("FAKE_HOST_PATH", str(host_bin))
    monkeypatch.setenv("PATH", f"{bin_dir}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.setenv("TMPDIR", os.environ.get("TMPDIR", "/tmp"))
    assert flatpak_host.install(info_path=str(info))
    try:
        yield {"log": log, "host_bin": host_bin, "tmp": tmp_path}
    finally:
        flatpak_host.uninstall()
        import tempfile
        tempfile.tempdir = None


def _records(log):
    return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []


@needs_posix
def test_a_host_tool_crosses_with_its_directory_and_environment(sandbox, tmp_path):
    workdir = tmp_path / "gen"
    workdir.mkdir()
    env = dict(os.environ, SECRET="not on any command line", PYTHONPATH="/app/lib")
    result = subprocess.run(["docker", "info"], cwd=str(workdir), env=env,
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == f"docker info from {workdir} SECRET=not on any command line"
    (record,) = _records(sandbox["log"])
    assert record["directory"] == str(workdir)
    assert record["env"]["SECRET"] == "not on any command line"
    assert "PYTHONPATH" not in record["env"]
    # the environment travels through the descriptor, never the host command line
    assert not any("not on any command line" in a for a in record["argv"]), record["argv"]


@needs_posix
def test_the_studios_own_python_stays_in_the_sandbox(sandbox):
    result = subprocess.run([sys.executable, "-c", "print('here')"], capture_output=True,
                            text=True)
    assert result.stdout.strip() == "here"
    assert _records(sandbox["log"]) == []


@needs_posix
def test_which_answers_from_the_host(sandbox):
    assert shutil.which("docker") == str(sandbox["host_bin"] / "docker")
    assert shutil.which("kubectl") is None          # not on the pretend host
    assert shutil.which("sh") is not None           # not a host tool: the sandbox answers


@needs_posix
def test_temp_files_go_where_the_host_can_see_them(sandbox, tmp_path):
    import tempfile
    path = tempfile.mkstemp()[1]
    try:
        assert path.startswith(str(tmp_path / "home" / ".cache" / "hugmesh-studio" / "tmp"))
    finally:
        os.unlink(path)


@needs_posix
def test_bridge_status_names_why_the_host_cannot_be_reached(sandbox, monkeypatch):
    assert flatpak_host.bridge_status(refresh=True) == (True, "")
    monkeypatch.setenv("FAKE_SPAWN_TRUE_EXIT", "1")
    ok, why = flatpak_host.bridge_status(refresh=True)
    assert not ok and why == "exit 1"


def test_nothing_is_hooked_outside_a_flatpak(tmp_path):
    before = (subprocess.Popen.__init__, shutil.which)
    assert flatpak_host.install(info_path=str(tmp_path / "no-such-file")) is False
    assert (subprocess.Popen.__init__, shutil.which) == before


# ---------------------------------------------------------------------------------------
# What the Studio says inside the sandbox
# ---------------------------------------------------------------------------------------
def _host(**kw) -> HostInfo:
    base = dict(os="linux", is_gentoo=True, has_docker=True, has_bash=True, has_kvm=True,
                is_root=False, builder_image="hugmesh-builder", docker_state="ok",
                in_flatpak=True)
    base.update(kw)
    return HostInfo(**base)


def test_a_gentoo_host_seen_from_the_flatpak_builds_with_docker():
    host = _host()
    assert host.can_build_native is False
    assert host.default_backend == "docker"
    assert "Flatpak" in host.summary()
    assert host.can_flash_devices is False
    assert "Flatpak sandbox" in host.flash_blocker()


def test_the_remedy_says_which_half_is_missing():
    bridge = _host(has_docker=False, docker_state="missing",
                   host_bridge_error="org.freedesktop.Flatpak was not provided")
    assert "Flatpak session helper" in bridge.docker_remedy()
    assert "org.freedesktop.Flatpak was not provided" in bridge.docker_remedy()
    assert "Flatpak session helper" in _host(has_kvm=False, host_bridge_error="x").kvm_blocker()
    missing = _host(has_docker=False, docker_state="missing")
    assert "not installed on this computer" in missing.docker_remedy()
    assert "Docker Desktop" not in missing.docker_remedy()
    down = _host(has_docker=False, docker_state="down")
    assert "systemctl start docker" in down.docker_remedy()


def test_detect_reads_the_host_through_the_bridge(monkeypatch, tmp_path):
    release = tmp_path / "os-release"
    release.write_text("NAME='Gentoo'\nID='gentoo'\n")
    monkeypatch.setattr(flatpak_host, "in_flatpak", lambda *a, **k: True)
    monkeypatch.setattr(flatpak_host, "bridge_status", lambda **k: (True, ""))
    monkeypatch.setattr(flatpak_host, "host_kvm_state", lambda **k: (True, False))
    monkeypatch.setattr(flatpak_host, "HOST_OS_RELEASE", str(release))
    monkeypatch.setattr(flatpak_host.host_os_release, "__defaults__", (str(release),))
    monkeypatch.setattr(platform_info, "docker_probe", lambda *a, **k: platform_info.DOCKER_OK)
    monkeypatch.setattr(platform_info.platform, "system", lambda: "Linux")
    host = platform_info.detect()
    assert (host.in_flatpak, host.is_gentoo, host.has_kvm, host.has_docker) == (
        True, True, True, True)
    assert host.default_backend == "docker"

    monkeypatch.setattr(flatpak_host, "bridge_status", lambda **k: (False, "no helper"))
    host = platform_info.detect()
    assert host.host_bridge_error == "no helper" and not host.has_docker and not host.has_kvm
    assert host.default_backend == "none"

"""core/macos_host.py: the PATH a Finder-launched app needs, and the probes a Mac answers.

The fixture text below is what the hosted macOS runners actually printed (captured by
the "Record the host facts" step of the ``macos`` job in studio-tests.yml, 2026-11-11:
macOS 15.8 on a virtual Apple M1 and 15.7 on an Intel i7), not a recollection of it:

* ``sysctl -n hw.optional.arm64`` -> "1" on Apple silicon, and on Intel the key does
  not exist: "sysctl: unknown oid 'hw.optional.arm64'", exit 1;
* ``sysctl -n kern.hv_support`` -> "1" on the Intel runner, and an unknown oid on the
  virtual M1 (a VM has no nested Hypervisor.framework);
* stock tools: ``sed --version`` -> "sed: illegal option -- -", exit 1; ``grep
  --version`` -> "grep (BSD grep, GNU compatible) 2.6.0-FreeBSD"; ``make --version`` ->
  "GNU Make 3.81"; ``bash`` is 3.2.57.
"""
from __future__ import annotations

import os
import subprocess
import sys
import types

import pytest

from hugmesh_studio.core import macos_host

on_a_mac = pytest.mark.skipif(sys.platform != "darwin", reason="needs a real Mac")


def _proc(rc, out=""):
    return types.SimpleNamespace(returncode=rc, stdout=out, stderr="")


# ── the PATH hook ───────────────────────────────────────────────────────────────────
def _dirs(*present):
    return lambda d: d in present


def test_path_additions_put_gnubin_first_then_brew_then_docker():
    present = ("/opt/homebrew/opt/coreutils/libexec/gnubin",
               "/opt/homebrew/opt/gnu-sed/libexec/gnubin",
               "/opt/homebrew/bin", "/usr/local/bin",
               "/Applications/Docker.app/Contents/Resources/bin",
               "/Users/op/.colima/bin")
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/op"}
    assert macos_host.path_additions(env, isdir=_dirs(*present)) == list(present)


def test_path_additions_skip_what_is_missing_or_already_there():
    env = {"PATH": "/opt/homebrew/bin:/usr/bin", "HOME": "/Users/op"}
    present = ("/opt/homebrew/bin", "/opt/homebrew/opt/grep/libexec/gnubin")
    assert macos_host.path_additions(env, isdir=_dirs(*present)) == [
        "/opt/homebrew/opt/grep/libexec/gnubin"]
    assert macos_host.path_additions({"PATH": "", "HOME": "/h"}, isdir=lambda d: False) == []


def test_install_prepends_on_a_mac_only_and_only_once():
    present = ("/opt/homebrew/bin", "/Users/op/.docker/bin")
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/op"}
    assert macos_host.install(env, sysplatform="linux", isdir=_dirs(*present)) == []
    assert env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin"
    added = macos_host.install(env, sysplatform="darwin", isdir=_dirs(*present))
    assert added == list(present)
    assert env["PATH"] == "/opt/homebrew/bin:/Users/op/.docker/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    assert macos_host.install(env, sysplatform="darwin", isdir=_dirs(*present)) == []
    assert env["PATH"].count("/opt/homebrew/bin") == 1
    empty = {"HOME": "/Users/op"}
    macos_host.install(empty, sysplatform="darwin", isdir=_dirs("/opt/homebrew/bin"))
    assert empty["PATH"] == "/opt/homebrew/bin"


def test_install_keeps_an_activated_venv_ahead_of_homebrew():
    """A Studio started from a checkout with its venv activated: Homebrew's python3
    must not shadow the venv's (first_run and org_export start `python3` by name), and
    Homebrew's GNU tools must still shadow the BSD ones in /usr/bin."""
    present = ("/opt/homebrew/opt/gnu-sed/libexec/gnubin", "/opt/homebrew/bin")
    env = {"PATH": "/Users/op/gen/studio/.venv/bin:/usr/bin:/bin:/usr/sbin:/sbin",
           "HOME": "/Users/op"}
    macos_host.install(env, sysplatform="darwin", isdir=_dirs(*present))
    parts = env["PATH"].split(":")
    assert parts[0] == "/Users/op/gen/studio/.venv/bin"
    assert parts.index("/opt/homebrew/opt/gnu-sed/libexec/gnubin") < parts.index("/usr/bin")
    assert parts.index("/opt/homebrew/bin") < parts.index("/usr/bin")
    # no system dir at all: appended, nothing the person chose is displaced
    env = {"PATH": "/a/bin:/b/bin", "HOME": "/Users/op"}
    macos_host.install(env, sysplatform="darwin", isdir=_dirs("/opt/homebrew/bin"))
    assert env["PATH"] == "/a/bin:/b/bin:/opt/homebrew/bin"


def test_app_main_installs_the_hook_before_anything_spawns():
    import inspect
    from hugmesh_studio import app
    from hugmesh_studio.core import entry
    src = inspect.getsource(app.main)
    # core/entry.bootstrap() IS macos_host.install(): the one call every entry (the
    # window, the text UI, each module command line) makes; tests/test_entry_bootstrap.py
    assert "macos_host.install()" in inspect.getsource(entry.bootstrap)
    assert src.index("entry.bootstrap()") < src.index("ap = argparse.ArgumentParser")
    assert src.index("flatpak_host.install()") < src.index("entry.bootstrap()")


@on_a_mac
def test_on_a_mac_every_added_directory_exists():
    for d in macos_host.path_additions():
        assert os.path.isdir(d), d


# ── the GNU userland ────────────────────────────────────────────────────────────────
def _stock_mac(argv, **_):
    """macOS 15's own tools, as the runners printed them."""
    exe, *args = argv
    name = os.path.basename(exe)
    if name == "bash":
        return _proc(0, "3\n")
    if name in ("sed", "stat", "find"):
        return _proc(1, f"{name}: illegal option -- -\n")
    if name == "grep":
        return _proc(0, "grep (BSD grep, GNU compatible) 2.6.0-FreeBSD\n")
    if name == "make":
        return _proc(0, "GNU Make 3.81\n")
    raise AssertionError(argv)


def _gnu_mac(argv, **_):
    exe, *args = argv
    name = os.path.basename(exe)
    return _proc(0, {"bash": "5\n", "sed": "sed (GNU sed) 4.9\n",
                     "stat": "stat (GNU coreutils) 9.7\n", "find": "find (GNU findutils) 4.10.0\n",
                     "grep": "grep (GNU grep) 3.12\n", "make": "GNU Make 4.4.1\n"}[name])


def _which(name):
    return f"/usr/bin/{name}"


def test_a_stock_mac_misses_bash_4_and_four_gnu_formulae():
    assert macos_host.gnu_userland_missing(which=_which, run=_stock_mac) == [
        "bash", "gnu-sed", "coreutils", "findutils", "grep"]


def test_a_mac_with_homebrews_gnu_tools_misses_nothing():
    assert macos_host.gnu_userland_missing(which=_which, run=_gnu_mac) == []


def test_a_tool_that_is_not_on_path_at_all_is_missing():
    which = lambda name: None if name in ("bash", "make") else _which(name)  # noqa: E731
    assert macos_host.gnu_userland_missing(which=which, run=_gnu_mac) == ["bash", "make"]


def test_a_probe_that_cannot_start_counts_as_missing():
    def boom(argv, **_):
        raise OSError("exec format error")
    assert macos_host.gnu_userland_missing(which=_which, run=boom) == [
        "bash", "gnu-sed", "coreutils", "findutils", "grep", "make"]


def test_the_brew_line_installs_every_formula_the_probe_can_report():
    formulae = {f for _n, _a, _b, f in macos_host.GNU_TOOLS} | {"bash"}
    assert set(macos_host.BREW_INSTALL.split()[2:]) == formulae
    assert set(macos_host.GNUBIN_FORMULAE) <= formulae


# ── sysctl facts ────────────────────────────────────────────────────────────────────
def _sysctl(answers):
    def run(argv, **_):
        assert argv[:2] == ["sysctl", "-n"], argv
        if argv[2] in answers:
            return _proc(0, answers[argv[2]] + "\n")
        return types.SimpleNamespace(returncode=1, stdout="",
                                     stderr=f"sysctl: unknown oid '{argv[2]}'\n")
    return run


def test_mac_arch_asks_the_kernel():
    assert macos_host.mac_arch(_sysctl({"hw.optional.arm64": "1"})) == "arm64"
    assert macos_host.mac_arch(_sysctl({})) == "x86_64"          # the Intel runner
    assert macos_host.mac_arch(_sysctl({"hw.optional.arm64": "0"})) == "x86_64"


def test_hvf_needs_kern_hv_support():
    assert macos_host.hvf_available(_sysctl({"kern.hv_support": "1"})) is True
    assert macos_host.hvf_available(_sysctl({})) is False        # the virtual M1 runner
    assert macos_host.host_memory_bytes(_sysctl({"hw.memsize": "15032385536"})) == 15032385536
    assert macos_host.host_memory_bytes(_sysctl({})) == 0


@on_a_mac
def test_on_a_mac_the_probes_agree_with_the_kernel():
    import platform
    assert macos_host.mac_arch() == ("arm64" if platform.machine() == "arm64" else "x86_64")
    hv = subprocess.run(["sysctl", "-n", "kern.hv_support"], capture_output=True, text=True)
    assert macos_host.hvf_available() == (hv.returncode == 0 and hv.stdout.strip() == "1")
    assert macos_host.host_memory_bytes() > 2**30


# ── the Docker VM ───────────────────────────────────────────────────────────────────
def _docker(context, info, info_rc=0):
    def run(argv, **_):
        if argv[1:3] == ["info", "--format"]:
            return _proc(info_rc, info + "\n")
        if argv[1:3] == ["context", "show"]:
            return _proc(0, context + "\n")
        raise AssertionError(argv)
    return run


@pytest.mark.parametrize("context, osname, runtime", [
    ("desktop-linux", "Docker Desktop", "docker-desktop"),
    ("colima", "Ubuntu 24.04.1 LTS", "colima"),
    ("colima-x86", "Ubuntu 24.04.1 LTS", "colima"),
    ("orbstack", "OrbStack", "orbstack"),
    ("default", "Docker Desktop", "docker-desktop"),
    ("default", "Ubuntu 22.04", "other"),
])
def test_docker_vm_names_the_runtime_and_its_size(context, osname, runtime):
    vm = macos_host.docker_vm(which=_which, run=_docker(context, f"{osname}|8217206784|4"))
    assert vm == macos_host.DockerVM(runtime, context, 8217206784, 4)


def test_docker_vm_is_empty_without_an_answering_docker():
    assert macos_host.docker_vm(which=lambda n: None) == macos_host.DockerVM()
    assert macos_host.docker_vm(which=_which, run=_docker("x", "", info_rc=1)) == macos_host.DockerVM()


# ── terminals ───────────────────────────────────────────────────────────────────────
def test_terminal_app_prefers_iterm_when_installed():
    assert macos_host.terminal_app(_dirs("/Applications/iTerm.app",
                                         "/System/Applications/Utilities/Terminal.app")) == "iTerm"
    assert macos_host.terminal_app(_dirs("/System/Applications/Utilities/Terminal.app")) == "Terminal"
    assert macos_host.terminal_app(lambda d: False) == "Terminal"
    both = _dirs("/Applications/iTerm.app", "/System/Applications/Utilities/Terminal.app")
    assert macos_host.terminal_app(both, prefer="Terminal") == "Terminal"


@on_a_mac
def test_on_a_mac_terminal_app_is_where_the_studio_looks():
    assert os.path.isdir(dict(macos_host.TERMINAL_APPS)["Terminal"])


def test_the_command_file_is_private_and_carries_only_the_allowlisted_env(tmp_path):
    env = {"PATH": "/opt/homebrew/bin:/usr/bin:/bin", "GH_TOKEN": "ghp_secret",
           "DOCKER_HOST": "unix:///Users/op/.colima/default/docker.sock", "LANG": "en_US.UTF-8"}
    argv = macos_host.terminal_argv(["ssh", "-t", "hugmesh@127.0.0.1", "echo it's"],
                                    state_dir=str(tmp_path), cwd="/Users/op/My Gen",
                                    title="device login", environ=env,
                                    isdir=_dirs("/System/Applications/Utilities/Terminal.app"))
    assert argv[:3] == ["open", "-a", "Terminal"] and argv[3].endswith(".command")
    path = argv[3]
    assert os.path.dirname(path) == str(tmp_path / "term")
    assert oct(os.stat(path).st_mode & 0o777) == "0o700"
    text = open(path, encoding="utf-8").read()
    assert text.startswith("#!/bin/bash\nrm -f ")
    assert "export PATH=/opt/homebrew/bin:/usr/bin:/bin" in text
    assert "export DOCKER_HOST=" in text and "export LANG=en_US.UTF-8" in text
    assert "ghp_secret" not in text and "GH_TOKEN" not in text
    assert "cd '/Users/op/My Gen' || exit 1" in text
    assert "ssh -t hugmesh@127.0.0.1 'echo it'\"'\"'s'" in text
    assert 'read -r -p "press Enter to close..."' in text


def test_the_command_file_runs_its_argv_and_deletes_itself(tmp_path):
    """Executed for real (bash; /bin/bash 3.2 on a Mac): it changes directory, exports
    what it was given, runs the argv with its quoting intact and removes the file."""
    work = tmp_path / "w d"
    work.mkdir()
    marker = tmp_path / "out.txt"
    argv = macos_host.terminal_argv(
        ["bash", "-c", f'printf "%s|%s|%s" "$PWD" "$1" "$LANG" > {marker}', "x", "a b'c"],
        state_dir=str(tmp_path / "state"), cwd=str(work), environ={"LANG": "C.UTF-8"},
        hold=False)
    proc = subprocess.run(["bash", argv[3]], capture_output=True, text=True, timeout=30,
                          stdin=subprocess.DEVNULL)
    assert proc.returncode == 0, proc.stderr
    assert marker.read_text() == f"{work}|a b'c|C.UTF-8"
    assert not os.path.exists(argv[3]), "the .command file outlived its run"


def test_wrap_in_terminal_is_none_off_a_mac(tmp_path):
    assert macos_host.wrap_in_terminal(["true"], sysplatform="linux", state_dir=str(tmp_path)) is None
    argv = macos_host.wrap_in_terminal(["true"], sysplatform="darwin", state_dir=str(tmp_path),
                                       isdir=lambda d: False)
    assert argv[:3] == ["open", "-a", "Terminal"]


@on_a_mac
def test_on_a_mac_open_runs_the_command_file_in_terminal(tmp_path):
    """The whole terminal route on a real Mac: `open -a Terminal x.command` starts it,
    the argv runs, and the file is gone."""
    import time
    marker = tmp_path / "ran.txt"
    argv = macos_host.terminal_argv(["bash", "-c", f"echo ran > {marker}; exit"],
                                    state_dir=str(tmp_path / "state"), hold=False,
                                    app="Terminal")
    subprocess.run(argv, check=True, timeout=60)
    deadline = time.time() + 60
    while time.time() < deadline and not marker.exists():
        time.sleep(1)
    assert marker.exists() and marker.read_text().strip() == "ran"
    assert not os.path.exists(argv[3])

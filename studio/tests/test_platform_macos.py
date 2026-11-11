"""macOS as a Studio host: platform_info's darwin answers, and the drivers that ask them.

A Mac has ``os.name == "posix"``, so before this every gate that asked
``os.name == "nt"`` sent it down the LINUX branch: a "native" backend offered (sudo +
a Gentoo chroot that macOS cannot do), "needs Linux block devices; this is darwin",
"Install Docker Desktop and start it" for a colima user, no window session at all (so
no askpass dialog), and every bash verb let through to die on a BSD flag.

Everything here injects ``sysplatform="darwin"`` (or a darwin ``HostInfo``) and runs
the same on Linux and on a Mac; the ``macos`` job of studio-tests.yml runs this file on
real Apple-silicon and Intel Macs. The few checks that only mean something ON a Mac
(the filesystem really folds case, the remedy's diskutil/plutil pipeline really works)
are marked and skip elsewhere.
"""
from __future__ import annotations

import os
import shlex
import subprocess
import sys
import types

import pytest

from hugmesh_studio import app
from hugmesh_studio.core import (build_driver, cross_dracut, fleet, macos_host,
                                 platform_info, self_check)
from hugmesh_studio.core.build_driver import BuildDriver, askpass_helper_body
from hugmesh_studio.core.config import ImageConfig
from hugmesh_studio.core.platform_info import (DOCKER_DOWN, DOCKER_MISSING, DOCKER_OK,
                                               DOCKER_TIMEOUT, SESSION_COCOA, SESSION_NONE,
                                               SESSION_X11, HostInfo)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
on_a_mac = pytest.mark.skipif(sys.platform != "darwin", reason="needs a real Mac")


def mac(**over) -> HostInfo:
    base = dict(os="darwin", is_gentoo=False, has_docker=True, has_bash=True, has_kvm=False,
                is_root=False, builder_image="hugmesh-builder", session=SESSION_COCOA,
                mac_arch="arm64", has_hvf=True, docker_runtime="colima",
                docker_vm_mem=8 * 2**30, docker_vm_cpus=4, docker_state=DOCKER_OK)
    base.update(over)
    return HostInfo(**base)


LINUX = HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True, has_kvm=True,
                 is_root=False, builder_image="hugmesh-builder")


# ── the one question ────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("osname, sysplatform, kind", [
    ("nt", "win32", "windows"), ("nt", "darwin", "windows"),
    ("posix", "darwin", "darwin"), ("posix", "linux", "linux"),
])
def test_host_kind_tells_a_mac_from_linux(osname, sysplatform, kind):
    assert platform_info.host_kind(osname, sysplatform) == kind
    assert platform_info.builds_in_docker_vm(osname, sysplatform) == (kind != "linux")


# ── the window session ──────────────────────────────────────────────────────────────
def test_a_mac_has_a_cocoa_session_unless_it_is_reached_over_ssh():
    assert platform_info.detect_session("darwin", {}) == SESSION_COCOA
    assert platform_info.detect_session("darwin", {"DISPLAY": ":0"}) == SESSION_COCOA
    for ssh in ({"SSH_CONNECTION": "10.0.0.2 5 10.0.0.1 22"}, {"SSH_TTY": "/dev/ttys001"}):
        assert platform_info.detect_session("darwin", ssh) == SESSION_NONE
    # Linux is untouched by the darwin branch
    assert platform_info.detect_session("linux", {"DISPLAY": ":0"}) == SESSION_X11
    assert platform_info.detect_session("linux", {}) == SESSION_NONE


def test_cocoa_counts_as_a_gui_and_is_not_wayland():
    host = mac()
    assert host.has_gui and not host.is_wayland and host.is_macos
    assert not mac(session=SESSION_NONE).has_gui


def test_the_askpass_dialog_is_allowed_on_a_mac(monkeypatch):
    from hugmesh_studio.core import askpass
    monkeypatch.setattr(platform_info, "detect_session", lambda *a, **k: SESSION_COCOA)
    assert askpass._display_available()


# ── backends and builds ─────────────────────────────────────────────────────────────
def test_a_mac_never_builds_natively():
    assert not mac().can_build_native
    assert mac().default_backend == "docker"
    assert mac(has_docker=False).default_backend == "none"


def test_print_backend_prints_the_docker_command_on_a_mac_that_cannot_build():
    assert app.print_backend("auto", "none", osname="posix", sysplatform="darwin") == "docker"
    assert app.print_backend("auto", "none", osname="posix", sysplatform="linux") == "native"
    assert app.print_backend("native", "none", osname="posix", sysplatform="darwin") == "native"


def test_an_explicit_native_print_says_why_on_a_mac(capsys):
    app._native_print_note("native", osname="posix", sysplatform="darwin")
    err = capsys.readouterr().err
    assert err.startswith("note: A native build runs a Gentoo chroot") and "docker backend" in err
    app._native_print_note("native", osname="posix", sysplatform="linux")
    assert capsys.readouterr().err == ""


def test_the_native_backend_is_refused_on_a_mac_even_with_sudo(tmp_path):
    driver = BuildDriver(str(tmp_path), mac())
    driver._can_elevate = lambda: True          # macOS has sudo
    problems = driver.preflight(ImageConfig(), "native")
    said = [p for p in problems if "A native build" in p]
    assert said and "only a Linux host" in said[0] and "docker backend" in said[0], problems
    assert not any("elevation helper" in p for p in problems)


def test_the_native_fleet_backend_is_refused_on_a_mac():
    problems = fleet.FleetDriver(GENERATOR_DIR, mac()).preflight(fleet.FleetConfig(), "native")
    said = [p for p in problems if "native fleet build" in p]
    assert len(said) == 1 and "docker backend" in said[0], problems
    assert not any("needs root" in p for p in problems), problems


def test_native_build_blocker_follows_the_hosts_os():
    assert platform_info.native_build_blocker(host_os="linux", osname="posix",
                                              sysplatform="linux") == ""
    assert "Windows" in platform_info.native_build_blocker(host_os="windows")
    assert "Gentoo chroot" in platform_info.native_build_blocker(host_os="darwin")
    assert "Gentoo chroot" in platform_info.native_build_blocker(osname="posix",
                                                                 sysplatform="darwin")


def _docker_argv(host, tmp_path):
    cfg = ImageConfig()
    driver = BuildDriver(GENERATOR_DIR, host, workdir=str(tmp_path / "out"))
    return driver.command(cfg, "docker"), driver.builder_image_build_command()


def test_apple_silicon_runs_the_x86_64_builder_as_linux_amd64(tmp_path):
    run, build = _docker_argv(mac(mac_arch="arm64"), tmp_path)
    assert run[:6] == ["docker", "run", "--rm", "--privileged", "--platform", "linux/amd64"]
    assert build[:4] == ["docker", "build", "--platform", "linux/amd64"]
    for host in (mac(mac_arch="x86_64"), LINUX):
        run, build = _docker_argv(host, tmp_path)
        assert "--platform" not in run and "--platform" not in build, host.os
    fl = fleet.FleetDriver(GENERATOR_DIR, mac(mac_arch="arm64"))
    argv = fl.command(fleet.FleetConfig(), "docker")
    assert argv[4:6] == ["--platform", "linux/amd64"], argv[:8]


def test_a_case_folding_output_dir_blocks_a_mac_build(tmp_path, monkeypatch):
    out = tmp_path / "out"
    driver = BuildDriver(GENERATOR_DIR, mac(), workdir=str(out))
    monkeypatch.setattr(platform_info, "folds_case", lambda path: True)
    problems = driver.preflight(ImageConfig(), "docker")
    said = [p for p in problems if "ignores case" in p]
    assert said and str(out) in said[0] and "diskutil apfs addVolume" in said[0], problems
    assert "APFSContainerReference" in said[0] and "Case-sensitive APFS" in said[0]
    for answer in (False, None):
        monkeypatch.setattr(platform_info, "folds_case", lambda path, a=answer: a)
        assert not any("ignores case" in p for p in driver.preflight(ImageConfig(), "docker"))
    # never on Linux, whatever the filesystem says
    monkeypatch.setattr(platform_info, "folds_case", lambda path: True)
    linux = BuildDriver(GENERATOR_DIR, LINUX, workdir=str(out))
    assert not any("ignores case" in p for p in linux.preflight(ImageConfig(), "docker"))


def test_a_mac_build_is_called_experimental_and_sized_for_its_vm(tmp_path):
    warnings = BuildDriver(GENERATOR_DIR, mac(), workdir=str(tmp_path)).preflight_warnings(
        ImageConfig(), "docker")
    joined = "\n".join(warnings)
    assert "EXPERIMENTAL" in joined
    assert "x86_64 emulation" in joined                  # arm64
    assert "8.0 GiB of memory" in joined                 # an 8 GiB VM
    big_intel = mac(mac_arch="x86_64", docker_vm_mem=32 * 2**30)
    joined = "\n".join(BuildDriver(GENERATOR_DIR, big_intel, workdir=str(tmp_path))
                       .preflight_warnings(ImageConfig(), "docker"))
    assert "EXPERIMENTAL" in joined and "emulation" not in joined and "GiB of memory" not in joined
    linux = BuildDriver(GENERATOR_DIR, LINUX, workdir=str(tmp_path))
    assert "EXPERIMENTAL" not in "\n".join(linux.preflight_warnings(ImageConfig(), "docker"))


def test_folds_case_asks_the_filesystem(tmp_path):
    if sys.platform == "darwin":
        pytest.skip("the runner's APFS volume folds case; see the on_a_mac test")
    assert platform_info.folds_case(str(tmp_path)) is False
    # a path that does not exist yet is judged by its nearest existing parent
    assert platform_info.folds_case(str(tmp_path / "a" / "b")) is False
    assert not list(tmp_path.iterdir()), "the probe file was left behind"


def test_folds_case_is_none_when_nothing_can_be_written(tmp_path):
    if os.geteuid() == 0:
        pytest.skip("root writes anywhere")
    locked = tmp_path / "locked"
    locked.mkdir()
    locked.chmod(0o500)
    try:
        assert platform_info.folds_case(str(locked)) is None
    finally:
        locked.chmod(0o700)


@on_a_mac
def test_on_a_mac_the_default_volume_folds_case_and_the_remedy_names_its_container(tmp_path):
    """Both halves of the work-dir refusal, measured on the runner: APFS's default
    really ignores case, and the remedy's command substitution really prints the boot
    volume's APFS container (disk3, disk1, …) for `diskutil apfs addVolume`."""
    assert platform_info.folds_case(str(tmp_path)) is True
    out = subprocess.run(["bash", "-c", "diskutil info -plist / | plutil -extract "
                          "APFSContainerReference raw -"], capture_output=True, text=True)
    assert out.returncode == 0 and out.stdout.strip().startswith("disk"), out


# ── docker, KVM, flashing: the darwin remedies ──────────────────────────────────────
def test_the_docker_remedy_names_every_mac_runtime_and_sizes_the_vm():
    text = mac(has_docker=False, docker_state=DOCKER_MISSING).docker_remedy()
    for word in ("Docker Desktop", "colima", "OrbStack", "16 GB", "200 GB", "Rosetta"):
        assert word in text, word
    assert "systemctl" not in text and "usermod" not in text
    intel = mac(has_docker=False, docker_state=DOCKER_MISSING, mac_arch="x86_64").docker_remedy()
    assert "Rosetta" not in intel and "--arch x86_64" in intel
    assert "no engine answers" in mac(has_docker=False, docker_state=DOCKER_DOWN).docker_remedy()
    assert "in time" in mac(has_docker=False, docker_state=DOCKER_TIMEOUT).docker_remedy()
    assert mac().docker_remedy() == ""
    blocker = mac(has_docker=False, docker_state=DOCKER_DOWN).docker_blocker()
    assert blocker.startswith("The Docker daemon is not reachable") and "colima start" in blocker


def test_the_kvm_note_on_a_mac_says_tcg_and_hvf():
    text = mac(mac_arch="arm64", has_hvf=True).kvm_blocker()
    assert "no /dev/kvm" in text and "TCG" in text and "Apple silicon" in text
    assert "Hypervisor.framework is available" in text
    assert "kvm_intel" not in text and "Linux kernel feature" not in text
    text = mac(mac_arch="x86_64", has_hvf=False).kvm_blocker()
    assert "Apple silicon" not in text and "not available" in text


def test_flashing_on_a_mac_is_refused_with_the_commands_to_do_it_by_hand():
    host = mac()
    assert not host.can_flash_devices
    text = host.flash_blocker()
    assert "diskutil list external physical" in text and "/dev/rdiskN" in text
    assert "diskutil unmountDisk" in text and "diskutil eject" in text
    assert "/dev/disk0 is the Mac's own disk" in text
    assert "needs Linux block devices; this is darwin" not in text


def test_the_summary_line_of_a_mac():
    assert mac().summary() == "OS=darwin · arm64 · cocoa · docker(colima, 8 GiB VM) · HVF"
    assert "no-GNU-userland" in mac(gnu_missing=("bash",)).summary()
    assert LINUX.summary() == "OS=linux · Gentoo · docker · KVM"


# ── the bash verbs: a GNU userland or the brew line ─────────────────────────────────
def test_host_script_blocker_on_a_mac_names_what_is_missing_and_the_brew_line():
    said = platform_info.host_script_blocker("The local stack", sysplatform="darwin",
                                             gnu_missing=["bash", "gnu-sed", "grep"])
    assert said.startswith("The local stack runs `make` and bash scripts")
    assert "bash 4 or newer (macOS ships 3.2), gnu-sed, grep" in said
    assert macos_host.BREW_INSTALL in said
    assert platform_info.host_script_blocker("x", sysplatform="darwin", gnu_missing=[]) == ""
    assert platform_info.host_script_blocker("x", osname="posix", sysplatform="linux") == ""
    assert "WSL2" in platform_info.host_script_blocker("x", osname="nt")


def test_native_windows_blocker_now_also_answers_for_a_mac(monkeypatch):
    """Its ~45 call sites ask it before running a bash verb; on a Mac without the GNU
    tools they now get the brew line instead of a script that dies on a BSD flag."""
    monkeypatch.setattr(platform_info, "sys", types.SimpleNamespace(platform="darwin"))
    monkeypatch.setattr(platform_info, "_GNU_MISSING", ["findutils"])
    said = platform_info.native_windows_blocker("The e2e suite", osname="posix")
    assert said.startswith("The e2e suite runs") and "findutils" in said
    monkeypatch.setattr(platform_info, "_GNU_MISSING", [])
    assert platform_info.native_windows_blocker("The e2e suite", osname="posix") == ""


def test_the_gnu_probe_runs_once_per_process(monkeypatch):
    calls = []
    monkeypatch.setattr(platform_info, "_GNU_MISSING", None)
    monkeypatch.setattr(macos_host, "gnu_userland_missing",
                        lambda: calls.append(1) or ["grep"])
    assert platform_info._gnu_missing_cached() == ["grep"]
    assert platform_info._gnu_missing_cached() == ["grep"]
    assert calls == [1]


# ── detect() on a Mac ───────────────────────────────────────────────────────────────
def test_detect_fills_the_mac_fields(monkeypatch):
    monkeypatch.setattr(platform_info.platform, "system", lambda: "Darwin")
    monkeypatch.setattr(platform_info, "docker_probe", lambda *a, **k: DOCKER_OK)
    monkeypatch.setattr(platform_info, "_kvm_state", lambda: (False, False))
    monkeypatch.setattr(platform_info, "_GNU_MISSING", [])
    monkeypatch.setattr(platform_info, "detect_wsl", lambda: (False, 0))
    monkeypatch.setattr(macos_host, "mac_arch", lambda run=None: "arm64")
    monkeypatch.setattr(macos_host, "hvf_available", lambda run=None: True)
    monkeypatch.setattr(macos_host, "docker_vm", lambda which=None, run=None:
                        macos_host.DockerVM("docker-desktop", "desktop-linux", 16 * 2**30, 8))
    for k in ("SSH_CONNECTION", "SSH_TTY"):
        monkeypatch.delenv(k, raising=False)
    host = platform_info.detect()
    assert (host.os, host.mac_arch, host.has_hvf, host.docker_runtime) == (
        "darwin", "arm64", True, "docker-desktop")
    assert host.docker_vm_mem == 16 * 2**30 and host.docker_vm_cpus == 8
    assert host.session == SESSION_COCOA and host.gnu_missing == ()
    assert not host.is_gentoo and not host.in_flatpak
    assert host.default_backend == "docker" and host.needs_amd64_platform


# ── the cross-built FDE note, the askpass helper, the self-check ────────────────────
def test_the_cross_fde_note_on_a_mac_points_at_the_docker_vm():
    note = cross_dracut.cross_fde_note(["2"], ready=False, osname="posix", sysplatform="darwin")
    assert "Docker Desktop, colima or OrbStack" in note
    assert "NO usable qemu-aarch64" not in note
    linux = cross_dracut.cross_fde_note(["2"], ready=False, osname="posix", sysplatform="linux")
    assert "NO usable qemu-aarch64" in linux


def test_the_frozen_askpass_helper_runs_the_app_itself_not_python_dash_m():
    body = askpass_helper_body(frozen=True,
                               executable="/Applications/HugMesh Image Studio.app/Contents/"
                                          "MacOS/hugmesh-studio")
    last = body.strip().splitlines()[-1]
    assert last == ("exec '/Applications/HugMesh Image Studio.app/Contents/MacOS/"
                    "hugmesh-studio' --askpass-gui")
    assert "-m hugmesh_studio" not in body and "PYTHONPATH" not in body
    src = askpass_helper_body(frozen=False, executable="/usr/bin/python3")
    assert src.strip().splitlines()[-1] == "exec /usr/bin/python3 -m hugmesh_studio --askpass-gui"
    assert "export PYTHONPATH=" in src


def test_the_studio_refuses_dash_m_which_is_what_a_frozen_helper_used_to_pass():
    """The defect the frozen branch fixes: in a bundle sys.executable IS the Studio, and
    the Studio's own argument parser refuses "-m", so sudo -A got a usage error in place
    of a password. Shown with the real parser."""
    proc = subprocess.run([sys.executable, "-m", "hugmesh_studio", "-m", "hugmesh_studio",
                           "--askpass-gui"], capture_output=True, text=True, cwd=STUDIO_ROOT,
                          timeout=60, stdin=subprocess.DEVNULL)
    assert proc.returncode == 2 and "unrecognized arguments: -m hugmesh_studio" in proc.stderr


def test_the_generated_helper_is_the_frozen_one_when_frozen(monkeypatch, tmp_path):
    monkeypatch.setattr(build_driver, "_ASKPASS_PATH_CACHE", None)
    monkeypatch.delenv("SUDO_ASKPASS", raising=False)
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path))
    monkeypatch.setattr(build_driver.sys, "frozen", True, raising=False)
    monkeypatch.setattr(build_driver.sys, "executable", "/opt/hugmesh-studio/hugmesh-studio")
    path = build_driver._askpass_helper_path()
    text = open(path, encoding="utf-8").read()
    assert text.strip().endswith("exec /opt/hugmesh-studio/hugmesh-studio --askpass-gui")


def _mac_probe(missing, bash=5):
    return lambda: {"arch": "arm64", "gnu_missing": list(missing), "bash_major": bash,
                    "docker_runtime": "none", "docker_vm_mem": 0, "state_dir": "/x",
                    "state_dir_mode": "0o700"}


def test_the_self_check_on_a_stock_mac_refuses_and_does_not_parse_with_bash_3(monkeypatch):
    ran = []
    real = subprocess.run
    monkeypatch.setattr(self_check.subprocess, "run",
                        lambda argv, *a, **k: ran.append(argv) or real(argv, *a, **k))
    report = self_check.check(GENERATOR_DIR, sysplatform="darwin",
                              mac_probe=_mac_probe(["bash", "gnu-sed"], bash=3))
    assert report["macos"]["gnu_missing"] == ["bash", "gnu-sed"]
    said = [p for p in report["problems"] if "brew install" in p]
    assert len(said) == 1 and said[0].startswith("The generator runs bash scripts and make")
    assert report["scripts_parsed"] == 0 and report["scripts_skipped"] > 0
    assert not any(a[:2] == ["bash", "-n"] for a in ran), "parsed with macOS's bash 3.2"


def test_the_self_check_on_a_mac_with_the_gnu_tools_parses_and_passes():
    report = self_check.check(GENERATOR_DIR, sysplatform="darwin", mac_probe=_mac_probe([]))
    assert not [p for p in report["problems"] if "brew" in p]
    assert report["scripts_parsed"] > 0 and "scripts_skipped" not in report
    assert "macos" not in self_check.check(GENERATOR_DIR, sysplatform="linux")


def test_the_self_check_cli_prints_the_mac_line(monkeypatch, capsys):
    monkeypatch.setattr(self_check, "macos_report", _mac_probe([]))
    monkeypatch.setattr(self_check.platform_info, "host_kind", lambda *a, **k: "darwin")
    self_check.run_cli(GENERATOR_DIR)
    out = capsys.readouterr().out
    assert "macOS:         arm64, bash 5, GNU tools ok, docker none, state dir 0o700" in out


def test_a_frozen_self_check_says_it_could_not_list_the_paths(monkeypatch, capsys):
    from hugmesh_studio.core import generator_refs
    monkeypatch.setattr(self_check.sys, "frozen", True, raising=False)
    monkeypatch.setattr(generator_refs, "scan", lambda top: generator_refs.Refs())
    rc = self_check.run_cli(GENERATOR_DIR)
    out = capsys.readouterr().out
    assert rc == 0 and "carries no Python sources" in out


def test_macos_report_reads_the_probes(monkeypatch, tmp_path):
    monkeypatch.setattr(macos_host, "gnu_userland_missing", lambda which=None, run=None: [])
    monkeypatch.setattr(macos_host, "docker_vm", lambda which=None, run=None:
                        macos_host.DockerVM("orbstack", "orbstack", 2**33, 4))
    monkeypatch.setattr(macos_host, "mac_arch", lambda run=None: "x86_64")
    monkeypatch.setattr(macos_host, "bash_major", lambda which=None, run=None: 5)
    (tmp_path / "state").mkdir(mode=0o700)
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    r = self_check.macos_report()
    assert r == {"arch": "x86_64", "gnu_missing": [], "bash_major": 5,
                 "docker_runtime": "orbstack", "docker_vm_mem": 2**33,
                 "state_dir": str(tmp_path / "state"), "state_dir_mode": "0o700"}


def test_the_terminal_script_text_is_valid_for_bash_3():
    text = macos_host.command_script(["echo", "a b"], cwd="/tmp", title="t", environ={})
    proc = subprocess.run(["bash", "-n"], input=text, text=True, capture_output=True)
    assert proc.returncode == 0, proc.stderr
    assert shlex.join(["echo", "a b"]) in text

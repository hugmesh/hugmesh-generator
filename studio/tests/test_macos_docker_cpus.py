"""A Mac build's ``--cpus`` is held to what the Docker VM has, and says so.

On a Mac every build runs in the Linux VM of Docker Desktop, colima or OrbStack. That
VM has its own CPU count, set in the runtime's settings, and the colima line the Studio
itself recommends is ``--cpu 8``. The Studio's default CPU cap is "every core of this
machine but one" (resource_limits.default_cpus -> os.cpu_count()), counted from the
MAC. dockerd refuses to create a container that asks for more CPUs than it has:

    range of CPUs is from 0.01 to 8.00, as there are only 8 CPUs available

so a 12-core Mac got ``--cpus 11`` and a 10-core Mac ``--cpus 9`` on that VM, and every
build failed at container start, after dispatch, with nothing in the preflight. The
Studio already read the VM's count (``docker info`` NCPU -> HostInfo.docker_vm_cpus)
and did not use it.

Pinned here: the cap is lowered to the VM's count for the image build and the fleet
build, for the auto cap, a saved GUI limit and HUGMESH_CPUS alike; the preflight warns
with both numbers and names HUGMESH_CPUS; an unknown VM size or a small Mac changes
nothing; and a Linux or Windows host is never touched (its argv is byte-identical).

Memory has no such check on purpose: ``docker create --memory 9999g`` on a 31 GiB
engine succeeds (measured), so there is nothing for the daemon to refuse.

No Docker and no Mac needed: the host is a HostInfo, the Mac's core count an argument.
"""
from __future__ import annotations

import os

import pytest

from hugmesh_studio.core import build_driver, fleet, platform_info
from hugmesh_studio.core import resource_limits as rl
from hugmesh_studio.core.build_driver import BuildDriver
from hugmesh_studio.core.config import ImageConfig
from hugmesh_studio.core.platform_info import DOCKER_OK, SESSION_COCOA, HostInfo

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


def mac(vm_cpus: int, **over) -> HostInfo:
    base = dict(os="darwin", is_gentoo=False, has_docker=True, has_bash=True, has_kvm=False,
                is_root=False, builder_image="hugmesh-builder", session=SESSION_COCOA,
                mac_arch="arm64", has_hvf=True, docker_runtime="colima",
                docker_vm_mem=16 * 2**30, docker_vm_cpus=vm_cpus, docker_state=DOCKER_OK)
    base.update(over)
    return HostInfo(**base)


def host(os_name: str, **over) -> HostInfo:
    base = dict(os=os_name, is_gentoo=False, has_docker=True, has_bash=True, has_kvm=False,
                is_root=False, builder_image="hugmesh-builder")
    base.update(over)
    return HostInfo(**base)


@pytest.fixture
def cores(monkeypatch, tmp_path):
    """Set this machine's core count; no saved GUI limit, no env knob, and (as on a
    Mac) a build output folder that keeps case."""
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "config"))
    for knob in (rl.CPUS_ENV, rl.GPUS_ENV, rl.MEMORY_ENV):
        monkeypatch.delenv(knob, raising=False)
    monkeypatch.setattr(platform_info, "folds_case", lambda path: False)

    def _set(n: int) -> None:
        monkeypatch.setattr(rl.os, "cpu_count", lambda: n)
    return _set


def _cpus(argv: list[str]) -> str | None:
    return argv[argv.index("--cpus") + 1] if "--cpus" in argv else None


def _build_argv(h: HostInfo, tmp_path) -> list[str]:
    return BuildDriver(GENERATOR_DIR, h, workdir=str(tmp_path)).command(ImageConfig(), "docker")


def _fleet_argv(h: HostInfo, tmp_path) -> list[str]:
    drv = fleet.FleetDriver(GENERATOR_DIR, h)
    drv.workdir = str(tmp_path)
    return drv.command(fleet.FleetConfig(), "docker")


# ── the argv ────────────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("mac_cores, vm_cpus, expected", [
    (12, 8, "8"),      # the refuter's Mac: 11 was refused by an 8-CPU VM
    (10, 8, "8"),      # 9 was refused
    (8, 2, "2"),       # Docker Desktop's small default
    (9, 8, "8"),       # exactly at the VM: cores-1 == NCPU, nothing to lower
    (4, 8, "3"),       # a small Mac on a big VM keeps its own cap
    (12, 0, "11"),     # docker info gave no NCPU: unknown, so nothing is changed
])
def test_a_mac_build_asks_for_no_more_cpus_than_the_vm_has(cores, tmp_path, mac_cores,
                                                           vm_cpus, expected):
    cores(mac_cores)
    assert _cpus(_build_argv(mac(vm_cpus), tmp_path)) == expected
    assert _cpus(_fleet_argv(mac(vm_cpus), tmp_path)) == expected


def test_the_cap_is_never_above_the_vm_for_any_mac(cores, tmp_path):
    """The property dockerd enforces, for every pairing, on both build lanes."""
    for mac_cores in (2, 4, 8, 10, 12, 16, 24, 32):
        cores(mac_cores)
        for vm_cpus in (1, 2, 4, 6, 8, 12, 16):
            for argv in (_build_argv(mac(vm_cpus), tmp_path),
                         _fleet_argv(mac(vm_cpus), tmp_path)):
                assert float(_cpus(argv)) <= vm_cpus, (mac_cores, vm_cpus, argv)


def test_an_explicit_knob_above_the_vm_is_lowered_too(cores, tmp_path, monkeypatch):
    """HUGMESH_CPUS=12 on an 8-CPU VM would be refused exactly like the auto cap."""
    cores(12)
    monkeypatch.setenv(rl.CPUS_ENV, "12")
    assert _cpus(_build_argv(mac(8), tmp_path)) == "8"
    monkeypatch.setenv(rl.CPUS_ENV, "4")
    assert _cpus(_build_argv(mac(8), tmp_path)) == "4"            # below it: honoured
    monkeypatch.setenv(rl.CPUS_ENV, "off")
    assert _cpus(_build_argv(mac(8), tmp_path)) is None           # no cap is no cap


def test_a_saved_gui_limit_above_the_vm_is_lowered_too(cores, tmp_path):
    cores(12)
    rl.save(rl.ResourceLimits(cpus=10.0))
    assert _cpus(_build_argv(mac(8), tmp_path)) == "8"
    rl.save(rl.ResourceLimits(cpus=6.0))
    assert _cpus(_build_argv(mac(8), tmp_path)) == "6"


def test_only_the_cpu_flag_changes(cores, tmp_path):
    """Lowering the cap changes that one value: the rest of the Mac argv, the memory
    flags included, is what it was."""
    cores(12)
    capped, free = _build_argv(mac(8), tmp_path), _build_argv(mac(0), tmp_path)
    assert _cpus(capped) == "8" and _cpus(free) == "11"

    def rest(argv):
        out = list(argv)
        out[out.index("--cpus") + 1] = "N"
        out[out.index("--name") + 1] = "NAME"          # a random container name
        return out
    assert rest(capped) == rest(free)


# ── every other host is untouched ───────────────────────────────────────────────────
@pytest.mark.parametrize("os_name", ["linux", "windows"])
def test_a_linux_or_windows_argv_ignores_a_vm_cpu_count(cores, tmp_path, os_name):
    """docker_vm_cpus is a Mac fact. Even set on another host's HostInfo, and even with
    a count recorded for the process, the argv is what it always was."""
    cores(12)
    rl.set_engine_cpus(2)
    try:
        plain = _build_argv(host(os_name), tmp_path)
        odd = _build_argv(host(os_name, docker_vm_cpus=2), tmp_path)
    finally:
        rl.set_engine_cpus(0)
    assert _cpus(plain) == _cpus(odd) == "11"
    assert platform_info.docker_engine_cpus(host(os_name, docker_vm_cpus=2)) == 0
    assert _cpus(_fleet_argv(host(os_name, docker_vm_cpus=2), tmp_path)) == "11"


def test_with_no_count_recorded_the_limits_are_what_they_were(cores):
    cores(12)
    assert rl.engine_cpus() == 0                       # conftest pins "no ceiling"
    assert rl.effective().cpus == 11.0
    assert rl.docker_run_args(rl.effective())[:2] == ["--cpus", "11"]
    assert build_driver.docker_limit_args()[:2] == ["--cpus", "11"]
    assert rl.engine_cpu_warnings() == []


def test_off_macos_the_engine_count_is_never_probed(monkeypatch):
    """Nothing may start ``docker info`` on Linux or Windows to answer this."""
    from hugmesh_studio.core import macos_host
    monkeypatch.setattr(macos_host, "is_macos", lambda sysplatform=None: False)
    monkeypatch.setattr(macos_host, "docker_vm",
                        lambda *a, **k: (_ for _ in ()).throw(AssertionError("probed")))
    monkeypatch.setattr(rl, "_ENGINE_CPUS", None)
    assert rl.engine_cpus() == 0


def test_on_macos_a_process_that_never_detected_asks_docker_once(monkeypatch):
    """A module command line (``python -m ...local_mesh_bootstrap up``) writes the local
    stack's compose limits without ever building a HostInfo."""
    from hugmesh_studio.core import macos_host
    calls = []
    monkeypatch.setattr(macos_host, "is_macos", lambda sysplatform=None: True)
    monkeypatch.setattr(macos_host, "docker_vm",
                        lambda *a, **k: calls.append(1) or macos_host.DockerVM(
                            macos_host.RUNTIME_COLIMA, "colima", 16 * 2**30, 8))
    monkeypatch.setattr(rl, "_ENGINE_CPUS", None)
    assert rl.engine_cpus() == 8 and rl.engine_cpus() == 8
    assert calls == [1]


# ── the other lanes that hand Docker a CPU cap ──────────────────────────────────────
def test_the_compose_overlays_are_held_to_the_vm_too(cores, monkeypatch):
    """The local stack and the mesh node write ``deploy.resources.limits.cpus`` from
    resource_limits.effective(); dockerd refuses that above NCPU just the same. They
    have no HostInfo, so they read the count detect() recorded."""
    cores(12)
    monkeypatch.setattr(rl, "_ENGINE_CPUS", 8)
    assert rl.effective().cpus == 8.0
    assert rl.compose_resource_block(rl.effective())["limits"]["cpus"] == "8"


def test_detect_records_the_vm_cpu_count_on_a_mac(monkeypatch):
    from hugmesh_studio.core import macos_host
    monkeypatch.setattr(platform_info.platform, "system", lambda: "Darwin")
    monkeypatch.setattr(platform_info, "docker_probe", lambda *a, **k: DOCKER_OK)
    monkeypatch.setattr(platform_info, "_GNU_MISSING", [])
    monkeypatch.setattr(macos_host, "mac_arch", lambda run=None: "arm64")
    monkeypatch.setattr(macos_host, "hvf_available", lambda run=None: True)
    monkeypatch.setattr(macos_host, "docker_vm",
                        lambda *a, **k: macos_host.DockerVM(macos_host.RUNTIME_COLIMA,
                                                            "colima", 16 * 2**30, 8))
    monkeypatch.setattr(rl, "_ENGINE_CPUS", None)
    h = platform_info.detect()
    assert h.os == "darwin" and h.docker_vm_cpus == 8
    assert rl.engine_cpus() == 8


# ── the preflight says so ───────────────────────────────────────────────────────────
def _cpu_warnings(h: HostInfo, tmp_path) -> list[str]:
    drv = BuildDriver(GENERATOR_DIR, h, workdir=str(tmp_path))
    return [w for w in drv.preflight_warnings(ImageConfig(), "docker")
            if "Docker's VM has only" in w]


def test_the_preflight_warns_when_the_cap_was_lowered(cores, tmp_path):
    cores(12)
    (said,) = _cpu_warnings(mac(8), tmp_path)
    assert "CPU limit is 11 CPUs" in said and "has only 8" in said
    assert "--cpus 8" in said
    assert rl.CPUS_ENV in said                               # HUGMESH_CPUS, by name
    assert "Settings -> Resources" in said and "colima start --cpu" in said
    # advisory only: a lowered cap is not a reason to refuse the build
    drv = BuildDriver(GENERATOR_DIR, mac(8), workdir=str(tmp_path))
    assert not [p for p in drv.preflight(ImageConfig(), "docker") if "CPU" in p]


def test_the_warning_names_the_knob_that_asked(cores, tmp_path, monkeypatch):
    cores(12)
    monkeypatch.setenv(rl.CPUS_ENV, "16")
    (said,) = _cpu_warnings(mac(8), tmp_path)
    assert said.startswith("HUGMESH_CPUS=16 asks for 16 CPUs, and Docker's VM has only 8.")


@pytest.mark.parametrize("mac_cores, vm_cpus", [(4, 8), (9, 8), (12, 0)])
def test_no_warning_when_nothing_was_lowered(cores, tmp_path, mac_cores, vm_cpus):
    cores(mac_cores)
    assert _cpu_warnings(mac(vm_cpus), tmp_path) == []


def test_the_fleet_review_pane_says_it_too(cores, tmp_path):
    cores(12)
    drv = fleet.FleetDriver(GENERATOR_DIR, mac(8))
    notes = drv.advisories(fleet.FleetConfig(), "docker")
    assert [n for n in notes if "Docker's VM has only 8" in n and rl.CPUS_ENV in n]


def test_the_docker_remedy_mentions_the_cpu_knob():
    for arch in ("arm64", "x86_64"):
        assert "HUGMESH_CPUS" in platform_info.macos_docker_remedy(
            platform_info.DOCKER_MISSING, arch)

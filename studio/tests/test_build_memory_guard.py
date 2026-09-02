"""The 2026-07-15 host-freeze guard at the driver layer — no Qt, no real builds.

Covers: the docker --memory/--memory-swap wrapper flags (presence, env knob, preview
honesty, mutation-proven), inner-argv + native-leg byte-identity, explicit-jobs
byte-identity across host readings, the host-aware fresh-config jobs default and its
one-time pinning through to_dict, the never-throttle warning contract, the aggregate
worklist warning channel, and ONE real docker-inspect proof that the cap actually
lands on HostConfig (a cheap capped container — no build)."""
import json
import shlex
import shutil
import subprocess
import uuid

import pytest

from hugmesh_studio.core import host_resources as hr
from hugmesh_studio.core.build_driver import BuildDriver, docker_memory_args
from hugmesh_studio.core.config import Domain, ImageConfig, User
from hugmesh_studio.core.platform_info import HostInfo
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry
from hugmesh_studio.core.worklist_driver import WorklistDriver

GIB = hr.GIB


def host(is_root=True, has_docker=True, gentoo=True):
    return HostInfo(os="linux", is_gentoo=gentoo, has_docker=has_docker, has_bash=True,
                    has_kvm=False, is_root=is_root, builder_image="hugmesh-builder")


def cfg_for(tmp_path, **kw):
    kw.setdefault("jobs", 4)
    return ImageConfig(mode="mesh", role="omnibus", platform="x86", tailscale=True,
                       output_dir=str(tmp_path / "out"), **kw)


def pin_meminfo(monkeypatch, reading):
    # both seams: the process snapshot (jobs default + cap) and the per-call
    # dispatch-time read (low-memory warnings) see the same pinned host
    monkeypatch.setattr(hr, "_meminfo_cached", lambda: dict(reading))
    monkeypatch.setattr(hr, "_meminfo_fresh", lambda: dict(reading))


HEALTHY_32 = {"MemTotal": 32 * GIB, "MemAvailable": 24 * GIB,
              "SwapTotal": 4 * GIB, "SwapFree": 4 * GIB}
TIGHT_32 = {"MemTotal": 32 * GIB, "MemAvailable": 2 * GIB,
            "SwapTotal": 4 * GIB, "SwapFree": 0}


# ---- docker wrapper flags -----------------------------------------------------------

def test_docker_command_carries_the_memory_cap_in_the_wrapper_section(tmp_path, monkeypatch):
    pin_meminfo(monkeypatch, HEALTHY_32)   # 32 GiB total -> min(28, 24) = 24 GiB cap
    cmd = BuildDriver(str(tmp_path), host()).command(cfg_for(tmp_path), "docker")
    i = cmd.index("--memory")
    assert cmd[i:i + 4] == ["--memory", "24576m", "--memory-swap", "24576m"]
    # DOCKER-RUN WRAPPER SECTION only: after --name (the #339 slot), before the image
    assert cmd.index("--name") < i < cmd.index("hugmesh-builder")
    # memory-swap == memory -> ZERO container swap (no host swap-thrash)
    assert cmd[cmd.index("--memory-swap") + 1] == cmd[i + 1]


def test_env_knob_off_removes_the_cap_and_restores_prechange_argv(tmp_path, monkeypatch):
    pin_meminfo(monkeypatch, HEALTHY_32)
    d = BuildDriver(str(tmp_path), host())
    cfg = cfg_for(tmp_path)
    capped = d.command(cfg, "docker")
    monkeypatch.setenv(hr.MEMORY_ENV, "off")
    uncapped = d.command(cfg, "docker")
    assert "--memory" in capped and "--memory" not in uncapped
    # mutation proof: removing the 4 flag tokens yields the EXACT pre-change argv
    i = capped.index("--memory")
    assert capped[:i] + capped[i + 4:] == uncapped


def test_env_knob_verbatim_docker_size_string(tmp_path, monkeypatch):
    monkeypatch.setenv(hr.MEMORY_ENV, "16g")
    cmd = BuildDriver(str(tmp_path), host()).command(cfg_for(tmp_path), "docker")
    i = cmd.index("--memory")
    assert cmd[i:i + 4] == ["--memory", "16g", "--memory-swap", "16g"]


def test_no_cap_when_meminfo_unreadable_and_no_env(tmp_path, monkeypatch):
    pin_meminfo(monkeypatch, {})           # Windows/macOS: no /proc/meminfo
    assert docker_memory_args() == []
    cmd = BuildDriver(str(tmp_path), host()).command(cfg_for(tmp_path), "docker")
    assert "--memory" not in cmd


def test_preview_is_the_dispatch_command_with_and_without_the_cap(tmp_path, monkeypatch):
    """PREVIEW HONESTY, mutation-proven: command_string is a pure shlex render of
    command() — the cap the preview shows is byte-for-byte the cap dispatch runs,
    and the flags appear/disappear with the env knob in BOTH directions."""
    pin_meminfo(monkeypatch, HEALTHY_32)
    d = BuildDriver(str(tmp_path), host())
    cfg = cfg_for(tmp_path)
    s = d.command_string(cfg, "docker")
    assert shlex.split(s) == d.command(cfg, "docker")
    assert "--memory 24576m --memory-swap 24576m" in s
    monkeypatch.setenv(hr.MEMORY_ENV, "0")
    s_off = d.command_string(cfg, "docker")
    assert shlex.split(s_off) == d.command(cfg, "docker")
    assert "--memory" not in s_off


def test_cap_never_touches_inner_argv_or_the_native_leg(tmp_path, monkeypatch):
    """EMISSION IDENTITY: the flags live ONLY between `docker run` and the image name —
    the inner `bash -c` payload and the whole native command are byte-untouched."""
    pin_meminfo(monkeypatch, HEALTHY_32)
    d = BuildDriver(str(tmp_path), host())
    cfg = cfg_for(tmp_path)
    inner_capped = d.command(cfg, "docker")[-1]
    native_capped = d.command(cfg, "native")
    monkeypatch.setenv(hr.MEMORY_ENV, "off")
    assert d.command(cfg, "docker")[-1] == inner_capped
    assert d.command(cfg, "native") == native_capped
    assert "--memory" not in native_capped
    assert "-j" in shlex.split(inner_capped)  # the -j rides INSIDE, uncapped by the flag


# ---- jobs: byte-identity for explicit configs, host-aware default for fresh ones ----

def test_explicit_jobs_config_emits_identical_bytes_on_any_host(tmp_path, monkeypatch):
    """A saved config with an explicit jobs value emits `-j N` verbatim regardless of
    the host's memory state — proven under two different mocked readings."""
    saved = json.loads(json.dumps({"platform": "x86", "mode": "mesh", "role": "omnibus",
                                   "jobs": 5, "tailscale": True,
                                   "output_dir": str(tmp_path / "out")}))
    d = BuildDriver(str(tmp_path), host())
    monkeypatch.setenv(hr.MEMORY_ENV, "16g")   # fix the cap so ONLY jobs could vary
    pin_meminfo(monkeypatch, TIGHT_32)
    cfg1 = ImageConfig.from_dict(saved)
    tight_native = d.command(cfg1, "native")
    tight_docker = d.command(cfg1, "docker")
    pin_meminfo(monkeypatch, HEALTHY_32)
    cfg2 = ImageConfig.from_dict(saved)
    assert cfg1.jobs == cfg2.jobs == 5
    assert d.command(cfg2, "native") == tight_native
    assert d.command(cfg2, "docker") == tight_docker
    assert tight_native[tight_native.index("-j") + 1] == "5"


def test_fresh_config_default_jobs_is_host_aware(tmp_path, monkeypatch):
    monkeypatch.delenv(hr.JOBS_ENV, raising=False)   # undo the conftest determinism pin
    monkeypatch.setattr(hr.os, "cpu_count", lambda: 8)
    pin_meminfo(monkeypatch, TIGHT_32)               # 2 GiB avail -> floor 2
    assert ImageConfig().jobs == 2
    pin_meminfo(monkeypatch, HEALTHY_32)             # 24 GiB avail -> min(8, 12) = 8
    assert ImageConfig().jobs == 8
    pin_meminfo(monkeypatch, {})                     # memory unknown -> old flat-8 contract
    assert ImageConfig().jobs == 8


def test_host_awareness_applies_once_then_the_config_is_explicit_forever(tmp_path, monkeypatch):
    monkeypatch.delenv(hr.JOBS_ENV, raising=False)
    monkeypatch.setattr(hr.os, "cpu_count", lambda: 8)
    pin_meminfo(monkeypatch, TIGHT_32)
    d = ImageConfig().to_dict()                       # fresh on a tight host -> pins 2
    assert d["jobs"] == 2
    pin_meminfo(monkeypatch, HEALTHY_32)
    assert ImageConfig.from_dict(d).jobs == 2         # loaded verbatim, host ignored


def test_conftest_pin_keeps_suite_fresh_configs_at_8():
    # belt and braces: the autouse HUGMESH_BUILD_JOBS=8 pin makes every jobs-less
    # config in the rest of the suite byte-stable at the historical 8
    assert ImageConfig().jobs == 8


# ---- warning channel: parallel, advisory, never a throttle --------------------------

def test_preflight_warnings_fire_without_touching_preflight_or_the_command(tmp_path, monkeypatch):
    pin_meminfo(monkeypatch, HEALTHY_32)
    d = BuildDriver(str(tmp_path), host())
    cfg = cfg_for(tmp_path)
    baseline_cmd = d.command(cfg, "docker")
    baseline_problems = d.preflight(cfg, "docker")
    pin_meminfo(monkeypatch, {**TIGHT_32, "MemTotal": 32 * GIB})
    warns = d.preflight_warnings(cfg, "docker")
    assert len(warns) == 1 and "freeze the host" in warns[0]
    # NEVER-THROTTLE: same MemTotal (same cap), warning firing changes NOTHING —
    # not the argv, not cfg.jobs, not the blocking problems list
    assert d.command(cfg, "docker") == baseline_cmd
    assert cfg.jobs == 4
    assert d.preflight(cfg, "docker") == baseline_problems


def test_preflight_warnings_backend_wording(tmp_path, monkeypatch):
    pin_meminfo(monkeypatch, TIGHT_32)
    d = BuildDriver(str(tmp_path), host())
    cfg = cfg_for(tmp_path)
    native = d.preflight_warnings(cfg, "native")
    docker = d.preflight_warnings(cfg, "docker")
    assert "Native builds cannot be memory-capped" in native[0]
    assert "cannot be memory-capped" not in docker[0]


def test_preflight_warnings_quiet_on_healthy_host(tmp_path, monkeypatch):
    pin_meminfo(monkeypatch, HEALTHY_32)
    d = BuildDriver(str(tmp_path), host())
    assert d.preflight_warnings(cfg_for(tmp_path), "docker") == []
    assert d.preflight_warnings(cfg_for(tmp_path), "native") == []


def test_worklist_aggregate_warnings_dedupe_like_preflight(tmp_path, monkeypatch):
    pin_meminfo(monkeypatch, TIGHT_32)
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                       brand_title="Acme", org="Acme-Inc", cluster_domain="acme.example",
                       superdomain="core.acme.internal",
                       output_dir=str(tmp_path / "out"))
    base.domains = [Domain(name="acme.example", title="Acme")]
    base.users = [User(username="root-admin", domain="core.acme.internal",
                       role="superadmin")]
    wl = WorklistConfig(base=base, entries=[WorklistEntry(role="pki", platform="x86"),
                                            WorklistEntry(role="backend", platform="rpi5")])
    drv = WorklistDriver(str(tmp_path), wl, host=host(), backend="docker")
    warns = drv.preflight_warnings()
    # the host-level warning is common to every image -> reported ONCE, unlabelled
    assert len(warns) == 1
    assert "freeze the host" in warns[0] and not warns[0].startswith("[")
    pin_meminfo(monkeypatch, HEALTHY_32)
    assert WorklistDriver(str(tmp_path), wl, host=host(),
                          backend="docker").preflight_warnings() == []


# ---- exit-137 cap-kill attribution ---------------------------------------------------
# A container OOM-kill is a bare SIGKILL: docker prints NOTHING on the stream and the
# compile log ends mid-line. run() appends one actionable hint line so the user the cap
# protects does not blame their config — but ONLY when it can honestly be the cap.

def _run_with_code(tmp_path, monkeypatch, code, backend, cancel=False):
    d = BuildDriver(str(tmp_path), host())

    def fake_stream(cmd, on_line, be):
        if cancel:
            d._cancel.set()          # a user Stop: docker kill is also SIGKILL/137
        return code

    monkeypatch.setattr(d, "_stream", fake_stream)
    lines: list[str] = []
    got = d.run(cfg_for(tmp_path), backend, on_line=lines.append)
    return got, lines


def test_exit_137_docker_with_cap_gets_an_actionable_hint(tmp_path, monkeypatch):
    pin_meminfo(monkeypatch, HEALTHY_32)      # cap auto-derives -> 24576m
    code, lines = _run_with_code(tmp_path, monkeypatch, 137, "docker")
    assert code == 137                        # the exit code itself is untouched
    hint = [l for l in lines if "memory cap" in l]
    assert len(hint) == 1
    assert "exit 137" in hint[0]
    assert "likely" in hint[0]                # 137 is any SIGKILL — never overclaim
    assert "--memory 24576m" in hint[0]       # the actual cap value in force
    assert hr.MEMORY_ENV in hint[0]           # the remedy knob by name
    assert "lower" in hint[0] and "parallel jobs" in hint[0]


def test_exit_137_hint_absent_when_cap_disabled(tmp_path, monkeypatch):
    # no cap in force -> 137 CANNOT be the cap; a hint would be a lie
    monkeypatch.setenv(hr.MEMORY_ENV, "off")
    _, lines = _run_with_code(tmp_path, monkeypatch, 137, "docker")
    assert not any("memory cap" in l for l in lines)


def test_exit_137_hint_absent_on_native_backend(tmp_path, monkeypatch):
    pin_meminfo(monkeypatch, HEALTHY_32)
    _, lines = _run_with_code(tmp_path, monkeypatch, 137, "native")
    assert not any("memory cap" in l for l in lines)


def test_exit_137_hint_absent_on_user_cancel(tmp_path, monkeypatch):
    # a Stop kills the container (SIGKILL -> 137 too); that run is STOPPED, not capped
    pin_meminfo(monkeypatch, HEALTHY_32)
    _, lines = _run_with_code(tmp_path, monkeypatch, 137, "docker", cancel=True)
    assert not any("memory cap" in l for l in lines)


def test_ordinary_failure_gets_no_cap_hint(tmp_path, monkeypatch):
    pin_meminfo(monkeypatch, HEALTHY_32)
    code, lines = _run_with_code(tmp_path, monkeypatch, 1, "docker")
    assert code == 1
    assert not any("memory cap" in l for l in lines)


# ---- ONE real docker proof (cheap: `sleep`, no build) -------------------------------

def _docker_usable():
    if shutil.which("docker") is None:
        return False
    try:
        return subprocess.run(["docker", "info"], capture_output=True,
                              timeout=15).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


@pytest.mark.skipif(not _docker_usable(), reason="no reachable docker daemon")
def test_real_docker_run_lands_the_cap_on_hostconfig():
    """The flags the driver emits are exactly what docker enforces: start a capped
    throwaway container (the builder image when present, else the tiniest image at
    hand) and read HostConfig.Memory/MemorySwap back off the daemon."""
    image = "hugmesh-builder"
    if subprocess.run(["docker", "image", "inspect", image],
                      capture_output=True).returncode != 0:
        image = "busybox"
        if subprocess.run(["docker", "image", "inspect", image],
                          capture_output=True).returncode != 0:
            pytest.skip("neither hugmesh-builder nor busybox image is present")
    name = f"sd-memcap-proof-{uuid.uuid4().hex[:12]}"
    try:
        run = subprocess.run(
            ["docker", "run", "-d", "--rm", "--memory", "512m", "--memory-swap", "512m",
             "--name", name, image, "sleep", "30"],
            capture_output=True, text=True, timeout=60)
        assert run.returncode == 0, run.stderr
        ins = subprocess.run(
            ["docker", "inspect", "-f", "{{.HostConfig.Memory}} {{.HostConfig.MemorySwap}}",
             name], capture_output=True, text=True, timeout=30)
        assert ins.returncode == 0, ins.stderr
        assert ins.stdout.strip() == "536870912 536870912"   # 512 MiB, both knobs
    finally:
        subprocess.run(["docker", "rm", "-f", name], capture_output=True, check=False)

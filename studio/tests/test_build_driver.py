"""BuildDriver command assembly per platform, native and docker — no Qt, no builds.

The driver must dispatch the builder script from cfg.platform and keep both backends
working for all four builders (the docker path mounts the whole generator dir at /src,
so every script stays reachable in-container the same way).
"""
import os
import shlex
import subprocess

import pytest

from hugmesh_studio.core.build_driver import BuildDriver
from hugmesh_studio.core.config import BUILDER_SCRIPTS, ImageConfig
from hugmesh_studio.core.fleet import FLEET_SCRIPT, FleetConfig, FleetDriver
from hugmesh_studio.core.platform_info import HostInfo
from hugmesh_studio.core.validate import IdentityValidationError


def host(is_root=True, has_docker=True):
    return HostInfo(os="linux", is_gentoo=True, has_docker=has_docker, has_bash=True,
                    has_kvm=False, is_root=is_root, builder_image="hugmesh-builder")


def cfg_for(platform, tmp_path):
    role = {"x86": "omnibus", "rpi5": "pki", "frite": "frite", "jetson": "edge_ai",
            "orangepi5": "orangepi5", "orangepizero2": "orangepizero2"}[platform]
    mode = "cloud" if platform in ("frite", "orangepi5", "orangepizero2") else "mesh"
    return ImageConfig(mode=mode, role=role, platform=platform, tailscale=True,
                       output_dir=str(tmp_path / "out"), jobs=4)


@pytest.mark.parametrize("platform,script", sorted(BUILDER_SCRIPTS.items()))
def test_native_command_per_platform(platform, script, tmp_path):
    d = BuildDriver(str(tmp_path), host(is_root=True))
    cfg = cfg_for(platform, tmp_path)
    cmd = d.command(cfg, "native")
    assert cmd[:2] == ["bash", f"./{script}"]
    assert cmd[2:6] == ["-w", str(tmp_path / "out"), "-j", "4"]
    assert cmd[6:] == cfg.to_cli_args()


def test_native_command_plain_gentoo_roles(tmp_path):
    """The unaffiliated x86 desktop and the rpi5 generic server drive their builders
    with a bare role — no affiliation flags reach the command line."""
    d = BuildDriver(str(tmp_path), host(is_root=True))
    ua = ImageConfig(mode="standalone", role="standalone-unaffiliated", platform="x86",
                     bundle_source=False, output_dir=str(tmp_path / "out"), jobs=4)
    cmd = d.command(ua, "native")
    assert cmd[:2] == ["bash", "./build-x86-host-stage4.sh"]
    assert cmd[6:8] == ["--role", "standalone-unaffiliated"]
    for flag in ("--brand", "--brand-title", "--org", "--theme", "--bundle-source",
                 "--with-sso", "--with-tailscale", "--person-role", "--domains"):
        assert flag not in cmd
    gen = ImageConfig(mode="standalone", role="generic", platform="rpi5",
                      output_dir=str(tmp_path / "out"), jobs=4)
    cmd = d.command(gen, "native")
    assert cmd[:2] == ["bash", "./build-rpi5-stage4.sh"]
    assert cmd[6:8] == ["--role", "generic"]   # passes through the be/fe map unmapped


def test_native_non_root_prepends_sudo(tmp_path):
    d = BuildDriver(str(tmp_path), host(is_root=False))
    cmd = d.command(cfg_for("rpi5", tmp_path), "native")
    assert cmd[:3] == ["sudo", "bash", "./build-rpi5-stage4.sh"]


@pytest.mark.parametrize("platform,script", sorted(BUILDER_SCRIPTS.items()))
def test_docker_command_per_platform(platform, script, tmp_path):
    gen = str(tmp_path)
    d = BuildDriver(gen, host())
    cfg = cfg_for(platform, tmp_path)
    cmd = d.command(cfg, "docker")
    assert cmd[:4] == ["docker", "run", "--rm", "--privileged"]
    assert f"{d.generator_dir}:/src" in cmd            # generator dir mounted whole:
    assert f"{cfg.output_dir}:/out" in cmd             # every builder script reachable
    assert cmd[-4:-1] == ["hugmesh-builder", "bash", "-c"]
    inner = shlex.split(cmd[-1])
    assert inner[0] == f"./{script}"
    assert inner[1:5] == ["-w", "/out", "-j", "4"]
    assert inner[5:] == cfg.to_cli_args()


def test_extra_flags_flow_through_driver(tmp_path):
    d = BuildDriver(str(tmp_path), host(is_root=True))
    cfg = cfg_for("frite", tmp_path)
    cfg.extra_flags = '--uboot-url "https://example/u boot.bin"'
    cmd = d.command(cfg, "native")
    assert cmd[-2:] == ["--uboot-url", "https://example/u boot.bin"]
    inner = shlex.split(d.command(cfg, "docker")[-1])
    assert inner[-2:] == ["--uboot-url", "https://example/u boot.bin"]


# ---- HEADSCALE_URL env passthrough (G2) -------------------------------------
# HEADSCALE_URL is env-var-only by design (baked to /etc/hugmesh/headscale-url
# by the x86/rpi5/frite builders; NO builder flag exists) — the driver must carry
# it on BOTH backends: docker via `-e`, native via an `env` wrapper INSIDE the
# sudo boundary (sudo env_reset would strip a plain export).

def test_headscale_url_native_env_wrapper_root_and_sudo(tmp_path):
    cfg = cfg_for("x86", tmp_path)
    cfg.headscale_url = "https://hs.acme.example"
    root_cmd = BuildDriver(str(tmp_path), host(is_root=True)).command(cfg, "native")
    assert root_cmd[:3] == ["env", "HEADSCALE_URL=https://hs.acme.example", "bash"]
    sudo_cmd = BuildDriver(str(tmp_path), host(is_root=False)).command(cfg, "native")
    # env wrapper AFTER sudo so the var survives sudo's env_reset
    assert sudo_cmd[:4] == ["sudo", "env", "HEADSCALE_URL=https://hs.acme.example", "bash"]
    # the flag never leaks into the builder argv (env-only contract)
    assert not any("--headscale-url" in x for x in root_cmd)


def test_headscale_url_docker_e_flag(tmp_path):
    cfg = cfg_for("rpi5", tmp_path)
    cfg.headscale_url = "https://hs.acme.example"
    cmd = BuildDriver(str(tmp_path), host()).command(cfg, "docker")
    i = cmd.index("-e")
    assert cmd[i + 1] == "HEADSCALE_URL=https://hs.acme.example"
    assert i < cmd.index("hugmesh-builder")          # docker-run arg, not inner argv
    assert "HEADSCALE_URL" not in cmd[-1]               # not in the in-container argv


@pytest.mark.parametrize("backend", ["native", "docker"])
def test_no_headscale_url_means_no_env_plumbing(backend, tmp_path):
    cmd = BuildDriver(str(tmp_path), host(is_root=True)).command(
        cfg_for("frite", tmp_path), backend)
    assert "-e" not in cmd and "env" not in cmd
    assert not any("HEADSCALE_URL" in x for x in cmd)


def test_headscale_url_survives_command_string_quoting(tmp_path):
    cfg = cfg_for("x86", tmp_path)
    cfg.headscale_url = "https://hs.acme.example"
    s = BuildDriver(str(tmp_path), host(is_root=True)).command_string(cfg, "native")
    assert s.startswith("env HEADSCALE_URL=https://hs.acme.example bash ")


def test_pentest_env_knob_forwarded_both_backends(tmp_path):
    """PENTEST=1 (G40) is a fleet/env knob, never argv — the driver forwards it on
    both backends so the BuildPage checkbox is not a widget-level no-op."""
    cfg = cfg_for("x86", tmp_path)
    cfg.pentest = True
    native = BuildDriver(str(tmp_path), host(is_root=True)).command(cfg, "native")
    assert native[:3] == ["env", "PENTEST=1", "bash"]
    docker = BuildDriver(str(tmp_path), host()).command(cfg, "docker")
    i = docker.index("-e")
    assert docker[i + 1] == "PENTEST=1"
    assert not any("--pentest" in x for x in native + docker[:-1])


def test_command_string_is_shell_quoted(tmp_path):
    d = BuildDriver(str(tmp_path), host(is_root=True))
    cfg = cfg_for("x86", tmp_path)
    cfg.brand_title = "Acme Systems"
    s = d.command_string(cfg, "native")
    assert "./build-x86-host-stage4.sh" in s
    assert "'Acme Systems'" in s


@pytest.mark.parametrize("platform,script", sorted(BUILDER_SCRIPTS.items()))
def test_preflight_flags_missing_builder_script(platform, script, tmp_path):
    # an empty generator dir has no builder scripts -> preflight names the right one
    d = BuildDriver(str(tmp_path), host(is_root=True))
    problems = d.preflight(cfg_for(platform, tmp_path), "native")
    assert any(script in p for p in problems)


def test_preflight_ok_against_real_repo(tmp_path):
    gen = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    # all four builder scripts (jetson included) sit at the generator-repo root
    for platform in sorted(BUILDER_SCRIPTS):
        cfg = cfg_for(platform, tmp_path)
        problems = BuildDriver(gen, host(is_root=True)).preflight(cfg, "native")
        assert not any(cfg.builder_script in p for p in problems)


# ---- docker builder image preflight ----------------------------------------
# The Docker backend targets a local image tag ("hugmesh-builder", per
# HostInfo.builder_image) that is never built automatically — preflight() must catch a
# missing image (not just an unreachable daemon) and name the exact fix command, and the
# GUI needs a boolean to decide whether to offer a "build it now" button.

def _mock_docker_inspect(monkeypatch, present: bool):
    """Patch subprocess.run as used by BuildDriver._image_present so no real docker
    binary/daemon is needed."""
    calls = []

    def fake_run(cmd, **kwargs):
        calls.append(cmd)
        return subprocess.CompletedProcess(cmd, 0 if present else 1)

    monkeypatch.setattr("hugmesh_studio.core.build_driver.subprocess.run", fake_run)
    return calls


def test_preflight_no_warning_when_builder_image_present(monkeypatch, tmp_path):
    calls = _mock_docker_inspect(monkeypatch, present=True)
    d = BuildDriver(str(tmp_path), host(has_docker=True))
    cfg = cfg_for("x86", tmp_path)
    problems = d.preflight(cfg, "docker")
    assert not any("hugmesh-builder" in p for p in problems)
    assert not d.builder_image_missing("docker")
    assert calls and calls[0][:3] == ["docker", "image", "inspect"]


def test_preflight_warns_with_exact_command_when_builder_image_absent(monkeypatch, tmp_path):
    _mock_docker_inspect(monkeypatch, present=False)
    d = BuildDriver(str(tmp_path), host(has_docker=True))
    cfg = cfg_for("x86", tmp_path)
    problems = d.preflight(cfg, "docker")
    expected_cmd = "docker build -f Dockerfile.build -t hugmesh-builder ."
    assert any(expected_cmd in p and "hugmesh-builder" in p for p in problems)
    assert d.builder_image_missing("docker")


def test_builder_image_missing_false_when_daemon_unreachable(monkeypatch, tmp_path):
    # No point offering to build the image if Docker itself isn't reachable — that
    # problem is already surfaced separately.
    _mock_docker_inspect(monkeypatch, present=False)
    d = BuildDriver(str(tmp_path), host(has_docker=False))
    assert not d.builder_image_missing("docker")
    problems = d.preflight(cfg_for("x86", tmp_path), "docker")
    assert any("daemon is not reachable" in p for p in problems)
    assert not any("hugmesh-builder' not found" in p for p in problems)


# ---- fleet channel (G39): FleetDriver fronting scripts/build-all-roles.sh ----
# The fleet surface is ENV KNOBS + a small pass-through argv tail; both legs must
# carry the knobs exactly like BuildDriver carries HEADSCALE_URL/PENTEST (G2/G40).

def test_fleet_default_config_is_the_default_fleet(tmp_path):
    d = FleetDriver(str(tmp_path), host(is_root=True))
    cmd = d.command(FleetConfig(output_dir=str(tmp_path / "out")), "native")
    # no knobs -> no env wrapper: the script's own default role sets apply
    assert cmd == ["bash", f"./{FLEET_SCRIPT}", "-w", str(tmp_path / "out"), "-j", "8"]


def test_fleet_native_env_knobs_inside_sudo_boundary(tmp_path):
    cfg = FleetConfig(x86_omnibus=True, frite=True, rpi_roles="pki backend frontend desktop",
                      rpi_board="rpi4", pentest=True, skip_keys=True,
                      headscale_url="https://hs.acme.example",
                      env="prod", cluster_domain="acme.example",
                      output_dir=str(tmp_path / "out"), jobs=4)
    cmd = FleetDriver(str(tmp_path), host(is_root=False)).command(cfg, "native")
    assert cmd[0] == "sudo" and cmd[1] == "env"      # env wrapper AFTER sudo (env_reset)
    knobs = cmd[2:cmd.index("bash")]
    assert set(knobs) == {"X86_OMNIBUS=1", "FRITE=1", "PENTEST=1", "SKIP_KEYS=1",
                          "RPI_ROLES=pki backend frontend desktop", "RPI_BOARD=rpi4",
                          "HEADSCALE_URL=https://hs.acme.example"}
    tail = cmd[cmd.index("bash") + 1:]
    assert tail[:5] == [f"./{FLEET_SCRIPT}", "-w", str(tmp_path / "out"), "-j", "4"]
    assert tail[5:] == ["--env", "prod", "--cluster-domain", "acme.example"]


def test_fleet_docker_env_knobs_ride_dash_e(tmp_path):
    cfg = FleetConfig(jetson=True, jetson_board="orin-nx-16gb", pentest_scan="full",
                      output_dir=str(tmp_path / "out"))
    cmd = FleetDriver(str(tmp_path), host()).command(cfg, "docker")
    assert cmd[:4] == ["docker", "run", "--rm", "--privileged"]
    pairs = {cmd[i + 1] for i, x in enumerate(cmd) if x == "-e"}
    assert pairs == {"JETSON=1", "JETSON_BOARD=orin-nx-16gb", "PENTEST_SCAN=full"}
    assert cmd[-3:-1] == ["bash", "-c"]
    assert cmd[-1].startswith(f"./{FLEET_SCRIPT} -w /out")


def test_fleet_role_tokens_fail_closed(tmp_path):
    d = FleetDriver(str(tmp_path), host(is_root=True))
    bad = FleetConfig(rpi_roles="pki; rm -rf /")
    with pytest.raises(IdentityValidationError):
        d.command(bad, "native")
    with pytest.raises(IdentityValidationError):
        FleetConfig(cluster_domain="evil|inject").to_env()


def test_fleet_config_round_trips(tmp_path):
    cfg = FleetConfig(x86_standalone=True, orangepizero2=True, orangepizero2_flavor="live",
                      pentest_env="local", brand_profile="brands/acme.conf")
    again = FleetConfig.from_dict(cfg.to_dict())
    assert again == cfg
    assert FleetConfig.from_dict({**cfg.to_dict(), "unknown_future_key": 1}) == cfg


def test_fleet_preflight_names_missing_script_and_real_repo_is_clean(tmp_path):
    missing = FleetDriver(str(tmp_path), host(is_root=True)).preflight(FleetConfig(), "native")
    assert any(FLEET_SCRIPT in p for p in missing)
    gen = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    clean = FleetDriver(gen, host(is_root=True)).preflight(FleetConfig(), "native")
    assert not any(FLEET_SCRIPT in p for p in clean)


def test_build_builder_image_runs_expected_command(monkeypatch, tmp_path):
    gen = str(tmp_path)
    d = BuildDriver(gen, host(has_docker=True))
    seen = {}

    class FakeProc:
        stdout = iter(["Step 1/5 : FROM gentoo/stage3", "Successfully tagged hugmesh-builder"])

        def wait(self):
            return 0

    def fake_popen(cmd, **kwargs):
        seen["cmd"] = cmd
        seen["cwd"] = kwargs.get("cwd")
        return FakeProc()

    monkeypatch.setattr("hugmesh_studio.core.build_driver.subprocess.Popen", fake_popen)
    lines = []
    code = d.build_builder_image(on_line=lines.append)
    assert code == 0
    assert seen["cmd"] == ["docker", "build", "-f", "Dockerfile.build", "-t",
                           "hugmesh-builder", "."]
    assert seen["cwd"] == gen
    assert lines == ["Step 1/5 : FROM gentoo/stage3", "Successfully tagged hugmesh-builder"]

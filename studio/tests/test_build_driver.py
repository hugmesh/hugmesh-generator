"""BuildDriver command assembly per platform, native and docker — no Qt, no builds.

The driver must dispatch the builder script from cfg.platform and keep both backends
working for all four builders (the docker path mounts the whole generator dir at /src,
so every script stays reachable in-container the same way).
"""
import os
import shlex

import pytest

from snapdragon_studio.core.build_driver import BuildDriver
from snapdragon_studio.core.config import BUILDER_SCRIPTS, ImageConfig
from snapdragon_studio.core.platform_info import HostInfo


def host(is_root=True, has_docker=True):
    return HostInfo(os="linux", is_gentoo=True, has_docker=has_docker, has_bash=True,
                    has_kvm=False, is_root=is_root, builder_image="snapdragon-builder")


def cfg_for(platform, tmp_path):
    role = {"x86": "omnibus", "rpi5": "pki", "frite": "frite", "jetson": "edge_ai"}[platform]
    mode = "cloud" if platform == "frite" else "mesh"
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
    assert cmd[-4:-1] == ["snapdragon-builder", "bash", "-c"]
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
    for platform in ("x86", "rpi5", "frite"):   # jetson builder lands separately
        cfg = cfg_for(platform, tmp_path)
        problems = BuildDriver(gen, host(is_root=True)).preflight(cfg, "native")
        assert not any(cfg.builder_script in p for p in problems)

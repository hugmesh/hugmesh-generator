"""Windows sweep, cluster c3: the docker build reaches every path the GUI picked.

The docker backend is the only one the native Windows Studio offers, and the container
sees the host only through its bind mounts. Three ways a picked path still arrived in the
builder as a host spelling ('C:/Users/...') that does not exist in-container:

  * a path INSIDE the generator dir was skipped as "already under /src" and kept its host
    spelling instead of becoming /src/<rel> (wrong on Linux too: /home/u/gen/x is not at
    that path in the container either);
  * grub_theme / brand_profile / the three home seed fields were never mounted at all;
  * a lower-case drive letter or forward slashes changed which branch a path took.

Plus the preflight sentence for a stopped Docker Desktop, which told a Windows user to
install Docker (installed) or use a Gentoo host (impossible for the MSI).
"""
from __future__ import annotations

import os

import pytest

from hugmesh_studio.core import build_driver
from hugmesh_studio.core.build_driver import (
    DOCKER_ASSET_FIELDS, DOCKER_EXTRA_ASSET_FIELDS, BuildDriver, windows_docker_remedy,
)
from hugmesh_studio.core.config import ImageConfig
from hugmesh_studio.core.platform_info import HostInfo

windows_only = pytest.mark.skipif(os.name != "nt", reason="Windows path spellings")
posix_only = pytest.mark.skipif(os.name == "nt", reason="the Linux sentence")


def _host(has_docker: bool = True, os_name: str = "linux") -> HostInfo:
    return HostInfo(os=os_name, is_gentoo=False, has_docker=has_docker, has_bash=True,
                    has_kvm=False, is_root=True, builder_image="hugmesh-builder")


def _cfg(**kw) -> ImageConfig:
    cfg = ImageConfig(platform="x86", role="backend", mode="mesh", env="test")
    for k, v in kw.items():
        setattr(cfg, k, v)
    return cfg


def _gen(tmp_path, name: str = "gen") -> str:
    """A scratch generator dir with a file and a dir to point fields at."""
    gen = tmp_path / name
    (gen / "keys-template").mkdir(parents=True)
    (gen / "keys-template" / "sb.crt").write_text("x")
    (gen / "brands").mkdir()
    (gen / "brands" / "example.conf").write_text("BRAND=x\n")
    (gen / "build-x86-host-stage4.sh").write_text("#!/bin/bash\n")
    return str(gen)


def _inner(cmd: list[str]) -> str:
    assert cmd[-2] == "-c"
    return cmd[-1]


# ── paths inside the generator dir ──────────────────────────────────────────────────
def test_absolute_path_inside_generator_dir_becomes_src_path(tmp_path):
    gen = _gen(tmp_path)
    host_path = os.path.join(gen, "keys-template", "sb.crt")
    cmd = BuildDriver(gen, _host()).command(_cfg(secureboot_cert=host_path), "docker")
    assert "--secureboot-cert /src/keys-template/sb.crt" in _inner(cmd)
    assert host_path not in _inner(cmd)
    assert not any("/assets/" in a for a in cmd), "a /src file needs no extra mount"


def test_relative_path_inside_generator_dir_becomes_src_path(tmp_path, monkeypatch):
    """A relative value resolves against the Studio's cwd, as preflight's existence check
    does; when that lands in the generator dir it becomes /src/<rel>."""
    gen = _gen(tmp_path)
    monkeypatch.chdir(gen)
    rel = os.path.join("keys-template", "sb.crt")
    cmd = BuildDriver(gen, _host()).command(_cfg(secureboot_cert=rel), "docker")
    assert "--secureboot-cert /src/keys-template/sb.crt" in _inner(cmd)
    assert not any("/assets/" in a for a in cmd)


def test_relative_path_outside_generator_dir_is_mounted_from_cwd(tmp_path, monkeypatch):
    """The pre-sweep rule, kept: a cwd-relative file preflight accepted is the file the
    container gets, not a non-existent /src/<name>."""
    gen = _gen(tmp_path)
    work = tmp_path / "work"
    work.mkdir()
    (work / "wall.png").write_text("x")
    monkeypatch.chdir(work)
    drv = BuildDriver(gen, _host())
    mounts, dcfg = drv._remap_assets_for_docker(_cfg(wallpaper="wall.png"))
    assert dcfg.wallpaper == "/assets/0/wall.png"
    assert mounts == ["-v", f"{work / 'wall.png'}:/assets/0/wall.png:ro"]
    assert not [p for p in drv.preflight(_cfg(wallpaper="wall.png"), "docker")
                if "wallpaper" in p]


def test_brand_profile_inside_generator_dir_becomes_src_path(tmp_path):
    gen = _gen(tmp_path)
    host_path = os.path.join(gen, "brands", "example.conf")
    cmd = BuildDriver(gen, _host()).command(_cfg(brand_profile=host_path), "docker")
    assert "--config /src/brands/example.conf" in _inner(cmd)


def test_native_backend_keeps_host_path_inside_generator_dir(tmp_path):
    """The rewrite is docker-only: natively the host path is the right one."""
    gen = _gen(tmp_path)
    host_path = os.path.join(gen, "keys-template", "sb.crt")
    cmd = BuildDriver(gen, _host()).command(_cfg(secureboot_cert=host_path), "native")
    assert host_path in cmd


# ── the fields that were never mounted ───────────────────────────────────────────────
def test_extra_fields_outside_generator_dir_are_mounted_and_rewritten(tmp_path):
    gen = _gen(tmp_path)
    assets = tmp_path / "assets ö"
    assets.mkdir()
    (assets / "grubtheme").mkdir()
    (assets / "code").mkdir()
    (assets / "home.tar.gz").write_text("x")
    (assets / "pkgs.txt").write_text("x")
    (assets / "brand.conf").write_text("x")
    values = {
        "grub_theme": str(assets / "grubtheme"),
        "brand_profile": str(assets / "brand.conf"),
        "home_seed_code_from": str(assets / "code"),
        "include_home_archive": str(assets / "home.tar.gz"),
        "seed_packages_from": str(assets / "pkgs.txt"),
    }
    assert set(values) == set(DOCKER_EXTRA_ASSET_FIELDS)
    drv = BuildDriver(gen, _host())
    mounts, dcfg = drv._remap_assets_for_docker(_cfg(**values))
    base = len(DOCKER_ASSET_FIELDS)
    for j, field in enumerate(DOCKER_EXTRA_ASSET_FIELDS):
        cpath = f"/assets/{base + j}/{os.path.basename(values[field])}"
        assert getattr(dcfg, field) == cpath, field
        assert f"{values[field]}:{cpath}:ro" in mounts, field
    # And end to end for the flags this mesh/backend config emits.
    inner = _inner(drv.command(_cfg(**values), "docker"))
    for flag in ("--config", "--seed-packages-from", "--include-home-archive",
                 "--home-seed-code-from"):
        assert f"{flag} /assets/" in inner, flag
    assert str(assets) not in inner


def test_missing_extra_field_path_is_not_mounted(tmp_path):
    """docker run -v with a missing source creates an empty dir there; these fields are
    not preflight-checked, so the value is left for the builder's not-found refusal."""
    gen = _gen(tmp_path)
    missing = str(tmp_path / "nope.txt")
    mounts, dcfg = BuildDriver(gen, _host())._remap_assets_for_docker(
        _cfg(seed_packages_from=missing))
    assert mounts == []
    assert dcfg.seed_packages_from == missing
    assert not os.path.exists(missing)


# ── Windows spellings ────────────────────────────────────────────────────────────────
@windows_only
def test_qt_forward_slash_spelling_inside_generator_dir(tmp_path):
    gen = _gen(tmp_path, "Jöhn Dœ gen")
    qt_path = os.path.join(gen, "keys-template", "sb.crt").replace("\\", "/")
    cmd = BuildDriver(gen, _host()).command(_cfg(secureboot_cert=qt_path), "docker")
    assert "--secureboot-cert /src/keys-template/sb.crt" in _inner(cmd)
    assert qt_path not in _inner(cmd) and gen[:2] not in _inner(cmd)


@windows_only
def test_lower_case_drive_letter_inside_generator_dir(tmp_path):
    gen = _gen(tmp_path)
    p = os.path.join(gen, "keys-template", "sb.crt")
    p = p[0].lower() + p[1:]
    mounts, dcfg = BuildDriver(gen, _host())._remap_assets_for_docker(_cfg(secureboot_cert=p))
    assert dcfg.secureboot_cert == "/src/keys-template/sb.crt"
    assert mounts == []


@windows_only
def test_relative_backslash_path_gets_forward_slashes(tmp_path, monkeypatch):
    gen = _gen(tmp_path)
    monkeypatch.chdir(gen)
    cmd = BuildDriver(gen, _host()).command(
        _cfg(brand_profile="brands\\example.conf"), "docker")
    assert "--config /src/brands/example.conf" in _inner(cmd)


# ── the no-docker sentence ───────────────────────────────────────────────────────────
def test_windows_docker_remedy_is_empty_off_windows():
    assert windows_docker_remedy(osname="posix") == ""
    assert windows_docker_remedy(osname="posix", docker_cli=False) == ""


RESTART = "restart the Studio so it checks again"


def test_windows_docker_remedy_installed_but_stopped():
    """Docker is probed once, at Studio start: the cure must say to restart, since
    re-entering Review shows the same blocker until then."""
    s = windows_docker_remedy(osname="nt", docker_cli=True)
    assert "start Docker Desktop" in s and "WSL2" in s and RESTART in s
    assert "Gentoo" not in s and "install Docker" not in s


def test_windows_docker_remedy_not_installed():
    s = windows_docker_remedy(osname="nt", docker_cli=False)
    assert "install Docker Desktop" in s and "WSL2" in s and RESTART in s
    assert "Gentoo" not in s


def test_windows_docker_remedy_uses_the_probe_state():
    """A detected host's own wording wins: a timed-out probe is "still starting, or
    busy", not "does not answer"."""
    def host(state: str) -> HostInfo:
        h = _host(has_docker=False, os_name="windows")
        h.docker_state = state
        return h

    timeout = host("timeout")
    s = windows_docker_remedy(osname="nt", host=timeout)
    assert s.startswith(timeout.docker_remedy()) and "busy" in s and RESTART in s
    assert "WSL2" in s and "Gentoo" not in s
    s = windows_docker_remedy(osname="nt", docker_cli=False, host=host("down"))
    assert "start Docker Desktop" in s and RESTART in s and "not found" not in s
    # a probe that found no docker.exe is not second-guessed by PATH
    assert "not found" in windows_docker_remedy(osname="nt", host=host("missing"))


@windows_only
def test_preflight_on_windows_names_docker_desktop_not_gentoo(tmp_path, monkeypatch):
    gen = _gen(tmp_path)
    monkeypatch.setattr(build_driver.shutil, "which",
                        lambda n, *a, **k: "C:\\docker.exe" if n == "docker" else None)
    drv = BuildDriver(gen, _host(has_docker=False, os_name="windows"))
    for backend in ("none", "docker"):
        text = " ".join(drv.preflight(_cfg(), backend))
        assert "start Docker Desktop" in text and RESTART in text, backend
        assert "Gentoo" not in text and "Install Docker Desktop" not in text, backend


@windows_only
def test_preflight_on_windows_timeout_is_not_called_unreachable(tmp_path):
    gen = _gen(tmp_path)
    host = _host(has_docker=False, os_name="windows")
    host.docker_state = "timeout"
    drv = BuildDriver(gen, host)
    text = " ".join(drv.preflight(_cfg(), "docker"))
    assert "Docker selected. " + host.docker_remedy() in text
    assert "not reachable" not in text and "Gentoo" not in text
    assert "No build backend: " + host.docker_remedy() in " ".join(
        drv.preflight(_cfg(), "none"))


@posix_only
def test_preflight_off_windows_is_unchanged(tmp_path):
    gen = _gen(tmp_path)
    drv = BuildDriver(gen, _host(has_docker=False))
    assert ("No build backend: install Docker (any OS) or run on a Gentoo host."
            in drv.preflight(_cfg(), "none"))
    assert any(p.startswith("Docker selected but the Docker daemon is not reachable. Start")
               for p in drv.preflight(_cfg(), "docker"))

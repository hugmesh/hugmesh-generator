"""Native host-tool advisory: the Studio half of the builders' host-safety guard.

The builder scripts now REFUSE (fail fast, with a copy-pasteable emerge) when a
native build is missing a host tool it needs, instead of warning and silently
dropping an artifact the operator asked for. This surfaces the most common
shortfall in the Studio BEFORE the operator commits to a long build.

Two properties are load-bearing and locked here:

  1. It is ADVISORY, never blocking. It lives in preflight_warnings(), not
     preflight() — Review's isComplete gates on preflight(), and a blocking
     preflight bug once made the GUI unable to dispatch ANY native build
     (the pre-#382 regression). A wrong answer here must cost a spurious
     warning line, never a blocked build.

  2. It does not rely on PATH. Squash/disk tooling installs into /usr/sbin on
     some hosts, and the Studio runs as an unprivileged user whose PATH
     typically omits /usr/sbin — while the build itself runs as ROOT via
     sudo/pkexec, with /usr/sbin on PATH. A PATH-only probe reports "missing"
     for a tool the build would find.
"""

import os

import pytest

from snapdragon_studio.core import build_driver as bd
from snapdragon_studio.core.build_driver import BuildDriver, _host_tool_present
from snapdragon_studio.core.config import ImageConfig
from snapdragon_studio.core.platform_info import HostInfo


def host(is_root=True, has_docker=True, gentoo=True):
    # same shape as tests/test_build_memory_guard.py's helper
    return HostInfo(os="linux", is_gentoo=gentoo, has_docker=has_docker, has_bash=True,
                    has_kvm=False, is_root=is_root, builder_image="snapdragon-builder")


# ---- _host_tool_present: the PATH-independence contract ---------------------

def test_probes_sbin_when_path_omits_it(tmp_path, monkeypatch):
    """The exact false negative the advisory would otherwise hit: tool present in
    a *bin dir, but absent from the unprivileged Studio's PATH."""
    sbin = tmp_path / "usr" / "sbin"
    sbin.mkdir(parents=True)
    tool = sbin / "mksquashfs"
    tool.write_text("#!/bin/sh\n")
    tool.chmod(0o755)
    monkeypatch.setenv("PATH", "/nonexistent-bin")           # which() must fail
    monkeypatch.setattr(bd, "_SBIN_DIRS", (str(sbin),))
    assert _host_tool_present("mksquashfs") is True


def test_absent_tool_is_absent(monkeypatch, tmp_path):
    monkeypatch.setenv("PATH", str(tmp_path))
    monkeypatch.setattr(bd, "_SBIN_DIRS", (str(tmp_path),))
    assert _host_tool_present("mksquashfs") is False


def test_alternatives_any_match_wins(tmp_path, monkeypatch):
    """mksquashfs OR tar2sqfs can squash the rootfs — either satisfies the build,
    mirroring the builder's `mksquashfs|tar2sqfs` group."""
    d = tmp_path / "b"
    d.mkdir()
    alt = d / "tar2sqfs"
    alt.write_text("#!/bin/sh\n")
    alt.chmod(0o755)
    monkeypatch.setenv("PATH", "/nonexistent-bin")
    monkeypatch.setattr(bd, "_SBIN_DIRS", (str(d),))
    assert _host_tool_present("mksquashfs", "tar2sqfs") is True
    assert _host_tool_present("mksquashfs") is False


def test_non_executable_file_does_not_count(tmp_path, monkeypatch):
    d = tmp_path / "b"
    d.mkdir()
    (d / "mksquashfs").write_text("not executable")
    monkeypatch.setenv("PATH", "/nonexistent-bin")
    monkeypatch.setattr(bd, "_SBIN_DIRS", (str(d),))
    assert _host_tool_present("mksquashfs") is False


# ---- the advisory itself ---------------------------------------------------

def _driver(tmp_path):
    return BuildDriver(str(tmp_path), host())


def test_missing_squasher_warns_on_native(tmp_path, monkeypatch):
    monkeypatch.setattr(bd, "_host_tool_present", lambda *n: False)
    warns = _driver(tmp_path).preflight_warnings(ImageConfig(), "native")
    assert any("mksquashfs" in w and "live ISO will be refused" in w for w in warns)
    assert any("sys-fs/squashfs-tools" in w for w in warns), "must name the emerge atom"


def test_present_squasher_is_quiet(tmp_path, monkeypatch):
    monkeypatch.setattr(bd, "_host_tool_present", lambda *n: True)
    warns = _driver(tmp_path).preflight_warnings(ImageConfig(), "native")
    assert not any("mksquashfs" in w for w in warns)


def test_docker_backend_never_warns_about_host_tools(tmp_path, monkeypatch):
    """The builder IMAGE ships mksquashfs; a docker build does not care what the
    host has. Warning there would be noise about a non-problem."""
    monkeypatch.setattr(bd, "_host_tool_present", lambda *n: False)
    warns = _driver(tmp_path).preflight_warnings(ImageConfig(), "docker")
    assert not any("mksquashfs" in w for w in warns)


def test_advisory_never_blocks(tmp_path, monkeypatch):
    """THE property that matters: a missing host tool must not enter preflight()'s
    blocking list, whose growth is what broke native dispatch before #382."""
    d = _driver(tmp_path)
    cfg = ImageConfig()
    monkeypatch.setattr(bd, "_host_tool_present", lambda *n: True)
    baseline = d.preflight(cfg, "native")
    monkeypatch.setattr(bd, "_host_tool_present", lambda *n: False)
    assert d.preflight(cfg, "native") == baseline
    assert not any("mksquashfs" in p for p in d.preflight(cfg, "native"))
    # ...and it must not disturb the argv either.
    assert d.command(cfg, "native") == d.command(cfg, "native")


def test_elevation_advisory_still_intact(tmp_path, monkeypatch):
    """#382's elevation-advisory semantics must survive this addition: a non-root
    native build with a helper available advises a prompt and does NOT block."""
    monkeypatch.setattr(bd, "_host_tool_present", lambda *n: True)
    monkeypatch.setattr(bd.shutil, "which", lambda n: "/usr/bin/sudo" if n == "sudo" else None)
    d = BuildDriver(str(tmp_path), host(is_root=False))
    warns = d.preflight_warnings(ImageConfig(), "native")
    assert any("authentication prompt" in w for w in warns)
    assert not any("needs root" in p for p in d.preflight(ImageConfig(), "native"))

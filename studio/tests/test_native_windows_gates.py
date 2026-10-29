"""The Windows MSI runs the Studio natively, and the local-mesh and DevOps verbs cannot.

Measured on Windows 11 with the 0.3.0-beta.1 MSI (2026-10-23): "Bootstrapping",
"Building maven prerequisites" and "Installing DevOps prerequisites" all failed. The
first two said "make is required" (installing make would not help: the recipes are
bash, and System32\\bash.exe is the WSL launcher); the third said "Automatic install
covers Linux only". None named WSL2, the supported Windows runtime. Qt-free: every
gate here is core code, and the GUI refusal is the same sentence.
"""
from __future__ import annotations

import functools

import pytest

from hugmesh_studio.core import devops_tools, platform_info
from hugmesh_studio.core import local_stack_node as lsn


@pytest.fixture
def as_native_windows(monkeypatch):
    """Answer as the Windows build would, without changing os.name for the process
    (pathlib and subprocess read it too)."""
    monkeypatch.setattr(platform_info, "native_windows_blocker",
                        functools.partial(platform_info.native_windows_blocker,
                                          osname="nt"))


def test_the_sentence_names_wsl2_and_nothing_elsewhere():
    said = platform_info.native_windows_blocker("The local stack", osname="nt")
    assert said.startswith("The local stack runs `make` and bash scripts")
    assert "WSL2" in said and "Docker Desktop" in said and "/mnt/c" in said
    assert platform_info.native_windows_blocker("The local stack", osname="posix") == ""


def test_the_local_stack_says_wsl_not_make(as_native_windows, tmp_path):
    node = lsn.LocalStackNode(str(tmp_path))
    ok, why = node.available()
    assert not ok
    assert "WSL2" in why and "make is required" not in why, why


def test_the_devops_lane_says_wsl_not_install_kind(as_native_windows, tmp_path):
    problems = lsn.LocalStackNode(str(tmp_path)).devops_available()
    assert len(problems) == 1 and "WSL2" in problems[0], problems
    assert "Install DevOps prerequisites" not in problems[0], problems


def test_the_installer_refuses_with_the_same_sentence(as_native_windows, tmp_path):
    said: list[str] = []
    ok, msg = devops_tools.install(str(tmp_path), on_line=said.append)
    assert not ok and "WSL2" in msg, msg
    assert said and "WSL2" in said[0], said        # streamed, not only returned

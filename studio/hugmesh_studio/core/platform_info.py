"""Host capability detection — what can this machine do, and how should it build?

Used by the Studio to choose a build backend (native Gentoo vs Docker) and to decide
whether the local-mesh-node + hardware-scan features are available.
"""
from __future__ import annotations

import os
import platform
import shutil
import subprocess
from dataclasses import dataclass


@dataclass
class HostInfo:
    os: str               # "linux" | "windows" | "darwin"
    is_gentoo: bool
    has_docker: bool
    has_bash: bool
    has_kvm: bool
    is_root: bool
    builder_image: str    # docker image name to use for dockerized builds

    @property
    def can_build_native(self) -> bool:
        # The build script is Gentoo+bash and writes a stage4/chroot — only a Gentoo
        # host (ideally root) can run it natively. Everyone else uses Docker.
        return self.os == "linux" and self.is_gentoo and self.has_bash

    @property
    def default_backend(self) -> str:
        if self.can_build_native:
            return "native"
        return "docker" if self.has_docker else "none"

    def summary(self) -> str:
        bits = [f"OS={self.os}"]
        if self.is_gentoo:
            bits.append("Gentoo")
        bits.append("docker" if self.has_docker else "no-docker")
        if self.has_kvm:
            bits.append("KVM")
        if self.is_root:
            bits.append("root")
        return " · ".join(bits)


def _is_gentoo() -> bool:
    try:
        if os.path.exists("/etc/gentoo-release"):
            return True
        with open("/etc/os-release", encoding="utf-8") as fh:
            return "gentoo" in fh.read().lower()
    except OSError:
        return False


def _docker_ok() -> bool:
    exe = shutil.which("docker")
    if not exe:
        return False
    try:
        # `docker info` is the real "daemon reachable?" check (Windows: Docker Desktop).
        r = subprocess.run([exe, "info"], capture_output=True, timeout=8)
        return r.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def detect(builder_image: str = "hugmesh-builder") -> HostInfo:
    sysname = platform.system().lower()
    osname = "windows" if sysname.startswith("win") else ("darwin" if sysname == "darwin" else "linux")
    is_root = False
    try:
        is_root = hasattr(os, "geteuid") and os.geteuid() == 0  # type: ignore[attr-defined]
    except AttributeError:
        is_root = False
    return HostInfo(
        os=osname,
        is_gentoo=(osname == "linux" and _is_gentoo()),
        has_docker=_docker_ok(),
        has_bash=bool(shutil.which("bash")),
        has_kvm=os.path.exists("/dev/kvm"),
        is_root=is_root,
        builder_image=builder_image,
    )

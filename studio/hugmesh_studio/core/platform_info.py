"""Host capability detection — what can this machine do, and how should it build?

Used by the Studio to choose a build backend (native Gentoo vs Docker) and to decide
whether the local-mesh-node + hardware-scan features are available.

THREE AXES, not one, because they fail independently and the operator hits all three:

  * OS + distro       — can we build natively, or must we go through Docker?
  * DISPLAY SESSION   — Wayland or X11. Not cosmetic: under Wayland a client CANNOT
                        position its own top-level windows, so ``QWidget.move()``
                        silently does nothing and any "centre the window" or
                        "put the tooltip at the cursor" code is a no-op that leaves
                        the window wherever the compositor felt like putting it.
                        Detected here so the GUI can ASK instead of assuming.
  * WSL               — the supported way to run this Studio on Windows (operator
                        decision, 2026-08-14). WSL2 is a real Linux kernel, so bash,
                        make, docker, os.killpg and the whole shell-out layer keep
                        working unchanged — which is exactly why it was chosen over a
                        native Win32 port. What does NOT come for free is hardware:
                        a WSL2 VM sees no USB devices at all unless they are attached
                        from the Windows side with usbipd-win, so device FLASHING has
                        to be gated with that remedy rather than silently listing the
                        VM's own virtual disks as flash targets.
"""
from __future__ import annotations

import os
import platform
import shutil
import subprocess
from dataclasses import dataclass

#: Session kinds. "none" = no display at all (headless/CI); the GUI cannot run.
SESSION_WAYLAND = "wayland"
SESSION_X11 = "x11"
SESSION_NONE = "none"


@dataclass
class HostInfo:
    os: str               # "linux" | "windows" | "darwin"
    is_gentoo: bool
    has_docker: bool
    has_bash: bool
    has_kvm: bool
    is_root: bool
    builder_image: str    # docker image name to use for dockerized builds
    #: "wayland" | "x11" | "none" — the DISPLAY server actually in use.
    session: str = SESSION_NONE
    #: True when running inside WSL (either version).
    is_wsl: bool = False
    #: 2 for WSL2 (real kernel), 1 for WSL1, 0 when not WSL.
    wsl_version: int = 0
    #: True when Windows binaries are callable from here (WSL interop enabled) —
    #: what makes `usbipd.exe`, `explorer.exe` and Windows path translation reachable.
    has_win_interop: bool = False

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

    @property
    def is_wayland(self) -> bool:
        """Under Wayland a client cannot place its own top-level windows.

        Every ``move()`` / ``setGeometry()`` on a top-level is a silent no-op, so code
        that centres a window or pins a tooltip to the cursor must take a different
        route (let the compositor place it, or parent the popup to a widget) rather
        than appearing to work and quietly doing nothing.
        """
        return self.session == SESSION_WAYLAND

    @property
    def has_gui(self) -> bool:
        return self.session in (SESSION_WAYLAND, SESSION_X11)

    @property
    def can_flash_devices(self) -> bool:
        """Whether offering a 'write this image to a device' flow is HONEST here.

        Linux-only (it reads /proc/mounts + lsblk + /dev), and specifically NOT inside
        WSL unless USB devices have been attached from Windows: a bare WSL2 VM enumerates
        only its own virtual disks, so the picker would be listing targets that are
        either useless or actively dangerous to write to.
        """
        if self.os != "linux":
            return False
        if self.is_wsl and not self.has_usb_passthrough:
            return False
        return True

    @property
    def has_usb_passthrough(self) -> bool:
        """WSL only: has anything actually been attached with usbipd-win?

        Presence of a real removable block device is the evidence — /dev/sd* exists in a
        bare WSL2 VM for its own virtual disk, so the check has to be for a device the VM
        would not otherwise have.
        """
        if not self.is_wsl:
            return True
        try:
            return any(n.startswith(("sd", "nvme")) for n in os.listdir("/sys/block")
                       if _is_usb_backed(n))
        except OSError:
            return False

    def flash_blocker(self) -> str:
        """WHY flashing is unavailable, with the fix — never a bare 'unsupported'."""
        if self.can_flash_devices:
            return ""
        if self.os != "linux":
            return (f"Writing an image to a device needs Linux block devices; this is "
                    f"{self.os}. Run the Studio under WSL2 and attach the drive (below).")
        if self.is_wsl:
            return (
                "WSL sees no USB devices until Windows hands one over. In an ADMIN "
                "PowerShell on Windows:\n"
                "    usbipd list                     # find the BUSID of your drive\n"
                "    usbipd bind --busid <BUSID>     # once per device\n"
                "    usbipd attach --wsl --busid <BUSID>\n"
                "Then re-scan here. Without this the picker would only show WSL's own "
                "virtual disk, which is not what you want to write to.")
        return "Device flashing is unavailable on this host."

    def summary(self) -> str:
        bits = [f"OS={self.os}"]
        if self.is_wsl:
            bits.append(f"WSL{self.wsl_version or ''}")
        if self.is_gentoo:
            bits.append("Gentoo")
        if self.session != SESSION_NONE:
            bits.append(self.session)
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


def _is_usb_backed(block_name: str) -> bool:
    """Is /sys/block/<name> reached over USB? (the usbipd-attached case under WSL)"""
    try:
        return "usb" in os.path.realpath(f"/sys/block/{block_name}").lower()
    except OSError:
        return False


def detect_session() -> str:
    """Which display server is actually in use.

    Order matters. ``XDG_SESSION_TYPE`` is the declared answer but is routinely wrong or
    absent (it says "tty" under a display manager that did not set it, and is unset
    entirely inside containers and over ssh), so the concrete sockets are checked FIRST
    and the declaration is only a tie-breaker. ``WAYLAND_DISPLAY`` set means a Wayland
    compositor is reachable; a bare ``DISPLAY`` means X11 — including XWayland, which is
    the right answer for Qt because in that case Qt IS an X11 client and ``move()``
    works again.
    """
    if os.environ.get("WAYLAND_DISPLAY"):
        # XWayland: a Wayland compositor is up, but Qt was told to be an X11 client, so
        # it gets X11 semantics. Believe the override.
        if os.environ.get("QT_QPA_PLATFORM", "").strip().lower() in ("xcb", "x11"):
            return SESSION_X11
        return SESSION_WAYLAND
    if os.environ.get("DISPLAY"):
        return SESSION_X11
    declared = os.environ.get("XDG_SESSION_TYPE", "").strip().lower()
    if declared in (SESSION_WAYLAND, SESSION_X11):
        return declared
    return SESSION_NONE


def detect_wsl() -> tuple[bool, int]:
    """(is_wsl, version). WSL2 is a real kernel; WSL1 is a syscall shim.

    The distinction is load-bearing, not trivia: WSL1 cannot run Docker's daemon or
    KVM and mis-handles many block-device syscalls, so an image build that WOULD work
    on WSL2 fails there for reasons no error message explains.
    """
    if os.name == "nt":
        return False, 0
    release = ""
    try:
        with open("/proc/version", encoding="utf-8", errors="replace") as fh:
            release = fh.read().lower()
    except OSError:
        return False, 0
    if "microsoft" not in release:
        return False, 0
    # WSL2 kernels carry the marker in the release string; WSL1 reports a fake 4.4.
    return True, (2 if "wsl2" in release or "microsoft-standard" in release else 1)


def detect(builder_image: str = "hugmesh-builder") -> HostInfo:
    sysname = platform.system().lower()
    osname = "windows" if sysname.startswith("win") else ("darwin" if sysname == "darwin" else "linux")
    is_root = False
    try:
        is_root = hasattr(os, "geteuid") and os.geteuid() == 0  # type: ignore[attr-defined]
    except AttributeError:
        is_root = False
    is_wsl, wsl_version = detect_wsl()
    return HostInfo(
        os=osname,
        is_gentoo=(osname == "linux" and _is_gentoo()),
        has_docker=_docker_ok(),
        has_bash=bool(shutil.which("bash")),
        has_kvm=os.path.exists("/dev/kvm"),
        is_root=is_root,
        builder_image=builder_image,
        session=detect_session(),
        is_wsl=is_wsl,
        wsl_version=wsl_version,
        # WSL_INTEROP is the socket that makes Windows binaries callable; without it
        # usbipd.exe and friends are unreachable even though we are "on Windows".
        has_win_interop=is_wsl and bool(os.environ.get("WSL_INTEROP")),
    )

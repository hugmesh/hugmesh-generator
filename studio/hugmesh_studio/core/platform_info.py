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

THE THREE WSL FAILURES THAT DO NOT ANNOUNCE THEMSELVES are all handled here, because
none of them produces an error message that names its own cause:

  1. /mnt/c   A repo living on a Windows drive is reached over 9p/virtiofs. Every
              open(), stat() and rename() leaves the VM, and a build is hundreds of
              thousands of those — 10-20x slower. It does not present as slowness, it
              presents as "the build hung". Nothing errors, so nothing explains it.
              :meth:`HostInfo.slow_filesystem_warning` reads the FILESYSTEM TYPE out of
              /proc/mounts rather than pattern-matching the path, because a bind mount
              or a symlink into /mnt/c looks like a Linux path and is just as slow.
  2. docker   Docker Desktop keeps the daemon on the WINDOWS side and exposes it per
              distro. With WSL integration off for this distro `docker info` fails with
              a connection error that says nothing about the checkbox that caused it.
  3. KVM      WSL2 disables nested virtualisation by default outside Windows 11, so
              /dev/kvm is simply absent and QEMU silently falls back to TCG — x86 rows
              go from minutes to hours, which again reads as a hang. The fix is a
              .wslconfig setting plus `wsl --shutdown`, which no error mentions.
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

#: Where the kernel publishes the mount table. Overridable so the WSL cases can be
#: asserted on a machine that is not WSL (this workstation, and CI).
MOUNTS_PATH = "/proc/mounts"

#: Filesystem types that mean "this directory really lives on the Windows side".
#: WSL has used all three names for a Windows drive over the years — ``drvfs`` (the
#: WSL1 spelling, still reported by some builds), ``9p`` (WSL2's plan9 transport) and
#: ``virtiofs`` (newer WSL2). Every one of them crosses the VM boundary per operation.
WINDOWS_DRIVE_FSTYPES = frozenset({"9p", "drvfs", "virtiofs"})

#: Genuinely remote filesystems. Slow for the same reason and on every platform, so
#: they are reported too — just with a different remedy than "clone into the VM".
NETWORK_FSTYPES = frozenset({"cifs", "smb3", "smbfs", "nfs", "nfs4"})


@dataclass
class HostInfo:
    os: str               # "linux" | "windows" | "darwin"
    is_gentoo: bool
    has_docker: bool
    has_bash: bool
    #: /dev/kvm exists AND this user can actually open it read-write. Both halves
    #: matter: the QEMU harness tests `-r` and `-w`, not mere existence, so a node
    #: the operator has no group membership for is NOT acceleration.
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
    #: WSL_DISTRO_NAME — the name Docker Desktop's WSL-integration list shows, so the
    #: remedy can point at the exact checkbox instead of "your distro".
    wsl_distro: str = ""
    #: /dev/kvm is THERE but this user cannot open it. A different fix (group
    #: membership) from "nested virtualisation is off", so it is kept distinguishable.
    kvm_present_but_denied: bool = False

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

    # ── the /mnt/c performance trap ─────────────────────────────────────────────
    def slow_filesystem_warning(self, path: str, mounts_path: str = MOUNTS_PATH) -> str:
        """Is ``path`` reached over a filesystem that will make the build look HUNG?

        The most expensive WSL2 mistake there is, and the one that never announces
        itself. A repo cloned to ``C:\\Users\\…\\hugmesh-generator`` and opened as
        ``/mnt/c/Users/…`` is reached over 9p/virtiofs: every ``open()``, ``stat()``
        and ``rename()`` leaves the VM for a Windows file server, and a build performs
        hundreds of thousands of them. The result is routinely 10-20x slower, and it
        does NOT present as slowness — it presents as a build whose progress line has
        stopped moving for minutes at a time, i.e. as a hang. Nothing errors, nothing
        logs, so nothing tells the operator what happened.

        Decided on the FILESYSTEM TYPE from /proc/mounts, not on the shape of the path:
        a bind mount, or a symlink from ``~/Github`` into ``/mnt/c``, is an ordinary
        Linux-looking path and is exactly as slow. The path shape is used only as a
        fallback when the mount table cannot be read at all.

        Returns "" when the path is on a local disk — never a guess, never a nag.
        """
        _mountpoint, fstype = mount_for(path, mounts_path)
        windows_drive = fstype in WINDOWS_DRIVE_FSTYPES
        if not fstype and self.is_wsl:
            # No mount table (unreadable /proc): fall back to the path shape rather
            # than staying silent about the trap. Secondary evidence, clearly labelled.
            windows_drive = _looks_like_windows_drive_path(path)
            fstype = "9p/virtiofs"
        if windows_drive and self.is_wsl:
            return (
                f"SLOW FILESYSTEM — this will look like a HANG. The generator directory "
                f"({path}) is on a Windows drive (filesystem '{fstype}'). Under WSL2 every "
                f"file operation there crosses out of the VM to Windows, which is 10-20x "
                f"slower for the many small files a build touches: the build does not fail, "
                f"it just stops appearing to move. Put the repo on the Linux filesystem and "
                f"run from there:\n"
                f"    git clone <repo-url> ~/Github/hugmesh-generator\n"
                f"(or `cp -a \"{path}\" ~/Github/`). ~ is the VM's own virtual disk and is "
                f"as fast as native Linux; /mnt/c is not, and no setting makes it so.")
        if fstype in NETWORK_FSTYPES:
            return (
                f"SLOW FILESYSTEM — this will look like a HANG. The generator directory "
                f"({path}) is on a network filesystem ('{fstype}'): every file operation is "
                f"a round trip and a build performs hundreds of thousands of them. Copy the "
                f"repo onto a local disk and build from there.")
        return ""

    # ── docker reachability ─────────────────────────────────────────────────────
    def docker_remedy(self) -> str:
        """HOW to make the daemon reachable from here — the fix text only, "" when it
        already is. Kept separate from a full sentence so callers that have already
        stated the symptom (preflight: "the Docker daemon is not reachable") can append
        the cure without saying the diagnosis twice."""
        if self.has_docker:
            return ""
        wsl = wsl_docker_remedy(self.is_wsl, self.wsl_version, self.wsl_distro)
        if wsl:
            return wsl
        if self.os == "linux":
            return ("Start the daemon (`sudo systemctl start docker`) and make sure your "
                    "user is in the 'docker' group (`sudo usermod -aG docker $USER`, then "
                    "log out and back in).")
        return "Install Docker Desktop and start it."

    def docker_blocker(self) -> str:
        """Symptom + fix, self-contained — for surfaces that show this text alone."""
        if self.has_docker:
            return ""
        return "The Docker daemon is not reachable from here. " + self.docker_remedy()

    # ── KVM / nested virtualisation (the QEMU lane) ─────────────────────────────
    def kvm_blocker(self) -> str:
        """WHY emulated x86 devices will crawl here, with the fix. "" when KVM works.

        Deliberately a WARNING and not a block: the harness falls back to TCG on its
        own (``run-qemu-docker.sh``: ``[ -r /dev/kvm ] && [ -w /dev/kvm ]``), so the
        run does succeed — it just takes hours instead of minutes, which is once again
        indistinguishable from a hang unless somebody says so out loud.
        """
        if self.has_kvm:
            return ""
        head = ("No usable /dev/kvm — emulated x86 devices will run under full "
                "emulation (TCG), which is roughly 10x slower and reads as a hang. "
                "Aarch64/Pi rows are pure emulation on any x86 host and are unaffected.")
        if self.kvm_present_but_denied:
            return (f"{head}\n/dev/kvm EXISTS but this user cannot open it — add yourself "
                    f"to the group that owns it (`sudo usermod -aG kvm $USER`) and log "
                    f"out and back in.")
        if self.is_wsl and self.wsl_version == 1:
            return (f"{head}\nWSL1 cannot run KVM at all (it is a syscall shim, not a "
                    f"kernel). Convert this distro to WSL2 from an admin PowerShell:\n"
                    f"    wsl --set-version {self.wsl_distro or '<distro>'} 2")
        if self.is_wsl:
            return (f"{head}\nWSL2 leaves nested virtualisation OFF by default. On the "
                    f"Windows side, in %UserProfile%\\.wslconfig:\n"
                    f"    [wsl2]\n"
                    f"    nestedVirtualization=true\n"
                    f"then from PowerShell:  wsl --shutdown   — and reopen this distro "
                    f"(the setting is only read when the VM starts).")
        if self.os != "linux":
            return (f"{head}\nKVM is a Linux kernel feature; this is {self.os}.")
        return (f"{head}\nLoad the KVM module for your CPU (`sudo modprobe kvm_intel` or "
                f"`kvm_amd`) and enable VT-x/AMD-V virtualisation in the firmware setup.")

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


def wsl_docker_remedy(is_wsl: bool | None = None, wsl_version: int = 0,
                      distro: str = "") -> str:
    """The WSL-specific reason `docker info` failed, with the fix. "" when not on WSL.

    Under WSL there is no daemon in the distro at all by default: Docker Desktop runs it
    on the WINDOWS side and exposes it to each distro individually, through a checkbox.
    With that checkbox off, `docker info` fails with a socket/connection error that names
    neither Docker Desktop nor WSL integration, so the operator is left debugging a
    daemon that was never supposed to be running here in the first place.

    Called with no arguments by helpers that have no :class:`HostInfo` to hand, in which
    case the environment is probed on the spot.
    """
    if is_wsl is None:
        is_wsl, wsl_version = detect_wsl()
        distro = distro or os.environ.get("WSL_DISTRO_NAME", "")
    if not is_wsl:
        return ""
    named = distro or "this distro"
    if wsl_version == 1:
        return (f"This is WSL1, which cannot run the Docker daemon (it is a syscall shim, "
                f"not a kernel). Convert it from an admin PowerShell:\n"
                f"    wsl --set-version {distro or '<distro>'} 2\n"
                f"then enable Docker Desktop's WSL integration for it.")
    return (f"Under WSL the daemon lives on the WINDOWS side, not in this VM, and is "
            f"exposed per distro. Make sure Docker Desktop is RUNNING, then:\n"
            f"    Docker Desktop -> Settings -> Resources -> WSL Integration\n"
            f"    -> enable {named}, then Apply & Restart\n"
            f"(If you instead installed docker inside the distro rather than using Docker "
            f"Desktop, start it with `sudo service docker start` and add yourself to the "
            f"'docker' group.)")


def _unescape_mount(field: str) -> str:
    """/proc/mounts octal-escapes space, tab, newline and backslash in path fields."""
    for esc, ch in (("\\040", " "), ("\\011", "\t"), ("\\012", "\n"), ("\\134", "\\")):
        field = field.replace(esc, ch)
    return field


def read_mounts(mounts_path: str = MOUNTS_PATH) -> list[tuple[str, str]]:
    """[(mountpoint, fstype)] from the kernel's mount table. [] when unreadable.

    Empty on failure rather than raising or guessing: a missing mount table must make
    the caller say nothing, not invent a diagnosis.
    """
    out: list[tuple[str, str]] = []
    try:
        with open(mounts_path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) >= 3:
                    out.append((_unescape_mount(parts[1]), parts[2]))
    except OSError:
        return []
    return out


def mount_for(path: str, mounts_path: str = MOUNTS_PATH) -> tuple[str, str]:
    """(mountpoint, fstype) of the mount that actually carries ``path``.

    Longest-prefix on whole path COMPONENTS, so ``/mnt/c`` never claims ``/mnt/cache``.
    ``realpath`` first, because a symlink from ``~/Github`` into ``/mnt/c`` presents as
    a fast-looking Linux path and is exactly as slow as the target it points at — the
    whole reason this reads the filesystem type instead of the path spelling.
    ``("", "")`` when the mount table is unreadable.
    """
    try:
        target = os.path.realpath(path or ".")
    except OSError:
        target = os.path.abspath(path or ".")
    best = ("", "")
    for mountpoint, fstype in read_mounts(mounts_path):
        if target == mountpoint or target.startswith(mountpoint.rstrip("/") + "/"):
            if len(mountpoint) >= len(best[0]):
                best = (mountpoint, fstype)
    return best


def _looks_like_windows_drive_path(path: str) -> bool:
    """/mnt/<drive-letter>/… — FALLBACK ONLY, when the mount table cannot be read.

    Never the primary test: WSL's automount root is configurable and a bind mount or
    symlink hides the shape entirely, which is why :func:`mount_for` exists.
    """
    parts = os.path.realpath(path or ".").split("/")
    return len(parts) > 2 and parts[1] == "mnt" and len(parts[2]) == 1 and parts[2].isalpha()


def _kvm_state() -> tuple[bool, bool]:
    """(usable, present_but_denied) for /dev/kvm.

    Usable means what the QEMU harness means by it — readable AND writable by this
    user (``run-qemu-docker.sh``: ``[ -r /dev/kvm ] && [ -w /dev/kvm ]``). Mere
    existence is not acceleration: a node the operator has no group membership for
    makes QEMU fall back to TCG just as completely as an absent one, but has a
    different fix, so the two states are kept apart.
    """
    if not os.path.exists("/dev/kvm"):
        return False, False
    if os.access("/dev/kvm", os.R_OK | os.W_OK):
        return True, False
    return False, True


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
    kvm_usable, kvm_denied = _kvm_state()
    return HostInfo(
        os=osname,
        is_gentoo=(osname == "linux" and _is_gentoo()),
        has_docker=_docker_ok(),
        has_bash=bool(shutil.which("bash")),
        has_kvm=kvm_usable,
        is_root=is_root,
        builder_image=builder_image,
        session=detect_session(),
        is_wsl=is_wsl,
        wsl_version=wsl_version,
        # WSL_INTEROP is the socket that makes Windows binaries callable; without it
        # usbipd.exe and friends are unreachable even though we are "on Windows".
        has_win_interop=is_wsl and bool(os.environ.get("WSL_INTEROP")),
        wsl_distro=os.environ.get("WSL_DISTRO_NAME", "") if is_wsl else "",
        kvm_present_but_denied=kvm_denied,
    )

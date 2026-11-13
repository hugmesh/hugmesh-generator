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
import posixpath
import shutil
import subprocess
import sys
from dataclasses import dataclass

#: Session kinds. "none" = no display at all (headless/CI); the GUI cannot run.
SESSION_WAYLAND = "wayland"
SESSION_X11 = "x11"
SESSION_NONE = "none"
#: macOS: Qt's cocoa platform plugin, i.e. a window on the Mac's own desktop. Neither
#: Wayland nor X11 applies, and "none" would have refused the askpass dialog and every
#: "has a GUI" gate on a Mac that plainly has one.
SESSION_COCOA = "cocoa"

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

#: What :func:`docker_probe` found.
DOCKER_OK = "ok"
DOCKER_MISSING = "missing"      # no docker executable on PATH
DOCKER_DOWN = "down"            # docker answered, with an error (engine not running)
DOCKER_TIMEOUT = "timeout"      # docker did not answer within the probe's timeout

#: How long the native-Windows probe waits for `docker info`. Docker Desktop that is
#: starting, or busy with a build, took 9-30 s to answer on a Windows 11 host.
WINDOWS_DOCKER_PROBE_TIMEOUT_S = 20


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
    #: WHY has_docker is False, from :func:`docker_probe`: "missing" (no docker
    #: executable), "down" (it answered with an error), "timeout" (it did not answer in
    #: time); "" when unknown. Native Windows words its remedy from it: a busy Docker
    #: Desktop was told to "Install Docker Desktop".
    docker_state: str = ""
    #: Running inside the Flatpak sandbox. Every other field then describes the HOST,
    #: read through flatpak-spawn --host (core/flatpak_host.py), not the sandbox.
    in_flatpak: bool = False
    #: In the Flatpak: why flatpak-spawn --host could not start a host command ("" when
    #: it could, or outside the Flatpak). Without that route nothing on the host is
    #: reachable, so this outranks every other remedy.
    host_bridge_error: str = ""
    # ── macOS only (core/macos_host.py); left at these defaults everywhere else ──────
    #: "arm64" (Apple silicon) or "x86_64", from the kernel, not platform.machine():
    #: under Rosetta an x86_64 Python says x86_64 on an M-series Mac.
    mac_arch: str = ""
    #: Hypervisor.framework is usable (sysctl kern.hv_support), QEMU's -accel hvf.
    has_hvf: bool = False
    #: Homebrew formulae whose GNU tools (or bash 4+) are missing from PATH; empty when
    #: the generator's bash scripts can run here.
    gnu_missing: tuple = ()
    #: Which Docker runtime answers (macos_host.RUNTIME_*), and the size of its VM —
    #: what a build actually gets, not the Mac's own memory.
    docker_runtime: str = ""
    docker_vm_mem: int = 0
    docker_vm_cpus: int = 0

    @property
    def can_build_native(self) -> bool:
        # The build script is Gentoo+bash and writes a stage4/chroot — only a Gentoo
        # host (ideally root) can run it natively. Everyone else uses Docker. Never from
        # the Flatpak: see flatpak_host.native_build_blocker for the two measured reasons.
        return (self.os == "linux" and self.is_gentoo and self.has_bash
                and not self.in_flatpak)

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
        return self.session in (SESSION_WAYLAND, SESSION_X11, SESSION_COCOA)

    @property
    def is_macos(self) -> bool:
        return self.os == "darwin"

    @property
    def needs_amd64_platform(self) -> bool:
        """An Apple-silicon Mac: the builder image is x86_64 (Dockerfile.build fetches an
        amd64 Gentoo stage3), so every builder ``docker build``/``docker run`` must say
        ``--platform linux/amd64``. Without it Docker builds an arm64 image around an
        amd64 stage3, which dies with "exec format error" at the first chroot."""
        return self.os == "darwin" and self.mac_arch == "arm64"

    def docker_platform_args(self) -> list[str]:
        return docker_platform_args(self)

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
        if self.in_flatpak:
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
        if self.in_flatpak:
            from . import flatpak_host
            return flatpak_host.flash_blocker()
        if self.os == "windows":
            # The usbipd steps used to be promised "(below)" and never shown.
            return ("Writing an image to a device needs Linux block devices, which the "
                    "Windows build of the Studio does not have. Run the Studio inside "
                    "WSL2, then hand the drive to WSL from an ADMIN PowerShell:\n"
                    "    winget install usbipd           # once\n"
                    "    usbipd list                     # find the BUSID of your drive\n"
                    "    usbipd bind --busid <BUSID>     # once per device\n"
                    "    usbipd attach --wsl --busid <BUSID>")
        if self.os == "darwin":
            return macos_flash_blocker()
        if self.os != "linux":
            return (f"Writing an image to a device needs Linux block devices; this is "
                    f"{self.os}.")
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
        if self.in_flatpak and self.host_bridge_error:
            from . import flatpak_host
            return flatpak_host.bridge_failure_message(self.host_bridge_error)
        if self.in_flatpak and self.docker_state == DOCKER_MISSING:
            return ("Docker is not installed on this computer (checked outside the Flatpak "
                    "sandbox, through flatpak-spawn --host). Install Docker Engine with "
                    "your distribution's package manager, start it, add your user to the "
                    "'docker' group, then restart the Studio so it checks again.")
        wsl = wsl_docker_remedy(self.is_wsl, self.wsl_version, self.wsl_distro)
        if wsl:
            return wsl
        if self.os == "linux":
            return ("Start the daemon (`sudo systemctl start docker`) and make sure your "
                    "user is in the 'docker' group (`sudo usermod -aG docker $USER`, then "
                    "log out and back in).")
        if self.os == "darwin":
            return macos_docker_remedy(self.docker_state, self.mac_arch)
        # The Studio probes once, at start, so each Windows remedy ends in a restart:
        # nothing re-asks Docker before then.
        if self.os == "windows" and self.docker_state == DOCKER_TIMEOUT:
            # not "it is running": docker.exe also took 40 s to give up on a stopped
            # Docker Desktop on the same host, so the sentence covers both
            return (f"Docker did not answer `docker info` within "
                    f"{WINDOWS_DOCKER_PROBE_TIMEOUT_S} s when the Studio started. If "
                    f"Docker Desktop is not running, start it; if it is still starting, "
                    f"or busy (a running build slows it down), wait until it says the "
                    f"engine is running. Then restart the Studio so it checks again.")
        if self.os == "windows" and self.docker_state == DOCKER_DOWN:
            return ("docker.exe is installed but the Docker engine does not answer: start "
                    "Docker Desktop, wait until it says the engine is running, then "
                    "restart the Studio so it checks again.")
        return "Install Docker Desktop and start it."

    def docker_blocker(self) -> str:
        """Symptom + fix, self-contained — for surfaces that show this text alone."""
        if self.has_docker:
            return ""
        if self.os == "windows" and self.docker_state == DOCKER_TIMEOUT:
            return self.docker_remedy()     # slow, not unreachable: the remedy says so
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
        if self.in_flatpak and self.host_bridge_error:
            from . import flatpak_host
            return flatpak_host.bridge_failure_message(self.host_bridge_error)
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
        if self.os == "darwin":
            return macos_kvm_note(self.mac_arch, self.has_hvf)
        if self.os != "linux":
            return (f"{head}\nKVM is a Linux kernel feature; this is {self.os}.")
        return (f"{head}\nLoad the KVM module for your CPU (`sudo modprobe kvm_intel` or "
                f"`kvm_amd`) and enable VT-x/AMD-V virtualisation in the firmware setup.")

    def summary(self) -> str:
        bits = [f"OS={self.os}"]
        if self.mac_arch:
            bits.append(self.mac_arch)
        if self.in_flatpak:
            bits.append("Flatpak")
        if self.is_wsl:
            bits.append(f"WSL{self.wsl_version or ''}")
        if self.is_gentoo:
            bits.append("Gentoo")
        if self.session != SESSION_NONE:
            bits.append(self.session)
        if not self.has_docker and self.os == "windows" and \
                self.docker_state == DOCKER_TIMEOUT:
            bits.append(f"docker (did not answer in {WINDOWS_DOCKER_PROBE_TIMEOUT_S} s)")
        elif self.has_docker and self.docker_runtime:
            vm = f", {self.docker_vm_mem / 2**30:.0f} GiB VM" if self.docker_vm_mem else ""
            bits.append(f"docker({self.docker_runtime}{vm})")
        else:
            bits.append("docker" if self.has_docker else "no-docker")
        if self.has_kvm:
            bits.append("KVM")
        if self.has_hvf:
            bits.append("HVF")
        if self.gnu_missing:
            bits.append("no-GNU-userland")
        if self.is_root:
            bits.append("root")
        return " · ".join(bits)


def docker_platform_args(host) -> list[str]:
    """``["--platform", "linux/amd64"]`` for every builder-image ``docker build`` and
    ``docker run`` on an Apple-silicon Mac, [] everywhere else (so a Linux or Windows
    argv stays byte-identical). Takes any host object (a test's stand-in included)."""
    if getattr(host, "os", "") == "darwin" and getattr(host, "mac_arch", "") == "arm64":
        return ["--platform", "linux/amd64"]
    return []


def docker_engine_cpus(host) -> int:
    """The CPU count of the Docker ENGINE a build on ``host`` runs in, where that is not
    the host's own and is known: a Mac's Docker VM (``docker info`` NCPU, probed by
    detect()). 0 on every other host and when the probe did not answer.

    It is the ceiling for a builder's ``--cpus`` (resource_limits.clamp_cpus): dockerd
    refuses a container that asks for more CPUs than it has, and the auto cap is counted
    from the MAC's cores. Takes any host object (a test's stand-in included)."""
    if getattr(host, "os", "") != "darwin":
        return 0
    try:
        return max(0, int(getattr(host, "docker_vm_cpus", 0) or 0))
    except (TypeError, ValueError):
        return 0


def folds_case(path: str) -> "bool | None":
    """Does the filesystem holding ``path`` (or its nearest existing parent) ignore
    case? True on APFS's and NTFS's defaults, False on ext4/btrfs/xfs and on a
    case-sensitive APFS volume; None when it cannot be told (nothing writable there).

    Asked of the filesystem itself, by creating a file with an upper-case name and
    looking for its lower-case spelling, not inferred from the OS: a Mac can have a
    case-sensitive volume, and that is exactly the remedy for a build that needs one."""
    d = os.path.abspath(path or ".")
    while not os.path.isdir(d):
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent
    import tempfile
    try:
        fd, probe = tempfile.mkstemp(prefix="HmCaseProbe.", dir=d)
    except OSError:
        return None
    os.close(fd)
    try:
        return os.path.exists(os.path.join(d, os.path.basename(probe).lower()))
    finally:
        try:
            os.unlink(probe)
        except OSError:
            pass


#: The smallest Docker VM a Mac build is sized for (the 16 GB the docs ask for, less
#: what the VM's own kernel keeps back from MemTotal).
MAC_VM_MIN_BYTES = 15 * 2**30


def macos_build_warnings(host) -> list[str]:
    """What a docker build on a Mac should be told before it starts. Advisory only."""
    out = ["Building on a Mac is EXPERIMENTAL: the build runs in the Linux VM of Docker "
           "Desktop, colima or OrbStack, writing its Gentoo chroot into a folder shared "
           "from macOS, and that has not been proven end to end yet. If it fails, the "
           "build log names the step; a Linux machine (or a Linux VM) is the proven "
           "route."]
    if getattr(host, "mac_arch", "") == "arm64":
        out.append("Apple silicon: the builder image is x86_64, so the whole build runs "
                   "under x86_64 emulation inside the Docker VM (Rosetta when it is "
                   "turned on, otherwise QEMU). Expect it to take 2-5 times as long, and "
                   "do not mistake a slow step for a hang.")
    mem = getattr(host, "docker_vm_mem", 0) or 0
    if 0 < mem < MAC_VM_MIN_BYTES:
        out.append(f"Docker's VM has {mem / 2**30:.1f} GiB of memory; a build wants at "
                   f"least 16 GB. Raise it in Docker Desktop (Settings -> Resources) or "
                   f"restart colima with --memory 16.")
    # The CPU cap is counted from the Mac's cores and the VM usually has fewer: say so
    # when it was lowered to what the VM has (never silently, and before the build).
    from . import resource_limits
    out += resource_limits.engine_cpu_warnings(docker_engine_cpus(host))
    return out


def _is_gentoo(in_flatpak: bool = False) -> bool:
    if in_flatpak:
        # The sandbox's /etc is the runtime's ("KDE Flatpak runtime"); the host's
        # os-release is mounted at /run/host/os-release.
        from . import flatpak_host
        return "gentoo" in flatpak_host.host_os_release().lower()
    try:
        if os.path.exists("/etc/gentoo-release"):
            return True
        with open("/etc/os-release", encoding="utf-8") as fh:
            return "gentoo" in fh.read().lower()
    except OSError:
        return False


def docker_probe(osname: str | None = None, *, which=None, run=None) -> str:
    """Can this host reach a Docker daemon? One of the ``DOCKER_*`` states.

    `docker info` is the real "daemon reachable?" check (Windows: Docker Desktop).
    On native Windows it is run without a console and without pipes, and waits
    longer: from the windowed MSI each docker.exe got a console of its own, which
    alone pushed `docker info` past 8 s; the CLI's com.docker.cli.exe child kept a
    captured pipe open after the timeout killed docker.exe, so the "8 s" ran to
    20-30 s; and a busy Docker Desktop can take longer than 8 s anyway. A timeout is
    kept apart from "no docker", so the remedy can say what happened. ``osname`` is
    ``os.name`` unless a test passes another; ``which``/``run`` are for tests."""
    which, run = which or shutil.which, run or subprocess.run
    exe = which("docker")
    if not exe:
        return DOCKER_MISSING
    if (osname or os.name) != "nt":
        try:
            r = run([exe, "info"], capture_output=True, timeout=8)
        except subprocess.TimeoutExpired:
            return DOCKER_TIMEOUT
        except (OSError, subprocess.SubprocessError):
            return DOCKER_DOWN
        return DOCKER_OK if r.returncode == 0 else DOCKER_DOWN
    try:
        r = run([exe, "info"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, timeout=WINDOWS_DOCKER_PROBE_TIMEOUT_S,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000))
    except subprocess.TimeoutExpired:
        return DOCKER_TIMEOUT
    except (OSError, subprocess.SubprocessError):
        return DOCKER_DOWN
    return DOCKER_OK if r.returncode == 0 else DOCKER_DOWN


def _docker_ok() -> bool:
    return docker_probe() == DOCKER_OK


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


def unquote_pasted_path(text: str, osname: str | None = None) -> str:
    """``text`` without the double quotes Explorer's "Copy as path" puts around a path,
    on native Windows; ``text`` unchanged anywhere else, or when it is not one quoted
    path. A Windows file name cannot contain a double quote, so on nt a pair around the
    whole text can only be that wrapping, never part of the path. Elsewhere a quote is
    a legal file-name character, so nothing is touched. ``osname`` is ``os.name``
    unless a test passes another."""
    if (osname or os.name) != "nt":
        return text
    t = (text or "").strip()
    if len(t) >= 2 and t[0] == t[-1] == '"' and '"' not in t[1:-1]:
        return t[1:-1]
    return text


def is_terminal(stream, osname: str | None = None, console_mode=None) -> bool:
    """Is ``stream`` a terminal someone can type into? ``isatty()``, except on native
    Windows, where the NUL device (``< NUL``, ``stdin=DEVNULL``, a job with no input)
    is a character device and so ``isatty()`` says True: there it is a terminal only
    when the console answers ``GetConsoleMode`` for its handle. Without that check
    ``getpass`` (which reads the console keyboard on Windows, not stdin) waited for a
    key that a script or CI job never presses. A stream with no file descriptor (a
    test's fake) is taken at its ``isatty()`` word. ``osname`` is ``os.name`` and
    ``console_mode(handle) -> bool`` asks the console, unless a test passes others."""
    try:
        if stream is None or not stream.isatty():
            return False
    except (AttributeError, ValueError, OSError):
        return False
    if (os.name if osname is None else osname) != "nt":
        return True
    try:
        fd = stream.fileno()
    except (AttributeError, ValueError, OSError):
        return True
    try:
        import msvcrt
        handle = msvcrt.get_osfhandle(fd)
    except (ImportError, OSError, ValueError):
        return False
    if console_mode is None:
        console_mode = _windows_console_mode
    return bool(console_mode(handle))


def _windows_console_mode(handle) -> bool:
    try:
        import ctypes
        mode = ctypes.c_uint32()
        return bool(ctypes.windll.kernel32.GetConsoleMode(ctypes.c_void_p(handle),
                                                          ctypes.byref(mode)))
    except (AttributeError, OSError, ValueError):
        return False


def host_kind(osname: str | None = None, sysplatform: str | None = None) -> str:
    """"windows", "darwin" or "linux": the ONE question every platform branch asks.

    ``os.name`` alone cannot tell a Mac from Linux (both are "posix"), which is why a Mac
    used to take every Linux branch silently. ``osname`` is ``os.name`` and
    ``sysplatform`` is ``sys.platform`` unless a test passes others, so the darwin
    branches are exercised on Linux with ``sysplatform="darwin"``."""
    if (osname or os.name) == "nt":
        return "windows"
    if (sysplatform or sys.platform) == "darwin":
        return "darwin"
    return "linux"


def builds_in_docker_vm(osname: str | None = None, sysplatform: str | None = None) -> bool:
    """Every image build on this host runs in a Linux VM's Docker (Docker Desktop on
    Windows; Docker Desktop, colima or OrbStack on a Mac), never natively: no "native"
    backend to offer, and a binfmt registration or a memory figure that matters is the
    VM's, which this process cannot read."""
    return host_kind(osname, sysplatform) in ("windows", "darwin")


class HostBlocker(str):
    """A :func:`host_script_blocker` sentence that remembers WHICH host it refuses.

    The sentence is a plain ``str`` to everything that shows it. ``kind`` ("windows" or
    "darwin") is for the consumers that ADD advice to it: "use QEMU for Windows (WHPX)",
    "start Ollama for Windows", "install the vault CLI on Windows" are true for the MSI
    and nonsense on a Mac that is only missing Homebrew's GNU tools. Before this, a
    non-empty blocker MEANT native Windows, and a Mac was told all of that.

    Read it with :func:`blocker_kind`, from the value a blocker function returned and
    BEFORE formatting it: an f-string, ``html.escape`` or ``+`` gives back a plain str.
    """

    kind: str = ""

    def __new__(cls, text: str = "", kind: str = "") -> "HostBlocker":
        self = super().__new__(cls, text)
        self.kind = kind
        return self


def blocker_kind(blocker) -> str:
    """"windows", "darwin" or "" (no blocker): the host a blocker sentence refuses.

    A plain non-empty ``str`` is "windows": that is what a non-empty blocker meant
    before a Mac could be refused, and what a caller's (or a test's) own stand-in
    sentence still means. Only a :class:`HostBlocker` made for a Mac says "darwin"."""
    if not blocker:
        return ""
    return getattr(blocker, "kind", "") or "windows"


def blocker_lines(blocker: str) -> list[str]:
    """The sentence as display lines. The Windows one is a single line; the Mac one
    carries its ``brew install`` command on a line of its own, so a face that joins or
    wraps text (HTML drops a newline, a text screen indents by line) keeps the command
    apart from the prose and copyable by itself."""
    return [ln for ln in str(blocker).splitlines() if ln.strip()]


def host_script_blocker(action: str, osname: str | None = None,
                        runs: str = "`make` and bash scripts", *,
                        sysplatform: str | None = None,
                        gnu_missing: "list[str] | tuple[str, ...] | None" = None) -> str:
    """WHY ``action`` cannot run the generator's bash/make verbs on this host, with the
    fix; "" when it can (Linux, WSL, and a Mac with a GNU userland).

    * native Windows (the MSI): the Win32 Studio cannot run them at all; WSL2 is the
      supported Windows runtime (the module docstring), so that is what it says.
    * macOS: they run, once bash 4+ and the GNU tools are installed. /bin/bash is 3.2
      and sed/find/grep/stat are BSD, and the scripts die mid-run on a flag the BSD tool
      does not have, naming the flag and not the cause. ``gnu_missing`` is the list
      core/macos_host.gnu_userland_missing() returns, probed once when not given.

    The answer is a :class:`HostBlocker`: a str that also says which of the two it is
    (:func:`blocker_kind`), for the callers that add platform advice of their own.

    ``osname`` / ``sysplatform`` are ``os.name`` / ``sys.platform`` unless a test passes
    others."""
    kind = host_kind(osname, sysplatform)
    if kind == "windows":
        return HostBlocker(
            f"{action} runs {runs} from a hugmesh-generator checkout, "
            f"which the Windows build of the Studio cannot run. On Windows, run the "
            f"Studio inside WSL2 instead: in a WSL2 distro (Ubuntu) with Docker "
            f"Desktop's WSL integration turned on for it, clone hugmesh-generator into "
            f"~ (not /mnt/c) and start the Linux build of the Studio from that "
            f"checkout; WSLg shows its window on the Windows desktop.", "windows")
    if kind != "darwin":
        return ""
    missing = list(_gnu_missing_cached() if gnu_missing is None else gnu_missing)
    if not missing:
        return ""
    from .macos_host import BREW_INSTALL
    what = ", ".join("bash 4 or newer (macOS ships 3.2)" if m == "bash" else m
                     for m in missing)
    return HostBlocker(
        f"{action} runs {runs} written for bash 4 and the GNU tools, and this Mac is "
        f"missing: {what}. Install them with Homebrew (https://brew.sh):\n"
        f"    {BREW_INSTALL}\n"
        f"then restart the Studio. You do not need to change your shell or PATH: the "
        f"Studio puts Homebrew's GNU tools first for every command it runs.", "darwin")


def native_windows_blocker(action: str, osname: str | None = None,
                           runs: str = "`make` and bash scripts") -> str:
    """WHY ``action`` cannot run here, with the fix. "" when it can.

    The name is historical (it began as the MSI's sentence) and its ~45 call sites keep
    it: it is :func:`host_script_blocker`, so a Mac without a GNU userland is now refused
    here too, with the ``brew install`` line, instead of being let through to a script
    that dies on a BSD flag. The Windows wording is unchanged: every local-mesh and
    DevOps verb is a `make` target whose recipes are bash scripts, and
    C:\\Windows\\System32\\bash.exe is the WSL launcher, which runs a script inside the
    Linux VM where a C:\\ checkout path means nothing. ``runs`` names what ``action``
    actually needs (Go Live, cloud deploy and the phone wizard are bash drivers with no
    `make` in them). ``osname`` is ``os.name`` unless a test passes another.

    A caller that ADDS platform advice to the sentence must ask :func:`blocker_kind`
    which host it is for: non-empty no longer means Windows."""
    return host_script_blocker(action, osname, runs)


def native_build_blocker(what: str = "A native build", osname: str | None = None,
                         sysplatform: str | None = None, *, host_os: str | None = None) -> str:
    """WHY the NATIVE backend (sudo + bash + a Gentoo chroot) cannot run here; "" when
    it can be tried. Not :func:`host_script_blocker`: a Mac WITH the GNU tools still
    cannot build natively, because the builders write a Gentoo stage4 through chroot,
    loop devices and mount, which macOS does not have. Both say what to use instead.

    ``host_os`` is a driver's ``HostInfo.os`` and, when given, is the answer: the
    driver builds for the host it was handed (detect() on the real machine, a canned
    host in a test). Without it the process's own ``os.name`` / ``sys.platform``
    decide (``osname`` / ``sysplatform`` for tests)."""
    if host_os is not None:
        kind = host_os if host_os in ("windows", "darwin") else "linux"
    else:
        kind = host_kind(osname, sysplatform)
    if kind == "windows":
        return (f"{what} runs sudo and bash on a Gentoo host, which the Windows build of "
                f"the Studio cannot do. Choose the docker backend (Docker Desktop), or run "
                f"the Studio inside WSL2.")
    if kind == "darwin":
        return (f"{what} runs a Gentoo chroot as root (sudo, bash, loop devices, mount), "
                f"which only a Linux host can do. On a Mac choose the docker backend: the "
                f"build runs in the Linux VM of Docker Desktop, colima or OrbStack.")
    return ""


_GNU_MISSING: "list[str] | None" = None


def _gnu_missing_cached() -> list[str]:
    """macos_host.gnu_userland_missing(), once per process: it starts six probes, and
    the blocker is asked on every page refresh. Read AFTER macos_host.install() has put
    Homebrew on PATH, so an installed GNU userland is found: every process entry (the
    window, the text UI, each module command line) calls core/entry.bootstrap() first."""
    global _GNU_MISSING
    if _GNU_MISSING is None:
        from .macos_host import gnu_userland_missing
        _GNU_MISSING = gnu_userland_missing()
    return _GNU_MISSING


def macos_docker_remedy(docker_state: str = "", mac_arch: str = "") -> str:
    """How to give a Mac a Docker that answers. The Mac's own memory does not matter to
    a build: it runs in the runtime's Linux VM, sized in that runtime's settings."""
    rosetta = ("" if mac_arch != "arm64" else
               " On Apple silicon also turn on \"Use Rosetta for x86_64/amd64 emulation on "
               "Apple Silicon\" (Docker Desktop: Settings -> General), or start colima "
               "with --vz-rosetta: the builder image is x86_64.")
    # Rosetta translates x86_64 for an ARM VM, so it is Apple silicon's flag only; an
    # Intel Mac runs the x86_64 builder natively and says --arch x86_64 instead
    # (docs/STUDIO-INSTALLERS.md gives the same two lines).
    colima_flags = (" --vz-rosetta --cpu 8 --memory 16 --disk 200" if mac_arch == "arm64"
                    else " --cpu 8 --memory 16 --disk 200 --arch x86_64")
    sizing = (f" Give the VM at least 16 GB of memory and a 200 GB disk (Docker Desktop: "
              f"Settings -> Resources; colima: `colima start --vm-type vz"
              f"{colima_flags}`). A build uses at most the VM's CPUs; HUGMESH_CPUS sets a "
              f"lower cap.{rosetta}")
    if docker_state == DOCKER_MISSING or not docker_state:
        return ("No docker command was found (the Studio looked in Homebrew, Docker "
                "Desktop's and colima's folders too). Install one Docker runtime: Docker "
                "Desktop for Mac, or `brew install colima docker`, or OrbStack; start it, "
                "then restart the Studio so it checks again." + sizing)
    if docker_state == DOCKER_TIMEOUT:
        return ("Docker did not answer `docker info` in time when the Studio started. If "
                "its VM is still starting, wait until it is up, then restart the Studio "
                "so it checks again." + sizing)
    return ("docker is installed but no engine answers: start Docker Desktop (or "
            "`colima start`, or OrbStack) and wait until it is running, then restart the "
            "Studio so it checks again." + sizing)


def macos_kvm_note(mac_arch: str = "", has_hvf: bool = False) -> str:
    """What emulated devices cost on a Mac. A warning, like the KVM one: the run still
    succeeds, it is just slow enough to read as a hang."""
    head = ("macOS has no /dev/kvm, and the Docker VM the QEMU harness runs in has none "
            "either, so emulated devices run under full emulation (TCG): expect x86 rows "
            "to take hours rather than minutes, which reads as a hang.")
    if mac_arch == "arm64":
        head += (" On Apple silicon every x86_64 row is emulated whatever the "
                 "accelerator; only aarch64 rows could ever run at native speed.")
    hvf = ("Hypervisor.framework is available on this Mac (QEMU's -accel hvf), but the "
           "Studio does not drive a native macOS QEMU yet."
           if has_hvf else
           "Hypervisor.framework is not available on this Mac (sysctl kern.hv_support "
           "is 0), so QEMU could not accelerate here at all.")
    return f"{head}\n{hvf}"


def macos_flash_blocker() -> str:
    """Flashing from a Mac, by hand. The Studio's writer (scripts/flash-disk.sh) reads
    lsblk and Linux sysfs and cannot run here; until a diskutil writer with the same
    safety checks exists, the commands are given rather than a dead end."""
    return ("The Studio cannot write an image to a device on macOS yet (its writer uses "
            "Linux block devices). Do it in Terminal, and check the disk number twice: "
            "/dev/disk0 is the Mac's own disk.\n"
            "    diskutil list external physical        # find /dev/diskN, your card or stick\n"
            "    diskutil unmountDisk /dev/diskN\n"
            "    sudo dd if=<image>.img of=/dev/rdiskN bs=4m\n"
            "    diskutil eject /dev/diskN\n"
            "For a .img.xz, decompress it first (`brew install xz`, then `xz -dk <image>.img.xz`).")


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
    mounts = read_mounts(mounts_path)
    if not mounts:
        # Checked before resolving: on native Windows (the MSI) there is no
        # /proc/mounts, and a C:\ path has no business going through POSIX rules.
        return ("", "")
    target = _resolve_linux_path(path)
    best = ("", "")
    for mountpoint, fstype in mounts:
        if target == mountpoint or target.startswith(mountpoint.rstrip("/") + "/"):
            if len(mountpoint) >= len(best[0]):
                best = (mountpoint, fstype)
    return best


def _resolve_linux_path(path: str) -> str:
    """``realpath`` for a path that is matched against the Linux kernel's mount table.

    A path rooted at ``/`` is a Linux path, so it is resolved under POSIX rules even on
    a Windows interpreter, where ``ntpath`` would turn ``/mnt/c/…`` into
    ``C:\\mnt\\c\\…``, match no mountpoint and silence the warning. Anything else is
    the host's own spelling and goes through ``os.path``. On Linux and WSL
    ``posixpath`` IS ``os.path``, so nothing changes there.
    """
    pathmod = posixpath if (path or "").startswith("/") else os.path
    try:
        return pathmod.realpath(path or ".")
    except OSError:
        return pathmod.abspath(path or ".")


def _looks_like_windows_drive_path(path: str) -> bool:
    """/mnt/<drive-letter>/… — FALLBACK ONLY, when the mount table cannot be read.

    Never the primary test: WSL's automount root is configurable and a bind mount or
    symlink hides the shape entirely, which is why :func:`mount_for` exists.
    """
    parts = _resolve_linux_path(path).split("/")
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


def detect_session(sysplatform: str | None = None, environ=None) -> str:
    """Which display server is actually in use.

    Order matters. ``XDG_SESSION_TYPE`` is the declared answer but is routinely wrong or
    absent (it says "tty" under a display manager that did not set it, and is unset
    entirely inside containers and over ssh), so the concrete sockets are checked FIRST
    and the declaration is only a tie-breaker. ``WAYLAND_DISPLAY`` set means a Wayland
    compositor is reachable; a bare ``DISPLAY`` means X11 — including XWayland, which is
    the right answer for Qt because in that case Qt IS an X11 client and ``move()``
    works again.

    macOS has neither: Qt draws through cocoa on the Mac's own desktop. The one Mac
    session that cannot show a window is a login over ssh, whose processes have no
    connection to the WindowServer, so that alone is "none".
    """
    env = os.environ if environ is None else environ
    if (sysplatform or sys.platform) == "darwin":
        if env.get("SSH_CONNECTION") or env.get("SSH_TTY"):
            return SESSION_NONE
        return SESSION_COCOA
    if env.get("WAYLAND_DISPLAY"):
        # XWayland: a Wayland compositor is up, but Qt was told to be an X11 client, so
        # it gets X11 semantics. Believe the override.
        if env.get("QT_QPA_PLATFORM", "").strip().lower() in ("xcb", "x11"):
            return SESSION_X11
        return SESSION_WAYLAND
    if env.get("DISPLAY"):
        return SESSION_X11
    declared = env.get("XDG_SESSION_TYPE", "").strip().lower()
    if declared in (SESSION_WAYLAND, SESSION_X11):
        return declared
    return SESSION_NONE


def detect_wsl() -> tuple[bool, int]:
    """(is_wsl, version). WSL2 is a real kernel; WSL1 is a syscall shim.

    The distinction is relied on, not trivia: WSL1 cannot run Docker's daemon or
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
    from . import flatpak_host
    in_flatpak = osname == "linux" and flatpak_host.in_flatpak()
    bridge_error = ""
    if in_flatpak:
        # Everything below is about the HOST, which the sandbox reaches only through
        # flatpak-spawn --host (installed by app.main via flatpak_host.install()).
        bridge_ok, bridge_error = flatpak_host.bridge_status()
        kvm_usable, kvm_denied = (flatpak_host.host_kvm_state() if bridge_ok
                                  else (False, False))
        docker_state = docker_probe() if bridge_ok else DOCKER_MISSING
    else:
        kvm_usable, kvm_denied = _kvm_state()
        docker_state = docker_probe()
    mac: dict = {}
    if osname == "darwin":
        from . import macos_host
        vm = macos_host.docker_vm() if docker_state == DOCKER_OK else macos_host.DockerVM()
        mac = {"mac_arch": macos_host.mac_arch(), "has_hvf": macos_host.hvf_available(),
               "gnu_missing": tuple(_gnu_missing_cached()), "docker_runtime": vm.runtime,
               "docker_vm_mem": vm.mem_bytes, "docker_vm_cpus": vm.cpus}
        # Every lane that hands Docker a CPU cap (a build's --cpus, the local stack's
        # and the mesh node's compose overlays) is held to the VM's CPU count, which
        # dockerd refuses to exceed. The lanes with no HostInfo read it from here.
        from . import resource_limits
        resource_limits.set_engine_cpus(vm.cpus)
    return HostInfo(
        os=osname,
        is_gentoo=(osname == "linux" and _is_gentoo(in_flatpak)),
        has_docker=docker_state == DOCKER_OK,
        docker_state=docker_state,
        has_bash=bool(shutil.which("bash")),
        has_kvm=kvm_usable,
        is_root=is_root,
        builder_image=builder_image,
        session=detect_session(sysplatform="darwin" if osname == "darwin" else None),
        is_wsl=is_wsl,
        wsl_version=wsl_version,
        # WSL_INTEROP is the socket that makes Windows binaries callable; without it
        # usbipd.exe and friends are unreachable even though we are "on Windows".
        has_win_interop=is_wsl and bool(os.environ.get("WSL_INTEROP")),
        wsl_distro=os.environ.get("WSL_DISTRO_NAME", "") if is_wsl else "",
        kvm_present_but_denied=kvm_denied,
        in_flatpak=in_flatpak,
        host_bridge_error=bridge_error,
        **mac,
    )

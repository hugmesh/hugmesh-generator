"""QEMU for Windows (WHPX) — the native Windows device-emulation backend.

OPERATOR ASK (2026-11-04): "find a qemu equivalent and use that as an option on windows
for device emulation and work that into the gui/TUI/CLI", with "only test small thin
desktop device images or single nodes on this machine due to resources".

Every other emulation lane is a bash script (tests/qemu/run-qemu-docker.sh and its
launch-*.sh), which the Windows Studio cannot run, so they are refused there with the
WSL2 sentence (:func:`qemu_tests.native_blocker`). This module is the lane that DOES
run on Windows: QEMU's own Windows build (``winget install
SoftwareFreedomConservancy.QEMU``) accelerated by the Windows Hypervisor Platform
(``-accel whpx``), driven from Python with no bash, no Docker and no WSL2.

It boots ONE x86 device at a time — a thin desktop image or a single node — the same
way tests/qemu/launch-x86.sh does:

* q35 + UEFI (QEMU's bundled ``share\\edk2-x86_64-code.fd``, with a per-run copy of
  ``edk2-i386-vars.fd`` as the variable store), no ``-kernel``: the image self-boots
  through GRUB-EFI on its ESP;
* an explicit ``-cpu`` (:data:`CPU_MODELS`): the images are built for x86-64-v2, and
  QEMU's default ``qemu64`` model lacks it (SSE4.2, POPCNT, …);
* the golden image is never written: a qcow2 overlay per run (``qemu-img create -b
  … -F raw``), and a ``.img.xz`` is first unpacked once into ``<work>/native-images``;
* user-mode networking with the launcher's port map, bound to 127.0.0.1 only
  (2222->22 ssh, 8443->443, 8080->80);
* headless (serial console to ``console.log``) or with a desktop window
  (``-display sdl`` + ``virtio-gpu-pci``) for a thin desktop;
* QMP on a 127.0.0.1 TCP port (Windows QEMU cannot ``-daemonize`` and a polite
  taskkill does not reach it), so Stop is ``system_powerdown`` then ``quit``. Any local
  account can reach that port while the device runs. A ``-qmp pipe:`` (an owner-only
  DACL) is not used: QEMU's Windows pipe chardev blocks start-up until a client
  connects and serves one connection for the process's life, so a later Stop could
  never reach it.

What it refuses, with a sentence: any host but Windows (use the docker lane there),
QEMU or its firmware missing (the winget command), the hypervisor platform off (the
DISM command), ARM/Pi rows (WHPX accelerates x86_64 guests only on an x64 PC, and
those rows boot a kernel lifted out of the image), a second device while one runs, and
a start the free memory cannot hold. TCG (no acceleration) is an explicit opt-in.

The GUI, the TUI and the CLI (``python -m hugmesh_studio.core.qemu_windows``, also
``hugmesh-studio-cli --qemu-windows …`` in the MSI) all go through the functions
below, and preview the SAME argv (:func:`preview_lines`).
"""
from __future__ import annotations

import argparse
import dataclasses
import json
import lzma
import os
import shlex
import shutil
import socket
import subprocess
import sys
import time

from . import proc_text

BACKEND_DOCKER = "docker"
BACKEND_WHPX = "whpx"
#: (id, label) for every face's backend chooser — one tuple so the GUI selector, the
#: TUI key and the CLI ``--backend`` choices can never drift.
BACKENDS = ((BACKEND_DOCKER, "Docker container (Linux or WSL2)"),
            (BACKEND_WHPX, "QEMU for Windows (WHPX)"))
#: The Docker backend's label on a Mac, where it runs in neither Linux nor WSL2 but in
#: the Linux VM of Docker Desktop, colima or OrbStack.
DOCKER_LABEL_MACOS = "Docker container (this Mac's Docker VM)"


def backends(osname: str | None = None, sysplatform: str | None = None) -> tuple:
    """:data:`BACKENDS` as THIS host's chooser shows them: the same ids in the same
    order, with the Docker backend's label in the Mac's words on a Mac. Everywhere
    else it is :data:`BACKENDS` itself."""
    from . import platform_info
    if platform_info.host_kind(osname, sysplatform) != "darwin":
        return BACKENDS
    return tuple((bid, DOCKER_LABEL_MACOS if bid == BACKEND_DOCKER else label)
                 for bid, label in BACKENDS)

WINGET_ID = "SoftwareFreedomConservancy.QEMU"
INSTALL_HINT = f"winget install --id {WINGET_ID} -e"
WHPX_HINT = ("DISM /Online /Enable-Feature /FeatureName:HypervisorPlatform /All "
             "(in an administrator terminal), then restart Windows")

QEMU_EXE = "qemu-system-x86_64.exe"
QEMU_IMG_EXE = "qemu-img.exe"
CODE_FD = "edk2-x86_64-code.fd"
VARS_FD = "edk2-i386-vars.fd"

#: Under the emulation work dir (``<generator>/out/qemu-runs`` by default).
NATIVE_DEVICES_SUBDIR = "native-devices"
NATIVE_IMAGES_SUBDIR = "native-images"
NATIVE_RUNS_SUBDIR = "native-runs"

#: Small on purpose: this lane is for thin desktops and single nodes on an ordinary
#: Windows PC (the launcher's 4096 MiB / 4 CPUs are for a build host).
DEFAULT_MEM_MB = 2048
DEFAULT_SMP = 2
#: Kept free for Windows itself on top of the guest's memory.
HOST_RESERVE_MB = 768
DISPLAYS = ("none", "window")
#: ``-cpu`` per accelerator. TCG: ``max``, what tests/qemu/launch-x86.sh falls back to.
#: WHPX: Nehalem, the oldest named model with the whole x86-64-v2 baseline the images
#: are compiled for (specs-x86/portage/make.conf.tmpl). Hyper-V answers most CPUID
#: leaves itself under WHPX, so this is QEMU's view, kept no lower than the images.
CPU_MODELS = {"whpx": "Nehalem", "tcg": "max"}

_WHPX_DLL = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32",
                         "WinHvPlatform.dll")


class NativeError(RuntimeError):
    """A refusal or failure, already worded as the sentence the operator sees."""


# ── finding QEMU ─────────────────────────────────────────────────────────────────────
@dataclasses.dataclass(frozen=True)
class QemuInstall:
    dir: str
    system: str            # qemu-system-x86_64.exe
    img: str               # qemu-img.exe
    code_fd: str           # UEFI code (read-only pflash)
    vars_fd: str           # UEFI variable-store template (copied per run)


def _registry_dir() -> str:
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\QEMU") as k:
            return str(winreg.QueryValueEx(k, "Install_Dir")[0])
    except (ImportError, OSError):
        return ""


def _candidate_dirs(env) -> list[str]:
    # The installer records its folder in the registry and does NOT touch PATH.
    dirs = [_registry_dir(),
            os.path.join(env.get("ProgramFiles", r"C:\Program Files"), "qemu")]
    found = shutil.which("qemu-system-x86_64")
    if found:
        dirs.append(os.path.dirname(found))
    out = []
    for d in dirs:
        if d and d not in out:
            out.append(d)
    return out


def find_qemu(env=None) -> QemuInstall | None:
    """The first folder holding QEMU, qemu-img and the x86 UEFI firmware."""
    env = os.environ if env is None else env
    for d in _candidate_dirs(env):
        system, img = os.path.join(d, QEMU_EXE), os.path.join(d, QEMU_IMG_EXE)
        if not (os.path.isfile(system) and os.path.isfile(img)):
            continue
        for fw in (os.path.join(d, "share"), d):     # older builds put them in the root
            code, vars_ = os.path.join(fw, CODE_FD), os.path.join(fw, VARS_FD)
            if os.path.isfile(code) and os.path.isfile(vars_):
                return QemuInstall(d, system, img, code, vars_)
    return None


def blocker(osname: str | None = None, *, install=None, whpx_dll: str | None = None,
            accel: str = "whpx") -> str:
    """WHY this backend cannot boot a device here ("" when it can)."""
    if (osname or os.name) != "nt":
        return ("QEMU for Windows is the Windows Studio's emulation backend. On this "
                "system use the Docker backend, which runs the full QEMU lanes.")
    install = find_qemu() if install is None else install
    if not install:
        return (f"QEMU for Windows is not installed (or its UEFI firmware is missing). "
                f"Install it with: {INSTALL_HINT}")
    if accel == "whpx" and not os.path.isfile(whpx_dll or _WHPX_DLL):
        return ("The Windows Hypervisor Platform is off, so QEMU cannot use WHPX "
                f"acceleration. Turn it on with: {WHPX_HINT}.")
    return ""


def row_refusal(platform: str) -> str:
    """WHY a device row cannot boot on this backend ("" for an x86 row)."""
    if platform == "x86":
        return ""
    return (f"{platform} images cannot boot on QEMU for Windows: WHPX accelerates only "
            f"x86_64 guests on this PC, and {platform} rows boot a kernel taken out of "
            f"the image. Use the Docker backend in WSL2 for them.")


# ── options, paths and argv (pure) ───────────────────────────────────────────────────
@dataclasses.dataclass(frozen=True)
class NativeOptions:
    label: str                       # "x86/standalone-thin"
    image: str                       # the .img or .img.xz
    work_dir: str
    platform: str = "x86"
    role: str = ""
    mem_mb: int = DEFAULT_MEM_MB
    smp: int = DEFAULT_SMP
    ssh_port: int = 2222
    ui_port: int = 8443
    http_port: int = 8080
    display: str = "none"            # "none" (headless) | "window" (thin desktop)
    accel: str = "whpx"              # "whpx" | "tcg" (explicit, very slow)
    overlay_size: str = "32G"
    keep: bool = False               # keep the run dir (overlay) after Stop

    def __post_init__(self):
        # Absolute once, here: QEMU runs with the run dir as its cwd, and qemu-img
        # reads a relative -b against the overlay's folder, so a relative --work or
        # image would name files that do not exist where they are opened.
        for name in ("work_dir", "image"):
            value = getattr(self, name)
            if value:
                object.__setattr__(self, name, os.path.abspath(value))


def safe_label(label: str) -> str:
    return "".join(c if c.isalnum() or c in "-." else "_" for c in label)


def run_dir(o: NativeOptions) -> str:
    return os.path.join(o.work_dir, NATIVE_RUNS_SUBDIR, safe_label(o.label))


def base_image(o: NativeOptions) -> str:
    """The raw image QEMU reads: the image itself, or its one-time unpacked copy."""
    if o.image.endswith(".xz"):
        return os.path.join(o.work_dir, NATIVE_IMAGES_SUBDIR,
                            os.path.basename(o.image)[:-3])
    return o.image


def _drive_path(path: str) -> str:
    # QEMU's option parser splits on commas; a comma in a path is written twice.
    return path.replace(",", ",,")


def prepare_argvs(o: NativeOptions, install: QemuInstall) -> list[list[str]]:
    """The qemu-img steps before a boot: a qcow2 overlay over the golden image."""
    overlay = os.path.join(run_dir(o), "run.qcow2")
    return [[install.img, "create", "-q", "-f", "qcow2", "-b", base_image(o), "-F", "raw",
             overlay],
            [install.img, "resize", "-q", overlay, o.overlay_size]]


def launch_argv(o: NativeOptions, install: QemuInstall, qmp_port: int) -> list[str]:
    """``qemu-system-x86_64.exe`` for one device — tests/qemu/launch-x86.sh's argv
    with the Linux-only parts (/dev/kvm, -daemonize, unix QMP, mcast mesh) replaced."""
    rd = run_dir(o)
    fwd = ",".join(f"hostfwd=tcp:127.0.0.1:{h}-:{g}" for h, g in
                   ((o.ssh_port, 22), (o.ui_port, 443), (o.http_port, 80)))
    argv = [install.system,
            "-machine", "q35", "-accel", o.accel, "-cpu", CPU_MODELS.get(o.accel, "max"),
            "-smp", str(o.smp), "-m", str(o.mem_mb), "-no-reboot",
            "-drive", f"if=pflash,format=raw,readonly=on,file={_drive_path(install.code_fd)}",
            "-drive", f"if=pflash,format=raw,file={_drive_path(os.path.join(rd, 'vars.fd'))}",
            "-drive", f"file={_drive_path(os.path.join(rd, 'run.qcow2'))},format=qcow2,"
                      f"if=none,id=hd0",
            "-device", "virtio-blk-pci,drive=hd0",
            "-netdev", f"user,id=net0,{fwd}",
            "-device", "virtio-net-pci,netdev=net0",
            "-qmp", f"tcp:127.0.0.1:{qmp_port},server=on,wait=off",
            "-serial", f"file:{os.path.join(rd, 'console.log')}",
            "-monitor", "none",
            "-pidfile", os.path.join(rd, "qemu.pid")]
    if o.display == "window":
        argv += ["-device", "virtio-gpu-pci", "-display", "sdl"]
    else:
        argv += ["-display", "none"]
    return argv


def _quote(argv: list[str], osname: str | None = None) -> str:
    if (osname or os.name) == "nt":
        return subprocess.list2cmdline(argv)
    return shlex.join(argv)


def preview_lines(o: NativeOptions, install: QemuInstall | None = None,
                  qmp_port: int = 4444, osname: str | None = None) -> list[str]:
    """What a start will run, in order — the one text the GUI, TUI and CLI show."""
    install = install or find_qemu() or _placeholder_install()
    lines = []
    if o.image.endswith(".xz"):
        lines.append(f"# unpack once: {o.image} -> {base_image(o)}")
    lines += [_quote(a, osname) for a in prepare_argvs(o, install)]
    lines.append(f"# copy {install.vars_fd} -> {os.path.join(run_dir(o), 'vars.fd')}")
    lines.append(_quote(launch_argv(o, install, qmp_port), osname))
    return lines


def _placeholder_install() -> QemuInstall:
    d = r"C:\Program Files\qemu"
    return QemuInstall(d, os.path.join(d, QEMU_EXE), os.path.join(d, QEMU_IMG_EXE),
                       os.path.join(d, "share", CODE_FD), os.path.join(d, "share", VARS_FD))


# ── host checks ──────────────────────────────────────────────────────────────────────
def free_memory_mb() -> int | None:
    """Available physical memory, or None when it cannot be read."""
    if os.name == "nt":
        try:
            import ctypes

            class _MemStatus(ctypes.Structure):
                _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong),
                            ("ullTotalPhys", ctypes.c_ulonglong),
                            ("ullAvailPhys", ctypes.c_ulonglong),
                            ("ullTotalPageFile", ctypes.c_ulonglong),
                            ("ullAvailPageFile", ctypes.c_ulonglong),
                            ("ullTotalVirtual", ctypes.c_ulonglong),
                            ("ullAvailVirtual", ctypes.c_ulonglong),
                            ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]
            st = _MemStatus()
            st.dwLength = ctypes.sizeof(_MemStatus)
            if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st)):
                return int(st.ullAvailPhys // (1024 * 1024))
        except (OSError, AttributeError):
            return None
        return None
    try:
        with open("/proc/meminfo", encoding="ascii") as fh:
            for line in fh:
                if line.startswith("MemAvailable:"):
                    return int(line.split()[1]) // 1024
    except (OSError, ValueError, IndexError):
        pass
    return None


def memory_refusal(mem_mb: int, free_mb: int | None) -> str:
    if free_mb is None or free_mb >= mem_mb + HOST_RESERVE_MB:
        return ""
    return (f"Only {free_mb} MiB of memory is free; this device needs {mem_mb} MiB plus "
            f"{HOST_RESERVE_MB} MiB for Windows. Close programs, or stop WSL2 and "
            f"Docker Desktop (`wsl --shutdown`), or lower the device's memory.")


def _port_free(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        try:
            s.bind(("127.0.0.1", port))
            return True
        except OSError:
            return False


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


# ── the device registry (one JSON per device) ───────────────────────────────────────
def devices_dir(work_dir: str) -> str:
    return os.path.join(work_dir, NATIVE_DEVICES_SUBDIR)


def _record_path(work_dir: str, label: str) -> str:
    return os.path.join(devices_dir(work_dir), safe_label(label) + ".json")


def records(work_dir: str) -> list[dict]:
    out = []
    try:
        names = sorted(os.listdir(devices_dir(work_dir)))
    except OSError:
        return out
    for n in names:
        if not n.endswith(".json"):
            continue
        try:
            with open(os.path.join(devices_dir(work_dir), n), encoding="utf-8") as fh:
                rec = json.load(fh)
        except (OSError, ValueError):
            continue
        if isinstance(rec, dict) and rec.get("label") and isinstance(rec.get("pid"), int):
            out.append(rec)
    return out


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    if os.name == "nt":
        import ctypes
        k = ctypes.windll.kernel32
        h = k.OpenProcess(0x1000, False, pid)        # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return False
        try:
            code = ctypes.c_ulong()
            return bool(k.GetExitCodeProcess(h, ctypes.byref(code))) and code.value == 259
        finally:
            k.CloseHandle(h)
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def process_started(pid: int) -> int | None:
    """When ``pid`` was created, as an opaque number (None when it cannot be read).

    A pid alone does not name a process: Windows hands a dead QEMU's pid to the next
    process soon after, so a record names its QEMU by pid AND this."""
    if pid <= 0:
        return None
    if os.name == "nt":
        try:
            import ctypes
            k = ctypes.windll.kernel32
        except (ImportError, AttributeError, OSError):
            return None
        h = k.OpenProcess(0x1000, False, int(pid))   # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return None
        try:
            times = [ctypes.c_ulonglong() for _ in range(4)]   # FILETIMEs, creation first
            if not k.GetProcessTimes(h, *(ctypes.byref(t) for t in times)):
                return None
            return int(times[0].value)
        finally:
            k.CloseHandle(h)
    try:                                       # field 22 (starttime), after "(comm)"
        with open(f"/proc/{int(pid)}/stat", encoding="ascii", errors="replace") as fh:
            return int(fh.read().rsplit(")", 1)[1].split()[19])
    except (OSError, ValueError, IndexError):
        return None


def record_alive(rec: dict, alive=pid_alive, started=process_started) -> bool:
    """Is the record's QEMU still the process at its pid? A dead pid, or one another
    process now holds (a different creation time), is not, and nothing is ever
    stopped or killed through such a record."""
    pid = rec.get("pid")
    if not isinstance(pid, int) or not alive(pid):
        return False
    born = rec.get("started")
    return born is not None and born == started(pid)


def running(work_dir: str, alive=record_alive) -> list[dict]:
    """Records whose QEMU process is still alive. A record left by a crash, a
    shutdown inside the guest or a reboot is not running, whatever it says, and
    even once Windows has given its pid to another process."""
    return [r for r in records(work_dir) if alive(r)]


# ── QMP over 127.0.0.1 TCP ───────────────────────────────────────────────────────────
def qmp(port: int, command: str, timeout: float = 5.0) -> dict:
    """Send one QMP command and return its reply (raises OSError/ValueError)."""
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as s:
        f = s.makefile("rwb")
        json.loads(f.readline())                              # the greeting
        for cmd in ("qmp_capabilities", command):
            f.write(json.dumps({"execute": cmd}).encode() + b"\r\n")
            f.flush()
            while True:
                reply = json.loads(f.readline())
                if "return" in reply or "error" in reply:
                    break                                     # skip async events
        return reply


# ── start / stop ─────────────────────────────────────────────────────────────────────
def _unpack(src: str, dst: str, on_line) -> None:
    if os.path.isfile(dst) and os.path.getmtime(dst) >= os.path.getmtime(src):
        return
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    on_line(f"Unpacking {os.path.basename(src)} once (later starts reuse it)…")
    tmp = dst + ".part"
    try:
        with lzma.open(src, "rb") as fin, open(tmp, "wb") as fout:
            shutil.copyfileobj(fin, fout, 4 * 1024 * 1024)
        os.replace(tmp, dst)
    except BaseException as e:
        # A partial image is gigabytes: never leave one behind, whatever stopped it.
        try:
            os.remove(tmp)
        except OSError:
            pass
        if isinstance(e, (lzma.LZMAError, EOFError, OSError)):   # corrupt .xz, full disk
            raise NativeError(f"{os.path.basename(src)} could not be unpacked into "
                              f"{os.path.dirname(dst)}: {e}") from None
        raise


def _run_quiet(argv: list[str]) -> None:
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=600,
                           **proc_text.TEXT_IO)
    except subprocess.TimeoutExpired:
        raise NativeError(f"{os.path.basename(argv[0])} did not finish in 10 minutes.") \
            from None
    if r.returncode != 0:
        raise NativeError(f"{os.path.basename(argv[0])} failed: "
                          f"{(r.stderr or r.stdout).strip()}")


#: Under devices_dir: the one start in progress (see :func:`_claim`).
_START_CLAIM = ".starting"
#: A claim still empty this soon after it was made is a start that is writing it.
_CLAIM_GRACE_S = 30.0


def _claim(work_dir: str) -> str:
    """Take ``work_dir``'s one start slot before any slow step (unpack, qemu-img, the
    settle), so a second start from another face or process is refused here instead
    of both passing the one-device and free-memory checks. A claim whose process is
    gone is taken over. Returns the claim's path for :func:`start` to remove."""
    d = devices_dir(work_dir)
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, _START_CLAIM)
    for _ in range(2):
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            try:
                with open(path, encoding="utf-8") as fh:
                    other = json.load(fh)
            except (OSError, ValueError):
                other = None
            try:
                young = time.time() - os.path.getmtime(path) < _CLAIM_GRACE_S
            except OSError:
                young = False
            held = (record_alive(other) if isinstance(other, dict) else
                    other is None and young)
            if held:
                pid = other.get("pid", "?") if isinstance(other, dict) else "?"
                raise NativeError(f"Another QEMU for Windows start is in progress "
                                  f"(pid {pid}); wait for it to finish.") from None
            try:
                os.remove(path)                       # its process is gone: stale
            except OSError:
                pass
            continue
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump({"pid": os.getpid(), "started": process_started(os.getpid())}, fh)
        return path
    raise NativeError("Another QEMU for Windows start is in progress; wait for it to "
                      "finish.")


def start(o: NativeOptions, *, install: QemuInstall | None = None, on_line=print,
          osname: str | None = None, free_mb=free_memory_mb,
          popen=subprocess.Popen, settle_s: float = 3.0) -> dict:
    """Boot one device; returns its registry record. Raises :class:`NativeError`."""
    install = install or find_qemu()
    why = (blocker(osname, install=install or False, accel=o.accel)
           or row_refusal(o.platform))
    if why:
        raise NativeError(why)
    if o.accel not in ("whpx", "tcg") or o.display not in DISPLAYS:
        raise NativeError(f"Unknown accel {o.accel!r} or display {o.display!r}.")
    claim = _claim(o.work_dir)
    try:
        return _start_claimed(o, install, on_line=on_line, osname=osname,
                              free_mb=free_mb, popen=popen, settle_s=settle_s)
    finally:
        try:
            os.remove(claim)
        except OSError:
            pass


def _start_claimed(o: NativeOptions, install: QemuInstall, *, on_line, osname,
                   free_mb, popen, settle_s: float) -> dict:
    live = running(o.work_dir)
    if live:
        raise NativeError(f"{live[0]['label']} is already running. This backend runs one "
                          f"device at a time; stop it first.")
    why = memory_refusal(o.mem_mb, free_mb())
    if why:
        raise NativeError(why)
    busy = [p for p in (o.ssh_port, o.ui_port, o.http_port) if not _port_free(p)]
    if busy:
        raise NativeError(f"Port {busy[0]} on 127.0.0.1 is in use: free it, or choose "
                          f"other ports with the CLI's --ssh-port, --ui-port and "
                          f"--http-port.")
    if not os.path.isfile(o.image):
        raise NativeError(f"The image {o.image} does not exist.")

    rd = run_dir(o)
    shutil.rmtree(rd, ignore_errors=True)                     # a fresh overlay each start
    os.makedirs(rd, exist_ok=True)
    if o.image.endswith(".xz"):
        _unpack(o.image, base_image(o), on_line)
    for argv in prepare_argvs(o, install):
        _run_quiet(argv)
    shutil.copyfile(install.vars_fd, os.path.join(rd, "vars.fd"))

    port = _free_port()
    argv = launch_argv(o, install, port)
    on_line(_quote(argv, osname))
    log = open(os.path.join(rd, "qemu.log"), "wb")
    kw = {}
    if (osname or os.name) == "nt":
        # getattr: the flags exist only in a Windows Python (tests fake "nt" elsewhere).
        # CREATE_NO_WINDOW in BOTH displays: qemu-system-x86_64.exe is a console
        # program, so without it the windowed Studio opens an empty console beside it
        # (and the CLI shares its terminal) whose closing kills the guest. It hides only
        # the console; the SDL desktop window is a GUI window and still opens.
        kw["creationflags"] = (getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0x200)
                               | getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000))
    else:
        kw["start_new_session"] = True
    try:
        proc = popen(argv, cwd=rd, stdin=subprocess.DEVNULL, stdout=log,
                     stderr=subprocess.STDOUT, **kw)
    except OSError as e:
        raise NativeError(f"QEMU could not be started: {e}") from None
    finally:
        log.close()
    # Recorded BEFORE the settle: a start interrupted there (Ctrl+C on the CLI does not
    # reach QEMU's own process group) leaves a device that Stop can still address.
    rec = {"label": o.label, "platform": o.platform, "role": o.role, "backend": BACKEND_WHPX,
           "image": o.image, "pid": proc.pid, "started": process_started(proc.pid),
           "qmp_port": port, "ssh_port": o.ssh_port,
           "ui_port": o.ui_port, "http_port": o.http_port, "run_dir": rd,
           "display": o.display, "accel": o.accel, "mem_mb": o.mem_mb, "keep": o.keep,
           "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    record = _record_path(o.work_dir, o.label)
    os.makedirs(devices_dir(o.work_dir), exist_ok=True)
    with open(record, "w", encoding="utf-8") as fh:
        json.dump(rec, fh, indent=1)
    deadline = time.monotonic() + settle_s
    while time.monotonic() < deadline and proc.poll() is None:
        time.sleep(0.2)
    if proc.poll() is not None:
        os.remove(record)
        with open(os.path.join(rd, "qemu.log"), encoding="utf-8", errors="replace") as fh:
            tail = fh.read().strip()[-600:]
        raise NativeError(f"QEMU stopped at once (exit {proc.returncode}): {tail}")
    on_line(f"Started {o.label}: ssh -p {o.ssh_port} <user>@127.0.0.1, "
            f"https://127.0.0.1:{o.ui_port}/, console {os.path.join(rd, 'console.log')}")
    return rec


def _kill(pid: int, osname: str | None = None) -> None:
    if (osname or os.name) == "nt":
        # No /T: QEMU starts no children, so a tree kill could only reach further.
        subprocess.run(["taskkill", "/PID", str(pid), "/F"], capture_output=True,
                       timeout=30)
    else:
        try:
            os.kill(pid, 9)
        except OSError:
            pass


def stop(work_dir: str, label: str, *, timeout_s: float = 60.0, alive=record_alive,
         ask=qmp) -> str:
    """Stop one device: ACPI power-off first (the guest shuts down cleanly), then
    QMP quit, then a hard kill. Returns what happened. A record whose pid another
    process now holds (:func:`record_alive`) was not running: only the record goes,
    and that process is never asked or killed."""
    path = _record_path(work_dir, label)
    try:
        with open(path, encoding="utf-8") as fh:
            rec = json.load(fh)
    except (OSError, ValueError):
        raise NativeError(f"No QEMU for Windows device named {label} is recorded.") from None
    pid, how = int(rec.get("pid", 0)), "was not running"
    if alive(rec):
        how = "powered off"
        try:
            ask(int(rec["qmp_port"]), "system_powerdown")
            deadline = time.monotonic() + timeout_s
            while alive(rec) and time.monotonic() < deadline:
                time.sleep(0.5)
            if alive(rec):
                how = "quit (it did not power off in time)"
                ask(int(rec["qmp_port"]), "quit")
                time.sleep(2)
        except (OSError, ValueError, KeyError):
            how = "killed (QMP did not answer)"
        if alive(rec):
            _kill(pid)
            if not how.startswith("killed"):
                how = "killed"
    os.remove(path)
    if not rec.get("keep"):
        shutil.rmtree(rec.get("run_dir", ""), ignore_errors=True)
    return f"{label}: {how}."


def ssh_argv(rec: dict, user: str) -> list[str]:
    """Windows' own OpenSSH client into the device's forwarded port."""
    return ["ssh", "-p", str(rec["ssh_port"]), "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=" + os.devnull, f"{user}@127.0.0.1"]


# ── rows from a build session ────────────────────────────────────────────────────────
def options_for_row(row, work_dir: str, **over) -> NativeOptions:
    """NativeOptions for a qemu_tests.DeviceRow (raises NativeError for ARM rows)."""
    why = row_refusal(row.platform)
    if why:
        raise NativeError(why)
    return NativeOptions(label=row.label, image=row.image, work_dir=work_dir,
                         platform=row.platform, role=row.role, **over)


# ── CLI ─────────────────────────────────────────────────────────────────────────────
_REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir,
                                          os.pardir, os.pardir))


def add_arguments(p: argparse.ArgumentParser) -> None:
    p.add_argument("action", choices=("check", "rows", "plan", "start", "stop", "status"))
    p.add_argument("--generator-dir", default=_REPO_ROOT)
    p.add_argument("--session", default="", help="build session name or path (for "
                   "rows/plan/start); its x86 images are the bootable rows")
    p.add_argument("--row", default="", help="the device label, e.g. x86/standalone-thin")
    p.add_argument("--img", default="", help="boot this .img/.img.xz instead of a session row")
    p.add_argument("--work", default="", help="work dir (default <generator>/out/qemu-runs)")
    p.add_argument("--mem", type=int, default=DEFAULT_MEM_MB)
    p.add_argument("--smp", type=int, default=DEFAULT_SMP)
    p.add_argument("--ssh-port", type=int, default=2222)
    p.add_argument("--ui-port", type=int, default=8443)
    p.add_argument("--http-port", type=int, default=8080)
    p.add_argument("--window", action="store_true", help="show the desktop in a window")
    p.add_argument("--tcg", action="store_true", help="no acceleration (very slow); only "
                   "when the Windows Hypervisor Platform cannot be turned on")
    p.add_argument("--keep", action="store_true", help="keep the overlay after stop")
    p.add_argument("--json", action="store_true")


def _work(args) -> str:
    return os.path.abspath(args.work or os.path.join(args.generator_dir, "out",
                                                     "qemu-runs"))


def _x86_rows(args) -> list:
    from . import emulation
    try:
        plan = emulation.plan(args.generator_dir, args.session, emulation.EmulationMode.TEST)
    except ValueError as e:                   # no such session: a sentence, not a traceback
        raise NativeError(str(e)) from None
    return list(plan.rows)


def _options(args) -> NativeOptions:
    over = dict(mem_mb=args.mem, smp=args.smp, ssh_port=args.ssh_port,
                ui_port=args.ui_port, http_port=args.http_port,
                display="window" if args.window else "none",
                accel="tcg" if args.tcg else "whpx", keep=args.keep)
    if args.img:
        label = args.row or "x86/" + os.path.basename(args.img).split(".")[0]
        return NativeOptions(label=label, image=os.path.abspath(args.img),
                             work_dir=_work(args), **over)
    if not args.session:
        raise NativeError("Give --session (and --row) or --img.")
    rows = _x86_rows(args)
    pick = [r for r in rows if r.label == args.row] if args.row else \
        [r for r in rows if r.platform == "x86"]
    if not pick:
        raise NativeError(f"No device row {args.row or 'for x86'} in that session. Rows: "
                          f"{', '.join(r.label for r in rows) or 'none'}.")
    return options_for_row(pick[0], _work(args), **over)


def run_cli(args) -> int:
    try:
        if args.action == "check":
            why = blocker(accel="tcg" if args.tcg else "whpx")
            inst = find_qemu()
            print(why or f"Ready: {inst.system} with "
                         f"{'TCG (no acceleration)' if args.tcg else 'WHPX'}.")
            return 0 if not why else 2
        if args.action == "rows":
            for r in _x86_rows(args):
                why = row_refusal(r.platform)
                print(f"{r.label}\t{'bootable' if not why else 'refused: ' + why}")
            return 0
        if args.action == "plan":
            print("\n".join(preview_lines(_options(args))))
            return 0
        if args.action == "start":
            rec = start(_options(args))
            if args.json:
                print(json.dumps(rec, indent=1))
            return 0
        if args.action == "stop":
            if not args.row:
                raise NativeError("Give --row LABEL of the device to stop.")
            print(stop(_work(args), args.row))
            return 0
        live = running(_work(args))
        if args.json:
            print(json.dumps(live, indent=1))
        else:
            print("\n".join(f"{r['label']}\trunning (pid {r['pid']}, ssh 127.0.0.1:"
                            f"{r['ssh_port']})" for r in live) or "no device running")
        return 0
    except (NativeError, OSError, subprocess.SubprocessError) as e:
        # A full disk under the run dir, or a tool that hangs, is worded like a
        # refusal (as the GUI's worker words it), not shown as a traceback.
        print(f"REFUSED: {e}", file=sys.stderr)
        return 2


def _parser(prog: str) -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog=prog,
                                description="Boot one x86 device image under QEMU for "
                                            "Windows (WHPX), with no bash, Docker or WSL2.")
    add_arguments(p)
    return p


def main(argv: list[str] | None = None) -> int:
    return run_cli(_parser("python -m hugmesh_studio.core.qemu_windows").parse_args(argv))


def add_cli_arguments(ap: argparse.ArgumentParser) -> None:
    """``--qemu-windows ACTION [options]`` on the Studio's argparse parser (Qt-free):
    everything after it is handed, unparsed, to this module's own parser, so the
    options are the ones :func:`add_arguments` defines and cannot drift."""
    ap.add_argument("--qemu-windows", nargs=argparse.REMAINDER, default=None,
                    metavar="ACTION",
                    help="headless: boot ONE x86 device image under QEMU for Windows "
                         "(WHPX), no bash, Docker or WSL2. ACTION is check, rows, plan, "
                         "start, stop or status; the options after it are those of "
                         "python -m hugmesh_studio.core.qemu_windows.")


def run_studio_cli(rest: list[str], generator_dir: str) -> int:
    """``hugmesh-studio --qemu-windows …``: the Studio's resolved checkout is the
    default ``--generator-dir`` (the frozen exe has no repo around this file)."""
    p = _parser("hugmesh-studio --qemu-windows")
    p.set_defaults(generator_dir=generator_dir)
    return run_cli(p.parse_args(rest))


if __name__ == "__main__":
    from .entry import bootstrap as _bootstrap   # the Mac PATH hook: core/entry.py
    _bootstrap()
    raise SystemExit(main())

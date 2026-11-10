"""Running inside the Flatpak: reach the host's tools through ``flatpak-spawn --host``
(Qt-free, stdlib only).

The Studio is a front end over host tooling (docker, make, git, qemu, kubectl, the
generator's bash scripts). Inside the Flatpak sandbox none of those exist: PATH is
``/app/bin:/usr/bin`` of the KDE runtime, there is no /run/docker.sock, no /dev/kvm and
no block device node, and /tmp is private to the sandbox. The manifest has always
granted ``--talk-name=org.freedesktop.Flatpak``, which is what lets a sandboxed program
start a command on the host, but nothing called it, so an installed Studio saw no
Docker and said "This machine can't build images yet" on a host that had Docker running
(measured 2026-11-09 on the installed 0.4.1-beta.1).

What this module does, only when ``/.flatpak-info`` exists:

  * :func:`install` wraps ``subprocess.Popen.__init__`` once, the way
    ``core/no_console.py`` does on Windows, instead of editing the ~40 modules that
    spawn processes. A command whose program is a HOST tool (:func:`runs_on_host`) is
    rewritten to ``flatpak-spawn --host --directory=<cwd> --env-fd=<n> <argv>``.
  * It also wraps ``shutil.which`` so a probe for a host tool answers with the host's
    path (``/usr/bin/docker``), from one ``command -v`` run on the host per name.
  * It points ``TMPDIR`` at a directory under the real home, because a temp file the
    Studio hands to a host command (``docker run -v <file>:...``) must exist on the
    host too, and the sandbox's /tmp does not.

What it measured and therefore does NOT do:

  * The environment is NOT inherited by the host command, so it is passed explicitly,
    through ``--env-fd`` (env -0 format) and never ``--env=K=V``: a value on the host
    command line is readable by every user through ps and /proc. Variables that only
    describe the sandbox (PATH, PYTHONPATH, LD_LIBRARY_PATH, the XDG_*_HOME the sandbox
    redirects into ~/.var/app, FLATPAK_*) are left out, so the host keeps its own.
  * The working directory is passed with ``--directory``.
  * ``--watch-bus`` is NOT used. With it, every host command dies when the Studio
    exits, and the Studio's builds and stacks are meant to outlive its window, as they
    do from a checkout.
  * A signal sent to ``flatpak-spawn`` reaches only the direct host child, not that
    child's own children (measured: a ``sh -c`` wrapper's ``sleep`` survived SIGTERM).
    So a process-GROUP stop does not cross the bridge, which is one of the two reasons
    the native (sudo) backend is unavailable in the Flatpak (see
    :func:`native_build_blocker`). The docker backend's stop, ``docker kill <name>``,
    is itself a host command and works.
  * Anything that re-runs the Studio's own Python (``sys.executable``) stays in the
    sandbox: on the host that path is not this Python.
"""
from __future__ import annotations

import fnmatch
import os
import shutil
import subprocess
import sys

#: The file every Flatpak sandbox has and nothing else does.
FLATPAK_INFO = "/.flatpak-info"

#: The host's os-release as the sandbox sees it (the sandbox's own /etc/os-release is
#: the runtime's, "KDE Flatpak runtime").
HOST_OS_RELEASE = "/run/host/os-release"

#: The program that asks the Flatpak session helper to start a host command.
SPAWN = "flatpak-spawn"

#: Host programs, matched on the basename of argv[0]. Read from the code: every
#: ``shutil.which("<name>")`` probe the Studio makes, every program it starts by name,
#: and the QEMU binaries the emulation lanes run. tests/test_flatpak_host.py derives
#: the probed names from the source and fails when one is missing here.
HOST_TOOLS = (
    "docker", "docker-compose", "make", "git", "gh", "kubectl", "kind", "helm",
    "qemu-system-*", "qemu-img", "remote-viewer", "spicy",
    "ssh", "scp", "ssh-keygen", "lsblk", "lspci", "losetup", "shred", "pgrep",
    "sudo", "pkexec", "ollama", "npx", "npm", "node",
    # mesh_controls.TOR_BROWSER_COMMANDS
    "torbrowser-launcher", "torbrowser", "tor-browser", "start-tor-browser",
    # local_agent opens one of these to run a command in a terminal the operator sees
    "x-terminal-emulator", "gnome-terminal", "konsole", "xfce4-terminal", "kitty",
    "alacritty", "foot", "xterm",
)

#: Shells. A shell runs on the host when what it runs is the generator's (a script
#: outside the sandbox's own trees, or a -c string), and stays in the sandbox when it
#: runs something under /app.
SHELLS = ("bash", "sh", "dash")

#: Trees that exist only inside the sandbox.
SANDBOX_PREFIXES = ("/app/", "/usr/", "/bin/", "/sbin/", "/lib/", "/lib64/", "/etc/")

#: Variables that describe the sandbox, not the host, and so are never passed across.
SANDBOX_ONLY_ENV = frozenset({
    "PATH", "LD_LIBRARY_PATH", "LD_PRELOAD", "PYTHONPATH", "PYTHONHOME",
    "PYTHONUSERBASE", "PYTHONSAFEPATH", "PYTHONNOUSERSITE",
    "XDG_DATA_DIRS", "XDG_CONFIG_DIRS", "XDG_DATA_HOME", "XDG_CONFIG_HOME",
    "XDG_CACHE_HOME", "XDG_STATE_HOME", "GI_TYPELIB_PATH", "GIO_EXTRA_MODULES",
    "GST_PLUGIN_SYSTEM_PATH", "GST_PLUGIN_SYSTEM_PATH_1_0", "GTK_PATH",
    "QT_PLUGIN_PATH", "QML2_IMPORT_PATH", "QML_IMPORT_PATH", "QTWEBENGINEPROCESS_PATH",
    "ALSA_CONFIG_PATH", "LIBGL_DRIVERS_PATH", "__EGL_VENDOR_LIBRARY_DIRS",
    "VK_ICD_FILENAMES", "VK_ADD_DRIVER_FILES", "container",
})

#: The sandbox's own PATH entries; any OTHER entry a caller put on PATH (the kind
#: binary the DevOps lane downloads, say) is carried to the host in front of its PATH.
_SANDBOX_PATH_ENTRIES = frozenset({"/app/bin", "/usr/bin", "/bin", "/app/sbin",
                                   "/usr/sbin", "/sbin"})

_INSTALLED = False
_WHICH_CACHE: dict[str, str | None] = {}
_BRIDGE: tuple[bool, str] | None = None

#: What :func:`install` wrapped, so :func:`uninstall` puts exactly that back.
_WRAPPED: tuple | None = None


def in_flatpak(info_path: str = FLATPAK_INFO) -> bool:
    return os.path.exists(info_path)


def _matches_host_tool(name: str) -> bool:
    return any(fnmatch.fnmatchcase(name, pattern) for pattern in HOST_TOOLS)


def _is_sandbox_path(path: str) -> bool:
    absolute = os.path.abspath(path)
    return absolute.startswith(SANDBOX_PREFIXES) or absolute == os.path.abspath(sys.executable)


def runs_on_host(argv) -> bool:
    """Whether ``argv`` (a list) names a program that lives on the host."""
    if not argv:
        return False
    program = str(argv[0])
    name = os.path.basename(program)
    if name == SPAWN or name.startswith("python") or program == sys.executable:
        return False
    if _matches_host_tool(name):
        return True
    if name in SHELLS:
        rest = [str(a) for a in argv[1:]]
        if "-c" in rest or any(a.startswith("-") and "c" in a[1:] and not a.startswith("--")
                               for a in rest):
            # A -c string: what it runs (docker, make, the generator's scripts) is the
            # host's. One that names /app is the Studio's own and stays here.
            return not any("/app/" in a for a in rest)
        if "-n" in rest:
            return False      # a syntax check runs nothing; the sandbox's shell will do
        operands = [a for a in rest if not a.startswith("-")]
        if not operands:
            return False
        script = operands[0]
        return not _is_sandbox_path(script)
    if "/" in program:
        # A script or binary started by path (./build-x86-host-stage4.sh, a generator
        # script): a path outside the sandbox's own trees is a host file.
        return not _is_sandbox_path(program)
    return False


def host_env(env) -> dict[str, str]:
    """``env`` without the variables that only describe the sandbox."""
    source = os.environ if env is None else env
    out: dict[str, str] = {}
    for key, value in source.items():
        key, value = str(key), str(value)
        if key in SANDBOX_ONLY_ENV or key.startswith("FLATPAK_"):
            continue
        out[key] = value
    return out


def _extra_path(env) -> list[str]:
    source = os.environ if env is None else env
    entries = []
    for entry in str(source.get("PATH", "")).split(os.pathsep):
        if entry and entry not in _SANDBOX_PATH_ENTRIES and not entry.startswith("/app/") \
                and entry not in entries:
            entries.append(entry)
    return entries


def host_argv(argv, cwd: str | None = None, env_fd: int | None = None,
              forward_fds=(), env=None) -> list[str]:
    """``argv`` as a host command: the ``flatpak-spawn --host`` prefix plus, when the
    caller's PATH carries entries of its own, a host ``sh`` that puts them in front of
    the host's PATH. ``env_fd`` is an open descriptor holding the environment in env -0
    format (see :func:`_env_memfd`)."""
    prefix = [SPAWN, "--host", f"--directory={os.path.abspath(cwd or os.getcwd())}"]
    if env_fd is not None:
        prefix.append(f"--env-fd={env_fd}")
    prefix += [f"--forward-fd={fd}" for fd in forward_fds]
    command = [str(a) for a in argv]
    extra = _extra_path(env)
    if extra:
        command = ["sh", "-c", 'PATH="$0:$PATH"; exec "$@"', os.pathsep.join(extra), *command]
    return prefix + command


def _env_memfd(env: dict[str, str]) -> int:
    """An anonymous file holding ``env`` in env -0 format, positioned at its start."""
    payload = b"".join(f"{k}={v}".encode("utf-8", "surrogateescape") + b"\0"
                       for k, v in env.items())
    if hasattr(os, "memfd_create"):
        fd = os.memfd_create("hugmesh-studio-env", 0)
    else:                                      # pragma: no cover - Linux always has it
        import tempfile
        fd, path = tempfile.mkstemp()
        os.unlink(path)
    os.write(fd, payload)
    os.lseek(fd, 0, os.SEEK_SET)
    return fd


def _wrap_popen(original):
    def __init__(self, args, *pargs, **kwargs):
        if kwargs.get("shell") or isinstance(args, (str, bytes, os.PathLike)) or pargs \
                or kwargs.get("executable") or not runs_on_host(list(args)):
            original(self, args, *pargs, **kwargs)
            return
        env = kwargs.pop("env", None)
        cwd = kwargs.pop("cwd", None)
        fd = _env_memfd(host_env(env))
        pass_fds = tuple(kwargs.pop("pass_fds", ()) or ())
        argv = host_argv(list(args), cwd=os.fspath(cwd) if cwd else None, env_fd=fd,
                         forward_fds=pass_fds, env=env)
        kwargs["pass_fds"] = (*pass_fds, fd)
        try:
            original(self, argv, **kwargs)
        finally:
            os.close(fd)
    __init__.__wrapped__ = original           # type: ignore[attr-defined]
    return __init__


def host_which(name: str, *, run=None) -> str | None:
    """The host's path for ``name`` ("" never: None when the host has none)."""
    if name in _WHICH_CACHE:
        return _WHICH_CACHE[name]
    run = run or subprocess.run
    found: str | None = None
    try:
        result = run([SPAWN, "--host", "sh", "-c", 'command -v -- "$1"', "sh", name],
                     capture_output=True, text=True, timeout=10)
        line = (result.stdout or "").strip().splitlines()
        if result.returncode == 0 and line and line[0].startswith("/"):
            found = line[0]
    except (OSError, subprocess.SubprocessError):
        found = None
    _WHICH_CACHE[name] = found
    return found


def _wrap_which(original):
    def which(cmd, mode=os.F_OK | os.X_OK, path=None):
        name = os.fspath(cmd)
        if path is None and isinstance(name, str) and "/" not in name \
                and _matches_host_tool(name):
            return host_which(name)
        return original(cmd, mode, path)
    which.__wrapped__ = original               # type: ignore[attr-defined]
    return which


def host_tmp_dir() -> str:
    """A temp directory that is the same path in the sandbox and on the host."""
    return os.path.join(os.path.expanduser("~"), ".cache", "hugmesh-studio", "tmp")


def install(*, info_path: str = FLATPAK_INFO) -> bool:
    """Route host tools through flatpak-spawn; True when the hooks are (now) in place.
    A no-op outside a Flatpak sandbox."""
    global _INSTALLED
    if _INSTALLED:
        return True
    if not in_flatpak(info_path):
        return False
    global _WRAPPED
    _WRAPPED = (subprocess.Popen.__init__, shutil.which)
    subprocess.Popen.__init__ = _wrap_popen(subprocess.Popen.__init__)  # type: ignore[method-assign]
    shutil.which = _wrap_which(shutil.which)                              # type: ignore[assignment]
    tmp = host_tmp_dir()
    try:
        os.makedirs(tmp, mode=0o700, exist_ok=True)
        os.environ["TMPDIR"] = tmp
        import tempfile
        tempfile.tempdir = None                # re-read TMPDIR on the next call
    except OSError:
        pass                                   # the sandbox /tmp still works for its own files
    _INSTALLED = True
    return True


def uninstall() -> None:
    """Put the real Popen and which back (tests)."""
    global _INSTALLED, _BRIDGE, _WRAPPED
    if _WRAPPED is not None:
        subprocess.Popen.__init__, shutil.which = _WRAPPED  # type: ignore[method-assign]
        _WRAPPED = None
    _WHICH_CACHE.clear()
    _BRIDGE = None
    _INSTALLED = False


def bridge_status(*, run=None, refresh: bool = False) -> tuple[bool, str]:
    """(works, why-not): can this sandbox start a command on the host at all?"""
    global _BRIDGE
    if _BRIDGE is not None and not refresh and run is None:
        return _BRIDGE
    run = run or subprocess.run
    try:
        result = run([SPAWN, "--host", "true"], capture_output=True, text=True, timeout=10)
        status = (True, "") if result.returncode == 0 else (
            False, (result.stderr or result.stdout or f"exit {result.returncode}").strip())
    except subprocess.TimeoutExpired:
        status = (False, "flatpak-spawn --host true did not answer within 10 s")
    except (OSError, subprocess.SubprocessError) as exc:
        status = (False, f"{type(exc).__name__}: {exc}")
    if run is subprocess.run:
        _BRIDGE = status
    return status


def bridge_failure_message(why: str) -> str:
    return ("Running as a Flatpak, the Studio runs docker, make and qemu on this computer "
            "through the Flatpak session helper (org.freedesktop.Flatpak), which did not "
            f"answer: {why or 'no reason given'}. Start the Studio from a desktop login "
            "(the helper lives on the D-Bus session bus), or run it from a "
            "hugmesh-generator checkout instead.")


def host_os_release(path: str = HOST_OS_RELEASE) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def host_kvm_state(*, run=None) -> tuple[bool, bool]:
    """(usable, present_but_denied) for the HOST's /dev/kvm, which the sandbox cannot
    see. Same meaning as platform_info._kvm_state: readable and writable by this user."""
    run = run or subprocess.run
    script = ('[ -e /dev/kvm ] || exit 2; '
              '[ -r /dev/kvm ] && [ -w /dev/kvm ] && exit 0; exit 3')
    try:
        result = run([SPAWN, "--host", "sh", "-c", script], capture_output=True,
                     timeout=10)
    except (OSError, subprocess.SubprocessError):
        return False, False
    return result.returncode == 0, result.returncode == 3


def native_build_blocker() -> str:
    """Why the native (sudo) backend is not offered in the Flatpak."""
    return ("A native build runs the builder as root on this computer, which the Flatpak "
            "cannot do safely: the password helper sudo calls back into lives inside the "
            "sandbox, and a Stop sent through flatpak-spawn reaches only the first host "
            "process, so the builder's own children would keep running. The Flatpak "
            "builds with Docker. To build natively, run the Studio from a "
            "hugmesh-generator checkout (studio/hugmesh-studio).")


def flash_blocker() -> str:
    return ("Writing an image to a device needs the host's block devices, losetup and "
            "root, and the Flatpak sandbox has none of them (it can list your disks but "
            "not open them). Flash from the Studio run from a hugmesh-generator checkout, "
            "or with scripts/flash-disk.sh in a terminal.")

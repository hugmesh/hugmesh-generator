"""Running on macOS: the facts and fixes a Mac needs (Qt-free, stdlib only).

A Mac runs the Studio as a POSIX program, so the Linux code paths mostly apply, and
that is the trap: nothing in them fails loudly on a Mac, they quietly do the Linux
thing. This module holds what is different, and every probe in it takes its
``run`` / ``which`` / ``environ`` / ``isdir`` from the caller so the darwin branches
are tested on Linux (tests/test_macos_host.py) and proven on a real Mac by the
``macos`` job of .github/workflows/studio-tests.yml.

THE PATH A FINDER-LAUNCHED APP GETS. An app started from Finder, the Dock or
Launchpad inherits launchd's PATH, ``/usr/bin:/bin:/usr/sbin:/sbin``, not the login
shell's. Homebrew (``/opt/homebrew/bin`` on Apple silicon, ``/usr/local/bin`` on
Intel), Docker Desktop's CLI and colima are all outside it, so ``shutil.which("docker")``
said "not installed" on a Mac that had Docker running. :func:`install` (called from
``app.main`` before anything spawns a process) puts them back, in this order:

  1. Homebrew's ``gnubin`` directories (coreutils, gnu-sed, findutils, grep, make),
     so ``sed``, ``readlink``, ``find`` and ``make`` are the GNU tools the generator's
     scripts are written for, in every child the Studio starts;
  2. Homebrew's ``bin`` (bash 5 lives there; /bin/bash is 3.2);
  3. Docker Desktop's CLI directory and ``~/.docker/bin``;
  4. colima's and OrbStack's.

Only directories that exist are added, nothing already on PATH is added twice, and off
macOS it does nothing. They go in just BEFORE the first system directory (/usr/bin,
/bin, /usr/sbin, /sbin), which is the front of launchd's PATH: ahead of the BSD tools
they must shadow, but behind anything a person put first on purpose, such as an
activated virtualenv's bin, whose ``python3`` must not lose to Homebrew's.

THE GNU USERLAND. macOS ships bash 3.2 (the last GPLv2 release) and BSD sed, find,
grep, stat and date. The generator's scripts use bash 4 (associative arrays, ``${x,,}``,
``mapfile``) and GNU flags (``sed -i`` without a suffix, ``find -printf``, ``stat -c``),
and on BSD tools they fail mid-run with messages that name the flag, not the cause.
:func:`gnu_userland_missing` says which are missing; ``platform_info.host_script_blocker``
turns that into the one ``brew install`` line that fixes all of them.
"""
from __future__ import annotations

import os
import re
import shlex
import shutil
import subprocess
import sys
import uuid
from dataclasses import dataclass

#: Homebrew's two prefixes: Apple silicon, then Intel.
BREW_PREFIXES = ("/opt/homebrew", "/usr/local")

#: Formulae whose GNU tools Homebrew installs with a "g" prefix, plus a ``gnubin``
#: directory holding the unprefixed names. Putting gnubin first is what makes ``sed``
#: GNU sed for every script the Studio starts.
GNUBIN_FORMULAE = ("coreutils", "gnu-sed", "findutils", "grep", "make")

#: The one line that installs every tool :func:`gnu_userland_missing` can report.
BREW_INSTALL = "brew install bash coreutils gnu-sed findutils grep make"

#: Docker runtimes a Mac can have. Each puts its ``docker`` CLI somewhere launchd's
#: PATH does not reach.
DOCKER_DIRS = ("/Applications/Docker.app/Contents/Resources/bin", "~/.docker/bin",
               "~/.colima/bin", "~/.orbstack/bin")

RUNTIME_DOCKER_DESKTOP = "docker-desktop"
RUNTIME_COLIMA = "colima"
RUNTIME_ORBSTACK = "orbstack"
RUNTIME_OTHER = "other"

#: The tools the generator's scripts need in their GNU form, each with the version
#: probe that tells GNU from BSD and the Homebrew formula that provides it. BSD's tools
#: reject ``--version`` (sed, stat, find) or print "BSD grep, GNU compatible", so the
#: probe is the GNU banner itself.
GNU_TOOLS = (
    # (name on PATH, argv, banner a GNU build prints, formula)
    ("sed", ["sed", "--version"], "GNU sed", "gnu-sed"),
    ("stat", ["stat", "--version"], "GNU coreutils", "coreutils"),
    ("find", ["find", "--version"], "GNU findutils", "findutils"),
    ("grep", ["grep", "--version"], "GNU grep", "grep"),
    ("make", ["make", "--version"], "GNU Make", "make"),
)

#: bash 4 is what the scripts need; macOS's own /bin/bash is 3.2.
MIN_BASH = 4

_PROBE_TIMEOUT_S = 5

#: The directories holding macOS's own (BSD) tools: the additions go before the first.
SYSTEM_DIRS = ("/usr/bin", "/bin", "/usr/sbin", "/sbin")


def is_macos(sysplatform: str | None = None) -> bool:
    return (sysplatform or sys.platform) == "darwin"


def path_additions(environ=None, *, isdir=os.path.isdir, home: str | None = None) -> list[str]:
    """The directories :func:`install` would put in front of PATH, in order: those that
    exist and are not already on it."""
    environ = os.environ if environ is None else environ
    home = home or environ.get("HOME") or os.path.expanduser("~")
    current = [p for p in (environ.get("PATH") or "").split(os.pathsep) if p]
    wanted: list[str] = []
    for prefix in BREW_PREFIXES:
        for formula in GNUBIN_FORMULAE:
            wanted.append(f"{prefix}/opt/{formula}/libexec/gnubin")
    for prefix in BREW_PREFIXES:
        wanted += [f"{prefix}/bin", f"{prefix}/sbin"]
    for d in DOCKER_DIRS:
        wanted.append(home + d[1:] if d.startswith("~") else d)
    out: list[str] = []
    for d in wanted:
        if d in current or d in out:
            continue
        if isdir(d):
            out.append(d)
    return out


def install(environ=None, *, sysplatform: str | None = None, isdir=os.path.isdir,
            home: str | None = None) -> list[str]:
    """Put :func:`path_additions` into ``environ["PATH"]`` (``os.environ`` by default)
    just before its first :data:`SYSTEM_DIRS` entry (at the end when it has none).
    Returns what was added; [] off macOS and on a second call."""
    if not is_macos(sysplatform):
        return []
    environ = os.environ if environ is None else environ
    added = path_additions(environ, isdir=isdir, home=home)
    if added:
        parts = [p for p in (environ.get("PATH") or "").split(os.pathsep) if p]
        at = next((i for i, p in enumerate(parts) if p.rstrip("/") in SYSTEM_DIRS),
                  len(parts))
        environ["PATH"] = os.pathsep.join(parts[:at] + added + parts[at:])
    return added


def _run(argv, run=None) -> tuple[int, str]:
    run = run or subprocess.run
    try:
        proc = run(argv, capture_output=True, text=True, timeout=_PROBE_TIMEOUT_S)
    except (OSError, subprocess.SubprocessError):
        return 127, ""
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def bash_major(which=None, run=None) -> int:
    """The major version of the ``bash`` first on PATH; 0 when there is none."""
    which = which or shutil.which
    exe = which("bash")
    if not exe:
        return 0
    rc, out = _run([exe, "-c", "echo ${BASH_VERSINFO[0]}"], run)
    m = re.match(r"\s*(\d+)", out)
    return int(m.group(1)) if rc == 0 and m else 0


def gnu_userland_missing(which=None, run=None) -> list[str]:
    """Homebrew formulae whose GNU tools are missing from PATH ("bash" first when the
    bash on PATH is older than 4). [] when the generator's scripts can run here."""
    which = which or shutil.which
    missing: list[str] = []
    if bash_major(which, run) < MIN_BASH:
        missing.append("bash")
    for name, argv, banner, formula in GNU_TOOLS:
        exe = which(name)
        if not exe:
            missing.append(formula)
            continue
        rc, out = _run([exe, *argv[1:]], run)
        if rc != 0 or banner not in out:
            missing.append(formula)
    return missing


def mac_arch(run=None) -> str:
    """"arm64" on Apple silicon, else "x86_64". Asked of the KERNEL (sysctl), not of
    ``platform.machine()``: under Rosetta an x86_64 Python reports x86_64 on an M-series
    Mac, and every decision keyed on it (which builder image, which QEMU accelerator)
    would be wrong."""
    rc, out = _run(["sysctl", "-n", "hw.optional.arm64"], run)
    return "arm64" if rc == 0 and out.strip() == "1" else "x86_64"


def hvf_available(run=None) -> bool:
    """Hypervisor.framework is usable (``kern.hv_support`` = 1): QEMU's ``-accel hvf``,
    the macOS counterpart of /dev/kvm."""
    rc, out = _run(["sysctl", "-n", "kern.hv_support"], run)
    return rc == 0 and out.strip() == "1"


def host_memory_bytes(run=None) -> int:
    rc, out = _run(["sysctl", "-n", "hw.memsize"], run)
    return int(out.strip()) if rc == 0 and out.strip().isdigit() else 0


@dataclass(frozen=True)
class DockerVM:
    """The Linux VM a Mac's Docker runs in. Its memory and CPUs, not the Mac's, are
    what a build gets."""
    runtime: str = ""        # RUNTIME_* or "" when docker did not answer
    context: str = ""
    mem_bytes: int = 0
    cpus: int = 0


def docker_vm(which=None, run=None) -> DockerVM:
    """Which runtime answers ``docker``, and how big its VM is. ``DockerVM()`` when
    docker is missing or does not answer."""
    which = which or shutil.which
    exe = which("docker")
    if not exe:
        return DockerVM()
    rc, out = _run([exe, "info", "--format", "{{.OperatingSystem}}|{{.MemTotal}}|{{.NCPU}}"],
                   run)
    if rc != 0:
        return DockerVM()
    parts = (out.strip().splitlines() or [""])[-1].split("|")
    osname = parts[0] if parts else ""
    mem = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
    cpus = int(parts[2]) if len(parts) > 2 and parts[2].isdigit() else 0
    rc, ctx = _run([exe, "context", "show"], run)
    context = ctx.strip().splitlines()[-1] if rc == 0 and ctx.strip() else ""
    return DockerVM(_runtime(context, osname), context, mem, cpus)


def _runtime(context: str, osname: str) -> str:
    c, o = context.lower(), osname.lower()
    if c.startswith("colima"):
        return RUNTIME_COLIMA
    if c == "orbstack" or "orbstack" in o:
        return RUNTIME_ORBSTACK
    if c == "desktop-linux" or "docker desktop" in o:
        return RUNTIME_DOCKER_DESKTOP
    return RUNTIME_OTHER


# ── terminals ───────────────────────────────────────────────────────────────────────
#: The terminal apps the Studio can open a command in, by the name ``open -a`` takes,
#: with the bundle that must exist for it. Terminal.app ships with every Mac.
TERMINAL_APPS = (("iTerm", "/Applications/iTerm.app"),
                 ("Terminal", "/System/Applications/Utilities/Terminal.app"))

#: Environment variables a .command script re-exports. Terminal.app starts a fresh
#: login shell and does NOT inherit the Studio's environment, so what a command needs
#: from it has to be written into the script. Never a secret: the file is on disk.
COMMAND_ENV_KEYS = ("PATH", "LANG", "LC_ALL", "DOCKER_HOST", "DOCKER_CONTEXT",
                    "KUBECONFIG", "HUGMESH_STUDIO_STATE_DIR")

_HOLD = 'rc=$?; echo; read -r -p "press Enter to close..." _; exit "$rc"'


def terminal_app(isdir=os.path.isdir, prefer: str = "") -> str:
    """``prefer`` when its bundle exists, else iTerm when installed, else Terminal."""
    names = [n for n, _ in TERMINAL_APPS]
    if prefer in names and isdir(dict(TERMINAL_APPS)[prefer]):
        return prefer
    for name, bundle in TERMINAL_APPS:
        if isdir(bundle):
            return name
    return "Terminal"


def command_script(argv, *, cwd: str = "", title: str = "", environ=None,
                   hold: bool = True, path: str = "") -> str:
    """The text of a ``.command`` file that runs ``argv`` in a terminal window.

    Its first line after the shebang deletes the file itself, so nothing is left behind
    once the window has started; it exports :data:`COMMAND_ENV_KEYS` from ``environ``,
    changes to ``cwd``, sets the window title and, with ``hold``, waits for Enter so the
    result stays readable. Run by /bin/bash (3.2 is enough: nothing here needs 4).
    """
    environ = os.environ if environ is None else environ
    lines = ["#!/bin/bash"]
    if path:
        lines.append(f"rm -f {shlex.quote(path)}")
    for key in COMMAND_ENV_KEYS:
        if environ.get(key):
            lines.append(f"export {key}={shlex.quote(environ[key])}")
    if title:
        # OSC 0: the window and tab title, which Terminal.app and iTerm2 both honour.
        lines.append(f"printf '\\033]0;%s\\007' {shlex.quote(title)}")
    if cwd:
        lines.append(f"cd {shlex.quote(cwd)} || exit 1")
    lines.append(shlex.join(list(argv)))
    if hold:
        lines.append(_HOLD)
    return "\n".join(lines) + "\n"


def terminal_argv(argv, *, state_dir: str, cwd: str = "", title: str = "", environ=None,
                  hold: bool = True, app: str = "", isdir=os.path.isdir) -> list[str]:
    """Write ``argv`` into a 0700 ``.command`` file under ``<state_dir>/term`` and return
    the ``open -a <app> <file>`` that runs it in a new terminal window.

    WHY A FILE AND NOT ``osascript -e 'tell application "Terminal" to do script …'``:

      * no Automation (TCC) consent. macOS asks once per app signature before an app
        may script Terminal, and an ad-hoc-signed app gets a NEW signature with every
        build, so every upgrade would ask again;
      * no AppleScript string escaping of arbitrary argv (the shell quoting here is
        ``shlex``, the same as every other terminal launcher in the Studio);
      * iTerm2 opens a .command file the same way, so one path serves both.
    """
    term = os.path.join(state_dir, "term")
    os.makedirs(term, mode=0o700, exist_ok=True)
    path = os.path.join(term, f"{uuid.uuid4().hex}.command")
    text = command_script(argv, cwd=cwd, title=title, environ=environ, hold=hold, path=path)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o700)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(path, 0o700)
    return ["open", "-a", app or terminal_app(isdir), path]


def wrap_in_terminal(argv, *, hold: bool = True, cwd: str = "", title: str = "",
                     environ=None, sysplatform: str | None = None,
                     state_dir: str | None = None, isdir=os.path.isdir) -> "list[str] | None":
    """On macOS, :func:`terminal_argv` with the Studio's state dir; None anywhere else,
    so a caller tries this first and falls through to its Linux terminal list. The one
    entry point every "open a terminal" path in the Studio shares on a Mac (go-live,
    cloud deploy, the phone wizard, a device login, the local AI agent)."""
    if not is_macos(sysplatform):
        return None
    if state_dir is None:
        from . import state_paths
        state_dir = state_paths.state_dir()
    return terminal_argv(argv, state_dir=state_dir, cwd=cwd, title=title, environ=environ,
                         hold=hold, isdir=isdir)

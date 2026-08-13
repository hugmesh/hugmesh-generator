"""Containerized QEMU emulated-device test driver (Qt-free).

The Studio front-end for ``tests/qemu/run-qemu-docker.sh``. Like core/build_matrix.py
this module is deliberately Qt-free and side-effect-free at import time, so every
resolution rule below is unit-testable HERMETICALLY — no docker, no qemu, no images.

WHY THE TESTS ARE CONTAINERIZED (the constraint that shapes this whole module)
-----------------------------------------------------------------------------
Lifting a kernel out of a golden ``.img`` needs a loop mount, and building a
throwaway rootfs from a stage4 needs mkfs + an xattr-preserving untar. Both need
root. On a workstation that means an interactive ``sudo`` password, which a GUI
cannot supply — so the Studio would be unable to run its own device tests. A
``--privileged`` container is root for anyone in the ``docker`` group, so the
whole matrix runs unattended. See docker/Dockerfile.qemu-runner.

WHAT THIS MODULE OWNS vs WHAT THE SHELL OWNS
--------------------------------------------
The shell script is the single source of truth for RUNNING a row. This module
only:
  * enumerates build SESSIONS and the device rows their artifacts imply, so the
    Studio can offer "images built in another session" without shelling out;
  * builds the argv for the runner;
  * reads back the per-row result JSON the runner emits.
``parse_artifact_name`` mirrors the runner's own parsing rule; the two are
cross-checked by test_qemu_tests.py against the SAME sample names, so drift in
either direction fails a test rather than silently selecting the wrong image.
"""
from __future__ import annotations

import json
import os
import shlex
import subprocess
import threading
from collections.abc import Callable
from dataclasses import dataclass, field

#: Where the builders drop per-session artifact dirs, relative to the generator repo.
SESSIONS_SUBDIR = os.path.join("out", "sessions")
#: The host-side runner this module drives.
RUNNER_SCRIPT = os.path.join("tests", "qemu", "run-qemu-docker.sh")
#: Default scratch root (decompressed images, overlays, per-row result JSON).
DEFAULT_WORK_SUBDIR = os.path.join("out", "qemu-runs")

#: Image extensions a device row can be built from, longest-first so ".img.xz"
#: is stripped before ".img" ever matches.
_IMAGE_SUFFIXES = (".img.xz", ".img")

#: Blobs that live beside the images but are not bootable disks.
_NON_IMAGE_MARKERS = ("kernel", "initramfs", "initrd", "squashfs")

#: Platforms whose rows are slowest and most load-bearing, in the order the
#: runner boots them. aarch64 has no KVM on an x86_64 host, so every Pi/ARM row
#: is pure TCG emulation and wants to start first; x86 gets KVM and is quick.
_PLATFORM_ORDER = {"rpi5": 0, "rpi4": 0, "rpi3": 0}
_PLATFORM_ORDER_ARM_DEFAULT = 1
_PLATFORM_ORDER_X86 = 2


def platform_rank(platform: str) -> int:
    """Boot-order rank: Pi first, other ARM next, x86 last.

    Mirrors ``platform_rank()`` in tests/qemu/run-qemu-docker.sh — the Studio
    previews the order the runner will actually use, so a user is never shown a
    plan the harness then reorders.
    """
    if platform in _PLATFORM_ORDER:
        return _PLATFORM_ORDER[platform]
    if platform == "x86":
        return _PLATFORM_ORDER_X86
    return _PLATFORM_ORDER_ARM_DEFAULT


@dataclass(frozen=True)
class DeviceRow:
    """One emulated device: a platform/role pair backed by a concrete artifact."""
    platform: str
    arch: str
    role: str
    env: str
    image: str          # absolute path to the .img / .img.xz

    @property
    def label(self) -> str:
        return f"{self.platform}/{self.role}"

    @property
    def compressed(self) -> bool:
        return self.image.endswith(".img.xz")

    @property
    def basename(self) -> str:
        return os.path.basename(self.image)


@dataclass
class BuildSession:
    """A build session dir plus the device rows its artifacts support."""
    path: str
    name: str
    rows: list[DeviceRow] = field(default_factory=list)
    mtime: float = 0.0

    @property
    def has_images(self) -> bool:
        return bool(self.rows)

    @property
    def platforms(self) -> list[str]:
        return sorted({r.platform for r in self.rows})

    def summary(self) -> str:
        """One line for a picker: what this session can actually be tested with."""
        if not self.rows:
            return f"{self.name} — no images"
        by_platform: dict[str, list[str]] = {}
        for r in sorted(self.rows, key=lambda r: (platform_rank(r.platform), r.role)):
            by_platform.setdefault(r.platform, []).append(r.role)
        parts = [f"{p} ({', '.join(roles)})" for p, roles in by_platform.items()]
        return f"{self.name} — {len(self.rows)} image(s): " + "; ".join(parts)


def parse_artifact_name(basename: str) -> tuple[str, str, str, str] | None:
    """``hugmesh-<platform>-<arch>-<role>-<env>-<stamp>.img[.xz]`` -> (platform, arch, role, env).

    Returns None for anything that is not a bootable role image.

    The role may itself contain '-' (``standalone-thin``), so the name is parsed
    from BOTH ends: the first two fields are the brand and platform, the third is
    the arch, and the LAST two fields before the extension are env and stamp —
    whatever remains in the middle is the role, hyphens and all. A naive
    ``split('-')[3]`` would truncate every hyphenated role to "standalone".
    """
    name = basename
    for suffix in _IMAGE_SUFFIXES:
        if name.endswith(suffix):
            name = name[: -len(suffix)]
            break
    else:
        return None

    lowered = name.lower()
    if any(marker in lowered for marker in _NON_IMAGE_MARKERS):
        return None
    if not name.startswith("hugmesh-"):
        return None

    parts = name.split("-")
    # hugmesh + platform + arch + <role...> + env + stamp  => at least 6 fields
    if len(parts) < 6:
        return None
    platform, arch = parts[1], parts[2]
    env = parts[-2]
    role = "-".join(parts[3:-2])
    if not platform or not role:
        return None
    return platform, arch, role, env


def discover_rows(artifacts_dir: str) -> list[DeviceRow]:
    """Every device row the artifacts in ``artifacts_dir`` can boot, Pi first.

    When both a ``.img`` and its ``.img.xz`` exist for the same artifact, the
    decompressed one wins: the runner would otherwise spend minutes re-expanding
    9-20GB it already has on disk.
    """
    if not os.path.isdir(artifacts_dir):
        return []

    best: dict[tuple[str, str], DeviceRow] = {}
    try:
        entries = sorted(os.listdir(artifacts_dir))
    except OSError:
        return []

    for entry in entries:
        parsed = parse_artifact_name(entry)
        if parsed is None:
            continue
        platform, arch, role, env = parsed
        path = os.path.join(artifacts_dir, entry)
        if not os.path.isfile(path):
            continue
        row = DeviceRow(platform=platform, arch=arch, role=role, env=env, image=path)
        key = (platform, role)
        prior = best.get(key)
        if prior is None or (prior.compressed and not row.compressed):
            best[key] = row

    return sorted(best.values(), key=lambda r: (platform_rank(r.platform), r.platform, r.role))


def discover_sessions(generator_dir: str, *, only_with_images: bool = True) -> list[BuildSession]:
    """Build sessions under ``out/sessions/``, newest first.

    A session dir is minted when a build STARTS, so many hold no artifacts at
    all; ``only_with_images`` keeps those out of a picker whose every entry is
    supposed to be runnable.
    """
    root = os.path.join(generator_dir, SESSIONS_SUBDIR)
    if not os.path.isdir(root):
        return []

    sessions: list[BuildSession] = []
    try:
        names = os.listdir(root)
    except OSError:
        return []

    for name in names:
        path = os.path.join(root, name)
        if not os.path.isdir(path):
            continue
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            mtime = 0.0
        session = BuildSession(path=path, name=name, rows=discover_rows(path), mtime=mtime)
        if only_with_images and not session.has_images:
            continue
        sessions.append(session)

    sessions.sort(key=lambda s: s.mtime, reverse=True)
    return sessions


def newest_session(generator_dir: str) -> BuildSession | None:
    """The newest session that actually holds images, or None."""
    sessions = discover_sessions(generator_dir, only_with_images=True)
    return sessions[0] if sessions else None


@dataclass
class QemuRunOptions:
    """Everything the runner needs for one fan-out."""
    artifacts_dir: str = ""          # explicit artifacts dir (a session path)
    work_dir: str = ""               # scratch; defaults to <generator>/out/qemu-runs
    platform: str = ""               # filter: only this platform
    role: str = ""                   # filter: only this role
    only: str = ""                   # substring filter on "<platform>/<role>"
    mode: str = "golden"             # golden | stage4
    jobs: int = 2
    mem_mb: int = 2048
    smp: int = 2
    timeout_s: int = 2400
    list_only: bool = False
    build_image: bool = False
    keep: bool = False


def runner_command(generator_dir: str, opts: QemuRunOptions) -> list[str]:
    """argv for tests/qemu/run-qemu-docker.sh.

    Only non-default knobs are emitted, so the printed command stays readable and
    a future default change in the shell script is not frozen here.
    """
    cmd: list[str] = [os.path.join(generator_dir, RUNNER_SCRIPT)]
    if opts.artifacts_dir:
        cmd += ["--artifacts", opts.artifacts_dir]
    cmd += ["--work", opts.work_dir or os.path.join(generator_dir, DEFAULT_WORK_SUBDIR)]
    if opts.platform:
        cmd += ["--platform", opts.platform]
    if opts.role:
        cmd += ["--role", opts.role]
    if opts.only:
        cmd += ["--only", opts.only]
    if opts.mode and opts.mode != "golden":
        cmd += ["--mode", opts.mode]
    cmd += ["--jobs", str(opts.jobs),
            "--mem", str(opts.mem_mb),
            "--smp", str(opts.smp),
            "--timeout", str(opts.timeout_s)]
    if opts.list_only:
        cmd.append("--list")
    if opts.build_image:
        cmd.append("--build-image")
    if opts.keep:
        cmd.append("--keep")
    return cmd


def command_string(generator_dir: str, opts: QemuRunOptions) -> str:
    return " ".join(shlex.quote(x) for x in runner_command(generator_dir, opts))


def read_results(work_dir: str) -> list[dict]:
    """The per-row result JSON the runner emits, worst-first.

    Failures sort to the top: a 7-row matrix where one row failed should not make
    the operator scroll to find it.
    """
    results_dir = os.path.join(work_dir, "results")
    if not os.path.isdir(results_dir):
        return []
    out: list[dict] = []
    for name in sorted(os.listdir(results_dir)):
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(results_dir, name), encoding="utf-8") as fh:
                out.append(json.load(fh))
        except (OSError, ValueError):
            continue
    rank = {"FAIL": 0, "ERROR": 1, "PASS": 2}
    out.sort(key=lambda r: (rank.get(str(r.get("status")), 3), str(r.get("label", ""))))
    return out


def results_summary(results: list[dict]) -> tuple[int, int, int]:
    """(passed, failed, total) over a result list."""
    passed = sum(1 for r in results if r.get("status") == "PASS")
    total = len(results)
    return passed, total - passed, total


def docker_available() -> tuple[bool, str]:
    """Whether this host can run the containerized harness at all.

    The Studio must say so up-front rather than let the operator configure a run
    that dies at spawn — the same reasoning as WelcomePage's no-build-backend note.
    """
    try:
        proc = subprocess.run(["docker", "info"], stdout=subprocess.DEVNULL,
                              stderr=subprocess.PIPE, text=True, timeout=15)
    except FileNotFoundError:
        return False, "docker was not found on PATH."
    except (OSError, subprocess.SubprocessError) as exc:
        return False, f"could not run docker: {exc}"
    if proc.returncode != 0:
        return False, ("cannot talk to the docker daemon — is it running, and is "
                       "your user in the 'docker' group?")
    return True, "docker is available."


class QemuTestRunner:
    """Spawns the runner and streams its output, cancellably.

    Mirrors core/build_driver.py's streaming contract (spawn, per-line callback,
    exit code, cancel()) so the GUI can drive it with the SAME worker thread the
    build and cloud-deploy pages already use.
    """

    def __init__(self, generator_dir: str):
        self.generator_dir = generator_dir
        self._proc: subprocess.Popen | None = None
        self._cancel = threading.Event()

    def run(self, opts: QemuRunOptions,
            on_line: Callable[[str], None] | None = None) -> int:
        """Run the matrix, calling ``on_line`` per output line. Returns the exit code."""
        cmd = runner_command(self.generator_dir, opts)
        if on_line:
            on_line(f"$ {command_string(self.generator_dir, opts)}")
        self._cancel.clear()
        try:
            # start_new_session: the runner spawns docker containers that must be
            # signalled as a group on cancel, exactly as build_driver does for the
            # native sudo->bash->emerge tree.
            self._proc = subprocess.Popen(
                cmd, cwd=self.generator_dir, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, text=True, bufsize=1, start_new_session=True)
        except OSError as exc:
            if on_line:
                on_line(f"!! could not start the runner: {exc}")
            return 127
        assert self._proc.stdout is not None
        for line in self._proc.stdout:
            if on_line:
                on_line(line.rstrip("\n"))
            if self._cancel.is_set():
                break
        return self._proc.wait()

    def cancel(self) -> None:
        """Stop the run and the containers it started."""
        self._cancel.set()
        proc = self._proc
        if proc is None or proc.poll() is not None:
            return
        try:
            os.killpg(proc.pid, 15)
        except (OSError, ProcessLookupError):
            try:
                proc.terminate()
            except OSError:
                pass

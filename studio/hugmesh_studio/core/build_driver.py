"""BuildDriver — assemble + run a build from an ImageConfig, native or dockerized.

The GUI calls ``command(...)`` to preview the exact invocation and ``run(...)`` to
stream it line-by-line into the progress page. Identical config -> identical command on
Linux and Windows; the only difference is the backend wrapper.

MEMORY-GUARD ASYMMETRY (2026-07-15 host-freeze incident): docker builds run under a
container memory cap by default (``--memory``/``--memory-swap`` in the docker-run
wrapper — see :func:`docker_memory_args`), so a runaway compile OOMs the CONTAINER
with an honest build failure instead of freezing the host. NATIVE builds cannot be
memory-capped by the Studio (no cgroup wrapper around a sudo'd chroot build) — on a
memory-tight host the preflight WARNING recommends the docker backend instead. The
warning channel (:meth:`BuildDriver.preflight_warnings`) is advisory only: it never
blocks a build and never silently throttles jobs or the cap.
"""
from __future__ import annotations

import math
import os
import shlex
import shutil
import stat
import subprocess
import sys
import threading
import time
import uuid
from collections.abc import Callable, Iterator
from typing import NamedTuple

from . import askpass, emulation_save, host_resources, platform_info, proc_text
from . import resource_limits, secret_files, state_paths
from .config import (PLATFORM_FIELD_SUPPORT, ImageConfig, scope_violations,
                     standalone_login_problem, unaffiliated_image)
from .platform_info import HostInfo, detect

# Config fields holding a HOST path that the builder must be able to READ. Under the docker
# backend the container sees only /src (the generator repo) and /out, so any path outside
# those is invisible in-container; _remap_assets_for_docker bind-mounts each of these :ro
# and rewrites the flag to the in-container path.
#
# This list is the whole ballgame, and it used to be an inline tuple with NO test pinning
# it — which is exactly how it drifted. A field MISSING here does not fail loudly: the flag
# is emitted carrying an unreachable host path, and every consumer in the builder guards its
# path with `[ -f ]` / `[ -d ]` and SKIPS when the test fails. So the flag was accepted,
# ignored, and the build exited 0:
#   * secureboot_key/_cert — the UKI got signed with a throwaway generated key that is in no
#     firmware db => the delivered image does NOT boot under Secure Boot on the target. This
#     fired for a PERFECTLY CORRECT host path, on the DEFAULT backend, every single time.
#   * distdir            — silently fell back to scanning /media/*, so a build that was
#     supposed to reuse a local cache re-downloaded everything instead.
#   * keys_usb           — the builder does err on a missing dir, so this one at least failed
#     loudly; it is mounted here so the flag actually WORKS under docker rather than being a
#     native-only feature that hard-errors the moment you use the default backend.
# test_docker_asset_mounts.py pins this list against the real path-valued flag surface so a
# newly-added path field cannot rejoin the silent-ignore club.
DOCKER_ASSET_FIELDS: tuple[str, ...] = (
    # Order is relied on ONLY in that each field's index names its /assets/<i>/ dir;
    # append new fields at the END so existing mounts keep their paths.
    "wallpaper", "grub_background", "login_background",
    "brand_logo", "color_scheme", "branding_dir", "egress_vpn",
    "secureboot_key", "secureboot_cert", "keys_usb", "distdir",
)

# More host-path flags the docker backend must translate or mount, kept OUT of
# DOCKER_ASSET_FIELDS because that list also derives _PATH_MUST_EXIST. These are emitted
# under more conditions than the platform table knows (the brand args are dropped for an
# unaffiliated image; home flags are x86-only), so a stale value riding a loaded, saved or
# restarted config would false-block a build that never receives it. They are checked —
# and mounted — only when this config's argv really carries them (_emitted_path_fields).
# Operator session 20261031-104549 (docker backend) is why brand_profile is here: every
# image died on "config file not found" for a brands/*.conf the native backend read fine.
# Their /assets/<i>/ index continues after DOCKER_ASSET_FIELDS; append at the END.
DOCKER_EXTRA_ASSET_FIELDS: tuple[str, ...] = (
    "grub_theme", "brand_profile", "home_seed_code_from", "include_home_archive",
    "seed_packages_from",
)

# Path-valued fields that must EXIST on the host or the build is stopped BEFORE dispatch.
# Derived from DOCKER_ASSET_FIELDS because the two lists are siblings and drifted together:
# the same four fields were missing from BOTH, so a mistyped signing key was neither mounted
# nor reported — it was simply ignored an hour into the build.
#   * distdir is deliberately EXCLUDED — it warns instead (see _PATH_ADVISORY). An unusable
#     distfiles cache costs build TIME; it never changes the artifact, so blocking on it
#     would break the "cache drive is sometimes attached" workflow to prevent nothing.
#   * keyzip is added here but is NOT in DOCKER_ASSET_FIELDS: Studio reads and unpacks it
#     itself on the host, so it is never a builder flag and never needs a mount.
_PATH_MUST_EXIST: tuple[str, ...] = tuple(
    f for f in DOCKER_ASSET_FIELDS if f != "distdir") + ("keyzip",)
_PATH_ADVISORY: tuple[str, ...] = ("distdir",)
# Labels that are NOT just the field name kebab-cased (which is also the flag spelling).
_PATH_LABELS: dict[str, str] = {"keyzip": "key-zip"}
# The builder flag each path field rides; the kebab-cased field name unless listed.
_PATH_FLAG_OVERRIDES: dict[str, str] = {"brand_profile": "--config"}


def _path_flag(field: str) -> str:
    return _PATH_FLAG_OVERRIDES.get(field, "--" + field.replace("_", "-"))


# The login password rides a 0600 FILE at dispatch, never argv (secret_files.
# stage_local_pass says why). ImageConfig.to_cli_args() keeps emitting
# `--local-pass PASS` — the CLI/--print-cmd channel and every argv pin depend on it —
# and run()/iter_run() swap that one pair for `--local-pass-file PATH` on the argv
# they actually spawn. Under docker the file is bind-mounted read-only here.
DOCKER_LOCAL_PASS_PATH = "/assets/local-pass/local-pass"


#: The Desktop step's extra local accounts' passwords (NAME:PASSWORD lines): staged
#: like the login password, mounted read-only here under docker. The argv a preview
#: shows carries desktop_spec.EXTRA_PASS_PLACEHOLDER; dispatch swaps the real path in.
DOCKER_EXTRA_PASS_PATH = "/assets/extra-local-pass/extra-local-passes"


def _swap_extra_pass(argv: list[str], path: str) -> list[str]:
    """``argv`` with the Desktop step's ``--extra-local-pass-file <placeholder>`` pair
    pointing at ``path`` (the file staged for this one run)."""
    from .desktop_spec import EXTRA_PASS_PLACEHOLDER
    out = list(argv)
    for k in range(len(out) - 1):
        if out[k] == "--extra-local-pass-file" and out[k + 1] == EXTRA_PASS_PLACEHOLDER:
            out[k + 1] = path
            break
    return out


def _swap_local_pass(argv: list[str], secret: str, path: str) -> list[str]:
    """``argv`` with its structured ``--local-pass <secret>`` pair replaced by
    ``--local-pass-file <path>``. Only the FIRST pair carrying exactly ``secret`` is
    the structured emission (``extra_flags`` comes last and is the operator's own),
    so that is the one swapped."""
    out = list(argv)
    for k in range(len(out) - 1):
        if out[k] == "--local-pass" and out[k + 1] == secret:
            out[k:k + 2] = ["--local-pass-file", path]
            break
    return out


def _emitted_path_fields(cfg: ImageConfig) -> set[str] | None:
    """The path fields this config's builder argv REALLY carries — the flag followed by
    the field's own value — read from ``to_cli_args()`` itself, so no second copy of the
    emission rules (unaffiliated drops the brand args, ARM never gets the x86 flags, ...)
    can drift from the one that builds the argv. ``extra_flags`` is blanked first: a
    hand-typed flag there is the operator's own and is never rewritten. None when the
    config's argv cannot be built at all (preflight reports that separately)."""
    import copy
    try:
        probe = copy.copy(cfg)
        probe.extra_flags = ""
        argv = probe.to_cli_args()
    except Exception:  # noqa: BLE001 — "cannot tell" is the answer, not a crash
        return None
    out: set[str] = set()
    for field in DOCKER_ASSET_FIELDS + DOCKER_EXTRA_ASSET_FIELDS:
        val = getattr(cfg, field, "")
        flag = _path_flag(field)
        if val and any(argv[k] == flag and argv[k + 1] == val
                       for k in range(len(argv) - 1)):
            out.add(field)
    return out


def _path_emitted(field: str, cfg: ImageConfig, emitted: set[str] | None) -> bool:
    """Does the builder receive ``field`` for this cfg? keyzip is host-side, so always.
    When the argv could not be built, fall back to the platform table plus the one rule
    it cannot express (an unaffiliated image never gets --config)."""
    if field == "keyzip":
        return True
    if emitted is not None:
        return field in emitted
    if field == "brand_profile" and unaffiliated_image(cfg):
        return False
    return _path_field_emitted(field, cfg)


def _path_label(field: str) -> str:
    return _PATH_LABELS.get(field, field.replace("_", "-"))


def _path_field_emitted(field: str, cfg: ImageConfig) -> bool:
    """True when this platform's builder actually receives ``field``. keyzip is host-side
    (never a flag) so it always counts; everything else defers to the platform table."""
    if field == "keyzip":
        return True
    platforms = PLATFORM_FIELD_SUPPORT.get(field)
    return platforms is None or (cfg.platform or "x86") in platforms


# Memoized path of the GUI askpass helper (see _askpass_helper_path). One per process
# is enough — the helper body only depends on this interpreter's path/location.
_ASKPASS_PATH_CACHE: str | None = None

# Directories a root build's PATH has but an unprivileged Studio's typically does
# not. See _host_tool_present().
_SBIN_DIRS = ("/usr/sbin", "/sbin", "/usr/bin", "/bin")


def _host_tool_present(*names: str) -> bool:
    """True iff ANY of ``names`` exists as an executable on this host.

    Deliberately does NOT rely on shutil.which() alone. Squash/disk tooling
    installs into /usr/sbin on some hosts, and the Studio runs as an
    unprivileged user whose PATH typically omits /usr/sbin — while the build
    itself runs as ROOT via sudo/pkexec (_elevation_prefix), with /usr/sbin on
    PATH. A PATH-only probe therefore reports "missing" for a tool the build
    would find. Probe explicit directories too.

    This residual false-negative risk is exactly why the caller belongs in the
    ADVISORY channel (preflight_warnings), never in blocking preflight(): a
    wrong answer here costs a spurious warning line, never a blocked build. The
    builder script's own hostguard_require_host_tools remains authoritative.
    """
    for n in names:
        if shutil.which(n):
            return True
        if any(os.access(os.path.join(d, n), os.X_OK) for d in _SBIN_DIRS):
            return True
    return False


def windows_docker_remedy(osname: str | None = None, docker_cli: bool | None = None,
                          host: HostInfo | None = None) -> str:
    """How to get a build backend on the native Windows Studio (the MSI), "" elsewhere.

    Docker is its only backend, and Docker Desktop does not start with Windows by
    default, so the usual cause is an installed but stopped Docker Desktop: the generic
    "install Docker ... or run on a Gentoo host" told that user to install what they
    have, plus a host the MSI cannot use. ``host`` lends its probe result (down / timeout
    have their own wording in HostInfo.docker_remedy); ``docker_cli`` is whether
    docker.exe is on PATH (probed when None); ``osname`` is ``os.name`` unless a test
    passes another."""
    if (osname or os.name) != "nt":
        return ""
    alt = ("Or run the Linux build of the Studio inside WSL2, with Docker Desktop's WSL "
           "integration turned on for that distro.")
    state = getattr(host, "docker_state", "")
    if host is not None and state in (platform_info.DOCKER_DOWN, platform_info.DOCKER_TIMEOUT):
        return host.docker_remedy() + " " + alt
    if docker_cli is None:
        docker_cli = (state != platform_info.DOCKER_MISSING
                      and shutil.which("docker") is not None)
    # Docker is probed once, at Studio start (wizard.host), and nothing re-asks before a
    # restart: "check again" alone would show the same blocker forever.
    if docker_cli:
        return ("docker.exe is installed but the Docker engine does not answer: start "
                "Docker Desktop, wait until it says the engine is running, then restart "
                "the Studio so it checks again. " + alt)
    return ("docker.exe was not found: install Docker Desktop "
            "(https://www.docker.com/products/docker-desktop/), start it, then restart "
            "the Studio so it checks again. " + alt)


def docker_limit_args(host=None) -> list[str]:
    """The full ``docker run`` resource-limit wrapper for a builder run: CPU, memory
    and GPU, resolved by :mod:`hugmesh_studio.core.resource_limits`.

    ``host`` is the driver's HostInfo. On a Mac its Docker VM's CPU count
    (``docker_vm_cpus``, read from ``docker info``) is the ceiling for ``--cpus``:
    dockerd refuses a container that asks for more CPUs than its VM has, and the auto
    formula counts the MAC's cores (platform_info.docker_engine_cpus; 0 on every other
    host, which clamps nothing). Without ``host`` the count detect() recorded applies.

    Supersedes :func:`docker_memory_args`, which capped memory and left CPU
    unbounded — half of the 2026-07-15 host-freeze defence. With every limit off this
    returns ``[]`` and the surrounding argv is byte-identical to the pre-guard
    command, which is what keeps the committed command-string tests valid.

    Evaluated at command()-assembly time, so the PREVIEW the operator is shown and
    the argv that is DISPATCHED are the same by construction."""
    engine = None if host is None else platform_info.docker_engine_cpus(host)
    return resource_limits.docker_run_args(resource_limits.effective(engine=engine))


def docker_memory_args() -> list[str]:
    """The container memory-cap leg of the docker-run wrapper: ``[]`` (cap disabled /
    memory unknown) or ``["--memory", v, "--memory-swap", v]``. memory-swap == memory
    means ZERO container swap — a runaway compile OOMs promptly instead of thrashing
    the host's swap (the 2026-07-15 freeze signature). Knob: HUGMESH_BUILD_MEMORY
    (unset = auto formula; 0/off/none = no cap; anything else = verbatim docker size).

    Module-level (not a BuildDriver method) so FleetDriver.command (core/fleet.py) can
    adopt the identical cap as a two-line follow-up — the actual incident was a fleet
    build. Evaluated at command()-assembly time, so preview == dispatch by construction."""
    v = host_resources.build_memory_flag()
    if v is None:
        return []
    return ["--memory", v, "--memory-swap", v]


# ── elevation refusal ──────────────────────────────────────────────────────────────
#: argv[0] basenames that mean "become another user". A build spawned through one of
#: these blocks on a password prompt the process may be unable to answer — the
#: 2026-09-04 incident: Studio pytest runs (tests/test_pages_fields_asks.py arriving at
#: the ProgressPage, which dispatches on arrival) launched the REAL
#: `sudo -A bash ./build-x86-host-stage4.sh` with the Qt askpass as SUDO_ASKPASS; 60
#: root-owned launchers were found hung on an OFFSCREEN password dialog, some two
#: days old, each pinning a 15-58 MB Qt helper. Nothing ever authenticated.
ELEVATION_PROGRAMS = frozenset({"sudo", "pkexec", "doas", "su", "run0"})

#: Set (anything but 0/off/false/no) to make this process refuse to spawn ANY elevation
#: program: headless automation, CI, a box with no admin password. The refusal is a
#: hard error (ElevationRefused), never a silent un-elevated build. Also honoured by the
#: askpass helper itself (core/askpass.py), which then answers nothing.
NO_ELEVATION_ENV = askpass.NO_ELEVATION_ENV

#: Deliberate opt-out for the handful of tests whose SUBJECT is the sudo/pkexec argv or
#: the SUDO_ASKPASS env plumbing: they fake subprocess.Popen/run and need the driver to
#: reach that fake. Set to "1" in the test body, next to the fake. NO_ELEVATION_ENV
#: still wins over it, and tests/conftest.py's spy on the REAL subprocess.Popen has no
#: opt-out at all — a test that sets this and forgets the fake still cannot start sudo.
ALLOW_ELEVATION_UNDER_TEST_ENV = "HUGMESH_STUDIO_ALLOW_ELEVATION_UNDER_TEST"


class ElevationRefused(RuntimeError):
    """Raised INSTEAD of spawning sudo/pkexec when this process must not elevate."""


def elevation_refusal() -> str | None:
    """Why this process must not spawn an elevation program, or ``None`` when it may.

    Two triggers, in this order:

    * :data:`NO_ELEVATION_ENV` is set — the operator's / the automation's explicit
      word, which nothing overrides;
    * pytest is running this process (:func:`state_paths.under_pytest`) — a test that
      reaches a real ``sudo`` has a missing stub, never a legitimate need. The one
      exception is :data:`ALLOW_ELEVATION_UNDER_TEST_ENV`, for tests that fake the
      process layer and assert the argv it would have received.

    Pinned by tests/test_build_driver_elevation.py; the production GUI (no pytest, no
    env) is untouched: a real operator run with a TTY, a dialog opt-in or a credential
    source elevates exactly as before.
    """
    if askpass.no_elevation():
        return f"{NO_ELEVATION_ENV} is set"
    if state_paths.under_pytest() and os.environ.get(ALLOW_ELEVATION_UNDER_TEST_ENV) != "1":
        return ("pytest is running this process — a test that reaches a real elevation "
                "program is missing a BuildDriver stub (see tests/test_pages_progress.py "
                f"FakeBuildDriver); {ALLOW_ELEVATION_UNDER_TEST_ENV}=1 is only for tests "
                "that fake subprocess and assert the argv")
    return None


def guard_elevation(cmd: list[str]) -> None:
    """Refuse (:class:`ElevationRefused`) to run ``cmd`` when its program is an
    elevation program and :func:`elevation_refusal` says this process may not elevate.

    The single choke point for every sudo/pkexec spawn in the driver — the build itself
    (:meth:`BuildDriver._spawn`, inherited by FleetDriver) and the kill-tree
    (:meth:`BuildDriver._kill_native_group`) — called immediately before the
    ``subprocess`` call so nothing can slip between the decision and the spawn.
    Commands that do not elevate (root, docker, plain bash) pass untouched. The message
    names only the leading tokens: a builder argv can carry --user-password."""
    prog = os.path.basename(cmd[0]) if cmd else ""
    if prog not in ELEVATION_PROGRAMS:
        return
    why = elevation_refusal()
    if why is None:
        return
    raise ElevationRefused(
        f"refusing to spawn {prog} ({why}): this process must not elevate, and an "
        f"unanswerable password prompt would leave a root-owned launcher hung forever "
        f"(command starts: {shlex.join(cmd[:4])} ...)")


def _operator_askpass() -> str | None:
    """An operator-supplied ``SUDO_ASKPASS`` to honour instead of generating our own
    (#221), or ``None``. Only an EXISTING executable that is not our own generated
    helper qualifies — so a stale/empty value never wins, and we never recurse into
    the helper we wrote. When present, a ``sudo -A`` build defers to the operator's
    program (a secret manager, a corp askpass, a test stub) untouched."""
    p = os.environ.get("SUDO_ASKPASS")
    if not p:
        return None
    if _ASKPASS_PATH_CACHE and os.path.abspath(p) == os.path.abspath(_ASKPASS_PATH_CACHE):
        return None
    return p if os.access(p, os.X_OK) else None


def askpass_helper_body(frozen: bool | None = None, executable: str | None = None) -> str:
    """The text of the generated ``SUDO_ASKPASS`` helper.

    From a checkout or a wheel it re-runs THIS interpreter as ``python -m hugmesh_studio``
    with PYTHONPATH pinned to the studio root. A FROZEN Studio (the MSI, the Linux
    tarball, the macOS .app) has no interpreter to re-run: ``sys.executable`` is the
    app's own executable, whose argparse refuses ``-m``, so the helper printed a usage
    error instead of a password and every ``sudo -A`` build failed authentication. There
    it runs the executable itself with ``--askpass-gui``. ``frozen`` / ``executable``
    default to ``sys.frozen`` / ``sys.executable`` and are for tests."""
    frozen = bool(getattr(sys, "frozen", False)) if frozen is None else frozen
    executable = sys.executable if executable is None else executable
    head = (
        "#!/bin/sh\n"
        "# Auto-generated by HugMesh Image Studio: a GUI askpass helper so a native\n"
        "# (sudo) build launched from the GUI prompts for the admin password in a dialog\n"
        "# rather than an invisible terminal. Safe to delete; it is recreated on demand.\n"
        "# --askpass-gui is the explicit dialog opt-in (a GUI-launched build is the one\n"
        "# caller entitled to it); the bare --askpass never pops a dialog.\n"
    )
    if frozen:
        return head + f"exec {shlex.quote(executable)} --askpass-gui\n"
    studio_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    return (head
            + f'export PYTHONPATH="{studio_root}${{PYTHONPATH:+:$PYTHONPATH}}"\n'
            + f"exec {shlex.quote(executable)} -m hugmesh_studio --askpass-gui\n")


def _askpass_helper_path() -> str | None:
    """The ``SUDO_ASKPASS`` program for a GUI-launched ``sudo -A`` build: an
    operator-supplied one if present (honoured verbatim — #221), else a tiny
    executable we generate that runs ``python -m hugmesh_studio --askpass-gui``.
    Returns its path, or ``None`` if none is available and none can be written.

    ``--askpass-gui`` is the EXPLICIT dialog opt-in: this helper is only ever generated
    for a GUI-launched build (``graphical=True``), which is the one caller entitled to
    a password dialog. The bare ``--askpass`` never pops one — a headless run (no TTY on
    stdin, no credential source) fails fast there instead of blocking forever on an
    offscreen dialog, which is how 60 root-owned launchers came to be hung.

    Pointed at by ``SUDO_ASKPASS`` so ``sudo -A`` reads the admin password from the
    helper's stdout instead of prompting into an invisible terminal (the hang this
    fixes). The generated helper is self-contained: it re-execs THIS interpreter and
    pins PYTHONPATH to the studio root so the package resolves whether Studio is
    installed or run from a source checkout."""
    op = _operator_askpass()
    if op is not None:
        return op
    global _ASKPASS_PATH_CACHE
    if _ASKPASS_PATH_CACHE and os.path.exists(_ASKPASS_PATH_CACHE):
        return _ASKPASS_PATH_CACHE
    body = askpass_helper_body()
    cache_dir = os.path.join(
        os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
        "hugmesh-studio")
    for target in (os.path.join(cache_dir, "studio-askpass.sh"),):
        try:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "w", encoding="utf-8") as fh:
                fh.write(body)
            os.chmod(target, 0o755)
            _ASKPASS_PATH_CACHE = target
            return target
        except OSError:
            continue
    return None


def shared_assets_root(out_dir: str) -> str:
    """The fleet-wide SHARED build-asset root (stage3 seed cache / distfiles / binpkg
    pools) for a builder whose work dir is ``out_dir``.

    The builders default this to ``<work-dir>/shared`` themselves, and for a make-driven
    build that is already right. The Studio is the caller that MUST be explicit: a GUI
    run's work dir is the PER-SESSION ``<out>/sessions/<id>`` (build_sessions.
    session_workdir), so the builder-side default would resolve to a per-session root and
    share nothing across sessions — which is exactly the reuse gap this exists to close.
    We therefore strip a trailing ``sessions/<id>`` and anchor the root at the stable
    ``<out>`` the operator chose. That also keeps the root INSIDE the docker ``-v
    <out>:/out`` mount whenever the driver is not session-overridden."""
    base = os.path.abspath(out_dir)
    parent, name = os.path.split(base)
    grandparent, sessions = os.path.split(parent)
    if name and sessions == "sessions" and grandparent:
        base = grandparent
    return os.path.join(base, "shared")


# ---- free-space preflight ------------------------------------------------------------
# Defect L4, session 20261110-220215-cde67f: a 23-image mesh ran for 1.5 h into a full
# disk. ENOSPC stopped its FIRST image at the .img step ("sfdisk: cannot open ...img",
# with a 22.7 GiB payload, 12 GiB of the .img and a 1.3 GiB stage4 written) and the four
# after it ("cannot open pool lockfile ... No space left on device", "tar: ... Cannot
# open: No space left on device"). How much was free when it started is not recorded.
# Nothing compared free space with what an image needs, before the session or between
# images, so the record held mid-build crashes where a refusal belonged. WorklistDriver
# checks these numbers before the session (blocking for the first image, advisory for the
# whole list) and again before each queued image. FleetDriver (build-all-roles.sh) does
# not use them.
GIB = 1024 ** 3
#: The most one x86 image holds under its work dir at once, taken from that session's pki
#: node: its build system (the sysroot, a 22.7 GiB payload), the stage4 (1.3 GiB), the raw
#: .img (27.5 GiB: the payload plus 15 %, and a filesystem that does not keep it sparse
#: stores all of it), the filesystem tarball and the compressed image (about 3 GiB). The
#: ISOs come after the raw .img has been replaced by its .xz and peak lower.
X86_IMAGE_SPACE_GIB = 55
#: The part of that which is the build system. A build that finds an earlier run's build
#: system in its work dir does not need this part again (see :func:`image_space`); the
#: other 32 GiB it writes every time.
X86_TREE_SPACE_GIB = 23
#: One ARM image (rpi5, jetson, frite, Orange Pi): a smaller payload and its .img.
ARM_IMAGE_SPACE_GIB = 20
#: Its build system's part. No more than 7, because every build writes the rest again:
#: for an rpi5 node the 9.5 GiB raw .img (a 9216 MiB root that the payload must fit), the
#: stage4, the filesystem tarball and the compressed image, about 12.5 GiB together.
ARM_TREE_SPACE_GIB = 7
#: Kept free on top of an image's estimate. The output dir usually shares a filesystem
#: with docker volumes and the rest of the host, and a disk filled to the last byte takes
#: those down with the build (it killed a live 56-container mesh on 2026-08-14).
SPACE_MARGIN_GIB = 10
#: Operator override for the per-image estimate: unset or "" = the table above;
#: 0/off/none = no free-space check; a positive number = that many GiB per image (the
#: margin still applies). Anything else is ignored, so a typo never turns the check off.
SPACE_ENV = "HUGMESH_BUILD_IMAGE_SPACE"
_SPACE_OFF = ("0", "off", "none")
#: The longest :func:`measure_tree` reads one build system before it settles for what it
#: has counted. Reading a real 24 GiB x86 tree took 43 s, and a 15 GiB rpi5 one 115 s, on
#: the incident host (an encrypted home under a running build).
TREE_MEASURE_SECONDS = 300
_TREE_CHECK_EVERY = 256        # entries read between two looks at the clock and at Stop


def image_space_estimate_bytes(cfg, env=None) -> int:
    """Bytes one image is expected to leave under its work dir; 0 = check switched off.

    Builds in one session accumulate (each entry keeps its own ``wl-<id>`` tree beside
    its products), so this is what the image ADDS, and the next image must fit into
    what is left after it."""
    env = os.environ if env is None else env
    raw = (env.get(SPACE_ENV) or "").strip().lower()
    if raw in _SPACE_OFF:
        return 0
    try:
        gib = float(raw) if raw else 0.0
    except ValueError:
        gib = 0.0
    if gib > 0 and math.isfinite(gib * GIB):
        return int(gib * GIB)
    platform = getattr(cfg, "platform", "") or "x86"
    return (X86_IMAGE_SPACE_GIB if platform == "x86" else ARM_IMAGE_SPACE_GIB) * GIB


class ImageSpace(NamedTuple):
    """What one image needs from the disk under its work dir."""
    estimate: int       #: bytes it holds there at once, built from nothing; 0 = check off
    share: int          #: of those, the bytes ``sysroot`` may already hold (0 without one)
    sysroot: str        #: the build system an earlier run left for it, "" when none

    def need(self, credit: int = 0) -> int:
        """Free bytes the image needs when ``credit`` bytes of it are already in
        ``sysroot``. No more than ``share`` is ever counted: the rest of the estimate
        is written by every build."""
        return self.estimate - max(0, min(credit, self.share)) + SPACE_MARGIN_GIB * GIB

    def credit_wanted(self, free: int) -> int:
        """Bytes ``sysroot`` must already hold for the image to fit into ``free``; 0
        when no measurement could change the answer (the check is off, free space is
        unknowable, the image fits with nothing counted, or it would not fit even
        over a finished tree)."""
        if not self.estimate or free < 0:
            return 0
        wanted = self.need() - free
        return wanted if 0 < wanted <= self.share else 0


def image_space(cfg, build_tree: str = "", env=None) -> ImageSpace:
    """The space ``cfg``'s image needs, given ``build_tree``, its ``wl-<id>`` dir.

    A build into a work dir an earlier run used (a RESTART into the same session)
    finds that run's build system at ``<build_tree>/sysroot``, and does not need the
    space it holds a second time, whichever way the build goes. With ``--resume`` every
    builder skips the stage3 extraction and continues from it. Without, x86, rpi5,
    orangepi5 and orangepi4-lts remove it and extract again, and the other six extract
    over it; both put the new build system where the old one was.

    Only a POPULATED build system counts, by the test all ten builders make before they
    reuse one: ``sysroot/etc/gentoo-release`` exists. A run that died before or during
    the extraction leaves none (four of the incident session's six trees), and then
    nothing is counted."""
    estimate = image_space_estimate_bytes(cfg, env)
    sysroot = os.path.join(build_tree, "sysroot") if build_tree else ""
    if not estimate or not os.path.isfile(os.path.join(sysroot, "etc", "gentoo-release")):
        return ImageSpace(estimate, 0, "")
    x86 = (getattr(cfg, "platform", "") or "x86") == "x86"
    tree, image = ((X86_TREE_SPACE_GIB, X86_IMAGE_SPACE_GIB) if x86
                   else (ARM_TREE_SPACE_GIB, ARM_IMAGE_SPACE_GIB))
    # The override replaces the estimate, and the build system keeps its proportion of it.
    return ImageSpace(estimate, estimate * tree // image, sysroot)


class TreeMeasure(NamedTuple):
    """What :func:`measure_tree` found. ``bytes`` is a LOWER bound whenever the walk did
    not read everything, which the other three fields say."""
    bytes: int                  #: allocated bytes it counted
    cut_short: bool = False     #: the time limit ended the walk
    unreadable: int = 0         #: directories and files it could not read (not counted)
    stopped: bool = False       #: ``should_stop()`` ended the walk


def _allocated_bytes(st) -> int:
    """What one directory entry takes on disk: its blocks (512 bytes each, whatever the
    filesystem's own block size), so a sparse file counts for what it really holds.
    Where a stat carries no block count (Windows) its length is the best there is."""
    blocks = getattr(st, "st_blocks", None)
    return st.st_size if blocks is None else blocks * 512


def measure_tree(path: str, *, enough: int = 0, seconds: float = TREE_MEASURE_SECONDS,
                 should_stop: Callable[[], bool] | None = None) -> TreeMeasure:
    """Count the bytes allocated under ``path``, a build system an earlier run left.

    Never on the GUI thread: this reads every directory, and a real tree takes from
    seconds to minutes. It returns as soon as ``enough`` bytes are counted (the caller
    needs no more than that to decide), at the ``seconds`` limit, or when
    ``should_stop()`` says the operator stopped the image.

    It never counts more than is there. Symlinks are not followed. Anything on another
    filesystem is skipped (a crashed build leaves /proc, /sys and /dev bound under its
    sysroot). A file with several names is counted once. What cannot be read (the
    tree is root's, and a few of its directories are root-only) is left out and
    reported in ``unreadable``. Blocks are counted, not lengths, so a sparse file
    counts for what it really holds; without block counts (Windows) lengths are used."""
    try:
        device = os.stat(path).st_dev
    except OSError:
        return TreeMeasure(0, unreadable=1)
    deadline = time.monotonic() + seconds
    total = unreadable = seen = 0
    linked: set[tuple[int, int]] = set()
    pending = [path]
    while pending:
        try:
            entries = os.scandir(pending.pop())
        except OSError:
            unreadable += 1
            continue
        with entries:
            for entry in entries:
                seen += 1
                if seen % _TREE_CHECK_EVERY == 0:
                    if should_stop is not None and should_stop():
                        return TreeMeasure(total, unreadable=unreadable, stopped=True)
                    if time.monotonic() > deadline:
                        return TreeMeasure(total, cut_short=True, unreadable=unreadable)
                try:
                    st = entry.stat(follow_symlinks=False)
                except OSError:
                    unreadable += 1
                    continue
                # st_dev is 0 from a Windows directory listing: nothing to compare.
                if st.st_dev and st.st_dev != device:
                    continue
                if stat.S_ISDIR(st.st_mode):
                    pending.append(entry.path)
                elif st.st_nlink > 1:
                    if (st.st_dev, st.st_ino) in linked:
                        continue
                    linked.add((st.st_dev, st.st_ino))
                total += _allocated_bytes(st)
                if enough and total >= enough:
                    return TreeMeasure(total, unreadable=unreadable)
    return TreeMeasure(total, unreadable=unreadable)


#: The seam :func:`dispatch_space_refusal` measures through, so a test can answer for a
#: tree it does not have (as ``emulation_save._disk_usage`` is for free space).
_measure_tree = measure_tree


def _passes_resume(cfg) -> bool:
    """Is ``--resume`` in the argv the Studio dispatches for ``cfg``? Read from the argv,
    so it is what the builder gets, including a ``--resume`` typed into the extra flags."""
    try:
        return "--resume" in cfg.to_cli_args()
    except (AttributeError, ValueError):       # not a config, or one that cannot be built
        return bool(getattr(cfg, "resume", False))


def _space_refusal(space: ImageSpace, cfg, out_dir: str, free: int,
                   reused: TreeMeasure | None) -> str:
    """The one place a need is compared with ``free`` and a refusal is worded.

    ``reused`` is what a measurement of ``space.sysroot`` found, or None when it was not
    measured. Unmeasured, an earlier build system is taken as finished: only an image
    that would not fit even then is refused."""
    if not space.estimate or free < 0 or free >= space.need():
        return ""
    wanted = space.credit_wanted(free)
    if wanted and (reused is None or reused.bytes >= wanted):
        return ""
    what = (f"{getattr(cfg, 'role', '') or 'this image'} "
            f"({getattr(cfg, 'platform', '') or 'x86'})")
    override = f"set {SPACE_ENV} to the GiB one image needs (0 turns this check off)."
    if not space.sysroot:
        need = space.need()
        return (f"not enough free disk space under {out_dir} for {what}: it needs about "
                f"{need / GIB:.0f} GiB ({space.estimate / GIB:.0f} GiB for its build tree "
                f"and images, plus a {SPACE_MARGIN_GIB} GiB margin), but only "
                f"{free / GIB:.1f} GiB is free, {(need - free) / GIB:.1f} GiB short. Free "
                f"space on that disk (earlier build sessions under the output folder's "
                f"sessions/ are the usual bulk), choose an output folder on a bigger "
                f"disk, or {override}")
    how = ("continues from it (the builder is passed --resume)" if _passes_resume(cfg)
           else "rebuilds it in place (the builder is not passed --resume)")
    if wanted:
        # Measured, and not enough of the tree is there.
        need = space.need(reused.bytes)
        notes = []
        if reused.cut_short:
            notes.append(f"measuring it stopped at the {TREE_MEASURE_SECONDS}-second limit")
        if reused.unreadable:
            notes.append(f"{reused.unreadable} of its directories or files could not be "
                         f"read and are not counted")
        counted = (f"It holds {'at least ' if reused.cut_short else ''}"
                   f"{reused.bytes / GIB:.1f} GiB{' (' + '; '.join(notes) + ')' if notes else ''}"
                   f", so the image still")
        rest = "the rest of its build tree and its images"
    else:
        need = space.need(space.share)
        counted = f"Even with all {space.share / GIB:.0f} GiB counted, the image still"
        rest = "the images and archives every build writes again"
    return (f"not enough free disk space under {out_dir} for {what}: an earlier run left "
            f"this image's build tree at {space.sysroot}, and this run {how}, so what "
            f"that tree already holds is not needed again and is counted, up to the "
            f"{space.share / GIB:.0f} GiB a finished one takes. {counted} needs about "
            f"{need / GIB:.0f} GiB ({(need - SPACE_MARGIN_GIB * GIB) / GIB:.0f} GiB for "
            f"{rest}, plus a {SPACE_MARGIN_GIB} GiB margin), but only {free / GIB:.1f} GiB "
            f"is free, {(need - free) / GIB:.1f} GiB short. Free space elsewhere on that "
            f"disk (other build sessions under the output folder's sessions/ are the "
            f"usual bulk), or {override}")


def disk_space_refusal(cfg, out_dir: str, *, build_tree: str = "",
                       reused: TreeMeasure | None = None, free: int | None = None,
                       disk_usage=None, env=None) -> str:
    """Why the filesystem under ``out_dir`` cannot take this image now, or "" when it can.

    Free space comes from :func:`emulation_save.free_bytes_for`, which walks up to the
    nearest existing ancestor (a session dir does not exist before dispatch) and whose
    probe is the injectable ``emulation_save._disk_usage``. Its -1 (unknowable) never
    refuses, the same rule :func:`emulation_save.preflight_refusal` follows.

    ``build_tree`` is this image's ``wl-<id>`` dir; what an earlier run's build system
    under it already holds is not needed again (:func:`image_space`). This function
    never measures it, so it is safe on the GUI thread: without ``reused`` it takes a
    populated build system as finished, and refuses only an image that would not fit
    even then. :func:`dispatch_space_refusal` is the check that measures."""
    if free is None:
        free = emulation_save.free_bytes_for(out_dir, disk_usage)
    return _space_refusal(image_space(cfg, build_tree, env), cfg, out_dir, free, reused)


def dispatch_space_refusal(cfg, out_dir: str, *, build_tree: str = "",
                           should_stop: Callable[[], bool] | None = None,
                           on_measure: Callable[[str], None] | None = None,
                           disk_usage=None, env=None) -> str | None:
    """:func:`disk_space_refusal` for the moment right before an image is dispatched,
    on the build thread: here an earlier run's build system is MEASURED when the answer
    depends on how much of it is there, and only what was found is counted. A run that
    died early leaves a populated build system of a few GiB; taking that one as
    finished would start a build 20 GiB short.

    The walk is asked for no more than the bytes that make the image fit, and is
    skipped when no result could change the answer. ``on_measure(sysroot)`` is called
    before it starts. Returns None when ``should_stop()`` ended it: the operator
    stopped the image, and there is no verdict to give."""
    space = image_space(cfg, build_tree, env)
    free = emulation_save.free_bytes_for(out_dir, disk_usage)
    wanted = space.credit_wanted(free)
    reused = None
    if wanted:
        if on_measure is not None:
            on_measure(space.sysroot)
        reused = _measure_tree(space.sysroot, enough=wanted, should_stop=should_stop)
        if reused.stopped:
            return None
    return _space_refusal(space, cfg, out_dir, free, reused)


def disk_space_warning(cfgs, out_dir: str, *, build_trees=(), disk_usage=None,
                       env=None) -> str:
    """ADVISORY: the first image passes but the whole sequence does not fit; "" otherwise.

    Also "" when the first image is refused (:func:`disk_space_refusal` blocks that
    case, and this asks it, so the two cannot disagree), when the check is off, and when
    free space is unknowable. ``build_trees`` are the images' ``wl-<id>`` dirs, in
    order; a populated build system under one is counted as finished, as the refusal
    does, and never measured."""
    cfgs = list(cfgs)
    trees = [*build_trees, *[""] * len(cfgs)][:len(cfgs)]
    spaces = [image_space(c, t, env) for c, t in zip(cfgs, trees)]
    if not spaces or not spaces[0].estimate:
        return ""
    free = emulation_save.free_bytes_for(out_dir, disk_usage)
    if free < 0 or _space_refusal(spaces[0], cfgs[0], out_dir, free, None):
        return ""
    margin = SPACE_MARGIN_GIB * GIB
    total = sum(s.need(s.share) - margin for s in spaces) + margin
    if free >= total:
        return ""
    reusing = sum(1 for s in spaces if s.sysroot)
    counted = (f", and counting the build trees {reusing} of them already have from an "
               f"earlier run as finished" if reusing else "")
    # A run over earlier build trees is pinned to the folder they are in.
    remedy = ("Free space elsewhere on that disk" if reusing
              else "Free space or choose an output folder on a bigger disk")
    return (f"not enough free disk space under {out_dir} for the whole worklist: its "
            f"{len(spaces)} images need about {total / GIB:.0f} GiB together "
            f"(including a {SPACE_MARGIN_GIB} GiB margin{counted}), but only "
            f"{free / GIB:.1f} GiB is free. The first image passes this check, so the "
            f"session can start. Every image is re-checked before it starts and refused "
            f"(marked failed, with the reason) if it does not fit by then. {remedy} to "
            f"build them all.")


class BuildDriver:
    def __init__(self, generator_dir: str, host: HostInfo | None = None, *,
                 graphical: bool = False, workdir: str | None = None,
                 shared_assets: str | None = None):
        self.generator_dir = os.path.abspath(generator_dir)
        self.host = host or detect()
        # Runtime-only work-dir override (per-session artifact dirs, GUI dispatch).
        # None (the default — every --print-* channel, the goldens, and the unit tests)
        # keeps the computed out dir byte-identical to before: `cfg.output_dir or
        # <generator>/out`. The override is DRIVER state, never config state — it is
        # deliberately never written into cfg.output_dir, so config save/load and
        # --print-specs round-trip untouched for the same config.
        self.workdir = workdir
        # Shared build-asset root override. None (the default) = derive it from the work
        # dir via shared_assets_root(); "" = OPT OUT, emitting --no-shared-assets so the
        # builder falls back to its private per-BUILD_ROOT seed/distfiles/pkgdir. Driver
        # state, never config state — same discipline as `workdir`.
        self.shared_assets = shared_assets
        # A GUI-launched build (True) must never route a sudo password prompt into an
        # invisible terminal: _elevation_prefix picks a GRAPHICAL auth path (sudo -A +
        # a Qt askpass, else pkexec) instead of bare `sudo`. A terminal/headless launch
        # (False, the default — every --print-* channel and the unit tests) keeps the
        # plain-`sudo` prefix so the printed command stays copy-pasteable and the
        # sudo-prefix strippers (test_headless, build-matrix check.sh) keep matching.
        self.graphical = graphical
        self._proc: subprocess.Popen | None = None
        self._cancel = threading.Event()
        # Cancel needs a HANDLE on the running child that survives the wrapper layers
        # between us and the actual builder (PID1 bash in docker, root-owned sudo
        # natively). We stamp a stable container name onto every docker run so
        # `docker kill <name>` can reach PID1 (the bash builder ignores TERM forwarded
        # to the docker CLI), and we run native builds in a fresh session/process group
        # so `kill -TERM -<pgid>` (sudo-wrapped when non-root) reaches the whole tree —
        # today's plain Popen.terminate() only signals the docker CLI / EPERMs against
        # the root-owned sudo. One driver per image (WorklistDriver makes a fresh
        # BuildDriver per entry), so the name is unique per build.
        self._container_name = f"sd-build-{uuid.uuid4().hex[:12]}"
        self._backend: str | None = None   # backend of the in-flight/last run — cancel keys on it
        self._pgid: int | None = None       # native process-group id (== child pid via setsid)

    # ---- elevation ---------------------------------------------------------
    def _elevation_prefix(self) -> list[str]:
        """The privilege-escalation prefix for a native build (and its kill), single-
        sourced so command() and _kill_native_group can never diverge. root -> [] (no
        wrapper). Non-root TERMINAL launch -> ["sudo"] (unchanged: plain prompt on the
        controlling tty). Non-root GUI launch -> a GRAPHICAL auth path: `sudo -A` with a
        Qt askpass helper when both are available (reuses the sudo launch/kill nearly
        verbatim and benefits from sudo's credential cache on a quick cancel), else
        `pkexec` (polkit). Falls back to plain `sudo` only if neither graphical path is
        installed — best effort over silently failing to elevate."""
        if self.host.is_root:
            return []
        if not self.graphical:
            return ["sudo"]
        if shutil.which("sudo") and _askpass_helper_path() is not None:
            return ["sudo", "-A"]
        if shutil.which("pkexec"):
            return ["pkexec"]
        return ["sudo"]

    def _can_elevate(self) -> bool:
        """True iff a non-root native build can actually reach root. Single-sources the
        SAME helpers _elevation_prefix() picks from, so preflight() can never block a
        build the driver would have elevated fine (the pre-2026-07-17 bug: preflight
        appended a BLOCKING problem whose own text said "the Studio will prepend sudo",
        so a GUI Studio — never run as root — could never dispatch ANY native build)."""
        return bool(shutil.which("sudo") or shutil.which("pkexec"))

    def _elevation_env(self) -> dict[str, str] | None:
        """Caller-side environment the elevation prefix needs, or ``None`` to inherit the
        ambient env unchanged. Only ``sudo -A`` needs anything (SUDO_ASKPASS pointing at
        the helper — an operator-supplied one if present, else our generated Qt helper);
        every other prefix — [], plain sudo, pkexec — returns None so the root /
        terminal-sudo / docker Popen and kill stay byte-identical to before."""
        if self._elevation_prefix()[:2] == ["sudo", "-A"]:
            helper = _askpass_helper_path()
            if helper:
                return {**os.environ, "SUDO_ASKPASS": helper}
        return None

    # ---- command assembly --------------------------------------------------
    def _passthrough_env(self, cfg: ImageConfig) -> dict[str, str]:
        """Config values the build environment consumes from ENV VARS, not argv:
        HEADSCALE_URL (G2) is baked to /etc/hugmesh/headscale-url by the x86/
        rpi5/frite builders when set (build-x86:2843, rpi5:2421, frite:948) — there
        is deliberately NO builder flag for it (the Makefile's BRAND_ENV rides the
        same env channel). PENTEST=1 (G40) is the OWASP pen-test knob consumed by
        the fleet/make layer (scripts/build-all-roles.sh / the Makefile), forwarded
        here so the BuildPage checkbox is never a widget-level no-op and the same
        config drives every channel identically. HUGMESH_QEMU_E2E=1 rides the same
        channel for cfg.qemu_device_tests (the post-build emulated-device tests).
        THE ENV VAR KEEPS ITS NAME ON PURPOSE, and it does nothing for the builders: the
        only readers of HUGMESH_QEMU_E2E anywhere in this tree are
        tests/qemu/run-matrix-e2e.sh and the Makefile's `qemu-matrix` target — no
        build-*-stage4.sh looks at it. So its presence in a build environment is NOT
        evidence that anything is wired; the real post-build step is
        gui/pages/progress.py::_maybe_qemu_tests, which spawns
        tests/qemu/run-qemu-docker.sh directly. It is forwarded anyway so a build-side
        hook that ever wants the gate reads the SAME knob — never a builder flag.
        Empty/false values are omitted so an untouched config adds nothing."""
        env: dict[str, str] = {}
        if cfg.headscale_url:
            env["HEADSCALE_URL"] = cfg.headscale_url
        if cfg.pentest:
            env["PENTEST"] = "1"
        if cfg.qemu_device_tests:
            env["HUGMESH_QEMU_E2E"] = "1"
        return env

    def command(self, cfg: ImageConfig, backend: str | None = None,
                local_pass_file: str | None = None,
                extra_pass_file: str | None = None) -> list[str]:
        """The builder invocation for ``cfg``. ``local_pass_file`` (dispatch only —
        run()/iter_run() stage it) moves the login password off argv: the argv's
        ``--local-pass PASS`` becomes ``--local-pass-file PATH`` (docker: the file
        is mounted read-only at DOCKER_LOCAL_PASS_PATH). The preview channel passes
        nothing and is unchanged."""
        backend = backend or self.host.default_backend
        out = self.workdir or cfg.output_dir or os.path.join(self.generator_dir, "out")
        # cfg.platform picks the builder (x86/rpi5/frite/jetson); all four scripts sit
        # at the generator-repo root, so ./<script> works both natively (cwd =
        # generator_dir) and in the container (the repo is mounted at /src).
        script = f"./{cfg.builder_script}"
        # The shared-asset leg rides between the work-dir/jobs plumbing and the CONFIG
        # args — never after them. cfg.to_cli_args() ends with the operator's raw
        # `extra_flags`, and an escape hatch must stay LAST so a hand-typed
        # `--no-shared-assets` (or any other override) still wins the builder's
        # last-flag-wins argv parse. It is also the honest reading order: -w/-j and the
        # asset root are build-PHASE plumbing; everything after describes the image.
        inner = [script, "-w", "/out" if backend == "docker" else out,
                 "-j", str(cfg.jobs), *self._shared_assets_args(out), *cfg.to_cli_args()]
        if local_pass_file and cfg.local_pass:
            inner = _swap_local_pass(inner, cfg.local_pass, local_pass_file)
        # the Desktop step's extra accounts: a run stages their passwords (run/iter_run)
        extra_pass_file = extra_pass_file or getattr(self, "_extra_pass_file", None)
        if extra_pass_file:
            inner = _swap_extra_pass(inner, extra_pass_file)
        penv = self._passthrough_env(cfg)
        if backend == "native":
            # run in the generator dir; needs root for the chroot/loop ops.
            # Env passthrough rides an `env K=V` wrapper INSIDE the sudo boundary
            # (sudo's env_reset would strip a caller-side export), so the printed
            # command is copy-pasteable and run() needs no Popen env plumbing.
            env_wrap = ["env", *(f"{k}={v}" for k, v in penv.items())] if penv else []
            return self._elevation_prefix() + env_wrap + ["bash", *inner]
        if backend == "docker":
            # Asset paths outside the generator dir (wallpaper, branding dir, egress conf)
            # are not visible in the container — mount each and rewrite its flag value.
            asset_mounts, dcfg = self._remap_assets_for_docker(cfg)
            shared_mounts, shared_args = self._shared_assets_docker(out)
            dinner = [script, "-w", "/out", "-j", str(cfg.jobs), *shared_args,
                      *dcfg.to_cli_args()]
            if local_pass_file and cfg.local_pass:
                swapped = _swap_local_pass(dinner, dcfg.local_pass, DOCKER_LOCAL_PASS_PATH)
                if swapped != dinner:
                    dinner = swapped
                    asset_mounts = [*asset_mounts, "-v",
                                    f"{local_pass_file}:{DOCKER_LOCAL_PASS_PATH}:ro"]
            if extra_pass_file:
                swapped = _swap_extra_pass(dinner, DOCKER_EXTRA_PASS_PATH)
                if swapped != dinner:
                    dinner = swapped
                    asset_mounts = [*asset_mounts, "-v",
                                    f"{extra_pass_file}:{DOCKER_EXTRA_PASS_PATH}:ro"]
            env_args: list[str] = []
            for k, v in penv.items():
                env_args += ["-e", f"{k}={v}"]
            return [
                "docker", "run", "--rm", "--privileged",
                # Apple silicon only: the builder image is x86_64 (platform_info.
                # docker_platform_args); [] everywhere else.
                *platform_info.docker_platform_args(self.host),
                # --init: a real PID1 that reaps and forwards signals so `docker kill`
                # (cancel) actually stops the build instead of orphaning it. --name:
                # the stable handle cancel() targets.
                "--init", "--name", self._container_name,
                # Container CPU/memory/GPU caps (docker-run wrapper only — the inner
                # builder argv below is byte-untouched): see docker_limit_args.
                *docker_limit_args(self.host),
                "-v", f"{self.generator_dir}:/src",
                "-v", f"{out}:/out",
                *asset_mounts,
                *shared_mounts,
                *env_args,
                "-w", "/src", self.host.builder_image,
                "bash", "-c", shlex.join(dinner),
            ]
        raise RuntimeError("no usable build backend (need Gentoo native or Docker)")

    # ---- shared build assets ----------------------------------------------
    def _shared_assets_args(self, out: str) -> list[str]:
        """The ``--shared-assets DIR`` / ``--no-shared-assets`` leg of the builder argv.

        Emitted for EVERY Studio-dispatched build (and therefore visible in the command
        PREVIEW), because the builder-side default — ``<work-dir>/shared`` — is wrong for
        a Studio session: its work dir is ``<out>/sessions/<id>``, so the default would
        mint a fresh, empty root per session and every GUI build would re-download the
        stage3 seed and recompile the world from an empty pool."""
        if self.shared_assets == "":
            return ["--no-shared-assets"]
        return ["--shared-assets", self.shared_assets or shared_assets_root(out)]

    def _shared_assets_docker(self, out: str) -> tuple[list[str], list[str]]:
        """(extra docker -v args, builder argv) for the shared root under docker.

        The root always gets its OWN read-write bind mount at the fixed container path
        ``/shared``, and the builder is always told ``--shared-assets /shared``.

        WHY A MOUNT AT ALL, given <out>/shared is normally already inside ``-v out:/out``:
        for a MAKE-driven build it genuinely is, and the Makefile needs no change — the
        builder's own ``<work-dir>/shared`` default resolves to ``/out/shared``
        in-container with zero new mounts. But a STUDIO docker build mounts the
        PER-SESSION work dir (``<out>/sessions/<id>:/out``), and the shared root
        deliberately sits at the stable ``<out>/shared`` ABOVE it — outside that mount.
        So the Studio path needs a mount in the case that matters most, and making it
        unconditional buys two things worth more than one redundant bind:

          * the container-side path is ``/shared`` in EVERY Studio dispatch, so the
            command preview and the build log read the same on both mount layouts; and
          * the golden workdir invariant survives — a session work dir may still change
            ONLY the ``-v <host>:/out`` value and nothing else, because the shared root
            is derived from the STABLE out dir (shared_assets_root strips ``sessions/<id>``)
            and is therefore byte-identical with and without the override.

        The mount is read-WRITE: the builder creates and writes the seed cache, the pool
        and the distfiles there. That is why it is not in DOCKER_ASSET_FIELDS, whose
        entries are read-only inputs that must pre-exist."""
        if self.shared_assets == "":
            return [], ["--no-shared-assets"]
        host = os.path.abspath(self.shared_assets or shared_assets_root(out))
        return ["-v", f"{host}:/shared"], ["--shared-assets", "/shared"]

    def _host_path(self, p: str) -> str:
        """Where a path field's value points ON THE HOST. A relative value means relative
        to the generator checkout — the cwd every build runs in (native ``cwd=``, docker
        ``-w /src``) — never the Studio process's own cwd, which under a desktop launcher
        is usually $HOME. Typed ``brands/example.conf`` is the case this exists for."""
        return os.path.normpath(p if os.path.isabs(p) else os.path.join(self.generator_dir, p))

    def missing_host_path(self, p: str) -> str:
        """'' when ``p`` passes the existence test :meth:`preflight` applies to a path
        field's value; otherwise the host path it was looked for at. For a wizard page
        that refuses a missing file on the field it was typed into instead of at Review:
        same resolution (:meth:`_host_path` — relative means relative to the generator
        checkout, never the Studio's cwd), same ``os.path.exists``."""
        host = self._host_path(p)
        return "" if os.path.exists(host) else host

    def _docker_path(self, value: str, index: int) -> tuple[list[str], str | None]:
        """One host path value -> (extra docker args, its in-container value), or
        ``([], None)`` when it must be left exactly as it is.

        Decided on the REAL path (symlinks resolved on both sides, case-folded where the
        OS folds case): a link that lives in the checkout but points outside it is under
        /src by spelling only and would dangle in the container, so it is mounted like
        any other outside path. "Inside" needs the separator: a sibling such as
        ``hugmesh-generator-sibling/`` shares the checkout's name as a prefix and is not
        under it.

          * inside the checkout -> ``/src/<relative path>``; the repo is already mounted.
          * outside, and present -> bind-mounted read-only at ``/assets/<i>/<basename>``
            (the basename the operator gave, so a theme dir keeps its name).
          * outside, and missing -> left alone. ``docker run -v`` would CREATE the
            missing source as an empty root-owned directory on the host; the builder's
            own guard reports the bad path instead (and preflight already blocks one
            that must exist)."""
        host = self._host_path(value)
        real = os.path.realpath(host)
        real_gen = os.path.realpath(self.generator_dir)
        nc = os.path.normcase
        if nc(real) == nc(real_gen) or nc(real).startswith(nc(real_gen.rstrip(os.sep)) + os.sep):
            if not os.path.isabs(value) and nc(host) == nc(real):
                # A plain relative spelling (no symlink on the way) already resolves
                # under the container's -w /src; keep it, so the argv reads as typed.
                return [], value.replace(os.sep, "/")
            rel = os.path.relpath(real, real_gen)
            return [], ("/src" if rel == os.curdir else "/src/" + rel.replace(os.sep, "/"))
        if not os.path.exists(real):
            return [], None
        cpath = f"/assets/{index}/{os.path.basename(host.rstrip(os.sep))}"
        return ["-v", f"{real}:{cpath}:ro"], cpath

    def _remap_assets_for_docker(self, cfg: ImageConfig) -> tuple[list[str], ImageConfig]:
        """Mount external asset paths into the container and return (mount-args, a config
        whose asset flags point at the in-container paths).

        Only a field this config's argv REALLY carries is touched (_emitted_path_fields):
        a stale x86-only value on an ARM config, or a brand profile on an unaffiliated
        image, is never emitted, so it is neither mounted nor rewritten. Each emitted one
        goes through :meth:`_docker_path`.

        The path under the checkout used to be left as the HOST path ("already under
        /src, reachable"), which it is not — the container sees the repo at /src. That is
        the "config file not found" every docker image of session 20261031-104549 died
        on, for a brands/*.conf the native backend read fine."""
        import copy
        dcfg = copy.deepcopy(cfg)
        mounts: list[str] = []
        emitted = _emitted_path_fields(cfg)
        for i, field in enumerate(DOCKER_ASSET_FIELDS + DOCKER_EXTRA_ASSET_FIELDS):
            p = getattr(dcfg, field, "")
            if not p or not _path_emitted(field, cfg, emitted):
                continue
            extra, cval = self._docker_path(p, i)
            if cval is None:
                continue
            mounts += extra
            setattr(dcfg, field, cval)
        return mounts, dcfg

    def command_string(self, cfg: ImageConfig, backend: str | None = None) -> str:
        return " ".join(shlex.quote(x) for x in self.command(cfg, backend))

    # ---- execution ---------------------------------------------------------
    def _spawn(self, cmd: list[str], backend: str) -> subprocess.Popen:
        """Popen cmd (cwd=generator_dir) recording the handle cancel() needs. Native
        builds get their own session (start_new_session) so the whole sudo→bash→emerge
        tree lands in one process group we can signal by negative pgid; docker builds
        are reached by container name instead."""
        self._cancel.clear()
        self._backend = backend
        self._pgid = None
        # A GUI `sudo -A` build needs SUDO_ASKPASS in the CALLER env so sudo can spawn the
        # Qt password dialog; every other launch inherits the ambient env (None). Only the
        # native path can elevate, so docker/other never carry it.
        spawn_env = self._elevation_env() if backend == "native" else None
        # LAST thing before the spawn: under pytest / HUGMESH_STUDIO_NO_ELEVATION a
        # sudo/pkexec launch is refused outright (ElevationRefused) rather than left to
        # hang on a prompt nobody can answer. See guard_elevation.
        guard_elevation(cmd)
        self._proc = subprocess.Popen(
            cmd, cwd=self.generator_dir, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1, start_new_session=(backend == "native"), env=spawn_env,
            # NOT bare text=True — that decodes with the launcher's locale, which is
            # routinely C/POSIX (i.e. ASCII) and then raises UnicodeDecodeError out of
            # the read the moment emerge emits a GCC smart quote. See core/proc_text.
            **proc_text.TEXT_IO)
        if backend == "native":
            # start_new_session makes the child a session/group leader → pgid == pid.
            self._pgid = self._proc.pid
        return self._proc

    def _stream(self, cmd: list[str], on_line: Callable[[str], None] | None,
                backend: str) -> int:
        """Spawn cmd, call on_line per output line, return the exit code. Shared by
        run() and build_builder_image() so both stream identically and both respect
        cancel(). On cancel the per-backend kill in cancel() stops the real build; here
        we only stop reading (the pipe closes when the child dies) and reap it."""
        proc = self._spawn(cmd, backend)
        assert proc.stdout is not None
        for line in proc.stdout:
            if on_line:
                on_line(line.rstrip("\n"))
            if self._cancel.is_set():
                break
        return proc.wait()

    def _consume_held_secret_files(
            self, cfg: ImageConfig) -> tuple[ImageConfig, Callable[[], None]]:
        """Swap vault-held secret-file fields to just-in-time private tmp copies for
        ONE run (the 2026-07-29 operator ask: "once the file is selected its held in
        memory until the build is completed" — see core/secret_files.py).

        Consumption rules, each relied on:
        * only a field the config ALREADY carries is swapped — the vault never adds a
          flag the preview didn't show (no injection: a leftover held key from an
          abandoned wizard walk must never silently sign an unrelated build);
        * only while the config's path still equals the entry's ``origin`` — a held
          copy corresponds to exactly one browsed selection, never to a different
          path the operator loaded/typed later;
        * only when this platform's builder actually receives the flag
          (_path_field_emitted — the same gate preflight uses), so an ARM entry in a
          mesh worklist provisions nothing;
        * headless/CLI processes never populate a vault, so this returns ``cfg``
          untouched there and every --print-*/golden channel stays byte-identical.

        Returns ``(run_cfg, cleanup)``; the caller MUST run cleanup() in a finally so
        no key material outlives the run — success, failure or cancel alike."""
        v = secret_files.vault()
        entries = []
        for f in secret_files.VAULT_FIELDS:
            path = getattr(cfg, f, "")
            held = v.get(f)
            if (path and held is not None and held.origin == path
                    and _path_field_emitted(f, cfg)):
                entries.append(held)
        if not entries:
            return cfg, (lambda: None)
        mat = secret_files.materialize(entries)
        import copy
        run_cfg = copy.deepcopy(cfg)
        for f, p in mat.paths.items():
            setattr(run_cfg, f, p)
        return run_cfg, mat.cleanup

    def _stage_extra_pass(self, cfg) -> Callable[[], None]:
        """Stage the Desktop step's extra accounts' passwords (a 0600 file for this one
        run; command() swaps it in for the preview placeholder) and return the cleanup."""
        text = getattr(cfg, "extra_local_passes", "") or ""
        if not text:
            return lambda: None
        path, cleanup = secret_files.stage_secret_file("extra-local-passes", text.encode("utf-8"))
        self._extra_pass_file = path

        def _done() -> None:
            self._extra_pass_file = None
            cleanup()
        return _done

    def _dispatch_command(self, cfg, backend: str, local_pass_file: str | None) -> list[str]:
        """The argv run() actually spawns: :meth:`command` with the dispatch-only
        staged files. FleetDriver overrides it to add its own (the NVD key pointer)."""
        return self.command(cfg, backend, local_pass_file=local_pass_file)

    def run(self, cfg: ImageConfig, backend: str | None = None,
            on_line: Callable[[str], None] | None = None) -> int:
        """Run the build, calling on_line for each output line. Returns the exit code.
        Blocking — callers run it on a worker thread (the GUI uses a QThread)."""
        backend = backend or self.host.default_backend
        out = self.workdir or cfg.output_dir or os.path.join(self.generator_dir, "out")
        os.makedirs(out, exist_ok=True)
        # Held-in-memory secret files (KEYS USB / SB signing key) are staged to a
        # private 0600 tmp copy for exactly this run and removed in the finally —
        # the same rewrite class as _remap_assets_for_docker (which then mounts the
        # tmp copy :ro under docker, since it lives outside the generator dir).
        run_cfg, cleanup_held = self._consume_held_secret_files(cfg)
        if run_cfg is not cfg and on_line is not None:
            on_line("== held-in-memory Secure Boot material staged to a private 0600 "
                    "temp copy for this run (removed when the run ends): "
                    + ", ".join(f"--{f.replace('_', '-')}" for f in
                                secret_files.VAULT_FIELDS
                                if getattr(run_cfg, f, "") != getattr(cfg, f, "")))
        # ELEVATION-CANCEL ATTRIBUTION (#222): a GUI native build elevates through
        # `sudo -A` / pkexec, and when the operator CANCELS the password dialog (or the
        # askpass otherwise yields nothing) sudo aborts and the build never runs as root.
        # Without this the operator sees a bare exit 1 and cannot tell a cancelled prompt
        # from a real build failure — the confusion behind "the build just keeps going and
        # then fails". Watch the stream (sudo's own stderr + our askpass CANCEL_MARKER are
        # folded in via stderr=STDOUT) for an auth-failure signature, and annotate. Native
        # + graphical elevation only; a user Stop is excluded (cancel() sets _cancel first).
        graphical_native = (backend == "native"
                            and self._elevation_prefix()[:2] in (["sudo", "-A"], ["pkexec"]))
        auth_failed = False
        watched_on_line = on_line
        if graphical_native and on_line is not None:
            def watched_on_line(line: str, _sink=on_line) -> None:  # noqa: E306
                nonlocal auth_failed
                if askpass.looks_like_auth_failure(line):
                    auth_failed = True
                _sink(line)
        # The login password: a private 0600 file for this run, never argv.
        pass_file: str | None = None
        cleanup_pass: Callable[[], None] = lambda: None  # noqa: E731
        try:
            # getattr: FleetDriver inherits this run() and a FleetConfig has no login
            # password — ``run_cfg.local_pass`` raised AttributeError there (#860), so
            # every "Build fleet now" aborted before anything was spawned.
            if getattr(run_cfg, "local_pass", ""):
                pass_file, cleanup_pass = secret_files.stage_local_pass(run_cfg.local_pass)
            cleanup_extra = self._stage_extra_pass(run_cfg)
            try:
                code = self._stream(self._dispatch_command(run_cfg, backend, pass_file),
                                    watched_on_line, backend)
            finally:
                cleanup_extra()
        finally:
            cleanup_pass()
            cleanup_held()
        if (graphical_native and code != 0 and on_line is not None
                and auth_failed and not self._cancel.is_set()):
            on_line("!! Administrator authentication was cancelled or failed — the build "
                    "did NOT start (nothing ran as root). Re-run and complete the password "
                    "prompt, or set HUGMESH_STUDIO_SUDO_PASSWORD / an operator SUDO_ASKPASS "
                    "for an unattended build.")
            return code
        # CAP-KILL ATTRIBUTION (the guard's failure UX): a container OOM-kill exits 137
        # with NO docker-side explanation on the stream — the compile log just ends
        # mid-line. Without this line, the one person the cap protects sees a bare
        # FAILED and blames their config. Only when a cap was actually in force, only
        # docker (native has no cgroup cap), and NOT on a user Stop (`docker kill` is
        # also SIGKILL/137 — cancel() sets _cancel first, and the worklist maps that
        # run to STOPPED). Wording says "likely": 137 is any SIGKILL, we cannot prove
        # the OOM-killer from the exit code alone. Log-text only — the exit code and
        # FAILED status stay untouched (the build DID fail; honestly).
        if (code == 137 and backend == "docker" and on_line is not None
                and not self._cancel.is_set()):
            cap = host_resources.build_memory_flag()
            if cap is not None:
                on_line(f"!! exit 137 — the builder container was likely killed by its "
                        f"memory cap (--memory {cap}), which protects the HOST from a "
                        f"runaway compile (2026-07-15 freeze guard). Remedies: lower "
                        f"parallel jobs, free host memory, or raise/disable the cap via "
                        f"{host_resources.MEMORY_ENV}.")
        return code

    def build_builder_image(self, on_line: Callable[[str], None] | None = None) -> int:
        """Build the Docker builder image (see HostInfo.builder_image) from
        Dockerfile.build at the generator repo root — the same command as `make
        docker-image`. Streams output the same way run() does; blocking, so callers run
        it on a worker thread (the GUI uses a QThread)."""
        # A plain `docker build` — no run container to name/kill, so it takes the cancel
        # FALLBACK leg (terminate the docker-build CLI, which aborts the build) rather than
        # the docker-run `docker kill <name>` path.
        return self._stream(self.builder_image_build_command(), on_line, "builder-image")

    def iter_run(self, cfg: ImageConfig, backend: str | None = None) -> Iterator[str]:
        backend = backend or self.host.default_backend
        out = self.workdir or cfg.output_dir or os.path.join(self.generator_dir, "out")
        os.makedirs(out, exist_ok=True)
        pass_file: str | None = None
        cleanup_pass: Callable[[], None] = lambda: None  # noqa: E731
        try:
            if cfg.local_pass:
                pass_file, cleanup_pass = secret_files.stage_local_pass(cfg.local_pass)
            cleanup_extra = self._stage_extra_pass(cfg)
            try:
                proc = self._spawn(self.command(cfg, backend, local_pass_file=pass_file), backend)
                assert proc.stdout is not None
                yield from (line.rstrip("\n") for line in proc.stdout)
                proc.wait()
            finally:
                cleanup_extra()
        finally:
            cleanup_pass()

    def _docker_kill(self) -> None:
        subprocess.run(["docker", "kill", self._container_name],
                       capture_output=True, check=False)

    def _kill_native_group(self, sig: str = "TERM") -> None:
        """Signal the whole native process group. Elevated with the SAME prefix that
        launched the build (non-root host) — the build tree is root-owned, so an
        unprivileged kill EPERMs — so a GUI launch's kill reuses sudo -A / pkexec and its
        askpass/polkit auth. Negative pgid targets every process in the group (sudo →
        bash → emerge → the compiler), not just the leader."""
        if self._pgid is None:
            return
        cmd = self._elevation_prefix() + ["kill", f"-{sig}", f"-{self._pgid}"]
        guard_elevation(cmd)          # the kill elevates through the same prefix
        subprocess.run(cmd, capture_output=True, check=False, env=self._elevation_env())

    # ---- kernel reconfiguration (core/kernel_reconfig.py) -------------------
    @property
    def container_name(self) -> str:
        """The ``--name`` this driver stamps on its docker runs (cancel's handle)."""
        return self._container_name

    def reconfig_context(self, backend: str | None = None, *, live_container: str = ""):
        """How "Kernel config…" reaches root from THIS driver: the same backend, builder
        image and generator mount as the build, the same elevation prefix (``sudo -A`` +
        askpass for a GUI driver), and this driver's container name so :meth:`cancel`
        stops a running rebuild. ``live_container`` is a build container still running
        (menuconfig mid-build goes in with ``docker exec``). No behaviour change for builds."""
        from .kernel_reconfig import RunContext
        b = backend or self.host.default_backend
        return RunContext(backend=b, generator_dir=self.generator_dir,
                          builder_image=self.host.builder_image, container=live_container,
                          run_container_name=self._container_name,
                          elevation=self._elevation_prefix() if b == "native" else [])

    def stream_command(self, cmd: list[str], on_line: Callable[[str], None] | None,
                       backend: str) -> int:
        """Stream an arbitrary command through the build's own spawn: guard_elevation,
        the askpass env, the process group / container name cancel() reaches."""
        return self._stream(cmd, on_line, backend)

    def cancel(self) -> None:
        """Stop the in-flight build honestly, per backend (design 2.5). Idempotent and
        safe to call after the build has already finished (the kill just no-ops)."""
        self._cancel.set()
        proc = self._proc
        if self._backend == "docker":
            self._docker_kill()
        elif self._backend == "native":
            self._kill_native_group("TERM")
            if proc is not None:
                try:
                    proc.wait(timeout=10)   # graceful window before escalation
                except subprocess.TimeoutExpired:
                    self._kill_native_group("KILL")
        elif proc is not None and proc.poll() is None:
            proc.terminate()   # unknown/plain backend (e.g. builder-image build)

    # ---- preflight ---------------------------------------------------------
    def _image_present(self) -> bool:
        """Is self.host.builder_image already built? (`docker image inspect` — same
        daemon-reachability caveats as platform_info._docker_ok.)"""
        try:
            r = subprocess.run(["docker", "image", "inspect", self.host.builder_image],
                               capture_output=True, timeout=8)
            return r.returncode == 0
        except (OSError, subprocess.SubprocessError):
            return False

    def builder_image_build_command(self) -> list[str]:
        """The exact command build_builder_image() runs — also shown in preflight
        messages and by the GUI's "Build builder image now" button."""
        return ["docker", "build", *platform_info.docker_platform_args(self.host),
                "-f", "Dockerfile.build", "-t", self.host.builder_image, "."]

    def builder_image_missing(self, backend: str | None = None) -> bool:
        """True iff backend is docker, the daemon is reachable, but the builder image has
        not been built yet — exactly the condition the GUI should offer to fix. Only when
        the generator dir HAS a Dockerfile.build: from a folder that is not a checkout
        (the Windows install folder, before #827) the offered build could only fail."""
        backend = backend or self.host.default_backend
        return (backend == "docker" and self.host.has_docker
                and os.path.isfile(os.path.join(self.generator_dir, "Dockerfile.build"))
                and not self._image_present())

    def preflight(self, cfg: ImageConfig, backend: str | None = None) -> list[str]:
        """Return a list of human-readable problems that would stop a build (empty = OK)."""
        backend = backend or self.host.default_backend
        problems: list[str] = []
        # Only for a host detected as Windows: a WSL host keeps its own remedy (the
        # per-distro WSL-integration checkbox), and Linux keeps the generic sentence.
        win_docker = windows_docker_remedy(host=self.host) if self.host.os == "windows" and (
            backend == "none" or (backend == "docker" and not self.host.has_docker)) else ""
        if backend == "none":
            problems.append(("No build backend: " + win_docker) if win_docker else
                            "No build backend: install Docker (any OS) or run on a Gentoo host.")
        # The Desktop step's extra accounts need their first-login passwords TYPED for
        # this run (never saved): a reloaded config has none, and the builder would
        # refuse an account without one after the dispatch.
        try:
            from . import desktop_spec as _ds
            if _ds.applies(cfg):
                _typed = _ds.parse_passwords(getattr(cfg, "extra_local_passes", "") or "")
                _missing = [u.name for u in _ds.spec_of(cfg).extra_users if not _typed.get(u.name)]
                if _missing:
                    problems.append("Type the first-login password for the extra local "
                                    "account(s) " + ", ".join(_missing) + " on the Desktop step "
                                    "(passwords are never saved with the config).")
        except Exception:                       # noqa: BLE001 — a malformed spec: to_cli_args says so
            pass
        if not os.path.exists(os.path.join(self.generator_dir, cfg.builder_script)):
            problems.append(f"builder script {cfg.builder_script} not found in {self.generator_dir}"
                            + (" (Jetson support is EXPERIMENTAL — hardware validation pending)"
                               if cfg.platform == "jetson" else ""))
        if backend == "docker" and not self.host.has_docker:
            # The remedy half is the WSL case's whole value: Docker Desktop keeps the
            # daemon on the Windows side and exposes it per distro, so `docker info`
            # fails with a bare connection error that names neither Docker Desktop nor
            # the WSL-integration checkbox that actually caused it.
            # A timed-out probe is "slow", not "unreachable": its remedy states the
            # symptom itself (as HostInfo.docker_blocker does).
            slow = win_docker and self.host.docker_state == platform_info.DOCKER_TIMEOUT
            problems.append(("Docker selected. " if slow else
                             "Docker selected but the Docker daemon is not reachable. ")
                            + (win_docker or self.host.docker_remedy()))
        elif backend == "docker" and not self._image_present():
            problems.append(
                f"Docker builder image '{self.host.builder_image}' not found — build it "
                f"first: {' '.join(self.builder_image_build_command())}")
        # #382's rule, preserved verbatim: elevation is an ADVISORY, so block ONLY when no
        # helper exists at all (a real dead end). The advisory itself lives in
        # preflight_warnings(). Never widen this back into "not root => block": a GUI Studio
        # is never root, and that blocked every native build.
        native_refusal = platform_info.native_build_blocker(
            "A native build", host_os=getattr(self.host, "os", None))
        if backend == "native" and native_refusal:
            # Windows 11 ships sudo.exe, so the elevation check below passed there and
            # the build failed after dispatch; macOS has sudo too, and no chroot/loop
            # devices. The docker backend does work on both.
            problems.append(native_refusal)
        elif backend == "native" and getattr(self.host, "in_flatpak", False):
            from . import flatpak_host
            problems.append(flatpak_host.native_build_blocker())
        elif backend == "native" and not self.host.is_root and not self._can_elevate():
            problems.append(
                "Native build needs root and no elevation helper is available — install "
                "sudo or pkexec (polkit), or run the Studio as root.")
        emitted = _emitted_path_fields(cfg)
        for field in _PATH_MUST_EXIST + DOCKER_EXTRA_ASSET_FIELDS:
            path = getattr(cfg, field, "")
            # Only a path the builder will actually RECEIVE can be a problem. Without this
            # gate a stale x86-only value (secureboot_key, wallpaper, ...) riding an ARM
            # config — or a stale brand profile on an unaffiliated image — would BLOCK a
            # build over a flag that config never emits.
            if not path or not _path_emitted(field, cfg, emitted):
                continue
            # A vault-held selection satisfies the check even when the origin path is
            # GONE (the KEYS USB was unplugged): run() consumes the held in-memory
            # copy via a private 0600 tmp file, never this path — blocking here would
            # defeat the whole "held in memory until the build is completed" ask.
            # Origin-pinned: a held copy for a DIFFERENT path than the config carries
            # is no cover (run() would ignore it too — the consumption rules match).
            if field in secret_files.VAULT_FIELDS:
                held = secret_files.vault().get(field)
                if held is not None and held.origin == path:
                    continue
            if not os.path.exists(self._host_path(path)):
                problems.append(f"{_path_label(field)} path does not exist: {path}")
        # Out-of-scope values the BUILDER ITSELF hard-errors on (today: rpi5 + --standalone
        # + a node role). Catching them here turns a post-dispatch dead-end into a second-0
        # message; the accepted-but-wrong shapes warn instead (see _config_warnings).
        problems += scope_violations(cfg)[0]
        problems += self._macos_docker_problems(cfg, backend)
        # A standalone image whose only login was never given a password: the build
        # would succeed and produce an image nobody can log in to.
        login = standalone_login_problem(cfg)
        if login:
            problems.append(login)
        return problems

    def _macos_docker_problems(self, cfg, backend: str | None) -> list[str]:
        """Every BLOCKING check a docker build on a Mac needs, [] on any other host or
        backend. ONE seam for BuildDriver.preflight and FleetDriver.preflight (which
        overrides preflight wholesale and so reached none of them: a fleet build mounts
        the same ``-v <out>:/out`` and was started into a folder that cannot hold it).
        A new Mac refusal goes here and both lanes get it."""
        if backend != "docker" or getattr(self.host, "os", "") != "darwin":
            return []
        return self._macos_workdir_problems(cfg)

    def _macos_docker_warnings(self, backend: str | None) -> list[str]:
        """The ADVISORY twin of :meth:`_macos_docker_problems`: EXPERIMENTAL, x86_64
        emulation on Apple silicon, a small Docker VM, a CPU cap lowered to the VM's
        CPU count. BuildDriver.preflight_warnings and FleetDriver.advisories share it."""
        if backend != "docker" or getattr(self.host, "os", "") != "darwin":
            return []
        return platform_info.macos_build_warnings(self.host)

    def _macos_workdir_problems(self, cfg: ImageConfig) -> list[str]:
        """A Mac's docker build writes its work dir through ``-v <out>:/out`` from
        macOS into the Docker VM. On APFS's default (case-insensitive) that folder
        cannot hold a Linux kernel tree, which ships headers whose names differ only in
        case (netfilter's xt_*.h), nor a Gentoo root, so the build would fail hours in.
        Measured on the folder itself, not assumed (platform_info.folds_case)."""
        out = self.workdir or cfg.output_dir or os.path.join(self.generator_dir, "out")
        if platform_info.folds_case(out) is not True:
            return []
        return [
            f"The output directory {out} is on a filesystem that ignores case (APFS's "
            f"default). The build writes a Linux kernel tree and a Gentoo root there, "
            f"which need case to matter (the kernel has files whose names differ only in "
            f"case), so it would fail partway. Make a case-sensitive APFS volume and "
            f"choose a folder on it as the output directory:\n"
            f"    diskutil apfs addVolume \"$(diskutil info -plist / | plutil -extract "
            f"APFSContainerReference raw -)\" 'Case-sensitive APFS' HugMeshBuild\n"
            f"then use /Volumes/HugMeshBuild/out (it shares free space with your Mac's "
            f"disk; nothing is repartitioned). Docker Desktop and OrbStack share /Volumes "
            f"already; colima shares only your home folder, so add the volume to the "
            f"mounts in ~/.colima/default/colima.yaml and run `colima restart`."]

    def preflight_warnings(self, cfg: ImageConfig, backend: str | None = None) -> list[str]:
        """ADVISORY warnings (empty = nothing to say) — a PARALLEL channel to
        preflight(), deliberately separate because problems BLOCK (Review's
        isComplete gates on them; ProgressPage refuses dispatch) and a low-memory
        host must WARN, never block and never silently throttle: this computes and
        returns text only, mutating neither cfg.jobs nor the cap.

        ``cfg`` is no longer the unused placeholder it was: _config_warnings() now fills the
        per-config slot this signature always reserved (out-of-scope values the builder
        ACCEPTS but builds wrong, and an unusable --distdir). The BLOCK/WARN split is
        builder truth, not taste — see scope_violations()."""
        backend = backend or self.host.default_backend
        out: list[str] = []
        # FIRST, because it is the one that costs hours and never announces itself: a
        # generator dir on a Windows drive under WSL2 is reached over 9p/virtiofs, and a
        # build there does not fail — it just stops appearing to progress. Backend-
        # independent (both native and docker read the tree file by file), so it sits
        # above the backend-specific notices.
        slow_fs = self.host.slow_filesystem_warning(self.generator_dir)
        if slow_fs:
            out.append(slow_fs)
        # Elevation is an ADVISORY, not a blocker (#382): the driver prepends sudo/pkexec
        # itself (_elevation_prefix), so say an auth prompt is coming rather than
        # refusing the build — preflight() only blocks when NO helper exists at all.
        if backend == "native" and not self.host.is_root and self._can_elevate():
            out.append("Native build runs as root via "
                       f"{self._elevation_prefix()[0]} — expect an authentication prompt.")
        # Native host-tool advisory. The builder scripts now REFUSE (fail fast)
        # rather than silently dropping a requested artifact when a host tool is
        # missing, so surface the most common shortfall here — before the
        # operator commits to a long build. Advisory only: see
        # _host_tool_present() for why this must never block.
        # Kept adjacent to the elevation notice above: both are HOST/native facts,
        # which keeps them separable from the per-config block below.
        if backend == "native" and not _host_tool_present("mksquashfs", "tar2sqfs"):
            out.append("Native build: neither mksquashfs nor tar2sqfs found — the live ISO "
                       "will be refused. Install sys-fs/squashfs-tools.")
        # Per-config advisories (#387): out-of-scope values the builder ACCEPTS and
        # builds wrong, plus an unusable --distdir. Ordered after the host/elevation notice
        # so the two SOURCES stay visually separable, as _config_warnings' docstring says.
        out += self._config_warnings(cfg)
        out += host_resources.low_memory_warnings(backend=backend)
        out += self._macos_docker_warnings(backend)
        return out

    def _config_warnings(self, cfg: ImageConfig) -> list[str]:
        """Per-config ADVISORY text (the `cfg` half preflight_warnings reserved a slot for).

        Kept as its own method so the warning SOURCES stay separable: host-resource warnings
        depend on the machine, these depend only on the config."""
        # Out-of-scope values the builder ACCEPTS and builds silently wrong (finding 1's
        # --config half: x86 + --standalone + a node role). Never blocked — the builder has
        # no such constraint and inventing one would be its own lie.
        out: list[str] = list(scope_violations(cfg)[1])
        emitted = _emitted_path_fields(cfg)
        for field in _PATH_ADVISORY:
            path = getattr(cfg, field, "")
            if (path and _path_emitted(field, cfg, emitted)
                    and not os.path.exists(self._host_path(path))):
                # Mirrors build-x86-host-stage4.sh's own --distdir warning: an unusable cache
                # is silently dropped for the /media/* auto-detect scan. Correct artifact,
                # just a full re-download — so it warns here rather than blocking.
                out.append(f"{_path_label(field)} path does not exist: {path} — it will be "
                           f"IGNORED and sources re-downloaded (the build still succeeds).")
        return out

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

import os
import shlex
import shutil
import subprocess
import sys
import threading
import uuid
from collections.abc import Callable, Iterator

from . import askpass, host_resources, platform_info, proc_text, resource_limits
from . import secret_files, state_paths
from .config import PLATFORM_FIELD_SUPPORT, ImageConfig, scope_violations
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


def docker_limit_args() -> list[str]:
    """The full ``docker run`` resource-limit wrapper for a builder run: CPU, memory
    and GPU, resolved by :mod:`hugmesh_studio.core.resource_limits`.

    Supersedes :func:`docker_memory_args`, which capped memory and left CPU
    unbounded — half of the 2026-07-15 host-freeze defence. With every limit off this
    returns ``[]`` and the surrounding argv is byte-identical to the pre-guard
    command, which is what keeps the committed command-string tests valid.

    Evaluated at command()-assembly time, so the PREVIEW the operator is shown and
    the argv that is DISPATCHED are the same by construction."""
    return resource_limits.docker_run_args(resource_limits.effective())


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
    studio_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    body = (
        "#!/bin/sh\n"
        "# Auto-generated by HugMesh Image Studio: a GUI askpass helper so a native\n"
        "# (sudo) build launched from the GUI prompts for the admin password in a dialog\n"
        "# rather than an invisible terminal. Safe to delete; it is recreated on demand.\n"
        "# --askpass-gui is the explicit dialog opt-in (a GUI-launched build is the one\n"
        "# caller entitled to it); the bare --askpass never pops a dialog.\n"
        f'export PYTHONPATH="{studio_root}${{PYTHONPATH:+:$PYTHONPATH}}"\n'
        f"exec {shlex.quote(sys.executable)} -m hugmesh_studio --askpass-gui\n"
    )
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

    def command(self, cfg: ImageConfig, backend: str | None = None) -> list[str]:
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
            env_args: list[str] = []
            for k, v in penv.items():
                env_args += ["-e", f"{k}={v}"]
            return [
                "docker", "run", "--rm", "--privileged",
                # --init: a real PID1 that reaps and forwards signals so `docker kill`
                # (cancel) actually stops the build instead of orphaning it. --name:
                # the stable handle cancel() targets.
                "--init", "--name", self._container_name,
                # Container CPU/memory/GPU caps (docker-run wrapper only — the inner
                # builder argv below is byte-untouched): see docker_limit_args.
                *docker_limit_args(),
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

    def _remap_assets_for_docker(self, cfg: ImageConfig) -> tuple[list[str], ImageConfig]:
        """Mount external asset paths into the container and return (mount-args, a config
        whose asset flags point at the in-container paths)."""
        import copy
        dcfg = copy.deepcopy(cfg)
        mounts: list[str] = []
        gen = self.generator_dir + os.sep
        for i, field in enumerate(DOCKER_ASSET_FIELDS):
            p = getattr(dcfg, field, "")
            if not p:
                continue
            ap = os.path.abspath(p)
            if ap.startswith(gen):
                continue  # already under /src, reachable in-container
            cpath = f"/assets/{i}/{os.path.basename(ap.rstrip(os.sep))}"
            mounts += ["-v", f"{ap}:{cpath}:ro"]
            setattr(dcfg, field, cpath)
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
        try:
            code = self._stream(self.command(run_cfg, backend), watched_on_line, backend)
        finally:
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
        proc = self._spawn(self.command(cfg, backend), backend)
        assert proc.stdout is not None
        yield from (line.rstrip("\n") for line in proc.stdout)
        proc.wait()

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
        return ["docker", "build", "-f", "Dockerfile.build", "-t", self.host.builder_image, "."]

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
        if backend == "none":
            problems.append("No build backend: install Docker (any OS) or run on a Gentoo host.")
        if not os.path.exists(os.path.join(self.generator_dir, cfg.builder_script)):
            problems.append(f"builder script {cfg.builder_script} not found in {self.generator_dir}"
                            + (" (Jetson support is EXPERIMENTAL — hardware validation pending)"
                               if cfg.platform == "jetson" else ""))
        if backend == "docker" and not self.host.has_docker:
            # The remedy half is the WSL case's whole value: Docker Desktop keeps the
            # daemon on the Windows side and exposes it per distro, so `docker info`
            # fails with a bare connection error that names neither Docker Desktop nor
            # the WSL-integration checkbox that actually caused it.
            problems.append("Docker selected but the Docker daemon is not reachable. "
                            + self.host.docker_remedy())
        elif backend == "docker" and not self._image_present():
            problems.append(
                f"Docker builder image '{self.host.builder_image}' not found — build it "
                f"first: {' '.join(self.builder_image_build_command())}")
        # #382's rule, preserved verbatim: elevation is an ADVISORY, so block ONLY when no
        # helper exists at all (a real dead end). The advisory itself lives in
        # preflight_warnings(). Never widen this back into "not root => block": a GUI Studio
        # is never root, and that blocked every native build.
        if backend == "native" and platform_info.native_windows_blocker("A native build"):
            # Windows 11 ships sudo.exe, so the elevation check below passed there and
            # the build failed after dispatch. The docker backend does work natively.
            problems.append(
                "A native build runs sudo and bash on a Gentoo host, which the Windows "
                "build of the Studio cannot do. Choose the docker backend (Docker "
                "Desktop), or run the Studio inside WSL2.")
        elif backend == "native" and not self.host.is_root and not self._can_elevate():
            problems.append(
                "Native build needs root and no elevation helper is available — install "
                "sudo or pkexec (polkit), or run the Studio as root.")
        for field in _PATH_MUST_EXIST:
            path = getattr(cfg, field, "")
            # Only a path the builder will actually RECEIVE can be a problem. Without this
            # gate a stale x86-only value (secureboot_key, wallpaper, ...) riding an ARM
            # config would BLOCK a build over a flag that platform never emits.
            if not path or not _path_field_emitted(field, cfg):
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
            if not os.path.exists(path):
                problems.append(f"{_path_label(field)} path does not exist: {path}")
        # Out-of-scope values the BUILDER ITSELF hard-errors on (today: rpi5 + --standalone
        # + a node role). Catching them here turns a post-dispatch dead-end into a second-0
        # message; the accepted-but-wrong shapes warn instead (see _config_warnings).
        problems += scope_violations(cfg)[0]
        return problems

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
        return out

    def _config_warnings(self, cfg: ImageConfig) -> list[str]:
        """Per-config ADVISORY text (the `cfg` half preflight_warnings reserved a slot for).

        Kept as its own method so the warning SOURCES stay separable: host-resource warnings
        depend on the machine, these depend only on the config."""
        # Out-of-scope values the builder ACCEPTS and builds silently wrong (finding 1's
        # --config half: x86 + --standalone + a node role). Never blocked — the builder has
        # no such constraint and inventing one would be its own lie.
        out: list[str] = list(scope_violations(cfg)[1])
        for field in _PATH_ADVISORY:
            path = getattr(cfg, field, "")
            if path and _path_field_emitted(field, cfg) and not os.path.exists(path):
                # Mirrors build-x86-host-stage4.sh's own --distdir warning: an unusable cache
                # is silently dropped for the /media/* auto-detect scan. Correct artifact,
                # just a full re-download — so it warns here rather than blocking.
                out.append(f"{_path_label(field)} path does not exist: {path} — it will be "
                           f"IGNORED and sources re-downloaded (the build still succeeds).")
        return out

"""One Qt-free emulation facade — plan, boot, watch, stop and save emulated devices.

Four cores grew around the QEMU harness, each owning one honest slice:

  * core/qemu_tests.py      — sessions/rows, the runner argv, result JSON;
  * core/qemu_devices.py    — the live keep-alive registry, ssh/QMP/save argv;
  * core/mesh_emulation.py  — the whole-mesh planner (ports, identities, gateway);
  * core/emulation_save.py  — the whole-mesh save orchestrator.

Both GUI pages, the TUI and the Makefile each stitched those four together BY HAND,
and every seam between them was a place for the stitchings to disagree: the mesh
page pinned ``--work`` on start but not on stop, the device page's per-row Start
let the runner guess its newest session, verdicts from last week's run were shown
as this run's outcome. This module is the one stitching, COMPOSING the four cores
— every argv is still authored by (or through) the module that owns its slice, and
nothing here boots, copies or probes anything the cores do not already boot, copy
or probe.

WHAT THE FACADE ADDS (and the cores deliberately do not)
--------------------------------------------------------
* :func:`plan` — one plan object for both lanes: a TEST run (boot, assert, power
  off) and a DEPLOY (standing ``--keep-alive`` mesh). DEPLOY wraps
  ``mesh_emulation.plan_mesh``, so ports/identities/gateway are that planner's.
* :func:`status` — THE reconciled truth about a plan's devices: the runner's own
  ``--devices`` view (already reconciled against docker ps) when it answers, the
  raw registry with the same downgrade replicated when it does not; planned rows
  merged in; verdicts scoped, epoch-gated (STALE), suspicion-graded (SUSPECT) and
  synthesized (NO-RESULT) — see :func:`_verdict_for` for each rule's reason.
* :func:`start_device_argv` — the per-device Start contract T1 built: ALWAYS pins
  ``--artifacts`` + ``--work`` and addresses the row with ``--only-exact``, never
  the runner's newest-session guess and never a substring match.
* :func:`spawn` — THE single process boundary, promoted from mesh_emulation (which
  keeps an alias until T4). Tests and GUIs replace this one function.

CLI
---
``python -m hugmesh_studio.core.emulation plan|test|up|status|down|save-mesh`` —
the same stdlib subcommand shape as core/emulation_save.py. ``plan`` and ``status``
take ``--json`` for machine-readable output. The Makefile faces are
``mesh-emu-up`` / ``mesh-emu-status`` / ``mesh-emu-down``.
"""
from __future__ import annotations

import argparse
import datetime
import enum
import json
import os
import shlex
import signal
import subprocess
import sys
import threading
from collections.abc import Callable
from dataclasses import dataclass, field, replace

from . import emulation_save, mesh_emulation, qemu_devices, qemu_tests
# Re-exports: the single argv authors for the verbs the cores already own. The
# facade adds NO second spelling of any of these — a GUI that imports only this
# module still runs the exact argv the owning core's tests pin.
from .mesh_emulation import web_tunnel_argv                       # noqa: F401
from .qemu_devices import Device, qmp_argv, ssh_argv              # noqa: F401
from .qemu_devices import device_save_argv as save_device_argv    # noqa: F401
from .qemu_tests import (BuildSession, DeviceRow, QemuRunOptions,
                         runner_command)
from . import proc_group

#: The SELinux AVC workout (issue #45): boots ONE row through the launchers,
#: drives the confined workloads and harvests every AVC into a narrowing report.
AVC_SCRIPT = os.path.join("tests", "qemu", "avc-workout.sh")

#: THE PLAYWRIGHT LANE — a DIFFERENT harness from ``qemu_tests.RUNNER_SCRIPT``, and
#: the distinction is the whole reason this constant exists rather than a string at a
#: call site. Three things in this tree are called "e2e":
#:
#:   * ``tests/qemu/run-qemu-docker.sh``  (``qemu_tests.RUNNER_SCRIPT``) — boots a
#:     MATRIX of images in a privileged container and runs IN-GUEST assertions. This
#:     is what ``run_argv``/``start_device_argv`` drive and what the post-build
#:     opt-in (``cfg.qemu_device_tests``) runs.
#:   * ``tests/qemu/run-qemu-e2e.sh``     (BELOW) — boots ONE role VM through
#:     launch-x86.sh/launch-pi.sh, seeds the e2e identities over SSH and runs the
#:     UNCHANGED Playwright specs from ``tests/e2e`` against the guest's forwarded
#:     UI. Browsers, not ssh assertions.
#:   * ``tests/qemu/run-matrix-e2e.sh``   — the size/load matrix gated on
#:     ``HUGMESH_QEMU_E2E=1``. Nothing here drives it.
#:
#: Pointing an envelope at the wrong one of these is exactly the confusion the
#: rename of ``cfg.qemu_e2e`` -> ``cfg.qemu_device_tests`` was about, so
#: test_emulation.py pins WHICH script each author emits.
PLAYWRIGHT_SCRIPT = os.path.join("tests", "qemu", "run-qemu-e2e.sh")

#: ``run-qemu-e2e.sh --target``: which launcher boots the guest. It wires exactly two
#: (launch-x86.sh and launch-pi.sh), so these three are the whole vocabulary.
PLAYWRIGHT_TARGET_X86 = "x86"
PLAYWRIGHT_TARGET_PI = "pi"
PLAYWRIGHT_TARGET_BOTH = "both"
PLAYWRIGHT_TARGETS = (PLAYWRIGHT_TARGET_X86, PLAYWRIGHT_TARGET_PI,
                      PLAYWRIGHT_TARGET_BOTH)

#: Platforms that map onto a launcher run-qemu-e2e.sh actually wires. Everything
#: else (jetson, the OrangePi boards, frite) has no launcher in that script — its
#: arg parser would take ``--target jetson`` and ``die`` — so the author REFUSES
#: rather than silently boot some other board's image.
_PLAYWRIGHT_PLATFORM_TARGETS = {
    "x86": PLAYWRIGHT_TARGET_X86,
    "rpi5": PLAYWRIGHT_TARGET_PI,
    "rpi4": PLAYWRIGHT_TARGET_PI,
    "rpi3": PLAYWRIGHT_TARGET_PI,
}

#: Wall clock for the ``--devices`` shell-out in :func:`status`. The subcommand
#: boots nothing (a file read plus one ``docker ps``), so anything slower than
#: this is a hung daemon — and the registry fallback answers instead.
DEVICES_PROBE_TIMEOUT_S = 10.0
#: Wall clock for the fallback lane's own ``docker ps``.
DOCKER_PS_TIMEOUT_S = 5.0

# ── status vocabulary ──────────────────────────────────────────────────────────────
#: Row states. The first two are the merge's additions: a planned row with no
#: registry record is PLANNED (the run never reached it), and BOOTING is T1's
#: moment-of-qemu-launch record — a row killed mid-boot is findable, not absent.
STATE_PLANNED = "PLANNED"
STATE_BOOTING = "BOOTING"
STATE_RUNNING = "RUNNING"
STATE_ASSERTIONS = "ASSERTIONS"
STATE_STOPPED = "STOPPED"

#: Verdicts beyond the runner's own PASS/FAIL/ERROR. Each is synthesized here and
#: only here, so the GUI, the TUI and the CLI cannot grade the same row differently.
VERDICT_SUSPECT = "SUSPECT"      # a PASS that asserted nothing — never green
VERDICT_STALE = "STALE"          # a verdict from an earlier boot/run
VERDICT_NO_RESULT = "NO-RESULT"  # planned, run completed, no verdict emitted
VERDICT_PENDING = ""             # no verdict yet, and none is owed yet

_STATE_WORDS = {"booting": STATE_BOOTING, "running": STATE_RUNNING,
                "assertions": STATE_ASSERTIONS, "stopped": STATE_STOPPED,
                "": STATE_STOPPED}


class EmulationMode(enum.Enum):
    """The two lanes one plan can drive.

    TEST is the matrix run to completion: every row boots, asserts and powers off,
    leaving verdicts. DEPLOY is the standing mesh: ``--keep-alive`` guests, the
    device registry, ssh/tunnel actions — what the mesh-emulation screen shows.
    Same rows, same artifacts, same runner; only the run shape differs.
    """
    TEST = "test"
    DEPLOY = "deploy"


@dataclass(frozen=True)
class RunEnvelope:
    """Every runner knob a caller may set, in one bag with the runner's defaults.

    Frozen because a plan embeds it: two surfaces sharing a plan must be sharing
    the same knobs, not a mutable bag one of them quietly adjusted. Only
    non-default values reach the argv (``qemu_tests.runner_command``'s rule), so
    the default envelope adds nothing to the printed command.
    """
    jobs: int = 2                        # concurrency; keep-alive admission gate
    mem_mb: int = 2048
    smp: int = 2
    timeout_s: int = 2400                # guest ssh wait
    assert_timeout_s: int = 0            # in-guest assertion wall clock; 0 = default
    extra_users: tuple[str, ...] = ()    # additional wheel logins on every guest
    keep: bool = False                   # keep per-run scratch dirs
    cache_max_gb: int = 0                # decompressed-image cache cap; 0 = unbounded
    #: THE SPEC/TAG FILTER, and the ONE field here that is not a
    #: ``qemu_tests.QemuRunOptions`` knob. It is the ``-- <extra playwright args>``
    #: passthrough of ``run-qemu-e2e.sh`` (``specs/01-frontpage.spec.ts``,
    #: ``--grep @smoke``, ``--repeat-each 3``), carried in the envelope rather than
    #: read off a widget at spawn time for the reason gui/pages/qemu.py states about
    #: every other knob: the preview and the spawn build their argv from the SAME
    #: envelope, so a knob the envelope does not carry is a knob that previews and
    #: then does not happen.
    #:
    #: It reaches ONLY the Playwright lane. ``_envelope_options`` deliberately does
    #: NOT forward it to ``QemuRunOptions`` — run-qemu-docker.sh has no such flag and
    #: would ``die`` on it — and ``test_emulation.py`` pins that split so a future
    #: field cannot be added to this class and then silently reach neither lane.
    playwright_args: tuple[str, ...] = ()


@dataclass(frozen=True)
class PlaywrightOptions:
    """Every knob of ``tests/qemu/run-qemu-e2e.sh``, with THAT script's defaults.

    Deliberately a SECOND options object rather than more fields on
    :class:`RunEnvelope`: the two lanes share not one flag spelling. The docker
    runner takes ``--artifacts/--work/--only-exact/--jobs``; this one takes
    ``--target/--role/--img/--kernel/--ssh-port/--ui-port/--accel`` and a trailing
    ``-- <playwright args>``. Collapsing them into one bag is how an envelope ends
    up aimed at the wrong runner.

    THE DEFAULTS ARE THE SCRIPT'S, COPIED — but see :func:`playwright_argv` for why
    most flags are emitted ANYWAY. run-qemu-e2e.sh spells every default as
    ``"${MEM:-4096}"``, i.e. an ENVIRONMENT variable with a fallback, so "the
    default" is whatever the spawning shell happens to export. Omitting a flag
    because it matches the literal default would hand the guest a different value on
    a workstation that has ``MEM``/``SSH_PORT``/``TIMEOUT`` in its environment — and
    the Studio spawns with the environment it inherited.
    """
    #: Which VM(s) to boot: ``x86`` | ``pi`` | ``both`` (``-t/--target``).
    target: str = PLAYWRIGHT_TARGET_X86
    role: str = "frontend"           # -r/--role: whose UI the specs drive
    img: str = ""                    # --img      x86 .img (else autodetect in -w)
    kernel: str = ""                 # --kernel   Pi kernel Image (else autodetect)
    stage4: str = ""                 # --stage4   Pi stage4 (else autodetect)
    #: ``-w/--work-dir`` — the ARTIFACT dir the script autodetects images in, NOT a
    #: scratch dir. Left empty here; :func:`playwright_argv` pins it to the plan's
    #: session path, for the same reason every other author here pins ``--artifacts``.
    work_dir: str = ""
    test_dir: str = ""               # --test-dir scratch (default <work>/qemu-e2e)
    ssh_port: int = 2222             # --ssh-port host port forwarded to guest :22
    ui_port: int = 8443              # --ui-port  host port forwarded to the guest UI
    ssh_user: str = "tester"         # --ssh-user login seeded onto the image
    mem_mb: int = 4096               # -m/--mem
    smp: int = 4                     # --smp
    accel: str = "auto"              # --accel    auto | kvm | tcg
    timeout_s: int = 1800            # --timeout     max wait for SSH
    ui_timeout_s: int = 300          # --ui-timeout  max wait for the forwarded UI
    keep: bool = False               # --keep     don't tear the VM/scratch down
    dry_run: bool = False            # --dry-run  resolve + print the plan; no boot
    #: ``--list`` — enumerate the boot plan AND the Playwright specs that run,
    #: without booting anything. Needs no root, which is what makes it the only verb
    #: on this lane a GUI can offer unconditionally (see :func:`playwright_root_blocker`).
    list_only: bool = False
    #: Everything after ``--``: handed verbatim to ``playwright test``.
    playwright_args: tuple[str, ...] = ()


@dataclass
class EmulationPlan:
    """One session's emulation plan, for either lane.

    ``rows`` is what would boot (newest artifact per platform/role, boot order).
    ``mesh`` is the DEPLOY extras — ports, identities, gateway — and None for a
    TEST plan, which needs none of them. ``epoch`` is the UTC stamp the plan was
    minted at; :func:`status` grades any verdict older than it STALE (pass
    ``epoch=""`` to :func:`plan` to disable that gate — the status CLI does, since
    it inspects a mesh some earlier process started).
    """
    mode: EmulationMode
    generator_dir: str
    session_path: str
    session_name: str
    work_dir: str
    envelope: RunEnvelope = field(default_factory=RunEnvelope)
    rows: list[DeviceRow] = field(default_factory=list)
    mesh: mesh_emulation.MeshPlan | None = None
    epoch: str = ""

    @property
    def labels(self) -> list[str]:
        return [r.label for r in self.rows]

    def row(self, label: str) -> DeviceRow | None:
        for r in self.rows:
            if r.label == label:
                return r
        return None

    @property
    def gateway_label(self) -> str:
        return self.mesh.gateway_label if self.mesh else ""

    @property
    def front_door(self) -> str:
        """The mesh's web front-door URL — DEPLOY only, "" otherwise."""
        return mesh_emulation.front_door_url(self.mesh) if self.mesh else ""


def _utc_now() -> str:
    # timezone.utc, not datetime.UTC — the Studio supports 3.10 (same note as
    # qemu_devices._utc_stamp).
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _as_session(generator_dir: str, session) -> BuildSession:
    """Coerce a BuildSession, a session path, or a session NAME into a BuildSession.

    A name is resolved under ``out/sessions/`` — and only there. There is
    deliberately no "else take the newest" here: the caller-facing defaulting
    lives in ``qemu_tests.default_session`` (newest COMPLETE), and a typo'd name
    must be an error, not a silent run of some other session's images.
    """
    if isinstance(session, BuildSession):
        return session
    path = str(session or "")
    if not os.path.isdir(path):
        candidate = os.path.join(generator_dir, qemu_tests.SESSIONS_SUBDIR, path)
        if path and os.path.isdir(candidate):
            path = candidate
        else:
            raise ValueError(
                f"no such build session: {session!r} is neither a directory nor a "
                f"name under {os.path.join(generator_dir, qemu_tests.SESSIONS_SUBDIR)}")
    return BuildSession(path=path,
                        name=os.path.basename(os.path.normpath(path)),
                        rows=qemu_tests.discover_rows(path),
                        expected_images=qemu_tests.expected_image_count(path))


def plan(generator_dir: str, session, mode, envelope: RunEnvelope | None = None, *,
         work_dir: str = "", epoch: str | None = None) -> EmulationPlan:
    """The plan for one session in one lane — pure arithmetic, boots nothing.

    ``session`` may be a ``qemu_tests.BuildSession``, a session directory, or a
    session name under ``out/sessions/``. ``mode`` may be an :class:`EmulationMode`
    or its string value. DEPLOY plans additionally run ``mesh_emulation.plan_mesh``
    (which validates port/identity ranges and may raise ValueError for an
    oversized session, exactly as before — this facade adds no second limit).

    ``epoch=None`` (default) stamps "now"; ``epoch=""`` disables the STALE gate in
    :func:`status` for callers inspecting a run they did not start.
    """
    env = envelope or RunEnvelope()
    mode = mode if isinstance(mode, EmulationMode) else EmulationMode(str(mode))
    sess = _as_session(generator_dir, session)
    work = work_dir or qemu_devices.default_work_dir(generator_dir)
    rows = sorted(sess.rows, key=lambda r: (qemu_tests.platform_rank(r.platform),
                                            r.platform, r.role))
    mesh = None
    if mode is EmulationMode.DEPLOY:
        # plan_mesh sorts identically, so plan.rows[i] and mesh.devices[i] are the
        # same device; the mesh carries the ports/identities, the row the artifact.
        mesh = mesh_emulation.plan_mesh(sess, generator_dir, work_dir=work)
    return EmulationPlan(mode=mode, generator_dir=generator_dir,
                         session_path=sess.path, session_name=sess.name,
                         work_dir=work, envelope=env, rows=rows, mesh=mesh,
                         epoch=_utc_now() if epoch is None else epoch)


# ── argv authors ────────────────────────────────────────────────────────────────────

#: RunEnvelope fields that are deliberately NOT forwarded into QemuRunOptions,
#: with the reason. ``_envelope_options`` maps every OTHER field one-for-one, and
#: test_emulation.py asserts this set plus that mapping covers the dataclass exactly
#: — so a field added to RunEnvelope must be routed somewhere on purpose, instead of
#: joining the argv of neither lane and looking wired because the widget exists.
ENVELOPE_FIELDS_NOT_FOR_THE_DOCKER_RUNNER = {
    "playwright_args": ("the `-- <extra playwright args>` passthrough of "
                        "run-qemu-e2e.sh; run-qemu-docker.sh has no such flag and "
                        "treats an unknown arg as a hard error"),
}


def _envelope_options(env: RunEnvelope, **overrides) -> QemuRunOptions:
    return QemuRunOptions(jobs=env.jobs, mem_mb=env.mem_mb, smp=env.smp,
                          timeout_s=env.timeout_s,
                          assert_timeout_s=env.assert_timeout_s,
                          extra_users=tuple(env.extra_users), keep=env.keep,
                          cache_max_gb=env.cache_max_gb, **overrides)


def run_argv(plan: EmulationPlan) -> list[str]:
    """argv for the plan's whole run, through the ONE argv author.

    TEST is the matrix run; DEPLOY is the same fan-out with ``--keep-alive``.
    ``--artifacts`` is pinned to the plan's session path in BOTH lanes — the runner
    can guess its newest session, and a plan that previewed one session while the
    run booted another is precisely the bug class this facade exists to close.
    """
    opts = _envelope_options(plan.envelope,
                             artifacts_dir=plan.session_path,
                             work_dir=plan.work_dir,
                             keep_alive=(plan.mode is EmulationMode.DEPLOY))
    return runner_command(plan.generator_dir, opts)


def start_device_argv(plan_or_record, label: str = "", *, generator_dir: str = "",
                      session_path: str = "", work_dir: str = "",
                      envelope: RunEnvelope | None = None) -> list[str]:
    """argv that boots ONE device — ALWAYS pinned, NEVER the runner's guess.

    Two caller shapes, one contract:

    * ``(plan, label)`` — artifacts/work/generator all come from the plan;
    * ``(device_record)`` (a ``qemu_devices.Device``, ``label`` optional) — the
      restart path for a row someone else booted: artifacts come from the record's
      ``artifacts`` field (the T1 start contract), and for an older record that
      predates the field, from an EXPLICIT ``session_path``. When neither exists
      this raises rather than let the runner default to its newest session: a
      restart that silently boots a different build than the device came from is
      how a green run tests bits that were never deployed. ``generator_dir`` is
      required in this shape (a record does not know the checkout).

    The row is addressed with T1's ``--only-exact``: ``--only`` is a substring
    filter, and restarting ``x86/be`` must not drag be+gpu/be-ha along.
    ``--work`` is always emitted too, so the new device registers in the registry
    the caller is actually watching.
    """
    if isinstance(plan_or_record, EmulationPlan):
        p = plan_or_record
        if not label:
            raise ValueError("start_device_argv needs the label of the planned row")
        if p.row(label) is None:
            raise ValueError(f"{label!r} is not a row of this plan "
                             f"(session {p.session_name}: {', '.join(p.labels)})")
        gen, artifacts, work = p.generator_dir, p.session_path, p.work_dir
        env = envelope or replace(p.envelope, jobs=1)
    else:
        rec = plan_or_record
        lbl = label or str(getattr(rec, "label", "") or "")
        if not lbl:
            raise ValueError("start_device_argv got a record with no label")
        label = lbl
        gen = generator_dir
        if not gen:
            raise ValueError("generator_dir is required when starting from a "
                             "device record (the record does not know the checkout)")
        artifacts = str(getattr(rec, "artifacts", "") or "") or session_path
        if not artifacts:
            raise ValueError(
                f"{label}: no artifacts dir to start from — the record predates the "
                "'artifacts' field and no session_path was given. Pass the session "
                "explicitly; falling back to the runner's newest-session guess could "
                "boot a different build than this device came from.")
        work = work_dir or qemu_devices.default_work_dir(gen)
        env = envelope or RunEnvelope(jobs=1)
    opts = _envelope_options(env, artifacts_dir=artifacts, work_dir=work,
                             only_exact=label, keep_alive=True)
    return runner_command(gen, opts)


def stop_device_argv(plan: EmulationPlan, label: str) -> list[str]:
    """argv that stops ONE device — mesh_emulation's author, with ``--work`` ALWAYS
    carried: the start argv pins the work dir, so a stop that lets the runner
    default would aim at a registry the device never registered in (the start/stop
    asymmetry mesh_emulation shipped with)."""
    return mesh_emulation.stop_device_argv(plan.generator_dir, label,
                                           work_dir=plan.work_dir)


def stop_all_argv(plan: EmulationPlan) -> list[str]:
    """argv for the fleet-wide stop, ``--work`` carried for the same reason."""
    return mesh_emulation.stop_mesh_argv(plan.generator_dir,
                                         work_dir=plan.work_dir)


def avc_argv(plan: EmulationPlan, row_or_label) -> list[str]:
    """argv for the SELinux AVC workout over ONE planned row (issue #45).

    tests/qemu/avc-workout.sh boots the row through its own launcher, drives the
    confined workloads and emits the narrowing report; its ``-w`` is the artifacts
    dir it autodetects the image in, pinned to the plan's session for the same
    reason every other argv here pins ``--artifacts``. Accepts a row object or its
    label; a label not in the plan raises, matching :func:`start_device_argv`.
    """
    label = getattr(row_or_label, "label", row_or_label)
    row = plan.row(str(label))
    if row is None:
        raise ValueError(f"{label!r} is not a row of this plan "
                         f"(session {plan.session_name}: {', '.join(plan.labels)})")
    return [os.path.join(plan.generator_dir, AVC_SCRIPT),
            "--platform", row.platform, "--role", row.role,
            "-w", plan.session_path]


# ── the Playwright lane: run-qemu-e2e.sh over a REAL booted image ───────────────────
# tests/qemu/run-qemu-e2e.sh has existed and worked for months and was reachable from
# NOWHERE in the Studio (zero references under studio/ before 2026-08-26). These three
# functions are the door: one argv author, one row->target rule, one honest refusal.


def playwright_target_for(platform: str) -> str:
    """``x86`` -> ``x86``, a Pi board -> ``pi``; "" when no launcher exists.

    run-qemu-e2e.sh wires exactly two launchers (launch-x86.sh, launch-pi.sh) and its
    own parser rejects any other ``--target``, so a jetson/OrangePi/frite row has no
    honest answer here. "" is that answer, and the callers turn it into a refusal
    naming the platform rather than booting some other board's image.
    """
    return _PLAYWRIGHT_PLATFORM_TARGETS.get(str(platform or ""), "")


def playwright_options_for_row(plan: EmulationPlan, row_or_label,
                               **overrides) -> PlaywrightOptions:
    """The options that drive the Playwright suite against ONE planned row.

    ``--target`` and ``--role`` are DERIVED from the row (never typed twice), the
    Playwright passthrough comes from the plan's envelope, and everything else is
    the script's own default unless a caller overrides it. A label not in the plan
    raises, matching :func:`avc_argv` and :func:`start_device_argv`.
    """
    label = str(getattr(row_or_label, "label", row_or_label))
    row = plan.row(label)
    if row is None:
        raise ValueError(f"{label!r} is not a row of this plan "
                         f"(session {plan.session_name}: {', '.join(plan.labels)})")
    target = playwright_target_for(row.platform)
    if not target:
        raise ValueError(
            f"{label}: platform {row.platform!r} has no launcher in "
            f"{PLAYWRIGHT_SCRIPT} — it wires launch-x86.sh (x86) and launch-pi.sh "
            f"(rpi3/rpi4/rpi5) only, and rejects any other --target. Run this row's "
            "in-guest assertions through the device-test lane instead.")
    opts = PlaywrightOptions(target=target, role=row.role,
                             playwright_args=tuple(plan.envelope.playwright_args))
    return replace(opts, **overrides) if overrides else opts


def playwright_argv(plan: EmulationPlan,
                    options: PlaywrightOptions | None = None) -> list[str]:
    """argv for ``tests/qemu/run-qemu-e2e.sh`` — boot ONE role VM, seed the e2e
    identities over SSH, run the UNCHANGED Playwright specs against its forwarded UI.

    ``-w`` is pinned to the plan's session path unless the caller names one, exactly
    as :func:`avc_argv` pins its own ``-w`` and :func:`run_argv` pins ``--artifacts``:
    a preview that showed one session while the boot resolved its image out of another
    is the bug class this facade exists to close.

    EVERY PORT/SIZE/TIMEOUT FLAG IS EMITTED, including ones equal to the script's
    default — unlike ``qemu_tests.runner_command``, which suppresses defaults to keep
    the preview short. The reason is in :class:`PlaywrightOptions`: run-qemu-e2e.sh
    reads each of those defaults from the ENVIRONMENT (``"${MEM:-4096}"``), and the
    Studio spawns with the environment it inherited, so "omitted" does not mean
    "default" on this lane. It also makes the printed command reproducible in a
    terminal that has none of those variables set.

    The passthrough is LAST and behind a bare ``--``, because that is the script's
    own contract ("Everything after -- is passed through to Playwright"); it is
    omitted entirely when there is nothing to pass, so the default command carries no
    dangling separator.
    """
    opts = options or PlaywrightOptions()
    if opts.target not in PLAYWRIGHT_TARGETS:
        raise ValueError(f"invalid Playwright target {opts.target!r} "
                         f"({'|'.join(PLAYWRIGHT_TARGETS)})")
    if not opts.role:
        raise ValueError("the Playwright lane needs a --role: it boots ONE role's "
                         "image and drives that node's UI")
    argv = [os.path.join(plan.generator_dir, PLAYWRIGHT_SCRIPT),
            "--target", opts.target,
            "--role", opts.role,
            "-w", opts.work_dir or plan.session_path]
    if opts.img:
        argv += ["--img", opts.img]
    if opts.kernel:
        argv += ["--kernel", opts.kernel]
    if opts.stage4:
        argv += ["--stage4", opts.stage4]
    if opts.test_dir:
        argv += ["--test-dir", opts.test_dir]
    argv += ["--ssh-port", str(opts.ssh_port),
             "--ui-port", str(opts.ui_port),
             "--ssh-user", opts.ssh_user,
             "--mem", str(opts.mem_mb),
             "--smp", str(opts.smp),
             "--accel", opts.accel,
             "--timeout", str(opts.timeout_s),
             "--ui-timeout", str(opts.ui_timeout_s)]
    if opts.keep:
        argv.append("--keep")
    if opts.dry_run:
        argv.append("--dry-run")
    if opts.list_only:
        argv.append("--list")
    if opts.playwright_args:
        argv.append("--")
        argv += [str(a) for a in opts.playwright_args]
    return argv


def playwright_root_blocker() -> str:
    """Why the Playwright lane cannot BOOT from here, or "" when it can.

    run-qemu-e2e.sh refuses unless ``id -u`` is 0, because launch-x86.sh/launch-pi.sh
    loop-mount the golden image and prep KVM disks. The Studio has no way to answer an
    interactive sudo prompt and MUST NOT try — so this states the fact, names the
    containerized route the device-test lane already uses for exactly this constraint,
    and leaves ``--list``/``--dry-run`` (which need no root) enabled.
    """
    if hasattr(os, "geteuid") and os.geteuid() == 0:
        return ""
    return (
        "Booting a guest on this lane needs root: tests/qemu/run-qemu-e2e.sh drives "
        "launch-x86.sh / launch-pi.sh, which loop-mount the golden image to lift its "
        "kernel out of the boot partition. The Studio cannot answer a sudo prompt and "
        "does not try. Run it from a root shell, or from the privileged container the "
        "device-test lane already uses for this same constraint (make "
        "qemu-docker-image, then docker run --privileged hugmesh-qemu-runner) — the "
        "script's own refusal message spells that command out. "
        "Its --list and --dry-run verbs (the Studio's “List specs” and “Preview”) "
        "need no root and work now.")


# ── whole-mesh save: thin delegates over core/emulation_save ────────────────────────

def plan_mesh_save(plan: EmulationPlan, *, session: str = "", stamp: str = "",
                   overwrite: bool = False, budget_bytes: int = 0,
                   disk_usage=None) -> dict:
    """Preview a whole-mesh save of THIS plan's devices (pure; nothing pauses).

    Fed with the planner's rows, so "save the mesh" means the planned fleet: a
    planned device with no live record surfaces as an unresolved/blocked row in
    the returned dict instead of silently shrinking the set, and a stray device
    from some other session never rides along. All rules (liveness, disk budget,
    KEYS copy-back) are emulation_save's own.
    """
    return emulation_save.plan_mesh_save(
        plan.generator_dir, list(plan.rows), work_dir=plan.work_dir,
        session=session, stamp=stamp, overwrite=overwrite,
        budget_bytes=budget_bytes, disk_usage=disk_usage)


def save_mesh(plan: EmulationPlan, *, session: str = "", stamp: str = "",
              overwrite: bool = False, budget_bytes: int = 0, run=None,
              disk_usage=None) -> emulation_save.MeshSaveReport:
    """Save THIS plan's devices — one save-set, emulation_save's orchestration."""
    return emulation_save.save_mesh(
        plan.generator_dir, list(plan.rows), work_dir=plan.work_dir,
        session=session, stamp=stamp, overwrite=overwrite,
        budget_bytes=budget_bytes, run=run, disk_usage=disk_usage)


# ── status: THE reconciled truth ─────────────────────────────────────────────────────

@dataclass
class DeviceStatus:
    """One planned row's reconciled state + verdict."""
    label: str
    state: str = STATE_PLANNED
    verdict: str = VERDICT_PENDING
    detail: str = ""
    device: Device | None = None     # the live registry record, when one exists
    result: dict | None = None       # the row's verdict JSON, scoped + un-graded

    @property
    def green(self) -> bool:
        """Only a fresh, assertion-backed PASS is green — SUSPECT/STALE never are."""
        return self.verdict == "PASS"


@dataclass
class MeshStatus:
    """Everything :func:`status` reconciled about one plan."""
    plan: EmulationPlan
    rows: list[DeviceStatus] = field(default_factory=list)
    #: Where the device view came from: "runner" (the script's --devices, already
    #: reconciled), "registry+docker" (raw registry, downgrade replicated here) or
    #: "registry" (raw registry, docker unreachable — states are the records' own
    #: words and may flatter a killed container).
    source: str = "registry"
    #: Live registry records that are NOT the plan's — another session's devices,
    #: listed so "why is my port taken" has an answer, never graded.
    unplanned: list[Device] = field(default_factory=list)

    def row(self, label: str) -> DeviceStatus | None:
        for r in self.rows:
            if r.label == label:
                return r
        return None

    @property
    def all_green(self) -> bool:
        return bool(self.rows) and all(r.green for r in self.rows)

    def counts(self) -> dict[str, int]:
        out: dict[str, int] = {}
        for r in self.rows:
            key = r.verdict or "PENDING"
            out[key] = out.get(key, 0) + 1
        return out

    def summary(self) -> str:
        parts = [f"{name} {n}" for name, n in sorted(self.counts().items())]
        return (f"{len(self.rows)} planned row(s): " + ", ".join(parts)
                + f" (devices via {self.source})")


def _devices_argv(generator_dir: str, work_dir: str) -> list[str]:
    return [os.path.join(generator_dir, qemu_tests.RUNNER_SCRIPT),
            "--work", work_dir, "--devices"]


def _runner_devices(generator_dir: str, work_dir: str) -> list[Device] | None:
    """Device records via the runner's ``--devices``, or None when it cannot answer.

    Preferred over reading the registry directly because the runner RECONCILES:
    a record whose container is gone (docker kill, OOM, daemon restart) is
    downgraded to stopped before it is printed, and only when the daemon actually
    answered. The subcommand boots nothing, so this is a file read plus one
    ``docker ps`` behind a short timeout.
    """
    try:
        proc = subprocess.run(_devices_argv(generator_dir, work_dir),
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              text=True, timeout=DEVICES_PROBE_TIMEOUT_S)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    try:
        raw = json.loads(proc.stdout or "null")
    except ValueError:
        return None
    if not isinstance(raw, list):
        return None
    devices = (qemu_devices.device_from_record(rec) for rec in raw)
    return [d for d in devices if d is not None]


def _docker_running_names() -> set[str] | None:
    """Names of running containers, or None when docker did not answer.

    None is relied on: the fallback downgrade must NOT run on it. An unanswered
    daemon says nothing about the containers, and downgrading every record to
    stopped because docker was slow is the same lie in the other direction.
    """
    try:
        proc = subprocess.run(["docker", "ps", "--format", "{{.Names}}"],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              text=True, timeout=DOCKER_PS_TIMEOUT_S)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    return {name for name in proc.stdout.splitlines() if name}


def _registry_devices(work_dir: str) -> tuple[list[Device], str]:
    """The fallback lane: the raw registry plus the runner's own downgrade rule.

    Replicates cmd_devices' reconcile exactly: only when the daemon answered, and
    DOWNGRADE ONLY — a record is never promoted to running by anything but its own
    writer. A stale "running" would have the Studio offer a shell into a device
    that is gone.
    """
    devices = qemu_devices.discover_devices(work_dir)
    running = _docker_running_names()
    if running is None:
        return devices, "registry"
    reconciled = [replace(d, state="stopped")
                  if d.state not in ("stopped", "") and d.container not in running
                  else d
                  for d in devices]
    return reconciled, "registry+docker"


def _row_state(dev: Device | None) -> str:
    if dev is None:
        return STATE_PLANNED
    return _STATE_WORDS.get(dev.state, dev.state.upper())


def _int_field(value) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def _verdict_for(plan: EmulationPlan, dev: Device | None, result: dict | None,
                 run_completed: bool) -> tuple[str, str]:
    """(verdict, detail) for one row — every grading rule of the merge, in one place.

    * NO-RESULT — a planned row with no verdict after a COMPLETED test run. The
      runner's own CLI summary counts missing rows; a table that just leaves the
      row blank reads as "still running" forever. Only synthesized for TEST (a
      standing DEPLOY mesh legitimately has rows whose assertions have not
      finished) and only once the run is over.
    * STALE — the verdict predates the row's current boot (the record's
      ``started_at``; verdict and record are stamped from the SAME variable by the
      entrypoint) or, absent both, the plan's epoch. This is the cross-session
      bleed: results/ is never wiped, so last week's verdict for this label is
      sitting right there waiting to be presented as today's outcome.
    * SUSPECT — a PASS with ``assertions_passed == 0`` is never green: the
      2026-08-19 truncated-assertions defect graded six rows holding 9-12 real
      FAILs each as PASS, all with zero recorded assertions. The harness is fixed
      (T1), but old files persist and the class of failure is generic.
    """
    if result is None:
        if run_completed and plan.mode is EmulationMode.TEST:
            return VERDICT_NO_RESULT, ("the run completed without a verdict for "
                                       "this planned row")
        return VERDICT_PENDING, "no verdict yet"
    started = str(result.get("started_at") or "")
    epoch = plan.epoch
    dev_started = dev.started_at if dev is not None else ""
    if dev_started and dev_started > epoch:
        epoch = dev_started
    if epoch and (not started or started < epoch):
        return VERDICT_STALE, (f"verdict dated {started or 'undated'} predates the "
                               f"current run epoch {epoch} — it belongs to an "
                               "earlier boot of this label")
    verdict = str(result.get("status") or "")
    passed = _int_field(result.get("assertions_passed"))
    failed = _int_field(result.get("assertions_failed"))
    detail = f"{passed} assertion(s) passed, {failed} failed"
    if verdict == "PASS" and passed == 0:
        return VERDICT_SUSPECT, ("graded PASS with 0 assertions recorded — a "
                                 "verdict that asserted nothing is never green")
    if verdict in ("PASS", "FAIL", "ERROR"):
        runner_detail = str(result.get("detail") or "")
        return verdict, (f"{detail}" + (f" — {runner_detail}" if runner_detail else ""))
    return verdict or "UNKNOWN", f"unrecognized verdict {verdict!r}; {detail}"


def status(plan: EmulationPlan, *, run_completed: bool = False) -> MeshStatus:
    """THE reconciled truth about a plan's devices — one row per planned label.

    Sources, in preference order (see :data:`MeshStatus.source`): the runner's
    ``--devices`` (its reconcile against docker ps is the harness's own), then the
    raw registry with that downgrade replicated here, then the raw registry
    verbatim when docker never answered. Results are read SCOPED to the plan's
    labels and graded by :func:`_verdict_for`.

    ``run_completed`` is the caller's statement that the TEST run has exited —
    it arms the NO-RESULT synthesis and nothing else.
    """
    devices = _runner_devices(plan.generator_dir, plan.work_dir)
    if devices is not None:
        source = "runner"
    else:
        devices, source = _registry_devices(plan.work_dir)
    by_label = {d.label: d for d in devices}
    results = {str(r.get("label") or ""): r
               for r in qemu_tests.read_results(plan.work_dir, labels=plan.labels)}

    rows: list[DeviceStatus] = []
    for label in plan.labels:
        dev = by_label.get(label)
        result = results.get(label)
        verdict, detail = _verdict_for(plan, dev, result, run_completed)
        rows.append(DeviceStatus(label=label, state=_row_state(dev),
                                 verdict=verdict, detail=detail,
                                 device=dev, result=result))
    planned = set(plan.labels)
    return MeshStatus(plan=plan, rows=rows, source=source,
                      unplanned=[d for d in devices if d.label not in planned])


# ── THE process boundary (promoted from mesh_emulation) ─────────────────────────────

def spawn(argv: list[str], cwd: str,
          on_line: Callable[[str], None] | None = None,
          cancel: "threading.Event | None" = None) -> int:
    """THE single function through which every emulation argv becomes a process.

    Interface (the contract tests mock, and the only thing the GUI calls):

    * ``argv``     — one of this module's (or the cores') argv authors' outputs;
    * ``cwd``      — the generator checkout (the runner resolves itself from it);
    * ``on_line``  — called once per merged stdout/stderr line, newline-stripped;
    * ``cancel``   — an optional threading.Event; once set, the process GROUP gets
      SIGTERM (the runner spawns docker children, so signalling only the shell
      would orphan them — the same reason QemuTestRunner kills by group);
    * returns the exit code (127 when the process could not start at all).

    BLOCKS until the process exits, so callers run it off the GUI thread.
    Everything else in this module is pure planning; keeping the one impure step
    this narrow is what lets every emulation screen be tested with no qemu, no
    docker and no ssh — tests replace THIS function and assert on the argv it
    received. mesh_emulation.spawn is an alias of this function until T4.
    """
    try:
        proc = subprocess.Popen(argv, cwd=cwd, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, bufsize=1,
                                start_new_session=True)
    except OSError as exc:
        if on_line:
            on_line(f"!! could not run {argv[0]}: {exc}")
        return 127

    if cancel is not None:
        def _watch():
            cancel.wait()
            if proc.poll() is None:
                proc_group.terminate_group(proc)
        threading.Thread(target=_watch, daemon=True).start()

    assert proc.stdout is not None
    for line in proc.stdout:
        if on_line:
            on_line(line.rstrip("\n"))
    rc = proc.wait()
    if cancel is not None:
        cancel.set()        # release the watcher; a second set() is a no-op
    return rc


# ── CLI ──────────────────────────────────────────────────────────────────────────
# Same subcommand shape as core/emulation_save: previews are pure, actions act,
# and the Makefile faces (mesh-emu-up/-status/-down) are one line each.

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))))


def plan_as_dict(pl: EmulationPlan) -> dict:
    """The plan as plain data — the ``--json`` face, and nothing the text face
    does not also say."""
    devices = []
    for row in pl.rows:
        entry = {"label": row.label, "platform": row.platform, "arch": row.arch,
                 "role": row.role, "image": row.image, "stamp": row.stamp}
        planned = pl.mesh.device(row.label) if pl.mesh else None
        if planned is not None:
            entry.update({"ssh_port": planned.ssh_port, "ui_port": planned.ui_port,
                          "mac": planned.mac, "ip": planned.ip,
                          "keys_image": planned.keys_image})
        devices.append(entry)
    return {"mode": pl.mode.value, "session": pl.session_name,
            "session_path": pl.session_path, "work_dir": pl.work_dir,
            "epoch": pl.epoch, "gateway": pl.gateway_label,
            "front_door": pl.front_door, "argv": run_argv(pl),
            "devices": devices}


def status_as_dict(st: MeshStatus) -> dict:
    rows = []
    for r in st.rows:
        entry = {"label": r.label, "state": r.state, "verdict": r.verdict,
                 "detail": r.detail}
        if r.device is not None:
            entry.update({"container": r.device.container,
                          "ssh_host_port": r.device.ssh_host_port,
                          "artifacts": r.device.artifacts,
                          "image": r.device.image,
                          "started_at": r.device.started_at})
        rows.append(entry)
    return {"session": st.plan.session_name, "work_dir": st.plan.work_dir,
            "source": st.source, "rows": rows,
            "unplanned": [d.label for d in st.unplanned],
            "all_green": st.all_green, "summary": st.summary()}


def _print_plan(pl: EmulationPlan) -> None:
    print(f"emulation plan : {pl.session_name} [{pl.mode.value}]")
    print(f"  artifacts    : {pl.session_path}")
    print(f"  work dir     : {pl.work_dir}")
    if pl.mesh:
        print(f"  gateway      : {pl.gateway_label}  front door: {pl.front_door}")
    for row in pl.rows:
        planned = pl.mesh.device(row.label) if pl.mesh else None
        ports = (f"  ssh:{planned.ssh_port} web:{planned.ui_port} ip:{planned.ip}"
                 if planned else "")
        print(f"  {row.label:<24} {row.basename}{ports}")
    print(f"  argv         : {' '.join(shlex.quote(a) for a in run_argv(pl))}")


def _print_status(st: MeshStatus) -> None:
    print(f"emulated mesh  : {st.plan.session_name} (devices via {st.source})")
    for r in st.rows:
        verdict = r.verdict or "pending"
        extra = ""
        if r.device is not None and r.device.ssh_host_port:
            extra = f"  ssh 127.0.0.1:{r.device.ssh_host_port}"
        print(f"  {r.label:<24} [{r.state:<10}] {verdict:<10} {r.detail}{extra}")
    for dev in st.unplanned:
        print(f"  {dev.label:<24} (not in this plan; state {dev.state or 'unknown'})")
    print(f"  {st.summary()}")


def _print_save_report(report: emulation_save.MeshSaveReport) -> int:
    for res in report.results:
        if res.ok:
            print(f"  saved {res.label} -> {res.target}")
            if res.keys_error:
                print(f"    keys warning: {res.keys_error}")
            for piece in res.keys_copied:
                print(f"    keys: {piece}")
        else:
            print(f"  FAILED {res.label}: {res.error}", file=sys.stderr)
    if report.manifest_path:
        print(f"  manifest: {report.manifest_path}")
    if not report.results:
        print("no devices to save (nothing planned)", file=sys.stderr)
        return 1
    return 0 if report.ok else 1


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="python -m hugmesh_studio.core.emulation",
        description=("Plan, boot, inspect, stop and save emulated devices through "
                     "the one facade the Studio's pages drive. `plan` and `status` "
                     "are pure; `test` runs the assertion matrix, `up` boots the "
                     "standing (--keep-alive) mesh, `down` stops every device, "
                     "`save-mesh` saves the planned fleet's disks + KEYS sticks, "
                     "`playwright` runs the browser suite against ONE booted row "
                     "(tests/qemu/run-qemu-e2e.sh) — its --list needs no root."))
    p.add_argument("subcommand",
                   choices=("plan", "test", "up", "status", "down", "save-mesh",
                            "playwright"))
    p.add_argument("--generator-dir", default=_REPO_ROOT,
                   help="the hugmesh-generator checkout (default: this one)")
    p.add_argument("--session", default="",
                   help="build session: a name under out/sessions or a path "
                        "(default: the newest COMPLETE session)")
    p.add_argument("--work", default="",
                   help="runner --work dir (default: <generator>/out/qemu-runs)")
    p.add_argument("--mode", choices=("test", "deploy"), default="deploy",
                   help="plan only: which lane to preview (test/up ARE their lane)")
    p.add_argument("--jobs", type=int, default=2,
                   help="concurrency; the keep-alive boot-admission gate (0=ungated)")
    p.add_argument("--mem", type=int, default=2048, help="guest RAM (MB) per device")
    p.add_argument("--smp", type=int, default=2, help="guest vCPUs per device")
    p.add_argument("--timeout", type=int, default=2400, help="guest ssh wait (s)")
    p.add_argument("--assert-timeout", type=int, default=0,
                   help="in-guest assertion wall clock (s); 0 = entrypoint default")
    p.add_argument("--extra-user", action="append", default=[], metavar="NAME",
                   help="additional wheel login on every guest; repeatable")
    p.add_argument("--keep", action="store_true", help="keep per-run scratch dirs")
    p.add_argument("--cache-max-gb", type=int, default=0,
                   help="cap the decompressed-image cache (GiB); 0 = unbounded")
    p.add_argument("--json", action="store_true",
                   help="plan/status: machine-readable output")
    # ── the Playwright lane (subcommand `playwright`) ──────────────────────────
    p.add_argument("--row", default="",
                   help="playwright: which planned row to boot, as <platform>/<role> "
                        "(default: the first row with an x86/Pi launcher)")
    p.add_argument("--ui-port", type=int, default=PlaywrightOptions.ui_port,
                   help="playwright: host port the guest UI is forwarded to")
    p.add_argument("--ssh-port", type=int, default=PlaywrightOptions.ssh_port,
                   help="playwright: host port forwarded to the guest's :22")
    p.add_argument("--playwright-arg", action="append", default=[], metavar="ARG",
                   help="playwright: extra argv for `playwright test` (a spec path, "
                        "--grep, --repeat-each); repeatable, passed after `--`")
    p.add_argument("--list", dest="list_only", action="store_true",
                   help="playwright: enumerate the boot plan + the specs that would "
                        "run; boots nothing and needs no root")
    p.add_argument("--dry-run", action="store_true",
                   help="playwright: resolve the artifacts and print the boot plan")
    p.add_argument("--save-session", default="",
                   help="save-mesh: save-set name (default: mesh-<UTC stamp>)")
    p.add_argument("--overwrite", action="store_true",
                   help="save-mesh: allow replacing files an earlier run of the "
                        "SAME save-set wrote (never the golden images)")
    args = p.parse_args(argv)
    gen = args.generator_dir

    if args.subcommand == "down":
        # No session needed: --stop-all-devices sweeps whatever the registry under
        # --work holds, including rows of a session that no longer exists.
        work = args.work or qemu_devices.default_work_dir(gen)
        return spawn(mesh_emulation.stop_mesh_argv(gen, work_dir=work), gen,
                     on_line=print)

    try:
        sess = (_as_session(gen, args.session) if args.session
                else qemu_tests.default_session(gen))
    except ValueError as exc:
        print(exc, file=sys.stderr)
        return 1
    if sess is None:
        print("no build session with images under out/sessions — build images "
              "first, or pass --session", file=sys.stderr)
        return 1
    if sess.is_partial:
        print(f"note: session {sess.name} is {sess.completeness_badge()}",
              file=sys.stderr)

    env = RunEnvelope(jobs=args.jobs, mem_mb=args.mem, smp=args.smp,
                      timeout_s=args.timeout, assert_timeout_s=args.assert_timeout,
                      extra_users=tuple(args.extra_user), keep=args.keep,
                      cache_max_gb=args.cache_max_gb,
                      playwright_args=tuple(args.playwright_arg))

    if args.subcommand == "playwright":
        # epoch="" — this lane grades nothing; it hands the verdict to Playwright.
        pl = plan(gen, sess, EmulationMode.TEST, env, work_dir=args.work, epoch="")
        label = args.row
        if not label:
            for row in pl.rows:
                if playwright_target_for(row.platform):
                    label = row.label
                    break
        if not label:
            print("no planned row has an x86 or Pi launcher in "
                  f"{PLAYWRIGHT_SCRIPT} (rows: {', '.join(pl.labels) or 'none'})",
                  file=sys.stderr)
            return 1
        try:
            # --mem/--smp are NOT forwarded from the shared flags above: they default
            # to the DOCKER lane's 2048/2, and this lane's script defaults to 4096/4
            # because it boots a full node and drives a browser against it. Silently
            # halving a Playwright guest's RAM because another lane's default rode
            # along is the kind of cross-lane bleed this whole unit is about.
            # PlaywrightOptions carries both knobs for callers that mean them.
            opts = playwright_options_for_row(
                pl, label, ssh_port=args.ssh_port, ui_port=args.ui_port,
                keep=args.keep, list_only=args.list_only, dry_run=args.dry_run)
        except ValueError as exc:
            print(exc, file=sys.stderr)
            return 1
        argv = playwright_argv(pl, opts)
        # The refusal is stated BEFORE the spawn, not left to the script's own die:
        # booting needs root, enumerating and previewing do not.
        blocker = playwright_root_blocker()
        if blocker and not (args.list_only or args.dry_run):
            print(f"REFUSED: {blocker}", file=sys.stderr)
            print(f"  would run: {' '.join(shlex.quote(a) for a in argv)}",
                  file=sys.stderr)
            return 1
        return spawn(argv, gen, on_line=print)

    if args.subcommand == "plan":
        pl = plan(gen, sess, args.mode, env, work_dir=args.work)
        if args.json:
            json.dump(plan_as_dict(pl), sys.stdout, indent=2)
            sys.stdout.write("\n")
        else:
            _print_plan(pl)
        return 0 if pl.rows else 1

    if args.subcommand == "test":
        pl = plan(gen, sess, EmulationMode.TEST, env, work_dir=args.work)
        rc = spawn(run_argv(pl), gen, on_line=print)
        st = status(pl, run_completed=True)
        if args.json:
            json.dump(status_as_dict(st), sys.stdout, indent=2)
            sys.stdout.write("\n")
        else:
            _print_status(st)
        return rc if rc != 0 else (0 if st.all_green else 1)

    if args.subcommand == "up":
        pl = plan(gen, sess, EmulationMode.DEPLOY, env, work_dir=args.work)
        rc = spawn(run_argv(pl), gen, on_line=print)
        st = status(pl)
        _print_status(st)
        if pl.front_door:
            print(f"  front door   : {pl.front_door} (via the gateway's web tunnel)")
        return rc

    if args.subcommand == "status":
        # epoch="" — this process did not start the run, so verdicts are gated by
        # each device's own boot stamp, not by "when was status typed".
        pl = plan(gen, sess, EmulationMode.DEPLOY, env, work_dir=args.work, epoch="")
        st = status(pl)
        if args.json:
            json.dump(status_as_dict(st), sys.stdout, indent=2)
            sys.stdout.write("\n")
        else:
            _print_status(st)
        return 0

    # save-mesh
    pl = plan(gen, sess, EmulationMode.DEPLOY, env, work_dir=args.work, epoch="")
    try:
        report = save_mesh(pl, session=args.save_session, overwrite=args.overwrite)
    except emulation_save.MeshSaveError as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        return 1
    return _print_save_report(report)


if __name__ == "__main__":
    sys.exit(main())

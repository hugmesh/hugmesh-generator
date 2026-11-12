"""Whole-mesh emulation — the TUI surface of GUI PR #69 (issue #50 items 7-9).

Session picker first (prior build sessions holding bootable images), then the
per-device status list: one row per planned device with the four honest section
statuses (``boot`` / ``ssh`` / ``provision`` / ``web``) derived by
``core.mesh_emulation`` from the LIVE device registry + the runner's assertion
verdicts — never inferred.

TUI-appropriate scope: the list and the per-device detail are REAL (the same
core planner/status calls the GUI table makes); starting/stopping guests and
opening tunnels are surfaced as COPY-READY COMMAND HINTS (the runner argv /
ssh argv the GUI's buttons would spawn), not spawned processes — a terminal
operator pastes them into a shell of their own, which also keeps this screen
read-only toward the host. Every hint is built by the same single-argv-author
core functions the GUI uses, so the spelling can never drift.

T4: the argv authors are now reached through :mod:`...core.emulation`, the one
facade that composes the four emulation cores. Behaviour is unchanged for every
hint but ONE, and that one is the point of the move: a per-device start is
addressed with T1's ``--only-exact`` instead of ``--only``, which is a SUBSTRING
filter — restarting ``x86/be`` used to drag be+gpu and be-ha along. The fleet
stop now carries ``--work`` too, so a mesh booted in a custom work dir is
stopped against the registry it actually registered in.

QEMU FOR WINDOWS (WHPX): every hint above is the Docker backend's bash runner, which
a native Windows Studio cannot run — there the Docker backend prints the WSL2
sentence (``qemu_tests.native_blocker``) INSTEAD of argv nobody could paste.
:data:`BACKEND_KEY` cycles ``qemu_windows.BACKENDS`` — the TUI twin of the GUI page's
backend chooser — and under WHPX an x86 row's detail is ``qemu_windows``' own preview
of what a start runs plus the ``--qemu-windows`` CLI lines, an ARM row is
``row_refusal``'s sentence, and the whole-mesh verbs give way to the
one-device-at-a-time sentence. Still nothing spawns: the start is the operator's to
paste into a Windows terminal.
"""
from __future__ import annotations

import os
import shlex

from ..core import emulation as emu
from ..core import emulation_save, golive_target
from ..core import mesh_emulation as me
from ..core import platform_info, qemu_devices, qemu_tests, qemu_windows
from ..core.domain_services import session_boot_gate_reason
from . import model

__all__ = ["MeshEmuScreen", "BACKEND_KEY", "WHPX_ONE_AT_A_TIME", "WHPX_NOT_HERE",
           "WHPX_CLI_PREFIXES", "backend_label", "next_backend", "default_backend",
           "native_blocker_lines", "backend_lines", "whpx_cli_args", "whpx_device_table",
           "whpx_detail_lines", "device_table", "device_detail_lines",
           "plan_summary_lines", "save_hint_lines", "GO_LIVE_KEY", "GO_LIVE_ACTION",
           "front_door_target", "go_live_lines"]

#: The key that opens the Go-Live screen on the mesh's front door (the GUI page's
#: "Go live from this mesh…" button). Not b/q/r and not a digit.
GO_LIVE_KEY = "g"
GO_LIVE_ACTION = "Go live from this mesh…"


def front_door_target(plan: me.MeshPlan, devices: list, backend: str
                      ) -> golive_target.GoLiveTarget | None:
    """The go-live TARGET for the mesh's front door (its gateway row): the docker
    lane's keep-alive record, or — under QEMU for Windows — the native record. None
    when that row is not running at all."""
    label = plan.gateway_label
    if not label:
        return None
    if backend == qemu_windows.BACKEND_WHPX:
        rec = _whpx_live(plan).get(label)
        return golive_target.target_from_whpx(rec, plan.work_dir) if rec else None
    dev = qemu_devices.device_by_label(devices, label)
    return golive_target.target_from_device(dev, plan.work_dir) if dev else None


def go_live_refusal(plan: me.MeshPlan, target) -> str:
    """Why the front door cannot be gone live from, "" when it can (the record's own
    refusal — the device is probed when the Go-Live screen takes it)."""
    if target is None:
        return (f"the front door ({plan.gateway_label or 'none'}) is not running — "
                "start it first")
    return golive_target.refusal(target)


def go_live_lines(plan: me.MeshPlan, devices: list, backend: str) -> list[str]:
    """The front-door row's go-live line: the action and its key, or the sentence
    that refuses it."""
    why = go_live_refusal(plan, front_door_target(plan, devices, backend))
    if why:
        return [f"{GO_LIVE_ACTION} — not offered: {why}"]
    return [f"{GO_LIVE_ACTION} press {GO_LIVE_KEY}: the Go-Live screen on "
            f"{plan.gateway_label} (its own driver over ssh; plan here, the flip on its "
            "TTY)."]

#: The key that switches the emulation backend, cycling ``qemu_windows.BACKENDS`` —
#: the TUI twin of the GUI page's chooser. Not "q" (BACK), not "r" (refresh) and not
#: a digit (a digit opens a device row).
BACKEND_KEY = "b"

#: Why the whole-mesh verbs are absent under QEMU for Windows — the GUI page greys
#: its whole-mesh Start/Stop for the same reason.
WHPX_ONE_AT_A_TIME = ("QEMU for Windows (WHPX) boots ONE x86 device at a time — a thin "
                      "desktop or a single node — so it has no whole-mesh start or "
                      "stop: use each x86 row's own start and stop.")
#: What else this backend does not offer; each is the Docker backend's runner.
WHPX_NOT_HERE = ("Not on QEMU for Windows (WHPX): ARM rows, the QMP console, the web "
                 "tunnel and saving a disk or the whole mesh — those are the Docker "
                 "backend's.")

#: The two spellings of the QEMU for Windows CLI: the Studio's own flag and the module
#: itself. Both hand everything after them to ``qemu_windows``' own parser.
WHPX_CLI_PREFIXES = (("hugmesh-studio", "--qemu-windows"),
                     ("python", "-m", "hugmesh_studio.core.qemu_windows"))


def backend_label(backend: str) -> str:
    return dict(qemu_windows.backends())[backend]


def next_backend(backend: str) -> str:
    """The backend :data:`BACKEND_KEY` switches to: the next of ``BACKENDS``, wrapping."""
    ids = [bid for bid, _label in qemu_windows.BACKENDS]
    return ids[(ids.index(backend) + 1) % len(ids)]


def default_backend(osname: str | None = None) -> str:
    """The GUI page's rule: Docker everywhere, except a native Windows Studio — where
    the Docker lane is refused with the WSL2 sentence — whose QEMU for Windows can
    actually boot something."""
    return (qemu_windows.BACKEND_WHPX
            if qemu_tests.native_blocker() and not qemu_windows.blocker(osname)
            else qemu_windows.BACKEND_DOCKER)


def native_blocker_lines(switch: str) -> list[str]:
    """The Docker backend's WSL2 refusal on a native Windows Studio, [] elsewhere.

    ``qemu_tests.native_blocker()`` verbatim — the sentence the GUI and the emulation
    CLI refuse with — plus where the one lane that does run there lives (``switch``
    says how to reach it from the screen showing this).

    A Mac missing Homebrew's GNU tools is refused by the same sentence function, and
    gets only its own lines (the ``brew install`` command on a line by itself): it is
    not a Windows Studio, has no WSL2, and QEMU for Windows cannot boot anything
    there, so ``switch`` is not offered."""
    blocker = qemu_tests.native_blocker()
    if not blocker:
        return []
    if platform_info.blocker_kind(blocker) == "darwin":
        return ["! not on this Mac yet:"] + [
            "  " + line for line in platform_info.blocker_lines(blocker)]
    return ["! not from this Windows Studio:", "  " + blocker,
            "  To boot ONE x86 device image (a thin desktop or a single node) on this "
            f"PC without WSL2: {switch} “{backend_label(qemu_windows.BACKEND_WHPX)}”."]


def backend_lines(backend: str, osname: str | None = None) -> list[str]:
    """Which backend the hints below are for, and whether it can run here."""
    out = [f"backend   {backend_label(backend)}  ({BACKEND_KEY} = switch)"]
    if backend != qemu_windows.BACKEND_WHPX:
        return out + native_blocker_lines(f"press {BACKEND_KEY} for the backend")
    why = qemu_windows.blocker(osname)
    if why:
        out.append("! not ready: " + why)
    else:
        install = qemu_windows.find_qemu()
        out.append(f"ready: QEMU for Windows in {install.dir if install else '?'}, "
                   "with WHPX acceleration.")
    return out + [WHPX_ONE_AT_A_TIME]


def whpx_cli_args(eplan: emu.EmulationPlan, action: str, label: str = "") -> list[str]:
    """``ACTION [options]`` for ``qemu_windows``' own parser, addressed at this plan.

    ``--generator-dir`` always (the module's default is the checkout it sits in, the
    Studio's is its resolved one — neither has to be this screen's), ``--work`` only
    when the plan's differs from the default both sides compute."""
    args = [action]
    if action == "start":
        args += ["--session", eplan.session_name, "--row", label]
    elif action == "stop":
        args += ["--row", label]
    # Absolute: the line is pasted into a terminal whose folder need not be this one.
    args += ["--generator-dir", os.path.abspath(eplan.generator_dir)]
    if eplan.work_dir != qemu_devices.default_work_dir(eplan.generator_dir):
        args += ["--work", os.path.abspath(eplan.work_dir)]
    return args


def _whpx_join(argv: list[str], osname: str | None) -> str:
    # qemu_windows' own quoting: cmd.exe's on Windows, a POSIX shell's elsewhere.
    return qemu_windows._quote(argv, osname)


def _whpx_cli_lines(eplan: emu.EmulationPlan, action: str, label: str,
                    osname: str | None) -> list[str]:
    args = whpx_cli_args(eplan, action, label)
    return ["  " + _whpx_join([*prefix, *args], osname) for prefix in WHPX_CLI_PREFIXES]


def _whpx_live(plan: me.MeshPlan) -> dict[str, dict]:
    # qemu_windows.running: a record left by a crash or a reboot is not running.
    return {rec["label"]: rec for rec in qemu_windows.running(plan.work_dir)}


def whpx_device_table(plan: me.MeshPlan,
                      live: dict[str, dict]) -> tuple[list[str], list[list[str]]]:
    """(headers, rows) under QEMU for Windows: its registry, nothing else. Only a boot
    column — this backend boots a device and runs no assertions, so the Docker lane's
    ssh/provision/web grades would be grades nobody made."""
    headers = ["#", "device", "role", "platform", "boot", "ssh"]
    rows: list[list[str]] = []
    for i, planned in enumerate(plan.devices, 1):
        rec = live.get(planned.label)
        boot = ("running" if rec else
                "refused" if qemu_windows.row_refusal(planned.platform) else "off")
        rows.append([str(i), planned.label, planned.role, planned.platform, boot,
                     f"127.0.0.1:{rec['ssh_port']}" if rec else ""])
    return headers, rows


def _results_by_label(plan: me.MeshPlan) -> dict[str, dict]:
    labels = [d.label for d in plan.devices]
    return {str(r.get("label", "")): r
            for r in qemu_tests.read_results(plan.work_dir, labels)}


def device_table(plan: me.MeshPlan,
                 devices: list) -> tuple[list[str], list[list[str]]]:
    """(headers, rows) for the per-device status list — one row per planned
    device, statuses from the live registry/results (honest at every stage)."""
    results = _results_by_label(plan)
    headers = ["#", "device", "role", "platform", "ssh port", "boot", "ssh",
               "provision", "web"]
    rows: list[list[str]] = []
    for i, planned in enumerate(plan.devices, 1):
        dev = qemu_devices.device_by_label(devices, planned.label)
        sections = me.section_statuses(planned, dev, results.get(planned.label),
                                       gateway=planned.label == plan.gateway_label)
        # live-vs-planned ssh port: the registry is authoritative once up.
        port = str(dev.ssh_host_port) if dev is not None and dev.ssh_host_port \
            else f"{planned.ssh_port} (planned)"
        rows.append([str(i), planned.label, planned.role, planned.platform, port]
                    + [sections[s][0] for s in me.SECTIONS])
    return headers, rows


def plan_summary_lines(plan: me.MeshPlan) -> list[str]:
    front = me.front_door_url(plan)
    gw = plan.gateway_label or "(none)"
    return [
        f"mesh plan — session {plan.session_name}: {len(plan.devices)} "
        f"device(s), gateway {gw}",
        (f"front door (once the gateway's web tunnel is up): {front}"
         if front else "front door: (no gateway — the session holds no rows)"),
    ]


def save_hint_lines(eplan: emu.EmulationPlan) -> list[str]:
    """The WHOLE-MESH SAVE hint (issue #50 item 10) — the TUI's face of it.

    A save copies every live device's disk at its FULL virtual size (16 GiB per
    ARM row, 32 GiB per x86 row), so the preview matters more than the command:
    this box has run out of room mid-fleet before, and that failure takes the
    live mesh's own volumes down with it. ``emulation.plan_mesh_save`` answers
    what the save WOULD need and whether it fits — purely, from the registry and
    a ``statvfs``; nothing is paused, created or copied by looking.

    The command itself is only ever printed. Saving is a multi-GB, device-pausing
    action, and this screen does not act on the host.
    """
    preview = emu.plan_mesh_save(eplan)
    devices = preview["devices"]
    blocked = [row for row in devices if row["blocker"]]
    unresolved = preview["unresolved"]
    needed, free = preview["needed_bytes"], preview["free_bytes"]
    gib = emulation_save.GIB
    lines = [
        "save the WHOLE mesh — every LIVE device's disk plus its emulated KEYS "
        "stick, into one flashable save-set:",
        f"  python -m hugmesh_studio.core.emulation save-mesh "
        f"--generator-dir {shlex.quote(eplan.generator_dir)} "
        f"--session {shlex.quote(eplan.session_name)}",
        "  (the Makefile's `make qemu-save-mesh` saves every device the registry "
        "holds; the command above saves exactly THIS session's planned fleet.)",
        # denominator is the PLAN's fleet, not the resolved subset: "0 of 0" for a
        # mesh that is simply not running would read as "nothing to save".
        f"budget preview: {len(devices) - len(blocked)} of {len(eplan.rows)} "
        f"planned device(s) savable, needs {needed / gib:.1f} GiB, "
        + ("free space unknown" if free < 0 else f"{free / gib:.1f} GiB free"),
    ]
    for row in blocked:
        lines.append(f"  blocked   {row['label']} — {row['blocker']}")
    # Group by REASON: a whole fleet that is simply not up shares one explanation
    # (a paragraph each would bury the row that is unsaveable for a DIFFERENT
    # one). The core's errors open with the row's own label, so that prefix is
    # dropped before grouping — the sentence after it is the shared reason, and
    # it is reproduced verbatim rather than reworded here.
    by_reason: dict[str, list[str]] = {}
    for row in unresolved:
        label, reason = row["label"], row["error"]
        prefix = f"{label} "
        by_reason.setdefault(
            reason[len(prefix):] if reason.startswith(prefix) else reason,
            []).append(label)
    for reason, labels in by_reason.items():
        lines.append(f"  no device {', '.join(labels)} — {reason}")
    if preview["refusal"]:
        lines.append(f"  REFUSED: {preview['refusal']}")
    return lines


def whpx_detail_lines(eplan: emu.EmulationPlan, planned: me.PlannedDevice,
                      boot_refusal: str = "", osname: str | None = None) -> list[str]:
    """One device's detail under QEMU for Windows (WHPX).

    An x86 row: its live record or ``qemu_windows.preview_lines`` (what a start
    runs) and the ``--qemu-windows`` start/stop CLI lines; an ARM row:
    ``row_refusal``'s sentence. ``qemu_windows.blocker`` is shown when this host
    cannot boot it — off Windows that is all there is, since nothing below would
    run there. ``boot_refusal`` (#637) replaces the preview and the start, exactly as
    it replaces the Docker backend's start hints."""
    plan = eplan.mesh
    assert plan is not None, "whpx_detail_lines needs a DEPLOY plan"
    lines = [
        f"device    {planned.label}  ({planned.role} · {planned.platform} · "
        f"{planned.arch})",
        f"image     {planned.image}",
        "",
    ]
    why = qemu_windows.blocker(osname)
    if why:
        lines.append("! not ready: " + why)
        if (osname or os.name) != "nt":
            return lines
        lines.append("")
    refusal = qemu_windows.row_refusal(planned.platform)
    live = _whpx_live(plan)
    rec = live.get(planned.label)
    if refusal:
        lines.append("! refused: " + refusal)
    elif rec:
        shown = "desktop window" if rec.get("display") == "window" else "headless"
        lines += [
            f"boot      running under QEMU for Windows (pid {rec['pid']}, "
            f"{rec.get('mem_mb', '?')} MiB, {shown})",
            f"web       https://127.0.0.1:{rec['ui_port']}/  (its :443, on 127.0.0.1 "
            "only)",
            f"console   {os.path.join(str(rec.get('run_dir', '')), 'console.log')}",
            "ssh in — QEMU for Windows adds no account to the guest, so log in as a "
            "user this image was built with:",
            "  " + _whpx_join(qemu_windows.ssh_argv(rec, "<user>"), osname),
        ]
    else:
        lines.append("boot      not running")
        busy = next(iter(live.values()), None)
        if busy:
            lines.append(f"! {busy['label']} is running, and this backend runs one "
                         "device at a time — stop it first.")
        if boot_refusal:
            lines += ["not started from here:", "  ! refused: " + boot_refusal]
        else:
            opts = qemu_windows.options_for_row(planned, eplan.work_dir)
            lines.append("what a start runs (QEMU for Windows' own preview; the QMP "
                         "port is picked free at start):")
            lines += ["  " + ln for ln in qemu_windows.preview_lines(opts,
                                                                     osname=osname)]
            lines.append(f"start it ({opts.mem_mb} MiB, headless; add --window for a "
                         "desktop window, --mem N for memory) — paste into a Windows "
                         "terminal, this screen spawns nothing:")
            lines += _whpx_cli_lines(eplan, "start", planned.label, osname)
    if planned.label == plan.gateway_label:
        lines += go_live_lines(plan, [], qemu_windows.BACKEND_WHPX)
    if not refusal:
        lines.append("stop it — ACPI power-off first, a hard kill only if it does "
                     "not go; the session's image is never written:")
        lines += _whpx_cli_lines(eplan, "stop", planned.label, osname)
    lines += ["", WHPX_ONE_AT_A_TIME, WHPX_NOT_HERE,
              "which device this backend is running:"]
    lines += _whpx_cli_lines(eplan, "status", "", osname)
    return lines


def device_detail_lines(eplan: emu.EmulationPlan, planned: me.PlannedDevice,
                        devices: list, boot_refusal: str = "",
                        backend: str = qemu_windows.BACKEND_DOCKER,
                        osname: str | None = None) -> list[str]:
    """The per-device detail: identity, section statuses WITH their detail text,
    and the copy-ready command hints (start / ssh / QMP / web tunnel / save).

    ``boot_refusal`` (``core.domain_services.session_boot_gate_reason``, #637)
    replaces the two START hints — this device's and the whole mesh's — with the
    refusal: printing the argv the GUI refuses to run would make this face the way
    around that gate. Stop, ssh, QMP and save stay: none of them boots anything.

    On a native Windows Studio every one of those hints is a bash script it cannot
    run, so the WSL2 sentence replaces them all (save-mesh refuses with it too).
    ``backend`` WHPX is :func:`whpx_detail_lines`."""
    if backend == qemu_windows.BACKEND_WHPX:
        return whpx_detail_lines(eplan, planned, boot_refusal, osname)
    plan = eplan.mesh
    assert plan is not None, "device_detail_lines needs a DEPLOY plan"
    generator_dir = eplan.generator_dir
    results = _results_by_label(plan)
    dev = qemu_devices.device_by_label(devices, planned.label)
    gateway = planned.label == plan.gateway_label
    sections = me.section_statuses(planned, dev, results.get(planned.label),
                                   gateway=gateway)
    lines = [
        f"device    {planned.label}  ({planned.role} · {planned.platform} · "
        f"{planned.arch})",
        f"image     {planned.image}",
        f"identity  mac {planned.mac} · mesh ip {planned.ip}",
        f"keys      {planned.keys_image}  (emulated USB provisioning stick)",
        "",
    ]
    for section in me.SECTIONS:
        status, detail = sections[section]
        lines.append(f"{section:9s} {status} — {detail}")
    lines.append("")
    native = native_blocker_lines(f"press {BACKEND_KEY} for the backend")
    if native:
        return lines + native
    if dev is not None and dev.is_running and dev.ssh_host_port > 0 and dev.ssh_key:
        lines.append("ssh in:")
        lines.append("  " + shlex.join(emu.ssh_argv(dev, dev.ssh_user)))
        lines.append("ask the emulator what it thinks this guest is doing "
                     "(reads only, changes nothing):")
        lines.append("  " + shlex.join(emu.qmp_argv(generator_dir, dev, "status")))
        if gateway:
            lines.append("web front door — start the tunnel, then browse "
                         f"{me.front_door_url(plan)}:")
            lines.append("  " + shlex.join(emu.web_tunnel_argv(dev, planned)))
    elif boot_refusal:
        lines.append("not running — and not started from here:")
        lines.append("  ! refused: " + boot_refusal)
    else:
        lines.append("not running — start it (keep-alive) with:")
        lines.append("  " + shlex.join(
            emu.start_device_argv(eplan, planned.label)))
        lines.append(f"once up, ssh lands on {me.SSH_HOST}:{planned.ssh_port} "
                     "(planned — the device registry is authoritative).")
    if gateway:
        lines += go_live_lines(plan, devices, backend)
    lines.append("")
    if not boot_refusal:
        lines.append("start the WHOLE mesh with:")
        lines.append("  " + shlex.join(emu.run_argv(eplan)))
    lines.append("stop everything with:")
    lines.append("  " + shlex.join(emu.stop_all_argv(eplan)))
    lines.append("")
    lines += save_hint_lines(eplan)
    return lines


class MeshEmuScreen:
    """MESH EMULATION: session picker -> per-device status list -> detail."""

    slug = "meshemu"
    title = "Mesh emulation"
    wants_q = True                       # q navigates BACK through the sub-states
    #: ``os.name`` unless a test answers as another host (qemu_windows' convention).
    osname: str | None = None

    def __init__(self):
        self._sub = "pick"               # pick | table | detail
        self._sessions: list = []
        #: The DEPLOY plan from the facade; ``_eplan.mesh`` IS the MeshPlan the
        #: table renders, so the two can never describe different device sets.
        self._eplan: emu.EmulationPlan | None = None
        self._plan: me.MeshPlan | None = None
        self._detail: me.PlannedDevice | None = None
        self._refusal = ""               # #637: the picked session's boot refusal
        #: A qemu_windows.BACKENDS id; chosen on first entry, then the operator's.
        self._backend = ""

    @property
    def _whpx(self) -> bool:
        return self._backend == qemu_windows.BACKEND_WHPX

    def enter(self, j) -> None:
        self._sub = "pick"
        self._eplan = None
        self._plan = None
        self._detail = None
        self._refusal = ""
        if not self._backend:
            self._backend = default_backend(self.osname)
        # which prior sessions hold bootable images — the same discovery the
        # QEMU device-test lane uses (only_with_images: an empty session cannot
        # be emulated and is not offered).
        self._sessions = qemu_tests.discover_sessions(j.generator_dir,
                                                      only_with_images=True)

    def _devices(self) -> list:
        assert self._plan is not None
        return qemu_devices.discover_devices(self._plan.work_dir)

    def lines(self, j) -> list[str]:
        if self._sub == "pick":
            out = ["Emulate a WHOLE built mesh: pick the prior build session "
                   "whose images to boot.", ""]
            if not self._sessions:
                out.append("  (no build session holds bootable images yet — "
                           "build a mesh first)")
            for i, sess in enumerate(self._sessions, 1):
                out.append(f"  {i}. {sess.name} — {len(sess.rows)} bootable "
                           f"image(s)")
            out += ["", "(a NUMBER picks; q = back to the menu)"]
            return out
        assert self._plan is not None and self._eplan is not None
        if self._sub == "detail" and self._detail is not None:
            devices = [] if self._whpx else self._devices()
            gl = (f" · {GO_LIVE_KEY} = {GO_LIVE_ACTION}"
                  if self._detail.label == self._plan.gateway_label else "")
            return device_detail_lines(self._eplan, self._detail, devices,
                                       self._refusal, self._backend, self.osname) + \
                ["", f"({BACKEND_KEY} = switch backend · r = refresh{gl} · "
                     "q = back to the device list)"]
        # Under WHPX only the plan line: the front door rides the Docker backend's
        # web tunnel, which this backend does not have.
        out = plan_summary_lines(self._plan)[:1] if self._whpx else \
            plan_summary_lines(self._plan)
        out += backend_lines(self._backend, self.osname)
        if self._refusal:
            out.append("! refused — this session's devices are not started from "
                       "here: " + self._refusal)
        out.append("")
        if self._whpx:
            headers, rows = whpx_device_table(self._plan, _whpx_live(self._plan))
            out += model.format_table(headers, rows)
            refused = sorted({d.platform for d in self._plan.devices
                              if qemu_windows.row_refusal(d.platform)})
            out += [f"refused: {qemu_windows.row_refusal(p)}" for p in refused]
        else:
            headers, rows = device_table(self._plan, self._devices())
            out += model.format_table(headers, rows)
        out += ["", "(a NUMBER opens a device's detail + access hints · "
                    f"{BACKEND_KEY} = switch backend · r = refresh · q = back)"]
        return out

    def prompt(self, j) -> str:  # noqa: ARG002 — screen-protocol signature
        return f"meshemu:{self._sub}> "

    def feed(self, j, line: str) -> None:
        low = line.lower()
        if self._sub == "pick":
            if low in ("q", "quit", "exit", ""):
                j.goto("mode")
                return
            row = _index(line, len(self._sessions))
            if row is None:
                j.status = f"no such session: {line!r}"
                return
            # epoch="" — this screen inspects a mesh some other process started,
            # so verdicts are gated by each device's own boot stamp rather than
            # by "when was the session picked" (the status CLI's rule).
            self._eplan = emu.plan(j.generator_dir, self._sessions[row],
                                   emu.EmulationMode.DEPLOY, epoch="")
            self._plan = self._eplan.mesh
            # the SAME seam the GUI's Mesh emulation page reads (#637)
            self._refusal = session_boot_gate_reason(self._sessions[row].name)
            self._sub = "table"
            return
        if low == BACKEND_KEY:
            # Table or detail: the next qemu_windows.BACKENDS id. Switching boots and
            # stops nothing — it changes which backend the hints are for.
            self._backend = next_backend(self._backend)
            j.status = f"backend: {backend_label(self._backend)}"
            return
        if self._sub == "detail":
            if low in ("q", "quit", "exit"):
                self._sub = "table"
            elif low == GO_LIVE_KEY and self._detail is not None:
                self._go_live(j)
            # r (or anything else) re-renders — the detail reads live state
            return
        # table
        if low in ("q", "quit", "exit"):
            self._sub = "pick"
            return
        if low in ("r", "refresh", ""):
            return                        # lines() re-reads registry + results
        assert self._plan is not None
        row = _index(line, len(self._plan.devices))
        if row is None:
            j.status = f"no such device row: {line!r}"
            return
        self._detail = self._plan.devices[row]
        self._sub = "detail"


    def _go_live(self, j) -> None:
        """``g`` on the front door's detail: the Go-Live screen over this one, on that
        device; ``b`` on its first step comes back here."""
        assert self._plan is not None and self._detail is not None
        if self._detail.label != self._plan.gateway_label:
            j.status = (f"{GO_LIVE_ACTION} is the front door's "
                        f"({self._plan.gateway_label}) — open that row")
            return
        devices = [] if self._whpx else self._devices()
        target = front_door_target(self._plan, devices, self._backend)
        why = go_live_refusal(self._plan, target)
        if why:
            j.status = why
            return
        from .golive import GoLiveScreen
        screen = GoLiveScreen()
        screen.back_to = "Mesh emulation"
        j.open_overlay(screen)
        why = screen.preselect_target(j, target, work_dir=self._plan.work_dir)
        if why:
            j.close_overlay()
            j.status = why


def _index(line: str, count: int) -> int | None:
    try:
        n = int(line.strip())
    except ValueError:
        return None
    return n - 1 if 1 <= n <= count else None

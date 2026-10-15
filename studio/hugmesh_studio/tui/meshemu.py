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
"""
from __future__ import annotations

import shlex

from ..core import emulation as emu
from ..core import emulation_save
from ..core import mesh_emulation as me
from ..core import qemu_devices, qemu_tests
from ..core.domain_services import session_boot_gate_reason
from . import model

__all__ = ["MeshEmuScreen", "device_table", "device_detail_lines",
           "plan_summary_lines", "save_hint_lines"]


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


def device_detail_lines(eplan: emu.EmulationPlan, planned: me.PlannedDevice,
                        devices: list, boot_refusal: str = "") -> list[str]:
    """The per-device detail: identity, section statuses WITH their detail text,
    and the copy-ready command hints (start / ssh / QMP / web tunnel / save).

    ``boot_refusal`` (``core.domain_services.session_boot_gate_reason``, #637)
    replaces the two START hints — this device's and the whole mesh's — with the
    refusal: printing the argv the GUI refuses to run would make this face the way
    around that gate. Stop, ssh, QMP and save stay: none of them boots anything."""
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

    def __init__(self):
        self._sub = "pick"               # pick | table | detail
        self._sessions: list = []
        #: The DEPLOY plan from the facade; ``_eplan.mesh`` IS the MeshPlan the
        #: table renders, so the two can never describe different device sets.
        self._eplan: emu.EmulationPlan | None = None
        self._plan: me.MeshPlan | None = None
        self._detail: me.PlannedDevice | None = None
        self._refusal = ""               # #637: the picked session's boot refusal

    def enter(self, j) -> None:
        self._sub = "pick"
        self._eplan = None
        self._plan = None
        self._detail = None
        self._refusal = ""
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
            return device_detail_lines(self._eplan, self._detail,
                                       self._devices(), self._refusal) + \
                ["", "(r = refresh · q = back to the device list)"]
        out = plan_summary_lines(self._plan)
        if self._refusal:
            out.append("! refused — this session's devices are not started from "
                       "here: " + self._refusal)
        out.append("")
        headers, rows = device_table(self._plan, self._devices())
        out += model.format_table(headers, rows)
        out += ["", "(a NUMBER opens a device's detail + access hints · "
                    "r = refresh · q = back)"]
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
        if self._sub == "detail":
            if low in ("q", "quit", "exit"):
                self._sub = "table"
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


def _index(line: str, count: int) -> int | None:
    try:
        n = int(line.strip())
    except ValueError:
        return None
    return n - 1 if 1 <= n <= count else None

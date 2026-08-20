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
"""
from __future__ import annotations

import shlex

from ..core import mesh_emulation as me
from ..core import qemu_devices, qemu_tests
from . import model

__all__ = ["MeshEmuScreen", "device_table", "device_detail_lines",
           "plan_summary_lines"]


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


def device_detail_lines(generator_dir: str, plan: me.MeshPlan,
                        planned: me.PlannedDevice, devices: list) -> list[str]:
    """The per-device detail: identity, section statuses WITH their detail text,
    and the copy-ready command hints (start / ssh / web tunnel)."""
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
        lines.append("  " + shlex.join(qemu_devices.ssh_argv(dev, dev.ssh_user)))
        if gateway:
            lines.append("web front door — start the tunnel, then browse "
                         f"{me.front_door_url(plan)}:")
            lines.append("  " + shlex.join(me.web_tunnel_argv(dev, planned)))
    else:
        lines.append("not running — start it (keep-alive) with:")
        lines.append("  " + shlex.join(
            me.start_device_argv(generator_dir, plan, planned)))
        lines.append(f"once up, ssh lands on {me.SSH_HOST}:{planned.ssh_port} "
                     "(planned — the device registry is authoritative).")
    lines.append("")
    lines.append("start the WHOLE mesh with:")
    lines.append("  " + shlex.join(me.start_mesh_argv(generator_dir, plan)))
    lines.append("stop everything with:")
    lines.append("  " + shlex.join(me.stop_mesh_argv(generator_dir)))
    return lines


class MeshEmuScreen:
    """MESH EMULATION: session picker -> per-device status list -> detail."""

    slug = "meshemu"
    title = "Mesh emulation"
    wants_q = True                       # q navigates BACK through the sub-states

    def __init__(self):
        self._sub = "pick"               # pick | table | detail
        self._sessions: list = []
        self._plan: me.MeshPlan | None = None
        self._detail: me.PlannedDevice | None = None

    def enter(self, j) -> None:
        self._sub = "pick"
        self._plan = None
        self._detail = None
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
        assert self._plan is not None
        if self._sub == "detail" and self._detail is not None:
            return device_detail_lines(j.generator_dir, self._plan,
                                       self._detail, self._devices()) + \
                ["", "(r = refresh · q = back to the device list)"]
        out = plan_summary_lines(self._plan)
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
            self._plan = me.plan_mesh(self._sessions[row], j.generator_dir)
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

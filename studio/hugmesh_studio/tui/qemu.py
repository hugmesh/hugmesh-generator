"""tui — QEMU device tests: the TEST-mode face over :mod:`...core.emulation`.

The mesh-emulation screen (:mod:`.meshemu`) is the DEPLOY lane of a plan — a
standing ``--keep-alive`` mesh. This is the OTHER lane of the same plan: the
matrix run that boots every row, asserts, powers the guest off and leaves a
verdict behind. One session, one planner, two run shapes.

TUI-appropriate scope, inherited from :mod:`.meshemu` DELIBERATELY (it is a
design decision, not a missing feature): this screen stays READ-ONLY toward the
host. It plans, it reads the device registry and the verdict JSONs, and it
renders COPY-READY argv for everything that would spawn something — the whole
matrix run, one row's re-boot, the SELinux AVC workout. A terminal operator
pastes those into a shell of their own. Nothing here starts a container, a
guest or an ssh; the only process any of this can reach is the read-only
``--devices`` probe ``emulation.status()`` makes on its own (a file read plus
one ``docker ps``, which boots nothing), and that one belongs to the core, not
to this face.

Every hint is authored by ``core.emulation`` — the one module that composes
qemu_tests + qemu_devices + mesh_emulation + emulation_save — so the TUI cannot
print a spelling the GUI, the Makefile and the CLI do not also run. The pin for
that is a test comparing this module's hint to ``emulation.run_argv`` itself.

VERDICTS ARE NOT GRADED HERE. ``emulation.status()`` is the single grader:
PASS / FAIL / ERROR come from the runner, and it synthesizes the three that
exist because a table can lie by omission — SUSPECT (a PASS that recorded zero
assertions, never shown as a pass), STALE (a verdict from an earlier boot of
the same label) and NO-RESULT (a planned row a COMPLETED run never graded).
This module only chooses columns and copy.
"""
from __future__ import annotations

import shlex

from ..core import emulation as emu
from ..core import qemu_devices, qemu_tests
from . import model

__all__ = ["QemuScreen", "COMPLETE_BADGE", "MAKE_TARGET", "VERDICT_LEGEND",
           "session_badge", "session_lines", "default_session_index", "plan_for",
           "planned_table", "run_hint_lines", "run_completed", "results_table",
           "legend_lines", "row_detail_lines"]

#: Badge for a session whose build produced every image it intended. The PARTIAL
#: spelling is the session's OWN (``BuildSession.completeness_badge``), so the two
#: faces can never describe the same aborted build differently.
COMPLETE_BADGE = "COMPLETE"

#: The Makefile face of this lane. The copy-ready argv the screen prints above it
#: is the EXACT command (artifacts and work dir pinned); this is the same lane
#: through make's own defaults, for an operator who lives in the Makefile.
MAKE_TARGET = "make qemu-docker"

#: What the three synthesized verdicts mean, on screen rather than in the docs —
#: keyed by ``core.emulation``'s own constants so a renamed verdict breaks the
#: legend loudly instead of leaving a stale word in the footer.
VERDICT_LEGEND = {
    emu.VERDICT_SUSPECT: "graded PASS with 0 assertions recorded — never a pass",
    emu.VERDICT_STALE: "a verdict from an EARLIER boot of this label",
    emu.VERDICT_NO_RESULT: "the run finished without grading this planned row",
}


def session_badge(sess) -> str:
    """``COMPLETE`` or the session's own PARTIAL badge — never a second spelling."""
    return sess.completeness_badge() or COMPLETE_BADGE


def default_session_index(sessions: list) -> int:
    """Index of the session a picker preselects: the newest COMPLETE one.

    ``qemu_tests.default_session``'s rule, applied to a list already discovered
    (the picker must not re-scan the disk to learn its own default): a partial
    session still LISTS — its images are real and individually runnable — but
    defaulting to it silently hands the operator a 1-of-4 matrix. When every
    session is partial the newest of them is still the answer. -1 for none.
    """
    for i, sess in enumerate(sessions):
        if not sess.is_partial:
            return i
    return 0 if sessions else -1


def session_lines(sessions: list, default_index: int = -1) -> list[str]:
    """The picker's numbered list, one line per session, badged."""
    out: list[str] = []
    for i, sess in enumerate(sessions):
        mark = "  (default)" if i == default_index else ""
        out.append(f"  {i + 1}. {sess.name} — {len(sess.rows)} bootable image(s) "
                   f"[{session_badge(sess)}]{mark}")
    return out


def plan_for(generator_dir: str, session) -> emu.EmulationPlan:
    """The TEST plan for one session — pure arithmetic, boots nothing.

    ``epoch=""`` on purpose: this screen inspects a run some OTHER process
    started, so a verdict is gated STALE by the DEVICE's own boot stamp rather
    than by "when was this screen opened" — the exact reason the ``status``
    subcommand of the emulation CLI passes the same empty epoch.
    """
    return emu.plan(generator_dir, session, emu.EmulationMode.TEST, epoch="")


def planned_table(plan: emu.EmulationPlan) -> tuple[list[str], list[list[str]]]:
    """(headers, rows) for what this plan WOULD boot, in the runner's boot order
    (Pi rows first — pure TCG and slowest — then x86, which gets KVM)."""
    headers = ["#", "device", "platform", "arch", "role", "artifact"]
    rows: list[list[str]] = []
    for i, row in enumerate(plan.rows, 1):
        artifact = row.basename + ("  (decompressed once)" if row.compressed else "")
        rows.append([str(i), row.label, row.platform, row.arch, row.role, artifact])
    return headers, rows


def run_hint_lines(plan: emu.EmulationPlan) -> list[str]:
    """The copy-ready whole-matrix run, plus the same lane's make-target spelling.

    The argv is ``emulation.run_argv`` VERBATIM — this module builds no command of
    its own, which is what keeps the printed hint and the GUI's spawn identical.
    """
    return [
        f"run the whole TEST matrix for {plan.session_name} — boot every row, "
        "assert, power off (paste into a shell; this screen spawns nothing):",
        "  " + shlex.join(emu.run_argv(plan)),
        "the same lane through the Makefile (make's own defaults, artifacts by "
        f"session dir): {MAKE_TARGET} SESSION={shlex.quote(plan.session_path)} "
        f"QEMU_JOBS={plan.envelope.jobs}",
    ]


def run_completed(plan: emu.EmulationPlan) -> bool:
    """Has the TEST matrix for this plan FINISHED? Read-only; no docker, no spawn.

    This arms ``status``'s NO-RESULT synthesis and nothing else, so it has to be
    conservative in BOTH directions: claiming "finished" while rows are still
    booting accuses them of a missing verdict, and never claiming it leaves an
    ungraded row blank, reading as "still running" forever (the omission
    NO-RESULT exists to fix).

    The rule, from the two files the harness writes: the run left at least one
    verdict for this plan's labels, AND no planned label is still registered as a
    LIVE device. Verdicts without live guests is what the end of a matrix run
    looks like on disk; a run that never started leaves no verdicts at all and is
    therefore never accused.
    """
    if not qemu_tests.read_results(plan.work_dir, labels=plan.labels):
        return False
    live = {dev.label for dev in qemu_devices.discover_devices(plan.work_dir)
            if dev.is_running}
    return not (live & set(plan.labels))


def _cell(value) -> str:
    return "" if value is None or value == "" else str(value)


def results_table(st: emu.MeshStatus) -> tuple[list[str], list[list[str]]]:
    """(headers, rows) for the verdict table — one row per PLANNED label.

    The verdict cell is ``DeviceStatus.verdict`` verbatim, which is why a SUSPECT
    row reads SUSPECT here even though its result JSON says ``"status": "PASS"``:
    the grading happened once, in ``emulation._verdict_for``, and a face that
    re-read the raw status would quietly re-green the 2026-08-19 truncated-
    assertions defect. Counts come from the raw result so the operator can see
    the zero that made the row suspect.
    """
    headers = ["#", "device", "state", "verdict", "passed", "failed", "time"]
    rows: list[list[str]] = []
    for i, row in enumerate(st.rows, 1):
        res = row.result or {}
        duration = _cell(res.get("duration_s"))
        rows.append([str(i), row.label, row.state, row.verdict or "pending",
                     _cell(res.get("assertions_passed")),
                     _cell(res.get("assertions_failed")),
                     f"{duration}s" if duration else ""])
    return headers, rows


def legend_lines(st: emu.MeshStatus) -> list[str]:
    """One line per synthesized verdict actually present in this table.

    Rendered only when a row carries it: a legend for words that are not on
    screen is noise, and the three synthesized verdicts are precisely the ones an
    operator has never seen the runner print.
    """
    present = {row.verdict for row in st.rows}
    return [f"{verdict} = {why}" for verdict, why in VERDICT_LEGEND.items()
            if verdict in present]


def row_detail_lines(plan: emu.EmulationPlan, st: emu.MeshStatus,
                     label: str) -> list[str]:
    """One row's verdict WITH its reason, plus the two per-row copy-ready argv."""
    row = st.row(label)
    planned = plan.row(label)
    if row is None or planned is None:
        return [f"{label} is not a row of session {plan.session_name}."]
    lines = [
        f"device    {label}  ({planned.role} · {planned.platform} · {planned.arch})",
        f"artifact  {planned.basename}",
        f"state     {row.state}",
        f"verdict   {row.verdict or 'pending'} — {row.detail}",
    ]
    dev = row.device
    if dev is not None:
        lines.append(f"registry  container {dev.container or '-'} · booted "
                     f"{dev.started_at or '-'} · ssh port "
                     f"{dev.ssh_host_port or 'not published'}")
    lines += [
        "",
        "boot JUST this row and keep it up (artifacts and work dir pinned; "
        "--only-exact, so x86/be never drags be+gpu along):",
        "  " + shlex.join(emu.start_device_argv(plan, label)),
        "",
        "SELinux AVC workout for this row (issue #45) — boots it through its own "
        "launcher, drives the confined workloads, writes the narrowing report:",
        "  " + shlex.join(emu.avc_argv(plan, label)),
    ]
    return lines


class QemuScreen:
    """QEMU DEVICE TESTS: session picker -> planned rows + run hint + verdicts
    -> one row's detail. ``q`` walks BACK through those sub-states."""

    slug = "qemu"
    title = "QEMU device tests"
    wants_q = True                       # q navigates BACK through the sub-states

    def __init__(self):
        self._sub = "pick"               # pick | rows | detail
        self._sessions: list = []
        self._default = -1
        self._plan: emu.EmulationPlan | None = None
        self._detail = ""                # the label whose detail is open

    def enter(self, j) -> None:
        self._sub = "pick"
        self._plan = None
        self._detail = ""
        # only sessions that hold bootable images: an empty session cannot be
        # tested and is not offered (the mesh-emulation picker's rule).
        self._sessions = qemu_tests.discover_sessions(j.generator_dir,
                                                      only_with_images=True)
        self._default = default_session_index(self._sessions)

    def _status(self) -> emu.MeshStatus:
        assert self._plan is not None
        return emu.status(self._plan, run_completed=run_completed(self._plan))

    def lines(self, j) -> list[str]:  # noqa: ARG002 — screen-protocol signature
        if self._sub == "pick":
            out = ["Boot a prior build session's images as emulated devices and "
                   "assert they provisioned correctly — pick the session.", ""]
            if not self._sessions:
                out.append("  (no build session holds bootable images yet — "
                           "build a mesh first)")
            out += session_lines(self._sessions, self._default)
            out += ["", "(a NUMBER picks · Enter = the default, the newest "
                        "COMPLETE session · q = back to the menu)"]
            return out
        plan = self._plan
        assert plan is not None
        st = self._status()
        if self._sub == "detail" and self._detail:
            return row_detail_lines(plan, st, self._detail) + \
                ["", "(r = refresh · q = back to the row list)"]
        out = [f"session {plan.session_name} — {len(plan.rows)} planned "
               f"device(s); work dir {plan.work_dir}", ""]
        headers, rows = planned_table(plan)
        out += model.format_table(headers, rows)
        out += [""] + run_hint_lines(plan)
        out += ["", f"verdicts — {st.summary()}"]
        headers, rows = results_table(st)
        out += model.format_table(headers, rows)
        out += legend_lines(st)
        out += ["", "(a NUMBER opens a row's verdict detail + per-row hints · "
                    "r = refresh · q = back)"]
        return out

    def prompt(self, j) -> str:  # noqa: ARG002 — screen-protocol signature
        return f"qemu:{self._sub}> "

    def feed(self, j, line: str) -> None:
        low = line.lower()
        if self._sub == "pick":
            if low in ("q", "quit", "exit"):
                j.goto("mode")
                return
            if line == "":
                index = self._default
                if index < 0:
                    j.status = ("no build session holds bootable images yet — "
                                "build one first (q = back to the menu)")
                    return
            else:
                index = _index(line, len(self._sessions))
                if index is None:
                    j.status = f"no such session: {line!r}"
                    return
            self._plan = plan_for(j.generator_dir, self._sessions[index])
            self._sub = "rows"
            return
        if self._sub == "detail":
            if low in ("q", "quit", "exit"):
                self._sub = "rows"
            # r (or anything else) re-renders — the detail reads live state
            return
        # rows
        if low in ("q", "quit", "exit"):
            self._sub = "pick"
            return
        if low in ("r", "refresh", ""):
            return                        # lines() re-reads registry + results
        assert self._plan is not None
        row = _index(line, len(self._plan.rows))
        if row is None:
            j.status = f"no such device row: {line!r}"
            return
        self._detail = self._plan.labels[row]
        self._sub = "detail"


def _index(line: str, count: int) -> int | None:
    try:
        n = int(line.strip())
    except ValueError:
        return None
    return n - 1 if 1 <= n <= count else None

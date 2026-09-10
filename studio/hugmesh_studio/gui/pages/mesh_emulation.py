"""MeshEmulationPage — the DEPLOY face of emulation: a whole mesh, standing (#50).

This screen boots EVERY image of a chosen build session as a persistent
(``--keep-alive``) emulated device and then lets the operator drive it: per-device
status badges, ssh logins, the QEMU console, per-device and whole-mesh disk saves,
and the emulated mesh's web front door. Its sibling ``gui/pages/qemu.py`` is the
TEST face — boot, assert, power off — and after T3 the two are genuinely different
screens rather than two copies of one.

WHAT MOVED HERE IN T3, AND WHY IT BELONGS HERE
-----------------------------------------------
The device console lived on the TEST page because ``--keep-alive`` lived there. That
put a persistent-device console on the screen whose whole purpose is ephemeral runs,
and it grew a SECOND process lane and a SECOND spelling of the per-device Start
(the runner's newest-session guess, matched by SUBSTRING) beside this page's. Every
verb it owned is now here, once:

* the QMP console — pause / resume / status / power off, and ``reset`` behind an
  inline “confirm reset” tick because under ``-no-reboot`` (which every launcher
  passes: launch-pi.sh, launch-arm.sh, launch-x86.sh) a QMP ``system_reset`` does
  not reboot the guest, it ENDS it;
* per-device Save copy / Overwrite save, with the inline “confirm overwrite” tick
  as its consent, and the on-disk verification that reports what actually landed
  rather than what the exit status claimed;
* the desktop-terminal shell, with the copy-ready fallback.

And one thing that was on NEITHER page: the WHOLE-MESH save (issue #50 item 10). A
mesh save is 9.5-20.5 GB PER DEVICE, so it is previewed before it is run, always —
per-device budget, fleet total, KEYS presence, and the refusal (with its remedies)
when the filesystem cannot hold it. The preview is not a nicety: running out of
space mid-fleet leaves earlier saves landed, the current one a giant ``.partial``,
and on this workstation a full root filesystem has taken the live mesh down with it.

PLAN-DRIVEN, POLLED
-------------------
The row set is the PLAN, not the registry: a mesh row exists before its guest does,
so the operator sees what WILL boot (and can start it) instead of an empty table.
Reality is reconciled onto those rows by ``core.emulation.status()`` — the one place
that grades a verdict SUSPECT (PASS with zero assertions), STALE (a verdict from an
earlier boot) or NO-RESULT. A QTimer re-reads it while any row is still booting or
asserting, so a mesh coming up repaints itself instead of looking dead for the many
minutes an emulated boot takes.

THE WEB FRONT DOOR
------------------
The keep-alive runner publishes exactly one port per device: ssh, on loopback. The
web UI is reached THROUGH it — an ``ssh -N -L`` tunnel from the plan's local ui_port
to the guest's own :443. This is the operator's "cannot access the web console while
emulating devices" path, so the tunnel is not a side effect of a button: its state
is on the page, its reuse is stated when it is reused, and it is torn down when the
gateway stops, when the mesh stops, and when this page is left.

Modeless throughout: every refusal is inline (note + log), never a dialog — a modal
in page logic hangs the headless tests (the no-modals rule).
"""
from __future__ import annotations

import html
import os
import re
import shlex
import subprocess
import threading

from ..qt import Qt, QtCore, QtGui, QtWidgets
from .. import console
from ..styles import MUTED, WARN
from ...core import emulation, emulation_save, mesh_emulation, qemu_devices, qemu_tests
from ...core.local_stack_node import LocalStackNode
from . import _emulation_common as common
from ._mesh_monitor_widget import MeshMonitorSection
from ._scroll import scrollable
from ._widgets import label_finish_as_exit
from .localmesh import _MeshWorker

#: Device-table columns — symbolic, never hardcoded at a call site (progress.py's
#: rule), headers beside them so a column can never be labelled as its neighbour.
(_MCOL_LABEL, _MCOL_ROLE, _MCOL_ARCH, _MCOL_STATE, _MCOL_VERDICT, _MCOL_SECTIONS,
 _MCOL_SSH, _MCOL_USER, _MCOL_ACTIONS, _MCOL_QMP, _MCOL_SAVE,
 _MCOL_REPLICAS) = range(12)
_HEADERS = ("Device", "Role", "Arch", "State", "Verdict", "Sections", "SSH",
            "Login", "Actions", "QEMU", "Save disk", "Replicas (0/1)")

#: The Replicas column's tooltip, and the whole reason its ceiling is 1.
#:
#: The operator asked for the monitor's -/+/Apply on this table too, "so devices and
#: services scale here as well" (#336). It is wired to the runner and it is honest
#: about how far it can go: an emulated device is ONE guest per built image, and its
#: identity is allocated per PLAN ROW -- MAC and mesh IP from the row's index
#: (core/mesh_emulation._mesh_mac), the ssh port from the same place, the container
#: named after the label. A second instance of a row would collide with the first on
#: every one of those, and the runner has no replica verb to ask for one with. So the
#: counts that exist here are 0 and 1, Apply drives the SAME runner start/stop verbs
#: the buttons beside it drive, and the ceiling says so instead of offering a number
#: the runner would refuse. The SERVICES inside the mesh scale in the pod table below.
_REPLICAS_TIP = (
    "0 or 1 — an emulated device is one guest per built image. Its MAC, mesh IP, ssh "
    "port and container name are allocated per plan row, so a second copy of a row "
    "would collide with the first on all four, and the runner has no verb to ask for "
    "one. THIS COLUMN ADDS NO NEW CAPABILITY: Apply(1) runs the byte-identical runner "
    "command the Start button in Actions runs, and Apply(0) the Stop button's. It is "
    "here because the scale control was asked for on this table too (#336), and it "
    "shows the count rather than hiding it behind two buttons. To scale the SERVICES "
    "the mesh runs — the thing that genuinely has a replica count — use the Replicas "
    "column in the running-mesh table below.")
_REPLICAS_APPLY_TIP = ("Start this device (1) or stop it (0) through the runner. "
                       "Enabled when the target differs from what is running and no "
                       "other verb owns the page.")

#: Section badge colours (the #50 per-section dropdown). Distinct from the verdict
#: colours in _emulation_common: these grade a SECTION (boot/ssh/provision/web),
#: those grade the whole row's assertion verdict.
_SECTION_COLOURS = {
    mesh_emulation.ST_OK: common.GREEN,
    mesh_emulation.ST_FAILED: common.RED,
    mesh_emulation.ST_PENDING: WARN,
}

#: The dropdown row that means "log in as a wheel user, THEN sudo -i". It is not a
#: login and must never be sent as one: the guest's sshd ships PermitRootLogin no and
#: tests/qemu/assertions.sh checks that it still does, so root is reached through a
#: wheel user or not at all. The sentinel is unspellable as a unix login, so it can
#: never collide with a real account coming out of available_logins().
_ROOT_ROW = "\x00root-via-sudo"

#: How each QMP verb reads on its button. A LOOKUP over qemu_devices.QMP_COMMANDS,
#: never a second list of verbs: that tuple decides which buttons exist and in what
#: order, and a verb added there grows a button here under a title-cased fallback
#: instead of vanishing.
_QMP_LABELS = {
    "pause": "Pause",
    "resume": "Resume",
    # Deliberately NOT the bare word "Reset". Every launcher this harness uses runs
    # qemu with -no-reboot (tests/qemu/launch-pi.sh, launch-arm.sh and launch-x86.sh
    # each pass it), and under that flag a QMP system_reset does not reboot the
    # guest: qemu reports a SHUTDOWN with reason host-qmp-system-reset and the
    # process exits. A button labelled "Reset" would therefore destroy the device it
    # appears to restart, so the label says what the click actually does.
    "reset": "Reset (ends guest)",
    "powerdown": "Power off",
    "status": "Status",
}

#: Verbs after which the guest is GONE, so the row's own Start is what brings it
#: back. Presenting these as ordinary controls is what the label above avoids.
_QMP_ENDS_GUEST = frozenset({"reset", "powerdown"})

#: The verb that needs an INLINE confirmation tick before it can fire. Power off
#: ends the guest too, but it is the ORDERLY shutdown an operator means when they
#: say "shut it down"; reset is the one whose name promises the opposite of what
#: it does.
_QMP_ARMED = "reset"

_QMP_TOOLTIPS = {
    "pause": "Freeze the guest's virtual CPUs. The container, the published ssh "
             "port and the guest's memory all stay as they are; Resume continues "
             "it from exactly there.",
    "resume": "Continue a paused guest.",
    "reset": "DESTRUCTIVE — this ENDS the device. The launchers run qemu with "
             "-no-reboot, and under that flag a QMP system_reset makes the "
             "emulator shut down and exit instead of rebooting: qemu reports the "
             "shutdown with reason host-qmp-system-reset. Nothing is lost that a "
             "disposable overlay was not going to lose anyway, but the row stops "
             "and has to be Started (a full boot) to come back. Tick "
             "“confirm reset” beside it first.",
    "powerdown": "Press the guest's ACPI power button: an ORDERLY shutdown from "
                 "inside. The device ends — use Start to boot it again.",
    "status": "Ask the emulator what it thinks the guest is doing. Reads only; "
              "changes nothing — and it is how this table re-syncs its State "
              "column with a device someone paused from a terminal.",
}

#: The emulator's own run-state, lifted out of what ``--qmp LABEL status`` printed.
#: The runner's QMP client prints QEMU's reply line VERBATIM, and query-status
#: answers ``{"return": {"status": "running", "running": true}}`` — checked against
#: qemu 10.2.3, which reported "running" on a fresh boot, "paused" after a QMP stop
#: and "running" again after cont. Nothing is inferred when this does not match: an
#: unparsed line leaves the row's run-state UNKNOWN, which the State column then
#: says rather than guessing "running".
_QMP_STATUS_RE = re.compile(r'"status"\s*:\s*"([a-z-]+)"')
_RUN_PAUSED, _RUN_RUNNING = "paused", "running"

#: The two save actions, and the only two. ``copy`` writes a NEW file and leaves
#: every previous save alone; ``overwrite`` re-saves onto the device's most recent
#: save, which destroys it. Folding an overlay back into the golden build image
#: (QMP block-commit) is not a third mode and not a button: measured on qemu 10.2.3
#: it mutates the shared .img in place and drops the overlay from the chain, so
#: every later write in the session would land on the image every other run boots
#: from.
_SAVE_COPY, _SAVE_OVERWRITE = "copy", "overwrite"

#: How often the table re-reads reality while something is still coming up. Slow
#: enough that the runner's ``--devices`` probe is not a treadmill, fast enough that
#: a device finishing its boot shows up before the operator reaches for Refresh.
_POLL_MS = 4000

#: Row states that mean "this is still happening" — the poll runs while any planned
#: row is in one of them (or while a verb of this page's own is in flight).
_UNSETTLED_STATES = frozenset({emulation.STATE_BOOTING, emulation.STATE_ASSERTIONS})


class _Row:
    """The live widgets and the reconciled truth of ONE mesh-device row.

    QTableWidget only hands cell widgets back by (row, column), and this page
    re-arms a dozen controls per row on every refresh — and now on a timer — so the
    handles are kept rather than looked up by column number at each call site.
    """

    def __init__(self, planned, user, sections, ssh_btn, start, stop, qmp, arm_reset,
                 save, overwrite, arm_save, replicas=None):
        self.planned = planned          # mesh_emulation.PlannedDevice
        self.status = None              # emulation.DeviceStatus | None
        self.user = user                # QComboBox
        self.sections = sections        # QComboBox (badge list)
        self.ssh_btn = ssh_btn
        self.start = start
        self.stop = stop
        self.qmp = qmp                  # {verb: QPushButton}
        self.arm_reset = arm_reset      # QCheckBox guarding the reset verb
        self.save = save
        self.overwrite = overwrite
        self.arm_save = arm_save        # QCheckBox guarding the overwrite
        #: The -/+/Apply strip (_emulation_common.ReplicaStrip), 0..1. Defaulted so a
        #: caller that predates the column still builds a row.
        self.replicas = replicas
        #: This device's existing saves, newest first, as of the last refresh.
        #: Cached rather than re-scanned inside the arming pass, which runs on every
        #: poll tick, while the set of files can only change when a save finishes.
        self.saves: list[str] = []
        #: What the EMULATOR last SAID about this guest's vCPUs — never what this
        #: page assumes. "" for not known.
        self.run_state = ""

    @property
    def label(self) -> str:
        return self.planned.label

    @property
    def dev(self):
        """The live registry record, or None when the row is only planned."""
        return self.status.device if self.status is not None else None

    @property
    def up(self) -> bool:
        dev = self.dev
        return dev is not None and dev.is_running

    @property
    def paused(self) -> bool:
        return self.run_state == _RUN_PAUSED

    @property
    def settled(self) -> bool:
        """Whether this row has stopped changing on its own.

        A BOOTING or ASSERTIONS row is mid-flight by definition — that is what the
        poll is for. Everything else (planned, running, stopped) only changes when
        somebody does something, and polling it forever would mean a permanent
        ``docker ps`` treadmill behind an idle window.
        """
        return (self.status is None
                or self.status.state not in _UNSETTLED_STATES)

    @property
    def can_shell(self) -> bool:
        """Whether a login is even expressible for this row — four conditions.

        A device that is not running has no sshd behind the port. A record with
        ``ssh_host_port: 0`` published no port at all, and ``ssh_argv`` emits that 0
        verbatim on purpose (there is no fallback to 22, because on this host
        127.0.0.1:22 is the operator's OWN workstation sshd). A record can carry a
        published port and an empty ``ssh_key``, and ``ssh -i ''`` does not fall back
        to the agent — it fails on an unreadable identity file. And a PAUSED guest
        passes every other check while its vCPUs are frozen, so sshd never answers
        and the terminal that opened would sit there until it timed out.
        """
        dev = self.dev
        return bool(self.up and not self.paused and dev.ssh_host_port > 0
                    and dev.ssh_key)

    @property
    def can_save(self) -> bool:
        """Whether a save is expressible for this row.

        RUNNING is not a UI nicety: while QEMU holds the overlay it holds a write
        LOCK on it, so nothing outside that process can read the disk (measured on
        qemu 10.2.3 — ``qemu-img convert`` on a live overlay fails with
        `Failed to get shared "write" lock`, and so does ``qemu-img commit``). The
        save therefore happens INSIDE the running emulator as a QMP block job, and a
        stopped row has no emulator to ask. The rest of the rule is deferred to
        ``qemu_devices.can_save``, which also demands a container name and a QMP
        socket — two predicates that disagree about the same question are how a
        button comes to promise something the thing behind it refuses.
        """
        return bool(self.up and qemu_devices.can_save(self.dev))

    @property
    def overwrite_target(self) -> str:
        """The save that Overwrite would destroy, or "" when there is none yet."""
        return self.saves[0] if self.saves else ""


class MeshEmulationPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Mesh emulation")
        self.setSubTitle(
            "Boot every image of a finished build session as persistent emulated "
            "devices and drive the whole mesh locally — status per device, ssh "
            "logins, the QEMU console, disk saves, and the mesh's web front door.")
        # Terminal side-flow: the final button does nothing but close the Studio (the
        # emulated devices keep running — the verbs on this page are what start and
        # stop them), so it says Exit (_widgets.label_finish_as_exit).
        label_finish_as_exit(self)
        self._running = False
        self._cancel = threading.Event()
        #: Whether the operator pressed Cancel for the work now in flight. Distinct
        #: from ``_cancel``, which emulation.spawn sets itself on every exit.
        self._cancel_pressed = False
        self._docker_ok = False
        self.worker: _MeshWorker | None = None
        self._sessions: list[qemu_tests.BuildSession] = []
        #: The DEPLOY plan. ``epoch=""`` on purpose: this page routinely inspects a
        #: mesh some earlier process started, so a verdict is graded against the
        #: DEVICE's own boot stamp rather than against "when was this page opened".
        self.plan: emulation.EmulationPlan | None = None
        self.status: emulation.MeshStatus | None = None
        self._rows: list[_Row] = []
        #: label -> the detached ssh tunnel process. Tracked (not fire-and-forget)
        #: because a tunnel outliving the device it points at is a port that answers
        #: and then hangs — see _close_tunnels for every place they are torn down.
        self._tunnels: dict[str, subprocess.Popen] = {}
        #: The label whose ``--qmp … status`` output is being read right now, so a
        #: status line is attributed to the row that asked for it.
        self._status_watch = ""
        #: The whole-mesh save preview, and the save-set name it named. Pinned
        #: between preview and run: minting a fresh ``mesh-<stamp>`` at run time
        #: would write into a different directory than the one just previewed.
        self._mesh_save_preview: dict | None = None
        #: Called on the GUI thread when the verb in flight finishes, with
        #: (ok, cancelled); may return an inline note to show after the repaint.
        self._verb_finished = None

        lay = scrollable(self)

        # ── docker availability, probed OFF the GUI thread ───────────────────────
        self.docker_note = QtWidgets.QLabel()
        self.docker_note.setWordWrap(True)
        self.docker_note.setTextFormat(Qt.TextFormat.RichText)
        self.docker_note.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextBrowserInteraction)
        lay.addWidget(self.docker_note)
        self.docker_probe = common.DockerProbe(self)
        self.docker_probe.answered.connect(self._docker_answered)

        # ── which prior session's images (the ask: it FIRST asks this) ──────────
        self.session_box = QtWidgets.QGroupBox("Which build session's images?")
        sb = QtWidgets.QVBoxLayout(self.session_box)
        self.session_combo = QtWidgets.QComboBox()
        self.session_combo.setToolTip(
            "Prior build sessions holding at least one bootable image, newest "
            "first. The whole mesh is planned from the one you pick — every image "
            "it holds becomes one emulated device. A build that did not finish its "
            "fleet is listed and MARKED; the preselected session is the newest one "
            "whose images are all present.")
        self.session_combo.currentIndexChanged.connect(self._session_changed)
        sb.addWidget(self.session_combo)
        self.session_note = QtWidgets.QLabel()
        self.session_note.setWordWrap(True)
        self.session_note.setTextFormat(Qt.TextFormat.RichText)
        sb.addWidget(self.session_note)
        self.plan_label = QtWidgets.QLabel()
        self.plan_label.setWordWrap(True)
        self.plan_label.setTextFormat(Qt.TextFormat.RichText)
        sb.addWidget(self.plan_label)
        lay.addWidget(self.session_box)

        # ── mesh-wide actions ────────────────────────────────────────────────────
        btns = QtWidgets.QHBoxLayout()
        self.start_btn = QtWidgets.QPushButton("Start mesh")
        self.start_btn.setToolTip(
            "Boot every planned device through the containerized runner with "
            "--keep-alive: the guests stay up after their assertions and register "
            "themselves in the table below. Boots are FULL emulated boots and can "
            "take many minutes each — the table repaints itself as they land.")
        self.start_btn.clicked.connect(self._start_mesh)
        self.stop_btn = QtWidgets.QPushButton("Stop all")
        self.stop_btn.setToolTip(
            "Stop every registered device (--stop-all-devices) and close any web "
            "tunnel this page opened.")
        self.stop_btn.clicked.connect(self._stop_mesh)
        self.refresh_btn = QtWidgets.QPushButton("Refresh")
        self.refresh_btn.setToolTip(
            "Re-read the device registry and the assertion verdicts through "
            "core.emulation.status(). Reads only — starts nothing, stops nothing.")
        self.refresh_btn.clicked.connect(self._refresh_reality)
        self.cancel_btn = QtWidgets.QPushButton("Cancel")
        self.cancel_btn.setEnabled(False)
        self.cancel_btn.setToolTip(
            "Terminate the runner invocation now in flight — process group and "
            "all, docker children included.")
        self.cancel_btn.clicked.connect(self._cancel_verb)
        for b in (self.start_btn, self.stop_btn, self.refresh_btn, self.cancel_btn):
            btns.addWidget(b)
        btns.addStretch(1)
        lay.addLayout(btns)

        # ── the web front door, and the tunnel that IS it ────────────────────────
        web = QtWidgets.QHBoxLayout()
        self.web_btn = QtWidgets.QPushButton("Open web UI")
        self.web_btn.clicked.connect(self._open_web_ui)
        web.addWidget(self.web_btn)
        self.tunnel_close_btn = QtWidgets.QPushButton("Close tunnel")
        self.tunnel_close_btn.setToolTip(
            "Terminate the ssh tunnel this page opened. The browser tab stops "
            "working; the device is untouched.")
        self.tunnel_close_btn.clicked.connect(
            lambda: self._close_tunnels("closed from this page"))
        web.addWidget(self.tunnel_close_btn)
        self.web_note = QtWidgets.QLabel()
        self.web_note.setWordWrap(True)
        self.web_note.setTextFormat(Qt.TextFormat.RichText)
        # Selectable: the URL and the tunnel command are for copying, not retyping.
        self.web_note.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse)
        web.addWidget(self.web_note, 1)
        lay.addLayout(web)

        self.tunnel_note = QtWidgets.QLabel()
        self.tunnel_note.setWordWrap(True)
        self.tunnel_note.setTextFormat(Qt.TextFormat.RichText)
        self.tunnel_note.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse)
        lay.addWidget(self.tunnel_note)

        # ── the device table ─────────────────────────────────────────────────────
        self.devices = common.make_table(_HEADERS, min_height=200)
        # The ceiling is in the header text and the whole disclosure is on the header
        # item: a tooltip only on the cell widget is unreachable until a session is
        # picked and rows exist, which is exactly when an operator wonders what the
        # column is for.
        _rep_head = self.devices.horizontalHeaderItem(_MCOL_REPLICAS)
        if _rep_head is not None:
            _rep_head.setToolTip(_REPLICAS_TIP)
        lay.addWidget(self.devices)

        # ── the running mesh's pods and containers (#336) ────────────────────────
        # A DIFFERENT mesh from the table above, and the note says so: the rows above
        # are emulated QEMU guests booted from this session's images, and this section
        # is the docker compose project and the kind cluster running on THIS
        # workstation. Both are "the mesh" to an operator standing in front of them,
        # and having only one of them on screen is what the request was about.
        #
        # Collapsed and greyed until something is up, exactly as on the local-mesh page
        # (PR #291's contract) — MeshMonitorSection owns that gate, the 10 s poll and
        # the off-thread read, so this page holds no monitor logic of its own.
        self.monitor = MeshMonitorSection(
            self, self.wiz.generator_dir, self._monitor_node,
            title="Running mesh — pods, containers and their addresses",
            scaling=True,
            what=("This reads the docker compose project and the kind cluster on THIS "
                  "workstation — not the emulated guests in the table above."))
        # `make view` is the local-mesh page's session to own; this mount would be a
        # second launcher for one process-owner guard.
        self.monitor.monitor.hide_view_controls(
            "Open the browser door from the local-mesh page — it owns the `make view` "
            "session, and two launchers would fight over one session lock.")
        self.monitor.mount(lay)

        # ── the whole-mesh save: preview FIRST, always ───────────────────────────
        self.save_box = QtWidgets.QGroupBox("Save the whole mesh")
        sv = QtWidgets.QVBoxLayout(self.save_box)
        save_row = QtWidgets.QHBoxLayout()
        self.mesh_save_btn = QtWidgets.QPushButton("Save mesh")
        self.mesh_save_btn.setToolTip(
            "Save every planned device's disk and its KEYS set into ONE save-set "
            "directory. The FIRST press only PREVIEWS: what would be written, what "
            "it would cost, and whether it fits. Nothing is paused or copied until "
            "you tick “confirm mesh save” and press again — a mesh save is "
            "9.5-20.5 GB per device, and running out mid-fleet is the worst shape "
            "of failure available here.")
        self.mesh_save_btn.clicked.connect(self._save_mesh_clicked)
        save_row.addWidget(self.mesh_save_btn)
        self.mesh_save_arm = QtWidgets.QCheckBox("confirm mesh save")
        self.mesh_save_arm.setToolTip(
            "Confirm the mesh save — this tick is CONSENT, not an architecture "
            "choice (each device is saved for the architecture its own image was "
            "built for; see the Arch column). Disabled until a preview exists that "
            "FITS; cleared again after every run, because this is consent for one "
            "save, not a mode the page stays in.")
        self.mesh_save_arm.setEnabled(False)
        self.mesh_save_arm.toggled.connect(lambda *_: self._sync_controls())
        save_row.addWidget(self.mesh_save_arm)
        save_row.addStretch(1)
        sv.addLayout(save_row)
        self.mesh_save_note = QtWidgets.QLabel()
        self.mesh_save_note.setWordWrap(True)
        self.mesh_save_note.setTextFormat(Qt.TextFormat.RichText)
        self.mesh_save_note.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse)
        sv.addWidget(self.mesh_save_note)
        lay.addWidget(self.save_box)

        # INLINE note (the no-modals rule): refusals, copy-ready commands, results.
        self.note = QtWidgets.QLabel()
        self.note.setWordWrap(True)
        self.note.setTextFormat(Qt.TextFormat.RichText)
        self.note.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse)
        lay.addWidget(self.note)

        # ── streamed log ─────────────────────────────────────────────────────────
        self.log = console.attach(QtWidgets.QPlainTextEdit())
        self.log.setReadOnly(True)
        self.log.setMinimumHeight(160)
        lay.addWidget(self.log)

        # ── the poll ─────────────────────────────────────────────────────────────
        self.poll = QtCore.QTimer(self)
        self.poll.setInterval(_POLL_MS)
        self.poll.timeout.connect(self._poll_tick)

        # Closing the Studio is the third way to leave this page, and the only one
        # cleanupPage() never sees (Qt calls it on Back, not on Exit/close). A
        # tunnel that survives the window is a bound loopback port with nothing
        # behind it, which the NEXT session would find taken.
        finished = getattr(wiz, "finished", None)
        if finished is not None:
            finished.connect(lambda *_: self._close_tunnels("the Studio is closing"))

    # ── wizard-flow contract (mirrors QemuPage) ─────────────────────────────────
    def nextId(self) -> int:
        return -1                       # terminal side-flow: nothing to build next

    def applies_to(self, cfg) -> bool:  # noqa: ARG002 — the hook's fixed signature
        return bool(getattr(self.wiz, "meshemu_selected", False))

    def isComplete(self) -> bool:
        # Leaving mid-run would orphan the worker's signals into a destroyed page.
        return not self._running

    def initializePage(self):
        self._refresh_docker_note()
        self._reload_sessions()

    def cleanupPage(self):
        """Leaving the page: stop polling and take the tunnels with us.

        A tunnel is a detached ssh that would otherwise outlive the screen that
        opened it, holding a loopback port for a mesh nobody is watching — and the
        NEXT visit would find that port taken and reuse a pipe to a device that has
        since been stopped. The devices themselves are deliberately untouched: this
        page exists to leave a mesh RUNNING.
        """
        self.poll.stop()
        self.monitor.shutdown()
        self._close_tunnels("left the mesh emulation page")
        super().cleanupPage()

    def hideEvent(self, event):
        """Off screen, off the clock.

        The poll shells out to the runner's ``--devices`` probe every few seconds;
        doing that behind a page nobody is looking at is a treadmill, and a timer
        that outlives its page is a slot firing into a half-destroyed widget tree.
        ``showEvent`` restarts it if there is still something to watch, so this
        costs nothing but the ticks that were never worth taking.
        """
        self.poll.stop()
        self.monitor.stop()
        super().hideEvent(event)

    def showEvent(self, event):
        super().showEvent(event)
        self._sync_poll()
        self.monitor.start()

    # ── the running-mesh monitor's node ─────────────────────────────────────────
    def _monitor_node(self):
        """The stack node the monitor reads both lanes through, built once.

        Deliberately a DEFAULT LocalStackNode: the monitor only reads (compose ps,
        kubectl get, docker inspect), and this page has no local-mesh configuration to
        thread in — the ports and the compose file are the ones the Makefile uses,
        which is what the running mesh was started with.
        """
        node = getattr(self, "_monitor_stack_node", None)
        if node is None:
            node = LocalStackNode(self.wiz.generator_dir)
            self._monitor_stack_node = node
        return node

    # ── docker ──────────────────────────────────────────────────────────────────
    def _refresh_docker_note(self):
        self._docker_paint(self.docker_probe.answer)
        self.docker_probe.start()

    def _docker_answered(self, ok: bool, why: str):
        self._docker_paint((bool(ok), str(why)))

    def _docker_paint(self, answer):
        self.docker_note.setText(common.docker_note_html(answer))
        self._docker_ok = bool(answer and answer[0])
        self._sync_controls()

    # ── population ──────────────────────────────────────────────────────────────
    def _reload_sessions(self):
        self._sessions = qemu_tests.discover_sessions(self.wiz.generator_dir)
        common.populate_sessions(self.session_combo, self._sessions)
        if not self._sessions:
            self.plan_label.setText(
                f'<span style="color:{WARN}">No build session under out/sessions/ '
                "holds a bootable image yet.</span> Build a mesh first, then come "
                "back — this screen emulates images that already exist.")
        self._session_changed()

    def _current_session(self) -> qemu_tests.BuildSession | None:
        idx = self.session_combo.currentIndex()
        if idx < 0 or idx >= len(self._sessions):
            return None
        return self._sessions[idx]

    def _session_changed(self, *_):
        session = self._current_session()
        self.session_note.setText(common.partial_note(session))
        # A different session is a different mesh; a preview of the old one must not
        # survive to be armed against the new one.
        self._mesh_save_preview = None
        self.mesh_save_arm.setChecked(False)
        self.mesh_save_note.setText("")
        if session is None:
            self.plan = None
            self.status = None
            self._rows = []
            self.devices.setRowCount(0)
            self._sync_controls()
            return
        try:
            # epoch="" — see the attribute's own note: this page inspects meshes it
            # did not necessarily start.
            self.plan = emulation.plan(self.wiz.generator_dir, session,
                                       emulation.EmulationMode.DEPLOY, epoch="")
        except ValueError as exc:
            self.plan = None
            self._rows = []
            self.devices.setRowCount(0)
            self.plan_label.setText(
                f'<span style="color:{WARN}">This session cannot be planned: '
                f"{exc}</span>")
            self._sync_controls()
            return
        mesh = self.plan.mesh
        gw = mesh.gateway if mesh else None
        self.plan_label.setText(
            f"<b>{len(self.plan.rows)} emulated device(s)</b> planned. Front "
            f"door: <tt>{gw.label if gw else '?'}</tt> &rarr; "
            f"<tt>{self.plan.front_door}</tt> (via an ssh tunnel over the device's "
            "published port).")
        self._build_table()
        self._refresh_reality()

    def _build_table(self):
        """One row per PLANNED device — the plan is the row set, reality only
        colours it. A mesh row exists before its guest does, so the operator sees
        what WILL boot (and can start it) rather than staring at an empty table."""
        assert self.plan is not None and self.plan.mesh is not None
        self._rows = []
        planned_devices = self.plan.mesh.devices
        self.devices.setRowCount(len(planned_devices))
        for r, planned in enumerate(planned_devices):
            for col, text in {_MCOL_LABEL: planned.label, _MCOL_ROLE: planned.role,
                              _MCOL_ARCH: planned.arch}.items():
                common.set_cell(self.devices, r, col, str(text))
            self.devices.item(r, _MCOL_LABEL).setToolTip(
                f"image {os.path.basename(planned.image)}\n"
                f"planned ssh 127.0.0.1:{planned.ssh_port}\n"
                f"planned mesh identity {planned.mac} / {planned.ip}\n"
                f"USB KEYS stick {planned.keys_image}")
            for col in (_MCOL_STATE, _MCOL_VERDICT, _MCOL_SSH):
                common.set_cell(self.devices, r, col, "")

            sections = QtWidgets.QComboBox()
            sections.setToolTip(
                "Per-section status: boot, ssh, provisioning (the assertion "
                "verdict) and the web front door. A dropdown, not a control — "
                "picking an entry changes nothing.")
            self.devices.setCellWidget(r, _MCOL_SECTIONS, sections)

            user = QtWidgets.QComboBox()
            user.setToolTip(
                "Logins that exist ON THIS GUEST once it is up, labelled with the "
                "domain they were configured for; “root (via sudo -i)” elevates "
                "through the wheel login because the guest refuses root ssh.")
            self.devices.setCellWidget(r, _MCOL_USER, user)

            ssh_btn = QtWidgets.QPushButton("SSH")
            ssh_btn.clicked.connect(lambda _=False, i=r: self._open_shell(i))
            start = QtWidgets.QPushButton("Start")
            start.clicked.connect(lambda _=False, i=r: self._start_device(i))
            stop = QtWidgets.QPushButton("Stop")
            stop.setToolTip("Stop this device through the runner, which owns the "
                            "container name. The row stays listed — it is planned.")
            stop.clicked.connect(lambda _=False, i=r: self._stop_device(i))
            self.devices.setCellWidget(
                r, _MCOL_ACTIONS, common.button_strip(start, stop, ssh_btn))

            # ── the QMP console — BUILT FROM the exported verb tuple ────────────
            qmp: dict[str, QtWidgets.QPushButton] = {}
            for command in qemu_devices.QMP_COMMANDS:
                b = QtWidgets.QPushButton(
                    _QMP_LABELS.get(command, command.capitalize()))
                b.setToolTip(_QMP_TOOLTIPS.get(
                    command, f"Send the QMP verb “{command}” to this guest's "
                             "monitor socket, through the runner."))
                if command in _QMP_ENDS_GUEST:
                    b.setStyleSheet(f"color: {WARN};")
                b.clicked.connect(
                    lambda _=False, i=r, c=command: self._device_qmp(i, c))
                qmp[command] = b
            arm_reset = QtWidgets.QCheckBox("confirm reset")
            arm_reset.setChecked(False)
            # Arming is what SHOWS the warning, not clicking: the operator must be
            # able to read what "reset" does on this harness before the destructive
            # button lights up, not discover it from the row that stopped.
            arm_reset.toggled.connect(lambda on, i=r: self._reset_armed(i, on))
            self.devices.setCellWidget(
                r, _MCOL_QMP, common.button_strip(*qmp.values(), arm_reset))

            # ── save: the safe copy, and the destructive one behind a tick ──────
            save = QtWidgets.QPushButton("Save copy")
            overwrite = QtWidgets.QPushButton("Overwrite save")
            overwrite.setStyleSheet(f"color: {WARN};")
            # Default OFF, and off again after every save: arming is per-click
            # consent, not a mode the row stays in.
            arm_save = QtWidgets.QCheckBox("confirm overwrite")
            arm_save.setChecked(False)
            arm_save.toggled.connect(lambda *_: self._sync_controls())
            save.clicked.connect(
                lambda _=False, i=r: self._device_save(i, _SAVE_COPY))
            overwrite.clicked.connect(
                lambda _=False, i=r: self._device_save(i, _SAVE_OVERWRITE))
            self.devices.setCellWidget(
                r, _MCOL_SAVE, common.button_strip(save, overwrite, arm_save))

            # ── replicas: 0 or 1, through the runner (see _REPLICAS_TIP) ────────
            replicas = common.ReplicaStrip(
                planned.label, ceiling=1,
                what=f"the emulated device {planned.label}",
                minus_tip="Target 0 — stop this device through the runner.",
                plus_tip="Target 1 — boot this device through the runner.",
                apply_tip=_REPLICAS_APPLY_TIP)
            replicas.widget.setToolTip(_REPLICAS_TIP)
            replicas.minus.clicked.connect(
                lambda _=False, i=r: self._bump_replicas(i, -1))
            replicas.plus.clicked.connect(
                lambda _=False, i=r: self._bump_replicas(i, +1))
            replicas.apply.clicked.connect(
                lambda _=False, i=r: self._apply_replicas(i))
            self.devices.setCellWidget(r, _MCOL_REPLICAS, replicas.widget)

            self._rows.append(_Row(planned, user, sections, ssh_btn, start, stop,
                                   qmp, arm_reset, save, overwrite, arm_save,
                                   replicas))
        self.devices.resizeColumnsToContents()

    # ── plan vs reality ─────────────────────────────────────────────────────────
    def _refresh_reality(self, *_):
        """Re-read reality through ``emulation.status()`` and repaint every row.

        The PLAN never changes here — only which of its devices are real right now,
        and how their verdicts grade. Rows are patched (not rebuilt) because the row
        set IS the plan, and because this now runs on a timer: rebuilding would throw
        away the operator's selection every few seconds.
        """
        if self.plan is None:
            self._sync_controls()
            return
        self.status = emulation.status(self.plan)
        live = {row.label: row for row in self.status.rows}
        work = self.plan.work_dir
        for i, row in enumerate(self._rows):
            row.status = live.get(row.label)
            # A run-state belongs to a GUEST, and a label outlives its guests: a
            # device that went away must not hand "paused" to the one that replaces
            # it and grey its own Pause button.
            if not row.up:
                row.run_state = ""
            row.saves = _saved_copies(work, row.dev)
            self._paint_row(i, row)
        self._sync_controls()
        self._sync_poll()

    def _poll_tick(self):
        """One timed re-read. Skipped while a verb owns the page: the verb's own
        completion re-reads anyway, and a poll landing mid-stream would repaint from
        a registry the runner is still writing."""
        if self._running:
            return
        self._refresh_reality()

    def _sync_poll(self):
        """Poll only while something is still moving — see ``_Row.settled``."""
        want = self.plan is not None and (
            self._running or any(not row.settled for row in self._rows))
        if want and not self.poll.isActive():
            self.poll.start()
        elif not want and self.poll.isActive():
            self.poll.stop()

    def _paint_row(self, r: int, row: _Row):
        st = row.status
        state_text, state_tip, state_colour = self._state_cell(row)
        common.set_cell(self.devices, r, _MCOL_STATE, state_text,
                        tooltip=state_tip, colour=state_colour)

        verdict = st.verdict if st is not None else ""
        common.set_cell(
            self.devices, r, _MCOL_VERDICT, common.verdict_text(verdict),
            colour=common.verdict_colour(verdict),
            tooltip=common.VERDICT_TOOLTIPS.get(
                verdict, st.detail if st is not None else ""))

        dev = row.dev
        where = (f"{qemu_devices.SSH_HOST}:{dev.ssh_host_port}"
                 if dev is not None and dev.ssh_host_port > 0
                 else f"planned :{row.planned.ssh_port}")
        common.set_cell(
            self.devices, r, _MCOL_SSH, where,
            tooltip=("The registry's published port." if dev is not None else
                     "The plan's port — the registry record is authoritative once "
                     "the device is up."))

        gateway = (self.plan is not None
                   and row.label == self.plan.gateway_label)
        stats = mesh_emulation.section_statuses(
            row.planned, dev, st.result if st is not None else None,
            gateway=gateway)
        row.sections.blockSignals(True)
        row.sections.clear()
        for section in mesh_emulation.SECTIONS:
            status, detail = stats[section]
            row.sections.addItem(f"{section}: {status}", section)
            idx = row.sections.count() - 1
            row.sections.setItemData(idx, detail, Qt.ItemDataRole.ToolTipRole)
            colour = _SECTION_COLOURS.get(status)
            if colour:
                row.sections.setItemData(idx, QtGui.QBrush(QtGui.QColor(colour)),
                                         Qt.ItemDataRole.ForegroundRole)
        row.sections.blockSignals(False)

        # Preserve the operator's login choice across a repaint — the poll runs
        # every few seconds and resetting the dropdown under the cursor would make
        # the SSH button unusable on a booting mesh.
        want = row.user.currentData()
        row.user.blockSignals(True)
        row.user.clear()
        if dev is not None:
            for login, display in qemu_devices.available_logins(
                    dev, self.wiz.cfg.users):
                row.user.addItem(display, login)
            # Root last and never pre-selected — one-click ssh must not hand out a
            # root prompt the operator did not pick.
            row.user.addItem("root (via sudo -i)", _ROOT_ROW)
            for i in range(row.user.count()):
                if row.user.itemData(i) == want:
                    row.user.setCurrentIndex(i)
                    break
        row.user.blockSignals(False)

    def _state_cell(self, row: _Row) -> tuple[str, str, str]:
        """(text, tooltip, colour) for the State column — registry AND emulator.

        Two different questions hide behind one word here, and conflating them is
        what makes a paused device indistinguishable from a working one:

        * the reconciled state (PLANNED/BOOTING/RUNNING/ASSERTIONS/STOPPED) answers
          "is this device's container up", and comes from core.emulation.status();
        * the emulator's run-state answers "are the guest's vCPUs executing", and
          pausing is a QMP verb the entrypoint never sees — so a guest frozen by the
          Pause button on this very row keeps its record at "running" forever.

        So a paused row does NOT say RUNNING. It says PAUSED, in the warning colour,
        and the tooltip explains that the container really is up. When the emulator
        has not been asked, the run-state is unknown and the cell says only what the
        registry knows — with a tooltip that says Status is how to find out, rather
        than implying the CPUs were checked.
        """
        st = row.status
        state = st.state if st is not None else emulation.STATE_PLANNED
        if not row.up:
            return (state, f"Reconciled from {self.status.source if self.status else 'the plan'}: "
                           f"this device is not running.",
                    common.state_colour(state))
        known = row.run_state
        if not known:
            return (state,
                    f"State {state} — that is the CONTAINER, not the guest's CPUs. "
                    "Nothing has asked this emulator whether it is paused; press "
                    "Status to find out.",
                    common.state_colour(state))
        if known == _RUN_RUNNING:
            return (state,
                    f"State {state}. The emulator last reported its vCPUs RUNNING.",
                    common.state_colour(state))
        if known == _RUN_PAUSED:
            return ("PAUSED",
                    "The guest's vCPUs are FROZEN. Its container is up and its ssh "
                    "port is still published (the record still says "
                    f"“{state}”, because pausing is a QMP verb the entrypoint never "
                    "sees), but nothing inside the guest is executing — ssh will "
                    "not answer until Resume continues it from exactly here.",
                    WARN)
        # Everything else QEMU can report — prelaunch, inmigrate, guest-panicked,
        # io-error … — is shown VERBATIM rather than rounded to running or paused,
        # because rounding is how a wedged guest comes to read as a healthy one.
        return (f"qemu: {known}",
                f"State {state}. The emulator reports run-state “{known}”, which is "
                "neither running nor paused.", WARN)

    # ── arming ──────────────────────────────────────────────────────────────────
    def _gateway_row(self) -> _Row | None:
        if self.plan is None:
            return None
        for row in self._rows:
            if row.label == self.plan.gateway_label:
                return row
        return None

    def _can_tunnel(self, row: _Row | None) -> bool:
        return bool(row is not None and row.up and row.dev.ssh_host_port > 0
                    and row.dev.ssh_key)

    def _sync_controls(self):
        idle = not self._running
        planned = self.plan is not None and bool(self._rows)
        self.start_btn.setEnabled(idle and planned and self._docker_ok)
        self.stop_btn.setEnabled(idle and any(row.up for row in self._rows))
        self.refresh_btn.setEnabled(idle and planned)
        self.cancel_btn.setEnabled(self._running)
        for row in self._rows:
            self._arm_row(row, idle)
        self._sync_mesh_save(idle)
        self._sync_web(idle)
        self.completeChanged.emit()

    def _arm_row(self, row: _Row, idle: bool):
        up = row.up
        live = up and idle
        row.start.setEnabled(idle and not up and self._docker_ok)
        row.start.setToolTip(
            f"Disabled: {row.label} is already running." if up else
            "Boot this one device with --keep-alive, pinned to THIS session's "
            "artifacts and addressed with --only-exact — a FULL emulated boot; "
            "Cancel stops it.")
        row.stop.setEnabled(live)
        row.user.setEnabled(row.can_shell and idle)
        row.ssh_btn.setEnabled(row.can_shell and idle)
        row.ssh_btn.setToolTip(self._shell_tooltip(row))
        for verb, button in row.qmp.items():
            button.setEnabled(live and (verb != _QMP_ARMED
                                        or row.arm_reset.isChecked()))
        row.arm_reset.setEnabled(live)
        row.arm_reset.setToolTip(
            "Confirm the reset verb so it can fire — this tick is CONSENT, not an "
            "architecture choice (this device's architecture is the Arch column, "
            "and it follows the image it was built from). Under -no-reboot a QMP "
            "system_reset does not restart this guest — it ENDS it. Off again "
            "after every verb: consent for one click, not a mode the row stays in.")
        self._arm_pause(row, live)
        self._arm_save(row, idle)
        self._arm_replicas(row, idle, up)

    def _arm_replicas(self, row: _Row, idle: bool, up: bool):
        """The row's 0/1 replica control, against what is ACTUALLY running.

        The observed count is the row's own liveness — the same answer Start and Stop
        are armed from — so the two controls can never disagree about whether this
        device is up. A target the operator moved is left alone until the verb that
        spends it finishes (``_disarm_all``); one nobody moved simply follows reality.
        """
        strip = row.replicas
        if strip is None:
            return
        observed = 1 if up else 0
        if not strip.pending:
            strip.target = observed
        strip.paint(observed, busy=not idle)
        if not self._docker_ok:
            # Stopping never needs docker to be healthy; starting always does, and
            # the note above the table already says why it is not.
            strip.plus.setEnabled(False)
            if strip.target > observed:
                strip.apply.setEnabled(False)

    def _bump_replicas(self, index: int, delta: int):
        row = self._rows[index]
        if row.replicas is None:
            return
        row.replicas.bump(delta)
        self._sync_controls()

    def _apply_replicas(self, index: int):
        """Apply on a device row: the SAME runner verbs Start and Stop press.

        No second process lane and no second spelling of the per-device start — that
        divergence is exactly what T3 removed from this page (see the module
        docstring), and a replica control that grew its own would put it straight back.
        """
        row = self._rows[index]
        strip = row.replicas
        if strip is None or self._running:
            return
        observed = 1 if row.up else 0
        if strip.target == observed:
            return
        if strip.target >= 1:
            self._start_device(index)
        else:
            self._stop_device(index)

    def _shell_tooltip(self, row: _Row) -> str:
        dev = row.dev
        if not row.up:
            state = row.status.state if row.status is not None else "planned"
            return (f"Disabled: {row.label} is not running (state: {state}). Start "
                    "it first.")
        if dev.ssh_host_port <= 0:
            return (f"Disabled: {row.label} published no ssh port (the record says "
                    "ssh_host_port 0), so there is nothing to connect to.")
        if not dev.ssh_key:
            return (f"Disabled: {row.label}'s record names no ssh key, so there is "
                    "no identity to log in with. The key is written by the "
                    "keep-alive run that publishes the device.")
        if row.paused:
            return (f"Disabled: {row.label} is PAUSED. The port is still published "
                    "and the container is up, but the guest's CPUs are frozen, so "
                    "sshd cannot answer and the terminal would hang until it timed "
                    "out. Resume first.")
        return ("Open the desktop terminal on this device as the login selected "
                f"beside it ({qemu_devices.SSH_HOST}:{dev.ssh_host_port}).")

    def _arm_pause(self, row: _Row, live: bool):
        """Make Pause/Resume agree with what the emulator last said.

        Only Pause is ever greyed by knowledge, never Resume, and that asymmetry is
        deliberate: this page's belief can be STALE (someone can pause a device from
        a terminal with ``run-qemu-docker.sh --qmp LABEL pause``, and nothing tells
        the GUI). Greying Resume on a belief of "running" would leave the operator
        with no way to un-freeze a guest from here at all, whereas a redundant Resume
        on an already-running guest is a QMP ``cont`` that changes nothing. Status
        re-syncs the belief either way, which is why its tooltip says so.
        """
        pause, resume = row.qmp.get("pause"), row.qmp.get("resume")
        if not live or pause is None or resume is None:
            return                       # the disabled-because-dead tooltips win
        pause.setEnabled(not row.paused)
        if row.paused:
            pause.setToolTip(
                f"Disabled: {row.label} is already paused — its vCPUs are frozen. "
                "Resume continues it from exactly here. (If you paused or resumed "
                "it outside the Studio, press Status to re-read the emulator.)")
            resume.setToolTip("Continue this PAUSED guest from exactly where its "
                              "vCPUs were frozen.")
        else:
            pause.setToolTip(_QMP_TOOLTIPS["pause"])
            resume.setToolTip(_QMP_TOOLTIPS["resume"])

    def _arm_save(self, row: _Row, idle: bool):
        """Arm this row's Save copy / Overwrite save, and say what each would do.

        Overwrite has THREE gates and each is its own sentence on the widget, because
        a greyed button whose tooltip does not name its own reason reads as broken:
        the device must be up (there is no emulator to ask otherwise), a previous
        save must EXIST (there is nothing to overwrite on a first save), and the tick
        beside it must be armed (this destroys that file).

        ``idle`` rather than the row's liveness, exactly as SSH is armed: a verb
        already in flight owns this page's single worker, so nothing may start a
        second on top of it — including a save, the longest of them all.
        """
        target = row.overwrite_target
        enabled = row.can_save and idle
        row.save.setEnabled(enabled)
        row.arm_save.setEnabled(enabled and bool(target))
        row.overwrite.setEnabled(enabled and bool(target)
                                 and row.arm_save.isChecked())
        row.arm_save.setToolTip(
            "Confirm the overwrite — this tick is CONSENT, not an architecture "
            "choice (see the Arch column for that). Off by default, and off again "
            "after every save: this is consent for ONE click, not a mode the row "
            "stays in."
            if target else
            f"Nothing to confirm: {row.label} has no saved copy yet.")

        if not row.up:
            why = (f"Disabled: {row.label} is not running. While QEMU holds a "
                   "device's disk it holds a write LOCK on it, so the disk can only "
                   "be copied from INSIDE the running emulator — a stopped row has "
                   "no emulator to ask.")
            row.save.setToolTip(why)
            row.overwrite.setToolTip(why)
            return
        if not row.can_save:
            why = (f"Disabled: {row.label}'s record cannot support a save — "
                   f"{qemu_devices.save_blocker(row.dev)}")
            row.save.setToolTip(why)
            row.overwrite.setToolTip(why)
            return

        row.save.setToolTip(
            f"Save {row.label}'s disk to a NEW file. Any copy you saved before is "
            "left exactly as it is.\n\n"
            "The guest is paused for the copy and put back the way it was found (a "
            "device you had paused yourself stays paused). The result is "
            "CRASH-CONSISTENT — the disk as it would be if you pulled the power "
            "lead, NOT a clean shutdown: guest RAM is not in it and no application "
            "is asked to quiesce, so anything mid-write is copied mid-write.\n\n"
            "It copies the data the guest has actually used, so a big disk takes a "
            "while; the page is locked meanwhile and Cancel stops it. The image "
            "this device was built from is never written to.")
        if not target:
            row.overwrite.setToolTip(
                f"Disabled: {row.label} has no saved copy to overwrite yet. Use "
                "“Save copy” first — this button only ever replaces a previous "
                "SAVE, never the image the device was built from.")
        else:
            row.overwrite.setToolTip(
                "DESTRUCTIVE — re-saves this device onto its previous save:\n"
                f"    {target}\n    ({common.describe_file(target)})\n"
                "That file's current contents are DELETED and replaced with the "
                "disk as it is now. There is no undo and no second copy is kept; if "
                "you want to keep it, press “Save copy” instead.\n\n"
                "Same consistency as “Save copy”: CRASH-CONSISTENT, not a clean "
                "shutdown. Tick “confirm overwrite” beside this button to enable "
                "it."
                + ("" if row.arm_save.isChecked() else
                   "\n\nDisabled: “confirm overwrite” is not ticked."))

    def _sync_mesh_save(self, idle: bool):
        savable = any(row.can_save for row in self._rows)
        preview = self._mesh_save_preview
        fits = bool(preview) and not preview.get("refusal")
        # The PREVIEW is offered whenever there is a plan, even when nothing can be
        # saved: "why can I not save this mesh" is answered by the per-device
        # blockers the preview lists, and a button greyed with no explanation is the
        # question rather than the answer. Only the CONFIRMATION tick needs
        # something to save.
        self.mesh_save_btn.setEnabled(idle and self.plan is not None)
        self.mesh_save_arm.setEnabled(idle and savable and fits)
        if not fits and self.mesh_save_arm.isChecked():
            self.mesh_save_arm.setChecked(False)

    def _sync_web(self, idle: bool):
        gw = self._gateway_row()
        tunnel_ok = idle and self._can_tunnel(gw)
        self.web_btn.setEnabled(tunnel_ok)
        self.tunnel_close_btn.setEnabled(bool(self._tunnels))
        if self.plan is None:
            self.web_note.setText("")
        elif tunnel_ok:
            self.web_btn.setToolTip(
                "Start (or reuse) the ssh tunnel to the gateway's :443 and hand "
                "the URL to your desktop browser.")
            self.web_note.setText(
                f"Front door ready: <tt>{self.plan.front_door}</tt>")
        else:
            self.web_btn.setToolTip(
                "Greyed until the gateway device is up with a published ssh port — "
                "the web tunnel rides it.")
            self.web_note.setText(
                f'<span style="color:{MUTED}">The front door '
                f"(<tt>{self.plan.gateway_label or '?'}</tt>) is not up yet — start "
                "the mesh, then Refresh.</span>")
        self._sync_tunnel_note()

    def _sync_tunnel_note(self):
        """The tunnel's state, ON the page. This is the operator's "why can't I
        reach the web console" path, so "is a tunnel up, for what, as what pid" is
        never a thing to go and find out elsewhere."""
        live = [(label, proc) for label, proc in self._tunnels.items()
                if proc.poll() is None]
        if not live:
            self.tunnel_note.setText(
                f'<span style="color:{MUTED}">No web tunnel is open.</span>')
            return
        pieces = [f"<tt>{html.escape(label)}</tt> (pid {getattr(proc, 'pid', '?')})"
                  for label, proc in live]
        self.tunnel_note.setText(
            "Web tunnel open for " + ", ".join(pieces) +
            f" &rarr; <tt>{self.plan.front_door if self.plan else ''}</tt>. It "
            "stays up until you close it, the device stops, or you leave this page.")

    # ── verbs (all through the ONE core spawn) ──────────────────────────────────
    def _run_verb(self, label: str, argv: list[str], *, finished=None):
        """Run one runner invocation off the GUI thread, streaming into the log.

        Every boot/stop/QMP/save goes through ``emulation.spawn`` — the facade's one
        documented process boundary — so the whole page is testable with that single
        function replaced: no docker, no qemu, no images. The page's single worker
        slot blocks a second verb on top of a first (the LocalMeshPage discipline).

        ``finished(ok, cancelled)`` runs on the GUI thread when the verb ends and may
        return an inline note. It exists so a verb can record what it CHANGED (a
        pause that took, a save that landed) BEFORE the table is repainted from it.
        """
        if self._running or not argv:
            return
        console.write(self.log, f"$ {shlex.join(argv)}")
        self._cancel = threading.Event()
        self._verb_finished = finished
        self._set_running(True)

        def verb(on_line, _cancel):
            rc = emulation.spawn(argv, self.wiz.generator_dir, on_line=on_line,
                                 cancel=self._cancel)
            return rc == 0, []

        self.worker = _MeshWorker(verb, parent=self, stream=True)
        self.worker.line.connect(self._on_line)
        self.worker.done.connect(lambda ok, lbl=label: self._verb_done(ok, lbl))
        self.worker.start()

    def _on_line(self, line: str):
        console.write(self.log, line)
        self._note_run_state(line)

    def _note_run_state(self, line: str):
        """Learn a device's real run-state from a ``--qmp … status`` reply.

        The only way this table can tell the truth about a device someone paused
        OUTSIDE the Studio. Nothing is inferred when the line does not parse: the
        row's run-state stays unknown, and the State column says that rather than
        assuming the guest is running.
        """
        if not self._status_watch:
            return
        m = _QMP_STATUS_RE.search(line)
        if m:
            for row in self._rows:
                if row.label == self._status_watch:
                    row.run_state = m.group(1)

    def _verb_done(self, ok: bool, label: str):
        # The cancel EVENT is not the answer to "was this cancelled": emulation.spawn
        # sets it on the way out to release its own watcher thread, so every normal
        # completion leaves it set. What was cancelled is what the operator pressed
        # Cancel on — _cancel_pressed, cleared by _set_running when work starts.
        cancelled = self._cancel_pressed
        finished, self._verb_finished = self._verb_finished, None
        self._set_running(False)
        outcome = "cancelled" if cancelled else ("done" if ok else "FAILED")
        console.write(self.log, f"== {label}: {outcome} ==")
        # BEFORE the repaint: the callback is what the rows read their run-state and
        # their save set from, so it has to have run by the time they are painted.
        note = finished(ok, cancelled) if finished is not None else None
        self._disarm_all()
        # Re-read reality rather than inferring it from the exit code: a stop that
        # half-worked still leaves a container behind, and the row must show what IS.
        self._refresh_reality()
        if note:
            self.note.setText(note)

    def _disarm_all(self):
        """Spend every confirmation tick when a verb finishes.

        Arming is consent for ONE click, not a mode the row stays in. The old console
        got that for free because it REBUILT the whole table after every verb; this
        page patches rows instead (it repaints on a timer, and a rebuild would throw
        away the operator's selection every few seconds), so the ticks have to be
        cleared deliberately. Without this, one armed overwrite would stay armed for
        every later click on that row.
        """
        for row in self._rows:
            row.arm_save.setChecked(False)
            row.arm_reset.setChecked(False)
            # The same rule for the replica target: one press, one ask. Cleared here
            # rather than snapped to a count, because the count is re-read AFTER this
            # (_verb_done -> _refresh_reality) and a target set from the pre-verb
            # truth would re-arm Apply against the post-verb one.
            if row.replicas is not None:
                row.replicas.clear_pending()

    def _set_running(self, running: bool):
        self._running = running
        if running:
            self._cancel_pressed = False      # fresh work, fresh cancel bookkeeping
        self._sync_controls()
        self._sync_poll()

    def _cancel_verb(self):
        if not self._running:
            return
        self._cancel_pressed = True
        console.write(self.log,
                      "!! cancelling — terminating the runner's process group")
        self._cancel.set()

    # ── mesh-wide verbs ─────────────────────────────────────────────────────────
    def _start_mesh(self):
        if self.plan is None:
            return
        console.write(self.log,
                      "[mesh] booting every planned device with --keep-alive — "
                      "each is a full emulated boot; Cancel stops the run.")
        self._run_verb("start mesh", emulation.run_argv(self.plan))

    def _stop_mesh(self):
        if self.plan is None:
            return
        # BEFORE the stop, not after: a tunnel pointed at a device that is going away
        # would keep a loopback port bound and answer the browser with a hang.
        self._close_tunnels("the mesh is stopping")
        self._run_verb("stop all devices", emulation.stop_all_argv(self.plan),
                       finished=self._forget_run_states)

    def _forget_run_states(self, _ok, _cancelled):
        for row in self._rows:
            row.run_state = ""
        return None

    def _start_device(self, index: int):
        """Boot ONE device — through the single per-device Start contract.

        ``emulation.start_device_argv`` ALWAYS pins ``--artifacts`` and ``--work``
        and addresses the row with ``--only-exact``. The spelling it replaced let the
        runner guess its newest session and matched the label by SUBSTRING, so a
        restart of ``x86/be`` could boot a different build than the row was planned
        from and drag ``be+gpu``/``be-ha`` along with it.
        """
        if self.plan is None:
            return
        row = self._rows[index]
        try:
            argv = emulation.start_device_argv(self.plan, row.label)
        except ValueError as exc:
            self.note.setText(f'<span style="color:{WARN}">{exc}</span>')
            return
        self._run_verb(f"start {row.label}", argv)

    def _stop_device(self, index: int):
        if self.plan is None:
            return
        row = self._rows[index]
        if row.label == self.plan.gateway_label:
            self._close_tunnels("the gateway device is stopping", [row.label])
        self._run_verb(f"stop {row.label}",
                       emulation.stop_device_argv(self.plan, row.label),
                       finished=lambda *_a, r=row: self._forget_row_state(r))

    def _forget_row_state(self, row: _Row):
        row.run_state = ""
        return None

    # ── the QMP console ─────────────────────────────────────────────────────────
    def _reset_armed(self, index: int, armed: bool):
        """Ticking “confirm reset” PRINTS what it just allowed."""
        if armed:
            row = self._rows[index]
            self.note.setText(
                f'<span style="color:{WARN}"><b>Reset is confirmed for '
                f"{html.escape(row.label)}.</b></span> " + _reset_warning(row.label))
        self._sync_controls()

    def _device_qmp(self, index: int, command: str):
        if self._running:
            # Returning first keeps the status watch below from being armed for a
            # verb that never starts, which would then attribute an unrelated line
            # to this row.
            return
        row = self._rows[index]
        if command == _QMP_ARMED and not row.arm_reset.isChecked():
            # The button is greyed in this state, so this is the belt to that braces:
            # the guard that matters is the one in front of the ACTION, not the one
            # in front of the pixels. NOT a popup — the tick beside the button IS the
            # confirmation, so saying "tick it" inline keeps the answer where the
            # question is.
            self.note.setText(
                f'<span style="color:{WARN}"><b>Reset is not confirmed.</b></span> '
                "Tick “confirm reset” beside the button to allow it. "
                + _reset_warning(row.label))
            console.write(
                self.log,
                f"[mesh] refused: reset of {row.label} is not confirmed")
            return
        # A status reply is read off the STREAM, so the reader has to know whose it
        # is before the first line arrives.
        self._status_watch = row.label

        def finished(ok, _cancelled, r=row, cmd=command):
            self._status_watch = ""
            if not ok:
                return None                  # a verb that failed changed nothing
            if cmd == "pause":
                r.run_state = _RUN_PAUSED
            elif cmd == "resume":
                r.run_state = _RUN_RUNNING
            elif cmd in _QMP_ENDS_GUEST:
                r.run_state = ""             # that guest is gone
            return None

        if command in _QMP_ENDS_GUEST and row.label == self.plan.gateway_label:
            self._close_tunnels("the gateway guest is ending", [row.label])
        self._run_verb(f"qmp {command} {row.label}",
                       emulation.qmp_argv(self.wiz.generator_dir, row.dev, command),
                       finished=finished)

    # ── per-device save ─────────────────────────────────────────────────────────
    def _device_save(self, index: int, mode: str):
        """Save this device's disk — to a NEW file, or over its previous save.

        Every refusal below is stated INLINE (note + log) and never as a dialog: each
        is a fact to read rather than a question to answer.

        The arming is re-checked here as well as being greyed in the table: the guard
        that matters is the one in front of the ACTION, not the one in front of the
        pixels. It is checked before the argv is built, so an unarmed overwrite never
        becomes a command that exists.
        """
        row = self._rows[index]
        if not row.up:
            self.note.setText(
                f'<span style="color:{WARN}">{html.escape(row.label)} is not '
                "running</span>, so there is no emulator to copy its disk from — "
                "QEMU holds a write lock on it while it is up, and the copy happens "
                "inside that process.")
            return
        target = row.overwrite_target
        if mode == _SAVE_OVERWRITE:
            if not target:
                self.note.setText(
                    f'<span style="color:{WARN}">{html.escape(row.label)} has no '
                    "saved copy to overwrite.</span> Press “Save copy” first — "
                    "overwrite only ever replaces a previous save, never the image "
                    "the device was built from.")
                return
            if not row.arm_save.isChecked():
                self.note.setText(
                    f'<span style="color:{WARN}">Overwrite is not confirmed.</span> '
                    f"It would DELETE {html.escape(target)} "
                    f"({common.describe_file(target)}) and replace it with the disk "
                    "as it is now. Tick “confirm overwrite” beside the button to "
                    "allow that, or press “Save copy” to keep both.")
                console.write(
                    self.log,
                    f"[mesh] refused: overwrite of {target} is not confirmed")
                return
        try:
            # qemu_devices owns WHICH FILE a mode resolves to — the naming rule, the
            # target directory and the "newest existing save" lookup. The GUI does
            # not re-derive any of it: the first attempt let the GUI pick a path, the
            # runner pick another and the core offer a third, and "overwrite the
            # existing copy" overwrote a file nothing else had ever written.
            argv = qemu_devices.save_argv(self.wiz.generator_dir, row.dev, mode,
                                          work_dir=self.plan.work_dir,
                                          artifacts_dir=self.plan.session_path)
        except (TypeError, ValueError) as exc:
            self.note.setText(
                f'<span style="color:{WARN}">This Studio cannot build a “{mode}” '
                f"save command: {html.escape(str(exc))}</span>")
            console.write(self.log, f"!! save_argv({mode!r}) rejected it: {exc}")
            return

        consistency = ("crash-consistent — the guest is paused for the copy, so the "
                       "result is its disk as if the power lead had been pulled, "
                       "not a clean shutdown")
        if mode == _SAVE_OVERWRITE:
            console.write(self.log,
                          f"[mesh] OVERWRITING {target} "
                          f"({common.describe_file(target)}) — that copy is gone "
                          f"from here on. The new one is {consistency}.")
        else:
            console.write(self.log,
                          f"[mesh] saving {row.label} to a NEW file; existing saves "
                          f"are left alone. The copy is {consistency}.")
        console.write(self.log,
                      "[mesh] a big disk takes a while — the page is locked until "
                      "it finishes, and Cancel stops it (a cancelled save leaves a "
                      "PARTIAL file, which is not a save).")

        before = list(row.saves)
        self._run_verb(
            f"save ({mode}) {row.label}", argv,
            finished=lambda ok, cancelled, r=row, m=mode, b=before, t=target:
                self._save_finished(ok, cancelled, r, m, b, t))

    def _save_finished(self, ok: bool, cancelled: bool, row: _Row, mode: str,
                       before: list[str], target: str) -> str:
        """Report what is ON DISK now, not what the exit status claimed.

        A backup that dies mid-job still leaves a target file behind, so "the runner
        exited 0" and "there is a save you can restore from" are different
        statements. This one re-reads the save directory and says which it got: a
        partial file that looks like a save is the worst outcome available here.

        Returns the note rather than setting it, because ``_verb_done`` repaints
        straight afterwards and a repaint clears the row-level state it read.
        """
        after = _saved_copies(self.plan.work_dir if self.plan else "", row.dev)
        row.saves = after
        if not ok:
            why = "cancelled" if cancelled else "FAILED"
            appeared = [p for p in after if p not in before]
            leftover = (target if mode == _SAVE_OVERWRITE and target
                        else (appeared[0] if appeared else ""))
            extra = (f" <tt>{html.escape(leftover)}</tt> may be a PARTIAL copy — do "
                     "not restore from it." if leftover else "")
            return (f'<span style="color:{WARN}">Save {why} for '
                    f"{html.escape(row.label)}.</span>" + extra)
        if mode == _SAVE_OVERWRITE:
            if not os.path.exists(target):
                return (f'<span style="color:{WARN}">The overwrite of '
                        f"{html.escape(target)} reported success, but that file is "
                        f"not there now.</span> Treat {html.escape(row.label)} as "
                        "NOT saved.")
            return (f"Overwrote <tt>{html.escape(target)}</tt> "
                    f"({common.describe_file(target)}) with {html.escape(row.label)}"
                    "'s disk — crash-consistent. The copy that was there is gone.")
        new = [p for p in after if p not in before]
        if not new:
            return (f'<span style="color:{WARN}">The save of '
                    f"{html.escape(row.label)} reported success, but no new file "
                    "appeared where saves are listed.</span> Do not treat this "
                    "device as saved until you can see the file.")
        return (f"Saved <tt>{html.escape(row.label)}</tt> to "
                f"<tt>{html.escape(new[0])}</tt> ({common.describe_file(new[0])}) — "
                "crash-consistent, and any earlier save was left untouched.")

    # ── the whole-mesh save (issue #50 item 10) ─────────────────────────────────
    def _save_mesh_clicked(self):
        """PREVIEW first, execute second — never the other way round.

        Two presses, and the “confirm mesh save” tick between them, because a
        mesh save is 9.5-20.5 GB PER DEVICE. The preview is pure
        (``emulation.plan_mesh_save`` creates, pauses and copies nothing) and it is
        the only place the operator can see the fleet total against the free space
        BEFORE a single guest is frozen. Running
        out mid-fleet leaves earlier saves landed, the current one a giant
        ``.partial``, and — measured on this workstation — can take the live mesh's
        own volumes down with a full filesystem.
        """
        if self.plan is None or self._running:
            return
        if self._mesh_save_preview is None or not self.mesh_save_arm.isChecked():
            self._preview_mesh_save()
            return
        self._run_mesh_save()

    def _preview_mesh_save(self):
        assert self.plan is not None
        name = emulation_save.session_name()
        try:
            preview = emulation.plan_mesh_save(self.plan, session=name)
        except (OSError, ValueError) as exc:
            self._mesh_save_preview = None
            self.mesh_save_note.setText(
                f'<span style="color:{WARN}">The mesh save cannot be planned: '
                f"{html.escape(str(exc))}</span>")
            self._sync_controls()
            return
        self._mesh_save_preview = preview
        self.mesh_save_note.setText(self._render_mesh_save_preview(preview))
        self.mesh_save_arm.setChecked(False)
        self._sync_controls()

    def _render_mesh_save_preview(self, preview: dict) -> str:
        """The preview, as the operator reads it: per device, then the fleet."""
        lines = [f"<b>Mesh save preview</b> — save-set "
                 f"<tt>{html.escape(str(preview.get('session', '')))}</tt> in "
                 f"<tt>{html.escape(str(preview.get('session_dir', '')))}</tt>"]
        rows = preview.get("devices") or []
        for row in rows:
            label = html.escape(str(row.get("label", "?")))
            blocker = str(row.get("blocker") or "")
            keys = row.get("keys") or []
            present = sum(1 for k in keys if k.get("exists"))
            keys_text = (f"KEYS {present}/{len(keys)} piece(s) present" if keys
                         else "no KEYS set recorded")
            if blocker:
                lines.append(
                    f'&nbsp;&nbsp;<tt>{label}</tt> — <span style="color:{WARN}">'
                    f"will NOT be saved: {html.escape(blocker)}</span>")
                continue
            lines.append(
                f"&nbsp;&nbsp;<tt>{label}</tt> — budget "
                f"{common.human_bytes(row.get('budget_bytes', 0))}, {keys_text} "
                f"&rarr; <tt>{html.escape(str(row.get('target', '')))}</tt>")
        for un in preview.get("unresolved") or []:
            lines.append(
                f'&nbsp;&nbsp;<span style="color:{WARN}">'
                f"{html.escape(str(un.get('label', '?')))} — "
                f"{html.escape(str(un.get('error', '')))}</span>")
        needed = preview.get("needed_bytes", 0)
        free = preview.get("free_bytes", -1)
        lines.append(
            f"<b>Fleet total {common.human_bytes(needed)}</b> against "
            f"{common.human_bytes(free)} free. A save is each disk's FULL virtual "
            "size, not what the guest wrote.")
        refusal = str(preview.get("refusal") or "")
        if refusal:
            lines.append(f'<span style="color:{WARN}"><b>REFUSED — nothing will be '
                         f"saved.</b> {html.escape(refusal)}</span>")
        else:
            lines.append("Tick <b>confirm mesh save</b> and press <b>Save mesh</b> "
                         "again to run it. Each device is paused for its copy and "
                         "put back the way it was found; the copies are "
                         "CRASH-CONSISTENT.")
        return "<br>".join(lines)

    def _run_mesh_save(self):
        """Execute the PREVIEWED save-set — same session name, same targets."""
        assert self.plan is not None
        preview = self._mesh_save_preview or {}
        name = str(preview.get("session") or "")
        if not name:
            self._preview_mesh_save()
            return
        plan = self.plan
        gen = self.wiz.generator_dir
        console.write(self.log,
                      f"[mesh] saving the fleet into {preview.get('session_dir')} — "
                      f"{common.human_bytes(preview.get('needed_bytes', 0))} "
                      "budgeted. Cancel stops the device now copying; the ones "
                      "already saved stay saved.")
        self._cancel = threading.Event()
        self._verb_finished = self._mesh_save_finished
        # Cleared BEFORE the run: a refusal leaves no report, and the previous run's
        # report standing in for it would report devices that this save never touched.
        self._mesh_save_report = None
        self._set_running(True)
        cancel = self._cancel

        def verb(on_line, _cancel):
            def run(argv):
                # The save orchestrator's process seam, wired to THE spawn — so a
                # mesh save streams into this log and cancels by process group like
                # every other verb on this page.
                return emulation.spawn(argv, gen, on_line=on_line, cancel=cancel)

            try:
                report = emulation.save_mesh(plan, session=name, run=run)
            except emulation_save.MeshSaveError as exc:
                on_line(f"REFUSED: {exc}")
                return False, []
            for res in report.results:
                if res.ok:
                    on_line(f"saved {res.label} -> {res.target}")
                    for piece in res.keys_copied:
                        on_line(f"  keys: {piece}")
                    if res.keys_error:
                        on_line(f"  keys warning: {res.keys_error}")
                else:
                    on_line(f"FAILED {res.label}: {res.error}")
            if report.manifest_path:
                on_line(f"manifest: {report.manifest_path}")
            self._mesh_save_report = report
            return report.ok, []

        self.worker = _MeshWorker(verb, parent=self, stream=True)
        self.worker.line.connect(self._on_line)
        self.worker.done.connect(lambda ok: self._verb_done(ok, "save mesh"))
        self.worker.start()

    def _mesh_save_finished(self, ok: bool, cancelled: bool) -> str:
        """Disarm and report — a preview is spent once it has been run."""
        report = getattr(self, "_mesh_save_report", None)
        self._mesh_save_preview = None
        self.mesh_save_arm.setChecked(False)
        self.mesh_save_note.setText("")
        if report is None:
            return (f'<span style="color:{WARN}">The mesh save was refused before '
                    "anything was written.</span> See the log for the reason and "
                    "its remedies.")
        saved = [r.label for r in report.saved]
        failed = [r.label for r in report.failed]
        word = "cancelled" if cancelled else ("complete" if ok else "INCOMPLETE")
        note = (f"Mesh save {word}: {len(saved)} device(s) saved into "
                f"<tt>{html.escape(report.session_dir)}</tt>")
        if failed:
            note += (f'. <span style="color:{WARN}">Not saved: '
                     f"{html.escape(', '.join(failed))}</span> — a failed device's "
                     "partial copy was quarantined by the runner as "
                     "<tt>&lt;target&gt;.partial</tt> and must not be trusted")
        return note + "."

    # ── ssh + web (desktop-side, detached) ──────────────────────────────────────
    def _open_shell(self, index: int):
        """Desktop terminal on that device as the selected login — DETACHED."""
        row = self._rows[index]
        if not row.can_shell:
            # The button is disabled in this state, so this is the belt to that
            # braces — it exists because "ssh -p 0" is the one failure the operator
            # could not diagnose from the terminal window that flashed up and died.
            self.note.setText(
                f'<span style="color:{WARN}">{html.escape(row.label)} has no ssh '
                "login to open</span> — it is not running, it is paused, or its "
                "record published no port/key.")
            return
        dev = row.dev
        if row.user.currentData() == _ROOT_ROW:
            login, superuser = dev.ssh_user, True
        else:
            login = str(row.user.currentData() or dev.ssh_user)
            superuser = False
        argv = qemu_devices.ssh_argv(dev, login, superuser=superuser)
        opened, note, log_line = common.open_terminal(argv)
        console.write(self.log, f"[mesh] {log_line}")
        if not opened:
            self.note.setText(note)
            return
        who = f"{login} + sudo -i" if superuser else login
        self.note.setText(f"Opened a terminal on <tt>{html.escape(row.label)}</tt> "
                          f"as <tt>{html.escape(who)}</tt>.")

    def _open_web_ui(self):
        """Tunnel to the gateway's :443 and open the URL — stating the REUSE.

        The tunnel is DETACHED like a terminal, because the browser tab must keep
        working while the operator does other things; it is TRACKED all the same, so
        this page can say whether it started one or reused one, and can take it down
        when the device it points at goes away.
        """
        row = self._gateway_row()
        if not self._can_tunnel(row):
            self.note.setText(
                f'<span style="color:{WARN}">The gateway device is not reachable '
                "yet</span> — start the mesh and Refresh until its row says "
                "running.")
            return
        assert row is not None and self.plan is not None
        url = self.plan.front_door
        try:
            argv = mesh_emulation.web_tunnel_argv(row.dev, row.planned)
        except ValueError as exc:
            self.note.setText(f'<span style="color:{WARN}">{html.escape(str(exc))}'
                              "</span>")
            return
        existing = self._tunnels.get(row.label)
        reused = existing is not None and existing.poll() is None
        if reused:
            console.write(self.log,
                          f"[mesh] reusing the web tunnel already open for "
                          f"{row.label} (pid {getattr(existing, 'pid', '?')})")
        else:
            try:
                self._tunnels[row.label] = subprocess.Popen(
                    argv, start_new_session=True)
            except OSError as exc:
                self.note.setText(
                    f'<span style="color:{WARN}">Could not start the web tunnel: '
                    f"{html.escape(str(exc))}</span> Run it yourself: "
                    f"<tt>{html.escape(shlex.join(argv))}</tt>")
                return
            console.write(self.log, f"[mesh] web tunnel: {shlex.join(argv)}")
        QtGui.QDesktopServices.openUrl(QtCore.QUrl(url))
        pid = getattr(self._tunnels.get(row.label), "pid", "?")
        decision = (f"Reusing the tunnel already open for <tt>{html.escape(row.label)}"
                    f"</tt> (pid {pid})." if reused else
                    f"Started a web tunnel for <tt>{html.escape(row.label)}</tt> "
                    f"(pid {pid}).")
        self.note.setText(
            f"{decision} Front door: <tt>{html.escape(url)}</tt> (self-signed TLS — "
            f"the browser will warn once). Tunnel: "
            f"<tt>{html.escape(shlex.join(argv))}</tt>")
        self._sync_controls()

    def _close_tunnels(self, reason: str, labels: list[str] | None = None):
        """Terminate the tunnels this page opened, and say so in the log.

        Called from Stop-all, from the stop (or reset/powerdown) of the GATEWAY, and
        from leaving the page. A tunnel whose far end is gone is worse than no
        tunnel: the local port still binds and still accepts, so the browser hangs
        on a connection that will never be answered.
        """
        for label in (list(self._tunnels) if labels is None else list(labels)):
            proc = self._tunnels.pop(label, None)
            if proc is None:
                continue
            if proc.poll() is None:
                try:
                    proc.terminate()
                except OSError:
                    pass
            console.write(self.log,
                          f"[mesh] closed the {label} web tunnel ({reason})")
        self._sync_tunnel_note()
        self.tunnel_close_btn.setEnabled(bool(self._tunnels))


def _reset_warning(label: str) -> str:
    """The loud inline destructive warning for the ``reset`` verb, spelled ONCE.

    Shown when the tick is armed and again if the action is somehow reached unarmed,
    so the two can never drift into saying different things about the same verb.
    """
    return (f"On <tt>{html.escape(label)}</tt> it would <b>end the guest</b>, not "
            "restart it: every launcher runs qemu with <tt>-no-reboot</tt> "
            "(tests/qemu/launch-pi.sh, launch-arm.sh, launch-x86.sh), and under that "
            "flag a QMP <tt>system_reset</tt> makes the emulator shut down and exit "
            "— qemu reports the shutdown with reason "
            "<tt>host-qmp-system-reset</tt>. The row would stop and need a FULL "
            "emulated boot to come back. Nothing is lost that a disposable overlay "
            "was not going to lose anyway; any unsaved disk state is.")


def _saved_copies(work_dir: str, dev) -> list[str]:
    """That device's existing saves, newest first — [] when there is no device.

    Wrapped rather than called directly because it runs on every repaint, and now on
    a TIMER: a work dir that has gone away (an unplugged external disk, a tmpdir a
    test tore down) must cost an empty list and a greyed Overwrite, not a traceback
    out of a Qt slot every four seconds.
    """
    if dev is None or not work_dir:
        return []
    try:
        return [str(p) for p in qemu_devices.saved_copies(work_dir, dev)]
    except OSError:
        return []

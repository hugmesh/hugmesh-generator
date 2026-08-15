"""QemuPage — run the QEMU emulated-device tests, containerized, from the Studio.

This is the fourth ModePage SIDE-FLOW (after LOCAL DOCKER MESH, MDM PHONE/QUEST and
CLOUD DEPLOY): it builds no image and commits NOTHING to ``cfg.mode``, so
``applies_to()`` reads a transient wizard flag exactly as its siblings do.

THE THREE THINGS THIS PAGE OFFERS (the first two from the operator ask, verbatim:
"run these tests containerized with qemu using images built in other sessions or
start a new build and then run these emulations after")

  1. USE EXISTING IMAGES — pick any previous build session and boot its artifacts
     as emulated devices right now. This is the common case: image builds take
     hours, so re-testing what is already on disk must not require rebuilding it.

  2. BUILD FIRST, THEN TEST — leave this page into the normal image-configuration
     flow with ``cfg.qemu_e2e`` set, so the tests run against the images that
     build produces. The chaining flag is the SAME one BuildPage exposes, so
     "build then test" means one thing in the Studio, not two.

  3. DRIVE THE DEVICES THAT ARE UP — with "Keep devices running after tests"
     ticked the guests are left running instead of powered off, and each one gets
     a row in the DEVICES table below (the operator ask, verbatim: "when the
     devices are run in the qemu emulation suite … they can be logged into with a
     terminal by shell with a single button using the default bash terminal
     application on the desktop as the superuser or another user that can be
     selected from available users in all domains by dropdown per device … and
     that it has the same local mesh start and stop options with additional
     buttons to control the qemu options on each running emulated device").

  4. PAUSE AND SAVE what a device has become (the operator ask, verbatim: "makse
     sure that the studio user has options to pause and save everything to the
     existing disk in another copy or overwrite the existing copy in the
     session"). Each row gets "Save copy" — a NEW file, previous saves untouched
     — and "Overwrite save", which re-saves onto that device's most recent save
     and is therefore DESTRUCTIVE, so it is armed by a tick beside it and greyed
     out entirely until a save exists to overwrite.

WHAT A SAVE IS, AND WHAT IT IS NOT (both are on the buttons, not only here)
--------------------------------------------------------------------------
A save is CRASH-CONSISTENT: the guest's vCPUs are stopped, the DISK is copied,
and the copy is what the device would hold if its power lead had been pulled at
that instant. Guest RAM is not in it and no application is asked to quiesce, so a
database caught mid-write is copied mid-write. The buttons say exactly that; a
"snapshot" that is quietly assumed to be clean is worse than no button.

Nothing here can write to the golden build image. The runner boots every device
through a per-run qcow2 overlay precisely so the shared .img artifact stays
pristine, and the one QMP verb that would fold an overlay back into it
(block-commit) both mutates that artifact in place and drops the overlay from the
chain — measured on qemu 10.2.3 — so every later guest write in the session would
land on the image every other run and session boots from. It is offered by no
control on this page, and "overwrite" means the device's own previous SAVE, never
the image it was booted from.

WHY THE TICK IS A REAL OPTION FIELD, NOT A LOCAL FLAG
-----------------------------------------------------
``--keep-alive`` is the only thing that leaves a guest up and makes the entrypoint
write the registry this page's device table reads, so a tick that does not reach the
runner's argv leaves the whole console permanently empty. It therefore rides
``QemuRunOptions.keep_alive`` — the SAME object the preview and the spawn both build
their argv from (``qemu_tests.runner_command``) — instead of an attribute assigned
onto the options here, which the shared argv builder would simply not look at.

WHY CONTAINERIZED (and why the page says so out loud)
----------------------------------------------------
Booting a golden .img means lifting its kernel out of the boot partition, which
is a loop mount, which is root. A GUI cannot answer an interactive sudo prompt,
so the harness runs inside a --privileged container instead — root for anyone in
the ``docker`` group. If docker is unreachable the page says so up-front rather
than letting the operator configure a run that dies at spawn (the same courtesy
WelcomePage extends when the host has no build backend).
"""
from __future__ import annotations

import datetime
import html
import os
import re
import shlex
import signal
import subprocess
import threading
from dataclasses import dataclass, field

from ..qt import Qt, QtGui, QtWidgets
from ..styles import MUTED, WARN
from ...core import qemu_devices, qemu_tests
from ...core.qemu_tests import QemuRunOptions, QemuTestRunner
from ._scroll import scrollable
from .localmesh import _MeshWorker

#: Result-table columns. Symbolic, never hardcoded at a call site (progress.py's rule).
_COL_LABEL, _COL_STATUS, _COL_PASS, _COL_FAIL, _COL_TIME = range(5)

#: Status -> the colour it reads as in the results table.
_STATUS_COLOURS = {"PASS": "#2e7d32", "FAIL": "#c62828", "ERROR": "#c62828"}

#: Device-table columns. Same symbolic rule as the results table above, and the
#: headers live beside them so a column can never end up labelled as its neighbour.
(_DCOL_LABEL, _DCOL_WHAT, _DCOL_STATE, _DCOL_SSH, _DCOL_CONTAINER, _DCOL_USER,
 _DCOL_SHELL, _DCOL_POWER, _DCOL_QMP, _DCOL_SAVE) = range(10)
_DEVICE_HEADERS = ("Device", "Platform/role", "State", "SSH", "Container", "User",
                   "Shell", "Start/Stop", "QEMU", "Save disk")

#: What the SSH cell says for a device whose record carries ``ssh_host_port: 0``.
#: That is a legitimate registry value — it means the container published nothing —
#: so the cell states the fact and the Shell button on that row is DISABLED.
_NO_SSH_PORT = "not published"

#: The dropdown row that means "log in as a wheel user, THEN sudo -i". It is not a
#: login and must never be sent as one: the guest's sshd ships PermitRootLogin no
#: and tests/qemu/assertions.sh checks that it still does ("sshd PermitRootLogin
#: disabled"), so root is reached through a wheel user or not at all. The sentinel
#: is unspellable as a unix login, so it can never collide with a real account
#: coming out of available_logins().
_ROOT_ROW = "\x00root-via-sudo"

#: How each QMP verb reads on its button. A LOOKUP over qemu_devices.QMP_COMMANDS,
#: never a second list of verbs: that tuple decides which buttons exist and in what
#: order (its own docstring asks the GUI to build them from it), and a verb added
#: there grows a button here under a title-cased fallback instead of vanishing.
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

#: Verbs after which the guest is GONE, so the button is marked and the row's own
#: Start is what brings it back. Presenting these as ordinary controls is what the
#: label above exists to avoid.
_QMP_ENDS_GUEST = frozenset({"reset", "powerdown"})

#: Per-verb "what does this actually do", on the widget rather than in prose.
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
             "and has to be Started (a full boot) to come back.",
    "powerdown": "Press the guest's ACPI power button: an ORDERLY shutdown from "
                 "inside. The device ends — use Start to boot it again.",
    "status": "Ask the emulator what it thinks the guest is doing. Reads only; "
              "changes nothing — and it is how this table re-syncs its State "
              "column with a device someone paused from a terminal.",
}

#: The emulator's own run-state, lifted out of what ``--qmp LABEL status`` printed.
#: The runner's QMP client prints QEMU's reply line VERBATIM (it ends in
#: ``print $r``, tests/qemu/run-qemu-docker.sh:778), and query-status answers
#: ``{"return": {"status": "running", "running": true}}`` — checked against qemu
#: 10.2.3, which reported "running" on a fresh boot, "paused" after a QMP stop and
#: "running" again after cont. Nothing is inferred when this does not match: an
#: unparsed line leaves the row's run-state UNKNOWN, which the State column then
#: says rather than guessing "running".
_QMP_STATUS_RE = re.compile(r'"status"\s*:\s*"([a-z-]+)"')

#: Run-states this page distinguishes. Anything else QEMU can report (prelaunch,
#: inmigrate, watchdog, guest-panicked …) is shown VERBATIM in the State cell
#: instead of being flattened into one of these two.
_RUN_PAUSED, _RUN_RUNNING = "paused", "running"

#: The two save actions, and the only two.
#:
#: ``copy`` writes a NEW file and leaves every previous save of that device alone;
#: ``overwrite`` re-saves onto the device's most recent save, which destroys it.
#: That is what "overwrite the existing copy in the session" can safely mean here
#: — see the module docstring for why folding an overlay back into the golden
#: build image is not a third mode and not a button.
_SAVE_COPY, _SAVE_OVERWRITE = "copy", "overwrite"

#: What this page needs from core.qemu_devices before it can offer saving at all,
#: checked in ONE place (``_save_supported``).
#:
#: The rules a save obeys — where a target file lands, how a new copy is named,
#: which existing file "overwrite" reuses — belong to that module, which already
#: owns every other argv this table builds. So nothing here reimplements them: in a
#: tree whose core module predates them the two buttons are DISABLED and say so,
#: which is honest, rather than this page inventing a second set of path rules that
#: would disagree with the runner's and quietly arm Overwrite against the wrong file.
#: ``can_save`` is in the list because ``_DeviceRow.can_save`` calls it. Every name
#: this page reaches for has to be checked in the ONE place that decides whether the
#: feature is offered — a name that is called but not checked turns a tree without it
#: from "the buttons are greyed and say why" into an AttributeError out of a Qt slot.
_SAVE_API = ("save_argv", "saved_copies", "can_save")


def _save_supported() -> bool:
    """Whether core.qemu_devices in THIS tree can express a save."""
    return all(callable(getattr(qemu_devices, name, None)) for name in _SAVE_API)


def _saved_copies(work_dir: str, dev: qemu_devices.Device) -> list[str]:
    """That device's existing saves, newest first — [] when saving is unavailable.

    Wrapped rather than called directly because it is read on every re-arm of the
    table: it touches the filesystem, so a work dir that has gone away (an unplugged
    external disk, a tmpdir a test tore down) must cost an empty list and a greyed
    Overwrite, not a traceback out of a Qt slot.
    """
    if not _save_supported():
        return []
    try:
        return [str(p) for p in qemu_devices.saved_copies(work_dir, dev)]
    except OSError:
        return []


def _describe_file(path: str) -> str:
    """"12.4 MB, saved 2026-08-14 21:09" — what an Overwrite is about to destroy.

    The size and the timestamp are the only two things that let an operator tell
    one save from another before agreeing to lose it, so the destructive button
    names them instead of saying "the previous save".
    """
    try:
        st = os.stat(path)
    except OSError:
        return "unreadable"
    size = float(st.st_size)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024 or unit == "TB":
            break
        size /= 1024
    when = datetime.datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M")
    return f"{size:.1f} {unit}, saved {when}"


@dataclass
class _DeviceRow:
    """The widgets of ONE device row, kept addressable after the table is built.

    QTableWidget hands cell widgets back only by (row, column), so a page that
    re-arms eight controls per row on every state change would otherwise repeat
    that lookup with column numbers at each call site — exactly what the symbolic
    column constants above exist to prevent. It keeps the handles instead.
    """
    dev: qemu_devices.Device
    user: QtWidgets.QComboBox
    shell: QtWidgets.QPushButton
    start: QtWidgets.QPushButton
    stop: QtWidgets.QPushButton
    qmp: dict[str, QtWidgets.QPushButton] = field(default_factory=dict)
    save: QtWidgets.QPushButton | None = None
    overwrite: QtWidgets.QPushButton | None = None
    #: The INLINE arming for Overwrite — a tick, never a dialog: a modal in page
    #: logic hangs the headless tests, and the confirmation has to live where the
    #: thing it guards is, so the operator can see what is armed without a click.
    arm: QtWidgets.QCheckBox | None = None
    #: This device's existing saves, newest first, as of the last table rebuild.
    #: Cached rather than re-scanned inside ``_sync_device_buttons`` because that
    #: runs on every re-arm (each verb start and finish) while the set of files can
    #: only change when a save itself finishes — which reloads the table anyway.
    saves: list[str] = field(default_factory=list)
    #: What the EMULATOR last said it was doing ("paused"/"running"/a rarer QEMU
    #: status), or "" for not known. Distinct from ``dev.state``: see ``_state_cell``.
    run_state: str = ""

    @property
    def can_shell(self) -> bool:
        """Whether a login is even expressible for this row.

        Four independent conditions, and ALL are load-bearing. A device that is not
        running has no sshd behind the port; a device whose record says
        ``ssh_host_port: 0`` published no port at all, and core.qemu_devices.ssh_argv
        emits that 0 verbatim on purpose (there is no fallback to 22, because on this
        host 127.0.0.1:22 is the operator's OWN workstation sshd). Enabling the
        button in that state would spawn a terminal running ``ssh -p 0``.

        The third: a record can carry a published port and an empty ``ssh_key`` —
        the entrypoint writes the record from several states, and only a complete one
        is loginable. ``ssh -i ''`` does not fall back to the agent or to ~/.ssh, it
        fails on an unreadable identity file, so the button would open a terminal
        that only ever prints an error.

        The fourth is the paused guest. Its container is up and its port is still
        published, so every other check passes — but its vCPUs are frozen, so sshd
        never answers and the terminal that opened would sit there until it timed
        out. That reads as a broken device rather than as the pause the operator
        asked for, so the button is greyed with a tooltip that says Resume first.
        """
        return (self.dev.is_running
                and self.run_state != _RUN_PAUSED
                and self.dev.ssh_host_port > 0
                and bool(self.dev.ssh_key))

    @property
    def can_save(self) -> bool:
        """Whether a save is expressible for this row.

        The device has to be RUNNING, and that is not a UI nicety: while QEMU holds
        the overlay it holds a write lock on it, so nothing outside that process can
        read the disk (measured on qemu 10.2.3: ``qemu-img convert`` on a live
        overlay fails with `Failed to get shared "write" lock`, and so does
        ``qemu-img commit``). A save therefore happens INSIDE the running emulator as
        a QMP block job, and a stopped row has no emulator to ask.

        "Running" is NOT the whole rule, though, and this deliberately defers the rest
        to ``core.qemu_devices.can_save``. That predicate also demands a container name
        and a QMP socket, because the runner reaches the emulator through
        ``docker exec`` on the former and speaks the block job over the latter. A
        record can carry ``state: running`` with either missing — a device started
        without ``--qmp``, or one whose record was written before the container was
        named — and a row that only checked "running" enabled Save on it, which then
        died in the runner with "device has no qmp socket recorded". Two predicates
        that disagree about the same question are how a button comes to promise
        something the thing behind it refuses.
        """
        return (self.dev.is_running and _save_supported()
                and qemu_devices.can_save(self.dev))

    @property
    def overwrite_target(self) -> str:
        """The save that Overwrite would destroy, or "" when there is none yet."""
        return self.saves[0] if self.saves else ""


def _button_strip(buttons: tuple[QtWidgets.QPushButton, ...]) -> QtWidgets.QWidget:
    """Several buttons in ONE table cell. setCellWidget takes a single widget, so
    the group needs a container; the zero margins keep the row the same height as
    the plain-text cells beside it."""
    holder = QtWidgets.QWidget()
    lay = QtWidgets.QHBoxLayout(holder)
    lay.setContentsMargins(0, 0, 0, 0)
    lay.setSpacing(2)
    for b in buttons:
        lay.addWidget(b)
    return holder


class _DeviceJob:
    """ONE runner subcommand, spawned so that it can actually be CANCELLED.

    The device lane needs the same process hygiene as QemuTestRunner, for the same
    two reasons, and an earlier revision of this page had neither:

    * ``start_new_session`` — the runner spawns docker containers, so a cancel must
      signal the whole process GROUP rather than just the shell that is holding the
      pipe. QemuTestRunner spawns with it and kills with ``killpg`` for exactly this;
      a device verb that ran without it left the group unreachable.
    * a real cancel — ``Start`` re-enters the boot path (``--keep-alive --only``),
      which is a FULL emulated boot and can run for many minutes. A page that greys
      Next while such a verb runs must be able to stop it; a Cancel button wired to
      something with no live process is a control that lies.

    The Popen handle is published under a lock because ``cancel()`` is called from
    the GUI thread while ``run()`` is executing on the worker thread, and a cancel
    that lands in the window before the spawn must still be honoured — hence the
    ``_cancelled`` flag being checked before spawning, not only after.
    """

    def __init__(self, argv: list[str], cwd: str):
        self.argv = list(argv)
        self.cwd = cwd
        self._proc: subprocess.Popen | None = None
        self._lock = threading.Lock()
        self._cancelled = False

    @property
    def cancelled(self) -> bool:
        return self._cancelled

    def run(self, on_line) -> bool:
        with self._lock:
            if self._cancelled:
                on_line("!! cancelled before the command started")
                return False
            try:
                self._proc = subprocess.Popen(
                    self.argv, cwd=self.cwd, stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT, text=True, bufsize=1,
                    start_new_session=True)
            except OSError as exc:
                on_line(f"!! could not run {self.argv[0]}: {exc}")
                return False
            proc = self._proc
        assert proc.stdout is not None
        for line in proc.stdout:
            on_line(line.rstrip("\n"))
        rc = proc.wait()
        # A cancelled verb did not succeed even if the terminated process happened
        # to exit 0 — the caller re-reads the registry either way, so this only
        # decides whether the log says "done" or "FAILED".
        return rc == 0 and not self._cancelled

    def cancel(self) -> None:
        """Terminate the command's whole process group (docker children included)."""
        with self._lock:
            self._cancelled = True
            proc = self._proc
        if proc is None or proc.poll() is not None:
            return
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except OSError:
            # ProcessLookupError is an OSError: the group is already gone. Fall back
            # to the plain terminate in case the session never got created.
            try:
                proc.terminate()
            except OSError:
                pass


class QemuPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("QEMU emulated-device tests")
        self.setSubTitle(
            "Boot built images as emulated devices in Docker and assert they "
            "provisioned correctly — Pi roles first, then x86.")
        self._running = False
        # Whether Cancel has already been pressed for the work now in flight, so a
        # second press reads as "re-sending" rather than repeating itself. Reset by
        # _set_running when new work starts.
        self._cancel_sent = False
        self.worker: _MeshWorker | None = None
        self.runner = QemuTestRunner(wiz.generator_dir)
        # Which of the two cancellable things is in flight, so Cancel can address the
        # right one. None = the matrix runner owns the run.
        self._device_job: _DeviceJob | None = None
        self._sessions: list[qemu_tests.BuildSession] = []
        self._device_rows: list[_DeviceRow] = []
        # What the emulator last SAID, per device label — never what this page
        # assumes. Written from a status reply and from a pause/resume that
        # actually succeeded; dropped for a label whose guest went away, because a
        # device that boots again is a new guest and inherits nothing.
        self._run_state: dict[str, str] = {}
        # The label whose `--qmp … status` output is being read right now, so a
        # status line is attributed to the row that asked for it rather than to
        # whichever row happens to be first.
        self._status_watch: str = ""
        # Called on the GUI thread when the verb in flight finishes, with
        # (ok, cancelled). Lets a verb re-read what it changed — see _device_done.
        self._verb_finished = None

        lay = scrollable(self)

        # ── docker availability, stated up-front ────────────────────────────────
        self.docker_note = QtWidgets.QLabel()
        self.docker_note.setWordWrap(True)
        self.docker_note.setTextFormat(Qt.TextFormat.RichText)
        # Selectable: under WSL the remedy is a path through Docker Desktop's settings
        # and a .wslconfig stanza — text the operator needs to copy, not retype.
        self.docker_note.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextBrowserInteraction)
        lay.addWidget(self.docker_note)

        # ── acceleration, stated up-front for the SAME reason ───────────────────
        # A run without KVM is not a failure, so this must not block; but it is ~10x
        # slower, and "slower" past a certain point is indistinguishable from a hang.
        # Hidden entirely when KVM works — nothing to say, so nothing said. PLAIN text
        # (the _device_table.platform_note precedent): the remedy is a .wslconfig
        # stanza whose newlines and backslashes must survive verbatim to be copyable.
        self.kvm_note = QtWidgets.QLabel("")
        self.kvm_note.setWordWrap(True)
        self.kvm_note.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse)
        self.kvm_note.setStyleSheet("color: #a05000;")
        self.kvm_note.setVisible(False)
        lay.addWidget(self.kvm_note)

        # ── choice: existing images vs build-then-test ──────────────────────────
        self.source_group = QtWidgets.QGroupBox("What should the tests run against?")
        sg = QtWidgets.QVBoxLayout(self.source_group)
        self.use_existing = QtWidgets.QRadioButton(
            "Images from a previous build session")
        self.use_existing.setToolTip(
            "Boot artifacts that are already on disk. An image build takes hours; "
            "re-testing one must not mean rebuilding it.")
        self.build_first = QtWidgets.QRadioButton(
            "Build new images first, then run these tests")
        self.build_first.setToolTip(
            "Continue into the normal image configuration. The tests run when that "
            "build finishes — the same option BuildPage offers as a checkbox.")
        self.use_existing.setChecked(True)
        sg.addWidget(self.use_existing)
        sg.addWidget(self.build_first)
        lay.addWidget(self.source_group)

        # ── session picker + the rows it implies ────────────────────────────────
        self.session_box = QtWidgets.QGroupBox("Build session")
        sb = QtWidgets.QVBoxLayout(self.session_box)
        self.session_combo = QtWidgets.QComboBox()
        self.session_combo.setToolTip(
            "Sessions holding at least one bootable image. Sessions are minted when a "
            "build starts, so empty ones are hidden rather than offered and refused.")
        self.session_combo.currentIndexChanged.connect(self._session_changed)
        sb.addWidget(self.session_combo)
        self.rows_label = QtWidgets.QLabel()
        self.rows_label.setWordWrap(True)
        sb.addWidget(self.rows_label)
        lay.addWidget(self.session_box)

        # ── run envelope ────────────────────────────────────────────────────────
        knobs = QtWidgets.QGroupBox("Run envelope")
        kg = QtWidgets.QFormLayout(knobs)
        self.platform_combo = QtWidgets.QComboBox()
        self.platform_combo.setToolTip(
            "Restrict the run to one platform. Pi rows always boot first: aarch64 has "
            "no KVM on an x86_64 host, so they are pure emulation and the slowest.")
        kg.addRow("Platforms:", self.platform_combo)

        self.jobs = QtWidgets.QSpinBox()
        self.jobs.setRange(1, 8)
        self.jobs.setValue(2)
        self.jobs.setToolTip(
            "How many emulated devices boot at once. Each one holds its own guest RAM, "
            "so this multiplies the memory below.")
        kg.addRow("Concurrent devices:", self.jobs)

        self.mem = QtWidgets.QSpinBox()
        self.mem.setRange(512, 16384)
        self.mem.setSingleStep(512)
        self.mem.setValue(2048)
        self.mem.setSuffix(" MB")
        kg.addRow("Guest RAM:", self.mem)

        self.timeout = QtWidgets.QSpinBox()
        self.timeout.setRange(300, 10800)
        self.timeout.setSingleStep(300)
        self.timeout.setValue(2400)
        self.timeout.setSuffix(" s")
        self.timeout.setToolTip(
            "How long to wait for the guest to answer SSH. A first boot under ARM "
            "emulation runs a full-filesystem SELinux relabel before sshd starts.")
        kg.addRow("Boot timeout:", self.timeout)

        self.keep_alive = QtWidgets.QCheckBox("Keep devices running after tests")
        self.keep_alive.setToolTip(
            "Adds --keep-alive to the command previewed below. The guests are left "
            "running once their assertions finish, instead of being powered off, and "
            "each one registers itself in the DEVICES table further down so it can be "
            "shelled into and driven. Untick and the run ends exactly as it does today.")
        kg.addRow(self.keep_alive)
        lay.addWidget(knobs)

        # ── the exact command, so nothing is hidden ─────────────────────────────
        self.cmd_view = QtWidgets.QPlainTextEdit()
        self.cmd_view.setReadOnly(True)
        self.cmd_view.setMaximumHeight(56)
        self.cmd_view.setToolTip(
            "The exact command this page runs — copy-pasteable into a terminal.")
        lay.addWidget(self.cmd_view)

        # ── actions ─────────────────────────────────────────────────────────────
        btns = QtWidgets.QHBoxLayout()
        self.list_btn = QtWidgets.QPushButton("List devices")
        self.list_btn.setToolTip("Enumerate what WOULD run. Boots nothing.")
        self.list_btn.clicked.connect(lambda: self._launch(list_only=True))
        self.run_btn = QtWidgets.QPushButton("Run device tests")
        self.run_btn.clicked.connect(lambda: self._launch(list_only=False))
        self.cancel_btn = QtWidgets.QPushButton("Cancel")
        self.cancel_btn.setEnabled(False)
        self.cancel_btn.setToolTip(
            "Terminate whatever this page is running — the matrix run, or a device "
            "verb from the table below — process group and all.")
        self.cancel_btn.clicked.connect(self._cancel)
        btns.addWidget(self.list_btn)
        btns.addWidget(self.run_btn)
        btns.addWidget(self.cancel_btn)
        btns.addStretch(1)
        lay.addLayout(btns)

        # ── results table ───────────────────────────────────────────────────────
        self.results = QtWidgets.QTableWidget(0, 5)
        self.results.setHorizontalHeaderLabels(["Device", "Status", "Passed", "Failed", "Time"])
        self.results.horizontalHeader().setStretchLastSection(True)
        self.results.setEditTriggers(QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
        self.results.setMinimumHeight(140)
        lay.addWidget(self.results)

        # ── live devices: shell in, and drive the guest ──────────────────────────
        # Everything here addresses a device that ALREADY registered itself (the
        # --keep-alive tick above is what leaves guests up long enough to). Start is
        # the one exception and says so on the widget: a stopped row has no container
        # to resume, so starting it is a fresh emulated boot.
        self.devices_box = QtWidgets.QGroupBox("Emulated devices that are up")
        dv = QtWidgets.QVBoxLayout(self.devices_box)
        dev_intro = QtWidgets.QLabel(
            "A device registers itself here as soon as it answers SSH. <b>Shell</b> "
            "opens your desktop terminal on that guest as the login chosen beside "
            "it; the <tt>root</tt> row is that login plus <tt>sudo -i</tt>, because "
            "the guest's sshd ships <tt>PermitRootLogin no</tt> and the assertions "
            "check that it still does. The QEMU buttons act on the EMULATOR — read "
            "each one's tooltip, because under <tt>-no-reboot</tt> a reset ends the "
            "guest rather than restarting it.<br><b>Save disk</b> pauses the guest, "
            "copies its disk and puts the guest back the way it found it. The copy "
            "is <b>crash-consistent</b> — what the device would hold if you pulled "
            "its power lead, not a clean shutdown — and it never writes to the image "
            "the device was built from. <b>Save copy</b> makes a new file; "
            "<b>Overwrite save</b> replaces that device's previous save and is "
            "greyed until you tick <b>arm</b> beside it.")
        dev_intro.setWordWrap(True)
        dev_intro.setTextFormat(Qt.TextFormat.RichText)
        dv.addWidget(dev_intro)

        drow = QtWidgets.QHBoxLayout()
        self.devices_refresh_btn = QtWidgets.QPushButton("Refresh")
        self.devices_refresh_btn.setToolTip(
            "Re-read the device registry under the work dir. Reads files only — "
            "starts nothing, stops nothing.")
        self.devices_refresh_btn.clicked.connect(self._reload_devices)
        drow.addWidget(self.devices_refresh_btn)
        self.devices_stop_all_btn = QtWidgets.QPushButton("Stop all devices")
        self.devices_stop_all_btn.setToolTip(
            "Stop every registered device in one go. Disabled while none is running.")
        self.devices_stop_all_btn.clicked.connect(self._stop_all_devices)
        drow.addWidget(self.devices_stop_all_btn)
        # INLINE, never a dialog: a modal in page logic hangs the headless tests,
        # and "no terminal emulator on this desktop" is a fact to read, not a
        # decision to make. Same reasoning as DeployPage's terminal fallback,
        # which prints the command to run by hand instead of popping a box.
        self.dev_note = QtWidgets.QLabel()
        self.dev_note.setWordWrap(True)
        self.dev_note.setTextFormat(Qt.TextFormat.RichText)
        self.dev_note.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse)
        drow.addWidget(self.dev_note, 1)
        dv.addLayout(drow)

        self.devices = QtWidgets.QTableWidget(0, len(_DEVICE_HEADERS))
        self.devices.setHorizontalHeaderLabels(list(_DEVICE_HEADERS))
        self.devices.horizontalHeader().setStretchLastSection(True)
        self.devices.setEditTriggers(
            QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
        self.devices.setMinimumHeight(140)
        dv.addWidget(self.devices)
        lay.addWidget(self.devices_box)

        # ── streamed log ────────────────────────────────────────────────────────
        self.log = QtWidgets.QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMinimumHeight(160)
        lay.addWidget(self.log)

        for w in (self.use_existing, self.build_first):
            w.toggled.connect(self._source_changed)
        for w in (self.jobs, self.mem, self.timeout):
            w.valueChanged.connect(self._refresh_command)
        self.platform_combo.currentIndexChanged.connect(self._refresh_command)
        self.keep_alive.toggled.connect(self._refresh_command)

    # ── wizard-flow contract (mirrors DeployPage/PhonePage) ─────────────────────
    def nextId(self) -> int:
        # "Build first" rejoins the normal image flow, so this page is only terminal
        # when it is testing images that already exist. -1 is the wizard's
        # skip-walk-safe terminator.
        if self.build_first.isChecked():
            return super().nextId()
        return -1

    def applies_to(self, cfg) -> bool:  # noqa: ARG002 — the hook's fixed signature
        # A WIZARD-transient choice, deliberately absent from cfg (ModePage keeps
        # cfg.mode an IMAGE mode), so this reads the wizard, not cfg.
        return bool(getattr(self.wiz, "qemu_selected", False))

    def isComplete(self) -> bool:
        # Leaving mid-run would orphan the worker's signals into a destroyed page.
        # Cancel is the way out, and it reaches a real process group in BOTH lanes
        # (the matrix runner and a device verb) — see _cancel.
        return not self._running

    def initializePage(self):
        self._refresh_docker_note()
        self._refresh_kvm_note()
        self._reload_sessions()
        self._source_changed()
        self._reload_results()
        # Devices outlive this page: a --keep-alive run from an EARLIER visit (or an
        # earlier Studio session) leaves guests up, so the table is populated on
        # entry rather than only after a run this visit started.
        self._reload_devices()

    def validatePage(self) -> bool:
        """SEED the chaining flag — BuildPage owns it from the moment it is reached.

        cfg.qemu_e2e has two writers: this page's radio and BuildPage's checkbox. That
        is fine going forward and broken on the way back, because collect_all() re-runs
        the validatePage of every VISITED page (wizard.py:262-268) — so every revisit of
        BuildPage used to re-run this method and re-assert the radio over the operator's
        own choice. The live sequence: build-first -> Next (arms) -> BuildPage -> untick
        (clears) -> Back -> Next -> BuildPage.initializePage -> collect_all() -> this
        method re-arms -> build.py:888 re-ticks the box from cfg. The post-build device
        tests then ran after an explicit opt-out, with the checkbox visibly re-ticking
        itself.

        Once BuildPage has been reached its checkbox is the ONLY writer: it is the
        control the operator can actually see, it carries the --env gate, and it is
        strictly later in the flow. Before that it holds no opinion, so the radio seeds it.

        The latch is a durable flag BuildPage sets on the wizard, NOT hasVisitedPage():
        Qt's visited set is a history STACK, and back() pops the page straight back out
        of it. Gating on it therefore looks right and does nothing — on the way forward
        again BuildPage reads as unvisited, this method re-arms, and the bug survives
        unchanged. (Measured: the trace still showed qemu.py validatePage as the writer.)
        """
        if getattr(self.wiz, "qemu_e2e_owned_by_build", False):
            return True
        self.wiz.cfg.qemu_e2e = self.build_first.isChecked()
        return True

    # ── population ──────────────────────────────────────────────────────────────
    def _refresh_docker_note(self):
        ok, why = qemu_tests.docker_available()
        if ok:
            self.docker_note.setText(
                "These tests run inside a <b>privileged Docker container</b>: booting a "
                "golden image means loop-mounting it to lift its kernel out, which needs "
                "root. Container root comes from your <tt>docker</tt> group membership, so "
                "no sudo password is needed.")
        else:
            # ESCAPED, and newlines turned into breaks: the WSL remedy is multi-line and
            # contains `<distro>`, which RichText would otherwise eat as an unknown tag —
            # deleting the one word that tells the operator what to substitute.
            detail = "<br>".join(html.escape(line) for line in why.splitlines())
            self.docker_note.setText(
                f'<b style="color:{WARN}">These tests cannot run on this machine yet.</b> '
                f"{detail}<br>The harness needs Docker because booting an image requires a "
                "root-only loop mount, which a GUI cannot obtain interactively.")
        for w in (self.run_btn, self.list_btn):
            w.setEnabled(ok)

    def _refresh_kvm_note(self):
        """State the acceleration situation — WARN, never block.

        The runner already degrades correctly on its own (``run-qemu-docker.sh`` only
        passes ``--device /dev/kvm`` when it is readable AND writable), so a KVM-less
        host still produces correct results. What it does not do is finish in a
        plausible time: an x86 row under TCG goes from minutes to hours, and an
        operator watching a stalled boot log has no way to tell that from a hang. Under
        WSL2 this is the DEFAULT state — nested virtualisation is off unless a
        .wslconfig stanza turns it on — so saying nothing would strand every Windows
        operator on the slowest possible path with no clue that a fix exists.
        """
        why = self.wiz.host.kvm_blocker()
        self.kvm_note.setText(why)
        self.kvm_note.setVisible(bool(why))

    def _reload_sessions(self):
        self._sessions = qemu_tests.discover_sessions(self.wiz.generator_dir)
        self.session_combo.blockSignals(True)
        self.session_combo.clear()
        for s in self._sessions:
            self.session_combo.addItem(s.summary(), s.path)
        self.session_combo.blockSignals(False)
        if not self._sessions:
            self.rows_label.setText(
                f'<span style="color:{WARN}">No build session under out/sessions/ holds a '
                "bootable image yet.</span> Choose “Build new images first”, or "
                "build on this machine and come back.")
            self.use_existing.setEnabled(False)
            self.build_first.setChecked(True)
        else:
            self.use_existing.setEnabled(True)
        self._session_changed()

    def _current_session(self) -> qemu_tests.BuildSession | None:
        idx = self.session_combo.currentIndex()
        if idx < 0 or idx >= len(self._sessions):
            return None
        return self._sessions[idx]

    def _session_changed(self, *_):
        session = self._current_session()
        self.platform_combo.blockSignals(True)
        self.platform_combo.clear()
        self.platform_combo.addItem("All platforms (Pi first)", "")
        if session:
            for p in sorted(session.platforms, key=qemu_tests.platform_rank):
                self.platform_combo.addItem(p, p)
        self.platform_combo.blockSignals(False)

        if session and session.rows:
            listing = "<br>".join(
                f"&nbsp;&nbsp;<tt>{r.label}</tt> &mdash; {r.basename}"
                + (" <i>(will be decompressed once)</i>" if r.compressed else "")
                for r in session.rows)
            self.rows_label.setText(
                f"<b>{len(session.rows)} emulated device(s)</b> in boot order:<br>{listing}")
        elif session:
            self.rows_label.setText("This session holds no bootable image.")
        self._refresh_command()

    def _source_changed(self, *_):
        existing = self.use_existing.isChecked()
        self.session_box.setVisible(existing)
        self.run_btn.setVisible(existing)
        self.list_btn.setVisible(existing)
        self.results.setVisible(existing)
        # The device console belongs to the run this page performs. On the
        # "build first" arm the run happens on ProgressPage later, so there is
        # nothing here to shell into yet — hidden with the rest of that arm.
        self.devices_box.setVisible(existing)
        if not existing:
            self.rows_label.setText("")
            self.cmd_view.setPlainText(
                "The tests will run automatically when the build you configure next "
                "finishes.")
        else:
            self._refresh_command()
        self.completeChanged.emit()

    # ── command preview ─────────────────────────────────────────────────────────
    def _options(self, *, list_only: bool) -> QemuRunOptions:
        session = self._current_session()
        return QemuRunOptions(
            artifacts_dir=session.path if session else "",
            work_dir=self._work_dir(),
            platform=self.platform_combo.currentData() or "",
            jobs=self.jobs.value(),
            mem_mb=self.mem.value(),
            smp=2,
            timeout_s=self.timeout.value(),
            list_only=list_only,
            # A CONSTRUCTOR argument, not an attribute pinned on afterwards: the
            # preview below and the spawn in _launch both build their argv through
            # qemu_tests.runner_command, which reads the dataclass field. An options
            # object carrying a field the builder does not know about previews and
            # runs a command with no --keep-alive in it, and the device table is then
            # empty forever because nothing was left running to register itself.
            keep_alive=self.keep_alive.isChecked(),
        )

    def _refresh_command(self, *_):
        if not self.use_existing.isChecked():
            return
        self.cmd_view.setPlainText(
            qemu_tests.command_string(self.wiz.generator_dir, self._options(list_only=False)))

    # ── run ─────────────────────────────────────────────────────────────────────
    def _launch(self, *, list_only: bool):
        if self._running:
            return
        opts = self._options(list_only=list_only)
        self.log.clear()
        # This lane is the matrix runner's, so Cancel must address IT and not a
        # device verb left over from earlier.
        self._device_job = None
        self._set_running(True)

        def verb(on_line, _cancel):
            rc = self.runner.run(opts, on_line=on_line)
            return rc == 0, []

        self.worker = _MeshWorker(verb, parent=self, stream=True, cancel=threading.Event())
        self.worker.line.connect(self._on_line)
        self.worker.done.connect(lambda ok: self._on_done(ok, list_only=list_only))
        self.worker.start()

    def _cancel(self):
        """Stop whatever is running — and there are two different things it can be.

        Both lanes spawn with ``start_new_session`` and are killed by process GROUP,
        because both end up with docker children that a signal to the direct child
        alone would leave behind.

        The button deliberately stays ARMED after a click. Cancelling sends SIGTERM
        and nothing here escalates to SIGKILL, so a runner that ignores the first
        signal — a qemu wedged in TCG, a docker pull mid-layer — would be
        uncancellable from the GUI for the rest of the run if one click disarmed it.
        Re-sending is the only escalation the operator has, and ``_set_running``
        still greys the button the moment the work actually ends.
        """
        if not self._running:
            return
        again = self._cancel_sent
        self._cancel_sent = True
        job = self._device_job
        if job is not None:
            self.log.appendPlainText(
                "!! re-sending — the device command has not exited yet" if again else
                "!! cancelling — terminating the device command's process group")
            job.cancel()
            return
        self.log.appendPlainText(
            "!! re-sending — the runner has not exited yet" if again else
            "!! cancelling — stopping the emulated devices")
        self.runner.cancel()

    def _set_running(self, running: bool):
        self._running = running
        if running:
            self._cancel_sent = False          # fresh work, fresh first-cancel wording
        self.run_btn.setEnabled(not running)
        self.list_btn.setEnabled(not running)
        self.cancel_btn.setEnabled(running)
        # A verb in flight owns the log and the worker slot, so the device controls
        # go with it — LocalMeshPage's _set_verbs_enabled greys its own start/stop
        # for the same reason.
        self._sync_device_buttons()
        self.completeChanged.emit()

    def _on_line(self, line: str):
        self.log.appendPlainText(line)
        self._note_run_state(line)

    def _note_run_state(self, line: str):
        """Learn a device's real run-state from a ``--qmp … status`` reply.

        This is the only way the table can tell the truth about a device someone
        paused OUTSIDE the Studio — from a terminal, or in an earlier Studio session
        that has since been closed. Nothing is inferred when the line does not
        parse: the row's run-state simply stays unknown, and the State column says
        that rather than assuming the guest is running.
        """
        if not self._status_watch:
            return
        m = _QMP_STATUS_RE.search(line)
        if m:
            self._run_state[self._status_watch] = m.group(1)

    def _on_done(self, ok: bool, *, list_only: bool):
        self._set_running(False)
        if not list_only:
            self._reload_results()
            # A run is the one thing that changes WHICH devices are registered (the
            # entrypoint writes a record per guest and updates its state), so
            # re-read the registry instead of leaving the previous table on screen.
            self._reload_devices()
        self.log.appendPlainText(
            "== device tests passed ==" if ok else "== device tests reported failures ==")

    def _run_labels(self) -> list[str]:
        """Labels of the rows THIS page would run, under the current filters."""
        session = self._current_session()
        if not session:
            return []
        want = self.platform_combo.currentData() or ""
        return [r.label for r in session.rows if not want or r.platform == want]

    def _reload_results(self):
        work = self._work_dir()
        # Scope to this run's rows. The results dir sits under the persistent work
        # dir and keeps every row ever run, so an unscoped read shows rows from
        # older sessions and other artifacts as if they were this run's outcome.
        results = qemu_tests.read_results(work, labels=self._run_labels())
        self.results.setRowCount(len(results))
        for row, r in enumerate(results):
            status = str(r.get("status", "?"))
            cells = {
                _COL_LABEL: str(r.get("label", "?")),
                _COL_STATUS: status,
                _COL_PASS: str(r.get("assertions_passed", "")),
                _COL_FAIL: str(r.get("assertions_failed", "")),
                _COL_TIME: f"{r.get('duration_s', '')}s",
            }
            for col, text in cells.items():
                item = QtWidgets.QTableWidgetItem(text)
                if col == _COL_STATUS:
                    if status in _STATUS_COLOURS:
                        item.setForeground(QtGui.QColor(_STATUS_COLOURS[status]))
                    item.setToolTip(str(r.get("detail", "")))
                self.results.setItem(row, col, item)
        passed, failed, total = qemu_tests.results_summary(results)
        if total:
            self.results.setToolTip(f"{passed}/{total} device(s) passed, {failed} failed")

    # ── the device console ──────────────────────────────────────────────────────
    def _work_dir(self) -> str:
        return os.path.join(self.wiz.generator_dir, qemu_tests.DEFAULT_WORK_SUBDIR)

    def _reload_devices(self, *_):
        """Re-read the device registry and rebuild the table from it.

        Rebuilt wholesale rather than patched in place: a row's controls are armed
        off the device's state, so a row holding a stale Device would keep offering
        buttons for a guest that has since gone.
        """
        devices = qemu_devices.discover_devices(self._work_dir())
        # A run-state belongs to a GUEST, and a label outlives its guests. Forget the
        # ones that are no longer registered, so a device that is booted again does
        # not inherit "paused" from the run before it and grey its own Pause button.
        live = {dev.label for dev in devices}
        self._run_state = {k: v for k, v in self._run_state.items() if k in live}
        self._device_rows = []
        self.devices.setRowCount(len(devices))
        for r, dev in enumerate(devices):
            self._build_device_row(r, dev)
        self.devices.resizeColumnsToContents()
        self.dev_note.setText("" if devices else (
            f'<span style="color:{MUTED}">No emulated device is registered. Tick '
            "“Keep devices running after tests”, run the tests, and each guest "
            "appears here as soon as it answers SSH.</span>"))
        self._sync_device_buttons()

    def _state_cell(self, dev: qemu_devices.Device) -> tuple[str, str, str]:
        """(text, tooltip, colour) for the State column — registry AND emulator.

        Two different questions hide behind one word here, and conflating them is
        what makes a paused device indistinguishable from a working one:

        * ``dev.state`` is the REGISTRY's answer to "is this device's container up"
          (booting -> running -> assertions -> stopped, written by
          docker-entrypoint.sh);
        * the emulator's run-state answers "are the guest's vCPUs executing", and
          pausing is a QMP verb the entrypoint never sees — so a guest frozen by the
          Pause button on this very row keeps its record at "running" forever.

        So a paused row does NOT say "running". It says PAUSED, in the warning
        colour, and the tooltip explains that the container really is up. When the
        emulator has not been asked (a page just opened on devices from an earlier
        session), the run-state is unknown and the cell says only what the registry
        knows — with a tooltip that says Status is how to find out, rather than
        implying the CPUs were checked.
        """
        registry = dev.state or "unknown"
        known = self._run_state.get(dev.label, "")
        if not dev.is_running:
            return (registry,
                    "From the device registry: this device is not running.", "")
        if not known:
            return (registry,
                    f"Registry state: {registry} — that is the CONTAINER, not the "
                    "guest's CPUs. Nothing has asked this emulator whether it is "
                    "paused; press Status to find out.", "")
        if known == _RUN_RUNNING:
            return (registry,
                    f"Registry state: {registry}. The emulator last reported its "
                    "vCPUs RUNNING.", "")
        if known == _RUN_PAUSED:
            return ("PAUSED",
                    "The guest's vCPUs are FROZEN. Its container is up and its ssh "
                    "port is still published (the registry record still says "
                    f"“{registry}”, because pausing is a QMP verb the entrypoint "
                    "never sees), but nothing inside the guest is executing — ssh "
                    "will not answer until Resume continues it from exactly here.",
                    WARN)
        # Everything else QEMU can report — prelaunch, inmigrate, guest-panicked,
        # io-error … — is shown verbatim rather than being rounded to running or
        # paused, because rounding is how a wedged guest comes to read as a healthy one.
        return (f"qemu: {known}",
                f"Registry state: {registry}. The emulator reports run-state "
                f"“{known}”, which is neither running nor paused.", WARN)

    def _build_device_row(self, r: int, dev: qemu_devices.Device):
        what = f"{dev.platform}/{dev.role}" if dev.role else dev.platform
        # The SSH cell is the operator-visible reason the Shell button on this row is
        # live or not: a record with ssh_host_port 0 published nothing.
        where = (f"{qemu_devices.SSH_HOST}:{dev.ssh_host_port}"
                 if dev.ssh_host_port > 0 else _NO_SSH_PORT)
        state_text, state_tip, state_colour = self._state_cell(dev)
        for col, text in {_DCOL_LABEL: dev.label, _DCOL_WHAT: what,
                          _DCOL_STATE: state_text, _DCOL_SSH: where,
                          _DCOL_CONTAINER: dev.container}.items():
            self.devices.setItem(r, col, QtWidgets.QTableWidgetItem(str(text)))
        self.devices.item(r, _DCOL_STATE).setToolTip(state_tip)
        if state_colour:
            self.devices.item(r, _DCOL_STATE).setForeground(QtGui.QColor(state_colour))
        # The rest of the record, on the widget rather than in prose — these are the
        # HOST paths the operator needs to reach the guest from their own terminal.
        self.devices.item(r, _DCOL_LABEL).setToolTip(
            f"key {dev.ssh_key}\nqmp {dev.qmp}\nstarted {dev.started_at}")

        combo = QtWidgets.QComboBox()
        for login, display in qemu_devices.available_logins(dev, self.wiz.cfg.users):
            combo.addItem(display, login)
        # Root goes LAST and is never the pre-selected row: a one-click Shell button
        # that hands out a root prompt by default gives away a privilege the
        # operator did not ask for on that click.
        combo.addItem("root (via sudo -i)", _ROOT_ROW)
        combo.setToolTip(
            "Logins that exist ON THIS GUEST, labelled with the domain they were "
            f"configured for. “root (via sudo -i)” logs in as {dev.ssh_user} and "
            "elevates there, because the guest refuses a root ssh login outright.")
        self.devices.setCellWidget(r, _DCOL_USER, combo)

        shell = QtWidgets.QPushButton("Shell")
        shell.clicked.connect(lambda _=False, i=r: self._open_shell(i))
        self.devices.setCellWidget(r, _DCOL_SHELL, shell)

        # start/stop are the pair core.qemu_devices.DEVICE_ACTIONS names and
        # device_control_argv validates against; they stay two named buttons rather
        # than a loop because they carry different enable rules and different
        # warnings, which is also how LocalMeshPage presents its own Start/Stop.
        start = QtWidgets.QPushButton("Start")
        stop = QtWidgets.QPushButton("Stop")
        stop.setToolTip("Stop this device through the runner, which owns the "
                        "container name. The row stays listed until the registry "
                        "record says it is gone.")
        start.clicked.connect(lambda _=False, i=r: self._device_control(i, "start"))
        stop.clicked.connect(lambda _=False, i=r: self._device_control(i, "stop"))
        self.devices.setCellWidget(r, _DCOL_POWER, _button_strip((start, stop)))

        # BUILT FROM the exported tuple, in its order — see _QMP_LABELS.
        qmp: dict[str, QtWidgets.QPushButton] = {}
        for command in qemu_devices.QMP_COMMANDS:
            b = QtWidgets.QPushButton(_QMP_LABELS.get(command, command.capitalize()))
            b.setToolTip(_QMP_TOOLTIPS.get(
                command, f"Send the QMP verb “{command}” to this guest's monitor "
                         "socket, through the runner."))
            if command in _QMP_ENDS_GUEST:
                b.setStyleSheet(f"color: {WARN};")
            b.clicked.connect(lambda _=False, i=r, c=command: self._device_qmp(i, c))
            qmp[command] = b
        self.devices.setCellWidget(r, _DCOL_QMP, _button_strip(tuple(qmp.values())))

        # ── save: the safe copy, and the destructive one behind a tick ──────────
        save = QtWidgets.QPushButton("Save copy")
        overwrite = QtWidgets.QPushButton("Overwrite save")
        overwrite.setStyleSheet(f"color: {WARN};")
        # Default OFF, and it goes back to off after every save because the table is
        # rebuilt: arming is per-click consent, not a mode the row stays in.
        arm = QtWidgets.QCheckBox("arm")
        arm.setChecked(False)
        arm.toggled.connect(lambda *_: self._sync_device_buttons())
        save.clicked.connect(lambda _=False, i=r: self._device_save(i, _SAVE_COPY))
        overwrite.clicked.connect(
            lambda _=False, i=r: self._device_save(i, _SAVE_OVERWRITE))
        self.devices.setCellWidget(r, _DCOL_SAVE,
                                   _button_strip((save, overwrite, arm)))

        self._device_rows.append(_DeviceRow(
            dev=dev, user=combo, shell=shell, start=start, stop=stop, qmp=qmp,
            save=save, overwrite=overwrite, arm=arm,
            saves=_saved_copies(self._work_dir(), dev),
            run_state=self._run_state.get(dev.label, "")))

    def _sync_device_buttons(self):
        """Arm each row against what its device can actually do right now.

        A control fired at a guest that is not running cannot succeed — there is no
        container to exec into and no QMP socket to talk to — so the button says so
        by being disabled, rather than by failing after the click. Start is the
        mirror image: it is the one thing a stopped row is for. Shell has the extra
        condition (a published port) that ``_DeviceRow.can_shell`` documents. This is
        LocalMeshPage's rule (its Stop greys out when no mesh is up), applied per
        row because here every row has its own state.
        """
        idle = not self._running
        for row in self._device_rows:
            up = row.dev.is_running
            live = up and idle
            for w in (row.user, row.stop, *row.qmp.values()):
                w.setEnabled(live)
            self._arm_pause_buttons(row, live)
            self._arm_save_buttons(row, idle)
            row.shell.setEnabled(row.can_shell and idle)
            row.start.setEnabled(not up and idle)
            row.start.setToolTip(
                f"Disabled: {row.dev.label} is already running." if up else
                "Boot this device again with --keep-alive. A stopped device has no "
                "container to resume, so this is a FULL emulated boot and can take "
                "many minutes — Cancel above stops it and its containers.")
            if not up:
                for w in (row.shell, row.stop, *row.qmp.values()):
                    w.setToolTip(f"Disabled: {row.dev.label} is not running "
                                 f"(state: {row.dev.state or 'unknown'}).")
            elif row.dev.ssh_host_port <= 0:
                row.shell.setToolTip(
                    f"Disabled: {row.dev.label} published no ssh port (the record "
                    "says ssh_host_port 0), so there is nothing to connect to. "
                    "Devices are published by a --keep-alive run.")
            elif not row.dev.ssh_key:
                # Every branch of this chain has to explain ITSELF: can_shell greys
                # the button for a keyless record too, and without this the row would
                # sit disabled under the "Open the desktop terminal" tooltip below,
                # which reads as a broken button rather than an incomplete record.
                row.shell.setToolTip(
                    f"Disabled: {row.dev.label}'s record names no ssh key, so there "
                    "is no identity to log in with. The key is written by the "
                    "keep-alive run that publishes the device.")
            elif row.run_state == _RUN_PAUSED:
                row.shell.setToolTip(
                    f"Disabled: {row.dev.label} is PAUSED. The port is still "
                    "published and the container is up, but the guest's CPUs are "
                    "frozen, so sshd cannot answer and the terminal would hang "
                    "until it timed out. Resume first.")
            else:
                row.shell.setToolTip(
                    "Open the desktop terminal on this device as the login selected "
                    f"beside it ({qemu_devices.SSH_HOST}:{row.dev.ssh_host_port}).")
        self.devices_refresh_btn.setEnabled(idle)
        self.devices_stop_all_btn.setEnabled(
            idle and any(row.dev.is_running for row in self._device_rows))

    def _arm_pause_buttons(self, row: _DeviceRow, live: bool):
        """Make Pause/Resume agree with what the emulator last said.

        A row that has just been paused must not keep offering Pause as though
        nothing happened — that is the same class of lie as a State column still
        reading "running". So the verb that cannot apply is greyed and says why.

        Only Pause is ever greyed by knowledge, never Resume, and that asymmetry is
        deliberate: this page's belief can be STALE (someone can pause a device from
        a terminal with ``run-qemu-docker.sh --qmp LABEL pause``, and nothing tells
        the GUI). Greying Resume on a belief of "running" would leave the operator
        with no way to un-freeze a guest from here at all, whereas a redundant
        Resume on an already-running guest is a QMP ``cont`` that changes nothing.
        Status re-syncs the belief either way, which is why its tooltip says so.
        """
        pause, resume = row.qmp.get("pause"), row.qmp.get("resume")
        if not live or pause is None or resume is None:
            return                       # the disabled-because-dead tooltips win
        paused = row.run_state == _RUN_PAUSED
        pause.setEnabled(not paused)
        if paused:
            pause.setToolTip(
                f"Disabled: {row.dev.label} is already paused — its vCPUs are "
                "frozen. Resume continues it from exactly here. (If you paused or "
                "resumed it outside the Studio, press Status to re-read the "
                "emulator.)")
            resume.setToolTip("Continue this PAUSED guest from exactly where its "
                              "vCPUs were frozen.")
        else:
            pause.setToolTip(_QMP_TOOLTIPS["pause"])
            resume.setToolTip(_QMP_TOOLTIPS["resume"])

    def _arm_save_buttons(self, row: _DeviceRow, idle: bool):
        """Arm this row's Save copy / Overwrite save, and say what each would do.

        Overwrite has THREE gates and each one is a separate sentence on the widget,
        because a greyed button whose tooltip does not name its own reason reads as
        broken: the device must be up (there is no emulator to ask otherwise), a
        previous save must EXIST (there is nothing to overwrite on a first save), and
        the tick beside it must be armed (this destroys that file, and the arming is
        what makes the destruction a decision rather than a mis-click).

        ``idle`` rather than the row's liveness, exactly as Shell is armed: a verb
        already in flight owns this page's single worker, so nothing may start a
        second one on top of it — including a save, which is the longest of them all.
        """
        save, overwrite, arm = row.save, row.overwrite, row.arm
        if save is None or overwrite is None or arm is None:
            return
        target = row.overwrite_target
        enabled = row.can_save and idle
        save.setEnabled(enabled)
        arm.setEnabled(enabled and bool(target))
        overwrite.setEnabled(enabled and bool(target) and arm.isChecked())
        arm.setToolTip(
            "Arm the overwrite. Off by default, and off again after every save: "
            "this is consent for ONE click, not a mode the row stays in."
            if target else
            f"Nothing to arm: {row.dev.label} has no saved copy yet.")

        if not _save_supported():
            why = ("Saving is not available in this Studio: its "
                   "core.qemu_devices does not provide "
                   + " and ".join(_SAVE_API)
                   + ", which is where a save's target path and naming rules live. "
                     "This page will not invent its own — they would disagree with "
                     "the runner's and could arm Overwrite against the wrong file.")
            save.setToolTip(why)
            overwrite.setToolTip(why)
            return
        if not row.dev.is_running:
            why = (f"Disabled: {row.dev.label} is not running. While QEMU holds a "
                   "device's disk it holds a write LOCK on it, so the disk can only "
                   "be copied from INSIDE the running emulator — a stopped row has "
                   "no emulator to ask.")
            save.setToolTip(why)
            overwrite.setToolTip(why)
            return

        save.setToolTip(
            f"Save {row.dev.label}'s disk to a NEW file. Any copy you saved before "
            "is left exactly as it is.\n\n"
            "The guest is paused for the copy and put back the way it was found "
            "(a device you had paused yourself stays paused). The result is "
            "CRASH-CONSISTENT — the disk as it would be if you pulled the power "
            "lead, NOT a clean shutdown: guest RAM is not in it and no application "
            "is asked to quiesce, so anything mid-write is copied mid-write.\n\n"
            "It copies the data the guest has actually used, so a big disk takes a "
            "while; the page is locked meanwhile and Cancel stops it. The image "
            "this device was built from is never written to.")
        if not target:
            overwrite.setToolTip(
                f"Disabled: {row.dev.label} has no saved copy to overwrite yet. "
                "Use “Save copy” first — this button only ever replaces a previous "
                "SAVE, never the image the device was built from.")
        else:
            overwrite.setToolTip(
                "DESTRUCTIVE — re-saves this device onto its previous save:\n"
                f"    {target}\n    ({_describe_file(target)})\n"
                "That file's current contents are DELETED and replaced with the "
                "disk as it is now. There is no undo and no second copy is kept; if "
                "you want to keep it, press “Save copy” instead.\n\n"
                "Same consistency as “Save copy”: CRASH-CONSISTENT, not a clean "
                "shutdown. Tick “arm” beside this button to enable it."
                + ("" if arm.isChecked() else
                   "\n\nDisabled: “arm” is not ticked."))

    def _shell_target(self, row: _DeviceRow) -> tuple[str, bool]:
        """(login to ssh as, whether to sudo -i once in) for that row's dropdown."""
        if row.user.currentData() == _ROOT_ROW:
            return row.dev.ssh_user, True
        return str(row.user.currentData() or row.dev.ssh_user), False

    def _open_shell(self, index: int):
        """Open the desktop terminal on that device — DETACHED, so nothing blocks.

        start_new_session: the terminal is the operator's session from here on and
        must outlive this page (and the wizard), exactly as CloudDeploy launches
        the destroy TTY. No pipes either — the terminal owns its own tty.
        """
        row = self._device_rows[index]
        if not row.can_shell:
            # The button is disabled in this state, so this is the belt to that
            # braces — it exists because "ssh -p 0" is the one failure the operator
            # could not diagnose from the terminal window that flashed up and died.
            self.dev_note.setText(
                f'<span style="color:{WARN}">{row.dev.label} has no SSH login to '
                "open</span> — it is not running, or its record published no port.")
            return
        login, superuser = self._shell_target(row)
        argv = qemu_devices.ssh_argv(row.dev, login, superuser=superuser)
        cmd = qemu_devices.terminal_argv(argv)
        if cmd is None:
            hint = shlex.join(argv)
            self.dev_note.setText(
                f'<span style="color:{WARN}">No terminal emulator found on this '
                f"desktop.</span> Run this yourself: <tt>{hint}</tt>")
            self.log.appendPlainText(f"[devices] no terminal emulator — run: {hint}")
            return
        try:
            subprocess.Popen(cmd, start_new_session=True)
        except OSError as exc:
            self.dev_note.setText(
                f'<span style="color:{WARN}">Could not open a terminal: {exc}</span>')
            self.log.appendPlainText(f"!! could not open a terminal: {exc}")
            return
        who = f"{login} + sudo -i" if superuser else login
        self.dev_note.setText(f"Opened a terminal on <tt>{row.dev.label}</tt> as "
                              f"<tt>{who}</tt>.")
        self.log.appendPlainText(f"[devices] {shlex.join(cmd)}")

    def _device_control(self, index: int, action: str):
        row = self._device_rows[index]
        if action == "start" and not self._running:
            # Said in the log, not only in a tooltip: this is the one control here
            # that boots an image, and the page is locked while it does.
            self.log.appendPlainText(
                "[devices] a stopped device has no container to resume — this is a "
                "full emulated boot; Cancel stops it.")
        label = row.dev.label

        def finished(ok, _cancelled, lbl=label):
            # Whatever this did, the guest it referred to is not the one whose
            # run-state was recorded: a stop ends it, a start boots a new one. Drop
            # the belief rather than carrying "paused" across a reboot.
            self._run_state.pop(lbl, None)

        self._device_verb(f"{action} {label}",
                          qemu_devices.device_control_argv(
                              self.wiz.generator_dir, row.dev, action),
                          finished=finished)

    def _device_qmp(self, index: int, command: str):
        row = self._device_rows[index]
        if self._running:
            # _device_verb would drop this anyway; returning first keeps the status
            # watch below from being armed for a verb that never starts, which would
            # then attribute an unrelated line to this row.
            return
        label = row.dev.label
        # A status reply is read off the STREAM, so the reader has to know whose it
        # is before the first line arrives.
        self._status_watch = label

        def finished(ok, _cancelled, lbl=label, cmd=command):
            self._status_watch = ""
            if not ok:
                return                       # a verb that failed changed nothing
            if cmd == "pause":
                self._run_state[lbl] = _RUN_PAUSED
            elif cmd == "resume":
                self._run_state[lbl] = _RUN_RUNNING
            elif cmd in _QMP_ENDS_GUEST:
                self._run_state.pop(lbl, None)   # that guest is gone

        self._device_verb(f"qmp {command} {label}",
                          qemu_devices.qmp_argv(
                              self.wiz.generator_dir, row.dev, command),
                          finished=finished)

    def _stop_all_devices(self):
        def finished(_ok, _cancelled):
            self._run_state.clear()

        self._device_verb("stop all devices",
                          qemu_devices.stop_all_argv(self.wiz.generator_dir),
                          finished=finished)

    # ── save ────────────────────────────────────────────────────────────────────
    def _device_save(self, index: int, mode: str):
        """Save this device's disk — to a NEW file, or over its previous save.

        Every refusal below is stated INLINE (dev_note + the log) and never as a
        dialog: a modal in page logic hangs the headless tests, and each of these is
        a fact to read rather than a question to answer.

        The arming is re-checked here as well as being greyed in the table, for the
        same reason ``_open_shell`` re-checks ``can_shell``: the guard that matters
        is the one in front of the action, not the one in front of the pixels. It is
        checked before the argv is built, so an unarmed overwrite never becomes a
        command that exists.
        """
        row = self._device_rows[index]
        dev = row.dev
        if not _save_supported():
            self.dev_note.setText(
                f'<span style="color:{WARN}">Saving is not available in this '
                "Studio.</span> Its <tt>core.qemu_devices</tt> provides no "
                + " / ".join(_SAVE_API) + " — that module owns where a save lands "
                "and what it is called, and this page will not guess.")
            return
        if not dev.is_running:
            self.dev_note.setText(
                f'<span style="color:{WARN}">{dev.label} is not running</span>, so '
                "there is no emulator to copy its disk from — QEMU holds a write "
                "lock on it while it is up, and the copy happens inside that process.")
            return

        target = row.overwrite_target
        if mode == _SAVE_OVERWRITE:
            if not target:
                self.dev_note.setText(
                    f'<span style="color:{WARN}">{dev.label} has no saved copy to '
                    "overwrite.</span> Press “Save copy” first — overwrite only ever "
                    "replaces a previous save, never the image the device was built "
                    "from.")
                return
            if row.arm is None or not row.arm.isChecked():
                # NOT a popup: the tick beside the button IS the confirmation, so
                # saying "tick it" inline keeps the answer where the question is.
                self.dev_note.setText(
                    f'<span style="color:{WARN}">Overwrite is not armed.</span> It '
                    f"would DELETE {target} ({_describe_file(target)}) and replace "
                    "it with the disk as it is now. Tick “arm” beside the button to "
                    "allow that, or press “Save copy” to keep both.")
                self.log.appendPlainText(
                    f"[devices] refused: overwrite of {target} is not armed")
                return

        try:
            argv = qemu_devices.save_argv(self.wiz.generator_dir, dev, mode)
        except (TypeError, ValueError) as exc:
            # A mode or signature this tree's core module does not know is a WIRING
            # fault between two layers, and it has to read as one — a save that
            # "failed" would send the operator looking at the device.
            self.dev_note.setText(
                f'<span style="color:{WARN}">This Studio cannot build a “{mode}” '
                f"save command: {exc}</span>")
            self.log.appendPlainText(f"!! save_argv({mode!r}) rejected it: {exc}")
            return

        consistency = ("crash-consistent — the guest is paused for the copy, so the "
                       "result is its disk as if the power lead had been pulled, not "
                       "a clean shutdown")
        if mode == _SAVE_OVERWRITE:
            self.log.appendPlainText(
                f"[devices] OVERWRITING {target} ({_describe_file(target)}) — that "
                f"copy is gone from here on. The new one is {consistency}.")
        else:
            self.log.appendPlainText(
                f"[devices] saving {dev.label} to a NEW file; existing saves are "
                f"left alone. The copy is {consistency}.")
        self.log.appendPlainText(
            "[devices] a big disk takes a while — the page is locked until it "
            "finishes, and Cancel stops it (a cancelled save leaves a PARTIAL file, "
            "which is not a save).")

        before = list(row.saves)
        self._device_verb(
            f"save ({mode}) {dev.label}", argv,
            finished=lambda ok, cancelled, d=dev, m=mode, b=before, t=target:
                self._save_finished(ok, cancelled, d, m, b, t))

    def _save_finished(self, ok: bool, cancelled: bool, dev: qemu_devices.Device,
                       mode: str, before: list[str], target: str) -> str:
        """Report what is ON DISK now, not what the exit status claimed.

        A backup that dies mid-job still leaves a target file behind, so "the runner
        exited 0" and "there is a save you can restore from" are different
        statements. This one re-reads the save directory and says which it got: a
        partial file that looks like a save is the worst outcome available here.

        Returns the note rather than setting it, because _device_done rebuilds the
        table straight afterwards and that rebuild clears dev_note.
        """
        after = _saved_copies(self._work_dir(), dev)
        if not ok:
            why = "cancelled" if cancelled else "FAILED"
            appeared = [p for p in after if p not in before]
            leftover = (target if mode == _SAVE_OVERWRITE and target
                        else (appeared[0] if appeared else ""))
            extra = (f" <tt>{leftover}</tt> may be a PARTIAL copy — do not restore "
                     "from it." if leftover else "")
            return (f'<span style="color:{WARN}">Save {why} for {dev.label}.</span>'
                    + extra)

        if mode == _SAVE_OVERWRITE:
            if not os.path.exists(target):
                return (f'<span style="color:{WARN}">The overwrite of {target} '
                        "reported success, but that file is not there now.</span> "
                        f"Treat {dev.label} as NOT saved.")
            return (f"Overwrote <tt>{target}</tt> ({_describe_file(target)}) with "
                    f"{dev.label}'s disk — crash-consistent. The copy that was "
                    "there is gone.")

        new = [p for p in after if p not in before]
        if not new:
            return (f'<span style="color:{WARN}">The save of {dev.label} reported '
                    "success, but no new file appeared where saves are listed."
                    "</span> Do not treat this device as saved until you can see "
                    "the file.")
        return (f"Saved <tt>{dev.label}</tt> to <tt>{new[0]}</tt> "
                f"({_describe_file(new[0])}) — crash-consistent, and any earlier "
                "save was left untouched.")

    def _device_verb(self, label: str, argv: list[str], *, finished=None):
        """Run ONE device subcommand off the GUI thread, streaming into the log.

        The same worker/streaming shape LocalMeshPage's Start/Stop use, and for the
        same reason: these run the runner script, which talks to docker — a GUI that
        freezes on it looks broken. The page's single worker slot is reused, so
        _set_running already blocks a second launch on top of a verb still going,
        and the job is published to ``_device_job`` first so Cancel has something
        real to terminate from the moment the button lights up.

        ``finished(ok, cancelled)`` runs on the GUI thread when it ends, and may
        return a note to show beside the table. It exists so a verb can record what
        it CHANGED (a pause that took, a save that landed) before the table is
        rebuilt — one lane, so a long save is cancellable and locks the page exactly
        as Start already does.
        """
        if self._running or not argv:
            return
        self.log.appendPlainText(f"$ {shlex.join(argv)}")
        job = _DeviceJob(argv, self.wiz.generator_dir)
        self._device_job = job
        self._verb_finished = finished
        self._set_running(True)

        def verb(on_line, _cancel):
            return job.run(on_line), []

        self.worker = _MeshWorker(verb, parent=self, stream=True)
        self.worker.line.connect(self._on_line)
        self.worker.done.connect(lambda ok, lbl=label: self._device_done(ok, lbl))
        self.worker.start()

    def _device_done(self, ok: bool, label: str):
        cancelled = self._device_job is not None and self._device_job.cancelled
        self._device_job = None
        finished, self._verb_finished = self._verb_finished, None
        self._set_running(False)
        outcome = "cancelled" if cancelled else ("done" if ok else "FAILED")
        self.log.appendPlainText(f"== {label}: {outcome} ==")
        # BEFORE the reload: the callback is what the rebuilt rows read their
        # run-state from, so it has to have run by the time they are built.
        note = finished(ok, cancelled) if finished is not None else None
        # Re-read the registry rather than inferring the new state from the exit
        # code: a stop that half-worked still leaves a container behind, and the
        # row must show what IS, not what the verb intended. (LocalMeshPage
        # re-probes after every verb for the same reason.)
        self._reload_devices()
        # AFTER it, because _reload_devices clears dev_note (an old "opened a
        # terminal on …" must not outlive the table it referred to) — a verb's
        # result would otherwise be wiped in the same turn it was written.
        if note:
            self.dev_note.setText(note)

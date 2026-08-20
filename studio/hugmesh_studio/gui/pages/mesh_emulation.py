"""MeshEmulationPage — emulate a WHOLE mesh locally from one build session (#50).

The fifth ModePage side-flow (after LOCAL DOCKER MESH, MDM PHONE/QUEST, CLOUD
DEPLOY and QEMU DEVICE TESTS): it builds no image and commits NOTHING to
``cfg.mode``, so ``applies_to()`` reads a transient wizard flag exactly as its
siblings do. The operator ask, condensed: after a mesh's images are built, one
screen that boots EVERY image of a chosen prior session as emulated devices —
per-device rows with status badges per section, per-row actions, ssh in as each
user of each device, the emulated USB KEYS sticks the existing tools already
build, and the emulated mesh's web UI reachable from the desktop browser.

WHAT IS REUSED, DELIBERATELY
----------------------------
Everything that already exists for the single-device test page is driven, not
re-implemented: sessions come from ``qemu_tests.discover_sessions``, live devices
from the registry ``qemu_devices.discover_devices`` reads, assertion verdicts
from ``qemu_tests.read_results``, ssh/terminal argv from ``qemu_devices``, and
the actual boots run tests/qemu/run-qemu-docker.sh with ``--keep-alive`` — the
same flag, through the same argv author. What is NEW lives in
core/mesh_emulation.py: the PLAN (ports, MAC/IP identities, KEYS-image paths,
which row is the front door) and the one mockable process boundary
(``mesh_emulation.spawn``) every runner invocation goes through.

THE WEB FRONT DOOR
------------------
The keep-alive runner publishes exactly one port per device: ssh, on loopback.
The web UI is reached THROUGH it — an ``ssh -N -L`` tunnel from the plan's local
ui_port to the guest's own :443 — so "Open web UI" needs nothing the harness
does not already provide. The button stays greyed until the gateway device's
registry record carries a published port and a key (the tunnel rides both), and
the URL is surfaced as selectable text as well, because a browser the Studio
cannot launch is not a browser the operator cannot use.

Modeless throughout: every refusal is inline (note + log), never a dialog — a
modal in page logic hangs the headless tests (the no-modals rule).
"""
from __future__ import annotations

import os
import shlex
import subprocess
import threading

from ..qt import Qt, QtCore, QtGui, QtWidgets
from .. import console
from ..styles import MUTED, WARN
from ...core import mesh_emulation, qemu_devices, qemu_tests
from ._scroll import scrollable
from .localmesh import _MeshWorker

#: Device-table columns — symbolic, never hardcoded at a call site (progress.py's
#: rule), headers beside them so a column can never be labelled as its neighbour.
(_MCOL_LABEL, _MCOL_ROLE, _MCOL_ARCH, _MCOL_STATUS, _MCOL_SECTIONS, _MCOL_SSH,
 _MCOL_USER, _MCOL_ACTIONS) = range(8)
_HEADERS = ("Device", "Role", "Arch", "Status", "Sections", "SSH", "Login",
            "Actions")

#: Section status -> the colour its badge text reads as. ST_OFF stays the muted
#: theme colour; everything else says something and colours accordingly.
_STATUS_COLOURS = {
    mesh_emulation.ST_OK: "#2e7d32",
    mesh_emulation.ST_FAILED: "#c62828",
    mesh_emulation.ST_PENDING: "#a05000",
}

#: The dropdown row that means "log in and sudo -i" — the same unspellable
#: sentinel the device-test page uses (root ssh is disabled on the guests).
_ROOT_ROW = "\x00root-via-sudo"


class _Row:
    """The live widgets of ONE mesh-device row, addressable after the build.

    Same reasoning as qemu.py's _DeviceRow: QTableWidget only hands cell widgets
    back by (row, column), and this page re-arms several controls per row on
    every registry refresh.
    """

    def __init__(self, planned, user, sections, ssh_btn, start, stop):
        self.planned = planned                      # mesh_emulation.PlannedDevice
        self.dev = None                             # live registry record or None
        self.result = None                          # assertion verdict or None
        self.user = user                            # QComboBox
        self.sections = sections                    # QComboBox (badge list)
        self.ssh_btn = ssh_btn
        self.start = start
        self.stop = stop


class MeshEmulationPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Mesh emulation")
        self.setSubTitle(
            "Boot every image of a finished build session as emulated devices and "
            "drive the whole mesh locally — status per device, ssh logins, the "
            "emulated USB KEYS sticks, and the mesh's web front door.")
        self._running = False
        self._cancel = threading.Event()
        self._docker_ok = False
        self.worker: _MeshWorker | None = None
        self._sessions: list[qemu_tests.BuildSession] = []
        self.plan: mesh_emulation.MeshPlan | None = None
        self._rows: list[_Row] = []
        #: label -> the detached tunnel process (page-lifetime; a tunnel is cheap
        #: and dies with its ssh, so nothing here reaps them beyond re-use checks).
        self._tunnels: dict[str, subprocess.Popen] = {}

        lay = scrollable(self)

        # ── docker availability, stated up-front (the QemuPage courtesy) ────────
        self.docker_note = QtWidgets.QLabel()
        self.docker_note.setWordWrap(True)
        self.docker_note.setTextFormat(Qt.TextFormat.RichText)
        lay.addWidget(self.docker_note)

        # ── which prior session's images (the ask: it FIRST asks this) ──────────
        self.session_box = QtWidgets.QGroupBox("Which build session's images?")
        sb = QtWidgets.QVBoxLayout(self.session_box)
        self.session_combo = QtWidgets.QComboBox()
        self.session_combo.setToolTip(
            "Prior build sessions holding at least one bootable image. The whole "
            "mesh is planned from the one you pick — every image it holds becomes "
            "one emulated device.")
        self.session_combo.currentIndexChanged.connect(self._session_changed)
        sb.addWidget(self.session_combo)
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
            "take many minutes each.")
        self.start_btn.clicked.connect(self._start_mesh)
        self.stop_btn = QtWidgets.QPushButton("Stop all")
        self.stop_btn.setToolTip("Stop every registered device (--stop-all-devices).")
        self.stop_btn.clicked.connect(self._stop_mesh)
        self.refresh_btn = QtWidgets.QPushButton("Refresh")
        self.refresh_btn.setToolTip(
            "Re-read the device registry and the assertion verdicts. Reads files "
            "only — starts nothing, stops nothing.")
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

        # ── the web front door ───────────────────────────────────────────────────
        web = QtWidgets.QHBoxLayout()
        self.web_btn = QtWidgets.QPushButton("Open web UI")
        self.web_btn.clicked.connect(self._open_web_ui)
        web.addWidget(self.web_btn)
        self.web_note = QtWidgets.QLabel()
        self.web_note.setWordWrap(True)
        self.web_note.setTextFormat(Qt.TextFormat.RichText)
        # Selectable: the URL and the tunnel command are for copying, not retyping.
        self.web_note.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse)
        web.addWidget(self.web_note, 1)
        lay.addLayout(web)

        # ── the device table ─────────────────────────────────────────────────────
        self.devices = QtWidgets.QTableWidget(0, len(_HEADERS))
        self.devices.setHorizontalHeaderLabels(list(_HEADERS))
        self.devices.horizontalHeader().setStretchLastSection(True)
        self.devices.setEditTriggers(
            QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
        self.devices.setMinimumHeight(180)
        lay.addWidget(self.devices)

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

    # ── population ──────────────────────────────────────────────────────────────
    def _refresh_docker_note(self):
        ok, why = qemu_tests.docker_available()
        self._docker_ok = ok
        if ok:
            self.docker_note.setText(
                "The devices boot inside a <b>privileged Docker container</b> "
                "(the same harness as the QEMU device tests): booting a golden "
                "image needs a root-only loop mount, which a GUI cannot obtain "
                "interactively.")
        else:
            self.docker_note.setText(
                f'<b style="color:{WARN}">The mesh cannot be emulated on this '
                f"machine yet.</b> {why}")
        self.start_btn.setEnabled(ok and not self._running)

    def _reload_sessions(self):
        self._sessions = qemu_tests.discover_sessions(self.wiz.generator_dir)
        self.session_combo.blockSignals(True)
        self.session_combo.clear()
        for s in self._sessions:
            self.session_combo.addItem(s.summary(), s.path)
        self.session_combo.blockSignals(False)
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
        if session is None:
            self.plan = None
            self._rows = []
            self.devices.setRowCount(0)
            self._sync_controls()
            return
        try:
            self.plan = mesh_emulation.plan_mesh(session, self.wiz.generator_dir)
        except ValueError as exc:
            self.plan = None
            self._rows = []
            self.devices.setRowCount(0)
            self.plan_label.setText(
                f'<span style="color:{WARN}">This session cannot be planned: '
                f"{exc}</span>")
            self._sync_controls()
            return
        gw = self.plan.gateway
        url = mesh_emulation.front_door_url(self.plan)
        self.plan_label.setText(
            f"<b>{len(self.plan.devices)} emulated device(s)</b> planned. Front "
            f"door: <tt>{gw.label if gw else '?'}</tt> &rarr; <tt>{url}</tt> "
            "(via an ssh tunnel over the device's published port).")
        self._build_table()
        self._refresh_reality()

    def _build_table(self):
        """One row per PLANNED device — the plan is the row set, the registry only
        colours it. A mesh row exists before its guest does, so the operator can
        see what WILL boot (and start it) rather than staring at an empty table."""
        assert self.plan is not None
        self._rows = []
        self.devices.setRowCount(len(self.plan.devices))
        for r, planned in enumerate(self.plan.devices):
            for col, text in {_MCOL_LABEL: planned.label, _MCOL_ROLE: planned.role,
                              _MCOL_ARCH: planned.arch}.items():
                self.devices.setItem(r, col, QtWidgets.QTableWidgetItem(str(text)))
            self.devices.item(r, _MCOL_LABEL).setToolTip(
                f"image {os.path.basename(planned.image)}\n"
                f"planned ssh 127.0.0.1:{planned.ssh_port}\n"
                f"planned mesh identity {planned.mac} / {planned.ip}\n"
                f"USB KEYS stick {planned.keys_image}")

            self.devices.setItem(r, _MCOL_STATUS, QtWidgets.QTableWidgetItem(""))
            self.devices.setItem(r, _MCOL_SSH, QtWidgets.QTableWidgetItem(""))

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
            stop.clicked.connect(lambda _=False, i=r: self._stop_device(i))
            holder = QtWidgets.QWidget()
            hl = QtWidgets.QHBoxLayout(holder)
            hl.setContentsMargins(0, 0, 0, 0)
            hl.setSpacing(2)
            for b in (start, stop, ssh_btn):
                hl.addWidget(b)
            self.devices.setCellWidget(r, _MCOL_ACTIONS, holder)

            self._rows.append(_Row(planned, user, sections, ssh_btn, start, stop))
        self.devices.resizeColumnsToContents()

    # ── plan vs reality ─────────────────────────────────────────────────────────
    def _refresh_reality(self, *_):
        """Re-read the registry + verdicts and repaint every row from them.

        The PLAN never changes here — only which of its devices are real right
        now. Rows are patched (not rebuilt) because the row set IS the plan.
        """
        if self.plan is None:
            self._sync_controls()
            return
        live = {d.label: d for d in
                qemu_devices.discover_devices(self.plan.work_dir)}
        results = {str(res.get("label", "")): res for res in
                   qemu_tests.read_results(
                       self.plan.work_dir,
                       labels=[d.label for d in self.plan.devices])}
        for i, row in enumerate(self._rows):
            row.dev = live.get(row.planned.label)
            row.result = results.get(row.planned.label)
            self._paint_row(i, row)
        self._sync_controls()

    def _paint_row(self, r: int, row: _Row):
        st, text = mesh_emulation.device_status(row.dev)
        item = self.devices.item(r, _MCOL_STATUS)
        item.setText(text)
        colour = _STATUS_COLOURS.get(st)
        item.setForeground(QtGui.QColor(colour) if colour
                           else self.devices.palette().text().color())

        where = (f"{qemu_devices.SSH_HOST}:{row.dev.ssh_host_port}"
                 if row.dev is not None and row.dev.ssh_host_port > 0
                 else f"planned :{row.planned.ssh_port}")
        self.devices.item(r, _MCOL_SSH).setText(where)
        self.devices.item(r, _MCOL_SSH).setToolTip(
            "The registry's published port." if row.dev is not None else
            "The plan's port — the registry record is authoritative once the "
            "device is up.")

        gateway = (self.plan is not None
                   and row.planned.label == self.plan.gateway_label)
        stats = mesh_emulation.section_statuses(
            row.planned, row.dev, row.result, gateway=gateway)
        row.sections.blockSignals(True)
        row.sections.clear()
        for section in mesh_emulation.SECTIONS:
            status, detail = stats[section]
            row.sections.addItem(f"{section}: {status}", section)
            idx = row.sections.count() - 1
            row.sections.setItemData(idx, detail, Qt.ItemDataRole.ToolTipRole)
            colour = _STATUS_COLOURS.get(status)
            if colour:
                row.sections.setItemData(idx, QtGui.QBrush(QtGui.QColor(colour)),
                                          Qt.ItemDataRole.ForegroundRole)
        row.sections.blockSignals(False)

        row.user.blockSignals(True)
        row.user.clear()
        if row.dev is not None:
            for login, display in qemu_devices.available_logins(
                    row.dev, self.wiz.cfg.users):
                row.user.addItem(display, login)
            # Root last and never pre-selected — one-click ssh must not hand out
            # a root prompt the operator did not pick.
            row.user.addItem("root (via sudo -i)", _ROOT_ROW)
        row.user.blockSignals(False)

    def _gateway_row(self) -> _Row | None:
        if self.plan is None:
            return None
        for row in self._rows:
            if row.planned.label == self.plan.gateway_label:
                return row
        return None

    def _can_tunnel(self, row: _Row | None) -> bool:
        return (row is not None and row.dev is not None and row.dev.is_running
                and row.dev.ssh_host_port > 0 and bool(row.dev.ssh_key))

    def _sync_controls(self):
        idle = not self._running
        planned = self.plan is not None and bool(self.plan.devices)
        docker_ok = self._docker_ok
        self.start_btn.setEnabled(idle and planned and docker_ok)
        self.stop_btn.setEnabled(
            idle and any(r.dev is not None and r.dev.is_running
                         for r in self._rows))
        self.refresh_btn.setEnabled(idle and planned)
        self.cancel_btn.setEnabled(self._running)
        for row in self._rows:
            up = row.dev is not None and row.dev.is_running
            can_ssh = (up and row.dev.ssh_host_port > 0
                       and bool(row.dev.ssh_key))
            row.start.setEnabled(idle and not up and docker_ok)
            row.start.setToolTip(
                f"Disabled: {row.planned.label} is already running." if up else
                "Boot this one device with --keep-alive — a FULL emulated boot; "
                "Cancel stops it.")
            row.stop.setEnabled(idle and up)
            row.ssh_btn.setEnabled(idle and can_ssh)
            row.user.setEnabled(idle and can_ssh)
            row.ssh_btn.setToolTip(
                "Open the desktop terminal on this device as the login selected "
                f"beside it ({qemu_devices.SSH_HOST}:"
                f"{row.dev.ssh_host_port})." if can_ssh else
                f"Disabled: {row.planned.label} has no reachable ssh yet — it is "
                "not running, or its record published no port/key.")

        gw = self._gateway_row()
        tunnel_ok = idle and self._can_tunnel(gw)
        self.web_btn.setEnabled(tunnel_ok)
        if self.plan is None:
            self.web_note.setText("")
        elif tunnel_ok:
            self.web_btn.setToolTip(
                "Start (or reuse) the ssh tunnel to the gateway's :443 and hand "
                "the URL to your desktop browser.")
            self.web_note.setText(
                f"Front door ready: <tt>{mesh_emulation.front_door_url(self.plan)}"
                "</tt>")
        else:
            self.web_btn.setToolTip(
                "Greyed until the gateway device is up with a published ssh port "
                "— the web tunnel rides it.")
            self.web_note.setText(
                f'<span style="color:{MUTED}">The front door '
                f"(<tt>{self.plan.gateway_label or '?'}</tt>) is not up yet — "
                "start the mesh, then Refresh.</span>")
        self.completeChanged.emit()

    # ── verbs (all through the ONE mockable core spawn) ─────────────────────────
    def _run_verb(self, label: str, argv: list[str]):
        """Run one runner invocation off the GUI thread, streaming into the log.

        Every boot/stop goes through ``mesh_emulation.spawn`` — the module's one
        process boundary — so the whole page is testable with that single
        function mocked. The page's single worker slot blocks a second verb on
        top of a first (the QemuPage discipline).
        """
        if self._running or not argv:
            return
        console.write(self.log, f"$ {shlex.join(argv)}")
        self._cancel = threading.Event()
        self._set_running(True)

        def verb(on_line, _cancel):
            rc = mesh_emulation.spawn(argv, self.wiz.generator_dir,
                                      on_line=on_line, cancel=self._cancel)
            return rc == 0, []

        self.worker = _MeshWorker(verb, parent=self, stream=True)
        self.worker.line.connect(lambda ln: console.write(self.log, ln))
        self.worker.done.connect(lambda ok, lbl=label: self._verb_done(ok, lbl))
        self.worker.start()

    def _verb_done(self, ok: bool, label: str):
        self._set_running(False)
        console.write(self.log, f"== {label}: {'done' if ok else 'FAILED'} ==")
        # Re-read the registry rather than inferring from the exit code: the rows
        # must show what IS (the LocalMeshPage/QemuPage re-probe rule).
        self._refresh_reality()

    def _set_running(self, running: bool):
        self._running = running
        self._sync_controls()

    def _cancel_verb(self):
        if not self._running:
            return
        console.write(self.log,
                      "!! cancelling — terminating the runner's process group")
        self._cancel.set()

    def _start_mesh(self):
        if self.plan is None:
            return
        console.write(self.log,
                      "[mesh] booting every planned device with --keep-alive — "
                      "each is a full emulated boot; Cancel stops the run.")
        self._run_verb("start mesh", mesh_emulation.start_mesh_argv(
            self.wiz.generator_dir, self.plan))

    def _stop_mesh(self):
        self._run_verb("stop all devices",
                       mesh_emulation.stop_mesh_argv(self.wiz.generator_dir))

    def _start_device(self, index: int):
        if self.plan is None:
            return
        row = self._rows[index]
        self._run_verb(f"start {row.planned.label}",
                       mesh_emulation.start_device_argv(
                           self.wiz.generator_dir, self.plan, row.planned))

    def _stop_device(self, index: int):
        row = self._rows[index]
        self._run_verb(f"stop {row.planned.label}",
                       mesh_emulation.stop_device_argv(
                           self.wiz.generator_dir, row.planned))

    # ── ssh + web (desktop-side, detached — the QemuPage _open_shell pattern) ───
    def _open_shell(self, index: int):
        """Desktop terminal on that device as the selected login — DETACHED.

        When no terminal emulator exists the exact ssh command is surfaced
        copy-ready instead (inline, never a dialog), so the login is one paste
        away rather than gone.
        """
        row = self._rows[index]
        if row.dev is None or not row.dev.is_running or \
                row.dev.ssh_host_port <= 0 or not row.dev.ssh_key:
            self.note.setText(
                f'<span style="color:{WARN}">{row.planned.label} has no ssh '
                "login to open</span> — it is not running, or its record "
                "published no port/key.")
            return
        if row.user.currentData() == _ROOT_ROW:
            login, superuser = row.dev.ssh_user, True
        else:
            login = str(row.user.currentData() or row.dev.ssh_user)
            superuser = False
        argv = qemu_devices.ssh_argv(row.dev, login, superuser=superuser)
        cmd = qemu_devices.terminal_argv(argv)
        if cmd is None:
            hint = shlex.join(argv)
            self.note.setText(
                f'<span style="color:{WARN}">No terminal emulator found on this '
                f"desktop.</span> Run this yourself: <tt>{hint}</tt>")
            console.write(self.log, f"[mesh] no terminal emulator — run: {hint}")
            return
        try:
            subprocess.Popen(cmd, start_new_session=True)
        except OSError as exc:
            self.note.setText(
                f'<span style="color:{WARN}">Could not open a terminal: '
                f"{exc}</span>")
            return
        who = f"{login} + sudo -i" if superuser else login
        self.note.setText(
            f"Opened a terminal on <tt>{row.planned.label}</tt> as <tt>{who}</tt>.")
        console.write(self.log, f"[mesh] {shlex.join(cmd)}")

    def _open_web_ui(self):
        """Tunnel to the gateway's :443 (reusing a live tunnel) and open the URL.

        The tunnel is DETACHED like a terminal — it must outlive this page so the
        browser tab keeps working — and the URL + the exact tunnel command are
        surfaced as selectable text either way.
        """
        row = self._gateway_row()
        if not self._can_tunnel(row):
            self.note.setText(
                f'<span style="color:{WARN}">The gateway device is not '
                "reachable yet</span> — start the mesh and Refresh until its row "
                "says up.")
            return
        assert row is not None and self.plan is not None
        url = mesh_emulation.front_door_url(self.plan)
        try:
            argv = mesh_emulation.web_tunnel_argv(row.dev, row.planned)
        except ValueError as exc:
            self.note.setText(f'<span style="color:{WARN}">{exc}</span>')
            return
        existing = self._tunnels.get(row.planned.label)
        if existing is None or existing.poll() is not None:
            try:
                self._tunnels[row.planned.label] = subprocess.Popen(
                    argv, start_new_session=True)
            except OSError as exc:
                self.note.setText(
                    f'<span style="color:{WARN}">Could not start the web '
                    f"tunnel: {exc}</span> Run it yourself: "
                    f"<tt>{shlex.join(argv)}</tt>")
                return
            console.write(self.log, f"[mesh] web tunnel: {shlex.join(argv)}")
        QtGui.QDesktopServices.openUrl(QtCore.QUrl(url))
        self.note.setText(
            f"Front door: <tt>{url}</tt> (self-signed TLS — the browser will "
            f"warn once). Tunnel: <tt>{shlex.join(argv)}</tt>")

"""QemuPage — run the QEMU emulated-device tests, containerized, from the Studio.

This is the fourth ModePage SIDE-FLOW (after LOCAL DOCKER MESH, MDM PHONE/QUEST and
CLOUD DEPLOY): it builds no image and commits NOTHING to ``cfg.mode``, so
``applies_to()`` reads a transient wizard flag exactly as its siblings do.

THE TWO THINGS THIS PAGE OFFERS (the operator ask, verbatim: "run these tests
containerized with qemu using images built in other sessions or start a new build
and then run these emulations after")

  1. USE EXISTING IMAGES — pick any previous build session and boot its artifacts
     as emulated devices right now. This is the common case: image builds take
     hours, so re-testing what is already on disk must not require rebuilding it.

  2. BUILD FIRST, THEN TEST — leave this page into the normal image-configuration
     flow with ``cfg.qemu_e2e`` set, so the tests run against the images that
     build produces. The chaining flag is the SAME one BuildPage exposes, so
     "build then test" means one thing in the Studio, not two.

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

import html
import os
import threading

from ..qt import Qt, QtGui, QtWidgets
from ..styles import WARN
from ...core import qemu_tests
from ...core.qemu_tests import QemuRunOptions, QemuTestRunner
from ._scroll import scrollable
from .localmesh import _MeshWorker

#: Result-table columns. Symbolic, never hardcoded at a call site (progress.py's rule).
_COL_LABEL, _COL_STATUS, _COL_PASS, _COL_FAIL, _COL_TIME = range(5)

#: Status -> the colour it reads as in the results table.
_STATUS_COLOURS = {"PASS": "#2e7d32", "FAIL": "#c62828", "ERROR": "#c62828"}


class QemuPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("QEMU emulated-device tests")
        self.setSubTitle(
            "Boot built images as emulated devices in Docker and assert they "
            "provisioned correctly — Pi roles first, then x86.")
        self._running = False
        self.worker: _MeshWorker | None = None
        self.runner = QemuTestRunner(wiz.generator_dir)
        self._sessions: list[qemu_tests.BuildSession] = []

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
        return not self._running

    def initializePage(self):
        self._refresh_docker_note()
        self._refresh_kvm_note()
        self._reload_sessions()
        self._source_changed()
        self._reload_results()

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
            work_dir=os.path.join(self.wiz.generator_dir, qemu_tests.DEFAULT_WORK_SUBDIR),
            platform=self.platform_combo.currentData() or "",
            jobs=self.jobs.value(),
            mem_mb=self.mem.value(),
            smp=2,
            timeout_s=self.timeout.value(),
            list_only=list_only,
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
        self._set_running(True)

        def verb(on_line, _cancel):
            rc = self.runner.run(opts, on_line=on_line)
            return rc == 0, []

        self.worker = _MeshWorker(verb, parent=self, stream=True, cancel=threading.Event())
        self.worker.line.connect(self._on_line)
        self.worker.done.connect(lambda ok: self._on_done(ok, list_only=list_only))
        self.worker.start()

    def _cancel(self):
        self.runner.cancel()
        self.log.appendPlainText("!! cancelling — stopping the emulated devices")

    def _set_running(self, running: bool):
        self._running = running
        self.run_btn.setEnabled(not running)
        self.list_btn.setEnabled(not running)
        self.cancel_btn.setEnabled(running)
        self.completeChanged.emit()

    def _on_line(self, line: str):
        self.log.appendPlainText(line)

    def _on_done(self, ok: bool, *, list_only: bool):
        self._set_running(False)
        if not list_only:
            self._reload_results()
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
        work = os.path.join(self.wiz.generator_dir, qemu_tests.DEFAULT_WORK_SUBDIR)
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

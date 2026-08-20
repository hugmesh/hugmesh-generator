"""QemuPage — the TEST face of emulation: boot the images, assert, power off, grade.

This is one of the two emulation screens, and after T3 they are two DIFFERENT
screens rather than two copies of one:

  * THIS page is the TEST lane. It runs a build session's rows to completion — boot,
    assert, power off — and shows what each row's verdict actually was. Nothing it
    starts is meant to outlive the run.
  * ``gui/pages/mesh_emulation.py`` is the DEPLOY lane: the standing ``--keep-alive``
    mesh, with the console (ssh, QMP, per-device save, whole-mesh save, the web
    front door). Persistent devices live THERE, and this page says so out loud.

Both slugs survive in the frozen wizard order (``core/config.WIZARD_PAGE_SLUGS``);
what changed is that this one stopped trying to be both.

WHY THE DEVICE CONSOLE LEFT THIS PAGE
--------------------------------------
It was here because ``--keep-alive`` was here, and it grew a SECOND process lane
(its own ``_DeviceJob``) beside the matrix runner's, a second spelling of the
per-device Start (the runner's newest-session guess, filtered by SUBSTRING — so
restarting ``x86/be`` could boot a different build and drag ``be+gpu`` along), and a
"Keep devices running after tests" tick whose tooltip promised the jobs knob would
gate the boots. Every one of those is a place where the two screens could disagree
about the same device. They are now on the mesh page, once, over
``core/emulation``'s single per-device Start contract (``--only-exact``, artifacts
and work dir ALWAYS pinned).

WHAT THIS PAGE OFFERS
---------------------
  1. USE EXISTING IMAGES — pick any previous build session and run its rows now.
     Image builds take hours, so re-testing what is on disk must not mean rebuilding
     it. The picker BADGES partial sessions and preselects the newest COMPLETE one
     (see ``_emulation_common.default_session_index`` for the aborted-session trap
     that rule closes).

  2. BUILD FIRST, THEN TEST — leave into the normal image flow with ``cfg.qemu_e2e``
     set, so the tests run against the images that build produces. The chaining flag
     is the SAME one BuildPage exposes, and the ownership latch in ``validatePage``
     is unchanged.

  3. READ THE VERDICTS HONESTLY — the results table is one row per PLANNED row, fed
     by ``emulation.status()``. A planned row that produced no verdict says
     NO-RESULT instead of vanishing (on 2026-08-19 x86/be and x86/pki simply were
     not in the table); a PASS with zero assertions says SUSPECT and is never green
     (that night six such rows read as green while holding 9-12 real FAILs each);
     a verdict from an earlier boot says STALE. The completion line counts those
     buckets — the old unconditional "== device tests passed ==" reported the
     RUNNER's exit status as if it were the devices' verdict.

  4. ONE ROW, NOT THE FLEET — the per-platform filter this page used to carry is
     GONE, and deliberately: every knob here is a ``RunEnvelope`` field so that the
     preview and the spawn are the same argv, and the envelope has no platform/role
     filter to carry (adding one is a core/emulation change, not a GUI one). Booting
     a single device is what the mesh page's per-device Start is for — pinned to its
     session and addressed with ``--only-exact`` — and the AVC workout below is the
     other single-row lane. The rows listing says so on the page.

  5. THE AVC WORKOUT — attach ``tests/qemu/avc-workout.sh`` to one planned row
     (issue #45): boot it through its launcher, drive the confined workloads and
     harvest every SELinux AVC into a narrowing report. The argv is
     ``emulation.avc_argv``'s, pinned to this plan's session like every other.

WHY CONTAINERIZED (and why the page says so up-front)
------------------------------------------------------
Booting a golden .img means lifting its kernel out of the boot partition, which is a
loop mount, which is root. A GUI cannot answer an interactive sudo prompt, so the
harness runs inside a --privileged container instead — root for anyone in the
``docker`` group. The availability probe is ASYNC now
(``_emulation_common.DockerProbe``): the synchronous one froze the whole window for
up to fifteen seconds against a wedged daemon, before the page had even painted.

Modeless throughout: every refusal is an inline label plus the log, never a dialog —
a modal in page logic hangs the headless tests (the no-modals rule).
"""
from __future__ import annotations

import shlex
import threading

from ..qt import Qt, QtWidgets
from .. import console
from ..styles import MUTED, WARN
from ...core import emulation, qemu_tests
from . import _emulation_common as common
from ._scroll import scrollable
from .localmesh import _MeshWorker

#: Result-table columns. Symbolic, never hardcoded at a call site (progress.py's
#: rule), with the headers beside them so a column cannot be labelled as its
#: neighbour.
(_COL_LABEL, _COL_STATE, _COL_VERDICT, _COL_PASS, _COL_FAIL,
 _COL_DETAIL) = range(6)
_RESULT_HEADERS = ("Device", "State", "Verdict", "Passed", "Failed", "What it says")

#: Where the persistent half of emulation went, said ON the page rather than only
#: in this docstring. One line, always visible on the "use existing images" arm.
_CONSOLE_POINTER = ("Persistent emulated devices live on the Mesh emulation page.")


class QemuPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("QEMU device tests")
        self.setSubTitle(
            "Boot a build session's images as emulated devices, assert they "
            "provisioned correctly and power them off — Pi roles first, then x86.")
        self._running = False
        # Whether Cancel has already been pressed for the work now in flight, so a
        # second press reads as "re-sending" rather than repeating itself.
        self._cancel_sent = False
        self._cancel_event = threading.Event()
        self.worker: _MeshWorker | None = None
        #: What the docker probe last answered. False until it does, and the run
        #: buttons stay greyed meanwhile — offering a run that is about to die at
        #: spawn is exactly what the note above exists to prevent.
        self._docker_ok = False
        self._sessions: list[qemu_tests.BuildSession] = []
        #: The PREVIEW plan — what the current session + envelope would run. Rebuilt
        #: on every knob change; boots nothing.
        self.plan: emulation.EmulationPlan | None = None
        #: The plan of the run that is in flight or last finished. Kept separate
        #: because its EPOCH is what grades a verdict fresh or STALE, and rebuilding
        #: the preview plan (which stamps a new epoch) must not re-grade a run that
        #: already happened.
        self.run_plan: emulation.EmulationPlan | None = None
        self._run_completed = False

        lay = scrollable(self)

        # ── docker availability, stated up-front and probed OFF the GUI thread ───
        self.docker_note = QtWidgets.QLabel()
        self.docker_note.setWordWrap(True)
        self.docker_note.setTextFormat(Qt.TextFormat.RichText)
        # Selectable: under WSL the remedy is a path through Docker Desktop's
        # settings and a .wslconfig stanza — text to copy, not to retype.
        self.docker_note.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextBrowserInteraction)
        lay.addWidget(self.docker_note)
        self.docker_probe = common.DockerProbe(self)
        self.docker_probe.answered.connect(self._docker_answered)

        # ── acceleration, stated up-front for the SAME reason ───────────────────
        # A run without KVM is not a failure, so this must not block; but it is ~10x
        # slower, and "slower" past a certain point is indistinguishable from a hang.
        # Hidden entirely when KVM works. PLAIN text: the remedy is a .wslconfig
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
            "Sessions holding at least one bootable image, newest first. A build "
            "that did not finish its fleet is listed and MARKED — the preselected "
            "one is the newest session whose images are all present.")
        self.session_combo.currentIndexChanged.connect(self._session_changed)
        sb.addWidget(self.session_combo)
        # The PARTIAL warning for a session the operator picked anyway — inline,
        # under the picker it belongs to.
        self.session_note = QtWidgets.QLabel()
        self.session_note.setWordWrap(True)
        self.session_note.setTextFormat(Qt.TextFormat.RichText)
        sb.addWidget(self.session_note)
        self.rows_label = QtWidgets.QLabel()
        self.rows_label.setWordWrap(True)
        sb.addWidget(self.rows_label)
        lay.addWidget(self.session_box)

        # ── run envelope — every knob is a core.emulation.RunEnvelope field ──────
        # Not a local bag: the preview and the spawn both build their argv from the
        # SAME envelope through emulation.run_argv, so a knob the envelope does not
        # carry is a knob that previews and then does not happen.
        self.knobs = QtWidgets.QGroupBox("Run envelope")
        kg = QtWidgets.QFormLayout(self.knobs)

        self.jobs = QtWidgets.QSpinBox()
        self.jobs.setRange(1, 8)
        self.jobs.setValue(2)
        self.jobs.setToolTip(
            "How many emulated devices boot at once. Each one holds its own guest "
            "RAM, so this multiplies the memory below.")
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

        self.assert_timeout = QtWidgets.QSpinBox()
        self.assert_timeout.setRange(0, 7200)
        self.assert_timeout.setSingleStep(60)
        self.assert_timeout.setValue(0)
        self.assert_timeout.setSuffix(" s")
        self.assert_timeout.setSpecialValueText("entrypoint default")
        self.assert_timeout.setToolTip(
            "Wall clock for the IN-GUEST assertion pass (--assert-timeout), which "
            "is a different clock from the boot timeout above. When the assertions "
            "are cut short the row can still be graded PASS with nothing recorded — "
            "that is the SUSPECT verdict below. 0 leaves the entrypoint's own "
            "default, and then the flag is not emitted at all.")
        kg.addRow("Assertion timeout:", self.assert_timeout)

        self.extra_users = QtWidgets.QLineEdit()
        self.extra_users.setPlaceholderText("e.g. alice, bob")
        self.extra_users.setToolTip(
            "Additional wheel logins created on EVERY guest (--extra-user, "
            "repeated once per name). Separate with commas or spaces. These are "
            "the accounts the mesh page's per-device login dropdown can then offer "
            "beyond the payload's own 'tester'.")
        kg.addRow("Extra guest logins:", self.extra_users)

        self.cache_max = QtWidgets.QSpinBox()
        self.cache_max.setRange(0, 4096)
        self.cache_max.setValue(0)
        self.cache_max.setSuffix(" GiB")
        self.cache_max.setSpecialValueText("unbounded")
        self.cache_max.setToolTip(
            "Cap the decompressed-image cache under <work>/images "
            "(--cache-max-gb). Every .img.xz row is decompressed once and KEPT; on "
            "this workstation a full root filesystem has taken the live mesh down "
            "with it. 0 leaves the runner's own unbounded default.")
        kg.addRow("Image cache cap:", self.cache_max)
        lay.addWidget(self.knobs)

        # ── the exact command, so nothing is hidden ─────────────────────────────
        self.cmd_view = QtWidgets.QPlainTextEdit()
        self.cmd_view.setReadOnly(True)
        self.cmd_view.setMaximumHeight(56)
        self.cmd_view.setToolTip(
            "The exact command this page runs — copy-pasteable into a terminal. "
            "Authored by core.emulation.run_argv, the same call the Run button "
            "spawns, so the preview cannot drift from what happens.")
        lay.addWidget(self.cmd_view)

        # ── actions ─────────────────────────────────────────────────────────────
        btns = QtWidgets.QHBoxLayout()
        self.list_btn = QtWidgets.QPushButton("List devices")
        self.list_btn.setToolTip("Enumerate what WOULD run. Boots nothing.")
        self.list_btn.clicked.connect(lambda: self._launch(list_only=True))
        self.run_btn = QtWidgets.QPushButton("Run device tests")
        self.run_btn.setToolTip(
            "Boot every row of the chosen session, run its assertions and power it "
            "off. The verdicts land in the table below as the run reports them.")
        self.run_btn.clicked.connect(lambda: self._launch(list_only=False))
        self.refresh_btn = QtWidgets.QPushButton("Read verdicts")
        self.refresh_btn.setToolTip(
            "Re-read this session's verdicts and device records. Reads files (and "
            "asks the runner what it has registered) — boots nothing, stops nothing.")
        self.refresh_btn.clicked.connect(lambda: self._reload_results())
        self.cancel_btn = QtWidgets.QPushButton("Cancel")
        self.cancel_btn.setEnabled(False)
        self.cancel_btn.setToolTip(
            "Terminate what this page is running — process group and all, so the "
            "runner's docker children go with it.")
        self.cancel_btn.clicked.connect(self._cancel)
        for b in (self.list_btn, self.run_btn, self.refresh_btn, self.cancel_btn):
            btns.addWidget(b)
        btns.addStretch(1)
        lay.addLayout(btns)

        # ── the SELinux AVC workout, over ONE planned row (issue #45) ────────────
        avc = QtWidgets.QHBoxLayout()
        self.avc_combo = QtWidgets.QComboBox()
        self.avc_combo.setToolTip(
            "Which planned row the AVC workout boots. One row, not the fleet — the "
            "workout drives the confined workloads and narrows the policy from what "
            "that one machine actually denied.")
        self.avc_btn = QtWidgets.QPushButton("Attach AVC workout")
        self.avc_btn.setToolTip(
            "Run tests/qemu/avc-workout.sh against the row beside it: boot it "
            "through its own launcher, drive the confined workloads and harvest "
            "every SELinux AVC into a narrowing report. A FULL emulated boot — "
            "Cancel stops it and its containers.")
        self.avc_btn.clicked.connect(self._launch_avc)
        avc.addWidget(QtWidgets.QLabel("SELinux AVC workout:"))
        avc.addWidget(self.avc_combo)
        avc.addWidget(self.avc_btn)
        avc.addStretch(1)
        lay.addLayout(avc)

        # ── where the persistent half lives ─────────────────────────────────────
        self.console_pointer = QtWidgets.QLabel(
            f'<span style="color:{MUTED}">{_CONSOLE_POINTER}</span> This page boots '
            "rows, asserts and powers them off; to keep guests up and shell into "
            "them, save their disks or reach the mesh's web front door, use "
            "<b>Mesh emulation</b> on the first screen.")
        self.console_pointer.setWordWrap(True)
        self.console_pointer.setTextFormat(Qt.TextFormat.RichText)
        lay.addWidget(self.console_pointer)

        # ── results: one row per PLANNED row, graded by core.emulation ──────────
        self.results = common.make_table(_RESULT_HEADERS)
        self.results.setToolTip(
            "One row per PLANNED device — including the ones that produced nothing. "
            "PASS is the only green verdict there is.")
        lay.addWidget(self.results)

        self.note = QtWidgets.QLabel()
        self.note.setWordWrap(True)
        self.note.setTextFormat(Qt.TextFormat.RichText)
        self.note.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse)
        lay.addWidget(self.note)

        # ── streamed log ────────────────────────────────────────────────────────
        self.log = console.attach(QtWidgets.QPlainTextEdit())
        self.log.setReadOnly(True)
        self.log.setMinimumHeight(160)
        lay.addWidget(self.log)

        for w in (self.use_existing, self.build_first):
            w.toggled.connect(self._source_changed)
        for w in (self.jobs, self.mem, self.timeout, self.assert_timeout,
                  self.cache_max):
            w.valueChanged.connect(self._refresh_command)
        self.extra_users.textChanged.connect(self._refresh_command)

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
        # Cancel is the way out, and it reaches a real process group.
        return not self._running

    def initializePage(self):
        self._refresh_docker_note()
        self._refresh_kvm_note()
        self._reload_sessions()
        self._source_changed()

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

    # ── docker / kvm notes ──────────────────────────────────────────────────────
    def _refresh_docker_note(self):
        """Paint what is known now, then probe OFF the GUI thread for the rest."""
        self._docker_answered_paint(self.docker_probe.answer)
        self.docker_probe.start()

    def _docker_answered(self, ok: bool, why: str):
        self._docker_answered_paint((bool(ok), str(why)))

    def _docker_answered_paint(self, answer):
        self.docker_note.setText(common.docker_note_html(answer))
        # While the answer is unknown the buttons stay DISABLED: offering a run that
        # is about to fail at spawn is the courtesy this note exists to extend, and
        # the probe's grace window means the unknown state is normally never seen.
        ok = bool(answer and answer[0])
        self._docker_ok = ok
        self._sync_controls()

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

    # ── population ──────────────────────────────────────────────────────────────
    def _reload_sessions(self):
        self._sessions = qemu_tests.discover_sessions(self.wiz.generator_dir)
        common.populate_sessions(self.session_combo, self._sessions)
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
        self.session_note.setText(common.partial_note(session))
        if session and session.rows:
            listing = "<br>".join(
                f"&nbsp;&nbsp;<tt>{r.label}</tt> &mdash; {r.basename}"
                + (" <i>(will be decompressed once)</i>" if r.compressed else "")
                for r in session.rows)
            self.rows_label.setText(
                f"<b>{len(session.rows)} emulated device(s)</b> in boot order:<br>"
                f"{listing}<br><i>All of them run. There is no per-platform filter "
                "on this lane — a single device is booted from <b>Mesh "
                "emulation</b>'s per-device Start, or through the AVC workout "
                "below.</i>")
        elif session:
            self.rows_label.setText("This session holds no bootable image.")
        # A new session is a new plan, so the run this page last performed no longer
        # describes what is on screen — drop it rather than grade one session's rows
        # against another session's epoch.
        self.run_plan = None
        self._run_completed = False
        self._refresh_command()
        self._reload_results(probe=False)

    def _source_changed(self, *_):
        existing = self.use_existing.isChecked()
        for w in (self.session_box, self.knobs, self.cmd_view, self.results,
                  self.console_pointer):
            w.setVisible(existing)
        for w in (self.run_btn, self.list_btn, self.refresh_btn, self.avc_btn,
                  self.avc_combo):
            w.setVisible(existing)
        if not existing:
            self.rows_label.setText("")
            self.cmd_view.setPlainText(
                "The tests will run automatically when the build you configure next "
                "finishes.")
        else:
            self._refresh_command()
        self._sync_controls()
        self.completeChanged.emit()

    # ── the plan, and the command it implies ────────────────────────────────────
    def _extra_users(self) -> tuple[str, ...]:
        """The extra-login field as the runner's repeated --extra-user values.

        Commas OR spaces, because an operator typing a list will use whichever they
        reach for first; empty pieces are dropped so a trailing comma cannot become
        an ``--extra-user ''`` that the runner would then try to create.
        """
        raw = self.extra_users.text().replace(",", " ").split()
        seen: list[str] = []
        for name in raw:
            if name and name not in seen:
                seen.append(name)
        return tuple(seen)

    def _envelope(self) -> emulation.RunEnvelope:
        return emulation.RunEnvelope(
            jobs=self.jobs.value(), mem_mb=self.mem.value(), smp=2,
            timeout_s=self.timeout.value(),
            assert_timeout_s=self.assert_timeout.value(),
            extra_users=self._extra_users(),
            cache_max_gb=self.cache_max.value())

    def _build_plan(self) -> emulation.EmulationPlan | None:
        """The preview plan for the current session + envelope. Boots nothing."""
        session = self._current_session()
        if session is None:
            self.plan = None
            return None
        try:
            self.plan = emulation.plan(self.wiz.generator_dir, session,
                                       emulation.EmulationMode.TEST,
                                       self._envelope())
        except ValueError as exc:
            self.plan = None
            self.note.setText(f'<span style="color:{WARN}">This session cannot be '
                              f"planned: {exc}</span>")
        return self.plan

    def _refresh_command(self, *_):
        if not self.use_existing.isChecked():
            return
        plan = self._build_plan()
        if plan is None:
            self.cmd_view.setPlainText("")
            self.avc_combo.clear()
            return
        self.cmd_view.setPlainText(
            " ".join(shlex.quote(a) for a in emulation.run_argv(plan)))
        want = self.avc_combo.currentData()
        self.avc_combo.blockSignals(True)
        self.avc_combo.clear()
        for label in plan.labels:
            self.avc_combo.addItem(label, label)
        if want in plan.labels:
            self.avc_combo.setCurrentIndex(plan.labels.index(want))
        self.avc_combo.blockSignals(False)
        self._sync_controls()

    # ── run ─────────────────────────────────────────────────────────────────────
    def _launch(self, *, list_only: bool):
        """Run the whole matrix (or just enumerate it) through the ONE spawn.

        The plan is minted HERE rather than reused from the preview, because its
        epoch is the line between "this run's verdict" and "a verdict that was
        already on disk": ``emulation.status`` grades anything older than the epoch
        STALE, and a stale PASS presented as today's outcome is the failure this
        whole table exists to prevent.
        """
        if self._running:
            return
        plan = self._build_plan()
        if plan is None:
            return
        self.log.clear()
        self.note.setText("")
        if not list_only:
            self.run_plan = plan
            self._run_completed = False
        argv = emulation.run_argv(plan)
        if list_only:
            # --list is not a RunEnvelope field (it is not a knob, it is a different
            # question), so it rides the runner's own options object through the same
            # author every other argv here uses.
            argv = qemu_tests.runner_command(
                plan.generator_dir,
                qemu_tests.QemuRunOptions(artifacts_dir=plan.session_path,
                                          work_dir=plan.work_dir, list_only=True))
        self._run("device tests" if not list_only else "device listing", argv,
                  on_done=None if list_only else self._run_finished)

    def _launch_avc(self):
        """Boot ONE planned row through the SELinux AVC workout (issue #45)."""
        plan = self.plan or self._build_plan()
        label = str(self.avc_combo.currentData() or "")
        if plan is None or not label:
            return
        try:
            argv = emulation.avc_argv(plan, label)
        except ValueError as exc:
            self.note.setText(f'<span style="color:{WARN}">{exc}</span>')
            return
        console.write(self.log,
                      f"[avc] {label}: a full emulated boot plus the confined "
                      "workloads — Cancel stops it and its containers.")
        self._run(f"avc workout {label}", argv)

    def _run(self, label: str, argv: list[str], *, on_done=None):
        """One argv, off the GUI thread, through ``emulation.spawn`` and nothing else.

        ``spawn`` is THE process boundary the facade documents: it is what the tests
        replace, and routing every verb through it is what keeps this page runnable
        with no docker, no qemu and no images. The page's single worker slot blocks a
        second verb on top of a first (the LocalMeshPage discipline).
        """
        if self._running or not argv:
            return
        console.write(self.log, f"$ {shlex.join(argv)}")
        self._cancel_event = threading.Event()
        self._set_running(True)

        def verb(on_line, _cancel):
            rc = emulation.spawn(argv, self.wiz.generator_dir, on_line=on_line,
                                 cancel=self._cancel_event)
            return rc == 0, []

        self.worker = _MeshWorker(verb, parent=self, stream=True)
        self.worker.line.connect(lambda ln: console.write(self.log, ln))
        self.worker.done.connect(
            lambda ok, lbl=label, cb=on_done: self._verb_done(ok, lbl, cb))
        self.worker.start()

    def _verb_done(self, ok: bool, label: str, on_done):
        # The CANCEL EVENT is not the answer to "was this cancelled": emulation.spawn
        # sets it on the way out to release its own watcher thread, so every normal
        # completion leaves it set. What was cancelled is what the operator pressed
        # Cancel on, which is exactly what _cancel_sent records — and _set_running
        # clears it when new work starts.
        cancelled = self._cancel_sent
        self._set_running(False)
        outcome = "cancelled" if cancelled else ("done" if ok else "FAILED")
        console.write(self.log, f"== {label}: {outcome} ==")
        if on_done is not None:
            on_done(ok, cancelled)

    def _run_finished(self, _ok: bool, cancelled: bool):
        """What the RUN said, from the verdicts rather than from the exit status.

        A cancelled run is not a completed one, so NO-RESULT is NOT synthesized for
        it: every row the cancel cut short would otherwise be accused of having
        produced nothing, when what happened is that it was stopped.
        """
        self._run_completed = not cancelled
        st = self._reload_results()
        if st is None:
            return
        console.write(self.log, f"== {common.status_summary(st)} ==")

    def _cancel(self):
        """Stop what is running — and keep the button ARMED afterwards.

        Cancelling sends SIGTERM to the process GROUP (the runner spawns docker
        children, so signalling the shell alone would orphan them) and nothing here
        escalates to SIGKILL. A runner that ignores the first signal — a qemu wedged
        in TCG, a docker pull mid-layer — would be uncancellable from the GUI for the
        rest of the run if one click disarmed the button. Re-sending is the only
        escalation the operator has; ``_set_running`` greys the button the moment the
        work actually ends.
        """
        if not self._running:
            return
        again = self._cancel_sent
        self._cancel_sent = True
        console.write(self.log,
                      "!! re-sending — the runner has not exited yet" if again else
                      "!! cancelling — terminating the runner's process group")
        self._cancel_event.set()

    def _set_running(self, running: bool):
        self._running = running
        if running:
            self._cancel_sent = False          # fresh work, fresh first-cancel wording
        self._sync_controls()
        self.completeChanged.emit()

    def _sync_controls(self):
        idle = not self._running
        docker_ok = getattr(self, "_docker_ok", False)
        planned = self.plan is not None and bool(self.plan.rows)
        for w in (self.run_btn, self.list_btn):
            w.setEnabled(idle and docker_ok and planned)
        self.avc_btn.setEnabled(idle and docker_ok and planned
                                and bool(self.avc_combo.currentData()))
        self.refresh_btn.setEnabled(idle)
        self.cancel_btn.setEnabled(self._running)

    # ── verdicts ────────────────────────────────────────────────────────────────
    def _reload_results(self, *, probe: bool = True) -> emulation.MeshStatus | None:
        """Repaint the results table from ``emulation.status()``.

        One row per PLANNED label, ALWAYS — that is the whole point. The old table
        rendered the result FILES it found, so a planned row that produced nothing
        was indistinguishable from a row that was never planned, and on 2026-08-19
        two x86 rows simply vanished from a run that reported success.

        ``probe=False`` paints the plan's rows without asking the facade anything,
        which is what a session change does: swapping the picker must repaint at
        once and must not shell out.
        """
        plan = self.run_plan or self.plan
        if plan is None:
            self.results.setRowCount(0)
            return None
        if not probe:
            self._paint_planned(plan)
            return None
        st = emulation.status(plan, run_completed=self._run_completed)
        self.results.setRowCount(len(st.rows))
        for r, row in enumerate(st.rows):
            result = row.result or {}
            common.set_cell(self.results, r, _COL_LABEL, row.label,
                            tooltip=self._row_tooltip(row))
            common.set_cell(self.results, r, _COL_STATE, row.state,
                            colour=common.state_colour(row.state))
            common.set_cell(
                self.results, r, _COL_VERDICT, common.verdict_text(row.verdict),
                colour=common.verdict_colour(row.verdict),
                tooltip=common.VERDICT_TOOLTIPS.get(row.verdict, row.detail))
            common.set_cell(self.results, r, _COL_PASS,
                            str(result.get("assertions_passed", "")))
            common.set_cell(self.results, r, _COL_FAIL,
                            str(result.get("assertions_failed", "")))
            common.set_cell(self.results, r, _COL_DETAIL, row.detail,
                            tooltip=row.detail)
        self.results.resizeColumnsToContents()
        self.results.setToolTip(st.summary())
        return st

    def _paint_planned(self, plan: emulation.EmulationPlan):
        """The plan's rows, before anything has been asked of the filesystem."""
        self.results.setRowCount(len(plan.rows))
        for r, row in enumerate(plan.rows):
            common.set_cell(self.results, r, _COL_LABEL, row.label)
            common.set_cell(self.results, r, _COL_STATE, emulation.STATE_PLANNED,
                            colour=common.state_colour(emulation.STATE_PLANNED))
            common.set_cell(self.results, r, _COL_VERDICT, common.PENDING_TEXT)
            for col in (_COL_PASS, _COL_FAIL):
                common.set_cell(self.results, r, col, "")
            common.set_cell(self.results, r, _COL_DETAIL,
                            "planned — press “Read verdicts” or run the tests")
        self.results.resizeColumnsToContents()

    def _row_tooltip(self, row: emulation.DeviceStatus) -> str:
        dev = row.device
        if dev is None:
            return f"{row.label}: no device record under this run's work dir."
        return (f"container {dev.container}\nimage {dev.image}\n"
                f"artifacts {dev.artifacts}\nstarted {dev.started_at}")

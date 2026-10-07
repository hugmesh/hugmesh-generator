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

HOW YOU GET HERE, SINCE 2026-08-27
-----------------------------------
This page no longer has a mode-menu card. The operator asked for it to go ("remove
QEMU device emulation menu item as it does not do anything that cannot be done from
the other menu, but add the run e2e tests button") and ``ModePage``'s slot now holds
RUN E2E TESTS. Nothing about THIS page changed: its second radio arm
(``gui/pages/e2e.py::E2EPage``, "Emulated-device test lanes") is what writes
``wiz.qemu_selected`` now, and ``applies_to`` still reads that same flag.

The card was removed; the LANE was not, and could not be — items 5 and 6 below
(``tests/qemu/avc-workout.sh`` and ``tests/qemu/run-qemu-e2e.sh``) have no other door
anywhere in the Studio, and the mesh-emulation page the request pointed at offers
neither. The THIRD route in is unchanged and needs no menu at all: BuildPage's
``cfg.qemu_device_tests`` opt-in, run post-build by ``progress.py::_maybe_qemu_tests``.

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

  2. BUILD FIRST, THEN TEST — leave into the normal image flow with
     ``cfg.qemu_device_tests``
     set, so the tests run against the images that build produces. The chaining flag
     is the SAME one BuildPage exposes, and the ownership latch in ``validatePage``
     is unchanged. Two things make this arm REPORT ITSELF as ineffective if they are
     omitted, and both were: the button bar must be refreshed when the arm is picked
     (``_source_changed``'s ``setFinalPage``), because QWizard caches whether the
     current page can continue and would otherwise leave FINISH on screen with no
     Next to press; and the arm must SAY what Next will do (``chain_note``), because
     every other widget on this page belongs to the other arm and is hidden, so
     picking it otherwise blanks the page. And the arm CHOOSES WHICH BUILD: this route
     never passes the Mode screen, so it used to inherit whatever ``cfg.mode`` an
     earlier flow had committed; ``build_mode_box`` preselects that mode, NAMES it as
     inherited, and ``validatePage`` commits the pick through the Mode screen's own
     ``commit_image_mode``.

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

  6. THE PLAYWRIGHT BROWSER SUITE — ``tests/qemu/run-qemu-e2e.sh`` over ONE planned
     row: boot it, seed the e2e identities over SSH, and drive the UNCHANGED
     ``tests/e2e`` specs against the guest's forwarded UI. That harness has worked for
     months and had NO door anywhere in the Studio (zero references under studio/
     before 2026-08-26); this group is the door. The argv is
     ``emulation.playwright_argv``'s, ``-w`` pinned to this plan's session.

THREE THINGS IN THIS TREE ARE CALLED "e2e", AND THIS PAGE TOUCHES TWO OF THEM
-----------------------------------------------------------------------------
``run-qemu-docker.sh`` runs IN-GUEST ASSERTIONS over a matrix (items 1-3 above, and
the post-build opt-in). ``run-qemu-e2e.sh`` runs PLAYWRIGHT against one booted node
(item 6). ``run-matrix-e2e.sh`` is a third harness nothing here drives. The config
field behind the build-first arm used to be called ``qemu_e2e``, so its checkbox
read as a promise to run the browser suite and delivered the assertions instead; it
is ``cfg.qemu_device_tests`` now, and every label on both screens names its script.

WHY CONTAINERIZED (and why the page says so up-front)
------------------------------------------------------
Booting a golden .img means lifting its kernel out of the boot partition, which is a
loop mount, which is root. A GUI cannot answer an interactive sudo prompt, so the
harness runs inside a --privileged container instead — root for anyone in the
``docker`` group. The availability probe is ASYNC now
(``_emulation_common.DockerProbe``): the synchronous one froze the whole window for
up to fifteen seconds against a hung daemon, before the page had even painted.

Modeless throughout: every refusal is an inline label plus the log, never a dialog —
a modal in page logic hangs the headless tests (the no-modals rule).
"""
from __future__ import annotations

import dataclasses
import html
import shlex
import threading

from ..qt import Qt, QtWidgets
from .. import console
from ..styles import MUTED, WARN, muted
from ...core import emulation, qemu_tests
from ...core.domain_services import session_boot_gate_reason
from ...core.local_stack_node import LocalStackNode
from . import _emulation_common as common
from ._mesh_monitor_widget import MeshMonitorSection
from ._scroll import scrollable
from ._widgets import label_finish_as_exit
from .localmesh import _MeshWorker
from .mode import IMAGE_MODE_TITLES, commit_image_mode

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
        # On the "images that already exist" arm this page is TERMINAL, and its final
        # button does nothing but close the Studio — so it says Exit, not Finish. On
        # the "build first" arm the page is not final and Qt hides the button entirely
        # (_widgets.label_finish_as_exit).
        label_finish_as_exit(self)
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
        #: The per-domain services refusal for the picked session (#637), "" when its
        #: images may boot — core.domain_services.session_boot_gate_reason, the seam
        #: the Mesh emulation page reads too. Listing and previews stay available.
        self._boot_refusal = ""
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
        #: Why an arm is unavailable — ALWAYS visible, and deliberately NOT inside the
        #: session group box. This text used to be written into ``rows_label``, which
        #: lives in that box; picking build-first hides the box AND blanks the label, so
        #: the one sentence telling an operator with no images what to do was erased by
        #: the very choice it was telling them to make.
        self.source_note = QtWidgets.QLabel()
        self.source_note.setWordWrap(True)
        self.source_note.setTextFormat(Qt.TextFormat.RichText)
        self.source_note.setVisible(False)
        sg.addWidget(self.source_note)
        #: What pressing Next will do. Shown ONLY on the build-first arm, where every
        #: other widget on this page is hidden — this line is then the whole page, so it
        #: cannot live in ``cmd_view``, which that same arm hides.
        self.chain_note = QtWidgets.QLabel(
            "The tests will run automatically when the build you configure next "
            "finishes. Press <b>Next</b> to configure that build — the choice is "
            "carried to the Build screen as its “after the build, run the QEMU "
            "emulated-device tests” checkbox, which stays yours to untick there.")
        self.chain_note.setWordWrap(True)
        self.chain_note.setTextFormat(Qt.TextFormat.RichText)
        self.chain_note.setVisible(False)
        sg.addWidget(self.chain_note)
        # WHICH BUILD "Build first" continues into — chosen HERE, explicitly. This
        # route reaches the image flow without passing the Mode screen (its "Run e2e
        # tests" card commits no cfg.mode), so without this the build took whatever
        # mode an EARLIER flow had committed: a mesh walked this morning turned "test
        # a desktop image" into a mesh worklist, and a fresh Studio's default sent a
        # mesh operator down the standalone desktop pages. The inherited mode is
        # preselected AND named, so nothing changes silently; validatePage commits the
        # pick through the Mode screen's own commit_image_mode.
        self.build_mode_box = QtWidgets.QGroupBox("Which image build should run first?")
        bm = QtWidgets.QVBoxLayout(self.build_mode_box)
        self.build_mode_group = QtWidgets.QButtonGroup(self)
        self.build_mode_radios: dict[str, QtWidgets.QRadioButton] = {}
        for mid in ("mesh", "cloud", "standalone"):
            rb = QtWidgets.QRadioButton(IMAGE_MODE_TITLES[mid])
            rb.setProperty("mode", mid)
            self.build_mode_group.addButton(rb)
            self.build_mode_radios[mid] = rb
            bm.addWidget(rb)
        self.build_mode_note = QtWidgets.QLabel("")
        self.build_mode_note.setWordWrap(True)
        self.build_mode_note.setStyleSheet(muted())
        bm.addWidget(self.build_mode_note)
        self.build_mode_box.setVisible(False)
        self.build_mode_group.buttonToggled.connect(self._build_mode_changed)
        sg.addWidget(self.build_mode_box)
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
        # The per-domain services refusal (#637), INLINE under the picker — never a
        # modal. Plain text: it carries operator-typed domain names.
        self.domain_gate_note = QtWidgets.QLabel()
        self.domain_gate_note.setWordWrap(True)
        self.domain_gate_note.setTextFormat(Qt.TextFormat.PlainText)
        self.domain_gate_note.setStyleSheet(f"color: {WARN};")
        self.domain_gate_note.setVisible(False)
        sb.addWidget(self.domain_gate_note)
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

        # ── the Playwright browser suite, over ONE booted row ────────────────────
        # A DIFFERENT harness from everything above: run-qemu-e2e.sh boots the row
        # through launch-x86.sh/launch-pi.sh, seeds the e2e identities over SSH and
        # runs the UNCHANGED tests/e2e specs against the guest's forwarded UI. The
        # group is titled with its script so it cannot be mistaken for the in-guest
        # assertions the buttons above run.
        self.pw_group = QtWidgets.QGroupBox(
            "Playwright browser suite on an emulated device "
            "(tests/qemu/run-qemu-e2e.sh)")
        pw = QtWidgets.QFormLayout(self.pw_group)

        self.pw_row = QtWidgets.QComboBox()
        self.pw_row.setToolTip(
            "Which planned row to boot and drive with a browser. Only rows whose "
            "platform has a launcher in run-qemu-e2e.sh are listed — it wires "
            "launch-x86.sh (x86) and launch-pi.sh (rpi3/4/5) and rejects any other "
            "--target, so a jetson or OrangePi row has no honest entry here.")
        pw.addRow("Device to drive:", self.pw_row)

        self.pw_ui_port = QtWidgets.QSpinBox()
        self.pw_ui_port.setRange(1024, 65535)
        self.pw_ui_port.setValue(emulation.PlaywrightOptions.ui_port)
        self.pw_ui_port.setToolTip(
            "Host port the guest's UI/gateway HTTPS is forwarded to — the specs' "
            "baseURL becomes https://localhost:<this>. Change it if something on "
            "this workstation already owns the default.")
        pw.addRow("Forwarded UI port:", self.pw_ui_port)

        self.pw_ssh_port = QtWidgets.QSpinBox()
        self.pw_ssh_port.setRange(1024, 65535)
        self.pw_ssh_port.setValue(emulation.PlaywrightOptions.ssh_port)
        self.pw_ssh_port.setToolTip(
            "Host port forwarded to the guest's :22. The accounts are seeded over "
            "this, so it must be free too.")
        pw.addRow("Forwarded SSH port:", self.pw_ssh_port)

        self.pw_args = QtWidgets.QLineEdit()
        self.pw_args.setPlaceholderText(
            "e.g. specs/01-frontpage.spec.ts   or   --grep @smoke")
        self.pw_args.setToolTip(
            "Extra argv handed straight to `playwright test`, after the script's "
            "own `--` separator: a spec path, --grep, --repeat-each. Split on "
            "whitespace, so '--grep @smoke' arrives as TWO arguments. It is a "
            "RunEnvelope field, not a widget read at spawn time, so the command "
            "below and the run are built from the same value.")
        pw.addRow("Specs / Playwright args:", self.pw_args)

        self.pw_cmd_view = QtWidgets.QPlainTextEdit()
        self.pw_cmd_view.setReadOnly(True)
        self.pw_cmd_view.setMaximumHeight(72)
        self.pw_cmd_view.setToolTip(
            "The exact command the buttons below run — authored by "
            "core.emulation.playwright_argv, the same call the spawn uses.")
        pw.addRow("Command:", self.pw_cmd_view)

        pwb = QtWidgets.QHBoxLayout()
        self.pw_list_btn = QtWidgets.QPushButton("List specs")
        self.pw_list_btn.setToolTip(
            "Enumerate the boot plan AND the Playwright specs this lane would run, "
            "as JSON. Boots nothing, needs no root and no network — so it works "
            "even from an unprivileged Studio.")
        self.pw_list_btn.clicked.connect(
            lambda: self._launch_playwright(list_only=True))
        self.pw_preview_btn = QtWidgets.QPushButton("Preview (dry run)")
        self.pw_preview_btn.setToolTip(
            "Resolve the artifacts this row would boot from and print the plan. "
            "Boots nothing and needs no root.")
        self.pw_preview_btn.clicked.connect(
            lambda: self._launch_playwright(dry_run=True))
        self.pw_run_btn = QtWidgets.QPushButton("Run Playwright suite")
        self.pw_run_btn.setToolTip(
            "Boot this row, seed the e2e accounts over SSH and run the tests/e2e "
            "specs against its forwarded UI. A FULL emulated boot, and it needs "
            "ROOT — see the line below. Cancel stops it and its children.")
        self.pw_run_btn.clicked.connect(
            lambda: self._launch_playwright(list_only=False))
        for b in (self.pw_list_btn, self.pw_preview_btn, self.pw_run_btn):
            pwb.addWidget(b)
        pwb.addStretch(1)
        pw.addRow("", pwb)

        #: Why the Run button is dead on an unprivileged Studio, stated ON the page
        #: rather than discovered when the script dies — and naming the containerized
        #: route, never sudo (there is no way for a GUI to answer a password prompt).
        #: Inline label, never a dialog: the no-modals rule.
        self.pw_note = QtWidgets.QLabel()
        self.pw_note.setWordWrap(True)
        self.pw_note.setTextFormat(Qt.TextFormat.RichText)
        self.pw_note.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse)
        pw.addRow("", self.pw_note)
        lay.addWidget(self.pw_group)

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

        # ── the running mesh's pods and containers (#336) ────────────────────────
        # The operator asked for the pod table on this screen too. It is a DIFFERENT
        # mesh from the results above — those rows are emulated guests this page boots
        # and powers off, this section is the docker compose project and the kind
        # cluster running on THIS workstation — and the note says so rather than
        # letting two tables on one screen imply they are two views of one thing.
        #
        # Collapsed and greyed until something is up (PR #291's contract), with the
        # gate, the 10 s poll and the off-thread read owned by MeshMonitorSection, so
        # this page holds no monitor logic of its own.
        self.monitor = MeshMonitorSection(
            self, self.wiz.generator_dir, self._monitor_node,
            title="Running mesh — pods, containers and their addresses",
            scaling=True,
            what=("This reads the docker compose project and the kind cluster on THIS "
                  "workstation — not the emulated guests in the table above."))
        self.monitor.monitor.hide_view_controls(
            "Open the browser door from the local-mesh page — it owns the `make view` "
            "session, and two launchers would fight over one session lock.")
        self.monitor.mount(lay)

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
                  self.cache_max, self.pw_ui_port, self.pw_ssh_port):
            w.valueChanged.connect(self._refresh_command)
        self.extra_users.textChanged.connect(self._refresh_command)
        # The Playwright passthrough is a RunEnvelope field, so changing it must
        # rebuild the plan the preview and the spawn both read — exactly like every
        # knob in the Run envelope box above.
        self.pw_args.textChanged.connect(self._refresh_command)
        self.pw_row.currentIndexChanged.connect(self._refresh_playwright_command)

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
        self._seed_build_mode()
        self._reload_sessions()
        self._source_changed()

    def cleanupPage(self):
        """Leaving the page: stop the monitor's clock and let its threads land."""
        self.monitor.shutdown()
        super().cleanupPage()

    def hideEvent(self, event):
        """Off screen, off the clock — the monitor is two shell round trips per tick
        and nobody is looking at them."""
        self.monitor.stop()
        super().hideEvent(event)

    def showEvent(self, event):
        super().showEvent(event)
        self.monitor.start()

    # ── the running-mesh monitor's node ─────────────────────────────────────────
    def _monitor_node(self):
        """The stack node the monitor reads both lanes through, built once.

        Deliberately a DEFAULT LocalStackNode: the monitor only reads, and this page
        has no local-mesh configuration to thread in — the compose file and the ports
        are the Makefile's, which is what the running mesh was started with.
        """
        node = getattr(self, "_monitor_stack_node", None)
        if node is None:
            node = LocalStackNode(self.wiz.generator_dir)
            self._monitor_stack_node = node
        return node

    def validatePage(self) -> bool:
        """SEED the chaining flag — BuildPage owns it from the moment it is reached.

        cfg.qemu_device_tests has two writers: this page's radio and BuildPage's
        checkbox. That is fine going forward and broken on the way back, because collect_all() re-runs
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
        if self.build_first.isChecked():
            # The build this arm continues into takes the mode picked HERE (see
            # build_mode_box), committed exactly as the Mode screen commits it — BEFORE
            # the wizard asks nextId(), which reads cfg.mode to pick the flow.
            commit_image_mode(self.wiz, self.selected_build_mode())
        if getattr(self.wiz, "qemu_device_tests_owned_by_build", False):
            return True
        self.wiz.cfg.qemu_device_tests = self.build_first.isChecked()
        return True

    # ── the build-first arm's explicit mode ─────────────────────────────────────
    def selected_build_mode(self) -> str:
        btn = self.build_mode_group.checkedButton()
        return str(btn.property("mode")) if btn is not None else self.wiz.cfg.mode

    def _seed_build_mode(self):
        """Preselect the mode the configuration is CARRYING — and say so — every time
        the page is entered, so a pick is never silently a leftover."""
        inherited = self.wiz.cfg.mode
        rb = self.build_mode_radios.get(inherited)
        if rb is not None:
            rb.setChecked(True)
        self._inherited_mode = inherited
        self._build_mode_changed()

    def _build_mode_changed(self, *_):
        try:
            picked = self.selected_build_mode()
            inherited = getattr(self, "_inherited_mode", "")
            # ONE sentence for both faces (the TUI QEMU screen's build sub-state
            # renders the same core string — decision 71 = A).
            self.build_mode_note.setText(emulation.build_first_mode_note(
                IMAGE_MODE_TITLES.get(picked, picked),
                IMAGE_MODE_TITLES.get(inherited, inherited)))
        except Exception:                    # noqa: BLE001 — PyQt6 qFatals on a slot raise
            pass

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
            # Said on source_note, NOT rows_label: rows_label lives in session_box,
            # which the build-first arm hides — and _source_changed blanks it — so this
            # guidance was written and then erased before anyone could read it. The
            # instruction is "press Next", not "choose build-first": the line below has
            # already chosen it, so naming the radio sent the operator hunting for a
            # control that was checked and (until the setFinalPage fix in
            # _source_changed) could not be acted on either.
            self.source_note.setText(
                f'<span style="color:{WARN}">No build session under out/sessions/ holds a '
                "bootable image yet</span>, so there is nothing here to boot — <b>Build "
                "new images first</b> is preselected below. Press <b>Next</b> to "
                "configure that build here, or run one of the generator's "
                "<tt>build-*-stage4.sh</tt> scripts outside Studio and come back.")
            self.source_note.setVisible(True)
            self.use_existing.setEnabled(False)
            self.build_first.setChecked(True)
        else:
            self.source_note.setVisible(False)
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
        self._boot_refusal = (session_boot_gate_reason(session.name)
                              if session is not None else "")
        self.domain_gate_note.setText(self._boot_refusal)
        self.domain_gate_note.setVisible(bool(self._boot_refusal))
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
                  self.console_pointer, self.pw_group):
            w.setVisible(existing)
        for w in (self.run_btn, self.list_btn, self.refresh_btn, self.avc_btn,
                  self.avc_combo):
            w.setVisible(existing)
        self.chain_note.setVisible(not existing)
        self.build_mode_box.setVisible(not existing)
        if not existing:
            self.rows_label.setText("")
            self.cmd_view.setPlainText("")
        else:
            self._refresh_command()
        # REFRESH THE BUTTON BAR — this is what made the radio look as if it did nothing.
        #
        # nextId() reports the right answer the instant this toggles. QWizard does not
        # ask it again: canContinue/canFinish are cached by
        # QWizardPrivate::updateCurrentPage(), which runs when a page is ENTERED and is
        # never re-run because a current page's nextId() changed underneath it. This
        # page arrives on the use-existing arm, where nextId() is -1, so the bar is
        # built as FINISH with Next hidden and disabled — and ticking "build new images
        # first" left it exactly that way. The only live button then ENDED the wizard
        # instead of continuing into the build, which is indistinguishable from a radio
        # that does nothing.
        #
        # setFinalPage() is the public lever that re-runs updateCurrentPage() (it does
        # so whenever the page is current), and what it asserts is precisely the fact
        # that changed: this page is terminal only on the test-what-exists arm.
        # completeChanged, emitted below, is NOT a substitute — it re-runs
        # _q_updateButtonStates(), which READS those cached flags rather than
        # recomputing them.
        #
        # Every other test of this chain drives it with wiz.next(), which bypasses the
        # button bar entirely; that is why they were all green while the operator's
        # only route was dead.
        self.setFinalPage(existing)
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

    def _playwright_args(self) -> tuple[str, ...]:
        """The spec/--grep field as the argv that rides after the script's ``--``.

        Split on whitespace, because that is what `playwright test` receives on a
        command line: '--grep @smoke' must arrive as TWO arguments, and a field that
        handed it over as one would narrow to a spec file literally named
        '--grep @smoke' and match nothing. (The same word-splitting rule the
        Makefile's E2E_ARGS passthrough documents.)
        """
        return tuple(self.pw_args.text().split())

    def _envelope(self) -> emulation.RunEnvelope:
        return emulation.RunEnvelope(
            jobs=self.jobs.value(), mem_mb=self.mem.value(), smp=2,
            timeout_s=self.timeout.value(),
            assert_timeout_s=self.assert_timeout.value(),
            extra_users=self._extra_users(),
            cache_max_gb=self.cache_max.value(),
            playwright_args=self._playwright_args())

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
            # The Playwright group has its own combo and its own preview; leaving
            # them populated from the last plan would offer a Run against a session
            # that is no longer selected.
            self.pw_row.clear()
            self._refresh_playwright_command()
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
        self._refresh_playwright_rows(plan)
        self._sync_controls()

    # ── the Playwright lane ─────────────────────────────────────────────────────
    def _refresh_playwright_rows(self, plan: emulation.EmulationPlan):
        """Offer only rows run-qemu-e2e.sh has a launcher for.

        Listing a jetson row here would be a control that always dies: the script
        wires launch-x86.sh and launch-pi.sh, and its own parser rejects any other
        --target. The label under the combo says so when nothing qualifies, rather
        than leaving an empty dropdown to be read as "no images".
        """
        eligible = [r.label for r in plan.rows
                    if emulation.playwright_target_for(r.platform)]
        want = self.pw_row.currentData()
        self.pw_row.blockSignals(True)
        self.pw_row.clear()
        for label in eligible:
            self.pw_row.addItem(label, label)
        if want in eligible:
            self.pw_row.setCurrentIndex(eligible.index(want))
        self.pw_row.blockSignals(False)
        self._refresh_playwright_command()

    def _playwright_options(self) -> emulation.PlaywrightOptions | None:
        """The options for the selected row, or None when nothing is selectable."""
        plan = self.plan
        label = str(self.pw_row.currentData() or "")
        if plan is None or not label:
            return None
        try:
            return emulation.playwright_options_for_row(
                plan, label, ui_port=self.pw_ui_port.value(),
                ssh_port=self.pw_ssh_port.value())
        except ValueError:
            return None

    def _refresh_playwright_command(self, *_):
        """Repaint the Playwright command + the root refusal.

        The preview is ``emulation.playwright_argv``'s output — the SAME call
        ``_launch_playwright`` spawns — so what is printed cannot drift from what
        runs. That is the whole reason the ports and the spec filter are wired
        through the options/envelope instead of being read off the widgets at spawn.
        """
        opts = self._playwright_options()
        if opts is None or self.plan is None:
            self.pw_cmd_view.setPlainText("")
            self.pw_note.setText(
                f'<span style="color:{MUTED}">No planned row has an x86 or Pi '
                "launcher in <tt>tests/qemu/run-qemu-e2e.sh</tt>, so this lane has "
                "nothing to boot from this session.</span>")
        else:
            self.pw_cmd_view.setPlainText(
                " ".join(shlex.quote(a)
                         for a in emulation.playwright_argv(self.plan, opts)))
            blocker = emulation.playwright_root_blocker()
            self.pw_note.setText(
                f'<span style="color:{WARN}">{blocker}</span>' if blocker else
                f'<span style="color:{MUTED}">Running as root: this lane can boot '
                "from here.</span>")
        self._sync_controls()

    def _launch_playwright(self, *, list_only: bool = False,
                           dry_run: bool = False):
        """Enumerate, preview, or actually run the browser suite over one row.

        ``--list`` and ``--dry-run`` need no root and are offered unconditionally;
        the real run is refused HERE, before the spawn, with the containerized route
        named — the Studio must never reach for sudo, and letting the script die
        three seconds later teaches the operator nothing they can act on.
        """
        if self._running:
            return
        plan = self._build_plan()
        opts = self._playwright_options()
        if plan is None or opts is None:
            return
        if not (list_only or dry_run) and self._refuse_boot():
            return
        if not (list_only or dry_run):
            blocker = emulation.playwright_root_blocker()
            if blocker:
                self.note.setText(f'<span style="color:{WARN}">{blocker}</span>')
                console.write(self.log, f"!! refused: {blocker}")
                return
        opts = dataclasses.replace(opts, list_only=list_only, dry_run=dry_run)
        argv = emulation.playwright_argv(plan, opts)
        verb = ("playwright spec listing" if list_only else
                "playwright dry run" if dry_run else
                f"playwright suite on {opts.target}/{opts.role}")
        if not (list_only or dry_run):
            console.write(
                self.log,
                f"[playwright] {opts.target}/{opts.role}: a FULL emulated boot, then "
                f"the tests/e2e specs against https://localhost:{opts.ui_port} — "
                "Cancel stops it and its children.")
        self._run(verb, argv)

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
        if not list_only and self._refuse_boot():
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
        if self._refuse_boot():
            return
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

    def _refuse_boot(self) -> bool:
        """DEFENCE IN DEPTH for the #637 gate: every verb that BOOTS a row asks, not
        only the buttons' enabled state. Inline note + log, never a modal. Listing and
        dry runs boot nothing and are never refused."""
        if not self._boot_refusal:
            return False
        self.note.setText(f'<span style="color:{WARN}">'
                          f"{html.escape(self._boot_refusal)}</span>")
        console.write(self.log, f"!! refused: {self._boot_refusal}")
        return True

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
        escalates to SIGKILL. A runner that ignores the first signal — a qemu hung
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
        boots = not self._boot_refusal           # #637: a refused session boots nothing
        self.run_btn.setEnabled(idle and docker_ok and planned and boots)
        self.list_btn.setEnabled(idle and docker_ok and planned)
        self.avc_btn.setEnabled(idle and docker_ok and planned and boots
                                and bool(self.avc_combo.currentData()))
        # The Playwright lane does NOT gate on docker: run-qemu-e2e.sh drives the
        # host launchers directly (that is exactly why it needs root and the
        # containerized lane does not). Gating it on the docker probe would grey out
        # a listing that works fine on a machine with no daemon at all.
        pw_row = bool(self.pw_row.currentData())
        for w in (self.pw_list_btn, self.pw_preview_btn):
            w.setEnabled(idle and planned and pw_row)
        self.pw_run_btn.setEnabled(idle and planned and pw_row and boots
                                   and not emulation.playwright_root_blocker())
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

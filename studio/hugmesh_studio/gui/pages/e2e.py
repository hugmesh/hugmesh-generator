"""E2EPage — RUN E2E TESTS: the suite against a mesh that is ALREADY running.

WHY THIS PAGE EXISTS (operator, 2026-08-27): *"remove QEMU device emulation menu
item as it does not do anything that cannot be done from the other menu, but add
the run e2e tests button."* The "QEMU device tests" card is gone from the mode menu
and this page holds its slot on both faces.

THE HALF OF THAT REQUEST THAT WAS NOT TRUE, AND WHAT WAS DONE ABOUT IT
----------------------------------------------------------------------
"does not do anything that cannot be done from the other menu" is right about the
BOOT-AND-ASSERT lane — Mesh emulation runs the same matrix through the same argv
author (``core.emulation.run_argv``: TEST is the run, DEPLOY is the same fan-out
with ``--keep-alive``), grades with the same ``emulation.status()``, and has its own
per-row Stop / QMP power-off. It is wrong about two harnesses that had NO other door
anywhere in the Studio:

  * ``tests/qemu/run-qemu-e2e.sh`` — Playwright driving ``tests/e2e`` against a
    booted emulated device (``emulation.playwright_argv``, spawned only from
    ``QemuPage``), and
  * ``tests/qemu/avc-workout.sh`` — the SELinux AVC narrowing run (issue #45,
    ``emulation.avc_argv``, likewise spawned only from ``QemuPage``).

So deleting the card without a replacement door would have deleted a lane — and the
sharpest irony is that the Playwright one IS an e2e lane. This page therefore has TWO
arms: the suite (below) and a route into the untouched ``QemuPage``. ``QemuPage`` and
every line of the QEMU test machinery survive unchanged; what changed is which screen
arms ``wiz.qemu_selected``.

THE POST-BUILD OPT-IN IS UNTOUCHED. ``BuildPage``'s "After the build, run the QEMU
emulated-device tests in Docker" checkbox (``cfg.qemu_device_tests``, ``--env test``
gated) and ``progress.py::_maybe_qemu_tests`` never read ``wiz.qemu_selected`` and
never routed through the removed card. That path still works end to end with no menu
at all.

NEVER A LYING BUTTON
--------------------
Everything on the suite arm answers to two objects and invents nothing:

  * ``core.e2e_environments`` decides WHICH mesh. The chooser is BUILT from
    ``describe()`` — a restated list here is how the label and the target come to
    disagree. The choice becomes ``SNAP_ENV`` on the child process, the same channel
    ``SNAP_ENV=kind make stack-e2e-bdd-env`` uses and ``tests/e2e/steps/world.ts``
    reads. Not a flag, not a config key, not a second make target.
  * ``LocalStackNode.e2e_ready(environment)`` decides WHETHER it can run. Off the GUI
    thread (it is three 30s docker subprocesses plus a 5s HTTP probe), through the
    SAME ``_E2EGateProbe`` the Local-Docker-mesh page uses — the probe class is
    reused, its ANSWER is not: this page probes for ITS OWN chosen environment.

TRI-STATE, seeded as a blocker, AND RE-SEEDED ON EVERY RE-GATE. ``_blockers`` starts
non-empty: before any probe has reported, "nothing established" must read as a
blocker, never as permission. The list rides into ``E2ETreeDialog(blockers=...)``,
which disables its Run and NAMES every reason, so the tree can never be armed against
a mesh that cannot host the suite. The half review caught: shutting the BUTTON is not
enough — the tree opens asynchronously, so every path that shuts the door re-seeds
the list too (``_sync_gate`` and ``_launch``). ``_on_gate_answer`` is the only place
an empty list — permission — can come from.

THE GATE IS PER-ENVIRONMENT AND SO IS THE HONESTY. ``e2e_ready`` deliberately answers
only the tests/e2e + node_modules half for ``kind`` and ``qemu`` and leaves liveness
to the harness (``world.ts`` skips per scenario with a reason naming what to start).
So on those two the button is legitimately armed with the mesh possibly down, and the
page says exactly that inline, with the environment's own ``start_hint``. For
``qemu`` it also renders ``e2e_environments.emulator_running()`` — a read-only,
name-anchored ``pgrep`` — as a NOTE, never as a block, because it cannot see a device
inside the runner container.

IT STARTS NOTHING. ``plan(boot=True)`` is refused for ``qemu`` (root), and this page
never asks for it. Every "how do I start that mesh" answer is TEXT.

NO MODALS IN PAGE LOGIC (house rule). The environment handler and the arm radios open
no dialog; the feature tree is ``show()``n, not ``exec()``d, and ``accepted`` carries
the selection back — so a headless test drives the whole chain with nothing waiting on
a human. This page also has NO ``validatePage`` override at all: the QEMU arm writes
``wiz.qemu_selected`` from the radio's ``toggled``, which sidesteps the re-arming trap
``QemuPage.validatePage``'s docstring documents (``collect_all()`` re-runs the
validatePage of every VISITED page).
"""
from __future__ import annotations

import threading

from ..qt import Qt, QtWidgets
from .. import console
from ..styles import MUTED, WARN
from ...core import e2e_environments
from ...core.local_mesh_bootstrap import (LocalMeshBootstrap,
                                          LocalMeshBootstrapConfig,
                                          discover_brands)
from ._scroll import scrollable
from ._widgets import label_finish_as_exit, own_probe, probe_running
from .localmesh import _E2ECatalogueProbe, _E2EGateProbe, _MeshWorker

#: The tri-state seed. Before the first probe answers, the Run door is shut and this
#: is the reason it gives. It is a BLOCKER, not an empty list: an empty list is
#: permission, and nothing has been established yet.
UNCHECKED_BLOCKER = ("the chosen environment has not been checked yet — the "
                     "readiness probe has not reported.")

#: The other shut state that is not a refusal. A run holds the door closed for as
#: long as it is in flight, and an already-open feature tree must be told the same
#: thing the button is showing.
RUNNING_BLOCKER = "an e2e run is already in flight on this page."


class E2EPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.generator_dir = wiz.generator_dir
        # The SAME construction LocalMeshPage uses, so both pages ask about one mesh
        # rather than two differently-configured ideas of it: the bootstrap owns the
        # stack node's compose project / env / profiles, and it also owns the minted
        # superadmin bundle reader (superadmin_login).
        self.boot = LocalMeshBootstrap(self.generator_dir, LocalMeshBootstrapConfig())
        self.worker: _MeshWorker | None = None
        self._running = False
        self._blockers: list[str] = [UNCHECKED_BLOCKER]
        #: Which environment the gate probe currently in flight was started for. Only
        #: used to avoid stacking an identical probe; the ANSWER is stamped per-probe
        #: (see _sync_gate), because "the last probe I started" is not the same fact as
        #: "the probe this answer came from".
        self._gate_env: str | None = None

        self.setTitle("Run e2e tests")
        self.setSubTitle(
            "Run the end-to-end suite against a mesh that is ALREADY running. This "
            "page starts no mesh: it chooses which one to drive, says why a run is "
            "blocked when it is, and streams the run below. This is the end of this "
            "path unless you pick the emulated-device lanes; Exit closes the Studio.")
        self.setFinalPage(True)
        label_finish_as_exit(self)

        lay = scrollable(self)

        # ── the two arms ───────────────────────────────────────────────────────
        self.arm_suite = QtWidgets.QRadioButton(
            "Run the suite against a running mesh")
        self.arm_suite.setToolTip(
            "tests/e2e — the Gherkin lane (make " + e2e_environments.RUN_TARGET
            + "), against the mesh the chooser below names.")
        self.arm_qemu = QtWidgets.QRadioButton(
            "Emulated-device test lanes (QEMU device tests) — Next")
        self.arm_qemu.setToolTip(
            "The QEMU device-test page: a build session's images booted as emulated "
            "devices with their in-guest assertions (tests/qemu/run-qemu-docker.sh), "
            "the Playwright browser suite driven against one booted guest "
            "(tests/qemu/run-qemu-e2e.sh) and the SELinux AVC workout "
            "(tests/qemu/avc-workout.sh).\n\n"
            "That page used to have its own mode-menu card. The card was removed on "
            "2026-08-27; the page was not, and this is its door.")
        self.arm_suite.setChecked(True)
        lay.addWidget(self.arm_suite)
        lay.addWidget(self.arm_qemu)

        self.chain_note = QtWidgets.QLabel(
            "Press <b>Next</b> for the QEMU device-test page — three emulated-device "
            "lanes: the in-guest assertion matrix, the Playwright browser suite on a "
            "booted guest, and the SELinux AVC workout. Nothing on this page runs on "
            "that arm.<br><br>"
            "Persistent emulated devices (console, ssh, disk save-back) live on the "
            "<b>Mesh emulation</b> card instead.")
        self.chain_note.setWordWrap(True)
        self.chain_note.setVisible(False)
        lay.addWidget(self.chain_note)

        # ── the suite arm ──────────────────────────────────────────────────────
        self.suite_box = QtWidgets.QGroupBox("The suite, and which mesh it drives")
        box = QtWidgets.QVBoxLayout(self.suite_box)

        intro = QtWidgets.QLabel(
            "The Gherkin lane (<tt>make " + e2e_environments.RUN_TARGET + "</tt>) "
            "against a mesh that is <b>already serving</b>. The choice below rides as "
            "<tt>" + e2e_environments.ENV_VAR + "</tt> on the run — the same channel a "
            "terminal uses — so the Studio and the CLI can never target different "
            "meshes. The 33 HANDWRITTEN spec files are a separate lane and are not run "
            "here: <tt>make stack-e2e</tt> from a terminal.")
        intro.setWordWrap(True)
        box.addWidget(intro)

        # THE CHOOSER IS BUILT FROM describe(), never restated (the localmesh page's
        # rule, pinned by test_pages_e2e_environment.py's first assertion).
        self.env_combo = QtWidgets.QComboBox()
        for envrow in e2e_environments.describe():
            self.env_combo.addItem(envrow["label"], envrow["id"])
            self.env_combo.setItemData(
                self.env_combo.count() - 1,
                "%s\n\nRuns: make %s with %s=%s\nPins: %s\nStart it with: %s"
                % (envrow["note"], envrow["makeTarget"], e2e_environments.ENV_VAR,
                   envrow["id"], ", ".join(envrow["pins"]) or "<none>",
                   envrow["startHint"]),
                int(Qt.ItemDataRole.ToolTipRole))
        self.env_combo.setCurrentIndex(
            max(0, self.env_combo.findData(e2e_environments.DEFAULT_ENVIRONMENT)))
        # currentIndexChanged, not activated: a programmatic change must re-gate too.
        # The handler only re-probes and edits labels — it opens NO modal, because a
        # QMessageBox from a selection handler hangs every headless test.
        self.env_combo.currentIndexChanged.connect(self._on_env_changed)
        env_row = QtWidgets.QHBoxLayout()
        env_row.addWidget(QtWidgets.QLabel("e2e target:"))
        env_row.addWidget(self.env_combo, 1)
        env_wrap = QtWidgets.QWidget()
        env_wrap.setLayout(env_row)
        box.addWidget(env_wrap)

        #: What the chosen environment IS and how it is started — the plan's own
        #: note/start_hint/pins, never a second telling.
        self.env_note = QtWidgets.QLabel("")
        self.env_note.setWordWrap(True)
        self.env_note.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse)
        box.addWidget(self.env_note)

        #: The live gate, rendered. Never blank: it says "checking…", or it names
        #: every blocker, or it says the door is open and for which mesh.
        self.gate_note = QtWidgets.QLabel("")
        self.gate_note.setWordWrap(True)
        self.gate_note.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse)
        box.addWidget(self.gate_note)

        #: WHOSE superadmin the run logs in as. A menu-level page built from
        #: generator_dir alone silently loses the minted identity the Local-Docker-mesh
        #: bootstrap put in the secrets bundle, and every superadmin scenario then
        #: 401s against a GUI-bootstrapped mesh. This page reconstructs it through the
        #: bootstrap's OWN reader and SAYS which brand's bundle answered — or that
        #: none did, which is the terminal-seeded case where the deterministic e2e
        #: defaults apply.
        self.identity_note = QtWidgets.QLabel("")
        self.identity_note.setWordWrap(True)
        self.identity_note.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse)
        box.addWidget(self.identity_note)

        brow = QtWidgets.QHBoxLayout()
        self.tree_btn = QtWidgets.QPushButton("e2e features…")
        self.tree_btn.setEnabled(False)
        self.tree_btn.clicked.connect(self._open_tree)
        brow.addWidget(self.tree_btn)
        self.cancel_btn = QtWidgets.QPushButton("Cancel")
        self.cancel_btn.setVisible(False)
        self.cancel_btn.clicked.connect(self._cancel)
        brow.addWidget(self.cancel_btn)
        brow.addStretch(1)
        brow_wrap = QtWidgets.QWidget()
        brow_wrap.setLayout(brow)
        box.addWidget(brow_wrap)

        self.status = QtWidgets.QLabel("")
        self.status.setWordWrap(True)
        self.status.setStyleSheet(f"color:{MUTED};")
        box.addWidget(self.status)

        self.log = console.attach(QtWidgets.QPlainTextEdit())
        self.log.setReadOnly(True)
        box.addWidget(self.log, 1)

        lay.addWidget(self.suite_box, 1)

        self._cancel_event: threading.Event | None = None
        self.arm_suite.toggled.connect(self._sync_arm)
        self.arm_qemu.toggled.connect(self._sync_arm)
        self._sync_arm()
        self._refresh_env_note()
        self._render_identity_note()

    # ── wizard-flow contract ───────────────────────────────────────────────────
    def applies_to(self, cfg) -> bool:  # noqa: ARG002 — the hook's fixed signature
        # A WIZARD-transient choice, deliberately absent from cfg (ModePage keeps
        # cfg.mode an IMAGE mode), so this reads the wizard, not cfg. This page emits
        # ZERO ImageConfig fields, so the ALL-OPTIONS skip guard holds trivially.
        return bool(getattr(self.wiz, "e2e_selected", False))

    def nextId(self) -> int:
        # Terminal on the suite arm; the QEMU arm rejoins the flow at the very next
        # slug ("qemu" sits immediately after "e2e" in WIZARD_PAGE_SLUGS, and
        # QemuPage.applies_to reads the flag this page's radio wrote).
        if self.arm_qemu.isChecked():
            return super().nextId()
        return -1

    def isComplete(self) -> bool:
        # Leaving mid-run would orphan the worker's signals into a destroyed page.
        # Cancel is the way out, and it reaches a real process group.
        return not self._running

    def initializePage(self):
        # Re-assert the flag from the radio on every entry: a True left over from an
        # earlier visit must not survive a Back-and-switch to the suite arm.
        # _sync_arm re-gates as part of landing on an arm, so there is no separate
        # _sync_gate() call here: a second one would only be swallowed by the
        # probe-in-flight guard, and reading as if the gate had two owners.
        self._sync_arm()
        self._refresh_env_note()
        self._render_identity_note()

    # ── the two arms ───────────────────────────────────────────────────────────
    def _sync_arm(self, *_a):
        """Show one arm's widgets, and ARM (or disarm) the QEMU device-test page.

        This is where ``wiz.qemu_selected`` is written — from a radio ``toggled``,
        NOT from ``validatePage``. ``collect_all()`` re-runs the validatePage of every
        VISITED page, which is exactly how ``QemuPage``'s own chaining flag once
        re-armed itself over an explicit opt-out (its docstring records the trace).
        A toggled handler has no such second life, and it also keeps this page out of
        the "terminal page that commits on the way out" set the Exit-label guard pins.
        """
        suite = self.arm_suite.isChecked()
        self.suite_box.setVisible(suite)
        self.chain_note.setVisible(not suite)
        self.wiz.qemu_selected = not suite
        # setFinalPage() is the public lever that re-runs updateCurrentPage(), and
        # what it asserts is precisely the fact that changed: this page is terminal
        # only on the suite arm. completeChanged is NOT a substitute — it re-runs the
        # button-state pass, which READS those cached flags rather than recomputing
        # them (the trap qemu.py::_source_changed documents at length).
        self.setFinalPage(suite)
        self.completeChanged.emit()
        # Re-gate for the arm we just landed on: the suite arm probes, the device
        # arm shuts the door without spending a subprocess (see _sync_gate). During
        # __init__ this is a no-op — tree_btn does not exist yet — and the tri-state
        # seed set in __init__ stands.
        self._sync_gate()

    # ── the environment ────────────────────────────────────────────────────────
    def environment(self) -> str:
        """Which mesh the chooser currently names. Falls back to the default
        (docker — what an unset SNAP_ENV has always meant) when the combo has not been
        built yet, so a caller during construction cannot crash the page."""
        combo = getattr(self, "env_combo", None)
        if combo is None:
            return e2e_environments.DEFAULT_ENVIRONMENT
        return combo.currentData() or e2e_environments.DEFAULT_ENVIRONMENT

    def _on_env_changed(self, *_a):
        """The chooser moved: re-render what it means, and RE-PROBE for it.

        NO MODAL HERE. This is a selection handler; everything it has to say goes into
        the labels and the tooltip.
        """
        self._refresh_env_note()
        self._sync_gate()

    def _refresh_env_note(self):
        env_id = self.environment()
        try:
            plan = e2e_environments.plan(env_id)
        except ValueError as exc:                 # an unknown id names the legal set
            self.env_note.setText(str(exc))
            return
        parts = [
            f"<b>{env_id}</b> — {plan.note}",
            f"Runs <tt>make {plan.make_target}</tt> with "
            f"<tt>{e2e_environments.ENV_VAR}={env_id}</tt>"
            + (", pinning <tt>" + "</tt>, <tt>".join(
                k for k in plan.env if k != e2e_environments.ENV_VAR) + "</tt>"
               if len(plan.env) > 1 else ""),
            f"<i>Nothing here starts it.</i> Start it yourself with: "
            f"<tt>{plan.start_hint}</tt>",
        ]
        if env_id != "docker":
            # e2e_ready is SCOPED: for kind and qemu it checks only tests/e2e +
            # node_modules and hands liveness to the harness. Saying so is the
            # difference between an armed button and a lying one.
            parts.append(
                f'<span style="color:{MUTED}">The readiness check below covers only '
                "this checkout (tests/e2e + node_modules) for this environment — "
                "whether the mesh itself is serving is answered by the harness, which "
                "SKIPS each scenario with a reason naming what to start "
                "(tests/e2e/steps/world.ts).</span>")
        if env_id == "qemu":
            running = e2e_environments.emulator_running()
            if running is True:
                word = "a qemu-system-* process is running on this host"
            elif running is False:
                word = "no qemu-system-* process is running on this host"
            else:
                word = "could not tell whether a qemu-system-* process is running"
            parts.append(
                f'<span style="color:{MUTED}">Note ({word}) — this is a read-only '
                "name-anchored pgrep and it is NOT a gate: it cannot see a device "
                "emulating inside the runner container, so it must never block the "
                "run.</span>")
        self.env_note.setText("<br>".join(parts))

    # ── the identity bridge ────────────────────────────────────────────────────
    def _superadmin_bridge(self) -> tuple[dict, str]:
        """(env bridge, the sentence describing it).

        The suite's superadmin scenarios log in as the MINTED platform superadmin, not
        as the deterministic e2e default, whenever the mesh was bootstrapped from the
        Studio. ``LocalMeshBootstrap.superadmin_login()`` is the ONE reader of that
        bundle; this walks it over the brand profiles the checkout actually ships
        rather than re-parsing secrets.json with a second reader.
        """
        seen: list[str] = []
        brands = [self.boot.cfg.brand]
        try:
            brands += [b for b in discover_brands(self.generator_dir)
                       if b != self.boot.cfg.brand]
        except OSError:                              # a checkout with no brands/ dir
            pass
        for brand in brands:
            if brand in seen:
                continue
            seen.append(brand)
            cfg = LocalMeshBootstrapConfig(brand=brand)
            creds = LocalMeshBootstrap(self.generator_dir, cfg).superadmin_login()
            if creds:
                return ({"CASDOOR_SUPERADMIN_USERNAME": creds[0],
                         "E2E_SUPERADMIN_PASSWORD": creds[1]},
                        f"superadmin identity bridged from the '{brand}' secrets "
                        f"bundle: {creds[0]} (password from the minted bundle; it "
                        f"rides the subprocess env, never argv).")
        return ({},
                "no minted secrets bundle under keys-out/vault — the run will use the "
                "suite's deterministic e2e defaults. That is correct for a "
                "terminal-seeded stack; a mesh bootstrapped from the Local Docker mesh "
                "page mints its own superadmin, and superadmin scenarios 401 without "
                "it. Run the suite from that page to bridge a mesh it bootstrapped.")

    def _render_identity_note(self):
        bridge, why = self._superadmin_bridge()
        colour = MUTED if bridge else WARN
        self.identity_note.setText(f'<span style="color:{colour}">Identity: {why}</span>')

    # ── the gate ───────────────────────────────────────────────────────────────
    def _sync_gate(self):
        """Honest enablement for the feature tree, per CHOSEN environment.

        OFF-THREAD: ``e2e_ready()`` is three 30s docker subprocesses plus a 5s HTTP
        probe, and running it inline from initializePage could freeze the window for
        ~95s against a hung daemon. A probe already in flight is left alone rather
        than stacking threads.

        THE BLOCKER LIST MOVES WITH THE BUTTON, ALWAYS. Review found the first
        version re-shutting the button on an environment change while leaving
        ``_blockers`` holding the PREVIOUS environment's answer — and since the tree
        opens asynchronously (``npx playwright test --list``, up to 180s), a dialog
        constructed after the switch got ``blockers=[]`` and an armed Run for a mesh
        nothing had checked. Every path that shuts the door therefore re-seeds the
        list in the same breath; ``_on_gate_answer`` is the ONLY place an empty list
        can come from.
        """
        btn = getattr(self, "tree_btn", None)
        if btn is None:
            return
        if self._running:
            self._blockers = [RUNNING_BLOCKER]
            btn.setEnabled(False)
            btn.setToolTip("A run is in flight — wait for it to finish.")
            self.gate_note.setText("A run is in flight.")
            return
        if not self.arm_suite.isChecked():
            # THE DEVICE-LANE ARM. suite_box — and this button with it — is hidden,
            # and nothing on that arm reads the answer, so probing here would spend
            # three 30s docker subprocesses plus a 5s urlopen on a question nobody
            # asked, and widen the window in which a live probe thread outlives the
            # page (the teardown qFatal LocalMeshPage already carries). Shut the
            # door, re-seed the tri-state, start nothing: switching BACK comes
            # through _sync_arm, which lands here again with the arm checked.
            self._blockers = [UNCHECKED_BLOCKER]
            btn.setEnabled(False)
            return
        # TRI-STATE, and this runs BEFORE the in-flight guard on purpose: a caller
        # that just blanket-enabled the buttons must not be able to leave this one
        # armed by arriving while a probe happens to be out.
        self._blockers = [UNCHECKED_BLOCKER]
        btn.setEnabled(False)
        btn.setToolTip("Checking whether the chosen mesh can host the e2e suite…")
        self.gate_note.setText(
            "Checking whether the <b>%s</b> mesh can host the suite "
            "(read-only probes — this can take a few seconds)…" % self.environment())
        env_id = self.environment()
        if probe_running(self, "_gate_probe") and self._gate_env == env_id:
            return                       # its answer is already on the way, for THIS mesh
        # A probe out for a DIFFERENT mesh is not reusable and must not be waited on:
        # it is superseded here and its answer is discarded on arrival. Two probes
        # briefly in flight is safe — own_probe gives each one its own deleteLater —
        # whereas waiting for the stale one is how the door came to be armed for a
        # mesh nobody asked about.
        self._gate_env = env_id
        probe = own_probe(self, "_gate_probe",
                          _E2EGateProbe(self.boot._stack_node(),
                                        environment=env_id,
                                        parent=self))
        # STAMPED WITH ITS OWN QUESTION. _E2EGateProbe.result carries only the problem
        # list (it is shared with the local-mesh page, whose chooser cannot move), so
        # the environment is bound here at connect time. Without it an answer about
        # docker, arriving after the chooser moved to kind, reads as permission for
        # kind — the exact lying button this page exists not to be.
        probe.result.connect(lambda problems, asked=env_id:
                             self._on_gate_answer(problems, asked))
        probe.start()

    def _on_gate_answer(self, problems, asked: str | None = None):
        """The gate's answer arrived (GUI thread).

        ``asked`` is the environment the answering probe was started for. An answer
        about a mesh that is no longer chosen is DISCARDED — never applied to the
        chooser's current value — and the door stays shut on the seed _sync_gate
        already put there. It defaults to None so a test (and any future caller that
        knows the answer is current) can hand an answer in directly.
        """
        btn = getattr(self, "tree_btn", None)
        if btn is None or self._running:
            return
        if asked is not None and asked != self.environment():
            return
        if not self.arm_suite.isChecked():
            # The device-lane arm hides this button; an answer landing here must not
            # leave it armed underneath for a Back-and-switch to find.
            return
        problems = list(problems or [])
        # Kept so an OPEN feature tree is gated by the same answer, in the same
        # sentences, as this button's tooltip.
        self._blockers = list(problems)
        btn.setEnabled(not problems)
        env_id = self.environment()
        if problems:
            btn.setToolTip("Disabled:\n- " + "\n- ".join(problems))
            self.gate_note.setText(
                f'<span style="color:{WARN}">The suite cannot run against the '
                f"<b>{env_id}</b> mesh:</span><ul><li>"
                + "</li><li>".join(problems) + "</li></ul>")
        else:
            btn.setToolTip(
                "Browse the e2e suite as a tree — Gherkin features, spec files with "
                "their last verdicts and skip reasons, the seeded personas each draws "
                "from, the source, and the screenshots a run produced — then run the "
                "features you CHECK against the mesh named by the chooser above.")
            self.gate_note.setText(
                f"Ready: the <b>{env_id}</b> mesh can host the suite.")

    def blockers(self) -> list[str]:
        """The live gate's last answer — what an opening feature tree is gated by."""
        return list(self._blockers)

    # ── the feature tree ───────────────────────────────────────────────────────
    def _open_tree(self):
        """Open the e2e feature tree. The catalogue is built OFF-THREAD.

        ``load_catalogue`` shells ``npx playwright test --list`` and walks every spec
        source — a subprocess with a 180s ceiling. Building it inline would freeze the
        window on the very click meant to open a browser.
        """
        if probe_running(self, "_cat_probe"):
            self.status.setText("Still enumerating the e2e suite — one moment.")
            return
        self.status.setText(
            "Enumerating the e2e suite (asking Playwright for the spec list; this "
            "works with the mesh down) …")
        probe = own_probe(self, "_cat_probe",
                          _E2ECatalogueProbe(
                              self.generator_dir,
                              env=self.boot._stack_node()._build_env(
                                  write_overlays=False),   # a catalogue READS
                              parent=self))
        probe.result.connect(self._show_tree)
        probe.start()

    def _show_tree(self, catalogue):
        """The catalogue arrived (GUI thread): put the tree on screen.

        NON-MODAL, deliberately. A run started from the tree streams into THIS page's
        log, and a modal would sit on top of the thing the operator needs to watch.
        ``accepted`` carries the selection back, so the dialog is drivable by a
        headless test without exec() ever being called (house rule).
        """
        from .e2e_tree_dialog import E2ETreeDialog
        # THE GATE'S OWN BLOCKERS, so the tree's Run can never be armed for a mesh
        # that cannot host the suite — and NAMES them when it is not.
        blockers = list(self._blockers)
        # A previous tree is CLOSED and destroyed first: these are parented to the
        # page, so rebinding the attribute alone would leak the old dialog for the
        # life of the page.
        old = getattr(self, "_tree_dialog", None)
        if old is not None:
            old.close()
            old.deleteLater()
        dlg = E2ETreeDialog(catalogue, self.generator_dir, blockers=blockers,
                            parent=self)
        self._tree_dialog = dlg             # held: a local would be collected
        dlg.accepted.connect(lambda: self._run(dlg.run_specs))
        dlg.show()
        self.status.setText(
            f"e2e feature tree: {len(catalogue.features)} spec file(s), "
            f"{len(catalogue.tests)} test(s). Check what to run.")

    # ── the run ────────────────────────────────────────────────────────────────
    def _run(self, specs=()):
        """Run the SELECTED specs against the chosen mesh.

        The gate is re-probed here (and again inside ``run_e2e``) because enablement
        can go stale the moment the mesh changes underneath the page.
        """
        if self._running:
            return
        node = self.boot._stack_node()
        env_id = self.environment()
        problems = node.e2e_ready(env_id)
        if problems:
            self.status.setText("Cannot run e2e: " + "; ".join(problems))
            self._sync_gate()
            return
        plan = e2e_environments.plan(env_id)
        if not plan.runnable:                     # renders refusals, never spawns them
            self.status.setText("Cannot run e2e: " + "; ".join(plan.refusals))
            return
        specs = tuple(specs or ())
        target = plan.env.get(e2e_environments.BASE_URL_VAR, env_id)
        self._note(f"[e2e] running the Gherkin suite against the {env_id} mesh "
                   f"({target}) — {e2e_environments.ENV_VAR}={env_id}, "
                   f"make {plan.make_target} …")
        self._note("[e2e] selection: "
                   + (", ".join(specs) if specs else "none — the WHOLE suite"))
        bridge, why = self._superadmin_bridge()
        self._note(f"[e2e] {why}")
        self._launch(env_id, node, bridge, specs)

    def _launch(self, env_id, node, bridge, specs):
        self._running = True
        # The list, not just the button: a catalogue probe launched before this run
        # can still deliver its tree after it started, and it must not be built from
        # the pre-run answer. _done() re-gates and the real answer comes back.
        self._blockers = [RUNNING_BLOCKER]
        self.tree_btn.setEnabled(False)
        self.env_combo.setEnabled(False)
        self.arm_qemu.setEnabled(False)
        self._cancel_event = threading.Event()
        self.cancel_btn.setVisible(True)
        self.cancel_btn.setEnabled(True)
        self.status.setText(
            f"Running the e2e suite ({env_id}) — output streams below as it happens; "
            "the wizard stays responsive. Cancel stops the run.")
        self.worker = _MeshWorker(
            lambda on_line, cancel: node.run_e2e(extra_env=bridge, on_line=on_line,
                                                 cancel=cancel, environment=env_id,
                                                 specs=specs),
            parent=self, stream=True, cancel=self._cancel_event)
        self.worker.line.connect(self._on_line)
        self.worker.done.connect(self._done)
        self.completeChanged.emit()
        self.worker.start()

    def _cancel(self):
        if self._cancel_event is not None:
            self._cancel_event.set()
            self.cancel_btn.setEnabled(False)
            self.status.setText("Cancelling — the run's process group is being "
                                "stopped.")

    def _on_line(self, line: str):
        console.write(self.log, line)

    def _done(self, ok: bool):
        self._running = False
        self.cancel_btn.setVisible(False)
        self.env_combo.setEnabled(True)
        self.arm_qemu.setEnabled(True)
        self.status.setText("e2e run finished." if ok
                            else "e2e run FAILED (see the log).")
        self.completeChanged.emit()
        self._sync_gate()

    def _note(self, msg: str):
        console.write(self.log, msg)

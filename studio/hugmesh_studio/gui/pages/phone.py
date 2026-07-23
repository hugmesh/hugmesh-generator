"""PhonePage — the wizard page behind ModePage's fifth first-screen choice
("MDM phone"). It flashes a USB-connected Google Pixel with VERIFIED GrapheneOS and
enrolls it as an MDM-managed mesh device — IN the wizard flow, no image build.

Modelled verbatim on LocalMeshPage (the other builds-no-image side flow):
  - ModePage's phone radio sets ``wiz.phone_selected`` (transient, NEVER in cfg — the
    phone is not an image mode, so cfg.mode stays untouched);
  - ``applies_to()`` reads that flag, so the page is dynamically skipped on every
    image-mode flow (it emits ZERO ImageConfig fields);
  - the page is TERMINAL for its branch (``nextId() == -1`` + setFinalPage): after
    provisioning a phone there is no image to build. Back returns to ModePage.

It is a THIN front over ``core/phone_wizard.py``, which shells the ONE canonical
driver ``scripts/phone-wizard.sh`` — the SAME script the ncurses phone_screen drives.
All gating (fail-closed device catalog, sshsig verify, typed-serial flash confirm,
vault-seed escrow) lives in the bash driver; this page only collects knobs and runs
verbs. The masked auth key is never persisted and never lands on argv — a run stages
it into a 0600 ``--authkey-file`` the core shreds afterwards.

Two verb classes (the driver's own TTY needs decide which):
  - READ-ONLY / non-interactive (plan, detect, fetch, enroll, profile, ingest,
    status) run off the GUI thread on a _MeshWorker (reused from localmesh.py) and
    stream into the log;
  - the TWO verbs that REQUIRE a real TTY — ``flash`` (destructive typed-serial
    confirm) and ``wizard`` (the guided full flow) — are handed to a real terminal
    emulator (PhoneWizard.run_verb_in_terminal), where the driver's own confirmation
    runs untouched. The GUI never injects a --yes bypass and never pipes /dev/null at
    a confirmation gate (see phone-wizard.sh:924, :1820).

``PhoneDialog`` is a thin standalone-host shim wrapping the page, mirroring
LocalMeshDialog.
"""
from __future__ import annotations

import threading
import types

from ..qt import QtWidgets
from ...core.phone_wizard import PhoneWizard, PhoneWizardConfig
from ._scroll import scrollable
from ._widgets import _row
from .localmesh import _MeshWorker


class PhonePage(QtWidgets.QWizardPage):
    # (label, verb, streamed?) — the ncurses phone_screen button set (build-menu.sh
    # :1763-1771). flash/wizard are NOT streamed: they go to a terminal.
    _VERBS = (
        ("★ Guided wizard", "wizard", False),
        ("Plan (dry-run)", "plan", True),
        ("Detect", "detect", True),
        ("Fetch + verify", "fetch", True),
        ("Flash (DESTRUCTIVE)", "flash", False),
        ("Enroll", "enroll", True),
        ("Profile", "profile", True),
        ("Ingest", "ingest", True),
        ("Status", "status", True),
    )

    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.generator_dir = wiz.generator_dir
        self.pw = PhoneWizard(self.generator_dir, PhoneWizardConfig())
        self.worker: _MeshWorker | None = None
        self._running = False
        self.setTitle("MDM phone")
        self.setSubTitle("Flash a USB Pixel with VERIFIED GrapheneOS and enroll it in "
                         "the mesh — no image build. Dry-run by default; every "
                         "destructive step is gated by the driver itself. This is the "
                         "end of this path: Finish closes the wizard.")
        self.setFinalPage(True)

        lay = scrollable(self)
        intro = QtWidgets.QLabel(
            "Onboard a USB-connected Google Pixel as an MDM-managed mesh device. The "
            "same driver the ncurses menu uses owns every gate (fail-closed device "
            "catalog, GrapheneOS signature verify, typed-serial flash confirmation, "
            "vault-seed escrow). Read-only verbs run here; FLASH and the guided WIZARD "
            "open a terminal so the driver's own confirmation prompts run there.")
        intro.setWordWrap(True)
        lay.addWidget(intro)

        # Device codename — fed LIVE from the driver's own vetted catalog (the driver
        # FAILS CLOSED, exit 4, on any codename not in it). Editable so a brand-new
        # device can still be typed; the first entry means "probe at run".
        self.codename = QtWidgets.QComboBox()
        self.codename.setEditable(True)
        self.codename.addItem("<detect at run — probe the connected device>", "")
        for cn, name in self.pw.device_catalog():
            self.codename.addItem(f"{name} ({cn})", cn)
        self.codename.setToolTip(
            "GrapheneOS device codename. Leave as <detect at run> to read it from the "
            "connected device. The driver rejects any codename not in its vetted "
            "catalog (scripts/phone-devices.tsv).")
        lay.addWidget(_row("Device codename", self.codename))

        self.channel = QtWidgets.QComboBox()
        self.channel.addItems(["stable", "beta", "alpha"])
        self.channel.setToolTip("GrapheneOS release channel (stable is the vetted default).")
        lay.addWidget(_row("Release channel", self.channel))

        self.serial = QtWidgets.QLineEdit()
        self.serial.setPlaceholderText("blank = auto when exactly one device is connected")
        lay.addWidget(_row("Serial", self.serial))

        self.keys_dir = QtWidgets.QLineEdit()
        self.keys_dir.setPlaceholderText(
            "docker-mesh-node layout: login-server, tailscale/authkey, role "
            "(blank = use the server / auth-key fields below)")
        keys_row = QtWidgets.QHBoxLayout()
        keys_row.addWidget(self.keys_dir, 1)
        self.keys_browse = QtWidgets.QPushButton("Browse…")
        self.keys_browse.clicked.connect(self._browse_keys)
        keys_row.addWidget(self.keys_browse)
        lay.addWidget(_row("Keys dir", self._wrap(keys_row)))

        self.login_server = QtWidgets.QLineEdit()
        self.login_server.setPlaceholderText(
            "headscale control URL (blank = the keys-dir login-server file)")
        lay.addWidget(_row("Login server", self.login_server))

        self.auth_key = QtWidgets.QLineEdit()
        self.auth_key.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.auth_key.setPlaceholderText(
            "tskey-… (blank = unset; the enroll runbook then expects it from your own "
            "custody)")
        self.auth_key.setToolTip(
            "One-time tailnet/headscale pre-auth key. Never saved to disk by this page; "
            "at run time it rides a 0600 --authkey-file (off the process table) that is "
            "shredded afterwards.")
        lay.addWidget(_row("Auth key", self.auth_key))

        self.role = QtWidgets.QComboBox()
        self.role.addItem("<driver default — user, or the keys-dir role file>", "")
        for r in ("user", "mod", "admin", "superadmin"):
            self.role.addItem(r, r)
        self.role.setToolTip("Mesh role for the enrollment record.")
        lay.addWidget(_row("Mesh role", self.role))

        # Verb buttons — a grid so the nine actions wrap tidily.
        self._buttons: dict[str, QtWidgets.QPushButton] = {}
        grid = QtWidgets.QGridLayout()
        for i, (label, verb, streamed) in enumerate(self._VERBS):
            b = QtWidgets.QPushButton(label)
            if streamed:
                b.clicked.connect(lambda _=False, v=verb, lbl=label: self._run_stream(v, lbl))
            else:
                b.clicked.connect(lambda _=False, v=verb: self._run_terminal(v))
            self._buttons[verb] = b
            grid.addWidget(b, i // 3, i % 3)
        lay.addLayout(grid)

        brow = QtWidgets.QHBoxLayout()
        self.cancel_btn = QtWidgets.QPushButton("Cancel")
        self.cancel_btn.setToolTip("Terminate the running verb.")
        self.cancel_btn.clicked.connect(self._cancel_clicked)
        self.cancel_btn.setVisible(False)
        brow.addWidget(self.cancel_btn)
        brow.addStretch(1)
        lay.addLayout(brow)

        self.status = QtWidgets.QLabel("")
        self.status.setWordWrap(True)
        lay.addWidget(self.status)

        self.log = QtWidgets.QPlainTextEdit()
        self.log.setReadOnly(True)
        lay.addWidget(self.log, 1)

    # ── wizard-flow contract (copied from LocalMeshPage) ─────────────────────────
    def nextId(self) -> int:
        # Terminal branch: no image follows a phone provisioning. The wizard's skip
        # walk is -1-safe.
        return -1

    def applies_to(self, cfg) -> bool:  # noqa: ARG002 — the hook's fixed signature
        # phone is a WIZARD-transient choice, deliberately absent from cfg (ModePage
        # keeps cfg.mode an IMAGE mode), so this reads the wizard, not cfg. The page
        # emits ZERO ImageConfig fields, so the ALL-OPTIONS skip guard holds trivially.
        return bool(getattr(self.wiz, "phone_selected", False))

    def isComplete(self) -> bool:
        # Finish stays disabled while a verb runs — leaving mid-run would orphan the
        # worker's signals into a destroyed page.
        return not self._running

    def initializePage(self):
        self._refresh_available()

    # ── helpers ──────────────────────────────────────────────────────────────────
    @staticmethod
    def _wrap(inner_layout) -> QtWidgets.QWidget:
        holder = QtWidgets.QWidget()
        holder.setLayout(inner_layout)
        return holder

    def _browse_keys(self):
        d = QtWidgets.QFileDialog.getExistingDirectory(
            self, "Keys dir (docker-mesh-node layout)", self.keys_dir.text())
        if d:
            self.keys_dir.setText(d)

    def _codename_value(self) -> str:
        # A GENUINE selection is when the edit text still equals the selected item's
        # display: then its itemData is the codename (the <detect> item's data is ""
        # -> detect at run; a device item's data is its codename). Any other edit text
        # is a freely typed codename, used verbatim. (currentData() alone is unsafe: an
        # editable combo can keep a stale currentIndex after setCurrentText of a value
        # that matches no item's DISPLAY text, e.g. "comet" vs "Pixel 9 … (comet)".)
        idx = self.codename.currentIndex()
        text = self.codename.currentText().strip()
        if idx >= 0 and self.codename.itemText(idx) == self.codename.currentText():
            data = self.codename.itemData(idx)
            return (data if data is not None else text).strip()
        return text

    def collect(self) -> PhoneWizardConfig:
        """Widgets -> PhoneWizardConfig (auth_key transient — never persisted)."""
        return PhoneWizardConfig(
            codename=self._codename_value(),
            channel=self.channel.currentText().strip() or "stable",
            serial=self.serial.text().strip(),
            keys_dir=self.keys_dir.text().strip(),
            login_server=self.login_server.text().strip(),
            role=(self.role.currentData() or ""),
            auth_key=self.auth_key.text().strip(),
        )

    def _refresh_available(self):
        ok, why = self.pw.available()
        if not ok:
            self.status.setText(why)
        self._set_verbs_enabled(ok and not self._running)

    def _set_verbs_enabled(self, on: bool):
        for b in self._buttons.values():
            b.setEnabled(on)

    # ── streamed verbs (off-thread) ──────────────────────────────────────────────
    def _run_stream(self, verb: str, label: str):
        if self._running:
            return
        available, why = self.pw.available()
        if not available:
            self.status.setText(why)
            return
        self.pw = PhoneWizard(self.generator_dir, self.collect())
        self.log.appendPlainText(f"[phone] {self.pw.command_string(verb)}")
        self._launch(label, verb)

    def _launch(self, label: str, verb: str):
        self._running = True
        self._set_verbs_enabled(False)
        cancel = threading.Event()
        self.status.setText(f"{label} — output streams below as it happens; the "
                            f"wizard stays responsive. Cancel stops the verb.")
        self.cancel_btn.setVisible(True)
        self.cancel_btn.setEnabled(True)
        pw = self.pw
        self.worker = _MeshWorker(
            lambda on_line, c: (pw.run(verb, on_line, c) == 0, []),
            parent=self, stream=True, cancel=cancel)
        self.worker.line.connect(self.log.appendPlainText)
        self.worker.done.connect(self._verb_done)
        self.completeChanged.emit()
        self.worker.start()

    def _cancel_clicked(self):
        w = self.worker
        if w is not None and w.cancel is not None and self._running:
            w.cancel.set()
            self.pw.cancel()
            self.cancel_btn.setEnabled(False)
            self.status.setText("Cancelling — terminating the running verb…")

    def _verb_done(self, ok: bool):
        self._running = False
        self.cancel_btn.setVisible(False)
        self._set_verbs_enabled(True)
        self.status.setText("Done." if ok else "FAILED (see log).")
        self.completeChanged.emit()

    # ── TTY verbs (flash / wizard) — deferred to a terminal ──────────────────────
    def _run_terminal(self, verb: str):
        if self._running:
            return
        available, why = self.pw.available()
        if not available:
            self.status.setText(why)
            return
        self.pw = PhoneWizard(self.generator_dir, self.collect())
        ok, msg = self.pw.run_verb_in_terminal(verb)
        self.log.appendPlainText(f"[phone] {msg}")
        self.status.setText(
            f"'{verb}' opened in a terminal — finish it there." if ok
            else f"'{verb}' needs a terminal (see log).")


class PhoneDialog(QtWidgets.QDialog):
    """Thin standalone-host shim: ``PhoneDialog(generator_dir).exec()`` hosts the SAME
    PhonePage without any wizard (one implementation, two frames), mirroring
    LocalMeshDialog. The wizard flow reaches the page via Next (ModePage's phone
    radio); this is for a tray/standalone launch."""

    def __init__(self, generator_dir: str, parent=None):
        super().__init__(parent)
        self.setWindowTitle("MDM phone")
        self.resize(720, 620)
        shim = types.SimpleNamespace(generator_dir=generator_dir, phone_selected=True)
        self.page = PhonePage(shim)
        lay = QtWidgets.QVBoxLayout(self)
        lay.addWidget(self.page, 1)
        close = QtWidgets.QPushButton("Close")
        close.clicked.connect(self.accept)
        row = QtWidgets.QHBoxLayout()
        row.addStretch(1)
        row.addWidget(close)
        lay.addLayout(row)
        self.page.initializePage()

    def __getattr__(self, name):
        # Delegate the former dialog surface to the hosted page (the LocalMeshDialog
        # pattern): __getattr__ fires only on a MISS, so the dialog's own attributes
        # are never shadowed, and the __dict__ guard keeps a mid-__init__ lookup an
        # honest AttributeError instead of infinite recursion.
        page = self.__dict__.get("page")
        if page is None:
            raise AttributeError(name)
        return getattr(page, name)

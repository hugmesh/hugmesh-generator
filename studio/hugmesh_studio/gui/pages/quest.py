"""QuestPage — the wizard page behind ModePage's "MDM Quest headset" first-screen
choice. It onboards a USB-connected Meta Quest 3/3S as an MDM-managed mesh device —
IN the wizard flow, no image build, no flash: a Quest is enrolled AS-IS (Horizon OS
cannot be reflashed by this wizard).

Modelled verbatim on PhonePage (which is itself modelled on LocalMeshPage):
  - ModePage's quest radio sets ``wiz.quest_selected`` (transient, NEVER in cfg — the
    headset is not an image mode, so cfg.mode stays untouched);
  - ``applies_to()`` reads that flag, so the page is dynamically skipped on every
    image-mode flow (it emits ZERO ImageConfig fields);
  - the page is TERMINAL for its branch (``nextId() == -1`` + setFinalPage): after
    provisioning a headset there is no image to build. Back returns to ModePage.

It is a THIN front over the SAME ``core/phone_wizard.py`` runner the phone page uses
— one canonical driver (``scripts/phone-wizard.sh``) for both device classes, with
``--device-class quest`` selecting the quest catalog (scripts/quest-devices.tsv:
eureka = Meta Quest 3, panther = Meta Quest 3S) and the quest verb subset. All
gating lives in the bash driver: the fail-closed catalog, the vendor-2833 /
ro.product.manufacturer=oculus identity pin (a Pixel can never be driven down the
quest path — `panther` is ALSO the Pixel 7), the Developer-Mode runbook, and the
fail-closed refusal of fetch/flash/attest/profile with the per-verb rationale
(GrapheneOS is Pixel-only; no Auditor tier exists on Horizon OS; the user model is
Meta-account-bound). The masked auth key is never persisted and never lands on argv
— a run stages it into a 0600 ``--authkey-file`` the core shreds afterwards.

Verb classes (the driver's own TTY needs decide which):
  - READ-ONLY / non-interactive (plan, detect, mdm-enroll, enroll, ingest, status)
    run off the GUI thread on a _MeshWorker and stream into the log. mdm-enroll is
    streamable HERE (unlike the phone page): the phone's fresh-device gates become
    non-interactive ADVISORIES on quest — Horizon OS setup requires a Meta account,
    so ``dpm set-device-owner`` is the real arbiter (phone-wizard.sh quest gates).
  - ``wizard`` (the guided detect→mdm-enroll→enroll→ingest flow) REQUIRES a real
    TTY and is handed to a terminal emulator (run_verb_in_terminal), where the
    driver's own prompts run untouched. The GUI never injects a --yes bypass.

``QuestDialog`` is a thin standalone-host shim wrapping the page, mirroring
PhoneDialog/LocalMeshDialog.
"""
from __future__ import annotations

import functools

import threading
import types

from ..qt import QtWidgets
from .. import console
from ...core.phone_wizard import PhoneWizard, PhoneWizardConfig
from ._scroll import scrollable
from ._widgets import _row, label_finish_as_exit
from .localmesh import _MeshWorker


class QuestPage(QtWidgets.QWizardPage):
    # (label, verb, streamed?) — the quest verb subset (the ncurses quest_screen
    # button set). ONLY wizard is a terminal verb; mdm-enroll streams (see module
    # docstring). fetch/flash/attest/profile are deliberately ABSENT: the driver
    # refuses them for --device-class quest with the rationale.
    _VERBS = (
        ("★ Guided wizard", "wizard", False),
        ("Plan (dry-run)", "plan", True),
        ("Detect", "detect", True),
        ("MDM-enroll + chat URL", "mdm-enroll", True),
        ("Enroll (mesh join)", "enroll", True),
        ("Ingest", "ingest", True),
        ("Status", "status", True),
    )

    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.generator_dir = wiz.generator_dir
        self.pw = PhoneWizard(self.generator_dir,
                              PhoneWizardConfig(device_class="quest"))
        self.worker: _MeshWorker | None = None
        self._running = False
        self.setTitle("MDM Quest headset")
        self.setSubTitle("Enroll a USB-connected Meta Quest 3/3S as an MDM-managed "
                         "mesh device — no image build, no flash (the headset keeps "
                         "Horizon OS). Every gate lives in the driver itself. This is "
                         "the end of this path: Exit closes the Studio.")
        self.setFinalPage(True)
        # Pressing the final button here does nothing but close the Studio — no
        # build, no apply, no write, no state commit — so it says so (_widgets:
        # label_finish_as_exit).
        label_finish_as_exit(self)

        lay = scrollable(self)
        intro = QtWidgets.QLabel(
            "Onboard a Meta Quest 3/3S over USB: Headwind device-owner enrollment, "
            "Tailscale mesh join (sideloaded APK, tun0 verify), XR-chat entry URL "
            "provisioning, and the device-registry ingest record. The same driver the "
            "ncurses menu and the make quest-* targets use owns every gate. "
            "PREREQUISITE: Developer Mode must be ON (a Meta developer account; the "
            "driver prints the full runbook when the headset is not adb-visible). "
            "Read-only verbs run here; the guided WIZARD opens a terminal so the "
            "driver's own prompts run there.")
        intro.setWordWrap(True)
        lay.addWidget(intro)

        # Device codename — fed LIVE from the driver's own vetted QUEST catalog
        # (scripts/quest-devices.tsv; the driver FAILS CLOSED, exit 4, on any codename
        # not in it). Editable so a brand-new headset can still be typed; the first
        # entry means "probe at run".
        self.codename = QtWidgets.QComboBox()
        self.codename.setEditable(True)
        self.codename.addItem("<detect at run — probe the connected headset>", "")
        for cn, name in self.pw.device_catalog():
            self.codename.addItem(f"{name} ({cn})", cn)
        self.codename.setToolTip(
            "Quest codename (eureka = Meta Quest 3, panther = Meta Quest 3S). Leave as "
            "<detect at run> to read it from the connected headset. The driver rejects "
            "any codename not in its vetted quest catalog (scripts/quest-devices.tsv) "
            "and pins the device identity (USB vendor 2833, manufacturer oculus/Meta) "
            "— 'panther' is ALSO the Pixel 7, so the class picks the catalog.")
        lay.addWidget(_row("Device codename", self.codename))

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

        # ── Headwind management plane (mdm-enroll) ────────────────────────────────
        # Paths/URLs/names only — never secrets (the phone_screen custody posture).
        self.headwind_url = QtWidgets.QLineEdit()
        self.headwind_url.setPlaceholderText("blank = driver HMDM_URL env")
        self.headwind_url.setToolTip(
            "Headwind server base URL, written into the DPC's init.json "
            "(com.hmdm.BASE_URL).")
        lay.addWidget(_row("Headwind URL", self.headwind_url))

        self.headwind_apk = QtWidgets.QLineEdit()
        self.headwind_apk.setPlaceholderText(
            "path to the Headwind DPC APK (blank = require already-installed)")
        apk_row = QtWidgets.QHBoxLayout()
        apk_row.addWidget(self.headwind_apk, 1)
        self.apk_browse = QtWidgets.QPushButton("Browse…")
        self.apk_browse.clicked.connect(self._browse_apk)
        apk_row.addWidget(self.apk_browse)
        lay.addWidget(_row("Headwind DPC APK", self._wrap(apk_row)))

        self.headwind_signer = QtWidgets.QLineEdit()
        self.headwind_signer.setPlaceholderText(
            "expected APK signing-cert SHA-256 (hex; mdm-enroll fails closed on mismatch)")
        lay.addWidget(_row("Headwind signer SHA-256", self.headwind_signer))

        self.headwind_config = QtWidgets.QLineEdit()
        self.headwind_config.setPlaceholderText(
            "Headwind CONFIGURATION the headset self-selects into (init.json com.hmdm.CONFIG)")
        self.headwind_config.setToolTip(
            "The app-push lever: applications in this Headwind configuration (e.g. the "
            "XR-chat web-page entry) are pushed by the Headwind server to the headset.")
        lay.addWidget(_row("Headwind configuration", self.headwind_config))

        # ── XR-chat URL provisioning (toggle + URL) ───────────────────────────────
        self.xr_chat_enabled = QtWidgets.QCheckBox(
            "Provision the XR-chat entry URL during mdm-enroll")
        self.xr_chat_enabled.setToolTip(
            "When enabled, mdm-enroll records the URL in mdm.json, prints the Headwind "
            "web-page-app console runbook (app-push), and fires a VIEW intent so you can "
            "confirm the room loads in the headset browser. https:// only — WebXR needs "
            "a secure context.")
        lay.addWidget(self.xr_chat_enabled)
        self.xr_chat_url = QtWidgets.QLineEdit()
        self.xr_chat_url.setPlaceholderText("https://… (the Shadows-of-the-Net room URL)")
        self.xr_chat_url.setEnabled(False)
        self.xr_chat_enabled.toggled.connect(self.xr_chat_url.setEnabled)
        lay.addWidget(_row("XR-chat URL", self.xr_chat_url))

        # ── Thin desktop (§8b — toggle + Moonlight APK/pin + host list) ───────────
        # Same opt-in shape as the XR-chat toggle above: the value fields are
        # greyed until the capability is enabled and collect() emits them ONLY
        # while it is on — the driver refuses value knobs without --thin-desktop.
        self.thin_desktop_enabled = QtWidgets.QCheckBox(
            "Thin desktop: provision Moonlight + the thin-client host list during mdm-enroll")
        self.thin_desktop_enabled.setToolTip(
            "Opt-in quest capability: sideload the Moonlight streaming client "
            "(operator-supplied APK, signer-pinned like every other sideload) and "
            "push the managed list of thin-client tailnet names, so the headset can "
            "open a Sunshine-hosted virtual desktop of a mesh node over the tailnet "
            "ONLY. mdm-enroll also prints the Headwind app-push runbook (durable "
            "fleet distribution) and the Moonlight/Sunshine PIN pairing runbook. "
            "The node side is the x86 builder's --with-sunshine provisioning item — "
            "see docs/MDM.md 'Thin desktop'.")
        lay.addWidget(self.thin_desktop_enabled)
        self.moonlight_apk = QtWidgets.QLineEdit()
        self.moonlight_apk.setPlaceholderText(
            "path to the Moonlight APK (blank = require already-installed)")
        ml_row = QtWidgets.QHBoxLayout()
        ml_row.addWidget(self.moonlight_apk, 1)
        self.moonlight_browse = QtWidgets.QPushButton("Browse…")
        self.moonlight_browse.clicked.connect(self._browse_moonlight)
        ml_row.addWidget(self.moonlight_browse)
        self._moonlight_row = self._wrap(ml_row)
        lay.addWidget(_row("Moonlight APK", self._moonlight_row))
        self.moonlight_signer = QtWidgets.QLineEdit()
        self.moonlight_signer.setPlaceholderText(
            "expected APK signing-cert SHA-256 (hex; mdm-enroll fails closed on mismatch)")
        lay.addWidget(_row("Moonlight signer SHA-256", self.moonlight_signer))
        self.thin_desktop_hosts = QtWidgets.QLineEdit()
        self.thin_desktop_hosts.setPlaceholderText(
            "comma-separated thin-client tailnet names (e.g. frite,box2.hugmesh.internal)")
        self.thin_desktop_hosts.setToolTip(
            "Written into the managed host-list file pushed to the headset "
            "(Moonlight external files dir) and mirrored in mdm.json. Lowercase "
            "tailnet DNS names only — the driver validates the charset fail-closed.")
        lay.addWidget(_row("Thin-client hosts", self.thin_desktop_hosts))
        for w in (self._moonlight_row, self.moonlight_signer, self.thin_desktop_hosts):
            w.setEnabled(False)
            self.thin_desktop_enabled.toggled.connect(w.setEnabled)

        # Verb buttons — a grid so the seven actions wrap tidily.
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

        self.log = console.attach(QtWidgets.QPlainTextEdit())
        self.log.setReadOnly(True)
        lay.addWidget(self.log, 1)

    # ── wizard-flow contract (copied from PhonePage/LocalMeshPage) ────────────────
    def nextId(self) -> int:
        # Terminal branch: no image follows a headset provisioning. The wizard's skip
        # walk is -1-safe.
        return -1

    def applies_to(self, cfg) -> bool:  # noqa: ARG002 — the hook's fixed signature
        # quest is a WIZARD-transient choice, deliberately absent from cfg (ModePage
        # keeps cfg.mode an IMAGE mode), so this reads the wizard, not cfg. The page
        # emits ZERO ImageConfig fields, so the ALL-OPTIONS skip guard holds trivially.
        return bool(getattr(self.wiz, "quest_selected", False))

    def isComplete(self) -> bool:
        # Exit stays disabled while a verb runs — leaving mid-run would orphan the
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

    def _browse_apk(self):
        f, _sel = QtWidgets.QFileDialog.getOpenFileName(
            self, "Headwind DPC APK", self.headwind_apk.text(), "APK (*.apk);;All files (*)")
        if f:
            self.headwind_apk.setText(f)

    def _browse_moonlight(self):
        f, _sel = QtWidgets.QFileDialog.getOpenFileName(
            self, "Moonlight APK", self.moonlight_apk.text(), "APK (*.apk);;All files (*)")
        if f:
            self.moonlight_apk.setText(f)

    def _codename_value(self) -> str:
        # Same genuine-selection rule as PhonePage._codename_value (see its comment on
        # why currentData() alone is unsafe on an editable combo).
        idx = self.codename.currentIndex()
        text = self.codename.currentText().strip()
        if idx >= 0 and self.codename.itemText(idx) == self.codename.currentText():
            data = self.codename.itemData(idx)
            return (data if data is not None else text).strip()
        return text

    def collect(self) -> PhoneWizardConfig:
        """Widgets -> PhoneWizardConfig with device_class pinned to "quest"
        (auth_key transient — never persisted). channel is deliberately left at ""
        (a GrapheneOS release-channel knob; meaningless for a class with no
        fetch/flash). The XR-chat URL is emitted ONLY while its toggle is on, and
        the thin-desktop value knobs ONLY while THAT toggle is on (the driver
        refuses --moonlight-*/--thin-desktop-hosts without --thin-desktop)."""
        td_on = self.thin_desktop_enabled.isChecked()
        return PhoneWizardConfig(
            device_class="quest",
            codename=self._codename_value(),
            channel="",
            serial=self.serial.text().strip(),
            keys_dir=self.keys_dir.text().strip(),
            login_server=self.login_server.text().strip(),
            role=(self.role.currentData() or ""),
            auth_key=self.auth_key.text().strip(),
            headwind_apk=self.headwind_apk.text().strip(),
            headwind_signer=self.headwind_signer.text().strip(),
            headwind_url=self.headwind_url.text().strip(),
            headwind_config=self.headwind_config.text().strip(),
            xr_chat_url=(self.xr_chat_url.text().strip()
                         if self.xr_chat_enabled.isChecked() else ""),
            thin_desktop=td_on,
            moonlight_apk=(self.moonlight_apk.text().strip() if td_on else ""),
            moonlight_signer=(self.moonlight_signer.text().strip() if td_on else ""),
            thin_desktop_hosts=(self.thin_desktop_hosts.text().strip() if td_on else ""),
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
        console.write(self.log, f"[quest] {self.pw.command_string(verb)}")
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
        # functools.partial, not a lambda: the slot outlives this method and a
        # lambda closing over self.log would keep re-resolving it.
        self.worker.line.connect(functools.partial(console.write, self.log))
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

    # ── the TTY verb (wizard) — deferred to a terminal ────────────────────────────
    def _run_terminal(self, verb: str):
        if self._running:
            return
        available, why = self.pw.available()
        if not available:
            self.status.setText(why)
            return
        self.pw = PhoneWizard(self.generator_dir, self.collect())
        ok, msg = self.pw.run_verb_in_terminal(verb)
        console.write(self.log, f"[quest] {msg}")
        self.status.setText(
            f"'{verb}' opened in a terminal — finish it there." if ok
            else f"'{verb}' needs a terminal (see log).")


class QuestDialog(QtWidgets.QDialog):
    """Thin standalone-host shim: ``QuestDialog(generator_dir).exec()`` hosts the SAME
    QuestPage without any wizard (one implementation, two frames), mirroring
    PhoneDialog. The wizard flow reaches the page via Next (ModePage's quest radio);
    this is for a tray/standalone launch."""

    def __init__(self, generator_dir: str, parent=None):
        super().__init__(parent)
        self.setWindowTitle("MDM Quest headset")
        self.resize(720, 680)
        shim = types.SimpleNamespace(generator_dir=generator_dir, quest_selected=True)
        self.page = QuestPage(shim)
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
        # Delegate the former dialog surface to the hosted page (the PhoneDialog
        # pattern): __getattr__ fires only on a MISS, so the dialog's own attributes
        # are never shadowed, and the __dict__ guard keeps a mid-__init__ lookup an
        # honest AttributeError instead of infinite recursion.
        page = self.__dict__.get("page")
        if page is None:
            raise AttributeError(name)
        return getattr(page, name)

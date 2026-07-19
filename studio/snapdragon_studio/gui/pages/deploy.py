"""DeployPage — the wizard page behind ModePage's sixth first-screen choice
("Cloud deploy"). It publishes an already-built, cloud-PACKAGED x86 image to a
cloud provider via the canonical deploy driver — IN the wizard flow, no image build.

Modelled verbatim on PhonePage/LocalMeshPage (the other builds-no-image side flows):
  - ModePage's deploy radio sets ``wiz.deploy_selected`` (transient, NEVER in cfg —
    deploy is not an image mode, so cfg.mode stays untouched);
  - ``applies_to()`` reads that flag, so the page is dynamically skipped on every
    image-mode flow (it emits ZERO ImageConfig fields);
  - the page is TERMINAL for its branch (``nextId() == -1`` + setFinalPage): after
    a deploy there is no image to build. Back returns to ModePage.

It is a THIN front over ``core/cloud_deploy.py``, which shells the ONE canonical
driver ``specs/usr/sbin/snapdragon-cloud-deploy`` — the SAME driver the ncurses
deploy_screen and the Makefile deploy-* delegates reach. All gating (provider
registry, validate_inputs, creds-present check, the TTY confirmation on apply/
destroy) lives in the bash driver; this page only collects knobs and runs verbs.
Pasted creds are never persisted and never land on argv — a run stages them into a
0600 ``--creds-file`` tempfile the core shreds afterwards.

Verb routing (the driver's own gates decide the shape):
  - ``plan`` (offline artifact render) and ``status`` (emitted-state reader) stream
    off the GUI thread on a _MeshWorker (reused from localmesh.py) into the log;
  - ``apply`` ALSO streams, but ONLY behind the explicit ack checkbox — and the
    driver still owns its own confirmation (fail-closed without a TTY; the GUI
    never sets the driver's test-only CD_ASSUME_YES and never pipes /dev/null at
    a confirmation gate it could satisfy);
  - ``destroy`` (DESTRUCTIVE) is handed to a real terminal emulator
    (CloudDeploy.run_verb_in_terminal), where the driver's own confirmation runs
    untouched.

The read-only monospace plan pane live-refreshes CloudDeploy.preview() — a PURE
text manifest (knobs + exact plan command + BLOCKERS tail); the actual artifact
render stays behind the explicit Plan button (localmesh plan_view precedent).

``DeployDialog`` is a thin standalone-host shim wrapping the page, mirroring
PhoneDialog/LocalMeshDialog.
"""
from __future__ import annotations

import threading
import types

from ..qt import QtCore, QtGui, QtWidgets
from ...core.cloud_deploy import CloudDeploy, CloudDeployOptions
from ._scroll import scrollable
from ._widgets import _row
from .localmesh import _MeshWorker


class DeployPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.generator_dir = wiz.generator_dir
        self.cd = CloudDeploy(self.generator_dir, CloudDeployOptions())
        self.worker: _MeshWorker | None = None
        self._running = False
        self.setTitle("Cloud deploy")
        self.setSubTitle("Publish an already-built, cloud-packaged x86 image to a "
                         "cloud provider — no image build. Plan renders readable "
                         "artifacts OFFLINE; only the emitted apply.sh/destroy.sh "
                         "ever touch a cloud, and the driver confirms each. This is "
                         "the end of this path: Finish closes the wizard.")
        self.setFinalPage(True)

        lay = scrollable(self)
        intro = QtWidgets.QLabel(
            "Deploy the OUTPUT of a build: package an existing x86 artifact with "
            "scripts/cloud-package.sh (qcow2 / fixed VHD / raw), then point this page "
            "at it. The same driver the ncurses menu and `make deploy-*` use owns "
            "every gate (provider registry, input validation, creds-present check, "
            "apply/destroy confirmation). PLAN and STATUS run here; APPLY streams "
            "here after you acknowledge the plan; DESTROY opens a terminal so the "
            "driver's own confirmation runs there.")
        intro.setWordWrap(True)
        lay.addWidget(intro)

        # Provider — fed LIVE from the driver's own registry (`list`, THE parseable
        # API). An absent driver leaves the combo empty and the status names why.
        self.provider = QtWidgets.QComboBox()
        self.provider.setToolTip(
            "Cloud provider from the driver's registry "
            "(specs/usr/lib/snapdragon/cloud-deploy-providers.sh). Refresh re-reads "
            "`snapdragon-cloud-deploy list`.")
        prov_row = QtWidgets.QHBoxLayout()
        prov_row.addWidget(self.provider, 1)
        self.prov_refresh = QtWidgets.QPushButton("Refresh")
        self.prov_refresh.setToolTip("Re-read the driver's provider registry.")
        self.prov_refresh.clicked.connect(self._reload_providers)
        prov_row.addWidget(self.prov_refresh)
        lay.addWidget(_row("Provider", self._wrap(prov_row)))

        self.image = QtWidgets.QLineEdit()
        self.image.setPlaceholderText(
            "cloud-PACKAGED artifact — scripts/cloud-package.sh output "
            "(.qcow2 / .vhd / .img)")
        img_row = QtWidgets.QHBoxLayout()
        img_row.addWidget(self.image, 1)
        self.image_browse = QtWidgets.QPushButton("Browse…")
        self.image_browse.clicked.connect(self._browse_image)
        img_row.addWidget(self.image_browse)
        lay.addWidget(_row("Image", self._wrap(img_row)))

        self.domain = QtWidgets.QLineEdit()
        self.domain.setPlaceholderText("public apex domain, e.g. example.com (optional)")
        lay.addWidget(_row("Domain", self.domain))

        self.region = QtWidgets.QLineEdit()
        self.region.setPlaceholderText("provider region, e.g. eu-central-1 (optional)")
        lay.addWidget(_row("Region", self.region))

        self.creds_file = QtWidgets.QLineEdit()
        self.creds_file.setPlaceholderText(
            "PATH to your 0600 credentials file (the path rides argv; the contents "
            "never do)")
        cf_row = QtWidgets.QHBoxLayout()
        cf_row.addWidget(self.creds_file, 1)
        self.creds_browse = QtWidgets.QPushButton("Browse…")
        self.creds_browse.clicked.connect(self._browse_creds)
        cf_row.addWidget(self.creds_browse)
        lay.addWidget(_row("Creds file", self._wrap(cf_row)))

        self.creds = QtWidgets.QLineEdit()
        self.creds.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.creds.setPlaceholderText(
            "…or paste creds content (blank = use the creds file above)")
        self.creds.setToolTip(
            "Pasted credentials. Never saved to disk by this page; at run time they "
            "ride a 0600 --creds-file tempfile (off the process table) that is "
            "shredded afterwards. Leave blank when a creds file path is set.")
        lay.addWidget(_row("Creds (paste)", self.creds))

        self.out_dir = QtWidgets.QLineEdit()
        self.out_dir.setPlaceholderText("where plan renders its artifacts (driver default when blank)")
        od_row = QtWidgets.QHBoxLayout()
        od_row.addWidget(self.out_dir, 1)
        self.out_browse = QtWidgets.QPushButton("Browse…")
        self.out_browse.clicked.connect(self._browse_out)
        od_row.addWidget(self.out_browse)
        lay.addWidget(_row("Out dir", self._wrap(od_row)))

        self.keys_dir = QtWidgets.QLineEdit()
        self.keys_dir.setPlaceholderText("optional keys dir for the provider's KEYS volume notes")
        kd_row = QtWidgets.QHBoxLayout()
        kd_row.addWidget(self.keys_dir, 1)
        self.keys_browse = QtWidgets.QPushButton("Browse…")
        self.keys_browse.clicked.connect(self._browse_keys)
        kd_row.addWidget(self.keys_browse)
        lay.addWidget(_row("Keys dir", self._wrap(kd_row)))

        # IdP passthrough (same picker the node/localmesh setups offer): the
        # built-in IdP is the default and adds nothing; an external choice makes
        # the plan emit idp/idp.conf beside the provider artifacts.
        self.idp = QtWidgets.QComboBox()
        self.idp.addItem("Casdoor (built-in — default)", "")
        self.idp.addItem("Azure Entra ID", "entra")
        self.idp.addItem("AWS Cognito", "aws")
        self.idp.addItem("Other OIDC provider", "oidc")
        self.idp.setToolTip(
            "Identity provider recorded in the plan's idp/idp.conf. The built-in "
            "default emits nothing; deploys of an image BUILT with external IdP "
            "flags should pick the same provider here.")
        self.idp.currentIndexChanged.connect(self._idp_changed)
        lay.addWidget(_row("Identity provider", self.idp))

        self.idp_issuer = QtWidgets.QLineEdit()
        self.idp_issuer.setPlaceholderText(
            "issuer URL — Entra: https://login.microsoftonline.com/<tenant>/v2.0 · "
            "Cognito: https://cognito-idp.<region>.amazonaws.com/<pool-id>")
        lay.addWidget(_row("IdP issuer", self.idp_issuer))
        self.idp_client_id = QtWidgets.QLineEdit()
        self.idp_client_id.setPlaceholderText("optional client id registered at the IdP")
        lay.addWidget(_row("IdP client id", self.idp_client_id))
        self.idp_jwks = QtWidgets.QLineEdit()
        self.idp_jwks.setPlaceholderText(
            "optional JWKS URL override (Entra defaults to /discovery/v2.0/keys)")
        lay.addWidget(_row("IdP JWKS", self.idp_jwks))
        self._idp_changed()

        # Plan preview (read-only, live) — the confirm-before-run surface.
        lay.addWidget(QtWidgets.QLabel("Plan preview (pure — nothing runs until you pick a verb):"))
        self.plan_view = QtWidgets.QPlainTextEdit()
        self.plan_view.setReadOnly(True)
        self.plan_view.setLineWrapMode(QtWidgets.QPlainTextEdit.LineWrapMode.NoWrap)
        f = self.plan_view.font()
        f.setStyleHint(f.StyleHint.Monospace)
        f.setFamily("monospace")
        self.plan_view.setFont(f)
        lay.addWidget(self.plan_view, 1)

        self.ack = QtWidgets.QCheckBox(
            "I understand APPLY executes the plan's emitted apply.sh against a REAL "
            "cloud account (resources + cost).")
        lay.addWidget(self.ack)

        brow = QtWidgets.QHBoxLayout()
        self.plan_btn = QtWidgets.QPushButton("Plan (render artifacts)")
        self.plan_btn.setToolTip(
            "Run the driver's plan verb: render the provider's artifacts OFFLINE "
            "into the out dir. No cloud API is touched.")
        self.plan_btn.clicked.connect(lambda: self._run_stream("plan", "Planning"))
        brow.addWidget(self.plan_btn)
        self.apply_btn = QtWidgets.QPushButton("Apply")
        self.apply_btn.setToolTip(
            "Execute the rendered plan's apply.sh (driver-gated; requires the "
            "acknowledgement). Real resources, real cost.")
        self.apply_btn.clicked.connect(self._apply_clicked)
        brow.addWidget(self.apply_btn)
        self.status_btn = QtWidgets.QPushButton("Status")
        self.status_btn.setToolTip(
            "Read the emitted state hints / print the provider check commands. "
            "Never calls a cloud API itself.")
        self.status_btn.clicked.connect(lambda: self._run_stream("status", "Status"))
        brow.addWidget(self.status_btn)
        self.destroy_btn = QtWidgets.QPushButton("Destroy (DESTRUCTIVE)")
        self.destroy_btn.setToolTip(
            "Run the emitted destroy.sh in a terminal — the driver's own "
            "confirmation runs there (no GUI bypass).")
        self.destroy_btn.clicked.connect(lambda: self._run_terminal("destroy"))
        brow.addWidget(self.destroy_btn)
        self.cancel_btn = QtWidgets.QPushButton("Cancel")
        self.cancel_btn.setToolTip("Terminate the running verb.")
        self.cancel_btn.clicked.connect(self._cancel_clicked)
        self.cancel_btn.setVisible(False)
        brow.addWidget(self.cancel_btn)
        self.open_btn = QtWidgets.QPushButton("Open artifacts folder")
        self.open_btn.setToolTip("Open the out dir holding the rendered plan artifacts.")
        self.open_btn.clicked.connect(self._open_artifacts)
        brow.addWidget(self.open_btn)
        brow.addStretch(1)
        lay.addLayout(brow)

        self.status = QtWidgets.QLabel("")
        self.status.setWordWrap(True)
        lay.addWidget(self.status)

        self.log = QtWidgets.QPlainTextEdit()
        self.log.setReadOnly(True)
        lay.addWidget(self.log, 1)

        # Live-refresh the pure preview + gate Apply on the acknowledgement.
        self.provider.currentIndexChanged.connect(self._refresh_preview)
        for le in (self.image, self.domain, self.region, self.creds_file,
                   self.creds, self.out_dir, self.keys_dir):
            le.textChanged.connect(self._refresh_preview)
        self.ack.toggled.connect(self._sync_apply_gate)
        self._reload_providers()

    # ── wizard-flow contract (copied from PhonePage/LocalMeshPage) ───────────────
    def nextId(self) -> int:
        # Terminal branch: no image follows a cloud deploy. The wizard's skip walk
        # is -1-safe.
        return -1

    def applies_to(self, cfg) -> bool:  # noqa: ARG002 — the hook's fixed signature
        # deploy is a WIZARD-transient choice, deliberately absent from cfg (ModePage
        # keeps cfg.mode an IMAGE mode), so this reads the wizard, not cfg. The page
        # emits ZERO ImageConfig fields, so the ALL-OPTIONS skip guard holds trivially.
        return bool(getattr(self.wiz, "deploy_selected", False))

    def isComplete(self) -> bool:
        # Finish stays disabled while a verb runs — leaving mid-run would orphan the
        # worker's signals into a destroyed page.
        return not self._running

    def initializePage(self):
        self._refresh_available()
        self._refresh_preview()

    # ── helpers ──────────────────────────────────────────────────────────────────
    @staticmethod
    def _wrap(inner_layout) -> QtWidgets.QWidget:
        holder = QtWidgets.QWidget()
        holder.setLayout(inner_layout)
        return holder

    def _browse_image(self):
        p, _ = QtWidgets.QFileDialog.getOpenFileName(
            self, "Cloud-packaged image (cloud-package.sh output)", self.image.text(),
            "Cloud images (*.qcow2 *.vhd *.img);;All files (*)")
        if p:
            self.image.setText(p)

    def _browse_creds(self):
        p, _ = QtWidgets.QFileDialog.getOpenFileName(
            self, "Credentials file (0600)", self.creds_file.text())
        if p:
            self.creds_file.setText(p)

    def _browse_out(self):
        d = QtWidgets.QFileDialog.getExistingDirectory(
            self, "Plan artifacts out dir", self.out_dir.text())
        if d:
            self.out_dir.setText(d)

    def _browse_keys(self):
        d = QtWidgets.QFileDialog.getExistingDirectory(
            self, "Keys dir", self.keys_dir.text())
        if d:
            self.keys_dir.setText(d)

    def _idp_changed(self, *_a):
        """External IdP enables its detail fields; the built-in default greys them."""
        external = bool(self.idp.currentData())
        for w in (self.idp_issuer, self.idp_client_id, self.idp_jwks):
            w.setEnabled(external)

    def collect(self) -> CloudDeployOptions:
        """Widgets -> CloudDeployOptions (pasted creds transient — never persisted)."""
        return CloudDeployOptions(
            provider=(self.provider.currentData() or ""),
            image=self.image.text().strip(),
            domain=self.domain.text().strip(),
            region=self.region.text().strip(),
            creds_file=self.creds_file.text().strip(),
            out_dir=self.out_dir.text().strip(),
            keys_dir=self.keys_dir.text().strip(),
            creds=self.creds.text().strip(),
            idp=(self.idp.currentData() or ""),
            idp_issuer=self.idp_issuer.text().strip(),
            idp_client_id=self.idp_client_id.text().strip(),
            idp_jwks=self.idp_jwks.text().strip(),
        )

    def _reload_providers(self):
        """(Re)populate the provider combo from the driver's `list` registry,
        keeping the current pick when it survives the reload."""
        keep = self.provider.currentData()
        self.provider.blockSignals(True)
        self.provider.clear()
        rows = self.cd.providers()
        if not rows:
            self.provider.addItem("<no providers — is the deploy driver present?>", "")
        for pid, pstatus, desc in rows:
            label = f"{pid} — {desc}" if desc else pid
            if pstatus and pstatus != "full":
                label += f"  [{pstatus}]"
            self.provider.addItem(label, pid)
        if keep:
            i = self.provider.findData(keep)
            if i >= 0:
                self.provider.setCurrentIndex(i)
        self.provider.blockSignals(False)
        self._refresh_available()
        self._refresh_preview()

    def _refresh_available(self):
        ok, why = self.cd.available()
        if not ok:
            self.status.setText(why)
        self._set_verbs_enabled(ok and not self._running)

    def _set_verbs_enabled(self, on: bool):
        for b in (self.plan_btn, self.status_btn, self.destroy_btn):
            b.setEnabled(on)
        self._sync_apply_gate()

    def _refresh_preview(self, *_):
        self.cd = CloudDeploy(self.generator_dir, self.collect())
        self.plan_view.setPlainText(self.cd.preview())
        self._sync_apply_gate()

    def _sync_apply_gate(self, *_):
        # Apply is gated behind the explicit acknowledgement + an available driver —
        # nothing mutates on mere selection (non-destructive by default). The driver
        # still runs its OWN confirmation gate on top.
        ok, _why = self.cd.available()
        self.apply_btn.setEnabled(ok and self.ack.isChecked() and not self._running)

    # ── streamed verbs (off-thread) ──────────────────────────────────────────────
    def _run_stream(self, verb: str, label: str):
        if self._running:
            return
        available, why = self.cd.available()
        if not available:
            self.status.setText(why)
            return
        self.cd = CloudDeploy(self.generator_dir, self.collect())
        self.log.appendPlainText(f"[deploy] {self.cd.command_string(verb)}")
        self._launch(label, verb)

    def _apply_clicked(self):
        if not self.ack.isChecked():
            self.status.setText("Acknowledge the plan first.")
            return
        problems = CloudDeploy(self.generator_dir, self.collect()).validate()
        if problems:
            self.status.setText("Cannot apply: " + "; ".join(problems))
            return
        self._run_stream("apply", "Applying")

    def _launch(self, label: str, verb: str):
        self._running = True
        self._set_verbs_enabled(False)
        cancel = threading.Event()
        self.status.setText(f"{label} — output streams below as it happens; the "
                            f"wizard stays responsive. Cancel stops the verb.")
        self.cancel_btn.setVisible(True)
        self.cancel_btn.setEnabled(True)
        cd = self.cd
        self.worker = _MeshWorker(
            lambda on_line, c: (cd.run(verb, on_line, c) == 0, []),
            parent=self, stream=True, cancel=cancel)
        self.worker.line.connect(self.log.appendPlainText)
        self.worker.done.connect(self._verb_done)
        self.completeChanged.emit()
        self.worker.start()

    def _cancel_clicked(self):
        w = self.worker
        if w is not None and w.cancel is not None and self._running:
            w.cancel.set()
            self.cd.cancel()
            self.cancel_btn.setEnabled(False)
            self.status.setText("Cancelling — terminating the running verb…")

    def _verb_done(self, ok: bool):
        self._running = False
        self.cancel_btn.setVisible(False)
        self._set_verbs_enabled(True)
        self.status.setText("Done." if ok else "FAILED (see log).")
        self.completeChanged.emit()

    # ── TTY verbs (destroy) — deferred to a terminal ─────────────────────────────
    def _run_terminal(self, verb: str):
        if self._running:
            return
        available, why = self.cd.available()
        if not available:
            self.status.setText(why)
            return
        self.cd = CloudDeploy(self.generator_dir, self.collect())
        ok, msg = self.cd.run_verb_in_terminal(verb)
        self.log.appendPlainText(f"[deploy] {msg}")
        self.status.setText(
            f"'{verb}' opened in a terminal — finish it there." if ok
            else f"'{verb}' needs a terminal (see log).")

    # ── artifacts ────────────────────────────────────────────────────────────────
    def _open_artifacts(self):
        out = self.out_dir.text().strip() or self.generator_dir
        QtGui.QDesktopServices.openUrl(QtCore.QUrl.fromLocalFile(out))


class DeployDialog(QtWidgets.QDialog):
    """Thin standalone-host shim: ``DeployDialog(generator_dir).exec()`` hosts the
    SAME DeployPage without any wizard (one implementation, two frames), mirroring
    PhoneDialog/LocalMeshDialog. The wizard flow reaches the page via Next
    (ModePage's deploy radio); this is for a tray/standalone launch."""

    def __init__(self, generator_dir: str, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Cloud deploy")
        self.resize(720, 620)
        shim = types.SimpleNamespace(generator_dir=generator_dir, deploy_selected=True)
        self.page = DeployPage(shim)
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
        # Delegate the dialog surface to the hosted page (the PhoneDialog pattern):
        # __getattr__ fires only on a MISS, so the dialog's own attributes are never
        # shadowed, and the __dict__ guard keeps a mid-__init__ lookup an honest
        # AttributeError instead of infinite recursion.
        page = self.__dict__.get("page")
        if page is None:
            raise AttributeError(name)
        return getattr(page, name)

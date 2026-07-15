"""LocalMeshDialog — the modal launcher behind the ModePage's fourth first-screen
choice ("Local Docker mesh"). It runs a dockerized Snapdragon mesh on THIS machine
(no image build, no server hardware).

TWO mutually-exclusive paths, surfaced as tabs (mirroring the mandate's "join with a
key" vs "generate & start from scratch"):
  - JOIN an existing mesh with a key — the original path: collect a tailnet/headscale
    auth key + node knobs into a LocalMeshConfig and drive LocalMeshNode
    (core/local_mesh.py) start/stop/logs.
  - GENERATE & START a NEW local mesh FROM SCRATCH — mint ALL credentials + bring up
    the full platform stack seeded with a fresh superadmin, via LocalMeshBootstrap
    (core/local_mesh_bootstrap.py). NON-destructive: nothing runs until the operator
    acknowledges the read-only plan preview and clicks "Generate & start".

Deliberately SELF-CONTAINED (the FleetDialog / golive precedent):
``LocalMeshDialog(generator_dir).exec()`` works without any wizard-page registration.
ModePage's fourth-choice button (_launch_local_mesh) is unchanged — it opens this one
dialog. All lifecycle/option logic lives Qt-free in the core modules; this module only
collects widgets into the two config dataclasses and drives them.
"""
from __future__ import annotations

from ..qt import QtCore, QtWidgets
from ...core.local_mesh import LocalMeshConfig, LocalMeshNode
from ...core.local_mesh_bootstrap import LocalMeshBootstrap, LocalMeshBootstrapConfig
from ._widgets import _row


class LocalMeshDialog(QtWidgets.QDialog):
    """Standalone host: ``LocalMeshDialog(generator_dir).exec()`` — no wizard needed."""

    def __init__(self, generator_dir: str, parent=None):
        super().__init__(parent)
        self.generator_dir = generator_dir
        self.node = LocalMeshNode(generator_dir, LocalMeshConfig())
        self.boot = LocalMeshBootstrap(generator_dir, LocalMeshBootstrapConfig())
        self.setWindowTitle("Run a local Docker mesh")
        self.resize(720, 620)
        lay = QtWidgets.QVBoxLayout(self)

        self.tabs = QtWidgets.QTabWidget()
        self.tabs.addTab(self._build_join_tab(), "Join an existing mesh with a key")
        self.tabs.addTab(self._build_bootstrap_tab(),
                         "Generate && start a NEW local mesh from scratch")
        lay.addWidget(self.tabs)

        # Shared status + log pane (used by BOTH tabs).
        self.status = QtWidgets.QLabel("")
        self.status.setWordWrap(True)
        lay.addWidget(self.status)

        self.log = QtWidgets.QPlainTextEdit()
        self.log.setReadOnly(True)
        lay.addWidget(self.log, 1)

        close = QtWidgets.QPushButton("Close")
        close.clicked.connect(self.accept)
        row = QtWidgets.QHBoxLayout()
        row.addStretch(1)
        row.addWidget(close)
        lay.addLayout(row)

        self._refresh_status()

    # ── JOIN tab (the original path — widget names/handlers unchanged) ───────────
    def _build_join_tab(self) -> QtWidgets.QWidget:
        w = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(w)
        intro = QtWidgets.QLabel(
            "Join an EXISTING mesh: run a Snapdragon mesh node on THIS machine in "
            "Docker — no separate server hardware and no image build. Provide a "
            "tailnet/headscale auth key; the dockerized node joins the mesh and serves "
            "locally.")
        intro.setWordWrap(True)
        lay.addWidget(intro)

        self.auth_key = QtWidgets.QLineEdit()
        self.auth_key.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.auth_key.setPlaceholderText("tskey-… (required — the tailnet/headscale auth key)")
        self.auth_key.setToolTip(
            "The pre-auth key the node's tailscale container joins with (staged as "
            "TS_AUTHKEY). Never saved to disk by this dialog beyond the local compose "
            "project's .env.")
        lay.addWidget(_row("Auth key", self.auth_key))

        self.node_name = QtWidgets.QLineEdit()
        self.node_name.setPlaceholderText("optional hostname on the tailnet (default: snapdragon-node)")
        lay.addWidget(_row("Node name", self.node_name))

        self.login_server = QtWidgets.QLineEdit()
        self.login_server.setPlaceholderText(
            "optional self-hosted headscale URL, e.g. https://headscale.example.com")
        self.login_server.setToolTip(
            "For a self-hosted headscale control plane — appended to TS_EXTRA_ARGS as "
            "--login-server=<url>. Leave empty to use Tailscale's default coordinator.")
        lay.addWidget(_row("Login server", self.login_server))

        btns = QtWidgets.QHBoxLayout()
        self.start_btn = QtWidgets.QPushButton("Start")
        self.stop_btn = QtWidgets.QPushButton("Stop")
        self.logs_btn = QtWidgets.QPushButton("View logs…")
        self.start_btn.clicked.connect(self._start)
        self.stop_btn.clicked.connect(self._stop)
        self.logs_btn.clicked.connect(self._logs)
        btns.addWidget(self.start_btn)
        btns.addWidget(self.stop_btn)
        btns.addWidget(self.logs_btn)
        btns.addStretch(1)
        lay.addLayout(btns)
        lay.addStretch(1)
        return w

    # ── BOOTSTRAP tab (generate & start from scratch) ────────────────────────────
    def _build_bootstrap_tab(self) -> QtWidgets.QWidget:
        w = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(w)
        intro = QtWidgets.QLabel(
            "Generate ALL credentials from scratch and start a NEW superadmin-"
            "controlled mesh on THIS machine: mint the Casdoor/DB/observability "
            "secrets + a fresh superadmin, bring up the full platform stack, and (in "
            "prod) attach the tailscale overlay. Nothing runs until you acknowledge "
            "the plan below.")
        intro.setWordWrap(True)
        lay.addWidget(intro)

        # ENV test/prod.
        self.env_group = QtWidgets.QButtonGroup(self)
        self.env_test = QtWidgets.QRadioButton("test — LAN-only / offline (safe default)")
        self.env_prod = QtWidgets.QRadioButton("prod — real public domain")
        self.env_test.setChecked(True)
        self.env_group.addButton(self.env_test)
        self.env_group.addButton(self.env_prod)
        envrow = QtWidgets.QHBoxLayout()
        envrow.addWidget(self.env_test)
        envrow.addWidget(self.env_prod)
        envrow.addStretch(1)
        lay.addWidget(_row("Environment", self._wrap(envrow)))

        self.superadmin = QtWidgets.QLineEdit("superadmin")
        self.superadmin.setToolTip(
            "The platform superadmin login to mint. Its password is generated fresh "
            "and written ONLY to the offline secrets bundle — never shown here.")
        lay.addWidget(_row("Superadmin", self.superadmin))

        self.social = QtWidgets.QCheckBox("Also bring up the social (Matrix/Mastodon) profile")
        lay.addWidget(self.social)

        # prod-only overlay group.
        self.prod_group = QtWidgets.QGroupBox("Mesh overlay (prod only)")
        pg = QtWidgets.QVBoxLayout(self.prod_group)
        self.boot_domain = QtWidgets.QLineEdit()
        self.boot_domain.setPlaceholderText("public apex domain, e.g. example.com (required in prod)")
        pg.addWidget(_row("Domain", self.boot_domain))
        self.boot_auth_key = QtWidgets.QLineEdit()
        self.boot_auth_key.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.boot_auth_key.setPlaceholderText("tskey-… (required in prod — attaches the overlay)")
        pg.addWidget(_row("Auth key", self.boot_auth_key))
        self.boot_login_server = QtWidgets.QLineEdit()
        self.boot_login_server.setPlaceholderText("optional self-hosted headscale URL")
        pg.addWidget(_row("Login server", self.boot_login_server))
        lay.addWidget(self.prod_group)

        # Plan preview (read-only) — the confirm-before-run surface.
        lay.addWidget(QtWidgets.QLabel("Plan preview (what will be generated + started):"))
        self.plan_view = QtWidgets.QPlainTextEdit()
        self.plan_view.setReadOnly(True)
        self.plan_view.setLineWrapMode(QtWidgets.QPlainTextEdit.LineWrapMode.NoWrap)
        f = self.plan_view.font()
        f.setStyleHint(f.StyleHint.Monospace)
        f.setFamily("monospace")
        self.plan_view.setFont(f)
        lay.addWidget(self.plan_view, 1)

        self.ack = QtWidgets.QCheckBox(
            "I understand this will MINT credentials and START containers on this machine.")
        lay.addWidget(self.ack)

        brow = QtWidgets.QHBoxLayout()
        self.boot_start_btn = QtWidgets.QPushButton("Generate && start")
        self.boot_down_btn = QtWidgets.QPushButton("Stop")
        self.boot_start_btn.clicked.connect(self._bootstrap_up)
        self.boot_down_btn.clicked.connect(self._bootstrap_down)
        brow.addWidget(self.boot_start_btn)
        brow.addWidget(self.boot_down_btn)
        brow.addStretch(1)
        lay.addLayout(brow)

        # Live-refresh the plan + gate the start button on the acknowledgement.
        self.env_test.toggled.connect(self._refresh_plan)
        self.env_prod.toggled.connect(self._refresh_plan)
        self.superadmin.textChanged.connect(self._refresh_plan)
        self.social.toggled.connect(self._refresh_plan)
        self.boot_domain.textChanged.connect(self._refresh_plan)
        self.boot_auth_key.textChanged.connect(self._refresh_plan)
        self.boot_login_server.textChanged.connect(self._refresh_plan)
        self.ack.toggled.connect(self._sync_boot_gate)
        self._refresh_plan()
        return w

    @staticmethod
    def _wrap(inner_layout) -> QtWidgets.QWidget:
        holder = QtWidgets.QWidget()
        holder.setLayout(inner_layout)
        return holder

    # ── config collection ────────────────────────────────────────────────────────
    def collect(self) -> LocalMeshConfig:
        """JOIN-tab widgets -> LocalMeshConfig."""
        return LocalMeshConfig(
            auth_key=self.auth_key.text().strip(),
            node_name=self.node_name.text().strip(),
            login_server=self.login_server.text().strip(),
        )

    def collect_bootstrap(self) -> LocalMeshBootstrapConfig:
        """BOOTSTRAP-tab widgets -> LocalMeshBootstrapConfig."""
        return LocalMeshBootstrapConfig(
            env=("prod" if self.env_prod.isChecked() else "test"),
            superadmin_username=self.superadmin.text().strip() or "superadmin",
            social=self.social.isChecked(),
            cluster_domain=self.boot_domain.text().strip(),
            auth_key=self.boot_auth_key.text().strip(),
            login_server=self.boot_login_server.text().strip(),
        )

    # ── JOIN handlers (unchanged behavior) ───────────────────────────────────────
    def _refresh_status(self):
        st = self.node.status()
        self.status.setText(f"Status: {'running' if st.running else 'stopped'} ({st.detail})")
        self.stop_btn.setEnabled(st.running)

    def _start(self):
        self.node = LocalMeshNode(self.generator_dir, self.collect())
        ok, why = self.node.available()
        if not ok:
            self.status.setText(f"Cannot start: {why}")
            return
        self.log.appendPlainText("[local-mesh] docker compose up -d …")
        ok, why = self.node.start()
        self.log.appendPlainText(why or ("started" if ok else "failed"))
        self.status.setText("Started." if ok else f"Failed: {why}")
        self._refresh_status()

    def _stop(self):
        ok, why = self.node.stop()
        self.log.appendPlainText(why or ("stopped" if ok else "failed"))
        self.status.setText("Stopped." if ok else f"Failed: {why}")
        self._refresh_status()

    def _logs(self):
        self.log.setPlainText(self.node.logs() or "(no logs — node not started?)")

    # ── BOOTSTRAP handlers ───────────────────────────────────────────────────────
    def _refresh_plan(self):
        prod = self.env_prod.isChecked()
        self.prod_group.setVisible(prod)
        self.boot = LocalMeshBootstrap(self.generator_dir, self.collect_bootstrap())
        self.plan_view.setPlainText(self.boot.plan())
        self._sync_boot_gate()

    def _sync_boot_gate(self):
        # The from-scratch start is gated behind the explicit acknowledgement — nothing
        # is generated or started on mere selection (non-destructive by default).
        self.boot_start_btn.setEnabled(self.ack.isChecked())

    def _bootstrap_up(self):
        if not self.ack.isChecked():
            self.status.setText("Acknowledge the plan first.")
            return
        self.boot = LocalMeshBootstrap(self.generator_dir, self.collect_bootstrap())
        problems = self.boot.validate()
        if problems:
            self.status.setText("Cannot start: " + "; ".join(problems))
            return
        self.log.appendPlainText("[bootstrap] generating credentials + starting the "
                                 "full platform stack from scratch …")
        QtCore.QCoreApplication.processEvents()
        ok, lines = self.boot.up()
        for ln in lines:
            self.log.appendPlainText(ln)
        self.status.setText("Bootstrap complete." if ok else "Bootstrap failed (see log).")
        self._refresh_status()

    def _bootstrap_down(self):
        ok, lines = self.boot.down()
        for ln in lines:
            self.log.appendPlainText(ln)
        self.status.setText("Stopped." if ok else "Stop failed (see log).")
        self._refresh_status()

"""LocalMeshDialog — the modal launcher behind the ModePage's fourth first-screen
choice ("Local Docker mesh"). It runs a dockerized Snapdragon mesh node on THIS
machine (no image build, no server hardware) via the shared MeshNode lifecycle.

Deliberately SELF-CONTAINED (the FleetDialog / golive precedent):
``LocalMeshDialog(generator_dir).exec()`` works without any wizard-page registration,
so gui/wizard.py's page registry does not need to know about this side-flow. It is NOT
a WIZARD_PAGE_SLUGS page — ModePage imports it lazily inside the button handler.

All lifecycle/option logic lives Qt-free in core.local_mesh (LocalMeshConfig /
LocalMeshNode, itself a MeshNode subclass) — this module only collects the widgets into
a LocalMeshConfig and drives start/stop/logs, mirroring how the tray's _ControlTray
drives a MeshNode.
"""
from __future__ import annotations

from ..qt import QtWidgets
from ...core.local_mesh import LocalMeshConfig, LocalMeshNode
from ._widgets import _row


class LocalMeshDialog(QtWidgets.QDialog):
    """Standalone host: ``LocalMeshDialog(generator_dir).exec()`` — no wizard needed.

    The node is (re)built from the current field values on each Start, so the operator
    can correct the auth key and retry without reopening the dialog."""

    def __init__(self, generator_dir: str, parent=None):
        super().__init__(parent)
        self.generator_dir = generator_dir
        self.node = LocalMeshNode(generator_dir, LocalMeshConfig())
        self.setWindowTitle("Run a local Docker mesh node")
        self.resize(640, 520)
        lay = QtWidgets.QVBoxLayout(self)

        intro = QtWidgets.QLabel(
            "Run a Snapdragon mesh node on THIS machine in Docker — no separate server "
            "hardware and no image build. Provide a tailnet/headscale auth key; the "
            "dockerized node joins the mesh and serves locally.")
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

        self.status = QtWidgets.QLabel("")
        self.status.setWordWrap(True)
        lay.addWidget(self.status)

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
        close = QtWidgets.QPushButton("Close")
        close.clicked.connect(self.accept)
        btns.addWidget(close)
        lay.addLayout(btns)

        self.log = QtWidgets.QPlainTextEdit()
        self.log.setReadOnly(True)
        lay.addWidget(self.log, 1)

        self._refresh_status()

    def collect(self) -> LocalMeshConfig:
        """Widget -> LocalMeshConfig (the dialog's whole contract)."""
        return LocalMeshConfig(
            auth_key=self.auth_key.text().strip(),
            node_name=self.node_name.text().strip(),
            login_server=self.login_server.text().strip(),
        )

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

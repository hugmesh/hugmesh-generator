"""System-tray (taskbar) controller for a LOCAL mesh node — start/stop/status/logs the
dockerized node on the host OS (Linux or Windows via Docker Desktop)."""
from __future__ import annotations

from .qt import Qt, QtGui, QtWidgets
from ..core.mesh_node import MeshNode


def _brand_icon() -> QtGui.QIcon:
    """A dependency-free brand icon: a navy rounded square with a white 'S'."""
    pm = QtGui.QPixmap(64, 64)
    pm.fill(Qt.GlobalColor.transparent)
    p = QtGui.QPainter(pm)
    p.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing)
    p.setBrush(QtGui.QColor("#1f2740"))
    p.setPen(QtGui.QColor("#3f5b8c"))
    p.drawRoundedRect(4, 4, 56, 56, 12, 12)
    p.setPen(QtGui.QColor("white"))
    f = p.font(); f.setBold(True); f.setPointSize(30); p.setFont(f)
    p.drawText(pm.rect(), Qt.AlignmentFlag.AlignCenter, "S")
    p.end()
    return QtGui.QIcon(pm)


class MeshTray(QtWidgets.QSystemTrayIcon):
    def __init__(self, generator_dir: str, on_open_studio=None, parent=None):
        super().__init__(_brand_icon(), parent)
        self.node = MeshNode(generator_dir)
        self.on_open_studio = on_open_studio
        self.setToolTip("Snapdragon mesh node")
        menu = QtWidgets.QMenu()
        self.status_act = menu.addAction("Status: (checking…)")
        self.status_act.setEnabled(False)
        menu.addSeparator()
        self.start_act = menu.addAction("Start mesh node")
        self.stop_act = menu.addAction("Stop mesh node")
        self.logs_act = menu.addAction("View logs…")
        menu.addSeparator()
        if on_open_studio:
            menu.addAction("Open Image Studio…").triggered.connect(lambda: on_open_studio())
        menu.addAction("Quit").triggered.connect(QtWidgets.QApplication.quit)
        self.start_act.triggered.connect(self._start)
        self.stop_act.triggered.connect(self._stop)
        self.logs_act.triggered.connect(self._logs)
        self.setContextMenu(menu)
        self._refresh()

    def _notify(self, title, msg):
        self.showMessage(title, msg, _brand_icon(), 4000)

    def _start(self):
        ok, why = self.node.start()
        self._notify("Mesh node", "Started." if ok else f"Failed: {why}")
        self._refresh()

    def _stop(self):
        ok, why = self.node.stop()
        self._notify("Mesh node", "Stopped." if ok else f"Failed: {why}")
        self._refresh()

    def _logs(self):
        dlg = QtWidgets.QDialog()
        dlg.setWindowTitle("Mesh node logs")
        dlg.resize(700, 460)
        lay = QtWidgets.QVBoxLayout(dlg)
        te = QtWidgets.QPlainTextEdit(); te.setReadOnly(True)
        te.setPlainText(self.node.logs())
        lay.addWidget(te)
        dlg.exec()

    def _refresh(self):
        st = self.node.status()
        self.status_act.setText(f"Status: {'running' if st.running else 'stopped'} ({st.detail})")
        self.start_act.setEnabled(not st.running)
        self.stop_act.setEnabled(st.running)

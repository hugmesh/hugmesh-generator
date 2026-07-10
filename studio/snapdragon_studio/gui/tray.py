"""System-tray (taskbar) controllers — start/stop/status/logs a local dockerized
service (a mesh node, or the generator's own dev stack) on the host OS (Linux or
Windows via Docker Desktop)."""
from __future__ import annotations

import webbrowser

from .qt import Qt, QtGui, QtWidgets
from ..core.mesh_node import MeshNode
from ..core.local_stack_node import LocalStackNode


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


class _ControlTray(QtWidgets.QSystemTrayIcon):
    """Shared start/stop/status/logs tray menu for anything shaped like MeshNode/
    LocalStackNode (start()/stop()/status()/logs()). web_url, if given, adds an
    "Open web UI" action that opens it in the default browser."""

    def __init__(self, node, *, label: str, tooltip: str, web_url: str | None = None,
                 on_open_studio=None, on_open_golive=None, parent=None):
        super().__init__(_brand_icon(), parent)
        self.node = node
        self.label = label
        self.web_url = web_url
        self.on_open_studio = on_open_studio
        self.on_open_golive = on_open_golive
        self.setToolTip(tooltip)
        menu = QtWidgets.QMenu()
        self.status_act = menu.addAction("Status: (checking…)")
        self.status_act.setEnabled(False)
        menu.addSeparator()
        self.start_act = menu.addAction(f"Start {label}")
        self.stop_act = menu.addAction(f"Stop {label}")
        self.logs_act = menu.addAction("View logs…")
        if web_url:
            menu.addSeparator()
            menu.addAction("Open web UI…").triggered.connect(self._open_web_ui)
        menu.addSeparator()
        if on_open_studio:
            menu.addAction("Open Image Studio…").triggered.connect(lambda: on_open_studio())
        if on_open_golive:
            menu.addAction("Go Live…").triggered.connect(lambda: on_open_golive())
        menu.addAction("Quit").triggered.connect(QtWidgets.QApplication.quit)
        self.start_act.triggered.connect(self._start)
        self.stop_act.triggered.connect(self._stop)
        self.logs_act.triggered.connect(self._logs)
        self.setContextMenu(menu)
        self._refresh()

    def _notify(self, title, msg):
        self.showMessage(title, msg, _brand_icon(), 4000)

    def _open_web_ui(self):
        webbrowser.open(self.web_url)

    def _start(self):
        ok, why = self.node.start()
        self._notify(self.label, "Started." if ok else f"Failed: {why}")
        self._refresh()
        if ok and self.web_url:
            self._open_web_ui()

    def _stop(self):
        ok, why = self.node.stop()
        self._notify(self.label, "Stopped." if ok else f"Failed: {why}")
        self._refresh()

    def _logs(self):
        dlg = QtWidgets.QDialog()
        dlg.setWindowTitle(f"{self.label} logs")
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


class MeshTray(_ControlTray):
    def __init__(self, generator_dir: str, on_open_studio=None, on_open_golive=None, parent=None):
        super().__init__(MeshNode(generator_dir), label="mesh node",
                          tooltip="Snapdragon mesh node", on_open_studio=on_open_studio,
                          on_open_golive=on_open_golive, parent=parent)


class StackTray(_ControlTray):
    def __init__(self, generator_dir: str, on_open_studio=None, on_open_golive=None, parent=None):
        node = LocalStackNode(generator_dir)
        super().__init__(node, label="local stack", tooltip="Snapdragon local dev stack",
                          web_url=node.web_url, on_open_studio=on_open_studio,
                          on_open_golive=on_open_golive, parent=parent)

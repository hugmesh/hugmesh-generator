"""System-tray (taskbar) controllers — start/stop/status/logs a local dockerized
service (a mesh node, or the generator's own dev stack) on the host OS (Linux or
Windows via Docker Desktop).

DEFAULT launch = ONE icon. A default `python -m snapdragon_studio` builds a single
:class:`CombinedTray` whose context menu carries BOTH the mesh-node and the local-stack
sections (clearly labelled) — the old two-icons-look-identical bug came from appending a
MeshTray AND a StackTray, two indistinguishable navy-'S' QSystemTrayIcons. ``--tray`` /
``--stack-tray`` still show exactly the one section the operator asked for; :func:`build_tray`
is the single factory app.py (and the headless tests) go through.

BUILD BADGE. While an image build runs in the same process as the tray (ProgressPage /
WorklistDriver on a default launch), the icon shows a small corner badge — building N%,
error, or complete. The build->tray channel is a tiny STATUS FILE (not a Qt signal): the
tray and the lazily-created wizard/ProgressPage are decoupled and the wizard window is
normally closed to the tray while the build keeps running, so a file the tray polls on a
QTimer works even with the window closed (and even if a build ever runs out-of-process).
ProgressPage writes it via :func:`write_build_status`; the tray reads it via
:func:`read_build_status` and re-renders through :func:`_render_icon`.
"""
from __future__ import annotations

import json
import os
import webbrowser

from .qt import Qt, QtCore, QtGui, QtWidgets
from ..core.mesh_node import MeshNode
from ..core.local_stack_node import LocalStackNode

_ICON_PX = 64
# the four build states a badge can show; anything else renders as the plain brand icon.
_BUILD_STATES = ("idle", "building", "error", "complete")


# ── brand icon + build-state badge overlay (dependency-free QPainter) ─────────────────
def _brand_pixmap() -> QtGui.QPixmap:
    """A fresh navy rounded square with a white 'S' — the brand mark. Returned fresh each
    call so a badge painter can mutate it without touching a shared pixmap."""
    pm = QtGui.QPixmap(_ICON_PX, _ICON_PX)
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
    return pm


def _brand_icon() -> QtGui.QIcon:
    """The plain brand icon (no build badge)."""
    return QtGui.QIcon(_brand_pixmap())


def _render_icon(state: str = "idle", percent: int | None = None) -> QtGui.QIcon:
    """The brand icon with a dependency-free corner badge painted per build state:

    * ``idle``      -> plain brand icon
    * ``building``  -> a blue progress ring filled to ``percent`` + the number
    * ``error``     -> a red disc with ``!``
    * ``complete``  -> a green disc with ``✓``

    Each state — and each ``building`` percent — yields a visibly different pixmap, so a
    headless test can grab the images and assert they differ.
    """
    pm = _brand_pixmap()
    if state not in ("building", "error", "complete"):
        return QtGui.QIcon(pm)                       # idle / unknown -> plain
    p = QtGui.QPainter(pm)
    p.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing)
    d = 34                                            # badge diameter, bottom-right corner
    rect = QtCore.QRectF(_ICON_PX - d - 1, _ICON_PX - d - 1, d, d)
    if state == "building":
        pct = max(0, min(int(percent or 0), 100))
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(QtGui.QColor("#ffffff"))
        p.drawEllipse(rect)                           # white disc backing
        ring = rect.adjusted(3, 3, -3, -3)
        track = QtGui.QPen(QtGui.QColor("#c9d3e6")); track.setWidth(4)
        p.setPen(track); p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawEllipse(ring)                           # full grey track
        arc = QtGui.QPen(QtGui.QColor("#1a73e8")); arc.setWidth(4)
        p.setPen(arc)
        # Qt arc angles are 1/16°, 0 at 3 o'clock, CCW positive; sweep clockwise from 12.
        p.drawArc(ring, 90 * 16, -int(360 * pct / 100) * 16)
        p.setPen(QtGui.QColor("#1f2740"))
        f = p.font(); f.setBold(True); f.setPointSize(11 if pct < 100 else 9); p.setFont(f)
        p.drawText(rect, Qt.AlignmentFlag.AlignCenter, str(pct))
    else:
        colour, glyph, pt = (("#c5221f", "!", 20) if state == "error"
                             else ("#188038", "✓", 18))
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(QtGui.QColor(colour))
        p.drawEllipse(rect)
        p.setPen(QtGui.QColor("white"))
        f = p.font(); f.setBold(True); f.setPointSize(pt); p.setFont(f)
        p.drawText(rect, Qt.AlignmentFlag.AlignCenter, glyph)
    p.end()
    return QtGui.QIcon(pm)


def _status_suffix(state: str, percent: int | None) -> str:
    if state == "building":
        return f" — building {int(percent or 0)}%"
    if state == "error":
        return " — build FAILED"
    if state == "complete":
        return " — build complete"
    return ""


# ── build-status channel: a tiny JSON file the tray polls (works window-closed) ───────
def build_status_path() -> str:
    """The tray<->build status file. Honours ``$SNAPDRAGON_STUDIO_STATE_DIR`` (for tests /
    hygiene); defaults to ``~/.snapdragon/studio/build-status.json``."""
    base = os.environ.get("SNAPDRAGON_STUDIO_STATE_DIR") or os.path.join(
        os.path.expanduser("~"), ".snapdragon", "studio")
    return os.path.join(base, "build-status.json")


def write_build_status(state: str, *, percent: int | None = None,
                       running: int = 0, total: int = 0) -> None:
    """Atomically write the tiny build-status JSON the tray polls. Best-effort — a build
    must NEVER crash because its status file could not be written."""
    path = build_status_path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = f"{path}.{os.getpid()}.tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump({"state": state, "percent": percent,
                       "running": running, "total": total}, fh)
        os.replace(tmp, path)
    except OSError:
        pass


def read_build_status() -> dict | None:
    """The current build status, or ``None`` if the file is absent/unreadable/corrupt
    (a missing or stale file reads as idle)."""
    try:
        with open(build_status_path(), encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


# ── one controllable node per menu section ────────────────────────────────────────────
class _Section:
    """One controllable node (a mesh node or the local stack) inside a tray menu: owns its
    Start/Stop/View-logs (+ optional Open-web-UI) actions and a status line, and knows how
    to refresh them from ``node.status()``. Its owning tray is injected by _ControlTray."""

    def __init__(self, node, *, label: str, web_url: str | None = None):
        self.node = node
        self.label = label
        self.web_url = web_url
        self.tray: _ControlTray | None = None
        self.status_act = None
        self.start_act = None
        self.stop_act = None
        self.logs_act = None

    def add_to_menu(self, menu: QtWidgets.QMenu) -> None:
        self.status_act = menu.addAction(f"{self.label}: (checking…)")
        self.status_act.setEnabled(False)
        self.start_act = menu.addAction(f"Start {self.label}")
        self.stop_act = menu.addAction(f"Stop {self.label}")
        self.logs_act = menu.addAction(f"View {self.label} logs…")
        if self.web_url:
            menu.addAction(f"Open {self.label} web UI…").triggered.connect(self._open_web_ui)
        self.start_act.triggered.connect(self._start)
        self.stop_act.triggered.connect(self._stop)
        self.logs_act.triggered.connect(self._logs)

    def _open_web_ui(self) -> None:
        webbrowser.open(self.web_url)

    def _start(self) -> None:
        ok, why = self.node.start()
        self.tray._notify(self.label, "Started." if ok else f"Failed: {why}")
        self.tray._refresh()
        if ok and self.web_url:
            self._open_web_ui()

    def _stop(self) -> None:
        ok, why = self.node.stop()
        self.tray._notify(self.label, "Stopped." if ok else f"Failed: {why}")
        self.tray._refresh()

    def _logs(self) -> None:
        dlg = QtWidgets.QDialog()
        dlg.setWindowTitle(f"{self.label} logs")
        dlg.resize(700, 460)
        lay = QtWidgets.QVBoxLayout(dlg)
        te = QtWidgets.QPlainTextEdit(); te.setReadOnly(True)
        te.setPlainText(self.node.logs())
        lay.addWidget(te)
        dlg.exec()

    def refresh(self) -> None:
        st = self.node.status()
        self.status_act.setText(
            f"{self.label}: {'running' if st.running else 'stopped'} ({st.detail})")
        self.start_act.setEnabled(not st.running)
        self.stop_act.setEnabled(st.running)


class _ControlTray(QtWidgets.QSystemTrayIcon):
    """One QSystemTrayIcon carrying one or more :class:`_Section` menu blocks, plus the
    shared Open Studio / Go Live / Quit actions, plus the build-status badge poller."""

    def __init__(self, sections, *, tooltip: str, on_open_studio=None,
                 on_open_golive=None, parent=None):
        super().__init__(_brand_icon(), parent)
        self.sections = list(sections)
        for s in self.sections:
            s.tray = self
        self._tooltip = tooltip
        self._build_state = "idle"
        self._build_percent: int | None = None
        self.setToolTip(tooltip)
        menu = QtWidgets.QMenu()
        for i, s in enumerate(self.sections):
            if i:
                menu.addSeparator()
            s.add_to_menu(menu)
        menu.addSeparator()
        if on_open_studio:
            menu.addAction("Open Image Studio…").triggered.connect(lambda: on_open_studio())
        if on_open_golive:
            menu.addAction("Go Live…").triggered.connect(lambda: on_open_golive())
        menu.addAction("Quit").triggered.connect(QtWidgets.QApplication.quit)
        self.setContextMenu(menu)
        self._refresh()
        # poll the build-status file so the icon shows build progress even when the wizard
        # window is closed to the tray (and even if a build ever runs out-of-process).
        self._poll = QtCore.QTimer(self)
        self._poll.setInterval(1000)
        self._poll.timeout.connect(self._poll_build_status)
        self._poll.start()
        self._poll_build_status()

    def _notify(self, title, msg) -> None:
        self.showMessage(title, msg, _brand_icon(), 4000)

    def _refresh(self) -> None:
        for s in self.sections:
            s.refresh()

    # ---- build badge --------------------------------------------------------------
    def set_build_state(self, state: str, percent: int | None = None) -> None:
        """Repaint the icon + tooltip for a build state (idle/building/error/complete)."""
        if state not in _BUILD_STATES:
            state = "idle"
        self._build_state = state
        self._build_percent = percent
        self.setIcon(_render_icon(state, percent))
        self.setToolTip(self._tooltip + _status_suffix(state, percent))

    def _poll_build_status(self) -> None:
        data = read_build_status()
        if not data:
            state, percent = "idle", None
        else:
            state, percent = data.get("state", "idle"), data.get("percent")
        if state != self._build_state or percent != self._build_percent:
            self.set_build_state(state, percent)


# ── section factories + single-section wrappers + the ONE-tray factory ────────────────
def _mesh_section(generator_dir: str) -> _Section:
    return _Section(MeshNode(generator_dir), label="mesh node")


def _stack_section(generator_dir: str) -> _Section:
    node = LocalStackNode(generator_dir)
    return _Section(node, label="local stack", web_url=node.web_url)


class MeshTray(_ControlTray):
    """`--tray`: one icon, the mesh-node section only."""

    def __init__(self, generator_dir: str, on_open_studio=None, on_open_golive=None, parent=None):
        super().__init__([_mesh_section(generator_dir)], tooltip="Snapdragon mesh node",
                         on_open_studio=on_open_studio, on_open_golive=on_open_golive,
                         parent=parent)


class StackTray(_ControlTray):
    """`--stack-tray`: one icon, the local-stack section only."""

    def __init__(self, generator_dir: str, on_open_studio=None, on_open_golive=None, parent=None):
        super().__init__([_stack_section(generator_dir)], tooltip="Snapdragon local dev stack",
                         on_open_studio=on_open_studio, on_open_golive=on_open_golive,
                         parent=parent)


class CombinedTray(_ControlTray):
    """The DEFAULT launch tray: ONE icon whose menu carries BOTH the mesh-node and the
    local-stack sections (clearly labelled), plus Open Studio / Go Live / Quit."""

    def __init__(self, generator_dir: str, on_open_studio=None, on_open_golive=None, parent=None):
        super().__init__([_mesh_section(generator_dir), _stack_section(generator_dir)],
                         tooltip="Snapdragon Image Studio", on_open_studio=on_open_studio,
                         on_open_golive=on_open_golive, parent=parent)


def build_tray(generator_dir: str, *, show_mesh: bool = True, show_stack: bool = True,
               on_open_studio=None, on_open_golive=None, parent=None) -> _ControlTray:
    """Return exactly ONE QSystemTrayIcon for the requested sections:

    * default (both)  -> :class:`CombinedTray` (mesh + stack in one labelled menu)
    * ``--tray``      -> :class:`MeshTray`  (mesh only)
    * ``--stack-tray``-> :class:`StackTray` (stack only)

    app.py calls this behind its ``isSystemTrayAvailable()`` guard; headless tests call it
    directly (that guard is False on the offscreen platform) to assert the default path
    instantiates exactly one QSystemTrayIcon.
    """
    kw = dict(on_open_studio=on_open_studio, on_open_golive=on_open_golive, parent=parent)
    if show_mesh and show_stack:
        return CombinedTray(generator_dir, **kw)
    if show_stack:
        return StackTray(generator_dir, **kw)
    return MeshTray(generator_dir, **kw)

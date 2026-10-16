"""System-tray (taskbar) controllers — start/stop/status/logs a local dockerized
service (a mesh node, or the generator's own dev stack) on the host OS (Linux or
Windows via Docker Desktop).

DEFAULT launch = ONE icon. A default `python -m hugmesh_studio` builds a single
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
from .branding_icon import (
    ICON_PX as _ICON_PX, brand_icon as _brand_icon, brand_pixmap as _brand_pixmap)
from ..core import build_sessions
from ..core import resource_limits as _resource_limits
from ..core.mesh_node import MeshNode
from ..core.local_stack_node import LocalStackNode
from ..core.state_paths import state_dir

# the four build states a badge can show; anything else renders as the plain brand icon.
_BUILD_STATES = ("idle", "building", "error", "complete")

# ASK 16 — the "Running builds" submenu label and its honest empty row.
RUNNING_BUILDS_LABEL = "Running builds"
NO_RUNNING_BUILDS = "(no builds running)"

#: The resource-limits entry. The label carries the CURRENT setting so the operator
#: can read it without opening anything — a menu item that says only "Resource
#: limits…" makes you open a dialog to answer "am I limited right now?".
LIMITS_LABEL = "Resource limits…"


def limits_menu_label(limits=None) -> str:
    """The tray label for the current limits, e.g. "Resource limits: 7 CPU, 23808m…"."""
    limits = _resource_limits.effective() if limits is None else limits
    if limits.is_unlimited():
        return "Resource limits: none…"
    return f"Resource limits: {limits.describe()}…"


def _log_swallowed(where: str) -> None:
    import sys
    import traceback
    print(f"tray: swallowed exception in {where}", file=sys.stderr)
    traceback.print_exc(file=sys.stderr)


def unlistable_builds_text(n: int) -> str:
    """The honest stand-in for running builds this menu could not render.

    Dropping them silently would be a lie by omission — the roster would say fewer
    builds are running than really are. A disabled row says so instead.
    """
    return f"({n} running build{'' if n == 1 else 's'} could not be listed)"


def menu_label(session) -> str:
    """A menu-safe label for one session record: its label, else its id, else "build".

    ``QMenu.addAction`` accepts only ``str``. Records are JSON on disk, so this coerces
    rather than trusts — belt to :meth:`..core.build_sessions.BuildSession.from_dict`'s
    braces, because this roster can also be fed by an injected ``builds_provider`` that
    never went through that boundary at all.
    """
    for name in ("label", "id"):
        try:
            # the read itself is guarded, not just the conversion: `getattr` only
            # swallows AttributeError, and a property that raises anything else would
            # otherwise escape from here into a Qt slot.
            value = getattr(session, name, None)
            text = value if isinstance(value, str) else (
                "" if value is None else str(value))
        except Exception:                        # an attribute or __str__ that raises
            continue
        text = text.strip()
        if text:
            return text
    return "build"


# ── build-state badge overlay (dependency-free QPainter) ──────────────────────────────
# The plain brand mark (_brand_pixmap/_brand_icon) now lives in gui/branding_icon.py so
# every top-level window can reuse it; the tray owns only the build-state badge below.
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
    """The tray<->build status file: ``<state>/build-status.json``. The state dir comes
    from :func:`...core.state_paths.state_dir`, the single resolver, so the
    ``$HUGMESH_STUDIO_STATE_DIR`` override and the pytest home-fallback guard apply
    here too."""
    return os.path.join(state_dir(), "build-status.json")


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


# ── ASK 16: the per-build roster behind the "Running builds" submenu ──────────────────
def running_builds() -> list:
    """Every build running RIGHT NOW, as :class:`~..core.build_sessions.BuildSession`
    records, newest first.

    Driven off the session records rather than a second status file, deliberately: the
    aggregate ``build-status.json`` carries one ``{state, percent}`` for the whole
    process and cannot name individual builds, while ``build_sessions`` already models
    exactly one record per dispatch — the same records the Sessions list reads, so the
    tray and the list can never tell different stories.

    ``is_active`` is the honesty gate: a record left at "running" by a SIGKILL'd Studio
    is stale, not running, and never appears here as a clickable entry for a run that no longer exists.
    Records from ANOTHER host stay listed (we cannot probe them, so we do not claim
    they died) — selecting one still opens a window that says what it truthfully can.
    """
    try:
        return [s for s in build_sessions.load_all() if build_sessions.is_active(s)]
    except Exception:            # a broken state dir must never break the tray menu
        return []


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
                 on_open_golive=None, on_open_build=None, builds_provider=None,
                 generator_dir: str = "", parent=None):
        super().__init__(_brand_icon(), parent)
        self.sections = list(sections)
        for s in self.sections:
            s.tray = self
        self._tooltip = tooltip
        self._build_state = "idle"
        self._build_percent: int | None = None
        # ASK 16 — "running builds" with a SUBMENU listing each running build; selecting
        # one opens a window for that build. The provider is injectable so a headless
        # test can drive an exact roster instead of racing real records on disk.
        self._on_open_build = on_open_build
        self._builds_provider = builds_provider or running_builds
        # Where the limits dialog reads the compose service list from, so it can say
        # what a whole-mesh budget means per service.
        self._generator_dir = generator_dir
        self.setToolTip(tooltip)
        menu = QtWidgets.QMenu()
        for i, s in enumerate(self.sections):
            if i:
                menu.addSeparator()
            s.add_to_menu(menu)
        menu.addSeparator()
        self.builds_menu = menu.addMenu(RUNNING_BUILDS_LABEL)
        # repopulate on OPEN, never on a timer: the roster is only interesting at the
        # moment the operator looks at it, and re-reading records every second to paint
        # a menu nobody has opened is pure waste.
        self.builds_menu.aboutToShow.connect(self.refresh_running_builds)
        self.refresh_running_builds()
        menu.addSeparator()
        # Resource limits belong in the TRAY, not only in the wizard: the tray is what
        # is running while the operator uses the machine for something else, and
        # "the mesh made my laptop unusable" is the problem the setting solves. Also
        # the one place it is reachable when the wizard window is closed.
        self.limits_act = menu.addAction(LIMITS_LABEL)
        self.limits_act.triggered.connect(self._open_limits)
        self.refresh_limits_label()

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

    # ---- resource limits ----------------------------------------------------------
    def refresh_limits_label(self) -> None:
        """Re-read the effective limits and restate them on the menu entry."""
        try:
            self.limits_act.setText(limits_menu_label())
        except Exception:            # pragma: no cover - a label must never take the tray down
            _log_swallowed("refresh_limits_label")
            self.limits_act.setText(LIMITS_LABEL)

    def _open_limits(self) -> None:
        # Imported lazily: the dialog pulls in QtWidgets form machinery that a tray
        # which is never asked for limits should not pay for at startup.
        try:
            from .limits_dialog import open_limits_dialog
            saved = open_limits_dialog(generator_dir=self._generator_dir)
        except Exception:            # pragma: no cover - never let a dialog kill the tray
            _log_swallowed("_open_limits")
            return
        if saved is not None:
            self.refresh_limits_label()
            self._notify("Resource limits saved",
                         "Applies to the next build, stack bring-up or emulated mesh.")

    # ---- ASK 16: running-builds submenu -------------------------------------------
    def refresh_running_builds(self) -> None:
        """Rebuild the submenu to list EXACTLY the builds running right now.

        Guarded end to end — and "end to end" has to mean it. This runs from
        ``aboutToShow``, a Qt slot, and it is ALSO called eagerly by ``__init__``, so
        anything that escapes here does not merely break a menu: it propagates out of
        ``build_tray`` -> ``install_tray`` -> ``app.main()`` and the Studio never starts.
        Only the PROVIDER call used to be inside the try; rendering a row was not, so
        one record whose ``label`` deserialised to a number raised ``TypeError`` out of
        ``QMenu.addAction`` and cost the operator the whole application.

        A row that cannot be rendered now costs THAT ROW — counted and declared, never
        dropped in silence, because a roster that quietly under-reports running builds
        is its own lie. An empty roster shows one DISABLED "(no builds running)" row
        rather than an empty menu, so the operator can tell "nothing is running" apart
        from "the menu is broken"."""
        try:
            self._populate_running_builds()
        except Exception:                        # pragma: no cover - defence in depth
            _log_swallowed("_ControlTray.refresh_running_builds")
            try:
                self.builds_menu.clear()
                self.builds_menu.addAction(NO_RUNNING_BUILDS).setEnabled(False)
            except Exception:
                pass

    def _populate_running_builds(self) -> None:
        self.builds_menu.clear()
        try:
            builds = list(self._builds_provider() or [])
        except Exception:                # a broken state dir costs an empty roster only
            _log_swallowed("_ControlTray builds provider")
            builds = []
        listed = unlistable = 0
        for s in builds:
            try:
                act = self.builds_menu.addAction(menu_label(s))
                act.triggered.connect(
                    lambda _checked=False, sess=s: self._open_build(sess))
                listed += 1
            except Exception:
                _log_swallowed("_ControlTray running-builds row")
                unlistable += 1
        if unlistable:
            self.builds_menu.addAction(
                unlistable_builds_text(unlistable)).setEnabled(False)
        elif not listed:
            self.builds_menu.addAction(NO_RUNNING_BUILDS).setEnabled(False)

    def _open_build(self, session) -> None:
        try:
            if self._on_open_build is not None:
                self._on_open_build(session)
        except Exception:
            import sys
            import traceback
            print("tray: swallowed exception in _open_build", file=sys.stderr)
            traceback.print_exc(file=sys.stderr)

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

    def __init__(self, generator_dir: str, on_open_studio=None, on_open_golive=None,
                 on_open_build=None, builds_provider=None, parent=None):
        super().__init__([_mesh_section(generator_dir)], tooltip="HugMesh mesh node",
                         on_open_studio=on_open_studio, on_open_golive=on_open_golive,
                         on_open_build=on_open_build, builds_provider=builds_provider,
                         generator_dir=generator_dir, parent=parent)


class StackTray(_ControlTray):
    """`--stack-tray`: one icon, the local-stack section only."""

    def __init__(self, generator_dir: str, on_open_studio=None, on_open_golive=None,
                 on_open_build=None, builds_provider=None, parent=None):
        super().__init__([_stack_section(generator_dir)], tooltip="HugMesh local dev stack",
                         on_open_studio=on_open_studio, on_open_golive=on_open_golive,
                         on_open_build=on_open_build, builds_provider=builds_provider,
                         generator_dir=generator_dir, parent=parent)


class CombinedTray(_ControlTray):
    """The DEFAULT launch tray: ONE icon whose menu carries BOTH the mesh-node and the
    local-stack sections (clearly labelled), plus Running builds / Open Studio / Go
    Live / Quit."""

    def __init__(self, generator_dir: str, on_open_studio=None, on_open_golive=None,
                 on_open_build=None, builds_provider=None, parent=None):
        super().__init__([_mesh_section(generator_dir), _stack_section(generator_dir)],
                         tooltip="HugMesh Image Studio", on_open_studio=on_open_studio,
                         on_open_golive=on_open_golive, on_open_build=on_open_build,
                         builds_provider=builds_provider, generator_dir=generator_dir,
                         parent=parent)


def build_tray(generator_dir: str, *, show_mesh: bool = True, show_stack: bool = True,
               on_open_studio=None, on_open_golive=None, on_open_build=None,
               builds_provider=None, parent=None) -> _ControlTray:
    """Return exactly ONE QSystemTrayIcon for the requested sections:

    * default (both)  -> :class:`CombinedTray` (mesh + stack in one labelled menu)
    * ``--tray``      -> :class:`MeshTray`  (mesh only)
    * ``--stack-tray``-> :class:`StackTray` (stack only)

    app.py calls this behind its ``isSystemTrayAvailable()`` guard; headless tests call it
    directly (that guard is False on the offscreen platform) to assert the default path
    instantiates exactly one QSystemTrayIcon.
    """
    kw = dict(on_open_studio=on_open_studio, on_open_golive=on_open_golive,
              on_open_build=on_open_build, builds_provider=builds_provider,
              parent=parent)
    if show_mesh and show_stack:
        return CombinedTray(generator_dir, **kw)
    if show_stack:
        return StackTray(generator_dir, **kw)
    return MeshTray(generator_dir, **kw)

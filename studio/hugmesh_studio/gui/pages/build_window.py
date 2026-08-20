"""ASK 15 — clicking a build opens its OWN window: resume / view artifacts / edit / delete.

The Sessions screen's build list (``sessions_widget.PreviousBuildsWidget``) offered its
actions as a row of buttons under the table, enabled or disabled by selection. The ask
is a per-build WINDOW: click the entry, get a window about that build.

The part that matters more than the window is the honesty rule the lane sets:

    *derive the available actions from the build's real state rather than offering
    dead buttons.*

So :func:`actions_for` is a PURE function of one row — no widgets, no wizard — and it
is the single source of truth for both the window's buttons and the table's "Next"
column. Every refusal carries the REASON, shown as the button's tooltip and (for the
primary action) inline in the window, because a greyed button with no explanation is
its own kind of lie. In particular:

* a build that **completed** cannot be resumed — there is nothing to resume;
* a build whose **artifact directory is empty or gone** cannot show artifacts;
* a build **running in another Studio process** may be neither resumed nor deleted;
* a **pre-session** (unmanaged) tree has no config snapshot, so neither resume nor edit
  applies — which the old widget already knew, and this keeps.

The window is a real top-level window (``Qt.WindowType.Window``), parented to the
Studio so it can never outlive the app, and it is **not modal**: the ask is to be able
to look at a build while other things carry on.

Qt duality: PySide6 in the venv, PyQt6 for the operator — every slot here is
exception-guarded, because an escaping exception in a PyQt6 slot calls qFatal.
"""
from __future__ import annotations

import os
import sys
import traceback

from ..qt import Qt, QtWidgets, Signal
from ..styles import muted
from ...core import build_sessions

__all__ = ["Action", "ACTIONS", "actions_for", "next_action", "BuildActionsWindow"]

# the four the ask names, in the order the window lays them out
ACTIONS = ("resume", "artifacts", "edit", "delete")

_LABELS = {
    "resume": "Resume build",
    "artifacts": "View artifacts",
    "edit": "Edit as a new build",
    "delete": "Delete",
    "log": "View errors / log",
}


#: Shown when the build's STATE would allow an action but this window was constructed
#: without anything to carry it out. A button with nothing behind it looks alive, does
#: nothing when clicked, and is exactly the dead button ask 15 forbids — so the window
#: refuses to enable one, whatever its caller forgot to wire.
NO_HANDLER_REASON = (
    "This window cannot perform that action — it was opened without a handler for "
    "it. Open the build from the Studio’s “Previous builds” list, which wires all "
    "of them.")


def _log_swallowed(where: str) -> None:
    print(f"build_window: swallowed exception in {where}", file=sys.stderr)
    traceback.print_exc(file=sys.stderr)


class Action:
    """One offered action: whether it applies, and — when it does not — why."""

    __slots__ = ("name", "enabled", "reason")

    def __init__(self, name: str, enabled: bool, reason: str = ""):
        self.name = name
        self.enabled = enabled
        self.reason = reason

    @property
    def label(self) -> str:
        return _LABELS.get(self.name, self.name)

    def __repr__(self) -> str:                       # pragma: no cover - debugging
        return f"Action({self.name}, enabled={self.enabled}, reason={self.reason!r})"


def _has_artifacts(path: str) -> bool:
    """True when the location exists AND holds something. An empty session dir means
    the run produced nothing, and "View artifacts" on it would open an empty folder."""
    try:
        return bool(path) and os.path.isdir(path) and bool(os.listdir(path))
    except OSError:
        return False


def actions_for(row) -> dict[str, Action]:
    """The actions offered for one build-list row, derived from its REAL state.

    ``row`` is a ``sessions_widget._RowData`` (duck-typed: ``kind``, ``status``,
    ``location``, ``session``). Pure — no widgets, no filesystem writes — so the table,
    the window and the tests all read the same answer.
    """
    kind = getattr(row, "kind", "session")
    status = getattr(row, "status", "unknown")
    location = getattr(row, "location", "") or ""
    session = getattr(row, "session", None)
    active = bool(session is not None and build_sessions.is_active(session))

    # ── resume ──────────────────────────────────────────────────────────────────
    if kind != "session":
        resume = Action("resume", False,
                        "No config snapshot exists for a pre-session build — there is "
                        "nothing to resume from.")
    elif active:
        resume = Action("resume", False,
                        "This build is running in another Studio process — stop it "
                        "there first.")
    elif status == build_sessions.COMPLETE:
        resume = Action("resume", False,
                        "This build finished successfully — there is nothing to "
                        "resume. Use “Edit as a new build” to build it again.")
    elif not os.path.isdir(location):
        resume = Action("resume", False,
                        "Its build directory no longer exists:\n"
                        f"{location}\nUse “Edit as a new build” instead.")
    else:
        resume = Action("resume", True)

    # ── artifacts ───────────────────────────────────────────────────────────────
    if kind == "unreadable":
        artifacts = Action("artifacts", False,
                           "This record could not be parsed, so it points at no "
                           "build directory.")
    elif not os.path.isdir(location):
        artifacts = Action("artifacts", False,
                           f"The build directory no longer exists:\n{location}")
    elif not _has_artifacts(location):
        artifacts = Action("artifacts", False,
                           "This build produced no files — its directory is empty.")
    else:
        artifacts = Action("artifacts", True)

    # ── edit (REDO: load the config back into the wizard as a NEW build) ─────────
    if kind != "session":
        edit = Action("edit", False,
                      "No config snapshot exists for a pre-session build.")
    else:
        edit = Action("edit", True)

    # ── delete ──────────────────────────────────────────────────────────────────
    if active:
        delete = Action("delete", False,
                        "This build is running in another Studio process — stop it "
                        "there first.")
    else:
        delete = Action("delete", True)

    # ── log (kept from the existing widget: never lose an affordance) ────────────
    has_log = (kind == "session"
               or (kind == "unmanaged" and getattr(row.unmanaged, "has_log", False))
               or kind == "unreadable")
    log = Action("log", bool(has_log),
                 "" if has_log else "No build.log was found next to this tree.")

    return {"resume": resume, "artifacts": artifacts, "edit": edit,
            "delete": delete, "log": log}


def next_action(row) -> str:
    """What can be done NEXT with this build — the table's at-a-glance column.

    A single honest word per row, in the order the operator would actually reach for:
    a live build is watched, a stopped/failed one is resumed, a finished one's output
    is opened, a configuration-only leftover is edited, and anything else is cleanup.
    """
    session = getattr(row, "session", None)
    if session is not None and build_sessions.is_active(session):
        return "running — open to watch"
    acts = actions_for(row)
    if acts["resume"].enabled:
        return "resume"
    if acts["artifacts"].enabled:
        return "open artifacts"
    if acts["edit"].enabled:
        return "edit as new"
    if acts["delete"].enabled:
        return "delete"
    return "—"


class BuildActionsWindow(QtWidgets.QWidget):
    """The per-build window ask 15 asks for.

    Non-modal, top-level, parented to the Studio (so it cannot outlive the app). Each
    button is enabled by :meth:`offered` — the build's real state (:func:`actions_for`)
    AND a handler that can actually carry the action out. A disabled one keeps its
    reason as a tooltip AND the window states the primary refusal inline, so the
    operator is never left guessing why a button is grey.
    """

    #: This window went off screen. A plain ``QWidget`` has no ``finished`` (that is a
    #: QDialog's), and ``destroyed`` fires only when Qt finally collects the C++ object
    #: — far too late to answer "does the process still have a reason to exist?". Sent
    #: from ``hideEvent``, so by the time a listener runs the window really is gone.
    closed = Signal()

    def __init__(self, row, *, on_resume=None, on_artifacts=None, on_edit=None,
                 on_delete=None, on_log=None, parent=None):
        super().__init__(parent, Qt.WindowType.Window)
        self.row = row
        self._handlers = {"resume": on_resume, "artifacts": on_artifacts,
                          "edit": on_edit, "delete": on_delete, "log": on_log}
        self.actions = actions_for(row)
        self.setWindowTitle(f"Build — {getattr(row, 'label', 'build')}")
        self.resize(560, 300)

        lay = QtWidgets.QVBoxLayout(self)
        head = QtWidgets.QLabel(f"<b>{getattr(row, 'label', 'build')}</b>")
        head.setTextFormat(Qt.TextFormat.RichText)
        lay.addWidget(head)

        self.status_label = QtWidgets.QLabel(
            f"{row.status_text()}   ·   {getattr(row, 'when', '') or 'no timestamp'}")
        lay.addWidget(self.status_label)

        loc = QtWidgets.QLabel(getattr(row, "location", "") or "")
        loc.setWordWrap(True)
        loc.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        loc.setStyleSheet(muted())
        lay.addWidget(loc)

        self.buttons: dict[str, QtWidgets.QPushButton] = {}
        for name in (*ACTIONS, "log"):
            act = self.offered(name)
            btn = QtWidgets.QPushButton(act.label)
            btn.setEnabled(act.enabled)
            btn.setToolTip(act.reason)
            btn.clicked.connect(lambda _=False, n=name: self._fire(n))
            self.buttons[name] = btn
            lay.addWidget(btn)

        # the primary refusal, stated in the open rather than hidden in a tooltip
        self.note = QtWidgets.QLabel(self._blocked_text())
        self.note.setWordWrap(True)
        self.note.setStyleSheet(muted())
        self.note.setVisible(bool(self.note.text()))
        lay.addWidget(self.note)
        lay.addStretch(1)

        close = QtWidgets.QPushButton("Close")
        close.clicked.connect(self.close)
        lay.addWidget(close, 0, Qt.AlignmentFlag.AlignRight)

    def hideEvent(self, ev):  # noqa: N802 (Qt override)
        """Announce that the window left the screen. Guarded: this is a Qt event
        handler, and an escaping exception under PyQt6 calls qFatal."""
        try:
            super().hideEvent(ev)
        finally:
            try:
                self.closed.emit()
            except Exception:                    # pragma: no cover - defence in depth
                _log_swallowed("BuildActionsWindow.hideEvent")

    # ---- what this window can truthfully offer ---------------------------------------
    def offered(self, name: str) -> Action:
        """The action as THIS window can offer it: the build's real state, narrowed by
        whether anything is wired up to carry it out.

        ``actions_for`` answers "may this build be resumed?"; it cannot know whether the
        caller passed an ``on_resume``. A window opened without one (the tray's
        per-build window used to be exactly that) would show a live-looking button whose
        click did nothing at all — a dead button wearing an enabled face. Gating here
        makes that impossible by construction rather than by remembering to wire.
        """
        act = self.actions[name]
        if act.enabled and self._handlers.get(name) is None:
            return Action(name, False, NO_HANDLER_REASON)
        return act

    def _blocked_text(self) -> str:
        blocked = [self.offered(n) for n in ACTIONS]
        return "\n".join(f"• {a.label}: {a.reason}"
                         for a in blocked if not a.enabled and a.reason)

    def _fire(self, name: str) -> None:
        """Run an action's handler. Re-checks :meth:`offered` at CLICK time rather than
        trusting the enablement baked at construction — a build can finish, or another
        Studio can take it, while this window sits open."""
        try:
            self.actions = actions_for(self.row)
            fresh = self.offered(name)
            if not fresh.enabled:
                self.refresh()
                QtWidgets.QMessageBox.warning(self, fresh.label,
                                              fresh.reason or "No longer available.")
                return
            handler = self._handlers.get(name)
            if handler is None:                  # pragma: no cover - offered() forbids it
                return
            handler(self.row)
            if name == "delete":
                self.close()
        except Exception:
            _log_swallowed(f"BuildActionsWindow._fire({name})")

    def refresh(self) -> None:
        """Re-derive every button from the build's CURRENT state."""
        try:
            self.actions = actions_for(self.row)
            for name, btn in self.buttons.items():
                act = self.offered(name)
                btn.setEnabled(act.enabled)
                btn.setToolTip(act.reason)
            self.note.setText(self._blocked_text())
            self.note.setVisible(bool(self.note.text()))
        except Exception:
            _log_swallowed("BuildActionsWindow.refresh")

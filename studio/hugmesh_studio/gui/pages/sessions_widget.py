"""PreviousBuildsWidget — the Welcome screen's first-class "Previous builds" manager.

A capped-height, searchable table of persisted build sessions
(:mod:`...core.build_sessions`) plus best-effort DISCOVERED pre-session ``wl-*.*``
build dirs under the default out dir ("unmanaged" — status honestly ``unknown``,
never fabricated) and any unreadable/corrupt record files (surfaced as rows, never a
crash). Selecting a session offers RESTART (same config, SAME session dir, honoring
--resume), REDO (load the config back into the wizard as a NEW session), open-
artifacts, and a view-errors/log dialog that renders the persisted per-image error
tails — or, for a stale "running" record, the honest "process gone" text, never an
upgrade to complete.

The whole groupbox hides itself when there are zero rows, so a first-run Welcome
screen renders pixel-identical to before this widget existed.
"""
from __future__ import annotations

import os
from datetime import datetime

from ..qt import QtCore, QtGui, QtWidgets
from .. import console
from . import build_window
from ...core import build_sessions
from ...core import secret_files

# status id -> (symbol, colour) — the ProgressPage glyph/colour language, extended
# with the session-only states (unknown/unreadable grey/amber).
_STATUS_GLYPH = {
    "complete": ("✓", "#188038"),
    "failed": ("✗", "#c5221f"),
    "running": ("●", "#1a73e8"),
    "stopped": ("■", "#888888"),
    "unknown": ("?", "#888888"),
    "unreadable": ("?", "#a65d00"),
}

_STATUS_FILTERS = ("all", "complete", "failed", "running", "stopped", "unknown")


def row_identity(row) -> tuple[str, str] | None:
    """The STABLE identity of a build-list row, or ``None`` when it has none.

    :meth:`PreviousBuildsWidget.refresh` rebuilds every :class:`_RowData` from disk, so
    an open per-build window's row object is orphaned by any reload even though its
    build is still listed. Identity — never object identity — is what tells "this build
    is GONE" apart from "the list was reloaded", and EVERY row kind needs one, not just
    sessions: a session is its record id, while an unmanaged tree and an unreadable
    record are each identified by their path on disk. Keying only on ``session.id``
    made every action in an unmanaged/unreadable build's window refuse — with a message
    stating the build had been removed — while the row sat plainly listed above it.

    Duck-typed on purpose (``getattr`` throughout): rows also arrive from
    :meth:`..shell.StudioShell.open_build_window`, which mints its own ``_RowData``.
    """
    kind = getattr(row, "kind", "")
    if kind == "session":
        ident = getattr(getattr(row, "session", None), "id", "") or ""
    elif kind == "unmanaged":
        ident = (getattr(row, "location", "")
                 or getattr(getattr(row, "unmanaged", None), "path", "") or "")
    elif kind == "unreadable":
        ident = getattr(row, "path", "") or getattr(row, "location", "") or ""
    else:
        return None
    if not ident:
        return None
    # paths are normalised (never abspath'd — that would drag the cwd in) so the two
    # sides of a comparison cannot differ by a trailing slash or a "./".
    return (kind, ident if kind == "session" else os.path.normpath(ident))


class _RowData:
    """One table row: a session, an unmanaged build dir, or an unreadable record."""

    def __init__(self, kind, *, session=None, unmanaged=None, path=""):
        self.kind = kind                      # "session" | "unmanaged" | "unreadable"
        self.session = session
        self.unmanaged = unmanaged
        self.path = path
        if kind == "session":
            self.status = session.status
            self.stale = build_sessions.is_stale(session)
            self.label = session.label or session.id
            self.when = session.started or session.created
            self.location = session.workdir
            self.haystack = build_sessions.session_haystack(session)
        elif kind == "unmanaged":
            self.status = "unknown"
            self.stale = False
            self.label = f"{unmanaged.role} · {unmanaged.platform} (unmanaged)"
            self.when = (datetime.fromtimestamp(unmanaged.mtime)
                         .isoformat(timespec="seconds") if unmanaged.mtime else "")
            self.location = unmanaged.path
            self.haystack = build_sessions.unmanaged_haystack(unmanaged)
        else:
            self.status = "unreadable"
            self.stale = False
            self.label = "unreadable record"
            self.when = ""
            self.location = path
            self.haystack = ("unreadable " + os.path.basename(path)).lower()

    # ---- render fragments (pure, unit-testable offscreen) -----------------------
    def status_text(self) -> str:
        sym, _c = _STATUS_GLYPH.get(self.status, ("?", "#888888"))
        if self.kind == "unreadable":
            return "unreadable record"
        if self.status == "failed":
            imgs = self.session.images if self.session else []
            failed = sum(1 for im in imgs if im.get("status") == "failed")
            if imgs:
                return f"{sym} failed · {failed} of {len(imgs)} images"
            return f"{sym} failed"
        if self.status == "running" and self.stale:
            return f"{sym} running (stale?)"
        return f"{sym} {self.status}"

    def images_text(self) -> str:
        if self.kind != "session":
            return "—"
        imgs = self.session.images
        ok = sum(1 for im in imgs if im.get("status") == "ok")
        return f"{ok}/{len(imgs)} ok"

    def visible_for(self, query: str, status_sel: str) -> bool:
        if status_sel != "all" and self.status != status_sel:
            return False
        return build_sessions.matches(self.haystack, query)


class _SessionDetailDialog(QtWidgets.QDialog):
    """View errors/log: the persisted per-image error tails for a failed session, the
    honest "recorded as running; process gone" text for a stale one, or the (possibly
    interleaved) legacy shared build.log for an unmanaged dir. Never fabricates
    status; "open full build.log" defers to the desktop."""

    def __init__(self, row: _RowData, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Build session — errors / log")
        self.resize(760, 480)
        lay = QtWidgets.QVBoxLayout(self)
        head = QtWidgets.QLabel(f"<b>{row.label}</b> — {row.status_text()}")
        head.setTextFormat(QtCore.Qt.TextFormat.RichText)
        lay.addWidget(head)
        text = console.attach(QtWidgets.QPlainTextEdit())
        text.setReadOnly(True)
        text.setPlainText(self._body(row))
        lay.addWidget(text, 1)
        btns = QtWidgets.QHBoxLayout()
        log_path = (row.session.log_path if row.kind == "session"
                    else row.unmanaged.log_path if row.kind == "unmanaged" else "")
        open_log = QtWidgets.QPushButton("Open full build.log")
        open_log.setEnabled(bool(log_path) and os.path.isfile(log_path))
        open_log.clicked.connect(
            lambda: QtGui.QDesktopServices.openUrl(QtCore.QUrl.fromLocalFile(log_path)))
        btns.addWidget(open_log)
        btns.addStretch(1)
        close = QtWidgets.QPushButton("Close")
        close.clicked.connect(self.accept)
        btns.addWidget(close)
        lay.addLayout(btns)

    @staticmethod
    def _body(row: _RowData) -> str:
        if row.kind == "unreadable":
            return (f"This session record could not be parsed:\n  {row.path}\n\n"
                    "It is left untouched on disk (never rewritten).")
        if row.kind == "unmanaged":
            u = row.unmanaged
            parts = [f"Unmanaged build tree (no session record): {u.path}",
                     "Status is unknown — it predates build sessions.", ""]
            if u.has_log:
                parts.append("NOTE: the legacy shared build.log may contain "
                             "INTERLEAVED output from multiple runs:")
                parts.append(_tail_file(u.log_path))
            else:
                parts.append("No build.log found next to it.")
            return "\n".join(parts)
        s = row.session
        parts = []
        if row.status == "running":
            if row.stale:
                parts.append(f"Recorded as running; the Studio process (pid {s.pid}) "
                             "is no longer alive — likely interrupted. Shown as-is; "
                             "the record is never upgraded to a fake terminal state.")
            else:
                parts.append(f"Recorded as running (pid {s.pid} on {s.hostname}).")
            parts.append("")
        for im in s.images:
            parts.append(f"[{im.get('id')}] {im.get('status')}"
                         + (f" (exit {im.get('exit_code')})"
                            if im.get("exit_code") is not None else ""))
        for image_id, tail in (s.error_tail or {}).items():
            parts += ["", f"── error tail: {image_id} (last {len(tail)} lines) ──",
                      *tail]
        if not s.error_tail and row.status == "failed":
            parts.append("\n(no error tail was captured for this run)")
        return "\n".join(parts)


def _tail_file(path: str, lines: int = 200) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return "".join(fh.readlines()[-lines:])
    except OSError as e:
        return f"(could not read {path}: {e})"


class PreviousBuildsWidget(QtWidgets.QGroupBox):
    def __init__(self, wiz, parent=None):
        super().__init__("Previous builds", parent)
        self.wiz = wiz
        self._row_data: list[_RowData] = []
        self._pinned_row = None             # see _selected() / act_on_row()
        lay = QtWidgets.QVBoxLayout(self)

        filt = QtWidgets.QHBoxLayout()
        self.search = QtWidgets.QLineEdit()
        self.search.setPlaceholderText("filter by role, platform, label, status, date…")
        self.search.textChanged.connect(self._apply_filter)
        filt.addWidget(self.search, 1)
        self.status_filter = QtWidgets.QComboBox()
        self.status_filter.addItems(list(_STATUS_FILTERS))
        self.status_filter.currentIndexChanged.connect(lambda _=0: self._apply_filter())
        filt.addWidget(self.status_filter)
        lay.addLayout(filt)

        self.table = QtWidgets.QTableWidget(0, 6)
        # ASK 15 — "options to resume builds should show next": the NEXT column states
        # what can actually be done with each entry, derived from its real state by
        # build_window.next_action (the same source the per-build window's buttons use,
        # so the list and the window can never disagree).
        self.table.setHorizontalHeaderLabels(
            ["Build", "When", "Status", "Next", "Images", "Location"])
        self.table.verticalHeader().setVisible(False)
        self.table.setSelectionBehavior(
            QtWidgets.QAbstractItemView.SelectionBehavior.SelectRows)
        self.table.setSelectionMode(
            QtWidgets.QAbstractItemView.SelectionMode.SingleSelection)
        self.table.setEditTriggers(
            QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
        self.table.setMaximumHeight(200)          # bloat cap — the page stays a page
        self.table.horizontalHeader().setStretchLastSection(True)
        self.table.itemSelectionChanged.connect(self._update_buttons)
        # ASK 15 — clicking a build opens a WINDOW for that build. Both the
        # single-click and the double-click/Enter activation route here; the button row
        # below stays exactly as it was so nothing an operator (or a test) already
        # reaches for is taken away.
        self.table.cellClicked.connect(self._row_clicked)
        self.table.itemActivated.connect(lambda _it: self._open_build_window())
        self._build_windows: list = []      # keep the non-modal windows alive
        lay.addWidget(self.table)

        btns = QtWidgets.QHBoxLayout()
        self.restart_btn = QtWidgets.QPushButton("Restart")
        self.restart_btn.clicked.connect(self._restart)
        self.redo_btn = QtWidgets.QPushButton("Redo (edit as new)")
        self.redo_btn.clicked.connect(self._redo)
        self.open_btn = QtWidgets.QPushButton("Open artifacts")
        self.open_btn.clicked.connect(self._open_artifacts)
        self.log_btn = QtWidgets.QPushButton("View errors/log")
        self.log_btn.clicked.connect(self._view_log)
        for b in (self.restart_btn, self.redo_btn, self.open_btn, self.log_btn):
            btns.addWidget(b)
        btns.addStretch(1)
        # destructive actions live on the right, past the stretch — a session record is a
        # cheap unlink, artifacts a confirmed opt-in; both refuse an in-progress build.
        self.delete_btn = QtWidgets.QPushButton("Delete")
        self.delete_btn.clicked.connect(self._delete)
        self.delete_all_btn = QtWidgets.QPushButton("Delete all finished…")
        self.delete_all_btn.clicked.connect(self._delete_all)
        for b in (self.delete_btn, self.delete_all_btn):
            btns.addWidget(b)
        lay.addLayout(btns)
        self._update_buttons()

    # ---- data --------------------------------------------------------------------
    def _default_out(self) -> str:
        return (self.wiz.cfg.output_dir
                or os.path.join(self.wiz.generator_dir, "out"))

    def refresh(self) -> None:
        """Rebuild the rows from disk: session records newest-first, then unmanaged
        wl-*.* dirs under the default out dir, then unreadable record files. Hides the
        whole groupbox when there is nothing to show (first-run Welcome unchanged)."""
        sessions, unreadable = build_sessions.scan()
        rows = [_RowData("session", session=s) for s in sessions]
        rows += [_RowData("unmanaged", unmanaged=u)
                 for u in build_sessions.discover_unmanaged(self._default_out())]
        rows += [_RowData("unreadable", path=p) for p in unreadable]
        self._row_data = rows
        self.setVisible(bool(rows))
        self.table.setRowCount(len(rows))
        for i, r in enumerate(rows):
            self.table.setItem(i, 0, QtWidgets.QTableWidgetItem(r.label))
            self.table.setItem(i, 1, QtWidgets.QTableWidgetItem(r.when))
            item = QtWidgets.QTableWidgetItem(r.status_text())
            _sym, colour = _STATUS_GLYPH.get(r.status, ("?", "#888888"))
            item.setForeground(QtGui.QBrush(QtGui.QColor(colour)))
            self.table.setItem(i, 2, item)
            nxt = QtWidgets.QTableWidgetItem(build_window.next_action(r))
            nxt.setToolTip("Click the row to open this build in its own window.")
            self.table.setItem(i, 3, nxt)
            self.table.setItem(i, 4, QtWidgets.QTableWidgetItem(r.images_text()))
            loc = QtWidgets.QTableWidgetItem(self._elide(r.location))
            loc.setToolTip(r.location)
            self.table.setItem(i, 5, loc)
        self.table.resizeColumnsToContents()
        self._apply_filter()
        self._update_buttons()
        self._rebind_build_windows()

    def _rebind_build_windows(self) -> None:
        """Point every open per-build window at the FRESH row for its build.

        The reload above replaced every ``_RowData`` object, which is what orphaned an
        open window in the first place. Rebinding here fixes it at the source rather
        than leaving each action to rescue itself, and it also re-derives the window's
        buttons from the state just read off disk (a build that finished, or that
        another Studio took, while the window sat open).

        Best-effort and fully guarded: ``refresh()`` runs from ``initializePage`` — a Qt
        slot, where an escaping exception calls ``qFatal`` under the operator's PyQt6
        binding. A window whose C++ side is already gone raises on attribute access; it
        is simply skipped (``destroyed`` unlists it).
        """
        for win in list(self._build_windows):
            try:
                ident = row_identity(getattr(win, "row", None))
                fresh = self.row_for_identity(ident) if ident is not None else None
                if fresh is not None and fresh is not win.row:
                    win.row = fresh
                win.refresh()
            except Exception:                  # pragma: no cover - defence in depth
                import sys
                import traceback
                print("sessions_widget: swallowed exception in _rebind_build_windows",
                      file=sys.stderr)
                traceback.print_exc(file=sys.stderr)

    @staticmethod
    def _elide(path: str, keep: int = 46) -> str:
        return path if len(path) <= keep else "…" + path[-(keep - 1):]

    def _apply_filter(self) -> None:
        query = self.search.text()
        status_sel = self.status_filter.currentText() or "all"
        for i, r in enumerate(self._row_data):
            self.table.setRowHidden(i, not r.visible_for(query, status_sel))

    # ---- selection / gating --------------------------------------------------------
    def _selected(self) -> _RowData | None:
        # A PINNED row wins over the table's selection. Every action below reads
        # _selected(), which is right for the button row under the table but WRONG for
        # a per-build window (ask 15): that window is about ONE build, and the table's
        # selection moves under it — clicking another row selects it, and refresh()
        # clears the selection outright. Unpinned, "Delete" in build A's window would
        # delete whatever happened to be selected, or silently do nothing. act_on_row()
        # pins for the duration of one action and restores afterwards.
        if self._pinned_row is not None:
            return self._pinned_row
        rows = {ix.row() for ix in self.table.selectedIndexes()}
        if len(rows) != 1:
            return None
        i = rows.pop()
        return self._row_data[i] if 0 <= i < len(self._row_data) else None

    def _update_buttons(self) -> None:
        r = self._selected()
        is_session = r is not None and r.kind == "session"
        self.restart_btn.setEnabled(is_session)
        self.redo_btn.setEnabled(is_session)
        if r is not None and r.kind == "unmanaged":
            tip = ("No config snapshot exists for a pre-session build — "
                   "Restart/Redo need one.")
            self.restart_btn.setToolTip(tip)
            self.redo_btn.setToolTip(tip)
        else:
            self.restart_btn.setToolTip("")
            self.redo_btn.setToolTip("")
        loc_exists = r is not None and os.path.isdir(
            r.location if r.kind != "unreadable" else "")
        self.open_btn.setEnabled(bool(loc_exists))
        self.open_btn.setToolTip("" if loc_exists else
                                 "The artifact directory no longer exists."
                                 if r is not None else "")
        has_log = (is_session
                   or (r is not None and r.kind == "unmanaged" and r.unmanaged.has_log)
                   or (r is not None and r.kind == "unreadable"))
        self.log_btn.setEnabled(bool(r is not None and has_log))
        # Delete: any selected row is deletable (record unlink / tree rmtree); an ACTIVE
        # session shows the blocked reason (the hard guard still re-runs at click time).
        self.delete_btn.setEnabled(r is not None)
        if is_session and build_sessions.is_active(r.session):
            self.delete_btn.setToolTip(
                "This session is running in another Studio process — stop it there "
                "first.")
        else:
            self.delete_btn.setToolTip("")
        self.delete_all_btn.setEnabled(bool(self._row_data))

    # ---- ASK 15: click a build -> its own window -------------------------------------
    def _row_clicked(self, row: int, _col: int) -> None:
        """A click selects the row AND opens its window (clicking a build IS the ask).
        Guarded: a click handler is a Qt slot, and under PyQt6 an escaping exception
        calls qFatal and kills the Studio mid-list."""
        try:
            if 0 <= row < len(self._row_data):
                self.table.selectRow(row)
                self.open_build_window(self._row_data[row])
        except Exception:                      # pragma: no cover - defence in depth
            import sys
            import traceback
            print("sessions_widget: swallowed exception in _row_clicked",
                  file=sys.stderr)
            traceback.print_exc(file=sys.stderr)

    def _open_build_window(self) -> None:
        r = self._selected()
        if r is not None:
            self.open_build_window(r)

    #: per-build action name -> the widget handler that already implements it, with all
    #: its guards (can_restart, the missing-secrets refusal, the fleet routing, the
    #: delete confirmation). One implementation, two faces.
    ROW_ACTIONS = {"resume": "_restart", "artifacts": "_open_artifacts",
                   "edit": "_redo", "delete": "_delete", "log": "_view_log"}

    def row_for_identity(self, ident):
        """The listed row with this :func:`row_identity`, or None when none matches.

        Works for all three row kinds — a session record, an unmanaged build tree and an
        unreadable record file — because all three outlive a list reload on disk.
        """
        if ident is None:
            return None
        for r in self._row_data:
            if row_identity(r) == ident:
                return r
        return None

    def row_for_session(self, session_id: str):
        """The listed row for a session id, or None when nothing on disk matches it."""
        if not session_id:
            return None
        return self.row_for_identity(("session", session_id))

    def act_on_row(self, row, name: str) -> bool:
        """Run one per-build action against **this** row, whatever the table has
        selected. Returns False (with an honest message) when the row is no longer
        listed — a record another Studio deleted while the window sat open.

        The pin is what makes a per-build window correct: the handlers all read
        ``_selected()``, and the table's selection is not the window's build. It is
        restored in a ``finally`` so a handler that raises cannot leave the button row
        under the table permanently pointed at a row nobody selected.
        """
        if row not in self._row_data:
            # refresh() rebuilds _row_data from disk, so an open window's row object is
            # stale after any reload even though the BUILD is still perfectly listed.
            # Re-resolve by IDENTITY — which every row kind has (row_identity), not just
            # sessions: keying on session.id alone made an unmanaged tree's or an
            # unreadable record's window refuse every action, claiming the build had been
            # removed, with the row still listed. Only a build that is genuinely gone
            # from the list refuses.
            fresh = self.row_for_identity(row_identity(row))
            if fresh is None:
                QtWidgets.QMessageBox.warning(
                    self, "Build no longer listed",
                    "This build is no longer in the list — its record was removed or "
                    "the list was reloaded. Refresh and try again.")
                return False
            row = fresh
        handler = getattr(self, self.ROW_ACTIONS[name], None)
        if handler is None:                        # pragma: no cover - table is fixed
            return False
        prev, self._pinned_row = self._pinned_row, row
        try:
            handler()
        finally:
            self._pinned_row = prev
        return True

    def open_build_window(self, row) -> "build_window.BuildActionsWindow":
        """Open (or re-raise) the per-build window for ``row``.

        The five actions are wired to the widget's EXISTING, already-tested handlers
        via :meth:`act_on_row`, so the window is a new face on proven behaviour
        (including every confirmation and refusal) rather than a second implementation
        that could drift from it — and ``act_on_row`` pins the row, so the window acts
        on ITS build rather than on whatever the table happens to have selected. Which
        actions are OFFERED is decided by build_window.actions_for(), from real state.
        """
        ident = row_identity(row)
        for win in list(self._build_windows):
            try:
                open_row = getattr(win, "row", None)
                same = (open_row is row
                        or (ident is not None and row_identity(open_row) == ident))
            except Exception:                  # pragma: no cover - a deleted C++ window
                continue
            if same:
                # the same BUILD, so re-raise its window rather than open a second one —
                # after a reload the row object differs while the build does not.
                win.row = row
                win.refresh()
                win.show()
                win.raise_()
                return win
        win = build_window.BuildActionsWindow(
            row,
            on_resume=lambda r: self.act_on_row(r, "resume"),
            on_artifacts=lambda r: self.act_on_row(r, "artifacts"),
            on_edit=lambda r: self.act_on_row(r, "edit"),
            on_delete=lambda r: self.act_on_row(r, "delete"),
            on_log=lambda r: self.act_on_row(r, "log"),
            parent=self.window())
        self._build_windows.append(win)
        win.destroyed.connect(
            lambda *_a, w=win: self._build_windows.remove(w)
            if w in self._build_windows else None)
        win.show()
        win.raise_()
        return win

    # ---- guards (pure-ish, offscreen-testable) --------------------------------------
    @staticmethod
    def can_restart(session) -> tuple[bool, str]:
        """RESTART gate: refuse a genuinely-running session (another Studio process);
        a deleted workdir means only REDO applies (the caller offers it)."""
        if build_sessions.is_active(session):
            return False, ("This session appears to be running in another Studio "
                           "process — stop it there first.")
        if not os.path.isdir(session.workdir):
            return False, ("Its artifact directory no longer exists:\n"
                           f"{session.workdir}\nUse Redo to build it as a new session.")
        return True, ""

    # ---- actions ---------------------------------------------------------------------
    def _restart(self) -> None:
        r = self._selected()
        if r is None or r.kind != "session":
            return
        s = r.session
        ok, why = self.can_restart(s)
        if not ok:
            if "Redo" in why and QtWidgets.QMessageBox.question(
                    self, "Restart not possible",
                    why + "\n\nLoad its config into the wizard now (Redo)?"
            ) == QtWidgets.QMessageBox.StandardButton.Yes:
                self._redo()
            elif "Redo" not in why:
                QtWidgets.QMessageBox.warning(self, "Restart refused", why)
            return
        if getattr(s, "kind", "wizard") == "fleet":
            # a fleet run restarts through the fleet window, pinned to the SAME
            # record/workdir (prior outcome archived); it lands on the Review step,
            # so "Build fleet now" there IS the confirmation. Deferred import — the
            # fleet channel stays self-contained (welcome.py precedent).
            from . import fleet
            fleet.open_fleet_window(self.wiz, session=s)
            return
        has_trees = any(n.startswith("wl-") for n in
                        (os.listdir(s.workdir) if os.path.isdir(s.workdir) else []))
        box = QtWidgets.QMessageBox(self)
        box.setWindowTitle("Restart build")
        msg = (f"Rebuild into {s.workdir}?\n"
               "Existing artifacts will be reused/overwritten.")
        if s.blanked_secrets:
            msg += ("\n\nNOTE: these secrets were NOT saved with the session and "
                    "will be empty: " + ", ".join(s.blanked_secrets))
        # Held secret FILES (core/secret_files.py): forewarn here, but the actual
        # re-selection prompt is ProgressPage's dispatch gate — it fires for ANY
        # restart path, not just this button, so this text is a courtesy, never
        # the enforcement.
        need = secret_files.missing_for_restart(getattr(s, "held_secret_files", []))
        if need:
            msg += ("\n\nThese secret files were held in memory only (never saved) — "
                    "you will be prompted to re-select them before the build starts: "
                    + ", ".join(
                        f"{r.get('name', '?')} "
                        f"({secret_files.FIELD_LABELS.get(r.get('field', ''), r.get('field', ''))})"
                        for r in need))
        box.setText(msg)
        box.setStandardButtons(QtWidgets.QMessageBox.StandardButton.Ok
                               | QtWidgets.QMessageBox.StandardButton.Cancel)
        resume_cb = QtWidgets.QCheckBox("Resume from existing build tree (--resume)")
        resume_cb.setChecked(has_trees)
        box.setCheckBox(resume_cb)
        if box.exec() != QtWidgets.QMessageBox.StandardButton.Ok:
            return
        self.wiz.start_build_from_session(s, resume=resume_cb.isChecked())

    def _redo(self) -> None:
        r = self._selected()
        if r is None or r.kind != "session":
            return
        s = r.session
        if getattr(s, "kind", "wizard") == "fleet":
            # REDO for a fleet run: load its config into the fleet window as a NEW
            # session (fresh record/workdir minted at Review). No secrets exist in
            # a fleet config, so no blanked-secrets warning applies.
            from . import fleet
            fleet.open_fleet_window(self.wiz, session=s, reuse_record=False)
            return
        self.wiz.load_session(s.config)
        if s.blanked_secrets:
            QtWidgets.QMessageBox.warning(
                self, "Passwords not saved",
                "\n".join(f"{k.replace('_', '-')} was NOT saved (plaintext secret) — "
                          "re-enter it before building from this config"
                          for k in s.blanked_secrets))

    def _open_artifacts(self) -> None:
        r = self._selected()
        if r is None or r.kind == "unreadable" or not os.path.isdir(r.location):
            return
        QtGui.QDesktopServices.openUrl(QtCore.QUrl.fromLocalFile(r.location))

    def _view_log(self) -> None:
        r = self._selected()
        if r is None:
            return
        _SessionDetailDialog(r, parent=self).exec()

    # ---- delete / cleanup ------------------------------------------------------------
    def _delete(self) -> None:
        r = self._selected()
        if r is None:
            return
        if r.kind == "session":
            s = r.session
            if build_sessions.is_active(s):    # re-evaluated at click time, never cached
                QtWidgets.QMessageBox.warning(
                    self, "Delete refused",
                    "This session appears to be running in another Studio process — "
                    "stop it there first.")
                return
            box = QtWidgets.QMessageBox(self)
            box.setWindowTitle("Delete build session")
            box.setText(f"Delete the record for “{r.label}”?")
            box.setStandardButtons(QtWidgets.QMessageBox.StandardButton.Ok
                                   | QtWidgets.QMessageBox.StandardButton.Cancel)
            # records are cheap; the built artifacts on disk may still be wanted, so the
            # rmtree is an explicit opt-in that defaults OFF.
            cb = QtWidgets.QCheckBox("Also delete build artifacts on disk:\n"
                                     + s.workdir)
            cb.setChecked(False)
            box.setCheckBox(cb)
            if box.exec() != QtWidgets.QMessageBox.StandardButton.Ok:
                return
            build_sessions.delete(s, remove_artifacts=cb.isChecked())
        elif r.kind == "unmanaged":
            if QtWidgets.QMessageBox.question(
                    self, "Delete build tree",
                    f"Permanently delete this unmanaged build tree?\n\n{r.location}"
            ) != QtWidgets.QMessageBox.StandardButton.Yes:
                return
            build_sessions.delete_unmanaged(r.unmanaged)
        else:                                  # unreadable record — a cheap unlink
            if QtWidgets.QMessageBox.question(
                    self, "Delete record",
                    f"Delete this unreadable record file?\n\n{r.path}"
            ) != QtWidgets.QMessageBox.StandardButton.Yes:
                return
            build_sessions.delete_path(r.path)
        self.refresh()

    def _delete_all(self) -> None:
        if not self._row_data:
            return
        box = QtWidgets.QMessageBox(self)
        box.setWindowTitle("Delete all finished sessions")
        box.setText("Delete every finished build-session record?\n"
                    "Sessions still running are kept.")
        box.setStandardButtons(QtWidgets.QMessageBox.StandardButton.Ok
                               | QtWidgets.QMessageBox.StandardButton.Cancel)
        cb = QtWidgets.QCheckBox("Also delete build artifacts on disk")
        cb.setChecked(False)                   # parity with per-row: records-only default
        box.setCheckBox(cb)
        if box.exec() != QtWidgets.QMessageBox.StandardButton.Ok:
            return
        deleted, skipped = build_sessions.prune(remove_artifacts=cb.isChecked())
        QtWidgets.QMessageBox.information(
            self, "Delete all finished",
            f"Deleted {deleted}; skipped {skipped} still running.")
        self.refresh()

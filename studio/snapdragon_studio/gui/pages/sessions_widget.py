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
from ...core import build_sessions

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
        text = QtWidgets.QPlainTextEdit()
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

        self.table = QtWidgets.QTableWidget(0, 5)
        self.table.setHorizontalHeaderLabels(
            ["Build", "When", "Status", "Images", "Location"])
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
            self.table.setItem(i, 3, QtWidgets.QTableWidgetItem(r.images_text()))
            loc = QtWidgets.QTableWidgetItem(self._elide(r.location))
            loc.setToolTip(r.location)
            self.table.setItem(i, 4, loc)
        self.table.resizeColumnsToContents()
        self._apply_filter()
        self._update_buttons()

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

    # ---- guards (pure-ish, offscreen-testable) --------------------------------------
    @staticmethod
    def can_restart(session) -> tuple[bool, str]:
        """RESTART gate: refuse a genuinely-running session (another Studio process);
        a deleted workdir means only REDO applies (the caller offers it)."""
        if session.status == "running" and not build_sessions.is_stale(session):
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
        has_trees = any(n.startswith("wl-") for n in
                        (os.listdir(s.workdir) if os.path.isdir(s.workdir) else []))
        box = QtWidgets.QMessageBox(self)
        box.setWindowTitle("Restart build")
        msg = (f"Rebuild into {s.workdir}?\n"
               "Existing artifacts will be reused/overwritten.")
        if s.blanked_secrets:
            msg += ("\n\nNOTE: these secrets were NOT saved with the session and "
                    "will be empty: " + ", ".join(s.blanked_secrets))
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

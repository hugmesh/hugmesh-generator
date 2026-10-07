"""The "Code folders" block of the local-mesh Repo source step (issue #689).

For every domain in the Domains table it lists the apps that domain runs and, per
app, the git checkout compose builds it from — with a button to open that folder
in the file manager. One "Open all" per domain, one "Open source root" for the
mesh. The MAP is :func:`core.code_folders.code_folder_map` (Qt-free: what is on a
domain, which folder, whether it exists, why not); the OPENING is
:func:`core.open_path.open_folder` (Qt-free: verified dispatch). This widget only
draws them and reports what happened.

Two rules this widget exists to keep (the lessons behind #647 and #656):

* A control the operator cannot SEE is not delivered. Every row is a plain grid of
  labels and QPushButtons — no index widgets inside an item view, whose cells can
  size themselves to zero and hide the control (#647). The two text columns are
  :class:`ElidedLabel`, which elides in the middle rather than widening the row, so
  a long domain name or a long path can never push a button out of the viewport
  (the page is a width-locked scroll area: content wider than the viewport is
  simply cut off, with no horizontal scrollbar to reach it).
* No modal dialogs. A folder that is not there is a DISABLED button with the
  reason beside it and in its tooltip; the outcome of an open is an inline note,
  and when nothing can be confirmed the note carries the path in a read-only field
  with a Copy button, so the operator is one paste away from the folder.

``opener`` is injectable (``path -> OpenResult``) so a test can click every button
and assert exactly which folder was handed over, with no subprocess and no desktop.
Without one, the real openers run and ``host`` (a :class:`core.open_path.Host`)
stands in for the machine; "Open all" then goes through ``open_folders``, which
spends ONE waiting budget on all the folders of a domain — the click runs on the
window's own thread, and an opener that is the file manager never exits.
"""
from __future__ import annotations

from typing import Callable

from ..qt import Qt, QtCore, QtGui, QtWidgets
from ...core import code_folders
from ...core.open_path import OpenResult, open_folder, open_folders

__all__ = ["CodeFoldersWidget", "ElidedLabel", "default_opener"]


def _qt_last_resort(path: str) -> bool:
    """The desktop-portal fallback — reported as UNVERIFIED by open_folder, because
    Qt's True means "dispatched", not "a file manager appeared"."""
    return bool(QtGui.QDesktopServices.openUrl(QtCore.QUrl.fromLocalFile(path)))


def default_opener(path: str, host=None) -> OpenResult:
    return open_folder(path, last_resort=_qt_last_resort, host=host)


class ElidedLabel(QtWidgets.QLabel):
    """A one-line label that ELIDES (in the middle) instead of growing its row.

    A plain QLabel reports its full text width as its minimum, so one long path
    would widen the whole grid past the viewport and push the buttons off screen.
    This one's minimum is a few characters; the full text is its tooltip."""

    def __init__(self, text: str = "", parent=None):
        super().__init__(parent)
        self._full = ""
        self.setSizePolicy(QtWidgets.QSizePolicy.Policy.Expanding,
                           QtWidgets.QSizePolicy.Policy.Preferred)
        self.setText(text)

    def setText(self, text: str) -> None:      # noqa: N802 — Qt's name
        self._full = text or ""
        super().setText(self._full)
        self.setToolTip(self._full)

    def full_text(self) -> str:
        return self._full

    def minimumSizeHint(self) -> QtCore.QSize:  # noqa: N802 — Qt's name
        base = super().minimumSizeHint()
        return QtCore.QSize(self.fontMetrics().horizontalAdvance("MMMM…"), base.height())

    def elided_text(self) -> str:
        """What is drawn right now, at the current width."""
        return self.fontMetrics().elidedText(
            self._full, Qt.TextElideMode.ElideMiddle, self.contentsRect().width())

    def paintEvent(self, _ev) -> None:          # noqa: N802 — Qt's name
        painter = QtGui.QPainter(self)
        group = (QtGui.QPalette.ColorGroup.Normal if self.isEnabled()
                 else QtGui.QPalette.ColorGroup.Disabled)
        painter.setPen(self.palette().color(group, QtGui.QPalette.ColorRole.WindowText))
        flags = (int(Qt.AlignmentFlag.AlignLeft.value)
                 | int(Qt.AlignmentFlag.AlignVCenter.value)
                 | int(Qt.TextFlag.TextSingleLine.value))
        painter.drawText(self.contentsRect(), flags, self.elided_text())


def _grey(label: QtWidgets.QLabel) -> QtWidgets.QLabel:
    pal = label.palette()
    pal.setColor(QtGui.QPalette.ColorGroup.Normal, QtGui.QPalette.ColorRole.WindowText,
                 QtGui.QColor("gray"))
    label.setPalette(pal)
    return label


class CodeFoldersWidget(QtWidgets.QGroupBox):
    """See the module docstring. ``refresh()`` is cheap to call often: it rebuilds
    the rows only when the map actually changed."""

    #: How a result note is coloured: verified green, dispatched-unconfirmed amber,
    #: failed red — the same three the login preview uses.
    _COLOUR = {"verified": "#2e7d32", "unverified": "#a65d00", "failed": "#b00020"}
    #: The name column's minimum never exceeds this (see _domain_frame).
    _NAME_COLUMN_CAP = 230

    @staticmethod
    def _row_title(app: "code_folders.AppFolder") -> str:
        """The name, plus the per-domain selection(s) that put it here — so a row a
        domain CHOSE reads differently from one every domain runs."""
        slugs = [r[len("selected: "):] for r in app.reasons if r.startswith("selected: ")]
        return f"{app.name}  [{', '.join(slugs)}]" if slugs else app.name

    def __init__(self, generator_dir: str,
                 opener: "Callable[[str], OpenResult] | None" = None, parent=None,
                 host=None):
        super().__init__("Code folders — the git checkout behind each app", parent)
        self.generator_dir = generator_dir
        self._opener = opener
        self._host = host
        self.map: "code_folders.CodeFolderMap | None" = None
        self.open_buttons: dict[tuple[str, str], QtWidgets.QPushButton] = {}
        self.open_all_buttons: dict[str, QtWidgets.QPushButton] = {}
        self.rows: dict[tuple[str, str], code_folders.AppFolder] = {}
        self.last_results: list[OpenResult] = []

        lay = QtWidgets.QVBoxLayout(self)
        intro = QtWidgets.QLabel(
            "Every domain below runs the platform apps (one set of images serves all "
            "domains) plus the optional services chosen for it on the ‘Domain "
            "services’ step. Each row is the folder compose builds that app from.")
        intro.setWordWrap(True)
        lay.addWidget(_grey(intro))

        root_row = QtWidgets.QHBoxLayout()
        root_row.addWidget(QtWidgets.QLabel("Source root:"))
        self.root_path = ElidedLabel("")
        root_row.addWidget(self.root_path, 1)
        self.open_root_btn = QtWidgets.QPushButton("Open source root")
        self.open_root_btn.clicked.connect(self._open_root)
        root_row.addWidget(self.open_root_btn)
        lay.addLayout(root_row)
        # WHY the root is missing, wrapped: in the one-line path above the sentence
        # would be elided in the middle at the smallest window ("the build does not
        # expand ‘~’" is the part the operator needs).
        self.root_note = QtWidgets.QLabel("")
        self.root_note.setWordWrap(True)
        self.root_note.setVisible(False)
        lay.addWidget(_grey(self.root_note))

        self.notice = QtWidgets.QLabel("")
        self.notice.setWordWrap(True)
        lay.addWidget(_grey(self.notice))

        self._domains_box = QtWidgets.QWidget()
        self._domains_lay = QtWidgets.QVBoxLayout(self._domains_box)
        self._domains_lay.setContentsMargins(0, 0, 0, 0)
        lay.addWidget(self._domains_box)

        # The outcome of the last open: inline, never a dialog.
        self.result_note = QtWidgets.QLabel("")
        self.result_note.setWordWrap(True)
        self.result_note.setVisible(False)
        lay.addWidget(self.result_note)
        copy_row = QtWidgets.QHBoxLayout()
        self.result_path = QtWidgets.QLineEdit()
        self.result_path.setReadOnly(True)
        self.result_path.setVisible(False)
        self.copy_btn = QtWidgets.QPushButton("Copy path")
        self.copy_btn.setVisible(False)
        self.copy_btn.clicked.connect(self._copy_path)
        copy_row.addWidget(self.result_path, 1)
        copy_row.addWidget(self.copy_btn)
        lay.addLayout(copy_row)

    # ── wiring ──────────────────────────────────────────────────────────────────
    def set_opener(self, opener: "Callable[[str], OpenResult] | None") -> None:
        """Hand every open to ``opener`` (one call per folder, Open all included);
        None goes back to the real openers."""
        self._opener = opener

    def set_host(self, host) -> None:
        """Run the REAL openers against ``host`` (a test's stand-in machine)."""
        self._opener = None
        self._host = host

    def _open_paths(self, paths: "list[str]") -> "list[OpenResult]":
        if self._opener is not None:
            return [self._opener(p) for p in paths]
        if len(paths) == 1:
            return [default_opener(paths[0], self._host)]
        return open_folders(paths, last_resort=_qt_last_resort, host=self._host)

    def _show_working(self, count: int) -> None:
        """An opener can take a few seconds, and this runs on the window's thread:
        say so first, with a synchronous repaint (no event loop re-entry, so a second
        click cannot sneak in)."""
        self.result_note.setStyleSheet("")
        self.result_note.setText("Opening…" if count == 1 else f"Opening {count} folders…")
        self.result_note.setVisible(True)
        self.result_note.repaint()

    def refresh(self, source_mode: str, source_dir: str, domains,
                own_name: str = "") -> "code_folders.CodeFolderMap":
        """Re-read the map for the current source choice and domain rows. With no
        domain rows yet (the single-page frame never seeds the Domains table) the
        mesh's own domain stands in, so the block is never empty."""
        rows = list(domains or ())
        if not rows and own_name:
            rows = [{"name": own_name, "optional_services": [], "idp": ""}]
        new = code_folders.code_folder_map(self.generator_dir, source_mode,
                                          source_dir, rows)
        if new == self.map:
            return new
        self.map = new
        self._rebuild()
        return new

    # ── rendering ───────────────────────────────────────────────────────────────
    def _rebuild(self) -> None:
        m = self.map
        assert m is not None
        while self._domains_lay.count():
            item = self._domains_lay.takeAt(0)
            w = item.widget()
            if w is not None:
                w.setParent(None)
                w.deleteLater()
        self.open_buttons.clear()
        self.open_all_buttons.clear()
        self.rows.clear()

        self.root_path.setText(m.root or m.root_reason)
        missing_root = bool(m.root) and not m.root_exists
        self.root_note.setText(m.root_reason if missing_root else "")
        self.root_note.setVisible(missing_root)
        self.open_root_btn.setEnabled(m.root_exists)
        self.open_root_btn.setToolTip(m.root if m.root_exists else m.root_reason)
        self.notice.setText(m.notice)

        for dom in m.domains:
            self._domains_lay.addWidget(self._domain_frame(dom))

    def _domain_frame(self, dom: "code_folders.DomainFolders") -> QtWidgets.QFrame:
        frame = QtWidgets.QFrame()
        frame.setFrameShape(QtWidgets.QFrame.Shape.StyledPanel)
        frame.setObjectName("code_folders_domain")
        v = QtWidgets.QVBoxLayout(frame)
        head = QtWidgets.QHBoxLayout()
        title = ElidedLabel(f"Domain: {dom.name}")
        font = title.font()
        font.setBold(True)
        title.setFont(font)
        head.addWidget(title, 1)
        open_all = QtWidgets.QPushButton("Open all")
        paths = dom.openable_paths()
        open_all.setEnabled(bool(paths))
        open_all.setToolTip(f"Open the {len(paths)} existing folder(s) of {dom.name}"
                            if paths else f"No folder of {dom.name} exists yet")
        open_all.clicked.connect(lambda _=False, d=dom.name: self._open_all(d))
        head.addWidget(open_all)
        v.addLayout(head)
        self.open_all_buttons[dom.name] = open_all

        grid = QtWidgets.QGridLayout()
        grid.setHorizontalSpacing(8)
        grid.setVerticalSpacing(2)
        grid.setColumnStretch(0, 3)
        grid.setColumnStretch(1, 5)
        # The name column gets the widest name as its minimum, CAPPED: a name that
        # fits reads whole, and the cap keeps the row narrower than the smallest
        # window (736 px) even with the button beside it, so nothing is pushed out.
        fm = self.fontMetrics()
        widest = max([fm.horizontalAdvance(self._row_title(a)) for a in dom.apps] or [0])
        grid.setColumnMinimumWidth(0, min(widest + 4, self._NAME_COLUMN_CAP))
        for r, app in enumerate(dom.apps):
            name = ElidedLabel(self._row_title(app))
            name.setToolTip(app.why())
            where = ElidedLabel(app.path if app.exists else app.missing_reason)
            _grey(where)
            btn = QtWidgets.QPushButton("Open folder")
            btn.setEnabled(app.openable)
            btn.setToolTip(app.path if app.openable else app.missing_reason)
            btn.clicked.connect(lambda _=False, d=dom.name, n=app.name, p=app.path:
                                self._open_one(d, n, p))
            grid.addWidget(name, r, 0)
            grid.addWidget(where, r, 1)
            grid.addWidget(btn, r, 2)
            self.open_buttons[(dom.name, app.name)] = btn
            self.rows[(dom.name, app.name)] = app
        v.addLayout(grid)
        for note in dom.notes:
            lab = QtWidgets.QLabel(note)
            lab.setWordWrap(True)
            v.addWidget(_grey(lab))
        return frame

    # ── opening ─────────────────────────────────────────────────────────────────
    def _open_root(self) -> None:
        if self.map is None or not self.map.root_exists:
            return
        self._show_working(1)
        self._report(self._open_paths([self.map.root]))

    def _open_one(self, domain: str, name: str, path: str) -> None:
        app = self.rows.get((domain, name))
        if app is None or not app.openable:
            return
        self._show_working(1)
        self._report(self._open_paths([path]))

    def _open_all(self, domain: str) -> None:
        if self.map is None:
            return
        for dom in self.map.domains:
            if dom.name == domain:
                paths = dom.openable_paths()
                self._show_working(len(paths))
                self._report(self._open_paths(paths))
                return

    def _report(self, results: list[OpenResult]) -> None:
        """Say what happened, inline. Several results (Open all) are summarised; any
        result that is not a verified success gets its path offered for copying."""
        self.last_results = list(results)
        if not results:
            return
        unverified = [r for r in results if r.opened and not r.verified]
        failed = [r for r in results if not r.opened]
        if not unverified and not failed:
            state = "verified"
            text = (f"Opened {results[0].path} ({results[0].how})." if len(results) == 1
                    else f"Opened {len(results)} folders ({results[0].how}).")
            path = ""
        elif failed:
            state = "failed"
            first = failed[0]
            text = (f"Could not open {first.path}: {first.reason}. Copy the path "
                    "below and open it yourself.")
            if len(results) > 1:
                text = (f"{len(results) - len(failed)} of {len(results)} folders opened; "
                        + text)
            path = first.path
        else:
            state = "unverified"
            first = unverified[0]
            text = (f"Asked the desktop to open {first.path} ({first.how}) — "
                    f"{first.reason}")
            if len(results) > 1:
                text = (f"Asked for {len(results)} folders; {len(unverified)} not "
                        f"confirmed. First: {first.path} ({first.how}) — {first.reason}")
            path = first.path
        self.result_note.setStyleSheet(f"color: {self._COLOUR[state]};")
        self.result_note.setText(text)
        self.result_note.setVisible(True)
        self.result_path.setText(path)
        self.result_path.setVisible(bool(path))
        self.copy_btn.setText("Copy path")      # a new outcome: forget "Copied"
        self.copy_btn.setVisible(bool(path))

    def _copy_path(self) -> None:
        path = self.result_path.text()
        if not path:
            return
        try:
            QtWidgets.QApplication.clipboard().setText(path)
            self.copy_btn.setText("Copied")
        except Exception:                      # noqa: BLE001 — no clipboard (headless)
            self.copy_btn.setText("Select and copy the path")

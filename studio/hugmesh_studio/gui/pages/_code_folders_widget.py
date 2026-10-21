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

COPIES FOR EACH DOMAIN (operator ask 2026-10-21). Under each domain's rows sits the
domain's own folder of copies (:mod:`core.domain_workspaces`): one ``git clone`` per app
that domain has, each named ``<app>.<domain>``, made on a worker thread by *Make N
copies*. A row whose copy exists shows and opens the COPY. An app the domain no longer
has (a service was un-ticked), and the folder of a domain that left the mesh, are
listed as EXTRA; *Remove N extra folders* arms on the first click, showing per folder
whether it holds edits, and acts on the second click only, after re-reading the disk.
A copy that holds edits or commits found nowhere else is always kept.

``opener`` is injectable (``path -> OpenResult``) so a test can click every button
and assert exactly which folder was handed over, with no subprocess and no desktop.
Without one, the real openers run and ``host`` (a :class:`core.open_path.Host`)
stands in for the machine; "Open all" then goes through ``open_folders``, which
spends ONE waiting budget on all the folders of a domain — the click runs on the
window's own thread, and an opener that is the file manager never exits.
"""
from __future__ import annotations

import os
import time
from typing import Callable

from ..qt import Qt, QtCore, QtGui, QtWidgets, Signal
from ...core import code_folders
from ...core import domain_workspaces as dw
from ...core.open_path import OpenResult, open_folder, open_folders
from ._widgets import own_probe, probe_running

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


class _CopyJob(QtCore.QThread):
    """Run one callable off the window's thread; ``progress`` carries a line while it
    runs and ``result`` the value (or the exception) at the end. Never raises into Qt."""
    progress = Signal(object)
    result = Signal(object)

    def __init__(self, fn: "Callable[[Callable[[str], None]], object]"):
        super().__init__(None)
        self._fn = fn

    def run(self) -> None:                         # noqa: D401 — Qt's name
        try:
            value = self._fn(self.progress.emit)
        except BaseException as exc:               # noqa: BLE001 — carried to the slot
            value = exc
        self.result.emit(value)


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
                 host=None, git_runner=None, state_root: "str | None" = None):
        super().__init__("Code folders — the git checkout behind each app", parent)
        self.generator_dir = generator_dir
        self._opener = opener
        self._host = host
        #: ``(argv, cwd) -> (code, output)``; None = the real git (core.local_agent)
        self.git_runner = git_runner
        self.state_root = state_root
        self.map: "code_folders.CodeFolderMap | None" = None
        self.plan: "dw.WorkspacePlan | None" = None
        self._inputs: tuple = ("clone", "", (), "")
        self.open_buttons: dict[tuple[str, str], QtWidgets.QPushButton] = {}
        self.open_all_buttons: dict[str, QtWidgets.QPushButton] = {}
        self.rows: dict[tuple[str, str], code_folders.AppFolder] = {}
        #: the folder each row's Open button opens (the copy once there is one)
        self.row_paths: dict[tuple[str, str], str] = {}
        self.copy_labels: dict[str, QtWidgets.QLabel] = {}
        self.clone_buttons: dict[str, QtWidgets.QPushButton] = {}
        self.open_copies_buttons: dict[str, QtWidgets.QPushButton] = {}
        self.extra_labels: dict[str, QtWidgets.QLabel] = {}
        self.remove_buttons: dict[str, QtWidgets.QPushButton] = {}
        self.cancel_buttons: dict[str, QtWidgets.QPushButton] = {}
        #: domain -> the extra paths the FIRST click armed (the second acts on these)
        self.armed: dict[str, tuple[str, ...]] = {}
        self._armed_words: dict[str, str] = {}
        self._job = None
        self.last_results: list[OpenResult] = []
        self.last_copy_results: list = []

        lay = QtWidgets.QVBoxLayout(self)
        intro = QtWidgets.QLabel(
            "Every domain below runs the platform apps (one set of images serves all "
            "domains) plus the services chosen for it on the ‘Domain services’ step; "
            "the apps of a service a domain did not choose are not listed under it. "
            "Each row is the folder compose builds that app from, or this domain's "
            "own copy once one is made.")
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

        # Where the per-domain copies live, and the one sentence about what they are.
        copies_row = QtWidgets.QHBoxLayout()
        copies_row.addWidget(QtWidgets.QLabel("Domain copies:"))
        self.copies_root = ElidedLabel("")
        copies_row.addWidget(self.copies_root, 1)
        lay.addLayout(copies_row)
        self.copies_note = QtWidgets.QLabel(dw.EDITS_NOTE)
        self.copies_note.setWordWrap(True)
        lay.addWidget(_grey(self.copies_note))

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
        self._inputs = (source_mode, source_dir, tuple(rows), own_name)
        new = code_folders.code_folder_map(self.generator_dir, source_mode,
                                          source_dir, rows)
        plan = self._plan(new)
        if new == self.map and plan == self.plan:
            return new
        self.map = new
        self.plan = plan
        self._rebuild()
        return new

    def _mesh_name(self) -> str:
        return (self._inputs[3] or "").strip() or "mesh"

    def _plan(self, folder_map=None) -> "dw.WorkspacePlan | None":
        """The copies plan for the last inputs. Never raises: a plan that cannot be
        read hides the copies part and says why, instead of breaking the step."""
        mode, sdir, rows, _own = self._inputs
        try:
            return dw.plan_workspaces(self.generator_dir, mode, sdir, list(rows),
                                      self._mesh_name(), state_root=self.state_root,
                                      folder_map=folder_map)
        except Exception as exc:                  # noqa: BLE001 — a block must not break the page
            self._plan_error = f"{type(exc).__name__}: {exc}"
            return None

    def reread(self) -> None:
        """Re-read the disk with the last inputs (after a copy or a removal)."""
        self.map = None
        mode, sdir, rows, own = self._inputs
        self.refresh(mode, sdir, list(rows), own_name=own)

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
        for d in (self.open_buttons, self.open_all_buttons, self.rows, self.row_paths,
                  self.copy_labels, self.clone_buttons, self.open_copies_buttons,
                  self.extra_labels, self.remove_buttons, self.cancel_buttons):
            d.clear()

        self.root_path.setText(m.root or m.root_reason)
        missing_root = bool(m.root) and not m.root_exists
        self.root_note.setText(m.root_reason if missing_root else "")
        self.root_note.setVisible(missing_root)
        self.open_root_btn.setEnabled(m.root_exists)
        self.open_root_btn.setToolTip(m.root if m.root_exists else m.root_reason)
        self.notice.setText(m.notice)

        plan = self.plan
        self.copies_root.setText(plan.root if plan else
                                 "cannot be worked out: " + getattr(self, "_plan_error", ""))
        spaces = {d.name: d for d in (plan.domains if plan else ()) if d.in_mesh}
        # an arm survives a re-read only while every armed folder is still extra
        extras_now = {x.path for x in (plan.extras() if plan else ())}
        for name in list(self.armed):
            if not set(self.armed[name]) <= extras_now:
                self.armed.pop(name, None)
                self._armed_words.pop(name, None)
        for dom in m.domains:
            self._domains_lay.addWidget(self._domain_frame(dom, spaces.get(dom.name)))
        for ws in (plan.domains if plan else ()):
            if not ws.in_mesh:
                self._domains_lay.addWidget(self._gone_frame(ws))
        self._sync_busy()

    def _domain_frame(self, dom: "code_folders.DomainFolders",
                      ws: "dw.DomainWorkspace | None" = None) -> QtWidgets.QFrame:
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
        copies = {r.app: r for r in (ws.repos if ws else ())}
        for r, app in enumerate(dom.apps):
            copy = copies.get(app.name)
            name = ElidedLabel(self._row_title(app))
            if copy is not None and copy.cloned:
                # The row now stands for this domain's COPY: that is the folder to
                # work in. Where the build reads stays in the tooltip.
                path, openable = copy.dest, os.path.isdir(copy.dest)
                where = ElidedLabel(copy.dest)
                name.setToolTip(app.why() + f" — this domain's copy; the mesh build "
                                f"reads {app.path or app.missing_reason}")
            else:
                path, openable = app.path, app.openable
                where = ElidedLabel(app.path if app.exists else app.missing_reason)
                name.setToolTip(app.why())
            _grey(where)
            btn = QtWidgets.QPushButton("Open folder")
            btn.setEnabled(openable)
            btn.setToolTip(path if openable else app.missing_reason)
            btn.clicked.connect(lambda _=False, d=dom.name, n=app.name, p=path:
                                self._open_one(d, n, p))
            grid.addWidget(name, r, 0)
            grid.addWidget(where, r, 1)
            grid.addWidget(btn, r, 2)
            self.open_buttons[(dom.name, app.name)] = btn
            self.rows[(dom.name, app.name)] = app
            self.row_paths[(dom.name, app.name)] = path
        v.addLayout(grid)
        paths = self._domain_paths(dom.name)
        open_all.setEnabled(bool(paths))
        open_all.setToolTip(f"Open the {len(paths)} existing folder(s) of {dom.name}"
                            if paths else f"No folder of {dom.name} exists yet")
        for note in dom.notes:
            lab = QtWidgets.QLabel(note)
            lab.setWordWrap(True)
            v.addWidget(_grey(lab))
        if ws is not None:
            self._copies_part(v, ws)
        return frame

    # ── the per-domain copies ───────────────────────────────────────────────────
    def _copies_part(self, v: QtWidgets.QVBoxLayout, ws: "dw.DomainWorkspace") -> None:
        """The copies line, *Make N copies*, *Open copies folder*, and the extras."""
        made, missing = len(ws.cloned()), len(ws.missing())
        total = len(ws.repos)
        if ws.problem:
            text = f"Copies for this domain: none can be made — {ws.problem}"
        elif not ws.in_mesh:
            text = f"Copies folder: {ws.folder}"
        else:
            blocked = total - made - missing
            text = (f"Copies for this domain: {made} of {total} made, in "
                    f"{os.path.basename(ws.folder)}/ (each named "
                    f"<app>.{ws.slug})")
            if blocked:
                first = next(r for r in ws.repos if not r.cloned and r.reason)
                text += (f". {blocked} cannot be made yet: {first.reason}")
        lab = QtWidgets.QLabel(text)
        lab.setWordWrap(True)
        v.addWidget(lab)
        self.copy_labels[ws.name] = lab

        row = QtWidgets.QHBoxLayout()
        if ws.in_mesh:
            make = QtWidgets.QPushButton(f"Make {missing} cop{'y' if missing == 1 else 'ies'}"
                                         if missing else "All copies made")
            make.setEnabled(bool(missing))
            make.setToolTip(f"git clone each missing app into {ws.folder}" if missing else
                            (ws.problem or "Every app of this domain has its copy."))
            make.clicked.connect(lambda _=False, d=ws.name: self._make_copies(d))
            row.addWidget(make)
            self.clone_buttons[ws.name] = make
        openf = QtWidgets.QPushButton("Open copies folder")
        exists = bool(ws.folder) and os.path.isdir(ws.folder) and not ws.problem
        openf.setEnabled(exists)
        openf.setToolTip(ws.folder if exists else "No copy has been made yet.")
        openf.clicked.connect(lambda _=False, p=ws.folder: self._open_copies(p))
        row.addWidget(openf)
        self.open_copies_buttons[ws.name] = openf
        row.addStretch(1)
        v.addLayout(row)

        if ws.foreign:
            names = ", ".join(os.path.basename(p) for p in ws.foreign[:4])
            more = len(ws.foreign) - min(4, len(ws.foreign))
            note = QtWidgets.QLabel(
                f"Not made by the Studio, left alone: {names}"
                + (f", +{more} more" if more else ""))
            note.setWordWrap(True)
            v.addWidget(_grey(note))
        if ws.extras:
            self._extras_part(v, ws)

    def _extras_part(self, v: QtWidgets.QVBoxLayout, ws: "dw.DomainWorkspace") -> None:
        n = len(ws.extras)
        armed = ws.name in self.armed
        if armed:
            text = self._armed_words.get(ws.name, "")
        else:
            whys = sorted({x.why for x in ws.extras})
            text = (f"{n} extra folder{'s' if n != 1 else ''}: " + "; ".join(whys)
                    + ". Nothing is removed until you click Remove twice.")
        lab = QtWidgets.QLabel(text)
        lab.setWordWrap(True)
        lab.setStyleSheet(f"color: {self._COLOUR['unverified']};")
        v.addWidget(lab)
        self.extra_labels[ws.name] = lab
        row = QtWidgets.QHBoxLayout()
        count = len(self.armed.get(ws.name, ())) if armed else n
        btn = QtWidgets.QPushButton(
            f"Click again to remove {count} folder{'s' if count != 1 else ''}" if armed
            else f"Remove {n} extra folder{'s' if n != 1 else ''}…")
        btn.setEnabled(not armed or bool(count))
        btn.clicked.connect(lambda _=False, d=ws.name: self._remove_clicked(d))
        row.addWidget(btn)
        self.remove_buttons[ws.name] = btn
        cancel = QtWidgets.QPushButton("Keep them")
        cancel.setVisible(armed)
        cancel.clicked.connect(lambda _=False, d=ws.name: self._disarm(d))
        row.addWidget(cancel)
        self.cancel_buttons[ws.name] = cancel
        row.addStretch(1)
        v.addLayout(row)

    def _gone_frame(self, ws: "dw.DomainWorkspace") -> QtWidgets.QFrame:
        """The folder of a domain that is no longer in this mesh."""
        frame = QtWidgets.QFrame()
        frame.setFrameShape(QtWidgets.QFrame.Shape.StyledPanel)
        frame.setObjectName("code_folders_gone_domain")
        v = QtWidgets.QVBoxLayout(frame)
        title = ElidedLabel(f"No longer a domain of this mesh: {ws.name}")
        font = title.font()
        font.setBold(True)
        title.setFont(font)
        v.addWidget(title)
        self._copies_part(v, ws)
        return frame

    def _workspace(self, name: str) -> "dw.DomainWorkspace | None":
        for ws in (self.plan.domains if self.plan else ()):
            if ws.name == name:
                return ws
        return None

    def busy(self) -> bool:
        return probe_running(self, "_job")

    def _sync_busy(self) -> None:
        busy = self.busy()
        for name, btn in self.clone_buttons.items():
            ws = self._workspace(name)
            btn.setEnabled(not busy and bool(ws and ws.missing()))
        for name, btn in self.remove_buttons.items():
            btn.setEnabled(not busy and (name not in self.armed or bool(self.armed[name])))

    def _start(self, fn, working: str, done) -> bool:
        if self.busy():
            return False
        job = own_probe(self, "_job", _CopyJob(fn))
        # BOUND METHODS, not lambdas: a bound method of this widget carries the
        # widget's thread, so both signals are queued onto the window's thread and
        # no label is ever touched from the worker.
        self._job_done = done
        job.progress.connect(self._on_job_progress)
        job.result.connect(self._on_job_result)
        self._say(working, "unverified")
        job.start()
        self._sync_busy()
        return True

    def _on_job_progress(self, line) -> None:
        self._say(str(line), "unverified")

    def _on_job_result(self, value) -> None:
        done, self._job_done = getattr(self, "_job_done", None), None
        if done is not None:
            done(value)

    def _say(self, text: str, state: str) -> None:
        self.result_note.setStyleSheet(f"color: {self._COLOUR[state]};")
        self.result_note.setText(text)
        self.result_note.setVisible(True)
        self.result_path.setVisible(False)
        self.copy_btn.setVisible(False)

    def _make_copies(self, domain: str) -> None:
        ws = self._workspace(domain)
        if self.plan is None or ws is None or not ws.missing():
            return
        plan, runner, todo = self.plan, self.git_runner, len(ws.missing())

        def work(emit):
            return dw.clone_missing(
                plan, domain, runner,
                progress=lambda i, n, app: emit(f"Copying {i} of {n} for {domain}: {app}…"))

        self._start(work, f"Copying {todo} app{'s' if todo != 1 else ''} for {domain}…",
                    lambda value, d=domain: self._copies_done(d, value))

    def _copies_done(self, domain: str, value) -> None:
        if isinstance(value, BaseException):
            self.last_copy_results = []
            self._say(f"Copying for {domain} stopped: {type(value).__name__}: {value}",
                      "failed")
        else:
            self.last_copy_results = list(value)
            bad = [r for r in value if not r.ok]
            good = len(value) - len(bad)
            if bad:
                self._say(f"Made {good} of {len(value)} copies for {domain}. "
                          f"{bad[0].app}: {bad[0].message}", "failed")
            else:
                self._say(f"Made {good} cop{'y' if good == 1 else 'ies'} for {domain}.",
                          "verified")
        self.reread()
        self._sync_busy()

    def _open_copies(self, path: str) -> None:
        if not path or not os.path.isdir(path):
            return
        self._show_working(1)
        self._report(self._open_paths([path]))

    # ── removing extra copies: arm, then act ─────────────────────────────────────
    def _disarm(self, domain: str) -> None:
        self.armed.pop(domain, None)
        self._armed_words.pop(domain, None)
        self.reread_now()

    def reread_now(self) -> None:
        self.plan = None          # force the rebuild even when the disk did not change
        self.reread()

    def _remove_clicked(self, domain: str) -> None:
        if self.busy():
            return
        if domain not in self.armed:
            self._arm(domain)
            return
        self._remove_armed(domain)

    def _arm(self, domain: str) -> None:
        """FIRST click: list exactly what would go, and what will be kept and why.
        Nothing is removed here."""
        ws = self._workspace(domain)
        if ws is None or not ws.extras:
            return
        lines, ok = [], []
        for x in ws.extras:
            st = dw.extra_status(x.path, self.git_runner)
            lines.append(f"{os.path.basename(x.path)} ({x.why}): {st.words()}")
            if st.safe_to_remove:
                ok.append(x.path)
        head = (f"Click again to remove {len(ok)} folder{'s' if len(ok) != 1 else ''}; "
                "‘Keep them’ cancels." if ok else
                "Every extra folder holds work of its own, so none will be removed; "
                "remove them yourself if you mean it.")
        self.armed[domain] = tuple(ok)
        self._armed_words[domain] = head + "\n" + "\n".join(lines)
        self.result_note.setVisible(False)       # an older outcome is not this one
        self.reread_now()

    def _remove_armed(self, domain: str) -> None:
        """SECOND click: re-read the disk, then remove only folders that are STILL
        extra and were armed; each removal re-checks everything (core)."""
        armed = self.armed.pop(domain, ())
        self._armed_words.pop(domain, None)
        mode, sdir, rows, _own = self._inputs
        runner, root_state = self.git_runner, self.state_root
        gen, mesh = self.generator_dir, self._mesh_name()

        def work(emit):
            fresh = dw.plan_workspaces(gen, mode, sdir, list(rows), mesh,
                                       state_root=root_state)
            out = []
            for x in fresh.extras():
                if x.path in armed:
                    emit(f"Removing {os.path.basename(x.path)}…")
                    out.append(dw.remove_extra(x, fresh, runner))
            gone = set(armed) - {x.path for x in fresh.extras()}
            out.extend(dw.RemoveResult(p, False, "no longer an extra folder; kept")
                       for p in sorted(gone))
            return out

        self._start(work, f"Removing {len(armed)} folder(s) for {domain}…",
                    lambda value, d=domain: self._removed(d, value))

    def _removed(self, domain: str, value) -> None:
        if isinstance(value, BaseException):
            self.last_copy_results = []
            self._say(f"Removing for {domain} stopped: {type(value).__name__}: {value}",
                      "failed")
        else:
            self.last_copy_results = list(value)
            kept = [r for r in value if not r.removed]
            done = len(value) - len(kept)
            if kept:
                self._say(f"Removed {done} of {len(value)} folders for {domain}. Kept "
                          f"{os.path.basename(kept[0].path)}: {kept[0].message}", "failed")
            else:
                self._say(f"Removed {done} extra folder{'s' if done != 1 else ''} for "
                          f"{domain}.", "verified")
        self.reread_now()
        self._sync_busy()

    def wait_idle(self, timeout_s: float = 30.0) -> bool:
        """Process events until no copy or removal is running. True when idle."""
        end = time.monotonic() + timeout_s
        while self.busy() and time.monotonic() < end:
            QtWidgets.QApplication.processEvents()
            QtCore.QThread.msleep(5)
        QtWidgets.QApplication.processEvents()
        return not self.busy()

    # ── opening ─────────────────────────────────────────────────────────────────
    def _open_root(self) -> None:
        if self.map is None or not self.map.root_exists:
            return
        self._show_working(1)
        self._report(self._open_paths([self.map.root]))

    def _open_one(self, domain: str, name: str, path: str) -> None:
        app = self.rows.get((domain, name))
        if app is None or self.row_paths.get((domain, name)) != path \
                or not path or not os.path.isdir(path):
            return
        self._show_working(1)
        self._report(self._open_paths([path]))

    def _open_all(self, domain: str) -> None:
        if self.map is None:
            return
        paths = self._domain_paths(domain)
        if paths:
            self._show_working(len(paths))
            self._report(self._open_paths(paths))

    def _domain_paths(self, domain: str) -> "list[str]":
        """Every existing folder the rows of ``domain`` open, once each, in row order:
        the domain's copy where one is made, the build checkout otherwise."""
        out: list[str] = []
        for (d, _name), path in self.row_paths.items():
            if d == domain and path and path not in out and os.path.isdir(path):
                out.append(path)
        return out

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

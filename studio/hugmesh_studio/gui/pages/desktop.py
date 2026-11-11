"""DesktopPage — the per-build Desktop step (operator ask 2026-11-11).

"allow for a step to configure each desktop, login, window managers on board,
compositers, per build being made, users, roles, installed apps and if they're native
or flatpak, video drivers, and the ai assistant will help it run emerge pretend and
resolve any build flag or package useflag issues. It can also configure python."

One page, sections stacked in the page scroll (no dialogs; every problem is an inline
label): Environment, Login, Window managers & compositors, Video, Accounts, Apps,
Python, Portage & emerge --pretend. The data model, the rules and the emission are all
in ``core/desktop_spec.py`` (shared with the text UI and the CLI); the pretend run and
its parser in ``core/desktop_pretend.py``; the assistant's portage card in
``gui/_local_ai_dock.py`` (``_PortageCard``) calls :meth:`apply_portage_changes`.

WHO OWNS WHAT. This page is the ONE writer of the desktop environment (``cfg.desktop``
/ ``cfg.capable``) and of Steam delivery (``cfg.steam``) for a single desktop image —
those rows LEFT the Role step, so Back-then-Next can never let a stale combo there
overwrite a choice made here. The GPU driver preset stays on the Hardware step (it is
fed by the hardware scan and gates CUDA); this page shows it and owns the VIDEO_CARDS
override. The primary login account and its administrator tick stay on the Home step,
the SSO switch on the Network step: shown here, with a button that walks Back to them.

PER BUILD: a standalone or cloud flow edits its one image; a mesh flow picks a desktop
row of its worklist and edits that row's own spec (``WorklistEntry.desktop_spec``).
"""
from __future__ import annotations

import copy

from ..qt import QtCore, QtGui, QtWidgets, Signal
from ..styles import muted
from ...core import desktop_pretend as dp
from ...core import desktop_spec as ds
from ._scroll import scrollable
from ._widgets import _row

_ERR = "color: #b00020;"
_WARN = "color: #8a6d00;"


class _PretendWorker(QtCore.QThread):
    """Runs desktop_pretend.run() off the GUI thread."""
    line = Signal(str)
    done = Signal(object)

    def __init__(self, cfg, driver, out_dir):
        super().__init__()
        self._cfg, self._driver, self._out = cfg, driver, out_dir

    def run(self):
        try:
            res = dp.run(self._cfg, self._driver, out_dir=self._out,
                         on_line=lambda s: self.line.emit(s))
        except Exception as exc:                # noqa: BLE001 — reported, never raised
            res = dp.PretendResult(status="error", reason=f"{exc.__class__.__name__}: {exc}")
        self.done.emit(res)


def _section(title: str) -> tuple[QtWidgets.QGroupBox, QtWidgets.QVBoxLayout]:
    box = QtWidgets.QGroupBox(title)
    lay = QtWidgets.QVBoxLayout(box)
    lay.setSpacing(4)
    return box, lay


def _link(button: QtWidgets.QPushButton) -> QtWidgets.QWidget:
    """A button at its natural width on its own row (not stretched across the page)."""
    w = QtWidgets.QWidget()
    h = QtWidgets.QHBoxLayout(w)
    h.setContentsMargins(0, 0, 0, 0)
    h.addWidget(button)
    h.addStretch(1)
    return w


def _fit_table(table: QtWidgets.QTableWidget, min_rows: int = 2) -> None:
    """Size a table to show every row (no scroll area inside the page's own scroll)."""
    rows = max(min_rows, table.rowCount())
    row_h = table.verticalHeader().defaultSectionSize()
    h = table.horizontalHeader().height() + rows * row_h + 2 * table.frameWidth() + 2
    table.setFixedHeight(h)


def _note(text: str = "") -> QtWidgets.QLabel:
    lab = QtWidgets.QLabel(text)
    lab.setWordWrap(True)
    lab.setStyleSheet(muted())
    return lab


class DesktopPage(QtWidgets.QWizardPage):
    """The Desktop step. Skips itself when the build produces no desktop."""

    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Desktop")
        self.setSubTitle(
            "Environment, login, window managers, video drivers, extra accounts, apps "
            "(native or Flatpak) and Python for this build. Check with emerge --pretend "
            "asks Gentoo whether it all builds.")
        self.last_result: dp.PretendResult | None = None
        self._worker: _PretendWorker | None = None
        self._pending_offer: list[ds.OverlayChange] = []
        self._last_applied: list[ds.OverlayChange] = []
        self._entry = None                      # the mesh row being edited (None = the one image)
        self._loading = False
        lay = scrollable(self)

        # ── which build (mesh) ──
        self.target = QtWidgets.QComboBox()
        self.target_row = _row("Desktop build", self.target)
        self.target.currentIndexChanged.connect(self._target_changed)
        lay.addWidget(self.target_row)

        self.problems = QtWidgets.QLabel("")
        self.problems.setWordWrap(True)
        self.problems.setVisible(False)
        lay.addWidget(self.problems)

        # ── environment ──
        self.env_box, el = _section("Desktop environment")
        self.env = QtWidgets.QComboBox()
        el.addWidget(_row("Environment", self.env))
        self.env_note = _note()
        el.addWidget(self.env_note)
        self.steam = QtWidgets.QComboBox()
        self.steam.addItems(["(default)", "native", "flatpak", "none"])
        self.steam.setToolTip("Steam delivery (--steam): native from the steam-overlay, the "
                              "Flatpak, or none. (default) keeps the builder's choice.")
        self.steam_row = _row("Steam", self.steam)
        el.addWidget(self.steam_row)
        self.env.currentIndexChanged.connect(self._changed)
        self.steam.currentIndexChanged.connect(self._changed)
        lay.addWidget(self.env_box)

        # ── login ──
        self.login_box, ll = _section("Login screen")
        ll.addWidget(_note(ds.LOGIN_MANAGER_NOTE))
        self.sso_state = QtWidgets.QLabel("")
        self.sso_state.setWordWrap(True)
        self.sso_btn = QtWidgets.QPushButton("Change SSO on the Network step")
        self.sso_btn.clicked.connect(lambda: self._go_back_to("network", self.sso_state))
        ll.addWidget(self.sso_state)
        ll.addWidget(_link(self.sso_btn))
        lay.addWidget(self.login_box)

        # ── sessions ──
        self.sess_box, sl = _section("Window managers and compositors on board")
        self.sess_note = _note("Each one is installed next to the environment; the greeter "
                               "lists every session. picom is a compositor for an X11 window "
                               "manager; a Wayland compositor adds USE=wayland.")
        sl.addWidget(self.sess_note)
        self.session_checks: dict[str, QtWidgets.QCheckBox] = {}
        grid = QtWidgets.QGridLayout()
        for i, s in enumerate(ds.SESSION_CATALOG):
            cb = QtWidgets.QCheckBox(s.label)
            cb.setToolTip(f"{s.atom} ({s.kind})")
            cb.toggled.connect(self._changed)
            self.session_checks[s.name] = cb
            grid.addWidget(cb, i // 2, i % 2)
        sl.addLayout(grid)
        self.default_session = QtWidgets.QComboBox()
        self.default_session.currentIndexChanged.connect(self._changed)
        sl.addWidget(_row("Default session", self.default_session))
        lay.addWidget(self.sess_box)

        # ── video ──
        self.video_box, vl = _section("Video drivers")
        self.gpu_state = QtWidgets.QLabel("")
        self.gpu_state.setWordWrap(True)
        vl.addWidget(self.gpu_state)
        self.gpu_btn = QtWidgets.QPushButton("Change the GPU driver on the Hardware step")
        self.gpu_btn.clicked.connect(lambda: self._go_back_to("hardware", self.gpu_state))
        self.gpu_link = _link(self.gpu_btn)
        vl.addWidget(self.gpu_link)
        self.cards_override = QtWidgets.QCheckBox("Choose the VIDEO_CARDS list myself")
        self.cards_override.toggled.connect(self._changed)
        vl.addWidget(self.cards_override)
        self.card_checks: dict[str, QtWidgets.QCheckBox] = {}
        cgrid = QtWidgets.QGridLayout()
        for i, tok in enumerate(ds.VIDEO_CARD_TOKENS):
            cb = QtWidgets.QCheckBox(ds.VIDEO_CARD_LABELS.get(tok, tok))
            cb.setToolTip(f"VIDEO_CARDS token: {tok}")
            cb.toggled.connect(self._changed)
            self.card_checks[tok] = cb
            cgrid.addWidget(cb, i // 3, i % 3)
        self.cards_widget = QtWidgets.QWidget()
        self.cards_widget.setLayout(cgrid)
        vl.addWidget(self.cards_widget)
        self.cards_effective = _note()
        vl.addWidget(self.cards_effective)
        lay.addWidget(self.video_box)

        # ── accounts ──
        self.users_box, ul = _section("Accounts")
        self.primary_state = QtWidgets.QLabel("")
        self.primary_state.setWordWrap(True)
        ul.addWidget(self.primary_state)
        self.home_btn = QtWidgets.QPushButton("Change the login account on the Home step")
        self.home_btn.clicked.connect(lambda: self._go_back_to("home", self.primary_state))
        ul.addWidget(_link(self.home_btn))
        ul.addWidget(_note("Extra local accounts are created at first boot. None is an "
                           "administrator unless you tick it, and each must choose a new "
                           "password at first login. Passwords are typed here for this "
                           "build only and never saved."))
        self.users_table = QtWidgets.QTableWidget(0, 3)
        self.users_table.setHorizontalHeaderLabels(["Login name", "Administrator", "First-login password"])
        self.users_table.horizontalHeader().setStretchLastSection(True)
        self.users_table.verticalHeader().setVisible(False)
        self.users_table.setVerticalScrollBarPolicy(QtCore.Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        _fit_table(self.users_table)
        ul.addWidget(self.users_table)
        ub = QtWidgets.QHBoxLayout()
        self.add_user_btn = QtWidgets.QPushButton("Add account")
        self.del_user_btn = QtWidgets.QPushButton("Remove selected")
        self.add_user_btn.clicked.connect(lambda: self._add_user_row("", False, ""))
        self.del_user_btn.clicked.connect(self._remove_user_row)
        ub.addWidget(self.add_user_btn)
        ub.addWidget(self.del_user_btn)
        ub.addStretch(1)
        ul.addLayout(ub)
        lay.addWidget(self.users_box)

        # ── apps ──
        self.apps_box, al = _section("Apps")
        al.addWidget(_note("Native apps are built from source into the image (emerge); "
                           "Flatpak apps install from their remote once the machine is "
                           "online. A governed mesh desktop keeps only the hugmesh-discover "
                           "remote."))
        self.apps_table = QtWidgets.QTableWidget(0, 3)
        self.apps_table.setHorizontalHeaderLabels(["App", "Install", "Package / app id"])
        self.apps_table.horizontalHeader().setStretchLastSection(True)
        self.apps_table.verticalHeader().setVisible(False)
        self.apps_table.setVerticalScrollBarPolicy(QtCore.Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        al.addWidget(self.apps_table)
        free = QtWidgets.QHBoxLayout()
        self.free_app = QtWidgets.QLineEdit()
        self.free_app.setPlaceholderText("another app: category/name, or remote:app.id for a Flatpak")
        self.free_add = QtWidgets.QPushButton("Add")
        self.free_add.clicked.connect(self._add_free_app)
        free.addWidget(self.free_app, 1)
        free.addWidget(self.free_add)
        al.addLayout(free)
        self.free_note = _note()
        al.addWidget(self.free_note)
        self.remotes = QtWidgets.QLineEdit()
        self.remotes.setPlaceholderText("extra Flatpak remotes: name=https://…/x.flatpakrepo (space-separated)")
        self.remotes.textChanged.connect(self._changed)
        al.addWidget(_row("Flatpak remotes", self.remotes))
        lay.addWidget(self.apps_box)

        # ── python ──
        self.py_box, pl = _section("Python")
        pl.addWidget(_note("The image keeps every Python target its stage3 seed carries; "
                           "tick more to build them too. The seed's own set is reported by "
                           "the emerge --pretend check."))
        prow = QtWidgets.QHBoxLayout()
        self.py_checks: dict[str, QtWidgets.QCheckBox] = {}
        for t in ds.PYTHON_TARGET_CHOICES:
            cb = QtWidgets.QCheckBox(t.replace("python3_", "3."))
            cb.setToolTip(f"PYTHON_TARGETS += {t}")
            cb.toggled.connect(self._changed)
            self.py_checks[t] = cb
            prow.addWidget(cb)
        prow.addStretch(1)
        pl.addLayout(prow)
        self.py_single = QtWidgets.QComboBox()
        self.py_single.addItem("(the seed's newest)", "")
        for t in ds.PYTHON_TARGET_CHOICES:
            self.py_single.addItem(t.replace("python3_", "Python 3."), t)
        self.py_single.currentIndexChanged.connect(self._changed)
        pl.addWidget(_row("Single target", self.py_single))
        lay.addWidget(self.py_box)

        # ── portage + pretend ──
        self.portage_box, pol = _section("Portage and emerge --pretend")
        pol.addWidget(_note("USE and keyword lines added to this image's portage config "
                            "(package.use / package.accept_keywords zz-hugmesh-studio). "
                            "One per line."))
        self.use_lines = QtWidgets.QPlainTextEdit()
        self.use_lines.setPlaceholderText(">=media-video/ffmpeg-7.1.5 opus x264")
        self.use_lines.setFixedHeight(64)
        self.use_lines.textChanged.connect(self._changed)
        pol.addWidget(_row("package.use", self.use_lines))
        self.kw_lines = QtWidgets.QPlainTextEdit()
        self.kw_lines.setPlaceholderText("=media-video/obs-studio-32.2.2 ~amd64")
        self.kw_lines.setFixedHeight(48)
        self.kw_lines.textChanged.connect(self._changed)
        pol.addWidget(_row("accept_keywords", self.kw_lines))
        prb = QtWidgets.QHBoxLayout()
        self.pretend_btn = QtWidgets.QPushButton("Check with emerge --pretend")
        self.pretend_btn.clicked.connect(self.start_pretend)
        self.stop_btn = QtWidgets.QPushButton("Stop")
        self.stop_btn.setEnabled(False)
        self.stop_btn.clicked.connect(self._stop_pretend)
        prb.addWidget(self.pretend_btn)
        prb.addWidget(self.stop_btn)
        prb.addStretch(1)
        pol.addLayout(prb)
        self.pretend_status = QtWidgets.QLabel("Not checked yet.")
        self.pretend_status.setWordWrap(True)
        pol.addWidget(self.pretend_status)
        self.pretend_needs = QtWidgets.QLabel("")
        self.pretend_needs.setWordWrap(True)
        self.pretend_needs.setTextInteractionFlags(QtCore.Qt.TextInteractionFlag.TextSelectableByMouse)
        pol.addWidget(self.pretend_needs)
        # the deterministic fix card: portage's own suggestions, applied on a click
        self.offer_box = QtWidgets.QFrame()
        self.offer_box.setFrameShape(QtWidgets.QFrame.Shape.StyledPanel)
        ol = QtWidgets.QVBoxLayout(self.offer_box)
        self.offer_text = QtWidgets.QLabel("")
        self.offer_text.setWordWrap(True)
        self.offer_text.setFont(QtGui.QFontDatabase.systemFont(QtGui.QFontDatabase.SystemFont.FixedFont))
        self.offer_text.setTextInteractionFlags(QtCore.Qt.TextInteractionFlag.TextSelectableByMouse)
        ol.addWidget(self.offer_text)
        orow = QtWidgets.QHBoxLayout()
        self.offer_apply = QtWidgets.QPushButton("Apply portage's changes")
        self.offer_cancel = QtWidgets.QPushButton("Cancel")
        self.offer_undo = QtWidgets.QPushButton("Undo")
        self.offer_recheck = QtWidgets.QPushButton("Re-check")
        self.offer_apply.clicked.connect(self._offer_apply)
        self.offer_cancel.clicked.connect(lambda: self.offer_box.setVisible(False))
        self.offer_undo.clicked.connect(self._offer_undo)
        self.offer_recheck.clicked.connect(self.start_pretend)
        for b in (self.offer_apply, self.offer_cancel, self.offer_undo, self.offer_recheck):
            orow.addWidget(b)
        orow.addStretch(1)
        ol.addLayout(orow)
        self.offer_box.setVisible(False)
        pol.addWidget(self.offer_box)
        self.honesty = _note(dp.HONESTY_NOTE)
        pol.addWidget(self.honesty)
        self.pretend_log = QtWidgets.QPlainTextEdit()
        self.pretend_log.setReadOnly(True)
        self.pretend_log.setFont(QtGui.QFontDatabase.systemFont(QtGui.QFontDatabase.SystemFont.FixedFont))
        self.pretend_log.setPlaceholderText("The resolver's output appears here.")
        self.pretend_log.setMinimumHeight(120)
        self.pretend_log.setMaximumBlockCount(4000)
        pol.addWidget(self.pretend_log)
        lay.addWidget(self.portage_box)
        lay.addStretch(1)

    # ── which config this page edits ─────────────────────────────────────────────
    def _mesh(self) -> bool:
        return getattr(self.wiz.cfg, "mode", "") == "mesh"

    def _entries(self) -> list:
        return ds.desktop_entries(getattr(self.wiz, "worklist", None), "mesh") if self._mesh() else []

    def view(self):
        """The config standing for the image being edited (the wizard's own config, or
        a mesh row's view of it)."""
        if self._mesh() and self._entry is not None:
            return ds.entry_view(self.wiz.cfg, self._entry)
        return self.wiz.cfg

    def _store_spec(self, spec: ds.DesktopSpec) -> None:
        if self._mesh() and self._entry is not None:
            self._entry.desktop_spec = spec.to_dict()
        else:
            ds.store(self.wiz.cfg, spec)

    def applies_to(self, cfg) -> bool:
        return ds.step_applies(cfg, getattr(self.wiz, "worklist", None))

    # ── wizard contract ──────────────────────────────────────────────────────────
    def initializePage(self):
        self._loading = True
        try:
            entries = self._entries()
            self.target.blockSignals(True)
            self.target.clear()
            for e in entries:
                self.target.addItem(f"{e.role} on {e.platform} ({e.id})", e.id)
            self.target.blockSignals(False)
            self.target_row.setVisible(bool(entries))
            if entries:
                ids = [e.id for e in entries]
                keep = self._entry.id if self._entry is not None and self._entry.id in ids else ids[0]
                self.target.setCurrentIndex(ids.index(keep))
                self._entry = entries[ids.index(keep)]
            else:
                self._entry = None
            self._load()
        finally:
            self._loading = False
        self._refresh()

    def _target_changed(self, idx: int) -> None:
        if self._loading or idx < 0:
            return
        self._collect()                         # keep the row we leave
        entries = self._entries()
        if idx < len(entries):
            self._entry = entries[idx]
        self._loading = True
        try:
            self._load()
        finally:
            self._loading = False
        self._refresh()

    def _load(self) -> None:
        c = self.view()
        spec = ds.spec_of(c)
        # environment
        self.env.clear()
        for env in ds.environment_choices(c):
            self.env.addItem(ds.ENVIRONMENTS[env][0], env)
        self.env.setCurrentIndex(max(0, self.env.findData(ds.environment(c))))
        mesh = self._mesh()
        lock = ds.environment_lock(c)
        if mesh and not lock:
            lock = ("In a mesh build each row's desktop weight is set on the Worklist step "
                    "(Plasma is not offered per row).")
        self.env.setEnabled(not lock and ds.is_x86(c))
        self.env_note.setText(lock)
        self.env_note.setVisible(bool(lock))
        self.steam_row.setVisible(ds.is_x86(c) and not mesh)
        self.steam.setCurrentText(c.steam or "(default)")
        # sessions
        for name, cb in self.session_checks.items():
            cb.setChecked(name in spec.sessions or name in ds.ALWAYS_ON_SESSIONS)
        # video
        self.cards_override.setChecked(bool(spec.video_cards))
        for tok, cb in self.card_checks.items():
            cb.setChecked(tok in spec.video_cards)
        # users
        self.users_table.setRowCount(0)
        _fit_table(self.users_table)
        typed = ds.parse_passwords(getattr(self.wiz.cfg, "extra_local_passes", "") or "")
        for u in spec.extra_users:
            self._add_user_row(u.name, u.admin, typed.get(u.name, ""))
        # apps
        self._fill_apps(spec)
        self.remotes.setText(" ".join(f"{k}={v}" for k, v in sorted(spec.flatpak_remotes.items())))
        # python
        for t, cb in self.py_checks.items():
            cb.setChecked(t in spec.python_extra_targets)
        self.py_single.setCurrentIndex(max(0, self.py_single.findData(spec.python_single_target)))
        # portage
        self.use_lines.setPlainText("\n".join(spec.use_lines))
        self.kw_lines.setPlainText("\n".join(spec.keyword_lines))
        self._fill_sessions_combo(spec)
        self.default_session.setCurrentIndex(max(0, self.default_session.findData(spec.default_session)))
        self.offer_box.setVisible(False)
        if spec.last_pretend and self.last_result is None:
            self.pretend_status.setText(
                f"Last check: {spec.last_pretend.get('status', '?')} ({spec.last_pretend.get('at', '')}).")

    def _fill_sessions_combo(self, spec: ds.DesktopSpec) -> None:
        keep = self.default_session.currentData() if self.default_session.count() else spec.default_session
        self.default_session.blockSignals(True)
        self.default_session.clear()
        self.default_session.addItem("(the environment's own)", "")
        for name in ds.installed_sessions(self.view(), spec):
            self.default_session.addItem(name, name)
        idx = self.default_session.findData(keep or "")
        self.default_session.setCurrentIndex(max(0, idx))
        self.default_session.blockSignals(False)

    def _fill_apps(self, spec: ds.DesktopSpec) -> None:
        chosen = {a.id: a for a in spec.apps}
        rows = [(a["id"], a["label"], a.get("atom", ""), a.get("flatpak", "")) for a in ds.app_catalog()]
        for a in spec.apps:
            if a.id not in {r[0] for r in rows}:
                rows.append((a.id, a.label, a.atom, a.flatpak))
        self.apps_table.setRowCount(0)
        for app_id, label, atom, flat in rows:
            r = self.apps_table.rowCount()
            self.apps_table.insertRow(r)
            item = QtWidgets.QTableWidgetItem(label)
            item.setData(QtCore.Qt.ItemDataRole.UserRole, (app_id, atom, flat))
            item.setFlags(item.flags() & ~QtCore.Qt.ItemFlag.ItemIsEditable)
            self.apps_table.setItem(r, 0, item)
            combo = QtWidgets.QComboBox()
            combo.addItem("Not installed", "")
            if atom:
                combo.addItem("Native (emerge)", "native")
            if flat:
                combo.addItem("Flatpak", "flatpak")
            cur = chosen.get(app_id)
            combo.setCurrentIndex(max(0, combo.findData(cur.delivery if cur else "")))
            combo.currentIndexChanged.connect(self._changed)
            self.apps_table.setCellWidget(r, 1, combo)
            src = QtWidgets.QTableWidgetItem("")
            src.setFlags(src.flags() & ~QtCore.Qt.ItemFlag.ItemIsEditable)
            self.apps_table.setItem(r, 2, src)
            if cur is not None and cur.delivery == "flatpak" and cur.remote != "flathub":
                src.setData(QtCore.Qt.ItemDataRole.UserRole, cur.remote)
        self.apps_table.resizeColumnToContents(0)
        self.apps_table.resizeColumnToContents(1)
        _fit_table(self.apps_table)
        self._apps_sources()

    def _apps_sources(self) -> None:
        for r in range(self.apps_table.rowCount()):
            app_id, atom, flat = self.apps_table.item(r, 0).data(QtCore.Qt.ItemDataRole.UserRole)
            delivery = self.apps_table.cellWidget(r, 1).currentData()
            remote = self.apps_table.item(r, 2).data(QtCore.Qt.ItemDataRole.UserRole) or "flathub"
            self.apps_table.item(r, 2).setText(
                atom if delivery == "native" else f"{remote}:{flat}" if delivery == "flatpak" else "")

    def _add_free_app(self) -> None:
        text = self.free_app.text().strip()
        if not text:
            return
        if ":" in text:
            remote, _, flat = text.partition(":")
            app = ds.DesktopApp(id=flat, label=flat, delivery="flatpak", flatpak=flat, remote=remote)
        else:
            app = ds.DesktopApp(id=text, label=text, delivery="native", atom=text)
        spec = self._collect_spec()
        probe = copy.deepcopy(spec)
        probe.apps.append(app)
        bad = ds.grammar_errors(self.view(), probe)
        if bad:
            self.free_note.setText(f"Not added: {bad[0]}")
            self.free_note.setStyleSheet(_ERR)
            return
        spec.apps.append(app)
        self._store_spec(spec)
        self._fill_apps(spec)
        self.free_app.clear()
        self.free_note.setText("")
        self._refresh()

    def _add_user_row(self, name: str, admin: bool, password: str) -> None:
        r = self.users_table.rowCount()
        self.users_table.insertRow(r)
        self.users_table.setItem(r, 0, QtWidgets.QTableWidgetItem(name))
        adm = QtWidgets.QCheckBox()
        adm.setChecked(admin)
        adm.toggled.connect(self._changed)
        self.users_table.setCellWidget(r, 1, adm)
        pw = QtWidgets.QLineEdit(password)
        pw.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        pw.textChanged.connect(self._changed)
        self.users_table.setCellWidget(r, 2, pw)
        _fit_table(self.users_table)
        if not self._loading:
            self._refresh()

    def _remove_user_row(self) -> None:
        rows = sorted({i.row() for i in self.users_table.selectedIndexes()}, reverse=True)
        if not rows and self.users_table.rowCount():
            rows = [self.users_table.rowCount() - 1]
        for r in rows:
            self.users_table.removeRow(r)
        _fit_table(self.users_table)
        self._refresh()

    # ── collecting ───────────────────────────────────────────────────────────────
    def _lines(self, edit: QtWidgets.QPlainTextEdit) -> list[str]:
        return [ds.normalise_line(x) for x in edit.toPlainText().splitlines() if x.strip()]

    def _passwords(self) -> dict[str, str]:
        out = {}
        for r in range(self.users_table.rowCount()):
            name = (self.users_table.item(r, 0).text() if self.users_table.item(r, 0) else "").strip()
            pw = self.users_table.cellWidget(r, 2)
            if name:
                out[name] = pw.text() if pw is not None else ""
        return out

    def _collect_spec(self) -> ds.DesktopSpec:
        old = ds.spec_of(self.view())
        spec = ds.DesktopSpec(history=list(old.history), last_pretend=dict(old.last_pretend))
        spec.sessions = [n for n, cb in self.session_checks.items()
                         if cb.isChecked() and n not in ds.ALWAYS_ON_SESSIONS]
        spec.default_session = self.default_session.currentData() or ""
        if self.cards_override.isChecked():
            spec.video_cards = [t for t, cb in self.card_checks.items() if cb.isChecked()]
        for r in range(self.users_table.rowCount()):
            item = self.users_table.item(r, 0)
            name = (item.text() if item else "").strip()
            if name:
                adm = self.users_table.cellWidget(r, 1)
                spec.extra_users.append(ds.ExtraUser(name, bool(adm and adm.isChecked())))
        for r in range(self.apps_table.rowCount()):
            app_id, atom, flat = self.apps_table.item(r, 0).data(QtCore.Qt.ItemDataRole.UserRole)
            delivery = self.apps_table.cellWidget(r, 1).currentData()
            if not delivery:
                continue
            label = self.apps_table.item(r, 0).text()
            remote = self.apps_table.item(r, 2).data(QtCore.Qt.ItemDataRole.UserRole) or "flathub"
            spec.apps.append(ds.DesktopApp(id=app_id, label=label, delivery=delivery,
                                           atom=atom if delivery == "native" else "",
                                           flatpak=flat if delivery == "flatpak" else "",
                                           remote=remote if delivery == "flatpak" else "flathub"))
        for tok in self.remotes.text().split():
            name, _, url = tok.partition("=")
            spec.flatpak_remotes[name] = url
        spec.python_extra_targets = [t for t, cb in self.py_checks.items() if cb.isChecked()]
        spec.python_single_target = self.py_single.currentData() or ""
        spec.use_lines = self._lines(self.use_lines)
        spec.keyword_lines = self._lines(self.kw_lines)
        # operator edits to the overlay go in the append-only history too
        for kind, before, after in (("package.use", old.use_lines, spec.use_lines),
                                    ("accept_keywords", old.keyword_lines, spec.keyword_lines)):
            for line in after:
                if line not in before:
                    spec.history.append({"op": "add", "kind": kind, "line": line,
                                         "source": "operator", "at": ds._now()})
            for line in before:
                if line not in after:
                    spec.history.append({"op": "remove", "kind": kind, "line": line,
                                         "source": "operator", "at": ds._now()})
        return spec

    def _collect(self) -> None:
        """Write the widgets back: the spec, the environment, Steam, the passwords."""
        c = self.view()
        spec = self._collect_spec()
        self._store_spec(spec)
        if not self._mesh():
            env = self.env.currentData()
            if env and self.env.isEnabled():
                try:
                    ds.set_environment(self.wiz.cfg, env)
                except ValueError:
                    pass
            if self.steam_row.isVisibleTo(self) and ds.is_x86(c):
                steam = self.steam.currentText()
                self.wiz.cfg.steam = "" if steam == "(default)" else steam
        # passwords: merged by name across rows (a mesh shares one secret file)
        typed = ds.parse_passwords(getattr(self.wiz.cfg, "extra_local_passes", "") or "")
        typed.update({k: v for k, v in self._passwords().items() if v})
        names = {u.name for u in spec.extra_users}
        for e in self._entries():
            names |= {u.get("name", "") for u in (e.desktop_spec or {}).get("extra_users", [])}
        keep = {k: v for k, v in typed.items() if k in names}
        try:
            self.wiz.cfg.extra_local_passes = ds.extra_pass_file_text(
                ds.DesktopSpec(extra_users=[ds.ExtraUser(n) for n in sorted(keep)]), keep)
        except ValueError:
            pass

    # ── refresh: everything derived ──────────────────────────────────────────────
    def _changed(self, *_):
        if self._loading:
            return
        self._refresh()

    def _refresh(self) -> None:
        try:
            self._refresh_unguarded()
        except Exception as exc:                # noqa: BLE001 — a slot must never raise
            self.problems.setText(f"Could not update the page: {exc}")
            self.problems.setStyleSheet(_ERR)
            self.problems.setVisible(True)

    def _refresh_unguarded(self) -> None:
        c = self.view()
        spec = self._collect_spec()
        x86 = ds.is_x86(c)
        probe = copy.copy(c)
        probe.desktop_spec = spec.to_dict()
        if not self._mesh() and self.env.isEnabled() and self.env.currentData():
            probe = copy.deepcopy(probe)
            try:
                ds.set_environment(probe, self.env.currentData())
            except ValueError:
                pass
        # sessions (x86 only), the default-session list follows them
        for name, cb in self.session_checks.items():
            cb.setEnabled(x86 and name not in ds.ALWAYS_ON_SESSIONS)
        self.sess_note.setText(
            "Each one is installed next to the environment; the greeter lists every session. "
            "picom is a compositor for an X11 window manager; a Wayland compositor adds USE=wayland."
            if x86 else "This board ships LXDE with openbox only; more sessions are x86-only for now.")
        keep = self.default_session.currentData()
        self.default_session.blockSignals(True)
        self.default_session.clear()
        self.default_session.addItem("(the environment's own)", "")
        for name in ds.installed_sessions(probe, spec):
            self.default_session.addItem(name, name)
        self.default_session.setCurrentIndex(max(0, self.default_session.findData(keep or "")))
        self.default_session.blockSignals(False)
        # login
        sso = ds._sso(c)
        self.sso_state.setText(
            "Sign-in on this image: a local account" + (" and SSO (device flow on the greeter)."
                                                          if sso else ". SSO sign-in is OFF for this image."))
        # video
        self.cards_override.setVisible(x86)
        self.cards_widget.setVisible(x86 and self.cards_override.isChecked())
        self.gpu_link.setVisible(x86 and not self._mesh())
        if x86:
            self.gpu_state.setText(f"GPU driver preset: {ds.gpu_driver_effective(c)} "
                                   f"(VIDEO_CARDS {ds.X86_GPU_VIDEO_CARDS.get(ds.gpu_driver_effective(c), '') or 'none'}).")
            self.cards_effective.setText("This image's VIDEO_CARDS: "
                                         + (ds.effective_video_cards(probe, spec) or "none"))
        else:
            self.gpu_state.setText(f"VIDEO_CARDS on {c.platform} is fixed by its SoC: "
                                   f"{ds.ARM_FIXED_VIDEO_CARDS.get(c.platform, '')}.")
            self.cards_effective.setText("")
        # accounts
        self.primary_state.setText("\n".join(ds.account_lines(
            c, self._entry if self._mesh() else None)))
        # apps
        self._apps_sources()
        # pretend availability
        why = dp.supported(self._pretend_cfg())
        running = self._worker is not None
        self.pretend_btn.setEnabled(not why and not running)
        if why and not running and self.last_result is None:
            self.pretend_status.setText(why)
        # problems
        probs = ds.problems(probe, spec, passwords=self._passwords())
        if probs:
            text = "\n".join(("Fix: " if p.level == "error" else "Note: ") + p.text for p in probs)
            self.problems.setText(text)
            self.problems.setStyleSheet(_ERR if any(p.level == "error" for p in probs) else _WARN)
        self.problems.setVisible(bool(probs))

    # ── navigation to the steps that own the linked rows ─────────────────────────
    def _go_back_to(self, slug: str, why_label: QtWidgets.QLabel) -> None:
        try:
            wiz = self.wizard()
            target = (getattr(self.wiz, "_page_ids", None) or {}).get(slug)
            if wiz is None or target is None or target not in wiz.visitedIds():
                why_label.setText(why_label.text().split(" — ")[0]
                                  + f" — the {slug.title()} step is not behind this one in this walk.")
                return
            self._collect()
            while wiz.currentId() != target:
                before = wiz.currentId()
                wiz.back()
                if wiz.currentId() == before:
                    break
        except Exception as exc:                # noqa: BLE001 — a slot must never raise
            why_label.setText(f"Could not go back: {exc}")

    # ── portage overlay edits (the assistant card and the fix card call these) ───
    def apply_portage_changes(self, changes, *, source: str) -> list[ds.OverlayChange]:
        self._collect()
        target = self.view()
        run = self.last_result.run_id if self.last_result else ""
        applied = ds.apply_changes(target, list(changes), source=source, pretend_run=run)
        self._store_spec(ds.spec_of(target))
        spec = ds.spec_of(self.view())
        self._loading = True
        try:
            self.use_lines.setPlainText("\n".join(spec.use_lines))
            self.kw_lines.setPlainText("\n".join(spec.keyword_lines))
        finally:
            self._loading = False
        self._refresh()
        return applied

    def undo_portage_changes(self, applied, *, source: str) -> None:
        self._collect()
        target = self.view()
        ds.undo_changes(target, list(applied), source=source)
        self._store_spec(ds.spec_of(target))
        spec = ds.spec_of(self.view())
        self._loading = True
        try:
            self.use_lines.setPlainText("\n".join(spec.use_lines))
            self.kw_lines.setPlainText("\n".join(spec.keyword_lines))
        finally:
            self._loading = False
        self._refresh()

    # ── emerge --pretend ─────────────────────────────────────────────────────────
    def _pretend_cfg(self):
        """The image config the check runs: the one image, or the mesh row materialized."""
        if self._mesh() and self._entry is not None:
            wl = getattr(self.wiz, "worklist", None)
            try:
                return wl._materialize_one(self._entry)
            except Exception:                   # noqa: BLE001 — fall back to the view
                return self.view()
        return self.wiz.cfg

    def _out_dir(self) -> str:
        import os
        c = self.wiz.cfg
        return c.output_dir or os.path.join(self.wiz.generator_dir, "out")

    def start_pretend(self) -> str:
        """Start the check; returns "" when it started, else why not (also shown inline)."""
        if self._worker is not None:
            return "A check is already running."
        self._collect()
        cfg = self._pretend_cfg()
        why = dp.supported(cfg)
        bad = ds.grammar_errors(cfg)
        if not why and bad:
            why = f"Fix first: {bad[0]}"
        if not why:
            try:
                from .. import build_supervisor
                busy = build_supervisor.supervisor().count() > 0
            except Exception:                   # noqa: BLE001
                busy = False
            why = dp.gate(self._out_dir(), supervisor_running=busy)
        if why:
            self.pretend_status.setText(why)
            self.pretend_status.setStyleSheet(_WARN)
            return why
        from ...core.build_driver import BuildDriver
        driver = BuildDriver(self.wiz.generator_dir, self.wiz.host, workdir=self._out_dir())
        self.pretend_log.clear()
        self.pretend_needs.setText("")
        self.offer_box.setVisible(False)
        self.pretend_status.setStyleSheet("")
        self.pretend_status.setText("Checking… (the builder unpacks the seed and asks the "
                                    "resolver; this takes a few minutes)")
        self._worker = _PretendWorker(cfg, driver, self._out_dir())
        self._worker_driver = driver
        self._worker.line.connect(self.pretend_log.appendPlainText)
        self._worker.done.connect(self._pretend_done)
        self.pretend_btn.setEnabled(False)
        self.stop_btn.setEnabled(True)
        self._worker.start()
        return ""

    def _stop_pretend(self) -> None:
        drv = getattr(self, "_worker_driver", None)
        if drv is not None:
            try:
                drv.cancel()
            except Exception:                   # noqa: BLE001
                pass

    def _pretend_done(self, res) -> None:
        self._worker = None
        self.stop_btn.setEnabled(False)
        self.show_result(res)

    def show_result(self, res: dp.PretendResult) -> None:
        """Render a result (from a run, or a test) and record its summary."""
        self.last_result = res
        target = self.view()
        dp.record(target, res)
        self._store_spec(ds.spec_of(target))
        words = {"clean": "Clean: the resolver sees no USE or keyword wall.",
                 "needs": "Portage needs changes before this image can build:",
                 "error": "The check failed: "}
        text = words.get(res.status, res.status)
        if res.status == "error":
            text += res.reason
        if res.seed_python:
            text += f"  (seed Python: {' '.join(res.seed_python)})"
        self.pretend_status.setText(text)
        self.pretend_status.setStyleSheet({"clean": "", "needs": _WARN}.get(res.status, _ERR))
        need_lines = [f"{k} {line}" for k, line in res.needs]
        ops = res.operator_needs()
        if ops:
            need_lines += ["", "Not applied from here (the operator's call, in the specs): "
                           + "; ".join(f"{k} {line}" for k, line in ops)]
        self.pretend_needs.setText("\n".join(need_lines))
        if res.excerpt and not self.pretend_log.toPlainText():
            self.pretend_log.setPlainText("\n".join(res.excerpt))
        offer = [ch for ch in res.applicable_needs()
                 if not ds.check_change(ch, self.view())]
        self._pending_offer = offer
        diff = ds.overlay_diff(ds.spec_of(self.view()), offer)
        if diff:
            self.offer_text.setText("Portage's own suggestion:\n" + "\n".join(diff))
            self.offer_apply.setVisible(True)
            self.offer_undo.setVisible(False)
            self.offer_recheck.setVisible(False)
            self.offer_box.setVisible(True)
        else:
            self.offer_box.setVisible(False)
        self.pretend_btn.setEnabled(not dp.supported(self._pretend_cfg()))

    def _offer_apply(self) -> None:
        self._last_applied = self.apply_portage_changes(self._pending_offer, source="autounmask")
        self.offer_text.setText(f"Applied {len(self._last_applied)} line(s). Re-check runs the "
                                "resolver again (portage often names only the first change).")
        self.offer_apply.setVisible(False)
        self.offer_undo.setVisible(True)
        self.offer_recheck.setVisible(True)

    def _offer_undo(self) -> None:
        self.undo_portage_changes(self._last_applied, source="autounmask")
        self._last_applied = []
        self.offer_text.setText("Undone: the overlay is as it was.")
        self.offer_undo.setVisible(False)
        self.offer_recheck.setVisible(False)

    def validatePage(self):
        self._collect()
        c = self.view()
        probs = [p for p in ds.problems(c, passwords=ds.parse_passwords(
            getattr(self.wiz.cfg, "extra_local_passes", "") or "")) if p.level == "error"]
        if probs:
            self.problems.setText("\n".join("Fix: " + p.text for p in probs))
            self.problems.setStyleSheet(_ERR)
            self.problems.setVisible(True)
            return False
        return True

"""The SAVED MESHES table on the local-mesh page (ask C, 2026-09-01).

"A TABLE of saved meshes shown when one tries to generate a new mesh, from which a
saved entry can be started/restored (and deleted), instead of always generating
from scratch." The page hosts this widget ABOVE its Actions row, so the table is in
front of the operator before they reach 'Generate && start'.

Modelled on :class:`.sessions_widget.PreviousBuildsWidget` but simpler — no filter
row, no per-record window — and DIFFERENT in one deliberate way: it never hides
itself at zero rows. The empty state is a visible grey line, because a hidden
table is exactly the undiscoverable feature this ask is fixing.

WHAT EACH ROW SAYS BEFORE THE CLICK. The "Restores as" column is
:func:`.saved_meshes.restore_plan`'s sentence — what pressing Start/Restore would
ACTUALLY give back (reattach the same data / bring up empty + re-seed with the
same or new passwords) — decided from live facts the page's off-thread probe
supplies (:class:`SavedMeshProbe`), never guessed at save time. Until the probe
answers the column says so ("Checking…"), and the buttons stay disabled with that
reason: unknown is not "no".

THE CURRENT MESH, AT THE TOP (operator, 2026-10-21: "Saved meshes screen does not
give anywhere to save the mesh we just started working on"). Above the table sits a
strip for the mesh being worked on — the page's form, read through the page's
``current_provider`` — with what it carries per domain, whether it is saved
already (the same as a record, or changed since one), and the SAVE controls:
``Save current mesh`` (a new record, named by the ``Save as`` box or derived), and
``Overwrite selected``, which replaces the selected record only on a SECOND click.
None of these needs a running mesh: the record is the configuration, and a restore
decides from the machine as it is, like every other record. It is a strip and not a
row of the table on purpose: the table holds records only, so a row index always
means a record and nothing that selects row 0 can mean the form.

HOUSE RULES THIS FILE KEEPS:
  * NO modal from page logic. Delete is armed by typing the record's label into an
    inline QLineEdit (the vaults_dialog idiom) — never a nested QMessageBox; an
    overwrite is armed by its own first click and carried out by the second.
  * ``cellClicked``/``itemActivated`` only. Never ``itemChanged``.
  * ONE writer of ``setEnabled`` for the button cluster (:meth:`_update_buttons`),
    and every disabled button carries the reason in its tooltip.
  * Nothing here shells out. The docker/git work lives in :mod:`.core.saved_meshes`
    and runs on the page's ``_saved_probe`` QThread; this widget only renders.
  * :func:`.vaults.remove_volume` is never called: Delete removes the RECORD and
    its own side dir, and says so where it is pressed.
"""
from __future__ import annotations

import os
import socket
from dataclasses import dataclass, field

from ..qt import QtCore, QtGui, QtWidgets, Signal
from ...core import saved_meshes as sm
from ._emulation_common import make_table, set_cell

#: plain words for :func:`.saved_meshes.unrecorded_fields` in the overwrite note
_UNRECORDED_WORDS = {"services": "services", "kind_addons": "DevOps add-ons"}

# Symbolic column indices only (network.py's rule).
(_SM_COL_MESH, _SM_COL_SAVED, _SM_COL_ENV, _SM_COL_SERVICES,
 _SM_COL_RESTORE, _SM_COL_VOLUMES, _SM_COL_DOMAINS) = range(7)
_SM_HEADERS = ("Mesh", "Saved", "Env / brand", "Services", "Restores as", "Volumes",
               "Domains")

_EMPTY_NOTE = ("No saved meshes yet — press 'Save current mesh' above (it does not "
               "need the mesh to be running). A record keeps the mesh's configuration "
               "— every domain's look, sign-in, services and VPN/egress choices "
               "included — its source HEADs, credential pointers and a volume "
               "inventory, so it can be loaded, started or restored from here instead "
               "of set up from scratch.")

#: The heading of the "current mesh" strip at the top of the list, by state.
_CURRENT_TITLE = {
    "unsaved": "Current mesh — not saved yet",
    "same": "Current mesh — saved as ‘{label}’, no changes since",
    "changed": "Current mesh — changed since it was saved as ‘{label}’",
    "none": "Current mesh — the form could not be read",
}

_VOLUMES_NOTE = (
    "Records never contain data volumes — only an inventory of them. They are "
    "multi-GB, a consistent copy needs the stack halted plus a helper container per "
    "volume, 'Stop mesh' (make stack-halt) keeps them on disk anyway, and copying "
    "casdoor-pg would put an identity database into the Studio state dir. After "
    "'Stop mesh' a saved entry STARTS with its data intact; after 'Stop && clean "
    "Docker' it is RESTORED empty and re-seeded — same usernames; the same passwords "
    "only if the record kept credential copies.")

_CANNOT_RESTORE = (
    "Never restored: the tailnet auth key (re-enter it for a prod mesh), passwords "
    "of users added with 'Add user…' (env-only at creation), the exact image bits "
    "after a clean (rebuilt from the tree as it is now), and the .onion after a "
    "clean (its key volume is gone).")


class SavedMeshProbe(QtCore.QThread):
    """Ask docker/git what is TRUE for each record, off the GUI thread.

    :func:`.saved_meshes.probe_state` is `docker volume ls` + `docker ps` +
    `docker images` + a `git rev-parse` per source repo, per record — the same
    class of call the page's ``_StatusProbe`` exists for. Emits ``{record id:
    probe dict}``; never raises (an exception escaping run() would leave every
    row stuck on "Checking…" forever)."""
    result = Signal(object)        # dict[str, dict]

    def __init__(self, records: list, parent=None):
        super().__init__(parent)
        self._records = list(records)

    def run(self):
        out: dict[str, dict] = {}
        for rec in self._records:
            try:
                out[rec.id] = sm.probe_state(rec)
            except Exception as e:            # never kill the page over a probe
                out[rec.id] = {"error": f"{type(e).__name__}: {e}"}
            # which VERSION of the record these facts are about: an overwrite keeps
            # the id, and an answer for the old one must not land on the new one
            out[rec.id]["_updated"] = rec.updated
        self.result.emit(out)


@dataclass
class _Row:
    kind: str                                  # "record" | "unreadable"
    rec: sm.SavedMesh | None = None
    path: str = ""
    probe: dict | None = None                  # probe_state() result, None until probed
    plan: sm.RestorePlan = field(default_factory=sm.RestorePlan)

    @property
    def label(self) -> str:
        if self.rec is not None:
            return self.rec.label or self.rec.id
        return os.path.basename(self.path)


class SavedMeshesWidget(QtWidgets.QWidget):
    #: (SavedMesh, mode) — mode is saved_meshes.MODE_START / MODE_RESEED.
    start_requested = Signal(object, str)
    #: SavedMesh — "Load into the form" only; nothing runs.
    load_requested = Signal(object)
    #: list[SavedMesh] — the page owns the QThread (own_probe/probe_running).
    probe_needed = Signal(object)
    #: (SavedMesh | None, label) — save the CURRENT mesh: None = a new record, a
    #: record = overwrite that one (already confirmed by the second click). The page
    #: does the capture off-thread and calls :meth:`mark_current` when it is written.
    save_requested = Signal(object, str)

    def __init__(self, parent=None):
        super().__init__(parent)
        #: The Collapsible the page wraps this in (set by the page); refresh()
        #: folds/unfolds it by record count via set_default_expanded, so a
        #: manual fold still wins for the session.
        self.section = None
        self.generator_dir = ""
        self.hostname = socket.gethostname()
        self._mesh_up: bool | None = None
        self._busy = False
        self._rows: list[_Row] = []
        #: () -> the current mesh's config dict (``saved_meshes.config_for_record``),
        #: set by the page. None = this widget has no form behind it (the strip
        #: says so and Save stays off).
        self.current_provider = None
        self._current: dict | None = None
        self._current_error = ""
        #: the record the form was last saved as / loaded from (this session)
        self._tied_id = ""
        #: the record id the FIRST click of Overwrite armed ("" = not armed)
        self._armed_id = ""

        lay = QtWidgets.QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)

        # ── THE CURRENT MESH (top of the list) ───────────────────────────────
        self.current_box = QtWidgets.QFrame()
        self.current_box.setObjectName("savedMeshesCurrent")
        self.current_box.setFrameShape(QtWidgets.QFrame.Shape.StyledPanel)
        # never taller than its contents: spare height belongs to the list below,
        # not to gaps between the strip's lines
        self.current_box.setSizePolicy(QtWidgets.QSizePolicy.Policy.Preferred,
                                       QtWidgets.QSizePolicy.Policy.Maximum)
        cur = QtWidgets.QVBoxLayout(self.current_box)
        cur.setContentsMargins(8, 6, 8, 6)
        self.current_title = QtWidgets.QLabel(_CURRENT_TITLE["unsaved"])
        f = self.current_title.font()
        f.setBold(True)
        self.current_title.setFont(f)
        self.current_title.setWordWrap(True)
        cur.addWidget(self.current_title)
        self.current_summary = QtWidgets.QLabel("")
        self.current_summary.setTextFormat(QtCore.Qt.TextFormat.PlainText)
        self.current_summary.setWordWrap(True)
        cur.addWidget(self.current_summary)
        self.current_domains = QtWidgets.QLabel("")
        self.current_domains.setTextFormat(QtCore.Qt.TextFormat.PlainText)
        self.current_domains.setWordWrap(True)
        self.current_domains.setStyleSheet("color: gray;")
        cur.addWidget(self.current_domains)
        # GRID, not one row: the wizard sizes to its widest page.
        save_row = QtWidgets.QGridLayout()
        self.name_label = QtWidgets.QLabel("Save as:")
        self.name_edit = QtWidgets.QLineEdit()
        self.name_edit.setPlaceholderText("a name for the record (blank = derived)")
        self.name_edit.textChanged.connect(self._on_name_changed)
        self.name_label.setBuddy(self.name_edit)
        self.save_btn = QtWidgets.QPushButton("Save current mesh")
        self.save_btn.clicked.connect(self._save_new)
        self.overwrite_btn = QtWidgets.QPushButton("Overwrite selected")
        self.overwrite_btn.clicked.connect(self._overwrite)
        save_row.addWidget(self.name_label, 0, 0)
        save_row.addWidget(self.name_edit, 0, 1, 1, 2)
        save_row.addWidget(self.save_btn, 1, 1)
        save_row.addWidget(self.overwrite_btn, 1, 2)
        save_row.setColumnStretch(1, 1)
        save_row.setColumnStretch(2, 1)
        cur.addLayout(save_row)
        # What the armed overwrite will replace — inline, never a modal.
        self.overwrite_note = QtWidgets.QLabel("")
        self.overwrite_note.setWordWrap(True)
        self.overwrite_note.setStyleSheet("color: #a05000;")
        self.overwrite_note.setVisible(False)
        cur.addWidget(self.overwrite_note)
        lay.addWidget(self.current_box)

        self.empty_note = QtWidgets.QLabel(_EMPTY_NOTE)
        self.empty_note.setWordWrap(True)
        self.empty_note.setStyleSheet("color: gray;")
        lay.addWidget(self.empty_note)

        # The page body is a QScrollArea (scrollable(self)), so min_height is
        # mandatory or the table collapses to its header row; the max keeps the
        # page a page.
        self.table = make_table(_SM_HEADERS, min_height=140)
        self.table.setMaximumHeight(200)
        self.table.verticalHeader().setVisible(False)
        self.table.setSelectionBehavior(
            QtWidgets.QAbstractItemView.SelectionBehavior.SelectRows)
        self.table.setSelectionMode(
            QtWidgets.QAbstractItemView.SelectionMode.SingleSelection)
        self.table.itemSelectionChanged.connect(self._update_buttons)
        self.table.cellClicked.connect(lambda _r, _c: self._update_buttons())
        # Enter/double-click = the row's primary action, whatever the plan allows.
        self.table.itemActivated.connect(lambda _it: self._activate())
        lay.addWidget(self.table)

        self.volumes_note = QtWidgets.QLabel(_VOLUMES_NOTE + " " + _CANNOT_RESTORE)
        self.volumes_note.setWordWrap(True)
        self.volumes_note.setStyleSheet("color: gray;")
        lay.addWidget(self.volumes_note)

        # Anything the last Load/Start could not apply, or the last delete —
        # inline, never a modal.
        self.note = QtWidgets.QLabel("")
        self.note.setWordWrap(True)
        self.note.setStyleSheet("color: gray;")
        self.note.setVisible(False)
        lay.addWidget(self.note)

        # GRID, not one row: the wizard sizes to its widest page.
        btns = QtWidgets.QGridLayout()
        self.start_btn = QtWidgets.QPushButton("Start")
        self.start_btn.clicked.connect(self._start)
        self.restore_btn = QtWidgets.QPushButton("Restore (reseed)")
        self.restore_btn.clicked.connect(self._restore)
        self.load_btn = QtWidgets.QPushButton("Load into the form")
        self.load_btn.clicked.connect(self._load)
        self.reveal_btn = QtWidgets.QPushButton("Reveal folder")
        self.reveal_btn.setToolTip("Open the records folder in your file manager.")
        self.reveal_btn.clicked.connect(self._reveal)
        for col, b in enumerate((self.start_btn, self.restore_btn, self.load_btn,
                                 self.reveal_btn)):
            btns.addWidget(b, 0, col)
        btns.setColumnStretch(4, 1)
        lay.addLayout(btns)

        # DESTRUCTIVE ROW — the vaults_dialog inline confirm: type the record's
        # label to arm Delete. Only the RECORD (and its own credential-copy dir)
        # is removed; the running mesh, its volumes and keys-out/ are untouched.
        self.danger = QtWidgets.QLabel("")
        self.danger.setWordWrap(True)
        self.danger.setStyleSheet("color: #a05000;")
        self.danger.setVisible(False)
        lay.addWidget(self.danger)
        del_row = QtWidgets.QHBoxLayout()
        self.confirm = QtWidgets.QLineEdit()
        self.confirm.setPlaceholderText("type the record's name to enable Delete")
        self.confirm.textChanged.connect(self._update_buttons)
        self.delete_btn = QtWidgets.QPushButton("Delete record")
        self.delete_btn.clicked.connect(self._delete)
        del_row.addWidget(self.confirm, 1)
        del_row.addWidget(self.delete_btn)
        lay.addLayout(del_row)
        self._update_buttons()

    # ---- page-supplied context ------------------------------------------------
    def set_context(self, *, mesh_up: bool | None, busy: bool) -> None:
        """The page's own facts: is a mesh up (its tri-state ``_mesh_up``), and is
        a verb running. Re-derives every row's plan and the button gate."""
        changed = (mesh_up != self._mesh_up) or (busy != self._busy)
        self._mesh_up, self._busy = mesh_up, busy
        if changed:
            if busy:
                self._disarm()
            self._replan()
            self._update_buttons()

    def set_note(self, text: str) -> None:
        self.note.setText(text)
        self.note.setVisible(bool(text))

    # ---- the current mesh (the strip at the top) ---------------------------------
    def update_current(self) -> None:
        """Re-read the current mesh from the page (``current_provider``) and re-render
        the strip. Cheap — the page's form plus an in-memory compare against the
        records already listed; no disk, no subprocess. A provider that raises leaves
        the strip saying the form could not be read, with Save off: a record of a form
        nobody could read would describe nothing."""
        self._current, self._current_error = None, ""
        if self.current_provider is not None:
            try:
                cur = self.current_provider()
                self._current = dict(cur) if isinstance(cur, dict) else None
            except Exception as e:                    # noqa: BLE001 — never kill the page
                self._current_error = f"{type(e).__name__}: {e}"
        self._render_current()
        self._update_buttons()

    def mark_current(self, rec_id: str) -> None:
        """The form now IS record ``rec_id`` (it was just saved as it, or loaded or
        started from it): the strip compares against that record from here on."""
        self._tied_id = str(rec_id or "")
        self._render_current()

    def current_state(self) -> tuple[str, "sm.SavedMesh | None", list[str]]:
        """``(state, record, changed fields)`` for the strip: ``unsaved``, ``same``
        (identical to ``record``), ``changed`` (differs from the record it was saved
        as or loaded from) or ``none`` (no form / unreadable form)."""
        if self._current is None:
            return "none", None, []
        recs = [r.rec for r in self._rows if r.rec is not None]
        tied = next((r for r in recs if r.id == self._tied_id), None)
        if tied is not None:
            changes = sm.config_changes(tied.config, self._current, unrecorded_ok=True)
            return ("same" if not changes else "changed"), tied, changes
        for r in recs:
            if r.same_checkout(self.generator_dir, self.hostname) and \
                    not sm.config_changes(r.config, self._current):
                return "same", r, []
        return "unsaved", None, []

    def _render_current(self) -> None:
        state, rec, changes = self.current_state()
        label = (rec.label or rec.id) if rec is not None else ""
        self.current_title.setText(_CURRENT_TITLE[state].format(label=label))
        if state == "none":
            self.current_summary.setText(
                ("The form could not be read: " + self._current_error)
                if self._current_error else
                "There is no mesh form behind this list, so there is nothing to save.")
            self.current_domains.setText("")
            return
        cur = self._current or {}
        env = str(cur.get("env") or "test")
        brand = str(cur.get("brand") or "")
        summary = (f"{env} / {brand}" if brand else env) + \
            " · services: " + sm.services_text_of(cur)
        if state == "changed" and changes:
            shown = ", ".join(changes[:6]) + (", …" if len(changes) > 6 else "")
            summary += f"\nChanged since it was saved: {shown}."
        self.current_summary.setText(summary)
        lines = sm.domain_lines_of(cur)
        self.current_domains.setText(
            "\n".join(lines) if lines else
            "Domains: this mesh's own domain only, at its defaults.")

    def _on_name_changed(self, *_):
        self._disarm()
        self._update_buttons()

    def _disarm(self) -> None:
        if self._armed_id:
            self._armed_id = ""
        self.overwrite_btn.setText("Overwrite selected")
        self.overwrite_note.setVisible(False)

    def _typed_label(self) -> str:
        return self.name_edit.text().strip()

    def _save_new(self) -> None:
        """One press: a NEW record of the current mesh. A blank name is derived by the
        core (and made unique here, so the Delete confirmation — type the name — is
        never ambiguous); a typed name that another record already has is refused by
        the gate in :meth:`_update_buttons`, with Overwrite named as the way."""
        if not self.save_btn.isEnabled() or self._current is None:
            return
        label = self._typed_label()
        if not label:
            label = sm.unique_label(sm.derived_label_of(self._current), self.records())
        self._disarm()
        self.save_requested.emit(None, label)

    def _overwrite(self) -> None:
        """TWO clicks. The first ARMS (the button and the note say exactly which
        record is replaced, and what goes with it); the second, on the same selected
        record, asks the page to save over it. Any selection change, a typed name,
        a refresh or a verb starting disarms it."""
        r = self.selected()
        if (not self.overwrite_btn.isEnabled() or r is None or r.rec is None
                or self._current is None):
            return
        rec = r.rec
        if self._armed_id != rec.id:
            self._armed_id = rec.id
            label = rec.label or rec.id
            self.overwrite_btn.setText(f"Click again to overwrite ‘{label}’")
            copies = (" Its saved credential copies are removed: this save keeps "
                      "pointers only." if rec.has_credential_copies() else "")
            rename = ""
            typed = self._typed_label()
            if typed and typed != (rec.label or ""):
                rename = f" It is renamed to ‘{typed}’."
            # a record that never recorded a services / DevOps add-on choice does not
            # read as "changed" when loaded, so say here that the form's choice is
            # written into it
            unrecorded = [_UNRECORDED_WORDS.get(k, k)
                          for k in sm.unrecorded_fields(rec.config)]
            fills = (" It never recorded a choice of " + " or ".join(unrecorded)
                     + "; the form's current ticks are written in." if unrecorded
                     else "")
            # a record whose mesh RAN keeps that it did (capture's ran_before_at):
            # only a record that never ran is called one that never ran
            try:
                last_ran = rec.last_ran_at()
            except Exception:                       # noqa: BLE001 — wording only
                last_ran = ""
            if self._mesh_up is not False:
                draft = ""
            elif last_ran:
                draft = (" The Docker mesh is not running, so unless the DevOps lane "
                         "is up the replaced record is marked not run as saved (it "
                         "keeps that this mesh last ran "
                         f"{last_ran[:16].replace('T', ' ')}) and the node-image "
                         "pages stop importing it by default.")
            else:
                draft = (" The Docker mesh is not running, so unless the DevOps lane "
                         "is up the replaced record stays a draft (never ran).")
            self.overwrite_note.setText(
                f"A second click replaces the saved record ‘{label}’ (saved "
                f"{(rec.updated or rec.created or '?')[:16].replace('T', ' ')}) with "
                "the mesh being "
                f"worked on now. Its place in the list is kept.{rename}{copies}"
                f"{fills}{draft} Its data volumes and the running mesh are not "
                "touched.")
            self.overwrite_note.setVisible(True)
            return
        label = self._typed_label() or rec.label or rec.id
        self._disarm()
        self.save_requested.emit(rec, label)

    # ---- data -------------------------------------------------------------------
    def records(self) -> list:
        return [r.rec for r in self._rows if r.rec is not None]

    def record_count(self) -> int:
        return len(self._rows)

    def unprobed(self) -> list:
        """Records with no probe answer yet (a record saved while a probe was
        out, for instance) — what the page re-probes when one finishes."""
        return [r.rec for r in self._rows if r.rec is not None and r.probe is None]

    def refresh(self) -> None:
        """Rebuild the rows from disk (a directory listing plus JSON parses — no
        subprocess). Probe results already known for a record are kept so the
        table does not flash back to "Checking…" on every revisit; records the
        probe has not seen yet are handed to the page via ``probe_needed``."""
        # keyed by id AND the record's `updated` stamp: an OVERWRITE keeps the id, and
        # the old record's facts (its volumes, its credential copies) say nothing
        # about the record that replaced it
        known = {(r.rec.id, r.rec.updated): r.probe for r in self._rows
                 if r.rec is not None and r.probe is not None}
        recs, unreadable = sm.scan()
        rows = [_Row("record", rec=rec, probe=known.get((rec.id, rec.updated)))
                for rec in recs]
        rows += [_Row("unreadable", path=p) for p in unreadable]
        self._rows = rows
        self._disarm()
        self.empty_note.setVisible(not rows)
        self.table.setRowCount(len(rows))
        for i, r in enumerate(rows):
            self._render_row(i, r)
        self.table.resizeColumnsToContents()
        self._replan()
        # the strip compares the form against the records just read
        self.update_current()
        if self.section is not None:
            # OPEN whenever there is something to act on: a record, or the current
            # mesh to save (the Save controls live in here — folded away at zero
            # records they were exactly the "nowhere to save" the operator found)
            self.section.set_default_expanded(bool(rows) or self._current is not None)
        pending = [r.rec for r in rows if r.rec is not None and r.probe is None]
        if pending:
            self.probe_needed.emit(pending)

    def apply_probe(self, results: dict) -> None:
        """The page's ``_saved_probe`` answered: attach each record's facts and
        re-derive its plan (pure)."""
        for r in self._rows:
            if r.rec is not None and r.rec.id in results:
                ans = results[r.rec.id]
                if isinstance(ans, dict) and "_updated" in ans and \
                        ans["_updated"] != r.rec.updated:
                    continue                 # facts about a record since overwritten
                r.probe = ans
        self._replan()
        self._update_buttons()

    def _replan(self) -> None:
        for i, r in enumerate(self._rows):
            if r.rec is None:
                continue
            probe = r.probe or {}
            if probe and "error" not in probe:
                kw = {k: probe[k] for k in (
                    "volumes_present", "images_present", "creds_match",
                    "mesh_running", "source_ok", "copies_missing", "source_drift",
                    "volumes_missing", "volumes_seen", "unanswered") if k in probe}
                # the page's own answer counts too: a mesh it knows is up blocks
                # a Start even if the docker probe has not caught up. A probe that
                # could not answer (None, #361) stays None — `bool(None)` here read
                # as "nothing running" and offered Restore over a mesh that may be up;
                # the page's own `_mesh_up` False is no better evidence (its status()
                # also reports running=False when docker raises).
                if self._mesh_up is True:
                    kw["mesh_running"] = True
                r.plan = sm.restore_plan(r.rec, **kw)
            elif probe:
                r.plan = sm.RestorePlan(
                    sm.MODE_UNKNOWN,
                    "Could not check this machine: " + str(probe.get("error")),
                    (), "unknown")
            else:
                r.plan = sm.RestorePlan()
            self._render_plan_cells(i, r)

    # ---- rendering --------------------------------------------------------------
    def _render_row(self, i: int, r: _Row) -> None:
        if r.rec is None:
            set_cell(self.table, i, _SM_COL_MESH, os.path.basename(r.path),
                     tooltip=r.path, colour="#c62828")
            set_cell(self.table, i, _SM_COL_SAVED, "unreadable",
                     tooltip="This record file could not be parsed. It is shown so "
                             "you can delete it; it is never rewritten.")
            for c in (_SM_COL_ENV, _SM_COL_SERVICES):
                set_cell(self.table, i, c, "—")
            set_cell(self.table, i, _SM_COL_RESTORE, "cannot be restored (corrupt record)")
            set_cell(self.table, i, _SM_COL_VOLUMES, "—")
            set_cell(self.table, i, _SM_COL_DOMAINS, "—")
            return
        rec = r.rec
        tip = (f"{rec.id}\nsaved {rec.updated or rec.created} on {rec.hostname or '?'}"
               + (f" (first saved {rec.created})"
                  if rec.updated and rec.created and rec.updated != rec.created else "")
               + "\n"
               f"generator: {rec.generator_dir} @ {rec.generator_head[:12] or '?'}")
        if not rec.same_checkout(self.generator_dir, self.hostname):
            tip += ("\n\nThis record is from ANOTHER checkout or host — it points "
                    "at another mesh's volumes, so Start is disabled here.")
        set_cell(self.table, i, _SM_COL_MESH, rec.label or rec.id, tooltip=tip)
        # The LAST save, as the node-image picker shows it: an Overwrite keeps
        # `created` and moves `updated` (saved-meshes skeptic 3 — the two screens
        # disagreed about when the same record was saved).
        # A plain save stamps `created` and then `updated` a moment apart; more than
        # two minutes apart is a later save of the same record (an Overwrite, or a
        # Start that wrote the form's Domain services walk into it).
        last = rec.updated or rec.created or ""
        t_up, t_made = sm._stamp(rec.updated), sm._stamp(rec.created)
        resaved = bool(t_up and t_made and t_up - t_made > 120)
        set_cell(self.table, i, _SM_COL_SAVED,
                 last[:16].replace("T", " ") + (" (re-saved)" if resaved else ""),
                 tooltip=(f"last saved {rec.updated}\nfirst saved {rec.created}"
                          if resaved else last))
        set_cell(self.table, i, _SM_COL_ENV, rec.brand_text())
        set_cell(self.table, i, _SM_COL_SERVICES, rec.services_text(),
                 tooltip=rec.services_text())
        lines = rec.domain_lines()
        names = [ln.split(" — ", 1)[0] for ln in lines]
        set_cell(self.table, i, _SM_COL_DOMAINS,
                 (f"{len(names)}: " + ", ".join(names)) if names else "own domain only",
                 tooltip="\n".join(lines) if lines else
                 "This record carries no domain rows: the mesh's own domain only, at "
                 "its defaults.")
        self._render_plan_cells(i, r)

    def _render_plan_cells(self, i: int, r: _Row) -> None:
        if r.rec is None:
            return
        plan = r.plan
        colour = {"start": "#188038", "reseed": "#a65d00", "blocked": "#c62828"}.get(
            plan.mode, "")
        tip = plan.sentence
        if plan.warnings:
            tip += "\n\n" + "\n".join(f"• {w}" for w in plan.warnings)
        set_cell(self.table, i, _SM_COL_RESTORE, plan.sentence, tooltip=tip,
                 colour=colour)
        vol_tip = "\n".join(r.rec.volume_names()) or "no volumes were recorded"
        set_cell(self.table, i, _SM_COL_VOLUMES, plan.volumes_text, tooltip=vol_tip)

    # ---- selection + the one setEnabled writer ---------------------------------
    def selected(self) -> _Row | None:
        rows = {ix.row() for ix in self.table.selectedIndexes()}
        if len(rows) != 1:
            return None
        i = rows.pop()
        return self._rows[i] if 0 <= i < len(self._rows) else None

    def _update_buttons(self, *_) -> None:
        r = self.selected()
        busy_tip = "Disabled while a verb is running — wait for it to finish, or Cancel."
        none_tip = "Select a saved mesh first."

        def gate(btn, on: bool, why: str, ok_tip: str) -> None:
            btn.setEnabled(bool(on))
            btn.setToolTip(ok_tip if on else why)

        self._gate_save(r, gate, busy_tip)
        if r is None:
            for b, ok_tip in ((self.start_btn, ""), (self.restore_btn, ""),
                              (self.load_btn, ""), (self.delete_btn, "")):
                gate(b, False, none_tip, ok_tip)
            self.danger.setVisible(False)
            self.confirm.setEnabled(False)
            return
        self.confirm.setEnabled(not self._busy)
        if r.rec is None:
            gate(self.start_btn, False, "This record is unreadable — only Delete applies.", "")
            gate(self.restore_btn, False, "This record is unreadable — only Delete applies.", "")
            gate(self.load_btn, False, "This record is unreadable — only Delete applies.", "")
        elif self._busy:
            for b in (self.start_btn, self.restore_btn, self.load_btn):
                gate(b, False, busy_tip, "")
        else:
            rec, plan = r.rec, r.plan
            same = rec.same_checkout(self.generator_dir, self.hostname)
            other = ("This record is from another checkout or host "
                     f"({rec.generator_dir} on {rec.hostname or '?'}) — it points at "
                     "another mesh's volumes. Load it into the form and use "
                     "'Generate && start', or restore it cold.")
            if self._mesh_up is True:
                why = "A local mesh is running — stop it first."
                gate(self.start_btn, False, why, "")
                gate(self.restore_btn, False, why, "")
            elif plan.mode == sm.MODE_UNKNOWN:
                gate(self.start_btn, False, plan.sentence, "")
                gate(self.restore_btn, False, plan.sentence, "")
            elif plan.mode == sm.MODE_BLOCKED:
                gate(self.start_btn, False, plan.sentence, "")
                gate(self.restore_btn, False, plan.sentence, "")
            elif plan.can_start():
                gate(self.start_btn, same,
                     other if not same else plan.sentence, plan.sentence)
                gate(self.restore_btn, False,
                     "Its data volumes are still here — use Start to reattach them. "
                     "Restore (reseed) is for a mesh whose volumes are gone.", "")
            else:
                gate(self.start_btn, False,
                     "Its data volumes are gone — there is nothing to reattach; "
                     "Restore (reseed) brings it up empty and seeds it again.", "")
                gate(self.restore_btn, True, "", plan.sentence)
            gate(self.load_btn, True, "",
                 "Put this record's configuration into the form above without "
                 "starting anything. The auth key is never stored and stays as typed.")
        typed = self.confirm.text().strip() == r.label
        gate(self.delete_btn, typed and not self._busy,
             busy_tip if self._busy else
             f"Type '{r.label}' in the box to enable Delete.",
             "Delete this RECORD (and its own credential-copy folder, if any). The "
             "running mesh, its data volumes and keys-out/ are untouched.")
        self.danger.setText(
            f"Delete removes only the record '{r.label}'"
            + (" and its credential copies" if r.rec is not None and
               r.rec.has_credential_copies() else "")
            + ". The running mesh, its volumes and keys-out/ are not touched.")
        self.danger.setVisible(True)

    def _gate_save(self, r: "_Row | None", gate, busy_tip: str) -> None:
        """Save current mesh / Overwrite selected — part of the one setEnabled writer
        (:meth:`_update_buttons` calls this first). Neither asks whether a mesh is
        RUNNING: the record is the configuration being worked on."""
        # a selection that moved off the armed record disarms it
        if self._armed_id and (r is None or r.rec is None or r.rec.id != self._armed_id):
            self._disarm()
        typed = self._typed_label()
        records = self.records()
        if self._current is None:
            why = ("The form could not be read: " + self._current_error
                   if self._current_error else "There is no mesh form to save here.")
            gate(self.save_btn, False, why, "")
            gate(self.overwrite_btn, False, why, "")
            self.name_edit.setEnabled(False)
            return
        self.name_edit.setEnabled(not self._busy)
        taken = sm.label_owner(typed, records) if typed else None
        save_tip = ("Save the mesh being worked on as a NEW record"
                    + (f" called ‘{typed}’" if typed else " (the name is derived)")
                    + ": every domain's look, sign-in, services and VPN/egress "
                      "choices, the mesh-wide settings, source HEADs and credential "
                      "POINTERS (paths and hashes — never a password). It does not "
                      "need the mesh to be running, and nothing is started or "
                      "stopped. Runs off-thread.")
        if self._busy:
            gate(self.save_btn, False, busy_tip, save_tip)
        elif taken is not None:
            gate(self.save_btn, False,
                 f"A saved mesh is already called ‘{taken.label}’ — pick another name, "
                 "or select that record and use Overwrite selected.", save_tip)
        else:
            gate(self.save_btn, True, "", save_tip)

        over_ok = ("Replace the selected record with the mesh being worked on. The "
                   "FIRST click only arms this and says what is replaced; the "
                   "second click saves over it.")
        if self._busy:
            gate(self.overwrite_btn, False, busy_tip, over_ok)
        elif r is None or r.rec is None:
            gate(self.overwrite_btn, False,
                 "Select the saved record to replace first." if r is None else
                 "This record is unreadable — delete it, then save a new one.", over_ok)
        elif not r.rec.same_checkout(self.generator_dir, self.hostname):
            gate(self.overwrite_btn, False,
                 "This record is from another checkout or host — it describes "
                 "another mesh; save a new record instead.", over_ok)
        elif typed and sm.label_owner(typed, records, exclude_id=r.rec.id) is not None:
            gate(self.overwrite_btn, False,
                 f"Another saved mesh is already called ‘{typed}’ — pick another "
                 "name, or clear the box to keep this record's name.", over_ok)
        else:
            gate(self.overwrite_btn, True, "", over_ok)

    # ---- actions ------------------------------------------------------------------
    def _activate(self) -> None:
        if self.start_btn.isEnabled():
            self._start()
        elif self.restore_btn.isEnabled():
            self._restore()

    def _start(self) -> None:
        r = self.selected()
        if r is None or r.rec is None or not self.start_btn.isEnabled():
            return
        self.start_requested.emit(r.rec, sm.MODE_START)

    def _restore(self) -> None:
        r = self.selected()
        if r is None or r.rec is None or not self.restore_btn.isEnabled():
            return
        self.start_requested.emit(r.rec, sm.MODE_RESEED)

    def _load(self) -> None:
        r = self.selected()
        if r is None or r.rec is None:
            return
        self.load_requested.emit(r.rec)

    def _delete(self) -> None:
        r = self.selected()
        if r is None or not self.delete_btn.isEnabled():
            return
        if self.confirm.text().strip() != r.label:
            return
        if r.rec is not None:
            sm.delete(r.rec, remove_copies=True)
        else:
            sm.delete_path(r.path)
        self.confirm.clear()
        self.set_note(f"Deleted the record '{r.label}'. Nothing else was touched.")
        self.refresh()

    def _reveal(self) -> None:
        d = sm.meshes_dir()
        try:
            os.makedirs(d, exist_ok=True)
        except OSError:
            pass
        QtGui.QDesktopServices.openUrl(QtCore.QUrl.fromLocalFile(d))

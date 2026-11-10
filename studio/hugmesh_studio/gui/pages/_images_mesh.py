"""The node-image flow's mesh on screen: SAVE it on the Build screen, and START it
locally while the images build (the GUI half of core/images_mesh.py).

Operator ask (2026-11-09): "when someone makes a mesh in the mesh node images studio
path, they should have the option to save that mesh before proceeding to the build as
well as starting that mesh locally as the build proceeds".

Two widgets, one per page:

* :class:`ImagesMeshStrip` — on LaunchPage, ABOVE the two cards: a name, a Save button
  and an inline status (never a modal — the no-modals-in-page-logic rule), plus the
  two choices the progress page acts on: save again automatically when the build
  starts (default on), and start a local copy while it builds (default off, with the
  resource gate's verdict shown as soon as it is ticked).
* :class:`LocalMeshPanel` — on ProgressPage, shown only when one of those choices is
  on: the dispatch save's outcome, the local mesh's live tail and a Stop button.

The choices live on the WIZARD as transient attributes (``saved_mesh_id``,
``images_mesh_autosave``, ``images_mesh_start_local``), never on ``cfg``: a saved
config and the builder argv stay ignorant of them.

Everything blocking (``capture`` shells out to docker and git; a start is a compose
build) runs on a QThread held by ``hold_thread``/``own_probe``, and every slot is
exception-guarded (PyQt6 qFatals on an exception escaping a slot). A failure here is a
line on screen — never a failed build.
"""
from __future__ import annotations

import os
import sys
import threading
import traceback

from ..qt import QtCore, QtWidgets, Qt, Signal
from ..styles import ERROR, muted
from ...core import images_mesh
from ._widgets import hold_thread, own_probe


def _log_swallowed(where: str) -> None:
    print(f"images_mesh: swallowed exception in {where}", file=sys.stderr)
    traceback.print_exc(file=sys.stderr)


class _CallThread(QtCore.QThread):
    """Run ``fn`` off the GUI thread; ``line`` streams, ``done`` carries the result.
    ``fn`` receives ``on_line`` when ``streams`` is set. Never raises: an exception
    becomes ``done(exc)``."""
    line = Signal(str)
    done = Signal(object)

    def __init__(self, fn, streams: bool = False):
        super().__init__()
        self._fn = fn
        self._streams = streams

    def run(self):
        try:
            out = self._fn(on_line=self.line.emit) if self._streams else self._fn()
        except Exception as e:                  # noqa: BLE001 — becomes a line on screen
            out = e
        self.done.emit(out)


def is_images_mesh_flow(wiz) -> bool:
    """The node-image MESH flow (ModePage "Mesh node", or "Create nodes for local
    cloud"): the only flow whose images make a mesh worth saving."""
    return getattr(getattr(wiz, "cfg", None), "mode", "") == "mesh"


# ── LaunchPage: the Save strip ─────────────────────────────────────────────────
class ImagesMeshStrip(QtWidgets.QGroupBox):
    """Save this mesh (and choose what happens to it when the build starts)."""

    def __init__(self, wiz, parent=None):
        super().__init__("Save this mesh", parent)
        self.wiz = wiz
        self._save_probe = None
        self._gate_probe = None
        lay = QtWidgets.QVBoxLayout(self)
        self.note = note = QtWidgets.QLabel(
            "Keep the mesh these images make — its brand, domains, sign-in, services "
            "and Tor — in the Saved meshes list. It is a DRAFT (not run yet) until it "
            "runs. Each image's own settings (role, board, encryption, passwords) stay "
            "with the build.")
        note.setWordWrap(True)
        note.setStyleSheet(muted())
        lay.addWidget(note)
        row = QtWidgets.QHBoxLayout()
        row.addWidget(QtWidgets.QLabel("Name:"))
        self.name_edit = QtWidgets.QLineEdit()
        self.name_edit.setAccessibleName("Saved mesh name")
        row.addWidget(self.name_edit, 1)
        self.save_btn = QtWidgets.QPushButton("Save mesh")
        self.save_btn.setAccessibleName("Save this mesh")
        self.save_btn.clicked.connect(self._save_clicked)
        row.addWidget(self.save_btn)
        lay.addLayout(row)
        self.status = QtWidgets.QLabel("")
        self.status.setWordWrap(True)
        self.status.setTextFormat(Qt.TextFormat.PlainText)
        self.status.hide()
        lay.addWidget(self.status)
        self.autosave_cb = QtWidgets.QCheckBox(
            "Also save it when the build starts (updates this same saved mesh)")
        self.autosave_cb.setChecked(True)
        self.autosave_cb.toggled.connect(self._autosave_toggled)
        lay.addWidget(self.autosave_cb)
        self.start_cb = QtWidgets.QCheckBox(
            "Start this mesh locally (Docker) while the images build")
        self.start_cb.toggled.connect(self._start_toggled)
        lay.addWidget(self.start_cb)
        self.gate = QtWidgets.QLabel("")
        self.gate.setWordWrap(True)
        self.gate.setTextFormat(Qt.TextFormat.PlainText)
        self.gate.hide()
        lay.addWidget(self.gate)

    # ---- page entry -----------------------------------------------------------
    def refresh(self) -> None:
        """Called from LaunchPage.initializePage: visible on the mesh flow only, the
        derived name as the placeholder, the wizard's choices reflected."""
        on = is_images_mesh_flow(self.wiz)
        self.setVisible(on)
        if not on:
            return
        self.name_edit.setPlaceholderText(images_mesh.derived_label(
            self.wiz.cfg, getattr(self.wiz, "worklist", None)))
        self.autosave_cb.setChecked(bool(getattr(self.wiz, "images_mesh_autosave", True)))
        self.start_cb.setChecked(bool(getattr(self.wiz, "images_mesh_start_local", False)))
        self._sync_save_button()
        if self.start_cb.isChecked():
            self._probe_gate()

    def _sync_save_button(self) -> None:
        saved = bool(getattr(self.wiz, "saved_mesh_id", ""))
        self.save_btn.setText("Save again (update)" if saved else "Save mesh")

    # ---- Save -----------------------------------------------------------------
    def _save_clicked(self) -> None:
        try:
            if self._save_probe is not None:
                return
            wiz = self.wiz
            label = self.name_edit.text().strip()
            rid = getattr(wiz, "saved_mesh_id", "") or ""
            gen = wiz.generator_dir
            cfg = wiz.cfg
            wl = getattr(wiz, "worklist", None)
            self.save_btn.setEnabled(False)
            self._show("Saving…", "")
            t = _CallThread(lambda: images_mesh.save(gen, cfg, wl, label=label,
                                                      record_id=rid))
            t.done.connect(self._saved)
            own_probe(self, "_save_probe", t)
            t.start()
        except Exception:                     # noqa: BLE001
            _log_swallowed("_save_clicked")
            self.save_btn.setEnabled(True)

    def _saved(self, res) -> None:
        try:
            self.save_btn.setEnabled(True)
            if isinstance(res, Exception) or not getattr(res, "ok", False):
                msg = str(res) if isinstance(res, Exception) else res.message
                self._show(f"Not saved: {msg}", ERROR)
                return
            self.wiz.saved_mesh_id = res.record.id
            if not self.name_edit.text().strip():
                self.name_edit.setText(res.record.label)
            self._show(f"Saved mesh: {res.message}. It is listed under Saved meshes; "
                       "saving again updates it.", "")
            self._sync_save_button()
        except Exception:                     # noqa: BLE001
            _log_swallowed("_saved")

    def _show(self, text: str, colour: str) -> None:
        self.status.setText(text)
        self.status.setStyleSheet(f"color: {colour};" if colour else "")
        self.status.setVisible(bool(text))

    # ---- the two choices ProgressPage acts on ------------------------------------
    def _autosave_toggled(self, on: bool) -> None:
        self.wiz.images_mesh_autosave = bool(on)

    def _start_toggled(self, on: bool) -> None:
        try:
            self.wiz.images_mesh_start_local = bool(on)
            if on:
                self._probe_gate()
            else:
                self.gate.hide()
        except Exception:                     # noqa: BLE001
            _log_swallowed("_start_toggled")

    def _probe_gate(self) -> None:
        """The resource gate's verdict for THIS host, off the GUI thread (it bind-tests
        ports and may ask docker who holds one). Checked again when the build starts."""
        if self._gate_probe is not None:
            return
        from ...core.local_mesh_domains import bootstrap_config_from_images
        cfg = self.wiz.cfg
        self.gate.setText("Checking whether this host can run it beside the build…")
        self.gate.setStyleSheet(muted())
        self.gate.show()
        t = _CallThread(lambda: images_mesh.plan_alongside(
            bootstrap_config_from_images(cfg), building=True))
        t.done.connect(self._gate_done)
        own_probe(self, "_gate_probe", t)
        t.start()

    def _gate_done(self, plan) -> None:
        try:
            if isinstance(plan, Exception):
                self.gate.setText(f"Could not check this host: {plan}")
                self.gate.setStyleSheet(f"color: {ERROR};")
                return
            if plan.ok:
                text = ("It fits beside the build: a test copy of this mesh starts when "
                        "the build does, under its own compose project and ports, and you "
                        "can stop it from the next screen.")
                colour = ""
            else:
                text = ("Right now it would NOT start beside the build:\n"
                        + "\n".join(f"• {r}" for r in plan.reasons)
                        + "\nThis is checked again when the build starts; the build "
                          "itself runs either way.")
                colour = ERROR
            self.gate.setText(text)
            self.gate.setStyleSheet(f"color: {colour};" if colour else muted())
            self.gate.show()
        except Exception:                     # noqa: BLE001
            _log_swallowed("_gate_done")


# ── ProgressPage: the dispatch save + the local mesh ─────────────────────────────
class LocalMeshPanel(QtWidgets.QGroupBox):
    """The saved mesh of this build, and its local copy while the images build."""

    TAIL_LINES = 400

    def __init__(self, parent=None):
        super().__init__("This mesh", parent)
        self.wiz = None
        self.record = None
        self.lane = None
        self._save_thread = None
        self._start_thread = None
        self._stop_thread = None
        self._cancel = threading.Event()
        self._started = False
        lay = QtWidgets.QVBoxLayout(self)
        lay.setSpacing(4)
        # two lines, two colours: the SAVE outcome, and the local copy's outcome (a
        # refused start is red; a saved mesh beside it is not)
        self.status = QtWidgets.QLabel("")
        self.status.setWordWrap(True)
        self.status.setTextFormat(Qt.TextFormat.PlainText)
        lay.addWidget(self.status)
        row = QtWidgets.QHBoxLayout()
        self.run_status = QtWidgets.QLabel("")
        self.run_status.setWordWrap(True)
        self.run_status.setTextFormat(Qt.TextFormat.PlainText)
        self.run_status.hide()
        row.addWidget(self.run_status, 1)
        self.stop_btn = QtWidgets.QPushButton("Stop local mesh")
        self.stop_btn.setAccessibleName("Stop the local copy of this mesh")
        self.stop_btn.clicked.connect(self._stop_clicked)
        self.stop_btn.hide()
        row.addWidget(self.stop_btn)
        lay.addLayout(row)
        self.tail = QtWidgets.QPlainTextEdit()
        self.tail.setReadOnly(True)
        self.tail.setMaximumBlockCount(self.TAIL_LINES)
        # compact: the image rows and their log below are what this page is for
        self.tail.setMaximumHeight(72)
        self.tail.hide()
        lay.addWidget(self.tail)
        self.hide()

    def reset(self) -> None:
        self.hide()
        self.status.setText("")
        self.status.setStyleSheet("")
        self._run("", "")
        self.tail.clear()
        self.tail.hide()
        self.stop_btn.hide()

    def begin(self, wiz, session) -> None:
        """Called once the build has been DISPATCHED (``ProgressPage._start_worker``,
        after ``build_sessions.start``). Saves the mesh — overwriting the flow's own
        record or the one saved for this session — and then, when asked, starts its
        local copy. Never raises and never touches the build."""
        try:
            self.wiz = wiz
            autosave = bool(getattr(wiz, "images_mesh_autosave", True))
            start = bool(getattr(wiz, "images_mesh_start_local", False))
            if not is_images_mesh_flow(wiz) or not (autosave or start):
                self.reset()
                return
            self.show()
            self._cancel = threading.Event()
            self._started = False
            self.status.setText("Saving this mesh…")
            gen = wiz.generator_dir
            cfg = wiz.cfg
            wl = getattr(wiz, "worklist", None)
            rid = getattr(wiz, "saved_mesh_id", "") or ""
            sid = getattr(session, "id", "") or ""
            t = _CallThread(lambda: images_mesh.save(gen, cfg, wl, record_id=rid,
                                                      session_id=sid))
            t.done.connect(lambda res, s=start: self._saved(res, s))
            self._save_thread = hold_thread(t)
            t.start()
        except Exception:                     # noqa: BLE001
            _log_swallowed("begin")

    def _line(self, text: str) -> None:
        try:
            self.tail.show()
            self.tail.appendPlainText(text)
        except Exception:                     # noqa: BLE001
            _log_swallowed("_line")

    def _saved(self, res, start: bool) -> None:
        try:
            if isinstance(res, Exception) or not getattr(res, "ok", False):
                msg = str(res) if isinstance(res, Exception) else res.message
                self.status.setText(f"This mesh was NOT saved ({msg}). The build goes "
                                    "on.")
                self.status.setStyleSheet(f"color: {ERROR};")
                return
            self.record = res.record
            self.wiz.saved_mesh_id = res.record.id
            self.status.setStyleSheet("")
            verb = "Updated" if res.message.startswith("updated") else "Saved"
            self.status.setText(f"{verb} this mesh as '{res.record.label}' in Saved "
                                "meshes (a draft until it runs); it points at this "
                                "build.")
            if start:
                self._start()
        except Exception:                     # noqa: BLE001
            _log_swallowed("_saved")

    def _start(self) -> None:
        self.lane = images_mesh.AlongsideMesh(self.wiz.generator_dir, self.record)
        self._run(f"Starting its local copy beside the build (compose project "
                  f"{self.lane.project})…", "")
        self.stop_btn.setText("Stop local mesh")
        self.stop_btn.show()
        self.stop_btn.setEnabled(True)
        lane, cancel = self.lane, self._cancel
        t = _CallThread(lambda on_line: lane.start(building=True, on_line=on_line,
                                                    cancel=cancel), streams=True)
        t.line.connect(self._line)
        t.done.connect(self._start_done)
        self._start_thread = hold_thread(t)
        self._started = True
        t.start()

    def _start_done(self, res) -> None:
        try:
            ok = (not isinstance(res, Exception)) and bool(res and res[0])
            if isinstance(res, Exception):
                self._line(f"[local mesh] FAILED: {res}")
            if ok:
                self._run(f"Its local copy is UP (compose project {self.lane.project}).",
                          "")
            elif self._cancel.is_set():
                self._run("The local copy was stopped before it came up.", "")
            else:
                self._run("Its local copy did NOT start (see below). The build is not "
                          "affected.", ERROR)
                # a refusal by the gate starts nothing (no worktree is made): nothing
                # to stop. A start that failed part-way may have left containers up.
                if not os.path.isdir(self.lane.worktree):
                    self.stop_btn.hide()
            if self._cancel.is_set():
                self._run_stop()
        except Exception:                     # noqa: BLE001
            _log_swallowed("_start_done")

    def _run(self, text: str, colour: str) -> None:
        self.run_status.setText(text)
        self.run_status.setStyleSheet(f"color: {colour};" if colour else "")
        self.run_status.setVisible(bool(text))

    def _stop_clicked(self) -> None:
        try:
            self._cancel.set()
            self.stop_btn.setEnabled(False)
            st = self._start_thread
            if st is not None and st.isRunning():
                self._line("[local mesh] stopping once the start step ends…")
                return                        # _start_done runs the stop
            self._run_stop()
        except Exception:                     # noqa: BLE001
            _log_swallowed("_stop_clicked")

    def _run_stop(self) -> None:
        if self.lane is None or self._stop_thread is not None:
            return
        lane = self.lane
        t = _CallThread(lane.stop)
        t.done.connect(self._stopped)
        own_probe(self, "_stop_thread", t)
        t.start()

    def _stopped(self, res) -> None:
        try:
            if isinstance(res, Exception):
                self._line(f"[local mesh] stop FAILED: {res}")
                self.stop_btn.setEnabled(True)
                return
            ok, lines = res
            for ln in lines:
                self._line(ln)
            self.stop_btn.setText("Stopped" if ok else "Stop local mesh")
            self.stop_btn.setEnabled(not ok)
        except Exception:                     # noqa: BLE001
            _log_swallowed("_stopped")

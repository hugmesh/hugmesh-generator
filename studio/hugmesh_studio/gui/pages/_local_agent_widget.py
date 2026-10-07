"""The "Work on this mesh with a local AI agent" card (issue #695).

One card on the local-mesh Bring-up page, which is where BOTH ways of building a local
mesh end: the Docker mesh (Generate & start) and the kind DevOps lane (Start DevOps
lane) share that page, its Actions box and its running-mesh table. So there is one card
and one probe and one launch path, with a Lane drop-down that only changes the words in
the brief (and which rebuild command it names). The stepped wizard and the single-page
``LocalMeshDialog`` both host it, because both build the same Bring-up section.

What the card does (all of it in :mod:`core.local_agent`, which is Qt-free):

* says, in plain words, the FIRST thing that is missing — Ollama not installed, the
  server not answering, no pulled model with the tools capability, the agent command not
  installed, or the app's folder not being a git repository — and the rest under it;
* keeps *Start local agent chat* disabled, with the reason as its tooltip, until none is
  missing; nothing starts without that press, and the probe it shows is read-only;
* on the press, on a worker thread: makes a copy of the chosen app's repository that has
  no remote, writes the brief beside it, and opens a terminal window running
  ``ollama launch <agent> --model <model>`` there with a stripped environment;
* when no terminal takes the request, shows the exact lines to run yourself;
* *Copy command* is always available; *Re-check* re-reads the machine.

No dialog is opened anywhere in this file (a source scan in the tests holds that), and
no window is repositioned by code (a move request does nothing on Wayland).

THE APP LIST is the service-to-folder map of the Code folders block (issue #689,
``core/code_folders.py``) when that module is present; a minimal scan of the source
root's ``hugmesh-*`` folders otherwise. That fallback is a MERGE POINT: once #689 is on
the branch the fallback is dead code and can go.
"""
from __future__ import annotations

import importlib
import os
import time
from dataclasses import dataclass, field
from typing import Callable, Optional

from ..qt import Qt, QtCore, QtGui, QtWidgets, Signal
from ..flow_layout import flow_box
from ...core import local_agent as la
from ...core.e2e_catalogue import STACK_SRC_DIR
from ._widgets import own_probe, probe_running

__all__ = ["AgentContext", "AppChoice", "Outcome", "LocalAgentWidget", "list_apps",
           "context_from_page", "TITLE"]

TITLE = "Work on this mesh with a local AI agent"
_GREEN, _AMBER, _RED = "#2e7d32", "#a65d00", "#b00020"
_INTRO = (
    "Opens a terminal with a coding agent that runs on a model on this PC (Ollama), in a "
    "copy of one app's repository that has no remote, so it cannot push. You read and "
    "approve what it does. Nothing starts until you press Start.")


@dataclass(frozen=True)
class AgentContext:
    """What the card needs to know about the mesh being built. Read at press time
    (never cached), so a changed source choice is always the one used."""
    mesh: str = ""
    domains: "tuple[str, ...]" = ()
    #: the Domain rows themselves (or saved-record dicts), for the app map
    domain_rows: tuple = ()
    doors: "dict[str, tuple[str, ...]]" = field(default_factory=dict)   # lane -> doors
    source_mode: str = "clone"
    source_dir: str = ""
    kind_cluster: str = ""
    lane: str = la.LANE_DOCKER


@dataclass(frozen=True)
class AppChoice:
    name: str
    path: str
    exists: bool
    reason: str = ""


@dataclass(frozen=True)
class Outcome:
    """What one press did. Exactly one of ``error`` and ``launch`` is set."""
    plan: "Optional[la.Plan]" = None
    clone: "Optional[la.ScratchClone]" = None
    launch: "Optional[la.LaunchResult]" = None
    error: str = ""


# ── the app list ─────────────────────────────────────────────────────────────────
def _code_folders_module():
    """The #689 folder map, or None until that change is on this branch."""
    try:
        return importlib.import_module("...core.code_folders", __package__)
    except ImportError:
        return None


def list_apps(generator_dir: str, ctx: AgentContext) -> "tuple[list[AppChoice], str]":
    """``(apps, note)``. The apps of every domain once each, with the folder the build
    reads. ``note`` says where the list came from when it is not the full map."""
    cf = _code_folders_module()
    if cf is not None:
        rows = list(ctx.domain_rows) or [{"name": ctx.mesh or "mesh",
                                           "optional_services": [], "idp": ""}]
        try:
            m = cf.code_folder_map(generator_dir, ctx.source_mode, ctx.source_dir, rows)
            seen: dict[str, AppChoice] = {}
            for dom in m.domains:
                for app in dom.apps:
                    if app.kind == cf.KIND_REPO and app.path and app.path not in seen:
                        seen[app.path] = AppChoice(app.name, app.path, bool(app.exists),
                                                   app.missing_reason)
            return sorted(seen.values(), key=lambda a: a.name), ""
        except Exception as exc:                  # noqa: BLE001 — a card must not break the page
            note = f"the app map failed ({type(exc).__name__}); listing folders instead"
    else:
        note = "listing the hugmesh-* folders of the source root"
    if ctx.source_mode == "existing":
        root = os.path.abspath(os.path.expanduser(ctx.source_dir)) if ctx.source_dir.strip() else ""
    else:
        root = os.path.join(os.path.abspath(generator_dir), STACK_SRC_DIR)
    names = []
    if root and os.path.isdir(root):
        try:
            names = sorted(n for n in os.listdir(root)
                           if n.startswith("hugmesh-") and os.path.isdir(os.path.join(root, n)))
        except OSError:
            names = []
    return [AppChoice(n, os.path.join(root, n), True) for n in names], note


def context_from_page(page) -> AgentContext:
    """Read the Bring-up page's current choices. Called at press time and on show."""
    try:
        own = page._own_domain_name()
    except Exception:                              # noqa: BLE001 — a half-built page
        own = ""
    rows = tuple(getattr(getattr(page, "mesh_domains", None), "domains", ()) or ())
    names = tuple(getattr(r, "name", "") for r in rows if getattr(r, "name", "")) or \
        ((own,) if own else ())
    existing = bool(getattr(page, "src_existing", None) is not None
                    and page.src_existing.isChecked())
    try:
        from ...core.local_stack_node import _kind_cluster_name
        cluster = _kind_cluster_name()
    except Exception:                              # noqa: BLE001
        cluster = ""
    port = os.environ.get("PUBLIC_HOST_PORT") or "8088"
    return AgentContext(
        mesh=own or (names[0] if names else ""), domains=names, domain_rows=rows,
        doors={la.LANE_DOCKER: (f"http://localhost:{port}",), la.LANE_KIND: ()},
        source_mode="existing" if existing else "clone",
        source_dir=page.src_dir.text().strip() if existing else "",
        kind_cluster=cluster)


# ── small pieces ─────────────────────────────────────────────────────────────────
class _Elided(QtWidgets.QLabel):
    """A one-line label that elides in the middle instead of widening its row, so a long
    path can never push a button out of a width-locked page. Full text is the tooltip."""

    def __init__(self, text: str = "", parent=None):
        super().__init__(parent)
        self._full = ""
        self.setSizePolicy(QtWidgets.QSizePolicy.Policy.Expanding,
                           QtWidgets.QSizePolicy.Policy.Preferred)
        self.setText(text)

    def setText(self, text: str) -> None:          # noqa: N802 — Qt's name
        self._full = text or ""
        super().setText(self._full)
        self.setToolTip(self._full)

    def full_text(self) -> str:
        return self._full

    def minimumSizeHint(self) -> QtCore.QSize:     # noqa: N802
        base = super().minimumSizeHint()
        return QtCore.QSize(self.fontMetrics().horizontalAdvance("MMMM…"), base.height())

    def elided_text(self) -> str:
        return self.fontMetrics().elidedText(
            self._full, Qt.TextElideMode.ElideMiddle, self.contentsRect().width())

    def paintEvent(self, _ev) -> None:             # noqa: N802
        painter = QtGui.QPainter(self)
        group = (QtGui.QPalette.ColorGroup.Normal if self.isEnabled()
                 else QtGui.QPalette.ColorGroup.Disabled)
        painter.setPen(self.palette().color(group, QtGui.QPalette.ColorRole.WindowText))
        flags = (int(Qt.AlignmentFlag.AlignLeft.value) | int(Qt.AlignmentFlag.AlignVCenter.value)
                 | int(Qt.TextFlag.TextSingleLine.value))
        painter.drawText(self.contentsRect(), flags, self.elided_text())


def _wrapped(text: str = "", grey: bool = False) -> QtWidgets.QLabel:
    lab = QtWidgets.QLabel(text)
    lab.setWordWrap(True)
    lab.setSizePolicy(QtWidgets.QSizePolicy.Policy.Expanding,
                      QtWidgets.QSizePolicy.Policy.Minimum)
    lab.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
    if grey:
        pal = lab.palette()
        pal.setColor(QtGui.QPalette.ColorGroup.Normal, QtGui.QPalette.ColorRole.WindowText,
                     QtGui.QColor("gray"))
        lab.setPalette(pal)
    return lab


def _combo() -> QtWidgets.QComboBox:
    box = QtWidgets.QComboBox()
    box.setSizeAdjustPolicy(
        QtWidgets.QComboBox.SizeAdjustPolicy.AdjustToMinimumContentsLengthWithIcon)
    box.setMinimumContentsLength(12)
    box.setSizePolicy(QtWidgets.QSizePolicy.Policy.Expanding,
                      QtWidgets.QSizePolicy.Policy.Fixed)
    return box


class _Job(QtCore.QThread):
    """Run one callable off the GUI thread and hand back its value, or the exception it
    raised, as the single ``result`` payload. Never raises into Qt."""
    result = Signal(object)

    def __init__(self, fn: Callable[[], object], parent=None):
        super().__init__(parent)
        self._fn = fn

    def run(self) -> None:                         # noqa: D401 — Qt's name
        try:
            value = self._fn()
        except BaseException as exc:               # noqa: BLE001 — carried to the slot
            value = exc
        self.result.emit(value)


class LocalAgentWidget(QtWidgets.QGroupBox):
    """See the module docstring. Every outside effect is injectable:

    * ``context``  ``() -> AgentContext``      what the mesh is
    * ``prober``   ``() -> Probe``             what is installed (default: the real probe)
    * ``launcher`` ``(Plan) -> LaunchResult``  open the window (default: the real one)
    """

    def __init__(self, generator_dir: str,
                 context: "Optional[Callable[[], AgentContext]]" = None,
                 prober: "Optional[Callable[[], la.Probe]]" = None,
                 launcher: "Optional[Callable[[la.Plan], la.LaunchResult]]" = None,
                 parent=None):
        super().__init__(TITLE, parent)
        self.setObjectName("local_agent_card")
        self.generator_dir = generator_dir
        self._context = context or (lambda: AgentContext())
        self._prober = prober or la.probe
        self._launcher = launcher or la.launch
        self.probe: "Optional[la.Probe]" = None
        self.apps: "list[AppChoice]" = []
        self.apps_note = ""
        self.last_outcome: "Optional[Outcome]" = None
        self.copied_text = ""
        self._first_probe_done = False
        self._probe_job = None
        self._work_job = None

        lay = QtWidgets.QVBoxLayout(self)
        lay.addWidget(_wrapped(_INTRO, grey=True))

        form = QtWidgets.QFormLayout()
        form.setRowWrapPolicy(QtWidgets.QFormLayout.RowWrapPolicy.WrapLongRows)
        form.setFieldGrowthPolicy(QtWidgets.QFormLayout.FieldGrowthPolicy.AllNonFixedFieldsGrow)
        self.lane_box = _combo()
        self.lane_box.addItem("Docker mesh", la.LANE_DOCKER)
        self.lane_box.addItem("Kind cluster (Running DevOps)", la.LANE_KIND)
        self.lane_box.setToolTip("Which build this is. It only changes what the agent is "
                                 "told about rebuilding a service.")
        self.app_box = _combo()
        self.agent_box = _combo()
        for key, spec in la.AGENTS.items():
            self.agent_box.addItem(f"{spec['label']} ({key})", key)
        self.model_box = _combo()
        form.addRow("Lane:", self.lane_box)
        form.addRow("App:", self.app_box)
        form.addRow("Agent:", self.agent_box)
        form.addRow("Model:", self.model_box)
        lay.addLayout(form)
        self.folder_label = _Elided("")
        lay.addWidget(self.folder_label)

        self.status = _wrapped("")
        self.more = _wrapped("", grey=True)
        self.docs = _wrapped("", grey=True)
        lay.addWidget(self.status)
        lay.addWidget(self.more)
        lay.addWidget(self.docs)

        box, row = flow_box()
        self.start_btn = QtWidgets.QPushButton("Start local agent chat")
        self.copy_btn = QtWidgets.QPushButton("Copy command")
        self.recheck_btn = QtWidgets.QPushButton("Re-check")
        for b in (self.start_btn, self.copy_btn, self.recheck_btn):
            row.addWidget(b)
        lay.addWidget(box)
        self.copy_btn.setToolTip("Copies the lines that make the no-remote copy and start "
                                 "the agent, to run in a terminal of your own.")
        self.recheck_btn.setToolTip("Look again at Ollama, the models and the agent "
                                    "command. Read-only.")

        self.note = _wrapped("")
        self.note.setVisible(False)
        lay.addWidget(self.note)
        self.command_box = QtWidgets.QPlainTextEdit()
        self.command_box.setReadOnly(True)
        self.command_box.setLineWrapMode(QtWidgets.QPlainTextEdit.LineWrapMode.NoWrap)
        self.command_box.setVisible(False)
        self.command_box.setMaximumHeight(
            self.command_box.fontMetrics().lineSpacing() * 6 + 14)
        lay.addWidget(self.command_box)

        self.start_btn.clicked.connect(self._start)
        self.copy_btn.clicked.connect(self._copy)
        self.recheck_btn.clicked.connect(self.recheck)
        self.lane_box.currentIndexChanged.connect(lambda _i: self._sync())
        self.app_box.currentIndexChanged.connect(lambda _i: self._on_app_changed())
        self.agent_box.currentIndexChanged.connect(lambda _i: self._on_agent_changed())
        self.model_box.currentIndexChanged.connect(lambda _i: self._sync())
        self.refresh_apps()
        self._sync()

    def set_prober(self, prober: "Callable[[], la.Probe]") -> None:
        self._prober = prober

    def set_launcher(self, launcher: "Callable[[la.Plan], la.LaunchResult]") -> None:
        self._launcher = launcher

    # ── reading the page ─────────────────────────────────────────────────────────
    def ctx(self) -> AgentContext:
        try:
            return self._context()
        except Exception:                          # noqa: BLE001 — never break the page
            return AgentContext()

    def selection(self) -> "tuple[str, Optional[AppChoice], str, str]":
        lane = str(self.lane_box.currentData() or la.LANE_DOCKER)
        idx = self.app_box.currentIndex()
        app = self.apps[idx] if 0 <= idx < len(self.apps) else None
        return (lane, app, str(self.agent_box.currentData() or "claude"),
                str(self.model_box.currentData() or ""))

    def set_lane(self, lane: str) -> None:
        i = self.lane_box.findData(lane)
        if i >= 0:
            self.lane_box.setCurrentIndex(i)

    def refresh_apps(self) -> None:
        """Re-read the app list for the page's current source choice, keeping the
        selection when the app is still there."""
        ctx = self.ctx()
        keep = self.selection()[1]
        self.apps, self.apps_note = list_apps(self.generator_dir, ctx)
        self.app_box.blockSignals(True)
        self.app_box.clear()
        for a in self.apps:
            self.app_box.addItem(a.name if a.exists else f"{a.name} (not downloaded)", a.path)
        # Keep the person's pick; otherwise the first app whose folder exists, so a map
        # that lists every platform app does not open on one that is not downloaded.
        i = next((n for n, a in enumerate(self.apps) if keep and a.path == keep.path), -1)
        if i < 0:
            i = next((n for n, a in enumerate(self.apps) if a.exists), -1)
        if i >= 0:
            self.app_box.setCurrentIndex(i)
        self.app_box.blockSignals(False)
        self.app_box.setEnabled(bool(self.apps))
        if not self.apps:
            self.app_box.addItem("(no app folders yet)", "")
        if ctx.lane and self.lane_box.findData(ctx.lane) >= 0 and not self._first_probe_done:
            self.set_lane(ctx.lane)

    # ── probing ──────────────────────────────────────────────────────────────────
    def showEvent(self, event) -> None:            # noqa: N802
        super().showEvent(event)
        # The first look happens when the card is first SHOWN, never at import or
        # construction, so building the page stays instant and tests that never show it
        # never touch the machine.
        if not self._first_probe_done:
            self.recheck()
        else:
            self.refresh_apps()
            self._sync()

    def recheck(self) -> None:
        """Read the machine again, off the GUI thread. Read-only."""
        self._first_probe_done = True
        if probe_running(self, "_probe_job"):
            return
        self.refresh_apps()
        job = own_probe(self, "_probe_job", _Job(self._prober))
        job.result.connect(self._on_probe)
        job.finished.connect(self._sync)      # own_probe has released it by now
        job.start()
        self._sync()

    def _on_probe(self, value) -> None:
        if isinstance(value, BaseException):
            value = la.Probe(server_error=f"{type(value).__name__}: {value}")
        self.probe = value
        keep_agent = self.selection()[2]
        keep_model = self.selection()[3]
        agent, model = la.choose_defaults(self.probe, keep_agent, keep_model)
        self.agent_box.blockSignals(True)
        for n, key in enumerate(la.AGENTS):
            installed = bool(self.probe.agents.get(key))
            spec = la.AGENTS[key]
            self.agent_box.setItemText(
                n, f"{spec['label']} ({key})" + ("" if installed else " - not installed"))
        self.agent_box.setCurrentIndex(max(0, self.agent_box.findData(agent)))
        self.agent_box.blockSignals(False)
        self._fill_models(model)
        self._sync()

    def _fill_models(self, choose: str) -> None:
        self.model_box.blockSignals(True)
        self.model_box.clear()
        for m in (self.probe.local_models if self.probe else ()):
            self.model_box.addItem(m.name if m.tools else f"{m.name} (no tools)", m.name)
        if not self.model_box.count():
            self.model_box.addItem("(no model)", "")
        i = self.model_box.findData(choose) if choose else -1
        self.model_box.setCurrentIndex(i if i >= 0 else 0)
        self.model_box.blockSignals(False)

    def _on_agent_changed(self) -> None:
        self._sync()

    def _on_app_changed(self) -> None:
        self._sync()

    # ── the one place state becomes text and enabled-ness ────────────────────────
    @staticmethod
    def _cheap_source(app: "Optional[AppChoice]") -> "la.SourceInfo":
        """The checks that cost nothing (no git run on the GUI thread); the real
        inspection happens on the press, on the worker."""
        if app is None:
            return la.SourceInfo("", False, "No app folder is known yet: download the "
                                 "source, or point at your own source tree, first.")
        if not app.exists or not os.path.isdir(app.path):
            return la.SourceInfo(app.path, False,
                                 app.reason or f"{app.path} does not exist yet.")
        if not os.path.exists(os.path.join(app.path, ".git")):
            return la.SourceInfo(app.path, False,
                                 f"{app.path} is not a git repository, so it cannot be "
                                 "copied for an agent.")
        return la.SourceInfo(app.path, True)

    def problems(self) -> "list[la.Problem]":
        if self.probe is None:
            return []
        _lane, app, agent, model = self.selection()
        return la.diagnose(self.probe, agent, model, source=self._cheap_source(app))

    def _busy(self) -> bool:
        return probe_running(self, "_probe_job") or probe_running(self, "_work_job")

    def _sync(self) -> None:
        lane, app, agent, model = self.selection()
        self.folder_label.setText(f"Folder: {app.path}" if app else "Folder: (none)")
        self.docs.setVisible(False)
        self.more.setVisible(False)
        reason = ""
        if self.probe is None:
            self.status.setStyleSheet("")
            self.status.setText("Checking this machine…" if probe_running(self, "_probe_job")
                                else "Not checked yet. Press Re-check.")
            reason = "Still checking this machine."
        else:
            probs = self.problems()
            if probs:
                first = probs[0]
                self.status.setStyleSheet(f"color: {_RED};")
                self.status.setText(first.text())
                self.docs.setText(f"More: {first.doc}")
                self.docs.setVisible(True)
                if len(probs) > 1:
                    self.more.setText("Also: " + " ".join(p.what for p in probs[1:]))
                    self.more.setVisible(True)
                reason = first.what
            else:
                label = la.AGENTS[agent]["label"]
                self.status.setStyleSheet(f"color: {_GREEN};")
                self.status.setText(
                    f"Ready: {label} on {model}, working in a copy of "
                    f"{app.name if app else 'the app'}. Press Start.")
        if self.probe is not None and self.probe.host_note:
            self.more.setText((self.more.text() + " " if self.more.isVisible() else "")
                              + self.probe.host_note)
            self.more.setVisible(True)
        if self._busy() and not reason:
            reason = "Working…"
        self.start_btn.setEnabled(not reason)
        self.start_btn.setToolTip(reason or "Make a no-remote copy and open a terminal "
                                  "window running the agent there.")
        self.copy_btn.setEnabled(not probe_running(self, "_work_job"))
        self.recheck_btn.setEnabled(not probe_running(self, "_probe_job"))

    # ── Start ────────────────────────────────────────────────────────────────────
    def _prepare_plan(self) -> "la.Plan":
        lane, app, agent, model = self.selection()
        ctx = self.ctx()
        if app is None:
            raise la.ScratchError("No app folder is known yet.")
        return la.prepare(
            lane=lane, mesh=ctx.mesh, domains=list(ctx.domains),
            doors=list(ctx.doors.get(lane, ())), repo=app.name, source=app.path,
            source_root=os.path.dirname(app.path), source_mode=ctx.source_mode,
            generator_dir=self.generator_dir, pr=self.probe, agent=agent, model=model,
            kind_cluster=ctx.kind_cluster)

    def _start(self) -> None:
        if not self.start_btn.isEnabled() or self.probe is None:
            return
        self._show_note("Making the copy and opening a terminal…", _AMBER)
        self.command_box.setVisible(False)
        launcher = self._launcher

        def work() -> Outcome:
            try:
                plan = self._prepare_plan()
                la.write_brief(plan)
                clone = la.create_scratch(plan.scratch)
                return Outcome(plan, clone, launcher(plan))
            except (la.ScratchError, ValueError) as exc:
                return Outcome(error=str(exc))
            except Exception as exc:               # noqa: BLE001 — shown, never raised into Qt
                return Outcome(error=f"Unexpected {type(exc).__name__}: {exc}")

        job = own_probe(self, "_work_job", _Job(work))
        job.result.connect(self._on_started)
        job.finished.connect(self._sync)      # own_probe has released it by now
        job.start()
        self._sync()

    def _on_started(self, value) -> None:
        out = value if isinstance(value, Outcome) else Outcome(error=f"{value}")
        self.last_outcome = out
        self._sync()
        if out.error:
            self._show_note(out.error, _RED)
            return
        plan, res = out.plan, out.launch
        dirty = plan.scratch.source.dirty_files
        extra = (f" The real folder has {dirty} uncommitted change(s) that the copy does "
                 "not contain." if dirty else "")
        where = f" The copy is {out.clone.path}" + (" (the one from before)." if out.clone.reused
                                                    else ".")
        if res.opened:
            self._show_note(
                f"A terminal was opened with {res.terminal} (look for the window titled "
                f"“{plan.title}”).{where}{extra} If no window appeared, copy the lines below.",
                _GREEN)
            self.command_box.setPlainText(res.command)
            self.command_box.setVisible(True)
        else:
            self._show_note(f"No window was opened: {res.reason}.{where}{extra} Run the "
                            "lines below in a terminal instead.", _RED)
            self.command_box.setPlainText(res.command)
            self.command_box.setVisible(True)

    def _show_note(self, text: str, colour: str) -> None:
        self.note.setStyleSheet(f"color: {colour};")
        self.note.setText(text)
        self.note.setVisible(True)

    # ── Copy ─────────────────────────────────────────────────────────────────────
    def _copy(self) -> None:
        if self.probe is None:
            self._show_note("Still checking this machine; press Copy command again in a "
                            "moment.", _AMBER)
            return
        probs = self.problems()
        if probs:                                  # no plan is possible: copy what to do first
            self._copy_text("\n".join(p.text() for p in probs),
                            "Nothing can start yet, so what was copied is what to fix first.")
            return

        def work():
            try:
                plan = self._prepare_plan()
                la.write_brief(plan)
                return plan
            except (la.ScratchError, ValueError) as exc:
                return Outcome(error=str(exc))

        job = own_probe(self, "_work_job", _Job(work))
        job.result.connect(self._on_copy_plan)
        job.finished.connect(self._sync)      # own_probe has released it by now
        job.start()
        self._sync()

    def _on_copy_plan(self, value) -> None:
        self._sync()
        if isinstance(value, la.Plan):
            self.command_box.setPlainText(value.paste_text)
            self.command_box.setVisible(True)
            self._copy_text(value.paste_text,
                            "Copied the lines that make the no-remote copy and start the "
                            f"agent. The brief is saved at {value.scratch.brief_path}.")
        else:
            self._show_note(value.error if isinstance(value, Outcome) else str(value), _RED)

    def _copy_text(self, text: str, message: str) -> None:
        self.copied_text = text
        try:
            QtWidgets.QApplication.clipboard().setText(text)
            self._show_note(message, _GREEN)
        except Exception:                          # noqa: BLE001 — no clipboard (headless)
            self._show_note("There is no clipboard here; select the lines below and copy "
                            "them.", _AMBER)
        if not self.command_box.isVisible():
            self.command_box.setPlainText(text)
            self.command_box.setVisible(True)

    # ── tests and callers that must wait for the workers ─────────────────────────
    def wait_idle(self, timeout_s: float = 20.0) -> bool:
        """Process events until no worker is running. True when idle."""
        end = time.monotonic() + timeout_s
        while self._busy() and time.monotonic() < end:
            QtWidgets.QApplication.processEvents()
            QtCore.QThread.msleep(5)
        QtWidgets.QApplication.processEvents()
        return not self._busy()

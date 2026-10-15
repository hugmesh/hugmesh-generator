"""_e2e_evidence_dialog.py — BROWSE a BDD run's per-step evidence, per environment
and per interface.

WHAT IT SHOWS, AND WHY THAT IS NEW. The Studio's older screenshot browser listed
PNGs off the filesystem and had to label each one with HOW it had been guessed to
belong to a test, because per-STEP data did not exist. It exists now:
tests/e2e/steps/evidence.ts writes one artefact plus a JSON sidecar per Gherkin
step and indexes every one of them in manifest.json — carrying the ENVIRONMENT
(docker | kind | qemu) and the INTERFACE (browser | cli | studio) that step ran
on. Those two axes are the operator's actual question ("screenshots in docker,
local devops, and qemu ... through cli and gui"), so they are the two outermost
levels of the tree.

THE ARTEFACT IS INTERFACE-SHAPED, and the pane renders it that way rather than
pretending everything is a screenshot:
  * browser -> a PNG, shown as a picture;
  * cli     -> a TRANSCRIPT (argv, stdout, stderr, the REAL exit code), shown as
               text, because a terminal has no screen to shoot;
  * studio  -> a Qt WIDGET GRAB, shown as a picture.

*** A MANIFEST THAT LIES IS WORSE THAN NO MANIFEST. *** A reviewer counts the
rows and believes them. So the header carries core/e2e_evidence.verify()'s verdict
in BOTH directions — rows pointing at absent files, and files with no row — and a
row whose artefact is gone renders as a loud MISSING entry that stays in the tree.
Filtering it out would turn a broken run into a clean-looking one, which is the
single most expensive thing this surface could do.

HOUSE RULE, NOT OPTIONAL: NO QMessageBox AND NO .exec() ANYWHERE IN THIS FILE'S
PAGE LOGIC. A modal opened from validatePage or an itemChanged handler hangs
every headless test (feedback_no_modals_in_page_logic). Selection is wired to
itemSelectionChanged/itemClicked and every refusal — unreadable file, absent run,
schema mismatch — is an INLINE label. This dialog is itself opened by a BUTTON
CLICK, which is the one place exec() is legitimate; that call lives in the caller,
not here.

Qt lives ONLY in this module. The model is core/e2e_evidence.py, which is
stdlib-only, so `python -m hugmesh_studio --e2e-evidence` shows the same numbers
on a host with no display.
"""
from __future__ import annotations

import json
import os

from ..qt import Qt, QtGui, QtWidgets
from ...core import e2e_evidence
from ...core import e2e_environments

#: Roles on a tree item: the manifest row it stands for, if any.
_ROW_ROLE = int(Qt.ItemDataRole.UserRole) + 1

#: Rendered as pictures; everything else is rendered as text.
_PICTURE_KINDS = ("screenshot", "widget-grab", "transcript-render")


def _fmt_bytes(n) -> str:
    try:
        n = int(n)
    except (TypeError, ValueError):
        return "?"
    if n < 0:
        return "unstat-able"
    for unit in ("B", "KiB", "MiB"):
        if n < 1024 or unit == "MiB":
            return "%.0f %s" % (n, unit) if unit == "B" else "%.1f %s" % (n, unit)
        n /= 1024.0
    return "%d B" % n


class E2EEvidenceDialog(QtWidgets.QDialog):
    """Per-step evidence for one or more BDD runs, grouped env -> interface.

    Constructed with a REPORT dir (or a single run dir). Discovery is a plain
    directory walk done once in __init__ — no timer, no watcher: a run that
    finishes while this is open is picked up by Refresh, which is a button.
    """

    def __init__(self, parent=None, report_dir: str = "", generator_dir: str = ""):
        super().__init__(parent)
        self.setWindowTitle("e2e evidence — per step, per environment, per interface")
        self.resize(1180, 760)
        self._generator_dir = generator_dir or ""
        self._report_dir = report_dir or ""
        self._manifest: e2e_evidence.Manifest | None = None

        outer = QtWidgets.QVBoxLayout(self)

        # ── run picker + header ────────────────────────────────────────────
        top = QtWidgets.QHBoxLayout()
        top.addWidget(QtWidgets.QLabel("Run:"))
        self.run_combo = QtWidgets.QComboBox()
        self.run_combo.setMinimumWidth(420)
        self.run_combo.setToolTip(
            "Every evidence run found under this checkout's report dir "
            "(<report>/bdd-steps/<runId>/). Each carries its own manifest.json — "
            "the index tests/e2e/steps/evidence.ts writes, one row per artefact "
            "per Gherkin step.")
        top.addWidget(self.run_combo, 1)
        self.refresh_btn = QtWidgets.QPushButton("Refresh")
        self.refresh_btn.setToolTip("Re-scan for evidence runs and reload the "
                                    "selected one. Reads only; runs nothing.")
        top.addWidget(self.refresh_btn)
        outer.addLayout(top)

        # THE HONESTY LINE. Never a modal — an inline label that is always
        # present, so "nothing is wrong" and "we never checked" cannot look alike.
        self.header = QtWidgets.QLabel("")
        self.header.setWordWrap(True)
        self.header.setTextInteractionFlags(Qt.TextInteractionFlag.TextBrowserInteraction)
        outer.addWidget(self.header)

        self.problems = QtWidgets.QLabel("")
        self.problems.setWordWrap(True)
        self.problems.setStyleSheet("color:#b00020;")
        self.problems.setVisible(False)
        outer.addWidget(self.problems)

        # ── the tree + the preview ─────────────────────────────────────────
        split = QtWidgets.QSplitter(Qt.Orientation.Horizontal)
        self.tree = QtWidgets.QTreeWidget()
        self.tree.setHeaderLabels(["environment / interface / feature / scenario / step",
                                   "kind", "size"])
        self.tree.setColumnWidth(0, 620)
        self.tree.setUniformRowHeights(True)
        split.addWidget(self.tree)

        right = QtWidgets.QWidget()
        rlay = QtWidgets.QVBoxLayout(right)
        rlay.setContentsMargins(0, 0, 0, 0)
        self.preview_label = QtWidgets.QLabel("Select a step artefact on the left.")
        self.preview_label.setWordWrap(True)
        rlay.addWidget(self.preview_label)
        self.picture = QtWidgets.QLabel()
        self.picture.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.picture.setMinimumHeight(240)
        self.picture.setVisible(False)
        pic_scroll = QtWidgets.QScrollArea()
        pic_scroll.setWidgetResizable(True)
        pic_scroll.setWidget(self.picture)
        rlay.addWidget(pic_scroll, 3)
        self.text = QtWidgets.QPlainTextEdit()
        self.text.setReadOnly(True)          # evidence is a RECORD, never editable here
        self.text.setLineWrapMode(QtWidgets.QPlainTextEdit.LineWrapMode.NoWrap)
        rlay.addWidget(self.text, 2)
        split.addWidget(right)
        split.setStretchFactor(0, 3)
        split.setStretchFactor(1, 4)
        outer.addWidget(split, 1)

        # Close is a plain button, not a QMessageBox and not an accept() that
        # anything is waiting on.
        buttons = QtWidgets.QHBoxLayout()
        buttons.addStretch(1)
        self.close_btn = QtWidgets.QPushButton("Close")
        buttons.addWidget(self.close_btn)
        outer.addLayout(buttons)

        # SIGNALS. itemSelectionChanged / clicked only — never itemChanged, which
        # fires during programmatic population and would run this handler while
        # the tree is half-built.
        self.tree.itemSelectionChanged.connect(self._on_selection)
        self.tree.itemClicked.connect(lambda *_a: self._on_selection())
        self.run_combo.currentIndexChanged.connect(lambda *_a: self._load_selected())
        self.refresh_btn.clicked.connect(self.reload)
        self.close_btn.clicked.connect(self.reject)

        self.reload()

    # ── discovery + load ───────────────────────────────────────────────────

    def candidate_dirs(self) -> list[str]:
        """Every evidence run dir worth listing, most recent first.

        Looks in the report dir handed in, then at this checkout's two default
        report roots. A checkout with none is a NAMED empty state, not a silent
        blank tree.
        """
        roots: list[str] = []
        if self._report_dir:
            roots.append(self._report_dir)
        if self._generator_dir:
            roots.append(os.path.join(self._generator_dir, "tests", "e2e", "test-results"))
            roots.append(os.path.join(self._generator_dir, "test-results"))
        found: list[str] = []
        for root in roots:
            for d in e2e_evidence.run_dirs(root):
                if d not in found:
                    found.append(d)
        found.sort(key=lambda d: os.path.getmtime(d) if os.path.exists(d) else 0,
                   reverse=True)
        return found

    def reload(self):
        dirs = self.candidate_dirs()
        self.run_combo.blockSignals(True)
        self.run_combo.clear()
        for d in dirs:
            self.run_combo.addItem(os.path.basename(d) or d, d)
        self.run_combo.blockSignals(False)
        if not dirs:
            self.tree.clear()
            self._manifest = None
            self.header.setText(
                "No e2e evidence runs found. Per-step evidence is written under "
                "<code>${SNAP_REPORT_DIR:-test-results}/bdd-steps/&lt;runId&gt;/</code> "
                "by the Gherkin lane. Produce some with:<br>"
                "<code>make stack-e2e-bdd-env</code>&nbsp; (or "
                "<code>SNAP_ENV=kind make stack-e2e-bdd-env</code> / "
                "<code>SNAP_ENV=qemu …</code>) — the mesh must already be serving; "
                "this dialog starts nothing.")
            self.problems.setVisible(False)
            return
        self._load_selected()

    def _load_selected(self):
        idx = self.run_combo.currentIndex()
        if idx < 0:
            return
        run_dir = self.run_combo.itemData(idx)
        self._manifest = e2e_evidence.load(run_dir)
        rep = e2e_evidence.report(self._manifest)
        self._render_header(rep)
        self._populate(self._manifest)

    def _render_header(self, rep: dict):
        counts = rep["counts"]
        env_bits = ", ".join("%s %d" % (k, v) for k, v in counts["byEnv"].items()) or "none"
        if_bits = ", ".join("%s %d" % (k, v) for k, v in counts["byInterface"].items()) or "none"
        kind_bits = ", ".join("%s %d" % (k, v) for k, v in counts["byKind"].items()) or "none"
        verdict = rep["verification"]
        self.header.setText(
            "<b>%s</b> &nbsp; schema <code>%s</code> &nbsp; %d artefact(s), %d from "
            "FAILED steps<br>environments: %s &nbsp;|&nbsp; interfaces: %s"
            "<br>kinds: %s<br><b>index:</b> %s"
            % (rep["runId"] or "(unnamed run)", rep["schema"] or "&lt;none&gt;",
               counts["rows"], counts["failed"], env_bits, if_bits, kind_bits,
               verdict["summary"]))
        lines = list(rep["problems"])
        if not verdict["ok"]:
            for m in verdict["missing"][:20]:
                lines.append("row points at a MISSING file: %s" % m)
            for o in verdict["orphans"][:20]:
                lines.append("artefact on disk with NO manifest row: %s" % o)
            lines.extend(verdict["malformed"][:20])
        self.problems.setText("\n".join(lines))
        self.problems.setVisible(bool(lines))

    def _populate(self, man: e2e_evidence.Manifest):
        self.tree.clear()
        tree = e2e_evidence.group(man)
        legal_envs = set(e2e_environments.environment_ids())
        for env in sorted(tree):
            env_item = QtWidgets.QTreeWidgetItem([env, "", ""])
            if env not in legal_envs:
                # A row carrying an environment the catalogue does not know is a
                # defect worth SEEING, not a row to drop.
                env_item.setText(0, "%s   (NOT a catalogued environment)" % env)
            self.tree.addTopLevelItem(env_item)
            for iface in sorted(tree[env]):
                if_item = QtWidgets.QTreeWidgetItem([iface, "", ""])
                env_item.addChild(if_item)
                for feature in sorted(tree[env][iface]):
                    f_item = QtWidgets.QTreeWidgetItem([os.path.basename(feature), "", ""])
                    if_item.addChild(f_item)
                    for scenario in sorted(tree[env][iface][feature]):
                        s_item = QtWidgets.QTreeWidgetItem([scenario, "", ""])
                        f_item.addChild(s_item)
                        for row in tree[env][iface][feature][scenario]:
                            abs_path = e2e_evidence.artefact_path(man, row)
                            exists = bool(abs_path) and os.path.exists(abs_path)
                            label = e2e_evidence.row_label(row)
                            if not exists:
                                label += "   [MISSING ON DISK]"
                            a_item = QtWidgets.QTreeWidgetItem(
                                [label, str(row.get("kind") or "?"),
                                 _fmt_bytes(row.get("bytes"))])
                            if not exists or row.get("failed"):
                                a_item.setForeground(0, QtGui.QBrush(QtGui.QColor("#b00020")))
                            a_item.setData(0, _ROW_ROLE, json.dumps(row))
                            s_item.addChild(a_item)
            env_item.setExpanded(True)

    # ── preview ────────────────────────────────────────────────────────────

    def _on_selection(self):
        items = self.tree.selectedItems()
        if not items or self._manifest is None:
            return
        raw = items[0].data(0, _ROW_ROLE)
        if not raw:
            self.picture.setVisible(False)
            self.text.setPlainText("")
            self.preview_label.setText("Select a step artefact (a leaf row).")
            return
        row = json.loads(raw)
        self._show_row(row)

    def _show_row(self, row: dict):
        man = self._manifest
        abs_path = e2e_evidence.artefact_path(man, row)
        head = ("step %s — %s\n%s\nenv=%s interface=%s role=%s service=%s "
                "platform=%s layer=%s\n%s"
                % (row.get("ordinal"), row.get("kind"), row.get("step"),
                   row.get("env"), row.get("interface"), row.get("role"),
                   row.get("service"), row.get("platform"), row.get("layer"),
                   row.get("note") or ""))
        self.preview_label.setText(head)
        if not abs_path or not os.path.exists(abs_path):
            # INLINE, never a modal: this fires from a selection handler.
            self.picture.setVisible(False)
            self.text.setPlainText(
                "THE MANIFEST CLAIMS AN ARTEFACT THAT IS NOT ON DISK.\n\n"
                "  row path : %s\n  resolved : %s\n\n"
                "The index and the run tree disagree. Every row is supposed to "
                "point at a file that exists — that is checked in both directions "
                "by core/e2e_evidence.verify(), and the header above says so. "
                "Treat this run's counts as unreliable rather than trusting them."
                % (row.get("path"), abs_path or "<empty path>"))
            return
        if str(row.get("kind")) in _PICTURE_KINDS or abs_path.endswith(".png"):
            pix = QtGui.QPixmap(abs_path)
            if pix.isNull():
                self.picture.setVisible(False)
                self.text.setPlainText("%s exists (%s) but Qt could not decode it "
                                       "as an image." % (abs_path, _fmt_bytes(row.get("bytes"))))
                return
            self.picture.setPixmap(pix)
            self.picture.setVisible(True)
            self.text.setPlainText(abs_path)
            return
        self.picture.setVisible(False)
        try:
            with open(abs_path, encoding="utf-8", errors="replace") as fh:
                body = fh.read(400_000)
        except OSError as exc:
            body = "could not read %s: %s" % (abs_path, exc)
        if abs_path.endswith(".cli.json"):
            # Render the transcript the way a human reads one, exit code first —
            # the exit code is the cli interface's actual assertion surface.
            try:
                t = json.loads(body)
                body = ("$ %s\n# cwd  : %s\n# exit : %s\n# signal: %s\n"
                        "# spawnError: %s\n# duration: %sms\n\n"
                        "--- stdout ---\n%s\n--- stderr ---\n%s"
                        % (t.get("command"), t.get("cwd"), t.get("exitCode"),
                           t.get("signal"), t.get("spawnError"),
                           t.get("durationMs"), t.get("stdout"), t.get("stderr")))
            except ValueError:
                pass
        self.text.setPlainText(body)

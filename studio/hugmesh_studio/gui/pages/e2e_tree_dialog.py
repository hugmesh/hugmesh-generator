"""E2ETreeDialog — the e2e suite as a browsable TREE, replacing the one "Run e2e
suite" button on the Local-Docker-mesh page.

WHAT THIS REPLACES AND WHY. The page had a single button. It ran all 221 specs and
went one colour, so an operator who wanted to know WHICH feature broke, WHO the
failing persona was, what the run looked like, or what the suite even covers had
nothing to click. Worse, the button was honest only by accident: running everything
cannot lie about coverage. A tree CAN — and the three ways it can are what most of
this file is about:

  * a green Run button on a node that runs nothing (owncast, tube, wiki and
    character-studio have ZERO specs today). Those render as "NO COVERAGE" rows with
    NO checkbox at all, and a child node carrying the reason. A checkbox is the only
    thing that can put a spec into the run, so an uncovered row is structurally
    incapable of being run — not merely discouraged from it.
  * a grey row that will not say why it is grey. Every skipped test gets an explicit
    child node with its reason, and when the suite gave no machine-readable one (62
    of 259 results in the last run) the node says REASON UNKNOWN in those words
    rather than showing a bare "skipped" that reads as fine.
  * a screenshot browser implying a precision the repo does not have. tests/e2e/
    screenshots/ is flat, git-tracked, overwritten in place, and helpers.ts shot()
    records neither the step nor the persona. So every shot is labelled with HOW it
    was linked (Playwright attachment / filename prefix / not linked at all), and the
    pane says in as many words that per-STEP data does not exist yet.

MODEL / VIEW. Everything rendered here comes from core.e2e_catalogue — Qt-free, and
itself a parser of Playwright, the seeder and the spec sources rather than a
restatement of them. This file adds no parsing of its own and no second roster
reader: the persona table is core.seeded_credentials' roster, the same one
_credentials_dialog.py shows.

EDITING. The source pane is the first EDITABLE QPlainTextEdit in this codebase (the
other fifteen are read-only log panes), so it is deliberately conservative: it opens
one file at a time, Save writes only the file whose path is on screen, a file that
disappeared or changed under us is reported rather than clobbered, and anything under
.stack-src is opened READ-ONLY with the reason on screen — `make stack-clone` deletes
that tree, so a save there is thrown away silently.

NO MODALS IN THE LOGIC. Every refusal (nothing selected, save failed, a rejected
path) lands in an inline status label. exec() is never called from here; the caller
show()s this dialog and connects ``accepted``, so a headless test can drive the whole
chain without anything waiting on a human.
"""
from __future__ import annotations

import os

from ..qt import Qt, QtGui, QtWidgets
from ...core import e2e_catalogue as ec
from ...core.seeded_credentials import Roster

# Group headers, in tree order. Gherkin sits FIRST because the operator asked for it
# by name; the specs follow; the two "what this suite does not do" groups are last so
# they read as the tail of the story rather than as noise between features.
GROUP_GHERKIN = "Gherkin features (.feature)"
GROUP_SPECS = "Playwright specs"
GROUP_UNCOVERED = "Services with NO e2e coverage"
GROUP_UNREACHABLE = "Services this suite cannot reach"
GROUP_ORPHAN_SHOTS = "Screenshots linked to no spec"

# Node kinds — what the detail panes switch on.
NODE_GROUP = "group"
NODE_FEATURE = "feature"          # a spec FILE: the only checkable, runnable node
NODE_TEST = "test"
NODE_REASON = "reason"
NODE_GHERKIN = "gherkin"
NODE_SCENARIO = "scenario"
NODE_SERVICE = "service"
NODE_SHOTS = "shots"

#: Prefix on a skipped test's reason node when the suite gave no reason. The WORDS
#: matter: a bare "skipped" reads as "fine", and 62 of the last run's 259 results
#: were exactly that.
UNKNOWN_SKIP_PREFIX = "skipped, REASON UNKNOWN — "
KNOWN_SKIP_PREFIX = "skipped — "

#: The standing truth about the screenshot directory. Shown on the Screenshots tab in
#: every state, because the alternative is a browser that IMPLIES per-step capture.
SHOT_LIMIT_NOTE = (
    "Per-STEP screenshot data does not exist in this suite. tests/e2e/screenshots/ is "
    "flat, git-tracked and OVERWRITTEN IN PLACE every run, and helpers.ts shot() "
    "records neither the step nor the persona — so a shot cannot be placed under the "
    "step it was taken at. Each row below says how it was linked: an attachment "
    "Playwright tied to that exact test result, a filename NN- prefix that only "
    "matches the spec file, or no link at all.")

_LINKAGE_LABEL = {
    ec.LINK_TEST: "attached by Playwright to THIS test result (failures only)",
    ec.LINK_FILENAME_PREFIX: "matched by filename NN- prefix to the spec FILE only",
    ec.LINK_NONE: "not linked to any spec — its filename carries no NN- prefix",
}

_STATUS_MARK = {
    ec.STATUS_PASSED: "PASS",
    ec.STATUS_FAILED: "FAIL",
    ec.STATUS_SKIPPED: "SKIP",
    ec.STATUS_NOT_RUN: "not run",
}

_PERSONA_COLS = ("Username", "Password", "Opens", "Roles", "Seeder note")


class E2ETreeDialog(QtWidgets.QDialog):
    """Browse the e2e suite; check features; press Run.

    Read :attr:`run_specs` after ``accepted`` fires — the tuple of Playwright
    positional filters (``specs/NN-x.spec.ts``) the operator selected, already
    validated by :func:`core.e2e_catalogue.safe_spec_args`. Empty is impossible: Run
    refuses an empty selection inline instead of accepting.

    ``blockers`` is the live gate from LocalStackNode.e2e_ready() — the same list the
    page's button tooltip carries. Non-empty disables Run and NAMES every blocker,
    while the whole tree stays browsable: reading the catalogue needs no stack.
    """

    def __init__(self, catalogue: ec.Catalogue, generator_dir: str,
                 blockers=(), parent=None):
        super().__init__(parent)
        self.cat = catalogue
        self.generator_dir = generator_dir
        self.blockers = list(blockers or [])
        self.run_specs: tuple[str, ...] = ()

        self.setWindowTitle("e2e features — browse, edit, run")
        self.resize(1180, 780)

        #: payload dicts, indexed by the integer each item carries in UserRole.
        self._nodes: list[dict] = []
        #: spec-file nodes, the only checkable ones: {spec_file: item}
        self.feature_items: dict[str, QtWidgets.QTreeWidgetItem] = {}
        self._group_items: dict[str, QtWidgets.QTreeWidgetItem] = {}
        #: the file currently in the editor, and the bytes it held when loaded.
        self._open_path = ""
        self._open_text = ""
        self._open_readonly = True

        root = QtWidgets.QVBoxLayout(self)
        root.addWidget(self._header())
        problems = self._problems_box()
        if problems is not None:
            root.addWidget(problems)

        split = QtWidgets.QSplitter(Qt.Orientation.Horizontal, self)
        split.addWidget(self._left_pane())
        split.addWidget(self._right_pane())
        split.setStretchFactor(0, 3)
        split.setStretchFactor(1, 4)
        root.addWidget(split, 1)

        self.status = QtWidgets.QLabel("")
        self.status.setWordWrap(True)
        self.status.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse)
        root.addWidget(self.status)
        root.addWidget(self._buttons())

        self._build_tree()
        self._sync_run_button()
        self.tree.currentItemChanged.connect(self._on_current_changed)

    # ── header + problems ────────────────────────────────────────────────────────
    def _header(self) -> QtWidgets.QLabel:
        n_specs = sum(1 for f in self.cat.features)
        n_tests = len(self.cat.tests)
        run = self.cat.run
        if run.summary is not None:
            s = run.summary
            # TWO COUNTS THAT DO NOT AGREE. summary.json counts RESULTS — the
            # reporter counts in onTestEnd(test, result), once per ATTEMPT, and
            # playwright.config.ts sets `retries: 1` — while this tree renders one
            # row per TEST. On the 2026-08-22 run that is 76 failed RESULTS over 38
            # red ROWS. Rendering the reporter's number over this tree's rows is the
            # disagreement in front of the operator that core.e2e_catalogue named
            # its fields (`failed_results`) to stop, so the banner leads with the
            # per-TEST half and states the retry gap instead of hiding it.
            c = run.counts()
            gap = run.retried_results
            verdict = (f"last run: <b>{c[ec.STATUS_PASSED]} passed, "
                       f"{c[ec.STATUS_FAILED]} failed, "
                       f"{c[ec.STATUS_SKIPPED]} skipped</b> (per test)"
                       + (f"; the reporter counted {s.total_results} result(s), "
                          f"{gap} of them retries" if gap else "")
                       + (f" (tier {s.tier})" if s.tier else "")
                       + (f" — {s.finished_at}" if s.finished_at else ""))
        elif run.directory:
            verdict = (f"last run: {len(run.tests)} result(s) from "
                       f"{os.path.basename(run.directory)} (no summary.json — the "
                       f"custom reporter did not finish)")
        else:
            verdict = ("<b>no run found</b> — every row below is 'not run'; the tree "
                       "is the SUITE, not a verdict")
        lab = QtWidgets.QLabel(
            f"{n_specs} spec file(s), {n_tests} test(s); {verdict}."
            f"<br>Check the features to run and press <b>Run selected</b>. "
            f"Only checked spec files are run — nothing else is.")
        lab.setWordWrap(True)
        lab.setTextFormat(Qt.TextFormat.RichText)
        return lab

    def _problems_box(self):
        """Everything the catalogue could NOT determine, on screen and not in a log.

        A tree that renders its own blind spots as absence is the failure mode this
        whole unit exists to avoid, so this box is not collapsible and not optional.
        """
        if not self.cat.problems:
            return None
        box = QtWidgets.QGroupBox("What this tree cannot tell you", self)
        v = QtWidgets.QVBoxLayout(box)
        lab = QtWidgets.QLabel("\n".join(f"• {p}" for p in self.cat.problems))
        lab.setWordWrap(True)
        lab.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        self.problems_label = lab
        v.addWidget(lab)
        return box

    # ── left: filter + tree ──────────────────────────────────────────────────────
    def _left_pane(self) -> QtWidgets.QWidget:
        w = QtWidgets.QWidget(self)
        v = QtWidgets.QVBoxLayout(w)
        v.setContentsMargins(0, 0, 0, 0)

        self.filter_edit = QtWidgets.QLineEdit()
        self.filter_edit.setPlaceholderText(
            "Filter by file, test title, persona or service…")
        self.filter_edit.textChanged.connect(self._apply_filter)
        v.addWidget(self.filter_edit)

        self.tree = QtWidgets.QTreeWidget()
        self.tree.setHeaderLabels(["Feature / test", "Last result"])
        self.tree.setColumnWidth(0, 420)
        v.addWidget(self.tree, 1)

        row = QtWidgets.QHBoxLayout()
        self.check_all_btn = QtWidgets.QPushButton("Check all specs")
        self.check_all_btn.clicked.connect(lambda: self._set_all_checked(True))
        self.clear_btn = QtWidgets.QPushButton("Clear")
        self.clear_btn.clicked.connect(lambda: self._set_all_checked(False))
        self.check_failed_btn = QtWidgets.QPushButton("Check last run's failures")
        self.check_failed_btn.setToolTip(
            "Check every spec file that had at least one FAILED test in the last "
            "run. Disabled when there is no run to read.")
        self.check_failed_btn.clicked.connect(self._check_failed)
        row.addWidget(self.check_all_btn)
        row.addWidget(self.check_failed_btn)
        row.addWidget(self.clear_btn)
        row.addStretch(1)
        v.addLayout(row)
        return w

    # ── right: the three detail panes ────────────────────────────────────────────
    def _right_pane(self) -> QtWidgets.QWidget:
        self.tabs = QtWidgets.QTabWidget(self)
        self.tabs.addTab(self._source_tab(), "Gherkin / spec source")
        self.tabs.addTab(self._shots_tab(), "Screenshots")
        self.tabs.addTab(self._personas_tab(), "Users this draws from")
        return self.tabs

    def _source_tab(self) -> QtWidgets.QWidget:
        w = QtWidgets.QWidget(self)
        v = QtWidgets.QVBoxLayout(w)
        self.source_path = QtWidgets.QLabel("Select a feature or spec to view its source.")
        self.source_path.setWordWrap(True)
        self.source_path.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse)
        v.addWidget(self.source_path)

        self.source_edit = QtWidgets.QPlainTextEdit()
        self.source_edit.setReadOnly(True)
        self.source_edit.setLineWrapMode(
            QtWidgets.QPlainTextEdit.LineWrapMode.NoWrap)
        f = QtGui.QFontDatabase.systemFont(QtGui.QFontDatabase.SystemFont.FixedFont)
        self.source_edit.setFont(f)
        v.addWidget(self.source_edit, 1)

        row = QtWidgets.QHBoxLayout()
        self.save_btn = QtWidgets.QPushButton("Save")
        self.save_btn.setEnabled(False)
        self.save_btn.clicked.connect(self._save_source)
        self.reload_btn = QtWidgets.QPushButton("Reload from disk")
        self.reload_btn.setEnabled(False)
        self.reload_btn.clicked.connect(self._reload_source)
        row.addWidget(self.save_btn)
        row.addWidget(self.reload_btn)
        row.addStretch(1)
        v.addLayout(row)

        self.source_status = QtWidgets.QLabel("")
        self.source_status.setWordWrap(True)
        v.addWidget(self.source_status)
        return w

    def _shots_tab(self) -> QtWidgets.QWidget:
        w = QtWidgets.QWidget(self)
        v = QtWidgets.QVBoxLayout(w)
        note = QtWidgets.QLabel(SHOT_LIMIT_NOTE)
        note.setWordWrap(True)
        self.shot_note = note
        v.addWidget(note)
        self.shot_list = QtWidgets.QListWidget()
        self.shot_list.currentRowChanged.connect(self._show_shot)
        v.addWidget(self.shot_list, 1)
        self.shot_preview = QtWidgets.QLabel("")
        self.shot_preview.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.shot_preview.setMinimumHeight(220)
        v.addWidget(self.shot_preview, 2)
        self.shot_status = QtWidgets.QLabel("")
        self.shot_status.setWordWrap(True)
        v.addWidget(self.shot_status)
        self._shots: list[ec.Screenshot] = []
        return w

    def _personas_tab(self) -> QtWidgets.QWidget:
        w = QtWidgets.QWidget(self)
        v = QtWidgets.QVBoxLayout(w)
        self.persona_head = QtWidgets.QLabel("")
        self.persona_head.setWordWrap(True)
        self.persona_head.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse)
        v.addWidget(self.persona_head)

        self.persona_only = QtWidgets.QCheckBox(
            "Show only the personas the selected feature names")
        self.persona_only.toggled.connect(lambda _on: self._sync_persona_rows())
        v.addWidget(self.persona_only)

        roster: Roster = self.cat.roster
        if roster.error:
            warn = QtWidgets.QLabel(
                f"Could not read the seeded roster — the persona column is EMPTY "
                f"because the roster could not be parsed, not because these features "
                f"use no accounts.\n\n{roster.error}\n\nLooked in: {roster.source}")
            warn.setWordWrap(True)
            v.addWidget(warn)
            self.persona_table = None
            return w

        gated = {g.username: g.reason for g in self.cat.gated}
        self.persona_table = QtWidgets.QTableWidget(
            len(roster.users), len(_PERSONA_COLS), w)
        self.persona_table.setHorizontalHeaderLabels(list(_PERSONA_COLS))
        self.persona_table.verticalHeader().setVisible(False)
        self.persona_table.setEditTriggers(
            QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
        self.persona_table.setSelectionBehavior(
            QtWidgets.QAbstractItemView.SelectionBehavior.SelectRows)
        self._persona_rows: dict[str, int] = {}
        for r, u in enumerate(roster.users):
            self._persona_rows[u.username] = r
            note = gated.get(u.username, "")
            for c, text in enumerate((u.username, u.password, u.apps_display,
                                      u.roles_display, note)):
                item = QtWidgets.QTableWidgetItem(text)
                if note:
                    item.setToolTip(note)
                self.persona_table.setItem(r, c, item)
        hh = self.persona_table.horizontalHeader()
        for c in (0, 1, 2):
            hh.setSectionResizeMode(
                c, QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        hh.setSectionResizeMode(3, QtWidgets.QHeaderView.ResizeMode.Stretch)
        v.addWidget(self.persona_table, 1)

        foot = QtWidgets.QLabel(
            "These are deterministic THROWAWAY credentials for the local test stack. "
            "\"Seeder note\" is filled for personas seed-e2e.sh leaves un-onboarded ON "
            "PURPOSE — specs 17/28/29 assert that gated state, so completing their "
            "registration makes those specs pass vacuously.\n"
            "The per-feature persona list is a TEXTUAL reference: it is every roster "
            "handle the spec's source names (comments stripped). A spec that builds a "
            "handle at runtime is not counted, so this under-reports rather than "
            "inventing.")
        foot.setWordWrap(True)
        v.addWidget(foot)
        return w

    def _buttons(self) -> QtWidgets.QWidget:
        box = QtWidgets.QWidget(self)
        h = QtWidgets.QHBoxLayout(box)
        h.setContentsMargins(0, 0, 0, 0)
        self.run_btn = QtWidgets.QPushButton("Run selected", box)
        self.run_btn.clicked.connect(self._on_run)
        h.addWidget(self.run_btn)
        h.addStretch(1)
        close = QtWidgets.QPushButton("Close", box)
        close.clicked.connect(self.reject)
        h.addWidget(close)
        return box

    # ── tree construction ────────────────────────────────────────────────────────
    def _payload(self, item: QtWidgets.QTreeWidgetItem, data: dict) -> None:
        """Attach a payload to an item by INDEX. Storing the dict itself in a
        QVariant round-trips differently across the two Qt bindings; an int does not."""
        self._nodes.append(data)
        item.setData(0, Qt.ItemDataRole.UserRole, len(self._nodes) - 1)

    def node_of(self, item) -> dict:
        if item is None:
            return {}
        i = item.data(0, Qt.ItemDataRole.UserRole)
        if isinstance(i, int) and 0 <= i < len(self._nodes):
            return self._nodes[i]
        return {}

    def _group(self, title: str) -> QtWidgets.QTreeWidgetItem:
        it = QtWidgets.QTreeWidgetItem(self.tree, [title, ""])
        it.setFlags(Qt.ItemFlag.ItemIsEnabled)
        f = it.font(0)
        f.setBold(True)
        it.setFont(0, f)
        self._payload(it, {"kind": NODE_GROUP, "title": title})
        self._group_items[title] = it
        return it

    def _plain_child(self, parent, text: str, kind: str = NODE_REASON,
                     data: dict | None = None) -> QtWidgets.QTreeWidgetItem:
        """A non-checkable, non-runnable explanation row."""
        it = QtWidgets.QTreeWidgetItem(parent, [text, ""])
        it.setFlags(Qt.ItemFlag.ItemIsEnabled | Qt.ItemFlag.ItemIsSelectable)
        it.setToolTip(0, text)
        payload = {"kind": kind, "text": text}
        payload.update(data or {})
        self._payload(it, payload)
        return it

    def _build_tree(self) -> None:
        self.tree.blockSignals(True)
        self._add_gherkin_group()
        self._add_spec_group()
        self._add_service_groups()
        self._add_orphan_shot_group()
        for it in self._group_items.values():
            it.setExpanded(True)
        self.tree.blockSignals(False)
        self.tree.itemChanged.connect(self._on_item_changed)

    def _add_gherkin_group(self) -> None:
        g = self._group(GROUP_GHERKIN)
        idx = self.cat.gherkin
        if not idx.features:
            # NAMED absence. "no .feature nodes" and "the harness is not on this
            # branch yet" are different facts and only one of them is true here.
            self._plain_child(g, idx.error or ec.GHERKIN_ABSENT_REASON)
            return
        for feat in idx.features:
            label = f"{os.path.basename(feat.rel)} — {feat.title}"
            it = QtWidgets.QTreeWidgetItem(g, [label, ""])
            it.setFlags(Qt.ItemFlag.ItemIsEnabled | Qt.ItemFlag.ItemIsSelectable)
            it.setToolTip(0, feat.rel)
            self._payload(it, {"kind": NODE_GHERKIN, "path": feat.path,
                               "rel": feat.rel, "search": label.lower()})
            if feat.error:
                self._plain_child(it, feat.error)
                continue
            if feat.tags:
                self._plain_child(it, "tags: " + " ".join(feat.tags))
            for sc in feat.scenarios:
                s = QtWidgets.QTreeWidgetItem(
                    it, [f"{sc.keyword}: {sc.name}", " ".join(sc.tags)])
                s.setFlags(Qt.ItemFlag.ItemIsEnabled | Qt.ItemFlag.ItemIsSelectable)
                self._payload(s, {"kind": NODE_SCENARIO, "path": feat.path,
                                  "rel": feat.rel, "line": sc.line,
                                  "search": sc.name.lower()})
            # A .feature is not itself a Playwright spec path, so it gets NO
            # checkbox: playwright-bdd GENERATES the spec that runs it, and offering
            # to "run" the .feature would be offering to run a file the runner has
            # never heard of.
            self._plain_child(
                it, "not runnable directly: playwright-bdd generates the spec that "
                    "executes this feature — check that generated spec below to run it.")

    def _add_spec_group(self) -> None:
        g = self._group(GROUP_SPECS)
        if not self.cat.features:
            self._plain_child(
                g, self.cat.listing.error
                or "no spec files were enumerated (see the box above).")
            return
        for feat in self.cat.features:
            counts = feat.counts()
            bits = [f"{counts[k]} {k}" for k in
                    (ec.STATUS_PASSED, ec.STATUS_FAILED, ec.STATUS_SKIPPED,
                     ec.STATUS_NOT_RUN) if counts.get(k)]
            summary = ", ".join(bits) or "no tests"
            if feat.unexplained_skips:
                summary += f" ({feat.unexplained_skips} skip(s) with NO reason)"
            it = QtWidgets.QTreeWidgetItem(g, [feat.file, summary])
            it.setFlags(Qt.ItemFlag.ItemIsUserCheckable | Qt.ItemFlag.ItemIsEnabled
                        | Qt.ItemFlag.ItemIsSelectable)
            it.setCheckState(0, Qt.CheckState.Unchecked)
            personas = self.cat.personas_of(feat.file)
            path = ec.spec_path(self.generator_dir, feat.file)
            self._payload(it, {"kind": NODE_FEATURE, "spec_file": feat.file,
                               "path": path, "rel": os.path.relpath(
                                   path, self.generator_dir),
                               "personas": personas,
                               "shots": list(feat.screenshots),
                               "failed": counts.get(ec.STATUS_FAILED, 0),
                               "search": " ".join(
                                   [feat.file, *personas]).lower()})
            it.setToolTip(0, f"{path}\npersonas named: "
                             + (", ".join(personas) or "none found in this spec's source"))
            self.feature_items[feat.file] = it
            for t in feat.tests:
                self._add_test(it, feat, t)

    def _add_test(self, parent, feat: ec.Feature, t: ec.E2ETest) -> None:
        it = QtWidgets.QTreeWidgetItem(
            parent, [t.title or " ▸ ".join(t.title_path),
                     _STATUS_MARK.get(t.status, t.status)])
        it.setFlags(Qt.ItemFlag.ItemIsEnabled | Qt.ItemFlag.ItemIsSelectable)
        self._payload(it, {"kind": NODE_TEST, "spec_file": feat.file,
                           "path": ec.spec_path(self.generator_dir, feat.file),
                           "line": t.line,
                           "personas": self.cat.personas_of(feat.file),
                           "shots": list(t.screenshots),
                           "search": " ".join(t.title_path).lower()})
        detail = []
        if t.role != ec.UNKNOWN_TAG or t.layer != ec.UNKNOWN_TAG:
            detail.append(f"role: {t.role} · layer: {t.layer}")
        if t.duration_ms:
            detail.append(f"{t.duration_ms} ms")
        if detail:
            self._plain_child(it, " · ".join(detail))
        if t.status == ec.STATUS_SKIPPED:
            # THE grey-row rule: a skip always gets a node, and that node always
            # carries a reason — the stand-in included, spelled out as unknown.
            reason = t.skip_reason or ec.UNKNOWN_SKIP_REASON
            prefix = KNOWN_SKIP_PREFIX if t.skip_reason_known else UNKNOWN_SKIP_PREFIX
            self._plain_child(it, prefix + reason)
        elif t.status == ec.STATUS_NOT_RUN:
            self._plain_child(
                it, "not run — this test exists in the suite but the last run "
                    "produced no result for it (it was not selected, or there is "
                    "no run to read).")

    def _add_service_groups(self) -> None:
        uncovered = [c for c in self.cat.services if c.needs_a_test]
        unreachable = [c for c in self.cat.services if not c.reachable]
        g = self._group(GROUP_UNCOVERED)
        if not uncovered:
            self._plain_child(g, "every reachable service is named by at least one spec.")
        for c in uncovered:
            # NO checkbox, ever. The checkbox is what puts a file into the run, so an
            # uncovered service cannot be run by construction — not by convention.
            it = QtWidgets.QTreeWidgetItem(
                g, [f"{c.slug} — NO COVERAGE", "nothing to run"])
            it.setFlags(Qt.ItemFlag.ItemIsEnabled | Qt.ItemFlag.ItemIsSelectable)
            self._payload(it, {"kind": NODE_SERVICE, "slug": c.slug,
                               "reason": c.reason or ec.UNCOVERED_REASON,
                               "search": c.slug.lower()})
            self._plain_child(it, c.reason or ec.UNCOVERED_REASON)
            for line in ec.lane_door_lines(self.generator_dir, c.slug):
                self._plain_child(it, line)
        g2 = self._group(GROUP_UNREACHABLE)
        if not unreachable:
            self._plain_child(g2, "every catalogued service runs on a lane this suite drives.")
        for c in unreachable:
            it = QtWidgets.QTreeWidgetItem(
                g2, [f"{c.slug} — not reachable", "nothing to run"])
            it.setFlags(Qt.ItemFlag.ItemIsEnabled | Qt.ItemFlag.ItemIsSelectable)
            self._payload(it, {"kind": NODE_SERVICE, "slug": c.slug,
                               "reason": c.reason or ec.UNREACHABLE_REASON,
                               "search": c.slug.lower()})
            self._plain_child(it, c.reason or ec.UNREACHABLE_REASON)
            for line in ec.lane_door_lines(self.generator_dir, c.slug):
                self._plain_child(it, line)

    def _add_orphan_shot_group(self) -> None:
        shots = list(self.cat.orphan_screenshots)
        g = self._group(GROUP_ORPHAN_SHOTS)
        if not shots:
            self._plain_child(g, "every screenshot's NN- prefix matches a spec file.")
            return
        it = QtWidgets.QTreeWidgetItem(
            g, [f"{len(shots)} screenshot(s) with no matching spec", ""])
        it.setFlags(Qt.ItemFlag.ItemIsEnabled | Qt.ItemFlag.ItemIsSelectable)
        self._payload(it, {"kind": NODE_SHOTS, "shots": shots,
                           "search": "screenshots"})

    # ── selection ────────────────────────────────────────────────────────────────
    def _set_all_checked(self, on: bool) -> None:
        self.tree.blockSignals(True)
        for it in self.feature_items.values():
            it.setCheckState(0, Qt.CheckState.Checked if on
                             else Qt.CheckState.Unchecked)
        self.tree.blockSignals(False)
        self._sync_run_button()

    def _check_failed(self) -> None:
        self.tree.blockSignals(True)
        hits = 0
        for file, it in self.feature_items.items():
            failed = bool(self.node_of(it).get("failed"))
            it.setCheckState(0, Qt.CheckState.Checked if failed
                             else Qt.CheckState.Unchecked)
            hits += bool(failed)
        self.tree.blockSignals(False)
        self._sync_run_button()
        if not hits:
            self.status.setText(
                "No spec file had a FAILED test in the last run"
                + (" — and there is no run to read." if not self.cat.run.directory
                   else ". Nothing was checked."))

    def checked_spec_files(self) -> list[str]:
        """The spec FILES the operator ticked, in tree order."""
        return [f for f, it in self.feature_items.items()
                if it.checkState(0) == Qt.CheckState.Checked]

    def selected_specs(self) -> tuple[tuple[str, ...], tuple[str, ...]]:
        """``(accepted, rejected)`` Playwright positional filters for the selection."""
        return ec.safe_spec_args(self.checked_spec_files())

    def _on_item_changed(self, item, _col) -> None:
        # itemChanged fires on a CHECKBOX click. HOUSE RULE: nothing modal may run
        # from here — a QMessageBox in this handler hangs every headless test. The
        # only effect is re-arming the Run button and writing an inline count.
        self._sync_run_button()

    def _sync_run_button(self) -> None:
        n = len(self.checked_spec_files())
        if self.blockers:
            self.run_btn.setEnabled(False)
            self.run_btn.setToolTip("Disabled:\n- " + "\n- ".join(self.blockers))
            return
        self.run_btn.setEnabled(n > 0)
        self.run_btn.setToolTip(
            f"Run the {n} checked spec file(s) against the running local mesh. "
            "Output streams into the page's log."
            if n else "Check at least one spec file first — Run never runs "
                      "the whole suite behind your back.")
        self.run_btn.setText(f"Run selected ({n})" if n else "Run selected")

    def _on_run(self) -> None:
        """Compile the selection and accept. INLINE refusals only — no modal."""
        if self.blockers:
            self.status.setText("Cannot run: " + "; ".join(self.blockers))
            return
        accepted, rejected = self.selected_specs()
        if rejected:
            # Refuse the WHOLE run rather than quietly running the half that parsed:
            # a partial run reported as the selection is the vacuity this unit exists
            # to prevent.
            self.status.setText(
                f"Refusing to run: {len(rejected)} selected path(s) are "
                f"{ec.SPEC_ARG_REJECT_REASON} — " + ", ".join(rejected))
            return
        if not accepted:
            self.status.setText(
                "Nothing is checked. Tick the spec files you want to run — "
                "\"Run selected\" never falls back to running everything.")
            return
        self.run_specs = accepted
        self.accept()

    # ── detail panes ─────────────────────────────────────────────────────────────
    def _on_current_changed(self, item, _prev) -> None:
        node = self.node_of(item)
        self._load_source(node)
        self._load_shots(node, item)
        self._load_personas(node)

    # -- source --
    def _load_source(self, node: dict) -> None:
        path = node.get("path") or ""
        if not path:
            self._open_path = ""
            self.source_edit.setPlainText("")
            self.source_edit.setReadOnly(True)
            self.save_btn.setEnabled(False)
            self.reload_btn.setEnabled(False)
            self.source_path.setText(
                "This node has no source file — select a Gherkin feature, a spec "
                "file or a test.")
            self.source_status.setText("")
            return
        self._open_path = path
        readonly = ec.is_readonly_source(path)
        self._open_readonly = readonly
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except OSError as e:
            self._open_text = ""
            self.source_edit.setPlainText("")
            self.source_edit.setReadOnly(True)
            self.save_btn.setEnabled(False)
            self.reload_btn.setEnabled(True)
            self.source_path.setText(path)
            self.source_status.setText(f"Could not read this file: {e}")
            return
        self._open_text = text
        self.source_edit.setPlainText(text)
        self.source_edit.setReadOnly(readonly)
        self.save_btn.setEnabled(not readonly)
        self.reload_btn.setEnabled(True)
        rel = node.get("rel") or os.path.relpath(path, self.generator_dir)
        self.source_path.setText(
            f"{rel}   [READ-ONLY]" if readonly else f"{rel}   (editable — Save writes this file)")
        self.source_status.setText(
            ec.READONLY_STACK_SRC_REASON if readonly else "")
        line = node.get("line") or 0
        if line:
            cur = self.source_edit.textCursor()
            cur.movePosition(QtGui.QTextCursor.MoveOperation.Start)
            cur.movePosition(QtGui.QTextCursor.MoveOperation.Down,
                             QtGui.QTextCursor.MoveMode.MoveAnchor, max(0, line - 1))
            self.source_edit.setTextCursor(cur)
            self.source_edit.centerCursor()

    def _reload_source(self) -> None:
        if not self._open_path:
            return
        try:
            with open(self._open_path, encoding="utf-8") as fh:
                text = fh.read()
        except OSError as e:
            self.source_status.setText(f"Could not re-read this file: {e}")
            return
        self._open_text = text
        self.source_edit.setPlainText(text)
        self.source_status.setText("Reloaded from disk; unsaved edits were discarded.")

    def _save_source(self) -> None:
        """Write the editor back to the file whose path is on screen.

        Refusals are inline text, never a dialog. The .stack-src guard is checked
        AGAIN here and not only at load: the read-only flag on the widget is a UI
        affordance, and a guard that lives only in the affordance is one keystroke
        from being bypassed.
        """
        path = self._open_path
        if not path:
            self.source_status.setText("Nothing is open to save.")
            return
        if ec.is_readonly_source(path):
            self.source_status.setText(ec.READONLY_STACK_SRC_REASON)
            return
        new = self.source_edit.toPlainText()
        if new == self._open_text:
            self.source_status.setText("No change to save.")
            return
        try:
            # Read back first: if the file moved under us, say so rather than
            # writing over whatever is there now.
            with open(path, encoding="utf-8") as fh:
                on_disk = fh.read()
        except OSError as e:
            self.source_status.setText(f"Not saved — cannot read {path}: {e}")
            return
        if on_disk != self._open_text:
            self.source_status.setText(
                f"Not saved — {path} changed on disk since it was opened. Press "
                f"\"Reload from disk\" to see the current file (this discards your "
                f"edits), then re-apply them.")
            return
        try:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(new)
        except OSError as e:
            self.source_status.setText(f"Not saved — {e}")
            return
        self._open_text = new
        self.source_status.setText(f"Saved {path} ({len(new)} bytes).")

    # -- screenshots --
    def _load_shots(self, node: dict, item) -> None:
        shots = list(node.get("shots") or [])
        if not shots and item is not None:
            # A feature's own shots live on the feature node; a test with no
            # attachment still deserves its FILE's narrative shots rather than an
            # empty pane that reads as "this test took no screenshots".
            parent_node = self.node_of(item.parent())
            shots = list(parent_node.get("shots") or [])
        self._shots = shots
        self.shot_list.clear()
        self.shot_preview.clear()
        for sh in shots:
            self.shot_list.addItem(
                f"{sh.name}  —  {_LINKAGE_LABEL.get(sh.linkage, sh.linkage)}"
                + ("  [from the last run]" if sh.from_last_run else ""))
        if not shots:
            self.shot_status.setText(
                "No screenshot is linked to this node. `screenshot: 'only-on-failure'` "
                "in playwright.config.ts means a PASSING test attaches none — so an "
                "empty list here says nothing about whether the test ran.")
        else:
            self.shot_status.setText(
                f"{len(shots)} screenshot(s). Step and persona are EMPTY for every "
                f"one of them — the suite does not record either.")

    def _show_shot(self, row: int) -> None:
        if not (0 <= row < len(self._shots)):
            return
        sh = self._shots[row]
        # The METADATA goes up first and unconditionally. A shot that will not decode
        # still has a path, a linkage, and the same two empty fields — and those are
        # the facts the pane exists to state. Writing them only on the happy path is
        # how "step: (not recorded)" quietly stops being said.
        self.shot_status.setText(
            f"{sh.path}\nlinkage: {_LINKAGE_LABEL.get(sh.linkage, sh.linkage)}; "
            f"step: {sh.step or '(not recorded)'}; "
            f"persona: {sh.persona or '(not recorded)'}")
        if not sh.path or not os.path.isfile(sh.path):
            self.shot_preview.setText(f"missing on disk: {sh.path or '(no path)'}")
            return
        pix = QtGui.QPixmap(sh.path)
        if pix.isNull():
            self.shot_preview.setText(f"could not decode {sh.path}")
            return
        self.shot_preview.setPixmap(pix.scaled(
            self.shot_preview.width() or 480, self.shot_preview.height() or 220,
            Qt.AspectRatioMode.KeepAspectRatio,
            Qt.TransformationMode.SmoothTransformation))

    # -- personas --
    def _load_personas(self, node: dict) -> None:
        self._current_personas = tuple(node.get("personas") or ())
        who = node.get("spec_file") or node.get("rel") or node.get("title") or ""
        if node.get("kind") in (NODE_FEATURE, NODE_TEST):
            self.persona_head.setText(
                (f"<b>{who}</b> names {len(self._current_personas)} seeded persona(s): "
                 + ", ".join(self._current_personas))
                if self._current_personas else
                f"<b>{who}</b> names no seeded persona in its source. That is not "
                f"proof it uses none — it may build a handle at runtime or reach one "
                f"through a helper.")
        else:
            self.persona_head.setText(
                "Select a spec file or a test to see which seeded personas its source "
                "names. The full roster is below in every case.")
        self.persona_head.setTextFormat(Qt.TextFormat.RichText)
        self._sync_persona_rows()

    def _sync_persona_rows(self) -> None:
        table = getattr(self, "persona_table", None)
        if table is None:
            return
        only = self.persona_only.isChecked()
        wanted = set(getattr(self, "_current_personas", ()) or ())
        for name, row in self._persona_rows.items():
            table.setRowHidden(row, bool(only and name not in wanted))

    # ── filter ───────────────────────────────────────────────────────────────────
    def _apply_filter(self, text: str) -> None:
        needle = text.strip().lower()
        for i in range(self.tree.topLevelItemCount()):
            self._filter_item(self.tree.topLevelItem(i), needle)

    def _filter_item(self, item, needle: str) -> bool:
        """Hide an item unless it or a descendant matches. Returns visibility."""
        node = self.node_of(item)
        hay = node.get("search") or item.text(0).lower()
        self_match = (not needle) or needle in hay
        child_match = False
        for i in range(item.childCount()):
            if self._filter_item(item.child(i), needle if not self_match else ""):
                child_match = True
        visible = self_match or child_match
        item.setHidden(not visible)
        return visible

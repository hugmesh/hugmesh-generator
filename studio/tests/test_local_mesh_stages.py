"""The local-mesh STAGED VIEW: phase tables pinned to the real banners, the tracker
driving them, and the tree/log drill-down that replaced the flat scrolling log.

The operator's report was "remove the scrolling log at the bottom and implement a nice
staged navigable table with a responsive log output below tied to what's selected in that
table, like in the other build screens". The other build screen is gui/pages/progress.py,
so the implementation is ITS machinery reused — core/progress_parse.ProgressParser over a
``tracks`` phase table plus core/stage_tracker.StageTracker — and these tests pin the two
halves that can rot independently:

  1. the TABLE half (Qt-free): every pattern must still be emitted verbatim by the
     Makefile / shell scripts that actually run, and no banner line may be ambiguous
     between two phases. This is the ``==> Done`` trap: that exact banner is printed by
     THREE different scripts with three different meanings, so a table that used "Done"
     as a pattern would light up the wrong stage;
  2. the GUI half: feeding banners advances the tree, a nonzero exit fails the RUNNING
     stage and leaves trailing ones PENDING (never fabricated done), a cancel marks the
     running stage stopped, and selecting a stage filters the shared log pane to that
     stage's slice while the run row shows the whole raw log.
"""
import os
import re
import threading
import time

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from hugmesh_studio.core import local_mesh_stages as lms            # noqa: E402
from hugmesh_studio.core import progress_parse as pp                # noqa: E402
from hugmesh_studio.core.stage_tracker import (                     # noqa: E402
    DONE, FAILED, PENDING, RUNNING, SKIPPED, STOPPED, StageTracker)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

_BANNER_LINE = re.compile(r"==>\s*(.*)$")


def _emitted_banners(track: str) -> list[str]:
    """Every ``==> `` banner TEXT the track's declared emitters contain, verbatim from
    the Makefile / shell sources (make and shell variables left un-expanded — the
    patterns are deliberately chosen to be the literal, variable-free part)."""
    out = []
    for rel in pp.track_banner_sources(track):
        with open(os.path.join(GENERATOR_DIR, rel), encoding="utf-8") as fh:
            for ln in fh:
                m = _BANNER_LINE.search(ln)
                if m:
                    out.append(m.group(1))
    return out


# ── 1. the phase tables vs the shell that actually runs ─────────────────────────────
@pytest.mark.parametrize("track", lms.LOCALMESH_TRACKS)
def test_localmesh_track_declares_its_emitters(track):
    srcs = pp.track_banner_sources(track)
    assert srcs, f"{track}: no banner_sources declared — the drift probe would be blind"
    for rel in srcs:
        assert os.path.isfile(os.path.join(GENERATOR_DIR, rel)), rel


@pytest.mark.parametrize("track", lms.LOCALMESH_TRACKS)
def test_localmesh_banners_are_present_verbatim_in_the_sources(track):
    """The drift probe (test_progress_parse.py's clouddeploy pattern, adapted): a local
    bring-up's banners come from SIX emitters, so this asserts PRESENCE rather than a
    call-site count — the Makefile+scripts also print banners this table deliberately
    does not stage (``==> Done:``, ``==> wrote <settings>``)."""
    banners = _emitted_banners(track)
    assert banners
    for ph in pp.track_phases(track):
        for pat in ph["any"]:
            assert any(pat in b for b in banners), (
                f"{track}: phase {ph['label']!r} pattern {pat!r} is emitted by NOTHING in "
                f"{pp.track_banner_sources(track)} — a banner was reworded; update "
                f"core/progress-tables.json")


@pytest.mark.parametrize("track", lms.LOCALMESH_TRACKS)
def test_no_emitted_banner_is_ambiguous_between_two_phases(track):
    """Forward-only matching is only honest if a banner belongs to exactly ONE phase.
    ``==> Done`` is printed by clone-all-repos.sh, gen-certs.sh AND m2-bootstrap.sh — a
    pattern that matched two phases would silently jump the ladder."""
    phases = pp.track_phases(track)
    for banner in _emitted_banners(track):
        hits = [ph["label"] for ph in phases
                if any(pat in banner for pat in ph["any"])]
        assert len(hits) <= 1, f"{track}: banner {banner!r} matches phases {hits}"


@pytest.mark.parametrize("track", lms.LOCALMESH_TRACKS)
def test_declared_callsites_equals_the_pinned_pattern_count(track):
    # one pattern == one `echo "==> …"` call site this table pins (NOT the total number
    # of banners in the file: these emitters print more than the table stages).
    assert pp.track_declared_callsites(track) == pp.track_pattern_count(track)


def test_verb_to_track_mapping_and_the_honest_empty_table():
    assert lms.verb_track("up") == "localmesh-up"
    assert [ph["label"] for ph in lms.verb_phases("up")][:2] == [
        "Private maven prerequisites", "Fetch repo source"]
    assert lms.verb_phases("m2") and lms.verb_phases("clean")
    # verbs whose shell prints no banners get NO phases — never a fabricated ladder
    for verb in ("down", "readiness", "", "not-a-verb"):
        assert lms.verb_phases(verb) == []
        assert lms.verb_track(verb) == ""


def test_the_up_table_covers_the_load_bearing_bring_up_milestones():
    """The stages the operator actually waits on must exist, in this order: fetch the
    source, mint the certs, build+start the containers, then seed. The hours-long
    compose build sits between 'Local stack: ENV=' and 'Up. Front door:' — the only two
    banners that bracket it — and is deliberately ONE stage, not invented sub-steps."""
    labels = [ph["label"] for ph in lms.verb_phases("up")]
    pats = ["".join(ph["any"]) for ph in lms.verb_phases("up")]
    assert labels.index("Fetch repo source") < labels.index("TLS front-door certificates")
    assert (labels.index("TLS front-door certificates")
            < labels.index("Build images + start containers")
            < labels.index("Front door up")
            < labels.index("Seed identity + personas"))
    assert "Local stack: ENV=" in pats[labels.index("Build images + start containers")]
    assert "Up. Front door:" in pats[labels.index("Front door up")]


# ── 2. the tracker over a realistic transcript (Qt-free) ────────────────────────────
def _feed(tracker, parser, lines, t0=0.0):
    for k, ln in enumerate(lines):
        tracker.feed(ln, parser.feed(ln).phase_index, t0 + k)


def _banner_for(track: str, label: str) -> str:
    """The line a phase's FIRST pattern would arrive as — built from the table itself so
    this transcript can never drift from the patterns the probe above pins."""
    ph = next(p for p in pp.track_phases(track) if p["label"] == label)
    return "==> " + ph["any"][0]


def test_feeding_banner_lines_advances_the_stages():
    phases = lms.verb_phases("up")
    tr, pa = StageTracker(phases), pp.ProgressParser(phases=phases)
    labels = [ph["label"] for ph in phases]
    _feed(tr, pa, [
        "make: entering directory",                       # before any banner: no stage
        _banner_for("localmesh-up", "Fetch repo source"),
        "  ++ hugmesh-fe-gateway: cloning",
        _banner_for("localmesh-up", "TLS front-door certificates"),
        _banner_for("localmesh-up", "Build images + start containers"),
        "#42 [hugmesh-wiki-ui builder 3/9] RUN npm ci",
    ])
    st = {s.label: s.state for s in tr.stages}
    assert st["Fetch repo source"] == DONE          # advanced PAST it -> green
    assert st["TLS front-door certificates"] == DONE
    assert st["Patch the checkouts"] == SKIPPED     # stepped over -> neutral, not green
    assert st["Build images + start containers"] == RUNNING
    assert st["Seed identity + personas"] == PENDING
    assert tr.cur == labels.index("Build images + start containers")
    # the pre-banner line belongs to NO stage; the build line belongs to the running one
    assert "make: entering directory" not in [l for s in tr.stages for l in s.lines]
    assert "#42 [hugmesh-wiki-ui builder 3/9] RUN npm ci" in list(tr.stages[tr.cur].lines)


def test_a_nonzero_exit_fails_the_running_stage_and_leaves_the_rest_pending():
    phases = lms.verb_phases("up")
    tr, pa = StageTracker(phases), pp.ProgressParser(phases=phases)
    _feed(tr, pa, [_banner_for("localmesh-up", "Build images + start containers"),
                   "ERROR: failed to solve: process did not complete successfully"])
    tr.finalize(1, 99.0)
    st = {s.label: s.state for s in tr.stages}
    assert st["Build images + start containers"] == FAILED
    # nothing downstream ran, so nothing downstream may claim to have been skipped
    assert st["Front door up"] == PENDING
    assert st["Seed identity + personas"] == PENDING
    assert tr.stages[tr.failed_index()].label == "Build images + start containers"


def test_a_cancel_stops_the_running_stage_and_never_reds_it():
    phases = lms.verb_phases("up")
    tr, pa = StageTracker(phases), pp.ProgressParser(phases=phases)
    _feed(tr, pa, [_banner_for("localmesh-up", "Build images + start containers")])
    tr.finalize(None, 99.0)                       # None == cancelled by the operator
    assert tr.stages[tr.cur].state == STOPPED
    assert tr.failed_index() is None
    assert all(s.state == PENDING for s in tr.stages[tr.cur + 1:])


def test_the_m2_self_heal_running_late_is_skipped_not_reopened_backwards():
    """`make stack-m2-check` can fire the maven banners AFTER clone/certs (the stale-
    registry self-heal). The matcher is forward-only, so the maven stage is honestly
    rendered skipped rather than re-opened — this pins that documented behaviour so
    nobody "fixes" it into a backwards jump."""
    phases = lms.verb_phases("up")
    tr, pa = StageTracker(phases), pp.ProgressParser(phases=phases)
    _feed(tr, pa, [_banner_for("localmesh-up", "Fetch repo source"),
                   _banner_for("localmesh-up", "Private maven prerequisites")])
    st = {s.label: s.state for s in tr.stages}
    assert st["Private maven prerequisites"] == SKIPPED
    assert st["Fetch repo source"] == RUNNING      # never re-opened backwards


def test_module_imports_no_qt():
    """core/local_mesh_stages.py is CORE, so it must import cleanly with no Qt binding
    at all. It needs its own probe: the transitive guard in test_local_mesh_bootstrap.py
    covers local_services (bootstrap imports it) but reaches nothing here — this module's
    only importer is the GUI page, so a stray Qt import would go unnoticed until a
    headless run. In a FRESH interpreter, because this file imports Qt further down and
    an in-process sys.modules check would therefore always find it."""
    import subprocess
    import sys
    probe = (
        "import hugmesh_studio.core.local_mesh_stages as m, sys;"
        "assert m.verb_phases('up');"
        "bad=[x for x in sys.modules if x.startswith(('PySide6','PyQt6','PyQt5'))];"
        "assert not bad, bad;"
        "assert 'hugmesh_studio.gui' not in sys.modules"
    )
    env = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    r = subprocess.run([sys.executable, "-c", probe], env=env,
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


# ── 3. the GUI: tree, filtering, terminal settle ────────────────────────────────────
pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.gui.pages import localmesh as localmesh_mod     # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                         # noqa: E402


@pytest.fixture
def qapp():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication([])


def _drain(qapp, page, timeout_s=15.0):
    deadline = time.monotonic() + timeout_s
    while page._running and time.monotonic() < deadline:
        w = getattr(page, "worker", None)
        if w is not None:
            w.wait(50)
        qapp.processEvents()
    qapp.processEvents()
    assert not page._running, "verb never finished"


class _GatedVerb:
    """A streaming verb that blocks until the test releases it — so the test can feed
    lines through the REAL GUI slot (_on_line, what the worker's queued signal calls)
    while the run is genuinely live."""

    def __init__(self, ok=True, honour_cancel=False):
        self.gate = threading.Event()
        self.ok = ok
        self.honour_cancel = honour_cancel

    def __call__(self, on_line, cancel):
        if self.honour_cancel and cancel is not None:
            cancel.wait(15)
            return False, []
        self.gate.wait(15)
        return self.ok, []


def _start(page, verb="up", ok=True, honour_cancel=False):
    v = _GatedVerb(ok=ok, honour_cancel=honour_cancel)
    page._launch("Bootstrapping", v, stream=True, cancellable=True, verb=verb)
    return v


def _stage_labels(page, i=0):
    run = page._runs[i]
    return [it.text(localmesh_mod._ST_COL_NAME) for it in run.stage_items]


def _states(page, i=0):
    run = page._runs[i]
    return [it.text(localmesh_mod._ST_COL_STATE) for it in run.stage_items]


def test_the_flat_log_is_gone_and_a_stage_tree_hosts_it(qapp):
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    page = dlg.page
    # the log is still the SAME widget (page.log) — it just lives in the split now
    assert isinstance(page.log, QtWidgets.QPlainTextEdit)
    assert isinstance(page.stage_tree, QtWidgets.QTreeWidget)
    assert page.stage_tree.headerItem().text(localmesh_mod._ST_COL_NAME) == "Stage"
    assert page.stage_tree.headerItem().text(localmesh_mod._ST_COL_TIME) == "Time"
    # the log pane may be dragged shut; the tree may NEVER be
    assert page.stage_splitter.isCollapsible(0) is False
    assert page.stage_splitter.isCollapsible(1) is True
    assert page.stage_tree.topLevelItemCount() == 0      # nothing has run yet


def test_a_launched_verb_builds_its_whole_ladder_up_front(qapp):
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    page = dlg.page
    v = _start(page)
    assert page.stage_tree.topLevelItemCount() == 1
    assert len(page._runs[0].stage_items) == len(lms.verb_phases("up"))
    # every stage starts PENDING — the ladder shows what is still ahead, honestly
    assert set(_states(page)) == {PENDING}
    assert all(lbl.split("  ", 1)[1] for lbl in _stage_labels(page))
    v.gate.set()
    _drain(qapp, page)


def test_streamed_banners_advance_the_tree_and_the_log_follows_the_selection(qapp):
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    page = dlg.page
    v = _start(page)
    labels = [ph["label"] for ph in lms.verb_phases("up")]
    i_fetch = labels.index("Fetch repo source")
    i_build = labels.index("Build images + start containers")

    page._on_line(_banner_for("localmesh-up", "Fetch repo source"))
    page._on_line("  ++ hugmesh-fe-gateway: cloning")
    page._on_line(_banner_for("localmesh-up", "Build images + start containers"))
    page._on_line("#42 [hugmesh-wiki-ui builder] RUN npm ci")

    assert _states(page)[i_fetch] == DONE
    assert _states(page)[i_build] == RUNNING
    assert _stage_labels(page)[i_build].startswith("●")     # running glyph, not green
    # the RUN row is selected by default: the pane holds the whole raw stream
    text = page.log.toPlainText()
    assert "cloning" in text and "npm ci" in text
    assert page.log_header.text().endswith("Bootstrapping")

    # select the (already finished) fetch stage -> only ITS slice, and the live stream
    # stops landing in the pane because the selection no longer covers it
    page._on_stage_clicked(page._runs[0].stage_items[i_fetch])
    text = page.log.toPlainText()
    assert "cloning" in text
    assert "npm ci" not in text
    assert "Fetch repo source" in page.log_header.text()
    page._on_line("#43 [hugmesh-wiki-ui builder] RUN npm run build")
    assert "npm run build" not in page.log.toPlainText()
    assert "npm run build" in "\n".join(page._runs[0].buffer)   # never LOST, just filtered

    # back to the run row -> the full raw log again, including what was filtered out
    page._on_stage_clicked(page._runs[0].item)
    assert "npm run build" in page.log.toPlainText()
    assert "cloning" in page.log.toPlainText()
    v.gate.set()
    _drain(qapp, page)


def test_the_selected_running_stage_keeps_receiving_the_live_stream(qapp):
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    page = dlg.page
    v = _start(page)
    i_build = [ph["label"] for ph in lms.verb_phases("up")].index(
        "Build images + start containers")
    page._on_line(_banner_for("localmesh-up", "Build images + start containers"))
    page._on_stage_clicked(page._runs[0].stage_items[i_build])
    page._on_line("#7 exporting layers")
    assert "#7 exporting layers" in page.log.toPlainText()
    v.gate.set()
    _drain(qapp, page)


def test_a_failed_verb_fails_the_running_stage_and_selects_it(qapp):
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    page = dlg.page
    v = _start(page, ok=False)
    labels = [ph["label"] for ph in lms.verb_phases("up")]
    i_build = labels.index("Build images + start containers")
    page._on_line(_banner_for("localmesh-up", "Build images + start containers"))
    page._on_line("ERROR: failed to solve")
    v.gate.set()
    _drain(qapp, page)

    states = _states(page)
    assert states[i_build] == FAILED
    assert states[i_build + 1:] == [PENDING] * (len(labels) - i_build - 1)
    assert _stage_labels(page)[i_build].startswith("✗")
    # the failure drill-down is pre-loaded: the pane already shows the failing slice
    assert page._selected_stage == i_build
    assert "ERROR: failed to solve" in page.log.toPlainText()
    assert page._runs[0].status == "failed"


def test_a_cancelled_verb_marks_the_running_stage_stopped_not_failed(qapp):
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    page = dlg.page
    _start(page, honour_cancel=True)
    i_build = [ph["label"] for ph in lms.verb_phases("up")].index(
        "Build images + start containers")
    page._on_line(_banner_for("localmesh-up", "Build images + start containers"))
    page._cancel_clicked()
    _drain(qapp, page)
    assert _states(page)[i_build] == STOPPED
    assert page._runs[0].status == "stopped"
    assert FAILED not in _states(page)          # an operator stop is never a red failure


def test_a_clean_run_marks_reached_stages_done_and_the_rest_skipped(qapp):
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    page = dlg.page
    v = _start(page)
    labels = [ph["label"] for ph in lms.verb_phases("up")]
    i_seeded = labels.index("Sign-in ready (overlay, Tor, finish)")
    for lbl in ("Fetch repo source", "Build images + start containers",
                "Seed identity + personas"):
        page._on_line(_banner_for("localmesh-up", lbl))
    v.gate.set()
    _drain(qapp, page)
    states = _states(page)
    assert states[labels.index("Seed identity + personas")] == DONE
    # a clean exit never fabricates a done for a stage whose banner never arrived
    assert states[i_seeded] == SKIPPED
    assert DONE not in states[i_seeded:]
    assert page._runs[0].status == "ok"


def test_each_verb_gets_its_own_row_and_the_older_log_stays_reachable(qapp):
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    page = dlg.page
    v = _start(page, verb="m2")
    page._on_line("[m2] building hugmesh-parent")
    v.gate.set()
    _drain(qapp, page)
    v2 = _start(page, verb="up")
    page._on_line("[bring-up] second run")
    assert page.stage_tree.topLevelItemCount() == 2
    assert len(page._runs[1].stage_items) == len(lms.verb_phases("up"))
    assert "[m2] building" not in page.log.toPlainText()   # pane follows the NEW run
    page._on_stage_clicked(page._runs[0].item)             # ... and the old one is a click away
    assert "[m2] building hugmesh-parent" in page.log.toPlainText()
    v2.gate.set()
    _drain(qapp, page)


def test_a_verb_with_no_banners_gets_no_stages_and_still_shows_its_log(qapp):
    """The readiness check / stack-down print no ``==> `` banners. An honest empty
    ladder — plus the raw log — beats a fabricated one-stage bar."""
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    page = dlg.page
    v = _start(page, verb="down")
    assert page._runs[0].stage_items == []
    page._on_line("[readiness] READY")
    assert "[readiness] READY" in page.log.toPlainText()
    v.gate.set()
    _drain(qapp, page)
    assert page._runs[0].status == "ok"


def test_the_handlers_pre_flight_lines_belong_to_the_run_they_announce(qapp, monkeypatch):
    """`_bootstrap_up` prints "[bootstrap] generating credentials …" BEFORE launching.
    That line must survive into the run's raw log — selecting the run row used to be
    able to erase the very sentence that explains what it is doing."""
    monkeypatch.setattr(localmesh_mod.LocalMeshBootstrap, "up",
                        lambda self, on_line=None, cancel=None:
                        (on_line and on_line("[done] platform up")) or (True, []),
                        raising=True)
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    dlg.ack.setChecked(True)
    dlg._bootstrap_up()
    _drain(qapp, dlg.page)
    assert dlg.page._runs and dlg.page._runs[0].stage_items      # the "up" ladder is staged
    raw = "\n".join(dlg.page._runs[0].buffer)
    assert "[bootstrap] generating credentials" in raw
    assert "[done] platform up" in raw
    assert "[done] platform up" in dlg.log.toPlainText()


def test_a_declined_confirmation_does_not_donate_its_line_to_the_next_run(qapp,
                                                                          monkeypatch):
    """A note that announces NO run must not be queued. `_bootstrap_clean` prints
    "[stack-clean] cancelled" when the operator answers No to the destructive prompt
    and then returns without launching anything; while that line sat in _pending it was
    adopted by whatever verb ran NEXT, so an unrelated run's raw log opened by claiming
    a stack-clean cancellation that was never part of it."""
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    page = dlg.page
    monkeypatch.setattr(localmesh_mod.QtWidgets.QMessageBox, "question",
                        staticmethod(lambda *a, **k:
                                     localmesh_mod.QtWidgets.QMessageBox
                                     .StandardButton.No))
    page._bootstrap_clean()
    assert page._pending == []
    assert "cancelled" in page.log.toPlainText()   # still SHOWN, just not inherited
    v = _start(page)
    assert not any("stack-clean" in ln for ln in page._runs[-1].buffer)
    v.gate.set()
    _drain(qapp, page)


def test_control_bytes_never_reach_the_log_widget(qapp):
    """compose/maven colour their output unconditionally; Qt paints a BOX for every
    escape byte, so the line is sanitised in the ONE per-line slot."""
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    page = dlg.page
    v = _start(page)
    page._on_line("\x1b[1;36m==> " + lms.verb_phases("up")[1]["any"][0] + "\x1b[0m")
    page._on_line("\x1b[32mgreen\x1b[0m\r noise")
    assert "\x1b" not in page.log.toPlainText()
    assert "\r" not in page.log.toPlainText()
    # the ANSI-wrapped banner still advanced the ladder (strip_ansi runs first)
    assert RUNNING in _states(page)
    v.gate.set()
    _drain(qapp, page)

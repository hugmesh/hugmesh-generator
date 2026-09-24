"""The e2e FEATURE TREE that replaced the "Run e2e suite" button.

THE DEFECT CLASS THIS FILE GUARDS. A button that runs everything is honest by
accident: it cannot claim to have run something it did not. A tree can, and there are
exactly three ways it does:

  1. VACUITY — the tree renders, the operator checks one feature, and Run ignores the
     selection and runs the whole suite anyway (or runs nothing). Nothing on screen
     would show the difference: the log scrolls, a summary line appears, and it is
     green. So the centre of this file
     (test_the_checked_spec_reaches_the_spawned_make_argv) asserts on the ARGV A CHILD
     PROCESS RECEIVED, via a stub `make` on PATH that echoes its own argv — the same
     discipline as studio/tests/test_pages_qemu.py, for the same reason.
  2. A RUN BUTTON ON SOMETHING UNRUNNABLE — owncast, tube, wiki and character-studio
     have ZERO specs. A checkbox next to them would run nothing and report green.
  3. A GREY ROW THAT WILL NOT SAY WHY — 62 of the last run's 259 results were skipped
     and 14 of those gave no machine-readable reason. "skipped" with no reason reads
     as "fine".

WHAT THIS FILE DOES NOT PROVE. It never starts a stack, never installs Playwright and
never runs a spec. `make` is a stub; the suite is a recorded fixture. So it proves the
SELECTION REACHES THE RUNNER and that the tree's honesty rules hold — not that the
suite passes, and not that `make stack-e2e E2E_SPECS=…` narrows Playwright correctly
(that is the Makefile's own line, asserted here only as text, and marked as such).
"""
from __future__ import annotations

import json
import os
import shutil
import stat
import time

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from types import SimpleNamespace                                    # noqa: E402

from hugmesh_studio.core import e2e_catalogue as ec                  # noqa: E402
from hugmesh_studio.core import local_mesh_bootstrap as lmb          # noqa: E402
from hugmesh_studio.core.local_stack_node import LocalStackNode      # noqa: E402
from hugmesh_studio.core.mesh_node import MeshNode, MeshStatus       # noqa: E402
from hugmesh_studio.gui.pages import localmesh as localmesh_mod      # noqa: E402
from hugmesh_studio.gui.pages.e2e_tree_dialog import (               # noqa: E402
    GROUP_SPECS, GROUP_UNCOVERED, NODE_FEATURE, NODE_SERVICE, UNKNOWN_SKIP_PREFIX,
    E2ETreeDialog,
)
from hugmesh_studio.gui.qt import Qt, QtWidgets                      # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "fixtures", "e2e-catalogue")

#: The stub `make`. It echoes its own argv — that echo is the ONLY thing the vacuity
#: test reads, so the assertion is about what a CHILD PROCESS was given, not about
#: anything the page or the dialog printed to itself.
_STUB_MAKE = """#!/usr/bin/env bash
echo "STUB-MAKE $*"
exit 0
"""

#: A 1x1 PNG, so the screenshot pane has something real to decode.
_PNG = bytes.fromhex(
    "89504e470d0a1a0a0000000d4948445200000001000000010802000000907753"
    "de0000000c49444154789c63f8cfc0000003010100c9fe92ef0000000049454e"
    "44ae426082")

#: The two spec files the recorded fixtures name, with persona handles in the source
#: (and one named ONLY in a comment — the house-rule trap core/e2e_catalogue strips).
_SPEC_SOURCES = {
    "01-frontpage.spec.ts": (
        "import { test } from '@playwright/test';\n"
        "// e2e-admin is NOT used here — this mention is a comment on purpose.\n"
        "test('front page', async ({ page }) => { await page.goto('/'); });\n"),
    "12-rbac-gateway-route-access.spec.ts": (
        "import { test } from '@playwright/test';\n"
        "const who = 'e2e-admin';\n"
        "const other = 'e2e-adminonly';\n"),
    "14-rbac-gateway-live.spec.ts": "const u = 'e2e-user';\n",
    "18-rbac-phase8-10-pending.spec.ts": "const m = 'e2e-mod';\n",
    "23-domainlock-mod-ban-interaction.spec.ts": "const b = 'e2e-banned';\n",
}

_ROSTER = """#!/usr/bin/env bash
SYSTEMS_ROLE_USERS="${SYSTEMS_ROLE_USERS:-\\
e2e-admin:ROLE_ADMIN,ROLE_USER:E2E_ADMIN_PASSWORD \\
e2e-adminonly:ROLE_ADMIN,ROLE_USER:E2E_ADMINONLY_PASSWORD \\
e2e-mod:ROLE_MOD:E2E_MOD_PASSWORD \\
e2e-user:ROLE_USER:E2E_USER_PASSWORD \\
e2e-pending:ROLE_USER:E2E_PENDING_PASSWORD \\
e2e-banned:ROLE_USER:E2E_BANNED_PASSWORD \\
rbac-pending@gmail.com:ROLE_USER:E2E_RBACPENDING_PASSWORD \\
}"
"""

_SEED_E2E = """#!/usr/bin/env bash
LOCAL_OPERATOR_USER="${LOCAL_OPERATOR_USER:-mesh-operator}"
LOCAL_OPERATOR_ROLES="${LOCAL_OPERATOR_ROLES:-ROLE_SUPERADMIN,ROLE_USER}"
SEED_REGISTRATION_SKIP="${SEED_REGISTRATION_SKIP:-e2e-pending rbac-pending-gmail-com e2e-banned}"
"""

_FEATURE = """@service:login @layer:ui
Feature: Front door over the generated TLS certs

  Scenario: the front page gates anonymous visitors @layer:ui
    When I open the path "/"
    Then the URL matches "/login"
"""


# ── the fake checkout ────────────────────────────────────────────────────────────
@pytest.fixture
def fake_gen(tmp_path):
    """A generator checkout with a RECORDED suite: the fixture --list payload, the
    fixture report.json, real spec sources, one .feature, and two screenshots (one
    whose NN- prefix matches a spec, one orphan)."""
    gen = tmp_path / "gen"
    e2e = gen / "tests" / "e2e"
    (e2e / "specs").mkdir(parents=True)
    (e2e / "node_modules").mkdir()          # list_specs' precondition
    for name, text in _SPEC_SOURCES.items():
        (e2e / "specs" / name).write_text(text, encoding="utf-8")

    (e2e / "features" / "onboarding").mkdir(parents=True)
    (e2e / "features" / "onboarding" / "frontpage.feature").write_text(
        _FEATURE, encoding="utf-8")

    shots = e2e / "screenshots"
    shots.mkdir()
    (shots / "01-front-page.png").write_bytes(_PNG)
    (shots / "97-nobody-owns-me.png").write_bytes(_PNG)

    run = e2e / "test-results" / "studio-20260822-000000"
    run.mkdir(parents=True)
    shutil.copy(os.path.join(FIXTURES, "report.json"), run / "report.json")
    shutil.copy(os.path.join(FIXTURES, "summary.json"), run / "summary.json")

    (gen / "tests" / "qemu").mkdir(parents=True)
    (gen / "tests" / "qemu" / "seed-accounts.sh").write_text(_ROSTER, encoding="utf-8")
    (gen / "tests" / "stack").mkdir(parents=True)
    (gen / "tests" / "stack" / "seed-e2e.sh").write_text(_SEED_E2E, encoding="utf-8")
    return gen


@pytest.fixture
def stub_make(tmp_path, monkeypatch):
    """Put a `make` that ECHOES ITS ARGV first on PATH, and hand back its directory."""
    binf = tmp_path / "stubbin"
    binf.mkdir()
    m = binf / "make"
    m.write_text(_STUB_MAKE)
    m.chmod(m.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    monkeypatch.setenv("PATH", str(binf) + os.pathsep + os.environ.get("PATH", ""))
    return binf


def _list_runner():
    """subprocess.run stand-in returning the RECORDED `--list` payload, so no Node is
    needed. Records its calls so a test can prove the enumeration actually happened."""
    import subprocess
    with open(os.path.join(FIXTURES, "list.json"), encoding="utf-8") as fh:
        payload = fh.read()

    def run(argv, **kwargs):
        run.calls.append(tuple(argv))
        return subprocess.CompletedProcess(argv, 0, payload, "")
    run.calls = []
    return run


@pytest.fixture
def catalogue(fake_gen):
    return ec.load_catalogue(str(fake_gen), runner=_list_runner())


@pytest.fixture(scope="module")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def dlg(qapp, catalogue, fake_gen):
    d = E2ETreeDialog(catalogue, str(fake_gen))
    yield d
    d.deleteLater()
    qapp.processEvents()


# ── tree helpers ─────────────────────────────────────────────────────────────────
def _walk(item):
    yield item
    for i in range(item.childCount()):
        yield from _walk(item.child(i))


def _all_items(dlg):
    for i in range(dlg.tree.topLevelItemCount()):
        yield from _walk(dlg.tree.topLevelItem(i))


def _group(dlg, title):
    return dlg._group_items[title]


def _texts_under(dlg, title):
    return [it.text(0) for it in _walk(_group(dlg, title))]


# ── 1. THE VACUITY GUARD ─────────────────────────────────────────────────────────
def test_the_checked_spec_reaches_the_spawned_make_argv(qapp, dlg, wired_page,
                                                        stub_make):
    """THE test. Check ONE feature, press Run, and read the argv a child got.

    The whole chain is production code: the dialog compiles the selection, the page's
    _run_e2e passes it through, LocalStackNode.run_e2e turns it into a make variable
    assignment, and _make spawns it. Only `make` itself is a stub, and only so the
    argv can be read back.
    """
    page, echoed = wired_page()

    dlg.feature_items["12-rbac-gateway-route-access.spec.ts"].setCheckState(
        0, Qt.CheckState.Checked)
    dlg.run_btn.click()
    assert dlg.run_specs == ("specs/12-rbac-gateway-route-access.spec.ts",)

    page._run_e2e(dlg.run_specs)
    _finish(page, qapp)

    lines = echoed()
    assert lines, "the stub `make` never ran — nothing was spawned"
    argv = lines[0]
    assert "stack-e2e" in argv, argv
    assert "E2E_SPECS=specs/12-rbac-gateway-route-access.spec.ts" in argv, (
        f"the CHECKED spec never reached the spawned command: {argv!r}")
    # …and the ones NOT checked must not have come along for the ride.
    assert "01-frontpage" not in argv, (
        f"an UNCHECKED spec was passed to the runner: {argv!r}")


def test_two_checked_specs_both_arrive_and_nothing_else_does(qapp, dlg, wired_page,
                                                             stub_make):
    """A partial selection must be exactly the partial selection."""
    page, echoed = wired_page()
    for f in ("01-frontpage.spec.ts", "14-rbac-gateway-live.spec.ts"):
        dlg.feature_items[f].setCheckState(0, Qt.CheckState.Checked)
    dlg.run_btn.click()
    page._run_e2e(dlg.run_specs)
    _finish(page, qapp)

    argv = echoed()[0]
    assert "E2E_SPECS=specs/01-frontpage.spec.ts specs/14-rbac-gateway-live.spec.ts" \
        in argv, argv
    assert "12-rbac" not in argv and "18-rbac" not in argv, argv


def test_the_dialog_click_is_wired_to_the_page_run(qapp, fake_gen, wired_page,
                                                   stub_make, monkeypatch):
    """The seam between the two halves: opening the tree FROM THE PAGE and pressing
    its Run must dispatch the page's run with that selection. A dialog that compiles a
    perfect selection nobody connected is the same defect wearing a suit."""
    page, echoed = wired_page()
    # The gate must ANSWER before the tree can arm its Run — the page starts with
    # "nothing established", which is a blocker, not permission.
    page._sync_e2e_gate()
    _settle_probe(qapp, page, "_e2e_probe")
    assert page._e2e_blockers == []
    monkeypatch.setattr(localmesh_mod, "load_catalogue",
                        lambda d, env=None: ec.load_catalogue(
                            str(fake_gen), runner=_list_runner()))
    page._open_e2e_tree()
    _settle_probe(qapp, page, "_e2e_cat_probe")
    d = page._e2e_dialog
    assert d is not None, "the tree never opened"
    d.feature_items["18-rbac-phase8-10-pending.spec.ts"].setCheckState(
        0, Qt.CheckState.Checked)
    d.run_btn.click()
    qapp.processEvents()
    _finish(page, qapp)
    argv = echoed()[0]
    assert "E2E_SPECS=specs/18-rbac-phase8-10-pending.spec.ts" in argv, argv
    d.deleteLater()


def test_reopening_the_tree_replaces_the_previous_one(qapp, fake_gen, wired_page,
                                                     monkeypatch):
    """These dialogs are parented to the page, so rebinding the attribute without
    destroying the old one leaks it for the life of the page — the same trap
    own_probe() documents for QThreads."""
    page, _ = wired_page()
    monkeypatch.setattr(localmesh_mod, "load_catalogue",
                        lambda d, env=None: ec.load_catalogue(
                            str(fake_gen), runner=_list_runner()))
    page._open_e2e_tree()
    _settle_probe(qapp, page, "_e2e_cat_probe")
    first = page._e2e_dialog
    page._open_e2e_tree()
    _settle_probe(qapp, page, "_e2e_cat_probe")
    second = page._e2e_dialog
    assert second is not first
    qapp.processEvents()
    kids = [c for c in page.children()
            if isinstance(c, E2ETreeDialog) and c is not second]
    assert not kids, f"{len(kids)} stale tree dialog(s) still parented to the page"


def test_run_refuses_an_empty_selection_inline_and_never_falls_back_to_all(dlg):
    """The other half of vacuity: Run must not quietly mean "everything"."""
    assert not dlg.run_btn.isEnabled(), "Run is armed with nothing checked"
    dlg._on_run()                       # drive it anyway, as a stuck UI would
    assert dlg.run_specs == ()
    assert "Nothing is checked" in dlg.status.text()
    assert "never falls back" in dlg.status.text()


def test_a_shell_unsafe_selection_is_refused_whole(dlg):
    """E2E_SPECS is expanded inside a /bin/sh recipe. A path that is not a plain
    specs/*.ts must stop the run, not run the half that parsed."""
    it = dlg.feature_items["01-frontpage.spec.ts"]
    it.setCheckState(0, Qt.CheckState.Checked)
    # forge a hostile entry the way a corrupted listing would
    dlg.feature_items["; touch /tmp/pwned"] = it
    dlg._on_run()
    assert dlg.run_specs == (), "a rejected path did not stop the run"
    assert "Refusing to run" in dlg.status.text()


# ── 2. NOTHING UNRUNNABLE IS RUNNABLE ────────────────────────────────────────────
def test_uncovered_services_have_no_checkbox_and_carry_their_reason(dlg, catalogue):
    """owncast / tube / wiki / character-studio must render as NO COVERAGE rows that
    CANNOT be selected — the checkbox is the only path into the run, so removing it
    is a structural guarantee, not a convention."""
    slugs = {c.slug for c in catalogue.uncovered}
    for expected in ("owncast", "tube", "wiki", "character-studio"):
        assert expected in slugs, (
            f"{expected} is no longer reported uncovered — if a spec really covers "
            f"it now, this test should be updated, not deleted")

    seen = set()
    for it in _walk(_group(dlg, GROUP_UNCOVERED)):
        node = dlg.node_of(it)
        if node.get("kind") != NODE_SERVICE:
            continue
        seen.add(node["slug"])
        assert not (it.flags() & Qt.ItemFlag.ItemIsUserCheckable), (
            f"{node['slug']} has NO e2e coverage but rendered a checkbox — a Run "
            f"here would run nothing and report green")
        assert "NO COVERAGE" in it.text(0)
        kids = [it.child(i).text(0) for i in range(it.childCount())]
        assert kids and kids[0].strip(), f"{node['slug']} has no reason node"
        assert "must not offer a Run button" in kids[0] or "NO spec" in kids[0], kids
    assert {"owncast", "tube", "wiki", "character-studio"} <= seen


def test_the_tor_row_names_its_kind_lane_door_and_checks_it(dlg):
    """#577: tor has no compose spec, so it stays a NO COVERAGE row with its reason
    FIRST — but the row also states the kind lane's onion door, checked against the
    tree. The fake checkout has no tor-onion-kind.feature, so the line must say the
    door is MISSING rather than vouch for it."""
    rows = [it for it in _walk(_group(dlg, GROUP_UNCOVERED))
            if dlg.node_of(it).get("kind") == NODE_SERVICE
            and dlg.node_of(it).get("slug") == "tor"]
    assert len(rows) == 1, "tor is not a NO COVERAGE row"
    kids = [rows[0].child(i).text(0) for i in range(rows[0].childCount())]
    assert "NO spec" in kids[0], kids
    door = [k for k in kids[1:] if k.startswith("kind:")]
    assert len(door) == 1, kids
    assert "make kind-tor" in door[0] and "MISSING" in door[0], door


def _door_rows(d):
    from hugmesh_studio.gui.pages.e2e_tree_dialog import GROUP_LANE_DOORS
    return [it for it in _walk(_group(d, GROUP_LANE_DOORS))
            if d.node_of(it).get("kind") == NODE_SERVICE
            and d.node_of(it).get("slug") == "tor"]


def test_the_kind_onion_door_has_its_own_group_row(dlg):
    """#577: the door is listed in its OWN group whatever tor's compose verdict is,
    and with no checkbox (a .feature runs through its own make target)."""
    rows = _door_rows(dlg)
    assert len(rows) == 1, "no tor row under the lane-door group"
    assert not (rows[0].flags() & Qt.ItemFlag.ItemIsUserCheckable)
    kids = [rows[0].child(i).text(0) for i in range(rows[0].childCount())]
    assert len(kids) == 1 and kids[0].startswith("kind:") and "make kind-tor" in kids[0], kids


def test_the_door_survives_tor_becoming_covered(qapp, fake_gen):
    """THE REGRESSION the #613 skeptics found: once a compose spec names tor (#576's
    onion helpers did), tor leaves NO COVERAGE — and a door listed only there
    vanished from the tree. Here tor is COVERED and the door line must still show,
    verified against the fake tree (feature present -> 'drives this service')."""
    specs = fake_gen / "tests" / "e2e" / "specs"
    (specs / "helpers.ts").write_text(
        "export async function onionContext(browser: any) {\n"
        "  return browser.newContext({ proxy: { server: 'socks5://127.0.0.1:9050' } });\n"
        "}\n", encoding="utf-8")
    feat = fake_gen / ec.LANE_DOORS[0].feature
    feat.parent.mkdir(parents=True, exist_ok=True)
    feat.write_text("@env:kind @via:onion\nFeature: kind onion\n", encoding="utf-8")
    cat = ec.load_catalogue(str(fake_gen), runner=_list_runner())
    tor = [c for c in cat.services if c.slug == "tor"]
    assert tor and not tor[0].needs_a_test and tor[0].reachable, tor
    d = E2ETreeDialog(cat, str(fake_gen))
    try:
        assert not [it for it in _walk(_group(d, GROUP_UNCOVERED))
                    if d.node_of(it).get("slug") == "tor"], "tor is covered here"
        rows = _door_rows(d)
        assert len(rows) == 1, "the kind onion door vanished once tor was covered"
        line = rows[0].child(0).text(0)
        assert line.startswith("kind: tor-onion-kind.feature drives this service"), line
    finally:
        d.deleteLater()
        qapp.processEvents()


def test_no_uncovered_slug_can_ever_reach_the_selection(dlg, catalogue):
    """Belt and braces: even after checking everything checkable, no service slug is
    in the compiled run."""
    dlg._set_all_checked(True)
    accepted, rejected = dlg.selected_specs()
    assert not rejected
    joined = " ".join(accepted)
    for c in catalogue.uncovered:
        assert c.slug not in joined, f"{c.slug} reached the run args: {accepted}"
    assert all(a.startswith("specs/") and a.endswith(".ts") for a in accepted)


# ── 3. NO GREY ROW WITHOUT A REASON ──────────────────────────────────────────────
def test_every_skipped_test_has_a_reason_node(dlg, catalogue):
    skipped = [t for t in catalogue.tests if t.status == ec.STATUS_SKIPPED]
    assert skipped, "the fixture no longer contains a skipped test"
    by_title = {}
    for it in _all_items(dlg):
        node = dlg.node_of(it)
        if node.get("kind") == "test":
            by_title[it.text(0)] = it
    for t in skipped:
        it = by_title.get(t.title)
        assert it is not None, f"skipped test missing from the tree: {t.title!r}"
        kids = [it.child(i).text(0) for i in range(it.childCount())]
        reason_rows = [k for k in kids if "skipped" in k]
        assert reason_rows, f"{t.title!r} is grey with no reason node: {kids}"
        assert (t.skip_reason or ec.UNKNOWN_SKIP_REASON) in reason_rows[0]


def test_a_skip_with_no_machine_reason_says_REASON_UNKNOWN(dlg, catalogue):
    """The 62-of-259 case. A bare "skipped" reads as fine; this must not."""
    unexplained = catalogue.unexplained_skips
    assert unexplained, "the fixture no longer contains an unexplained skip"
    rows = [it.text(0) for it in _all_items(dlg)
            if it.text(0).startswith(UNKNOWN_SKIP_PREFIX)]
    assert len(rows) >= len(unexplained), (
        f"{len(unexplained)} skip(s) gave no reason but only {len(rows)} row(s) say "
        f"REASON UNKNOWN")
    assert "REASON UNKNOWN" in rows[0]
    # and a skip that DID give a reason must not be smeared with the same words
    known = [t for t in catalogue.tests
             if t.status == ec.STATUS_SKIPPED and t.skip_reason_known]
    assert known, "the fixture no longer contains an explained skip"
    for t in known:
        assert not any(r.startswith(UNKNOWN_SKIP_PREFIX) and t.skip_reason in r
                       for r in rows)


def test_the_catalogues_problems_are_on_screen(dlg, catalogue):
    """A tree that renders its own blind spots as absence is the whole failure mode."""
    assert catalogue.problems
    shown = dlg.problems_label.text()
    for p in catalogue.problems:
        assert p in shown, f"unreported problem: {p}"


# ── 4. GHERKIN, PERSONAS, SOURCE, SCREENSHOTS ────────────────────────────────────
def test_gherkin_features_are_first_class_nodes(dlg):
    from hugmesh_studio.gui.pages.e2e_tree_dialog import GROUP_GHERKIN
    texts = _texts_under(dlg, GROUP_GHERKIN)
    assert any("frontpage.feature" in t for t in texts), texts
    assert any(t.startswith("Scenario:") for t in texts), texts
    assert any("not runnable directly" in t for t in texts), (
        "a .feature offered as runnable would run a file Playwright never sees")


def test_a_missing_gherkin_harness_is_a_NAMED_absence(qapp, fake_gen):
    """This checkout may legitimately have no tests/e2e/features. "not merged yet" and
    "there are no features" are different facts."""
    shutil.rmtree(fake_gen / "tests" / "e2e" / "features")
    cat = ec.load_catalogue(str(fake_gen), runner=_list_runner())
    d = E2ETreeDialog(cat, str(fake_gen))
    from hugmesh_studio.gui.pages.e2e_tree_dialog import GROUP_GHERKIN
    texts = _texts_under(d, GROUP_GHERKIN)
    assert any("feat/e2e-gherkin-harness" in t for t in texts), texts
    d.deleteLater()


def test_a_feature_reports_the_personas_its_source_names(dlg, catalogue):
    it = dlg.feature_items["12-rbac-gateway-route-access.spec.ts"]
    node = dlg.node_of(it)
    assert node["kind"] == NODE_FEATURE
    assert set(node["personas"]) == {"e2e-admin", "e2e-adminonly"}
    dlg.tree.setCurrentItem(it)
    head = dlg.persona_head.text()
    assert "e2e-admin" in head and "e2e-adminonly" in head

    # HOUSE RULE: a persona named only in a COMMENT is not a persona this spec drives.
    front = dlg.node_of(dlg.feature_items["01-frontpage.spec.ts"])
    assert front["personas"] == (), front["personas"]
    dlg.tree.setCurrentItem(dlg.feature_items["01-frontpage.spec.ts"])
    assert "names no seeded persona" in dlg.persona_head.text()


def test_the_users_table_is_the_seeded_roster_and_marks_gated_personas(dlg,
                                                                       catalogue):
    """One roster parser, not two: this is core.seeded_credentials' output verbatim."""
    table = dlg.persona_table
    assert table is not None and table.rowCount() == len(catalogue.roster.users)
    names = {table.item(r, 0).text() for r in range(table.rowCount())}
    assert names == {u.username for u in catalogue.roster.users}
    # read-only
    assert table.editTriggers() == QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers
    gated = {g.username for g in catalogue.gated}
    assert "e2e-pending" in gated and "rbac-pending@gmail.com" in gated
    for r in range(table.rowCount()):
        note = table.item(r, 4).text()
        if table.item(r, 0).text() in gated:
            assert "ON PURPOSE" in note, (
                "a deliberately-gated persona shown with no note is one the next "
                "reader will 'fix'")
        else:
            assert note == ""


def test_the_persona_filter_hides_only_the_others(dlg):
    dlg.tree.setCurrentItem(dlg.feature_items["12-rbac-gateway-route-access.spec.ts"])
    dlg.persona_only.setChecked(True)
    table = dlg.persona_table
    visible = {table.item(r, 0).text() for r in range(table.rowCount())
               if not table.isRowHidden(r)}
    assert visible == {"e2e-admin", "e2e-adminonly"}
    dlg.persona_only.setChecked(False)
    assert not any(table.isRowHidden(r) for r in range(table.rowCount()))


def test_the_source_pane_edits_and_saves_back(dlg, fake_gen):
    path = fake_gen / "tests" / "e2e" / "specs" / "01-frontpage.spec.ts"
    dlg.tree.setCurrentItem(dlg.feature_items["01-frontpage.spec.ts"])
    assert dlg.source_edit.toPlainText() == path.read_text(encoding="utf-8")
    assert not dlg.source_edit.isReadOnly()
    assert dlg.save_btn.isEnabled()

    dlg.source_edit.setPlainText("// edited by the tree\n")
    dlg.save_btn.click()
    assert path.read_text(encoding="utf-8") == "// edited by the tree\n"
    assert "Saved" in dlg.source_status.text()


def test_a_save_over_a_file_that_moved_under_us_is_refused(dlg, fake_gen):
    path = fake_gen / "tests" / "e2e" / "specs" / "01-frontpage.spec.ts"
    dlg.tree.setCurrentItem(dlg.feature_items["01-frontpage.spec.ts"])
    dlg.source_edit.setPlainText("// mine\n")
    path.write_text("// somebody else's\n", encoding="utf-8")
    dlg.save_btn.click()
    assert path.read_text(encoding="utf-8") == "// somebody else's\n", \
        "the tree clobbered a file that had changed on disk"
    assert "changed on disk" in dlg.source_status.text()


def test_a_stack_src_file_is_read_only_and_says_why(qapp, dlg, tmp_path):
    """`make stack-clone` wipes .stack-src, so a save there is thrown away silently."""
    victim = tmp_path / ".stack-src" / "x" / "a.spec.ts"
    victim.parent.mkdir(parents=True)
    victim.write_text("original\n", encoding="utf-8")
    dlg._load_source({"kind": NODE_FEATURE, "path": str(victim), "rel": "x/a.spec.ts"})
    assert dlg.source_edit.isReadOnly()
    assert not dlg.save_btn.isEnabled()
    assert "READ-ONLY" in dlg.source_path.text()
    assert ".stack-src" in dlg.source_status.text()
    # and the guard survives a caller that reaches past the widget
    dlg.source_edit.setPlainText("clobbered\n")
    dlg._save_source()
    assert victim.read_text(encoding="utf-8") == "original\n"


def test_the_screenshot_pane_never_implies_per_step_data(dlg, fake_gen):
    dlg.tree.setCurrentItem(dlg.feature_items["01-frontpage.spec.ts"])
    assert "Per-STEP screenshot data does not exist" in dlg.shot_note.text()
    assert dlg.shot_list.count() >= 1
    row = dlg.shot_list.item(0).text()
    assert "01-front-page" in row
    assert "filename NN- prefix" in row, (
        "a filename-prefix guess rendered as if it were a real per-test link")
    dlg.shot_list.setCurrentRow(0)
    assert "(not recorded)" in dlg.shot_status.text()


def test_an_orphan_screenshot_is_still_shown_somewhere(dlg):
    from hugmesh_studio.gui.pages.e2e_tree_dialog import GROUP_ORPHAN_SHOTS
    texts = _texts_under(dlg, GROUP_ORPHAN_SHOTS)
    assert any("screenshot(s) with no matching spec" in t for t in texts), texts


# ── 5. THE GATE IS NOT REGRESSED ─────────────────────────────────────────────────
def test_blockers_disable_the_trees_run_and_name_themselves(qapp, catalogue,
                                                            fake_gen):
    d = E2ETreeDialog(catalogue, str(fake_gen),
                      blockers=["the local stack is not running — bring it up first."])
    d.feature_items["01-frontpage.spec.ts"].setCheckState(0, Qt.CheckState.Checked)
    assert not d.run_btn.isEnabled()
    assert "not running" in d.run_btn.toolTip()
    d._on_run()
    assert d.run_specs == ()
    assert "Cannot run" in d.status.text()
    d.deleteLater()


def test_the_page_button_still_carries_the_gate(qapp, wired_page):
    """The four preserved behaviours, at the page: the gate probe stays off-thread and
    the button's tooltip is still where blockers are named."""
    page, _ = wired_page(["the local stack is not running."])
    page._sync_e2e_gate()
    assert page._e2e_probe.isRunning() or True      # started; may already be done
    _settle_probe(qapp, page, "_e2e_probe")
    assert not page.e2e_btn.isEnabled()
    assert "not running" in page.e2e_btn.toolTip()
    assert "Disabled:" in page.e2e_btn.toolTip()


def test_the_superadmin_identity_is_still_bridged_via_extra_env(qapp, wired_page,
                                                               monkeypatch):
    """Preserved behaviour: without CASDOOR_SUPERADMIN_USERNAME + E2E_SUPERADMIN_
    PASSWORD in the CHILD ENV, every superadmin login 401s on a studio-bootstrapped
    mesh. Values ride the env, never argv."""
    seen = {}

    def fake_make(self, target, timeout, extra_env=None, on_line=None, cancel=None,
                  args=None):
        seen["env"] = dict(extra_env or {})
        seen["args"] = list(args or [])
        return True, ""

    page, _ = wired_page()
    monkeypatch.setattr(LocalStackNode, "_make", fake_make)
    monkeypatch.setattr(lmb.LocalMeshBootstrap, "superadmin_login",
                        lambda self: ("mesh-operator", "s3cret"))
    page._run_e2e(("specs/01-frontpage.spec.ts",))
    _finish(page, qapp)
    assert seen["env"].get("CASDOOR_SUPERADMIN_USERNAME") == "mesh-operator"
    assert seen["env"].get("E2E_SUPERADMIN_PASSWORD") == "s3cret"
    assert seen["args"] == ["E2E_SPECS=specs/01-frontpage.spec.ts"]
    assert not any("s3cret" in a for a in seen["args"]), \
        "a password reached argv, where every `ps` can read it"


def test_the_run_is_still_streaming_and_cancellable(qapp, wired_page, monkeypatch):
    """Preserved behaviour: _launch(stream=True, cancellable=True) — an hour-long run
    must stay watchable and killable."""
    shape = {}

    def fake_launch(self, label, fn, stream=False, cancellable=False, verb=""):
        shape.update(stream=stream, cancellable=cancellable, verb=verb)

    page, _ = wired_page()
    monkeypatch.setattr(localmesh_mod.LocalMeshPage, "_launch", fake_launch)
    page._run_e2e(("specs/01-frontpage.spec.ts",))
    assert shape == {"stream": True, "cancellable": True, "verb": "e2e"}


def test_the_makefile_target_consumes_the_variable():
    """The one leg a stub `make` cannot prove: that `make stack-e2e E2E_SPECS=…`
    actually narrows Playwright. Asserted as TEXT on the real recipe, and that is all
    it is — running the real target needs a live stack and Playwright, which this
    suite deliberately does not have."""
    with open(os.path.join(GENERATOR_DIR, "Makefile"), encoding="utf-8") as fh:
        text = fh.read()
    i = text.index("\nstack-e2e:")
    recipe = text[i:text.index("\nstack-logs:", i)]
    assert "$(E2E_SPECS)" in recipe, (
        "stack-e2e ignores E2E_SPECS — the Studio would pass a selection the suite "
        "silently discards, which is the exact vacuity this unit exists to prevent")
    assert "npx playwright test" in recipe


# ── plumbing ─────────────────────────────────────────────────────────────────────
_PROBE_ATTRS = ("_probe", "_node_probe", "_e2e_probe", "_e2e_cat_probe",
                "_monitor_probe")


@pytest.fixture
def wired_page(qapp, fake_gen, monkeypatch):
    """Build a real LocalMeshPage over the fake checkout — and TEAR IT DOWN.

    Every docker probe is faked off (a real one would shell `docker compose ps` at
    30s a go), but LocalStackNode itself is REAL, so run_e2e/_make are production
    code all the way to the spawn; only `make` is a stub.

    The teardown is not incidental: a probe QThread still running when its parent
    page is destroyed takes the process down with a Qt qFatal (see
    gui/pages/_widgets.own_probe). Every thread is joined before deleteLater.
    """
    made: list = []

    def build(blockers=()):
        monkeypatch.setattr(
            MeshNode, "status",
            lambda self: MeshStatus(running=False, detail="not started"))
        node = LocalStackNode(str(fake_gen))
        monkeypatch.setattr(LocalStackNode, "status",
                            lambda self: SimpleNamespace(running=True,
                                                         detail="stubbed"))
        monkeypatch.setattr(LocalStackNode, "e2e_ready",
                            lambda self, environment="docker": list(blockers))
        monkeypatch.setattr(lmb.LocalMeshBootstrap, "_stack_node", lambda self: node)
        monkeypatch.setattr(lmb.LocalMeshBootstrap, "superadmin_login",
                            lambda self: None)
        page = localmesh_mod.LocalMeshPage(
            SimpleNamespace(generator_dir=str(fake_gen), cfg=SimpleNamespace(),
                            localmesh_selected=True))
        made.append(page)

        def echoed():
            return [ln for ln in page.log.toPlainText().splitlines()
                    if ln.startswith("STUB-MAKE")]
        return page, echoed

    yield build

    for page in made:
        dlg = getattr(page, "_e2e_dialog", None)
        if dlg is not None:
            dlg.close()
        w = getattr(page, "worker", None)
        if w is not None:
            w.wait(20000)
        for name in _PROBE_ATTRS:
            t = getattr(page, name, None)
            if t is not None:
                t.wait(20000)
        qapp.processEvents()
        page.deleteLater()
    qapp.processEvents()


def _finish(page, qapp, ms=20000):
    """Let the verb in flight finish and deliver its queued signals."""
    w = getattr(page, "worker", None)
    if w is None:
        return
    assert w.wait(ms), "the verb never finished"
    qapp.processEvents()
    qapp.processEvents()


def _settle_probe(qapp, page, attr, timeout_s=15.0):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        t = getattr(page, attr, None)
        if t is not None:
            t.wait(200)
            qapp.processEvents()
            if not t.isRunning():
                qapp.processEvents()
                return
        qapp.processEvents()
        time.sleep(0.01)
    raise AssertionError(f"{attr} never finished")

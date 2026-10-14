"""The TUI half of the Go-Live "Export to GitHub org" feature (decision 71 = A: the
text-mode front end offers the same controls as the GUI). Headless and Qt-free,
except the one parity test that imports the GUI page and skips without a binding.

* the image flow's Domains step: ``o N ORG|-`` / ``o own ORG|-`` write the same fields
  the GUI's cell writes, with the same refusal sentence; the column is mesh-only;
* the local-mesh Domains step: ``o N ORG`` on every row, row 1 included, and the
  org reaches ``bootstrap_domain_records``;
* the Go-Live screen: ``x`` is offered only when a domain names an org; the export
  stage plans through the injected runner, applies only on ``apply <org>``, and its
  plan text is ``org_export.plan_lines`` — the GUI step's exact lines.
"""
from __future__ import annotations

import os

import pytest

from hugmesh_studio.core import org_export as oe
from hugmesh_studio.core.golive_domains import NO_EXPORT_DOMAINS_NOTE
from hugmesh_studio.core.local_mesh_domains import bootstrap_domain_records
from hugmesh_studio.tui import domains_step, journey, localmesh

from _org_export_helpers import bare_log, make_world, saved_mesh_naming_the_org

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture
def world(tmp_path):
    return make_world(tmp_path)


def _at_mesh_domains() -> journey.Journey:
    j = journey.Journey(".")
    for line in ("", "3", "", "1", "", "", "", ""):
        # welcome, mesh, idp, worklist row, collect, branding, network, keyzip
        j.feed(line)
    assert j.slug == "domains_choice"
    j.feed("y")
    assert j.slug == "domains"
    return j


# ── the image flow's Domains step ───────────────────────────────────────────────────
def test_mesh_table_carries_the_github_org_column_and_cloud_does_not():
    j = _at_mesh_domains()
    j.feed("a chat.example.org")
    headers, rows = domains_step.domain_table(j.cfg, with_own=True)
    assert headers[-1] == "github org"
    assert rows[0][0] == "own" and rows[0][-1] == "none"
    assert rows[1][-1] == "none"
    text = "\n".join(j.lines())
    assert "o NUMBER|own ORG|-=set its GitHub org" in text
    assert "never a token" in text
    j.cfg.mode = "cloud"
    headers, _rows = domains_step.domain_table(j.cfg)
    assert "github org" not in headers


def test_o_sets_clears_and_refuses_with_the_configs_sentence():
    j = _at_mesh_domains()
    j.feed("a chat.example.org")
    j.feed("o 1 ExampleOrg")
    assert j.cfg.domains[0].github_org == "exampleorg"           # case folded, as the GUI
    assert "GitHub org -> exampleorg" in j.status
    _h, rows = domains_step.domain_table(j.cfg)
    assert rows[0][-1] == "exampleorg"
    j.feed("o 1 -bad-")
    assert "not a GitHub org slug" in j.status
    assert j.cfg.domains[0].github_org == "exampleorg"           # the bad one is not written
    j.feed("o 1 " + "a" * 40)
    assert "longer than 39" in j.status
    j.feed("o 1 -")
    assert j.cfg.domains[0].github_org == "" and "none (not exported)" in j.status
    j.feed("o 7 x")
    assert "no such domain row" in j.status
    j.feed("o 1")
    assert "needs an org slug" in j.status


def test_o_own_writes_the_own_domains_field_and_the_manifest_carries_it():
    j = _at_mesh_domains()
    j.feed("o own exampleorg")
    assert j.cfg.cluster_domain_github_org == "exampleorg"
    _h, rows = domains_step.domain_table(j.cfg, with_own=True)
    assert rows[0][-1] == "exampleorg"
    assert j.cfg.mesh_manifest()["cluster_domain_github_org"] == "exampleorg"
    assert j.cfg.to_dict()["cluster_domain_github_org"] == "exampleorg"
    j.feed("o own -")
    assert j.cfg.cluster_domain_github_org == ""
    assert "cluster_domain_github_org" not in j.cfg.to_dict()


# ── the local-mesh Domains step ─────────────────────────────────────────────────────
def _at_localmesh_domains(*added) -> journey.Journey:
    j = journey.Journey(".")
    j.feed("")                     # welcome -> mode
    j.feed("1")                    # Local Docker mesh
    assert j.slug == "localmesh"
    j.feed("2")                    # Generate a new mesh
    assert j.screen().stage == "domains"
    for name in added:
        j.feed(f"a {name}")
    return j


def test_local_mesh_o_works_on_every_row_including_the_own_row():
    j = _at_localmesh_domains("chat.example.org")
    screen = j.screen_for("localmesh")
    md = screen.state(j)
    headers, rows = screen.table(j)
    assert headers[-1] == "github org" and rows[0][-1] == "none"
    assert "o NUMBER ORG|-=set its GitHub org (row 1 too)" in "\n".join(j.lines())
    j.feed("o 1 exampleorg")                                   # the own row
    assert md.domains[0].github_org == "exampleorg"
    j.feed("o 2 otherorg")
    assert md.domains[1].github_org == "otherorg"
    j.feed("o 2 not valid")
    assert "not a GitHub org slug" in j.status and md.domains[1].github_org == "otherorg"
    _h, rows = screen.table(j)
    assert [r[-1] for r in rows] == ["exampleorg", "otherorg"]
    recs = bootstrap_domain_records(md.domains, md.own_name)
    assert recs[0]["name"] == md.own_name and recs[0]["github_org"] == "exampleorg"
    assert recs[1]["github_org"] == "otherorg"
    j.feed("o 1 -")
    assert md.domains[0].github_org == ""
    # without an org the own row is not recorded: emission neutrality as before
    assert bootstrap_domain_records(md.domains, md.own_name)[0]["name"] == "chat.example.org"


# ── the Go-Live screen's export stage ───────────────────────────────────────────────
def _golive_at_plan(world):
    j = journey.Journey(GENERATOR_DIR)
    j.goto("golive")
    screen = j.screen()
    screen.export_runner = world["runner"]
    screen.export_remote_base = f"file://{world['gh_root']}/"
    screen.stage = "plan"
    screen.opts.provider, screen.opts.domain = "byo-domain", "mesh.example"
    return j, screen


def test_x_is_offered_only_when_a_domain_names_an_org(world):
    j, screen = _golive_at_plan(world)
    assert "x=export" not in "\n".join(j.lines())
    j.feed("x")
    assert j.status == NO_EXPORT_DOMAINS_NOTE and screen.stage == "plan"
    saved_mesh_naming_the_org(world)
    assert "x=export to a GitHub org (1 domain name one)" in "\n".join(j.lines())
    j.feed("x")
    assert screen.stage == "export"
    text = "\n".join(j.lines())
    assert "1. mesh.example -> exampleorg  (saved mesh exported mesh)  <- picked" in text
    assert "python3 -m hugmesh_studio --org-export PLAN" in text
    assert "apply ORG=apply (type the org name)" in text
    j.feed("b")
    assert screen.stage == "plan"


def test_export_plans_through_the_runner_and_applies_only_on_the_typed_org(world):
    saved_mesh_naming_the_org(world)
    j, screen = _golive_at_plan(world)
    j.feed("x")
    j.feed("apply exampleorg")
    assert j.status == "plan first (p)"
    j.feed("p")
    assert screen.export_plan is not None, j.status
    assert not screen.export_plan.blocked
    assert "planned; nothing created or pushed" in j.status
    assert screen.export_plan_lines() == oe.plan_lines(screen.export_plan)
    text = "\n".join(j.lines())
    assert "exampleorg/example-actions" in text and "mesh.example.github.io" in text
    assert not os.path.isdir(os.path.join(world["gh_root"], "exampleorg"))
    j.feed("apply nope")
    assert "type the org name exactly" in j.status
    assert not os.path.isdir(os.path.join(world["gh_root"], "exampleorg"))
    j.feed("apply ExampleOrg")
    assert j.status.startswith("applied: 7 done, 0 skipped"), j.status
    assert len(bare_log(world, "example-actions")) == 1
    assert len(bare_log(world, "mesh.example.github.io")) == 1
    assert "Result file:" in "\n".join(j.lines())
    # the visibility / existing-repository choices are the GUI's two pickers
    j.feed("v public")
    assert screen.export_visibility == "public" and screen.export_plan is None
    j.feed("u branch")
    assert screen.export_update == oe.UPDATE_BRANCH
    j.feed("v nope")
    assert "visibility must be one of" in j.status


def test_the_own_domains_selected_services_reach_the_tui_plan(world):
    """The text-mode twin of the GUI test: the own domain's phpbb selection puts
    hugmesh-forum-api on the plan (as 'missing source' in the test world)."""
    saved_mesh_naming_the_org(world, services=["phpbb"])
    j, screen = _golive_at_plan(world)
    j.feed("x")
    j.feed("p")
    assert screen.export_plan is not None, j.status
    assert screen.export_plan.config.optional_services == ["phpbb"]
    text = "\n".join(j.lines())
    assert "exampleorg/example-forum-api" in text
    forum = next(r for r in screen.export_plan.repos if r.source == "hugmesh-forum-api")
    assert forum.action == "missing source"
    j.feed("apply exampleorg")
    assert not os.path.isdir(os.path.join(world["gh_root"], "exampleorg"))


def test_a_config_file_can_be_added_with_c(world, tmp_path):
    import json
    cfg_path = tmp_path / "export.json"
    cfg_path.write_text(json.dumps(world["cfg"].to_dict()))
    j, screen = _golive_at_plan(world)
    j.feed("x")                                   # refused: nothing names an org yet
    assert screen.stage == "plan"
    screen.stage = "export"
    j.feed(f"c {cfg_path}")
    assert len(screen.export_candidates(j)) == 1
    assert "config file export.json" in "\n".join(j.lines())
    j.feed(f"c {tmp_path / 'missing.json'}")
    assert "missing.json" in j.status


def test_a_config_files_rules_reach_the_tui_plan_and_r_merges_a_rename_map(world, tmp_path):
    """The TUI's `c FILE` door kept only domain/org/source, so `p` planned a generic
    config file's DEFAULTS (correctness skeptic B4). Now the file's own visibility
    and update seed `v`/`u`, `p` honours include_generator / skip_repos / exclude,
    the terminal line hands the file over as --config, and `r FILE` merges an extra
    rename map (`r -` drops it) — the TUI's spelling of the GUI's Rename map field."""
    import json
    cfg = world["cfg"]
    cfg.visibility = "public"
    cfg.update = oe.UPDATE_BRANCH
    cfg.rename_map = oe.merge_rename_maps({}, {"exclude": ["hugmesh-actions:Dockerfile"]})
    cfg_path = tmp_path / "export.json"
    cfg_path.write_text(json.dumps(cfg.to_dict()))
    j, screen = _golive_at_plan(world)
    screen.stage = "export"
    j.feed(f"c {cfg_path}")
    assert screen.export_visibility == "public" and screen.export_update == oe.UPDATE_BRANCH
    text = "\n".join(j.lines())
    assert f"--config {cfg_path} --domain mesh.example" in text and "--org " not in text
    assert "r FILE|-=rename map" in text
    j.feed("p")
    assert screen.export_plan is not None, j.status
    targets = [r.target for r in screen.export_plan.repos]
    assert targets == ["example-actions", "example-parent", "example-commons"]
    actions = next(r for r in screen.export_plan.repos if r.source == "hugmesh-actions")
    assert "Dockerfile: excluded by the rename map" in actions.excluded
    assert screen.export_plan.config.visibility == "public"
    # r FILE: merged over the file's own map; the plan is dropped until re-made
    rm = tmp_path / "extra.json"
    rm.write_text(json.dumps({"repos": {"hugmesh-commons": "example-core"},
                              "exclude": ["hugmesh-parent:LICENSE"]}))
    j.feed(f"r {rm}")
    assert screen.export_rename_map == str(rm) and screen.export_plan is None
    assert f"--rename-map {rm}" in "\n".join(j.lines())
    j.feed("p")
    targets = [r.target for r in screen.export_plan.repos]
    assert "example-core" in targets and "example-commons" not in targets
    parent = next(r for r in screen.export_plan.repos if r.source == "hugmesh-parent")
    assert "LICENSE: excluded by the rename map" in parent.excluded
    actions = next(r for r in screen.export_plan.repos if r.source == "hugmesh-actions")
    assert "Dockerfile: excluded by the rename map" in actions.excluded    # both maps apply
    # a file that cannot be read is refused on the status line and nothing changes
    j.feed(f"r {tmp_path / 'nope.json'}")
    assert "nope.json" in j.status and screen.export_rename_map == str(rm)
    j.feed("r")
    assert "r needs a rename-map FILE" in j.status
    j.feed("r -")
    assert screen.export_rename_map == "" and screen.export_plan is None
    assert "--rename-map" not in "\n".join(j.lines())


def test_a_banned_marker_is_cleared_from_the_tui_with_r(world, tmp_path):
    """The whole remedy a person gets in the TUI: a planted marker blocks one
    repository (BLOCKED names the file), apply is refused; `r FILE` with an exclude
    rule unblocks it on the next `p`."""
    import json
    from _org_export_helpers import git as _git
    token = "github_pat_" + "11FAKE" + "A" * 30
    src = os.path.join(world["src"], "hugmesh-commons")
    os.makedirs(os.path.join(src, "tests"), exist_ok=True)
    with open(os.path.join(src, "tests", "fake-token.sh"), "w", encoding="utf-8") as fh:
        fh.write(f"TOKEN={token}\n")
    _git(src, "add", "-A")
    _git(src, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "plant")
    cfg_path = tmp_path / "export.json"
    cfg_path.write_text(json.dumps(world["cfg"].to_dict()))
    j, screen = _golive_at_plan(world)
    screen.stage = "export"
    j.feed(f"c {cfg_path}")
    j.feed("p")
    assert "plan blocked" in j.status and screen.export_plan.blocked
    text = "\n".join(j.lines())
    assert "BLOCKED" in text and "tests/fake-token.sh: GitHub fine-grained token" in text
    j.feed("apply exampleorg")
    assert "the plan is blocked" in j.status
    assert not os.path.isdir(os.path.join(world["gh_root"], "exampleorg"))
    rm = tmp_path / "unblock.json"
    rm.write_text(json.dumps({"exclude": ["hugmesh-commons:tests/fake-token.sh"]}))
    j.feed(f"r {rm}")
    j.feed("p")
    assert "planned; nothing created or pushed" in j.status and not screen.export_plan.blocked
    assert not os.path.isdir(os.path.join(world["gh_root"], "exampleorg"))


def test_the_gui_step_and_the_tui_stage_show_the_same_plan_text(world, tmp_path):
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding installed")
    from hugmesh_studio.gui.pages import golive as gui_golive
    from hugmesh_studio.gui.qt import QtWidgets
    qapp = QtWidgets.QApplication.instance() or QtWidgets.QApplication(["parity"])
    saved_mesh_naming_the_org(world)
    j, screen = _golive_at_plan(world)
    j.feed("x")
    j.feed("p")
    w = gui_golive.GoLiveWizard(GENERATOR_DIR)
    w.export_runner = world["runner"]
    w.export_remote_base = f"file://{world['gh_root']}/"
    page = w.page(w._page_ids["org-export"])
    page.initializePage()
    assert page.source.currentText() == screen.export_candidates(j)[0].label()
    gui_cfg = page.export_config()
    tui_cfg = screen.export_config(j)
    assert gui_cfg.to_dict() == tui_cfg.to_dict()
    # the same plan (same stamp) renders the same lines on both faces
    gui_plan = oe.plan(gui_cfg, world["runner"], stamp=screen.export_plan.stamp)
    page._planned(("ok", gui_plan))
    qapp.processEvents()
    assert page.plan_text.toPlainText().splitlines() == screen.export_plan_lines()
    w.deleteLater()

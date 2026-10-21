"""Saved meshes that NEVER RAN (drafts) and the readers that must not mistake them
for the mesh that did — the fix round on the "save the mesh being worked on" lane.

Since the Saved meshes list saves a mesh with nothing up, a record can be a DRAFT.
The node-image pages ("Create nodes for local cloud", GUI and TUI) import the local
mesh's domain, accounts and Tor from a saved record; before this round they took
the NEWEST record, so a draft saved after the real mesh replaced its domain and
turned Tor off in the node images. These pin:

* ``SavedMesh.ran_when_saved`` (legacy records with no facts count as ran);
* ``records_for_checkout`` order and ``latest_for_checkout(ran_only=True)``;
* ``LocalMeshBootstrap.for_checkout`` picks the newest record that RAN, falls back
  to a draft only when nothing ran, and honours an explicit ``record_id``;
* ``saved_mesh_source`` says NEVER RAN for a draft;
* the CLI ``mesh-save``: saves with nothing running, refuses a credential copy
  then, refuses a taken name, and ``--overwrite`` keeps the id;
* ``config_changes`` does not call an unrecorded (None) services/add-on choice a
  change.

Nothing here shells out: the stack node is a stand-in and the volume inventory is
faked. The Studio state dir is the autouse tmp dir.
"""
from __future__ import annotations

import json
import os
import socket
from types import SimpleNamespace

import pytest

from hugmesh_studio.core import local_mesh_bootstrap as lmb
from hugmesh_studio.core import saved_meshes as sm
from hugmesh_studio.core import vaults

GEN = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


class _Node:
    web_url = "https://localhost:8488"
    plain_web_url = "http://localhost:8088"

    def __init__(self, running=False, kind=False):
        self.running = running
        self.kind = kind

    def _build_env(self, extra_env=None, *, write_overlays=True):
        return dict(os.environ, ENV="test")

    def status(self):
        return SimpleNamespace(running=self.running)

    def running_env(self):
        return "test" if self.running else ""

    def onion_url(self):
        return ""

    def devops_running(self):
        return self.kind


class _Boot:
    secrets_json = ""

    def superadmin_login(self):
        return None


@pytest.fixture(autouse=True)
def _no_docker(monkeypatch):
    monkeypatch.setattr(vaults, "list_volumes", lambda *a, **k: [])
    monkeypatch.setattr(sm, "_repo_rows", lambda root: [])


def _cfg(domain, tor):
    return lmb.LocalMeshBootstrapConfig(
        cluster_domain=domain, services=("tor",) if tor else (), kind_addons=(),
        with_tor=tor)


def _save(domain, tor, *, running, label, updated, kind=None):
    rec = sm.capture(GEN, _cfg(domain, tor), _Node(running), _Boot(), label=label,
                     kind_running=kind)
    path = sm.save(rec)
    assert path
    # save() stamps `updated` with now; pin it so the order is the test's, not the
    # clock's
    with open(path, encoding="utf-8") as fh:
        d = json.load(fh)
    d["updated"] = updated
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(d, fh)
    return sm.load(path)


# ── the record's own fact ───────────────────────────────────────────────────────
def test_ran_when_saved_reads_the_facts_and_legacy_records_count_as_ran():
    up = _save("up.example", True, running=True, label="up",
               updated="2026-10-01T10:00:00+00:00")
    draft = _save("draft.example", False, running=False, label="draft",
                  updated="2026-10-02T10:00:00+00:00")
    kind = _save("kind.example", False, running=False, label="kind", kind=True,
                 updated="2026-10-03T10:00:00+00:00")
    assert up.ran_when_saved() is True
    assert draft.ran_when_saved() is False
    assert kind.ran_when_saved() is True          # the DevOps lane counts as up
    legacy = sm.SavedMesh.from_dict({"id": "x", "last_seen": {}})
    assert legacy.ran_when_saved() is True        # no facts: predates the field


def test_records_for_checkout_lists_the_ones_that_ran_first_each_newest_first():
    a = _save("a.example", False, running=True, label="a",
              updated="2026-10-01T10:00:00+00:00")
    b = _save("b.example", False, running=False, label="b",
              updated="2026-10-05T10:00:00+00:00")
    c = _save("c.example", False, running=True, label="c",
              updated="2026-10-03T10:00:00+00:00")
    order = [r.id for r in sm.records_for_checkout(GEN)]
    assert order == [c.id, a.id, b.id]
    assert sm.latest_for_checkout(GEN).id == b.id
    assert sm.latest_for_checkout(GEN, ran_only=True).id == c.id


# ── THE BLOCKER: a newer draft must not replace the mesh that ran ──────────────
def test_a_newer_draft_never_stands_in_for_the_mesh_that_ran():
    ran = _save("running.example", True, running=True, label="the mesh that ran",
                updated="2026-10-20T10:00:00+00:00")
    _save("draft.example", False, running=False, label="draft, never run",
          updated="2026-10-21T10:00:00+00:00")
    boot, rec = lmb.LocalMeshBootstrap.for_checkout(GEN)
    assert rec is not None and rec.id == ran.id
    assert boot.cfg.resolved_domain() == "running.example"
    assert boot.cfg.effective_with_tor() is True
    assert "NEVER RAN" not in lmb.saved_mesh_source(rec)


def test_with_only_drafts_the_newest_draft_is_used_and_says_it_never_ran():
    _save("old-draft.example", False, running=False, label="old draft",
          updated="2026-10-20T10:00:00+00:00")
    new = _save("new-draft.example", False, running=False, label="new draft",
                updated="2026-10-21T10:00:00+00:00")
    boot, rec = lmb.LocalMeshBootstrap.for_checkout(GEN)
    assert rec.id == new.id
    src = lmb.saved_mesh_source(rec)
    assert "NEVER RAN" in src and "new draft" in src
    assert "never ran" in lmb.saved_mesh_choice_text(rec)


def test_an_explicit_record_id_wins_and_an_unknown_one_falls_back():
    ran = _save("running.example", True, running=True, label="ran",
                updated="2026-10-20T10:00:00+00:00")
    draft = _save("draft.example", False, running=False, label="draft",
                  updated="2026-10-21T10:00:00+00:00")
    boot, rec = lmb.LocalMeshBootstrap.for_checkout(GEN, record_id=draft.id)
    assert rec.id == draft.id and boot.cfg.resolved_domain() == "draft.example"
    boot, rec = lmb.LocalMeshBootstrap.for_checkout(GEN, record_id="no-such-id")
    assert rec.id == ran.id


def test_both_node_image_faces_import_the_mesh_that_ran(monkeypatch):
    """The skeptic's repro (node_import.py) through the GUI and the TUI readers."""
    pytest.importorskip("hugmesh_studio.gui.qt")
    from hugmesh_studio.gui.pages import localcloud_nodes as gui_nodes
    from hugmesh_studio.tui import localcloud as tui_nodes
    _save("running.example", True, running=True, label="the mesh that is running",
          updated="2026-10-20T10:00:00+00:00")
    draft = _save("draft.example", False, running=False, label="draft, never run",
                  updated="2026-10-21T10:00:00+00:00")
    for mod in (gui_nodes, tui_nodes):
        ident = mod.local_mesh_identity(GEN)
        assert (ident.domain, ident.with_tor) == ("running.example", True), mod
        assert "the mesh that is running" in ident.source
        picked = mod.local_mesh_identity(GEN, record_id=draft.id)
        assert (picked.domain, picked.with_tor) == ("draft.example", False), mod
        assert "NEVER RAN" in picked.source


# ── the CLI matches the GUI ─────────────────────────────────────────────────────
@pytest.fixture
def cli_node(monkeypatch):
    node = _Node(running=False)
    monkeypatch.setattr(lmb.LocalMeshBootstrap, "_stack_node", lambda self: node)
    return node


def _cli(*argv):
    return lmb.main(["mesh-save", "--generator-dir", GEN, *argv])


def test_cli_mesh_save_records_a_draft_with_nothing_running(cli_node, capsys):
    assert _cli("--cluster-domain", "draft.example", "--label", "cli draft") == 0
    out = capsys.readouterr().out
    assert "running at save time: nothing" in out and "DRAFT" in out
    (rec,) = sm.scan()[0]
    assert rec.label == "cli draft" and rec.ran_when_saved() is False
    assert rec.last_seen["kind_running"] is False      # the CLI asks the lane


def test_cli_refuses_a_credential_copy_with_nothing_running(cli_node, capsys):
    assert _cli("--copy-credentials") == 1
    assert "needs the local mesh to be running" in capsys.readouterr().err
    assert sm.scan()[0] == []


def test_cli_refuses_a_taken_name_and_overwrite_keeps_the_id(cli_node, capsys):
    assert _cli("--cluster-domain", "one.example", "--label", "Lab") == 0
    (first,) = sm.scan()[0]
    assert _cli("--cluster-domain", "two.example", "--label", "lab") == 1
    assert f"--overwrite {first.id}" in capsys.readouterr().err
    cli_node.running = True
    assert _cli("--cluster-domain", "two.example", "--overwrite", first.id) == 0
    assert "overwrote 'Lab'" in capsys.readouterr().out
    (again,) = sm.scan()[0]
    assert again.id == first.id and again.created == first.created
    assert again.config["cluster_domain"] == "two.example"
    assert again.ran_when_saved() is True
    assert _cli("--overwrite", "no-such-id") == 1
    assert "no saved mesh with id no-such-id" in capsys.readouterr().err


def test_cli_derives_a_unique_name_when_none_is_given(cli_node):
    assert _cli("--cluster-domain", "a.example") == 0
    assert _cli("--cluster-domain", "a.example") == 0
    labels = sorted(r.label for r in sm.scan()[0])
    assert len(set(labels)) == 2 and labels[1].endswith("(2)")


# ── an old record does not read as changed the moment it is loaded ─────────────
def test_an_unrecorded_choice_is_not_a_change_but_is_named_for_an_overwrite():
    saved = lmb.LocalMeshBootstrapConfig(cluster_domain="old.example",
                                         services=("tor",), kind_addons=None,
                                         with_tor=True).to_dict()
    form = dict(saved, kind_addons=["metrics-server"])
    # the record the form was loaded from: an unrecorded choice is no change
    assert sm.config_changes(saved, form, unrecorded_ok=True) == []
    # any other comparison stays strict: that record never chose, the form did
    assert sm.config_changes(saved, form) == ["kind_addons"]
    assert sm.unrecorded_fields(saved) == ["kind_addons"]
    # a RECORDED choice counts either way
    rec_saved = dict(saved, kind_addons=[])
    assert sm.config_changes(rec_saved, form, unrecorded_ok=True) == ["kind_addons"]
    assert sm.unrecorded_fields(rec_saved) == []
    # and a record from disk loads the same way
    raw = json.loads(json.dumps(saved))
    assert sm.config_changes(raw, form, unrecorded_ok=True) == []


# ── node domain config: a saved mesh's per-domain settings reach the node images
# and survive the image flow's own Save config / Load config ──────────────────────
def test_per_domain_settings_go_from_a_saved_mesh_into_a_saved_node_config(tmp_path):
    from hugmesh_studio.core.config import ImageConfig
    from hugmesh_studio.core.local_mesh_domains import (apply_imported_domains,
                                                         imported_mesh_domains)
    row_b = {"name": "b.example", "title": "Bee", "idp": "own",
             "optional_services": ["tuwunel"],
             "idp_settings": {"provider": "oidc", "issuer": "https://id.b.example",
                              "client_id": "bee-web"},
             "look": {"primary": "#123456", "mode": "dark"},
             "ways": {"tailnet": True,
                      "egress": {"mode": "vpn", "conf": "/etc/hugmesh/b-egress.conf"}},
             "tor": True}
    cfg = lmb.LocalMeshBootstrapConfig(
        cluster_domain="a.example", services=("tor",), kind_addons=(), with_tor=True,
        social=True, domains=(dict(row_b),), domain_services_reviewed=("b.example",))
    rec = sm.capture(GEN, cfg, _Node(True), _Boot(), label="per-domain")
    assert sm.save(rec)
    boot, got = lmb.LocalMeshBootstrap.for_checkout(GEN)
    assert got.id == rec.id
    image = ImageConfig()
    image.cluster_domain = boot.cfg.resolved_domain()
    apply_imported_domains(image, imported_mesh_domains(boot.cfg))
    path = str(tmp_path / "node-image.json")
    image.save(path)
    back = ImageConfig.load(path)
    b = next(d for d in back.domains if d.name == "b.example")
    assert b.idp_settings == row_b["idp_settings"]
    assert b.look == row_b["look"]
    assert b.ways == row_b["ways"]
    assert b.tor is True and b.optional_services == ["tuwunel"]

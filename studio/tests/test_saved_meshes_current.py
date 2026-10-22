"""core/saved_meshes.py — saving the mesh being WORKED ON (operator, 2026-10-21).

"Saved meshes screen does not give anywhere to save the mesh we just started working
on." These pin the Qt-free half of the fix: a capture with nothing running, an
OVERWRITE that keeps the record's id and place, the stale credential copies an
overwrite leaves behind, unique names, the "is the form saved already?" compare, and
the per-domain lines (look, sign-in, services, VPN/egress) a record carries.

Nothing here shells out: the stack node is a stand-in and the volume inventory is
faked, the way test_saved_meshes.py does it. The Studio state dir is the autouse
tmp dir.
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
    """Nothing running: what a mesh being worked on looks like before its first up."""
    web_url = "https://localhost:8488"
    plain_web_url = "http://localhost:8088"

    def __init__(self, running=False):
        self.running = running

    def _build_env(self, extra_env=None, *, write_overlays=True):
        return dict(os.environ, ENV="test")

    def status(self):
        return SimpleNamespace(running=self.running)

    def running_env(self):
        return "test" if self.running else ""

    def onion_url(self):
        return ""


class _Boot:
    secrets_json = ""

    def superadmin_login(self):
        return None


@pytest.fixture(autouse=True)
def _no_docker(monkeypatch):
    monkeypatch.setattr(vaults, "list_volumes", lambda *a, **k: [])
    monkeypatch.setattr(sm, "_repo_rows", lambda root: [])


#: a domain row that carries EVERY per-domain setting the operator asked to keep
_ROW_B = {"name": "b.example", "title": "Bee", "idp": "own",
          "optional_services": ["tuwunel"],
          "idp_settings": {"provider": "oidc", "issuer": "https://id.b.example",
                           "client_id": "bee-web"},
          "look": {"primary": "#123456", "mode": "dark"},
          "ways": {"tailnet": True,
                   "egress": {"mode": "vpn", "conf": "/etc/hugmesh/b-egress.conf"}},
          "tor": True}
_ROW_C = {"name": "c.example", "title": "", "idp": "own", "optional_services": []}


def _cfg(**over) -> lmb.LocalMeshBootstrapConfig:
    # social/with_tor agree with what runs (tor mesh-wide, tuwunel on b.example):
    # from_dict normalises them from the selection, so a config that disagreed
    # would not round-trip for a reason that has nothing to do with saving
    kw = dict(cluster_domain="a.example", services=("tor",), kind_addons=(),
              social=True, with_tor=True,
              domains=(dict(_ROW_B), dict(_ROW_C)),
              domain_services_reviewed=("b.example",))
    kw.update(over)
    return lmb.LocalMeshBootstrapConfig(**kw)


def _capture(cfg, **kw):
    return sm.capture(GEN, cfg, _Node(), _Boot(), **kw)


# ── a capture with NOTHING running ─────────────────────────────────────────────
def test_a_mesh_that_never_ran_can_be_captured_and_says_what_it_is():
    rec = _capture(_cfg(), kind_running=False)
    assert rec.last_seen["compose_running"] is False
    assert rec.last_seen["kind_running"] is False
    assert any("configuration as it was being worked on" in n for n in rec.notes)
    assert any("neither was the DevOps lane" in n for n in rec.notes)
    assert rec.volumes["included"] is False and rec.volumes["inventory"] == []
    assert sm.save(rec)


def test_the_kind_lane_state_is_recorded_as_given_never_probed():
    assert _capture(_cfg(), kind_running=True).last_seen["kind_running"] is True
    rec = _capture(_cfg())
    assert rec.last_seen["kind_running"] is None
    # kind unknown: the record does not claim the DevOps lane was down
    assert not any("neither was the DevOps lane" in n for n in rec.notes)
    up = _capture(_cfg(), kind_running=True)
    assert not any("configuration as it was being worked on" in n for n in up.notes)


# ── everything per domain survives the record ──────────────────────────────────
def test_every_per_domain_setting_round_trips_through_the_record_file():
    cfg = _cfg()
    rec = _capture(cfg)
    path = sm.save(rec)
    back = sm.load(path)
    got = lmb.LocalMeshBootstrapConfig.from_dict(back.config)
    rows = {r["name"]: r for r in got.domains}
    b = rows["b.example"]
    assert b["look"] == _ROW_B["look"]
    assert b["ways"] == _ROW_B["ways"]
    assert b["idp_settings"] == _ROW_B["idp_settings"]
    assert b["optional_services"] == ["tuwunel"] and b["tor"] is True
    assert b["idp"] == "own" and b["title"] == "Bee"
    assert got.domain_services_reviewed == ("b.example",)
    # the whole config, not just the row: what was saved is what loads
    want = cfg.to_dict()
    want["auth_key"] = ""
    assert got.to_dict() == want


def test_domain_lines_name_look_sign_in_services_and_reach():
    lines = sm.domain_lines_of(_cfg().to_dict())
    assert lines[0].startswith("a.example — this mesh's own domain")
    b = next(ln for ln in lines if ln.startswith("b.example"))
    assert "its own sign-in through" in b
    assert "services: tuwunel" in b
    assert "look: mode=dark, primary=#123456" in b
    assert "VPN: on" in b and "outbound: vpn (b-egress.conf)" in b
    assert "its own Tor front door" in b
    c = next(ln for ln in lines if ln.startswith("c.example"))
    assert "its own Casdoor" in c and "services: none chosen" in c
    # the screen word is "sign-in", never the protocol word
    assert not any("issuer" in ln.lower() for ln in lines)
    assert sm.domain_lines_of(lmb.LocalMeshBootstrapConfig().to_dict()) == []


def test_services_text_reads_what_the_mesh_runs_not_the_mesh_wide_half():
    """``services`` holds only the mesh-wide half since the per-domain screens became
    the one source; a record whose domains run tuwunel read "tor" (or "none")."""
    rec = sm.SavedMesh(config=_cfg().to_dict())
    text = rec.services_text()
    assert "tuwunel" in text and "tor" in text
    none = sm.SavedMesh(config=lmb.LocalMeshBootstrapConfig().to_dict())
    assert none.services_text() == "(picker unused — profile defaults)"
    explicit = sm.SavedMesh(config=lmb.LocalMeshBootstrapConfig(services=()).to_dict())
    assert explicit.services_text() == "none (explicit)"
    assert "2 service(s)" in sm.derived_label_of(_cfg().to_dict())


# ── overwrite ────────────────────────────────────────────────────────────────────
def test_an_overwrite_keeps_the_id_the_place_and_the_created_stamp():
    first = _capture(_cfg(), label="mine")
    first.created = "2026-10-01T10:00:00-07:00"
    assert sm.save(first)
    changed = _cfg(env="prod", cluster_domain="z.example")
    second = _capture(changed, overwrite=first)
    assert second.id == first.id
    assert second.created == first.created
    assert second.label == "mine"                    # kept unless a name is given
    assert sm.save(second) == first.path()
    recs, bad = sm.scan()
    assert [r.id for r in recs] == [first.id] and not bad
    assert recs[0].config["env"] == "prod"
    assert _capture(changed, overwrite=first, label="renamed").label == "renamed"


def test_an_overwrite_refuses_a_record_whose_id_can_walk():
    bad = sm.SavedMesh(id="../../escape", label="x")
    with pytest.raises(ValueError):
        _capture(_cfg(), overwrite=bad)


def test_stale_credential_copies_go_when_the_new_record_keeps_pointers_only():
    old = _capture(_cfg(), label="had copies")
    os.makedirs(old.copy_dir(), mode=0o700)
    copy = os.path.join(old.copy_dir(), "e2e-credentials")
    with open(copy, "w") as fh:
        fh.write("secret")
    old.credentials["e2e_file"] = {"copied": True, "copy": f"{old.id}/e2e-credentials"}
    assert sm.save(old)
    # a record that DECLARES its copy keeps the dir
    assert sm.drop_unreferenced_copies(old) is False and os.path.isfile(copy)
    new = _capture(_cfg(), overwrite=old)
    assert sm.save(new)
    assert not new.has_credential_copies()
    assert sm.drop_unreferenced_copies(new) is True
    assert not os.path.exists(old.copy_dir())
    # nothing outside the record's own dir is ever a candidate
    stray = sm.SavedMesh(id="..", label="x")
    assert sm.drop_unreferenced_copies(stray) is False


# ── is the form saved already? ───────────────────────────────────────────────────
def test_config_changes_compares_as_loaded_and_ignores_the_auth_key():
    saved = sm.config_for_record(_cfg())
    assert sm.config_changes(saved, sm.config_for_record(_cfg(auth_key="tskey-x"))) == []
    assert sm.config_changes(saved, sm.config_for_record(_cfg(env="prod"))) == ["env"]
    # a pre-migration record (domain slugs in `services`) compares as it LOADS
    legacy = sm.config_for_record(lmb.LocalMeshBootstrapConfig(
        cluster_domain="a.example", services=("tuwunel",), kind_addons=()))
    migrated = sm.config_for_record(lmb.LocalMeshBootstrapConfig.from_dict(legacy))
    assert sm.config_changes(legacy, migrated) == []
    assert "auth_key" not in sm.config_for_record(_cfg(auth_key="tskey-x")).values()


# ── names ─────────────────────────────────────────────────────────────────────────
def test_names_are_unique_and_the_owner_is_found_case_blind():
    a = sm.SavedMesh(id="1", label="Lab mesh")
    b = sm.SavedMesh(id="2", label="lab mesh (2)")
    assert sm.label_owner("  lab MESH ", [a, b]) is a
    assert sm.label_owner("lab mesh", [a, b], exclude_id="1") is None
    assert sm.label_owner("", [a]) is None
    assert sm.unique_label("Lab mesh", [a, b]) == "Lab mesh (3)"
    assert sm.unique_label("other", [a, b]) == "other"


def test_a_record_saved_with_nothing_running_does_not_offer_a_warm_start():
    """The plan decides from the machine as it is: no inventory means no Start, and a
    Restore of a mesh whose credentials were never minted refuses in boot.restore
    (\"use 'Generate && start'\") — the record never promises otherwise."""
    rec = _capture(_cfg())
    plan = sm.restore_plan(rec, volumes_present=False, images_present=False,
                           creds_match=False, mesh_running=False)
    assert plan.mode == sm.MODE_RESEED and not plan.can_start()
    assert json.loads(json.dumps(rec.to_dict()))["config"]["auth_key"] == ""
    assert rec.hostname == socket.gethostname()


def test_a_never_run_record_says_what_a_restore_would_do_honestly():
    rec = _capture(_cfg())
    assert rec.volume_count() == 0
    rec.credentials["e2e_file"] = {"path": "/nowhere", "sha256": "", "copied": False}
    plan = sm.restore_plan(rec, volumes_present=False, images_present=False,
                           creds_match=False, mesh_running=False)
    assert "no data volumes were recorded" in plan.sentence
    assert "no credential files existed when it was saved" in plan.sentence
    assert "gone" not in plan.sentence and ".onion" not in plan.sentence


def test_restoring_a_never_run_record_refuses_before_any_preflight(tmp_path,
                                                                 monkeypatch):
    """boot.restore asked for the superadmin password only AFTER _prepare (host
    preflight and the m2 self-heal: minutes of docker). A record saved before its
    first bring-up has none, so it now refuses first, from two file reads."""
    rec = _capture(_cfg())
    assert sm.save(rec)
    boot = lmb.LocalMeshBootstrap(GEN, lmb.LocalMeshBootstrapConfig(
        out_dir=str(tmp_path / "keys-out")))
    monkeypatch.setattr(lmb.LocalMeshBootstrap, "guard_host_local",
                        lambda self: (True, ""))
    monkeypatch.setattr(sm, "probe_state", lambda r, project="": {
        "volumes_present": False, "images_present": True, "creds_match": False,
        "mesh_running": False, "source_ok": True, "copies_missing": (),
        "source_drift": (), "volumes_missing": (), "volumes_seen": 0,
        "unanswered": ()})

    def no_prepare(self, *a, **k):
        raise AssertionError("_prepare ran for a restore that cannot seed")
    monkeypatch.setattr(lmb.LocalMeshBootstrap, "_prepare", no_prepare)
    ok, log = boot.restore(rec)
    assert ok is False
    assert any("no superadmin password is available" in ln for ln in log), log
    assert any("Generate && start" in ln for ln in log)


def test_a_record_saved_before_the_whole_look_existed_is_not_changed_by_it():
    """``login_look`` (the mesh's whole look, carried for the domain looks) is derived
    from the look like ``login_theme_css``. A record saved before it existed must not
    read as changed only because the loaded form now carries one; a record that has
    it still compares it, and the stylesheet still catches a real look change."""
    old = lmb.LocalMeshBootstrapConfig(login_theme_css=":root{--sd-primary:#123456}")
    old_dict = old.to_dict()
    old_dict.pop("login_look")
    form = lmb.LocalMeshBootstrapConfig(login_theme_css=":root{--sd-primary:#123456}",
                                        login_look={"primary": "#123456"}).to_dict()
    assert sm.config_changes(old_dict, form, unrecorded_ok=True) == []
    assert sm.config_changes(old_dict, form) == []
    new = dict(form, login_look={"primary": "#654321"})
    assert sm.config_changes(new, form, unrecorded_ok=True) == ["login_look"]
    css_changed = dict(form, login_theme_css=":root{--sd-primary:#000000}")
    assert sm.config_changes(old_dict, css_changed) == ["login_theme_css"]

"""LocalMeshBootstrapConfig.to_dict/from_dict + LocalMeshBootstrap.restore /
start_saved — the core half of the saved-mesh lane (ask C, 2026-09-01).

No Qt, no docker: every subprocess override point is monkeypatched on the bootstrap or the
stack node, exactly as test_local_mesh_bringup.py's ``_happy_boot`` does.
"""
from __future__ import annotations

import argparse
import json
import os

import pytest

from hugmesh_studio.core import saved_meshes as sm
from hugmesh_studio.core.local_mesh_bootstrap import (
    LocalMeshBootstrap, LocalMeshBootstrapConfig, _cfg_from_args)
from hugmesh_studio.core.local_stack_node import LocalStackNode

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
SA_VALUE = "Sa-Pass-77"


def _full_cfg(**over) -> LocalMeshBootstrapConfig:
    base = dict(
        env="prod", superadmin_username="root", out_dir="/tmp/keys", social=True,
        with_tor=True, services=("tuwunel", "tor", "wiki"), egress_vpn_conf="/x.conf",
        auth_key="tskey-1", login_server="https://hs.example.org", node_name="n1",
        brand="acme", cluster_domain="example.org", source_mode="existing",
        source_dir="/src", web_locales=("de", "fr"), login_theme_css=":root{}",
        idp="oidc", idp_issuer="https://id.example.org", idp_client_id="cid",
        idp_jwks="https://id.example.org/jwks", own_idp_domains=("a.org",),
        kind_addons=("metrics-server",),
        # #494: the recorded domain rows — a tuple of JSON objects, the one field
        # whose items are not scalars, so "every field round-trips" has to carry one
        domains=({"name": "a.org", "title": "A", "idp": "own",
                  "optional_services": ["games"]},))
    base.update(over)
    return LocalMeshBootstrapConfig(**base)


# ── round-trip ─────────────────────────────────────────────────────────────────
def test_every_field_round_trips():
    cfg = _full_cfg()
    d = cfg.to_dict()
    assert set(d) == {f for f in LocalMeshBootstrapConfig.__dataclass_fields__}
    assert json.loads(json.dumps(d)) == d          # JSON-shaped: lists, not tuples
    back = LocalMeshBootstrapConfig.from_dict(json.loads(json.dumps(d)))
    assert back == cfg
    assert isinstance(back.services, tuple) and isinstance(back.web_locales, tuple)


@pytest.mark.parametrize("field", ["services", "kind_addons"])
def test_none_and_empty_tuple_are_distinct_in_both_directions(field):
    for value in (None, ()):
        cfg = LocalMeshBootstrapConfig(**{field: value})
        d = json.loads(json.dumps(cfg.to_dict()))
        assert d[field] == (None if value is None else [])
        back = LocalMeshBootstrapConfig.from_dict(d)
        assert getattr(back, field) == value
        assert (getattr(back, field) is None) == (value is None)


def test_from_dict_filters_unknown_keys_and_coerces():
    cfg = LocalMeshBootstrapConfig.from_dict(
        {"env": None, "brand": 7, "social": "yes", "web_locales": None,
         "own_idp_domains": ["a", 2], "future_field": 1})
    assert cfg.env == "" and cfg.brand == "7" and cfg.social is True
    assert cfg.web_locales == () and cfg.own_idp_domains == ("a", "2")
    with pytest.raises(ValueError):
        LocalMeshBootstrapConfig.from_dict("nope")


def test_cli_config_round_trips():
    args = argparse.Namespace(
        env="prod", superadmin_username="root", out="/tmp/k", social=True,
        with_tor=True, services="tuwunel tor", authkey_file="", authkey="tskey-2",
        login_server="https://hs", node_name="n", brand="acme",
        cluster_domain="example.org", source_mode="existing", source_dir="/src",
        web_locales="de, fr", login_primary="#123456", login_secondary="",
        login_font="", idp="oidc", idp_issuer="https://id", idp_client_id="cid",
        idp_jwks="", own_casdoor_domain=["a.org"])
    cfg = _cfg_from_args(args)
    assert cfg.services == ("tuwunel", "tor") and cfg.login_theme_css
    back = LocalMeshBootstrapConfig.from_dict(json.loads(json.dumps(cfg.to_dict())))
    assert back == cfg
    # the absent flag stays None through the round-trip too
    args.services = None
    cfg2 = _cfg_from_args(args)
    assert LocalMeshBootstrapConfig.from_dict(cfg2.to_dict()).services is None


# ── restore / start_saved ──────────────────────────────────────────────────────
_LIVE_OK = {"volumes_present": True, "images_present": True, "creds_match": True,
            "mesh_running": False, "source_ok": True, "copies_missing": (),
            "source_drift": (), "volumes_missing": (), "volumes_seen": 3}


def _boot(monkeypatch, tmp_path):
    boot = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(
        out_dir=str(tmp_path / "keys"), superadmin_username="sa"))
    os.makedirs(boot.vault_dir)
    with open(boot.secrets_json, "w") as fh:
        json.dump({"hugmesh-pki": {"casdoor-superadmin": {
            "username": "sa", "password": SA_VALUE}}}, fh)
    monkeypatch.setattr(boot, "guard_host_local", lambda: (True, ""))
    monkeypatch.setattr(boot, "validate", lambda: [])
    monkeypatch.setattr(boot, "preflight", lambda: [])

    def never(*a, **k):
        raise AssertionError("generate_creds must never run on a restore")
    monkeypatch.setattr(boot, "generate_creds", never)
    # what the machine holds NOW, as start_saved/restore re-decide it on the worker
    # (sm.probe_state is the gatherer; the default says "case 1, nothing running")
    calls = {"start": 0, "seed": [], "facts": dict(_LIVE_OK)}
    monkeypatch.setattr(sm, "probe_state", lambda rec, project="": dict(calls["facts"]))
    monkeypatch.setattr(LocalStackNode, "start",
                        lambda self, on_line=None, cancel=None:
                        (calls.__setitem__("start", calls["start"] + 1)) or (True, "up"))
    monkeypatch.setattr(LocalStackNode, "seed",
                        lambda self, extra_env=None, timeout=600, on_line=None,
                        cancel=None: calls["seed"].append(dict(extra_env or {}))
                        or (True, "seeded"))
    return boot, calls


def _record(boot, *, copied=False, tmp_path=None):
    rec = sm.SavedMesh(id=sm.new_id(), label="saved", generator_dir=GENERATOR_DIR)
    rec.config = boot.cfg.to_dict()
    rec.credentials = {"superadmin_username": "sa",
                       "e2e_file": {"copied": False, "copy": ""},
                       "secrets_json": {"copied": False, "copy": ""}}
    if copied:
        d = rec.copy_dir()
        os.makedirs(d, mode=0o700)
        with open(os.path.join(d, "e2e-credentials"), "w") as fh:
            fh.write("E2E_PASSWORD=from-the-copy\n")
        with open(os.path.join(d, "secrets.json"), "w") as fh:
            json.dump({"hugmesh-pki": {"casdoor-superadmin": {
                "username": "sa", "password": "copy-pass-1"}}}, fh)
        rec.credentials["e2e_file"] = {"copied": True,
                                       "copy": os.path.join(rec.id, "e2e-credentials")}
        rec.credentials["secrets_json"] = {"copied": True,
                                           "copy": os.path.join(rec.id, "secrets.json")}
    return rec


def test_restore_does_not_call_generate_creds(monkeypatch, tmp_path):
    boot, calls = _boot(monkeypatch, tmp_path)
    rec = _record(boot)
    streamed = []
    ok, log = boot.restore(rec, on_line=streamed.append)
    assert ok, log
    assert calls["start"] == 1 and len(calls["seed"]) == 1
    env = calls["seed"][0]
    assert env["CASDOOR_SUPERADMIN_USERNAME"] == "sa"
    assert env["E2E_SUPERADMIN_PASSWORD"] == SA_VALUE     # READ from the bundle, not minted
    assert any("reusing superadmin 'sa'" in l for l in streamed)
    assert any(l.startswith("[done] platform up") for l in streamed)
    assert not any(SA_VALUE in l for l in log + streamed), "a password reached a log line"


def test_restore_uses_the_saved_copies_and_puts_them_back(monkeypatch, tmp_path):
    boot, calls = _boot(monkeypatch, tmp_path)
    # the run-state file lives under the generator dir — redirect it into tmp
    e2e = tmp_path / ".e2e-credentials"
    e2e.write_text("E2E_PASSWORD=minted-later\n")
    monkeypatch.setattr(boot, "e2e_credentials_path", lambda: str(e2e))
    rec = _record(boot, copied=True)
    ok, log = boot.restore(rec, on_line=lambda _l: None)
    assert ok, log
    env = calls["seed"][0]
    assert env["E2E_CREDENTIALS_FILE"] == rec.credential_copies()[0]
    assert env["E2E_SUPERADMIN_PASSWORD"] == "copy-pass-1"
    # put back IN PLACE, so every later seed from the page reads the same file
    assert e2e.read_text() == "E2E_PASSWORD=from-the-copy\n"
    assert json.load(open(boot.secrets_json))["hugmesh-pki"]["casdoor-superadmin"][
        "password"] == "copy-pass-1"
    assert any("put the saved credential file(s) back" in l for l in log)
    assert not any("copy-pass-1" in l or "from-the-copy" in l for l in log)


def test_restore_refuses_when_a_declared_copy_is_missing(monkeypatch, tmp_path):
    boot, calls = _boot(monkeypatch, tmp_path)
    rec = _record(boot, copied=True)
    os.remove(rec.credential_copies()[0])
    ok, log = boot.restore(rec, on_line=lambda _l: None)
    assert not ok
    assert any("refused" in l and "e2e-credentials" in l for l in log)
    assert calls["start"] == 0 and calls["seed"] == []


def test_restore_refuses_with_no_password_anywhere(monkeypatch, tmp_path):
    boot, calls = _boot(monkeypatch, tmp_path)
    os.remove(boot.secrets_json)
    rec = _record(boot)
    ok, log = boot.restore(rec, on_line=lambda _l: None)
    assert not ok and any("no superadmin password" in l for l in log)
    assert calls["start"] == 0


def test_start_saved_runs_stack_start_only(monkeypatch, tmp_path):
    boot, calls = _boot(monkeypatch, tmp_path)
    monkeypatch.setattr(LocalStackNode, "seed",
                        lambda *a, **k: (_ for _ in ()).throw(
                            AssertionError("a warm start must not seed")))
    rec = _record(boot)
    ok, log = boot.start_saved(rec, on_line=lambda _l: None)
    assert ok and calls["start"] == 1
    assert any("nothing is re-minted or re-seeded" in l for l in log)


def test_start_saved_puts_a_changed_credentials_file_back_first(monkeypatch, tmp_path):
    boot, calls = _boot(monkeypatch, tmp_path)
    e2e = tmp_path / ".e2e-credentials"
    e2e.write_text("E2E_PASSWORD=minted-later\n")
    monkeypatch.setattr(boot, "e2e_credentials_path", lambda: str(e2e))
    rec = _record(boot, copied=True)
    ok, log = boot.start_saved(rec, on_line=lambda _l: None)
    assert ok and calls["start"] == 1
    assert e2e.read_text() == "E2E_PASSWORD=from-the-copy\n"


def test_start_saved_refuses_when_the_volumes_are_gone_at_execution_time(monkeypatch,
                                                                         tmp_path):
    """The row's plan is decided at PROBE time (page entry, a _mesh_up flip) and can
    be hours stale. With the volumes cleaned since, `stack.start()` would create
    EMPTY volumes and no seed runs — while the log says "reattaching". The plan is
    re-decided on the worker from what is on the machine now."""
    boot, calls = _boot(monkeypatch, tmp_path)
    calls["facts"].update(volumes_present=False, volumes_missing=("v0", "v1", "v2"),
                          volumes_seen=0)
    rec = _record(boot)
    rec.volumes = {"included": False, "inventory": [{"name": f"v{i}"} for i in range(3)]}
    streamed = []
    ok, log = boot.start_saved(rec, on_line=streamed.append)
    assert not ok and calls["start"] == 0
    assert any("refused" in l and "Restore (reseed)" in l for l in streamed)
    assert not any("reattaching" in l for l in log)


def test_start_saved_and_restore_refuse_over_a_mesh_that_came_up_since_the_probe(
        monkeypatch, tmp_path):
    """A terminal `make stack-up` after the row was probed: the page's gate is
    probe-time, so the button is still armed. A start over it stacks a second
    project on the same compose name; a restore re-seeds the LIVE mesh's users
    with this record's passwords. Both refuse on the worker, before any side
    effect."""
    boot, calls = _boot(monkeypatch, tmp_path)
    calls["facts"]["mesh_running"] = True
    rec = _record(boot)
    ok, log = boot.start_saved(rec, on_line=lambda _l: None)
    assert not ok and calls["start"] == 0
    assert any("refused" in l and "running" in l for l in log)
    ok, log = boot.restore(rec, on_line=lambda _l: None)
    assert not ok and calls["start"] == 0 and calls["seed"] == []
    assert any("refused" in l and "running" in l for l in log)
    assert not any(SA_VALUE in l for l in log)


def test_a_probe_that_cannot_answer_refuses_rather_than_starting(monkeypatch, tmp_path):
    boot, calls = _boot(monkeypatch, tmp_path)

    def boom(rec, project=""):
        raise OSError("docker: connection refused")
    monkeypatch.setattr(sm, "probe_state", boom)
    rec = _record(boot)
    ok, log = boot.start_saved(rec, on_line=lambda _l: None)
    assert not ok and calls["start"] == 0
    assert any("could not be established" in l for l in log)
    ok, log = boot.restore(rec, on_line=lambda _l: None)
    assert not ok and calls["start"] == 0 and calls["seed"] == []


@pytest.mark.parametrize("unanswered", [
    {"mesh_running": None},                                   # docker ps failed
    {"volumes_present": None, "volumes_missing": (),
     "unanswered": ("volumes",)},                             # docker volume ls failed
    {"images_present": None},                                 # docker images failed
    {"volumes_present": None, "volumes_missing": (), "images_present": None,
     "mesh_running": None,
     "unanswered": ("volumes", "images", "containers")},      # docker down altogether
])
def test_a_docker_that_did_not_answer_refuses_both_verbs(monkeypatch, tmp_path, unanswered):
    """#361: probe_state now reports None for a fact docker could not answer, and
    _live_plan must treat ANY None as refuse. Before, the failure read as 'volumes gone,
    nothing running' -> a RESEED plan -> `make stack-up` + `stack-seed` ran over the live
    mesh with this record's credentials once docker answered again."""
    boot, calls = _boot(monkeypatch, tmp_path)
    calls["facts"].update(unanswered)
    rec = _record(boot)
    ok, log = boot.start_saved(rec, on_line=lambda _l: None)
    assert not ok and calls["start"] == 0
    assert any("refused" in l for l in log), log
    ok, log = boot.restore(rec, on_line=lambda _l: None)
    assert not ok and calls["start"] == 0 and calls["seed"] == [], (calls, log)
    assert any("refused" in l and "did not answer" in l for l in log), log
    assert not any(SA_VALUE in l for l in log)


def test_the_cli_restore_stops_at_a_plan_docker_could_not_establish(monkeypatch, tmp_path,
                                                                      capsys):
    """`mesh-restore` prints the plan and used to fall through to restore() for anything
    but BLOCKED — including a plan built from a docker that did not answer (#361)."""
    boot, calls = _boot(monkeypatch, tmp_path)
    calls["facts"].update(mesh_running=None, unanswered=("containers",))
    rec = _record(boot)
    monkeypatch.setattr(sm, "find", lambda mesh_id: rec)
    for verb in ("restore", "start_saved"):
        monkeypatch.setattr(LocalMeshBootstrap, verb,
                            lambda *a, **k: pytest.fail("the CLI went on to " + verb))
    from hugmesh_studio.core import local_mesh_bootstrap as lmb
    rc = lmb.main(["mesh-restore", rec.id, "--generator-dir", GENERATOR_DIR,
                   "--out", str(tmp_path / "keys")])
    out = capsys.readouterr().out
    assert rc == 1 and "Docker did not answer" in out, out
    assert calls["start"] == 0 and calls["seed"] == []


def test_down_log_says_volumes_are_kept(monkeypatch, tmp_path):
    from hugmesh_studio.core.local_stack_node import StackStatus
    from hugmesh_studio.core.mesh_node import MeshNode
    monkeypatch.setattr(LocalStackNode, "status",
                        lambda self: StackStatus(running=True, detail="9 container(s)"))
    monkeypatch.setattr(LocalStackNode, "stop", lambda self: (True, "noise"))
    monkeypatch.setattr(MeshNode, "stop", lambda self: (True, "not started"))
    _ok, log = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(
        out_dir=str(tmp_path))).down()
    line = next(l for l in log if l.startswith("[stack-down]"))
    assert "kept its volumes" in line and "dropped" not in line


# ── #579: a saved record's Tor selection is what a start/restore brings up ──────────
# ONE authority per profile: with a services TUPLE the picker's rows decide the tor
# profile and the legacy boolean is normalised to agree at from_dict, so a record can
# no longer say "with_tor=True" over a mesh that starts no hugmesh-tor (or the
# reverse). And both bring-up paths of a saved mesh — the warm start and the cold
# restore — build their stack node from the RECORD through one seam (for_record).
_ONION = "https://txljwl7mdg7t3wmqdci77ttof5ikxeqg2epmfadzfxlzxvjgtx5k4fad.onion/"


@pytest.mark.parametrize("given,want_tor", [
    ({"with_tor": True}, True),                                  # CLI record: flag rules
    ({"with_tor": False, "services": ["tor"]}, True),            # the row rules...
    ({"with_tor": True, "services": ["tuwunel"]}, False),        # ...both ways
    ({"with_tor": True, "services": []}, False),                 # explicit none
])
def test_from_dict_normalises_the_tor_flag_to_the_services_row(given, want_tor):
    cfg = LocalMeshBootstrapConfig.from_dict(given)
    assert cfg.with_tor is want_tor
    assert cfg.effective_with_tor() is want_tor
    tor_env = LocalMeshBootstrap(GENERATOR_DIR, cfg)._stack_node()._build_env()["TOR"]
    assert tor_env == ("1" if want_tor else "")


def test_from_dict_normalises_social_the_same_way():
    assert LocalMeshBootstrapConfig.from_dict(
        {"social": False, "services": ["tuwunel"]}).social is True
    assert LocalMeshBootstrapConfig.from_dict(
        {"social": True, "services": ["tor"]}).social is False
    assert LocalMeshBootstrapConfig.from_dict({"social": True}).social is True


def _tor_record_boot(monkeypatch, tmp_path, services, with_tor=False):
    cfg = LocalMeshBootstrapConfig(out_dir=str(tmp_path / "keys"),
                                   superadmin_username="sa", services=services,
                                   with_tor=with_tor)
    rec = sm.SavedMesh(id=sm.new_id(), label="saved-tor", generator_dir=GENERATOR_DIR)
    rec.config = cfg.to_dict()
    rec.credentials = {"superadmin_username": "sa",
                       "e2e_file": {"copied": False, "copy": ""},
                       "secrets_json": {"copied": False, "copy": ""}}
    boot = LocalMeshBootstrap.for_record(GENERATOR_DIR, rec)
    os.makedirs(boot.vault_dir)
    with open(boot.secrets_json, "w") as fh:
        json.dump({"hugmesh-pki": {"casdoor-superadmin": {
            "username": "sa", "password": SA_VALUE}}}, fh)
    monkeypatch.setattr(boot, "guard_host_local", lambda: (True, ""))
    monkeypatch.setattr(boot, "validate", lambda: [])
    monkeypatch.setattr(boot, "preflight", lambda: [])
    monkeypatch.setattr(boot, "generate_creds",
                        lambda: pytest.fail("generate_creds must never run here"))
    monkeypatch.setattr(sm, "probe_state", lambda rec, project="": dict(_LIVE_OK))
    seen = {"tor": []}

    def fake_start(self, on_line=None, cancel=None):
        seen["tor"].append(self._build_env()["TOR"])   # what `make stack-up` would get
        return True, "up"
    monkeypatch.setattr(LocalStackNode, "start", fake_start)
    monkeypatch.setattr(LocalStackNode, "seed",
                        lambda self, extra_env=None, timeout=600, on_line=None,
                        cancel=None: (True, "seeded"))
    monkeypatch.setattr(LocalStackNode, "onion_url", lambda self: _ONION)
    return boot, rec, seen


def test_start_saved_of_a_tor_record_brings_up_the_tor_profile(monkeypatch, tmp_path):
    boot, rec, seen = _tor_record_boot(monkeypatch, tmp_path, ("tor",))
    ok, log = boot.start_saved(rec, on_line=lambda _l: None)
    assert ok, log
    assert seen["tor"] == ["1"]


def test_restore_of_a_tor_record_brings_up_the_tor_profile(monkeypatch, tmp_path):
    boot, rec, seen = _tor_record_boot(monkeypatch, tmp_path, ("tor",))
    streamed = []
    ok, log = boot.restore(rec, on_line=streamed.append)
    assert ok, log
    assert seen["tor"] == ["1"]
    assert any("onion published" in l for l in streamed)


def test_a_record_whose_flag_disagrees_with_its_row_starts_no_tor(monkeypatch, tmp_path):
    boot, rec, seen = _tor_record_boot(monkeypatch, tmp_path, ("tuwunel",),
                                       with_tor=True)
    assert boot.cfg.with_tor is False                  # normalised at load
    ok, log = boot.start_saved(rec, on_line=lambda _l: None)
    assert ok, log
    assert seen["tor"] == [""]


def test_for_record_carries_the_auth_key_the_record_never_stores(tmp_path):
    rec = sm.SavedMesh(id=sm.new_id(), config=LocalMeshBootstrapConfig(
        env="prod", services=("tor",)).to_dict())
    rec.config["auth_key"] = ""                        # what capture() writes
    boot = LocalMeshBootstrap.for_record(GENERATOR_DIR, rec, auth_key="tskey-9")
    assert boot.cfg.auth_key == "tskey-9" and boot.cfg.effective_with_tor() is True
    assert LocalMeshBootstrap.for_record(GENERATOR_DIR, rec).cfg.auth_key == ""

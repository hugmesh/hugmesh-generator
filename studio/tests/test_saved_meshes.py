"""core/saved_meshes.py — the saved-mesh RECORD (ask C, 2026-09-01).

Pure-core, no Qt, no docker: every docker/git seam is monkeypatched at the
function the module calls (``vaults.list_volumes``, ``_git``, ``_run``), and the
Studio state dir is the autouse tmp dir from conftest.

The two SILENT-REGRESSION guards live here on purpose: ``services``/``kind_addons``
``None`` vs ``()`` must survive a record round-trip, because collapsing them
re-enables metrics-server and flips the profile semantics with no error anywhere.
"""
from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
from types import SimpleNamespace

import pytest

from hugmesh_studio.core import saved_meshes as sm
from hugmesh_studio.core import vaults
from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

E2E_VALUE = "Sekrit-Value-42"
SA_VALUE = "Top-Secret-99"


# ── fixtures / fakes ───────────────────────────────────────────────────────────
def _gen(tmp_path):
    """A throwaway generator checkout: the run-state password file, the minted
    secrets bundle and a .stack-src with one fake repo."""
    gen = tmp_path / "gen"
    gen.mkdir(parents=True)
    (gen / ".e2e-credentials").write_text(f"E2E_PASSWORD={E2E_VALUE}\n")
    os.chmod(gen / ".e2e-credentials", 0o600)
    vault = gen / "keys-out" / "vault"
    vault.mkdir(parents=True)
    (vault / "secrets.json").write_text(json.dumps(
        {"hugmesh-pki": {"casdoor-superadmin": {"username": "sa",
                                                 "password": SA_VALUE}}}))
    stack = gen / "tests" / "stack"
    stack.mkdir(parents=True)
    (stack / ".theme.css").write_text(":root{--x:1}")
    (gen / ".stack-src" / "hugmesh-gateway" / ".git").mkdir(parents=True)
    return str(gen)


class _Node:
    web_url = "https://localhost:8488"
    plain_web_url = "http://localhost:8088"

    def __init__(self, extra=None):
        self._extra = dict(extra or {})

    def _build_env(self):
        env = dict(os.environ)
        env.update({"ENV": "test", "SOCIAL": "1", "PUBLIC_HOST_PORT": "8088",
                    "E2E_SUPERADMIN_PASSWORD": "never-me",
                    "HUG_THEME_CSS": "bulky"})
        env.update(self._extra)
        return env

    def onion_url(self):
        return ""

    def status(self):
        return SimpleNamespace(running=True, detail="3 container(s)")

    def running_env(self):
        return "test"


class _Boot:
    def __init__(self, gen):
        self.secrets_json = os.path.join(gen, "keys-out", "vault", "secrets.json")

    def superadmin_login(self):
        return ("sa", SA_VALUE)


def _vol(name, short, in_use=("c1",)):
    return vaults.ManagedVolume(name=name, short=short, mountpoint="", size_bytes=10,
                                in_use_by=tuple(in_use))


@pytest.fixture
def seams(monkeypatch):
    """Every subprocess seam faked; returns the recorder."""
    calls = {"projects": [], "git": []}

    def list_volumes(project=vaults.DEFAULT_PROJECT):
        calls["projects"].append(project)
        # a volume whose compose definition was RENAMED (survived stack-clean) —
        # only a LABEL inventory sees it
        return [_vol("hugmesh-local_synapse", "synapse"),
                _vol("hugmesh-local_casdoor-pg", "casdoor-pg")]

    def git(repo, *args):
        calls["git"].append((repo, args))
        if "--abbrev-ref" in args:
            return "fix/branch"
        if args == ("rev-parse", "HEAD"):
            return "abc123" * 6 + "abcd"
        if args[0] == "status":
            return " M file"
        return ""

    monkeypatch.setattr(vaults, "list_volumes", list_volumes)
    monkeypatch.setattr(sm, "_git", git)
    monkeypatch.setattr(sm, "_run", lambda *a, **k: (1, ""))
    return calls


def _capture(gen, **kw):
    cfg = kw.pop("cfg", LocalMeshBootstrapConfig(services=("tuwunel",), kind_addons=()))
    return sm.capture(gen, cfg, _Node(), _Boot(gen), **kw)


# ── the record ─────────────────────────────────────────────────────────────────
def test_record_round_trips_through_json(seams, tmp_path):
    rec = _capture(_gen(tmp_path))
    path = sm.save(rec)
    assert path and os.path.isfile(path)
    back = sm.load(path)
    assert back.to_dict() == rec.to_dict()
    assert back.id == rec.id and back.label == rec.label


def test_services_none_and_empty_tuple_survive_the_round_trip(seams, tmp_path):
    gen = _gen(tmp_path)
    for value in (None, ()):
        rec = _capture(gen, cfg=LocalMeshBootstrapConfig(services=value))
        back = sm.load(sm.save(rec))
        cfg = LocalMeshBootstrapConfig.from_dict(back.config)
        assert cfg.services == value, (value, cfg.services)
        assert (cfg.services is None) == (value is None)


def test_kind_addons_none_and_empty_tuple_survive_the_round_trip(seams, tmp_path):
    gen = _gen(tmp_path)
    for value in (None, ()):
        rec = _capture(gen, cfg=LocalMeshBootstrapConfig(kind_addons=value))
        back = sm.load(sm.save(rec))
        cfg = LocalMeshBootstrapConfig.from_dict(back.config)
        assert cfg.kind_addons == value
        assert (cfg.kind_addons is None) == (value is None)
        # the JSON itself keeps them distinct: null vs []
        raw = json.load(open(back.path()))
        assert raw["config"]["kind_addons"] == (None if value is None else [])


def test_auth_key_is_never_written_and_is_listed_in_blanked_secrets(seams, tmp_path):
    rec = _capture(_gen(tmp_path),
                   cfg=LocalMeshBootstrapConfig(env="prod", auth_key="tskey-abc-123"))
    text = json.dumps(rec.to_dict())
    assert "tskey-abc-123" not in text
    assert rec.config["auth_key"] == ""
    assert "auth_key" in rec.blanked_secrets


def test_egress_conf_is_stored_as_a_path_not_content(seams, tmp_path):
    conf = tmp_path / "vpn.conf"
    conf.write_text("[Interface]\nPrivateKey = VPN-PRIVATE-KEY-VALUE\n")
    rec = _capture(_gen(tmp_path),
                   cfg=LocalMeshBootstrapConfig(services=("egress-vpn",),
                                                egress_vpn_conf=str(conf)))
    text = json.dumps(rec.to_dict())
    assert rec.config["egress_vpn_conf"] == str(conf)
    assert "VPN-PRIVATE-KEY-VALUE" not in text


def test_scan_is_newest_first_and_surfaces_corrupt_files(seams, tmp_path):
    a = sm.SavedMesh(id="20260101-000000-aaaaaa", label="old")
    b = sm.SavedMesh(id="20260202-000000-bbbbbb", label="new")
    assert sm.save(a) and sm.save(b)
    bad = os.path.join(sm.meshes_dir(), "20260303-000000-cccccc.json")
    with open(bad, "w") as fh:
        fh.write("{not json")
    recs, unreadable = sm.scan()
    assert [r.label for r in recs] == ["new", "old"]
    assert unreadable == [bad]
    # surfaced, never rewritten
    assert open(bad).read() == "{not json"


def test_from_dict_filters_unknown_keys_and_coerces_declared_str_fields():
    rec = sm.SavedMesh.from_dict({"id": 7, "label": 7, "hostname": None,
                                  "config": "not-a-dict", "notes": "not-a-list",
                                  "bogus": 1})
    assert rec.id == "7" and rec.label == "7" and rec.hostname == ""
    assert rec.config == {} and rec.notes == []
    assert not hasattr(rec, "bogus")
    with pytest.raises(ValueError):
        sm.SavedMesh.from_dict(["a list"])


def test_delete_removes_the_record_and_its_copy_dir(seams, tmp_path):
    rec = _capture(_gen(tmp_path), copy_credentials=True)
    sm.save(rec)
    assert os.path.isfile(rec.path()) and os.path.isdir(rec.copy_dir())
    called = []
    # Delete must never reach for a volume — by construction, not by luck.
    import hugmesh_studio.core.vaults as v
    orig = v.remove_volume
    v.remove_volume = lambda *a, **k: called.append(a)
    try:
        assert sm.delete(rec)
    finally:
        v.remove_volume = orig
    assert not os.path.exists(rec.path()) and not os.path.exists(rec.copy_dir())
    assert called == []


def test_delete_refuses_a_copy_dir_outside_the_meshes_dir(tmp_path):
    victim = tmp_path / "victim"
    victim.mkdir()
    (victim / "keep.txt").write_text("x")
    # a poisoned record whose id escapes the meshes dir
    rec = sm.SavedMesh(id=os.path.join("..", "..", "victim"), label="evil")
    rec.copy_dir = lambda: str(victim)          # type: ignore[method-assign]
    sm.delete(rec)
    assert (victim / "keep.txt").exists(), "rmtree escaped <state>/meshes"
    assert not sm._is_record_copy_dir(str(victim), rec.id)
    assert not sm._is_record_copy_dir("/", "")
    assert sm._is_record_copy_dir(os.path.join(sm.meshes_dir(), "abc"), "abc")


def test_delete_path_refuses_files_outside_the_meshes_dir(tmp_path):
    other = tmp_path / "elsewhere.json"
    other.write_text("{}")
    sm.delete_path(str(other))
    assert other.exists()


# ── capture ────────────────────────────────────────────────────────────────────
def test_capture_records_a_volume_inventory_and_marks_included_false(seams, tmp_path):
    rec = _capture(_gen(tmp_path))
    assert rec.volumes["included"] is False
    assert "casdoor-pg" in rec.volumes["reason"]
    assert sorted(v["short"] for v in rec.volumes["inventory"]) == ["casdoor-pg", "synapse"]
    assert rec.volume_count() == 2
    assert rec.doors["web_url"] == "https://localhost:8488"
    assert rec.lanes["compose_project"] == vaults.DEFAULT_PROJECT
    assert rec.lanes["kube_context"].startswith("kind-")
    assert rec.last_seen["compose_running"] is True
    assert rec.overlays["theme_css"] == ":root{--x:1}"
    assert rec.regenerated == list(sm.REGENERATED)


def test_capture_inventories_by_label_not_by_the_compose_file(seams, tmp_path):
    rec = _capture(_gen(tmp_path))
    # the seam is vaults.list_volumes(<compose project>) — the LABEL query — and
    # the renamed-away 'synapse' volume (absent from the current compose files) is
    # in the inventory because of it
    assert seams["projects"] == [vaults.DEFAULT_PROJECT]
    assert "hugmesh-local_synapse" in rec.volume_names()


def test_capture_does_not_copy_credentials_by_default(seams, tmp_path):
    rec = _capture(_gen(tmp_path))
    for key in ("e2e_file", "secrets_json"):
        assert rec.credentials[key]["copied"] is False
        assert rec.credentials[key]["copy"] == ""
        assert rec.credentials[key]["sha256"]          # pointer + hash recorded
        assert rec.credentials[key]["mtime"]
    assert not os.path.exists(rec.copy_dir())
    assert rec.credentials["superadmin_username"] == "sa"
    assert any("NOT copied" in n for n in rec.notes)


def test_capture_copies_the_credentials_file_at_0600_when_asked(seams, tmp_path):
    rec = _capture(_gen(tmp_path), copy_credentials=True)
    copies = rec.credential_copies()
    assert len(copies) == 2
    for p in copies:
        assert os.path.isfile(p)
        assert stat.S_IMODE(os.stat(p).st_mode) == 0o600
    assert stat.S_IMODE(os.stat(rec.copy_dir()).st_mode) == 0o700
    assert rec.credentials["e2e_file"]["copied"] is True
    assert rec.credentials["e2e_file"]["copy"] == os.path.join(rec.id, "e2e-credentials")


def test_capture_records_per_repo_head_and_dirty_flags(seams, tmp_path):
    rec = _capture(_gen(tmp_path))
    assert rec.source["mode"] == "clone"
    rows = rec.source["repos"]
    assert [r["name"] for r in rows] == ["hugmesh-gateway"]
    assert rows[0]["branch"] == "fix/branch"
    assert rows[0]["head"].startswith("abc123")
    assert rows[0]["dirty"] is True
    assert rec.generator_head.startswith("abc123")


def test_env_snapshot_keeps_only_the_delta_and_drops_secret_shaped_keys(seams, tmp_path):
    rec = _capture(_gen(tmp_path))
    assert rec.env_snapshot["ENV"] == "test"
    assert rec.env_snapshot["SOCIAL"] == "1"
    assert "E2E_SUPERADMIN_PASSWORD" not in rec.env_snapshot
    assert "HUG_THEME_CSS" not in rec.env_snapshot          # bulky, carried in overlays
    assert "PATH" not in rec.env_snapshot                    # inherited, not the mesh's


def test_extra_users_record_names_and_roles_but_never_a_password(seams, tmp_path):
    rec = _capture(_gen(tmp_path), extra_users=["alice:ROLE_MOD:E2E_ALICE_PASSWORD"])
    assert rec.extra_users == [{"username": "alice", "roles": "ROLE_MOD",
                                "password_saved": False}]


def test_no_password_value_appears_in_the_record_json(seams, tmp_path):
    gen = _gen(tmp_path)
    for copy in (False, True):
        rec = _capture(gen, copy_credentials=copy,
                       extra_users=["bob:ROLE_USER:E2E_BOB_PASSWORD"])
        path = sm.save(rec)
        text = open(path, encoding="utf-8").read()
        assert E2E_VALUE not in text
        assert SA_VALUE not in text
        assert "never-me" not in text
        # …while the copies (when asked for) DO hold them, at 0600, outside the JSON
        if copy:
            assert E2E_VALUE in open(rec.credential_copies()[0]).read()


# ── the plan (PURE) ────────────────────────────────────────────────────────────
def _rec(n=3, copied=False):
    rec = sm.SavedMesh(id="20260101-000000-abcdef", label="t")
    rec.volumes = {"included": False, "inventory": [{"name": f"v{i}"} for i in range(n)]}
    if copied:
        rec.credentials = {"e2e_file": {"copied": True, "copy": "x/e2e-credentials"},
                           "secrets_json": {"copied": False}}
    return rec


def test_restore_plan_says_reattach_when_volumes_are_present():
    plan = sm.restore_plan(_rec(), volumes_present=True, images_present=True)
    assert plan.mode == sm.MODE_START and plan.can_start()
    assert "reattaches 3 data volume(s)" in plan.sentence
    assert "no re-seed" in plan.sentence.lower() or "No credentials are re-minted" in plan.sentence
    assert plan.volumes_text == "3 present"
    cold = sm.restore_plan(_rec(), volumes_present=True, images_present=False)
    assert cold.mode == sm.MODE_START and "COLD" in " ".join(cold.warnings)


def test_restore_plan_says_reseed_when_volumes_are_gone():
    plan = sm.restore_plan(_rec(), volumes_present=False, images_present=True,
                           creds_match=False)
    assert plan.mode == sm.MODE_RESEED and plan.can_reseed()
    assert "CURRENT files" in plan.sentence and ".onion" in plan.sentence
    assert plan.volumes_text == "gone (cleaned)"
    same = sm.restore_plan(_rec(copied=True), volumes_present=False)
    assert "same passwords" in same.sentence
    match = sm.restore_plan(_rec(), volumes_present=False, creds_match=True)
    assert "same passwords" in match.sentence
    partial = sm.restore_plan(_rec(), volumes_present=False,
                              volumes_missing=("v2",))
    assert partial.mode == sm.MODE_RESEED and "v2" in " ".join(partial.warnings)
    assert partial.volumes_text == "2 of 3 present"


def test_restore_plan_flags_a_moved_source_tree():
    plan = sm.restore_plan(_rec(), volumes_present=True, images_present=True,
                           source_drift=("hugmesh-gateway (HEAD moved)",))
    assert plan.can_start()
    assert "hugmesh-gateway (HEAD moved)" in " ".join(plan.warnings)
    assert "as it is now" in " ".join(plan.warnings)
    gone = sm.restore_plan(_rec(), volumes_present=False, source_ok=False)
    assert "source tree is gone" in " ".join(gone.warnings)


def test_restore_plan_blocks_on_a_running_mesh_and_on_missing_copies():
    running = sm.restore_plan(_rec(), volumes_present=True, images_present=True,
                              mesh_running=True)
    assert running.mode == sm.MODE_BLOCKED and "Stop it first" in running.sentence
    missing = sm.restore_plan(_rec(copied=True), volumes_present=False,
                              copies_missing=("/x/e2e-credentials",))
    assert missing.mode == sm.MODE_BLOCKED and "e2e-credentials" in missing.sentence


def test_restore_plan_unknown_is_rendered_as_unknown_never_as_no():
    plan = sm.restore_plan(_rec())
    assert plan.mode == sm.MODE_UNKNOWN
    assert not plan.can_start() and not plan.can_reseed()
    assert "Checking" in plan.sentence and plan.volumes_text == "unknown"


def test_probe_state_feeds_the_plan(seams, tmp_path, monkeypatch):
    rec = _capture(_gen(tmp_path))
    sm.save(rec)
    # all volumes present, images absent (_run is faked to fail), nothing running
    st = sm.probe_state(rec)
    assert st["volumes_present"] is True and st["volumes_missing"] == ()
    assert st["images_present"] is False and st["mesh_running"] is False
    assert st["creds_match"] is True                 # the file is unchanged
    assert st["source_ok"] is True and st["source_drift"] == ()
    plan = sm.restore_plan(rec, **st)
    assert plan.mode == sm.MODE_START and "COLD" in " ".join(plan.warnings)
    # the file changes -> creds no longer match; HEAD moves -> drift is named
    with open(os.path.join(rec.generator_dir, ".e2e-credentials"), "a") as fh:
        fh.write("E2E_PASSWORD=other\n")
    monkeypatch.setattr(sm, "_git", lambda repo, *a: "ffff" if a == ("rev-parse", "HEAD") else "")
    st = sm.probe_state(rec)
    assert st["creds_match"] is False
    assert st["source_drift"] == ("hugmesh-gateway (HEAD moved)",)


# ── restore env / put-back ─────────────────────────────────────────────────────
def test_restore_env_carries_the_saved_credentials_file_path(seams, tmp_path):
    rec = _capture(_gen(tmp_path), copy_credentials=True)
    env = sm.restore_env(rec)
    assert env["E2E_CREDENTIALS_FILE"] == rec.credential_copies()[0]
    assert env["CASDOOR_SUPERADMIN_USERNAME"] == "sa"
    assert env["E2E_SUPERADMIN_PASSWORD"] == SA_VALUE     # read from the COPY
    # pointers-only record: nothing to point at, no password to bridge
    plain = _capture(_gen(tmp_path / "b"))
    env2 = sm.restore_env(plain)
    assert "E2E_CREDENTIALS_FILE" not in env2 and "E2E_SUPERADMIN_PASSWORD" not in env2
    assert env2["CASDOOR_SUPERADMIN_USERNAME"] == "sa"


def test_put_copies_back_restores_in_place_at_0600_only_when_changed(seams, tmp_path):
    gen = _gen(tmp_path)
    rec = _capture(gen, copy_credentials=True)
    e2e = os.path.join(gen, ".e2e-credentials")
    secrets = os.path.join(gen, "keys-out", "vault", "secrets.json")
    assert sm.put_copies_back(rec, e2e_target=e2e, secrets_target=secrets) == []
    open(e2e, "w").write("E2E_PASSWORD=changed\n")
    os.chmod(e2e, 0o644)
    restored = sm.put_copies_back(rec, e2e_target=e2e, secrets_target=secrets)
    assert restored == [".e2e-credentials"]
    assert open(e2e).read() == f"E2E_PASSWORD={E2E_VALUE}\n"
    assert stat.S_IMODE(os.stat(e2e).st_mode) == 0o600


# ── CLI + hygiene ──────────────────────────────────────────────────────────────
def test_cli_list_show_delete(seams, tmp_path, capsys):
    rec = _capture(_gen(tmp_path))
    sm.save(rec)
    assert sm.main(["list"]) == 0
    out = capsys.readouterr().out
    assert rec.id in out and "included=False" in out
    assert sm.main(["show", rec.id]) == 0
    assert json.loads(capsys.readouterr().out)["id"] == rec.id
    assert sm.main(["delete", rec.id]) == 0
    assert not os.path.exists(rec.path())
    assert sm.main(["show", rec.id]) == 1


def test_module_is_qt_free():
    probe = (
        "import hugmesh_studio.core.saved_meshes as m, sys;"
        "assert callable(m.capture) and callable(m.restore_plan);"
        "bad=[x for x in sys.modules if x.startswith(('PySide6','PyQt6','PyQt5'))];"
        "assert not bad, bad"
    )
    env = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    r = subprocess.run([sys.executable, "-c", probe], env=env,
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


def test_lane_never_calls_remove_volume():
    """vaults.remove_volume is destructive; nothing in the saved-mesh lane may
    reach it (its Delete removes a RECORD)."""
    here = os.path.join(STUDIO_ROOT, "hugmesh_studio")
    for rel in ("core/saved_meshes.py", "gui/pages/_saved_meshes_widget.py"):
        text = open(os.path.join(here, rel), encoding="utf-8").read()
        assert "remove_volume(" not in text, rel

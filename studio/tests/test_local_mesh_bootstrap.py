"""Qt-free coverage for the from-scratch local-mesh bootstrapper
(core/local_mesh_bootstrap). This is the SAME object graph the GUI's LocalMeshDialog
bootstrap tab and the ncurses menu drive — a LocalMeshBootstrapConfig ->
LocalMeshBootstrap composing the gen scripts + LocalStackNode + LocalMeshNode.

Everything here imports NO Qt (the core module imports only sibling core modules), so
it runs in the Qt-free system-python environment CI uses. The subprocess boundary is
ALWAYS mocked — these tests NEVER really mint prod secrets or start containers.
"""
import json
import os

import pytest

from hugmesh_studio.core import local_mesh_bootstrap as boot_mod
from hugmesh_studio.core import local_services as ls
from hugmesh_studio.core.local_mesh_bootstrap import (
    SEED_SUPERADMIN_PASSWORD_ENV, SEED_SUPERADMIN_USERNAME_ENV,
    LocalMeshBootstrap, LocalMeshBootstrapConfig, main,
)
from hugmesh_studio.core.local_stack_node import LocalStackNode
from hugmesh_studio.core.local_mesh import ENV_AUTHKEY, LocalMeshNode

GENERATOR_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(GENERATOR_DIR)  # studio/tests -> studio -> repo root

# A fresh minted password value we assert NEVER leaks into logs/argv/plan.
SECRET_PW = "s3cr3t-minted-pw-should-never-leak"


def _boot(tmp_path, **kw):
    cfg = LocalMeshBootstrapConfig(out_dir=str(tmp_path), **kw)
    return LocalMeshBootstrap(GENERATOR_DIR, cfg)


def _write_secrets(b: LocalMeshBootstrap, username="superadmin", password=SECRET_PW):
    os.makedirs(b.vault_dir, exist_ok=True)
    with open(b.secrets_json, "w", encoding="utf-8") as fh:
        json.dump({f"{b.cfg.brand}-pki": {
            "casdoor-superadmin": {"username": username, "password": password}}}, fh)


# ── config / env toggle ─────────────────────────────────────────────────────────

def test_env_toggle_issuer_and_domain():
    test = LocalMeshBootstrapConfig(env="test")
    assert test.issuer() == "http://localhost:8000"
    prod = LocalMeshBootstrapConfig(env="prod", cluster_domain="example.com")
    assert prod.issuer() == "https://id.example.com"
    assert prod.resolved_domain() == "example.com"


def test_overlay_attaches_only_in_prod_with_key(tmp_path):
    # test: never (LAN-only, no tailnet)
    assert _boot(tmp_path, env="test", auth_key="tskey-x").overlay_will_attach() is False
    # prod without key: not yet
    assert _boot(tmp_path, env="prod", cluster_domain="e.com").overlay_will_attach() is False
    # prod with key: attaches
    assert _boot(tmp_path, env="prod", cluster_domain="e.com",
                 auth_key="tskey-x").overlay_will_attach() is True


# ── plan(): pure, side-effect-free, no secret value ─────────────────────────────

def test_plan_is_pure_and_names_everything(tmp_path):
    b = _boot(tmp_path, env="test", superadmin_username="root-boss")
    p = b.plan()
    # (a) both scripts + the out dir
    assert boot_mod.GEN_CLUSTER_SECRETS in p
    assert boot_mod.GEN_PROVISION_KEYS in p
    assert b.vault_dir in p and b.keys_dir in p and b.secrets_json in p
    # (b) both compose layers named
    assert "stack-up" in p and "stack-seed" in p and "overlay" in p.lower()
    # (c) ENV / issuer / domain
    assert "http://localhost:8000" in p and "test" in p
    # (d) superadmin username shown, password location shown, VALUE absent
    assert "root-boss" in p
    assert "casdoor-superadmin" in p
    # plan must not have created anything
    assert not os.path.exists(b.secrets_json)


def test_plan_test_skips_overlay_prod_attaches(tmp_path):
    assert "SKIPPED" in _boot(tmp_path, env="test").plan()
    prod = _boot(tmp_path, env="prod", cluster_domain="e.com", auth_key="tskey-x").plan()
    assert "ATTACHED" in prod


def test_plan_points_to_go_live_for_public_exposure(tmp_path):
    # The from-scratch bring-up serves LOCALLY; the plan must make the SEPARATE
    # public-exposure path discoverable (the "no clear way to serve onion/DDNS" gap).
    p = _boot(tmp_path, env="test").plan()
    assert "SERVE" in p and "Go Live" in p
    assert "tor-onion" in p and "duckdns" in p        # onion + a common Dynamic DNS
    assert "Local front door" in p


def test_plan_tor_on_reports_onion_not_go_live_for_public(tmp_path):
    # With Tor already enabled the public step is already satisfied — do not tell the
    # operator to run Go Live for an onion they already have.
    p = _boot(tmp_path, env="test", with_tor=True).plan()
    assert "already ON — the Tor v3 .onion" in p


def test_plan_flags_prod_blockers(tmp_path):
    p = _boot(tmp_path, env="prod").plan()  # no domain, no key
    assert "BLOCKERS" in p
    assert "cluster domain" in p.lower()
    assert "auth key" in p.lower()


def test_plan_accounts_for_every_row_the_services_table_shows(tmp_path):
    """The confirm-before-run manifest must describe the mesh the operator was SHOWN,
    which means all three kinds of row. The DevOps-lane rows were omitted entirely
    while the surface rendered live checkboxes for them, so an operator could tick
    ArgoCD, read a plan that never mentioned it, and press Start."""
    p = _boot(tmp_path, env="test", services=("tuwunel",)).plan()
    assert "SERVICES (compose profiles" in p
    assert "SERVICES (federation registry" in p
    assert "SERVICES (DevOps lane" in p
    for slug in ls.kind_slugs():
        assert f"[-] {slug}" in p, slug          # listed, and NOT as a checkbox
        assert f"[x] {slug}" not in p and f"[ ] {slug}" not in p, slug
    assert ls.KIND_LANE_LABEL in p
    assert "NOT started by this bring-up" in p
    assert "Start DevOps lane" in p


def test_a_devops_lane_slug_in_a_selection_is_a_blocker_not_a_silent_no_op(tmp_path):
    """`--services argocd` used to validate clean and then evaporate: every consumer
    (profile_flags/federation_env/plan) correctly ignored it and nothing said so."""
    b = _boot(tmp_path, env="test", services=("argocd", "tuwunel"))
    probs = b.validate()
    assert any("argocd" in x and ls.KIND_LANE_TARGET in x for x in probs), probs
    assert "BLOCKERS" in b.plan()


# ── validate() ──────────────────────────────────────────────────────────────────

def test_validate_test_ok_prod_requires_domain_and_key(tmp_path):
    assert _boot(tmp_path, env="test").validate() == []
    probs = _boot(tmp_path, env="prod").validate()
    assert any("domain" in x for x in probs)
    assert any("auth key" in x for x in probs)
    assert _boot(tmp_path, env="prod", cluster_domain="e.com",
                 auth_key="tskey-x").validate() == []


def test_validate_rejects_bad_env(tmp_path):
    assert any("test" in x for x in _boot(tmp_path, env="staging").validate())


# ── guard_host_local(): refuse inside a cluster pod ─────────────────────────────

def test_guard_refuses_in_cluster_pod(tmp_path, monkeypatch):
    monkeypatch.setenv("KUBERNETES_SERVICE_HOST", "10.0.0.1")
    ok, why = _boot(tmp_path).guard_host_local()
    assert ok is False and "pod" in why.lower()


def test_guard_defers_to_stack_availability(tmp_path, monkeypatch):
    monkeypatch.delenv("KUBERNETES_SERVICE_HOST", raising=False)
    monkeypatch.setattr("os.path.exists", lambda p: False)  # no /var/run/secrets/…
    monkeypatch.setattr(LocalStackNode, "available",
                        lambda self: (False, "make is required"), raising=True)
    ok, why = _boot(tmp_path).guard_host_local()
    assert ok is False and "make is required" in why


# ── generate_creds(): reuses the scripts verbatim; secrets never in argv ────────

def test_generate_creds_invokes_both_scripts_with_right_args_env(tmp_path, monkeypatch):
    calls = []

    class _R:
        returncode = 0
        stdout = ""
        stderr = ""

    def _fake_run(cmd, cwd=None, env=None, **kw):
        calls.append({"cmd": cmd, "cwd": cwd, "env": dict(env or {})})
        return _R()

    monkeypatch.setenv("VAULT_ADDR", "https://vault.example.com")  # must be stripped
    monkeypatch.setenv("VAULT_TOKEN", "tok")
    monkeypatch.setattr(boot_mod.subprocess, "run", _fake_run)

    b = _boot(tmp_path, env="prod", superadmin_username="megaadmin",
              cluster_domain="corp.example")
    ok, msg = b.generate_creds()
    assert ok is True
    assert len(calls) == 2

    c0, c1 = calls
    # cluster secrets: --out <vault>, no --random
    assert c0["cmd"] == ["bash", boot_mod.GEN_CLUSTER_SECRETS, "--out", b.vault_dir]
    # provision keys: -o <keys> --random
    assert c1["cmd"] == ["bash", boot_mod.GEN_PROVISION_KEYS, "-o", b.keys_dir, "--random"]
    for c in calls:
        assert c["cwd"] == b.generator_dir
        e = c["env"]
        # offline: VAULT_ADDR/TOKEN removed so the mint never hits a real Vault
        assert "VAULT_ADDR" not in e and "VAULT_TOKEN" not in e
        assert e["BRAND"] == "hugmesh"
        assert e["CASDOOR_SUPERADMIN_USERNAME"] == "megaadmin"
        assert e["NONINTERACTIVE"] == "1"
        assert e["CLUSTER_DOMAIN"] == "corp.example"   # prod pins the apex
        # the superadmin username may ride the env; NO secret value is in argv
    # nothing secret in any argv
    for c in calls:
        assert not any("PASSWORD" in str(a) or SECRET_PW in str(a) for a in c["cmd"])


def test_generate_creds_test_leaves_cluster_domain_default(tmp_path, monkeypatch):
    captured = {}

    class _R:
        returncode = 0
        stdout = ""
        stderr = ""

    def _fake_run(cmd, cwd=None, env=None, **kw):
        captured.setdefault("envs", []).append(dict(env or {}))
        return _R()

    monkeypatch.setattr(boot_mod.subprocess, "run", _fake_run)
    _boot(tmp_path, env="test").generate_creds()
    # test mode never pins CLUSTER_DOMAIN — the script keeps its brand default
    for e in captured["envs"]:
        assert "CLUSTER_DOMAIN" not in e


def test_generate_creds_reports_script_failure(tmp_path, monkeypatch):
    class _R:
        returncode = 3
        stdout = ""
        stderr = "boom"

    monkeypatch.setattr(boot_mod.subprocess, "run", lambda *a, **k: _R())
    ok, msg = _boot(tmp_path).generate_creds()
    assert ok is False and "boom" in msg


# ── read_superadmin() ───────────────────────────────────────────────────────────

def test_read_superadmin_parses_bundle(tmp_path):
    b = _boot(tmp_path)
    _write_secrets(b, username="root-boss", password=SECRET_PW)
    sa = b.read_superadmin()
    assert sa == {"username": "root-boss", "password": SECRET_PW}


def test_read_superadmin_missing_is_empty(tmp_path):
    assert _boot(tmp_path).read_superadmin() == {}


# ── up(): composes the three pieces; password bridged via env only ──────────────

def _patch_up_happy(monkeypatch, seed_calls, start_calls):
    monkeypatch.setattr(LocalMeshBootstrap, "guard_host_local",
                        lambda self: (True, ""), raising=True)
    # host cold-build preflight green — its fail-fast behaviour has dedicated
    # both-ways coverage in test_local_stack_preflight.py
    monkeypatch.setattr(LocalMeshBootstrap, "preflight",
                        lambda self: [], raising=True)
    monkeypatch.setattr(LocalMeshBootstrap, "generate_creds",
                        lambda self: (True, "generated"), raising=True)

    def _fake_stack_start(self, on_line=None, cancel=None):
        start_calls.append(True)
        return True, "stack up"

    def _fake_stack_seed(self, extra_env=None, timeout=600, on_line=None, cancel=None):
        seed_calls.append(dict(extra_env or {}))
        return True, "seeded"

    monkeypatch.setattr(LocalStackNode, "start", _fake_stack_start, raising=True)
    monkeypatch.setattr(LocalStackNode, "seed", _fake_stack_seed, raising=True)


def test_up_test_path_seeds_superadmin_and_skips_overlay(tmp_path, monkeypatch):
    seed_calls, start_calls = [], []
    _patch_up_happy(monkeypatch, seed_calls, start_calls)
    mesh_started = {"called": False}
    monkeypatch.setattr(LocalMeshNode, "start",
                        lambda self: mesh_started.__setitem__("called", True) or (True, ""),
                        raising=True)

    b = _boot(tmp_path, env="test", superadmin_username="root-boss")
    _write_secrets(b, username="root-boss", password=SECRET_PW)
    ok, log = b.up()

    assert ok is True
    assert start_calls == [True]               # stack came up
    # the minted username + password were bridged into stack-seed via env ONLY, so the
    # seeded ROLE_SUPERADMIN login matches the advertised username (not e2e-superadmin)
    assert seed_calls == [{SEED_SUPERADMIN_USERNAME_ENV: "root-boss",
                           SEED_SUPERADMIN_PASSWORD_ENV: SECRET_PW}]
    assert mesh_started["called"] is False     # LAN-only: overlay skipped
    # SECRET SAFETY: the password value never appears in any log line
    assert all(SECRET_PW not in line for line in log)
    # but the username + the path DO (so the operator knows where it landed)
    assert any("root-boss" in line for line in log)
    assert any(b.secrets_json in line for line in log)


def test_up_prod_path_attaches_overlay_and_exports_authkey(tmp_path, monkeypatch):
    seed_calls, start_calls = [], []
    _patch_up_happy(monkeypatch, seed_calls, start_calls)
    monkeypatch.delenv(ENV_AUTHKEY, raising=False)
    seen = {}

    def _fake_mesh_start(self):
        seen["ts"] = os.environ.get(ENV_AUTHKEY)
        seen["cfg_key"] = self.cfg.auth_key
        return True, "overlay up"

    monkeypatch.setattr(LocalMeshNode, "start", _fake_mesh_start, raising=True)

    b = _boot(tmp_path, env="prod", cluster_domain="corp.example",
              auth_key="tskey-prod", node_name="n1")
    _write_secrets(b)
    ok, log = b.up()

    assert ok is True
    assert seed_calls and SEED_SUPERADMIN_PASSWORD_ENV in seed_calls[0]
    # overlay attached AND TS_AUTHKEY exported before MeshNode.start (its guard reads env)
    assert seen["ts"] == "tskey-prod"
    assert seen["cfg_key"] == "tskey-prod"


def test_up_refuses_when_guard_fails(tmp_path, monkeypatch):
    monkeypatch.setattr(LocalMeshBootstrap, "guard_host_local",
                        lambda self: (False, "in a pod"), raising=True)
    gen = {"called": False}
    monkeypatch.setattr(LocalMeshBootstrap, "generate_creds",
                        lambda self: gen.__setitem__("called", True) or (True, ""),
                        raising=True)
    ok, log = _boot(tmp_path).up()
    assert ok is False and gen["called"] is False   # never generated creds


def test_up_stops_if_superadmin_unreadable(tmp_path, monkeypatch):
    monkeypatch.setattr(LocalMeshBootstrap, "guard_host_local",
                        lambda self: (True, ""), raising=True)
    monkeypatch.setattr(LocalMeshBootstrap, "preflight",
                        lambda self: [], raising=True)
    monkeypatch.setattr(LocalMeshBootstrap, "generate_creds",
                        lambda self: (True, "gen"), raising=True)
    started = {"called": False}
    monkeypatch.setattr(LocalStackNode, "start",
                        lambda self: started.__setitem__("called", True) or (True, ""),
                        raising=True)
    # no secrets.json written -> read_superadmin returns {}
    ok, log = _boot(tmp_path).up()
    assert ok is False and started["called"] is False


# ── Finding 1: prod domain threads into the running stack's Casdoor issuer ───────

def test_prod_stack_node_threads_domain_test_does_not(tmp_path):
    # prod: the resolved apex is handed to LocalStackNode as DOMAIN, so `make
    # stack-up` derives CASDOOR_ISSUER=https://id.<domain> — matching the minted
    # secrets and the plan, not the silent hugmesh.net default.
    prod = _boot(tmp_path, env="prod", cluster_domain="corp.example",
                 auth_key="tskey-x")
    assert prod._stack_node().domain == "corp.example"
    # test: issuer is localhost, so no DOMAIN is threaded (Makefile keeps its default).
    assert _boot(tmp_path, env="test")._stack_node().domain == ""


def test_stack_node_exports_domain_only_when_set(tmp_path, monkeypatch):
    captured = {}

    class _R:
        returncode = 0
        stdout = ""
        stderr = ""

    def _fake_run(cmd, cwd=None, env=None, **kw):
        captured["env"] = dict(env or {})
        return _R()

    monkeypatch.setattr("hugmesh_studio.core.local_stack_node.subprocess.run",
                        _fake_run)
    # start() gates on the cold-build preflight; pin it green so this test keeps
    # capturing the env of the `make stack-up` call itself.
    monkeypatch.setattr(LocalStackNode, "preflight", lambda self: [], raising=True)
    # with a domain -> DOMAIN exported into `make`
    LocalStackNode(GENERATOR_DIR, env="prod", domain="corp.example").start()
    assert captured["env"]["DOMAIN"] == "corp.example"
    assert captured["env"]["ENV"] == "prod"
    # without one (the default / test) -> DOMAIN is NOT set, so the Makefile default holds
    captured.clear()
    LocalStackNode(GENERATOR_DIR, env="test").start()
    assert "DOMAIN" not in captured["env"]


def test_up_prod_stack_receives_domain(tmp_path, monkeypatch):
    # end-to-end: a prod up() must construct a stack node carrying the apex, so the
    # running issuer can never silently diverge from the minted/advertised domain.
    seed_calls, start_calls = [], []
    _patch_up_happy(monkeypatch, seed_calls, start_calls)
    monkeypatch.setattr(LocalMeshNode, "start", lambda self: (True, ""), raising=True)
    seen = {}
    orig = LocalMeshBootstrap._stack_node

    def _spy(self):
        node = orig(self)
        seen["domain"] = node.domain
        return node

    monkeypatch.setattr(LocalMeshBootstrap, "_stack_node", _spy, raising=True)
    b = _boot(tmp_path, env="prod", cluster_domain="corp.example", auth_key="tskey-x")
    _write_secrets(b)
    ok, _log = b.up()
    assert ok is True
    assert seen["domain"] == "corp.example"


# ── Finding 2: the seeded superadmin login matches the minted/advertised name ────

def test_up_bridges_custom_superadmin_username_into_seed(tmp_path, monkeypatch):
    # a custom --superadmin-username must reach `make stack-seed` (not just the inert
    # secrets.json), so the operator can actually log in as the advertised name.
    seed_calls, start_calls = [], []
    _patch_up_happy(monkeypatch, seed_calls, start_calls)
    monkeypatch.setattr(LocalMeshNode, "start", lambda self: (True, ""), raising=True)
    b = _boot(tmp_path, env="test", superadmin_username="chief")
    _write_secrets(b, username="chief", password=SECRET_PW)
    ok, log = b.up()
    assert ok is True
    assert seed_calls == [{SEED_SUPERADMIN_USERNAME_ENV: "chief",
                           SEED_SUPERADMIN_PASSWORD_ENV: SECRET_PW}]
    # the advertised login in the log matches the seeded one; the value never leaks
    assert any("chief" in line for line in log)
    assert all(SECRET_PW not in line for line in log)


def test_down_stops_both_projects(tmp_path, monkeypatch):
    stopped = []
    monkeypatch.setattr(LocalStackNode, "stop",
                        lambda self: stopped.append("stack") or (True, "down"), raising=True)
    monkeypatch.setattr(LocalMeshNode, "stop",
                        lambda self: stopped.append("mesh") or (True, "down"), raising=True)
    ok, log = _boot(tmp_path).down()
    assert ok is True and stopped == ["stack", "mesh"]


# ── default out dir is the gitignored keys-out/ (creds never committed) ──────────

def test_default_out_dir_is_gitignored_keys_out():
    b = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig())
    assert b.out_dir == os.path.join(GENERATOR_DIR, "keys-out")
    # keys-out/ + vault-seed/ are in .gitignore (asserted here so a rename is caught)
    gi = open(os.path.join(GENERATOR_DIR, ".gitignore"), encoding="utf-8").read()
    assert "/keys-out/" in gi and "vault-seed/" in gi


# ── CLI face ─────────────────────────────────────────────────────────────────────

def test_cli_plan_prints_manifest_no_side_effects(tmp_path, capsys, monkeypatch):
    ran = {"up": False}
    monkeypatch.setattr(LocalMeshBootstrap, "up",
                        lambda self: ran.__setitem__("up", True) or (True, []), raising=True)
    rc = main(["plan", "--env", "test", "--out", str(tmp_path),
               "--generator-dir", GENERATOR_DIR])
    assert rc == 0
    out = capsys.readouterr().out
    assert boot_mod.GEN_CLUSTER_SECRETS in out
    assert ran["up"] is False    # plan NEVER runs up


def test_cli_up_test_runs_after_printing_plan(tmp_path, capsys, monkeypatch):
    monkeypatch.setattr(LocalMeshBootstrap, "up",
                        lambda self: (True, ["[done] platform up"]), raising=True)
    rc = main(["up", "--env", "test", "--out", str(tmp_path),
               "--generator-dir", GENERATOR_DIR])
    assert rc == 0
    out = capsys.readouterr().out
    assert "[done] platform up" in out


def test_cli_prod_up_refused_without_tty(tmp_path, capsys, monkeypatch):
    # golive posture: prod bring-up needs a real TTY confirm, NO bypass flag.
    monkeypatch.setattr(boot_mod.sys.stdin, "isatty", lambda: False)
    up_ran = {"called": False}
    monkeypatch.setattr(LocalMeshBootstrap, "up",
                        lambda self: up_ran.__setitem__("called", True) or (True, []),
                        raising=True)
    rc = main(["up", "--env", "prod", "--cluster-domain", "corp.example",
               "--authkey", "tskey-x", "--out", str(tmp_path),
               "--generator-dir", GENERATOR_DIR])
    assert rc == 2
    assert up_ran["called"] is False


def test_cli_prod_up_proceeds_on_tty_confirm(tmp_path, monkeypatch):
    monkeypatch.setattr(boot_mod.sys.stdin, "isatty", lambda: True)
    monkeypatch.setattr("builtins.input", lambda *_a: "yes")
    monkeypatch.setattr(LocalMeshBootstrap, "up",
                        lambda self: (True, ["ok"]), raising=True)
    rc = main(["up", "--env", "prod", "--cluster-domain", "corp.example",
               "--authkey", "tskey-x", "--out", str(tmp_path),
               "--generator-dir", GENERATOR_DIR])
    assert rc == 0


def test_cli_prod_up_aborts_when_not_confirmed(tmp_path, monkeypatch):
    monkeypatch.setattr(boot_mod.sys.stdin, "isatty", lambda: True)
    monkeypatch.setattr("builtins.input", lambda *_a: "no")
    up_ran = {"called": False}
    monkeypatch.setattr(LocalMeshBootstrap, "up",
                        lambda self: up_ran.__setitem__("called", True) or (True, []),
                        raising=True)
    rc = main(["up", "--env", "prod", "--cluster-domain", "corp.example",
               "--authkey", "tskey-x", "--out", str(tmp_path),
               "--generator-dir", GENERATOR_DIR])
    assert rc == 1 and up_ran["called"] is False


def test_cli_authkey_file_kept_off_argv(tmp_path, monkeypatch):
    keyfile = tmp_path / "authkey"
    keyfile.write_text("tskey-fromfile\n")
    monkeypatch.setattr(boot_mod.sys.stdin, "isatty", lambda: True)
    monkeypatch.setattr("builtins.input", lambda *_a: "yes")
    seen = {}
    monkeypatch.setattr(LocalMeshBootstrap, "up",
                        lambda self: (seen.__setitem__("key", self.cfg.auth_key), (True, []))[1],
                        raising=True)
    rc = main(["up", "--env", "prod", "--cluster-domain", "corp.example",
               "--authkey-file", str(keyfile), "--out", str(tmp_path),
               "--generator-dir", GENERATOR_DIR])
    assert rc == 0
    assert seen["key"] == "tskey-fromfile"   # trailing newline stripped


def test_module_imports_no_qt():
    import subprocess
    import sys
    studio_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    probe = (
        "import hugmesh_studio.core.local_mesh_bootstrap as m, sys;"
        "assert callable(m.main);"
        "bad=[x for x in sys.modules if x.startswith(('PySide6','PyQt6','PyQt5'))];"
        "assert not bad, bad;"
        "assert 'hugmesh_studio.gui' not in sys.modules"
    )
    env = dict(os.environ, PYTHONPATH=studio_root)
    r = subprocess.run([sys.executable, "-c", probe], env=env,
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr

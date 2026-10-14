"""The record on the Docker-mesh path and the image path (hugmesh-generator#654): Qt-free.

* ``show-record`` prints every brand's effective look with its source and every way's
  effect, in the model's words, from a record file in a fresh argv;
* ``up --record FILE`` and ``plan --record FILE`` start from the record (brand, public
  name, brands, own sign-ins) and keep every other flag;
* the plan says what a Tor address is, and whether a production mesh HOLDS it (D14);
* the TOR_RELEASE hand-over reaches `make stack-up` only when Go live was pressed, and
  an ambient TOR_RELEASE is dropped;
* key generation on the image path is given the brand and the internal root name
  (red on main before #654: gen-provision-keys.sh was started with neither).
"""
from __future__ import annotations

import json
import os


from hugmesh_studio.core import brand_model as bm
from hugmesh_studio.core import local_mesh_bootstrap as lmb
from hugmesh_studio.core import plain_words
from hugmesh_studio.core import worklist_driver as wd
from hugmesh_studio.core.config import DOMAIN_IDP_OWN, Domain, ImageConfig
from hugmesh_studio.core.local_mesh_bootstrap import (LocalMeshBootstrap,
                                                      LocalMeshBootstrapConfig, main)
from hugmesh_studio.core.platform_info import HostInfo
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry
from hugmesh_studio.core.worklist_driver import WorklistDriver

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


def _record_file(tmp_path) -> str:
    sb = bm.Superbrand(id="acme", title="Acme Mesh", org="example", public_name="mesh.example",
                       internal_root="acme.internal",
                       look={"primary": "#112233", "font": "System UI"})
    rec = bm.BrandRecord(superbrand=sb, brands=[
        Domain(name="shop.mesh.example", title="Shop", idp=DOMAIN_IDP_OWN, tor=True,
               look={"primary": "#aa0000"}, issuer_port=8002),
        Domain(name="blog.mesh.example", title="Blog")])
    return bm.save_record(rec, str(tmp_path / "brand-record.json"))


# ── show-record ────────────────────────────────────────────────────────────────────
def test_show_record_prints_every_brand_with_sources_effects_and_the_models_words(tmp_path, capsys):
    rc = main(["show-record", "--record", _record_file(tmp_path),
               "--generator-dir", GENERATOR_DIR])
    out = capsys.readouterr().out
    assert rc == 0, out
    assert "superbrand: acme — Acme Mesh" in out
    assert "brand shop-mesh-example: shop.mesh.example — Shop" in out
    assert "brand blog-mesh-example: blog.mesh.example — Blog" in out
    assert (f"sign-in: {plain_words.SIGN_IN['own']}; sign-in port 8002 recorded — the "
            "Docker mesh still publishes it at 8001 (by table position) until the mesh "
            "reads the record") in out
    assert f"sign-in: {plain_words.SIGN_IN['superdomain']}" in out
    shop = out.split("brand shop-mesh-example")[1].split("brand blog-mesh-example")[0]
    assert "primary    #aa0000                  — this brand's own" in shop
    assert "font       System UI                — inherited from the superbrand" in shop
    assert "Tor address: yes" in shop
    for (way, path), sentence in plain_words.WAY_EFFECT.items():
        assert sentence in shop, (way, path)
    assert "Docker mesh plan:  Brand: acme  Domain: mesh.example" in out
    assert "kind cluster:      brand acme; Tor per brand: shop.mesh.example" in out
    assert "builder profile:   BRAND='acme' BRAND_TITLE='Acme Mesh' SUPERDOMAIN='acme.internal'" in out
    # the printed words are the model's: no word the brand screens forbid
    for word in plain_words.FORBIDDEN_ON_SCREENS:
        assert word not in out.lower(), word


def test_show_record_without_a_file_shows_the_flags_and_refuses_a_bad_record(tmp_path, capsys):
    rc = main(["show-record", "--brand", "acme", "--cluster-domain", "mesh.example",
               "--own-casdoor-domain", "shop.mesh.example", "--generator-dir", GENERATOR_DIR])
    out = capsys.readouterr().out
    assert rc == 0 and "brand shop-mesh-example" in out
    bad = tmp_path / "bad.json"
    bad.write_text(json.dumps({"schema": 1, "superbrand": {"id": "acme"},
                               "brands": [{"name": "x.example", "id": "default"}]}))
    rc = main(["show-record", "--record", str(bad), "--generator-dir", GENERATOR_DIR])
    out = capsys.readouterr().out
    assert rc == 1 and "PROBLEMS" in out and "reserved" in out
    rc = main(["show-record", "--record", str(tmp_path / "missing.json"),
               "--generator-dir", GENERATOR_DIR])
    assert rc == 2


# ── up / plan --record ─────────────────────────────────────────────────────────────
def test_up_record_starts_from_the_record_and_keeps_every_other_flag(tmp_path, monkeypatch, capsys):
    seen = {}

    def _fake_up(self, on_line=None, cancel=None):
        seen["cfg"] = self.cfg
        return True, ["[done] fake"]

    monkeypatch.setattr(LocalMeshBootstrap, "up", _fake_up)
    rc = main(["up", "--record", _record_file(tmp_path), "--services", "tor",
               "--web-locales", "de", "--generator-dir", GENERATOR_DIR])
    assert rc == 0
    cfg = seen["cfg"]
    assert cfg.brand == "acme" and cfg.cluster_domain == "mesh.example"
    assert cfg.own_idp_domains == ("shop.mesh.example",)
    assert [r["name"] for r in cfg.domains] == ["shop.mesh.example", "blog.mesh.example"]
    assert cfg.domains[0]["look"] == {"primary": "#aa0000"} and cfg.domains[0]["issuer_port"] == 8002
    assert cfg.superbrand["title"] == "Acme Mesh" and cfg.superbrand["look"]["font"] == "System UI"
    assert cfg.services == ("tor",) and cfg.web_locales == ("de",)
    plan = capsys.readouterr().out
    assert "Brand:      acme  (Acme Mesh)" in plan
    assert "shop.mesh.example: its own onion (key ‘shop-mesh-example’), served as brand ‘shop-mesh-example’" in plan


def test_plan_record_applies_the_records_tor_way_and_refuses_a_contradicting_flag(tmp_path, capsys):
    """The record's superbrand says Tor yes: plan --record (no --with-tor) starts the
    mesh with Tor on and mints the brand's onion; --services without tor contradicts
    it and is refused with the reason; a record saying no refuses --with-tor."""
    path = _record_file(tmp_path)
    rec = bm.load_record(path)
    assert bm.set_ways(rec, "acme", tor=True) == []
    bm.save_record(rec, path)
    rc = main(["plan", "--record", path, "--generator-dir", GENERATOR_DIR])
    out = capsys.readouterr().out
    assert rc == 0 and "TOR=on" in out
    assert "shop.mesh.example: its own onion (key ‘shop-mesh-example’), served as brand ‘shop-mesh-example’" in out
    assert "NO onion" not in out
    # the plan says the record's sign-in port is not what this mesh publishes on
    assert "host port 8001" in out
    assert "(the brand record stores sign-in port 8002; this mesh does not read it yet)" in out
    rc = main(["plan", "--record", path, "--services", "tuwunel", "--generator-dir", GENERATOR_DIR])
    err = capsys.readouterr().err
    assert rc == 2 and "says this mesh has a Tor address, but --services leaves out tor" in err
    assert bm.set_ways(rec, "acme", tor=False) == []
    bm.save_record(rec, path)
    rc = main(["plan", "--record", path, "--with-tor", "--generator-dir", GENERATOR_DIR])
    err = capsys.readouterr().err
    assert rc == 2 and "says this mesh has no Tor address, but --with-tor was given" in err
    rc = main(["plan", "--record", path, "--generator-dir", GENERATOR_DIR])
    out = capsys.readouterr().out
    assert rc == 0 and "TOR=off" in out and "NO onion for the Tor domains" in out
    # show-record on the same record gives the same answer as the plan
    rc = main(["show-record", "--record", path, "--generator-dir", GENERATOR_DIR])
    out = capsys.readouterr().out
    assert rc == 0 and "Tor address: no" in out.split("brand shop-mesh-example")[0]


def test_show_record_refuses_a_brand_id_that_names_a_profile_as_up_does(tmp_path, capsys):
    bad = tmp_path / "bad.json"
    bad.write_text(json.dumps({"schema": 1, "superbrand": {"id": "acme"},
                               "brands": [{"name": "example", "idp": "superdomain"}]}))
    rc = main(["show-record", "--record", str(bad), "--generator-dir", GENERATOR_DIR])
    out = capsys.readouterr().out
    assert rc == 1 and "names an existing brands/example.conf profile" in out
    assert bm.main(["validate", "--record", str(bad), "--generator-dir", GENERATOR_DIR]) == 1
    assert "names an existing brands/example.conf profile" in capsys.readouterr().out


def test_plan_record_is_the_same_record_the_saved_mesh_round_trips(tmp_path):
    path = _record_file(tmp_path)
    cfg = LocalMeshBootstrapConfig()
    bm.apply_record_to_bootstrap(bm.load_record(path), cfg)
    again = LocalMeshBootstrapConfig.from_dict(json.loads(json.dumps(cfg.to_dict())))
    assert again == cfg
    assert bm.record_from_bootstrap(again).superbrand.look == {"primary": "#112233",
                                                               "font": "System UI"}


def test_validate_refuses_a_record_a_save_would_refuse(tmp_path):
    cfg = LocalMeshBootstrapConfig(brand="acme", cluster_domain="mesh.example",
                                   domains=({"name": "x.mesh.example", "id": "default",
                                             "idp": "superdomain", "optional_services": [],
                                             "title": ""},))
    problems = LocalMeshBootstrap(GENERATOR_DIR, cfg).validate()
    assert any("brand record" in p and "reserved" in p for p in problems)
    cfg2 = LocalMeshBootstrapConfig(brand="acme", cluster_domain="mesh.example",
                                    superbrand={"ways": {"public": {"provider": "duckdns",
                                                                    "inputs": {"t": "ghp_" + "a" * 36}}}})
    problems = LocalMeshBootstrap(GENERATOR_DIR, cfg2).validate()
    assert any("token-shaped" in p for p in problems)
    # an untouched config has none of this to say
    assert not any("brand record" in p
                   for p in LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig()).validate())


# ── the plan's Tor sentences and the production hold (D1, D14) ─────────────────────
def test_plan_says_what_a_tor_address_is_and_whether_production_holds_it(tmp_path):
    test_plan = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(with_tor=True)).plan()
    assert "already ON" not in test_plan
    assert "A Tor address is another way in" in test_plan and "starts with this mesh (a test mesh)" in test_plan
    assert "HELD" not in test_plan
    prod = LocalMeshBootstrapConfig(env="prod", with_tor=True, cluster_domain="mesh.example",
                                    auth_key="k",
                                    domains=({"name": "shop.mesh.example", "title": "",
                                              "idp": "superdomain", "optional_services": [],
                                              "tor": True},))
    held = LocalMeshBootstrap(GENERATOR_DIR, prod).plan()
    assert "HELD: a production mesh starts no Tor address until Go live" in held
    assert "It is HELD until Go live" in held
    assert prod.tor_held() is True
    released = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(
        env="prod", with_tor=True, cluster_domain="mesh.example", auth_key="k",
        tor_release=True)).plan()
    assert "RELEASED at start (TOR_RELEASE=1" in released and "HELD" not in released
    assert LocalMeshBootstrapConfig(env="test", with_tor=True).tor_held() is False
    assert LocalMeshBootstrapConfig(env="prod", with_tor=False).tor_held() is False


def test_tor_release_reaches_stack_up_only_when_go_live_was_pressed(tmp_path, monkeypatch):
    seen = []

    class _Node:
        web_url = "https://localhost"

        def start(self, on_line=None, cancel=None):
            seen.append(os.environ.get("TOR_RELEASE"))
            return False, "stopped by the test"           # ends the bring-up here

    def _drive(cfg):
        boot = LocalMeshBootstrap(GENERATOR_DIR, cfg)
        monkeypatch.setattr(boot, "_prepare", lambda *_a, **_k: True)
        monkeypatch.setattr(boot, "generate_creds", lambda: (True, "fake"))
        monkeypatch.setattr(boot, "read_superadmin", lambda path=None: {"username": "u", "password": "p"})
        monkeypatch.setattr(boot, "_stack_node", lambda: _Node())
        return boot.up()

    monkeypatch.setenv("TOR_RELEASE", "1")                # an ambient value nobody chose
    ok, _log = _drive(LocalMeshBootstrapConfig(env="prod", with_tor=True,
                                               cluster_domain="mesh.example", auth_key="k"))
    assert ok is False and seen == [None]                 # dropped: production holds
    _drive(LocalMeshBootstrapConfig(env="prod", with_tor=True, cluster_domain="mesh.example",
                                    auth_key="k", tor_release=True))
    assert seen == [None, "1"]                            # Go live pressed: released
    assert main(["plan", "--tor-release", "--generator-dir", GENERATOR_DIR]) == 0


# ── the image path: key generation gets the brand and the internal root (D5) ───────
def _host():
    return HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                    has_kvm=False, is_root=True, builder_image="hugmesh-builder")


def test_key_generation_is_given_the_brand_and_the_internal_root_name(monkeypatch, tmp_path):
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                       cluster_domain="mesh.example", superdomain="core.acme.internal",
                       output_dir=str(tmp_path / "out"))
    wl = WorklistConfig(base=base, entries=[WorklistEntry(role="pki", platform="x86")])
    calls = []

    class _Proc:
        stdout = iter(["ok"])

        def wait(self):
            return 0

    class _Build:
        def __init__(self, *a, **k):
            pass

        def run(self, cfg, backend, on_line=None):
            return 0

    monkeypatch.setattr(wd, "BuildDriver", _Build)
    monkeypatch.setattr(wd.subprocess, "Popen",
                        lambda cmd, **kw: calls.append((list(cmd), kw)) or _Proc())
    monkeypatch.setenv("BRAND", "someone-elses-shell-brand")
    WorklistDriver(str(tmp_path), wl, host=_host()).run_all()
    assert len(calls) == 1
    cmd, kw = calls[0]
    assert cmd[cmd.index("--superdomain") + 1] == "core.acme.internal"
    assert kw["env"]["BRAND"] == "acme"                   # the worklist's, not the shell's
    assert kw["cwd"] == str(tmp_path)
    # the derived root when none is set: <brand>.internal, as the script derives it too
    base.superdomain = ""
    calls.clear()
    WorklistDriver(str(tmp_path), wl, host=_host()).run_all()
    assert calls[0][0][calls[0][0].index("--superdomain") + 1] == "acme.internal"


def test_the_key_script_parses_superdomain_and_reads_brand(tmp_path):
    """The flag and the env knob the driver now passes are the script's own."""
    text = open(os.path.join(GENERATOR_DIR, wd.GENKEYS_SCRIPT), encoding="utf-8").read()
    assert "--superdomain)" in text and 'EFFECTIVE_SUPERDOMAIN="${SUPERDOMAIN:-${BRAND:-hugmesh}.internal}"' in text

"""The per-domain data model (2026-10-21): each domain's own sign-in settings, its VPN
membership and egress, and per-domain services as the ONE source of what a local
Docker mesh runs (the mesh-wide "Local services" pick retired, with a migration).

Qt-free. Every value here that a row does not set INHERITS the mesh-wide one, and a
config, record or manifest that sets none of them writes the bytes it wrote before.
"""
from __future__ import annotations

import json
import os

import pytest

from hugmesh_studio.core import brand_model, domain_reach, own_casdoor
from hugmesh_studio.core.config import (
    DOMAIN_IDP_OWN, DOMAIN_IDP_SUPERDOMAIN, SIGNIN_FROM_MESH, SIGNIN_OWN_CASDOOR,
    SIGNIN_OWN_EXTERNAL, Domain, ImageConfig, domain_from_record_row, domain_rows_to_dict,
    domain_signin_problems, effective_signin, has_external_signin, runs_own_casdoor,
    set_domain_signin, signin_problems)
from hugmesh_studio.core.local_mesh_bootstrap import (LocalMeshBootstrap,
                                                      LocalMeshBootstrapConfig)
from hugmesh_studio.core.local_mesh_domains import (bootstrap_domain_records,
                                                    domains_from_bootstrap,
                                                    own_idp_names)
from hugmesh_studio.core.local_services import (domain_local_slugs, mesh_plane_slugs,
                                                split_selection)
from hugmesh_studio.core.validate import IdentityValidationError

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
OWN = "mesh.example"
EXT = {"provider": "oidc", "issuer": "https://id.shop.example", "client_id": "shop-app"}


def _mesh(**kw) -> ImageConfig:
    return ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                       cluster_domain=OWN, **kw)


# ── 1. sign-in: inherit, own Casdoor, own external ───────────────────────────────────
def test_a_superdomain_row_inherits_the_mesh_provider_whatever_it_is():
    row = Domain(name="shop.mesh.example")
    s = effective_signin(row, _mesh())
    assert (s.where, s.provider, s.issuer, s.source) == (
        DOMAIN_IDP_SUPERDOMAIN, "casdoor", "", SIGNIN_FROM_MESH)
    mesh = _mesh(idp="entra", idp_issuer="https://login.microsoftonline.com/t/v2.0",
                 idp_client_id="mesh-app")
    s = effective_signin(row, mesh)
    assert s.provider == "entra" and s.issuer == mesh.idp_issuer
    assert s.client_id == "mesh-app" and s.source == SIGNIN_FROM_MESH
    # the JWKS is the one derivation config owns (Entra's discovery keys path)
    assert s.jwks == "https://login.microsoftonline.com/t/v2.0/discovery/v2.0/keys"


def test_an_own_row_without_settings_is_its_own_casdoor_as_before():
    row = Domain(name="shop.mesh.example", idp=DOMAIN_IDP_OWN)
    s = effective_signin(row, _mesh(idp="oidc", idp_issuer="https://id.mesh.example",
                                    idp_client_id="m"))
    # never the mesh's external provider: one issuer can only be one brand
    assert (s.provider, s.source) == ("casdoor", SIGNIN_OWN_CASDOOR)
    assert runs_own_casdoor(row) and not has_external_signin(row)


def test_an_own_row_with_an_external_provider_trusts_its_own_issuer():
    row = Domain(name="shop.mesh.example", issuer_port=8003)
    assert set_domain_signin(row, DOMAIN_IDP_OWN, **EXT) == []
    assert row.idp == DOMAIN_IDP_OWN and row.idp_settings == EXT
    assert row.issuer_port == 0, "a brand with no Casdoor must not hold a Casdoor port"
    s = effective_signin(row)
    assert (s.provider, s.issuer, s.client_id, s.source) == (
        "oidc", EXT["issuer"], "shop-app", SIGNIN_OWN_EXTERNAL)
    assert s.jwks == "https://id.shop.example/.well-known/jwks"
    assert has_external_signin(row) and not runs_own_casdoor(row)


def test_the_one_writer_clears_settings_on_superdomain_and_on_casdoor():
    row = Domain(name="shop.mesh.example")
    assert set_domain_signin(row, DOMAIN_IDP_OWN, **EXT) == []
    assert set_domain_signin(row, DOMAIN_IDP_OWN, provider="casdoor") == []
    assert row.idp_settings == {} and runs_own_casdoor(row)
    assert set_domain_signin(row, DOMAIN_IDP_OWN, **EXT) == []
    assert set_domain_signin(row, DOMAIN_IDP_SUPERDOMAIN, **EXT) == []
    assert row.idp == DOMAIN_IDP_SUPERDOMAIN and row.idp_settings == {}
    # the same writer works on a recorded row (a dict), and omits the empty block
    rec = {"name": "shop.mesh.example", "idp": "superdomain", "issuer_port": 8002}
    assert set_domain_signin(rec, DOMAIN_IDP_OWN, **EXT) == []
    assert rec["idp_settings"] == EXT and "issuer_port" not in rec
    assert set_domain_signin(rec, DOMAIN_IDP_SUPERDOMAIN) == []
    assert "idp_settings" not in rec


@pytest.mark.parametrize("kw,needle", [
    (dict(provider="oidc", issuer="http://id.shop.example", client_id="a"), "https://"),
    (dict(provider="oidc", issuer="https://id.shop.example"), "client id"),
    # a client id rides in URL query strings: '+' decodes to a space, '=' splits it
    (dict(provider="oidc", issuer="https://id.shop.example", client_id="a+b"),
     "client id"),
    (dict(provider="oidc", issuer="https://id.shop.example", client_id="a=b"),
     "client id"),
    (dict(provider="oidc", issuer="https://id.shop.example", client_id="a",
          jwks="http://k"), "https://"),
    (dict(provider="nope", issuer="https://x.example", client_id="a"), "must be one of"),
    (dict(provider="casdoor", issuer="https://x.example"), "Casdoor"),
])
def test_the_writer_refuses_what_the_mesh_wide_rules_refuse_and_writes_nothing(kw, needle):
    row = Domain(name="shop.mesh.example")
    before = (row.idp, dict(row.idp_settings))
    problems = set_domain_signin(row, DOMAIN_IDP_OWN, **kw)
    assert problems and any(needle in p for p in problems), problems
    assert (row.idp, row.idp_settings) == before


def test_one_issuer_is_one_brand():
    mesh = _mesh(idp="oidc", idp_issuer="https://id.shop.example", idp_client_id="m")
    row = Domain(name="shop.mesh.example")
    assert any("mesh's own" in p for p in set_domain_signin(row, "own", mesh=mesh, **EXT))
    other = Domain(name="blog.mesh.example", idp=DOMAIN_IDP_OWN, idp_settings=dict(EXT))
    assert any("blog.mesh.example already uses" in p
               for p in set_domain_signin(row, "own", others=[other], **EXT))


def test_settings_on_a_superdomain_row_are_a_problem_not_silently_kept():
    row = Domain(name="shop.mesh.example", idp_settings=dict(EXT))
    assert any("never be read" in p for p in domain_signin_problems(row))


def test_the_strict_loader_refuses_a_junk_block_and_cleans_a_good_one():
    for bad in ("text", {"provider": "zzz"}, {"secret": "x"}, {"issuer": 5}):
        with pytest.raises(ValueError):
            ImageConfig._domain_from_dict({"name": "a.example", "idp_settings": bad})
    d = ImageConfig._domain_from_dict({"name": "a.example", "idp": "own",
                                       "idp_settings": {"provider": " oidc ",
                                                        "issuer": EXT["issuer"],
                                                        "client_id": "shop-app",
                                                        "jwks": ""}})
    assert d.idp_settings == EXT
    # a block that only says Casdoor is the default: stored empty, old bytes kept
    d = ImageConfig._domain_from_dict({"name": "a.example",
                                       "idp_settings": {"provider": "casdoor"}})
    assert d.idp_settings == {} and "idp_settings" not in domain_rows_to_dict([d])[0]
    # the lenient saved-mesh loader carries it by the field list
    assert domain_from_record_row({"name": "a", "idp_settings": dict(EXT)}).idp_settings \
        == EXT


def test_validate_identity_refuses_a_bad_domain_block():
    cfg = _mesh(domains=[Domain(name="shop.mesh.example", idp=DOMAIN_IDP_OWN,
                                idp_settings={"provider": "oidc",
                                              "issuer": "http://plain.example",
                                              "client_id": "a"})])
    with pytest.raises(IdentityValidationError, match="https://"):
        cfg.validate_identity()
    cfg.domains[0].idp_settings["issuer"] = "https://id.shop.example"
    cfg.validate_identity()


def test_a_domain_with_its_own_external_provider_gets_no_casdoor_anywhere():
    ext = Domain(name="ext.mesh.example", idp=DOMAIN_IDP_OWN, idp_settings=dict(EXT))
    cas = Domain(name="cas.mesh.example", idp=DOMAIN_IDP_OWN)
    cfg = _mesh(domains=[ext, cas])
    assert cfg.own_idp_domains() == ("cas.mesh.example",)
    assert own_casdoor.own_domain_names([ext, cas]) == ("cas.mesh.example",)
    assert own_idp_names([ext, cas]) == ("cas.mesh.example",)
    # the record keeps the external row's own sign-in (it is not in own_idp_domains,
    # which lists the Casdoors the stack stands up — and that must not flip it)
    md_rows = bootstrap_domain_records([Domain(name=OWN), ext, cas], OWN)
    boot = LocalMeshBootstrapConfig(brand="acme", cluster_domain=OWN, domains=md_rows,
                                    own_idp_domains=own_idp_names([ext, cas]))
    rec = brand_model.record_from_bootstrap(boot)
    got = {d.name: (d.idp, d.idp_settings) for d in rec.brands}
    assert got["ext.mesh.example"] == (DOMAIN_IDP_OWN, EXT)
    assert got["cas.mesh.example"] == (DOMAIN_IDP_OWN, {})
    back = LocalMeshBootstrapConfig(brand="acme")
    brand_model.apply_record_to_bootstrap(rec, back, typed_flags=False)
    assert back.own_idp_domains == ("cas.mesh.example",)
    assert not [p for p in LocalMeshBootstrap(GENERATOR_DIR, boot).validate()
                if "ext.mesh.example" in p]


def test_an_external_domain_is_one_more_issuer_pair_on_the_docker_mesh():
    rows = ({"name": "shop.mesh.example", "title": "", "idp": "own",
             "optional_services": [], "idp_settings": dict(EXT), "tor": True},
            {"name": "cas.mesh.example", "title": "", "idp": "own",
             "optional_services": []})
    boot = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(
        brand="acme", cluster_domain=OWN, domains=rows, with_tor=True,
        own_idp_domains=("cas.mesh.example",)))
    assert boot.external_idp_domains() == [
        ("shop.mesh.example", EXT["issuer"], "shop-mesh-example")]
    env = boot._stack_node()._build_env(write_overlays=False)
    assert env["APP_TENANCY_ISSUERS"].split(",")[-1] == (
        "https://id.shop.example=shop-mesh-example")
    assert "shop.mesh.example=shop-mesh-example" in env["APP_TENANCY_HOSTS"].split(",")
    # its onion opens its own sign-in, because the gateway now has its issuer
    assert ("shop.mesh.example", "shop-mesh-example", "shop-mesh-example") in \
        boot.tor_domains()
    assert "issuer https://id.shop.example" in boot.plan()
    assert any("shop.mesh.example signs in through its own" in w for w in boot.warnings())
    # ONLY an external domain: still no Casdoor, still the registry
    only = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(
        brand="acme", cluster_domain=OWN, domains=rows[:1]))
    env = only._stack_node()._build_env(write_overlays=False)
    assert env["OWN_CASDOOR"] == ""
    assert env["APP_TENANCY_ISSUERS"] == (
        "http://localhost:8000=default,https://id.shop.example=shop-mesh-example")
    # a row whose block is refused is never registered
    bad = dict(rows[0], idp_settings={"provider": "oidc", "issuer": "http://x",
                                      "client_id": "a"})
    assert LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(
        cluster_domain=OWN, domains=(bad,))).external_idp_domains() == []


def test_the_bootstrap_validate_names_a_bad_recorded_block():
    rows = ({"name": "ext.mesh.example", "title": "", "idp": "own",
             "optional_services": [], "idp_settings": {"provider": "oidc",
                                                       "issuer": "http://x.example",
                                                       "client_id": "a"}},)
    boot = LocalMeshBootstrapConfig(brand="acme", cluster_domain=OWN, domains=rows)
    assert any("ext.mesh.example" in p and "https://" in p
               for p in LocalMeshBootstrap(GENERATOR_DIR, boot).validate())


# ── 2. reach: VPN membership and egress ──────────────────────────────────────────────
def _record(*rows) -> brand_model.BrandRecord:
    return brand_model.BrandRecord(
        superbrand=brand_model.Superbrand(id="acme", public_name=OWN), brands=list(rows))


def test_reach_is_inherited_until_a_domain_says_otherwise():
    row = Domain(name="shop.mesh.example")
    prod = LocalMeshBootstrapConfig(env="prod", cluster_domain=OWN)
    assert domain_reach.effective_tailnet(row, prod) == (True, domain_reach.REACH_FROM_MESH)
    assert domain_reach.effective_tailnet(row, LocalMeshBootstrapConfig()) == (
        False, domain_reach.REACH_FROM_MESH)
    assert domain_reach.effective_tailnet(row, _mesh()).on is True
    img = _mesh(egress_vpn="/etc/hugmesh/egress/mesh.conf")
    assert domain_reach.effective_egress(row, img) == (
        "vpn", "/etc/hugmesh/egress/mesh.conf", domain_reach.REACH_FROM_MESH)
    dock = LocalMeshBootstrapConfig(services=("egress-vpn",),
                                    egress_vpn_conf="/home/x/wg.conf")
    assert domain_reach.effective_egress(row, dock).conf == "/home/x/wg.conf"
    assert domain_reach.effective_egress(row, LocalMeshBootstrapConfig()).mode == "direct"


def test_set_ways_writes_and_clears_reach_through_the_one_writer():
    rec = _record(Domain(name="shop.mesh.example"))
    bid = "shop-mesh-example"
    assert brand_model.set_ways(rec, bid, tailnet=False,
                                egress={"mode": "vpn", "conf": " "}) == []
    row = rec.brands[0]
    assert row.ways == {"tailnet": False, "egress": {"mode": "vpn"}}
    img = _mesh(egress_vpn="/etc/hugmesh/egress/mesh.conf")
    # a VPN with no file of its own uses the mesh's file
    assert domain_reach.effective_egress(row, img) == (
        "vpn", "/etc/hugmesh/egress/mesh.conf", domain_reach.REACH_OWN)
    assert domain_reach.effective_tailnet(row, img) == (False, domain_reach.REACH_OWN)
    assert brand_model.set_ways(rec, bid, tailnet=domain_reach.REACH_INHERIT,
                                egress=domain_reach.REACH_INHERIT) == []
    assert row.ways == {}
    assert "ways" not in domain_rows_to_dict([row])[0]


@pytest.mark.parametrize("kw,needle", [
    (dict(tailnet="yes"), "tailnet"),
    (dict(egress={"mode": "tunnel"}), "egress mode"),
    (dict(egress={"mode": "direct", "conf": "/x.conf"}), "never be read"),
    (dict(egress={"mode": "vpn", "conf": "relative.conf"}), "absolute"),
    (dict(egress={"mode": "vpn", "conf": "/x\nwg0.conf"}), "one line"),
    (dict(egress={"mode": "vpn", "extra": 1}), "unknown egress field"),
    (dict(egress="vpn"), "object"),
])
def test_set_ways_refuses_a_bad_reach_and_writes_nothing(kw, needle):
    rec = _record(Domain(name="shop.mesh.example"))
    problems = brand_model.set_ways(rec, "shop-mesh-example", **kw)
    assert problems and any(needle in p for p in problems), problems
    assert rec.brands[0].ways == {}


def test_the_superbrand_has_no_per_domain_reach():
    rec = _record()
    assert any("unknown way" in p for p in brand_model.set_ways(rec, "acme", tailnet=True))


@pytest.mark.parametrize("conf", [
    "/x PrivateKey = yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=",
    "/x [Interface]", "/x <key>", "/x -----BEGIN PRIVATE KEY-----"])
def test_the_record_save_refuses_provider_file_contents_in_an_egress_conf(conf):
    """The conf is a POINTER: text that looks like the file's contents is refused at
    save (the record is shared; a key pasted into the path field must never land)."""
    rec = _record(Domain(name="shop.mesh.example",
                         ways={"egress": {"mode": "vpn", "conf": conf}}))
    assert any("contents" in p for p in brand_model.record_problems(rec))


def test_egress_files_are_checked_where_the_mesh_starts(tmp_path):
    good = tmp_path / "wg.conf"
    good.write_text("[Interface]\nPrivateKey = x\nAddress = 10.0.0.2/32\n"
                    "[Peer]\nPublicKey = y\nEndpoint = 1.2.3.4:51820\n"
                    "AllowedIPs = 0.0.0.0/0\n")
    bad = tmp_path / "junk.conf"
    bad.write_text("hello\n")
    rows = ({"name": "a.mesh.example", "ways": {"egress": {"mode": "vpn",
                                                          "conf": str(good)}}},
            {"name": "b.mesh.example", "ways": {"egress": {"mode": "vpn",
                                                          "conf": str(bad)}}},
            {"name": "c.mesh.example", "ways": {"egress": {"mode": "vpn"}}},
            {"name": "d.mesh.example", "ways": {"egress": {"mode": "direct"}}})
    problems = domain_reach.egress_conf_problems(rows, LocalMeshBootstrapConfig())
    assert not any(p.startswith("a.mesh.example") for p in problems)
    assert any(p.startswith("b.mesh.example") for p in problems)
    assert any(p.startswith("c.mesh.example") and "neither" in p for p in problems)
    assert not any(p.startswith("d.mesh.example") for p in problems)
    boot = LocalMeshBootstrapConfig(cluster_domain=OWN, domains=rows)
    assert any("b.mesh.example" in p
               for p in LocalMeshBootstrap(GENERATOR_DIR, boot).validate())


# ── 3. per-domain services: the one source; the "Local services" pick retired ────────
def test_the_split_covers_every_local_slug_once():
    assert set(domain_local_slugs()) | set(mesh_plane_slugs()) == set(
        domain_local_slugs() + mesh_plane_slugs())
    assert not set(domain_local_slugs()) & set(mesh_plane_slugs())
    assert "tuwunel" in domain_local_slugs() and "tor" in mesh_plane_slugs()
    assert split_selection(("tuwunel", "tor", "bogus")) == (("tuwunel",), ("tor", "bogus"))


def test_a_saved_mesh_wide_selection_migrates_into_the_domains():
    old = {"brand": "acme", "cluster_domain": OWN,
           "services": ["tuwunel", "tor", "wiki", "games"],
           "social": True, "with_tor": True}
    before = set(old["services"])
    cfg = LocalMeshBootstrapConfig.from_dict(old)
    # the domain slugs left the mesh-wide pick; the mesh-plane ones stayed
    assert cfg.services == ("tor", "wiki")
    # the own domain, implicit before, is now a row carrying them — and walked, as the
    # implicit cluster default always counted
    assert cfg.domains == ({"name": OWN, "title": "", "idp": "superdomain",
                            "optional_services": ["tuwunel", "games"]},)
    assert cfg.domain_services_reviewed == (OWN,)
    # and the mesh runs exactly what it ran
    assert set(cfg.effective_services()) == before
    assert (cfg.effective_social(), cfg.effective_with_tor(), cfg.effective_games()) == (
        True, True, True)
    # the legacy mirrors every raw reader still reads agree with what runs
    assert (cfg.social, cfg.with_tor) == (True, True)
    md = domains_from_bootstrap(cfg)
    assert md.by_name(OWN).optional_services == ["tuwunel", "games"]
    assert OWN in md.domain_services_reviewed
    # a second load changes nothing (the migration is idempotent)
    again = LocalMeshBootstrapConfig.from_dict(json.loads(json.dumps(cfg.to_dict())))
    assert again.to_dict() == cfg.to_dict()


def test_migration_fills_only_the_domains_without_services_of_their_own():
    cfg = LocalMeshBootstrapConfig.from_dict({
        "brand": "acme", "cluster_domain": OWN, "services": ["tuwunel", "anubis"],
        "domains": [{"name": "a.mesh.example", "optional_services": ["owncast"]},
                    {"name": "b.mesh.example"}],
        "domain_services_reviewed": ["a.mesh.example"]})
    by = {r["name"]: r.get("optional_services") for r in cfg.domains}
    assert by == {OWN: ["tuwunel"], "a.mesh.example": ["owncast"],
                  "b.mesh.example": ["tuwunel"]}
    assert cfg.services == ("anubis",)
    assert cfg.domain_services_reviewed == (OWN, "a.mesh.example")
    assert set(cfg.effective_services()) == {"tuwunel", "anubis", "owncast"}


def test_an_explicit_empty_or_mesh_plane_only_selection_is_not_touched():
    for svc in ([], ["tor", "egress-vpn"]):
        d = LocalMeshBootstrapConfig(services=tuple(svc), with_tor="tor" in svc).to_dict()
        cfg = LocalMeshBootstrapConfig.from_dict(d)
        assert cfg.to_dict() == d
        assert cfg.services == tuple(svc) and cfg.domains == ()


def test_no_selection_and_no_domain_choice_stays_none():
    cfg = LocalMeshBootstrapConfig.from_dict(LocalMeshBootstrapConfig().to_dict())
    assert cfg.services is None and cfg.effective_services() is None
    assert cfg.to_dict() == LocalMeshBootstrapConfig().to_dict()


def test_a_domain_choice_runs_on_the_docker_mesh():
    cfg = LocalMeshBootstrapConfig(
        services=("tor",), domains=({"name": "a.mesh.example",
                                     "optional_services": ["phpbb", "owncast"]},))
    assert cfg.effective_services() == ("tor", "phpbb", "owncast")
    assert cfg.effective_phpbb() and cfg.federation_services() == ("owncast",)
    env = LocalMeshBootstrap(GENERATOR_DIR, cfg)._stack_node()._build_env(
        write_overlays=False)
    assert env["PHPBB"] == "1" and env["TOR"] == "1" and env["SOCIAL"] == ""
    assert "owncast" in env.get("HUGMESH_FEDERATION_ENABLE", "")
    # services None, legacy flags, plus a domain choice: the flags join the union
    legacy = LocalMeshBootstrapConfig(with_tor=True, domains=(
        {"name": "a.mesh.example", "optional_services": ["games"]},))
    assert legacy.effective_services() == ("tor", "games")


def test_the_stack_env_is_the_same_before_and_after_migration():
    old = LocalMeshBootstrapConfig(brand="acme", services=("tuwunel", "tor", "owncast"))
    migrated = LocalMeshBootstrapConfig.from_dict(old.to_dict())
    assert migrated.services == ("tor",)
    e1 = LocalMeshBootstrap(GENERATOR_DIR, old)._stack_node()._build_env(
        write_overlays=False)
    e2 = LocalMeshBootstrap(GENERATOR_DIR, migrated)._stack_node()._build_env(
        write_overlays=False)
    assert e1 == e2


# ── 4. byte-identical when nothing new is set ────────────────────────────────────────
def test_nothing_set_writes_no_new_key_anywhere():
    row = Domain(name="a.mesh.example", title="A", optional_services=["games"])
    cfg = _mesh(domains=[row])
    texts = [json.dumps(cfg.to_dict(), sort_keys=True),
             json.dumps(cfg.mesh_manifest(), sort_keys=True),
             json.dumps(bootstrap_domain_records([Domain(name=OWN), row], OWN)),
             json.dumps(LocalMeshBootstrapConfig(
                 domains=bootstrap_domain_records([row], OWN)).to_dict())]
    for t in texts:
        for key in ('"idp_settings"', '"tailnet"', '"egress"'):
            assert key not in t, (key, t)
    assert domain_rows_to_dict([row])[0] == {
        "name": "a.mesh.example", "title": "A", "images": [],
        "optional_services": ["games"], "idp": "superdomain"}
    # a recorded row that chose nothing changes nothing the stack is started with
    plain = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(
        cluster_domain=OWN))._stack_node()._build_env(write_overlays=False)
    rows = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(
        cluster_domain=OWN, domains=bootstrap_domain_records(
            [Domain(name=OWN), Domain(name="a.mesh.example")], OWN))
    )._stack_node()._build_env(write_overlays=False)
    assert plain == rows

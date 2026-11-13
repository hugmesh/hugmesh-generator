"""Per-domain sign-in METHODS (hugmesh-generator#1107, operator decision 2026-11-13).

Each domain offers its people a subset of password / Google / Discord. The contract
(the issue's comment):
  * ``Domain.signin_methods`` and, for the mesh's own domain,
    ``ImageConfig.cluster_domain_signin_methods``: a list from SIGNIN_METHODS in that
    order; absent or empty = password only (today's behaviour), no inheritance;
  * ONE writer (``set_domain_signin_methods``) refuses an empty set, an unknown method
    and a domain whose sign-in is an external provider, and stores the default as [];
  * junk fails loudly at load; the default keeps every saved shape byte-identical;
  * the field never reaches argv.
"""
from __future__ import annotations

import json

import pytest

from hugmesh_studio.core.config import (
    DEFAULT_SIGNIN_METHODS, DOMAIN_IDP_OWN, DOMAIN_IDP_SUPERDOMAIN, SIGNIN_METHODS,
    Domain, ImageConfig, clean_signin_methods, domain_rows_to_dict,
    effective_signin_methods, manifest_domain_rows, set_domain_signin,
    set_domain_signin_methods, signin_methods_problem)


def _mesh_cfg(**kw) -> ImageConfig:
    base = dict(mode="mesh", domains=[Domain(name="shop.mesh.example")])
    base.update(kw)
    return ImageConfig(**base)


# ── the vocabulary ──────────────────────────────────────────────────────────────────
def test_the_methods_and_the_default():
    assert SIGNIN_METHODS == ("password", "google", "discord")
    assert DEFAULT_SIGNIN_METHODS == ("password",)
    assert effective_signin_methods([]) == ["password"]
    assert effective_signin_methods(None) == ["password"]
    assert effective_signin_methods(["discord", "google"]) == ["google", "discord"]


def test_clean_stores_canonical_order_and_the_default_as_empty():
    assert clean_signin_methods(["password"]) == []
    assert clean_signin_methods([]) == []
    assert clean_signin_methods(["discord", "password"]) == ["password", "discord"]
    assert clean_signin_methods(["google"]) == ["google"]


@pytest.mark.parametrize("junk", ["password", ["github"], ["password", "password"],
                                  [1], {"password": True}])
def test_problem_names_every_kind_of_junk(junk):
    assert signin_methods_problem(junk)


@pytest.mark.parametrize("ok", [None, [], ["password"], ["google", "discord"]])
def test_problem_accepts_the_valid_shapes(ok):
    assert signin_methods_problem(ok) == ""


# ── the one writer ──────────────────────────────────────────────────────────────────
def test_writer_stores_a_choice_and_the_default_as_empty():
    row = Domain(name="shop.mesh.example")
    assert set_domain_signin_methods(row, ["discord", "password"]) == []
    assert row.signin_methods == ["password", "discord"]
    assert set_domain_signin_methods(row, ["password"]) == []
    assert row.signin_methods == []


def test_writer_works_on_a_recorded_row_dict():
    row = {"name": "shop.mesh.example"}
    assert set_domain_signin_methods(row, ["google"]) == []
    assert row["signin_methods"] == ["google"]
    assert set_domain_signin_methods(row, ["password"]) == []
    assert "signin_methods" not in row


@pytest.mark.parametrize("bad", [[], ["github"], ["google", "google"]])
def test_writer_refuses_and_writes_nothing(bad):
    row = Domain(name="shop.mesh.example", signin_methods=["google"])
    problems = set_domain_signin_methods(row, bad)
    assert problems
    assert row.signin_methods == ["google"]


def test_writer_refuses_a_domain_with_an_external_provider():
    row = Domain(name="shop.mesh.example", idp=DOMAIN_IDP_OWN,
                 idp_settings={"provider": "oidc", "issuer": "https://id.shop.example",
                               "client_id": "shop"})
    problems = set_domain_signin_methods(row, ["google"])
    assert problems and "external provider" in problems[0]
    assert row.signin_methods == []


def test_writer_follows_an_external_mesh_provider_for_a_superdomain_row():
    mesh = ImageConfig(idp="oidc", idp_issuer="https://id.mesh.example",
                       idp_client_id="mesh")
    row = Domain(name="shop.mesh.example", idp=DOMAIN_IDP_SUPERDOMAIN)
    assert set_domain_signin_methods(row, ["google"], mesh=mesh)
    assert set_domain_signin_methods(row, ["google"]) == []    # the built-in Casdoor


def test_leaving_casdoor_clears_the_methods():
    row = Domain(name="shop.mesh.example", signin_methods=["password", "google"])
    assert set_domain_signin(row, DOMAIN_IDP_OWN, provider="oidc",
                             issuer="https://id.shop.example", client_id="shop") == []
    assert row.signin_methods == []
    rec = {"name": "shop.mesh.example", "signin_methods": ["google"]}
    assert set_domain_signin(rec, DOMAIN_IDP_OWN, provider="oidc",
                             issuer="https://id.shop.example", client_id="shop") == []
    assert "signin_methods" not in rec


def test_moving_between_casdoor_choices_keeps_the_methods():
    row = Domain(name="shop.mesh.example", signin_methods=["password", "google"])
    assert set_domain_signin(row, DOMAIN_IDP_OWN) == []         # its own Casdoor
    assert row.signin_methods == ["password", "google"]
    assert set_domain_signin(row, DOMAIN_IDP_SUPERDOMAIN) == []
    assert row.signin_methods == ["password", "google"]


# ── saved shapes: the default is byte-identical, a choice round-trips ──────────────
def test_default_row_says_nothing_in_any_saved_shape():
    cfg = _mesh_cfg()
    assert "signin_methods" not in domain_rows_to_dict(cfg.domains)[0]
    assert "signin_methods" not in manifest_domain_rows(cfg.domains)[0]
    d = cfg.to_dict()
    assert "signin_methods" not in d["domains"][0]
    assert "cluster_domain_signin_methods" not in d
    m = cfg.mesh_manifest()
    assert "signin_methods" not in m["domains"][0]
    assert "cluster_domain_signin_methods" not in m


def test_a_choice_round_trips_through_save_and_load(tmp_path):
    cfg = _mesh_cfg(domains=[Domain(name="shop.mesh.example",
                                    signin_methods=["password", "discord"])],
                    cluster_domain_signin_methods=["google"])
    path = tmp_path / "c.json"
    cfg.save(str(path))
    raw = json.loads(path.read_text())
    assert raw["domains"][0]["signin_methods"] == ["password", "discord"]
    assert raw["cluster_domain_signin_methods"] == ["google"]
    back = ImageConfig.load(str(path))
    assert back.domains[0].signin_methods == ["password", "discord"]
    assert back.cluster_domain_signin_methods == ["google"]
    m = back.mesh_manifest()
    assert m["domains"][0]["signin_methods"] == ["password", "discord"]
    assert m["cluster_domain_signin_methods"] == ["google"]


def test_load_normalises_order_and_the_default():
    back = ImageConfig.from_dict({
        "mode": "mesh",
        "domains": [{"name": "a.example", "signin_methods": ["discord", "password"]},
                    {"name": "b.example", "signin_methods": ["password"]}],
        "cluster_domain_signin_methods": ["password"]})
    assert back.domains[0].signin_methods == ["password", "discord"]
    assert back.domains[1].signin_methods == []
    assert back.cluster_domain_signin_methods == []


@pytest.mark.parametrize("junk", ["password", ["github"], ["google", "google"]])
def test_load_refuses_junk_on_a_domain_and_on_the_own_domain(junk):
    with pytest.raises(ValueError, match="signin_methods"):
        ImageConfig.from_dict({"mode": "mesh",
                               "domains": [{"name": "a.example", "signin_methods": junk}]})
    with pytest.raises(ValueError, match="signin_methods"):
        ImageConfig.from_dict({"mode": "mesh", "cluster_domain_signin_methods": junk})


def test_never_reaches_argv():
    plain = _mesh_cfg().to_cli_args()
    chosen = _mesh_cfg(domains=[Domain(name="shop.mesh.example",
                                       signin_methods=["google", "discord"])],
                       cluster_domain_signin_methods=["discord"]).to_cli_args()
    assert plain == chosen

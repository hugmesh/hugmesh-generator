"""Round 2 of the brand record's guards (hugmesh-generator#654), Qt-free. Each test is
one defect the skeptics measured on the first round's head:

* a TEXT GUARD THAT A TRAILING NEWLINE PASSES: a guard written ``^...$`` and used with
  ``.match`` accepts ``value + "\\n"``; ``validate`` printed ok for a record the ``profile``
  verb then crashed on;
* A DESIGN SAVED ON A TEST MESH is a safe description of the mesh and a test mesh has no
  public name: the record must not carry the placeholder apex, and a record's public name
  must not silently beat an explicit ``--cluster-domain``;
* THE DOCKER ROUTE checks a brand design the way the Docker start does (the title rule off,
  the 63-character label), and only the record FILE keeps the strict rules, with a refusal
  that says so;
* THE IMAGE ROUTE's pick and record agree after a design is abandoned (twin of the Docker
  route's test).
"""
from __future__ import annotations

import json
import os
import types

import pytest

from hugmesh_studio.core import brand_model as bm
from hugmesh_studio.core import local_mesh_bootstrap as lmb
from hugmesh_studio.core.config import Domain, ImageConfig
from hugmesh_studio.core.local_mesh_bootstrap import (LocalMeshBootstrap,
                                                      LocalMeshBootstrapConfig)
from hugmesh_studio.core.local_mesh_domains import LocalMeshDomains
from hugmesh_studio.tui.localmesh import sync_brand_session
from hugmesh_studio.tui.superbrand_step import CREATE_KEY, session_for

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


@pytest.fixture(autouse=True)
def _state(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def _file(tmp_path, superbrand: dict, name="r.json") -> str:
    path = tmp_path / name
    path.write_text(json.dumps({"schema": 1, "superbrand": superbrand}), encoding="utf-8")
    return str(path)


# ── 1. a trailing newline is refused by every anchored guard ────────────────────────
@pytest.mark.parametrize("field,value", [
    ("id", "acme\n"), ("title", "Acme\n"), ("org", "x\n"),
    ("public_name", "mesh.example\n"), ("internal_root", "acme.internal\n")])
def test_a_value_with_a_newline_at_its_end_is_refused_by_the_record_checks(field, value):
    """Built straight on the dataclass (a file is stripped on load, see the next test)."""
    sb = bm.Superbrand(**{"id": "acme", "title": "Acme", "org": "x",
                          "public_name": "mesh.example", "internal_root": "acme.internal",
                          field: value})
    rec = bm.BrandRecord(superbrand=sb)
    assert bm.record_problems(rec), f"{field} + newline passed record_problems"
    assert bm.record_problems(rec, docker_start=True), \
        f"{field} + newline passed the Docker start's form of the checks"
    if field != "internal_root":        # the profile strips that one itself
        with pytest.raises(bm.ProfileRefused):
            bm.builder_profile(rec)


def test_a_file_value_with_a_newline_is_stripped_so_validate_and_profile_agree(tmp_path, capsys):
    """The reproduction: validate said ok, profile raised ValueError with a traceback."""
    path = _file(tmp_path, {"id": "acme\n", "title": "Acme", "org": "x",
                            "public_name": "mesh.example\n",
                            "internal_root": "acme.internal\n"})
    assert bm.main(["validate", "--record", path]) == 0
    capsys.readouterr()
    assert bm.main(["profile", "--record", path]) == 0
    out = capsys.readouterr().out
    assert "BRAND='acme'" in out and "\n'" not in out
    assert bm.parse_builder_profile(out)["BRAND"] == "acme"


def test_validate_refuses_org_public_name_and_internal_root_that_profile_would(tmp_path, capsys):
    for field, value in (("org", "Acme & Co"), ("public_name", "Mesh.Example"),
                         ("internal_root", "acme internal")):
        path = _file(tmp_path, {"id": "acme", field: value}, name=f"{field}.json")
        assert bm.main(["validate", "--record", path]) == 1, field
        capsys.readouterr()
        assert bm.main(["profile", "--record", path, "--out",
                        str(tmp_path / f"{field}.p")]) == 1, field
        capsys.readouterr()
        assert not (tmp_path / f"{field}.p").exists()


def test_the_profile_verb_never_prints_a_traceback(tmp_path, capsys, monkeypatch):
    """Whatever slips past the checks, the strict re-read ends in a refusal."""
    path = _file(tmp_path, {"id": "acme", "title": "Acme"})
    monkeypatch.setattr(bm, "builder_profile", lambda rec: "BRAND='acme\n'\n")
    assert bm.main(["profile", "--record", path]) == 1
    err = capsys.readouterr().err
    assert "[refused]" in err and "Traceback" not in err


@pytest.mark.parametrize("look,field", [
    ({"primary": "#112233\n"}, "primary"), ({"secondary": "#112233\n"}, "secondary")])
def test_a_colour_with_a_newline_is_not_a_colour(look, field):
    assert bm.look_problems(look, "x"), field


def test_a_provider_and_an_internal_name_with_a_newline_are_refused():
    assert bm.ways_problems({"public": {"provider": "abc\n"}}, "x")
    assert bm.ways_problems({"internal_name": "shop.acme.internal\n"}, "x",
                            internal_root="acme.internal")


def test_a_brand_id_with_a_newline_is_refused_by_the_id_rule():
    assert bm.brand_id_problem("shop\n")
    assert bm.brand_id_problem("shop\n", max_len=bm.DOCKER_LABEL_MAX)


def test_a_stored_row_id_with_a_newline_is_refused_by_the_record_checks():
    row = Domain(name="shop.example", id="shop-example\n")
    rec = bm.BrandRecord(superbrand=bm.Superbrand(id="acme"), brands=[row])
    assert bm.record_problems(rec) and bm.record_problems(rec, docker_start=True)


def test_the_theme_colour_pattern_refuses_a_newline():
    from hugmesh_studio.core import theme
    assert theme.HEX_RE.match("#112233") and not theme.HEX_RE.match("#112233\n")


def test_the_bootstraps_own_check_refuses_a_brand_with_a_newline():
    cfg = LocalMeshBootstrapConfig(brand="acme\n")
    problems = LocalMeshBootstrap(GENERATOR_DIR, cfg).validate()
    assert any("Brand" in p and "line break" in p for p in problems), problems


# ── 2. a test mesh has no public name ───────────────────────────────────────────────
def _docker_session(tmp_path, *, env="test", domain=""):
    boot = LocalMeshBootstrapConfig(env=env, cluster_domain=domain)
    state = LocalMeshDomains(domains=[Domain(name=domain or "hugmesh.net")],
                             own_name=domain or "hugmesh.net")
    owner = types.SimpleNamespace()
    return boot, state, session_for(owner, "docker", (boot, state), GENERATOR_DIR)


def test_a_design_saved_on_a_test_mesh_carries_no_public_name_and_no_central_signin(tmp_path):
    boot, state, s = _docker_session(tmp_path)
    s.set_identity("id", "acme")
    s.set_identity("title", "Acme Mesh")
    sync_brand_session(s, boot)
    assert s.commit(save=True) == []
    saved = bm.load_record()
    assert saved.superbrand.id == "acme"
    assert saved.superbrand.public_name == "", saved.superbrand.public_name
    assert saved.superbrand.central_signin == "", saved.superbrand.central_signin
    assert boot.superbrand.get("central_signin", "") == ""


def test_a_record_saved_on_a_test_mesh_does_not_start_a_production_plan_on_the_placeholder(
        tmp_path, capsys):
    boot, state, s = _docker_session(tmp_path)
    s.set_identity("id", "acme")
    s.set_identity("title", "Acme Mesh")
    sync_brand_session(s, boot)
    s.commit(save=True)
    rec = bm.record_path()
    # with no domain given the only way to a prod plan is still the missing domain
    rc = lmb.main(["plan", "--env", "prod", "--record", rec, "--generator-dir", GENERATOR_DIR])
    out = capsys.readouterr().out
    assert rc == 0
    assert "prod requires a public cluster domain" in out, out
    # and with one, the typed domain is the plan's domain
    rc = lmb.main(["plan", "--env", "prod", "--cluster-domain", "real.example",
                   "--record", rec, "--generator-dir", GENERATOR_DIR])
    out = capsys.readouterr().out
    assert "Domain:     real.example" in out and "https://id.real.example" in out, out
    assert "prod requires a public cluster domain" not in out, out


def test_a_record_domain_that_differs_from_an_explicit_cluster_domain_is_a_contradiction(
        tmp_path, capsys):
    path = _file(tmp_path, {"id": "acme", "public_name": "mesh.example"})
    rc = lmb.main(["plan", "--env", "prod", "--cluster-domain", "real.example",
                   "--record", path, "--generator-dir", GENERATOR_DIR])
    err = capsys.readouterr().err
    assert rc == 2 and "mesh.example" in err and "real.example" in err, err
    # the same domain on both sides is no contradiction
    rc = lmb.main(["plan", "--env", "prod", "--cluster-domain", "mesh.example",
                   "--record", path, "--generator-dir", GENERATOR_DIR])
    assert rc == 0
    capsys.readouterr()


def test_the_production_name_still_follows_the_page(tmp_path):
    boot, state, s = _docker_session(tmp_path, env="prod", domain="real.example")
    s.set_identity("id", "acme")
    sync_brand_session(s, boot)
    assert s.sb.public_name == "real.example"
    assert s.sb.central_signin == "https://id.real.example"


# ── 3. the Docker route checks a design the way the Docker start does ───────────────
def _with_row(boot, state, name, title):
    state.domains.append(Domain(name=name, title=title))


def test_a_brand_row_titled_with_an_apostrophe_does_not_block_the_superbrand_design(tmp_path):
    boot, state, s = _docker_session(tmp_path)
    _with_row(boot, state, "shop.example", "Bob's Shop")
    s.set_identity("id", "acme")
    s.set_identity("title", "Acme Mesh")
    sync_brand_session(s, boot)
    # the Docker start itself accepts this mesh ...
    assert not [p for p in LocalMeshBootstrap(GENERATOR_DIR, boot).validate()
                if "brand record" in p], LocalMeshBootstrap(GENERATOR_DIR, boot).validate()
    # ... and so does the design step
    assert s.problems() == [], s.problems()
    problems = s.commit(save=True)
    # the carrier took the design; only the record FILE refused, and it says so
    assert boot.brand == "acme" and boot.superbrand.get("title") == "Acme Mesh"
    assert problems and "brand record file" in s.message.lower(), s.message
    assert "still starts" in s.message, s.message
    # and editing the design afterwards is not refused over the other brand's title
    assert s.set_identity("title", "Acme Mesh 2") == ""
    s.commit()
    assert boot.superbrand.get("title") == "Acme Mesh 2"


def test_a_brand_row_with_a_sixty_one_character_id_does_not_block_the_design(tmp_path):
    boot, state, s = _docker_session(tmp_path)
    name = ("a" * 53) + ".example"          # its id is 61 characters
    _with_row(boot, state, name, "")
    s.set_identity("id", "acme")
    sync_brand_session(s, boot)
    assert s.problems() == [], s.problems()


def test_the_image_route_keeps_the_strict_rules_for_every_row(tmp_path):
    cfg = ImageConfig()
    cfg.domains = [Domain(name="shop.example", title="Bob's Shop")]
    s = session_for(types.SimpleNamespace(), "image", cfg, GENERATOR_DIR)
    s.set_identity("id", "acme")
    assert any("Bob's Shop" in p for p in s.problems()), s.problems()


def test_a_saved_record_file_still_refuses_what_the_start_accepts(tmp_path):
    rec = bm.BrandRecord(superbrand=bm.Superbrand(id="acme"),
                         brands=[Domain(name="shop.example", title="Bob's Shop")])
    assert bm.record_problems(rec, docker_start=True) == []
    with pytest.raises(bm.RecordRefused):
        bm.save_record(rec, str(tmp_path / "r.json"))


# ── 4. the image route: the pick and the record agree ───────────────────────────────
def test_picking_a_profile_after_a_design_drops_the_designs_title_and_organisation_on_the_image_route(
        tmp_path):
    """Twin of the Docker route's test. The configuration was left saying brand
    ‘example’ with the title ‘Acme Mesh’ and the organisation ‘Example’ of a design the
    person had abandoned, and CLI flags win over a profile."""
    cfg = ImageConfig()
    s = session_for(types.SimpleNamespace(), "image", cfg, GENERATOR_DIR)
    s.set_identity("id", "acme")
    s.set_identity("title", "Acme Mesh")
    s.set_identity("org", "Example")
    assert s.commit() == []
    assert (cfg.brand, cfg.brand_title, cfg.org) == ("acme", "Acme Mesh", "Example")
    s.choose("profile:example")
    assert s.commit(save=True) == []
    shipped = ImageConfig()
    assert cfg.brand == "example"
    assert (cfg.brand_title, cfg.org) == (shipped.brand_title, shipped.org), \
        (cfg.brand_title, cfg.org)
    assert cfg.brand_profile.endswith(os.path.join("brands", "example.conf"))
    assert "--brand-title" not in cfg._brand_args() and "--org" not in cfg._brand_args()
    assert cfg._brand_args()[:2] == ["--brand", "example"] or "example" in cfg._brand_args()
    saved = bm.load_record()
    assert (saved.superbrand.id, saved.superbrand.title, saved.superbrand.org) == (
        "example", "", "")


def test_picking_a_design_after_a_profile_lets_go_of_the_profile_file_on_the_image_route(
        tmp_path):
    cfg = ImageConfig()
    s = session_for(types.SimpleNamespace(), "image", cfg, GENERATOR_DIR)
    s.choose("profile:example")
    assert cfg.brand_profile.endswith("example.conf")
    s.choose(CREATE_KEY)
    s.set_identity("id", "acme")
    assert s.commit() == []
    assert cfg.brand == "acme" and cfg.brand_profile == ""


# ── 5. the document and the code agree about the copy sites ─────────────────────────
def test_the_copy_sites_paragraph_describes_the_table_as_it_is():
    assert not hasattr(bm, "COPY_SITES_STILL_DROPPING")
    with open(os.path.join(GENERATOR_DIR, "docs", "BRAND-MODEL.md"), encoding="utf-8") as fh:
        text = fh.read()
    assert "STILL_DROPPING" not in text and "not converted" not in text

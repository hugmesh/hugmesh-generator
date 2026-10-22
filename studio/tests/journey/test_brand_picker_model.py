"""The superbrand drop-down and its design, as the Qt-free model both faces drive
(hugmesh-generator#654, D8 and D20).

What is pinned here, and the change that turns each test red:

* ``Create a new superbrand`` is the FIRST item on every route and the item selected
  when nothing has been chosen (move it, or select another by default: red);
* the saved designs and the brands/ profiles follow, in that order, and an unaffiliated
  image is offered NOTHING and is told why (offer the item there: red);
* choosing a design COPIES it into the record with a note of where it came from, and a
  profile only names the superbrand (a design that renames the mesh: red);
* a refused identity changes nothing and says why; an untouched session writes nothing,
  not to the configuration and not to the record file;
* the record's look holds eight fields: whatever else the editor set is NAMED, never
  dropped without a word (silently filter it: red).
"""
import dataclasses
import json
import os

import pytest

from hugmesh_studio.core import brand_model
from hugmesh_studio.core.config import Domain, ImageConfig
from hugmesh_studio.core.fleet import FleetConfig, FleetDomains
from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig
from hugmesh_studio.tui.superbrand_step import (BootstrapHost, BrandSession,
                                                CREATE_KEY, CREATE_LABEL, FleetHost,
                                                ImageHost, UNAFFILIATED_REASON,
                                                session_for)

DATE = "2026-10-14"


@pytest.fixture
def gen(tmp_path):
    """A generator checkout with two brands/ profiles."""
    (tmp_path / "brands").mkdir()
    for name in ("local", "example"):
        (tmp_path / "brands" / f"{name}.conf").write_text(f"BRAND={name}\n")
    return str(tmp_path)


def _mesh_cfg(**kw) -> ImageConfig:
    cfg = ImageConfig()
    cfg.mode = "mesh"
    for k, v in kw.items():
        setattr(cfg, k, v)
    return cfg


def _session(gen, cfg=None, **kw) -> BrandSession:
    return BrandSession(ImageHost(cfg or _mesh_cfg(), gen), today=lambda: DATE, **kw)


def _keep_design(name="acme-look", title="Acme Mesh", primary="#336699"):
    sb = brand_model.Superbrand(id="ignored", title=title, org="example",
                                public_name="not.this.example",
                                look={"primary": primary})
    brand_model.save_design(name, sb)


# ── the drop-down ────────────────────────────────────────────────────────────────────
def test_create_is_first_and_selected_when_nothing_was_chosen(gen):
    s = _session(gen)
    labels = [c.label for c in s.choices()]
    assert labels[0] == CREATE_LABEL == "Create a new superbrand"
    assert s.choices()[0].key == CREATE_KEY
    assert s.choice == s.default_key() == CREATE_KEY
    assert s.designing, "the default choice opens the design"


def test_designs_then_profiles_follow_create_in_that_order(gen):
    _keep_design("aaa-design")
    _keep_design("zzz-design")
    s = _session(gen)
    kinds = [c.kind for c in s.choices()]
    assert kinds == ["create", "design", "design", "profile", "profile"]
    assert [c.key for c in s.choices()][1:3] == ["design:aaa-design", "design:zzz-design"]
    assert [c.key for c in s.choices()][3:] == ["profile:example", "profile:local"]


def test_a_configuration_with_its_own_superbrand_is_selected_as_that_not_as_create(gen):
    cfg = _mesh_cfg(brand="acme", brand_title="Acme Mesh", org="example")
    s = _session(gen, cfg)
    assert s.choices()[0].key == CREATE_KEY, "Create is still the FIRST item"
    assert s.choice == "current:acme" and not s.designing
    assert any(c.kind == "current" and "Acme Mesh" in c.label for c in s.choices())
    # a person who loaded a saved config is not asked to design over it
    assert "Acme Mesh" in "\n".join(s.summary_lines())


def test_an_unaffiliated_image_is_offered_nothing_and_told_why(gen):
    cfg = _mesh_cfg(unaffiliated=True)
    s = _session(gen, cfg)
    assert s.unaffiliated and s.choices() == []
    assert s.choose(CREATE_KEY) == UNAFFILIATED_REASON == s.message
    assert s.set_identity("title", "Nope") == UNAFFILIATED_REASON
    assert s.change() == UNAFFILIATED_REASON
    assert "no brand identity" in UNAFFILIATED_REASON
    assert "look is still yours" in UNAFFILIATED_REASON.replace("Its look", "look") or \
        "look is still yours" in UNAFFILIATED_REASON


def test_choosing_a_stored_design_copies_it_and_notes_where_it_came_from(gen):
    _keep_design("acme-look", title="Acme Mesh", primary="#336699")
    cfg = _mesh_cfg(cluster_domain="mesh.example")
    s = _session(gen, cfg)
    assert s.choose("design:acme-look") == ""
    assert not s.designing and s.choice == "design:acme-look"
    assert s.sb.title == "Acme Mesh" and s.sb.look == {"primary": "#336699"}
    # the design's file never renames the mesh: the public name stays the mesh's own
    assert s.sb.public_name == "mesh.example" != "not.this.example"
    assert s.copied_from == {"design": "acme-look", "date": DATE}
    s.touched = True
    assert s.record().copied_from == {"design": "acme-look", "date": DATE}
    assert ("Copied from", "design ‘acme-look’ on 2026-10-14") in s.summary_rows()
    assert any("design ‘acme-look’ on 2026-10-14" in ln for ln in s.summary_lines())
    # the existing choice shows a summary and Change it opens the design
    assert s.change() == "" and s.designing


def test_choosing_a_profile_names_the_superbrand_and_points_the_profile_field(gen):
    cfg = _mesh_cfg()
    s = _session(gen, cfg)
    s.choose("profile:example")
    assert s.sb.id == "example" and not s.designing
    assert cfg.brand_profile == os.path.join(gen, "brands", "example.conf")


def test_a_choice_that_is_not_offered_is_refused_with_its_name(gen):
    s = _session(gen)
    assert "not one of the choices" in s.choose("design:missing")
    assert s.choice == CREATE_KEY


# ── the design ───────────────────────────────────────────────────────────────────────
def test_a_new_design_starts_blank_and_a_blank_field_keeps_the_shipped_value(gen):
    cfg = _mesh_cfg()
    s = _session(gen, cfg)
    assert s.identity()["id"] == s.identity()["title"] == s.identity()["org"] == ""
    s.look.try_set("primary", "#336699")
    s.touched = True
    rec = s.record()
    assert rec.superbrand.id == "hugmesh" and rec.superbrand.title == "HugMesh Systems"
    assert rec.superbrand.look == {"primary": "#336699"}


@pytest.mark.parametrize(("field", "value", "word"), [
    ("id", "Bad ID", "DNS label"),
    ("id", "default", "reserved"),
    ("title", "no;semicolon", "title"),
    ("public_name", "not a domain", "domain"),
])
def test_a_refused_identity_changes_nothing_and_says_why(gen, field, value, word):
    s = _session(gen)
    before = s.identity()
    problem = s.set_identity(field, value)
    assert word.lower() in problem.lower(), problem
    assert s.identity() == before and s.message == problem and not s.touched


def test_an_accepted_identity_is_written_back_and_the_record_saved(gen, tmp_path):
    cfg = _mesh_cfg()
    s = _session(gen, cfg)
    for f, v in (("id", "acme"), ("title", "Acme Mesh"), ("org", "example"),
                 ("public_name", "mesh.example")):
        assert s.set_identity(f, v) == ""
    assert s.commit(save=True) == []
    assert (cfg.brand, cfg.brand_title, cfg.org, cfg.cluster_domain) == (
        "acme", "Acme Mesh", "example", "mesh.example")
    saved = json.loads(open(brand_model.record_path(), encoding="utf-8").read())
    assert saved["superbrand"]["id"] == "acme"
    assert saved["superbrand"]["public_name"] == "mesh.example"


def test_an_untouched_session_writes_nothing_anywhere(gen):
    cfg = _mesh_cfg()
    before = dataclasses.asdict(cfg)
    s = _session(gen, cfg)
    assert s.commit(save=True) == []
    assert dataclasses.asdict(cfg) == before
    assert not os.path.exists(brand_model.record_path())


def test_keeping_a_design_puts_it_in_the_drop_down_next_time(gen):
    s = _session(gen)
    s.set_identity("title", "Kept Mesh")
    assert s.keep_design("kept-look") == ""
    assert "design:kept-look" in [c.key for c in _session(gen).choices()]
    assert "short lowercase slug" in s.keep_design("Not A Slug")


# ── what the record cannot hold yet ──────────────────────────────────────────────────
def test_look_choices_the_record_cannot_hold_are_named_not_dropped(gen, tmp_path):
    from test_look_model import png_bytes
    s = _session(gen)
    logo = tmp_path / "logo.png"
    logo.write_bytes(png_bytes(48, 48, opaque=True))
    assert s.look.load_picture("logo_image", str(logo)).ok
    s.look.try_set("primary", "#336699")
    s.touched = True
    assert s.not_in_record() == ["logo_image"]
    sentence = s.not_in_record_sentence()
    assert "logo" in sentence and "Not saved in the brand record yet" in sentence
    # the saved look holds what the record can hold and nothing else
    assert s.record().superbrand.look == {"primary": "#336699"}
    assert s.commit(save=True) == []


def test_the_sentence_goes_away_by_itself_when_the_record_can_hold_the_field(
        gen, tmp_path, monkeypatch):
    from test_look_model import png_bytes
    s = _session(gen)
    logo = tmp_path / "logo.png"
    logo.write_bytes(png_bytes(48, 48, opaque=True))
    s.look.load_picture("logo_image", str(logo))
    assert s.not_in_record_sentence()
    monkeypatch.setattr(brand_model, "LOOK_KEYS",
                        brand_model.LOOK_KEYS + ("logo_image",))
    assert s.not_in_record_sentence() == ""
    assert "logo_image" in s.record_look()


# ── the three hosts keep one record shape ────────────────────────────────────────────
def test_the_three_routes_write_the_same_record_bytes_for_the_same_choices(gen, tmp_path):
    """J-SUPERBRAND at the model: image, Docker and Fleet, one script, one record."""
    def script(s: BrandSession):
        s.set_identity("id", "acme")
        s.set_identity("title", "Acme Mesh")
        s.set_identity("org", "example")
        s.set_identity("public_name", "mesh.example")
        s.look.try_set("primary", "#336699")
        s.look.try_set("font", "System UI")
        s.touched = True
        out = tmp_path / f"{s.host.route}.json"
        assert s.commit(save=False) == []
        brand_model.save_record(s.record(), str(out))
        return out.read_bytes()

    image = BrandSession(ImageHost(_mesh_cfg(), gen), today=lambda: DATE)
    docker = BrandSession(BootstrapHost(LocalMeshBootstrapConfig(), gen),
                          today=lambda: DATE)
    fleet = BrandSession(FleetHost(FleetConfig(), FleetDomains(), gen),
                         today=lambda: DATE)
    bytes_by_route = {s.host.route: script(s) for s in (image, docker, fleet)}
    # the image route and the fleet window know nothing the person did not type: their
    # bytes are EQUAL (J-FLEET)
    assert bytes_by_route["image"] == bytes_by_route["fleet"], {
        r: b.decode() for r, b in bytes_by_route.items()}
    # the Docker route adds the two facts only its start path has: the central sign-in it
    # derives (http://localhost:8000 on a test mesh) and whether it starts Tor. Everything
    # the person chose is equal.
    docker_rec = json.loads(bytes_by_route["docker"])
    assert docker_rec["superbrand"].pop("central_signin") == "http://localhost:8000"
    assert docker_rec["superbrand"].pop("ways") == {"tor": False}
    assert docker_rec == json.loads(bytes_by_route["image"])
    rec = json.loads(bytes_by_route["image"])
    assert rec["superbrand"]["title"] == "Acme Mesh"
    assert rec["superbrand"]["look"] == {"font": "System UI", "primary": "#336699"}


def test_the_session_follows_the_configuration_object_not_its_values(gen):
    owner = type("Owner", (), {})()
    a, b = _mesh_cfg(), _mesh_cfg()
    assert a == b and a is not b
    s1 = session_for(owner, "image", a, gen)
    assert session_for(owner, "image", a, gen) is s1
    assert session_for(owner, "image", b, gen) is not s1, \
        "Load config replaces the configuration: a session belongs to the one it was made for"
    opts, state = FleetConfig(), FleetDomains()
    f1 = session_for(owner, "fleet", (opts, state), gen)
    assert session_for(owner, "fleet", (opts, state), gen) is f1
    assert session_for(owner, "fleet", (opts, FleetDomains()), gen) is not f1


def test_a_brand_row_edit_reaches_the_live_row_and_nothing_else(gen):
    cfg = _mesh_cfg()
    cfg.domains = [Domain(name="shop.example", title="Shop", optional_services=["akkoma"]),
                   Domain(name="blog.example")]
    s = _session(gen, cfg)
    s.host.update_row("shop.example", look={"primary": "#aa0000"})
    assert cfg.domains[0].look == {"primary": "#aa0000"}
    assert cfg.domains[0].optional_services == ["akkoma"], "the services step's data stays"
    assert cfg.domains[1].look == {}
    assert [d.name for d in s.host.rows()] == ["shop.example", "blog.example"]
    # rows() are COPIES: the record can be held while the config keeps changing
    s.host.rows()[0].title = "Changed"
    assert cfg.domains[0].title == "Shop"


def test_the_summary_says_where_each_setting_lives():
    from hugmesh_studio.tui import brand_step
    assert "Domains step" in brand_step.IDENTITY_HOME
    # the mesh's own look is chosen on its own domain's Look tab (2026-10-21)
    assert "one place it is chosen" in brand_step.LOOK_HOME
    assert "Look" in brand_step.LOOK_POINTER and "own domain" in brand_step.LOOK_POINTER
    assert "Go-Live wizard" in brand_step.WAYS_HOME
    assert brand_step.WAYS_BUTTON == "Set up ways to reach this brand"
    assert [t for _n, t in brand_step.SECTIONS] == [
        "Identity", "Look", "Services", "Ways to reach it"]


# ── a design edit is checked against every brand's finished stylesheet ───────────────
def test_a_superbrand_edit_that_would_push_a_brand_over_budget_is_refused_by_name(
        gen, monkeypatch):
    """The session wires its look to the brands' rows, and re-wires every fresh look it
    makes (Create and a copied design replace the look model), so the check survives a
    pick. (Mutation: build the fresh look without the wiring.) Qt-free."""
    from hugmesh_studio.core import brand_look as bl
    from test_look_model import png_bytes
    from hugmesh_studio.core import brand_images
    bg = brand_images.reencode(png_bytes(40, 40, noise=True), "background").data_uri()
    logo = brand_images.reencode(png_bytes(16, 16, noise=True), "logo").data_uri()
    shop = Domain(name="shop.mesh.example", look={"login_bg_image": bg})
    cfg = _mesh_cfg()
    cfg.domains = [shop]
    s = _session(gen, cfg)
    s.choose(CREATE_KEY)                       # replaces the look model
    both = len(bl.look_css({"login_bg_image": bg, "logo_image": logo}).encode())
    monkeypatch.setattr(bl, "LOOK_CSS_BUDGET", both - 1)
    out = s.look.try_set("logo_image", logo)
    assert not out.ok and "brand shop-mesh-example" in out.text, out.text
    shop.look = {}                             # the rows are read at each edit
    assert s.look.try_set("logo_image", logo).ok

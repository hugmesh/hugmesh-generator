"""The text screens for the superbrand step and the Brand settings sections
(hugmesh-generator#654, D8, D9, D20; operator decision 71 = A).

These walk the SAME controls the window offers, by typing lines at the screens, and read
back what they wrote. A screen that offered less than the window (a missing section, a
control with no command) is red here and in tests/test_tui_gui_parity.py.
"""
import json
import os

import pytest

from hugmesh_studio.core import brand_model
from hugmesh_studio.core.config import DOMAIN_IDP_OWN, Domain
from hugmesh_studio.tui import brand_step
from hugmesh_studio.tui.domain_services_step import DomainServicesScreen
from hugmesh_studio.tui.domains_step import DomainsScreen
from hugmesh_studio.tui.fleet import FleetScreen
from hugmesh_studio.tui.journey import Journey
from hugmesh_studio.tui.superbrand_step import (CREATE_LABEL, UNAFFILIATED_REASON,
                                                session_for)

DATE = "2026-10-14"


@pytest.fixture
def gen(tmp_path):
    (tmp_path / "brands").mkdir()
    (tmp_path / "brands" / "example.conf").write_text("BRAND=example\n")
    return str(tmp_path)


def _journey(gen, **cfg) -> Journey:
    j = Journey(gen)
    j.cfg.mode = "mesh"
    for k, v in cfg.items():
        setattr(j.cfg, k, v)
    return j


def _feed(j, *lines):
    for ln in lines:
        j.feed(ln)
    return "\n".join(j.lines())


# ── the superbrand step (the Branding screen's s) ────────────────────────────────────
def test_the_branding_screen_offers_the_superbrand_step_on_a_mesh_only(gen):
    j = _journey(gen)
    j.goto("branding")
    assert "s. Superbrand" in "\n".join(j.lines())
    j.cfg.mode = "standalone"
    assert "s. Superbrand" not in "\n".join(j.lines())
    j.feed("s")                              # not offered: the key just continues
    assert j.slug != "branding" or j.overlay is None


def test_the_drop_down_lists_create_first_selected_and_numbers_every_item(gen):
    j = _journey(gen)
    j.goto("branding")
    text = _feed(j, "s")
    lines = [ln for ln in text.splitlines() if ln.strip().startswith(("*1.", "1.", "2."))]
    assert lines[0].strip() == f"*1. {CREATE_LABEL}"
    assert "2. example (a brands/ profile)" in text
    assert "Design your superbrand" in text and "1. Identity" in text
    assert "2. Look" in text


def test_a_walk_designs_the_superbrand_and_continuing_writes_cfg_and_record(gen):
    j = _journey(gen)
    j.goto("branding")
    _feed(j, "s", "id acme", "title Acme Mesh", "org example", "public mesh.example",
          "look", "1 #336699", "font", "back")
    assert j.status == "" or "unrecognised" not in j.status
    _feed(j, "")                             # Enter: continue, commit
    assert (j.cfg.brand, j.cfg.brand_title, j.cfg.cluster_domain) == (
        "acme", "Acme Mesh", "mesh.example")
    assert j.cfg.login_primary_color == "#336699"
    assert j.slug == "branding" and j.overlay is None
    # the record file is written when the brand settings step is left
    assert not os.path.exists(brand_model.record_path())


def test_a_refused_field_is_a_sentence_on_the_screen_and_changes_nothing(gen):
    j = _journey(gen)
    j.goto("branding")
    _feed(j, "s")
    text = _feed(j, "id Not A Slug")
    assert "DNS label" in j.status or "DNS label" in text
    assert j.cfg.brand == "hugmesh"
    text = _feed(j, "7")
    assert "no such choice" in j.status


def test_an_unaffiliated_image_is_told_why_there_is_nothing_to_choose(gen):
    j = _journey(gen, unaffiliated=True)
    j.goto("branding")
    # not offered at all on the Branding screen's menu for a non-mesh; on a mesh it is
    text = _feed(j, "s")
    assert UNAFFILIATED_REASON in text
    assert "Create a new superbrand" not in text
    j.feed("id acme")
    assert j.status == UNAFFILIATED_REASON or UNAFFILIATED_REASON in "\n".join(j.lines())
    assert j.cfg.brand == "hugmesh"


def test_choosing_a_profile_shows_a_read_only_summary_with_a_change_it(gen):
    j = _journey(gen)
    j.goto("branding")
    text = _feed(j, "s", "2")
    assert "example" in text and "change" in text
    assert "Design your superbrand" not in text
    text = _feed(j, "change")
    assert "Design your superbrand" in text


# ── the Brand settings sections ──────────────────────────────────────────────────────
def _services_screen(gen, route="docker", rows=None):
    j = Journey(gen)
    j.cfg.mode = "mesh"
    j.cfg.domains = rows if rows is not None else [
        Domain(name="shop.example", title="Shop"),
        Domain(name="blog.example", title="Blog", idp=DOMAIN_IDP_OWN)]
    screen = DomainServicesScreen(
        brand_session_of=lambda j: session_for(j, "image", j.cfg, gen), route=route)
    screen.enter(j)
    return j, screen


def _text(screen, j):
    return "\n".join(screen.lines(j))


def test_the_sections_are_numbered_and_the_services_one_is_open(gen):
    j, sc = _services_screen(gen)
    text = _text(sc, j)
    assert "1. Identity" in text and "2. Look" in text
    assert "*3. Services" in text and "4. Ways to reach it" in text
    assert "Tor front door" in text, "the services screen is the one that opens"


def test_every_existing_services_command_still_works_with_the_sections_on_screen(gen):
    j, sc = _services_screen(gen)
    sc.feed(j, "n")                          # shop.example (the own domain is first)
    assert sc.current(j).name == "shop.example"
    sc.feed(j, "1")                          # NUMBER toggles a service, as before
    assert sc.current(j).optional_services
    sc.feed(j, "t")
    assert sc.current(j).tor is True


def test_identity_is_a_read_only_mirror_that_says_where_it_is_changed(gen):
    j, sc = _services_screen(gen)
    sc.feed(j, "n")
    sc.feed(j, "open 1")
    text = _text(sc, j)
    assert "Public name   shop.example" in text and "Title         Shop" in text
    assert "Id            shop-example" in text
    assert brand_step.IDENTITY_HOME in text
    sc.feed(j, "title Other")
    assert "Nothing to change" in j.status
    assert sc.current(j).title == "Shop"
    sc.feed(j, "n")
    sc.feed(j, "open 1")
    assert "has its own sign-in" in _text(sc, j)


def test_the_superbrands_own_row_is_labelled_and_points_at_its_step(gen):
    j, sc = _services_screen(gen)
    sc.feed(j, "open 1")
    text = _text(sc, j)
    assert "(the superbrand)" in text and brand_step.SUPERBRAND_HOME in text


def test_the_ways_section_is_read_only_and_names_the_wizard(gen):
    j, sc = _services_screen(gen)
    sc.feed(j, "n")
    sc.feed(j, "open 4")
    text = _text(sc, j)
    assert "internal name: shop-example." in text
    assert "Docker mesh:" in text and "kind cluster:" in text and "node image:" in text
    assert brand_step.WAYS_HOME in text
    sc.feed(j, "tor on")
    assert "Nothing to change" in j.status
    assert sc.current(j).tor is False


def test_the_look_section_edits_a_brand_on_the_docker_mesh_and_gives_it_back(gen):
    j, sc = _services_screen(gen, route="docker")
    sess = session_for(j, "image", j.cfg, gen)
    sess.look.try_set("primary", "#336699")
    sc.feed(j, "n")
    sc.feed(j, "open 2")
    assert "inherited from the superbrand" in _text(sc, j)
    sc.feed(j, "1 #aa0000")
    assert j.cfg.domains[0].look == {"primary": "#aa0000"}
    text = _text(sc, j)
    assert "this brand's own" in text
    sc.feed(j, "use 1")                      # first click: armed, nothing changes
    assert j.cfg.domains[0].look == {"primary": "#aa0000"}
    assert "armed" in _text(sc, j)
    sc.feed(j, "use 1")                      # second click applies
    assert j.cfg.domains[0].look == {}
    assert "inherited from the superbrand" in _text(sc, j)


def test_off_the_docker_mesh_the_look_is_shown_with_the_reason_and_not_editable(gen):
    j, sc = _services_screen(gen, route="image")
    sc.feed(j, "n")
    sc.feed(j, "open 2")
    text = _text(sc, j)
    assert "shown on the Docker mesh only" in text
    sc.feed(j, "1 #aa0000")
    assert "Docker mesh only" in j.status
    assert j.cfg.domains[0].look == {}


def test_leaving_the_step_writes_the_brand_record_once_something_changed(gen):
    j, sc = _services_screen(gen, route="docker")
    sess = session_for(j, "image", j.cfg, gen)
    sc.feed(j, "")                           # nothing changed: nothing written
    assert not os.path.exists(brand_model.record_path())
    sess.set_identity("title", "Acme Mesh")
    sc.feed(j, "n")
    sc.feed(j, "open 2")
    sc.feed(j, "1 #aa0000")
    sc.feed(j, "")
    saved = json.loads(open(brand_model.record_path(), encoding="utf-8").read())
    assert saved["superbrand"]["title"] == "Acme Mesh"
    row = next(b for b in saved["brands"] if b["name"] == "shop.example")
    assert row["look"] == {"primary": "#aa0000"}


def test_a_host_with_no_session_shows_the_screen_exactly_as_before(gen):
    j = Journey(gen)
    j.cfg.mode = "mesh"
    j.cfg.domains = [Domain(name="shop.example")]
    plain = DomainServicesScreen()
    plain.enter(j)
    text = "\n".join(plain.lines(j))
    assert "Brand settings" not in text and "Ways to reach it" not in text
    plain.feed(j, "open 2")
    assert "unrecognised" in j.status


# ── the brands table's summary ───────────────────────────────────────────────────────
def test_the_domains_step_prints_a_read_only_brand_summary_on_a_mesh(gen):
    j = _journey(gen)
    j.cfg.domains = [Domain(name="shop.example", title="Shop", tor=True,
                            look={"primary": "#aa0000"}),
                     Domain(name="blog.example", idp=DOMAIN_IDP_OWN)]
    j.goto("domains")
    text = "\n".join(DomainsScreen().lines(j))
    assert "brand summary" in text
    assert "signs in through the superbrand; 1 look setting of its own; reached by Tor" in text
    assert "has its own sign-in; inherits the look" in text
    assert "the superbrand — " + brand_step.SUPERBRAND_HOME in text
    j.cfg.mode = "cloud"
    assert "brand summary" not in "\n".join(DomainsScreen().lines(j))


# ── the Fleet's text twin ────────────────────────────────────────────────────────────
def test_the_fleet_text_twin_offers_the_same_drop_down_and_design(gen):
    j = Journey(gen)
    fs = FleetScreen()
    fs.enter(j)
    fs.feed(j, "brand")                       # the options' command to the superbrand step
    assert fs.stage == "brand"
    text = "\n".join(fs.lines(j))
    assert f"*1. {CREATE_LABEL}" in text and "Design your superbrand" in text
    fs.feed(j, "title Acme Mesh")
    fs.feed(j, "public mesh.example")
    fs.feed(j, "b")                           # back to the options, nothing committed
    assert fs.stage == "options" and fs.options(j).cluster_domain == ""
    fs.feed(j, "brand")
    fs.feed(j, "")                            # commit and return to the options
    assert fs.stage == "options"
    assert fs.options(j).cluster_domain == "mesh.example"
    fs.feed(j, "")                            # Enter on the options still goes to Domains
    assert fs.stage == "domains"
    assert fs.state(j).own_name == "mesh.example"

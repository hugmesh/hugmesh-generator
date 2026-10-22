"""The text face's twin of the Ways tab's ‘Set up ways to reach this brand’ button:
``go-live`` typed in a domain's Ways section opens the Go-Live screen over Brand
settings with that domain picked, and ``b`` on its first step comes back (2026-10-21).

Headless and Qt-free. The image route (the journey's Brand settings step) and the Fleet
screen's Brand settings are both driven; the Docker mesh screen embeds the same
``DomainServicesScreen``, so the same handler serves it.
"""
import os

import pytest

from hugmesh_studio.tui import brand_step, journey
from hugmesh_studio.tui.fleet import FleetScreen
from hugmesh_studio.tui.golive import GoLiveScreen

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def _image_ways(name: str) -> journey.Journey:
    """The image route's Brand settings step, on ``name``'s Ways section."""
    j = journey.Journey(GENERATOR_DIR)
    for line in ("", "3", "", "1", "", "", "", ""):
        j.feed(line)
    assert j.slug == "domains_choice"
    j.feed("y")
    j.feed(f"a {name}")
    j.feed("")
    assert j.slug == "domain_services"
    j.feed("n")                                   # past the own domain
    assert j.screen().current(j).name == name
    j.feed("ways")
    return j


def _go_live_and_back(j, name: str, under) -> None:
    text = "\n".join(j.lines())
    assert brand_step.WAYS_HOME in text and brand_step.WAYS_TUI_LINE in text
    j.feed(brand_step.WAYS_GO_LIVE_COMMAND)
    gl = j.screen()
    assert isinstance(gl, GoLiveScreen), "go-live opened nothing"
    assert gl.stage == "provider"
    assert gl.opts.domain == name
    shown = "\n".join(j.lines())
    assert f"domain: {name} (picked from its Brand settings)" in shown
    assert "b=back to Brand settings" in shown
    j.feed("b")
    assert j.overlay is None
    assert j.screen() is under
    assert not j.done


def test_the_image_routes_ways_section_opens_go_live_with_its_domain():
    j = _image_ways("shop.example")
    under = j.screen()
    _go_live_and_back(j, "shop.example", under)
    assert j.slug == "domain_services" and under.section == 4


def test_the_picked_domain_carries_to_the_go_live_domain_step():
    j = _image_ways("shop.example")
    j.feed(brand_step.WAYS_GO_LIVE_COMMAND)
    gl = j.screen()
    if not gl._driver(j).providers():
        pytest.skip("the driver's registry lists no providers on this checkout")
    j.feed("1")                                   # the first provider
    assert gl.stage == "domain"
    assert "shop.example" in gl.opts.domain
    j.feed("")                                    # Enter keeps the picked domain
    assert gl.opts.domain == "shop.example"


def test_the_fleet_screens_ways_section_opens_go_live_with_its_domain():
    j = journey.Journey(GENERATOR_DIR)
    j.goto("fleet")
    fs = j.screen()
    assert isinstance(fs, FleetScreen)
    j.feed("brand")
    for cmd, v in (("id", "acme"), ("title", "Acme Mesh"), ("org", "example"),
                   ("public", "mesh.example")):
        j.feed(f"{cmd} {v}")
    j.feed("")                                    # back on the options
    j.feed("")                                    # -> Domains
    j.feed("a acme.example")
    j.feed("")                                    # -> Brand settings
    assert fs.stage == "services"
    j.feed("n")
    j.feed("ways")
    _go_live_and_back(j, "acme.example", fs)
    assert fs.stage == "services"


def test_outside_the_ways_section_go_live_is_not_a_command():
    j = _image_ways("shop.example")
    j.feed("services")
    j.feed(brand_step.WAYS_GO_LIVE_COMMAND)
    assert j.overlay is None

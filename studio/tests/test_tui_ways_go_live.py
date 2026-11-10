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


# ── the TARGET stage: go live from an emulated device (core.golive_target) ───────────
# The device is a fake `ssh` first on PATH (tests/_golive_fake_guest): against an
# emulated target this host runs nothing but ssh, so every argv it ran is on record.
import shlex                                                   # noqa: E402

import _golive_fake_guest as fake                              # noqa: E402
from hugmesh_studio.core import golive_target                  # noqa: E402

SECRET = "tui-tok-NEVER-ON-ARGV-987"


@pytest.fixture
def guest(tmp_path, monkeypatch):
    g = fake.install(tmp_path, monkeypatch)
    monkeypatch.setattr(golive_target, "local_node_refusal",
                        lambda *a, **k: "this host is not a HugMesh node — pick a device")
    fake.register(g, label="rpi5/pki")
    fake.register(g, label="x86/laptop", platform="x86", role="laptop", port=22402)
    return g


def _go_live_screen(guest) -> tuple[journey.Journey, GoLiveScreen]:
    j = journey.Journey(GENERATOR_DIR)
    j.goto("golive")
    gl = j.screen()
    gl.work_dir = guest.work_dir
    return j, gl


def _pick_target(j, gl, label):
    j.feed("t")
    assert gl.stage == "target"
    j.lines()                                        # the list a person is looking at
    rows = [t.label for t in gl._rows]
    j.feed(str(rows.index(label) + 1))


def test_t_lists_this_host_and_the_devices_with_their_refusals(guest):
    j, gl = _go_live_screen(guest)
    assert "target: This host (plan/status preview; commit refused: this host is not " \
        "a HugMesh node" in "\n".join(j.lines())
    j.feed("t")
    text = "\n".join(j.lines())
    assert "1. This host  <- picked" in text
    assert "rpi5/pki (emulated · rpi5 · pki)" in text
    assert "x86/laptop (emulated · x86 · laptop)" in text
    assert "! refused: x86/laptop is a laptop client" in text
    # a refused device is not taken; the screen says why and stays
    rows = [t.label for t in gl._rows]
    j.feed(str(rows.index("x86/laptop") + 1))
    assert gl.target.is_local and gl.stage == "target"
    assert "client" in j.status
    # refused on its record alone: nothing was ever sent to that device
    assert not any("22402" in c for c in guest.calls()), guest.calls()


def test_picking_a_device_targets_its_own_driver_over_ssh(guest):
    j, gl = _go_live_screen(guest)
    _pick_target(j, gl, "rpi5/pki")
    assert gl.stage == "provider" and gl.target.label == "rpi5/pki"
    text = "\n".join(j.lines())
    assert "target: rpi5/pki (emulated · rpi5 · pki) — its own hugmesh-go-live, over " \
        "ssh 127.0.0.1:22401" in text
    assert "from rpi5/pki: REHEARSAL" in text               # byo-domain and friends
    assert "from rpi5/pki: not on headscale" in text        # funnel
    # the provider list is the DEVICE's `list`, read over ssh — not this checkout's bash
    lists = [c for c in guest.calls() if c[-1] == "sudo -n hugmesh-go-live list"]
    assert lists and "BatchMode=yes" in lists[0]


def test_a_device_with_no_driver_is_refused_and_this_host_stays(guest, monkeypatch):
    monkeypatch.setenv("FAKE_GUEST_DRIVER", "")
    j, gl = _go_live_screen(guest)
    _pick_target(j, gl, "rpi5/pki")
    assert gl.target.is_local and gl.stage == "target"
    assert "no go-live driver" in j.status


def _to_plan(j, gl, provider_id):
    ids = [p.id for p in gl._driver(j).providers()]
    j.feed(str(ids.index(provider_id) + 1))
    assert gl.stage == "domain"
    j.feed("")                                       # the device's cluster domain
    assert gl.stage == "plan"


def test_the_plan_runs_on_the_device_and_the_flip_is_handed_over(guest):
    j, gl = _go_live_screen(guest)
    _pick_target(j, gl, "rpi5/pki")
    _to_plan(j, gl, "byo-domain")
    assert gl.opts.domain == "mesh.example"           # read over ssh, not this host
    text = "\n".join(j.lines())
    assert f"EPHEMERAL on rpi5/pki: {golive_target.EPHEMERAL_NOTE}." in text
    commit = gl.commit_command(j)
    argv = shlex.split(commit)
    assert argv[0] == "ssh" and "-t" in argv
    assert argv[-1] == "sudo hugmesh-go-live commit --provider byo-domain --domain " \
        "mesh.example"
    assert "-y" not in argv and "--yes" not in commit
    assert "  " + commit in text
    assert "  " + gl.rollback_command(j) in text
    j.feed("p")
    text = "\n".join(j.lines())
    assert "==> Plan summary ready" in text and "=== plan exited 0 ===" in text
    assert "artifacts copied back to" in text
    assert "  records.txt" in text and "  zone.db" in text
    assert "exited 0" in j.status
    j.feed("s")
    assert "posture: INTERNAL" in "\n".join(j.lines())
    j.feed("l")
    assert "byo-domain files" in "\n".join(j.lines())


def test_a_token_file_reaches_the_device_over_stdin_only(guest, tmp_path):
    tok = tmp_path / "token"
    tok.write_text(SECRET + "\n")
    j, gl = _go_live_screen(guest)
    _pick_target(j, gl, "rpi5/pki")
    _to_plan(j, gl, "cloudflare-tunnel")
    assert "PROD ExternalSecret" in "\n".join(j.lines())
    j.feed(f"tf {tok}")
    assert gl.opts.token_file == str(tok)
    j.feed("p")
    assert guest.token_seen().strip() == SECRET
    assert guest.removed() == ["/run/hugmesh-golive-tok.AbC123"]
    for argv in guest.calls():
        assert not any(SECRET in a for a in argv), argv
    assert SECRET not in "\n".join(j.lines())

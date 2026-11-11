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


# ── round 2 of #931: the picked device is RE-BOUND on `r` and on a pick ──────────────

def _restart(guest, label="rpi5/pki", port=22999, started_at="2026-11-10T09:00:00Z",
             **kw):
    return fake.register(guest, label=label, port=port, started_at=started_at, **kw)


def _commit_port(gl, j):
    argv = shlex.split(gl.commit_command(j))
    return argv[argv.index("-p") + 1]


def test_r_rebinds_the_picked_device_after_a_restart(guest):
    j, gl = _go_live_screen(guest)
    _pick_target(j, gl, "rpi5/pki")
    _to_plan(j, gl, "byo-domain")
    assert _commit_port(gl, j) == "22401"
    _restart(guest)                                  # new port, new boot
    # the plan stage refuses to hand over a command for the boot it no longer is
    text = "\n".join(j.lines())
    assert "restarted" in text and "22999" in text
    assert "sudo hugmesh-go-live commit" not in text
    j.feed("p")
    assert "restarted" in j.status
    assert not any("plan" in c[-1] for c in guest.calls() if c[-1].startswith("sudo "))
    # t, then r: the device is re-bound to its fresh record
    j.feed("")                                       # back to the providers
    j.feed("t")
    j.feed("r")
    assert gl.target.ssh_port == 22999 and gl._driver(j).target.ssh_port == 22999
    assert gl.target.started_at == "2026-11-10T09:00:00Z"
    assert gl.opts.provider == "byo-domain"          # the same device: provider kept
    assert _commit_port(gl, j) == "22999"


def test_r_after_a_stop_and_port_reuse_refuses_the_stale_pick(guest):
    j, gl = _go_live_screen(guest)
    _pick_target(j, gl, "rpi5/pki")
    _restart(guest, port=22401, started_at="2026-11-09T20:00:00Z", state="stopped")
    _restart(guest, label="rpi5/be", role="backend", port=22401)
    j.feed("t")
    j.feed("r")
    assert gl.target.label == "rpi5/pki" and not gl.target.running
    assert "rpi5/pki is not running" in j.status
    _to_plan_anyway = gl._driver(j).blocker()
    assert "not running" in _to_plan_anyway
    assert gl.commit_command(j).startswith("!! ")    # no ssh line to hand over


def _keep_a_stopped_pick(guest):
    """Plan stage on rpi5/pki, then it stops and rpi5/be takes its port; `t`, `r`
    keeps the stopped device (refused). Returns (j, gl) back on the providers."""
    j, gl = _go_live_screen(guest)
    _pick_target(j, gl, "rpi5/pki")
    _to_plan(j, gl, "byo-domain")
    _restart(guest, port=22401, started_at="2026-11-09T20:00:00Z", state="stopped")
    _restart(guest, label="rpi5/be", role="backend", port=22401)
    j.feed("")                                       # back to the providers
    j.feed("t")
    j.feed("r")
    assert gl.target.label == "rpi5/pki" and not gl.target.running
    j.feed("")                                       # back to the providers
    assert gl.stage == "provider"
    return j, gl


def test_a_kept_stopped_device_lists_no_providers_and_refuses_a_pick(guest):
    """The provider step says WHY, and never lists this checkout's registry as if the
    stopped device offered it (the driver falls back to that registry when it cannot
    run). A NUMBER is refused, as the GUI's Preflight shuts Next on the same record."""
    j, gl = _keep_a_stopped_pick(guest)
    sent = len(guest.calls())
    text = "\n".join(gl.lines(j))
    assert "rpi5/pki is not running" in text
    assert "  1. " not in text and "cloudflare-tunnel" not in text
    assert "commands: t=pick the target" in text
    j.feed("2")
    assert gl.stage == "provider"
    assert "rpi5/pki is not running" in j.status
    assert guest.calls()[sent:] == []


def test_plan_verbs_refuse_a_device_the_driver_cannot_reach(guest):
    """The backstop under the provider step. That step no longer lets a refused device
    through, so the test puts one on the plan stage itself: p, s and l each say why and
    send nothing. `l` used to list this checkout's registry as the device's."""
    j, gl = _keep_a_stopped_pick(guest)
    gl.stage = "plan"                                # unreachable through the providers now
    sent = len(guest.calls())
    for verb in ("l", "s", "p"):
        gl.run_log = []
        j.feed(verb)
        assert "rpi5/pki is not running" in j.status, verb
        assert gl.run_log == [], (verb, gl.run_log)
    assert guest.calls()[sent:] == []


def test_picking_a_row_takes_the_record_as_it_is_now(guest):
    j, gl = _go_live_screen(guest)
    j.feed("t")
    j.lines()                                        # the rows a person reads...
    rows = [t.label for t in gl._rows]
    _restart(guest)                                  # ...then the device restarts
    j.feed(str(rows.index("rpi5/pki") + 1))
    assert gl.target.ssh_port == 22999 and gl._driver(j).target.ssh_port == 22999


# ── Tailscale Funnel on an emulated mesh: refused on the TUI too ─────────────────────

def test_funnel_is_refused_on_the_provider_step_for_a_device(guest):
    j, gl = _go_live_screen(guest)
    _pick_target(j, gl, "rpi5/pki")
    text = "\n".join(j.lines())
    assert "! refused: tailscale-funnel is refused on rpi5/pki" in text
    ids = [p.id for p in gl._driver(j).providers()]
    j.feed(str(ids.index("tailscale-funnel") + 1))
    assert gl.stage == "provider" and gl.opts.provider != "tailscale-funnel"
    assert "headscale" in j.status


def test_funnel_is_offered_on_this_host(guest):
    j, gl = _go_live_screen(guest)
    assert "! refused: tailscale-funnel" not in "\n".join(j.lines())
    ids = [p.id for p in gl._driver(j).providers()]
    j.feed(str(ids.index("tailscale-funnel") + 1))
    assert gl.stage == "domain" and gl.opts.provider == "tailscale-funnel"


# ── plan inputs on the TUI: --ingress-ip, --tunnel-cname, --ddns-subdomain ───────────

def test_ingress_ip_and_tunnel_cname_reach_the_plan_on_the_device(guest):
    j, gl = _go_live_screen(guest)
    _pick_target(j, gl, "rpi5/pki")
    _to_plan(j, gl, "byo-domain")
    text = "\n".join(j.lines())
    assert "ip ADDR|-" in text and "cname HOST|-" in text
    assert "sub LABEL|-" not in text                 # byo-domain takes no subdomain
    j.feed("ip 203.0.113.10")
    j.feed("cname edge.example.invalid")
    assert gl.opts.ingress_ip == "203.0.113.10"
    assert gl.opts.tunnel_cname == "edge.example.invalid"
    assert "--ingress-ip 203.0.113.10" in "\n".join(j.lines())
    j.feed("p")
    plans = [c[-1] for c in guest.calls() if " plan " in c[-1]]
    assert plans, guest.calls()
    words = shlex.split(plans[-1])
    assert words[words.index("--ingress-ip") + 1] == "203.0.113.10"
    assert words[words.index("--tunnel-cname") + 1] == "edge.example.invalid"
    j.feed("ip -")
    assert gl.opts.ingress_ip == ""


def test_a_slirp_or_mesh_l2_ingress_ip_is_refused_on_the_tui(guest):
    j, gl = _go_live_screen(guest)
    _pick_target(j, gl, "rpi5/pki")
    _to_plan(j, gl, "byo-domain")
    for ip in ("10.0.2.15", "10.77.0.5"):
        j.feed(f"ip {ip}")
        assert gl.opts.ingress_ip == "", ip
        assert "the emulator's private network" in j.status, j.status
    assert not any(" plan " in c[-1] for c in guest.calls())


def test_ddns_subdomain_is_a_command_for_a_ddns_provider(guest):
    j, gl = _go_live_screen(guest)
    _pick_target(j, gl, "rpi5/pki")
    _to_plan(j, gl, "duckdns")
    assert "sub LABEL|-" in "\n".join(j.lines())
    j.feed("sub home")
    assert gl.opts.ddns_subdomain == "home"
    assert "--ddns-subdomain home" in "\n".join(j.lines())
    j.feed("ip 203.0.113.10")                        # duckdns takes no ingress IP
    assert gl.opts.ingress_ip == ""
    assert "duckdns takes no" in j.status


def test_this_host_takes_the_same_inputs_into_its_command(guest):
    j, gl = _go_live_screen(guest)
    _to_plan(j, gl, "byo-domain")
    j.feed("ip 203.0.113.10")
    assert gl.opts.ingress_ip == "203.0.113.10"
    assert "--ingress-ip 203.0.113.10" in "\n".join(j.lines())
    j.feed("ip 10.0.2.15")                           # a real node's LAN: not refused
    assert gl.opts.ingress_ip == "10.0.2.15"

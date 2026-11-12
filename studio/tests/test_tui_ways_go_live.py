"""The text face's twin of the Ways tab's ‘Set up ways to reach this brand’ button:
``go-live`` typed in a domain's Ways section opens the Go-Live screen over Brand
settings with that domain picked, and ``b`` on its first step comes back (2026-10-21).

Headless and Qt-free. The image route (the journey's Brand settings step) and the Fleet
screen's Brand settings are both driven; the Docker mesh screen embeds the same
``DomainServicesScreen``, so the same handler serves it.
"""
import os
import re

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
    text = "\n".join(j.lines())
    assert "effective posture:   internal" in text
    # the reading carries its read time wherever it is printed — the plan screen's
    # own line and the s output under it — and the output says which verb and when
    at = gl.posture.at
    assert _STAMP.fullmatch(at), at
    said = (f"device posture at the last s (read {at}): INTERNAL — both witnesses say "
            "internal (hugmesh-go-live status; nft table inet hugmesh_release_gate)")
    assert _posture_lines(text) == [said, said]
    assert f"output of s (read {at}):" in text
    j.feed("l")
    text = "\n".join(j.lines())
    assert "byo-domain files" in text
    # the list is the device's registry as read when it was picked: no read time
    assert "\noutput of l:\n" in text and "output of s" not in text
    j.feed("p")
    assert _STAMP.fullmatch(_output_stamp("\n".join(j.lines()), "p"))


#: a read time, as golive_target.utc_now writes it
_STAMP = re.compile(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ")


def _posture_lines(text: str) -> list[str]:
    """Every line of the screen that states the device's posture, unindented."""
    return [ln.strip() for ln in text.splitlines()
            if ln.strip().startswith("device posture")]


def _output_stamp(text: str, verb: str) -> str:
    """The time in the plan screen's ``output of VERB (read|run …):`` heading: s
    READS the device, p RUNS a plan on it."""
    word = "run" if verb == "p" else "read"
    m = re.search(rf"^output of {verb} \({word} ([^)]*)\):$", text, re.M)
    assert m, text
    return m.group(1)


def _no_posture_is_called_now(text: str) -> None:
    """The plan screen redraws on every key without asking the device, so nothing on
    it may call a reading "now", and every reading that IS quoted has its time."""
    assert "posture now" not in text, text
    for ln in _posture_lines(text):
        assert ln.startswith("device posture: unknown (not read) — ") or re.match(
            r"device posture at the last s \(read \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\): ",
            ln), ln


def _boot_from_a_save_taken_while_public(guest, tmp_path):
    """rpi5/pki: this host's commit journalled during boot 1, then a save taken while
    PUBLIC, then boot 2 from that save (the saved disk carries the marker)."""
    import json
    from hugmesh_studio.core import golive_target as gt
    sdir = tmp_path / "work" / "saves" / "mesh-20261111T152704Z"
    sdir.mkdir(parents=True)
    disk = sdir / "rpi5_pki.qcow2"
    disk.write_text("qcow2")
    (sdir / "mesh-save.json").write_text(json.dumps({
        "session": "mesh-20261111T152704Z", "created_at": "2026-11-11T15:30:29Z",
        "devices": [{"label": "rpi5/pki", "target": str(disk), "ok": True,
                     "golive_posture": gt.Posture(status="public", nft="public",
                                                  reachable=True).as_record()}]}))
    first = fake.register(guest, label="rpi5/pki", started_at="2026-11-11T15:11:59Z")
    gt.write_journal(gt.target_from_device(first, guest.work_dir), "commit",
                     "byo-domain", "example.invalid", rc=0, now="2026-11-11T15:26:38Z")
    fake.register(guest, label="rpi5/pki", started_at="2026-11-11T15:31:13Z",
                  boot_save=str(disk))
    fake.set_public(guest)


def test_s_after_a_boot_from_a_save_taken_while_public_says_public(guest, tmp_path):
    """The live defect on the TUI face (tui-rebind.txt): the plan screen and `s`
    printed 'reset by a restart (… INTERNAL)' beside the device's own 'public'."""
    _boot_from_a_save_taken_while_public(guest, tmp_path)
    j, gl = _go_live_screen(guest)
    _pick_target(j, gl, "rpi5/pki")
    _to_plan(j, gl, "byo-domain")
    text = "\n".join(j.lines())
    # before `s`: nothing was read, and nothing is guessed
    assert "device posture: unknown (not read) — s reads it from the device" in text
    assert "booted from a save taken while PUBLIC (mesh-20261111T152704Z" in text
    assert "during an earlier boot (the device booted again at 2026-11-11T15:31:13Z)" in text
    assert "INTERNAL" not in text and "reset by a restart" not in text
    _no_posture_is_called_now(text)
    j.feed("s")
    text = "\n".join(j.lines())
    assert "effective posture:   public" in text
    said = (f"device posture at the last s (read {gl.posture.at}): PUBLIC — both "
            "witnesses say public (hugmesh-go-live status; nft table inet "
            "hugmesh_release_gate)")
    # the plan screen quotes the read, and so does the s output: same words, same time
    assert _posture_lines(text) == [said, said]
    assert "INTERNAL" not in text and "reset by a restart" not in text
    _no_posture_is_called_now(text)


def test_s_while_the_reconcile_lags_says_mixed_and_unreachable_says_unknown(
        guest, monkeypatch):
    j, gl = _go_live_screen(guest)
    _pick_target(j, gl, "rpi5/pki")
    _to_plan(j, gl, "byo-domain")
    fake.set_public(guest)                           # committed; nft not caught up yet
    monkeypatch.setenv("FAKE_GUEST_NFT", "internal")
    j.feed("s")
    text = "\n".join(j.lines())
    assert f"device posture at the last s (read {gl.posture.at}): MIXED — " \
        "hugmesh-go-live status says public, the nft release gate says internal" in text
    _no_posture_is_called_now(text)
    monkeypatch.setenv("FAKE_GUEST_NFT", "absent")  # no table loaded: never "public"
    j.feed("s")
    text = "\n".join(j.lines())
    assert "the nft release gate says unknown (table inet hugmesh_release_gate absent " \
        "or unreadable)" in text
    # an unloaded table is not a reconcile lag: no promise that it converges
    assert all("converges them" not in ln for ln in _posture_lines(text))
    assert len(_posture_lines(text)) == 2
    monkeypatch.setenv("FAKE_GUEST_DOWN", "1")
    j.feed("s")
    text = "\n".join(j.lines())
    assert f"device posture at the last s (read {gl.posture.at}): unknown (device not " \
        "reachable) — ssh to rpi5/pki failed (exit 255)" in text
    _no_posture_is_called_now(text)


# ── round 2 of #1007: nothing an EARLIER boot said stays on the plan screen ──────────
# The plan screen redraws on every key and never sshes to draw. Whatever it quotes
# from the device (the posture line, the s / l / p output) was read at some earlier
# moment from some binding: it is shown with its read time while the pick is still
# that binding, withheld the moment it is not, and dropped on a re-bind or a pick.

def _nftrc_calls(guest) -> int:
    return len([c for c in guest.calls() if "@@nftrc" in c[-1]])


def _s_at_boot_one_then_boot_from_a_public_save(guest, tmp_path):
    """`s` reads INTERNAL at boot 1; the device is then booted from a save taken
    while PUBLIC — same ssh port, new started_at. Returns (j, gl, boot-1 read time)."""
    j, gl = _go_live_screen(guest)
    _pick_target(j, gl, "rpi5/pki")
    _to_plan(j, gl, "byo-domain")
    j.feed("s")
    assert "INTERNAL — both witnesses say internal" in "\n".join(j.lines())
    at = gl.posture.at
    _boot_from_a_save_taken_while_public(guest, tmp_path)
    assert gl.target.ssh_port == 22401               # the port did not move: only the boot
    return j, gl, at


def test_a_restart_withholds_what_the_earlier_boot_said(guest, tmp_path):
    """The refuter's P8: the header was right ('unknown (not read)'), but the output
    section went on showing boot 1's `s` — 'device posture now: INTERNAL — both
    witnesses say internal' and the driver's own 'effective posture: internal' —
    while the device was PUBLIC."""
    j, gl, at = _s_at_boot_one_then_boot_from_a_public_save(guest, tmp_path)
    asked = _nftrc_calls(guest)
    text = "\n".join(j.lines())                      # any key: the screen redraws
    assert _posture_lines(text) == ["device posture: unknown (not read) — t, then r: "
                                    "re-scan"]
    assert "INTERNAL" not in text and "both witnesses" not in text
    assert "effective posture" not in text and "go-live marker" not in text
    # the output is withheld, and says so (which verb, when, and how to get it back)
    assert (f"output of s (read {at}): not shown — it was read before rpi5/pki "
            "changed, so it is not this device's word any more (t, then r: re-scan).") \
        in text
    assert not any(ln.startswith("  domain (cluster):") for ln in text.splitlines())
    # the save line is the CURRENT boot's (it did boot from that save)
    assert "booted from a save taken while PUBLIC (mesh-20261111T152704Z" in text
    assert _nftrc_calls(guest) == asked, "a redraw asked the device"
    _no_posture_is_called_now(text)
    # the plan's output is the earlier boot's word just as much
    j2, gl2 = _go_live_screen(guest)
    fake.register(guest, label="rpi5/pki")           # back on the golden, boot 1
    _pick_target(j2, gl2, "rpi5/pki")
    _to_plan(j2, gl2, "byo-domain")
    j2.feed("p")
    assert "==> Plan summary ready" in "\n".join(j2.lines())
    _restart(guest, port=22401, started_at="2026-11-11T17:00:00Z")
    text = "\n".join(j2.lines())
    assert "==> Plan summary ready" not in text and "artifacts copied back" not in text
    assert re.search(r"^output of p \(run [^)]*\): not shown — ", text, re.M), text


def test_r_drops_the_earlier_boots_reading_and_output(guest, tmp_path):
    """`t`, `r` re-binds the pick to the new boot: its posture is unread again and
    nothing of boot 1 is left — not on the screen, and not held to come back."""
    j, gl, _at = _s_at_boot_one_then_boot_from_a_public_save(guest, tmp_path)
    j.feed("")                                       # back to the providers
    j.feed("t")
    j.feed("r")
    assert gl.target.started_at == "2026-11-11T15:31:13Z"
    assert gl.posture is None and gl.run_log == [] and gl.run_log_of == ""
    j.feed("")
    _to_plan(j, gl, "byo-domain")
    text = "\n".join(j.lines())
    assert _posture_lines(text) == ["device posture: unknown (not read) — s reads it "
                                    "from the device"]
    assert "INTERNAL" not in text and "output of" not in text
    assert "sudo hugmesh-go-live commit" in text     # re-bound: the flip is handed over
    j.feed("s")
    text = "\n".join(j.lines())
    assert [ln.split("): ")[1][:6] for ln in _posture_lines(text)] == ["PUBLIC", "PUBLIC"]
    assert "INTERNAL" not in text


def test_picking_the_device_again_drops_the_earlier_boots_reading(guest, tmp_path):
    """The other way to a fresh binding: `t`, then its NUMBER (set_target)."""
    j, gl, _at = _s_at_boot_one_then_boot_from_a_public_save(guest, tmp_path)
    j.feed("")
    _pick_target(j, gl, "rpi5/pki")
    assert gl.target.started_at == "2026-11-11T15:31:13Z"
    assert gl.posture is None and gl.run_log == [] and gl.run_log_of == ""
    _to_plan(j, gl, "byo-domain")
    text = "\n".join(j.lines())
    assert _posture_lines(text) == ["device posture: unknown (not read) — s reads it "
                                    "from the device"]
    assert "INTERNAL" not in text and "output of" not in text


def test_a_reading_is_never_called_now_after_the_operators_own_flip(guest):
    """The refuter's P6: `s` reads INTERNAL, the operator pastes the commit into
    another terminal and answers y; the plan screen went on saying 'device posture
    now … INTERNAL'. It is the last s's reading, and is labelled as that."""
    j, gl = _go_live_screen(guest)
    _pick_target(j, gl, "rpi5/pki")
    _to_plan(j, gl, "byo-domain")
    j.feed("s")
    at = gl.posture.at
    fake.set_public(guest)                           # the flip, in another terminal
    asked = _nftrc_calls(guest)
    j.feed("ip 203.0.113.10")                        # any key: the screen redraws
    text = "\n".join(j.lines())
    assert _nftrc_calls(guest) == asked              # a redraw does not ask the device
    assert _posture_lines(text) == [f"device posture at the last s (read {at}): INTERNAL "
                                    "— both witnesses say internal (hugmesh-go-live "
                                    "status; nft table inet hugmesh_release_gate)"]
    _no_posture_is_called_now(text)
    j.feed("s")                                      # asked again: the device's answer
    text = "\n".join(j.lines())
    assert "): PUBLIC — both witnesses say public" in text and "INTERNAL" not in text
    _no_posture_is_called_now(text)


def test_a_stale_pick_reports_the_current_boot_not_the_one_it_picked(guest, tmp_path):
    """The refuter's P7: picked while booted from a save taken while PUBLIC, then
    restarted from its golden image. The screen kept 'booted from a save taken while
    PUBLIC' and measured the journal against the boot that was over."""
    _boot_from_a_save_taken_while_public(guest, tmp_path)
    j, gl = _go_live_screen(guest)
    _pick_target(j, gl, "rpi5/pki")
    _to_plan(j, gl, "byo-domain")
    assert "booted from a save taken while PUBLIC" in "\n".join(j.lines())
    save = gl.target.boot_save
    fake.set_public(guest, False)
    fake.register(guest, label="rpi5/pki", started_at="2026-11-11T16:00:00Z")  # golden
    text = "\n".join(j.lines())
    assert _posture_lines(text) == ["device posture: unknown (not read) — t, then r: "
                                    "re-scan"]
    assert "booted from" not in text and "PUBLIC" not in text
    assert "during an earlier boot (the device booted again at 2026-11-11T16:00:00Z)" \
        in text
    assert "booted again at 2026-11-11T15:31:13Z)" not in text.split("!! ")[0]
    # stopped (its record still names the save its next Start resumes from): not a
    # boot that is running — said as the LAST boot, and that it is not running
    fake.register(guest, label="rpi5/pki", started_at="2026-11-11T16:00:00Z",
                  state="stopped", boot_save=save)
    text = "\n".join(j.lines())
    assert ("last booted from a save taken while PUBLIC (mesh-20261111T152704Z, saved "
            "2026-11-11T15:30:29Z) — it is not running now") in text
    assert "\nbooted from" not in text
    assert "stopped since it was picked" in text


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


def test_this_host_on_native_windows_still_lists_the_registry(monkeypatch):
    """The device-only gate above must not reach This host. On native Windows the
    driver cannot run there, and the registry it reads instead is this checkout's own,
    and real: the provider step lists it and a pick goes on (test_golive_registry)."""
    from hugmesh_studio.core import golive_driver
    monkeypatch.setattr(golive_driver.platform_info, "native_windows_blocker",
                        lambda action, osname=None, runs="": "needs WSL2")
    j = journey.Journey(GENERATOR_DIR)
    j.goto("golive")
    gl = j.screen()
    assert gl.target.is_local and gl.stage == "provider"
    text = "\n".join(gl.lines(j))
    assert "  1. cloudflare-tunnel" in text and "needs WSL2" not in text
    ids = [p.id for p in gl._driver(j).providers()]
    j.feed(str(ids.index("byo-domain") + 1))
    assert gl.stage == "domain" and gl.opts.provider == "byo-domain"


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

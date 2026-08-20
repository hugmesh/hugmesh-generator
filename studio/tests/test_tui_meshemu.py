"""tui — the whole-mesh emulation screen (#69's TUI surface).

Headless and hermetic: the 3-device session fixture mirrors
test_mesh_emulation.py's, the registry/results dirs start empty (honest "not
started" everywhere), and NOTHING is spawned — access is copy-ready command
hints built by the same single-argv-author core functions the GUI drives.
"""
import io
import json
import os

import pytest

from hugmesh_studio.core import mesh_emulation as me
from hugmesh_studio.core import qemu_tests
from hugmesh_studio.tui import app as tui_app
from hugmesh_studio.tui import journey, meshemu

SESSION = "20260810-101010-mesh"


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture
def gen(tmp_path):
    """A generator dir holding one 3-device session: rpi5/pki, x86/be, x86/fe."""
    gen = tmp_path / "gen"
    sess = gen / "out" / "sessions" / SESSION
    sess.mkdir(parents=True)
    for name in ("hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img.xz",
                 "hugmesh-x86-amd64-be-test-20260807T172418Z.img",
                 "hugmesh-x86-amd64-fe-test-20260807T172419Z.img"):
        (sess / name).write_bytes(b"")
    return str(gen)


def _at_table(gen) -> journey.Journey:
    j = journey.Journey(gen)
    j.feed("")            # welcome -> mode
    j.feed("5")           # the meshemu card (journey position 5)
    assert j.slug == "meshemu"
    j.feed("1")           # pick the only session
    return j


# ── session picker first ────────────────────────────────────────────────────────────
def test_asks_for_the_session_first_and_lists_only_bootable_ones(gen):
    j = journey.Journey(gen)
    j.feed("")
    j.feed("5")
    text = "\n".join(j.lines())
    assert SESSION in text and "3 bootable image(s)" in text


def test_empty_generator_dir_is_an_honest_empty_list(tmp_path):
    j = journey.Journey(str(tmp_path))
    j.feed("")
    j.feed("5")
    assert any("no build session holds bootable images" in ln
               for ln in j.lines())


# ── the per-device status list ──────────────────────────────────────────────────────
def test_table_has_one_row_per_planned_device_in_boot_order(gen):
    j = _at_table(gen)
    plan = me.plan_mesh(qemu_tests.discover_sessions(gen)[0], gen)
    _headers, rows = meshemu.device_table(plan, [])
    assert [r[1] for r in rows] == ["rpi5/pki", "x86/be", "x86/fe"]  # Pi first
    text = "\n".join(j.lines())
    for label in ("rpi5/pki", "x86/be", "x86/fe"):
        assert label in text
    for section in me.SECTIONS:
        assert section in text                       # the four section columns


def test_statuses_are_honest_off_when_nothing_runs(gen):
    j = _at_table(gen)
    _headers, rows = meshemu.device_table(
        me.plan_mesh(qemu_tests.discover_sessions(gen)[0], gen), [])
    for row in rows:
        assert row[5:] == ["off", "off", "off", "off"]
        assert "(planned)" in row[4]                 # no registry: planned port


def test_summary_names_the_front_door(gen):
    j = _at_table(gen)
    text = "\n".join(j.lines())
    assert "gateway x86/fe" in text                  # fe wins the gateway rule
    assert "front door" in text and "https://127.0.0.1:" in text


# ── the per-device detail: identity + copy-ready hints ─────────────────────────────
def test_detail_shows_identity_and_a_start_hint_for_a_stopped_device(gen):
    j = _at_table(gen)
    j.feed("1")                                      # rpi5/pki detail
    text = "\n".join(j.lines())
    assert "52:54:00" in text and "10.77.0." in text
    assert "keys.img" in text                        # the USB provisioning stick
    assert "--only rpi5/pki" in text and "--keep-alive" in text
    assert "run-qemu-docker.sh" in text
    assert "--stop-all-devices" in text


def test_detail_ssh_and_tunnel_hints_for_a_live_gateway(gen):
    sessions = qemu_tests.discover_sessions(gen)
    plan = me.plan_mesh(sessions[0], gen)
    gw = plan.gateway
    # a live registry record, exactly as the harness writes it
    dev_dir = os.path.join(plan.work_dir, "devices")
    os.makedirs(dev_dir)
    record = {"label": gw.label, "platform": gw.platform, "role": gw.role,
              "container": "hugmesh-qemu-x86_fe", "ssh_host_port": 22399,
              "ssh_user": "tester", "ssh_key": "/w/keys/id_ed25519",
              "users": ["tester"], "qmp": "/w/q.sock", "state": "running",
              "started_at": "2026-08-19T00:00:00Z"}
    with open(os.path.join(dev_dir, "x86_fe.json"), "w", encoding="utf-8") as fh:
        json.dump(record, fh)
    j = _at_table(gen)
    j.feed(str(gw.index + 1))
    text = "\n".join(j.lines())
    assert "ssh -i /w/keys/id_ed25519 -p 22399" in text
    assert f"-L {gw.ui_port}:127.0.0.1:443" in text  # the web tunnel hint
    assert me.front_door_url(plan) in text


def test_q_walks_back_through_the_substates_not_out(gen):
    j = _at_table(gen)
    j.feed("1")
    j.feed("q")                                      # detail -> table
    assert "device" in "\n".join(j.lines())
    j.feed("q")                                      # table -> picker
    assert any("pick the prior build session" in ln for ln in j.lines())
    j.feed("q")                                      # picker -> the mode menu
    assert j.slug == "mode" and not j.done


# ── the headless flag (the --worklist precedent) ────────────────────────────────────
def test_main_meshemu_flag_prints_the_status_list(gen):
    out = io.StringIO()
    rc = tui_app.main(["--meshemu", SESSION, "--generator-dir", gen],
                      inp=io.StringIO(""), out=out)
    assert rc == 0
    text = out.getvalue()
    assert "rpi5/pki" in text and "x86/fe" in text and "front door" in text


def test_main_meshemu_unknown_session_exits_2(gen, capsys):
    rc = tui_app.main(["--meshemu", "no-such", "--generator-dir", gen],
                      inp=io.StringIO(""), out=io.StringIO())
    assert rc == 2
    assert "no artifact session" in capsys.readouterr().err

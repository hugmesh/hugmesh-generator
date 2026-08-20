"""core/mesh_emulation.py — the whole-mesh emulation planner, hermetically.

Pure-core: no Qt, no docker, no qemu, no images. The planner is arithmetic over
a session's artifact rows, so everything here runs against a 3-device session
fixture on a tmpdir; the one impure function (``spawn``) is exercised against a
plain /bin/echo-style child, which is a subprocess, not an emulator.
"""
import os
import sys
import threading

import pytest

from hugmesh_studio.core import mesh_emulation as me
from hugmesh_studio.core import qemu_devices, qemu_tests


# ---- the 3-device session fixture ---------------------------------------------------

@pytest.fixture
def session(tmp_path):
    """One build session holding a 3-device mesh: rpi5/pki, x86/be, x86/fe."""
    gen = tmp_path / "gen"
    sess = gen / "out" / "sessions" / "20260810-101010-mesh"
    sess.mkdir(parents=True)
    for name in ("hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img.xz",
                 "hugmesh-x86-amd64-be-test-20260807T172418Z.img",
                 "hugmesh-x86-amd64-fe-test-20260807T172419Z.img"):
        (sess / name).write_bytes(b"")
    sessions = qemu_tests.discover_sessions(str(gen))
    assert len(sessions) == 1 and len(sessions[0].rows) == 3
    return str(gen), sessions[0]


@pytest.fixture
def plan(session):
    gen, sess = session
    return gen, me.plan_mesh(sess, gen)


def _device(planned, *, state="running", port=22301, key="/w/keys/id_ed25519"):
    """A live registry record for a planned device, as qemu_devices hands it over."""
    return qemu_devices.Device(
        label=planned.label, platform=planned.platform, role=planned.role,
        container=f"hugmesh-qemu-{qemu_devices.safe_label(planned.label)}",
        ssh_host_port=port, ssh_user="tester", ssh_key=key,
        users=["tester", "alice"], qmp="/w/q.sock", state=state,
        started_at="2026-08-19T00:00:00Z")


# ---- planning: non-conflicting ports and identities ---------------------------------

def test_plan_covers_every_session_image_in_boot_order(plan):
    _gen, p = plan
    assert [d.label for d in p.devices] == ["rpi5/pki", "x86/be", "x86/fe"]
    assert [d.index for d in p.devices] == [0, 1, 2]
    assert all(os.path.isabs(d.image) for d in p.devices)


def test_plan_assigns_nonconflicting_ports_and_identities(plan):
    _gen, p = plan
    for attr in ("ssh_port", "ui_port", "mac", "ip"):
        values = [getattr(d, attr) for d in p.devices]
        assert len(set(values)) == len(values), f"{attr} collides: {values}"
    for d in p.devices:
        assert me.SSH_PORT_MIN <= d.ssh_port <= me.SSH_PORT_MAX
        assert me.UI_PORT_MIN <= d.ui_port <= me.UI_PORT_MAX
        # the web-tunnel ports must stay OFF the live stack's :8443/:8080
        assert d.ui_port not in (8080, 8443)
        assert d.mac.startswith(me.MAC_PREFIX + ":")
        assert len(d.mac.split(":")) == 6
        assert d.ip.startswith(me.MESH_SUBNET + ".")
        # .1 stays reserved for the future shared network's host gateway
        assert int(d.ip.rsplit(".", 1)[1]) >= 11


def test_plan_is_deterministic_across_replans(session):
    gen, sess = session
    assert me.plan_mesh(sess, gen) == me.plan_mesh(sess, gen)


def test_plan_keys_image_is_the_entrypoints_own_spelling(plan):
    """<work>/runs/<safe-label>/keys.img — docker-entrypoint.sh:699's path, so the
    row points at the emulated USB stick the existing tools actually build."""
    gen, p = plan
    d = p.device("rpi5/pki")
    assert d.keys_image == os.path.join(
        gen, qemu_tests.DEFAULT_WORK_SUBDIR, "runs", "rpi5_pki", "keys.img")


def test_plan_refuses_a_session_larger_than_the_port_ranges(session):
    gen, sess = session
    rows = [qemu_tests.DeviceRow(platform="x86", arch="amd64", role=f"r{i}",
                                 env="test", image=f"/img/{i}.img")
            for i in range(200)]
    big = qemu_tests.BuildSession(path=sess.path, name=sess.name, rows=rows)
    with pytest.raises(ValueError):
        me.plan_mesh(big, gen)


# ---- the front door ------------------------------------------------------------------

def test_gateway_prefers_the_fe_role_and_the_url_names_its_port(plan):
    _gen, p = plan
    assert p.gateway_label == "x86/fe"
    gw = p.gateway
    assert me.front_door_url(p) == f"https://127.0.0.1:{gw.ui_port}/"


def test_gateway_falls_back_when_no_preferred_role_exists():
    rows = [qemu_tests.DeviceRow(platform="rpi5", arch="arm64", role="generic",
                                 env="test", image="/i.img")]
    assert me.gateway_label(rows) == "rpi5/generic"
    assert me.gateway_label([]) == ""


def test_web_tunnel_rides_the_published_ssh_port(plan):
    _gen, p = plan
    gw = p.gateway
    dev = _device(gw, port=22302)
    argv = me.web_tunnel_argv(dev, gw)
    assert argv[0] == "ssh" and "-N" in argv
    assert argv[argv.index("-p") + 1] == "22302"
    assert argv[argv.index("-L") + 1] == f"{gw.ui_port}:127.0.0.1:443"
    assert argv[-1] == "tester@127.0.0.1"
    # no published port / no key: refuse rather than emit ssh -p 0 (the operator's
    # own workstation sshd lives on 127.0.0.1:22)
    with pytest.raises(ValueError):
        me.web_tunnel_argv(_device(gw, port=0), gw)
    with pytest.raises(ValueError):
        me.web_tunnel_argv(_device(gw, key=""), gw)


# ---- argv builders (all through the existing runner) ---------------------------------

def test_start_mesh_argv_is_the_keepalive_fanout_over_the_session(plan):
    gen, p = plan
    argv = me.start_mesh_argv(gen, p)
    assert argv[0] == os.path.join(gen, qemu_tests.RUNNER_SCRIPT)
    assert "--keep-alive" in argv
    assert argv[argv.index("--artifacts") + 1] == p.session_path
    assert "--only" not in argv


def test_start_device_argv_reenters_the_boot_path_for_one_label(plan):
    """The GUI/TUI-facing spelling (--only, substring) until T3/T4 move those
    surfaces onto core.emulation.start_device_argv, which uses --only-exact."""
    gen, p = plan
    d = p.device("x86/be")
    argv = me.start_device_argv(gen, p, d)
    assert "--keep-alive" in argv
    assert argv[argv.index("--only") + 1] == "x86/be"


def test_stop_argvs_are_the_runners_own_verbs(plan):
    gen, p = plan
    d = p.device("rpi5/pki")
    assert me.stop_device_argv(gen, d) == [
        os.path.join(gen, qemu_tests.RUNNER_SCRIPT), "--stop-device", "rpi5/pki"]
    assert me.stop_mesh_argv(gen) == [
        os.path.join(gen, qemu_tests.RUNNER_SCRIPT), "--stop-all-devices"]


def test_stop_argvs_can_carry_the_meshes_work_dir(plan):
    """The start/stop asymmetry fix: every start argv pins --work, so a stop that
    let the runner default would aim at a registry the device never registered in.
    Callers that know the work dir (core.emulation always does) pass it; a bare
    label works too, because a stop only needs the name."""
    gen, p = plan
    d = p.device("rpi5/pki")
    assert me.stop_device_argv(gen, d, work_dir=p.work_dir) == [
        os.path.join(gen, qemu_tests.RUNNER_SCRIPT),
        "--work", p.work_dir, "--stop-device", "rpi5/pki"]
    assert me.stop_device_argv(gen, "rpi5/pki", work_dir=p.work_dir) == \
        me.stop_device_argv(gen, d, work_dir=p.work_dir)
    assert me.stop_mesh_argv(gen, work_dir=p.work_dir) == [
        os.path.join(gen, qemu_tests.RUNNER_SCRIPT),
        "--work", p.work_dir, "--stop-all-devices"]


# ---- section statuses ----------------------------------------------------------------

def test_sections_are_off_for_a_device_that_never_registered(plan):
    _gen, p = plan
    d = p.device("x86/be")
    stats = me.section_statuses(d, None, None)
    assert set(stats) == set(me.SECTIONS)
    assert stats["boot"][0] == me.ST_OFF
    assert stats["ssh"][0] == me.ST_OFF
    assert stats["provision"][0] == me.ST_OFF


def test_sections_read_ok_for_a_running_passing_gateway(plan):
    _gen, p = plan
    gw = p.gateway
    dev = _device(gw)
    result = {"label": gw.label, "status": "PASS",
              "assertions_passed": 12, "assertions_failed": 0}
    stats = me.section_statuses(gw, dev, result, gateway=True)
    assert stats["boot"][0] == me.ST_OK
    assert stats["ssh"] == (me.ST_OK, "127.0.0.1:22301")
    assert stats["provision"][0] == me.ST_OK
    assert stats["web"][0] == me.ST_OK
    assert str(gw.ui_port) in stats["web"][1]


def test_sections_state_failure_and_pending_honestly(plan):
    _gen, p = plan
    d = p.device("x86/be")
    dev = _device(d)
    failed = me.section_statuses(
        d, dev, {"label": d.label, "status": "FAIL",
                 "assertions_passed": 3, "assertions_failed": 2})
    assert failed["provision"][0] == me.ST_FAILED
    pending = me.section_statuses(d, dev, None)
    assert pending["provision"][0] == me.ST_PENDING
    # a non-gateway row never claims the front door
    assert pending["web"][0] == me.ST_OFF


def test_device_status_maps_the_registry_states(plan):
    _gen, p = plan
    d = p.device("rpi5/pki")
    assert me.device_status(None) == (me.ST_OFF, "not started")
    assert me.device_status(_device(d, state="booting"))[0] == me.ST_PENDING
    assert me.device_status(_device(d, state="running")) == (me.ST_OK, "up")
    assert me.device_status(_device(d, state="stopped"))[0] == me.ST_OFF


# ---- the ONE process boundary ---------------------------------------------------------
# spawn() was PROMOTED to core/emulation.py (T2); the alias here must keep the
# full contract until T4 retires it, so these tests exercise it THROUGH the alias.

def test_spawn_is_an_alias_for_the_facades_boundary(monkeypatch):
    """tui/meshemu.py keeps importing mesh_emulation.spawn until T4 — it must call
    the ONE promoted implementation, arguments forwarded verbatim."""
    from hugmesh_studio.core import emulation as em
    seen = {}

    def _spy(argv, cwd, on_line=None, cancel=None):
        seen.update(argv=argv, cwd=cwd, on_line=on_line, cancel=cancel)
        return 42

    monkeypatch.setattr(em, "spawn", _spy)
    cancel = threading.Event()
    cb = lambda line: None  # noqa: E731
    assert me.spawn(["echo", "hi"], "/cwd", on_line=cb, cancel=cancel) == 42
    assert seen == {"argv": ["echo", "hi"], "cwd": "/cwd",
                    "on_line": cb, "cancel": cancel}


def test_spawn_streams_lines_and_returns_the_exit_code(tmp_path):
    """spawn() is the single function the GUI calls and the tests mock — so its
    real behaviour (line streaming, exit code, no shell) is pinned here against a
    plain child process."""
    lines = []
    rc = me.spawn([sys.executable, "-c", "print('one'); print('two')"],
                  str(tmp_path), on_line=lines.append)
    assert rc == 0 and lines == ["one", "two"]
    assert me.spawn([sys.executable, "-c", "raise SystemExit(3)"],
                    str(tmp_path)) == 3
    assert me.spawn(["/nonexistent/binary"], str(tmp_path),
                    on_line=lines.append) == 127


def test_spawn_cancel_terminates_the_process_group(tmp_path):
    cancel = threading.Event()
    lines = []
    done = {}

    def _run():
        done["rc"] = me.spawn(
            [sys.executable, "-u", "-c",
             "import time; print('up', flush=True); time.sleep(120)"],
            str(tmp_path), on_line=lines.append, cancel=cancel)

    t = threading.Thread(target=_run)
    t.start()
    deadline = 15
    while "up" not in lines and deadline > 0:
        t.join(0.1)
        deadline -= 0.1
    assert "up" in lines, "the child never started"
    cancel.set()
    t.join(15)
    assert not t.is_alive(), "spawn() did not return after cancel"
    assert done["rc"] != 0

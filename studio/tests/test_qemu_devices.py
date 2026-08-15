"""Hermetic tests for core/qemu_devices.py — the live emulated-device registry.

Nothing here starts docker, qemu or ssh. The module's whole job is reading JSON the
runner wrote and building argv for the GUI to spawn, so the registry is FABRICATED in
tmp_path and every argv is asserted as a list — which is also the only way to test
the two rules that would otherwise only be discovered in front of an operator: that a
half-written record costs one row instead of the whole list, and that a device with no
published port never silently aims ssh at 127.0.0.1:22 (the operator's own machine).
"""
import json
import os

import pytest

from hugmesh_studio.core import cloud_deploy
from hugmesh_studio.core import qemu_devices as qd
from hugmesh_studio.core.config import User

WORK = "/work/on/host"          # any path; only the devices/ subdir is ever read


def _write_device(work_dir, label, **overrides):
    """Write one registry record, shaped exactly like docker-entrypoint.sh's."""
    root = qd.devices_dir(str(work_dir))
    os.makedirs(root, exist_ok=True)
    record = {
        "label": label,
        "platform": label.split("/")[0],
        "role": label.split("/")[-1],
        "board": "",
        "container": "hugmesh-qemu-" + label.replace("/", "_") + "-4242",
        "ssh_host_port": 22301,
        "ssh_user": "tester",
        "ssh_key": "/host/out/qemu-runs/keys/id_ed25519",
        "users": ["tester"],
        "qmp": "/host/out/qemu-runs/runs/" + label.replace("/", "_") + "/qmp.sock",
        "state": "running",
        "started_at": "2026-08-15T00:00:00Z",
    }
    record.update(overrides)
    path = os.path.join(root, label.replace("/", "_").replace("+", "_") + ".json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(record, fh)
    return path


def _dev(**overrides):
    fields = {
        "label": "rpi5/pki", "platform": "rpi5", "role": "pki", "board": "",
        "container": "hugmesh-qemu-rpi5_pki-4242", "ssh_host_port": 22301,
        "ssh_user": "tester", "ssh_key": "/host/keys/id_ed25519",
        "users": ["tester"], "qmp": "/host/runs/rpi5_pki/qmp.sock",
        "state": "running", "started_at": "2026-08-15T00:00:00Z",
    }
    fields.update(overrides)
    return qd.Device(**fields)


# ── discovery ────────────────────────────────────────────────────────────────────

def test_discover_devices_no_registry_dir(tmp_path):
    """A work dir from a run that never used --keep-alive simply has no devices."""
    assert qd.discover_devices(str(tmp_path)) == []


def test_discover_devices_newest_first(tmp_path):
    _write_device(tmp_path, "rpi5/pki", started_at="2026-08-15T01:00:00Z")
    _write_device(tmp_path, "x86/omnibus", started_at="2026-08-15T03:00:00Z")
    _write_device(tmp_path, "rpi5/backend", started_at="2026-08-15T02:00:00Z")

    labels = [d.label for d in qd.discover_devices(str(tmp_path))]
    assert labels == ["x86/omnibus", "rpi5/backend", "rpi5/pki"]


def test_discover_devices_skips_corrupt_records(tmp_path):
    """One unreadable file must cost ONE row, not the device list.

    The entrypoint rewrites a record as the guest advances (booting -> running ->
    assertions), so a polling GUI will eventually read one mid-write. All three
    unusable shapes are covered: truncated JSON, a JSON value that is not an object,
    and a record with no label (nothing the runner's LABEL-addressed subcommands
    could ever be pointed at).
    """
    _write_device(tmp_path, "rpi5/pki")
    root = qd.devices_dir(str(tmp_path))
    with open(os.path.join(root, "half_written.json"), "w", encoding="utf-8") as fh:
        fh.write('{"label": "x86/omnibus", "platform": "x8')      # truncated mid-write
    with open(os.path.join(root, "not_an_object.json"), "w", encoding="utf-8") as fh:
        fh.write("[]")
    with open(os.path.join(root, "no_label.json"), "w", encoding="utf-8") as fh:
        json.dump({"platform": "x86", "state": "running"}, fh)
    with open(os.path.join(root, "notes.txt"), "w", encoding="utf-8") as fh:
        fh.write("not a registry file")

    devices = qd.discover_devices(str(tmp_path))
    assert [d.label for d in devices] == ["rpi5/pki"]


def test_discover_devices_reads_every_contract_field(tmp_path):
    _write_device(tmp_path, "rpi5/pki", users=["tester", "alice"], state="assertions",
                  board="pi5-8gb", ssh_host_port=22307)
    dev, = qd.discover_devices(str(tmp_path))
    assert (dev.label, dev.platform, dev.role, dev.board) == (
        "rpi5/pki", "rpi5", "pki", "pi5-8gb")
    assert dev.ssh_host_port == 22307 and isinstance(dev.ssh_host_port, int)
    assert dev.ssh_user == "tester"
    assert dev.users == ["tester", "alice"]
    assert dev.ssh_key.startswith("/host/") and dev.qmp.endswith("qmp.sock")
    assert dev.state == "assertions" and dev.started_at.endswith("Z")


def test_device_by_label(tmp_path):
    _write_device(tmp_path, "rpi5/pki")
    _write_device(tmp_path, "x86/omnibus", started_at="2026-08-15T04:00:00Z")
    devices = qd.discover_devices(str(tmp_path))
    assert qd.device_by_label(devices, "rpi5/pki").role == "pki"
    assert qd.device_by_label(devices, "rpi5/nope") is None


@pytest.mark.parametrize("state,running", [
    ("booting", True), ("running", True), ("assertions", True),
    ("stopped", False), ("", False),
])
def test_is_running(state, running):
    """A blank state is a record that never got updated — not a login target."""
    assert _dev(state=state).is_running is running


# ── ssh argv ─────────────────────────────────────────────────────────────────────

def test_ssh_argv_shape():
    assert qd.ssh_argv(_dev(), "tester") == [
        "ssh", "-i", "/host/keys/id_ed25519", "-p", "22301",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "tester@127.0.0.1",
    ]


def test_ssh_argv_superuser_is_sudo_not_root_login():
    """The guest keeps PermitRootLogin no (assertions.sh asserts it), so the
    superuser button logs in as the wheel user and escalates — with -t, because
    sudo -i needs a pty."""
    argv = qd.ssh_argv(_dev(), "alice", superuser=True)
    assert argv[:1] == ["ssh"]
    assert "alice@127.0.0.1" in argv
    assert argv[-2:] == ["-t", "sudo -i"]
    assert "root@127.0.0.1" not in argv


def test_ssh_argv_only_ever_targets_loopback():
    for argv in (qd.ssh_argv(_dev(), "tester"),
                 qd.ssh_argv(_dev(), "tester", superuser=True)):
        assert [a for a in argv if "@" in a] == [f"tester@{qd.SSH_HOST}"]
        assert qd.SSH_HOST == "127.0.0.1"


def test_ssh_argv_does_not_fall_back_to_port_22():
    """An unpublished device must not aim the button at the operator's own sshd.

    ssh_host_port 0 means the container published nothing; 127.0.0.1:22 on this host
    is the WORKSTATION's sshd, so a "sensible default" would log the operator into
    their own machine and call it a device."""
    argv = qd.ssh_argv(_dev(ssh_host_port=0), "tester")
    assert argv[argv.index("-p") + 1] == "0"


# ── terminal hand-off ────────────────────────────────────────────────────────────

def test_terminal_argv_reuses_the_cloud_deploy_list():
    """Same tuple object, not a copy — a third list would drift on the next addition."""
    assert qd.TERMINALS is cloud_deploy._TERMINALS


def test_terminal_argv_none_when_no_terminal_exists(monkeypatch):
    """A headless box (CI, an ssh session, a server) has no emulator at all; the GUI
    needs None so it can print the command instead of failing to spawn."""
    monkeypatch.setattr(qd, "TERMINALS", (("hugmesh-no-such-terminal", ("-e",)),))
    assert qd.terminal_argv(["ssh", "tester@127.0.0.1"]) is None


def test_terminal_argv_prefers_the_first_available(monkeypatch):
    """Order is the contract: konsole outranks xterm, and each binary's own exec flag
    is used (gnome-terminal/kitty want "--", xfce4-terminal "-x", foot neither)."""
    inner = ["ssh", "-p", "22301", "tester@127.0.0.1"]

    monkeypatch.setattr(qd.shutil, "which",
                        lambda b: "/usr/bin/" + b if b in ("konsole", "xterm") else None)
    assert qd.terminal_argv(inner) == ["konsole", "-e", *inner]

    monkeypatch.setattr(qd.shutil, "which",
                        lambda b: "/usr/bin/" + b if b == "gnome-terminal" else None)
    assert qd.terminal_argv(inner) == ["gnome-terminal", "--", *inner]

    monkeypatch.setattr(qd.shutil, "which",
                        lambda b: "/usr/bin/" + b if b == "foot" else None)
    assert qd.terminal_argv(inner) == ["foot", *inner]


# ── runner passthrough ───────────────────────────────────────────────────────────

def test_qmp_argv():
    argv = qd.qmp_argv("/gen", _dev(), "pause")
    assert argv == ["/gen/tests/qemu/run-qemu-docker.sh", "--qmp", "rpi5/pki", "pause"]
    for cmd in qd.QMP_COMMANDS:
        assert qd.qmp_argv("/gen", _dev(), cmd)[-1] == cmd


def test_qmp_argv_rejects_unknown_verb():
    with pytest.raises(ValueError):
        qd.qmp_argv("/gen", _dev(), "eject-the-disk")


def test_device_control_argv():
    """stop is the runner's LABEL-addressed subcommand; start re-enters the boot path
    filtered to this one row, because a stopped device has no container to resume."""
    assert qd.device_control_argv("/gen", _dev(), "stop") == [
        "/gen/tests/qemu/run-qemu-docker.sh", "--stop-device", "rpi5/pki"]
    assert qd.device_control_argv("/gen", _dev(), "start") == [
        "/gen/tests/qemu/run-qemu-docker.sh", "--keep-alive", "--only", "rpi5/pki"]
    assert qd.stop_all_argv("/gen") == [
        "/gen/tests/qemu/run-qemu-docker.sh", "--stop-all-devices"]


def test_device_control_argv_rejects_unknown_action():
    with pytest.raises(ValueError):
        qd.device_control_argv("/gen", _dev(), "restart")


# ── login dropdown ───────────────────────────────────────────────────────────────

def test_available_logins_labels_device_users_with_their_wizard_domain():
    """The dropdown is the INTERSECTION, labelled from the wizard.

    ``carol`` is a configured mesh identity that was never created as a unix account
    on this image — offering her would produce a Permission denied with no
    explanation, so she is omitted. ``bob`` exists on the guest but has no wizard
    entry, so he is offered unlabelled: he can be logged into, which is the only
    question this list answers.
    """
    dev = _dev(ssh_user="tester", users=["tester", "alice", "bob"])
    cfg_users = [User(username="alice", domain="example.org"),
                 User(username="carol", domain="example.org")]

    logins = qd.available_logins(dev, cfg_users)

    assert logins == [("tester", "tester"),
                      ("alice", "alice @ example.org"),
                      ("bob", "bob")]
    assert "carol" not in [login for login, _display in logins]


def test_available_logins_puts_the_always_present_wheel_user_first():
    """tester is the one account the payload always creates, so the default selection
    is always a login that works — even when the record lists it late or not at all."""
    dev = _dev(ssh_user="tester", users=["alice", "tester"])
    assert [login for login, _ in qd.available_logins(dev, [])] == ["tester", "alice"]

    dev = _dev(ssh_user="tester", users=[])
    assert qd.available_logins(dev, []) == [("tester", "tester")]


def test_available_logins_tolerates_empty_and_duplicate_config_rows():
    """Half-filled wizard rows are normal (the users table starts blank), and must not
    label a device login with an empty domain or crash the dropdown."""
    dev = _dev(ssh_user="tester", users=["tester", "alice"])
    cfg_users = [User(username="", domain="example.org"),
                 User(username="alice", domain=""),
                 User(username="alice", domain="second.example")]
    assert qd.available_logins(dev, cfg_users) == [("tester", "tester"),
                                                   ("alice", "alice")]


def test_available_logins_accepts_any_username_domain_object():
    """cfg_users is duck-typed on .username/.domain, so the GUI can pass its own rows
    without importing ImageConfig's User."""
    class Row:
        def __init__(self, username, domain):
            self.username, self.domain = username, domain

    dev = _dev(ssh_user="tester", users=["tester", "alice"])
    assert qd.available_logins(dev, [Row("alice", "example.org")]) == [
        ("tester", "tester"), ("alice", "alice @ example.org")]


def test_module_is_qt_free_and_side_effect_free_at_import():
    """Same rule as core/qemu_tests.py: importable in the Qt-free CI python.

    A SOURCE grep, not a sys.modules check: the suite's GUI files import Qt long
    before this file runs, so a runtime check would pass or fail on test ORDER
    rather than on this module's dependencies.
    """
    with open(qd.__file__, encoding="utf-8") as fh:
        source = fh.read()
    for banned in ("PySide6", "PyQt6", "hugmesh_studio.gui"):
        assert banned not in source, f"core/qemu_devices.py must not reach for {banned}"
    assert qd.discover_devices(WORK) == []       # a nonexistent work dir, no writes
    assert not os.path.exists(WORK)

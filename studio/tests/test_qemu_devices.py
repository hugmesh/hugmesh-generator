"""Hermetic tests for core/qemu_devices.py — the live emulated-device registry.

Nothing here starts docker, qemu or ssh. The module's whole job is reading JSON the
runner wrote and building argv for the GUI to spawn, so the registry is FABRICATED in
tmp_path and every argv is asserted as a list — which is also the only way to test
the two rules that would otherwise only be discovered in front of an operator: that a
half-written record costs one row instead of the whole list, and that a device with no
published port never silently aims ssh at 127.0.0.1:22 (the operator's own machine).

The pause-and-save block at the bottom is the same idea applied to a destructive
action: where a save may land, when the button is offered at all, and which
``--overwrite`` reaches the runner are all paths and argv, so they are asserted
literally rather than described.
"""
import datetime
import json
import os
import re

import pytest

from hugmesh_studio.core import cloud_deploy
from hugmesh_studio.core import qemu_devices as qd
from hugmesh_studio.core import qemu_tests as qt
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


def test_device_reads_the_t1_start_contract_fields_tolerantly(tmp_path):
    """Records written since 2026-08-19 carry "artifacts" (host path) and "image"
    (booted basename) — the per-device restart contract — plus a state:"booting"
    record published the moment qemu launches. All three must parse, and a record
    from BEFORE that contract must still yield a usable row with empty defaults:
    the registry outlives harness upgrades, and one old record must never cost the
    device list."""
    _write_device(tmp_path, "rpi5/pki", state="booting",
                  artifacts="/host/out/sessions/20260819-125930-89bb8e",
                  image="hugmesh-rpi5-arm64-pki-test-20260819T195951Z.img")
    _write_device(tmp_path, "x86/backend")          # pre-T1 shape: neither field
    new = qd.device_by_label(qd.discover_devices(str(tmp_path)), "rpi5/pki")
    old = qd.device_by_label(qd.discover_devices(str(tmp_path)), "x86/backend")
    assert new.artifacts == "/host/out/sessions/20260819-125930-89bb8e"
    assert new.image == "hugmesh-rpi5-arm64-pki-test-20260819T195951Z.img"
    # booting is a LIVE state: a row killed mid-boot is findable and stoppable.
    assert new.state == "booting" and new.is_running
    assert old.artifacts == "" and old.image == ""


def test_device_from_record_is_the_public_parsing_rule():
    """core.emulation feeds this the runner's --devices output — same records,
    fetched differently — so the public spelling must be the same rule."""
    assert qd.device_from_record({"label": "rpi5/pki", "state": "running",
                                  "artifacts": "/a", "image": "b.img"}).artifacts == "/a"
    assert qd.device_from_record({"state": "running"}) is None    # nameless: no row
    assert qd.device_from_record("not a dict") is None


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
    """stop is the runner's LABEL-addressed subcommand — the one action left here."""
    assert qd.device_control_argv("/gen", _dev(), "stop") == [
        "/gen/tests/qemu/run-qemu-docker.sh", "--stop-device", "rpi5/pki"]
    assert qd.stop_all_argv("/gen") == [
        "/gen/tests/qemu/run-qemu-docker.sh", "--stop-all-devices"]
    assert qd.DEVICE_ACTIONS == ("stop",)


def test_device_control_argv_start_is_a_shim_naming_its_successor():
    """'start' was DELETED (T2): the old spelling let the runner guess its newest
    session and matched the label by substring, so a restart could boot a different
    build than the device came from and drag be+gpu/be-ha along. The shim raises —
    never authors a doomed argv — and its message names the single author a caller
    must move to (core.emulation.start_device_argv, which pins --artifacts/--work
    and uses --only-exact). The shim itself goes with its last caller in T3."""
    with pytest.raises(ValueError) as err:
        qd.device_control_argv("/gen", _dev(), "start")
    assert "emulation.start_device_argv" in str(err.value)
    assert "--only-exact" in str(err.value)


def test_device_control_argv_rejects_unknown_action():
    with pytest.raises(ValueError):
        qd.device_control_argv("/gen", _dev(), "restart")


# ── pause and save ───────────────────────────────────────────────────────────────
# The device's disk is a per-run qcow2 overlay backed by the golden build image. QEMU
# holds that overlay for the life of the guest — a host-side tool cannot even read it
# consistently — and write-locks the golden underneath it as soon as the disk is
# attached to a guest device. So the only save that exists is "the runner copies it
# out through the running QEMU", and the rules worth testing are the ones deciding
# WHERE that copy goes and WHEN the button is offered at all — each of them a path or
# an argv, i.e. assertable exactly.

def test_default_save_target_is_a_stable_qcow2_under_the_work_dir():
    """The overwrite target has to be findable by RULE, not by memory.

    The Studio is restarted between saves and the runner is also driven from a shell,
    so "the existing copy" can only mean "the path this rule produces". It is
    therefore timestamp-free, one per device label, and lands beside runs/ and
    devices/ in the same --work tree the registry was read from.
    """
    assert qd.default_save_target("/gen/out/qemu-runs", _dev()) == \
        "/gen/out/qemu-runs/saves/rpi5_pki.qcow2"
    # Same device, later call: the same path, or "overwrite" has nothing to aim at.
    assert qd.default_save_target("/gen/out/qemu-runs", _dev()) == \
        qd.default_save_target("/gen/out/qemu-runs", _dev())
    # A '+' label is filed the way the runner files it, not left in the filename.
    assert qd.default_save_target("/w", _dev(label="rpi5/backend+pki")) == \
        "/w/saves/rpi5_backend_pki.qcow2"


def test_save_names_use_the_runners_on_disk_spelling():
    """A save must be pairable with the run dir and the result row of the same device.

    Cross-checked against qemu_tests.result_filename rather than restated: that is the
    same ``tr '/+' '__'`` rule as safe_label() in run-qemu-docker.sh and the registry
    filename in docker-entrypoint.sh, so drift in either direction fails here.
    """
    for label in ("rpi5/pki", "x86/standalone-thin", "rpi5/backend+pki"):
        stem = qt.result_filename(label)[: -len(".json")]
        assert qd.safe_label(label) == stem
        assert qd.save_basename(label) == stem + ".qcow2"


def test_new_save_target_never_clobbers_an_existing_copy(tmp_path):
    """"Another copy" means another FILE. A stamp alone would not guarantee that.

    Two saves in the same second, an explicit stamp reused, or a clock that stepped
    backwards would all silently replace a copy the operator asked to keep — so a
    taken name grows a discriminator instead of being handed back.
    """
    work = str(tmp_path)
    dev = _dev()
    first = qd.new_save_target(work, dev, stamp="20260814T120000Z")
    assert first == os.path.join(work, "saves", "rpi5_pki-20260814T120000Z.qcow2")

    os.makedirs(qd.saves_dir(work), exist_ok=True)
    open(first, "w").close()
    second = qd.new_save_target(work, dev, stamp="20260814T120000Z")
    assert second == os.path.join(work, "saves", "rpi5_pki-20260814T120000Z-2.qcow2")

    open(second, "w").close()
    third = qd.new_save_target(work, dev, stamp="20260814T120000Z")
    assert third == os.path.join(work, "saves", "rpi5_pki-20260814T120000Z-3.qcow2")

    # And none of them is the overwrite target: "another copy" never touches it.
    stable = qd.default_save_target(work, dev)
    assert stable == os.path.join(work, "saves", "rpi5_pki.qcow2")
    assert stable not in (first, second, third)


def test_new_save_target_default_stamp_is_a_utc_artifact_stamp():
    """Unstamped copies are named like build artifacts: fixed-width UTC, so a plain
    listing of saves/ is in chronological order."""
    name = os.path.basename(qd.new_save_target("/no/such/work", _dev()))
    match = re.fullmatch(r"rpi5_pki-(\d{8}T\d{6}Z)\.qcow2", name)
    assert match, name
    stamp = match.group(1)
    assert len(stamp) == 16                                   # fixed width, so sortable
    parsed = datetime.datetime.strptime(stamp, qd.SAVE_STAMP_FORMAT) \
                              .replace(tzinfo=datetime.UTC)
    assert abs((datetime.datetime.now(datetime.UTC) - parsed).total_seconds()) < 300


def test_save_targets_are_qcow2_never_raw():
    """A raw save IS the device's whole 16G virtual size; a qcow2 costs the data.

    Measured on this host with qemu 10.2.3: a 64M device holding 2M of data backs up
    to a 3.3M qcow2 — and unlike a sparse raw file it keeps that size through any
    later copy.
    """
    assert qd.SAVE_SUFFIX == ".qcow2"
    for target in (qd.default_save_target("/w", _dev()),
                   qd.new_save_target("/w", _dev(), stamp="20260814T120000Z")):
        assert target.endswith(".qcow2")
    for bad in ("/w/saves/rpi5_pki.img", "/w/saves/rpi5_pki.raw", "/w/saves/rpi5_pki"):
        reason = qd.save_target_refusal(bad)
        assert ".qcow2" in reason and "raw" in reason


@pytest.mark.parametrize("overrides,ok", [
    ({}, True),
    ({"state": "booting"}, True),                 # a booting guest already has a QEMU
    ({"state": "stopped"}, False),                # nothing to pause, no live overlay
    ({"state": ""}, False),                       # never-updated record
    ({"qmp": ""}, False),                         # started without --qmp: no channel
    ({"container": ""}, False),                   # nowhere to run the QMP client
])
def test_can_save_needs_running_plus_container_plus_qmp(overrides, ok):
    assert qd.can_save(_dev(**overrides)) is ok
    assert bool(qd.save_blocker(_dev(**overrides))) is (not ok)


def test_can_save_does_not_depend_on_ssh():
    """Flushing the guest over ssh before the pause makes a cleaner copy, but its
    absence only costs cleanliness — the copy is crash-consistent either way — so a
    device that published no port keeps its save button."""
    dev = _dev(ssh_host_port=0, ssh_key="", ssh_user="", users=[])
    assert qd.can_save(dev) is True
    assert qd.save_blocker(dev) == ""


def test_save_blocker_says_which_prerequisite_is_missing():
    """The GUI shows this text on a disabled button, so it has to name the fix."""
    assert "not running" in qd.save_blocker(_dev(state="stopped"))
    assert "--qmp" in qd.save_blocker(_dev(qmp=""))
    assert "container" in qd.save_blocker(_dev(container=""))


def test_device_save_argv_copy_and_overwrite():
    dev = _dev()
    copy_to = "/gen/out/qemu-runs/saves/rpi5_pki-20260814T120000Z.qcow2"
    assert qd.device_save_argv("/gen", dev, copy_to) == [
        "/gen/tests/qemu/run-qemu-docker.sh",
        "--save-device", "rpi5/pki", "--save-to", copy_to]

    stable = "/gen/out/qemu-runs/saves/rpi5_pki.qcow2"
    assert qd.device_save_argv("/gen", dev, stable, overwrite=True) == [
        "/gen/tests/qemu/run-qemu-docker.sh",
        "--save-device", "rpi5/pki", "--save-to", stable, "--overwrite"]


def test_device_save_argv_never_arms_overwrite_by_itself():
    """Replacing a saved copy is destructive, so the flag only ever comes from an
    explicit request — exactly like the runner's other non-default knobs."""
    argv = qd.device_save_argv("/gen", _dev(), "/gen/out/qemu-runs/saves/a.qcow2")
    assert "--overwrite" not in argv
    assert qd.device_save_argv("/gen", _dev(), "/gen/out/qemu-runs/saves/a.qcow2",
                               overwrite=False) == argv


def test_device_save_argv_refuses_a_device_that_cannot_be_saved():
    for dev in (_dev(state="stopped"), _dev(qmp=""), _dev(container="")):
        with pytest.raises(ValueError):
            qd.device_save_argv("/gen", dev, "/gen/out/qemu-runs/saves/a.qcow2")


def test_device_save_argv_refuses_an_unarmed_clobber(tmp_path):
    """An existing copy at the target is only replaced when overwrite was asked for.

    Advisory — the runner re-checks the path it is about to write — but it is what
    lets the GUI arm a confirmation instead of surfacing a shell error afterwards.
    """
    work = str(tmp_path)
    dev = _dev()
    stable = qd.default_save_target(work, dev)

    # No previous save yet: both spellings are fine, and neither is a clobber.
    assert qd.save_would_overwrite(stable) is False
    assert qd.device_save_argv("/gen", dev, stable, work_dir=work)[-1] == stable
    assert qd.device_save_argv("/gen", dev, stable, overwrite=True,
                               work_dir=work)[-1] == "--overwrite"

    os.makedirs(qd.saves_dir(work), exist_ok=True)
    open(stable, "w").close()
    assert qd.save_would_overwrite(stable) is True
    with pytest.raises(ValueError, match="overwriting"):
        qd.device_save_argv("/gen", dev, stable, work_dir=work)
    assert qd.device_save_argv("/gen", dev, stable, overwrite=True,
                               work_dir=work)[-1] == "--overwrite"


def test_save_target_refusal_accepts_the_targets_this_module_builds():
    work = "/gen/out/qemu-runs"
    for target in (qd.default_save_target(work, _dev()),
                   qd.new_save_target(work, _dev(), stamp="20260814T120000Z")):
        assert qd.save_target_refusal(target, generator_dir="/gen", work_dir=work,
                                      artifacts_dir="/gen/out/sessions/s1") == ""


def test_save_target_refusal_protects_the_golden_images():
    """The artifacts tree is the shared build output every run and session boots from.

    Both spellings are refused — the out/sessions root the builders always use, and
    an explicit --artifacts dir that can be anywhere — and the check survives a
    ``..`` walk, because a refusal you can path-traverse around is not a refusal.
    """
    sessions = qd.save_target_refusal("/gen/out/sessions/s1/rpi5.qcow2",
                                      generator_dir="/gen")
    assert "golden" in sessions and "/gen/out/sessions" in sessions

    elsewhere = qd.save_target_refusal("/mnt/build/artifacts/rpi5.qcow2",
                                       artifacts_dir="/mnt/build/artifacts")
    assert "golden" in elsewhere

    traversal = qd.save_target_refusal(
        "/gen/out/qemu-runs/saves/../../sessions/s1/rpi5.qcow2", generator_dir="/gen")
    assert "golden" in traversal


def test_save_target_refusal_is_containment_not_a_string_prefix():
    """out/sessions-archive is NOT inside out/sessions; startswith cannot tell."""
    assert qd.save_target_refusal("/gen/out/sessions-archive/keep.qcow2",
                                  generator_dir="/gen") == ""
    assert qd.save_target_refusal("/mnt/build/artifacts-old/keep.qcow2",
                                  artifacts_dir="/mnt/build/artifacts") == ""


def test_save_target_refusal_protects_the_live_overlay():
    """<work>/runs/<label>/ holds the overlay QEMU has open and write-locked, so a
    target in there is a save that could never be created."""
    reason = qd.save_target_refusal("/gen/out/qemu-runs/runs/rpi5_pki/run.qcow2",
                                    work_dir="/gen/out/qemu-runs")
    assert "live overlay" in reason and "write lock" in reason


def test_save_target_refusal_rejects_unusable_paths(tmp_path):
    assert qd.save_target_refusal("") == "no save target given"
    assert "absolute" in qd.save_target_refusal("saves/rpi5_pki.qcow2")
    a_dir = tmp_path / "rpi5_pki.qcow2"
    a_dir.mkdir()
    assert "is a directory" in qd.save_target_refusal(str(a_dir))


def test_no_argv_this_module_builds_can_commit_into_the_golden_image():
    """The one action that must never reach a button.

    Committing the overlay down into its backing file rewrites the golden build
    artifact in place and drops the overlay out of the chain, so every later guest
    write lands on the artifact every other run boots from. It is not expressible
    here: the GUI builds its monitor buttons from QMP_COMMANDS, and the save argv
    names the runner and a target path — nothing else.
    """
    argvs = [qd.device_save_argv("/gen", _dev(), "/gen/out/qemu-runs/saves/a.qcow2"),
             qd.device_save_argv("/gen", _dev(), "/gen/out/qemu-runs/saves/a.qcow2",
                                 overwrite=True)]
    argvs += [qd.qmp_argv("/gen", _dev(), cmd) for cmd in qd.QMP_COMMANDS]
    for argv in argvs:
        for word in ("commit", "qemu-img", "qemu-nbd", "blockdev-add"):
            assert not any(word in arg for arg in argv), argv
    assert "commit" not in qd.QMP_COMMANDS
    # C5's pause/restore needs all three: read the state, pause, put it back.
    assert {"pause", "resume", "status"} <= set(qd.QMP_COMMANDS)


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


# ---- the guard has to be reachable, not merely present -----------------------------

@pytest.mark.parametrize("bad, why", [
    ("/gen/out/sessions/s1/hugmesh-rpi5-pki.qcow2", "the artifacts tree"),
    ("/gen/out/qemu-runs/images/golden.qcow2",      "the decompressed goldens"),
    ("/gen/out/qemu-runs/runs/rpi5_pki/live.qcow2", "the live overlay dir"),
    ("/gen/out/qemu-runs/devices/rpi5_pki.qcow2",   "the device registry"),
    ("/gen/out/qemu-runs/results/rpi5_pki.qcow2",   "the results dir"),
    ("/somewhere/else/save.qcow2",                  "outside the work dir"),
    ("relative/save.qcow2",                         "a relative path"),
    ("/gen/out/qemu-runs/saves/rpi5_pki.img",       "a raw .img"),
])
def test_device_save_argv_enforces_the_refusal_it_documents(bad, why):
    """The refusal must fire THROUGH the builder, not only when called directly.

    Every refusal test used to call ``save_target_refusal`` itself, so deleting the
    whole ``refusal = ...; if refusal: raise`` block from ``device_save_argv`` — and
    separately, dropping the artifacts_dir/work_dir it forwards — left the suite
    green. The GUI's safety depends on the builder refusing, not on the rule
    existing somewhere nearby, so it is asserted at the builder.
    """
    dev = _dev(label="rpi5/pki", state="running", container="c", qmp="/w/q.sock")
    with pytest.raises(ValueError):
        qd.device_save_argv("/gen", dev, bad,
                            artifacts_dir="/gen/out/sessions/s1",
                            work_dir="/gen/out/qemu-runs")


def test_save_argv_modes_are_the_two_the_operator_asked_for(tmp_path):
    """copy -> a new file; overwrite -> the NEWEST existing save, whoever made it."""
    gen = str(tmp_path / "gen")
    work = qd.default_work_dir(gen)
    os.makedirs(qd.saves_dir(work), exist_ok=True)
    dev = _dev(label="rpi5/pki", state="running", container="c", qmp="/w/q.sock")

    # With nothing saved, "overwrite" must REFUSE rather than quietly create the
    # first copy — otherwise a control labelled destructive silently is not.
    with pytest.raises(ValueError):
        qd.save_argv(gen, dev, "overwrite")

    first = qd.save_argv(gen, dev, "copy")
    target = first[first.index("--save-to") + 1]
    assert "--overwrite" not in first
    open(target, "w").close()

    # A save the RUNNER made from a shell, under its own name, newest of all.
    cli = os.path.join(qd.saves_dir(work), "before-upgrade.qcow2")
    open(cli, "w").close()
    # The runner writes a sidecar beside every save; it is what makes a
    # custom-named file recognisably THIS device's rather than a stray qcow2.
    with open(cli + ".json", "w", encoding="utf-8") as fh:
        json.dump({"label": dev.label}, fh)
    os.utime(cli, (2 ** 31, 2 ** 31))            # unambiguously newest

    ov = qd.save_argv(gen, dev, "overwrite")
    assert ov[ov.index("--save-to") + 1] == cli, \
        "overwrite must replace the newest existing save, including a CLI-made one"
    assert "--overwrite" in ov

    with pytest.raises(ValueError):
        qd.save_argv(gen, dev, "clobber")        # not one of SAVE_MODES

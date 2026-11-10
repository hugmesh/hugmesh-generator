"""Boot from a save (FG5) — the facade/manifest half, hermetically.

A go-live flipped inside an emulated mesh lasts only while its devices run: a
restart boots the golden image INTERNAL again. Saving the mesh and booting it back
from the saves is how the posture survives. The shell half (launchers, runner,
entrypoint) is pinned by tests/qemu/save_test.sh; this file pins what the Studio
authors and reads:

* the mesh save manifest records which build each saved device ran from, so a
  resume never guesses the newest session;
* ``load_save_set`` refuses every set the runner could not boot (incomplete, a
  missing disk/stick/key, mixed sessions) with the reason in words;
* ``plan_from_save`` narrows the plan to the saved rows and hands the runner one
  ``--boot-save LABEL=QCOW2`` per row — and a per-row Start keeps its own save;
* the device record's ``boot_save`` reaches ``Device`` and ``status --json``.

Nothing here starts docker, qemu or ssh.
"""
import json
import os
from types import SimpleNamespace

import pytest

from hugmesh_studio.core import emulation as em
from hugmesh_studio.core import emulation_save as es
from hugmesh_studio.core import qemu_devices as qd
from hugmesh_studio.core import qemu_tests as qt

EPOCH = "2026-11-09T00:00:00Z"
STAMP = "20261109T000000Z"
LABELS = ("rpi5/pki", "x86/backend", "x86/frontend")


@pytest.fixture
def gen_session(tmp_path):
    """A generator checkout with ONE 3-row build session."""
    gen = tmp_path / "gen"
    sess = gen / "out" / "sessions" / "20261109-000000-mesh00"
    sess.mkdir(parents=True)
    for name in ("hugmesh-rpi5-arm64-pki-test-20261108T235951Z.img.xz",
                 "hugmesh-x86-amd64-be-test-20261108T235952Z.img",
                 "hugmesh-x86-amd64-fe-test-20261108T235953Z.img"):
        (sess / name).write_bytes(b"\0")
    return str(gen), str(sess)


def _registry(work, sess_path, labels=LABELS, **overrides):
    """Live keep-alive records + run-dir KEYS payloads, as the entrypoint leaves them."""
    root = qd.devices_dir(work)
    os.makedirs(root, exist_ok=True)
    for label in labels:
        safe = qd.safe_label(label)
        run_dir = os.path.join(work, qd.RUNS_SUBDIR, safe)
        os.makedirs(os.path.join(run_dir, "keys"), exist_ok=True)
        for rel, body in (("keys/users.json", '{"users": [{"name": "tester"}]}'),
                          ("keys.img", "FAT32"), ("id_ed25519", "PRIVATE"),
                          ("id_ed25519.pub", "ssh-ed25519 AAAA")):
            with open(os.path.join(run_dir, rel), "w", encoding="utf-8") as fh:
                fh.write(body)
        rec = {"label": label, "platform": label.split("/")[0],
               "role": label.split("/")[1], "board": "",
               "container": "hugmesh-qemu-dev-" + safe, "ssh_host_port": 22301,
               "ssh_user": "tester", "ssh_key": os.path.join(run_dir, "id_ed25519"),
               "users": ["tester"], "qmp": os.path.join(run_dir, "qmp.sock"),
               "artifacts": sess_path, "image": f"{safe}-golden.img",
               "state": "running", "started_at": "2026-11-09T00:00:00Z"}
        rec.update(overrides.get(label, {}))
        with open(os.path.join(root, safe + ".json"), "w", encoding="utf-8") as fh:
            json.dump(rec, fh)


def _spy(fail=()):
    def run(argv):
        label = argv[argv.index("--save-device") + 1]
        if label in fail:
            return 1
        with open(argv[argv.index("--save-to") + 1], "wb") as fh:
            fh.write(b"QFI\xfb")
        return 0
    return run


def _roomy(path):
    return SimpleNamespace(total=1000 * es.GIB, used=0, free=1000 * es.GIB)


def _saved_set(gen, sess_path, work, fail=(), **overrides):
    """A REAL mesh save of the fabricated registry (the runner is the spy)."""
    _registry(work, sess_path, **overrides)
    return es.save_mesh(gen, None, work_dir=work, stamp=STAMP, run=_spy(fail),
                        disk_usage=_roomy)


# ── the manifest says where each disk came from ─────────────────────────────────

def test_manifest_records_each_devices_build_and_lineage(gen_session, tmp_path):
    gen, sess = gen_session
    work = str(tmp_path / "work")
    report = _saved_set(gen, sess, work,
                        **{"x86/backend": {"boot_save": "/w/saves/old/x86_backend.qcow2"}})
    rec = json.load(open(report.manifest_path, encoding="utf-8"))
    by = {d["label"]: d for d in rec["devices"]}
    assert set(by) == set(LABELS)
    for label in LABELS:
        assert by[label]["artifacts"] == sess
        assert by[label]["image"] == qd.safe_label(label) + "-golden.img"
    # a device that was itself resumed says from what — lineage, not a guess
    assert by["x86/backend"]["boot_save"] == "/w/saves/old/x86_backend.qcow2"
    assert by["rpi5/pki"]["boot_save"] == ""


# ── load_save_set: the refusals ─────────────────────────────────────────────────

def test_load_save_set_by_name_dir_or_manifest(gen_session, tmp_path):
    gen, sess = gen_session
    work = str(tmp_path / "work")
    report = _saved_set(gen, sess, work)
    for ref in (f"mesh-{STAMP}", report.session_dir, report.manifest_path):
        sset = es.load_save_set(work, ref)
        assert sset.session_dir == report.session_dir
        assert sset.artifacts == sess
        # the manifest's order = the order the mesh was saved in
        assert [lb for lb, _ in sset.disks] == [r.label for r in report.results]
        for label, disk in sset.disks:
            assert disk == os.path.join(report.session_dir, qd.save_basename(label))


def test_load_save_set_never_guesses(tmp_path):
    work = str(tmp_path / "work")
    os.makedirs(qd.saves_dir(work))
    with pytest.raises(es.SaveSetError, match="no save-set"):
        es.load_save_set(work, "mesh-typo")
    with pytest.raises(es.SaveSetError, match="no save-set named"):
        es.load_save_set(work, "")
    bare = tmp_path / "not-a-set"
    bare.mkdir()
    with pytest.raises(es.SaveSetError, match="has no mesh-save.json"):
        es.load_save_set(work, str(bare))


def test_an_incomplete_set_is_refused_by_name(gen_session, tmp_path):
    gen, sess = gen_session
    work = str(tmp_path / "work")
    report = _saved_set(gen, sess, work, fail=("x86/backend",))
    assert not report.ok
    with pytest.raises(es.SaveSetError, match=r"INCOMPLETE.*x86/backend"):
        es.load_save_set(work, report.session_dir)


@pytest.mark.parametrize("suffix", [".qcow2", ".keys.img", ".id_ed25519"])
def test_a_missing_disk_stick_or_key_is_refused(gen_session, tmp_path, suffix):
    gen, sess = gen_session
    work = str(tmp_path / "work")
    report = _saved_set(gen, sess, work)
    os.remove(os.path.join(report.session_dir, "x86_frontend" + suffix))
    with pytest.raises(es.SaveSetError, match=r"x86/frontend: missing .*x86_frontend"
                                              + suffix.replace(".", r"\.")):
        es.load_save_set(work, report.session_dir)


def test_devices_from_two_sessions_are_refused(gen_session, tmp_path):
    gen, sess = gen_session
    work = str(tmp_path / "work")
    report = _saved_set(gen, sess, work,
                        **{"x86/frontend": {"artifacts": "/elsewhere/session"}})
    with pytest.raises(es.SaveSetError, match="different build sessions"):
        es.load_save_set(work, report.session_dir)


# ── plan_from_save: the argv the runner gets ────────────────────────────────────

def test_plan_from_save_boots_every_saved_row_from_its_save(gen_session, tmp_path):
    gen, sess = gen_session
    work = str(tmp_path / "work")
    report = _saved_set(gen, sess, work)
    pl = em.plan_from_save(gen, f"mesh-{STAMP}", work_dir=work, epoch=EPOCH)

    assert pl.mode is em.EmulationMode.DEPLOY
    assert pl.session_path == sess            # the build the set was saved from
    assert pl.save_set == report.session_dir
    argv = em.run_argv(pl)
    assert "--keep-alive" in argv
    assert argv[argv.index("--artifacts") + 1] == sess
    pairs = [argv[i + 1] for i, a in enumerate(argv) if a == "--boot-save"]
    assert sorted(pairs) == sorted(
        f"{lb}={os.path.join(report.session_dir, qd.save_basename(lb))}"
        for lb in LABELS)
    # rows stay in BOOT order (pi first), and the saves ride along in that order
    assert [lb for lb, _ in pl.boot_saves] == pl.labels


def test_plan_from_save_narrows_to_the_saved_rows(gen_session, tmp_path):
    gen, sess = gen_session
    work = str(tmp_path / "work")
    _registry(work, sess, labels=("rpi5/pki", "x86/backend"))
    es.save_mesh(gen, None, work_dir=work, stamp=STAMP, run=_spy(),
                 disk_usage=_roomy)
    pl = em.plan_from_save(gen, f"mesh-{STAMP}", work_dir=work, epoch=EPOCH)
    # The runner boots ONLY the --boot-save rows; the plan must not claim x86/frontend.
    assert pl.labels == ["rpi5/pki", "x86/backend"]
    assert [lb for lb, _ in pl.boot_saves] == ["rpi5/pki", "x86/backend"]


def test_a_per_row_start_keeps_its_own_save(gen_session, tmp_path):
    gen, sess = gen_session
    work = str(tmp_path / "work")
    report = _saved_set(gen, sess, work)
    pl = em.plan_from_save(gen, f"mesh-{STAMP}", work_dir=work, epoch=EPOCH)
    argv = em.start_device_argv(pl, "x86/backend")
    assert argv[argv.index("--only-exact") + 1] == "x86/backend"
    assert [argv[i + 1] for i, a in enumerate(argv) if a == "--boot-save"] == [
        "x86/backend=" + os.path.join(report.session_dir, "x86_backend.qcow2")]
    # ...and a golden plan's Start carries none
    golden = em.plan(gen, sess, em.EmulationMode.DEPLOY, work_dir=work, epoch=EPOCH)
    assert "--boot-save" not in em.start_device_argv(golden, "x86/backend")
    assert "--boot-save" not in em.run_argv(golden)


def test_a_session_that_disagrees_with_the_set_is_refused(gen_session, tmp_path):
    gen, sess = gen_session
    other = os.path.join(gen, "out", "sessions", "20261110-000000-other0")
    os.makedirs(other)
    with open(os.path.join(other, "hugmesh-x86-amd64-be-test-20261110T000000Z.img"),
              "wb") as fh:
        fh.write(b"\0")
    work = str(tmp_path / "work")
    _saved_set(gen, sess, work)
    with pytest.raises(ValueError, match="kernel of the build it came from"):
        em.plan_from_save(gen, f"mesh-{STAMP}", session=other, work_dir=work)
    # naming the SAME session explicitly is fine
    assert em.plan_from_save(gen, f"mesh-{STAMP}", session=sess,
                             work_dir=work).session_path == sess


def test_an_old_manifest_without_artifacts_needs_the_session(gen_session, tmp_path):
    gen, sess = gen_session
    work = str(tmp_path / "work")
    report = _saved_set(gen, sess, work)
    rec = json.load(open(report.manifest_path, encoding="utf-8"))
    for d in rec["devices"]:
        d.pop("artifacts")
    with open(report.manifest_path, "w", encoding="utf-8") as fh:
        json.dump(rec, fh)
    with pytest.raises(ValueError, match="pass the session explicitly"):
        em.plan_from_save(gen, f"mesh-{STAMP}", work_dir=work)
    pl = em.plan_from_save(gen, f"mesh-{STAMP}", session=sess, work_dir=work)
    assert len(pl.boot_saves) == 3


def test_a_saved_row_the_session_lacks_is_refused(gen_session, tmp_path):
    gen, sess = gen_session
    work = str(tmp_path / "work")
    _registry(work, sess, labels=("rpi5/pki", "rpi5/backend"))
    es.save_mesh(gen, None, work_dir=work, stamp=STAMP, run=_spy(),
                 disk_usage=_roomy)
    with pytest.raises(ValueError, match=r"rpi5/backend.*no image"):
        em.plan_from_save(gen, f"mesh-{STAMP}", work_dir=work)


def test_runner_command_spells_boot_saves_and_defaults_to_none():
    assert "--boot-save" not in qt.runner_command("/g", qt.QemuRunOptions())
    argv = qt.runner_command("/g", qt.QemuRunOptions(
        boot_saves=(("rpi5/pki", "/w/saves/s/rpi5_pki.qcow2"),
                    ("x86/backend", "/w/saves/s/x86_backend.qcow2"))))
    i = argv.index("--boot-save")
    assert argv[i:i + 4] == ["--boot-save", "rpi5/pki=/w/saves/s/rpi5_pki.qcow2",
                             "--boot-save", "x86/backend=/w/saves/s/x86_backend.qcow2"]


# ── the record half: Device, status, CLI ────────────────────────────────────────

def test_device_record_boot_save_is_read_tolerantly():
    old = qd.device_from_record({"label": "x86/backend", "state": "running"})
    assert old.boot_save == "" and not old.resumed_from_save
    new = qd.device_from_record({"label": "x86/backend", "state": "running",
                                 "boot_save": "/w/saves/s/x86_backend.qcow2"})
    assert new.boot_save == "/w/saves/s/x86_backend.qcow2" and new.resumed_from_save


def test_status_json_carries_the_save_a_device_resumed_from(gen_session, tmp_path,
                                                            monkeypatch):
    gen, sess = gen_session
    work = str(tmp_path / "work")
    _registry(work, sess, **{"x86/backend": {"boot_save": "/w/saves/s/x86_backend.qcow2"}})
    monkeypatch.setattr(em, "_runner_devices", lambda g, w: None)
    monkeypatch.setattr(em, "_docker_running_names",
                        lambda: {"hugmesh-qemu-dev-" + qd.safe_label(lb)
                                 for lb in LABELS})
    pl = em.plan(gen, sess, em.EmulationMode.DEPLOY, work_dir=work, epoch="")
    rows = {r["label"]: r for r in em.status_as_dict(em.status(pl))["rows"]}
    assert rows["x86/backend"]["boot_save"] == "/w/saves/s/x86_backend.qcow2"
    assert rows["x86/frontend"]["boot_save"] == ""
    assert rows["x86/backend"]["started_at"] == "2026-11-09T00:00:00Z"


def test_cli_plan_from_save_previews_and_boots_nothing(gen_session, tmp_path,
                                                       monkeypatch, capsys):
    gen, sess = gen_session
    work = str(tmp_path / "work")
    report = _saved_set(gen, sess, work)
    monkeypatch.setattr(em, "spawn", lambda *a, **k: pytest.fail("plan spawned"))
    rc = em.main(["plan", "--generator-dir", gen, "--work", work,
                  "--from-save", f"mesh-{STAMP}", "--json"])
    assert rc == 0
    out = json.loads(capsys.readouterr().out)
    assert out["save_set"] == report.session_dir
    assert {d["label"]: d["boot_save"] for d in out["devices"]} == {
        lb: os.path.join(report.session_dir, qd.save_basename(lb)) for lb in LABELS}
    assert out["argv"].count("--boot-save") == 3


def test_cli_up_from_save_spawns_the_boot_save_argv(gen_session, tmp_path,
                                                    monkeypatch, capsys):
    gen, sess = gen_session
    work = str(tmp_path / "work")
    _saved_set(gen, sess, work)
    spawned = []
    monkeypatch.setattr(em, "spawn", lambda argv, cwd, **k: spawned.append(argv) or 0)
    monkeypatch.setattr(em, "_runner_devices", lambda g, w: None)
    monkeypatch.setattr(em, "_docker_running_names", lambda: set())
    assert em.main(["up", "--generator-dir", gen, "--work", work,
                    "--from-save", f"mesh-{STAMP}"]) == 0
    assert len(spawned) == 1 and spawned[0].count("--boot-save") == 3
    assert "--keep-alive" in spawned[0]


def test_cli_from_save_refusals(gen_session, tmp_path, capsys):
    gen, sess = gen_session
    work = str(tmp_path / "work")
    assert em.main(["status", "--generator-dir", gen, "--work", work,
                    "--from-save", "mesh-x"]) == 2
    assert "plan and up only" in capsys.readouterr().err
    os.makedirs(qd.saves_dir(work))
    assert em.main(["up", "--generator-dir", gen, "--work", work,
                    "--from-save", "mesh-typo"]) == 1
    assert "REFUSED: no save-set" in capsys.readouterr().err


def test_a_set_saved_from_a_shared_l2_fleet_is_refused_by_name(gen_session, tmp_path):
    """The facade boots no --mesh-net, and each saved disk's mesh0 profile is bound
    to its mesh MAC — resumed here, the fleet would have no mesh NIC and a dead
    tailnet. Refuse, naming the runner invocation that brings the L2 back."""
    gen, sess = gen_session
    work = str(tmp_path / "work")
    report = _saved_set(gen, sess, work,
                        **{"rpi5/pki": {"mesh_net": "mcast=239.77.0.1:5000",
                                        "mesh_mac": "52:54:00:aa:bb:01",
                                        "mesh_ip": "10.77.0.10"}})
    rec = json.load(open(report.manifest_path, encoding="utf-8"))
    assert {d["label"]: d["mesh_net"] for d in rec["devices"]}["rpi5/pki"] \
        == "mcast=239.77.0.1:5000"
    with pytest.raises(ValueError, match=r"shared-L2 fleet \(rpi5/pki ran with "
                                         r"--mesh-net\).*--identities FILE"):
        em.plan_from_save(gen, f"mesh-{STAMP}", work_dir=work)

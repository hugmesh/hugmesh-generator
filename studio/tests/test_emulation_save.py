"""Hermetic tests for core/emulation_save.py — the whole-mesh save orchestrator.

Nothing here starts docker, qemu or ssh: the single-device saver is a SPY injected
through the module's process override point (``run=``), free space comes through the injected
``disk_usage``, and the device registry — when a test needs one — is fabricated in
tmp_path exactly the way docker-entrypoint.sh writes it. What is asserted is the
orchestration itself, the parts that would otherwise only be discovered in front of
an operator with a paused fleet:

* devices are saved in the CALLER'S order, into ONE save-set dir, under names that
  pair each file with its device;
* the disk preflight refuses the WHOLE save, by named shortfall, before the spy is
  ever called;
* one device's failure never touches another device's save;
* the KEYS stick is COPIED BACK (the run's exact payload), never regenerated, and
  its absence is a warning on a still-successful disk save.
"""
import json
import os
import stat
from types import SimpleNamespace

import pytest

from hugmesh_studio.core import emulation_save as es
from hugmesh_studio.core import qemu_devices as qd

GEN = "/gen"
STAMP = "20260819T000000Z"


def _dev(label="rpi5/pki", **overrides):
    fields = {
        "label": label, "platform": label.split("/")[0],
        "role": label.split("/")[-1], "board": "",
        "container": "hugmesh-qemu-" + qd.safe_label(label) + "-4242",
        "ssh_host_port": 22301, "ssh_user": "tester", "ssh_key": "",
        "users": ["tester"],
        "qmp": "/host/runs/" + qd.safe_label(label) + "/qmp.sock",
        "state": "running", "started_at": "2026-08-19T00:00:00Z",
    }
    fields.update(overrides)
    return qd.Device(**fields)


def _write_record(work, label, **overrides):
    """One registry record, shaped exactly like docker-entrypoint.sh's."""
    root = qd.devices_dir(str(work))
    os.makedirs(root, exist_ok=True)
    record = {
        "label": label, "platform": label.split("/")[0],
        "role": label.split("/")[-1], "board": "",
        "container": "hugmesh-qemu-" + qd.safe_label(label) + "-4242",
        "ssh_host_port": 22301, "ssh_user": "tester",
        "ssh_key": "", "users": ["tester"],
        "qmp": "/host/runs/" + qd.safe_label(label) + "/qmp.sock",
        "state": "running", "started_at": "2026-08-19T00:00:00Z",
    }
    record.update(overrides)
    path = os.path.join(root, qd.safe_label(label) + ".json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(record, fh)


def _roomy(path):
    return SimpleNamespace(total=1000 * es.GIB, used=0, free=1000 * es.GIB)


def _tight(free_bytes):
    return lambda path: SimpleNamespace(total=1000 * es.GIB, used=0,
                                        free=free_bytes)


class RunnerSpy:
    """The mocked single-device saver: records argv, fabricates the target file
    the way a successful runner would, fails on demand per label."""

    def __init__(self, fail_labels=()):
        self.calls = []
        self.fail = set(fail_labels)

    def labels(self):
        return [argv[argv.index("--save-device") + 1] for argv in self.calls]

    def __call__(self, argv):
        self.calls.append(list(argv))
        label = argv[argv.index("--save-device") + 1]
        target = argv[argv.index("--save-to") + 1]
        if label in self.fail:
            return 1
        with open(target, "wb") as fh:      # parent dir must already exist:
            fh.write(b"QFI\xfb")            # the runner does not mkdir it
        return 0


def _save(tmp_path, devices, spy=None, **kwargs):
    work = str(tmp_path / "work")
    os.makedirs(work, exist_ok=True)
    spy = spy or RunnerSpy()
    kwargs.setdefault("disk_usage", _roomy)
    report = es.save_mesh(GEN, devices, work_dir=work, stamp=STAMP,
                          run=spy, **kwargs)
    return report, spy, work


# ── order, naming, isolation ─────────────────────────────────────────────────────

def test_saves_every_device_in_caller_order_under_one_session_dir(tmp_path):
    devs = [_dev("rpi5/pki"), _dev("x86/omnibus"), _dev("rpi5/worker")]
    report, spy, work = _save(tmp_path, devs)

    assert spy.labels() == ["rpi5/pki", "x86/omnibus", "rpi5/worker"]
    sdir = os.path.join(work, "saves", f"mesh-{STAMP}")
    assert report.session_dir == sdir
    assert [r.target for r in report.results] == [
        os.path.join(sdir, "rpi5_pki.qcow2"),
        os.path.join(sdir, "x86_omnibus.qcow2"),
        os.path.join(sdir, "rpi5_worker.qcow2"),
    ]
    assert report.ok
    for r in report.results:
        assert os.path.isfile(r.target)
    # Each save went through the LANDED primitive: the runner script, addressed
    # by label, told about the overridden work dir.
    for argv in spy.calls:
        assert argv[0] == os.path.join(GEN, qd.RUNNER_SCRIPT)
        assert argv[1:3] == ["--work", work]
        assert "--overwrite" not in argv


def test_one_failed_device_does_not_corrupt_the_others(tmp_path):
    devs = [_dev("rpi5/pki"), _dev("x86/omnibus"), _dev("rpi5/worker")]
    report, spy, _ = _save(tmp_path, devs, spy=RunnerSpy(fail_labels={"x86/omnibus"}))

    assert spy.labels() == ["rpi5/pki", "x86/omnibus", "rpi5/worker"]  # carried on
    by_label = {r.label: r for r in report.results}
    assert by_label["rpi5/pki"].ok and by_label["rpi5/worker"].ok
    failed = by_label["x86/omnibus"]
    assert not failed.ok
    assert "exited 1" in failed.error and ".partial" in failed.error
    assert not os.path.exists(failed.target)          # nothing fabricated for it
    assert os.path.isfile(by_label["rpi5/pki"].target)
    assert not report.ok
    # The manifest still exists and tells the truth about the half-saved set.
    manifest = json.load(open(report.manifest_path, encoding="utf-8"))
    assert manifest["ok"] is False
    assert {d["label"]: d["ok"] for d in manifest["devices"]} == {
        "rpi5/pki": True, "x86/omnibus": False, "rpi5/worker": True}


def test_blocked_device_costs_a_row_never_a_runner_call(tmp_path):
    devs = [_dev("rpi5/pki"), _dev("rpi5/worker", state="stopped")]
    report, spy, _ = _save(tmp_path, devs)

    assert spy.labels() == ["rpi5/pki"]
    blocked = {r.label: r for r in report.results}["rpi5/worker"]
    assert not blocked.ok and blocked.error == qd.save_blocker(devs[1])
    assert not report.ok


# ── disk preflight ───────────────────────────────────────────────────────────────

def test_preflight_refuses_the_whole_save_naming_the_shortfall(tmp_path):
    devs = [_dev("rpi5/pki"), _dev("rpi5/worker")]     # 2 x 16 GiB budget
    spy = RunnerSpy()
    work = str(tmp_path / "work")
    os.makedirs(work)
    with pytest.raises(es.MeshSaveError) as err:
        es.save_mesh(GEN, devs, work_dir=work, stamp=STAMP, run=spy,
                     disk_usage=_tight(10 * es.GIB))
    msg = str(err.value)
    assert "32.0 GiB" in msg and "10.0 GiB" in msg and "22.0 GiB" in msg
    assert "short" in msg
    assert spy.calls == []                             # nothing was paused
    assert not os.path.exists(os.path.join(work, "saves"))   # nothing created


def test_budget_is_the_full_virtual_size_per_platform(tmp_path):
    assert es.device_budget_bytes(_dev("rpi5/pki")) == 16 * es.GIB
    assert es.device_budget_bytes(_dev("x86/omnibus")) == 32 * es.GIB
    # 20 GiB free: fits one Pi save, refuses one x86 save.
    work = str(tmp_path / "work")
    os.makedirs(work)
    assert es.preflight_refusal([_dev("rpi5/pki")], work,
                                disk_usage=_tight(20 * es.GIB)) == ""
    assert "short" in es.preflight_refusal([_dev("x86/omnibus")], work,
                                           disk_usage=_tight(20 * es.GIB))


def test_unknowable_free_space_defers_to_the_runners_own_check(tmp_path):
    def _broken(path):
        raise OSError("statvfs failed")
    report, spy, _ = _save(tmp_path, [_dev()], disk_usage=_broken)
    assert spy.labels() == ["rpi5/pki"] and report.ok


# ── the KEYS sticks: copy-back, not regenerate ───────────────────────────────────

def _fabricate_keys(work, label):
    """The run-dir payload exactly as docker-entrypoint.sh leaves it."""
    run_dir = os.path.join(work, qd.RUNS_SUBDIR, qd.safe_label(label))
    os.makedirs(os.path.join(run_dir, "keys", "ssh"), exist_ok=True)
    for rel, content in (("keys/users.json", '{"users": []}'),
                         ("keys/provision.json", '{"version": 1}'),
                         ("keys/ssh/marker", "x"),
                         ("keys.img", "FAT32"),
                         ("id_ed25519", "PRIVATE"),
                         ("id_ed25519.pub", "ssh-ed25519 AAAA")):
        with open(os.path.join(run_dir, rel), "w", encoding="utf-8") as fh:
            fh.write(content)
    return run_dir


def test_keys_stick_is_copied_back_beside_the_disk(tmp_path):
    work = str(tmp_path / "work")
    run_dir = _fabricate_keys(work, "rpi5/pki")
    dev = _dev("rpi5/pki", ssh_key=os.path.join(run_dir, "id_ed25519"))
    report, _, _ = _save(tmp_path, [dev])

    sdir = report.session_dir
    res = report.results[0]
    assert res.ok and res.keys_error == ""
    # The EXACT payload the device provisioned from, under names that pair it
    # with the disk save — never a regenerated one.
    assert open(os.path.join(sdir, "rpi5_pki.keys", "users.json"),
                encoding="utf-8").read() == '{"users": []}'
    assert os.path.isfile(os.path.join(sdir, "rpi5_pki.keys", "ssh", "marker"))
    assert open(os.path.join(sdir, "rpi5_pki.keys.img"),
                encoding="utf-8").read() == "FAT32"
    key_copy = os.path.join(sdir, "rpi5_pki.id_ed25519")
    assert open(key_copy, encoding="utf-8").read() == "PRIVATE"
    assert stat.S_IMODE(os.stat(key_copy).st_mode) == 0o600  # ssh accepts it
    assert os.path.isfile(key_copy + ".pub")
    assert set(res.keys_copied) == {
        os.path.join(sdir, "rpi5_pki.keys"),
        os.path.join(sdir, "rpi5_pki.keys.img"),
        key_copy, key_copy + ".pub"}


def test_missing_keys_payload_is_a_warning_not_a_failed_save(tmp_path):
    report, _, _ = _save(tmp_path, [_dev("rpi5/pki")])   # no run dir at all
    res = report.results[0]
    assert res.ok                                         # the disk save stands
    assert "no KEYS payload" in res.keys_error
    assert res.keys_copied == []
    manifest = json.load(open(report.manifest_path, encoding="utf-8"))
    assert manifest["keys_method"] == "copy-back"
    assert "no KEYS payload" in manifest["devices"][0]["keys_error"]


# ── duck-typed input (the mesh_emulation planner override point) ───────────────────────────

def test_items_may_be_labels_dicts_or_planner_rows(tmp_path):
    work = str(tmp_path / "work")
    for label in ("rpi5/pki", "x86/omnibus", "rpi5/worker"):
        _write_record(work, label)
    items = ["rpi5/pki",                                   # bare label
             {"label": "x86/omnibus"},                     # registry-shaped dict
             SimpleNamespace(label="rpi5/worker")]         # planner row
    spy = RunnerSpy()
    report = es.save_mesh(GEN, items, work_dir=work, stamp=STAMP, run=spy,
                          disk_usage=_roomy)
    assert spy.labels() == ["rpi5/pki", "x86/omnibus", "rpi5/worker"]
    assert report.ok


def test_duplicate_labels_fold_to_one_save(tmp_path):
    report, spy, _ = _save(tmp_path, [_dev("rpi5/pki"), "rpi5/pki",
                                      {"label": "rpi5/pki"}, _dev("rpi5/pki")])
    assert spy.labels() == ["rpi5/pki"]      # one device, one save
    assert len(report.results) == 1


def test_registry_liveness_wins_over_a_stale_planner_row(tmp_path):
    work = str(tmp_path / "work")
    _write_record(work, "rpi5/pki", state="stopped")       # the runner's truth
    stale = _dev("rpi5/pki", state="running")              # the planner's memory
    spy = RunnerSpy()
    report = es.save_mesh(GEN, [stale], work_dir=work, stamp=STAMP, run=spy,
                          disk_usage=_roomy)
    assert spy.calls == []                                 # never paused
    assert "not running" in report.results[0].error


def test_unresolvable_row_is_reported_not_dropped(tmp_path):
    report, spy, _ = _save(tmp_path, [_dev("rpi5/pki"),
                                      SimpleNamespace(label="x86/omnibus")])
    assert spy.labels() == ["rpi5/pki"]
    ghost = {r.label: r for r in report.results}["x86/omnibus"]
    assert not ghost.ok and "no record in the live device registry" in ghost.error
    assert not report.ok                                   # "everything" wasn't saved


# ── CLI ──────────────────────────────────────────────────────────────────────────

def test_cli_save_discovers_the_registry_and_exits_zero(tmp_path, monkeypatch, capsys):
    work = str(tmp_path / "work")
    for label in ("rpi5/pki", "rpi5/worker"):
        _write_record(work, label)
    spy = RunnerSpy()
    monkeypatch.setattr(es, "_run_argv", spy)
    monkeypatch.setattr(es, "_disk_usage", _roomy)
    rc = es.main(["save", "--generator-dir", GEN, "--work", work,
                  "--session", "mesh-cli-test"])
    assert rc == 0
    assert sorted(spy.labels()) == ["rpi5/pki", "rpi5/worker"]
    sdir = os.path.join(work, "saves", "mesh-cli-test")
    assert os.path.isfile(os.path.join(sdir, "rpi5_pki.qcow2"))
    assert os.path.isfile(os.path.join(sdir, es.MANIFEST_NAME))
    assert "saved rpi5/pki" in capsys.readouterr().out


def test_cli_only_filters_like_the_runner(tmp_path, monkeypatch):
    work = str(tmp_path / "work")
    for label in ("rpi5/pki", "x86/omnibus"):
        _write_record(work, label)
    spy = RunnerSpy()
    monkeypatch.setattr(es, "_run_argv", spy)
    monkeypatch.setattr(es, "_disk_usage", _roomy)
    rc = es.main(["save", "--generator-dir", GEN, "--work", work,
                  "--only", "rpi5"])
    assert rc == 0 and spy.labels() == ["rpi5/pki"]


def test_cli_save_refuses_on_preflight_and_names_the_shortfall(tmp_path, monkeypatch,
                                                               capsys):
    work = str(tmp_path / "work")
    _write_record(work, "rpi5/pki")
    spy = RunnerSpy()
    monkeypatch.setattr(es, "_run_argv", spy)
    monkeypatch.setattr(es, "_disk_usage", _tight(1 * es.GIB))
    rc = es.main(["save", "--generator-dir", GEN, "--work", work])
    assert rc == 1 and spy.calls == []
    err = capsys.readouterr().err
    assert "REFUSED" in err and "short" in err


def test_cli_plan_is_pure_and_previews_the_set(tmp_path, monkeypatch, capsys):
    work = str(tmp_path / "work")
    _write_record(work, "rpi5/pki")
    spy = RunnerSpy()
    monkeypatch.setattr(es, "_run_argv", spy)
    monkeypatch.setattr(es, "_disk_usage", _roomy)
    rc = es.main(["plan", "--generator-dir", GEN, "--work", work,
                  "--session", "mesh-plan-test"])
    assert rc == 0 and spy.calls == []                     # previewed, ran nothing
    out = capsys.readouterr().out
    assert "mesh-plan-test" in out and "rpi5/pki" in out
    assert "--save-device" in out                          # the argv is shown
    assert not os.path.exists(os.path.join(work, "saves"))  # nothing created


def test_cli_plan_exits_nonzero_when_nothing_is_saveable(tmp_path, monkeypatch,
                                                         capsys):
    work = str(tmp_path / "work")
    os.makedirs(work)
    monkeypatch.setattr(es, "_disk_usage", _roomy)
    rc = es.main(["plan", "--generator-dir", GEN, "--work", work])
    assert rc == 1
    assert "nothing is saveable" in capsys.readouterr().err

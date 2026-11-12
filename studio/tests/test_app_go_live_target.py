"""``hugmesh-studio --go-live-target …`` — the Studio's headless go-live CLI, and
``--go-live --go-live-target LABEL``, the wizard opened on a device.

The CLI is ``core.golive_target``'s own (targets|probe|status|list|plan|commit|
rollback); app.py only dispatches the rest of the line to it BEFORE any Qt import, the
way ``--qemu-windows`` does, so hugmesh-studio-cli(.exe) and a display-less Linux box
reach it. Each case runs the real entry point in a child process against a fake
device (a fake ``ssh`` first on PATH — tests/_golive_fake_guest), and asserts no Qt
binding was imported.
"""
import os
import subprocess
import sys

import _golive_fake_guest as fake

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

_RUN = ("import sys; from hugmesh_studio import app; rc = app.main(sys.argv[1:]); "
        "qt = sorted(m for m in sys.modules if m.split('.')[0] in "
        "('PyQt6', 'PySide6', 'PyQt5', 'PySide2')); "
        "print('QT-MODULES:', qt, file=sys.stderr); sys.exit(rc)")


def _studio(*args, env=None):
    return subprocess.run([sys.executable, "-c", _RUN, *args], cwd=STUDIO_ROOT,
                          env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, timeout=120)


def _env(tmp_path, monkeypatch):
    guest = fake.install(tmp_path, monkeypatch)
    fake.register(guest, label="rpi5/pki")
    env = dict(os.environ)
    env["PYTHONPATH"] = STUDIO_ROOT + os.pathsep + env.get("PYTHONPATH", "")
    env["HUGMESH_STUDIO_STATE_DIR"] = str(tmp_path / "state")
    return guest, env


def test_targets_and_status_run_headless_with_no_qt(tmp_path, monkeypatch):
    guest, env = _env(tmp_path, monkeypatch)
    r = _studio("--go-live-target", "targets", "--work", guest.work_dir, env=env)
    assert r.returncode == 0, r.stderr
    assert "rpi5/pki" in r.stdout and "emulated-docker" in r.stdout
    assert "QT-MODULES: []" in r.stderr
    r = _studio("--go-live-target", "status", "--target", "rpi5/pki", "--work",
                guest.work_dir, env=env)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "effective posture:   internal" in r.stdout
    # the posture read from the device (both witnesses), never inferred
    assert "): INTERNAL — both witnesses say internal (hugmesh-go-live status; nft" in r.stdout
    assert "QT-MODULES: []" in r.stderr
    assert any(c[-1] == "sudo -n hugmesh-go-live status" for c in guest.calls())
    assert any("@@nftrc" in c[-1] for c in guest.calls())


def test_status_after_a_boot_from_a_save_taken_while_public(tmp_path, monkeypatch):
    """The live defect, headless: a device booted from a save taken while PUBLIC, with
    this host's commit journalled during the EARLIER boot. Status prints what the
    device says (public, both witnesses), the save and the posture it was taken in, and
    the journal's WHEN — no 'reset by a restart', no INTERNAL."""
    import json
    from hugmesh_studio.core import golive_target
    guest, env = _env(tmp_path, monkeypatch)
    sdir = tmp_path / "work" / "saves" / "mesh-20261111T152704Z"
    sdir.mkdir(parents=True)
    disk = sdir / "rpi5_pki.qcow2"
    disk.write_text("qcow2")
    saved = golive_target.Posture(status="public", nft="public", reachable=True,
                                  at="2026-11-11T15:30:20Z").as_record()
    (sdir / "mesh-save.json").write_text(json.dumps({
        "session": "mesh-20261111T152704Z", "created_at": "2026-11-11T15:30:29Z",
        "devices": [{"label": "rpi5/pki", "target": str(disk), "ok": True,
                     "golive_posture": saved}]}))
    first = fake.register(guest, label="rpi5/pki", started_at="2026-11-11T15:11:59Z")
    golive_target.write_journal(golive_target.target_from_device(first, guest.work_dir),
                                "commit", "byo-domain", "example.invalid", rc=0,
                                now="2026-11-11T15:26:38Z")
    fake.register(guest, label="rpi5/pki", started_at="2026-11-11T15:31:13Z",
                  boot_save=str(disk))
    fake.set_public(guest)                       # the saved disk carried the marker
    r = _studio("--go-live-target", "status", "--target", "rpi5/pki", "--work",
                guest.work_dir, env=env)
    assert r.returncode == 0, r.stdout + r.stderr
    out = r.stdout
    assert "effective posture:   public" in out
    assert "): PUBLIC — both witnesses say public (hugmesh-go-live status; nft table" in out
    assert ("booted from a save taken while PUBLIC (mesh-20261111T152704Z, saved "
            "2026-11-11T15:30:29Z)") in out
    assert ("last commit from this host: byo-domain example.invalid at "
            "2026-11-11T15:26:38Z — during an earlier boot (the device booted again at "
            "2026-11-11T15:31:13Z)") in out
    assert "INTERNAL" not in out and "reset by a restart" not in out
    # unreachable now: unknown, never a guess; the save and the journal still said
    env["FAKE_GUEST_DOWN"] = "1"
    r = _studio("--go-live-target", "status", "--target", "rpi5/pki", "--work",
                guest.work_dir, env=env)
    assert r.returncode == 2
    assert ": unknown (device not reachable) — " in r.stdout
    assert "booted from a save taken while PUBLIC" in r.stdout
    assert "INTERNAL" not in r.stdout


def test_plan_runs_inside_the_device(tmp_path, monkeypatch):
    guest, env = _env(tmp_path, monkeypatch)
    r = _studio("--go-live-target", "plan", "--target", "rpi5/pki", "--work",
                guest.work_dir, "--provider", "byo-domain", "--domain", "example.invalid",
                "--ingress-ip", "203.0.113.10", env=env)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "==> Plan summary ready" in r.stdout
    assert "copied 2 plan artifact(s)" in r.stdout
    assert "QT-MODULES: []" in r.stderr


def test_commit_refuses_without_a_terminal_and_never_adds_yes(tmp_path, monkeypatch):
    guest, env = _env(tmp_path, monkeypatch)
    r = _studio("--go-live-target", "commit", "--target", "rpi5/pki", "--work",
                guest.work_dir, "--provider", "byo-domain", "--domain", "example.invalid",
                env=env)
    assert r.returncode == 2
    assert "needs a terminal" in r.stdout
    assert not any("commit" in c[-1] for c in guest.calls())


def test_go_live_with_an_empty_target_is_refused_before_any_window(tmp_path, monkeypatch):
    _guest, env = _env(tmp_path, monkeypatch)
    r = _studio("--go-live", "--go-live-target", env=env)
    assert r.returncode == 2
    assert "needs a device LABEL" in r.stderr
    assert "QT-MODULES: []" in r.stderr


def test_the_wizard_label_is_read_from_either_spelling():
    from hugmesh_studio.app import go_live_target_label
    assert go_live_target_label(["rpi5/pki"]) == "rpi5/pki"
    assert go_live_target_label(["--target", "x86/fe"]) == "x86/fe"
    assert go_live_target_label(["--target=x86/fe"]) == "x86/fe"
    assert go_live_target_label(["--work", "w", "--target", "rpi5/be"]) == "rpi5/be"
    assert go_live_target_label([]) == ""
    assert go_live_target_label(["--target"]) == ""

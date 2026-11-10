"""Sessions in ANY output folder: the per-user session-root registry (core/session_locations.py).

THE REPORTED DEFECT (operator, 2026-11-09): "when someone chooses another output folder
the sessions don't appear", and "when a session is output somewhere else, I can't run
it through qemu emulation to test it".

Reproduced on the operator's workstation before the fix: session
``20261108-213119-c18ff4`` was COMPLETE, held three rpi5 images, and lived in
a folder outside the checkout (``~/<another-mesh>/out/sessions``). ``qemu_tests.discover_sessions`` returned only the
one session under ``<generator>/out/sessions``; ``emulation._as_session(gen, id)``
raised "no such build session"; ``run-qemu-docker.sh`` with no ``--artifacts`` said
"no build session under out/sessions/". The Sessions page listed it (it reads the
records), so the session was visible and unbootable at once.

Every test here builds that shape: an EMPTY ``<generator>/out/sessions`` and a session
with real (stamped, non-empty) images in a folder somewhere else, which no live config
names. Whatever finds it can only have found it through the registry or the records.
"""
from __future__ import annotations

import json
import os
import shlex
import shutil
import stat
import subprocess
import sys
import textwrap

import pytest

from hugmesh_studio.core import (build_sessions, emulation, qemu_devices, qemu_tests,
                                 session_locations as sl)
from hugmesh_studio.core.config import ImageConfig
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
RUNNER = os.path.join(GENERATOR_DIR, qemu_tests.RUNNER_SCRIPT)

IMAGES = ("acme-rpi5-arm64-backend-prod-20261109T072422Z.img.xz",
          "acme-rpi5-arm64-frontend-prod-20261109T080602Z.img.xz",
          "acme-rpi5-arm64-pki-prod-20261109T053553Z.img.xz")
SECRET = "hunter2-must-never-reach-the-registry"


@pytest.fixture(autouse=True)
def _state(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture
def gen(tmp_path):
    """A generator checkout whose default sessions folder EXISTS and is EMPTY."""
    g = tmp_path / "gen"
    (g / "out" / "sessions").mkdir(parents=True)
    return g


def _dispatch_into(out_dir, *, local_pass=SECRET):
    """A Studio build dispatched into ``out_dir`` — the real record path
    (new_session + start), with a secret set — then the builder's images."""
    base = ImageConfig(mode="mesh", output_dir=str(out_dir), local_pass=local_pass)
    wl = WorklistConfig(base=base, entries=[
        WorklistEntry(role=r, platform="rpi5") for r in ("backend", "frontend", "pki")])
    rec = build_sessions.new_session(wl, "/nonexistent-generator")
    build_sessions.start(rec)
    os.makedirs(rec.workdir, exist_ok=True)
    for name in IMAGES:
        with open(os.path.join(rec.workdir, name), "wb") as fh:
            fh.write(b"\0")
    return rec


# ── the registry itself ──────────────────────────────────────────────────────────────
def test_dispatch_records_the_output_folder_under_the_state_dir(tmp_path):
    out = tmp_path / "elsewhere" / "out"
    rec = _dispatch_into(out)
    assert rec.workdir == os.path.join(str(out), "sessions", rec.id)
    reg = sl.registry_dir()
    assert reg == os.path.join(str(tmp_path / "state"), "session-roots")
    assert sl.registered_roots() == [str(out)]


def test_registry_holds_paths_only_never_a_secret_and_is_private(tmp_path):
    _dispatch_into(tmp_path / "custom" / "out")
    reg = sl.registry_dir()
    entries = os.listdir(reg)
    assert len(entries) == 1 and entries[0].endswith(".json")
    path = os.path.join(reg, entries[0])
    raw = open(path, encoding="utf-8").read()
    assert SECRET not in raw
    assert set(json.loads(raw)) == {"root", "recorded"}
    if os.name != "nt":
        assert stat.S_IMODE(os.stat(path).st_mode) == 0o600


def test_a_custom_folder_session_is_found_after_a_restart_by_the_registry_alone(gen, tmp_path):
    """A fresh process knows nothing but what is on disk. Delete the session RECORD
    too, so only the registry entry can be what found it."""
    out = tmp_path / "custom" / "out"
    rec = _dispatch_into(out)
    os.unlink(rec.path())
    sessions = qemu_tests.discover_sessions(str(gen))
    assert [s.path for s in sessions] == [rec.workdir]
    assert sessions[0].location == str(out)
    assert [r.label for r in sessions[0].rows] == ["rpi5/backend", "rpi5/frontend",
                                                   "rpi5/pki"]


def test_a_session_recorded_before_the_registry_existed_is_found_from_its_record(gen, tmp_path):
    """The migration path: the operator's existing records carry ``workdir`` and
    there is no registry yet. Only the record can be what found it."""
    out = tmp_path / "custom" / "out"
    rec = _dispatch_into(out)
    shutil.rmtree(sl.registry_dir())
    assert sl.registered_roots() == []
    assert qemu_tests.default_session(str(gen)).path == rec.workdir


def test_the_live_config_folder_is_searched_before_any_build_recorded_it(gen, tmp_path):
    out = tmp_path / "chosen-just-now"
    (out / "sessions" / "20261109-000000-aaaaaa").mkdir(parents=True)
    for name in IMAGES:
        (out / "sessions" / "20261109-000000-aaaaaa" / name).write_bytes(b"\0")
    assert qemu_tests.discover_sessions(str(gen)) == []
    found = qemu_tests.discover_sessions(str(gen), extra_roots=(str(out),))
    assert [s.name for s in found] == ["20261109-000000-aaaaaa"]


def test_the_same_folder_spelled_twice_is_listed_once(gen, tmp_path):
    out = tmp_path / "custom" / "out"
    _dispatch_into(out)
    spelled = str(out) + os.sep + "." + os.sep
    sessions = qemu_tests.discover_sessions(str(gen), extra_roots=(spelled, str(out)))
    assert len(sessions) == 1


# ── emulation: name resolution, the plan, the argv ───────────────────────────────────
def test_a_session_name_resolves_in_a_custom_folder_and_the_argv_points_there(gen, tmp_path):
    rec = _dispatch_into(tmp_path / "custom" / "out")
    sess = emulation._as_session(str(gen), rec.id)
    assert sess.path == rec.workdir
    for mode in (emulation.EmulationMode.TEST, emulation.EmulationMode.DEPLOY):
        plan = emulation.plan(str(gen), rec.id, mode)
        argv = emulation.run_argv(plan)
        i = argv.index("--artifacts")
        assert argv[i + 1] == rec.workdir, "artifacts must come from the registry, not out/"


def test_an_unknown_name_still_errors_and_says_where_it_looked(gen, tmp_path):
    _dispatch_into(tmp_path / "custom" / "out")
    with pytest.raises(ValueError) as exc:
        emulation._as_session(str(gen), "20990101-000000-nope00")
    assert "custom" in str(exc.value) and "searched" in str(exc.value)


@pytest.mark.parametrize("name", ["..", ".", "../out", "a/b", "a\\b", ""])
def test_a_name_lookup_cannot_walk_out_of_a_sessions_folder(gen, name):
    assert sl.find_session_dir(str(gen), name) == ""


def test_the_save_guard_protects_a_custom_folders_goldens(gen, tmp_path):
    rec = _dispatch_into(tmp_path / "custom" / "out")
    target = os.path.join(rec.workdir, "my-save.qcow2")
    why = qemu_devices.save_target_refusal(target, generator_dir=str(gen))
    assert "refusing to save into" in why and "custom" in why


# ── absence is not deletion: the registry is the durable location index ─────────────
# Round-1 refutation of PR #928 (BLOCKER 1): the registry used to drop an entry the
# moment its folder was absent, from every Sessions page refresh and every build
# dispatch. After a record-only delete ("delete the record, keep the images") the
# entry is the ONLY thing that still names the folder, so an external drive that
# happened to be unplugged during one refresh made its sessions unbootable for good:
# the images were back on disk, and discover_sessions / emulation._as_session could
# not see them. Nothing prunes on absence any more; an absent folder is just not
# LISTED (roots() filters it), and it is listed again the moment it returns.
def _finished(rec):
    """The build ended (an ACTIVE session refuses delete)."""
    rec.images = [dict(i, status="ok", exit_code=0) for i in rec.images]
    build_sessions.finish(rec, build_sessions.COMPLETE)
    return rec


def _unplug(drive):
    away = str(drive) + ".unplugged"
    os.rename(drive, away)
    return away


def test_a_record_only_delete_survives_a_drive_that_was_away(gen, tmp_path):
    """The refuter's five steps, verbatim in shape."""
    drive = tmp_path / "ExternalDrive"
    rec = _finished(_dispatch_into(drive / "out"))
    # 1. built into the drive: found
    assert [s.path for s in qemu_tests.discover_sessions(str(gen))] == [rec.workdir]
    # 2. "delete the record, keep the images": still found, through the registry
    assert build_sessions.delete(rec, remove_artifacts=False)
    assert not os.path.exists(rec.path())
    assert [s.path for s in qemu_tests.discover_sessions(str(gen))] == [rec.workdir]
    # 3. the drive is unplugged while both former prune triggers fire: another
    #    build is dispatched (record_root) and the Sessions page refreshes (roots)
    away = _unplug(drive)
    assert qemu_tests.discover_sessions(str(gen)) == []         # not listed, no error
    other = _dispatch_into(tmp_path / "other" / "out")
    sl.roots(str(gen))
    assert str(drive / "out") in sl.registered_roots(), \
        "an absent folder was forgotten: its sessions can never be found again"
    # 4. the drive comes back: the images are bootable again
    os.rename(away, drive)
    found = [s.path for s in qemu_tests.discover_sessions(str(gen))]
    assert rec.workdir in found and other.workdir in found
    # 5. ... including by bare name, the --session / WHPX path
    assert emulation._as_session(str(gen), rec.id).path == rec.workdir


def test_a_record_only_delete_registers_a_pre_registry_sessions_folder(gen, tmp_path):
    """A session dispatched before the registry existed is found only through its
    RECORD (roots derived from ``workdir``). Deleting that record while keeping the
    images must hand the folder to the registry first, or the images are orphaned
    the moment the record goes, drive present or not."""
    out = tmp_path / "legacy" / "out"
    rec = _finished(_dispatch_into(out))
    shutil.rmtree(sl.registry_dir())                 # as if recorded before #928
    assert sl.registered_roots() == []
    assert build_sessions.delete(rec, remove_artifacts=False)
    assert sl.registered_roots() == [str(out)]
    assert [s.path for s in qemu_tests.discover_sessions(str(gen))] == [rec.workdir]


def test_a_vanished_folder_stays_registered_and_its_record_survives(gen, tmp_path):
    out = tmp_path / "usb-stick" / "out"
    rec = _dispatch_into(out)
    shutil.rmtree(tmp_path / "usb-stick")
    assert str(out) not in sl.roots(str(gen))
    assert qemu_tests.discover_sessions(str(gen)) == []          # and nothing raised
    assert sl.registered_roots() == [str(out)], "absence must not forget a folder"
    assert os.path.isfile(rec.path()), "a session RECORD is build history: never pruned"


def test_recording_a_root_never_forgets_an_absent_one(tmp_path):
    away = tmp_path / "away" / "out"
    away.mkdir(parents=True)
    assert sl.record_root(str(away))
    shutil.rmtree(tmp_path / "away")
    keep = tmp_path / "keep" / "out"
    keep.mkdir(parents=True)
    assert sl.record_root(str(keep))
    assert sorted(sl.registered_roots()) == sorted([str(keep), str(away)])


def test_an_explicit_prune_still_forgets_absent_folders_and_only_those(tmp_path):
    """prune() survives as an EXPLICIT call (nothing in the Studio makes it on its
    own): it drops pointer files of absent folders and touches nothing else."""
    away = tmp_path / "away" / "out"
    keep = tmp_path / "keep" / "out"
    for d in (away, keep):
        d.mkdir(parents=True)
        assert sl.record_root(str(d))
    shutil.rmtree(tmp_path / "away")
    assert sl.prune() == [str(away)]
    assert sl.registered_roots() == [str(keep)]


def test_no_reader_or_writer_prunes_on_its_own():
    """Source pin for the two former automatic triggers: record_root (every build
    dispatch) and the Sessions page refresh. A prune there is exactly the defect."""
    import inspect
    assert "prune(" not in inspect.getsource(sl.record_root)
    assert "prune(" not in inspect.getsource(sl.roots)
    widget = os.path.join(STUDIO_ROOT, "hugmesh_studio", "gui", "pages",
                          "sessions_widget.py")
    with open(widget, encoding="utf-8") as fh:        # read, not imported: Qt-free file
        assert "session_locations.prune" not in fh.read()


# ── concurrent writers ───────────────────────────────────────────────────────────────
def test_concurrent_writers_lose_no_root(tmp_path):
    """Eight PROCESSES, each recording its own folder twenty times while the others
    do the same. One file per root and an atomic replace means there is no
    read-modify-write to lose: every root must be there, every entry must parse, and
    no temp file may be left behind."""
    roots = []
    for i in range(8):
        r = tmp_path / f"root{i}" / "out"
        r.mkdir(parents=True)
        roots.append(str(r))
    code = textwrap.dedent("""
        import sys
        sys.path.insert(0, sys.argv[1])
        from hugmesh_studio.core import session_locations as sl
        for _ in range(20):
            assert sl.record_root(sys.argv[2])
    """)
    procs = [subprocess.Popen([sys.executable, "-c", code, STUDIO_ROOT, r])
             for r in roots]
    assert [p.wait(timeout=120) for p in procs] == [0] * len(roots)
    assert sorted(sl.registered_roots()) == sorted(roots)
    names = os.listdir(sl.registry_dir())
    assert len(names) == len(roots) and all(n.endswith(".json") for n in names)
    for n in names:
        json.load(open(os.path.join(sl.registry_dir(), n), encoding="utf-8"))


# ── the shell runner (tests/qemu/run-qemu-docker.sh) ─────────────────────────────────
_RUNS_BASH = pytest.mark.skipif(
    os.name == "nt" or not shutil.which("bash") or not os.path.isfile(RUNNER),
    reason="runs the real bash runner (--list boots nothing)")


@pytest.fixture
def runner_ready():
    """``--list`` boots nothing, but the runner still preflights the docker daemon
    before it enumerates rows. Without one these tests could only measure that
    preflight, so they skip rather than fail."""
    if not shutil.which("docker"):
        pytest.skip("no docker CLI: the runner refuses before --list")
    try:
        ok = subprocess.run(["docker", "info"], capture_output=True,
                            timeout=30).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        ok = False
    if not ok:
        pytest.skip("docker daemon not reachable: the runner refuses before --list")


def _runner_list(work, *extra):
    env = dict(os.environ)
    return subprocess.run([RUNNER, "--list", "--work", str(work), *extra],
                          capture_output=True, text=True, env=env, timeout=120)


@_RUNS_BASH
def test_the_runner_resolves_a_bare_session_name_through_the_registry(tmp_path, runner_ready):
    rec = _dispatch_into(tmp_path / "custom" / "out")
    res = _runner_list(tmp_path / "work", "--session", rec.id)
    assert res.returncode == 0, res.stderr
    assert f"artifacts : {rec.workdir}" in res.stdout
    assert "3 row(s) runnable" in res.stdout


@_RUNS_BASH
def test_the_runners_default_is_the_newest_session_in_any_known_folder(tmp_path,
                                                                     runner_ready):
    rec = _dispatch_into(tmp_path / "custom" / "out")
    # Newer than anything a developer's own out/sessions can hold, so the default
    # pick is deterministic on a workstation as well as on CI.
    os.utime(rec.workdir, (4_000_000_000, 4_000_000_000))
    res = _runner_list(tmp_path / "work")
    assert res.returncode == 0, res.stderr
    assert f"artifacts : {rec.workdir}" in res.stdout


@_RUNS_BASH
def test_the_runner_names_the_folders_it_searched_for_an_unknown_name(tmp_path, runner_ready):
    _dispatch_into(tmp_path / "custom" / "out")
    res = _runner_list(tmp_path / "work", "--session", "20990101-000000-nope00")
    assert res.returncode != 0
    assert "in any known output folder" in res.stderr
    assert os.path.join(str(tmp_path / "custom" / "out"), "sessions") in res.stderr


def _runner_fn_output(repo_dir, call):
    """Run ONE shell function of the real runner (extracted, not the whole script:
    the script preflights docker before it resolves a session)."""
    text = open(RUNNER, encoding="utf-8").read()
    fns = []
    for name in ("session_dirs", "searched_text"):
        start = text.index(f"\n{name}() {{\n") + 1
        fns.append(text[start:text.index("\n}\n", start) + 3])
    script = "set -euo pipefail\n" + "".join(fns) + call + "\n"
    res = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                         env=dict(os.environ, REPO_DIR=str(repo_dir)), timeout=60)
    assert res.returncode == 0, res.stderr
    return res.stdout


@_RUNS_BASH
def test_the_runners_search_list_is_never_empty(tmp_path):
    """Round-1 note on PR #928: with no known output folder present the runner said
    "(searched: )". It must still say where it looked."""
    bare = tmp_path / "bare-gen"                     # no out/, no studio/ package
    bare.mkdir()
    said = _runner_fn_output(bare, "searched_text")
    assert said.strip(), "the runner says it searched nothing"
    assert os.path.join(str(bare), "out", "sessions") + " (absent)" in said


@_RUNS_BASH
def test_the_runners_search_list_names_a_registered_folder(tmp_path):
    rec = _dispatch_into(tmp_path / "custom" / "out")
    said = _runner_fn_output(GENERATOR_DIR, "searched_text")
    assert os.path.dirname(rec.workdir) in said.split(",")


def test_the_cli_prints_one_root_per_line(gen, tmp_path, capsys):
    out = tmp_path / "custom" / "out"
    _dispatch_into(out)
    assert sl.main(["roots", "--generator-dir", str(gen)]) == 0
    lines = capsys.readouterr().out.splitlines()
    assert lines == [os.path.join(str(gen), "out"), str(out)]
    assert sl.main(["find", "nope", "--generator-dir", str(gen)]) == 1


def test_the_sessions_folder_name_matches_build_sessions(tmp_path):
    assert os.path.basename(os.path.dirname(
        build_sessions.session_workdir(str(tmp_path), "x"))) == sl.SESSIONS_NAME


def test_runner_command_quotes_the_custom_path_as_the_preview_does(gen, tmp_path):
    rec = _dispatch_into(tmp_path / "custom dir with space" / "out")
    plan = emulation.plan(str(gen), rec.id, emulation.EmulationMode.TEST)
    argv = emulation.run_argv(plan)
    assert shlex.split(shlex.join(argv))[argv.index("--artifacts") + 1] == rec.workdir

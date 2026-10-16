"""core/emulation.py — the one Qt-free facade over the four emulation cores.

Hermetic: no docker, no qemu, no ssh. The facade composes the existing cores, so
these tests fabricate exactly what those cores read — a session dir of artifact
names, a device registry and result JSONs in the REAL formats the harness writes
(field-for-field copies of out/qemu-runs shapes, stamps included) — and
monkeypatch the two probe override points (`_runner_devices`, `_docker_running_names`)
that would otherwise shell out.

The cross-check block at the bottom greps the shell runner's own text (the same
technique test_qemu_tests uses for row-discovery parity), so a constant or flag
renamed on either side fails a test instead of silently drifting.
"""
import json
import os
import re
import sys

import pytest

from hugmesh_studio.core import emulation as em
from hugmesh_studio.core import emulation_save
from hugmesh_studio.core import mesh_emulation as me
from hugmesh_studio.core import qemu_devices as qd
from hugmesh_studio.core import qemu_tests as qt

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
RUNNER = os.path.join(GENERATOR_DIR, qt.RUNNER_SCRIPT)
AVC = os.path.join(GENERATOR_DIR, em.AVC_SCRIPT)

#: A deterministic plan epoch — every fixture stamp below is placed relative to
#: it, so the suite never depends on the wall clock.
EPOCH = "2026-08-19T11:00:00Z"


# ── fixtures: a 3-device session, registry records and results in REAL formats ──────

@pytest.fixture
def session(tmp_path):
    """A build session holding a 3-device mesh: rpi5/pki, x86/be, x86/fe."""
    gen = tmp_path / "gen"
    sess = gen / "out" / "sessions" / "20260819-101010-mesh00"
    sess.mkdir(parents=True)
    for name in ("hugmesh-rpi5-arm64-pki-test-20260819T095951Z.img.xz",
                 "hugmesh-x86-amd64-be-test-20260819T101010Z.img",
                 "hugmesh-x86-amd64-fe-test-20260819T101011Z.img"):
        (sess / name).write_bytes(b"\0")  # non-empty: a 0-byte .img is a killed build, not a row
    sessions = qt.discover_sessions(str(gen))
    assert len(sessions) == 1 and len(sessions[0].rows) == 3
    return str(gen), sessions[0]


@pytest.fixture
def test_plan(session):
    gen, sess = session
    return em.plan(gen, sess, em.EmulationMode.TEST, epoch=EPOCH)


@pytest.fixture
def deploy_plan(session):
    gen, sess = session
    return em.plan(gen, sess, em.EmulationMode.DEPLOY, epoch=EPOCH)


def _record(work, label, **overrides):
    """One device-registry record, field-for-field docker-entrypoint.sh's shape
    (the T1 contract: artifacts + image + a state:'booting' first record)."""
    safe = qd.safe_label(label)
    rec = {
        "label": label,
        "platform": label.split("/")[0],
        "role": label.split("/")[-1],
        "board": "",
        "container": f"hugmesh-qemu-dev-{safe}",
        "ssh_host_port": 22300,
        "ssh_user": "tester",
        "ssh_key": f"{work}/runs/{safe}/id_ed25519",
        "users": ["tester"],
        "qmp": f"{work}/runs/{safe}/launch/qmp.sock",
        "artifacts": "/host/out/sessions/20260819-101010-mesh00",
        "image": "hugmesh-rpi5-arm64-pki-test-20260819T095951Z.img",
        "state": "running",
        "started_at": "2026-08-19T12:00:00Z",
    }
    rec.update(overrides)
    return rec


def _write_record(work, label, **overrides):
    rec = _record(work, label, **overrides)
    root = qd.devices_dir(work)
    os.makedirs(root, exist_ok=True)
    with open(os.path.join(root, qd.safe_label(label) + ".json"), "w",
              encoding="utf-8") as fh:
        json.dump(rec, fh, indent=2)
    return rec


def _write_result(work, label, **overrides):
    """One per-row verdict, field-for-field docker-entrypoint.sh's result JSON."""
    res = {
        "label": label,
        "platform": label.split("/")[0],
        "board": "",
        "role": label.split("/")[-1],
        "mode": "golden",
        "status": "PASS",
        "detail": "all assertions passed",
        "assertions_passed": 33,
        "assertions_failed": 0,
        "image": "/work/images/hugmesh-rpi5-arm64-pki-test-20260819T095951Z.img",
        "started_at": "2026-08-19T12:00:00Z",
        "duration_s": 90,
    }
    res.update(overrides)
    results = os.path.join(work, "results")
    os.makedirs(results, exist_ok=True)
    with open(os.path.join(results, qt.result_filename(label)), "w",
              encoding="utf-8") as fh:
        json.dump(res, fh, indent=2)
    return res


def _no_probes(monkeypatch, *, runner=None, docker=None):
    """Pin both status probes: hermetic tests never shell out."""
    monkeypatch.setattr(em, "_runner_devices", lambda gen, work: runner)
    monkeypatch.setattr(em, "_docker_running_names", lambda: docker)


# ── plan ─────────────────────────────────────────────────────────────────────────────

def test_plan_test_mode_covers_the_session_in_boot_order(test_plan):
    assert test_plan.mode is em.EmulationMode.TEST
    assert test_plan.labels == ["rpi5/pki", "x86/backend", "x86/frontend"]
    assert test_plan.mesh is None and test_plan.front_door == ""
    assert test_plan.epoch == EPOCH


def test_plan_deploy_mode_carries_the_mesh_planners_answers(deploy_plan):
    """DEPLOY wraps mesh_emulation.plan_mesh — ports/identities/gateway are that
    planner's, row-for-row, never a second arithmetic."""
    p = deploy_plan
    assert p.mesh is not None
    assert [d.label for d in p.mesh.devices] == p.labels
    assert p.gateway_label == "x86/frontend"
    gw = p.mesh.gateway
    assert p.front_door == f"https://127.0.0.1:{gw.ui_port}/"
    for planned in p.mesh.devices:
        assert me.SSH_PORT_MIN <= planned.ssh_port <= me.SSH_PORT_MAX


def test_plan_accepts_a_session_path_or_name_but_never_guesses(session):
    gen, sess = session
    by_path = em.plan(gen, sess.path, "test", epoch=EPOCH)
    by_name = em.plan(gen, sess.name, "test", epoch=EPOCH)
    assert by_path.labels == by_name.labels == ["rpi5/pki", "x86/backend", "x86/frontend"]
    with pytest.raises(ValueError):
        em.plan(gen, "20990101-000000-nope00", "test")
    with pytest.raises(ValueError):
        em.plan(gen, "", "test")   # defaulting lives in qemu_tests.default_session


# ── argv authors ─────────────────────────────────────────────────────────────────────

def test_run_argv_test_lane_is_the_pinned_matrix_run(session):
    gen, sess = session
    env = em.RunEnvelope(jobs=3, mem_mb=4096, smp=4, timeout_s=1800,
                         assert_timeout_s=900, extra_users=("alice",),
                         keep=True, cache_max_gb=120)
    p = em.plan(gen, sess, "test", env, epoch=EPOCH)
    argv = em.run_argv(p)
    assert argv[0] == os.path.join(gen, qt.RUNNER_SCRIPT)
    assert argv[argv.index("--artifacts") + 1] == p.session_path
    assert argv[argv.index("--work") + 1] == p.work_dir
    assert argv[argv.index("--jobs") + 1] == "3"
    assert argv[argv.index("--smp") + 1] == "4"
    assert argv[argv.index("--assert-timeout") + 1] == "900"
    assert argv[argv.index("--cache-max-gb") + 1] == "120"
    assert argv[argv.index("--extra-user") + 1] == "alice"
    assert "--keep" in argv
    assert "--keep-alive" not in argv     # TEST powers its guests off


def test_run_argv_deploy_lane_keeps_alive_and_still_pins_artifacts(deploy_plan):
    argv = em.run_argv(deploy_plan)
    assert "--keep-alive" in argv
    assert argv[argv.index("--artifacts") + 1] == deploy_plan.session_path
    assert argv[argv.index("--work") + 1] == deploy_plan.work_dir


def test_start_device_argv_from_a_plan_pins_everything(deploy_plan):
    argv = em.start_device_argv(deploy_plan, "x86/backend")
    assert argv[argv.index("--artifacts") + 1] == deploy_plan.session_path
    assert argv[argv.index("--work") + 1] == deploy_plan.work_dir
    assert argv[argv.index("--only-exact") + 1] == "x86/backend"
    assert "--only" not in argv           # exact equality, never substring
    assert "--keep-alive" in argv
    assert argv[argv.index("--jobs") + 1] == "1"
    with pytest.raises(ValueError):
        em.start_device_argv(deploy_plan, "x86/nope")
    with pytest.raises(ValueError):
        em.start_device_argv(deploy_plan)  # a plan needs the label


def test_start_device_argv_from_a_record_uses_the_t1_artifacts_field(tmp_path):
    work = str(tmp_path / "work")
    rec = _write_record(work, "rpi5/pki")
    dev = qd.discover_devices(work)[0]
    argv = em.start_device_argv(dev, generator_dir="/gen")
    assert argv[argv.index("--artifacts") + 1] == rec["artifacts"]
    assert argv[argv.index("--only-exact") + 1] == "rpi5/pki"
    # --work is ALWAYS pinned, even at its default value: the argv must say where
    # the new device will register, not leave it to the runner's default du jour.
    assert argv[argv.index("--work") + 1] == qd.default_work_dir("/gen")
    custom = em.start_device_argv(dev, generator_dir="/gen", work_dir=work)
    assert custom[custom.index("--work") + 1] == work


def test_start_device_argv_never_falls_back_to_the_runners_guess(tmp_path):
    """A pre-T1 record has no artifacts field. An explicit session is accepted;
    NOTHING is the refusal case — the runner's newest-session default could boot a
    different build than the device came from."""
    work = str(tmp_path / "work")
    _write_record(work, "rpi5/pki", artifacts="", image="")
    dev = qd.discover_devices(work)[0]
    argv = em.start_device_argv(dev, generator_dir="/gen",
                                session_path="/host/out/sessions/explicit")
    assert argv[argv.index("--artifacts") + 1] == "/host/out/sessions/explicit"
    with pytest.raises(ValueError) as err:
        em.start_device_argv(dev, generator_dir="/gen")
    assert "newest-session guess" in str(err.value)
    with pytest.raises(ValueError):
        em.start_device_argv(dev)          # a record does not know the checkout


def test_stop_argvs_always_carry_the_plans_work_dir(deploy_plan):
    """The start/stop asymmetry fix: starts pin --work, so stops must too, or a
    custom-work mesh gets 'stopped' against a registry it never registered in."""
    p = deploy_plan
    stop = em.stop_device_argv(p, "rpi5/pki")
    assert stop == [os.path.join(p.generator_dir, qt.RUNNER_SCRIPT),
                    "--work", p.work_dir, "--stop-device", "rpi5/pki"]
    assert em.stop_all_argv(p) == [
        os.path.join(p.generator_dir, qt.RUNNER_SCRIPT),
        "--work", p.work_dir, "--stop-all-devices"]


def test_avc_argv_authors_the_workout_invocation(deploy_plan):
    p = deploy_plan
    argv = em.avc_argv(p, "rpi5/pki")
    assert argv == [os.path.join(p.generator_dir, em.AVC_SCRIPT),
                    "--platform", "rpi5", "--role", "pki",
                    "-w", p.session_path]
    assert em.avc_argv(p, p.row("x86/backend")) == em.avc_argv(p, "x86/backend")
    with pytest.raises(ValueError):
        em.avc_argv(p, "x86/nope")


def test_reexports_are_the_owning_cores_functions_not_copies():
    """One argv author per verb: the facade re-exports, never respells."""
    assert em.qmp_argv is qd.qmp_argv
    assert em.ssh_argv is qd.ssh_argv
    assert em.save_device_argv is qd.device_save_argv
    assert em.web_tunnel_argv is me.web_tunnel_argv


# ── status: the reconciled merge ─────────────────────────────────────────────────────

def test_status_prefers_the_runners_reconciled_devices(deploy_plan, monkeypatch):
    """When --devices answers, its records ARE the device view (it reconciled
    against docker ps itself). Planned rows with no record read PLANNED; a T1
    booting record reads BOOTING; a foreign record lands in unplanned, ungraded."""
    devices = [qd.device_from_record(_record("/w", "rpi5/pki")),
               qd.device_from_record(_record("/w", "x86/backend", state="booting",
                                             ssh_host_port=0)),
               qd.device_from_record(_record("/w", "x86/omnibus"))]
    _no_probes(monkeypatch, runner=devices)
    st = em.status(deploy_plan)
    assert st.source == "runner"
    assert [r.label for r in st.rows] == deploy_plan.labels
    assert st.row("rpi5/pki").state == em.STATE_RUNNING
    assert st.row("x86/backend").state == em.STATE_BOOTING
    assert st.row("x86/frontend").state == em.STATE_PLANNED
    assert [d.label for d in st.unplanned] == ["x86/omnibus"]


def test_status_fallback_replicates_the_runners_downgrade(deploy_plan, monkeypatch):
    """When the runner cannot answer, the raw registry is read and the SAME
    running->stopped downgrade applied — but ONLY when docker answered. An
    unanswered daemon says nothing about the containers."""
    work = deploy_plan.work_dir
    _write_record(work, "rpi5/pki")                       # container gone below
    _write_record(work, "x86/backend", container="hugmesh-qemu-dev-x86_be",
                  started_at="2026-08-19T12:00:01Z")      # still running

    _no_probes(monkeypatch, runner=None, docker={"hugmesh-qemu-dev-x86_be"})
    st = em.status(deploy_plan)
    assert st.source == "registry+docker"
    assert st.row("rpi5/pki").state == em.STATE_STOPPED   # downgraded
    assert st.row("x86/backend").state == em.STATE_RUNNING

    _no_probes(monkeypatch, runner=None, docker=None)     # docker never answered
    st = em.status(deploy_plan)
    assert st.source == "registry"
    assert st.row("rpi5/pki").state == em.STATE_RUNNING   # the record's own word


def test_status_grades_fresh_verdicts_and_scopes_to_the_plan(deploy_plan, monkeypatch):
    work = deploy_plan.work_dir
    _write_record(work, "rpi5/pki")
    _write_result(work, "rpi5/pki")                                  # fresh PASS
    _write_result(work, "x86/backend", status="FAIL",
                  detail="assertions failed", assertions_passed=25,
                  assertions_failed=8)
    _write_result(work, "x86/omnibus")           # NOT planned: must not surface
    _no_probes(monkeypatch, runner=None, docker=None)
    st = em.status(deploy_plan)
    assert st.row("rpi5/pki").verdict == "PASS"
    assert st.row("rpi5/pki").green
    assert st.row("x86/backend").verdict == "FAIL"
    assert "25 assertion(s) passed, 8 failed" in st.row("x86/backend").detail
    assert st.row("x86/frontend").verdict == em.VERDICT_PENDING
    assert not st.all_green
    assert st.counts() == {"PASS": 1, "FAIL": 1, "PENDING": 1}


def test_status_suspects_a_pass_that_asserted_nothing(deploy_plan, monkeypatch):
    """Field-for-field the real out/qemu-runs shape of the 2026-08-19 defect: rows
    graded PASS with assertions_passed=0 while holding real failures. The harness
    is fixed (T1), but old files persist and the class is generic — a PASS with no
    recorded assertions is NEVER green."""
    work = deploy_plan.work_dir
    _write_record(work, "rpi5/pki")
    _write_result(work, "rpi5/pki", status="PASS",
                  detail="all assertions passed",
                  assertions_passed=0, assertions_failed=0, duration_s=613)
    _no_probes(monkeypatch, runner=None, docker=None)
    row = em.status(deploy_plan).row("rpi5/pki")
    assert row.verdict == em.VERDICT_SUSPECT
    assert not row.green


def test_status_stales_verdicts_from_an_earlier_boot(deploy_plan, monkeypatch):
    """The cross-session bleed: results/ is never wiped, so last week's verdict for
    this label sits beside today's run. A verdict older than the device's current
    boot (record and result are stamped from the SAME variable) — or, recordless,
    older than the plan's epoch — is STALE, never presented as this run's outcome."""
    work = deploy_plan.work_dir
    # rpi5/pki: booted at 12:00, verdict stamped 09:00 — an earlier boot's.
    _write_record(work, "rpi5/pki", started_at="2026-08-19T12:00:00Z")
    _write_result(work, "rpi5/pki", started_at="2026-08-19T09:00:00Z")
    # x86/be: no record at all; verdict predates the plan epoch (11:00).
    _write_result(work, "x86/backend", started_at="2026-08-19T10:00:00Z")
    _no_probes(monkeypatch, runner=None, docker=None)
    st = em.status(deploy_plan)
    assert st.row("rpi5/pki").verdict == em.VERDICT_STALE
    assert st.row("x86/backend").verdict == em.VERDICT_STALE
    assert not st.row("rpi5/pki").green and not st.row("x86/backend").green

    # An epoch-less plan (the status CLI inspecting a run it did not start) keeps
    # the record-based gate but drops the plan-time one.
    gen = deploy_plan.generator_dir
    p2 = em.plan(gen, deploy_plan.session_path, "deploy", epoch="")
    st2 = em.status(p2)
    assert st2.row("rpi5/pki").verdict == em.VERDICT_STALE   # record still gates
    assert st2.row("x86/backend").verdict == "PASS"               # no record, no epoch


def test_status_synthesizes_no_result_rows_after_a_completed_test_run(
        test_plan, deploy_plan, monkeypatch):
    """Parity with the runner's own CLI summary: after a completed TEST run, a
    planned row with no verdict is a FINDING (the run ended without it), not a
    blank that reads as 'still running' forever. Never synthesized for DEPLOY (a
    standing mesh legitimately has unfinished assertions) nor mid-run."""
    for p in (test_plan, deploy_plan):
        _write_result(p.work_dir, "rpi5/pki")
        _write_record(p.work_dir, "rpi5/pki")
    _no_probes(monkeypatch, runner=None, docker=None)

    done = em.status(test_plan, run_completed=True)
    assert done.row("rpi5/pki").verdict == "PASS"
    assert done.row("x86/backend").verdict == em.VERDICT_NO_RESULT
    assert done.row("x86/frontend").verdict == em.VERDICT_NO_RESULT
    assert not done.all_green

    midrun = em.status(test_plan)
    assert midrun.row("x86/backend").verdict == em.VERDICT_PENDING
    deployed = em.status(deploy_plan, run_completed=True)
    assert deployed.row("x86/backend").verdict == em.VERDICT_PENDING


# ── save-mesh delegation ────────────────────────────────────────────────────────────

def test_save_mesh_delegates_planner_rows_to_emulation_save(deploy_plan, monkeypatch):
    seen = {}

    def _spy_save(generator_dir, items=None, *, work_dir="", session="", stamp="",
                  overwrite=False, budget_bytes=0, run=None, disk_usage=None):
        seen.update(generator_dir=generator_dir, items=items, work_dir=work_dir,
                    session=session, overwrite=overwrite)
        return emulation_save.MeshSaveReport(session=session, session_dir="",
                                             work_dir=work_dir)

    monkeypatch.setattr(emulation_save, "save_mesh", _spy_save)
    em.save_mesh(deploy_plan, session="mesh-x", overwrite=True)
    assert seen["generator_dir"] == deploy_plan.generator_dir
    assert seen["work_dir"] == deploy_plan.work_dir
    assert [i.label for i in seen["items"]] == deploy_plan.labels
    assert seen["session"] == "mesh-x" and seen["overwrite"] is True


def test_plan_mesh_save_surfaces_unbootable_planned_rows(deploy_plan):
    """Fed with planner rows, the save plan must account for EVERY planned device:
    with no live registry, each surfaces as unresolved instead of silently
    shrinking 'save the mesh' to nothing."""
    save_plan = em.plan_mesh_save(deploy_plan, stamp="20260819T120000Z")
    assert save_plan["session"] == "mesh-20260819T120000Z"
    assert {row["label"] for row in save_plan["unresolved"]} == set(deploy_plan.labels)
    assert save_plan["devices"] == []


# ── the process boundary ────────────────────────────────────────────────────────────

def test_spawn_streams_lines_and_returns_the_exit_code(tmp_path):
    lines = []
    rc = em.spawn([sys.executable, "-c", "print('one'); print('two')"],
                  str(tmp_path), on_line=lines.append)
    assert rc == 0 and lines == ["one", "two"]
    assert em.spawn(["/nonexistent/binary"], str(tmp_path),
                    on_line=lines.append) == 127


# ── CLI ─────────────────────────────────────────────────────────────────────────────

def test_cli_plan_json_is_machine_readable(session, capsys):
    gen, sess = session
    rc = em.main(["plan", "--generator-dir", gen, "--session", sess.name,
                  "--json"])
    assert rc == 0
    plan = json.loads(capsys.readouterr().out)
    assert plan["mode"] == "deploy"
    assert [d["label"] for d in plan["devices"]] == ["rpi5/pki", "x86/backend", "x86/frontend"]
    assert all("ssh_port" in d and "ui_port" in d for d in plan["devices"])
    assert plan["gateway"] == "x86/frontend"
    assert plan["argv"][0].endswith("run-qemu-docker.sh")
    assert "--keep-alive" in plan["argv"]


def test_cli_status_json_reports_the_merge(session, capsys, monkeypatch):
    gen, sess = session
    work = qd.default_work_dir(gen)
    _write_record(work, "rpi5/pki")
    _write_result(work, "rpi5/pki")
    _no_probes(monkeypatch, runner=None, docker=None)
    rc = em.main(["status", "--generator-dir", gen, "--session", sess.name,
                  "--json"])
    assert rc == 0
    status = json.loads(capsys.readouterr().out)
    rows = {r["label"]: r for r in status["rows"]}
    assert rows["rpi5/pki"]["state"] == em.STATE_RUNNING
    assert rows["rpi5/pki"]["verdict"] == "PASS"
    assert rows["rpi5/pki"]["artifacts"]        # the T1 field rides along
    assert rows["x86/backend"]["state"] == em.STATE_PLANNED
    assert status["source"] == "registry"


def test_cli_refuses_an_unknown_session(session, capsys):
    gen, _sess = session
    assert em.main(["plan", "--generator-dir", gen,
                    "--session", "20990101-000000-nope00"]) == 1
    assert "no such build session" in capsys.readouterr().err


def test_cli_down_needs_no_session_and_stops_the_fleet(tmp_path, monkeypatch):
    """`down` must work with an empty out/sessions: the mesh may outlive the
    session it was booted from, and 'stop everything' cannot depend on artifacts."""
    seen = {}

    def _spy(argv, cwd, on_line=None, cancel=None):
        seen.update(argv=argv, cwd=cwd)
        return 0

    monkeypatch.setattr(em, "spawn", _spy)
    gen = str(tmp_path)
    assert em.main(["down", "--generator-dir", gen]) == 0
    assert seen["argv"] == [os.path.join(gen, qt.RUNNER_SCRIPT),
                            "--work", qd.default_work_dir(gen),
                            "--stop-all-devices"]


# ── shell/python parity: constants and flags greppped from the runner itself ─────────

@pytest.mark.skipif(not os.path.exists(RUNNER), reason="runner script not present")
def test_port_ranges_match_the_runners_literal_text():
    """SSH_PORT_MIN/MAX mirror run-qemu-docker.sh's DEV_PORT_MIN/MAX — mirrored,
    not invented, so a range moved in the shell must fail HERE rather than let the
    plan preview ports the runner then refuses to publish. The web-tunnel range
    must stay disjoint from it (both bind the same loopback) and off the live
    stack's :8443/:8080."""
    text = open(RUNNER, encoding="utf-8").read()
    dev_min = int(re.search(r"^DEV_PORT_MIN=(\d+)$", text, re.M).group(1))
    dev_max = int(re.search(r"^DEV_PORT_MAX=(\d+)$", text, re.M).group(1))
    assert (me.SSH_PORT_MIN, me.SSH_PORT_MAX) == (dev_min, dev_max)
    ui = set(range(me.UI_PORT_MIN, me.UI_PORT_MAX + 1))
    assert not ui & set(range(dev_min, dev_max + 1))
    assert not ui & {8080, 8443}


@pytest.mark.skipif(not os.path.exists(RUNNER), reason="runner script not present")
def test_every_flag_the_facade_emits_exists_in_the_runner():
    """Source-grep drift guard: every long flag any facade argv can emit must be a
    string the runner's own text contains. A flag renamed in the shell (or typo'd
    here) fails this test instead of failing at spawn in front of an operator."""
    text = open(RUNNER, encoding="utf-8").read()
    opts = qt.QemuRunOptions(
        artifacts_dir="/a", work_dir="/w", platform="p", role="r", only="o",
        only_exact="x/y", mode="stage4", assert_timeout_s=1, extra_users=("u",),
        list_only=True, build_image=True, keep=True, cache_max_gb=1,
        keep_alive=True)
    flags = {a for a in qt.runner_command("/gen", opts) if a.startswith("--")}
    flags |= {"--devices", "--stop-device", "--stop-all-devices", "--qmp",
              "--save-device", "--save-to", "--overwrite"}
    missing = sorted(f for f in flags if f not in text)
    assert not missing, f"flags unknown to run-qemu-docker.sh: {missing}"


@pytest.mark.skipif(not os.path.exists(AVC), reason="avc-workout.sh not present")
def test_avc_argv_flags_exist_in_the_workout_script():
    text = open(AVC, encoding="utf-8").read()
    for flag in ("--platform", "--role", "-w"):
        assert flag in text


# ── THE PLAYWRIGHT LANE (tests/qemu/run-qemu-e2e.sh) ─────────────────────────────────
#
# A DIFFERENT harness from run-qemu-docker.sh, and every assertion below exists
# because the two were confusable: the config field that drove the docker lane was
# called `qemu_e2e`, which is the *other* script's name. So these tests pin WHICH
# script each author emits, not merely that some argv came out.

PW = os.path.join(GENERATOR_DIR, em.PLAYWRIGHT_SCRIPT)


def test_playwright_argv_is_the_e2e_script_and_never_the_docker_runner(test_plan):
    """THE naming guard. run_argv and playwright_argv must not be aimable at each
    other's script — that swap is exactly what the cfg.qemu_e2e rename was about."""
    argv = em.playwright_argv(test_plan)
    assert argv[0] == os.path.join(test_plan.generator_dir, em.PLAYWRIGHT_SCRIPT)
    assert argv[0].endswith("run-qemu-e2e.sh")
    assert not argv[0].endswith("run-qemu-docker.sh")
    # and the docker lane is still the docker lane
    assert em.run_argv(test_plan)[0].endswith("run-qemu-docker.sh")


def test_playwright_argv_emits_every_knob_of_the_scripts_flag_set(test_plan):
    """Every flag, with a value distinguishable from the script's default.

    Ports/sizes/timeouts are asserted PRESENT even when a caller leaves them alone
    (next test): run-qemu-e2e.sh reads each default from the environment
    (``"${MEM:-4096}"``), so omitting one hands the guest whatever the spawning
    shell exported.
    """
    opts = em.PlaywrightOptions(
        target="both", role="backend", img="/a/x.img", kernel="/a/Image",
        stage4="/a/s4.tar.xz", work_dir="/artifacts", test_dir="/scratch",
        ssh_port=2299, ui_port=9443, ssh_user="qa", mem_mb=8192, smp=6,
        accel="tcg", timeout_s=999, ui_timeout_s=77, keep=True,
        playwright_args=("--grep", "@smoke"))
    argv = em.playwright_argv(test_plan, opts)
    for flag, value in (("--target", "both"), ("--role", "backend"),
                        ("--img", "/a/x.img"), ("--kernel", "/a/Image"),
                        ("--stage4", "/a/s4.tar.xz"), ("-w", "/artifacts"),
                        ("--test-dir", "/scratch"), ("--ssh-port", "2299"),
                        ("--ui-port", "9443"), ("--ssh-user", "qa"),
                        ("--mem", "8192"), ("--smp", "6"), ("--accel", "tcg"),
                        ("--timeout", "999"), ("--ui-timeout", "77")):
        assert flag in argv, f"{flag} was not emitted at all"
        assert argv[argv.index(flag) + 1] == value, f"{flag} carried the wrong value"
    assert "--keep" in argv
    assert "--dry-run" not in argv and "--list" not in argv


def test_playwright_argv_emits_ports_and_sizes_even_at_their_defaults(test_plan):
    argv = em.playwright_argv(test_plan)
    for flag in ("--ssh-port", "--ui-port", "--ssh-user", "--mem", "--smp",
                 "--accel", "--timeout", "--ui-timeout"):
        assert flag in argv, (
            f"{flag} suppressed at its default — run-qemu-e2e.sh reads that default "
            "from the ENVIRONMENT, so omitting it is not the same as passing it")


def test_playwright_argv_pins_w_to_this_plans_session(test_plan):
    """``-w`` is the artifact dir the script autodetects the image in. Pinned to the
    plan's session for the same reason run_argv pins --artifacts: previewing one
    session while the boot resolves an image out of another is the bug this facade
    exists to close."""
    argv = em.playwright_argv(test_plan)
    assert argv[argv.index("-w") + 1] == test_plan.session_path


def test_playwright_argv_passthrough_rides_last_behind_a_bare_separator(test_plan):
    opts = em.PlaywrightOptions(
        playwright_args=("specs/01-frontpage.spec.ts", "--grep", "@smoke"))
    argv = em.playwright_argv(test_plan, opts)
    assert argv[-4:] == ["--", "specs/01-frontpage.spec.ts", "--grep", "@smoke"]
    # ...and nothing dangles when there is nothing to pass
    assert "--" not in em.playwright_argv(test_plan)


def test_playwright_options_for_row_derives_target_and_role_from_the_row(test_plan):
    x86 = em.playwright_options_for_row(test_plan, "x86/backend")
    assert (x86.target, x86.role) == ("x86", "backend")
    pi = em.playwright_options_for_row(test_plan, "rpi5/pki")
    assert (pi.target, pi.role) == ("pi", "pki")
    # a label that is not a row of THIS plan raises, like every other author here
    with pytest.raises(ValueError):
        em.playwright_options_for_row(test_plan, "x86/nope")


def test_playwright_refuses_platforms_that_have_no_launcher(session):
    """run-qemu-e2e.sh wires launch-x86.sh and launch-pi.sh only, and its own parser
    dies on any other --target — so a jetson row must refuse HERE, by name, rather
    than boot some other board's image or fail at spawn."""
    gen, _sess = session
    jet = os.path.join(gen, "out", "sessions", "20260819-101010-jet000")
    os.makedirs(jet)
    # non-empty: a 0-byte .img is a killed build, and neither discover_rows twin
    # counts one as a row
    with open(os.path.join(jet,
                           "hugmesh-jetson-arm64-edge_ai-test-20260819T101010Z.img"),
              "wb") as fh:
        fh.write(b"\0")
    pl = em.plan(gen, jet, "test", epoch=EPOCH)
    assert pl.labels == ["jetson/edge-ai"]
    assert em.playwright_target_for("jetson") == ""
    with pytest.raises(ValueError, match="no launcher"):
        em.playwright_options_for_row(pl, "jetson/edge-ai")


def test_playwright_argv_rejects_a_target_the_script_would_die_on(test_plan):
    with pytest.raises(ValueError):
        em.playwright_argv(test_plan, em.PlaywrightOptions(target="jetson"))
    with pytest.raises(ValueError):
        em.playwright_argv(test_plan, em.PlaywrightOptions(role=""))


def test_playwright_list_and_dry_run_are_distinct_flags(test_plan):
    assert "--list" in em.playwright_argv(
        test_plan, em.PlaywrightOptions(list_only=True))
    assert "--dry-run" in em.playwright_argv(
        test_plan, em.PlaywrightOptions(dry_run=True))
    assert "--list" not in em.playwright_argv(
        test_plan, em.PlaywrightOptions(dry_run=True))


# ── the envelope's new field, and the split it must not blur ─────────────────────────

def test_envelope_playwright_args_reach_the_playwright_lane(session):
    """The passthrough is a RunEnvelope field so the plan carries it — a knob read
    off a widget at spawn time is a knob that previews and then does not happen."""
    gen, sess = session
    env = em.RunEnvelope(playwright_args=("--repeat-each", "3"))
    pl = em.plan(gen, sess, "test", env, epoch=EPOCH)
    opts = em.playwright_options_for_row(pl, "x86/backend")
    assert opts.playwright_args == ("--repeat-each", "3")
    assert em.playwright_argv(pl, opts)[-3:] == ["--", "--repeat-each", "3"]


def test_envelope_playwright_args_never_reach_the_docker_runner(session):
    """run-qemu-docker.sh treats an unknown arg as a hard error, so the new field
    must be invisible to run_argv/start_device_argv. Asserted on the ARGV, both
    ways: nothing new appears, and the command is byte-identical to the one an
    envelope without the field produces."""
    gen, sess = session
    plain = em.plan(gen, sess, "test", em.RunEnvelope(), epoch=EPOCH)
    with_pw = em.plan(gen, sess, "test",
                      em.RunEnvelope(playwright_args=("--grep", "@smoke")),
                      epoch=EPOCH)
    assert em.run_argv(with_pw) == em.run_argv(plain)
    assert "--grep" not in em.run_argv(with_pw)
    assert "@smoke" not in em.run_argv(with_pw)
    assert "--grep" not in em.start_device_argv(with_pw, "x86/backend")


def test_every_run_envelope_field_is_routed_somewhere_on_purpose(session):
    """SHAPE GUARD for the frozen envelope.

    ``_envelope_options`` maps RunEnvelope one field at a time, so a field added to
    the dataclass and forgotten there reaches NEITHER lane while its widget looks
    wired. Every field must therefore be either a QemuRunOptions knob or an
    explicitly-recorded playwright-only one.
    """
    import dataclasses
    fields = {f.name for f in dataclasses.fields(em.RunEnvelope)}
    docker_knobs = {f.name for f in dataclasses.fields(qt.QemuRunOptions)}
    unrouted = fields - docker_knobs - set(
        em.ENVELOPE_FIELDS_NOT_FOR_THE_DOCKER_RUNNER)
    assert not unrouted, (
        f"RunEnvelope fields that reach no lane: {sorted(unrouted)} — forward them "
        "in _envelope_options or record them in "
        "ENVELOPE_FIELDS_NOT_FOR_THE_DOCKER_RUNNER with the reason")
    # the recorded exceptions must be real fields, with a real reason
    for name, why in em.ENVELOPE_FIELDS_NOT_FOR_THE_DOCKER_RUNNER.items():
        assert name in fields
        assert len(why) > 20, f"{name}: the exemption reason must say WHY"


# ── the honest refusal (no sudo, ever) ───────────────────────────────────────────────

def test_root_blocker_names_the_container_and_never_reaches_for_sudo():
    blocker = em.playwright_root_blocker()
    if os.geteuid() == 0:
        assert blocker == ""
        pytest.skip("running as root: the non-root refusal cannot be exercised here")
    assert "--privileged" in blocker and "hugmesh-qemu-runner" in blocker
    assert "root" in blocker
    # It must never TELL the operator (or a caller) to sudo: the Studio cannot
    # answer a password prompt, and this box has no admin password at all.
    assert "sudo" not in blocker.replace("cannot answer a sudo prompt", "")


# ── shell/python parity for the second runner ────────────────────────────────────────
#
# NOT by grepping the whole file. Every flag this lane emits also appears in
# run-qemu-e2e.sh's usage() heredoc AND in its header comments, so "the token is
# somewhere in the text" is satisfied by PROSE — a flag deleted from the parser, or a
# refusal that stopped naming the container, would still read as green. That is
# comment-token inversion, and it has shipped in this repo more than once. The two
# helpers below narrow the haystack to the only two places that can actually affect
# an operator: the parser's case arms, and the bytes of the refusal message itself.

_PARSER_RE = re.compile(r"while \[\[ \$# -gt 0 \]\]; do\n(.*?)\ndone\n", re.S)
_REFUSAL_RE = re.compile(
    r'if \[ "\$\(id -u\)" -ne 0 \]; then\s*\n\s*cat >&2 <<EOF\n(.*?)\nEOF\n', re.S)


def _parser_flags(text):
    """The option tokens run-qemu-e2e.sh's arg parser actually ACCEPTS."""
    block = _PARSER_RE.search(text)
    assert block, "the arg-parser loop moved — this guard can no longer see it"
    flags = set()
    for arm in re.finditer(r"^\s*([-a-zA-Z0-9|]+)\)", block.group(1), re.M):
        flags.update(t for t in arm.group(1).split("|") if t.startswith("-"))
    return flags


def _refusal_message(text):
    """The heredoc a non-root operator actually reads, comments excluded."""
    m = _REFUSAL_RE.search(text)
    assert m, "the non-root refusal heredoc moved — this guard can no longer see it"
    return m.group(1)


@pytest.mark.skipif(not os.path.exists(PW), reason="run-qemu-e2e.sh not present")
def test_every_playwright_flag_is_a_real_parser_arm_not_just_prose():
    """Drift guard, the twin of the docker runner's. A flag renamed in
    run-qemu-e2e.sh (or typo'd in the author) fails here rather than at spawn."""
    text = open(PW, encoding="utf-8").read()
    opts = em.PlaywrightOptions(
        img="/a", kernel="/k", stage4="/s", test_dir="/t", keep=True,
        dry_run=True, list_only=True)
    plan_stub = em.EmulationPlan(mode=em.EmulationMode.TEST, generator_dir="/gen",
                                 session_path="/gen/out/sessions/s", session_name="s",
                                 work_dir="/w")
    flags = {a for a in em.playwright_argv(plan_stub, opts)
             if a.startswith("--") and a != "--"}
    accepted = _parser_flags(text)
    missing = sorted(f for f in flags if f not in accepted)
    assert not missing, f"flags no arg-parser arm accepts: {missing}"
    assert {"-w", "--work-dir"} <= accepted, "the -w spelling this author emits moved"
    assert {"--list", "--dry-run", "--"} <= accepted   # the two non-root verbs + passthrough


@pytest.mark.skipif(not os.path.exists(PW), reason="run-qemu-e2e.sh not present")
def test_the_flag_guard_is_not_satisfied_by_comments_or_usage_text():
    """BREAK-IT TWIN for the guard above — the comment-token-inversion control.

    Delete one parser arm and leave every mention of it in usage()/the comments. The
    naive whole-file grep the first cut used still finds the flag (asserted, so this
    twin is proven to model the defect); _parser_flags does not.
    """
    text = open(PW, encoding="utf-8").read()
    mutant = re.sub(r"^\s*--ui-port\).*\n", "", text, flags=re.M)
    assert mutant != text, "the mutation did not change the text — this twin proves nothing"
    assert "--ui-port" in mutant, "usage()/comments no longer mention it; twin is moot"
    assert "--ui-port" in _parser_flags(text)
    assert "--ui-port" not in _parser_flags(mutant), \
        "COMMENT-TOKEN INVERSION: a deleted parser arm still counted as wired"


@pytest.mark.skipif(not os.path.exists(PW), reason="run-qemu-e2e.sh not present")
def test_the_e2e_script_refusal_names_the_container_and_offers_no_sudo():
    """The script's own refusal must point at the containerized route, not at sudo:
    the old message was `run as root ...: sudo $0 ...`, which is the one instruction
    a Studio-driven harness must never give."""
    text = open(PW, encoding="utf-8").read()
    msg = _refusal_message(text)
    assert "--privileged" in msg and "hugmesh-qemu-runner" in msg
    assert "make qemu-docker-image" in msg
    # ...and it offers the two verbs that need no root.
    assert "--list" in msg and "--dry-run" in msg
    # The sudo checks stay whole-file on purpose: a commented-out `sudo $0` is still
    # a regression waiting to be uncommented, so a false RED there is the safe way
    # round. (Inversion only ever weakens a POSITIVE assertion.)
    assert "sudo $0" not in text, "the sudo-yourself instruction came back"
    assert "Usage: sudo $0" not in text


@pytest.mark.skipif(not os.path.exists(PW), reason="run-qemu-e2e.sh not present")
def test_the_refusal_guard_is_not_satisfied_by_the_header_comment():
    """BREAK-IT TWIN: the header comment block at the top of run-qemu-e2e.sh already
    says "the privileged hugmesh-qemu-runner container". A refusal that STOPPED
    naming the container would therefore pass a whole-file grep. It must not pass
    this one."""
    text = open(PW, encoding="utf-8").read()
    msg = _refusal_message(text)
    gutted = text.replace(msg, "this lane needs root.\n")
    assert gutted != text, "the mutation did not change the text — this twin proves nothing"
    assert "hugmesh-qemu-runner" in gutted, "the header comment stopped baiting the naive grep"
    assert "--privileged" in gutted
    assert "hugmesh-qemu-runner" not in _refusal_message(gutted), \
        "COMMENT-TOKEN INVERSION: a header comment stood in for the refusal message"

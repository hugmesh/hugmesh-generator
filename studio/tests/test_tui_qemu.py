"""tui — the QEMU device-test screen: the TEST lane over core/emulation.

Hermetic, like every emulation suite here: the fixtures write the REAL on-disk
shapes the harness writes (a session dir of artifact names, per-row verdict
JSONs, device-registry records — field for field), and BOTH of
``core.emulation``'s probe seams are pinned autouse, so no test shells out to
the runner or to docker.

What these pins are actually protecting:

* the SCREEN never authors a command. Every printed argv is compared to
  ``emulation``'s own output, byte for byte — the single-argv-author rule, which
  is the only thing keeping the TUI's hint and the GUI's spawn identical;
* a PASS that asserted nothing is never rendered as a pass (the 2026-08-19
  truncated-assertions defect graded six rows holding real FAILs as PASS with
  zero recorded assertions);
* a planned row a finished run never graded says NO-RESULT rather than sitting
  blank, which reads as "still running" forever;
* the TUI spawns NOTHING — a test replaces the facade's one process boundary
  with a landmine and walks the whole screen over it.
"""
import json
import os
import shlex

import pytest

from hugmesh_studio.core import emulation as em
from hugmesh_studio.core import qemu_devices as qd
from hugmesh_studio.core import qemu_tests as qt
from hugmesh_studio.tui import journey
from hugmesh_studio.tui import qemu as tui_qemu

COMPLETE = "20260818-090000-mesh00"      # older, whole fleet built
PARTIAL = "20260819-125930-89bb8e"       # newer, build aborted mid-fleet


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(autouse=True)
def _no_probes(monkeypatch):
    """Pin both of status()'s probe seams: these tests never shell out.

    ``_runner_devices`` returning None drops status onto the registry lane, and
    ``_docker_running_names`` returning None means "docker never answered", which
    is the one case where the raw registry is used verbatim — deterministic, and
    the honest reading on a host with no daemon.
    """
    monkeypatch.setattr(em, "_runner_devices", lambda gen, work: None)
    monkeypatch.setattr(em, "_docker_running_names", lambda: None)


@pytest.fixture
def gen(tmp_path):
    """A generator dir with two sessions: an older COMPLETE 3-device one and a
    NEWER one whose build aborted after a single image (4 per-image build logs,
    1 bootable artifact — the ``is_partial`` shape)."""
    root = tmp_path / "gen"
    whole = root / "out" / "sessions" / COMPLETE
    whole.mkdir(parents=True)
    for name in ("hugmesh-rpi5-arm64-pki-test-20260818T085951Z.img.xz",
                 "hugmesh-x86-amd64-be-test-20260818T090010Z.img",
                 "hugmesh-x86-amd64-fe-test-20260818T090011Z.img"):
        (whole / name).write_bytes(b"")

    aborted = root / "out" / "sessions" / PARTIAL
    aborted.mkdir(parents=True)
    (aborted / "hugmesh-x86-amd64-be-test-20260819T125930Z.img").write_bytes(b"")
    for name in ("build-pki.rpi5.log", "build-backend.x86.log", "build-frontend.x86.log",
                 "build-omnibus.x86.log"):
        (aborted / name).write_text("...", encoding="utf-8")

    os.utime(whole, (1_000_000, 1_000_000))
    os.utime(aborted, (2_000_000, 2_000_000))       # newest wins the list order
    return str(root)


def _work(gen: str) -> str:
    return qd.default_work_dir(gen)


def _write_result(gen: str, label: str, **overrides) -> dict:
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
        "image": f"/work/images/{label.replace('/', '-')}.img",
        "started_at": "2026-08-19T12:00:00Z",
        "duration_s": 90,
    }
    res.update(overrides)
    results = os.path.join(_work(gen), "results")
    os.makedirs(results, exist_ok=True)
    with open(os.path.join(results, qt.result_filename(label)), "w",
              encoding="utf-8") as fh:
        json.dump(res, fh, indent=2)
    return res


def _write_record(gen: str, label: str, **overrides) -> dict:
    """One live device-registry record, the T1 shape (artifacts + image pinned)."""
    safe = qd.safe_label(label)
    rec = {
        "label": label, "platform": label.split("/")[0],
        "role": label.split("/")[-1], "board": "",
        "container": f"hugmesh-qemu-dev-{safe}",
        "ssh_host_port": 22301, "ssh_user": "tester",
        "ssh_key": f"{_work(gen)}/runs/{safe}/id_ed25519", "users": ["tester"],
        "qmp": f"{_work(gen)}/runs/{safe}/launch/qmp.sock",
        "artifacts": os.path.join(gen, "out", "sessions", COMPLETE),
        "image": "hugmesh-x86-amd64-be-test-20260818T090010Z.img",
        "state": "running", "started_at": "2026-08-19T12:00:00Z",
    }
    rec.update(overrides)
    root = qd.devices_dir(_work(gen))
    os.makedirs(root, exist_ok=True)
    with open(os.path.join(root, safe + ".json"), "w", encoding="utf-8") as fh:
        json.dump(rec, fh, indent=2)
    return rec


def _at_picker(gen: str) -> journey.Journey:
    j = journey.Journey(gen)
    j.feed("")            # welcome -> mode
    j.feed("4")           # the QEMU device-tests card (journey position 4)
    assert j.slug == "qemu"
    return j


def _at_rows(gen: str) -> journey.Journey:
    j = _at_picker(gen)
    j.feed("")            # Enter = the default: the newest COMPLETE session
    return j


def _plan(gen: str) -> em.EmulationPlan:
    session = qt.default_session(gen)
    return tui_qemu.plan_for(gen, session)


# ── the session picker: badges and the COMPLETE default ────────────────────────────
def test_picker_badges_every_session_with_its_own_completeness(gen):
    j = _at_picker(gen)
    text = "\n".join(j.lines())
    assert f"{PARTIAL} — 1 bootable image(s) [PARTIAL — 1 of 4 image(s)]" in text
    assert f"{COMPLETE} — 3 bootable image(s) [COMPLETE]" in text


def test_the_default_is_the_newest_complete_session_not_the_newest(gen):
    sessions = qt.discover_sessions(gen)
    assert sessions[0].name == PARTIAL          # newest overall IS the partial one
    index = tui_qemu.default_session_index(sessions)
    # the picker's default must be the SESSION module's own rule, not a second one
    assert sessions[index].name == qt.default_session(gen).name == COMPLETE
    assert "(default)" in "\n".join(j for j in tui_qemu.session_lines(sessions, index)
                                    if COMPLETE in j)


def test_enter_picks_the_default_and_a_number_picks_by_row(gen):
    j = _at_picker(gen)
    j.feed("")
    assert f"session {COMPLETE}" in "\n".join(j.lines())
    j.feed("q")                                  # back to the picker
    j.feed("1")                                  # row 1 is the newest = partial
    assert f"session {PARTIAL}" in "\n".join(j.lines())


def test_empty_generator_dir_is_an_honest_empty_list(tmp_path):
    j = journey.Journey(str(tmp_path))
    j.feed("")
    j.feed("4")
    assert any("no build session holds bootable images" in ln for ln in j.lines())
    j.feed("")                                   # Enter with nothing to pick
    assert "build one first" in j.status
    assert j.slug == "qemu"                      # never a dead end, never a crash


# ── the planned rows + the run hint ────────────────────────────────────────────────
def test_planned_rows_are_the_plans_rows_in_boot_order(gen):
    _headers, rows = tui_qemu.planned_table(_plan(gen))
    assert [r[1] for r in rows] == ["rpi5/pki", "x86/backend", "x86/frontend"]   # Pi first
    assert "(decompressed once)" in rows[0][5]    # the .img.xz row says so
    text = "\n".join(_at_rows(gen).lines())
    for label in ("rpi5/pki", "x86/backend", "x86/frontend"):
        assert label in text


def test_the_run_hint_is_exactly_the_facades_argv(gen):
    """The single-argv-author pin. If this ever needs 'fixing' by editing the
    TUI, the fix belongs in core/emulation instead."""
    plan = _plan(gen)
    text = "\n".join(_at_rows(gen).lines())
    assert shlex.join(em.run_argv(plan)) in text
    assert "--artifacts" in em.run_argv(plan)     # never the runner's own guess
    assert "--keep-alive" not in em.run_argv(plan)  # TEST powers the guests off


def test_the_run_hint_also_spells_the_make_target(gen):
    text = "\n".join(_at_rows(gen).lines())
    assert f"{tui_qemu.MAKE_TARGET} SESSION=" in text
    assert os.path.join("out", "sessions", COMPLETE) in text


# ── the results table: PASS / FAIL / NO-RESULT / SUSPECT ───────────────────────────
def _verdicts(gen) -> dict[str, str]:
    plan = _plan(gen)
    st = em.status(plan, run_completed=tui_qemu.run_completed(plan))
    _headers, rows = tui_qemu.results_table(st)
    return {row[1]: row[3] for row in rows}


def test_pass_and_fail_are_the_runners_own_verdicts(gen):
    _write_result(gen, "rpi5/pki")
    _write_result(gen, "x86/backend", status="FAIL", assertions_passed=30,
                  assertions_failed=2, detail="2 assertion(s) failed")
    verdicts = _verdicts(gen)
    assert verdicts["rpi5/pki"] == "PASS"
    assert verdicts["x86/backend"] == "FAIL"


def test_a_planned_row_a_finished_run_never_graded_is_no_result(gen):
    _write_result(gen, "rpi5/pki")
    _write_result(gen, "x86/backend")
    # x86/fe has no verdict and nothing is live -> the run is over
    plan = _plan(gen)
    assert tui_qemu.run_completed(plan) is True
    assert _verdicts(gen)["x86/frontend"] == em.VERDICT_NO_RESULT == "NO-RESULT"
    text = "\n".join(_at_rows(gen).lines())
    assert "NO-RESULT" in text
    assert "the run finished without grading this planned row" in text


def test_a_pass_with_zero_assertions_is_suspect_and_never_shown_as_a_pass(gen):
    _write_result(gen, "x86/backend", status="PASS", assertions_passed=0,
                  assertions_failed=0, detail="all assertions passed")
    verdicts = _verdicts(gen)
    assert verdicts["x86/backend"] == em.VERDICT_SUSPECT == "SUSPECT"
    text = "\n".join(_at_rows(gen).lines())
    assert "SUSPECT" in text
    assert "graded PASS with 0 assertions recorded — never a pass" in text
    # the raw count that made it suspect is on screen, not hidden behind the word
    _headers, rows = tui_qemu.results_table(
        em.status(_plan(gen), run_completed=True))
    suspect = next(r for r in rows if r[1] == "x86/backend")
    assert suspect[3] == "SUSPECT" and suspect[4] == "0"


def test_no_result_is_not_synthesized_while_a_row_is_still_live(gen):
    """A run in flight must not be accused of a missing verdict."""
    _write_result(gen, "rpi5/pki")
    _write_record(gen, "x86/backend", state="assertions")
    plan = _plan(gen)
    assert tui_qemu.run_completed(plan) is False
    assert _verdicts(gen)["x86/frontend"] == "pending"


def test_a_run_that_never_started_is_never_called_finished(gen):
    assert tui_qemu.run_completed(_plan(gen)) is False


def test_the_legend_only_names_verdicts_actually_on_screen(gen):
    _write_result(gen, "rpi5/pki")
    _write_result(gen, "x86/backend")
    _write_result(gen, "x86/frontend")
    text = "\n".join(_at_rows(gen).lines())
    assert "PASS" in text
    for word in (em.VERDICT_SUSPECT, em.VERDICT_STALE, em.VERDICT_NO_RESULT):
        assert f"{word} =" not in text


# ── the per-row detail: the two copy-ready per-row commands ────────────────────────
def test_row_detail_carries_the_verdict_reason_and_both_row_argv(gen):
    _write_result(gen, "rpi5/pki", status="FAIL", assertions_passed=31,
                  assertions_failed=2, detail="firewalld assertion failed")
    j = _at_rows(gen)
    j.feed("1")                                   # rpi5/pki detail
    text = "\n".join(j.lines())
    plan = _plan(gen)
    assert "FAIL" in text and "firewalld assertion failed" in text
    assert shlex.join(em.start_device_argv(plan, "rpi5/pki")) in text
    assert shlex.join(em.avc_argv(plan, "rpi5/pki")) in text
    assert "avc-workout.sh" in text and "--only-exact rpi5/pki" in text


def test_row_detail_shows_the_registry_record_when_one_exists(gen):
    _write_record(gen, "x86/backend")
    j = _at_rows(gen)
    j.feed("2")                                   # x86/be
    text = "\n".join(j.lines())
    assert "hugmesh-qemu-dev-x86_backend" in text and "22301" in text


def test_an_unknown_row_number_is_an_inline_message_never_a_crash(gen):
    j = _at_rows(gen)
    j.feed("99")
    assert "no such device row" in j.status
    assert "session" in "\n".join(j.lines())      # still on the row list


# ── the design decision this screen inherits: read-only toward the host ────────────
def test_the_screen_never_spawns_anything(gen, monkeypatch):
    """The whole walk with the facade's ONE process boundary replaced by a
    landmine: planning, rendering and hint-building must never reach it."""
    def _boom(*args, **kwargs):
        raise AssertionError("the TUI must never spawn a process")

    monkeypatch.setattr(em, "spawn", _boom)
    _write_result(gen, "rpi5/pki")
    j = _at_rows(gen)
    for line in ("1", "q", "2", "q", "3", "q", "r"):
        j.feed(line)
    assert not j.done


def test_q_walks_back_through_the_substates_not_out(gen):
    j = _at_rows(gen)
    j.feed("1")
    j.feed("q")                                   # detail -> rows
    assert "planned device(s)" in "\n".join(j.lines())
    j.feed("q")                                   # rows -> picker
    assert any("pick the session" in ln for ln in j.lines())
    j.feed("q")                                   # picker -> the mode menu
    assert j.slug == "mode" and not j.done

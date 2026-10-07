"""tui — the QEMU device-test screen: the TEST lane over core/emulation.

Hermetic, like every emulation suite here: the fixtures write the REAL on-disk
shapes the harness writes (a session dir of artifact names, per-row verdict
JSONs, device-registry records — field for field), and BOTH of
``core.emulation``'s probe override points are pinned autouse, so no test shells out to
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
from hugmesh_studio.tui import e2e as tui_e2e
from hugmesh_studio.tui import journey
from hugmesh_studio.tui import qemu as tui_qemu

COMPLETE = "20260818-090000-mesh00"      # older, whole fleet built
PARTIAL = "20260819-125930-89bb8e"       # newer, build aborted mid-fleet


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(autouse=True)
def _no_probes(monkeypatch):
    """Pin both of status()'s probe override points: these tests never shell out.

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
        (whole / name).write_bytes(b"\0")  # non-empty: a 0-byte .img is a killed build, not a row

    aborted = root / "out" / "sessions" / PARTIAL
    aborted.mkdir(parents=True)
    (aborted / "hugmesh-x86-amd64-be-test-20260819T125930Z.img").write_bytes(b"\0")  # non-empty: a 0-byte .img is a killed build, not a row
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
    j.feed("4")           # RUN E2E TESTS (journey position 4)
    # The "QEMU device tests" card was removed from BOTH menus on 2026-08-27; this
    # screen is its door now (the GUI twin is E2EPage's second radio arm). The screen
    # itself is untouched — everything below this helper is unchanged.
    j.feed(tui_e2e.DEVICE_LANE_KEY)
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
    j.feed(tui_e2e.DEVICE_LANE_KEY)
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


# ── #637: a refused session prints the refusal, never the argv the GUI refuses ──────
from _session_records import write_build_record  # noqa: E402


def test_a_refused_session_shows_no_run_hint(gen):
    write_build_record(COMPLETE, domains=("b.example",), reviewed=("hugmesh.net",))
    j = _at_rows(gen)
    text = "\n".join(j.lines())
    assert "! refused" in text and "b.example" in text
    plan = _plan(gen)
    assert shlex.join(em.run_argv(plan)) not in text
    j.feed("1")
    detail = "\n".join(j.lines())
    assert "b.example" in detail
    assert shlex.join(em.start_device_argv(plan, plan.labels[0])) not in detail
    assert shlex.join(em.avc_argv(plan, plan.labels[0])) not in detail


def test_an_unrecorded_session_keeps_its_run_hint(gen):
    text = "\n".join(_at_rows(gen).lines())
    assert "! refused" not in text
    assert shlex.join(em.run_argv(_plan(gen))) in text


# ── #638, decision 71 = A: the build-first arm has a text-mode twin ────────────────
from hugmesh_studio.core.config import ImageConfig  # noqa: E402


def _at_build(gen, mode="standalone") -> journey.Journey:
    j = journey.Journey(gen, cfg=ImageConfig(mode=mode))
    j.feed("")
    j.feed("4")
    j.feed(tui_e2e.DEVICE_LANE_KEY)
    assert j.slug == "qemu"
    j.feed(tui_qemu.BUILD_FIRST_KEY)
    return j


def test_the_picker_offers_the_build_first_arm_and_its_key_is_not_a_back_key(gen):
    text = "\n".join(_at_picker(gen).lines())
    assert f"{tui_qemu.BUILD_FIRST_KEY} = build new images first" in text
    assert tui_qemu.BUILD_FIRST_KEY not in ("q", "quit", "exit")
    assert not tui_qemu.BUILD_FIRST_KEY.isdigit()       # a digit picks a session


def test_the_build_arm_lists_the_three_image_builds_and_marks_the_inherited_one(gen):
    """The route here passes no Mode screen, so the preselected build is whatever
    this Studio session was already carrying — marked, and said to be a leftover."""
    j = _at_build(gen, mode="mesh")                    # left over from an earlier flow
    text = "\n".join(j.lines())
    for i, (mid, title) in enumerate(tui_qemu.image_mode_choices(), 1):
        assert f"{i:2d}. {title}" in text
        assert (f" *{i:2d}. {title}" in text) == (mid == "mesh")
    assert "Preselected: Mesh node" in text and "already carrying" in text
    assert "NOT a choice made for this test" in text


def test_enter_takes_the_inherited_build_and_walks_into_its_chain(gen):
    j = _at_build(gen, mode="standalone")
    j.feed("")
    assert j.cfg.mode == "standalone" and j.cfg.qemu_device_tests is True
    assert j.slug == "role"                            # the desktop chain, as the GUI


def test_a_number_picks_another_build_and_commits_it_like_the_mode_screen(gen):
    """The commit is the journey's ONE mode commit (the TUI twin of the GUI's
    commit_image_mode): mesh's role reset, its defaults, a fresh worklist."""
    j = _at_build(gen, mode="standalone")
    j.worklist = object()                               # anything an earlier flow left
    j.feed("1")                                         # 1 = Mesh node
    assert j.cfg.mode == "mesh" and j.cfg.role == "omnibus"
    assert j.worklist is None
    assert j.cfg.qemu_device_tests is True
    assert j.slug == "idp"                              # the mesh chain, as the GUI
    assert j.flags.get("qemu_selected") is False        # any other commit disarms it


@pytest.mark.parametrize(("inherited", "first_slug"),
                         [("mesh", "idp"), ("cloud", "role"), ("standalone", "role")])
def test_enter_takes_whichever_build_the_session_was_carrying(gen, inherited,
                                                              first_slug):
    """Not only the desktop: Enter is "the preselected one", whichever of the three
    that is — a mesh left over from an earlier flow walks into the mesh chain."""
    j = _at_build(gen, mode=inherited)
    j.feed("")
    assert j.cfg.mode == inherited and j.cfg.qemu_device_tests is True
    assert j.slug == first_slug


@pytest.mark.parametrize(("number", "picked"),
                         [("1", "mesh"), ("2", "cloud"), ("3", "standalone")])
def test_each_number_picks_its_own_build(gen, number, picked):
    """The numbers are the list's order (Mesh node, Mesh desktop client, Standalone
    Gentoo desktop) — and the pick is not the inherited build, so a number that
    silently fell back to it could not pass."""
    inherited = "cloud" if picked != "cloud" else "mesh"
    j = _at_build(gen, mode=inherited)
    j.feed(number)
    assert j.cfg.mode == picked and j.cfg.qemu_device_tests is True


def test_the_build_screen_says_the_device_tests_will_run_after_the_build(gen):
    j = _at_build(gen, mode="standalone")
    j.feed("")
    for _ in range(40):             # bounded: a walk that cannot reach Build must FAIL
        if j.slug == "build" or j.done:
            break
        j.feed("")
    assert j.slug == "build", f"the walk stopped on {j.slug!r}"
    assert "the QEMU emulated-device tests run" in "\n".join(j.lines())


def test_a_bad_pick_on_the_build_arm_says_the_keys_and_commits_nothing(gen):
    j = _at_build(gen, mode="cloud")
    j.feed("9")
    assert j.slug == "qemu" and "a NUMBER picks a build" in j.status
    assert j.cfg.mode == "cloud" and not j.cfg.qemu_device_tests
    j.feed("x")
    assert j.slug == "qemu" and j.cfg.mode == "cloud"


def test_q_leaves_the_build_arm_for_the_picker_not_the_journey(gen):
    j = _at_build(gen)
    j.feed("q")
    assert j.slug == "qemu" and not j.done
    assert "pick the session" in "\n".join(j.lines())
    assert not j.cfg.qemu_device_tests


def test_the_build_arm_is_offered_with_no_session_to_boot(tmp_path):
    """The GUI forces build-first when nothing is bootable; the TUI's empty list
    points at the same door."""
    empty = tmp_path / "empty"
    (empty / "out" / "sessions").mkdir(parents=True)
    j = _at_picker(str(empty))
    assert f"build new images first: {tui_qemu.BUILD_FIRST_KEY}" in "\n".join(j.lines())
    j.feed("")
    assert tui_qemu.BUILD_FIRST_KEY in j.status
    j.feed(tui_qemu.BUILD_FIRST_KEY)
    j.feed("")
    assert j.cfg.qemu_device_tests is True and j.slug == "role"

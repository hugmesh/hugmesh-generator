"""StageTracker (core.stage_tracker) — headless, Qt-free unit tests (same idiom as
test_progress_parse.py). The tracker turns the parser's phase_index stream into nested
stage state + per-stage log slices for the GitHub-Actions-style ProgressPage tree.
"""
from snapdragon_studio.core.progress_parse import platform_phases
from snapdragon_studio.core.stage_tracker import (
    DONE, FAILED, PENDING, RUNNING, SKIPPED, STOPPED, StageTracker)


def _tracker(platform="x86"):
    return StageTracker(platform_phases(platform))


def test_stages_mirror_the_phase_table():
    phases = platform_phases("x86")
    t = _tracker("x86")
    assert len(t.stages) == len(phases)
    assert [s.label for s in t.stages] == [ph["label"] for ph in phases]
    assert all(s.state == PENDING for s in t.stages)   # all pending up front
    assert t.cur == -1


def test_first_banner_opens_stage_and_skips_earlier_pre_banner_phases():
    t = _tracker("x86")
    # jump straight to phase 3 (the earlier 0..2 were never announced -> skipped, not green)
    t.feed("==> banner", phase_index=3, now=1.0)
    assert t.cur == 3
    assert t.stages[3].state == RUNNING
    assert [t.stages[j].state for j in (0, 1, 2)] == [SKIPPED, SKIPPED, SKIPPED]
    assert all(s.state == PENDING for s in t.stages[4:])


def test_transition_closes_old_stage_and_attributes_banner_to_new_stage():
    t = _tracker("x86")
    t.feed("==> stage-0 banner", 0, 1.0)
    t.feed("  work line for 0", 0, 2.0)
    d = t.feed("==> stage-1 banner", 1, 3.0)     # the banner is the FIRST line of stage 1
    assert t.stages[0].state == DONE and t.stages[0].t_end == 3.0
    assert t.stages[1].state == RUNNING
    assert 0 in d.finished and 1 in d.started
    # ordering rule: the banner line lands in the stage it announces, work line in stage 0
    assert list(t.stages[0].lines) == ["==> stage-0 banner", "  work line for 0"]
    assert list(t.stages[1].lines) == ["==> stage-1 banner"]


def test_lines_before_first_banner_belong_to_no_stage():
    t = _tracker("x86")
    t.feed("docker: preamble noise", -1, 1.0)     # parser still indeterminate
    assert all(len(s.lines) == 0 for s in t.stages)
    assert t.cur == -1


def test_skipped_over_stage_is_neutral_never_green():
    t = _tracker("x86")
    t.feed("==> stage-2", 2, 1.0)
    t.feed("==> stage-5", 5, 2.0)                 # 3,4 stepped over
    assert t.stages[3].state == SKIPPED and t.stages[4].state == SKIPPED
    assert t.stages[2].state == DONE
    assert t.stages[5].state == RUNNING


def test_finalize_ok_marks_running_done_and_trailing_skipped():
    t = _tracker("x86")
    t.feed("==> stage-2", 2, 1.0)
    d = t.finalize(0, now=9.0)
    assert t.stages[2].state == DONE and t.stages[2].t_end == 9.0
    assert 2 in d.finished
    # every unreached trailing stage -> skipped (NOT fabricated done)
    assert all(s.state == SKIPPED for s in t.stages[3:])
    assert not any(s.state == DONE for s in t.stages[3:])


def test_finalize_nonzero_fails_running_and_leaves_trailing_pending():
    t = _tracker("x86")
    t.feed("==> stage-4", 4, 1.0)
    d = t.finalize(2, now=5.0)
    assert t.stages[4].state == FAILED
    assert t.failed_index() == 4
    assert 4 in d.failed
    # the build died at stage 4 — nothing downstream ran, so trailing stays PENDING
    assert all(s.state == PENDING for s in t.stages[5:])


def test_finalize_cancel_marks_running_stopped_neutral():
    t = _tracker("x86")
    t.feed("==> stage-1", 1, 1.0)
    d = t.finalize(None, now=4.0)
    assert t.stages[1].state == STOPPED           # neutral, not failed
    assert t.failed_index() is None               # a cancel is not a failure
    assert 1 in d.stopped
    assert all(s.state == PENDING for s in t.stages[2:])


def test_pre_banner_failure_has_no_failed_stage():
    """A build that dies before any banner (broken docker) has no running stage — so NO
    stage is marked failed; the caller reds the JOB itself instead."""
    t = _tracker("x86")
    t.feed("docker: error creating mount source path", -1, 1.0)
    t.finalize(1, now=2.0)
    assert t.failed_index() is None
    assert all(s.state == PENDING for s in t.stages)


def test_stage_elapsed_uses_t_end_when_done_else_now():
    t = _tracker("x86")
    t.feed("==> stage-0", 0, 10.0)
    assert t.stages[0].elapsed(now=13.5) == 3.5   # running -> now - t_start
    t.feed("==> stage-1", 1, 20.0)                # closes stage 0 at t_end=20
    assert t.stages[0].elapsed(now=999.0) == 10.0  # done -> fixed at t_end - t_start

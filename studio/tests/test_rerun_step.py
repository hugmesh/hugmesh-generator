"""core/rerun_step.py — what a rerun from a stage means, and the flags it dispatches with.

Pinned here: the steps a builder can start at are exactly the x86 builder's
X86_LATE_STEPS and the tail of the x86 progress table, in order (so an icon never
offers a --from-step the builder refuses); every other stage reruns with --resume and
says so; --from-step replaces any earlier one in extra_flags and never touches the
rest; and a page with no session, a fleet run or several images offers no rerun.
"""
import os
import re

from hugmesh_studio.core import rerun_step as rs
from hugmesh_studio.core.progress_parse import platform_phases

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILDER = os.path.join(os.path.dirname(STUDIO_ROOT), "build-x86-host-stage4.sh")


def test_late_steps_are_the_builders_and_the_tail_of_the_progress_table():
    with open(BUILDER, encoding="utf-8") as fh:
        m = re.search(r"^X86_LATE_STEPS=\(([^)]*)\)", fh.read(), re.M)
    assert m, "X86_LATE_STEPS not found in the x86 builder"
    assert tuple(m.group(1).split()) == rs.LATE_STEPS["x86"]
    ids = [p["id"] for p in platform_phases("x86")]
    late = list(rs.LATE_STEPS["x86"])
    assert ids[-len(late):] == late


def test_a_late_step_reruns_from_itself_and_says_what_is_kept():
    p = rs.plan("x86", "image-live", "Build LIVE image")
    assert p.from_step == "image-live"
    assert "“Build LIVE image” and the steps after it" in p.sentence
    assert "kept, not repeated" in p.sentence and "build stamp" in p.sentence
    first = rs.plan("x86", "package-stage4", "Package stage4")
    assert first.from_step == "package-stage4" and "everything before it" in first.sentence


def test_an_early_step_or_another_board_reruns_with_resume_and_says_so():
    for platform, sid in (("x86", "kernel"), ("x86", "emerge-system"), ("rpi5", "image-live")):
        p = rs.plan(platform, sid, "Some step")
        assert p.from_step == "", (platform, sid)
        assert "--resume" in p.sentence and "cannot restart in the middle" in p.sentence


def test_with_from_step_replaces_an_earlier_one_and_keeps_the_rest():
    assert rs.with_from_step("", "image-live") == "--from-step image-live"
    assert rs.with_from_step("--no-tar", "image-raw") == "--no-tar --from-step image-raw"
    assert rs.with_from_step("--from-step image-live --no-tar", "image-raw") == \
        "--no-tar --from-step image-raw"
    assert rs.with_from_step("--from-step=image-live --x 'a b'", "") == "--x 'a b'"
    # a plain Restart (no step) drops a stale one
    assert rs.with_from_step("--from-step package-stage4", "") == ""
    # unparseable flags are left for the builder to refuse, not silently rewritten
    assert rs.with_from_step("--x 'unterminated", "") == "--x 'unterminated"


def test_refusals():
    assert rs.refusal(1, False, "") == rs.NO_SESSION
    assert rs.refusal(1, True, "fleet") == rs.FLEET
    assert rs.refusal(2, True, "wizard") == rs.ONE_IMAGE_ONLY
    assert rs.refusal(1, True, "wizard") == ""

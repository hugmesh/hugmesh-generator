"""Halting a lane that is ALREADY halted is the goal reached, not a failure.

Operator log 20261030-060710-Halting-the-DevOps-lane-FAILED.log: the Studio ran
`make kind-halt`, scripts/kind-halt.sh refused with

    REFUSED (exit 4): cluster 'hugmesh-local' is ALREADY halted - devops/hugmesh-kind-halt
    holds a completed halt record.

and the run was filed (and its log named) FAILED. The refusal itself is right and stays:
a second halt would record the zeroed cluster as its own 'before' and the real replica
counts would be lost. What was wrong is the Studio's reading of it — the operator asked
for a halted lane and has one.

Qt-free: drives the REAL LocalStackNode.devops_halt with `_make` stubbed to replay the
script's real output. No make, no kind, no kubectl.
"""
from __future__ import annotations

import os
import re
import threading

from hugmesh_studio.core import local_stack_node
from hugmesh_studio.core.local_stack_node import LocalStackNode

GENERATOR_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
KIND_HALT_SH = os.path.join(GENERATOR_DIR, "scripts", "kind-halt.sh")

# The operator's log, verbatim (the make line included).
_ALREADY_HALTED = """bash scripts/kind-halt.sh halt
REFUSED (exit 4): cluster 'hugmesh-local' is ALREADY halted - devops/hugmesh-kind-halt holds a completed halt record.
    Run `make kind-halt-status` to see it, or `make kind-resume` to undo it.
    Halting twice would record a zeroed cluster as its own 'before', and the original replica counts would be lost.
make: *** [Makefile:1473: kind-halt] Error 4"""

_UNREADABLE = """bash scripts/kind-halt.sh halt
REFUSED (exit 5): could not read the halt record devops/hugmesh-kind-halt, so this control will not act.
make: *** [Makefile:1473: kind-halt] Error 5"""

_NO_CLUSTER = """bash scripts/kind-halt.sh halt
REFUSED (exit 3): there is no kind cluster named 'hugmesh-local' - nothing to halt.
make: *** [Makefile:1473: kind-halt] Error 3"""


def _node(monkeypatch, ok: bool, out: str, calls: list | None = None) -> LocalStackNode:
    def _fake_make(self, target, timeout=0, extra_env=None, on_line=None, cancel=None,
                   args=None):
        if calls is not None:
            calls.append(target)
        if on_line is not None:
            for ln in out.splitlines():
                on_line(ln)
        return ok, out
    monkeypatch.setattr(LocalStackNode, "_make", _fake_make)
    return LocalStackNode.__new__(LocalStackNode)


def test_already_halted_is_reported_done_not_failed(monkeypatch):
    """THE REGRESSION: the exact transcript of the operator's run."""
    calls: list[str] = []
    lines: list[str] = []
    node = _node(monkeypatch, False, _ALREADY_HALTED, calls)
    ok, msg = node.devops_halt(on_line=lines.append, cancel=threading.Event())
    assert ok is True, "an already-halted lane is the requested end state"
    assert calls == ["kind-halt"], "exactly one run of the real verb; never a second halt"
    said = [ln for ln in lines if ln.startswith("[devops] already halted")]
    assert len(said) == 1, lines
    # The operator is told the record was KEPT and how to undo it.
    assert "left untouched" in said[0] and "Resume DevOps lane" in said[0]
    # The script's own words stay in the log/message (nothing is hidden).
    assert "REFUSED (exit 4)" in msg and said[0] in msg


def test_other_refusals_still_fail(monkeypatch):
    """Only the already-halted refusal is the goal. An unreadable record (exit 5) and no
    cluster at all (exit 3) are real failures and must stay FAILED."""
    for out in (_UNREADABLE, _NO_CLUSTER):
        lines: list[str] = []
        ok, _msg = _node(monkeypatch, False, out).devops_halt(on_line=lines.append,
                                                              cancel=threading.Event())
        assert ok is False, out.splitlines()[1]
        assert not any(ln.startswith("[devops] already halted") for ln in lines)


def test_resumes_no_record_refusal_is_not_mistaken_for_already_halted(monkeypatch):
    """The OTHER exit 4 (resume with no record) must not match the halt mapping, even
    if it ever reached this verb's output."""
    out = ("REFUSED (exit 4): cluster 'hugmesh-local' has no halt record "
           "(devops/hugmesh-kind-halt) - this control did not halt it.")
    ok, _ = _node(monkeypatch, False, out).devops_halt(cancel=threading.Event())
    assert ok is False


def test_a_cancelled_run_is_never_relabelled(monkeypatch):
    """Cancel pressed: whatever the output carried, a cancelled run stays a cancelled
    (failed) run — the Studio does not get to claim the lane is halted."""
    ev = threading.Event()
    ev.set()
    ok, _ = _node(monkeypatch, False, _ALREADY_HALTED).devops_halt(cancel=ev)
    assert ok is False


def test_success_is_untouched(monkeypatch):
    lines: list[str] = []
    ok, msg = _node(monkeypatch, True, "halted 12 workloads").devops_halt(
        on_line=lines.append, cancel=threading.Event())
    assert ok is True and msg == "halted 12 workloads"
    assert not any(ln.startswith("[devops] already halted") for ln in lines)


def _uncommented(text: str) -> str:
    return "\n".join(re.sub(r"(^|\s)#.*$", "", ln) for ln in text.splitlines())


def test_the_pattern_is_pinned_to_the_scripts_real_refusal():
    """The mapping keys off kind-halt.sh's text, so pin it to that text: die() still
    prints `REFUSED (exit %s): %s`, and `halt` still refuses an already-halted cluster
    with exit 4 and the 'is ALREADY halted' wording. Rendered here the way bash would,
    then matched with the Studio's own pattern. If the script's wording moves, this
    fails instead of the Studio silently going back to FAILED."""
    with open(KIND_HALT_SH, encoding="utf-8") as fh:
        body = _uncommented(fh.read())
    assert "printf 'REFUSED (exit %s): %s\\n' \"${code}\" \"$*\" >&2" in body
    m = re.search(r'die 4 "(cluster \'\$\{CLUSTER_NAME\}\' is ALREADY halted[^\n]*)', body)
    assert m, "kind-halt.sh no longer refuses an already-halted cluster with exit 4"
    rendered = "REFUSED (exit 4): " + m.group(1).replace("${CLUSTER_NAME}", "hugmesh-local")
    assert local_stack_node._KIND_HALT_ALREADY_HALTED.search(rendered)
    # ...and the script still refuses rather than overwriting (the record is protected).
    assert "Halting twice would record a zeroed cluster" in body

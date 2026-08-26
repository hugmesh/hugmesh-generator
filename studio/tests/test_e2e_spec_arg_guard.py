"""The MODEL-level shell-safety guard on ``LocalStackNode.run_e2e``.

WHY THIS FILE EXISTS, SEPARATELY FROM THE TREE'S OWN TESTS. The selection the e2e
feature tree compiles ends up in ``make stack-e2e E2E_SPECS='…'``, and the Makefile
expands ``$(E2E_SPECS)`` UNQUOTED inside a /bin/sh recipe. So the value is a shell
word, and a path that is not a plain ``tests/e2e/specs/*.ts`` must never reach it.

There are two guards for that, on purpose — the same double-guard shape as the
.stack-src read-only rule, and for the same reason: a guard that lives only in the
affordance is one keystroke from being bypassed. The dialog refuses first (pinned by
tests/test_pages_e2e_tree.py), and ``run_e2e`` refuses again for every caller that
never went through the dialog — the TUI, a script, a future page.

An adversarial review of this unit found the SECOND guard completely unpinned: with
``run_e2e``'s ``safe_spec_args`` call replaced by ``tuple(specs or ()), ()``, and
again with the ``if rejected:`` branch neutered, the whole related suite stayed green.
Both mutations are RED against this file. It is deliberately Qt-free so it runs in the
plain-python lane, where the tree's own Qt file only skips.

WHAT IT DOES NOT PROVE. No stack is started and no spec is run: ``make`` is a stub
that records its argv. This proves what the MODEL refuses and what it lets through —
not that Playwright narrows correctly, which is the Makefile's own line.
"""
import os
import stat

import pytest

from hugmesh_studio.core import e2e_catalogue as ec
from hugmesh_studio.core.local_stack_node import LocalStackNode

#: A stub `make` that RECORDS ITS ARGV and nothing else. The refusal test reads the
#: recording's ABSENCE, so the sentinel path is baked in at fixture time rather than
#: passed through an env var the production code is free to rewrite.
_STUB_MAKE = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> '{record}'
exit 0
"""

#: What the tree would hand over if nothing validated it: a shell word that is not a
#: path at all. `;` ends the command, so the unquoted $(E2E_SPECS) expansion would run
#: `touch` as a second command in the recipe's shell.
INJECTION = "; touch /tmp/hugmesh-e2e-spec-arg-guard-pwned"


@pytest.fixture
def node(tmp_path, monkeypatch):
    """A real LocalStackNode over a throwaway checkout, with the readiness gate held
    open (so a refusal can only come from the spec-arg guard) and a recording `make`
    first on PATH. Yields ``(node, spawned)`` where ``spawned()`` is every argv line
    the stub actually received."""
    gen = tmp_path / "gen"
    (gen / "tests" / "e2e").mkdir(parents=True)

    record = tmp_path / "make-argv.log"
    binf = tmp_path / "stubbin"
    binf.mkdir()
    m = binf / "make"
    m.write_text(_STUB_MAKE.format(record=record))
    m.chmod(m.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    monkeypatch.setenv("PATH", str(binf) + os.pathsep + os.environ.get("PATH", ""))

    # e2e_ready() is run_e2e's FIRST gate and would refuse this checkout for a dozen
    # honest reasons (no stack running, nothing seeded). Held open so that the only
    # thing left that can refuse is the guard under test — otherwise this file would
    # pass with the guard deleted.
    monkeypatch.setattr(LocalStackNode, "e2e_ready", lambda self: [])

    def spawned():
        if not record.exists():
            return []
        return [ln for ln in record.read_text().splitlines() if ln.strip()]

    return LocalStackNode(str(gen)), spawned


def test_the_guard_is_not_the_dialogs_alone_and_spawns_no_make(node):
    """THE test the review asked for. A caller that never went through the tree hands
    run_e2e an injection alongside a legitimate spec. The run must be REFUSED, the bad
    path NAMED back (never silently dropped, which would run the good half and report
    green), and — the part a return value alone cannot show — `make` must never have
    been spawned at all."""
    n, spawned = node
    ok, msg = n.run_e2e(specs=[INJECTION, "specs/01-frontpage.spec.ts"])

    assert ok is False, "an unsafe spec arg was accepted into the run"
    assert ec.SPEC_ARG_REJECT_REASON in msg, msg
    assert INJECTION in msg, ("the rejected path was dropped rather than reported — "
                             "the operator would see a green run of half a selection")
    assert spawned() == [], (
        "make was spawned despite the refusal: %r" % (spawned(),))


def test_every_unsafe_shape_is_refused_through_run_e2e(node):
    """One test per shape a /bin/sh word can take that a spec path cannot, driven
    through run_e2e rather than through safe_spec_args as a pure function — the pure
    function already had coverage and the CALL SITE is what was missing."""
    n, spawned = node
    for bad in ("; rm -rf /",
                "specs/$(id).spec.ts",
                "specs/`id`.spec.ts",
                "specs/a b.spec.ts",
                "specs/../../etc/passwd",
                "specs/01-frontpage.spec.ts && echo hi",
                "specs/*.ts"):
        ok, msg = n.run_e2e(specs=[bad])
        assert ok is False, f"run_e2e accepted {bad!r}"
        assert ec.SPEC_ARG_REJECT_REASON in msg, (bad, msg)
    assert spawned() == [], (
        "make was spawned for a refused selection: %r" % (spawned(),))


def test_a_legitimate_selection_still_reaches_make_argv(node):
    """The positive control, without which the two tests above would pass a guard that
    refuses EVERYTHING — a run button that never runs is its own defect. Also pins the
    normalisation: a bare spec name is prefixed once, and the assignment rides ARGV."""
    n, spawned = node
    ok, msg = n.run_e2e(specs=["01-frontpage.spec.ts",
                               "specs/12-rbac-gateway-route-access.spec.ts"])

    assert ok is True, msg
    assert spawned() == [
        "stack-e2e E2E_SPECS=specs/01-frontpage.spec.ts "
        "specs/12-rbac-gateway-route-access.spec.ts"], spawned()


def test_no_selection_at_all_still_runs_the_whole_suite(node):
    """EMPTY MEANS EVERYTHING, and only here: no selection was made. It must NOT be
    the fallback for a selection that failed to compile — that case is the refusal
    above, and conflating the two is how a narrowed run silently becomes a full one."""
    n, spawned = node
    ok, _ = n.run_e2e()
    assert ok is True
    assert spawned() == ["stack-e2e"], spawned()

"""The look tests, run where they can be fast: in a FRESH interpreter (#647, #656).

Every ``test_look_*`` test in the files below measures what a person sees — at
the wizard's default window size, under two Qt styles, at the default font and at
8 pt — and skips in an ordinary run (``tests/_look.py`` says why: switching the
application style in a process that has already run other wizard tests takes minutes).
Here, ONE child pytest per file runs exactly those tests with ``HUGMESH_LOOK_CHILD=1``
and its verdict is this test's verdict, with the child's own output in the message.

A child that ran no look case at all (no Qt binding, no style installed, a renamed
test) is not a pass: the verdict needs at least one case that PASSED under EVERY
style the run requires. Fusion is always required (it ships inside Qt). Breeze is a
KDE plugin the Qt wheels do not carry, so by default it is optional: a host without it
looks under Fusion only, and the wrapper says so as a warning in the test summary. A
runner that has Breeze sets ``HUGMESH_LOOK_REQUIRE_STYLES=Fusion,Breeze`` and then a
missing Breeze fails (``tests/_look.py`` has the rule).

    HUGMESH_LOOK_SHOTS=<dir> python -m pytest tests/test_look.py

also saves one PNG per case, so a reviewer can open what the test measured.
"""
import os
import re
import subprocess
import sys
import warnings

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from _look import (LOOK_CASES, LOOK_CHILD_ENV, REQUIRE_STYLES_ENV,  # noqa: E402
                   looking, missing_style_action, required_styles)

from hugmesh_studio.gui.qt import QtWidgets  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
STUDIO_ROOT = os.path.dirname(HERE)

#: The test files that carry ``test_look_*`` tests. A new look test in another file
#: must be added here, or it would never run anywhere (test_every_look_test_is_run
#: below fails when a file carries one that is not listed).
LOOK_FILES = ("test_anubis_tristate_page.py", "test_localcloud_nodes.py",
              "test_pages_qemu.py", "test_pages_mesh_emulation.py",
              "test_look_editor.py")


# an id may also end in the window size a look case was drawn at (``fusion-9pt-736x736``)
_PASSED_CASE = re.compile(
    r"\[([A-Za-z]+)-(?:default|\d+(?:\.\d+)?pt)(?:-\d+x\d+)?\]\s+PASSED")


def styles_passed(lines: list) -> set:
    """The lower-cased style names that have at least one PASSED look case in a child's
    verbose output (``...::test_look_x[fusion-default] PASSED``)."""
    return {m.group(1).lower() for ln in lines for m in [_PASSED_CASE.search(ln)] if m}


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


def child_verdict(returncode: int, lines: list, required=None) -> str:
    """"" when a child's run counts as a pass; otherwise why it does not. A clean exit
    is not enough: a child whose every case SKIPPED (no style installed, the guard env
    lost) also exits 0, and nothing was looked at. Every REQUIRED style (default:
    :func:`_look.required_styles`) needs a passed case of its own, so a run that looked
    under Fusion only cannot pass for one that was meant to look under Breeze too."""
    if returncode != 0:
        return f"the child exited {returncode}"
    summary = next((ln for ln in reversed(lines) if " passed" in ln), "")
    passed = re.search(r"(\d+) passed", summary)
    if not passed or int(passed.group(1)) == 0:
        return "the child ran no look case that passed"
    need = required_styles() if required is None else {r.lower() for r in required}
    missing = sorted(need - styles_passed(lines))
    if missing:
        return (f"no look case passed under the required style(s) {missing} "
                f"({REQUIRE_STYLES_ENV} names them)")
    return ""


def test_a_look_run_needs_a_clean_exit_and_at_least_one_passing_case():
    ok = ["x.py::test_look_a[fusion-default] PASSED", "x.py::test_look_a[fusion-8pt] PASSED",
          "16 passed, 2 skipped in 9.1s"]
    assert child_verdict(0, ok, required=("Fusion",)) == ""
    assert child_verdict(1, ok + ["1 failed, 15 passed in 9.1s"], ("Fusion",)) != ""
    assert child_verdict(0, ["16 skipped in 0.3s"], ("Fusion",)) != ""   # nothing looked at
    assert child_verdict(5, ["no tests ran in 0.1s"], ("Fusion",)) != ""  # nothing selected
    assert child_verdict(0, [], ("Fusion",)) != ""


def test_every_required_style_needs_a_passing_case_of_its_own():
    """A run that looked under Fusion only is not a run that looked under Breeze too
    (the Breeze half is eight of the sixteen cases)."""
    fusion_only = ["x.py::t[fusion-default] PASSED", "x.py::t[breeze-default] SKIPPED",
                   "x.py::t[fusion-8pt] PASSED", "2 passed, 2 skipped in 1s"]
    both = fusion_only[:2] + ["x.py::t[breeze-8pt] PASSED"] + fusion_only[2:3] \
        + ["3 passed, 1 skipped in 1s"]
    assert child_verdict(0, fusion_only, ("Fusion",)) == ""
    why = child_verdict(0, fusion_only, ("Fusion", "Breeze"))
    assert "breeze" in why and "fusion" not in why, why
    assert child_verdict(0, both, ("Fusion", "Breeze")) == ""
    # Breeze alone does not stand in for Fusion
    why = child_verdict(0, ["x.py::t[breeze-default] PASSED", "1 passed in 1s"], ("Fusion",))
    assert "fusion" in why, why
    assert styles_passed(["a[Breeze-8pt] PASSED", "b[fusion-default] FAILED"]) == {"breeze"}
    # a case drawn at a named window size keeps its style (the look editor's ids)
    assert styles_passed(["a[fusion-9pt-736x736] PASSED",
                          "b[breeze-8pt-1040x780] PASSED"]) == {"fusion", "breeze"}
    assert styles_passed(["a[fusion-9pt-736x736] FAILED"]) == set()


def test_a_missing_style_fails_when_the_run_requires_it_and_skips_when_optional():
    keys = ["Windows", "Fusion"]                      # a host with no Breeze plugin
    assert missing_style_action("Fusion", keys, required=("Fusion",)) == "ok"
    assert missing_style_action("fusion", ["Fusion"], required=("Fusion",)) == "ok"
    assert missing_style_action("Breeze", keys, required=("Fusion",)) == "skip"
    assert missing_style_action("Breeze", keys, required=("Fusion", "Breeze")) == "fail"
    assert missing_style_action("Fusion", ["Windows"], required=("Fusion",)) == "fail"


def _outcome_of_looking(qapp, style: str) -> tuple:
    """Run ``looking(qapp, style, None)`` and say what happened: ``("fail", msg)``,
    ``("skip", msg)`` or ``("ran", "")`` when the body was reached. pytest's Failed and
    Skipped are BaseExceptions, and ``pytest.raises(one)`` does not catch the other, so a
    check on one outcome alone would pass (or report SKIPPED) when the code swaps them."""
    try:
        with looking(qapp, style, None):
            return ("ran", "")
    except pytest.fail.Exception as exc:
        return ("fail", str(exc))
    except pytest.skip.Exception as exc:
        return ("skip", str(exc))


def test_looking_fails_for_a_required_missing_style_and_skips_an_optional_one(
        qapp, monkeypatch):
    """The context manager itself (not only the helper it asks): a style this host does
    not have is a FAILURE where the run requires it, and a skip with the reason where it
    does not. Nothing is measured either way, so the application's style is untouched.
    Each case asserts WHICH outcome came back, so turning the required-missing ``fail``
    into a ``skip`` (the bug this guards) makes this test red, not skipped."""
    before = qapp.style().objectName()
    monkeypatch.setenv(REQUIRE_STYLES_ENV, "NoSuchStyle")
    kind, msg = _outcome_of_looking(qapp, "NoSuchStyle")
    assert kind == "fail" and "NoSuchStyle" in msg, (kind, msg)
    monkeypatch.setenv(REQUIRE_STYLES_ENV, "Fusion")
    kind, msg = _outcome_of_looking(qapp, "NoSuchStyle")
    assert kind == "skip" and "optional" in msg, (kind, msg)
    assert qapp.style().objectName() == before


def test_the_required_styles_come_from_the_environment_and_default_to_fusion(monkeypatch):
    monkeypatch.delenv(REQUIRE_STYLES_ENV, raising=False)
    assert required_styles() == {"fusion"}
    monkeypatch.setenv(REQUIRE_STYLES_ENV, "")
    assert required_styles() == {"fusion"}
    monkeypatch.setenv(REQUIRE_STYLES_ENV, "Fusion, Breeze")
    assert required_styles() == {"fusion", "breeze"}
    assert {st.lower() for st, _pt in LOOK_CASES} == {"fusion", "breeze"}


@pytest.mark.parametrize("fname", LOOK_FILES)
def test_the_looked_at_pages_are_drawn_whole_in_a_fresh_interpreter(fname):
    if os.environ.get(LOOK_CHILD_ENV) == "1":
        pytest.skip("this is the child interpreter; the parent runs this test")
    env = dict(os.environ)
    env[LOOK_CHILD_ENV] = "1"
    proc = subprocess.run(
        [sys.executable, "-m", "pytest", "-v", "-p", "no:cacheprovider",
         "-k", "test_look_", "-rs", os.path.join(HERE, fname)],
        cwd=STUDIO_ROOT, env=env, capture_output=True, text=True, timeout=900)
    lines = [ln for ln in (proc.stdout + proc.stderr).splitlines()
             if "propagateSizeHints" not in ln]
    problem = child_verdict(proc.returncode, lines)
    assert not problem, f"{problem} in {fname}:\n" + "\n".join(lines[-60:])
    # An optional style that did not run is said so, not dropped: a reader of the
    # summary sees that the run looked under Fusion only.
    skipped = sorted({st for st, _pt in LOOK_CASES} - {s.title() for s in styles_passed(lines)})
    if skipped:
        warnings.warn(f"{fname}: no look case ran under {skipped} (not installed here; "
                      f"optional unless {REQUIRE_STYLES_ENV} names it)", stacklevel=1)


def test_every_look_test_is_run():
    """A ``test_look_*`` test in a file this wrapper does not start would skip for ever
    in an ordinary run — a look test nobody runs. Names are read from the source, so no
    Qt is needed."""
    carriers = []
    for name in sorted(os.listdir(HERE)):
        if not (name.startswith("test_") and name.endswith(".py")) or name == "test_look.py":
            continue
        with open(os.path.join(HERE, name), encoding="utf-8") as fh:
            if re.search(r"^def test_look_", fh.read(), re.M):
                carriers.append(name)
    assert sorted(carriers) == sorted(LOOK_FILES), \
        f"files with test_look_* tests: {carriers}; started by test_look.py: " \
        f"{list(LOOK_FILES)}"

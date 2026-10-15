"""The look tests, run where they can be fast: in a FRESH interpreter (#647, #656).

Every ``test_look_*`` test in the files below measures what a person sees — at
the wizard's default window size, under two Qt styles, at the default font and at
8 pt — and skips in an ordinary run (``tests/_look.py`` says why: switching the
application style in a process that has already run other wizard tests takes minutes).
Here, ONE child pytest per file runs exactly those tests with ``HUGMESH_LOOK_CHILD=1``
and its verdict is this test's verdict, with the child's own output in the message.

A child that ran no look case at all (no Qt binding, neither style installed, a
renamed test) is not a pass: the verdict needs at least one case that PASSED.

    HUGMESH_LOOK_SHOTS=<dir> python -m pytest tests/test_look.py

also saves one PNG per case, so a reviewer can open what the test measured.
"""
import os
import re
import subprocess
import sys

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from _look import LOOK_CHILD_ENV  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
STUDIO_ROOT = os.path.dirname(HERE)

#: The test files that carry ``test_look_*`` tests. A new look test in another file
#: must be added here, or it would never run anywhere (test_every_look_test_is_run
#: below fails when a file carries one that is not listed).
LOOK_FILES = ("test_anubis_tristate_page.py", "test_localcloud_nodes.py",
              "test_pages_qemu.py", "test_pages_mesh_emulation.py",
              "test_look_editor.py")


def child_verdict(returncode: int, lines: list) -> str:
    """"" when a child's run counts as a pass; otherwise why it does not. A clean exit
    is not enough: a child whose every case SKIPPED (no style installed, the guard env
    lost) also exits 0, and nothing was looked at."""
    if returncode != 0:
        return f"the child exited {returncode}"
    summary = next((ln for ln in reversed(lines) if " passed" in ln), "")
    passed = re.search(r"(\d+) passed", summary)
    if not passed or int(passed.group(1)) == 0:
        return "the child ran no look case that passed"
    return ""


def test_a_look_run_needs_a_clean_exit_and_at_least_one_passing_case():
    assert child_verdict(0, ["....", "16 passed, 2 skipped in 9.1s"]) == ""
    assert child_verdict(1, ["1 failed, 15 passed in 9.1s"]) != ""   # a case failed
    assert child_verdict(0, ["16 skipped in 0.3s"]) != ""            # nothing looked at
    assert child_verdict(5, ["no tests ran in 0.1s"]) != ""          # nothing selected
    assert child_verdict(0, []) != ""


@pytest.mark.parametrize("fname", LOOK_FILES)
def test_the_looked_at_pages_are_drawn_whole_in_a_fresh_interpreter(fname):
    if os.environ.get(LOOK_CHILD_ENV) == "1":
        pytest.skip("this is the child interpreter; the parent runs this test")
    env = dict(os.environ)
    env[LOOK_CHILD_ENV] = "1"
    proc = subprocess.run(
        [sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider",
         "-k", "test_look_", "-rs", os.path.join(HERE, fname)],
        cwd=STUDIO_ROOT, env=env, capture_output=True, text=True, timeout=900)
    lines = [ln for ln in (proc.stdout + proc.stderr).splitlines()
             if "propagateSizeHints" not in ln]
    problem = child_verdict(proc.returncode, lines)
    assert not problem, f"{problem} in {fname}:\n" + "\n".join(lines[-60:])


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

"""A module-level ``pytest.importorskip`` must not sit ABOVE tests that do not need the module.

The pre-merge studio job installs no Qt binding on purpose, and a module-level importorskip there
skips the WHOLE module: every Qt-free test above it is never collected, nothing is red, nothing is
in known-failures.txt, and the only symptom is a skip count nobody reads. Two files had it (63 tests
that never ran before merge, hugmesh-generator#537). The right shapes are an importorskip INSIDE the
fixture the Qt tests use, a guarded import plus a marker on just those tests (what the two fixed files
do), or a file that is Qt from its first line.

This walks ``studio/tests/test_*.py`` and fails on any module-level importorskip with a test function
or test class above it.
"""
from __future__ import annotations

import ast
import glob
import os

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))


def _is_importorskip(node: ast.stmt) -> bool:
    value = None
    if isinstance(node, ast.Expr):
        value = node.value
    elif isinstance(node, (ast.Assign, ast.AnnAssign)):
        value = node.value
    return (isinstance(value, ast.Call)
            and getattr(value.func, "attr", getattr(value.func, "id", "")) == "importorskip")


def _is_test(node: ast.stmt) -> bool:
    return ((isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name.startswith("test_"))
            or (isinstance(node, ast.ClassDef) and node.name.startswith("Test")))


def offenders(source: str) -> list[tuple[int, int]]:
    """(importorskip line, number of tests above it) for each module-level importorskip that has tests above."""
    found: list[tuple[int, int]] = []
    tests_above = 0
    for node in ast.parse(source).body:
        if _is_test(node):
            tests_above += 1
        elif _is_importorskip(node) and tests_above:
            found.append((node.lineno, tests_above))
    return found


def test_no_test_module_skips_its_own_qt_free_tests():
    bad = []
    for path in sorted(glob.glob(os.path.join(HERE, "test_*.py"))):
        with open(path, encoding="utf-8") as fh:
            for line, n in offenders(fh.read()):
                bad.append(f"{os.path.basename(path)}:{line} ({n} test(s) above it)")
    assert not bad, (
        "a module-level pytest.importorskip skips every test above it in the job that has no such "
        "module (hugmesh-generator#537): move it into the fixture the tests need, or guard the import "
        "and mark just those tests. Offenders: " + "; ".join(bad))


# ── the detector itself bites ────────────────────────────────────────────────────────────────────
def test_a_module_level_importorskip_below_a_test_is_caught():
    src = "import pytest\n\ndef test_a():\n    pass\n\npytest.importorskip('x')\n"
    assert offenders(src) == [(6, 1)]


def test_the_assigned_form_is_caught_too():
    src = "import pytest\n\nclass TestA:\n    def test_a(self):\n        pass\n\nqt = pytest.importorskip('x')\n"
    assert offenders(src) == [(7, 1)]


@pytest.mark.parametrize("src", [
    # the whole file is Qt from its first line: nothing above it to hide
    "import pytest\npytest.importorskip('x')\n\ndef test_a():\n    pass\n",
    # inside a fixture: only the tests that ask for it skip
    "import pytest\n\n@pytest.fixture\ndef qapp():\n    pytest.importorskip('x')\n\ndef test_a():\n    pass\n",
    # helpers above are not tests
    "import pytest\n\ndef _helper():\n    pass\n\npytest.importorskip('x')\n\ndef test_a():\n    pass\n",
])
def test_the_correct_idioms_pass(src):
    assert offenders(src) == []

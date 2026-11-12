"""Guards over the Studio's Qt tests that need NO Qt binding, so the pull-request job
(.github/workflows/studio-tests.yml, which installs none) runs them.

On 2026-11-11 five Qt test files were red on main and nothing showed it: the pull
request job ignores six GUI files and importorskips the rest, so a GUI test passes
there whatever it does. Two of the five were exactly what a source read can catch, and
the guard for one of them already existed, inside a module that skipped for want of
Qt:

* the look census (a ``test_look_*`` test the look wrapper never starts) lived in
  tests/test_look.py, whose ``importorskip`` skipped it, and it was red;
* tests/test_windows_sweep_c5.py built its QApplication and dropped it, so the file
  aborted (rc 134) whenever it ran on its own.

The third guard pins the job that closes the gap for everything else: the Qt job in
studio-tests.yml, which runs every test file in its own interpreter with a binding
(tests/run_file_by_file.py).
"""
import ast
import os
import re

import pytest

from _look_files import LOOK_FILES
import run_file_by_file as rfbf

HERE = os.path.dirname(os.path.abspath(__file__))
STUDIO_ROOT = os.path.dirname(HERE)
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
WORKFLOW = os.path.join(GENERATOR_DIR, ".github", "workflows", "studio-tests.yml")


def _test_files(tests_dir=HERE):
    """Every test module pytest collects under tests/ (it recurses: journey/ too), as
    ``(path relative to tests/, source)``."""
    for root, dirs, files in os.walk(tests_dir):
        dirs[:] = sorted(d for d in dirs if not d.startswith((".", "__")))
        for name in sorted(files):
            if name.startswith("test_") and name.endswith(".py"):
                path = os.path.join(root, name)
                with open(path, encoding="utf-8") as fh:
                    yield os.path.relpath(path, tests_dir), fh.read()


def _calls(node, name: str) -> bool:
    """Whether ``name(...)`` (or ``x.name(...)``) is called anywhere under ``node``."""
    for n in ast.walk(node):
        if isinstance(n, ast.Call):
            f = n.func
            if (isinstance(f, ast.Name) and f.id == name) or \
                    (isinstance(f, ast.Attribute) and f.attr == name):
                return True
    return False


# ── 1. every look case is one the look wrapper runs ──────────────────────────────────
def look_census(sources, look_files) -> list:
    """What is wrong with the look cases in ``sources`` (``[(relpath, source)]``) against
    the wrapper's ``look_files``; ``[]`` when nothing is.

    The rules, each a way a look test ends up run by nobody or not looked with:

    * ``test_look_*`` is tests/test_look.py's prefix. Such a test must start with
      ``child_only()`` and live in a file the wrapper starts. Without ``child_only()`` it
      runs in an ordinary run at whatever style and font that process has, and in the
      wrapper's child a non-parametrized case gives the verdict no style to count; in a
      file the wrapper does not start, it skips for ever.
    * A test that calls ``child_only()`` under ANOTHER name (the ``test_geom_*`` files)
      is never selected by the wrapper's ``-k test_look_``, so its own file must start
      the fresh interpreter itself (it sets ``LOOK_CHILD_ENV`` for a child).
    * Every file the wrapper starts must exist and carry a look case, or its child runs
      nothing and the wrapper's verdict fails for a reason nobody can read at a glance.
    """
    problems = []
    carriers = set()
    for rel, src in sources:
        tree = ast.parse(src, filename=rel)
        starts_own_child = any(isinstance(n, ast.Name) and n.id == "LOOK_CHILD_ENV"
                               for n in ast.walk(tree))
        for fn in ast.walk(tree):
            if not isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef)) or \
                    not fn.name.startswith("test_"):
                continue
            child = _calls(fn, "child_only")
            where = f"{rel}::{fn.name}"
            if fn.name.startswith("test_look_"):
                if not child:
                    problems.append(f"{where} is named test_look_* but does not start with "
                                    "child_only(): it is not a look case (rename it, or "
                                    "make it one with LOOK_CASES and looking())")
                elif rel not in look_files:
                    problems.append(f"{where} is a look case in a file the look wrapper "
                                    "never starts: add the file to tests/_look_files.py")
                else:
                    carriers.add(rel)
            elif child and (rel in look_files or not starts_own_child):
                problems.append(f"{where} calls child_only() but is not named test_look_*, "
                                "and its file does not start a child of its own: it never "
                                "runs")
    names = {rel for rel, _src in sources}
    for rel in look_files:
        if rel not in names:
            problems.append(f"tests/_look_files.py names {rel}, which does not exist")
        elif rel not in carriers:
            problems.append(f"tests/_look_files.py names {rel}, which carries no look case")
    return problems


def test_every_look_case_is_run_by_the_look_wrapper():
    """The census over the real tree (journey/ too: pytest collects it)."""
    problems = look_census(list(_test_files()), LOOK_FILES)
    assert not problems, "\n".join(problems)


_CASE = '''
@pytest.mark.parametrize(("style", "pt"), LOOK_CASES, ids=LOOK_IDS)
def test_look_{name}(qapp, style, pt):
    child_only()
    with looking(qapp, style, pt):
        pass
'''
_NOT_A_CASE = '''
def test_look_{name}(qapp, wiz):
    assert wiz.isVisible()
'''
_GEOM = '''
def test_geom_{name}(qapp, style, pt):
    child_only()
'''
_OWN_CHILD = '''
def test_the_geometry_runs_in_a_fresh_interpreter():
    env = dict(os.environ)
    env[LOOK_CHILD_ENV] = "1"
'''


def test_the_census_names_each_way_a_look_case_goes_unrun():
    """The census against the shapes it must tell apart, so a census that read only one
    rule (the old one matched ``^def test_look_`` in top-level files) cannot pass."""
    ok = [("test_a.py", _CASE.format(name="a")),
          ("test_geom.py", _GEOM.format(name="g") + _OWN_CHILD),
          ("journey/test_model.py", "def test_design_choices():\n    pass\n")]
    assert look_census(ok, ("test_a.py",)) == []
    # a look case in a file nobody starts, in a subdirectory too
    for rel in ("test_b.py", "journey/test_b.py"):
        probs = look_census(ok + [(rel, _CASE.format(name="b"))], ("test_a.py",))
        assert len(probs) == 1 and rel in probs[0] and "never starts" in probs[0], probs
    # the #937 shape: the prefix on a test that is not a look case
    probs = look_census(ok + [("test_c.py", _NOT_A_CASE.format(name="c"))],
                        ("test_a.py", "test_c.py"))
    assert any("does not start with child_only()" in p for p in probs), probs
    probs = look_census(ok + [("journey/test_m.py", _NOT_A_CASE.format(name="m"))],
                        ("test_a.py",))
    assert len(probs) == 1 and "journey/test_m.py" in probs[0], probs
    # a geometry case whose file starts no child of its own
    probs = look_census(ok + [("test_d.py", _GEOM.format(name="d"))], ("test_a.py",))
    assert len(probs) == 1 and "never runs" in probs[0], probs
    # ...or that sits in a wrapper file, where -k test_look_ never selects it
    probs = look_census([("test_a.py", _CASE.format(name="a") + _GEOM.format(name="e")
                          + _OWN_CHILD)], ("test_a.py",))
    assert len(probs) == 1 and "never runs" in probs[0], probs
    # a listed file that is gone, or that carries no look case
    assert "does not exist" in look_census(ok, ("test_a.py", "test_gone.py"))[0]
    assert look_census(ok, ("test_a.py", "journey/test_model.py")) == [
        "tests/_look_files.py names journey/test_model.py, which carries no look case"]
    # a look case inside a class is still a look case
    cls = "class TestX:\n" + "\n".join("    " + ln for ln in
                                        _CASE.format(name="k").splitlines())
    probs = look_census(ok + [("test_k.py", cls)], ("test_a.py",))
    assert len(probs) == 1 and "never starts" in probs[0], probs


# ── 2. no test builds a QApplication and drops it ────────────────────────────────────
def _is_qapplication_ctor(node) -> bool:
    f = node.func if isinstance(node, ast.Call) else None
    return (isinstance(f, ast.Attribute) and f.attr == "QApplication") or \
        (isinstance(f, ast.Name) and f.id == "QApplication")


def dropped_qapplications(source: str, filename: str = "<src>") -> list:
    """Line numbers of statements that construct a QApplication and keep no reference:
    ``QApplication([...])`` or ``QApplication.instance() or QApplication([...])`` as a
    bare expression. The object is freed at once, and the next widget aborts the
    interpreter ("Fatal Python error: Aborted"), unless an earlier file in the same
    process happened to leave an application alive."""
    lines = []
    for node in ast.walk(ast.parse(source, filename=filename)):
        if not isinstance(node, ast.Expr):
            continue
        v = node.value
        parts = v.values if isinstance(v, ast.BoolOp) else [v]
        if any(_is_qapplication_ctor(p) for p in parts):
            lines.append(node.lineno)
    return lines


def test_no_test_file_drops_its_qapplication():
    found = [f"tests/{rel}:{ln}" for rel, src in _test_files()
             for ln in dropped_qapplications(src, rel)]
    assert not found, ("a QApplication built and dropped (keep a reference: a "
                       "module-level holder or a qapp fixture): " + ", ".join(found))


def test_the_dropped_qapplication_reader_reads_each_spelling():
    dropped = ('QtWidgets.QApplication.instance() or QtWidgets.QApplication(["c5"])\n'
               'QApplication([])\n'
               'qt.QtWidgets.QApplication.instance() or qt.QtWidgets.QApplication([])\n')
    assert dropped_qapplications(dropped) == [1, 2, 3]
    held = ('app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(["x"])\n'
            '_QAPP.append(QtWidgets.QApplication.instance() or QtWidgets.QApplication([]))\n'
            'return QtWidgets.QApplication.instance() or QtWidgets.QApplication([])\n'
            'QtWidgets.QApplication.processEvents()\n'
            'QtWidgets.QApplication.instance()\n')
    assert dropped_qapplications("def f():\n" + "".join("    " + ln + "\n"
                                                        for ln in held.splitlines())) == []


# ── 3. the runner the Qt job uses ────────────────────────────────────────────────────
def test_shards_run_every_file_exactly_once():
    files = [f"tests/test_{i:03d}.py" for i in range(17)]
    for n in (1, 2, 3, 4, 5):
        got = [f for k in range(1, n + 1) for f in rfbf.shard(files, f"{k}/{n}")]
        assert sorted(got) == files and len(got) == len(files), n
    for bad in ("0/3", "4/3", "1", "a/b", ""):
        with pytest.raises(ValueError):
            rfbf.shard(files, bad)


def test_the_runner_finds_every_file_pytest_collects():
    """journey/ included, helpers and the runner itself not."""
    cwd = os.getcwd()
    try:
        os.chdir(STUDIO_ROOT)
        found = rfbf.discover()
    finally:
        os.chdir(cwd)
    want = sorted(os.path.join("tests", rel) for rel, _src in _test_files())
    assert found == want
    assert any(p.startswith(os.path.join("tests", "journey", "")) for p in found)
    assert os.path.join("tests", "run_file_by_file.py") not in found


def test_a_file_passes_only_on_a_clean_exit_with_something_run():
    ok = "....\n4 passed in 1.0s\n"
    assert rfbf.verdict(0, ok, require_qt=True) == ""
    assert "timed out" in rfbf.verdict(None, "", require_qt=False)
    assert "died" in rfbf.verdict(134, "Fatal Python error: Aborted", require_qt=False)
    assert "died" in rfbf.verdict(-11, "", require_qt=False)
    assert rfbf.verdict(1, "1 failed", require_qt=False)
    assert rfbf.verdict(2, "1 error", require_qt=False)
    assert "no test ran" in rfbf.verdict(5, "no tests ran in 0.1s", require_qt=False)
    # a module that skipped itself whole (exit 5) is judged by its skip reason
    urwid = "SKIPPED [1] tests/test_tui_urwid.py:10: could not import 'urwid'\n1 skipped\n"
    assert rfbf.verdict(5, urwid, require_qt=True) == ""
    no_qt = "SKIPPED [1] tests/test_x.py:9: no Qt binding installed\n1 skipped in 0.1s\n"
    assert "missing Qt binding" in rfbf.verdict(5, no_qt, require_qt=True)


@pytest.mark.parametrize("reason", [
    "no Qt binding (PySide6/PyQt6) installed",
    "no Qt binding installed in this job",
    "dialog tests need a Qt binding",
    "could not import 'hugmesh_studio.gui.qt': No module named 'PySide6'",
])
def test_a_qt_job_whose_files_skip_for_want_of_qt_is_red(reason):
    out = f"s....\nSKIPPED [1] tests/test_x.py:12: {reason}\n4 passed, 1 skipped in 1s\n"
    assert rfbf.verdict(0, out, require_qt=False) == ""
    assert "missing Qt binding" in rfbf.verdict(0, out, require_qt=True)


def test_a_case_that_pins_one_binding_by_name_may_skip_under_the_other():
    """tests/test_never_elevate_guard.py pins PyQt6's qFatal and skips under PySide6 by
    design; and a look case skips an optional style. Neither is a blind Qt job."""
    out = ("SKIPPED [1] tests/test_never_elevate_guard.py:171: no PyQt6 binding installed "
           "(this case pins PyQt6's qFatal)\n"
           "SKIPPED [2] tests/_look.py:102: Qt style 'Breeze' is not installed here and is "
           "optional\n3 passed, 3 skipped in 1s\n")
    assert rfbf.verdict(0, out, require_qt=True) == ""


# ── 4. the Qt job is wired, file by file, over every shard ──────────────────────────
def _qt_job():
    yaml = pytest.importorskip("yaml")
    with open(WORKFLOW, encoding="utf-8") as fh:
        wf = yaml.safe_load(fh)
    jobs = [j for j in wf["jobs"].values()
            if any("run_file_by_file.py" in (s.get("run") or "") for s in j.get("steps", []))]
    assert len(jobs) == 1, "studio-tests.yml has no single job running run_file_by_file.py"
    return jobs[0]


def test_the_qt_job_runs_every_file_with_a_binding_and_refuses_a_blind_run():
    job = _qt_job()
    steps = job["steps"]
    runs = "\n".join(s.get("run") or "" for s in steps)
    assert "pip install" in runs and \
        re.search(r"\b(?:PySide6|pyside6-essentials|PyQt6)\b", runs), \
        "the Qt job installs no Qt binding: every GUI test would importorskip"
    env = {**(job.get("env") or {})}
    for s in steps:
        if "run_file_by_file.py" in (s.get("run") or ""):
            env.update(s.get("env") or {})
            call = s["run"]
            assert s.get("working-directory") == "studio", "the runner runs from studio/"
    assert env.get("QT_QPA_PLATFORM") == "offscreen"
    assert "--require-qt" in call, "without --require-qt a run that skipped all Qt is green"
    assert "${{ matrix.shard }}" in call
    # no file list: the runner discovers every file, so a new test file cannot be left out
    assert not re.search(r"\btests/\S+\.py\b", call.replace("tests/run_file_by_file.py", ""))
    # the shards cover 1..N, each once
    shards = job["strategy"]["matrix"]["shard"]
    n = len(shards)
    assert sorted(shards) == sorted(f"{k}/{n}" for k in range(1, n + 1)), shards
    assert job["strategy"].get("fail-fast") is False, \
        "one red shard must not cancel the others: their files would never report"

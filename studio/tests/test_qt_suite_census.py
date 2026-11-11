"""Checks over the Qt half of the Studio suite that need no Qt binding.

Every GUI test file importorskips Qt, so the Qt-free GitHub job (studio-tests.yml,
``pytest``) skips each one whole, and a check that lived inside one never ran there:
tests/test_look.py's census of the look cases went red on main and nothing showed it.
These read the test SOURCES with ``ast`` and import nothing from Qt, so they run on
every runner:

* every look case is started by a wrapper. A look case calls ``_look.child_only()`` and
  SKIPS in an ordinary run; it runs only in the fresh interpreter a wrapper starts with
  ``-k <selector>``. One that no wrapper selects is a test that never runs anywhere.
* no test builds a QApplication and drops it. ``QApplication.instance() or
  QApplication([...])`` as a bare statement leaves nothing holding the application:
  PyQt6 destroys it on the spot, the next QWidget aborts the interpreter, and every
  later test in the file goes unreported (PySide6 keeps a reference of its own, which
  is how tests/test_windows_sweep_c5.py stayed green on the Windows job and aborted
  when run alone under PyQt6).
"""
import ast
import functools
import os

from _look_files import LOOK_FILES

HERE = os.path.dirname(os.path.abspath(__file__))

#: The wrapper that starts the files in LOOK_FILES (tests/test_look.py).
LOOK_WRAPPER = "test_look.py"


@functools.lru_cache(maxsize=1)
def _sources() -> tuple:
    """(path relative to tests/, parsed module) for every .py file under tests/, parsed
    once per session (the checks below only read the trees)."""
    out = []
    for root, _dirs, files in os.walk(HERE):
        for name in sorted(files):
            if name.endswith(".py"):
                path = os.path.join(root, name)
                with open(path, encoding="utf-8") as fh:
                    out.append((os.path.relpath(path, HERE), ast.parse(fh.read(), path)))
    return tuple(sorted(out, key=lambda item: item[0]))


def _calls(node, name: str) -> bool:
    """Whether ``name(...)`` (or ``x.name(...)``) is called anywhere under ``node``."""
    for sub in ast.walk(node):
        if isinstance(sub, ast.Call):
            fn = sub.func
            if (isinstance(fn, ast.Name) and fn.id == name) or \
                    (isinstance(fn, ast.Attribute) and fn.attr == name):
                return True
    return False


def look_cases(tree) -> list:
    """The names of the functions that call ``child_only()``: the look cases."""
    return [fn.name for fn in ast.walk(tree)
            if isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef))
            and _calls(fn, "child_only")]


def k_selectors(tree) -> list:
    """The ``-k`` values a wrapper hands its child pytest: every string that follows a
    ``"-k"`` in a list or tuple literal."""
    out = []
    for node in ast.walk(tree):
        if isinstance(node, (ast.List, ast.Tuple)):
            elts = node.elts
            for a, b in zip(elts, elts[1:]):
                if isinstance(a, ast.Constant) and a.value == "-k" \
                        and isinstance(b, ast.Constant) and isinstance(b.value, str):
                    out.append(b.value)
    return out


def unstarted_look_cases(sources) -> list:
    """``file::case`` for every look case no wrapper starts. tests/test_look.py starts
    the cases its ``-k`` selects in the files LOOK_FILES names; a file with a wrapper
    of its own (``-k test_geom_`` over itself) starts the cases that selects."""
    by_file = dict(sources)
    wrapper = by_file.get(LOOK_WRAPPER)
    look_k = k_selectors(wrapper) if wrapper is not None else []
    missing = []
    for rel, tree in sources:
        if rel == "_look.py":
            continue
        own_k = [] if rel == LOOK_WRAPPER else k_selectors(tree)
        for case in look_cases(tree):
            by_look = rel in LOOK_FILES and any(k in case for k in look_k)
            by_own = any(k in case for k in own_k)
            if not (by_look or by_own):
                missing.append(f"{rel}::{case}")
    return missing


def dropped_qapplications(sources) -> list:
    """``file:line`` for every bare expression statement that constructs a
    QApplication: its value is thrown away, so nothing holds the application."""
    def builds_app(expr) -> bool:
        if isinstance(expr, ast.BoolOp):
            return any(builds_app(v) for v in expr.values)
        if isinstance(expr, ast.Call):
            fn = expr.func
            return (isinstance(fn, ast.Name) and fn.id == "QApplication") or \
                (isinstance(fn, ast.Attribute) and fn.attr == "QApplication")
        return False
    return [f"{rel}:{node.lineno}" for rel, tree in sources for node in ast.walk(tree)
            if isinstance(node, ast.Expr) and builds_app(node.value)]


# ── the census, on the real tree ─────────────────────────────────────────────────────
def test_every_look_case_is_started_by_a_wrapper():
    """A look case that no wrapper starts skips in every ordinary run, for ever."""
    sources = _sources()
    assert unstarted_look_cases(sources) == [], (
        "look cases no wrapper starts (add the file to tests/_look_files.py, or name the "
        "case so its file's own wrapper selects it): "
        f"{unstarted_look_cases(sources)}")


def test_every_listed_look_file_has_a_case_the_wrapper_selects():
    """The other direction, and the census's own real-cases check: a listed file that
    is gone, or holds no case ``-k test_look_`` selects, would make the wrapper's child
    run nothing (and the census above would pass while looking at nothing)."""
    by_file = dict(_sources())
    assert k_selectors(by_file[LOOK_WRAPPER]) == ["test_look_"], \
        "tests/test_look.py no longer starts its children with -k test_look_"
    for name in LOOK_FILES:
        assert name in by_file, f"tests/_look_files.py lists {name}, which does not exist"
        cases = [c for c in look_cases(by_file[name]) if "test_look_" in c]
        assert cases, f"{name} is listed but holds no look case named test_look_*"


def test_no_test_drops_its_qapplication():
    assert dropped_qapplications(_sources()) == [], (
        "a QApplication is built and dropped; hold it (a fixture that returns it, or a "
        "name that outlives the widgets): "
        f"{dropped_qapplications(_sources())}")


# ── the readers, on fixtures ─────────────────────────────────────────────────────────
def _src(text: str):
    return ast.parse(text)


def test_the_census_reader_finds_what_a_wrapper_would_miss():
    listed = LOOK_FILES[0]
    case = ("@pytest.mark.parametrize('style', ['Fusion'])\n"
            "def test_look_x(qapp, style):\n    child_only()\n")
    wrapper = _src("args = [sys.executable, '-m', 'pytest', '-k', 'test_look_', f]\n")
    # a listed file's test_look_ case is started; an unlisted file's is not
    assert unstarted_look_cases([(LOOK_WRAPPER, wrapper), (listed, _src(case))]) == []
    assert unstarted_look_cases([(LOOK_WRAPPER, wrapper), ("test_new.py", _src(case))]) \
        == ["test_new.py::test_look_x"]
    # a case in a listed file that -k test_look_ does not select
    geom = case.replace("test_look_x", "test_geom_x")
    assert unstarted_look_cases([(LOOK_WRAPPER, wrapper), (listed, _src(geom))]) \
        == [f"{listed}::test_geom_x"]
    # ... unless the file starts its own child with a selector that picks it
    own = geom + "def test_parent():\n    run(['pytest', '-k', 'test_geom_', __file__])\n"
    assert unstarted_look_cases([(LOOK_WRAPPER, wrapper), ("test_self.py", _src(own))]) \
        == []
    # a test that never calls child_only() is not a look case, whatever its name
    plain = "def test_look_choices_are_named():\n    assert True\n"
    assert look_cases(_src(plain)) == []
    assert unstarted_look_cases([(LOOK_WRAPPER, wrapper), ("journey/t.py", _src(plain))]) \
        == []


def test_the_dropped_qapplication_reader():
    flagged = ("def test_a():\n"
               "    QtWidgets.QApplication.instance() or QtWidgets.QApplication(['a'])\n"
               "def test_b():\n"
               "    QApplication([])\n")
    assert dropped_qapplications([("t.py", _src(flagged))]) == ["t.py:2", "t.py:4"]
    held = ("@pytest.fixture\n"
            "def qapp():\n"
            "    return QtWidgets.QApplication.instance() or QtWidgets.QApplication([])\n"
            "def test_c():\n"
            "    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])\n"
            "    _APPS.append(QtWidgets.QApplication.instance() or QApplication([]))\n"
            "def fx():\n"
            "    yield (QtWidgets.QApplication.instance() or QtWidgets.QApplication([]))\n")
    assert dropped_qapplications([("t.py", _src(held))]) == []

"""Background probes must be released, not just re-referenced.

An adversarial verifier caught this in the off-the-GUI-thread work (2026-08-14): the
probes were correctly held on the page so they could not be garbage-collected mid-run,
but each new probe simply REBOUND the attribute. Dropping the Python reference does not
destroy the C++ object when Qt's parent owns it, so every finished probe stayed a child
of the page — 50 QThread children after 50 verb cycles, unbounded over a session,
because the e2e gate re-probes on every verb start, every verb end and every page entry.

The cost is not memory. A probe still alive when its page is destroyed takes the Studio
down with a Qt qFatal, so every stranded thread widens that window. That is also why the
fix must CLEAR the attribute and not only schedule deletion: an in-flight guard calling
isRunning() on a deleted wrapper raises RuntimeError, and on PyQt6 a RuntimeError raised
inside a Qt slot aborts the process rather than propagating into Python.

2026-09-04: the window was CLOSED rather than narrowed. ``own_probe`` now un-parents the
thread and holds it in a module registry, because ``~QWidget`` deletes its children
inside its own body — before ``~QObject`` emits ``destroyed`` — so a page has no hook
with which to drain its probes first, and garbage collection drops pages at moments no
code chooses. Four test files aborted mid-file that way. The registry is what keeps the
first paragraph's hazard closed at the same time, and ``finished`` clears it, so the
accumulation guard below counts registry entries instead of page children.
"""

from __future__ import annotations

import pytest

from hugmesh_studio.gui.qt import QtCore, QtWidgets
from hugmesh_studio.gui.pages import _widgets
from hugmesh_studio.gui.pages._widgets import own_probe, probe_running


class _Tiny(QtCore.QThread):
    """A thread that finishes immediately — the lifecycle is what is under test."""

    def run(self):
        return


def _settle(qapp, thread=None):
    """Let the thread finish AND let Qt actually run the queued DeferredDelete."""
    if thread is not None:
        thread.wait(3000)
    for _ in range(3):
        qapp.processEvents()
        QtCore.QCoreApplication.sendPostedEvents(None, QtCore.QEvent.Type.DeferredDelete)
        qapp.processEvents()


@pytest.fixture(scope="session")
def qapp():
    # Same shape the other GUI suites use (test_flag_badges_gui.py): one application
    # per session, reused if pytest already created one.
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def owner(qapp):
    w = QtWidgets.QWidget()
    yield w
    w.deleteLater()


def _live_threads(obj) -> int:
    return len([c for c in obj.children() if isinstance(c, QtCore.QThread)])


class TestOwnProbe:
    def test_holds_the_probe_while_it_runs(self, owner):
        t = own_probe(owner, "_p", _Tiny(owner))
        assert getattr(owner, "_p") is t

    def test_clears_the_attribute_when_the_probe_finishes(self, qapp, owner):
        """So the next in-flight guard reads None instead of a dead wrapper."""
        t = own_probe(owner, "_p", _Tiny(owner))
        t.start()
        _settle(qapp, t)
        assert getattr(owner, "_p") is None

    def test_releases_the_cpp_object_so_children_do_not_accumulate(self, qapp, owner):
        """THE regression guard. Before the fix this ended at 25.

        The widget must gain no children (the original guard, which the un-parenting
        makes trivially true), and own_probe's registry must return to the size it
        started at — a DELTA, because a session-scoped qapp is shared with every other
        test in the run. Without the second half this now passes vacuously.
        """
        before = len(_widgets.in_flight_probes())
        for _ in range(25):
            t = own_probe(owner, "_p", _Tiny(owner))
            t.start()
            _settle(qapp, t)
        assert _live_threads(owner) == 0
        assert len(_widgets.in_flight_probes()) == before

    def test_the_probe_is_parented_to_nothing_and_held_by_the_module(self, qapp, owner):
        """The lifetime contract, both halves. A QThread CHILD is destroyed BY ~QWidget,
        which runs deleteChildren() before anything can drain it — that is the qFatal
        the un-parenting removes; and a QThread nothing holds is garbage-collected
        mid-run — which is why the module keeps a strong reference until it finishes.
        Every call site constructs with parent=owner, so both must be true after."""
        t = own_probe(owner, "_p", _Tiny(owner))
        assert t.parent() is None
        assert _live_threads(owner) == 0
        assert t in _widgets.in_flight_probes()
        t.start()
        _settle(qapp, t)
        assert t not in _widgets.in_flight_probes()

    def test_does_not_clear_an_attribute_that_was_reassigned(self, qapp, owner):
        """A stale probe finishing late must not null out its SUCCESSOR — that would
        make the in-flight guard report idle while a probe is genuinely running, and
        two concurrent probes would then race on the same widgets."""
        slow = own_probe(owner, "_p", _Tiny(owner))
        newer = own_probe(owner, "_p", _Tiny(owner))
        slow.start()
        _settle(qapp, slow)
        assert getattr(owner, "_p") is newer


class TestProbeRunning:
    def test_false_when_never_set(self, owner):
        assert probe_running(owner, "_missing") is False

    def test_false_when_cleared(self, qapp, owner):
        t = own_probe(owner, "_p", _Tiny(owner))
        t.start()
        _settle(qapp, t)
        assert probe_running(owner, "_p") is False

    def test_false_rather_than_RuntimeError_on_a_dead_wrapper(self, qapp, owner):
        """The abort path. A page torn down between finish and clear leaves a wrapper
        whose C++ object is gone; isRunning() on that raises RuntimeError, and inside a
        Qt slot PyQt6 turns that into qFatal."""
        t = _Tiny(owner)
        owner._p = t
        t.deleteLater()
        _settle(qapp)
        assert probe_running(owner, "_p") is False


class TestRealPagesUseIt:
    """The helper is only worth having if the known sites actually route through it —
    this is what stops the NEXT probe quietly reintroducing the leak. Every new probe
    attribute on these pages belongs in the list below."""

    @pytest.mark.parametrize("module,attr", [
        ("hugmesh_studio.gui.pages.localmesh", "_probe"),
        ("hugmesh_studio.gui.pages.localmesh", "_node_probe"),
        ("hugmesh_studio.gui.pages.localmesh", "_e2e_probe"),
        ("hugmesh_studio.gui.pages.localmesh", "_e2e_cat_probe"),
        ("hugmesh_studio.gui.pages.localmesh", "_creds_probe"),
        ("hugmesh_studio.gui.pages.localmesh", "_saved_probe"),
        ("hugmesh_studio.gui.pages.localmesh", "_monitor_probe"),
        ("hugmesh_studio.gui.pages.keyzip", "_fetch_worker"),
        ("hugmesh_studio.gui.pages.localcloud_nodes", "_k8s_probe"),
    ])
    def test_site_is_wired_through_own_probe(self, module, attr):
        import importlib
        import inspect
        src = inspect.getsource(importlib.import_module(module))
        assert f'own_probe(self, "{attr}"' in src, (
            f"{module}.{attr} is not routed through own_probe — a probe parented to the "
            f"page without it leaks on every cycle")

    def test_no_site_still_assigns_a_probe_directly(self):
        """Catches the shape that caused it: `self._x = SomeThread(..., parent=self)`."""
        import importlib
        import inspect
        import re
        for module in ("hugmesh_studio.gui.pages.localmesh",
                       "hugmesh_studio.gui.pages.keyzip"):
            src = inspect.getsource(importlib.import_module(module))
            bad = re.findall(r"self\._\w*(?:probe|worker)\s*=\s*_\w+\(", src)
            assert not bad, f"{module} assigns a probe without own_probe: {bad}"

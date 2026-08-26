"""A pressed button must never be indistinguishable from a broken one.

WHY THIS TEST EXISTS. _launch guards "one verb at a time" with

    if self._running:
        return

and the guard is correct — two concurrent `make` runs against one cluster would be
worse than a refusal. What was wrong is that it refused SILENTLY: no status text,
no log line, nothing. And because the buttons are re-armed only in _verb_done, any
verb that never reaches it leaves EVERY button on this page a no-op that reports
nothing at all.

The operator-visible symptom is then "I pressed Start DevOps lane and nothing
happened", with an empty log and an unchanged status bar — the least diagnosable
state this page can be in. Found while chasing exactly that report (2026-08-22);
the lane itself was healthy, devops_up returned ok=True end to end. That is
precisely why a silent refusal is expensive: it is indistinguishable from the
thing being broken, so it sends the reader to debug the wrong layer.

DELIBERATELY Qt-FREE. LocalMeshPage's constructor builds the whole page and starts
its probes, which is far more than this guard needs and does not survive a headless
run on every dev box. These drive the REAL LocalMeshPage._launch against a minimal
stand-in carrying only the attributes the guard touches — so the code under test is
production code, not a re-implementation of it.
"""
from __future__ import annotations

import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import pytest  # noqa: E402

# This file is deliberately Qt-FREE — it drives the real methods against
# stand-ins and never builds a widget — but importing the module they live in
# pulls gui.qt, and the pre-merge pytest job installs NO Qt binding. Skipping is
# the documented shape for that here (studio/tests/known-failures.txt header):
# these run in GitLab's fuller test:studio-suite job against PySide6. Skipping
# rather than being added to the workflow's --ignore list is the point: that list
# is for GUI files that ABORT in Qt teardown, which these cannot, so they should
# start gating the moment this job grows a binding.
pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding installed in this job")

from hugmesh_studio.gui.pages import localmesh  # noqa: E402


class _Text:
    def __init__(self) -> None:
        self.value = ""

    def setText(self, s) -> None:
        self.value = s

    def text(self):
        return self.value


class _Btn:
    def __init__(self, visible=False) -> None:
        self._v = visible

    def isVisible(self):
        return self._v


class _Stub:
    """Only what the refusal branch of _launch reads."""

    def __init__(self, running: bool, label: str = "", cancellable=False) -> None:
        self._running = running
        self._running_label = label
        self.status = _Text()
        self.cancel_btn = _Btn(cancellable)


def _launch(stub, label, fn):
    return localmesh.LocalMeshPage._launch(stub, label, fn)


def test_a_busy_page_says_so_instead_of_swallowing_the_click():
    s = _Stub(True, "Starting the DevOps lane")
    s.status.setText("SENTINEL")
    _launch(s, "Deleting the DevOps lane", lambda *a: (True, ""))
    assert s.status.text() != "SENTINEL", "the click was swallowed with no feedback"
    assert "Starting the DevOps lane" in s.status.text(), \
        f"the refusal must name the verb holding the page: {s.status.text()!r}"


def test_the_refusal_does_not_start_a_second_verb():
    # Saying so must not weaken the guard's actual job.
    s = _Stub(True, "Starting the DevOps lane")
    started = []
    _launch(s, "Deleting the DevOps lane", lambda *a: started.append(1))
    assert started == [], "a second verb ran while one was already running"


def test_it_offers_cancel_only_when_cancel_is_actually_available():
    # Telling an operator to press Cancel when no Cancel is on screen is a second
    # wrong answer, not a better message.
    busy = _Stub(True, "Starting the DevOps lane", cancellable=True)
    _launch(busy, "x", lambda *a: None)
    assert "Cancel" in busy.status.text()

    plain = _Stub(True, "Some buffered verb", cancellable=False)
    _launch(plain, "x", lambda *a: None)
    assert "Cancel" not in plain.status.text()


def test_an_unnamed_holder_still_produces_a_sentence():
    # _running set with no label (a path that forgot to set one) must not render
    # "Still running: ." — the fallback has to read as English.
    s = _Stub(True, "")
    _launch(s, "x", lambda *a: None)
    assert s.status.text().strip()
    assert "Still running: ." not in s.status.text()


def test_an_idle_page_is_not_refused():
    # VACUITY GUARD. If the refusal branch were taken unconditionally, every test
    # above would pass while the page never launched anything again. An idle stub
    # must get PAST the guard — proven by _running flipping true before the method
    # runs on into the Qt work this stand-in deliberately cannot serve.
    s = _Stub(False)
    try:
        _launch(s, "Some verb", lambda *a: (True, ""))
    except Exception:
        pass
    assert s._running is True, "an idle page took the refusal path — the guard inverted"
    assert s.status.text() == "" or "Still running" not in s.status.text()


def test_launch_records_which_verb_it_started():
    # The message above can only name the holder if _launch WROTE the name. Every
    # other test here pre-sets _running_label on the stub, so without this one,
    # deleting `self._running_label = label` from _launch left the whole file green
    # — the refusal would silently regress to "a previous step" forever. (Found by
    # mutation, 2026-08-22: a test that supplies the value it is checking proves
    # only that the reader works.)
    s = _Stub(False)
    try:
        _launch(s, "Starting the DevOps lane", lambda *a: (True, ""))
    except Exception:
        pass
    assert s._running_label == "Starting the DevOps lane", \
        f"_launch did not record the running verb: {s._running_label!r}"

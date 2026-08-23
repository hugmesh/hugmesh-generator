"""A verb's output must survive the run that produced it.

WHY THIS TEST EXISTS. A verb's output used to live ONLY in _StageRun.buffer and
the log pane — both in memory, both gone when the Studio closes. Under a desktop
launcher the Studio's own stdout goes to /dev/null, so when an operator reported
"the DevOps lane fails" there was no artifact anywhere on disk to read. The verb
had already run, at length, and its evidence was discarded; the only way forward
was to ask them to reproduce it and copy the pane by hand.

That is the whole cost being fixed: a long, expensive, already-completed run whose
failure cannot be examined afterwards. Reproducing a 10-minute cluster bring-up to
recover output it already produced is not a diagnosis, it is a tax.

Qt-FREE on purpose: LocalMeshPage's constructor builds the whole page and starts
its probes. _save_run_log touches nothing on self, so these drive the REAL method
against a stand-in — production code under test, not a re-implementation.
"""
from __future__ import annotations

import os
from collections import deque

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from hugmesh_studio.gui.pages import localmesh  # noqa: E402


class _Run:
    def __init__(self, label, lines):
        self.label = label
        self.buffer = deque(lines)


def _save(tmp_path, monkeypatch, run, ok):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path))
    return localmesh.LocalMeshPage._save_run_log(object(), run, ok)


def test_the_output_is_on_disk_afterwards(tmp_path, monkeypatch):
    run = _Run("Starting the DevOps lane", ["==> creating cluster", "boom: it failed"])
    p = _save(tmp_path, monkeypatch, run, False)
    assert p and os.path.isfile(p), "no log file was written"
    body = open(p, encoding="utf-8").read()
    assert "boom: it failed" in body, "the failing line is not in the saved log"
    assert "==> creating cluster" in body


def test_the_filename_says_whether_it_failed(tmp_path, monkeypatch):
    # So a directory listing is triage. Without this you open every file to find
    # the one that matters.
    bad = _save(tmp_path, monkeypatch, _Run("Start", ["x"]), False)
    good = _save(tmp_path, monkeypatch, _Run("Start", ["x"]), True)
    assert "FAILED" in os.path.basename(bad)
    assert "FAILED" not in os.path.basename(good)


def test_a_label_with_path_characters_cannot_escape_the_log_dir(tmp_path, monkeypatch):
    # Labels are developer-authored today, but a label is a STRING that becomes a
    # FILENAME; "../" in one must not write outside the log directory.
    p = _save(tmp_path, monkeypatch, _Run("../../etc/evil", ["x"]), True)
    assert p
    logs = os.path.join(str(tmp_path), "logs")
    assert os.path.abspath(p).startswith(os.path.abspath(logs)), \
        f"the log escaped its directory: {p}"


def test_an_unwritable_state_dir_returns_empty_and_never_raises(tmp_path, monkeypatch):
    # This runs on the FINISH path of every verb. Raising here would turn a
    # successful bring-up into a crash, which is far worse than no log file.
    blocked = tmp_path / "blocked"
    blocked.write_text("i am a file, not a directory")
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(blocked))
    assert localmesh.LocalMeshPage._save_run_log(object(), _Run("Start", ["x"]), True) == ""


def test_an_empty_run_still_writes_something_readable(tmp_path, monkeypatch):
    # A verb that failed having emitted NOTHING is exactly the case worth keeping:
    # "zero lines" is itself the finding, and an absent file is indistinguishable
    # from the save having broken.
    p = _save(tmp_path, monkeypatch, _Run("Start", []), False)
    assert p and os.path.isfile(p)
    body = open(p, encoding="utf-8").read()
    assert "FAILED" in body and "0 line(s)" in body

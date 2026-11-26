"""One row model for a build session's list and status text, owned by core.

The Previous builds table (GUI), the sessions review (TUI) and ``--list-sessions`` each
worded a "running" record whose process is gone their own way ("running (stale?)",
"running (process gone — likely interrupted)", "running (process gone)"), and the GUI
re-derived the failed-image count, the images cell and the row's time itself. These
tests pin the shared functions in core/build_sessions.py and hold the faces to them.

Qt-free; the table cells themselves are checked in test_pages_sessions.py.
"""
from __future__ import annotations

import ast
import os
import subprocess
import sys

import pytest

from hugmesh_studio.core import build_sessions as bs
from hugmesh_studio.core.config import ImageConfig
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry, synthesize
from hugmesh_studio.tui import model

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACKAGE = os.path.join(STUDIO_ROOT, "hugmesh_studio")


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def _one_image(tmp_path):
    return synthesize(ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                                  brand="acme", output_dir=str(tmp_path / "out")))


def _two_images(tmp_path):
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                       output_dir=str(tmp_path / "out"))
    return WorklistConfig(base=base, entries=[
        WorklistEntry(role="pki", platform="x86"),
        WorklistEntry(role="backend", platform="rpi5"),
    ])


def _stale(tmp_path):
    """A running record whose recorded pid has exited on this host."""
    s = bs.new_session(_one_image(tmp_path), str(tmp_path))
    bs.start(s)
    proc = subprocess.Popen([sys.executable, "-c", "pass"])
    proc.wait()
    s.pid = proc.pid
    bs.save(s)
    return s


def test_the_stale_phrase_is_the_documented_one():
    assert bs.STALE_STATUS == "running (process gone — likely interrupted)"


def test_a_live_running_record_reads_running(tmp_path):
    s = bs.new_session(_one_image(tmp_path), str(tmp_path))
    bs.start(s)                                         # our own live pid
    assert bs.display_status(s) == "running"
    assert bs.status_summary(s) == "running"


def test_a_running_record_whose_process_is_gone_reads_the_stale_phrase(tmp_path):
    s = _stale(tmp_path)
    assert bs.display_status(s) == bs.STALE_STATUS
    assert bs.status_summary(s) == bs.STALE_STATUS
    assert bs.load(s.path()).status == "running"        # a render hint: never written back


def test_a_caller_that_already_asked_is_not_made_to_probe_again(tmp_path, monkeypatch):
    s = bs.new_session(_one_image(tmp_path), str(tmp_path))
    bs.start(s)

    def boom(_s):
        raise AssertionError("is_stale was asked although the caller passed stale=")
    monkeypatch.setattr(bs, "is_stale", boom)
    assert bs.display_status(s, stale=True) == bs.STALE_STATUS
    assert bs.display_status(s, stale=False) == "running"
    assert bs.status_summary(s, stale=True) == bs.STALE_STATUS


def test_a_failed_session_says_how_many_images_failed(tmp_path):
    s = bs.new_session(_two_images(tmp_path), str(tmp_path))
    bs.start(s)
    bs.update_image(s, 0, status="ok", exit_code=0)
    bs.update_image(s, 1, status="failed", exit_code=1)
    bs.finish(s, "failed")
    assert bs.image_counts(s) == (1, 1, 2)
    assert bs.status_summary(s) == "failed · 1 of 2 images"
    assert bs.images_summary(s) == "1/2 ok"
    # the plain display status stays the bare word (the text UI's and the CLI's)
    assert bs.display_status(s) == "failed"


def test_a_failed_session_with_no_image_rows_is_just_failed(tmp_path):
    s = bs.new_session(_one_image(tmp_path), str(tmp_path))
    s.images = []
    s.status = "failed"
    assert bs.status_summary(s) == "failed"
    assert bs.images_summary(s) == "0/0 ok"


@pytest.mark.parametrize("status", ["complete", "stopped", "unknown"])
def test_the_other_statuses_read_as_recorded(tmp_path, status):
    s = bs.new_session(_one_image(tmp_path), str(tmp_path))
    s.status = status
    assert bs.status_summary(s) == status == bs.display_status(s)


def test_the_row_time_is_started_else_created_else_nothing(tmp_path):
    s = bs.new_session(_one_image(tmp_path), str(tmp_path))
    s.created, s.started = "2026-01-02T03:04:05+00:00", ""
    assert bs.session_when(s) == "2026-01-02T03:04:05+00:00"
    s.started = "2026-01-02T03:10:00+00:00"
    assert bs.session_when(s) == "2026-01-02T03:10:00+00:00"
    s.created = s.started = ""
    assert bs.session_when(s) == ""


def test_the_text_ui_and_the_cli_word_a_stale_record_as_core_does(tmp_path):
    s = _stale(tmp_path)
    assert model.STALE_STATUS is bs.STALE_STATUS
    assert model.display_status(s) == bs.STALE_STATUS
    (row,), _ = model.session_rows()
    assert row.status == bs.STALE_STATUS
    assert f"  {bs.STALE_STATUS}  " in bs.format_session_line(s)    # was "(process gone)"


def test_the_cli_line_still_shows_the_start_time_or_a_dash(tmp_path):
    s = bs.new_session(_one_image(tmp_path), str(tmp_path))
    s.created = s.started = ""
    assert bs.format_session_line(s).split("  ")[1] == "-"


STALE_SPELLINGS = ("running (stale?)", "running (process gone")


def _string_literals(source: str):
    """Every string constant in ``source`` that is NOT a docstring: the text a face can
    put on screen (comments and docstrings may name the phrase in passing)."""
    tree = ast.parse(source)
    docstrings = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            first = node.body[0] if node.body else None
            if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant):
                docstrings.add(id(first.value))
    for node in ast.walk(tree):
        if (isinstance(node, ast.Constant) and isinstance(node.value, str)
                and id(node) not in docstrings):
            yield node.value


def _front_end_sources():
    for sub in ("gui", "tui"):
        for root, _dirs, files in os.walk(os.path.join(PACKAGE, sub)):
            for name in files:
                if name.endswith(".py"):
                    path = os.path.join(root, name)
                    with open(path, encoding="utf-8") as fh:
                        yield os.path.relpath(path, PACKAGE), fh.read()


def _offenders(sources):
    return [(rel, spelling) for rel, text in sources
            for lit in _string_literals(text) for spelling in STALE_SPELLINGS
            if spelling in lit]


def test_no_front_end_words_the_stale_status_itself():
    """GUI and TUI read build_sessions.STALE_STATUS; a string literal of the phrase in a
    face is a copy that can drift again."""
    sources = list(_front_end_sources())
    assert len(sources) > 20, "the walk found no front-end files"
    assert not _offenders(sources), _offenders(sources)


def test_the_scan_catches_a_planted_copy_and_ignores_prose():
    for spelling in STALE_SPELLINGS:
        assert _offenders([("gui/pages/x.py", f'TEXT = "{spelling} — x"\n')]) == [
            ("gui/pages/x.py", spelling)]
    # a docstring and a comment may name the phrase; only a literal that is shown counts
    prose = f'''"""The cell reads {STALE_SPELLINGS[0]}."""\n# {STALE_SPELLINGS[1]} ...\nX = 1\n'''
    assert _offenders([("gui/pages/x.py", prose)]) == []

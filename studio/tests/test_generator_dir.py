"""Which checkout the Studio drives (issue #827 group 2). Qt-free.

The MSI's Start Menu shortcut starts the Studio in its install folder, and the old
fallback was os.getcwd(), so on Windows every build said "builder script
build-x86-host-stage4.sh not found in C:\\...\\HugMesh\\Image Studio" and nothing in the GUI
could choose another folder.
"""
from __future__ import annotations

import os
import types

import pytest

from hugmesh_studio import app
from hugmesh_studio.core import generator_dir


def _checkout(path):
    path.mkdir(parents=True, exist_ok=True)
    (path / generator_dir.MARKER).write_text("#!/bin/bash\n")
    return str(path)


@pytest.fixture
def elsewhere(tmp_path, monkeypatch):
    """Start where the MSI shortcut does: in a folder with no checkout near it."""
    cwd = tmp_path / "Image Studio"
    cwd.mkdir()
    monkeypatch.chdir(cwd)
    monkeypatch.delenv(generator_dir.ENV, raising=False)
    return str(cwd)


def test_the_install_folder_is_still_the_last_resort(elsewhere, tmp_path):
    assert generator_dir.resolve(str(tmp_path / "no-repo")) == elsewhere


def test_a_source_run_finds_its_own_repo(elsewhere, tmp_path):
    repo = _checkout(tmp_path / "repo")
    assert generator_dir.resolve(repo) == repo


def test_the_environment_wins(elsewhere, tmp_path, monkeypatch):
    other = _checkout(tmp_path / "other")
    monkeypatch.setenv(generator_dir.ENV, other)
    assert generator_dir.resolve(_checkout(tmp_path / "repo")) == other


def test_the_saved_choice_is_used_only_while_it_is_a_checkout(elsewhere, tmp_path):
    picked = _checkout(tmp_path / "hugmesh-generator")
    generator_dir.save(picked)
    assert generator_dir.saved() == picked
    assert generator_dir.resolve("") == picked
    os.remove(os.path.join(picked, generator_dir.MARKER))      # moved / deleted since
    assert generator_dir.resolve("") == elsewhere


def test_the_message_says_what_is_missing():
    said = generator_dir.not_a_checkout_message(r"C:\Program Files\HugMesh")
    assert generator_dir.MARKER in said and "hugmesh-generator" in said


class _FakeQt:
    """Just enough of QtWidgets for app._choose_generator_dir: the message box answers
    with ``answers`` in turn ("pick" or "cancel") and the folder dialog returns ``dirs``."""

    def __init__(self, answers, dirs):
        answers, dirs = list(answers), list(dirs)
        self.shown = []
        qt = self

        class Box:
            Icon = types.SimpleNamespace(Information=0)
            ButtonRole = types.SimpleNamespace(AcceptRole=0)
            StandardButton = types.SimpleNamespace(Cancel=1)

            def __init__(self, _icon, _title, text):
                qt.shown.append(text)
                self._ok = object()
                self._cancel = object()

            def addButton(self, *a):
                return self._ok if isinstance(a[0], str) else self._cancel

            def exec(self):
                self._clicked = self._ok if answers.pop(0) == "pick" else self._cancel

            def clickedButton(self):
                return self._clicked

        self.QMessageBox = Box
        self.QFileDialog = types.SimpleNamespace(
            getExistingDirectory=lambda *a: dirs.pop(0))


def test_the_gui_asks_until_it_gets_a_checkout_and_remembers_it(elsewhere, tmp_path):
    good = _checkout(tmp_path / "hugmesh-generator")
    qt = _FakeQt(["pick", "pick"], [str(tmp_path), good])     # a wrong folder first
    assert app._choose_generator_dir(elsewhere, qt) == good
    assert len(qt.shown) == 2 and str(tmp_path) in qt.shown[1]
    assert generator_dir.saved() == good


def test_a_cancel_keeps_the_folder_and_saves_nothing(elsewhere):
    qt = _FakeQt(["cancel"], [])
    assert app._choose_generator_dir(elsewhere, qt) == elsewhere
    assert generator_dir.saved() == ""


def test_a_checkout_is_never_asked_about(tmp_path):
    good = _checkout(tmp_path / "repo")
    qt = _FakeQt([], [])
    assert app._choose_generator_dir(good, qt) == good and qt.shown == []

"""Which checkout the Studio drives (issue #827 group 2). Qt-free.

The MSI's Start Menu shortcut starts the Studio in its install folder, and the old
fallback was os.getcwd(), so on Windows every build said "builder script
build-x86-host-stage4.sh not found in C:\\...\\HugMesh\\Image Studio" and nothing in the GUI
could choose another folder.
"""
from __future__ import annotations

import os
import sys
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


def test_a_working_directory_that_is_a_checkout_beats_the_saved_choice(tmp_path, monkeypatch):
    # `cd checkout-B && hugmesh-studio-cli --print-command ...` drove B before the saved
    # pick existed; a folder picked once for the MSI shortcut must not take that over.
    monkeypatch.delenv(generator_dir.ENV, raising=False)
    generator_dir.save(_checkout(tmp_path / "A"))
    b = _checkout(tmp_path / "B")
    monkeypatch.chdir(b)
    assert generator_dir.resolve(str(tmp_path / "no-repo")) == b


def test_an_environment_value_that_is_no_checkout_is_ignored(elsewhere, tmp_path, monkeypatch):
    repo = _checkout(tmp_path / "repo")
    monkeypatch.setenv(generator_dir.ENV, str(tmp_path / "gone"))     # stale profile value
    assert generator_dir.resolve(repo) == repo
    # ... and it does not hide the folder the picker saved, or the picker would come
    # back on every start
    picked = _checkout(tmp_path / "picked")
    generator_dir.save(picked)
    assert generator_dir.resolve("") == picked


def test_a_relative_environment_value_after_the_nix_cd_falls_back_to_the_source_tree(
        tmp_path, monkeypatch):
    # flake.nix: cd "${HUGMESH_GENERATOR_DIR:-$PWD}" and exec Python with it still set, so
    # a relative "hg" is resolved again inside hg/ and names hg/hg.
    repo = _checkout(tmp_path / "hg")
    monkeypatch.chdir(repo)
    monkeypatch.setenv(generator_dir.ENV, "hg")
    assert generator_dir.resolve(repo) == repo


def test_the_message_says_what_is_missing():
    said = generator_dir.not_a_checkout_message(r"C:\Program Files\HugMesh")
    assert generator_dir.MARKER in said and "hugmesh-generator" in said


def test_the_message_names_the_install_the_operator_runs():
    # the picker also runs on Linux (pip, Flatpak, the release tarball, a source run given
    # a --generator-dir that is no checkout), none of which is the Windows installer
    assert "Windows installer" in generator_dir.not_a_checkout_message("x", osname="nt")
    linux = generator_dir.not_a_checkout_message("/home/u", osname="posix")
    assert "Windows" not in linux and "the Studio itself does not include them" in linux


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


def test_a_checkout_is_never_asked_about_and_not_saved(tmp_path):
    # a --generator-dir or source-tree checkout was not picked in the GUI; saving it would
    # make a one-off flag the default of every later non-source launch
    good = _checkout(tmp_path / "repo")
    qt = _FakeQt([], [])
    assert app._choose_generator_dir(good, qt) == good and qt.shown == []
    assert generator_dir.saved() == ""


def test_a_folder_name_that_cannot_be_saved_still_starts_the_gui(elsewhere, tmp_path):
    # Non-UTF-8 bytes in a Linux path decode to a lone surrogate (an unpaired one on
    # Windows); the UTF-8 save raises UnicodeEncodeError, a ValueError, not an OSError.
    odd = _checkout(tmp_path / "g\udcff")
    qt = _FakeQt(["pick"], [odd])
    assert app._choose_generator_dir(elsewhere, qt) == odd
    assert generator_dir.saved() == ""


# ── main()'s wiring, with every Qt piece faked so this file stays Qt-free ──────────────

class _Recorder:
    def __init__(self):
        self.events = []


def _fake_gui(monkeypatch, rec, *, primary=True):
    """Fake the modules main() imports for its GUI section, and record the order of the
    instance handshake, the folder question and the shell it builds."""
    import hugmesh_studio.gui as gui_pkg
    from hugmesh_studio.core import instance

    class QApplication:
        def __init__(self, _argv):
            pass

        def __getattr__(self, _name):           # setApplicationName and friends
            return lambda *a, **k: None

        def exec(self):
            rec.events.append("exec")
            return 0

    qtwidgets = types.SimpleNamespace(
        QApplication=QApplication,
        QSystemTrayIcon=types.SimpleNamespace(isSystemTrayAvailable=lambda: False))

    class Shell:
        def __init__(self, folder, **_kw):
            rec.events.append(("shell", folder))

        def __getattr__(self, _name):           # install_quit_guard, open_or_raise, ...
            return lambda *a, **k: None

    def ask():
        rec.events.append("ask-already-running")
        return "nothing"

    fakes = {
        "qt": types.SimpleNamespace(QtWidgets=qtwidgets, BINDING="fake"),
        "branding_icon": types.SimpleNamespace(brand_icon=lambda: None),
        "shell": types.SimpleNamespace(StudioShell=Shell, ask_already_running=ask,
                                       CHOICE_NEW_WINDOW="new", CHOICE_RESET="reset"),
    }
    for name, module in fakes.items():
        monkeypatch.setitem(sys.modules, f"hugmesh_studio.gui.{name}", module)
        monkeypatch.setattr(gui_pkg, name, module, raising=False)

    class Server:
        def start(self):
            rec.events.append("handshake")
            return primary

    monkeypatch.setattr(instance, "InstanceServer", Server)
    monkeypatch.setattr(instance, "send", lambda *a: None)

    def choose(current, _qt):
        rec.events.append(("choose", current))
        return current + "-picked"

    monkeypatch.setattr(app, "_choose_generator_dir", choose)


def test_main_asks_after_the_handshake_and_builds_the_shell_on_the_answer(
        elsewhere, monkeypatch):
    rec = _Recorder()
    _fake_gui(monkeypatch, rec)
    assert app.main(["--generator-dir", elsewhere]) == 0
    assert rec.events[:3] == ["handshake", ("choose", elsewhere),
                              ("shell", elsewhere + "-picked")]


def test_a_second_default_launch_is_never_asked(elsewhere, monkeypatch):
    rec = _Recorder()
    _fake_gui(monkeypatch, rec, primary=False)
    assert app.main(["--generator-dir", elsewhere]) == 0
    assert rec.events == ["handshake", "ask-already-running"]


@pytest.mark.parametrize("flag", ["--tray", "--stack-tray"])
def test_a_tray_only_launch_never_blocks_on_the_question(elsewhere, monkeypatch, flag):
    rec = _Recorder()
    _fake_gui(monkeypatch, rec)
    assert app.main([flag, "--generator-dir", elsewhere]) == 0
    assert ("shell", elsewhere) in rec.events
    assert not any(isinstance(e, tuple) and e[0] == "choose" for e in rec.events)

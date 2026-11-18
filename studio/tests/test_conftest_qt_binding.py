"""conftest's Qt hooks find the binding the Studio actually loaded.

They looked up ``PyQt6.*`` only, so under PySide6 (what CI and the MSI run) the
end-of-session probe drain, the per-test QApplication pin and the post-cancel pump were
all silently skipped, and a probe still running at exit aborted the run after every
test had passed (``QThread: Destroyed while thread is still running``, exit 0xC0000409
on Windows: tests/test_domains_row_checks_saved_door.py, 10 of 18 runs under load).
"""
from __future__ import annotations

import sys
import types

import pytest

pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

import conftest                                                       # noqa: E402
from hugmesh_studio.gui import qt                                     # noqa: E402


def test_the_hooks_see_the_loaded_binding():
    assert qt.BINDING in ("PySide6", "PyQt6")
    assert conftest._qt_module("QtCore") is sys.modules[f"{qt.BINDING}.QtCore"]
    assert conftest._qt_module("QtWidgets") is sys.modules[f"{qt.BINDING}.QtWidgets"]


def test_the_drain_finds_the_running_application():
    app = qt.QtWidgets.QApplication.instance() or qt.QtWidgets.QApplication([])
    assert conftest._live_qapplication() is app


def test_no_binding_loaded_means_none_and_nothing_imported(monkeypatch):
    for name in list(sys.modules):
        if name.split(".")[0] in ("PySide6", "PyQt6") or name == "hugmesh_studio.gui.qt":
            monkeypatch.delitem(sys.modules, name)
    assert conftest._qt_module("QtCore") is None
    assert conftest._live_qapplication() is None
    assert not any(n.split(".")[0] in ("PySide6", "PyQt6") for n in sys.modules)


def test_the_shims_choice_wins_when_both_are_loaded(monkeypatch):
    pyside, pyqt = types.ModuleType("PySide6.QtCore"), types.ModuleType("PyQt6.QtCore")
    monkeypatch.setitem(sys.modules, "PySide6.QtCore", pyside)
    monkeypatch.setitem(sys.modules, "PyQt6.QtCore", pyqt)
    monkeypatch.setitem(sys.modules, "hugmesh_studio.gui.qt",
                        types.SimpleNamespace(BINDING="PyQt6"))
    assert conftest._qt_module("QtCore") is pyqt
    monkeypatch.setitem(sys.modules, "hugmesh_studio.gui.qt",
                        types.SimpleNamespace(BINDING="PySide6"))
    assert conftest._qt_module("QtCore") is pyside

"""Qt binding shim — prefer PySide6 (LGPL, easy Windows packaging), fall back to PyQt6.
Both are Qt6 with scoped enums, so the rest of the GUI is binding-agnostic.
"""
from __future__ import annotations

BINDING = ""
try:
    from PySide6 import QtCore, QtGui, QtWidgets  # type: ignore
    from PySide6.QtCore import Qt, Signal  # noqa: F401
    BINDING = "PySide6"
except ImportError:  # pragma: no cover - environment dependent
    from PyQt6 import QtCore, QtGui, QtWidgets  # type: ignore
    from PyQt6.QtCore import Qt  # noqa: F401
    from PyQt6.QtCore import pyqtSignal as Signal  # noqa: F401
    BINDING = "PyQt6"

__all__ = ["QtCore", "QtGui", "QtWidgets", "Qt", "Signal", "BINDING"]

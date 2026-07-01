"""Make the snapdragon_studio package importable for the studio test suite.

These tests target the pure-Python core (config / keyzip / validate) and do NOT
need PySide6, so they run in plain CI without the GUI toolkit installed.
"""
import os
import sys

# studio/ is the package root (contains snapdragon_studio/).
_STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _STUDIO_ROOT not in sys.path:
    sys.path.insert(0, _STUDIO_ROOT)

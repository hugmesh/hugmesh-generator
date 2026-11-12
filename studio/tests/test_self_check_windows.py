"""``--self-check`` on native Windows (part of the Windows contract in studio-tests.yml).

Found 2026-11-12 on Windows 11 by running ``python -m hugmesh_studio --self-check`` from a
checkout: every shipped .sh was reported as "bash -n failed: ... No such file or
directory", because the ``bash`` on PATH was C:\\Windows\\System32\\bash.exe (the WSL
launcher), which strips the backslashes out of a C:\\ path. Native Windows runs none of
these scripts, so the parse is skipped there and said, not counted.
"""
from __future__ import annotations

import os
import subprocess

from hugmesh_studio.core import self_check

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


def _as_windows(monkeypatch):
    monkeypatch.setattr(self_check.platform_info, "host_kind", lambda *a, **k: "windows")


def test_native_windows_does_not_parse_scripts_with_whatever_bash_is_on_path(monkeypatch):
    _as_windows(monkeypatch)
    ran = []
    real = subprocess.run
    monkeypatch.setattr(self_check.subprocess, "run",
                        lambda argv, *a, **k: ran.append(argv) or real(argv, *a, **k))
    report = self_check.check(GENERATOR_DIR)
    assert report["scripts_parsed"] == 0 and report["scripts_skipped"] > 0
    assert not report["syntax_errors"]
    assert not [p for p in report["problems"] if p.startswith("bash -n failed")]
    assert not any(a[:2] == ["bash", "-n"] for a in ran)
    assert "macos" not in report


def test_native_windows_self_check_passes_from_a_checkout_and_says_why(monkeypatch, capsys):
    _as_windows(monkeypatch)
    assert self_check.run_cli(GENERATOR_DIR) == 0
    out = capsys.readouterr().out
    assert "scripts not parsed: native Windows runs no bash scripts" in out
    assert out.rstrip().endswith("ok")


def test_linux_still_parses_the_scripts(monkeypatch):
    monkeypatch.setattr(self_check.platform_info, "host_kind", lambda *a, **k: "linux")
    monkeypatch.setattr(self_check.subprocess, "run",
                        lambda argv, *a, **k: subprocess.CompletedProcess(argv, 0, "", ""))
    report = self_check.check(GENERATOR_DIR)
    assert report["scripts_parsed"] > 0 and "scripts_skipped" not in report

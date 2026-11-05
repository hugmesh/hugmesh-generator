"""Every `make` verb of the local stack refuses on native Windows, not only the start.

Measured on the Windows sweep (2026-10-30, branch win/studio-windows-sweep-20261030):
``available()``, ``start()`` and ``devops_up()`` already said the WSL2 sentence, but
Stop, Stop & clean, Seed, the m2 bootstrap, Delete/Halt/Resume DevOps lane and the e2e
run went straight to ``make``. The operator got a bare "[WinError 2] The system cannot
find the file specified", which names neither make nor WSL2, after the verb had written
tests/stack/.compose.limits.yaml into the checkout; the e2e gate even read "Ready" and
advised `make playwright-deps` / "bring it up first", neither of which the Windows build
can do.

The gate answers as Windows by the same idiom tests/test_native_windows_gates.py uses
(``native_windows_blocker`` with ``osname`` bound), never by changing os.name, so every
test here runs on Linux CI and on Windows alike.
"""
from __future__ import annotations

import functools
import os
import subprocess

import pytest

from hugmesh_studio.core import local_stack_node as lsn
from hugmesh_studio.core import platform_info

# e2e_ready is the subject here, so the conftest stub that answers for it must not
pytestmark = pytest.mark.real_stack_probes

_REAL_BLOCKER = platform_info.native_windows_blocker


def _answer_as(monkeypatch, osname):
    monkeypatch.setattr(platform_info, "native_windows_blocker",
                        functools.partial(_REAL_BLOCKER, osname=osname))


@pytest.fixture
def as_native_windows(monkeypatch):
    _answer_as(monkeypatch, "nt")


@pytest.fixture
def as_linux(monkeypatch):
    _answer_as(monkeypatch, "posix")


@pytest.fixture
def no_spawn(monkeypatch):
    def boom(*a, **kw):
        raise AssertionError(f"spawned {a[0] if a else kw.get('args')!r}")
    monkeypatch.setattr(lsn.subprocess, "Popen", boom)
    monkeypatch.setattr(lsn.subprocess, "run", boom)
    monkeypatch.setattr(subprocess, "Popen", boom)
    monkeypatch.setattr(subprocess, "run", boom)


def _checkout(tmp_path):
    """A generator checkout shaped enough for the verbs: tests/stack (where the
    limits overlay lands) and tests/e2e with node_modules (what `npm ci` leaves)."""
    (tmp_path / "tests" / "stack").mkdir(parents=True)
    (tmp_path / "tests" / "e2e" / "node_modules").mkdir(parents=True)
    return tmp_path


def _files(root):
    return sorted(os.path.relpath(os.path.join(d, f), root)
                  for d, _, fs in os.walk(root) for f in fs)


_STACK = "The local stack runs `make` and bash scripts"
_DEVOPS = "The DevOps (Kubernetes) lane runs `make` and bash scripts"
_E2E = "The e2e suite runs `make` and bash scripts"

# (verb, takes on_line, the action its sentence names)
_VERBS = [
    ("clean", _STACK), ("seed", _STACK), ("m2_bootstrap", _STACK),
    ("devops_down", _DEVOPS), ("devops_halt", _DEVOPS), ("devops_resume", _DEVOPS),
]


def test_stop_refuses_with_the_wsl2_sentence_and_writes_nothing(
        as_native_windows, no_spawn, tmp_path):
    gen = _checkout(tmp_path)
    before = _files(gen)
    ok, why = lsn.LocalStackNode(str(gen)).stop()
    assert ok is False
    assert why.startswith(_STACK) and "WSL2" in why
    assert "WinError" not in why
    # the limits overlay (_build_env) is not written for a verb that cannot run
    assert _files(gen) == before


@pytest.mark.parametrize("verb,said", _VERBS)
def test_streamed_verbs_refuse_and_say_it_in_the_log(as_native_windows, no_spawn,
                                                    tmp_path, verb, said):
    gen = _checkout(tmp_path)
    before = _files(gen)
    lines: list[str] = []
    ok, why = getattr(lsn.LocalStackNode(str(gen)), verb)(on_line=lines.append)
    assert ok is False
    assert why.startswith(said) and "WSL2" in why
    # the GUI's streaming worker drops the returned message: the log must carry it
    assert lines == [why]
    assert _files(gen) == before


@pytest.mark.parametrize("environment", ["docker", "kind", "qemu"])
def test_the_e2e_gate_refuses_instead_of_linux_advice(as_native_windows, no_spawn,
                                                      tmp_path, environment):
    problems = lsn.LocalStackNode(str(_checkout(tmp_path))).e2e_ready(environment)
    assert len(problems) == 1
    assert problems[0].startswith(_E2E) and "WSL2" in problems[0]
    assert "playwright-deps" not in problems[0]


def test_the_e2e_gate_still_rejects_an_unknown_environment(as_native_windows, tmp_path):
    with pytest.raises(ValueError):
        lsn.LocalStackNode(str(_checkout(tmp_path))).e2e_ready("no-such-mesh")


def test_run_e2e_refuses_before_make(as_native_windows, no_spawn, tmp_path):
    gen = _checkout(tmp_path)
    before = _files(gen)
    ok, why = lsn.LocalStackNode(str(gen)).run_e2e(environment="kind",
                                                   on_line=lambda _l: None)
    assert ok is False and why.startswith(_E2E)
    assert _files(gen) == before


# ── off Windows nothing changes ─────────────────────────────────────────────────

_TARGETS = [("clean", "stack-clean"), ("seed", "stack-seed"),
            ("m2_bootstrap", "stack-m2-bootstrap"), ("devops_down", "kind-down"),
            ("devops_halt", "kind-halt"), ("devops_resume", "kind-resume")]


def _record_make(monkeypatch):
    calls: list[str] = []

    def fake(self, target, timeout, extra_env=None, on_line=None, cancel=None,
             args=None):
        calls.append(target)
        return True, "ran"
    monkeypatch.setattr(lsn.LocalStackNode, "_make", fake)
    return calls


def test_stop_still_runs_stack_halt_off_windows(as_linux, monkeypatch, tmp_path):
    calls = _record_make(monkeypatch)
    assert lsn.LocalStackNode(str(_checkout(tmp_path))).stop() == (True, "ran")
    assert calls == ["stack-halt"]


@pytest.mark.parametrize("verb,target", _TARGETS)
def test_streamed_verbs_still_run_make_off_windows(as_linux, monkeypatch, tmp_path,
                                                   verb, target):
    calls = _record_make(monkeypatch)
    lines: list[str] = []
    ok, _ = getattr(lsn.LocalStackNode(str(_checkout(tmp_path))), verb)(
        on_line=lines.append)
    assert ok is True and calls == [target] and lines == []


def test_the_e2e_gate_is_unchanged_off_windows(as_linux, no_spawn, tmp_path):
    gen = _checkout(tmp_path)
    assert lsn.LocalStackNode(str(gen)).e2e_ready("kind") == []
    os.rmdir(gen / "tests" / "e2e" / "node_modules")
    problems = lsn.LocalStackNode(str(gen)).e2e_ready("kind")
    assert len(problems) == 1 and "playwright-deps" in problems[0]

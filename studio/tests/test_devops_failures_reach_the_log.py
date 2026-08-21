"""A failed DevOps-lane verb must SAY why, in the log the status bar points at.

WHY THIS FILE EXISTS. The local-mesh page runs its long verbs streamed, and
:class:`~hugmesh_studio.gui.pages.localmesh._MeshWorker` deliberately DISCARDS a
streaming verb's return value — the lines already streamed, and re-dumping them
doubled every milestone in the log. Correct for the output TAIL. Silently wrong
for every failure whose reason is INVENTED at the return statement and was never
streamed at all:

  * ``devops_tools.install`` returns "Could not download kind: <DNS error>" /
    "SHA-256 MISMATCH" / "unsupported architecture" and streams none of them, so
    "Install DevOps prerequisites" failing printed ``downloading kind …`` and
    then nothing;
  * ``LocalStackNode._make`` returns "timed out after 3600 s" and "cancelled by
    operator" and "could not start make" as NEW sentences, so a ``make kind-up``
    that hit ``DEVOPS_UP_TIMEOUT_S`` showed a log that just STOPPED;
  * ``LocalStackNode.devops_up``'s tool-gap early return had no ``on_line`` at
    all, unlike the repo-access block two lines below it.

In all of them the operator's whole report is "starting the devops lane fails"
under a status bar reading ``FAILED (see log)`` — pointing at a log that does not
contain the reason. These tests pin the reason INTO the streamed lines.

Nothing here downloads anything or talks to docker: the network, Popen and the
probes are all mocked.
"""
from __future__ import annotations

import io
import os

import pytest

from hugmesh_studio.core import devops_tools
from hugmesh_studio.core import local_stack_node as lsn
from hugmesh_studio.core.local_stack_node import LocalStackNode


# ── devops_tools.install: every failure is said, not just returned ───────────

def _linux_amd64(monkeypatch):
    monkeypatch.setattr(devops_tools.platform, "machine", lambda: "x86_64")
    monkeypatch.setattr(devops_tools.platform, "system", lambda: "Linux")


def test_download_failure_reaches_the_log(monkeypatch, tmp_path):
    _linux_amd64(monkeypatch)
    monkeypatch.setattr(devops_tools, "tools_dir", lambda gd="": str(tmp_path))

    def _boom(url, timeout=0):
        raise OSError("Temporary failure in name resolution")
    monkeypatch.setattr(devops_tools.urllib.request, "urlopen", _boom)

    lines: list[str] = []
    ok, msg = devops_tools.install("", tools=("kind",), on_line=lines.append)
    assert ok is False
    assert "name resolution" in msg
    assert any("name resolution" in ln for ln in lines), lines


def test_checksum_mismatch_reaches_the_log(monkeypatch, tmp_path):
    _linux_amd64(monkeypatch)
    monkeypatch.setattr(devops_tools, "tools_dir", lambda gd="": str(tmp_path))

    class _R(io.BytesIO):
        """A urlopen() stand-in. MUST be a real read(size) stream: install()
        hands the binary response to shutil.copyfileobj, and a read() that
        ignores its size argument never returns b"" — the copy then writes until
        the disk fills (hit while writing this test)."""
        def __enter__(self):
            return self
        def __exit__(self, *a):
            return False

    def _urlopen(url, timeout=0):
        # the binary, then a checksum that cannot match it
        return _R(b"0" * 64) if url.endswith(".sha256sum") else _R(b"not-the-real-binary")
    monkeypatch.setattr(devops_tools.urllib.request, "urlopen", _urlopen)

    lines: list[str] = []
    ok, msg = devops_tools.install("", tools=("kind",), on_line=lines.append)
    assert ok is False and "MISMATCH" in msg
    assert any("MISMATCH" in ln for ln in lines), lines
    # and the rejected download is not left behind as a half-installed tool
    assert not (tmp_path / "kind").exists()
    assert not (tmp_path / "kind.part").exists()


def test_unsupported_arch_reaches_the_log(monkeypatch):
    monkeypatch.setattr(devops_tools.platform, "machine", lambda: "riscv64")
    lines: list[str] = []
    ok, msg = devops_tools.install("", on_line=lines.append)
    assert ok is False and "riscv64" in msg
    assert any("riscv64" in ln for ln in lines), lines


# ── _make: the three sentences it invents and never streamed ────────────────

def _node(tmp_path, makefile: str) -> LocalStackNode:
    (tmp_path / "Makefile").write_text(makefile)
    return LocalStackNode(str(tmp_path))


def test_unstartable_make_reaches_the_log(monkeypatch, tmp_path):
    node = _node(tmp_path, "noop:\n\t@true\n")

    def _boom(*a, **kw):
        raise OSError(2, "No such file or directory: 'make'")
    monkeypatch.setattr(lsn.subprocess, "Popen", _boom)

    lines: list[str] = []
    ok, msg = node._make("noop", timeout=30, on_line=lines.append)
    assert ok is False
    assert "No such file or directory" in msg
    assert any("No such file or directory" in ln for ln in lines), lines


@pytest.mark.skipif(os.name != "posix", reason="process-group kill is POSIX-only")
def test_timeout_reaches_the_log_and_names_the_target(tmp_path):
    # timeout=0: the deadline is already past on the first loop pass, so the
    # group is terminated immediately and the timeout branch is the real one —
    # no sleeping test, and the sentence under test is genuinely produced.
    node = _node(tmp_path, "slow:\n\t@sleep 60\n")
    lines: list[str] = []
    ok, msg = node._make("slow", timeout=0, on_line=lines.append)
    assert ok is False
    assert "timed out" in msg and "make slow" in msg
    assert any("timed out" in ln and "make slow" in ln for ln in lines), lines


@pytest.mark.skipif(os.name != "posix", reason="process-group kill is POSIX-only")
def test_cancel_reaches_the_log(tmp_path):
    node = _node(tmp_path, "slow:\n\t@sleep 60\n")

    class _AlreadySet:
        def is_set(self):
            return True

    lines: list[str] = []
    ok, msg = node._make("slow", timeout=300, on_line=lines.append,
                         cancel=_AlreadySet())
    assert ok is False and "cancelled by operator" in msg
    assert any("cancelled by operator" in ln for ln in lines), lines


def test_a_clean_run_streams_no_invented_sentence(tmp_path):
    # The counterweight: none of the three sentences may appear on a verb that
    # simply worked, or the log grows noise on every successful bring-up.
    node = _node(tmp_path, "noop:\n\t@echo hello\n")
    lines: list[str] = []
    ok, _ = node._make("noop", timeout=60, on_line=lines.append)
    assert ok is True
    assert lines == ["hello"], lines


# ── devops_up's tool gap streams like its repo-access sibling ───────────────

def test_missing_tool_reaches_the_log(monkeypatch, tmp_path):
    node = LocalStackNode(str(tmp_path))
    monkeypatch.setattr(LocalStackNode, "devops_available",
                        lambda self: ["`kind` is not installed"], raising=True)

    def _no_make(self, *a, **kw):  # pragma: no cover - the assertion IS the test
        raise AssertionError("make kind-up must not run without the lane's tools")
    monkeypatch.setattr(LocalStackNode, "_make", _no_make, raising=True)

    lines: list[str] = []
    ok, msg = node.devops_up(on_line=lines.append)
    assert ok is False and "not installed" in msg
    assert any("not installed" in ln for ln in lines), lines


# ── the net under all of them: the GUI worker itself ────────────────────────

def test_worker_emits_a_reason_when_a_streaming_verb_emitted_nothing():
    """A streaming verb that fails having streamed NOTHING has no lines to
    double, so the worker must surface its returned reason rather than leave the
    run's log empty under "FAILED (see log)"."""
    pytest.importorskip("hugmesh_studio.gui.qt")
    from hugmesh_studio.gui.pages import localmesh

    w = localmesh._MeshWorker(lambda on_line, cancel: (False, "the real reason\nline two"),
                              stream=True)
    seen: list[str] = []
    w.line.connect(seen.append)
    w.run()                      # run() directly: no thread, no event loop needed
    assert seen == ["the real reason", "line two"]


def test_worker_still_never_doubles_a_verb_that_did_stream():
    """The original contract, unchanged: output that already streamed is NOT
    re-dumped — that doubling is what made the drop correct in the first place."""
    pytest.importorskip("hugmesh_studio.gui.qt")
    from hugmesh_studio.gui.pages import localmesh

    def _verb(on_line, cancel):
        on_line("==> building")
        on_line("boom")
        return False, "==> building\nboom"

    w = localmesh._MeshWorker(_verb, stream=True)
    seen: list[str] = []
    w.line.connect(seen.append)
    w.run()
    assert seen == ["==> building", "boom"]

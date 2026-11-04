"""The bring-up's cancel handle is a threading.Event, and the onion wait must read it as one.

THE BUG (operator's run log 20261031-101210-Bootstrapping-FAILED.log): the stack came
up, `make stack-seed` reported ok, the overlay step printed
"[mesh-overlay] skipped (LAN-only / no auth key)", and then the whole bring-up died on

    !! TypeError: 'Event' object is not callable

The GUI (gui/pages/localmesh.py `_launch`) hands every cancellable verb a
``threading.Event`` and every other consumer of it (LocalStackNode._make, the m2
bootstrap) reads it with ``.is_set()``. ``_await_onion`` — the Tor step that runs
right after the overlay step whenever Tor is on — called it like a function. Every
existing test drove ``up()`` with ``cancel=None``, which is the one value that never
reaches the call, so the crash only existed on the real GUI path.

These tests drive the SAME step sequence as that log, offline: guard -> preflight ->
creds -> stack-up -> stack-seed -> overlay skipped (LAN-only) -> Tor onion wait, with
the cancel handle the GUI actually passes. No subprocess, no docker, no sleeping.
"""
import os
import threading

from hugmesh_studio.core import local_mesh_bootstrap as lmb
from hugmesh_studio.core.local_mesh import LocalMeshNode
from hugmesh_studio.core.local_mesh_bootstrap import (
    LocalMeshBootstrap, LocalMeshBootstrapConfig,
)
from hugmesh_studio.core.local_stack_node import LocalStackNode

GENERATOR_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ONION = "https://txljwl7mdg7t3wmqdci77ttof5ikxeqg2epmfadzfxlzxvjgtx5k4fad.onion/"


def _boot(tmp_path, monkeypatch, onion_after_polls: int):
    """A bootstrapper whose every side-effecting step is stubbed to succeed, exactly as
    the operator's run did, with Tor on and no overlay (env=test => LAN-only)."""
    # _hand_over_tor_hold writes os.environ; keep it from leaking out of the test.
    monkeypatch.delenv("TOR_HOLD", raising=False)
    monkeypatch.setattr(LocalMeshBootstrap, "guard_host_local", lambda self: (True, ""))
    monkeypatch.setattr(LocalMeshBootstrap, "preflight", lambda self: [])
    monkeypatch.setattr(LocalMeshBootstrap, "generate_creds",
                        lambda self: (True, "credentials generated"))
    monkeypatch.setattr(LocalMeshBootstrap, "read_superadmin",
                        lambda self: {"username": "superadmin", "password": "pw"})
    monkeypatch.setattr(LocalStackNode, "start",
                        lambda self, on_line=None, cancel=None: (True, "stack up"))
    monkeypatch.setattr(LocalStackNode, "seed",
                        lambda self, extra_env=None, timeout=600, on_line=None,
                        cancel=None: (True, "seeded"))

    def _no_overlay(self):
        raise AssertionError("a LAN-only (env=test) bring-up must not start the overlay")
    monkeypatch.setattr(LocalMeshNode, "start", _no_overlay)

    polls = {"n": 0}

    def _onion_url(self):
        polls["n"] += 1
        return ONION if polls["n"] > onion_after_polls else ""
    monkeypatch.setattr(LocalStackNode, "onion_url", _onion_url)
    monkeypatch.setattr(lmb.time, "sleep", lambda _s: None)

    cfg = LocalMeshBootstrapConfig(out_dir=str(tmp_path), env="test", with_tor=True)
    b = LocalMeshBootstrap(GENERATOR_DIR, cfg)
    assert b.cfg.effective_with_tor() and not b.overlay_will_attach()
    return b, polls


def test_bring_up_with_tor_survives_the_guis_threading_event(tmp_path, monkeypatch):
    """THE REGRESSION: the exact sequence of the failed log, with the GUI's handle."""
    b, polls = _boot(tmp_path, monkeypatch, onion_after_polls=2)
    lines: list[str] = []
    ok, log = b.up(on_line=lines.append, cancel=threading.Event())

    assert ok is True
    assert "[mesh-overlay] skipped (LAN-only / no auth key)" in lines
    assert any(ln.startswith("[tor] onion published") and ONION in ln for ln in lines)
    assert any(ln.startswith("[done] platform up") for ln in lines)
    assert polls["n"] == 3                      # it really waited for the descriptor
    assert log == lines                         # streamed AND returned, same lines


def test_a_set_event_ends_the_onion_wait_without_failing_the_bring_up(tmp_path, monkeypatch):
    """Cancel pressed during the ~30 s onion wait: the wait stops at once (no further
    polls), the platform that already came up is still reported up, and the operator is
    told how to read the address later. Nothing raises."""
    b, polls = _boot(tmp_path, monkeypatch, onion_after_polls=10_000)
    cancel = threading.Event()
    cancel.set()
    lines: list[str] = []
    ok, _log = b.up(on_line=lines.append, cancel=cancel)

    assert ok is True
    assert polls["n"] == 0                      # cancelled before the first poll
    assert any("onion still publishing" in ln for ln in lines)
    assert any(ln.startswith("[done] platform up") for ln in lines)


def test_await_onion_reads_an_event_and_still_accepts_a_predicate(tmp_path, monkeypatch):
    """Both shapes a caller might hand it: the GUI's Event, and a plain zero-arg
    predicate (the shape the old code assumed). Neither may raise."""
    monkeypatch.setattr(lmb.time, "sleep", lambda _s: None)
    monkeypatch.setattr(LocalStackNode, "onion_url", lambda self: "")
    b = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(out_dir=str(tmp_path)))
    stack = LocalStackNode(str(tmp_path))
    ev = threading.Event()
    ev.set()
    assert b._await_onion(stack, lambda _l: None, ev, timeout_s=30) == ""
    assert b._await_onion(stack, lambda _l: None, lambda: True, timeout_s=30) == ""

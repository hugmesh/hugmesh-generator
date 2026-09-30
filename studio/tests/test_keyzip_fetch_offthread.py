"""The remote-config fetch must not run on the GUI thread, and must not wait forever.

WHY THIS TEST EXISTS. KeyZipPage._fetch called _fetch_to_zip() INLINE from a `clicked`
slot, and _fetch_to_zip called ``urllib.request.urlopen(url)`` with NO timeout. urlopen's
default is the process-wide socket default, normally None — i.e. no deadline at all. A
server that accepts the connection and then never answers (a half-open NAT, a hung
reverse proxy, a black-holed address) therefore froze the entire wizard window with no
Cancel, no progress and no way to close it. Both halves are needed: a timeout alone would
still freeze the window, just for a bounded 60 seconds.
"""
from __future__ import annotations

import os
import threading

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from types import SimpleNamespace                                   # noqa: E402

from hugmesh_studio.core.config import ImageConfig                  # noqa: E402
from hugmesh_studio.gui.pages import keyzip as keyzip_page          # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                         # noqa: E402


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def page(qapp):
    p = keyzip_page.KeyZipPage(SimpleNamespace(cfg=ImageConfig(), generator_dir="."))
    yield p
    w = p._fetch_worker
    if w is not None:
        w.wait(5000)
    p.deleteLater()


def _pump(qapp, page, timeout_s=5.0):
    """Run the event loop until the fetch worker has finished and its queued signal has
    been delivered — the real path, not a direct call into the slot."""
    w = page._fetch_worker
    assert w is not None, "no fetch was started"
    deadline = threading.Event()
    for _ in range(int(timeout_s * 200)):
        qapp.processEvents()
        if not w.isRunning():
            break
        deadline.wait(0.005)
    w.wait(2000)
    qapp.processEvents()


def test_the_fetch_carries_a_socket_timeout(monkeypatch, tmp_path):
    """A no-timeout urlopen waits forever on a server that never answers."""
    seen = {}

    class _Resp:
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read(self, _n):
            return b"PK\x05\x06" + b"\0" * 18

    def fake_urlopen(url, timeout=None):
        seen["url"], seen["timeout"] = url, timeout
        return _Resp()

    monkeypatch.setattr(keyzip_page.urllib.request, "urlopen", fake_urlopen)
    keyzip_page._fetch_to_zip("https://admin.example.org/cfg.zip",
                              str(tmp_path / "fetch" / "admin-config.zip"))

    assert seen["timeout"] == keyzip_page._FETCH_TIMEOUT_S
    assert seen["timeout"] is not None and seen["timeout"] > 0


def test_the_click_returns_immediately_while_the_server_stalls(qapp, page, monkeypatch,
                                                               tmp_path):
    """THE freeze test. The fetch parks on an event; the click slot must return anyway,
    with the window still able to process events."""
    monkeypatch.setattr(os.path, "expanduser", lambda p: str(tmp_path))
    parked = threading.Event()
    entered = threading.Event()

    def stalling_fetch(url, dest):
        entered.set()
        parked.wait(10)                      # a server that accepts and never answers
        raise OSError("timed out")

    monkeypatch.setattr(keyzip_page, "_fetch_to_zip", stalling_fetch)
    page.link.setText("https://admin.example.org/cfg.zip")
    page._fetch()                            # must NOT block

    assert entered.wait(5), "the fetch never started off-thread"
    assert page._fetch_worker.isRunning(), "the fetch must be on its own thread"
    assert not page.fetch_btn.isEnabled(), "a second click must not start a second thread"
    assert "Fetching" in page.out.text()
    qapp.processEvents()                     # the event loop is alive; the window is not
    page._fetch()                            # a repeat click while in flight does nothing
    assert page._fetch_worker.isRunning()

    parked.set()
    _pump(qapp, page)
    assert page.fetch_btn.isEnabled(), "the button must come back"
    assert "Fetch failed" in page.out.text() and "timed out" in page.out.text()


def test_a_successful_fetch_still_imports_on_the_gui_thread(qapp, page, monkeypatch,
                                                            tmp_path):
    """The fetch moved off-thread; the APPLY (extract + wire into the config) must stay on
    the GUI thread, on the same path a BROWSED zip takes."""
    monkeypatch.setattr(os.path, "expanduser", lambda p: str(tmp_path))
    zip_path = tmp_path / "fetched.zip"
    zip_path.write_bytes(b"not really a zip")
    monkeypatch.setattr(keyzip_page, "_fetch_to_zip",
                        lambda url, dest: str(zip_path))
    applied = []
    monkeypatch.setattr(type(page), "_apply",
                        lambda self, p: applied.append((p, threading.get_ident())))

    page.link.setText("file:///whatever.zip")
    page._fetch()
    _pump(qapp, page)

    assert applied == [(str(zip_path), threading.get_ident())], \
        "the apply must run on the calling (GUI) thread, once"
    assert page.path.text() == str(zip_path)
    assert page.fetch_btn.isEnabled()


def test_an_empty_link_says_so_without_starting_a_thread(page):
    page.link.setText("   ")
    page._fetch()
    assert page._fetch_worker is None
    assert "Paste a remote-config link first." in page.out.text()

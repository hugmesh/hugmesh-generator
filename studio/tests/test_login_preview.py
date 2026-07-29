"""The browser-preview asset + writer (core/login_preview.py).

The asset is a CAPTURED SNAPSHOT of the real production login-ui build (rendered
DOM + serialized component styles + compiled global stylesheet). These tests pin
what makes it honest: it is the real page (the real form controls are in it), it
is inert (zero scripts — a frozen visual snapshot), it records its provenance
(the login-ui commit it was captured from), and the theme substitution point is
exactly one ``style#snap-theme`` marker — the same text, same ``:root:root``
mechanism that ships to containers. Proven end-to-end at build time: headless-
chromium screenshots of default vs themed previews differ, with the themed font
and accent visibly applied.
"""
import re

import pytest

from hugmesh_studio.core import login_preview, theme


@pytest.fixture(scope="module")
def asset() -> str:
    with open(login_preview.preview_asset_path(), encoding="utf-8") as fh:
        return fh.read()


def test_asset_is_the_real_login_page(asset):
    # the real form controls, captured from the rendered production build —
    # not a hand-drawn mock that drifts when login.component.html changes.
    assert 'data-testid="login-submit"' in asset
    assert 'id="snap-login-username"' in asset
    assert 'id="snap-login-password"' in asset
    assert 'id="captured-component-styles"' in asset
    assert 'id="compiled-global-styles"' in asset


def test_asset_is_inert_and_carries_provenance(asset):
    assert "<script" not in asset          # frozen visual snapshot: no JS ever runs
    assert re.search(r"hugmesh-login-ui commit [0-9a-f]{40}", asset), (
        "the snapshot must record WHICH login-ui commit it captures, or drift "
        "becomes undetectable")
    # the honesty banner: what the preview does NOT claim, stated in the artifact.
    assert "DOES NOT CLAIM" in asset


def test_marker_is_exactly_one_style_block(asset):
    assert asset.count(login_preview.MARKER) == 1
    assert f'<style id="snap-theme">{login_preview.MARKER}</style>' in asset


def test_preview_html_substitutes_the_exact_theme_text():
    css = theme.compose_login_css("#e91e63", "#00bcd4", font_preset="Monospace")
    page = login_preview.preview_html(css)
    assert login_preview.MARKER not in page
    assert f'<style id="snap-theme">{css}</style>' in page
    # unthemed: marker replaced by nothing — the compiled fallbacks render.
    blank = login_preview.preview_html("")
    assert '<style id="snap-theme"></style>' in blank


def test_write_preview_returns_a_real_file(tmp_path):
    css = theme.compose_login_css("#336699")
    path = login_preview.write_preview(css, str(tmp_path))
    assert path.endswith(login_preview.PREVIEW_BASENAME)
    text = open(path, encoding="utf-8").read()
    assert "--sd-primary: #336699;" in text
    assert ":root:root {" in text


# ── open_in_browser: the VERIFIED open path (the "preview does nothing" fix) ─────────
#
# Contract under test: CLI openers first, each judged by its OWN exit code (xdg-open
# exits 2/3/4 on failure — the signal the old Popen-and-forget threw away, which is
# how "opened in your browser" could be reported while nothing appeared); the stdlib
# webbrowser controller runs LAST because its True is dispatch-only (poll() right
# after fork). `how` is prefixed verified:/unverified: so the GUI can be honest.

class _FakeProc:
    def __init__(self, code=0, hang=False):
        self._code, self._hang = code, hang

    def wait(self, timeout=None):
        if self._hang:
            raise login_preview.subprocess.TimeoutExpired(cmd="x", timeout=timeout)
        return self._code


def _linux(monkeypatch):
    monkeypatch.setattr(login_preview.sys, "platform", "linux")
    monkeypatch.setattr(login_preview.os, "name", "posix")
    monkeypatch.setenv("BROWSER", "")


def test_file_url_is_an_absolute_file_uri(tmp_path):
    p = tmp_path / "x.html"
    p.write_text("hi", encoding="utf-8")
    url = login_preview.file_url(str(p))
    assert url.startswith("file://") and url.endswith("/x.html")


def test_open_in_browser_verifies_the_opener_exit_code(tmp_path, monkeypatch):
    p = tmp_path / "x.html"; p.write_text("hi", encoding="utf-8")
    _linux(monkeypatch)
    monkeypatch.setattr(login_preview.shutil, "which",
                        lambda t: "/usr/bin/xdg-open" if t == "xdg-open" else None)
    spawned = {}

    def _popen(cmd, **kw):
        spawned["cmd"] = cmd
        return _FakeProc(code=0)
    monkeypatch.setattr(login_preview.subprocess, "Popen", _popen)
    # webbrowser must NOT be consulted when a verified opener already succeeded —
    # its dispatch-only True was the original false-positive source.
    monkeypatch.setattr(login_preview.webbrowser, "open",
                        lambda url: pytest.fail("webbrowser must be the LAST resort"))
    ok, how = login_preview.open_in_browser(str(p))
    assert ok and how.startswith("verified") and "xdg-open" in how
    assert spawned["cmd"][0] == "/usr/bin/xdg-open"


def test_open_in_browser_treats_a_nonzero_opener_as_failed_and_tries_the_next(
        tmp_path, monkeypatch):
    # xdg-open exit 2 (no handler) — the EXACT case the old code reported as success.
    p = tmp_path / "x.html"; p.write_text("hi", encoding="utf-8")
    _linux(monkeypatch)
    monkeypatch.setattr(
        login_preview.shutil, "which",
        lambda t: f"/usr/bin/{t}" if t in ("xdg-open", "sensible-browser") else None)
    codes = {"/usr/bin/xdg-open": 2, "/usr/bin/sensible-browser": 0}
    ran = []
    monkeypatch.setattr(login_preview.subprocess, "Popen",
                        lambda cmd, **kw: ran.append(cmd[0]) or _FakeProc(codes[cmd[0]]))
    ok, how = login_preview.open_in_browser(str(p))
    assert ran == ["/usr/bin/xdg-open", "/usr/bin/sensible-browser"]
    assert ok and how.startswith("verified") and "sensible-browser" in how


def test_open_in_browser_counts_a_long_running_opener_as_the_browser(tmp_path,
                                                                     monkeypatch):
    # $BROWSER=firefox cold start: the "opener" IS the browser; longevity = success.
    p = tmp_path / "x.html"; p.write_text("hi", encoding="utf-8")
    _linux(monkeypatch)
    monkeypatch.setenv("BROWSER", "firefox")
    monkeypatch.setattr(login_preview.shutil, "which",
                        lambda t: "/usr/bin/firefox" if t == "firefox" else None)
    monkeypatch.setattr(login_preview.subprocess, "Popen",
                        lambda cmd, **kw: _FakeProc(hang=True))
    ok, how = login_preview.open_in_browser(str(p))
    assert ok and how.startswith("verified") and "still running" in how


def test_open_in_browser_falls_back_to_stdlib_webbrowser_as_unverified(tmp_path,
                                                                       monkeypatch):
    p = tmp_path / "x.html"; p.write_text("hi", encoding="utf-8")
    _linux(monkeypatch)
    monkeypatch.setattr(login_preview.shutil, "which", lambda t: None)
    called = {}
    monkeypatch.setattr(login_preview.webbrowser, "open",
                        lambda url: called.setdefault("url", url) or True)
    ok, how = login_preview.open_in_browser(str(p))
    assert ok and how.startswith("unverified")   # the GUI shows the manual path too
    assert called["url"].startswith("file://")


def test_open_in_browser_returns_false_when_nothing_can_open(tmp_path, monkeypatch):
    # The "preview button does nothing" environment: no opener on PATH, controller dead.
    p = tmp_path / "x.html"; p.write_text("hi", encoding="utf-8")
    _linux(monkeypatch)
    monkeypatch.setattr(login_preview.webbrowser, "open", lambda url: False)
    monkeypatch.setattr(login_preview.shutil, "which", lambda t: None)
    ok, why = login_preview.open_in_browser(str(p))
    assert ok is False and "no browser opener worked" in why


# ── preview_out_dir: a stable target the openers can still reach later ──────────────

def test_preview_out_dir_honours_xdg_cache_home(monkeypatch, tmp_path):
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path))
    out = login_preview.preview_out_dir()
    assert out == str(tmp_path / "hugmesh-studio" / "preview")


def test_preview_out_dir_is_not_the_sweepable_tempdir(monkeypatch, tmp_path):
    # $TMPDIR can point into build scratch that portage sweeps mid-session (the studio
    # venv itself lives under /var/tmp/portage) — the preview must not land there.
    monkeypatch.delenv("XDG_CACHE_HOME", raising=False)
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("TMPDIR", "/var/tmp/portage/whatever")
    out = login_preview.preview_out_dir()
    assert out.startswith(str(tmp_path))
    assert "/.cache/" in out and "portage" not in out

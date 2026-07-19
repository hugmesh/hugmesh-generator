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

from snapdragon_studio.core import login_preview, theme


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
    assert re.search(r"snapdragon-login-ui commit [0-9a-f]{40}", asset), (
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


# ── open_in_browser: the Qt-free fallback that fixes the "preview does nothing" bug ──

def test_file_url_is_an_absolute_file_uri(tmp_path):
    p = tmp_path / "x.html"
    p.write_text("hi", encoding="utf-8")
    url = login_preview.file_url(str(p))
    assert url.startswith("file://") and url.endswith("/x.html")


def test_open_in_browser_uses_stdlib_controller_when_it_works(tmp_path, monkeypatch):
    p = tmp_path / "x.html"; p.write_text("hi", encoding="utf-8")
    called = {}
    monkeypatch.setattr(login_preview.webbrowser, "open",
                        lambda url: called.setdefault("url", url) or True)
    ok, how = login_preview.open_in_browser(str(p))
    assert ok and how == "webbrowser"
    assert called["url"].startswith("file://")


def test_open_in_browser_falls_back_to_an_opener_when_controller_fails(tmp_path, monkeypatch):
    p = tmp_path / "x.html"; p.write_text("hi", encoding="utf-8")
    monkeypatch.setattr(login_preview.sys, "platform", "linux")
    monkeypatch.setattr(login_preview.os, "name", "posix")
    monkeypatch.setattr(login_preview.webbrowser, "open", lambda url: False)
    monkeypatch.setattr(login_preview.shutil, "which",
                        lambda t: "/usr/bin/xdg-open" if t == "xdg-open" else None)
    spawned = {}
    monkeypatch.setattr(login_preview.subprocess, "Popen",
                        lambda cmd, **kw: spawned.setdefault("cmd", cmd))
    monkeypatch.setenv("BROWSER", "")
    ok, how = login_preview.open_in_browser(str(p))
    assert ok and how == "/usr/bin/xdg-open"
    assert spawned["cmd"][0] == "/usr/bin/xdg-open"


def test_open_in_browser_returns_false_when_nothing_can_open(tmp_path, monkeypatch):
    # The "preview button does nothing" environment: no controller, no opener on PATH.
    p = tmp_path / "x.html"; p.write_text("hi", encoding="utf-8")
    monkeypatch.setattr(login_preview.sys, "platform", "linux")
    monkeypatch.setattr(login_preview.os, "name", "posix")
    monkeypatch.setattr(login_preview.webbrowser, "open", lambda url: False)
    monkeypatch.setattr(login_preview.shutil, "which", lambda t: None)
    monkeypatch.setenv("BROWSER", "")
    ok, why = login_preview.open_in_browser(str(p))
    assert ok is False and "failed" in why  # caller surfaces the path for a manual open

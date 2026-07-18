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

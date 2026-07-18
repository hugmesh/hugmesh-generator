"""Real-browser preview of the REAL login page (Qt-free; the GUI only opens the URL).

The asset (assets/login-preview.html) is a captured snapshot of the production
login-ui build: rendered DOM + serialized component styles + the real compiled
global stylesheet, scripts stripped. Substituting the derived theme css into its
``style#snap-theme`` marker reproduces EXACTLY the mechanism that ships — the same
token text, under the same ``:root:root`` selector, cascading over the same
compiled fallbacks — so the browser that renders this file is answering the same
question production answers, not a Qt-painted approximation of it.

WHY NOT QtWebEngine: it exists under PySide6 (the test venv) and NOT under the
operator's PyQt6 — a WebEngine preview would pass every test here and be dead on
the machine that matters. The operator's default browser is also the actual
runtime target, so "open a file in the real browser" is both the portable and the
honest choice (QDesktopServices.openUrl on the GUI side).

The preview makes NO claim about host-federated composition, live i18n strings,
or MFA views (banner in the asset states this in-window).
"""
from __future__ import annotations

import os

MARKER = "/*__SNAP_THEME_CSS__*/"
_ASSET = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                      "assets", "login-preview.html")
PREVIEW_BASENAME = "snapdragon-login-preview.html"


def preview_asset_path() -> str:
    return _ASSET


def preview_html(theme_css: str) -> str:
    """The preview page with ``theme_css`` (theme.compose_login_css output, or ""
    for the shipped default) substituted at the snap-theme marker."""
    with open(_ASSET, encoding="utf-8") as fh:
        tpl = fh.read()
    if MARKER not in tpl:
        raise RuntimeError(
            f"preview asset lost its substitution marker ({MARKER}) — regenerate "
            "assets/login-preview.html from a login-ui build")
    return tpl.replace(MARKER, theme_css, 1)


def write_preview(theme_css: str, out_dir: str) -> str:
    """Write the substituted preview into ``out_dir`` and return its path (the GUI
    hands this to the operator's browser as a file:// URL)."""
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, PREVIEW_BASENAME)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(preview_html(theme_css))
    return path

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
import shutil
import subprocess
import sys
import webbrowser

MARKER = "/*__SNAP_THEME_CSS__*/"
_ASSET = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                      "assets", "login-preview.html")
PREVIEW_BASENAME = "hugmesh-login-preview.html"


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


def file_url(path: str) -> str:
    """The ``file://`` URL for a local ``path`` (absolute), for a browser open."""
    from pathlib import Path
    return Path(os.path.abspath(path)).as_uri()


def open_in_browser(path: str) -> tuple[bool, str]:
    """Best-effort open a local file in the operator's browser — Qt-FREE and portable,
    the fallback for when Qt's QDesktopServices.openUrl silently fails (common on a
    minimal/Wayland/tiling desktop with no registered ``xdg-open`` handler, which is
    exactly where the "preview button does nothing" bug bites). Returns ``(ok, how)``:
    ``how`` is the mechanism that worked, or the reason none did.

    Order: the stdlib ``webbrowser`` controller (honours ``$BROWSER``, cross-platform)
    first; then explicit platform openers (``open`` on macOS, ``os.startfile`` on
    Windows, ``$BROWSER`` / ``xdg-open`` / ``gio open`` / ``sensible-browser`` on the
    rest). Never raises — a total miss returns ``(False, reason)`` so the caller can
    surface the path for a manual open instead of failing silently."""
    url = file_url(path)

    # 1) stdlib controller — the most portable single call.
    try:
        if webbrowser.open(url):
            return True, "webbrowser"
    except Exception:  # pragma: no cover - controller quirks are environment-specific
        pass

    # 2) explicit platform openers.
    if sys.platform == "darwin":
        candidates = [["open", path]]
    elif os.name == "nt":  # pragma: no cover - not exercised on the Linux test host
        try:
            os.startfile(path)  # type: ignore[attr-defined]
            return True, "startfile"
        except Exception:
            candidates = []
    else:
        candidates = []
        env_browser = os.environ.get("BROWSER", "").strip()
        if env_browser and shutil.which(env_browser.split()[0]):
            candidates.append([*env_browser.split(), url])
        for tool in ("xdg-open", "gio", "sensible-browser", "x-www-browser"):
            exe = shutil.which(tool)
            if not exe:
                continue
            candidates.append([exe, "open", path] if tool == "gio" else [exe, path])

    for cmd in candidates:
        try:
            subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True, cmd[0]
        except Exception:
            continue

    return False, "no browser opener found (webbrowser + xdg-open/$BROWSER all failed)"

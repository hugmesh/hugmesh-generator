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
import tempfile
import webbrowser

MARKER = "/*__SNAP_THEME_CSS__*/"
_ASSET = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                      "assets", "login-preview.html")
PREVIEW_BASENAME = "hugmesh-login-preview.html"

# How long to wait for a CLI opener to report its exit status. xdg-open/gio hand the
# URL to the desktop and exit well under a second; the timeout only triggers when the
# "opener" IS the browser itself ($BROWSER=firefox on a cold start), which staying
# alive this long is itself the success signal.
_OPENER_WAIT_S = 3.0


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


def preview_out_dir() -> str:
    """A STABLE per-user directory for written previews — deliberately NOT
    ``tempfile.gettempdir()``.

    WHY: every open mechanism is asynchronous — the click returns before the browser
    ever reads the file — and on this fleet ``$TMPDIR`` can point into build scratch
    that gets swept mid-session (the studio venv itself lives under a
    /var/tmp/portage/<pkg>-work/ tree, and portage sweeps its tmpdir on every build).
    A preview written to gettempdir() can therefore vanish between the click and the
    render: the browser shows file-not-found (or nothing at all) and the operator
    reads it as "the preview button doesn't work". ``~/.cache`` survives builds;
    gettempdir() remains only as the no-``$HOME`` fallback."""
    base = os.environ.get("XDG_CACHE_HOME", "").strip()
    if not base:
        home = os.path.expanduser("~")
        base = os.path.join(home, ".cache") if home not in ("", "~") \
            else tempfile.gettempdir()
    return os.path.join(base, "hugmesh-studio", "preview")


def open_in_browser(path: str) -> tuple[bool, str]:
    """Open a local file in the operator's browser — Qt-FREE, portable, and VERIFIED
    where the platform allows it. Returns ``(ok, how)``; on success ``how`` starts
    with ``"verified:"`` (the opener's own exit status confirmed the handoff) or
    ``"unverified:"`` (the mechanism reports launch, not render) so the GUI can be
    honest about which one it got. Never raises — a total miss returns
    ``(False, reason)`` and the caller surfaces the path for a manual open.

    WHY exit-code verification (the "preview button does nothing" post-mortem): every
    mechanism this code used to trust reports DISPATCH, not DISPLAY —
      * stdlib ``webbrowser.BackgroundBrowser.open`` returns ``p.poll() is None``
        immediately after the fork (CPython Lib/webbrowser.py), so a handler that
        dies 100ms later still counted as success;
      * ``xdg-open`` exits 0 only AFTER a successful handoff and exits 2/3/4 when no
        handler exists or the handler fails (xdg-open(1)) — but the old code
        Popen-and-forgot, throwing that signal away.
    So: CLI openers first, each waited on for up to ``_OPENER_WAIT_S`` (exit 0 =
    verified handoff; non-zero = THAT opener failed, try the next; still running =
    the opener is the browser itself, also success). The stdlib controller runs LAST
    as the unverifiable hail-mary instead of first as a false-positive source."""
    url = file_url(path)

    # 1) explicit platform openers — the verifiable mechanisms.
    if sys.platform == "darwin":
        candidates = [["open", path]]
    elif os.name == "nt":  # pragma: no cover - not exercised on the Linux test host
        try:
            os.startfile(path)  # type: ignore[attr-defined]
            # startfile raises when no association exists, so not-raising is a real
            # (if weak) success signal — Windows resolves the handler synchronously.
            return True, "verified: os.startfile (file association dispatched)"
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
            proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL)
        except Exception:
            continue
        try:
            code = proc.wait(timeout=_OPENER_WAIT_S)
        except subprocess.TimeoutExpired:
            # Still running after the grace period: this "opener" is the browser
            # itself ($BROWSER=firefox on a cold start) — staying alive IS the signal.
            return True, (f"verified: {cmd[0]} still running after "
                          f"{_OPENER_WAIT_S:g}s (it is the browser)")
        if code == 0:
            return True, f"verified: {cmd[0]} exited 0 (handoff confirmed)"
        # non-zero: THIS opener says it failed (xdg-open: 2 = no handler,
        # 3 = required tool missing, 4 = action failed). Fall through to the next.

    # 2) stdlib controller LAST: its True is dispatch-only (see docstring), but when
    # no CLI opener exists it can still reach a registered browser class.
    try:
        if webbrowser.open(url):
            return True, ("unverified: stdlib webbrowser.open returned True — it "
                          "only checks the child forked, not that anything rendered")
    except Exception:  # pragma: no cover - controller quirks are environment-specific
        pass

    return False, ("no browser opener worked ($BROWSER/xdg-open/gio missing or "
                   "reported failure, stdlib webbrowser too)")

"""Push a per-domain theme to the mesh — the Studio half of the operator's ask
("let themes be set different for different domains by the studio and by the superadmin
or admin of a domain in the web ui").

WHY THE STUDIO SENDS THE STYLESHEET AND NOT JUST THE CHOICE. The colour derivation has
exactly ONE implementation, and it is here in Python (:mod:`theme` + :mod:`theme_presets`).
That is a deliberate constraint, stated where the shipped theme hook lives: it writes
already-derived token text and does zero colour maths, because "a shell re-derivation
would be a second implementation whose drift makes the Studio preview lie". A Java
re-derivation in the BFF would be the same mistake with a worse symptom — the admin UI
showing one theme while the page renders another.

So the admin BFF stores the SELECTION as the source of truth and the rendered CSS as an
explicit cache, and this module is the renderer that fills it. The web UI can still
change a selection without being able to derive: the BFF then drops the stale render and
serves the shipped chrome until a Studio push re-fills it, which is un-themed rather than
wrong.

AUTHENTICATION IS THE CALLER'S JOB. This module takes a bearer token and never sources
one, so it stays pure enough to test headless and carries no second copy of the login
flow. A token that is absent or unprivileged surfaces as the BFF's own 401/403 rather
than as a guess made here.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass

from . import theme, theme_presets

#: The reserved path segment for the MESH DEFAULT, mirroring
#: ``DomainThemeAdminController.DEFAULT_SEGMENT``. The mesh default's storage key is the
#: EMPTY string, which cannot be a URL path segment, so it needs a name that no real
#: domain can take — the underscore guarantees that, since a registry-sanitized domain is
#: ``[a-z0-9-]``. Both sides must spell it identically; that is why it is a named constant
#: on both and not a literal at the call site.
DEFAULT_SEGMENT = "_default"

#: Recorded as ``rendered_by`` so a stale cache is identifiable rather than merely
#: suspected when the derivation changes.
RENDERER_ID = "studio"

_TIMEOUT_S = 15.0


class ThemePushError(RuntimeError):
    """A push that did not take effect. Carries the status when there was one."""

    def __init__(self, message: str, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


@dataclass(frozen=True)
class ThemeSelection:
    """One domain's choice, on the three orthogonal axes the Studio exposes."""

    preset: str
    ramp: str = theme_presets.MODES[0]
    style: str = theme.DEFAULT_STYLE
    primary_hex: str = ""
    secondary_hex: str = ""

    def validate(self) -> None:
        """Fail HERE rather than at the BFF, so the operator sees which field is wrong
        while the dialog is still open.

        The vocabularies are this module's own (``theme_presets.PRESETS`` / ``MODES`` and
        ``theme.STYLE_VARIANTS``), so this cannot drift from what will actually render —
        unlike the BFF's copy, which necessarily restates them.
        """
        if not self.preset:
            raise ValueError("preset is required")
        try:
            theme_presets.by_id(self.preset)
        except KeyError as e:
            # by_id raises KeyError; every other failure here is a ValueError. Leaving
            # both to escape would make a caller catch two types to report one thing —
            # "your selection is wrong" — so it is normalised to the one this contract
            # documents.
            raise ValueError(f"unknown theme preset: {self.preset!r}") from e
        if self.ramp not in theme_presets.MODES:
            raise ValueError(
                f"ramp must be one of {', '.join(theme_presets.MODES)}, got {self.ramp!r}")
        if self.style not in theme.STYLE_VARIANTS:
            raise ValueError(
                f"style must be one of {', '.join(theme.STYLE_VARIANTS)}, got {self.style!r}")
        for name, value in (("primary_hex", self.primary_hex),
                            ("secondary_hex", self.secondary_hex)):
            if value and not _is_hex(value):
                raise ValueError(f"{name} must be a #rrggbb colour, got {value!r}")


def _is_hex(s: str) -> bool:
    return (len(s) == 7 and s[0] == "#"
            and all(c in "0123456789abcdefABCDEF" for c in s[1:]))


def render_css(selection: ThemeSelection) -> str:
    """The ready-to-serve stylesheet for a selection — the single implementation.

    Identical in shape to what the entrypoint hook writes to ``snap-theme.css`` today, so
    a domain served this over HTTP and a container handed it via ``SNAP_THEME_CSS`` render
    the same page. The style axis is merged AFTER the preset+ramp tokens because it only
    contributes shape tokens (radius, border, shadow) and must not be re-anchored by the
    ramp's neutral pass.
    """
    selection.validate()
    tokens = theme_presets.compose_tokens(selection.preset, selection.ramp)
    tokens.update(theme.style_tokens(selection.style))
    return theme.css_root(tokens)


def build_payload(selection: ThemeSelection, *, include_css: bool = True) -> dict:
    """The ``PUT /bff/admin/themes/{domain}`` body.

    ``include_css=False`` sends the selection ALONE, which is what a caller wants when it
    is only re-pointing a domain and will re-render separately. Be aware of what that
    means at the far side: the BFF keeps an existing render only while the selection is
    unchanged, so an altered selection sent without CSS deliberately clears the cache and
    the domain serves default chrome until a render arrives.
    """
    selection.validate()
    body = {
        "preset": selection.preset,
        "ramp": selection.ramp,
        "style": selection.style,
    }
    # Omit rather than send empty: the BFF treats blank as null anyway, and an absent key
    # is the honest encoding of "no override".
    if selection.primary_hex:
        body["primaryHex"] = selection.primary_hex
    if selection.secondary_hex:
        body["secondaryHex"] = selection.secondary_hex
    if include_css:
        body["renderedCss"] = render_css(selection)
    return body


def theme_url(base_url: str, domain: str) -> str:
    """The endpoint for one domain, with the mesh default mapped to its reserved segment."""
    seg = DEFAULT_SEGMENT if not (domain or "").strip() else (domain or "").strip()
    return f"{base_url.rstrip('/')}/bff/admin/themes/{urllib.parse.quote(seg, safe='')}"


def push(base_url: str, domain: str, selection: ThemeSelection, token: str, *,
         include_css: bool = True, timeout: float = _TIMEOUT_S,
         opener=None) -> dict:
    """Set one domain's theme. Returns the stored row; raises :class:`ThemePushError`.

    ``opener`` exists so tests drive the real request-building code without a network:
    the URL, method, headers and body are what break, and a test that stubbed this whole
    function would verify none of them.
    """
    payload = json.dumps(build_payload(selection, include_css=include_css)).encode("utf-8")
    req = urllib.request.Request(
        theme_url(base_url, domain), data=payload, method="PUT",
        headers={
            "Content-Type": "application/json",
            # The BFF gates this on hasRole('ADMIN') and then on canManage(scope, target),
            # so which domains this token may touch is decided there, not here.
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
        })
    _open = opener or urllib.request.urlopen
    try:
        with _open(req, timeout=timeout) as resp:                # noqa: S310 - operator-supplied mesh URL
            raw = resp.read()
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = (e.read() or b"").decode("utf-8", "replace")[:400]
        except Exception:                                        # noqa: BLE001 - detail is best-effort
            pass
        raise ThemePushError(_explain(e.code, domain, detail), e.code) from e
    except (OSError, ValueError) as e:                           # URLError/timeout are OSError
        raise ThemePushError(f"could not reach the admin BFF at {base_url}: {e}") from e
    try:
        return json.loads(raw)
    except ValueError as e:
        raise ThemePushError("the admin BFF returned a non-JSON body") from e


def _explain(status: int, domain: str, detail: str) -> str:
    """Turn the status into the thing the operator has to DO about it.

    A bare "403 Forbidden" against a theme endpoint is genuinely ambiguous on this
    platform — a domain admin editing the mesh default and an admin editing a neighbour's
    domain both land here, and they have different fixes.
    """
    where = "the mesh default" if not (domain or "").strip() else f"domain '{domain}'"
    if status == 401:
        return "not signed in to the mesh (401) — the token is missing, expired or unaccepted"
    if status == 403:
        return (f"not permitted to set the theme for {where} (403) — a domain admin may set "
                f"ONLY their own domain, and the mesh default is superadmin-only because "
                f"it repaints every domain that has not overridden it")
    if status == 400:
        return f"the mesh rejected the theme for {where} (400): {detail or 'invalid selection'}"
    return f"the mesh returned {status} setting the theme for {where}: {detail}"

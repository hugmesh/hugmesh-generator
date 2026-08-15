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

AUTHENTICATION. A caller may hand in a bearer token; when it does not, :func:`resolve_token`
finds one — Vault first, then the environment. It still carries no copy of the LOGIN flow:
it reads a token someone else stored, never mints one, so there is nothing here to drift
from the real sign-in. What the token is ALLOWED to do stays entirely the BFF's decision
(``hasRole('ADMIN')``, then ``canManage(scope, target)``), so a domain admin's token can
theme only their own domain no matter what this module asks for.

Vault is preferred but deliberately not required: it is a DevOps/Kubernetes-lane service
and a docker-compose mesh has no vault container, so requiring it would make this control
permanently dead on the lane the operator actually runs. See :func:`resolve_token`.
"""

from __future__ import annotations

import json
import os
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


#: Where the mesh-admin token lives in Vault, and under which key. One path so the
#: Vaults dialog, this resolver and any runbook all name the same place.
TOKEN_VAULT_PATH = "secret/hugmesh/studio"
TOKEN_VAULT_KEY = "admin_token"

#: The environment fallback, mirroring how Vault's own token is handled here — read from
#: the environment, never written to disk.
TOKEN_ENV_VAR = "HUGMESH_ADMIN_TOKEN"


@dataclass(frozen=True)
class TokenSource:
    """Where a token came from, or what to do when there is none.

    Carries a remedy rather than a bare failure, matching ``vaults.Capability``: a push
    that reports only "no token" sends the operator hunting for a fault that is not there.
    """

    token: str = ""
    origin: str = ""
    detail: str = ""
    remedy: str = ""

    @property
    def available(self) -> bool:
        return bool(self.token)


def resolve_token(explicit: str = "", *, vault_path: str = TOKEN_VAULT_PATH,
                  vault_key: str = TOKEN_VAULT_KEY, env_var: str = TOKEN_ENV_VAR,
                  reader=None, environ=None) -> TokenSource:
    """Find the mesh-admin token: explicit argument, then Vault, then the environment.

    VAULT IS PREFERRED BUT CANNOT BE REQUIRED, and that is the whole reason this is an
    ordered chain rather than a single lookup. ``vaults.vault_capability`` is explicit
    that Vault is a DevOps/Kubernetes-lane service: a docker-compose mesh has no vault
    container at all. Making Vault the only source would therefore ship a theme control
    that is permanently dead on the lane the operator actually runs — the inert-control
    trap this codebase has hit repeatedly, and the one that module's own docstring warns
    about.

    So Vault is used when it is there, the environment when it is not, and when neither
    has it the failure names both options instead of saying "unauthorized".

    THE TOKEN IS NEVER RETURNED IN A DETAIL STRING, only its origin. Details reach logs
    and dialogs; the token must not.
    """
    if explicit and explicit.strip():
        return TokenSource(token=explicit.strip(), origin="argument",
                           detail="using the token supplied by the caller")

    read = reader or _vault_reader
    value, cap = read(vault_path, vault_key)
    if value:
        return TokenSource(token=value, origin="vault",
                           detail=f"read {vault_key} from {vault_path}")

    env = os.environ if environ is None else environ
    from_env = (env.get(env_var) or "").strip()
    if from_env:
        return TokenSource(token=from_env, origin="environment",
                           detail=f"using ${env_var}")

    # Neither source had it. Report BOTH routes, and carry Vault's own reason when it had
    # one — "vault is not on this lane" and "vault is up but the path is empty" need
    # different actions from the operator.
    why = f" Vault: {cap.detail}" if getattr(cap, "detail", "") else ""
    return TokenSource(
        detail=f"no mesh-admin token available.{why}",
        remedy=(f"Store one in Vault at {vault_path} under '{vault_key}' (the Vaults "
                f"dialog writes it on stdin, never argv), or export ${env_var} for this "
                f"session. The token needs ROLE_ADMIN on the mesh; a domain admin's token "
                f"can theme only their own domain."))


def _vault_reader(path: str, key: str):
    """Indirection so :func:`resolve_token` is testable without Vault, and so importing
    this module does not drag the docker-dependent vault helpers in at import time."""
    from . import vaults
    return vaults.get_entry(path, key)


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


def push(base_url: str, domain: str, selection: ThemeSelection, token: str = "", *,
         include_css: bool = True, timeout: float = _TIMEOUT_S,
         opener=None, token_source: TokenSource | None = None) -> dict:
    """Set one domain's theme. Returns the stored row; raises :class:`ThemePushError`.

    ``token`` is optional: when it is empty the token is resolved via
    :func:`resolve_token` (Vault, then the environment), so a GUI caller does not have to
    source credentials itself. An absent token fails BEFORE any request is built, with the
    remedy naming both places it could be stored — rather than sending an anonymous
    request and reporting the mesh's 401 as though the mesh were at fault.

    ``opener`` exists so tests drive the real request-building code without a network:
    the URL, method, headers and body are what break, and a test that stubbed this whole
    function would verify none of them.
    """
    src = token_source or (TokenSource(token=token.strip(), origin="argument")
                           if token and token.strip() else resolve_token())
    if not src.available:
        raise ThemePushError(f"{src.detail} {src.remedy}".strip())
    payload = json.dumps(build_payload(selection, include_css=include_css)).encode("utf-8")
    req = urllib.request.Request(
        theme_url(base_url, domain), data=payload, method="PUT",
        headers={
            "Content-Type": "application/json",
            # The BFF gates this on hasRole('ADMIN') and then on canManage(scope, target),
            # so which domains this token may touch is decided there, not here.
            "Authorization": f"Bearer {src.token}",
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

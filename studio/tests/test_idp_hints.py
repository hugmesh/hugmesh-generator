"""The provider hints the IdP screens show come from ONE table in core/config.py.

Three screens carried their own copy of the issuer / client-id / JWKS placeholder text:
the node wizard's IdP page (gui/pages/idp.py), the provider wizard (gui/pages/
idp_provider.py) and the local mesh's bootstrap tab (gui/pages/localmesh.py). They had
already drifted (the bootstrap tab's OIDC JWKS hint lost the "(override ...)" clause the
other two carry), and the Deploy page spelled the issuer shapes a third way
(``<tenant>``, ``<pool-id>``). This file holds the core table to the derivation it
describes and fails when a front end spells the shapes out again.

Qt-free: the screens' own placeholders are checked in test_idp_hints_gui.py.
"""
from __future__ import annotations

import os

from hugmesh_studio.core.config import (
    IDP_CHOICES, IDP_CLIENT_HINTS, IDP_ISSUER_HINTS, IDP_JWKS_HINTS, IDP_JWKS_SUFFIX,
    idp_effective_jwks)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACKAGE = os.path.join(STUDIO_ROOT, "hugmesh_studio")

EXTERNAL = {p for p in IDP_CHOICES if p != "casdoor"}

#: Fragments only the hint tables spell. A front end that carries one has a copy.
HINT_FRAGMENTS = (
    "login.microsoftonline.com",       # the Entra issuer shape
    "cognito-idp.",                   # the Cognito issuer shape
    "the app registration's Application",    # the Entra client-id hint
    "the Cognito app client id",      # the Cognito client-id hint
    "the OIDC client id registered",  # the generic client-id hint
    "(override if your provider differs)",   # the generic JWKS hint's clause
)


def test_every_external_provider_has_all_three_hints():
    for table in (IDP_ISSUER_HINTS, IDP_CLIENT_HINTS, IDP_JWKS_HINTS):
        assert set(table) == EXTERNAL, "a hint table drifted from IDP_CHOICES"
        assert all(isinstance(v, str) and v.strip() for v in table.values())


def test_the_jwks_hints_name_the_path_the_derivation_uses():
    """A hint must not promise a path the build does not derive: each says "empty =
    <issuer>" plus the suffix idp_effective_jwks appends."""
    for provider in EXTERNAL:
        suffix = IDP_JWKS_SUFFIX[provider]
        assert IDP_JWKS_HINTS[provider].startswith(f"empty = <issuer>{suffix}")
        assert idp_effective_jwks(provider, "https://id.example.org", "") == (
            "https://id.example.org" + suffix)


def test_the_issuer_hints_are_https_shapes_with_placeholders():
    for provider, hint in IDP_ISSUER_HINTS.items():
        assert hint.startswith("https://"), provider
    assert "<tenant-id>" in IDP_ISSUER_HINTS["entra"]
    assert "<region>" in IDP_ISSUER_HINTS["aws"] and "<user-pool-id>" in IDP_ISSUER_HINTS["aws"]


def _front_end_sources():
    """(relative path, text) of every .py under the GUI and the TUI."""
    for sub in ("gui", "tui"):
        for root, _dirs, files in os.walk(os.path.join(PACKAGE, sub)):
            for name in files:
                if name.endswith(".py"):
                    path = os.path.join(root, name)
                    with open(path, encoding="utf-8") as fh:
                        yield os.path.relpath(path, PACKAGE), fh.read()


def _offenders(sources):
    return [(rel, frag) for rel, text in sources for frag in HINT_FRAGMENTS if frag in text]


def test_no_front_end_spells_a_provider_hint_itself():
    """The guard: GUI and TUI read core's table, they never carry the text. Put one of
    the fragments back into a screen and this goes red."""
    sources = list(_front_end_sources())
    assert len(sources) > 20, "the walk found no front-end files"
    assert not _offenders(sources), (
        "provider hint text spelled outside core/config.py (use IDP_ISSUER_HINTS / "
        f"IDP_CLIENT_HINTS / IDP_JWKS_HINTS): {_offenders(sources)}")


def test_the_scan_catches_a_planted_copy():
    """Mutation check on the scan itself: a copy of any hint in a front-end source is
    found, so a refactor of the walk cannot leave the guard passing blind."""
    for frag in HINT_FRAGMENTS:
        assert _offenders([("gui/pages/x.py", f'_HINT = "{frag}"\n')]) == [
            ("gui/pages/x.py", frag)]

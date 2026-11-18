"""A brand profile, read for the local Docker stack (``make stack-up BRAND=<name>``).

WHY. ``brands/<name>.conf`` and ``brands/<name>.yaml`` describe a brand (its title, its
domain, optionally its login colours and font), but only the IMAGE builders read them. The
local Docker stack never did, so ``make stack-up BRAND=acme`` still brought up a mesh that
called itself HugMesh on ``hugmesh.net``: a brand's images were built, and the lane that
runs them ignored the brand.

WHAT IT DOES. :func:`load` reads the profile; :func:`apply` writes the stack's OWN look
(``tests/stack/.theme.css``, the file ``make stack-up`` hands the login page as
``HUG_THEME_CSS``) from its title and colours, and returns the domain for the Makefile to
use as ``DOMAIN`` when the caller named none. The host shell and the sign-in page already
say the name in the theme's header text (host-shell ``BrandNameService``), so the title is
carried there; nothing else needs a code change.

READING IS NOT SOURCING. A ``.conf`` is a shell file the builders ``source``. This module
never does: it takes three variables (``BRAND``, ``BRAND_TITLE``, ``CLUSTER_DOMAIN``) off
lines of the exact form ``NAME=value`` / ``NAME="value"`` / ``NAME='value'`` and nothing
else, so a profile with ``$(...)`` or backticks in it yields that text, never runs it, and
a hostile title reaches the page only through the same CSS string escape every look uses
(:func:`brand_look.look_css`). A ``.yaml`` is read with ``yaml.safe_load``.

Qt-free; nothing here starts a container. ``python3 -m hugmesh_studio.core.brand_profile
apply --brand NAME [--generator-dir D]`` is what the Makefile runs.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass, field
from typing import Any

from . import brand_look
from .look_serving import _DNS_NAME_RE, _ID_RE, default_generator_dir

__all__ = ["BrandProfile", "BrandProfileError", "available", "load", "apply", "main"]

#: Where the profiles live, and where the stack reads its own look from.
BRANDS_DIR = "brands"
THEME_RELPATH = os.path.join("tests", "stack", ".theme.css")
#: The title is shown in a header: one line, short, no control characters.
TITLE_MAX = 60
_CONF_VARS = ("BRAND", "BRAND_TITLE", "CLUSTER_DOMAIN")
_CONF_LINE = re.compile(
    r"""^(?P<name>BRAND|BRAND_TITLE|CLUSTER_DOMAIN)=
        (?: "(?P<dq>[^"\\\n]*)" | '(?P<sq>[^'\n]*)' | (?P<bare>[^\s"'#$`\\;|&<>()]*) )
        \s*(?:\#.*)?$""", re.X)
_LOGIN_THEME_FIELDS = ("primary", "secondary", "font")


class BrandProfileError(Exception):
    """The profile cannot be used; the message says what to change. Nothing was written."""


@dataclass(frozen=True)
class BrandProfile:
    name: str                       # the file stem, also the brand slug
    title: str                      # shown by the shell and the sign-in page
    domain: str                     # the base domain; "" when the profile names none
    look: dict = field(default_factory=dict)   # the login look fields it sets (colours, font)
    source: str = ""                # the file it was read from, relative to brands/


def available(generator_dir: str) -> list[str]:
    """The profile names on offer: every ``brands/<name>.conf|yaml`` that LOADS (so the
    multi-domain registry ``domains.conf``, which is not a brand, is not offered)."""
    d = os.path.join(generator_dir, BRANDS_DIR)
    names = set()
    for f in os.listdir(d) if os.path.isdir(d) else []:
        stem, ext = os.path.splitext(f)
        if ext in (".conf", ".yaml") and _ID_RE.match(stem):
            try:
                load(generator_dir, stem)
            except BrandProfileError:
                continue
            names.add(stem)
    return sorted(names)


def _clean_title(raw: str, where: str) -> str:
    title = " ".join(str(raw).split())          # one line; runs of blanks collapse
    if not title:
        raise BrandProfileError(f"{where}: the brand title is empty")
    if any(ord(c) < 0x20 or ord(c) == 0x7F for c in title):
        raise BrandProfileError(f"{where}: the brand title holds a control character")
    if len(title) > TITLE_MAX:
        raise BrandProfileError(f"{where}: the brand title is {len(title)} characters; at most {TITLE_MAX}")
    return title


def _clean_domain(raw: str, where: str) -> str:
    domain = str(raw or "").strip().lower()
    if not domain:
        return ""
    if not _DNS_NAME_RE.match(domain):
        raise BrandProfileError(f"{where}: '{domain}' is not a domain name (a.b.c, letters, digits, hyphens)")
    return domain


def _read_conf(path: str, name: str) -> BrandProfile:
    found: dict[str, str] = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            m = _CONF_LINE.match(line.rstrip("\n"))
            if not m:
                continue
            value = next(v for v in (m.group("dq"), m.group("sq"), m.group("bare")) if v is not None)
            found.setdefault(m.group("name"), value)     # the first assignment wins
    where = os.path.relpath(path, os.path.dirname(os.path.dirname(path)))
    if "BRAND_TITLE" not in found:
        raise BrandProfileError(f"{where}: no BRAND_TITLE=... line (a plain NAME=\"value\" line; "
                                "this reader does not run the file)")
    return BrandProfile(name=name, title=_clean_title(found["BRAND_TITLE"], where),
                        domain=_clean_domain(found.get("CLUSTER_DOMAIN", ""), where),
                        source=os.path.basename(path))


def _read_yaml(path: str, name: str) -> BrandProfile:
    try:
        import yaml
    except ImportError as exc:                              # pragma: no cover - env without PyYAML
        raise BrandProfileError("reading brands/*.yaml needs PyYAML (pip install pyyaml); "
                                "a brands/<name>.conf needs nothing") from exc
    where = os.path.relpath(path, os.path.dirname(os.path.dirname(path)))
    try:
        with open(path, encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}
    except (OSError, yaml.YAMLError) as exc:
        raise BrandProfileError(f"{where}: not readable YAML: {exc}") from exc
    if not isinstance(data, dict) or not str(data.get("title", "")).strip():
        raise BrandProfileError(f"{where}: no 'title:' (the name the pages show)")
    domains = data.get("domains") or []
    first = domains[0] if isinstance(domains, list) and domains else ""
    look: dict[str, Any] = {}
    theme = data.get("login_theme")
    if isinstance(theme, dict):
        look = {k: str(theme[k]).strip() for k in _LOGIN_THEME_FIELDS if str(theme.get(k, "")).strip()}
    return BrandProfile(name=name, title=_clean_title(data["title"], where),
                        domain=_clean_domain(first, where), look=look,
                        source=os.path.basename(path))


def load(generator_dir: str, name: str) -> BrandProfile:
    """The profile called ``name``. A ``.yaml`` wins over a ``.conf`` of the same name (it
    carries the login colours). Raises :class:`BrandProfileError` naming what is wrong, and
    the profiles that do exist."""
    name = (name or "").strip()
    if not _ID_RE.match(name):
        raise BrandProfileError(f"'{name}' is not a brand name (lowercase letters, digits, hyphens)")
    base = os.path.join(generator_dir, BRANDS_DIR, name)
    for ext, reader in ((".yaml", _read_yaml), (".conf", _read_conf)):
        if os.path.isfile(base + ext):
            return reader(base + ext, name)
    have = ", ".join(available(generator_dir)) or "none"
    raise BrandProfileError(f"no brands/{name}.yaml or brands/{name}.conf (profiles here: {have})")


def look_of(profile: BrandProfile) -> dict:
    """The look fields the stack's own page is given: the colours and font the profile
    sets, and its title as the header text (what the shell and sign-in page say)."""
    return {**profile.look, "header_text": profile.title}


def apply(generator_dir: str, name: str) -> BrandProfile:
    """Write ``tests/stack/.theme.css`` for the brand and return it. The look is composed
    and checked FIRST (:func:`brand_look.look_css` refuses a bad colour or font), so a
    refusal leaves the file as it was."""
    profile = load(generator_dir, name)
    try:
        css = brand_look.look_css(look_of(profile))
    except brand_look.LookError as exc:
        raise BrandProfileError(f"brands/{profile.source}: {exc}") from exc
    path = os.path.join(generator_dir, THEME_RELPATH)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(css)
    os.replace(tmp, path)
    os.chmod(path, 0o644)
    return profile


def main(argv: list[str] | None = None) -> int:
    """``apply|show --brand NAME [--generator-dir D]``. ``apply`` writes the stack's look
    (``make stack-up``); ``show`` only reads the profile (the other ``stack-*`` goals, which
    need the same ``DOMAIN`` and must not rewrite the look). Both print ``DOMAIN=<domain>``
    (empty value when the profile names none) on stdout, ONE line and nothing else there;
    every message goes to stderr. Exit 1 with the reason on stderr and nothing on stdout
    when the profile cannot be used: the Makefile stops on that."""
    ap = argparse.ArgumentParser(prog="brand_profile")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for cmd, text in (("apply", "write the stack's look from a brand profile"),
                      ("show", "read a brand profile and print its domain (writes nothing)")):
        sp = sub.add_parser(cmd, help=text)
        sp.add_argument("--brand", required=True)
        sp.add_argument("--generator-dir", default=default_generator_dir())
    args = ap.parse_args(argv)
    try:
        profile = (apply if args.cmd == "apply" else load)(args.generator_dir, args.brand)
    except (BrandProfileError, OSError) as exc:
        print(f"brand_profile: {exc}", file=sys.stderr)
        return 1
    print(f"brand_profile: {profile.name} ({profile.source}): title '{profile.title}', "
          f"domain {profile.domain or '(none: DOMAIN keeps its default)'}", file=sys.stderr)
    print(f"DOMAIN={profile.domain}")
    return 0


if __name__ == "__main__":
    from .entry import bootstrap as _bootstrap   # the Mac PATH hook: core/entry.py
    _bootstrap()
    raise SystemExit(main())

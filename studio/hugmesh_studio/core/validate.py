"""Identity-field allowlists for the image build.

The Studio passes brand/org/domain/user/home fields straight through to
``build-x86-host-stage4.sh``, where several of them are written into KEY=VALUE
files (``brand.conf`` / ``home.conf``) that the generator ``.``-sources as ROOT
(at build time and at the device's first boot), and into ``sed s|...|VALUE|`` replacements.
A value containing a quote, ``$()``, a backtick, ``;``, ``|``, ``&`` or a newline
therefore becomes root code execution on the build host and on every device the
image is installed onto.

These fields can cross a trust boundary: an admin key-zip's ``domain.conf`` carries
brand/brand_title/org/cluster_domain from a (possibly compromised) domain admin into
the user's build (see :mod:`hugmesh_studio.core.keyzip`). So we fail closed here —
reject (never silently set) any identity value that is not a known-safe shape, mirroring
the admin-bff charset allowlist on targetUser/hardwareClass.

Validation lives at the parse/apply boundary; the generator keeps its own
sink-side escaping as defense-in-depth.
"""
from __future__ import annotations

import re

# A DNS label: brand slugs and per-label hostnames. Lowercase (BRAND is used as a
# hostname slug, e.g. "${BRAND}-pki", so it must be a legal DNS label).
_DNS_LABEL = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
# ORG is a display/cert org name (default "Snapdragon-Systems"): a DNS label but
# case-insensitive (the generator lowercases it for paths via org_lc).
_DNS_LABEL_CI = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")
# A DNS name: one or more labels joined by dots. NO comma (the generator joins
# --domains on the comma it splits on) and no other shell/sed metacharacters.
_DNS_NAME = re.compile(
    r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$"
)
# A unix login name (useradd-legal subset): starts with a letter or underscore.
_USERNAME = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
# A home device spec: LABEL=/UUID=/PARTUUID= or a /dev/ path, safe charset only.
_HOME_DEVICE = re.compile(r"^(LABEL=|UUID=|PARTUUID=|/dev/)[A-Za-z0-9._/=:+-]+$")
# A backup path / "auto": a contained path with NO shell metacharacters or whitespace.
_HOME_BACKUP = re.compile(r"^(auto|[A-Za-z0-9._/:+-]+)$")
# A brand TITLE is free-ish text but MUST NOT contain any character that is shell- or
# sed-meaningful when the value lands in a sourced KEY=VALUE file or a sed replacement:
# quote, backslash, dollar, backtick, newline/CR, pipe, ampersand, and other shell meta.
_BRAND_TITLE_FORBIDDEN = re.compile(r"""["'\\$`\r\n|&;<>(){}*?!]""")


class IdentityValidationError(ValueError):
    """Raised when an identity field fails its allowlist (fail-closed)."""


def _require(ok: bool, field: str, value: str) -> None:
    if not ok:
        raise IdentityValidationError(
            f"invalid {field}: {value!r} — rejected by the identity allowlist "
            f"(this value would be written into a root-sourced config / sed replacement)"
        )


def validate_brand(value: str) -> str:
    _require(bool(_DNS_LABEL.fullmatch(value)), "brand", value)
    return value


def validate_org(value: str) -> str:
    _require(bool(_DNS_LABEL_CI.fullmatch(value)), "org", value)
    return value


def validate_brand_title(value: str) -> str:
    # printable, no control chars, no shell/sed metacharacters.
    ok = bool(value) and value.isprintable() and not _BRAND_TITLE_FORBIDDEN.search(value)
    _require(ok, "brand_title", value)
    return value


_ACCENT = re.compile(r"^#[0-9A-Fa-f]{6}$")


def validate_accent_color(value: str) -> str:
    # a brand accent is an "#RRGGBB" hex colour (mirrors the build-script accent
    # gate); "" means no accent. It flows to --accent-color and into a root-sourced
    # brand.conf, so reject anything that is not exactly that.
    ok = value == "" or bool(_ACCENT.fullmatch(value))
    _require(ok, "accent_color", value)
    return value


def validate_login_color(field: str, value: str) -> str:
    # web login-theme colours keep the same strict "#RRGGBB"-or-empty shape as
    # accent_color: they flow into the SNAP_THEME_CSS token text (compose env /
    # ConfigMap) and brands/<brand>.yaml, never free-form. "" = shipped default.
    ok = value == "" or bool(_ACCENT.fullmatch(value))
    _require(ok, field, value)
    return value


def validate_domain_name(value: str) -> str:
    _require(bool(_DNS_NAME.fullmatch(value)), "domain", value)
    return value


def validate_username(value: str) -> str:
    _require(bool(_USERNAME.fullmatch(value)), "local_user", value)
    return value


def validate_home_device(value: str) -> str:
    _require(bool(_HOME_DEVICE.fullmatch(value)), "home_device", value)
    return value


def validate_home_backup(value: str) -> str:
    _require(bool(_HOME_BACKUP.fullmatch(value)), "home_backup", value)
    return value


# A Portage package atom (category/name): the space-separated words the ARM builders
# read into --extra-packages (and the new --packages-add/--packages-drop lists) via
# `read -ra`. The category is a lowercase slug; the package name may carry caps
# (e.g. app-editors/vim, sys-fs/ecryptfs-utils, dev-libs/libFoo). Shell-word-safe — no
# quote/space/$()/;|&/glob — so a value can never break out of the emerge command line.
_PACKAGE_ATOM = re.compile(r"^[a-z0-9][a-z0-9+._-]*/[A-Za-z0-9+._-]+$")


def validate_package_atoms(value: str) -> str:
    """Validate a SPACE-SEPARATED list of Portage atoms (category/name). Empty is OK
    (no packages). Every word must be a plain category/name atom — fail closed on any
    shell/sed-meaningful character so the list stays a safe `read -ra` payload. Same
    allowlist at every surface (Studio, headless, and the web DTO validators)."""
    for atom in value.split():
        _require(bool(_PACKAGE_ATOM.fullmatch(atom)), "package_atom", atom)
    return value

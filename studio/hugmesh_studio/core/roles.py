"""THE role vocabulary, read from ``scripts/_roles-lib.sh``.

An image is identified by a device platform and then a ROLE. That role token used
to be spelled independently in ~14 places — the same logical node took ``be``
on x86 and ``--role backend`` on rpi5 — and the Studio bridged the two with a
hand-written ``RPI5_ROLE_MAP``. There is now ONE declaration, and it lives in the
SHELL (``scripts/_roles-lib.sh``) because the ten builders must not acquire a Python
dependency, while the Studio already runs Python. This module is the reader.

Deliberately NOT a second declaration: nothing here restates a role name, an alias,
a hostname suffix or a keys profile. If you find yourself typing a role literal into
this file, it belongs in the shell lib instead.

Direction matters. ``tests/scripts/test-platform-key-spelling.sh`` uses ``config.py``
as the reference for the PLATFORM key and reads the shell; for the ROLE key the
reference is the shell and Python reads it. The guard
``tests/scripts/test-role-key-spelling.sh`` asserts set-equality in both directions,
so neither side can drift silently.

No import-time assertion that ``config.ROLE_CHOICES`` matches: an import-time assert
would break the whole Studio at runtime mid-migration. Agreement is the guard's job.
"""

from __future__ import annotations

import os
import re
from functools import lru_cache

# ── WHERE THE VOCABULARY IS READ FROM ───────────────────────────────────────────
# TWO paths, and the second is not a fallback for a broken checkout — it is the ONLY
# one that exists in an INSTALLED Studio.
#
#   checkout   <repo>/scripts/_roles-lib.sh, four dirnames up from this file
#              (core/ -> hugmesh_studio/ -> studio/ -> repo). THE declaration.
#   packaged   _roles-lib.sh beside this module, shipped as package-data — a
#              byte-identical mirror, never edited by hand.
#
# The packaged mirror exists because `pip install ./studio` (how BOTH installers are
# built: the Flatpak manifest's build context is studio/, which cannot even see the
# repo root, and the MSI freezes the same install) copies hugmesh_studio/ into
# site-packages with nothing above it. There the checkout path resolves to
# `<prefix>/lib/python3.x/scripts/_roles-lib.sh` and is absent — and since config.py
# builds RPI5_ROLE_MAP/JETSON_ROLE_MAP out of composite_aliases() at MODULE IMPORT
# time, and _lib_text() raises rather than degrading (deliberately — see
# RoleVocabularyError), that is not a missing feature but a bundle that cannot start.
# An installed Studio died on `import hugmesh_studio.core.config` for exactly this.
#
# THE CHECKOUT COPY WINS when it exists. So an edit to scripts/_roles-lib.sh takes
# effect immediately in a checkout, and a stale mirror can never quietly become the
# thing the Studio obeys; studio/tests/test_roles_lib_packaging.py fails on drift.
#
# $HUGMESH_ROLES_LIB overrides both — for a frozen bundle pointed at an operator's
# own checkout, and so a test can aim the reader at a fixture.
_LIB_REL = os.path.join("scripts", "_roles-lib.sh")
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))))

#: Env override, highest precedence. Empty/unset means "use the two paths below".
ROLES_LIB_ENV = "HUGMESH_ROLES_LIB"
#: The declaration, in a checkout.
CHECKOUT_ROLES_LIB = os.path.join(_REPO_ROOT, _LIB_REL)
#: The byte-identical mirror that ships inside the wheel/Flatpak/MSI.
PACKAGED_ROLES_LIB = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "_roles-lib.sh")


def roles_lib_candidates() -> list[str]:
    """Every path the vocabulary may be read from, in precedence order."""
    override = os.environ.get(ROLES_LIB_ENV, "").strip()
    return ([override] if override else []) + [CHECKOUT_ROLES_LIB, PACKAGED_ROLES_LIB]


def roles_lib_path() -> str:
    """The file the reader will actually open.

    Resolved per call, not once at import: the env override has to be settable by a
    caller (and by a test) after this module is already imported. Falls back to the
    checkout path when NOTHING exists, so the error names the path a developer
    expects rather than an internal one.
    """
    for path in roles_lib_candidates():
        if os.path.isfile(path):
            return path
    return CHECKOUT_ROLES_LIB



class RoleVocabularyError(RuntimeError):
    """The role vocabulary could not be read, or a role is not in it.

    Raised rather than defaulted ON PURPOSE. Every historical bug in this area was a
    silent fallback: four ``*) -> "host"`` catch-alls handed the wrong
    gen-provision-keys profile to any role missing from a hand-copied table.
    """


def _lib_text() -> str:
    path = roles_lib_path()
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError as e:
        raise RoleVocabularyError(
            f"cannot read the role vocabulary at {path}: {e}"
            f" (tried: {', '.join(roles_lib_candidates())};"
            f" set ${ROLES_LIB_ENV} to point at scripts/_roles-lib.sh)") from e


def _scalar(text: str, name: str) -> str:
    m = re.search(r'(?m)^%s="([^"]*)"' % re.escape(name), text)
    if not m:
        raise RoleVocabularyError(f"{name} not found in {_LIB_REL}")
    return m.group(1)


def _table(text: str, name: str) -> list[tuple[str, str]]:
    """A multi-line ``NAME="\\n k=v\\n ..."`` block -> [(k, v), ...], order preserved."""
    m = re.search(r'(?ms)^%s="\n(.*?)^"' % re.escape(name), text)
    if not m:
        raise RoleVocabularyError(f"{name} not found in {_LIB_REL}")
    out: list[tuple[str, str]] = []
    for line in m.group(1).splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        k, _, v = line.partition("=")
        out.append((k, v))
    return out


@lru_cache(maxsize=1)
def _vocab() -> dict:
    t = _lib_text()
    aliases = dict(_table(t, "HUGMESH_ROLE_ALIASES"))
    composite: dict[str, tuple[str, str, str]] = {}
    for alias, val in _table(t, "HUGMESH_ROLE_COMPOSITE"):
        role, _, axis = val.partition(":")
        key, _, av = axis.partition("=")
        composite[alias] = (role, key, av)
    hostname: dict[tuple[str, str], str] = {}
    for key, sfx in _table(t, "HUGMESH_ROLE_HOSTNAME_SUFFIX"):
        plat, _, role = key.partition(":")
        hostname[(plat, role)] = sfx
    return {
        "canonical": tuple(_scalar(t, "HUGMESH_ROLES_CANONICAL").split()),
        "platform": {
            "x86": tuple(_scalar(t, "HUGMESH_ROLES_X86").split()),
            "rpi5": tuple(_scalar(t, "HUGMESH_ROLES_RPI5").split()),
            "jetson": tuple(_scalar(t, "HUGMESH_ROLES_JETSON").split()),
            # The two Orange Pi NODE-axis boards (EXPERIMENTAL): their set holds
            # `desktop` (the light desktop, whose Studio id is the board itself) plus
            # the cluster node roles they build.
            "orangepi5": tuple(_scalar(t, "HUGMESH_ROLES_ORANGEPI5").split()),
            "orangepi4-lts": tuple(_scalar(t, "HUGMESH_ROLES_ORANGEPI4LTS").split()),
        },
        "min_ram_gb": {k: int(v) for k, v in _table(t, "HUGMESH_ROLE_MIN_RAM_GB")},
        "board_ram_gb": {k: tuple(int(x) for x in v.split(","))
                         for k, v in _table(t, "HUGMESH_BOARD_RAM_GB")},
        "aliases": aliases,
        "composite": composite,
        "hostname": hostname,
        "keyprofile": dict(_table(t, "HUGMESH_ROLE_KEYPROFILE")),
    }


# ── public surface ──────────────────────────────────────────────────────────────

def canonical_roles() -> tuple[str, ...]:
    """The 13 canonical role tokens, declaration order."""
    return _vocab()["canonical"]


def roles_for_platform(platform: str) -> tuple[str, ...]:
    """The canonical roles a platform builds. () for the five free-slug boards,
    which have no role axis at all (``--role`` there is a hostname/marker); the two
    Orange Pi node-axis boards list `desktop` plus their node roles."""
    return _vocab()["platform"].get(platform, ())


def min_ram_gb(role: str) -> int | None:
    """The RAM floor (GB) a cluster node role needs (scripts/_roles-lib.sh
    HUGMESH_ROLE_MIN_RAM_GB), or None for a role with no floor."""
    return _vocab()["min_ram_gb"].get(canonicalize(role))


def board_ram_gb(board: str) -> tuple[int, ...]:
    """The RAM sizes (GB) ``board`` is sold with (HUGMESH_BOARD_RAM_GB); () when
    unknown. A hint for the RAM picker, never a refusal (the list may be stale)."""
    return _vocab()["board_ram_gb"].get(board, ())


def ram_choices(role: str, board: str) -> tuple[int, ...]:
    """The RAM sizes to OFFER for ``role`` on ``board``: the board's sizes at or above
    the role's floor (the same rule the builders enforce with --ram-gb)."""
    floor = min_ram_gb(role) or 0
    return tuple(g for g in board_ram_gb(board) if g >= floor)


def ram_required(role: str) -> bool:
    """omnibus needs --ram-gb (one image serves every RAM size a board is sold with)."""
    return canonicalize(role) == "omnibus"


def aliases() -> dict[str, str]:
    """Pure spelling aliases, ``alias -> canonical``. Input only, permanent."""
    return dict(_vocab()["aliases"])


def composite_aliases() -> dict[str, tuple[str, str, str]]:
    """``alias -> (canonical role, extra-axis key, extra-axis value)``.

    NOT pure spelling: each carries a platform or a flag, so a caller that cannot
    honour the extra axis must not fold one. This is what remains of
    ``RPI5_ROLE_MAP``/``JETSON_ROLE_MAP`` — derived, not restated, and it exists only
    because the Studio still mangles the platform into the role id
    (``rpi5-desktop``/``jetson-desktop``). Retiring those ids touches the persisted
    session schema and is deliberately deferred.
    """
    return dict(_vocab()["composite"])


def is_canonical(role: str) -> bool:
    return role in _vocab()["canonical"]


def canonicalize(role: str, *, default: str | None = None) -> str:
    """Fold a pure spelling alias onto its canonical token.

    Composite aliases are NOT folded (they would lose their second axis). Unknown
    tokens come back unchanged when ``default`` is None — this is the READ-SIDE
    canonicalisation used on persisted state, where an id from an old session record
    or a Studio pseudo-role (a platform id used as a role id) must survive rather
    than explode.
    """
    v = _vocab()
    if role in v["canonical"]:
        return role
    return v["aliases"].get(role, role if default is None else default)


def aliases_of(canonical: str) -> tuple[str, ...]:
    """Every spelling that resolves to ``canonical``, canonical first.

    Used by the artifact globbers: an image built under the old spelling
    (``hugmesh-x86-amd64-be-test-*.img``) keeps its name and must stay findable.
    """
    v = _vocab()
    return (canonical,) + tuple(a for a, c in v["aliases"].items() if c == canonical)


def accepts(role: str, platform: str) -> bool:
    """Would the builder for ``platform`` accept this token (canonical or alias)?"""
    allowed = roles_for_platform(platform)
    return bool(allowed) and canonicalize(role) in allowed


def builder_role(role: str, platform: str) -> str:
    """The token to put on the builder's ``--role``. Composite aliases resolve to
    their canonical role here (the caller already emitted the extra axis)."""
    comp = _vocab()["composite"].get(role)
    if comp is not None:
        return comp[0]
    return canonicalize(role)


def hostname(platform: str, role: str, brand: str, board: str = "") -> str:
    """The default hostname the builder assigns with no ``-H``.

    ``{brand}-{role}`` derived, with the exceptions declared in the shell lib. This
    replaces the 20-entry table that used to be transcribed into ``config.py``.

    Resolved through :func:`builder_role`, not :func:`canonicalize`: the hostname a
    builder assigns follows the token it is actually GIVEN, so a composite id must be
    folded here too. (``rpi5-desktop`` previously derived ``{brand}-rpi5-desktop``
    while the builder, handed ``--role desktop``, produced ``{brand}-desktop``.)
    """
    role = builder_role(role, platform)
    if platform == "rpi5" and role == "generic":
        return f"gentoo-{board or 'rpi5'}"
    sfx = _vocab()["hostname"].get((platform, role))
    return f"{brand}-{sfx}" if sfx else f"{brand}-{role}"


def key_profile(role: str) -> str:
    """The ``gen-provision-keys.sh --role`` profile for a node role.

    Raises for a role with no declared profile. NO fallback: the historical
    ``*) -> "host"`` catch-all silently provisioned backend and frontend nodes with
    the worker keys profile whenever a table went stale.
    """
    r = canonicalize(role)
    try:
        return _vocab()["keyprofile"][r]
    except KeyError:
        raise RoleVocabularyError(
            f"no keys profile declared for role {role!r}"
            + (f" (canonical {r!r})" if r != role else "")
            + " — add it to HUGMESH_ROLE_KEYPROFILE in scripts/_roles-lib.sh rather "
              "than defaulting it; a wrong keys profile provisions a node with the "
              "wrong credentials") from None

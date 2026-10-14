"""The brand record: one superbrand governing its brands (hugmesh-generator#654, D1-D5, D10).

ONE FILE PER MESH, ``brand-record.json``, in the Studio state folder (never in the
shared brands/ checkout). It holds an explicit ``superbrand`` block (id, title,
organisation, public name, internal root name, central sign-in, the default look —
which holds the sign-in page's style and decoration — and the default ways to reach
it) and a ``brands``
list of rows (``config.Domain``). Everything else is a PROJECTION of it:

* the mesh manifest — ``superbrand.id`` becomes the manifest's ``brand``, the internal
  root name its ``superdomain``, ``brands`` its ``domains`` (:func:`manifest_from_record`;
  both manifest emitters already write the same header and rows, see
  ``config.brand_header_fields`` / ``config.manifest_domain_rows``);
* the Docker mesh — ``LocalMeshBootstrapConfig`` carries the block and the rows, and
  ``hugmesh-mesh-bootstrap up --record FILE`` starts from a record;
* the image builders — a GENERATED shell profile (:func:`builder_profile`): values from a
  safe character set, single-quoted, re-parsed strictly by :func:`parse_builder_profile`,
  so a brand title can never run code in a builder that sources it;
* the saved mesh — it embeds the bootstrap config, and so the record, as it always has.

NO SECRET. :func:`secret_problems` refuses token-shaped values, PEM blocks and Tor key
lines on every save. The bytes carry no clock value: the window and the text screens
given the same inputs write the same file (a design's copy date is an INPUT the caller
hands in, not something read here).

THE COPY SITES. A Domain field used to have about ten places that copied rows by a
literal key list, and each dropped a key it did not know. They are listed by name in
:data:`COPY_SITES`; every one now copies by the field list (``config.DOMAIN_FIELDS``),
and studio/tests/test_brand_record_copy_sites.py drives one row through all of them and
back, then deletes a key at each site in turn and shows the round trip go red. Two
sites are NOT converted and are named in :data:`COPY_SITES_STILL_DROPPING`: the
window's Domains table rebuilds every row from its cells, so a Next through it erases
a brand's id, look, ways and sign-in port today. They belong to the brands-table lane.

Qt-free; the screens and the text front end call this, never the other way round.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import asdict, dataclass, field
from typing import Any

from . import own_casdoor, plain_words
from .config import (DOMAIN_FIELDS, DOMAIN_IDP_OWN, DOMAIN_IDP_SUPERDOMAIN, Domain,
                     ImageConfig, brand_header_fields, default_brand_id,
                     domain_rows_to_dict, manifest_domain_rows)
from .domain_services import tor_domain_entries
from .state_paths import state_dir
from .validate import IdentityValidationError, validate_brand_title

__all__ = [
    "SCHEMA", "RECORD_FILENAME", "DESIGNS_SUBDIR", "LOOK_KEYS", "COPY_SITES",
    "COPY_SITES_STILL_DROPPING",
    "Superbrand", "BrandRecord", "RecordRefused", "ProfileRefused",
    "brand_id", "brand_id_problem", "stored_id_problem", "profile_names",
    "look_problems", "secret_problems",
    "record_problems", "set_ways", "effective_look", "way_effects", "show_record_lines",
    "builder_profile", "parse_builder_profile", "write_branding_dir",
    "record_from_image_config", "apply_record_to_image_config",
    "record_from_bootstrap", "apply_record_to_bootstrap", "manifest_from_record",
    "record_path", "save_record", "load_record",
    "designs_dir", "save_design", "load_design", "list_designs", "choose_design",
    "issuer_ports",
]

SCHEMA = 1
RECORD_FILENAME = "brand-record.json"
#: The superbrand store: ``<state dir>/superbrands/<design name>.json``.
DESIGNS_SUBDIR = "superbrands"

#: The look fields a brand may override, one by one (D7). The superbrand's ``look``
#: carries the defaults; a brand's ``look`` carries ONLY the fields it changes.
LOOK_KEYS: tuple[str, ...] = ("primary", "secondary", "preset", "mode", "font",
                              "style", "decor", "bg_effect")

#: Every place a brand row is copied, by name. A site listed here copies by the field
#: list; the mutation battery deletes a key at each one and expects the round trip to
#: fail. (fleet.py's two sites copy with asdict and are listed for the battery.)
COPY_SITES: tuple[str, ...] = (
    "config.ImageConfig._domain_from_dict",
    "config.domain_rows_to_dict",
    "config.ImageConfig.mesh_manifest",
    "worklist_driver.WorklistDriver.manifest_v2",
    "local_mesh_domains.bootstrap_domain_records",
    "local_mesh_domains.domains_from_bootstrap",
    "local_mesh_domains.record_walk",
    "local_mesh_domains.apply_imported_domains",
    "local_mesh_bootstrap._domain_record",
    "fleet.fleet_domain_fields",
    "fleet.fleet_domains_from_config",
)

#: Copy sites that STILL rebuild a row from a literal key list and so drop ``id``,
#: ``look``, ``ways`` and ``issuer_port`` (the window's Domains table; the Docker
#: mesh page commits through the same ``rows()``). Named here so the claim above is
#: exact; converting them is the brands-table lane's (it owns gui/pages/domains.py).
COPY_SITES_STILL_DROPPING: tuple[str, ...] = (
    "gui.pages.domains.DomainsTableBody.rows",
    "gui.pages.localmesh.LocalMeshPage._commit_domains",
)

# ── the id rule (D4) ─────────────────────────────────────────────────────────────────
#: The strictest rule in use: a DNS label of at most 59 characters, starting and ending
#: alphanumeric (the registry's DomainSlug rule; hugmesh-tor-reconcile allows 63 and the
#: issuer sanitiser is unbounded — the record uses the tightest so every consumer
#: accepts the one text).
BRAND_ID_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,57}[a-z0-9])?$")
#: ``default`` is the superbrand's run-time key in every back end; ``domains`` names
#: brands/domains.conf, the CA registry, which discover_brands never offers either.
RESERVED_IDS: tuple[str, ...] = ("default", "domains")


def brand_id(row) -> str:
    """The id of a brand row: its stored ``id``, else the default derived from its
    public name (``own_casdoor.slug``). A record made before #654 has no stored ids,
    so it keeps exactly the ids its running mesh already uses."""
    get = row.get if isinstance(row, dict) else (lambda k, _r=row: getattr(_r, k, ""))
    return str(get("id") or "").strip() or default_brand_id(str(get("name") or ""))


def profile_names(generator_dir: str) -> tuple[str, ...]:
    """The brands/*.conf profile names (the files the builders source), minus the CA
    registry. A brand id must not name one: ``make BRAND=<id>`` would source it."""
    out: set[str] = set()
    try:
        for name in os.listdir(os.path.join(generator_dir, "brands")):
            if name.endswith(".conf"):
                out.add(name[: -len(".conf")])
    except OSError:
        pass
    return tuple(sorted(out - set(RESERVED_IDS)))


#: Why a stored id must still equal the derived one. The Docker mesh's stack node
#: (core/local_stack_node.py) hands own_casdoor the brand NAMES only, so its tenant
#: keys and compose services derive the id from the name while the Tor key folder
#: (domain_services.onion_slug) reads the stored one; a stored id that differs would
#: mint the onion for a tenant the gateway never registers. Refused here until that
#: file passes ids (own_casdoor.tenancy_env/compose_overlay already take them).
STORED_ID_MUST_MATCH = ("the Docker mesh still derives a brand's id from its public "
                        "name, so the record accepts only that id today")


def stored_id_problem(row) -> str:
    """Why a row's STORED id cannot be kept ("" when it can): it differs from the id
    its public name derives (D4: one text every consumer shares, and today the Docker
    mesh is a consumer that derives)."""
    stored = str(getattr(row, "id", "") or "").strip()
    name = str(getattr(row, "name", "") or "")
    if not stored or stored == default_brand_id(name):
        return ""
    return (f"its stored id ‘{stored}’ differs from the id its public name derives "
            f"(‘{default_brand_id(name)}’); {STORED_ID_MUST_MATCH}")


def brand_id_problem(candidate: str, *, superbrand_id: str = "", taken=(),
                     profiles=()) -> str:
    """Why ``candidate`` cannot be a brand's id ("" when it can): every refusal of D4,
    each with its reason. ``taken`` are the other brands' ids; ``profiles`` the
    brands/*.conf names (:func:`profile_names`)."""
    cid = (candidate or "").strip()
    if not cid:
        return "a brand needs an id (the default is made from its public name)"
    if not BRAND_ID_RE.match(cid):
        return (f"‘{cid}’ is not a DNS label of at most 59 characters that starts and "
                "ends with a letter or digit (lowercase letters, digits and dashes only)")
    if cid in RESERVED_IDS:
        return (f"‘{cid}’ is reserved: " +
                ("it is the superbrand's run-time key in every back end"
                 if cid == "default" else "brands/domains.conf is the CA registry"))
    if superbrand_id and cid == superbrand_id.strip():
        return f"‘{cid}’ is the superbrand's id"
    if cid.endswith("-pki"):
        return (f"‘{cid}’ ends in -pki, the suffix of another brand's PKI namespace "
                "(a path it would be confused with)")
    if cid in {str(p).strip() for p in profiles}:
        return f"‘{cid}’ names an existing brands/{cid}.conf profile"
    if cid in {str(t).strip() for t in taken}:
        return f"‘{cid}’ is already taken by another brand"
    return ""


# ── the superbrand block ─────────────────────────────────────────────────────────────
@dataclass
class Superbrand:
    """The mesh's one governing brand as the record holds it (D1, D2). Every text field
    defaults to "" so a saved block carries ONLY what was chosen; the consumers supply
    their own defaults (ImageConfig's 'hugmesh' / 'HugMesh Systems')."""
    id: str = ""
    title: str = ""
    org: str = ""
    public_name: str = ""
    #: The tailnet root every node joins (the builders' --superdomain). "" = <id>.internal.
    internal_root: str = ""
    #: The central sign-in's issuer as the path that starts the mesh prints it. "" = the
    #: path derives it (test: http://localhost:8000; prod: https://id.<public name>).
    central_signin: str = ""
    look: dict[str, Any] = field(default_factory=dict)
    ways: dict[str, Any] = field(default_factory=dict)

    def effective_internal_root(self) -> str:
        return self.internal_root.strip() or f"{self.id.strip() or 'hugmesh'}.internal"

    # The sign-in page's shape and menu decoration are the look's ``style`` and
    # ``decor`` fields, nothing else: one representation, so show-record, the image
    # config and the manifest header cannot read different values for the same thing.
    @property
    def login_style(self) -> str:
        return str((self.look or {}).get("style") or "")

    @property
    def login_decor(self) -> str:
        return str((self.look or {}).get("decor") or "")

    def to_dict(self) -> dict[str, Any]:
        """Every key that says something; an empty one is left out so an older file
        keeps its bytes."""
        return {k: v for k, v in asdict(self).items() if v not in ("", {}, None)}

    @classmethod
    def from_dict(cls, d: dict[str, Any] | None) -> "Superbrand":
        known = set(cls.__dataclass_fields__)
        kw: dict[str, Any] = {}
        for k, v in (d or {}).items():
            if k not in known:
                continue
            if k in ("look", "ways"):
                if v is None:
                    v = {}
                elif not isinstance(v, dict):
                    raise ValueError(f"superbrand.{k} must be an object, got {v!r}")
                v = dict(v)
            else:
                v = "" if v is None else str(v)
            kw[k] = v
        # a block written with separate login_style/login_decor keys (an early shape
        # of this record) folds them into the look; the look's own value wins
        look = kw.setdefault("look", {})
        for old, new in (("login_style", "style"), ("login_decor", "decor")):
            v = (d or {}).get(old)
            if isinstance(v, str) and v and not look.get(new):
                look[new] = v
        return cls(**kw)


class RecordRefused(ValueError):
    """A save refused, with every reason (never a partial file)."""

    def __init__(self, problems: list[str]):
        super().__init__("; ".join(problems))
        self.problems = list(problems)


@dataclass
class BrandRecord:
    """The record: one superbrand block and a list of brand rows (``config.Domain``)."""
    superbrand: Superbrand = field(default_factory=Superbrand)
    brands: list[Domain] = field(default_factory=list)
    #: {"design": <stored design name>, "date": "YYYY-MM-DD"} once a stored design was
    #: copied in (D5). The record never refers BACK to the store.
    copied_from: dict[str, str] = field(default_factory=dict)
    schema: int = SCHEMA

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {"schema": self.schema,
                               "superbrand": self.superbrand.to_dict(),
                               "brands": domain_rows_to_dict(self.brands)}
        if self.copied_from:
            out["copied_from"] = dict(self.copied_from)
        return out

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "BrandRecord":
        """Load a record. A pre-#654 MESH MANIFEST (header keys and ``domains``, no
        ``superbrand`` block) is MIGRATED: its header becomes the superbrand block
        and its rows the brands, with the ids the running mesh already uses."""
        if not isinstance(d, dict):
            raise ValueError("brand record must be a JSON object")
        if "superbrand" not in d and ("brand" in d or "domains" in d):
            return cls._from_manifest(d)
        sb = Superbrand.from_dict(d.get("superbrand") or {})
        rows = [ImageConfig._domain_from_dict(x) for x in (d.get("brands") or [])
                if isinstance(x, dict)]
        copied = d.get("copied_from") or {}
        if not isinstance(copied, dict):
            copied = {}
        schema = d.get("schema", SCHEMA)
        if not isinstance(schema, int) or isinstance(schema, bool):
            raise ValueError(f"brand record schema must be a number, got {schema!r}")
        if schema > SCHEMA:
            raise ValueError(f"brand record schema {schema} is newer than this Studio "
                             f"reads ({SCHEMA})")
        return cls(superbrand=sb, brands=rows,
                   copied_from={str(k): str(v) for k, v in copied.items()},
                   schema=SCHEMA)

    @classmethod
    def _from_manifest(cls, m: dict[str, Any]) -> "BrandRecord":
        look = {k: str(m.get(src)) for k, src in (("style", "login_style"),
                                                   ("decor", "login_decor"))
                if m.get(src)}
        sb = Superbrand(id=str(m.get("brand") or ""), title=str(m.get("brand_title") or ""),
                        org=str(m.get("org") or ""),
                        public_name=str(m.get("cluster_domain") or ""),
                        internal_root=str(m.get("superdomain") or ""), look=look)
        rows = [ImageConfig._domain_from_dict(x) for x in (m.get("domains") or [])
                if isinstance(x, dict)]
        return cls(superbrand=sb, brands=rows)

    def brand(self, bid: str) -> Domain | None:
        for d in self.brands:
            if brand_id(d) == (bid or "").strip():
                return d
        return None

    def ids(self) -> list[str]:
        return [brand_id(d) for d in self.brands]


# ── the look (D6, D7) ────────────────────────────────────────────────────────────────
_HEX = re.compile(r"^#[0-9A-Fa-f]{6}$")


def look_problems(look: dict[str, Any], where: str) -> list[str]:
    """Why a look block cannot be saved ([] when it can): an unknown key, a value that
    is not text, or a value no theme table knows (fail-closed: theme.style_tokens would
    otherwise fall back to the shipped style and the preview would lie)."""
    from . import fonts, theme, theme_presets   # caller-side, like config does
    problems: list[str] = []
    if not isinstance(look, dict):
        return [f"{where}: look must be an object"]
    for k, v in look.items():
        if k not in LOOK_KEYS:
            problems.append(f"{where}: unknown look field ‘{k}’ (one of "
                            f"{', '.join(LOOK_KEYS)})")
            continue
        if not isinstance(v, str):
            problems.append(f"{where}: look.{k} must be text")
            continue
        if not v:
            continue
        if k in ("primary", "secondary") and not _HEX.match(v):
            problems.append(f"{where}: look.{k} must be #RRGGBB, got ‘{v}’")
        elif k == "preset":
            try:
                theme_presets.by_id(v)
            except KeyError:
                problems.append(f"{where}: unknown look.preset ‘{v}’")
        elif k == "mode" and v not in ("dark", "light"):
            problems.append(f"{where}: look.mode must be dark or light, got ‘{v}’")
        elif k == "font" and v not in fonts.FONT_PRESETS:
            problems.append(f"{where}: unknown look.font ‘{v}’")
        elif k == "style" and v not in theme.STYLE_VARIANTS:
            problems.append(f"{where}: unknown look.style ‘{v}’")
        elif k == "decor" and v not in theme.DECOR_VARIANTS:
            problems.append(f"{where}: unknown look.decor ‘{v}’")
        elif k == "bg_effect" and v not in theme.BG_EFFECTS:
            problems.append(f"{where}: unknown look.bg_effect ‘{v}’")
    return problems


def effective_look(record: BrandRecord, row=None) -> dict[str, tuple[str, str]]:
    """look key -> (value, source) for a brand row (or the superbrand when ``row`` is
    None): the superbrand's value unless the brand overrides THAT field (D7). The
    source is one of plain_words.LOOK_SOURCE; "" with the superbrand's source means
    the shipped page."""
    out: dict[str, tuple[str, str]] = {}
    sb = record.superbrand.look or {}
    own = (getattr(row, "look", None) or {}) if row is not None else {}
    for k in LOOK_KEYS:
        if row is not None and own.get(k):
            out[k] = (str(own[k]), plain_words.LOOK_SOURCE["own"])
        elif row is not None:
            out[k] = (str(sb.get(k) or ""), plain_words.LOOK_SOURCE["inherited"])
        else:
            out[k] = (str(sb.get(k) or ""), plain_words.LOOK_SOURCE["default"])
    return out


# ── the ways to reach a brand (D10) ──────────────────────────────────────────────────
_PROVIDER_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
_DNS_NAME_RE = re.compile(
    r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$")


def default_internal_name(record: BrandRecord, row) -> str:
    return f"{brand_id(row)}.{record.superbrand.effective_internal_root()}"


def ways_problems(ways: dict[str, Any], where: str, *, internal_root: str = "",
                  superbrand: bool = False) -> list[str]:
    """Why a ways block cannot be saved ([] when it can). ``tor`` is a key of the
    SUPERBRAND's block only (the mesh's own Tor address); a brand's Tor address is
    its row's ``tor`` field, which set_ways writes, so a ``tor`` key in a brand's
    ways would be a second place saying the same thing and is refused."""
    problems: list[str] = []
    if not isinstance(ways, dict):
        return [f"{where}: ways must be an object"]
    allowed = ("internal_name", "public") + (("tor",) if superbrand else ())
    for k in ways:
        if k not in allowed:
            problems.append(f"{where}: unknown way ‘{k}’ ({', '.join(allowed)})"
                            + ("" if superbrand or k != "tor" else
                               "; a brand's Tor address is its tor field, written by "
                               "set_ways"))
    if superbrand and "tor" in ways and not isinstance(ways["tor"], bool):
        problems.append(f"{where}: ways.tor must be yes or no (true/false)")
    name = ways.get("internal_name")
    if name is not None:
        if not isinstance(name, str) or not _DNS_NAME_RE.match(name):
            problems.append(f"{where}: internal name must be a lowercase dotted "
                            f"hostname, got {name!r}")
        elif internal_root and not name.endswith("." + internal_root):
            problems.append(f"{where}: internal name ‘{name}’ is not under the "
                            f"internal root name {internal_root}")
    pub = ways.get("public")
    if pub is not None:
        if not isinstance(pub, dict):
            problems.append(f"{where}: public must be an object")
        else:
            for k in pub:
                if k not in ("provider", "inputs", "token_file"):
                    problems.append(f"{where}: unknown public field ‘{k}’")
            prov = pub.get("provider", "")
            if not isinstance(prov, str) or (prov and not _PROVIDER_RE.match(prov)):
                problems.append(f"{where}: provider must be a short lowercase slug, "
                                f"got {prov!r}")
            inputs = pub.get("inputs", {})
            if not isinstance(inputs, dict) or not all(
                    isinstance(a, str) and isinstance(b, str) for a, b in inputs.items()):
                problems.append(f"{where}: public inputs must be text -> text")
            tf = pub.get("token_file", "")
            if not isinstance(tf, str):
                problems.append(f"{where}: token_file must be a path (a pointer, never "
                                "the token)")
    return problems


def set_ways(record: BrandRecord, bid: str, *, internal_name: str | None = None,
             tor: bool | None = None, public: dict[str, Any] | None = None) -> list[str]:
    """THE ONE WRITER of how a brand is reached (D10): the Go-Live wizard and the
    mesh page's Tor switch both call this. Writes ``internal_name`` and ``public`` into
    the row's ``ways`` and the Tor choice into the row's ``tor`` field (the field the
    manifest, the Docker mesh and the builders read), or into the superbrand block
    when ``bid`` is the superbrand's id. Returns the problems ([] = written); nothing
    is written when there is one."""
    sb = record.superbrand
    is_sb = (bid or "").strip() == sb.id.strip()
    row = None if is_sb else record.brand(bid)
    if not is_sb and row is None:
        return [f"no brand with id ‘{bid}’ in this record"]
    ways = dict(sb.ways if is_sb else (row.ways or {}))
    if internal_name is not None:
        ways["internal_name"] = internal_name.strip()
    if public is not None:
        ways["public"] = dict(public)
    if is_sb and tor is not None:
        ways["tor"] = bool(tor)
    problems = ways_problems(ways, f"brand {bid}",
                             internal_root=sb.effective_internal_root(), superbrand=is_sb)
    problems += secret_problems(ways, f"brand {bid}.ways")
    if problems:
        return problems
    if is_sb:
        sb.ways = ways
    else:
        row.ways = ways
        if tor is not None:
            row.tor = bool(tor)
    return []


def way_effects(record: BrandRecord, row=None) -> list[tuple[str, str, str, str]]:
    """``(way label, value, path label, effect)`` for every way of a brand on every
    start path, in the screens' order; the words are plain_words'."""
    sb = record.superbrand
    if row is None:
        ways = sb.ways or {}
        internal = str(ways.get("internal_name") or sb.effective_internal_root())
        tor_on = bool(ways.get("tor", False))
    else:
        ways = row.ways or {}
        internal = str(ways.get("internal_name") or default_internal_name(record, row))
        tor_on = bool(getattr(row, "tor", False))
    pub = ways.get("public") or {}
    prov = str(pub.get("provider") or "")
    values = {
        "internal_name": internal,
        "tor": "yes" if tor_on else "no",
        "public": (f"through {prov}" if prov else "none"),
    }
    out: list[tuple[str, str, str, str]] = []
    for way, way_label in plain_words.WAYS:
        for path, path_label in plain_words.PATHS:
            out.append((way_label, values[way], path_label,
                        plain_words.WAY_EFFECT[(way, path)]))
    return out


# ── the secret scan (D5) ─────────────────────────────────────────────────────────────
_PEM = re.compile(r"-----BEGIN [A-Z0-9 ]+-----")
_TOR_KEY = re.compile(r"== ed25519v1-(secret|public): type0 ==|ED25519-V3:|"
                      r"HiddenServicePrivateKey|hs_ed25519_secret_key", re.I)
_TOKEN = re.compile(
    r"(?:^|[^A-Za-z0-9])("
    r"tskey-[A-Za-z0-9_-]{8,}|hskey-[A-Za-z0-9_-]{8,}|"
    r"ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|gh[ours]_[A-Za-z0-9]{20,}|"
    r"glpat-[A-Za-z0-9_-]{15,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|"
    r"sk-[A-Za-z0-9_-]{20,}|hvs\.[A-Za-z0-9_-]{20,}|hvb\.[A-Za-z0-9_-]{20,}|"
    r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"
    r")")
#: A long opaque string (≥40 chars of letters, digits and base64 punctuation, holding
#: both letters and digits) is a token shape too — except a Tor address, a URL or a path.
_OPAQUE = re.compile(r"^[A-Za-z0-9+/_=-]{40,}$")
#: A KEY that says it holds a secret refuses any value at all; ``*_file`` keys are
#: POINTERS (the record stores where a token lives, never the token).
_SECRET_KEY = re.compile(r"(token|secret|passw|passphrase|private[_-]?key|authkey|"
                         r"api[_-]?key)", re.I)


def _looks_like_secret(value: str) -> str:
    v = value.strip()
    if _PEM.search(v):
        return "a PEM block"
    if _TOR_KEY.search(v):
        return "a Tor key line"
    m = _TOKEN.search(v)
    if m:
        return f"a token-shaped value ({m.group(1)[:6]}…)"
    if (_OPAQUE.match(v) and re.search(r"[A-Za-z]", v) and re.search(r"[0-9]", v)
            and not v.endswith(".onion") and "://" not in v and not v.startswith("/")):
        return "a long opaque value (token-shaped)"
    return ""


def secret_problems(obj: Any, where: str = "record") -> list[str]:
    """Every secret-shaped value under ``obj``, as 'path: what it looks like'. Walks
    dicts and lists; a dataclass row is walked through asdict."""
    problems: list[str] = []

    def walk(o: Any, path: str) -> None:
        if hasattr(o, "__dataclass_fields__"):
            o = asdict(o)
        if isinstance(o, dict):
            for k, v in o.items():
                p = f"{path}.{k}"
                if (isinstance(v, str) and v.strip() and _SECRET_KEY.search(str(k))
                        and not str(k).endswith("_file")):
                    problems.append(f"{p}: a value under a key that names a secret")
                    continue
                walk(v, p)
        elif isinstance(o, (list, tuple)):
            for i, v in enumerate(o):
                walk(v, f"{path}[{i}]")
        elif isinstance(o, str):
            why = _looks_like_secret(o)
            if why:
                problems.append(f"{path}: {why}")

    walk(obj, where)
    return problems


# ── whole-record checks (D4, D5, D20) ────────────────────────────────────────────────
def record_problems(record: BrandRecord, *, unaffiliated: bool = False,
                    profiles=()) -> list[str]:
    """Why the record cannot be saved ([] when it can): the id rule for the superbrand
    and every brand, duplicate ids, every look and ways block, and — on an
    unaffiliated image (D20) — any identity (a brand IS an affiliation; the look is
    allowed)."""
    sb = record.superbrand
    problems: list[str] = []
    sid = sb.id.strip()
    if sid:
        p = brand_id_problem(sid, profiles=())
        if p and not p.startswith(f"‘{sid}’ names an existing"):
            problems.append(f"superbrand: {p}")
    else:
        problems.append("superbrand: a superbrand needs an id")
    if sb.title:
        try:
            validate_brand_title(sb.title)
        except IdentityValidationError as e:
            problems.append(f"superbrand: {e}")
    problems += look_problems(sb.look, "superbrand")
    problems += ways_problems(sb.ways, "superbrand",
                              internal_root=sb.effective_internal_root(), superbrand=True)
    seen: list[str] = []
    for d in record.brands:
        bid = brand_id(d)
        p = brand_id_problem(bid, superbrand_id=sid, taken=seen, profiles=profiles)
        if p:
            problems.append(f"brand {d.name or bid}: {p}")
        elif (d.id or "").strip() and bid != default_brand_id(d.name):
            problems.append(f"brand {d.name}: {stored_id_problem(d)}")
        seen.append(bid)
        if d.title:
            try:
                validate_brand_title(d.title)
            except IdentityValidationError as e:
                problems.append(f"brand {bid}: {e}")
        problems += look_problems(d.look or {}, f"brand {bid}")
        problems += ways_problems(d.ways or {}, f"brand {bid}",
                                  internal_root=sb.effective_internal_root())
        if d.idp == DOMAIN_IDP_SUPERDOMAIN and d.issuer_port:
            problems.append(f"brand {bid}: signs in through the superbrand and has no "
                            "sign-in of its own, so it takes no sign-in port")
    if unaffiliated:
        # The record writer is the fourth enforcement site of the unaffiliated rule
        # (D20): identity refused, look allowed.
        if sb.title or sb.org or (sid and sid != "hugmesh") or record.brands:
            problems.append("an unaffiliated image carries no brand identity: no "
                            "superbrand title, organisation or id and no brands (its "
                            "look is allowed)")
    return problems


# ── issuer ports for own-sign-in brands (D4) ─────────────────────────────────────────
def issuer_ports(record: BrandRecord, *, brand_b: bool = False) -> dict[str, int]:
    """public name -> published Casdoor port for every brand with its own sign-in: the
    STORED port when the record has one, else allocated from the sequence (from 8002
    while the test-only BRAND_B knob holds 8001). Writing the result back into the rows
    (``store_issuer_ports``) is what freezes them."""
    own = [d for d in record.brands if d.idp == DOMAIN_IDP_OWN and (d.name or "").strip()]
    names = [d.name.strip() for d in own]
    stored = {d.name.strip(): int(d.issuer_port or 0) for d in own}
    return own_casdoor.ports_for(names, stored, brand_b=brand_b)


def store_issuer_ports(record: BrandRecord, *, brand_b: bool = False) -> dict[str, int]:
    ports = issuer_ports(record, brand_b=brand_b)
    for d in record.brands:
        if d.idp == DOMAIN_IDP_OWN and (d.name or "").strip() in ports:
            d.issuer_port = ports[d.name.strip()]
    return ports


# ── the projections ──────────────────────────────────────────────────────────────────
def manifest_from_record(record: BrandRecord) -> dict[str, Any]:
    """The mesh manifest header and rows as a projection of the record (D5): the same
    two functions both emitters use. ``users`` and ``images`` belong to the worklist
    and are not the record's to say."""
    sb = record.superbrand
    return {
        **brand_header_fields(sb.id, sb.title, sb.org, sb.public_name,
                              sb.effective_internal_root(), sb.login_style,
                              sb.login_decor),
        "domains": manifest_domain_rows(record.brands),
    }


def record_from_image_config(cfg: ImageConfig) -> BrandRecord:
    """The record an image configuration describes: its brand plane as the superbrand
    block (D5) and its Domain rows as the brands."""
    sb = Superbrand(id=cfg.brand, title=cfg.brand_title, org=cfg.org,
                    public_name=cfg.cluster_domain, internal_root=cfg.superdomain,
                    look=_look_from_image_config(cfg))
    rows = [ImageConfig._domain_from_dict(r) for r in domain_rows_to_dict(cfg.domains)]
    return BrandRecord(superbrand=sb, brands=rows)


def _look_from_image_config(cfg: ImageConfig) -> dict[str, str]:
    pairs = (("primary", cfg.login_primary_color), ("secondary", cfg.login_secondary_color),
             ("preset", cfg.login_theme_preset),
             ("mode", cfg.login_theme_mode if cfg.login_theme_preset else ""),
             ("font", cfg.login_font), ("style", cfg.login_style),
             ("decor", cfg.login_decor),
             ("bg_effect", "" if cfg.login_bg_effect == "gradient" else cfg.login_bg_effect))
    return {k: v for k, v in pairs if v}


def apply_record_to_image_config(record: BrandRecord, cfg: ImageConfig) -> None:
    """Write the record onto an image configuration, in place: the superbrand block
    onto the brand plane, the brands onto the Domain rows (replaced, never merged)."""
    sb = record.superbrand
    if sb.id:
        cfg.brand = sb.id
    if sb.title:
        cfg.brand_title = sb.title
    if sb.org:
        cfg.org = sb.org
    if sb.public_name:
        cfg.cluster_domain = sb.public_name
    cfg.superdomain = sb.internal_root
    # the look is the one place style and decoration live (Superbrand.login_style
    # reads it); an empty look value says nothing and leaves the field alone
    cfg.login_style = sb.login_style
    cfg.login_decor = sb.login_decor
    look = {k: v for k, v in (sb.look or {}).items() if v}
    if "primary" in look:
        cfg.login_primary_color = look["primary"]
    if "secondary" in look:
        cfg.login_secondary_color = look["secondary"]
    if "preset" in look:
        cfg.login_theme_preset = look["preset"]
    if "mode" in look:
        cfg.login_theme_mode = look["mode"]
    if "font" in look:
        cfg.login_font = look["font"]
    if "bg_effect" in look:
        cfg.login_bg_effect = look["bg_effect"]
    cfg.domains = [ImageConfig._domain_from_dict(r) for r in domain_rows_to_dict(record.brands)]
    cfg.additional_domains = bool(cfg.domains)


def record_from_bootstrap(cfg) -> BrandRecord:
    """The record a local Docker mesh's bootstrap config carries: ``brand`` and the
    resolved domain are the superbrand's id and public name, the ``superbrand`` block
    holds the rest, and the recorded domain rows are the brands (the mesh's own row,
    when recorded, is the superbrand and is not listed twice)."""
    block = dict(getattr(cfg, "superbrand", None) or {})
    own = (cfg.cluster_domain or "").strip() or cfg.resolved_domain()
    sb = Superbrand.from_dict({**block, "id": cfg.brand, "public_name": own})
    if not sb.central_signin:
        sb.central_signin = cfg.issuer()
    own_idp = {n.strip() for n in (getattr(cfg, "own_idp_domains", None) or ())}
    rows: list[Domain] = []
    for rec in (getattr(cfg, "domains", None) or ()):
        name = (rec.get("name") or "").strip()
        if not name or name == own:
            continue
        row = ImageConfig._domain_from_dict(dict(rec))
        # the tenant the stack REGISTERS is what own_idp_domains says (the compose
        # lane consumes that list), whatever the recorded row's idp says
        if name in own_idp:
            row.idp = DOMAIN_IDP_OWN
        rows.append(row)
    for name in sorted(own_idp):
        if name != own and not any(r.name == name for r in rows):
            rows.append(Domain(name=name, idp=DOMAIN_IDP_OWN))
    tor_on = bool(cfg.effective_with_tor())
    if "tor" not in (sb.ways or {}):
        sb.ways = {**sb.ways, "tor": tor_on}
    return BrandRecord(superbrand=sb, brands=rows)


def apply_record_to_bootstrap(record: BrandRecord, cfg) -> None:
    """Write the record onto a bootstrap config, in place (``up --record``): the
    superbrand's id and public name onto ``brand``/``cluster_domain``, the block onto
    ``superbrand``, the brands onto ``domains`` and ``own_idp_domains``, and the
    superbrand's Tor way (``ways.tor``, set_ways' one field) onto ``with_tor``, so the
    mesh show-record describes is the mesh that starts. A flag that says the opposite
    (``--with-tor`` or a ``--services`` selection) is a contradiction, not an
    override: ValueError, and nothing is applied. Everything that is not the record's
    to say (env, source, the auth key) is left as the caller set it."""
    sb = record.superbrand
    if "tor" in (sb.ways or {}):
        want = bool(sb.ways["tor"])
        if cfg.services is not None and cfg.effective_with_tor() != want:
            raise ValueError(
                f"the brand record says this mesh has {'a' if want else 'no'} Tor "
                f"address, but --services {'leaves out' if want else 'names'} tor: "
                "change the record's way (set_ways) or the selection, not both")
        if cfg.services is None and cfg.with_tor and not want:
            raise ValueError("the brand record says this mesh has no Tor address, but "
                             "--with-tor was given: change the record's way (set_ways) "
                             "or drop the flag")
        if cfg.services is None:
            cfg.with_tor = want
    if sb.id:
        cfg.brand = sb.id
    if sb.public_name:
        cfg.cluster_domain = sb.public_name
    block = sb.to_dict()
    block.pop("id", None)
    block.pop("public_name", None)
    cfg.superbrand = block
    rows = domain_rows_to_dict(record.brands)
    for r in rows:
        if not r.get("images"):
            r.pop("images", None)
    cfg.domains = tuple(rows)
    cfg.own_idp_domains = tuple(d.name.strip() for d in record.brands
                                if d.idp == DOMAIN_IDP_OWN and (d.name or "").strip())


# ── show-record (D2, D5, D10) ────────────────────────────────────────────────────────
def show_record_lines(record: BrandRecord, *, env: str = "test") -> list[str]:
    """What ``show-record`` prints: every brand's effective look with the source of
    each value, the effect of each way to reach it on each path, and what the one
    superbrand block drives on the Docker, kind and builder paths. The words are the
    model document's (plain_words)."""
    sb = record.superbrand
    root = sb.effective_internal_root()
    lines: list[str] = []
    lines.append(f"Brand record (schema {record.schema})")
    lines.append(f"{plain_words.term('superbrand')}: {sb.id or '(no id)'}"
                 + (f" — {sb.title}" if sb.title else ""))
    lines.append(f"  public name:        {sb.public_name or '(none)'}")
    lines.append(f"  {plain_words.term('internal_root')}: {root}")
    lines.append(f"  central sign-in:    {sb.central_signin or '(derived by the start path)'}")
    if sb.org:
        lines.append(f"  organisation:       {sb.org}")
    if record.copied_from:
        lines.append(f"  design: copied from design {record.copied_from.get('design', '?')}"
                     f" on {record.copied_from.get('date', '?')} (the record never refers "
                     "back to the store)")
    lines.append("  look (the default every brand starts from):")
    for k, (v, src) in effective_look(record).items():
        lines.append(f"    {k:<10} {v or '(shipped page)':<24} — {src}")
    lines.append("  ways to reach it:")
    _append_ways(lines, way_effects(record))
    own_names = [d.name.strip() for d in record.brands
                 if d.idp == DOMAIN_IDP_OWN and (d.name or "").strip()]
    for d in record.brands:
        bid = brand_id(d)
        lines.append("")
        lines.append(f"{plain_words.term('brand')} {bid}: {d.name}"
                     + (f" — {d.title}" if d.title else ""))
        lines.append(f"  {plain_words.term('sign_in')}: "
                     f"{plain_words.SIGN_IN.get(d.idp, d.idp)}"
                     + (f"; {sign_in_port_sentence(d, own_names)}"
                        if d.idp == DOMAIN_IDP_OWN else ""))
        lines.append("  look:")
        for k, (v, src) in effective_look(record, d).items():
            lines.append(f"    {k:<10} {v or '(shipped page)':<24} — {src}")
        lines.append("  ways to reach it:")
        _append_ways(lines, way_effects(record, d))
    lines.append("")
    lines.append("What the one superbrand block drives:")
    lines.append(f"  Docker mesh plan:  Brand: {sb.id}  Domain: {sb.public_name or '(brand default)'}"
                 f"  (ENV={env})")
    tor_rows = tor_domain_entries(record.brands, own_name=sb.public_name)
    lines.append(f"  kind cluster:      brand {sb.id}; Tor per brand: "
                 + (", ".join(f"{n} (key ‘{s}’, served as {t})" for n, s, t in tor_rows)
                    or "none"))
    prof = {k: v for k, v in _profile_values(record).items()
            if k in ("BRAND", "BRAND_TITLE", "SUPERDOMAIN")}
    lines.append("  builder profile:   " + " ".join(f"{k}='{v}'" for k, v in prof.items()))
    return lines


def sign_in_port_sentence(row, own_names) -> str:
    """The sign-in port line of one own-sign-in brand: the port the record stores AND
    the port the Docker mesh publishes today. The stack node (core/local_stack_node.py)
    still allocates by table position (own_casdoor.port_for), so when the two differ
    the sentence says both; a printout that called the stored port effective would be
    wrong about the running mesh."""
    name = (getattr(row, "name", "") or "").strip()
    stored = int(getattr(row, "issuer_port", 0) or 0)
    docker = own_casdoor.port_for(own_names.index(name)) if name in own_names else 0
    if not stored:
        return (f"sign-in port {docker} on the Docker mesh (by table position; "
                "none recorded)")
    if stored == docker:
        return f"sign-in port {stored} (recorded; the Docker mesh publishes it there too)"
    return (f"sign-in port {stored} recorded — the Docker mesh still publishes it at "
            f"{docker} (by table position) until the mesh reads the record")


def _append_ways(lines: list[str], effects) -> None:
    last = None
    for way_label, value, path_label, effect in effects:
        if way_label != last:
            lines.append(f"    {way_label}: {value}")
            last = way_label
        lines.append(f"      {path_label:<12} {effect}")


# ── the generated builder profile (D5) ───────────────────────────────────────────────
#: The one character set a profile value may hold: letters, digits, space and a few
#: punctuation marks that mean nothing to a shell inside single quotes AND nothing to
#: sed (= carries the slug=tenant pairs of TOR_BRANDS). Everything else — quotes, $, backticks, backslash, braces, ;|&<>*?!# — is
#: refused, so a title like $(touch x) never reaches a file a builder sources.
PROFILE_SAFE_RE = re.compile(r"^[A-Za-z0-9 ._:/@+,=-]*$")
#: A profile line as the strict re-parser accepts it: KEY='safe value'. Nothing else.
PROFILE_LINE_RE = re.compile(r"^([A-Z][A-Z0-9_]*)='([A-Za-z0-9 ._:/@+,=-]*)'$")
PROFILE_HEADER = "# GENERATED by HugMesh Studio from the brand record (core/brand_model.py)."


class ProfileRefused(ValueError):
    def __init__(self, problems: list[str]):
        super().__init__("; ".join(problems))
        self.problems = list(problems)


def _profile_values(record: BrandRecord) -> dict[str, str]:
    sb = record.superbrand
    tor_rows = tor_domain_entries(record.brands, own_name=sb.public_name)
    return {
        "BRAND": sb.id,
        "BRAND_TITLE": sb.title,
        "ORG": sb.org,
        "CLUSTER_DOMAIN": sb.public_name,
        "SUPERDOMAIN": sb.effective_internal_root(),
        "BRAND_RECORD_SCHEMA": str(record.schema),
        "BRANDS": " ".join(record.ids()),
        "TOR_BRANDS": " ".join(f"{s}={t}" for _n, s, t in tor_rows),
    }


def builder_profile(record: BrandRecord) -> str:
    """The shell profile the image builders source, generated from the record: every
    value single-quoted and limited to PROFILE_SAFE_RE, or :class:`ProfileRefused`
    naming each value that is not (and then NO file is written by any caller).
    Round-trips through :func:`parse_builder_profile` by construction."""
    problems: list[str] = []
    vals = _profile_values(record)
    for k, v in vals.items():
        if not PROFILE_SAFE_RE.match(v):
            problems.append(f"{k}: ‘{v}’ holds a character a generated profile may not "
                            "carry (letters, digits, space and . _ : / @ + , = - only)")
    if problems:
        raise ProfileRefused(problems)
    lines = [PROFILE_HEADER,
             "# Values are single-quoted and limited to a safe character set; the Studio",
             "# re-parses this file strictly (parse_builder_profile) before any builder",
             "# sources it. Edit the brand record, not this file."]
    lines += [f"{k}='{v}'" for k, v in vals.items()]
    return "\n".join(lines) + "\n"


def parse_builder_profile(text: str) -> dict[str, str]:
    """Read a generated profile STRICTLY: comments and blank lines, else exactly
    KEY='safe value'. Anything else — a command substitution, an unquoted value, a
    second statement on the line, a function — raises ValueError naming the line."""
    out: dict[str, str] = {}
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = PROFILE_LINE_RE.match(line)
        if not m:
            raise ValueError(f"line {n} is not KEY='safe value': {raw!r}")
        if m.group(1) in out:
            raise ValueError(f"line {n} repeats {m.group(1)}")
        out[m.group(1)] = m.group(2)
    return out


# ── the branding folder (--branding-dir) ─────────────────────────────────────────────
_BRAND_CONF_FORBIDDEN = re.compile(r"""["'\\\r\n]|[\x00-\x1f\x7f]""")


def write_branding_dir(record: BrandRecord, folder: str) -> str:
    """Write ``<folder>/brand.conf`` in the strict KEY="VALUE" form the desktop applier
    (specs/usr/sbin/hugmesh-branding) reads without sourcing: BRAND_NAME, BRAND_TITLE
    and, when the look sets one, ACCENT_COLOR. The applier strips one layer of quotes
    and cannot unescape, so a value with a quote, a backslash or a control character is
    REFUSED here (the _brand_conf_kv rule) rather than escaped. Returns the path."""
    sb = record.superbrand
    pairs = [("BRAND_NAME", sb.id), ("BRAND_TITLE", sb.title)]
    accent = (sb.look or {}).get("primary", "")
    if accent:
        pairs.append(("ACCENT_COLOR", accent))
    problems = [f"{k}: a brand.conf value may not hold a quote, a backslash or a "
                f"control character ({v!r})" for k, v in pairs
                if _BRAND_CONF_FORBIDDEN.search(v)]
    if problems:
        raise RecordRefused(problems)
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, "brand.conf")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("# GENERATED by HugMesh Studio from the brand record; strict KEY=VALUE, "
                 "never sourced.\n")
        for k, v in pairs:
            fh.write(f'{k}="{v}"\n')
    return path


# ── the record file ──────────────────────────────────────────────────────────────────
def record_path() -> str:
    return os.path.join(state_dir(), RECORD_FILENAME)


def _dump(d: dict[str, Any]) -> str:
    """One byte shape for the file: sorted keys, two-space indent, trailing newline,
    no clock value — so two faces given the same inputs write the same bytes."""
    return json.dumps(d, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def save_record(record: BrandRecord, path: str | None = None, *,
                unaffiliated: bool = False, profiles=()) -> str:
    """Check (:func:`record_problems`, :func:`secret_problems`) and write the record,
    or raise :class:`RecordRefused` and write NOTHING. Returns the path."""
    problems = record_problems(record, unaffiliated=unaffiliated, profiles=profiles)
    problems += secret_problems(record.to_dict(), "record")
    if problems:
        raise RecordRefused(problems)
    path = path or record_path()
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(_dump(record.to_dict()))
    os.replace(tmp, path)
    return path


def load_record(path: str | None = None) -> BrandRecord:
    with open(path or record_path(), encoding="utf-8") as fh:
        return BrandRecord.from_dict(json.load(fh))


# ── the superbrand store (D5) ────────────────────────────────────────────────────────
_DESIGN_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")


def designs_dir() -> str:
    return os.path.join(state_dir(), DESIGNS_SUBDIR)


def _design_path(name: str) -> str:
    if not _DESIGN_NAME_RE.match(name or ""):
        raise ValueError(f"a design name is a short lowercase slug, got {name!r}")
    return os.path.join(designs_dir(), f"{name}.json")


def save_design(name: str, superbrand: Superbrand) -> str:
    """Keep a superbrand design in the store (scanned for secrets first)."""
    problems = look_problems(superbrand.look, f"design {name}")
    problems += secret_problems(superbrand.to_dict(), f"design {name}")
    if problems:
        raise RecordRefused(problems)
    path = _design_path(name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(_dump(superbrand.to_dict()))
    return path


def load_design(name: str) -> Superbrand:
    with open(_design_path(name), encoding="utf-8") as fh:
        return Superbrand.from_dict(json.load(fh))


def list_designs() -> list[str]:
    try:
        return sorted(f[:-5] for f in os.listdir(designs_dir()) if f.endswith(".json"))
    except OSError:
        return []


def choose_design(record: BrandRecord, name: str, date: str) -> None:
    """COPY a stored design into the record (D5): the record then holds its own copy
    and notes where it came from; editing the stored design later changes no existing
    mesh. ``date`` (YYYY-MM-DD) is the caller's input, never read from a clock here."""
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", date or ""):
        raise ValueError(f"the copy date must be YYYY-MM-DD, got {date!r}")
    design = load_design(name)
    record.superbrand = Superbrand.from_dict(design.to_dict())   # a copy, by value
    record.copied_from = {"design": name, "date": date}


# ── a small Qt-free command line (the e2e scenarios drive it in a fresh process) ─────
def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="hugmesh-brand-record",
        description="Read a brand record: show it in the model's words, validate it, "
                    "or write the generated builder profile from it.")
    p.add_argument("verb", choices=("show", "validate", "profile", "manifest"))
    p.add_argument("--record", required=True, help="the brand-record.json to read")
    p.add_argument("--out", default="", help="profile: where to write it (default: stdout)")
    p.add_argument("--env", default="test", choices=("test", "prod"))
    p.add_argument("--generator-dir", default="",
                   help="a hugmesh-generator checkout: validate refuses a brand id that "
                        "names one of its brands/*.conf profiles (as `up` does)")
    args = p.parse_args(argv)
    try:
        rec = load_record(args.record)
    except (OSError, ValueError) as e:
        print(f"[refused] cannot read {args.record}: {e}", file=sys.stderr)
        return 2
    if args.verb == "show":
        for line in show_record_lines(rec, env=args.env):
            print(line)
        return 0
    if args.verb == "manifest":
        print(_dump(manifest_from_record(rec)), end="")
        return 0
    profiles = profile_names(args.generator_dir) if args.generator_dir else ()
    problems = (record_problems(rec, profiles=profiles)
                + secret_problems(rec.to_dict(), "record"))
    if args.verb == "validate":
        for pr in problems:
            print(f"  - {pr}")
        print("ok" if not problems else f"{len(problems)} problem(s)")
        return 0 if not problems else 1
    # profile: refused values write NO file
    try:
        text = builder_profile(rec)
    except ProfileRefused as e:
        for pr in e.problems:
            print(f"[refused] {pr}", file=sys.stderr)
        print("[refused] no profile written", file=sys.stderr)
        return 1
    parse_builder_profile(text)            # the strict re-read, before any write
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text)
        print(f"wrote {args.out}")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

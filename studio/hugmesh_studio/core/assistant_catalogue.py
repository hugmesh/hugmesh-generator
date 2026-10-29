"""The catalogue of every setting the Studio offers, generated FROM THE CODE (Qt-free).

Hand-typed prose about options rots: a field added to ``config.Domain`` or a preset
added to ``theme_presets.PRESETS`` would be invisible to the assistant for ever. So the
catalogue is built at import time from the dataclasses and the ``*_CHOICES`` tables the
pages themselves read:

* DOMAIN scope: ``config.Domain.__dataclass_fields__`` (``DOMAIN_FIELDS``), with
  ``optional_services`` offered as ``services`` (choices OPTIONAL_SERVICES_CHOICES,
  described by domain_services.describe), ``idp`` as ``signin`` (superdomain | own, plus
  the provider/issuer/client_id/jwks of ``idp_settings``), ``look`` expanded to one
  ``look.<key>`` per brand_model.LOOK_KEYS (choices from theme_presets / theme /
  fonts, colours checked by brand_look.check_value), ``ways`` expanded to ``tailnet``
  and ``egress`` (core/domain_reach), ``tor`` and ``github_org``.
* MESH scope: ``local_mesh_bootstrap.LocalMeshBootstrapConfig`` fields; secrets and
  bulky values (auth_key, egress_vpn_conf, login_theme_css, login_look) flagged and
  never rendered.
* IMAGE scope: ``config.ImageConfig`` fields, with choices parsed once from the
  ``# a | b | c`` comments in config.py's own source and the ``<FIELD>_CHOICES``
  constants, ``SECRET_FIELDS`` marked secret, and the page each field is edited on read
  from ``assistant_catalogue_pages.json`` beside this module (written by
  ``scripts/local-ai/catalogue-pages.py`` from ``grep cfg.<field>`` over gui/pages; a
  test regenerates and compares it).

``setter`` names the apply route in core/assistant_actions ("" = the assistant can
describe the option but not change it). ``options_for(where)`` is the slice for the
page the person is on; ``render_options`` prints it with the current values a reader
supplies; ``catalogue_text(scope)`` is the full dump for the ``catalogue`` command.
"""
from __future__ import annotations

import inspect
import json
import os
import re
from dataclasses import dataclass, fields as dc_fields
from typing import Any, Callable, Iterable, Optional

from . import config
from .assistant_context import NEVER_SHOWN, SECRET_FIELD_NAMES, SECRET_KEY_RE, tokens

__all__ = ["Option", "SCOPES", "catalogue", "options_for", "render_options", "catalogue_text",
           "find", "PAGES_FILE", "load_pages", "compute_pages", "DOMAIN_KEY_MAP",
           "choices_for", "look_choices", "mesh_service_choices", "DOMAIN_PAGES",
           "MESH_PAGES", "IMAGE_PAGES_DEFAULT", "LOCALMESH_FIELD_PAGES"]

SCOPES = ("domain", "mesh", "image")
PAGES_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          "assistant_catalogue_pages.json")
DOMAIN_PAGES = ("domain_services", "localmesh_domain_services")
MESH_PAGES = ("localmesh_env", "localmesh_domains", "localmesh_domain_services",
              "localmesh_source", "localmesh_services", "localmesh_idp", "localmesh_overlay",
              "localmesh_review", "localmesh")

#: Domain dataclass field -> the catalogue key the person sees.
DOMAIN_KEY_MAP = {"optional_services": "services", "idp": "signin"}

#: Which local-mesh step edits which bootstrap field (the steps are one page module;
#: the json generator cannot tell them apart, so this table is the map).
LOCALMESH_FIELD_PAGES: dict = {
    "env": ("localmesh_env",), "superadmin_username": ("localmesh_env",),
    "brand": ("localmesh_env",), "cluster_domain": ("localmesh_env",),
    "login_server": ("localmesh_env",), "node_name": ("localmesh_env",),
    "auth_key": ("localmesh_env",), "superbrand": ("localmesh_env",),
    "domains": ("localmesh_domains",), "own_idp_domains": ("localmesh_domains",),
    "domain_services_reviewed": ("localmesh_domain_services",),
    "source_mode": ("localmesh_source",), "source_dir": ("localmesh_source",),
    "social": ("localmesh_services",), "with_tor": ("localmesh_services",),
    "services": ("localmesh_services",), "egress_vpn_conf": ("localmesh_services",),
    "web_locales": ("localmesh_services",), "tor_release": ("localmesh_services",),
    "idp": ("localmesh_idp",), "idp_issuer": ("localmesh_idp",),
    "idp_client_id": ("localmesh_idp",), "idp_jwks": ("localmesh_idp",),
    "kind_addons": ("localmesh_overlay",), "out_dir": ("localmesh",),
    "login_theme_css": ("localmesh_domain_services",), "login_look": ("localmesh_domain_services",),
}
IMAGE_PAGES_DEFAULT = ("review",)


@dataclass(frozen=True)
class Option:
    scope: str
    key: str
    label: str
    kind: str                      # enum | bool | text | colour | path | list | int
    choices: tuple = ()
    default: Any = ""
    doc: str = ""
    page: tuple = ()
    secret: bool = False
    applies: str = ""
    setter: str = ""
    source: str = ""               # the dataclass field this option came from

    def choices_text(self) -> str:
        if self.kind == "bool":
            return "on | off"
        if self.kind == "colour":
            return "#RRGGBB"
        if self.choices:
            return " | ".join(str(c) for c in self.choices)
        return {"text": "text", "path": "a path on this machine", "list": "a list",
                "int": "a number"}.get(self.kind, self.kind)


# ── choices from the code ────────────────────────────────────────────────────────────
def look_choices() -> dict:
    from . import brand_look, fonts, theme, theme_presets
    presets = tuple(p.preset_id for p in theme_presets.PRESETS)
    effects = tuple(theme.BG_EFFECTS)
    vanta = tuple(getattr(theme, "VANTA_EFFECTS", ()))
    return {
        "preset": presets, "mode": tuple(theme_presets.MODES),
        "style": tuple(theme.STYLE_VARIANTS), "decor": tuple(theme.DECOR_VARIANTS),
        "bg_effect": tuple(e + (" (not selectable yet)" if e in vanta else "") for e in effects),
        "font": tuple(fonts.FONT_PRESETS),
        "_defaults": dict(brand_look.LOOK_DEFAULTS),
    }


def mesh_service_choices() -> tuple:
    from . import local_services
    per_domain = set(local_services.domain_local_slugs()) | set(config.OPTIONAL_SERVICES_CHOICES)
    out = []
    for _title, slugs in local_services.local_groups():
        out += [s for s in slugs if s not in per_domain and s not in out]
    return tuple(out)


_INLINE_RE = re.compile(r"^\s*(?P<name>[a-z_][a-z0-9_]*)\s*:\s*[^=]+=\s*[^#]*#\s*(?P<comment>.*)$")
_PIPE_RE = re.compile(r"(?:^|[\s(:])([A-Za-z0-9_\-]+(?:\s*\|\s*[A-Za-z0-9_\-]+)+)")


def _image_comments() -> dict:
    """field -> (comment, choices parsed from ``a | b | c``)."""
    try:
        src = inspect.getsource(config.ImageConfig)
    except (OSError, TypeError):
        return {}
    out = {}
    for line in src.splitlines():
        m = _INLINE_RE.match(line)
        if not m:
            continue
        comment = m.group("comment").strip()
        choices: tuple = ()
        pm = _PIPE_RE.search(comment)
        if pm:
            cand = tuple(c.strip().strip("'\"") for c in pm.group(1).split("|"))
            # prose ("shipped | a") and constant names ("FRITE_BOARDS | jetson") are not
            # choices: every item must be a plain lowercase token of two or more letters
            if all(re.fullmatch(r"[a-z0-9][a-z0-9_\-]+", c) for c in cand) and len(cand) >= 2:
                choices = cand
        out[m.group("name")] = (comment, choices)
    return out


def choices_for(field_name: str) -> tuple:
    """``<FIELD>_CHOICES`` in config when there is one."""
    const = getattr(config, f"{field_name.upper()}_CHOICES", None)
    if isinstance(const, (tuple, list)):
        return tuple(str(c) for c in const)
    if isinstance(const, dict):
        vals = list(const.values())
        if vals and all(isinstance(v, (tuple, list)) for v in vals):
            out: list = []
            for v in vals:                               # ROLE_CHOICES: mode -> roles
                for x in v:
                    # (role, platforms, label) rows name the role first
                    x = x[0] if isinstance(x, (tuple, list)) and x else x
                    if str(x) not in out:
                        out.append(str(x))
            return tuple(out)
        return tuple(str(c) for c in const)
    return ()


def _kind_of(value: Any, choices: tuple, name: str) -> str:
    if choices:
        return "enum"
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, int):
        return "int"
    if isinstance(value, (list, tuple, set, frozenset)) or value is None and name.endswith("s"):
        return "list"
    if name.endswith(("_dir", "_file", "_path", "_conf", "dir")) or "path" in name:
        return "path"
    return "text"


def _secret(name: str) -> bool:
    return name in SECRET_FIELD_NAMES or name in config.SECRET_FIELDS or bool(SECRET_KEY_RE.search(name))


# ── the three scopes ─────────────────────────────────────────────────────────────────
def _domain_options() -> "list[Option]":
    from . import domain_reach, domain_services
    look = look_choices()
    out: list = []
    svc_doc = "; ".join(f"{s}: {domain_services.describe(s).split('.')[0]}"
                        for s in config.OPTIONAL_SERVICES_CHOICES)
    for name in config.DOMAIN_FIELDS:
        f = config.Domain.__dataclass_fields__[name]
        default = f.default if f.default is not f.default_factory else ()
        if name == "optional_services":
            out.append(Option("domain", "services", "services this domain runs", "list",
                              tuple(config.OPTIONAL_SERVICES_CHOICES), (), svc_doc, DOMAIN_PAGES,
                              setter="services", source=name))
        elif name == "idp":
            out.append(Option("domain", "signin", "how people sign in", "enum",
                              tuple(config.DOMAIN_IDP_CHOICES), config.DOMAIN_IDP_SUPERDOMAIN,
                              "superdomain = through the mesh's sign-in (same people, same admins); "
                              "own = this domain's own sign-in", DOMAIN_PAGES, setter="signin",
                              source=name))
        elif name == "idp_settings":
            out.append(Option("domain", "provider", "the own sign-in's provider", "enum",
                              tuple(config.IDP_CHOICES), "casdoor",
                              "; ".join(f"{k}: {v}" for k, v in config.IDP_LABELS.items())
                              + "; only an own sign-in has a provider", DOMAIN_PAGES,
                              setter="signin", source=name))
            out.append(Option("domain", "issuer", "the own sign-in address (https://...)", "text",
                              (), "", "only for entra, aws or oidc", DOMAIN_PAGES, setter="signin",
                              source=name))
            out.append(Option("domain", "client_id", "the own sign-in's client id", "text", (),
                              "", "only for entra, aws or oidc", DOMAIN_PAGES, setter="signin",
                              source=name))
            out.append(Option("domain", "jwks", "the own sign-in's key address (https://...)",
                              "text", (), "", "optional override for entra, aws or oidc",
                              DOMAIN_PAGES, setter="signin", source=name))
        elif name == "look":
            defaults = look["_defaults"]
            labels = {"primary": "main colour", "secondary": "second colour",
                      "preset": "colour preset", "mode": "light or dark", "font": "font style",
                      "style": "shape style", "decor": "decoration", "bg_effect": "page background effect"}
            from . import brand_model
            for key in brand_model.LOOK_KEYS:
                kind = "colour" if key in ("primary", "secondary") else ("enum" if key in look else "text")
                out.append(Option("domain", f"look.{key}", labels.get(key, key), kind,
                                  tuple(look.get(key, ())), defaults.get(key, ""),
                                  "a brand's own value; empty = inherited from the mesh's look",
                                  DOMAIN_PAGES, setter="look", source=name))
        elif name == "ways":
            out.append(Option("domain", "tailnet", "VPN (the mesh's private network)", "enum",
                              (domain_reach.REACH_INHERIT, "on", "off"), domain_reach.REACH_INHERIT,
                              "recorded per domain; the mesh's VPN joins as one machine",
                              DOMAIN_PAGES, setter="tailnet", source=name))
            out.append(Option("domain", "egress", "outbound traffic (egress)", "enum",
                              (domain_reach.REACH_INHERIT,) + tuple(domain_reach.EGRESS_MODES),
                              domain_reach.REACH_INHERIT,
                              "vpn needs a provider file picked on the page (never proposed here)",
                              DOMAIN_PAGES, setter="egress", source=name))
            out.append(Option("domain", "egress_file", "the egress VPN provider file", "path", (),
                              "", "a path to a provider file; pick it on the page", DOMAIN_PAGES,
                              secret=True, source=name))
            out.append(Option("domain", "internal_name", "internal name on the mesh's own network",
                              "text", (), "", "recorded; not served yet", ("domains",), source=name))
            out.append(Option("domain", "public", "public name through a provider", "text", (), "",
                              "set on the Go-Live wizard", ("domains",), source=name))
        elif name == "tor":
            out.append(Option("domain", "tor", "its own Tor address (front door)", "bool", (), False,
                              "an onion address of its own, ticked on the Ways to reach it tab; "
                              "needs Tor on the node or mesh", DOMAIN_PAGES, setter="tor",
                              source=name))
        elif name == "github_org":
            out.append(Option("domain", "github_org", "GitHub organisation for export", "text", (),
                              "", "an org name (letters, digits, hyphens); set on the Domains page",
                              ("domains",), source=name))
        elif name == "images":
            out.append(Option("domain", "images", "which images carry this domain", "list", (), (),
                              "empty = every eligible image", ("domains",), source=name))
        elif name == "issuer_port":
            out.append(Option("domain", "issuer_port", "the own sign-in's published port", "int",
                              (), 0, "allocated by the Studio, never typed", ("domains",), source=name))
        else:
            out.append(Option("domain", name, {"name": "domain name", "title": "title",
                                                "id": "brand id"}.get(name, name), "text", (),
                              default if isinstance(default, str) else "",
                              "set on the Domains page", ("domains",), source=name))
    return out


def _mesh_options() -> "list[Option]":
    from . import local_mesh_bootstrap as lmb, local_services
    out: list = []
    for f in dc_fields(lmb.LocalMeshBootstrapConfig):
        name = f.name
        default = f.default if f.default is not f.default_factory else ()
        choices: tuple = ()
        kind = _kind_of(default, choices, name)
        doc = ""
        setter = ""
        if name == "env":
            choices, kind, doc, setter = tuple(config.ENV_CHOICES), "enum", \
                "test = LAN-only test mesh; prod = public names and the mesh's VPN (needs an auth key)", "env"
        elif name == "source_mode":
            choices, kind, doc = ("clone", "existing"), "enum", "clone the sources, or use an existing folder"
        elif name == "services":
            choices, kind, doc, setter = mesh_service_choices(), "list", \
                "the mesh-level services (per-domain ones are on each domain's page)", "mesh_services"
        elif name == "kind_addons":
            try:
                choices = tuple(a.id for a in local_services.KIND_ADDONS)
            except Exception:                # noqa: BLE001
                choices = ()
            kind, doc = "list", "the kind lane's add-ons"
        elif name == "idp":
            choices, kind, doc = tuple(config.IDP_CHOICES), "enum", \
                "; ".join(f"{k}: {v}" for k, v in config.IDP_LABELS.items())
        elif name in ("with_tor", "social", "tor_release"):
            kind, setter = "bool", {"with_tor": "with_tor", "social": "social"}.get(name, "")
            doc = {"with_tor": "run Tor on the mesh (every domain's onion needs it)",
                   "social": "run the social (fediverse) service", "tor_release": "Tor release posture"}[name]
        elif name == "web_locales":
            kind, doc, setter = "list", "extra web login languages, e.g. de, fr, pt-BR", "web_locales"
        elif name == "superadmin_username":
            kind, doc, setter = "text", "the first superadmin account", "superadmin_username"
        elif name == "domains":
            kind, doc = "list", "the domain rows (see the domain scope)"
        elif name == "superbrand":
            kind, doc = "text", "the mesh's own brand: id, title, organisation, look"
        elif name in ("login_look",):
            kind, doc = "text", "the mesh's look (edited on the own domain's Look tab)"
        secret = _secret(name)
        if name == "login_theme_css":
            secret, doc = True, "the finished stylesheet (bulky; never shown)"
        out.append(Option("mesh", name, name.replace("_", " "), kind, choices,
                          default if isinstance(default, (str, bool, int)) else (), doc,
                          LOCALMESH_FIELD_PAGES.get(name, ("localmesh",)), secret, "", setter, name))
    return out


def _image_options(pages: Optional[dict] = None) -> "list[Option]":
    comments = _image_comments()
    pages = load_pages() if pages is None else pages
    out: list = []
    for f in dc_fields(config.ImageConfig):
        name = f.name
        default = f.default if f.default is not f.default_factory else ()
        comment, parsed = comments.get(name, ("", ()))
        choices = choices_for(name) or parsed
        if name == "idp":
            choices = tuple(config.IDP_CHOICES)
        kind = _kind_of(default, choices, name)
        if name == "domains":
            kind, choices = "list", ()
        secret = _secret(name)
        out.append(Option("image", name, name.replace("_", " "), kind, choices,
                          default if isinstance(default, (str, bool, int)) else (),
                          comment, tuple(pages.get(name, ())) or IMAGE_PAGES_DEFAULT, secret,
                          "config.field_in_scope", "", name))
    return out


_CACHE: dict = {}


def catalogue(scope: Optional[str] = None) -> "list[Option]":
    """Every option (cached per process), or one scope's."""
    if not _CACHE:
        _CACHE["domain"] = _domain_options()
        _CACHE["mesh"] = _mesh_options()
        _CACHE["image"] = _image_options()
    if scope:
        return list(_CACHE.get(scope, ()))
    return [o for s in SCOPES for o in _CACHE[s]]


def find(key: str, scope: Optional[str] = None) -> Optional[Option]:
    for o in catalogue(scope):
        if o.key == key:
            return o
    return None


# ── the page map (scripts/local-ai/catalogue-pages.py writes it) ─────────────────────
def load_pages() -> dict:
    try:
        with open(PAGES_FILE, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    return {str(k): [str(p) for p in v] for k, v in data.items()} if isinstance(data, dict) else {}


def compute_pages(pages_dir: Optional[str] = None) -> dict:
    """field -> sorted page slugs whose module reads ``cfg.<field>`` (stdlib grep)."""
    pages_dir = pages_dir or os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                          "gui", "pages")
    names = set(f.name for f in dc_fields(config.ImageConfig))
    out: dict = {n: set() for n in names}
    rx = re.compile(r"cfg\.([a-z_][a-z0-9_]*)")
    try:
        files = sorted(os.listdir(pages_dir))
    except OSError:
        return {}
    for fn in files:
        if not fn.endswith(".py") or fn.startswith("_"):
            continue
        slug = fn[:-3]
        try:
            with open(os.path.join(pages_dir, fn), encoding="utf-8") as fh:
                text = fh.read()
        except OSError:
            continue
        for m in rx.finditer(text):
            if m.group(1) in names:
                out[m.group(1)].add(slug)
    return {k: sorted(v) for k, v in sorted(out.items()) if v}


# ── the slice for a page ─────────────────────────────────────────────────────────────
_TAB_KEYS = {
    "identity": ("signin", "provider", "issuer", "client_id", "jwks"),
    "look": tuple(f"look.{k}" for k in ("preset", "mode", "primary", "secondary", "font", "style",
                                        "decor", "bg_effect")),
    "services": ("services",),
    "ways": ("tor", "tailnet", "egress"),
}


def options_for(where) -> "list[Option]":
    """The options the page the person is on edits (domain tab's keys first)."""
    slug = (getattr(where, "slug", "") or "").strip()
    tab = (getattr(where, "tab", "") or "").strip()
    if slug in DOMAIN_PAGES:
        opts = [o for o in catalogue("domain") if slug in o.page]
        first = _TAB_KEYS.get(tab, ())
        opts.sort(key=lambda o: (0 if o.key in first else 1))
        if slug == "localmesh_domain_services":
            opts += [o for o in catalogue("mesh") if slug in o.page and not o.secret]
        return opts
    if slug in MESH_PAGES:
        return [o for o in catalogue("mesh") if slug in o.page]
    if slug == "domains":
        return [o for o in catalogue("domain") if "domains" in o.page]
    if slug:
        cfg = getattr(where, "cfg", None)
        out = []
        for o in catalogue("image"):
            if slug not in o.page:
                continue
            if cfg is not None:
                try:
                    if not config.field_in_scope(o.key, cfg):
                        continue
                except Exception:            # noqa: BLE001
                    pass
            out.append(o)
        return out
    return []


def render_options(opts: Iterable[Option], budget_tokens: int = 600,
                   current: Optional[Callable[[Option], Any]] = None) -> str:
    """``- key (label): choices | current: value`` lines under ``budget_tokens``."""
    lines = []
    for o in opts:
        cur = ""
        if o.secret:
            cur = NEVER_SHOWN
        elif current is not None:
            try:
                v = current(o)
            except Exception:                # noqa: BLE001
                v = None
            if v is not None:
                if isinstance(v, (list, tuple, set, frozenset)):
                    v = ", ".join(str(x) for x in v) or "none"
                elif isinstance(v, bool):
                    v = "on" if v else "off"
                cur = str(v) if str(v) != "" else "not set"
        line = f"- {o.key} ({o.label}): {o.choices_text()}"
        if o.doc and not o.key.startswith("look.") and o.scope != "image":
            line += f" — {o.doc}"
        if cur:
            line += f" | current: {cur}"
        if o.setter == "" and not o.secret:
            line += " | read-only here"
        lines.append(line)
    text = "\n".join(lines)
    while tokens(text) > budget_tokens and len(lines) > 1:
        lines.pop()
        text = "\n".join(lines)
    return text


def catalogue_text(scope: Optional[str] = None) -> str:
    """The full dump, one line per option, for the ``catalogue`` command and the docs."""
    out = []
    for s in ([scope] if scope else SCOPES):
        if s not in SCOPES:
            return f"no such scope {s!r}; one of {', '.join(SCOPES)}"
        out.append(f"# {s} options")
        for o in catalogue(s):
            cur = f" | default: {o.default}" if o.default not in ("", (), None, False, 0) else ""
            how = " | set on the page, never shown" if o.secret else (
                " | the assistant can propose a change" if o.setter else "")
            pages = ", ".join(o.page) if o.page else "-"
            out.append(f"- {o.key} ({o.label}): {o.choices_text()}{cur} | page: {pages}{how}"
                       + (f" | {o.doc}" if o.doc else ""))
        out.append("")
    return "\n".join(out).rstrip() + "\n"

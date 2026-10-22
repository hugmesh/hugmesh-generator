"""A brand's LOOK: inherit from the superbrand, override field by field, one stylesheet
(hugmesh-generator#654, decisions D6, D7, D18 and D19).

THE MODEL. A look is a flat record of named fields (:data:`LOOK_FIELDS`): the colours,
the font, the shape and decoration, the header and footer, the page background effect,
the two web pictures and the desktop pictures. The superbrand's look holds the values
every brand starts from; a brand's look holds ONLY the fields that brand changed. One
function, :func:`effective_look`, resolves a brand's look (the superbrand's value unless
the brand overrides that one field) and one function, :func:`look_css`, turns a resolved
look into the stylesheet. The preview in the Studio, the per-brand files the Docker
front serves, the kind ConfigMap and the mesh-wide HUG_THEME_CSS are all meant to call
these two, so a brand cannot look one way in the preview and another on the mesh.

THE CONFIG TODAY. The image config carries most of these fields as ``login_*`` (and the
desktop ones under their builder names); :func:`look_from_cfg` reads them and
:func:`apply_look_to_cfg` writes them back, and for a look built from a config
``look_css`` writes byte for byte what ``cfg.login_theme_css()`` writes (pinned in
tests/test_look_model.py), so the hand-over to this module changes no mesh. The fields
the config cannot hold yet (shape, decoration, the two pictures) live in the brand
record (D5); :class:`CfgLook` keeps them beside the config until that record lands.

THE BUDGET (D19). One brand's finished stylesheet may be at most 100 KiB
(:data:`LOOK_CSS_BUDGET`); the two web pictures are what can spend it, so the meter the
editor shows is :func:`budget` and a picture that would not fit is refused by
:func:`picture_fits` with the numbers. Two bigger ceilings exist on the mesh: an
environment entry (measured on this host: NAME=value of 131071 bytes starts a process,
131072 does not), which is how the superbrand's look reaches the Docker containers as
HUG_THEME_CSS, and the 1 MiB ConfigMap that carries looks on the kind cluster. They are
kept below them by construction (the budget is under the environment entry, a test pins
that, so no separate environment check exists) and the ConfigMap is checked where it
applies (:func:`fits_configmap`).

Qt-free, like the rest of core/: the window, the text screens and the start commands
share it.
"""
from __future__ import annotations

import base64
import os
import re
import shutil
from collections.abc import Callable, Collection, Mapping
from dataclasses import dataclass
from typing import Any

from . import brand_images, fonts, platform_preview, theme, theme_presets

__all__ = [
    "LOOK_FIELDS", "LOOK_DEFAULTS", "CFG_FIELDS", "IDENTITY_FIELDS", "PICTURE_FIELDS",
    "SUPERBRAND", "OWN", "Resolved", "LookError", "LookBudgetError",
    "INHERITED_TEXT", "OWN_TEXT", "USE_SUPERBRAND", "USE_SUPERBRAND_ARMED",
    "PATHS_WITH_OWN_LOOK", "DOCKER_ONLY_SENTENCE", "DOCKER_SERVED_SENTENCE",
    "DOCKER_NOT_SERVED_SENTENCE", "VANTA_UNSELECTABLE",
    "normalise", "effective_look", "resolve", "look_css",
    "LOOK_CSS_BUDGET", "ENV_ENTRY_LIMIT", "ENV_VALUE_LIMIT", "CONFIGMAP_LIMIT",
    "Budget", "budget", "picture_cost", "picture_fits", "fits_configmap",
    "write_look_files", "look_from_cfg", "apply_look_to_cfg", "Look", "CfgLook",
    "Outcome", "HEX_FIELDS", "EFFECT_LABELS", "STYLE_LABELS", "DECOR_LABELS",
    "check_value", "check_carriers", "requirements", "Board", "board", "preview_html", "write_look_preview",
]

# ── the fields ───────────────────────────────────────────────────────────────────────
#: Every field a look has, in the order the screens show them. Each has a default in
#: LOOK_DEFAULTS; a record that names any other field is refused (never silently kept
#: or dropped: a copy site that drops a key is the defect D5 names).
LOOK_FIELDS: tuple[str, ...] = (
    # colours
    "preset", "mode", "primary", "secondary",
    # font
    "font", "font_file", "font_licence", "font_source",
    # shape and decoration
    "style", "decor",
    # header and footer
    "header_hidden", "header_size", "header_bg", "header_text",
    "footer_hidden", "footer_size", "footer_bg", "footer_text",
    # page background effect
    "bg_effect",
    # web pictures: data: URIs made by brand_images.reencode, or ""
    "logo_image", "login_bg_image",
    # desktop pictures and colours (x86 desktop images, through the flags that exist)
    "theme", "wallpaper", "boot_background", "boot_theme", "login_screen_background",
    "desktop_logo", "accent_color", "color_scheme",
)

LOOK_DEFAULTS: dict[str, Any] = {
    "preset": "", "mode": theme_presets.MODES[0], "primary": "", "secondary": "",
    "font": "", "font_file": "", "font_licence": "", "font_source": "",
    "style": theme.DEFAULT_STYLE, "decor": theme.DEFAULT_DECOR,
    "header_hidden": False, "header_size": "", "header_bg": "", "header_text": "",
    "footer_hidden": False, "footer_size": "", "footer_bg": "", "footer_text": "",
    "bg_effect": theme.BG_EFFECT_DEFAULT,
    "logo_image": "", "login_bg_image": "",
    "theme": "", "wallpaper": "", "boot_background": "", "boot_theme": "",
    "login_screen_background": "", "desktop_logo": "", "accent_color": "", "color_scheme": "",
}

#: look field -> the ImageConfig attribute that carries it today. The fields missing
#: here (style, decor, the two pictures) have no home in the config; the brand record
#: carries them.
CFG_FIELDS: dict[str, str] = {
    "preset": "login_theme_preset", "mode": "login_theme_mode",
    "primary": "login_primary_color", "secondary": "login_secondary_color",
    "font": "login_font", "font_file": "login_font_file",
    "font_licence": "login_font_licence", "font_source": "login_font_source",
    "header_hidden": "login_header_hidden", "header_size": "login_header_size",
    "header_bg": "login_header_bg", "header_text": "login_header_text",
    "footer_hidden": "login_footer_hidden", "footer_size": "login_footer_size",
    "footer_bg": "login_footer_bg", "footer_text": "login_footer_text",
    "bg_effect": "login_bg_effect",
    "theme": "theme", "wallpaper": "wallpaper", "boot_background": "grub_background",
    "boot_theme": "grub_theme", "login_screen_background": "login_background",
    "desktop_logo": "brand_logo", "accent_color": "accent_color",
    "color_scheme": "color_scheme",
}

#: A logo is an affiliation: an unaffiliated build refuses it (the identity-versus-look
#: rule of 2026-08-26); every other field is LOOK and stays allowed. Hosts hide these
#: with the reason shown inline.
IDENTITY_FIELDS: tuple[str, ...] = ("desktop_logo",)

#: The two web pictures and the picture kind each one is re-encoded as.
PICTURE_FIELDS: dict[str, str] = {"logo_image": "logo", "login_bg_image": "background"}

#: Where a resolved value comes from.
SUPERBRAND = "superbrand"
OWN = "own"

#: The sentences both faces show, defined ONCE here (the VANTA_DEPENDENCY_NOTE
#: lesson: a copy in each face is how they stopped agreeing). tests/test_look_text.py pins
#: that the window and the text screen read these and nothing of their own.
INHERITED_TEXT = "inherited from the superbrand"
OWN_TEXT = "this brand's own"
USE_SUPERBRAND = "Use the superbrand's value"
USE_SUPERBRAND_ARMED = "Click again to use the superbrand's value"
#: Where a brand's own look can be shown (D18): the Docker mesh only. Everywhere else the
#: override controls are drawn disabled with DOCKER_ONLY_SENTENCE.
PATHS_WITH_OWN_LOOK: tuple[str, ...] = ("docker",)
#: The image and Fleet routes: what the page says, plainly, beside the disabled controls.
DOCKER_ONLY_SENTENCE = ("Not applied on this route yet: a built image and a Fleet cluster "
                        "show the mesh's own look on every domain. A domain's own look "
                        "is served on the Docker mesh only.")
#: The Docker route, when this checkout's front door serves looks by Host
#: (core/look_serving.door_serves_looks measures it; look_serving.own_look_sentence
#: picks the line).
DOCKER_SERVED_SENTENCE = ("On the Docker mesh this domain's own look is served at its own "
                          "name through the HTTPS front door, from the first page load "
                          "after the Studio starts the mesh; the command "
                          "\"make view LANE=compose\" opens it there. The plain http "
                          "door and Tor addresses show the mesh's own look.")
#: The Docker route, on a checkout whose front door does not serve looks by Host.
DOCKER_NOT_SERVED_SENTENCE = ("Recorded only: this checkout's Docker front door does not "
                              "serve a domain's own look, so every domain shows the "
                              "mesh's own look.")
#: The four vanta effects are kept in the record but cannot be picked (D6).
VANTA_UNSELECTABLE = "saved but not selectable"

#: Fields that must be #RRGGBB (or empty).
HEX_FIELDS: tuple[str, ...] = ("primary", "secondary", "header_bg", "footer_bg",
                               "accent_color")

#: The choice lists' labels, defined ONCE for both faces (the window's combos and the
#: text screens' numbered lists read these; tests/test_look_text.py pins that nothing
#: else carries a copy).
EFFECT_LABELS = {
    "gradient": "Moving gradient (shipped default — colours follow the theme)",
    "none": "None — flat themed background",
    "vanta-fog": "Vanta fog (animated WebGL)",
    "vanta-waves": "Vanta waves (animated WebGL)",
    "vanta-net": "Vanta net (animated WebGL)",
    "vanta-globe": "Vanta globe (animated WebGL)",
}
STYLE_LABELS = {
    "soft": "Soft — gently rounded, hairline border (shipped)",
    "sharp": "Sharp — no radius, dense and technical",
    "outlined": "Outlined — structure by borders",
    "elevated": "Elevated — structure by shadow, borders gone",
    "flat": "Flat — no radius, shadow or border",
    "glass": "Glass — translucent panes over the gradient",
}
DECOR_LABELS = {
    "none": "None (shipped)",
    "uwu": "UwU / UwO / OwO on the menu links",
    "arrows": "An arrow on hover, a dot when active",
    "terminal": "A cursor on hover, a star when active",
    "sparkle": "A sparkle on hover and when active",
}


@dataclass(frozen=True)
class Resolved:
    value: Any
    source: str          # SUPERBRAND | OWN


@dataclass(frozen=True)
class Outcome:
    """What an edit through :class:`Look` did, as the sentence both faces show beside the
    control. ``ok`` False means the record is exactly as it was; ``warn`` marks an
    accepted value with something the person should read."""
    ok: bool
    text: str = ""
    warn: bool = False


class LookError(ValueError):
    """An invalid look: an unknown field, a malformed value, a picture that is not
    the re-encoder's. The message is what the screens show inline."""


class LookBudgetError(LookError):
    """The finished stylesheet is past its budget. Carries the numbers."""

    def __init__(self, used: int, limit: int) -> None:
        super().__init__(
            f"This look's stylesheet would be {used:,} bytes; the budget is {limit:,} "
            f"bytes ({used - limit:,} too many). Remove or shrink a picture.")
        self.used = used
        self.limit = limit


def normalise(look: Mapping[str, Any] | None) -> dict[str, Any]:
    """``look`` as a dict holding only known fields, bools made bool and text
    stripped. Unknown fields raise: a record with a key nobody reads is a bug, not a
    preference, and dropping it silently is the copy-site defect D5 names."""
    out: dict[str, Any] = {}
    for key, value in (look or {}).items():
        if key not in LOOK_DEFAULTS:
            raise LookError(f"unknown look field {key!r}; known: {', '.join(LOOK_FIELDS)}")
        if isinstance(LOOK_DEFAULTS[key], bool):
            out[key] = bool(value)
        else:
            out[key] = ("" if value is None else str(value)).strip()
    return out


def check_value(field: str, value: Any) -> str:
    """Why ``value`` cannot be written to ``field`` ("" when it can): a colour that is
    not #RRGGBB, a name no table knows, a background effect that is saved but not
    selectable. One rule for both faces, so a refusal reads the same in each. Pictures
    and font files are not checked here: they arrive only through
    :meth:`Look.load_picture` and :meth:`Look.load_font`."""
    if field not in LOOK_DEFAULTS:
        return f"unknown look field {field!r}"
    text = value if isinstance(value, bool) else ("" if value is None else str(value)).strip()
    if isinstance(text, bool) or text == "":
        return ""
    if field in HEX_FIELDS and not theme.HEX_RE.fullmatch(text):
        return f"“{text}” is not #RRGGBB — {field} not changed"
    if field == "mode" and text not in theme_presets.MODES:
        return f"mode must be one of {', '.join(theme_presets.MODES)}, not “{text}”"
    if field == "preset":
        try:
            theme_presets.by_id(text)
        except KeyError:
            return f"no such preset “{text}”"
    if field == "font" and text not in fonts.FONT_PRESETS:
        return f"no such font style “{text}” — one of {', '.join(fonts.FONT_PRESETS)}"
    if field == "style" and text not in theme.STYLE_VARIANTS:
        return f"no such shape “{text}” — one of {', '.join(theme.STYLE_VARIANTS)}"
    if field == "decor" and text not in theme.DECOR_VARIANTS:
        return f"no such decoration “{text}” — one of {', '.join(theme.DECOR_VARIANTS)}"
    if field in ("header_size", "footer_size") and text not in theme.CHROME_SIZES:
        return f"no such size “{text}” — one of {', '.join(theme.CHROME_SIZES)}"
    if field == "bg_effect":
        if text not in theme.BG_EFFECTS:
            return f"no such effect “{text}” — one of {', '.join(theme.BG_EFFECTS)}"
        if text in theme.VANTA_EFFECTS:
            return f"{text} is {VANTA_UNSELECTABLE}: {theme.VANTA_DEPENDENCY_NOTE}"
    if field in PICTURE_FIELDS:
        try:
            _check_picture_uri(field, text)
        except LookError as exc:
            return str(exc)
    return ""


def requirements(look: Mapping[str, Any], own: Collection[str] | None = None) -> list[str]:
    """What a look still needs before it can be built: the sentences both faces show
    under the font rows. Not an edit refusal (the person types the licence AFTER picking
    the file); the image build refuses the same gap (ImageConfig.validate), so a host
    that saves a look should ask this first.

    ``own`` is the fields a brand set itself (override mode; None means every field is
    its own). The font file, its licence and its source are ONE group: a brand's own
    font file may not borrow the superbrand's licence and source, which describe a
    different file."""
    eff = effective_look(look)
    out: list[str] = []
    if eff["font_file"]:
        own_font = own is not None and "font_file" in own
        for field, label in (("font_licence", "The font's licence"),
                             ("font_source", "Where the font came from")):
            value = eff[field]
            borrowed = own_font and field not in own
            if not value or not value.isprintable() or borrowed:
                out.append(f"{label} is required with an uploaded font: embedding a face "
                           "nobody can attribute is the licensing problem the upload "
                           "path exists to make explicit."
                           + (" This brand's own font file needs its own, not the "
                              "superbrand's." if borrowed else ""))
    return out


# ── D7: inherit, then override, field by field ───────────────────────────────────────
def resolve(superbrand: Mapping[str, Any] | None,
            brand: Mapping[str, Any] | None = None) -> dict[str, Resolved]:
    """Every field with its value and where it comes from. With no ``brand`` this is the
    superbrand's own look (every field OWN, defaults filled in). A field the brand did
    not set is the superbrand's, whether the superbrand set it or left the default."""
    sb = normalise(superbrand)
    own = normalise(brand) if brand is not None else None
    out: dict[str, Resolved] = {}
    for field in LOOK_FIELDS:
        if own is not None and field in own:
            out[field] = Resolved(own[field], OWN)
        elif own is not None:
            out[field] = Resolved(sb.get(field, LOOK_DEFAULTS[field]), SUPERBRAND)
        else:
            out[field] = Resolved(sb.get(field, LOOK_DEFAULTS[field]), OWN)
    return out


def effective_look(superbrand: Mapping[str, Any] | None,
                   brand: Mapping[str, Any] | None = None) -> dict[str, Any]:
    """The look a brand shows: the superbrand's value for every field the brand did not
    override, the brand's own for the ones it did. Always holds every field."""
    return {field: r.value for field, r in resolve(superbrand, brand).items()}


# ── the stylesheet ───────────────────────────────────────────────────────────────────
LOOK_CSS_BUDGET = 100 * 1024                      # one brand's finished stylesheet
ENV_ENTRY_LIMIT = 131071                          # NAME=value, measured on this host
_ENV_NAME = "HUG_THEME_CSS="
ENV_VALUE_LIMIT = ENV_ENTRY_LIMIT - len(_ENV_NAME)
CONFIGMAP_LIMIT = 1024 * 1024                     # Kubernetes' ConfigMap ceiling

_DATA_URI_RE = re.compile(r"^data:image/(png|jpeg);base64,([A-Za-z0-9+/]+={0,2})$")


def _check_picture_uri(field: str, uri: str) -> None:
    """A picture value must be a data: URI holding bytes the re-encoder accepts (a URI
    typed into a record by hand is not trusted)."""
    m = _DATA_URI_RE.fullmatch(uri)
    if not m:
        raise LookError(f"{field} must be a data: PNG or JPEG made by the Studio's "
                        f"re-encoder, not {uri[:40]!r}")
    try:
        raw = base64.b64decode(m.group(2), validate=True)
    except ValueError as exc:
        raise LookError(f"{field}: not valid base64 ({exc})") from None
    kind = brand_images.sniff(raw)
    if kind != m.group(1):
        raise LookError(f"{field}: the data: URI says image/{m.group(1)} but the bytes are "
                        f"{kind or 'not a picture'}")
    try:
        left = brand_images.leftovers(raw, PICTURE_FIELDS[field])
    except brand_images.PictureRefused as exc:
        raise LookError(f"{field}: {exc}") from None
    # "Would the re-encoder accept it" is not "is it clean": a PNG with a tEXt chunk or
    # bytes after IEND is accepted (and cleaned) on upload, but a record that holds the
    # dirty bytes would ship them to every visitor. Cleanliness is judged from the
    # file's structure, not by comparing bytes with a fresh re-encode: the compressed
    # bytes depend on the zlib build, and a clean picture saved on another host must
    # still load here.
    if left:
        raise LookError(f"{field}: this picture was not made by the Studio's re-encoder "
                        f"(it still carries {', '.join(left)}); choose the file again so "
                        "it is cleaned")


def _font_bytes(look: Mapping[str, Any]) -> tuple[bytes, str]:
    """The uploaded font's bytes and the family name the config path derives — the
    same rule as ImageConfig.login_theme_css, so the two write the same bytes."""
    path = look.get("font_file") or ""
    if not path:
        return b"", ""
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError as exc:
        raise LookError(f"cannot read font_file: {exc}") from None
    blocks, _warns = fonts.check_font(os.path.basename(path), data)
    if blocks:
        raise LookError("; ".join(blocks))
    family = os.path.splitext(os.path.basename(path))[0].replace("-", " ").replace("_", " ")
    return data, family


def look_css(look: Mapping[str, Any], *, enforce_budget: bool = True) -> str:
    """The complete stylesheet for a RESOLVED look (every field present or defaulted),
    or "" when nothing deviates from the shipped pages.

    Composition order is the config's own (base colours and font, the preset's extra
    block, the web chrome) followed by the two blocks the config has no field for
    (shape and decoration; the pictures), each omitted when at its default, so a look
    read from a config composes the config's exact bytes. Raises :class:`LookError` on
    any invalid value and :class:`LookBudgetError` past :data:`LOOK_CSS_BUDGET`."""
    eff = effective_look(look)
    for field in ("primary", "secondary", "header_bg", "footer_bg"):
        if eff[field] and not theme.HEX_RE.fullmatch(eff[field]):
            raise LookError(f"{field} must be #RRGGBB, got {eff[field]!r}")
    if eff["mode"] not in theme_presets.MODES:
        raise LookError(f"mode must be one of {', '.join(theme_presets.MODES)}, "
                        f"got {eff['mode']!r}")
    if eff["style"] not in theme.STYLE_VARIANTS:
        raise LookError(f"style must be one of {', '.join(theme.STYLE_VARIANTS)}, "
                        f"got {eff['style']!r}")
    if eff["decor"] not in theme.DECOR_VARIANTS:
        raise LookError(f"decor must be one of {', '.join(theme.DECOR_VARIANTS)}, "
                        f"got {eff['decor']!r}")
    for field in PICTURE_FIELDS:
        if eff[field]:
            _check_picture_uri(field, eff[field])
    try:
        primary, secondary = eff["primary"], eff["secondary"]
        delta = ""
        if eff["preset"]:
            try:
                preset = theme_presets.by_id(eff["preset"])
            except KeyError as exc:
                raise LookError(str(exc)) from None
            # A preset FILLS the two colours when the screens pick it, so a look the
            # screens wrote carries the preset's own colours here and composes the
            # config's exact bytes. A colour that differs is a choice (a brand's own
            # primary over an inherited preset) and wins; the preset still supplies
            # its ramp and stripes through the delta block.
            primary = primary or preset.primary
            secondary = secondary or preset.secondary
            delta = theme_presets.delta_css(eff["preset"], eff["mode"])
        font_bytes, family = _font_bytes(eff)
        css = theme.compose_login_css(
            primary, secondary, font_preset=eff["font"], font_family=family,
            font_bytes=font_bytes)
        if delta:
            css = (css + "\n" if css else "") + delta
        chrome = theme.chrome_css(
            header_hidden=eff["header_hidden"], header_size=eff["header_size"],
            header_bg=eff["header_bg"], header_text=eff["header_text"],
            footer_hidden=eff["footer_hidden"], footer_size=eff["footer_size"],
            footer_bg=eff["footer_bg"], footer_text=eff["footer_text"],
            bg_effect=eff["bg_effect"])
        if chrome:
            css = (css + "\n" if css else "") + chrome
        shape: dict[str, str] = {}
        if eff["style"] != theme.DEFAULT_STYLE:
            shape.update(theme.style_tokens(eff["style"]))
        if eff["decor"] != theme.DEFAULT_DECOR:
            shape.update(theme.decor_tokens(eff["decor"]))
        if shape:
            css = (css + "\n" if css else "") + theme.css_root(shape)
        pictures = theme.picture_tokens(logo_uri=eff["logo_image"],
                                        login_bg_uri=eff["login_bg_image"])
        if pictures:
            css = (css + "\n" if css else "") + theme.css_root(pictures)
    except ValueError as exc:                     # the writer's and derivation's refusals
        if isinstance(exc, LookError):
            raise
        raise LookError(str(exc)) from None
    used = len(css.encode("utf-8"))
    if enforce_budget and used > LOOK_CSS_BUDGET:
        raise LookBudgetError(used, LOOK_CSS_BUDGET)
    return css


# ── the budget and the ceilings ──────────────────────────────────────────────────────
@dataclass(frozen=True)
class Budget:
    used: int
    limit: int = LOOK_CSS_BUDGET

    @property
    def free(self) -> int:
        return self.limit - self.used

    @property
    def fits(self) -> bool:
        return self.used <= self.limit

    def text(self) -> str:
        if self.fits:
            return f"{self.used:,} of {self.limit:,} bytes used ({self.free:,} free)"
        return f"{self.used:,} of {self.limit:,} bytes used ({-self.free:,} too many)"


def budget(look: Mapping[str, Any]) -> Budget:
    """The meter: how many bytes of the budget this look's stylesheet takes."""
    return Budget(len(look_css(look, enforce_budget=False).encode("utf-8")))


def picture_cost(field: str, picture_bytes: int, mime: str = "image/png") -> int:
    """The stylesheet bytes a picture of ``picture_bytes`` costs in its two
    declarations: its base64 text under BOTH token names (the --sd token and its --hug
    twin) plus the declaration text. The first picture in a look also opens the
    pictures' own :root block (a few more bytes), so :func:`picture_fits` measures the
    real composition and uses this only to say how big a file would still fit."""
    if field not in PICTURE_FIELDS:
        raise LookError(f"{field} is not a picture field")
    b64 = 4 * ((picture_bytes + 2) // 3)
    uri = len(f"data:{mime};base64,") + b64
    sd = theme.PICTURE_TOKENS[field]
    hug = "--hug-" + sd[len("--sd-"):]
    # "  <name>: url(<uri>);\n" for each of the two names
    return sum(len(f"  {name}: url(") + uri + len(");\n") for name in (sd, hug))


def picture_fits(look: Mapping[str, Any], field: str, picture: brand_images.Picture,
                 others: Mapping[str, str] | None = None) -> tuple[bool, str]:
    """Would ``picture`` fit in ``field``? ``(True, "")`` or ``(False, the sentence with
    the numbers)``. Two ceilings are asked in order: this look's own budget (which sits
    inside the one environment entry the Docker containers receive it in) and the
    ConfigMap that carries it together with ``others`` (the other looks sharing that
    ConfigMap, id -> stylesheet). A picture already in that field is replaced, so its bytes are freed
    first. Measured on the real composition, not estimated."""
    without = dict(normalise(look))
    without[field] = ""
    used = budget(without).used
    with_it = dict(without)
    with_it[field] = picture.data_uri()
    css = look_css(with_it, enforce_budget=False)
    total = len(css.encode("utf-8"))
    if total <= LOOK_CSS_BUDGET:
        return check_carriers(css, others)
    room = LOOK_CSS_BUDGET - used
    # how big a picture FILE could still fit: the room less the fixed declaration text,
    # scaled back from base64 (4 characters per 3 bytes) and halved for the twin
    fixed = picture_cost(field, 0) + len("\n:root:root {\n}\n")
    max_file = max(0, (room - fixed) * 3 // 8)
    return False, (
        f"This picture does not fit. With it the stylesheet would be {total:,} bytes; "
        f"the budget is {LOOK_CSS_BUDGET:,} bytes, of which {used:,} are used and "
        f"{room:,} are free. The picture is {len(picture.data):,} bytes after re-encoding "
        f"({picture.width}x{picture.height}) and costs {total - used:,} bytes of "
        f"stylesheet; a file of at most about {max_file:,} bytes would fit.")


def check_carriers(css: str, others: Mapping[str, str] | None = None) -> tuple[bool, str]:
    """The ceiling a finished stylesheet meets after its own budget: the ConfigMap
    shared with ``others``. ``(True, "")`` or the sentence with the numbers. Called with
    the look's final bytes by every path that grows a look (a picture, a font, a longer
    header text). The environment entry has no check of its own: the budget is below it
    (:data:`ENV_VALUE_LIMIT`), so a look inside the budget always fits."""
    if others:
        return fits_configmap({**others, "this look": css})
    return True, ""


def fits_configmap(css_by_brand: Mapping[str, str]) -> tuple[bool, str]:
    """Do these stylesheets together fit one ConfigMap (the kind cluster's carrier)?"""
    sizes = {k: len(v.encode("utf-8")) for k, v in css_by_brand.items()}
    total = sum(sizes.values())
    if total <= CONFIGMAP_LIMIT:
        return True, ""
    biggest = ", ".join(f"{k} {n:,}" for k, n in
                        sorted(sizes.items(), key=lambda kv: -kv[1])[:3])
    return False, (
        f"Together these looks are {total:,} bytes; a ConfigMap holds at most "
        f"{CONFIGMAP_LIMIT:,} bytes. Largest: {biggest}.")


# ── D18: the per-brand stylesheet files the Docker front reads ──────────────────────
_ID_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,57}[a-z0-9])?$")
_SUPERBRAND_DIR = "default"                 # the superbrand is tenant 'default' (D2)
_FILE_NAMES = ("hug-theme.css", "snap-theme.css")


def write_look_files(superbrand: Mapping[str, Any] | None,
                     brands: Mapping[str, Mapping[str, Any] | None], out_dir: str) -> list[str]:
    """Write ``<out_dir>/<brand id>/hug-theme.css`` (and ``snap-theme.css``, the older
    name some UI images still request) for the superbrand (folder ``default``) and every
    brand. The folder is what the TLS front serves by Host: a request for any path
    ending in one of these names is answered from the requesting brand's folder.

    Everything is composed and checked before anything is written, so a brand past its
    budget or an unsafe id leaves the folder untouched; a brand that is no longer in
    ``brands`` has its folder removed (when it holds only look files), so a dropped brand
    cannot keep serving a look."""
    for bid in brands:
        if bid == _SUPERBRAND_DIR or not _ID_RE.fullmatch(bid):
            raise LookError(
                f"brand id {bid!r} cannot name a look folder: ids are 1-59 lowercase "
                f"letters, digits and hyphens, start and end alphanumeric, and "
                f"{_SUPERBRAND_DIR!r} is the superbrand's")
    sb = normalise(superbrand)
    sheets = {_SUPERBRAND_DIR: look_css(sb)}
    for bid, own in brands.items():
        sheets[bid] = look_css(effective_look(sb, own or {}))
    os.makedirs(out_dir, exist_ok=True)
    for entry in os.listdir(out_dir):
        folder = os.path.join(out_dir, entry)
        # Only a folder this function could have written (its files are the look files
        # and nothing else) is removed: an out_dir shared with anything else keeps it.
        if (entry not in sheets and os.path.isdir(folder) and not os.path.islink(folder)
                and set(os.listdir(folder)) <= set(_FILE_NAMES)):
            shutil.rmtree(folder)
    written: list[str] = []
    for bid, css in sheets.items():
        folder = os.path.join(out_dir, bid)
        os.makedirs(folder, exist_ok=True)
        for name in _FILE_NAMES:
            path = os.path.join(folder, name)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(css)
            written.append(path)
    return written


# ── the config projection ────────────────────────────────────────────────────────────
def look_from_cfg(cfg) -> dict[str, Any]:
    """The look an image config carries (its ``login_*`` and desktop fields)."""
    look: dict[str, Any] = {}
    for field, attr in CFG_FIELDS.items():
        value = getattr(cfg, attr, LOOK_DEFAULTS[field])
        if isinstance(LOOK_DEFAULTS[field], bool):
            look[field] = bool(value)
        else:
            look[field] = (value or "") if value is not None else ""
    if not look.get("mode"):
        look["mode"] = LOOK_DEFAULTS["mode"]
    if not look.get("bg_effect"):
        look["bg_effect"] = LOOK_DEFAULTS["bg_effect"]
    return look


def apply_look_to_cfg(cfg, look: Mapping[str, Any]) -> None:
    """Write the fields the config carries. The others (shape, decoration, pictures)
    have no home there and stay in the brand record."""
    eff = effective_look(look)
    for field, attr in CFG_FIELDS.items():
        setattr(cfg, attr, eff[field])


# ── the preview: the token board and the page ────────────────────────────────────────
@dataclass(frozen=True)
class Board:
    """The token board as data, so the window draws swatches and the text screen prints
    the same rows. ``rows`` are (hex, caption) cells; ``contrast`` is the measured
    sentence; ``problem`` is set (and the rest empty) when the look cannot be derived."""
    rows: tuple[tuple[tuple[str, str], ...], ...] = ()
    contrast: str = ""
    problem: str = ""
    stripes: tuple[str, ...] = ()


def _board_tokens(eff: Mapping[str, Any]) -> dict[str, str]:
    if eff["preset"]:
        tokens = theme_presets.compose_tokens(eff["preset"], eff["mode"])
        if eff["primary"] and eff["primary"] != tokens["--sd-primary"]:
            tokens.update(theme._brand_tokens("primary", eff["primary"]))
        if eff["secondary"] and eff["secondary"] != tokens["--sd-secondary"]:
            tokens.update(theme._brand_tokens("secondary", eff["secondary"]))
        return tokens
    if eff["primary"] or eff["secondary"]:
        return theme.derive(eff["primary"] or theme._DEFAULT_PRIMARY, eff["secondary"])
    return theme.default_tokens()


def board(eff: Mapping[str, Any]) -> Board:
    """The derived colours and their MEASURED contrast for a resolved look, straight
    from core/theme.py — the values that ship, by construction."""
    try:
        tokens = _board_tokens(eff)
    except (ValueError, KeyError) as exc:
        return Board(problem=f"board paused: {exc}")
    bg = tokens["--sd-bg-0"]
    rows = []
    for prefix in ("primary", "secondary"):
        base = tokens[f"--sd-{prefix}"]
        soft = tokens[f"--sd-{prefix}-soft"]
        on = tokens[f"--sd-{prefix}-on"]
        bright = tokens[f"--sd-{prefix}-bright"]
        dim = tokens[f"--sd-{prefix}-dim"]
        rows.append(((base, f"{prefix}\n{base}"),
                     (bright, f"bright\n{bright}"),
                     (dim, f"dim\n{dim}"),
                     (soft, f"as text\n{soft}\n{theme.contrast_ratio(soft, bg):.2f}:1"),
                     (base, f"button text\n{on} on {base}\n"
                            f"{theme.contrast_ratio(on, base):.2f}:1")))
    text_ratio = theme.contrast_ratio(tokens["--sd-text"], bg)
    accent_ratio = theme.contrast_ratio(tokens["--sd-accent-soft"], bg)
    button_ratio = theme.contrast_ratio(tokens["--sd-primary-on"], tokens["--sd-primary"])
    verdict = ("all clear AA (4.5:1)" if min(text_ratio, accent_ratio, button_ratio) >= 4.5
               else "BELOW AA — check the colours")
    stripes: tuple[str, ...] = ()
    if eff["preset"]:
        try:
            stripes = tuple(theme_presets.by_id(eff["preset"]).stripes)
        except KeyError:
            stripes = ()
    return Board(tuple(rows), (
        f"Measured contrast on {bg}: text {text_ratio:.1f}:1, accent as text "
        f"{accent_ratio:.1f}:1, text on the primary button {button_ratio:.1f}:1 — {verdict}."),
        stripes=stripes)


# The platform preview page has no panel for the two web pictures (it predates them), so
# the Studio adds one: each picture drawn from the SAME token the real pages read, so a
# picture that parses and shows here parses and shows there.
_PICTURE_PANEL = (
    '<section class="pane" id="look-pictures" style="margin:1rem 1.25rem;padding:.8rem 1rem">'
    '<h2 style="margin:.2rem 0 .6rem;font-size:1rem">Pictures (representative layout)</h2>'
    '<div style="display:flex;gap:1rem;flex-wrap:wrap">'
    '<div id="look-logo" style="width:128px;height:128px;border:1px solid var(--sd-border);'
    'background:var(--hug-logo-image) center/contain no-repeat"></div>'
    '<div id="look-login-bg" style="width:320px;height:180px;border:1px solid var(--sd-border);'
    'background:var(--hug-login-bg-image) center/cover no-repeat"></div>'
    '</div></section>\n')


def preview_html(css: str) -> str:
    """The platform preview page for ``css`` — the delivered bytes — with the picture
    panel added when the stylesheet carries a picture."""
    page = platform_preview.platform_preview_html(css)
    if "--hug-logo-image" in css or "--hug-login-bg-image" in css:
        page = page.replace("</main>", "</main>\n" + _PICTURE_PANEL, 1)
    return page


def write_look_preview(css: str, out_dir: str) -> str:
    """Write :func:`preview_html` into ``out_dir`` and return its path."""
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, platform_preview.PLATFORM_PREVIEW_BASENAME)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(preview_html(css))
    return path


# ── the model both faces edit ────────────────────────────────────────────────────────
class Look:
    """What the window and the text screens edit: a look in DESIGN mode (the
    superbrand: every field is its own) or in OVERRIDE mode (a brand over the
    superbrand's effective look: a field is the superbrand's until set, and
    :meth:`use_superbrand` hands it back).

    Every edit either face makes comes through here and returns an :class:`Outcome`, so
    a refusal is the same sentence in both and the record is the same bytes (J-DESIGN).
    'Use the superbrand's value' is two clicks: :meth:`click_use_superbrand` arms the
    field on the first and applies on the second; any other edit disarms it.

    ``others`` is the stylesheets of the other looks that share this one's ConfigMap
    (id -> css); the host fills it, and a picture that would push the total past the
    ConfigMap is refused with the numbers. ``dependents`` is, in DESIGN mode, a function
    the host sets that returns each brand's OWN overrides (id -> look): a brand's
    stylesheet is the superbrand's look plus its own, so an edit here that would push
    one of them past the budget is refused here, with that brand's name, and not later
    by the writer that refuses the whole write (write_look_files). ``identity_allowed`` False refuses the
    desktop logo (an unaffiliated build: identity refused, look allowed)."""

    def __init__(self, own: Mapping[str, Any] | None = None, *,
                 base: Mapping[str, Any] | None = None) -> None:
        self.own: dict[str, Any] = normalise(own)
        self.base: dict[str, Any] | None = (
            None if base is None else effective_look(normalise(base)))
        self.mode = "design" if base is None else "override"
        self.armed: str | None = None
        self.others: dict[str, str] = {}
        self.dependents: Callable[[], Mapping[str, Mapping[str, Any] | None]] | None = None
        self.identity_allowed = True
        self.identity_reason = ""

    # reading
    def get(self, field: str) -> Any:
        if field not in LOOK_DEFAULTS:
            raise LookError(f"unknown look field {field!r}")
        if field in self.own:
            return self.own[field]
        if self.base is not None:
            return self.base[field]
        return LOOK_DEFAULTS[field]

    def source(self, field: str) -> str:
        if self.base is None or field in self.own:
            return OWN
        return SUPERBRAND

    def is_own(self, field: str) -> bool:
        return self.source(field) == OWN

    def effective(self) -> dict[str, Any]:
        if self.base is None:
            return effective_look(self.own)
        return effective_look(self.base, self.own)

    def record(self) -> dict[str, Any]:
        """What the brand record stores: in override mode the overrides, in design
        mode every field that differs from the shipped default."""
        if self.base is not None:
            return dict(self.own)
        return {k: v for k, v in self.own.items() if v != LOOK_DEFAULTS[k]}

    def css(self, *, enforce_budget: bool = True) -> str:
        return look_css(self.effective(), enforce_budget=enforce_budget)

    def requirements(self) -> list[str]:
        """What this look still needs, with the override-mode font group rule."""
        return requirements(self.effective(), self.own if self.mode == "override" else None)

    def budget(self) -> Budget:
        return budget(self.effective())

    # writing: the raw verbs (no checks beyond known-field), used by the checked ones
    def set(self, field: str, value: Any) -> None:
        self.armed = None
        self.own.update(normalise({field: value}))

    def use_superbrand(self, field: str) -> None:
        """Drop this brand's own value for ``field``: the superbrand's shows again. In
        design mode the superbrand has no superbrand, so it is the shipped default."""
        if field not in LOOK_DEFAULTS:
            raise LookError(f"unknown look field {field!r}")
        self.armed = None
        self.own.pop(field, None)

    # writing: the checked verbs both faces call
    def _restore(self, field: str, had: bool, old: Any) -> None:
        if had:
            self.set(field, old)
        else:
            self.use_superbrand(field)

    def try_set(self, field: str, value: Any) -> Outcome:
        """Write ``value`` to ``field`` unless it is invalid or the finished look would
        not fit its ceilings; on a refusal the record is as it was and the Outcome says
        why, with the numbers."""
        if field in IDENTITY_FIELDS and not self.identity_allowed and value:
            return Outcome(False, self.identity_reason or
                           "This build is unaffiliated: a logo names an organisation, "
                           "so it is refused (colours, fonts and pictures are allowed).")
        why = check_value(field, value)
        if why:
            return Outcome(False, why)
        if self.mode == "override":
            # D7 is field by field: a brand's field stays the superbrand's until the
            # person CHANGES it. The window fills each box with the inherited value, and
            # a box fires 'finished' when focus leaves it, so without this a person
            # tabbing through the form froze every field into a copy. An emptied colour
            # box says "use the superbrand's" (that is what its placeholder promises);
            # any other emptied text is a real value (no header text over an inherited
            # one), so it is kept.
            if field in HEX_FIELDS and not value:
                if field in self.own:
                    self.use_superbrand(field)
                return Outcome(True)
            if normalise({field: value})[field] == self.get(field):
                return Outcome(True)
        had = field in self.own
        old = self.own.get(field)
        self.set(field, value)
        try:
            css = self.css(enforce_budget=False)
        except LookError as exc:
            self._restore(field, had, old)
            return Outcome(False, str(exc))
        used = len(css.encode("utf-8"))
        if used > LOOK_CSS_BUDGET:
            self._restore(field, had, old)
            return Outcome(False, LookBudgetError(used, LOOK_CSS_BUDGET).args[0])
        ok, why = check_carriers(css, self.others)
        if ok:
            why = self._dependents_problem()
            ok = not why
        if not ok:
            self._restore(field, had, old)
            return Outcome(False, why)
        return Outcome(True)

    def _dependents_problem(self) -> str:
        """Design mode: the sentence for the first brand whose finished stylesheet (the
        superbrand's look as it now is, plus that brand's own overrides) would pass the
        budget, or for the ConfigMap those sheets and this one share (the kind cluster
        carries every look in one); "" when none does or this is not the superbrand's
        look. Override mode never asks: a brand's edit cannot see its siblings, so the
        ConfigMap total is checked for a superbrand edit only (and where ``others`` is
        filled by a host)."""
        if self.mode != "design" or self.dependents is None:
            return ""
        mine = self.effective()
        sheets: dict[str, str] = {}
        for bid, own in self.dependents().items():
            try:
                css = look_css(effective_look(mine, own or {}), enforce_budget=False)
            except LookError:
                continue                       # that brand's own value is its own problem
            used = len(css.encode("utf-8"))
            if used > LOOK_CSS_BUDGET:
                return (f"With this, the brand {bid} would have a stylesheet of {used:,} "
                        f"bytes (it starts from this look and adds its own); the budget "
                        f"is {LOOK_CSS_BUDGET:,}. Choose a smaller picture here, or "
                        f"remove a picture {bid} adds itself.")
            sheets[bid] = css
        if sheets:
            sheets["the superbrand"] = look_css(mine, enforce_budget=False)
            ok, why = fits_configmap(sheets)
            if not ok:
                return why
        return ""

    def choose_preset(self, preset_id: str) -> Outcome:
        """A preset FILLS the two colours (and the model keeps the preset too, for its
        ramp and stripes), exactly as the Themes group always has. "" is Custom."""
        why = check_value("preset", preset_id)
        if why:
            return Outcome(False, why)
        out = self.try_set("preset", preset_id)
        if not out.ok or not preset_id:
            return out
        preset = theme_presets.by_id(preset_id)
        for field, value in (("primary", preset.primary), ("secondary", preset.secondary)):
            out = self.try_set(field, value)
            if not out.ok:
                return out
        return Outcome(True)

    def hand_edit_colour(self, field: str, value: str) -> Outcome:
        """A hand-typed primary or secondary. In DESIGN mode it flips the preset to
        Custom (the Themes group's rule); in override mode a brand's typed colour simply
        wins over the inherited preset, so nothing flips."""
        out = self.try_set(field, value)
        if out.ok and self.mode == "design" and self.own.get("preset"):
            self.set("preset", "")
        return out

    def load_picture(self, field: str, path: str) -> Outcome:
        """Read the file at ``path``, re-encode it as a PNG or JPEG without its metadata,
        check it against the budget, the environment entry and the ConfigMap, and only
        then record it as a data: URI. A path of "" removes the picture. Every refusal
        is a sentence naming the reason; the record keeps its previous picture."""
        if field not in PICTURE_FIELDS:
            raise LookError(f"{field} is not a picture field")
        path = (path or "").strip()
        if not path:
            return self.try_set(field, "")
        try:
            with open(path, "rb") as fh:
                data = fh.read(brand_images.MAX_UPLOAD_BYTES + 1)
        except OSError as exc:
            return Outcome(False, f"Cannot read this file: {exc}")
        try:
            pic = brand_images.reencode(data, PICTURE_FIELDS[field],
                                        filename=os.path.basename(path))
        except brand_images.PictureRefused as exc:
            return Outcome(False, f"Refused: {exc}")
        ok, why = picture_fits(self.effective(), field, pic, self.others)
        if not ok:
            return Outcome(False, f"Refused: {why}")
        out = self.try_set(field, pic.data_uri())
        if not out.ok:
            return Outcome(False, f"Refused: {out.text}")
        dropped = f"; dropped {', '.join(pic.dropped)}" if pic.dropped else ""
        return Outcome(True, (
            f"Accepted: {pic.width}x{pic.height} {pic.mime.split('/')[1].upper()}, "
            f"{len(pic.data):,} bytes after re-encoding (was {pic.original_bytes:,})"
            f"{dropped}."))

    def load_font(self, path: str) -> Outcome:
        """Check an uploaded font at pick time (the Themes group's gates) and record
        its path. A path of "" removes it. Licence and source are asked for beside it;
        the stylesheet is not composed without them."""
        path = (path or "").strip()
        if not path:
            return self.try_set("font_file", "")
        try:
            with open(path, "rb") as fh:
                data = fh.read()
        except OSError as exc:
            return Outcome(False, f"cannot read: {exc}")
        blocks, warns = fonts.check_font(os.path.basename(path), data)
        if blocks:
            return Outcome(False, "REJECTED: " + "; ".join(blocks))
        out = self.try_set("font_file", path)
        if not out.ok:
            return out
        family = fonts.safe_font_family(os.path.splitext(os.path.basename(path))[0])
        note = (f"OK: family “{family}”, {len(data) // 1024}KB, sha256 "
                f"{fonts.font_sha256(data)[:16]}… — licence and source are required.")
        if warns:
            note += "  " + " ".join(warns)
        return Outcome(True, note, warn=bool(warns))

    # 'Use the superbrand's value': arm on the first click, apply on the second
    def click_use_superbrand(self, field: str) -> str:
        """One click of the control. Returns "armed" (first click: nothing changed),
        "applied" (second click on the same field: the superbrand's value shows again)
        or "" (design mode: there is no superbrand above to go back to)."""
        if field not in LOOK_DEFAULTS:
            raise LookError(f"unknown look field {field!r}")
        if self.mode != "override":
            return ""
        if self.armed != field:
            self.armed = field
            return "armed"
        self.use_superbrand(field)
        return "applied"


class CfgLook(Look):
    """The superbrand's look bound to an image config: every field the config carries
    is read from it and written through to it on :meth:`set`, so the Docker start that
    reads ``cfg.login_theme_css()`` sees each edit at once; the fields the config has
    no home for are kept here for the brand record."""

    def __init__(self, cfg) -> None:
        self.cfg = cfg
        super().__init__(look_from_cfg(cfg))

    def _sync(self) -> None:
        """The config is the store for the fields it carries, and other screens write
        it too, so read it fresh before answering rather than trust a copy."""
        self.own.update(look_from_cfg(self.cfg))

    def get(self, field: str) -> Any:
        self._sync()
        return super().get(field)

    def source(self, field: str) -> str:
        self._sync()
        return super().source(field)

    def effective(self) -> dict[str, Any]:
        self._sync()
        return super().effective()

    def record(self) -> dict[str, Any]:
        self._sync()
        return super().record()

    def set(self, field: str, value: Any) -> None:
        self._sync()
        super().set(field, value)
        if field in CFG_FIELDS:
            setattr(self.cfg, CFG_FIELDS[field], self.own[field])

    def use_superbrand(self, field: str) -> None:
        super().use_superbrand(field)
        if field in CFG_FIELDS:
            setattr(self.cfg, CFG_FIELDS[field], LOOK_DEFAULTS[field])

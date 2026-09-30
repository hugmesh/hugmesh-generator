"""The premade DESKTOP branding themes — the ONE place the four-theme set is declared.

Operator ask 6: *"redo entire branding section as well and remove existing themes and
leave a light and a dark, a purple, and a grey theme selectable"*.

Before this module the offered set had three DIFFERENT, silently-disagreeing sources:

* the on-disk directories under ``specs-x86/branding/themes/`` (exactly one:
  ``boogiepop``, carrying only a ``wallpaper.png``),
* the GUI, which listed those directories **and then appended the brand name**
  (``BrandingPage.initializePage`` on ``origin/main``) — so the combo offered
  ``hugmesh``, a name with **no directory**, straight into a builder that hard-errors
  ``unknown --theme 'hugmesh'`` (``build-x86-host-stage4.sh``),
* ``scripts/build-menu.sh``'s persisted ``OPT_SA_THEME`` default, a hardcoded literal.

That "the GUI offers a theme the builder rejects" defect class is what
:func:`assert_theme_set_agrees` exists to make impossible: it asserts

    PREMADE_THEMES  ==  the on-disk theme directories  ==  what the builder accepts

(the builder's accepted set *is* the directory listing — it resolves
``${SPECS_DIR}/branding/themes/<name>`` and fails when that directory is absent, so
directory-set equality is builder equality; ``test_branding_themes.py`` pins that
builder line verbatim so the equivalence cannot go stale).

Colour + copy for each theme live here too, so exactly one table feeds

* :mod:`scripts/gen-branding-themes.py`, which RENDERS the committed PNG/ini assets
  from these numbers (no downloaded art, no third-party blob, no network), and
* the wizard's theme cards, whose preview swatch paints from the same numbers — the
  swatch therefore cannot drift from the wallpaper it previews.

Pure stdlib, no Qt: the generator script and the headless config path both import it.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Dict, Tuple

__all__ = [
    "PREMADE_THEMES", "THEME_SPECS", "ThemeSpec", "ThemeSetMismatch",
    "THEME_ASSETS", "REQUIRED_THEME_ASSETS", "REMOVED_THEMES",
    "themes_dir", "on_disk_themes", "assert_theme_set_agrees", "theme_set_problem",
    "is_valid_theme",
]


class ThemeSetMismatch(RuntimeError):
    """The offered / on-disk / builder-accepted theme sets disagree."""


@dataclass(frozen=True)
class ThemeSpec:
    """One premade theme: its identity, its wizard copy, and the five colours every
    generated asset derives from.

    Colours are ``#rrggbb`` strings (lower-case, six digits — the shape
    ``hugmesh-branding``'s ``_norm_accent`` and the builder's accent validator accept).

    ``top``/``bottom``  the vertical wallpaper gradient (top row -> bottom row);
    ``accent``          the brand rule + the hexagon mark + ``ACCENT_COLOR``;
    ``ink``             foreground/text tone — also the lattice's mix target;
    ``dim``             the secondary accent (inner hexagon, second rule).
    """
    name: str
    title: str
    description: str
    top: str
    bottom: str
    accent: str
    ink: str
    dim: str

    @property
    def color_scheme_name(self) -> str:
        """The KDE ``ColorScheme`` name ``hugmesh-branding`` writes into kdeglobals."""
        return "HugMesh " + self.title


# ── the FOUR premade themes (ask 6) ──────────────────────────────────────────────
# Order is the wizard's card order and is deliberate: light, dark, then the two
# tinted neutrals. `PREMADE_THEMES` is derived from this table, never typed twice.
_SPECS: Tuple[ThemeSpec, ...] = (
    ThemeSpec(
        name="light", title="Light",
        description="Bright desktop — pale blue-grey gradient, deep blue accent. "
                    "Best on high-brightness panels and for projected/shared screens.",
        top="#f6f8fc", bottom="#d7dde9", accent="#3f5b8c", ink="#1b2333", dim="#7a89a8"),
    ThemeSpec(
        name="dark", title="Dark",
        description="Low-light desktop — near-black to slate gradient, blue accent. "
                    "The default for build/ops workstations.",
        top="#0e131b", bottom="#1e2634", accent="#4d7fd6", ink="#e6ecf7", dim="#33507f"),
    ThemeSpec(
        name="purple", title="Purple",
        description="Dark violet gradient with a lilac accent — a distinct tint for "
                    "telling one mesh's fleet apart from another at a glance.",
        top="#1b1230", bottom="#3b2a60", accent="#a678f0", ink="#f0e9fb", dim="#6a49a8"),
    ThemeSpec(
        name="grey", title="Grey",
        description="Neutral graphite gradient with a steel accent — no colour cast, "
                    "for colour-critical work and for kiosk/appliance screens.",
        top="#232629", bottom="#42474e", accent="#8f98a3", ink="#e8eaed", dim="#5c636c"),
)

THEME_SPECS: Dict[str, ThemeSpec] = {s.name: s for s in _SPECS}
#: The EXACT set the GUI offers, the generator renders and the builder must accept.
PREMADE_THEMES: Tuple[str, ...] = tuple(s.name for s in _SPECS)

#: Theme names that USED to exist and must not reappear anywhere in the tree.
#: ``test_branding_themes.py`` greps the whole repo for each of these.
REMOVED_THEMES: Tuple[str, ...] = ("boogiepop",)

#: Every file :mod:`scripts/gen-branding-themes.py` writes into a theme directory.
#: Names are the ones ``specs/usr/sbin/hugmesh-branding`` reads out of a brand dir.
THEME_ASSETS: Tuple[str, ...] = ("brand.conf", "wallpaper.png", "logo.png",
                                 "colors.colors")
#: The subset without which the theme would stage nothing useful. ``wallpaper.png`` is
#: the fallback source for BOTH the GRUB and the greeter background, so a theme
#: missing it brands nothing; ``logo.png`` is what the Calamares branding component
#: picks up (``build-x86-host-stage4.sh`` -> ``themes/<name>/logo.png``).
REQUIRED_THEME_ASSETS: Tuple[str, ...] = ("brand.conf", "wallpaper.png", "logo.png")

#: ``<generator_dir>/specs-x86/branding/themes`` — the ONE path both the builder
#: (``${SPECS_DIR}/branding/themes/<name>``) and the GUI resolve.
THEMES_SUBPATH: Tuple[str, ...] = ("specs-x86", "branding", "themes")


def themes_dir(generator_dir: str) -> str:
    """Absolute path of the premade-theme directory for a generator checkout."""
    return os.path.join(generator_dir, *THEMES_SUBPATH)


def on_disk_themes(generator_dir: str) -> Tuple[str, ...]:
    """The theme names that actually exist as directories — i.e. EXACTLY the set the
    builder will accept, since it resolves the name to a directory and errors when it
    is absent. Sorted; unreadable/absent parent -> empty (the caller decides)."""
    d = themes_dir(generator_dir)
    try:
        return tuple(sorted(x for x in os.listdir(d)
                            if os.path.isdir(os.path.join(d, x))))
    except OSError:
        return ()


def is_valid_theme(name: str) -> bool:
    """True for "" (no premade theme — stock look) and for a declared theme name.

    Deliberately checks the DECLARED set, not the disk: a saved config carrying a
    theme name is validated against the contract even when it is loaded on a machine
    whose checkout is mid-regeneration.
    """
    return name == "" or name in THEME_SPECS


def theme_set_problem(generator_dir: str) -> str:
    """"" when the sets agree; otherwise a one-line operator-readable explanation.

    The NON-raising twin of :func:`assert_theme_set_agrees`, for the GUI: under PyQt6
    an exception escaping a slot calls ``qFatal`` and kills the Studio, so the wizard
    must render a mismatch as a visible note, never as a traceback.
    """
    declared = set(PREMADE_THEMES)
    disk = set(on_disk_themes(generator_dir))
    if declared != disk:
        missing = sorted(declared - disk)
        extra = sorted(disk - declared)
        bits = []
        if missing:
            bits.append("missing on disk: " + ", ".join(missing))
        if extra:
            bits.append("on disk but not offered: " + ", ".join(extra))
        return ("Premade themes are out of sync with " + themes_dir(generator_dir)
                + " (" + "; ".join(bits)
                + "). Re-run scripts/gen-branding-themes.py.")
    root = themes_dir(generator_dir)
    for name in PREMADE_THEMES:
        for asset in REQUIRED_THEME_ASSETS:
            if not os.path.isfile(os.path.join(root, name, asset)):
                return (f"Theme '{name}' is missing {asset} — it would stage nothing. "
                        "Re-run scripts/gen-branding-themes.py.")
    return ""


def assert_theme_set_agrees(generator_dir: str) -> None:
    """Raise :class:`ThemeSetMismatch` unless the offered set, the on-disk set and the
    builder-accepted set are all the same four names, each complete on disk.

    This is THE set-equality assertion for ask 6. A fifth directory (a theme the
    builder would accept but the GUI never offers) fails it; a deleted directory (a
    theme the GUI offers but the builder hard-errors on) fails it too.
    """
    problem = theme_set_problem(generator_dir)
    if problem:
        raise ThemeSetMismatch(problem)

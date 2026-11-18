"""The extended theme catalogue — data, not hand-written presets.

Operator ask (2026-11-13): ten times as many colour options that work, including
accessible high-contrast ones and pretty ones with different WebGL backgrounds, some of
which change the font. Writing 340 presets by hand would be 340 chances to mistype a
hex; instead each NAMED PALETTE below is one row, and the catalogue is the cross product
of those rows with the background effects the shell renders (theme.BG_EFFECTS).

"That work" is not a promise this table makes by eye: every preset here goes through the
same theme.derive / theme_presets.compose_tokens path as the hand-written 38, which
solves accent text, field edges and role colours against each ramp's own surfaces, and
studio/tests/test_theme_catalogue.py walks every generated preset on every ramp.

The table carries two colours per palette: PRIMARY (headline/brand: wordmark, primary
buttons) and SECONDARY (accent: links, focus, secondary actions). The font, when set, is
a fonts.FONT_PRESETS system stack; nothing is fetched.
"""
from __future__ import annotations

from typing import NamedTuple, Tuple


class Palette(NamedTuple):
    slug: str
    label: str
    group: str
    primary: str
    secondary: str
    font: str = ""
    note: str = ""


#: Named palettes. Every one is crossed with every BACKGROUNDS row.
PALETTES: Tuple[Palette, ...] = (
    # Nature
    Palette("aurora", "Aurora", "Nature", "#7cffcb", "#a06cff", "Neo-grotesque",
            "Northern-lights green over violet."),
    Palette("meadow", "Meadow", "Nature", "#9bd770", "#f2c14e", "Humanist"),
    Palette("glacier", "Glacier", "Nature", "#a8e0ff", "#3d8bfd", "Geometric"),
    Palette("canyon", "Canyon", "Nature", "#e07a3f", "#f4d35e", "Slab serif"),
    Palette("moss", "Moss", "Nature", "#8fae5d", "#d9c27a", ""),
    Palette("lagoon", "Lagoon", "Nature", "#2ec4b6", "#ff9f1c", "Rounded"),
    Palette("redwood", "Redwood", "Nature", "#c8553d", "#8fbf9f", "Old style serif"),
    Palette("tundra", "Tundra", "Nature", "#cfd8dc", "#7fb3d5", ""),
    Palette("savanna", "Savanna", "Nature", "#e9c46a", "#e76f51", "Humanist"),
    Palette("reef", "Reef", "Nature", "#ff7f7f", "#00b4d8", "Rounded"),
    # Gemstones
    Palette("emerald", "Emerald", "Gemstones", "#50c878", "#c0f0d0", "Didone"),
    Palette("sapphire", "Sapphire", "Gemstones", "#4f7dff", "#9ec5ff", ""),
    Palette("ruby", "Ruby", "Gemstones", "#e0115f", "#ff8fab", "Didone"),
    Palette("topaz", "Topaz", "Gemstones", "#ffc87c", "#ff9248", ""),
    Palette("amethyst", "Amethyst", "Gemstones", "#9966cc", "#e0b0ff", "Old style serif"),
    Palette("opal", "Opal", "Gemstones", "#a8c3bc", "#f2a6c8", "Transitional serif"),
    Palette("onyx", "Onyx", "Gemstones", "#c9c9c9", "#7c7cff", "Neo-grotesque"),
    Palette("garnet", "Garnet", "Gemstones", "#a52a2a", "#f4a261", "Antique"),
    # Cities
    Palette("neon-tokyo", "Neon Tokyo", "Cities", "#ff2e88", "#2ef2ff", "Industrial",
            "Signage pink and cyan."),
    Palette("paris-dusk", "Paris Dusk", "Cities", "#f6bd60", "#b5838d", "Didone"),
    Palette("havana", "Havana", "Cities", "#ff8c61", "#33a1fd", "Handwritten"),
    Palette("reykjavik", "Reykjavík", "Cities", "#89c2d9", "#f28482", "Neo-grotesque"),
    Palette("marrakesh", "Marrakesh", "Cities", "#e76f51", "#2a9d8f", "Antique"),
    Palette("brooklyn", "Brooklyn", "Cities", "#d62828", "#fcbf49", "Industrial"),
    Palette("kyoto", "Kyoto", "Cities", "#e5989b", "#6d9773", "Transitional serif"),
    Palette("lisbon", "Lisbon", "Cities", "#ffd166", "#118ab2", ""),
    # Seasons
    Palette("spring-bloom", "Spring Bloom", "Seasons", "#ffafcc", "#a2d2ff", "Rounded"),
    Palette("high-summer", "High Summer", "Seasons", "#ffbe0b", "#3a86ff", ""),
    Palette("harvest", "Harvest", "Seasons", "#e36414", "#9a031e", "Old style serif"),
    Palette("first-frost", "First Frost", "Seasons", "#caf0f8", "#90e0ef", "Geometric"),
    Palette("monsoon", "Monsoon", "Seasons", "#4cc9f0", "#7209b7", ""),
    Palette("midwinter", "Midwinter", "Seasons", "#e0e1dd", "#778da9", "Transitional serif"),
    # Cosmic
    Palette("nebula", "Nebula", "Cosmic", "#f72585", "#4cc9f0", "Geometric"),
    Palette("event-horizon", "Event Horizon", "Cosmic", "#ff9e00", "#9d4edd", ""),
    Palette("stardust", "Stardust", "Cosmic", "#ffe066", "#c77dff", "Rounded"),
    Palette("red-giant", "Red Giant", "Cosmic", "#ff4d00", "#ffb703", "Industrial"),
    Palette("pulsar", "Pulsar", "Cosmic", "#00f5d4", "#9b5de5", "Neo-grotesque"),
    Palette("deep-field", "Deep Field", "Cosmic", "#8ecae6", "#ffb5a7", ""),
    # Retro
    Palette("synthwave", "Synthwave", "Retro", "#ff71ce", "#01cdfe", "Industrial",
            "Outrun pink and electric blue."),
    Palette("vaporwave", "Vaporwave", "Retro", "#b967ff", "#05ffa1", "Geometric"),
    Palette("phosphor", "Phosphor", "Retro", "#33ff33", "#ffb000", "Monospace",
            "Green-screen terminal."),
    Palette("amber-crt", "Amber CRT", "Retro", "#ffb000", "#ff6b35", "Monospace"),
    Palette("diner", "Diner", "Retro", "#ef476f", "#06d6a0", "Handwritten"),
    Palette("arcade", "Arcade", "Retro", "#fee440", "#f15bb5", "Industrial"),
    Palette("polaroid", "Polaroid", "Retro", "#f4a259", "#5b8e7d", "Handwritten"),
    # Food
    Palette("espresso", "Espresso", "Food", "#c69c72", "#e9d8a6", "Antique"),
    Palette("matcha", "Matcha", "Food", "#a3c585", "#f1e3d3", "Humanist"),
    Palette("berry", "Berry", "Food", "#c9184a", "#ffb3c1", "Rounded"),
    Palette("citrus", "Citrus", "Food", "#ffca3a", "#8ac926", ""),
    Palette("chai", "Chai", "Food", "#d4a373", "#ccd5ae", "Old style serif"),
    Palette("blueberry", "Blueberry", "Food", "#5e60ce", "#b8c0ff", ""),
    Palette("sorbet", "Sorbet", "Food", "#ff9b85", "#ffd97d", "Rounded"),
)

#: (id suffix, label suffix, theme.BG_EFFECTS value, note). "" suffix = the shipped
#: gradient, so the plain palette id is the gradient variant.
BACKGROUNDS: Tuple[Tuple[str, str, str, str], ...] = (
    ("", "", "", "Animated gradient wash."),
    ("flat", "Flat", "none", "Still background, no motion."),
    ("fog", "Fog", "vanta-fog", "WebGL drifting fog."),
    ("waves", "Waves", "vanta-waves", "WebGL rolling waves."),
    ("net", "Net", "vanta-net", "WebGL connected-node net."),
    ("globe", "Globe", "vanta-globe", "WebGL wireframe globe."),
)

#: High-contrast presets: saturated accents chosen for maximum separation, no motion
#: (effect "none"), and plain legible system faces. Pair them with the "contrast-dark"
#: or "contrast-light" ramp for pure black/white surfaces.
HIGH_CONTRAST: Tuple[Palette, ...] = (
    Palette("hc-yellow-black", "Signal Yellow", "High contrast", "#ffff00", "#00ffff", "System UI"),
    Palette("hc-cyan", "Cyan Beacon", "High contrast", "#00ffff", "#ffff00", "System UI"),
    Palette("hc-white", "Pure White", "High contrast", "#ffffff", "#ffd700", "Neo-grotesque"),
    Palette("hc-lime", "Lime Signal", "High contrast", "#00ff00", "#ff00ff", "System UI"),
    Palette("hc-magenta", "Magenta Signal", "High contrast", "#ff00ff", "#00ff00", "System UI"),
    Palette("hc-orange", "Safety Orange", "High contrast", "#ff9900", "#00ffff", "Bootstrap native stack"),
    Palette("hc-amber", "Amber Alert", "High contrast", "#ffbf00", "#ffffff", "Bootstrap native stack"),
    Palette("hc-sky", "Sky Signal", "High contrast", "#66ccff", "#ffff66", "Neo-grotesque"),
    Palette("hc-rose", "Rose Signal", "High contrast", "#ff66b3", "#66ffcc", "Neo-grotesque"),
    Palette("hc-mint", "Mint Signal", "High contrast", "#66ffcc", "#ff66b3", "System UI"),
    Palette("hc-gold", "Gold Standard", "High contrast", "#ffd700", "#ffffff", "Transitional serif"),
    Palette("hc-ice", "Ice", "High contrast", "#e0ffff", "#ffd700", "Humanist"),
    Palette("hc-coral", "Coral Signal", "High contrast", "#ff7f50", "#7fffd4", "System UI"),
    Palette("hc-violet", "Violet Signal", "High contrast", "#cc99ff", "#ffff00", "Neo-grotesque"),
    Palette("hc-ocean", "Ocean Signal", "High contrast", "#00bfff", "#ffd700", "Bootstrap native stack"),
    Palette("hc-forest", "Forest Signal", "High contrast", "#7cfc00", "#ffffff", "Humanist"),
    Palette("hc-fire", "Fire Signal", "High contrast", "#ff4500", "#ffff00", "System UI"),
    Palette("hc-electric", "Electric", "High contrast", "#7df9ff", "#ff1493", "Neo-grotesque"),
    Palette("hc-sun", "Sunlight", "High contrast", "#fff200", "#ff6600", "Bootstrap native stack"),
    Palette("hc-chalk", "Chalkboard", "High contrast", "#f8f8f8", "#7fff00", "Rounded"),
    Palette("hc-terminal", "Terminal", "High contrast", "#00ff66", "#ffffff", "Monospace"),
    Palette("hc-blueprint", "Blueprint", "High contrast", "#ffffff", "#00e5ff", "Monospace"),
    Palette("hc-ink", "Ink", "High contrast", "#000000", "#0000cc", "Transitional serif",
            "Built for the contrast-light ramp."),
    Palette("hc-newsprint", "Newsprint", "High contrast", "#1a1a1a", "#b30000", "Old style serif",
            "Built for the contrast-light ramp."),
    Palette("hc-navy", "Navy Ink", "High contrast", "#001f5b", "#8b0000", "Humanist",
            "Built for the contrast-light ramp."),
    Palette("hc-forest-ink", "Forest Ink", "High contrast", "#003300", "#5a0099", "Humanist",
            "Built for the contrast-light ramp."),
    Palette("hc-burgundy", "Burgundy Ink", "High contrast", "#5c0020", "#003d7a", "Antique",
            "Built for the contrast-light ramp."),
    Palette("hc-graphite", "Graphite", "High contrast", "#222222", "#0050a0", "Neo-grotesque",
            "Built for the contrast-light ramp."),
    Palette("hc-dyslexia", "Steady Reader", "High contrast", "#ffeb99", "#99ddff", "Humanist",
            "Soft cream on dark, wide humanist face."),
    Palette("hc-low-vision", "Low Vision", "High contrast", "#ffffff", "#ffff00", "Bootstrap native stack",
            "Maximum separation, largest system face stack."),
)


def rows() -> Tuple[Tuple[str, str, str, str, str, str, str, str], ...]:
    """(id, label, group, primary, secondary, note, effect, font) for every generated
    preset, in presentation order: palettes by group, each with its six backgrounds,
    then the high-contrast set."""
    out = []
    for pal in PALETTES:
        for suffix, label_suffix, effect, bg_note in BACKGROUNDS:
            pid = f"{pal.slug}-{suffix}" if suffix else pal.slug
            label = f"{pal.label} · {label_suffix}" if label_suffix else pal.label
            note = " ".join(x for x in (pal.note, bg_note) if x)
            out.append((pid, label, pal.group, pal.primary, pal.secondary, note,
                        effect, pal.font))
    for pal in HIGH_CONTRAST:
        out.append((pal.slug, pal.label, pal.group, pal.primary, pal.secondary,
                    pal.note or "High contrast, no motion.", "none", pal.font))
    return tuple(out)

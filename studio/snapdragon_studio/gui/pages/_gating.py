"""Per-platform capability gating for wizard widgets (G10/G11/G12/G16).

The wizard historically gated widgets by MODE (standalone vs cloud/mesh) while
``config.py`` emits flags by PLATFORM — so an ARM cloud/mesh build showed ~24
x86-only widgets whose values were silently dropped from the argv. This module
is the single place pages ask "does the selected platform's builder actually
take this field?" and get the two halves of the established gating pattern
(BuildPage's installer_ui / HomePage's unlock combos):

* ``gate_widgets()``  — initializePage(): grey the widget (with an explanatory
  tooltip) when the platform's builder has no flag for the field;
* ``clear_unsupported()`` — validatePage(): reset the config field to its
  dataclass default so a stale choice picked on another platform can never
  linger into a saved config or the emitted command.

The capability table itself is core.config's exported PLATFORM_FIELD_SUPPORT
(field name -> platform ids whose arg builder emits it), which a diff-probe
test (test_platform_field_support_matches_emission) pins to the REAL emission
surface so it cannot drift from the argv builders. Fields absent from the
table are emitted for every platform (fail-open: never grey a universal knob).
"""
from __future__ import annotations

from dataclasses import MISSING

from ...core.config import PLATFORM_FIELD_SUPPORT, ImageConfig


def platform_supports(fld: str, platform: str) -> bool:
    """True when the platform's builder actually receives this config field
    ("" = the x86 default, matching the pages' `platform in ("", "x86")` idiom).
    Unknown fields are all-platform (fail-open)."""
    platforms = PLATFORM_FIELD_SUPPORT.get(fld)
    return platforms is None or (platform or "x86") in platforms


def unsupported_note(platform: str) -> str:
    """The tooltip explaining WHY a widget is greyed (silent-drop prevention)."""
    return (f"Not available for the {platform or 'x86'} builder — it has no flag "
            "for this option, so a value here would be silently dropped from the "
            "build. Cleared when you leave the page.")


def gate_widgets(platform: str, field_widgets: dict) -> None:
    """initializePage() half: enable/disable widgets per the capability table.

    field_widgets maps a config field name to the widget (or tuple of widgets —
    e.g. a line edit's container row holding its Browse… button) carrying it.
    Disabling a QGroupBox greys all its children at once, matching the
    BrandingPage form-container pattern."""
    for fld, widgets in field_widgets.items():
        supported = platform_supports(fld, platform)
        for w in (widgets if isinstance(widgets, (list, tuple)) else (widgets,)):
            w.setEnabled(supported)
            w.setToolTip("" if supported else unsupported_note(platform))


def clear_unsupported(cfg: ImageConfig, fields: tuple[str, ...]) -> list[str]:
    """validatePage() half: reset each unsupported field to its ImageConfig
    dataclass default so the greyed widget's stale value can't reach save()
    or the emitted argv. Returns the fields actually cleared."""
    cleared = []
    for fld in fields:
        if platform_supports(fld, cfg.platform):
            continue
        f = ImageConfig.__dataclass_fields__[fld]
        default = f.default_factory() if f.default is MISSING else f.default
        setattr(cfg, fld, default)
        cleared.append(fld)
    return cleared

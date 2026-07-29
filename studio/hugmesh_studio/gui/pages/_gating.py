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

from ...core.config import (
    PLATFORM_FIELD_SUPPORT,
    ImageConfig,
    field_in_scope,
    scope_reject_reason,
)


def platform_supports(fld: str, platform: str) -> bool:
    """True when the platform's builder actually receives this config field
    ("" = the x86 default, matching the pages' `platform in ("", "x86")` idiom).
    Unknown fields are all-platform (fail-open)."""
    platforms = PLATFORM_FIELD_SUPPORT.get(fld)
    return platforms is None or (platform or "x86") in platforms


def scope_allows(fld: str, cfg: ImageConfig) -> bool:
    """The composed field gate: is this field meaningful for THIS image on all three axes
    (platform x role-class x mode)?

    ``platform_supports`` answers only "does this builder PARSE the flag" — and that is the
    hole the whole FIELD_SCOPE track exists to close, because the x86 builder parses plenty
    of flags that are meaningless on a cluster node. It takes them, warns-and-ignores or
    silently builds the wrong image, and exits 0. So a platform-valid but role-invalid
    combination sails through the only gate that ever existed. This adds the other two axes.

    Unknown fields stay FAIL-OPEN, the same rule platform_supports keeps: never gate a
    universal knob just because nobody wrote it down.

    Thin delegate to core.config.field_in_scope so the predicate has ONE implementation:
    the wizard and any Qt-free consumer (worklist materialize, --print-command) cannot
    disagree about whether a field applies. This module keeps the name the pages call."""
    return field_in_scope(fld, cfg)


def out_of_scope_note(fld: str, cfg: ImageConfig) -> str:
    """The reason text for a row hidden by ``scope_allows`` — names the builder's contract
    rather than just asserting the option is unavailable."""
    # Reason-precise: scope_reject_reason names the AXIS that actually rejected. Testing
    # `image_class not in scope.classes` directly (the first cut) told a jetson-desktop —
    # rejected by the PLATFORM axis, and desktop-class — that it was "a cluster node /
    # headless appliance". The row's whole job is to explain WHY, so a wrong why is worse
    # than none.
    reason = scope_reject_reason(fld, cfg)
    if reason == "class":
        return (f"Not applicable to this image: {cfg.role or 'this role'} is a cluster "
                "node / headless appliance, and this option only means something on a "
                "desktop-class image. The builder would take the flag and quietly build "
                "the wrong thing, so the wizard does not offer it here.")
    if reason == "platform":
        return unsupported_note(cfg.platform)
    return (f"Not applicable in {cfg.mode or 'this'} mode — every image in this flow "
            "exists to join the cluster, which is exactly what this option turns off.")


def unsupported_note(platform: str) -> str:
    """The tooltip explaining WHY a widget is greyed (silent-drop prevention)."""
    return (f"Not available for the {platform or 'x86'} builder — it has no flag "
            "for this option, so a value here would be silently dropped from the "
            "build. Cleared when you leave the page.")


def gate_widgets(platform: str, field_widgets: dict, *, hide: bool = False) -> None:
    """initializePage() half: gate widgets per the capability table.

    field_widgets maps a config field name to the widget (or tuple of widgets —
    e.g. a line edit's container row holding its Browse… button) carrying it.
    Disabling/hiding a QGroupBox greys/hides all its children at once, matching the
    BrandingPage form-container pattern.

    ``hide=True`` HIDES (setVisible) the inapplicable widget instead of greying it
    (setEnabled) — the spec's "hide inapplicable options" mode. Emission stays
    preserved by the SAME two guards as the grey mode: (1) clear_unsupported() in
    validatePage still resets a hidden field to its dataclass default, and (2)
    initializePage re-runs this gate on every visit, so setVisible(True) restores the
    widget (and its collectable value) the moment the platform supports the field
    again — a hidden option that becomes applicable later is reachable + emitted."""
    for fld, widgets in field_widgets.items():
        supported = platform_supports(fld, platform)
        for w in (widgets if isinstance(widgets, (list, tuple)) else (widgets,)):
            if hide:
                w.setVisible(supported)
            else:
                w.setEnabled(supported)
            w.setToolTip("" if supported else unsupported_note(platform))


def gate_widgets_role_class(widgets, allowed: bool, reason: str, *, hide: bool = False) -> None:
    """Role-class gating twin of ``gate_widgets`` (G/spec 2/3/7).

    Where ``gate_widgets`` keys each widget on the per-field PLATFORM_FIELD_SUPPORT
    table, this greys a WHOLE surface on a single capability boolean from core.config
    (``branding_allowed`` / ``home_options_allowed`` / ``tailnet_sso_visible``) — the
    new role-class axis (desktop vs node, cloud-branded-desktop, non-mesh). Disabling a
    QGroupBox greys all its children at once, matching the platform-keyed idiom.

    ``widgets`` is one widget or an iterable of them; ``reason`` is the explanatory
    tooltip shown while the surface is greyed (blank when allowed). ``hide=True`` hides
    (setVisible) the surface instead of greying it — emission is still preserved by the
    caller's role-class clear (HOME_DESKTOP_FIELDS reset in validatePage) plus the
    every-visit re-gate that restores the surface when the role class allows it again."""
    for w in (widgets if isinstance(widgets, (list, tuple)) else (widgets,)):
        if hide:
            w.setVisible(allowed)
        else:
            w.setEnabled(allowed)
        w.setToolTip("" if allowed else reason)


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

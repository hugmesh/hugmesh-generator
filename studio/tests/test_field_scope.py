"""FIELD_SCOPE structure guards — the field-gating authority (platform x role-class x mode)
and the DERIVED PLATFORM_FIELD_SUPPORT compat view.

This step is a PURE REFACTOR: FIELD_SCOPE becomes the authority, PLATFORM_FIELD_SUPPORT is
projected back out of it under its historical name, and every existing consumer keeps
reading exactly the mapping it always did. These tests pin that "exactly":

  * the derived view is IDENTICAL to the hand-written table it replaced (no emission or
    greying change can hide in this diff);
  * an override may narrow the role-class/mode axes but may NEVER perturb the platform
    axis (the one axis the old table owned);
  * every role-class/mode narrowing declared today restates a rule some EXISTING predicate
    already enforces — asserted against that predicate over the full mode x role space, so
    the table and the predicate cannot drift apart. FIELD_SCOPE is documentation-of-record
    at this step; it becomes load-bearing when the gating consumers move onto it.

Pure-core: no Qt import — runs in the headless suite.
"""
from __future__ import annotations

import itertools
import os
import re

import pytest

from hugmesh_studio.core.config import (
    _ALL_CLASSES, _ALL_MODES, _ALL_PLATFORMS, _FIELD_PLATFORMS, _FIELD_SCOPE_OVERRIDES,
    _STANDALONE_CLASS_GATED_PLATFORMS,
    BUILDER_SCRIPTS,
    DESKTOP_ROLES, FIELD_SCOPE, FieldScope, HOME_DESKTOP_FIELDS, NODE_ROLES,
    PLATFORM_FIELD_SUPPORT, THEME_FIELDS, ImageConfig, branding_allowed, field_in_scope,
    image_class, scope_reject_reason, scope_violations,
    home_options_allowed,
)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

ALL_ROLES = tuple(dict.fromkeys(DESKTOP_ROLES + NODE_ROLES))
MODE_ROLE = tuple(itertools.product(_ALL_MODES, ALL_ROLES))


def _in_scope(fld: str, mode: str, role: str, platform: str | None = None) -> bool:
    """The role-class/mode half of the composed scope predicate the GUI adopts.

    ``platform`` is only needed for a field whose class rule is platform-conditional
    (``class_platforms`` — see FieldScope). Callers testing a field with a flat class axis
    may omit it; None means "the class rule applies here", which is the common case."""
    scope = FIELD_SCOPE[fld]
    class_gated = (scope.class_platforms is None or platform is None
                   or platform in scope.class_platforms)
    if class_gated and image_class(mode, role) not in scope.classes:
        return False
    return mode in scope.modes


# ── the derived compat view ─────────────────────────────────────────────────────────

def test_platform_field_support_is_derived_from_field_scope():
    """PLATFORM_FIELD_SUPPORT must BE the platform axis of FIELD_SCOPE — not a second
    hand-maintained copy that can drift."""
    assert PLATFORM_FIELD_SUPPORT == {f: s.platforms for f, s in FIELD_SCOPE.items()}


def test_derived_view_preserves_the_original_table_exactly():
    """Same keys, same order, same values as the table FIELD_SCOPE replaced. Key ORDER is
    pinned too: the catalog emitter and the test_cli_args diff-probe both iterate it."""
    assert list(PLATFORM_FIELD_SUPPORT) == list(_FIELD_PLATFORMS)
    assert PLATFORM_FIELD_SUPPORT == _FIELD_PLATFORMS


def test_field_scope_covers_exactly_the_declared_fields():
    assert set(FIELD_SCOPE) == set(_FIELD_PLATFORMS)


def test_overrides_never_perturb_the_platform_axis():
    """An override declares the role-class/mode axes. If it also (re)states platforms, it
    must restate them IDENTICALLY — a typo there would silently regrey widgets / change
    emission, which is exactly what this refactor promises it does not do."""
    for fld, scope in _FIELD_SCOPE_OVERRIDES.items():
        assert fld in _FIELD_PLATFORMS, f"{fld}: override for a field with no platform entry"
        assert scope.platforms == _FIELD_PLATFORMS[fld], (
            f"{fld}: override platforms {scope.platforms} != table {_FIELD_PLATFORMS[fld]}")


def test_axis_values_are_valid():
    for fld, scope in FIELD_SCOPE.items():
        assert set(scope.platforms) <= set(_ALL_PLATFORMS), f"{fld}: unknown platform"
        assert set(scope.classes) <= set(_ALL_CLASSES), f"{fld}: unknown role class"
        assert set(scope.modes) <= set(_ALL_MODES), f"{fld}: unknown mode"
        assert scope.classes and scope.modes and scope.platforms, f"{fld}: empty axis"


def test_undeclared_fields_are_fully_open():
    """Only the fields in _FIELD_SCOPE_OVERRIDES narrow the new axes; everything else keeps
    the "everything" default, so this step cannot gate a field nobody scoped."""
    for fld, scope in FIELD_SCOPE.items():
        if fld in _FIELD_SCOPE_OVERRIDES:
            continue
        assert scope.classes == _ALL_CLASSES and scope.modes == _ALL_MODES, (
            f"{fld} narrows an axis without a declaration in _FIELD_SCOPE_OVERRIDES")


def test_field_scope_is_frozen():
    scope = FIELD_SCOPE["theme"]
    with pytest.raises(Exception):
        scope.classes = ("node",)          # type: ignore[misc]
    assert hash(FieldScope()) == hash(FieldScope())


# ── every declared narrowing restates an EXISTING enforced rule ─────────────────────

@pytest.mark.parametrize("fld", sorted(THEME_FIELDS))
@pytest.mark.parametrize("mode,role", MODE_ROLE)
def test_theme_field_scope_matches_branding_allowed(fld, mode, role):
    """branding_allowed() already owns "theming is desktop-class and never mesh". The
    THEME_FIELDS scope must say the same thing for every mode x role."""
    cfg = ImageConfig(mode=mode, role=role)
    assert _in_scope(fld, mode, role) == branding_allowed(cfg), (
        f"{fld} @ mode={mode} role={role}: FIELD_SCOPE and branding_allowed() disagree")


@pytest.mark.parametrize("fld", sorted(HOME_DESKTOP_FIELDS))
@pytest.mark.parametrize("mode,role", MODE_ROLE)
def test_home_field_scope_matches_home_options_allowed(fld, mode, role):
    """home_options_allowed() already owns "home provisioning is desktop-class, any mode"."""
    cfg = ImageConfig(mode=mode, role=role)
    assert _in_scope(fld, mode, role) == home_options_allowed(cfg), (
        f"{fld} @ mode={mode} role={role}: FIELD_SCOPE and home_options_allowed() disagree")


def test_the_declared_narrowings_actually_narrow():
    """Guard against a vacuous pass: the two families really must exclude node-class,
    or the tests above prove nothing. (Theming's extra never-in-mesh narrowing was
    spec 2; the 2026-08-14 operator ask superseded it — desktop theming now follows
    home_mode's shape: desktop-class in any mode, applied per-entry in mesh.)"""
    node_role = NODE_ROLES[0]
    desktop_role = DESKTOP_ROLES[0]
    assert not _in_scope("theme", "cloud", node_role), "theme not node-excluded"
    assert not _in_scope("theme", "mesh", node_role), "theme not node-excluded in mesh"
    assert _in_scope("theme", "cloud", desktop_role), "theme wrongly excluded on a desktop"
    assert _in_scope("theme", "mesh", desktop_role), "theme wrongly mesh-excluded"
    assert not _in_scope("home_mode", "cloud", node_role), "home_mode not node-excluded"
    assert _in_scope("home_mode", "mesh", desktop_role), "home_mode wrongly mesh-excluded"


# ── the composed predicate (field_in_scope / _gating.scope_allows) ───────────────────

def test_field_in_scope_composes_all_three_axes():
    """field_in_scope must be exactly platform AND role-class AND mode — the composition
    step (a) only described. Checked across the whole mode x role space for both a
    platform-narrow field (home_mode, x86-only) and an all-platform one."""
    for fld in ("home_mode", "theme", "standalone"):
        for mode, role in MODE_ROLE:
            for plat in _ALL_PLATFORMS:
                cfg = ImageConfig(mode=mode, role=role, platform=plat)
                expected = (plat in FIELD_SCOPE[fld].platforms) and _in_scope(fld, mode, role, plat)
                assert field_in_scope(fld, cfg) is expected, (
                    f"{fld} on {plat}/{mode}/{role}: composed predicate disagrees with "
                    "platform AND class AND mode")


def test_field_in_scope_is_fail_open_for_unknown_fields():
    """The rule platform_supports has always kept: never gate a universal knob just because
    nobody wrote it down. A field with no FIELD_SCOPE entry is in scope everywhere."""
    cfg = ImageConfig(mode="mesh", role=NODE_ROLES[0], platform="x86")
    assert "luks_pass" not in FIELD_SCOPE or FIELD_SCOPE["luks_pass"].classes == _ALL_CLASSES
    assert field_in_scope("a_field_nobody_declared", cfg) is True


def test_gating_scope_allows_delegates_to_core():
    """_gating.scope_allows is the wizard's name for field_in_scope; one implementation, so
    the GUI and the Qt-free channels cannot disagree about whether a field applies.

    The ONE assertion in this otherwise pure-core file that has to reach into
    ``gui.pages`` — and ``gui/pages/__init__.py`` imports the Qt shim, so with no
    binding installed this raises ModuleNotFoundError at import time. It spent that
    time listed on tests/known-failures.txt as a code failure ("a gating-scope
    delegate the core no longer exposes"), which was never true: ``scope_allows``
    is right there in ``gui/pages/_gating.py`` and the test passes wherever Qt
    exists. A missing optional dependency is a SKIP — the repo's own convention for
    every other Qt-touching assertion — not a permanent deselect that also keeps the
    known-failures re-run step red forever."""
    pytest.importorskip("hugmesh_studio.gui.qt",
                        reason="no Qt binding (PySide6/PyQt6) installed")
    from hugmesh_studio.gui.pages._gating import scope_allows
    for mode, role in MODE_ROLE:
        cfg = ImageConfig(mode=mode, role=role, platform="x86")
        for fld in ("standalone", "home_mode", "theme", "bundle_source"):
            assert scope_allows(fld, cfg) == field_in_scope(fld, cfg)


# ── finding 1: --standalone is a desktop posture, meaningless in mesh ────────────────

def test_standalone_scope_excludes_nodes_in_every_mode_and_no_more():
    """The declaration behind HomePage's hide gate: --standalone is out of scope on a NODE
    class, in every mode — and in scope on a DESKTOP class, in every mode.

    The class rule is the ONLY rule, and that is builder truth rather than taste: build-rpi5
    :1037 gates --standalone on ROLE_CLIENT alone and build-x86 likewise splits on
    ROLE_CLIENT. NEITHER has a mode term. An earlier cut of this branch also narrowed
    modes=(standalone, cloud) on the prose reasoning that "--standalone is self-contradictory
    in mesh mode" — it is not, and the code says so: ROLE_CHOICES documents rpi5-desktop as
    "compose with --standalone for FDE, no mesh", i.e. a mesh-flow entry that is deliberately
    built standalone. That narrowing blocked dispatch on a documented build and force-cleared
    the flag at home.py:363, so the mesh cells below are pinned POSITIVE on purpose."""
    for role in NODE_ROLES:
        for mode in _ALL_MODES:
            cfg = ImageConfig(mode=mode, role=role, platform="x86")
            assert not field_in_scope("standalone", cfg), (
                f"--standalone still in scope on node role {role} in {mode} mode")
    for mode in _ALL_MODES:                      # incl. mesh: see docstring
        cfg = ImageConfig(mode=mode, role="laptop", platform="x86")
        assert field_in_scope("standalone", cfg), (
            f"--standalone wrongly excluded on a {mode} DESKTOP. No builder gates "
            "--standalone on mode; excluding it here hides a legitimate option and "
            "force-clears it at home.py:363 (silently non-FDE image).")


def test_standalone_scope_pins_the_reported_defect():
    """The exact combination the audit proved reaches argv: a mesh PKI node carrying
    --standalone gets ROLE_K8S=none (no kubelet/kubeadm/containerd, no cluster GitOps tree)
    while still building the full desktop stack — a node that can never join its own mesh,
    discovered hours later at deploy. The builder accepts it silently, so only scope can
    catch it."""
    cfg = ImageConfig(mode="mesh", role="pki", platform="x86", standalone=True)
    assert image_class(cfg.mode, cfg.role) == "node"
    assert not field_in_scope("standalone", cfg)
    # the defect itself is still reachable by argv construction — this step fixes the GUI
    # entry point (HomePage hides + drops it); the explicit-config warn lane is finding 1's
    # remaining half, tracked in the PR body.
    assert "--standalone" in cfg.to_cli_args()


# ── the class axis is only builder-true where a builder HAS a role-class concept ────────
def _builder_has_role_class(platform: str) -> bool:
    """Does this builder gate anything on role-class at all? ROLE_CLIENT is the builder's
    own name for the split image_class() models. Comment-stripped: build-orangepi-zero2's
    header PROSE mentions the x86/frite builders by name, so a raw substring search would
    report a role-class concept that the script does not have."""
    path = os.path.join(GENERATOR_DIR, BUILDER_SCRIPTS[platform])
    with open(path, encoding="utf-8") as fh:
        body = "\n".join(re.sub(r"(^|\s)#.*$", "", ln) for ln in fh.read().splitlines())
    return bool(re.search(r"\bROLE_CLIENT\b", body))


def test_standalone_class_gate_matches_the_builders_that_have_a_role_class():
    """DRIFT GUARD for the class_platforms deviation.

    --standalone's classes=("desktop",) is real on exactly the builders that HAVE a
    role-class concept: build-x86 (accepts it on a node and silently builds a desktop stack
    with ROLE_K8S=none) and build-rpi5 (:1037 hard-errors). frite / orangepi5 /
    orangepi-zero2 have no ROLE_CLIENT at all — they compose ${STANDALONE} unconditionally,
    and orangepizero2's role is a node-class appliance whose DEFINING posture is
    --standalone. Applying the class rule there hid the checkbox on the flow whose whole
    point it is and force-cleared the value.

    Derived from the builder scripts, not asserted as a literal: a builder that grows or
    loses a role-class concept turns this RED instead of letting the tuple rot."""
    derived = tuple(p for p in _FIELD_PLATFORMS["standalone"] if _builder_has_role_class(p))
    assert derived == _STANDALONE_CLASS_GATED_PLATFORMS, (
        f"builders with a ROLE_CLIENT concept are {derived}, but --standalone's class rule "
        f"is applied on {_STANDALONE_CLASS_GATED_PLATFORMS}. Studio must not enforce a "
        "role-class rule on a builder that has no roles.")
    # and the platforms it does NOT cover really are parsed (else this is a no-op tuple)
    assert set(_STANDALONE_CLASS_GATED_PLATFORMS) < set(_FIELD_PLATFORMS["standalone"])


def test_no_class_narrowing_reaches_a_builder_that_has_no_roles():
    """GENERAL GUARD for the bug class finding 1 belongs to — not just its one instance.

    A classes=("desktop",) entry asserts "this builder gates the flag on role-class". That
    is only true of a builder that HAS a role-class concept (ROLE_CLIENT). Today every
    narrowed field except --standalone is x86-only, so --standalone was the only field that
    could over-reach and it did: its tuple spans five platforms, three of which
    (frite/orangepi5/orangepi-zero2) have no roles at all.

    The next field to be narrowed will not necessarily be x86-only, so pin the RULE rather
    than the instance: any class narrowing must either live entirely on builders with a
    role-class concept, or name the ones it applies to via class_platforms."""
    offenders = []
    for fld, scope in FIELD_SCOPE.items():
        if set(scope.classes) == set(_ALL_CLASSES):
            continue                              # not narrowed — nothing asserted
        governed = scope.class_platforms if scope.class_platforms is not None else scope.platforms
        roleless = [p for p in governed if not _builder_has_role_class(p)]
        if roleless:
            offenders.append((fld, roleless))
    assert not offenders, (
        "these fields apply a role-class rule on builders that have no ROLE_CLIENT concept "
        f"— the builder composes the flag unconditionally, so the narrowing is invented: "
        f"{offenders}")


def test_standalone_stays_reachable_on_the_orangepizero2_appliance():
    """REGRESSION PIN (review finding 1). orangepizero2 is node-class AND standalone —
    ROLE_CHOICES calls it a "standalone HEADLESS APPLIANCE", and
    build-orangepi-zero2-stage4.sh:218-226 documents --standalone as a posture this image
    composes (LUKS2 FDE + local user, no mesh). A flat classes=("desktop",) made the wizard
    hide the box and home.py force-clear the value: a silently non-standalone, non-FDE image
    where an FDE appliance was asked for. Exactly the bug class this track exists to kill."""
    for mode in ("standalone", "cloud"):
        cfg = ImageConfig(mode=mode, role="orangepizero2", platform="orangepizero2",
                          standalone=True)
        assert image_class(cfg.mode, cfg.role) == "node", "premise: this role is node-class"
        assert field_in_scope("standalone", cfg), (
            "--standalone hidden on the orangepizero2 appliance flow — its own builder "
            "composes it unconditionally and has no role-class concept to honour")
        assert scope_violations(cfg) == ([], []), (
            "orangepizero2 + --standalone warned/blocked: the builder has zero ROLE_K8S / "
            "ROLE_CLIENT / kubelet references, so any node prose about it is fiction")
        assert "--standalone" in cfg.to_cli_args()


def test_scope_violations_never_speaks_node_prose_about_a_desktop_image():
    """HONESTY PIN. scope_violations reported `not field_in_scope(...)`, which is true for
    THREE different reasons while every message it emits blames role-class. Two desktop-class
    images tripped it:

      * mesh + rpi5-desktop (MODE axis) was BLOCKED as "the rpi5 builder hard-errors on this
        (--standalone only composes onto a desktop role)" — but rpi5-desktop IS a desktop
        role, sets ROLE_CLIENT=true, and :1037 never fires. An invented hard-error.
      * mesh + jetson-desktop (PLATFORM axis) was told it was a cluster node that can never
        join its mesh — also desktop-class.

    Neither builder does what the message claimed. A wrong reason is worse than silence."""
    for mode, role, plat in (("mesh", "rpi5-desktop", "rpi5"),
                             ("mesh", "jetson-desktop", "jetson")):
        cfg = ImageConfig(mode=mode, role=role, platform=plat, standalone=True)
        assert image_class(cfg.mode, cfg.role) == "desktop", "premise: desktop-class"
        blocking, advisory = scope_violations(cfg)
        assert (blocking, advisory) == ([], []), (
            f"{plat}/{role} is desktop-class but scope_violations says: {blocking + advisory}")


def test_scope_reject_reason_names_the_axis_that_actually_rejected():
    """The reason feeds the wizard's hidden-row text, so it must name the true axis."""
    cases = (
        # mesh pki on x86: node-class. The class axis is the only one that rejects, and it
        # names the real consequence (a node that can never join its mesh).
        ("mesh", "pki", "x86", "class"),
        # mesh rpi5-desktop: NOT rejected at all. This case previously expected "mode" — it
        # encoded this branch's own false positive. build-rpi5:1037 gates --standalone on
        # ROLE_CLIENT alone (no mode term) and :998 sets ROLE_CLIENT=true for the desktop arm
        # rpi5-desktop maps to, so the builder ACCEPTS it; ROLE_CHOICES documents this exact
        # combination ("compose with --standalone for FDE, no mesh"). Rejecting it invented a
        # constraint, refused dispatch on a documented build, and force-cleared the flag.
        ("mesh", "rpi5-desktop", "rpi5", None),
        ("mesh", "jetson-desktop", "jetson", "platform"),
        ("standalone", "laptop", "x86", None),
        ("standalone", "orangepizero2", "orangepizero2", None),
        # the Zero 2's H618 sibling is the SAME node-class-but-standalone appliance
        # (_APPLIANCE_ROLES carries both), so the same "never rejected" pin applies.
        ("standalone", "orangepizero2w", "orangepizero2w", None),
        # the Zero 2's H618 sibling is the SAME node-class-but-standalone appliance
        # (_APPLIANCE_ROLES carries both), so the same "never rejected" pin applies.
        ("standalone", "orangepizero3", "orangepizero3", None),
        ("standalone", "orangepi3-lts", "orangepi3-lts", None),
    )
    for mode, role, plat, want in cases:
        cfg = ImageConfig(mode=mode, role=role, platform=plat)
        assert scope_reject_reason("standalone", cfg) == want, (
            f"{mode}/{role}/{plat}: expected reason {want}, "
            f"got {scope_reject_reason('standalone', cfg)}")


def test_x86_and_rpi5_node_tiers_are_unchanged_by_the_class_platforms_split():
    """The narrowing must still BITE where the builder does gate: the split is a
    correction, not a retreat. x86 warns (builder accepts, builds wrong); rpi5 blocks
    (builder errs at :1037)."""
    x86 = ImageConfig(mode="mesh", role="pki", platform="x86", standalone=True)
    assert not field_in_scope("standalone", x86)
    blocking, advisory = scope_violations(x86)
    assert not blocking and any("NEVER join" in a for a in advisory)

    rpi5 = ImageConfig(mode="mesh", role="pki", platform="rpi5", standalone=True)
    assert not field_in_scope("standalone", rpi5)
    blocking, advisory = scope_violations(rpi5)
    assert any("hard-errors" in b for b in blocking) and not advisory

"""Device-catalog drift guards — pin the catalog to config.py's constants AND to the
six builders' own role/board allowlists, in three directions:

1. catalog -> config.py: every selectable device's builder axes exist in the config
   tuples; role_allow only narrows; reasons are honest (non-empty where required).
2. config.py -> catalog (surjectivity): every config board/platform is claimed by a
   selectable device — adding rpi6 to RPI_BOARDS (or a new platform) without a catalog
   entry fails, and deleting a config board the catalog still claims fails via 1.
3. catalog -> builder scripts: parse each build-*-stage4.sh's OWN "--board/--role must
   be one of" error strings (the check.sh code-copy-assertion idiom) and assert
   set-equality with the config tuples / mapped studio role ids; assert the rpi3
   desktop-only hard-error guard is still present and mirrored by buildable().

Pure-core: no Qt import — runs in the headless suite.
"""
from __future__ import annotations

import os
import re

import pytest

from hugmesh_studio.core import device_catalog as dc
from hugmesh_studio.core import roles as roles_lib
from hugmesh_studio.core.config import (
    BUILDER_SCRIPTS, FRITE_BOARDS, JETSON_BOARDS, JETSON_ROLE_MAP, ORANGEPI5_BOARDS,
    ROLE_CHOICES, RPI5_ROLE_MAP, RPI_BOARDS, RPI_NODE_BOARDS,
)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

CAT = dc.load_catalog()

# platform -> the config board tuple ("" marks the no-board-axis platforms).
CONFIG_BOARDS = {
    "x86": ("",),
    "rpi5": RPI_BOARDS,
    "frite": FRITE_BOARDS,
    "jetson": JETSON_BOARDS,
    "orangepi5": ORANGEPI5_BOARDS,
    "orangepizero2": ("",),
    "orangepizero2w": ("",),
    "orangepizero3": ("",),
    "orangepi3-lts": ("",),
    "orangepi4-lts": ("",),
}


def _builder_text(platform: str) -> str:
    with open(os.path.join(GENERATOR_DIR, BUILDER_SCRIPTS[platform]), encoding="utf-8") as fh:
        return fh.read()


def _allowlist(text: str, flag: str) -> set[str]:
    """Parse a builder's own '--<flag> must be one of: a | b | c (got ...)' error string
    into the token set — parenthetical asides ('(default)', '(host = ... alias)',
    '(client devices)') are dropped; both '|'- and space-separated lists are handled."""
    m = re.search(rf'--{flag} must be one of: ([^"\n]+)', text)
    assert m, f"builder lost its '--{flag} must be one of' error line"
    body = re.sub(r"\(got[^)]*'?\)?.*$", "", m.group(1))
    body = re.sub(r"\([^)]*\)", " ", body)          # drop parenthetical asides
    toks = {t.strip() for part in body.split("|") for t in part.split()}
    return {t for t in toks if t and not t.startswith("(")}


# ── structural sanity ────────────────────────────────────────────────────────────

def test_ids_unique_and_references_resolve():
    ids = [d.id for d in CAT.devices]
    assert len(ids) == len(set(ids)), "duplicate device ids"
    fam_ids = {f.id for f in CAT.families}
    arch_ids = {a.id for a in CAT.archs}
    for d in CAT.devices:
        assert d.family in fam_ids, f"{d.id}: unknown family {d.family}"
        assert d.arch in arch_ids, f"{d.id}: unknown arch {d.arch}"
        assert d.status in dc.STATUSES, f"{d.id}: bad status {d.status}"
    for f in CAT.families:
        assert f.arch in arch_ids, f"family {f.id}: unknown arch"


def test_every_arch_and_family_has_a_device():
    for a in CAT.archs:
        assert CAT.devices_for_arch(a.id), f"arch {a.id} has no devices"
    for f in CAT.families:
        assert CAT.devices_in_family(f.id), f"family {f.id} has no devices"


# ── direction 1: catalog -> config.py ────────────────────────────────────────────

def test_selectable_devices_have_config_backed_builder_axes():
    for d in CAT.devices:
        if d.status == "unsupported":
            assert d.builder_platform is None, f"{d.id}: unsupported must carry no builder"
            continue
        assert d.builder_platform in BUILDER_SCRIPTS, f"{d.id}: unknown platform"
        boards = CONFIG_BOARDS[d.builder_platform]
        assert d.builder_board in boards, \
            f"{d.id}: board {d.builder_board!r} not in config's {d.builder_platform} boards"


def test_boardless_platform_devices_have_empty_board():
    for d in CAT.devices:
        if d.builder_platform in dc.BOARDLESS_PLATFORMS:
            assert d.builder_board == "", f"{d.id}: {d.builder_platform} has no --board axis"


def test_role_allow_only_narrows_the_derivation():
    for d in CAT.devices:
        if d.role_allow is None:
            continue
        for mode in ROLE_CHOICES:
            derived = {r for r, _ in dc.roles_for(d.id, mode)}
            assert derived <= set(d.role_allow), \
                f"{d.id}: roles_for leaked outside role_allow in {mode}"
        # every allowlisted role must be a real ROLE_CHOICES id somewhere (no invention)
        all_roles = {r for m in ROLE_CHOICES for r, _p, _l in ROLE_CHOICES[m]}
        assert set(d.role_allow) <= all_roles, f"{d.id}: role_allow invents roles"


def test_every_selectable_device_derives_at_least_one_role():
    for d in CAT.devices:
        if d.status == "unsupported":
            assert dc.roles_for(d.id, "mesh") == () and dc.roles_for(d.id, "cloud") == ()
            continue
        assert any(dc.roles_for(d.id, m) for m in ROLE_CHOICES), \
            f"{d.id}: selectable but derives zero roles in every mode"


def test_non_supported_entries_carry_an_honest_reason():
    for d in CAT.devices:
        if d.status != "supported":
            assert d.reason.strip(), f"{d.id}: {d.status} entry with empty reason"
        assert dc.status_reason(d.id) == "" or d.status != "supported"


def test_experimental_reason_carries_the_fail_loud_caveat():
    for d in CAT.devices:
        if d.status == "experimental":
            assert "fail-loud" in dc.status_reason(d.id) or "fail-loud" in d.reason, \
                f"{d.id}: experimental without the fail-loud-preflight caveat"


# ── direction 2: config.py -> catalog (surjectivity) ─────────────────────────────

def test_every_config_platform_and_board_is_claimed_by_a_selectable_device():
    claimed = {(d.builder_platform, d.builder_board)
               for d in CAT.devices if d.status != "unsupported"}
    for platform in BUILDER_SCRIPTS:
        assert any(p == platform for p, _b in claimed), \
            f"platform {platform} has no catalog device — add one (honesty: every " \
            f"builder-real target must be visible)"
        for board in CONFIG_BOARDS[platform]:
            assert (platform, board) in claimed, \
                f"config board ({platform}, {board!r}) unclaimed by any selectable " \
                f"catalog device — a new config board needs a catalog entry"


# ── direction 3: catalog -> the builders' own allowlists ─────────────────────────

# ── the ROLE allowlist moved OUT of the builders ─────────────────────────────────
# Each builder used to carry its own `--role must be one of: ...` string, and this
# guard parsed it. Role validation now happens ONCE, in scripts/_roles-lib.sh, which
# every builder sources — so the reference is that declaration, read through
# core/roles.py. The role half of these three tests therefore compares the STUDIO's
# per-platform role set against the SHELL's, which is the drift that actually
# mattered; the shell-side "does every builder really source and call it" half is
# tests/scripts/test-role-key-spelling.sh's job (it can see all ten builders, which a
# Studio-side test cannot).

def test_rpi5_builder_board_and_role_allowlists_match():
    text = _builder_text("rpi5")
    assert _allowlist(text, "board") == set(RPI_BOARDS)
    studio_rpi5_roles = {r for m in ROLE_CHOICES for r, plats, _l in ROLE_CHOICES[m]
                         if "rpi5" in plats}
    mapped = {RPI5_ROLE_MAP.get(r, r) for r in studio_rpi5_roles}
    assert set(roles_lib.roles_for_platform("rpi5")) >= mapped, \
        "the Studio offers an rpi5 role scripts/_roles-lib.sh does not declare"
    assert 'hugmesh_role_validate "${ROLE}" rpi5' in text, \
        "build-rpi5-stage4.sh no longer validates --role through the shared vocabulary"


def test_rpi3_desktop_only_hard_error_guard_is_present_and_mirrored():
    text = _builder_text("rpi5")
    assert re.search(r'"\$\{BOARD\}" = "rpi3"[^\n]*&&[^\n]*ROLE_CLIENT', text), \
        "build-rpi5-stage4.sh lost the rpi3 desktop-only hard-error guard"
    # the catalog mirrors it: rpi3 is buildable for exactly the desktop-class rpi5
    # roles, never a node-class one, in every mode.
    for mode, choices in ROLE_CHOICES.items():
        for role, plats, _l in choices:
            if "rpi5" not in plats:
                continue
            expect = "rpi3" in dc.load_catalog().device("rpi3").builder_board \
                and role in {r for r, _ in dc.roles_for("rpi3", mode)}
            assert dc.buildable("rpi3", mode, role) == expect
    assert {r for r, _ in dc.roles_for("rpi3", "mesh")} == {"rpi5-desktop"}
    assert dc.roles_for("rpi3", "standalone") == ()
    assert "rpi3" not in RPI_NODE_BOARDS


def test_jetson_builder_board_and_role_allowlists_match():
    text = _builder_text("jetson")
    assert _allowlist(text, "board") == set(JETSON_BOARDS)
    studio_jetson_roles = {r for m in ROLE_CHOICES for r, plats, _l in ROLE_CHOICES[m]
                           if "jetson" in plats}
    mapped = {JETSON_ROLE_MAP.get(r, r) for r in studio_jetson_roles}
    assert set(roles_lib.roles_for_platform("jetson")) == mapped, \
        "the Studio jetson role set and HUGMESH_ROLES_JETSON disagree"
    assert 'hugmesh_role_validate "${ROLE}" jetson' in text, \
        "build-jetson-stage4.sh no longer validates --role through the shared vocabulary"


def test_x86_builder_role_allowlist_matches_modulo_documented_aliases():
    text = _builder_text("x86")
    studio_x86_roles = {r for m in ROLE_CHOICES for r, plats, _l in ROLE_CHOICES[m]
                        if "x86" in plats}
    assert set(roles_lib.roles_for_platform("x86")) == studio_x86_roles, \
        "x86 builder/studio role drift: "\
        f"lib-only={set(roles_lib.roles_for_platform('x86')) - studio_x86_roles} "\
        f"studio-only={studio_x86_roles - set(roles_lib.roles_for_platform('x86'))}"
    assert 'hugmesh_role_validate "${ROLE}" x86' in text, \
        "build-x86-host-stage4.sh no longer validates --role through the shared vocabulary"
    # The two documented ALIAS arms are no longer arms — `host` and `standalone-full`
    # fold in scripts/_roles-lib.sh, before the case block ever runs. Assert they are
    # still ACCEPTED (that is the promise the operator was given), from the one place
    # that now decides it.
    al = roles_lib.aliases()
    assert al.get("host") == "backend-gpu", "the legacy `host` alias was dropped"
    assert al.get("be+gpu") == "backend-gpu", "the `be+gpu` alias was dropped"
    assert al.get("be") == "backend" and al.get("fe") == "frontend", \
        "the short be/fe spellings were dropped — every documented CLI must keep taking them"
    assert al.get("standalone-full") == "standalone-thick", \
        "the standalone-full alias was dropped"


def test_frite_and_opi5_board_allowlists_match_and_single_role_platforms_have_no_role_allowlist():
    frite = _builder_text("frite")
    opi5 = _builder_text("orangepi5")
    opz2 = _builder_text("orangepizero2")
    opz2w = _builder_text("orangepizero2w")
    opz2w = _builder_text("orangepizero3")
    assert _allowlist(frite, "board") == set(FRITE_BOARDS)
    assert _allowlist(opi5, "board") == set(ORANGEPI5_BOARDS)
    # single-role platforms: --role is only a hostname marker, so the builders carry
    # NO '--role must be one of' allowlist — matching the catalog's single-role
    # derivation (and no --board line at all in the zero2 builder).
    for name, text in (("frite", frite), ("orangepi5", opi5), ("orangepizero2", opz2),
                       ("orangepizero2w", opz2w)):
        assert "--role must be one of" not in text, \
            f"build-{name} grew a --role allowlist — update the catalog derivation"
    assert "--board must be one of" not in opz2, \
        "build-orangepi-zero2 grew a --board axis — update the catalog"
    assert "--board must be one of" not in opz2w, \
        "build-orangepi-zero2w grew a --board axis — update the catalog"
    assert "--board must be one of" not in opz2w, \
        "build-orangepi-zero3 grew a --board axis — update the catalog"


# ── the buildable() honesty predicate, catalog-wide ───────────────────────────────

def test_unsupported_devices_are_never_buildable_and_raise_on_axes():
    for d in CAT.devices:
        if d.status != "unsupported":
            continue
        assert not dc.selectable(d.id)
        for mode in ROLE_CHOICES:
            for role, _p, _l in ROLE_CHOICES[mode]:
                assert not dc.buildable(d.id, mode, role), (d.id, mode, role)
        with pytest.raises(ValueError):
            dc.config_axes(d.id)


def test_buildable_iff_config_accepts_the_axes():
    """buildable(dev, mode, role) IFF the config/builder grammar accepts the device's
    (platform, board) for that role — the exact ROLE_CHOICES + rpi_boards_for_role
    predicate every emission channel consumes."""
    from hugmesh_studio.core.config import rpi_boards_for_role
    for d in CAT.devices:
        if d.status == "unsupported":
            continue
        for mode, choices in ROLE_CHOICES.items():
            offered = {r for r, _ in dc.roles_for(d.id, mode)}
            for role, plats, _l in choices:
                accepts = (d.builder_platform in plats
                           and (d.builder_platform != "rpi5"
                                or d.builder_board in rpi_boards_for_role(role))
                           and (d.role_allow is None or role in d.role_allow))
                assert (role in offered) == accepts, (d.id, mode, role)
                assert dc.buildable(d.id, mode, role) == accepts, (d.id, mode, role)


def test_catalog_covers_the_named_families_and_verdicts():
    """The #351 verdicts stay visible: the named-but-unbuildable families exist with
    honest statuses, and at least one experimental + one unsupported device exist
    (real-cases check — the badge machinery discriminates)."""
    by_status = {s: [d.id for d in CAT.devices if d.status == s] for s in dc.STATUSES}
    assert by_status["experimental"] and by_status["unsupported"]
    expect_unsupported = {"rpi2", "rpi6", "opi2", "opi3", "opi4", "opi6",
                          "bpi-m5", "bpi-f3", "rock-5b", "nanopc-t6",
                          "rk3588-generic", "lc-renegade"}
    assert expect_unsupported <= set(by_status["unsupported"])
    expect_supported = {"x86-pc", "x86-laptop", "chromebook", "rpi5", "rpi4", "rpi3",
                        "la-frite", "le-potato", "sweet-potato"}
    assert expect_supported <= set(by_status["supported"])
    expect_experimental = {"orin-nano", "orin-nano-4gb", "orin-nx-8gb", "orin-nx-16gb",
                           "orange-pi-5", "orange-pi-5-plus", "orange-pi-zero2"}
    assert expect_experimental <= set(by_status["experimental"])

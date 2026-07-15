"""Worklist envelope + materialize() — the model half (core/worklist.py).

Pure-core: no Qt, no display. Pins the wire format (round-trip / legacy-wrap /
loud-reject / secret-blanking) and the deterministic materialize() pipeline
(id stability, table-order domain filtering + primary ordering, jetson encrypt-root
exemption, desktop-field clearing, mesh tailnet forcing, build_subdir, GUI-channel
parity). These are the invariants both UIs and the web job channel project onto.
"""
import json
import os

import pytest

from snapdragon_studio.core.config import (
    PLATFORM_DEFAULT_ROLE,
    Domain,
    ImageConfig,
    User,
    resolve_platform_defaults,
    roles_for_platform,
)
from snapdragon_studio.core.worklist import (
    WORKLIST_SCHEMA,
    WorklistConfig,
    WorklistEntry,
    entry_id,
    load_any,
    synthesize,
)


# ---- entry identity -----------------------------------------------------------

def test_entry_id_derived_from_role_platform():
    e = WorklistEntry(role="omnibus", platform="x86")
    assert e.id == "omnibus.x86" == entry_id("omnibus", "x86")


def test_entry_id_stable_across_board_edit():
    """board/flavor are ATTRIBUTES — editing them must never re-key the entry (the
    dangling-ref hazard the synthesis fixed)."""
    a = WorklistEntry(role="be", platform="rpi5", board="rpi5")
    b = WorklistEntry(role="be", platform="rpi5", board="rpi4")
    assert a.id == b.id == "be.rpi5"


def test_entry_explicit_id_honored():
    e = WorklistEntry(role="be", platform="rpi5", id="legacy.id")
    assert e.id == "legacy.id"


def test_entry_build_subdir_derived():
    e = WorklistEntry(role="edge_ai", platform="jetson")
    assert e.build_subdir == "wl-edge_ai.jetson"


# ---- wire format: round-trip / legacy-wrap / loud-reject / secrets -------------

def _envelope():
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                       brand_title="Acme", org="Acme-Inc", cluster_domain="acme.example",
                       superdomain="core.acme.internal")
    base.domains = [Domain(name="acme.example", title="Acme"),
                    Domain(name="team.acme.example", title="Team", images=["be.rpi5"])]
    base.users = [User(username="root-admin", domain="core.acme.internal", role="superadmin")]
    entries = [WorklistEntry(role="omnibus", platform="x86"),
               WorklistEntry(role="be", platform="rpi5", board="rpi5",
                             packages_add="app-misc/tmux"),
               WorklistEntry(role="edge_ai", platform="jetson", encrypt_root="on")]
    return WorklistConfig(base=base, entries=entries)


def test_envelope_round_trips_exact():
    wl = _envelope()
    d = wl.to_dict()
    assert d["schema"] == WORKLIST_SCHEMA
    wl2 = WorklistConfig.from_dict(d)
    assert wl2.to_dict() == d
    assert [e.id for e in wl2.entries] == ["omnibus.x86", "be.rpi5", "edge_ai.jetson"]
    assert wl2.base.superdomain == "core.acme.internal"
    assert wl2.entries[1].packages_add == "app-misc/tmux"


def test_load_any_envelope(tmp_path):
    wl = _envelope()
    p = tmp_path / "wl.json"
    wl.save(str(p))
    base, loaded = load_any(str(p))
    assert loaded is not None
    assert loaded.schema == WORKLIST_SCHEMA
    assert base.brand == "acme"
    assert [e.id for e in loaded.entries] == ["omnibus.x86", "be.rpi5", "edge_ai.jetson"]


def test_load_any_flat_config_unchanged(tmp_path):
    """A flat single-image config (no `schema` key) loads byte-identically to
    ImageConfig.from_dict, with no worklist — the 118 matrix configs / user saves."""
    cfg = ImageConfig(mode="cloud", role="laptop", platform="x86", brand="acme")
    p = tmp_path / "flat.json"
    cfg.save(str(p))
    base, loaded = load_any(str(p))
    assert loaded is None
    assert base.to_dict() == ImageConfig.load(str(p)).to_dict()


def test_imageconfig_load_rejects_envelope_loudly(tmp_path):
    """The load guard: ImageConfig.load must fail LOUDLY on an envelope (explicit
    `schema` key), never silently degrade to a default config."""
    p = tmp_path / "env.json"
    p.write_text(json.dumps(_envelope().to_dict()), encoding="utf-8")
    with pytest.raises(ValueError, match="worklist envelope"):
        ImageConfig.load(str(p))


def test_from_dict_rejects_duplicate_entry_ids():
    """A foreign/hand-authored envelope with two entries that differ only in
    board/flavor collides on id (role.platform) — from_dict must reject it LOUDLY,
    not let a later consumer silently drop or clobber one image."""
    d = {
        "schema": WORKLIST_SCHEMA,
        "base": {"mode": "mesh", "brand": "acme"},
        "entries": [
            {"role": "frite", "platform": "frite", "board": "la-frite", "flavor": "live"},
            {"role": "frite", "platform": "frite", "board": "le-potato", "flavor": "installer"},
        ],
    }
    with pytest.raises(ValueError, match=r"share id 'frite\.frite'"):
        WorklistConfig.from_dict(d)


def test_materialize_rejects_duplicate_entry_ids():
    """The universal build chokepoint guards even a programmatically-built worklist
    (the GUI never routes through from_dict), so a duplicate id can never reach the
    driver and clobber a build tree / node-keys dir."""
    base = ImageConfig(mode="mesh", brand="acme")
    wl = WorklistConfig(base=base, entries=[
        WorklistEntry(role="edge_ai", platform="jetson", board="agx"),
        WorklistEntry(role="edge_ai", platform="jetson", board="orin"),
    ])
    with pytest.raises(ValueError, match=r"share id 'edge_ai\.jetson'"):
        wl.materialize()


def test_unique_entry_ids_load_and_materialize_ok():
    """The guard must NOT reject a valid worklist whose entries are all distinct
    role×platform pairs (the shape every real GUI/synthesize flow produces)."""
    wl = _envelope()  # omnibus.x86 / be.rpi5 / edge_ai.jetson — all distinct
    WorklistConfig.from_dict(wl.to_dict())  # no raise
    assert len(wl.materialize()) == 3


def test_save_blanks_base_secrets_and_aggregates_warnings(tmp_path):
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86",
                       local_pass="pw", luks_pass="pw2",
                       user_password="pw3", root_password="pw4")
    wl = WorklistConfig(base=base, entries=[WorklistEntry(role="omnibus", platform="x86")])
    p = tmp_path / "secret.json"
    warnings = wl.save(str(p))
    data = json.loads(p.read_text(encoding="utf-8"))
    for k in ("local_pass", "luks_pass", "user_password", "root_password"):
        assert data["base"][k] == ""
    assert len(warnings) == 4
    assert all("NOT saved" in w for w in warnings)
    assert any("luks-pass" in w for w in warnings)


# ---- materialize(): the deterministic pipeline --------------------------------

def test_materialize_order_matches_entries():
    wl = _envelope()
    out = wl.materialize()
    assert [e.id for e, _ in out] == ["omnibus.x86", "be.rpi5", "edge_ai.jetson"]


def test_materialize_sets_structural_axes_and_build_subdir():
    wl = _envelope()
    out = dict((e.id, cfg) for e, cfg in wl.materialize())
    be = out["be.rpi5"]
    assert be.role == "be" and be.platform == "rpi5" and be.board == "rpi5"
    assert be.build_subdir == "wl-be.rpi5"


def test_materialize_jetson_encrypt_root_forced_off():
    """A jetson entry is forced off even with encrypt_root='on' (builder hard-block)."""
    wl = WorklistConfig(base=ImageConfig(mode="mesh", encrypt_root=True),
                        entries=[WorklistEntry(role="edge_ai", platform="jetson",
                                               encrypt_root="on")])
    _e, cfg = wl.materialize()[0]
    assert cfg.encrypt_root is False


def test_materialize_encrypt_root_default_inherits_base():
    base = ImageConfig(mode="mesh", encrypt_root=True)
    wl = WorklistConfig(base=base, entries=[
        WorklistEntry(role="be", platform="rpi5", encrypt_root="default"),
        WorklistEntry(role="fe", platform="rpi5", encrypt_root="off"),
        WorklistEntry(role="pki", platform="rpi5", encrypt_root="on"),
    ])
    out = dict((e.id, cfg.encrypt_root) for e, cfg in wl.materialize())
    assert out["be.rpi5"] is True     # inherits base default
    assert out["fe.rpi5"] is False    # explicit off
    assert out["pki.rpi5"] is True    # explicit on


def test_materialize_clears_desktop_fields_for_node():
    """A cluster node (omnibus) must never carry stale theming/home-provisioning values
    that a desktop base config picked up (belt & braces I4)."""
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86",
                       theme="boogiepop", wallpaper="/x.png", home_mode="adopt")
    wl = WorklistConfig(base=base, entries=[WorklistEntry(role="omnibus", platform="x86")])
    _e, cfg = wl.materialize()[0]
    assert cfg.theme == "" and cfg.wallpaper == ""
    assert cfg.home_mode == "create"   # dataclass default


def test_materialize_mesh_forces_tailnet():
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86",
                       tailscale=False, sso=False)
    wl = WorklistConfig(base=base, entries=[WorklistEntry(role="omnibus", platform="x86")])
    _e, cfg = wl.materialize()[0]
    assert cfg.tailscale is True and cfg.sso is True


def test_materialize_domain_filter_table_order_primary_first():
    """cfg.domains is the attached subset, IN base table order (first = PRIMARY). x86
    keeps the domains field, so the filtered list survives strip_platform_unsupported."""
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86")
    base.domains = [
        Domain(name="primary.example", images=[]),                 # all images
        Domain(name="only-be.example", images=["be.rpi5"]),        # not this entry
        Domain(name="second.example", images=["omnibus.x86"]),     # this entry
    ]
    wl = WorklistConfig(base=base, entries=[WorklistEntry(role="omnibus", platform="x86")])
    _e, cfg = wl.materialize()[0]
    assert [d.name for d in cfg.domains] == ["primary.example", "second.example"]


def test_materialize_domain_stripped_for_arm():
    """--domains is x86-only in emission — strip_platform_unsupported blanks cfg.domains
    on ARM. The table-order filter (step 2) still runs BEFORE the strip (step 5), so the
    ordering concern is honored even though ARM ends up with no domains."""
    base = ImageConfig(mode="mesh", role="be", platform="rpi5")
    base.domains = [Domain(name="a.example", images=[]),
                    Domain(name="b.example", images=["be.rpi5"])]
    wl = WorklistConfig(base=base, entries=[WorklistEntry(role="be", platform="rpi5")])
    _e, cfg = wl.materialize()[0]
    assert cfg.domains == []


def test_materialize_carries_users_whole():
    wl = _envelope()
    out = dict((e.id, cfg) for e, cfg in wl.materialize())
    for cfg in out.values():
        assert [u.username for u in cfg.users] == ["root-admin"]


def test_materialize_applies_package_deltas():
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86")
    wl = WorklistConfig(base=base, entries=[
        WorklistEntry(role="omnibus", platform="x86",
                      packages_add="app-editors/vim", packages_drop="games-util/steam")])
    _e, cfg = wl.materialize()[0]
    assert cfg.packages_add == "app-editors/vim"
    assert cfg.packages_drop == "games-util/steam"


def test_materialize_output_is_valid_cli():
    """Every materialized config is a plain, fully-valid ImageConfig — to_cli_args runs
    and the per-entry build_subdir + role reach the argv."""
    wl = _envelope()
    for entry, cfg in wl.materialize():
        args = cfg.to_cli_args()
        assert "--build-subdir" in args
        assert args[args.index("--build-subdir") + 1] == entry.build_subdir


def test_materialize_bad_atom_fails_closed():
    """validate_identity (step 6) fails closed on a shell-unsafe package atom."""
    wl = WorklistConfig(base=ImageConfig(mode="mesh", role="omnibus", platform="x86"),
                        entries=[WorklistEntry(role="omnibus", platform="x86",
                                               packages_add="evil; rm -rf /")])
    with pytest.raises(ValueError):
        wl.materialize()


# ---- GUI-channel parity + single-image synthesize -----------------------------

def test_materialize_matches_hand_built_flat_config():
    """The redesign's core parity claim: a materialized mesh entry's argv equals the
    argv of the flat single-image config a user would build by hand for that image."""
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                       brand_title="Acme", org="Acme-Inc", cluster_domain="acme.example")
    wl = WorklistConfig(base=base, entries=[WorklistEntry(role="omnibus", platform="x86")])
    _e, materialized = wl.materialize()[0]

    flat = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                       brand_title="Acme", org="Acme-Inc", cluster_domain="acme.example",
                       tailscale=True, sso=True, build_subdir="wl-omnibus.x86")
    assert materialized.to_cli_args() == flat.to_cli_args()


def test_synthesize_single_image_round_trips_argv():
    """A standalone/cloud config wrapped as a 1-entry worklist materializes back to the
    same argv (plus the collision-guard build_subdir the driver always sets)."""
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      brand="acme", cluster_domain="acme.example")
    wl = synthesize(cfg)
    assert len(wl.entries) == 1 and wl.entries[0].id == "standalone-thick.x86"
    _e, materialized = wl.materialize()[0]

    expect = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                         brand="acme", cluster_domain="acme.example",
                         build_subdir="wl-standalone-thick.x86")
    assert materialized.to_cli_args() == expect.to_cli_args()


# ---- wire-format schema conformance (the frozen contract both UIs / the BFF share) --

_SCHEMA_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "docs", "schemas", "worklist.v1.schema.json")


def test_schema_file_parses_and_pins_v1():
    schema = json.load(open(_SCHEMA_PATH, encoding="utf-8"))
    assert schema["properties"]["schema"]["const"] == WORKLIST_SCHEMA


def test_envelope_conforms_to_frozen_schema():
    """A real serialized envelope validates against the checked-in JSON-Schema, and the
    mandatory `schema` discriminator / entry `platform` enum are enforced — the same
    contract the admin-bff bean validator will apply (spec item 10)."""
    jsonschema = pytest.importorskip("jsonschema")
    schema = json.load(open(_SCHEMA_PATH, encoding="utf-8"))
    jsonschema.validate(_envelope().to_dict(), schema)

    missing_disc = _envelope().to_dict()
    missing_disc.pop("schema")
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(missing_disc, schema)

    bad_platform = _envelope().to_dict()
    bad_platform["entries"][0]["platform"] = "sparc"
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(bad_platform, schema)


# ---- platform-aware default resolution (gaps G2/G3; source-side of worker PR #334) ----
# An entry that leaves role UNSET (or a synthesized flat config carrying the x86
# dataclass default role) materialized an off-platform role -> `--role ''` /
# `--role standalone-thick`, and an unset flavor on the ARM ISO platforms materialized
# to `--flavor both` (two artifacts). resolve_platform_defaults() (run in
# _materialize_one) fixes both at the SOURCE so the worker's spec channel gets a
# builder-valid command; already-valid inputs stay byte-identical.

@pytest.mark.parametrize("platform,expect_role", [
    ("jetson", "edge_ai"),   # build-jetson-stage4.sh:84 ROLE="edge_ai" (DEFAULT)
    ("rpi5", "generic"),     # build-rpi5-stage4.sh:99 ROLE="generic"
    ("frite", "frite"),      # ROLE_CHOICES role-id == platform name (no --role emitted)
    ("orangepi5", "orangepi5"),
    ("orangepizero2", "orangepizero2"),
])
def test_materialize_unset_role_resolves_to_platform_default(platform, expect_role):
    """An UNSET entry.role on a non-x86 platform resolves to that platform's canonical
    default role instead of materializing the empty string / x86 client default."""
    wl = WorklistConfig(base=ImageConfig(mode="mesh", role="omnibus", platform="x86"),
                        entries=[WorklistEntry(role="", platform=platform)])
    _e, cfg = wl.materialize()[0]
    assert cfg.role == expect_role


@pytest.mark.parametrize("platform,expect_role", [
    ("jetson", "edge_ai"),
    ("rpi5", "generic"),
])
def test_materialize_x86_default_role_leak_resolved_for_role_platforms(platform, expect_role):
    """A flat config that leaves role at the x86 dataclass default ('standalone-thick')
    and is then targeted at a --role platform (jetson/rpi5) resolves to that platform's
    default rather than emitting the invalid x86 client role."""
    # synthesize() copies cfg.role onto the entry, reproducing the flat-config leak.
    cfg = ImageConfig(platform=platform)          # role defaults to standalone-thick
    assert cfg.role == "standalone-thick"
    wl = synthesize(cfg)
    _e, materialized = wl.materialize()[0]
    assert materialized.role == expect_role
    assert "--role" in materialized.to_cli_args()
    assert materialized.to_cli_args()[materialized.to_cli_args().index("--role") + 1] == expect_role


@pytest.mark.parametrize("platform", ["frite", "orangepi5", "orangepizero2"])
def test_materialize_unset_flavor_defaults_to_installer(platform):
    """An unset flavor on the ARM ISO platforms materializes to the single-artifact
    'installer' (not to_cli_args's two-artifact 'both'), so the worker's one-imageRef
    ingest contract holds."""
    wl = WorklistConfig(base=ImageConfig(mode="standalone"),
                        entries=[WorklistEntry(role="", platform=platform, flavor="")])
    _e, cfg = wl.materialize()[0]
    assert cfg.flavor == "installer"
    assert "--flavor" in cfg.to_cli_args()
    assert cfg.to_cli_args()[cfg.to_cli_args().index("--flavor") + 1] == "installer"


@pytest.mark.parametrize("platform", ["frite", "orangepi5", "orangepizero2"])
def test_materialize_explicit_flavor_is_honored(platform):
    """An explicitly-set flavor is never overridden by the installer default."""
    wl = WorklistConfig(base=ImageConfig(mode="standalone"),
                        entries=[WorklistEntry(role="", platform=platform, flavor="live")])
    _e, cfg = wl.materialize()[0]
    assert cfg.flavor == "live"


def test_materialize_explicit_wrong_role_left_for_builder_hard_error():
    """An EXPLICIT (non-default) wrong role is NOT silently corrected — it is left as-is
    so the builder's own hard-error fails loud rather than the Studio guessing intent."""
    wl = WorklistConfig(base=ImageConfig(mode="cloud"),
                        entries=[WorklistEntry(role="laptop", platform="jetson")])
    _e, cfg = wl.materialize()[0]
    assert cfg.role == "laptop"          # untouched (not in the unset/x86-default set)


def test_materialize_x86_role_flavor_byte_identical():
    """x86 is untouched: a valid x86 role stays byte-identical (standalone-thick is a
    valid x86 role, so the resolver is a no-op) and no flavor is injected."""
    wl = WorklistConfig(base=ImageConfig(mode="standalone", role="standalone-thick",
                                         platform="x86"),
                        entries=[WorklistEntry(role="standalone-thick", platform="x86")])
    _e, cfg = wl.materialize()[0]
    ref = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      build_subdir="wl-standalone-thick.x86")
    assert cfg.role == "standalone-thick" and cfg.flavor == ""
    assert cfg.to_cli_args() == ref.to_cli_args()


def test_materialize_valid_explicit_role_flavor_byte_identical():
    """A valid explicit role+flavor (frite installer) materializes byte-identically to a
    hand-built flat config — the resolver never perturbs an already-valid input."""
    wl = WorklistConfig(base=ImageConfig(mode="standalone", role="frite", platform="frite"),
                        entries=[WorklistEntry(role="frite", platform="frite",
                                               board="la-frite", flavor="installer")])
    _e, cfg = wl.materialize()[0]
    ref = ImageConfig(mode="standalone", role="frite", platform="frite",
                      board="la-frite", flavor="installer",
                      build_subdir="wl-frite.frite")
    assert cfg.to_cli_args() == ref.to_cli_args()


def test_resolve_platform_defaults_is_noop_for_valid_inputs():
    """The resolver mutates nothing for a config that already carries a valid role and
    (for ISO platforms) a flavor."""
    for cfg in (ImageConfig(role="edge_ai", platform="jetson"),
                ImageConfig(role="be", platform="rpi5"),
                ImageConfig(role="frite", platform="frite", flavor="live"),
                ImageConfig(role="standalone-thick", platform="x86")):
        before = (cfg.role, cfg.flavor)
        resolve_platform_defaults(cfg)
        assert (cfg.role, cfg.flavor) == before


def test_platform_default_role_map_grounded_in_catalog():
    """DRIFT GUARD: every PLATFORM_DEFAULT_ROLE value must be a role the ROLE_CHOICES
    catalog actually declares for that platform (so the map can never name a role the
    builder would reject). Pins the two builder-default-backed values explicitly."""
    for platform, role in PLATFORM_DEFAULT_ROLE.items():
        assert role in roles_for_platform(platform), \
            f"{platform} default role {role!r} not in roles_for_platform({platform})"
    assert PLATFORM_DEFAULT_ROLE["rpi5"] == "generic"     # build-rpi5-stage4.sh:99
    assert PLATFORM_DEFAULT_ROLE["jetson"] == "edge_ai"   # build-jetson-stage4.sh:84


def test_roles_for_platform_inversion():
    """roles_for_platform inverts ROLE_CHOICES exactly (guards a catalog edit that would
    silently drop a role from a platform's accepted set)."""
    assert roles_for_platform("frite") == frozenset({"frite"})
    assert roles_for_platform("orangepi5") == frozenset({"orangepi5"})
    assert roles_for_platform("orangepizero2") == frozenset({"orangepizero2"})
    assert roles_for_platform("rpi5") == frozenset({"generic", "rpi5-desktop", "pki", "be", "fe"})
    assert roles_for_platform("jetson") == frozenset({"edge_ai", "full", "gpu-host", "jetson-desktop"})
    assert "standalone-thick" in roles_for_platform("x86")
    assert roles_for_platform("") == roles_for_platform("x86")   # "" defaults to x86

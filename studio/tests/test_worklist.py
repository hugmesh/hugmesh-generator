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

from snapdragon_studio.core.config import Domain, ImageConfig, User
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

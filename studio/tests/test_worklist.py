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

from hugmesh_studio.core.config import (
    PLATFORM_DEFAULT_ROLE,
    Domain,
    ImageConfig,
    User,
    effective_installer_ui,
    resolve_installer_ui_default,
    resolve_platform_defaults,
    roles_for_platform,
)
from hugmesh_studio.core.worklist import (
    WORKLIST_SCHEMA,
    WorklistConfig,
    WorklistEntry,
    derived_hostname,
    duplicate_hostnames,
    entry_id,
    load_any,
    resolve_hostname,
    synthesize,
)


# ---- entry identity -----------------------------------------------------------

def test_entry_id_derived_from_role_platform():
    e = WorklistEntry(role="omnibus", platform="x86")
    assert e.id == "omnibus.x86" == entry_id("omnibus", "x86")


def test_entry_id_stable_across_board_edit():
    """board/flavor are ATTRIBUTES — editing them must never re-key the entry (the
    dangling-ref hazard the synthesis fixed)."""
    a = WorklistEntry(role="backend", platform="rpi5", board="rpi5")
    b = WorklistEntry(role="backend", platform="rpi5", board="rpi4")
    assert a.id == b.id == "backend.rpi5"


def test_entry_explicit_id_honored():
    e = WorklistEntry(role="backend", platform="rpi5", id="legacy.id")
    assert e.id == "legacy.id"


def test_entry_build_subdir_derived():
    e = WorklistEntry(role="edge-ai", platform="jetson")
    assert e.build_subdir == "wl-edge-ai.jetson"


# ---- wire format: round-trip / legacy-wrap / loud-reject / secrets -------------

def _envelope():
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                       brand_title="Acme", org="Acme-Inc", cluster_domain="acme.example",
                       superdomain="core.acme.internal")
    base.domains = [Domain(name="acme.example", title="Acme"),
                    Domain(name="team.acme.example", title="Team", images=["backend.rpi5"])]
    # multi-role (#228) so the frozen schema's `roles` clause is actually exercised
    base.users = [User(username="root-admin", domain="core.acme.internal",
                       roles=["superadmin", "games"])]
    entries = [WorklistEntry(role="omnibus", platform="x86"),
               WorklistEntry(role="backend", platform="rpi5", board="rpi5",
                             packages_add="app-misc/tmux", hostname="be-pi"),
               WorklistEntry(role="edge-ai", platform="jetson", encrypt_root="on")]
    return WorklistConfig(base=base, entries=entries)


def test_envelope_round_trips_exact():
    wl = _envelope()
    d = wl.to_dict()
    assert d["schema"] == WORKLIST_SCHEMA
    wl2 = WorklistConfig.from_dict(d)
    assert wl2.to_dict() == d
    assert [e.id for e in wl2.entries] == ["omnibus.x86", "backend.rpi5", "edge-ai.jetson"]
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
    assert [e.id for e in loaded.entries] == ["omnibus.x86", "backend.rpi5", "edge-ai.jetson"]


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
        WorklistEntry(role="edge-ai", platform="jetson", board="agx"),
        WorklistEntry(role="edge-ai", platform="jetson", board="orin"),
    ])
    with pytest.raises(ValueError, match=r"share id 'edge-ai\.jetson'"):
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
    assert [e.id for e, _ in out] == ["omnibus.x86", "backend.rpi5", "edge-ai.jetson"]


def test_materialize_sets_structural_axes_and_build_subdir():
    wl = _envelope()
    out = dict((e.id, cfg) for e, cfg in wl.materialize())
    be = out["backend.rpi5"]
    assert be.role == "backend" and be.platform == "rpi5" and be.board == "rpi5"
    assert be.build_subdir == "wl-backend.rpi5"


def test_materialize_jetson_encrypt_root_forced_off():
    """A jetson entry is forced off even with encrypt_root='on' (builder hard-block)."""
    wl = WorklistConfig(base=ImageConfig(mode="mesh", encrypt_root=True),
                        entries=[WorklistEntry(role="edge-ai", platform="jetson",
                                               encrypt_root="on")])
    _e, cfg = wl.materialize()[0]
    assert cfg.encrypt_root is False


def test_materialize_encrypt_root_default_inherits_base():
    base = ImageConfig(mode="mesh", encrypt_root=True)
    wl = WorklistConfig(base=base, entries=[
        WorklistEntry(role="backend", platform="rpi5", encrypt_root="default"),
        WorklistEntry(role="frontend", platform="rpi5", encrypt_root="off"),
        WorklistEntry(role="pki", platform="rpi5", encrypt_root="on"),
    ])
    out = dict((e.id, cfg.encrypt_root) for e, cfg in wl.materialize())
    assert out["backend.rpi5"] is True     # inherits base default
    assert out["frontend.rpi5"] is False    # explicit off
    assert out["pki.rpi5"] is True    # explicit on


def test_materialize_clears_desktop_fields_for_node():
    """A cluster node (omnibus) must never carry stale theming/home-provisioning values
    that a desktop base config picked up (belt & braces I4)."""
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86",
                       theme="dark", wallpaper="/x.png", home_mode="adopt")
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
        Domain(name="only-be.example", images=["backend.rpi5"]),        # not this entry
        Domain(name="second.example", images=["omnibus.x86"]),     # this entry
    ]
    wl = WorklistConfig(base=base, entries=[WorklistEntry(role="omnibus", platform="x86")])
    _e, cfg = wl.materialize()[0]
    assert [d.name for d in cfg.domains] == ["primary.example", "second.example"]


def test_materialize_domain_stripped_for_arm():
    """--domains is x86-only in emission — strip_platform_unsupported blanks cfg.domains
    on ARM. The table-order filter (step 2) still runs BEFORE the strip (step 5), so the
    ordering concern is honored even though ARM ends up with no domains."""
    base = ImageConfig(mode="mesh", role="backend", platform="rpi5")
    base.domains = [Domain(name="a.example", images=[]),
                    Domain(name="b.example", images=["backend.rpi5"])]
    wl = WorklistConfig(base=base, entries=[WorklistEntry(role="backend", platform="rpi5")])
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
    # The flat CHANNEL is app.py's --print-command, which resolves the platform AND the
    # role-class installer-UI default before emitting — mirror it here, exactly as this
    # test already mirrors the tailscale/sso forcing by hand. Without this the comparison
    # would pit a resolved materialize against a RAW dataclass and the parity claim would
    # be tested against something no channel actually emits (omnibus is a node, so the
    # real flat channel emits `--installer-ui cli` too — verified). This still bites if
    # the two call sites ever diverge, which is the invariant the test exists to protect.
    resolve_installer_ui_default(flat)
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
    ("jetson", "edge-ai"),   # build-jetson-stage4.sh:84 ROLE="edge-ai" (DEFAULT)
    ("rpi5", "generic"),     # build-rpi5-stage4.sh:99 ROLE="generic"
    ("frite", "frite"),      # ROLE_CHOICES role-id == platform name (no --role emitted)
    ("orangepi5", "orangepi5"),
    ("orangepizero2", "orangepizero2"),
    ("orangepizero2w", "orangepizero2w"),
    ("orangepizero3", "orangepizero3"),
    ("orangepi3-lts", "orangepi3-lts"),
])
def test_materialize_unset_role_resolves_to_platform_default(platform, expect_role):
    """An UNSET entry.role on a non-x86 platform resolves to that platform's canonical
    default role instead of materializing the empty string / x86 client default."""
    wl = WorklistConfig(base=ImageConfig(mode="mesh", role="omnibus", platform="x86"),
                        entries=[WorklistEntry(role="", platform=platform)])
    _e, cfg = wl.materialize()[0]
    assert cfg.role == expect_role


@pytest.mark.parametrize("platform,expect_role", [
    ("jetson", "edge-ai"),
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


@pytest.mark.parametrize("platform", ["frite", "orangepi5", "orangepizero2", "orangepizero2w"])
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


@pytest.mark.parametrize("platform", ["frite", "orangepi5", "orangepizero2", "orangepizero2w"])
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
    for cfg in (ImageConfig(role="edge-ai", platform="jetson"),
                ImageConfig(role="backend", platform="rpi5"),
                ImageConfig(role="frite", platform="frite", flavor="live"),
                ImageConfig(role="standalone-thick", platform="x86")):
        before = (cfg.role, cfg.flavor)
        resolve_platform_defaults(cfg)
        assert (cfg.role, cfg.flavor) == before


# ---- installer-UI role-class resolver (headless node -> cli) ---------------------
# The Studio's flat `installer_ui: str = "all"` default made to_cli_args ALWAYS pass an
# explicit value, so build-x86-host-stage4.sh:1327's `[ -z "${INSTALLER_UI}" ]` guard
# could never fire and every headless node inherited the standalone-only "all" — pulling
# an app-admin/calamares whose USE closure (package.use/desktop) the builder only copies
# for ROLE_CLIENT roles (:3676). That killed 5 x86 node images on boost[python] and 5
# more on libpwquality[python] (session 20260716-235722-54d2f7), ~16min each.

X86_NODE_ROLES_UNDER_TEST = ("pki", "backend", "frontend", "backend-gpu", "omnibus", "edge-ai")
# The two values that flip the builder's WANT_CALAMARES true (:1246).
CALAMARES_TRIGGERS = ("all", "calamares")


@pytest.mark.parametrize("role", X86_NODE_ROLES_UNDER_TEST)
@pytest.mark.parametrize("bad", CALAMARES_TRIGGERS)
def test_installer_ui_node_rewrites_calamares_triggers_to_cli(role, bad):
    """Every x86 node role x every WANT_CALAMARES-triggering value -> "cli" + a note.
    Covers the (2) decision: an EXPLICIT "calamares" is overridden, not honoured — on a
    node it is unsatisfiable, so honouring it buys a guaranteed ~16min failure."""
    cfg = ImageConfig(mode="mesh", role=role, platform="x86", installer_ui=bad)
    note = resolve_installer_ui_default(cfg)
    assert cfg.installer_ui == "cli"
    assert note and role in note        # the note names the offending role


@pytest.mark.parametrize("mode,role", [("cloud", "laptop"), ("cloud", "chromebook"),
                                       ("cloud", "desktop"), ("standalone", "standalone-thin"),
                                       ("standalone", "standalone-thick"),
                                       ("standalone", "standalone-unaffiliated")])
def test_installer_ui_desktop_class_untouched(mode, role):
    """Client + standalone are byte-identical: they legitimately want calamares and CAN
    build it (ROLE_CLIENT gets package.use/desktop). The rule is one-directional."""
    cfg = ImageConfig(mode=mode, role=role, platform="x86", installer_ui="all")
    assert resolve_installer_ui_default(cfg) is None
    assert cfg.installer_ui == "all"


@pytest.mark.parametrize("plat,role", [("rpi5", "pki"), ("rpi5", "backend"), ("jetson", "edge-ai")])
def test_installer_ui_non_x86_untouched(plat, role):
    """installer_ui is _X86-only (PLATFORM_FIELD_SUPPORT), matching the evidence that the
    rpi5/jetson entries of the failed session survived."""
    cfg = ImageConfig(mode="mesh", role=role, platform=plat, installer_ui="all")
    assert resolve_installer_ui_default(cfg) is None
    assert cfg.installer_ui == "all"


@pytest.mark.parametrize("mode,role,plat,stored", [
    ("mesh", "pki", "x86", "all"),          # rewritten
    ("mesh", "pki", "x86", "ncurses"),      # NOT rewritten — the GUI's old blind spot
    ("mesh", "pki", "rpi5", "all"),         # non-x86 no-op
    ("cloud", "laptop", "x86", "all"),      # desktop no-op
])
def test_effective_installer_ui_agrees_with_the_resolver_without_mutating(mode, role, plat, stored):
    """effective_installer_ui() is the read-only twin display surfaces ASK instead of
    RESTATING the rule (the GUI used to hard-code "a node shows cli" and so lied for a
    node carrying "ncurses"). Contract: it returns exactly what the resolver would leave
    behind, and it must NOT touch the caller's cfg — the GUI calls it on the LIVE
    wizard cfg on every page visit, so a mutation there would persist "cli" into a user's
    saved preference and silently strip a later desktop's graphical installer."""
    cfg = ImageConfig(mode=mode, role=role, platform=plat, installer_ui=stored)
    got = effective_installer_ui(cfg)
    assert cfg.installer_ui == stored           # the probe copy must be non-destructive
    twin = ImageConfig(mode=mode, role=role, platform=plat, installer_ui=stored)
    resolve_installer_ui_default(twin)          # what materialize really leaves behind
    assert got == twin.installer_ui             # ...and the report matches it exactly


@pytest.mark.parametrize("value", ["cli", "ncurses"])
def test_installer_ui_node_non_graphical_values_are_noops(value):
    """A node already asking for a NON-graphical front-end is left alone — neither value
    sets WANT_CALAMARES (:1246), and ncurses is a TUI that needs no Qt/KDE closure, so
    rewriting it would override a legitimate, satisfiable choice for no reason."""
    cfg = ImageConfig(mode="mesh", role="pki", platform="x86", installer_ui=value)
    assert resolve_installer_ui_default(cfg) is None
    assert cfg.installer_ui == value


def test_installer_ui_resolver_runs_in_materialize_for_the_real_failed_shape():
    """END-TO-END on tonight's EXACT shape: a mesh worklist whose base carries
    installer_ui="all" (session 20260716-235722-54d2f7), materialized. The x86 nodes must
    emit `--installer-ui cli` in the FULL argv; the ARM entries keep "all"."""
    base = ImageConfig(mode="mesh", installer_ui="all", installer_iso=False)
    wl = WorklistConfig(base=base, entries=[
        WorklistEntry(role="pki", platform="x86"),
        WorklistEntry(role="omnibus", platform="x86"),
        WorklistEntry(role="pki", platform="rpi5"),
    ])
    got = {e.id: cfg for e, cfg in wl.materialize()}
    for eid in ("pki.x86", "omnibus.x86"):
        args = got[eid].to_cli_args()
        assert ("--installer-ui", "cli") in pairs_of(args), f"{eid}: {args}"
        # the assertion that matters: WANT_CALAMARES can never go true
        for trigger in CALAMARES_TRIGGERS:
            assert ("--installer-ui", trigger) not in pairs_of(args)
    # ARM carries no --installer-ui flag at all (strip_platform_unsupported + _X86)
    assert "--installer-ui" not in got["pki.rpi5"].to_cli_args()


def test_installer_ui_materialize_leaves_client_argv_byte_identical():
    """The no-regression fence: a cloud client's materialized argv is IDENTICAL to the
    same config's, proving the resolver cannot perturb a desktop image."""
    base = ImageConfig(mode="cloud", installer_ui="all")
    wl = WorklistConfig(base=base, entries=[WorklistEntry(role="laptop", platform="x86")])
    _e, cfg = wl.materialize()[0]
    ref = ImageConfig(mode="cloud", role="laptop", platform="x86", installer_ui="all",
                      build_subdir="wl-laptop.x86")
    assert cfg.to_cli_args() == ref.to_cli_args()
    assert ("--installer-ui", "all") in pairs_of(cfg.to_cli_args())


def pairs_of(args):
    """argv adjacent-pair view — assert on the flag's VALUE, never a substring grep."""
    return list(zip(args, args[1:]))


def test_platform_default_role_map_grounded_in_catalog():
    """DRIFT GUARD: every PLATFORM_DEFAULT_ROLE value must be a role the ROLE_CHOICES
    catalog actually declares for that platform (so the map can never name a role the
    builder would reject). Pins the two builder-default-backed values explicitly."""
    for platform, role in PLATFORM_DEFAULT_ROLE.items():
        assert role in roles_for_platform(platform), \
            f"{platform} default role {role!r} not in roles_for_platform({platform})"
    assert PLATFORM_DEFAULT_ROLE["rpi5"] == "generic"     # build-rpi5-stage4.sh:99
    assert PLATFORM_DEFAULT_ROLE["jetson"] == "edge-ai"   # build-jetson-stage4.sh:84


def test_roles_for_platform_inversion():
    """roles_for_platform inverts ROLE_CHOICES exactly (guards a catalog edit that would
    silently drop a role from a platform's accepted set)."""
    assert roles_for_platform("frite") == frozenset({"frite"})
    assert roles_for_platform("orangepi5") == frozenset({"orangepi5"})
    assert roles_for_platform("orangepizero2") == frozenset({"orangepizero2"})
    assert roles_for_platform("orangepizero2w") == frozenset({"orangepizero2w"})
    assert roles_for_platform("orangepizero3") == frozenset({"orangepizero3"})
    assert roles_for_platform("orangepi3-lts") == frozenset({"orangepi3-lts"})
    assert roles_for_platform("rpi5") == frozenset({"generic", "rpi5-desktop", "pki", "backend", "frontend"})
    assert roles_for_platform("jetson") == frozenset({"edge-ai", "omnibus", "backend-gpu", "jetson-desktop"})
    assert "standalone-thick" in roles_for_platform("x86")
    assert roles_for_platform("") == roles_for_platform("x86")   # "" defaults to x86


# ---- desktop people (operator ask 2026-08-14) ---------------------------------

def _mesh_base(**kw):
    return ImageConfig(mode="mesh", role="pki", platform="x86", brand="hugmesh", **kw)


def test_desktop_user_roundtrips_the_wire_format():
    e = WorklistEntry(role="laptop", platform="x86",
                      desktop_user="alice", desktop_user_role="admin")
    e2 = WorklistEntry.from_dict(e.to_dict())
    assert (e2.desktop_user, e2.desktop_user_role) == ("alice", "admin")
    # a pre-feature JSON (no keys) loads with the blank defaults
    d = e.to_dict()
    del d["desktop_user"], d["desktop_user_role"]
    e3 = WorklistEntry.from_dict(d)
    assert (e3.desktop_user, e3.desktop_user_role) == ("", "user")


def test_desktop_users_derive_on_the_superdomain_only_for_desktops():
    base = _mesh_base()
    wl = WorklistConfig(base=base, entries=[
        WorklistEntry(role="pki", platform="x86",
                      desktop_user="mallory"),          # node: ignored even if set
        WorklistEntry(role="laptop", platform="x86",
                      desktop_user="alice", desktop_user_role="admin"),
        WorklistEntry(role="desktop", platform="x86"),  # no person named
    ])
    users = wl.desktop_users()
    assert [(u.username, u.role) for u in users] == [("alice", "admin")]
    assert users[0].domain == base.effective_superdomain()


def test_materialize_stamps_person_role_and_manifest_user():
    base = _mesh_base(users=[User(username="bob", domain="tenant.example", role="admin")])
    wl = WorklistConfig(base=base, entries=[
        WorklistEntry(role="pki", platform="x86"),
        WorklistEntry(role="laptop", platform="x86",
                      desktop_user="alice", desktop_user_role="mod"),
    ])
    by_id = {e.id: cfg for e, cfg in wl.materialize()}
    lap, pki = by_id["laptop.x86"], by_id["pki.x86"]
    assert lap.person_role == "mod"
    assert pki.person_role == ""            # a desktop pick can never leak onto a node
    dom = base.effective_superdomain()
    for cfg in (lap, pki):                  # users are manifest-only: carried whole
        assert ("alice", dom, "mod") in [(u.username, u.domain, u.role) for u in cfg.users]
        assert ("bob", "tenant.example") in [(u.username, u.domain) for u in cfg.users]


def test_desktop_users_dedup_against_the_users_table():
    base = _mesh_base()
    base.users = [User(username="alice", domain=base.effective_superdomain(),
                       role="superadmin", email="a@example.org")]
    wl = WorklistConfig(base=base, entries=[
        WorklistEntry(role="laptop", platform="x86",
                      desktop_user="alice", desktop_user_role="user")])
    _e, cfg = wl.materialize()[0]
    rows = [u for u in cfg.users if u.username == "alice"]
    # the richer Users-table row wins; no duplicate derived row
    assert len(rows) == 1 and rows[0].role == "superadmin" and rows[0].email


# ---- desktop people x multi-role (issue #228) ---------------------------------

def test_desktop_user_roles_round_trip_and_omit_when_single():
    """Issue #228 on the desktop-person leg. FAILS on the single-role entry: there
    ``desktop_user_roles`` was not a field (TypeError at construction) and the
    person named on a desktop row could hold exactly one tier — no grants."""
    e = WorklistEntry(role="laptop", platform="x86", desktop_user="alice",
                      desktop_user_roles=["games", "admin"])
    assert e.desktop_user_roles == ["admin", "games"]     # precedence order
    assert e.desktop_user_role == "admin"                 # the tier is DERIVED
    d = e.to_dict()
    assert d["desktop_user_role"] == "admin"
    assert d["desktop_user_roles"] == ["admin", "games"]
    assert WorklistEntry.from_dict(d).to_dict() == d
    # one tier: the pre-#228 bytes exactly (no `desktop_user_roles` key)
    one = WorklistEntry(role="laptop", platform="x86",
                        desktop_user="bob", desktop_user_role="mod")
    assert one.desktop_user_roles == ["mod"] and one.desktop_user_role == "mod"
    assert "desktop_user_roles" not in one.to_dict()
    assert WorklistEntry().desktop_user_role == "user"    # the untouched default
    assert WorklistEntry().desktop_user_roles == ["user"]
    # grants-only: the account still holds the tier the image bakes in — a fixed point
    g = WorklistEntry(role="laptop", platform="x86",
                      desktop_user="gg", desktop_user_roles=["games"])
    assert g.desktop_user_roles == ["user", "games"] and g.desktop_user_role == "user"
    assert WorklistEntry.from_dict(g.to_dict()).to_dict() == g.to_dict()


def test_desktop_user_roles_loads_every_spelling_and_tolerates_junk():
    def one(**extra):
        return WorklistEntry.from_dict({"role": "laptop", "platform": "x86",
                                        "desktop_user": "a", **extra}).desktop_user_roles
    assert one(desktop_user_role="mod") == ["mod"]                       # pre-#228
    assert one(desktop_user_roles=["games-services", "mod"]) == ["mod", "games-services"]
    assert one(desktop_user_role="admin", desktop_user_roles=["games"]) == \
        ["admin", "games"]                                               # unioned
    assert one(desktop_user_roles="admin") == ["admin"]                  # bare string
    assert one(desktop_user_roles=None, desktop_user_role="mod") == ["mod"]
    assert one(desktop_user_roles=7) == ["user"]
    assert one(desktop_user_role=None) == ["user"]
    # both spellings agree after a load, whatever the record said
    e = WorklistEntry.from_dict({"role": "laptop", "platform": "x86",
                                 "desktop_user_role": "user",
                                 "desktop_user_roles": ["superadmin", "games"]})
    assert (e.desktop_user_role, e.desktop_user_roles) == \
        ("superadmin", ["superadmin", "user", "games"])


def test_desktop_users_carry_every_role_and_materialize_stamps_only_the_tier():
    base = _mesh_base()
    wl = WorklistConfig(base=base, entries=[
        WorklistEntry(role="pki", platform="x86"),
        WorklistEntry(role="laptop", platform="x86",
                      desktop_user="alice", desktop_user_roles=["games", "admin"]),
    ])
    users = wl.desktop_users()
    assert [(u.username, u.roles, u.role, u.tier) for u in users] == \
        [("alice", ["admin", "games"], "admin", "admin")]
    by_id = {e.id: cfg for e, cfg in wl.materialize()}
    lap, pki = by_id["laptop.x86"], by_id["pki.x86"]
    assert lap.person_role == "admin"        # the tier — the builder takes four tiers
    assert pki.person_role == ""
    alice = [u for u in lap.users if u.username == "alice"][0]
    assert alice.roles == ["admin", "games"]
    # the manifest wire shape carries the full set beside the primary
    row = [u for u in lap.to_dict()["users"] if u["username"] == "alice"][0]
    assert row["role"] == "admin" and row["roles"] == ["admin", "games"]
    args = lap.to_cli_args()
    assert ("--person-role", "admin") in list(zip(args, args[1:]))
    assert "games" not in args


def test_multi_role_desktop_entry_conforms_to_frozen_schema():
    """The frozen wire contract declares `desktop_user_roles` (additionalProperties
    is false on an entry, so an undeclared key is a schema violation) and a real
    multi-role desktop entry validates against it."""
    jsonschema = pytest.importorskip("jsonschema")
    schema = json.load(open(_SCHEMA_PATH, encoding="utf-8"))
    assert "desktop_user_roles" in schema["$defs"]["worklistEntry"]["properties"]
    wl = _envelope()
    wl.entries.append(WorklistEntry(role="laptop", platform="x86", desktop_user="alice",
                                    desktop_user_roles=["games", "admin"]))
    d = wl.to_dict()
    assert d["entries"][-1]["desktop_user_roles"] == ["admin", "games"]
    jsonschema.validate(d, schema)
    # ...and a one-tier entry still carries no such key (the omit-when-single rule)
    assert "desktop_user_roles" not in d["entries"][0]


# ---- per-image hostname (issue #229) --------------------------------------------
# "System identity is a single image-config setting even when generating multiple
# images — acceptable for timezone and maybe user, but NOT for hostname. Hostname must
# be settable per image." The base's one `hostname` used to ride onto every
# materialized image byte-identical; WorklistEntry.hostname is the per-image override.

def _two_row_mesh(base_hostname="", **entry_hostnames):
    base = ImageConfig(mode="mesh", brand="acme", hostname=base_hostname)
    entries = [WorklistEntry(role="pki", platform="x86",
                             hostname=entry_hostnames.get("pki", "")),
               WorklistEntry(role="backend", platform="rpi5", board="rpi5",
                             hostname=entry_hostnames.get("backend", ""))]
    return WorklistConfig(base=base, entries=entries)


def _hostname_flag(argv):
    return argv[argv.index("--hostname") + 1] if "--hostname" in argv else None


def test_entry_hostname_roundtrips_the_wire_format():
    e = WorklistEntry(role="pki", platform="x86", hostname="ca-1")
    d = e.to_dict()
    assert d["hostname"] == "ca-1"
    assert WorklistEntry.from_dict(d).hostname == "ca-1"
    # absent on an older envelope -> the blank default (inherit), never a KeyError
    assert WorklistEntry.from_dict({"role": "pki", "platform": "x86"}).hostname == ""


def test_two_rows_with_different_hostnames_each_get_their_own():
    """THE #229 test: a two-row worklist with two identities materializes two images
    that each carry THEIR OWN -H, and neither carries the other's."""
    wl = _two_row_mesh(pki="ca-1", backend="be-pi")
    out = wl.materialize()
    by_id = {e.id: cfg for e, cfg in out}
    assert by_id["pki.x86"].hostname == "ca-1"
    assert by_id["backend.rpi5"].hostname == "be-pi"
    assert _hostname_flag(by_id["pki.x86"].to_cli_args()) == "ca-1"
    assert _hostname_flag(by_id["backend.rpi5"].to_cli_args()) == "be-pi"
    # the shared base is untouched — the names live on the entries
    assert wl.base.hostname == ""


def test_blank_entry_hostname_inherits_the_base_and_a_blank_base_derives():
    """"" = inherit: a blank entry takes the base's value (the single-image shape),
    and with a blank base the image emits NO -H so the builder derives its role name
    — the mesh argv of a worklist that never named anything is byte-identical."""
    wl = _two_row_mesh(pki="ca-1")
    by_id = {e.id: cfg for e, cfg in wl.materialize()}
    assert by_id["pki.x86"].hostname == "ca-1"
    assert by_id["backend.rpi5"].hostname == ""
    assert "--hostname" not in by_id["backend.rpi5"].to_cli_args()
    # a base value is the fallback for a blank row — but only ONE row may use it
    one = WorklistConfig(base=ImageConfig(mode="mesh", brand="acme", hostname="shared"),
                         entries=[WorklistEntry(role="pki", platform="x86"),
                                  WorklistEntry(role="backend", platform="x86",
                                                hostname="be-1")])
    by_id = {e.id: cfg for e, cfg in one.materialize()}
    assert by_id["pki.x86"].hostname == "shared"
    assert by_id["backend.x86"].hostname == "be-1"


def test_materialize_rejects_two_images_baking_the_same_hostname():
    """The #229 failure mode is now DETECTED instead of silently produced: two
    explicit names that collide, or one base value riding onto several blank rows,
    fail loudly at materialize (the same chokepoint as the duplicate-id guard) with
    the fix named in the message."""
    with pytest.raises(ValueError, match="same hostname.*'node' on pki.x86, backend.rpi5"):
        _two_row_mesh(pki="node", backend="node").materialize()
    with pytest.raises(ValueError, match="same hostname.*entries\\[\\].hostname"):
        _two_row_mesh(base_hostname="everyone").materialize()
    # ...and naming the rows apart is exactly what clears it
    fixed = _two_row_mesh(base_hostname="everyone", pki="ca-1")
    by_id = {e.id: cfg for e, cfg in fixed.materialize()}
    assert (by_id["pki.x86"].hostname, by_id["backend.rpi5"].hostname) == ("ca-1", "everyone")


def test_materialize_rejects_a_typed_name_equal_to_a_blank_siblings_derived_name():
    """The other half of #229's collision, and the one that reads CLEAN in the argv:
    one row types ``acme-backend``, its sibling is left blank and emits no --hostname
    at all — so nothing in the command looks wrong and both nodes still boot as
    ``acme-backend``. The model refuses it, which is what makes the guard the same
    strength on all three channels (the GUI used to catch this alone)."""
    derived_be = derived_hostname(WorklistEntry(role="backend", platform="rpi5",
                                                board="rpi5"), "acme")
    wl = _two_row_mesh(pki=derived_be)
    with pytest.raises(ValueError,
                       match=f"same hostname.*{derived_be!r}.*pki.x86, backend.rpi5"):
        wl.materialize()
    # ...and the message says WHY a blank row is implicated, since the operator can
    # see only one name in the envelope
    with pytest.raises(ValueError, match="blank row is not free of this"):
        wl.materialize()
    # a name that is nobody's derived name still builds
    ok = {e.id: cfg for e, cfg in _two_row_mesh(pki="ca-1").materialize()}
    assert ok["pki.x86"].hostname == "ca-1" and ok["backend.rpi5"].hostname == ""


def test_derived_hostname_is_the_one_shared_role_name_implementation():
    """Both UIs show a blank row's name (GUI placeholder, TUI "if blank" column) and
    the model refuses collisions against it — one function, so a shown name can never
    disagree with a refused one. Derived per ENTRY: the base's role/platform is the
    first checked row's, not every row's."""
    pki = WorklistEntry(role="pki", platform="x86")
    be = WorklistEntry(role="backend", platform="rpi5", board="rpi5")
    assert derived_hostname(pki, "acme") != derived_hostname(be, "acme")
    assert derived_hostname(pki, "acme").startswith("acme")
    # a blank brand is the builder's own default, exactly as derive_hostname treats it
    assert derived_hostname(pki, "") == derived_hostname(pki, "hugmesh")


def test_two_blank_rows_are_never_a_refusal():
    """Blank vs blank stays the builder's business: two rows that derive the same name
    have always built that way, so the UIs say it out loud and nothing refuses. Only a
    TYPED name colliding is an operator mistake this can name."""
    twin = WorklistConfig(base=ImageConfig(mode="mesh", brand="acme"),
                          entries=[WorklistEntry(role="pki", platform="x86"),
                                   WorklistEntry(role="pki", platform="rpi5",
                                                 board="rpi5")])
    assert duplicate_hostnames(twin.entries, "", "acme") == {}
    assert len(twin.materialize()) == 2


def test_bad_per_image_hostname_fails_closed():
    """validate_identity runs on every materialized cfg, so a malformed per-row
    name is refused exactly like a malformed base one (no new validator needed)."""
    with pytest.raises(ValueError):
        _two_row_mesh(pki="Bad_Host!").materialize()


def test_synthesize_keeps_the_single_image_hostname():
    """Existing single-image flows are UNCHANGED: synthesize() wraps cfg.hostname on
    the base, the lone entry inherits it, and the argv round-trips byte-identical."""
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      hostname="my-desktop")
    (entry, out), = synthesize(cfg).materialize()
    assert entry.hostname == ""                     # inherit
    assert out.hostname == "my-desktop"
    expect = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                         hostname="my-desktop", build_subdir="wl-standalone-thick.x86")
    assert out.to_cli_args() == expect.to_cli_args()


def test_resolve_and_duplicate_hostnames_are_the_pure_helpers_the_uis_share():
    a = WorklistEntry(role="pki", platform="x86", hostname="  ca-1 ")
    b = WorklistEntry(role="backend", platform="x86")
    assert resolve_hostname(a, "base") == "ca-1"
    assert resolve_hostname(b, "base") == "base"
    assert resolve_hostname(b, "") == ""
    assert duplicate_hostnames([a, b], "") == {}
    assert duplicate_hostnames([a, b], "ca-1") == {"ca-1": ["pki.x86", "backend.x86"]}
    # blanks never collide with each other: their names are the builder's to derive
    assert duplicate_hostnames([b, WorklistEntry(role="frontend", platform="x86")], "") == {}

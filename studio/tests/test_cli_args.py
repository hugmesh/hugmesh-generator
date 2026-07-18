"""Golden ImageConfig.to_cli_args() translations for EVERY role x platform.

The Studio's all-options-in-all-menus contract: each documented role builds through
the right builder script with exactly the flags that builder parses. Pure-core tests —
no Qt required.
"""
import json

import pytest

from snapdragon_studio.core.config import (
    BUILDER_SCRIPTS,
    DESKTOP_ROLES,
    ENV_CHOICES,
    GPU_DRIVER_ALIASES,
    GPU_DRIVER_CHOICES,
    HOME_DESKTOP_FIELDS,
    Domain,
    ImageConfig,
    INFRA_SERVICES_CHOICES,
    MODE_DEFAULT_ROLE,
    MODE_SKIPPED_PAGES,
    NODE_ROLES,
    NON_ARGV_FIELDS,
    OPTIONAL_SERVICES_BY_PLATFORM,
    PLATFORM_FIELD_SUPPORT,
    ROLE_CHOICES,
    SECRET_FIELDS,
    SERVICES_ALL,
    SERVICES_NONE,
    THEME_FIELDS,
    UNAFFILIATED_ROLE,
    User,
    WIZARD_PAGE_SLUGS,
    X86_CLIENT_ROLES,
    X86_NODE_ROLES,
    RPI_BOARDS,
    RPI_NODE_BOARDS,
    branding_allowed,
    clear_role_class_fields,
    enter_mesh_defaults,
    home_options_allowed,
    image_class,
    rpi_boards_for_role,
    strip_platform_unsupported,
    tailnet_sso_visible,
)


# the invariant x86 tail (script defaults made explicit by to_cli_args)
X86_TAIL = ["--snort", "--installer-ui", "all", "--uncached", "--live-toram", "--bundle-source"]


def pairs(args):
    """value-flag pairs for order-insensitive assertions."""
    return list(zip(args, args[1:]))


# ---- catalog sanity ---------------------------------------------------------

def test_role_catalog_covers_every_documented_role():
    flat = {(r, p) for roles in ROLE_CHOICES.values() for r, plats, _ in roles for p in plats}
    # SERVER/cluster
    for r in ("pki", "be", "fe", "be+gpu", "omnibus", "edge_ai"):
        assert (r, "x86") in flat
    for r in ("pki", "be", "fe"):
        assert (r, "rpi5") in flat
    assert ("rpi5-desktop", "rpi5") in flat
    # CLIENT
    for r in ("laptop", "chromebook", "desktop"):
        assert (r, "x86") in flat
    assert ("frite", "frite") in flat
    # STANDALONE
    assert ("standalone-thin", "x86") in flat and ("standalone-thick", "x86") in flat
    # PLAIN-GENTOO arms: the unaffiliated x86 desktop + the rpi5 generic arm64 server
    assert ("standalone-unaffiliated", "x86") in flat
    assert ("generic", "rpi5") in flat
    # JETSON (EXPERIMENTAL)
    for r in ("edge_ai", "full", "gpu-host", "jetson-desktop"):
        assert (r, "jetson") in flat


def test_mode_defaults_stay_in_catalog():
    for mode, role in MODE_DEFAULT_ROLE.items():
        assert role in {r for r, _, _ in ROLE_CHOICES[mode]}


def test_mode_skipped_pages_match_the_page_catalog():
    """The wizard's mode-gated page flow (Qt-free contract): one skip set per mode,
    every slug real, standalone skipping the whole admin/mesh plane (the shortest
    path to the plain/unaffiliated desktop) — and no mode may skip a structural page."""
    assert set(MODE_SKIPPED_PAGES) == set(MODE_DEFAULT_ROLE)
    for slugs in MODE_SKIPPED_PAGES.values():
        assert set(slugs) <= set(WIZARD_PAGE_SLUGS)
    assert MODE_SKIPPED_PAGES["standalone"] == ("worklist", "keyzip", "domains", "users")
    # 'role' is no longer universally structural — mesh skips it (the WorklistPage owns
    # role x platform there); welcome/mode/build stay structural in every mode.
    for structural in ("welcome", "mode", "build"):
        assert all(structural not in slugs for slugs in MODE_SKIPPED_PAGES.values())


@pytest.mark.parametrize("platform,script", sorted(BUILDER_SCRIPTS.items()))
def test_builder_script_per_platform(platform, script):
    assert ImageConfig(platform=platform).builder_script == script


def test_unknown_platform_rejected():
    with pytest.raises(ValueError):
        ImageConfig(platform="amiga").to_cli_args()
    with pytest.raises(ValueError):
        _ = ImageConfig(platform="amiga").builder_script


# ---- x86: every role --------------------------------------------------------

@pytest.mark.parametrize("role", ["standalone-thin", "standalone-thick"])
def test_x86_standalone_roles_golden(role):
    args = ImageConfig(mode="standalone", role=role, platform="x86").to_cli_args()
    assert args == ["--role", role, "--env", "test", "--local-user", "magus",
                    "--no-tailscale", "--no-sso", *X86_TAIL]


# ---- x86: the UNAFFILIATED plain-Gentoo desktop -------------------------------
# The builder's role arm PRESETS everything (neutral gentoo identity, no bundled
# source, no mesh/SSO) and HARD-ERRORS on any affiliation flag — the Studio emits
# the bare role + generic options only, and raises the same conflicts loudly.

def test_x86_standalone_unaffiliated_golden():
    args = ImageConfig(mode="standalone", role="standalone-unaffiliated", platform="x86",
                       bundle_source=False).to_cli_args()
    assert args == ["--role", "standalone-unaffiliated", "--env", "test",
                    "--local-user", "magus",
                    "--snort", "--installer-ui", "all", "--uncached", "--live-toram"]


def test_x86_unaffiliated_never_emits_affiliation_flags():
    """Mirror of test_rpi5_never_emits_x86_only_flags: generic options flow through,
    every affiliation flag (a builder hard-conflict) is absent."""
    args = ImageConfig(mode="standalone", role="standalone-unaffiliated", platform="x86",
                       bundle_source=False, gpu_driver="nvidia", encrypt_root=True,
                       luks_pass="sekrit", unlock_keyfile="boot", unlock_yubikey="login",
                       compress=True, resume=True).to_cli_args()
    for flag in ("--brand", "--brand-title", "--org",
                 "--theme", "--branding-dir", "--wallpaper", "--grub-background",
                 "--grub-theme", "--login-background", "--brand-logo", "--accent-color",
                 "--color-scheme", "--brand-locked",
                 "--bundle-source", "--no-bundle-source", "--home-seed-code",
                 "--with-tailscale", "--no-tailscale", "--with-sso", "--no-sso",
                 "--person-role", "--domains"):
        assert flag not in args
    p = pairs(args)
    assert ("--role", "standalone-unaffiliated") in p
    assert ("--gpu-driver", "nvidia") in p
    assert "--encrypt-root" in args
    assert ("--luks-pass", "sekrit") in p
    assert ("--unlock-keyfile", "boot") in p and ("--unlock-yubikey", "login") in p
    assert "--compress" in args and "--resume" in args


@pytest.mark.parametrize("conflict", [
    {"brand": "acme"},
    {"brand_title": "Acme"},
    {"org": "Acme-Org"},
    {"brand": "gentoo"},              # even the neutral id: the builder forces it ITSELF
    {"theme": "boogiepop"},
    {"branding_dir": "/tmp/brand"},
    {"wallpaper": "wp.png"},
    {"grub_background": "g.png"},
    {"login_background": "l.png"},
    {"brand_logo": "logo.png"},
    {"accent_color": "#123456"},
    {"color_scheme": "dark"},
    {"brand_locked": True},
    {"home_seed_code": "repos"},
    {"tailscale": True},
    {"sso": True},
    {"mode": "cloud"},                # would emit --person-role/--domains
    {"mode": "mesh"},
])
def test_x86_unaffiliated_conflicting_fields_raise(conflict):
    kw = dict(mode="standalone", role="standalone-unaffiliated", platform="x86",
              bundle_source=False)
    kw.update(conflict)
    with pytest.raises(ValueError, match="unaffiliated"):
        ImageConfig(**kw).to_cli_args()


def test_x86_unaffiliated_bundle_source_default_is_normalized_not_a_conflict():
    """bundle_source defaults True (the branded-standalone self-hosting default), so
    an untouched config must NOT raise — it is normalized like the wizard does on
    role selection: the argv carries NEITHER --bundle-source NOR --no-bundle-source
    (the role presets no-bundled-source builder-side; only an EXPLICIT
    --bundle-source flag errors there)."""
    args = ImageConfig(mode="standalone", role="standalone-unaffiliated",
                       platform="x86", bundle_source=True).to_cli_args()
    assert "--bundle-source" not in args
    assert "--no-bundle-source" not in args


def test_x86_unaffiliated_generic_iso_knobs_flow_through():
    """The BuildPage's generic knobs (img-size / cached / live-toram) and the proxy
    stack are NOT affiliation — they flow through on the unaffiliated role while the
    bundle-source pair stays suppressed."""
    args = ImageConfig(mode="standalone", role="standalone-unaffiliated", platform="x86",
                       bundle_source=False, img_size=6144, cached=True, live_toram=False,
                       proxy_stack="off").to_cli_args()
    assert ("--img-size", "6144") in pairs(args)
    assert "--cached" in args and "--no-live-toram" in args
    assert "--no-proxy-stack" in args
    assert "--bundle-source" not in args and "--no-bundle-source" not in args


def test_unaffiliated_role_constant_matches_catalog():
    assert UNAFFILIATED_ROLE == "standalone-unaffiliated"
    assert UNAFFILIATED_ROLE in {r for r, _, _ in ROLE_CHOICES["standalone"]}


@pytest.mark.parametrize("role", ["laptop", "chromebook", "desktop"])
def test_x86_client_roles_golden(role):
    args = ImageConfig(mode="cloud", role=role, platform="x86",
                       tailscale=True, sso=True).to_cli_args()
    assert args == ["--role", role, "--env", "test", "--local-user", "magus",
                    "--with-tailscale", "--with-sso", "--person-role", "user", *X86_TAIL]


# ---- Chromebook: a coreboot/UEFI laptop-class DESKTOP image (ADR-16) ----------
# The chromebook role is a person-device DESKTOP (X86_CLIENT_ROLES/DESKTOP_ROLES),
# surfaced as a first-class desktop selection in BOTH cloud (tailnet + SSO) and
# standalone (no mesh/SSO) modes. It must never be misclassified as a node.

def test_chromebook_is_desktop_class_not_a_node():
    assert "chromebook" in X86_CLIENT_ROLES
    assert "chromebook" in DESKTOP_ROLES and "chromebook" not in NODE_ROLES
    assert image_class("cloud", "chromebook") == "desktop"
    assert image_class("standalone", "chromebook") == "desktop"


def test_chromebook_selectable_in_cloud_and_standalone_catalog():
    """Discoverability: chromebook is a labelled desktop choice in BOTH modes."""
    for mode in ("cloud", "standalone"):
        entry = [(r, plats, label) for r, plats, label in ROLE_CHOICES[mode] if r == "chromebook"]
        assert entry, f"chromebook missing from ROLE_CHOICES[{mode!r}]"
        (_r, plats, label) = entry[0]
        assert plats == ("x86",)
        # the label must say WHAT it is (coreboot/UEFI Chromebook desktop), not the old
        # opaque "Chromebook client" — the discoverability + labelling ask.
        assert "Chromebook desktop" in label and "coreboot" in label


def test_x86_chromebook_standalone_golden():
    """Standalone posture: no mesh/SSO plane, plain coreboot/UEFI laptop image. The
    builder accepts --role chromebook with --no-tailscale/--no-sso (verified against
    build-x86-host-stage4.sh --print-plan in the build-matrix GUI channel)."""
    args = ImageConfig(mode="standalone", role="chromebook", platform="x86").to_cli_args()
    assert args == ["--role", "chromebook", "--env", "test", "--local-user", "magus",
                    "--no-tailscale", "--no-sso", *X86_TAIL]


# ---- Raspberry Pi board-per-role-class: rpi3 is desktop-only (1GB RAM) ---------
# build-rpi5-stage4.sh hard-errors a non-desktop role on --board rpi3, so the GUI /
# menu / catalog must never OFFER rpi3 for a node role — the selection layer mirrors
# the builder's contract so a pick can't dead-end (honesty rule).

def test_rpi_boards_for_role_gates_rpi3_to_desktop():
    # desktop-class rpi5 role -> every board incl. rpi3
    assert rpi_boards_for_role("rpi5-desktop") == RPI_BOARDS
    assert "rpi3" in rpi_boards_for_role("rpi5-desktop")
    # node/appliance rpi5 roles -> rpi5/rpi4 ONLY (rpi3 excluded)
    for node_role in ("pki", "be", "fe", "generic"):
        boards = rpi_boards_for_role(node_role)
        assert boards == RPI_NODE_BOARDS
        assert "rpi3" not in boards


def _load_emit_image_catalog():
    """Import scripts/emit-image-catalog.py (dashed filename) and return its module."""
    import importlib.util
    import os

    here = os.path.dirname(os.path.abspath(__file__))
    gen_root = os.path.dirname(os.path.dirname(here))       # studio/tests -> repo root
    path = os.path.join(gen_root, "scripts", "emit-image-catalog.py")
    spec = importlib.util.spec_from_file_location("_emit_image_catalog", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod, gen_root


def _node_roles_offering_rpi3(catalog: dict) -> list[tuple]:
    """(mode, role, board_axis) for every NON-desktop catalog entry that offers rpi3."""
    offenders = []
    for mode, roles in catalog["roles"].items():
        for entry in roles:
            if entry["image_class"] == "desktop":
                continue
            for plat in entry["platforms"]:
                board = plat["axes"].get("board", [])
                if "rpi3" in board:
                    offenders.append((mode, entry["role"], board))
    return offenders


def test_image_catalog_never_offers_rpi3_for_a_node_role():
    """The machine-readable web/JOB catalog (docs/catalog/image-catalog.json) the admin-ui
    worklist multi-select consumes MUST mirror the GUI gating: rpi3 (1GB RAM, builder
    hard-errors a non-desktop role on --board rpi3) is desktop-only. A node role offering
    rpi3 in any menu is exactly the dead-end the honesty rule forbids."""
    emit, _ = _load_emit_image_catalog()
    catalog = emit.build_image_catalog()
    assert _node_roles_offering_rpi3(catalog) == []
    # the desktop rpi5 role still keeps rpi3 (the one role that may target it)
    desk = [e for e in catalog["roles"]["cloud"] if e["role"] == "rpi5-desktop"][0]
    rpi5_axis = [p for p in desk["platforms"] if p["platform"] == "rpi5"][0]
    assert "rpi3" in rpi5_axis["axes"]["board"]


def test_committed_image_catalog_matches_emitter_and_gates_rpi3():
    """The committed image-catalog.json is in sync with the emitter (drift guard) AND, as a
    belt-and-suspenders check on the artifact the web modal actually serves, carries no
    node-role rpi3 offer."""
    import os

    emit, gen_root = _load_emit_image_catalog()
    committed_path = os.path.join(gen_root, "docs", "catalog", "image-catalog.json")
    with open(committed_path, encoding="utf-8") as fh:
        committed = json.load(fh)
    assert committed == emit.build_image_catalog(), (
        "docs/catalog/image-catalog.json is stale — re-run scripts/emit-image-catalog.py")
    assert _node_roles_offering_rpi3(committed) == []


def test_rpi5_node_on_rpi4_is_a_real_buildable_cell():
    """A Raspberry Pi 4 backend NODE is an explicit, valid selection (board rpi4 +
    node role) — the surfacing the request asks for. Emits --role backend --board rpi4."""
    args = ImageConfig(mode="mesh", role="be", platform="rpi5", board="rpi4",
                       tailscale=True).to_cli_args()
    assert args[:5] == ["--role", "backend", "--board", "rpi4", "--env"]


@pytest.mark.parametrize("role", ["pki", "be", "fe", "be+gpu", "omnibus", "edge_ai"])
def test_x86_mesh_roles_golden(role):
    # G18: a mesh NODE role does NOT carry --person-role/--domains — the builder warns
    # + ignores them there (build-x86:1220-1222), so the Studio must not emit them.
    args = ImageConfig(mode="mesh", role=role, platform="x86",
                       tailscale=True, sso=True).to_cli_args()
    # WS-SUPER-B: every mesh image records its orchestration plane (derived
    # <brand>.internal). --superdomain rides the cluster/mesh identity block.
    assert args == ["--role", role, "--env", "test", "--local-user", "magus",
                    "--with-tailscale", "--with-sso",
                    "--superdomain", "snapdragon.internal", *X86_TAIL]
    assert "--person-role" not in args
    assert "--domains" not in args


def test_x86_mesh_node_never_emits_person_role_even_with_domains_and_users():
    # Even when the superadmin fills in domains/users (they go to the mesh manifest),
    # a NODE-role x86 image carries NO --person-role/--domains at build time (FD-08).
    from snapdragon_studio.core.config import Domain, User
    args = ImageConfig(mode="mesh", role="omnibus", platform="x86", tailscale=True, sso=True,
                       domains=[Domain(name="acme.example")],
                       users=[User(username="root", role="superadmin")]).to_cli_args()
    assert "--person-role" not in args and "--domains" not in args


# ---- mode-aware tailscale/sso tri-state (the PR #304 verify-pass defect) -------
# ImageConfig used to default tailscale/sso to a plain False while the mode-aware
# defaulting lived ONLY in NetworkPage.initializePage — so a mesh/cloud config JSON
# that simply OMITTED the keys printed --no-tailscale --no-sso (x86) / --skip-mesh
# (ARM): headless callers got a non-mesh mesh image. Now "" (never set) resolves to
# the MODE default at emission time; bools stay EXPLICIT (the GUI's checkboxes).

def test_mesh_and_cloud_configs_omitting_tailscale_sso_resolve_on():
    for mode, role in (("mesh", "omnibus"), ("cloud", "desktop")):
        args = ImageConfig(mode=mode, role=role, platform="x86").to_cli_args()
        assert "--with-tailscale" in args and "--with-sso" in args, (mode, role)
        assert "--no-tailscale" not in args and "--no-sso" not in args, (mode, role)


def test_standalone_config_omitting_tailscale_sso_resolves_off():
    args = ImageConfig(mode="standalone", role="standalone-thick", platform="x86").to_cli_args()
    assert "--no-tailscale" in args and "--no-sso" in args


def test_explicit_false_still_forces_no_flags_on_a_mesh_build():
    """The GUI contract: a user who UNCHECKS the box on a mesh build collects
    tailscale=False/sso=False (a plain bool, NetworkPage.validatePage) and must
    STILL get the explicit --no-* pair — False is NEVER 'leave the mode default'."""
    args = ImageConfig(mode="mesh", role="omnibus", platform="x86",
                       tailscale=False, sso=False).to_cli_args()
    assert "--no-tailscale" in args and "--no-sso" in args
    assert "--with-tailscale" not in args and "--with-sso" not in args


def test_arm_mesh_config_omitting_tailscale_keeps_its_mesh():
    on = ImageConfig(mode="mesh", role="be", platform="rpi5").to_cli_args()
    assert "--skip-mesh" not in on
    off = ImageConfig(mode="mesh", role="be", platform="rpi5", tailscale=False).to_cli_args()
    assert "--skip-mesh" in off


def test_tailscale_sso_onoff_spellings_accepted():
    on = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                     tailscale="on", sso="on").to_cli_args()
    assert "--with-tailscale" in on and "--with-sso" in on
    off = ImageConfig(mode="mesh", role="omnibus", platform="x86",
                      tailscale="off", sso="off").to_cli_args()
    assert "--no-tailscale" in off and "--no-sso" in off


@pytest.mark.parametrize("junk", ["yes", "1", "true", 1])
def test_tailscale_sso_junk_values_fail_closed(junk):
    """A typo like "yes" must never silently strip the mesh off (or bake it into)
    an image — both the emission path and the JSON-load path reject it."""
    with pytest.raises(ValueError, match="tailscale"):
        ImageConfig(mode="mesh", role="omnibus", platform="x86",
                    tailscale=junk).to_cli_args()
    with pytest.raises(ValueError, match="sso"):
        ImageConfig.from_dict({"mode": "mesh", "role": "omnibus", "platform": "x86",
                               "sso": junk})


def test_tailscale_sso_round_trip_preserves_never_set(tmp_path):
    """save()/load() must keep the '' sentinel (so the mode default keeps applying,
    even if the mode later changes) AND keep explicit bools explicit; the
    'on'/'off' spellings normalize to bools at load so the GUI's truthy checkbox
    seeding (NetworkPage.initializePage) can never misread a truthy 'off' string."""
    p = tmp_path / "roundtrip.json"
    never_set = ImageConfig(mode="mesh", role="omnibus", platform="x86")
    never_set.save(str(p))
    assert ImageConfig.load(str(p)).tailscale == ""
    explicit = ImageConfig(mode="mesh", role="omnibus", platform="x86",
                           tailscale=False, sso=True)
    explicit.save(str(p))
    reloaded = ImageConfig.load(str(p))
    assert reloaded.tailscale is False and reloaded.sso is True
    assert reloaded.to_cli_args() == explicit.to_cli_args()
    assert ImageConfig.from_dict({"tailscale": "off", "sso": "on"}).tailscale is False
    assert ImageConfig.from_dict({"tailscale": "off", "sso": "on"}).sso is True


def test_x86_client_desktop_weight_and_steam():
    args = ImageConfig(mode="cloud", role="laptop", platform="x86",
                       desktop="thin", steam="flatpak").to_cli_args()
    assert ("--desktop", "thin") in pairs(args)
    assert ("--steam", "flatpak") in pairs(args)


@pytest.mark.parametrize("role", ["laptop", "chromebook", "desktop"])
def test_x86_client_role_standalone_compose(role):
    # --standalone composes onto ANY x86 client role (not just the dedicated
    # standalone-thin/standalone-thick role ids, whose ROLE NAME itself sets
    # STANDALONE=true inside the builder's own role-switch) — the builder
    # already supports this (verified live); Studio must actually emit the
    # flag for it to reach the builder.
    args = ImageConfig(mode="cloud", role=role, platform="x86", standalone=True,
                       local_user="alice", local_pass="s3cret",
                       encrypt_root=True, luks_pass="hunter2").to_cli_args()
    assert "--standalone" in args
    assert "--encrypt-root" in args
    assert ("--luks-pass", "hunter2") in pairs(args)


def test_x86_optional_services_and_games():
    cfg = ImageConfig(mode="mesh", role="omnibus", platform="x86",
                      optional_services=["akkoma", "tuwunel", "phpbb", "games",
                                         "owncast", "tube", "character-studio"],
                      enable_games=True)
    args = cfg.to_cli_args()
    # SPACE-separated (one argv element): the builders word-split OPTIONAL_SERVICES
    # on IFS whitespace — a comma-joined value matches no slug, so every selected
    # service would be silently pruned by gate_optional_services().
    assert ("--optional-services",
            "akkoma tuwunel phpbb games owncast tube character-studio") in pairs(args)
    assert "--enable-games" in args


def test_x86_encryption_flags():
    args = ImageConfig(mode="standalone", role="standalone-thick",
                       encrypt_root=True, luks_pass="sekrit",
                       unlock_keyfile="boot", unlock_yubikey="login").to_cli_args()
    p = pairs(args)
    assert "--encrypt-root" in args
    assert ("--luks-pass", "sekrit") in p
    assert ("--unlock-keyfile", "boot") in p
    assert ("--unlock-yubikey", "login") in p


def test_x86_installer_ui_compress_resume():
    args = ImageConfig(installer_ui="ncurses", compress=True, resume=True).to_cli_args()
    assert ("--installer-ui", "ncurses") in pairs(args)
    assert "--compress" in args and "--resume" in args


def test_x86_proxy_stack_tristate():
    """--proxy-stack is TRI-STATE like the builder (PROXY_STACK=auto is ITS default,
    resolved to on for client desktops): auto emits NOTHING so the builder keeps its
    per-role default; only an explicit on/off emits the flag pair."""
    auto = ImageConfig(proxy_stack="auto").to_cli_args()
    assert "--proxy-stack" not in auto and "--no-proxy-stack" not in auto
    on = ImageConfig(proxy_stack="on").to_cli_args()
    assert "--proxy-stack" in on and "--no-proxy-stack" not in on
    off = ImageConfig(proxy_stack="off").to_cli_args()
    assert "--no-proxy-stack" in off and "--proxy-stack" not in off


def test_x86_img_size_emitted_only_when_set():
    # 0 = "(role default)": the builder sizes the compact root per role/desktop itself
    assert "--img-size" not in ImageConfig(img_size=0).to_cli_args()
    assert ("--img-size", "4096") in pairs(ImageConfig(img_size=4096).to_cli_args())


def test_x86_iso_finish_pairs_flip():
    """The BuildPage checkboxes' non-default sides: --cached / --no-live-toram /
    --no-bundle-source each replace (not join) their default counterpart."""
    args = ImageConfig(mode="standalone", role="standalone-thick", cached=True,
                       live_toram=False, bundle_source=False).to_cli_args()
    assert "--cached" in args and "--uncached" not in args
    assert "--no-live-toram" in args and "--live-toram" not in args
    assert "--no-bundle-source" in args and "--bundle-source" not in args


# ---- rpi5: server node roles (be/fe spelled out) -----------------------------

@pytest.mark.parametrize("role,builder_role",
                         [("pki", "pki"), ("be", "backend"), ("fe", "frontend"),
                          ("rpi5-desktop", "desktop")])
def test_rpi5_roles_golden(role, builder_role):
    args = ImageConfig(mode="mesh", role=role, platform="rpi5", tailscale=True).to_cli_args()
    # WS-SUPER-B: mesh images record the derived orchestration superdomain.
    assert args == ["--role", builder_role, "--env", "test",
                    "--superdomain", "snapdragon.internal"]


def test_rpi5_standalone_desktop():
    # --standalone only composes onto rpi5-desktop (builder --role desktop);
    # the builder itself hard-errors on the cluster-node roles.
    args = ImageConfig(mode="mesh", role="rpi5-desktop", platform="rpi5", tailscale=True,
                       standalone=True, local_user="alice", local_pass="s3cret",
                       encrypt_root=True, luks_pass="hunter2").to_cli_args()
    assert args == ["--role", "desktop", "--env", "test",
                    "--superdomain", "snapdragon.internal",
                    "--standalone", "--local-user", "alice", "--local-pass", "s3cret",
                    "--encrypt-root", "--luks-pass", "hunter2"]


def test_rpi5_full_surface():
    cfg = ImageConfig(mode="mesh", role="fe", platform="rpi5", tailscale=False,
                      brand="acme", brand_title="Acme", org="Acme-Org",
                      cluster_domain="acme.example", enable_wifi=True, enable_bluetooth=True,
                      root_login="prohibit-password", img_size=4096, compress=True, resume=True,
                      optional_services=["akkoma", "owncast"], enable_games=True,
                      character_studio=True)
    args = cfg.to_cli_args()
    assert args == ["--role", "frontend", "--env", "test",
                    "--brand", "acme", "--brand-title", "Acme", "--org", "Acme-Org",
                    "--cluster-domain", "acme.example",
                    "--superdomain", "acme.internal", "--skip-mesh",
                    "--enable-wifi", "--enable-bluetooth",
                    "--permit-root-login", "prohibit-password",
                    "--img-size", "4096", "--compress", "--resume",
                    "--optional-services", "akkoma owncast", "--enable-games",
                    "--with-character-studio"]


def test_rpi5_board_unset_emits_nothing():
    """board="" (the dataclass default) must NOT emit --board at all — the
    builder's own default (rpi5) applies, exactly like every existing rpi5
    golden test above (none of them pass board=...)."""
    args = ImageConfig(mode="mesh", role="pki", platform="rpi5", tailscale=True).to_cli_args()
    assert args == ["--role", "pki", "--env", "test",
                    "--superdomain", "snapdragon.internal"]
    assert "--board" not in args


@pytest.mark.parametrize("board", ["rpi5", "rpi4", "rpi3"])
def test_rpi5_board_axis(board):
    """build-rpi5-stage4.sh --board (Phase 6 Pi 4 support, Phase 8 Pi 3 support)
    — mirrors test_jetson_board_axis: --board rides right after --role, before
    the shared --env/_arm_common_args() surface. (This is a pure CLI-arg
    composition test — ImageConfig does not pre-validate rpi3's desktop-only
    constraint; role="be" here would hard-error at the builder, which is by
    design — see test_rpi5_board_rpi3_composes_with_desktop_standalone below
    for the actually-valid rpi3 shape.)"""
    args = ImageConfig(mode="mesh", role="be", platform="rpi5", tailscale=True,
                       board=board).to_cli_args()
    assert args == ["--role", "backend", "--board", board, "--env", "test",
                    "--superdomain", "snapdragon.internal"]


def test_rpi5_board_composes_with_desktop_standalone():
    """--board rpi4 must compose cleanly with the desktop role's --standalone/
    LUKS2 surface (Phase 6 reuses ALL of the Phase 2b/Phase 3 machinery)."""
    args = ImageConfig(mode="mesh", role="rpi5-desktop", platform="rpi5", tailscale=True,
                       board="rpi4", standalone=True, local_user="alice",
                       encrypt_root=True).to_cli_args()
    assert args == ["--role", "desktop", "--board", "rpi4", "--env", "test",
                    "--superdomain", "snapdragon.internal",
                    "--standalone", "--local-user", "alice", "--encrypt-root"]


def test_rpi5_board_rpi3_composes_with_desktop_standalone():
    """--board rpi3 (Phase 8, DESKTOP-ONLY — the builder hard-errors on any
    other --role) must compose cleanly with the desktop role's --standalone/
    LUKS2 surface too, same as --board rpi4 above."""
    args = ImageConfig(mode="mesh", role="rpi5-desktop", platform="rpi5", tailscale=True,
                       board="rpi3", standalone=True, local_user="alice",
                       encrypt_root=True).to_cli_args()
    assert args == ["--role", "desktop", "--board", "rpi3", "--env", "test",
                    "--superdomain", "snapdragon.internal",
                    "--standalone", "--local-user", "alice", "--encrypt-root"]


def test_rpi5_generic_golden():
    """The plain-Gentoo unbranded arm64 server (the rpi5 builder's default role) —
    standalone mode (no tailnet) emits --skip-mesh; role passes through unmapped."""
    args = ImageConfig(mode="standalone", role="generic", platform="rpi5").to_cli_args()
    assert args == ["--role", "generic", "--env", "test", "--skip-mesh"]


def test_rpi5_generic_with_mesh_golden():
    args = ImageConfig(mode="standalone", role="generic", platform="rpi5",
                       tailscale=True).to_cli_args()
    assert args == ["--role", "generic", "--env", "test"]


def test_rpi5_never_emits_x86_only_flags():
    # --encrypt-root is genuinely NOT x86-only (rpi5/frite both support it) —
    # excluded from this list; see test_rpi5_frite_encryption_flags below.
    args = ImageConfig(mode="mesh", role="pki", platform="rpi5",
                       installer_ui="all", cached=True, desktop="thin",
                       steam="native").to_cli_args()
    for flag in ("--local-user", "--installer-ui", "--cached", "--uncached", "--desktop",
                 "--steam", "--with-tailscale", "--no-tailscale",
                 "--with-sso", "--no-sso", "--person-role", "--live-toram", "--bundle-source"):
        assert flag not in args


def test_rpi5_frite_encryption_flags():
    # --encrypt-root/--luks-pass landed on rpi5 (Phase 2b) and frite (Phase 2a).
    # jetson is EXCLUDED here — see test_jetson_encrypt_root_and_standalone_blocked
    # below: build-jetson-stage4.sh hard-blocks --encrypt-root unconditionally
    # (commit 92a847b), so this platform never reaches this flag combination.
    for platform, extra in (("rpi5", {"role": "pki"}), ("frite", {})):
        args = ImageConfig(mode="mesh", platform=platform,
                           encrypt_root=True, luks_pass="sekrit", **extra).to_cli_args()
        assert "--encrypt-root" in args
        assert ("--luks-pass", "sekrit") in pairs(args)


def test_jetson_encrypt_root_and_standalone_blocked():
    # build-jetson-stage4.sh hard-blocks --encrypt-root (and --standalone, which
    # forces it on) unconditionally: the Orin's single boot+root partition means
    # LUKS2-encrypting it leaves the UEFI firmware unable to find a kernel — see
    # docs/STANDALONE-DESKTOP.md's Jetson section. config.py must refuse to emit
    # this combination too (a real, permanent boot-chain limitation, not a
    # deferred gap this test should silently outlive).
    with pytest.raises(ValueError, match="jetson"):
        ImageConfig(mode="mesh", platform="jetson", encrypt_root=True, luks_pass="sekrit").to_cli_args()
    with pytest.raises(ValueError, match="jetson"):
        ImageConfig(mode="mesh", platform="jetson", role="desktop",
                    standalone=True, local_user="alice").to_cli_args()
    # bare jetson (no encrypt_root/standalone at all) is unaffected
    args = ImageConfig(mode="mesh", platform="jetson", role="edge_ai").to_cli_args()
    assert "--encrypt-root" not in args
    assert "--standalone" not in args


# ---- frite: arm64 client (board x flavor x desktop, no --role) ----------------

def test_frite_defaults_golden():
    # cloud mode + never-set tailscale ("" tri-state) resolves the mesh ON — the
    # mode default the GUI seeds — so NO --skip-mesh (a defaults-only cloud config
    # used to print a mesh-less client: the PR #304 verify-pass defect).
    args = ImageConfig(mode="cloud", role="frite", platform="frite").to_cli_args()
    assert args == ["--board", "la-frite", "--flavor", "both", "--env", "test"]


@pytest.mark.parametrize("board", ["la-frite", "le-potato", "sweet-potato"])
@pytest.mark.parametrize("flavor", ["live", "installer", "both"])
@pytest.mark.parametrize("desktop", ["light", "none"])
def test_frite_board_flavor_desktop_matrix(board, flavor, desktop):
    args = ImageConfig(mode="cloud", role="frite", platform="frite", tailscale=True,
                       board=board, flavor=flavor, desktop=desktop).to_cli_args()
    assert args == ["--board", board, "--flavor", flavor, "--desktop", desktop,
                    "--env", "test"]
    assert "--role" not in args


# ---- jetson: EXPERIMENTAL arm64 Tegra node (frite conventions + --role) -------

@pytest.mark.parametrize("role,builder_role",
                         [("edge_ai", "edge_ai"), ("full", "full"),
                          ("gpu-host", "gpu-host"), ("jetson-desktop", "desktop")])
def test_jetson_roles_golden(role, builder_role):
    args = ImageConfig(mode="mesh", role=role, platform="jetson", tailscale=True).to_cli_args()
    assert args == ["--role", builder_role, "--env", "test",
                    "--superdomain", "snapdragon.internal"]


def test_jetson_shared_arm_surface():
    args = ImageConfig(mode="mesh", role="edge_ai", platform="jetson", tailscale=False,
                       brand="acme", enable_wifi=True, img_size=8192,
                       compress=True, resume=True).to_cli_args()
    assert args == ["--role", "edge_ai", "--env", "test", "--brand", "acme",
                    "--superdomain", "acme.internal",
                    "--skip-mesh", "--enable-wifi", "--img-size", "8192",
                    "--compress", "--resume"]


@pytest.mark.parametrize("board", ["orin-nano", "orin-nano-4gb",
                                   "orin-nx-8gb", "orin-nx-16gb"])
def test_jetson_board_axis(board):
    args = ImageConfig(mode="mesh", role="edge_ai", platform="jetson", tailscale=True,
                       board=board).to_cli_args()
    assert args == ["--role", "edge_ai", "--board", board, "--env", "test",
                    "--superdomain", "snapdragon.internal"]


# ---- env threading (test|prod baked per channel) ------------------------------

@pytest.mark.parametrize("platform,role", [("x86", "omnibus"), ("rpi5", "pki"),
                                           ("frite", "frite"), ("jetson", "edge_ai")])
@pytest.mark.parametrize("env", ["test", "prod"])
def test_env_threads_through_every_platform(platform, role, env):
    args = ImageConfig(mode="mesh" if platform != "frite" else "cloud",
                       role=role, platform=platform, env=env).to_cli_args()
    assert ("--env", env) in pairs(args)


@pytest.mark.parametrize("env", ENV_CHOICES)
def test_env_threads_through_the_plain_gentoo_roles(env):
    """ENV_CHOICES backs the BuildPage env picker — both values must translate for
    the new plain-Gentoo arms exactly like every other role."""
    ua = ImageConfig(mode="standalone", role="standalone-unaffiliated", platform="x86",
                     env=env, bundle_source=False).to_cli_args()
    assert ("--env", env) in pairs(ua)
    gen = ImageConfig(mode="standalone", role="generic", platform="rpi5",
                      env=env).to_cli_args()
    assert ("--env", env) in pairs(gen)


# ---- GPU driver matrix (the HardwarePage combo mirrors the builder) ------------

def test_gpu_driver_choices_cover_the_builder_matrix():
    # build-x86-host-stage4.sh: --gpu-driver must be: all-free | nvidia-free |
    # nvidia | amd-free | amd-pro | intel-free | intel-pro | none ("auto" = the
    # Studio's don't-emit value, resolved by the builder per role).
    assert GPU_DRIVER_CHOICES == ("auto", "all-free", "nvidia-free", "nvidia",
                                  "amd-free", "amd-pro", "intel-free", "intel-pro", "none")
    # vendor aliases normalize INTO the canonical set and never appear in the combo
    for alias, canonical in GPU_DRIVER_ALIASES.items():
        assert canonical in GPU_DRIVER_CHOICES
        assert alias not in GPU_DRIVER_CHOICES


@pytest.mark.parametrize("driver", [d for d in GPU_DRIVER_CHOICES if d != "auto"])
def test_gpu_driver_matrix_emits_verbatim(driver):
    args = ImageConfig(mode="standalone", role="standalone-thick",
                       gpu_driver=driver).to_cli_args()
    assert ("--gpu-driver", driver) in pairs(args)


def test_gpu_driver_auto_emits_nothing():
    assert "--gpu-driver" not in ImageConfig(gpu_driver="auto").to_cli_args()


# ---- secrets: live command only, never persisted -------------------------------

def test_local_pass_reaches_command_but_never_json(tmp_path):
    cfg = ImageConfig(mode="standalone", role="standalone-thick",
                      local_pass="hunter2", luks_pass="tr0ub4dor")
    args = cfg.to_cli_args()
    assert ("--local-pass", "hunter2") in pairs(args)
    assert ("--luks-pass", "tr0ub4dor") in pairs(args)
    path = tmp_path / "cfg.json"
    warnings = cfg.save(str(path))
    assert len(warnings) == 2  # both secrets were set -> both flagged as not saved
    raw = json.loads(path.read_text(encoding="utf-8"))
    assert raw["local_pass"] == "" and raw["luks_pass"] == ""
    assert "hunter2" not in path.read_text(encoding="utf-8")
    reloaded = ImageConfig.load(str(path))
    assert reloaded.local_pass == "" and reloaded.luks_pass == ""
    assert "--local-pass" not in reloaded.to_cli_args()


def test_save_without_secrets_warns_nothing(tmp_path):
    path = tmp_path / "cfg.json"
    assert ImageConfig().save(str(path)) == []


def test_to_dict_secret_optin():
    cfg = ImageConfig(local_pass="x")
    assert cfg.to_dict()["local_pass"] == ""
    assert cfg.to_dict(include_secrets=True)["local_pass"] == "x"


# ---- extra-flags escape hatch ---------------------------------------------------

def test_extra_flags_shlex_split_appended_last():
    cfg = ImageConfig(mode="mesh", role="pki", platform="rpi5", tailscale=True,
                      extra_flags='--grow none --seed-url "http://mirror/x y"')
    args = cfg.to_cli_args()
    assert args[-4:] == ["--grow", "none", "--seed-url", "http://mirror/x y"]


def test_extra_flags_bad_quoting_raises():
    with pytest.raises(ValueError):
        ImageConfig(extra_flags='--foo "unclosed').to_cli_args()


# ---- round-trip / forward-compat -------------------------------------------------

def test_new_fields_round_trip(tmp_path):
    cfg = ImageConfig(mode="cloud", role="frite", platform="frite", board="le-potato",
                      flavor="live", desktop="light", steam="none",
                      optional_services=["tube"], enable_games=True,
                      encrypt_root=True, unlock_keyfile="login", unlock_yubikey="boot",
                      compress=True, resume=True, extra_flags="--skip-uboot")
    p = tmp_path / "c.json"
    cfg.save(str(p))
    r = ImageConfig.load(str(p))
    assert (r.platform, r.board, r.flavor, r.desktop) == ("frite", "le-potato", "live", "light")
    assert r.optional_services == ["tube"] and r.enable_games and r.encrypt_root
    assert (r.unlock_keyfile, r.unlock_yubikey) == ("login", "boot")
    assert r.compress and r.resume and r.extra_flags == "--skip-uboot"


def test_old_configs_without_platform_default_to_x86(tmp_path):
    p = tmp_path / "old.json"
    p.write_text(json.dumps({"mode": "standalone", "role": "standalone-thin"}), encoding="utf-8")
    cfg = ImageConfig.load(str(p))
    assert cfg.platform == "x86"
    assert cfg.builder_script == "build-x86-host-stage4.sh"


# ═══════════════════════════════════════════════════════════════════════════════
# WS1 gap coverage: new fields, per-platform emission, secret masking, and the
# machine-checked PLATFORM_FIELD_SUPPORT capability table (WS2/WS6 consume it).
# ═══════════════════════════════════════════════════════════════════════════════

# ---- G17: role-catalog reachability holes closed --------------------------------

def test_g17_rpi5_reachable_in_cloud_mode():
    flat = {(r, p) for r, plats, _ in ROLE_CHOICES["cloud"] for p in plats}
    assert ("rpi5-desktop", "rpi5") in flat


@pytest.mark.parametrize("role,plat", [("frite", "frite"), ("orangepi5", "orangepi5"),
                                       ("orangepizero2", "orangepizero2")])
def test_g17_arm_clients_reachable_in_standalone_mode(role, plat):
    flat = {(r, p) for r, plats, _ in ROLE_CHOICES["standalone"] for p in plats}
    assert (role, plat) in flat
    # and a standalone ARM build actually threads --standalone + FDE
    args = ImageConfig(mode="standalone", role=role, platform=plat, standalone=True,
                       local_user="alice", encrypt_root=True).to_cli_args()
    assert "--standalone" in args and "--encrypt-root" in args
    assert ("--local-user", "alice") in pairs(args)


# ---- G1: --cluster-domain is emitted (was a dead field on x86) -------------------

def test_g1_cluster_domain_emitted_for_x86_cloud_client():
    args = ImageConfig(mode="cloud", role="desktop", platform="x86", tailscale=True, sso=True,
                       cluster_domain="acme.example").to_cli_args()
    assert ("--cluster-domain", "acme.example") in pairs(args)


def test_g1_cluster_domain_emitted_for_x86_mesh_node():
    args = ImageConfig(mode="mesh", role="omnibus", platform="x86", tailscale=True, sso=True,
                       cluster_domain="acme.example").to_cli_args()
    assert ("--cluster-domain", "acme.example") in pairs(args)


def test_g1_cluster_domain_default_and_standalone_suppress():
    # default value is never emitted, and standalone (no cluster plane) never emits it
    assert "--cluster-domain" not in ImageConfig(mode="cloud", role="desktop",
                                                 platform="x86").to_cli_args()
    assert "--cluster-domain" not in ImageConfig(mode="standalone", role="standalone-thick",
                                                 platform="x86",
                                                 cluster_domain="acme.example").to_cli_args()


# ---- G18: explicit --person-role picker; node roles carry none ------------------

def test_g18_explicit_person_role_overrides_derivation():
    args = ImageConfig(mode="cloud", role="laptop", platform="x86", tailscale=True, sso=True,
                       person_role="admin").to_cli_args()
    assert ("--person-role", "admin") in pairs(args)


def test_g18_person_role_derives_from_users_in_cloud():
    args = ImageConfig(mode="cloud", role="desktop", platform="x86", tailscale=True, sso=True,
                       users=[User(username="jo", role="mod")]).to_cli_args()
    assert ("--person-role", "mod") in pairs(args)


def test_g18_client_role_still_emits_domains():
    args = ImageConfig(mode="cloud", role="desktop", platform="x86", tailscale=True, sso=True,
                       domains=[Domain(name="a.example"), Domain(name="b.example")]).to_cli_args()
    assert ("--domains", "a.example,b.example") in pairs(args)
    assert ("--person-role", "user") in pairs(args)


# ---- G3/G4/G6: brand profile / release-state / games-domain ---------------------

def test_g3_brand_profile_emits_config_on_every_platform():
    for plat, extra in (("x86", dict(role="desktop", mode="cloud")),
                        ("rpi5", dict(role="be", mode="mesh")),
                        ("frite", dict(role="frite", mode="cloud"))):
        args = ImageConfig(platform=plat, brand_profile="/tmp/brand.conf", **extra).to_cli_args()
        assert ("--config", "/tmp/brand.conf") in pairs(args)


def test_g4_release_state_x86_and_rpi5_only():
    x = ImageConfig(mode="mesh", role="omnibus", platform="x86", tailscale=True,
                    release_state="public").to_cli_args()
    assert ("--release-state", "public") in pairs(x)
    r = ImageConfig(mode="mesh", role="be", platform="rpi5", tailscale=True,
                    release_state="internal").to_cli_args()
    assert ("--release-state", "internal") in pairs(r)
    # frite does not parse it -> never emitted
    f = ImageConfig(mode="cloud", role="frite", platform="frite",
                    release_state="public").to_cli_args()
    assert "--release-state" not in f


def test_g6_games_domain_x86_and_rpi5():
    x = ImageConfig(mode="mesh", role="omnibus", platform="x86", tailscale=True,
                    games_domain="games.acme.example").to_cli_args()
    assert ("--games-domain", "games.acme.example") in pairs(x)
    r = ImageConfig(mode="mesh", role="fe", platform="rpi5", tailscale=True,
                    games_domain="games.acme.example").to_cli_args()
    assert ("--games-domain", "games.acme.example") in pairs(r)


# ---- G5: Secure Boot family (x86) -----------------------------------------------

def test_g5_secure_boot_tristate_and_keys():
    off = ImageConfig(mode="standalone", role="standalone-thick", secure_boot="off").to_cli_args()
    assert "--no-secure-boot" in off and "--secure-boot" not in off
    on = ImageConfig(mode="standalone", role="standalone-thick", secure_boot="on").to_cli_args()
    assert "--secure-boot" in on and "--no-secure-boot" not in on
    blank = ImageConfig(mode="standalone", role="standalone-thick").to_cli_args()
    assert "--secure-boot" not in blank and "--no-secure-boot" not in blank
    keys = ImageConfig(mode="standalone", role="standalone-thick", keys_usb="/mnt/keys",
                       secureboot_key="/k.pem", secureboot_cert="/c.pem").to_cli_args()
    p = pairs(keys)
    assert ("--keys-usb", "/mnt/keys") in p
    assert ("--secureboot-key", "/k.pem") in p and ("--secureboot-cert", "/c.pem") in p


def test_g5_secure_boot_never_on_arm():
    args = ImageConfig(mode="mesh", role="be", platform="rpi5", tailscale=True,
                       secure_boot="on", keys_usb="/mnt/keys").to_cli_args()
    for flag in ("--secure-boot", "--no-secure-boot", "--keys-usb"):
        assert flag not in args


# ---- G13/G14: none / all / exclude services semantics ---------------------------

def test_g13_explicit_none_services():
    args = ImageConfig(mode="mesh", role="omnibus", platform="x86", tailscale=True,
                       optional_services=[SERVICES_NONE]).to_cli_args()
    # EXPLICIT none: --optional-services "" (an empty argv element), not "no flag"
    i = args.index("--optional-services")
    assert args[i + 1] == ""


def test_g14_all_services_sentinel():
    args = ImageConfig(mode="mesh", role="omnibus", platform="x86", tailscale=True,
                       optional_services=[SERVICES_ALL]).to_cli_args()
    assert "--all-services" in args
    assert "--optional-services" not in args


def test_g14_exclude_services_subtractive():
    args = ImageConfig(mode="mesh", role="omnibus", platform="x86", tailscale=True,
                       optional_services=["akkoma", "tuwunel"],
                       exclude_services=["tuwunel"]).to_cli_args()
    assert ("--optional-services", "akkoma tuwunel") in pairs(args)
    assert ("--exclude-services", "tuwunel") in pairs(args)


def test_g13_empty_list_leaves_builder_default():
    args = ImageConfig(mode="mesh", role="omnibus", platform="x86", tailscale=True).to_cli_args()
    assert "--optional-services" not in args and "--all-services" not in args


# ---- G15: infra service slugs reachable on rpi5 (no dedicated flag there) --------

def test_g15_rpi5_infra_slugs_in_catalog():
    assert set(INFRA_SERVICES_CHOICES) <= set(OPTIONAL_SERVICES_BY_PLATFORM["rpi5"])
    # x86 keeps the dedicated flags; its catalog is the user-level set only
    assert "tor" not in OPTIONAL_SERVICES_BY_PLATFORM["x86"]


def test_g15_rpi5_tor_via_optional_services():
    args = ImageConfig(mode="mesh", role="fe", platform="rpi5", tailscale=True,
                       optional_services=["akkoma", "tor"]).to_cli_args()
    assert ("--optional-services", "akkoma tor") in pairs(args)


# ---- G21/G22: composable --capable and --unaffiliated ---------------------------

def test_g21_capable_composes_onto_any_client_role():
    args = ImageConfig(mode="cloud", role="laptop", platform="x86", tailscale=True, sso=True,
                       capable=True).to_cli_args()
    assert "--capable" in args


def test_g22_unaffiliated_composable_flag():
    args = ImageConfig(mode="standalone", role="standalone-thin", platform="x86",
                       unaffiliated=True).to_cli_args()
    assert "--unaffiliated" in args
    # composing unaffiliated suppresses the brand plane + bundle pair like the role does
    for flag in ("--brand", "--with-tailscale", "--no-tailscale", "--with-sso", "--no-sso",
                 "--bundle-source", "--no-bundle-source"):
        assert flag not in args


def test_g22_dedicated_role_does_not_double_emit_unaffiliated():
    # the role id presets it in the builder's own switch; no flag needed
    args = ImageConfig(mode="standalone", role="standalone-unaffiliated", platform="x86",
                       bundle_source=False).to_cli_args()
    assert "--unaffiliated" not in args


def test_g22_composable_unaffiliated_conflicts_with_cloud_mode():
    with pytest.raises(ValueError, match="unaffiliated"):
        ImageConfig(mode="cloud", role="laptop", platform="x86", tailscale=True,
                    unaffiliated=True).to_cli_args()


# ---- G23/G24: artifact selection ------------------------------------------------

def test_g23_x86_artifact_selection():
    args = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                       build_img="off", live_iso="on", installer_iso=True,
                       build_tar="off", skip_iso=True).to_cli_args()
    assert "--no-img" in args and "--live-iso" in args and "--installer-iso" in args
    assert "--no-tar" in args and "--skip-iso" in args


def test_g24_rpi5_artifact_selection():
    args = ImageConfig(mode="mesh", role="be", platform="rpi5", tailscale=True,
                       build_iso=True, sd_only=True, build_tar="off").to_cli_args()
    assert "--iso" in args and "--sd-only" in args and "--no-tar" in args


def test_g24_jetson_and_frite_artifacts():
    j = ImageConfig(mode="mesh", role="edge_ai", platform="jetson", tailscale=True,
                    build_img="off", image_only=True).to_cli_args()
    assert "--no-img" in j and "--image-only" in j
    f = ImageConfig(mode="cloud", role="frite", platform="frite", image_only=True).to_cli_args()
    assert "--image-only" in f
    # frite has no --img/--no-img/--iso
    for flag in ("--img", "--no-img", "--iso", "--sd-only"):
        assert flag not in f


# ---- G25/G26: grow + host identity ----------------------------------------------

@pytest.mark.parametrize("platform,role,mode", [("x86", "standalone-thick", "standalone"),
                                                ("rpi5", "be", "mesh"),
                                                ("frite", "frite", "cloud"),
                                                ("jetson", "edge_ai", "mesh")])
def test_g25_grow_on_every_platform(platform, role, mode):
    args = ImageConfig(mode=mode, role=role, platform=platform, grow="fill").to_cli_args()
    assert ("--grow", "fill") in pairs(args)


@pytest.mark.parametrize("platform,role,mode", [("x86", "standalone-thick", "standalone"),
                                                ("rpi5", "be", "mesh"),
                                                ("frite", "frite", "cloud")])
def test_g26_hostname_timezone_user(platform, role, mode):
    args = ImageConfig(mode=mode, role=role, platform=platform,
                       hostname="node01", timezone="America/New_York",
                       user="operator").to_cli_args()
    p = pairs(args)
    assert ("--hostname", "node01") in p
    assert ("--timezone", "America/New_York") in p
    assert ("--user", "operator") in p


def test_g26_bad_hostname_and_timezone_rejected():
    with pytest.raises(ValueError):
        ImageConfig(hostname="bad;host").to_cli_args()
    with pytest.raises(ValueError):
        ImageConfig(timezone="Region/$(evil)").to_cli_args()


# ---- G27/G28: node fallback creds (SECRET) + ARM local-user un-gating ------------

def test_g27_node_fallback_creds_secret_and_x86_only():
    args = ImageConfig(mode="mesh", role="omnibus", platform="x86", tailscale=True,
                       user_password="up", root_password="rp").to_cli_args()
    assert ("--user-password", "up") in pairs(args)
    assert ("--root-password", "rp") in pairs(args)
    # rpi5 does NOT get them (deprecated no-ops there)
    r = ImageConfig(mode="mesh", role="be", platform="rpi5", tailscale=True,
                    user_password="up", root_password="rp").to_cli_args()
    assert "--user-password" not in r and "--root-password" not in r


def test_g27_node_creds_never_persisted(tmp_path):
    cfg = ImageConfig(mode="mesh", role="omnibus", platform="x86", tailscale=True,
                      user_password="uPw7xQ", root_password="rPw9kL")
    path = tmp_path / "c.json"
    warnings = cfg.save(str(path))
    assert len(warnings) == 2
    raw = json.loads(path.read_text(encoding="utf-8"))
    assert raw["user_password"] == "" and raw["root_password"] == ""
    blob = path.read_text(encoding="utf-8")
    assert "uPw7xQ" not in blob and "rPw9kL" not in blob


def test_secret_fields_include_node_creds():
    assert set(SECRET_FIELDS) == {"local_pass", "luks_pass", "user_password", "root_password"}


def test_g28_arm_local_user_without_standalone():
    # renamed account, no --standalone
    args = ImageConfig(mode="mesh", role="be", platform="rpi5", tailscale=True,
                       local_user="alice", local_pass="pw").to_cli_args()
    assert ("--local-user", "alice") in pairs(args)
    assert ("--local-pass", "pw") in pairs(args)
    assert "--standalone" not in args
    # default account name with no password + no standalone stays quiet (existing goldens)
    quiet = ImageConfig(mode="mesh", role="be", platform="rpi5", tailscale=True).to_cli_args()
    assert "--local-user" not in quiet


# ---- G29/G30: version pins + image stamps ---------------------------------------

@pytest.mark.parametrize("platform,role,mode", [("x86", "omnibus", "mesh"),
                                                ("rpi5", "be", "mesh"),
                                                ("frite", "frite", "cloud")])
def test_g29_version_pins_and_skip_tailscale(platform, role, mode):
    args = ImageConfig(mode=mode, role=role, platform=platform, tailscale=True,
                       headscale_version="0.23.0", tailscale_version="1.62.0",
                       skip_tailscale=True).to_cli_args()
    p = pairs(args)
    assert ("--headscale-version", "0.23.0") in p
    assert ("--tailscale-version", "1.62.0") in p
    assert "--skip-tailscale" in args


def test_g30_version_all_release_tag_x86_only():
    x = ImageConfig(mode="mesh", role="omnibus", platform="x86", tailscale=True,
                    version="2026.07", release_tag="rc1").to_cli_args()
    assert ("--version", "2026.07") in pairs(x)
    assert ("--release-tag", "rc1") in pairs(x)
    r = ImageConfig(mode="mesh", role="be", platform="rpi5", tailscale=True,
                    version="2026.07", release_tag="rc1").to_cli_args()
    assert ("--version", "2026.07") in pairs(r)
    assert "--release-tag" not in r


# ---- G31/G32/G33: home extras / media / cuda+grub-theme (x86) --------------------

def test_g31_home_extras():
    args = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                       home_seed_code_from="/seed", include_home_archive="/home.tar",
                       seed_packages_from="/pkgs.txt").to_cli_args()
    p = pairs(args)
    assert ("--home-seed-code-from", "/seed") in p
    assert ("--include-home-archive", "/home.tar") in p
    assert ("--seed-packages-from", "/pkgs.txt") in p


def test_g32_media_data_set():
    off = ImageConfig(mode="standalone", role="standalone-thick",
                      media_data="off", no_vaults=True, media_label="DATA").to_cli_args()
    assert "--no-media-data" in off and "--no-vaults" in off
    assert ("--media-label", "DATA") in pairs(off)
    on = ImageConfig(mode="standalone", role="standalone-thick", media_data="on").to_cli_args()
    assert "--media-data" in on


def test_g33_nvidia_cuda_and_grub_theme():
    args = ImageConfig(mode="standalone", role="standalone-thick",
                       nvidia_cuda=True, grub_theme="/themes/snap").to_cli_args()
    assert "--nvidia-cuda" in args
    assert ("--grub-theme", "/themes/snap") in pairs(args)


# ---- G34: force-off tri-states --------------------------------------------------

def test_g34_force_off_tristates():
    args = ImageConfig(mode="mesh", role="omnibus", platform="x86", tailscale=True,
                       aide="off", tor_onion_service="off",
                       character_studio="off", edge_ai_service="off").to_cli_args()
    assert "--no-aide" in args
    assert "--no-tor" in args
    assert "--no-character-studio" in args
    assert "--no-edge-ai" in args


def test_g34_tristate_bool_backcompat():
    # a plain True still means the positive path (checkbox back-compat)
    args = ImageConfig(mode="mesh", role="omnibus", platform="x86", tailscale=True,
                       aide=True, tor_onion_service=True, character_studio=True).to_cli_args()
    assert "--with-aide" in args and "--with-tor" in args and "--with-character-studio" in args


def test_g34_rpi5_force_off_character_studio():
    args = ImageConfig(mode="mesh", role="be", platform="rpi5", tailscale=True,
                       character_studio="off").to_cli_args()
    assert "--no-character-studio" in args


# ---- edge-ai-tts: independent tri-state, NO edge-ai dependency ------------------

def test_edge_ai_tts_x86_no_edge_ai_coupling():
    """edge_ai_tts is CPU-only + self-contained — UNLIKE edge_ai_analysis it must
    NOT fold 'edge-ai' in, even though it lives in the same Edge-AI GUI grouping."""
    args = ImageConfig(mode="mesh", role="omnibus", platform="x86", tailscale=True,
                       edge_ai_tts=True).to_cli_args()
    assert "--with-edge-ai-tts" in args
    assert "--with-edge-ai" not in args
    assert "--with-edge-ai-analysis" not in args


def test_edge_ai_tts_rpi5_emits():
    args = ImageConfig(mode="mesh", role="be", platform="rpi5", tailscale=True,
                       edge_ai_tts=True).to_cli_args()
    assert "--with-edge-ai-tts" in args


def test_edge_ai_tts_force_off():
    args = ImageConfig(mode="mesh", role="omnibus", platform="x86", tailscale=True,
                       edge_ai_tts="off").to_cli_args()
    assert "--no-edge-ai-tts" in args


# ---- G35/G36/G37: u-boot / jetson kernel-flavor / ARM kernel-board overrides -----

@pytest.mark.parametrize("platform,role", [("frite", "frite"), ("orangepi5", "orangepi5"),
                                           ("orangepizero2", "orangepizero2")])
def test_g35_uboot_chain(platform, role):
    args = ImageConfig(mode="cloud", role=role, platform=platform,
                       uboot_url="http://x/u.bin", uboot_defconfig="foo_defconfig",
                       skip_uboot=False).to_cli_args()
    assert ("--uboot-url", "http://x/u.bin") in pairs(args)
    assert ("--uboot-defconfig", "foo_defconfig") in pairs(args)
    skip = ImageConfig(mode="cloud", role=role, platform=platform, skip_uboot=True).to_cli_args()
    assert "--skip-uboot" in skip


def test_g35_uboot_never_on_rpi5_or_jetson():
    for platform, role, mode in (("rpi5", "be", "mesh"), ("jetson", "edge_ai", "mesh")):
        args = ImageConfig(mode=mode, role=role, platform=platform, tailscale=True,
                           uboot_url="http://x").to_cli_args()
        assert "--uboot-url" not in args


def test_g36_jetson_kernel_flavor():
    args = ImageConfig(mode="mesh", role="edge_ai", platform="jetson", tailscale=True,
                       kernel_flavor="l4t").to_cli_args()
    assert ("--kernel-flavor", "l4t") in pairs(args)
    # not a jetson-only leak: rpi5 never emits it
    r = ImageConfig(mode="mesh", role="be", platform="rpi5", tailscale=True,
                    kernel_flavor="l4t").to_cli_args()
    assert "--kernel-flavor" not in r


def test_g37_arm_kernel_board_overrides():
    # shared -c/-d on every ARM builder
    for platform, role, mode in (("rpi5", "be", "mesh"), ("frite", "frite", "cloud"),
                                 ("jetson", "edge_ai", "mesh")):
        a = ImageConfig(mode=mode, role=role, platform=platform, tailscale=True,
                        cpu="cortex-a53", defconfig="foo_defconfig").to_cli_args()
        assert ("--cpu", "cortex-a53") in pairs(a)
        assert ("--defconfig", "foo_defconfig") in pairs(a)
    # rpi5-only --dtb-prefix / --kernel-img / --pcie-gen3
    r = ImageConfig(mode="mesh", role="be", platform="rpi5", tailscale=True,
                    dtb_prefix="bcm2712", kernel_img="Image", pcie_gen3=True).to_cli_args()
    assert ("--dtb-prefix", "bcm2712") in pairs(r) and ("--kernel-img", "Image") in pairs(r)
    assert "--pcie-gen3" in r
    # --dtb on frite/jetson/opi5/opz2 (rpi5 uses --dtb-prefix instead)
    f = ImageConfig(mode="cloud", role="frite", platform="frite", dtb="foo.dtb").to_cli_args()
    assert ("--dtb", "foo.dtb") in pairs(f)
    assert "--dtb" not in r


# ---- G38: build plumbing --------------------------------------------------------

def test_g38_shared_plumbing_on_x86_and_arm():
    x = ImageConfig(mode="mesh", role="omnibus", platform="x86", tailscale=True,
                    skip_kernel=True, skip_clean=True, build_subdir="sub",
                    seed_url="http://s", distdir="/dist").to_cli_args()
    assert "--skip-kernel" in x and "--skip-clean" in x
    assert ("--build-subdir", "sub") in pairs(x) and ("--seed-url", "http://s") in pairs(x)
    assert ("--distdir", "/dist") in pairs(x)
    a = ImageConfig(mode="mesh", role="be", platform="rpi5", tailscale=True,
                    skip_kernel=True, extra_packages="app-editors/vim").to_cli_args()
    assert "--skip-kernel" in a
    assert ("--extra-packages", "app-editors/vim") in pairs(a)
    # -p/--extra-packages is ARM-only; --distdir is x86-only
    assert "--extra-packages" not in x and "--distdir" not in a


# ---- G2/G40/G41: out-of-band fields never reach argv ----------------------------

def test_g2_g40_g41_never_argv():
    cfg = ImageConfig(mode="mesh", role="omnibus", platform="x86", tailscale=True,
                      headscale_url="https://hs.acme", pentest=True, hw_profile="framework-13")
    args = cfg.to_cli_args()
    for token in ("https://hs.acme", "framework-13", "--pentest", "--headscale-url",
                  "--hw-profile", "--pentest=1"):
        assert token not in args


def test_non_argv_fields_set():
    # headscale_url/pentest/hw_profile stay out-of-band (env passthrough / fleet knob /
    # GUI preset). superdomain STARTED here (v1 = manifest + KEYS channel) but WS-SUPER-B
    # flipped it to an emitted --superdomain (mesh-only), so it is NO LONGER here — like
    # packages_add/packages_drop (WS-BUILDER), it now lives in PLATFORM_FIELD_SUPPORT.
    # login_* (web login theme) follow the headscale_url precedent: cluster-plane data
    # carried as SNAP_THEME_CSS env / brands yaml, emitted by NO builder argv — the
    # login-ui is a Deployment the mesh SERVES, not desktop-image bytes.
    assert set(NON_ARGV_FIELDS) == {
        "headscale_url", "pentest", "hw_profile",
        "login_primary_color", "login_secondary_color", "login_font",
        "login_font_file", "login_font_licence", "login_font_source"}
    # and none of them appear in the capability table (they are not "silently dropped")
    for f in NON_ARGV_FIELDS:
        assert f not in PLATFORM_FIELD_SUPPORT
    # superdomain + extra_packages + the now-emitted packages_add/packages_drop are
    # DIFFERENT, emitted fields — all must be in the table, none in the out-of-band set.
    for f in ("superdomain", "extra_packages", "packages_add", "packages_drop"):
        assert f in PLATFORM_FIELD_SUPPORT and f not in NON_ARGV_FIELDS


# ═══════════════════════════════════════════════════════════════════════════════
# PLATFORM_FIELD_SUPPORT — asserted against REAL emission so it cannot drift.
# A field is "supported" on a platform iff setting it changes that platform's argv.
# ═══════════════════════════════════════════════════════════════════════════════

_PROBE_PLATFORMS = ("x86", "rpi5", "frite", "jetson", "orangepi5", "orangepizero2")

# baseline valid config per platform, chosen so every field that CAN emit does emit
# (x86 uses a cloud CLIENT role so the cluster/person plane is live).
_BASELINES = {
    "x86": dict(mode="cloud", role="desktop", platform="x86"),
    "rpi5": dict(mode="mesh", role="be", platform="rpi5"),
    "frite": dict(mode="cloud", role="frite", platform="frite"),
    "jetson": dict(mode="mesh", role="edge_ai", platform="jetson"),
    "orangepi5": dict(mode="cloud", role="orangepi5", platform="orangepi5"),
    "orangepizero2": dict(mode="cloud", role="orangepizero2", platform="orangepizero2"),
}

# field -> overrides that make a supporting builder's argv change. Multi-key entries
# supply a prerequisite (e.g. egress_vpn_locked needs egress_vpn). "unaffiliated" is
# probed separately (it needs a standalone baseline). Everything else in the table is
# here — a coverage assertion below guarantees that.
_FIELD_PROBE = {
    "brand": {"brand": "acme"}, "brand_title": {"brand_title": "Acme Co"},
    "org": {"org": "Acme-Org"}, "brand_profile": {"brand_profile": "/tmp/brand.conf"},
    "hostname": {"hostname": "myhost"}, "timezone": {"timezone": "America/New_York"},
    "user": {"user": "bob"},
    "cluster_domain": {"cluster_domain": "acme.example"},
    "games_domain": {"games_domain": "games.acme.example"},
    "release_state": {"release_state": "public"}, "person_role": {"person_role": "admin"},
    "domains": {"domains": [Domain(name="probe.example")]},
    "local_user": {"local_user": "alice"}, "local_pass": {"local_pass": "pw"},
    "user_password": {"user_password": "pw"}, "root_password": {"root_password": "pw"},
    "standalone": {"standalone": True}, "capable": {"capable": True},
    # tailscale/sso are MODE-AWARE tri-states: the cloud/mesh baselines resolve
    # the never-set "" to ON, so probing True would be a no-op — probe the
    # EXPLICIT False (the GUI's unchecked box), which flips every supporting
    # platform's emission (--no-tailscale/--no-sso on x86; --skip-mesh on ARM).
    "tailscale": {"tailscale": False}, "sso": {"sso": False},
    "headscale_version": {"headscale_version": "0.23"},
    "tailscale_version": {"tailscale_version": "1.60"},
    "skip_tailscale": {"skip_tailscale": True},
    "gpu_driver": {"gpu_driver": "nvidia"}, "nvidia_cuda": {"nvidia_cuda": True},
    "kernel_builtin": {"kernel_builtin": True},
    "enable_wifi": {"enable_wifi": True}, "enable_bluetooth": {"enable_bluetooth": True},
    "theme": {"theme": "boogiepop"}, "branding_dir": {"branding_dir": "/tmp/b"},
    "wallpaper": {"wallpaper": "/tmp/w.png"}, "grub_background": {"grub_background": "/tmp/g.png"},
    "grub_theme": {"grub_theme": "/tmp/gt"}, "login_background": {"login_background": "/tmp/l.png"},
    "brand_logo": {"brand_logo": "/tmp/logo.png"}, "accent_color": {"accent_color": "#123456"},
    "color_scheme": {"color_scheme": "dark"}, "brand_locked": {"brand_locked": True},
    "egress_vpn": {"egress_vpn": "/tmp/e.ovpn"},
    "egress_vpn_locked": {"egress_vpn": "/tmp/e.ovpn", "egress_vpn_locked": True},
    "proxy_stack": {"proxy_stack": "on"}, "snort": {"snort": False}, "aide": {"aide": True},
    "root_login": {"root_login": "yes"},
    "edge_ai_service": {"edge_ai_service": True},
    "edge_ai_runtime": {"edge_ai_service": True, "edge_ai_runtime": "vllm"},
    "edge_ai_models": {"edge_ai_service": True, "edge_ai_models": "llama3"},
    "edge_ai_model_default": {"edge_ai_service": True, "edge_ai_model_default": "llama3"},
    "edge_ai_analysis": {"edge_ai_analysis": True},
    "edge_ai_tts": {"edge_ai_tts": True},
    "tor_onion_service": {"tor_onion_service": True},
    "character_studio": {"character_studio": True},
    "optional_services": {"optional_services": ["akkoma"]},
    "exclude_services": {"exclude_services": ["games"]},
    "enable_games": {"enable_games": True},
    "desktop": {"desktop": "thin"}, "steam": {"steam": "native"},
    "media_data": {"media_data": "off"}, "media_label": {"media_label": "DATA"},
    "no_vaults": {"no_vaults": True},
    "encrypt_root": {"encrypt_root": True}, "luks_pass": {"luks_pass": "pw"},
    "unlock_keyfile": {"unlock_keyfile": "boot"}, "unlock_yubikey": {"unlock_yubikey": "login"},
    "secure_boot": {"secure_boot": "off"}, "keys_usb": {"keys_usb": "/tmp/keys"},
    "secureboot_key": {"secureboot_key": "/tmp/k.pem"},
    "secureboot_cert": {"secureboot_cert": "/tmp/c.pem"},
    "home_mode": {"home_mode": "adopt"}, "home_device": {"home_device": "LABEL=HOME"},
    "home_backup": {"home_backup": "auto"}, "home_encrypted": {"home_encrypted": True},
    "home_seed_code": {"home_seed_code": "repos"},
    "home_seed_code_from": {"home_seed_code_from": "/tmp/seed"},
    "include_home_archive": {"include_home_archive": "/tmp/home.tar"},
    "seed_packages_from": {"seed_packages_from": "/tmp/pkgs"},
    "installer_ui": {"installer_ui": "cli"}, "cached": {"cached": True},
    "live_toram": {"live_toram": False}, "bundle_source": {"bundle_source": False},
    "build_img": {"build_img": "off"}, "live_iso": {"live_iso": "on"},
    "installer_iso": {"installer_iso": True}, "build_tar": {"build_tar": "off"},
    "skip_iso": {"skip_iso": True}, "build_iso": {"build_iso": True},
    "sd_only": {"sd_only": True}, "image_only": {"image_only": True},
    "grow": {"grow": "fill"}, "img_size": {"img_size": 4096},
    "compress": {"compress": True}, "resume": {"resume": True},
    "cpu": {"cpu": "cortex-a53"}, "defconfig": {"defconfig": "foo_defconfig"},
    "dtb": {"dtb": "foo.dtb"}, "dtb_prefix": {"dtb_prefix": "bcm2712"},
    "kernel_img": {"kernel_img": "Image"}, "pcie_gen3": {"pcie_gen3": True},
    "kernel_flavor": {"kernel_flavor": "l4t"},
    "uboot_url": {"uboot_url": "http://x/u.bin"},
    "uboot_defconfig": {"uboot_defconfig": "foo_defconfig"}, "skip_uboot": {"skip_uboot": True},
    "skip_kernel": {"skip_kernel": True}, "skip_clean": {"skip_clean": True},
    "distdir": {"distdir": "/tmp/dist"}, "build_subdir": {"build_subdir": "sub"},
    "seed_url": {"seed_url": "http://s/x"}, "version": {"version": "1.2.3"},
    "release_tag": {"release_tag": "rc1"}, "extra_packages": {"extra_packages": "app-editors/vim"},
    "packages_add": {"packages_add": "app-editors/vim"},
    "packages_drop": {"packages_drop": "app-editors/vim"},
}


def _emits(platform, overrides):
    """True iff applying ``overrides`` changes this platform's emitted argv. A raised
    ValueError (a rejected combination, e.g. encrypt-root on jetson) counts as 'the
    flag never reaches the builder' -> not supported."""
    base = _BASELINES[platform]
    before = ImageConfig(**base).to_cli_args()
    try:
        after = ImageConfig(**{**base, **overrides}).to_cli_args()
    except ValueError:
        return False
    return before != after


def test_field_probe_covers_the_whole_capability_table():
    # `unaffiliated` (needs a standalone baseline) and `superdomain` (mesh-only gate,
    # so the mixed cloud/mesh baselines can't isolate it) are each probed by a dedicated
    # test below instead of the shared before/after differ.
    assert set(_FIELD_PROBE) | {"unaffiliated", "superdomain"} == set(PLATFORM_FIELD_SUPPORT)


@pytest.mark.parametrize("field", sorted(_FIELD_PROBE))
def test_platform_field_support_matches_emission(field):
    derived = {p for p in _PROBE_PLATFORMS if _emits(p, _FIELD_PROBE[field])}
    assert derived == set(PLATFORM_FIELD_SUPPORT[field]), (
        f"{field}: table says {sorted(PLATFORM_FIELD_SUPPORT[field])} "
        f"but emission says {sorted(derived)}")


def test_platform_field_support_unaffiliated_is_x86_only():
    assert set(PLATFORM_FIELD_SUPPORT["unaffiliated"]) == {"x86"}
    # composable on a standalone x86 role; ignored on ARM
    assert "--unaffiliated" in ImageConfig(mode="standalone", role="standalone-thin",
                                           platform="x86", unaffiliated=True).to_cli_args()
    assert "--unaffiliated" not in ImageConfig(mode="mesh", role="be", platform="rpi5",
                                               tailscale=True, unaffiliated=True).to_cli_args()


# a valid mesh (role, platform) per builder — the shared cloud/mesh baselines can't be
# reused because superdomain emits ONLY in mesh mode (WS-SUPER-B).
_MESH_ROLE = {"x86": "omnibus", "rpi5": "be", "frite": "frite", "jetson": "edge_ai",
              "orangepi5": "orangepi5", "orangepizero2": "orangepizero2"}


def test_platform_field_support_superdomain_is_all_platforms_mesh_gated():
    """superdomain sits in PLATFORM_FIELD_SUPPORT as _ALL_PLATFORMS, but its emission is
    mesh-gated (the orchestration plane; not a standalone/cloud concept), so it can't be
    verified by the shared cloud/mesh differ. Prove directly: every builder threads the
    EFFECTIVE value in mesh mode, and it is absent for a standalone build on that same
    platform."""
    assert set(PLATFORM_FIELD_SUPPORT["superdomain"]) == set(_PROBE_PLATFORMS)
    for platform in _PROBE_PLATFORMS:
        mesh = ImageConfig(mode="mesh", role=_MESH_ROLE[platform], platform=platform,
                           tailscale=True, brand="acme").to_cli_args()
        assert ("--superdomain", "acme.internal") in pairs(mesh), platform
    # standalone (any supporting platform) carries NO orchestration plane
    for platform in ("x86", "rpi5", "frite"):
        role = {"x86": "standalone-thick", "rpi5": "rpi5-desktop", "frite": "frite"}[platform]
        sa = ImageConfig(mode="standalone", role=role, platform=platform,
                         standalone=True, brand="acme").to_cli_args()
        assert "--superdomain" not in sa, platform


def test_capability_table_platforms_are_all_known():
    for field, plats in PLATFORM_FIELD_SUPPORT.items():
        for p in plats:
            assert p in BUILDER_SCRIPTS, f"{field} references unknown platform {p}"


# ═══════════════════════════════════════════════════════════════════════════════
# WS-CORE redesign: superdomain, packages_add/drop, Domain.images + games migration,
# the load() envelope guard, and the role-class capability layer (§2.1/§2.2/§2.6).
# ═══════════════════════════════════════════════════════════════════════════════

# ---- superdomain: field + derivation + round-trip + manifest --------------------

def test_superdomain_derivation_and_explicit():
    # "" derives <brand>.internal; an explicit value wins
    assert ImageConfig().effective_superdomain() == "snapdragon.internal"
    assert ImageConfig(brand="acme").effective_superdomain() == "acme.internal"
    assert ImageConfig(brand="acme", superdomain="mesh.acme.internal"
                       ).effective_superdomain() == "mesh.acme.internal"


def test_superdomain_emitted_for_mesh_absent_for_standalone():
    # WS-SUPER-B: --superdomain <effective> is baked into every MESH image (the
    # orchestration plane); an explicit value wins over the derived <brand>.internal.
    # A standalone image joins no plane, so it carries nothing.
    for kw in (dict(mode="mesh", role="omnibus", platform="x86", tailscale=True, sso=True),
               dict(mode="mesh", role="be", platform="rpi5", tailscale=True)):
        args = ImageConfig(superdomain="acme.internal", **kw).to_cli_args()
        assert ("--superdomain", "acme.internal") in pairs(args)
        assert "--super-domain" not in args     # never the misspelled alias
    # derived value when the field is "" (brand=acme -> acme.internal)
    derived = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                          tailscale=True, sso=True).to_cli_args()
    assert ("--superdomain", "acme.internal") in pairs(derived)
    # standalone (no orchestration plane) never emits it, even if a value is set
    sa = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                     superdomain="acme.internal").to_cli_args()
    assert "--superdomain" not in sa


def test_superdomain_round_trip_and_manifest(tmp_path):
    cfg = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                      superdomain="core.acme.internal")
    p = tmp_path / "c.json"
    cfg.save(str(p))
    r = ImageConfig.load(str(p))
    assert r.superdomain == "core.acme.internal"
    assert r.effective_superdomain() == "core.acme.internal"
    # the manifest carries the effective superdomain (derived when "")
    assert cfg.mesh_manifest()["superdomain"] == "core.acme.internal"
    assert ImageConfig(brand="acme").mesh_manifest()["superdomain"] == "acme.internal"


def test_superdomain_internal_suffix_accepted_by_validate_identity():
    # .internal must validate — the whole v1 depends on <brand>.internal being legal
    ImageConfig(mode="mesh", role="omnibus", platform="x86",
                superdomain="snapdragon.internal").to_cli_args()   # must not raise


def test_superdomain_injection_rejected():
    with pytest.raises(ValueError):
        ImageConfig(superdomain="x;reboot.internal").to_cli_args()


# ---- packages_add / packages_drop: EMITTED flags + round-trip + atom regex -----

def test_packages_add_drop_reach_argv():
    # WS-BUILDER Phase 2: packages_add/packages_drop now emit --packages-add /
    # --packages-drop as one argv element each (space-separated atom string), on
    # EVERY platform (all six builders parse them identically).
    for plat, extra in (("x86", dict(mode="mesh", role="omnibus", tailscale=True, sso=True)),
                        ("rpi5", dict(mode="mesh", role="be", tailscale=True)),
                        ("frite", dict(mode="cloud", role="frite")),
                        ("jetson", dict(mode="mesh", role="edge_ai")),
                        ("orangepi5", dict(mode="cloud", role="orangepi5")),
                        ("orangepizero2", dict(mode="cloud", role="orangepizero2"))):
        args = ImageConfig(platform=plat, packages_add="app-editors/vim app-misc/tmux",
                           packages_drop="games-util/steam", **extra).to_cli_args()
        assert ("--packages-add", "app-editors/vim app-misc/tmux") in pairs(args)
        assert ("--packages-drop", "games-util/steam") in pairs(args)


def test_packages_add_drop_empty_emit_nothing():
    # byte-identity (I1): defaults ("") emit NEITHER flag on any platform, so every
    # existing flat config's argv is unchanged by the flip.
    for plat, extra in (("x86", dict(mode="mesh", role="omnibus", tailscale=True, sso=True)),
                        ("rpi5", dict(mode="mesh", role="be", tailscale=True))):
        args = ImageConfig(platform=plat, **extra).to_cli_args()
        assert "--packages-add" not in args and "--packages-drop" not in args


def test_packages_add_drop_round_trip(tmp_path):
    cfg = ImageConfig(mode="mesh", role="be", platform="rpi5",
                      packages_add="app-editors/vim dev-vcs/git",
                      packages_drop="games-util/steam")
    p = tmp_path / "c.json"
    cfg.save(str(p))
    r = ImageConfig.load(str(p))
    assert r.packages_add == "app-editors/vim dev-vcs/git"
    assert r.packages_drop == "games-util/steam"


@pytest.mark.parametrize("atoms", [
    "",                                   # empty = no packages
    "app-editors/vim",
    "app-editors/vim app-misc/tmux dev-vcs/git",
    "sys-fs/ecryptfs-utils sys-apps/keyutils",
    "dev-libs/libFoo",                    # package name may carry caps
    "virtual/foo x11-libs/gtk+3",         # '+' is legal in an atom
    "cat.d/pkg_1.2",                      # '.' and '_' legal
])
def test_validate_package_atoms_accepts(atoms):
    ImageConfig(packages_add=atoms, packages_drop=atoms).to_cli_args()   # must not raise


@pytest.mark.parametrize("bad", [
    "vim",                                # no category/name slash
    "app-editors/vim; reboot",            # shell metacharacter
    "app-editors/vim && curl evil|sh",
    "$(reboot)/x",
    "app-editors/",                       # empty package name
    "/vim",                               # empty category
    "app editors/vim",                    # space inside an atom (would split into 'app' + 'editors/vim')
    "App-Editors/vim",                    # uppercase category not allowed
    "app-editors/vim`id`",
])
def test_validate_package_atoms_rejects(bad):
    with pytest.raises(ValueError):
        ImageConfig(packages_add=bad).to_cli_args()
    with pytest.raises(ValueError):
        ImageConfig(packages_drop=bad).to_cli_args()


def test_extra_packages_kept_frozen_and_separate_from_packages_add():
    # extra_packages STILL emits --extra-packages on ARM (frozen, unchanged);
    # packages_add is now a SEPARATE emitted flag (--packages-add), never merged.
    args = ImageConfig(mode="mesh", role="be", platform="rpi5", tailscale=True,
                       extra_packages="app-editors/vim",
                       packages_add="app-misc/tmux").to_cli_args()
    assert ("--extra-packages", "app-editors/vim") in pairs(args)
    assert ("--packages-add", "app-misc/tmux") in pairs(args)
    # two distinct flags, not concatenated into one
    assert "--extra-packages" in args and "--packages-add" in args


# ---- Domain.images round-trip + legacy games -> optional_services migration ------

def test_domain_images_round_trip(tmp_path):
    cfg = ImageConfig(mode="mesh", role="omnibus", platform="x86",
                      domains=[Domain(name="a.example", title="A",
                                      images=["omnibus.x86", "be.rpi5"]),
                               Domain(name="b.example")])
    p = tmp_path / "c.json"
    cfg.save(str(p))
    r = ImageConfig.load(str(p))
    assert r.domains[0].images == ["omnibus.x86", "be.rpi5"]
    assert r.domains[1].images == []


def test_domain_has_no_games_field():
    assert "games" not in Domain.__dataclass_fields__
    assert "images" in Domain.__dataclass_fields__
    with pytest.raises(TypeError):
        Domain(name="x", games=True)     # the field is gone


def test_legacy_domain_games_migrates_to_optional_services():
    # a legacy save with games:true -> optional_services gains "games" (never dropped)
    cfg = ImageConfig.from_dict({"mode": "mesh", "role": "omnibus",
                                 "domains": [{"name": "a.example", "games": True,
                                              "optional_services": ["akkoma"]}]})
    assert cfg.domains[0].optional_services == ["akkoma", "games"]
    assert not hasattr(cfg.domains[0], "games")


def test_legacy_domain_games_no_duplicate_and_false_ignored():
    # games:true already listed -> no duplicate; games:false -> no-op
    dup = ImageConfig.from_dict({"domains": [{"name": "a", "games": True,
                                              "optional_services": ["games", "tube"]}]})
    assert dup.domains[0].optional_services == ["games", "tube"]
    off = ImageConfig.from_dict({"domains": [{"name": "b", "games": False}]})
    assert off.domains[0].optional_services == []


def test_domain_games_migration_is_load_level(tmp_path):
    # an old on-disk save with the games key still loads and migrates
    p = tmp_path / "old.json"
    p.write_text(json.dumps({"mode": "mesh", "role": "omnibus",
                             "domains": [{"name": "a.example", "games": True}]}),
                 encoding="utf-8")
    cfg = ImageConfig.load(str(p))
    assert cfg.domains[0].optional_services == ["games"]


# ---- User.registration: additive manifest-only field (round-trip + forward-compat) --

def test_user_registration_round_trip_and_manifest(tmp_path):
    # The additive `registration` User field (first-login method: "" = derive | discord |
    # gmail | password) is MANIFEST-ONLY provisioning data (never argv). It must survive
    # BOTH emission paths — mesh_manifest() and to_dict() (the --print-specs surface) —
    # round-trip through from_dict(to_dict()) + save/load, default to "" when absent, and
    # from_dict must tolerate + DROP an unknown FUTURE user key without losing it.
    cfg = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                      users=[User(username="ada", domain="a.acme", role="admin",
                                  email="ada@a.acme", registration="gmail"),
                             User(username="bob", domain="a.acme")])
    # 1) reaches mesh_manifest()["users"][0]; absent -> "" default
    assert cfg.mesh_manifest()["users"][0]["registration"] == "gmail"
    assert cfg.mesh_manifest()["users"][1]["registration"] == ""
    # 2) reaches to_dict()["users"][0] (carried to --print-specs)
    assert cfg.to_dict()["users"][0]["registration"] == "gmail"
    assert cfg.to_dict()["users"][1]["registration"] == ""
    # 3) round-trips through from_dict(to_dict()) and through an on-disk save/load
    r = ImageConfig.from_dict(cfg.to_dict())
    assert r.users[0].registration == "gmail"
    assert r.users[1].registration == ""
    p = tmp_path / "c.json"
    cfg.save(str(p))
    assert ImageConfig.load(str(p)).users[0].registration == "gmail"


def test_user_registration_from_dict_drops_unknown_future_key():
    # forward-compat: an unknown future user key is tolerated + DROPPED (matching the
    # nested from_dict filter), while a known `registration` is preserved.
    cfg = ImageConfig.from_dict({"mode": "mesh", "role": "omnibus",
                                 "users": [{"username": "cid", "registration": "discord",
                                            "future_unknown_key": "whatever"}]})
    assert cfg.users[0].registration == "discord"
    assert not hasattr(cfg.users[0], "future_unknown_key")


# ---- ImageConfig.load() envelope guard ------------------------------------------

def test_load_rejects_worklist_envelope(tmp_path):
    p = tmp_path / "wl.json"
    p.write_text(json.dumps({"schema": "snapdragon-worklist/v1",
                             "base": ImageConfig().to_dict(), "entries": []}),
                 encoding="utf-8")
    with pytest.raises(ValueError, match="worklist envelope"):
        ImageConfig.load(str(p))


def test_load_still_accepts_flat_config(tmp_path):
    # a flat config (no schema key) loads byte-identically — the 118 harness configs + saves
    p = tmp_path / "flat.json"
    ImageConfig(mode="cloud", role="desktop", platform="x86").save(str(p))
    cfg = ImageConfig.load(str(p))
    assert cfg.role == "desktop" and cfg.mode == "cloud"


# ---- role-class capability layer (§2.2) -----------------------------------------

def test_image_class_desktop_vs_node():
    # desktop-class person/standalone/ARM-desktop roles
    for role in ("laptop", "chromebook", "desktop", "standalone-thin", "standalone-thick",
                 "standalone-unaffiliated", "rpi5-desktop", "jetson-desktop", "frite",
                 "orangepi5"):
        assert image_class("cloud", role) == "desktop", role
    # node-class cluster infra + headless appliances
    for role in ("pki", "be", "fe", "be+gpu", "omnibus", "edge_ai", "full", "gpu-host",
                 "orangepizero2", "generic"):
        assert image_class("mesh", role) == "node", role
    # membership sets are disjoint and cover the mesh/x86 catalogs
    assert set(DESKTOP_ROLES).isdisjoint(NODE_ROLES)
    assert set(X86_NODE_ROLES) <= set(NODE_ROLES)
    assert set(X86_CLIENT_ROLES) <= set(DESKTOP_ROLES)


def test_branding_allowed_predicate():
    # desktop, non-mesh -> allowed
    assert branding_allowed(ImageConfig(mode="standalone", role="standalone-thick"))
    assert branding_allowed(ImageConfig(mode="cloud", role="desktop"))
    # node role -> never
    assert not branding_allowed(ImageConfig(mode="cloud", role="omnibus"))
    # mesh -> never, even for a desktop-class row
    assert not branding_allowed(ImageConfig(mode="mesh", role="rpi5-desktop"))


def test_tailnet_sso_visible_predicate():
    # cloud branded desktop -> visible
    assert tailnet_sso_visible(ImageConfig(mode="cloud", role="desktop"))
    # standalone / mesh -> hidden (implicit / none)
    assert not tailnet_sso_visible(ImageConfig(mode="standalone", role="standalone-thick"))
    assert not tailnet_sso_visible(ImageConfig(mode="mesh", role="omnibus"))
    # unaffiliated hard-conflicts with the tailnet -> hidden even in cloud
    assert not tailnet_sso_visible(ImageConfig(mode="cloud", role="standalone-unaffiliated"))
    # a node in cloud -> hidden
    assert not tailnet_sso_visible(ImageConfig(mode="cloud", role="edge_ai"))


def test_home_options_allowed_predicate():
    assert home_options_allowed(ImageConfig(mode="standalone", role="standalone-thick"))
    assert home_options_allowed(ImageConfig(mode="cloud", role="laptop"))
    assert not home_options_allowed(ImageConfig(mode="mesh", role="omnibus"))
    assert not home_options_allowed(ImageConfig(mode="cloud", role="pki"))


def test_clear_role_class_fields_desktop_keeps_everything():
    # a standalone desktop keeps theming + home; tailscale/sso already False (cleared, no-op)
    cfg = ImageConfig(mode="standalone", role="standalone-thick", theme="boogiepop",
                      home_mode="adopt", home_encrypted=True)
    cleared = clear_role_class_fields(cfg)
    assert cfg.theme == "boogiepop" and cfg.home_mode == "adopt" and cfg.home_encrypted
    assert "theme" not in cleared and "home_mode" not in cleared


def test_clear_role_class_fields_node_zeroes_theme_and_home():
    cfg = ImageConfig(mode="mesh", role="omnibus", theme="boogiepop", accent_color="#123456",
                      brand_locked=True, home_mode="adopt", home_encrypted=True,
                      seed_packages_from="/x", tailscale=True, sso=True)
    cleared = clear_role_class_fields(cfg)
    # every THEME_FIELD/HOME_DESKTOP_FIELD reset to its dataclass default
    assert cfg.theme == "" and cfg.accent_color == "" and cfg.brand_locked is False
    assert cfg.home_mode == "create" and cfg.home_encrypted is False and cfg.seed_packages_from == ""
    # mesh isn't a cloud desktop -> tailnet/sso reset to their tri-state default ""
    # (#307 made them tri-states; "" = resolve-by-mode, re-forced True for mesh by enter_mesh_defaults)
    assert cfg.tailscale == "" and cfg.sso == ""
    for f in ("theme", "accent_color", "brand_locked", "home_mode", "tailscale", "sso"):
        assert f in cleared


def test_enter_mesh_defaults_clears_then_forces_tailnet():
    cfg = ImageConfig(mode="mesh", role="omnibus", theme="boogiepop", home_mode="adopt")
    enter_mesh_defaults(cfg)
    assert cfg.theme == "" and cfg.home_mode == "create"
    # today's mesh x86 argv (--with-tailscale/--with-sso) is preserved byte-identically
    assert cfg.tailscale is True and cfg.sso is True
    args = cfg.to_cli_args()
    assert "--with-tailscale" in args and "--with-sso" in args


def test_enter_mesh_defaults_preserves_mesh_x86_golden():
    # the enter-mesh path must land on the exact existing mesh x86 golden argv
    cfg = ImageConfig(mode="mesh", role="omnibus", platform="x86")
    enter_mesh_defaults(cfg)
    assert cfg.to_cli_args() == ["--role", "omnibus", "--env", "test", "--local-user", "magus",
                                 "--with-tailscale", "--with-sso",
                                 "--superdomain", "snapdragon.internal", *X86_TAIL]


def test_strip_platform_unsupported_clears_x86_only_fields_on_arm():
    # theme/home/secure_boot are x86-only -> stripped on an rpi5 node cfg
    cfg = ImageConfig(mode="mesh", role="be", platform="rpi5", tailscale=True,
                      theme="boogiepop", secure_boot="off", home_mode="adopt",
                      brand="acme")
    cleared = strip_platform_unsupported(cfg)
    assert cfg.theme == "" and cfg.secure_boot == "" and cfg.home_mode == "create"
    assert "theme" in cleared and "secure_boot" in cleared
    # a field the rpi5 builder DOES take (brand) survives
    assert cfg.brand == "acme" and "brand" not in cleared


def test_strip_platform_unsupported_noop_on_x86_baseline():
    # a plain x86 config touches no x86-supported field -> nothing spurious cleared
    cfg = ImageConfig(mode="cloud", role="desktop", platform="x86", theme="boogiepop")
    cleared = strip_platform_unsupported(cfg)
    assert cfg.theme == "boogiepop"        # theme IS x86-supported
    assert "theme" not in cleared

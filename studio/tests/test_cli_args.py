"""Golden ImageConfig.to_cli_args() translations for EVERY role x platform.

The Studio's all-options-in-all-menus contract: each documented role builds through
the right builder script with exactly the flags that builder parses. Pure-core tests —
no Qt required.
"""
import json

import pytest

from snapdragon_studio.core.config import (
    BUILDER_SCRIPTS,
    ImageConfig,
    MODE_DEFAULT_ROLE,
    ROLE_CHOICES,
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
    # CLIENT
    for r in ("laptop", "chromebook", "desktop"):
        assert (r, "x86") in flat
    assert ("frite", "frite") in flat
    # STANDALONE
    assert ("standalone-thin", "x86") in flat and ("standalone-thick", "x86") in flat
    # JETSON (EXPERIMENTAL)
    for r in ("edge_ai", "full", "gpu-host", "jetson-desktop"):
        assert (r, "jetson") in flat


def test_mode_defaults_stay_in_catalog():
    for mode, role in MODE_DEFAULT_ROLE.items():
        assert role in {r for r, _, _ in ROLE_CHOICES[mode]}


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


@pytest.mark.parametrize("role", ["laptop", "chromebook", "desktop"])
def test_x86_client_roles_golden(role):
    args = ImageConfig(mode="cloud", role=role, platform="x86",
                       tailscale=True, sso=True).to_cli_args()
    assert args == ["--role", role, "--env", "test", "--local-user", "magus",
                    "--with-tailscale", "--with-sso", "--person-role", "user", *X86_TAIL]


@pytest.mark.parametrize("role", ["pki", "be", "fe", "be+gpu", "omnibus", "edge_ai"])
def test_x86_mesh_roles_golden(role):
    args = ImageConfig(mode="mesh", role=role, platform="x86",
                       tailscale=True, sso=True).to_cli_args()
    assert args == ["--role", role, "--env", "test", "--local-user", "magus",
                    "--with-tailscale", "--with-sso", "--person-role", "superadmin", *X86_TAIL]


def test_x86_client_desktop_weight_and_steam():
    args = ImageConfig(mode="cloud", role="laptop", platform="x86",
                       desktop="thin", steam="flatpak").to_cli_args()
    assert ("--desktop", "thin") in pairs(args)
    assert ("--steam", "flatpak") in pairs(args)


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


# ---- rpi5: server node roles (be/fe spelled out) -----------------------------

@pytest.mark.parametrize("role,builder_role",
                         [("pki", "pki"), ("be", "backend"), ("fe", "frontend")])
def test_rpi5_roles_golden(role, builder_role):
    args = ImageConfig(mode="mesh", role=role, platform="rpi5", tailscale=True).to_cli_args()
    assert args == ["--role", builder_role, "--env", "test"]


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
                    "--cluster-domain", "acme.example", "--skip-mesh",
                    "--enable-wifi", "--enable-bluetooth",
                    "--permit-root-login", "prohibit-password",
                    "--img-size", "4096", "--compress", "--resume",
                    "--optional-services", "akkoma owncast", "--enable-games",
                    "--with-character-studio"]


def test_rpi5_never_emits_x86_only_flags():
    args = ImageConfig(mode="mesh", role="pki", platform="rpi5",
                       installer_ui="all", cached=True, desktop="thin",
                       steam="native", encrypt_root=True).to_cli_args()
    for flag in ("--local-user", "--installer-ui", "--cached", "--uncached", "--desktop",
                 "--steam", "--encrypt-root", "--with-tailscale", "--no-tailscale",
                 "--with-sso", "--no-sso", "--person-role", "--live-toram", "--bundle-source"):
        assert flag not in args


# ---- frite: arm64 client (board x flavor x desktop, no --role) ----------------

def test_frite_defaults_golden():
    args = ImageConfig(mode="cloud", role="frite", platform="frite").to_cli_args()
    assert args == ["--board", "la-frite", "--flavor", "both", "--env", "test", "--skip-mesh"]


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
    assert args == ["--role", builder_role, "--env", "test"]


def test_jetson_shared_arm_surface():
    args = ImageConfig(mode="mesh", role="edge_ai", platform="jetson", tailscale=False,
                       brand="acme", enable_wifi=True, img_size=8192,
                       compress=True, resume=True).to_cli_args()
    assert args == ["--role", "edge_ai", "--env", "test", "--brand", "acme",
                    "--skip-mesh", "--enable-wifi", "--img-size", "8192",
                    "--compress", "--resume"]


@pytest.mark.parametrize("board", ["orin-nano", "orin-nano-4gb",
                                   "orin-nx-8gb", "orin-nx-16gb"])
def test_jetson_board_axis(board):
    args = ImageConfig(mode="mesh", role="edge_ai", platform="jetson", tailscale=True,
                       board=board).to_cli_args()
    assert args == ["--role", "edge_ai", "--board", board, "--env", "test"]


# ---- env threading (test|prod baked per channel) ------------------------------

@pytest.mark.parametrize("platform,role", [("x86", "omnibus"), ("rpi5", "pki"),
                                           ("frite", "frite"), ("jetson", "edge_ai")])
@pytest.mark.parametrize("env", ["test", "prod"])
def test_env_threads_through_every_platform(platform, role, env):
    args = ImageConfig(mode="mesh" if platform != "frite" else "cloud",
                       role=role, platform=platform, env=env).to_cli_args()
    assert ("--env", env) in pairs(args)


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

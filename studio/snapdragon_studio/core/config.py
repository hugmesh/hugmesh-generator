"""ImageConfig — the single source of truth for a Snapdragon image build.

Every field maps to a builder flag; ``to_cli_args()`` is the exact translation the
GUI and the build driver share, so the Studio UI can surface the WHOLE flag surface
without drifting from the scripts. The ``platform`` axis picks the builder:
x86 -> build-x86-host-stage4.sh, rpi5 -> build-rpi5-stage4.sh,
frite -> build-frite-stage4.sh, jetson -> build-jetson-stage4.sh (EXPERIMENTAL —
hardware validation pending; frite flag conventions + --role),
orangepi5 -> build-orangepi5-stage4.sh (EXPERIMENTAL — hardware validation
pending; frite flag conventions: --board + --flavor, no --role),
orangepizero2 -> build-orangepi-zero2-stage4.sh (EXPERIMENTAL — hardware
validation pending; a HEADLESS APPLIANCE, not a desktop client — no --board,
no --desktop, just --flavor; see specs-orangepi-zero2/README.md for why this
platform never has a desktop mode).
"""
from __future__ import annotations

import json
import re
import shlex
from dataclasses import dataclass, field, asdict, MISSING
from typing import Any

from .host_resources import default_jobs
from .validate import (
    IdentityValidationError,
    validate_accent_color,
    validate_brand,
    validate_brand_title,
    validate_domain_name,
    validate_home_backup,
    validate_home_device,
    validate_org,
    validate_package_atoms,
    validate_username,
)

# A timezone (Area/Location, "UTC", …): letters/digits + the handful of separators
# a tz database name uses. It flows to -T/--timezone and into a root-sourced config,
# so reject anything shell/sed-meaningful. A media/vault filesystem label is even
# stricter (it becomes a `mkfs -L` / by-label mount target).
_TIMEZONE_RE = re.compile(r"^[A-Za-z0-9_+./-]+$")
_MEDIA_LABEL_RE = re.compile(r"^[A-Za-z0-9_.-]+$")


# Studio "mode" -> sensible default role. The wizard lets the user override role.
MODE_DEFAULT_ROLE = {
    "standalone": "standalone-thick",  # hardened personal desktop, no mesh/SSO
    "cloud": "desktop",                # branded tailnet client (mesh + SSO + admin keys)
    "mesh": "omnibus",                 # superadmin: a mesh node serving domains
}

# The wizard's page order (StudioWizard registers exactly one page per slug, in this
# order — a fail-loud assert keeps the two lists from drifting) and which pages do
# NOT apply per Studio mode: the wizard's nextId() skips them, so a standalone build
# never routes through the admin key-zip or the superadmin domains/users tables (the
# shortest path to a plain/unaffiliated desktop). Kept Qt-free HERE so the flow
# contract is testable without a GUI toolkit. Skipped pages are never VISITED, and
# collect_all() only reads visited pages — so a skipped page's widgets can never
# leak stale values into a saved config or the emitted argv.
WIZARD_PAGE_SLUGS = ("welcome", "mode", "role", "worklist", "hardware", "branding",
                     "network", "keyzip", "domains", "users", "system", "home",
                     "build", "progress")
MODE_SKIPPED_PAGES = {
    # standalone/cloud build ONE image the old way (role/hardware/branding per image);
    # the mesh worklist is skipped there. mesh builds N images from a role x platform
    # multi-select on the WorklistPage instead of the single-image role/hardware/branding
    # pages (per-image hardware/GPU/board facts derive from the worklist row; theming is
    # a desktop-class surface a mesh node never carries).
    "standalone": ("worklist", "keyzip", "domains", "users"),  # single image, no admin/mesh plane
    "cloud": ("worklist",),                                     # single image, admin plane via key-zip
    "mesh": ("role", "hardware", "branding"),                  # the WorklistPage owns role x platform
}

# platform id -> builder script at the generator-repo root. All four are reachable
# in the docker path too (the whole generator dir is mounted at /src).
BUILDER_SCRIPTS = {
    "x86": "build-x86-host-stage4.sh",
    "rpi5": "build-rpi5-stage4.sh",
    "frite": "build-frite-stage4.sh",
    "jetson": "build-jetson-stage4.sh",
    "orangepi5": "build-orangepi5-stage4.sh",
    "orangepizero2": "build-orangepi-zero2-stage4.sh",
}

# GUI-facing platform labels (Jetson/Orange Pi 5/Orange Pi Zero 2 are
# scaffold-stage — see specs-jetson/README.md / specs-orangepi5/README.md /
# specs-orangepi-zero2/README.md).
PLATFORM_LABELS = {
    "x86": "x86_64 host",
    "rpi5": "Raspberry Pi 5 / 4 / 3 (arm64) — desktop OR mesh node; --board rpi5 [DEFAULT] | rpi4 | rpi3 [desktop-only, no node]",
    "frite": "Libre AML-S805X La Frite family (arm64)",
    "jetson": "NVIDIA Jetson Orin (arm64) — EXPERIMENTAL: hardware validation pending",
    "orangepi5": "Orange Pi 5 / 5 Plus (Rockchip RK3588/RK3588S, arm64) — EXPERIMENTAL: hardware validation pending",
    "orangepizero2": "Orange Pi Zero 2 (Allwinner H616, arm64) — HEADLESS APPLIANCE, no desktop mode ever — EXPERIMENTAL: hardware validation pending",
}

# The full role catalog, grouped by Studio mode: (role id, supported platforms, label).
# THE all-options-in-all-menus source of truth for the Studio (specs-jetson/README.md).
ROLE_CHOICES = {
    "standalone": [
        ("standalone-thin", ("x86",), "Standalone thin — hardened LXDE desktop, no mesh/SSO"),
        ("standalone-thick", ("x86",), "Standalone thick — hardened full desktop, no mesh/SSO"),
        ("standalone-unaffiliated", ("x86",),
         "Unaffiliated desktop — plain Gentoo, no Snapdragon (zero branding/tooling baked)"),
        ("generic", ("rpi5",),
         "Generic arm64 server — plain Gentoo Raspberry Pi 5, unbranded (builder default role)"),
        # frite/orangepi5/orangepizero2 all support --standalone (FDE + local user, no
        # mesh/SSO); reachable in standalone mode too, not only as a cloud client (G17).
        ("frite", ("frite",), "La Frite family arm64 standalone (FDE local desktop; board + flavor)"),
        ("orangepi5", ("orangepi5",), "Orange Pi 5 / 5 Plus arm64 standalone — EXPERIMENTAL (FDE local desktop; board + flavor)"),
        ("orangepizero2", ("orangepizero2",), "Orange Pi Zero 2 arm64 standalone HEADLESS APPLIANCE — EXPERIMENTAL (FDE; flavor only)"),
        # A coreboot/UEFI Chromebook is a laptop-class DESKTOP image (build-x86: the
        # chromebook role == a laptop image targeting coreboot-UEFI, ADR-16). It is
        # reachable standalone (no mesh/SSO) as well as as a cloud client — mirroring
        # laptop/desktop being desktop-class in either posture (G17). Role stays the
        # x86 `chromebook` device-class id; standalone posture drops the mesh plane.
        ("chromebook", ("x86",),
         "Chromebook desktop — coreboot/UEFI laptop image (ADR-16), standalone (no mesh/SSO)"),
    ],
    "cloud": [
        ("laptop", ("x86",), "Laptop desktop — tailnet + SSO"),
        # A Chromebook is a laptop-class DESKTOP image (coreboot/UEFI, ADR-16), not a
        # node — surfaced here as a first-class desktop selection alongside laptop/desktop.
        ("chromebook", ("x86",), "Chromebook desktop — coreboot/UEFI laptop image (ADR-16); tailnet + SSO"),
        ("desktop", ("x86",), "Desktop client — tailnet + SSO"),
        # rpi5 arm64 tailnet client desktop (builder --role desktop) — reachable in
        # cloud mode, not only as a mesh role (G17). All three boards are desktop-capable.
        ("rpi5-desktop", ("rpi5",),
         "Raspberry Pi 5 / 4 / 3 arm64 desktop client — tailnet + SSO (choose board below)"),
        ("frite", ("frite",), "La Frite family arm64 client (board + live/installer flavor)"),
        ("orangepi5", ("orangepi5",), "Orange Pi 5 / 5 Plus arm64 client — EXPERIMENTAL (board + live/installer flavor)"),
        ("orangepizero2", ("orangepizero2",), "Orange Pi Zero 2 arm64 HEADLESS APPLIANCE — EXPERIMENTAL (live/installer flavor only; no board/desktop axis)"),
    ],
    "mesh": [
        # pki/be/fe are node images buildable on x86 OR a Raspberry Pi 4/5 board (Pi 3
        # is desktop-only — 1GB RAM can't host the node stack, so the rpi5 board picker
        # offers only rpi5/rpi4 for these; see rpi_boards_for_role()).
        ("pki", ("x86", "rpi5"), "PKI node — cluster certificate authority (x86 or Raspberry Pi 4/5)"),
        ("be", ("x86", "rpi5"), "Backend node (x86 or Raspberry Pi 4/5)"),
        ("fe", ("x86", "rpi5"), "Frontend node (x86 or Raspberry Pi 4/5)"),
        ("be+gpu", ("x86",), "Backend + GPU node"),
        ("omnibus", ("x86",), "Omnibus — every cluster role on one node"),
        ("rpi5-desktop", ("rpi5",),
         "Raspberry Pi 5 / 4 / 3 desktop — arm64 client (compose with --standalone for FDE, no mesh)"),
        ("edge_ai", ("x86", "jetson"), "Edge-AI node — GPU + OpenAI-compatible model API"),
        ("full", ("jetson",), "Jetson full-stack node — EXPERIMENTAL, hardware validation pending"),
        ("gpu-host", ("jetson",), "Jetson GPU host — EXPERIMENTAL, hardware validation pending"),
        ("jetson-desktop", ("jetson",), "Jetson desktop — EXPERIMENTAL, hardware validation pending"),
    ],
}

# The x86 role that builds a PLAIN, unaffiliated Gentoo desktop. The builder's role
# arm PRESETS everything (neutral gentoo identity, no bundled source, no mesh/SSO)
# and HARD-ERRORS on any brand/branding/bundle/seed/mesh/SSO/person flag — so the
# Studio raises the same conflicts instead of emitting them (fail loudly, like the
# builder), and emits the bare role + generic options only.
UNAFFILIATED_ROLE = "standalone-unaffiliated"

# build-rpi5-stage4.sh spells the node roles out (pki | backend | frontend).
# The Studio disambiguates the rpi5 desktop role id; the builder takes --role desktop.
RPI5_ROLE_MAP = {"be": "backend", "fe": "frontend", "rpi5-desktop": "desktop"}
# The Studio disambiguates the jetson desktop role id; the builder takes --role desktop.
JETSON_ROLE_MAP = {"jetson-desktop": "desktop"}

FRITE_BOARDS = ("la-frite", "le-potato", "sweet-potato")
FRITE_FLAVORS = ("live", "installer", "both")
FRITE_DESKTOPS = ("light", "none")

# build-jetson-stage4.sh --board (Tegra234 Orin modules on the devkit carrier).
JETSON_BOARDS = ("orin-nano", "orin-nano-4gb", "orin-nx-8gb", "orin-nx-16gb")

# build-rpi5-stage4.sh --board (ONE builder extended with a board table, Phase 6
# — Pi 4/Pi 5 share the Raspberry Pi Foundation boot model closely enough that a
# separate builder script isn't warranted). "" (unset) = the builder's own
# default (rpi5). rpi3 (Phase 8) is DESKTOP-ONLY (1GB RAM) — the builder
# hard-errors if role != desktop; this dataclass does NOT pre-validate that
# combo (the builder's hard-error is the authoritative safety net).
RPI_BOARDS = ("rpi5", "rpi4", "rpi3")
# The board subset a CLUSTER-NODE role may target: rpi3 (1GB RAM) is desktop-only —
# build-rpi5-stage4.sh hard-errors a non-desktop role on --board rpi3, so a node
# selection must never offer it (the menu would otherwise dead-end in that hard-error,
# violating the honesty rule). rpi_boards_for_role() picks the right list per role.
RPI_NODE_BOARDS = ("rpi5", "rpi4")

# build-orangepi5-stage4.sh --board (Rockchip RK3588/RK3588S) / --flavor.
# EXPERIMENTAL — hardware validation pending; see specs-orangepi5/README.md.
# ONE role (a client desktop, no --role axis), like Frite — just board + flavor.
ORANGEPI5_BOARDS = ("orange-pi-5-plus", "orange-pi-5")
ORANGEPI5_FLAVORS = ("live", "installer", "both")

# build-orangepi-zero2-stage4.sh --flavor (Allwinner H616). EXPERIMENTAL —
# hardware validation pending; see specs-orangepi-zero2/README.md. ONE role (a
# HEADLESS APPLIANCE, not a desktop client, no --role axis) AND no --board axis
# (a single board, unlike Frite/Orange-Pi-5's board tables) — just --flavor.
ORANGEPIZERO2_FLAVORS = ("live", "installer", "both")

# ── BOARD-EXPANSION MATRIX — logged decisions (Orange Pi 2/3/4/4pro/5/6 +
# Raspberry Pi 2/3/4/5/6 + Chromebook). The honesty rule (no selectable board whose
# build is guaranteed to fail): a board only becomes a plain selection when it has a
# REAL recipe (real upstream u-boot+kernel+DTB or a reusable sibling) that is at least
# --print-plan-clean; otherwise it is EXPERIMENTAL (labelled + fail-loud preflight) or
# NOT ADDED. NOTHING in this sandbox is hardware-validated (no silicon, no network to
# cross-emerge) — mirrors why jetson/orangepi5/orangepizero2 are EXPERIMENTAL.
#
# ADDED / SURFACED (REAL — already build; this change is verification + node-exposure
# + relabelling only, no new builder or specs-*/):
#   RPi 5   REAL — build-rpi5-stage4.sh default board; desktop (rpi5-desktop) + node
#                  (pki/be/fe). Already in matrix.tsv.
#   RPi 4   REAL — build-rpi5-stage4.sh --board rpi4; desktop + node. Now explicitly
#                  pickable as a node board (rpi_boards_for_role) + relabelled.
#   RPi 3   REAL, DESKTOP-ONLY — --board rpi3; 1GB RAM cannot host the node stack, so
#                  the builder hard-errors non-desktop roles. Offered desktop-only;
#                  rpi3 is kept OUT of every node board picker (RPI_NODE_BOARDS).
#   OPi 5   EXPERIMENTAL (pre-existing) — build-orangepi5-stage4.sh, desktop only (this
#                  builder has no cluster-node axis; a node OPi 5 = net-new capability,
#                  NOT a selection). Unchanged here.
#   Chromebook  REAL — build-x86-host-stage4.sh --role chromebook == a coreboot/UEFI
#                  laptop DESKTOP image (ADR-16). Was buried under one cloud label;
#                  now a clearly-labelled desktop choice in cloud AND standalone.
#
# NOT ADDED — EXPERIMENTAL-at-best (real upstream, but net-new unvalidatable builder +
# specs-*/ work; would need the jetson/opi5 EXPERIMENTAL-label + fail-loud-preflight
# convention; the orchestrator deliberately did NOT author new builders it cannot
# validate on silicon, per the honesty rule):
#   OPi 4 (RK3399)        — mature mainline u-boot/kernel/DTB/TF-A/panfrost, but the
#                           only Rockchip recipe here (RK3588) is NOT directly reusable
#                           (different rkbin DDR blob, TF-A platform, Mali). Would be a
#                           new platform `orangepi4` + build-orangepi4-stage4.sh.
#   OPi 3 (Allwinner H6)  — mainline u-boot/kernel/DTB incl. display; closest sibling
#                           is the H616 zero2 flow but needs new specs-orangepi3/.
#   OPi 4 Pro             — UNCONFIRMED SKU; folds into OPi 4 only IF proven RK3399.
#
# NOT ADDED — INFEASIBLE (no internally-consistent, --print-plan-clean recipe to even
# gate; fails at recipe-authoring, so a preflight-gated EXPERIMENTAL would be dishonest):
#   RPi 2 (BCM2836)          — 32-bit ARMv7; the whole rpi5 toolchain is aarch64-only.
#   OPi 2 (Allwinner H3)     — 32-bit ARMv7; same aarch64-only blocker.
#   RPi 6                    — does not exist (latest shipping Pi is the Pi 5, Jan-2026).
#   OPi 6 / 6 Plus (CIX Sky1)— 2025 SoC, vendor-BSP/out-of-tree; no trustworthy mainline
#                              u-boot/kernel/DTB to build a recipe against.

# --env: what gets baked into the image's stack config (test | prod).
ENV_CHOICES = ("test", "prod")

# build-x86-host-stage4.sh's full documented --gpu-driver matrix (canonical names).
# "auto" is a Studio value, not a builder flag: to_cli_args() omits --gpu-driver so
# the builder resolves its own default (all-free on GPU roles, nvidia on edge_ai).
GPU_DRIVER_CHOICES = ("auto", "all-free", "nvidia-free", "nvidia",
                      "amd-free", "amd-pro", "intel-free", "intel-pro", "none")
# Vendor aliases the builder folds into canonical ids — mirrored so hwprofile /
# scanner values (e.g. "intel") select the right canonical GUI combo entry.
GPU_DRIVER_ALIASES = {"amd": "amd-free", "ati": "amd-free", "ati-free": "amd-free",
                      "ati-pro": "amd-pro", "intel": "intel-free"}

# The full cluster user-level optional-service set (--optional-services slugs).
OPTIONAL_SERVICES_CHOICES = ("akkoma", "tuwunel", "phpbb", "games", "owncast", "tube",
                             "character-studio")

# INFRA-level slugs the builders honour in --optional-services but which --all-services
# does NOT include (build-rpi5-stage4.sh usage 573-581). x86 has dedicated flags for
# tor/egress (--with-tor / --egress-vpn), but rpi5 has none — the ONLY way to bake a
# Tor-onion / egress-VPN rpi5 node is to list the slug here, so the rpi5 catalog offers
# them explicitly (G15). frite/jetson/opi5/opz2 do not parse --optional-services at all.
INFRA_SERVICES_CHOICES = ("tor", "egress-vpn", "workloadConsole", "anubis")

# Which optional-service slugs each builder's --optional-services accepts. Only x86 and
# rpi5 parse --optional-services/--exclude-services/--enable-games at all — the other
# four builders bake no cluster tree, so the widgets must be greyed there (G12/G15).
OPTIONAL_SERVICES_BY_PLATFORM = {
    "x86": OPTIONAL_SERVICES_CHOICES,
    "rpi5": OPTIONAL_SERVICES_CHOICES + INFRA_SERVICES_CHOICES,
}

# --optional-services sentinels (mirror build-menu.sh's OPT_SERVICES + the builders):
#   optional_services == []            -> emit nothing (builder default akkoma tuwunel phpbb)
#   optional_services == [SERVICES_NONE] -> emit --optional-services "" (EXPLICIT none, G13)
#   optional_services == [SERVICES_ALL]  -> emit --all-services (full user-level set, G14)
#   optional_services == [slug, ...]     -> emit --optional-services "slug ..." (allow-list)
SERVICES_NONE = "none"
SERVICES_ALL = "all"

# --person-role client-identity picker (FD-08). The x86 builder honours --person-role/
# --domains only for ROLE_CLIENT roles (the person-device desktops laptop/chromebook/
# desktop AND the standalone desktops); on a cluster NODE role it warns + IGNORES them
# (build-x86:1219-1221), so the Studio must NOT emit them for a node role (G18).
PERSON_ROLE_CHOICES = ("user", "mod", "admin", "superadmin")
X86_CLIENT_ROLES = ("laptop", "chromebook", "desktop")
# The cluster NODE roles (ROLE_CLIENT=false) — the roles for which the builder drops
# --person-role/--domains. Gating on "not a node role" (rather than "is a client role")
# also lets a standalone-desktop role carry them, exactly like the builder does.
X86_NODE_ROLES = ("pki", "be", "fe", "be+gpu", "omnibus", "edge_ai")

# --release-state: cluster ingress + Layer-3 nftables posture baked into the image
# (build-x86:674 / bake_host_firewall:2888; rpi5:1089-1091). Only x86 + rpi5 parse it.
RELEASE_STATE_CHOICES = ("internal", "public")

# --kernel-flavor (jetson only): mainline (default) | l4t. The l4t BUILD is a stub that
# hard-errors today, but the plan/matrix/--print-plan accept the axis (G36).
KERNEL_FLAVOR_CHOICES = ("mainline", "l4t")

# --secure-boot tri-state (x86 only; builder default is ON with a throwaway org key):
#   "" -> leave the builder default   "on" -> --secure-boot   "off" -> --no-secure-boot (G5)
SECURE_BOOT_CHOICES = ("", "on", "off")

# Plaintext secrets that are NEVER persisted to a saved JSON config — they exist only
# for the live command line (the builder hashes them at build time). user_password /
# root_password are the x86 node FALLBACK credentials (G27); local_pass / luks_pass the
# standalone/FDE ones.
SECRET_FIELDS = ("local_pass", "luks_pass", "user_password", "root_password")


# ── capability table: which platforms' arg builders EMIT each option field ──────────
# THE contract WS2 (per-platform widget greying) and WS6 (parity/coverage differ)
# consume: an ImageConfig field is "supported" on a platform iff that platform's
# _<platform>_args() emits something for it (a builder that does not parse the flag would
# exit "Unknown option", so the wizard must grey the widget there). Hand-declared for
# readability + stable import, but ASSERTED against real emission by a diff-probe in
# tests/test_cli_args.py (test_platform_field_support_matches_emission), so it CANNOT
# drift from the code above. Structural axes (mode/role/platform/board/flavor/env) and
# the extra_flags escape hatch are RolePage/BuildPage concerns, not gateable option
# widgets, so they are intentionally absent. See NON_ARGV_FIELDS for fields delivered
# out-of-band (never argv) which must stay shown regardless of platform.
_ALL_PLATFORMS = ("x86", "rpi5", "frite", "jetson", "orangepi5", "orangepizero2")
_ARM_PLATFORMS = ("rpi5", "frite", "jetson", "orangepi5", "orangepizero2")
_ENC_PLATFORMS = ("x86", "rpi5", "frite", "orangepi5", "orangepizero2")   # --encrypt-root: all but jetson
_UBOOT_PLATFORMS = ("frite", "orangepi5", "orangepizero2")
_DTB_PLATFORMS = ("frite", "jetson", "orangepi5", "orangepizero2")        # rpi5 uses --dtb-prefix
_IMAGE_ONLY_PLATFORMS = ("frite", "jetson", "orangepi5", "orangepizero2")
_X86 = ("x86",)
_X86_RPI5 = ("x86", "rpi5")

PLATFORM_FIELD_SUPPORT: dict[str, tuple[str, ...]] = {
    # brand plane — every builder parses these identically (x86 unaffiliated suppresses).
    "brand": _ALL_PLATFORMS, "brand_title": _ALL_PLATFORMS, "org": _ALL_PLATFORMS,
    "brand_profile": _ALL_PLATFORMS,
    # host identity (-H/-T/-u) — all builders.
    "hostname": _ALL_PLATFORMS, "timezone": _ALL_PLATFORMS, "user": _ALL_PLATFORMS,
    # cluster / mesh identity.
    "cluster_domain": _ALL_PLATFORMS, "games_domain": _X86_RPI5, "release_state": _X86_RPI5,
    "person_role": _X86, "domains": _X86,
    # orchestration superdomain — every builder parses --superdomain (WS-SUPER-B bake);
    # emitted ONLY in mesh mode (see _superdomain_args), so it is EXCLUDED from the
    # generic _FIELD_PROBE diff-probe (mixed cloud/mesh baselines) and pinned by a
    # dedicated mesh-mode test, exactly like `unaffiliated`.
    "superdomain": _ALL_PLATFORMS,
    # local account (compose without --standalone on ARM too, G28).
    "local_user": _ALL_PLATFORMS, "local_pass": _ALL_PLATFORMS,
    # node fallback creds (x86 only; rpi5's are deprecated no-ops).
    "user_password": _X86, "root_password": _X86,
    # standalone / capable / unaffiliated.
    "standalone": _ENC_PLATFORMS, "capable": _X86, "unaffiliated": _X86,
    # mesh agents.
    "tailscale": _ALL_PLATFORMS, "sso": _X86,
    "headscale_version": _ALL_PLATFORMS, "tailscale_version": _ALL_PLATFORMS,
    "skip_tailscale": _ALL_PLATFORMS,
    # hardware.
    "gpu_driver": _X86, "nvidia_cuda": _X86, "kernel_builtin": _X86,
    "enable_wifi": _ALL_PLATFORMS, "enable_bluetooth": _ALL_PLATFORMS,
    # branding assets (x86 only).
    "theme": _X86, "branding_dir": _X86, "wallpaper": _X86, "grub_background": _X86,
    "grub_theme": _X86, "login_background": _X86, "brand_logo": _X86, "accent_color": _X86,
    "color_scheme": _X86, "brand_locked": _X86,
    # egress VPN (x86 only).
    "egress_vpn": _X86, "egress_vpn_locked": _X86,
    # host security stack.
    "proxy_stack": _X86, "snort": _X86, "aide": _X86, "root_login": _ALL_PLATFORMS,
    # edge-AI (x86 only).
    "edge_ai_service": _X86, "edge_ai_runtime": _X86, "edge_ai_models": _X86,
    "edge_ai_model_default": _X86, "edge_ai_analysis": _X86,
    # edge_ai_tts is CPU-only + self-contained (NO edge-ai dependency) — wired on
    # BOTH x86 AND rpi5 (unlike edge_ai_analysis, which is x86/GPU-only).
    "edge_ai_tts": _X86_RPI5,
    # tor / character-studio / services.
    "tor_onion_service": _X86, "character_studio": _X86_RPI5,
    "optional_services": _X86_RPI5, "exclude_services": _X86_RPI5, "enable_games": _X86_RPI5,
    # client desktop weight / steam / media.
    "desktop": ("x86", "frite"), "steam": _X86,
    "media_data": _X86, "media_label": _X86, "no_vaults": _X86,
    # encryption (jetson hard-blocks encrypt-root; luks_pass alone still emits everywhere).
    "encrypt_root": _ENC_PLATFORMS, "luks_pass": _ALL_PLATFORMS,
    "unlock_keyfile": _X86, "unlock_yubikey": _X86,
    # Secure Boot (x86 only).
    "secure_boot": _X86, "keys_usb": _X86, "secureboot_key": _X86, "secureboot_cert": _X86,
    # home (x86 only).
    "home_mode": _X86, "home_device": _X86, "home_backup": _X86, "home_encrypted": _X86,
    "home_seed_code": _X86, "home_seed_code_from": _X86, "include_home_archive": _X86,
    "seed_packages_from": _X86,
    # installer / ISO / artifact.
    "installer_ui": _X86, "cached": _X86, "live_toram": _X86, "bundle_source": _X86,
    "build_img": ("x86", "rpi5", "jetson"), "live_iso": _X86, "installer_iso": _X86,
    "build_tar": _X86_RPI5, "skip_iso": _X86_RPI5, "build_iso": ("rpi5",),
    "sd_only": ("rpi5",), "image_only": _IMAGE_ONLY_PLATFORMS,
    # sizing / finish.
    "grow": _ALL_PLATFORMS, "img_size": _ALL_PLATFORMS, "compress": _ALL_PLATFORMS,
    "resume": _ALL_PLATFORMS,
    # kernel / board overrides.
    "cpu": _ARM_PLATFORMS, "defconfig": _ARM_PLATFORMS, "dtb": _DTB_PLATFORMS,
    "dtb_prefix": ("rpi5",), "kernel_img": ("rpi5",), "pcie_gen3": ("rpi5",),
    "kernel_flavor": ("jetson",),
    "uboot_url": _UBOOT_PLATFORMS, "uboot_defconfig": _UBOOT_PLATFORMS, "skip_uboot": _UBOOT_PLATFORMS,
    # build plumbing.
    "skip_kernel": _ALL_PLATFORMS, "skip_clean": _ALL_PLATFORMS, "build_subdir": _ALL_PLATFORMS,
    "seed_url": _ALL_PLATFORMS, "version": _ALL_PLATFORMS, "release_tag": _X86,
    "distdir": _X86, "extra_packages": _ARM_PLATFORMS,
    # user package deltas — parsed identically by all six builders (WS-BUILDER flip).
    "packages_add": _ALL_PLATFORMS, "packages_drop": _ALL_PLATFORMS,
}

# Fields delivered OUT-OF-BAND — never a builder CLI flag on any platform, so absent
# from PLATFORM_FIELD_SUPPORT above, but the wizard must STILL show them everywhere
# (they are not "silently dropped"): headscale_url rides as a docker `-e` / native env
# var forwarded by build_driver (G2); pentest is the fleet-level PENTEST=1 env knob
# consumed by build-all-roles.sh / the Makefile (G40); hw_profile is a GUI-only preset
# that pre-fills gpu/wifi/bt and never emits (decided document-as-preset, G41).
#
# superdomain STARTED here (v1: manifest + the KEYS channel that sets .mesh.magic_dns_domain)
# and was flipped by WS-SUPER-B to an emitted --superdomain (all six builders parse it, bake it
# to <etc>/superdomain, and template it into the node's headscale config). It is now in
# PLATFORM_FIELD_SUPPORT above, not here — but emitted ONLY for mesh builds (the orchestration
# plane; standalone joins none), the EFFECTIVE value (derived <brand>.internal when ""), so every
# mesh image RECORDS its plane. It stays permanently internal / never go-live-flipped (I7); the
# v1 KEYS channel remains authoritative for the secret side. packages_add/packages_drop likewise
# STARTED here (WS-CORE Phase 1) and were flipped by WS-BUILDER to emitted
# --packages-add/--packages-drop — they too now live in PLATFORM_FIELD_SUPPORT above, not here.
NON_ARGV_FIELDS = ("headscale_url", "pentest", "hw_profile")


# ── role-class capability layer (Qt-free; BESIDE PLATFORM_FIELD_SUPPORT, NEVER inside
# to_cli_args — invariant I3) ─────────────────────────────────────────────────────────
# A SECOND gating axis on top of the platform axis: whether an image is a person DESKTOP
# (themeable, home-provisionable, tailnet/SSO-optional) or a cluster NODE / headless
# appliance (root-encrypted infrastructure — no theming, no home provisioning, mesh join
# implicit). Keyed on the role id (a shared id like pki/edge_ai is a node on EVERY
# platform it appears on). These predicates run at ModePage.validatePage and inside
# materialize() step 5 — never in to_cli_args, so emission stays a faithful field->argv
# translation (the 51 GUITHR probes thread hand-set fields with no role-class logic).

# Person-desktop / standalone-desktop family (themeable + home-provisionable). Cites
# X86_CLIENT_ROLES + UNAFFILIATED_ROLE above; the ARM desktop role ids mirror ROLE_CHOICES.
_STANDALONE_DESKTOP_ROLES = ("standalone-thin", "standalone-thick", UNAFFILIATED_ROLE)
_ARM_DESKTOP_ROLES = ("rpi5-desktop", "jetson-desktop", "frite", "orangepi5")
DESKTOP_ROLES = X86_CLIENT_ROLES + _STANDALONE_DESKTOP_ROLES + _ARM_DESKTOP_ROLES
# Cluster-node / headless-appliance family (root-encrypted infra). X86_NODE_ROLES already
# covers pki/be/fe/be+gpu/omnibus/edge_ai (x86 AND rpi5 share pki/be/fe; edge_ai is shared
# x86/jetson); jetson adds full/gpu-host; the orangepizero2 appliance and the plain-Gentoo
# rpi5 "generic" server are headless nodes too. Everything not an explicit desktop role
# is treated as a node (fail-safe: infra never accidentally exposes theming/home surfaces).
_JETSON_NODE_ROLES = ("full", "gpu-host")
_APPLIANCE_ROLES = ("orangepizero2", "generic")
NODE_ROLES = X86_NODE_ROLES + _JETSON_NODE_ROLES + _APPLIANCE_ROLES

# The theming + home-provisioning field families gated by role-class. Both families are
# x86-only in emission today, so clearing them never perturbs ARM argv (belt & braces I1).
THEME_FIELDS = ("theme", "branding_dir", "wallpaper", "grub_background", "grub_theme",
                "login_background", "brand_logo", "accent_color", "color_scheme", "brand_locked")
HOME_DESKTOP_FIELDS = ("home_mode", "home_device", "home_backup", "home_encrypted",
                       "home_seed_code", "home_seed_code_from", "include_home_archive",
                       "seed_packages_from")


def image_class(mode: str, role: str) -> str:
    """"desktop" (person device / standalone desktop) or "node" (cluster infra / headless
    appliance). Role id is authoritative; mode is accepted for signature stability."""
    return "desktop" if role in DESKTOP_ROLES else "node"


def rpi_boards_for_role(role: str) -> tuple[str, ...]:
    """The --board choices to OFFER for an rpi5-platform ``role``. A desktop-class role
    (rpi5-desktop) may target any Raspberry Pi board (rpi5/rpi4/rpi3); a node/appliance
    role (pki/be/fe, generic) may target rpi5/rpi4 ONLY — rpi3's 1GB RAM cannot host the
    hardened SELinux/containerd/kubelet stack, and build-rpi5-stage4.sh hard-errors that
    combo. Keeping rpi3 out of the node picker mirrors the builder's own contract so a
    Studio/menu selection can never dead-end in that hard-error (honesty rule)."""
    return RPI_BOARDS if image_class("", role) == "desktop" else RPI_NODE_BOARDS


def branding_allowed(cfg: "ImageConfig") -> bool:
    """Theming is offered only on desktop-class images and never in mesh mode (spec 2)."""
    return image_class(cfg.mode, cfg.role) == "desktop" and cfg.mode != "mesh"


def tailnet_sso_visible(cfg: "ImageConfig") -> bool:
    """Tailnet/SSO checkboxes are user-editable only for cloud branded desktops (spec 3).
    Unaffiliated hard-conflicts with the tailnet; sso additionally keeps its x86-only
    platform gate (applied by strip_platform_unsupported / _gating.gate_widgets)."""
    return (cfg.mode == "cloud" and image_class(cfg.mode, cfg.role) == "desktop"
            and cfg.role != UNAFFILIATED_ROLE)


def home_options_allowed(cfg: "ImageConfig") -> bool:
    """Home provisioning applies to desktop-class images in any mode (spec 7); nodes are
    root-encrypted and have no separately-provisioned home."""
    return image_class(cfg.mode, cfg.role) == "desktop"


def superadmin_plane_applies(cfg: "ImageConfig") -> bool:
    """Whether the superadmin Domains/Users tables contribute anything for this config
    (the wizard's dynamic page-skip predicate, ALL-OPTIONS-safe).

    * mesh  → always (domains/users flow into the mesh manifest).
    * cloud → only for a NON-node role: to_cli_args emits --domains/--person-role solely
      when ``role not in X86_NODE_ROLES`` (build-x86 warns+ignores them on a node role),
      and cloud writes no manifest — so a cloud NODE image's Domains/Users pages emit
      NOTHING and can be skipped without changing the argv.
    * standalone → already statically skipped (MODE_SKIPPED_PAGES); returns False for
      completeness.

    Because a cloud node build emits none of these flags and produces no manifest,
    skipping the pages leaves the argv byte-identical — the emission guard the wizard's
    collect_all (visited-pages-only) requires."""
    if cfg.mode == "mesh":
        return True
    if cfg.mode == "cloud":
        return cfg.role not in X86_NODE_ROLES
    return False


# ── platform-aware default resolution (materialize/spec channel; NEVER to_cli_args) ──
# The dataclass defaults role="standalone-thick" (an x86 CLIENT role) and flavor=""
# — correct for an x86 image, but a worklist entry / synthesized flat config for a
# NON-x86 platform that leaves the role UNSET materializes that x86 role (or a bare
# "" stamped from an unset entry.role) onto a builder that rejects it (gap G3), and
# an UNSET flavor on the ARM ISO platforms (frite/orangepi5/orangepizero2) rides
# to_cli_args's `self.flavor or "both"` default -> the builder emits TWO ISOs, which
# the worker's single-artifact ingest contract rejects after a full build (gap G2).
#
# PLATFORM_DEFAULT_ROLE names the canonical default role per platform, grounded in
# each builder's OWN default: build-rpi5-stage4.sh:99 ROLE="generic",
# build-jetson-stage4.sh:84 ROLE="edge_ai"; frite/orangepi5/orangepizero2 have ONE
# role (the ROLE_CHOICES role-id == platform name) and emit no --role at all. x86
# keeps its dataclass default. A unit test pins every value ∈ roles_for_platform().
PLATFORM_DEFAULT_ROLE = {
    "x86": "standalone-thick",
    "rpi5": "generic",
    "frite": "frite",
    "jetson": "edge_ai",
    "orangepi5": "orangepi5",
    "orangepizero2": "orangepizero2",
}

# The two "unset / at-the-x86-default" role shapes that trigger role resolution: a
# blank role (an unset worklist entry.role) and the x86 dataclass default that a
# synthesized non-x86 flat config carries. An EXPLICITLY-set wrong role (e.g. laptop
# on jetson) is NOT in this set — it is left for the builder's own hard-error so the
# mistake fails LOUD rather than being silently corrected.
_DEFAULT_LEAK_ROLES = ("", PLATFORM_DEFAULT_ROLE["x86"])

# The ARM ISO platforms whose builders take a live|installer|both --flavor. An unset
# flavor resolves to the single-artifact "installer" here (the legacy worker-channel
# default) rather than to_cli_args's "both", so the worker's one-artifact ingest holds.
_ISO_FLAVOR_PLATFORMS = ("frite", "orangepi5", "orangepizero2")


def roles_for_platform(platform: str) -> frozenset:
    """The set of role ids ROLE_CHOICES declares for ``platform`` — inverted from the
    single authoritative role catalog (the same source emit-image-catalog.py consumes),
    never a hand-maintained second list. Used to decide whether a materialized role is
    even valid for the target platform before falling back to PLATFORM_DEFAULT_ROLE."""
    plat = platform or "x86"
    return frozenset(role for choices in ROLE_CHOICES.values()
                     for (role, platforms, _label) in choices if plat in platforms)


def resolve_platform_defaults(cfg: "ImageConfig") -> None:
    """Fill in a platform-correct default role/flavor when a config left them at the
    x86 dataclass default (or blank) and that value is wrong for the target platform.

    Mutates ``cfg`` in place. Called at MATERIALIZE time only
    (WorklistConfig._materialize_one), NEVER in to_cli_args — so every already-valid
    input and the flat to_cli_args `--flavor both` default stay byte-identical, and
    the corrected role/flavor is baked into the materialized spec the worker channel
    (--print-specs -> to_dict) carries. x86 is untouched: standalone-thick ∈
    roles_for_platform("x86"), so the role branch never fires for an x86 image, and
    the flavor branch is frite/orangepi5/orangepizero2 only.
    """
    plat = cfg.platform or "x86"
    # ROLE: only the unset / x86-default leak shapes, and only when that role is not
    # already valid for this platform. An explicit valid role is a no-op; an explicit
    # wrong role is left for the builder's hard-error.
    if cfg.role in _DEFAULT_LEAK_ROLES and cfg.role not in roles_for_platform(plat):
        cfg.role = PLATFORM_DEFAULT_ROLE.get(plat, cfg.role)
    # FLAVOR: the ARM ISO platforms default an unset flavor to a SINGLE artifact so the
    # worker's one-artifact ingest contract holds (to_cli_args's default is "both").
    if plat in _ISO_FLAVOR_PLATFORMS and not cfg.flavor:
        cfg.flavor = "installer"


def _reset_field(cfg: "ImageConfig", name: str) -> bool:
    """Reset one ImageConfig field to its dataclass default. True iff it changed."""
    f = ImageConfig.__dataclass_fields__[name]  # type: ignore[attr-defined]
    default = f.default_factory() if f.default is MISSING else f.default
    if getattr(cfg, name) != default:
        setattr(cfg, name, default)
        return True
    return False


def clear_role_class_fields(cfg: "ImageConfig") -> list[str]:
    """Zero the theming/home field families (and tailscale/sso) the current role-class
    does NOT permit, so a stale desktop value picked before a mode/role switch can never
    leak into a node's save or (belt & braces) its argv. Returns the fields cleared. The
    caller re-forces mesh tailscale/sso afterwards (enter_mesh_defaults / materialize)."""
    cleared: list[str] = []
    if not branding_allowed(cfg):
        cleared += [f for f in THEME_FIELDS if _reset_field(cfg, f)]
    if not home_options_allowed(cfg):
        cleared += [f for f in HOME_DESKTOP_FIELDS if _reset_field(cfg, f)]
    if not tailnet_sso_visible(cfg):
        cleared += [f for f in ("tailscale", "sso") if _reset_field(cfg, f)]
    return cleared


def enter_mesh_defaults(cfg: "ImageConfig") -> None:
    """Mesh entry: clear every role-class desktop surface, then force tailscale=sso=True
    so mesh x86 nodes keep emitting today's --with-tailscale/--with-sso byte-identically
    (ARM joins mesh unless --skip-mesh; sso is x86-only in emission)."""
    clear_role_class_fields(cfg)
    cfg.tailscale = True
    cfg.sso = True


def strip_platform_unsupported(cfg: "ImageConfig") -> list[str]:
    """Qt-free twin of gui/pages/_gating.clear_unsupported keyed on PLATFORM_FIELD_SUPPORT:
    reset every field the selected platform's builder has no flag for, so a value set on
    another platform can never linger into a save or the emitted argv. Returns the fields
    cleared. Fields absent from the table are all-platform (fail-open) and untouched."""
    cleared: list[str] = []
    plat = cfg.platform or "x86"
    for fld, plats in PLATFORM_FIELD_SUPPORT.items():
        if plat in plats:
            continue
        if _reset_field(cfg, fld):
            cleared.append(fld)
    return cleared


@dataclass
class Domain:
    name: str = ""
    title: str = ""
    # Worklist entry-id refs this domain attaches to (f"{role}.{platform}"); empty =
    # attach to every eligible image. Legacy `games: bool` was DROPPED — from_dict
    # migrates a truthy games into optional_services += ["games"] (games never reached
    # argv, so zero emission change; intent preserved, never silently dropped).
    images: list[str] = field(default_factory=list)
    optional_services: list[str] = field(default_factory=list)  # akkoma/tuwunel/phpbb/owncast/tor...


@dataclass
class User:
    username: str = ""
    domain: str = ""
    role: str = "user"                 # superadmin|admin|mod|user (+games roles)
    email: str = ""
    # First-login registration METHOD (spec 4/6): "" = derive (builder/provisioning
    # default) | discord | gmail | password. Manifest-only — NEVER reaches to_cli_args
    # (User is provisioning data, not argv). "password" records that this account is
    # given a RANDOM password generated + presented at provisioning time; no plaintext
    # secret is ever stored on the User (so it is safe to serialize/save like the other
    # User fields — nothing to blank).
    registration: str = ""


@dataclass
class ImageConfig:
    # ── identity / mode ──
    mode: str = "standalone"           # standalone | cloud | mesh
    role: str = "standalone-thick"
    platform: str = "x86"              # x86 | rpi5 | frite | jetson -> BUILDER_SCRIPTS
    board: str = ""                    # frite: FRITE_BOARDS | jetson: JETSON_BOARDS | rpi5: RPI_BOARDS
    flavor: str = ""                   # frite: live | installer | both
    env: str = "test"
    brand: str = "snapdragon"
    brand_title: str = "Snapdragon Systems"
    org: str = "Snapdragon-Systems"
    brand_profile: str = ""            # -C/--config brands/*.conf (carries HEADSCALE_URL/RELEASE_STATE/… presets)
    cluster_domain: str = "snapdragon.systems"
    superdomain: str = ""              # orchestration superdomain all mesh nodes join; "" = derived <brand>.internal. Emitted as --superdomain for MESH builds (WS-SUPER-B: baked to <etc>/superdomain + headscale MagicDNS); permanently internal, never go-live-flipped (I7)
    games_domain: str = ""             # --games-domain (games.<domain> host + OIDC issuer; x86+rpi5)
    release_state: str = ""            # --release-state internal|public (x86+rpi5; "" = builder default)
    release_tag: str = ""              # --release-tag image stamp (x86)
    version: str = ""                  # -v/--version image stamp (all)
    person_role: str = ""              # --person-role user|mod|admin|superadmin (x86 CLIENT roles; "" = derive)
    hostname: str = ""                 # -H/--hostname baked host identity (all)
    timezone: str = ""                 # -T/--timezone baked host identity (all)
    user: str = ""                     # -u/--user baked default account name (all; distinct from --local-user)
    local_user: str = "magus"
    local_pass: str = ""               # --local-pass (SECRET — never saved; live cmd only)
    user_password: str = ""            # --user-password node FALLBACK cred (SECRET; x86)
    root_password: str = ""            # --root-password node FALLBACK cred (SECRET; x86)
    standalone: bool = False           # --standalone (arm64 only; x86 gets it via role name)
    capable: bool = False              # --capable (most-capable Plasma payload, 50GiB root; x86, composable)
    unaffiliated: bool = False         # --unaffiliated as a COMPOSABLE flag (x86; role standalone-unaffiliated presets it)
    # ── network / identity plane ──
    # MODE-AWARE tri-states (see tailscale_enabled()/sso_enabled()): "" (never
    # set) = the MODE default — cloud/mesh ON, standalone OFF, the same rule
    # NetworkPage.initializePage seeds into the checkboxes — while a BOOL is
    # ALWAYS an explicit choice (the GUI checkboxes collect bools; False from a
    # mesh build is a user who UNCHECKED the box and still gets --no-*). This
    # deliberately differs from the G34 _tri() convention (False = leave
    # default) — with a former plain-bool default of False, a mesh/cloud config
    # JSON that simply OMITTED these keys printed --no-tailscale/--no-sso (x86)
    # / --skip-mesh (ARM): headless callers got a non-mesh mesh image.
    tailscale: bool | str = ""         # --with-tailscale / --no-tailscale ('' | True/'on' | False/'off')
    sso: bool | str = ""               # --with-sso / --no-sso ('' | True/'on' | False/'off')
    headscale_url: str = ""            # brand mesh control-server URL — NOT a builder flag; env passthrough in build_driver (G2)
    headscale_version: str = ""        # --headscale-version pin (all)
    tailscale_version: str = ""        # --tailscale-version pin (all)
    skip_tailscale: bool = False       # --skip-tailscale: headscale-only posture, distinct from --skip-mesh (all)
    # ── hardware ──
    gpu_driver: str = "auto"           # auto|nvidia|amd-free|amd-pro|intel|none
    nvidia_cuda: bool = False          # --nvidia-cuda (CUDA bake for GPU/edge-AI images; x86)
    hw_profile: str = ""               # a hwprofiles/<id> preset — GUI-ONLY (sets gpu/wifi/bt presets; NEVER emits; G41)
    kernel_builtin: bool = False       # --kernel-builtin
    enable_wifi: bool = False          # --enable-wifi
    enable_bluetooth: bool = False     # --enable-bluetooth
    # ── ARM kernel / board overrides (per-platform; "" = builder default) ──
    cpu: str = ""                      # -c/--cpu (all ARM)
    defconfig: str = ""                # -d/--defconfig (all ARM)
    dtb: str = ""                      # --dtb (frite/jetson/opi5/opz2)
    dtb_prefix: str = ""               # --dtb-prefix (rpi5)
    kernel_img: str = ""               # --kernel-img (rpi5)
    pcie_gen3: bool = False            # --pcie-gen3 (rpi5 NVMe)
    kernel_flavor: str = ""            # --kernel-flavor mainline|l4t (jetson)
    uboot_url: str = ""                # --uboot-url (frite/opi5/opz2 — flashability-critical prebuilt)
    uboot_defconfig: str = ""          # --uboot-defconfig (frite/opi5/opz2)
    skip_uboot: bool = False           # --skip-uboot (frite/opi5/opz2)
    # ── branding ──
    theme: str = ""                    # --theme NAME
    branding_dir: str = ""             # --branding-dir DIR
    wallpaper: str = ""
    grub_background: str = ""
    grub_theme: str = ""               # --grub-theme DIR (a full GRUB theme dir, distinct from grub_background)
    login_background: str = ""
    brand_logo: str = ""
    accent_color: str = ""
    color_scheme: str = ""
    brand_locked: bool = False
    # ── egress VPN ──
    egress_vpn: str = ""               # --egress-vpn FILE
    egress_vpn_locked: bool = False
    # ── network/host security stack ──
    proxy_stack: str = "auto"          # auto|on|off — Squid+Privoxy+Firefox (desktops)
    snort: bool = True                 # Snort IDS (default-on, all images)
    # Tri-state (accepts bool for back-compat via _tri): False/""/None = leave the
    # builder/brand.conf default; True/"on" = --with-*; "off" = force --no-* so a
    # brand-profile default can be overridden OFF from the GUI (G34).
    aide: bool | str = False           # --with-aide / --no-aide (x86)
    root_login: str = "no"             # --permit-root-login: no (DEFAULT, hardened) | prohibit-password | yes
    # ── edge-AI inference (GPU cluster roles: be+gpu / omnibus / edge_ai) ──
    edge_ai_service: bool | str = False  # tri-state: --with-edge-ai / --no-edge-ai (edge_ai role auto-has it)
    edge_ai_runtime: str = "ollama"    # ollama | vllm
    edge_ai_models: str = ""           # comma list of models to PRELOAD (empty = builder default)
    edge_ai_model_default: str = ""    # default model when an OpenAI request omits one
    edge_ai_analysis: bool = False     # also bake the edge-ai-analysis task API (image/log verdicts; separate image)
    # edge-ai-tts is CPU-only + self-contained (baked-in voice model, no upstream
    # call) — UNLIKE edge_ai_analysis it has NO edge-ai dependency, so it is its own
    # independent tri-state (mirrors character_studio's shape, not edge_ai_analysis's
    # plain-bool fold-with-dependency shape) and is wired on BOTH x86 AND rpi5.
    edge_ai_tts: bool | str = False    # tri-state: --with-edge-ai-tts / --no-edge-ai-tts (Piper TTS + visemes; separate image)
    # ── Tor v3 onion (hidden) service — node-scoped optional, default off ──
    tor_onion_service: bool | str = False  # tri-state: --with-tor / --no-tor (expose fe-gateway as a v3 .onion)
    # ── Character Studio (VN) frontend remote — OPTIONAL, default off (admin gate) ──
    character_studio: bool | str = False  # tri-state: --with-character-studio / --no-character-studio
    # ── cluster optional services + games (node-scoped) ──
    optional_services: list[str] = field(default_factory=list)  # --optional-services slugs (+ none/all sentinels)
    exclude_services: list[str] = field(default_factory=list)   # --exclude-services subtractive list (applied last)
    enable_games: bool = False         # --enable-games (Game Studio + games.<domain>)
    # ── client desktop weight / gaming delivery (x86 client roles; frite: light|none) ──
    desktop: str = ""                  # --desktop: x86 thin|full; frite light|none ("" = default)
    steam: str = ""                    # --steam native|flatpak|none ("" = builder default)
    # ── external media data device (Steam library + gocryptfs Vaults; x86 standalone) ──
    media_data: bool | str = ""        # tri-state: --media-data / --no-media-data (builder default ON)
    media_label: str = ""              # --media-label
    no_vaults: bool = False            # --no-vaults (drop the gocryptfs Vaults set)
    # ── Secure Boot + KEYS-USB signing chain (x86 only; builder default SECURE_BOOT=on) ──
    secure_boot: str = ""              # tri-state "" | "on" (--secure-boot) | "off" (--no-secure-boot)
    keys_usb: str = ""                 # --keys-usb DIR (existing fleet SB signing key Keys/kernel_key.{pem,der})
    secureboot_key: str = ""           # --secureboot-key PATH
    secureboot_cert: str = ""          # --secureboot-cert PATH
    # ── root-disk encryption (installer LUKS2 FDE) ──
    encrypt_root: bool = False         # --encrypt-root
    luks_pass: str = ""                # --luks-pass (SECRET — never saved; live cmd only)
    unlock_keyfile: str = ""           # --unlock-keyfile boot|login ("" = off)
    unlock_yubikey: str = ""           # --unlock-yubikey boot|login ("" = off)
    # ── home provisioning ──
    home_mode: str = "create"          # create|adopt|archive|restore
    home_device: str = ""
    home_backup: str = ""
    home_encrypted: bool = False
    home_seed_code: str = "none"       # none|repos|stack|mesh
    home_seed_code_from: str = ""      # --home-seed-code-from PATH (x86)
    include_home_archive: str = ""     # --include-home-archive FILE (x86)
    seed_packages_from: str = ""       # --seed-packages-from FILE (x86)
    # ── installer / ISO / artifact selection ──
    installer_ui: str = "all"          # cli|ncurses|calamares|all
    cached: bool = False               # --cached / --uncached
    live_toram: bool = True            # --live-toram / --no-live-toram
    bundle_source: bool = True         # --bundle-source / --no-bundle-source
    build_img: bool | str = ""         # tri-state --img / --no-img (x86/rpi5/jetson)
    live_iso: bool | str = ""          # tri-state --live-iso / --no-live-iso (x86)
    installer_iso: bool = False        # --installer-iso (x86; direct, not only an encrypt-root side effect)
    build_tar: bool | str = ""         # tri-state --tar / --no-tar (x86/rpi5)
    skip_iso: bool = False             # --skip-iso (x86/rpi5)
    build_iso: bool = False            # --iso (rpi5: build installer ISO for an UNencrypted image)
    sd_only: bool = False              # --sd-only (rpi5)
    image_only: bool = False           # --image-only (frite/jetson/opi5/opz2)
    grow: str = ""                     # --grow fill|none|<size> first-boot root-growth policy (all; "" = default)
    img_size: int = 0                  # --img-size MiB (0 = role default)
    # ── admin-supplied secrets (cloud/mesh) ──
    keyzip: str = ""                   # an admin key-zip (keys/certs/egress) for this user's domain
    # ── superadmin mesh ──
    domains: list[Domain] = field(default_factory=list)
    users: list[User] = field(default_factory=list)
    # ── build ──
    output_dir: str = ""
    # Host-aware default (cores AND memory headroom; see host_resources.default_jobs —
    # 2026-07-15 host-freeze guard). Applies exactly ONCE, at fresh-config creation:
    # to_dict/asdict pins the number into the saved JSON, and from_dict assigns a
    # present "jobs" key verbatim — an existing config's -j emission is byte-identical.
    jobs: int = field(default_factory=default_jobs)
    compress: bool = False             # --compress: xz -9 the finished image(s)
    resume: bool = False               # --resume: reuse an existing sysroot
    # build plumbing / phases (change baked content or phases, not artifacts)
    skip_kernel: bool = False          # --skip-kernel (all)
    skip_clean: bool = False           # --skip-clean (all)
    distdir: str = ""                  # --distdir (x86: reuse a distfiles cache)
    build_subdir: str = ""             # --build-subdir (all)
    seed_url: str = ""                 # --seed-url stage3 seed (all)
    extra_packages: str = ""           # -p/--extra-packages (ARM only; x86 has no -p) — KEPT FROZEN (verbatim load/save/emission; no migration)
    # Portage atom deltas (space-separated) relative to the builder-derived default set.
    # Phase 1 (WS-CORE): NON_ARGV_FIELDS — stored/saved/validated, ZERO emission (WS-BUILDER
    # atomically flips them to --packages-add/--packages-drop later). Kept SEPARATE from
    # extra_packages (no merging).
    packages_add: str = ""             # atoms to add on top of the default set
    packages_drop: str = ""            # default-set atoms to remove (honoring the mandatory floor)
    # PENTEST=1 OWASP pen-test toggle — NOT a per-builder flag; a FLEET/env knob the
    # build_driver/fleet channel forwards (build-all-roles.sh / Makefile), never argv (G40).
    pentest: bool = False
    extra_flags: str = ""              # escape hatch — shlex-split, appended verbatim

    # ---- (de)serialization -------------------------------------------------
    def to_dict(self, include_secrets: bool = False) -> dict[str, Any]:
        """Serialize; plaintext secrets (SECRET_FIELDS) are BLANKED unless the caller
        explicitly opts in — a saved JSON config must never carry a password."""
        d = asdict(self)
        if not include_secrets:
            for k in SECRET_FIELDS:
                d[k] = ""
        return d

    @staticmethod
    def _domain_from_dict(x: dict[str, Any]) -> "Domain":
        """Build a Domain from a raw dict, filtering unknown nested keys (forward-compat)
        and MIGRATING the dropped legacy `games: true` into optional_services += ["games"]
        (intent preserved, never silently dropped; games never reached argv)."""
        dom_f = set(Domain.__dataclass_fields__)
        kw = {k: v for k, v in x.items() if k in dom_f}
        if x.get("games"):
            svcs = list(kw.get("optional_services") or [])
            if "games" not in svcs:
                svcs.append("games")
            kw["optional_services"] = svcs
        return Domain(**kw)

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "ImageConfig":
        if not isinstance(d, dict):
            # A top-level JSON array/scalar reaches `dict(d)` below as a non-mapping and
            # raises TypeError; normalize to ValueError so the headless --print-* handlers
            # (and every other loader) surface a clean "error: ..." + exit 2 instead of a
            # traceback + exit 1, matching the json.JSONDecodeError (also a ValueError) path.
            raise ValueError(
                f"config must be a JSON object, got {type(d).__name__} "
                "(a top-level array or scalar is not a valid image config)")
        d = dict(d)
        usr_f = set(User.__dataclass_fields__)
        # tolerate "domains": null / "users": null and unknown nested keys
        d["domains"] = [cls._domain_from_dict(x) if isinstance(x, dict) else x
                        for x in (d.get("domains") or [])]
        d["users"] = [User(**{k: v for k, v in x.items() if k in usr_f}) if isinstance(x, dict) else x
                      for x in (d.get("users") or [])]
        # The mode-aware tri-states: normalize the 'on'/'off' hand-written
        # spellings to bools AT LOAD (fail-closed on junk), so the in-memory value
        # is always bool-or-'' — NetworkPage.initializePage seeds its checkboxes
        # with a truthy test (`c.tailscale or c.mode in ...`) that a truthy 'off'
        # string would silently invert.
        for k in ("tailscale", "sso"):
            if k in d:
                v = cls._tri_explicit(d[k], k)
                d[k] = "" if v is None else v
        known = set(cls.__dataclass_fields__)  # type: ignore[attr-defined]
        return cls(**{k: v for k, v in d.items() if k in known})

    def save(self, path: str) -> list[str]:
        """Write the config JSON (secrets blanked). Returns human-readable warnings
        for any secret that was set but NOT persisted, so the UI can surface it."""
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(self.to_dict(), fh, indent=2)
        return [f"{k.replace('_', '-')} was NOT saved (plaintext secret) — re-enter it "
                "before building from this config" for k in SECRET_FIELDS if getattr(self, k)]

    @classmethod
    def load(cls, path: str) -> "ImageConfig":
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        # A worklist envelope carries an explicit `schema` discriminator; from_dict would
        # silently DEGRADE it to a default config (it drops unknown top-level keys). Fail
        # loudly so callers route it through the envelope loader instead.
        if isinstance(data, dict) and "schema" in data:
            raise ValueError(
                "worklist envelope — open via worklist.load_any / --print-commands")
        return cls.from_dict(data)

    def effective_superdomain(self) -> str:
        """The orchestration superdomain every mesh node joins. An explicit superdomain
        wins; "" derives f"{brand}.internal" (permanently internal — never the go-live
        apex, which stays cluster_domain, I7)."""
        return self.superdomain or f"{self.brand}.internal"

    # ---- identity validation (fail-closed) ---------------------------------
    def validate_identity(self) -> None:
        """Allowlist every identity field that flows into a root-sourced KEY=VALUE
        file (brand.conf / home.conf) or a sed replacement in the generator.

        Fail-closed: raise IdentityValidationError on any value that is not a
        known-safe shape, BEFORE it can reach --brand/--org/--local-user/--home-*.
        Defense-in-depth that does not rely on the build script's own escaping.
        """
        # always emitted
        validate_username(self.local_user)
        # brand / org / brand_title flow into brand.conf (sourced as root)
        validate_brand(self.brand)
        validate_org(self.org)
        validate_brand_title(self.brand_title)
        validate_accent_color(self.accent_color)
        # cluster_domain + per-domain names flow into --domains / the mesh manifest
        validate_domain_name(self.cluster_domain)
        if self.games_domain:
            validate_domain_name(self.games_domain)
        # orchestration superdomain: "" = derived <brand>.internal (always valid once
        # brand is validated). Validate an explicit value like any other domain name
        # (core.validate accepts .internal). Feeds the manifest + the KEYS channel.
        if self.superdomain:
            validate_domain_name(self.superdomain)
        for d in self.domains:
            if getattr(d, "name", ""):
                validate_domain_name(d.name)
        # baked host identity (-H/-T/-u) flows into root-sourced config; fail closed.
        if self.hostname:
            validate_domain_name(self.hostname)   # a hostname is a DNS label/name
        if self.user:
            validate_username(self.user)
        if self.timezone and not _TIMEZONE_RE.fullmatch(self.timezone):
            raise IdentityValidationError(
                f"invalid timezone: {self.timezone!r} — rejected by the identity allowlist")
        if self.media_label and not _MEDIA_LABEL_RE.fullmatch(self.media_label):
            raise IdentityValidationError(
                f"invalid media_label: {self.media_label!r} — rejected by the identity allowlist")
        # home provisioning fields flow into home.conf (sourced as root)
        if self.home_device:
            validate_home_device(self.home_device)
        if self.home_backup:
            validate_home_backup(self.home_backup)
        # Portage atom deltas — space-separated category/name atoms. Must stay shell-word-
        # safe wherever they are eventually emitted (NON_ARGV in Phase 1; --packages-add /
        # --packages-drop later). Fail closed on any shell/sed-meaningful character.
        validate_package_atoms(self.packages_add)
        validate_package_atoms(self.packages_drop)

    # ---- the canonical flag translation ------------------------------------
    @property
    def builder_script(self) -> str:
        try:
            return BUILDER_SCRIPTS[self.platform or "x86"]
        except KeyError:
            raise ValueError(f"unknown platform: {self.platform!r} "
                             f"(known: {', '.join(BUILDER_SCRIPTS)})") from None

    def to_cli_args(self) -> list[str]:
        """Build the argument list for this platform's builder script. Only emits
        flags that differ from the script's own defaults, so the command stays
        readable — and only flags THAT builder parses (each script has its own
        surface). The extra_flags escape hatch is appended verbatim (shlex-split)
        so every CLI option stays expressible even if unfielded."""
        # Reject injection-shaped identity values at the earliest boundary, before
        # they can reach the root-sourced brand.conf/home.conf or a sed replacement.
        self.validate_identity()
        plat = self.platform or "x86"
        if plat == "x86":
            a = self._x86_args()
        elif plat == "rpi5":
            a = self._rpi5_args()
        elif plat == "frite":
            a = self._frite_args()
        elif plat == "jetson":
            a = self._jetson_args()
        elif plat == "orangepi5":
            a = self._orangepi5_args()
        elif plat == "orangepizero2":
            a = self._orangepizero2_args()
        else:
            raise ValueError(f"unknown platform: {self.platform!r} "
                             f"(known: {', '.join(BUILDER_SCRIPTS)})")
        if self.extra_flags:
            a += shlex.split(self.extra_flags)
        return a

    @staticmethod
    def _tri(value: bool | str) -> str:
        """Normalize a tri-state field to '', 'on' or 'off'. Accepts bools for
        backward-compat (True->'on', False->'') so a plain checkbox and a 3-way
        force-off combo drive the same emission (G34)."""
        if value is True:
            return "on"
        if value in (False, None, ""):
            return ""
        return str(value)

    @staticmethod
    def _tri_explicit(value: bool | str, field_name: str) -> bool | None:
        """Resolve a MODE-AWARE tri-state (tailscale/sso) to an explicit bool, or
        None when never set. UNLIKE _tri()/G34 (where False = 'leave the builder
        default'), a bool here is ALWAYS an explicit user choice: the NetworkPage
        boxes are plain 2-state checkboxes that initializePage seeds from the mode
        and validatePage collects back as bools — so False from the GUI is a user
        who UNCHECKED the box on a mesh build and must still get the explicit
        --no-* flag. Only the never-set sentinel '' (the dataclass default, which
        the GUI never writes) defers to the mode default. 'on'/'off' are accepted
        for hand-written configs; anything else is rejected fail-closed (a typo
        like "yes" must never silently strip the mesh off a mesh image)."""
        if value is True or value == "on":
            return True
        if value is False or value == "off":
            return False
        if value in (None, ""):
            return None
        raise ValueError(f"{field_name} must be true / false / 'on' / 'off' / '' "
                         f"(got {value!r})")

    def _mesh_mode_default(self) -> bool:
        """cloud/mesh default the mesh/SSO plane ON, standalone OFF — the same rule
        NetworkPage.initializePage uses to seed the checkboxes (gui/pages/network.py),
        applied at emission time so a headless config that never set the fields
        builds the SAME image the GUI flow would produce."""
        return self.mode in ("cloud", "mesh")

    def tailscale_enabled(self) -> bool:
        """The RESOLVED mesh plane: the explicit user choice, else the mode default.
        Passed through verbatim even on an x86 cluster NODE role — the builder does
        NOT force mesh back on there (build-x86-host-stage4.sh: SKIP_MESH=false
        default at 122; only the flag arms 707-712 and the standalone posture
        1083-1089 touch SKIP_MESH — no role arm at 950-1019 does), so an explicit
        off genuinely ships a mesh-less node, mirroring the builder."""
        v = self._tri_explicit(self.tailscale, "tailscale")
        return self._mesh_mode_default() if v is None else v

    def sso_enabled(self) -> bool:
        """The RESOLVED Casdoor/OIDC SSO plane (x86-only flag; see
        tailscale_enabled() — build-x86-host-stage4.sh's SKIP_SSO mirrors
        SKIP_MESH: default false at 173, flag arms 738-741, standalone posture
        1089, no role-based forcing)."""
        v = self._tri_explicit(self.sso, "sso")
        return self._mesh_mode_default() if v is None else v

    def _brand_args(self) -> list[str]:
        """The brand-identity flags every builder parses identically (+ the -C/--config
        brand-profile picker, which is sourced before the CLI). Suppressed for the x86
        unaffiliated role (which bakes zero brand)."""
        a: list[str] = []
        if self.brand_profile:
            a += ["--config", self.brand_profile]
        if self.brand != "snapdragon":
            a += ["--brand", self.brand]
        if self.brand_title != "Snapdragon Systems":
            a += ["--brand-title", self.brand_title]
        if self.org != "Snapdragon-Systems":
            a += ["--org", self.org]
        return a

    def _identity_args(self) -> list[str]:
        """Baked host identity every builder parses (-H/-T/-u). '' = the builder's own
        role-derived hostname / UTC / default account."""
        a: list[str] = []
        if self.hostname:
            a += ["--hostname", self.hostname]
        if self.timezone:
            a += ["--timezone", self.timezone]
        if self.user:
            a += ["--user", self.user]
        return a

    def _mesh_version_args(self) -> list[str]:
        """--headscale-version / --tailscale-version pins + --skip-tailscale (a
        headscale-only posture, distinct from --skip-mesh) — every builder parses all
        three."""
        a: list[str] = []
        if self.headscale_version:
            a += ["--headscale-version", self.headscale_version]
        if self.tailscale_version:
            a += ["--tailscale-version", self.tailscale_version]
        if self.skip_tailscale:
            a += ["--skip-tailscale"]
        return a

    def _plumbing_args(self) -> list[str]:
        """Build phases / plumbing every builder parses (-v/--version, --build-subdir,
        --seed-url, --skip-kernel, --skip-clean). x86-only --distdir and ARM-only
        -p/--extra-packages are emitted by their own methods."""
        a: list[str] = []
        if self.version:
            a += ["--version", self.version]
        if self.build_subdir:
            a += ["--build-subdir", self.build_subdir]
        if self.seed_url:
            a += ["--seed-url", self.seed_url]
        if self.skip_kernel:
            a += ["--skip-kernel"]
        if self.skip_clean:
            a += ["--skip-clean"]
        return a

    def _grow_args(self) -> list[str]:
        """--grow fill|none|<size> first-boot root-growth policy (/etc/growfs.conf).
        Every builder parses --grow/--no-grow; '' = leave the builder default (G25)."""
        return ["--grow", self.grow] if self.grow else []

    def _services_args(self) -> list[str]:
        """--optional-services allow-list (with the explicit-none / --all-services
        sentinels, G13/G14) + the subtractive --exclude-services list. Shared by x86 +
        rpi5, the only builders that parse them."""
        a: list[str] = []
        svcs = list(self.optional_services or [])
        if svcs == [SERVICES_NONE]:
            a += ["--optional-services", ""]           # EXPLICIT none (suppress the builder default)
        elif svcs == [SERVICES_ALL] or SERVICES_ALL in svcs:
            a += ["--all-services"]                    # full user-level set
        elif svcs:
            # SPACE-separated: the builders word-split OPTIONAL_SERVICES on IFS
            # whitespace (it stays ONE argv element — shlex.quote on print).
            a += ["--optional-services", " ".join(svcs)]
        if self.exclude_services:
            a += ["--exclude-services", " ".join(self.exclude_services)]
        return a

    def _character_studio_args(self) -> list[str]:
        """--with-character-studio / --no-character-studio tri-state (x86 + rpi5)."""
        cs = self._tri(self.character_studio)
        if cs == "on":
            return ["--with-character-studio"]
        if cs == "off":
            return ["--no-character-studio"]
        return []

    def _edge_ai_tts_args(self) -> list[str]:
        """--with-edge-ai-tts / --no-edge-ai-tts tri-state (x86 + rpi5). CPU-only,
        self-contained — NO edge-ai dependency (unlike edge_ai_analysis's plain-bool
        fold), so it is its own independent flag pair, mirroring character_studio."""
        tts = self._tri(self.edge_ai_tts)
        if tts == "on":
            return ["--with-edge-ai-tts"]
        if tts == "off":
            return ["--no-edge-ai-tts"]
        return []

    def _arm_kernel_args(self) -> list[str]:
        """-c/--cpu, -d/--defconfig kernel/toolchain overrides (every ARM builder)."""
        a: list[str] = []
        if self.cpu:
            a += ["--cpu", self.cpu]
        if self.defconfig:
            a += ["--defconfig", self.defconfig]
        return a

    def _uboot_args(self) -> list[str]:
        """U-Boot chain overrides (frite / orangepi5 / orangepizero2). --uboot-url is
        flashability-critical (frite FIP/BL31-signed prebuilt; opi5 rkbin DDR-init +
        TF-A BL31) — a GUI image may not be flashable at all without it (G35)."""
        a: list[str] = []
        if self.uboot_url:
            a += ["--uboot-url", self.uboot_url]
        if self.uboot_defconfig:
            a += ["--uboot-defconfig", self.uboot_defconfig]
        if self.skip_uboot:
            a += ["--skip-uboot"]
        return a

    def _packages_delta_args(self) -> list[str]:
        """--packages-add / --packages-drop — space-separated Portage-atom deltas
        on top of the builder's derived default set. Emitted on ALL six platforms
        (each builder parses them identically; drop is a final grep -vE honoring the
        mandatory-payload floor, never emerge --exclude). Empty = builder default, so
        every legacy flat config stays byte-identical (invariant I1). Atom-charset
        validation lives in validate_identity (validate_package_atoms), not here —
        emission stays a faithful field->argv translation."""
        a: list[str] = []
        if self.packages_add:
            a += ["--packages-add", self.packages_add]
        if self.packages_drop:
            a += ["--packages-drop", self.packages_drop]
        return a

    def _superdomain_args(self) -> list[str]:
        """--superdomain <effective_superdomain()> — the mesh orchestration plane every
        node joins (baked to <etc>/superdomain + templated into the node's headscale
        MagicDNS suffix by the builder). GATE: mesh mode ONLY. The superdomain IS the
        orchestration plane, so a standalone image (no plane at all) emits nothing, and
        a cloud CLIENT desktop — a consumer of a tailnet, never the definer of the
        orchestration plane — is likewise NOT baked with one. This mirrors the mesh-only
        v1 KEYS channel (gen-provision-keys sets .mesh.magic_dns_domain only on NODE
        builds); baking cloud too would double-configure against that channel.
        The EFFECTIVE value is always emitted (derived <brand>.internal when the field is
        ""), so every mesh image RECORDS its plane on disk — an intentional
        emission-behaviour change (like --cluster-domain), goldens updated. The value is
        permanently internal and never go-live-flipped (invariant I7); the flag is the
        authoritative on-image BAKE while the KEYS channel stays authoritative for the
        secret side (provision_headscale re-templates at first boot to the same value)."""
        if self.mode == "mesh":
            return ["--superdomain", self.effective_superdomain()]
        return []

    def _arm_common_args(self) -> list[str]:
        """Flags shared by ALL FIVE arm64 builders beyond the brand block: env baking,
        host identity, cluster domain, mesh opt-out + version pins, standalone/local
        account, radios, root login, kernel overrides, grow/sizing, plumbing, finish.
        (Per-platform-only flags — games-domain/release-state/services on rpi5,
        u-boot/dtb/artifact axes — live in each platform method, since emitting a flag
        a given builder does not parse would make it exit 'Unknown option'.)"""
        a: list[str] = ["--env", self.env]
        a += self._brand_args()
        a += self._identity_args()
        if self.cluster_domain != "snapdragon.systems":
            a += ["--cluster-domain", self.cluster_domain]
        # Orchestration superdomain — mesh-only, grouped with the cluster/mesh identity
        # plane (see _superdomain_args). Empty for cloud/standalone, so every existing
        # ARM cloud/standalone golden stays byte-identical.
        a += self._superdomain_args()
        # The arm builders have no --with/--no-tailscale pair; mesh is on unless
        # skipped. A never-set field resolves to the MODE default (cloud/mesh ON,
        # standalone OFF) so a mesh config that omits the key keeps its mesh.
        if not self.tailscale_enabled():
            a += ["--skip-mesh"]
        a += self._mesh_version_args()
        # --standalone: local user, no mesh, LUKS2-encrypted root. Only meaningful on a
        # client-desktop role; each builder hard-errors on a cluster-node role.
        if self.standalone:
            a += ["--standalone"]
        # --local-user/--local-pass compose WITHOUT --standalone too (G28): the ARM
        # builders accept them independently to rename/hash the default account. Emit
        # when standalone, OR when the account name was customized off the Studio
        # default, OR when a password was supplied.
        if self.standalone or self.local_user != "magus" or self.local_pass:
            a += ["--local-user", self.local_user]
            if self.local_pass:
                a += ["--local-pass", self.local_pass]
        if self.enable_wifi:
            a += ["--enable-wifi"]
        if self.enable_bluetooth:
            a += ["--enable-bluetooth"]
        if self.root_login and self.root_login != "no":
            a += ["--permit-root-login", self.root_login]
        a += self._arm_kernel_args()
        if self.extra_packages:
            a += ["--extra-packages", self.extra_packages]
        a += self._packages_delta_args()
        a += self._grow_args()
        if self.img_size:
            a += ["--img-size", str(self.img_size)]
        a += self._plumbing_args()
        if self.compress:
            a += ["--compress"]
        if self.resume:
            a += ["--resume"]
        return a

    def _encrypt_root_args(self) -> list[str]:
        """--encrypt-root / --luks-pass — landed on x86/Frite/RPi5/Jetson (all
        four platforms as of Phase 2c); kept as its own opt-in helper (called
        from each builder method) rather than folded into _arm_common_args()."""
        a: list[str] = []
        if self.encrypt_root:
            a += ["--encrypt-root"]
        if self.luks_pass:
            # plaintext ONLY on the live command line — never persisted (SECRET_FIELDS)
            a += ["--luks-pass", self.luks_pass]
        return a

    def _rpi5_args(self) -> list[str]:
        """build-rpi5-stage4.sh — arm64: pki | backend | frontend (cluster nodes)
        or desktop (client; compose with --standalone for FDE, no mesh). --board
        (RPI_BOARDS: rpi5 [DEFAULT] | rpi4 | rpi3) picks the board table
        (Phase 6 Pi 4 support, Phase 8 Pi 3 support) — ONE builder, mirrors
        _jetson_args()'s board handling. rpi3 is DESKTOP-ONLY (1GB RAM): the
        builder hard-errors if role != desktop; this method does not
        pre-validate that combo, same as it doesn't for any other builder
        constraint (the shell script is the single source of truth there)."""
        a = ["--role", RPI5_ROLE_MAP.get(self.role, self.role)]
        if self.board:                 # rpi5 | rpi4 | rpi3 ("" = builder default: rpi5)
            a += ["--board", self.board]
        # rpi5-only kernel/board overrides (x86 & the other ARM builders lack these).
        if self.dtb_prefix:
            a += ["--dtb-prefix", self.dtb_prefix]
        if self.kernel_img:
            a += ["--kernel-img", self.kernel_img]
        if self.pcie_gen3:
            a += ["--pcie-gen3"]
        a += self._arm_common_args()
        a += self._encrypt_root_args()
        # rpi5 shares x86's cluster identity surface (release-state / games-domain /
        # the optional-services checklist) — the other ARM builders bake no cluster tree.
        if self.release_state:
            a += ["--release-state", self.release_state]
        if self.games_domain:
            a += ["--games-domain", self.games_domain]
        a += self._services_args()
        if self.enable_games:
            a += ["--enable-games"]
        a += self._character_studio_args()
        a += self._edge_ai_tts_args()
        a += self._rpi5_artifact_args()
        return a

    def _rpi5_artifact_args(self) -> list[str]:
        """rpi5 artifact selection (G24): --img/--no-img, --iso (a bootable installer
        ISO for an UNencrypted image), --skip-iso, --sd-only, --tar/--no-tar."""
        a: list[str] = []
        bi = self._tri(self.build_img)
        if bi == "on":
            a += ["--img"]
        elif bi == "off":
            a += ["--no-img"]
        if self.build_iso:
            a += ["--iso"]
        if self.skip_iso:
            a += ["--skip-iso"]
        if self.sd_only:
            a += ["--sd-only"]
        bt = self._tri(self.build_tar)
        if bt == "on":
            a += ["--tar"]
        elif bt == "off":
            a += ["--no-tar"]
        return a

    def _frite_args(self) -> list[str]:
        """build-frite-stage4.sh — arm64 CLIENT: board + flavor, no --role."""
        a: list[str] = ["--board", self.board or "la-frite", "--flavor", self.flavor or "both"]
        if self.desktop:               # light | none (frite's lean LXDE toggle)
            a += ["--desktop", self.desktop]
        if self.dtb:
            a += ["--dtb", self.dtb]
        a += self._uboot_args()
        a += self._arm_common_args()
        a += self._encrypt_root_args()
        if self.image_only:
            a += ["--image-only"]
        return a

    def _orangepi5_args(self) -> list[str]:
        """build-orangepi5-stage4.sh — arm64 CLIENT: board + flavor, no --role.
        EXPERIMENTAL (hardware validation pending): mirrors _frite_args()'s
        shape exactly (this platform has ONE role — a client desktop — like
        Frite), minus Frite's --desktop light|none toggle (this platform has
        no headless variant to gate — see specs-orangepi5/README.md)."""
        a: list[str] = ["--board", self.board or "orange-pi-5-plus", "--flavor", self.flavor or "both"]
        if self.dtb:
            a += ["--dtb", self.dtb]
        a += self._uboot_args()
        a += self._arm_common_args()
        a += self._encrypt_root_args()
        if self.image_only:
            a += ["--image-only"]
        return a

    def _orangepizero2_args(self) -> list[str]:
        """build-orangepi-zero2-stage4.sh — arm64 HEADLESS APPLIANCE: flavor
        only, no --role AND no --board (a single board, unlike Frite/Orange-Pi-5's
        board tables). EXPERIMENTAL (hardware validation pending): mirrors
        _orangepi5_args()'s shape minus --board — this platform is not a
        desktop client at all (see specs-orangepi-zero2/README.md for why),
        so there is also no --desktop toggle to emit, same as _orangepi5_args()."""
        a: list[str] = ["--flavor", self.flavor or "both"]
        if self.dtb:
            a += ["--dtb", self.dtb]
        a += self._uboot_args()
        a += self._arm_common_args()
        a += self._encrypt_root_args()
        if self.image_only:
            a += ["--image-only"]
        return a

    def _check_jetson_conflicts(self) -> None:
        """Mirror build-jetson-stage4.sh's hard block on --encrypt-root (and, by
        extension, --standalone, which forces it on): the Orin's single boot+root
        partition means the UEFI L4TLauncher cannot find a kernel once that
        partition is LUKS2-encrypted, so the builder exits 1 unconditionally for
        ANY --encrypt-root request, standalone-forced or explicit. Raise HERE too
        (mirrors _check_unaffiliated_conflicts()) so --print-command/the GUI
        preview fail loudly with the same contract instead of showing a
        seemingly-valid command / a "Preflight OK." that always fails at build
        time — see docs/STANDALONE-DESKTOP.md's Jetson section for the full
        rationale. Not a deferred gap: a real fix needs a separate unencrypted
        boot partition, which this platform does not have."""
        if self.standalone or self.encrypt_root:
            raise ValueError(
                "jetson: --encrypt-root (and --standalone, which forces it on) is "
                "not supported on this platform yet — the Orin's single boot+root "
                "partition means LUKS2-encrypting it leaves the UEFI firmware "
                "unable to find a kernel to boot. See docs/STANDALONE-DESKTOP.md's "
                "Jetson section. Clear standalone/encrypt_root to build this role.")

    def _jetson_args(self) -> list[str]:
        """build-jetson-stage4.sh — arm64 Tegra edge-AI node. EXPERIMENTAL (hardware
        validation pending): frite flag conventions + --role edge_ai|full|gpu-host|
        desktop and --board JETSON_BOARDS (specs-jetson/README.md). Anything beyond
        that goes via extra_flags."""
        self._check_jetson_conflicts()
        a = ["--role", JETSON_ROLE_MAP.get(self.role, self.role)]
        if self.board:                 # Orin module/carrier ("" = builder default)
            a += ["--board", self.board]
        if self.kernel_flavor:         # mainline (default) | l4t (G36)
            a += ["--kernel-flavor", self.kernel_flavor]
        if self.dtb:
            a += ["--dtb", self.dtb]
        a += self._arm_common_args()
        a += self._encrypt_root_args()
        bi = self._tri(self.build_img)   # jetson artifact: --img/--no-img (G24)
        if bi == "on":
            a += ["--img"]
        elif bi == "off":
            a += ["--no-img"]
        if self.image_only:
            a += ["--image-only"]
        return a

    def _check_unaffiliated_conflicts(self) -> None:
        """Mirror build-x86-host-stage4.sh's standalone-unaffiliated HARD CONFLICTS.

        The role presets a plain, brand-free Gentoo desktop; every field that would
        bake a brand identity, branding assets, the bundled Snapdragon source, the
        stack seed, or platform machinery (mesh/SSO/person-device identity) into the
        image raises ValueError HERE — so --print-command and the GUI preview fail
        loudly with the same contract the builder enforces (it exits non-zero on the
        equivalent flags; an explicit --brand gentoo errors too — the builder forces
        the neutral identity itself)."""
        conflicts: list[str] = []
        if (self.brand != "snapdragon" or self.brand_title != "Snapdragon Systems"
                or self.org != "Snapdragon-Systems"):
            conflicts.append("a brand identity (brand/brand_title/org — the builder "
                             "forces the neutral gentoo identity itself)")
        assets = [name for name, val in (
            ("theme", self.theme), ("branding_dir", self.branding_dir),
            ("wallpaper", self.wallpaper), ("grub_background", self.grub_background),
            ("grub_theme", self.grub_theme),
            ("login_background", self.login_background), ("brand_logo", self.brand_logo),
            ("accent_color", self.accent_color), ("color_scheme", self.color_scheme),
        ) if val] + (["brand_locked"] if self.brand_locked else [])
        if assets:
            conflicts.append("branding assets (" + ", ".join(assets) + " — nothing to theme against)")
        # bundle_source is NOT flagged here: its dataclass default is True (the
        # branded-standalone self-hosting default), so an untouched config would
        # false-conflict. The wizard clears it on role selection and _x86_args()
        # normalizes it to False for this role (never emitting the flag pair) —
        # mirroring the builder, which only errors on an EXPLICIT --bundle-source.
        if self.home_seed_code and self.home_seed_code != "none":
            conflicts.append("home_seed_code (seeds the Snapdragon stack into the home)")
        # RESOLVED values: on the (required) standalone mode a never-set field is
        # OFF, so only an explicit opt-in conflicts — and on a (conflicting)
        # cloud/mesh mode the mode line below names the real problem anyway.
        if self.tailscale_enabled():
            conflicts.append("tailscale (the tailnet is Snapdragon platform machinery)")
        if self.sso_enabled():
            conflicts.append("sso (Casdoor SSO is Snapdragon platform machinery)")
        if self.mode in ("cloud", "mesh"):
            conflicts.append(f"mode={self.mode!r} (emits --person-role/--domains — "
                             "person-device identity is platform machinery)")
        if conflicts:
            raise ValueError(
                "role standalone-unaffiliated builds a plain Gentoo desktop with ZERO "
                "Snapdragon affiliation, but this config sets " + "; ".join(conflicts)
                + ". Clear the conflicting field(s) — the builder hard-errors on the "
                "same flags.")

    def _x86_args(self) -> list[str]:
        # unaffiliated is reachable two ways: the dedicated role id (presets it inside
        # the builder's own role-switch) OR the composable --unaffiliated flag on any
        # role (G22). Both suppress the brand plane and hard-conflict on affiliation.
        unaffiliated = self.role == UNAFFILIATED_ROLE or self.unaffiliated
        if unaffiliated:
            self._check_unaffiliated_conflicts()
        a: list[str] = ["--role", self.role, "--env", self.env, "--local-user", self.local_user]
        if self.local_pass:
            # plaintext ONLY on the live command line — never persisted (SECRET_FIELDS)
            a += ["--local-pass", self.local_pass]
        a += self._identity_args()
        if not unaffiliated:
            a += self._brand_args()

            # network / identity — emit explicit with/no so intent is unambiguous;
            # a never-set field resolves to the MODE default (cloud/mesh ON), so a
            # config JSON that omits the keys builds the same image the GUI would.
            # (unaffiliated: the role PRESETS no-mesh/no-SSO/no-bundled-source; the
            # conflict check above already rejected any opt-in, so emit nothing.)
            a += ["--with-tailscale"] if self.tailscale_enabled() else ["--no-tailscale"]
            a += ["--with-sso"] if self.sso_enabled() else ["--no-sso"]
        a += self._mesh_version_args()

        # --standalone composes onto ANY client role (laptop/chromebook/desktop),
        # not just the standalone-thin/standalone-thick role ids (those role names
        # set STANDALONE=true internally in the builder's own role-switch, so they
        # never needed this flag from here) — forces --encrypt-root + no mesh/SSO
        # in the builder regardless of the with/no-tailscale|sso flags just above.
        if self.standalone:
            a += ["--standalone"]
        # --capable (most-capable Plasma payload, 50GiB root) + composable --unaffiliated
        # (the dedicated role id already presets it via the role name — emit the flag
        # only for the compose-onto-another-role path).
        if self.capable:
            a += ["--capable"]
        if self.unaffiliated and self.role != UNAFFILIATED_ROLE:
            a += ["--unaffiliated"]

        # cloud/mesh: bake the cluster plane. --cluster-domain applies to every mesh
        # node AND client (build-x86-host-stage4.sh parses --cluster-domain|--domain;
        # G1). --person-role/--domains are ROLE_CLIENT-only (FD-08): on a cluster NODE
        # role the builder warns + ignores them, so emit them for any NON-node role (G18).
        if self.mode in ("cloud", "mesh"):
            if self.cluster_domain != "snapdragon.systems":
                a += ["--cluster-domain", self.cluster_domain]
            # Orchestration superdomain — mesh-only (see _superdomain_args), emitted for
            # every mesh role (nodes AND clients), so it sits OUTSIDE the node-role gate
            # below. No-op for cloud, keeping every cloud golden byte-identical.
            a += self._superdomain_args()
            if self.games_domain:
                a += ["--games-domain", self.games_domain]
            if self.release_state:
                a += ["--release-state", self.release_state]
            if self.role not in X86_NODE_ROLES:
                domnames = [d.name for d in self.domains if getattr(d, "name", "")]
                if domnames:
                    a += ["--domains", ",".join(domnames)]
                if self.person_role:
                    person = self.person_role
                elif self.mode == "mesh":
                    person = "superadmin"
                else:
                    person = self.users[0].role if self.users else "user"
                a += ["--person-role", person]

        # node FALLBACK credentials (a GUI-built mesh fleet otherwise ships defaults).
        if self.user_password:
            a += ["--user-password", self.user_password]
        if self.root_password:
            a += ["--root-password", self.root_password]
        if self.release_tag:
            a += ["--release-tag", self.release_tag]

        # client desktop weight (thin|full) + Steam delivery (native|flatpak|none) —
        # "" = builder default, so only explicit choices are emitted
        if self.desktop:
            a += ["--desktop", self.desktop]
        if self.steam:
            a += ["--steam", self.steam]
        # external media-data device (Steam library + gocryptfs Vaults); default ON.
        md = self._tri(self.media_data)
        if md == "on":
            a += ["--media-data"]
        elif md == "off":
            a += ["--no-media-data"]
        if self.media_label:
            a += ["--media-label", self.media_label]
        if self.no_vaults:
            a += ["--no-vaults"]

        # hardware
        if self.gpu_driver and self.gpu_driver != "auto":
            a += ["--gpu-driver", self.gpu_driver]
        if self.nvidia_cuda:
            a += ["--nvidia-cuda"]
        if self.kernel_builtin:
            a += ["--kernel-builtin"]
        if self.enable_wifi:
            a += ["--enable-wifi"]
        if self.enable_bluetooth:
            a += ["--enable-bluetooth"]

        # branding
        if self.theme:
            a += ["--theme", self.theme]
        if self.branding_dir:
            a += ["--branding-dir", self.branding_dir]
        for flag, val in (("--wallpaper", self.wallpaper), ("--grub-background", self.grub_background),
                          ("--grub-theme", self.grub_theme),
                          ("--login-background", self.login_background), ("--brand-logo", self.brand_logo),
                          ("--accent-color", self.accent_color), ("--color-scheme", self.color_scheme)):
            if val:
                a += [flag, val]
        if self.brand_locked:
            a += ["--brand-locked"]

        # egress VPN
        if self.egress_vpn:
            a += ["--egress-vpn", self.egress_vpn]
            if self.egress_vpn_locked:
                a += ["--egress-vpn-locked"]

        # network/host security stack
        if self.proxy_stack == "on":
            a += ["--proxy-stack"]
        elif self.proxy_stack == "off":
            a += ["--no-proxy-stack"]
        a += ["--snort"] if self.snort else ["--no-snort"]
        aide = self._tri(self.aide)         # tri-state so a brand.conf default can be forced OFF
        if aide == "on":
            a += ["--with-aide"]
        elif aide == "off":
            a += ["--no-aide"]
        # Root SSH login — hardened DEFAULT is "no" (locked); opt back in per build.
        if self.root_login and self.root_login != "no":
            a += ["--permit-root-login", self.root_login]

        # edge-AI inference service (GPU cluster roles). The edge_ai role auto-selects
        # the service; be+gpu/omnibus opt in with --with-edge-ai / force off with
        # --no-edge-ai (tri-state, G34). Model-library knobs (runtime/preload/default)
        # are emitted whenever the service is in play, so the mesh model catalog is
        # image-configurable from the Studio wizard.
        edge = self._tri(self.edge_ai_service)
        if self.role != "edge_ai":
            if edge == "on":
                a += ["--with-edge-ai"]
            elif edge == "off":
                a += ["--no-edge-ai"]
        if self.role == "edge_ai" or edge == "on":
            if self.edge_ai_runtime and self.edge_ai_runtime != "ollama":
                a += ["--edge-ai-runtime", self.edge_ai_runtime]
            if self.edge_ai_models:
                a += ["--edge-ai-models", self.edge_ai_models]
            if self.edge_ai_model_default:
                a += ["--edge-ai-model-default", self.edge_ai_model_default]
        # the analysis API (folds edge-ai too, its dependency)
        if self.edge_ai_analysis:
            a += ["--with-edge-ai-analysis"]

        # edge-ai-tts (VN voice synthesis) — CPU-only, self-contained, NO edge-ai
        # dependency (unlike the analysis API above). Independent tri-state.
        a += self._edge_ai_tts_args()

        # Tor v3 onion (hidden) service (node-scoped; any cloud/mesh cluster role).
        # No-op on a CLIENT/standalone role (the builder guards on !ROLE_CLIENT).
        # Tri-state: force off with --no-tor to override a brand.conf default (G34).
        tor = self._tri(self.tor_onion_service)
        if tor == "on":
            a += ["--with-tor"]
        elif tor == "off":
            a += ["--no-tor"]

        # Character Studio (VN) frontend remote — OPTIONAL, DEFAULT-OFF (admin gate).
        # Folds 'character-studio' into OPTIONAL_SERVICES. Meaningful only for a
        # cloud/mesh cluster build (the builder guards on !ROLE_CLIENT / no-op on a
        # standalone desktop with no cluster tree). Tri-state (--no-character-studio).
        a += self._character_studio_args()

        # cluster optional services (+ explicit-none / all sentinels + the subtractive
        # exclude list) and the games stack (--enable-games folds 'games' in).
        a += self._services_args()
        if self.enable_games:
            a += ["--enable-games"]

        # Secure Boot + KEYS-USB signing chain (x86 only). SECURE_BOOT defaults ON in
        # the builder with a throwaway org key; --keys-usb / --secureboot-key/-cert
        # thread the EXISTING fleet SB key so images match the fleet chain (G5).
        sb = self._tri(self.secure_boot)
        if sb == "on":
            a += ["--secure-boot"]
        elif sb == "off":
            a += ["--no-secure-boot"]
        if self.keys_usb:
            a += ["--keys-usb", self.keys_usb]
        if self.secureboot_key:
            a += ["--secureboot-key", self.secureboot_key]
        if self.secureboot_cert:
            a += ["--secureboot-cert", self.secureboot_cert]

        # root-disk encryption (installer LUKS2 FDE) + unlock factors
        a += self._encrypt_root_args()
        if self.unlock_keyfile:
            a += ["--unlock-keyfile", self.unlock_keyfile]
        if self.unlock_yubikey:
            a += ["--unlock-yubikey", self.unlock_yubikey]

        # home
        if self.home_mode and self.home_mode != "create":
            a += ["--home-mode", self.home_mode]
        if self.home_device:
            a += ["--home-device", self.home_device]
        if self.home_backup:
            a += ["--home-backup", self.home_backup]
        if self.home_encrypted:
            a += ["--home-encrypted"]
        if self.home_seed_code and self.home_seed_code != "none":
            a += ["--home-seed-code", self.home_seed_code]
        if self.home_seed_code_from:
            a += ["--home-seed-code-from", self.home_seed_code_from]
        if self.include_home_archive:
            a += ["--include-home-archive", self.include_home_archive]
        if self.seed_packages_from:
            a += ["--seed-packages-from", self.seed_packages_from]

        # artifact selection (G23): --img/--no-img, live/installer ISO, --tar/--no-tar,
        # --skip-iso. "" tri-states leave the builder default.
        bi = self._tri(self.build_img)
        if bi == "on":
            a += ["--img"]
        elif bi == "off":
            a += ["--no-img"]
        li = self._tri(self.live_iso)
        if li == "on":
            a += ["--live-iso"]
        elif li == "off":
            a += ["--no-live-iso"]
        if self.installer_iso:
            a += ["--installer-iso"]
        bt = self._tri(self.build_tar)
        if bt == "on":
            a += ["--tar"]
        elif bt == "off":
            a += ["--no-tar"]
        if self.skip_iso:
            a += ["--skip-iso"]

        # installer / ISO
        if self.installer_ui:
            a += ["--installer-ui", self.installer_ui]
        a += ["--cached"] if self.cached else ["--uncached"]
        a += ["--live-toram"] if self.live_toram else ["--no-live-toram"]
        if not unaffiliated:  # the unaffiliated role presets no-bundled-source itself
            a += ["--bundle-source"] if self.bundle_source else ["--no-bundle-source"]
        a += self._grow_args()
        if self.img_size:
            a += ["--img-size", str(self.img_size)]
        # build plumbing (phases / seed / distfiles) — x86 has no -p/--extra-packages.
        a += self._plumbing_args()
        if self.distdir:
            a += ["--distdir", self.distdir]
        a += self._packages_delta_args()
        if self.compress:
            a += ["--compress"]
        if self.resume:
            a += ["--resume"]

        return a

    def to_command_string(self) -> str:
        return "./%s -w OUT -j %d %s" % (
            self.builder_script, self.jobs, " ".join(shlex.quote(x) for x in self.to_cli_args()))

    # ---- superadmin mesh manifest -----------------------------------------
    def mesh_manifest(self) -> dict[str, Any]:
        """The domains + users a superadmin defined, as a portable manifest, now carrying
        the effective orchestration superdomain (§2.6). This is the v1+superdomain shim for
        the SINGLE-image path; the full manifest v2 envelope ({"format":2,...,"images":[…]})
        is written once-per-worklist by the driver (WS-ENGINE). Consumed by cluster
        provisioning (Casdoor seed + per-domain config) — separate from the image
        build, which is why it is emitted as its own artifact rather than CLI flags."""
        return {
            "brand": self.brand, "brand_title": self.brand_title, "org": self.org,
            "cluster_domain": self.cluster_domain,
            "superdomain": self.effective_superdomain(),
            "domains": [asdict(d) for d in self.domains],
            "users": [asdict(u) for u in self.users],
        }

    def write_mesh_manifest(self, output_dir: str) -> str:
        import os
        os.makedirs(output_dir, exist_ok=True)
        path = os.path.join(output_dir, "snapdragon-mesh-manifest.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(self.mesh_manifest(), fh, indent=2)
        return path

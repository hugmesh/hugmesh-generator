"""ImageConfig — the single source of truth for a HugMesh image build.

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
platform never has a desktop mode),
orangepizero2w -> build-orangepi-zero2w-stage4.sh (EXPERIMENTAL — hardware
validation pending; the Zero 2's H618 sibling, same HEADLESS-APPLIANCE
flavor-only shape; see specs-orangepi-zero2w/README.md),
orangepizero3 -> build-orangepi-zero3-stage4.sh (EXPERIMENTAL — hardware
validation pending; the H618 sibling with onboard Ethernet, same
HEADLESS-APPLIANCE flavor-only shape; see specs-orangepi-zero3/README.md),
orangepi3-lts -> build-orangepi3-lts-stage4.sh (EXPERIMENTAL — hardware
validation pending; Allwinner H6, boots the PLAIN OPi3's mainline DTB/
defconfig, USB-Ethernet-first, same HEADLESS-APPLIANCE flavor-only shape;
see specs-orangepi3-lts/README.md).
"""
from __future__ import annotations

import copy
import json
import os
import re
import shlex
from dataclasses import dataclass, field, asdict, MISSING
from typing import Any

import sys

from .branding_themes import PREMADE_THEMES, is_valid_theme
from .host_resources import default_jobs
from .validate import (
    IdentityValidationError,
    validate_accent_color,
    validate_brand,
    validate_brand_title,
    validate_domain_name,
    validate_home_backup,
    validate_home_device,
    validate_login_color,
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

# External-IdP identity values (I6). Both flow into a root-baked idp.conf AND the
# REPLACEMENT side of the builders' issuer/JWKS sed rewrite, so the allowlist
# excludes everything shell/sed-meaningful (quotes, spaces, |, &, \, ;). An issuer
# or JWKS URL must be https:// (the token-validation trust anchor — an http
# external issuer would be a downgrade the platform never had); a client id keeps
# the union of the real providers' shapes (Entra GUIDs, Cognito alnum ids,
# generic OIDC slugs).
_IDP_URL_RE = re.compile(r"^https://[A-Za-z0-9][A-Za-z0-9._:/%=+-]*$")
_IDP_CLIENT_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$")

# Managed backing-service endpoint (I8/M2 — the RHS of --managed-service id=<endpoint>).
# The value flows onto argv AND into the root-baked /etc/hugmesh/backing-services.conf,
# so it must be shell/sed-safe: reject quotes, spaces, |, &, ;, $, backticks, <, >, (, ).
# The allowed set covers host[:port], comma broker-lists (kafka), http(s):// URLs,
# bucket@endpoint (federation-bundles) and the bare 'aws' sentinel (velero-objectstore).
# Anchoring the FIRST char to alnum rejects both a bare ':port' (no host) and a leading
# '-'. Mirrors the builders' validate_managed_services host/shape guard.
_MANAGED_ENDPOINT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@,%+=-]*$")


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
# "localmesh", "phone" and "deploy" sit IMMEDIATELY after "mode" (nextId()'s skip
# walk is positional): the three non-image side-flow pages, each dynamically skipped
# via applies_to() on every image mode. None is a MODE_SKIPPED_PAGES key — _ALL_MODES
# derives the legal ImageConfig.mode set from that dict, and none is an image mode.
# "idp" sits immediately BEFORE "role" (operator direction I6.2: the IdP choice is
# one of the FIRST steps, its own screen) — a node (mesh-mode) run reads
# welcome -> mode -> idp -> worklist/…; the localmesh/phone/deploy side-flow slugs in
# between are terminal or dynamically skipped anyway. Non-node modes statically
# skip "idp" via MODE_SKIPPED_PAGES below, so client/standalone flows keep today's
# behaviour byte-identically.
#
# ASK 19/20 put a CHOICE screen in front of each superadmin table: "domains_choice"
# ("proceed with the single initial internal domain" | "add domains") and
# "users_choice" ("generate the minimal default accounts" | "configure superusers &
# domain users"). Each sits IMMEDIATELY before the table it gates, so nextId()'s
# positional skip walk steps choice -> (table | past it) -> next choice. Both are
# MESH-only (MODE_SKIPPED_PAGES): a cloud client's single domain is the FD-08 tie the
# image is built around, not an "additional" domain, so that flow keeps its tables
# unconditionally and its page order is unchanged.
#
# ASK 22 splits the terminal pair in three: "build" is the REVIEW screen (what will be
# built + the knobs), "launch" is the separate BUILD screen (continue the build / back
# to the main menu), "progress" runs it. Nothing dispatches until Continue is pressed.
WIZARD_PAGE_SLUGS = ("welcome", "mode", "localmesh", "phone", "quest", "deploy",
                     "idp", "role",
                     "worklist", "hardware", "branding", "network", "keyzip",
                     "domains_choice", "domains", "users_choice", "users",
                     "system", "home", "build", "launch", "progress")
MODE_SKIPPED_PAGES = {
    # standalone/cloud build ONE image the old way (role/hardware/branding per image);
    # the mesh worklist is skipped there. mesh builds N images from a role x platform
    # multi-select on the WorklistPage instead of the single-image role/hardware/branding
    # pages (per-image hardware/GPU/board facts derive from the worklist row; theming is
    # a desktop-class surface a mesh node never carries).
    # "idp" (the mesh-node identity-provider picker) is a NODE-plane choice: the
    # desktop-client and standalone flows never see it (their SSO posture is the
    # with/no-sso axis, unchanged), so both skip it statically and their flows +
    # argv stay byte-identical to before the page existed.
    # the two ask-19/20 CHOICE screens are mesh-only: standalone has no admin plane at
    # all, and a cloud client's Domains/Users tables are unconditional (its --domains
    # tie is the point of the image), so offering it a "just the internal domain"
    # choice would be a knob with one legal answer.
    "standalone": ("idp", "worklist", "keyzip",
                   "domains_choice", "domains", "users_choice", "users"),  # single image, no admin/mesh plane
    "cloud": ("idp", "worklist", "domains_choice", "users_choice"),  # single image, admin plane via key-zip
    # mesh USED to skip "branding" outright; it no longer can: the page now also hosts
    # the WEB login theme (login_* — NON_ARGV_FIELDS), which themes the login-ui the
    # MESH serves to browsers. The desktop-asset half still greys+clears in mesh via
    # branding_allowed (role-class), so unskipping shows exactly the mesh-relevant half.
    "mesh": ("role", "hardware"),                              # the WorklistPage owns role x platform
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
    "orangepizero2w": "build-orangepi-zero2w-stage4.sh",
    "orangepizero3": "build-orangepi-zero3-stage4.sh",
    "orangepi3-lts": "build-orangepi3-lts-stage4.sh",
    "orangepi4-lts": "build-orangepi4-lts-stage4.sh",
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
    "orangepizero2w": "Orange Pi Zero 2W (Allwinner H618, arm64) — HEADLESS APPLIANCE, no desktop mode ever — EXPERIMENTAL: hardware validation pending",
    "orangepizero3": "Orange Pi Zero 3 (Allwinner H618, arm64) — HEADLESS APPLIANCE, no desktop mode ever — EXPERIMENTAL: hardware validation pending",
    "orangepi3-lts": "Orange Pi 3 LTS (Allwinner H6, arm64) — HEADLESS APPLIANCE, no desktop mode — EXPERIMENTAL: hardware validation pending",
    "orangepi4-lts": "Orange Pi 4 LTS (Rockchip RK3399, arm64) — LIGHT DESKTOP (Mali-T860/panfrost) — EXPERIMENTAL: hardware validation pending",
}

# The full role catalog, grouped by Studio mode: (role id, supported platforms, label).
# THE all-options-in-all-menus source of truth for the Studio (specs-jetson/README.md).
ROLE_CHOICES = {
    "standalone": [
        ("standalone-thin", ("x86",), "Standalone thin — hardened LXDE desktop, no mesh/SSO"),
        ("standalone-thick", ("x86",), "Standalone thick — hardened full desktop, no mesh/SSO"),
        ("standalone-unaffiliated", ("x86",),
         "Unaffiliated desktop — plain Gentoo, no HugMesh (zero branding/tooling baked)"),
        ("generic", ("rpi5",),
         "Generic arm64 server — plain Gentoo Raspberry Pi 5, unbranded (builder default role)"),
        # frite/orangepi5/orangepizero2 all support --standalone (FDE + local user, no
        # mesh/SSO); reachable in standalone mode too, not only as a cloud client (G17).
        ("frite", ("frite",), "La Frite family arm64 standalone (FDE local desktop; board + flavor)"),
        ("orangepi5", ("orangepi5",), "Orange Pi 5 / 5 Plus arm64 standalone — EXPERIMENTAL (FDE local desktop; board + flavor)"),
        ("orangepizero2", ("orangepizero2",), "Orange Pi Zero 2 arm64 standalone HEADLESS APPLIANCE — EXPERIMENTAL (FDE; flavor only)"),
        ("orangepizero2w", ("orangepizero2w",), "Orange Pi Zero 2W arm64 standalone HEADLESS APPLIANCE — EXPERIMENTAL (FDE; flavor only)"),
        ("orangepizero3", ("orangepizero3",), "Orange Pi Zero 3 arm64 standalone HEADLESS APPLIANCE — EXPERIMENTAL (FDE; flavor only)"),
        ("orangepi3-lts", ("orangepi3-lts",), "Orange Pi 3 LTS arm64 standalone HEADLESS APPLIANCE — EXPERIMENTAL (FDE; flavor only)"),
        ("orangepi4-lts", ("orangepi4-lts",), "Orange Pi 4 LTS arm64 standalone LIGHT DESKTOP — EXPERIMENTAL (FDE local desktop; flavor only, single board)"),
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
        ("orangepizero2w", ("orangepizero2w",), "Orange Pi Zero 2W arm64 HEADLESS APPLIANCE — EXPERIMENTAL (live/installer flavor only; no board/desktop axis)"),
        ("orangepizero3", ("orangepizero3",), "Orange Pi Zero 3 arm64 HEADLESS APPLIANCE — EXPERIMENTAL (live/installer flavor only; no board/desktop axis)"),
        ("orangepi3-lts", ("orangepi3-lts",), "Orange Pi 3 LTS arm64 HEADLESS APPLIANCE — EXPERIMENTAL (live/installer flavor only; no board/desktop axis)"),
        ("orangepi4-lts", ("orangepi4-lts",), "Orange Pi 4 LTS arm64 LIGHT DESKTOP client — EXPERIMENTAL (live/installer flavor only; single board, no board axis)"),
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

# build-orangepi-zero2w-stage4.sh --flavor (Allwinner H618). EXPERIMENTAL —
# hardware validation pending; see specs-orangepi-zero2w/README.md. Same
# ONE-role / one-board / flavor-only shape as its Zero 2 template sibling
# (and NO onboard Ethernet on this board — USB-Ethernet-first appliance).
ORANGEPIZERO2W_FLAVORS = ("live", "installer", "both")

# build-orangepi-zero3-stage4.sh --flavor (Allwinner H618). EXPERIMENTAL —
# hardware validation pending; see specs-orangepi-zero3/README.md. Same
# ONE-role / one-board / flavor-only shape as its Zero 2 template sibling
# (and NO onboard Ethernet on this board — USB-Ethernet-first appliance).
ORANGEPIZERO3_FLAVORS = ("live", "installer", "both")

# build-orangepi3-lts-stage4.sh --flavor (Allwinner H6). EXPERIMENTAL —
# hardware validation pending; see specs-orangepi3-lts/README.md. Same
# ONE-role / one-board / flavor-only shape as its Zero 2 template sibling.
# Boots the PLAIN Orange Pi 3's mainline DTB/defconfig (mainline has no -lts
# variant), and the onboard GbE jack is dead on that DTB — USB-Ethernet-first.
ORANGEPI3LTS_FLAVORS = ("live", "installer", "both")

# build-orangepi4-lts-stage4.sh --flavor (Rockchip RK3399). EXPERIMENTAL —
# hardware validation pending; see specs-orangepi4-lts/README.md. Flavor-only
# like the appliances (mainline ships ONE Orange Pi RK3399 DTB/defconfig for
# the whole 4/4B/4 LTS family, so no board axis) — but this board IS a light
# desktop, and like orangepi5 there is no --desktop toggle because there is no
# headless variant to gate.
ORANGEPI4LTS_FLAVORS = ("live", "installer", "both")

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
                             "character-studio", "character-forge")

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

# The builders' OWN built-in default selection when no --optional-services is given:
#   build-x86-host-stage4.sh:134   OPTIONAL_SERVICES="${OPTIONAL_SERVICES:-akkoma tuwunel phpbb}"
#   build-rpi5-stage4.sh:218       (identical line)
# The services table PRE-TICKS exactly these rows on arrival, because they are what an
# untouched build genuinely ships — eight unticked boxes over a mesh that runs three of
# them anyway is the same lie as a part-checked square (ask 23: "anything off by default
# is UNCHECKED; only pre-check what is genuinely on by default"), and it also made
# unticking `phpbb` a no-op, since --optional-services REPLACES rather than subtracts.
# tests/test_services_section.py parses both builder scripts and asserts set-equality with
# this tuple, so it cannot rot into a comment.
BUILTIN_DEFAULT_SERVICES = ("akkoma", "tuwunel", "phpbb")

# What the `all` sentinel / --all-services ACTUALLY expands to, mirrored from the single
# line both node builders declare it on:
#   build-x86-host-stage4.sh:127   USER_LEVEL_SERVICES="akkoma tuwunel phpbb games owncast
#                                  tube character-studio character-forge"
#   build-rpi5-stage4.sh:212       (identical line)
# and expanded into OPTIONAL_SERVICES at build-x86-host-stage4.sh:1067-1069 /
# build-rpi5-stage4.sh:1075 — BEFORE the --with-<x> opt-in folds, so a slug in this set is
# BAKED by --all-services no matter what the dedicated flag says. That last clause is the
# whole reason this constant exists in Studio: the wizard has to know which rows the "every
# user-level service" preset takes over, or it shows `character-studio` unticked (and emits
# --no-character-studio, whose false arm the builder does not even have) over a mesh that
# builds it. NOT the same set as OPTIONAL_SERVICES_CHOICES conceptually — that is the
# catalogue a platform's --optional-services accepts, this is what one sentinel expands to
# — so it is mirrored separately and parsed out of both scripts by
# tests/test_services_section.py rather than aliased.
USER_LEVEL_SERVICES = ("akkoma", "tuwunel", "phpbb", "games", "owncast", "tube",
                       "character-studio", "character-forge")

# One line per service saying what ENABLING it does — the operator's "redo entire
# services section" was in large part "these are eight slugs and I cannot tell what any
# of them is". Keyed by the slug the builders parse, so the label and the emitted token
# can never drift apart. A test asserts every slug in OPTIONAL_SERVICES_CHOICES +
# INFRA_SERVICES_CHOICES has an entry here (and that no entry is orphaned), which is what
# stops a new slug landing as a bare identifier again.
SERVICE_DESCRIPTIONS: dict[str, str] = {
    "akkoma": "Fediverse social server — ActivityPub timelines, follows and DMs "
              "at social.<domain>.",
    "tuwunel": "Matrix homeserver — end-to-end-encrypted chat rooms and DMs for "
               "everyone on the mesh.",
    "phpbb": "Web forum — threaded boards at forum.<domain>, SSO-linked to mesh "
             "accounts.",
    "games": "Game Studio + the games.<domain> app store, with its own OIDC issuer.",
    "owncast": "Self-hosted live video streaming — one channel, no third-party CDN.",
    "tube": "Peer-to-peer video hosting and playback (PeerTube-style channels).",
    "character-studio": "Character creator + VN chat remote at /character-studio.",
    "character-forge": "3D character maker + XR chat avatars — BFF database, BFF API "
                       "and the remote at /character-forge.",
    "edge-ai-tts": "Voice synthesis for those characters — Piper TTS plus a viseme "
                   "timeline for lip-sync. CPU-only; needs no GPU node.",
    "tor": "Tor v3 onion service — publishes the cluster gateway as a .onion address "
           "reachable without exposing a public IP.",
    "egress-vpn": "Routes this node's outbound traffic through a provided VPN profile.",
    "workloadConsole": "In-cluster workload console — inspect and restart mesh workloads "
                       "from the browser.",
    "anubis": "Anti-scraper proof-of-work gate in front of the public web routes.",
}

# Presentation grouping for the services surface: (group title, (slug, ...)). Ordered —
# the section renders groups in this order and slugs in the order listed. A slug the
# selected platform's catalog does not carry is simply not rendered, so one table drives
# every platform. Grouping is by WHAT THE SERVICE IS FOR, which is the axis the operator
# reads; the previous surface grouped by "which flag emits it", which is an
# implementation detail they cannot see.
SERVICE_GROUPS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("Social & community", ("akkoma", "tuwunel", "phpbb")),
    ("Media & play", ("owncast", "tube", "games")),
    ("Characters & avatars", ("character-studio", "character-forge", "edge-ai-tts")),
    ("Network & access", ("tor", "egress-vpn", "anubis", "workloadConsole")),
)

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

# Mesh-node identity provider (I6). Casdoor is the NATIVE DEFAULT: with idp left at
# "casdoor" every argv, sysroot byte and test outcome is IDENTICAL to today (the #1
# invariant). External mode is a CONFIG AXIS the two mesh-node builders
# (build-x86-host-stage4.sh / build-rpi5-stage4.sh) honour via --idp/--idp-issuer/
# --idp-client-id/--idp-jwks — see docs/IDENTITY-PROVIDERS.md for what external mode
# honestly does and does NOT do (native /bff/login, MFA stamping, role-sync jobs and
# the signup gate remain Casdoor-only).
IDP_CHOICES = ("casdoor", "entra", "aws", "oidc")
IDP_LABELS = {
    "casdoor": "Casdoor (built-in) — default",
    "entra": "Azure Entra ID",
    "aws": "AWS Cognito",
    "oidc": "Other OIDC provider",
}
# Per-provider derived JWKS path when --idp-jwks is left empty (documented choice:
# Entra publishes keys at /discovery/v2.0/keys; Cognito at /.well-known/jwks.json;
# a generic OIDC provider gets the Casdoor-shaped /.well-known/jwks the baked tree
# already pins — override with idp_jwks when your provider differs).
IDP_JWKS_SUFFIX = {
    "entra": "/discovery/v2.0/keys",
    "aws": "/.well-known/jwks.json",
    "oidc": "/.well-known/jwks",
}


def idp_effective_jwks(idp: str, issuer: str, jwks: str) -> str:
    """The JWKS URL external mode bakes: the explicit override, else the
    per-provider derivation off the issuer (single source for GUI preview,
    localmesh plan and tests; the builders derive the same value in shell)."""
    if jwks:
        return jwks
    if idp in IDP_JWKS_SUFFIX and issuer:
        return issuer.rstrip("/") + IDP_JWKS_SUFFIX[idp]
    return ""

# Managed backing services (I8 / M2). The tier-1/2 ids a --managed-service may repoint
# (self-hosted -> hosted cloud endpoint) and the tier-3 ids the registry NAMES but
# REFUSES in v1 (docsOnly + modeLocked self-hosted). Mirrors
# specs/cluster/backing-services.yaml AND the two node builders' _MGD_TIER12_IDS /
# _MGD_TIER3_IDS (gate_backing_services' executable twin). A hermetic test
# (test_managed_services.py) asserts these three sources agree, so the constant here can
# never drift from the builder that actually parses --managed-service.
MANAGED_SERVICE_TIER12_IDS = (
    "velero-objectstore", "smtp", "kafka", "clickhouse", "federation-bundles",
    "postgres-admin-bff", "postgres-user-bff", "postgres-mod-bff",
    "postgres-forum-bff", "postgres-wiki-bff", "postgres-casdoor")
MANAGED_SERVICE_TIER3_IDS = ("cassandra", "harbor", "vault-kv", "vault-pki")
# Short WHY-refused one-liner per tier-3 id (mirrors the builders' _mgd_tier3_blocker) —
# surfaced verbatim when validate_identity() refuses a tier-3 --managed-service selection.
MANAGED_SERVICE_TIER3_BLOCKER = {
    "cassandra": "auth/TLS live only in the dark cassandra-hardening overlay; "
                 "Keyspaces/Cosmos need TLS+SigV4 on 9142 with no live-path driver wiring",
    "harbor": "registry host literal in ~30 kustomizations + dockerconfigjson + kaniko; "
              "robot-account Job has no ECR/ACR analog; 12h ECR tokens break static pull "
              "secrets; loses air-gap",
    "vault-kv": "mechanical but broad: 1 ClusterSecretStore + ~90 remoteRef renames + "
                "writer re-point + drop vault-token seeding for IRSA — deferred wave",
    "vault-pki": "hardest: VaultDynamicSecret is Vault-only; needs a cert-manager "
                 "re-architecture keeping <app>-mtls names; USB CA-custody has no managed analog",
}

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


# ── capability table (PLATFORM axis): which platforms' arg builders EMIT each field ──
# This table declares ONE axis — the platform. It is no longer the authority the wizard
# gates on: FIELD_SCOPE below is, and it DERIVES PLATFORM_FIELD_SUPPORT from this dict
# (see the FieldScope block). Keep declaring platform support HERE; declare the
# role-class / mode axes in _FIELD_SCOPE_OVERRIDES.
#
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
_ALL_PLATFORMS = ("x86", "rpi5", "frite", "jetson", "orangepi5", "orangepizero2", "orangepizero2w",
                  "orangepizero3", "orangepi3-lts", "orangepi4-lts")
_ARM_PLATFORMS = ("rpi5", "frite", "jetson", "orangepi5", "orangepizero2", "orangepizero2w",
                  "orangepizero3", "orangepi3-lts", "orangepi4-lts")
_ENC_PLATFORMS = ("x86", "rpi5", "frite", "orangepi5", "orangepizero2", "orangepizero2w",
                  "orangepizero3", "orangepi3-lts", "orangepi4-lts")   # --encrypt-root: all but jetson
_UBOOT_PLATFORMS = ("frite", "orangepi5", "orangepizero2", "orangepizero2w", "orangepizero3",
                    "orangepi3-lts", "orangepi4-lts")
_DTB_PLATFORMS = ("frite", "jetson", "orangepi5", "orangepizero2", "orangepizero2w",
                  "orangepizero3", "orangepi3-lts", "orangepi4-lts")   # rpi5 uses --dtb-prefix
_IMAGE_ONLY_PLATFORMS = ("frite", "jetson", "orangepi5", "orangepizero2", "orangepizero2w",
                         "orangepizero3", "orangepi3-lts", "orangepi4-lts")
_X86 = ("x86",)
_X86_RPI5 = ("x86", "rpi5")

_FIELD_PLATFORMS: dict[str, tuple[str, ...]] = {
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
    # mesh-node identity provider (I6) — the two node builders only. Casdoor
    # default emits nothing; the probe uses an external combo (multi-key entry).
    "idp": _X86_RPI5, "idp_issuer": _X86_RPI5, "idp_client_id": _X86_RPI5,
    "idp_jwks": _X86_RPI5,
    # tor / character-studio / character-forge / services.
    "tor_onion_service": _X86, "character_studio": _X86_RPI5,
    "character_forge": _X86_RPI5,
    "optional_services": _X86_RPI5, "exclude_services": _X86_RPI5, "enable_games": _X86_RPI5,
    # managed backing services (I8/M2) — the two node builders parse --managed-service;
    # a mesh-node cluster concern, so scoped to the only builders that bake a cluster tree.
    "managed_services": _X86_RPI5,
    # client desktop weight / steam / sunshine thin-desktop host / media.
    "desktop": ("x86", "frite"), "steam": _X86, "sunshine": _X86,
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
# login_* (web login theme) follow the headscale_url precedent exactly: mesh/cluster-
# plane config, carried structurally (brands yaml / SNAP_THEME_CSS env), emitted by NO
# image builder's argv — the login-ui is a k8s Deployment the mesh SERVES, not a byte
# of any desktop image. Scoping them _X86 would gate them OFF on the only plane that
# renders them (the --flavor-both/installer_ui="all" dead-knob class, inverted).
# additional_domains is the newest member and the only one that is pure WIZARD FLOW
# state: it records whether the operator asked to define domains BEYOND the mesh's own
# cluster domain (ask 8). It gates the Domains/Users steps (superadmin_plane_applies)
# and nothing else — no builder parses it, and the domains/users it gates reach the
# cluster through the mesh MANIFEST, not the argv. It is saved with the config on
# purpose: reloading a worklist must not silently re-hide the tables the saved config
# still carries rows for.
# configure_users (ask 20) is its twin on the users half of the same flow: it records
# whether the operator chose to NAME superusers/domain users instead of accepting the
# accounts gen-provision-keys.sh mints by itself. Same channel (the mesh manifest, never
# argv), same reason for being saved with the config.
NON_ARGV_FIELDS = ("headscale_url", "pentest", "hw_profile",
                   "login_primary_color", "login_secondary_color", "login_font",
                   "login_font_file", "login_font_licence", "login_font_source",
                   "additional_domains", "configure_users")


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
# orangepi4-lts belongs HERE and not in _APPLIANCE_ROLES: RK3399 has an enabled
# &gpu (Mali-T860/panfrost), an enabled &hdmi and both VOPs in the mainline DTB it
# boots, so it is a real desktop client like orangepi5 — unlike every OTHER Orange
# Pi platform here, which are headless appliances.
_ARM_DESKTOP_ROLES = ("rpi5-desktop", "jetson-desktop", "frite", "orangepi5", "orangepi4-lts")
DESKTOP_ROLES = X86_CLIENT_ROLES + _STANDALONE_DESKTOP_ROLES + _ARM_DESKTOP_ROLES
# Cluster-node / headless-appliance family (root-encrypted infra). X86_NODE_ROLES already
# covers pki/be/fe/be+gpu/omnibus/edge_ai (x86 AND rpi5 share pki/be/fe; edge_ai is shared
# x86/jetson); jetson adds full/gpu-host; the orangepizero2 appliance and the plain-Gentoo
# rpi5 "generic" server are headless nodes too. Everything not an explicit desktop role
# is treated as a node (fail-safe: infra never accidentally exposes theming/home surfaces).
_JETSON_NODE_ROLES = ("full", "gpu-host")
_APPLIANCE_ROLES = ("orangepizero2", "orangepizero2w", "orangepizero3", "orangepi3-lts",
                    "generic")
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
    appliance). Role id is authoritative; mode is accepted for signature stability.

    This mirrors build-x86-host-stage4.sh's OWN ROLE_CLIENT: the role arms that set
    ROLE_CLIENT=true are exactly the roles that are "desktop" here. That correspondence is
    not a comment — tests/test_builder_default_drift.py (GUARD B) parses the builder's role
    case block and asserts set-equality, so this function cannot drift from builder truth."""
    return "desktop" if role in DESKTOP_ROLES else "node"


# ── FIELD_SCOPE: the field-gating authority (platform x role-class x mode) ───────────
# PLATFORM_FIELD_SUPPORT scopes a field by PLATFORM ONLY. That makes a "platform-valid but
# role-invalid" combination UNREPRESENTABLE — and therefore unvalidated: the x86 builder
# happily PARSES flags that are meaningless on a cluster node (it warns and ignores, or
# silently builds the wrong thing), so the platform gate passes and nothing else looks.
# FIELD_SCOPE adds the two missing axes so such a combination can at least be SAID.
#
# Every axis defaults to "everything", so a field needs an entry in _FIELD_SCOPE_OVERRIDES
# ONLY when it is genuinely narrower than its platform tuple. Fields absent from the table
# entirely stay fail-open (never grey a universal knob) — see _gating.platform_supports.
_ALL_CLASSES = ("desktop", "node")
_ALL_MODES = tuple(MODE_SKIPPED_PAGES)          # standalone | cloud | mesh (single source)


@dataclass(frozen=True)
class BuilderDefault:
    """A default the BUILDER resolves FOR ITSELF when the flag is left unset — the
    ``[ -z "${VAR}" ] && { COND && VAR=<t> || VAR=<f>; }`` sentinel form that
    build-x86-host-stage4.sh uses for exactly four variables (GUARD A pins the set).

    DESIGN DEVIATION, and the code is why: the audited shape for this record was
    ``(var, when_standalone, otherwise, policy)`` — it assumed every sentinel forks on
    ``${STANDALONE}``. Only two of the four do (INSTALLER_UI :1244, BUNDLE_SOURCE :1248).
    GPU_DRIVER :1190 forks on ``${GPU}`` and HOME_MODE :1227 on
    ``[ -n "${INCLUDE_HOME_ARCHIVE}" ]``. A ``when_standalone`` field would therefore have
    recorded a fiction for half the table, and GUARD A could only ever have checked the
    variable NAMES. Carrying the fork ``condition`` verbatim instead lets the guard pin the
    whole sentinel — name, condition and both arms — so a builder-side edit to any part of
    it goes RED.

    ``policy`` is what STUDIO does about that sentinel, and it is descriptive of today's
    code, not aspirational:

    * ``defer``    — studio emits NOTHING while the field sits at its dataclass default, so
                     the sentinel fires and the builder's own fork owns the value. This is
                     the correct posture: the builder knows the role.
    * ``resolve``  — studio reproduces the builder's fork ITSELF for a field whose scope
                     excludes the current role-class. RESERVED, and deliberately unused
                     today: the audited plan put bundle_source here via a materialize-time
                     lane, and the codebase rejected that placement (see the note under
                     FIELD_SCOPE). Any future use must resolve in a place BOTH the worklist
                     and flat channels pass through, or the two disagree about the same cell.
    * ``override`` — studio emits a FLAT CONSTANT that kills the sentinel outright, so the
                     builder's role-aware default is unreachable. This is a KNOWN GAP, not
                     a design: it is how --installer-ui ships an ISO-installer stack onto a
                     headless cluster node. Declaring it here makes the gap a fact the test
                     suite states out loud, and GUARD A asserts the emission really is
                     unconditional — so whoever fixes one MUST come here and flip it.
    """
    var: str
    condition: str
    when_true: str
    when_false: str
    policy: str = "defer"


BUILDER_DEFAULT_POLICIES = ("defer", "resolve", "override")


@dataclass(frozen=True)
class FieldScope:
    """The axes on which a config field is in scope. ``platforms`` is which builders parse
    the flag at all; ``classes`` / ``modes`` are which IMAGES the flag is meaningful for;
    ``builder_default`` records the builder's own unset-fork for the field, if it has one.

    ``class_platforms`` is a DESIGN DEVIATION the code forced, and it is worth stating
    plainly. The audited shape was a flat ``(platforms x classes x modes)`` product, which
    silently assumes a field's role-class rule holds on EVERY platform it is parsed on.
    For --standalone that is false, and asserting it shipped a new bug in the very class
    this track exists to kill:

      * build-x86-host-stage4.sh   — 48 ROLE_CLIENT refs; ACCEPTS --standalone on a node
                                     role and builds the wrong image  -> class rule is real
      * build-rpi5-stage4.sh:1037  — ${ROLE_CLIENT} || err ...; exit 1 -> class rule is real
      * build-frite / -orangepi5 / -orangepi-zero2-stage4.sh
                                   — ZERO occurrences of ROLE_CLIENT or ROLE_K8S. They
                                     compose ${STANDALONE} unconditionally, and
                                     build-orangepi-zero2-stage4.sh:218-226 documents
                                     --standalone as a posture this image composes.

    The orangepizero2 role IS node-class (a headless appliance) AND its defining posture is
    --standalone; ROLE_CHOICES calls it a "standalone HEADLESS APPLIANCE". A flat
    classes=("desktop",) therefore HID the checkbox on that flow and force-cleared the value
    — a silently non-standalone, non-FDE image where an FDE appliance was asked for. So the
    class axis carries the platforms it is TRUE on: None means "everywhere" (the common
    case), a tuple means the narrowing applies only on those builders and every other
    platform stays fully open. GUARD B cannot catch this — it pins image_class to the x86
    builder, which is exactly the builder that does not govern orangepizero2."""
    platforms: tuple[str, ...] = _ALL_PLATFORMS
    classes: tuple[str, ...] = _ALL_CLASSES
    modes: tuple[str, ...] = _ALL_MODES
    builder_default: "BuilderDefault | None" = None
    class_platforms: "tuple[str, ...] | None" = None


# The builder's four self-resolving defaults, transcribed from build-x86-host-stage4.sh.
# GUARD A (tests/test_builder_default_drift.py) parses the real sentinels and asserts this
# table matches them EXACTLY — set of variables, fork condition, and both arms — and that
# each declared ``policy`` is the emission studio actually produces. Neither side can drift.
_BD_GPU_DRIVER = BuilderDefault(
    var="GPU_DRIVER", condition="${GPU}", when_true="all-free", when_false="none",
    policy="defer")          # gpu_driver="auto" emits nothing -> the builder forks on --gpu
_BD_HOME_MODE = BuilderDefault(
    var="HOME_MODE", condition='[ -n "${INCLUDE_HOME_ARCHIVE}" ]',
    when_true="archive", when_false="create",
    policy="defer")          # home_mode="create" emits nothing -> builder picks archive/create
_BD_INSTALLER_UI = BuilderDefault(
    var="INSTALLER_UI", condition="${STANDALONE}", when_true="all", when_false="cli",
    policy="resolve")        # CLOSED by #384 (merged 2026-07-17). The flat default still
                             # always emits, so :1244 itself never fires — but studio now
                             # computes the builder's OWN `when_false` arm ("cli") for
                             # node-class x86 at MATERIALIZE time
                             # (resolve_installer_ui_default, called from
                             # worklist._materialize_one + app.py --print-command), so the
                             # emitted value matches what the sentinel would have chosen.
                             # That is `resolve`, not `defer`: studio states the value
                             # explicitly rather than omitting the flag. Desktop-class is
                             # deliberately untouched (byte-identical) — the builder's
                             # non-standalone client arm is "cli", so deferring for
                             # everyone would strip calamares from a mesh laptop.
_BD_BUNDLE_SOURCE = BuilderDefault(
    var="BUNDLE_SOURCE", condition="${STANDALONE}", when_true="true", when_false="false",
    policy="override")       # GAP (finding 4/5): bundle_source=True ALWAYS emits, so :1248
                             # never fires and a headless node gets 33MB of generator tree.
                             # See resolve-lane note under FIELD_SCOPE for why the fix is
                             # NOT a materialize-time resolve.

# Platforms whose builder gates --standalone on role-class AT ALL — the union of "errors on
# a node" (rpi5 :1037) and "accepts it and builds the wrong thing" (x86, ROLE_K8S=none).
# frite / orangepi5 / orangepi-zero2 parse --standalone with NO role concept whatsoever
# (zero ROLE_CLIENT/ROLE_K8S occurrences), so there is no class rule there to enforce and
# Studio must not invent one. test_field_scope.py derives this set from the builder scripts
# and asserts equality, so a builder that grows or loses a role-class concept goes RED here
# rather than letting the tuple rot into a fiction.
_STANDALONE_CLASS_GATED_PLATFORMS = ("x86", "rpi5")

# Role-class / mode narrowings. Entries here either restate a rule the codebase ALREADY
# enforces elsewhere — a test pins each to the predicate that owns it so the two cannot
# disagree — or carry an enforcement landing in the SAME commit:
#   * THEME_FIELDS       -> branding_allowed()      (desktop-class, and never in mesh)
#   * HOME_DESKTOP_FIELDS-> home_options_allowed()  (desktop-class, any mode)
#   * standalone         -> HomePage's hide gate + scope_allows()  [finding 1]
# bundle_source's classes=("desktop",) is the ONE narrowing here with no enforcement yet: it
# is read by GUARD A (which pins the gap as `override`) but by no gate, because the fix
# belongs in to_cli_args and lands with finding 4/5. It is declared rather than withheld
# precisely so the guard can hold the gap open — see the note under FIELD_SCOPE.
# Fields whose scope is still a GAP with no consumer (egress_vpn-on-node, ...) remain
# deliberately undeclared: a scope nothing reads would be policy with no effect. They land
# with their enforcement, not before.
_FIELD_SCOPE_OVERRIDES: dict[str, FieldScope] = {
    **{f: FieldScope(platforms=_FIELD_PLATFORMS[f], classes=("desktop",),
                     modes=tuple(m for m in _ALL_MODES if m != "mesh"))
       for f in THEME_FIELDS},
    **{f: FieldScope(platforms=_FIELD_PLATFORMS[f], classes=("desktop",))
       for f in HOME_DESKTOP_FIELDS},
    # --standalone means "no mesh/SSO, local user logs in with a build-time password". It is
    # a DESKTOP posture: a NODE has no local desktop session to log into. The x86 builder
    # still PARSES it on a node role, which is
    # exactly why nothing caught it: ROLE_K8S=none so the node gets no kubelet/kubeadm/
    # containerd and no cluster GitOps tree, while the full desktop stack IS built
    # (packages-desktop.list, ROOT_MiB 16384, Xorg/openbox/lightdm) — a node that can
    # never join the mesh it was built for, discovered hours later at deploy time. On rpi5
    # the same worklist hard-errors at build-rpi5-stage4.sh:1037, after dispatch.
    # ...but ONLY on the two builders that actually have a role-class concept. frite,
    # orangepi5 and orangepi-zero2 have ZERO occurrences of ROLE_CLIENT/ROLE_K8S and
    # compose ${STANDALONE} unconditionally; orangepizero2's role is node-class and
    # --standalone is its DEFINING posture ("standalone HEADLESS APPLIANCE" — ROLE_CHOICES,
    # build-orangepi-zero2-stage4.sh:218-226). Applying the class rule there hid the
    # checkbox on the flow whose whole point it is, and force-cleared the value on load.
    # See FieldScope.class_platforms for why the flat product could not say this.
    #
    # NO MODE AXIS — deliberately, and this was a REGRESSION this branch shipped and had to
    # take back. The first cut read modes=(standalone, cloud), on the reasoning above that
    # "--standalone is self-contradictory in mesh mode". That reasoning is prose, not builder
    # truth, and it invented a constraint: build-rpi5-stage4.sh:1037 gates --standalone on
    # ROLE_CLIENT *only*, never on mode, and :998 sets ROLE_CLIENT=true for its desktop arm.
    # So mesh + rpi5-desktop + --standalone is ACCEPTED by the builder — and is a DOCUMENTED
    # combination: ROLE_CHOICES describes rpi5-desktop as "compose with --standalone for FDE,
    # no mesh". The mode axis blocked dispatch on it (build_driver:preflight) and hid the
    # checkbox for it in the wizard, i.e. this branch committed the exact bug class it exists
    # to fix. classes=("desktop",) alone already excludes every node role in EVERY mode,
    # which IS finding 1 — the mode axis bought nothing but the false positives.
    # test_scope_violations.py sweeps ALL modes against the builder's real ROLE_CLIENT arms
    # so this cannot come back.
    "standalone": FieldScope(platforms=_FIELD_PLATFORMS["standalone"], classes=("desktop",),
                             class_platforms=_STANDALONE_CLASS_GATED_PLATFORMS),
    # Egress VPN is a DESKTOP/tailnet-client feature and the builder says so itself:
    #   build-x86-host-stage4.sh:3962  if ! ${ROLE_CLIENT} && [ -n "${EGRESS_VPN_FILE}" ]; then
    #                          :3963      warn "--egress-vpn given for a non-desktop role
    #                                      (${ROLE}); ... — ignoring."
    # HISTORY — why this scope entry exists, and what is no longer true. When it was written
    # (#387) "ignoring" was only HALF true: the STAGING leg was role-gated but the PACKAGE leg
    # (`if [ -n "${EGRESS_VPN_FILE}" ]` — net-vpn/wireguard-tools, or networkmanager-openvpn +
    # openvpn for a .ovpn) was NOT, so a node still emerged the VPN userspace it was just told
    # it would not use. That leg is now gated on the SAME ROLE_CLIENT condition (:4569), so the
    # builder no longer contradicts itself. The old note ALSO named the CONFIG_WIREGUARD kernel
    # fragment as ungated — that was wrong when written: the fragment has always sat INSIDE the
    # `if ${ROLE_CLIENT}` kernel arm (:5237, verified back to #189, the commit that added it).
    # The scope entry STAYS regardless: with every leg role-gated, offering the field on a node
    # class would only produce a flag the builder warns about and ignores. Mode is deliberately
    # unrestricted: the builder gates on ROLE_CLIENT alone, and a cloud or standalone DESKTOP
    # legitimately takes an egress conf.
    "egress_vpn": FieldScope(platforms=_FIELD_PLATFORMS["egress_vpn"], classes=("desktop",)),
    "egress_vpn_locked": FieldScope(platforms=_FIELD_PLATFORMS["egress_vpn_locked"],
                                    classes=("desktop",)),
    "gpu_driver": FieldScope(platforms=_FIELD_PLATFORMS["gpu_driver"],
                             builder_default=_BD_GPU_DRIVER),
    "home_mode": FieldScope(platforms=_FIELD_PLATFORMS["home_mode"], classes=("desktop",),
                            builder_default=_BD_HOME_MODE),
    "installer_ui": FieldScope(platforms=_FIELD_PLATFORMS["installer_ui"],
                               builder_default=_BD_INSTALLER_UI),
    # bundle_source bakes the 33MB generator tree + /usr/sbin/hugmesh-regenerate into
    # the image: the self-hosting posture of a branded STANDALONE appliance, and dead
    # weight on a headless PKI/backend node. The builder says so itself at :1248.
    "bundle_source": FieldScope(platforms=_FIELD_PLATFORMS["bundle_source"],
                                classes=("desktop",), builder_default=_BD_BUNDLE_SOURCE),
}

FIELD_SCOPE: dict[str, FieldScope] = {
    fld: _FIELD_SCOPE_OVERRIDES.get(fld, FieldScope(platforms=plats))
    for fld, plats in _FIELD_PLATFORMS.items()
}

# DERIVED compat view — the platform axis projected back out under its historical name, so
# every existing consumer (_gating.platform_supports/gate_widgets/clear_unsupported,
# strip_platform_unsupported, scripts/emit-image-catalog.py, the test_cli_args diff-probe)
# keeps reading the same mapping it always did. Never hand-edit: edit _FIELD_PLATFORMS.
PLATFORM_FIELD_SUPPORT: dict[str, tuple[str, ...]] = {
    fld: scope.platforms for fld, scope in FIELD_SCOPE.items()
}

# DERIVED: field -> the builder's own unset-fork for it. GUARD A asserts this projection is
# exactly the sentinel set parsed out of the real builder scripts. Never hand-edit.
BUILDER_DEFAULTS: dict[str, BuilderDefault] = {
    fld: scope.builder_default for fld, scope in FIELD_SCOPE.items()
    if scope.builder_default is not None
}


def rpi_boards_for_role(role: str) -> tuple[str, ...]:
    """The --board choices to OFFER for an rpi5-platform ``role``. A desktop-class role
    (rpi5-desktop) may target any Raspberry Pi board (rpi5/rpi4/rpi3); a node/appliance
    role (pki/be/fe, generic) may target rpi5/rpi4 ONLY — rpi3's 1GB RAM cannot host the
    hardened SELinux/containerd/kubelet stack, and build-rpi5-stage4.sh hard-errors that
    combo. Keeping rpi3 out of the node picker mirrors the builder's own contract so a
    Studio/menu selection can never dead-end in that hard-error (honesty rule)."""
    return RPI_BOARDS if image_class("", role) == "desktop" else RPI_NODE_BOARDS


def x86_desktop_axis(role: str) -> tuple[str, ...]:
    """The x86 --desktop weights the CATALOG may honestly OFFER for ``role``.

    build-x86-host-stage4.sh's own contract, mirrored (the honesty rule, same as
    rpi_boards_for_role): the desktop weight is a CLIENT-image axis —

    * person-device client roles (laptop/chromebook/desktop) really take both
      weights, so both are offered;
    * the weight-pinning standalone roles carry the weight IN THE ROLE NAME
      (standalone-thin -> thin; standalone-thick / standalone-unaffiliated ->
      full) and the builder HARD-ERRORS a contradictory explicit --desktop, so
      only the agreeing weight is offered ('standalone-thin/full' is a
      contradiction in terms, not an image);
    * cluster NODE roles (pki/be/fe/be+gpu/omnibus/edge_ai) are headless k8s
      servers — the builder plans DESKTOP=none and ignores the flag, so NO
      desktop axis exists for them at all (advertising one manufactured 12 of
      the 16 phantom inventory entries).
    """
    if role in X86_CLIENT_ROLES:
        return ("thin", "full")
    if role == "standalone-thin":
        return ("thin",)
    if role in ("standalone-thick", UNAFFILIATED_ROLE):
        return ("full",)
    return ()


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


def local_login_applies(cfg: "ImageConfig") -> bool:
    """Whether the "Your login & standalone account" surface (the --local-user /
    --local-pass desktop account, and the --standalone posture it frames) applies to
    THIS image.

    Operator report, verbatim: "your login/standalone account doesnt belong on mesh
    builds, keep that to the desktop mesh track". They are right, and the reason is
    structural rather than cosmetic: a cluster node's console credentials already have
    their own surface — SystemPage's "Node fallback login (mesh nodes)" group
    (--user-password / --root-password, gated by SystemPage._node_creds_apply). Showing
    a SECOND login group titled "Your login & standalone account" on the same node flow
    offers one concept twice, and the one it offers is the desktop one.

    DESKTOP-CLASS, no mode axis — deliberately, and grounded the same way
    ``FieldScope.class_platforms`` is: a mesh flow made entirely of rpi5-desktop rows is
    the documented "desktop mesh track" the operator asked us to keep this on, and
    build-rpi5-stage4.sh:998 sets ROLE_CLIENT=true for exactly that arm. A mode axis
    would hide the group on the one flow it belongs to.

    ...OR wherever ``--standalone`` itself is still in scope, and that second arm is not
    belt-and-braces — it is the fix for a regression this predicate shipped and had to
    take back within the hour. The first cut was a flat ``image_class == "desktop"``,
    which hid the group on the orangepizero2 / -2w / -zero3 / -3-lts appliances. Those
    roles are NODE-class and ``--standalone`` is their DEFINING posture (ROLE_CHOICES
    calls them a "standalone HEADLESS APPLIANCE"; build-orangepi-zero2-stage4.sh:218-226
    composes ${STANDALONE} with zero ROLE_CLIENT/ROLE_K8S anywhere in the script). The
    standalone CHECKBOX lives inside this group, so hiding the group made the whole point
    of that flow unreachable — precisely the bug ``_STANDALONE_CLASS_GATED_PLATFORMS``
    and ``FieldScope.class_platforms`` exist to record, re-committed by the fix for a
    different one. Deferring to ``field_in_scope("standalone", …)`` means the group's
    scope IS its contents' scope, by construction, so the two cannot drift apart again.
    (Pinned by test_pages_home.test_home_standalone_live_on_the_orangepizero2_node_class_appliance.)

    NOT a claim about the builder, and it deliberately declares no FIELD_SCOPE
    narrowing of its own: build-x86-host-stage4.sh:1597 honours --local-user on EVERY role
    (it overrides DEFAULT_USER, :1598), so narrowing the FIELD would invent a builder
    constraint that does not exist. This is a WIZARD-surface rule of the same family as
    ``home_options_allowed``: it hides a group, and emission stays byte-identical because
    ``local_user`` keeps its dataclass default ("magus", still emitted as --local-user
    magus) while ``local_pass`` is empty by default — see HomePage.validatePage, which
    collects the secret only while the surface applies."""
    return (image_class(cfg.mode, cfg.role) == "desktop"
            or field_in_scope("standalone", cfg))


def external_media_applies(cfg: "ImageConfig") -> bool:
    """Whether the external media-data device group (Steam library + gocryptfs Vaults)
    applies to THIS image.

    Same evidence shape as ``egress_vpn``'s role-class narrowing, which is why it gets a
    predicate rather than a shrug: the x86 builder half-honours the option on a node.
    ``build-x86-host-stage4.sh:1442`` role-gates only the STEAM leg
    (``${ROLE_CLIENT} && ${MEDIA_DATA}``), while ``:4158`` and the package leg ``:4524``
    (``packages-media-data.list``) are NOT role-gated — so a headless PKI node emerged a
    Steam/Vaults media stack it has no session to use. It was reachable on every mesh node
    because ``FIELD_SCOPE`` has no entry for ``media_data`` at all and the only gate was
    the PLATFORM one, which a mesh flow passes unconditionally (WorklistPage forces the
    shared base to platform="x86")."""
    return image_class(cfg.mode, cfg.role) == "desktop"


@dataclass(frozen=True)
class ImageAxes:
    """The three axes every scope/capability predicate reads — mode x role x platform.

    A stand-in for a full ImageConfig so ``flow_images`` can ask "would this predicate
    say yes for THAT image?" without materializing (deepcopying) a whole config per
    worklist row on every initializePage. Every predicate in this module reads only
    these three attributes (``image_class(mode, role)``, ``cfg.platform``, ``cfg.mode``),
    which ``test_services_section.py`` pins so a predicate that grows a fourth input
    cannot silently start reading a default off this shim."""
    mode: str = ""
    role: str = ""
    platform: str = ""


def flow_images(cfg: "ImageConfig", entries=None) -> tuple[ImageAxes, ...]:
    """Every image THIS WIZARD FLOW will actually build, as (mode, role, platform) axes.

    THE BUG THIS EXISTS TO KILL. ``WorklistPage.validatePage`` stamps the shared mesh base
    with ``cfg.role = entries[0].role`` and ``cfg.platform = "x86"`` (the option superset)
    — see gui/pages/worklist.py. Every desktop-class gate downstream then keys
    ``image_class(cfg.mode, cfg.role)`` on ONE arbitrary row, so a mesh worklist whose
    FIRST checked row happens to be ``rpi5-desktop`` or ``jetson-desktop``
    (both are in ``ROLE_CHOICES["mesh"]``) makes the whole base read as "desktop-class"
    and unlocks every standalone-desktop surface on a mesh flow — the operator's
    "again, options for standalone desktops shouldnt appear in the mesh wizard".

    Outside mesh (or with no worklist yet) there is exactly one image and this is the
    base config itself, so every non-mesh flow keeps its existing answer byte-for-byte.
    ``SystemPage._node_creds_apply`` is the precedent: the only gate in the flow that
    already read the entries instead of the base, and the only one both probe runs got
    right."""
    if cfg.mode == "mesh" and entries:
        return tuple(ImageAxes(mode=cfg.mode, role=e.role, platform=e.platform)
                     for e in entries)
    return (ImageAxes(mode=cfg.mode, role=cfg.role, platform=cfg.platform),)


def flow_allows(pred, cfg: "ImageConfig", entries=None) -> bool:
    """``pred`` must hold for EVERY image this flow builds.

    ALL, not ANY, and that is the load-bearing choice. These surfaces live on the SHARED
    mesh base, which ``WorklistConfig._materialize_one`` DEEPCOPIES onto every entry, and
    ``clear_role_class_fields`` clears only the theme/home families — nothing per-entry
    ever strips ``standalone`` / ``local_pass`` / the media-data trio / ``egress_vpn``.
    So a value offered because ONE row could use it rides onto every OTHER row too. Under
    ANY, a single ``rpi5-desktop`` row in a ten-node worklist would put a desktop login
    password on all ten images — which is the leak, not the fix.

    ALL is also exactly what the operator asked for: a mesh worklist of nodes hides these,
    a worklist that is entirely desktop rows (the "desktop mesh track") keeps them."""
    return all(pred(img) for img in flow_images(cfg, entries))


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
    collect_all (visited-pages-only) requires.

    ASK 8 narrowed the mesh arm. A mesh flow used to visit both tables unconditionally,
    so every operator building three node images walked two superadmin tables they had
    nothing to put in. Now the mesh arm asks whether the operator opted into
    ``additional_domains`` on the Network step ("this mesh also hosts domains beyond its
    own cluster domain"). Emission-neutrality is preserved by NetworkPage.validatePage,
    which CLEARS cfg.domains/cfg.users whenever the opt-in is off — so a skipped table
    can never leave rows behind for mesh_manifest() to publish. See the ask-8 note in
    gui/pages/network.py.

    The CLOUD arm is deliberately untouched: a cloud desktop client's Domains/Users step
    carries the FD-08 --domains + --person-role tie the image is literally built around
    (build-x86-host-stage4.sh:4057-4058), which is not an "additional" domain at all."""
    if cfg.mode == "mesh":
        return bool(cfg.additional_domains)
    if cfg.mode == "cloud":
        return cfg.role not in X86_NODE_ROLES
    return False


def effective_domain_note(cfg: "ImageConfig") -> str:
    """Plain-language description of the domains a mesh serves WITHOUT adding any (ask
    19's default card). Names both real values rather than saying "the internal domain":
    the cluster domain the Network step set, and the orchestration superdomain every node
    joins (derived ``<brand>.internal`` when left blank — ``effective_superdomain``)."""
    return (f"Serve only {cfg.cluster_domain or 'the cluster domain'} and the internal "
            f"orchestration domain {cfg.effective_superdomain()} that every node joins. "
            "No domains table, no per-domain services to pick — this is the default and "
            "what almost every mesh wants.")


def users_table_applies(cfg: "ImageConfig") -> bool:
    """Whether the superadmin USERS TABLE step is reachable (ask 20's gate).

    Splits off ``superadmin_plane_applies`` because the two tables no longer share one
    switch. In MESH the domains table follows the domains CHOICE screen
    (``additional_domains``) and the users table follows the users CHOICE screen
    (``configure_users``) — an operator can perfectly well add a second domain and still
    want the generated accounts, or keep one internal domain and still name a superuser.
    Cloud is unchanged (the FD-08 --domains/--person-role tie a NODE role does not emit),
    standalone is statically skipped."""
    if cfg.mode == "mesh":
        return bool(cfg.configure_users)
    if cfg.mode == "cloud":
        return cfg.role not in X86_NODE_ROLES
    return False


def encrypt_root_always(cfg: "ImageConfig") -> bool:
    """ASK 21 — "root disk encryption should always be enabled". The single authority
    for what ``encrypt_root`` must be, for EVERY image the wizard produces.

    It is not a default any more, it is the posture: True wherever the platform's
    builder has a full-disk-encryption path, False on the ONE platform that does not
    (jetson — its single boot+root partition has no LUKS path, the builder hard-blocks
    ``--encrypt-root`` and ``to_cli_args`` raises on it, see ``_check_jetson_conflicts``).
    Keyed on PLATFORM_FIELD_SUPPORT so the exemption list cannot drift from the emission
    table.

    Deliberately NOT the dataclass default: a flat ``encrypt_root: bool = True`` would
    make a bare ``ImageConfig(platform="jetson")`` raise at ``to_cli_args()`` — the
    posture belongs where the platform is known, which is every place this is called
    (HomePage's collect, mesh entry, and the worklist's per-row resolution)."""
    return (cfg.platform or "x86") in PLATFORM_FIELD_SUPPORT["encrypt_root"]


def person_role_applies(cfg: "ImageConfig") -> bool:
    """Whether ``--person-role`` is REACHABLE for this image (ask 7's gate).

    Mirrors to_cli_args' own emission condition exactly (see the ``mode in
    ("cloud","mesh")`` / ``role not in X86_NODE_ROLES`` block): the builder writes
    /etc/hugmesh/identity-role from inside its ``elif ${ROLE_CLIENT}`` branch
    (build-x86-host-stage4.sh:4052-4057) and warns "--person-role/--domains are ignored
    for non-client role" otherwise (:1587-1588). A standalone build emits it never, and
    ``--unaffiliated`` hard-CONFLICTS with it (:1333).

    Used by SystemPage to hide the control rather than offer a knob whose value the
    builder would discard — the same class of leak asks 3 and 11 are about."""
    if cfg.mode not in ("cloud", "mesh"):
        return False
    if cfg.role == UNAFFILIATED_ROLE or cfg.unaffiliated:
        return False
    return cfg.role not in X86_NODE_ROLES


# ── ask 9: what the builders ACTUALLY default -H / -u to ─────────────────────────────
# The System step used to show three empty boxes whose only guidance was "leave blank
# for the builder default". The operator asked for the fields to be PRESELECTED — which
# is only honest if the preselected value is byte-for-byte what the builder would have
# derived. These two tables are transcribed from the builders' own role switches; the
# test test_derived_identity_matches_the_builder_tables re-reads the shell sources and
# fails if either side drifts.
#
# Per-platform hostname default, keyed platform -> {role -> suffix}. The value is the
# part after "{brand}-"; a role absent from a platform's map falls through to
# "{brand}-{role}" (every builder's `*)` arm).
_HOSTNAME_SUFFIX = {
    # build-x86-host-stage4.sh:1218-1287
    "x86": {"pki": "pki", "be": "be", "fe": "fe", "be+gpu": "host", "host": "host",
            "omnibus": "omnibus", "edge_ai": "edge-ai", "edge-ai": "edge-ai",
            "desktop": "desktop",
            "standalone-thin": "standalone-thin",
            "standalone-thick": "standalone", "standalone-full": "standalone"},
    # build-rpi5-stage4.sh:1238-1244 — `generic` is the ONE role whose default drops
    # the brand entirely ("gentoo-${BOARD}"); handled in derive_hostname.
    "rpi5": {},
    "frite": {"desktop": "frite", "generic": "frite"},            # :533-534
    "jetson": {"edge_ai": "jetson-edge-ai", "edge-ai": "jetson-edge-ai",
               "gpu-host": "jetson-gpu", "gpu_host": "jetson-gpu",
               "full": "jetson-full", "desktop": "jetson"},       # :487-503
    "orangepi5": {"desktop": "orangepi5", "generic": "orangepi5"},          # :564-565
    "orangepizero2": {"appliance": "orangepizero2", "generic": "orangepizero2"},    # :596
    "orangepizero2w": {"appliance": "orangepizero2w", "generic": "orangepizero2w"},  # :607
    "orangepizero3": {"appliance": "orangepizero3", "generic": "orangepizero3"},    # :610
    "orangepi3-lts": {"appliance": "orangepi3-lts", "generic": "orangepi3-lts"},    # :602
    "orangepi4-lts": {"desktop": "orangepi4-lts", "generic": "orangepi4-lts"},      # :645
}

# Each builder's DEFAULT_USER initialiser — the account created when -u is omitted.
_BUILDER_DEFAULT_USER = {
    "x86": "snap",                       # build-x86-host-stage4.sh:184
    "rpi5": "pi",                        # :261
    "frite": "frite",                    # :192
    "jetson": "jetson",                  # :176
    "orangepi5": "orangepi5",            # :219
    "orangepizero2": "orangepizero2",    # :266
    "orangepizero2w": "orangepizero2w",  # :273
    "orangepizero3": "orangepizero3",    # :276
    "orangepi3-lts": "orangepi3lts",     # :269
    "orangepi4-lts": "orangepi4-lts",    # :287
}


def derive_hostname(cfg: "ImageConfig") -> str:
    """The hostname this image would get with NO ``-H`` — i.e. what the builder's own
    role switch assigns. Pure; never raises.

    Notes that make this honest rather than decorative:
    * the UNAFFILIATED x86 desktop is special-cased to ``gentoo-desktop``
      (build-x86-host-stage4.sh:1343, applied AFTER the brand is neutralised);
    * rpi5's ``generic`` role drops the brand entirely (``gentoo-${BOARD}``, :1241);
    * an unknown role on any platform falls through to ``{brand}-{role}``, and an
      unset role on x86 to ``{brand}-host`` (:1889).
    """
    brand = (cfg.brand or "hugmesh").strip() or "hugmesh"
    role = (cfg.role or "").strip()
    plat = (cfg.platform or "x86").strip() or "x86"
    if plat == "x86" and (role == UNAFFILIATED_ROLE or cfg.unaffiliated):
        return "gentoo-desktop"           # build-x86-host-stage4.sh:1343
    if plat == "rpi5" and role == "generic":
        return f"gentoo-{cfg.board or 'rpi5'}"   # build-rpi5-stage4.sh:1241
    suffix = _HOSTNAME_SUFFIX.get(plat, {}).get(role)
    if suffix:
        return f"{brand}-{suffix}"
    if not role:
        return f"{brand}-host" if plat == "x86" else brand
    return f"{brand}-{role}"


def derive_default_user(cfg: "ImageConfig") -> str:
    """The default account name this image would get with NO ``-u``.

    Two layers, both real:
    1. every builder ships a platform DEFAULT_USER (``_BUILDER_DEFAULT_USER``);
    2. **``--local-user`` overrides it** — ``[ -n "${LOCAL_USER}" ] && DEFAULT_USER=
       "${LOCAL_USER}"`` (build-x86-host-stage4.sh:1598 and the ARM twins). x86 emits
       ``--local-user`` on EVERY image (``_x86_args``, an unconditional argv element),
       so on x86 the effective default is ``cfg.local_user``, not ``snap``. The ARM
       builders only receive it when standalone / a non-default name / a local password
       is set (``_arm_common_args``), so they keep the platform account otherwise.

    Layer 2 is exactly the emission predicate in ``_arm_common_args``/``_x86_args``; the
    drift guard test re-derives it from a real ``to_cli_args()``.

    PER IMAGE, ALWAYS. "The ARM builders keep the platform account otherwise" is true
    only while nothing bakes ``-u``. A caller holding a MULTI-PLATFORM worklist must
    call this once per row with that row's platform and compare — seeding one answer
    from the base config (which the worklist pins to x86) and applying it to every row
    overrides each ARM builder's own DEFAULT_USER. ``SystemPage._seed_user`` is the
    caller that has to do this; it leaves the field blank when the rows disagree.
    """
    plat = (cfg.platform or "x86").strip() or "x86"
    local = (cfg.local_user or "").strip()
    if plat == "x86":
        return local or _BUILDER_DEFAULT_USER["x86"]
    if local and (cfg.standalone or local != "magus" or cfg.local_pass):
        return local
    return _BUILDER_DEFAULT_USER.get(plat, local or "")


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
    "orangepizero2w": "orangepizero2w",
    "orangepizero3": "orangepizero3",
    "orangepi3-lts": "orangepi3-lts",
    "orangepi4-lts": "orangepi4-lts",
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
_ISO_FLAVOR_PLATFORMS = ("frite", "orangepi5", "orangepizero2", "orangepizero2w", "orangepizero3",
                         "orangepi3-lts", "orangepi4-lts")


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


# The --installer-ui values that flip the builder's WANT_CALAMARES true, hence pull
# app-admin/calamares into PKGS (build-x86-host-stage4.sh:1246 / :3532). Mirrored here
# deliberately; tests/scripts/test-installer-ui-node-default.sh re-extracts the set from
# that LIVE builder line and fails if the two ever drift.
_CALAMARES_INSTALLER_UI = ("calamares", "all")
# What a headless node emits instead. Explicit (not "" = defer-to-builder) so the intent
# is auditable in --print-command / --print-specs rather than inferred from an absence;
# same WANT_CALAMARES=false outcome as the builder's own :1244 non-standalone default.
_NODE_INSTALLER_UI = "cli"


def resolve_installer_ui_default(cfg: "ImageConfig") -> str | None:
    """Role-class twin of resolve_platform_defaults (#337/#344): a headless x86 NODE must
    never request a graphical installer front-end.

    The builder ALREADY implements this rule — build-x86-host-stage4.sh:1244 defaults an
    UNSET ``INSTALLER_UI`` to ``all`` for --standalone and ``cli`` for every other role —
    but the Studio's flat dataclass default (``installer_ui: str = "all"``) means
    to_cli_args:1732 always passes an explicit value, so that ``[ -z ... ]`` guard can
    never fire and every node inherits the standalone-only ``all``. That is not merely
    wasteful: the USE closure app-admin/calamares needs (specs-x86/portage/package.use/
    desktop) is copied ONLY for ROLE_CLIENT roles (:2496), so on a node calamares is
    UNSATISFIABLE, not just heavy — it killed 5 x86 node images on boost[python] (#380)
    and 5 more on libpwquality[python] the next run. image_class() is the exact
    ROLE_CLIENT complement, so it is the right predicate.

    ONE-DIRECTIONAL by design: node-class only. A mesh CLIENT (laptop) and a STANDALONE
    desktop legitimately want calamares and CAN build it, and the builder's own default
    for a non-standalone client is ``cli`` — so deferring for everyone would silently
    strip the graphical installer from mesh desktops. Desktops return early and are
    byte-identical by construction.

    An explicit ``all``/``calamares`` on a node is OVERRIDDEN, not honoured: on a node it
    is not a preference the builder can satisfy, so honouring it buys a guaranteed ~16min
    failure. Precedent: clear_role_class_fields() already silently resets explicitly-set
    theme/home fields on a node for the same "the role class does not permit this" reason.

    Mutates ``cfg`` in place. Returns a human-readable note iff it changed something, else
    None (the core/ house idiom — cf. save():896 — since core/ has no logger; the caller
    routes it to STDERR, never stdout, which is app.py's argv channel). Called at
    MATERIALIZE time only (WorklistConfig._materialize_one) and on app.py's headless
    --print-command cfg — NEVER in to_cli_args, so emission stays a faithful field->argv
    translation (invariant I3).
    """
    if (cfg.platform or "x86") != "x86":
        return None                       # installer_ui is _X86-only (PLATFORM_FIELD_SUPPORT:389)
    if image_class(cfg.mode, cfg.role) != "node":
        return None                       # client / standalone: untouched, byte-identical
    if cfg.installer_ui not in _CALAMARES_INSTALLER_UI:
        return None                       # already cli/ncurses: WANT_CALAMARES is false already
    prev = cfg.installer_ui
    cfg.installer_ui = _NODE_INSTALLER_UI
    return (f"installer_ui {prev!r} -> {_NODE_INSTALLER_UI!r} for headless node role "
            f"{cfg.role!r}: build-x86-host-stage4.sh gates the calamares USE closure "
            f"(package.use/desktop) on ROLE_CLIENT:2496, so a node cannot resolve "
            f"app-admin/calamares — and has no display to run it.")


# ── one-shot note emission ───────────────────────────────────────────────────
# resolve_installer_ui_default() returns a NOTE describing a rewrite it performed.
# Callers print it to stderr. That is right for a one-shot CLI, but the Studio is a
# LONG-LIVED process that re-materializes a worklist on every preview refresh, so the
# identical note printed once per entry per refresh — 76 copies of the same four lines
# in one operator session (2026-08-05). The note is advice about a CONFIGURATION, not
# an event: saying it once is the whole of its value, and repeating it buries anything
# else on stderr.
#
# Dedupe on the note TEXT (which already embeds the role), per process. A genuinely
# different rewrite — another role, another trigger value — has different text and is
# still reported. reset_emitted_notes() exists for tests, which must not inherit a
# sibling test's suppression.
_EMITTED_NOTES: set[str] = set()


def emit_note_once(note: str | None, *, stream=None) -> bool:
    """Print ``note`` to stderr the FIRST time this process sees that exact text.

    Returns True if it was printed. ``None``/empty is a no-op returning False, so
    callers can write ``emit_note_once(resolve_installer_ui_default(cfg))`` with no
    guard of their own.
    """
    if not note:
        return False
    if note in _EMITTED_NOTES:
        return False
    _EMITTED_NOTES.add(note)
    print(f"warning: {note}", file=stream if stream is not None else sys.stderr)
    return True


def reset_emitted_notes() -> None:
    """Forget every emitted note (tests only — never call from product code)."""
    _EMITTED_NOTES.clear()


def effective_installer_ui(cfg: "ImageConfig") -> str:
    """The installer_ui value the BUILD will actually receive for ``cfg`` — i.e. what
    materialize emits — WITHOUT mutating ``cfg``.

    Exists so a display surface can ASK the resolver instead of RESTATING its rule. The
    GUI previously hard-coded "a node shows cli", which silently disagreed with the
    resolver's ACTUAL (conditional) rule: only the calamares-triggering values are
    rewritten, so a node configured for "ncurses" really does build ncurses and must be
    shown as such. Any future change to resolve_installer_ui_default's trigger set now
    reaches every reporter for free — the two cannot drift.

    Shallow probe copy is deliberate and sufficient: resolve_installer_ui_default READS
    only platform/mode/role and WRITES only the installer_ui str, so no mutable field is
    shared-mutated; ImageConfig has no __post_init__, so copy.copy is a faithful clone.
    """
    probe = copy.copy(cfg)
    resolve_installer_ui_default(probe)
    return probe.installer_ui


def _field_default(name: str):
    """The dataclass default for one ImageConfig field."""
    f = ImageConfig.__dataclass_fields__[name]  # type: ignore[attr-defined]
    return f.default_factory() if f.default is MISSING else f.default


def class_axis_violated(fld: str, cfg: "ImageConfig") -> bool:
    """Is ``fld``'s ROLE-CLASS narrowing violated by this image, on a platform where that
    narrowing is actually builder-true?

    Split out from field_in_scope because the three axes reject for THREE DIFFERENT
    REASONS, and a caller that only knows "out of scope" cannot tell them apart. The first
    cut of scope_violations() collapsed them, and every message it produced blamed
    role-class — so a jetson-desktop (rejected by the PLATFORM axis) and an rpi5-desktop in
    mesh (rejected by the MODE axis) were both told they were "a cluster-node image" that
    the builder would build wrong. Both are desktop-class. The prose was fiction.

    Returns False when the platform axis already owns the rejection (that gate, and
    strip_platform_unsupported, are the flag-not-parsed story) and False when the field's
    class rule simply does not hold on this builder (``class_platforms``)."""
    scope = FIELD_SCOPE.get(fld)
    if scope is None:
        return False
    plat = cfg.platform or "x86"
    if plat not in scope.platforms:
        return False
    if scope.class_platforms is not None and plat not in scope.class_platforms:
        return False
    return image_class(cfg.mode, cfg.role) not in scope.classes


def scope_reject_reason(fld: str, cfg: "ImageConfig") -> str | None:
    """Which AXIS puts ``fld`` out of scope for this image — ``"platform"`` | ``"class"`` |
    ``"mode"`` — or None if it is in scope. The ONE implementation of the axis rules: the
    wizard's reason text, the Qt-free gate and the --config validator all read it, so they
    cannot disagree about whether (or why) a field applies.

    Class is checked before mode deliberately: a mesh/pki/x86 image violates both, and the
    class story ("the builder builds a desktop stack with ROLE_K8S=none") is the one that
    names the real consequence."""
    scope = FIELD_SCOPE.get(fld)
    if scope is None:
        return None
    if (cfg.platform or "x86") not in scope.platforms:
        return "platform"
    if class_axis_violated(fld, cfg):
        return "class"
    if cfg.mode not in scope.modes:
        return "mode"
    return None


def field_in_scope(fld: str, cfg: "ImageConfig") -> bool:
    """Qt-free twin of gui/pages/_gating.scope_allows: is ``fld`` meaningful for THIS image
    (platform x role-class x mode)? Unknown fields are in scope everywhere (fail-open —
    never gate a universal knob)."""
    return scope_reject_reason(fld, cfg) is None


# Platforms whose builder HARD-ERRORS on --standalone with a cluster-node role, verbatim:
#   build-rpi5-stage4.sh:1037
#     ${ROLE_CLIENT} || { err "--standalone only composes onto --role desktop (got --role
#                        ${ROLE})"; exit 1; }
# x86 is deliberately NOT here: build-x86-host-stage4.sh ACCEPTS --standalone on a pki/be
# role and builds a desktop-stack image with ROLE_K8S=none. That difference is the whole
# reason the two get different tiers below — it is builder truth, not a preference.
_STANDALONE_NODE_HARD_ERROR_PLATFORMS = ("rpi5",)


def scope_violations(cfg: "ImageConfig") -> tuple[list[str], list[str]]:
    """Out-of-scope values a config carries, split ``(blocking, advisory)``.

    This is finding 1's OTHER half. Hiding the checkbox fixes the wizard, but the
    ``--config`` / worker / build-image.sh channels never draw a widget: they hand a JSON
    straight to to_cli_args. So the JSON needs its own answer, and the tiering rule is the
    design's governing principle — NEVER invent a constraint the builder does not have:

    * BLOCK is reserved for a REAL post-dispatch dead-end, i.e. one the builder itself
      errs on. rpi5 + --standalone + a node role is exactly that (:1037 above): it dies
      AFTER dispatch, after the operator has already paid the queue. Catching it at second
      0 is strictly better and invents nothing.
    * WARN is for a value the builder ACCEPTS. x86 + --standalone + a node role builds
      SUCCESSFULLY and silently wrong (full desktop stack, ROLE_K8S=none, so the node can
      never join the mesh it was built for). Blocking it would invent a constraint the
      builder does not have and break anyone deliberately building that shape; staying
      silent is what let the bug ship. So it warns, loudly, naming the consequence.

    LEAK vs EXPLICIT: only a value differing from the dataclass default is reported. A
    field sitting at its default is a LEAK (nobody asked for it) and belongs to the
    resolve lane, not here — this is the same rule _DEFAULT_LEAK_ROLES states for role
    resolution, applied to the scope axes. It also keeps bundle_source (default True, so
    True-on-a-node is a leak) deliberately OUT of this function: finding 4/5 is a resolve,
    not a warning. Nothing here fires for any config that was already valid.
    """
    blocking: list[str] = []
    advisory: list[str] = []
    # class_axis_violated, NOT `not field_in_scope(...)`: the latter is true for THREE
    # different reasons and every message below speaks about role-class. A jetson-desktop
    # (platform axis: --standalone is not in _ENC_PLATFORMS) and an rpi5-desktop in mesh
    # mode (mode axis) are both DESKTOP-class images whose builders take --standalone
    # happily — rpi5-desktop sets ROLE_CLIENT=true, so :1037 does not fire at all. Reporting
    # either as a cluster node that can never join the mesh would be inventing a constraint
    # AND lying about why. The class axis is the only one the builder itself gates on.
    if cfg.standalone and class_axis_violated("standalone", cfg):
        plat = cfg.platform or "x86"
        where = f"--role {cfg.role}" + (f" in {cfg.mode} mode" if cfg.mode else "")
        if plat in _STANDALONE_NODE_HARD_ERROR_PLATFORMS:
            blocking.append(
                f"standalone=true with {where}: the {plat} builder hard-errors on this "
                f"(--standalone only composes onto a desktop role), so the build would fail "
                f"AFTER dispatch. Drop standalone, or build a desktop role.")
        else:
            advisory.append(
                f"standalone=true with {where}: --standalone is a DESKTOP posture and this is "
                f"a cluster-node image. The builder ACCEPTS it and exits 0, but the result is "
                f"silently wrong: no kubelet/kubeadm/containerd and no cluster GitOps tree "
                f"(ROLE_K8S=none) while the full desktop stack is still built — a node that "
                f"can NEVER join the mesh it was built for. Drop standalone unless you really "
                f"mean a standalone desktop.")
    # nvidia_cuda × gpu_driver — the exact combo behind the 2026-07-19 08:2x burst
    # of eight 1-second dispatch deaths (empty session dirs, error only in the
    # record tail). The x86 builder hard-errors on an EXPLICIT non-nvidia driver
    # (real post-dispatch dead-end → BLOCK) and implies nvidia when the driver is
    # unset/auto (accepted → ADVISORY naming the implication, per the tiering rule).
    if cfg.nvidia_cuda and (cfg.platform or "x86") == "x86":
        gd = cfg.gpu_driver or "auto"
        if gd not in ("auto", "nvidia"):
            blocking.append(
                f"nvidia_cuda=true with gpu_driver={gd}: CUDA needs the proprietary "
                f"NVIDIA driver, and the x86 builder hard-errors on this pair AFTER "
                f"dispatch. Switch the GPU driver to 'nvidia', or drop the CUDA bake.")
        elif gd == "auto":
            advisory.append(
                "nvidia_cuda=true with gpu_driver=auto: the builder will imply "
                "--gpu-driver nvidia (CUDA needs the proprietary driver). Pick "
                "'nvidia' explicitly if that is what you mean.")
    return blocking, advisory


# ── why finding 4/5's fix is NOT a materialize-time resolve ──────────────────────────
# The audited design routed bundle_source's leak through a "silently resolve at materialize"
# lane, next to resolve_platform_defaults. It was implemented, and the codebase rejected it:
# tests/test_worklist.py::test_materialize_matches_hand_built_flat_config pins "a
# materialized mesh entry's argv equals the argv of the flat single-image config a user
# would build by hand for that image" — the redesign's CORE parity claim. bundle_source's
# leak is present identically in BOTH channels (both simply leave the field at its dataclass
# default), so correcting it in only one makes the same cell build two different images
# depending on which channel dispatched it. That is a worse bug than the one being fixed.
#
# resolve_platform_defaults survives at materialize precisely because it does NOT have this
# property: it fires only for a role/flavor that is INVALID for the target platform, a shape
# a hand-built config for the same cell never carries — so equivalence holds for every valid
# cell. bundle_source's leak fires on perfectly VALID cells, so it cannot live there.
#
# The honest fix is therefore in to_cli_args (which both channels share) — i.e. stop emitting
# the flag when the field is at its default and the role-class is out of scope, letting
# build-x86:1248 fire. That changes emission for existing node configs, so it belongs with
# finding 4/5 proper (step (c)), not here. BUILDER_DEFAULTS declares the gap as `override`
# and GUARD A pins it, so it cannot be forgotten.
#
# TODO(finding 4/5, bundle_source): step (c) attempted this and found a SECOND blocker the
# audit did not have, which is why it is still not fixed here. Recorded rather than worked
# around, because the workaround would be a silent-wrong-image bug of its own:
#
#   THE LEAK/EXPLICIT DISCRIMINATOR DOES NOT EXIST FOR THIS FIELD. The whole tier design
#   rests on "at the dataclass default => leak => resolve; explicitly set => honour + WARN".
#   That works for `standalone` (default False, so True is unambiguously explicit) and it is
#   what scope_violations() keys on. It CANNOT work for bundle_source: the default is True,
#   and from_dict is `cls(**{k: v for k, v in d.items() if k in known})` — it keeps no record
#   of which keys the JSON actually carried. So a config that OMITS the key and one that says
#   `"bundle_source": true` produce byte-identical objects. Resolving True-on-a-node would
#   therefore ALSO silently override an operator who explicitly asked for the source tree on
#   a node — the exact "silently corrected an explicit value" anti-pattern the WARN tier
#   exists to prevent. Trading a silent-wrong-image for a different silent-wrong-image is not
#   a fix.
#
#   The real fix needs an unset state, and the codebase already has the idiom: `tailscale` /
#   `sso` are tri-states ('' | True | False) normalized at load (see from_dict), where ''
#   means "nobody said" and the flag is simply not emitted. bundle_source wants the same
#   shape, so the builder's :1248 fork owns the value whenever the operator stayed quiet.
#
#   SEQUENCING, and the reason this waits rather than races: --installer-ui :1244 is the
#   IDENTICAL sentinel four lines above :1248, with the identical `override` gap, and its fix
#   is owned by fix/studio-installer-ui-node-default. That PR is the reference exemplar. It
#   also decides the shape of the shared surface (a to_cli_args role-gate splits
#   test_cli_args.py's X86_TAIL into DESKTOP/NODE variants; a materialize-time resolve does
#   not). Landing a DIFFERENT mechanism for the sibling flag first would both collide with
#   that PR's exact surface and leave two neighbouring flags resolving their identical
#   builder sentinel two different ways — worse than the gap. So: land the exemplar, then
#   mirror it here. GUARD A's test_guard_a_policy_override_pins_the_known_gap goes RED the
#   moment either flag stops emitting unconditionally, which is what forces this to be
#   revisited rather than quietly inherited.


def _reset_field(cfg: "ImageConfig", name: str) -> bool:
    """Reset one ImageConfig field to its dataclass default. True iff it changed."""
    default = _field_default(name)
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
    # ASK 21 moved the --standalone checkbox OFF the Home step (see gui/pages/home.py:
    # "there is no reason for it there") onto the RolePage, beside the other composable
    # posture flags. That collect used to be the only thing stopping a tick made on a
    # desktop image from riding a mode/role switch into a cluster node's argv — the
    # finding-1 leak. RolePage is SKIPPED in mesh, so it cannot play that role; the
    # guarantee moves here instead, where it is Qt-free and runs inside materialize()
    # step 5 for every worklist row as well as at mesh entry. Same predicate the widget
    # gate uses (FieldScope "standalone": classes=("desktop",) with the
    # class_platforms carve-out for the appliance boards), so nothing legitimate is lost.
    if not field_in_scope("standalone", cfg):
        cleared += [f for f in ("standalone",) if _reset_field(cfg, f)]
    return cleared


def enter_mesh_defaults(cfg: "ImageConfig", *, fresh: bool = False) -> None:
    """Mesh entry: clear every role-class desktop surface, then force tailscale=sso=True
    so mesh x86 nodes keep emitting today's --with-tailscale/--with-sso byte-identically
    (ARM joins mesh unless --skip-mesh; sso is x86-only in emission).

    ``fresh=True`` marks a real TRANSITION into mesh (the previous mode was not mesh, or
    a config was just loaded into a fresh flow) as opposed to re-walking the Mode step of
    a flow that is already mesh. Only a transition seeds the opinionated defaults below;
    re-walking must never undo a choice the operator has since made, which is why they
    are not in the unconditional block above.

    ASK 12 — "rot encryption should be a mesh device default". A mesh node is
    unattended infrastructure sitting on someone's desk or in a rack; its disk holds the
    cluster's PKI material, so the encrypted-root posture is the right default and the
    plain one is the exception. It lands HERE rather than on
    ``ImageConfig.encrypt_root`` (still ``False``) for three reasons:

    * a flat default-true would make ``to_cli_args()`` RAISE for a jetson single-image
      flow (``_check_jetson_conflicts`` — the jetson builder hard-blocks --encrypt-root);
    * it would silently flip standalone and cloud-client flows, which no ask asked for;
    * here it is a real, untickable DEFAULT: it seeds ``cfg.encrypt_root`` so the Home
      step's checkbox arrives CHECKED (the GUI is honest about what will happen), the
      worklist's per-row "default" inherits it (``WorklistConfig._resolve_encrypt_root``),
      any row can still be forced "off", and a jetson row is still auto-exempted.

    THIS CHANGES WHAT A MESH BUILD PRODUCES — see the mesh note on HomePage: on x86
    ``--encrypt-root`` also sets ``INSTALLER_ISO=true`` (build-x86-host-stage4.sh:1465),
    so an encrypted node additionally yields an installer ISO, and without ``--luks-pass``
    the installer PROMPTS for a passphrase at install time.

    ASK 21 then SUPERSEDED ask 12's wording — "root disk encryption should always be
    enabled", not merely defaulted on. So the seed is no longer conditional on ``fresh``:
    there is no un-tick to preserve any more (the Home step shows a checked, disabled
    statement, not a choice), and the value is ``encrypt_root_always`` — True on every
    FDE-capable platform, False on jetson so a jetson-based mesh base cannot raise. The
    ``fresh`` parameter is KEPT because it still marks a real transition for callers
    (ModePage clears the worklist on it) and is part of this function's signature."""
    clear_role_class_fields(cfg)
    cfg.tailscale = True
    cfg.sso = True
    cfg.encrypt_root = encrypt_root_always(cfg)


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
    brand: str = "hugmesh"
    brand_title: str = "HugMesh Systems"
    # TODO(org-move): the default GitHub org is still the legacy one. This field
    # is ALSO compared against the literal in two validators below, so the flip is
    # three coordinated edits in this file, not one. See docs/ORG-MOVE-TODO.md.
    org: str = "hugmesh-net"
    brand_profile: str = ""            # -C/--config brands/*.conf (carries HEADSCALE_URL/RELEASE_STATE/… presets)
    cluster_domain: str = "hugmesh.systems"
    # Ask 8 — "only show steps for users and domains if its selected to start with
    # aditional domains". WIZARD-FLOW state, never argv (NON_ARGV_FIELDS): False means
    # this mesh serves only its own cluster domain, so the Domains and Users tables have
    # nothing to say and their steps are skipped entirely (superadmin_plane_applies).
    # MESH ONLY — a cloud desktop client's Domains/Users step carries the FD-08 --domains
    # tie the image is built around, which is not "additional" anything.
    additional_domains: bool = False
    # Ask 20 — the users CHOICE screen's answer. WIZARD-FLOW state, never argv
    # (NON_ARGV_FIELDS). False (the default) = "generate the minimal default accounts"
    # — the accounts scripts/gen-provision-keys.sh mints into each node's KEYS folder,
    # which needs no table at all; True = the operator asked to name superusers/domain
    # users themselves, so the Users TABLE step becomes reachable (users_table_applies).
    # MESH ONLY, exactly like additional_domains.
    configure_users: bool = False
    superdomain: str = ""            # orchestration superdomain all mesh nodes join; "" = derived <brand>.internal. Emitted as --superdomain for MESH builds (WS-SUPER-B: baked to <etc>/superdomain + headscale MagicDNS); permanently internal, never go-live-flipped (I7)
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
    # ── mesh-node identity provider (I6; x86 + rpi5 node builders) ──
    # "casdoor" (the NATIVE DEFAULT) emits NOTHING — argv/sysroot byte-identity is
    # the hard invariant. External providers emit --idp/--idp-issuer/--idp-client-id
    # [--idp-jwks]; validate_identity() fail-closes the combinations (external needs
    # an https issuer + client id; casdoor requires the other three EMPTY).
    idp: str = "casdoor"               # IDP_CHOICES: casdoor | entra | aws | oidc
    idp_issuer: str = ""               # external OIDC issuer URL (https://…)
    idp_client_id: str = ""            # external OIDC client id (public identifier, not a secret)
    idp_jwks: str = ""                 # external JWKS URL override ("" = per-provider derivation)
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
    # ── web login theme (mesh/cluster-plane, NON-ARGV — see NON_ARGV_FIELDS) ──
    # These theme the Angular login-ui a node SERVES to browsers, not the desktop
    # image the fields above bake — which is why they are NOT x86-gated: the only
    # platform that renders them is the mesh plane the desktop gate would hide.
    # Derivation single-source: core/theme.py; delivery: SNAP_THEME_CSS env
    # (compose/localmesh) or the snap-theme ConfigMap (scripts/tooling/derive-theme.py).
    login_primary_color: str = ""      # "#RRGGBB"; "" = shipped default (#ffd700 family)
    login_secondary_color: str = ""    # "#RRGGBB" accent driver; "" = shipped #7c4dff
    login_font: str = ""               # a core/fonts.py FONT_PRESETS name; "" = shipped Arial stack
    login_font_file: str = ""          # uploaded woff2/woff/ttf/otf, embedded as a data: URI
    login_font_licence: str = ""       # REQUIRED with login_font_file (recorded for audit)
    login_font_source: str = ""        # REQUIRED with login_font_file: vendor/URL provenance
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
    # ── Character Forge (3D) multi-app slug — OPTIONAL, default off (admin gate) ──
    character_forge: bool | str = False   # tri-state: --with-character-forge / --no-character-forge (3D maker: BFF db+api + remote)
    # ── cluster optional services + games (node-scoped) ──
    optional_services: list[str] = field(default_factory=list)  # --optional-services slugs (+ none/all sentinels)
    exclude_services: list[str] = field(default_factory=list)   # --exclude-services subtractive list (applied last)
    enable_games: bool = False         # --enable-games (Game Studio + games.<domain>)
    # ── managed backing services (I8/M2; x86 + rpi5 node builders) ──
    # Map backing-service id -> operator-supplied HOSTED endpoint. The EMPTY default
    # (every backing service self-hosted) emits NOTHING — argv/sysroot byte-identity is
    # the #1 invariant. Each entry emits a repeatable `--managed-service id=endpoint`
    # (to_cli_args); the builder's gate_backing_services() then prunes the in-mesh
    # workload + repoints the consumer at <endpoint>. Only TIER-1/2 ids
    # (MANAGED_SERVICE_TIER12_IDS) are accepted; a TIER-3 docs-only id is REFUSED with its
    # blocker (validate_identity, mirroring the builder's fail-closed die). dict[str,str]
    # round-trips through save/load and the IMAGE_SPEC_JSON channel natively (JSON object),
    # and prevents a duplicate id. MESH-WIDE by nature (every node talks to the same
    # logical service) — a single-image field, deliberately NOT a per-node worklist axis.
    managed_services: dict[str, str] = field(default_factory=dict)  # id -> endpoint (repeatable --managed-service id=endpoint)
    # ── client desktop weight / gaming delivery (x86 client roles; frite: light|none) ──
    desktop: str = ""                  # --desktop: x86 thin|full; frite light|none ("" = default)
    steam: str = ""                    # --steam native|flatpak|none ("" = builder default)
    # ── thin-desktop stream host (§8b) — x86 tailnet client desktops, default off ──
    # Sunshine + the mesh-scoped nftables fence + in-session autostart, so a
    # mesh-enrolled Quest (Moonlight, the quest wizard's --thin-desktop leg) can
    # open this desktop over the tailnet ONLY. The builder warn-drops it on
    # non-client roles and tailnet-less desktops (standalone/unaffiliated/
    # --skip-tailscale) — the loud-harmless-no-op convention.
    sunshine: bool | str = False       # tri-state: --with-sunshine / --no-sunshine
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
    # ASK 13 (operator, verbatim): "cached iso, live iso, bundle, compress and resume
    # should all be default on". Three of the five are plain bools whose default lived
    # HERE, so this is where the change has to land — a widget edit alone is a no-op,
    # because BuildPage.initializePage re-seeds every control from cfg on every visit.
    # The per-flag "does default-on change the build?" answer ships next to each
    # checkbox, in the artifact caption BuildPage._art_row builds (and is pinned by
    # tests/test_pages_build.py::
    #   test_ask13_defaults_that_change_the_build_are_the_single_flags).
    # Short version: cached / compress / resume DO change what a run produces (their
    # builder defaults are all false); live_iso does not (LIVE_ISO=true already).
    #
    # bundle_source is the fifth and it is the one that needs saying out loud rather than
    # being counted with either group. Its default here has been True since long before
    # ask 13, so this lane moved nothing — but "default on" is NOT what a mesh operator
    # sees, because ModePage:172 sets it to (mode == "standalone") when the mode is
    # picked. That is deliberate and predates all of this: FieldScope pins bundle_source
    # to classes=("desktop",) — baking the 33MB generator tree into a cluster NODE is not
    # a thing anyone wants — so ask 13's "bundle … default on" holds on the standalone
    # flow, where the option means something, and is deliberately off on mesh nodes.
    # Left alone rather than "fixed" to match the ask literally: forcing it on for mesh
    # would put a self-hosting generator tree inside every node image.
    cached: bool = True                # --cached / --uncached  (ask 13: DEFAULT ON)
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
    compress: bool = True              # --compress: xz -9 the finished image(s)  (ask 13: DEFAULT ON)
    resume: bool = True                # --resume: reuse an existing sysroot      (ask 13: DEFAULT ON)
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
    def login_theme_css(self) -> str:
        """The derived snap-theme.css text for this config's ``login_*`` choices, or
        "" when unthemed. The ONE cfg->css point (wraps theme.compose_login_css):
        the wizard's browser preview, the localmesh bootstrap and any headless
        caller all share it, so the previewed bytes ARE the delivered bytes.

        Raises ValueError with the gate reasons on a blocked upload / malformed
        colour — callers on Qt slots must catch (an unhandled slot exception
        aborts PyQt6)."""
        from . import fonts as _fonts     # local: keep module import Qt/asset-free
        from . import theme as _theme
        font_bytes = b""
        family = ""
        if self.login_font_file:
            try:
                with open(self.login_font_file, "rb") as fh:
                    font_bytes = fh.read()
            except OSError as exc:
                raise ValueError(f"cannot read login_font_file: {exc}") from exc
            blocks, _warns = _fonts.check_font(
                os.path.basename(self.login_font_file), font_bytes)
            if blocks:
                raise ValueError("; ".join(blocks))
            family = os.path.splitext(os.path.basename(self.login_font_file))[0] \
                .replace("-", " ").replace("_", " ")
        return _theme.compose_login_css(
            self.login_primary_color, self.login_secondary_color,
            font_preset=self.login_font, font_family=family, font_bytes=font_bytes)

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
        # ── BRANDING LANE (ask 6): the premade theme NAME is a closed set ──────
        # `theme` is not free text: the builder concatenates it into
        # ${SPECS_DIR}/branding/themes/<name> and `cp -r`s that directory's contents
        # into the image's branding dir. Two things follow, and neither was enforced
        # anywhere outside the wizard:
        #   * a name with no directory behind it (a typo, a theme deleted since the
        #     config was saved, the BRAND name the old combo used to append) emits a
        #     --theme the build hard-errors on — but only ~2100 lines into the run,
        #     long after --print-plan said the plan was fine;
        #   * a name containing a path (`..`, `/`) resolves to a directory that DOES
        #     exist, passes the builder's `[ -d ]`, and `cp -r`s an arbitrary tree
        #     into the image.
        # The wizard closed its own half (the picker has no free-text path), but the
        # HEADLESS channel — a hand-written or hand-edited config JSON straight into
        # --print-command — had no check at all. Fail closed HERE, at the same
        # boundary every other enumerated field (idp, login_font) is checked, so the
        # offered set and the emitted set are the same four on every channel.
        #
        # SCOPED TO THE PLATFORMS THAT ACTUALLY EMIT IT. `theme` is x86-only
        # (PLATFORM_FIELD_SUPPORT); _rpi5_args/_jetson_args/_orangepi*_args never
        # write --theme, and strip_platform_unsupported clears the value outright, so
        # on those platforms there is no builder to fail closed against and nothing to
        # traverse a path into. Checking there anyway refused to emit ANY command for
        # a config every ARM builder had handled fine — and it would have hit EVERY
        # config saved before this branch, since the one theme that used to ship
        # (see branding_themes.REMOVED_THEMES) is not in the new set. An x86-only
        # field is dropped silently off-x86; that is the rule every other x86-only
        # field follows, and the guard now follows it too.
        if (self.platform or "x86") in PLATFORM_FIELD_SUPPORT.get("theme", ()) \
                and not is_valid_theme(self.theme):
            raise IdentityValidationError(
                f"unknown theme: {self.theme!r} — the premade set is exactly "
                f"{', '.join(PREMADE_THEMES)} (or \"\" for the stock look). "
                "Use branding_dir / wallpaper / ... for your own assets.")
        # web login theme: colours keep the strict #RRGGBB-or-empty shape (they flow
        # into SNAP_THEME_CSS / brands yaml); a font preset must be a known name (a
        # typo here would silently fall back at render time — fail closed instead);
        # an uploaded font is a licensing decision, so it REQUIRES recorded
        # licence + source provenance next to it.
        validate_login_color("login_primary_color", self.login_primary_color)
        validate_login_color("login_secondary_color", self.login_secondary_color)
        if self.login_font:
            from .fonts import FONT_PRESETS   # local import: keep config Qt/asset-free
            if self.login_font not in FONT_PRESETS:
                raise IdentityValidationError(
                    f"unknown login_font preset: {self.login_font!r} — "
                    f"known: {', '.join(FONT_PRESETS)}")
        if self.login_font_file:
            if not self.login_font_file.lower().endswith(
                    (".woff2", ".woff", ".ttf", ".otf")):
                raise IdentityValidationError(
                    f"login_font_file must be .woff2/.woff/.ttf/.otf: "
                    f"{self.login_font_file!r}")
            for fld in ("login_font_licence", "login_font_source"):
                v = getattr(self, fld)
                if not v or not v.isprintable():
                    raise IdentityValidationError(
                        f"{fld} is required (printable, non-empty) when uploading a "
                        "font — embedding a face we cannot attribute is the licensing "
                        "landmine the upload path exists to make explicit")
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
        # ── mesh-node identity provider (I6) — fail-closed at the earliest boundary.
        # The values flow into a root-baked idp.conf AND the builders' issuer/JWKS
        # sed rewrite, so both the combination rules and the charset are enforced
        # HERE (before --print-command / the GUI preview / any dispatch).
        if self.idp not in IDP_CHOICES:
            raise IdentityValidationError(
                f"unknown idp: {self.idp!r} — known: {', '.join(IDP_CHOICES)}")
        if self.idp == "casdoor":
            # The byte-identity invariant: the built-in default carries ZERO external
            # identity residue. A stray issuer/client/jwks with idp=casdoor is a
            # config bug (a half-switched provider), never silently ignored.
            for fld in ("idp_issuer", "idp_client_id", "idp_jwks"):
                if getattr(self, fld):
                    raise IdentityValidationError(
                        f"{fld} is set but idp is 'casdoor' (the built-in default) — "
                        "clear the field or pick an external provider (entra/aws/oidc)")
        else:
            if not self.idp_issuer or not _IDP_URL_RE.fullmatch(self.idp_issuer):
                raise IdentityValidationError(
                    f"idp={self.idp!r} requires an https:// idp_issuer "
                    f"(got {self.idp_issuer!r}) — the issuer is the token-validation "
                    "trust anchor and must be TLS")
            if not self.idp_client_id or not _IDP_CLIENT_ID_RE.fullmatch(self.idp_client_id):
                raise IdentityValidationError(
                    f"idp={self.idp!r} requires a non-empty idp_client_id "
                    f"(got {self.idp_client_id!r}; allowlist [A-Za-z0-9._:/-], max 128)")
            if self.idp_jwks and not _IDP_URL_RE.fullmatch(self.idp_jwks):
                raise IdentityValidationError(
                    f"idp_jwks must be an https:// URL (got {self.idp_jwks!r}) — "
                    "leave empty to derive the per-provider default")
        # ── managed backing services (I8/M2) — fail-closed at the earliest boundary.
        # Each id/endpoint flows onto --managed-service argv AND the root-baked
        # backing-services.conf, so both the known-set membership and the endpoint charset
        # are enforced HERE (before --print-command / the GUI preview / any dispatch). The
        # empty default (all self-hosted) validates trivially — byte-identity holds.
        for sid, ep in self.managed_services.items():
            if sid in MANAGED_SERVICE_TIER3_IDS:
                raise IdentityValidationError(
                    f"managed-service {sid!r} is TIER-3 (mode-locked self-hosted, docs-only "
                    f"in v1) — {MANAGED_SERVICE_TIER3_BLOCKER.get(sid, 'not implemented')}. "
                    "See docs/MANAGED-SERVICES.md")
            if sid not in MANAGED_SERVICE_TIER12_IDS:
                raise IdentityValidationError(
                    f"unknown managed-service id {sid!r} — known tier-1/2: "
                    f"{', '.join(MANAGED_SERVICE_TIER12_IDS)}")
            if not ep or not _MANAGED_ENDPOINT_RE.fullmatch(ep):
                raise IdentityValidationError(
                    f"managed-service {sid!r} endpoint {ep!r} is empty or malformed — "
                    "expected host[:port] or a URL (no shell metacharacters, no bare :port)")
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
        elif plat == "orangepizero2w":
            a = self._orangepizero2w_args()
        elif plat == "orangepizero3":
            a = self._orangepizero3_args()
        elif plat == "orangepi3-lts":
            a = self._orangepi3lts_args()
        elif plat == "orangepi4-lts":
            a = self._orangepi4lts_args()
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
        if self.brand != "hugmesh":
            a += ["--brand", self.brand]
        if self.brand_title != "HugMesh Systems":
            a += ["--brand-title", self.brand_title]
        if self.org != "hugmesh-net":
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

    def _managed_services_args(self) -> list[str]:
        """--managed-service id=endpoint (REPEATABLE) — the managed backing-services axis
        (I8/M2; parsed by the x86 + rpi5 node builders ONLY, gate_backing_services). The
        EMPTY default (every backing service self-hosted) emits NOTHING, so every existing
        flow's argv stays byte-identical (the #1 invariant). Ids/endpoints are fail-closed
        by validate_identity() before emission (tier-3 refused, endpoint shape-checked).
        Emitted in SORTED-id order for a deterministic argv."""
        a: list[str] = []
        for sid in sorted(self.managed_services):
            a += ["--managed-service", f"{sid}={self.managed_services[sid]}"]
        return a

    def _idp_args(self) -> list[str]:
        """--idp/--idp-issuer/--idp-client-id [--idp-jwks] — the mesh-node identity
        provider (I6; parsed by the x86 + rpi5 node builders ONLY). Emitted ONLY
        when idp != casdoor: the built-in default emits NOTHING, so every existing
        flow's argv stays byte-identical (the #1 invariant). validate_identity()
        already fail-closed the combination + charset before emission."""
        if self.idp == "casdoor":
            return []
        a = ["--idp", self.idp, "--idp-issuer", self.idp_issuer,
             "--idp-client-id", self.idp_client_id]
        if self.idp_jwks:
            a += ["--idp-jwks", self.idp_jwks]
        return a

    def _character_studio_args(self) -> list[str]:
        """--with-character-studio / --no-character-studio tri-state (x86 + rpi5)."""
        cs = self._tri(self.character_studio)
        if cs == "on":
            return ["--with-character-studio"]
        if cs == "off":
            return ["--no-character-studio"]
        return []

    def _character_forge_args(self) -> list[str]:
        """--with-character-forge / --no-character-forge tri-state (x86 + rpi5).
        The Character Forge multi-app slug (BFF db + BFF api + UI remote) —
        mirrors _character_studio_args' shape exactly."""
        cf = self._tri(self.character_forge)
        if cf == "on":
            return ["--with-character-forge"]
        if cf == "off":
            return ["--no-character-forge"]
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
        if self.cluster_domain != "hugmesh.systems":
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
        # managed backing services (I8/M2) — rpi5 shares the x86 node-builder axis;
        # the empty default emits nothing (byte-identity).
        a += self._managed_services_args()
        a += self._character_studio_args()
        # character_forge shares character_studio's x86+rpi5 surface — this call
        # was MISSING on the rpi5 branch (a main-merge artifact: the rpi5 builder
        # parses --with/--no-character-forge and the capability table declares
        # _X86_RPI5, but no rpi5 argv ever carried it; flag-coverage's forward
        # check + test_g34_rpi5_character_forge_tristate_both_ways caught it).
        a += self._character_forge_args()
        a += self._edge_ai_tts_args()
        # mesh-node identity provider (I6) — rpi5 shares the x86 node-builder
        # surface; the casdoor default emits nothing (byte-identity).
        a += self._idp_args()
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

    def _orangepizero2w_args(self) -> list[str]:
        """build-orangepi-zero2w-stage4.sh — arm64 HEADLESS APPLIANCE: flavor
        only, no --role AND no --board (a single board). EXPERIMENTAL (hardware
        validation pending): byte-identical emission shape to
        _orangepizero2_args() — the Zero 2W is a faithful derivation of the
        Zero 2 template (H618 instead of H616; see
        specs-orangepi-zero2w/README.md for the honest hardware deltas, incl.
        NO onboard Ethernet), so there is no --desktop toggle to emit here
        either."""
        a: list[str] = ["--flavor", self.flavor or "both"]
        if self.dtb:
            a += ["--dtb", self.dtb]
        a += self._uboot_args()
        a += self._arm_common_args()
        a += self._encrypt_root_args()
        if self.image_only:
            a += ["--image-only"]
        return a

    def _orangepi3lts_args(self) -> list[str]:
        """build-orangepi3-lts-stage4.sh — arm64 HEADLESS APPLIANCE: flavor
        only, no --role AND no --board (a single board). EXPERIMENTAL (hardware
        validation pending): byte-identical emission shape to
        _orangepizero2_args() — the Orange Pi 3 LTS is a faithful derivation of
        the Zero 2 template (Allwinner H6; boots the PLAIN OPi3's mainline
        DTB/defconfig since mainline has no -lts variant, and its onboard GbE
        jack is dead on that DTB — USB-Ethernet-first; see
        specs-orangepi3-lts/README.md for the honest hardware deltas), so
        there is no --desktop toggle to emit here either."""
        a: list[str] = ["--flavor", self.flavor or "both"]
        if self.dtb:
            a += ["--dtb", self.dtb]
        a += self._uboot_args()
        a += self._arm_common_args()
        a += self._encrypt_root_args()
        if self.image_only:
            a += ["--image-only"]
        return a

    def _orangepi4lts_args(self) -> list[str]:
        """build-orangepi4-lts-stage4.sh — arm64 LIGHT-DESKTOP CLIENT: flavor
        only, no --role and no --board. EXPERIMENTAL (hardware validation
        pending).

        Emission shape is _orangepi5_args() MINUS --board, NOT the appliance
        shape the other Orange Pi platforms use. Two independent reasons, and
        they pull in opposite directions:
          * DESKTOP, like orangepi5: the mainline rk3399-orangepi.dts this
            image boots has an ENABLED &gpu ("arm,mali-t860" -> panfrost), an
            ENABLED &hdmi and both VOPs, so there is a real display pipeline.
            Hence orangepi4-lts is in _ARM_DESKTOP_ROLES. Like orangepi5 there
            is no headless variant to gate, so no --desktop toggle is emitted.
          * SINGLE-BOARD, like the appliances: mainline ships exactly one
            Orange Pi RK3399 DTB and one U-Boot defconfig for the whole
            4/4B/4 LTS family, so a --board axis would be a fake axis.
        See specs-orangepi4-lts/README.md."""
        a: list[str] = ["--flavor", self.flavor or "both"]
        if self.dtb:
            a += ["--dtb", self.dtb]
        a += self._uboot_args()
        a += self._arm_common_args()
        a += self._encrypt_root_args()
        if self.image_only:
            a += ["--image-only"]
        return a

    def _orangepizero3_args(self) -> list[str]:
        """build-orangepi-zero3-stage4.sh — arm64 HEADLESS APPLIANCE: flavor
        only, no --role AND no --board (a single board). EXPERIMENTAL (hardware
        validation pending): byte-identical emission shape to
        _orangepizero2_args() — the Zero 3 is a faithful derivation of the
        Zero 2 template (H618 instead of H616; see
        specs-orangepi-zero3/README.md for the honest hardware deltas — its
        onboard Gigabit Ethernet is BACK, unlike the Zero 2W), so there is no
        --desktop toggle to emit here either."""
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
        bake a brand identity, branding assets, the bundled HugMesh source, the
        stack seed, or platform machinery (mesh/SSO/person-device identity) into the
        image raises ValueError HERE — so --print-command and the GUI preview fail
        loudly with the same contract the builder enforces (it exits non-zero on the
        equivalent flags; an explicit --brand gentoo errors too — the builder forces
        the neutral identity itself)."""
        conflicts: list[str] = []
        if (self.brand != "hugmesh" or self.brand_title != "HugMesh Systems"
                or self.org != "hugmesh-net"):
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
            conflicts.append("home_seed_code (seeds the HugMesh stack into the home)")
        # RESOLVED values: on the (required) standalone mode a never-set field is
        # OFF, so only an explicit opt-in conflicts — and on a (conflicting)
        # cloud/mesh mode the mode line below names the real problem anyway.
        if self.tailscale_enabled():
            conflicts.append("tailscale (the tailnet is HugMesh platform machinery)")
        if self.sso_enabled():
            conflicts.append("sso (Casdoor SSO is HugMesh platform machinery)")
        if self.mode in ("cloud", "mesh"):
            conflicts.append(f"mode={self.mode!r} (emits --person-role/--domains — "
                             "person-device identity is platform machinery)")
        if conflicts:
            raise ValueError(
                "role standalone-unaffiliated builds a plain Gentoo desktop with ZERO "
                "HugMesh affiliation, but this config sets " + "; ".join(conflicts)
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
            if self.cluster_domain != "hugmesh.systems":
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
        # Thin-desktop stream host (Sunshine; §8b) — x86 tailnet client desktops.
        # Tri-state (G34): --no-sunshine can force a brand.conf default OFF; the
        # builder warn-drops the flag on roles/desktops it cannot apply to.
        sun = self._tri(self.sunshine)
        if sun == "on":
            a += ["--with-sunshine"]
        elif sun == "off":
            a += ["--no-sunshine"]
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

        # Character Forge (3D) multi-app slug — OPTIONAL, DEFAULT-OFF (admin gate).
        # Folds 'character-forge' into OPTIONAL_SERVICES. Same cluster-only scope +
        # tri-state shape as character_studio above (--no-character-forge).
        a += self._character_forge_args()

        # mesh-node identity provider (I6). Casdoor default = ZERO emission (the
        # byte-identity invariant); external providers thread the 4 idp flags the
        # builder bakes into idp.conf + the post-rebrand issuer/JWKS rewrite.
        a += self._idp_args()

        # cluster optional services (+ explicit-none / all sentinels + the subtractive
        # exclude list) and the games stack (--enable-games folds 'games' in).
        a += self._services_args()
        if self.enable_games:
            a += ["--enable-games"]

        # managed backing services (I8/M2). The empty default = every backing service
        # self-hosted = ZERO emission (byte-identity); each selected id threads a
        # repeatable --managed-service id=endpoint the builder's gate_backing_services
        # honours (prune in-mesh workload + repoint the consumer).
        a += self._managed_services_args()

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
        path = os.path.join(output_dir, "hugmesh-mesh-manifest.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(self.mesh_manifest(), fh, indent=2)
        return path

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

import base64
import binascii
import copy
import getpass
import json
import os
import re
import shlex
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field, asdict, MISSING
from typing import Any, NamedTuple

import sys

from . import roles
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
# "domain_services" (#494/#495) sits IMMEDIATELY after "domains": the operator asked for
# "a service page per domain you make you have to go through before building or starting
# a mesh", so the per-domain service choice is a STEP in the domain flow rather than a
# toolbutton in a Domains-table row nothing obliged anyone to open. It is dynamically
# skipped (applies_to) when the flow has no named domain, and standalone skips it
# statically for the same reason it skips "domains" — no admin/mesh plane at all.
#
# ASK 22 splits the terminal pair in three: "build" is the REVIEW screen (what will be
# built + the knobs), "launch" is the separate BUILD screen (continue the build / back
# to the main menu), "progress" runs it. Nothing dispatches until Continue is pressed.
#
# Issue #50 (welcome flow): "welcome" is the three-card first screen (start building /
# start a local mesh / review prior sessions) and "sessions" is the demoted old first
# screen (Load/Save config + the Previous-builds manager). "sessions" sits IMMEDIATELY
# after "welcome": only WelcomePage.nextId() ever routes INTO it (a plain Next flows
# welcome -> mode), and its own positional next is "mode" — reviewing what you built
# continues naturally into building. A fresh start shows "welcome" (first slug, and
# nothing sets a start id); prior-session RESTART still enters at "progress" via
# StudioWizard.start_build_from_session.
#
# "e2e" is the RUN E2E TESTS side-flow page (operator ask 2026-08-27: "remove QEMU
# device emulation menu item ... but add the run e2e tests button"). It took the mode
# menu slot the "QEMU device tests" card used to hold, and it is the ONLY door to
# "qemu" now: the card is gone, so E2EPage's second arm is what writes
# wiz.qemu_selected. "qemu" therefore sits IMMEDIATELY after "e2e" — nextId()'s skip
# walk is positional, so the arming page has to come first.
#
# "qemu" is the QEMU device-test page: KEPT, registered and reachable. Removing a
# MENU CARD must not delete a lane, and this one is not redundant with "meshemu" the
# way the card's blurb implied — it is the only Studio door to the Playwright-on-an-
# emulated-device harness (tests/qemu/run-qemu-e2e.sh) and to the SELinux AVC workout
# (tests/qemu/avc-workout.sh). It is ALSO still reached post-build, with no menu at
# all, via BuildPage's qemu_device_tests opt-in -> progress.py _maybe_qemu_tests().
#
# "meshemu" is the whole-mesh-emulation side-flow page: it sits IMMEDIATELY after
# "qemu" (the journey reads e2e -> QEMU device tests -> whole-mesh emulation),
# dynamically skipped (applies_to) unless its ModePage card was picked.
#
# "localcloud" (issue #50) is the create-nodes-for-local-cloud GATE page: the last
# side-flow slot before "idp", dynamically skipped (applies_to) unless its ModePage
# card was picked; unlike its terminal siblings it REJOINS the image flow as an
# abbreviated mesh wizard (it commits cfg.mode="mesh" itself on Next).
# "vault" (issue #224) is the mesh SECRETS-STORE page: where a node fetches its
# cluster secrets from (a HashiCorp Vault address + KV mount + base path). A cluster-
# NODE first-boot concern, so it is skipped statically by the two non-node modes
# exactly like "idp"; it sits after "system" (host identity) and before the desktop-
# only "home" page. The empty default emits NOTHING (offline/USB-only delivery).
WIZARD_PAGE_SLUGS = ("welcome", "sessions",
                     "mode", "localmesh", "phone", "quest", "deploy",
                     "e2e", "qemu", "meshemu", "localcloud",
                     "idp", "role",
                     "worklist", "hardware", "branding", "network", "keyzip",
                     "domains_choice", "domains", "domain_services",
                     "users_choice", "users",
                     "system", "vault", "home", "build", "launch", "progress")
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
                   "domains_choice", "domains", "domain_services",
                   "users_choice", "users",
                   "vault"),                                  # single image, no admin/mesh plane
    # "domain_services" (#495) is NOT skipped in cloud: a cloud client image IS built
    # around its --domains tie, its Domains table is unconditional, and the domain it
    # carries is exactly the one whose services the operator must answer for.
    # "vault" STAYS skipped in cloud (#588, decided 2026-09-24): the builder ignores
    # --vault-addr on a client role and the per-domain CA is recorded-only, so the
    # step would offer knobs a client build discards. The Domains step says where a
    # client's trust really comes from instead (CLIENT_CA_INHERITANCE_NOTE).
    "cloud": ("idp", "worklist", "domains_choice", "users_choice",
              "vault"),                                       # single image, admin plane via key-zip
    # mesh USED to skip "branding" outright; it no longer can: the page now also hosts
    # the WEB login theme (login_* — NON_ARGV_FIELDS), which themes the login-ui the
    # MESH serves to browsers. The DESKTOP-theme half shows in mesh too whenever the
    # worklist carries a desktop-class x86 entry (laptop/chromebook) — materialize()'s
    # per-entry clear keeps the theme off node entries — and greys otherwise.
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
        # pki/backend/frontend are node images buildable on x86 OR a Raspberry Pi 4/5
        # board (Pi 3 is desktop-only — 1GB RAM can't host the node stack, so the rpi5
        # board picker offers only rpi5/rpi4 for these; see rpi_boards_for_role()).
        # THE IDS ARE THE BUILDER TOKENS. They used to be `be`/`fe`/`be+gpu` here and
        # `backend`/`frontend` on the Pi builder, bridged by a hand-written
        # RPI5_ROLE_MAP; there is now one vocabulary (scripts/_roles-lib.sh) and
        # nothing to translate. Every old id still LOADS from a saved session — see
        # WorklistEntry.from_dict / BuildSession.from_dict.
        # The Orange Pi 5 / 5 Plus builds pki/backend/frontend/omnibus and the 4 GB
        # Orange Pi 4 LTS builds frontend only — both EXPERIMENTAL (no Orange Pi has
        # booted an image from this repo; hardware validation pending). Installer
        # flavor only. scripts/_roles-lib.sh HUGMESH_ROLES_ORANGEPI5/_ORANGEPI4LTS.
        ("pki", ("x86", "rpi5", "orangepi5"),
         "PKI node — cluster certificate authority (x86, Raspberry Pi 4/5, or Orange Pi 5 — EXPERIMENTAL)"),
        ("backend", ("x86", "rpi5", "orangepi5"),
         "Backend node (x86, Raspberry Pi 4/5, or Orange Pi 5 — EXPERIMENTAL)"),
        ("frontend", ("x86", "rpi5", "orangepi5", "orangepi4-lts"),
         "Frontend node (x86, Raspberry Pi 4/5, or Orange Pi 5 / 4 LTS — EXPERIMENTAL)"),
        ("backend-gpu", ("x86", "jetson"),
         "Backend + GPU node — a backend worker with a GPU, no inference service "
         "(x86, or Jetson Orin — EXPERIMENTAL)"),
        # omnibus on a Raspberry Pi 5 or Orange Pi 5 needs the board's RAM (16 GB+;
        # ImageConfig.ram_gb -> --ram-gb): one image serves every RAM size it is sold in.
        ("omnibus", ("x86", "jetson", "rpi5", "orangepi5"),
         "Omnibus — every cluster role on one node (x86; Raspberry Pi 5 or Orange Pi 5 "
         "with 16 GB+ RAM; Jetson Orin / Orange Pi — EXPERIMENTAL)"),
        # Person-device desktops attachable to the mesh (operator ask 2026-08-14):
        # checking one on the WorklistPage asks for the person's user + role via a
        # popup; the account is provisioned on the internal Tailscale root
        # domain and the role rides the image as --person-role (FD-08).
        ("laptop", ("x86",), "Laptop desktop — tailnet + SSO client for a person on this mesh"),
        ("chromebook", ("x86",),
         "Chromebook desktop — coreboot/UEFI laptop client (ADR-16); tailnet + SSO"),
        ("desktop", ("x86",), "Desktop client — tailnet + SSO client for a person on this mesh"),
        ("rpi5-desktop", ("rpi5",),
         "Raspberry Pi 5 / 4 / 3 desktop — arm64 client (compose with --standalone for FDE, no mesh)"),
        ("edge-ai", ("x86", "jetson"), "Edge-AI node — GPU + OpenAI-compatible model API"),
        # `full` and `gpu-host` were the SAME two roles as omnibus and backend-gpu
        # above — build-jetson-stage4.sh's own comments called them "the omnibus
        # analogue" and "the be+gpu analogue". They are merged into those entries
        # rather than offered twice under two more names; both old spellings remain
        # accepted on the builder CLI forever.
        ("jetson-desktop", ("jetson",), "Jetson desktop — EXPERIMENTAL, hardware validation pending"),
    ],
}

# The x86 role that builds a PLAIN, unaffiliated Gentoo desktop. The builder's role
# arm PRESETS everything (neutral gentoo identity, no bundled source, no mesh/SSO)
# and HARD-ERRORS on any brand/branding/bundle/seed/mesh/SSO/person flag — so the
# Studio raises the same conflicts instead of emitting them (fail loudly, like the
# builder), and emits the bare role + generic options only.
UNAFFILIATED_ROLE = "standalone-unaffiliated"

# ── what is LEFT of the translation, and why ────────────────────────────────────
# RPI5_ROLE_MAP used to hold {"be": "backend", "fe": "frontend", "rpi5-desktop":
# "desktop"} and was applied on the way to build-rpi5-stage4.sh. The first two
# entries are GONE: the Studio id and the builder token are the same word now, on
# every platform, so there is nothing left to translate.
#
# What survives is ONE thing, and it is not a spelling. `rpi5-desktop` and
# `jetson-desktop` are COMPOSITE ids that mangle a PLATFORM into the role string.
# They resolve to (role=desktop, platform=<that platform>) — a different kind of
# fold, where dropping the platform half would silently build the wrong image.
# Retiring them (keying the menus on the (platform, role) PAIR instead) touches the
# persisted session schema and is deliberately deferred; until then they are DERIVED
# from the single source rather than hand-written here:
#     scripts/_roles-lib.sh                HUGMESH_ROLE_COMPOSITE
#     studio/hugmesh_studio/core/roles.py  composite_aliases()
# The two names are kept so existing callers and tests keep working, but they are now
# VIEWS on that one declaration, not a second copy of it.
RPI5_ROLE_MAP = {a: c for a, (c, k, v) in roles.composite_aliases().items()
                 if k == "platform" and v == "rpi5"}
JETSON_ROLE_MAP = {a: c for a, (c, k, v) in roles.composite_aliases().items()
                   if k == "platform" and v == "jetson"}

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

# --compress-level N: the xz preset --compress uses, on EVERY builder (issue #233's one
# unchecked box, "consider allowing the xz compression level to be changed"). 0-9 is xz's
# own range and the range each builder validates, so the GUI offers exactly that — one
# range, no second narrower policy to drift from the flag. 9 is the level every builder
# hardcoded before this flag existed and stays the default, so an existing config's
# emission is byte-identical (to_cli_args omits --compress-level at the default).
#
# SCOPE, stated once: the level applies to the --compress path only — the `xz -T0 -6`
# invocations that always build the stage4 archive and fs.tar.xz are NOT --compress
# artifacts and are deliberately untouched (build-x86-host-stage4.sh:6420/6423/6743/6744,
# build-rpi5-stage4.sh:4638/4639). Changing those would alter what a build with no
# compression flags at all emits.
COMPRESS_LEVEL_CHOICES = tuple(range(10))
COMPRESS_LEVEL_DEFAULT = 9


def clamp_compress_level(value) -> int:
    """The ONE reading of a compress_level that came from an untrusted source.

    The GUI combo can only ever hold COMPRESS_LEVEL_CHOICES, but a hand-edited
    ``--config`` JSON can carry anything, and the builders hard-error on a level
    outside 0-9 (they validate the flag). Both readers of that untrusted value —
    ``ImageConfig._compress_level_args`` on emission and BuildPage.initializePage
    when it restores the combo — go through HERE, so the level the page shows and
    the level the builder is handed are the same function of the same file. Two
    different readings would mean one config.json produced two different artifacts
    depending on whether the operator happened to open the Build page.

    Out of range clamps to the nearest legal preset; junk that is not a number at
    all resolves to the builder default (which emits no flag at all)."""
    try:
        return max(0, min(9, int(value)))
    except (TypeError, ValueError):
        return COMPRESS_LEVEL_DEFAULT


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
# does NOT include (build-rpi5-stage4.sh usage :791, build-x86-host-stage4.sh :697).
# BOTH builders accept all four as catalogue slugs (issue #265, measured 2026-09-16):
# build-x86-host-stage4.sh:179 SELECTABLE_OPTIONAL_SERVICES lists egress-vpn, tor,
# workloadConsole and anubis, and every one of their registry rows says
# `buildGate: [rpi5, x86]` (specs/cluster/optional-services.yaml:721/:800/:845/:964).
# The gate itself is shared (scripts/_optional-services-lib.sh, sourced by both), so
# a slug resolves identically from either builder. x86 ALSO has a dedicated --with-tor;
# the Network page's _service_channel lets the flag win wherever it is parsed, so
# listing tor here changes nothing tor emits on x86. (x86's --egress-vpn FILE is a
# DIFFERENT thing — a desktop node's own VPN profile — not the cluster egress-vpn
# service this slug selects.) frite/jetson/opi5/opz2 parse no --optional-services.
INFRA_SERVICES_CHOICES = ("tor", "egress-vpn", "workloadConsole", "anubis")

# Which optional-service slugs each builder's --optional-services accepts. Only x86 and
# rpi5 parse --optional-services/--exclude-services/--enable-games at all — the other
# four builders bake no cluster tree, so the widgets must be greyed there (G12/G15).
# The two catalogues are IDENTICAL on purpose: the builders' selectable sets are (see
# INFRA_SERVICES_CHOICES). Folding the infra slugs into rpi5 alone was correct only
# while anubis's buildGate was [rpi5]; it has said [rpi5, x86] since 2026-08-26, and
# the stale x86 catalogue HID the anubis and workloadConsole rows on the platform every
# mesh flow forces on its shared worklist base (issue #265 / #226 "where's anubis?").
OPTIONAL_SERVICES_BY_PLATFORM = {
    "x86": OPTIONAL_SERVICES_CHOICES + INFRA_SERVICES_CHOICES,
    "rpi5": OPTIONAL_SERVICES_CHOICES + INFRA_SERVICES_CHOICES,
    # Orange Pi NODE roles (EXPERIMENTAL): the user-level set plus the two cluster-plane
    # infra slugs. NOT tor / egress-vpn: those are host daemons the Orange Pi node image
    # does not carry, and its builder refuses them (scripts/_node-role-lib.sh
    # NODE_ROLE_UNSUPPORTED_HOST_SLUGS) rather than bake the cluster app alone.
    "orangepi5": OPTIONAL_SERVICES_CHOICES + ("workloadConsole", "anubis"),
    "orangepi4-lts": OPTIONAL_SERVICES_CHOICES + ("workloadConsole", "anubis"),
}

# --optional-services sentinels (mirror build-menu.sh's OPT_SERVICES + the builders):
#   optional_services == []            -> emit nothing (builder default akkoma tuwunel phpbb)
#   optional_services == [SERVICES_NONE] -> emit --optional-services "" (EXPLICIT none, G13)
#   optional_services == [SERVICES_ALL]  -> emit --all-services (full user-level set, G14)
#   optional_services == [slug, ...]     -> emit --optional-services "slug ..." (allow-list)
SERVICES_NONE = "none"
SERVICES_ALL = "all"

# The builders' OWN built-in default selection when no --optional-services is given:
#   build-x86-host-stage4.sh:196   OPTIONAL_SERVICES="${OPTIONAL_SERVICES:-akkoma tuwunel phpbb}"
#   build-rpi5-stage4.sh:254       (identical line)
# The services table PRE-TICKS exactly these rows on arrival, because they are what an
# untouched build genuinely ships — eight unticked boxes over a mesh that runs three of
# them anyway is the same lie as a part-checked square (ask 23: "anything off by default
# is UNCHECKED; only pre-check what is genuinely on by default"), and it also made
# unticking `phpbb` a no-op, since --optional-services REPLACES rather than subtracts.
# tests/test_services_section.py parses both builder scripts and asserts set-equality with
# this tuple, so it cannot go stale into a comment.
BUILTIN_DEFAULT_SERVICES = ("akkoma", "tuwunel", "phpbb")

# What the `all` sentinel / --all-services ACTUALLY expands to, mirrored from the single
# line both node builders declare it on:
#   build-x86-host-stage4.sh:136   USER_LEVEL_SERVICES="akkoma tuwunel phpbb games owncast
#                                  tube character-studio character-forge"
#   build-rpi5-stage4.sh:241       (identical line)
# and expanded into OPTIONAL_SERVICES at build-x86-host-stage4.sh:1177-1191 /
# build-rpi5-stage4.sh:1111-1125 — BEFORE the --with-<x> opt-in folds, so a slug in this set is
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

# The anubis (public proof-of-work gate) row is a TRI-STATE, not a tick (issue #384):
#   ""    -> the build's own ENV policy decides (prod on, test off); emits nothing
#   "on"  -> force ON  — the `anubis` slug in --optional-services
#   "off" -> force OFF — the `-anubis` token in --optional-services (NEVER
#            --exclude-services: both builders refuse that spelling for it, because
#            subtraction cannot beat the ENV default)
ANUBIS_SLUG = "anubis"
ANUBIS_OFF_TOKEN = "-anubis"
ANUBIS_CHOICES = ("", "on", "off")
# The words BOTH faces show for those three values (the GUI combo's items, the TUI's
# state column), kept beside the values so the two cannot spell them differently.
ANUBIS_LABELS = {"": "Default", "on": "Force on", "off": "Force off"}


def anubis_locked(optional_services) -> bool:
    """Is the anubis choice locked at Default by a whole-set selection?

    ``--optional-services ""`` (no services at all) and ``--all-services`` each REPLACE
    the slug list the choice rides in, so on both faces the row is decided by the preset
    and reads Default until the operator goes back to picking services one by one."""
    svcs = [str(s) for s in (optional_services or [])]
    return SERVICES_NONE in svcs or SERVICES_ALL in svcs


def anubis_shown(cfg) -> str:
    """The value ("", "on" or "off") a face should SHOW for ``cfg``: the field itself,
    else what a pre-tri-state picker spelling already says (the ``anubis`` slug is Force
    on, ``-anubis`` / ``no-anubis`` is Force off). ``_services_args`` lets the field beat
    a contradicting spelling, so the field is read first."""
    mode = ImageConfig._anubis_mode(getattr(cfg, "anubis", ""))
    if mode:
        return mode
    svcs = [str(x) for x in (getattr(cfg, "optional_services", None) or [])]
    if ANUBIS_OFF_TOKEN in svcs or "no-anubis" in svcs:
        return "off"
    return "on" if ANUBIS_SLUG in svcs else ""


def client_class_role(role: str, platform: str) -> bool:
    """True when ``role`` builds a CLIENT-class (desktop) image on ``platform`` — the
    class whose builder accepts ``--optional-services`` but bakes no cluster GitOps tree
    (build-x86 skips the specs/cluster copy for ROLE_CLIENT; build-rpi5's plan echoes
    'n/a (role=desktop; no cluster GitOps tree baked)').

    * x86 — every role NOT in X86_NODE_ROLES (laptop/chromebook/desktop and all the
      standalone-* desktops);
    * rpi5 — ONLY builder ``--role desktop`` (Studio id rpi5-desktop, RPI5_ROLE_MAP);
      generic/pki/backend/frontend are cluster-node class, and standalone 'generic'
      DOES bake the tree (G16), so it must NOT count as client.

    Qt-free so the GUI Network page and the TUI Network step share ONE answer."""
    p = platform or "x86"
    if p == "rpi5":
        return RPI5_ROLE_MAP.get(role, role) == "desktop"
    if p == "x86":
        return role not in X86_NODE_ROLES
    return False


def services_catalog(cfg) -> tuple:
    """The optional-service slugs THIS image's builder accepts: the platform catalogue
    (OPTIONAL_SERVICES_BY_PLATFORM), except an Orange Pi DESKTOP row, whose builder bakes
    no cluster tree and refuses --optional-services (only its NODE roles take them)."""
    plat = getattr(cfg, "platform", "") or "x86"
    if plat in _OPI_NODE_PLATFORMS and getattr(cfg, "role", "") not in _ORANGEPI_NODE_ROLE_IDS:
        return ()
    return tuple(OPTIONAL_SERVICES_BY_PLATFORM.get(plat, ()))


def services_picker_hidden(cfg) -> bool:
    """True when the Network page hides the whole cluster-services picker — and with it
    the anubis row — for ``cfg``: an unaffiliated image (no HugMesh plane at all) or a
    standalone CLIENT-class desktop (no cluster tree is baked, so a selection would be
    accepted and ignored). Standalone rpi5 'generic' is cluster-node class and is NOT
    hidden: its builder bakes the tree, so the row applies there on both faces."""
    platform = getattr(cfg, "platform", "") or "x86"
    return bool(
        getattr(cfg, "role", "") == UNAFFILIATED_ROLE
        or getattr(cfg, "unaffiliated", False)
        or (getattr(cfg, "mode", "") == "standalone"
            and platform in PLATFORM_FIELD_SUPPORT.get("optional_services", (platform,))
            and client_class_role(getattr(cfg, "role", ""), platform)))


def with_service_slug(services, slug: str) -> list[str]:
    """``services`` (an ImageConfig.optional_services value) with ``slug`` ADDED —
    additively, the way a per-node infra toggle means it.

    ``--optional-services`` is an ALLOW-LIST that REPLACES the builder's own default
    (the builders' OPTIONAL_SERVICES default line), so a bare append is
    only right when the list already names services. The three other shapes each
    used to lose something without a word:

    * ``[]`` (emit nothing, the builder default applies) -> ``["tor"]`` emitted
      ``--optional-services tor`` and silently DROPPED akkoma/tuwunel/phpbb from the
      node. It becomes the builder default plus the slug.
    * ``[SERVICES_NONE]`` (the explicit "no optional services") -> ``["none", "tor"]``
      emitted the literal slug ``none``. It becomes just the slug.
    * ``[SERVICES_ALL, ...]`` -> ``--all-services`` expands to the USER-LEVEL set only,
      which by construction excludes every infra slug, so the slug was dropped. It
      becomes the user-level set spelled out, plus whatever else was listed, plus the
      slug (both builders' own all-expansion keeps nothing beyond the user-level set).
    """
    svcs = [str(s) for s in (services or [])]
    if slug in svcs:
        return svcs
    if svcs == [SERVICES_NONE]:
        base: list[str] = []
    elif SERVICES_ALL in svcs:
        base = list(USER_LEVEL_SERVICES) + [
            s for s in svcs if s not in (SERVICES_ALL, SERVICES_NONE)
            and s not in USER_LEVEL_SERVICES]
    elif not svcs:
        base = list(BUILTIN_DEFAULT_SERVICES)
    else:
        base = svcs
    return [*base, slug]


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
    "media-poisoner": "AI media cloak — perturbs an opted-in image before it is "
                      "posted, so a scraped copy degrades a training run instead "
                      "of feeding it. Turns on the 'AI media cloak' control in "
                      "user preferences.",
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
    # ISSUE #226 ASK 7. Worded in the order _opt_anubis_installed actually decides
    # in (scripts/_optional-services-lib.sh:478-482): it tests _opt_selected FIRST
    # and only falls through to the ENV split when the operator said nothing, so a
    # ticked row installs anubis on ANY build — including the default ENV=test one
    # (ImageConfig().env == "test"). Saying it "stays off on a test build" would be
    # false for the one action this row exists to perform.
    "anubis": "Anti-scraper proof-of-work gate in front of the public web routes. "
              "Force on installs it on any build; Default leaves it to the build "
              "(a prod build turns it on by itself, a test build leaves it off); "
              "Force off keeps it out of a prod build.",
}

# Presentation grouping for the services surface: (group title, (slug, ...)). Ordered —
# the section renders groups in this order and slugs in the order listed. A slug the
# selected platform's catalog does not carry is simply not rendered, so one table drives
# every platform. Grouping is by WHAT THE SERVICE IS FOR, which is the axis the operator
# reads; the previous surface grouped by "which flag emits it", which is an
# implementation detail they cannot see.
SERVICE_GROUPS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("Social & Community", ("akkoma", "tuwunel", "phpbb")),
    ("Media & Play", ("owncast", "tube", "games")),
    ("Characters & Avatars", ("character-studio", "character-forge", "edge-ai-tts")),
    ("Network & Access", ("egress-vpn", "workloadConsole")),
    # All three of these are here because PRIVACY is what they are FOR, which is the
    # axis the operator reads. `tor` and `anubis` sat under "Network & Access" only
    # because they are also network-level, which is the implementation detail, not
    # the purpose: `tor` is a privacy TRANSPORT (reach the mesh without exposing a
    # public IP or a DNS name to whoever is watching), and `anubis` is the
    # anti-scraper gate on the public routes. The AI cloak sits here rather than
    # under "Characters & Avatars" for the same why-not-what reason: it is a
    # protection applied to what a person UPLOADS, not a thing they create with.
    # What stays in "Network & Access" is the plumbing that carries no privacy claim
    # — where this node's egress goes, and a console for its workloads.
    #
    # ISSUE #226 ASK 7, verbatim: "where's anubis? if it is forced on, rename
    # 'Privacy & anti-scraping' to just 'Privacy services' (or similar)". The
    # condition HOLDS — scripts/_optional-services-lib.sh:478-482
    # (_opt_anubis_installed) returns "true" for every ENV=prod build unless the
    # operator passes the explicit "-anubis"/"no-anubis" spelling, and
    # build-x86-host-stage4.sh REFUSES --exclude-services for it by name. So the
    # title can no longer promise "anti-scraping" as something you pick here; the
    # per-row description says what anubis actually does instead.
    ("Privacy Services", ("tor", "anubis", "media-poisoner")),
)

# --person-role client-identity picker (FD-08). The x86 builder honours --person-role/
# --domains only for ROLE_CLIENT roles (the person-device desktops laptop/chromebook/
# desktop AND the standalone desktops); on a cluster NODE role it warns + IGNORES them
# (build-x86:1722-1724), so the Studio must NOT emit them for a node role (G18).
PERSON_ROLE_CHOICES = ("user", "mod", "admin", "superadmin")
# The per-ACCOUNT role vocabulary of the superadmin Users table (G20; issue #228): the
# four platform tiers PLUS the GRANTABLE games roles from the systems Casdoor seed
# (specs/cluster/manifests/casdoor/init-data-configmap.yaml): 'games' -> ROLE_GAMES
# (Games Member) and 'games-services' -> ROLE_GAMES_SERVICES (Games App-Store Access).
# The DERIVED intersection roles (ROLE_GAMES_ADMIN, ROLE_GAMES_SERVICES_ADMIN/_RUNNER)
# are deliberately NOT offered — the admin-sync Jobs materialize them from role
# intersections, and seeding them directly would bypass that default-deny.
#
# The ORDER is the precedence: a multi-role account (issue #228) is normalized to this
# order, so ``User.role`` — the primary, the back-compat scalar every pre-#228 consumer
# reads — is always the highest tier the account holds (superadmin > admin > mod >
# user), then the grants. PERSON roles, not image roles: scripts/_roles-lib.sh and
# tests/scripts/test-role-key-spelling.sh carve this vocabulary OUT of their sweep.
USER_ROLE_CHOICES = ("superadmin", "admin", "mod", "user", "games", "games-services")
# The GRANTS: every USER_ROLE_CHOICES entry that is not one of the four tiers. Derived,
# so the two tuples cannot drift — a role is either an exclusive tier (the thing
# --person-role bakes into a device) or a grant that rides on top of one. The desktop-
# person dialog (gui/pages/_desktop_user_dialog.py) offers exactly these as checkboxes
# beside its tier picker (issue #228).
USER_GRANT_CHOICES = tuple(r for r in USER_ROLE_CHOICES if r not in PERSON_ROLE_CHOICES)


def normalize_user_roles(roles) -> list[str]:
    """Canonical multi-role list (issue #228): deduped, USER_ROLE_CHOICES order first
    (that order is the precedence), any role outside the vocabulary kept AFTER the
    known ones in input order (a saved config from a newer Studio is never silently
    stripped), blank entries dropped, and an empty set is the ``user`` floor — an
    account with no role at all is not a thing the manifest can provision."""
    seen: list[str] = []
    for r in roles or ():
        r = (r or "").strip() if isinstance(r, str) else ""
        if r and r not in seen:
            seen.append(r)
    known = [r for r in USER_ROLE_CHOICES if r in seen]
    extra = [r for r in seen if r not in USER_ROLE_CHOICES]
    return (known + extra) or ["user"]


def person_tier(roles) -> str:
    """The single --person-role tier a multi-role account maps to: the highest
    PERSON_ROLE_CHOICES tier it holds (normalize_user_roles order), ``user`` when it
    holds only grants (games/games-services) — the builder accepts exactly the four
    tiers, so a grant can never be emitted as a person role."""
    for r in normalize_user_roles(roles):
        if r in PERSON_ROLE_CHOICES:
            return r
    return "user"


X86_CLIENT_ROLES = ("laptop", "chromebook", "desktop")
# The cluster NODE roles (ROLE_CLIENT=false) — the roles for which the builder drops
# --person-role/--domains. Gating on "not a node role" (rather than "is a client role")
# also lets a standalone-desktop role carry them, exactly like the builder does.
X86_NODE_ROLES = ("pki", "backend", "frontend", "backend-gpu", "omnibus", "edge-ai")

# --release-state: cluster ingress + Layer-3 nftables posture baked into the image
# (build-x86:909 parses it, :3174 bakes /etc/hugmesh/release-state inside
# bake_host_firewall(); rpi5:1000). Only x86 + rpi5 parse it.
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
# ISSUE #226 ask 2 — "names are not self-explanatory". Every tier-1/2 row used to carry
# one identical caption ("Runs in-cluster unless pointed at a hosted endpoint"), which
# told the operator nothing about `federation-bundles` or `velero-objectstore`. One line
# per id saying WHAT IT IS, taken from specs/cluster/backing-services.yaml's displayName
# + consumers (the same file the hermetic test_managed_services.py pins this constant
# against). The shared "in-cluster unless…" sentence is NOT re-appended anywhere: the
# row's own Hosting dropdown reads "Self-hosted (in-cluster)" / "Managed (hosted
# endpoint)" and the group row above it carries the scope note, so this column is
# free to answer only "what is it" (network.py's backing-services loop).
MANAGED_SERVICE_DESCRIPTIONS: dict[str, str] = {
    "velero-objectstore": "Object store Velero writes the cluster's backups into "
                          "(managed = an S3 / Azure Blob bucket).",
    "smtp": "The relay the mesh submits outbound mail through — account mail and "
            "alerts. There is no in-mesh SMTP server; this records the choice.",
    "kafka": "Usage-event bus the BFFs publish to (managed = MSK / Event Hubs).",
    "clickhouse": "Analytics warehouse behind the admin dashboards and the "
                  "observability DSN (managed = ClickHouse Cloud).",
    "federation-bundles": "Object store holding the remote-app bundles the federation "
                          "API serves to other meshes (managed = an S3 bucket).",
    "postgres-admin-bff": "PostgreSQL database behind the admin BFF.",
    "postgres-user-bff": "PostgreSQL database behind the user BFF.",
    "postgres-mod-bff": "PostgreSQL database behind the moderation BFF.",
    "postgres-forum-bff": "PostgreSQL database behind the forum BFF.",
    "postgres-wiki-bff": "PostgreSQL database behind the wiki BFF.",
    "postgres-casdoor": "PostgreSQL database behind Casdoor, the mesh's identity "
                        "provider.",
}
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


# Mesh secrets store (issue #224): the HashiCorp Vault a cluster NODE seeds its
# External Secrets Operator from at first boot. The EMPTY address (the NATIVE
# DEFAULT) emits NOTHING — offline/USB-only secret delivery, argv/sysroot byte-
# identical to before the fields existed. A set address threads --vault-addr
# [--vault-external-addr] to the two node builders (build-x86-host-stage4.sh /
# build-rpi5-stage4.sh), which bake CONNECTION FACTS ONLY into
# /etc/hugmesh/vault.conf; keys-provision's provision_vault() reads that file
# whenever the KEYS manifest carries no .vault block (the manifest still wins).
# The token and unseal key are secrets the operator keeps themselves: they ride the KEYS stick
# (vault/token, vault/unseal-key), never a flag and never the image.
# The INTERNAL/EXTERNAL split (issue #335): ``vault_addr`` is the address a node
# reaches Vault at from INSIDE the mesh (the one that was always here, same key and
# same --vault-addr flag), ``vault_external_addr`` the same Vault as reached from
# OUTSIDE it (an operator laptop, a CI runner, a second site). The external one is
# OPTIONAL and OMIT-WHEN-EMPTY at every layer — argv, and the baked vault.conf line —
# so every pre-#335 flow keeps its bytes.
#
# WHERE the cluster reads is NOT a field here and there is no flag for it, because
# NEITHER HALF IS BRAND-DERIVED ON THE READER SIDE (issue #285; decision 22 on #347,
# operator 2026-09-16 "A: drop both controls"). ``vault_kv_mount`` /
# ``vault_base_path`` and the builders' --vault-kv-mount / --vault-base-path are
# REMOVED. They were validated, baked into vault.conf and logged at first boot, and
# read by nothing: the mount is pinned in the shipped ClusterSecretStore
# (specs/cluster/manifests/external-secrets/secretstore.yaml ``path: "secret"``),
# which ArgoCD serves with prune+selfHeal and re-applies from git on every reconcile,
# so no image-side value could ever re-point it; and the key prefix the
# ExternalSecrets read is the LITERAL ``hugmesh/<service>`` — all 143 remoteRef keys
# under specs/cluster spell it out, none templates the brand (measured 2026-09-16).
# The builders still WRITE both lines into vault.conf, now derived, with the base
# path set to the brand slug because that is the WRITER side
# (``BASE="${BRAND:-hugmesh}"`` in scripts/gen-cluster-secrets.sh). For a brand other
# than "hugmesh" writer and reader therefore DISAGREE; that gap pre-dates #285, which
# only removed two controls that changed nothing, and closing it is its own call.
# A config saved before this carries the two keys; ``from_dict`` drops unknown keys,
# so it loads with no residue and emits the same argv as one that never had them.
VAULT_FIELDS = ("vault_addr", "vault_external_addr")


def vault_field_error(addr: str, external_addr: str = "") -> str:
    """The ONE fail-closed rule for the vault fields, shared by validate_identity()
    (argv) and both faces' inline notes (GUI VaultPage / TUI VaultScreen): "" when
    the combination is valid, else a LAY-USER sentence.

    Empty INTERNAL address = the offline default, and it must carry NO residue (an
    external address with nowhere to point is a half-configured store, never
    silently ignored — the idp=casdoor precedent). A set address must be https://
    (the secrets channel's trust anchor).

    ``external_addr`` is keyword-last and defaults to "" on purpose, so a caller
    that knows only the internal address keeps working. It must be https:// for the
    same trust-anchor reason, and it must DIFFER from the internal one — one Vault
    reached at one address needs only the internal field, and two identical
    addresses are a copy/paste, not a split.

    The KV-mount / base-path arms this predicate used to carry are GONE with the
    fields themselves (#285, decision 22): the mount and the read prefix are both
    pinned by the shipped ClusterSecretStore and its ExternalSecrets, so there is no
    operator input left to check. The builders' mirrored
    ``_validate_vault`` was cut in the same shape, which is what keeps the two
    sides one rule rather than two."""
    if not addr:
        if external_addr:
            return ("external address set but no Vault address — clear "
                    "it, or enter the address it belongs to")
        return ""
    if not _IDP_URL_RE.fullmatch(addr):
        return ("the Vault address must be an https:// URL (letters, digits and "
                "._:/%=+- only) — it is the secrets channel's trust anchor")
    if external_addr:
        if not _IDP_URL_RE.fullmatch(external_addr):
            return ("the external Vault address must be an https:// URL (letters, "
                    "digits and ._:/%=+- only) — it is the same secrets channel")
        if external_addr == addr:
            return ("the external Vault address is the same as the internal one — "
                    "clear it; one address reached from everywhere needs no split")
    return ""


# ── base CA certificates (issue #335) ────────────────────────────────────────────
# The operator's own certificate authorities, added as PEM FILES on the Vault step
# and offered per domain on the Domains step (``ImageConfig.domain_ca``). These are
# RECORDED ONLY: no builder script parses a CA flag, nothing copies a PEM into an
# image, a trust store or a KEYS stick, and no manifest emitter carries the per-domain
# choice yet. Both faces say exactly that (the "recorded, not yet consumed" label the
# KV mount / base path already wear) rather than implying a wiring that does not
# exist — a GUI knob that silently does nothing is this repo's named failure mode.
#
# What IS real here is the CHECK: a file added to the list is parsed as a PEM
# certificate before it can be added, so the list cannot fill with files that are not
# certificates at all. Parsing is deliberately dependency-light: the BEGIN/END
# CERTIFICATE framing and the base64 body are decoded with the standard library, and
# the SUBJECT + EXPIRY are read only when python-cryptography happens to be installed
# (it is NOT a studio requirement — the urwid/TUI precedent: degrade, never hard-fail).
CA_CERT_MAX_BYTES = 1 << 20             # 1 MiB: a CA bundle is kilobytes; refuse a blob

#: WHERE A MESH DESKTOP CLIENT GETS ITS CERTIFICATE AUTHORITIES (#588). Cloud mode
#: keeps skipping the Secrets store step and keeps the Domains table's Base CA column
#: hidden, and says THIS on its Domains step instead (both faces render this one
#: string, parity-pinned), because the two alternatives were dead knobs measured on
#: the builders, not guessed:
#:
#: * ``bake_vault_conf`` (build-x86-host-stage4.sh) warns and RETURNS on a client role
#:   — "--vault-addr given for a client role ... ignoring" — so a Vault address offered
#:   to a client build is discarded by the builder;
#: * the per-domain Base CA is recorded-only everywhere (no builder parses a CA flag).
#:
#: What really decides a client's trust is keys-provision's certificate import
#: (specs/etc/keys-provision/provision.sh: every KEYS/certs/*.crt and *.pem copied to
#: /usr/local/share/ca-certificates, then update-ca-certificates) — mesh-wide, from
#: the stick, never per domain. THE ENGINE'S SIDE OF THIS SENTENCE IS ISSUE #588: as
#: merged in #645 the import was the tail of provision_files(), below that function's
#: `jqe '.files' || return 0`, so a client stick (KEYS profile `host`, whose manifest
#: has no `files` key) imported nothing and the note promised an import that did not
#: run. The engine fix — the import as its own step, provision_certs, called from
#: main() for every manifest, with executing pins (studio/tests/
#: test_keys_provision_certs.py) and the container and client-image proofs — lands in
#: the same change as this wording: the note is true of the engine only WITH that
#: change, so the two must not be separated. gen-provision-keys.sh does not mint the CA
#: for a client: it tells the operator to copy certs/cluster-ca.crt from the pki node
#: onto the stick, which is why the note says "the certificates you put there".
#: studio/tests/test_client_ca_inheritance.py pins the text facts against the
#: scripts, so this sentence goes red the day one of them changes.
CLIENT_CA_INHERITANCE_NOTE = (
    "Certificate authorities on a Mesh desktop client: the image carries none of its "
    "own, so there is no per-domain CA to pick here and the Secrets store step is "
    "skipped. At first boot keys-provision imports every certificate you put in the "
    "KEYS stick's certs/ folder (*.crt and *.pem — the mesh's cluster-ca.crt, which "
    "gen-provision-keys.sh tells you to copy there from the pki node, and any other "
    "CA) into the system trust store, so this client trusts exactly the certificate "
    "authorities on the stick you provision it with, for every domain it is tied to. "
    "(A Vault address would be ignored too: the builder drops --vault-addr on a "
    "client role — Vault/ESO seeding is a cluster-node first-boot step.)")
_PEM_CERT_RE = re.compile(
    r"-----BEGIN CERTIFICATE-----\s*(?P<body>[A-Za-z0-9+/=\s]+?)\s*"
    r"-----END CERTIFICATE-----")


def _pem_der_blocks(text: str) -> list[bytes]:
    """Every decodable DER body in a PEM text, in file order ([] = none)."""
    out: list[bytes] = []
    for m in _PEM_CERT_RE.finditer(text):
        try:
            der = base64.b64decode("".join(m.group("body").split()), validate=True)
        except (binascii.Error, ValueError):
            continue
        if der:
            out.append(der)
    return out


def _der_parse_error(der: bytes) -> str:
    """"" when ``der`` really is an X.509 certificate — AND "" when python-cryptography
    is not installed, because then nobody here can tell. Otherwise the failing
    exception's type name.

    This is the DEPTH knob on :func:`ca_cert_error`. PEM framing plus a decodable
    base64 body is NOT proof of a certificate: a file holding BEGIN CERTIFICATE over
    ``aGVsbG8gd29ybGQ=`` ("hello world") passes both and is not one. With the optional
    wheel present we parse for real and refuse that; without it the stdlib framing
    check stands alone and we accept — the urwid precedent (degrade, never hard-fail,
    and never refuse what this host cannot actually disprove)."""
    try:
        from cryptography import x509                      # optional, see docstring
    except ImportError:
        return ""
    try:
        x509.load_der_x509_certificate(der)
    except Exception as exc:                               # noqa: BLE001 - any parse failure
        return type(exc).__name__
    return ""


def ca_cert_error(path: str) -> str:
    """The ONE fail-closed rule for ONE base CA certificate file: "" when the file is
    a PEM certificate, else a LAY-USER sentence naming what is wrong.

    Shared by the GUI picker, the TUI ``ca`` command and validate_identity, so what
    one face refuses every face refuses. Reads at most CA_CERT_MAX_BYTES; a directory,
    an unreadable file, a DER-only .crt and a PEM PRIVATE KEY are all named for what
    they are rather than lumped into one 'invalid file'.

    HOW MUCH "" ACTUALLY PROMISES depends on the host: BEGIN/END framing and a
    decodable base64 body always, plus a real X.509 parse when python-cryptography is
    importable (see :func:`_der_parse_error`). Without that optional wheel a
    well-framed non-certificate is accepted, and the row then reads "could not read
    its fields" instead — honest, but weaker. It is never a TRUST decision either
    way: nothing here copies the PEM into an image."""
    if not path:
        return "no certificate file given"
    if not os.path.isfile(path):
        return (f"{os.path.basename(path) or path}: not a readable file "
                "(moved, or a directory)")
    try:
        size = os.path.getsize(path)
        if size > CA_CERT_MAX_BYTES:
            return (f"{os.path.basename(path)}: {size} bytes is too large for a CA "
                    f"certificate (limit {CA_CERT_MAX_BYTES})")
        with open(path, "rb") as fh:
            raw = fh.read(CA_CERT_MAX_BYTES + 1)
    except OSError as exc:
        return f"{os.path.basename(path)}: cannot read it ({exc.strerror or exc})"
    text = raw.decode("utf-8", "replace")
    blocks = _pem_der_blocks(text)
    if blocks:
        why = _der_parse_error(blocks[0])
        if why:
            return (f"{os.path.basename(path)}: its BEGIN CERTIFICATE block decodes, "
                    f"but what comes out is not an X.509 certificate ({why}) — the "
                    "file is corrupted, or is some other PEM renamed .pem/.crt")
        return ""
    if "-----BEGIN CERTIFICATE-----" in text:
        return (f"{os.path.basename(path)}: has a BEGIN CERTIFICATE line but its "
                "body is not valid base64 — the file looks truncated or edited")
    if "-----BEGIN" in text and "PRIVATE KEY" in text:
        return (f"{os.path.basename(path)}: this is a PRIVATE KEY, not a certificate "
                "— never add a key here; pick the CA's public .pem/.crt")
    return (f"{os.path.basename(path)}: no -----BEGIN CERTIFICATE----- block "
            "(a DER/.der or PKCS#12 file needs converting to PEM first)")


def describe_ca_cert(path: str) -> str:
    """A one-line 'subject · expires YYYY-MM-DD' for a PEM the caller already checked
    with :func:`ca_cert_error`, or a short honest stand-in when it cannot be read.

    python-cryptography is OPTIONAL (not in studio/requirements.txt): without it the
    PEM is still structurally verified and the line says so instead of guessing."""
    try:
        with open(path, "rb") as fh:
            blocks = _pem_der_blocks(fh.read(CA_CERT_MAX_BYTES + 1)
                                     .decode("utf-8", "replace"))
    except OSError:
        return "unreadable"
    if not blocks:
        return "not a PEM certificate"
    extra = f" (+{len(blocks) - 1} more in file)" if len(blocks) > 1 else ""
    try:
        from cryptography import x509                      # optional, see docstring
    except ImportError:
        return f"PEM certificate, {len(blocks[0])} bytes DER{extra} " \
               "(install python-cryptography to show subject and expiry)"
    try:
        cert = x509.load_der_x509_certificate(blocks[0])
        subject = cert.subject.rfc4514_string()
        # not_valid_after_utc is cryptography >= 42; the naive not_valid_after is the
        # spelling before that and is deprecated after it. Try the current one first
        # and fall back, so a host with an older wheel shows the date rather than the
        # "could not read its fields" line (which would be true but unhelpful).
        after = getattr(cert, "not_valid_after_utc", None) or cert.not_valid_after
        expiry = after.date().isoformat()
    except Exception as exc:                               # noqa: BLE001 - any parse failure
        return f"PEM certificate; could not read its fields ({type(exc).__name__}){extra}"
    return f"{subject} · expires {expiry}{extra}"


def base_ca_certs_error(paths: Sequence[str], *, check_readable: bool = True) -> str:
    """"" when every listed base CA certificate is a readable PEM and the list has no
    duplicates, else the FIRST problem as a lay sentence. The empty list (the native
    default) is valid and emits nothing anywhere.

    ``check_readable=False`` keeps the STRUCTURAL rules (a non-string entry, a
    duplicate) and drops the on-disk ones. That is the split validate_identity needs:
    a duplicate is wrong on every machine and at every hour, while "this PEM is not
    readable right now" is a fact about THIS host at THIS moment. base_ca_certs
    reaches no argv, no image and no manifest, so an unreadable path must never be
    able to block a build that does not depend on it — a config carrying CA paths has
    to stay portable between machines, and a headless / --print-command operator has
    no repair UI. The two faces call this WITH the readability check and say so
    inline, which is where an operator can actually act on it."""
    seen: set[str] = set()
    for p in paths:
        if not isinstance(p, str):
            return f"base CA certificate list holds a {type(p).__name__}, not a path"
        if p in seen:
            return f"{os.path.basename(p)} is listed twice — remove the duplicate"
        seen.add(p)
        if check_readable:
            err = ca_cert_error(p)
            if err:
                return err
    return ""


def domain_ca_error(domain_ca: Mapping[str, str], base_ca_certs: Sequence[str]) -> str:
    """"" when every per-domain base-CA choice names a certificate the config actually
    carries, else a lay sentence. A domain with NO entry (the default, and every
    pre-#335 config) is valid: absent == "whatever the mesh already trusts"."""
    listed = set(base_ca_certs)
    for dom, cert in domain_ca.items():
        if not isinstance(dom, str) or not isinstance(cert, str):
            return "the per-domain base CA table must map a domain name to a path"
        if not cert:
            continue                    # explicit "none" is the same as absent
        if cert not in listed:
            return (f"domain {dom} names base CA {os.path.basename(cert)}, which is "
                    "not in the certificate list — add the PEM back, or clear the "
                    "domain's choice")
    return ""


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
# The Orange Pi boards with cluster NODE roles (EXPERIMENTAL): their builders parse the
# mesh's cluster choices (release state, games domain, optional services, IdP, Vault)
# for a NODE role only and refuse them on the desktop, so those fields are in scope
# there for the node class only (_OPI_NODE_CLASS_FIELDS below).
_OPI_NODE_PLATFORMS = ("orangepi5", "orangepi4-lts")
_X86_RPI5_OPI = _X86_RPI5 + _OPI_NODE_PLATFORMS

# The builders whose MEDIA is chosen by --flavor (live | installer | both; default
# "both") instead of by per-artifact ISO flags. Named once here because TWO separate
# facts hang off exactly this family, and the Review page states both:
#
#   * they DO build an installer ISO by default — build-frite-stage4.sh:573 sets
#     BUILD_INSTALLER=true for --flavor both, :2557 calls build_installer_iso(), :2540
#     names <prefix>.installer.iso; the six orangepi* builders are byte-parallel. So
#     "this builder produces no installer ISO" is FALSE for them (it is true only for
#     jetson, which contains no installer.iso at all), and the greyed --installer-iso
#     row must point at the Flavor control instead of denying the artifact exists;
#   * their --compress compresses LIVE_PATH and INSTALLER_PATH and never an .img
#     (frite:2438 + :2547), the exact INVERSE of x86/rpi5/jetson, whose --compress
#     compresses IMG_PATH only (x86:6757, rpi5:4654, jetson:2414).
#
# Pinned to real emission by tests/test_cli_args.py::test_flavor_media_platforms_are_
# exactly_the_flavor_emitting_builders, so it cannot drift from to_cli_args().
FLAVOR_MEDIA_PLATFORMS = ("frite", "orangepi5", "orangepizero2", "orangepizero2w",
                          "orangepizero3", "orangepi3-lts", "orangepi4-lts")

_FIELD_PLATFORMS: dict[str, tuple[str, ...]] = {
    # brand plane — every builder parses these identically (x86 unaffiliated suppresses).
    "brand": _ALL_PLATFORMS, "brand_title": _ALL_PLATFORMS, "org": _ALL_PLATFORMS,
    "brand_profile": _ALL_PLATFORMS,
    # host identity (-H/-T/-u) — all builders.
    "hostname": _ALL_PLATFORMS, "timezone": _ALL_PLATFORMS, "user": _ALL_PLATFORMS,
    # cluster / mesh identity.
    "cluster_domain": _ALL_PLATFORMS, "games_domain": _X86_RPI5_OPI, "release_state": _X86_RPI5_OPI,
    "person_role": _X86, "domains": _X86,
    # Tailscale root domain — every builder parses --superdomain (WS-SUPER-B bake);
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
    "idp": _X86_RPI5_OPI, "idp_issuer": _X86_RPI5_OPI, "idp_client_id": _X86_RPI5_OPI,
    "idp_jwks": _X86_RPI5_OPI,
    # mesh secrets store (#224) — the two node builders bake /etc/hugmesh/vault.conf;
    # the empty address emits nothing (byte-identity), so the probe supplies one.
    # vault_external_addr (#335) rides the same two builders and the same rule.
    # base_ca_certs / domain_ca are ABSENT on purpose: they emit no flag anywhere, so
    # a capability-table entry would claim a builder surface that does not exist.
    "vault_addr": _X86_RPI5_OPI, "vault_external_addr": _X86_RPI5_OPI,
    # tor / character-studio / character-forge / services.
    "tor_onion_service": _X86, "character_studio": _X86_RPI5,
    "character_forge": _X86_RPI5,
    "optional_services": _X86_RPI5_OPI, "exclude_services": _X86_RPI5_OPI,
    "enable_games": _X86_RPI5_OPI, "anubis": _X86_RPI5_OPI,
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
    "compress_level": _ALL_PLATFORMS, "resume": _ALL_PLATFORMS,
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
                   "login_theme_preset", "login_theme_mode",
                   # the Themes editor's web-chrome half (#50 item 2): same channel as
                   # the login_* colours — SNAP_THEME_CSS token text, never argv.
                   "login_header_hidden", "login_header_size", "login_header_bg",
                   "login_header_text",
                   "login_footer_hidden", "login_footer_size", "login_footer_bg",
                   "login_footer_text",
                   "login_bg_effect",
                   # #654: the superbrand's shape/decoration ride the same channel,
                   # and the brand record is a Studio-side path until the builders
                   # parse --brand-record (see ImageConfig.brand_record).
                   "login_style", "login_decor", "brand_record",
                   "additional_domains", "configure_users", "qemu_device_tests",
                   # #495: which domains have been through their Services page. Pure
                   # wizard-flow bookkeeping for the build/mesh-start gate — saved with
                   # the config so re-opening one you already configured does not
                   # refuse, and emitted nowhere.
                   "domain_services_reviewed")


# ── role-class capability layer (Qt-free; BESIDE PLATFORM_FIELD_SUPPORT, NEVER inside
# to_cli_args — invariant I3) ─────────────────────────────────────────────────────────
# A SECOND gating axis on top of the platform axis: whether an image is a person DESKTOP
# (themeable, home-provisionable, tailnet/SSO-optional) or a cluster NODE / headless
# appliance (root-encrypted infrastructure — no theming, no home provisioning, mesh join
# implicit). Keyed on the role id (a shared id like pki/edge-ai is a node on EVERY
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
# rpi5-desktop / jetson-desktop are the two COMPOSITE ids (a platform mangled into
# the role string) that survive this change; see RPI5_ROLE_MAP above.
_ARM_DESKTOP_ROLES = ("rpi5-desktop", "jetson-desktop", "frite", "orangepi5", "orangepi4-lts")
# The Studio role ids that are cluster NODE roles on the Orange Pi node-axis boards
# (orangepi5: pki/backend/frontend/omnibus; orangepi4-lts: frontend). Their desktop
# keeps the board id as its role id ("orangepi5"/"orangepi4-lts"), unchanged.
_ORANGEPI_NODE_ROLE_IDS = ("pki", "backend", "frontend", "omnibus")
# The cluster-choice fields an Orange Pi NODE role emits (_orangepi_node_cluster_args)
# and its DESKTOP does not: node-class only on _OPI_NODE_PLATFORMS (FIELD_SCOPE).
_OPI_NODE_CLASS_FIELDS = ("games_domain", "release_state", "idp", "idp_issuer",
                          "idp_client_id", "idp_jwks", "vault_addr", "vault_external_addr",
                          "optional_services", "exclude_services", "enable_games", "anubis")
DESKTOP_ROLES = X86_CLIENT_ROLES + _STANDALONE_DESKTOP_ROLES + _ARM_DESKTOP_ROLES
# Cluster-node / headless-appliance family (root-encrypted infra). X86_NODE_ROLES already
# covers pki/backend/frontend/backend-gpu/omnibus/edge-ai (x86 AND rpi5 share
# pki/backend/frontend; backend-gpu, omnibus and edge-ai are shared x86/jetson — the
# jetson-only `full`/`gpu-host` ids were the same two roles under two more names);
# the orangepizero2 appliance and the plain-Gentoo
# rpi5 "generic" server are headless nodes too. Everything not an explicit desktop role
# is treated as a node (fail-safe: infra never accidentally exposes theming/home surfaces).
# Empty by construction now: the jetson node roles ARE backend-gpu / omnibus /
# edge-ai, every one of which X86_NODE_ROLES already lists. Kept as a named, empty
# tuple rather than deleted so the merge stays visible — jetson used to add two more
# names (`full`, `gpu-host`) for two roles that already had names.
_JETSON_NODE_ROLES = ()
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
    ``${STANDALONE}``. Only two of the four do (INSTALLER_UI :1619, BUNDLE_SOURCE :1623).
    GPU_DRIVER :1517 forks on ``${GPU}`` and HOME_MODE :1602 on
    ``[ -n "${INCLUDE_HOME_ARCHIVE}" ]``. A ``when_standalone`` field would therefore have
    recorded a fiction for half the table, and GUARD A could only ever have checked the
    variable NAMES. Carrying the fork ``condition`` verbatim instead lets the guard pin the
    whole sentinel — name, condition and both arms — so a builder-side edit to any part of
    it fails.

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
      * build-rpi5-stage4.sh:1302  — ${ROLE_CLIENT} || err ...; exit 1 -> class rule is real
      * build-frite / -orangepi5 / -orangepi-zero2-stage4.sh
                                   — ZERO occurrences of ROLE_CLIENT or ROLE_K8S. They
                                     compose ${STANDALONE} unconditionally, and
                                     build-orangepi-zero2-stage4.sh:301-310 documents
                                     --standalone as a posture this image composes.

    The orangepizero2 role IS node-class (a headless appliance) AND its defining posture is
    --standalone; ROLE_CHOICES calls it a "standalone HEADLESS APPLIANCE". A flat
    classes=("desktop",) therefore HID the checkbox on that flow and force-cleared the value
    — a silently non-standalone, non-FDE image where an FDE appliance was asked for. So the
    class axis carries the platforms it is TRUE on: None means "everywhere" (the common
    case), a tuple means the narrowing applies only on those builders and every other
    platform stays fully open. GUARD B cannot catch this — it pins image_class to the x86
    builder, which is exactly the builder that does not govern orangepizero2.

    ``mode_platforms`` is the EXACT TWIN of that carrier for the MODE axis, and it exists
    for the same reason: a field's mode rule can be true on one builder and false on
    another. The cluster-identity trio is the measured case (2026-08-26, operator report
    "There should also be no inbetween menu for configuring domain"):

      * ``_x86_args`` (:3518; the mode fork at :3564-3574) emits --cluster-domain /
        --games-domain / --release-state ONLY under ``mode in ("cloud", "mesh")`` -> on x86
        the mode rule is real;
      * ``_arm_common_args`` (:3128; the unconditional --cluster-domain at :3139) emits it
        in EVERY mode and is shared by all NINE arm64 builder methods (call sites at :3213
        rpi5, :3271, :3287, :3304, :3323, :3343, :3370, :3389, :3428 jetson), and
        build-rpi5-stage4.sh:3386 bakes ${CLUSTER_DOMAIN} into /etc/hugmesh/cluster-domain
        with no role or mode fork at all. A standalone rpi5 'generic' image GENUINELY
        carries a cluster domain.

    A blanket ``modes=("cloud","mesh")`` would therefore have hidden a widget whose value
    the ARM builders really do take, and (via the clear that leaves the output unchanged the wizard pairs
    with every hide) silently reset it to "hugmesh.net" on an operator who had typed
    something else. Same shape of bug as the orangepizero2 --standalone regression above,
    on the other axis. None means "the mode rule holds everywhere"; a tuple means it holds
    ONLY on those builders and every other platform stays fully open."""
    platforms: tuple[str, ...] = _ALL_PLATFORMS
    classes: tuple[str, ...] = _ALL_CLASSES
    modes: tuple[str, ...] = _ALL_MODES
    builder_default: "BuilderDefault | None" = None
    class_platforms: "tuple[str, ...] | None" = None
    mode_platforms: "tuple[str, ...] | None" = None


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
# and asserts equality, so a builder that grows or loses a role-class concept fails here
# rather than letting the tuple go stale into a fiction.
# The two Orange Pi node-axis builders joined on 2026-10-21: their node roles refuse
# --standalone (a cluster node joins the mesh) while their desktop composes it, exactly
# the rpi5 split, and they now carry ROLE_CLIENT for it.
_STANDALONE_CLASS_GATED_PLATFORMS = ("x86", "rpi5", "orangepi5", "orangepi4-lts")

# The CLUSTER-IDENTITY trio — the three fields NetworkPage's "Identity & domain"
# collapsible collects (network.py:494/:499/:504: "Public apex domain", "Games domain",
# "Release state"). Declared as ONE tuple because they are ONE question to the operator
# and one predicate answers for all of them (cluster_identity_applies), not because they
# share a platform axis — they do not: --cluster-domain is parsed by all TEN builder
# scripts (verified: every build-*-stage4.sh has exactly one `--cluster-domain|--domain)`
# arm), --games-domain / --release-state by x86 + rpi5 only.
_CLUSTER_IDENTITY_FIELDS = ("cluster_domain", "games_domain", "release_state")

# The modes in which the cluster plane is baked AT ALL, and the builders on which that
# rule is true. Transcribed from the emitters, not from intent:
#   _x86_args:3582        if self.mode in ("cloud", "mesh"):  -> the trio is inside it
#   _arm_common_args:3157 --cluster-domain, unconditional     -> no mode fork on ARM
#   _rpi5_args:3236-3238  --release-state / --games-domain    -> also unconditional
# so the narrowing is x86-ONLY. See FieldScope.mode_platforms for the regression this
# shape prevents (a blanket mode key would hide + clear a domain the ARM builders bake).
_CLUSTER_PLANE_MODES = ("cloud", "mesh")
_CLUSTER_PLANE_MODE_GATED_PLATFORMS = ("x86",)

# Role-class / mode narrowings. Entries here either restate a rule the codebase ALREADY
# enforces elsewhere — a test pins each to the predicate that owns it so the two cannot
# disagree — or carry an enforcement landing in the SAME commit:
#   * THEME_FIELDS       -> branding_allowed()      (desktop-class, any mode)
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
    # The mesh's cluster choices on the Orange Pi node boards: a NODE role bakes them,
    # the Orange Pi DESKTOP bakes no cluster tree and its builder refuses the flags. The
    # class rule applies on those two builders only (x86/rpi5 keep their own rules).
    **{f: FieldScope(platforms=_FIELD_PLATFORMS[f], classes=("node",),
                     class_platforms=_OPI_NODE_PLATFORMS)
       for f in _OPI_NODE_CLASS_FIELDS},
    **{f: FieldScope(platforms=_FIELD_PLATFORMS[f], classes=("desktop",))
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
    # the same worklist hard-errors at build-rpi5-stage4.sh:1046, after dispatch.
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
    # truth, and it invented a constraint: build-rpi5-stage4.sh:1046 gates --standalone on
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
    #   build-x86-host-stage4.sh:4255  if ! ${ROLE_CLIENT} && [ -n "${EGRESS_VPN_FILE}" ]; then
    #                          :4494      warn "--egress-vpn given for a non-desktop role
    #                                      (${ROLE}); ... — ignoring."
    # HISTORY — why this scope entry exists, and what is no longer true. When it was written
    # (#387) "ignoring" was only HALF true: the STAGING leg was role-gated but the PACKAGE leg
    # (`if [ -n "${EGRESS_VPN_FILE}" ]` — net-vpn/wireguard-tools, or networkmanager-openvpn +
    # openvpn for a .ovpn) was NOT, so a node still emerged the VPN userspace it was just told
    # it would not use. That leg is now gated on the SAME ROLE_CLIENT condition (:5123), so the
    # builder no longer contradicts itself. The old note ALSO named the CONFIG_WIREGUARD kernel
    # fragment as ungated — that was wrong when written: the fragment has always sat INSIDE the
    # `if ${ROLE_CLIENT}` kernel arm (:5895, verified back to #189, the commit that added it).
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
    # weight on a headless PKI/backend node. The builder says so itself at :1623
    # (`[ -z "${BUNDLE_SOURCE}" ] && { ${STANDALONE} && BUNDLE_SOURCE=true || … }`).
    "bundle_source": FieldScope(platforms=_FIELD_PLATFORMS["bundle_source"],
                                classes=("desktop",), builder_default=_BD_BUNDLE_SOURCE),
    # Cluster identity (--cluster-domain / --games-domain / --release-state): a MODE
    # narrowing that is TRUE ON x86 ONLY. Enforcement lands with the declaration —
    # cluster_identity_applies() reads it and NetworkPage gates the "Identity & domain"
    # collapsible on that, closing the operator's 2026-08-26 report ("There should also be
    # no inbetween menu for configuring domain" on the standalone flow; the image was
    # role=standalone-unaffiliated / platform=x86, session 20260826-151356-64070a).
    #
    # NO CLASS AXIS, deliberately: --cluster-domain is baked for every mesh NODE and every
    # CLIENT alike (_x86_args:3582-3584 emits it outside the `role not in X86_NODE_ROLES`
    # gate that --person-role/--domains sit behind), so a class rule here would be an
    # invented constraint of exactly the kind FieldScope's docstring warns about.
    # ...EXCEPT on the Orange Pi node boards, where --games-domain / --release-state are
    # parsed for a NODE role only (the Orange Pi desktop refuses them): there the class
    # rule is real, so it rides class_platforms exactly like _OPI_NODE_CLASS_FIELDS above.
    **{f: FieldScope(platforms=_FIELD_PLATFORMS[f], modes=_CLUSTER_PLANE_MODES,
                     mode_platforms=_CLUSTER_PLANE_MODE_GATED_PLATFORMS,
                     **({"classes": ("node",), "class_platforms": _OPI_NODE_PLATFORMS}
                        if f in _OPI_NODE_CLASS_FIELDS else {}))
       for f in _CLUSTER_IDENTITY_FIELDS},
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
    Studio/menu selection can never dead-end in that hard-error (honesty rule). A node
    role whose RAM floor a board is never sold with is kept off that board too: omnibus
    (16 GB) is offered on rpi5 only, because a Pi 4 has 8 GB at most and the builder
    refuses it (roles.board_fits_role)."""
    if image_class("", role) == "desktop":
        return RPI_BOARDS
    return tuple(b for b in RPI_NODE_BOARDS if roles.board_fits_role(role, b))


def orangepi_flavors_for_role(platform: str, role: str) -> tuple[str, ...]:
    """The --flavor choices to OFFER for an Orange Pi node-axis board (orangepi5 /
    orangepi4-lts) and ``role``. A cluster NODE role is INSTALLER-only: the live flavor
    runs from RAM with no persistence, and build-orangepi5-stage4.sh /
    build-orangepi4-lts-stage4.sh refuse ``--flavor live|both`` for a node. The
    desktop keeps every flavor. Same honesty rule as rpi_boards_for_role: a picker
    never offers a combination the builder hard-errors."""
    flavors = {"orangepi5": ORANGEPI5_FLAVORS, "orangepi4-lts": ORANGEPI4LTS_FLAVORS}[platform]
    return ("installer",) if role in _ORANGEPI_NODE_ROLE_IDS else flavors


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
      the 16 inventory entries that never existed).
    """
    if role in X86_CLIENT_ROLES:
        return ("thin", "full")
    if role == "standalone-thin":
        return ("thin",)
    if role in ("standalone-thick", UNAFFILIATED_ROLE):
        return ("full",)
    return ()


def role_presets_standalone(role: str) -> bool:
    """Does ``role``'s own builder arm already set STANDALONE=true?

    The x86 standalone-* desktop roles ARE the standalone posture — the builder's role
    case sets it for them (build-x86-host-stage4.sh: the standalone-thin arm, the
    standalone-thick|standalone-full arm, and the standalone-unaffiliated arm each
    assign ``STANDALONE=true``), so ``--standalone`` on those roles is a no-op.

    Named here rather than spelled in a page (house rule: no second, page-local
    implementation of an axis rule). gui/pages/role.py uses it to HIDE the "Image
    posture" box on those roles — the operator's 2026-08-26 report is that the wizard
    "is asking same questions seemingly multiple times", and a tick box whose value the
    chosen image type already decided is exactly that: one question, two screens' worth
    of asking, one legal answer.

    NOT a general "hide what the role implies" rule. ``--standalone`` genuinely COMPOSES
    onto chromebook-in-standalone and onto every ARM appliance role, and those keep the
    box; this predicate is False for them."""
    return role in _STANDALONE_DESKTOP_ROLES


def role_presets_capable(role: str) -> bool:
    """Does ``role``'s own builder arm already set CAPABLE=true?

    DERIVED, not restated: it is the standalone-desktop role whose pinned desktop weight
    is "full". That mirrors the builder's own structure — ``CAPABLE=true`` appears only
    on the two arms that also pin ``DESKTOP="full"`` (standalone-thick|standalone-full
    and standalone-unaffiliated) and never on the thin arm, which is why
    standalone-thin KEEPS its --capable tick: that is the composition G21 exists for.

    The coupling ("capable iff the weight is pinned to full") is an INFERENCE from the
    builder's role case, true today and the reason this is expressed through
    x86_desktop_axis rather than as a third hand-written role list — if the builder ever
    pins a weight without CAPABLE, the axis table is the one place that has to change."""
    return role in _STANDALONE_DESKTOP_ROLES and x86_desktop_axis(role) == ("full",)


def branding_allowed(cfg: "ImageConfig") -> bool:
    """Desktop theming is offered on desktop-class images in ANY mode (operator ask,
    2026-08-14 — supersedes spec 2's never-in-mesh). A mesh WORKLIST has no single
    role, so this stays False for the mesh flow cfg itself; BrandingPage extends the
    gate to "the worklist carries a desktop-class x86 entry", and materialize()'s
    per-entry clear_role_class_fields keeps the theme off every node entry."""
    return image_class(cfg.mode, cfg.role) == "desktop"


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


def unaffiliated_image(cfg) -> bool:
    """Is THIS image unaffiliated — the dedicated ``standalone-unaffiliated`` role id, OR
    the composable ``--unaffiliated`` flag on any other x86 client role (G22)?

    THE CONTRACT gui/pages/branding.py:134-146 filed for this lane, honoured here so the axis
    rule has ONE implementation. Their note records why it had to exist at all: before it,
    ``BrandingPage.applies_to`` tested ``role == UNAFFILIATED_ROLE or cfg.unaffiliated``
    while ``initializePage``/``validatePage`` tested ONLY the role, so
    ``role="standalone-thick", unaffiliated=True`` rendered the page fully live for a
    config whose ``to_cli_args()`` raises. ``_x86_args`` had a THIRD copy of the same
    expression inline (the one that decides whether to run the conflict check and suppress
    the brand plane); it now calls this, so the emitter and the wizard cannot disagree
    about what "unaffiliated" means.

    Tolerant ``getattr``: pages hand this ImageConfigs, ``ImageAxes`` shims and worklist
    rows alike, and a shim carrying neither attribute is simply not unaffiliated.

    NO PLATFORM AXIS on purpose, even though ``--unaffiliated`` is x86-only in emission
    (PLATFORM_FIELD_SUPPORT["unaffiliated"] == ("x86",), pinned by
    test_g22/test_platform_field_support_unaffiliated_is_x86_only). The question here is
    "did the operator ask for an unaffiliated image", which is answered before the
    platform gate strips the flag — mixing the two would make the predicate say "no" for
    a config that is mid-switch between platforms and quietly re-enable the brand plane
    on it."""
    return bool(getattr(cfg, "role", "") == UNAFFILIATED_ROLE
                or getattr(cfg, "unaffiliated", False))


def cluster_identity_applies(cfg: "ImageConfig") -> bool:
    """Does the CLUSTER-IDENTITY surface — NetworkPage's "Identity & domain" collapsible
    (network.py:494/:499/:504: "Public apex domain" / "Games domain" / "Release state") — apply
    to THIS image? Signature: ``cluster_identity_applies(cfg: ImageConfig) -> bool``,
    reading ONLY ``cfg.platform`` and ``cfg.mode`` (so an ``ImageAxes`` shim satisfies it
    like every other predicate in this module).

    THE QUESTION IT ANSWERS is deliberately narrow: "are --cluster-domain /
    --games-domain / --release-state actually EMITTED for this image". Not "does this
    image have a domain", not "is this a mesh". Emission is the only thing a widget gate
    may key on, because the wizard's hide contract leaves the output unchanged — a hidden field
    is cleared to its dataclass default in validatePage, so hiding a field that IS emitted
    silently changes the built image.

    Operator report, 2026-08-26, verbatim: "There should also be no inbetween menu for
    configuring domain" on the standalone flow. Measured: their image is
    role=standalone-unaffiliated / platform=x86 (session 20260826-151356-64070a,
    out/sessions/.../build-standalone-unaffiliated.x86.log), and the "Identity & domain"
    group was the ONLY mode-ungated group left on NetworkPage — the static
    MODE_SKIPPED_PAGES["standalone"] skip already removes the domains_choice/domains
    PAGES, so this group was the whole of the leak.

    IT IS A FUNCTION OF (platform, mode), NOT MODE ALONE — this is the entire subtlety and
    the reason the answer is not a two-line `cfg.mode in ("cloud","mesh")`:

      * x86:  _x86_args:3582 wraps all three flags in ``if self.mode in ("cloud","mesh")``.
      * ARM:  _arm_common_args:3156-3157 emits --cluster-domain in EVERY mode, and is
              shared by all NINE arm64 builder methods; build-rpi5-stage4.sh:3386 writes
              ${CLUSTER_DOMAIN} to /etc/hugmesh/cluster-domain with no mode or role fork,
              and _rpi5_args:3236-3238 emits --release-state/--games-domain unconditionally
              too. A standalone rpi5 'generic' appliance genuinely carries a cluster
              domain, so a blanket mode-keyed answer would hide a live flag AND (via the
              paired clear) reset a typed domain to "hugmesh.net" behind the operator.

    NO SECOND IMPLEMENTATION OF THE AXIS RULE: the rule is DECLARED in FIELD_SCOPE
    (``modes=_CLUSTER_PLANE_MODES`` + ``mode_platforms=("x86",)``) and this predicate just
    composes ``field_in_scope`` over the trio, so the wizard gate, the Qt-free
    ``--config`` validator and ``_gating.scope_allows`` cannot drift apart from each other
    or from this function. ``any`` rather than ``all`` is the honest quantifier: on frite/
    jetson/orangepi* only --cluster-domain is parsed at all (--games-domain/--release-state
    are _X86_RPI5), yet that one flag IS baked, so the group must be shown — its two
    x86+rpi5 rows stay greyed there by NetworkPage's existing platform gate
    (gate_widgets, network.py:1429-1432), which is a different axis and already correct."""
    return any(field_in_scope(f, cfg) for f in _CLUSTER_IDENTITY_FIELDS)


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
    build-rpi5-stage4.sh:1007 sets ROLE_CLIENT=true for exactly that arm. A mode axis
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
    narrowing of its own: build-x86-host-stage4.sh:1912 honours --local-user on EVERY role
    (its guard is `${STANDALONE} || [ -n "${LOCAL_USER}" ] || [ -n "${LOCAL_USER_PASS}" ]`,
    with no role test in it; :1733 overrides DEFAULT_USER), so narrowing the FIELD would invent a builder
    constraint that does not exist. This is a WIZARD-surface rule of the same family as
    ``home_options_allowed``: it hides a group, and emission stays byte-identical because
    ``local_user`` keeps its dataclass default (``default_local_user()``, the invoking
    user, still emitted as --local-user on every x86 build)
    while ``local_pass`` is empty by default — see HomePage.validatePage, which
    collects the secret only while the surface applies."""
    return (image_class(cfg.mode, cfg.role) == "desktop"
            or field_in_scope("standalone", cfg))


def external_media_applies(cfg: "ImageConfig") -> bool:
    """Whether the external media-data device group (Steam library + gocryptfs Vaults)
    applies to THIS image.

    Same evidence shape as ``egress_vpn``'s role-class narrowing, which is why it gets a
    predicate rather than a shrug: the x86 builder half-honours the option on a node.
    ``build-x86-host-stage4.sh:1736`` role-gates the STEAM leg
    (``${ROLE_CLIENT} && ${MEDIA_DATA}``). HISTORY, re-verified 2026-08-26 rather than
    copied forward: when this predicate was written the media-detect STAGING leg and the
    ``packages-media-data.list`` PACKAGE leg were NOT role-gated, so a headless PKI node
    emerged a Steam/Vaults media stack it has no session to use. The builder has since
    closed both — staging now sits inside the ``if ${ROLE_CLIENT}`` service/desktop arm
    (:4658, the ``if ${MEDIA_DATA}`` at :4695) and the package leg inside the ROLE_CLIENT
    PKG_LISTS arm (:5070, the list append at :5084-5085). The predicate STAYS: with every
    leg role-gated, offering the group on a node class can only produce flags the builder
    ignores. It was reachable on every mesh node
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

    ALL, not ANY, and that is the choice that matters. These surfaces live on the SHARED
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
    own cluster domain"). Unchanged-output rule is preserved by NetworkPage.validatePage,
    which CLEARS cfg.domains/cfg.users whenever the opt-in is off — so a skipped table
    can never leave rows behind for mesh_manifest() to publish. See the ask-8 note in
    gui/pages/network.py.

    The CLOUD arm is deliberately untouched: a cloud desktop client's Domains/Users step
    carries the FD-08 --domains + --person-role tie the image is literally built around
    (build-x86-host-stage4.sh:4356-4357), which is not an "additional" domain at all."""
    if cfg.mode == "mesh":
        return bool(cfg.additional_domains)
    if cfg.mode == "cloud":
        return cfg.role not in X86_NODE_ROLES
    return False


def effective_domain_note(cfg: "ImageConfig") -> str:
    """Plain-language description of the domains a mesh serves WITHOUT adding any (ask
    19's default card). Names both real values rather than saying "the internal domain":
    the cluster domain the Network step set, and the Tailscale root domain every node
    joins (derived ``<brand>.internal`` when left blank — ``effective_superdomain``)."""
    return (f"Serve only {cfg.cluster_domain or 'the cluster domain'} and the internal "
            f"Tailscale root domain {cfg.effective_superdomain()} that every node joins. "
            "No domains table — this is the default and what almost every mesh wants. "
            f"The services {cfg.cluster_domain or 'the cluster domain'} provides are "
            "still picked on its own services page, which comes next.")


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
    (build-x86-host-stage4.sh:4351-4356) and warns "--person-role/--domains are ignored
    for non-client role" otherwise (:1722-1723). A standalone build emits it never, and
    ``--unaffiliated`` hard-CONFLICTS with it (:1414).

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
# DERIVED, not transcribed. This table used to be a 20-entry hand-copy of every
# builder's role switch — a fourth place the role vocabulary was written down, and
# the reason a rename had to be applied here too. It now delegates to the ONE shell
# declaration (scripts/_roles-lib.sh: the derived "${BRAND}-${ROLE}" rule plus its
# declared exceptions), read through core/roles.py. The name is kept because
# test_pages_fields_asks.py and derive_hostname() below both reference it.
class _HostnameSuffixView:
    """``_HOSTNAME_SUFFIX[platform][role]`` -> suffix, answered from the shell lib.

    Presented as a mapping only so the existing ``.get(plat, {}).get(role)`` call
    shape keeps working. There is no dict to drift.
    """

    def get(self, platform: str, default=None):
        brand = "\x00BRAND\x00"
        prefix = brand + "-"

        class _Roles:
            def get(_self, role, _default=None):
                hn = roles.hostname(platform, role, brand)
                if not hn.startswith(prefix):
                    return None                     # e.g. rpi5 generic -> gentoo-*
                sfx = hn[len(prefix):]
                return None if sfx == roles.builder_role(role, platform) else sfx

            def __getitem__(_self, role):
                v = _self.get(role)
                if v is None:
                    raise KeyError(role)
                return v

        return _Roles()

    def __getitem__(self, platform):
        return self.get(platform)


_HOSTNAME_SUFFIX = _HostnameSuffixView()

# Each builder's DEFAULT_USER initialiser — the account created when -u is omitted.
_BUILDER_DEFAULT_USER = {
    "x86": "snap",                       # build-x86-host-stage4.sh:246
    "rpi5": "pi",                        # :288
    "frite": "frite",                    # :219
    "jetson": "jetson",                  # :203
    "orangepi5": "orangepi5",            # :246
    "orangepizero2": "orangepizero2",    # build-orangepi-zero2-stage4.sh:293
    "orangepizero2w": "orangepizero2w",  # build-orangepi-zero2w-stage4.sh:300
    "orangepizero3": "orangepizero3",    # build-orangepi-zero3-stage4.sh:303
    "orangepi3-lts": "orangepi3lts",     # :296
    "orangepi4-lts": "orangepi4-lts",    # :314
}


def default_local_user() -> str:
    """The Studio default for ``local_user``: the INVOKING user, per call.

    Was the literal ``"magus"`` — the original operator's account baked into every
    default x86 argv (``--local-user magus``) on any machine the Studio ran on.
    ``getpass.getuser()`` honours LOGNAME/USER before falling back to the uid's
    passwd entry; the except arm covers the (bare-container) case where neither
    exists. Every predicate that asks "was the account name customized off the
    Studio default?" must compare against THIS, not a literal — the two emission
    predicates (``derive_default_user`` / ``_arm_common_args``) both do.

    NOT consulted on the worker spec channel in practice: ``to_dict``/``save`` pin
    every field via ``asdict``, so a materialized IMAGE_SPEC_JSON always carries
    ``local_user`` explicitly and ``from_dict`` assigns it verbatim.
    """
    try:
        return getpass.getuser()
    except Exception:
        return "user"


def derive_hostname(cfg: "ImageConfig") -> str:
    """The hostname this image would get with NO ``-H`` — i.e. what the builder's own
    role switch assigns. Pure; never raises.

    Notes that make this honest rather than decorative:
    * the UNAFFILIATED x86 desktop is special-cased to ``gentoo-desktop``
      (build-x86-host-stage4.sh:1604, applied AFTER the brand is neutralised);
    * rpi5's ``generic`` role drops the brand entirely (``gentoo-${BOARD}``, :1276);
    * an unknown role on any platform falls through to ``{brand}-{role}``, and an
      unset role on x86 to ``{brand}-host`` (:2072).
    """
    brand = (cfg.brand or "hugmesh").strip() or "hugmesh"
    role = (cfg.role or "").strip()
    plat = (cfg.platform or "x86").strip() or "x86"
    if plat == "x86" and (role == UNAFFILIATED_ROLE or cfg.unaffiliated):
        return "gentoo-desktop"           # build-x86-host-stage4.sh:1604
    if plat == "rpi5" and role == "generic":
        return f"gentoo-{cfg.board or 'rpi5'}"   # build-rpi5-stage4.sh:1294
    if not role:
        # An UNSET role on x86 still resolves to the builder's own default
        # (backend-gpu, whose hostname exception is the legacy "-host").
        return roles.hostname(plat, "backend-gpu", brand) if plat == "x86" else brand
    return roles.hostname(plat, role, brand, cfg.board or "")


def derive_default_user(cfg: "ImageConfig") -> str:
    """The default account name this image would get with NO ``-u``.

    Two layers, both real:
    1. every builder ships a platform DEFAULT_USER (``_BUILDER_DEFAULT_USER``);
    2. **``--local-user`` overrides it** — ``[ -n "${LOCAL_USER}" ] && DEFAULT_USER=
       "${LOCAL_USER}"`` (build-x86-host-stage4.sh:1913 and the ARM twins). x86 emits
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
    if local and (cfg.standalone or local != default_local_user() or cfg.local_pass):
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
# build-jetson-stage4.sh ROLE="edge-ai"; frite/orangepi5/orangepizero2 have ONE
# role (the ROLE_CHOICES role-id == platform name) and emit no --role at all. x86
# keeps its dataclass default. A unit test pins every value ∈ roles_for_platform().
PLATFORM_DEFAULT_ROLE = {
    "x86": "standalone-thick",
    "rpi5": "generic",
    "frite": "frite",
    "jetson": "edge-ai",
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
# Same family, named ONCE up at FLAVOR_MEDIA_PLATFORMS (which a test pins to real
# --flavor emission) — aliased rather than re-spelled so the two cannot drift apart.
_ISO_FLAVOR_PLATFORMS = FLAVOR_MEDIA_PLATFORMS


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
# app-admin/calamares into PKGS (build-x86-host-stage4.sh:1801 / :5115). Mirrored here
# deliberately; tests/scripts/test-installer-ui-node-default.sh re-extracts the set from
# that LIVE builder line and fails if the two ever drift.
_CALAMARES_INSTALLER_UI = ("calamares", "all")
# What a headless node emits instead. Explicit (not "" = defer-to-builder) so the intent
# is auditable in --print-command / --print-specs rather than inferred from an absence;
# same WANT_CALAMARES=false outcome as the builder's own :1619 non-standalone default.
_NODE_INSTALLER_UI = "cli"


def resolve_installer_ui_default(cfg: "ImageConfig") -> str | None:
    """Role-class twin of resolve_platform_defaults (#337/#344): a headless x86 NODE must
    never request a graphical installer front-end.

    The builder ALREADY implements this rule — build-x86-host-stage4.sh:1799 defaults an
    UNSET ``INSTALLER_UI`` to ``all`` for --standalone and ``cli`` for every other role —
    but the Studio's flat dataclass default (``installer_ui: str = "all"``) means
    to_cli_args:3794 always passes an explicit value, so that ``[ -z ... ]`` guard can
    never fire and every node inherits the standalone-only ``all``. That is not merely
    wasteful: the USE closure app-admin/calamares needs (specs-x86/portage/package.use/
    desktop) is copied ONLY for ROLE_CLIENT roles (:3676), so on a node calamares is
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
    None (the core/ house idiom — cf. save():2559 — since core/ has no logger; the caller
    routes it to STDERR, never stdout, which is app.py's argv channel). Called at
    MATERIALIZE time only (WorklistConfig._materialize_one) and on app.py's headless
    --print-command cfg — NEVER in to_cli_args, so emission stays a faithful field->argv
    translation (invariant I3).
    """
    if (cfg.platform or "x86") != "x86":
        return None                       # installer_ui is _X86-only (PLATFORM_FIELD_SUPPORT:1101)
    if image_class(cfg.mode, cfg.role) != "node":
        return None                       # client / standalone: untouched, byte-identical
    if cfg.installer_ui not in _CALAMARES_INSTALLER_UI:
        return None                       # already cli/ncurses: WANT_CALAMARES is false already
    prev = cfg.installer_ui
    cfg.installer_ui = _NODE_INSTALLER_UI
    return (f"installer_ui {prev!r} -> {_NODE_INSTALLER_UI!r} for headless node role "
            f"{cfg.role!r}: build-x86-host-stage4.sh gates the calamares USE closure "
            f"(package.use/desktop) on ROLE_CLIENT:3676, so a node cannot resolve "
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


def field_default(name: str):
    """The dataclass default for one ImageConfig field.

    PUBLIC since 2026-08-26. Every hide that leaves the output unchanged in the page set has to reset
    its field to this value, so three GUI pages had grown their own byte-identical
    copy (network.py, build.py, and role.py by importing the underscore name). They all
    delegate here now: the dataclass is the single truth, and a page that compares
    against a literal instead gets fields like ``snort`` — which defaults to True —
    exactly backwards.
    """
    f = ImageConfig.__dataclass_fields__[name]  # type: ignore[attr-defined]
    return f.default_factory() if f.default is MISSING else f.default


#: Private alias kept for this module's own long-standing call sites. Same object, so
#: there is exactly one implementation; new callers should use the public name.
_field_default = field_default


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


def mode_axis_violated(fld: str, cfg: "ImageConfig") -> bool:
    """Is ``fld``'s MODE narrowing violated by this image, on a platform where that
    narrowing is actually builder-true?

    The exact twin of ``class_axis_violated``, and it exists for the same reason that one
    does: the raw ``cfg.mode not in scope.modes`` test asserts a field's mode rule holds on
    EVERY builder that parses the flag, and for the cluster-identity trio that is FALSE.
    ``_x86_args:3582`` wraps --cluster-domain/--games-domain/--release-state in
    ``mode in ("cloud","mesh")``; ``_arm_common_args:3156-3157`` emits --cluster-domain in
    every mode for all nine ARM builders, and build-rpi5-stage4.sh:3386 bakes it into
    /etc/hugmesh/cluster-domain unconditionally. Reading the mode tuple flat would put a
    standalone rpi5 image's REAL, EMITTED cluster domain out of scope — hiding the widget
    and (the wizard pairs every hide with a clear that leaves the output unchanged) resetting the typed
    value to the "hugmesh.net" default behind the operator's back.

    Returns False when the platform axis already owns the rejection (that gate, and
    strip_platform_unsupported, are the flag-not-parsed story) and False when the field's
    mode rule simply does not hold on this builder (``mode_platforms``)."""
    scope = FIELD_SCOPE.get(fld)
    if scope is None:
        return False
    plat = cfg.platform or "x86"
    if plat not in scope.platforms:
        return False
    if scope.mode_platforms is not None and plat not in scope.mode_platforms:
        return False
    return cfg.mode not in scope.modes


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
    # mode_axis_violated, NOT the flat `cfg.mode not in scope.modes` this line used to be:
    # the mode rule, like the class rule, can be true on one builder and false on another
    # (the cluster-identity trio — see FieldScope.mode_platforms). The flat test was correct
    # only while every mode narrowing happened to be platform-uniform, which stopped being
    # true on 2026-08-26.
    if mode_axis_violated(fld, cfg):
        return "mode"
    return None


def field_in_scope(fld: str, cfg: "ImageConfig") -> bool:
    """Qt-free twin of gui/pages/_gating.scope_allows: is ``fld`` meaningful for THIS image
    (platform x role-class x mode)? Unknown fields are in scope everywhere (fail-open —
    never gate a universal knob)."""
    return scope_reject_reason(fld, cfg) is None


# Platforms whose builder HARD-ERRORS on --standalone with a cluster-node role, verbatim:
#   build-rpi5-stage4.sh:1046
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
# build-x86:1623 fire. That changes emission for existing node configs, so it belongs with
# finding 4/5 proper (step (c)), not here. BUILDER_DEFAULTS declares the gap as `override`
# and GUARD A pins it, so it cannot be forgotten.
#
# TODO(finding 4/5, bundle_source): DEFERRED — the fix is a tri-state, the shape is now
# settled (see SEQUENCING below), and what remains is a UX + product decision, not mechanics.
# Step (c) attempted the to_cli_args fix and found a SECOND blocker the audit did not have.
# Recorded rather than worked around, because the workaround would be a silent-wrong-image
# bug of its own:
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
#   SEQUENCING — RE-CHECKED, and the answer changed. This used to say "wait for
#   fix/studio-installer-ui-node-default, then mirror it". That exemplar LANDED (#384,
#   merged 2026-07-17) and it did NOT pick the tri-state: it picked a materialize-time
#   RESOLVE + a NOTE (resolve_installer_ui_default, called from worklist._materialize_one
#   AND app.py --print-command, so both channels resolve and the parity test above is
#   satisfied). So the FIRST blocker recorded here — "correcting it in only one channel
#   makes the same cell build two different images" — is dissolved: call it from both, as
#   #384 does.
#
#   The SECOND blocker survives the exemplar, and #384's own justification is what proves
#   it does not transfer. #384 overrides an EXPLICIT installer_ui on a node because on a
#   node that value is UNSATISFIABLE: the calamares USE closure is copied only for
#   ROLE_CLIENT (build-x86:3676), so honouring it buys a guaranteed ~16min failure (it
#   killed 10 node images). `--bundle-source` on a node is the opposite — perfectly
#   BUILDABLE, just 33MB of generator tree plus /usr/sbin/hugmesh-regenerate. Overriding it
#   would be overriding a preference the builder CAN satisfy, which is exactly the
#   "silently corrected an explicit value" anti-pattern #384 was careful not to commit. So
#   the tri-state above is now the SETTLED shape for this field, not a candidate.
#
#   WHY IT IS STILL NOT DONE HERE (deferred with a reason, not forgotten). The tri-state is
#   not a config.py-local change; it crosses surfaces that need a decision this file cannot
#   make on its own:
#     * gui/pages/build.py:784/:1199/:1462 drives bundle_source through a two-state
#       QCheckBox. '' | True | False needs an affordance for "nobody said" — a
#       partially-checked tristate box, or a different control. That is a UX decision.
#     * SIX call sites ASSIGN the field outright on a mode/role change (gui/pages/mode.py:270,
#       gui/pages/role.py:1317, gui/pages/localcloud_nodes.py:382, tui/journey.py:486,
#       tui/journey.py:1023, tui/localcloud.py:100). While they all assign, the field is
#       almost never LEFT unset, so the tri-state buys nothing until someone decides which
#       of the six should instead stay quiet — a product decision about what a node image
#       is allowed to contain, and specifically whether a node keeps hugmesh-regenerate.
#     * BUILDER_DEFAULTS['bundle_source'].policy flips override -> defer, which turns
#       GUARD A's test_guard_a_policy_override_pins_the_known_gap RED by design, and
#       test_cli_args.py's X86 tails plus test_field_scope.py:190 move with it.
#   GUARD A is doing its job in the meantime: it fails the moment either flag stops
#   emitting unconditionally, so this cannot be quietly inherited.


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
    ``--encrypt-root`` also sets ``INSTALLER_ISO=true`` (build-x86-host-stage4.sh:1780),
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
    # An INFRA slug this platform's builder cannot bake (tor / egress-vpn on an Orange Pi
    # node: host daemons that image does not carry, and its builder refuses them) is
    # dropped from a mesh-wide selection that reached this row, exactly like the
    # worklist's per-node infra fold drops a slug the platform cannot express.
    catalog = OPTIONAL_SERVICES_BY_PLATFORM.get(plat)
    if catalog is not None and cfg.optional_services:
        kept = [s for s in cfg.optional_services
                if not (s in INFRA_SERVICES_CHOICES and s not in catalog)]
        if kept != list(cfg.optional_services):
            cfg.optional_services = kept
            cleared.append("optional_services")
    return cleared


# ── per-domain identity-provider choice (issue #47) ──────────────────────────────
# WHERE a domain's sign-in lives: "superdomain" (THE DEFAULT — its users sign in via
# the mesh's central Casdoor; today's behavior byte-for-byte) or "own" (this domain
# runs its OWN Casdoor instance, stood up per domain the way the local stack's
# tests/stack/compose.brand-b.yaml second-Casdoor proof does — see
# core/own_casdoor.py for the compose-lane translation). DISTINCT from the
# node-level IDP_CHOICES axis above, which picks the MESH's central provider; this
# is a per-row column of the superadmin Domains table. Manifest emission is
# OMIT-WHEN-DEFAULT (absent == superdomain by definition), so a pre-#47 manifest
# and a superdomain-only config both keep provisioning byte-identically.
DOMAIN_IDP_SUPERDOMAIN = "superdomain"
DOMAIN_IDP_OWN = "own"
DOMAIN_IDP_CHOICES = (DOMAIN_IDP_SUPERDOMAIN, DOMAIN_IDP_OWN)

# A GitHub organisation SLUG (the per-domain ``Domain.github_org`` field, read by the
# Go-Live "Export to GitHub org" step): letters, digits and single hyphens, no leading
# or trailing hyphen, at most 39 characters — GitHub's own login rule. The slug is the
# ONLY thing ever stored: the export signs in with the person's own ``gh`` login at
# run time (a pointer, never a token copy).
GITHUB_ORG_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$")


def github_org_problem(slug) -> str:
    """Why ``slug`` cannot be a GitHub organisation; "" when it can. Empty is fine:
    no org is the default, and every config written before the field existed
    carries exactly that."""
    if slug is None:
        return ""
    if not isinstance(slug, str):
        return f"GitHub org must be text, got {slug!r}"
    s = slug.strip()
    if not s:
        return ""
    if len(s) > 39:
        return f"GitHub org {s!r} is longer than 39 characters"
    if not GITHUB_ORG_RE.match(s):
        return (f"not a GitHub org slug: {s!r} (letters, digits and single hyphens, "
                "no leading or trailing hyphen)")
    return ""


#: The default brand id of a public name (hugmesh-generator#654, D4): the DNS name with
#: every run of non-[a-z0-9] turned into one dash ("acme.example" -> "acme-example") —
#: the rule own_casdoor.slug has always used for the tenant key, the Tor key folder and
#: the compose service names, so a record without stored ids keeps the ids its running
#: mesh already uses.
_BRAND_ID_SLUG_RE = re.compile(r"[^a-z0-9]+")


def default_brand_id(name: str) -> str:
    return _BRAND_ID_SLUG_RE.sub("-", (name or "").strip().lower()).strip("-")


@dataclass
class Domain:
    name: str = ""
    title: str = ""
    # The brand's one id (#654, D4): the text the registry's nsPrefix, an own-sign-in
    # brand's tenant key, the Tor key-folder name, the certificate list's brand column
    # and the Vault path segment all share. "" (every pre-#654 row) = the default
    # derived from ``name`` (default_brand_id), which is what every consumer derived
    # for itself before; brand_model.brand_id reads it. OMIT-WHEN-EMPTY when saved.
    id: str = ""
    # Worklist entry-id refs this domain attaches to (f"{role}.{platform}"); empty =
    # attach to every eligible image. Legacy `games: bool` was DROPPED — from_dict
    # migrates a truthy games into optional_services += ["games"] (games never reached
    # argv, so zero emission change; intent preserved, never silently dropped).
    images: list[str] = field(default_factory=list)
    optional_services: list[str] = field(default_factory=list)  # akkoma/tuwunel/phpbb/owncast/tor...
    # Which Casdoor serves this domain's sign-in (DOMAIN_IDP_CHOICES, issue #47).
    # The default rides the superdomain's central Casdoor; "own" asks cluster
    # provisioning (via the mesh manifest) / the local compose lane
    # (core/own_casdoor.py) to stand up a per-domain Casdoor. Absent in an old
    # saved config/manifest == superdomain (_domain_from_dict normalizes), and
    # both manifest emitters OMIT the default so pre-#47 bytes never change.
    idp: str = DOMAIN_IDP_SUPERDOMAIN
    # Does this domain get its OWN Tor v3 onion (hugmesh-generator#582, operator
    # decision 68 = A on #347)? ``tor`` is the ONE infra slug that became per-domain:
    # a Tor domain is its own HiddenService stanza fronting the SAME gateway, and the
    # gateway tells the domains apart by the onion Host (hugmesh-gateway#38's host
    # map). It needs Tor on the node / mesh (the node-plane ``tor`` selection) to do
    # anything — see core/domain_services.tor_front_door_state. Manifest emission is
    # OMIT-WHEN-FALSE, like ``idp``, so every pre-#582 manifest keeps its bytes. A
    # legacy ``"tor"`` in ``optional_services`` (the pre-#227 freeform cell, a slot no
    # builder ever read) MOVES here at load — the ``games`` precedent.
    tor: bool = False
    # The brand record (hugmesh-generator#654, D5/D7/D10). Three keys that every copy
    # site carries by the FIELD LIST (``DOMAIN_FIELDS``), never by a literal key list,
    # so a field added here reaches the manifest, the local mesh, the saved mesh and
    # the fleet without a change at any of them. All three are OMIT-WHEN-EMPTY in
    # every saved shape, so a row that uses none keeps its pre-#654 bytes.
    #
    # ``look``: ONLY the look fields this brand changes (brand_model.LOOK_KEYS); the
    # superbrand's default supplies the rest (brand_model.effective_look).
    look: dict[str, Any] = field(default_factory=dict)
    # ``ways``: how this brand is reached, written through ONE function
    # (brand_model.set_ways): {"internal_name": str, "public": {"provider", "inputs",
    # "token_file"}}. The Tor way is the ``tor`` field above — one field, one writer.
    ways: dict[str, Any] = field(default_factory=dict)
    # ``issuer_port``: the published host port of an own-sign-in brand's Casdoor,
    # STORED here and never recomputed from the row's position (D4): removing or
    # reordering a brand must not move another brand's issuer. 0 = not allocated
    # (a brand that signs in through the superbrand, or a pre-#654 row).
    issuer_port: int = 0
    # The GitHub organisation this domain's repositories are EXPORTED to by the
    # Go-Live "Export to GitHub org" step (core/org_export.py): an org SLUG
    # (``GITHUB_ORG_RE``), never a token. "" — the default, and every config from
    # before the field existed — means the step does not apply to this domain at
    # all. OMIT-WHEN-EMPTY on every saved shape, like ``tor``, so an untouched
    # config, record and manifest keep their bytes.
    github_org: str = ""
    # This domain's OWN identity-provider settings (2026-10-21, per-domain sign-in):
    # {"provider", "issuer", "client_id", "jwks"} — the same four values the mesh-wide
    # provider carries (ImageConfig.idp / idp_issuer / idp_client_id / idp_jwks), and
    # validated by the same rules (``signin_problems``). EMPTY — the default and every
    # row written before the field existed — INHERITS: a ``superdomain`` row signs in
    # through the mesh's central provider, whatever that is, and an ``own`` row runs
    # its own Casdoor exactly as before. Only an ``own`` row may carry settings, and
    # only an external provider (entra/aws/oidc) needs them: that brand then trusts its
    # own external issuer — one more ``<issuer>=<brand id>`` pair in the gateways'
    # tenancy registry (hugmesh-gateway DomainRegistry: one issuer, one brand) — and
    # no Casdoor is stood up for it. Written through ONE function,
    # ``set_domain_signin``; read through ``effective_signin``. OMIT-WHEN-EMPTY.
    idp_settings: dict[str, Any] = field(default_factory=dict)


#: Every field a brand row carries, in declaration order — THE key list every copy
#: site reads. A site that spells its own list is the defect brand_model.COPY_SITES
#: and the mutation battery exist to catch.
DOMAIN_FIELDS: tuple[str, ...] = tuple(Domain.__dataclass_fields__)

#: Row keys left out of every SAVED shape when they are empty/false/zero, so a row
#: that does not use them is written exactly as before the field existed.
DOMAIN_OMIT_WHEN_EMPTY: tuple[str, ...] = ("id", "tor", "look", "ways", "issuer_port",
                                           "github_org", "idp_settings")


# ── per-domain identity-provider settings (2026-10-21) ──────────────────────────────
#: The keys ``Domain.idp_settings`` may hold, in display order.
DOMAIN_IDP_SETTINGS_KEYS: tuple[str, ...] = ("provider", "issuer", "client_id", "jwks")

#: Where a domain's effective sign-in comes from (``DomainSignIn.source``).
SIGNIN_FROM_MESH = "mesh"                # superdomain row: the mesh's central provider
SIGNIN_OWN_CASDOOR = "own-casdoor"       # own row, no settings: its own Casdoor
SIGNIN_OWN_EXTERNAL = "own-external"     # own row with an external provider

SIGNIN_SOURCE_WORDS = {
    SIGNIN_FROM_MESH: "inherited from the mesh's sign-in",
    SIGNIN_OWN_CASDOOR: "this domain's own Casdoor",
    SIGNIN_OWN_EXTERNAL: "this domain's own external provider",
}

#: What the image route's Domains step says about an 'Own' sign-in, in the window and
#: the text screen alike: ImageConfig.to_cli_args passes no per-domain sign-in to any
#: builder, the row rides the mesh manifest only, and the casdoor-domains element writer
#: that would read it is not built (docs/DOMAIN-IDP.md). The domain's Identity tab says
#: the same in full (tui/brand_step.SIGNIN_NOT_APPLIED).
OWN_SIGNIN_NOT_APPLIED_ON_IMAGE = (
    "Not applied by a built image yet: an Own choice is kept with this configuration "
    "and the domain signs in through the mesh until the cluster side is built "
    "(docs/DOMAIN-IDP.md).")


class DomainSignIn(NamedTuple):
    """A domain's EFFECTIVE sign-in (``effective_signin``). ``issuer`` is "" when the
    path that starts the mesh derives it (the central Casdoor, or the domain's own
    Casdoor: core/own_casdoor.issuer_for on the Docker mesh, https://id.<domain> on a
    cluster); ``jwks`` is the effective JWKS (explicit, else the per-provider
    derivation ``idp_effective_jwks``)."""
    where: str          # DOMAIN_IDP_SUPERDOMAIN | DOMAIN_IDP_OWN
    provider: str       # IDP_CHOICES
    issuer: str
    client_id: str
    jwks: str
    source: str         # SIGNIN_FROM_MESH | SIGNIN_OWN_CASDOOR | SIGNIN_OWN_EXTERNAL


def signin_problems(provider: str, issuer: str = "", client_id: str = "",
                    jwks: str = "", where: str = "") -> list[str]:
    """Why one provider block cannot be used ([] when it can) — the mesh-wide rules of
    ``ImageConfig.validate_identity`` (the same regexes, the same combinations), for a
    domain's own block: Casdoor carries no external values at all; an external
    provider needs an https:// issuer and a client id, and a JWKS override must be
    https:// too. ``where`` prefixes each sentence ("domain shop.example: ")."""
    p = f"{where}: " if where else ""
    prov = (provider or "").strip() or "casdoor"
    issuer, client_id, jwks = ((issuer or "").strip(), (client_id or "").strip(),
                               (jwks or "").strip())
    if prov not in IDP_CHOICES:
        return [f"{p}unknown identity provider {provider!r} (known: "
                f"{', '.join(IDP_CHOICES)})"]
    out: list[str] = []
    if prov == "casdoor":
        for label, v in (("sign-in address", issuer), ("client id", client_id),
                         ("key address (JWKS)", jwks)):
            if v:
                out.append(f"{p}a {label} is set but the provider is Casdoor, which "
                           "derives its own; clear it or pick an external provider")
        return out
    if not issuer or not _IDP_URL_RE.fullmatch(issuer):
        out.append(f"{p}{IDP_LABELS.get(prov, prov)} needs an https:// sign-in address "
                   f"(got {issuer!r}); it is what every sign-in is checked against "
                   "and must be TLS")
    if not client_id or not _IDP_CLIENT_ID_RE.fullmatch(client_id):
        out.append(f"{p}{IDP_LABELS.get(prov, prov)} needs a client id (got "
                   f"{client_id!r}; letters, digits and . _ : / -, at most 128)")
    if jwks and not _IDP_URL_RE.fullmatch(jwks):
        out.append(f"{p}the key address (JWKS) must be an https:// URL (got {jwks!r}); "
                   "leave it empty to derive the provider's default")
    return out


def idp_settings_shape_problem(settings) -> str:
    """Why ``settings`` is not a ``Domain.idp_settings`` SHAPE ("" when it is): an
    object of text values under the four known keys, with a known provider. What the
    strict loader refuses at load (``ImageConfig._domain_from_dict``); the values
    themselves are checked by :func:`domain_signin_problems`."""
    if settings is None:
        return ""
    if not isinstance(settings, dict):
        return f"idp_settings must be an object, got {settings!r}"
    for k, v in settings.items():
        if k not in DOMAIN_IDP_SETTINGS_KEYS:
            return (f"idp_settings has an unknown key {k!r} (known: "
                    f"{', '.join(DOMAIN_IDP_SETTINGS_KEYS)})")
        if v is not None and not isinstance(v, str):
            return f"idp_settings.{k} must be text, got {v!r}"
    prov = str(settings.get("provider") or "").strip()
    if prov and prov not in IDP_CHOICES:
        return (f"idp_settings.provider must be one of {'|'.join(IDP_CHOICES)}, "
                f"got {prov!r}")
    return ""


def clean_idp_settings(settings) -> dict[str, str]:
    """The STORED form of a settings block: stripped text, empty values dropped, and
    a block that says only "casdoor" (the own-Casdoor default) is empty — so a row
    whose screen merely showed the provider picker keeps its old bytes."""
    if not isinstance(settings, dict):
        return {}
    out = {k: str(settings.get(k) or "").strip() for k in DOMAIN_IDP_SETTINGS_KEYS}
    out = {k: v for k, v in out.items() if v}
    if out.get("provider", "casdoor") == "casdoor" and set(out) <= {"provider"}:
        return {}
    return out


def _row_get(row, key, default=None):
    if isinstance(row, dict):
        return row.get(key, default)
    return getattr(row, key, default)


def runs_own_casdoor(row) -> bool:
    """Whether this domain stands up ITS OWN Casdoor: sign-in ``own`` with no external
    provider. What every own-Casdoor consumer (the compose overlay, its port sequence,
    ``ImageConfig.own_idp_domains``) asks instead of ``idp == "own"`` alone, so a
    domain with its own EXTERNAL provider never gets a Casdoor nobody uses. Accepts a
    Domain or a recorded row dict."""
    if (_row_get(row, "idp", "") or "") != DOMAIN_IDP_OWN:
        return False
    settings = _row_get(row, "idp_settings") or {}
    prov = (str(settings.get("provider") or "").strip()
            if isinstance(settings, dict) else "")
    return prov in ("", "casdoor")


def has_external_signin(row) -> bool:
    """Whether this domain trusts its OWN external issuer (sign-in ``own`` with an
    entra/aws/oidc provider)."""
    return ((_row_get(row, "idp", "") or "") == DOMAIN_IDP_OWN
            and not runs_own_casdoor(row))


def effective_signin(row, mesh=None) -> DomainSignIn:
    """THE resolver of a domain's sign-in, like ``brand_model.effective_look`` is of
    its look: a ``superdomain`` row inherits the MESH's provider (``mesh`` is any
    object with ``idp``/``idp_issuer``/``idp_client_id``/``idp_jwks`` — an ImageConfig
    or a LocalMeshBootstrapConfig; None = the built-in Casdoor); an ``own`` row with
    no settings is its own Casdoor; an ``own`` row with an external provider is that
    provider. An ``own`` row never inherits an external MESH provider: two brands on
    one issuer cannot be told apart (the gateways' DomainRegistry maps one issuer to
    one brand), so "its own" always means a different issuer."""
    where = (_row_get(row, "idp", "") or DOMAIN_IDP_SUPERDOMAIN)
    if where != DOMAIN_IDP_OWN:
        prov = (getattr(mesh, "idp", "") or "casdoor") if mesh is not None else "casdoor"
        if prov == "casdoor":
            return DomainSignIn(DOMAIN_IDP_SUPERDOMAIN, "casdoor", "", "", "",
                                SIGNIN_FROM_MESH)
        iss = (getattr(mesh, "idp_issuer", "") or "").strip()
        jw = (getattr(mesh, "idp_jwks", "") or "").strip()
        return DomainSignIn(DOMAIN_IDP_SUPERDOMAIN, prov, iss,
                            (getattr(mesh, "idp_client_id", "") or "").strip(),
                            idp_effective_jwks(prov, iss, jw), SIGNIN_FROM_MESH)
    s = clean_idp_settings(_row_get(row, "idp_settings") or {})
    prov = s.get("provider", "casdoor")
    if prov == "casdoor":
        return DomainSignIn(DOMAIN_IDP_OWN, "casdoor", "", "", "", SIGNIN_OWN_CASDOOR)
    iss = s.get("issuer", "")
    return DomainSignIn(DOMAIN_IDP_OWN, prov, iss, s.get("client_id", ""),
                        idp_effective_jwks(prov, iss, s.get("jwks", "")),
                        SIGNIN_OWN_EXTERNAL)


def domain_signin_problems(row, mesh=None, others=()) -> list[str]:
    """Why a domain's sign-in cannot be used ([] when it can): its settings block's
    shape and values (:func:`signin_problems`), settings on a ``superdomain`` row
    (they would never be read — the row inherits the mesh's), and an external issuer
    that is the mesh's own or another domain's (``others``: the other rows), because
    one issuer can only ever be one brand."""
    name = (_row_get(row, "name", "") or "").strip()
    where = f"domain {name}" if name else "domain"
    settings = _row_get(row, "idp_settings") or {}
    shape = idp_settings_shape_problem(settings)
    if shape:
        return [f"{where}: {shape}"]
    s = clean_idp_settings(settings)
    idp = _row_get(row, "idp", "") or DOMAIN_IDP_SUPERDOMAIN
    if idp != DOMAIN_IDP_OWN:
        return ([f"{where}: it signs in through the mesh, so its own identity-provider "
                 "settings would never be read; choose sign-in ‘own’ or clear them"]
                if s else [])
    out = signin_problems(s.get("provider", ""), s.get("issuer", ""),
                          s.get("client_id", ""), s.get("jwks", ""), where)
    if out or not has_external_signin(row):
        return out
    iss = s.get("issuer", "").rstrip("/")
    mesh_iss = ((getattr(mesh, "idp_issuer", "") or "").strip().rstrip("/")
                if mesh is not None and (getattr(mesh, "idp", "") or "casdoor") != "casdoor"
                else "")
    if iss and iss == mesh_iss:
        out.append(f"{where}: its sign-in address is the mesh's own; a domain with its "
                   "own sign-in needs an address of its own (one address can only be "
                   "one brand), or choose sign-in ‘superdomain’")
    for o in others or ():
        if o is row:
            continue
        oname = (_row_get(o, "name", "") or "").strip()
        if oname == name or not has_external_signin(o):
            continue
        oset = _row_get(o, "idp_settings") or {}
        oiss = str(oset.get("issuer") or "").strip() if isinstance(oset, dict) else ""
        if oiss.rstrip("/") == iss:
            out.append(f"{where}: {oname} already uses the sign-in address {iss}; one "
                       "address can only be one brand")
    return out


def set_domain_signin(row, idp: str, *, provider: str = "", issuer: str = "",
                      client_id: str = "", jwks: str = "", mesh=None,
                      others=()) -> list[str]:
    """THE ONE WRITER of a domain's sign-in (``idp`` + ``idp_settings``), for every
    screen: ``idp`` is DOMAIN_IDP_CHOICES; ``provider`` "" or "casdoor" on an ``own``
    row means its own Casdoor (settings cleared), an external provider stores the
    block. A ``superdomain`` row's settings are always cleared (it inherits the
    mesh's). ``others`` are the other rows (an issuer clash is refused). Returns the
    problems ([] = written); nothing is written when there is one. ``issuer_port`` (an
    own Casdoor's stored port) is cleared when the row stops running its own Casdoor,
    so a port is never held by a brand that has none. Accepts a Domain or a recorded
    row dict."""
    idp = (idp or "").strip() or DOMAIN_IDP_SUPERDOMAIN
    if idp not in DOMAIN_IDP_CHOICES:
        return [f"sign-in must be one of {'|'.join(DOMAIN_IDP_CHOICES)}, got {idp!r}"]
    block = ({} if idp != DOMAIN_IDP_OWN else clean_idp_settings(
        {"provider": provider, "issuer": issuer, "client_id": client_id, "jwks": jwks}))
    probe = Domain(name=str(_row_get(row, "name", "") or ""), idp=idp,
                   idp_settings=dict(block))
    problems = domain_signin_problems(probe, mesh, [o for o in (others or ())
                                                    if o is not row])
    if problems:
        return problems
    if isinstance(row, dict):
        row["idp"] = idp
        if block:
            row["idp_settings"] = dict(block)
        else:
            row.pop("idp_settings", None)
        if not runs_own_casdoor(row):
            row.pop("issuer_port", None)
    else:
        row.idp = idp
        row.idp_settings = dict(block)
        if not runs_own_casdoor(row):
            row.issuer_port = 0
    return []


def domain_rows_to_dict(domains) -> list[dict[str, Any]]:
    """The SAVED shape of a list of domain rows (a config file, a session record, the
    brand record): every field, except the ``DOMAIN_OMIT_WHEN_EMPTY`` ones when they
    say nothing (``tor`` false since #582; ``look``/``ways`` empty and ``issuer_port``
    0 since #654; ``github_org`` empty). A row that uses none of them is written exactly as it was before
    they existed; loading treats an absent key as the empty default. A row that is
    already a plain dict is passed through the same filter."""
    out: list[dict[str, Any]] = []
    for d in domains or []:
        row = dict(d) if isinstance(d, dict) else asdict(d)
        for k in DOMAIN_OMIT_WHEN_EMPTY:
            v = row.get(k)
            # an org of only spaces says nothing either (the export step strips it)
            if not (v.strip() if isinstance(v, str) and k == "github_org" else v):
                row.pop(k, None)
        out.append(row)
    return out


def domain_from_record_row(rec: dict[str, Any]) -> Domain:
    """A Domain from a RECORDED row (a saved mesh's ``domains`` entry), carrying every
    field by the field list and coercing each to its declared shape WITHOUT raising —
    the local-mesh route keeps a junk sign-in as the text it found and names it later
    (``local_mesh_domains._import_problem``), where ``ImageConfig._domain_from_dict``
    fails loudly for a saved config. One lenient loader, so no route spells its own
    key list (#654)."""
    kw: dict[str, Any] = {}
    for k in DOMAIN_FIELDS:
        if k not in rec:
            continue
        v = rec.get(k)
        f = Domain.__dataclass_fields__[k]
        if k == "tor":
            kw[k] = v is True
        elif k == "issuer_port":
            kw[k] = v if isinstance(v, int) and not isinstance(v, bool) and v > 0 else 0
        elif f.type in ("dict[str, Any]",):
            kw[k] = dict(v) if isinstance(v, dict) else {}
        elif f.type in ("list[str]",):
            kw[k] = [str(s) for s in v] if isinstance(v, (list, tuple)) else []
        elif f.type == "bool":
            kw[k] = bool(v)
        else:
            kw[k] = "" if v is None else str(v)
    # an empty sign-in is the default, as every reader before #654 took it
    if not kw.get("idp"):
        kw.pop("idp", None)
    return Domain(**kw)


def manifest_domain_rows(domains) -> list[dict[str, Any]]:
    """The MANIFEST shape of the domain rows — what BOTH mesh manifest emitters write
    (``ImageConfig.mesh_manifest`` and ``WorklistDriver.manifest_v2``), so the two
    cannot disagree: the saved shape above, with ``idp`` left out when it is the
    superdomain default (#47: absent == superdomain for every consumer)."""
    out: list[dict[str, Any]] = []
    for row in domain_rows_to_dict(domains):
        if row.get("idp", DOMAIN_IDP_SUPERDOMAIN) == DOMAIN_IDP_SUPERDOMAIN:
            row.pop("idp", None)
        out.append(row)
    return out


def brand_header_fields(brand: str, brand_title: str, org: str, cluster_domain: str,
                        superdomain: str, login_style: str = "",
                        login_decor: str = "") -> dict[str, Any]:
    """The manifest HEADER both emitters write, as a projection of the record's
    superbrand block (#654, D5): the superbrand's id is the manifest's ``brand``, its
    internal root name the manifest's ``superdomain``. ``login_style``/``login_decor``
    (the superbrand's shape and menu decoration) are OMIT-WHEN-EMPTY so a pre-#654
    manifest keeps its bytes."""
    out: dict[str, Any] = {
        "brand": brand, "brand_title": brand_title, "org": org,
        "cluster_domain": cluster_domain, "superdomain": superdomain,
    }
    if login_style:
        out["login_style"] = login_style
    if login_decor:
        out["login_decor"] = login_decor
    return out


@dataclass
class User:
    username: str = ""
    domain: str = ""
    # The PRIMARY role — USER_ROLE_CHOICES; "" (the dataclass default) = derive from
    # ``roles``, and ``user`` when neither says anything. Kept as a scalar because every
    # pre-#228 consumer of the mesh manifest and the saved config reads ``role``; it is
    # DERIVED (__post_init__) as the first of ``roles`` in precedence order, so the two
    # can never disagree at construction. Build Users through the constructor; do not
    # assign ``.role`` afterwards — ``roles`` is the truth (issue #228).
    role: str = ""
    email: str = ""
    # First-login registration METHOD (spec 4/6): "" = derive (builder/provisioning
    # default) | discord | gmail | password. Manifest-only — NEVER reaches to_cli_args
    # (User is provisioning data, not argv). "password" records that this account is
    # given a RANDOM password generated + presented at provisioning time; no plaintext
    # secret is ever stored on the User (so it is safe to serialize/save like the other
    # User fields — nothing to blank).
    registration: str = ""
    # ALL the roles this account holds (issue #228 — "should a person be assignable to
    # multiple roles"): the union of ``roles`` and ``role`` as constructed, normalized by
    # normalize_user_roles (deduped, precedence order, ``user`` floor). Serialized by
    # to_dict() OMIT-WHEN-SINGLE — a one-role account keeps its pre-#228 bytes in the
    # saved config and both mesh manifests (absent == [role]), exactly like the
    # per-domain ``idp`` key — and loaded from either spelling (from_dict), so a config
    # saved before this field existed, or by a Studio that knows only ``role``, round-trips.
    roles: list[str] = field(default_factory=list)

    def __post_init__(self):
        given = [self.roles] if isinstance(self.roles, str) else list(self.roles or [])
        self.roles = normalize_user_roles([*given, self.role])
        self.role = self.roles[0]

    @property
    def tier(self) -> str:
        """The --person-role tier this account derives (person_tier)."""
        return person_tier(self.roles)

    def to_dict(self) -> dict[str, Any]:
        """The wire shape (saved config + both mesh manifests): ``role`` always — the
        primary, what every pre-#228 consumer reads — and ``roles`` only when the
        account holds more than one, so a single-role row is byte-identical to before
        the field existed. from_dict accepts both spellings."""
        d = asdict(self)
        if self.roles == [self.role]:
            del d["roles"]
        return d


@dataclass
class ImageConfig:
    # ── identity / mode ──
    mode: str = "standalone"           # standalone | cloud | mesh
    role: str = "standalone-thick"
    platform: str = "x86"              # x86 | rpi5 | frite | jetson -> BUILDER_SCRIPTS
    board: str = ""                    # frite: FRITE_BOARDS | jetson: JETSON_BOARDS | rpi5: RPI_BOARDS
    flavor: str = ""                   # frite: live | installer | both
    # GB of RAM on the Raspberry Pi / Orange Pi board a cluster NODE image is for
    # (--ram-gb). "" = not stated. REQUIRED for omnibus (16 GB+); for backend the
    # builder refuses a value below 8, for pki/frontend below 4. x86/jetson do not take it.
    ram_gb: str = ""
    env: str = "test"
    brand: str = "hugmesh"
    brand_title: str = "HugMesh Systems"
    org: str = "hugmesh"
    brand_profile: str = ""            # -C/--config brands/*.conf (carries HEADSCALE_URL/RELEASE_STATE/… presets)
    cluster_domain: str = "hugmesh.net"
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
    superdomain: str = ""            # Tailscale root domain all mesh nodes join; "" = derived <brand>.internal. Emitted as --superdomain for MESH builds (WS-SUPER-B: baked to <etc>/superdomain + headscale MagicDNS); permanently internal, never go-live-flipped (I7)
    games_domain: str = ""             # --games-domain (games.<domain> host + OIDC issuer; x86+rpi5)
    release_state: str = ""            # --release-state internal|public (x86+rpi5; "" = builder default)
    release_tag: str = ""              # --release-tag image stamp (x86)
    version: str = ""                  # -v/--version image stamp (all)
    person_role: str = ""              # --person-role user|mod|admin|superadmin (x86 CLIENT roles; "" = derive)
    hostname: str = ""                 # -H/--hostname baked host identity (all)
    timezone: str = ""                 # -T/--timezone baked host identity (all)
    user: str = ""                     # -u/--user baked default account name (all; distinct from --local-user)
    local_user: str = field(default_factory=default_local_user)  # the INVOKING user, not a baked operator name
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
    # ── mesh secrets store (#224; x86 + rpi5 node builders) ──
    # "" address (the NATIVE DEFAULT) = offline/USB-only delivery and emits NOTHING.
    # A set address threads --vault-addr [--vault-external-addr]; the builders bake
    # /etc/hugmesh/vault.conf (connection facts only — the token and unseal key stay
    # on the KEYS stick). vault_field_error() fail-closes the pair. The KV mount and
    # base path are NOT fields: the mount and the literal hugmesh/<service> read
    # prefix are pinned by the shipped ClusterSecretStore and its ExternalSecrets
    # (#285, decision 22), and the two flags that used to carry them are gone.
    vault_addr: str = ""               # --vault-addr https://… INTERNAL (VAULT_FIELDS)
    vault_external_addr: str = ""      # --vault-external-addr https://… (#335; "" = no such line in vault.conf)
    # ── base CA certificates (#335) — RECORDED ONLY, and labelled so on both faces.
    # ``base_ca_certs`` is the operator's list of PEM files (absolute paths, checked
    # by ca_cert_error before anything can add one); ``domain_ca`` maps a domain NAME
    # to one of those paths ("" / absent = whatever the mesh already trusts). Neither
    # reaches to_cli_args, any builder or any manifest: NO builder script parses a CA
    # flag, so emitting one would be a knob that silently does nothing. Empty
    # list + empty dict are the native defaults and keep argv byte-identical.
    base_ca_certs: list[str] = field(default_factory=list)
    domain_ca: dict[str, str] = field(default_factory=dict)
    # ── per-domain service configuration, the GATE's bookkeeping (#494/#495) ──
    # The NAMES of the domains whose per-domain Services page the operator actually
    # went through. NOT provisioning data and NOT argv (NON_ARGV_FIELDS): neither mesh
    # manifest carries it — manifest_v2 emits an explicit key list, and mesh_manifest()
    # filters this key out by name — so a manifest is byte-identical whether or not the
    # page was walked. It exists because ``optional_services == []`` is ALREADY
    # meaningful ("the cluster-wide set applies", see the emission table above), so
    # emptiness cannot double as "never configured"; a domain loaded from an older
    # worklist keeps its slugs AND stays unconfigured until someone confirms them,
    # which is the only reading that invents no selection. Consumed by
    # core/domain_services.gate_reason, which is what refuses an image build or a
    # docker mesh start naming the domains that were never configured.
    domain_services_reviewed: list[str] = field(default_factory=list)
    # The per-domain services of the MESH'S OWN domain (``cluster_domain``) — the
    # implicit domain every mesh serves and which #494's rule gives a services page
    # too, even on the default "just this mesh's own domain" path where the Domains
    # table is skipped (core/domain_services.implicit_own_domain). It is a separate
    # field, NOT a ``domains`` row, so the ASK-8 guard holds: an untouched flow emits
    # no ``--domains`` and no manifest ``domains`` entry. Provisioning input like
    # ``domains[].optional_services`` (never argv): both mesh manifests carry it as
    # ``cluster_domain_services`` ONLY when non-empty — empty means "the cluster-wide
    # set applies", the same reading as an empty per-domain list, and keeps every
    # pre-existing manifest byte-identical. Mesh mode only; cloud prefills its
    # cluster domain as a real row 0 and standalone has no domains.
    cluster_domain_services: list[str] = field(default_factory=list)
    # The GitHub org the MESH'S OWN domain exports to (``Domain.github_org`` for the
    # implicit own domain — the ``cluster_domain_services`` precedent: a separate
    # field, not a ``domains`` row, so the ASK-8 guard holds). "" = the own domain
    # takes no part in the Go-Live export step; OMIT-WHEN-EMPTY in to_dict and the
    # manifest, so every pre-existing config and manifest keeps its bytes.
    cluster_domain_github_org: str = ""
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
    # Named theme PRESET (core/theme_presets.py id: light/dark cores, basic
    # colours, pride flags) + ramp mode. "" preset = the raw primary/secondary
    # fields above rule alone (full back-compat: old configs load unchanged).
    # When set, the preset SUPPLIES primary/secondary and the delivery path
    # appends its delta block (light neutrals / flag stripes) after the shared
    # compose_login_css output, so fonts + derivation stay single-sourced.
    login_theme_preset: str = ""       # theme_presets.PRESETS id; "" = custom colours
    login_theme_mode: str = "dark"     # "dark" | "light" neutral ramp
    # ── web chrome (the Themes editor: header/footer existence, size, background,
    # content, plus the page background effect — #50 item 2). Same plane and same
    # channel as the login_* colours above: NON-argv, delivered as literal
    # --sd-header-*/--sd-footer-*/--sd-bg-effect tokens inside SNAP_THEME_CSS
    # (theme.chrome_tokens). Every default is the SHIPPED page exactly, so an old
    # saved config — whose JSON has none of these keys and therefore loads the
    # dataclass defaults — composes byte-identical css.
    login_header_hidden: bool = False  # True emits --sd-header-display: none
    login_header_size: str = ""        # "" = shipped | a theme.CHROME_SIZES name
    login_header_bg: str = ""          # "#RRGGBB" | "" = shipped (emits -on twin too)
    login_header_text: str = ""        # replacement header content; "" = shipped
    login_footer_hidden: bool = False
    login_footer_size: str = ""
    login_footer_bg: str = ""
    login_footer_text: str = ""
    # Background effect — the generator-side persistence anchor for host-shell
    # PR #20's deferred vanta catalog. "gradient" (the shipped theme-driven moving
    # gradient) is the default and emits no token; "none" flattens the backdrop;
    # "vanta-<effect>" (theme.VANTA_EFFECTS) is persisted but not yet selectable in
    # the UI — the effect loader ships only in hugmesh-login-ui today.
    login_bg_effect: str = "gradient"  # theme.BG_EFFECTS
    # ── the superbrand's shape and menu decoration (#654, D5/D6) — the two look
    # axes the Themes editor had no field for. The same NON-argv plane as the
    # login_* fields; they reach the mesh through the brand record and the manifest
    # header (OMIT-WHEN-EMPTY), never a builder flag. "" = the shipped page.
    login_style: str = ""              # theme.STYLE_VARIANTS id
    login_decor: str = ""              # theme.DECOR_VARIANTS id
    # ── the brand record this image is built from (#654, D5): a PATH the Studio
    # resolves names and flags from. NON-argv UNTIL the image builders parse
    # --brand-record (the builders-brand-record lane); test_brand_record_copy_sites
    # pins that the flag is emitted exactly when a builder parses it.
    brand_record: str = ""
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
    # Tri-state for the public PoW gate, "" / "on" / "off" (ANUBIS_CHOICES, issue #384).
    # "" = the build's ENV policy (prod on / test off); "on"/"off" force it, and are
    # folded into --optional-services by _services_args (never --exclude-services).
    anubis: str = ""
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
    compress: bool = True              # --compress: xz the finished artifact(s)   (ask 13: DEFAULT ON)
    # --compress-level N (issue #233): the xz preset --compress uses, 0-9. The
    # builders' own pre-flag behaviour was 9, so 9 stays the default and emits
    # NOTHING — an existing config's argv is unchanged byte for byte.
    compress_level: int = COMPRESS_LEVEL_DEFAULT
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
    # Run the QEMU emulated-device tests (tests/qemu/run-qemu-docker.sh) against this
    # build's images once it finishes. Like pentest this is NOT a builder flag — it is a
    # post-build step the Studio drives, so it stays in NON_ARGV_FIELDS and never
    # reaches argv. Only meaningful on ENV=test images: a prod build has the test
    # runner pruned out of its app tree, so booting one proves nothing about the
    # stack the assertions look for (BuildPage gates the checkbox on env accordingly).
    #
    # NAMED FOR THE LANE IT ACTUALLY DRIVES. Until 2026-08-26 this field was called
    # `qemu_e2e`, and every label built from that name promised the OTHER lane: THREE
    # different harnesses in this tree are called "e2e" —
    #   * tests/qemu/run-qemu-docker.sh   in-guest ASSERTIONS over a matrix of images
    #                                     (this field, and the only one the Studio ran);
    #   * tests/qemu/run-qemu-e2e.sh      the PLAYWRIGHT browser suite against ONE booted
    #                                     image's forwarded UI (core/emulation.playwright_argv);
    #   * tests/qemu/run-matrix-e2e.sh    the size/load matrix gated on HUGMESH_QEMU_E2E=1.
    # An operator who ticked "run the e2e suite on the built image" got the first and
    # expected the second. The name now says assertions, not e2e.
    qemu_device_tests: bool = False
    extra_flags: str = ""              # escape hatch — shlex-split, appended verbatim

    # ---- (de)serialization -------------------------------------------------
    def to_dict(self, include_secrets: bool = False) -> dict[str, Any]:
        """Serialize; plaintext secrets (SECRET_FIELDS) are BLANKED unless the caller
        explicitly opts in — a saved JSON config must never carry a password."""
        d = asdict(self)
        # users: the User wire shape (issue #228 — `roles` OMIT-WHEN-SINGLE), not the
        # raw asdict, so a one-role account keeps its pre-#228 bytes.
        d["users"] = [u.to_dict() if isinstance(u, User) else u for u in self.users]
        # domains: per-domain ``tor`` (#582) is OMIT-WHEN-FALSE here too, so a saved
        # config or session record with no Tor domain keeps its pre-#582 bytes.
        d["domains"] = domain_rows_to_dict(self.domains)
        # the own domain's GitHub org is OMIT-WHEN-EMPTY (its domains[] twin is), so
        # a config that never met the field keeps its bytes
        if not (d.get("cluster_domain_github_org") or "").strip():
            d.pop("cluster_domain_github_org", None)
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
        # per-domain idp (issue #47): absent/empty — every pre-#47 config — is the
        # superdomain default; junk fails loudly at load like the tri-states do,
        # never silently coerced into either real choice.
        v = kw.get("idp") or DOMAIN_IDP_SUPERDOMAIN
        if v not in DOMAIN_IDP_CHOICES:
            raise ValueError(
                f"domain {kw.get('name', '')!r}: idp must be one of "
                f"{'|'.join(DOMAIN_IDP_CHOICES)}, got {v!r}")
        kw["idp"] = v
        # per-domain Tor front door (#582). A real bool, or the two hand-written
        # spellings; junk fails loudly at load (the idp rule), never coerced.
        t = kw.get("tor", False)
        if isinstance(t, str) and t.strip().lower() in ("true", "false", ""):
            t = t.strip().lower() == "true"
        if t is None:
            t = False
        if not isinstance(t, bool):
            raise ValueError(
                f"domain {kw.get('name', '')!r}: tor must be true or false, got {t!r}")
        # MIGRATION: a legacy per-domain ``tor`` slug (pre-#227 freeform cell, kept as
        # a carried-over slug since) did nothing — the manifest carried it and no
        # builder read it (#580 addendum). Decision 68 made per-domain Tor a real
        # mechanism, so the intent moves onto the field that drives it, and the slug
        # leaves the allow-list rather than rendering a second, dead "tor" row.
        svcs = kw.get("optional_services")
        if isinstance(svcs, (list, tuple)) and "tor" in svcs:
            t = True
            kw["optional_services"] = [x for x in svcs if x != "tor"]
        kw["tor"] = t
        # The brand record's keys (#654): absent/null — every pre-#654 row — is the
        # empty default; a wrong SHAPE fails loudly at load like idp and tor do, never
        # a dict field holding a string.
        bid = kw.get("id")
        kw["id"] = "" if bid is None else str(bid).strip()
        for k in ("look", "ways"):
            v = kw.get(k)
            if v is None:
                kw[k] = {}
            elif not isinstance(v, dict):
                raise ValueError(
                    f"domain {kw.get('name', '')!r}: {k} must be an object, got {v!r}")
        port = kw.get("issuer_port", 0)
        if port is None or port == "":
            port = 0
        if isinstance(port, str) and port.strip().isdigit():
            port = int(port.strip())
        if isinstance(port, bool) or not isinstance(port, int) or port < 0 or port > 65535:
            raise ValueError(
                f"domain {kw.get('name', '')!r}: issuer_port must be a port number, "
                f"got {port!r}")
        kw["issuer_port"] = port
        # per-domain GitHub org (the Go-Live export step): absent / null / "" is "no
        # org" — every pre-existing config; anything else must be an org slug, and
        # junk fails loudly at load like idp and tor do, never silently kept as a
        # name the export would then try to create a repository under.
        org = kw.get("github_org")
        org = "" if org is None else org
        problem = github_org_problem(org)
        if problem:
            raise ValueError(f"domain {kw.get('name', '')!r}: {problem}")
        kw["github_org"] = org.strip()
        # per-domain identity-provider settings (2026-10-21): absent/null — every
        # earlier row — is the empty (inherit) default; a wrong SHAPE or an unknown
        # provider fails loudly at load like idp does; the values (issuer, client id)
        # are checked by validate_identity, through domain_signin_problems.
        st = kw.get("idp_settings")
        problem = idp_settings_shape_problem(st)
        if problem:
            raise ValueError(f"domain {kw.get('name', '')!r}: {problem}")
        kw["idp_settings"] = clean_idp_settings(st or {})
        return Domain(**kw)

    @staticmethod
    def _user_from_dict(x: dict[str, Any], usr_f: set[str]) -> "User":
        """Build a User from a raw dict, filtering unknown nested keys (forward-compat).
        Both role spellings load (issue #228): a pre-#228 ``role`` alone, a ``roles``
        list alone, or both (unioned — User.__post_init__ normalizes). ``roles`` that
        is null or not a list is treated as absent, never a crash; a bare string is
        taken as one role, so a hand-edited config still loads."""
        kw = {k: v for k, v in x.items() if k in usr_f}
        roles = kw.get("roles")
        if isinstance(roles, str):
            kw["roles"] = [roles]
        elif not isinstance(roles, (list, tuple)):
            kw.pop("roles", None)
        if not isinstance(kw.get("role", ""), str):
            kw.pop("role")
        return User(**kw)

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
        d["users"] = [cls._user_from_dict(x, usr_f) if isinstance(x, dict) else x
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
        # anubis tri-state (#384): the three spellings plus the bool a checkbox-era
        # hand-written config would use; junk fails closed AT LOAD, because a typo that
        # silently meant "default" would ship a public PoW gate the operator said to turn off.
        if "anubis" in d:
            d["anubis"] = cls._anubis_mode(d["anubis"])
        # base CA certificates (#335): tolerate `null` / a hand-edited scalar the same
        # way "domains": null is tolerated above — treat it as ABSENT (the native
        # empty default) rather than constructing a config whose list field holds a
        # string. Real content is still fail-closed at validate_identity, which is
        # where a path that is not a PEM (or a domain naming a dropped one) is named.
        for _k in ("base_ca_certs",):
            if _k in d and not isinstance(d[_k], (list, tuple)):
                d.pop(_k)
        if "domain_ca" in d and not isinstance(d["domain_ca"], dict):
            d.pop("domain_ca")
        # #495: tolerate `null` / a hand-edited scalar exactly as "domains": null is
        # tolerated — treat it as ABSENT (the native empty list), which is the
        # fail-CLOSED reading: every domain then counts as unconfigured and the gate
        # says so, rather than a junk value quietly standing in for "all reviewed".
        if "domain_services_reviewed" in d:
            v = d["domain_services_reviewed"]
            if isinstance(v, (list, tuple)):
                d["domain_services_reviewed"] = [x for x in v if isinstance(x, str)]
            else:
                d.pop("domain_services_reviewed")
        # The own domain's services (#494): the same tolerance — junk is ABSENT, i.e.
        # the cluster-wide set, never a list holding a scalar.
        if "cluster_domain_services" in d:
            v = d["cluster_domain_services"]
            if isinstance(v, (list, tuple)):
                d["cluster_domain_services"] = [x for x in v if isinstance(x, str)]
            else:
                d.pop("cluster_domain_services")
        # The own domain's GitHub org: the per-domain rule (_domain_from_dict) —
        # absent / null is "", junk fails loudly rather than naming an org to export to.
        if "cluster_domain_github_org" in d:
            v = d["cluster_domain_github_org"]
            v = "" if v is None else v
            problem = github_org_problem(v)
            if problem:
                raise ValueError(f"cluster_domain_github_org: {problem}")
            d["cluster_domain_github_org"] = v.strip()
        # MIGRATE the pre-2026-08-26 spelling of the post-build device-test opt-in.
        # from_dict filters unknown keys, so without this a config saved under the old
        # name would load with the opt-in silently OFF — the `games` precedent above:
        # intent preserved, never silently dropped.
        if "qemu_e2e" in d and "qemu_device_tests" not in d:
            d["qemu_device_tests"] = d.pop("qemu_e2e")
        # CANONICALIZE THE ROLE ON READ. The role is persisted with no schema version
        # and nothing anywhere re-validates it, so a config written before the role
        # vocabulary converged holds `be`, `fe`, `be+gpu`, `edge_ai`, `full` or
        # `gpu-host` — ids that would now fall through every `.get(role, default)` in
        # the Studio. Folding here (and NOT rewriting the file) is what lets an old
        # config replay: the record on disk is an already-emitted artifact.
        # A composite id (rpi5-desktop / jetson-desktop) is deliberately NOT folded —
        # it carries a platform, and only the argv emitters may spend that.
        if isinstance(d.get("role"), str) and d["role"]:
            d["role"] = roles.canonicalize(d["role"])
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
        """The Tailscale root domain every mesh node joins. An explicit superdomain
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
        primary, secondary = self.login_primary_color, self.login_secondary_color
        # The superbrand's shape/decoration (#654): an unknown id fails loudly here,
        # like an unknown preset below — theme.style_tokens would otherwise fall back
        # to the shipped style and the Studio preview would lie about the mesh.
        for _fld, _table in (("login_style", _theme.STYLE_VARIANTS),
                             ("login_decor", _theme.DECOR_VARIANTS)):
            _v = getattr(self, _fld)
            if _v and _v not in _table:
                raise ValueError(f"unknown {_fld}: {_v!r} (one of "
                                 f"{', '.join(sorted(_table))})")
        delta = ""
        if self.login_theme_preset:
            # A preset supplies the colours and its delta block; the shared
            # compose_login_css below still owns derivation + fonts, so the two
            # paths cannot drift. Unknown ids / modes raise ValueError like every
            # other invalid theme input (fail-closed, surfaced by the callers).
            from . import theme_presets as _presets
            try:
                preset = _presets.by_id(self.login_theme_preset)
            except KeyError as exc:
                raise ValueError(str(exc)) from exc
            primary, secondary = preset.primary, preset.secondary
            delta = _presets.delta_css(
                self.login_theme_preset, self.login_theme_mode or "dark")
        css = _theme.compose_login_css(
            primary, secondary,
            font_preset=self.login_font, font_family=family, font_bytes=font_bytes)
        if delta:
            # Later :root:root block wins at equal specificity — the delta lands
            # after the base tokens without touching the shared composer.
            css = (css + "\n" if css else "") + delta
        # Web chrome (Themes editor) rides the SAME later-block-wins mechanism.
        # All-defaults composes "" here, so a pre-chrome config's css is untouched;
        # chrome-only theming (e.g. just hiding the footer) still emits its block
        # even when no colour/font was chosen.
        chrome = _theme.chrome_css(
            header_hidden=self.login_header_hidden,
            header_size=self.login_header_size,
            header_bg=self.login_header_bg,
            header_text=self.login_header_text,
            footer_hidden=self.login_footer_hidden,
            footer_size=self.login_footer_size,
            footer_bg=self.login_footer_bg,
            footer_text=self.login_footer_text,
            bg_effect=self.login_bg_effect)
        if chrome:
            css = (css + "\n" if css else "") + chrome
        return css

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
        # web chrome (Themes editor, #50 item 2): the same fail-closed rules the other
        # login_* fields follow — strict hex-or-empty for colours, closed vocabularies
        # for the size names and the background effect (they flow into SNAP_THEME_CSS
        # token text; a typo would silently mis-render at runtime), printable-only for
        # the content strings (they become CSS string literals).
        validate_login_color("login_header_bg", self.login_header_bg)
        validate_login_color("login_footer_bg", self.login_footer_bg)
        from .theme import BG_EFFECTS, CHROME_SIZES  # local import: config stays lean
        for fld in ("login_header_size", "login_footer_size"):
            v = getattr(self, fld)
            if v and v not in CHROME_SIZES:
                raise IdentityValidationError(
                    f"unknown {fld}: {v!r} — known: {', '.join(CHROME_SIZES)} "
                    "(or \"\" for the shipped size)")
        if self.login_bg_effect and self.login_bg_effect not in BG_EFFECTS:
            raise IdentityValidationError(
                f"unknown login_bg_effect: {self.login_bg_effect!r} — known: "
                f"{', '.join(BG_EFFECTS)}")
        for fld in ("login_header_text", "login_footer_text"):
            v = getattr(self, fld)
            if v and not v.isprintable():
                raise IdentityValidationError(
                    f"{fld} must be printable text (it becomes a CSS string literal)")
        # cluster_domain + per-domain names flow into --domains / the mesh manifest
        validate_domain_name(self.cluster_domain)
        if self.games_domain:
            validate_domain_name(self.games_domain)
        # Tailscale root domain: "" = derived <brand>.internal (always valid once
        # brand is validated). Validate an explicit value like any other domain name
        # (core.validate accepts .internal). Feeds the manifest + the KEYS channel.
        if self.superdomain:
            validate_domain_name(self.superdomain)
        for d in self.domains:
            if getattr(d, "name", ""):
                validate_domain_name(d.name)
        # ── per-domain sign-in (2026-10-21): each own row's provider block follows the
        # mesh-wide rules below (signin_problems), a superdomain row carries none, and
        # no two brands share one issuer. Every pre-existing config has no block and
        # passes untouched.
        for d in self.domains:
            problems = domain_signin_problems(d, self, self.domains)
            if problems:
                raise IdentityValidationError(problems[0])
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
        # ── mesh secrets store (#224) — the same earliest-boundary rule: the values
        # land in the root-read /etc/hugmesh/vault.conf, so charset + combination are
        # enforced HERE, through the ONE predicate both faces' inline notes use.
        vault_err = vault_field_error(self.vault_addr, self.vault_external_addr)
        if vault_err:
            raise IdentityValidationError(f"vault: {vault_err}")
        # ── base CA certificates (#335). They reach NO argv, NO image and no
        # manifest, so this is not an emission guard. Only the STRUCTURAL rules are
        # enforced here — a non-string entry, a duplicate, a domain naming a
        # certificate the config does not carry — because those are wrong on every
        # machine and would make a saved config self-contradictory.
        #
        # READABILITY IS DELIBERATELY NOT ENFORCED (check_readable=False). A recorded
        # fact that changes no image must never be able to block a build: a config
        # written on one laptop and opened on another, or one whose PEM sits on a
        # volume that is not mounted this morning, would otherwise raise here and stop
        # a build that never depended on the file. The two faces DO check readability
        # and say so inline, which is the one place an operator can act on it.
        ca_err = base_ca_certs_error(self.base_ca_certs, check_readable=False)
        if ca_err:
            raise IdentityValidationError(f"base CA: {ca_err}")
        ca_err = domain_ca_error(self.domain_ca, self.base_ca_certs)
        if ca_err:
            raise IdentityValidationError(f"base CA: {ca_err}")
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
        if self.org != "hugmesh":
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

    def _compress_level_args(self) -> list[str]:
        """--compress-level N — the xz preset --compress uses (issue #233).

        Emitted ONLY beside --compress (the level means nothing without it: every
        builder reads COMPRESS_LEVEL exclusively inside its `if ${COMPRESS_IMG}` arm)
        and ONLY when it differs from COMPRESS_LEVEL_DEFAULT, which is the level all ten
        builders hardcoded before the flag existed. So a config that never touched the
        knob emits exactly the argv it emitted before — the property the exact-argv
        tests in tests/test_cli_args.py hold this to.

        An out-of-range value is CLAMPED rather than raised: the GUI can only offer
        0-9 (COMPRESS_LEVEL_CHOICES) and the builders hard-error on anything else, so a
        --config JSON carrying junk must not be able to hand a builder a flag it will
        refuse mid-run — it gets the nearest legal preset instead. The clamp lives in
        clamp_compress_level() because BuildPage restores the combo through the SAME
        reading; a second, different rule there would let the page and the argv
        disagree about one file (non-numeric junk resolves to the default, i.e. to
        emitting nothing at all)."""
        lvl = clamp_compress_level(self.compress_level)
        return [] if lvl == COMPRESS_LEVEL_DEFAULT else ["--compress-level", str(lvl)]

    @staticmethod
    def _anubis_mode(value) -> str:
        """Normalize the anubis tri-state to "", "on" or "off". Accepts the bools a
        hand-written config may carry (True -> "on", False/None -> ""); anything else
        is rejected fail-closed rather than read as "default"."""
        if value is True:
            return "on"
        if value is False or value is None:
            return ""
        v = str(value).strip().lower()
        if v in ANUBIS_CHOICES:
            return v
        raise ValueError(f"anubis must be one of '', 'on', 'off' (got {value!r})")

    def _services_args(self) -> list[str]:
        """--optional-services allow-list (with the explicit-none / --all-services
        sentinels, G13/G14) + the subtractive --exclude-services list. Shared by x86 +
        rpi5, the only builders that parse them.

        The anubis tri-state (``self.anubis``, #384) is folded in here, because it has
        no flag of its own: "on" adds the slug, "off" adds the ``-anubis`` token, "" adds
        nothing (so an untouched config emits the argv it always did). A force-off beside
        an EMPTY list relies on the builders' rule that a list of only deselect tokens
        keeps the built-in default; beside the EXPLICIT-none sentinel it cannot, so the
        default slugs are subtracted with --exclude-services instead."""
        a: list[str] = []
        svcs = list(self.optional_services or [])
        excl = list(self.exclude_services or [])
        mode = self._anubis_mode(self.anubis)
        if mode == "on":
            svcs = [s for s in svcs if s not in (ANUBIS_OFF_TOKEN, "no-anubis")]
            if SERVICES_ALL in svcs:
                # the builders' `all` expansion keeps deselect tokens but DROPS a
                # positive slug, so spell the set out (with_service_slug does).
                svcs = [s for s in svcs if s != ANUBIS_SLUG]
            svcs = with_service_slug(svcs, ANUBIS_SLUG)
        elif mode == "off":
            svcs = [s for s in svcs if s != ANUBIS_SLUG]
            if svcs == [SERVICES_NONE]:
                # none + veto: a lone veto would give the defaults back, so say "none"
                # the other way — keep the veto and subtract the default slugs.
                svcs = [ANUBIS_OFF_TOKEN]
                excl += [s for s in BUILTIN_DEFAULT_SERVICES if s not in excl]
            elif not any(s in (ANUBIS_OFF_TOKEN, "no-anubis") for s in svcs):
                svcs.append(ANUBIS_OFF_TOKEN)
        if svcs == [SERVICES_NONE]:
            a += ["--optional-services", ""]           # EXPLICIT none (suppress the builder default)
        elif SERVICES_ALL in svcs and mode != "off":
            a += ["--all-services"]                    # full user-level set
        elif svcs:
            # SPACE-separated: the builders word-split OPTIONAL_SERVICES on IFS
            # whitespace (it stays ONE argv element — shlex.quote on print).
            a += ["--optional-services", " ".join(svcs)]
        if excl:
            a += ["--exclude-services", " ".join(excl)]
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

    def _vault_args(self) -> list[str]:
        """--vault-addr [--vault-external-addr] — the mesh secrets store (#224, split
        internal/external in #335; parsed by the x86 + rpi5 node builders ONLY).
        Emitted ONLY when the INTERNAL address is set: the empty default
        (offline/USB-only delivery) emits NOTHING, so every existing flow's argv stays
        byte-identical. validate_identity() already fail-closed the combination +
        charset before emission; the external address rides only when it is set.

        NOTHING is emitted for the KV mount or the base path: those two flags are gone
        (#285, decision 22 — the mount and the read prefix are both pinned by the
        shipped ClusterSecretStore), and the
        builders no longer parse them, so emitting either would be an "Unknown option"
        abort rather than a dead knob.

        NOTHING is emitted for base_ca_certs / domain_ca: no builder parses a CA flag.
        They are recorded in the saved config and read by the two GUI/TUI faces, and
        the copy on both says so."""
        if not self.vault_addr:
            return []
        a = ["--vault-addr", self.vault_addr]
        if self.vault_external_addr:
            a += ["--vault-external-addr", self.vault_external_addr]
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
        if self.cluster_domain != "hugmesh.net":
            a += ["--cluster-domain", self.cluster_domain]
        # Tailscale root domain — mesh-only, grouped with the cluster/mesh identity
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
        if self.standalone or self.local_user != default_local_user() or self.local_pass:
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
            a += self._compress_level_args()
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

    def _ram_gb_args(self) -> list[str]:
        """--ram-gb N for a Pi / Orange Pi NODE role, when the RAM was stated. A desktop
        or the Pi's generic server has no RAM floor, so nothing is emitted for them."""
        ram = str(self.ram_gb or "").strip()
        if not ram or image_class(self.mode, self.role) == "desktop" or self.role == "generic":
            return []
        return ["--ram-gb", ram]

    def _rpi5_args(self) -> list[str]:
        """build-rpi5-stage4.sh — arm64: pki | backend | frontend (cluster nodes)
        or desktop (client; compose with --standalone for FDE, no mesh). --board
        (RPI_BOARDS: rpi5 [DEFAULT] | rpi4 | rpi3) picks the board table
        (Phase 6 Pi 4 support, Phase 8 Pi 3 support) — ONE builder, mirrors
        _jetson_args()'s board handling. rpi3 is DESKTOP-ONLY (1GB RAM): the
        builder hard-errors if role != desktop; this method does not
        pre-validate that combo, same as it doesn't for any other builder
        constraint (the shell script is the single source of truth there)."""
        # roles.builder_role() resolves a COMPOSITE id (rpi5-desktop -> desktop, the
        # platform half already spent on picking this method) and is otherwise the
        # identity: the Studio id IS the builder token now.
        a = ["--role", roles.builder_role(self.role, "rpi5")]
        if self.board:                 # rpi5 | rpi4 | rpi3 ("" = builder default: rpi5)
            a += ["--board", self.board]
        a += self._ram_gb_args()
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
        # mesh secrets store (#224) — same two-node-builder surface, same
        # empty-default-emits-nothing rule.
        a += self._vault_args()
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
        if self.role in _ORANGEPI_NODE_ROLE_IDS:
            # Cluster NODE role (EXPERIMENTAL): --role + the board's RAM, installer
            # flavor only (the builder refuses live/both for a node).
            a = ["--board", self.board or "orange-pi-5-plus", "--flavor", "installer",
                 "--role", roles.builder_role(self.role, "orangepi5")]
            a += self._ram_gb_args()
            if self.dtb:
                a += ["--dtb", self.dtb]
            a += self._uboot_args()
            a += self._arm_common_args()
            a += self._encrypt_root_args()
            if self.image_only:
                a += ["--image-only"]
            a += self._orangepi_node_cluster_args()
            return a
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

    def _orangepi_node_cluster_args(self) -> list[str]:
        """The mesh's cluster choices on an Orange Pi NODE role (EXPERIMENTAL): the
        same release-state / games-domain / optional-services / IdP / Vault surface
        _rpi5_args emits, so a mesh mixing Pi and Orange Pi nodes bakes ONE set of
        choices. Every default emits nothing. Never called for the Orange Pi desktop
        (its builder refuses these flags: no cluster tree is baked there)."""
        a: list[str] = []
        if self.release_state:
            a += ["--release-state", self.release_state]
        if self.games_domain:
            a += ["--games-domain", self.games_domain]
        a += self._services_args()
        if self.enable_games:
            a += ["--enable-games"]
        a += self._idp_args()
        a += self._vault_args()
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
        See specs-orangepi4-lts/README.md.

        The ``frontend`` role is its one cluster NODE role (EXPERIMENTAL; 4 GB RAM,
        16 GB eMMC): --role frontend, installer flavor only."""
        if self.role in _ORANGEPI_NODE_ROLE_IDS:
            a = ["--flavor", "installer", "--role", roles.builder_role(self.role, "orangepi4-lts")]
            a += self._ram_gb_args()
            if self.dtb:
                a += ["--dtb", self.dtb]
            a += self._uboot_args()
            a += self._arm_common_args()
            a += self._encrypt_root_args()
            if self.image_only:
                a += ["--image-only"]
            a += self._orangepi_node_cluster_args()
            return a
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
        validation pending): frite flag conventions + --role edge-ai|omnibus|
        backend-gpu|desktop and --board JETSON_BOARDS (specs-jetson/README.md). Anything beyond
        that goes via extra_flags."""
        self._check_jetson_conflicts()
        a = ["--role", roles.builder_role(self.role, "jetson")]
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
        bake a brand IDENTITY, the bundled HugMesh source, the stack seed, or platform
        machinery (mesh/SSO/person-device identity) into the image raises ValueError
        HERE — so --print-command and the GUI preview fail loudly with the same contract
        the builder enforces (it exits non-zero on the equivalent flags; an explicit
        --brand gentoo errors too — the builder forces the neutral identity itself).

        IDENTITY vs LOOK — the 2026-08-26 split, and the reason this docstring's "mirror"
        claim is still true. The operator's report, verbatim: "There should be the menu
        for adding the themes as in the branded images". Their image is
        role=standalone-unaffiliated / platform=x86 (session 20260826-151356-64070a).
        Until this change ALL TEN branding fields were lumped into one "branding assets"
        conflict, which is what made a theme illegal and, in turn, what made
        BrandingPage.applies_to() drop the whole page (and the theme menu with it) from
        the flow. The operator's decision: a BRAND is an affiliation, a WALLPAPER is not.

          FORBIDDEN (identity): brand / brand_title / org (above) + brand_logo +
            brand_locked. A LOGO is the mark of an organization — the builder feeds
            BRAND_LOGO into plymouth/lightdm/GRUB/ISO artwork, so baking one IS declaring
            an affiliation. --brand-locked exists solely to make a BRAND unremovable by
            the user; with no brand baked it would lock nothing, so accepting it would
            advertise a knob that cannot act.
          ALLOWED (look): theme / branding_dir / wallpaper / grub_background / grub_theme /
            login_background / accent_color / color_scheme. These are desktop appearance
            and carry no identity of their own.

        THE BUILDER SPLIT HAS LANDED — this is no longer "in progress", and the line
        numbers moved with it. build-x86-host-stage4.sh's unaffiliated fold now runs
        TWO identity checks and no look check at all:
          :1383-1385  brand/brand_title/org (and any --config brand profile) — the
                      original check, untouched by the split;
          :1398-1400  --brand-logo / --brand-locked — NEW, carrying the eight allowed
                      LOOK flags in its own error text so the operator is told what IS
                      legal at the moment they hit the wall.
        The eight LOOK flags are not tested there any more. Keep the two sides in step: this function's whole value is that a config Studio accepts is a
        config the builder accepts. Note the LOOK flags need NO emission change to become
        live — _x86_args emits them from a block that was already OUTSIDE the
        `if not unaffiliated:` brand-plane gate, so the ValueError was the only thing
        stopping them; deleting it makes --theme reach the builder rather than being
        silently dropped."""
        conflicts: list[str] = []
        if (self.brand != "hugmesh" or self.brand_title != "HugMesh Systems"
                or self.org != "hugmesh"):
            conflicts.append("a brand identity (brand/brand_title/org — the builder "
                             "forces the neutral gentoo identity itself)")
        identity_assets = (["brand_logo"] if self.brand_logo else []) \
                        + (["brand_locked"] if self.brand_locked else [])
        if identity_assets:
            conflicts.append(
                "brand identity assets (" + ", ".join(identity_assets)
                + " — a logo is an organization's mark and --brand-locked locks a brand "
                  "this image does not have; see build-x86-host-stage4.sh:1578-1580)")
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
        # Delegated to the module predicate rather than restated: gui/pages/branding.py
        # and gui/pages/home.py gate their surfaces on the SAME rule, and the inline copy
        # that used to live here was the third spelling of it.
        unaffiliated = unaffiliated_image(self)
        if unaffiliated:
            self._check_unaffiliated_conflicts()
        a: list[str] = ["--role", roles.builder_role(self.role, "x86"),
                        "--env", self.env, "--local-user", self.local_user]
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
            if self.cluster_domain != "hugmesh.net":
                a += ["--cluster-domain", self.cluster_domain]
            # Tailscale root domain — mesh-only (see _superdomain_args), emitted for
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
                    # the first row's TIER (issue #228): a multi-role account maps to the
                    # highest of the four tiers it holds; a grants-only account (games)
                    # is a plain user here — the builder accepts exactly the four tiers.
                    person = self.users[0].tier if self.users else "user"
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
        if self.role != "edge-ai":
            if edge == "on":
                a += ["--with-edge-ai"]
            elif edge == "off":
                a += ["--no-edge-ai"]
        if self.role == "edge-ai" or edge == "on":
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

        # mesh secrets store (#224). Empty address = ZERO emission (byte-identity);
        # a set one threads the vault trio the builder bakes into vault.conf.
        a += self._vault_args()

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
            a += self._compress_level_args()
        if self.resume:
            a += ["--resume"]

        return a

    def to_command_string(self) -> str:
        return "./%s -w OUT -j %d %s" % (
            self.builder_script, self.jobs, " ".join(shlex.quote(x) for x in self.to_cli_args()))

    def own_idp_domains(self) -> tuple[str, ...]:
        """Names of the domains that chose to HOST THEIR OWN Casdoor (Domain.idp ==
        "own" with no external provider — ``runs_own_casdoor``; issue #47), in
        Domains-table order — the order the compose lane's
        port allocation (core/own_casdoor.py: 8001, 8002, …) is derived from, and
        the k8s/ArgoCD lane's input once it lands. Empty on every pre-#47 config."""
        return tuple(d.name for d in self.domains if runs_own_casdoor(d))

    # ---- superadmin mesh manifest -----------------------------------------
    def mesh_manifest(self) -> dict[str, Any]:
        """The domains + users a superadmin defined, as a portable manifest, now carrying
        the effective Tailscale root domain (§2.6). This is the v1+superdomain shim for
        the SINGLE-image path; the full manifest v2 envelope ({"format":2,...,"images":[…]})
        is written once-per-worklist by the driver (WS-ENGINE). Consumed by cluster
        provisioning (Casdoor seed + per-domain config) — separate from the image
        build, which is why it is emitted as its own artifact rather than CLI flags.

        The per-domain ``idp`` key (issue #47) is OMIT-WHEN-DEFAULT: a domain riding
        the superdomain Casdoor emits no key at all, so a superdomain-only manifest is
        byte-identical to before the field existed and absent == superdomain stays the
        one backward-compatible reading for every consumer (old manifests provision
        identically; test_domain_idp_schema.py pins the exact golden bytes)."""
        return {
            # The header is a projection of the record's superbrand block (#654, D5):
            # the SAME function manifest_v2 calls, so the two emitters agree.
            **brand_header_fields(self.brand, self.brand_title, self.org,
                                  self.cluster_domain, self.effective_superdomain(),
                                  self.login_style, self.login_decor),
            # per-domain ``tor`` (#582), ``look``/``ways``/``issuer_port`` (#654) and
            # ``github_org`` (the export step) are
            # OMIT-WHEN-EMPTY the same way: a domain that uses none emits no key, so
            # pre-#582 bytes never change. ONE row writer for both emitters.
            "domains": manifest_domain_rows(self.domains),
            # per-user ``roles`` (issue #228) is OMIT-WHEN-SINGLE the same way (User.to_dict):
            # ``role`` stays the primary every consumer reads; a multi-role account adds
            # the full list beside it. test_user_multi_role.py pins both shapes.
            "users": [u.to_dict() for u in self.users],
            # the mesh's OWN domain's per-domain services (#494) — OMIT-WHEN-EMPTY, so
            # a manifest whose own domain takes the cluster-wide set keeps its bytes.
            **({"cluster_domain_services": list(self.cluster_domain_services)}
               if self.cluster_domain_services else {}),
            # the own domain's export org (the Go-Live export step) — OMIT-WHEN-EMPTY
            **({"cluster_domain_github_org": self.cluster_domain_github_org.strip()}
               if (self.cluster_domain_github_org or "").strip() else {}),
        }

    def write_mesh_manifest(self, output_dir: str) -> str:
        import os
        os.makedirs(output_dir, exist_ok=True)
        path = os.path.join(output_dir, "hugmesh-mesh-manifest.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(self.mesh_manifest(), fh, indent=2)
        return path

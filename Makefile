# Snapdragon-Systems image build / flash / emulate / test orchestrator.
#
# Front door over the build scripts and tooling. Every target just invokes the
# underlying script with the right flags, so the flags remain the engine and
# `make` is the friendly interface.
#
#   build-rpi5-stage4.sh      aarch64 (RPi5/RPi4/RPi3, RPI_BOARD=rpi5|rpi4|rpi3 — rpi3 desktop-only) cross-build -> .img + .fs.tar.xz
#   build-x86-host-stage4.sh  amd64 multi-role build      -> .img + live ISO + .fs.tar.xz
#   build-frite-stage4.sh     aarch64 (Amlogic) light desktop -> live/installer ISO
#   build-jetson-stage4.sh    aarch64 (Tegra234 Orin) edge-AI node -> .img (EXPERIMENTAL)
#   build-orangepi5-stage4.sh aarch64 (Rockchip RK3588/RK3588S) light desktop -> live/installer ISO (EXPERIMENTAL)
#   build-orangepi-zero2-stage4.sh aarch64 (Allwinner H616) HEADLESS APPLIANCE -> live/installer ISO (EXPERIMENTAL)
#   build-orangepi-zero2w-stage4.sh aarch64 (Allwinner H618) HEADLESS APPLIANCE -> live/installer ISO (EXPERIMENTAL)
#   build-orangepi-zero3-stage4.sh aarch64 (Allwinner H618) HEADLESS APPLIANCE -> live/installer ISO (EXPERIMENTAL)
#   build-orangepi3-lts-stage4.sh  aarch64 (Allwinner H6) HEADLESS APPLIANCE -> live/installer ISO (EXPERIMENTAL)
#   build-orangepi4-lts-stage4.sh  aarch64 (Rockchip RK3399) LIGHT DESKTOP -> live/installer ISO (EXPERIMENTAL)
#   scripts/build-all-roles.sh   the default fleet (3 Pi + x86 pki/be/fe/be+gpu)
#                                (+ FRITE=1 / JETSON=1 / build-everything for the full matrix)
#   scripts/flash-disk.sh        write a role image (.img preferred, else .iso) to a disk
#   tests/qemu/launch-pi.sh      boot a Pi   image in QEMU (aarch64 -M virt)
#   tests/qemu/launch-x86.sh     boot an x86 image in QEMU (q35 + OVMF + KVM)
#   tests/qemu/run-qemu-e2e.sh   boot a role VM + run the Playwright e2e with the e2e accounts
#
# ── BUILD PATH (Phase 5) ──────────────────────────────────────────────────────
# DEFAULT  = Docker: the build runs INSIDE the self-contained Gentoo builder
#            image (Dockerfile.build). The HOST needs NO build toolchain and NO
#            sudo. Run `make docker-image` once (LONG: it compiles the aarch64
#            cross-toolchain), then `make build-all` / `make rebuild` / etc.
# NATIVE=1 = local Gentoo: run the scripts directly on the host (or inside the
#            container, where this is the path taken). Uses sudo ONLY when not
#            already root — inside the container (root) no sudo is used.
#
# Common overrides:  WORK_DIR=$(CURDIR)/out  JOBS=$(nproc)  ROLE=be+gpu  ARCH=x86  DEV=/dev/sdX
# Image format:      pass IMG_FLAGS='--no-iso' (img only) or '--no-img' (iso only) etc.
# Branding:          make build-all BRAND=acme DOMAIN=acme.example  (-> brands/acme.conf)
#
# Products land in a local, gitignored ./out by default (WORK_DIR=$(CURDIR)/out).
# Each arch's heavy build tree (sysroot/distfiles/pkgdir) lives in a PER-ARCH
# subdir under WORK_DIR — snap-build-pi5 (aarch64) and snap-build-x86 (amd64) —
# so the Pi and x86 builds never share a sysroot. Products (.img/.iso/keys-*)
# still land in WORK_DIR itself. `make clean` wipes WORK_DIR (subdirs included).

SHELL    := /bin/bash
WORK_DIR ?= $(CURDIR)/out
JOBS     ?= $(shell nproc)
ROLE     ?= be+gpu
ARCH     ?= x86
DEV      ?=
IMG_FLAGS ?=
# Root SSH login: empty/no => DISABLED by default (hardened) on every image; set
# PERMIT_ROOT_LOGIN=yes|prohibit-password to opt in. Threaded to the builders via BRAND_ENV.
PERMIT_ROOT_LOGIN ?=

# ── Pen-test build OPTION (DEV / CI-pipeline only) ─────────────────────────────
# PENTEST=1 runs the OWASP pen-test harness as part of a build (NOT a deployed
# runner; public images via tests/pentest/run-pentest.sh). PENTEST_ONLY=1 runs ONLY
# the pen-test (no image builds). Knobs map onto run-pentest.sh:
#   PENTEST_ENV=compose|local|cluster  PENTEST_SCAN=baseline|full  PENTEST_PIPELINE=main|games
#   make build-all PENTEST=1            # build the fleet THEN pen-test it
#   make pentest                        # pen-test only (no image build)
#   make pentest PENTEST_SCAN=full PENTEST_ENV=local
PENTEST          ?=
PENTEST_ONLY     ?=
PENTEST_ENV      ?= compose
PENTEST_SCAN     ?= baseline
PENTEST_PIPELINE ?= main
# Threaded into scripts/build-all-roles.sh (which reads these from the env) on the
# native leg, and forwarded into the in-container `make` re-invoke on the Docker leg.
PENTEST_ENVVARS := PENTEST='$(PENTEST)' PENTEST_ONLY='$(PENTEST_ONLY)' \
                   PENTEST_ENV='$(PENTEST_ENV)' PENTEST_SCAN='$(PENTEST_SCAN)' \
                   PENTEST_PIPELINE='$(PENTEST_PIPELINE)'

# ── build-all-roles.sh ROLE-SELECTOR env knobs ─────────────────────────────────
# build-all-roles.sh reads these from the ENVIRONMENT to pick the fleet
# (FRITE/FRITE_ONLY add the Frite; X86_OMNIBUS/X86_ALL/X86_ROLES pick the x86 set;
# X86_STANDALONE appends the 3 standalone desktops, X86_STANDALONE_ONLY builds
# JUST them; SKIP_X86/SKIP_KEYS drop work). They default EMPTY so a plain build keeps the
# script's own defaults; `?=` lets `X86_OMNIBUS=1 make build-all` (env) and
# `make build-all X86_OMNIBUS=1` (CLI) both set them. Threaded onto the native
# leg via $(ALL) and forwarded into the in-container `make` re-invoke (Docker leg)
# exactly like PENTEST_ENVVARS — otherwise the Docker path silently drops them and
# builds only the default fleet while echoing the requested roles past.
FRITE       ?=
FRITE_ONLY  ?=
JETSON      ?=
JETSON_ONLY ?=
JETSON_ROLES ?=
ORANGEPI5      ?=
ORANGEPI5_ONLY ?=
ORANGEPIZERO2      ?=
ORANGEPIZERO2_ONLY ?=
ORANGEPIZERO2W      ?=
ORANGEPIZERO2W_ONLY ?=
ORANGEPIZERO3      ?=
ORANGEPIZERO3_ONLY ?=
X86_OMNIBUS ?=
X86_ALL     ?=
X86_ROLES   ?=
X86_STANDALONE ?=
X86_STANDALONE_ONLY ?=
SKIP_X86    ?=
SKIP_RPI    ?=
SKIP_KEYS   ?=
# NOTE: this is `:=` and expands here, BEFORE the FRITE_*/JETSON_*/ORANGEPI5_*
# `?=` defaults below — so a value reaches build-all-roles.sh only when the
# caller sets it (CLI/env); an empty assignment is fine (the script's own
# `${VAR:-default}` fallbacks catch empty exactly like unset). RPI_BOARD/
# RPI_ROLES/SKIP_RPI and ORANGEPIZERO2* MUST be here too — a prior version of
# this list omitted them, so `make build-everything RPI_BOARD=rpi4 ...` (or
# ORANGEPIZERO2=1) silently built only the default rpi5/pki+backend+frontend
# Pi set and dropped Orange Pi Zero 2 entirely, on BOTH the native leg ($(ALL)
# invoking build-all-roles.sh directly) and the Docker leg (the value never
# survives the docker-run process boundary since only what's listed here is
# baked as literal args into the in-container `make` re-invoke).
ROLESET_ENVVARS := FRITE='$(FRITE)' FRITE_ONLY='$(FRITE_ONLY)' \
                   FRITE_BOARD='$(FRITE_BOARD)' FRITE_FLAVOR='$(FRITE_FLAVOR)' \
                   FRITE_DESKTOP='$(FRITE_DESKTOP)' \
                   JETSON='$(JETSON)' JETSON_ONLY='$(JETSON_ONLY)' JETSON_ROLES='$(JETSON_ROLES)' \
                   JETSON_BOARD='$(JETSON_BOARD)' JETSON_KERNEL_FLAVOR='$(JETSON_KERNEL_FLAVOR)' \
                   ORANGEPI5='$(ORANGEPI5)' ORANGEPI5_ONLY='$(ORANGEPI5_ONLY)' \
                   ORANGEPI5_BOARD='$(ORANGEPI5_BOARD)' ORANGEPI5_FLAVOR='$(ORANGEPI5_FLAVOR)' \
                   ORANGEPIZERO2='$(ORANGEPIZERO2)' ORANGEPIZERO2_ONLY='$(ORANGEPIZERO2_ONLY)' \
                   ORANGEPIZERO2_FLAVOR='$(ORANGEPIZERO2_FLAVOR)' \
                   ORANGEPIZERO2W='$(ORANGEPIZERO2W)' ORANGEPIZERO2W_ONLY='$(ORANGEPIZERO2W_ONLY)' \
                   ORANGEPIZERO2W_FLAVOR='$(ORANGEPIZERO2W_FLAVOR)' \
                   ORANGEPIZERO3='$(ORANGEPIZERO3)' ORANGEPIZERO3_ONLY='$(ORANGEPIZERO3_ONLY)' \
                   ORANGEPIZERO3_FLAVOR='$(ORANGEPIZERO3_FLAVOR)' \
                   ORANGEPI3LTS='$(ORANGEPI3LTS)' ORANGEPI3LTS_ONLY='$(ORANGEPI3LTS_ONLY)' \
                   ORANGEPI3LTS_FLAVOR='$(ORANGEPI3LTS_FLAVOR)' \
                   ORANGEPI4LTS='$(ORANGEPI4LTS)' ORANGEPI4LTS_ONLY='$(ORANGEPI4LTS_ONLY)' \
                   ORANGEPI4LTS_FLAVOR='$(ORANGEPI4LTS_FLAVOR)' \
                   RPI_BOARD='$(RPI_BOARD)' RPI_ROLES='$(RPI_ROLES)' SKIP_RPI='$(SKIP_RPI)' \
                   X86_OMNIBUS='$(X86_OMNIBUS)' X86_ALL='$(X86_ALL)' X86_ROLES='$(X86_ROLES)' \
                   X86_STANDALONE='$(X86_STANDALONE)' X86_STANDALONE_ONLY='$(X86_STANDALONE_ONLY)' \
                   SKIP_X86='$(SKIP_X86)' SKIP_KEYS='$(SKIP_KEYS)'

# ── Build ENV selector (BAKED at image creation) ───────────────────────────────
# ENV=test (DEFAULT, local-first/safe): LAN-only — cluster wildcard DNS app kept,
#          cloudflared/ACME go-live app pruned from the baked tree, no public
#          internet / OAuth / SMTP needed.
# ENV=prod: bakes the REAL public domain (Cloudflare/ACME kept, creds from the
#          keys USB). The builders print a LOUD announced banner for prod.
# Convenience: `make local` (ENV=test, BRAND=local) / `make prod` (ENV=prod).
ENV      ?= test

# ── Branding (different brand + domain + its own mesh) ─────────────────────────
# BRAND=<name>   select the committed brand profile brands/<name>.conf (sourced by
#                the builders via --config). See brands/README.md + brands/example.conf.
# DOMAIN=<dom>   override the brand's CLUSTER_DOMAIN (threaded as --cluster-domain;
#                an explicit flag overrides the profile).
# HEADSCALE_URL= override the brand's own headscale control server (its own mesh).
#                Passed through as an env var the brand/mesh setup honors.
# Usage:  make build-all BRAND=acme DOMAIN=acme.example
BRAND     ?=
DOMAIN    ?=
HEADSCALE_URL ?=

# ── External CA (optional) ─────────────────────────────────────────────────────
# Point the cert generators at an EXISTING CA (cert + key) to use it as the
# issuer for every generated leaf/service cert instead of minting a fresh
# self-signed root. The generators (scripts/gen-provision-keys.sh /
# gen-keystores.sh) read these from the ENVIRONMENT, so they are exported below
# and forwarded into the Docker-dispatch re-invoke. Unset = self-signed root.
#   make ... CA_CERT=/path/ca.crt CA_KEY=/path/ca.key [CA_KEY_PASS=...]
# CA_KEY / CA_KEY_PASS are secrets — pass them on the command line / env, never
# commit them. They are forwarded but NEVER echoed by the build.
CA_CERT     ?=
CA_KEY      ?=
CA_KEY_PASS ?=
export CA_CERT CA_KEY CA_KEY_PASS

# BRAND_FLAGS — threaded into every builder invocation when BRAND is set.
# --config selects the profile; --cluster-domain (a real builder flag, so it
# overrides the sourced profile) applies the DOMAIN override.
BRAND_FLAGS :=
ifneq ($(strip $(BRAND)),)
BRAND_FLAGS += --config brands/$(BRAND).conf
endif
ifneq ($(strip $(DOMAIN)),)
BRAND_FLAGS += --cluster-domain $(DOMAIN)
endif

# ENV_FLAGS — the baked build ENV (test|prod), threaded into every builder
# invocation. --env is a real builder flag, so it overrides any profile default.
ENV_FLAGS := --env $(ENV)

# BRAND_ENV — leading VAR=val env assignments for things the builders read from
# the profile/env rather than a CLI flag (the brand's own mesh control server).
BRAND_ENV :=
ifneq ($(strip $(HEADSCALE_URL)),)
BRAND_ENV += HEADSCALE_URL=$(HEADSCALE_URL)
endif
# Root SSH login toggle (empty => builder default 'no' = DISABLED). Only threaded when
# explicitly set, so every image stays hardened-by-default unless opted in.
ifneq ($(strip $(PERMIT_ROOT_LOGIN)),)
BRAND_ENV += PERMIT_ROOT_LOGIN=$(PERMIT_ROOT_LOGIN)
endif

# BRAND_PASS — brand make-vars forwarded into the in-container `make` re-invoke
# (the Docker dispatch path) so BRAND_FLAGS/BRAND_ENV are rebuilt identically
# inside the builder image. brands/ is mounted at /src/brands via -v $(CURDIR):/src.
BRAND_PASS := BRAND='$(BRAND)' DOMAIN='$(DOMAIN)' HEADSCALE_URL='$(HEADSCALE_URL)' ENV='$(ENV)' PERMIT_ROOT_LOGIN='$(PERMIT_ROOT_LOGIN)'

# ── Docker-vs-native dispatch ─────────────────────────────────────────────────
# IMAGE        the builder image tag (build it with `make docker-image`).
# HOST_UID/GID the invoking user — passed into the container so a NATIVE build
#              can chown the root-created artifacts back to them.
# SUDO         only `sudo` when NOT already root. Inside the container (root)
#              SUDO is empty, so the native scripts run sudo-free.
IMAGE    ?= hugmesh-builder
HOST_UID := $(shell id -u)
HOST_GID := $(shell id -g)
SUDO     := $(shell [ "$$(id -u)" = 0 ] || echo sudo)

# External-CA mount (Docker leg). CA_CERT/CA_KEY are HOST paths; only $(CURDIR)
# and $(WORK_DIR) are bind-mounted, so a CA outside the repo tree does NOT exist
# in-container — gen-keystores.sh validate_external_ca then exits 'CA not readable'
# and (pre-fix) build-all-roles.sh swallowed it into a warn, shipping keys WITHOUT
# the requested external CA. Mount each set CA file read-only at a fixed in-container
# path and pass THAT path as the env var, so external-CA builds work from any path.
# Unset = self-signed root: forward the (empty) env vars as before.
CA_DOCKER_MOUNTS :=
CA_DOCKER_ENV    := -e CA_CERT -e CA_KEY -e CA_KEY_PASS
ifneq ($(strip $(CA_CERT)),)
CA_DOCKER_MOUNTS += -v $(abspath $(CA_CERT)):/ca/ca.crt:ro
CA_DOCKER_ENV    := -e CA_CERT=/ca/ca.crt -e CA_KEY_PASS
ifneq ($(strip $(CA_KEY)),)
CA_DOCKER_MOUNTS += -v $(abspath $(CA_KEY)):/ca/ca.key:ro
CA_DOCKER_ENV    := -e CA_CERT=/ca/ca.crt -e CA_KEY=/ca/ca.key -e CA_KEY_PASS
endif
endif

# Launch the builder image: privileged (build_img needs /dev/loop + mount),
# repo at /src, output at /out, and the invoking uid/gid forwarded so the
# in-container NATIVE build can chown artifacts back to the host user.
DOCKER_RUN := docker run --rm --privileged \
  -v $(CURDIR):/src -v $(WORK_DIR):/out -w /src \
  -e HOST_UID=$(HOST_UID) -e HOST_GID=$(HOST_GID) \
  -e STANDALONE_FLAGS \
  $(CA_DOCKER_MOUNTS) $(CA_DOCKER_ENV) $(IMAGE)

# ensure-image — auto-build the builder image if it is missing.
ensure-image:
	@docker image inspect $(IMAGE) >/dev/null 2>&1 \
	  || { echo "==> builder image '$(IMAGE)' missing — building it (first run is LONG)"; $(MAKE) docker-image; }

# chown-artifacts — after a NATIVE (root) build, hand the artifacts back to the
# invoking host user so host-side qemu/flash/read need no sudo. HOST_UID is set
# by DOCKER_RUN (the default path); on a bare host run it is the caller's own
# uid, so the chown is a harmless no-op.
define chown-artifacts
	@[ -n "$(HOST_UID)" ] && $(SUDO) chown -R $(HOST_UID):$(HOST_GID) "$(WORK_DIR)" 2>/dev/null || true
endef

# RPi5/RPi4/RPi3 board axis (--board rpi5|rpi4|rpi3 on build-rpi5-stage4.sh; ONE
# builder, extended with a board table rather than a separate script — all
# three share the Raspberry Pi Foundation boot model closely enough). Default
# rpi5 keeps every existing `make rpi` / `make rpi-<role>` invocation 100%
# unaffected. RPI_BOARD=rpi3 is DESKTOP-ONLY (1GB RAM) — the builder
# hard-errors if combined with any role but desktop, so `make rpi-desktop
# RPI_BOARD=rpi3` is the only valid rpi3 single-role invocation (the bare
# `rpi` 3-role fleet target, which never includes desktop, would hard-error on
# its very first role with RPI_BOARD=rpi3 — use rpi-desktop instead).
RPI_BOARD ?= rpi5

# Native build commands (run as-is inside the container or on local Gentoo).
# BRAND_ENV prefixes the brand's own-mesh env (HEADSCALE_URL); BRAND_FLAGS adds
# --config brands/<BRAND>.conf (+ --cluster-domain DOMAIN). build-all-roles.sh
# passes BRAND_FLAGS through to BOTH builders via its "$@" passthrough.
RPI := $(BRAND_ENV) $(SUDO) ./build-rpi5-stage4.sh -w $(WORK_DIR) -j $(JOBS) --board $(RPI_BOARD) $(IMG_FLAGS) $(ENV_FLAGS) $(BRAND_FLAGS)
X86 := $(BRAND_ENV) $(SUDO) ./build-x86-host-stage4.sh -w $(WORK_DIR) -j $(JOBS) $(IMG_FLAGS) $(ENV_FLAGS) $(BRAND_FLAGS)
FRITE_BUILD := $(BRAND_ENV) $(SUDO) ./build-frite-stage4.sh -w $(WORK_DIR) -j $(JOBS) $(IMG_FLAGS) $(ENV_FLAGS) $(BRAND_FLAGS)
JETSON_BUILD := $(BRAND_ENV) $(SUDO) ./build-jetson-stage4.sh -w $(WORK_DIR) -j $(JOBS) $(IMG_FLAGS) $(ENV_FLAGS) $(BRAND_FLAGS)
ORANGEPI5_BUILD := $(BRAND_ENV) $(SUDO) ./build-orangepi5-stage4.sh -w $(WORK_DIR) -j $(JOBS) $(IMG_FLAGS) $(ENV_FLAGS) $(BRAND_FLAGS)
ORANGEPIZERO2_BUILD := $(BRAND_ENV) $(SUDO) ./build-orangepi-zero2-stage4.sh -w $(WORK_DIR) -j $(JOBS) $(IMG_FLAGS) $(ENV_FLAGS) $(BRAND_FLAGS)
ORANGEPIZERO2W_BUILD := $(BRAND_ENV) $(SUDO) ./build-orangepi-zero2w-stage4.sh -w $(WORK_DIR) -j $(JOBS) $(IMG_FLAGS) $(ENV_FLAGS) $(BRAND_FLAGS)
ORANGEPIZERO3_BUILD := $(BRAND_ENV) $(SUDO) ./build-orangepi-zero3-stage4.sh -w $(WORK_DIR) -j $(JOBS) $(IMG_FLAGS) $(ENV_FLAGS) $(BRAND_FLAGS)
ORANGEPI3LTS_BUILD := $(BRAND_ENV) $(SUDO) ./build-orangepi3-lts-stage4.sh -w $(WORK_DIR) -j $(JOBS) $(IMG_FLAGS) $(ENV_FLAGS) $(BRAND_FLAGS)
ORANGEPI4LTS_BUILD := $(BRAND_ENV) $(SUDO) ./build-orangepi4-lts-stage4.sh -w $(WORK_DIR) -j $(JOBS) $(IMG_FLAGS) $(ENV_FLAGS) $(BRAND_FLAGS)
ALL := $(ROLESET_ENVVARS) $(PENTEST_ENVVARS) $(BRAND_ENV) $(SUDO) ./scripts/build-all-roles.sh -j $(JOBS) -w $(WORK_DIR) $(ENV_FLAGS) $(BRAND_FLAGS)

RPI_ROLES := pki backend frontend
# X86_ROLE_LIST: the role list the local `x86` target loops over. Deliberately NOT
# named X86_ROLES: that is a build-all-roles.sh ENV KNOB (see ROLESET_ENVVARS) and
# a same-named := make-var would shadow a user's `X86_ROLES=... make build-all`.
X86_ROLE_LIST := pki be fe be+gpu
# X86_EVERY_ROLE: the FULL documented x86 matrix (nodes + omnibus + edge_ai +
# the client devices + the standalone desktops, incl. the UNAFFILIATED plain
# Gentoo one) — what `make build-everything` threads through
# build-all-roles.sh's X86_ROLES knob.
X86_EVERY_ROLE := pki be fe be+gpu omnibus edge_ai laptop chromebook desktop standalone-thin standalone-thick standalone-unaffiliated

# Libre Computer Le/La Frite LIGHT-DESKTOP client image (Amlogic arm64).
#   FRITE_BOARD   = la-frite (DEFAULT) | le-potato | sweet-potato
#   FRITE_FLAVOR  = both (DEFAULT) | live | installer
#   FRITE_DESKTOP = light (DEFAULT, the lean LXDE set) | none (headless)
FRITE_BOARD   ?= la-frite
FRITE_FLAVOR  ?= both
FRITE_DESKTOP ?= light
FRITE_PASS    := FRITE_BOARD='$(FRITE_BOARD)' FRITE_FLAVOR='$(FRITE_FLAVOR)' FRITE_DESKTOP='$(FRITE_DESKTOP)'

# NVIDIA Jetson Orin (Tegra234 arm64) edge-AI platform — EXPERIMENTAL (hardware
# validation pending; see specs-jetson/README.md). FRITE-style vars:
#   JETSON_ROLE          = edge_ai (DEFAULT, headline) | gpu-host | full | desktop
#   JETSON_BOARD         = orin-nano (DEFAULT) | orin-nano-4gb | orin-nx-8gb | orin-nx-16gb
#   JETSON_KERNEL_FLAVOR = mainline (DEFAULT, buildable — NO CUDA) | l4t (stub)
JETSON_ROLE          ?= edge_ai
JETSON_BOARD         ?= orin-nano
JETSON_KERNEL_FLAVOR ?= mainline
JETSON_PASS := JETSON_ROLE='$(JETSON_ROLE)' JETSON_BOARD='$(JETSON_BOARD)' \
               JETSON_KERNEL_FLAVOR='$(JETSON_KERNEL_FLAVOR)'

# Orange Pi 5 / Orange Pi 5 Plus (Rockchip RK3588/RK3588S arm64) — EXPERIMENTAL
# (hardware validation pending; see specs-orangepi5/README.md). FRITE-style
# vars: a single dedicated platform, ONE role (a client desktop — no cluster-
# node concept), so just --board and --flavor, no --role/--desktop knob.
#   ORANGEPI5_BOARD  = orange-pi-5-plus (DEFAULT) | orange-pi-5
#   ORANGEPI5_FLAVOR = both (DEFAULT) | live | installer
ORANGEPI5_BOARD  ?= orange-pi-5-plus
ORANGEPI5_FLAVOR ?= both
ORANGEPI5_PASS   := ORANGEPI5_BOARD='$(ORANGEPI5_BOARD)' ORANGEPI5_FLAVOR='$(ORANGEPI5_FLAVOR)'

# Orange Pi Zero 2 (Allwinner H616 arm64) — EXPERIMENTAL (hardware validation
# pending; see specs-orangepi-zero2/README.md). A HEADLESS APPLIANCE, not a
# desktop client — no --board axis (one board), no --role/--desktop knob (one
# role: "appliance"), just --flavor. Mirrors the frite/orangepi5 single-
# dedicated-platform pattern.
#   ORANGEPIZERO2_FLAVOR = both (DEFAULT) | live | installer
ORANGEPIZERO2_FLAVOR ?= both
ORANGEPIZERO2_PASS    := ORANGEPIZERO2_FLAVOR='$(ORANGEPIZERO2_FLAVOR)'

# Orange Pi Zero 2W (Allwinner H618 arm64) — EXPERIMENTAL (hardware validation
# pending; see specs-orangepi-zero2w/README.md). A HEADLESS APPLIANCE, not a
# desktop client — no --board axis (one board), no --role/--desktop knob (one
# role: "appliance"), just --flavor. Mirrors the orangepizero2 single-
# dedicated-platform pattern (its H616 template sibling).
#   ORANGEPIZERO2W_FLAVOR = both (DEFAULT) | live | installer
ORANGEPIZERO2W_FLAVOR ?= both
ORANGEPIZERO2W_PASS    := ORANGEPIZERO2W_FLAVOR='$(ORANGEPIZERO2W_FLAVOR)'

# Orange Pi Zero 3 (Allwinner H618 arm64) — EXPERIMENTAL (hardware validation
# pending; see specs-orangepi-zero3/README.md). A HEADLESS APPLIANCE, not a
# desktop client — no --board axis (one board), no --role/--desktop knob (one
# role: "appliance"), just --flavor. Mirrors the orangepizero2/orangepizero2w
# single-dedicated-platform pattern (the Zero 2W is its same-SoC H618 template).
#   ORANGEPIZERO3_FLAVOR = both (DEFAULT) | live | installer
ORANGEPIZERO3_FLAVOR ?= both
ORANGEPIZERO3_PASS    := ORANGEPIZERO3_FLAVOR='$(ORANGEPIZERO3_FLAVOR)'

# Orange Pi 3 LTS (Allwinner H6 arm64) — EXPERIMENTAL (hardware validation
# pending; see specs-orangepi3-lts/README.md). A HEADLESS APPLIANCE, not a
# desktop client — no --board axis (one board), no --role/--desktop knob (one
# role: "appliance"), just --flavor. Mirrors the orangepizero2
# single-dedicated-platform pattern (the Zero 2 is its sunxi template; note
# this board boots the PLAIN Orange Pi 3's mainline DTB/defconfig — mainline
# has no -lts variant, see the README).
#   ORANGEPI3LTS_FLAVOR = both (DEFAULT) | live | installer
ORANGEPI3LTS_FLAVOR ?= both
ORANGEPI3LTS_PASS    := ORANGEPI3LTS_FLAVOR='$(ORANGEPI3LTS_FLAVOR)'

# Orange Pi 4 LTS (Rockchip RK3399 arm64) — EXPERIMENTAL (hardware validation
# pending; see specs-orangepi4-lts/README.md). A LIGHT DESKTOP client, NOT an
# appliance: the mainline DTB it boots has an enabled Mali-T860 GPU + HDMI, so
# this follows the orangepi5 desktop taxonomy. But like the appliances it has
# NO --board axis (mainline ships one Orange Pi RK3399 DTB/defconfig for the
# whole 4/4B/4 LTS family), and like orangepi5 it has no --desktop toggle (one
# role, no headless variant). So: just --flavor.
#   ORANGEPI4LTS_FLAVOR = both (DEFAULT) | live | installer
ORANGEPI4LTS_FLAVOR ?= both
ORANGEPI4LTS_PASS    := ORANGEPI4LTS_FLAVOR='$(ORANGEPI4LTS_FLAVOR)'

.DEFAULT_GOAL := help
.PHONY: help menu mesh-node-up mesh-node-down mesh-node-status mesh-node-logs go-live go-live-menu clean build-all build-everything matrix-check inventory-check image-inventory pentest pentest-seed rebuild \
        rpi x86 omnibus prebuild-binaries frite frite-live frite-installer jetson orangepi5 orangepi5-live orangepi5-installer \
        orangepizero2 orangepizero2-live orangepizero2-installer \
        orangepizero2w orangepizero2w-live orangepizero2w-installer \
        orangepizero3 orangepizero3-live orangepizero3-installer \
        orangepi3-lts orangepi3-lts-live orangepi3-lts-installer \
        orangepi4-lts orangepi4-lts-live orangepi4-lts-installer \
        phone-plan phone-detect phone-fetch phone-flash phone-mdm-enroll phone-attest phone-enroll phone-profile phone-rotate-profile-pass phone-remove-profile phone-ingest phone-status phone-wizard \
        quest-plan quest-detect quest-mdm-enroll quest-enroll quest-ingest quest-status quest-wizard \
        deploy-plan deploy-apply deploy-status deploy-destroy \
        flash qemu qemu-rpi qemu-x86 qemu-matrix qemu-matrix-enumerate \
        playwright-deps e2e ci ci-quick docker-image ensure-image image-gen-docker-image \
        docker docker-build local prod \
        stack-clone stack-mastodon-env stack-m2-bootstrap stack-certs stack-build stack-up stack-down stack-logs stack-ps \
        kind-images kind-up kind-e2e kind-down

help: ## list targets
	@grep -hE '^[a-zA-Z0-9_.+-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-20s\033[0m %s\n",$$1,$$2}'
	@echo
	@echo "  Build path: DEFAULT = Docker (no host sudo, no host toolchain)."
	@echo "              NATIVE=1 = local Gentoo (sudo only when not root)."
	@echo "  Run 'make docker-image' once before the first Docker build (LONG)."
	@echo
	@echo "  Branding:   make build-all BRAND=acme DOMAIN=acme.example"
	@echo "              (-> --config brands/acme.conf; its own domain + mesh;"
	@echo "               optional HEADSCALE_URL=https://hs.acme.example). See brands/README.md."
	@echo "  Build ENV:  ENV=test (DEFAULT, baked) = LAN-only (cluster wildcard DNS; no"
	@echo "              Cloudflare/OAuth/SMTP). ENV=prod = real public domain (announced)."
	@echo "              Shortcuts:  make local   (ENV=test BRAND=local -> hugmesh.test)"
	@echo "                          make prod    (ENV=prod, real domain — creds from keys USB)"
	@echo "  Output:     products land in ./out (WORK_DIR=$(CURDIR)/out; local + gitignored)."
	@echo "              Per-arch build trees: ./out/snap-build-pi5 + ./out/snap-build-x86"
	@echo "              + ./out/snap-build-frite + ./out/snap-build-jetson + ./out/snap-build-orangepi5"
	@echo "              + ./out/snap-build-orangepizero2 + ./out/snap-build-orangepizero2w"
	@echo "              + ./out/snap-build-orangepizero3 + ./out/snap-build-orangepi3-lts"
	@echo "              + ./out/snap-build-orangepi4-lts"
	@echo "              (never share a sysroot)."
	@echo "  Platforms:  rpi (3 cluster roles + rpi-desktop client; RPI_BOARD=rpi5 [DEFAULT] | rpi4 | rpi3 [desktop-only]) |"
	@echo "              x86 (nodes+omnibus+edge_ai+clients+standalone) |"
	@echo "              frite (arm64 light desktop) | jetson (arm64 Tegra edge-AI — EXPERIMENTAL,"
	@echo "              JETSON_ROLE=edge_ai|gpu-host|full|desktop, hardware validation pending) |"
	@echo "              orangepi5 (arm64 Rockchip RK3588/RK3588S light desktop — EXPERIMENTAL,"
	@echo "              ORANGEPI5_BOARD=orange-pi-5-plus|orange-pi-5, hardware validation pending) |"
	@echo "              orangepizero2 (arm64 Allwinner H616 HEADLESS APPLIANCE — EXPERIMENTAL,"
	@echo "              no desktop mode ever — see specs-orangepi-zero2/README.md, hardware validation pending) |"
	@echo "              orangepizero2w (arm64 Allwinner H618 HEADLESS APPLIANCE — EXPERIMENTAL,"
	@echo "              no desktop mode ever, NO onboard Ethernet — see specs-orangepi-zero2w/README.md,"
	@echo "              hardware validation pending) |"
	@echo "              orangepizero3 (arm64 Allwinner H618 HEADLESS APPLIANCE — EXPERIMENTAL,"
	@echo "              no desktop mode ever, onboard GbE back — see specs-orangepi-zero3/README.md,"
	@echo "              hardware validation pending) |"
	@echo "              orangepi3-lts (arm64 Allwinner H6 HEADLESS APPLIANCE — EXPERIMENTAL,"
	@echo "              no desktop mode, boots the PLAIN OPi3 mainline DTB/defconfig, USB-Ethernet-"
	@echo "              first — see specs-orangepi3-lts/README.md, hardware validation pending) |"
	@echo "              orangepi4-lts (arm64 Rockchip RK3399 LIGHT DESKTOP — EXPERIMENTAL,"
	@echo "              single board, Mali-T860/panfrost, boots the shared mainline Orange Pi"
	@echo "              RK3399 DTB — see specs-orangepi4-lts/README.md, hardware validation pending)."
	@echo "  Matrix:     make build-everything = the FULL documented matrix (honors ENV);"
	@echo "              make matrix-check = dry-run validate every role/flag combo via the"
	@echo "              builders' --print-plan (no root, no writes; tests/build-matrix/check.sh)."
	@echo "              make inventory-check = prove the committed FULL image inventory"
	@echo "              (docs/IMAGE-INVENTORY.md — every advertised image x which channels"
	@echo "              can express it) still matches all six channels (dry-run;"
	@echo "              tests/build-matrix/inventory-check.sh)."

menu: ## interactive console menu to build images (progress + quit-without-stopping)
	@bash scripts/build-menu.sh

# ── Local Docker mesh (the wizard's fourth choice — builds NO image) ────────────
# A first-class NON-BUILD face for the fourth choice: run a mesh node on THIS machine
# in Docker via the SAME Qt-free entrypoint the Studio wizard/tray drive
# (core/local_mesh.py), reusing the shipped docker-compose.mesh.yml overlay. No image
# is emitted. AUTHKEY_FILE holds the tailnet/headscale auth key (keeps it off the argv).
mesh-node-up: ## run a Local Docker mesh node on THIS machine (AUTHKEY_FILE=… [NODE_NAME=…] [LOGIN_SERVER=…])
	@PYTHONPATH=studio python3 -m hugmesh_studio.core.local_mesh up --authkey-file "$(AUTHKEY_FILE)" $(if $(NODE_NAME),--node-name "$(NODE_NAME)") $(if $(LOGIN_SERVER),--login-server "$(LOGIN_SERVER)") --generator-dir .

mesh-node-down: ## stop the Local Docker mesh node on THIS machine
	@PYTHONPATH=studio python3 -m hugmesh_studio.core.local_mesh down --generator-dir .

mesh-node-status: ## show whether the Local Docker mesh node is running
	@PYTHONPATH=studio python3 -m hugmesh_studio.core.local_mesh status --generator-dir .

mesh-node-logs: ## tail the Local Docker mesh node's container logs
	@PYTHONPATH=studio python3 -m hugmesh_studio.core.local_mesh logs --generator-dir .

# ── Local Docker mesh FROM SCRATCH (generate creds + start a superadmin mesh) ────
# The "generate & start a NEW local mesh from scratch" path: mint ALL credentials
# (gen-cluster-secrets.sh + gen-provision-keys.sh) then bring up the FULL platform
# stack (make stack-up) seeded with a fresh superadmin, plus the mesh overlay in prod.
# Drives the SAME Qt-free object graph the Studio dialog + ncurses menu use
# (core/local_mesh_bootstrap.py) — it composes the gen scripts + LocalStackNode +
# LocalMeshNode and adds NO new compose invocation. Builds NO image. NON-destructive:
# `plan` only previews; `up` is the explicit action (prod TTY-confirms, no bypass).
# Knobs: ENV=test|prod, SOCIAL=1, SUPERADMIN=…, CLUSTER_DOMAIN=…, AUTHKEY_FILE=… .
_MESH_BOOTSTRAP_ARGS = --env "$(ENV)" $(if $(strip $(SOCIAL)),--social) \
  $(if $(SUPERADMIN),--superadmin-username "$(SUPERADMIN)") \
  $(if $(CLUSTER_DOMAIN),--cluster-domain "$(CLUSTER_DOMAIN)") \
  $(if $(OUT_DIR),--out "$(OUT_DIR)") \
  $(if $(AUTHKEY_FILE),--authkey-file "$(AUTHKEY_FILE)") \
  $(if $(NODE_NAME),--node-name "$(NODE_NAME)") \
  $(if $(LOGIN_SERVER),--login-server "$(LOGIN_SERVER)") \
  --generator-dir .

mesh-bootstrap-plan: ## preview a from-scratch local mesh (creds + stack it WOULD start; no side effects)
	@PYTHONPATH=studio python3 -m hugmesh_studio.core.local_mesh_bootstrap plan $(_MESH_BOOTSTRAP_ARGS)

mesh-bootstrap-up: ## GENERATE creds + START a NEW superadmin local mesh from scratch (explicit; prod TTY-confirms)
	@PYTHONPATH=studio python3 -m hugmesh_studio.core.local_mesh_bootstrap up $(_MESH_BOOTSTRAP_ARGS)

mesh-bootstrap-down: ## stop the from-scratch local mesh (stack + overlay)
	@PYTHONPATH=studio python3 -m hugmesh_studio.core.local_mesh_bootstrap down $(_MESH_BOOTSTRAP_ARGS)

mesh-bootstrap-status: ## show whether the from-scratch local mesh (stack + overlay) is running
	@PYTHONPATH=studio python3 -m hugmesh_studio.core.local_mesh_bootstrap status $(_MESH_BOOTSTRAP_ARGS)

## ── build ─────────────────────────────────────────────────────────────
# Every build target dispatches: NATIVE unset -> re-invoke inside the builder
# container (which sets NATIVE=1, WORK_DIR=/out); NATIVE set -> run the scripts
# directly (the container's root path, or an explicit local-Gentoo run).

clean: ## wipe the work dir (forces a from-scratch rebuild)
	$(SUDO) rm -rf "$(WORK_DIR)"

build-all: ## build the DEFAULT fleet: 3 Pi + x86 pki/be/fe/be+gpu (--resume reuses sysroots)
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make build-all NATIVE=1 WORK_DIR=/out RESUME='$(RESUME)' IMG_FLAGS='$(IMG_FLAGS)' JOBS=$(JOBS) $(BRAND_PASS) $(PENTEST_ENVVARS) $(ROLESET_ENVVARS)
else
	$(ALL) $(RESUME)
	$(chown-artifacts)
endif

pentest: ## run the OWASP pen-test harness only (no image build); PENTEST_SCAN/ENV/PIPELINE knobs
	@echo "==> Pen-test (build option): env=$(PENTEST_ENV) scan=$(PENTEST_SCAN) pipeline=$(PENTEST_PIPELINE)"
	PENTEST_ONLY=1 PENTEST=1 PENTEST_ENV='$(PENTEST_ENV)' PENTEST_SCAN='$(PENTEST_SCAN)' \
	  PENTEST_PIPELINE='$(PENTEST_PIPELINE)' SKIP_KEYS=1 SKIP_X86=1 \
	  $(SUDO) ./scripts/build-all-roles.sh -w $(WORK_DIR)

# pentest-seed is the SEED_CMD target env/compose.env + env/local.env invoke
# (`make -C '$(GEN_DIR)' pentest-seed ...`) from run-pentest.sh's step_seed(). It
# is a thin delegate to the real seeder, tests/pentest/seed-personas.sh, which
# wraps tests/qemu/seed-accounts.sh to mint the ATTACKER + LOAD personas and
# write their bearer tokens to the seed-tokens file ZAP/k6 read. Casdoor admin
# creds (CASDOOR_ADMIN_USER/_PASS) and the throwaway pool password
# (PENTEST_SEED_PASSWORD) are inherited straight from the calling environment
# (CI variables / key-USB) — never pass secrets as make command-line vars.
pentest-seed: ## seed pen-test ATTACKER + LOAD personas (delegates to tests/pentest/seed-personas.sh)
	@echo "==> Pen-test seed: CASDOOR_URL=$(CASDOOR_URL)$(if $(strip $(CASDOOR_BRAND_B_URL)), CASDOOR_BRAND_B_URL=$(CASDOOR_BRAND_B_URL),)"
	$(if $(strip $(CASDOOR_URL)),CASDOOR_URL='$(CASDOOR_URL)') \
	$(if $(strip $(CASDOOR_BRAND_B_URL)),CASDOOR_BRAND_B_URL='$(CASDOOR_BRAND_B_URL)') \
	$(if $(strip $(PENTEST_TOKENS_ENV)),PENTEST_TOKENS_ENV='$(PENTEST_TOKENS_ENV)') \
	  bash tests/pentest/seed-personas.sh

local: ## build the LAN .test fleet (ENV=test, BRAND=local -> hugmesh.test; no internet)
	@echo "==> LOCAL build: ENV=test, brand=local (hugmesh.test). LAN-only — no public"
	@echo "    internet, no Cloudflare, no OAuth/SMTP. Cluster wildcard DNS serves *.hugmesh.test."
	@echo "    After boot, point your router/clients DNS at the backend node:53 (see docs/LOCAL-TESTING.md)."
	$(MAKE) build-all ENV=test BRAND=local

prod: ## build the PROD fleet (ENV=prod, REAL domain) — announced; creds from the keys USB
	@echo -e "\033[1;31m==> PROD build: ENV=prod. This bakes the REAL public domain and expects"
	@echo -e "    Cloudflare/OAuth/SMTP creds from the keys USB. For a LAN test use 'make local'.\033[0m"
	$(MAKE) build-all ENV=prod

# go-live wizard — DEV PREVIEW of the on-device superadmin go-live wizard. This
# is the repo-side CLI op (the thin front-end pattern in Makefile form) over the
# SHARED driver at specs/usr/sbin/hugmesh-go-live. It runs the driver's
# `plan` (a DRY-RUN — it NEVER flips posture) against the repo copies, sandboxed
# with GL_ETC_HUGMESH pointing at a scratch dir so it can NEVER read/write the
# host's /etc/hugmesh. On a real node you run `hugmesh-go-live` directly;
# the marker/posture switch is on-device only (see docs/GO-LIVE-WIZARD.md).
#   make go-live                                  # preview byo-domain for DOMAIN
#   make go-live PROVIDER=byo-domain DOMAIN=acme.example INGRESS_IP=203.0.113.10
GOLIVE_PROVIDER ?= $(if $(strip $(PROVIDER)),$(PROVIDER),byo-domain)
GOLIVE_DOMAIN   ?= $(if $(strip $(DOMAIN)),$(DOMAIN),hugmesh.systems)
GOLIVE_OUT      ?= $(WORK_DIR)/go-live
go-live: ## preview the on-device go-live wizard (DRY-RUN plan; PROVIDER=/DOMAIN=/INGRESS_IP= knobs)
	@echo "==> go-live wizard PREVIEW (dry-run; posture is NEVER touched here)"
	@mkdir -p '$(GOLIVE_OUT)/etc' '$(GOLIVE_OUT)/out'
	GL_ETC_HUGMESH='$(GOLIVE_OUT)/etc' \
	GL_PROVIDERS_LIB='$(CURDIR)/specs/usr/lib/hugmesh/go-live-providers.sh' \
	  bash specs/usr/sbin/hugmesh-go-live plan \
	    --provider '$(GOLIVE_PROVIDER)' --domain '$(GOLIVE_DOMAIN)' \
	    --out-dir '$(GOLIVE_OUT)/out' \
	    $(if $(strip $(INGRESS_IP)),--ingress-ip '$(INGRESS_IP)') \
	    $(if $(strip $(TUNNEL_CNAME)),--tunnel-cname '$(TUNNEL_CNAME)')
	@echo "==> emitted under $(GOLIVE_OUT)/out (preview only). Real go-live is on-device."

# go-live-menu — DEV PREVIEW of the on-device ncurses/whiptail CONSOLE front-end
# (specs/usr/sbin/hugmesh-go-live-menu), the thin successor of the removed
# #286 whiptail UX. It carries NO wizard logic: every action is a subcommand of
# the SAME shared driver `make go-live` previews. It runs under the identical
# GL_ETC_HUGMESH sandbox so it can NEVER read/write the host's
# /etc/hugmesh. On a real node you run `hugmesh-go-live-menu` directly.
go-live-menu: ## preview the on-device go-live CONSOLE menu (ncurses front-end; sandboxed)
	@echo "==> go-live console menu PREVIEW (dry-run sandbox; host posture is NEVER touched)"
	@mkdir -p '$(GOLIVE_OUT)/etc' '$(GOLIVE_OUT)/out'
	GL_ETC_HUGMESH='$(GOLIVE_OUT)/etc' \
	GL_DRIVER='$(CURDIR)/specs/usr/sbin/hugmesh-go-live' \
	GL_PROVIDERS_LIB='$(CURDIR)/specs/usr/lib/hugmesh/go-live-providers.sh' \
	GL_OUT_DIR='$(GOLIVE_OUT)/out' \
	  bash specs/usr/sbin/hugmesh-go-live-menu

# ── MDM phone wizard (onboarding form — builds NO image) ──────────────
# Thin delegates to the ONE driver, scripts/phone-wizard.sh: flash a USB-
# connected Google Pixel with VERIFIED GrapheneOS, enroll it in the brand's
# tailnet, provision the escrowed enterprise profile, emit the device-registry
# ingest record. HOST-SIDE ONLY — deliberately NEVER dispatched into the
# builder container: the driver needs the host's USB bus (adb/fastboot) and a
# real TTY for its typed-serial destructive gates. Default posture is dry-run/
# read-only (plan/detect/status); the state-changing verbs stay gated INSIDE
# the driver (flash: typed-serial confirm on a TTY; non-TTY needs BOTH YES=1
# AND SERIAL=). Secrets follow the mesh-node-up custody pattern: AUTHKEY_FILE=
# and PASS_FILE= forward file PATHS only — no secret ever rides argv.
# Knobs (forwarded only when set; PHONE_ROLE, because ROLE is the build knob):
#   SERIAL= CODENAME= CHANNEL= GRAPHENE_VERSION= OUT_DIR= KEYS_DIR=
#   LOGIN_SERVER= AUTHKEY_FILE= PASS_FILE= DEVICE_ID= SUPERDOMAIN= PHONE_ROLE=
#   PROFILE_NAME= TAILSCALE_APK= APK_SIGNER_SHA256= INGEST_URL= CLIENT_CERT=
#   CLIENT_KEY= CA= INTERNAL_TOKEN_FILE= HEADWIND_APK= HEADWIND_SIGNER_SHA256=
#   HEADWIND_URL= AUDITOR_APK= AUDITOR_SIGNER_SHA256= ATTESTATION_URL=
#   YES=1 FORCE=1 FORCE_FWUPD=1 RESOLVE=1 SHOW_AUTHKEY=1
PHONE_WORK_DIR ?= $(WORK_DIR)/phone-wizard
# Exported so bash — not Make — performs the substitution below: a value with
# an embedded ", `, or $(...) (e.g. a spoofed USB device serial) is inserted
# by the shell as an inert string via "$$VAR", instead of being spliced by
# Make as literal recipe text that /bin/sh would re-parse as shell syntax.
# This custody applies to the BOOLEAN flags and PLAN_VERB too: they are read
# via the shell ($${YES:+--yes}, $${PLAN_VERB}, and the phone-flash SERIAL
# guard's [ -n "$$SERIAL" ]) rather than Make's $(if $(strip $(YES))) / $(error)
# — those forms expand the value at MAKE time, so a $(shell …) payload in YES/
# FORCE/RESOLVE/SHOW_AUTHKEY/FORCE_FWUPD/SERIAL/PLAN_VERB would EXECUTE during
# recipe expansion (a real command-injection; reproduced + fixed). A recursive
# (=) variable never re-runs command substitution once it holds a shell string,
# so the shell forms are inert.
export PHONE_WORK_DIR SERIAL CODENAME CHANNEL GRAPHENE_VERSION OUT_DIR \
  KEYS_DIR LOGIN_SERVER AUTHKEY_FILE PASS_FILE DEVICE_ID SUPERDOMAIN \
  PHONE_ROLE PROFILE_NAME TAILSCALE_APK APK_SIGNER_SHA256 INGEST_URL \
  CLIENT_CERT CLIENT_KEY CA INTERNAL_TOKEN_FILE HEADWIND_APK \
  HEADWIND_SIGNER_SHA256 HEADWIND_URL HEADWIND_CONFIG XR_CHAT_URL \
  AUDITOR_APK AUDITOR_SIGNER_SHA256 ATTESTATION_URL \
  YES FORCE FORCE_FWUPD RESOLVE SHOW_AUTHKEY PLAN_VERB
_PHONE_ARGS = --work-dir "$$PHONE_WORK_DIR" \
  $${SERIAL:+--serial "$$SERIAL"} \
  $${CODENAME:+--codename "$$CODENAME"} \
  $${CHANNEL:+--channel "$$CHANNEL"} \
  $${GRAPHENE_VERSION:+--graphene-version "$$GRAPHENE_VERSION"} \
  $${OUT_DIR:+--out "$$OUT_DIR"} \
  $${KEYS_DIR:+--keys-dir "$$KEYS_DIR"} \
  $${LOGIN_SERVER:+--login-server "$$LOGIN_SERVER"} \
  $${AUTHKEY_FILE:+--authkey-file "$$AUTHKEY_FILE"} \
  $${PASS_FILE:+--pass-file "$$PASS_FILE"} \
  $${DEVICE_ID:+--device-id "$$DEVICE_ID"} \
  $${SUPERDOMAIN:+--superdomain "$$SUPERDOMAIN"} \
  $${PHONE_ROLE:+--role "$$PHONE_ROLE"} \
  $${PROFILE_NAME:+--profile-name "$$PROFILE_NAME"} \
  $${TAILSCALE_APK:+--tailscale-apk "$$TAILSCALE_APK"} \
  $${APK_SIGNER_SHA256:+--apk-signer-sha256 "$$APK_SIGNER_SHA256"} \
  $${INGEST_URL:+--ingest-url "$$INGEST_URL"} \
  $${CLIENT_CERT:+--client-cert "$$CLIENT_CERT"} \
  $${CLIENT_KEY:+--client-key "$$CLIENT_KEY"} \
  $${CA:+--ca "$$CA"} \
  $${INTERNAL_TOKEN_FILE:+--internal-token-file "$$INTERNAL_TOKEN_FILE"} \
  $${HEADWIND_APK:+--headwind-apk "$$HEADWIND_APK"} \
  $${HEADWIND_SIGNER_SHA256:+--headwind-signer-sha256 "$$HEADWIND_SIGNER_SHA256"} \
  $${HEADWIND_URL:+--headwind-url "$$HEADWIND_URL"} \
  $${HEADWIND_CONFIG:+--headwind-config "$$HEADWIND_CONFIG"} \
  $${XR_CHAT_URL:+--xr-chat-url "$$XR_CHAT_URL"} \
  $${THIN_DESKTOP:+--thin-desktop} \
  $${MOONLIGHT_APK:+--moonlight-apk "$$MOONLIGHT_APK"} \
  $${MOONLIGHT_SIGNER_SHA256:+--moonlight-signer-sha256 "$$MOONLIGHT_SIGNER_SHA256"} \
  $${THIN_DESKTOP_HOSTS:+--thin-desktop-hosts "$$THIN_DESKTOP_HOSTS"} \
  $${AUDITOR_APK:+--auditor-apk "$$AUDITOR_APK"} \
  $${AUDITOR_SIGNER_SHA256:+--auditor-signer-sha256 "$$AUDITOR_SIGNER_SHA256"} \
  $${ATTESTATION_URL:+--attestation-url "$$ATTESTATION_URL"} \
  $${YES:+--yes} \
  $${FORCE:+--force} \
  $${FORCE_FWUPD:+--force-fwupd} \
  $${RESOLVE:+--resolve} \
  $${SHOW_AUTHKEY:+--show-authkey}

phone-plan: ## dry-run the MDM phone wizard: validate knobs + catalog, print PLAN_* lines ([PLAN_VERB=flash] plans one verb)
	@bash scripts/phone-wizard.sh plan $${PLAN_VERB} $(_PHONE_ARGS)

phone-detect: ## read-only probe of the USB-connected Pixel (serial, codename, current OS)
	@bash scripts/phone-wizard.sh detect $(_PHONE_ARGS)

phone-fetch: ## download + sshsig-VERIFY the GrapheneOS install zip (CODENAME=… [CHANNEL=stable])
	@bash scripts/phone-wizard.sh fetch $(_PHONE_ARGS)

phone-flash: ## DESTRUCTIVE: wipe + flash the VERIFIED artifact (SERIAL=… required; non-TTY also YES=1)
	@[ -n "$$SERIAL" ] || { echo 'phone-flash: refusing — SERIAL= is required (make phone-detect lists connected devices)' >&2; exit 2; }
	@bash scripts/phone-wizard.sh flash $(_PHONE_ARGS)

phone-enroll: ## join the flashed phone to the mesh tailnet (KEYS_DIR=… or LOGIN_SERVER=…+AUTHKEY_FILE=…)
	@bash scripts/phone-wizard.sh enroll $(_PHONE_ARGS)

phone-profile: ## create + escrow the enterprise secondary user (vault-seed custody; operator sets the credential)
	@bash scripts/phone-wizard.sh profile $(_PHONE_ARGS)

phone-rotate-profile-pass: ## rotate + re-escrow the enterprise-profile passphrase (previous kept as .prev-<ts>)
	@bash scripts/phone-wizard.sh rotate-profile-pass $(_PHONE_ARGS)

phone-remove-profile: ## DESTRUCTIVE: remove the enterprise profile (typed confirm on a TTY; non-TTY needs YES=1)
	@bash scripts/phone-wizard.sh remove-profile $(_PHONE_ARGS)

phone-ingest: ## emit the phone-ingest/v1 device-registry record (INGEST_URL=+mTLS flags to POST it)
	@bash scripts/phone-wizard.sh ingest $(_PHONE_ARGS)

phone-status: ## read-only: tools, device, tailnet, profile + escrow PRESENCE (never contents)
	@bash scripts/phone-wizard.sh status $(_PHONE_ARGS)

phone-mdm-enroll: ## Headwind MDM device-owner enrollment (fresh device only; HEADWIND_APK=+HEADWIND_SIGNER_SHA256= pin, HEADWIND_URL= into init.json)
	@bash scripts/phone-wizard.sh mdm-enroll $(_PHONE_ARGS)

phone-attest: ## install the pinned HugMesh Auditor fork + guided AttestationServer pairing (AUDITOR_APK=+AUDITOR_SIGNER_SHA256=, ATTESTATION_URL=)
	@bash scripts/phone-wizard.sh attest $(_PHONE_ARGS)

phone-wizard: ## interactive guided full phone flow (TTY): detect->fetch->flash->attest->mdm-enroll->enroll->profile->ingest
	@bash scripts/phone-wizard.sh wizard $(_PHONE_ARGS)

# ── MDM Quest / Oculus headset (same driver, --device-class quest) ─────
# A Meta Quest 3/3S as another MDM-managed Android device on the mesh. SAME
# thin-delegate pattern and knobs as the phone-* targets above; the quest
# surface is the 4-verb subset that exists for the class (fetch/flash/attest/
# profile are UNSUPPORTED for quest and the driver refuses them with the
# rationale — see docs/MDM.md). Extra knobs: HEADWIND_CONFIG= (the Headwind
# configuration the headset self-selects into, i.e. the app-push lever),
# XR_CHAT_URL= (the https XR-chat entry URL provisioned during mdm-enroll)
# and the opt-in thin-desktop set — THIN_DESKTOP=1 MOONLIGHT_APK=
# MOONLIGHT_SIGNER_SHA256= THIN_DESKTOP_HOSTS= (Moonlight sideload + managed
# thin-client host list; the node side is the x86 builder's --with-sunshine).
_QUEST_ARGS = --device-class quest $(_PHONE_ARGS)

quest-plan: ## dry-run the Quest MDM wizard: validate knobs + quest catalog, print PLAN_* lines ([PLAN_VERB=mdm-enroll] plans one verb)
	@bash scripts/phone-wizard.sh plan $(PLAN_VERB) $(_QUEST_ARGS)

quest-detect: ## read-only probe of the USB-connected Quest (Developer Mode must be ON; prints the runbook when it is not)
	@bash scripts/phone-wizard.sh detect $(_QUEST_ARGS)

quest-mdm-enroll: ## Headwind MDM device-owner enrollment + XR-chat URL + opt-in thin desktop (HEADWIND_APK= HEADWIND_URL= [HEADWIND_CONFIG= XR_CHAT_URL= THIN_DESKTOP=1 MOONLIGHT_APK= MOONLIGHT_SIGNER_SHA256= THIN_DESKTOP_HOSTS=])
	@bash scripts/phone-wizard.sh mdm-enroll $(_QUEST_ARGS)

quest-enroll: ## join the headset to the mesh tailnet (TAILSCALE_APK= sideload; KEYS_DIR= or LOGIN_SERVER=+AUTHKEY_FILE=)
	@bash scripts/phone-wizard.sh enroll $(_QUEST_ARGS)

quest-ingest: ## emit the device-registry record (device_class=quest; registry POST is a documented cross-repo gap)
	@bash scripts/phone-wizard.sh ingest $(_QUEST_ARGS)

quest-status: ## read-only: tools, headset, tailnet presence
	@bash scripts/phone-wizard.sh status $(_QUEST_ARGS)

quest-wizard: ## interactive guided quest flow (TTY): detect->mdm-enroll->enroll->ingest
	@bash scripts/phone-wizard.sh wizard $(_QUEST_ARGS)

# ── Cloud deploy (publishes a PACKAGED image — builds NO image) ───────
# Thin delegates to the shared Qt-free entrypoint
# hugmesh_studio.core.cloud_deploy, which fronts the ONE canonical driver
# specs/usr/sbin/hugmesh-cloud-deploy — the exact same face the Studio
# DeployPage and the ncurses deploy_screen drive. `plan` renders the provider
# artifacts OFFLINE into OUT_DIR (readable scripts/policies/checklists; no
# cloud API is touched); only apply/destroy mutate anything, and BOTH stay
# TTY-confirmed INSIDE the driver (deliberately no YES= bypass knob here —
# the entrypoint runs them terminal-attached so the prompts reach you).
# Secrets follow the phone-wizard custody pattern: CREDS_FILE= forwards a
# file PATH only — no secret ever rides argv or this Makefile.
# Knobs (forwarded only when set; DEPLOY_IMAGE, because IMAGE is the builder-
# container knob at the top of this file):
#   PROVIDER= DEPLOY_IMAGE= DOMAIN= REGION= CREDS_FILE= OUT_DIR= KEYS_DIR=
#   IDP= IDP_ISSUER= IDP_CLIENT_ID= IDP_JWKS=   (IdP passthrough; casdoor default)
# The values are read by BASH ($${VAR:+…}), not spliced by Make — the
# _PHONE_ARGS injection custody: an ENVIRONMENT-supplied $(shell …) payload
# stays an inert string instead of executing at recipe-expansion time. (A
# command-line assignment `make deploy-plan 'PROVIDER=$(shell …)'` still
# expands at Make's own assignment step — identical to the phone-* precedent
# and to every Make CLI variable; invoking make already implies shell access,
# so the custody line here is the env/recipe path, not the CLI assignment.)
# All of these knobs are command-line/environment supplied (no Makefile-side
# defaults), and both sources are auto-exported to the recipe shell, so no
# export line is needed.
_CLOUD_DEPLOY_ARGS = $${PROVIDER:+--provider "$$PROVIDER"} \
  $${DEPLOY_IMAGE:+--image "$$DEPLOY_IMAGE"} \
  $${DOMAIN:+--domain "$$DOMAIN"} \
  $${REGION:+--region "$$REGION"} \
  $${CREDS_FILE:+--creds-file "$$CREDS_FILE"} \
  $${OUT_DIR:+--out-dir "$$OUT_DIR"} \
  $${KEYS_DIR:+--keys-dir "$$KEYS_DIR"} \
  $${IDP:+--idp "$$IDP"} \
  $${IDP_ISSUER:+--idp-issuer "$$IDP_ISSUER"} \
  $${IDP_CLIENT_ID:+--idp-client-id "$$IDP_CLIENT_ID"} \
  $${IDP_JWKS:+--idp-jwks "$$IDP_JWKS"} \
  --generator-dir .

deploy-plan: ## render the cloud-deploy provider artifacts OFFLINE (PROVIDER= DEPLOY_IMAGE= [DOMAIN= REGION= CREDS_FILE= OUT_DIR= KEYS_DIR=])
	@PYTHONPATH=studio python3 -m hugmesh_studio.core.cloud_deploy plan $(_CLOUD_DEPLOY_ARGS)

deploy-apply: ## EXECUTE the rendered plan's apply.sh (driver TTY-confirms; REAL cloud resources + cost)
	@PYTHONPATH=studio python3 -m hugmesh_studio.core.cloud_deploy apply $(_CLOUD_DEPLOY_ARGS)

deploy-status: ## read the emitted state hints / print the provider check commands (never calls a cloud API)
	@PYTHONPATH=studio python3 -m hugmesh_studio.core.cloud_deploy status $(_CLOUD_DEPLOY_ARGS)

deploy-destroy: ## run the rendered plan's destroy.sh (driver TTY-confirms)
	@PYTHONPATH=studio python3 -m hugmesh_studio.core.cloud_deploy destroy $(_CLOUD_DEPLOY_ARGS)

rebuild: ## from-scratch: wipe the work dir, then build the whole default fleet
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make rebuild NATIVE=1 WORK_DIR=/out IMG_FLAGS='$(IMG_FLAGS)' JOBS=$(JOBS) $(BRAND_PASS) $(PENTEST_ENVVARS) $(ROLESET_ENVVARS)
else
	$(MAKE) clean NATIVE=1
	$(ALL)
	$(chown-artifacts)
endif

rpi: ## build all 3 Pi cluster roles (.img + .fs.tar.xz each; RPI_BOARD=rpi5 [DEFAULT] | rpi4 — rpi3 is desktop-only, use rpi-desktop instead)
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make rpi NATIVE=1 WORK_DIR=/out IMG_FLAGS='$(IMG_FLAGS)' JOBS=$(JOBS) RPI_BOARD='$(RPI_BOARD)' $(BRAND_PASS)
else
	@for r in $(RPI_ROLES); do echo "==> Pi $$r ($(RPI_BOARD))"; $(RPI) --role $$r || exit 1; done
	$(chown-artifacts)
endif

x86: ## build the 4 default x86 roles (.img + live ISO + .fs.tar.xz each)
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make x86 NATIVE=1 WORK_DIR=/out IMG_FLAGS='$(IMG_FLAGS)' JOBS=$(JOBS) $(BRAND_PASS)
else
	@for r in $(X86_ROLE_LIST); do echo "==> x86 $$r"; $(X86) --role $$r || exit 1; done
	$(chown-artifacts)
endif

omnibus: ## build the opt-in x86 omnibus (all namespaces on one node)
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make omnibus NATIVE=1 WORK_DIR=/out IMG_FLAGS='$(IMG_FLAGS)' JOBS=$(JOBS) $(BRAND_PASS)
else
	$(X86) --role omnibus
	$(chown-artifacts)
endif

# ── prebuild-binaries: compile a platform's role-UNION binpkg pool ONCE ─────────
# (shared-binpkg track, Lane 4c)  ARCH=<platform> [BOARD=<board>]
# Computes the role-union atom list via the Qt-free Studio module, then invokes the
# platform's builder ONE time with --packages-only (populate PKGDIR under
# FEATURES=buildpkg, then exit BEFORE any image assembly — emits nothing
# image-shaped) + the union via --packages-add, into the PER-BOARD pkgdir. Later
# per-role image builds reuse it via --usepkg (guarded by the pool fingerprint).
# PER-BOARD: the pi builder's --board selects the Lane-2 snap-build-pi5/-pi4/-pi3
# subdir; a BOARD= override is threaded to the pi family (its -mcpu split is the one
# that needs distinct pools — see docs/SHARED-BINPKG.md). USE note: the pool is
# built under the chosen prebuild role's USE; a later role whose USE differs rebuilds
# just those atoms (--binpkg-respect-use=y + --newuse) — SAFE, never a wrong reuse.
PREBUILD_ROLE_X86     ?= omnibus
PREBUILD_ROLE_RPI     ?= backend
PREBUILD_JETSON_BOARD ?= orin-nano
prebuild-binaries: ## prebuild a platform's role-union binpkg pool (ARCH=x86|rpi5|frite|jetson|orangepi5|orangepizero2|orangepizero2w|orangepizero3|orangepi3-lts|orangepi4-lts [BOARD=]); compile once, reuse via --usepkg
	@_pl='$(ARCH)'; _list=$$(mktemp); \
	 echo "==> computing $$_pl role-union package set (prebuild_union)"; \
	 PYTHONPATH=studio python3 -m hugmesh_studio.core.prebuild_union "$$_pl" > "$$_list" \
	   || { echo "prebuild_union failed for '$$_pl'"; rm -f "$$_list"; exit 1; }; \
	 _atoms="$$(tr '\n' ' ' < "$$_list")"; \
	 echo "==> $$_pl: $$(wc -l < "$$_list") atoms -> per-board binpkg pool (--packages-only, no image)"; \
	 case "$$_pl" in \
	   x86)           $(X86) --role $(PREBUILD_ROLE_X86) --packages-only --packages-add "$$_atoms" ;; \
	   rpi5)          $(RPI) $(if $(BOARD),--board $(BOARD),) --role $(PREBUILD_ROLE_RPI) --packages-only --packages-add "$$_atoms" ;; \
	   frite)         $(FRITE_BUILD) --board $(FRITE_BOARD) --flavor installer --desktop light --packages-only --packages-add "$$_atoms" ;; \
	   jetson)        $(JETSON_BUILD) --board $(PREBUILD_JETSON_BOARD) --role $(JETSON_ROLE) --packages-only --packages-add "$$_atoms" ;; \
	   orangepi5)     $(ORANGEPI5_BUILD) --board $(ORANGEPI5_BOARD) --flavor installer --packages-only --packages-add "$$_atoms" ;; \
	   orangepizero2) $(ORANGEPIZERO2_BUILD) --flavor installer --packages-only --packages-add "$$_atoms" ;; \
	   orangepizero2w) $(ORANGEPIZERO2W_BUILD) --flavor installer --packages-only --packages-add "$$_atoms" ;; \
	   orangepizero3) $(ORANGEPIZERO3_BUILD) --flavor installer --packages-only --packages-add "$$_atoms" ;; \
	   orangepi3-lts) $(ORANGEPI3LTS_BUILD) --flavor installer --packages-only --packages-add "$$_atoms" ;; \
	   orangepi4-lts) $(ORANGEPI4LTS_BUILD) --flavor installer --packages-only --packages-add "$$_atoms" ;; \
	   *) echo "prebuild-binaries: ARCH must be x86|rpi5|frite|jetson|orangepi5|orangepizero2|orangepizero2w|orangepizero3|orangepi3-lts|orangepi4-lts (got '$$_pl')"; rm -f "$$_list"; exit 1 ;; \
	 esac; \
	 rm -f "$$_list"

# Extra builder flags threaded to the standalone-desktop targets (the menu / CLI
# passes e.g. STANDALONE_FLAGS='--local-user alice --local-pass s3cret --nvidia-driver proprietary').
# Exported (mirrors CA_KEY_PASS above) so the Docker-dispatch recipes below can
# forward it via DOCKER_RUN's `-e STANDALONE_FLAGS` instead of re-splicing
# '$(STANDALONE_FLAGS)' as literal recipe text: a value containing an embedded
# single quote (a realistic diceware/strong password character) would close
# that quote early and let the remainder of the string execute as separate
# shell commands on the HOST, before docker even starts. `export` here makes
# this safe regardless of whether STANDALONE_FLAGS arrived as a command-line
# var (`make ... STANDALONE_FLAGS=...`) or from the environment — either way
# each recipe's OWN unquoted `$(STANDALONE_FLAGS)` splice (native execution,
# e.g. `$(RPI) --role $* $(STANDALONE_FLAGS)`) still requires any secret VALUE
# folded into it to be shell-quoted by whoever composed it (see
# scripts/build-menu.sh's _shell_quote()) — this export only closes the
# Docker-dispatch hop's OWN additional, buggier re-quoting.
STANDALONE_FLAGS ?=
export STANDALONE_FLAGS

x86-standalone: ## build BOTH hardened standalone NVIDIA desktops (thin+thick; LUKS FDE installer + all 4 artifacts)
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make x86-standalone NATIVE=1 WORK_DIR=/out IMG_FLAGS='$(IMG_FLAGS)' JOBS=$(JOBS) $(BRAND_PASS)
else
	@for r in standalone-thin standalone-thick; do echo "==> x86 $$r"; $(X86) --role $$r $(STANDALONE_FLAGS) || exit 1; done
	$(chown-artifacts)
endif

rpi-%: ## build ONE Pi role: make rpi-frontend | rpi-desktop  (add IMG_FLAGS='--no-iso' etc.; RPI_BOARD=rpi5 [DEFAULT] | rpi4 | rpi3 [desktop-only]; STANDALONE_FLAGS='--standalone --local-user … --local-pass …' for rpi-desktop)
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make rpi-$* NATIVE=1 WORK_DIR=/out IMG_FLAGS='$(IMG_FLAGS)' JOBS=$(JOBS) RPI_BOARD='$(RPI_BOARD)' $(BRAND_PASS)
else
	@$(RPI) --role $* $(STANDALONE_FLAGS)
	$(chown-artifacts)
endif

x86-%: ## build ONE x86 role: make x86-be+gpu | x86-pki | x86-standalone-thin (STANDALONE_FLAGS='--local-user … --nvidia')
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make x86-$* NATIVE=1 WORK_DIR=/out IMG_FLAGS='$(IMG_FLAGS)' JOBS=$(JOBS) $(BRAND_PASS)
else
	@$(X86) --role $* $(STANDALONE_FLAGS)
	$(chown-artifacts)
endif

frite: ## build the Frite light desktop (FRITE_BOARD=la-frite|le-potato, FRITE_FLAVOR=both|live|installer, FRITE_DESKTOP=light|none; STANDALONE_FLAGS='--enable-wifi …' appended verbatim)
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make frite NATIVE=1 WORK_DIR=/out JOBS=$(JOBS) IMG_FLAGS='$(IMG_FLAGS)' $(BRAND_PASS) $(FRITE_PASS)
else
	@$(FRITE_BUILD) --board $(FRITE_BOARD) --flavor $(FRITE_FLAVOR) --desktop $(FRITE_DESKTOP) $(STANDALONE_FLAGS)
	$(chown-artifacts)
endif

frite-live: ## build the Frite light desktop LIVE image only (boots ephemerally off USB/SD)
	$(MAKE) frite FRITE_FLAVOR=live

frite-installer: ## build the Frite light desktop INSTALLER image only (writes to eMMC/SD)
	$(MAKE) frite FRITE_FLAVOR=installer

jetson: ## build the Jetson Orin edge-AI image (JETSON_ROLE=edge_ai|gpu-host|full|desktop; EXPERIMENTAL; STANDALONE_FLAGS='--enable-wifi …')
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make jetson NATIVE=1 WORK_DIR=/out JOBS=$(JOBS) IMG_FLAGS='$(IMG_FLAGS)' $(BRAND_PASS) $(JETSON_PASS)
else
	@$(JETSON_BUILD) --role $(JETSON_ROLE) --board $(JETSON_BOARD) --kernel-flavor $(JETSON_KERNEL_FLAVOR) $(STANDALONE_FLAGS)
	$(chown-artifacts)
endif

jetson-%: ## build ONE Jetson role: make jetson-edge_ai | jetson-gpu-host | jetson-full | jetson-desktop (STANDALONE_FLAGS appended verbatim)
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make jetson-$* NATIVE=1 WORK_DIR=/out JOBS=$(JOBS) IMG_FLAGS='$(IMG_FLAGS)' $(BRAND_PASS) $(JETSON_PASS)
else
	@$(JETSON_BUILD) --role $* --board $(JETSON_BOARD) --kernel-flavor $(JETSON_KERNEL_FLAVOR) $(STANDALONE_FLAGS)
	$(chown-artifacts)
endif

orangepi5: ## build the Orange Pi 5 light desktop (EXPERIMENTAL; ORANGEPI5_BOARD=orange-pi-5-plus|orange-pi-5, ORANGEPI5_FLAVOR=both|live|installer; STANDALONE_FLAGS='--standalone …' appended verbatim)
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make orangepi5 NATIVE=1 WORK_DIR=/out JOBS=$(JOBS) IMG_FLAGS='$(IMG_FLAGS)' $(BRAND_PASS) $(ORANGEPI5_PASS)
else
	@$(ORANGEPI5_BUILD) --board $(ORANGEPI5_BOARD) --flavor $(ORANGEPI5_FLAVOR) $(STANDALONE_FLAGS)
	$(chown-artifacts)
endif

orangepi5-live: ## build the Orange Pi 5 light desktop LIVE image only (boots ephemerally off USB/microSD)
	$(MAKE) orangepi5 ORANGEPI5_FLAVOR=live

orangepi5-installer: ## build the Orange Pi 5 light desktop INSTALLER image only (writes to eMMC/microSD/NVMe)
	$(MAKE) orangepi5 ORANGEPI5_FLAVOR=installer

orangepizero2: ## build the Orange Pi Zero 2 HEADLESS APPLIANCE (EXPERIMENTAL; no desktop mode ever; ORANGEPIZERO2_FLAVOR=both|live|installer; STANDALONE_FLAGS='--standalone …' appended verbatim)
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make orangepizero2 NATIVE=1 WORK_DIR=/out JOBS=$(JOBS) IMG_FLAGS='$(IMG_FLAGS)' $(BRAND_PASS) $(ORANGEPIZERO2_PASS)
else
	@$(ORANGEPIZERO2_BUILD) --flavor $(ORANGEPIZERO2_FLAVOR) $(STANDALONE_FLAGS)
	$(chown-artifacts)
endif

orangepizero2-live: ## build the Orange Pi Zero 2 headless appliance LIVE image only (boots ephemerally off microSD/USB)
	$(MAKE) orangepizero2 ORANGEPIZERO2_FLAVOR=live

orangepizero2-installer: ## build the Orange Pi Zero 2 headless appliance INSTALLER image only (writes to microSD/USB)
	$(MAKE) orangepizero2 ORANGEPIZERO2_FLAVOR=installer

orangepizero2w: ## build the Orange Pi Zero 2W HEADLESS APPLIANCE (EXPERIMENTAL; no desktop mode ever; ORANGEPIZERO2W_FLAVOR=both|live|installer; STANDALONE_FLAGS='--standalone …' appended verbatim)
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make orangepizero2w NATIVE=1 WORK_DIR=/out JOBS=$(JOBS) IMG_FLAGS='$(IMG_FLAGS)' $(BRAND_PASS) $(ORANGEPIZERO2W_PASS)
else
	@$(ORANGEPIZERO2W_BUILD) --flavor $(ORANGEPIZERO2W_FLAVOR) $(STANDALONE_FLAGS)
	$(chown-artifacts)
endif

orangepizero2w-live: ## build the Orange Pi Zero 2W headless appliance LIVE image only (boots ephemerally off microSD/USB)
	$(MAKE) orangepizero2w ORANGEPIZERO2W_FLAVOR=live

orangepizero2w-installer: ## build the Orange Pi Zero 2W headless appliance INSTALLER image only (writes to microSD/USB)
	$(MAKE) orangepizero2w ORANGEPIZERO2W_FLAVOR=installer

orangepizero3: ## build the Orange Pi Zero 3 HEADLESS APPLIANCE (EXPERIMENTAL; no desktop mode ever; ORANGEPIZERO3_FLAVOR=both|live|installer; STANDALONE_FLAGS='--standalone …' appended verbatim)
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make orangepizero3 NATIVE=1 WORK_DIR=/out JOBS=$(JOBS) IMG_FLAGS='$(IMG_FLAGS)' $(BRAND_PASS) $(ORANGEPIZERO3_PASS)
else
	@$(ORANGEPIZERO3_BUILD) --flavor $(ORANGEPIZERO3_FLAVOR) $(STANDALONE_FLAGS)
	$(chown-artifacts)
endif

orangepizero3-live: ## build the Orange Pi Zero 3 headless appliance LIVE image only (boots ephemerally off microSD/USB)
	$(MAKE) orangepizero3 ORANGEPIZERO3_FLAVOR=live

orangepizero3-installer: ## build the Orange Pi Zero 3 headless appliance INSTALLER image only (writes to microSD/USB)
	$(MAKE) orangepizero3 ORANGEPIZERO3_FLAVOR=installer

orangepi3-lts: ## build the Orange Pi 3 LTS HEADLESS APPLIANCE (EXPERIMENTAL; no desktop mode; ORANGEPI3LTS_FLAVOR=both|live|installer; STANDALONE_FLAGS='--standalone …' appended verbatim)
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make orangepi3-lts NATIVE=1 WORK_DIR=/out JOBS=$(JOBS) IMG_FLAGS='$(IMG_FLAGS)' $(BRAND_PASS) $(ORANGEPI3LTS_PASS)
else
	@$(ORANGEPI3LTS_BUILD) --flavor $(ORANGEPI3LTS_FLAVOR) $(STANDALONE_FLAGS)
	$(chown-artifacts)
endif

orangepi3-lts-live: ## build the Orange Pi 3 LTS headless appliance LIVE image only (boots ephemerally off microSD/USB)
	$(MAKE) orangepi3-lts ORANGEPI3LTS_FLAVOR=live

orangepi3-lts-installer: ## build the Orange Pi 3 LTS headless appliance INSTALLER image only (writes to microSD/eMMC/USB)
	$(MAKE) orangepi3-lts ORANGEPI3LTS_FLAVOR=installer

orangepi4-lts: ## build the Orange Pi 4 LTS LIGHT DESKTOP (EXPERIMENTAL; single board; ORANGEPI4LTS_FLAVOR=both|live|installer; STANDALONE_FLAGS='--standalone …' appended verbatim)
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make orangepi4-lts NATIVE=1 WORK_DIR=/out JOBS=$(JOBS) IMG_FLAGS='$(IMG_FLAGS)' $(BRAND_PASS) $(ORANGEPI4LTS_PASS)
else
	@$(ORANGEPI4LTS_BUILD) --flavor $(ORANGEPI4LTS_FLAVOR) $(STANDALONE_FLAGS)
	$(chown-artifacts)
endif

orangepi4-lts-live: ## build the Orange Pi 4 LTS light desktop LIVE image only (boots ephemerally off microSD/USB)
	$(MAKE) orangepi4-lts ORANGEPI4LTS_FLAVOR=live

orangepi4-lts-installer: ## build the Orange Pi 4 LTS light desktop INSTALLER image only (writes to onboard eMMC/microSD)
	$(MAKE) orangepi4-lts ORANGEPI4LTS_FLAVOR=installer

# build-everything delegates to build-all with the ROLE-SELECTOR knobs set on the
# sub-make COMMAND LINE (not as env prefixes: $(ALL)'s own ROLESET_ENVVARS would
# re-assign the empty defaults AFTER an env prefix and clobber it). Command-line
# make vars override the `?=` defaults inside the sub-make, so ROLESET_ENVVARS is
# rebuilt there with the full-matrix values; ENV/BRAND/IMG_FLAGS pass through.
build-everything: ## build the FULL documented matrix: 3 Pi + all 12 x86 (nodes+omnibus+edge_ai+clients+standalone incl. unaffiliated) + Frite + Jetson + Orange Pi 5 + Orange Pi Zero 2 + Orange Pi Zero 2W + Orange Pi Zero 3 + Orange Pi 3 LTS + Orange Pi 4 LTS (honors ENV=test|prod)
	$(MAKE) build-all \
	  X86_ROLES='$(X86_EVERY_ROLE)' \
	  FRITE=1 FRITE_BOARD='$(FRITE_BOARD)' FRITE_FLAVOR='$(FRITE_FLAVOR)' \
	  FRITE_DESKTOP='$(FRITE_DESKTOP)' \
	  JETSON=1 JETSON_ROLES='edge_ai gpu-host full desktop' \
	  JETSON_BOARD='$(JETSON_BOARD)' JETSON_KERNEL_FLAVOR='$(JETSON_KERNEL_FLAVOR)' \
	  ORANGEPI5=1 ORANGEPI5_BOARD='$(ORANGEPI5_BOARD)' ORANGEPI5_FLAVOR='$(ORANGEPI5_FLAVOR)' \
	  ORANGEPIZERO2=1 ORANGEPIZERO2_FLAVOR='$(ORANGEPIZERO2_FLAVOR)' \
	  ORANGEPIZERO2W=1 ORANGEPIZERO2W_FLAVOR='$(ORANGEPIZERO2W_FLAVOR)' \
	  ORANGEPIZERO3=1 ORANGEPIZERO3_FLAVOR='$(ORANGEPIZERO3_FLAVOR)' \
	  ORANGEPI3LTS=1 ORANGEPI3LTS_FLAVOR='$(ORANGEPI3LTS_FLAVOR)' \
	  ORANGEPI4LTS=1 ORANGEPI4LTS_FLAVOR='$(ORANGEPI4LTS_FLAVOR)'

matrix-check: ## dry-run validate the whole build matrix via --print-plan (tests/build-matrix/check.sh)
	@test -f tests/build-matrix/check.sh \
	  || { echo "tests/build-matrix/check.sh not found — the build-matrix harness is not in this checkout yet."; exit 1; }
	bash tests/build-matrix/check.sh

# matrix-check proves the 150 CURATED matrix.tsv cells; inventory-check proves the
# other half — that the committed FULL inventory (every image the catalog grammar
# advertises, x which of the six channels can express it) still matches reality.
# Both are dry-run: --print-plan / make -n / command printing, no root, no docker.
inventory-check: ## prove docs/IMAGE-INVENTORY.md still matches all six build channels (tests/build-matrix/inventory-check.sh)
	@test -f tests/build-matrix/inventory-check.sh \
	  || { echo "tests/build-matrix/inventory-check.sh not found — the inventory gate is not in this checkout yet."; exit 1; }
	bash tests/build-matrix/inventory-check.sh

image-inventory: ## regenerate docs/catalog/image-inventory.json + docs/IMAGE-INVENTORY.md from the live channels
	python3 scripts/emit-image-inventory.py

## ── docker (cross-platform builder; Phase 5) ──────────────────────────
# CROSSDEV=0 builds the x86-only image variant (skips the slow, several-GB
# aarch64 cross-toolchain stage; ARM targets then fail their prerequisite
# check inside it — see Dockerfile.build). Default 1 = the full image.
CROSSDEV ?= 1
docker-image: ## build the self-contained Gentoo builder image (LONG first time: cross-toolchain; CROSSDEV=0 = x86-only)
	docker build -f Dockerfile.build --build-arg CROSSDEV=$(CROSSDEV) -t $(IMAGE) .

# admin-bff-api's image-gen k8s Job worker (docker/Dockerfile.image-gen +
# docker/build-image.sh). Layers on top of $(IMAGE) (run `make docker-image`
# first) since the Job has no bind-mount of this repo — the checkout has to be
# baked in. IMAGE_GEN_TAG defaults to the registry ref the Job manifest
# expects; an operator still has to `docker push` it and flip
# admin-bff-api's imagegen.launch.enabled for any of this to go live.
# GIT_SHA is baked into the image as GENERATOR_REV (see Dockerfile.image-gen)
# purely for the build-image.sh terminal ingest message to report which
# generator revision produced the image; falls back to empty (not a fake
# placeholder) outside a git checkout so the message suffix just stays absent.
IMAGE_GEN_TAG ?= registry.hugmesh.systems/hugmesh/image-gen:latest
GIT_SHA ?= $(shell git rev-parse --short HEAD 2>/dev/null)
image-gen-docker-image: ## build the admin-bff-api image-gen Job worker (needs $(IMAGE) built first)
	docker build -f docker/Dockerfile.image-gen --build-arg GIT_SHA=$(GIT_SHA) -t $(IMAGE_GEN_TAG) .

## ── flash / emulate / test ────────────────────────────────────────────
# These run HOST-side. flash writes /dev/sdX (inherently privileged -> SUDO).
# qemu/e2e read the (now user-owned) artifacts: no sudo needed to READ them,
# but $(SUDO) is kept defensively where a root-owned path is still possible
# (loop-mount in --kernel-from-img, KVM device access on a locked-down host).

flash: ## write a role image to a disk: make flash DEV=/dev/sdX ROLE=frontend ARCH=arm64
	@test -n "$(DEV)" || { echo "set DEV=/dev/sdX (the target disk)"; exit 1; }
	$(SUDO) scripts/flash-disk.sh --arch $(ARCH) --role $(ROLE) -w "$(WORK_DIR)" "$(DEV)"

qemu-rpi: ## boot a Pi role image in QEMU: make qemu-rpi ROLE=frontend
	$(SUDO) tests/qemu/launch-pi.sh -w "$(WORK_DIR)" -r $(ROLE) --foreground

qemu-x86: ## boot an x86 role image in QEMU: make qemu-x86 ROLE=be+gpu
	$(SUDO) tests/qemu/launch-x86.sh -w "$(WORK_DIR)" -r $(ROLE) --foreground

qemu: qemu-$(if $(filter arm64,$(ARCH)),rpi,x86) ## boot ROLE/ARCH in QEMU (ARCH=x86|arm64)

qemu-matrix: ## boot+assert size/load for matrix rows (opt-in; HUGMESH_QEMU_E2E=1; MATRIX_FILTER=x86/be+gpu)
	HUGMESH_QEMU_E2E=$(if $(HUGMESH_QEMU_E2E),$(HUGMESH_QEMU_E2E),1) \
	  $(SUDO) tests/qemu/run-matrix-e2e.sh -w "$(WORK_DIR)" $(if $(MATRIX_FILTER),--only $(MATRIX_FILTER),)

qemu-matrix-enumerate: ## dry-run enumerate every matrix row + its launcher/size/RAM (no boot, no build)
	tests/qemu/run-matrix-e2e.sh --dry-run $(if $(MATRIX_FILTER),--only $(MATRIX_FILTER),)

# ── kind SSO e2e — the same native-login proof the compose stack runs
# (tests/e2e/specs/27-native-login.spec.ts), against a REAL kind cluster
# running the GitOps payload (ArgoCD + Vault/ESO/Casdoor + fe-gateway + BFFs).
# Flow: kind-images builds the first-party images from ./.stack-src and
# `kind load`s them under the exact rendered refs; kind-up brings up
# bootstrap-kind.sh KIND_PROFILE=sso (apps + Vault KV + e2e identity seed);
# kind-e2e resolver-maps hugmesh.systems -> 127.0.0.1 (kind-local.yaml maps
# the internal ingress out on :8443) and runs spec 27. No /etc/hosts edits,
# no sudo. See specs/cluster/bootstrap/kind-local/README.md.
kind-images: stack-clone stack-m2-bootstrap ## build + `kind load` the SSO-slice first-party images (needs the kind cluster to exist)
	bash scripts/kind-load-images.sh

kind-up: ## bring up the kind SSO slice (KIND_PROFILE=sso bootstrap: apps + Vault KV + e2e seeds)
	KIND_PROFILE=sso bash specs/cluster/bootstrap/kind-local/bootstrap-kind.sh

kind-e2e: playwright-deps ## run the native-login e2e (spec 27) against the kind cluster
	cd tests/e2e && \
	  SNAP_BASE_URL='https://hugmesh.systems:8443' \
	  SNAP_HOST_RESOLVER='MAP hugmesh.systems 127.0.0.1, MAP *.hugmesh.systems 127.0.0.1' \
	  npx playwright test specs/27-native-login.spec.ts

kind-down: ## delete the kind cluster
	kind delete cluster --name $${KIND_CLUSTER_NAME:-hugmesh-local}

playwright-deps: ## install the Playwright deps + chromium (needed once for e2e)
	cd tests/e2e && { [ -d node_modules ] || npm ci || npm install; } \
	  && npx playwright install --with-deps chromium

e2e: playwright-deps ## boot ROLE/ARCH in QEMU and run the Playwright e2e (default: x86 be+gpu)
	$(SUDO) tests/qemu/run-qemu-e2e.sh -w "$(WORK_DIR)" --target $(if $(filter arm64,$(ARCH)),pi,x86) --role $(ROLE)

ci: ## FULL pipeline: wipe -> build the whole fleet (Docker) -> QEMU-emulate + e2e (long; hours)
	$(MAKE) rebuild
	$(MAKE) e2e

ci-quick: ## fast pipeline: build only x86 be+gpu (Docker) -> emulate + e2e (host KVM)
	$(MAKE) clean
	$(MAKE) x86-be+gpu
	$(MAKE) e2e ARCH=x86 ROLE=be+gpu

## ── deprecated aliases (kept for muscle memory) ───────────────────────
docker: docker-image ## alias for docker-image (build the builder image)

docker-build: ## DEPRECATED: builds now default to Docker — just run `make build-all`
	@echo "Builds default to Docker now: run 'make build-all' (or 'make <target>')."
	@echo "Use NATIVE=1 for a local-Gentoo (host/in-container) build."

## ── LOCAL STACK (docker-compose; clone+build+run the whole platform) ──────────
# Runs the ENTIRE HugMesh platform on x86_64 via docker-compose, building every
# service from its cloned repo. Linux: `make stack-up`. Windows (Docker Desktop):
# scripts/stack-up.ps1. See docs/LOCAL-STACK.md.
#
# ENV selector (same test|prod knob as the image build): test = local placeholder
# Casdoor issuer (http://localhost:8000); prod = the REAL issuer (CASDOOR_ISSUER
# or https://id.<DOMAIN>; prod creds come from your env / keys USB, NOT committed).
# SOCIAL=1 also brings up the heavy Synapse/Mastodon tier (the `social` profile).
STACK_COMPOSE   := tests/stack/compose.local.yaml
STACK_SRC       ?= $(CURDIR)/.stack-src
PUBLIC_HOST_PORT ?= 8088
# HTTPS twin of the front door (the https-front TLS terminator in the compose
# file proxies it to the same fe-gateway). 8488 pairs with 8088; 8443 is NOT
# the default because dev boxes commonly have something else on it already.
PUBLIC_HTTPS_PORT ?= 8488
# Per-machine TLS material for the https front door — minted by `make
# stack-certs` (gen-certs.sh), gitignored. NOT tests/stack/certs: those are
# committed mock-stack fixtures whose CA key is public in the repo.
STACK_TLS_DIR   := tests/stack/.tls-front
GIT_BASE        ?= https://github.com/Snapdragon-Systems
GIT_REF         ?= main
SOCIAL          ?=
# ENV -> Casdoor issuer URI used by every service (overridable via CASDOOR_ISSUER).
ifeq ($(ENV),prod)
CASDOOR_ISSUER ?= https://id.$(if $(strip $(DOMAIN)),$(DOMAIN),hugmesh.systems)
else
CASDOOR_ISSUER ?= http://localhost:8000
endif
# External-IdP seam (Entra ID et al — see the azure-image provider's entra/ emit
# from hugmesh-cloud-deploy): OIDC_ISSUER, when set NON-EMPTY, overrides the
# derived CASDOOR_ISSUER above and rides the SAME CASDOOR_ISSUER_URI threading
# below — the CASDOOR_* env NAMES are cross-repo bindings and are deliberately
# NOT renamed. Default/empty = today's Casdoor-derived behavior, byte-for-byte.
#   make stack-up OIDC_ISSUER=https://login.microsoftonline.com/<tenant>/v2.0
OIDC_ISSUER ?=
ifneq ($(strip $(OIDC_ISSUER)),)
CASDOOR_ISSUER := $(OIDC_ISSUER)
endif
# Env exported into every compose invocation (build contexts + service env).
# DOCKER_BUILDKIT=1 belt-and-braces: several service Dockerfiles use BuildKit
# syntax (`# syntax=docker/dockerfile:1.7` + RUN --mount=type=secret), which a
# legacy-builder fallback (e.g. an env where the user-scoped buildx plugin in
# ~/.docker/cli-plugins is not visible) fails on with opaque parse errors.
# Translation catalogs the login-ui image ships (comma-separated locale tags).
# EMPTY (default) = English-only: zero catalog files in the image, zero catalog
# requests in the browser. English is the login-ui's source language, so it needs
# no catalog and the default is the smallest artifact. Threaded into the compose
# build arg (tests/stack/compose.local.yaml -> the login-ui Dockerfile's
# ARG SNAP_WEB_LOCALES); the Studio sets it via LocalMeshBootstrapConfig.web_locales.
#   make stack-up SNAP_WEB_LOCALES=de,fr
SNAP_WEB_LOCALES ?=
# MANAGED backing services (local-stack validation of managed mode; see
# specs/cluster/backing-services.yaml + docs/MANAGED-SERVICES.md). EMPTY by default
# so compose falls back to the in-stack containers BYTE-IDENTICALLY (the compose
# consumers read `$${MANAGED_*:-in-stack-default}`). Set one to a hosted endpoint to
# point the local stack at an external RDS/Azure-PG, e.g.
#   make stack-up MANAGED_ADMIN_BFF_R2DBC_URL='r2dbc:postgresql://my.rds:5432/adminbff'
# NOTE: the compose stack has no Kafka/ClickHouse/MinIO to replace — those managed
# ids are image-time only; local managed mode is DB-endpoint validation.
MANAGED_ADMIN_BFF_R2DBC_URL    ?=
MANAGED_ADMIN_BFF_LIQUIBASE_URL ?=
MANAGED_FORUM_BFF_R2DBC_URL    ?=
MANAGED_FORUM_BFF_LIQUIBASE_URL ?=
MANAGED_WIKI_BFF_R2DBC_URL     ?=
MANAGED_WIKI_BFF_LIQUIBASE_URL  ?=
STACK_ENV := STACK_SRC='$(STACK_SRC)' CASDOOR_ISSUER_URI='$(CASDOOR_ISSUER)' \
             PUBLIC_HOST_PORT='$(PUBLIC_HOST_PORT)' \
             PUBLIC_HTTPS_PORT='$(PUBLIC_HTTPS_PORT)' \
             SNAP_WEB_LOCALES='$(SNAP_WEB_LOCALES)' \
             MANAGED_ADMIN_BFF_R2DBC_URL='$(MANAGED_ADMIN_BFF_R2DBC_URL)' \
             MANAGED_ADMIN_BFF_LIQUIBASE_URL='$(MANAGED_ADMIN_BFF_LIQUIBASE_URL)' \
             MANAGED_FORUM_BFF_R2DBC_URL='$(MANAGED_FORUM_BFF_R2DBC_URL)' \
             MANAGED_FORUM_BFF_LIQUIBASE_URL='$(MANAGED_FORUM_BFF_LIQUIBASE_URL)' \
             MANAGED_WIKI_BFF_R2DBC_URL='$(MANAGED_WIKI_BFF_R2DBC_URL)' \
             MANAGED_WIKI_BFF_LIQUIBASE_URL='$(MANAGED_WIKI_BFF_LIQUIBASE_URL)' \
             DOCKER_BUILDKIT=1 COMPOSE_DOCKER_CLI_BUILD=1
STACK_PROFILE := $(if $(strip $(SOCIAL)),--profile social,)
STACK_TOR_PROFILE := $(if $(strip $(TOR)),--profile tor,)
COMPOSE_CMD   ?= docker compose
# ── private-maven cold-build wiring (see tests/stack/m2-bootstrap.sh) ──
# Four Java services (admin/user/mod-bff, federation-api) resolve org-PRIVATE
# systems.hugmesh:* maven artifacts at image-build time. `make
# stack-m2-bootstrap` builds those artifacts FROM SOURCE into a persistent
# cache and serves them from a local registry container, writing
# $(STACK_M2_ENV) (gitignored). Whenever that env file exists, every
# build-capable stack call auto-includes the committed override
# $(STACK_M2_COMPOSE), threading CI_API_V4_URL/GITLAB_GROUP_ID as build args.
# Without it, builds still work IF the images/artifacts are already local.
# The registry container name m2-bootstrap.sh creates (its own REGISTRY_NAME
# default). Declared here so `stack-clean` can remove it.
M2_REGISTRY_NAME ?= hugmesh-m2-registry
STACK_M2_ENV     := tests/stack/.m2-registry.env
STACK_M2_COMPOSE := tests/stack/compose.m2-local.yaml
STACK_M2_FLAGS    = $(if $(wildcard $(STACK_M2_ENV)),--env-file $(STACK_M2_ENV) -f $(STACK_M2_COMPOSE),)
# When SOCIAL=1, the included compose.real.yaml mastodon services need an
# env_file (tests/stack/.mastodon.env). Ensure it exists before any social
# compose call so the profile renders/runs (NOT needed for the core stack).
STACK_SOCIAL_DEP := $(if $(strip $(SOCIAL)),stack-mastodon-env,)

stack-clone: ## clone/update all hugmesh repos into ./.stack-src (idempotent; STACK_NO_CLONE=1 skips)
	@if [ -n "$(STACK_NO_CLONE)" ]; then \
	  echo "==> stack-clone: SKIPPED (STACK_NO_CLONE=1) — building from $(STACK_SRC) as-is"; \
	else \
	  STACK_SRC='$(STACK_SRC)' GIT_BASE='$(GIT_BASE)' GIT_REF='$(GIT_REF)' \
	    bash scripts/clone-all-repos.sh; \
	fi

# Guarantee tests/stack/.mastodon.env exists with non-empty dev secrets (only the
# SOCIAL=1 path needs it). Synapse's config/registration self-heals via its own
# service entrypoint (compose.real.yaml), same as tests/stack/up-real.sh; for
# Mastodon's db:prepare too, use tests/stack/up-real.sh instead — see
# docs/LOCAL-STACK.md.
#
# ALTERNATE_DOMAINS=mastodon-web:3000 is REQUIRED, not cosmetic: Mastodon's
# config/initializers/1_hosts.rb builds Rails' config.hosts from LOCAL_DOMAIN +
# WEB_DOMAIN + ALTERNATE_DOMAINS, and ActionDispatch::HostAuthorization 403s any
# request whose Host header isn't in that list. Spring Cloud Gateway's default
# HTTP client REWRITES the Host header to the proxied target's authority
# (mastodon-web:3000 — the be-gateway route to mastodon-web in
# gateway-routes/be/application-routes.yml), not the original client Host. Without
# this, LOCAL_DOMAIN=localhost alone never matches "mastodon-web:3000", so Rails
# blocks every be-gateway-proxied request with "Blocked hosts: mastodon-web:3000"
# — a 403 for EVERY role (mod/admin/user alike), independent of any Casdoor
# role/route-access decision. Reproduced + fixed live against the running compose
# stack (docker logs hugmesh-local-mastodon-web-1 showed the exact
# HostAuthorization block on every /api/v1/**, /api/v2/**, /oauth/** call proxied
# through the be-gateway).
# Delegated to tests/stack/gen-mastodon-env.sh (shared with up-real.sh) so a
# FRESH checkout gets a COMPLETE env: the old inline recipe only ran when the
# file was absent and never wrote ACTIVE_RECORD_ENCRYPTION_* (Mastodon v4.3 /
# Rails 7.1 refuses to boot without them) or EMAIL_DOMAIN_ALLOWLIST (required
# by seed-e2e.sh's @e2e.local personas). The script also self-heals an
# existing file: only missing/empty keys are generated, nothing is clobbered.
stack-mastodon-env:
	@bash tests/stack/gen-mastodon-env.sh

stack-m2-bootstrap: ## COLD-BUILD prereq: build the private systems.hugmesh maven artifacts FROM SOURCE + serve them from a local registry container
	bash tests/stack/m2-bootstrap.sh

# Idempotent: mints only when the leaf is absent, so an existing CA (one the
# operator may have imported into a browser trust store) is never silently
# rotated out from under them. ENV=prod with DOMAIN set also puts the real
# domain in the SANs; localhost/127.0.0.1 are ALWAYS included (gen-certs.sh).
stack-certs: ## mint the per-machine TLS CA + leaf for the https front door (idempotent; rm -rf tests/stack/.tls-front to re-mint)
	@if [ ! -f '$(STACK_TLS_DIR)/server.crt' ]; then \
	  SNAP_DOMAIN='$(if $(strip $(DOMAIN)),$(DOMAIN),hugmesh.systems)' \
	    bash tests/stack/gen-certs.sh '$(STACK_TLS_DIR)'; \
	else \
	  echo "==> stack-certs: $(STACK_TLS_DIR)/server.crt present - keeping it (rm -rf $(STACK_TLS_DIR) to re-mint)"; \
	fi

stack-build: stack-clone stack-certs $(STACK_SOCIAL_DEP) ## build every service from its cloned repo (no run)
	$(STACK_ENV) $(COMPOSE_CMD) -f $(STACK_COMPOSE) $(STACK_M2_FLAGS) $(STACK_PROFILE) $(STACK_TOR_PROFILE) build

stack-up: stack-clone stack-certs $(STACK_SOCIAL_DEP) ## clone -> build -> run the FULL stack (ENV=test|prod; SOCIAL=1 adds matrix/mastodon)
	@echo "==> Local stack: ENV=$(ENV), issuer=$(CASDOOR_ISSUER), host port=$(PUBLIC_HOST_PORT), social=$(if $(strip $(SOCIAL)),on,off)$(if $(wildcard $(STACK_M2_ENV)), m2-registry=on,)"
	$(STACK_ENV) $(COMPOSE_CMD) -f $(STACK_COMPOSE) $(STACK_M2_FLAGS) $(STACK_PROFILE) $(STACK_TOR_PROFILE) build
	$(STACK_ENV) $(COMPOSE_CMD) -f $(STACK_COMPOSE) $(STACK_M2_FLAGS) $(STACK_PROFILE) $(STACK_TOR_PROFILE) up -d
	@echo "==> Up. Front door: http://localhost:$(PUBLIC_HOST_PORT)  |  https://localhost:$(PUBLIC_HTTPS_PORT)  | Casdoor: http://localhost:8000"
	@echo "    (https uses the per-machine CA $(STACK_TLS_DIR)/ca.crt - import it to trust, or accept the browser warning)"
	@echo "    Logs: make stack-logs   Down: make stack-down"

stack-seed: ## seed Casdoor identity (org+roles+app-user-bff+personas) for real SSO login; SOCIAL=1 also seeds Matrix/Mastodon
	@echo "==> Seeding the running stack (Casdoor$(if $(strip $(SOCIAL)), + social,) tier)"
	$(if $(strip $(SOCIAL)),,SEED_CASDOOR_ONLY=1 )bash tests/stack/seed-e2e.sh
	@echo "==> Seeded. Real SSO web login: open http://localhost:$(PUBLIC_HOST_PORT)/login and sign in with an e2e persona (e.g. e2e-admin / e2e-pass)."

stack-down: ## stop the local stack and drop its volumes
	$(STACK_ENV) $(COMPOSE_CMD) -f $(STACK_COMPOSE) --profile social --profile tor down -v

# stack-down PLUS the disk: the ~28 images this stack BUILT (`--rmi local` — only
# images with no registry name, i.e. ours; never the pulled postgres/cassandra/
# mastodon bases other projects may share), any orphaned containers, and the
# private-maven registry container + its cache. Scoped to THIS compose project on
# purpose: no `docker system prune`, so nothing outside the local mesh is touched.
# The m2 cache is a rebuildable artifact (`make stack-m2-bootstrap` re-creates it
# from source), which is why it goes with the images rather than surviving.
stack-clean: ## stop the local stack AND remove the images it built + the m2 registry/cache
	@echo "==> Removing the local stack: containers, volumes, and the images IT built."
	@echo "    Pulled base images (postgres/cassandra/mastodon/...) are KEPT."
	$(STACK_ENV) $(COMPOSE_CMD) -f $(STACK_COMPOSE) --profile social --profile tor down -v --rmi local --remove-orphans
	@docker rm -f $(M2_REGISTRY_NAME) >/dev/null 2>&1 || true
	@rm -f $(STACK_M2_ENV)
	@echo '==> Clean. Next bring-up is a COLD build: run "make stack-m2-bootstrap", then "make stack-up".'

stack-logs: ## tail logs from the running local stack
	$(STACK_ENV) $(COMPOSE_CMD) -f $(STACK_COMPOSE) $(STACK_PROFILE) $(STACK_TOR_PROFILE) logs -f --tail=100

stack-ps: ## list the local stack's containers + status
	$(STACK_ENV) $(COMPOSE_CMD) -f $(STACK_COMPOSE) $(STACK_PROFILE) $(STACK_TOR_PROFILE) ps

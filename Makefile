# hugmesh image build / flash / emulate / test orchestrator.
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
#   scripts/build-all-roles.sh   the default fleet (3 Pi + x86 pki/backend/frontend/backend-gpu)
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
# Common overrides:  WORK_DIR=$(CURDIR)/out  JOBS=$(nproc)  ROLE=backend-gpu  ARCH=x86  DEV=/dev/sdX
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
# RE-SPELLED, never re-pointed: the same role the old `be+gpu` default named.
# Every old spelling still works (the builders normalize at parse time — see
# scripts/_roles-lib.sh), so `make flash-disk ROLE=be+gpu` keeps working.
ROLE     ?= backend-gpu
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
X86_ROLE_LIST := pki backend frontend backend-gpu
# X86_EVERY_ROLE: the FULL documented x86 matrix (nodes + omnibus + edge-ai +
# the client devices + the standalone desktops, incl. the UNAFFILIATED plain
# Gentoo one) — what `make build-everything` threads through
# build-all-roles.sh's X86_ROLES knob. omnibus is listed FIRST on purpose
# (issue #46): X86_ROLES is consumed in order, every x86 role shares the
# snap-build-x86 binpkg pool, and the most package-complete image must fill
# that pool before the roles that reuse it are queued.
X86_EVERY_ROLE := omnibus pki backend frontend backend-gpu edge-ai laptop chromebook desktop standalone-thin standalone-thick standalone-unaffiliated

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
#   JETSON_ROLE          = edge-ai (DEFAULT, headline) | backend-gpu | omnibus | desktop
#   JETSON_BOARD         = orin-nano (DEFAULT) | orin-nano-4gb | orin-nx-8gb | orin-nx-16gb
#   JETSON_KERNEL_FLAVOR = mainline (DEFAULT, buildable — NO CUDA) | l4t (stub)
JETSON_ROLE          ?= edge-ai
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
.PHONY: help menu kind-doctor kind-doctor-test mesh-node-up mesh-node-down mesh-node-status mesh-node-logs go-live go-live-menu clean build-all build-everything matrix-check inventory-check template-drift-check image-inventory pentest pentest-seed rebuild \
        rpi x86 omnibus prebuild-binaries frite frite-live frite-installer jetson orangepi5 orangepi5-live orangepi5-installer \
        orangepizero2 orangepizero2-live orangepizero2-installer \
        orangepizero2w orangepizero2w-live orangepizero2w-installer \
        orangepizero3 orangepizero3-live orangepizero3-installer \
        orangepi3-lts orangepi3-lts-live orangepi3-lts-installer \
        orangepi4-lts orangepi4-lts-live orangepi4-lts-installer \
        phone-plan phone-detect phone-fetch phone-flash phone-mdm-enroll phone-attest phone-enroll phone-profile phone-rotate-profile-pass phone-remove-profile phone-ingest phone-status phone-wizard \
        quest-plan quest-detect quest-mdm-enroll quest-enroll quest-ingest quest-status quest-wizard \
        deploy-plan deploy-apply deploy-status deploy-destroy \
        flash qemu qemu-rpi qemu-x86 qemu-matrix qemu-matrix-enumerate qemu-mesh qemu-mesh-enumerate \
        playwright-deps e2e e2e-list ci ci-quick docker-image ensure-image image-gen-docker-image \
        docker docker-build local prod \
        stack-clone stack-mastodon-env stack-m2-bootstrap stack-certs stack-build stack-up stack-halt stack-down stack-logs stack-ps stack-e2e stack-e2e-list \
        kind-images kind-up kind-e2e kind-e2e-mfa kind-mfa-posture kind-down kind-honesty \
        kind-metrics-check kind-addon-check \
        view view-list view-stop view-trust view-untrust view-honesty \
        scan-hardware sessions-list sessions-show sessions-artifacts sessions-delete

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
	@echo "              x86 (nodes+omnibus+edge-ai+clients+standalone) |"
	@echo "              frite (arm64 light desktop) | jetson (arm64 Tegra edge-AI — EXPERIMENTAL,"
	@echo "              JETSON_ROLE=edge-ai|backend-gpu|omnibus|desktop, hardware validation pending) |"
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

# ── Studio headless faces (Qt-free — the GUI is a thin face over these) ─────────
# The wizard HardwarePage's probe and the Welcome page's build-session history,
# via the same `python -m hugmesh_studio` flag channel as --print-command (#49).
scan-hardware: ## probe THIS machine (CPU/GPU/Wi-Fi/BT) + recommended build settings (JSON=1)
	@PYTHONPATH=studio python3 -m hugmesh_studio --scan-hardware $(if $(JSON),--json)

sessions-list: ## recorded build sessions, one line each: id, date, roles, status, artifacts (JSON=1)
	@PYTHONPATH=studio python3 -m hugmesh_studio --list-sessions $(if $(JSON),--json)

sessions-show: ## one build session's full record (ID=… [JSON=1])
	@PYTHONPATH=studio python3 -m hugmesh_studio --show-session "$(ID)" $(if $(JSON),--json)

sessions-artifacts: ## one build session's artifact files (ID=… [JSON=1])
	@PYTHONPATH=studio python3 -m hugmesh_studio --session-artifacts "$(ID)" $(if $(JSON),--json)

sessions-delete: ## delete a session record — refuses without YES=1 (ID=… YES=1 [ARTIFACTS=1])
	@PYTHONPATH=studio python3 -m hugmesh_studio --delete-session "$(ID)" $(if $(YES),--yes) $(if $(ARTIFACTS),--delete-artifacts)

# ── Local Docker mesh FROM SCRATCH (generate creds + start a superadmin mesh) ────
# The "generate & start a NEW local mesh from scratch" path: mint ALL credentials
# (gen-cluster-secrets.sh + gen-provision-keys.sh) then bring up the FULL platform
# stack (make stack-up) seeded with a fresh superadmin, plus the mesh overlay in prod.
# Drives the SAME Qt-free object graph the Studio dialog + ncurses menu use
# (core/local_mesh_bootstrap.py) — it composes the gen scripts + LocalStackNode +
# LocalMeshNode and adds NO new compose invocation. Builds NO image. NON-destructive:
# `plan` only previews; `up` is the explicit action (prod TTY-confirms, no bypass).
# Knobs: ENV=test|prod, SOCIAL=1, SUPERADMIN=…, CLUSTER_DOMAIN=…, AUTHKEY_FILE=…,
# OWN_CASDOOR_DOMAINS="team.example shop.example" (#47 — each named domain runs its
# OWN Casdoor; unnamed domains keep the superdomain default, nothing threads).
_MESH_BOOTSTRAP_ARGS = --env "$(ENV)" $(if $(strip $(SOCIAL)),--social) \
  $(if $(SUPERADMIN),--superadmin-username "$(SUPERADMIN)") \
  $(if $(CLUSTER_DOMAIN),--cluster-domain "$(CLUSTER_DOMAIN)") \
  $(foreach d,$(OWN_CASDOOR_DOMAINS),--own-casdoor-domain "$(d)") \
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

build-all: ## build the DEFAULT fleet: 3 Pi + x86 pki/backend/frontend/backend-gpu (--resume reuses sysroots)
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
GOLIVE_DOMAIN   ?= $(if $(strip $(DOMAIN)),$(DOMAIN),hugmesh.net)
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
	$(DOCKER_RUN) make rpi NATIVE=1 WORK_DIR=/out IMG_FLAGS='$(IMG_FLAGS)' JOBS=$(JOBS) RPI_BOARD='$(RPI_BOARD)' RPI_ROLES='$(RPI_ROLES)' $(BRAND_PASS)
else
	@for r in $(RPI_ROLES); do echo "==> Pi $$r ($(RPI_BOARD))"; $(RPI) --role $$r || exit 1; done
	$(chown-artifacts)
endif

x86: ## build the 4 default x86 roles (.img + live ISO + .fs.tar.xz each)
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make x86 NATIVE=1 WORK_DIR=/out IMG_FLAGS='$(IMG_FLAGS)' JOBS=$(JOBS) X86_ROLE_LIST='$(X86_ROLE_LIST)' $(BRAND_PASS)
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

rpi-%: ## build ONE Pi role: make rpi-frontend | rpi-desktop  (same vocabulary as x86 now; add IMG_FLAGS='--no-iso' etc.; RPI_BOARD=rpi5 [DEFAULT] | rpi4 | rpi3 [desktop-only]; STANDALONE_FLAGS='--standalone --local-user … --local-pass …' for rpi-desktop)
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make rpi-$* NATIVE=1 WORK_DIR=/out IMG_FLAGS='$(IMG_FLAGS)' JOBS=$(JOBS) RPI_BOARD='$(RPI_BOARD)' $(BRAND_PASS)
else
	@$(RPI) --role $* $(STANDALONE_FLAGS)
	$(chown-artifacts)
endif

x86-%: ## build ONE x86 role: make x86-backend-gpu | x86-pki | x86-standalone-thin (old spellings still work: x86-be, x86-fe, x86-be+gpu)
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

jetson: ## build the Jetson Orin edge-AI image (JETSON_ROLE=edge-ai|backend-gpu|omnibus|desktop; EXPERIMENTAL; STANDALONE_FLAGS='--enable-wifi …')
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make jetson NATIVE=1 WORK_DIR=/out JOBS=$(JOBS) IMG_FLAGS='$(IMG_FLAGS)' $(BRAND_PASS) $(JETSON_PASS)
else
	@$(JETSON_BUILD) --role $(JETSON_ROLE) --board $(JETSON_BOARD) --kernel-flavor $(JETSON_KERNEL_FLAVOR) $(STANDALONE_FLAGS)
	$(chown-artifacts)
endif

jetson-%: ## build ONE Jetson role: make jetson-edge-ai | jetson-backend-gpu | jetson-omnibus | jetson-desktop (STANDALONE_FLAGS appended verbatim)
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
build-everything: ## build the FULL documented matrix: 3 Pi + all 12 x86 (nodes+omnibus+edge-ai+clients+standalone incl. unaffiliated) + Frite + Jetson + Orange Pi 5 + Orange Pi Zero 2 + Orange Pi Zero 2W + Orange Pi Zero 3 + Orange Pi 3 LTS + Orange Pi 4 LTS (honors ENV=test|prod)
	$(MAKE) build-all \
	  X86_ROLES='$(X86_EVERY_ROLE)' \
	  FRITE=1 FRITE_BOARD='$(FRITE_BOARD)' FRITE_FLAVOR='$(FRITE_FLAVOR)' \
	  FRITE_DESKTOP='$(FRITE_DESKTOP)' \
	  JETSON=1 JETSON_ROLES='edge-ai backend-gpu omnibus desktop' \
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

# TEMPLATE-DRIFT gate over EVERY archetype (scripts/validate-repo-templates-all.sh).
# scripts/validate-repo-templates.sh grades ONE archetype per run and was wired into
# no pipeline at all — its only automated caller was case B8 of tests/domain-registry/
# test-templating-rename-pr.sh, `--archetype generator`. Three of the six overlays
# rotted behind that. These are class-A templates (the generator overwrites them
# wholesale in every rendered tenant), so a stale one strips content from every tenant
# on the next render. Needs node + scripts/tooling/node_modules (npm ci) and a base per
# archetype: exemplar clones come from pull-repo-base.sh, or point <NAME>_BASE_DIR at a
# local read-only clone to run it offline. Build host only, no root.
template-drift-check: ## prove every archetype template still matches its exemplar repo (scripts/validate-repo-templates-all.sh)
	@test -f scripts/validate-repo-templates-all.sh \
	  || { echo "scripts/validate-repo-templates-all.sh not found — the archetype drift gate is not in this checkout yet."; exit 1; }
	bash scripts/validate-repo-templates-all.sh

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
IMAGE_GEN_TAG ?= registry.hugmesh.net/hugmesh/image-gen:latest
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

qemu-x86: ## boot an x86 role image in QEMU: make qemu-x86 ROLE=backend-gpu
	$(SUDO) tests/qemu/launch-x86.sh -w "$(WORK_DIR)" -r $(ROLE) --foreground

qemu: qemu-$(if $(filter arm64,$(ARCH)),rpi,x86) ## boot ROLE/ARCH in QEMU (ARCH=x86|arm64)

qemu-matrix: ## boot+assert size/load for matrix rows (opt-in; HUGMESH_QEMU_E2E=1; MATRIX_FILTER=x86/backend-gpu)
	HUGMESH_QEMU_E2E=$(if $(HUGMESH_QEMU_E2E),$(HUGMESH_QEMU_E2E),1) \
	  $(SUDO) tests/qemu/run-matrix-e2e.sh -w "$(WORK_DIR)" $(if $(MATRIX_FILTER),--only $(MATRIX_FILTER),)

qemu-matrix-enumerate: ## dry-run enumerate every matrix row + its launcher/size/RAM (no boot, no build)
	tests/qemu/run-matrix-e2e.sh --dry-run $(if $(MATRIX_FILTER),--only $(MATRIX_FILTER),)

# 3-node emulated k8s cluster (issue #48 PR B): control-plane kubeadm init +
# two pinned-token joins over a shared QEMU mcast L2 (launch-x86.sh --mesh-net),
# every node behind its own per-run qcow2 overlay — the golden images are NEVER
# written (and overlays are never committed back: `qemu-img commit` against a
# live device silently rewrites the golden artifact). Opt-in like qemu-matrix.
qemu-mesh: ## boot a 3-node emulated k8s cluster (opt-in; HUGMESH_QEMU_MESH=1; CP_ROLE=pki WORKER_ROLE=be IMG=…)
	HUGMESH_QEMU_MESH=$(if $(HUGMESH_QEMU_MESH),$(HUGMESH_QEMU_MESH),1) \
	  $(SUDO) tests/qemu/mesh-cluster.sh -w "$(WORK_DIR)" \
	  $(if $(CP_ROLE),--cp-role $(CP_ROLE),) $(if $(WORKER_ROLE),--worker-role $(WORKER_ROLE),) \
	  $(if $(IMG),--img "$(IMG)",)

qemu-mesh-enumerate: ## plan the 3-node emulated cluster (L2 spec, MACs/IPs, ports, launcher argv; nothing boots)
	tests/qemu/mesh-cluster.sh --dry-run \
	  $(if $(CP_ROLE),--cp-role $(CP_ROLE),) $(if $(WORKER_ROLE),--worker-role $(WORKER_ROLE),)

# SELinux AVC workout (issue #45): boot ONE image, drive the workloads
# specs/selinux/*.te confine, harvest AVCs, and emit the narrowing report
# (denials grouped by source type -> owning .te). Run once per image type.
# ENFORCING=1 runs the workload under `setenforce 1` (the enforcing campaign);
# the boot itself always provisions permissive, like the enforce-gate posture.
.PHONY: avc-workout
PLATFORM ?= x86
avc-workout: ## SELinux AVC workout for ONE image: make avc-workout PLATFORM=x86 ROLE=pki [IMG=…] [ENFORCING=1]
	$(SUDO) tests/qemu/avc-workout.sh --platform $(PLATFORM) --role $(ROLE) -w "$(WORK_DIR)" \
	  $(if $(IMG),--img "$(IMG)",) $(if $(BOARD),--board "$(BOARD)",) \
	  $(if $(KERNEL),--kernel "$(KERNEL)",) $(if $(filter 1,$(ENFORCING)),--enforcing,)

# Containerized emulated-device tests (tests/qemu/run-qemu-docker.sh): one
# --privileged container per platform/role row, against a build session's
# artifacts. NO $(SUDO) on purpose — the whole point of the container is that
# `docker` group membership replaces the interactive sudo password the loop
# mounts would otherwise demand (see docker/Dockerfile.qemu-runner).
.PHONY: qemu-docker qemu-docker-image qemu-docker-list
# NOT $(JOBS): that defaults to nproc for compiles — nproc CONCURRENT emulated
# devices would hold nproc x 2GB of guest RAM. Two is the deliberate default
# (one slow TCG ARM row + one KVM x86 row).
QEMU_JOBS ?= 2
qemu-docker-image: ## build the containerized QEMU runner image (hugmesh-qemu-runner:latest)
	docker build -f docker/Dockerfile.qemu-runner -t hugmesh-qemu-runner:latest .

qemu-docker: ## containerized device tests, Pi rows first (SESSION=out/sessions/<id>; MATRIX_FILTER=rpi5/pki; QEMU_JOBS=2)
	tests/qemu/run-qemu-docker.sh $(if $(SESSION),--session "$(SESSION)",) \
	  $(if $(MATRIX_FILTER),--only "$(MATRIX_FILTER)",) --jobs $(QEMU_JOBS)

qemu-docker-list: ## enumerate the device rows a session's artifacts can boot (nothing runs)
	tests/qemu/run-qemu-docker.sh $(if $(SESSION),--session "$(SESSION)",) --list

# Whole-mesh save (#50 item 10): every LIVE emulated device's disk + its KEYS
# stick payload into ONE flashable save-set under out/qemu-runs/saves/. Drives
# the SAME Qt-free core the Studio uses (core/emulation_save.py), which in turn
# drives the landed run-qemu-docker.sh --save-device per device — no new copy
# mechanism. `-plan` previews (nothing pauses); `save` acts. Knobs:
# SAVE_SESSION=name, SAVE_ONLY=rpi5 (label substring), SAVE_OVERWRITE=1,
# QEMU_WORK=dir (the runner --work the mesh is running in).
.PHONY: qemu-save-mesh qemu-save-mesh-plan
_EMU_SAVE_ARGS = $(if $(QEMU_WORK),--work "$(QEMU_WORK)") \
  $(if $(SAVE_SESSION),--session "$(SAVE_SESSION)") \
  $(if $(SAVE_ONLY),--only "$(SAVE_ONLY)") \
  $(if $(filter 1,$(SAVE_OVERWRITE)),--overwrite) \
  --generator-dir .

qemu-save-mesh-plan: ## preview saving the WHOLE emulated mesh (disk budget + KEYS sticks; nothing runs)
	@PYTHONPATH=studio python3 -m hugmesh_studio.core.emulation_save plan $(_EMU_SAVE_ARGS)

qemu-save-mesh: ## save EVERY live emulated device's disk + KEYS stick to a flashable set (SAVE_ONLY=… SAVE_SESSION=…)
	@PYTHONPATH=studio python3 -m hugmesh_studio.core.emulation_save save $(_EMU_SAVE_ARGS)

# Whole-mesh emulation, one lane end to end: boot/inspect/stop the emulated mesh
# through the SAME Qt-free facade the Studio pages and the TUI drive
# (core/emulation.py), which composes qemu_tests + qemu_devices + mesh_emulation +
# emulation_save — no argv is spelled here that a core does not author. Knobs:
# SESSION=<name|path> (default: the newest COMPLETE session — a partial, aborted
# session is skipped, not silently half-booted), QEMU_WORK=dir, QEMU_JOBS=N (the
# keep-alive boot-admission gate; 0 = ungated), JSON=1 on status.
.PHONY: mesh-emu-up mesh-emu-status mesh-emu-down
_MESH_EMU_ARGS = $(if $(SESSION),--session "$(SESSION)") \
  $(if $(QEMU_WORK),--work "$(QEMU_WORK)") \
  $(if $(QEMU_JOBS),--jobs $(QEMU_JOBS)) \
  --generator-dir .

mesh-emu-up: ## boot the WHOLE mesh emulated: --keep-alive fan-out over the session, device registry, web front door
	@PYTHONPATH=studio python3 -m hugmesh_studio.core.emulation up $(_MESH_EMU_ARGS)

mesh-emu-status: ## reconciled per-device state + verdicts for the emulated mesh (JSON=1 for machine-readable)
	@PYTHONPATH=studio python3 -m hugmesh_studio.core.emulation status $(_MESH_EMU_ARGS) $(if $(filter 1,$(JSON)),--json)

mesh-emu-down: ## stop every emulated device the harness started (sweeps stale port claims too)
	@PYTHONPATH=studio python3 -m hugmesh_studio.core.emulation down $(_MESH_EMU_ARGS)

# ── kind SSO e2e — the same native-login proof the compose stack runs
# (tests/e2e/specs/27-native-login.spec.ts), against a REAL kind cluster
# running the GitOps payload (ArgoCD + Vault/ESO/Casdoor + fe-gateway + BFFs).
# Flow: kind-images builds the first-party images from ./.stack-src and
# `kind load`s them under the exact rendered refs; kind-up brings up
# bootstrap-kind.sh KIND_PROFILE=sso (apps + Vault KV + e2e identity seed);
# kind-e2e resolver-maps hugmesh.net -> 127.0.0.1 (kind-local.yaml maps
# the internal ingress out on :8443) and runs spec 27. No /etc/hosts edits,
# no sudo. See specs/cluster/bootstrap/kind-local/README.md.
# ONLY=<repo>[,<repo>...] rebuilds a SUBSET rather than every image — the
# difference between a one-image UI iteration and a full rebuild that includes
# three unrelated Java builds. Unknown names FAIL rather than filtering to
# nothing, because a typo that loads no image while exiting 0 leaves the cluster
# serving the old code and looks exactly like "my fix did not work":
#   make kind-images ONLY=hugmesh-host-shell
#   make kind-images ONLY=hugmesh-host-shell,hugmesh-login-ui
kind-images: stack-clone stack-m2-bootstrap ## build + `kind load` the SSO-slice first-party images (ONLY=repo[,repo] for a subset)
	ONLY='$(ONLY)' bash scripts/kind-load-images.sh

# KIND_ADDONS — the infra add-on SELECTION channel (operator ask 2026-08-26).
# `make kind-up` used to pass KIND_PROFILE and MFA and nothing else, so the only
# way to add an infra Application to the curated set was to edit
# bootstrap-kind.sh. That is why apps/01-metrics-server.yaml sat in no profile
# while the sso profile deployed seven HPAs with no resource-metrics API to read.
#
#   make kind-up                              # default: KIND_ADDONS=metrics-server
#   make kind-up KIND_ADDONS=metrics-server,keda
#   make kind-up KIND_ADDONS=none             # opt OUT (the HPAs go inert again)
#
# PASSED ONLY WHEN NON-EMPTY, and that is load-bearing rather than tidy. make
# expands an unset variable to the empty string, so an unconditional
# `KIND_ADDONS='$(KIND_ADDONS)'` would hand the script an EMPTY value on every
# plain `make kind-up`. The script reads empty as UNSET (falling back to its own
# default) for exactly that reason — but relying on that would put the default in
# two places, and the one in the Makefile would be the silent one. Leaving the
# assignment out entirely keeps bootstrap-kind.sh the single authority on what
# "no selection" means. `none` is the spelling for "none of them".
_KIND_ADDONS_ENV := $(if $(strip $(KIND_ADDONS)),KIND_ADDONS='$(strip $(KIND_ADDONS))',)

kind-up: ## bring up the kind SSO slice (KIND_PROFILE=sso bootstrap: apps + Vault KV + e2e seeds; MFA=1 flips gateway mfa.enabled; KIND_ADDONS=<slug,...>|none selects infra add-ons; SKIP_EGRESS_PREFLIGHT=1 for an air-gapped host)
	KIND_PROFILE=sso MFA='$(MFA)' $(_KIND_ADDONS_ENV) bash specs/cluster/bootstrap/kind-local/bootstrap-kind.sh

kind-e2e: playwright-deps ## run the native-login e2e (spec 27) against the kind cluster
	cd tests/e2e && \
	  SNAP_BASE_URL='https://hugmesh.net:8443' \
	  SNAP_HOST_RESOLVER='MAP hugmesh.net 127.0.0.1, MAP *.hugmesh.net 127.0.0.1' \
	  npx playwright test specs/27-native-login.spec.ts

# ── kind MFA e2e — spec 29 against the REAL kind cluster, at whatever posture that
# cluster is ACTUALLY holding.
#
# `make kind-up MFA=1` exists so the kind lane can carry live route-level MFA
# enforcement (§8 of docs/MFA-ROLLOUT.md), but until this target there was no way to
# RUN the MFA spec against either kind lane: kind-e2e runs spec 27 only. The two lanes
# needed different coverage and got none.
#
# The posture is READ BACK off the running gateway pod (scripts/kind-mfa-posture.sh),
# never taken from the caller's shell and never inferred from the repo. It cannot be
# inferred from the repo: kind-up flips MFA through an ArgoCD helm PARAMETER, so the
# committed chart says `mfa.enabled: false` on a cluster that is enforcing. Spec 29
# SELECTS between its OFF-posture block and its per-row enforcement block on that
# value, so reading it live means either lane is self-describing and neither can run
# the wrong block. The helper is fail-closed: no cluster, no reading, no run.
kind-e2e-mfa: playwright-deps ## run the MFA e2e (spec 29) against the kind cluster at its LIVE posture
	@posture="$$(bash scripts/kind-mfa-posture.sh --value)" || exit 1; \
	  echo "==> kind gateway APP_MFA_ENABLED=$${posture} (read from the running pod; flip with 'make kind-up MFA=1')"; \
	  cd tests/e2e && \
	    SNAP_BASE_URL='https://hugmesh.net:8443' \
	    SNAP_HOST_RESOLVER='MAP hugmesh.net 127.0.0.1, MAP *.hugmesh.net 127.0.0.1' \
	    APP_MFA_ENABLED="$${posture}" \
	    npx playwright test specs/29-mfa-privileged-floor.spec.ts

kind-mfa-posture: ## print the kind gateway's LIVE APP_MFA_ENABLED (fail-closed; never guesses)
	@bash scripts/kind-mfa-posture.sh

# The BEHAVIOURAL half of the metrics-server add-on. Asserting that
# 01-metrics-server.yaml is in an array proves the string is in the array and
# nothing else; this asks the CLUSTER whether metrics.k8s.io answers and whether a
# named HPA has stopped reporting <unknown>. SKIPS LOUDLY (exit 0, with the reason
# and the words "nothing was measured") when there is no cluster, and never
# creates one — a bring-up is minutes of image pulls and is the operator's call.
# NOT in the pre-merge shell-suite gate for exactly that reason: on a hosted
# runner it could only ever skip. Run it after `make kind-up`.
kind-metrics-check: ## ask the LIVE kind cluster whether the metrics API answers and the HPAs read real numbers
	bash tests/scripts/test-kind-metrics-api.sh

# The kind lane's service-selection channel, offline (Studio -> Makefile ->
# bootstrap-kind.sh). Also gated pre-merge in .github/workflows/shell-suites.yml.
kind-addon-check: ## offline: prove a KIND_ADDONS selection reaches bootstrap-kind.sh
	bash tests/scripts/test-kind-addon-channel.sh

kind-down: ## delete the kind cluster
	kind delete cluster --name $${KIND_CLUSTER_NAME:-hugmesh-local}

# kind-doctor — the standing "can this cluster actually run the mesh?" check.
#
# hugmesh-generator#349: on 2026-09-10 this lane had been dead for two days
# while `kind get clusters` listed the cluster and `kubectl get nodes` said
# Ready. Nineteen pods were in ImagePullBackOff and the failed-pull counter had
# passed thirteen thousand. Two causes, neither detected anywhere: the host had
# lost docker's netfilter rules (so nothing could leave the bridge, while the
# error text said "lookup ... i/o timeout" and read like DNS), and `make
# kind-images` had never run so no first-party image existed in the node at all.
# This target reports; it never repairs.
# KIND_DOCTOR_WARN_ONLY is pinned to 0 here on purpose. The script reads it
# from the AMBIENT environment (bootstrap-kind.sh's closing summary sets it per
# command, which is legitimate), so without this pin an exported value in the
# operator's shell would silently disarm the standing check and make this target
# exit 0 through a cluster that cannot run.
kind-doctor: ## is the kind cluster capable of running the mesh? (egress, images, pods, ArgoCD)
	KIND_DOCTOR_WARN_ONLY=0 bash scripts/kind-doctor.sh

# Offline honesty gate for the two ways kind-up used to report work it had not
# done: an identity seed that exits 0 through Casdoor's HTTP-200 denials, and a
# "idempotent" KV seed that re-minted every password onto Postgres volumes that
# keep the first run's. Runs the REAL seed hook + helpers against stubs — no
# cluster, no kind, no docker, no network. Also runs in CI (lint:kind-bootstrap-honesty).
kind-honesty: ## offline: prove the kind SSO harness cannot report an unperformed seed
	bash tests/scripts/test-kind-bootstrap-honesty.sh

# The doctor's own guard. Offline: stubs docker and kubectl and replays both
# halves of the 2026-09-10 outage (no egress; no first-party image) to prove the
# check actually goes red on each — plus the negative-tooling cases, because a
# guard that goes green when its OWN tooling breaks is worse than no guard.
# It also extracts and EXECUTES bootstrap-kind.sh's egress preflight, the half
# of #350 that can hard-abort a bring-up.
#
# Mutation-tested: 13 mutations of scripts/kind-doctor.sh and
# bootstrap-kind.sh's preflight, all 13 killed, each verified to have actually
# changed the file and each restored to its exact sha256 afterwards. The number
# here is what was measured, not a round claim — an earlier round asserted
# "seven mutations, all seven killed" while three trivial ones survived, every
# one of them in a code path no scenario exercised. Five of these thirteen
# survived here too, until the tests they answer to stopped asking the easy
# question. The battery, and what each survivor taught, is in the header of
# tests/scripts/test-kind-doctor.sh.
kind-doctor-test: ## offline: prove kind-doctor detects the outage it was written for
	bash tests/scripts/test-kind-doctor.sh

# The secrets half of the same question kind_route_closure.py asks about routes:
# every ExternalSecret this tree APPLIES must read a Vault path the seed WRITES,
# or be written down with a reason. hugmesh-generator#352 — external-secrets-config
# sits permanently Degraded with four unexplained SecretSyncedError rows, which
# makes a REAL secret failure indistinguishable from the background noise.
kind-secret-closure: ## offline: every applied ExternalSecret reads a seeded Vault path, or is explained
	bash tests/scripts/test-kind-secret-closure.sh

# ── local browsing — put ANY front door in THIS machine's browser
# Sits here because the kind lane is its first consumer, but it covers all
# local lanes (LANE=kind|kind-svc|compose|device). The problem it solves is that
# every front door routes by HOST HEADER, the names do not resolve without an
# /etc/hosts entry (root), and the https door pairs a self-signed cert with
# HSTS — which Chrome refuses to let you click through and then remembers for a
# year. hugmesh-view serves the doors as HTTPS on 127.0.0.1 under a
# loopback-only CA and speaks the right Host upstream. NO root, NO /etc/hosts
# edit, and — after one `make view-trust` — no cert prompt either. The domain ->
# port mapping is scripts/hugmesh-view.tsv; every row's port has an env override
# (HUGMESH_VIEW_PORT_<NAME>) so a collision is a one-line fix.
#
# LANE=kind (the default) is ONE door: the host shell. Everything a user
# reaches, they reach THROUGH it as a federated remote, so exposing each service
# on its own side port is how a broken federated route stays invisible.
# LANE=kind-svc opts into the platform's own UIs when you are debugging it.
# See docs/LOCAL-TESTING.md "Browsing the mesh from THIS machine".
view: ## serve the local front doors in the browser (LANE=kind|kind-svc|compose|device; OPEN=1 launches it)
	python3 scripts/hugmesh-view.py up --lane '$(or $(LANE),kind)' --background \
	  $(if $(OPEN),--open,) $(VIEW_ARGS)

# One-time, per workstation. Installs the loopback-only CA into THIS user's own
# NSS stores (~/.pki/nssdb for Chrome, each Firefox profile) — user-writable, no
# root. The CA is name-constrained to localhost/127.0.0.0/8/::1, so it cannot
# vouch for anything but the loopback doors; `make view-untrust` removes it.
view-trust: ## trust the local CA so the doors open with no warning (once per machine)
	python3 scripts/hugmesh-view.py trust $(VIEW_ARGS)

view-untrust: ## remove the local CA from this user's browser trust stores
	python3 scripts/hugmesh-view.py untrust $(VIEW_ARGS)

view-list: ## show the domain -> loopback-port map (no side effects)
	python3 scripts/hugmesh-view.py list $(VIEW_ARGS)

view-stop: ## stop the background view session (and sweep any stale port-forwards)
	python3 scripts/hugmesh-view.py stop $(VIEW_ARGS)

# Offline gate for the above: a fake kubectl and a fake certutil on PATH, HOME
# redirected into a temp dir so no real browser trust store is reachable, a
# loopback stand-in for the upstream, and a NEGATIVE CONTROL per behaviour so
# the gate is proven to bite. No cluster, no network, no root.
view-honesty: ## offline: prove the view tool's rewrites, CA constraints, collisions and cleanup
	bash tests/scripts/test-hugmesh-view.sh

# ── THE e2e TOOLCHAIN PROBE ──────────────────────────────────────────────────
# ONE readiness check, tests/e2e/check-toolchain.sh, and every e2e target below
# runs it in place of the `[ -d tests/e2e/node_modules ]` it used to carry.
#
# WHY. MEASURED 2026-08-27 on origin/main f1c41bb3: `[ -d node_modules ]` is
# satisfied by ANY node_modules, however stale. This box's install predated the
# Gherkin lane, so every e2e target passed its own precondition and then died on
# "Error: Cannot find module 'playwright-bdd'" (playwright.config.ts:2) or "To get
# bddgen CLI please install playwright-bdd" — the OFFLINE guards could not even
# start. The browser half was worse: a Studio-driven run
# (tests/e2e/test-results/studio-20260827-062152/report.json) had 36 of its 38
# failures as "browserType.launch: Executable doesn't exist at
# .../chromium_headless_shell-1228/..." — the pinned @playwright/test wanted
# headless-shell r1228, only r1234 was in ~/.cache/ms-playwright, every browser
# test failed for the TOOLCHAIN and nothing before the run said so.
#
# The probe verifies, offline and in ~0.2s: package.json agrees with the COMMITTED
# package-lock.json; node_modules was written by npm and matches the lock (hidden
# lockfile AND the files on disk); every declared dep require.resolve()s; and the
# chromium + chromium-headless-shell revision the INSTALLED playwright-core's
# browsers.json names is present (INSTALLATION_COMPLETE) under the Playwright
# browsers path (PLAYWRIGHT_BROWSERS_PATH honoured). It prints every missing
# thing and the one command that fixes it. tests/scripts/test-e2e-toolchain-
# readiness.sh is its guard: it breaks synthesised trees each of those ways and
# requires the probe to go red, and renders every target below to prove the
# probe is what they run.
E2E_READY = bash tests/e2e/check-toolchain.sh

# INSTALL, and only when the probe says something is missing. A READY tree is
# left alone (kind-e2e / kind-e2e-mfa / e2e depend on this target, so it has to
# be free when there is nothing to do) — but the skip is decided by the PROBE,
# never by the directory existing.
#
# `npm ci`, with NO `|| npm install` fallback. The old recipe's fallback is how a
# lock that had drifted from package.json (playwright-bdd declared, never locked)
# installed "successfully" for weeks while `npm ci` on the same tree could not
# succeed at all. package-lock.json is now COMMITTED; drift between it and
# package.json is a repo defect, and this target says so and stops.
#
# `--with-deps` is OPT-IN (PLAYWRIGHT_WITH_DEPS=1): it runs the distro package
# manager under sudo, wants a Debian-ish root, and this box has NO sudo, so the
# default is the plain `npx playwright install chromium` that works anywhere the
# system libraries are already present. Set it once on a fresh Debian/Ubuntu CI
# image. The probe runs again at the end so the target cannot exit 0 with the
# toolchain still broken.
playwright-deps: ## install the e2e toolchain (npm ci + chromium) unless tests/e2e/check-toolchain.sh already says READY (PLAYWRIGHT_WITH_DEPS=1 adds --with-deps; needs sudo)
	@if $(E2E_READY); then exit 0; fi; \
	  cd tests/e2e && \
	  { npm ci || { echo "==> npm ci FAILED. If it reported package.json and package-lock.json out of sync: run 'npm install' in tests/e2e and COMMIT tests/e2e/package-lock.json (it is tracked; the old fallback to a plain install, which hid exactly this, is gone on purpose)."; exit 2; }; } && \
	  npx playwright install $(if $(PLAYWRIGHT_WITH_DEPS),--with-deps ,)chromium && \
	  cd ../.. && $(E2E_READY)

# E2E_ARGS here is NOT the same shape as stack-e2e's. There, `npx playwright test`
# is the DIRECT consumer and bare argv is correct. This lane interposes a shell
# script whose parser ends in `*) echo "Unknown arg: $1"; usage 1`, so an
# unseparated `--grep @smoke` (or a bare spec path) is a HARD ERROR, not a
# passthrough — which is exactly how this target shipped broken on 2026-08-26.
# The `--` is therefore load-bearing, and the $(if ...) keeps an unset E2E_ARGS
# from emitting a dangling separator. e2e-list below must stay identical, and
# tests/qemu/qemu-e2e-lane_test.sh asserts BOTH by rendering `make -n` and feeding
# the result to the real parser.
e2e: playwright-deps ## boot ROLE/ARCH in QEMU and run the Playwright e2e (default: x86 backend-gpu)
	$(SUDO) tests/qemu/run-qemu-e2e.sh -w "$(WORK_DIR)" --target $(if $(filter arm64,$(ARCH)),pi,x86) --role $(ROLE) $(if $(E2E_ARGS),-- $(E2E_ARGS))

# Enumerate what the QEMU Playwright lane WOULD run — the boot plan plus the spec
# tree — as one JSON document. NO root, no image, no network, no boot: `--list`
# runs before run-qemu-e2e.sh's artifact-autodetect, so a tree that has built
# nothing yet still describes the lane (missing artifacts come back as nulls).
# Deliberately NOT gated on playwright-deps: the spec half degrades to a LOUD,
# named skip inside the JSON when tests/e2e/node_modules is absent, and the boot
# plan is still worth answering. tests/qemu/qemu-e2e-lane_test.sh pins both halves.
e2e-list: ## enumerate the QEMU Playwright lane (boot plan + specs) as JSON; boots nothing, needs no root
	@tests/qemu/run-qemu-e2e.sh -w "$(WORK_DIR)" --target $(if $(filter arm64,$(ARCH)),pi,x86) --role $(ROLE) --list $(if $(E2E_ARGS),-- $(E2E_ARGS))

ci: ## FULL pipeline: wipe -> build the whole fleet (Docker) -> QEMU-emulate + e2e (long; hours)
	$(MAKE) rebuild
	$(MAKE) e2e

ci-quick: ## fast pipeline: build only x86 backend-gpu (Docker) -> emulate + e2e (host KVM)
	$(MAKE) clean
	$(MAKE) x86-backend-gpu
	$(MAKE) e2e ARCH=x86 ROLE=backend-gpu

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
# SOCIAL=1 also brings up the heavy tuwunel/Mastodon tier (the `social` profile).
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
GIT_BASE        ?= https://github.com/hugmesh
GIT_REF         ?= main
SOCIAL          ?=
# ALTERNATIVE third-party social backends (tests/stack/compose.alt-social.yaml),
# each DEFAULT-OFF behind its own compose profile and independent of SOCIAL:
#   PHPBB=1   phpBB       — alternative FORUM to the first-party forum-ui/-bff
#   AKKOMA=1  Akkoma      — alternative FEDIVERSE server to Mastodon
# They compose with each other and with SOCIAL, e.g.
#   make stack-up SOCIAL=1 AKKOMA=1     (Mastodon AND Akkoma side by side)
PHPBB           ?=
AKKOMA          ?=
# ANUBIS=1 — the Techaro Anubis proof-of-work anti-scraper gate in front of the
# web routes (compose.local.yaml's `anubis` profile; the cluster's
# specs/cluster/manifests/anubis). The gate publishes on ANUBIS_HOST_PORT (8923)
# and forwards to the fe-gateway, so 8088/8488 stay the DIRECT doors and 8923 is
# the PoW-gated one. STACK_EGRESS_FLAGS already consumed $(ANUBIS) to select the
# profile, but the knob was never DECLARED here and threaded no env, so
# admin-bff's Anubis console stayed dark even with the gate up;
# STACK_ANUBIS_ENV below is what lights it.
#   make stack-up ANUBIS=1
ANUBIS          ?=
# TTS=1 — edge-ai-tts (Piper TTS + visemes; compose.edge-ai-tts.yaml, DEFAULT-OFF)
TTS             ?=
# POISONER=1 — the AI MEDIA CLOAK worker (hugmesh-media-poisoner;
# compose.media-poisoner.yaml, DEFAULT-OFF). Turning this on does BOTH halves,
# which is the whole point of the knob: it starts the worker AND flips the
# user-bff's media.poisoning.enabled, which ships DARK (application.yml
# MEDIA_POISONING_ENABLED:false). With only one half the "AI media cloak" control
# in the user preferences stays greyed out — exactly the state the operator hit
# after enabling every AI service (report 2026-08-14).
#
# Runs CPU-only here: the worker's default image is the lean Pillow+numpy baseline
# with no torch (its Dockerfile is explicit that it "runs on any node, including a
# CPU-only test node"). /health then reports device `cpu`, and the cloak is the
# reduced-strength tier rather than the GPU PGD one — real, and honestly labelled.
#   make stack-up POISONER=1
POISONER        ?=
# The cloak mode applied to an opted-in upload, and what happens when the heavy
# tier is unavailable. Defaults match the BFF's own (glaze / skip); with the
# worker up, `light` is the useful fallback because there IS a CPU tier to fall
# back TO — `skip` would forward the image UNCLOAKED.
POISON_MODE     ?= glaze
POISON_FALLBACK ?= light
# Egress VPN for the local mesh (tests/stack/compose.egress-vpn.yaml): EGRESS_VPN=1
# brings up a fail-closed WireGuard CLIENT container and attaches mastodon-sidekiq's
# netns to it, so Mastodon's outbound federation egresses via the tunnel — the local
# translation of the builder's --egress-vpn FILE lane (build-x86-host-stage4.sh:4258,
# `if ${ROLE_CLIENT} && [ -n "${EGRESS_VPN_FILE}" ]` — the line number drifts, the anchor does not).
# EGRESS_VPN_CONF must point at a provider wg-quick .conf (WireGuard ONLY — .ovpn is
# not supported locally). DEFAULT-OFF; without the conf the VPN container refuses to
# start and the attached service stays down (fail-closed, never a direct leak).
#   make stack-up SOCIAL=1 EGRESS_VPN=1 EGRESS_VPN_CONF=$$HOME/proton-wg0.conf
EGRESS_VPN      ?=
EGRESS_VPN_CONF ?=
# ENV -> Casdoor issuer URI used by every service (overridable via CASDOOR_ISSUER).
ifeq ($(ENV),prod)
CASDOOR_ISSUER ?= https://id.$(if $(strip $(DOMAIN)),$(DOMAIN),hugmesh.net)
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
# The OTHER HALF of the same seam (the Studio's local-mesh bootstrap exports all
# three vars together — studio core/local_stack_node.py): the external client id
# and JWKS URL, threaded on the SAME frozen CASDOOR_* compose names (cross-repo
# bindings — extend, never rename, exactly like CASDOOR_ISSUER_URI above):
#   OIDC_CLIENT_ID -> CASDOOR_APP_CLIENT_ID  (the BFF login/exchange client id
#                     admin-bff/user-bff read via APP_BFF_OIDC_CLIENT_ID)
#   OIDC_JWKS_URI  -> CASDOOR_JWKS_URI       (where every gateway + resource
#                     server fetches signing keys for JWT validation)
# EMPTY (the default) expands to NOTHING — not to an empty assignment — so the
# compose-side `${CASDOOR_APP_CLIENT_ID:-app-user-bff}` /
# `${CASDOOR_JWKS_URI:-http://casdoor:8000/.well-known/jwks}` defaults apply
# byte-identically AND an operator's own exported override still reaches the
# containers (the STACK_MFA_FLOOR_ENV rule). No JWKS derivation happens here:
# set OIDC_JWKS_URI alongside OIDC_ISSUER (providers differ — Entra serves
# /discovery/v2.0/keys, not /.well-known/jwks; the Studio always derives and
# exports it). NOTE the seam re-points token VALIDATION only: native
# /bff/login, MFA step-up and role claims stay Casdoor-coupled
# (docs/IDENTITY-PROVIDERS.md "Honest limits"), and `make stack-seed` still
# seeds the in-stack Casdoor with its own app-user-bff client, untouched by
# these vars.
#   make stack-up OIDC_ISSUER=https://login.microsoftonline.com/<t>/v2.0 \
#     OIDC_CLIENT_ID=app-mesh OIDC_JWKS_URI=https://login.microsoftonline.com/<t>/discovery/v2.0/keys
OIDC_CLIENT_ID ?=
OIDC_JWKS_URI ?=
STACK_OIDC_ENV := $(if $(strip $(OIDC_CLIENT_ID)),CASDOOR_APP_CLIENT_ID='$(OIDC_CLIENT_ID)' ,)$(if $(strip $(OIDC_JWKS_URI)),CASDOOR_JWKS_URI='$(OIDC_JWKS_URI)' ,)
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
# ARG HUG_WEB_LOCALES); the Studio sets it via LocalMeshBootstrapConfig.web_locales.
#   make stack-up HUG_WEB_LOCALES=de,fr
#
# RENAME PHASE 3c — DUAL WRITE, new name primary. HUG_WEB_LOCALES is the live
# spelling; SNAP_WEB_LOCALES is the retired one, still ACCEPTED here and still
# EMITTED below. Both halves of that are load-bearing and neither is decoration:
#
#   accepted (input): the Studio that invokes `make stack-up` is a SEPARATELY
#     INSTALLED app pointed at whatever generator checkout the operator has
#     (LocalStackNode.generator_dir), so an older Studio — and every operator
#     habit, script and shell history that says `make stack-up SNAP_WEB_LOCALES=`
#     — can hand this Makefile the old name. A Makefile that read only the new
#     one would take that as "unset", ship English-only, and exit 0. Nothing
#     would print. That silent-empty is the exact failure this rename ladder
#     exists to avoid, so the old name keeps working until phase 4 removes it.
#
#   emitted (output): the value crosses into ANOTHER REPO's image build (the
#     login-ui Dockerfile). That Dockerfile dual-reads today (ARG HUG_WEB_LOCALES
#     + ARG SNAP_WEB_LOCALES, tools/i18n/emit-shipped-locales.mjs prefers the new
#     name when NON-EMPTY), but STACK_SRC is cloned from pinned branches, so the
#     checkout being built is not necessarily new enough to declare the new ARG.
#     Emitting both means the worst case is docker's VISIBLE "build-args were not
#     consumed" warning instead of a silently un-translated UI.
#
# Precedence is NON-EMPTY-wins, not `?=`-style defined-wins, and it has to be:
# the Studio and the Makefile both materialise the new name unconditionally, so
# "defined" carries no information — only emptiness does. Same rule the consumer
# applies (tools/i18n/emit-shipped-locales.mjs webLocalesEnv()); the two ends
# disagreeing about what counts as "set" would put the locale list back in play.
HUG_WEB_LOCALES  ?=
SNAP_WEB_LOCALES ?=
# The one effective value both names carry downstream. `:=` (immediate) and
# defined ABOVE STACK_ENV on purpose — STACK_ENV is itself `:=`, so a variable
# referenced there but assigned later expands to EMPTY and the knob goes dark,
# the same trap STACK_POISONER_ENV's comment pins.
STACK_WEB_LOCALES := $(if $(strip $(HUG_WEB_LOCALES)),$(HUG_WEB_LOCALES),$(SNAP_WEB_LOCALES))
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
# MFA PRIVILEGED FLOOR, opt-in per run — the compose rehearsal of
# docs/MFA-ROLLOUT.md §3 step 7 (the runbook's single most dangerous flag; §2).
# MFA_FLOOR=1 threads APP_MFA_ENFORCE_PRIVILEGED_FLOOR=true into every compose
# gateway, so SUPERADMIN/ADMIN/GAME-MASTER need a FRESH second factor on the
# seeded mfa_required rows and privileged requests answer 503 + Retry-After
# during route-access cold-start priming. tests/e2e/specs/29-mfa-privileged-floor.spec.ts
# gates its floor legs on the SAME variable name, so one spelling drives both.
# EMPTY (the default) expands to NOTHING — not to an empty assignment — so the
# compose-side `${APP_MFA_ENFORCE_PRIVILEGED_FLOOR:-false}` default applies AND
# an operator's own exported override still reaches the containers. The leading
# space lives inside the $(if) then-part so the default STACK_ENV is
# byte-identical, not merely equivalent.
#   make stack-up MFA_FLOOR=1
MFA_FLOOR ?=
STACK_MFA_FLOOR_ENV := $(if $(strip $(MFA_FLOOR)), APP_MFA_ENFORCE_PRIVILEGED_FLOOR='true',)
# ANUBIS=1 also flips admin-bff's Anubis console on (compose defaults it false so
# an untouched bring-up stays byte-identical — the STACK_MFA_FLOOR_ENV rule).
STACK_ANUBIS_ENV := $(if $(strip $(ANUBIS)), ANUBIS_ENABLED='true',)
# MFA OPERATIONAL FLIP, opt-in per run — issue #47, following the PHPBB=1/AKKOMA=1
# knob precedent. ONE switch, three lanes, and it flips ONLY app.mfa.enabled — the
# freshness window keeps its default (600000) and the privileged floor stays on its
# OWN deliberate switch (MFA_FLOOR=1 above; never coupled to this one):
#   * compose lane (make stack-up MFA=1): threads an EXPLICIT APP_MFA_ENABLED='true'
#     so the run is ON even when the operator's shell exports APP_MFA_ENABLED=false.
#     EMPTY (the default) expands to NOTHING, so the compose-side
#     `${APP_MFA_ENABLED:-true}` dev default applies AND an exported override still
#     reaches the containers — a plain `make stack-up` stays byte-identical.
#   * kind SSO lane (make kind-up MFA=1): threaded into bootstrap-kind.sh, which
#     adds a `mfa.enabled=true` HELM PARAMETER to every gateway Application it
#     applies (a runtime patch, same mechanism as its ingress.className override —
#     the committed chart and specs/cluster/apps stay untouched and default-OFF,
#     which tests/stack/test-gateway-mfa-env.sh and
#     tests/scripts/test-mfa-required-rules.sh keep enforcing).
#   * per-domain/tenant lane: NOT this variable — set MFA=1 in the brand profile
#     (brands/<brand>.conf) and generate-brand-repos.sh renders mfa.enabled: true
#     into that ONE brand's gateway Applications ({{MFA_ENABLED}} token).
# Wiring for all three lanes is gated by tests/stack/test-mfa-flip-wiring.sh.
# ⚠ Enforcement preconditions (enroll BEFORE you enforce, machine-caller census)
# are unchanged: docs/MFA-ROLLOUT.md §2/§3 still apply to every lane.
#   make stack-up MFA=1        /  make kind-up MFA=1
MFA ?=
STACK_MFA_ENV := $(if $(strip $(MFA)), APP_MFA_ENABLED='true',)
# Runtime web-login THEME persistence (tests/stack/.theme.css, gitignored).
# The Studio's theme choice used to travel ONLY as an env var on the GUI's own
# `make` invocation — so any TERMINAL `make stack-up` (a restore, a rebuild, a
# peer's bring-up) silently reverted the login page to the shipped default
# brand, which reads as "my theme choices are not applied". The Studio now also
# WRITES the composed token CSS to this file, and whenever it exists the recipe
# shell threads its text as HUG_THEME_CSS (login-ui's 50-snap-theme.sh writes it
# verbatim at container start — env is the transport BY DESIGN, no image
# rebuild). Delete the file to return to the shipped brand.
#
# ONE spelling is exported here, deliberately, and it is the NEW one. The old
# SNAP_THEME_CSS is not ALSO set because this Makefile and the compose file it
# invokes ($(STACK_COMPOSE), a pinned in-tree path) are always the same checkout
# and cannot version-skew — so a second export would buy no coverage while
# threading a multi-kilobyte CSS blob through argv twice, and running $(cat) a
# second time. The legacy spelling is honoured ONE layer down instead, in
# compose.local.yaml's `${HUG_THEME_CSS:-${SNAP_THEME_CSS:-}}` value, which is
# where a host env set by someone OTHER than this Makefile actually arrives.
STACK_THEME_FILE := tests/stack/.theme.css
STACK_THEME_ENV := $(if $(wildcard $(STACK_THEME_FILE)),HUG_THEME_CSS="$$(cat $(STACK_THEME_FILE))",)
BRANDB_CASDOOR := http://casdoor-brandb.localtest.me:8001
comma := ,
# BRAND_B=1 -> the opt-in per-brand issuer registry (DomainRegistry /
# TenancyResourceServerConfig). Empty otherwise: every service stays
# byte-identical single-issuer (the '=' ConditionalOnExpression never fires).
STACK_BRAND_B_ENV := $(if $(strip $(BRAND_B)),APP_TENANCY_ISSUERS='$(CASDOOR_ISSUER)=default$(comma)$(BRANDB_CASDOOR)=brandb' APP_TENANCY_HOSTS='brandb.localtest.me=brandb' ,)
# AI-cloak env threaded into the user-bff (see the POISONER knob above). Empty
# unless POISONER=1, so the BFF keeps its shipped-dark defaults otherwise. The
# worker URL is the compose service name — the same in-network dial the cluster
# Deployment does via its Service name. MUST be defined ABOVE STACK_ENV: that is
# a `:=` immediate assignment, so a variable referenced there but defined later
# expands to EMPTY and the knob silently does nothing.
STACK_POISONER_ENV := $(if $(strip $(POISONER)),MEDIA_POISONING_ENABLED='true' MEDIA_POISONING_WORKER_URL='http://hugmesh-media-poisoner:8080' MEDIA_POISONING_DEFAULT_MODE='$(POISON_MODE)' MEDIA_POISONING_FALLBACK_MODE='$(POISON_FALLBACK)' ,)
STACK_ENV := $(STACK_BRAND_B_ENV)$(STACK_POISONER_ENV)$(STACK_OIDC_ENV)$(STACK_THEME_ENV) \
             STACK_SRC='$(STACK_SRC)' CASDOOR_ISSUER_URI='$(CASDOOR_ISSUER)' \
             PUBLIC_HOST_PORT='$(PUBLIC_HOST_PORT)' \
             PUBLIC_HTTPS_PORT='$(PUBLIC_HTTPS_PORT)' \
             HUG_WEB_LOCALES='$(STACK_WEB_LOCALES)' \
             SNAP_WEB_LOCALES='$(STACK_WEB_LOCALES)' \
             MANAGED_ADMIN_BFF_R2DBC_URL='$(MANAGED_ADMIN_BFF_R2DBC_URL)' \
             MANAGED_ADMIN_BFF_LIQUIBASE_URL='$(MANAGED_ADMIN_BFF_LIQUIBASE_URL)' \
             MANAGED_FORUM_BFF_R2DBC_URL='$(MANAGED_FORUM_BFF_R2DBC_URL)' \
             MANAGED_FORUM_BFF_LIQUIBASE_URL='$(MANAGED_FORUM_BFF_LIQUIBASE_URL)' \
             MANAGED_WIKI_BFF_R2DBC_URL='$(MANAGED_WIKI_BFF_R2DBC_URL)' \
             MANAGED_WIKI_BFF_LIQUIBASE_URL='$(MANAGED_WIKI_BFF_LIQUIBASE_URL)'$(STACK_MFA_FLOOR_ENV)$(STACK_MFA_ENV)$(STACK_ANUBIS_ENV) \
             EGRESS_VPN_CONF='$(abspath $(EGRESS_VPN_CONF))' \
             DOCKER_BUILDKIT=1 COMPOSE_DOCKER_CLI_BUILD=1
STACK_PROFILE := $(if $(strip $(SOCIAL)),--profile social,)
STACK_TOR_PROFILE := $(if $(strip $(TOR)),--profile tor,)
# Alternative-backend profiles (phpBB / Akkoma). Separate from STACK_PROFILE so
# they stack additively: SOCIAL=1 AKKOMA=1 passes BOTH --profile flags. These
# must be threaded into every compose call that STACK_PROFILE is, or the service
# is invisible to it — a `down` that omits the profile silently leaves the
# containers running, and `ps`/`logs` show nothing.
STACK_ALT_PROFILE := $(if $(strip $(PHPBB)),--profile phpbb,) $(if $(strip $(AKKOMA)),--profile akkoma,)
# Second-brand Casdoor (BRAND_B=1) — tests/stack/compose.brand-b.yaml. Also see
# STACK_BRAND_B_ENV above: the same knob threads the multi-issuer registry.
STACK_BRAND_B_PROFILE := $(if $(strip $(BRAND_B)),--profile brandb,) $(if $(strip $(TTS)),--profile edge-ai-tts,) $(if $(strip $(POISONER)),--profile media-poisoner,)
# Games WASM asset tier (compose.games.yaml). GAMES=1 -> `--profile games`.
# Builds from the SIBLING ../hugmesh-games clone (GAMES_SRC overrides) — NOT
# cloned by stack-clone. Threaded everywhere STACK_PROFILE is (see the
# STACK_ALT_PROFILE note above for why a missed `down` strands containers).
STACK_GAMES_PROFILE := $(if $(strip $(GAMES)),--profile games,)
# Per-domain OWN Casdoor (issue #47): the Studio writes the (gitignored)
# $(STACK_OWN_CASDOOR_COMPOSE) overlay — one Casdoor (+ postgres) per Domains-table
# row whose sign-in says 'own', mirroring the proven compose.brand-b.yaml wiring on
# host ports 8001+ — and threads OWN_CASDOOR=1 plus the multi-issuer APP_TENANCY_*
# registry env (studio core/own_casdoor.py + core/local_stack_node.py). The -f is
# wildcard-gated (the .theme.css persistence rule: a terminal `make stack-up` keeps
# honouring what the Studio wrote; absent on every untouched checkout), and every
# generated service sits behind the `own-casdoor` profile, so a stale overlay with
# OWN_CASDOOR unset changes nothing. Down/halt/clean carry the -f + profile via
# $(STACK_OWN_CASDOOR_DOWN_FLAGS) (the reap rule — the profile is listed there
# unconditionally like every other profile; --profile with no matching service is
# harmless).
STACK_OWN_CASDOOR_COMPOSE := tests/stack/.compose.own-domains.yaml
STACK_OWN_CASDOOR_FLAGS := $(if $(wildcard $(STACK_OWN_CASDOOR_COMPOSE)),-f $(STACK_OWN_CASDOOR_COMPOSE),) $(if $(strip $(OWN_CASDOOR)),--profile own-casdoor,)
STACK_OWN_CASDOOR_DOWN_FLAGS := $(if $(wildcard $(STACK_OWN_CASDOOR_COMPOSE)),-f $(STACK_OWN_CASDOOR_COMPOSE),) --profile own-casdoor
# Egress-VPN overlay: a conditional -f (NOT just a profile) because the overlay also
# sets network_mode: service:hugmesh-egress-vpn on mastodon-sidekiq, which must not
# be in the model at all unless EGRESS_VPN=1. The down targets pass the -f + profile
# UNCONDITIONALLY (same reap rule as the alt profiles above).
# Resource-limit overlay (CPU / memory ceilings for the whole local stack).
# GENERATED by the Studio (hugmesh_studio/core/stack_limits.py) on every bring-up
# from the operator's "Resource limits" setting, and DELETED again when limits are
# turned off. Included through $(wildcard) exactly like the own-casdoor overlay, for
# the same reason: a terminal `make stack-up` must honour a setting the operator made
# in the GUI, and with no file present the compose invocation is byte-identical to
# what it was before the feature existed. Dot-prefixed and gitignored — never commit
# a machine-specific core count.
STACK_LIMITS_COMPOSE := tests/stack/.compose.limits.yaml
STACK_LIMITS_FLAGS := $(if $(wildcard $(STACK_LIMITS_COMPOSE)),-f $(STACK_LIMITS_COMPOSE),)

STACK_EGRESS_COMPOSE := tests/stack/compose.egress-vpn.yaml
STACK_EGRESS_FLAGS := $(if $(strip $(EGRESS_VPN)),-f $(STACK_EGRESS_COMPOSE) --profile egress-vpn,) $(if $(strip $(ANUBIS)),--profile anubis,)
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

# stack-m2-check — the env file records the registry container's BRIDGE IP, which
# docker reassigns whenever the daemon restarts or the container is recreated. The
# file has always SAID so in a comment ("Re-run 'make stack-m2-bootstrap' if docker
# restarted"), but nothing enforced it: stack-up/stack-build happily fed a stale IP
# to every Maven build, which then failed deep inside a Dockerfile with
#   Could not transfer artifact ... Connect to <old-ip>:8080 failed: Connection refused
# — a message that names Maven, not the registry, and sends you hunting the wrong
# thing. (2026-08-05: the daemon restart SIGKILLed the registry (exit 137); the file
# still pointed at .3 while the restarted container came back on .4.)
# This target re-derives the truth and SELF-HEALS by re-running the bootstrap, which
# is idempotent and skips every already-cached artifact (seconds, not a rebuild).
.PHONY: stack-m2-check
stack-m2-check:
	@[ -f $(STACK_M2_ENV) ] || exit 0
	@live=$$(docker inspect -f '{{.State.Running}}' $(M2_REGISTRY_NAME) 2>/dev/null || echo false); \
	 ip=$$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(M2_REGISTRY_NAME) 2>/dev/null || true); \
	 want=$$(sed -n 's|^CI_API_V4_URL=http://\([^:]*\):.*|\1|p' $(STACK_M2_ENV)); \
	 if [ "$$live" != "true" ] || [ -z "$$ip" ] || [ "$$ip" != "$$want" ]; then \
	   echo "==> m2 registry stale (running=$$live ip=$${ip:-none} env=$${want:-none}) — re-running stack-m2-bootstrap"; \
	   $(MAKE) --no-print-directory stack-m2-bootstrap; \
	 fi

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
# SOCIAL=1 path needs it). tuwunel needs no first-run step: it is configured
# entirely declaratively via TUWUNEL_* env on its service (compose.real.yaml),
# same as tests/stack/up-real.sh; for Mastodon's db:prepare too, use
# tests/stack/up-real.sh instead — see docs/LOCAL-STACK.md.
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
	  SNAP_DOMAIN='$(if $(strip $(DOMAIN)),$(DOMAIN),hugmesh.net)' \
	    bash tests/stack/gen-certs.sh '$(STACK_TLS_DIR)'; \
	else \
	  echo "==> stack-certs: $(STACK_TLS_DIR)/server.crt present - keeping it (rm -rf $(STACK_TLS_DIR) to re-mint)"; \
	fi

stack-build: stack-clone stack-certs stack-m2-check $(STACK_SOCIAL_DEP) ## build every service from its cloned repo (no run)
	$(STACK_ENV) $(COMPOSE_CMD) -f $(STACK_COMPOSE) $(STACK_M2_FLAGS) $(STACK_PROFILE) $(STACK_ALT_PROFILE) $(STACK_TOR_PROFILE) $(STACK_GAMES_PROFILE) $(STACK_BRAND_B_PROFILE) $(STACK_OWN_CASDOOR_FLAGS) $(STACK_LIMITS_FLAGS) $(STACK_EGRESS_FLAGS) build

stack-up: stack-clone stack-certs stack-m2-check $(STACK_SOCIAL_DEP) ## clone -> build -> run the FULL stack (ENV=test|prod; SOCIAL=1 adds matrix/mastodon)
	@echo "==> Local stack: ENV=$(ENV), issuer=$(CASDOOR_ISSUER), host port=$(PUBLIC_HOST_PORT), social=$(if $(strip $(SOCIAL)),on,off)$(if $(strip $(MFA)), mfa=ON(explicit),)$(if $(strip $(MFA_FLOOR)), mfa-floor=ON,)$(if $(wildcard $(STACK_M2_ENV)), m2-registry=on,)"
	$(STACK_ENV) $(COMPOSE_CMD) -f $(STACK_COMPOSE) $(STACK_M2_FLAGS) $(STACK_PROFILE) $(STACK_ALT_PROFILE) $(STACK_TOR_PROFILE) $(STACK_GAMES_PROFILE) $(STACK_BRAND_B_PROFILE) $(STACK_OWN_CASDOOR_FLAGS) $(STACK_LIMITS_FLAGS) $(STACK_EGRESS_FLAGS) build
	$(STACK_ENV) $(COMPOSE_CMD) -f $(STACK_COMPOSE) $(STACK_M2_FLAGS) $(STACK_PROFILE) $(STACK_ALT_PROFILE) $(STACK_TOR_PROFILE) $(STACK_GAMES_PROFILE) $(STACK_BRAND_B_PROFILE) $(STACK_OWN_CASDOOR_FLAGS) $(STACK_LIMITS_FLAGS) $(STACK_EGRESS_FLAGS) up -d
	@echo "==> Up. Front door: http://localhost:$(PUBLIC_HOST_PORT)  |  https://localhost:$(PUBLIC_HTTPS_PORT)  | Casdoor: http://localhost:8000"
	@echo "    (https uses the per-machine CA $(STACK_TLS_DIR)/ca.crt - import it to trust, or accept the browser warning)"
	@echo "    Logs: make stack-logs   Down: make stack-down"

# The post-seed registration note, chosen at PARSE time by
# SEED_COMPLETE_REGISTRATION (a command-line assignment and an environment
# export both reach make's variable space, so either spelling flips it). The
# old block printed the "Re-run with SEED_COMPLETE_REGISTRATION=1" hint
# UNCONDITIONALLY — a static @echo, not a report — so a run where the flag WAS
# set (and leg 1c had just run, or just failed loudly) still ended by implying
# the flag had not been passed. reference: the 2026-08-27 recreated-stack
# incident, where that hint sent the diagnosis toward "make does not forward
# the variable" (it does — leg 1c running at all proves it).
# `make -n stack-seed [SEED_COMPLETE_REGISTRATION=1]` shows only the live
# variant, which is how tests/scripts/test-seed-password-reconcile.sh pins this
# without running a stack.
ifeq ($(SEED_COMPLETE_REGISTRATION),1)
define STACK_SEED_STAGE2_NOTE
@echo "    Registration STAGE 2 ran in this seed (SEED_COMPLETE_REGISTRATION=1): the personas are"
@echo "    onboarded — minus the deliberately-gated set (e2e-pending, rbac-pending-gmail-com,"
@echo "    e2e-banned, plus every email-shaped invite fixture; the seed log's 'left gated on"
@echo "    purpose' count is the exact tally) — and mesh-operator can navigate every app."
@echo "    Verify by outcome, not by this banner:"
@echo "    GET /bff/session must report registrationComplete=true for an onboarded persona."
endef
else
define STACK_SEED_STAGE2_NOTE
@echo "    NOTE: this seeds registration STAGE 1 (the Casdoor identity) only. Until stage 2"
@echo "    (POST /bff/register/complete) runs, GET /bff/session reports registrationComplete=false,"
@echo "    the gateway grants only a bare ROLE_USER, and every service route 403s — you can sign in"
@echo "    but not navigate. Re-run with SEED_COMPLETE_REGISTRATION=1 to onboard the personas too"
@echo "    (the Studio's local-mesh bring-up passes it; the e2e suite deliberately does not)."
endef
endif

stack-seed: ## seed Casdoor identity (org+roles+app-user-bff+personas) for real SSO login; SOCIAL=1 also seeds Matrix/Mastodon
	@echo "==> Seeding the running stack (Casdoor$(if $(strip $(SOCIAL)), + social,) tier)"
	$(if $(strip $(SOCIAL)),,SEED_CASDOOR_ONLY=1 )$(if $(strip $(BRAND_B)),CASDOOR_BRAND_B_URL='$(BRANDB_CASDOOR)' )bash tests/stack/seed-e2e.sh
	@pw="$$(bash tests/stack/e2e-password.sh)"; \
	  echo "==> Seeded. Real SSO web login: open http://localhost:$(PUBLIC_HOST_PORT)/login and sign in with an e2e persona (e.g. e2e-admin / $$pw) — $$pw is also readable from .e2e-credentials at the repo root."
	$(STACK_SEED_STAGE2_NOTE)

stack-halt: ## stop the local stack but KEEP its data (identity, rooms, accounts, DBs)
	# The NON-DESTRUCTIVE stop. `stack-down` below passes -v, which drops every
	# named volume — Casdoor identity, Matrix rooms, Mastodon accounts, the phpBB
	# board and all the BFF databases. That is the right default for a throwaway
	# test lane, but it is NOT what an operator means by "stop my mesh": the
	# Studio's Stop button called stack-down and silently wiped the operator's
	# whole mesh, so restarting left them unable to log in, post, or open the
	# forum until a full re-seed. Containers and images still go; only the data
	# survives, so `make stack-up` brings the same mesh back.
	$(STACK_ENV) $(COMPOSE_CMD) -f $(STACK_COMPOSE) -f $(STACK_EGRESS_COMPOSE) --profile social --profile tor --profile anubis --profile phpbb --profile akkoma --profile games --profile brandb --profile edge-ai-tts --profile media-poisoner --profile egress-vpn $(STACK_OWN_CASDOOR_DOWN_FLAGS) down

stack-down: ## stop the local stack and DROP ITS VOLUMES (destroys identity/rooms/accounts — use stack-halt to keep them)
	# Every profile is listed UNCONDITIONALLY (not via the PHPBB=1/AKKOMA=1
	# knobs): `down` must reap containers started by an EARLIER `up` whose knobs
	# this invocation does not repeat, or `make stack-down` leaves the phpbb/
	# akkoma containers and volumes orphaned while reporting success.
	$(STACK_ENV) $(COMPOSE_CMD) -f $(STACK_COMPOSE) -f $(STACK_EGRESS_COMPOSE) --profile social --profile tor --profile anubis --profile phpbb --profile akkoma --profile games --profile brandb --profile edge-ai-tts --profile media-poisoner --profile egress-vpn $(STACK_OWN_CASDOOR_DOWN_FLAGS) down -v

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
	$(STACK_ENV) $(COMPOSE_CMD) -f $(STACK_COMPOSE) -f $(STACK_EGRESS_COMPOSE) --profile social --profile tor --profile anubis --profile phpbb --profile akkoma --profile games --profile brandb --profile edge-ai-tts --profile media-poisoner --profile egress-vpn $(STACK_OWN_CASDOOR_DOWN_FLAGS) down -v --rmi local --remove-orphans
	@docker rm -f $(M2_REGISTRY_NAME) >/dev/null 2>&1 || true
	@rm -f $(STACK_M2_ENV)
	@echo '==> Clean. Next bring-up is a COLD build: run "make stack-m2-bootstrap", then "make stack-up".'

# Run the Playwright e2e suite (tests/e2e) against the RUNNING local stack's TLS
# front door. Preconditions: `make stack-up` + `make stack-seed` (stack-seed's
# SEED_REGISTRATION_SKIP keeps the pending/banned personas gated even under
# SEED_COMPLETE_REGISTRATION=1, so a Studio-seeded stack still satisfies specs
# 17/28/29). The toolchain is CHECKED, not auto-installed: every e2e target runs
# tests/e2e/check-toolchain.sh (see E2E_READY above playwright-deps), which
# names what is missing and stops, and `make playwright-deps` stays an explicit
# once-per-box step. SNAP_REPORT_DIR (optional, tests/e2e-
# relative, inherited from the environment) redirects the junit/json/summary
# artifacts; the hugmesh reporter's summary.json there is the durable result.
#
# E2E_ARGS — EXTRA ARGV HANDED STRAIGHT TO `playwright test`. Until 2026-08-26 this
# target was the only way to drive the suite against the compose stack and it took
# NO arguments at all, so there was no way to run one spec, one --grep or one
# --repeat-each: every iteration on a single failing spec paid for all 33 files /
# 221 tests. kind-e2e and kind-e2e-mfa had always named their single spec inline
# (specs/27-…, specs/29-…), so the capability existed everywhere except the lane
# people actually use.
#
# It is deliberately a VARIABLE, not a `%`-target or an argv trick, because make
# imports the environment as make variables: `E2E_ARGS='specs/01-frontpage.spec.ts'
# make stack-e2e` and `make stack-e2e E2E_ARGS=...` are then the same thing. That
# matters for the Studio, whose LocalStackNode._make(extra_env=...) can add an env
# var but cannot change the argv it builds.
#
# UNQUOTED on purpose — the shell word-splits it, so `E2E_ARGS='--grep @smoke -x'`
# passes two arguments. The cost is that a spec path with a space in it needs the
# caller's own quoting; no spec in tests/e2e/specs has one, and the alternative
# (quoting here) would break multi-argument use, which is the common case.
# Unset it expands to nothing and the recipe is byte-identical to the old one, so
# the DEFAULT is still the full suite. tests/scripts/test-stack-e2e-argv.sh asserts
# exactly that in both directions, by rendering and by running.
#
# WHY THIS DOES NOT DELEGATE TO tests/e2e/run.sh, which already forwards "$@".
# Because they are not the same invocation and never were:
#   * run.sh hardcodes `--reporter=list`, and a CLI --reporter REPLACES the config's
#     reporter array. Delegating would silently drop junit.xml, report.json and the
#     hugmesh reporter's summary.json — the artifacts the paragraph above calls the
#     durable result, and the ones the admin-bff TestReportsController serves.
#   * run.sh picks its ENGINE from whether the image named by PW_IMAGE
#     (default hugmeshgames-e2e:latest) happens to exist on the box, falling back to
#     host npx. Whether `make stack-e2e` runs in a container would then depend on an
#     unrelated `docker image ls`, and the container path passes neither
#     SNAP_REPORT_DIR nor SNAP_HOST_RESOLVER through.
#   * run.sh's job is "run these specs from a machine that may not have browsers" —
#     its callers are run-all.sh (mock stack) and tests/qemu/run-qemu-e2e.sh (a VM's
#     front door). This target's job is "run them against THIS repo's compose stack
#     with the durable reporters on."
# Collapsing the two is a real cleanup, but it means changing run.sh's reporter
# handling, which the QEMU lane depends on and which cannot be verified from here.
# So: two callers, one documented reason, and the divergence is now written down
# instead of merely existing.
# E2E_SPECS (optional) narrows the run to named spec FILES, as Playwright positional
# filters relative to tests/e2e — e.g.
#     make stack-e2e E2E_SPECS='specs/01-frontpage.spec.ts specs/04-five-users.spec.ts'
# This is what the Studio's e2e feature tree passes for a checked selection. UNSET
# runs the WHOLE suite, which is the historical behaviour and stays the default: an
# empty value must never be able to mean "run nothing" silently, and here it cannot,
# because an empty variable expands to no arguments at all.
#
# TWO VARIABLES, ONE RECIPE, AND THEY ARE NOT REDUNDANT. E2E_ARGS is FREE ARGV
# (flags: --grep, --repeat-each, -x) and is word-split by the shell; E2E_SPECS is
# the STUDIO's channel and carries spec PATHS ONLY, every one of which
# core.e2e_catalogue.safe_spec_args has matched against SPEC_ARG_RE before it is
# allowed near this unquoted expansion. Collapsing the two would either give the
# Studio's checkbox tree a door to arbitrary flags, or take --grep away from the
# command line. They are expanded in this order because Playwright reads flags
# first and positional filters last, and BOTH default to empty, so an unset pair
# renders the historical full-suite command byte for byte.
E2E_SPECS ?=
stack-e2e: ## run the Playwright e2e suite against the RUNNING local stack (E2E_ARGS='--grep …' / E2E_SPECS='specs/NN-….spec.ts' narrow it; needs stack-up + stack-seed)
	@$(E2E_READY) || exit 2
	cd tests/e2e && SNAP_BASE_URL='https://localhost:$(PUBLIC_HTTPS_PORT)' \
	  npx playwright test -c playwright.config.ts $(E2E_ARGS) $(E2E_SPECS)

# Enumerate the suite WITHOUT running it: `playwright test --list` resolves and
# loads every spec file and prints the test tree, then exits. Nothing is launched —
# no browser, no request — so this is the one e2e target that needs neither
# `stack-up` nor a network. MEASURED, not assumed, on 2026-08-26: run under
# `unshare -rn` (no network interfaces at all) with the stack down it exits 0 in
# ~1.1s and enumerates 33 spec files / 221 tests.
#
# --reporter=json is FORCED rather than left to the caller, and that is not cosmetic.
# MEASURED on 2026-08-26: a bare `--list` under the config's own reporter array
# still fires every FILE writer — SNAP_REPORT_DIR/ came out holding junit.xml,
# report.json AND the hugmesh reporter's summary.json, all describing zero tests. A
# mere enumeration would therefore CLOBBER the durable artifacts of the last real
# run. With `--reporter=json` the same directory stays empty (also measured). A CLI
# --reporter replaces the whole array, so one flag both makes the output
# machine-readable for a feature tree and disarms the writers.
#
# E2E_ARGS narrows the listing the same way it narrows a run, so
# `make stack-e2e-list E2E_ARGS=--grep=@smoke` answers "what WOULD that run?"
# without running it.
stack-e2e-list: ## enumerate the e2e specs as JSON without running them (no stack, no network; E2E_ARGS narrows)
	@$(E2E_READY) || exit 2
	@cd tests/e2e && npx playwright test -c playwright.config.ts --list --reporter=json $(E2E_ARGS) $(E2E_SPECS)

stack-logs: ## tail logs from the running local stack
	$(STACK_ENV) $(COMPOSE_CMD) -f $(STACK_COMPOSE) $(STACK_PROFILE) $(STACK_ALT_PROFILE) $(STACK_TOR_PROFILE) $(STACK_GAMES_PROFILE) $(STACK_BRAND_B_PROFILE) $(STACK_OWN_CASDOOR_FLAGS) $(STACK_LIMITS_FLAGS) $(STACK_EGRESS_FLAGS) logs -f --tail=100

stack-ps: ## list the local stack's containers + status
	$(STACK_ENV) $(COMPOSE_CMD) -f $(STACK_COMPOSE) $(STACK_PROFILE) $(STACK_ALT_PROFILE) $(STACK_TOR_PROFILE) $(STACK_GAMES_PROFILE) $(STACK_BRAND_B_PROFILE) $(STACK_OWN_CASDOOR_FLAGS) $(STACK_LIMITS_FLAGS) $(STACK_EGRESS_FLAGS) ps

# ── The Gherkin (BDD) e2e lane ───────────────────────────────────────────────
# SEPARATE targets on purpose: the `stack-e2e` recipe above is edited by other
# work in flight, so the BDD lane adds its own targets rather than growing that
# recipe. Its own .PHONY line, for the same reason.
#
# tests/e2e/features/**/*.feature is compiled by `npx bddgen` into the GITIGNORED
# tests/e2e/.features-gen/, which playwright.config.ts's `bdd` project runs.
# Conventions every feature author follows: tests/e2e/features/README.md.
#
# EVERY TARGET BELOW DELEGATES TO tests/e2e/run.sh. That script is the single
# CLI entry point for this suite; when these recipes spelled the invocation
# themselves there were two divergent ways to run one lane, and they drifted.
# Anything you can do here you can do by hand with the same flags, which is the
# point -- `make stack-e2e-bdd BDD_ENV=qemu` is exactly
# `bash tests/e2e/run.sh --bdd --env qemu`.
#
# KNOBS (all optional):
#   BDD_ENV=docker|kind|qemu  which mesh (default docker; NOTHING is started)
#   BDD_TAGS='@interface:cli' Gherkin tag expression, forwarded to bddgen
#   BDD_FEATURES='cli/'       feature path(s), forwarded to playwright
#   BDD_ARGS='--reporter=line' extra playwright arguments, verbatim
#   SNAP_PLATFORM=rpi5|x86    narrows the PLATFORM axis to the image running
#   SNAP_REPORT_DIR / SNAP_RUN_ID   where junit/json/summary + bdd-steps/ land
.PHONY: stack-e2e-bdd stack-e2e-bdd-gen stack-e2e-bdd-check stack-e2e-bdd-evidence \
        stack-e2e-bdd-env stack-e2e-bdd-guards

BDD_ENV ?= docker
BDD_RUN  = bash tests/e2e/run.sh --bdd --env $(BDD_ENV) \
             $(if $(strip $(BDD_TAGS)),--tags '$(BDD_TAGS)',) \
             $(if $(strip $(BDD_FEATURES)),--features '$(BDD_FEATURES)',)

stack-e2e-bdd-gen: ## compile tests/e2e/features/*.feature into runnable Playwright specs (bddgen)
	@$(E2E_READY) || exit 2
	$(BDD_RUN) --gen

# OFFLINE gate. No stack, no network. Proves every .feature compiles, every step
# is bound (bddgen is missingSteps:fail-on-gen, so an undefined step FAILS here),
# Playwright collects the generated tests, and no generated artefact is tracked.
# This is the one to run before committing a feature.
# The three AXIS guards belong here and NOT in .github/workflows/shell-suites.yml:
# both need tests/e2e/node_modules (playwright + a chromium), which the shell-suite
# runner image does not carry, so a CI listing would turn their honest
# "SKIPPED-LOUDLY ... checked NOTHING" exit 2 into a red pipeline. Wired at the
# Makefile gate instead, exactly as the anti-decoration guard above is.
#   env x interface — was UNWIRED on arrival (tests/scripts/test-guard-integrity.sh
#   check 3 listed it as "suite(s) nothing runs" on this very tree); wired here.
stack-e2e-bdd-check: ## OFFLINE: verify every .feature generates, binds and is collected (+ the anti-decoration guards)
	@$(E2E_READY) || exit 2
	$(BDD_RUN) --list --reporter=line
	bash tests/scripts/test-e2e-gherkin-harness.sh
	bash tests/scripts/test-e2e-env-interface-dimensions.sh
	bash tests/scripts/test-e2e-social-function-matrix.sh
	bash tests/scripts/test-e2e-cli-lane.sh
#   The media/games and governance FUNCTION guards arrived UNWIRED: their author
#   branches added the scripts and never called them from anywhere, which
#   tests/scripts/test-guard-integrity.sh check 2 reports as "suite(s) nothing
#   runs" on the merged tree. A drift guard nothing executes is the decorative
#   artefact this repo keeps re-learning about, so they are wired here.
	bash tests/scripts/test-e2e-func-media-games.sh
	bash tests/scripts/test-e2e-governance-function-matrix.sh

# The Gherkin lane's TWO deeper guards, each with its own mutation battery. Split
# out of stack-e2e-bdd-check because they are minutes rather than seconds: each
# breaks production several ways on purpose, re-runs the lane against every
# mutant, and restores the tree.
#
# THEY ARE A MAKE TARGET AND NOT A CI JOB, deliberately, and the reason is
# written here so nobody "fixes" it by gating them: both need `npx playwright`
# AND a Qt6 binding (they build the REAL PyQt wizard offscreen), and no image the
# shell-suites workflow runs carries either. On such a host both exit 2 with a
# SKIPPED-LOUDLY line naming the missing prerequisite — never 0, so they can
# never be mistaken for a pass. Gating a suite that can only skip would train
# everyone to ignore the job.
#
# NOTHING IS STARTED. Both are designed to be green with the compose stack, the
# kind cluster and every emulator DOWN: they test the vocabulary, the chooser and
# the evidence, not the meshes.
stack-e2e-bdd-guards: ## OFFLINE: the Gherkin lane's axis + Studio-GUI guards (mutation batteries; minutes)
	bash tests/scripts/test-e2e-env-interface-dimensions.sh
	bash tests/scripts/test-e2e-studio-gui-lane.sh

# ── The e2e REPORT's shape ───────────────────────────────────────────────────
# Its own target and its own .PHONY line, for the same reason the BDD lane has
# them: the stack-e2e recipe above is edited by other work in flight.
#
# What it gates: reporters/hugmesh-reporter.ts must keep emitting a report a
# feature tree can render - pivoted BY SPEC FILE, one record per test, with
# attachment paths and a skip REASON on every skipped test - while still writing
# the legacy role/layer pivot the admin-ui console and hugmesh_studio's
# parse_summary() read. The shape is pinned in tests/e2e/reporters/summary.schema.json,
# checked against a REPLAY of a recorded run (no suite, no stack, no browser, no
# node_modules: bare node + python3, ~4s).
.PHONY: e2e-reporter-check

e2e-reporter-check: ## OFFLINE: verify the e2e reporter emits a per-spec/per-test/attachment/skip-reason summary.json
	bash tests/scripts/test-e2e-reporter-shape.sh

# LIVE lane. Same preconditions as stack-e2e (stack-up + stack-seed; once:
# make playwright-deps) when BDD_ENV=docker. SNAP_PLATFORM=rpi5|x86 narrows the
# PLATFORM axis to the image target actually running; unset runs every platform
# row. SNAP_REPORT_DIR redirects junit/json/summary AND the per-step evidence
# under bdd-steps/, which `make stack-e2e-bdd-evidence` then summarises.
#
# SNAP_BASE_URL is passed for BDD_ENV=docker only: run.sh reads it as the docker
# mesh's address (PUBLIC_HTTPS_PORT is this repo's front door, not 8443), and
# for kind/qemu run.sh resolves the address itself.
stack-e2e-bdd: ## run the GHERKIN e2e lane (BDD_ENV=docker|kind|qemu; docker needs stack-up + stack-seed)
	@$(E2E_READY) || exit 2
	$(if $(filter docker,$(BDD_ENV)),SNAP_BASE_URL='https://localhost:$(PUBLIC_HTTPS_PORT)' ,)$(BDD_RUN) $(BDD_ARGS)

# Where did this run's screenshots / transcripts / widget grabs go, and what is
# in them? Reads the manifest the lane wrote and breaks it down per environment
# and per interface. Exits non-zero when there is nothing there -- an empty
# summary reported as success is how a lane that ran NOTHING passes for one that
# ran everything.
stack-e2e-bdd-evidence: ## summarise the Gherkin lane's evidence manifest (per env / per interface)
	bash tests/e2e/run.sh --evidence

# ── SNAP_ENV alias: the STUDIO's entry point ─────────────────────────────────
# studio/hugmesh_studio/core/e2e_environments.py pins RUN_TARGET = this name and
# studio/tests/test_e2e_environments.py asserts the target exists in this file,
# so the name is load-bearing. It is deliberately a THIN ALIAS and not a second
# implementation: the GUI lane and the CLI lane arrived independently, each with
# its own way to select an environment (SNAP_ENV inline here / BDD_ENV through
# run.sh), which is precisely the two-divergent-invocations drift the comment at
# the top of this block warns about. One implementation, two spellings of the
# knob. Nothing is started; a scenario whose mesh is down SKIPS with a reason.
#
#   make stack-e2e-bdd-env                       # docker (default)
#   SNAP_ENV=kind make stack-e2e-bdd-env         # the kind cluster
#   SNAP_ENV=qemu make stack-e2e-bdd-env         # a device somebody already booted
stack-e2e-bdd-env: ## run the GHERKIN lane against the mesh SNAP_ENV names (docker|kind|qemu; nothing is started)
	@$(MAKE) --no-print-directory stack-e2e-bdd \
	  BDD_ENV='$(or $(SNAP_ENV),docker)' BDD_ARGS='$(BDD_ARGS) $(E2E_ARGS)'

# ── THE GENERATIVE COVERAGE MATRIX ───────────────────────────────────────────
# tests/e2e/features/coverage/ is EMITTED, not hand-written: every seeded
# persona x every catalogued function x every service, with the expected
# admitted/refused outcome computed from the COMMITTED gateway route-access seed.
# Adding a persona to tests/e2e-extra-personas.sh, a service to
# tests/e2e/steps/dimensions.ts SERVICES, or a function to
# tests/e2e/steps/coverage-catalogue.ts FUNCTIONS expands the matrix
# automatically — and the drift guard goes RED until it is re-emitted.
.PHONY: stack-e2e-coverage-gen stack-e2e-coverage-check

stack-e2e-coverage-gen: ## re-emit tests/e2e/features/coverage/ from the persona/service/function catalogues
	@$(E2E_READY) || exit 2
	bash tests/e2e/gen-coverage-matrix.sh

# OFFLINE gate. Starts nothing. Re-emits into a scratch dir and DIFFS against the
# committed tree, derives the expected persona/service/function/pair sets from the
# catalogues and compares them with what `playwright test --list` actually
# generates, runs the whole coverage lane, then breaks production six ways and
# requires every break to turn it red.
#
# RUNTIME, MEASURED 2026-08-27 (warm node_modules, chromium in ~/.cache):
# 8m33s end-to-end = 24s harness + 5s checks 1-3 + 4m22s the full 2105-test
# lane + ~3m40s the six-mutation battery (a FAILING 124-cell lane costs ~88s —
# the failure path is ~6x the pass path). A browser store that cannot launch is
# refused in ~1s (exit 2, SKIPPED-LOUDLY) instead of the ~29 minutes of
# per-cell launch failures it used to burn before the timeout killed it.
# COVERAGE_MATRIX_FULL=0 runs a representative subset instead while iterating.
# The harness runs FIRST: it is the guard's own kill/refusal battery (stub
# playwright, ~25s) and it also gates every PR from shell-suites.yml's node job.
stack-e2e-coverage-check: stack-e2e-bdd-gen ## OFFLINE: the coverage matrix is complete, pinned and drift-guarded (measured ~9 min)
	bash tests/scripts/test-e2e-coverage-matrix-harness.sh
	bash tests/scripts/test-e2e-coverage-matrix.sh

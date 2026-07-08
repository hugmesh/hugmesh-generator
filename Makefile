# Snapdragon-Systems image build / flash / emulate / test orchestrator.
#
# Front door over the build scripts and tooling. Every target just invokes the
# underlying script with the right flags, so the flags remain the engine and
# `make` is the friendly interface.
#
#   build-rpi5-stage4.sh      aarch64 (RPi5) cross-build  -> .img + .fs.tar.xz
#   build-x86-host-stage4.sh  amd64 multi-role build      -> .img + live ISO + .fs.tar.xz
#   build-frite-stage4.sh     aarch64 (Amlogic) light desktop -> live/installer ISO
#   build-jetson-stage4.sh    aarch64 (Tegra234 Orin) edge-AI node -> .img (EXPERIMENTAL)
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
# SKIP_X86/SKIP_KEYS drop work). They default EMPTY so a plain build keeps the
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
X86_OMNIBUS ?=
X86_ALL     ?=
X86_ROLES   ?=
SKIP_X86    ?=
SKIP_KEYS   ?=
# NOTE: this is `:=` and expands here, BEFORE the FRITE_*/JETSON_* `?=` defaults
# below — so a value reaches build-all-roles.sh only when the caller sets it
# (CLI/env); an empty assignment is fine (the script's own `${VAR:-default}`
# fallbacks catch empty exactly like unset).
ROLESET_ENVVARS := FRITE='$(FRITE)' FRITE_ONLY='$(FRITE_ONLY)' \
                   FRITE_BOARD='$(FRITE_BOARD)' FRITE_FLAVOR='$(FRITE_FLAVOR)' \
                   FRITE_DESKTOP='$(FRITE_DESKTOP)' \
                   JETSON='$(JETSON)' JETSON_ONLY='$(JETSON_ONLY)' JETSON_ROLES='$(JETSON_ROLES)' \
                   JETSON_BOARD='$(JETSON_BOARD)' JETSON_KERNEL_FLAVOR='$(JETSON_KERNEL_FLAVOR)' \
                   X86_OMNIBUS='$(X86_OMNIBUS)' X86_ALL='$(X86_ALL)' X86_ROLES='$(X86_ROLES)' \
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
IMAGE    ?= snapdragon-builder
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

# Native build commands (run as-is inside the container or on local Gentoo).
# BRAND_ENV prefixes the brand's own-mesh env (HEADSCALE_URL); BRAND_FLAGS adds
# --config brands/<BRAND>.conf (+ --cluster-domain DOMAIN). build-all-roles.sh
# passes BRAND_FLAGS through to BOTH builders via its "$@" passthrough.
RPI := $(BRAND_ENV) $(SUDO) ./build-rpi5-stage4.sh -w $(WORK_DIR) -j $(JOBS) $(IMG_FLAGS) $(ENV_FLAGS) $(BRAND_FLAGS)
X86 := $(BRAND_ENV) $(SUDO) ./build-x86-host-stage4.sh -w $(WORK_DIR) -j $(JOBS) $(IMG_FLAGS) $(ENV_FLAGS) $(BRAND_FLAGS)
FRITE_BUILD := $(BRAND_ENV) $(SUDO) ./build-frite-stage4.sh -w $(WORK_DIR) -j $(JOBS) $(IMG_FLAGS) $(ENV_FLAGS) $(BRAND_FLAGS)
JETSON_BUILD := $(BRAND_ENV) $(SUDO) ./build-jetson-stage4.sh -w $(WORK_DIR) -j $(JOBS) $(IMG_FLAGS) $(ENV_FLAGS) $(BRAND_FLAGS)
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

.DEFAULT_GOAL := help
.PHONY: help menu clean build-all build-everything matrix-check pentest pentest-seed rebuild \
        rpi x86 omnibus frite frite-live frite-installer jetson \
        flash qemu qemu-rpi qemu-x86 \
        playwright-deps e2e ci ci-quick docker-image ensure-image image-gen-docker-image \
        docker docker-build local prod \
        stack-clone stack-mastodon-env stack-build stack-up stack-down stack-logs stack-ps

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
	@echo "              Shortcuts:  make local   (ENV=test BRAND=local -> snapdragon.test)"
	@echo "                          make prod    (ENV=prod, real domain — creds from keys USB)"
	@echo "  Output:     products land in ./out (WORK_DIR=$(CURDIR)/out; local + gitignored)."
	@echo "              Per-arch build trees: ./out/snap-build-pi5 + ./out/snap-build-x86"
	@echo "              + ./out/snap-build-frite + ./out/snap-build-jetson (never share a sysroot)."
	@echo "  Platforms:  rpi (3 roles) | x86 (nodes+omnibus+edge_ai+clients+standalone) |"
	@echo "              frite (arm64 light desktop) | jetson (arm64 Tegra edge-AI — EXPERIMENTAL,"
	@echo "              JETSON_ROLE=edge_ai|gpu-host|full|desktop, hardware validation pending)."
	@echo "  Matrix:     make build-everything = the FULL documented matrix (honors ENV);"
	@echo "              make matrix-check = dry-run validate every role/flag combo via the"
	@echo "              builders' --print-plan (no root, no writes; tests/build-matrix/check.sh)."

menu: ## interactive console menu to build images (progress + quit-without-stopping)
	@bash scripts/build-menu.sh

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

local: ## build the LAN .test fleet (ENV=test, BRAND=local -> snapdragon.test; no internet)
	@echo "==> LOCAL build: ENV=test, brand=local (snapdragon.test). LAN-only — no public"
	@echo "    internet, no Cloudflare, no OAuth/SMTP. Cluster wildcard DNS serves *.snapdragon.test."
	@echo "    After boot, point your router/clients DNS at the backend node:53 (see docs/LOCAL-TESTING.md)."
	$(MAKE) build-all ENV=test BRAND=local

prod: ## build the PROD fleet (ENV=prod, REAL domain) — announced; creds from the keys USB
	@echo -e "\033[1;31m==> PROD build: ENV=prod. This bakes the REAL public domain and expects"
	@echo -e "    Cloudflare/OAuth/SMTP creds from the keys USB. For a LAN test use 'make local'.\033[0m"
	$(MAKE) build-all ENV=prod

rebuild: ## from-scratch: wipe the work dir, then build the whole default fleet
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make rebuild NATIVE=1 WORK_DIR=/out IMG_FLAGS='$(IMG_FLAGS)' JOBS=$(JOBS) $(BRAND_PASS) $(PENTEST_ENVVARS) $(ROLESET_ENVVARS)
else
	$(MAKE) clean NATIVE=1
	$(ALL)
	$(chown-artifacts)
endif

rpi: ## build all 3 Pi roles (.img + .fs.tar.xz each)
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make rpi NATIVE=1 WORK_DIR=/out IMG_FLAGS='$(IMG_FLAGS)' JOBS=$(JOBS) $(BRAND_PASS)
else
	@for r in $(RPI_ROLES); do echo "==> Pi $$r"; $(RPI) --role $$r || exit 1; done
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

# Extra builder flags threaded to the standalone-desktop targets (the menu / CLI
# passes e.g. STANDALONE_FLAGS='--local-user alice --local-pass s3cret --nvidia-driver proprietary').
STANDALONE_FLAGS ?=

x86-standalone: ## build BOTH hardened standalone NVIDIA desktops (thin+thick; LUKS FDE installer + all 4 artifacts)
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make x86-standalone NATIVE=1 WORK_DIR=/out IMG_FLAGS='$(IMG_FLAGS)' JOBS=$(JOBS) STANDALONE_FLAGS='$(STANDALONE_FLAGS)' $(BRAND_PASS)
else
	@for r in standalone-thin standalone-thick; do echo "==> x86 $$r"; $(X86) --role $$r $(STANDALONE_FLAGS) || exit 1; done
	$(chown-artifacts)
endif

rpi-%: ## build ONE Pi role: make rpi-frontend  (add IMG_FLAGS='--no-iso' etc.)
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make rpi-$* NATIVE=1 WORK_DIR=/out IMG_FLAGS='$(IMG_FLAGS)' JOBS=$(JOBS) $(BRAND_PASS)
else
	$(RPI) --role $*
	$(chown-artifacts)
endif

x86-%: ## build ONE x86 role: make x86-be+gpu | x86-pki | x86-standalone-thin (STANDALONE_FLAGS='--local-user … --nvidia')
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make x86-$* NATIVE=1 WORK_DIR=/out IMG_FLAGS='$(IMG_FLAGS)' JOBS=$(JOBS) STANDALONE_FLAGS='$(STANDALONE_FLAGS)' $(BRAND_PASS)
else
	$(X86) --role $* $(STANDALONE_FLAGS)
	$(chown-artifacts)
endif

frite: ## build the Frite light desktop (FRITE_BOARD=la-frite|le-potato, FRITE_FLAVOR=both|live|installer, FRITE_DESKTOP=light|none; STANDALONE_FLAGS='--enable-wifi …' appended verbatim)
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make frite NATIVE=1 WORK_DIR=/out JOBS=$(JOBS) IMG_FLAGS='$(IMG_FLAGS)' STANDALONE_FLAGS='$(STANDALONE_FLAGS)' $(BRAND_PASS) $(FRITE_PASS)
else
	$(FRITE_BUILD) --board $(FRITE_BOARD) --flavor $(FRITE_FLAVOR) --desktop $(FRITE_DESKTOP) $(STANDALONE_FLAGS)
	$(chown-artifacts)
endif

frite-live: ## build the Frite light desktop LIVE image only (boots ephemerally off USB/SD)
	$(MAKE) frite FRITE_FLAVOR=live

frite-installer: ## build the Frite light desktop INSTALLER image only (writes to eMMC/SD)
	$(MAKE) frite FRITE_FLAVOR=installer

jetson: ## build the Jetson Orin edge-AI image (JETSON_ROLE=edge_ai|gpu-host|full|desktop; EXPERIMENTAL; STANDALONE_FLAGS='--enable-wifi …')
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make jetson NATIVE=1 WORK_DIR=/out JOBS=$(JOBS) IMG_FLAGS='$(IMG_FLAGS)' STANDALONE_FLAGS='$(STANDALONE_FLAGS)' $(BRAND_PASS) $(JETSON_PASS)
else
	$(JETSON_BUILD) --role $(JETSON_ROLE) --board $(JETSON_BOARD) --kernel-flavor $(JETSON_KERNEL_FLAVOR) $(STANDALONE_FLAGS)
	$(chown-artifacts)
endif

jetson-%: ## build ONE Jetson role: make jetson-edge_ai | jetson-gpu-host | jetson-full | jetson-desktop (STANDALONE_FLAGS appended verbatim)
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make jetson-$* NATIVE=1 WORK_DIR=/out JOBS=$(JOBS) IMG_FLAGS='$(IMG_FLAGS)' STANDALONE_FLAGS='$(STANDALONE_FLAGS)' $(BRAND_PASS) $(JETSON_PASS)
else
	$(JETSON_BUILD) --role $* --board $(JETSON_BOARD) --kernel-flavor $(JETSON_KERNEL_FLAVOR) $(STANDALONE_FLAGS)
	$(chown-artifacts)
endif

# build-everything delegates to build-all with the ROLE-SELECTOR knobs set on the
# sub-make COMMAND LINE (not as env prefixes: $(ALL)'s own ROLESET_ENVVARS would
# re-assign the empty defaults AFTER an env prefix and clobber it). Command-line
# make vars override the `?=` defaults inside the sub-make, so ROLESET_ENVVARS is
# rebuilt there with the full-matrix values; ENV/BRAND/IMG_FLAGS pass through.
build-everything: ## build the FULL documented matrix: 3 Pi + all 12 x86 (nodes+omnibus+edge_ai+clients+standalone incl. unaffiliated) + Frite + Jetson (honors ENV=test|prod)
	$(MAKE) build-all \
	  X86_ROLES='$(X86_EVERY_ROLE)' \
	  FRITE=1 FRITE_BOARD='$(FRITE_BOARD)' FRITE_FLAVOR='$(FRITE_FLAVOR)' \
	  FRITE_DESKTOP='$(FRITE_DESKTOP)' \
	  JETSON=1 JETSON_ROLES='edge_ai gpu-host full desktop' \
	  JETSON_BOARD='$(JETSON_BOARD)' JETSON_KERNEL_FLAVOR='$(JETSON_KERNEL_FLAVOR)'

matrix-check: ## dry-run validate the whole build matrix via --print-plan (tests/build-matrix/check.sh)
	@test -f tests/build-matrix/check.sh \
	  || { echo "tests/build-matrix/check.sh not found — the build-matrix harness is not in this checkout yet."; exit 1; }
	bash tests/build-matrix/check.sh

## ── docker (cross-platform builder; Phase 5) ──────────────────────────
docker-image: ## build the self-contained Gentoo builder image (LONG first time: cross-toolchain)
	docker build -f Dockerfile.build -t $(IMAGE) .

# admin-bff-api's image-gen k8s Job worker (docker/Dockerfile.image-gen +
# docker/build-image.sh). Layers on top of $(IMAGE) (run `make docker-image`
# first) since the Job has no bind-mount of this repo — the checkout has to be
# baked in. IMAGE_GEN_TAG defaults to the registry ref the Job manifest
# expects; an operator still has to `docker push` it and flip
# admin-bff-api's imagegen.launch.enabled for any of this to go live.
IMAGE_GEN_TAG ?= registry.snapdragon.systems/snapdragon/image-gen:latest
image-gen-docker-image: ## build the admin-bff-api image-gen Job worker (needs $(IMAGE) built first)
	docker build -f docker/Dockerfile.image-gen -t $(IMAGE_GEN_TAG) .

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
# Runs the ENTIRE Snapdragon platform on x86_64 via docker-compose, building every
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
GIT_BASE        ?= https://github.com/Snapdragon-Systems
GIT_REF         ?= main
SOCIAL          ?=
# ENV -> Casdoor issuer URI used by every service (overridable via CASDOOR_ISSUER).
ifeq ($(ENV),prod)
CASDOOR_ISSUER ?= https://id.$(if $(strip $(DOMAIN)),$(DOMAIN),snapdragon.systems)
else
CASDOOR_ISSUER ?= http://localhost:8000
endif
# Env exported into every compose invocation (build contexts + service env).
STACK_ENV := STACK_SRC='$(STACK_SRC)' CASDOOR_ISSUER_URI='$(CASDOOR_ISSUER)' \
             PUBLIC_HOST_PORT='$(PUBLIC_HOST_PORT)'
STACK_PROFILE := $(if $(strip $(SOCIAL)),--profile social,)
COMPOSE_CMD   ?= docker compose
# When SOCIAL=1, the included compose.real.yaml mastodon services need an
# env_file (tests/stack/.mastodon.env). Ensure it exists before any social
# compose call so the profile renders/runs (NOT needed for the core stack).
STACK_SOCIAL_DEP := $(if $(strip $(SOCIAL)),stack-mastodon-env,)

stack-clone: ## clone/update all snapdragon repos into ./.stack-src (idempotent)
	STACK_SRC='$(STACK_SRC)' GIT_BASE='$(GIT_BASE)' GIT_REF='$(GIT_REF)' \
	  bash scripts/clone-all-repos.sh

# Guarantee tests/stack/.mastodon.env exists with non-empty dev secrets (only the
# SOCIAL=1 path needs it). For a fully prepped social tier (Synapse config +
# Mastodon db:prepare) use tests/stack/up-real.sh instead — see docs/LOCAL-STACK.md.
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
# stack (docker logs snapdragon-local-mastodon-web-1 showed the exact
# HostAuthorization block on every /api/v1/**, /api/v2/**, /oauth/** call proxied
# through the be-gateway).
stack-mastodon-env:
	@if [ ! -f tests/stack/.mastodon.env ]; then \
	  echo "==> Generating dev tests/stack/.mastodon.env (SOCIAL tier)"; \
	  { echo "LOCAL_DOMAIN=localhost"; \
	    echo "SECRET_KEY_BASE=$$(openssl rand -hex 64)"; \
	    echo "OTP_SECRET=$$(openssl rand -hex 64)"; \
	    echo "DB_HOST=mastodon-db"; echo "DB_USER=mastodon"; echo "DB_NAME=mastodon"; echo "DB_PASS=mastodon"; \
	    echo "REDIS_HOST=mastodon-redis"; \
	    echo "ALTERNATE_DOMAINS=mastodon-web:3000"; \
	  } > tests/stack/.mastodon.env; \
	fi

stack-build: stack-clone $(STACK_SOCIAL_DEP) ## build every service from its cloned repo (no run)
	$(STACK_ENV) $(COMPOSE_CMD) -f $(STACK_COMPOSE) $(STACK_PROFILE) build

stack-up: stack-clone $(STACK_SOCIAL_DEP) ## clone -> build -> run the FULL stack (ENV=test|prod; SOCIAL=1 adds matrix/mastodon)
	@echo "==> Local stack: ENV=$(ENV), issuer=$(CASDOOR_ISSUER), host port=$(PUBLIC_HOST_PORT), social=$(if $(strip $(SOCIAL)),on,off)"
	$(STACK_ENV) $(COMPOSE_CMD) -f $(STACK_COMPOSE) $(STACK_PROFILE) build
	$(STACK_ENV) $(COMPOSE_CMD) -f $(STACK_COMPOSE) $(STACK_PROFILE) up -d
	@echo "==> Up. Front door: http://localhost:$(PUBLIC_HOST_PORT)  | Casdoor: http://localhost:8000"
	@echo "    Logs: make stack-logs   Down: make stack-down"

stack-seed: ## seed Casdoor identity (org+roles+app-user-bff+personas) for real SSO login; SOCIAL=1 also seeds Matrix/Mastodon
	@echo "==> Seeding the running stack (Casdoor$(if $(strip $(SOCIAL)), + social,) tier)"
	$(if $(strip $(SOCIAL)),,SEED_CASDOOR_ONLY=1 )bash tests/stack/seed-e2e.sh
	@echo "==> Seeded. Real SSO web login: open http://localhost:$(PUBLIC_HOST_PORT)/login and sign in with an e2e persona (e.g. e2e-admin / e2e-pass)."

stack-down: ## stop the local stack and drop its volumes
	$(STACK_ENV) $(COMPOSE_CMD) -f $(STACK_COMPOSE) --profile social down -v

stack-logs: ## tail logs from the running local stack
	$(STACK_ENV) $(COMPOSE_CMD) -f $(STACK_COMPOSE) $(STACK_PROFILE) logs -f --tail=100

stack-ps: ## list the local stack's containers + status
	$(STACK_ENV) $(COMPOSE_CMD) -f $(STACK_COMPOSE) $(STACK_PROFILE) ps

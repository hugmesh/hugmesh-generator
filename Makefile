# Snapdragon-Systems image build / flash / emulate / test orchestrator.
#
# Front door over the build scripts and tooling. Every target just invokes the
# underlying script with the right flags, so the flags remain the engine and
# `make` is the friendly interface.
#
#   build-rpi5-stage4.sh      aarch64 (RPi5) cross-build  -> .img + .fs.tar.xz
#   build-x86-host-stage4.sh  amd64 multi-role build      -> .img + live ISO + .fs.tar.xz
#   scripts/build-all-roles.sh   the default fleet (3 Pi + x86 pki/be/fe/be+gpu)
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

SHELL    := /bin/bash
WORK_DIR ?= $(CURDIR)/out
JOBS     ?= $(shell nproc)
ROLE     ?= be+gpu
ARCH     ?= x86
DEV      ?=
IMG_FLAGS ?=

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

# BRAND_ENV — leading VAR=val env assignments for things the builders read from
# the profile/env rather than a CLI flag (the brand's own mesh control server).
BRAND_ENV :=
ifneq ($(strip $(HEADSCALE_URL)),)
BRAND_ENV += HEADSCALE_URL=$(HEADSCALE_URL)
endif

# BRAND_PASS — brand make-vars forwarded into the in-container `make` re-invoke
# (the Docker dispatch path) so BRAND_FLAGS/BRAND_ENV are rebuilt identically
# inside the builder image. brands/ is mounted at /src/brands via -v $(CURDIR):/src.
BRAND_PASS := BRAND='$(BRAND)' DOMAIN='$(DOMAIN)' HEADSCALE_URL='$(HEADSCALE_URL)'

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

# Launch the builder image: privileged (build_img needs /dev/loop + mount),
# repo at /src, output at /out, and the invoking uid/gid forwarded so the
# in-container NATIVE build can chown artifacts back to the host user.
DOCKER_RUN := docker run --rm --privileged \
  -v $(CURDIR):/src -v $(WORK_DIR):/out -w /src \
  -e HOST_UID=$(HOST_UID) -e HOST_GID=$(HOST_GID) \
  -e CA_CERT -e CA_KEY -e CA_KEY_PASS $(IMAGE)

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
RPI := $(BRAND_ENV) $(SUDO) ./build-rpi5-stage4.sh -w $(WORK_DIR) -j $(JOBS) $(IMG_FLAGS) $(BRAND_FLAGS)
X86 := $(BRAND_ENV) $(SUDO) ./build-x86-host-stage4.sh -w $(WORK_DIR) -j $(JOBS) $(IMG_FLAGS) $(BRAND_FLAGS)
ALL := $(BRAND_ENV) $(SUDO) ./scripts/build-all-roles.sh -j $(JOBS) -w $(WORK_DIR) $(BRAND_FLAGS)

RPI_ROLES := pki backend frontend
X86_ROLES := pki be fe be+gpu

.DEFAULT_GOAL := help
.PHONY: help clean build-all rebuild rpi x86 omnibus flash qemu qemu-rpi qemu-x86 \
        playwright-deps e2e ci ci-quick docker-image ensure-image \
        docker docker-build

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
	@echo "  Output:     products land in ./out (WORK_DIR=$(CURDIR)/out; local + gitignored)."

## ── build ─────────────────────────────────────────────────────────────
# Every build target dispatches: NATIVE unset -> re-invoke inside the builder
# container (which sets NATIVE=1, WORK_DIR=/out); NATIVE set -> run the scripts
# directly (the container's root path, or an explicit local-Gentoo run).

clean: ## wipe the work dir (forces a from-scratch rebuild)
	$(SUDO) rm -rf "$(WORK_DIR)"

build-all: ## build the DEFAULT fleet: 3 Pi + x86 pki/be/fe/be+gpu (--resume reuses sysroots)
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make build-all NATIVE=1 WORK_DIR=/out RESUME='$(RESUME)' IMG_FLAGS='$(IMG_FLAGS)' JOBS=$(JOBS) $(BRAND_PASS)
else
	$(ALL) $(RESUME)
	$(chown-artifacts)
endif

rebuild: ## from-scratch: wipe the work dir, then build the whole default fleet
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make rebuild NATIVE=1 WORK_DIR=/out IMG_FLAGS='$(IMG_FLAGS)' JOBS=$(JOBS) $(BRAND_PASS)
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
	@for r in $(X86_ROLES); do echo "==> x86 $$r"; $(X86) --role $$r || exit 1; done
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

rpi-%: ## build ONE Pi role: make rpi-frontend  (add IMG_FLAGS='--no-iso' etc.)
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make rpi-$* NATIVE=1 WORK_DIR=/out IMG_FLAGS='$(IMG_FLAGS)' JOBS=$(JOBS) $(BRAND_PASS)
else
	$(RPI) --role $*
	$(chown-artifacts)
endif

x86-%: ## build ONE x86 role: make x86-be+gpu | x86-pki | x86-omnibus
ifndef NATIVE
	$(MAKE) ensure-image
	$(DOCKER_RUN) make x86-$* NATIVE=1 WORK_DIR=/out IMG_FLAGS='$(IMG_FLAGS)' JOBS=$(JOBS) $(BRAND_PASS)
else
	$(X86) --role $*
	$(chown-artifacts)
endif

## ── docker (cross-platform builder; Phase 5) ──────────────────────────
docker-image: ## build the self-contained Gentoo builder image (LONG first time: cross-toolchain)
	docker build -f Dockerfile.build -t $(IMAGE) .

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
	$(SUDO) tests/qemu/run-qemu-e2e.sh -w "$(WORK_DIR)" --arch $(ARCH) --role $(ROLE)

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

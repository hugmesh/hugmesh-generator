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
# Common overrides:  WORK_DIR=/var/tmp/snap-build  JOBS=$(nproc)  ROLE=be+gpu  ARCH=x86  DEV=/dev/sdX
# Image format:      pass IMG_FLAGS='--no-iso' (img only) or '--no-img' (iso only) etc.

SHELL    := /bin/bash
WORK_DIR ?= /var/tmp/snap-build
JOBS     ?= $(shell nproc)
ROLE     ?= be+gpu
ARCH     ?= x86
DEV      ?=
IMG_FLAGS ?=

RPI := sudo ./build-rpi5-stage4.sh -w $(WORK_DIR) -j $(JOBS) $(IMG_FLAGS)
X86 := sudo ./build-x86-host-stage4.sh -w $(WORK_DIR) -j $(JOBS) $(IMG_FLAGS)
ALL := sudo ./scripts/build-all-roles.sh -j $(JOBS) -w $(WORK_DIR)

RPI_ROLES := pki backend frontend
X86_ROLES := pki be fe be+gpu

.DEFAULT_GOAL := help
.PHONY: help clean build-all rebuild rpi x86 omnibus flash qemu qemu-rpi qemu-x86 \
        playwright-deps e2e ci ci-quick docker docker-build

help: ## list targets
	@grep -hE '^[a-zA-Z0-9_.+-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-20s\033[0m %s\n",$$1,$$2}'

## ── build ─────────────────────────────────────────────────────────────
clean: ## wipe the work dir (forces a from-scratch rebuild)
	sudo rm -rf "$(WORK_DIR)"

build-all: ## build the DEFAULT fleet: 3 Pi + x86 pki/be/fe/be+gpu (--resume reuses sysroots)
	$(ALL) $(RESUME)

rebuild: clean ## from-scratch: wipe the work dir, then build the whole default fleet
	$(ALL)

rpi: ## build all 3 Pi roles (.img + .fs.tar.xz each)
	@for r in $(RPI_ROLES); do echo "==> Pi $$r"; $(RPI) --role $$r || exit 1; done

x86: ## build the 4 default x86 roles (.img + live ISO + .fs.tar.xz each)
	@for r in $(X86_ROLES); do echo "==> x86 $$r"; $(X86) --role $$r || exit 1; done

omnibus: ## build the opt-in x86 omnibus (all namespaces on one node)
	$(X86) --role omnibus

rpi-%: ## build ONE Pi role: make rpi-frontend  (add IMG_FLAGS='--no-iso' etc.)
	$(RPI) --role $*

x86-%: ## build ONE x86 role: make x86-be+gpu | x86-pki | x86-omnibus
	$(X86) --role $*

## ── flash / emulate / test ────────────────────────────────────────────
flash: ## write a role image to a disk: make flash DEV=/dev/sdX ROLE=frontend ARCH=arm64
	@test -n "$(DEV)" || { echo "set DEV=/dev/sdX (the target disk)"; exit 1; }
	sudo scripts/flash-disk.sh --arch $(ARCH) --role $(ROLE) -w "$(WORK_DIR)" "$(DEV)"

qemu-rpi: ## boot a Pi role image in QEMU: make qemu-rpi ROLE=frontend
	sudo tests/qemu/launch-pi.sh -w "$(WORK_DIR)" -r $(ROLE) --foreground

qemu-x86: ## boot an x86 role image in QEMU: make qemu-x86 ROLE=be+gpu
	sudo tests/qemu/launch-x86.sh -w "$(WORK_DIR)" -r $(ROLE) --foreground

qemu: qemu-$(if $(filter arm64,$(ARCH)),rpi,x86) ## boot ROLE/ARCH in QEMU (ARCH=x86|arm64)

playwright-deps: ## install the Playwright deps + chromium (needed once for e2e)
	cd tests/e2e && { [ -d node_modules ] || npm ci || npm install; } \
	  && npx playwright install --with-deps chromium

e2e: playwright-deps ## boot ROLE/ARCH in QEMU and run the Playwright e2e (default: x86 be+gpu)
	sudo tests/qemu/run-qemu-e2e.sh -w "$(WORK_DIR)" --arch $(ARCH) --role $(ROLE)

ci: rebuild e2e ## FULL pipeline: wipe -> build the whole fleet -> QEMU-emulate + e2e (long; hours)

ci-quick: clean ## fast pipeline: build only x86 be+gpu (KVM) -> emulate + e2e
	$(X86) --role be+gpu
	$(MAKE) e2e ARCH=x86 ROLE=be+gpu

## ── docker (cross-platform builder; Phase 5) ──────────────────────────
docker: ## build the cross-platform builder image (Win/Mac/Linux)
	@test -f Dockerfile.build && docker build -f Dockerfile.build -t snapdragon-builder . \
	  || echo "Dockerfile.build not present yet (Phase 5)."

docker-build: ## run a build inside the privileged builder container (TARGET=rebuild|x86-be+gpu|...)
	@test -f Dockerfile.build && docker run --rm --privileged \
	  -v "$(CURDIR)":/src -v "$(WORK_DIR)":/out -w /src snapdragon-builder \
	  make $(or $(TARGET),build-all) WORK_DIR=/out \
	  || echo "Dockerfile.build not present yet (Phase 5)."

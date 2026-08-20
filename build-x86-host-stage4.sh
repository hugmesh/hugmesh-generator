#!/usr/bin/env bash
# build-x86-host-stage4.sh
# Build a hardened Gentoo amd64 stage4 + bootable ISO for the "hugmesh-host"
# node: a headless Kubernetes worker that joins the pki Pi control-plane and
# hosts ArgoCD + the hugmesh.games namespace + backend workloads, using a
# vendor-agnostic open GPU stack (Mesa/Vulkan) exposed to containers.
#
# NATIVE build — run on an amd64 Gentoo host (no crossdev). It chroots into the
# sysroot to emerge, so it needs root. Reuses the arch-agnostic specs/ (KEYS
# provisioning engine, OpenRC services, k8s config, GitOps payload) plus the
# amd64-specific specs-x86/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECS_DIR="${SCRIPT_DIR}/specs-x86"      # amd64-specific specs
SHARED_SPECS="${SCRIPT_DIR}/specs"       # arch-agnostic specs (etc/, cluster/)

# SUPPLY-CHAIN: every remote artifact (Gentoo stage3 seed, headscale, tailscale)
# is checksum/signature-verified through the SHARED, audited download-verification
# implementation instead of trusting a bare `curl`. See scripts/_download-lib.sh.
# (Same wiring as build-rpi5/frite/jetson-stage4.sh — the x86 builder was the last
# one still trusting unverified downloads; CRYPTO-AUDIT.md supply-chain section.)
# shellcheck source=scripts/_download-lib.sh
source "${SCRIPT_DIR}/scripts/_download-lib.sh"
# Shared /etc/shadow password-KDF helper (ph_crypt_hash): yescrypt ($y$) where
# the build host's libcrypt provably supports it, SHA-512 crypt ($6$) fallback.
# shellcheck source=scripts/_passhash-lib.sh
source "${SCRIPT_DIR}/scripts/_passhash-lib.sh"
# Host-safety guard. Unlike the ARM builders this script seeds NO host
# /etc/portage and runs no host emerge (its emerge/dracut calls are inside
# `chroot "${SYSROOT}"` heredocs, so they mutate the sysroot, not /). It is here
# ONLY for hostguard_require_host_tools: a native run must not warn-and-silently
# drop a requested artifact hours in. See scripts/_host-guard-lib.sh.
# shellcheck source=scripts/_host-guard-lib.sh
source "${SCRIPT_DIR}/scripts/_host-guard-lib.sh"
# Per-board binpkg-pool fingerprint guard (shared-binpkg track): the load-bearing
# SIGILL safety net over directory isolation — REFUSES --usepkg reuse of a pool
# whose (CHOST + exact CFLAGS/-mcpu + profile) fingerprint != this build's.
# shellcheck source=scripts/_binpkg-pool-lib.sh
source "${SCRIPT_DIR}/scripts/_binpkg-pool-lib.sh"
# Shared build-asset root (stage3 seed cache + fleet distfiles + per-BOARD binpkg
# pool) and its flock discipline — the ONE resolver every builder uses. See
# scripts/_shared-assets-lib.sh and docs/SHARED-BINPKG.md.
# shellcheck source=scripts/_shared-assets-lib.sh
source "${SCRIPT_DIR}/scripts/_shared-assets-lib.sh"
# Signed-kernel artifact cache (G4): a kernel+modules+initramfs+UKI set is reusable
# across images of the SAME board when board+kernel version+config digest+SIGNING KEY
# FINGERPRINT all match. The key fingerprint is in the cache key so a re-keyed fleet
# misses instead of silently reusing artifacts signed by a retired key.
# shellcheck source=scripts/_kernel-cache-lib.sh
source "${SCRIPT_DIR}/scripts/_kernel-cache-lib.sh"
# Seed-derived PYTHON_TARGETS/PYTHON_SINGLE_TARGET (pt_apply_seed_targets).
# A frozen python3_NN literal is a BUG — see docs/PYTHON-TARGETS-SEED-DRIFT.md.
# shellcheck source=scripts/_python-targets-lib.sh
source "${SCRIPT_DIR}/scripts/_python-targets-lib.sh"
# shellcheck source=scripts/_portage-config-lib.sh
source "${SCRIPT_DIR}/scripts/_portage-config-lib.sh"
# ── BEGIN shared block: SELinux node-policy lib ───────────────────────────────
# shellcheck source=scripts/_selinux-policy-lib.sh
source "${SCRIPT_DIR}/scripts/_selinux-policy-lib.sh"
# ── END shared block: SELinux node-policy lib ─────────────────────────────────

# NODE-STORAGE bake: bake_node_storage() — ONE definition of the four-file bake for
# every builder, so tests/node-storage/test-bake-coverage.sh can EXECUTE it against a
# sandbox sysroot instead of grepping this file for strings that a comment, a wrong
# destination or a dead branch all leave untouched.
# shellcheck source=scripts/_node-storage-bake-lib.sh
source "${SCRIPT_DIR}/scripts/_node-storage-bake-lib.sh"

# ── Defaults ───────────────────────────────────────────────────────
WORK_DIR=""
# Per-arch build subdirectory under WORK_DIR. The heavy, ARCH-SPECIFIC build
# tree (sysroot, ISO staging, distfiles, pkgdir, seed/binary downloads) lives
# under WORK_DIR/${BUILD_SUBDIR} so the amd64 (x86) and aarch64 (Pi) builds NEVER
# share a sysroot when they run against the same WORK_DIR (e.g. build-all-roles).
# Override with --build-subdir NAME or BUILD_SUBDIR=NAME in the env. The finished
# PRODUCTS (.img/.iso/.fs.tar.xz/stage4/keys-*) still land in WORK_DIR itself.
BUILD_SUBDIR="${BUILD_SUBDIR:-snap-build-x86}"
JOBS="$(nproc)"
REL_VERSION="2026.0"
HOSTNAME=""
HOSTNAME_SET=false      # true once -H/--hostname is given (role defaults defer to it)
ROLE="be+gpu"          # default role (= the legacy 'host'); 'host' is accepted as an alias
GPU=true               # derived from ROLE below; gates Mesa/Vulkan + DRM kernel + VIDEO_CARDS
# EARLY default (bug fix): the real value is derived from ROLE much further down
# (the "Validate role" section), but the opt-in guards for --with-tor /
# --with-character-studio / --with-edge-ai-tts run BEFORE that derivation and test
# ${ROLE_CLIENT} under `set -u` — leaving it undeclared here made any of those three
# flags hard-crash with "ROLE_CLIENT: unbound variable" on every role. The
# derivation below still runs and is still authoritative; this is just the bound
# default so the early guards can read it.
ROLE_CLIENT=false
# ── CLIENT (person-device) image config — see docs/CLIENT-IMAGES.md (FD-04..09) ──
# A client is a person's DESKTOP that joins the mesh + runs the platform UI, NOT a
# k8s node. The device-class role arms (laptop|chromebook|desktop) set ROLE_CLIENT.
PERSON_ROLE=""         # FD-08 identity role for client images: user|mod|admin|superadmin
DOMAINS=""             # FD-08 domain tie (comma/space separated; first = primary domain)
DESKTOP="thin"         # client desktop weight: thin (LXDE/openbox) | full (heavier DE)
DESKTOP_SET=false      # true once --desktop is given — role arms may default the weight
                       # ONLY when the operator said nothing (mirrors HOSTNAME_SET); an
                       # explicit flag is never silently overridden (it either wins, or
                       # a weight-pinning role name hard-errors on the contradiction)
CLUSTER_DOMAIN="hugmesh.net"
# Orchestration superdomain (WS-SUPER-B): the mesh control plane's MagicDNS suffix that
# every node joins. "" = builder default (legacy byte-identical: no marker, headscale keeps
# its checked-in headnet.internal base_domain). The Studio emits --superdomain <effective>
# only for MESH builds. PERMANENTLY INTERNAL — never the go-live public apex (that stays
# CLUSTER_DOMAIN); this flag is the authoritative on-image bake, the KEYS/provision channel
# handles the secret side.
SUPERDOMAIN=""
BRAND="hugmesh"
BRAND_TITLE="HugMesh Systems"
ORG="hugmesh"
# Games portal domain. DEFAULT serves games as a SUBDOMAIN of the primary domain
# (games.<CLUSTER_DOMAIN>) until the real .games TLD is obtained; flip to the TLD
# later with GAMES_DOMAIN=<brand>.games. The default literal "games.hugmesh.net"
# composes with rebrand_sysroot (its hugmesh.net->CLUSTER_DOMAIN rule turns
# it into games.<CLUSTER_DOMAIN>); a custom value is rebrand-neutral. Drives the
# games host + OIDC issuer/redirects via parameterize_games_domain(). See
# docs/OPTIONAL-SERVICES.md.
GAMES_DOMAIN="games.hugmesh.net"
# ── DEFAULT-INCLUSION POLICY (user 2026-06-17) — mirrors build-rpi5-stage4.sh ──
# USER_LEVEL_SERVICES is the SINGLE source-of-truth set of user-level OPTIONAL
# slugs (matches specs/cluster/optional-services.yaml; excludes the non-user-level
# infra slugs egress-vpn / tor / workloadConsole / anubis). It is what
# OPTIONAL_SERVICES=all / --all-services expands to.
USER_LEVEL_SERVICES="akkoma tuwunel phpbb games owncast tube character-studio character-forge"
# OPTIONAL services selected on this image (subset of USER_LEVEL_SERVICES).
#   DEFAULT-ON  (the built-in default when NO selection is given): akkoma tuwunel phpbb.
#   DEFAULT-OFF (must be specifically added): games owncast tube character-studio
#   character-forge.
# FULL-SET sentinel: OPTIONAL_SERVICES=all (or --all-services) expands to EVERY
# user-level slug (USER_LEVEL_SERVICES) just before EXCLUDE_SERVICES subtracts, so
# `all` + EXCLUDE_SERVICES="games" still drops games. GAMES IS OPT-IN / OFF BY
# DEFAULT — the games subdomain (games.<CLUSTER_DOMAIN>), casdoor-games and the
# games app-store are baked ONLY when games is explicitly selected (--enable-games
# / ENABLE_GAMES=true, by listing 'games' in --optional-services, or via 'all').
# brand.conf narrows; --optional-services overrides both (built-in < brand.conf <
# flag). Each unselected slug is pruned from the baked GitOps tree by
# gate_optional_services(). See specs/cluster/optional-services.yaml.
OPTIONAL_SERVICES="${OPTIONAL_SERVICES:-akkoma tuwunel phpbb}"
# EXCLUDE_SERVICES — the SUBTRACTIVE build-time exclusion knob (brand.conf /
# --exclude-services). Any user-level slug listed here is REMOVED from the final
# selection AFTER all positive sources (built-in default, brand.conf
# OPTIONAL_SERVICES, --optional-services, the games/edge-ai/tor/character-studio
# opt-ins) are resolved, so it is pruned from the baked tree by
# gate_optional_services no matter how it got selected. This is the one knob that
# can turn OFF an on-by-default service (akkoma/tuwunel/phpbb) without having to
# re-enumerate the whole positive list. Whitespace/comma separated.
# Example (brand.conf): EXCLUDE_SERVICES="phpbb tuwunel"  (forum-less + Matrix-less).
EXCLUDE_SERVICES="${EXCLUDE_SERVICES:-}"
# MANAGED_SERVICES — the MANAGED BACKING SERVICES selection (brand.conf / env), a
# WHITESPACE-separated list of `id=endpoint` tokens (commas are literal — a kafka
# endpoint is a comma-list of brokers) (e.g. "kafka=msk-broker:9098
# postgres-admin-bff=my.rds.amazonaws.com:5432"). Each id names a backing service
# (see specs/cluster/backing-services.yaml) whose in-mesh workload is pruned and
# whose consumer endpoint is repointed at <endpoint> by gate_backing_services().
# EMPTY (default) = SELF-HOSTED, byte-identical mainline (the #1 invariant). CLI
# --managed-service id=endpoint APPENDS to this. Tier-3 (docs-only) ids are
# fail-closed refused; creds are operator-supplied via gen-cluster-secrets, never
# argv/git. See docs/MANAGED-SERVICES.md.
MANAGED_SERVICES="${MANAGED_SERVICES:-}"
# Games opt-in toggle. --enable-games or ENABLE_GAMES=true folds 'games' into
# OPTIONAL_SERVICES (post-arg-parse, idempotent), baking the games subdomain.
ENABLE_GAMES="${ENABLE_GAMES:-false}"
# ── Build ENV selector (BAKED into the image) ──────────────────────
# test (DEFAULT, local-first/safe): LAN-only — cluster wildcard DNS ON, the
#   go-live cloudflared/external-dns/ACME app is PRUNED from the baked apps/,
#   OAuth/SMTP/Cloudflare optional/absent. Internal cluster-CA TLS only.
# prod: bakes the REAL public domain — public DNS / Cloudflare, ACME ALLOWED on
#   top of the internal CA, OAuth/SMTP/Cloudflare expected from the keys USB. The
#   build prints a LOUD announced banner because it bakes the real domain.
# The chosen ENV is written to /etc/hugmesh/env and gates which ArgoCD apps
# survive in the baked /var/lib/hugmesh/cluster/apps tree (gate_env_apps).
ENV="test"
# ── Release-state selector (BAKED into the image, gates gate_env_apps()/
# bake_host_firewall() ingress+firewall posture) ────────────────────
# internal (DEFAULT, safe): public ingress-nginx pruned, gateways forced to
#   the nginx-internal class, tier-ingress NetworkPolicy admits only
#   ingress-nginx-internal, host nftables firewall drops inbound 80/443 from
#   outside the tailnet unless /etc/hugmesh/go-live exists.
# public: the above restrictions are lifted (rebuild-time go-live).
RELEASE_STATE="internal"
# Pinned first-party release tag for ENV=prod. The prod tag-rewrite in
# gate_env_apps replaces every floating `:dev` first-party image tag with this so
# the prod-hygiene gate (scripts/validate-prod-hygiene.sh) finds no floating tag.
# Default = a deterministic build stamp; override with --release-tag.
RELEASE_TAG="${RELEASE_TAG:-$(date -u +%Y%m%d)}"
CONFIG_FILE=""
TIMEZONE="UTC"
DEFAULT_USER="snap"
DEFAULT_USER_PASS="hugmesh"
ROOT_PASS="hugmesh"
SEED_STAGE3_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-hardened-openrc.txt"
HEADSCALE_VERSION="0.23.0"
TAILSCALE_VERSION="1.78.1"
SKIP_MESH=false
SKIP_TAILSCALE=false
# --with-tailscale / --no-tailscale and --with-sso / --no-sso are EXPLICIT user
# overrides that win over a role's default posture (e.g. a standalone desktop
# defaults mesh+SSO OFF, but --with-tailscale/--with-sso force them back ON).
# Empty = "use the role default"; 'on'/'off' = the user chose explicitly.
MESH_FORCED=""
SSO_FORCED=""
SKIP_KERNEL=false
SKIP_CLEAN=false
RESUME=false
# ── Radio attack surface (DISABLED BY DEFAULT — hardened posture) ───
# WiFi + Bluetooth are OFF by default to shrink the attack surface: at first boot
# rfkill blocks both radios, their kernel modules are blacklisted, and no wifi/
# bluetooth service is enabled. ETHERNET + the Tailscale tailnet are UNAFFECTED
# (NetworkManager still manages wired; tailscaled still runs). Re-enable per build
# with ENABLE_WIFI=true / ENABLE_BLUETOOTH=true (env/brand.conf) or the
# --enable-wifi / --enable-bluetooth flags. Precedence: built-in (false) <
# brand.conf < CLI flag.
ENABLE_WIFI="${ENABLE_WIFI:-false}"
ENABLE_BLUETOOTH="${ENABLE_BLUETOOTH:-false}"
# Root SSH login is DISABLED by default (hardened posture: PermitRootLogin no +
# locked root). Opt back in per build with --permit-root-login yes|prohibit-password
# (env/brand.conf: PERMIT_ROOT_LOGIN). The non-root KEYS admin user stays the entry point.
PERMIT_ROOT_LOGIN="${PERMIT_ROOT_LOGIN:-no}"
# ── Mesh-node identity provider (I6; docs/IDENTITY-PROVIDERS.md) ─────────────
# casdoor (the NATIVE DEFAULT) changes NOTHING — every sysroot byte is identical
# to before the axis existed. --idp entra|aws|oidc (+ --idp-issuer/--idp-client-id
# [--idp-jwks]) switches token VALIDATION to an external OIDC provider:
#   (a) bake /etc/hugmesh/idp.conf (provider/issuer/client_id/jwks_uri, 0644,
#       PUBLIC identifiers only — never a secret),
#   (b) an idp-aware pass AFTER rebrand_sysroot rewrites the baked tree's
#       https://id.<CLUSTER_DOMAIN> issuer literals + in-cluster JWKS pins,
#   (c) the built-in Casdoor ArgoCD apps/manifests are gated OUT of the tree,
#   (d) README-IDP.md states honestly what does NOT work externally (native
#       /bff/login, MFA stamping, roles/groups model, signup-gate, role-sync).
IDP="${IDP:-casdoor}"
IDP_ISSUER="${IDP_ISSUER:-}"
IDP_CLIENT_ID="${IDP_CLIENT_ID:-}"
IDP_JWKS="${IDP_JWKS:-}"
# ── Artifact selection (mirrors rpi5): .img is now the DEFAULT deliverable ──
BUILD_IMG=true          # produce the flashable raw .img (DEFAULT)
ROOT_MiB=8192           # ext4 root partition size in the .img (growroot expands it on first boot)
IMG_SIZE_SET=false      # true once --img-size is given, so the client auto-bump below defers to it
GROW_POLICY="fill"      # first-boot grow policy baked into /etc/growfs.conf: fill|none|<size>
COMPRESS_IMG=false      # xz -9 the finished .img
LIVE_ISO=true           # self-booting live squashfs ISO (DEFAULT; --no-live-iso to skip)
INSTALLER_ISO=false     # stage4 + install-x86.sh data ISO (opt-in: --installer-iso)
BUILD_TAR=true          # also emit the mounted-filesystem tarball (.fs.tar.xz)
# --print-plan: resolve + validate everything, print the machine-greppable build
# plan (one PLAN_KEY=VALUE per line) and exit 0 BEFORE any mutation (no root, no
# disk writes, no network — it runs BEFORE the run-as-root gate). The CLI/make/
# menu/Studio channels + the build-matrix harness (tests/build-matrix/check.sh)
# verify every role/flag combo through it. Secrets are printed as REDACTED.
PRINT_PLAN=false

# ── STANDALONE hardened desktop (no mesh / no SSO / local login) ─────────────
# A STANDALONE desktop is a self-contained personal workstation, NOT a mesh
# client and NOT a k8s node: NO headscale/tailscale, NO Casdoor/OIDC SSO login,
# NO cluster GitOps tree. It boots straight to a lightdm greeter where a NORMAL
# LOCAL USER logs in with a password set at build time (--local-pass, hashed
# here with a salted crypt(3) KDF and never baked in plaintext). The two named
# role arms `standalone-thin` (LXDE) and `standalone-thick` (the most-capable
# Plasma workstation) preset this posture; the flags below also compose onto the
# laptop/chromebook/desktop client roles. See docs/STANDALONE-DESKTOP.md.
STANDALONE=false        # --standalone : self-contained desktop (no mesh/SSO/k8s)
SKIP_SSO=false          # --skip-sso   : drop the Casdoor/OIDC desktop SSO login
                        #   (orthogonal — works on any client role; auto-on for standalone)
CAPABLE=false           # --capable : pull the "most capable" Plasma desktop set
                        #   (packages-desktop-capable.list); auto-on for standalone-thick
LOCAL_USER=""           # --local-user NAME : the standalone local login account
LOCAL_USER_PASS=""      # --local-pass PASS : plaintext; hashed at build, never baked raw
# ── UNAFFILIATED plain desktop (a standalone with ZERO HugMesh affiliation) ──
# Everything --standalone drops, PLUS: neutral identity strings through the whole
# boot/installer chain (GRUB titles, ISO volids, UKI name, installer text — all
# derived from a forced neutral brand), NO hugmesh-* helper tools/services, NO
# /etc/hugmesh marker tree (the functional home.conf moves to a neutral path),
# NO bundled generator source or brand-repo templates, and NO k8s/mesh package
# payload or config remnants. The result is a plain hardened Gentoo desktop.
# Preset by the `standalone-unaffiliated` role arm; composable onto any client/
# standalone role with --unaffiliated. Brand/branding/seed-code/mesh/SSO flags
# CONFLICT with it (hard error) — unaffiliated means no brand identity at all.
UNAFFILIATED=false      # --unaffiliated : plain Gentoo desktop, no HugMesh affiliation
MEDIA_DATA_FORCED=""    # ''|on|off — tracks an explicit --media-data/--no-media-data
                        #   (unaffiliated defaults media-data OFF unless forced on)
# ── user package deltas (--packages-add / --packages-drop) ─────────────────────
# Space-separated Portage atoms threaded from the Studio/worklist on top of the
# role's derived default set. Adds are appended to the resolved set; drops are a
# final grep -vE over it (NEVER emerge --exclude / INSTALL_MASK, which also strip
# transitive deps). Atom charset is validated up front and a tier-1 mandatory atom
# may never be dropped (Decision #5).
PACKAGES_ADD=""
PACKAGES_DROP=""
# ── GPU driver matrix (--gpu-driver) — all common cards, FREE drivers default ──
# FREE drivers (open, no EULA, hardened) are the default. Only NVIDIA has a
# proprietary DISPLAY driver; AMD/Intel "pro" = the open display driver + the
# vendor's proprietary/closed compute + Vulkan stack. Values:
#   all-free    : open Mesa for ALL vendors (amdgpu radeonsi intel iris nouveau) —
#                 works on any GPU. DEFAULT. (Includes the FREE NVIDIA driver, nouveau.)
#   nvidia-free : open NVIDIA only (nouveau).
#   nvidia      : NVIDIA proprietary (x11-drivers/nvidia-drivers, NVIDIA-r2 EULA;
#                 nouveau blacklisted). CUDA optional (--nvidia-cuda).
#   amd-free    : open AMD (amdgpu/radeonsi/radeon).            (alias: ati-free)
#   amd-pro     : open AMD display + amdgpu-pro Vulkan + OpenCL. (alias: ati-pro; EULA)
#   intel-free  : open Intel (i915/iris).
#   intel-pro   : open Intel display + intel-compute-runtime + media stack.
#   none        : no GPU stack (headless).
GPU_DRIVER=""           # --gpu-driver VALUE (default resolves to all-free on a GPU role)
NVIDIA_CUDA=false       # --nvidia-cuda : also bake dev-util/nvidia-cuda-toolkit (nvidia proprietary only)
# ── Edge-AI inference node (GPU model API served to the mesh) ────────────────
# The edge_ai role bakes a GPU inference node and AUTO-SELECTS the edge-ai cluster
# service (Ollama, OpenAI-compatible /v1 API on :11434, scheduled via the nvidia
# device plugin). --with-edge-ai folds the service onto any GPU k8s role (be+gpu /
# omnibus); --no-edge-ai strips it. The model LIBRARY (catalog/preload/runtime/
# serving knobs) is the edge-ai-models ConfigMap, retunable per-domain.
EDGE_AI=false           # the edge_ai NODE role (GPU + CUDA + inference service auto-on)
WANT_EDGE_AI=""         # tri-state: ""=role-default, true=--with-edge-ai, false=--no-edge-ai
EDGE_AI_RUNTIME="ollama"   # --edge-ai-runtime : ollama | vllm
EDGE_AI_MODELS=""          # --edge-ai-models  : comma list of models to PRELOAD (patches the ConfigMap)
EDGE_AI_MODEL_DEFAULT=""   # --edge-ai-model-default : default model when an OpenAI request omits one
WANT_EDGE_AI_ANALYSIS=""   # --with-edge-ai-analysis : also bake the analysis API (separate image; dependsOn edge-ai)
# edge-ai-tts is CPU-only + self-contained (baked-in voice model, no upstream call),
# so — UNLIKE edge-ai-analysis — it has NO dependsOn edge-ai and is NOT folded by
# --with-edge-ai; it is its own independent tri-state (--with-edge-ai-tts / --no-edge-ai-tts).
WANT_EDGE_AI_TTS=""        # tri-state: ""=off (DEFAULT-OFF), true=--with-edge-ai-tts, false=--no-edge-ai-tts
# ── Root full-disk encryption (LUKS2) for the INSTALLED system ───────────────
# The installer (install-x86.sh) LUKS2-encrypts the target root and PROMPTS for
# a system root-unlock passphrase at install time (distinct from the user login
# password). The passphrase is NEVER baked into any artifact. --luks-pass is an
# OPTIONAL unattended-install convenience that writes a 0600 passphrase file into
# the installer tree only (loudly warned). Live ISO / .img / .fs.tar.xz stay
# plaintext (ephemeral / flashed); FDE is applied at INSTALL.
ENCRYPT_ROOT=false      # --encrypt-root : installer LUKS2-encrypts the target root
LUKS_PASS=""            # --luks-pass / --root-unlock-pass : optional unattended passphrase
# ── Optional extra unlock factor (keyfile or FIDO2/YubiKey) ──────────────────
# Either may unlock BOOT (an extra LUKS2 keyslot) or LOGIN (a PAM factor). The
# heavy enrollment that needs the physical device happens at install/first boot;
# the build just generates the keyfile artifact + wires the installer hooks.
UNLOCK_KEYFILE=""       # --unlock-keyfile boot|login : generate a keyfile unlock factor
UNLOCK_YUBIKEY=""       # --unlock-yubikey boot|login : enroll a FIDO2/YubiKey factor
# ── Seed-from-running-system + home-directory archive (optional) ─────────────
SEED_PACKAGES_FROM=""   # --seed-packages-from FILE : extra package list appended to PKG_LISTS
INCLUDE_HOME_ARCHIVE="" # --include-home-archive FILE : bundle a $HOME tarball into the installer ISO
# ── Home directory: provisioning mode + optional per-user ecryptfs + stack code ─
# --home-mode create : firstboot makes a fresh home for the local user (default
#                      when no archive is given).
# --home-mode adopt  : the installed system USES an existing home that already
#                      lives on a device (this host's separate /home partition,
#                      or an attached USB) — the installer mounts it at /home and
#                      does NOT format it, so an existing ecryptfs Private survives.
#                      Requires --home-device LABEL=…|UUID=…|/dev/….
# --home-mode archive: the installer unpacks a bundled $HOME tarball
#                      (--include-home-archive) into the user's home (default when
#                      an archive IS given). Good for a laptop with no data disk.
# --home-mode restore: the installer/firstboot decrypts + unpacks an ENCRYPTED,
#                      compressed FULL-home backup (config + documents + media —
#                      everything but build/cache cruft) from a USB or path. Make
#                      the backup with scripts/archive-home.sh --full --encrypt;
#                      point at it with --home-backup FILE|auto (auto = detect the
#                      marker file on any attached USB). Restores onto the same host
#                      or a separate one.
# --home-encrypted   : layer per-user ecryptfs (login-password-unwrapped) ON TOP of
#                      the LUKS2 full-disk root — the same posture as this host.
HOME_MODE=""
HOME_DEVICE=""
HOME_BACKUP=""          # --home-backup FILE|auto : for --home-mode restore, the
                        # encrypted full-home backup (auto = detect on attached USB)
HOME_ENCRYPTED=false
# --home-seed-code none|repos|stack|mesh : drop the whole HugMesh source tree +
# a docker-compose runner into ~/hugmesh-stack so the box can run the entire
# stack dockerized (stack) or join an existing tailnet as a dockerized mesh node
# (mesh); 'repos' is just the code. --home-seed-code-from is where to source it
# (a dir like this host's GitHub checkout, or a .tar.* — default: clone at runtime).
HOME_SEED_CODE="none"
HOME_SEED_CODE_FROM=""
# --distdir DIR : reuse a Gentoo distfiles cache from a mounted drive instead of
# re-downloading sources. Empty = auto-detect (top level of /media/*, common
# portage dirs); set explicitly to force one. Speeds rebuilds / enables offline.
DISTDIR_SRC=""
# --shared-assets DIR / --no-shared-assets (env: HUGMESH_SHARED_ASSETS): the fleet's
# SHARED build-asset root. On x86 it supplies the stage3 SEED cache (one amd64
# tarball for every build instead of one per BUILD_SUBDIR), a read-only view of
# the fleet distfiles the cross builders populate, AND — issue #46 — the shared
# per-arch binpkg POOL (<root>/pkgdir/snap-build-x86). The chroot's PKGDIR is
# /var/cache/binpkgs (make.conf.tmpl); mount_chroot BIND-MOUNTS the shared pool
# there so every amd64 role reads/writes ONE pool (wave-1 measured 0% x86 reuse
# and 2,042 duplicate compiles because each wl-<id> sysroot held its own pool and
# was discarded). The two carve-outs that sharing needed are implemented, not
# waived: the Phase-8 clean re-checks the bind is DETACHED before touching
# var/cache/binpkgs (an rm -rf through it would empty the fleet's pool), and a
# --cached image COPIES the pool back in after the unmount so the embedded-cache
# promise still holds. Safety: same-arch sharing is fingerprint-guarded
# (sa_pool_guard: CHOST+CFLAGS+profile) and USE differences between roles are
# pruned per-package by --binpkg-respect-use=y (see docs/SHARED-BINPKG.md).
# Empty ⇒ "${WORK_DIR}/shared", already covered by the Makefile's -v $(WORK_DIR):/out.
SHARED_ASSETS_DIR="${HUGMESH_SHARED_ASSETS:-}"
SHARED_ASSETS_ENABLED=true
# --no-kernel-cache (env: HUGMESH_KERNEL_CACHE=off): opt out of the signed-kernel
# artifact cache under <shared-root>/kernel. Build-phase escape hatch, same class as
# --no-shared-assets: it never changes the ARTIFACT, only whether an identical kernel
# is recompiled and re-signed. See scripts/_kernel-cache-lib.sh.
KERNEL_CACHE_ENABLED=true
# --live-toram / --no-live-toram : the live ISO gets a "Copy to RAM (removable)"
# GRUB entry (rd.live.ram=1) so the whole live system caches into memory and the
# USB/DVD can be pulled after boot. Default ON.
LIVE_TORAM=true
# --installer-ui cli|ncurses|calamares|all : which installer front-ends the live/
# installer ISO offers as boot entries. 'calamares' = graphical Qt installer (like
# Ubuntu); 'ncurses' = whiptail menu; 'cli' = unattended/manual install-x86.sh.
# Empty = role default (standalone => all). Adds app-admin/calamares when graphical.
INSTALLER_UI=""
# --cached / --uncached : a CACHED ISO embeds the binpkg cache (+ distfiles) so the
# installed system can rebuild/extend packages OFFLINE and reinstall fast; UNCACHED
# is lean (no caches). Empty = uncached (default).
ISO_CACHED=false
# --packages-only : PREBUILD mode. Run the chroot payload emerge (populating PKGDIR
# under FEATURES=buildpkg) then exit 0 BEFORE Phase 6 (mesh) / kernel / image
# assembly. Emits NOTHING image-shaped — the only output is the binpkg pool a later
# per-role image build reuses via --usepkg (--resume into this same sysroot). This
# is a host/CI build-phase flag, NOT a Studio ImageConfig field (like --specs-dir).
PACKAGES_ONLY=false
# --allow-missing-packages : accept a KNOWINGLY degraded image. The payload emerge
# runs --keep-going so one unbuildable optional package can't throw away hours of
# work; the completeness gate after it then FAILS the build when any requested atom
# did not actually install (before this gate, such a build emitted a full set of
# "prod" artifacts silently missing packages — see the gate's comment). This flag
# downgrades that hard failure to a warning for the operator who genuinely wants
# the image anyway. Default OFF: a silent hole is the thing being fixed.
ALLOW_MISSING_PACKAGES=false
# --no-emerge-plan : skip the read-only `--pretend` plan-preview pass that runs
# before the @world and payload emerges (scripts/_emerge-plan-lib.sh). The pass
# is a SECOND full dependency resolution per planned group — real, unmeasured
# cost, see docs/EMERGE-PLAN-PREVIEW.md — whose only product is the Studio's
# up-front "packages that WILL be installed" list. Build-phase opt-out in the
# --allow-missing-packages class (never a Studio field); the emission itself is
# failure-tolerant either way (WARN + no plan, never an aborted build).
EMERGE_PLAN_ENABLED=true
# --bundle-source : ship the generator source in the image (/usr/src/hugmesh-
# generator) + a regenerate helper, so you can build a fresh customized ISO from the
# running desktop. Default ON for standalone (self-hosting appliance).
BUNDLE_SOURCE=""
# ── Desktop branding (boot screen / login / wallpaper / colours) ─────────────
# Composable across ALL desktop generations (standalone or tailnet client; cli,
# ncurses or graphical install). A --theme NAME pulls a bundled preset from
# specs-x86/branding/themes/NAME/ (light | dark | purple | grey — the four premade
# themes scripts/gen-branding-themes.py renders); --branding-dir DIR supplies a
# whole brand dir; the individual --wallpaper/--grub-background/--login-background/
# --brand-logo/--accent-color/--color-scheme flags override single pieces on top.
# Everything is baked by hugmesh-branding at build time and stays user-changeable
# afterwards UNLESS --brand-locked is set (managed image). Empty => stock look.
BRANDING_THEME=""        # --theme NAME (bundled preset dir name)
BRANDING_DIR=""          # --branding-dir DIR (full brand dir)
BRAND_WALLPAPER=""       # --wallpaper FILE
BRAND_GRUB_BG=""         # --grub-background FILE
BRAND_GRUB_THEME=""      # --grub-theme DIR (full GRUB theme.txt dir; else one is generated)
BRAND_LOGIN_BG=""        # --login-background FILE
BRAND_LOGO=""            # --brand-logo FILE
BRAND_ACCENT=""          # --accent-color '#RRGGBB'
BRAND_COLOR_SCHEME=""    # --color-scheme FILE.colors
BRAND_LOCKED=false       # --brand-locked : user cannot re-theme (admin/managed image)
# ── Egress VPN (outbound) wired into NetworkManager ──────────────────────────
# --egress-vpn FILE drops a WireGuard (.conf) / OpenVPN (.ovpn) / NM keyfile
# (.nmconnection) into the desktop; first boot imports it into NetworkManager so the
# user can add/remove/toggle it. Split-tunnel keeps the tailnet + LAN direct.
# --egress-vpn-locked = managed tailscale node: it autoconnects and the user cannot
# remove it (an NM dispatcher re-asserts it). See hugmesh-egress-vpn.
EGRESS_VPN_FILE=""       # --egress-vpn FILE
EGRESS_VPN_LOCKED=false  # --egress-vpn-locked
# --kernel-builtin : compile most in-tree config as built-in (=y) instead of modules,
# EXCEPT symbols in specs-x86/kernel/keep-as-module.list (out-of-tree / firmware /
# load-order cases). CONFIG_MODULES stays on so out-of-tree nvidia.ko still loads.
# A smaller attack surface (no on-demand module loading) — fits the hardened posture.
KERNEL_BUILTIN=false
# ── Network/host security stack ──────────────────────────────────────────────
# --proxy-stack / --no-proxy-stack : Squid (cache) + Privoxy (filter) chained, wired
#   into Firefox. DEFAULT ON for desktops (ROLE_CLIENT), N/A on servers.
# --snort / --no-snort : Snort IDS. DEFAULT ON for ALL images.
# --with-aide : AIDE file-integrity IDS, OPT-IN (off by default); when on it is fully
#   configured (DB initialized at first boot + daily check cron).
PROXY_STACK=auto         # auto => on for ROLE_CLIENT desktops; or true/false
SNORT_IDS=true           # --no-snort to disable
WANT_AIDE=false          # --with-aide to enable
# ── External media data device (Vaults + Steam) — DEFAULT ON, configurable ───
# A SEPARATE data disk (kept across reinstalls) holds Steam/ and a gocryptfs
# Vaults/ at /media. The installed system auto-detects it (by LABEL if set, else
# by scanning attached non-root partitions for the marker dirs) and mounts it
# nofail at /media, installs gocryptfs for the vault, and points Steam's library
# at /media/Steam. All knobs are baked to /etc/hugmesh/media.conf.
MEDIA_DATA=true         # --no-media-data disables the whole feature
MEDIA_MOUNT="/media"    # where the data device mounts
MEDIA_LABEL=""          # --media-label : match the data device by FS LABEL (else content-scan)
MEDIA_MARKERS="Steam Vaults"   # marker dir names that identify the data device by content
STEAM_DIR="/media/Steam"
STEAM_DELIVERY="native"   # --steam : native (DEFAULT; steam-overlay + multilib) | flatpak | none
# ── Thin-desktop stream host (§8b) — CLIENT desktops on the tailnet, opt-in ──
# --with-sunshine bakes Sunshine (games-util/sunshine) + the mesh-scoped
# nftables fence (hugmesh-sunshine-firewall: stream ports tailnet-only, pairing
# web UI loopback-only) + the in-session XDG-autostart launcher, so a
# mesh-enrolled Quest running Moonlight (the quest wizard's --thin-desktop leg)
# can open this node's desktop OVER THE TAILNET ONLY. DEFAULT-OFF; a no-op
# with a warning on non-client roles and on desktops without a tailnet
# (standalone/unaffiliated/--skip-tailscale). See docs/MDM.md 'Thin desktop'.
WANT_SUNSHINE=false
VAULTS_DIR="/media/Vaults"
VAULTS_ENABLED=true     # --no-vaults disables gocryptfs / the /media/Vaults wiring
# ── Secure Boot + KEYS USB (mirror the model this host already uses) ──────────
# Secure Boot is ON by default: the kernel ships as a signed UKI + Microsoft shim.
# By default a throwaway org key is generated under WORK_DIR/secureboot. Point
# --secureboot-key/--secureboot-cert (or --keys-usb DIR, which uses
# DIR/Keys/kernel_key.{pem,der}) at the KEYS USB's existing signing key so the
# installed host boots under the Secure Boot key already enrolled in its firmware.
SECURE_BOOT=true        # --no-secure-boot to skip UKI signing/shim
KEYS_USB=""             # --keys-usb DIR : a KEYS USB providing SB keys (Keys/kernel_key.*) + provisioning
SECUREBOOT_KEY=""       # --secureboot-key FILE : SB signing private key (PEM); overrides the generated org key
SECUREBOOT_CERT=""      # --secureboot-cert FILE : SB signing cert (PEM/DER)

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'; YEL=$'\033[0;33m'; BOLD=$'\033[1m'; RST=$'\033[0m'
banner(){ echo -e "\n${CYAN}${BOLD}==> $1${RST}"; }
info(){ echo -e "${GREEN}    $1${RST}"; }
warn(){ echo -e "${YEL}    WARNING: $1${RST}"; }
err(){ echo -e "${RED}    ERROR: $1${RST}" >&2; }

usage() {
cat <<EOF
build-x86-host-stage4.sh — hardened Gentoo amd64 k8s/GPU worker image.

  -w, --work-dir DIR        Products dir (.img/.iso/.fs.tar.xz/stage4/keys-*).
                            Default: ./out  (local + gitignored)
  --build-subdir NAME       Per-arch subdir under --work-dir for the heavy build
                            tree (sysroot/distfiles/pkgdir/ISO staging). Default:
                            snap-build-x86 (or BUILD_SUBDIR=NAME). Keeps the amd64
                            build from sharing a sysroot with the Pi (aarch64)
                            build under a shared --work-dir (build-all-roles.sh).
  -j, --jobs N              Parallel jobs. Default: $(nproc)
  -v, --version STR         Version stamp. Default: ${REL_VERSION}
  -r, --role ROLE           NODE: pki | be | fe | be+gpu | edge_ai | omnibus  (host = be+gpu alias).
                            edge_ai = GPU inference node serving an OpenAI-compatible
                              model API to the mesh (NVIDIA + CUDA + edge-ai service).
                            CLIENT (person device, see docs/CLIENT-IMAGES.md):
                              laptop | chromebook | desktop  (desktop = full/thick).
                            Default: ${ROLE}. Gates GPU/desktop stack, services, k8s.
  --person-role ROLE        CLIENT only — FD-08 identity: user|mod|admin|superadmin
                            (default user). Baked to /etc/hugmesh/identity-role.
  --domains LIST            CLIENT only — domain tie (space/comma separated; first =
                            primary). Baked to /etc/hugmesh/domains + filename tag.
  --desktop WEIGHT          CLIENT only — thin (LXDE/openbox, default) | full (XFCE+).
  -H, --hostname NAME       Hostname. Default: derived from --role.
  -T, --timezone ZONE       Timezone. Default: ${TIMEZONE}
      --env test|prod       Build ENV, BAKED into the image. Default: ${ENV}.
                            test = LAN-only (cluster wildcard DNS; cloudflared/ACME
                            pruned; OAuth/SMTP optional). prod = real public domain
                            (Cloudflare/ACME allowed; creds from keys USB) — prints
                            a LOUD announced banner before building.
      --cluster-domain D    Default: ${CLUSTER_DOMAIN}
      --superdomain D       Orchestration superdomain (mesh MagicDNS suffix) baked to
                            /etc/<brand>/superdomain + headscale base_domain. Mesh only;
                            permanently internal (never the go-live apex). Default: derived
  -u, --user NAME           Fallback user. Default: ${DEFAULT_USER}
      --user-password PASS  Default: ${DEFAULT_USER_PASS}
      --root-password PASS  Default: ${ROOT_PASS}
      --headscale-version V Default: ${HEADSCALE_VERSION}
      --tailscale-version V Default: ${TAILSCALE_VERSION}
      --seed-url URL        amd64 stage3 index URL.
      --enable-wifi         Re-enable WiFi (DISABLED by default: rfkill block +
                            blacklisted modules + no service). Ethernet + the
                            tailnet are unaffected. (env/brand.conf: ENABLE_WIFI=true)
      --enable-bluetooth    Re-enable Bluetooth (DISABLED by default: rfkill block
                            + blacklisted modules + no bluetooth service).
                            (env/brand.conf: ENABLE_BLUETOOTH=true)
      --permit-root-login V Root SSH login. V = no (DEFAULT, hardened) |
                            prohibit-password (key-only root) | yes. Disabled by
                            default; admin via the non-root KEYS user.
                            (env/brand.conf: PERMIT_ROOT_LOGIN=yes)
      --enable-games        Bake the HugMesh Game Studio optional service +
                            games.<CLUSTER_DOMAIN> subdomain (OPT-IN; OFF by
                            default). Equivalent to adding 'games' to
                            --optional-services. (env/brand.conf: ENABLE_GAMES=true)
      --optional-services "<slugs>"
                            The SUBSET of user-level OPTIONAL services to bake
                            (allow-list). Choose from akkoma tuwunel phpbb games
                            owncast tube character-studio character-forge, or the
                            literal "all" (every user-level slug). Unlisted slugs
                            are pruned from the baked GitOps tree by
                            gate_optional_services.
                            Built-in DEFAULT (no selection) = "akkoma tuwunel phpbb";
                            games/owncast/tube/character-studio/character-forge are
                            DEFAULT-OFF.
                            (env/brand.conf: OPTIONAL_SERVICES; =all = the full set)
      --all-services        Bake EVERY user-level OPTIONAL service — the FULL-SET
                            shortcut, equivalent to --optional-services all.
                            EXCLUDE_SERVICES still subtracts (e.g. --all-services
                            --exclude-services "games" bakes everything but games).
                            NOTE: the INFRA-level slugs (egress-vpn, tor,
                            workloadConsole, anubis) are NOT included by "all".
      --exclude-services "<slugs>"
                            The SUBTRACTIVE build-time exclusion list: force-OFF
                            these user-level slugs no matter how they were selected
                            (default / brand.conf / --optional-services /
                            --enable-games / 'all'). Applied LAST. Each excluded
                            slug's Application + manifests + gateway routes +
                            route-access rows are pruned and its installed-services
                            ConfigMap + 13a ApplicationSet flag renders "false".
                            Example: --exclude-services "phpbb tuwunel".
                            (env/brand.conf: EXCLUDE_SERVICES)
      --with-edge-ai        Bake the edge-AI inference service (Ollama OpenAI /v1 API,
                            GPU-scheduled) onto a GPU k8s role; auto-on for --role
                            edge_ai. Other mesh nodes consume it over k8s + tailnet.
      --no-edge-ai          Do NOT bake the edge-AI service (overrides the edge_ai default).
      --edge-ai-runtime R   Inference runtime: ollama (default) | vllm.
      --edge-ai-models LIST Comma list of models to PRELOAD (patches the edge-ai-models
                            ConfigMap; e.g. 'llama3.2:3b,nomic-embed-text').
      --edge-ai-model-default M  Default model when an OpenAI request omits one.
      --with-edge-ai-analysis  Also bake the edge-ai-analysis task API (image NSFW/abuse
                            classify + perceptual-hash, log triage verdicts to the mesh).
                            Needs edge-ai + a SEPARATE container image (DEFAULT-OFF).
      --with-edge-ai-tts     Bake the edge-ai-tts voice-synthesis API (Piper TTS +
                            viseme timeline for the VN voice feature). CPU-only,
                            self-contained — NO edge-ai dependency. A SEPARATE
                            container image (DEFAULT-OFF). --no-edge-ai-tts to keep off.
      --with-character-studio  Bake the Character Studio (VN) frontend remote at
                            /character-studio (ROLE_USER). OPTIONAL, DEFAULT-OFF (admin
                            gate). Equivalent to adding 'character-studio' to
                            --optional-services. --no-character-studio to keep it off.
      --with-character-forge  Bake the Character Forge (3D character maker) slug —
                            BFF db + BFF api (/bff/character-forge) + frontend
                            remote at /character-forge (ROLE_USER). OPTIONAL,
                            DEFAULT-OFF (admin gate). Equivalent to adding
                            'character-forge' to --optional-services.
                            --no-character-forge to keep it off. See docs/XR-CHAT.md.
      --idp P               Identity provider the baked services TRUST: casdoor
                            (DEFAULT — the built-in IdP, zero change) | entra
                            (Azure Entra ID) | aws (AWS Cognito) | oidc (any other
                            OIDC provider). External mode bakes /etc/hugmesh/
                            idp.conf, rewrites the baked tree's issuer/JWKS pins,
                            gates the Casdoor apps out, and drops README-IDP.md
                            stating what does NOT work externally (native
                            /bff/login, MFA stamping, roles/groups, signup-gate —
                            docs/IDENTITY-PROVIDERS.md). Fail-closed validation.
      --idp-issuer URL      External OIDC issuer (https:// — REQUIRED unless
                            --idp casdoor; must byte-match the token 'iss').
      --idp-client-id ID    External OIDC client id (public identifier; REQUIRED
                            unless --idp casdoor. Client SECRETS are never flags).
      --idp-jwks URL        External JWKS override. Empty derives per provider:
                            entra <issuer>/discovery/v2.0/keys, aws
                            <issuer>/.well-known/jwks.json, oidc
                            <issuer>/.well-known/jwks.
      --skip-mesh           Don't install headscale/tailscale.
      --skip-tailscale      headscale only.
      --skip-kernel         Don't build the kernel.
      --skip-clean          Keep docs/headers/symbols.
  Artifacts (.img + live ISO are the DEFAULT; installer ISO is opt-in):
      --no-img              Don't build the raw .img.
      --img-size MiB        ext4 root size in the .img (built COMPACT, not
                            padded to the USB). Default: ${ROOT_MiB}.
      --grow V              First-boot grow policy baked in (/etc/growfs.conf):
                            fill (DEFAULT, fill the whole USB/SD/NVMe) | none
                            (keep compact) | <size> e.g. 16G, 12000M, 50%.
                            Override per-device via growfs.conf on the ESP or a
                            growfs=<v> kernel cmdline token (no rebuild).
      --no-grow             Shorthand for --grow none.
      --compress            xz -9 the finished .img.
      --live-iso            Force-build the self-booting live squashfs ISO (DEFAULT).
      --no-live-iso         Skip the live ISO (clean disable; no installer ISO implied).
      --installer-iso       Also build a stage4 + install-x86.sh data ISO.
      --no-tar              Don't emit the mounted-filesystem tarball (.fs.tar.xz).
      --resume              Reuse an existing sysroot.
      --print-plan          Resolve + validate all flags, print the build plan
                            (PLAN_KEY=VALUE lines) and exit 0 — no root, no
                            writes, no network. Secrets print as REDACTED.
                            Invalid role/flag combinations exit non-zero.
  STANDALONE hardened desktop (self-contained; no mesh / no SSO / local login):
      --standalone          Self-contained desktop: NO headscale/tailscale, NO
                            Casdoor/OIDC SSO, NO k8s/cluster tree. Boots to a
                            lightdm greeter with a NORMAL LOCAL USER. Implies
                            --skip-mesh + --skip-sso. (roles standalone-thin /
                            standalone-thick preset this.)
      --skip-sso            Drop the Casdoor/OIDC desktop SSO login from ANY
                            client image (orthogonal; auto-on for --standalone).
      --unaffiliated        UNAFFILIATED plain desktop: everything --standalone
                            drops, PLUS no HugMesh identity anywhere (neutral
                            GRUB titles/ISO volids/UKI/installer text derived
                            from a forced neutral brand), no hugmesh-* tools
                            or /etc/hugmesh markers, no bundled generator
                            source, no k8s/mesh payload. Brand/branding/
                            seed-code/mesh/SSO flags HARD-CONFLICT with it.
                            (role standalone-unaffiliated presets this at the
                            thick/Plasma weight.)
      --capable             Pull the "most capable" Plasma workstation package
                            set (packages-desktop-capable.list). Auto-on for the
                            standalone-thick role.
      --local-user NAME     Standalone local login account (default: ${DEFAULT_USER}).
      --local-pass PASS     Password for the local user. Hashed at build time
                            (yescrypt, \$6\$ fallback); the plaintext is NEVER baked.
  GPU driver — all common cards; FREE (open) drivers are the default (GPU roles):
      --gpu-driver VALUE    all-free (DEFAULT — open Mesa for every vendor; any GPU;
                            NVIDIA=nouveau) | nvidia-free (nouveau) | nvidia
                            (proprietary x11-drivers/nvidia-drivers, NVIDIA-r2 EULA,
                            nouveau blacklisted) | amd-free (amdgpu/radeonsi; alias
                            ati-free) | amd-pro (+ AMDGPU-PRO Vulkan/OpenCL, EULA) |
                            intel-free (i915/iris) | intel-pro (+ Intel compute/media
                            stack) | none. Only NVIDIA has a proprietary DISPLAY
                            driver; AMD/Intel "pro" add closed compute/Vulkan on top
                            of the OPEN display driver.
      --nvidia              Alias for --gpu-driver nvidia.
      --nvidia-cuda         Also bake dev-util/nvidia-cuda-toolkit (--gpu-driver nvidia).
      (Client desktops also bake mainline e-ink/e-paper display drivers as modules.)
  Root full-disk encryption (LUKS2) for the INSTALLED system (installer ISO):
      --encrypt-root        The installer LUKS2-encrypts the target root and
                            PROMPTS for a system root-unlock passphrase at install
                            time (distinct from the login password; never baked).
                            Auto-on for standalone roles. Implies --installer-iso.
      --luks-pass PASS      OPTIONAL unattended passphrase (alias --root-unlock-pass).
                            Written 0600 into the installer tree ONLY — loudly
                            warned; prefer the interactive install-time prompt.
      --unlock-keyfile WHERE  Generate a keyfile unlock factor: boot (extra LUKS2
                            keyslot, keyfile on ESP) | login (PAM factor).
      --unlock-yubikey WHERE  Enroll a FIDO2/YubiKey factor: boot (LUKS2 FIDO2) |
                            login (pam_u2f). Device must be present at install.
  External media data device (Vaults + Steam) — DEFAULT ON, optional:
      --no-media-data       Disable the media-data auto-detect (default ON).
      --media-label LABEL   Match the data device by filesystem LABEL (default:
                            content-scan for the Steam/Vaults marker dirs).
      --steam DELIVERY      native (DEFAULT; steam-overlay + multilib, gaming
                            desktops only) | flatpak | none. Library → /media/Steam.
      --with-sunshine       Thin-desktop stream host (CLIENT desktops on the
                            tailnet only; DEFAULT-OFF): bake Sunshine + the
                            mesh-scoped nftables fence (stream ports admitted
                            ONLY on the tailscale iface from 100.64/10; pairing
                            web UI 47990 loopback-only) + an in-session XDG
                            autostart. Pairs with the Quest wizard's
                            --thin-desktop Moonlight leg (docs/MDM.md).
      --no-sunshine         Force it off (override a brand.conf default).
      --no-vaults           Don't install gocryptfs / wire /media/Vaults.
      --allow-missing-packages  Ship the image even if some requested packages
                            failed to merge. The payload emerge uses --keep-going,
                            and the completeness gate after it normally FAILS the
                            build listing every atom that did not install — this
                            downgrades that to a warning. Use only when you have
                            read the list and genuinely want a degraded image.
      --no-emerge-plan      Skip the read-only --pretend plan preview emitted
                            before the @world and payload emerges (the Studio's
                            up-front resolved-package list). Saves one extra
                            dependency resolution per planned group; the build
                            itself is identical with or without it.
  Seed from a running system + bake a home directory:
      --seed-packages-from FILE  Append a package list (e.g. produced by
                            scripts/seed-packages-from-running-system.sh) to the
                            emerge set — "copy all installed programs".
      --include-home-archive FILE  Bundle a \$HOME archive (scripts/archive-home.sh)
                            into the installer ISO; unpacked into the new user's
                            home, leaving the rest of the system unchanged.
      --home-mode MODE      How the installed user's home is provisioned:
                              create  - fresh home (default w/o an archive)
                              adopt   - USE an existing home already on a device
                                        (this host's /home partition, or a USB) in
                                        place; needs --home-device. Never formats it.
                              archive - unpack --include-home-archive (default w/ one)
                              restore - decrypt+unpack an encrypted full-home backup;
                                        needs --home-backup FILE|auto
      --home-device SPEC    adopt: LABEL=…|UUID=…|/dev/… of the existing home.
      --home-backup F|auto  restore: the encrypted backup (auto = find on a USB).
      --home-encrypted      Layer per-user eCryptfs on top of the LUKS2 root
                            (encrypted home, login-password unwrapped).
      --home-seed-code MODE  none|repos|stack|mesh — drop the whole HugMesh
                            source + a docker-compose runner into ~/hugmesh-stack
                            so the box can run the stack dockerized (stack) or join
                            a tailnet as a dockerized mesh node (mesh).
      --home-seed-code-from PATH  Source the repos from a dir/tar (else clone at runtime).
      --with-tailscale | --no-tailscale   Force the tailnet agent ON/OFF (any role).
      --with-sso | --no-sso               Force the Casdoor/OIDC login ON/OFF (any role).
      --distdir DIR         Reuse a Gentoo distfiles cache from a mounted drive
                            (default: auto-detect /media/*; speeds rebuilds / offline).
      --shared-assets DIR   Fleet-wide asset root: the amd64 stage3 seed cache
                            (<DIR>/seed/amd64) and the shared distfiles
                            (<DIR>/distfiles, exposed read-only). Default
                            <work-dir>/shared; env HUGMESH_SHARED_ASSETS. The cached
                            seed is RE-VERIFIED (signed DIGESTS) on every reuse.
      --no-shared-assets    Opt out — private seed/distfiles under the build tree.
      --no-kernel-cache     Opt out of the signed-kernel artifact cache
                            (<shared-root>/kernel): always recompile and re-sign the
                            kernel. Env: HUGMESH_KERNEL_CACHE=off. Entries are keyed
                            on board + kernel version + config digest + the SIGNING
                            KEY FINGERPRINT, so a re-keyed fleet misses by design.
      --live-toram | --no-live-toram  Live ISO "Copy to RAM (removable)" boot entry
                            so the stick can be pulled after boot (default ON).
      --installer-ui UI     cli|ncurses|calamares|all — installer front-ends offered
                            as live-ISO boot entries. calamares = graphical Qt
                            installer (Ubuntu-style); standalone defaults to 'all'.
      --cached | --uncached  CACHED embeds the binpkg cache (+distfiles) for offline
                            rebuild / fast reinstall; UNCACHED is lean (default).
      --bundle-source | --no-bundle-source  Ship the generator source +
                            'hugmesh-regenerate' so the desktop can build a fresh
                            customized ISO (default ON for standalone).
  -h, --help                This help.

Run on an amd64 Gentoo host, as root. The default deliverables are a UEFI GPT
.img (ESP + ext4 root, GRUB-EFI --removable, growroot-expandable) that boots a
PC directly, a self-booting live squashfs ISO (--no-live-iso to skip), and the
mounted-filesystem tarball (--no-tar to skip). --installer-iso additionally
bundles install-x86.sh to write the layout to disk.
EOF
exit "${1:-0}"
}

# ── Identity-field input validation (defense-in-depth) ────────────────────────
# DEFAULT_USER/LOCAL_USER and BRAND/ORG/CLUSTER_DOMAIN/GAMES_DOMAIN/HOSTNAME/
# BRAND_TITLE end up (a) as unquoted shell words in root-run first-boot scripts,
# (b) on the REPLACEMENT side of `sed s|..|VALUE|` in render_template/rebrand_sysroot,
# and (c) inside sourced KEY=VALUE files (brand.conf/home.conf). A `;`/newline/`'`
# in a username, a `|`/`&`/newline in a brand/domain, or shell-meta in a title are
# all injection vectors. Reject anything outside a strict charset, fail-closed, at
# the earliest boundary (arg/config parse). The escaping at each sink stays as a
# second layer. Legit values (user 'snap', brand 'hugmesh', domain
# 'hugmesh.net', org 'hugmesh', title 'HugMesh Systems') pass.
_validate_username() {   # $1=field-name $2=value ; POSIX-ish login name
    case "$2" in
        '') return 0 ;;  # empty = "use the default" downstream; not user-injected
        *) [[ "$2" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
             || { err "$1 '$2' is not a valid username (allowed: ^[a-z_][a-z0-9_-]{0,31}\$)"; exit 1; } ;;
    esac
}
_validate_slug() {       # $1=field-name $2=value ; single DNS label / brand slug
    [[ "$2" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
        || { err "$1 '$2' is not a valid slug (allowed: lowercase DNS label ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\$)"; exit 1; }
}
_validate_org() {        # $1=field-name $2=value ; org name (mixed case, e.g. hugmesh)
    # No slash/space/quote/backslash/$/backtick/|/&/newline — it is lowercased into a
    # path component (org_lc) and used as a sed replacement; keep it a safe identifier.
    [[ "$2" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]{0,62}[A-Za-z0-9])?$ ]] \
        || { err "$1 '$2' is not a valid org name (allowed: ^[A-Za-z0-9]([A-Za-z0-9._-]{0,62}[A-Za-z0-9])?\$)"; exit 1; }
}
_validate_dnsname() {    # $1=field-name $2=value ; dotted DNS name (domains)
    [[ "$2" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$ ]] \
        || { err "$1 '$2' is not a valid DNS name (allowed: lowercase RFC-1123 dotted name)"; exit 1; }
}
_validate_hostname() {   # $1=field-name $2=value ; single hostname label (may be empty -> derived)
    case "$2" in
        '') return 0 ;;
        *) [[ "$2" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
             || { err "$1 '$2' is not a valid hostname (allowed: lowercase DNS label)"; exit 1; } ;;
    esac
}
_validate_title() {      # $1=field-name $2=value ; printable label, NO shell-meta/quote
    # Forbid the characters that break out of "KEY=..." in a sourced file or corrupt a
    # sed replacement: quote, backslash, dollar, backtick, pipe, ampersand, newline,
    # and other control chars. Allow letters/digits/space and a small safe punctuation set.
    [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._\ -]{0,63}$ ]] \
        || { err "$1 '$2' contains disallowed characters (allowed: letters/digits/space/.-_ , no quote/backslash/\$/backtick/|/&/newline)"; exit 1; }
}
# Escape a string for the REPLACEMENT side of `sed s|...|...|`: backslash first,
# then the ampersand (whole-match) and the `|` delimiter. Mirrors the helper in
# specs/usr/sbin/hugmesh-branding. Newlines are forbidden by the validators above,
# so a tainted-but-validated value cannot smuggle a second sed command.
_sed_rep_escape() {
    local s="$1"
    s="${s//\\/\\\\}"   # \  -> \\
    s="${s//&/\\&}"     # &  -> \&
    s="${s//|/\\|}"     # |  -> \|
    # Belt-and-suspenders (parity with rpi5/frite): refuse an embedded newline at the
    # sink itself. Identity fields are already allowlisted up front, but non-identity
    # sed replacements (e.g. ROOT_PASS / MEDIA_MOUNT) bypass those gates — a newline
    # here would terminate the `sed s|..|..|` command and inject a further sed command.
    case "${s}" in
        *$'\n'*) err "sed replacement contains a newline (refusing to render): '${1}'"; exit 1 ;;
    esac
    printf '%s' "${s}"
}

# Drop-in brand profile (sourced before CLI; CLI overrides). Auto-detect ./brand.conf.
for ((_i = 1; _i <= $#; _i++)); do
    case "${!_i}" in -C|--config) _j=$((_i + 1)); CONFIG_FILE="${!_j}" ;; esac
done
if [ -z "${CONFIG_FILE}" ] && [ -f "$(pwd)/brand.conf" ]; then CONFIG_FILE="$(pwd)/brand.conf"; fi
if [ -n "${CONFIG_FILE}" ]; then
    [ -f "${CONFIG_FILE}" ] || { err "config file not found: ${CONFIG_FILE}"; exit 1; }
    # shellcheck disable=SC1090
    . "${CONFIG_FILE}"; info "Loaded brand profile: ${CONFIG_FILE}"
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--work-dir) WORK_DIR="$2"; shift 2 ;;
        --build-subdir) BUILD_SUBDIR="$2"; shift 2 ;;
        -j|--jobs) JOBS="$2"; shift 2 ;;
        -v|--version) REL_VERSION="$2"; shift 2 ;;
        -r|--role) ROLE="$2"; shift 2 ;;
        # ── Client (person-device) image flags (FD-08); see docs/CLIENT-IMAGES.md ──
        --person-role) PERSON_ROLE="$2"; shift 2 ;;   # user|mod|admin|superadmin
        --domains) DOMAINS="$2"; shift 2 ;;           # first = primary domain
        --desktop) DESKTOP="$2"; DESKTOP_SET=true; shift 2 ;;   # thin|full (explicit)
        -H|--hostname) HOSTNAME="$2"; HOSTNAME_SET=true; shift 2 ;;
        -T|--timezone) TIMEZONE="$2"; shift 2 ;;
        -C|--config) CONFIG_FILE="$2"; shift 2 ;;
        --env) ENV="$2"; shift 2 ;;
        --release-tag) RELEASE_TAG="$2"; shift 2 ;;
        --cluster-domain|--domain) CLUSTER_DOMAIN="$2"; shift 2 ;;
        --superdomain) SUPERDOMAIN="$2"; shift 2 ;;
        --release-state)      RELEASE_STATE="$2";      shift 2 ;;
        --brand) BRAND="$2"; shift 2 ;;
        --brand-title) BRAND_TITLE="$2"; shift 2 ;;
        --org) ORG="$2"; shift 2 ;;
        --games-domain) GAMES_DOMAIN="$2"; shift 2 ;;
        --optional-services) OPTIONAL_SERVICES="$2"; shift 2 ;;
        --all-services)      OPTIONAL_SERVICES="all"; shift   ;;
        --exclude-services)  EXCLUDE_SERVICES="$2";   shift 2 ;;
        # Managed backing service (repeatable): --managed-service id=endpoint APPENDS
        # to MANAGED_SERVICES. Point one in-mesh datastore at a hosted cloud endpoint
        # (see specs/cluster/backing-services.yaml + docs/MANAGED-SERVICES.md).
        --managed-service)   MANAGED_SERVICES="${MANAGED_SERVICES:+${MANAGED_SERVICES} }$2"; shift 2 ;;
        -u|--user) DEFAULT_USER="$2"; shift 2 ;;
        --user-password) DEFAULT_USER_PASS="$2"; shift 2 ;;
        --root-password) ROOT_PASS="$2"; shift 2 ;;
        --headscale-version) HEADSCALE_VERSION="$2"; shift 2 ;;
        --tailscale-version) TAILSCALE_VERSION="$2"; shift 2 ;;
        --seed-url) SEED_STAGE3_URL="$2"; shift 2 ;;
        --enable-wifi) ENABLE_WIFI=true; shift ;;
        --enable-bluetooth) ENABLE_BLUETOOTH=true; shift ;;
        --permit-root-login) PERMIT_ROOT_LOGIN="$2"; shift 2 ;;
        --enable-games) ENABLE_GAMES=true; shift ;;
        --with-edge-ai) WANT_EDGE_AI=true; shift ;;
        --no-edge-ai) WANT_EDGE_AI=false; shift ;;
        --edge-ai-runtime) EDGE_AI_RUNTIME="$2"; shift 2 ;;
        --edge-ai-models) EDGE_AI_MODELS="$2"; shift 2 ;;
        --edge-ai-model-default) EDGE_AI_MODEL_DEFAULT="$2"; shift 2 ;;
        --with-edge-ai-analysis) WANT_EDGE_AI_ANALYSIS=true; shift ;;
        # edge-ai-tts (VN voice synthesis) — CPU-only, self-contained (NO edge-ai
        # dependency). Independent tri-state, unlike --with-edge-ai-analysis's fold.
        --with-edge-ai-tts) WANT_EDGE_AI_TTS=true; shift ;;
        --no-edge-ai-tts) WANT_EDGE_AI_TTS=false; shift ;;
        # Character Studio (VN) frontend remote — OPTIONAL service (DEFAULT-OFF, admin
        # gate). --with-character-studio folds 'character-studio' into OPTIONAL_SERVICES;
        # a CLIENT/standalone desktop is not a cluster member, so it is a no-op there.
        --with-character-studio) WANT_CHARACTER_STUDIO=true; shift ;;
        --no-character-studio) WANT_CHARACTER_STUDIO=false; shift ;;
        # Character Forge (3D) — OPTIONAL multi-app slug (DEFAULT-OFF, admin gate):
        # BFF db + BFF api + UI remote. --with-character-forge folds 'character-forge'
        # into OPTIONAL_SERVICES; no-op on a CLIENT/standalone desktop (not a cluster
        # member). See docs/XR-CHAT.md.
        --with-character-forge) WANT_CHARACTER_FORGE=true; shift ;;
        --no-character-forge) WANT_CHARACTER_FORGE=false; shift ;;
        # Tor v3 onion (hidden) service — a NODE service (DEFAULT-OFF) that exposes the
        # in-cluster fe-gateway as a .onion. Opt-in only; no-op on CLIENT/standalone.
        --with-tor) WANT_TOR=true; shift ;;
        --no-tor) WANT_TOR=false; shift ;;
        # Mesh-node identity provider (I6) — casdoor DEFAULT = zero change; external
        # providers validated fail-closed right after parsing (see _validate_idp).
        --idp)           IDP="$2";           shift 2 ;;
        --idp-issuer)    IDP_ISSUER="$2";    shift 2 ;;
        --idp-client-id) IDP_CLIENT_ID="$2"; shift 2 ;;
        --idp-jwks)      IDP_JWKS="$2";      shift 2 ;;
        --skip-mesh) SKIP_MESH=true; MESH_FORCED=off; shift ;;
        --skip-tailscale) SKIP_TAILSCALE=true; shift ;;
        # Composable mesh toggle (wins over a role's default; e.g. force the tailnet
        # agent onto a standalone desktop, or strip it off a client image).
        --with-tailscale|--with-mesh) SKIP_MESH=false; SKIP_TAILSCALE=false; MESH_FORCED=on; shift ;;
        --no-tailscale|--no-mesh) SKIP_MESH=true; MESH_FORCED=off; shift ;;
        --skip-kernel) SKIP_KERNEL=true; shift ;;
        --skip-clean) SKIP_CLEAN=true; shift ;;
        # ── Artifact selection ──
        --img) BUILD_IMG=true; shift ;;
        --no-img) BUILD_IMG=false; shift ;;
        --img-size) ROOT_MiB="$2"; IMG_SIZE_SET=true; shift 2 ;;
        --grow)     GROW_POLICY="$2"; shift 2 ;;
        --no-grow)  GROW_POLICY="none"; shift ;;
        --compress) COMPRESS_IMG=true; shift ;;
        --live-iso) LIVE_ISO=true; shift ;;
        --installer-iso) INSTALLER_ISO=true; shift ;;
        --tar) BUILD_TAR=true; shift ;;
        --no-tar) BUILD_TAR=false; shift ;;
        # --no-live-iso cleanly disables the (now-default) live ISO. It does NOT
        # imply the installer ISO — pass --installer-iso explicitly for that.
        --no-live-iso) LIVE_ISO=false; shift ;;
        # Legacy alias: --skip-iso meant "stage4 only". The .img is now the default
        # deliverable; this simply ensures no ISO is built (already the default).
        --skip-iso|--no-iso) LIVE_ISO=false; INSTALLER_ISO=false; shift ;;
        --resume) RESUME=true; shift ;;
        # User package deltas (validated + mandatory-floor-checked below). x86 has
        # no -p/--extra-packages; --packages-add is the add spelling here.
        --packages-add) PACKAGES_ADD="$2"; shift 2 ;;
        --packages-drop) PACKAGES_DROP="$2"; shift 2 ;;
        --print-plan) PRINT_PLAN=true; shift ;;
        # ── STANDALONE hardened desktop (no mesh / no SSO / local login) ──
        --standalone) STANDALONE=true; shift ;;
        # ── UNAFFILIATED plain desktop (standalone + zero HugMesh affiliation) ──
        --unaffiliated) UNAFFILIATED=true; shift ;;
        --skip-sso) SKIP_SSO=true; SSO_FORCED=off; shift ;;
        # Composable SSO toggle (wins over a role's default).
        --with-sso) SKIP_SSO=false; SSO_FORCED=on; shift ;;
        --no-sso) SKIP_SSO=true; SSO_FORCED=off; shift ;;
        # ── Home directory: mode + per-user ecryptfs + dockerized stack code ──
        --home-mode) HOME_MODE="$2"; shift 2 ;;
        --home-device) HOME_DEVICE="$2"; shift 2 ;;
        --home-backup) HOME_BACKUP="$2"; shift 2 ;;
        --home-encrypted) HOME_ENCRYPTED=true; shift ;;
        --home-seed-code) HOME_SEED_CODE="$2"; shift 2 ;;
        --home-seed-code-from) HOME_SEED_CODE_FROM="$2"; shift 2 ;;
        # Reuse a Gentoo distfiles cache from an attached/mounted drive (skip re-downloads).
        --distdir) DISTDIR_SRC="$2"; shift 2 ;;
        # Shared build-asset root (seed cache + fleet distfiles); opt out entirely.
        --shared-assets) SHARED_ASSETS_DIR="$2"; shift 2 ;;
        --no-shared-assets) SHARED_ASSETS_ENABLED=false; shift ;;
        --no-kernel-cache) KERNEL_CACHE_ENABLED=false; shift ;;
        # PREBUILD the binpkg pool then stop before image assembly (shared-binpkg).
        --packages-only) PACKAGES_ONLY=true; shift ;;
        # Accept an image whose requested package set did not fully merge (the
        # completeness gate warns instead of failing). See ALLOW_MISSING_PACKAGES.
        --allow-missing-packages) ALLOW_MISSING_PACKAGES=true; shift ;;
        # Skip the read-only --pretend plan preview (see EMERGE_PLAN_ENABLED).
        --no-emerge-plan) EMERGE_PLAN_ENABLED=false; shift ;;
        # Live ISO: add a "copy to RAM (removable)" boot path so the stick can be pulled.
        --live-toram) LIVE_TORAM=true; shift ;;
        --no-live-toram) LIVE_TORAM=false; shift ;;
        # Installer front-ends + cached/uncached + source-bundle.
        --installer-ui) INSTALLER_UI="$2"; shift 2 ;;
        --cached)   ISO_CACHED=true; shift ;;
        --uncached) ISO_CACHED=false; shift ;;
        --bundle-source)    BUNDLE_SOURCE=true; shift ;;
        --no-bundle-source) BUNDLE_SOURCE=false; shift ;;
        # ── Desktop branding (any desktop image; composable) ──
        --theme)            BRANDING_THEME="$2"; shift 2 ;;
        --branding-dir)     BRANDING_DIR="$2"; shift 2 ;;
        --wallpaper)        BRAND_WALLPAPER="$2"; shift 2 ;;
        --grub-background)  BRAND_GRUB_BG="$2"; shift 2 ;;
        --grub-theme)       BRAND_GRUB_THEME="$2"; shift 2 ;;
        --login-background) BRAND_LOGIN_BG="$2"; shift 2 ;;
        --brand-logo)       BRAND_LOGO="$2"; shift 2 ;;
        --accent-color)     BRAND_ACCENT="$2"; shift 2 ;;
        --color-scheme)     BRAND_COLOR_SCHEME="$2"; shift 2 ;;
        --brand-locked)     BRAND_LOCKED=true; shift ;;
        # ── Egress VPN (NetworkManager) ──
        --egress-vpn)        EGRESS_VPN_FILE="$2"; shift 2 ;;
        --egress-vpn-locked) EGRESS_VPN_LOCKED=true; shift ;;
        # ── Monolithic kernel (built-in vs modules) ──
        --kernel-builtin)    KERNEL_BUILTIN=true; shift ;;
        # ── Network/host security stack ──
        --proxy-stack)       PROXY_STACK=true; shift ;;
        --no-proxy-stack)    PROXY_STACK=false; shift ;;
        --snort)             SNORT_IDS=true; shift ;;
        --no-snort)          SNORT_IDS=false; shift ;;
        --with-aide)         WANT_AIDE=true; shift ;;
        --no-aide)           WANT_AIDE=false; shift ;;
        --capable) CAPABLE=true; shift ;;
        --local-user) LOCAL_USER="$2"; shift 2 ;;
        --local-pass|--local-user-password) LOCAL_USER_PASS="$2"; shift 2 ;;
        # ── GPU driver matrix (all common cards; free default) ──
        --gpu-driver) GPU_DRIVER="$2"; shift 2 ;;
        --nvidia) GPU_DRIVER="nvidia"; shift ;;                           # alias: proprietary NVIDIA
        --nvidia-driver) case "$2" in                                    # back-compat (open|proprietary)
                             open) GPU_DRIVER="nvidia-free" ;;
                             proprietary) GPU_DRIVER="nvidia" ;;
                             *) GPU_DRIVER="$2" ;;
                         esac; shift 2 ;;
        --nvidia-cuda) NVIDIA_CUDA=true; shift ;;
        # ── Root LUKS2 full-disk encryption (installed system) ──
        --encrypt-root) ENCRYPT_ROOT=true; shift ;;
        --luks-pass|--root-unlock-pass) LUKS_PASS="$2"; shift 2 ;;
        --unlock-keyfile) UNLOCK_KEYFILE="$2"; shift 2 ;;   # boot|login
        --unlock-yubikey) UNLOCK_YUBIKEY="$2"; shift 2 ;;   # boot|login
        # ── External media data device (Vaults + Steam) ──
        --media-data) MEDIA_DATA=true; MEDIA_DATA_FORCED=on; shift ;;
        --no-media-data) MEDIA_DATA=false; MEDIA_DATA_FORCED=off; shift ;;
        --media-label) MEDIA_LABEL="$2"; shift 2 ;;
        --steam) STEAM_DELIVERY="$2"; shift 2 ;;            # flatpak|native|none
        --with-sunshine) WANT_SUNSHINE=true; shift ;;       # thin-desktop stream host (client desktops)
        --no-sunshine) WANT_SUNSHINE=false; shift ;;
        --no-vaults) VAULTS_ENABLED=false; shift ;;
        # ── Seed-from-running-system + home archive ──
        --seed-packages-from) SEED_PACKAGES_FROM="$2"; shift 2 ;;
        --include-home-archive) INCLUDE_HOME_ARCHIVE="$2"; shift 2 ;;
        # ── Secure Boot + KEYS USB ──
        --secure-boot) SECURE_BOOT=true; shift ;;
        --no-secure-boot) SECURE_BOOT=false; shift ;;
        --keys-usb) KEYS_USB="$2"; shift 2 ;;
        --secureboot-key) SECUREBOOT_KEY="$2"; shift 2 ;;
        --secureboot-cert) SECUREBOOT_CERT="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) err "Unknown option: $1"; usage 1 ;;
    esac
done

# Comma tolerance: accept "akkoma,tuwunel" (the CSV spelling GUIs/configs tend to
# emit) as well as the native space-separated list — normalized HERE, right after
# arg parse, so every downstream word-split (`_opt_selected`, the games/edge-ai
# `case " ${OPTIONAL_SERVICES} "` folds) sees clean slugs. Mirrors DOMAINS.
OPTIONAL_SERVICES="${OPTIONAL_SERVICES//,/ }"

# FULL-SET sentinel: OPTIONAL_SERVICES=all (or --all-services, which sets the same
# token) expands to EVERY user-level slug. Done HERE — after arg parse, before the
# games/edge-ai/tor/character-studio opt-in folds and BEFORE EXCLUDE_SERVICES
# subtracts — so `all` is just a positive allow-list of the whole set and
# EXCLUDE_SERVICES still removes from it (e.g. OPTIONAL_SERVICES=all +
# EXCLUDE_SERVICES="games owncast" => everything but games/owncast). A bare `all`
# anywhere in the list expands the whole token to the full set (operators write
# `all`, not `all akkoma`). Mirrors build-rpi5-stage4.sh.
case " ${OPTIONAL_SERVICES} " in
    *" all "*)
        OPTIONAL_SERVICES="${USER_LEVEL_SERVICES}"
        info "OPTIONAL_SERVICES: 'all' sentinel expanded to every user-level slug: ${OPTIONAL_SERVICES}"
        ;;
esac

# Games is OPT-IN (off by default): fold it into the selection when --enable-games
# / ENABLE_GAMES=true. Idempotent — a no-op when 'games' is already listed (e.g. via
# --optional-services). When games stays unselected, gate_optional_services() prunes
# the games apps + the games.<domain> subdomain extrahost from the baked tree.
if [ "${ENABLE_GAMES}" = "true" ]; then
    case " ${OPTIONAL_SERVICES} " in
        *" games "*) ;;
        *) OPTIONAL_SERVICES="${OPTIONAL_SERVICES} games" ;;
    esac
fi

# Edge-AI service selection: the edge_ai ROLE auto-selects 'edge-ai' (unless
# --no-edge-ai); --with-edge-ai folds it onto any GPU k8s role. Idempotent. When
# unselected, gate_optional_services() prunes the edge-ai app/manifests/route/rows.
EDGE_AI_WANT=false
${EDGE_AI} && [ "${WANT_EDGE_AI}" != "false" ] && EDGE_AI_WANT=true
[ "${WANT_EDGE_AI}" = "true" ] && EDGE_AI_WANT=true
if ${EDGE_AI_WANT} && ${ROLE_CLIENT}; then
    warn "--with-edge-ai on a CLIENT/standalone role has no effect (no cluster tree); the edge-ai service is a k8s NODE service."
    EDGE_AI_WANT=false
fi
if ${EDGE_AI_WANT}; then
    case " ${OPTIONAL_SERVICES} " in
        *" edge-ai "*) ;;
        *) OPTIONAL_SERVICES="${OPTIONAL_SERVICES} edge-ai" ;;
    esac
fi

# Tor NODE service selection: --with-tor folds 'tor' onto any k8s role (idempotent).
# Never auto-selected — purely opt-in via --with-tor / OPTIONAL_SERVICES. A
# CLIENT/standalone desktop is not a cluster member, so it is a no-op there (and the
# SVCS/PKGS gate below also guards on !ROLE_CLIENT).
WANT_TOR="${WANT_TOR:-}"
if [ "${WANT_TOR}" = "true" ] && ${ROLE_CLIENT}; then
    warn "--with-tor on a CLIENT/standalone role has no effect (no cluster tree); the Tor onion service is a k8s NODE service."
    WANT_TOR=false
fi
if [ "${WANT_TOR}" = "true" ]; then
    case " ${OPTIONAL_SERVICES} " in
        *" tor "*) ;;
        *) OPTIONAL_SERVICES="${OPTIONAL_SERVICES} tor" ;;
    esac
fi

# Character Studio (VN) selection: --with-character-studio folds 'character-studio'
# into OPTIONAL_SERVICES (idempotent). DEFAULT-OFF; never auto-selected. A
# CLIENT/standalone desktop is not a cluster member, so it is a no-op there (the
# gate prunes the slug anyway when the cluster tree is absent).
WANT_CHARACTER_STUDIO="${WANT_CHARACTER_STUDIO:-}"
if [ "${WANT_CHARACTER_STUDIO}" = "true" ] && ${ROLE_CLIENT}; then
    warn "--with-character-studio on a CLIENT/standalone role has no effect (no cluster tree); Character Studio is a frontend cluster service."
    WANT_CHARACTER_STUDIO=false
fi
if [ "${WANT_CHARACTER_STUDIO}" = "true" ]; then
    case " ${OPTIONAL_SERVICES} " in
        *" character-studio "*) ;;
        *) OPTIONAL_SERVICES="${OPTIONAL_SERVICES} character-studio" ;;
    esac
fi

# Character Forge (3D) selection: --with-character-forge folds 'character-forge'
# into OPTIONAL_SERVICES (idempotent). DEFAULT-OFF; never auto-selected. A
# CLIENT/standalone desktop is not a cluster member, so it is a no-op there (the
# gate prunes the slug anyway when the cluster tree is absent).
WANT_CHARACTER_FORGE="${WANT_CHARACTER_FORGE:-}"
if [ "${WANT_CHARACTER_FORGE}" = "true" ] && ${ROLE_CLIENT}; then
    warn "--with-character-forge on a CLIENT/standalone role has no effect (no cluster tree); Character Forge is a cluster service."
    WANT_CHARACTER_FORGE=false
fi
if [ "${WANT_CHARACTER_FORGE}" = "true" ]; then
    case " ${OPTIONAL_SERVICES} " in
        *" character-forge "*) ;;
        *) OPTIONAL_SERVICES="${OPTIONAL_SERVICES} character-forge" ;;
    esac
fi

# --with-edge-ai-analysis folds the analysis API (task verdicts to the mesh) AND its
# edge-ai dependency. The container image is a SEPARATE build artifact — opt-in only.
if [ "${WANT_EDGE_AI_ANALYSIS}" = "true" ]; then
    case " ${OPTIONAL_SERVICES} " in *" edge-ai "*) ;; *) OPTIONAL_SERVICES="${OPTIONAL_SERVICES} edge-ai" ;; esac
    case " ${OPTIONAL_SERVICES} " in *" edge-ai-analysis "*) ;; *) OPTIONAL_SERVICES="${OPTIONAL_SERVICES} edge-ai-analysis" ;; esac
fi
# Dependency guard: edge-ai-analysis is useless without the edge-ai model server. If it
# was selected without edge-ai, drop it (its gate prune then runs) — never ship a wrapper
# with no upstream.
case " ${OPTIONAL_SERVICES} " in
    *" edge-ai-analysis "*)
        case " ${OPTIONAL_SERVICES} " in
            *" edge-ai "*) ;;
            *) OPTIONAL_SERVICES="${OPTIONAL_SERVICES//edge-ai-analysis/}"
               warn "edge-ai-analysis requires edge-ai — dropping it (no model server selected)" ;;
        esac ;;
esac

# edge-ai-tts (VN voice synthesis) selection: --with-edge-ai-tts folds 'edge-ai-tts'
# into OPTIONAL_SERVICES (idempotent). DEFAULT-OFF; never auto-selected. UNLIKE
# edge-ai-analysis, it has NO edge-ai dependency (CPU-only, self-contained) — no
# fold-in of 'edge-ai' and no dependency-drop guard. A CLIENT/standalone desktop is
# not a cluster member, so it is a no-op there (the gate prunes the slug anyway when
# the cluster tree is absent).
WANT_EDGE_AI_TTS="${WANT_EDGE_AI_TTS:-}"
if [ "${WANT_EDGE_AI_TTS}" = "true" ] && ${ROLE_CLIENT}; then
    warn "--with-edge-ai-tts on a CLIENT/standalone role has no effect (no cluster tree); edge-ai-tts is a cluster inference service."
    WANT_EDGE_AI_TTS=false
fi
if [ "${WANT_EDGE_AI_TTS}" = "true" ]; then
    case " ${OPTIONAL_SERVICES} " in
        *" edge-ai-tts "*) ;;
        *) OPTIONAL_SERVICES="${OPTIONAL_SERVICES} edge-ai-tts" ;;
    esac
fi

# EXCLUDE_SERVICES — apply the SUBTRACTIVE build-time exclusion LAST, so a slug
# listed here is force-OFF regardless of how it became selected (built-in default,
# brand.conf, --optional-services, the 'all' sentinel, or any opt-in fold above).
# gate_optional_services then prunes every excluded slug's Application/manifests/
# routes/rows from the baked tree and _opt_render_installed_services renders it
# installed:"false" in BOTH the ConfigMap and the 13a ApplicationSet, so the rest
# of the stack degrades gracefully. A slug may legitimately appear in
# EXCLUDE_SERVICES even if it was never selected (idempotent no-op).
# Whitespace/comma separated. Mirrors build-rpi5-stage4.sh.
if [ -n "${EXCLUDE_SERVICES//[[:space:],]/}" ]; then
    _excl_x=""
    for _x in ${EXCLUDE_SERVICES//,/ }; do
        _kept=""
        for _s in ${OPTIONAL_SERVICES}; do
            [ "${_s}" = "${_x}" ] || _kept="${_kept} ${_s}"
        done
        OPTIONAL_SERVICES="${_kept# }"
        _excl_x="${_excl_x} ${_x}"
    done
    info "OPTIONAL_SERVICES: EXCLUDE_SERVICES removed:${_excl_x} (final selection: ${OPTIONAL_SERVICES:-none})"
    unset _excl_x _x _s _kept
fi

# ── Validate role; derive GPU, hostname, node labels and init/join intent ──
# Node labels/taints are applied at RUNTIME by provision.sh from the KEYS stick;
# the image only bakes: the /etc/hugmesh/role marker, the OpenRC service set,
# the GPU stack (or not), and headscale-in-runlevel. The label/init hints below
# are recorded for the build summary + gen-provision-keys.sh guidance.
case "${ROLE}" in
    host) ROLE="be+gpu" ;;   # legacy alias
esac
ROLE_HEADSCALE=false         # headscale runs in the runlevel (pki/omnibus)
ROLE_K8S="worker"            # kubeadm join vs init vs single-node
ROLE_LABELS=""               # informational: node labels the KEYS stick should set
ROLE_CLIENT=false            # true for person-device desktop roles (laptop/chromebook/desktop)
case "${ROLE}" in
    pki)
        GPU=false; ROLE_HEADSCALE=true; ROLE_K8S="control-plane"
        ROLE_LABELS="hugmesh.net/pki=true (+ role=pki via provision.sh)"
        [ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-pki" ;;
    be)
        GPU=false; ROLE_K8S="worker"
        ROLE_LABELS="hugmesh.net/backend=true"
        [ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-be" ;;
    fe)
        GPU=false; ROLE_K8S="worker"
        ROLE_LABELS="hugmesh.net/frontend=true"
        [ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-fe" ;;
    be+gpu)
        GPU=true; ROLE_K8S="worker"
        ROLE_LABELS="hugmesh.net/backend=true,hugmesh.net/compute=gpu"
        # Keep the legacy 'host' hostname for back-compat with flashers/launchers.
        [ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-host" ;;
    omnibus)
        GPU=true; ROLE_HEADSCALE=true; ROLE_K8S="single-node"
        ROLE_LABELS="hugmesh.net/pki=true,hugmesh.net/backend=true,hugmesh.net/frontend=true,hugmesh.net/compute=gpu"
        [ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-omnibus" ;;
    # ── EDGE-AI (GPU inference) NODE — a be+gpu worker whose PURPOSE is serving an
    # AI model API to the mesh. Defaults the PROPRIETARY NVIDIA driver + CUDA, bakes
    # the nvidia container runtime + nvidia-container-toolkit, and AUTO-SELECTS the
    # edge-ai cluster service (Ollama, OpenAI-compatible /v1). Same machinery on x86
    # (RTX host) and the Jetson Orin Nano (arm64 — see specs-jetson). Other mesh
    # nodes consume the API over k8s (ClusterIP) AND the tailnet (be-gateway route).
    edge_ai|edge-ai)
        GPU=true; ROLE_K8S="worker"; EDGE_AI=true
        [ -z "${GPU_DRIVER}" ] && GPU_DRIVER="nvidia"   # inference wants the proprietary blob (CUDA)
        ROLE_LABELS="hugmesh.net/backend=true,hugmesh.net/compute=gpu,hugmesh.net/edge-ai=true"
        [ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-edge-ai" ;;
    # ── CLIENT (person-device) roles — see docs/CLIENT-IMAGES.md (ADR-16/FD-04..08).
    # These are DESKTOPS that join the tailnet + run the UI, NOT k8s nodes: no
    # headscale/containerd/kubelet, GPU on for DRI, ROLE_K8S=none, person-role+domain
    # tied. chromebook == laptop image targeting coreboot-UEFI (ADR-16; quirks land in
    # the desktop kernel fragment). 'desktop' is the opt-in full/thick variant.
    laptop|chromebook)
        GPU=true; ROLE_CLIENT=true; ROLE_K8S="none"; ROLE_HEADSCALE=false
        [ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-${ROLE}" ;;
    desktop)
        GPU=true; ROLE_CLIENT=true; ROLE_K8S="none"; ROLE_HEADSCALE=false
        # 'desktop' role DEFAULTS to the full/thick weight — but only when the operator
        # did not pass --desktop at all. The old test ([ thin ] && full) could not tell
        # "said nothing" from "explicitly said thin" and silently upgraded an explicit
        # --desktop thin to full — the thin-weight desktop image was unbuildable.
        ${DESKTOP_SET} || DESKTOP="full"
        [ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-desktop" ;;
    # ── STANDALONE hardened desktop roles — self-contained personal workstations.
    # Reuse the CLIENT desktop machinery (ROLE_CLIENT=true → Xorg/lightdm/desktop
    # stack, kernel desktop fragment, sizing, GPU/DRI) but preset the STANDALONE
    # posture: NO mesh (headscale/tailscale), NO Casdoor/OIDC SSO, NO k8s/cluster
    # tree — a NORMAL LOCAL USER logs in with a build-set password. The GPU driver
    # defaults to FREE (open) drivers (--gpu-driver all-free, which uses nouveau for
    # NVIDIA); pick --gpu-driver nvidia for the proprietary blob, or amd-*/intel-*.
    # thick = the most-capable Plasma set.
    standalone-thin)
        GPU=true; ROLE_CLIENT=true; ROLE_K8S="none"; ROLE_HEADSCALE=false
        # The weight is IN THE ROLE NAME — a contradictory explicit --desktop is a
        # hard error (naming both sides), never a silent override; an agreeing
        # explicit flag is accepted as the no-op it is.
        if ${DESKTOP_SET} && [ "${DESKTOP}" != "thin" ]; then
            err "--desktop ${DESKTOP} contradicts --role standalone-thin (the role name pins the thin weight) — drop --desktop, or pick --role standalone-thick for the full weight"; exit 1
        fi
        STANDALONE=true; DESKTOP="thin"
        [ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-standalone-thin" ;;
    standalone-thick|standalone-full)
        GPU=true; ROLE_CLIENT=true; ROLE_K8S="none"; ROLE_HEADSCALE=false
        if ${DESKTOP_SET} && [ "${DESKTOP}" != "full" ]; then
            err "--desktop ${DESKTOP} contradicts --role ${ROLE} (the role name pins the full weight) — drop --desktop, or pick --role standalone-thin for the thin weight"; exit 1
        fi
        STANDALONE=true; DESKTOP="full"; CAPABLE=true
        [ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-standalone" ;;
    # ── UNAFFILIATED plain desktop — standalone-thick weight with ZERO HugMesh
    # affiliation (see the UNAFFILIATED declaration + fold below). The hostname
    # default is assigned in the fold, AFTER the brand identity is neutralized.
    standalone-unaffiliated)
        GPU=true; ROLE_CLIENT=true; ROLE_K8S="none"; ROLE_HEADSCALE=false
        # standalone-thick weight by definition (see the UNAFFILIATED fold below) —
        # same contradiction rule as the named-weight standalone roles above.
        if ${DESKTOP_SET} && [ "${DESKTOP}" != "full" ]; then
            err "--desktop ${DESKTOP} contradicts --role standalone-unaffiliated (this role IS the standalone-thick/full weight) — drop --desktop"; exit 1
        fi
        STANDALONE=true; DESKTOP="full"; CAPABLE=true
        UNAFFILIATED=true ;;
    *)
        err "--role must be one of: pki | be | fe | be+gpu | edge_ai | omnibus  (host = be+gpu alias)  |  laptop | chromebook | desktop  |  standalone-thin | standalone-thick | standalone-unaffiliated  (client devices)"
        exit 1 ;;
esac

# ── UNAFFILIATED plain desktop (composable: --unaffiliated onto any client/
# standalone role, or the standalone-unaffiliated role arm above). Runs BEFORE
# the STANDALONE fold so the STANDALONE=true it forces is folded normally.
# Contract: the produced image carries NO HugMesh (or any other brand)
# affiliation — so every flag that would bake a brand identity, brand assets,
# HugMesh source, or platform machinery into the image is a HARD CONFLICT,
# not a silent override. What remains: stock Gentoo + the hardened desktop
# stack + the (neutral-named) installer/FDE/home machinery. ──────────────────
if ${UNAFFILIATED}; then
    ${ROLE_CLIENT} || { err "--unaffiliated composes onto desktop/client roles only (got --role ${ROLE} — a cluster node is HugMesh platform machinery by definition)"; exit 1; }
    STANDALONE=true
    # Brand identity flags conflict (a brand IS an affiliation — including a custom one).
    if [ "${BRAND}" != "hugmesh" ] || [ "${BRAND_TITLE}" != "HugMesh Systems" ] || [ "${ORG}" != "hugmesh" ]; then
        err "--unaffiliated builds carry no brand identity: drop --brand/--brand-title/--org (and any --config brand profile)"; exit 1
    fi
    # Branding-asset flags conflict (nothing to theme against).
    if [ -n "${BRANDING_THEME}" ] || [ -n "${BRANDING_DIR}" ] || [ -n "${BRAND_WALLPAPER}" ] \
       || [ -n "${BRAND_GRUB_BG}" ] || [ -n "${BRAND_GRUB_THEME}" ] || [ -n "${BRAND_LOGIN_BG}" ] \
       || [ -n "${BRAND_LOGO}" ] || [ -n "${BRAND_ACCENT}" ] || [ -n "${BRAND_COLOR_SCHEME}" ] || ${BRAND_LOCKED}; then
        err "--unaffiliated conflicts with branding flags (--theme/--branding-dir/--wallpaper/--grub-background/--grub-theme/--login-background/--brand-logo/--accent-color/--color-scheme/--brand-locked)"; exit 1
    fi
    # Platform-machinery flags conflict: bundled generator source, the dockerized
    # HugMesh stack seed, the mesh/SSO agents, and person-device identity all
    # tie the image back to the platform.
    [ "${BUNDLE_SOURCE}" = true ] && { err "--unaffiliated conflicts with --bundle-source (bundles the HugMesh generator source)"; exit 1; }
    [ "${HOME_SEED_CODE}" != none ] && { err "--unaffiliated conflicts with --home-seed-code (seeds the HugMesh stack into the home)"; exit 1; }
    [ "${MESH_FORCED}" = on ] && { err "--unaffiliated conflicts with --with-tailscale (the tailnet is HugMesh platform machinery)"; exit 1; }
    [ "${SSO_FORCED}" = on ] && { err "--unaffiliated conflicts with --with-sso (Casdoor SSO is HugMesh platform machinery)"; exit 1; }
    { [ -n "${PERSON_ROLE}" ] || [ -n "${DOMAINS}" ]; } && { err "--unaffiliated conflicts with --person-role/--domains (person-device identity is platform machinery)"; exit 1; }
    BUNDLE_SOURCE=false
    # Neutral identity: every downstream sink (GRUB titles, ISO volids, UKI name,
    # installer text, artifact filenames, hostname) derives from BRAND/BRAND_TITLE,
    # so forcing them neutral here neutralizes the whole chain.
    BRAND="gentoo"
    BRAND_TITLE="Gentoo Linux"
    ORG="gentoo"
    # Override any BRAND-derived role-default hostname (e.g. 'hugmesh-desktop'
    # from the desktop role arm) — only an explicit -H/--hostname survives.
    ${HOSTNAME_SET} || HOSTNAME="gentoo-desktop"
    # Plain desktop: the Steam/Vaults media-data machinery is HugMesh-named
    # tooling — default it OFF (an explicit --media-data keeps it, neutral-named).
    [ "${MEDIA_DATA_FORCED}" = on ] || MEDIA_DATA=false
    info "UNAFFILIATED plain desktop: no brand identity, no hugmesh-* tooling, no bundled source, no k8s/mesh payload"
fi

# ── STANDALONE posture (composable: --standalone onto any client role, or the
# standalone-* role arms above). A standalone desktop is self-contained: it never
# bakes the mesh agents (headscale/tailscale), the Casdoor/OIDC SSO desktop login,
# or the k8s/ArgoCD cluster tree, and logs a normal local user in with a password
# set at build time. It defaults the installed-system FDE + the media-data device
# detection ON. ──────────────────────────────────────────────────────────────
if ${STANDALONE}; then
    ROLE_CLIENT=true            # reuse all the desktop-stack machinery
    ROLE_HEADSCALE=false
    ROLE_K8S="none"
    # Default standalone posture is mesh-OFF / SSO-OFF, but an explicit
    # --with-tailscale / --with-sso overrides it (composable: a standalone desktop
    # that still joins the tailnet, or still uses the Casdoor SSO login).
    if [ "${MESH_FORCED}" != on ]; then
        SKIP_MESH=true          # no headscale/tailscale binaries or services
        SKIP_TAILSCALE=true
    fi
    [ "${SSO_FORCED}" = on ] || SKIP_SSO=true   # no Casdoor/OIDC desktop login
    ENCRYPT_ROOT=true           # the INSTALLED system is LUKS2 full-disk encrypted
    INSTALLER_ISO=true          # guarantee the installer artifact (the FDE path)
    [ -z "${LOCAL_USER}" ] && LOCAL_USER="${DEFAULT_USER}"
    info "STANDALONE desktop: no mesh / no SSO / no k8s; local user '${LOCAL_USER}'; LUKS FDE on install; media-data auto-detect=${MEDIA_DATA}"
fi

# ── Boot-chain identifiers (volids / CDLABEL / UKI name / installer cmdline key /
# partition labels / Secure-Boot cert identity + enrollment-cert dirs).
# Historically hardcoded HUGMESH_*/hugmesh.* literals;
# UNAFFILIATED swaps the whole set for neutral equivalents in one place so the
# live-boot CDLABEL always matches its volid and the autostart reads the same
# cmdline key the GRUB entries emit. Non-unaffiliated builds are byte-identical
# to the historical literals (volids are ISO9660-safe: A-Z0-9_, bounded; the FAT
# label is ≤11 chars). SB_ETC_DIR is where the org enrollment cert is staged in
# the sysroot; SB_EFI_VENDOR names the EFI/<vendor>/ dir the same cert is copied
# to on the ESP (.img) and the live ISO — the stager and BOTH boot-media
# consumers resolve these two variables, never their own branching, so the
# enrollment cert always ships on the boot media the user enrolls from. ───────
if ${UNAFFILIATED}; then
    LIVE_VOLID="GENTOO_LIVE";       INSTALL_VOLID="GENTOO_INSTALL"
    UKI_NAME="gentoo.efi";          INSTALL_CMDLINE_KEY="gentoo.install"
    ESP_LABEL="GENTOO_ESP";         ROOT_LABEL="GENTOO_ROOT"
    SB_CERT_O="Gentoo Linux";       SB_CERT_CN="Gentoo Secure Boot"
    SB_ETC_DIR="/etc/gentoo/secureboot";     SB_EFI_VENDOR="gentoo"
else
    LIVE_VOLID="HUGMESH_LIVE";   INSTALL_VOLID="HUGMESH_INSTALL"
    UKI_NAME="hugmesh.efi";      INSTALL_CMDLINE_KEY="hugmesh.install"
    ESP_LABEL="SNAP_ESP";           ROOT_LABEL="SNAP_ROOT"
    SB_CERT_O="HugMesh Systems"; SB_CERT_CN="HugMesh Secure Boot"
    SB_ETC_DIR="/etc/hugmesh/secureboot"; SB_EFI_VENDOR="hugmesh"
fi

# ── Validate + normalize the GPU driver selection (the full vendor matrix) ──
# Default resolves to all-free (open drivers for every vendor — works on any GPU,
# uses the FREE NVIDIA driver nouveau) on a GPU role; 'none' on a non-GPU role.
[ -z "${GPU_DRIVER}" ] && { ${GPU} && GPU_DRIVER="all-free" || GPU_DRIVER="none"; }
case "${GPU_DRIVER}" in
    ati-free)  GPU_DRIVER="amd-free" ;;          # vendor aliases
    ati-pro)   GPU_DRIVER="amd-pro" ;;
    amd|ati)   GPU_DRIVER="amd-free" ;;
    intel)     GPU_DRIVER="intel-free" ;;
esac
case "${GPU_DRIVER}" in
    all-free|nvidia-free|nvidia|amd-free|amd-pro|intel-free|intel-pro|none) ;;
    *) err "--gpu-driver must be: all-free | nvidia-free | nvidia | amd-free | amd-pro | intel-free | intel-pro | none (got '${GPU_DRIVER}')"; exit 1 ;;
esac
# A specific GPU driver is only meaningful on a GPU role (it ships the DRI stack).
if [ "${GPU_DRIVER}" != "none" ] && [ "${GPU_DRIVER}" != "all-free" ] && ! ${GPU}; then
    warn "--gpu-driver ${GPU_DRIVER} on a non-GPU role '${ROLE}' — forcing the GPU stack on."; GPU=true
fi
# --nvidia-cuda needs the proprietary NVIDIA driver. An UNSET driver is IMPLIED
# to nvidia (mirroring the --nvidia alias) so plain "--nvidia-cuda" just works;
# an EXPLICIT non-nvidia driver is a real contradiction and refuses — without
# this, the NVIDIA_PROPRIETARY gate below silently drops the CUDA list and the
# operator gets an image without the toolkit they asked for.
if ${NVIDIA_CUDA}; then
    if [ -z "${GPU_DRIVER}" ]; then
        warn "--nvidia-cuda without --gpu-driver — implying --gpu-driver nvidia (CUDA needs the proprietary driver)"
        GPU_DRIVER="nvidia"
    elif [ "${GPU_DRIVER}" != "nvidia" ]; then
        err "--nvidia-cuda requires --gpu-driver nvidia (the proprietary NVIDIA driver) — got --gpu-driver ${GPU_DRIVER}. Drop --nvidia-cuda, or switch to --gpu-driver nvidia."
        exit 1
    fi
fi
# edge_ai inference node: default CUDA on when on the proprietary NVIDIA driver (the
# inference runtime needs it). Skipped for an AMD/Intel edge node (future ROCm path).
if ${EDGE_AI} && [ "${GPU_DRIVER}" = "nvidia" ]; then NVIDIA_CUDA=true; fi
case "${STEAM_DELIVERY}" in flatpak|native|none) ;; *) err "--steam must be: flatpak | native | none (got '${STEAM_DELIVERY}')"; exit 1 ;; esac
# NATIVE Steam (games-util/steam-launcher from the steam-overlay) is heavy: it
# needs the multilib stage3 + the steam-overlay synced + 32-bit deps. Bake it only
# for a gaming desktop — the standalone variants and the full 'desktop' role — NOT
# the lean mesh laptop/chromebook clients (they still get the /media/Steam symlink
# via media-detect, just no baked native package). Requires the media-data wiring.
STEAM_NATIVE=false
if [ "${STEAM_DELIVERY}" = "native" ] && ${ROLE_CLIENT} && ${MEDIA_DATA} \
   && { ${STANDALONE} || [ "${DESKTOP}" = "full" ]; }; then
    STEAM_NATIVE=true
fi
# Thin-desktop stream host (--with-sunshine): CLIENT desktops WITH a tailnet
# only. Sunshine streams THIS node's desktop session and the fence admits it
# exclusively on the tailscale iface — a server/cluster role has no desktop
# session to stream, and a standalone/unaffiliated/--skip-tailscale desktop
# has no tailnet for the fence to admit. Warn-and-drop (the --with-tor
# client-role convention), never a hard error.
if ${WANT_SUNSHINE} && ! ${ROLE_CLIENT}; then
    warn "--with-sunshine on a non-client role has no effect (Sunshine streams a desktop session; this role has none) — dropping it."
    WANT_SUNSHINE=false
fi
if ${WANT_SUNSHINE} && { ${SKIP_TAILSCALE} || ${UNAFFILIATED}; }; then
    warn "--with-sunshine needs the tailnet (the fence admits stream traffic ONLY on the tailscale iface); this desktop has none (standalone/unaffiliated/--skip-tailscale) — dropping it."
    WANT_SUNSHINE=false
fi
[ -n "${UNLOCK_KEYFILE}" ] && { case "${UNLOCK_KEYFILE}" in boot|login) ;; *) err "--unlock-keyfile must be: boot | login"; exit 1 ;; esac; }
[ -n "${UNLOCK_YUBIKEY}" ] && { case "${UNLOCK_YUBIKEY}" in boot|login) ;; *) err "--unlock-yubikey must be: boot | login"; exit 1 ;; esac; }
[ -n "${SEED_PACKAGES_FROM}" ] && [ ! -f "${SEED_PACKAGES_FROM}" ] && { err "--seed-packages-from: file not found: ${SEED_PACKAGES_FROM}"; exit 1; }
[ -n "${INCLUDE_HOME_ARCHIVE}" ] && [ ! -f "${INCLUDE_HOME_ARCHIVE}" ] && { err "--include-home-archive: file not found: ${INCLUDE_HOME_ARCHIVE}"; exit 1; }
# --encrypt-root produces the encrypted INSTALLED system → it needs the installer ISO.
${ENCRYPT_ROOT} && INSTALLER_ISO=true
# ── Home mode: default to 'archive' when a $HOME tarball was supplied, else 'create'.
[ -z "${HOME_MODE}" ] && { [ -n "${INCLUDE_HOME_ARCHIVE}" ] && HOME_MODE=archive || HOME_MODE=create; }
case "${HOME_MODE}" in create|adopt|archive|restore) ;; *) err "--home-mode must be: create | adopt | archive | restore (got '${HOME_MODE}')"; exit 1 ;; esac
if [ "${HOME_MODE}" = adopt ] && [ -z "${HOME_DEVICE}" ]; then
    err "--home-mode adopt needs --home-device LABEL=…|UUID=…|/dev/… (the existing home partition/USB to mount in place)"; exit 1
fi
if [ "${HOME_MODE}" = archive ] && [ -z "${INCLUDE_HOME_ARCHIVE}" ]; then
    err "--home-mode archive needs --include-home-archive FILE (the $HOME tarball to unpack)"; exit 1
fi
if [ "${HOME_MODE}" = restore ] && [ -z "${HOME_BACKUP}" ]; then
    err "--home-mode restore needs --home-backup FILE|auto (the encrypted full-home backup; auto = detect on an attached USB)"; exit 1
fi
case "${HOME_SEED_CODE}" in none|repos|stack|mesh) ;; *) err "--home-seed-code must be: none | repos | stack | mesh (got '${HOME_SEED_CODE}')"; exit 1 ;; esac
[ -n "${HOME_SEED_CODE_FROM}" ] && [ ! -e "${HOME_SEED_CODE_FROM}" ] && { err "--home-seed-code-from: not found: ${HOME_SEED_CODE_FROM}"; exit 1; }
# Seeding the dockerized stack/mesh implies a container runtime + compose in the image.
WANT_DOCKER=false; [ "${HOME_SEED_CODE}" = stack ] || [ "${HOME_SEED_CODE}" = mesh ] && WANT_DOCKER=true
# Installer front-ends: standalone ships all three (graphical Calamares + ncurses +
# unattended CLI) as boot entries; other roles default to the CLI installer.
[ -z "${INSTALLER_UI}" ] && { ${STANDALONE} && INSTALLER_UI=all || INSTALLER_UI=cli; }
case "${INSTALLER_UI}" in cli|ncurses|calamares|all) ;; *) err "--installer-ui must be: cli | ncurses | calamares | all (got '${INSTALLER_UI}')"; exit 1 ;; esac
WANT_CALAMARES=false; { [ "${INSTALLER_UI}" = calamares ] || [ "${INSTALLER_UI}" = all ]; } && WANT_CALAMARES=true
# Self-hosting appliance: bundle the generator source by default on a standalone.
[ -z "${BUNDLE_SOURCE}" ] && { ${STANDALONE} && BUNDLE_SOURCE=true || BUNDLE_SOURCE=false; }
${WANT_CALAMARES} && info "Installer: graphical Calamares + ncurses + CLI boot entries (--installer-ui=${INSTALLER_UI})"
${ISO_CACHED} && info "ISO: CACHED (embeds binpkg cache for offline rebuild/fast reinstall)"
${BUNDLE_SOURCE} && info "Image: bundling generator source + regenerate helper (self-hosting)"
${HOME_ENCRYPTED} && info "Home: per-user ecryptfs layered on the LUKS2 root (login-password unwrapped)"
[ "${HOME_MODE}" = adopt ] && info "Home: ADOPT existing home on ${HOME_DEVICE} (installer mounts it at /home, never formats it)"
[ "${HOME_SEED_CODE}" != none ] && info "Home: seeding the HugMesh stack code (${HOME_SEED_CODE}) into ~/hugmesh-stack"
# A KEYS USB (--keys-usb DIR) supplies the existing Secure Boot signing key so the
# installed host boots under the key already enrolled in its firmware.
# Remember what the OPERATOR actually passed, before auto-discovery writes to the same two
# variables: the cert-without-key check below must speak about flags that were really given.
SECUREBOOT_CERT_EXPLICIT="${SECUREBOOT_CERT}"
if [ -n "${KEYS_USB}" ]; then
    [ -d "${KEYS_USB}" ] || { err "--keys-usb: directory not found: ${KEYS_USB}"; exit 1; }
    [ -z "${SECUREBOOT_KEY}"  ] && [ -f "${KEYS_USB}/Keys/kernel_key.pem" ] && SECUREBOOT_KEY="${KEYS_USB}/Keys/kernel_key.pem"
    [ -z "${SECUREBOOT_CERT}" ] && [ -f "${KEYS_USB}/Keys/kernel_key.der" ] && SECUREBOOT_CERT="${KEYS_USB}/Keys/kernel_key.der"
    info "KEYS USB: ${KEYS_USB} (Secure Boot key: ${SECUREBOOT_KEY:-<none found>})"
    # The two probes above are INDEPENDENT -f tests. A KEYS USB carrying only the public
    # kernel_key.der (private key withheld / on an HSM — a normal shape) therefore sets
    # CERT and leaves KEY empty. That is not an error: with no key, :378's documented
    # default applies ("a throwaway org key is generated under WORK_DIR/secureboot") and
    # the build is a correct dev/test image. Say so once, rather than failing a workflow
    # that never asked for Secure Boot signing.
    if [ -n "${SECUREBOOT_CERT}" ] && [ -z "${SECUREBOOT_KEY}" ]; then
        warn "KEYS USB has Keys/kernel_key.der but no Keys/kernel_key.pem: the cert alone"
        warn "  cannot sign. Falling back to a generated throwaway Secure Boot key — this"
        warn "  image will NOT boot under Secure Boot on a host enrolled to that cert."
    fi
fi
# Secure Boot signing material must be VALIDATED HERE, not discovered at signing time.
# The signing block (see "signing UKI with the provided KEYS key") is guarded by
# `[ -n "${SECUREBOOT_KEY}" ] && [ -f "${SECUREBOOT_KEY}" ]`, and its else-path silently
# generates a throwaway org key instead. So an unreadable key/cert path did not fail: it
# SKIPPED, the UKI got signed by a key that is in no firmware db, and the build exited 0.
# The breakage only surfaced when the delivered image refused to boot on the target —
# hours per image later. --keys-usb has had this preflight all along (just above); the
# loose --secureboot-key/--secureboot-cert paths never did. Fail fast instead, at second 0.
if [ -n "${SECUREBOOT_KEY}" ] && [ ! -f "${SECUREBOOT_KEY}" ]; then
    err "--secureboot-key: file not found: ${SECUREBOOT_KEY}"
    err "  (the UKI would otherwise be signed with a throwaway generated key that is in no"
    err "   firmware db, and the image would NOT boot under Secure Boot on the target.)"
    err "  NOTE: under the docker backend the path must be visible INSIDE the container."
    exit 1
fi
if [ -n "${SECUREBOOT_CERT}" ] && [ ! -f "${SECUREBOOT_CERT}" ]; then
    err "--secureboot-cert: file not found: ${SECUREBOOT_CERT}"; exit 1
fi
# A cert with no key is inert: the signing block keys off SECUREBOOT_KEY, so the cert is
# read only from within it. Passing one alone silently signs with the throwaway key.
# EXPLICIT only. Using ${SECUREBOOT_CERT} here would also catch the --keys-usb der-only
# case handled above, and hard-error a build the operator never asked to sign — telling
# them "--secureboot-cert needs ... (or --keys-usb DIR)" while naming a flag they did not
# pass and prescribing the one they did. Passing --secureboot-cert by hand is a request to
# sign, so a missing key there IS a real dead-end; auto-discovery is not.
if [ -n "${SECUREBOOT_CERT_EXPLICIT}" ] && [ -z "${SECUREBOOT_KEY}" ]; then
    err "--secureboot-cert needs --secureboot-key (or --keys-usb DIR): a cert alone is never used"
    exit 1
fi
# --distdir WARNS rather than errs, and the asymmetry with the secureboot preflight above
# is deliberate: an ignored signing key yields a WRONG ARTIFACT (an image that will not
# boot), while an ignored distfiles cache yields a CORRECT artifact that merely took longer
# to build. Erroring here would break the legitimate "cache drive is sometimes attached"
# workflow to prevent nothing. But the silence was still wrong: the flag is documented as
# "set explicitly to FORCE one", and an unusable value quietly fell back to the /media/*
# auto-detect scan — so an operator who mistyped it, or ran under docker without the path
# mounted, was told nothing and simply paid for a full re-download.
if [ -n "${DISTDIR_SRC}" ] && [ ! -d "${DISTDIR_SRC}" ]; then
    warn "--distdir: not a directory: ${DISTDIR_SRC} — IGNORING it and falling back to the"
    warn "  /media/* auto-detect scan (sources will be re-downloaded if no cache is found)."
    warn "  Under the docker backend the path must be visible INSIDE the container."
fi

# ── Client person-role + domain validation (FD-08) ──────────────────
# Client images are tied at build time to a person-role and domain(s). Default the
# person-role to 'user' and warn if no domain was given (the device still builds;
# the domain tie + Casdoor binding are applied by keys-provision from the KEYS USB).
if ${ROLE_CLIENT}; then
    [ -z "${PERSON_ROLE}" ] && PERSON_ROLE="user"
    case "${PERSON_ROLE}" in
        user|mod|admin|superadmin) : ;;
        *) err "--person-role must be one of: user | mod | admin | superadmin (got '${PERSON_ROLE}')"; exit 1 ;;
    esac
    case "${DESKTOP}" in thin|full) : ;; *) err "--desktop must be thin | full (got '${DESKTOP}')"; exit 1 ;; esac
    # A standalone desktop has no SSO/domain tie, so the no-domains warning is moot.
    ${STANDALONE} || { [ -z "${DOMAINS}" ] && warn "client role '${ROLE}' built with no --domains; the device will be domain-tied at provision time from the KEYS USB."; }
    # Desktop payloads (linux-firmware ~1.5G + Xorg/mesa/GTK/LXDE) overflow the 8 GiB
    # node-sized compact root → "No space left on device" mid-.img. Size the compact
    # root for the client payload (growroot still expands to the disk on first boot).
    # An explicit --img-size always wins.
    if ! ${IMG_SIZE_SET}; then
        # Measured thin payload ≈13.6 GiB after the binpkgs cleanup below (linux-firmware
        # ~1.9G + Xorg/mesa/GTK/LXDE); full adds firefox/xfce/vlc/pipewire/cups. The
        # --capable Plasma workstation (KDE + libreoffice + media + dev + nvidia/cuda)
        # is far bigger → size it generously. growroot still expands to the disk on boot.
        if ${CAPABLE}; then ROOT_MiB=51200
        elif [ "${DESKTOP}" = "full" ]; then ROOT_MiB=24576
        else ROOT_MiB=16384; fi
        info "Client desktop: compact root sized to ${ROOT_MiB} MiB for the ${DESKTOP}${CAPABLE:+/capable} payload (override with --img-size)"
    fi
elif [ -n "${PERSON_ROLE}" ] || [ -n "${DOMAINS}" ]; then
    warn "--person-role/--domains are ignored for non-client role '${ROLE}'."
fi

# ── Standalone local-user password → build-time hash (never baked in plaintext) ──
# --local-pass takes a PLAINTEXT password; we hash it here with `ph_crypt_hash`
# (yescrypt $y$, SHA-512 crypt $6$ fallback) and bake only the hash into the
# firstboot template. The local user name doubles as the firstboot
# DEFAULT_USER so the two paths agree.
LOCAL_PASSHASH=""
if ${STANDALONE} || [ -n "${LOCAL_USER}" ] || [ -n "${LOCAL_USER_PASS}" ]; then
    [ -n "${LOCAL_USER}" ] && DEFAULT_USER="${LOCAL_USER}"
    if [ -n "${LOCAL_USER_PASS}" ]; then
        command -v openssl >/dev/null 2>&1 || { err "--local-pass needs openssl on the build host (app-crypt/... / dev-libs/openssl)"; exit 1; }
        # ph_crypt_hash (scripts/_passhash-lib.sh): yescrypt ($y$) when the build
        # host's libcrypt round-trips it, else SHA-512 crypt ($6$). This hash is
        # what a stolen-device attacker cracks offline — docs/CRYPTO-AUDIT.md row 12.
        LOCAL_PASSHASH="$(ph_crypt_hash "${LOCAL_USER_PASS}")"
        LOCAL_USER_PASS=""   # scrub the plaintext from the environment immediately
        case "${LOCAL_PASSHASH}" in
            '$y$'*) info "Standalone local user '${DEFAULT_USER}': password hashed at build time (yescrypt; plaintext not baked)." ;;
            *)      info "Standalone local user '${DEFAULT_USER}': password hashed at build time (SHA-512 crypt fallback — build-host libcrypt lacks yescrypt; plaintext not baked)." ;;
        esac
    else
        ${STANDALONE} && warn "Standalone build with no --local-pass: a RANDOM one-time password is minted at first boot (printed once to console)."
    fi
fi

# ── Fail-closed identity/branding validation (defense-in-depth) ───────────────
# Run AFTER LOCAL_USER may have overridden DEFAULT_USER (above) so we validate the
# value actually baked into the root-run first-boot useradd/chpasswd and media.conf.
# These fields reach unquoted shell words, sed replacements, and sourced KEY=VALUE
# files; reject injection here, before any of those sinks. (HOSTNAME is either the
# operator's --hostname or the role-derived "${BRAND}-<role>" set above; an empty
# value would no-op, but by here it is always set — either way it must be a DNS label.)
_validate_username "DEFAULT_USER" "${DEFAULT_USER}"
_validate_username "--local-user" "${LOCAL_USER}"
_validate_slug     "--brand"      "${BRAND}"
_validate_org      "--org"        "${ORG}"
_validate_dnsname  "--cluster-domain" "${CLUSTER_DOMAIN}"
# Orchestration superdomain: validate as a DNS name (like --cluster-domain) only when
# set; "" = builder default (no bake). Same RFC-1123 allowlist as every other domain arg.
[ -n "${SUPERDOMAIN}" ] && _validate_dnsname "--superdomain" "${SUPERDOMAIN}"
_validate_dnsname  "--games-domain"   "${GAMES_DOMAIN}"
_validate_hostname "--hostname"   "${HOSTNAME}"
_validate_title    "--brand-title" "${BRAND_TITLE}"
# --domains is a comma/space-separated list baked line-by-line into the root-sourced
# /etc/hugmesh/domains (its first element also feeds a downstream sed replacement).
# --cluster-domain/--games-domain are validated above, but the DOMAINS list was not:
# validate EACH element as a DNS name, fail-closed, so a direct-CLI build (one that
# does NOT go through Studio's per-name gate) with e.g. --domains 'a.test,evil|inject'
# cannot bake a tainted / line-injected row into that root-sourced file.
if [ -n "${DOMAINS}" ]; then
    for _d in ${DOMAINS//,/ }; do _validate_dnsname "--domains element" "${_d}"; done
    unset _d
fi
# Accent is written as ACCENT_COLOR="..." into the sourced brand.conf; gate it with
# the same #RRGGBB shape the applier's _norm_accent enforces (empty = default later).
case "${BRAND_ACCENT}" in
    '') : ;;
    '#'[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) : ;;
    *) err "--accent-color '${BRAND_ACCENT}' must be #RRGGBB hex"; exit 1 ;;
esac

# ── Mesh-node IdP (I6): fail-closed validation + per-provider JWKS derivation ──
# Mirrors studio core/config.validate_identity byte-for-byte: unknown provider dies;
# casdoor (the built-in default) with ANY external field dies (a half-switched
# provider is a config bug, never silently ignored — the byte-identity invariant);
# an external provider without an https issuer + client id dies. Charset allowlists
# exclude everything shell/sed-meaningful: the values land in the root-baked
# /etc/hugmesh/idp.conf AND the replacement side of the issuer/JWKS sed rewrite.
_IDP_URL_RE='^https://[A-Za-z0-9][A-Za-z0-9._:/%=+-]*$'
_IDP_CLIENT_ID_RE='^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$'
_validate_idp() {
    case "${IDP}" in
        casdoor)
            [ -n "${IDP_ISSUER}" ]    && { err "--idp-issuer is set but --idp is 'casdoor' (the built-in default) — clear it or pick --idp entra|aws|oidc"; exit 1; }
            [ -n "${IDP_CLIENT_ID}" ] && { err "--idp-client-id is set but --idp is 'casdoor' (the built-in default) — clear it or pick --idp entra|aws|oidc"; exit 1; }
            [ -n "${IDP_JWKS}" ]      && { err "--idp-jwks is set but --idp is 'casdoor' (the built-in default) — clear it or pick --idp entra|aws|oidc"; exit 1; }
            ;;
        entra|aws|oidc)
            [[ "${IDP_ISSUER}" =~ ${_IDP_URL_RE} ]] \
                || { err "--idp ${IDP} requires an https:// --idp-issuer (got '${IDP_ISSUER}') — the issuer is the token-validation trust anchor and must be TLS"; exit 1; }
            [[ "${IDP_CLIENT_ID}" =~ ${_IDP_CLIENT_ID_RE} ]] \
                || { err "--idp ${IDP} requires --idp-client-id (allowlist [A-Za-z0-9._:/-], max 128; got '${IDP_CLIENT_ID}')"; exit 1; }
            if [ -n "${IDP_JWKS}" ]; then
                [[ "${IDP_JWKS}" =~ ${_IDP_URL_RE} ]] \
                    || { err "--idp-jwks must be an https:// URL (got '${IDP_JWKS}') — leave empty to derive the provider default"; exit 1; }
            fi
            ;;
        *)
            err "unknown --idp '${IDP}' (known: casdoor entra aws oidc)"
            exit 1
            ;;
    esac
    # Explicit success: the casdoor arm's last `[ -n … ]` legitimately evaluates
    # false, and under `set -e` a rc=1 falling out of the function would abort the
    # whole build for the DEFAULT provider.
    return 0
}
_idp_default_jwks() {
    # The documented per-provider JWKS derivation off the issuer (used when
    # --idp-jwks is empty): entra publishes at /discovery/v2.0/keys, Cognito at
    # /.well-known/jwks.json; a generic OIDC provider gets the Casdoor-shaped
    # /.well-known/jwks the baked tree already pins (override if yours differs).
    case "${IDP}" in
        entra) printf '%s/discovery/v2.0/keys' "${IDP_ISSUER%/}" ;;
        aws)   printf '%s/.well-known/jwks.json' "${IDP_ISSUER%/}" ;;
        oidc)  printf '%s/.well-known/jwks' "${IDP_ISSUER%/}" ;;
        *)     printf '' ;;
    esac
}
_validate_idp
if [ "${IDP}" != "casdoor" ] && [ -z "${IDP_JWKS}" ]; then
    IDP_JWKS="$(_idp_default_jwks)"
    info "IdP: --idp-jwks empty — derived the ${IDP} default: ${IDP_JWKS}"
fi

# ── Cluster NODE compact-root sizing (pki/be/fe/be+gpu/omnibus) ──────────────────────
# The k8s node payload (kubeadm/kubelet/containerd + mesh binaries + base) is ~11.2 GiB
# and overflows the historical 8 GiB ROOT_MiB default → the .img pre-flight (build_img)
# aborts with "Payload NNNN MiB exceeds the 8192 MiB root partition". Mirror the client
# auto-bump for nodes: GPU/omnibus roles add the mesa/vulkan runtime so they get more.
# An explicit --img-size always wins; growroot still expands to the disk on first boot.
if ! ${ROLE_CLIENT} && ! ${IMG_SIZE_SET}; then
    if ${GPU}; then ROOT_MiB=20480; else ROOT_MiB=14336; fi
    info "Cluster node '${ROLE}': compact root sized to ${ROOT_MiB} MiB for the k8s payload (override with --img-size)"
fi

# ── Validate/normalize the first-boot grow policy (baked into /etc/growfs.conf) ──
# fill (DEFAULT) | none/off/0 (keep the compact flashed layout) | concrete size
# (16G, 12000M, 50% ...). Concrete sizes pass through to resize2fs on the node.
GROW_POLICY="$(printf '%s' "${GROW_POLICY}" | tr '[:upper:]' '[:lower:]')"
case "${GROW_POLICY}" in
    fill|none|off|no|false|0) ;;
    *[0-9]g|*[0-9]m|*[0-9]k|*[0-9]t|*[0-9]gib|*[0-9]mib|*[0-9]kib|*[0-9]%|*[0-9]) ;;
    *) err "--grow must be: fill | none | <size> (e.g. 16G, 12000M, 50%)  (got '${GROW_POLICY}')"; exit 1 ;;
esac

# ── Validate + announce the build ENV (baked into the image) ──────────────
case "${ENV}" in
    test|prod) ;;
    *) err "--env must be one of: test | prod  (got '${ENV}')"; exit 1 ;;
esac

# ── Validate the release-state posture (baked into the image) ─────────────
case "${RELEASE_STATE}" in
    internal|public) ;;
    *) err "--release-state must be one of: internal | public  (got '${RELEASE_STATE}')"; exit 1 ;;
esac
if [ "${ENV}" = "prod" ] && ${UNAFFILIATED}; then
    # An unaffiliated desktop bakes no cluster domain / Cloudflare / ACME / keys-USB
    # machinery, so the loud cluster-prod banner below (and its domain) would be a
    # false affiliation claim in the build log.
    info "Build ENV: prod (unaffiliated plain desktop: no cluster domain or ACME machinery is baked)"
elif [ "${ENV}" = "prod" ]; then
    # LOUD announced banner — a prod image bakes the REAL public domain and
    # expects Cloudflare/OAuth/SMTP creds from the keys USB. Make it impossible
    # to miss that this is NOT a throwaway LAN image.
    echo -e "${RED}${BOLD}"
    echo "############################################################################"
    echo "##                                                                        ##"
    echo "##   BUILDING PROD IMAGE for ${CLUSTER_DOMAIN}"
    echo "##                                                                        ##"
    echo "##   - bakes the REAL public domain (no .test wildcard DNS authority)     ##"
    echo "##   - Cloudflare / external-dns / ACME go-live app is KEPT (creds: USB)  ##"
    echo "##   - OAuth / SMTP expected from the keys USB                            ##"
    echo "##   - internal cluster-CA TLS still applies (ACME is additive)           ##"
    echo "##                                                                        ##"
    echo "##   For a LAN test image use:  --env test  (or 'make local')             ##"
    echo "##                                                                        ##"
    echo "############################################################################"
    echo -e "${RST}"
else
    info "Build ENV: test (LAN-first; cluster wildcard DNS; cloudflared/ACME pruned)"
fi

# ── user package deltas: validate + enforce the tier-1 mandatory floor ─────────
# Done HERE (after role resolution, before --print-plan and any mutation) so a
# malformed atom or an illegal drop fails LOUDLY at the boundary — never reaching
# emerge or the grep -vE filter. Atom charset mirrors core/validate.py exactly.
_PKG_ATOM_RE='^[a-z0-9][a-z0-9+._-]*/[A-Za-z0-9+._-]+$'
_validate_pkg_atoms() { # LABEL VALUE
    local _lbl="$1" _a; local -a _arr
    read -ra _arr <<< "$2"
    for _a in "${_arr[@]}"; do
        [[ "${_a}" =~ ${_PKG_ATOM_RE} ]] || {
            err "invalid ${_lbl} atom: '${_a}' — want a category/name atom (e.g. app-editors/vim)"; exit 1; }
    done
}
_validate_pkg_atoms --packages-add  "${PACKAGES_ADD}"
_validate_pkg_atoms --packages-drop "${PACKAGES_DROP}"
# Tier-1 mandatory atoms: the payload whose binaries the post-emerge assert
# requires (base + role class). Dropping one would ship a broken image (Decision
# #5: tier-2 defaults are droppable; tier-1 essentials are hard-locked).
SNAP_MANDATORY_ATOMS="sys-boot/grub sys-kernel/dracut sys-block/parted app-misc/jq net-misc/networkmanager"
if ${ROLE_CLIENT}; then
    SNAP_MANDATORY_ATOMS="${SNAP_MANDATORY_ATOMS} x11-base/xorg-server x11-wm/openbox x11-misc/lightdm"
else
    SNAP_MANDATORY_ATOMS="${SNAP_MANDATORY_ATOMS} sys-cluster/kubelet sys-cluster/kubeadm app-containers/containerd"
fi
if [ -n "${PACKAGES_DROP}" ]; then
    read -ra _drop_check <<< "${PACKAGES_DROP}"
    for _d in "${_drop_check[@]}"; do
        for _m in ${SNAP_MANDATORY_ATOMS}; do
            [ "${_d}" = "${_m}" ] && { err "refusing to --packages-drop mandatory-payload atom '${_d}' — tier-1 essential (the image would fail its payload assert)"; exit 1; }
        done
    done
fi

# ── BRANDING LANE (ask 6): validate --theme HERE, not 2100 lines down ──────────
# The preset is resolved to ${SPECS_DIR}/branding/themes/<name> and `cp -r`'d at the
# branding step far below, and that was the ONLY place the name was ever checked.
# Two consequences this closes, in the same spirit as the package-atom floor above
# (validate at the boundary, before --print-plan and before any mutation):
#
#  1) --print-plan — the resolver EVERY channel preflights with (Studio
#     --print-command, tests/build-matrix, the ncurses menu's dry run) — exited 0 on
#     a theme the build would later hard-error on. The validator and the build
#     disagreed about which themes exist, which is exactly the "offered set != the
#     accepted set" defect the Studio's assert_theme_set_agrees() exists to prevent
#     one layer up. Now both ends resolve the same directory, so the accepted set IS
#     the directory listing at BOTH points and the equality holds end to end.
#  2) The name is concatenated straight into a path, so `--theme ../..` names a
#     directory that really exists, passes `[ -d ]`, and `cp -r`s that whole tree
#     into the image's branding dir. A bare-name allowlist makes that unreachable.
#
# Deliberately NOT a hardcoded list of the four: the builder's accepted set must stay
# "whatever directories are shipped", or adding a theme would mean editing the
# builder and the equality would gain a term that can silently drift.
if [ -n "${BRANDING_THEME}" ]; then
    case "${BRANDING_THEME}" in
        *[!A-Za-z0-9._-]*|.*|*..*)
            err "invalid --theme '${BRANDING_THEME}' — want a bare preset name (e.g. dark), not a path"
            exit 1 ;;
    esac
    [ -d "${SPECS_DIR}/branding/themes/${BRANDING_THEME}" ] || {
        err "unknown --theme '${BRANDING_THEME}' (looked in ${SPECS_DIR}/branding/themes/${BRANDING_THEME})"
        exit 1; }
fi

# ── --print-plan: emit the resolved plan and exit BEFORE ANY mutation ──────────
# Runs AFTER full arg parsing / role+GPU+desktop+env validation / the optional-
# services resolution / the standalone posture fold, but BEFORE the run-as-root
# gate directly below (deliberate: planning needs no root), before mkdir, network
# fetches or any sysroot write. One stable KEY=VALUE per line (grep '^PLAN_');
# exit 0. Invalid role/flag combos never reach this point — the validation above
# already exited non-zero, which is exactly what the tests/build-matrix harness
# relies on. SECRETS (--local-pass / --luks-pass / --user-password /
# --root-password values) are NEVER echoed — only a REDACTED presence marker.
# ── Shared build assets (root resolution) ─────────────────────────────────────
# Resolved BEFORE --print-plan so every channel's plan states what is reused. The
# WORK_DIR default is applied a few lines below, so use the SAME
# ${WORK_DIR:-$(pwd)/out} expression _plan WORK_DIR uses — both must agree.
BOARD_POOL_KEY="snap-build-x86"
SHARED_ROOT="$(sa_root "${WORK_DIR:-$(pwd)/out}" "${SHARED_ASSETS_DIR}")"
if [ -n "${SHARED_ROOT}" ]; then
    SHARED_DISTDIR="$(sa_distfiles_dir "${SHARED_ROOT}")"
    SHARED_SEED_DIR="$(sa_seed_dir "${SHARED_ROOT}" "amd64")" \
        || { echo "ERROR: cannot resolve the shared stage3 seed dir" >&2; exit 1; }
    # Shared x86 binpkg pool (issue #46): ONE per-arch pool for EVERY amd64 role.
    # The key is the arch constant snap-build-x86, NEVER ${BUILD_SUBDIR} — the Studio
    # passes --build-subdir wl-<entry-id> per worklist entry, and keying the pool on
    # the subdir is exactly what gave every x86 image a fresh empty pool (wave 1:
    # 0% reuse, 590 atoms recompiled in 2+ images at identical versions). All roles
    # share it deliberately: the wave-1 measurement proved compile sets are
    # byte-identical within role groups (pki=be=fe 230/230, laptop=chromebook
    # 590/590), and where roles DO diverge --binpkg-respect-use=y rejects the
    # mismatched binpkg per-package. Cross-ABI reuse stays impossible: the pool is
    # stamped/guarded by sa_pool_guard (CHOST + CFLAGS + profile) below.
    X86_POOL_DIR="$(sa_pool_dir "${SHARED_ROOT}" "${BOARD_POOL_KEY}")" \
        || { echo "ERROR: cannot resolve a shared binpkg pool for '${BOARD_POOL_KEY}'" >&2; exit 1; }
else
    SHARED_DISTDIR=""
    SHARED_SEED_DIR=""
    X86_POOL_DIR=""   # --no-shared-assets: legacy chroot-internal pool (see mount_chroot)
fi
# Signed-kernel artifact cache root. Empty (⇒ every lookup MISSES, nothing is stored)
# when --no-kernel-cache, HUGMESH_KERNEL_CACHE=off, or the shared root itself is off.
KERNEL_CACHE_ROOT="$(kc_root "${SHARED_ROOT}")"
if ${PRINT_PLAN}; then
    _plan() { printf 'PLAN_%s=%s\n' "$1" "$2"; }
    # Filename-safe role tag (mirrors the Phase-9 artifact naming): be+gpu keeps
    # the legacy 'host' tag; client devices carry person-role + primary domain.
    _PLAN_ROLE_TAG="${ROLE}"
    [ "${ROLE}" = "be+gpu" ] && _PLAN_ROLE_TAG="host"
    # UNAFFILIATED artifacts carry no person-role/domain tie — the bare role name.
    if ${ROLE_CLIENT} && ! ${UNAFFILIATED}; then
        _pd="${DOMAINS%%[ ,]*}"; _dt="${_pd//./_}"
        _PLAN_ROLE_TAG="${ROLE}-${PERSON_ROLE}${_dt:+-${_dt}}"
    fi
    _plan BUILDER            "build-x86-host-stage4.sh"
    _plan PLATFORM           "x86"
    _plan ARCH               "amd64"
    _plan ROLE               "${ROLE}"
    _plan ROLE_TAG           "${_PLAN_ROLE_TAG}"
    _plan ENV                "${ENV}"
    _plan ROLE_CLASS         "$(${STANDALONE} && echo standalone || { ${ROLE_CLIENT} && echo client || echo node; })"
    _plan DESKTOP            "$(${ROLE_CLIENT} && echo "${DESKTOP}$(${CAPABLE} && echo '+capable')" || echo none)"
    _plan GPU_DRIVER         "${GPU_DRIVER}"
    _plan CUDA               "${NVIDIA_CUDA}"
    _plan K8S                "${ROLE_K8S}"
    _plan PERSON_ROLE        "${PERSON_ROLE:-none}"
    _plan STANDALONE         "${STANDALONE}"
    _plan UNAFFILIATED       "${UNAFFILIATED}"
    _ARTS="stage4.tar.xz"
    ${BUILD_IMG}      && _ARTS="${_ARTS},img"
    ${LIVE_ISO}       && _ARTS="${_ARTS},live.iso"
    ${INSTALLER_ISO}  && _ARTS="${_ARTS},installer.iso"
    ${BUILD_TAR}      && _ARTS="${_ARTS},fs.tar.xz"
    _plan ARTIFACTS          "${_ARTS}"
    _plan ARTIFACT_PREFIX    "${BRAND}-x86-amd64-${_PLAN_ROLE_TAG}-${ENV}-<timestamp>"
    _plan WORK_DIR           "${WORK_DIR:-$(pwd)/out}"
    # Shared build assets. Additive PLAN_ keys (grep -qx consumers unaffected).
    # SHARED_POOL names the per-arch pool mount_chroot bind-mounts over the chroot's
    # /var/cache/binpkgs (issue #46); with sharing off the pool stays chroot-internal.
    _plan SHARED_ASSETS      "${SHARED_ROOT:-off}"
    _plan SHARED_SEED_DIR    "${SHARED_SEED_DIR:-${WORK_DIR:-$(pwd)/out}/${BUILD_SUBDIR}}"
    _plan SHARED_DISTDIR     "${SHARED_DISTDIR:-none}"
    _plan SHARED_POOL        "${X86_POOL_DIR:-no (private chroot-internal /var/cache/binpkgs)}"
    _plan KERNEL_CACHE       "${KERNEL_CACHE_ROOT:-off}"
    # Prebuild mode (shared-binpkg): 1 ⇒ populate PKGDIR then exit before image
    # assembly. Additive PLAN_ key (grep -qx consumers unaffected).
    _plan PACKAGES_ONLY      "$(${PACKAGES_ONLY} && echo 1 || echo 0)"
    _plan JOBS               "${JOBS}"
    _plan BRAND              "${BRAND}"
    _plan CLUSTER_DOMAIN     "${CLUSTER_DOMAIN}"
    _plan SUPERDOMAIN        "${SUPERDOMAIN}"
    _plan HOSTNAME           "${HOSTNAME:-${BRAND}-host}"
    _plan OPTIONAL_SERVICES  "$(${ROLE_CLIENT} && echo none || echo "${OPTIONAL_SERVICES:-none}")"
    _plan MESH               "$(${SKIP_MESH} && echo skip || echo "headscale=${HEADSCALE_VERSION},tailscale=$(${SKIP_TAILSCALE} && echo skip || echo "${TAILSCALE_VERSION}")")"
    _plan SSO                "$(${SKIP_SSO} && echo off || echo casdoor-oidc)"
    _plan IDP                "${IDP}"
    _plan IDP_ISSUER         "${IDP_ISSUER:-none}"
    _plan IDP_CLIENT_ID      "${IDP_CLIENT_ID:-none}"
    _plan IDP_JWKS           "${IDP_JWKS:-none}"
    _plan ENCRYPT_ROOT       "${ENCRYPT_ROOT}"
    _plan LUKS_PASS          "$([ -n "${LUKS_PASS}" ] && echo REDACTED || echo none)"
    _plan LOCAL_PASS         "$([ -n "${LOCAL_PASSHASH}" ] && echo REDACTED || echo none)"
    _plan FLAGS_EFFECTIVE    "env=${ENV} img=${BUILD_IMG} live_iso=${LIVE_ISO} installer_iso=${INSTALLER_ISO} tar=${BUILD_TAR} img_size=${ROOT_MiB} grow=${GROW_POLICY} compress=${COMPRESS_IMG} resume=${RESUME} skip_kernel=${SKIP_KERNEL} skip_mesh=${SKIP_MESH} skip_tailscale=${SKIP_TAILSCALE} skip_sso=${SKIP_SSO} standalone=${STANDALONE} desktop=${DESKTOP} capable=${CAPABLE} gpu_driver=${GPU_DRIVER} cuda=${NVIDIA_CUDA} encrypt_root=${ENCRYPT_ROOT} secure_boot=${SECURE_BOOT} media_data=${MEDIA_DATA} installer_ui=${INSTALLER_UI} permit_root_login=${PERMIT_ROOT_LOGIN} enable_wifi=${ENABLE_WIFI} enable_bluetooth=${ENABLE_BLUETOOTH} unaffiliated=${UNAFFILIATED}"
    _plan PACKAGES_ADD       "${PACKAGES_ADD}"
    _plan PACKAGES_DROP      "${PACKAGES_DROP}"
    exit 0
fi

[ "$(id -u)" -eq 0 ] || { err "Run as root (chroot emerge + ISO build need it)."; exit 1; }
[ -z "${WORK_DIR}" ] && WORK_DIR="$(pwd)/out"
[ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-host"
# BUILD_ROOT = the per-arch heavy build tree under WORK_DIR (default
# WORK_DIR/snap-build-x86). The sysroot, ISO staging, distfiles, pkgdir, seed
# tarball and downloads all live here so the amd64 build never collides with the
# aarch64 (Pi) build that shares the same WORK_DIR. Finished PRODUCTS
# (.img/.iso/.fs.tar.xz/stage4) still go to WORK_DIR (see STAGE4/IMG_PATH below).
BUILD_ROOT="${WORK_DIR}/${BUILD_SUBDIR}"
SYSROOT="${BUILD_ROOT}/sysroot"
ISO_DIR="${BUILD_ROOT}/isoroot"
CHOST="x86_64-pc-linux-gnu"

# Build logs (fix D, session 20260716-160638-f8c153): this builder used to have
# NO log redirect at all — its 5 node-image runs (~16min each) of that session
# left nothing on disk and the boost[python] wall could only be diagnosed from
# the Studio session JSON error_tail. Mirror the ARM builders: a session-shared
# build.log (tee -a append; what Studio's build_sessions.log_path and
# build-menu.sh monitor) PLUS a per-image build-<entry-id>.log derived from the
# EXISTING --build-subdir argv (wl-<entry-id> for worklist runs). No new flags.
LOG_FILE="${WORK_DIR}/build.log"
IMAGE_LOG_FILE="${WORK_DIR}/build-${BUILD_SUBDIR#wl-}.log"

# Single, sortable UTC build stamp shared by EVERY artifact of this run, so the
# .img / .iso / stage4 / fs tarball all carry the same identifier. Computed once
# here at build start. Artifacts are named:
#   ${BRAND}-x86-amd64-${ROLE_TAG}-${ENV}-${BUILD_TS}.<ext>
# (the ${BRAND}- prefix + role token keep the QEMU launcher's and flash-disk.sh's
#  'hugmesh-x86-*' / 'hugmesh-*-<role>-*' autodetect globs matching.)
BUILD_TS="$(date -u +%Y%m%dT%H%M%SZ)"
info "Build stamp: ${BUILD_TS} (UTC; brand=${BRAND}, env=${ENV})"

# GPU-derived make.conf tokens — the --gpu-driver matrix selects VIDEO_CARDS and
# which vendor stack is layered on. FREE (open) drivers are the default; only the
# 'nvidia' value pulls a proprietary DISPLAY driver (nvidia-drivers, nouveau
# blacklisted). amd-pro / intel-pro keep the OPEN display driver and add the
# vendor's proprietary/closed compute + Vulkan stack (see packages-gpu-*-pro.list).
NVIDIA_PROPRIETARY=false; AMD_PRO=false; INTEL_PRO=false
if ${GPU}; then
    GPU_USE="vulkan vaapi vdpau gbm egl gles2"
    case "${GPU_DRIVER}" in
        all-free)    VIDEO_CARDS="amdgpu radeonsi intel iris nouveau" ;;
        nvidia-free) VIDEO_CARDS="nouveau" ;;
        nvidia)      VIDEO_CARDS="nouveau nvidia"; NVIDIA_PROPRIETARY=true ;;
        amd-free)    VIDEO_CARDS="amdgpu radeonsi radeon" ;;
        amd-pro)     VIDEO_CARDS="amdgpu radeonsi"; AMD_PRO=true ;;
        intel-free)  VIDEO_CARDS="intel iris" ;;
        intel-pro)   VIDEO_CARDS="intel iris"; INTEL_PRO=true ;;
        none)        VIDEO_CARDS="" ;;
    esac
    info "GPU driver: ${GPU_DRIVER} (VIDEO_CARDS='${VIDEO_CARDS}')$(${NVIDIA_PROPRIETARY} && echo ' — NVIDIA proprietary, nouveau blacklisted'; ${AMD_PRO} && echo ' — + AMDGPU-PRO Vulkan/OpenCL'; ${INTEL_PRO} && echo ' — + Intel compute/media stack')${NVIDIA_CUDA:+ + CUDA toolkit}"
else
    GPU_USE=""
    VIDEO_CARDS=""
fi
# Client-desktop make.conf USE (appended LAST in make.conf.tmpl so it overrides the
# hardened headless -X/-gtk posture for client roles only). Nodes leave it empty.
if ${ROLE_CLIENT}; then
    CLIENT_USE="X gtk dbus elogind udev"
    [ "${DESKTOP}" = "full" ] && CLIENT_USE="${CLIENT_USE} pulseaudio pipewire"
    INPUT_DEVICES="libinput"   # Xorg keyboard/mouse/touchpad (via x11-base/xorg-drivers)
    # Client roles keep man pages; doc/info still skipped (not needed at runtime).
    # The .mo pattern masks ONLY the empty-basename catalogs from the gettext-0.23.2
    # empty-$(DOMAIN) bug (see the headless branch below): autotools-NLS packages
    # (grub/parted/cpio/openbox/speech-dispatcher/...) each install a file literally
    # named /usr/share/locale/<lang>/LC_MESSAGES/.mo that gettext already owns, and
    # collision-protect then refuses the WHOLE merge — the 2026-07-08 proof build
    # lost 143 packages to this. Real catalogs (openbox.mo etc.) are kept: desktops
    # deliberately retain translations.
    INSTALL_MASK="/usr/share/doc /usr/share/info /usr/share/locale/*/LC_MESSAGES/.mo"
else
    CLIENT_USE=""
    INPUT_DEVICES=""           # headless nodes run no X server
    # Also strip /usr/share/locale on headless nodes: they need no UI translations,
    # AND it dodges a tree-wide file-collision bug where gettext-0.23.2 + util-linux/
    # parted/grub/systemd-utils each install an empty-basename catalog
    # (/usr/share/locale/<lang>/LC_MESSAGES/.mo) that collides between packages, so
    # grub/parted/dracut fail to merge and the stage4 payload comes up incomplete.
    INSTALL_MASK="/usr/share/doc /usr/share/man /usr/share/info /usr/share/locale"
fi

# Reconcile the legacy SKIP_ISO switch with the new opt-in ISO design: an ISO
# build runs only when --live-iso or --installer-iso was requested. The prereq
# check + Phase-10 gate key off SKIP_ISO, so keep it as the negation of "any ISO".
if ${LIVE_ISO} || ${INSTALLER_ISO}; then SKIP_ISO=false; else SKIP_ISO=true; fi

render_template() {
    # Identity/branding/media/secret tokens are user/operator-influenced and land on the
    # REPLACEMENT side of `sed s|..|VALUE|` — a `|`/`&`/`\` (or newline) would terminate
    # the s-command, smuggle a second sed command, or backref the match into the rendered
    # artifact (which becomes a root-run script: firstboot/local.d/make.conf). Escape each
    # through _sed_rep_escape before substitution. (Up-front validators already forbid the
    # worst chars; this is the sink-side second layer.)
    local _user _userpass _rootpass _brand _btitle _domain _org _host
    local _mmount _mlabel _mmarkers _sdir _vdir
    _user="$(_sed_rep_escape "${DEFAULT_USER}")"
    _userpass="$(_sed_rep_escape "${DEFAULT_USER_PASS}")"
    _rootpass="$(_sed_rep_escape "${ROOT_PASS}")"
    _brand="$(_sed_rep_escape "${BRAND}")"
    _btitle="$(_sed_rep_escape "${BRAND_TITLE}")"
    _domain="$(_sed_rep_escape "${CLUSTER_DOMAIN}")"
    _org="$(_sed_rep_escape "${ORG}")"
    _host="$(_sed_rep_escape "${HOSTNAME}")"
    _mmount="$(_sed_rep_escape "${MEDIA_MOUNT}")"
    _mlabel="$(_sed_rep_escape "${MEDIA_LABEL}")"
    _mmarkers="$(_sed_rep_escape "${MEDIA_MARKERS}")"
    _sdir="$(_sed_rep_escape "${STEAM_DIR}")"
    _vdir="$(_sed_rep_escape "${VAULTS_DIR}")"
    sed -e "s|@@CHOST@@|${CHOST}|g" -e "s|@@JOBS@@|${JOBS}|g" \
        -e "s|@@WORK_DIR@@|${BUILD_ROOT}|g" -e "s|@@HOSTNAME@@|${_host}|g" \
        -e "s|@@TIMEZONE@@|${TIMEZONE}|g" -e "s|@@DEFAULT_USER@@|${_user}|g" \
        -e "s|@@DEFAULT_USER_PASS@@|${_userpass}|g" -e "s|@@ROOT_PASS@@|${_rootpass}|g" \
        -e "s|@@BRAND@@|${_brand}|g" -e "s|@@BRAND_TITLE@@|${_btitle}|g" \
        -e "s|@@DOMAIN@@|${_domain}|g" -e "s|@@ORG@@|${_org}|g" \
        -e "s|@@ENV@@|${ENV}|g" \
        -e "s|@@GPU_USE@@|${GPU_USE}|g" -e "s|@@VIDEO_CARDS@@|${VIDEO_CARDS}|g" \
        -e "s|@@CLIENT_USE@@|${CLIENT_USE}|g" -e "s|@@INPUT_DEVICES@@|${INPUT_DEVICES}|g" \
        -e "s|@@INSTALL_MASK@@|${INSTALL_MASK}|g" \
        -e "s|@@STANDALONE@@|${STANDALONE}|g" -e "s|@@LOCAL_PASSHASH@@|${LOCAL_PASSHASH}|g" \
        -e "s|@@MEDIA_DATA@@|${MEDIA_DATA}|g" -e "s|@@MEDIA_MOUNT@@|${_mmount}|g" \
        -e "s|@@MEDIA_LABEL@@|${_mlabel}|g" -e "s|@@MEDIA_MARKERS@@|${_mmarkers}|g" \
        -e "s|@@STEAM_DIR@@|${_sdir}|g" -e "s|@@STEAM_DELIVERY@@|${STEAM_DELIVERY}|g" \
        -e "s|@@VAULTS_DIR@@|${_vdir}|g" -e "s|@@VAULTS_ENABLED@@|${VAULTS_ENABLED}|g" \
        "$1" > "$2"
}

# ── harden_radios <sysroot> ───────────────────────────────────────────────────
# WiFi + Bluetooth are DISABLED BY DEFAULT (hardened posture). For each radio
# left OFF (ENABLE_WIFI / ENABLE_BLUETOOTH = false) we (a) blacklist its kernel
# modules in /etc/modprobe.d/ so they don't autoload, and (b) drop a first-boot
# /etc/local.d action that rfkill-blocks it and (for WiFi) tells NetworkManager
# to leave wlan unmanaged. ETHERNET + the Tailscale tailnet are NEVER touched.
# Idempotent + best-effort at runtime (missing rfkill/nmcli = skipped).
harden_radios() {
    local sysroot="$1"
    mkdir -p "${sysroot}/etc/modprobe.d" "${sysroot}/etc/local.d" \
             "${sysroot}/etc/NetworkManager/conf.d"
    local bl="${sysroot}/etc/modprobe.d/hugmesh-radio-blacklist.conf"
    : > "${bl}"
    local act="${sysroot}/etc/local.d/02-radio-hardening.start"

    {
        echo "#!/bin/sh"
        echo "# Radio hardening (generated by build-*-stage4.sh). WiFi/Bluetooth are"
        echo "# OFF by default; rfkill-block them at boot. Ethernet + tailnet untouched."
        echo "command -v rfkill >/dev/null 2>&1 || exit 0"
    } > "${act}"

    if [ "${ENABLE_WIFI}" != "true" ]; then
        {
            echo "# WiFi disabled by default (ENABLE_WIFI=false) — hardened posture."
            echo "blacklist cfg80211"
            echo "blacklist mac80211"
            echo "blacklist iwlwifi"
            echo "blacklist ath"
            echo "blacklist brcmfmac"
            echo "blacklist rtw88_core"
        } >> "${bl}"
        {
            echo "rfkill block wifi 2>/dev/null || true"
            echo "command -v nmcli >/dev/null 2>&1 && nmcli radio wifi off 2>/dev/null || true"
        } >> "${act}"
        # Keep NetworkManager from managing/auto-enabling WiFi (wired stays managed).
        printf '[device]\nwifi.scan-rand-mac-address=yes\n\n[main]\n# WiFi disabled by default; managed=ethernet only.\n' \
            > "${sysroot}/etc/NetworkManager/conf.d/10-no-wifi.conf"
        info "WiFi DISABLED by default (rfkill block + blacklist + NM no-wifi). Re-enable with --enable-wifi."
    else
        info "WiFi ENABLED (--enable-wifi / ENABLE_WIFI=true)."
    fi

    if [ "${ENABLE_BLUETOOTH}" != "true" ]; then
        {
            echo "# Bluetooth disabled by default (ENABLE_BLUETOOTH=false) — hardened posture."
            echo "blacklist bluetooth"
            echo "blacklist btusb"
            echo "blacklist btintel"
            echo "blacklist btrtl"
            echo "blacklist btbcm"
        } >> "${bl}"
        echo "rfkill block bluetooth 2>/dev/null || true" >> "${act}"
        info "Bluetooth DISABLED by default (rfkill block + blacklist + no service). Re-enable with --enable-bluetooth."
    else
        info "Bluetooth ENABLED (--enable-bluetooth / ENABLE_BLUETOOTH=true)."
    fi

    echo "rm -f /etc/local.d/02-radio-hardening.start" >> "${act}"
    chmod +x "${act}"
    # If both radios are enabled, the blacklist + action are inert; leave a note.
    [ -s "${bl}" ] || echo "# (no radios blacklisted — both WiFi and Bluetooth enabled)" > "${bl}"
}

# ── write_growfs_conf <dest> ──────────────────────────────────────────────────
# Emit the first-boot grow policy file consumed by the growroot service (GROW=
# fill|none|<size>). The comment header documents the per-device overrides so an
# operator editing the copy on the ESP needs no external docs.
write_growfs_conf() {
    local dest="$1"
    mkdir -p "$(dirname "${dest}")"
    cat > "${dest}" <<GROWFS_EOF
# growfs.conf — first-boot root-grow policy (read by the growroot service).
#   GROW=fill    grow the root to fill the WHOLE USB/SSD/NVMe (DEFAULT)
#   GROW=none    do not grow; keep the compact flashed layout
#   GROW=<size>  cap the root filesystem, e.g. 16G, 12000M, 50% (% of device)
# Precedence (first wins): kernel cmdline growfs=<v> > this file on the ESP >
#   /etc/growfs.conf (baked) > built-in fill. Edit this copy on the ESP to
#   retune a single flashed medium without rebuilding the image.
GROW=${GROW_POLICY}
GROWFS_EOF
}

# ── ENV app-gate (deterministic prune of the BAKED apps/ tree) ─────────────
# ArgoCD recurses specs/cluster/apps with recurse:true, so physically removing
# a YAML from the baked copy is the gate (no live-cluster conditional needed).
# Operates ONLY on ${SYSROOT}/var/lib/hugmesh/cluster/apps — never the repo.
#   prod => prune the LAN wildcard-DNS app (public DNS is authoritative instead).
#   test => prune the go-live cloudflared app (no Cloudflare/ACME on a LAN). The
#           LAN wildcard-DNS app is kept ONLY for a `.test` domain, so it can
#           never become authoritative for a real public domain (e.g. a default
#           ENV=test build still on hugmesh.net keeps neither edge).
# Pin first-party FLOATING image tags (`:dev`) to the pinned RELEASE_TAG for prod
# so the prod-hygiene gate finds no floating tag, and PRUNE the ENV=test e2e
# harness wave (the test-runner app + its test-only manifests) from the baked
# prod tree. Runs ONLY for ENV=prod (called from gate_env_apps). Conservative sed:
# only first-party image lines (image: ...hugmesh-.../...-{api,ui,bff,web,gateway}:dev
# + the akkoma/tuwunel pins) are rewritten; third-party `:dev`-less images untouched.
rewrite_prod_image_tags() {
    local tree="${SYSROOT}/var/lib/hugmesh/cluster"
    [ -d "${tree}" ] || return 0
    local n=0 f
    while IFS= read -r -d '' f; do
        # Any first-party image (its repo path contains 'hugmesh') tagged :dev
        # -> :RELEASE_TAG. Matches `image: <registry>/hugmesh.../<name>:dev`.
        # The repo-path char class EXCLUDES ':' so the greedy match stops before
        # the ':dev' tag (image repo paths carry no ':' except a registry port,
        # which our first-party images do not use).
        if grep -qE 'image:[[:space:]]*[^[:space:]:]*hugmesh[^[:space:]:]*:dev([[:space:]]|$)' "${f}" 2>/dev/null; then
            sed -i -E "s|(image:[[:space:]]*[^[:space:]:]*hugmesh[^[:space:]:]*):dev|\\1:${RELEASE_TAG}|g" "${f}"
            n=$((n+1))
        fi
    done < <(find "${tree}" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 2>/dev/null)
    info "ENV=prod: pinned first-party :dev image tags -> :${RELEASE_TAG} in ${n} file(s)"
    # Prune the ENV=test e2e harness (forbidden in prod by the hygiene gate's
    # tier:test rule). NOTE: the pen-test is now DEV/CI-pipeline-only (a per-repo
    # ArgoCD CI stage + a build option), NOT a deployed cluster wave — there is no
    # pentest-runner app/manifest to prune anymore.
    rm -f "${SYSROOT}/var/lib/hugmesh/cluster/apps/99-test-runner.yaml" \
          "${SYSROOT}/var/lib/hugmesh/cluster/apps/00-app-of-apps-waved.yaml" 2>/dev/null || true
    rm -rf "${SYSROOT}/var/lib/hugmesh/cluster/manifests/test-runner" 2>/dev/null || true
    info "ENV=prod: pruned the test-runner wave (apps/99-test-runner.yaml + manifests/test-runner) from the baked tree"
    # STATIC prod-hygiene self-check over the BAKED tree — hard-fail the build if
    # any dev-only server / tier:test resource / floating :dev tag survived the
    # prune + rewrite above. (The RUNTIME leg — the seam/seal/live-pod probe — is
    # the ArgoCD PreSync hook Job apps/00-prod-hygiene.yaml runs in-cluster.)
    local hygiene="${SCRIPT_DIR}/scripts/validate-prod-hygiene.sh"
    if [ -x "${hygiene}" ] || [ -f "${hygiene}" ]; then
        if bash "${hygiene}" "${tree}"; then
            info "ENV=prod: prod-hygiene static gate PASSED on the baked tree"
        else
            err "ENV=prod: prod-hygiene static gate FAILED on the baked tree (a dev-only server / test harness / floating :dev tag survived) — refusing to build a prod image"
            exit 1
        fi
    else
        warn "prod-hygiene gate script not found at ${hygiene}; skipping the static self-check"
    fi
}

# ── OPTIONAL-SERVICE gate ───────────────────────────────────────────────────
# Prune every OPTIONAL service (akkoma/tuwunel/phpbb/games) NOT selected in
# OPTIONAL_SERVICES from the baked GitOps tree, enumerated by
# specs/cluster/optional-services.yaml. Mirrors the gate_env_apps `rm -f` design
# (physically removing a baked YAML IS the gate: ArgoCD recurse:true never
# instantiates a removed Application). For each unselected slug it removes the
# owned apps/*.yaml + manifests dir, its per-service ESO file (+ its kustomization
# line), its gateway HOST routes (apps/20-gateway-*.yaml) and route-access rows
# (route-access/initdb/20-schema.sql) so a matched route to a deleted upstream
# cannot 502 and a leftover role row cannot stale-grant. Shared apps (social-ui,
# serving BOTH homeservers) are removed only when ALL owners are deselected.
#
# ⚠ RUNTIME NOTE: build-time prune only stops the ONE-TIME bootstrap seed; the
# live cluster syncs apps/ from the gitops repo. True runtime add/remove uses the
# installed-services ConfigMap + the optional-services ApplicationSet
# (apps/13a-optional-services.yaml). See docs/OPTIONAL-SERVICES.md.
#
# ⚠ CROSS-REPO TODO (gateway wave): CanonicalSeed.java (hugmesh-gateway) bakes
# a route-access floor + the cloudflared configmap hardcodes matrix./mastodon.
# reserved hostnames — keep those in sync with the rows pruned here. NOT edited by
# this build (separate repo / image rebuild).
_opt_selected() {
    # $1 = slug; returns 0 if selected (present in OPTIONAL_SERVICES), else 1.
    local s; for s in ${OPTIONAL_SERVICES}; do [ "${s}" = "$1" ] && return 0; done
    return 1
}
gate_optional_services() {
    local tree="${SYSROOT}/var/lib/hugmesh/cluster"
    local apps="${tree}/apps"
    [ -d "${apps}" ] || return 0
    local slug
    for slug in akkoma tuwunel phpbb games owncast tube character-studio character-forge headwind attestation-server egress-vpn workloadConsole edge-ai edge-ai-analysis edge-ai-tts tor; do
        _opt_selected "${slug}" && continue
        info "OPTIONAL_SERVICES: '${slug}' NOT selected — pruning it from the baked tree"
        case "${slug}" in
            akkoma)
                rm -f "${apps}/30-akkoma.yaml"
                rm -rf "${tree}/manifests/akkoma"
                rm -f "${tree}/manifests/external-secrets/akkoma-externalsecrets.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/external-secrets/kustomization.yaml" akkoma-externalsecrets.yaml
                _opt_drop_route "${apps}/20-gateway-be.yaml" mastodon-oauth mastodon-api mastodon-web
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-be-gateway \
                    '/api/v1/pleroma/admin/**' '/api/pleroma/admin/**' '/pleroma/admin/**'
                ;;
            tuwunel)
                rm -f "${apps}/30-tuwunel.yaml"
                rm -rf "${tree}/manifests/tuwunel"
                rm -f "${tree}/manifests/external-secrets/tuwunel-externalsecrets.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/external-secrets/kustomization.yaml" tuwunel-externalsecrets.yaml
                _opt_drop_route "${apps}/20-gateway-be.yaml" matrix-api matrix-wellknown matrix
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-be-gateway \
                    '/_matrix/**' '/.well-known/matrix/**' '/_synapse/**'
                ;;
            phpbb)
                rm -f "${apps}/30-phpbb.yaml" "${apps}/38-forum-bff-db.yaml" \
                      "${apps}/39-forum-bff-api.yaml" "${apps}/49-forum-ui.yaml"
                rm -rf "${tree}/manifests/forum"
                _opt_drop_route "${apps}/20-gateway-fe.yaml" forum-ui hugmesh-forum-bff-api hugmesh-forum-bff-api-moderation
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-fe-gateway \
                    '/social/forum/**' '/bff/forum/admin/**' '/bff/forum/moderation/**' '/bff/forum/**'
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-be-gateway \
                    '/api/forum/admin/**'
                ;;
            games)
                rm -f "${apps}/06-casdoor-games.yaml" "${apps}/50-games.yaml"
                rm -rf "${tree}/manifests/games" "${tree}/manifests/casdoor-games"
                _opt_drop_route     "${apps}/20-gateway-be.yaml" games
                _opt_drop_extrahost "${apps}/20-gateway-be.yaml" games.
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-be-gateway \
                    '/games/api/admin/**' '/games/**'
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-fe-gateway \
                    '/games/admin/**'
                # ── GAMES APP-STORE (games-services control plane) — degrade with games ──
                # The app-store rides the games slug (it needs the games namespace up), so
                # deselecting games prunes the WHOLE control plane: the 13c instances
                # ApplicationSet + the games-instances namespace/isolation manifests, the two
                # intersection-sync Jobs (+ their casdoor/kustomization lines), the be-gateway
                # HTTP-console route, and the games-services route-access rows (be + fe).
                rm -f "${apps}/13c-games-instances.yaml"
                rm -rf "${tree}/manifests/games-instances"
                rm -f "${tree}/manifests/casdoor/games-services-admin-sync-job.yaml" \
                      "${tree}/manifests/casdoor/games-services-runner-sync-job.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/casdoor/kustomization.yaml" games-services-admin-sync-job.yaml
                _opt_drop_kustomize_line "${tree}/manifests/casdoor/kustomization.yaml" games-services-runner-sync-job.yaml
                _opt_drop_route "${apps}/20-gateway-be.yaml" games-servers-console
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-be-gateway \
                    '/bff/superadmin/games-services/**' '/bff/games-services/instances/**' \
                    '/bff/games-services/catalog/**' '/games/servers/**'
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-fe-gateway \
                    '/admin/games-services/**'
                ;;
            edge-ai)
                rm -f "${apps}/54-edge-ai.yaml"
                rm -rf "${tree}/manifests/edge-ai"
                _opt_drop_route "${apps}/20-gateway-be.yaml" edge-ai
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-be-gateway \
                    '/v1/**'
                ;;
            edge-ai-analysis)
                rm -f "${apps}/55-edge-ai-analysis.yaml"
                rm -rf "${tree}/manifests/edge-ai-analysis"
                _opt_drop_route "${apps}/20-gateway-be.yaml" edge-ai-analysis
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-be-gateway \
                    '/v1/analyze/**'
                ;;
            edge-ai-tts)
                # Piper TTS + viseme timeline (VN voice, B3) — DEFAULT-OFF, NO
                # dependsOn (CPU-only, self-contained). Owns app 55b +
                # manifests/edge-ai-tts + the /v1/synthesize/** route + route-access
                # row. Image is a separate build artifact.
                rm -f "${apps}/55b-edge-ai-tts.yaml"
                rm -rf "${tree}/manifests/edge-ai-tts"
                _opt_drop_route "${apps}/20-gateway-be.yaml" edge-ai-tts
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-be-gateway \
                    '/v1/synthesize/**'
                ;;
            owncast)
                # Owncast live-streaming — GPU-gated x86 service (DEFAULT-OFF). Owns its
                # bootstrap Application + manifests dir + its fe-gateway BFF route-access
                # rows (no gateway HOST route + no per-service ESO today). When deselected
                # the user/admin live-stream panels grey out (installed-services "false").
                rm -f "${apps}/52-owncast.yaml"
                rm -rf "${tree}/manifests/owncast"
                _opt_drop_route "${apps}/20-gateway-fe.yaml" hugmesh-owncast-bff-api
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-fe-gateway \
                    '/bff/owncast/admin/**' '/bff/owncast/**'
                ;;
            character-studio)
                # Character Studio (VN) — FRONTEND micro-frontend remote (DEFAULT-OFF, admin
                # gate). Owns its bootstrap Application + manifests dir + its ONE fe-gateway
                # path route (character-studio-ui) + its ONE route-access row (no gateway
                # HOST + no per-service ESO + no BFF in this slug). When deselected the host
                # greys the /character-studio entry out (installed-services "false").
                rm -f "${apps}/49b-character-studio-ui.yaml"
                rm -rf "${tree}/manifests/character-studio"
                _opt_drop_route "${apps}/20-gateway-fe.yaml" character-studio-ui
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-fe-gateway \
                    '/character-studio/**'
                ;;
            character-forge)
                # Character Forge (3D) — MULTI-APP slug (DEFAULT-OFF, admin gate): BFF db +
                # BFF api + UI remote (phpbb shape). Owns its three bootstrap Applications +
                # three manifest dirs + its TWO fe-gateway path routes (character-forge-ui +
                # hugmesh-character-forge-bff-api) + its TWO route-access rows (no gateway
                # HOST; its ESO secrets ride the SHARED secretstore/pki files like forum-bff's
                # — inert without their consumer pods, so NOT pruned here). When deselected
                # the host greys the /character-forge entry out (installed-services "false").
                # See docs/XR-CHAT.md.
                rm -f "${apps}/38b-character-forge-bff-db.yaml" \
                      "${apps}/39b-character-forge-bff-api.yaml" \
                      "${apps}/49c-character-forge-ui.yaml"
                rm -rf "${tree}/manifests/character-forge" \
                       "${tree}/manifests/character-forge-bff-api" \
                       "${tree}/manifests/character-forge-bff-db"
                _opt_drop_route "${apps}/20-gateway-fe.yaml" character-forge-ui hugmesh-character-forge-bff-api
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-fe-gateway \
                    '/character-forge/**' '/bff/character-forge/**'
                ;;
            tube)
                # LocalTube (YouTube archive) — GPU-gated x86 service (DEFAULT-OFF). Owns
                # its bootstrap Application + manifests dir + its per-service ESO file
                # (tube-externalsecrets.yaml; standalone, not in the ESO kustomization) +
                # its fe/be route-access rows. When deselected the tube panel greys out.
                rm -f "${apps}/53-tube.yaml"
                rm -rf "${tree}/manifests/tube"
                rm -f "${tree}/manifests/external-secrets/tube-externalsecrets.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/external-secrets/kustomization.yaml" tube-externalsecrets.yaml
                _opt_drop_route "${apps}/20-gateway-fe.yaml" hugmesh-tube-bff-api tube-content
                _opt_drop_route "${apps}/20-gateway-be.yaml" tube-content
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-fe-gateway \
                    '/bff/tube/**'
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-be-gateway \
                    '/tube/content/**'
                ;;
            egress-vpn)
                # NODE service (not a cluster Application). Prune the per-service NetworkPolicy
                # interaction (file + kustomization line) so no vpn-egress label is ever
                # honoured. On x86 egress-vpn is the DESKTOP --egress-vpn FILE path (never a
                # registry _opt_selected), so this prune always runs — the registry interaction
                # NetworkPolicy is moot on x86; the node-package/service handling is its own path.
                rm -f "${tree}/manifests/networkpolicy/egress-vpn-interaction.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/networkpolicy/kustomization.yaml" egress-vpn-interaction.yaml
                # AND the runtime config-byte DELIVERY half: the (dark) secret-projector
                # overlay + its MANUAL-sync Application. A tree that never selected the VPN
                # must not carry a DaemonSet that writes VPN key bytes onto node hostPaths,
                # even inert — so the whole dir + app go, not just a kustomize line.
                rm -f "${apps}/13e-egress-vpn.yaml"
                rm -rf "${tree}/manifests/egress-vpn"
                ;;
            workloadConsole)
                # The WORKLOAD CONSOLE is RBAC + route-access + an admin-bff deployment
                # overlay (the BFF endpoints live in the always-present admin-bff).
                # Deselecting it prunes the two-SA RBAC Application + its manifests (so
                # the SA token Secrets are never minted), the two route-access rows (the
                # gateway 404s the whole /bff/{admin,superadmin}/workloads/** prefix),
                # AND the deployment overlay workload-console-patch.yaml + its single
                # kustomization `- path:` line — so the dark admin-bff renders
                # byte-identical to a tree that never had the feature (no
                # WORKLOAD_CONSOLE_* env, no token mounts, Noop k8s seam). Selected, the
                # overlay survives and lights the gate + k8s seam; the DB master flag +
                # TTL'd grants still keep the console dark (docs/OPTIONAL-SERVICES.md
                # §7.2).
                rm -f "${apps}/14-workload-console-rbac.yaml"
                rm -rf "${tree}/manifests/workload-console-rbac"
                rm -f "${tree}/manifests/admin-bff-api/workload-console-patch.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/admin-bff-api/kustomization.yaml" 'path: workload-console-patch.yaml'
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-be-gateway \
                    '/bff/superadmin/workloads/**' '/bff/admin/workloads/**'
                ;;
            headwind)
                # Headwind MDM (managed phones) — DEFAULT-OFF, admin-only devops
                # service (Harbor/superadmin posture). Owns its bootstrap Application +
                # manifests dir + per-service ESO file + TWO routes on the EXISTING
                # tailnet superadmin-gateway (NOT be/fe — no gatewayHost of its own)
                # + their route-access rows. When deselected the superadmin console's
                # Headwind entry greys out (installed-services "false").
                rm -f "${apps}/23-headwind.yaml"
                rm -rf "${tree}/manifests/headwind"
                rm -f "${tree}/manifests/external-secrets/headwind-externalsecrets.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/external-secrets/kustomization.yaml" headwind-externalsecrets.yaml
                _opt_drop_route "${apps}/22-gateway-superadmin.yaml" headwind-console headwind-checkin
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-superadmin-gateway \
                    '/hmdm/manage/**' '/hmdm/rest/**'
                ;;
            attestation-server)
                # AttestationServer (GrapheneOS Hardware Trust Root) — DEFAULT-OFF,
                # admin-only devops service (Harbor/superadmin posture). Owns its
                # bootstrap Application + manifests dir + per-service ESO file +
                # THREE routes on the EXISTING tailnet superadmin-gateway (NOT be/fe
                # — no gatewayHost of its own) + their route-access rows. When
                # deselected the superadmin console's AttestationServer entry greys
                # out (installed-services "false").
                rm -f "${apps}/24-attestation-server.yaml"
                rm -rf "${tree}/manifests/attestation-server"
                rm -f "${tree}/manifests/external-secrets/attestation-server-externalsecrets.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/external-secrets/kustomization.yaml" attestation-server-externalsecrets.yaml
                _opt_drop_route "${apps}/22-gateway-superadmin.yaml" attestation-auditor attestation-status attestation-console
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-superadmin-gateway \
                    '/attest/auditor/**' '/attest/api/status' '/attest/api/create-account' '/attest/api/**'
                ;;
            tor)
                # NODE service (DISTRO tor daemon + a reconcile agent), not a cluster
                # Application. Prune the per-service NetworkPolicy interaction (file +
                # kustomization line) so an x86 image built WITHOUT tor does not ship the
                # tor-onion egress hook (honours the "PRUNED when not selected" contract
                # in tor-onion-marked.yaml + the kustomization comment). The net-vpn/tor
                # omission + the service-link SKIP are handled in the SVCS/PKGS gates.
                rm -f "${tree}/manifests/networkpolicy/tor-onion-marked.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/networkpolicy/kustomization.yaml" tor-onion-marked.yaml
                ;;
        esac
    done
    # Edge-AI model library: when selected, patch the edge-ai-models ConfigMap from
    # the --edge-ai-* flags (the model catalog/preload/runtime knobs exposed to the
    # mesh). EDGE_AI_RUNTIME always set (defaults ollama); models/default only if given.
    if _opt_selected edge-ai; then
        local mc="${tree}/manifests/edge-ai/models-configmap.yaml"
        if [ -f "${mc}" ]; then
            [ -n "${EDGE_AI_RUNTIME}" ]       && sed -i -E "s#^(  runtime: ).*#\\1\"${EDGE_AI_RUNTIME}\"#"       "${mc}"
            [ -n "${EDGE_AI_MODELS}" ]        && sed -i -E "s#^(  preload: ).*#\\1\"${EDGE_AI_MODELS}\"#"        "${mc}"
            [ -n "${EDGE_AI_MODEL_DEFAULT}" ] && sed -i -E "s#^(  default-model: ).*#\\1\"${EDGE_AI_MODEL_DEFAULT}\"#" "${mc}"
            info "Edge-AI model library: runtime=${EDGE_AI_RUNTIME} preload='${EDGE_AI_MODELS:-<default>}' default='${EDGE_AI_MODEL_DEFAULT:-<default>}'"
        fi
    fi
    # Shared social-ui (matrix + mastodon micro-frontends in ONE app) — remove only
    # when BOTH homeservers are deselected (otherwise the surviving platform keeps
    # its UI; the federation manifest greys out the absent one).
    if ! _opt_selected akkoma && ! _opt_selected tuwunel; then
        rm -f "${apps}/45-social-ui.yaml"
        info "OPTIONAL_SERVICES: both homeservers deselected — pruned shared apps/45-social-ui.yaml"
    fi
    # Repair a possible trailing comma: if pruning removed the LAST VALUES row of an
    # INSERT (the one that ended with ')' not '),'), the new last row ends with ','
    # -> a fatal trailing comma before ON CONFLICT. Re-terminate the last data row.
    _opt_fix_trailing_comma "${tree}/manifests/route-access/initdb/20-schema.sql"
    # Re-render the installed-services ConfigMap from the surviving selection so the
    # runtime ApplicationSet + admin console see the build-time install-state.
    _opt_render_installed_services
    # Seed each per-slug OptionalService CR's `enabled` from the SAME selection so the
    # (dark-by-default) admin-bff OptionalServiceReconciler's desired-state baseline
    # matches this build (a USB built WITHOUT a slug ships its CR enabled:false).
    _opt_render_optionalservice_cr
}
# Fix the dangling trailing comma left when the LAST VALUES row of an INSERT was
# pruned: rewrite the trailing '),' of the final data row before 'ON CONFLICT' to
# ')'. Operates only on the data row immediately preceding the ON CONFLICT line.
_opt_fix_trailing_comma() {
    local f="$1"
    [ -f "${f}" ] || return 0
    awk '
        { lines[NR]=$0 }
        END {
            # find the ON CONFLICT line; walk back to the last VALUES data row.
            oc=0
            for (i=NR; i>=1; i--) { if (lines[i] ~ /ON CONFLICT/) { oc=i; break } }
            if (oc>0) {
                for (i=oc-1; i>=1; i--) {
                    if (lines[i] ~ /^[[:space:]]*\(.*\)[[:space:]]*,([[:space:]]*--.*)?$/) {
                        # strip the comma right after the closing paren of this row.
                        sub(/\)[[:space:]]*,/, ")", lines[i]); break
                    }
                    if (lines[i] ~ /^[[:space:]]*\(.*\)([[:space:]]*--.*)?$/) break  # already terminated
                }
            }
            for (i=1;i<=NR;i++) print lines[i]
        }
    ' "${f}" > "${f}.tmp" && mv "${f}.tmp" "${f}"
}
# Drop a `- <resource>` line from a kustomize resources: list.
_opt_drop_kustomize_line() {
    local f="$1" res="$2"
    [ -f "${f}" ] || return 0
    sed -i -E "\\|^[[:space:]]*-[[:space:]]+${res}([[:space:]].*)?\$|d" "${f}"
}
# Delete one or more Spring-Cloud-Gateway route blocks (a `- id: <rid>` item plus
# its indented continuation lines) from a baked gateway app's helm values.
_opt_drop_route() {
    local f="$1"; shift
    [ -f "${f}" ] || return 0
    local rid
    for rid in "$@"; do
        awk -v rid="${rid}" '
            BEGIN { skip=0; ind=-1 }
            {
                line=$0
                # indentation of this line (leading spaces)
                match(line, /^ */); cur=RLENGTH
                if (skip) {
                    # Stop skipping once we reach ANY non-blank line at or below the
                    # captured item indent — including a comment, since a trailing
                    # comment block at this indent may document the NEXT surviving
                    # route rather than the one being removed (excluding comments
                    # from this check would silently swallow that documentation).
                    if (line !~ /^ *$/ && cur<=ind) { skip=0 }
                    else { next }
                }
                if (line ~ ("^ *- id: " rid "$")) { skip=1; ind=cur; next }
                print line
            }
        ' "${f}" > "${f}.tmp" && mv "${f}.tmp" "${f}"
    done
}
# Drop the `- <host-prefix>...` extraHosts entry (+ any leading comment block) for
# a games-style host from a gateway app's ingress.extraHosts.
_opt_drop_extrahost() {
    local f="$1" prefix="$2"
    [ -f "${f}" ] || return 0
    sed -i -E "\\|^[[:space:]]*-[[:space:]]+\"?${prefix}[^[:space:]\"]*\"?[[:space:]]*\$|d" "${f}"
}
# Delete gateway_route_access INSERT VALUES rows matching (gateway, url_pattern)
# from the baked schema.sql. Rows are `  ('<gw>', '<pat>', 'ROLE', bool), -- ...`.
# Uses awk with LITERAL substring matching (the url_patterns carry ** / . which are
# regex metachars) on the row's leading `('<gw>', '<pat>',` so only the data rows
# are removed and the surrounding comments are left intact.
_opt_drop_rows() {
    local f="$1" gw="$2"; shift 2
    [ -f "${f}" ] || return 0
    local pat
    for pat in "$@"; do
        awk -v gw="${gw}" -v pat="${pat}" '
            BEGIN { needle = "(\x27" gw "\x27" }   # ('gw'   (x27 = single quote)
            {
                line=$0
                # Strip leading whitespace for the prefix test.
                t=line; sub(/^[[:space:]]+/, "", t)
                if (index(t, needle)==1) {
                    # This is a VALUES row for THIS gateway; check the url_pattern is
                    # the 2nd quoted field and equals pat exactly.
                    rest=t; sub(/^\([[:space:]]*\x27[^\x27]*\x27[[:space:]]*,[[:space:]]*\x27/, "", rest)
                    # rest now begins with the url_pattern; cut at its closing quote.
                    q=index(rest, "\x27")
                    if (q>0 && substr(rest,1,q-1)==pat) { next }
                }
                print line
            }
        ' "${f}" > "${f}.tmp" && mv "${f}.tmp" "${f}"
    done
}
# Render manifests/policy/installed-services-configmap.yaml install-state booleans
# from the surviving OPTIONAL_SERVICES selection (the runtime ApplicationSet +
# admin console read this). Idempotent: rewrites the data: block in place.
_opt_render_installed_services() {
    local cm="${SYSROOT}/var/lib/hugmesh/cluster/manifests/policy/installed-services-configmap.yaml"
    [ -f "${cm}" ] || return 0
    local slug val
    for slug in akkoma tuwunel phpbb games owncast tube character-studio character-forge headwind attestation-server workloadConsole edge-ai edge-ai-analysis edge-ai-tts; do
        if _opt_selected "${slug}"; then val="true"; else val="false"; fi
        # '#'-delimited so the (true|false) alternation does not collide with the delimiter.
        sed -i -E "s#^([[:space:]]*)${slug}:[[:space:]]*\"(true|false)\"#\\1${slug}: \"${val}\"#" "${cm}"
    done
    info "OPTIONAL_SERVICES: rendered installed-services ConfigMap (selected: ${OPTIONAL_SERVICES:-none})"
}
# Flip the `enabled:` value of ONE OptionalService CR (the block whose `slug: <slug>`)
# in the baked seed file. awk anchors on the slug line then rewrites the FIRST enabled
# line after it, preserving indentation (sub only touches the matched substring). The
# end-anchored slug compare keeps edge-ai distinct from edge-ai-analysis/edge-ai-tts.
_opt_set_cr_enabled() {
    local f="$1" slug="$2" val="$3"
    [ -f "${f}" ] || return 0
    awk -v slug="${slug}" -v val="${val}" '
        /^[[:space:]]*slug:[[:space:]]/ {
            s=$0; sub(/^[[:space:]]*slug:[[:space:]]*/,"",s); sub(/[[:space:]]*$/,"",s)
            arm=(s==slug)
        }
        arm && /^[[:space:]]*enabled:[[:space:]]*(true|false)[[:space:]]*$/ {
            sub(/enabled:[[:space:]]*(true|false)/, "enabled: " val); arm=0
        }
        { print }
    ' "${f}" > "${f}.tmp" && mv "${f}.tmp" "${f}"
}
# Seed the per-slug OptionalService CRs (manifests/optional-services-operator/
# seed-optionalservices.yaml) from the resolved OPTIONAL_SERVICES selection, mirroring
# _opt_render_installed_services above (the CR is the runtime desired-state twin of the
# installed-services ConfigMap boolean). coturn stays at its false baseline (not in the
# selection loop, matching the ConfigMap); anubis is ENV-conditional and is NOT rewritten
# on x86 (as with the ConfigMap here) — its CR keeps the safe test baseline.
_opt_render_optionalservice_cr() {
    local seed="${SYSROOT}/var/lib/hugmesh/cluster/manifests/optional-services-operator/seed-optionalservices.yaml"
    [ -f "${seed}" ] || return 0
    local slug val
    for slug in akkoma tuwunel phpbb games owncast tube character-studio character-forge edge-ai edge-ai-analysis edge-ai-tts; do
        if _opt_selected "${slug}"; then val="true"; else val="false"; fi
        _opt_set_cr_enabled "${seed}" "${slug}" "${val}"
    done
    info "OPTIONAL_SERVICES: seeded OptionalService CR enabled flags (selected: ${OPTIONAL_SERVICES:-none})"
}

# ============================================================================
# MANAGED BACKING SERVICES — gate_backing_services() + helpers. See
# specs/cluster/backing-services.yaml (the DECLARED contract; this is its
# executable twin — keep the case arms in sync). Applied AFTER
# gate_optional_services(). SELF-HOSTED IS THE DEFAULT: an EMPTY MANAGED_SERVICES
# selection returns immediately and the baked tree is byte-identical mainline
# (the #1 invariant). Managed mode, per selected id: prune the in-mesh workload
# app+manifests, repoint the consumer endpoint env value(s) at the operator-
# supplied endpoint, keep the ESO Secret names/Vault paths (creds ride the KEYS
# USB via gen-cluster-secrets, never argv/git). Fail-closed: unknown id / tier-3
# (docs-only) id / malformed endpoint => FATAL.
# ============================================================================
# Tier 1-2 ids (managed IS implemented). Tier 3 ids are mode-locked self-hosted.
_MGD_TIER12_IDS="velero-objectstore smtp kafka clickhouse federation-bundles postgres-admin-bff postgres-user-bff postgres-mod-bff postgres-forum-bff postgres-wiki-bff postgres-casdoor"
_MGD_TIER3_IDS="cassandra harbor vault-kv vault-pki"
_mgd_die() { echo "FATAL(managed-services): $1" >&2; exit 1; }
# The tier-3 blocker one-liner (WHY --managed-service <id> is refused in v1).
_mgd_tier3_blocker() {
    case "$1" in
        cassandra) echo "auth/TLS live only in the dark cassandra-hardening overlay; Keyspaces/Cosmos need TLS+SigV4 on 9142 with no live-path driver wiring";;
        harbor)    echo "registry host literal in ~30 kustomizations + dockerconfigjson + kaniko; robot-account Job has no ECR/ACR analog; 12h ECR tokens break static pull secrets; loses air-gap";;
        vault-kv)  echo "mechanical but broad: 1 ClusterSecretStore + ~90 remoteRef renames + writer re-point + drop vault-token seeding for IRSA — deferred wave";;
        vault-pki) echo "hardest: VaultDynamicSecret is Vault-only; needs a cert-manager re-architecture keeping <app>-mtls names; USB CA-custody has no managed analog";;
        *)         echo "tier-3 managed swap not implemented in v1";;
    esac
}
# Endpoint (RHS of id=endpoint) for a selected id; exit 1 if not selected.
_mgd_endpoint() {
    local want="$1" tok id
    for tok in ${MANAGED_SERVICES}; do
        id="${tok%%=*}"
        [ "${id}" = "${want}" ] && { printf '%s' "${tok#*=}"; return 0; }
    done
    return 1
}
_mgd_selected()  { _mgd_endpoint "$1" >/dev/null 2>&1; }
_mgd_is_tier12() { case " ${_MGD_TIER12_IDS} " in *" $1 "*) return 0;; esac; return 1; }
_mgd_is_tier3()  { case " ${_MGD_TIER3_IDS} "  in *" $1 "*) return 0;; esac; return 1; }
# Fail-closed validation of the whole MANAGED_SERVICES selection.
validate_managed_services() {
    local tok id ep
    for tok in ${MANAGED_SERVICES}; do
        case "${tok}" in *=*) : ;; *) _mgd_die "'${tok}' is malformed — expected id=endpoint";; esac
        id="${tok%%=*}"; ep="${tok#*=}"
        [ -n "${id}" ] || _mgd_die "empty id in token '${tok}'"
        # Endpoint shape: non-empty and must carry a host (not a bare `:port`). Note
        # whitespace can't reach here — word-splitting already tokenises on it.
        [ -n "${ep}" ] || _mgd_die "'${id}' has an empty endpoint (id=endpoint required)"
        case "${ep}" in :*) _mgd_die "'${id}' endpoint '${ep}' has no host (bare :port)";; esac
        if _mgd_is_tier3 "${id}"; then
            _mgd_die "'${id}' is TIER-3 (mode-locked self-hosted, docs-only in v1) — $(_mgd_tier3_blocker "${id}"). See docs/MANAGED-SERVICES.md."
        fi
        _mgd_is_tier12 "${id}" || _mgd_die "unknown backing-service id '${id}'. Known tier-1/2: ${_MGD_TIER12_IDS}. Tier-3 (docs-only): ${_MGD_TIER3_IDS}."
    done
}
# Rewrite the `value: "…"` line immediately following `- name: <ENV>` in a k8s
# container env list (exact-name anchored so SPRING_R2DBC_URL != _USERNAME; FIRST
# occurrence only; a valueFrom block is left untouched).
_mgd_rewrite_env() {
    local f="$1" env="$2" val="$3"
    [ -f "${f}" ] || return 0
    awk -v env="${env}" -v val="${val}" '
        BEGIN{done=0}
        {
            if (!done && $0 ~ ("^[[:space:]]*- name: " env "[[:space:]]*$")) {
                print
                if ((getline nl) > 0) {
                    if (nl ~ /^[[:space:]]*value:[[:space:]]*/) {
                        match(nl, /^[[:space:]]*/); ind=substr(nl,1,RLENGTH)
                        print ind "value: \"" val "\""; done=1; next
                    } else { print nl; next }
                }
                next
            }
            print
        }' "${f}" > "${f}.tmp" && mv "${f}.tmp" "${f}"
}
# Per-service Postgres: repoint BOTH URLs (R2DBC + Liquibase), delete the DB app +
# manifests. Guarded on the consumer file existing (phpbb may have pruned it first).
_mgd_pg() {  # tree endpoint dbname consumer_manifest db_app db_manifest
    local tree="$1" ep="$2" db="$3" cons="$4" dbapp="$5" dbman="$6"
    _mgd_rewrite_env "${tree}/${cons}" SPRING_R2DBC_URL    "r2dbc:postgresql://${ep}/${db}"
    _mgd_rewrite_env "${tree}/${cons}" SPRING_LIQUIBASE_URL "jdbc:postgresql://${ep}/${db}"
    rm -f  "${tree}/${dbapp}"
    rm -rf "${tree}/${dbman}"
}
# Casdoor PG: NO app prune (05-casdoor IS the IdP). Flip host+port+sslmode inside
# the single libpq dataSourceName string (dbname=casdoor kept), drop the bundled
# pg.yaml manifest + its kustomization line. Managed PG enforces TLS -> require.
_mgd_pg_casdoor() {  # tree endpoint(host[:port])
    local tree="$1" ep="$2" h p
    h="${ep%%:*}"; p="5432"; case "${ep}" in *:*) p="${ep##*:}";; esac
    local cm="${tree}/manifests/casdoor/app-conf-configmap.yaml"
    [ -f "${cm}" ] && sed -i -E "s#host=[^ ]+ port=[0-9]+#host=${h} port=${p}#; s#sslmode=[a-z-]+#sslmode=require#" "${cm}"
    rm -f "${tree}/manifests/casdoor/pg.yaml"
    _opt_drop_kustomize_line "${tree}/manifests/casdoor/kustomization.yaml" pg.yaml
}
# Velero BSL: rewrite bucket/region/s3Url in the FIRST YAML doc only (the VSL doc
# after '---' has its own region). endpoint=aws => real S3 (drop s3Url); else the
# S3-compatible URL. bucket/region from MANAGED_VELERO_{BUCKET,REGION} env.
_mgd_velero() {  # tree endpoint(aws|url)
    local tree="$1" ep="$2"
    local bsl="${tree}/manifests/velero/backupstoragelocation.yaml"
    [ -f "${bsl}" ] || return 0
    local bucket="${MANAGED_VELERO_BUCKET:-hugmesh-backups}"
    local region="${MANAGED_VELERO_REGION:-us-east-1}"
    local s3url="${ep}"; [ "${ep}" = "aws" ] && s3url=""
    awk -v bucket="${bucket}" -v region="${region}" -v s3url="${s3url}" '
        BEGIN{doc=0}
        /^---/ { doc++ }
        {
            if (doc==0) {
                if ($0 ~ /^[[:space:]]*bucket:[[:space:]]/) { match($0,/^[[:space:]]*/); print substr($0,1,RLENGTH) "bucket: " bucket; next }
                if ($0 ~ /^[[:space:]]*region:[[:space:]]/) { match($0,/^[[:space:]]*/); print substr($0,1,RLENGTH) "region: " region; next }
                if ($0 ~ /^[[:space:]]*s3Url:[[:space:]]/)  {
                    if (s3url=="") next
                    match($0,/^[[:space:]]*/); print substr($0,1,RLENGTH) "s3Url: " s3url; next
                }
            }
            print
        }' "${bsl}" > "${bsl}.tmp" && mv "${bsl}.tmp" "${bsl}"
}
# Federation bundles: flip APP_BUNDLES_STORAGE=s3 + inject APP_BUNDLES_S3_* env
# after APP_BUNDLES_DIR (idempotent). endpoint = bucket | bucket@https://endpoint.
# Creds ride the AWS default chain (IRSA/env) — no static-key Secret.
_mgd_fed_bundles() {  # tree endpoint
    local tree="$1" ep="$2"
    local dep="${tree}/manifests/federation-api/deployment.yaml"
    [ -f "${dep}" ] || return 0
    local bucket="${ep%%@*}" endpoint=""
    case "${ep}" in *@*) endpoint="${ep#*@}";; esac
    local region="${MANAGED_FEDERATION_BUNDLES_REGION:-us-east-1}"
    _mgd_rewrite_env "${dep}" APP_BUNDLES_STORAGE "s3"
    grep -q 'APP_BUNDLES_S3_BUCKET' "${dep}" && return 0
    awk -v bkt="${bucket}" -v ep="${endpoint}" -v rgn="${region}" '
        { print }
        /^[[:space:]]*- name: APP_BUNDLES_DIR[[:space:]]*$/ { match($0,/^[[:space:]]*/); nind=substr($0,1,RLENGTH); pend=1; next }
        pend==1 && /^[[:space:]]*value:/ {
            print nind "- name: APP_BUNDLES_S3_BUCKET";   print nind "  value: \"" bkt "\""
            print nind "- name: APP_BUNDLES_S3_ENDPOINT"; print nind "  value: \"" ep "\""
            print nind "- name: APP_BUNDLES_S3_REGION";   print nind "  value: \"" rgn "\""
            pend=0
        }' "${dep}" > "${dep}.tmp" && mv "${dep}.tmp" "${dep}"
}
# Bake /etc/hugmesh/backing-services.conf (id=endpoint list; NO creds) +
# README-MANAGED.md (the standing honesty notes) into the baked tree.
_mgd_bake_readme() {  # tree
    local tree="$1"; local rd="${tree}/README-MANAGED.md"
    { echo "# Managed backing services (this image)"; echo
      echo "This image points one or more in-mesh backing services at a hosted cloud"
      echo "endpoint. Self-hosted is the platform default; only the ids listed in"
      echo "\`/etc/hugmesh/backing-services.conf\` were repointed. Full runbooks:"
      echo "docs/MANAGED-SERVICES.md."; echo
      echo "## Selected"; echo
      local id ep
      for id in ${_MGD_TIER12_IDS}; do _mgd_selected "${id}" || continue; ep="$(_mgd_endpoint "${id}")"; echo "- \`${id}\` -> \`${ep}\`"; done
      echo
      echo "## Honesty notes (READ before relying on this image)"; echo
      echo "- **TLS delta:** in-mesh Postgres/ClickHouse run plaintext. Managed RDS /"
      echo "  Azure-PG / ClickHouse-Cloud enforce TLS — add \`?ssl=true&sslMode=require\`"
      echo "  to the URLs and the managed CA to each app's truststore OUT OF BAND. The"
      echo "  build repoints the HOST only; it does not invent TLS params (except the"
      echo "  Casdoor DSN sslmode, flipped to \`require\`)."
      echo "- **Role-split SQL:** each DB's \`initdb/10-roles.sh\` (owner + least-priv app"
      echo "  role) runs via docker-entrypoint-initdb.d and NEVER runs on RDS. Run that"
      echo "  role-split SQL against the managed DB by hand."
      echo "- **Citus:** federation-db + route-access-db need Citus (initdb/90-citus.sh)"
      echo "  which vanilla RDS lacks — they are NOT managed ids in v1 (Azure Cosmos DB"
      echo "  for PostgreSQL does have Citus)."
      echo "- **Creds:** operator-supplied only, delivered via ESO/Vault on the KEYS USB"
      echo "  (gen-cluster-secrets managed block). Never minted, never in this image."
    } > "${rd}"
}
gate_backing_services() {
    local tree="${SYSROOT}/var/lib/hugmesh/cluster"
    local apps="${tree}/apps"
    [ -d "${apps}" ] || return 0
    # #1 INVARIANT: empty selection => zero change. Tokens are WHITESPACE-separated
    # (all whitespace: space/tab/newline) — commas are LITERAL (a kafka endpoint is itself a comma-list of brokers).
    [ -z "${MANAGED_SERVICES//[[:space:]]/}" ] && return 0
    validate_managed_services
    local id ep churl hostport
    for id in ${_MGD_TIER12_IDS}; do
        _mgd_selected "${id}" || continue
        ep="$(_mgd_endpoint "${id}")"
        info "MANAGED_SERVICES: '${id}' -> '${ep}' — pruning in-mesh workload + repointing consumers"
        case "${id}" in
            postgres-admin-bff) _mgd_pg "${tree}" "${ep}" adminbff manifests/admin-bff-api/deployment.yaml apps/30-admin-bff-db.yaml manifests/admin-bff-db ;;
            postgres-user-bff)  _mgd_pg "${tree}" "${ep}" userbff  manifests/user-bff-api/deployment.yaml  apps/34-user-bff-db.yaml  manifests/user-bff-db ;;
            postgres-mod-bff)   _mgd_pg "${tree}" "${ep}" modbff   manifests/mod-bff-api/deployment.yaml   apps/32-mod-bff-db.yaml   manifests/mod-bff-db ;;
            postgres-forum-bff) _mgd_pg "${tree}" "${ep}" forumbff manifests/forum-bff-api/deployment.yaml apps/38-forum-bff-db.yaml manifests/forum-bff-db ;;
            postgres-wiki-bff)  _mgd_pg "${tree}" "${ep}" wikibff  manifests/wiki-bff-api/deployment.yaml  apps/34a-wiki-bff-db.yaml manifests/wiki-bff-db ;;
            postgres-casdoor)   _mgd_pg_casdoor "${tree}" "${ep}" ;;
            kafka)
                _mgd_rewrite_env "${tree}/manifests/admin-bff-api/deployment.yaml" SPRING_KAFKA_BOOTSTRAP_SERVERS "${ep}"
                rm -f "${apps}/35-analytics-kafka.yaml"; rm -rf "${tree}/manifests/analytics/kafka"
                ;;
            clickhouse)
                churl="${ep}"; case "${ep}" in *"://"*) ;; *) churl="https://${ep}";; esac
                _mgd_rewrite_env "${tree}/manifests/admin-bff-api/deployment.yaml" CLICKHOUSE_URL "${churl}"
                hostport="${ep#*://}"
                [ -f "${tree}/manifests/observability/deployment.yaml" ] && \
                    sed -i -E "s#(clickhouse://[^@]+@)[^/]+#\\1${hostport}#" "${tree}/manifests/observability/deployment.yaml"
                rm -f "${apps}/35-analytics-clickhouse.yaml"; rm -rf "${tree}/manifests/analytics/clickhouse"
                ;;
            velero-objectstore) _mgd_velero "${tree}" "${ep}" ;;
            federation-bundles) _mgd_fed_bundles "${tree}" "${ep}" ;;
            smtp) : ;;  # pure creds/host via gen-cluster-secrets MAIL_*; recorded in the conf only
        esac
    done
    mkdir -p "${SYSROOT}/etc/hugmesh"
    { echo "# Managed backing services baked into this image (see docs/MANAGED-SERVICES.md)."
      echo "# Self-hosted is the default; only the ids below were repointed at a hosted endpoint."
      echo "# Format: <id>=<endpoint>  (creds are NOT here — they ride ESO/Vault via the KEYS USB)."
      for id in ${_MGD_TIER12_IDS}; do _mgd_selected "${id}" || continue; echo "${id}=$(_mgd_endpoint "${id}")"; done
    } > "${SYSROOT}/etc/hugmesh/backing-services.conf"
    chmod 644 "${SYSROOT}/etc/hugmesh/backing-services.conf"
    _mgd_bake_readme "${tree}"
    info "MANAGED_SERVICES: baked /etc/hugmesh/backing-services.conf + README-MANAGED.md"
}

# Parameterize the games-realm OIDC identity on GAMES_DOMAIN. rebrand_sysroot does
# NOT touch the .games literals (its rules match hugmesh.net / hugmesh-),
# so the games host + issuer + redirects would otherwise stay hugmesh.games and
# break iss-strict JWT validation under the subdomain default. Runs UNCONDITIONALLY
# (even for the default brand) and BEFORE rebrand_sysroot so the default literal
# games.hugmesh.net composes with the hugmesh.net->CLUSTER_DOMAIN
# rule. A custom GAMES_DOMAIN (e.g. <brand>.games) is rebrand-neutral.
parameterize_games_domain() {
    local tree="${SYSROOT}/var/lib/hugmesh/cluster"
    [ -d "${tree}" ] || return 0
    local f n=0
    # GAMES_DOMAIN is allowlisted ([a-z0-9.-]) at parse; escape it against the sed
    # replacement metacharacters (\ & |) for defense-in-depth — matching how every other
    # rendered field is handled, so this stays injection-proof if the validator is ever
    # loosened. (The '#'-delimited sink below is also safe: the allowlist excludes '#'.)
    local gd_e; gd_e="$(_sed_rep_escape "${GAMES_DOMAIN}")"
    # URL-SCHEME-ANCHORED: only rewrite hugmesh.games when it is a HOST (right
    # after the // of https://...), so the games-realm origin/issuer/redirect/website
    # URLs flip to ${GAMES_DOMAIN} while the canonical IMAGE repo paths
    # (hugmesh/hugmesh.games-backend, .../hugmesh.games/backend) are
    # left untouched. id.hugmesh.games -> id.${GAMES_DOMAIN}; bare host -> ${GAMES_DOMAIN}.
    while IFS= read -r -d '' f; do
        if grep -q '//id\.hugmesh\.games\|//hugmesh\.games' "${f}" 2>/dev/null; then
            sed -i -E \
                -e "s|//id\\.hugmesh\\.games|//id.${gd_e}|g" \
                -e "s|//hugmesh\\.games|//${gd_e}|g" \
                "${f}"
            n=$((n+1))
        fi
    done < <(find "${tree}" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.sql' \) -print0 2>/dev/null)
    info "Games domain: parameterized games host URLs -> ${GAMES_DOMAIN} in ${n} file(s)"
    # The games PUBLIC host literal (gateway-be route host + ingress extraHost) is
    # "games.hugmesh.net" so it composes with the hugmesh.net ->
    # CLUSTER_DOMAIN rebrand into games.<CLUSTER_DOMAIN> = the DEFAULT GAMES_DOMAIN.
    # If the operator set a CUSTOM GAMES_DOMAIN (e.g. the real <brand>.games TLD),
    # the host must follow it instead of the subdomain default — rewrite it here,
    # BEFORE rebrand (which would otherwise only map the hugmesh.net suffix).
    if [ "${GAMES_DOMAIN}" != "games.hugmesh.net" ]; then
        local be="${tree}/apps/20-gateway-be.yaml"
        [ -f "${be}" ] && sed -i -E "s#games\\.hugmesh\\.net#${gd_e}#g" "${be}"
        info "Games domain: custom GAMES_DOMAIN — games host rewritten to ${GAMES_DOMAIN}"
    fi
}

gate_env_apps() {
    local apps="${SYSROOT}/var/lib/hugmesh/cluster/apps"
    [ -d "${apps}" ] || return 0
    if [ "${ENV}" = "prod" ]; then
        rm -f "${apps}/09-lan-dns.yaml" && \
            info "ENV=prod: pruned LAN wildcard-DNS app 09-lan-dns.yaml from the baked tree"
        rewrite_prod_image_tags
    else
        # ENV=test
        rm -f "${apps}/12-cloudflared.yaml" && \
            info "ENV=test: pruned go-live app 12-cloudflared.yaml from the baked tree"
        case "${CLUSTER_DOMAIN}" in
            *.test) info "ENV=test: LAN wildcard DNS authoritative for ${CLUSTER_DOMAIN}" ;;
            *) rm -f "${apps}/09-lan-dns.yaml" && \
                   warn "ENV=test but domain '${CLUSTER_DOMAIN}' is not .test — pruned 09-lan-dns.yaml so it cannot hijack a real domain (use brands/local.conf / 'make local' for a .test LAN build)" ;;
        esac
    fi

    # ── RELEASE_STATE gate (K8s-manifest enforcement — Layer 2 / the PRIMARY
    # mechanism; INDEPENDENT of the ENV=prod/test split above). RELEASE_STATE
    # is threaded from brand.conf like CLUSTER_DOMAIN (default "internal";
    # validated against CLUSTER_DOMAIN in generate-brand-repos.sh). A
    # RELEASE_STATE=internal build stays LAN/tailnet-only regardless of ENV,
    # so this block runs for BOTH branches above — which is why the prod
    # branch no longer `return`s early.
    #
    # This GENERALIZES the existing tailnet-only superadmin-gateway pattern
    # (apps/22-gateway-superadmin.yaml + tier-ingress.yaml's superadmin
    # carve-out) to the WHOLE brand: when not public, the public ingress
    # controller never ships at all, both public-facing gateways serve ONLY
    # the internal ingress class, and the tier-ingress NetworkPolicy admits
    # from the internal facade instead of the (now-absent) public one.
    #
    # Layer 3 (bake_host_firewall(), the host nftables backstop) is called
    # right after gate_env_apps() in the main build flow and enforces the
    # SAME posture independently, at the netfilter layer.
    if [ "${RELEASE_STATE:-internal}" != "public" ]; then
        local cluster="${SYSROOT}/var/lib/hugmesh/cluster"
        local netpol="${cluster}/manifests/networkpolicy/tier-ingress.yaml"

        # a) The public ingress controller Application never ships — nothing
        #    for a public IngressClass to bind to.
        rm -f "${apps}/10-ingress-nginx.yaml" && \
            info "RELEASE_STATE=internal: pruned the public ingress controller 10-ingress-nginx.yaml from the baked tree"

        # b) Both public-facing gateways (be/fe) are repointed to serve ONLY
        #    the internal ingress class (11-ingress-nginx-internal.yaml,
        #    pinned to the pki node) instead of the now-absent public class.
        local gw
        for gw in "${apps}/20-gateway-be.yaml" "${apps}/20-gateway-fe.yaml"; do
            [ -f "${gw}" ] && sed -i -E 's/^([[:space:]]*className: )nginx$/\1nginx-internal/' "${gw}"
        done
        info "RELEASE_STATE=internal: be/fe gateways repointed className nginx -> nginx-internal"

        # c) tier-ingress.yaml's backend/frontend admit-lists currently let
        #    the PUBLIC ingress-nginx namespace in; with the public
        #    controller gone, admit from ingress-nginx-internal instead (the
        #    pki namespace already carries this exact carve-out — see (a)/(b)
        #    above and 22-gateway-superadmin.yaml).
        [ -f "${netpol}" ] && sed -i -E \
            -e 's/(kubernetes\.io\/metadata\.name: )ingress-nginx( \} \})/\1ingress-nginx-internal\2/' \
            -e 's/# public facade/# internal facade (RELEASE_STATE=internal)/' \
            "${netpol}" && \
            info "RELEASE_STATE=internal: tier-ingress.yaml admits ingress-nginx-internal instead of the public ingress-nginx"
    fi
}

# Layer 3 (defense-in-depth): host-level nftables backstop for RELEASE_STATE,
# INDEPENDENT of the K8s ingress-class/NetworkPolicy split in gate_env_apps()
# above and of firewalld (/etc/firewalld) — even if either is ever
# misconfigured, an internal-only device still refuses public 80/443 at the
# netfilter layer. Ships the reconcile agent (owns render + `nft -f` load,
# scoped to its OWN nftables table so firewalld's tables are untouched) + its
# OpenRC oneshot (ordered before containerd/kubelet/tailscaled — see the
# init.d depend()) + its 60s convergence cron UNCONDITIONALLY (core
# hardening, not opt-in — unlike the STAGED vpn/tor/domain reconciles). Also
# bakes /etc/hugmesh/release-state, parallel to the existing
# /etc/hugmesh/cluster-domain bake below. The FIRST-EVER ruleset load
# happens at first boot (the oneshot), rendered from this baked value + the
# (absent-by-default) go-live marker, so there is no separate build-time
# nftables.conf to keep in sync.
bake_host_firewall() {
    mkdir -p "${SYSROOT}/usr/sbin" "${SYSROOT}/usr/lib/hugmesh" "${SYSROOT}/etc/init.d" "${SYSROOT}/etc/cron.d" "${SYSROOT}/etc/hugmesh"
    cp "${SHARED_SPECS}/usr/sbin/hugmesh-firewall-reconcile"   "${SYSROOT}/usr/sbin/hugmesh-firewall-reconcile"
    chmod +x "${SYSROOT}/usr/sbin/hugmesh-firewall-reconcile"
    cp "${SHARED_SPECS}/etc/init.d/hugmesh-firewall-reconcile" "${SYSROOT}/etc/init.d/hugmesh-firewall-reconcile"
    chmod +x "${SYSROOT}/etc/init.d/hugmesh-firewall-reconcile"
    cp "${SHARED_SPECS}/etc/cron.d/hugmesh-firewall-reconcile" "${SYSROOT}/etc/cron.d/hugmesh-firewall-reconcile"
    # ── coturn public-TURN node firewall: the marker-gated opener/backstop for the
    #    OPT-IN coturn-public overlay (docs/COTURN.md §5). Baked unconditionally
    #    alongside the release-gate reconcile — inert-closed until an operator
    #    touches /etc/hugmesh/coturn-public on the relay node (then it admits
    #    3478/5349 UDP+TCP + the 49152-49200/udp relay window through firewalld
    #    at runtime and lifts its own nftables backstop; converges <=60s).
    cp "${SHARED_SPECS}/usr/sbin/hugmesh-coturn-firewall"      "${SYSROOT}/usr/sbin/hugmesh-coturn-firewall"
    chmod +x "${SYSROOT}/usr/sbin/hugmesh-coturn-firewall"
    cp "${SHARED_SPECS}/etc/init.d/hugmesh-coturn-firewall"    "${SYSROOT}/etc/init.d/hugmesh-coturn-firewall"
    chmod +x "${SYSROOT}/etc/init.d/hugmesh-coturn-firewall"
    cp "${SHARED_SPECS}/etc/cron.d/hugmesh-coturn-firewall"    "${SYSROOT}/etc/cron.d/hugmesh-coturn-firewall"
    # ── Go-Live wizard: the human-facing effector of this same firewall-reconcile /
    #    release-state mechanism (driver writes /etc/hugmesh/go-live; reconcile
    #    converges <=60s). Baked unconditionally alongside reconcile — inert until the
    #    marker is written. Front-ends: -cli (thin CLI) and -menu (thin ncurses console).
    cp "${SHARED_SPECS}/usr/sbin/hugmesh-go-live"              "${SYSROOT}/usr/sbin/hugmesh-go-live"
    chmod +x "${SYSROOT}/usr/sbin/hugmesh-go-live"
    cp "${SHARED_SPECS}/usr/sbin/hugmesh-go-live-cli"          "${SYSROOT}/usr/sbin/hugmesh-go-live-cli"
    chmod +x "${SYSROOT}/usr/sbin/hugmesh-go-live-cli"
    cp "${SHARED_SPECS}/usr/sbin/hugmesh-go-live-menu"         "${SYSROOT}/usr/sbin/hugmesh-go-live-menu"
    chmod +x "${SYSROOT}/usr/sbin/hugmesh-go-live-menu"
    cp "${SHARED_SPECS}/usr/lib/hugmesh/go-live-providers.sh"  "${SYSROOT}/usr/lib/hugmesh/go-live-providers.sh"
    # ── Cloud-deploy wizard: go-live's SIBLING driver+registry (plan/apply/status/
    #    destroy of a PACKAGED x86 image onto aws-ec2/azure-image/openshift-cnv/
    #    generic-qcow2). Baked beside the go-live set — inert until an operator runs
    #    it: plan is a pure offline render, apply/destroy are TTY-gated (no --yes).
    cp "${SHARED_SPECS}/usr/sbin/hugmesh-cloud-deploy"         "${SYSROOT}/usr/sbin/hugmesh-cloud-deploy"
    chmod +x "${SYSROOT}/usr/sbin/hugmesh-cloud-deploy"
    cp "${SHARED_SPECS}/usr/lib/hugmesh/cloud-deploy-providers.sh" "${SYSROOT}/usr/lib/hugmesh/cloud-deploy-providers.sh"
    echo "${RELEASE_STATE:-internal}" > "${SYSROOT}/etc/hugmesh/release-state"
    # ── Go-Live web-UI effector: the 4th front-end (admin-bff's web console) can only
    #    RECORD a signed intent (it runs in a pod, can't touch this host's filesystem);
    #    this agent is what actually drives the SAME driver's commit/rollback for a
    #    web-originated intent. Baked alongside the driver it depends on (harmlessly
    #    inert without it — same fail-closed gate as every reconcile agent: missing
    #    verify lib / node.env / baked pubkey -> keep cache, exit 0, apply nothing).
    cp "${SHARED_SPECS}/usr/sbin/hugmesh-go-live-reconcile"     "${SYSROOT}/usr/sbin/hugmesh-go-live-reconcile"
    chmod +x "${SYSROOT}/usr/sbin/hugmesh-go-live-reconcile"
    cp "${SHARED_SPECS}/usr/lib/hugmesh/golive-verify.sh"       "${SYSROOT}/usr/lib/hugmesh/golive-verify.sh"
    cp "${SHARED_SPECS}/etc/init.d/hugmesh-go-live-reconcile"   "${SYSROOT}/etc/init.d/hugmesh-go-live-reconcile"
    chmod +x "${SYSROOT}/etc/init.d/hugmesh-go-live-reconcile"
    cp "${SHARED_SPECS}/etc/cron.d/hugmesh-go-live-reconcile"   "${SYSROOT}/etc/cron.d/hugmesh-go-live-reconcile"
    info "RELEASE_STATE=${RELEASE_STATE:-internal}: baked the host nftables backstop (hugmesh-firewall-reconcile renders + loads the live ruleset at boot + every 60s) + the go-live wizard (driver/registry/CLI/ncurses front-ends) + the web-UI go-live effector (hugmesh-go-live-reconcile)"
}

# Rebrand the baked cluster tree (no-op for default hugmesh naming).
rebrand_sysroot() {
    if [ "${BRAND}" = "hugmesh" ] && [ "${CLUSTER_DOMAIN}" = "hugmesh.net" ] \
       && [ "${ORG}" = "hugmesh" ] && [ "${BRAND_TITLE}" = "HugMesh Systems" ]; then
        info "Branding: default (hugmesh) — no rebrand"; return 0
    fi
    banner "Rebranding baked config -> brand=${BRAND} domain=${CLUSTER_DOMAIN} org=${ORG}"
    local org_lc; org_lc="$(echo "${ORG}" | tr '[:upper:]' '[:lower:]')"
    # All of these land on the REPLACEMENT side of `sed s|..|VALUE|` across the baked
    # cluster tree (configs that later execute on the device); escape sed metacharacters
    # so a tainted brand/domain/org cannot inject a second sed command or corrupt output.
    local _btitle _orglc _org _games _domain _brand _hproj
    _btitle="$(_sed_rep_escape "${BRAND_TITLE}")"
    _orglc="$(_sed_rep_escape "${org_lc}")"
    _org="$(_sed_rep_escape "${ORG}")"
    _games="$(_sed_rep_escape "${GAMES_DOMAIN}")"
    _domain="$(_sed_rep_escape "${CLUSTER_DOMAIN}")"
    _brand="$(_sed_rep_escape "${BRAND}")"
    # Harbor image-project segment (registry.<host>/<project>/<svc>). Defaults to the
    # brand; the HARBOR_PROJECT env is a first-class seam for a differently-named project.
    _hproj="$(_sed_rep_escape "${HARBOR_PROJECT:-${BRAND}}")"
    local f
    while IFS= read -r -d '' f; do
        # FROZEN k8s label-KEY / API-group namespace `hugmesh.net/<suffix>` must NOT
        # rebrand (it is compiled into operators/JVM and used as node/pod selectors). Every
        # KEY form is preceded by a YAML-structural boundary (line-start, space, {, (, comma,
        # quote, backtick); every HOST/URL form is preceded by a dot or slash. Protect the KEY
        # namespace behind a sentinel (first two -e), rebrand hosts/URLs/emails/CORS in the
        # middle, then restore the KEY namespace verbatim (last -e). The sentinel contains
        # neither `hugmesh.net` nor `hugmesh-`, so the middle rules skip it.
        sed -i \
            -e "s|^hugmesh\.net/|@@SDSYSKEY@@/|g" \
            -e "s|\([ {(,\"'\`]\)hugmesh\.net/|\1@@SDSYSKEY@@/|g" \
            -e "s|HugMesh Systems|${_btitle}|g" \
            -e "s|hugmesh|${_org}|g" \
            -e "s|//id\.hugmesh\.games|//id.${_games}|g" \
            -e "s|//hugmesh\.games|//${_games}|g" \
            -e "s|hugmesh\.net|${_domain}|g" \
            -e "s|\(registry\.[A-Za-z0-9.-]*\)/hugmesh/|\1/${_hproj}/|g" \
            -e "s|hugmesh-|${_brand}-|g" \
            -e "s|@@SDSYSKEY@@/|hugmesh.net/|g" \
            "${f}"
    done < <(find "${SYSROOT}/var/lib/hugmesh/cluster" "${SYSROOT}/etc/hugmesh" -type f -print0 2>/dev/null)
}

# ── Mesh-node IdP external mode (I6.3) — the baked-tree passes ────────────────
# All four are self-guarding no-ops for the casdoor default (byte-identity) and
# for absent trees, so the ONE call site (apply_idp_external, AFTER rebrand_sysroot
# — the issuer literals must already read id.<CLUSTER_DOMAIN>) is safe on every
# role. Small + dependency-light on purpose: tests extract and run them against a
# fixture tree (tests/scripts/test-idp-builder-functions.sh) — never a real build.
bake_idp_conf() {
    [ "${IDP}" = "casdoor" ] && return 0
    mkdir -p "${SYSROOT}/etc/hugmesh"
    cat > "${SYSROOT}/etc/hugmesh/idp.conf" <<EOF
# Identity provider this image's services TRUST (--idp; docs/IDENTITY-PROVIDERS.md).
# PUBLIC identifiers only — client SECRETS ride KEYS/Vault provisioning, never here.
provider=${IDP}
issuer=${IDP_ISSUER}
client_id=${IDP_CLIENT_ID}
jwks_uri=${IDP_JWKS}
EOF
    chmod 0644 "${SYSROOT}/etc/hugmesh/idp.conf"
    info "IdP: baked /etc/hugmesh/idp.conf (provider=${IDP}, 0644, no secrets)"
}

rewrite_idp_sysroot() {
    # The idp-aware pass AFTER rebrand_sysroot: re-point every issuer literal
    # (https://id.<CLUSTER_DOMAIN>, incl. the @@CLUSTER_DOMAIN@@ first-boot
    # template form) at the external issuer, and every in-cluster/derived JWKS pin
    # (http://casdoor…/.well-known/jwks and the issuer-suffixed form) at the
    # external JWKS. JWKS rules run FIRST so the issuer rule cannot half-rewrite a
    # jwks URL into <external-issuer>/.well-known/jwks.
    [ "${IDP}" = "casdoor" ] && return 0
    local iss_e jwks_e dom_re f n=0
    iss_e="$(_sed_rep_escape "${IDP_ISSUER}")"
    jwks_e="$(_sed_rep_escape "${IDP_JWKS}")"
    dom_re="${CLUSTER_DOMAIN//./\\.}"
    while IFS= read -r -d '' f; do
        if grep -qE "https://id\.(${dom_re}|@@CLUSTER_DOMAIN@@)|/\.well-known/jwks" "${f}" 2>/dev/null; then
            sed -i -E \
                -e "s|https?://casdoor[A-Za-z0-9.:_-]*/\.well-known/jwks|${jwks_e}|g" \
                -e "s|https://id\.${dom_re}/\.well-known/jwks|${jwks_e}|g" \
                -e "s|https://id\.@@CLUSTER_DOMAIN@@/\.well-known/jwks|${jwks_e}|g" \
                -e "s|https://id\.${dom_re}|${iss_e}|g" \
                -e "s|https://id\.@@CLUSTER_DOMAIN@@|${iss_e}|g" \
                "${f}"
            n=$((n+1))
        fi
    done < <(find "${SYSROOT}/var/lib/hugmesh/cluster" "${SYSROOT}/etc/hugmesh" -type f -print0 2>/dev/null)
    info "IdP: rewrote issuer -> ${IDP_ISSUER} + JWKS pins -> ${IDP_JWKS} in ${n} file(s)"
}

gate_casdoor_apps() {
    # External provider: the built-in Casdoor deployment must NOT ride along —
    # prune its ArgoCD apps + manifest trees from the baked GitOps payload
    # (same rm-from-the-baked-copy design as gate_env_apps/gate_optional_services;
    # the repo itself is never touched).
    [ "${IDP}" = "casdoor" ] && return 0
    local tree="${SYSROOT}/var/lib/hugmesh/cluster"
    [ -d "${tree}" ] || return 0
    rm -f "${tree}/apps/05-casdoor.yaml" "${tree}/apps/06-casdoor-games.yaml"
    rm -rf "${tree}/manifests/casdoor" "${tree}/manifests/casdoor-games"
    info "IdP: external provider — gated the built-in Casdoor apps/manifests out of the baked tree"
}

write_idp_readme() {
    [ "${IDP}" = "casdoor" ] && return 0
    mkdir -p "${SYSROOT}/etc/hugmesh"
    cat > "${SYSROOT}/etc/hugmesh/README-IDP.md" <<EOF
# External identity provider (--idp ${IDP})

This image was built to TRUST an external OIDC provider:

  provider:  ${IDP}
  issuer:    ${IDP_ISSUER}
  client id: ${IDP_CLIENT_ID}
  jwks:      ${IDP_JWKS}

What that changed in this image:
  * /etc/hugmesh/idp.conf carries provider/issuer/client_id/jwks_uri (no secrets).
  * The baked cluster tree's issuer literals (https://id.<cluster-domain>) and
    in-cluster JWKS pins were rewritten to the values above, so resource servers
    VALIDATE tokens minted by your provider.
  * The built-in Casdoor applications/manifests were removed from the GitOps tree.

What does NOT work with an external provider (Casdoor-only until the service
repos grow provider support — full table: docs/IDENTITY-PROVIDERS.md in the
generator repo):
  * The native first-party /bff/login leg (user-bff drives Casdoor's proprietary
    POST /api/login; an external provider needs a browser front-channel).
  * MFA step-up stamping (mfa_satisfied is written via the Casdoor API).
  * The roles/permissions/groups token model — headscale allowed_groups, Harbor
    oidc_group_claim, the desktop-sudo mapper all read Casdoor-shaped claims.
  * signup-gate and the role-membership sync jobs (Casdoor REST API callers).
  * JWKS egress: the pki-namespace NetworkPolicy only allows in-cluster JWKS —
    HTTPS egress to your provider needs an egress-policy change on the cluster.
EOF
    chmod 0644 "${SYSROOT}/etc/hugmesh/README-IDP.md"
    info "IdP: dropped /etc/hugmesh/README-IDP.md (the honest external-mode limits note)"
}

apply_idp_external() {
    [ "${IDP}" = "casdoor" ] && return 0
    bake_idp_conf
    rewrite_idp_sysroot
    gate_casdoor_apps
    write_idp_readme
}

# ── 0. Prereqs ─────────────────────────────────────────────────────
banner "Verifying prerequisites"
[ -d "${SPECS_DIR}" ]   || { err "Missing ${SPECS_DIR}"; exit 1; }
[ -d "${SHARED_SPECS}" ] || { err "Missing ${SHARED_SPECS}"; exit 1; }
for t in curl tar file; do command -v "$t" >/dev/null || { err "missing tool: $t"; exit 1; }; done
# .img builder tools (default deliverable) — losetup/mkfs/parted/grub-mkimage must
# be present and the build must run as root (already enforced). grub-mkimage must
# support the x86_64-efi target for the GRUB-EFI removable install.
# NATIVE HOST-TOOL PREFLIGHT. In the builder container each block below keeps
# TODAY'S behavior verbatim (warn + disable) — every tool here was measured
# present in hugmesh-builder:latest, so the hard path is unreachable during
# fleet builds. On a real host, silently disabling an artifact the operator
# explicitly asked for (or that is ON BY DEFAULT, as --live-iso is) is dishonest:
# fail fast, up front, with the exact emerge, instead of finishing hours later
# missing the thing they wanted.
if ${BUILD_IMG}; then
    if ! hostguard_require_host_tools ".img build" \
            "sys-block/parted sys-apps/util-linux sys-fs/dosfstools sys-fs/e2fsprogs sys-boot/grub" \
            --hint "Or pass --no-img to build without the raw .img." \
            -- parted losetup mkfs.vfat mkfs.ext4 blkid grub-mkimage; then
        for t in parted losetup mkfs.vfat mkfs.ext4 blkid grub-mkimage; do
            command -v "$t" >/dev/null || { warn "missing ${t}; disabling .img build"; BUILD_IMG=false; break; }
        done
    fi
    if ${BUILD_IMG} && [ ! -d /usr/lib/grub/x86_64-efi ]; then
        warn "grub x86_64-efi target not found (/usr/lib/grub/x86_64-efi); .img will not be UEFI-bootable"
        warn "rebuild sys-boot/grub with GRUB_PLATFORMS containing efi-64"
    fi
fi
if ${LIVE_ISO}; then
    if ! hostguard_require_host_tools "--live-iso" "sys-boot/grub dev-libs/libisoburn" \
            --hint "Or pass --no-live-iso to build without it." \
            -- grub-mkrescue xorriso; then
        for t in grub-mkrescue xorriso; do
            command -v "$t" >/dev/null || { warn "missing ${t}; disabling --live-iso"; LIVE_ISO=false; break; }
        done
    fi
    # Either mksquashfs (sys-fs/squashfs-tools) or tar2sqfs (sys-fs/squashfs-tools-ng)
    # can squash the rootfs; the squash step below picks whichever is present.
    if ${LIVE_ISO} && ! hostguard_require_host_tools "--live-iso" \
            "sys-fs/squashfs-tools" \
            --hint "Or emerge sys-fs/squashfs-tools-ng instead (its tar2sqfs also works). Or pass --no-live-iso to build without it." \
            -- "mksquashfs|tar2sqfs"; then
        warn "missing mksquashfs AND tar2sqfs; disabling --live-iso"; LIVE_ISO=false
    fi
fi
# --installer-iso is SOFT: unlike .img/--live-iso, a missing xorriso does not lose
# the artifact — the build leaves an installable TREE, a first-class deliverable it
# reports as INSTALLER_ISO_PATH="... (tree; no xorriso to wrap an ISO)". Failing
# fast here would turn a build that SUCCEEDS today into exit 1.
if ${INSTALLER_ISO}; then
    if ! hostguard_require_host_tools "--installer-iso" "dev-libs/libisoburn" --soft -- xorriso; then
        warn "no xorriso; installer ISO will be left as a plain tree"
    fi
fi
# Secure Boot chain tools live on the BUILD HOST (UKI/GRUB signing happens outside
# the chroot; shim is copied off the host). Warn EARLY and non-fatally — the build
# still completes but the artifacts degrade to bare GRUB / an unsigned UKI — so the
# operator learns NOW instead of after the multi-hour emerge (the late inline warns
# at the sign/ESP/ISO steps still fire).
if ${SECURE_BOOT}; then
    command -v sbsign >/dev/null 2>&1 \
        || warn "sbsign not found (install app-crypt/sbsigntools in the builder): UKI/GRUB will NOT be signed — Secure Boot chain won't verify"
    find /usr/share/shim /usr/lib/shim \( -name 'BOOTX64.EFI' -o -name 'shimx64.efi' \) 2>/dev/null | grep -q . \
        || warn "no shim under /usr/share/shim or /usr/lib/shim (install sys-boot/shim in the builder): artifacts boot via bare GRUB (no shim Secure Boot chain)"
fi

# ── BEGIN shared block: SELinux node-policy host tools ────────────────────────
# The other NINE builders already gate the host SELinux policy toolchain
# (HOST_POLICY_TOOLS, e.g. build-rpi5-stage4.sh:3013) because selinux-base's
# `emake base` shells out to it. This builder never needed it — until now: the
# SELinux node-policy step (scripts/_selinux-policy-lib.sh, called before
# "Packaging stage4 tarball") compiles specs/selinux/*.te with exactly these
# three host binaries. Asserting them HERE, in the prereq block, means a missing
# toolchain fails in the first minute with the exact emerge line instead of after
# the multi-hour @world pass. Same reasoning as the .img/--live-iso preflights
# above: this step is ON BY DEFAULT, so silently losing it would be dishonest.
# Skippable only by an explicit, deliberate operator choice.
if [ "${HUGMESH_SELINUX_MODULES:-1}" != "0" ]; then
    hostguard_require_host_tools "SELinux node-policy modules" \
        "sys-apps/checkpolicy sys-apps/semodule-utils sys-devel/m4" \
        --hint "Or set HUGMESH_SELINUX_MODULES=0 to build deliberately without the hugmesh node policy (the image then boots permissive with only the distro base policy)." \
        -- m4 checkmodule semodule_package \
        || { err "SELinux node-policy modules need m4 + checkmodule + semodule_package on the BUILD HOST."; \
             err "Install: emerge sys-apps/checkpolicy sys-apps/semodule-utils sys-devel/m4"; \
             err "Or set HUGMESH_SELINUX_MODULES=0 to build deliberately without node policy."; exit 1; }
    info "Host SELinux policy build tools present (checkmodule, semodule_package, m4)"
fi
# ── END shared block: SELinux node-policy host tools ──────────────────────────

# ── 1. Directories ─────────────────────────────────────────────────
banner "Preparing build directories"
mkdir -p "${WORK_DIR}" "${BUILD_ROOT}"/{distfiles,pkgdir} "${SYSROOT}" "${ISO_DIR}"
# Shared asset root: seed cache + fleet distfiles + the per-arch binpkg pool
# (issue #46). The pool takes sa_pool_hold's LONG-LIVED single-writer lock before
# anything can populate it: the tree has no binpkg-multi-instance, so two
# concurrent writers into one pkgdir overwrite each other's package instances
# (docs/SHARED-BINPKG.md invalidation rule #3) — and one arch-wide x86 pool makes
# that reachable from ANY two concurrent x86 builds, not just same-role ones.
# A held lock fails FAST with the holder named (same semantics as the ARM lane);
# --no-shared-assets remains the private-pool escape hatch.
if [ -n "${SHARED_ROOT}" ]; then
    mkdir -p "${SHARED_SEED_DIR}" "${SHARED_DISTDIR}" \
        || { err "cannot create the shared asset root ${SHARED_ROOT}"; exit 1; }
    if [ -n "${X86_POOL_DIR}" ]; then
        mkdir -p "${X86_POOL_DIR}" \
            || { err "cannot create the shared binpkg pool ${X86_POOL_DIR}"; exit 1; }
        sa_pool_hold "${X86_POOL_DIR}" || { err "shared binpkg pool busy (see above) — aborting."; exit 1; }
    fi
    info "$(sa_describe "${SHARED_ROOT}" "amd64" "${X86_POOL_DIR}")"
else
    SHARED_SEED_DIR="${BUILD_ROOT}"
fi
# Preserve the pre-log fds so secrets that must NOT be persisted can still be
# routed to the operator's terminal (>&3) without landing in the logs — same
# fd 3/4 idiom as the ARM builders. (Audited: LUKS_PASS is only ever written
# to a 0600 file on the installer ISO and REDACTED in --print-plan output;
# DEFAULT_USER_PASS is sed-substituted into sysroot config, never echoed.)
exec 3>&1 4>&2
exec > >(tee -a "${LOG_FILE}" "${IMAGE_LOG_FILE}") 2>&1
info "Logging to ${LOG_FILE} (session-shared) + ${IMAGE_LOG_FILE} (this image)"
# Run banner: the shared log interleaves runs (append) and a RESTART appends to
# the per-image log too — keep every chunk attributable to its run.
echo "==== ${BUILD_SUBDIR#wl-} (${BUILD_SUBDIR}) start ${BUILD_TS} brand=${BRAND} role=${ROLE} env=${ENV} ===="
info "Work dir:   ${WORK_DIR}  (products land here)"
info "Build root: ${BUILD_ROOT}  (per-arch sysroot/distfiles/pkgdir)"

# ── 2. Seed stage3 ─────────────────────────────────────────────────
banner "Fetching stage3 seed (amd64 hardened)"
# The index is PGP-signed; select the stage3 tarball line, ignoring armor/comments.
STAGE3_FILE=$(dlv_fetch_retry "${SEED_STAGE3_URL}" - -s | awk '/stage3-.*\.tar\.xz/{print $1; exit}')
STAGE3_BASENAME="$(basename "${STAGE3_FILE}")"
STAGE3_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds/${STAGE3_FILE}"
# Stage3 seed: ONE per-arch cache under the shared root instead of a fresh ~250 MB
# download for every BUILD_SUBDIR. sa_seed_acquire re-runs the FULL supply-chain
# verification (dlv_verify_stage3: GPG-signed DIGESTS + SHA512/SHA256) on the file it
# hands back — cache HIT or fresh download — so a poisoned cache is caught by exactly
# the code that catches a poisoned mirror; caching must never turn "verified once" into
# "trusted forever". Fail-closed: an unverifiable seed is discarded, re-fetched ONCE,
# and a second failure aborts. Per-arch keying (directory AND basename) means the
# aarch64 seed can never be handed to this amd64 build, or vice versa.
STAGE3_PRIVATE="${BUILD_ROOT}/${STAGE3_BASENAME}"

# SUPPLY-CHAIN: verify the seed's integrity+authenticity before we trust a single
# byte of it. dlv_verify_stage3 fetches the matching .DIGESTS(.asc), GPG-verifies
# it against the pinned Gentoo release-engineering key, then checks the tarball's
# SHA512/SHA256 against the signed DIGESTS — ABORTING on any signature/checksum
# mismatch. A poisoned mirror or MITM can no longer slip a backdoored seed in.
# (Mirrors the rpi5/frite/jetson builders; the amd64 seed was the last unverified one.)
banner "Verifying stage3 seed signature + checksum"
if ! STAGE3_LOCAL="$(sa_seed_acquire "${SHARED_ROOT}" "amd64" "${STAGE3_BASENAME}" \
        "${STAGE3_URL}" "${STAGE3_PRIVATE}")"; then
    err "stage3 seed unavailable or failed verification (bad signature or checksum) — aborting."
    err "If Gentoo rotated its signing key, set DLV_GENTOO_KEY=<fingerprint>; for an"
    err "air-gapped build set DLV_OFFLINE_KEYRING=<keyfile>. Refusing unverified seed."
    exit 1
fi
info "stage3 seed verified: ${STAGE3_LOCAL}"

# ── Concurrent-build exclusion (flock) ─────────────────────────────────────────
# Two builds of the SAME role share BUILD_ROOT (wl-<role>.<arch>) when launched
# from one WORK_DIR, and — even from DIFFERENT WORK_DIRs — share the host portage
# scratch (/var/tmp[/portage]/snap-portage-${BUILD_SUBDIR}, see mount_chroot),
# because that path is keyed on BUILD_SUBDIR alone. There was NO lock anywhere:
# on 2026-07-25, session 20260725-140638-09692d (standalone-unaffiliated) started
# at 14:06 while 20260725-061608-978c99 (same role, its own WORK_DIR) was still
# mid-emerge; both chroots had the SAME scratch bind-mounted at /var/tmp/portage,
# and 09692d's build.log ends MID-COMPILE of media-gfx/inkscape-1.4.4
# ("[788/1186] ... tile.cpp" is the last line — no compiler error, no summary:
# the shared per-package workdir was cleaned out from under gcc by the other
# build's portage). The fresh-start path below is worse still: it rm -rf's the
# whole sysroot, which would delete THROUGH any still-attached bind mounts of a
# live build (host /dev via the rbind, the shared scratch).
# Fix: an exclusive NON-BLOCKING flock per BUILD_ROOT (taken here and re-checked
# at mount_chroot) plus one per scratch dir (taken in mount_chroot before the
# bind), so the second build fails FAST naming the holder instead of corrupting
# the first. Lockfiles are SIBLINGS of the guarded dirs (never inside a dir any
# cleanup deletes — deleting a held lockfile would let a third build acquire a
# fresh lock on the same path mid-deletion). fd 217/218 stay open for the life
# of the build; the kernel releases flocks on process death, so a crashed build
# can never wedge the next one.
acquire_build_lock() {
    [ -n "${_BUILD_LOCK_HELD:-}" ] && return 0
    # util-linux flock — same package as the already-hard-required losetup/mount.
    command -v flock >/dev/null \
        || { err "flock(1) not found (util-linux) — cannot guard against a concurrent build of this role"; exit 1; }
    mkdir -p "$(dirname "${BUILD_ROOT}")"
    exec 217>>"${BUILD_ROOT}.lock"
    if ! flock -n 217; then
        err "another build already holds ${BUILD_ROOT}"
        err "holder: $(cat "${BUILD_ROOT}.lock" 2>/dev/null || echo '<unreadable>')"
        err "Two concurrent builds of one role share the sysroot and the portage scratch —"
        err "that is what killed session 20260725-140638-09692d mid-compile. Wait for the"
        err "other build, or give this one its own --build-subdir."
        exit 1
    fi
    printf 'pid=%s build_ts=%s role=%s work_dir=%s started=%s\n' \
        "$$" "${BUILD_TS}" "${ROLE:-?}" "${WORK_DIR}" "$(date -u +%FT%TZ)" > "${BUILD_ROOT}.lock"
    _BUILD_LOCK_HELD=1
}

# ── 3. Extract ─────────────────────────────────────────────────────
banner "Extracting stage3 into sysroot"
acquire_build_lock
if [ -f "${SYSROOT}/etc/gentoo-release" ] && ${RESUME}; then
    info "Sysroot populated and --resume — skipping extraction"
else
    # A non-resume build must start from a CLEAN sysroot. Extracting stage3 OVER a
    # populated tree leaves stale packages (e.g. extra python slots, old kubelet)
    # in var/db/pkg — a HYBRID db that breaks dep resolution (observed: 3 python
    # slots surviving + libselinux[python] conflicts). Wipe first so the extract
    # is pristine. (Warm reuse is the explicit --resume path above.)
    if [ -f "${SYSROOT}/etc/gentoo-release" ]; then
        # NEVER rm -rf a sysroot that still has mounts under it: a live (or
        # crashed) build leaves /proc,/sys,/dev RBINDS and the SHARED portage
        # scratch attached, and rm -rf would delete straight through them.
        # The flock above excludes a LIVE same-BUILD_ROOT build; this catches a
        # crashed one (flock died with it, mounts did not).
        # Captured into a variable, NOT `findmnt | grep -q`: under this script's
        # pipefail, grep -q exiting at the first match can SIGPIPE findmnt on a
        # mount-heavy host (>64K of table after the match), turning the pipeline
        # status non-zero — i.e. the guard silently NOT firing with mounts
        # present, the one direction this check must never fail in.
        _stale_mounts="$(findmnt -rn -o TARGET 2>/dev/null | grep "^${SYSROOT}/" || true)"
        if [ -n "${_stale_mounts}" ]; then
            err "mounts are still attached under ${SYSROOT} (a crashed build?):"
            printf '%s\n' "${_stale_mounts}" | head -5 >&2
            err "rm -rf would delete THROUGH those binds (host /dev, the shared portage"
            err "scratch). Unmount first:  umount -R '${SYSROOT}'  — then re-run."
            exit 1
        fi
        warn "Non-resume build over a populated sysroot — wiping for a clean stage3 extract"
        rm -rf "${SYSROOT}"; mkdir -p "${SYSROOT}"
    fi
    tar -C "${SYSROOT}" --xattrs-include='*.*' -xpf "${STAGE3_LOCAL}" 2>/dev/null || \
        tar -C "${SYSROOT}" -xpf "${STAGE3_LOCAL}"
fi

# Portage pkg_postinst calls sudo internally (as the portage build user); stage3
# sudoers has requiretty which breaks non-interactive builds. Patch the main
# sudoers file directly (sudoers.d may not be included by the stage3 default)
# and grant the portage user NOPASSWD. These patches are inside the build sysroot
# only and are never shipped — the cleanup section removes them before imaging.
if [[ -f "${SYSROOT}/etc/sudoers" ]]; then
    sed -i 's/^Defaults\s\+requiretty/Defaults !requiretty/' "${SYSROOT}/etc/sudoers"
    # Ensure sudoers.d drop-ins are loaded (stage3 may omit this)
    grep -q '#includedir /etc/sudoers.d' "${SYSROOT}/etc/sudoers" || \
        printf '\n#includedir /etc/sudoers.d # build-added\n' >> "${SYSROOT}/etc/sudoers"
fi
mkdir -p "${SYSROOT}/etc/sudoers.d"
# Allow portage build user to sudo without password or tty
printf 'Defaults !requiretty\nportage ALL=(ALL) NOPASSWD: ALL\n' \
    > "${SYSROOT}/etc/sudoers.d/build-notty"
chmod 440 "${SYSROOT}/etc/sudoers.d/build-notty"

# ── 4. Install spec files ──────────────────────────────────────────
banner "Installing spec files into sysroot (hardened profile)"
mkdir -p "${SYSROOT}/etc/portage/"{package.use,package.accept_keywords,package.license,package.mask,profile,env}
render_template "${SPECS_DIR}/portage/make.conf.tmpl" "${SYSROOT}/etc/portage/make.conf"
# Native Steam is a 32-bit app: enable the multilib ABI so its deps build with
# ABI_X86_32 (the amd64-hardened stage3 seed is multilib-capable). Scoped to the
# native-Steam gaming desktops; every other image stays pure 64-bit.
if ${STEAM_NATIVE}; then
    printf '\n# Native Steam (32-bit runtime) — see package.use/steam\nABI_X86="64 32"\n' >> "${SYSROOT}/etc/portage/make.conf"
    info "Native Steam: ABI_X86=\"64 32\" (multilib) added to make.conf"
fi
# Select the profile via an ABSOLUTE make.profile symlink derived from
# profile/parent (strip the "gentoo:" repo prefix) — the same mechanism the
# ARM builders use (build-rpi5-stage4.sh's "Select the profile" block).
#
# The bare `cp profile/parent -> /etc/portage/profile/parent` that stood here
# was a silent NO-OP for profile selection: portage appends /etc/portage/profile
# to the profile stack as a plain override node and IGNORES a `parent` file in
# it (verified against portage 3.0.81.2 — portage.settings.profiles lists no
# hardened/selinux node with only the copy in place). Every x86 image therefore
# built under the stage3 seed's plain `hardened` profile: USE=selinux stayed
# profile-masked, all 24 IUSE=selinux payload packages built `(-selinux)`
# (dbus, sudo, firewalld, containerd, NetworkManager, ...), and the final
# summary banner — which cat'd the copied file — claimed hardened/selinux
# anyway. The sec-policy/* store merged fine (policy sources need no selinux
# USE), which completed the illusion: policy on disk, userland unable to use it.
#
# The gentoo tree is bind-mounted at /var/db/repos/gentoo inside the chroot
# (same path as this container — see the chroot-enter block), so one absolute
# target resolves on both sides of the chroot boundary AND on the shipped
# image, where the stage3's own relative symlink pointed at the identical path.
# The @world pass below runs --newuse, so flipping the profile rebuilds every
# IUSE=selinux package (pam, openrc, util-linux, coreutils, dbus, sudo, ...)
# with SELinux support — the documented Gentoo profile-conversion path. On a
# --resume'd pre-fix sysroot the same --newuse pass performs the conversion.
PROFILE_PATH="$(sed 's/^gentoo://' "${SPECS_DIR}/portage/profile/parent" | tr -d '[:space:]')"
[ -d "/var/db/repos/gentoo/profiles/${PROFILE_PATH}" ] \
    || { err "profile not found in tree: /var/db/repos/gentoo/profiles/${PROFILE_PATH}"; exit 1; }
ln -sfn "/var/db/repos/gentoo/profiles/${PROFILE_PATH}" "${SYSROOT}/etc/portage/make.profile"
info "Profile: ${PROFILE_PATH} (absolute make.profile symlink; @world --newuse converts the seed)"
# ── binpkg-pool fingerprint preflight (shared-binpkg SIGILL guard) ─────────────
# Before the chroot payload emerge consumes the pool via --usepkg
# (EMERGE_DEFAULT_OPTS), verify the pool's fingerprint (CHOST + exact CFLAGS +
# CXXFLAGS + PROFILE, read from the just-rendered make.conf) matches THIS build.
# portage's --binpkg-respect-use checks USE only, never CFLAGS, so this is the only
# CFLAGS-level check before reuse. A fresh pool is stamped; a mismatch aborts.
# Sits AFTER the profile derivation above because the spec-derived PROFILE_PATH is
# now part of the x86 fingerprint (the PR #44 deferral, keyed like the ARM lane).
# Pools stamped BEFORE profile keying (empty PROFILE component) are RESTAMPED once
# by pool_fingerprint_preflight's migration path — loudly, and only when CHOST/
# CFLAGS/salt already match; any REAL ABI difference still hard-refuses reuse.
if [ -n "${X86_POOL_DIR}" ]; then
    # The SHARED per-arch pool that mount_chroot bind-mounts at /var/cache/binpkgs.
    # sa_pool_guard = the same preflight run under the pool's stamp lock, so two
    # builds can never race the stamp file. The guard itself is never bypassed.
    sa_pool_guard "${X86_POOL_DIR}" "${SYSROOT}/etc/portage/make.conf" "${PROFILE_PATH}" \
        || { err "binpkg pool ABI mismatch (see above) — refusing --usepkg reuse."; exit 1; }
else
    # --no-shared-assets: the legacy chroot-internal pool, same guard + same key.
    pool_fingerprint_preflight "${SYSROOT}/var/cache/binpkgs" "${SYSROOT}/etc/portage/make.conf" "${PROFILE_PATH}" \
        || { err "binpkg pool ABI mismatch (see above) — refusing --usepkg reuse."; exit 1; }
fi
# Copy every file in these portage config dirs (so added spec files always land).
# The 'desktop' files (LXDE ~amd64 keywords / GTK+netsurf USE) are client-only — a
# k8s NODE image stays stable-keyworded and never references desktop USE flags. The
# 'nvidia' files are copied ONLY for the proprietary GPU stack; 'capable' ONLY for
# the most-capable Plasma set (--capable / standalone-thick).
# Role-conditional copies below stage into a temp dir, then pcs_sync_dir makes
# the sysroot dir EXACTLY that set — pruning both files deleted from specs and
# files excluded for THIS role (a resumed sysroot must not keep a stale 'gpu'
# or a spec-retired file; see scripts/_portage-config-lib.sh for the incident).
PCS_STAGE_AK="$(mktemp -d)"; PCS_STAGE_PU="$(mktemp -d)"
for akf in "${SPECS_DIR}/portage/package.accept_keywords/"*; do
    [ -e "${akf}" ] || continue
    case "$(basename "${akf}")" in
        desktop) ${ROLE_CLIENT} || continue ;;
        capable) ${CAPABLE} || continue ;;
        nvidia)  ${NVIDIA_PROPRIETARY} || continue ;;
        amd-pro) ${AMD_PRO} || continue ;;
        intel-pro) ${INTEL_PRO} || continue ;;
        steam)   ${STEAM_NATIVE} || continue ;;
        sunshine) ${WANT_SUNSHINE} || continue ;;
        home-encrypted) ${HOME_ENCRYPTED} || continue ;;
        seed-code)      ${WANT_DOCKER}    || continue ;;
        calamares)      ${WANT_CALAMARES} || continue ;;
    esac
    cp "${akf}" "${PCS_STAGE_AK}/"
done
pcs_sync_dir "${PCS_STAGE_AK}" "${SYSROOT}/etc/portage/package.accept_keywords"
rm -rf "${PCS_STAGE_AK}"
# package.use: copy all role-independent files; the GPU-only 'gpu' file (Mesa
# vulkan/vaapi video_cards_*) is copied ONLY for GPU roles, 'desktop' ONLY for
# client roles, 'nvidia' ONLY for the proprietary stack, 'capable' ONLY for the
# capable Plasma set — so a headless image never references USE/cards it isn't building.
for puf in "${SPECS_DIR}/portage/package.use/"*; do
    [ -e "${puf}" ] || continue
    case "$(basename "${puf}")" in
        gpu)     ${GPU} || continue ;;
        desktop) ${ROLE_CLIENT} || continue ;;
        capable) ${CAPABLE} || continue ;;
        nvidia)  ${NVIDIA_PROPRIETARY} || continue ;;
        # nvidia-headless (-tools) ONLY for HEADLESS proprietary-NVIDIA roles
        # (edge_ai/be+gpu): nvidia-settings' gtk+:3[X] dep walls under the node
        # -X posture (issue #60 item 3). Desktop GPU roles keep 'tools'.
        nvidia-headless) ${NVIDIA_PROPRIETARY} && ! ${ROLE_CLIENT} || continue ;;
        amd-pro) ${AMD_PRO} || continue ;;
        intel-pro) ${INTEL_PRO} || continue ;;
        steam)   ${STEAM_NATIVE} || continue ;;
    esac
    cp "${puf}" "${PCS_STAGE_PU}/"
done
pcs_sync_dir "${PCS_STAGE_PU}" "${SYSROOT}/etc/portage/package.use"
rm -rf "${PCS_STAGE_PU}"
# ── PYTHON_TARGETS: derived from the STAGE3 SEED, never a literal ─────────────
# make.conf.tmpl deliberately ships no PYTHON_TARGETS/PYTHON_SINGLE_TARGET
# assignment: a USE_EXPAND variable ASSIGNED in make.conf REPLACES the profile
# default (portage's config.regenerate() wipes every accumulated
# python_targets_* flag for a non-incremental USE_EXPAND that a config layer
# sets), so a frozen python3_NN there silently narrows every image to one
# interpreter — whichever one happened to be right for the seed of the day. The
# seed floats: amd64 20260726 ships 3.13+3.14 with NO 3.12, arm64 ships 3.14
# only, the 2026-07 jetson seed shipped 3.12+3.14. Getting it wrong is fatal in
# both directions (2026-07-29 dev-python slot conflict / 2026-07-16 "USE changes
# are necessary: python_targets_python3_12" wall). Derive it from the seed
# instead, HERE — after the specs land and BEFORE the first emerge touches the
# sysroot, because an emerge run under a wrong pin installs the wrong
# interpreter and the probe would then read its own effect back in. Fails the
# build rather than guessing. Analysis: docs/PYTHON-TARGETS-SEED-DRIFT.md.
pt_apply_seed_targets "${SYSROOT}" "build-x86" \
    || { err "could not derive PYTHON_TARGETS from the stage3 seed (see above)"; exit 1; }
# package.mask: role-independent version quarantines (e.g. the gettext-0.23.x
# empty-$(DOMAIN) .mo-collision pin — see package.mask/gettext). Copied for every
# role like package.accept_keywords; the mask alone only prevents an UPGRADE back
# to a quarantined version, so a matching early downgrade emerge runs in the
# payload chroot below for anything the stage3 seed already ships too new.
for pmf in "${SPECS_DIR}/portage/package.mask/"*; do
    [ -e "${pmf}" ] || continue
    cp "${pmf}" "${SYSROOT}/etc/portage/package.mask/"
done
# package.license: accept the per-vendor proprietary EULAs explicitly (hardened
# images are explicit about proprietary licences) only for the chosen stack.
if ${NVIDIA_PROPRIETARY} && [ -f "${SPECS_DIR}/portage/package.license/nvidia" ]; then
    cp "${SPECS_DIR}/portage/package.license/nvidia" "${SYSROOT}/etc/portage/package.license/"
fi
if ${AMD_PRO} && [ -f "${SPECS_DIR}/portage/package.license/amd-pro" ]; then
    cp "${SPECS_DIR}/portage/package.license/amd-pro" "${SYSROOT}/etc/portage/package.license/"
fi
# package.license: accept the Valve Steam licence only for the native-Steam build.
if ${STEAM_NATIVE} && [ -f "${SPECS_DIR}/portage/package.license/steam" ]; then
    cp "${SPECS_DIR}/portage/package.license/steam" "${SYSROOT}/etc/portage/package.license/"
fi
# Blacklist nouveau when the proprietary NVIDIA kmod is in play, so it owns the GPU.
if ${NVIDIA_PROPRIETARY}; then
    mkdir -p "${SYSROOT}/etc/modprobe.d"
    printf '# HugMesh: proprietary NVIDIA driver owns the GPU; keep nouveau out.\nblacklist nouveau\noptions nouveau modeset=0\n' \
        > "${SYSROOT}/etc/modprobe.d/hugmesh-nvidia.conf"
fi

# Per-package build env (e.g. env/llvm-lowmem.conf caps MAKEOPTS for the
# memory-hungry llvm-core/llvm+clang that mesa[llvm] pulls for the be+gpu role —
# at the global -j28 they OOM-crashed the host). Copy the env/ snippets + the
# package.env mapping when present (the headless roles carry them harmlessly).
# -r: env/ also carries path-based env/<category>/<pkg> BASH files (portage
# sources those in the ebuild env — the only legal home for phase hooks; the
# package.env-referenced *.conf files are key=value only), and the old flat cp
# silently skipped subdirectories.
if [ -d "${SPECS_DIR}/portage/env" ]; then
    pcs_sync_dir "${SPECS_DIR}/portage/env" "${SYSROOT}/etc/portage/env"
else
    rm -rf "${SYSROOT}/etc/portage/env"
fi
if [ -f "${SPECS_DIR}/portage/package.env" ]; then
    cp "${SPECS_DIR}/portage/package.env" "${SYSROOT}/etc/portage/package.env"
else
    rm -f "${SYSROOT}/etc/portage/package.env"
fi
# Quiet portage's per-file sendfile WARNING-traceback spam before the first
# merge into this sysroot (sendfile(2) EINVALs for EVERY file merged onto the
# eCryptfs-backed work dir; the copy always succeeded via portage's shutil
# fallback — pure log noise, ~300k traceback lines per build). Also re-patches
# the container's own portage (host-guard gated) for builder images older than
# the Dockerfile.build twin. Never fatal. Root cause, refs and the patch:
# scripts/patch-portage-file-copy.py.
pcs_quiet_sendfile_noise "${SYSROOT}"

# x86 GRUB cmdline (SELinux LSM + KSPP hardening). Disable os-prober so a
# grub-mkconfig (installer / chroot) can never enumerate the host's other disks.
#
# ASSERT THE CMDLINE FIRST — it is a build INPUT with a silent degradation mode.
# Three consumers read GRUB_CMDLINE_LINUX out of this one file: the signed UKI's
# .cmdline section (build_uki), build_img's hand-written grub.cfg, and the live-ISO
# menu. All three spell it `${GRUB_CMDLINE_LINUX:-<short fallback>}`, and that
# fallback carries only lsm=/lockdown=/selinux=/audit=. So an empty or unreadable
# file does not fail the build — it quietly ships a kernel with no vsyscall=none,
# no cgroup_enable=*/cgroup_memory=1 (kubelet), no slab_nomerge / init_on_alloc /
# page_alloc.shuffle / randomize_kstack_offset, and no console= at all, which also
# blinds the serial boot-verify harness that reads the console. A PARTIALLY edited
# file is worse: it is non-empty, so the fallback never fires and the truncation
# ships verbatim. Nothing anywhere checked this (the only other reads are a `cp`
# and a sha256 cache key), so check it here, once, before anything consumes it.
_grub_defaults="${SPECS_DIR}/etc/default/grub"
[ -s "${_grub_defaults}" ] || { err "${_grub_defaults} is missing or empty — every consumer would silently fall back to the SHORT cmdline and drop the KSPP/cgroup/console hardening"; exit 1; }
# Sourced in a subshell, exactly as the three consumers do, so this asserts the
# value they will actually get — not merely that some text matches in the file.
_grub_cmdline="$(. "${_grub_defaults}"; printf '%s' "${GRUB_CMDLINE_LINUX:-}")"
[ -n "${_grub_cmdline}" ] || { err "${_grub_defaults} defines no GRUB_CMDLINE_LINUX — the .img grub.cfg, the signed UKI and the live ISO would each fall back to the short literal"; exit 1; }
for _p in lsm=lockdown,yama,selinux,bpf lockdown=integrity selinux=1 audit=1 \
          vsyscall=none cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1 \
          slab_nomerge init_on_alloc=1 page_alloc.shuffle=1 \
          randomize_kstack_offset=on console=tty0 console=ttyS0,115200; do
    # Space-delimited whole-param match: a substring test would let
    # `cgroup_enable=memoryX` or a truncated `console=tty` satisfy the guard.
    case " ${_grub_cmdline} " in
        *" ${_p} "*) ;;
        *) err "${_grub_defaults}: GRUB_CMDLINE_LINUX is missing '${_p}'. This string IS the boot cmdline for the .img grub.cfg, the signed UKI and the live ISO — refusing to ship a silently de-hardened kernel."; exit 1 ;;
    esac
done
info "grub cmdline asserted (LSM + lockdown + KSPP + cgroup + both console= params present)"
mkdir -p "${SYSROOT}/etc/default"
cp "${SPECS_DIR}/etc/default/grub"                    "${SYSROOT}/etc/default/grub"
grep -q '^GRUB_DISABLE_OS_PROBER=' "${SYSROOT}/etc/default/grub" || \
    echo 'GRUB_DISABLE_OS_PROBER=true' >> "${SYSROOT}/etc/default/grub"

# PARTUUID-token fstab (mounts / + /boot/efi by PARTUUID, plus hardening tmpfs).
# The .img builder and install-x86.sh substitute __ROOT_PARTUUID__/__ESP_PARTUUID__.
cp "${SPECS_DIR}/etc/fstab"                           "${SYSROOT}/etc/fstab"

# dracut LUKS-root persistence drop-in (so an installer-created encrypted root
# keeps unlocking across future in-image kernel rebuilds). Inert on plaintext-root.
# UNAFFILIATED: same functional content under a neutral filename.
if [ -f "${SPECS_DIR}/etc/dracut.conf.d/60-hugmesh-crypt.conf" ]; then
    mkdir -p "${SYSROOT}/etc/dracut.conf.d"
    if ${UNAFFILIATED}; then
        cp "${SPECS_DIR}/etc/dracut.conf.d/60-hugmesh-crypt.conf" "${SYSROOT}/etc/dracut.conf.d/60-crypt.conf"
    else
        cp "${SPECS_DIR}/etc/dracut.conf.d/60-hugmesh-crypt.conf" "${SYSROOT}/etc/dracut.conf.d/"
    fi
fi

# Shared (arch-agnostic) etc/ specs. UNAFFILIATED: only the neutral hardening
# dirs — no containerd/kubernetes/headscale/keys-provision platform trees.
if ${UNAFFILIATED}; then
    mkdir -p "${SYSROOT}/etc/"{sysctl.d,modules-load.d,init.d,ssh/sshd_config.d,local.d,firewalld/zones} \
             "${SYSROOT}/usr/sbin"
else
    mkdir -p "${SYSROOT}/etc/"{sysctl.d,modules-load.d,containerd,kubernetes,init.d,ssh/sshd_config.d,local.d,headscale,keys-provision,firewalld/zones} \
             "${SYSROOT}/var/lib/kubelet" "${SYSROOT}/usr/sbin"
fi
cp "${SHARED_SPECS}/etc/sysctl.d/10-hardened.conf"    "${SYSROOT}/etc/sysctl.d/"
if ! ${UNAFFILIATED}; then
cp "${SHARED_SPECS}/etc/sysctl.d/99-kubernetes.conf"  "${SYSROOT}/etc/sysctl.d/"
cp "${SHARED_SPECS}/etc/modules-load.d/kubernetes.conf" "${SYSROOT}/etc/modules-load.d/"
cp "${SHARED_SPECS}/etc/containerd/config.toml"       "${SYSROOT}/etc/containerd/"
# GPU k8s nodes (be+gpu / omnibus / edge_ai with the proprietary NVIDIA driver): add
# the containerd `nvidia` runtime so pods with runtimeClassName: nvidia get the GPU.
# The nvidia-device-plugin DaemonSet, the edge-ai inference service, and the GPU
# voice/video services (owncast/coturn/tube) all rely on it. The binary comes from
# app-containers/nvidia-container-toolkit (added to PKGS below). runc stays default.
if ${GPU} && [ "${GPU_DRIVER}" = "nvidia" ]; then
    cat >> "${SYSROOT}/etc/containerd/config.toml" <<'NVRT'

# ── NVIDIA GPU runtime (hugmesh edge-AI / GPU workloads) ──────────────────
# Selected per-pod via RuntimeClass `nvidia`; runc remains the default runtime.
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
  runtime_type = "io.containerd.runc.v2"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
    BinaryName = "/usr/bin/nvidia-container-runtime"
    SystemdCgroup = false
NVRT
    info "containerd: added the nvidia GPU runtime (RuntimeClass nvidia) for GPU pods"
fi
cp "${SHARED_SPECS}/etc/kubernetes/kubeadm-config.yaml" "${SYSROOT}/etc/kubernetes/"
cp "${SHARED_SPECS}/etc/kubernetes/kubelet-config.yaml" "${SYSROOT}/var/lib/kubelet/config.yaml"
fi   # ! UNAFFILIATED (k8s/containerd config remnants)
cp "${SHARED_SPECS}/etc/ssh/sshd_config.d/hardened.conf" "${SYSROOT}/etc/ssh/sshd_config.d/"
if ! ${UNAFFILIATED}; then
cp "${SHARED_SPECS}/etc/headscale/config.yaml"        "${SYSROOT}/etc/headscale/"
# WS-SUPER-B: template the control plane's MagicDNS suffix to the orchestration
# superdomain so the baked headscale config agrees with the KEYS/provision channel
# (provision.sh resolve_magic_dns_domain). "" = the checked-in default (headnet.internal);
# the provision.json value stays authoritative and re-templates this at first boot.
if [ -n "${SUPERDOMAIN}" ] && [ -f "${SYSROOT}/etc/headscale/config.yaml" ]; then
    sed -i "s|^  base_domain: .*|  base_domain: ${SUPERDOMAIN}|" "${SYSROOT}/etc/headscale/config.yaml"
    info "Templated headscale base_domain -> ${SUPERDOMAIN} (orchestration superdomain)"
fi
# Layer-A: bake the BOOTSTRAP policy AS the initial /etc/headscale/policy.hujson
# (NO any-to-any tag:hugmesh->tag:hugmesh:* :22 hole; KEEPS the k8s CIDR
# data-plane rule + a single conservative @@TS_SSH_USER@@ ssh rule). The #66
# full-mesh policy.hujson is intentionally NOT baked here — its any-to-any :22 hole
# must not exist at any time. The first verified Layer-A sync wholesale re-renders
# this from policy.hujson.tmpl. (provision_headscale also restages this from
# policy.bootstrap.hujson at provision time as a belt-and-braces.)
cp "${SHARED_SPECS}/etc/headscale/policy.bootstrap.hujson" "${SYSROOT}/etc/headscale/policy.hujson"   # Layer-A bootstrap (policy.mode: file)
cp "${SHARED_SPECS}/etc/keys-provision/provision.sh"  "${SYSROOT}/usr/sbin/keys-provision"; chmod +x "${SYSROOT}/usr/sbin/keys-provision"
mkdir -p "${SYSROOT}/usr/local/sbin"
cp "${SHARED_SPECS}/usr/local/sbin/hugmesh-backup"  "${SYSROOT}/usr/local/sbin/hugmesh-backup"; chmod +x "${SYSROOT}/usr/local/sbin/hugmesh-backup"
fi   # ! UNAFFILIATED (headscale/keys-provision/backup platform tools)
# UNAFFILIATED keeps only growroot (first-boot .img root expansion — generic).
if ${UNAFFILIATED}; then _base_svcs="growroot"; else _base_svcs="containerd kubelet headscale tailscaled keys-provision growroot"; fi
for svc in ${_base_svcs}; do
    cp "${SHARED_SPECS}/etc/init.d/${svc}" "${SYSROOT}/etc/init.d/${svc}"; chmod +x "${SYSROOT}/etc/init.d/${svc}"
done
unset _base_svcs
# NO 'firewall' alias for firewalld. 'firewall' is an OpenRC VIRTUAL (firewalld's
# own init script `provide firewall`s it); a real /etc/init.d/firewall symlink on
# top of that made every first boot print "Error: firewall is the name of a real
# and virtual service." and corrupted dependency-cache generation (2026-08-19
# forensics: prime suspect for nondeterministic service ordering / NetworkManager
# coming up inactive). The `after firewall` deps in tailscaled/kubelet/headscale/
# containerd/egress-vpn resolve against the VIRTUAL — and `after` is a soft edge,
# so it is satisfied even where no provider is installed. Never symlink a real
# service onto a virtual name (gate: tests/no-openrc-virtual-shadow.sh).
# Bake ENV-appropriate firewalld config: prod = hardened (DefaultZone=drop, tailscale0-only
# via trusted.xml), test = permissive (DefaultZone=trusted) so CI harnesses can reach
# the node without a tailnet.
if [ "${ENV}" = "prod" ]; then
    cp "${SHARED_SPECS}/etc/firewalld/firewalld-prod.conf" "${SYSROOT}/etc/firewalld/firewalld.conf"
else
    cp "${SHARED_SPECS}/etc/firewalld/firewalld-test.conf" "${SYSROOT}/etc/firewalld/firewalld.conf"
fi
cp "${SHARED_SPECS}/etc/firewalld/zones/trusted.xml" "${SYSROOT}/etc/firewalld/zones/trusted.xml"

# ── Layer-B device-license-registry sshd enforcement (ADMIN/mesh-extension) ─────
# INERT on a SUPERADMIN/core host: provision_device_registry() ACTIVATES it only
# when owner_type=ADMIN. Enforcement conf + break-glass + cron STAGED under
# /etc/hugmesh/registry (installed on ADMIN nodes only; conf gate-flips on first
# verified sync).
# UNAFFILIATED skips this whole platform block (Layer-B/Layer-A registries, the
# domain-registry bridge, tor reconcile, and the brand-repo generator bundle) —
# all of it is HugMesh mesh/fleet machinery with no place on a plain desktop.
if ! ${UNAFFILIATED}; then
mkdir -p "${SYSROOT}/usr/lib/hugmesh" "${SYSROOT}/etc/hugmesh/registry" "${SYSROOT}/var/lib/hugmesh/device-registry"
cp "${SHARED_SPECS}/usr/sbin/hugmesh-authorized-keys-lookup" "${SYSROOT}/usr/sbin/hugmesh-authorized-keys-lookup"; chmod +x "${SYSROOT}/usr/sbin/hugmesh-authorized-keys-lookup"
cp "${SHARED_SPECS}/usr/sbin/hugmesh-device-registry-sync"   "${SYSROOT}/usr/sbin/hugmesh-device-registry-sync";   chmod +x "${SYSROOT}/usr/sbin/hugmesh-device-registry-sync"
cp "${SHARED_SPECS}/usr/lib/hugmesh/registry-verify.sh"      "${SYSROOT}/usr/lib/hugmesh/registry-verify.sh"
cp "${SHARED_SPECS}/etc/init.d/hugmesh-device-registry-sync" "${SYSROOT}/etc/init.d/hugmesh-device-registry-sync"; chmod +x "${SYSROOT}/etc/init.d/hugmesh-device-registry-sync"
cp "${SHARED_SPECS}/etc/ssh/sshd_config.d/device-registry.conf" "${SYSROOT}/etc/hugmesh/registry/device-registry.conf"
cp "${SHARED_SPECS}/etc/ssh/sshd_config.d/break-glass.conf"     "${SYSROOT}/etc/hugmesh/registry/break-glass.conf"
cp "${SHARED_SPECS}/etc/cron.d/hugmesh-device-registry-sync" "${SYSROOT}/etc/hugmesh/registry/cron-device-registry-sync"

# ── Layer-A device-license-registry headscale policy (CONTROL/pki node only) ────
# CENTRALIZED: provision_headscale_policy_sync() ACTIVATES these only when
# headscale.enabled==true (the control node). The renderer + forced-tag pass + the
# bootstrap policy + the render template are baked into every host image (inert on
# a non-control node); REUSES the SAME registry-verify.sh + baked
# registry-pub.ed25519 as Layer-B (no duplication).
cp "${SHARED_SPECS}/usr/sbin/gen-headscale-policy.sh"          "${SYSROOT}/usr/sbin/gen-headscale-policy.sh";          chmod +x "${SYSROOT}/usr/sbin/gen-headscale-policy.sh"
cp "${SHARED_SPECS}/usr/sbin/hugmesh-headscale-forcetags"   "${SYSROOT}/usr/sbin/hugmesh-headscale-forcetags";   chmod +x "${SYSROOT}/usr/sbin/hugmesh-headscale-forcetags"
cp "${SHARED_SPECS}/etc/init.d/hugmesh-policy-sync"         "${SYSROOT}/etc/init.d/hugmesh-policy-sync";         chmod +x "${SYSROOT}/etc/init.d/hugmesh-policy-sync"
cp "${SHARED_SPECS}/etc/headscale/policy.bootstrap.hujson"     "${SYSROOT}/etc/headscale/policy.bootstrap.hujson"
cp "${SHARED_SPECS}/etc/headscale/policy.hujson.tmpl"          "${SYSROOT}/etc/headscale/policy.hujson.tmpl"
cp "${SHARED_SPECS}/etc/cron.d/hugmesh-policy-sync"         "${SYSROOT}/etc/hugmesh/registry/cron-policy-sync"

# ── NODE-STORAGE reconcile (signed per-node export consumer) — enabled by keys-provision ──
# The pull-half twin of hugmesh-device-registry-sync (boot oneshot + 60s cron
# convergence floor). storage-verify.sh SOURCES Layer-B's registry-verify.sh (the
# IDENTICAL detached-Ed25519 verify + strict-monotonic rollback guard; REUSES the
# baked registry-pub.ed25519 — never re-bake). INERT with no registered pool: the
# signed per-node export is the EMPTY body, so the agent provisions NOTHING. The
# cron drop-in is STAGED at /etc/hugmesh/registry (keys-provision rc-update adds
# the boot oneshot + places the cron into /etc/cron.d on every mesh node).
# The bake itself lives in scripts/_node-storage-bake-lib.sh — see its header for
# why it is a function and not seven pasted lines.
bake_node_storage "${SYSROOT}" "${SHARED_SPECS}" \
    || { err "node-storage bake failed (see above)"; exit 1; }

# ── Domain-registry -> brand-repo bridge (#4) — DEFAULT-OFF optional service ─────
# Bake the reconcile agent + its source-and-extend verify lib (domain-verify.sh) +
# the OpenRC service into every host image. INERT until enabled (the gate below
# links the service + cron ONLY when `domain-registry-bridge` is selected; a real
# key is required to verify; absent transport it keeps cache + emits nothing).
# REUSES the baked registry-pub.ed25519 (Layer-B's key — never re-bake). The agent
# drives the EXISTING gen-keystores.sh + generate-brand-repos.sh, so those two
# generators + the templates are baked under /usr/share/hugmesh/generator.
cp "${SHARED_SPECS}/usr/sbin/hugmesh-domain-reconcile"      "${SYSROOT}/usr/sbin/hugmesh-domain-reconcile";      chmod +x "${SYSROOT}/usr/sbin/hugmesh-domain-reconcile"
cp "${SHARED_SPECS}/usr/lib/hugmesh/domain-verify.sh"       "${SYSROOT}/usr/lib/hugmesh/domain-verify.sh"
cp "${SHARED_SPECS}/etc/init.d/hugmesh-domain-reconcile"    "${SYSROOT}/etc/init.d/hugmesh-domain-reconcile";    chmod +x "${SYSROOT}/etc/init.d/hugmesh-domain-reconcile"
cp "${SHARED_SPECS}/etc/cron.d/hugmesh-domain-reconcile"    "${SYSROOT}/etc/hugmesh/registry/cron-domain-reconcile"

# ── Tor v3 onion (hidden) service (#tor) — DEFAULT-OFF NODE service ──────────────
# Bake the onion-service reconcile agent + its OpenRC oneshot + the 24h cron into every
# host image (INERT until enabled). The DISTRO Tor daemon (net-vpn/tor → /etc/init.d/tor
# + /etc/tor/torrc) is installed + linked ONLY when 'tor' is selected (the SVCS/PKGS
# gates below); this agent (ordered `before tor`) writes the managed torrc and mints +
# persists the v3 onion keypair OFF-GIT under /var/lib/tor/hugmesh-onion on first boot.
cp "${SHARED_SPECS}/usr/sbin/hugmesh-tor-reconcile"        "${SYSROOT}/usr/sbin/hugmesh-tor-reconcile";        chmod +x "${SYSROOT}/usr/sbin/hugmesh-tor-reconcile"
cp "${SHARED_SPECS}/etc/init.d/hugmesh-tor-reconcile"      "${SYSROOT}/etc/init.d/hugmesh-tor-reconcile";      chmod +x "${SYSROOT}/etc/init.d/hugmesh-tor-reconcile"
cp "${SHARED_SPECS}/etc/cron.d/hugmesh-tor-reconcile"      "${SYSROOT}/etc/hugmesh/registry/cron-tor-reconcile"
mkdir -p "${SYSROOT}/usr/share/hugmesh/generator/scripts" "${SYSROOT}/usr/share/hugmesh/generator/templates"
cp "${SCRIPT_DIR}/scripts/gen-keystores.sh"  "${SYSROOT}/usr/share/hugmesh/generator/scripts/gen-keystores.sh";  chmod +x "${SYSROOT}/usr/share/hugmesh/generator/scripts/gen-keystores.sh"
cp "${SCRIPT_DIR}/generate-brand-repos.sh"   "${SYSROOT}/usr/share/hugmesh/generator/generate-brand-repos.sh";   chmod +x "${SYSROOT}/usr/share/hugmesh/generator/generate-brand-repos.sh"
cp -r "${SCRIPT_DIR}/templates/."            "${SYSROOT}/usr/share/hugmesh/generator/templates/"
fi   # ! UNAFFILIATED (Layer-B/Layer-A/domain/tor/brand-repo-generator block)

render_template "${SHARED_SPECS}/etc/local.d/01-firstboot.start.tmpl" "${SYSROOT}/etc/local.d/01-firstboot.start"
chmod +x "${SYSROOT}/etc/local.d/01-firstboot.start"
# UNAFFILIATED: the shared firstboot loads k8s modules and prints a k8s/headscale/
# KEYS banner — none of which exists on a plain desktop. Strip those sections from
# the RENDERED file (anchored ranges; `sysctl --system` and the NVMe note survive)
# and print an honest neutral banner instead.
if ${UNAFFILIATED}; then
    sed -i \
        -e '/^# ── Kubernetes kernel modules/,/^done$/d' \
        -e '\|/usr/libexec/cni|,/^fi$/d' \
        -e 's/=== Gentoo RPi 5 (Hardened + Headscale + Kubernetes) ===/=== Gentoo Linux — hardened desktop ===/' \
        -e '/Kubernetes:  /d' -e '/containerd:  /d' -e '/Headscale:   /d' \
        -e '/Provisioned from USB KEYS/d' -e '/Control plane:  kubeadm/d' -e '/Worker node:    kubeadm/d' \
        -e '/keys come from the USB KEYS/d' -e '/If you booted WITHOUT a KEYS stick/d' \
        "${SYSROOT}/etc/local.d/01-firstboot.start"
    grep -q 'kubeadm\|headscale' "${SYSROOT}/etc/local.d/01-firstboot.start" \
        && warn "unaffiliated firstboot still mentions kubeadm/headscale (template drift — review the sed anchors above)"
fi

# ── Home provisioning manifest + first-boot helper ───────────────────────────
# Carries the home posture (mode / device / backup / ecryptfs / stack-code) baked
# by this build. Consumed by hugmesh-home-setup (runs at first boot, after the
# 01-firstboot user is created) and read by the installer for adopt/restore.
# UNAFFILIATED: same functional machinery under NEUTRAL names — the conf moves to
# /etc/gentoo/home.conf, the helper installs as /usr/sbin/home-setup, and its
# internal hugmesh-* literals (conf path, first-login-encrypt dotfile) are
# rewritten on the staged copy. install-x86.sh's staged copy gets the matching
# conf-path rewrite where the installer ISO is built (below).
if ${UNAFFILIATED}; then
    HOME_CONF_DIR="/etc/gentoo"; HOME_SETUP_NAME="home-setup"
else
    HOME_CONF_DIR="/etc/hugmesh"; HOME_SETUP_NAME="hugmesh-home-setup"
fi
mkdir -p "${SYSROOT}${HOME_CONF_DIR}"
# home.conf is dot-sourced as ROOT at first boot (hugmesh-home-setup) AND by the
# installer (install-x86.sh). HOME_DEVICE/HOME_BACKUP are free-text operator fields, so
# emit every value with `printf %q` (shell-safe quoting): a sourced file can never run
# injected code and the value survives intact for the installer's fstab line.
{
    echo "# Baked by build-x86-host-stage4.sh — DO NOT edit by hand on the image; rebuild."
    printf 'HOME_MODE=%q\n'      "${HOME_MODE}"
    printf 'HOME_DEVICE=%q\n'    "${HOME_DEVICE}"
    printf 'HOME_BACKUP=%q\n'    "${HOME_BACKUP}"
    printf 'HOME_ENCRYPTED=%q\n' "${HOME_ENCRYPTED}"
    printf 'HOME_SEED_CODE=%q\n' "${HOME_SEED_CODE}"
    printf 'LOCAL_USER=%q\n'     "${LOCAL_USER:-${DEFAULT_USER}}"
} > "${SYSROOT}${HOME_CONF_DIR}/home.conf"
if [ -f "${SHARED_SPECS}/usr/sbin/hugmesh-home-setup" ]; then
    cp "${SHARED_SPECS}/usr/sbin/hugmesh-home-setup" "${SYSROOT}/usr/sbin/${HOME_SETUP_NAME}"
    chmod +x "${SYSROOT}/usr/sbin/${HOME_SETUP_NAME}"
    if ${UNAFFILIATED}; then
        # Neutralize the staged copy's internal literals (fail loudly on drift).
        grep -q '^CONF=/etc/hugmesh/home.conf' "${SYSROOT}/usr/sbin/${HOME_SETUP_NAME}" \
            || { err "hugmesh-home-setup drifted: CONF= line not found (unaffiliated rename would break silently)"; exit 1; }
        sed -i -e "s|/etc/hugmesh/home.conf|${HOME_CONF_DIR}/home.conf|g" \
               -e 's/hugmesh-home-setup/home-setup/g' \
               -e 's/hugmesh-first-login-encrypt/first-login-encrypt/g' \
               "${SYSROOT}/usr/sbin/${HOME_SETUP_NAME}"
    fi
    cat > "${SYSROOT}/etc/local.d/03-home-setup.start" <<HOOK
#!/bin/bash
# First-boot home provisioning (ecryptfs wiring, stack-code seeding). Self-removes.
[ -x /usr/sbin/${HOME_SETUP_NAME} ] && /usr/sbin/${HOME_SETUP_NAME}
HOOK
    chmod +x "${SYSROOT}/etc/local.d/03-home-setup.start"
fi
# Dockerized stack / mesh-node code templates (compose + runner) — staged for the
# helper to drop into ~/hugmesh-stack at first boot.
if [ "${HOME_SEED_CODE}" != none ] && [ -d "${SHARED_SPECS}/usr/share/hugmesh/stack" ]; then
    mkdir -p "${SYSROOT}/usr/share/hugmesh/stack"
    cp -r "${SHARED_SPECS}/usr/share/hugmesh/stack/." "${SYSROOT}/usr/share/hugmesh/stack/" 2>/dev/null || true
fi
# Self-hosting: bundle the generator source + a regenerate helper so the running
# desktop can build a fresh, customized ISO (hugmesh-regenerate …).
if ${BUNDLE_SOURCE:-false}; then
    info "Bundling generator source -> /usr/src/hugmesh-generator (regenerate from the desktop)"
    mkdir -p "${SYSROOT}/usr/src/hugmesh-generator"
    tar -C "${SCRIPT_DIR}" --exclude=./.git --exclude=./out --exclude='./snap-*' --exclude='./*.bundle' \
        -cf - . 2>/dev/null | tar -C "${SYSROOT}/usr/src/hugmesh-generator" -xf - 2>/dev/null || true
    if [ -f "${SHARED_SPECS}/usr/sbin/hugmesh-regenerate" ]; then
        cp "${SHARED_SPECS}/usr/sbin/hugmesh-regenerate" "${SYSROOT}/usr/sbin/hugmesh-regenerate"
        chmod +x "${SYSROOT}/usr/sbin/hugmesh-regenerate"
    fi
fi
# Graphical Calamares installer config + the bridge to install-x86.sh.
# UNAFFILIATED: neutral names (gentoo-calamares-install / gentoo-installer-autostart,
# a "Gentoo Installer" desktop entry, and the gentoo.install= cmdline key emitted by
# the live GRUB entries below) — same functional machinery.
if ${UNAFFILIATED}; then
    CALAMARES_BRIDGE="gentoo-calamares-install"; AUTOSTART_NAME="gentoo-installer-autostart"
    INSTALLER_DESKTOP_TITLE="Gentoo Installer"
else
    CALAMARES_BRIDGE="hugmesh-calamares-install"; AUTOSTART_NAME="hugmesh-installer-autostart"
    INSTALLER_DESKTOP_TITLE="HugMesh Installer"
fi
if ${WANT_CALAMARES:-false}; then
    mkdir -p "${SYSROOT}/etc/calamares/modules" "${SYSROOT}/usr/libexec"
    cp "${SHARED_SPECS}/etc/calamares/settings.conf" "${SYSROOT}/etc/calamares/settings.conf" 2>/dev/null || true
    cp "${SHARED_SPECS}/etc/calamares/modules/shellprocess-install.conf" "${SYSROOT}/etc/calamares/modules/" 2>/dev/null || true
    if [ -f "${SHARED_SPECS}/usr/libexec/hugmesh-calamares-install" ]; then
        cp "${SHARED_SPECS}/usr/libexec/hugmesh-calamares-install" "${SYSROOT}/usr/libexec/${CALAMARES_BRIDGE}"
        chmod +x "${SYSROOT}/usr/libexec/${CALAMARES_BRIDGE}"
    fi
    if ${UNAFFILIATED}; then
        # Re-point the shellprocess module at the renamed bridge + drop the
        # nonexistent-scaffold 'hugmesh' branding component reference.
        sed -i "s|/usr/libexec/hugmesh-calamares-install|/usr/libexec/${CALAMARES_BRIDGE}|" \
            "${SYSROOT}/etc/calamares/modules/shellprocess-install.conf" 2>/dev/null || true
        sed -i 's/^branding: hugmesh$/branding: default/' "${SYSROOT}/etc/calamares/settings.conf" 2>/dev/null || true
    else
        # BRANDED path: settings.conf names 'branding: hugmesh', but
        # app-admin/calamares only installs the stock 'default' component and no
        # 'hugmesh' one exists anywhere — Calamares refuses to start when its
        # branding component is unresolvable, leaving the live ISO's graphical-
        # installer boot entry dead. Generate a minimal valid component from the
        # build identity so the graphical installer always boots. (The
        # unaffiliated arm above instead rewrites the reference to 'default'.)
        grep -q '^branding: hugmesh$' "${SYSROOT}/etc/calamares/settings.conf" \
            || { err "calamares settings.conf drifted: 'branding: hugmesh' line not found (the generated branding component would go unused)"; exit 1; }
        info "Calamares branding: generating component 'hugmesh' (${BRAND_TITLE} ${REL_VERSION})"
        _caldir="${SYSROOT}/usr/share/calamares/branding/hugmesh"
        mkdir -p "${_caldir}"
        # Logo: reuse the desktop-branding assets when they carry one — same
        # precedence as the branding bake below (theme preset -> --branding-dir
        # -> --brand-logo). No bundled theme ships a logo.png yet, so the usual
        # fallback is the embedded placeholder.
        _callogo=""
        [ -n "${BRANDING_THEME}" ] && [ -f "${SPECS_DIR}/branding/themes/${BRANDING_THEME}/logo.png" ] \
            && _callogo="${SPECS_DIR}/branding/themes/${BRANDING_THEME}/logo.png"
        [ -n "${BRANDING_DIR}" ] && [ -f "${BRANDING_DIR}/logo.png" ] && _callogo="${BRANDING_DIR}/logo.png"
        [ -n "${BRAND_LOGO}" ]   && [ -f "${BRAND_LOGO}" ]            && _callogo="${BRAND_LOGO}"
        if [ -n "${_callogo}" ]; then
            cp "${_callogo}" "${_caldir}/logo.png"
        else
            # PLACEHOLDER pending real art: a 1x1 PNG in the sidebar colour
            # (#292F34) — valid PNG, Qt scales it cleanly. Ship a real logo.png
            # in the theme / --branding-dir, or pass --brand-logo, to replace it.
            base64 -d > "${_caldir}/logo.png" <<'CALPNG'
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGPQ1DcBAAERAI2Hvu38AAAAAElFTkSuQmCC
CALPNG
        fi
        [ -s "${_caldir}/logo.png" ] \
            || { err "calamares branding: logo.png did not stage (empty/missing) — Calamares hard-fails on a missing branding image"; exit 1; }
        # branding.desc: componentName MUST match the directory name, and every
        # referenced image/slideshow file must exist, or Calamares refuses to start.
        cat > "${_caldir}/branding.desc" <<CALDESC
---
# GENERATED at image-assembly time by build-x86-host-stage4.sh from the build
# identity (--brand / --brand-title / --version). Do not hand-edit on the image.
componentName:  hugmesh

welcomeStyleCalamares:   true
welcomeExpandingLogo:    true

strings:
    productName:         "${BRAND_TITLE}"
    shortProductName:    "${BRAND_TITLE}"
    version:             "${REL_VERSION}"
    shortVersion:        "${REL_VERSION}"
    versionedName:       "${BRAND_TITLE} ${REL_VERSION}"
    shortVersionedName:  "${BRAND} ${REL_VERSION}"
    bootloaderEntryName: "${BRAND_TITLE}"
    productUrl:          "https://${CLUSTER_DOMAIN}/"
    supportUrl:          "https://${CLUSTER_DOMAIN}/"
    knownIssuesUrl:      "https://${CLUSTER_DOMAIN}/"
    releaseNotesUrl:     "https://${CLUSTER_DOMAIN}/"

images:
    productLogo:         "logo.png"
    productIcon:         "logo.png"
    productWelcome:      "logo.png"

slideshow:               "show.qml"
slideshowAPI:            2

style:
    sidebarBackground:    "#292F34"
    sidebarText:          "#FFFFFF"
    sidebarTextSelect:    "#292F34"
    sidebarTextHighlight: "#D35400"
CALDESC
        # Minimal static slideshow: one branded slide (slideshow API 2).
        cat > "${_caldir}/show.qml" <<CALQML
/* GENERATED by build-x86-host-stage4.sh — single static branded slide. */
import QtQuick 2.5

Rectangle {
    anchors.fill: parent
    color: "#292F34"
    Column {
        anchors.centerIn: parent
        spacing: 12
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            color: "#FFFFFF"; font.pixelSize: 36; font.bold: true
            text: "${BRAND_TITLE}"
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            color: "#C0C6CC"; font.pixelSize: 16
            text: "Installing ${BRAND_TITLE} ${REL_VERSION}"
        }
    }
    // Slideshow API 2 hooks (called by Calamares; static slide = no-ops).
    function onActivate() { }
    function onLeave() { }
}
CALQML
    fi
fi
# Live-session installer autostart (reads ${INSTALL_CMDLINE_KEY}= from the GRUB entry).
if [ "${INSTALLER_UI:-cli}" != cli ] || ${WANT_CALAMARES:-false}; then
    if [ -f "${SHARED_SPECS}/usr/bin/hugmesh-installer-autostart" ]; then
        cp "${SHARED_SPECS}/usr/bin/hugmesh-installer-autostart" "${SYSROOT}/usr/bin/${AUTOSTART_NAME}"
        chmod +x "${SYSROOT}/usr/bin/${AUTOSTART_NAME}"
        if ${UNAFFILIATED}; then
            grep -q 'hugmesh\.install=' "${SYSROOT}/usr/bin/${AUTOSTART_NAME}" \
                || { err "hugmesh-installer-autostart drifted: hugmesh.install= key not found (unaffiliated rename would break silently)"; exit 1; }
            sed -i "s/hugmesh\.install=/${INSTALL_CMDLINE_KEY}=/g" "${SYSROOT}/usr/bin/${AUTOSTART_NAME}"
        fi
        mkdir -p "${SYSROOT}/etc/xdg/autostart"
        cat > "${SYSROOT}/etc/xdg/autostart/${AUTOSTART_NAME%-autostart}.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=${INSTALLER_DESKTOP_TITLE}
Exec=${AUTOSTART_NAME}
X-GNOME-Autostart-enabled=true
NoDisplay=true
DESK
    fi
fi

# ── Desktop branding bake (boot screen / login / wallpaper / colours) ─────────
# Resolve --theme preset + --branding-dir + individual file overrides into ONE
# staging dir (later sources win), copy it into the image, and let hugmesh-
# branding bake the static pieces from the host into the sysroot (GRUB background,
# lightdm greeter background, /etc/skel + per-user colour scheme/accent, and the
# in-session wallpaper autostart). The same tool re-themes the running desktop
# later, UNLESS --brand-locked drops the lock. Applies to EVERY desktop image
# (standalone OR tailnet client; any installer front-end).
BRAND_GRUB_BG_STAGED=""
BRAND_GRUB_THEME_STAGED=""
# Branding flags only apply to desktop (ROLE_CLIENT) images; warn if set on a server role.
if ! ${ROLE_CLIENT} && { [ -n "${BRANDING_THEME}" ] || [ -n "${BRANDING_DIR}" ] \
        || [ -n "${BRAND_WALLPAPER}" ] || [ -n "${BRAND_GRUB_BG}" ] || [ -n "${BRAND_GRUB_THEME}" ] \
        || [ -n "${BRAND_LOGIN_BG}" ] || [ -n "${BRAND_LOGO}" ] || [ -n "${BRAND_ACCENT}" ] \
        || [ -n "${BRAND_COLOR_SCHEME}" ] || ${BRAND_LOCKED}; }; then
    warn "branding flags given for a non-desktop role (${ROLE}); branding applies to desktop images only — ignoring."
fi
if ${ROLE_CLIENT} && { [ -n "${BRANDING_THEME}" ] || [ -n "${BRANDING_DIR}" ] \
        || [ -n "${BRAND_WALLPAPER}" ] || [ -n "${BRAND_GRUB_BG}" ] \
        || [ -n "${BRAND_GRUB_THEME}" ] || [ -n "${BRAND_LOGIN_BG}" ] || [ -n "${BRAND_LOGO}" ] \
        || [ -n "${BRAND_ACCENT}" ] || [ -n "${BRAND_COLOR_SCHEME}" ] \
        || ${BRAND_LOCKED}; }; then
    banner "Branding desktop image (theme=${BRANDING_THEME:-none} locked=${BRAND_LOCKED})"
    _bd="$(mktemp -d)"
    # 1) named preset (lowest precedence) — specs-x86/branding/themes/<name>/
    if [ -n "${BRANDING_THEME}" ]; then
        _tdir="${SPECS_DIR}/branding/themes/${BRANDING_THEME}"
        [ -d "${_tdir}" ] || { err "unknown --theme '${BRANDING_THEME}' (looked in ${_tdir})"; exit 1; }
        cp -r "${_tdir}/." "${_bd}/"
    fi
    # 2) whole brand dir (overlays the preset)
    if [ -n "${BRANDING_DIR}" ]; then
        [ -d "${BRANDING_DIR}" ] || { err "--branding-dir not found: ${BRANDING_DIR}"; exit 1; }
        cp -r "${BRANDING_DIR}/." "${_bd}/"
    fi
    # 3) individual file overrides (highest precedence). err() is non-fatal, so make
    #    a bad path FATAL explicitly — otherwise a typo'd asset would ship unbranded.
    [ -n "${BRAND_WALLPAPER}" ]    && { [ -f "${BRAND_WALLPAPER}" ]    || { err "--wallpaper not found: ${BRAND_WALLPAPER}"; exit 1; };       cp "${BRAND_WALLPAPER}"    "${_bd}/wallpaper.png"; }
    [ -n "${BRAND_GRUB_BG}" ]      && { [ -f "${BRAND_GRUB_BG}" ]      || { err "--grub-background not found: ${BRAND_GRUB_BG}"; exit 1; };   cp "${BRAND_GRUB_BG}"      "${_bd}/grub-background.png"; }
    [ -n "${BRAND_LOGIN_BG}" ]     && { [ -f "${BRAND_LOGIN_BG}" ]     || { err "--login-background not found: ${BRAND_LOGIN_BG}"; exit 1; }; cp "${BRAND_LOGIN_BG}"     "${_bd}/login-background.png"; }
    [ -n "${BRAND_LOGO}" ]         && { [ -f "${BRAND_LOGO}" ]         || { err "--brand-logo not found: ${BRAND_LOGO}"; exit 1; };          cp "${BRAND_LOGO}"         "${_bd}/logo.png"; }
    [ -n "${BRAND_COLOR_SCHEME}" ] && { [ -f "${BRAND_COLOR_SCHEME}" ] || { err "--color-scheme not found: ${BRAND_COLOR_SCHEME}"; exit 1; }; cp "${BRAND_COLOR_SCHEME}" "${_bd}/colors.colors"; }
    [ -n "${BRAND_GRUB_THEME}" ]   && { [ -d "${BRAND_GRUB_THEME}" ]   || { err "--grub-theme dir not found: ${BRAND_GRUB_THEME}"; exit 1; }; rm -rf "${_bd}/grub-theme"; cp -r "${BRAND_GRUB_THEME}" "${_bd}/grub-theme"; }
    # 4) brand.conf — preset's values first (already copied), then identity + accent
    #    override (later assignments win when sourced). brand.conf is dot-sourced as
    #    root by hugmesh-branding at build AND first boot, so emit every value with
    #    `printf %q` (shell-safe quoting): a dot-sourced file can never execute injected
    #    code even if a value slipped past the up-front validators (defense-in-depth).
    {
        echo "# appended by build-x86-host-stage4.sh"
        printf 'BRAND_NAME=%q\n' "${BRAND}"
        printf 'BRAND_TITLE=%q\n' "${BRAND_TITLE}"
        [ -n "${BRAND_ACCENT}" ] && printf 'ACCENT_COLOR=%q\n' "${BRAND_ACCENT}"
    } >> "${_bd}/brand.conf"
    # stage assets + canonical brand.conf into the image
    mkdir -p "${SYSROOT}/etc/hugmesh/branding"
    cp -r "${_bd}/." "${SYSROOT}/etc/hugmesh/branding/" 2>/dev/null || true
    cp "${_bd}/brand.conf" "${SYSROOT}/etc/hugmesh/brand.conf" 2>/dev/null || true
    # copy the applier, then bake static pieces into the sysroot FROM THE HOST
    cp "${SHARED_SPECS}/usr/sbin/hugmesh-branding" "${SYSROOT}/usr/sbin/hugmesh-branding"; chmod +x "${SYSROOT}/usr/sbin/hugmesh-branding"
    HUGMESH_BRANDING_ROOT="${SYSROOT}" HUGMESH_BRANDING_BUILD=1 \
        bash "${SHARED_SPECS}/usr/sbin/hugmesh-branding" apply "${SYSROOT}/etc/hugmesh/branding" \
        || warn "branding bake reported a problem (continuing)"
    if ${BRAND_LOCKED}; then : > "${SYSROOT}/etc/hugmesh/branding.lock"; info "Branding LOCKED (users cannot re-theme this image)"; fi
    # first-boot hook: re-apply on the real system so the INSTALLED grub.cfg picks up
    # the background (the build-time host run has no grub.cfg / block devices).
    cat > "${SYSROOT}/etc/local.d/04-branding.start" <<'HOOK'
#!/bin/bash
# First-boot: finish branding on the real system (regenerate grub.cfg with the brand
# background). Idempotent; self-removes after a clean run.
[ -x /usr/sbin/hugmesh-branding ] && /usr/sbin/hugmesh-branding apply /etc/hugmesh/branding && rm -f "$0"
HOOK
    chmod +x "${SYSROOT}/etc/local.d/04-branding.start"
    # hand the resolved GRUB background + theme to the live-ISO builder (boot-screen brand)
    [ -f "${SYSROOT}/boot/grub/hugmesh-background.png" ] && BRAND_GRUB_BG_STAGED="${SYSROOT}/boot/grub/hugmesh-background.png"
    [ -f "${SYSROOT}/boot/grub/themes/hugmesh/theme.txt" ] && BRAND_GRUB_THEME_STAGED="${SYSROOT}/boot/grub/themes/hugmesh"
    rm -rf "${_bd}"
    info "Branding baked: $(ls "${SYSROOT}/etc/hugmesh/branding" 2>/dev/null | tr '\n' ' ')"
fi

# ── Egress VPN (NetworkManager) staging ──────────────────────────────────────
# Drop the admin's egress conf into the image + the hugmesh-egress-vpn tool; first
# boot imports it into NetworkManager (NM must be running, so this is a boot hook, not
# a build-time bake). Split-tunnel keeps the tailnet + LAN direct. --egress-vpn-locked
# makes a managed node: autoconnect + user cannot remove (an NM dispatcher re-asserts).
if ! ${ROLE_CLIENT} && [ -n "${EGRESS_VPN_FILE}" ]; then
    warn "--egress-vpn given for a non-desktop role (${ROLE}); egress VPN is a desktop/tailnet-node feature — ignoring."
fi
if ${ROLE_CLIENT} && [ -n "${EGRESS_VPN_FILE}" ]; then
    [ -f "${EGRESS_VPN_FILE}" ] || { err "--egress-vpn file not found: ${EGRESS_VPN_FILE}"; exit 1; }
    banner "Staging egress VPN (locked=${EGRESS_VPN_LOCKED})"
    mkdir -p "${SYSROOT}/etc/hugmesh/egress"
    cp "${EGRESS_VPN_FILE}" "${SYSROOT}/etc/hugmesh/egress/$(basename "${EGRESS_VPN_FILE}")"
    chmod 600 "${SYSROOT}/etc/hugmesh/egress/"* 2>/dev/null || true
    cp "${SHARED_SPECS}/usr/sbin/hugmesh-egress-vpn" "${SYSROOT}/usr/sbin/hugmesh-egress-vpn"; chmod +x "${SYSROOT}/usr/sbin/hugmesh-egress-vpn"
    if ${EGRESS_VPN_LOCKED}; then : > "${SYSROOT}/etc/hugmesh/egress/locked"; info "Egress VPN LOCKED (managed node: user cannot remove)"; fi
    # first-boot import (NM is up by the time local.d runs); bring it up if locked.
    cat > "${SYSROOT}/etc/local.d/05-egress-vpn.start" <<'HOOK'
#!/bin/bash
# First-boot: import the egress VPN into NetworkManager. Self-removes ONLY on a
# successful import, so an NM-not-ready race on first boot retries next boot instead
# of permanently losing the connection.
if [ -x /usr/sbin/hugmesh-egress-vpn ]; then
    if /usr/sbin/hugmesh-egress-vpn import; then
        [ -e /etc/hugmesh/egress/locked ] && /usr/sbin/hugmesh-egress-vpn up || true
        rm -f "$0"
    fi
fi
HOOK
    chmod +x "${SYSROOT}/etc/local.d/05-egress-vpn.start"
    # When locked, re-assert on every NM connectivity change so a deleted connection
    # comes back (defense-in-depth alongside the tool's refuse-when-locked).
    if ${EGRESS_VPN_LOCKED}; then
        mkdir -p "${SYSROOT}/etc/NetworkManager/dispatcher.d"
        cat > "${SYSROOT}/etc/NetworkManager/dispatcher.d/90-hugmesh-egress" <<'DISP'
#!/bin/bash
# Re-assert the locked egress VPN whenever NetworkManager signals a change.
[ -x /usr/sbin/hugmesh-egress-vpn ] && /usr/sbin/hugmesh-egress-vpn ensure || true
DISP
        chmod +x "${SYSROOT}/etc/NetworkManager/dispatcher.d/90-hugmesh-egress"
        # polkit: on a managed node, only wheel (admins) may modify/delete SYSTEM NM
        # connections — so a non-admin user cannot remove the locked egress via nmcli or
        # the network applet (the tool's refuse-when-locked + the dispatcher re-assert
        # are the other two layers). enable-disable/network-control stay open so the
        # user can still use Wi-Fi etc.
        mkdir -p "${SYSROOT}/etc/polkit-1/rules.d"
        cat > "${SYSROOT}/etc/polkit-1/rules.d/49-hugmesh-egress-lock.rules" <<'POLKIT'
// HugMesh managed egress node: restrict modification/deletion of system-wide
// NetworkManager connections to administrators (wheel). Baked only with --egress-vpn-locked.
polkit.addRule(function(action, subject) {
    if (subject.isInGroup("wheel")) { return polkit.Result.YES; }
    switch (action.id) {
        case "org.freedesktop.NetworkManager.settings.modify.system":
            return polkit.Result.NO;
    }
});
POLKIT
    fi
    info "Egress VPN staged: $(basename "${EGRESS_VPN_FILE}") (import at first boot)"
fi

# First-boot grow policy (read by the growroot service). Default "fill" => the
# root expands to fill the whole USB/SSD/NVMe on first boot; --grow none keeps the
# compact flashed layout; --grow <size> caps the root filesystem. A copy is also
# dropped on the ESP in build_img so it can be edited per-device after a flash.
write_growfs_conf "${SYSROOT}/etc/growfs.conf"

# Cluster GitOps payload + role markers.
# UNAFFILIATED: no /etc/hugmesh marker tree at all — every consumer of these
# markers (keys-provision, hugmesh-update, provision-time tooling) is platform
# machinery this image does not carry. The one FUNCTIONAL conf (home.conf) is
# written to the neutral /etc/gentoo/ above instead.
if ! ${UNAFFILIATED}; then
mkdir -p "${SYSROOT}/etc/hugmesh" "${SYSROOT}/var/lib/hugmesh"
echo "${ROLE}"           > "${SYSROOT}/etc/hugmesh/role"
echo "${CLUSTER_DOMAIN}" > "${SYSROOT}/etc/hugmesh/cluster-domain"
# Runtime ENV marker (test|prod). Read by bootstrap/provision; also documents
# the image's posture. test => LAN wildcard DNS authoritative; prod => public.
echo "${ENV}"            > "${SYSROOT}/etc/hugmesh/env"
# Bake the brand's mesh control-server URL so keys-provision can read it at
# first boot (env does not survive to first boot). Empty = local-first: the
# control node defaults server_url to its own LAN IP (resolve_endpoint).
if [ -n "${HEADSCALE_URL:-}" ]; then
    echo "${HEADSCALE_URL}" > "${SYSROOT}/etc/hugmesh/headscale-url"
    info "Baked HEADSCALE_URL=${HEADSCALE_URL} -> /etc/hugmesh/headscale-url"
fi
fi   # ! UNAFFILIATED (marker tree)
# Orchestration superdomain (WS-SUPER-B): bake the mesh plane's MagicDNS suffix so the
# image RECORDS the plane it belongs to. Self-contained brand-etc fold like secureboot
# (SB_ETC_DIR): affiliated -> /etc/hugmesh, unaffiliated -> /etc/gentoo. Only ever set
# on a MESH build (the Studio's gate), and an unaffiliated desktop is standalone and never
# mesh, so the /etc/gentoo branch is belt-and-braces. This is the AUTHORITATIVE on-image
# bake; the KEYS/provision channel remains the secret side.
if [ -n "${SUPERDOMAIN}" ]; then
    if ${UNAFFILIATED}; then _sd_etc="/etc/gentoo"; else _sd_etc="/etc/hugmesh"; fi
    mkdir -p "${SYSROOT}${_sd_etc}"
    echo "${SUPERDOMAIN}" > "${SYSROOT}${_sd_etc}/superdomain"
    info "Baked orchestration superdomain -> ${_sd_etc}/superdomain (${SUPERDOMAIN})"
fi
if ${UNAFFILIATED}; then
    info "Unaffiliated desktop: no marker tree, no cluster payload, no identity tie."
elif ${ROLE_CLIENT}; then
    # CLIENT (person device): bake the FD-08 person-role + domain tie and SKIP the
    # whole k8s/ArgoCD cluster GitOps tree — a client is a desktop, not a node. The
    # Casdoor binding + multi-domain tie are applied at first boot by keys-provision
    # (provision_desktop_governance) from the KEYS USB. See docs/CLIENT-IMAGES.md.
    echo "${PERSON_ROLE}" > "${SYSROOT}/etc/hugmesh/identity-role"
    { for d in ${DOMAINS//,/ }; do echo "${d}"; done; } > "${SYSROOT}/etc/hugmesh/domains"
    echo "${DESKTOP}"     > "${SYSROOT}/etc/hugmesh/desktop-weight"
    if ${STANDALONE}; then
        # STANDALONE desktop: a self-contained personal workstation. Bake the marker
        # so keys-provision + firstboot SKIP all Casdoor/OIDC/mesh provisioning and a
        # normal LOCAL USER logs in with the build-set password (no domain/SSO tie).
        echo "true" > "${SYSROOT}/etc/hugmesh/standalone"
        info "Standalone desktop: local user '${DEFAULT_USER}', no SSO/mesh/domain tie."
    fi
    # Login-side unlock factor markers (enrolled at first login; the device must be
    # present). Boot-side factors are handled by the installer (LUKS keyslots).
    [ "${UNLOCK_KEYFILE}" = "login" ] && { echo "keyfile" > "${SYSROOT}/etc/hugmesh/unlock-login"; info "Login factor: keyfile (enroll at first login)."; }
    [ "${UNLOCK_YUBIKEY}" = "login" ] && { echo "yubikey" > "${SYSROOT}/etc/hugmesh/unlock-login"; info "Login factor: YubiKey/pam_u2f (run pamu2fcfg at first login)."; }
    # superadmin field device (FD-04/FD-06): require a SEPARATE device password set at
    # first boot from a salted+hashed value on the KEYS USB (NEVER baked into the image
    # — mirrors the Casdoor superadmin-seed custody). The marker tells keys-provision's
    # provision_device_password() to enforce it. Standalone has no superadmin/Casdoor
    # concept, so it never sets this. See docs/CLIENT-IMAGES.md.
    if [ "${PERSON_ROLE}" = "superadmin" ] && ! ${STANDALONE}; then
        : > "${SYSROOT}/etc/hugmesh/device-password-required"
        info "Client device: superadmin variant — device password REQUIRED at first boot (hash from KEYS, not baked)"
    fi
    info "Client device: person-role=${PERSON_ROLE} domains='${DOMAINS:-<provision-time>}' desktop=${DESKTOP} (no k8s cluster payload)"
    rebrand_sysroot       # still rebrand markers/desktop configs hugmesh.net -> ${CLUSTER_DOMAIN}
    apply_idp_external    # I6.3: idp.conf + issuer/JWKS re-point on the /etc/hugmesh side (no cluster tree here); casdoor default = no-op
else
    cp -r "${SHARED_SPECS}/cluster" "${SYSROOT}/var/lib/hugmesh/cluster"
    # Only parameterize the games host URLs when games is actually selected; when
    # games is opt-out (default) gate_optional_services prunes it below anyway.
    case " ${OPTIONAL_SERVICES} " in
        *" games "*) parameterize_games_domain ;;  # rewrite .games -> ${GAMES_DOMAIN} (BEFORE rebrand; fixes games OIDC iss on the subdomain default)
    esac
    gate_env_apps             # prune ENV-specific ArgoCD apps from the baked copy
    bake_host_firewall        # Layer 3: host nftables backstop for RELEASE_STATE (independent of gate_env_apps' K8s-manifest layer)
    gate_optional_services    # prune OPTIONAL services (akkoma/tuwunel/phpbb/games) not in OPTIONAL_SERVICES
    gate_backing_services     # MANAGED backing services: prune in-mesh datastore + repoint consumer at hosted endpoint (empty selection = no-op)
    rebrand_sysroot           # rewrites hugmesh.net -> ${CLUSTER_DOMAIN} (incl. lan-dns/cloudflared/games)
    apply_idp_external        # I6.3: AFTER rebrand — idp.conf bake + issuer/JWKS rewrite + Casdoor-app gating + README-IDP.md; casdoor default = no-op
fi

# Identity, locale, CNI dirs
echo "${HOSTNAME}" > "${SYSROOT}/etc/hostname"
mkdir -p "${SYSROOT}/etc/conf.d"; echo "hostname=\"${HOSTNAME}\"" > "${SYSROOT}/etc/conf.d/hostname"

# Serial-console getty: the amd64 stage3 ships the ttyS0 agetty line COMMENTED (PC
# default = VGA), so headless x86 nodes had NO serial login prompt — unlike the
# aarch64 stage3, which ships ttyAMA0 active. Activate ttyS0 at 115200 (matching the
# grub console=ttyS0,115200) for serial-console parity with the Pi images and so a
# headless node can be logged in over a serial/hypervisor console, not just SSH.
if grep -qE '^#\s*s0:12345:respawn:/sbin/agetty -L [0-9]+ ttyS0 ' "${SYSROOT}/etc/inittab" 2>/dev/null; then
    sed -i -E 's|^#\s*(s0:12345:respawn:/sbin/agetty -L )[0-9]+( ttyS0 vt100)|\1115200\2|' "${SYSROOT}/etc/inittab"
    info "Activated ttyS0 serial getty (115200) in /etc/inittab for serial-console access"
fi
echo "${TIMEZONE}" > "${SYSROOT}/etc/timezone"
echo "en_US.UTF-8 UTF-8" > "${SYSROOT}/etc/locale.gen"
# CNI + keys-provision state dirs are platform machinery — none on unaffiliated.
${UNAFFILIATED} || mkdir -p "${SYSROOT}/opt/cni/bin" "${SYSROOT}/etc/cni/net.d" "${SYSROOT}/var/lib/keys-provision"

# Runlevels. growroot expands the ext4 root to fill the medium on first boot and
# orders itself before keys-provision (so provisioning sees the full disk).
# headscale (identity/mesh control server) runs only on the pki / omnibus nodes;
# worker roles (be/fe/be+gpu) reach the mesh as a tailscale client.
mkdir -p "${SYSROOT}/etc/runlevels/default"
if ${ROLE_CLIENT}; then
    # CLIENT desktop: NO containerd/kubelet/headscale (not a k8s node). Add the
    # desktop session stack: dbus + elogind (seat/login) + display-manager (lightdm).
    # UNAFFILIATED additionally drops keys-provision (KEYS-USB fleet provisioning —
    # platform machinery; the local user is created by the firstboot script instead).
    if ${UNAFFILIATED}; then
        SVCS=(sshd NetworkManager cronie haveged growroot auditd local dbus elogind display-manager)
    else
        SVCS=(sshd NetworkManager cronie haveged growroot keys-provision auditd local dbus elogind display-manager)
    fi
    # gui-libs/display-manager-init's /etc/init.d/display-manager reads this to decide
    # WHICH DM to launch; lightdm ships no OpenRC service. Without it the service falls
    # back to xdm and the image boots to a bare console (mirrors the frite fix).
    mkdir -p "${SYSROOT}/etc/conf.d"
    echo 'DISPLAYMANAGER="lightdm"' > "${SYSROOT}/etc/conf.d/display-manager"
    # lightdm needs a greeter + a default session wired explicitly: with only
    # lightdm-gtk-greeter installed the stock greeter-session (example-gtk-gnome) is
    # absent → blank greeter. Thin = openbox, full = xfce. Written pre-emerge so
    # CONFIG_PROTECT keeps it over the package default (same pattern as frite).
    # thin = LXDE (lxsession: openbox WM + lxpanel + pcmanfm — the turnkey LXDE-lite
    # stack in packages-desktop.list), full = xfce. Both ship an /usr/share/xsessions
    # .desktop of that name.
    # thin = LXDE, full = xfce, capable = KDE Plasma (X11 session 'plasmax11').
    # The greeter still lists every installed session, so this is just the default.
    _user_session="LXDE"; [ "${DESKTOP}" = "full" ] && _user_session="xfce"
    ${CAPABLE} && _user_session="plasmax11"
    mkdir -p "${SYSROOT}/etc/lightdm"
    cat > "${SYSROOT}/etc/lightdm/lightdm.conf" <<LIGHTDM
[LightDM]
[Seat:*]
greeter-session=lightdm-gtk-greeter
user-session=${_user_session}
LIGHTDM
    # External media-data device (Steam library + gocryptfs Vaults). Default ON,
    # configurable + optional. Render the config + install the boot-time detector
    # that finds the SEPARATE data disk by LABEL or by the marker dirs and mounts
    # it at ${MEDIA_MOUNT}, then points Steam at ${STEAM_DIR}. See media.conf.
    if ${MEDIA_DATA}; then
        # UNAFFILIATED (only reachable here with an explicit --media-data): same
        # functional machinery under neutral names — media-detect + a conf under
        # the neutral ${HOME_CONF_DIR}-style /etc/gentoo path.
        if ${UNAFFILIATED}; then _md_name="media-detect"; _md_conf_dir="/etc/gentoo"; else _md_name="hugmesh-media-detect"; _md_conf_dir="/etc/hugmesh"; fi
        mkdir -p "${SYSROOT}${_md_conf_dir}" "${SYSROOT}/usr/sbin"
        render_template "${SHARED_SPECS}/etc/hugmesh/media.conf.tmpl" "${SYSROOT}${_md_conf_dir}/media.conf"
        cp "${SHARED_SPECS}/usr/sbin/hugmesh-media-detect" "${SYSROOT}/usr/sbin/${_md_name}"; chmod +x "${SYSROOT}/usr/sbin/${_md_name}"
        cp "${SHARED_SPECS}/etc/init.d/hugmesh-media-detect" "${SYSROOT}/etc/init.d/${_md_name}"; chmod +x "${SYSROOT}/etc/init.d/${_md_name}"
        if ${UNAFFILIATED}; then
            grep -q '^CONF=/etc/hugmesh/media.conf' "${SYSROOT}/usr/sbin/${_md_name}" \
                || { err "hugmesh-media-detect drifted: CONF= line not found (unaffiliated rename would break silently)"; exit 1; }
            sed -i -e "s|/etc/hugmesh/media.conf|${_md_conf_dir}/media.conf|g" \
                   -e "s|/usr/sbin/hugmesh-media-detect|/usr/sbin/${_md_name}|g" \
                "${SYSROOT}/usr/sbin/${_md_name}" "${SYSROOT}/etc/init.d/${_md_name}"
        fi
        SVCS+=("${_md_name}")
        unset _md_name _md_conf_dir
        info "Media-data: /media auto-detect + Steam->${STEAM_DIR} + Vaults (gocryptfs) wired (steam=${STEAM_DELIVERY})"
    fi
else
    # NOTE: no 'firewall' entry — that name is an OpenRC virtual (see the alias
    # removal note above); firewalld is shipped but deliberately NOT enabled, the
    # nftables backstop (hugmesh-firewall-reconcile) owns the host firewall
    # (tests/qemu/assertions.sh keys its firewalld gate on exactly this).
    SVCS=(sshd NetworkManager cronie haveged growroot keys-provision hugmesh-firewall-reconcile hugmesh-coturn-firewall hugmesh-go-live-reconcile containerd kubelet auditd local)
    ${ROLE_HEADSCALE} && SVCS+=(headscale)
fi
${SKIP_MESH} || ${SKIP_TAILSCALE} || SVCS+=(tailscaled)

# ── Network/host security stack (Squid+Privoxy desktops / Snort all / AIDE opt-in) ──
# Resolve the proxy-stack default once (auto => desktops only) — used here for SVCS and
# later for the PKGS additions.
WANT_PROXY_STACK=false
case "${PROXY_STACK}" in
    true)  WANT_PROXY_STACK=true ;;
    auto)  ${ROLE_CLIENT} && WANT_PROXY_STACK=true ;;
esac
if ${WANT_PROXY_STACK}; then
    mkdir -p "${SYSROOT}/etc/squid" "${SYSROOT}/etc/privoxy" "${SYSROOT}/etc/firefox/policies" \
             "${SYSROOT}/var/cache/squid" "${SYSROOT}/var/log/privoxy"
    cp "${SHARED_SPECS}/etc/squid/squid.conf"               "${SYSROOT}/etc/squid/squid.conf"
    cp "${SHARED_SPECS}/etc/privoxy/config"                 "${SYSROOT}/etc/privoxy/config"
    cp "${SHARED_SPECS}/etc/firefox/policies/policies.json" "${SYSROOT}/etc/firefox/policies/policies.json"
    SVCS+=(squid privoxy)
    info "Proxy stack staged: Squid(127.0.0.1:3128) <- Privoxy(127.0.0.1:8118) <- Firefox policy"
fi
# ── Thin-desktop stream host (--with-sunshine, client desktops on the tailnet) ──
# Sunshine must run INSIDE the user's desktop session (display capture + uinput),
# so its launcher is XDG autostart via a wrapper — the OpenRC-image equivalent
# of a systemd user unit (this fleet's desktops are OpenRC; see docs/MDM.md
# 'Thin desktop'). The mesh fence is its own reconcile-family member: one
# script, one init.d oneshot, one clearly-scoped nftables table
# (hugmesh_thin_desktop), plus the 60s cron — installed DIRECTLY (not staged):
# the capability is decided at build time by this flag, unlike the
# optional-service crons a later selection step links.
if ${WANT_SUNSHINE}; then
    cp "${SHARED_SPECS}/usr/sbin/hugmesh-sunshine-firewall" "${SYSROOT}/usr/sbin/hugmesh-sunshine-firewall"
    chmod +x "${SYSROOT}/usr/sbin/hugmesh-sunshine-firewall"
    cp "${SHARED_SPECS}/etc/init.d/hugmesh-sunshine-firewall" "${SYSROOT}/etc/init.d/hugmesh-sunshine-firewall"
    chmod +x "${SYSROOT}/etc/init.d/hugmesh-sunshine-firewall"
    mkdir -p "${SYSROOT}/etc/cron.d"
    cp "${SHARED_SPECS}/etc/cron.d/hugmesh-sunshine-firewall" "${SYSROOT}/etc/cron.d/hugmesh-sunshine-firewall"
    SVCS+=(hugmesh-sunshine-firewall)
    cp "${SHARED_SPECS}/usr/bin/hugmesh-sunshine-session" "${SYSROOT}/usr/bin/hugmesh-sunshine-session"
    chmod +x "${SYSROOT}/usr/bin/hugmesh-sunshine-session"
    mkdir -p "${SYSROOT}/etc/hugmesh/thin-desktop"
    cp "${SHARED_SPECS}/etc/hugmesh/thin-desktop/sunshine.conf"       "${SYSROOT}/etc/hugmesh/thin-desktop/sunshine.conf"
    # WiVRn sibling path: documented CONFIG STUB only (native-OpenXR streaming
    # of the shadows-of-the-net PCVR build to the same headset) — no package,
    # no service; the stub names the follow-up work. docs/MDM.md 'Thin desktop'.
    cp "${SHARED_SPECS}/etc/hugmesh/thin-desktop/wivrn.toml.example"  "${SYSROOT}/etc/hugmesh/thin-desktop/wivrn.toml.example"
    mkdir -p "${SYSROOT}/etc/xdg/autostart"
    cat > "${SYSROOT}/etc/xdg/autostart/hugmesh-sunshine.desktop" <<'DESK'
[Desktop Entry]
Type=Application
Name=HugMesh thin-desktop stream host (Sunshine)
Comment=Streams this desktop session to mesh-enrolled headsets over the tailnet only (pairing UI: https://localhost:47990)
Exec=/usr/bin/hugmesh-sunshine-session
Terminal=false
X-GNOME-Autostart-enabled=true
DESK
    info "Thin desktop staged: Sunshine (in-session XDG autostart) + hugmesh-sunshine-firewall (stream ports tailnet-only, web UI loopback-only) + WiVRn config stub"
fi
if ${SNORT_IDS}; then
    mkdir -p "${SYSROOT}/etc/snort/rules" "${SYSROOT}/var/log/snort"
    cp "${SHARED_SPECS}/etc/snort/snort.conf"        "${SYSROOT}/etc/snort/snort.conf"
    cp "${SHARED_SPECS}/etc/snort/rules/local.rules" "${SYSROOT}/etc/snort/rules/local.rules"
    SVCS+=(snort)
    info "Snort IDS staged (default-on; alert mode on HOME_NET)"
fi
if ${WANT_AIDE}; then
    mkdir -p "${SYSROOT}/etc/aide" "${SYSROOT}/var/lib/aide"
    cp "${SHARED_SPECS}/etc/aide/aide.conf" "${SYSROOT}/etc/aide/aide.conf"
    # First boot: baseline the REAL installed system, then a daily integrity-check cron.
    cat > "${SYSROOT}/etc/local.d/06-aide-init.start" <<'HOOK'
#!/bin/bash
# First-boot: initialize the AIDE database against the installed system. Self-removes.
if command -v aide >/dev/null 2>&1 && [ ! -s /var/lib/aide/aide.db ]; then
    aide --init --config=/etc/aide/aide.conf && \
        cp -f /var/lib/aide/aide.db.new /var/lib/aide/aide.db && rm -f "$0"
fi
HOOK
    chmod +x "${SYSROOT}/etc/local.d/06-aide-init.start"
    mkdir -p "${SYSROOT}/etc/cron.daily"
    cat > "${SYSROOT}/etc/cron.daily/aide-check" <<'CRON'
#!/bin/bash
# Daily AIDE integrity check; output goes to root's mail / cron log.
[ -s /var/lib/aide/aide.db ] && aide --check --config=/etc/aide/aide.conf
CRON
    chmod +x "${SYSROOT}/etc/cron.daily/aide-check"
    info "AIDE staged (opt-in): DB init at first boot + daily aide --check cron"
fi

# Domain-registry -> brand-repo bridge (#4, DEFAULT-OFF optional service): link the
# reconcile agent ONLY when `domain-registry-bridge` is selected AND this is a k8s
# node (a CLIENT desktop is not a cluster member). Unselected => never linked + no
# cron => ZERO boot/cron execution (gate 1 of 3). The 60s cron (staged at
# /etc/hugmesh/registry/cron-domain-reconcile) is installed alongside.
if ! ${ROLE_CLIENT} && _opt_selected domain-registry-bridge; then
    SVCS+=(hugmesh-domain-reconcile)
    if [ -f "${SYSROOT}/etc/hugmesh/registry/cron-domain-reconcile" ]; then
        mkdir -p "${SYSROOT}/etc/cron.d"
        cp -f "${SYSROOT}/etc/hugmesh/registry/cron-domain-reconcile" \
              "${SYSROOT}/etc/cron.d/hugmesh-domain-reconcile"
        info "OPTIONAL_SERVICES: domain-registry-bridge selected — linked hugmesh-domain-reconcile + 60s cron"
    fi
fi

# Tor v3 onion (hidden) service (DEFAULT-OFF optional service): link ONLY the hugmesh
# reconcile agent into the default runlevel when 'tor' is selected AND this is a k8s node
# (a CLIENT desktop is not a cluster member) — mirroring egress-vpn, which links only its
# reconcile agent, not the daemon. The DISTRO `tor` service is NOT linked here: the
# reconcile agent OWNS tor's lifecycle (writes the managed torrc, mints the v3 onion
# keypair OFF-GIT under /var/lib/tor/hugmesh-onion, then `rc-service tor restart`),
# avoiding any double-start. The 24h refresh cron (staged at
# /etc/hugmesh/registry/cron-tor-reconcile) is installed alongside. Unselected =>
# reconcile not linked + net-vpn/tor absent => ZERO execution.
if ! ${ROLE_CLIENT} && _opt_selected tor; then
    SVCS+=(hugmesh-tor-reconcile)
    if [ -f "${SYSROOT}/etc/hugmesh/registry/cron-tor-reconcile" ]; then
        mkdir -p "${SYSROOT}/etc/cron.d"
        cp -f "${SYSROOT}/etc/hugmesh/registry/cron-tor-reconcile" \
              "${SYSROOT}/etc/cron.d/hugmesh-tor-reconcile"
        info "OPTIONAL_SERVICES: tor selected — linked hugmesh-tor-reconcile + 24h cron (reconcile agent owns the tor daemon; v3 onion keypair off-git, minted first-boot)"
    fi
fi
for s in "${SVCS[@]}"; do ln -sf "/etc/init.d/${s}" "${SYSROOT}/etc/runlevels/default/${s}" 2>/dev/null || true; done
# Belt-and-suspenders for shared / --resume sysroots: `ln -sf` only ADDS, so a prior
# role's run can leave a headscale runlevel symlink behind that a worker/client image
# would background-start. Remove it unless THIS role runs the control server. (Same
# Pi audit finding; clients + be/fe have ROLE_HEADSCALE=false.)
${ROLE_HEADSCALE} || rm -f "${SYSROOT}/etc/runlevels/default/headscale"

# ── Radio hardening: WiFi + Bluetooth DISABLED BY DEFAULT ──────────────────
# Shrink the attack surface — by default neither radio comes up: their kernel
# modules are blacklisted (modprobe.d) and a first-boot local.d action rfkill-
# blocks them + tells NetworkManager to leave WiFi unmanaged. ETHERNET + the
# Tailscale tailnet are UNTOUCHED. ENABLE_WIFI / ENABLE_BLUETOOTH (knobs/flags)
# re-enable each. NetworkManager bluetooth/bluez services are not in SVCS, so
# nothing extra is enabled when they stay off.
harden_radios "${SYSROOT}"

# ── 4b. Toolchain static restore (source-compiling roles) ──────────
# §8 (clean) strips *.a + crt*.o from usr/lib{,64} to shrink the IMAGE, but the
# sysroot is SHARED across roles (same BUILD_SUBDIR) and §3 skips re-extracting
# stage3 on --resume. So once any prior role's clean has stripped the toolchain
# statics, a source-compiling role (GPU: llvm/mesa) hits `ld: cannot find -lgcc`
# (then missing crt*.o / libc_nonshared.a) during emerge. Idempotently restore
# the compiler+glibc statics from the seed tarball before emerge — additive only,
# a cheap no-op when they're already present. Only GPU roles compile from source;
# binpkg-only roles (pki/be/fe) never link a toolchain and don't need these.
if ${GPU} && [ -z "$(find "${SYSROOT}/usr/lib/gcc" -name libgcc.a -print -quit 2>/dev/null)" ]; then
    banner "Restoring toolchain static libs from seed (GPU source-compile)"
    _statics_list="$(mktemp)"
    tar tJf "${STAGE3_LOCAL}" 2>/dev/null | grep -E '\.a$|/[^/]*crt[^/]*\.o$' > "${_statics_list}" || true
    if [ -s "${_statics_list}" ]; then
        tar xJf "${STAGE3_LOCAL}" -C "${SYSROOT}" -T "${_statics_list}" 2>/dev/null || true
        info "Restored $(wc -l < "${_statics_list}") toolchain static archives/crt objects from $(basename "${STAGE3_LOCAL}")"
    fi
    rm -f "${_statics_list}"
fi
# ── configure_root_login <sysroot> ────────────────────────────────────────────
# Root SSH login is DISABLED BY DEFAULT (hardened posture). Write an AUTHORITATIVE
# sshd drop-in (00- prefix => read first => wins, since sshd takes the FIRST
# PermitRootLogin value) from the PERMIT_ROOT_LOGIN toggle (no | prohibit-password |
# yes; default no). The static specs/.../hardened.conf 'PermitRootLogin no' stays as a
# fail-safe backstop. The non-root admin user (SSH key via the KEYS device-registry) is
# the intended entry point, so disabling root never bricks a node. Applies to EVERY role.
configure_root_login() {
    local sysroot="$1"
    local val="${PERMIT_ROOT_LOGIN:-no}"
    case "${val}" in no|yes|prohibit-password) ;; *) val=no ;; esac
    mkdir -p "${sysroot}/etc/ssh/sshd_config.d"
    {
        echo "# Generated by build-*-stage4.sh from PERMIT_ROOT_LOGIN. Root SSH login is"
        echo "# DISABLED by default; re-enable with --permit-root-login yes (or"
        echo "# prohibit-password for key-only root). 00- prefix => authoritative."
        echo "PermitRootLogin ${val}"
    } > "${sysroot}/etc/ssh/sshd_config.d/00-root-login.conf"
    if [ "${val}" = "no" ]; then
        info "Root SSH login DISABLED by default. Admin via the non-root KEYS user; re-enable with --permit-root-login yes."
    else
        info "Root SSH login set to '${val}' (--permit-root-login / PERMIT_ROOT_LOGIN=${val})."
    fi
}
configure_root_login "${SYSROOT}"

# CUDA host-compiler preflight: detect the CUDA-vs-seed-toolchain IMPOSSIBLE
# combination now, in seconds, instead of after the multi-hour @world pass. The
# edge_ai.x86 role emitted ZERO artifacts on 2026-07-19 because nvidia-cuda-
# toolkit's default gcc leg (<gcc-15_pre) had no candidate at all: the seed gcc
# is 15 and EMERGE_EXCLUDE's name-level `--exclude sys-devel/gcc` masked every
# installable gcc:14 — a RESOLUTION failure, so --keep-going could not help and
# NOT ONE payload package merged (build-edge_ai.x86.log:153744). The fix rides
# specs-x86/portage/package.use/nvidia (USE=clang -> the clang-19 leg); this
# preflight fails the build loudly whenever that combination ever re-forms
# (USE line dropped, new toolkit ebuild moving its caps, seed jumping again).
# Called HOST-side against ${SYSROOT} deliberately — inside the unquoted CHROOT
# heredoc every '$' would need escaping (the script's own integration note).
if ${NVIDIA_CUDA}; then
    _cuda_pf_args=(--sysroot "${SYSROOT}")
    ${REBUILD_TOOLCHAIN:-false} && _cuda_pf_args+=(--gcc-not-excluded)
    bash "${SCRIPT_DIR}/scripts/preflight-cuda-host-compiler.sh" "${_cuda_pf_args[@]}" \
        || { err "CUDA host-compiler preflight failed — this payload emerge CANNOT resolve (see above)."; exit 1; }
fi

# ── 5. Chroot setup + native emerge ────────────────────────────────
banner "Emerging @system (hardened, native chroot)"

# Guard: chrooting needs an amd64 sysroot. The amd64 and aarch64 builds now keep
# their sysroots in SEPARATE per-arch subdirs (snap-build-x86 vs snap-build-pi5),
# so a shared --work-dir no longer collides. This guard only trips if someone
# overrode --build-subdir to point both arches at the SAME subdir, or hand-built
# a foreign sysroot here; then `chroot /bin/bash` would die with a confusing
# "No such file or directory".
if [ -e "${SYSROOT}/bin/bash" ] && ! file -L "${SYSROOT}/bin/bash" 2>/dev/null | grep -qE 'x86-64|x86_64'; then
    err "Sysroot ${SYSROOT} is NOT amd64 (looks like a foreign arch — e.g. the RPi aarch64 build)."
    err "The x86 build uses its own --build-subdir (default snap-build-x86); make sure it does"
    err "NOT match the Pi build's subdir (snap-build-pi5), or use a separate --work-dir."
    err "Or remove the stale sysroot:  rm -rf '${SYSROOT}'  (then re-run without --resume)."
    exit 1
fi

cp -L /etc/resolv.conf "${SYSROOT}/etc/resolv.conf" 2>/dev/null || true
mount_chroot() {
    # Exclusive-build guard FIRST (idempotent — see the flock rationale at the
    # Extract phase): a --resume run reaches here without passing the fresh-start
    # wipe, so this is the last stop before two builds could share one chroot.
    acquire_build_lock
    mount -t proc none "${SYSROOT}/proc"
    mount --rbind /sys  "${SYSROOT}/sys";  mount --make-rslave "${SYSROOT}/sys"
    mount --rbind /dev  "${SYSROOT}/dev";  mount --make-rslave "${SYSROOT}/dev"
    mount --rbind /run  "${SYSROOT}/run";  mount --make-rslave "${SYSROOT}/run"
    # Reuse the host's portage tree if present (much faster than webrsync)
    if [ -d /var/db/repos/gentoo ]; then
        mkdir -p "${SYSROOT}/var/db/repos/gentoo"
        mount --bind /var/db/repos/gentoo "${SYSROOT}/var/db/repos/gentoo"
        HOST_REPO_MOUNTED=true
    else
        HOST_REPO_MOUNTED=false
    fi
    # Shared binpkg pool (issue #46): bind the per-arch pool over the chroot's
    # PKGDIR (/var/cache/binpkgs, make.conf.tmpl) so every amd64 role reads and
    # writes ONE pool instead of a discarded per-wl-<id> one — the wave-1 fix for
    # 0% x86 binpkg reuse. Same pattern as the repo/distfiles binds above: mounted
    # here, detached in umount_chroot, and the Phase-8 clean re-verifies the
    # detach with mountpoint -q before touching anything under the path (an rm -rf
    # through a live bind would empty the FLEET's pool). The pool was fingerprint-
    # guarded (sa_pool_guard) before this point; a mismatched pool never mounts.
    # NOTE: no fail-soft fallback — under `set -e` a failed bind aborts the build,
    # exactly like the repo bind (an unguarded silent fallback pool would be worse).
    if [ -n "${X86_POOL_DIR}" ] && [ -d "${X86_POOL_DIR}" ]; then
        mkdir -p "${SYSROOT}/var/cache/binpkgs"
        mount --bind "${X86_POOL_DIR}" "${SYSROOT}/var/cache/binpkgs"
        X86_POOL_MOUNTED=true
        info "Binpkg pool: shared ${X86_POOL_DIR} -> /var/cache/binpkgs (--usepkg reuse across all amd64 roles; --binpkg-respect-use=y prunes USE mismatches per-package)"
    else
        X86_POOL_MOUNTED=false
    fi
    # Package build scratch on a NON-eCryptfs filesystem. The work dir often lives
    # on eCryptfs (/home/.Private), whose ~143-char filename limit makes Go builds
    # (kubelet/runc/cni-plugins/containerd — long vendored/cache paths) die with
    # "File name too long". Bind the chroot's /var/tmp/portage onto a host xfs dir
    # so package builds dodge the limit; INSTALLED files (short names) still land in
    # the eCryptfs sysroot fine. Only kicks in when the sysroot is actually eCryptfs.
    PORTAGE_SCRATCH_MOUNTED=false
    if df -T "${SYSROOT}" 2>/dev/null | awk 'NR==2{exit($2=="ecryptfs"?0:1)}'; then
        # Prefer the dedicated /var/tmp/portage partition (its own large xfs) when
        # present — /var/tmp itself may be on a small root fs. Falls back to /var/tmp.
        local scratchbase=/var/tmp
        mountpoint -q /var/tmp/portage 2>/dev/null && scratchbase=/var/tmp/portage
        local scratch="${scratchbase}/snap-portage-${BUILD_SUBDIR}"
        # The scratch path is keyed on BUILD_SUBDIR ALONE, so same-role builds
        # from DIFFERENT WORK_DIRs (each holding its own BUILD_ROOT lock) still
        # collide right here — the 20260725-140638-09692d kill (see the flock
        # rationale at the Extract phase). Sibling lockfile, non-blocking, held
        # on fd 218 for the life of the build.
        if [ -z "${_SCRATCH_LOCK_HELD:-}" ]; then
            exec 218>>"${scratch}.lock"
            if ! flock -n 218; then
                err "portage build scratch ${scratch} is held by another build:"
                err "holder: $(cat "${scratch}.lock" 2>/dev/null || echo '<unreadable>')"
                err "(same --build-subdir from another work dir — both chroots would bind THIS"
                err "dir at /var/tmp/portage and portage's own per-package clean would delete"
                err "the other build's in-flight compile tree). Refusing to share it."
                exit 1
            fi
            printf 'pid=%s build_ts=%s role=%s work_dir=%s started=%s\n' \
                "$$" "${BUILD_TS}" "${ROLE:-?}" "${WORK_DIR}" "$(date -u +%FT%TZ)" > "${scratch}.lock"
            _SCRATCH_LOCK_HELD=1
        fi
        local availg; availg=$(df -BG --output=avail "${scratchbase}" 2>/dev/null | tail -1 | tr -dc '0-9')
        [ "${availg:-99}" -lt 15 ] && warn "only ${availg}G free on ${scratchbase} (xfs) for build scratch; a large parallel build may fill it (EMERGE_JOBS is held low to bound this)."
        mkdir -p "${scratch}" "${SYSROOT}/var/tmp/portage"
        mount --bind "${scratch}" "${SYSROOT}/var/tmp/portage" && PORTAGE_SCRATCH_MOUNTED=true
        info "Build scratch -> non-eCryptfs xfs ${scratch} (eCryptfs 143-char filename-limit workaround)"
    fi
    # Reuse a Gentoo distfiles cache from a mounted drive (skip re-downloads / build
    # offline). Search --distdir, then the top level of any /media/* drive, then the
    # mounted portage scratch. Exposed READ-ONLY via PORTAGE_RO_DISTDIRS so a cache on
    # a read-only USB still works (new sources still download into the normal DISTDIR).
    DISTFILES_MOUNTED=false
    local dd=""
    if [ -n "${DISTDIR_SRC}" ] && [ -d "${DISTDIR_SRC}" ]; then
        dd="${DISTDIR_SRC}"
    elif [ -n "${SHARED_DISTDIR}" ] && [ -d "${SHARED_DISTDIR}" ]; then
        # The fleet-wide distfiles the CROSS builders write (arch-independent source
        # tarballs — no ABI risk). Exposed READ-ONLY via the same bind + PORTAGE_RO_DISTDIRS
        # path an explicit --distdir takes; x86's own new fetches still land in its private
        # chroot DISTDIR, so this build never writes the shared cache.
        dd="${SHARED_DISTDIR}"
    else
        for cand in /media/distfiles /media/*/distfiles /media/*/portage/distfiles \
                    /var/tmp/portage/distfiles; do
            [ -d "${cand}" ] && { dd="${cand}"; break; }
        done
    fi
    if [ -n "${dd}" ]; then
        mkdir -p "${SYSROOT}/var/cache/distfiles-ro"
        if mount --bind "${dd}" "${SYSROOT}/var/cache/distfiles-ro"; then
            DISTFILES_MOUNTED=true
            grep -q 'PORTAGE_RO_DISTDIRS' "${SYSROOT}/etc/portage/make.conf" 2>/dev/null \
                || echo 'PORTAGE_RO_DISTDIRS="/var/cache/distfiles-ro"' >> "${SYSROOT}/etc/portage/make.conf"
            info "Distfiles: reusing cache ${dd} via PORTAGE_RO_DISTDIRS (read-only; no re-downloads)"
        fi
    fi
}
umount_chroot() {
    ${PORTAGE_SCRATCH_MOUNTED:-false} && umount -l "${SYSROOT}/var/tmp/portage" 2>/dev/null || true
    ${HOST_REPO_MOUNTED:-false} && umount -l "${SYSROOT}/var/db/repos/gentoo" 2>/dev/null || true
    ${X86_POOL_MOUNTED:-false} && umount -l "${SYSROOT}/var/cache/binpkgs" 2>/dev/null || true
    for m in run dev sys proc; do umount -lR "${SYSROOT}/$m" 2>/dev/null || true; done
}
trap umount_chroot EXIT
mount_chroot

# Base package set; the vendor-agnostic GPU stack (Mesa/Vulkan/libva) is appended
# ONLY for GPU roles (be+gpu / omnibus) so pki/be/fe images stay slim.
PKG_LISTS=("${SPECS_DIR}/portage/packages.list")
${GPU} && PKG_LISTS+=("${SPECS_DIR}/portage/packages-gpu.list")
# Proprietary NVIDIA driver atoms (x11-drivers/nvidia-drivers [+ CUDA] — see
# packages-gpu-nvidia.list). The CUDA atom is in a separate list so --nvidia-cuda
# is opt-in even within the proprietary stack.
if ${NVIDIA_PROPRIETARY}; then
    PKG_LISTS+=("${SPECS_DIR}/portage/packages-gpu-nvidia.list")
    ${NVIDIA_CUDA} && [ -f "${SPECS_DIR}/portage/packages-gpu-nvidia-cuda.list" ] \
        && PKG_LISTS+=("${SPECS_DIR}/portage/packages-gpu-nvidia-cuda.list")
fi
# AMD-PRO: open amdgpu display + the proprietary AMDGPU-PRO Vulkan/OpenCL stack.
${AMD_PRO} && [ -f "${SPECS_DIR}/portage/packages-gpu-amd-pro.list" ] \
    && PKG_LISTS+=("${SPECS_DIR}/portage/packages-gpu-amd-pro.list")
# INTEL-PRO: open Intel display + the Intel compute/media stack.
${INTEL_PRO} && [ -f "${SPECS_DIR}/portage/packages-gpu-intel-pro.list" ] \
    && PKG_LISTS+=("${SPECS_DIR}/portage/packages-gpu-intel-pro.list")
if ${ROLE_CLIENT}; then
    # Client desktop stack (Xorg/lightdm/openbox/NM-applet/browser/fonts/firewalld/
    # acpid). NOTE: the shared packages.list still carries the k8s atoms
    # (kubelet/containerd) for now — built but never enabled in a client SVCS set;
    # factoring them into a separate packages-k8s.list for a leaner thin client is a
    # documented follow-up (docs/CLIENT-IMAGES.md, Increment 1b).
    PKG_LISTS+=("${SPECS_DIR}/portage/packages-desktop.list")
    [ "${DESKTOP}" = "full" ] && [ -f "${SPECS_DIR}/portage/packages-desktop-full.list" ] \
        && PKG_LISTS+=("${SPECS_DIR}/portage/packages-desktop-full.list")
    # --capable / standalone-thick: the most-capable Plasma workstation set
    # (KDE Plasma + apps + office + media + dev), curated from this build host's world.
    ${CAPABLE} && [ -f "${SPECS_DIR}/portage/packages-desktop-capable.list" ] \
        && PKG_LISTS+=("${SPECS_DIR}/portage/packages-desktop-capable.list")
    # The media-data feature pulls gocryptfs (Vaults) + udisks2 + flatpak.
    ${MEDIA_DATA} && [ -f "${SPECS_DIR}/portage/packages-media-data.list" ] \
        && PKG_LISTS+=("${SPECS_DIR}/portage/packages-media-data.list")
    # Native Steam (games-util/steam-launcher) for the gaming desktops only.
    ${STEAM_NATIVE} && [ -f "${SPECS_DIR}/portage/packages-steam-native.list" ] \
        && PKG_LISTS+=("${SPECS_DIR}/portage/packages-steam-native.list")
    # Thin-desktop stream host (--with-sunshine, tailnet client desktops only).
    ${WANT_SUNSHINE} && [ -f "${SPECS_DIR}/portage/packages-sunshine.list" ] \
        && PKG_LISTS+=("${SPECS_DIR}/portage/packages-sunshine.list")
fi
# --seed-packages-from FILE: append a package list seeded from a running system
# ("copy all installed programs"). Appended LAST so it augments the curated set.
[ -n "${SEED_PACKAGES_FROM}" ] && PKG_LISTS+=("${SEED_PACKAGES_FROM}")
PKGS=$(grep -hv '^\s*#' "${PKG_LISTS[@]}" | grep -v '^\s*$' | tr '\n' ' ')
# UNAFFILIATED: strip the k8s node payload from the shared base list (kubelet/
# kubeadm/kubectl/containerd/cni-plugins/cri-tools — carried "built but never
# enabled" on branded client images; a plain desktop ships none of it). ~11 GiB
# of node payload and the most platform-shaped packages on the image.
if ${UNAFFILIATED}; then
    PKGS=$(printf '%s\n' ${PKGS} | grep -vE '^(sys-cluster/(kubelet|kubeadm|kubectl)|app-containers/(containerd|cni-plugins|cri-tools))$' | tr '\n' ' ')
    info "Unaffiliated: k8s node payload stripped from the package set"
fi
# YubiKey/FIDO2 as a LOGIN factor needs the PAM module on the image (enrollment —
# `pamu2fcfg` — happens at first login since the key must be present).
[ "${UNLOCK_YUBIKEY}" = "login" ] && PKGS="${PKGS} sys-auth/pam-u2f"
# Per-user ecryptfs home (layered on the LUKS root) needs the userspace tools + the
# kernel keyring helper; the PAM module ships with ecryptfs-utils.
${HOME_ENCRYPTED} && PKGS="${PKGS} sys-fs/ecryptfs-utils sys-apps/keyutils"
# Dockerized stack / mesh-node seeding needs a container runtime + compose in the image.
${WANT_DOCKER} && PKGS="${PKGS} app-containers/docker app-containers/docker-compose"
# Graphical Qt installer (Calamares) — pulls KPMcore for partitioning. Only on a GPU
# desktop role that already ships Qt6 (thick); harmless atom add otherwise.
${WANT_CALAMARES} && PKGS="${PKGS} app-admin/calamares"
# Egress VPN userspace: WireGuard (.conf) is native to NetworkManager + the kernel
# (wireguard-tools for `wg`); OpenVPN (.ovpn) needs the NM OpenVPN plugin + openvpn.
# ROLE_CLIENT-gated to MATCH the staging leg (which warns '--egress-vpn given for a
# non-desktop role ... ignoring' and stages nothing): a node role must not emerge
# the VPN userspace it was just told it will not use. Same condition as the
# CONFIG_WIREGUARD kernel fragment (inside the ROLE_CLIENT kernel arm below) and
# Studio's egress_vpn FieldScope classes=("desktop",).
if ${ROLE_CLIENT} && [ -n "${EGRESS_VPN_FILE}" ]; then
    case "${EGRESS_VPN_FILE}" in
        *.ovpn) PKGS="${PKGS} net-vpn/networkmanager-openvpn net-vpn/openvpn" ;;
        *)      PKGS="${PKGS} net-vpn/wireguard-tools" ;;
    esac
fi
# Tor NODE service (DEFAULT-OFF optional service): the v3 onion daemon (net-vpn/tor,
# which ships /etc/init.d/tor + /etc/tor/torrc + the tor:tor user). Only added when
# 'tor' is selected (parity with the egress-vpn package gate); otherwise the image does
# not carry it. net-vpn/tor inherits USE=selinux from a SELinux node profile, giving the
# upstream tor_t confinement the reconcile agent's hugmesh_tor.te references.
_opt_selected tor && PKGS="${PKGS} net-vpn/tor" && info "Tor NODE service: net-vpn/tor for the v3 hidden service (fe-gateway onion; keypair off-git, minted first-boot)"
# Network/host security stack: Squid+Privoxy (desktops), Snort (all), AIDE (opt-in).
# WANT_PROXY_STACK was resolved at the SVCS step above.
${WANT_PROXY_STACK} && PKGS="${PKGS} net-proxy/squid net-proxy/privoxy" && info "Proxy stack: Squid + Privoxy (Firefox wired to 127.0.0.1:8118 -> :3128)"
${SNORT_IDS}        && PKGS="${PKGS} net-analyzer/snort" && info "Snort IDS: default-on (disable with --no-snort)"
${WANT_AIDE}        && PKGS="${PKGS} app-forensics/aide" && info "AIDE file-integrity IDS: enabled (DB initialized at first boot)"
# GPU k8s nodes with the proprietary NVIDIA driver: the container toolkit provides
# /usr/bin/nvidia-container-runtime so containerd can pass the GPU to pods (the
# edge-AI inference service + GPU voice/video). NOT for client desktops (no k8s).
if ${GPU} && [ "${GPU_DRIVER}" = "nvidia" ] && ! ${ROLE_CLIENT}; then
    PKGS="${PKGS} app-containers/nvidia-container-toolkit"
    info "NVIDIA container toolkit: GPU pods schedule (nvidia.com/gpu + RuntimeClass nvidia)"
fi
${EDGE_AI} && info "Edge-AI inference NODE: serving an OpenAI-compatible model API to the mesh (runtime=${EDGE_AI_RUNTIME}; k8s + tailnet)"
${ROLE_CLIENT} && info "Client desktop role: including desktop stack (packages-desktop.list, weight=${DESKTOP}${CAPABLE:+ +capable})"
${GPU} && info "GPU role: including Mesa/Vulkan stack (packages-gpu.list)${NVIDIA_PROPRIETARY:+ + NVIDIA proprietary}" \
        || info "Headless role: skipping Mesa/Vulkan stack"
[ -n "${SEED_PACKAGES_FROM}" ] && info "Seed packages appended from: ${SEED_PACKAGES_FROM}"

# ── user package deltas (--packages-add / --packages-drop) ─────────────────────
# Applied LAST, after every built-in add + the UNAFFILIATED strip, so the operator's
# explicit set is authoritative. Adds are appended; drops are a final grep -vE over
# the fully-resolved set — NEVER `emerge --exclude`/INSTALL_MASK (those also strip
# transitive deps a kept package still needs). Atoms were charset-validated and the
# tier-1 mandatory floor enforced up front (before --print-plan).
[ -n "${PACKAGES_ADD}" ] && { PKGS="${PKGS} ${PACKAGES_ADD}"; info "Extra packages (--packages-add): ${PACKAGES_ADD}"; }
if [ -n "${PACKAGES_DROP}" ]; then
    _drop_re="$(printf '%s' "${PACKAGES_DROP}" | tr ' ' '\n' | grep -v '^$' | paste -sd'|' -)"
    PKGS=$(printf '%s\n' ${PKGS} | grep -vxE "${_drop_re}" | tr '\n' ' ')
    info "Dropped packages (--packages-drop): ${PACKAGES_DROP}"
fi

# A stage4 keeps the (already-built, hardened) seed toolchain — we do NOT want
# @world to drag in a brand-new gcc/glibc/binutils (e.g. a bleeding-edge
# gcc-16.x that may not even compile). Exclude the toolchain by default; opt in
# with REBUILD_TOOLCHAIN=true. --keep-going so one optional package can't abort
# the whole image.
REBUILD_TOOLCHAIN="${REBUILD_TOOLCHAIN:-false}"
if ${REBUILD_TOOLCHAIN}; then
    EMERGE_EXCLUDE=""
    info "Toolchain rebuild ENABLED (REBUILD_TOOLCHAIN=true)"
else
    EMERGE_EXCLUDE="--exclude sys-devel/gcc --exclude sys-libs/glibc --exclude sys-devel/binutils"
    info "Keeping seed toolchain (set REBUILD_TOOLCHAIN=true to rebuild gcc/glibc/binutils)"
fi

# Package-level emerge parallelism, MEMORY-BOUNDED. EMERGE_JOBS concurrent
# packages, each make -j${JOBS} -l${JOBS}. C builds self-throttle on the shared
# system load via -l (all makes read the same loadavg). Go builds (kubelet, runc,
# cni-plugins, containerd, nerdctl) IGNORE make's jobserver and -l, defaulting to
# GOMAXPROCS=ncpu — so several concurrent Go builds each spawning 28-way blew past
# 32 GB RAM and the OOM killer failed 6 diverse packages at once. Cap both: fewer
# concurrent packages (JOBS/7) AND a hard GOMAXPROCS so Go can't grab the machine.
# Held LOW (2): package build scratch is bind-mounted onto the 20 GB xfs / (the
# eCryptfs filename-limit workaround in mount_chroot), so few concurrent package
# builds keeps peak scratch within that budget — and also bounds the Go-build RAM
# that OOM-killed the payload. The kernel builds in /usr/src (sysroot), not here.
# EMERGE_JOBS=1: SERIALIZE package builds. At 2 concurrent, the payload's 8 Go
# packages (kubelet/runc/cni-plugins/containerd/nerdctl/cri-tools/...) overlapped
# and their shared-runtime recompiles were OOM-KILLED (silent death, no compiler
# error — confirmed). One package at a time means a single Go build has the whole
# 32 GB, so concurrent-build OOM is structurally impossible. Also keeps the
# bind-mounted scratch within the 20 GB xfs / budget. (Raise once known-good.)
EMERGE_JOBS=1
GO_PROCS=$(( JOBS / 7 )); [ "${GO_PROCS}" -lt 2 ] && GO_PROCS=2
# Role-specific mandatory-binary set for the post-emerge payload assert (expanded
# into the chroot heredoc on the host): clients assert the desktop stack, nodes the
# k8s stack. The base (grub-install dracut parted jq nmcli) is common to both.
if ${ROLE_CLIENT}; then SNAP_ROLE_BINS="Xorg lightdm openbox"; else SNAP_ROLE_BINS="kubelet kubeadm containerd"; fi
# Native Steam needs the steam-overlay enabled + synced inside the chroot BEFORE the
# payload emerge resolves games-util/steam-launcher. Use eselect-repository so we
# rely on Gentoo's canonical repositories.xml entry rather than hardcoding a URL.
# Non-fatal: if the overlay can't sync (offline build), Steam just won't merge and
# the operator can rebuild with --steam flatpak. Expanded into the heredoc below.
#
# EMERGE-GROUP BANNER (tools): app-eselect/eselect-repository is a portage HELPER —
# it exists to register the steam-overlay repo, never to ship in the role payload —
# so it is the 'tools' group. The banner is a bare echo "==> ..." (not banner()):
# this text is executed INSIDE the chroot payload, where the host's banner() shell
# function does not exist (chroot runs a fresh /bin/bash from the sysroot). The
# Studio parser matches the "==> " TEXT, not how it was produced (core/
# progress_parse.py:39 _BANNER_RE), so an echo is fully equivalent. Heredoc-safe:
# this string is single-quoted here (no host expansion) and a parameter expansion's
# RESULT is not re-scanned when it lands in the unquoted <<CHROOT heredoc below.
STEAM_OVERLAY_SETUP=""
if ${STEAM_NATIVE}; then
    STEAM_OVERLAY_SETUP='
echo "[build-x86] Native Steam: enabling + syncing the steam-overlay"
echo "==> Emerge group: tools"
emerge --noreplace --quiet-build app-eselect/eselect-repository 2>/dev/null || emerge --quiet-build app-eselect/eselect-repository || true
eselect repository enable steam-overlay 2>/dev/null || true
emaint sync -r steam-overlay 2>/dev/null || emerge --sync steam-overlay 2>/dev/null || echo "[build-x86] WARN: steam-overlay sync failed; native Steam may not resolve (rebuild with --steam flatpak)"'
fi
# ── BEGIN shared block: emerge-plan preview (lib staging) ─────────────────────
# The plan-preview emission (scripts/_emerge-plan-lib.sh) runs INSIDE the payload
# chroot, so the lib is staged into the sysroot's /tmp first — same pattern as the
# kernel phase's /tmp/k.config staging. Guarded: the preview is cosmetic, so a
# failed cp degrades to the no-op fallback defined inside the heredoc, never an
# aborted build. (The queued badges-Emit phase will stage its OWN sidecar under
# its OWN "emerge badges" sentinels + output file — keep the two blocks separate.)
cp "${SCRIPT_DIR}/scripts/_emerge-plan-lib.sh" "${SYSROOT}/tmp/hugmesh-emerge-plan-lib.sh" \
    || info "WARN: emerge-plan lib staging failed — plan preview will be skipped"
# ── END shared block: emerge-plan preview (lib staging) ───────────────────────
chroot "${SYSROOT}" /bin/bash -eo pipefail <<CHROOT
# NOTE: MAKEOPTS is NOT exported here on purpose. It comes from the chroot's
# make.conf (rendered "-j${JOBS} -l${JOBS}"). An exported MAKEOPTS env var takes
# precedence over package.env, which would SHADOW the per-package -j4 cap in
# env/llvm-lowmem.conf and let llvm-core/llvm + clang OOM-crash the host at -j28
# (observed). make.conf MAKEOPTS, by contrast, IS overridable by package.env —
# its canonical use — so the cap actually applies. Do not re-add the export.
export EMERGE_DEFAULT_OPTS="--jobs ${EMERGE_JOBS} --load-average ${JOBS} --usepkg=y --binpkg-respect-use=y"
# Bound Go's self-managed parallelism (it ignores MAKEOPTS/-l) so even a single
# kubelet/runc build doesn't spike RAM → OOM-killed compile.
export GOMAXPROCS=${GO_PROCS}
export GOFLAGS="-p=${GO_PROCS}"
# A working locale: the stage3 has none configured, so build steps that call
# setlocale (e.g. sys-fs/btrfs-progs' docs/python tooling) die with
# "locale.Error: unsupported locale setting". C.UTF-8 is built into glibc (no
# locale-gen needed) and is always valid.
export LANG=C.UTF-8 LC_ALL=C.UTF-8
# ...but C.UTF-8 ALONE is not enough for everything: gimp-3.x pkg_setup (Gentoo
# bug #969468) requires a REAL en_US.UTF-8 in the locale -a list and explicitly
# dies when LANG is C/POSIX/C.* as the fallback. /etc/locale.gen already carries
# en_US.UTF-8 (written at spec-install) — compile it into the locale archive.
# NB: this text sits in the UNQUOTED CHROOT heredoc — never use backticks or
# dollar-parens here, even in comments (the host shell expands them).
locale-gen || true
# Build chroot: /boot/efi exists in the baked fstab but is never mounted here.
# Without this, mount-boot.eclass (linux-firmware, grub-themes) dies in
# pkg_pretend ("/boot/efi not mounted") and ABORTS the ENTIRE package-set
# emerge before anything merges — producing a payload-less stage4.
export DONT_MOUNT_BOOT=1
# Refresh ld.so.cache up front so any libs INHERITED from a warm/reused sysroot
# (e.g. an interrupted prior run that merged sqlite but never ran ldconfig) are
# resolvable before the python-dependent package emerge needs them — otherwise
# wheel builds die on "libsqlite3.so.0: cannot open shared object file".
ldconfig 2>/dev/null || true
if [ ! -d /var/db/repos/gentoo/metadata ] && ! mountpoint -q /var/db/repos/gentoo; then
    emerge-webrsync
fi
# ── BEGIN shared block: emerge-plan preview (in-chroot init) ──────────────────
# Source the staged plan-preview lib and carry the host's opt-out flag in. The
# preview is cosmetic, so a missing lib (failed staging above) degrades to a
# defined no-op — under this shell's -e an unguarded 127 here would abort the
# whole payload. HEREDOC SAFETY: the two EMERGE_PLAN_* lines below expand ON
# THE HOST by design (they render a literal true/false and a literal integer,
# exactly like the KBUILTIN line in the kernel heredoc); every other line here
# is free of unescaped dollar signs, backticks and dollar-parens.
#
# BOTH knobs must be carried, not just the opt-out. The ARM cross builders source
# this lib in the HOST shell, so an exported EMERGE_PLAN_TIMEOUT reaches it for
# free there; x86 runs it inside this chroot, where nothing from the host
# environment survives. Carrying only EMERGE_PLAN_ENABLED made the documented
# timeout knob a silent no-op on x86 alone — the resolution would always use the
# lib's built-in 1800s default no matter what the operator set. Gated by the EPL
# bucket's chroot-env-parity check so the asymmetry cannot come back.
EMERGE_PLAN_ENABLED=${EMERGE_PLAN_ENABLED}
EMERGE_PLAN_TIMEOUT=${EMERGE_PLAN_TIMEOUT:-1800}
if [ -f /tmp/hugmesh-emerge-plan-lib.sh ]; then
    . /tmp/hugmesh-emerge-plan-lib.sh
else
    echo "[build-x86] WARN: emerge-plan lib not staged — plan preview skipped"
    emerge_plan_emit() { return 0; }
fi
# ── END shared block: emerge-plan preview (in-chroot init) ────────────────────
# ── EMERGE-GROUP BANNERS (Studio package sub-listing) ─────────────────────────
# Each "==> Emerge group: GROUP" line tells the Studio which of image|tools|
# dependencies|system|world the FOLLOWING ">>> Emerging (N of M) cat/pn-ver"
# stream belongs to, so the GUI can sub-list packages under the right group for
# BOTH mesh/node and standalone/client roles (they share this builder — the role
# only changes \${PKGS}, never which emerges run).
# One banner per contiguous run of the SAME group, not one per emerge command: a
# group is a SECTION of the stream (the parser holds the group until the next
# transition), so re-announcing "system" between baselayout and gettext would add
# a second, meaningless step to the job-level phase ladder.
# echo, not banner(): this runs inside the chroot payload, where the host's
# banner() shell function does not exist. progress_parse.py matches the "==> "
# TEXT (_BANNER_RE, progress_parse.py:39), so the two are equivalent.
# HEREDOC SAFETY: this sits in the UNQUOTED CHROOT heredoc — every line added
# here (comments INCLUDED, see the locale-gen note above) is deliberately free of
# unescaped dollar signs, backticks and dollar-parens, so the HOST shell expands
# nothing of it. tests/build-matrix/check.sh's emerge-group-banners probe
# re-verifies that mechanically on every run.
# system: sys-apps/portage + sys-apps/baselayout + the gettext downgrade are
# profile/base-layer packages (the package manager itself, the filesystem
# layout and the .mo-collision pin), not payload.
echo "==> Emerge group: system"
# ── sys-apps/portage FIRST and ALONE ──────────────────────────────────────────
# portage must NEVER self-upgrade in the middle of a long emerge: the running
# python keeps its old import graph while the merge replaces portage's files on
# disk, and the very next merge of that same run dies importing a module the
# upgrade moved. Live evidence (out/sessions/20260725-061608-978c99/build.log):
# sys-apps/portage-3.0.81.2 merged as "(238 of 258)" mid-run, then "(239 of
# 258)" died with
#   ModuleNotFoundError: No module named 'portage.util.env_update'
#   >>> Failed to install sys-apps/groff-1.23.0-r2, Log file:
# and the resumed run dropped 17 core packages (pam, dbus, gtk+3, polkit, ...)
# under --keep-going, with 3 more merges dying the same ">>> Failed to install"
# death (groff, elogind, pam_wrapper) — all shipped as PROD artifacts with
# exit 0. Session 20260724-013844-53b498 lost app-admin/perl-cleaner
# ("(67 of 67)") the same way. So: bring portage current in its OWN
# single-package emerge (the run ends right after the self-replace — the
# sequence emerge itself nags for), and belt-and-suspenders EXCLUDE it from
# the long passes below so a failed oneshot can never re-queue the
# self-upgrade mid-run. It sits at the TOP of the 'system' group: the merges
# after it are then served by the CURRENT portage, and the Studio lists the
# package manager under system rather than under whatever group a later
# banner (e.g. Steam's 'tools') happens to have opened.
# --newuse, not just --update: without it this emerge is a NO-OP whenever the seed
# already carries the newest sys-apps/portage, so the package manager keeps the
# SEED's USE — including its PYTHON_TARGETS — while --exclude sys-apps/portage
# below stops any later pass from ever reconciling it. That is exactly how session
# 20260729-233913-719d4e wedged: the seed portage stayed on python3_13/python3_14
# (BUILD_TIME 07-13, never rebuilt) and its app-portage/gemato kept demanding
# those targets from the same dev-python slots the payload was resolving, giving
# "Multiple package instances within a single package slot". The baselayout line
# directly below already carries --newuse for the same reason.
emerge --oneshot --update --newuse sys-apps/portage \
    || echo "[build-x86] WARN: standalone sys-apps/portage update failed; continuing with the seed portage (the passes below exclude it, so the mid-run self-replace hazard stays closed)"
emerge --oneshot --update --newuse sys-apps/baselayout || true
# gettext-0.23.x empty-\$(DOMAIN) .mo-collision pin (see package.mask/gettext):
# the stage3 seed ships gettext-0.23.2, so the mask (which only blocks upgrades)
# cannot help until gettext is first actively downgraded to the stable 0.22.5-r2
# BEFORE the first eautoreconf+autopoint consumer in @world regenerates its po
# infra. Non-fatal: if the tree lacks a <0.23 candidate on a given sync, the mask
# + the INSTALL_MASK dodge still prevent the literal '.mo' from shipping.
emerge --oneshot --update "<sys-devel/gettext-0.23" \
    || echo "[build-x86] WARN: gettext downgrade to <0.23 unavailable; relying on INSTALL_MASK"
${STEAM_OVERLAY_SETUP}
# Stream-mirror emerge output while extracting the three failure-notice shapes
# portage emits under --keep-going (consumed by the EMERGE FAILURE-NOTICE GATE
# below). awk, not tee with a process substitution: the pipeline only completes
# after awk exits, so the sink file is fully written when the gate reads it —
# no process-substitution flush race, no bash-5.1 wait dependency. (And per the
# NB above: NO backticks/dollar-parens anywhere in this heredoc, comments
# included — a backticked tee example here EXECUTED at host render and ate the
# operator's stdin, hanging the build at this very phase.) Byte shapes taken
# verbatim from out/sessions/20260725-061608-978c99/build.log — note the drop
# notice WRAPS mid-phrase (" * emerge --keep-going: x11-themes/adwaita-icon-
# theme-legacy-46.2 dropped" / " * because it requires x11-libs/gtk+:3"), so
# matching the full phrase "dropped because it requires" would MISS lines; the
# stable anchor is the " * emerge --keep-going: " prefix, which only the FIRST
# line of each notice carries (continuations are " * " + text).
_emerge_notice_sink() {
    awk '/^>>> Failed to (emerge|install) / || /^ \* emerge --keep-going: / { print >> "/tmp/hugmesh-emerge-failures.log" } { print }'
}
: > /tmp/hugmesh-emerge-failures.log
# Apply our profile/USE across @world without churning the toolchain.
# ── BEGIN shared block: emerge-plan preview (world) ───────────────────────────
# Read-only --pretend pass with the SAME argument vector as the merge directly
# below (check.sh's EPL bucket pins the textual parity), emitted BEFORE the
# banner so the Studio knows the resolved list up front. Never fatal: every
# failure path prints an honest unavailable line and returns 0. This line
# host-expands the same variables as the real merge line, by design.
emerge_plan_emit world emerge --update --deep --newuse --keep-going --exclude sys-apps/portage ${EMERGE_EXCLUDE} @world
# ── END shared block: emerge-plan preview (world) ─────────────────────────────
# world: the literal @world set — its own group.
echo "==> Emerge group: world"
emerge --update --deep --newuse --keep-going --exclude sys-apps/portage ${EMERGE_EXCLUDE} @world 2>&1 | _emerge_notice_sink \
    || echo "[build-x86] WARN: @world had package failures (--keep-going); continuing"
# The role payload is its own rung on the canonical ladder (stage id
# emerge-payload) on every platform; x86 used to fold it into one big
# 'Emerge packages' stage. Announced with echo for the same reason the
# group banners are: banner() does not exist inside the chroot.
echo "==> Emerging role payload (stage4, native chroot)"
# Ensure the stage4 package set is present (deps included).
# --autounmask-continue auto-applies any required USE-flag change and continues
# the merge (so a dep needing e.g. a USE flag doesn't ABORT resolution the way a
# bare emerge does), but --autounmask-keep-keywords / -keep-masks keep keyword &
# mask decisions EXPLICIT — those are pre-seeded in package.accept_keywords for a
# reproducible hardened build rather than silently pulling unstable/masked pkgs.
# image: \${PKGS} IS the role package set — the image payload itself. NOTE the
# --pretend AUTOUNMASK-PRETEND diagnostic in the failure branch below gets NO
# banner: --pretend merges nothing and emits no ">>> Emerging (N of M)" lines, so
# announcing a group there would open an empty group in the Studio.
# ── BEGIN shared block: emerge-plan preview (image) ───────────────────────────
# Same-argument --pretend preview of the payload merge directly below (EPL-
# pinned parity, one line vs the real merge's continuations). Runs AFTER the
# @world merge so the plan is resolved against the same sysroot state the
# payload merge will see. Never fatal — unavailable line + return 0 on any
# failure. Host-expands the same variables as the real merge, by design.
emerge_plan_emit image emerge --update --deep --newuse --keep-going --autounmask-continue=y --autounmask-keep-keywords=y --autounmask-keep-masks=y --exclude sys-apps/portage ${EMERGE_EXCLUDE} ${PKGS}
# ── END shared block: emerge-plan preview (image) ─────────────────────────────
echo "==> Emerge group: image"
emerge --update --deep --newuse --keep-going \
    --autounmask-continue=y --autounmask-keep-keywords=y --autounmask-keep-masks=y \
    --exclude sys-apps/portage \
    ${EMERGE_EXCLUDE} ${PKGS} 2>&1 | _emerge_notice_sink \
    || { echo "[build-x86] WARN: some stage4 packages failed; review the emerge output"
         # DIAGNOSTIC: --autounmask-continue is NOT applying needed USE changes in
         # this chroot, so resolution dies one conflict at a time. A PRETEND
         # --autounmask pass computes the COMPLETE set of USE changes the payload
         # needs in one go — dump it so they can all be pre-seeded into the
         # package.use specs at once instead of whack-a-mole.
         echo "[build-x86] ===== AUTOUNMASK-PRETEND: full USE/keyword changes the payload needs ====="
         emerge --pretend --autounmask=y --autounmask-write=n --autounmask-backtrack=y \
             --keep-going --exclude sys-apps/portage ${EMERGE_EXCLUDE} ${PKGS} 2>&1 \
             | grep -E 'USE changes|keyword changes|^# |^>=|^<|^=|Change USE|necessary|masked by' \
             || true
         echo "[build-x86] ===== END AUTOUNMASK-PRETEND ====="; }
# Rebuild the dynamic-linker cache: with sandbox/postinst hooks disabled in this
# chroot, ldconfig can be skipped after a merge, leaving e.g. libsqlite3.so.0
# present on disk but absent from /etc/ld.so.cache — python wheel builds then die
# with "libsqlite3.so.0: cannot open shared object file" and cascade-fail the
# whole python-dependent package set. Refresh it explicitly before depending on it.
ldconfig 2>/dev/null || true
# The packages.list payload is MANDATORY for a usable role image — fail LOUDLY
# if the core set is missing rather than emit a payload-less stage4 (this
# happened silently for every x86 role until the DONT_MOUNT_BOOT fix above).
missing=""
for b in grub-install dracut parted jq nmcli ${SNAP_ROLE_BINS}; do
    command -v "\${b}" >/dev/null || missing="\${missing} \${b}"
done
if [ -n "\${missing}" ]; then
    echo "[build-x86] ERROR: stage4 payload incomplete — missing:\${missing}"
    echo "[build-x86]        packages.list did not merge; review the emerge output above."
    exit 1
fi
# ── REQUESTED-ATOM COMPLETENESS GATE ──────────────────────────────────────────
# The binary probe above only covers a HANDFUL of well-known commands, so a
# package that fails under --keep-going ships a SILENTLY DEGRADED image that
# still looks like a clean build. That is not theoretical: app-office/
# libreoffice failed check-if-root ("Building LibreOffice as root is a very bad
# idea") on 2026-07-25 and session 20260725-061608-978c99 went right on to emit
# a complete set of standalone-unaffiliated PROD artifacts with no office suite
# on them. Nothing in the build said a word.
#
# So: assert that EVERY atom we asked for is actually installed. portage's own
# vardb match() is the authority (one python startup for the whole set — a
# per-atom portageq loop would add minutes), and it understands every atom form
# the lists can carry (plain cat/pn, =cat/pn-ver, <cat/pn-ver, slots, virtuals).
# Anything portage cannot parse is reported rather than skipped.
printf '%s\n' ${PKGS} > /tmp/hugmesh-requested-atoms.txt
: > /tmp/hugmesh-missing-atoms.txt
# Guarded: a gate that ABORTS a six-hour build because its own tooling misfired
# would be worse than the hole it closes, so tooling failure is a loud WARN and
# only a real missing package is fatal. (portage itself is python3, so the
# fallback branch is unreachable in practice — it exists to stay honest.)
if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PYEOF' > /tmp/hugmesh-missing-atoms.txt || echo "[build-x86] WARN: completeness gate could not run (portage python API error) — package set NOT verified" >&2
import portage
vardb = portage.db[portage.settings["EROOT"]]["vartree"].dbapi
seen, out = set(), []
with open("/tmp/hugmesh-requested-atoms.txt") as fh:
    for line in fh:
        atom = line.strip()
        if not atom or atom in seen:
            continue
        seen.add(atom)
        try:
            if not vardb.match(atom):
                out.append(atom)
        except Exception as exc:
            out.append("%s  (unparsable atom: %s)" % (atom, exc))
# Emit NOTHING when nothing is missing. Joining an empty list still prints a
# bare newline, which is a 1-byte file — and -s is TRUE for that, so the
# gate failed EVERY clean build with "1 requested package(s) are NOT installed"
# followed by a blank line. That is exactly what killed the 2026-07-29 x86 pki
# mesh build (out/sessions/20260729-065121-ce11e0/build-pki.x86.log) after a
# fully successful emerge. The shell side below now also counts NON-BLANK lines,
# so either guard alone is sufficient.
if out:
    print("\n".join(out))
PYEOF
else
    echo "[build-x86] WARN: python3 absent — requested-atom completeness gate SKIPPED" >&2
fi
_missing_n=\$(grep -c '[^[:space:]]' /tmp/hugmesh-missing-atoms.txt 2>/dev/null || true)
[ -n "\${_missing_n}" ] || _missing_n=0
if [ "\${_missing_n}" -gt 0 ]; then
    echo "[build-x86] ERROR: \${_missing_n} requested package(s) are NOT installed:"
    sed 's/^/[build-x86]          /' /tmp/hugmesh-missing-atoms.txt
    echo "[build-x86]        The emerge above ran with --keep-going, so these failed WITHOUT"
    echo "[build-x86]        aborting it. Their per-package logs are in /var/log/portage/build/."
    if [ "${ALLOW_MISSING_PACKAGES}" = "true" ]; then
        echo "[build-x86] WARN: --allow-missing-packages given — shipping a DEGRADED image anyway."
    else
        echo "[build-x86]        Fix them, or rebuild with --allow-missing-packages to accept a"
        echo "[build-x86]        knowingly degraded image."
        exit 1
    fi
else
    echo "[build-x86] Package completeness: all \$(sort -u /tmp/hugmesh-requested-atoms.txt | grep -c .) requested atoms installed."
fi
# ── EMERGE FAILURE-NOTICE GATE ────────────────────────────────────────────────
# The requested-atom gate above only verifies atoms WE asked for. A DEPENDENCY
# that fails ships just as silently: session 20260725-061608-978c99 lost 20 core
# packages (sys-libs/pam, sys-apps/dbus, x11-libs/gtk+, sys-auth/polkit, ... —
# 17 dropped + groff/elogind/pam_wrapper dead in the merge phase) to
# an emerge --keep-going cascade — none of them requested atoms — and still
# emitted PROD artifacts with exit 0. The only trace was in the emerge output:
#   >>> Failed to install sys-apps/groff-1.23.0-r2, Log file:
#    * emerge --keep-going: sys-apps/dbus-1.16.2 dropped because it requires sys-
# ">>> Failed to install" (a MERGE-phase death, e.g. the portage self-upgrade
# ModuleNotFoundError above) and the "dropped because it requires" cascade are
# shapes no assertion ever looked at. The _emerge_notice_sink captured every
# such line; here each named package is VERIFIED against portage's vardb (a
# later pass may legitimately have healed it — e.g. autounmask on the second
# emerge), and anything still absent fails the build. Exact-version match on
# purpose: the failed cpv absent from vardb is the signal; an OLD version left
# behind by the failed upgrade must NOT count as healed (groff was exactly
# that case). Unparsable/wrapped notices count as failures — fail closed.
if [ -s /tmp/hugmesh-emerge-failures.log ]; then
    sort -u /tmp/hugmesh-emerge-failures.log > /tmp/hugmesh-emerge-failures.uniq
    : > /tmp/hugmesh-emerge-still-broken.txt
    if command -v python3 >/dev/null 2>&1; then
        python3 - <<'PYEOF' > /tmp/hugmesh-emerge-still-broken.txt || echo "[build-x86] WARN: failure-notice gate could not run (portage python API error) — emerge failure notices NOT verified" >&2
import re
import portage
vardb = portage.db[portage.settings["EROOT"]]["vartree"].dbapi
pat_fail = re.compile(r'>>> Failed to (?:emerge|install) (\S+)')
pat_drop = re.compile(r'\* emerge --keep-going: (\S+)')
seen, still = set(), []
with open("/tmp/hugmesh-emerge-failures.uniq") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line.strip():
            continue
        m = pat_fail.search(line) or pat_drop.search(line)
        if not m:
            still.append(line.strip() + "  [unparsable notice - counted as failed]")
            continue
        cpv = m.group(1).rstrip(",")
        if cpv in seen:
            continue
        seen.add(cpv)
        try:
            if not vardb.match("=" + cpv):
                still.append(cpv + "  (" + line.strip() + ")")
        except Exception as exc:
            still.append(cpv + "  [unverifiable atom: " + str(exc) + " - counted as failed]")
# Emit NOTHING when clean — print("\n".join([])) writes a 1-byte newline the
# shell side would miscount (the exact bug the requested-atom gate shipped once;
# see its comment). Same guard here.
if still:
    print("\n".join(still))
PYEOF
    else
        # No python3 = no vardb verification; treat every notice as unresolved.
        cp /tmp/hugmesh-emerge-failures.uniq /tmp/hugmesh-emerge-still-broken.txt
    fi
    _broken_n=\$(grep -c '[^[:space:]]' /tmp/hugmesh-emerge-still-broken.txt 2>/dev/null || true)
    [ -n "\${_broken_n}" ] || _broken_n=0
    if [ "\${_broken_n}" -gt 0 ]; then
        echo "[build-x86] ERROR: emerge reported \${_broken_n} failed/dropped merge(s) still absent from the system:"
        sed 's/^/[build-x86]          /' /tmp/hugmesh-emerge-still-broken.txt
        echo "[build-x86]        These are dependency-level failures the requested-atom gate cannot see"
        echo "[build-x86]        (a dep is not a requested atom). Per-package logs: /var/log/portage/build/."
        if [ "${ALLOW_MISSING_PACKAGES}" = "true" ]; then
            echo "[build-x86] WARN: --allow-missing-packages given — shipping a DEGRADED image anyway."
        else
            echo "[build-x86]        Fix them, or rebuild with --allow-missing-packages to accept a"
            echo "[build-x86]        knowingly degraded image."
            exit 1
        fi
    else
        _notice_n=\$(grep -c '[^[:space:]]' /tmp/hugmesh-emerge-failures.uniq 2>/dev/null || true)
        echo "[build-x86] Emerge failure notices: \${_notice_n:-0} line(s) seen, every named package verified installed by a later pass."
    fi
else
    echo "[build-x86] Emerge failure notices: none."
fi
CHROOT

# ── --packages-only: prebuild the binpkg pool, then STOP before image assembly ──
# The chroot emerge above populated PKGDIR under FEATURES=buildpkg — the SHARED
# per-arch pool (${X86_POOL_DIR}, bind-mounted at /var/cache/binpkgs) when sharing
# is on, the chroot-internal ${SYSROOT}/var/cache/binpkgs with --no-shared-assets.
# In --packages-only mode we exit NOW — before Phase 6 (mesh), the kernel, and
# image/ISO/squashfs assembly — so the ONLY output is the binpkg pool a later
# per-role image build reuses via --usepkg. With the shared pool that pool lives
# OUTSIDE the sysroot and survives everything (the EXIT trap detaches the bind);
# only the legacy private pool still needs the --resume caveat below. We never
# reach the Phase-8 clean that strips the cache, and we emit NOTHING image-shaped.
if ${PACKAGES_ONLY}; then
    ISO_CACHED=true   # belt-and-suspenders: the strip is downstream of this exit anyway
    info "--packages-only: binpkg pool prebuilt at ${X86_POOL_DIR:-${SYSROOT}/var/cache/binpkgs} — skipping image assembly (PLAN_PACKAGES_ONLY=1)"
    if [ -n "${X86_POOL_DIR}" ]; then
        info "No kernel, no mesh, no img/iso/tar emitted; every later amd64 build reuses the shared pool via --usepkg automatically."
    else
        info "No kernel, no mesh, no img/iso/tar emitted; reuse via a later --role build with --usepkg (--resume)."
    fi
    exit 0
fi

# ── 6. Mesh VPN (amd64 static binaries) ────────────────────────────
if ${SKIP_MESH}; then
    banner "SKIPPED mesh VPN (--skip-mesh)"
else
    banner "Installing mesh VPN (headscale + tailscale, amd64)"
    # Pinned versions (HEADSCALE_VERSION / TAILSCALE_VERSION) + publisher checksum
    # verification: headscale releases ship checksums.txt; tailscale ships a
    # <tgz>.sha256 sidecar. Fetch the manifest, verify sha256, ABORT on any
    # mismatch — a tampered binary can no longer reach the mesh runlevel.
    # (Mirrors the rpi5/frite/jetson builders' Phase 2.5 verification.)
    HS_REL="https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}"
    HS_BIN="${SYSROOT}/usr/bin/headscale"
    if dlv_fetch_retry "${HS_REL}/headscale_${HEADSCALE_VERSION}_linux_amd64" "${HS_BIN}"; then
        # Verify sha256 against the release checksums.txt BEFORE trusting it.
        HS_SUMS="${BUILD_ROOT}/headscale_${HEADSCALE_VERSION}_checksums.txt"
        if ! dlv_fetch "${HS_REL}/checksums.txt" "${HS_SUMS}" \
           || ! dlv_verify_from_sumsfile "${HS_BIN}" "headscale_${HEADSCALE_VERSION}_linux_amd64" "${HS_SUMS}" sha256; then
            rm -f "${HS_BIN}"
            err "headscale ${HEADSCALE_VERSION} checksum verification FAILED — refusing to ship an unverified control-plane binary."
            exit 1
        fi
        chmod +x "${HS_BIN}"
        file "${HS_BIN}" | grep -q 'ELF.*x86-64' || {
            rm -f "${HS_BIN}"
            err "headscale binary is not x86-64 — check --headscale-version"
            exit 1
        }
        info "headscale installed + sha256-verified"
    else
        rm -f "${HS_BIN}"   # curl -o may leave a truncated file behind
        err "headscale fetch failed — the image enables its service in the runlevel; aborting (use --skip-mesh to opt out)"; exit 1; fi
    if ! ${SKIP_TAILSCALE}; then
        TS_URL="https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_amd64.tgz"
        TGZ="${BUILD_ROOT}/tailscale_${TAILSCALE_VERSION}_amd64.tgz"
        if dlv_fetch_retry "${TS_URL}" "${TGZ}"; then
            # Verify sha256 against the published <tgz>.sha256 sidecar BEFORE extracting.
            TS_SHA="${TGZ}.sha256"
            if ! dlv_fetch "${TS_URL}.sha256" "${TS_SHA}" \
               || ! dlv_verify_sha256_sidecar "${TGZ}" "${TS_SHA}"; then
                rm -f "${TGZ}"
                err "tailscale ${TAILSCALE_VERSION} checksum verification FAILED — refusing to ship an unverified mesh client."
                exit 1
            fi
            TMP="$(mktemp -d)"; tar -C "${TMP}" -xzf "${TGZ}"
            SUB="$(find "${TMP}" -maxdepth 1 -type d -name 'tailscale_*' | head -1)"
            install -Dm0755 "${SUB}/tailscale" "${SYSROOT}/usr/bin/tailscale"
            install -Dm0755 "${SUB}/tailscaled" "${SYSROOT}/usr/sbin/tailscaled"
            rm -rf "${TMP}"; info "tailscale installed + sha256-verified"
        else err "tailscale fetch failed — tailscaled is enabled in the runlevel; aborting (use --skip-tailscale to opt out)"; exit 1; fi
    fi
fi

# ── 7. Kernel (Gentoo HARDENED kernel) ─────────────────────────────
# sys-kernel/hardened-sources (grsecurity) was removed from Gentoo in 2017. The
# modern Gentoo hardened kernel = sys-kernel/gentoo-sources built under the
# hardened profile (PIE/SSP toolchain) with the KSPP + SELinux hardening config
# fragment applied below. This step is SELF-SUFFICIENT + idempotent: the main
# package emerge may have aborted, so it re-ensures the sources + /usr/src/linux
# symlink exist before building, and fails loudly if core hardening didn't take.

# ── SIGNED-KERNEL ARTIFACT CACHE (G4) ─────────────────────────────────────────
# Compiling and signing a kernel that is byte-identical to one this fleet already
# built is pure waste: the same keys sign every device, so a kernel is reusable
# across images of the SAME board whenever board + kernel version + kernel config
# + SIGNING IDENTITY all match. Those four ARE the cache key (kc_cache_key).
#
# WHAT IS AND IS NOT SKIPPED ON A HIT. A hit replaces the COMPILE. It never
# replaces a CHECK: the DISK-INITRAMFS GATE, the build_img seal gate and the
# Secure Boot signing step all sit OUTSIDE this block and run identically on a
# hit and on a miss. The in-chroot KSPP/SELinux/k8s/LSM config assertions are the
# one thing a hit does not re-run — and they are safe to skip precisely because
# they are a pure function of (kernel source tree, assembled config), which is
# what components 2 and 3 of the key pin. Change either and the key changes.
#
# COMPONENT 3 IS WIDER THAN "the .config". The cached payload includes the
# initramfs and the unsigned UKI, so everything that decides THOSE has to be in
# the digest too, or a hit would hand back an initramfs built for a different
# world. kernel_cache_inputs() therefore also folds in --kernel-builtin and its
# keep-as-module list, the dracut drop-ins, the kernel cmdline source
# (/etc/default/grub), and the VERSIONS of dracut and systemd-utils in the
# sysroot (the sd-stub owner) — a dracut upgrade must invalidate the initramfs.
KCACHE_KEY=""; KCACHE_KVER=""; KCACHE_CFG=""; KCACHE_FP=""; KCACHE_HIT=false
KCACHE_TMP="${BUILD_ROOT}/kernel-cache-work"
# QUOTED on purpose: an array assignment performs pathname expansion, so a bare
# vmlinuz-* here would silently expand against the builder's CURRENT DIRECTORY and
# bake whatever it found into the payload list. These must reach kc_names_matching
# as literal patterns, to be expanded against ${SYSROOT}/boot and nowhere else.
KCACHE_BOOT_GLOBS=('vmlinuz' 'vmlinuz-*' 'initramfs-*.img' 'System.map*' 'config-*' '*-unsigned.efi')

# kernel_cache_inputs — write the extra key inputs to <SYSROOT>/tmp/k.cache-inputs.
# Everything here changes the CACHED ARTIFACTS without changing the config fragments.
kernel_cache_inputs() {
    local f="${SYSROOT}/tmp/k.cache-inputs" d
    mkdir -p "${SYSROOT}/tmp" 2>/dev/null || return 1
    {
        printf 'kernel-builtin=%s\n' "${KERNEL_BUILTIN}"
        printf 'uki-name=%s\n'       "${UKI_NAME}"
        # The UKI cmdline PREFIX this builder injects (root=LABEL=... ro). It is NOT in
        # /etc/default/grub — that file only carries the APPEND half (GRUB_CMDLINE_LINUX),
        # which the grub-default= digest below already covers. Without this line a change
        # to the prefix leaves the key identical, the cache HITS, and the build silently
        # ships the PREVIOUS UKI — which is exactly how a missing root= could survive a
        # rebuild that was performed to add it (2026-08-13).
        printf 'uki-cmdline-prefix=%s\n' "root=LABEL=${ROOT_LABEL} ro"
        for d in "${SYSROOT}"/var/db/pkg/sys-kernel/dracut-* \
                 "${SYSROOT}"/var/db/pkg/sys-apps/systemd-utils-*; do
            [ -d "${d}" ] && printf 'pkg=%s\n' "$(basename -- "${d}")"
        done
        [ -f "${SYSROOT}/etc/default/grub" ] && \
            printf 'grub-default=%s\n' "$(kc_sha256_file "${SYSROOT}/etc/default/grub")"
        for d in "${SYSROOT}"/etc/dracut.conf.d/*; do
            [ -f "${d}" ] && printf 'dracut-conf=%s %s\n' "$(basename -- "${d}")" "$(kc_sha256_file "${d}")"
        done
    } > "${f}" 2>/dev/null || return 1
    [ -s "${f}" ] || return 1
    printf '%s' "${f}"
}

# kernel_cache_derive — set KCACHE_KEY (and its components), or leave it EMPTY.
# An empty key is a permanent MISS for this build: nothing is looked up, nothing
# is stored. Every "cannot determine X" path lands there deliberately — a missing
# component must never be papered over with a default, because that default would
# be shared by every build that also could not determine it.
kernel_cache_derive() {
    KCACHE_KEY=""; KCACHE_KVER=""; KCACHE_CFG=""; KCACHE_FP=""
    [ -n "${KERNEL_CACHE_ROOT}" ] || return 1
    local src inputs
    src="$(ls -1d "${SYSROOT}"/usr/src/linux-* 2>/dev/null | sort -V | tail -1 || true)"
    KCACHE_KVER="$(kc_kver_from_srctree "${src}" 2>/dev/null || true)"
    [ -n "${KCACHE_KVER}" ] || { kc_info "no kernel source tree yet — cache MISS (kernel version unknown)"; return 1; }
    inputs="$(kernel_cache_inputs || true)"
    [ -n "${inputs}" ] || { kc_info "cannot record the kernel cache inputs — MISS"; return 1; }
    if [ -f "${SYSROOT}/tmp/keep-module.list" ]; then
        KCACHE_CFG="$(kc_config_digest "${SYSROOT}/tmp/k.config" "${SYSROOT}/tmp/keep-module.list" "${inputs}" || true)"
    else
        KCACHE_CFG="$(kc_config_digest "${SYSROOT}/tmp/k.config" "${inputs}" || true)"
    fi
    [ -n "${KCACHE_CFG}" ] || { kc_info "cannot digest the kernel config — MISS"; return 1; }
    # The signing identity. Candidates in precedence order; the persisted org cert
    # under WORK_DIR is the fleet-wide one that signs every board's artifacts.
    KCACHE_FP="$(kc_signing_fingerprint "${SECUREBOOT_CERT}" "${SECUREBOOT_KEY}" \
                    "${WORK_DIR}/secureboot/sb.crt" || true)"
    if [ -z "${KCACHE_FP}" ]; then
        kc_info "no signing identity available yet — cache MISS (a kernel cache keyed"
        kc_info "without the signing key would survive a fleet re-key; refusing to)."
        return 1
    fi
    KCACHE_KEY="$(kc_cache_key "x86" "${KCACHE_KVER}" "${KCACHE_CFG}" "${KCACHE_FP}" || true)"
    [ -n "${KCACHE_KEY}" ] || return 1
    return 0
}

# kernel_cache_try_restore — rc 0 (and KCACHE_HIT=true) only on a VALIDATED hit
# whose payload actually unpacked. A failed unpack is treated as a corrupt entry:
# pruned, reported, and the build compiles as if the cache were empty.
kernel_cache_try_restore() {
    KCACHE_HIT=false
    [ -n "${KCACHE_KEY}" ] || return 1
    local entry
    entry="$(kc_lookup "${KERNEL_CACHE_ROOT}" "x86" "${KCACHE_KEY}" \
                "${KCACHE_KVER}" "${KCACHE_CFG}" "${KCACHE_FP}" || true)"
    [ -n "${entry}" ] || return 1
    rm -rf "${KCACHE_TMP}"; mkdir -p "${KCACHE_TMP}" || return 1
    if ! kc_restore "${entry}" "boot.tar=${KCACHE_TMP}/boot.tar" "modules.tar=${KCACHE_TMP}/modules.tar"; then
        kc_prune "${entry}" "payload could not be read back"; return 1
    fi
    if ! kc_unpack "${KCACHE_TMP}/boot.tar" "${SYSROOT}/boot" \
       || ! kc_unpack "${KCACHE_TMP}/modules.tar" "${SYSROOT}/lib/modules"; then
        kc_prune "${entry}" "payload failed to unpack into the sysroot"
        rm -rf "${KCACHE_TMP}"; return 1
    fi
    rm -rf "${KCACHE_TMP}"
    KCACHE_HIT=true
    return 0
}

# kernel_cache_store — publish what the compile just produced. Best-effort: a
# cache that cannot be written must never fail a build that otherwise succeeded.
kernel_cache_store() {
    [ -n "${KCACHE_KEY}" ] || return 0
    local names kver
    mapfile -t names < <(kc_names_matching "${SYSROOT}/boot" "${KCACHE_BOOT_GLOBS[@]}")
    if [ "${#names[@]}" -eq 0 ]; then
        kc_warn "kernel phase produced no /boot artifacts — nothing cached"; return 0
    fi
    kver="$(ls -1 "${SYSROOT}/lib/modules" 2>/dev/null | sort -V | tail -1 || true)"
    [ -n "${kver}" ] && [ -d "${SYSROOT}/lib/modules/${kver}" ] || {
        kc_warn "no module tree under ${SYSROOT}/lib/modules — nothing cached"; return 0; }
    rm -rf "${KCACHE_TMP}"; mkdir -p "${KCACHE_TMP}" || return 0
    if kc_pack "${KCACHE_TMP}/boot.tar" "${SYSROOT}/boot" "${names[@]}" \
       && kc_pack "${KCACHE_TMP}/modules.tar" "${SYSROOT}/lib/modules" "${kver}"; then
        kc_store "${KERNEL_CACHE_ROOT}" "x86" "${KCACHE_KEY}" "${KCACHE_KVER}" \
            "${KCACHE_CFG}" "${KCACHE_FP}" "build-x86-host-stage4.sh" \
            "boot.tar=${KCACHE_TMP}/boot.tar" "modules.tar=${KCACHE_TMP}/modules.tar" \
            && kc_info "cached this kernel for reuse (board=x86 key=${KCACHE_KEY})" \
            || kc_warn "could not publish the kernel cache entry (build unaffected)"
    else
        kc_warn "could not pack the kernel artifacts (build unaffected)"
    fi
    rm -rf "${KCACHE_TMP}"
}

if ${SKIP_KERNEL}; then
    banner "SKIPPED kernel (--skip-kernel)"
else
    banner "Building hardened kernel (native: gentoo-sources + KSPP/SELinux + k8s fragment)"
    # Base (role-independent) hardening+k8s fragment; append the DRM driver block
    # ONLY for GPU roles. Headless roles keep just the virtio-gpu console FB.
    cp "${SPECS_DIR}/kernel/hardened-k8s.config" "${SYSROOT}/tmp/k.config"
    if ${GPU}; then
        cat "${SPECS_DIR}/kernel/gpu.config" >> "${SYSROOT}/tmp/k.config"
        info "Kernel: appending GPU/DRM fragment (gpu.config)"
        # Proprietary NVIDIA out-of-tree kmod: ensure CONFIG_MODULES + that nouveau
        # stays modular (not builtin, so the blob owns the GPU) + DRM/KMS bits.
        if ${NVIDIA_PROPRIETARY} && [ -f "${SPECS_DIR}/kernel/nvidia.config" ]; then
            cat "${SPECS_DIR}/kernel/nvidia.config" >> "${SYSROOT}/tmp/k.config"
            info "Kernel: appending NVIDIA proprietary fragment (nvidia.config)"
        fi
    else
        info "Kernel: headless (no AMD/Intel/Nouveau DRM drivers)"
    fi
    # Client desktops also need the input/HID/sound/storage/laptop-power bits the
    # k8s+GPU fragments don't carry (KMS comes from gpu.config above, GPU=true on
    # clients). chromebook adds coreboot/firmware quirks via the same fragment.
    if ${ROLE_CLIENT}; then
        cat "${SPECS_DIR}/kernel/desktop.config" >> "${SYSROOT}/tmp/k.config"
        info "Kernel: appending desktop fragment (desktop.config) for client role ${ROLE}"
        # E-INK / e-paper display support (mainline DRM + FB controllers): RePaper
        # (Pervasive Displays), Metronome, Broadsheet, AUO K190x — built as modules
        # so they cost nothing until an e-ink panel is attached.
        if ${HOME_ENCRYPTED} && [ -f "${SPECS_DIR}/kernel/ecryptfs.config" ]; then
            cat "${SPECS_DIR}/kernel/ecryptfs.config" >> "${SYSROOT}/tmp/k.config"
            info "Kernel: appending ecryptfs fragment (CONFIG_ECRYPT_FS) for the per-user home layer"
        fi
        # WireGuard egress VPN needs the in-kernel module (NM drives it natively).
        case "${EGRESS_VPN_FILE}" in
            *.ovpn) : ;;   # OpenVPN is userspace (tun), no kernel fragment needed
            "")     : ;;
            *) if [ -f "${SPECS_DIR}/kernel/wireguard.config" ]; then
                   cat "${SPECS_DIR}/kernel/wireguard.config" >> "${SYSROOT}/tmp/k.config"
                   info "Kernel: appending WireGuard fragment (CONFIG_WIREGUARD) for the egress VPN"
               fi ;;
        esac
        if [ -f "${SPECS_DIR}/kernel/eink.config" ]; then
            cat "${SPECS_DIR}/kernel/eink.config" >> "${SYSROOT}/tmp/k.config"
            info "Kernel: appending e-ink display fragment (eink.config)"
        fi
        # chromebook (coreboot-UEFI target, ADR-16): on top of the generic desktop
        # fragment, pull the chromebook-specific peripheral quirks (I2C-attached
        # touchpads, the I2S audio codecs + jack detect, EC backlight/charger).
        if [ "${ROLE}" = "chromebook" ]; then
            cat "${SPECS_DIR}/kernel/chromebook.config" >> "${SYSROOT}/tmp/k.config"
            info "Kernel: appending chromebook quirks fragment (chromebook.config)"
        fi
    fi
    # --kernel-builtin: stage the keep-as-module denylist so the in-chroot replay can
    # turn `module` -> built-in (=y) for everything else + sweep base =m -> =y.
    if ${KERNEL_BUILTIN} && [ -f "${SPECS_DIR}/kernel/keep-as-module.list" ]; then
        cp "${SPECS_DIR}/kernel/keep-as-module.list" "${SYSROOT}/tmp/keep-module.list"
        info "Kernel: --kernel-builtin set — compiling in-tree config built-in (=y) except keep-as-module.list"
    fi
    # Consult the signed-kernel cache now that every fragment is assembled (the
    # assembled config IS component 3 of the key). A hit unpacks the kernel,
    # modules, initramfs and unsigned UKI straight into the sysroot and skips the
    # compile below; everything AFTER this block — Secure Boot signing, the
    # DISK-INITRAMFS GATE, build_img's seal gate — runs either way.
    kernel_cache_derive || true
    if kernel_cache_try_restore; then
        # info, NOT banner: the kernel PHASE banner is already emitted above and a
        # cache hit is not a new phase. A second banner here would be a rung the
        # Studio's progress table has no row for, stranding the ladder
        # (studio/tests/test_progress_uniformity.py caught exactly that).
        info "Kernel: RESTORED from the signed-kernel artifact cache — compile skipped."
        info "Kernel: cache key ${KCACHE_KEY} (board=x86 ${KCACHE_KVER}); every"
        info "artifact-integrity gate below still runs against the restored sysroot."
    else
    # (heredoc body must stay at column 0, so the miss branch is not re-indented)
    chroot "${SYSROOT}" /bin/bash -eo pipefail <<CHROOT
KBUILTIN=${KERNEL_BUILTIN}
# (Re)ensure the hardened kernel sources are installed and /usr/src/linux is set
# — independent of whether the main stage4 emerge completed.
# EMERGE-GROUP BANNER (dependencies): sys-kernel/gentoo-sources is also listed in
# the image set (specs-x86/portage/packages.list:8), but THIS invocation is not
# the payload emerge — it is a guarded top-up whose only job is to satisfy the
# kernel build's /usr/src/linux dependency when the payload emerge did not
# complete. Grouping it under "image" would make the Studio re-open the already
# finished image group hours later to list one package, so it is "dependencies":
# it exists purely to satisfy another build step's dependency.
# Bare echo, and no dollar/backtick/dollar-paren anywhere in these lines: this is
# the UNQUOTED CHROOT heredoc, where the HOST shell expands comments too (same
# rule as the payload heredoc above).
if [ ! -e /usr/src/linux/Makefile ]; then
    echo "==> Emerge group: dependencies"
    emerge --noreplace --quiet-build sys-kernel/gentoo-sources \
        || emerge --quiet-build sys-kernel/gentoo-sources
fi
eselect kernel set 1 || true
if [ ! -e /usr/src/linux/Makefile ]; then
    echo "[build-x86] ERROR: /usr/src/linux is not set up (sys-kernel/gentoo-sources missing)"; exit 1
fi
cd /usr/src/linux
make defconfig
# Helper: is CONFIG_SYMBOL on the keep-as-module denylist? (only consulted for builtin)
_keep_module() { [ -f /tmp/keep-module.list ] && grep -qxF "\$1" /tmp/keep-module.list; }
while IFS= read -r line; do
    [[ "\${line}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "\${line// }" ]] && continue
    read -r action rest <<< "\${line}"
    # --kernel-builtin: turn fragment 'module CONFIG_X' into built-in (=y) unless X is
    # on the keep-as-module denylist (out-of-tree / firmware / load-order cases).
    if [ "\${KBUILTIN}" = true ] && [ "\${action}" = module ] && ! _keep_module "\${rest}"; then
        action=enable
    fi
    eval "scripts/config --\${action} \${rest}"
done < /tmp/k.config
# --kernel-builtin sweep: promote the base defconfig's remaining =m symbols to =y too,
# except the denylist. CONFIG_MODULES stays =y (out-of-tree nvidia.ko depends on it).
# olddefconfig then drops any =y that can't satisfy deps, so this is safe.
if [ "\${KBUILTIN}" = true ]; then
    nmod=0
    for sym in \$(grep -E '^CONFIG_[A-Z0-9_]+=m\$' .config | cut -d= -f1); do
        [ "\${sym}" = CONFIG_MODULES ] && continue
        _keep_module "\${sym}" && continue
        scripts/config --enable "\${sym}"; nmod=\$((nmod+1))
    done
    scripts/config --enable CONFIG_MODULES   # never lose module loading (nvidia.ko)
    echo "[build-x86] --kernel-builtin: promoted \${nmod} modules to built-in (kept denylist + CONFIG_MODULES)"
fi
make olddefconfig
# Refuse to ship a kernel that silently lost its hardening (e.g. a symbol that
# olddefconfig pruned for an unmet dep). Stable, long-standing KSPP/LSM symbols.
for must in CONFIG_SECURITY_SELINUX CONFIG_STACKPROTECTOR_STRONG CONFIG_FORTIFY_SOURCE CONFIG_HARDENED_USERCOPY; do
    grep -q "^\${must}=y" .config || { echo "[build-x86] ERROR: hardened kernel option \${must} not enabled after olddefconfig"; exit 1; }
done
# BOOT-CRITICAL (live ISO + SELinux enforcing): SQUASHFS_XATTR must survive olddefconfig.
# The live squashfs pack PRESERVES security.selinux xattrs (mksquashfs by default, the
# tar2sqfs fallback via tar --xattrs) — but note the sysroot is UNLABELED at pack time
# today: nothing runs setfiles into it, so the packed image carries only whatever
# labels happen to exist, and real labeling happens at FIRST BOOT when
# provision_selinux() relabels onto the live overlay. SQUASHFS_XATTR is still required:
# without it the kernel drops any labels that ARE present ("squashfs: Xattrs in
# filesystem, these will be ignored") — and on a labeled squashfs that unlabels the
# live root and the enforcing boot DEADLOCKS at OpenRC init-early (proven via QEMU:
# enforcing hangs, enforcing=0 reaches agetty). SQUASHFS_XATTR depends on SQUASHFS,
# so a pruned dep would silently re-strip the labels — fail closed here.
grep -q "^CONFIG_SQUASHFS_XATTR=y" .config || { echo "[build-x86] ERROR: CONFIG_SQUASHFS_XATTR not enabled after olddefconfig — live SELinux-enforcing boot would hang (unlabeled squashfs root)"; exit 1; }
# BOOT-CRITICAL: refuse to ship a kernel whose k8s Service-networking surface
# silently lost a netfilter/NAT/eBPF symbol. The x86 fragment used to be a
# TRUNCATED copy of the Pi one (no xtables match/target layer, no nft NAT/MASQ,
# no NF_NAT_MASQUERADE, no IPv6 nf tables, no IP_NF_MANGLE) which left ClusterIP/
# kube-proxy/MASQUERADE/dual-stack/NetworkPolicy DEAD. Even with the fragment
# fixed, \`make olddefconfig\` (above) will SILENTLY DROP any symbol whose parent
# dep is unmet on the x86_64 defconfig base — no error, no diff. This loop is the
# only thing that turns that silent prune into a BUILD FAILURE naming the symbol.
# This list is the FULL load-bearing set the fragment adds — NOT a representative
# subset. olddefconfig prunes per-LEAF: a parent (e.g. NETFILTER_XTABLES) can
# survive while a leaf (e.g. NETFILTER_XT_TARGET_REDIRECT, IP6_NF_FILTER,
# NETFILTER_XT_MATCH_MARK/MULTIPORT/STATISTIC, NETFILTER_XT_TARGET_MARK) gets
# silently dropped — shipping a dead path. Asserting only a subset would let such
# a leaf prune through, which is exactly the class of bug this guard exists to
# stop. Keep this list IDENTICAL (modulo shell-var escaping) to the
# build-rpi5-stage4.sh mirror and in sync with
# tests/scripts/test-x86-kernel-net-symbols.sh (which asserts guard==fragment).
# This guard asserts the FULL k8s Service-networking surface (kube-proxy xtables /
# nft NAT / IPVS / CNI overlay / cgroup). It is REQUIRED for a cluster node, but a
# standalone DESKTOP (ROLE_K8S=none) is not a k8s node — it doesn't run kube-proxy
# and legitimately has no k8s fragment, so olddefconfig prunes the legacy xtables
# leaves (e.g. IP_NF_MANGLE, whose legacy parent isn't enabled on the desktop). Skip
# the k8s assertion for non-k8s roles; firewalld (nftables) + docker get the symbols
# they need from hardened-k8s.config regardless, and the hardening/LSM guards below
# still run for every role.
if [ "${ROLE_K8S}" != none ]; then
for must in CONFIG_NETFILTER_XTABLES \
            CONFIG_NETFILTER_XT_MATCH_ADDRTYPE CONFIG_NETFILTER_XT_MATCH_COMMENT \
            CONFIG_NETFILTER_XT_MATCH_CONNTRACK CONFIG_NETFILTER_XT_MATCH_MARK \
            CONFIG_NETFILTER_XT_MATCH_MULTIPORT CONFIG_NETFILTER_XT_MATCH_STATISTIC \
            CONFIG_NETFILTER_XT_TARGET_MARK CONFIG_NETFILTER_XT_TARGET_MASQUERADE \
            CONFIG_NETFILTER_XT_TARGET_REDIRECT \
            CONFIG_NETFILTER_XTABLES_LEGACY CONFIG_IP_NF_IPTABLES_LEGACY \
            CONFIG_IP6_NF_IPTABLES_LEGACY \
            CONFIG_IP_NF_MANGLE CONFIG_NF_NAT CONFIG_NF_NAT_MASQUERADE \
            CONFIG_NF_TABLES CONFIG_NF_TABLES_IPV4 CONFIG_NF_TABLES_IPV6 \
            CONFIG_NFT_NAT CONFIG_NFT_MASQ CONFIG_NFT_CT \
            CONFIG_IP6_NF_IPTABLES CONFIG_IP6_NF_FILTER CONFIG_IP6_NF_NAT \
            CONFIG_IP6_NF_MANGLE \
            CONFIG_VLAN_8021Q CONFIG_NET_L3_MASTER_DEV CONFIG_NET_SCH_HTB \
            CONFIG_NET_CLS_CGROUP \
            CONFIG_IP_VS CONFIG_VXLAN CONFIG_VETH CONFIG_BRIDGE \
            CONFIG_OVERLAY_FS CONFIG_OVERLAY_FS_REDIRECT_DIR CONFIG_OVERLAY_FS_INDEX \
            CONFIG_CGROUP_NET_CLASSID CONFIG_CGROUP_NET_PRIO CONFIG_CGROUP_HUGETLB \
            CONFIG_CGROUP_PERF CONFIG_CGROUP_WRITEBACK \
            CONFIG_FAIR_GROUP_SCHED \
            CONFIG_BPF_SYSCALL CONFIG_BPF_EVENTS \
            CONFIG_POSIX_MQUEUE; do
    grep -q "^\${must}=y" .config || { echo "[build-x86] ERROR: k8s node kernel option \${must} not enabled after olddefconfig (Service/kube-proxy/CNI/container-runtime would be impaired)"; exit 1; }
done
else
    echo "[build-x86] Standalone/non-k8s role (ROLE_K8S=none): skipping the k8s Service-networking kernel guard"
fi
# SELinux only activates if CONFIG_LSM is a clean, well-formed string. lockdown is
# listed FIRST so it engages before any other LSM; a stray quote or wrong order here
# would silently ship SELinux or lockdown DISABLED. Assert the exact intended value.
grep -q '^CONFIG_LSM="lockdown,yama,selinux,bpf"\$' .config || { echo "[build-x86] ERROR: CONFIG_LSM malformed (expected lockdown,yama,selinux,bpf); lockdown/SELinux would not activate"; exit 1; }
# ...and every NAME in that string must have its module COMPILED IN. Asserting the
# string alone is structurally blind to the failure that actually shipped: the
# kernel does not diagnose an LSM name it cannot resolve, it initializes a SHORTER
# stack and boots on. The 2026-08-14 pki image asked for
#   lsm=lockdown,yama,selinux,bpf
# and dmesg answered
#   LSM: initializing lsm=lockdown,capability,selinux
# because CONFIG_SECURITY_YAMA and CONFIG_BPF_LSM were never set — two LSMs that
# were pure decoration in the config, the cmdline, the grub.cfg and the signed UKI.
# So derive the required symbols FROM the string: adding a name to CONFIG_LSM
# without its enabling symbol now fails the build instead of shipping a lie.
for _l in \$(sed -n 's/^CONFIG_LSM="\(.*\)"\$/\1/p' .config | tr ',' ' '); do
    case "\${_l}" in
        capability) continue ;;                      # always built in with CONFIG_SECURITY
        lockdown)   _sym=CONFIG_SECURITY_LOCKDOWN_LSM ;;
        yama)       _sym=CONFIG_SECURITY_YAMA ;;
        selinux)    _sym=CONFIG_SECURITY_SELINUX ;;
        bpf)        _sym=CONFIG_BPF_LSM ;;
        apparmor)   _sym=CONFIG_SECURITY_APPARMOR ;;
        loadpin)    _sym=CONFIG_SECURITY_LOADPIN ;;
        safesetid)  _sym=CONFIG_SECURITY_SAFESETID ;;
        landlock)   _sym=CONFIG_SECURITY_LANDLOCK ;;
        integrity)  _sym=CONFIG_INTEGRITY ;;
        *) echo "[build-x86] ERROR: CONFIG_LSM names '\${_l}', which this guard cannot verify — add its enabling CONFIG_* symbol to the case above"; exit 1 ;;
    esac
    grep -q "^\${_sym}=y\$" .config || { echo "[build-x86] ERROR: CONFIG_LSM names '\${_l}' but \${_sym} is not =y after olddefconfig — the kernel would SILENTLY DROP it from the LSM stack"; exit 1; }
done
make -j${JOBS} bzImage modules
make modules_install
# 'make install' copies bzImage/System.map/config to /boot FIRST, then falls
# through arch/x86/boot/install.sh's bootloader probe (no installkernel(8) in
# the image, no lilo) and prints a harmless "Cannot find LILO." as its last
# gasp. Filter that one cosmetic line: the shell is bash -eo pipefail, so a
# REAL make-install failure still aborts via the pipeline status; the '|| true'
# only absorbs grep's status-1 when every line was filtered.
make install 2>&1 | { grep -vF 'Cannot find LILO.' || true; }
# Disk-boot initramfs (NOT the live dmsquash-live one): a normal, generic
# (--no-hostonly) dracut image so the persistent ext4 GPT root mounts on real
# hardware AND in VMs. Named initramfs-<kver>.img to match the grub.cfg the .img
# builder writes. The live ISO builds its own initramfs-live.img separately.
KVER="\$(make -s kernelrelease 2>/dev/null || ls /lib/modules | sort -V | tail -1)"
if command -v dracut >/dev/null; then
    # --add crypt: the LUKS2 root the installer can lay down is unlocked
    # from /etc/crypttab + the rd.luks cmdline in this initramfs. Harmless on a
    # plaintext-root image (no crypttab → no unlock attempted). See dracut.conf.d.
    dracut --force --no-hostonly \
        --add crypt \
        --add-drivers "ext4 vfat nvme ahci sd_mod usb_storage uas virtio_blk virtio_pci virtio_net dm_crypt" \
        --kver "\${KVER}" "/boot/initramfs-\${KVER}.img" \
        || echo "[build-x86] WARN: dracut (disk initramfs) failed; the .img may not boot"
else
    echo "[build-x86] WARN: dracut not installed; no disk initramfs (sys-kernel/dracut should be in packages.list)"
fi
# Unified Kernel Image (UKI) for Secure Boot: bundles kernel+initramfs+cmdline
# as a single signed PE/EFI binary. Requires dracut[uefi] + systemd-utils[boot]
# (owns the sd-stub /usr/lib/systemd/boot/efi/linuxx64.efi.stub) + CONFIG_EFI_STUB.
# The host-side signing step below signs it with the org key; build_img() installs
# it to the ESP. NOTE: the output path expands HOST-side (unquoted heredoc) from
# UKI_NAME so it matches the sign step's UKI_UNSIGNED for BOTH the branded
# (hugmesh-unsigned.efi) and UNAFFILIATED (gentoo-unsigned.efi) names.
# --kernel-image /boot/vmlinuz is REQUIRED: 'make install' above ran with no
# installkernel(8) (see the LILO note), so arch/x86/boot/install.sh wrote an
# UNVERSIONED /boot/vmlinuz — dracut's determine_kernel_image() probes only
# versioned paths (/lib/modules/<kver>/vmlinuz, /boot/vmlinuz-<kver>, ...) and
# dies "Can't find a kernel image" without the flag; the WARN below would then
# swallow that and the SB chain would silently degrade to GRUB+vmlinuz
# (live-proven on the real desktop sysroot: exact invocation failed without
# the flag, produced a valid PE32+ UKI with it).
# NB: this whole block lives inside an UNQUOTED <<CHROOT heredoc, so backticks are
# COMMAND SUBSTITUTION even in a comment — the heredoc is expanded before any of it is
# parsed as shell. Quoting a command name in backticks here runs it at build time and
# splices its stdout into the script (a bare 'parted' printed "Using /dev/sda", which
# then executed as a command and failed the build). Use 'single quotes' in comments.
#
# root= MUST be baked in here. GRUB's 'chainloader' hands a UKI NO external cmdline,
# so unlike the GRUB 'linux' menuentry — which appends root=PARTUUID=... at build_img
# time — the UKI is only bootable if it carries root= itself. GRUB_CMDLINE_LINUX is the
# APPEND half by design and never contains one, so the UKI shipped without it: the
# kernel started and dracut then died "FATAL: No or empty root= argument" and dropped to
# a debug shell. That is every x86 image of the 2026-08-07 session (matrix triage
# 2026-08-13); it was masked until now by a separate GRUB defect that stopped the UKI
# entry from ever being reached.
#
# LABEL=, not PARTUUID=: the partition UUIDs are minted by 'parted' inside build_img()
# and only read back afterwards (see mkpart/_fld root_uuid), which happens long AFTER
# this UKI is built AND signed — so a PARTUUID is simply not knowable here, and
# rewriting .cmdline post-signing would invalidate the signature. ${ROOT_LABEL} is a
# build-time constant that build_img passes to 'mkfs.ext4 -L', so it is stable and
# known now. dracut already carries the ext4 driver (--add-drivers below) to mount it.
CMDLINE="root=LABEL=${ROOT_LABEL} ro \$(. /etc/default/grub 2>/dev/null; printf '%s' "\${GRUB_CMDLINE_LINUX:-lsm=lockdown,yama,selinux,bpf lockdown=integrity selinux=1 audit=1}")"
if command -v dracut >/dev/null && dracut --help 2>/dev/null | grep -q -- '--uefi'; then
    dracut --force --no-hostonly --uefi \
        --add crypt \
        --add-drivers "ext4 vfat nvme ahci sd_mod usb_storage uas virtio_blk virtio_pci virtio_net dm_crypt" \
        --kernel-cmdline "\${CMDLINE}" \
        --kernel-image /boot/vmlinuz \
        --kver "\${KVER}" "/boot/${UKI_NAME%.efi}-unsigned.efi" \
        && echo "[build-x86] UKI built: /boot/${UKI_NAME%.efi}-unsigned.efi" \
        || echo "[build-x86] WARN: dracut --uefi failed; UKI not built (secure boot chain needs manual rebuild)"
else
    echo "[build-x86] INFO: dracut --uefi not available; UKI skipped (add 'uefi' USE to sys-kernel/dracut)"
fi
CHROOT
    kernel_cache_store
    fi
    rm -f "${SYSROOT}/tmp/k.config" "${SYSROOT}/tmp/k.cache-inputs"
    info "Gentoo hardened kernel + disk-boot initramfs installed to ${SYSROOT}/boot"
fi

# ── DISK-INITRAMFS GATE (a disk-boot artifact must never seal without one) ─────
# The dracut step inside the kernel chroot above is WARN-ONLY by design (ISO-
# only/tar-only builds should not be hostage to it) — but build_img's grub.cfg
# writer then just OMITS the "initrd" line when the file is missing (see the
# `[ -n "${initrd}" ] &&` guard there), sealing an .img whose kernel boots with
# no initramfs at all: no rd.luks for an encrypted root, no dm_crypt/usb/nvme
# staging — an unbootable disk on most real hardware, shipped with exit 0. Same
# posture as build_img's grub-mkimage gate ("refusing to ship a non-booting
# .img"): when a disk-boot artifact is requested (.img, or the installer ISO —
# the system it installs boots from this same stage4 /boot) and a kernel is
# present, the MATCHING initramfs-<kver>.img must exist and be non-empty.
# <kver> is pinned to the newest /lib/modules entry: a stale initramfs left by a
# previous kernel would pass a bare existence probe and still fail to boot the
# new kernel (module tree mismatch). Runs OUTSIDE the SKIP_KERNEL conditional on
# purpose — a --resume/--skip-kernel run with a warm sysroot needs the same
# guarantee. No kernel at all stays a skip (build_img already warns + skips).
if ${BUILD_IMG} || ${INSTALLER_ISO}; then
    _gate_kver="$(ls "${SYSROOT}/lib/modules" 2>/dev/null | sort -V | tail -1 || true)"
    _gate_vmlinuz="$(ls -1 "${SYSROOT}/boot/vmlinuz-"* "${SYSROOT}/boot/vmlinuz" 2>/dev/null | head -1 || true)"
    if [ -n "${_gate_kver}" ] && [ -n "${_gate_vmlinuz}" ]; then
        if [ ! -s "${SYSROOT}/boot/initramfs-${_gate_kver}.img" ]; then
            err "disk initramfs missing or EMPTY: ${SYSROOT}/boot/initramfs-${_gate_kver}.img"
            err "dracut failed (see the WARN in the kernel phase above) or sys-kernel/dracut"
            err "is not in the payload. Sealing would ship a grub.cfg with NO initrd line —"
            err "no rd.luks unlock, no dm_crypt/usb/nvme modules; the .img/installed system"
            err "would not boot. Fix dracut, or drop the disk artifacts (--no-img and no"
            err "--installer-iso) to build the other artifact types."
            exit 1
        fi
        info "Disk-initramfs gate: initramfs-${_gate_kver}.img present ($(du -h "${SYSROOT}/boot/initramfs-${_gate_kver}.img" | cut -f1))"
    fi
fi

# ── Secure Boot: org signing-key generation + UKI signing ─────────
# Signing happens on the HOST (not in chroot) so the key stays outside the image.
# The unsigned UKI was built by dracut --uefi above inside the chroot.
# SBDIR persists across builds in WORK_DIR so the same org cert covers all roles.
SBDIR="${WORK_DIR}/secureboot"
SBKEY="${SBDIR}/sb.key"; SBCRT="${SBDIR}/sb.crt"; SBCER="${SBDIR}/sb.cer"
UKI_UNSIGNED="${SYSROOT}/boot/${UKI_NAME%.efi}-unsigned.efi"
UKI_SIGNED="${SYSROOT}/boot/${UKI_NAME}"
# A KEYS-USB / explicit signing key (--keys-usb, --secureboot-key/-cert) lets the
# UKI be signed with the key ALREADY ENROLLED in this host's firmware, so the
# reinstalled system boots under Secure Boot without re-enrolling. We stage that
# key/cert into SBDIR (converting a DER cert to PEM for sbsign) before signing.
if [ -n "${SECUREBOOT_KEY}" ] && [ -f "${SECUREBOOT_KEY}" ]; then
    mkdir -p "${SBDIR}"
    cp "${SECUREBOOT_KEY}" "${SBKEY}"; chmod 600 "${SBKEY}"
    if [ -n "${SECUREBOOT_CERT}" ] && [ -f "${SECUREBOOT_CERT}" ]; then
        case "${SECUREBOOT_CERT}" in
            *.der|*.cer) openssl x509 -inform DER -in "${SECUREBOOT_CERT}" -out "${SBCRT}" 2>/dev/null || cp "${SECUREBOOT_CERT}" "${SBCRT}" ;;
            *)           cp "${SECUREBOOT_CERT}" "${SBCRT}" ;;
        esac
    elif openssl rsa -in "${SBKEY}" -pubout >/dev/null 2>&1; then
        # No cert given: self-sign one from the provided key so sbsign has an x509.
        openssl req -new -x509 -key "${SBKEY}" -sha256 -days 3650 \
            -subj "/O=${ORG}/CN=${SB_CERT_CN} ${BRAND} (keys-usb)/" -out "${SBCRT}" 2>/dev/null || true
    fi
    [ -f "${SBCRT}" ] && openssl x509 -inform PEM -outform DER -in "${SBCRT}" -out "${SBCER}" 2>/dev/null || true
    info "Secure Boot: signing UKI with the provided KEYS key (${SECUREBOOT_KEY})"
fi
if ! ${SECURE_BOOT}; then
    warn "Secure Boot DISABLED (--no-secure-boot): UKI left unsigned (chain won't verify)."
    [ -f "${UKI_UNSIGNED}" ] && { cp "${UKI_UNSIGNED}" "${UKI_SIGNED}"; rm -f "${UKI_UNSIGNED}"; }
elif command -v sbsign >/dev/null 2>&1 && [ -f "${UKI_UNSIGNED}" ]; then
    mkdir -p "${SBDIR}"
    if [ ! -f "${SBKEY}" ]; then
        info "Generating HugMesh org Secure Boot signing key (RSA-4096, 10 yr)"
        openssl req -newkey rsa:4096 -nodes -sha256 \
            -keyout "${SBKEY}" -x509 -days 3650 \
            -subj "/O=${SB_CERT_O}/CN=${SB_CERT_CN} ${BRAND}/" \
            -out "${SBCRT}" 2>/dev/null
        openssl x509 -inform PEM -outform DER -in "${SBCRT}" -out "${SBCER}"
        if command -v cert-to-efi-sig-list >/dev/null && command -v sign-efi-sig-list >/dev/null; then
            _sb_guid="$(cat /proc/sys/kernel/random/uuid)"
            cert-to-efi-sig-list -g "${_sb_guid}" "${SBCRT}" "${SBDIR}/db.esl"
            sign-efi-sig-list -k "${SBKEY}" -c "${SBCRT}" db \
                "${SBDIR}/db.esl" "${SBDIR}/db.auth" 2>/dev/null \
                && info "EFI db.auth enrollment payload generated at ${SBDIR}/db.auth"
        fi
    fi
    info "Signing UKI with org Secure Boot key"
    sbsign --key "${SBKEY}" --cert "${SBCRT}" \
        --output "${UKI_SIGNED}" "${UKI_UNSIGNED}" \
        && info "Signed UKI: ${UKI_SIGNED}" \
        || { warn "sbsign failed; copying unsigned UKI (not verifiable under Secure Boot)"; cp "${UKI_UNSIGNED}" "${UKI_SIGNED}"; }
    rm -f "${UKI_UNSIGNED}"
    # Install org cert into the rootfs for keys-provision mokutil enrollment.
    # SB_ETC_DIR comes from the boot-chain identity fold (UNAFFILIATED keeps the
    # functional enrollment certs under the neutral /etc/gentoo dir); the ESP and
    # live-ISO copies below resolve the SAME variable, so wherever this stages
    # the cert, the boot media carries it too.
    mkdir -p "${SYSROOT}${SB_ETC_DIR}"
    cp "${SBCRT}" "${SYSROOT}${SB_ETC_DIR}/sb.crt"
    cp "${SBCER}" "${SYSROOT}${SB_ETC_DIR}/sb.cer"
    [ -f "${SBDIR}/db.auth" ] && cp "${SBDIR}/db.auth" "${SYSROOT}${SB_ETC_DIR}/db.auth"
    info "Org Secure Boot cert installed to sysroot ${SB_ETC_DIR}/"
elif [ -f "${UKI_UNSIGNED}" ]; then
    warn "sbsign not found on build host (install app-crypt/sbsigntools); UKI unsigned — Secure Boot chain won't verify"
    cp "${UKI_UNSIGNED}" "${UKI_SIGNED}"; rm -f "${UKI_UNSIGNED}"
fi

# ── 8. Clean ───────────────────────────────────────────────────────
umount_chroot; trap - EXIT
# Guard (shared-binpkg): the shared-pool bind must be DETACHED before ANYTHING
# below touches var/cache/binpkgs — the uncached clean's rm -rf through a live
# bind would empty the FLEET's pool, and the --cached embed below would copy the
# pool into itself. umount_chroot detaches with `umount -l ... || true`, a SILENT
# best-effort (same class as the var/tmp/portage guard inside the clean); verify.
if mountpoint -q "${SYSROOT}/var/cache/binpkgs" 2>/dev/null; then
    err "${SYSROOT}/var/cache/binpkgs is STILL a mountpoint after umount_chroot —"
    err "refusing to touch it: it is the SHARED binpkg pool every amd64 image"
    err "reuses (${X86_POOL_DIR:-<unset>}). Unmount first:  umount -R '${SYSROOT}'  — then re-run."
    exit 1
fi
# --cached carve-out (shared-binpkg): a CACHED image PROMISES an embedded binpkg
# cache (+ distfiles) so the installed system can rebuild/extend OFFLINE. With the
# shared pool the chroot's /var/cache/binpkgs was a bind — detached above — so the
# sysroot-side dir is now empty (or stale, on a pre-share --resume sysroot). COPY
# the pool in to honor the promise. Runs regardless of --skip-clean: the embed is
# image CONTENT, not cleanup. The pool stamp is a build-host key, not an image
# artifact, so it is dropped from the copy.
if ${ISO_CACHED:-false} && [ -n "${X86_POOL_DIR}" ]; then
    banner "CACHED image: embedding the shared binpkg pool"
    rm -rf "${SYSROOT}/var/cache/binpkgs"
    mkdir -p "${SYSROOT}/var/cache/binpkgs"
    cp -a "${X86_POOL_DIR}/." "${SYSROOT}/var/cache/binpkgs/" \
        || { err "could not embed the shared binpkg pool ${X86_POOL_DIR} into the CACHED image"; exit 1; }
    rm -f "${SYSROOT}/var/cache/binpkgs/.hugmesh-pool-fingerprint"
    info "embedded $(du -sh "${SYSROOT}/var/cache/binpkgs" 2>/dev/null | cut -f1) of binpkgs (whole per-arch pool incl. Packages index) from ${X86_POOL_DIR}"
fi
if ! ${SKIP_CLEAN}; then
    banner "Cleaning sysroot"
    # Remove build-only sudoers patches (added to allow portage pkg_postinst to run
    # sudo without a tty; not needed or wanted in the deployed image).
    rm -f "${SYSROOT}/etc/sudoers.d/build-notty"
    # Revert main sudoers: restore requiretty and remove the includedir line we added
    if [[ -f "${SYSROOT}/etc/sudoers" ]]; then
        sed -i 's/^Defaults !requiretty/Defaults requiretty/' "${SYSROOT}/etc/sudoers"
        sed -i '/^#includedir \/etc\/sudoers.d # build-added$/d' "${SYSROOT}/etc/sudoers"
    fi
    # Build-artifact bloat: binpkgs (~2.4 GiB), distfiles, docs, tmp.
    # CACHED ISO (--cached) KEEPS the binpkg cache (+ distfiles) so the installed
    # system can rebuild/extend packages OFFLINE and reinstall fast; UNCACHED prunes
    # them for a lean image (default). docs/man/tmp are always pruned.
    # Guard: umount_chroot above detaches the shared portage-scratch bind with
    # `umount -l ... || true` — a SILENT best-effort. If that bind were somehow
    # still attached, the var/tmp wipe below would empty the HOST-side scratch
    # every concurrent same-subdir build compiles in (see the flock rationale at
    # the Extract phase). Verify the detach actually happened before deleting.
    if mountpoint -q "${SYSROOT}/var/tmp/portage" 2>/dev/null; then
        err "${SYSROOT}/var/tmp/portage is STILL a mountpoint after umount_chroot —"
        err "refusing to rm -rf through the (shared) portage build scratch."
        exit 1
    fi
    rm -rf "${SYSROOT}"/usr/share/{doc,man,info}/* \
           "${SYSROOT}"/var/tmp/* "${SYSROOT}"/tmp/* 2>/dev/null || true
    if ${ISO_CACHED:-false}; then
        info "CACHED image: keeping the binpkg cache (+ distfiles) for offline rebuild/fast reinstall"
    else
        rm -rf "${SYSROOT}"/var/cache/distfiles/* "${SYSROOT}"/var/cache/binpkgs/* 2>/dev/null || true
    fi

    # Locale data: keep en/en_US/POSIX, prune the rest (~50 MiB of LC archives).
    find "${SYSROOT}"/usr/share/locale -maxdepth 1 -mindepth 1 -type d \
         ! -name 'en' ! -name 'en_US' ! -name 'POSIX' \
         -exec rm -rf {} + 2>/dev/null || true
    find "${SYSROOT}"/usr/lib/locale -maxdepth 1 -mindepth 1 -type d \
         ! -name 'en_US.utf8' ! -name 'C.utf8' \
         -exec rm -rf {} + 2>/dev/null || true

    # Static libraries: already linked into binaries; not needed at runtime.
    find "${SYSROOT}"/usr/lib{,64} -name '*.a' -delete 2>/dev/null || true

    # Python bytecode cache: reproducible from source; not needed at runtime.
    find "${SYSROOT}" -name '*.pyc' -delete 2>/dev/null || true
    find "${SYSROOT}" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true

    # Strip debug symbols from kernel modules (~30-60% size reduction per .ko).
    find "${SYSROOT}"/lib/modules -name '*.ko' \
         -exec strip --strip-debug {} \; 2>/dev/null || true

    # Strip unneeded symbols from ELF executables and shared libraries.
    find "${SYSROOT}"/{usr/bin,usr/sbin,usr/lib,usr/lib64,lib64} \
         -type f -executable 2>/dev/null | while read -r f; do
        strip --strip-unneeded "$f" 2>/dev/null || true
    done

    # Firmware pruning: headless server nodes don't need WiFi / Bluetooth /
    # audio firmware; GPU firmware is pruned for the non-GPU roles (pki/be/fe).
    if ! ${ROLE_CLIENT}; then
        rm -rf \
            "${SYSROOT}"/lib/firmware/ath/ \
            "${SYSROOT}"/lib/firmware/ath6k/ \
            "${SYSROOT}"/lib/firmware/ath10k/ \
            "${SYSROOT}"/lib/firmware/ath11k/ \
            "${SYSROOT}"/lib/firmware/ath12k/ \
            "${SYSROOT}"/lib/firmware/brcm/ \
            "${SYSROOT}"/lib/firmware/iwlwifi-* \
            "${SYSROOT}"/lib/firmware/rtw88/ \
            "${SYSROOT}"/lib/firmware/rtw89/ \
            "${SYSROOT}"/lib/firmware/mediatek/ \
            "${SYSROOT}"/lib/firmware/libertas/ \
            "${SYSROOT}"/lib/firmware/mwlwifi/ \
            "${SYSROOT}"/lib/firmware/mwifiex/ \
            "${SYSROOT}"/lib/firmware/carl9170* \
            "${SYSROOT}"/lib/firmware/wfx/ \
            2>/dev/null || true
        if ! ${GPU}; then
            rm -rf \
                "${SYSROOT}"/lib/firmware/amdgpu/ \
                "${SYSROOT}"/lib/firmware/i915/ \
                "${SYSROOT}"/lib/firmware/nouveau/ \
                "${SYSROOT}"/lib/firmware/radeon/ \
                2>/dev/null || true
        fi
    fi

    info "Sysroot cleaned: locale/static-libs/pyc/ko-dbg/elf stripped; firmware pruned."
else
    # Every cross builder has always announced this skip; x86 accepted
    # --skip-clean but printed nothing, so the Clean-sysroot rung silently
    # vanished from the operator's ladder instead of reporting itself skipped.
    banner "SKIPPED sysroot clean (--skip-clean)"
fi

# ── 9. Stage4 tarball ──────────────────────────────────────────────
# ── BEGIN shared block: SELinux node-policy modules ───────────────────────────
# Compile specs/selinux/*.te into .pp ON THE X86 BUILD HOST and install them into
# ${SYSROOT}/usr/share/selinux/<type>/ — the exact directory provision_selinux()
# already globs at first boot (`semodule -s "${type}" -i /usr/share/selinux/
# "${type}"/*.pp`, specs/etc/keys-provision/provision.sh:2563), so this needs NO
# provision.sh change. NEVER compiled on the target: checkmodule/semodule_package/
# m4 are x86 BUILD-host binaries, the same reason selinux-base builds base.pp here
# and defers only the load. Placed at this point because the sysroot is complete
# (payload emerged, kernel/bootloader staged, both arms of the sysroot clean done)
# and nothing has been packaged or imaged yet.
# The image still boots PERMISSIVE: the enforce-gate service ships INERT (not in
# any runlevel, /etc/conf.d/selinux-enforce-gate SELINUX_ENFORCE_GATE=no) unless
# HUGMESH_SELINUX_ENFORCE_GATE=1 is set at build time. See the lib header for why.
slx_stage_node_policy "${SYSROOT}" "${SHARED_SPECS}" \
    || { err "SELinux node-policy staging failed (see above) — refusing to ship an image whose policy modules did not build."; exit 1; }
# ── END shared block: SELinux node-policy modules ─────────────────────────────

banner "Packaging stage4 tarball"
# Filename-safe role tag. be+gpu keeps the legacy 'host' tag so existing
# flashers/launchers/gen-provision-keys examples that reference 'host' keep
# working; the other roles get their own (filesystem-friendly) names.
case "${ROLE}" in
    be+gpu) ROLE_TAG="host" ;;
    *)      ROLE_TAG="${ROLE}" ;;
esac
# FD-08: client device artifacts carry the person-role + primary-domain tag so the
# filename identifies who/what the device is tied to (cosmetic per ADR-12 — the real
# isolation is per-domain authz, not the name). e.g. laptop-user-acme_example.
# UNAFFILIATED artifacts carry no person-role/domain tie — the bare role name.
if ${ROLE_CLIENT} && ! ${UNAFFILIATED}; then
    _primary_domain="${DOMAINS%%[ ,]*}"                       # first domain (space/comma sep)
    _domtag="${_primary_domain//./_}"                         # filesystem-safe
    ROLE_TAG="${ROLE}-${PERSON_ROLE}${_domtag:+-${_domtag}}"
fi
STAGE4="${WORK_DIR}/${BRAND}-x86-amd64-${ROLE_TAG}-${ENV}-${BUILD_TS}.stage4.tar.xz"
# Multi-threaded xz (-T0) over the tar stream — -cJf is single-threaded and
# left 27 cores idle on the multi-GB sysroot; mirrors the fs.tar codepath below.
# --exclude=./usr/src: the kernel was built in /usr/src/linux (its modules +
# vmlinuz are already installed to /lib/modules + /boot), so the multi-GB build
# tree (.o/.cmd objects) is pure cruft in the image — and baking it in overflowed
# the fixed ROOT_MiB ext4 root partition ("No space left on device" mid-.img
# population). The rpi5 builder already strips it (rm /usr/src/* + --exclude); match it.
# --exclude=./home/${DEFAULT_USER}: the LOCAL USER's home (DEFAULT_USER already
# carries any --local-user override, :1621) is created by firstboot, so any
# build-time content under it is host leakage — was hard-coded './home/magus',
# which only worked when the operator WAS magus.
tar -C "${SYSROOT}" --xattrs-include='*.*' --numeric-owner \
    --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' --exclude='./run/*' \
    --exclude='./var/cache' --exclude='./tmp/*' --exclude='./usr/src' --exclude="./home/${DEFAULT_USER}" -cpf - . 2>/dev/null \
    | xz -T0 -6 > "${STAGE4}" \
  || tar -C "${SYSROOT}" --numeric-owner \
    --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' --exclude='./run/*' \
    --exclude='./var/cache' --exclude='./tmp/*' --exclude='./usr/src' --exclude="./home/${DEFAULT_USER}" -cpf - . | xz -T0 -6 > "${STAGE4}"
info "Stage4: ${STAGE4} ($(du -sh "${STAGE4}" | cut -f1))"

# ── 10. Raw .img (DEFAULT deliverable) ─────────────────────────────
# UEFI GPT image mirroring the rpi5 build_img, adapted MBR->GPT + a GRUB-EFI
# --removable install. Layout: p1 ESP FAT32 (/boot/efi, holds /EFI/BOOT/BOOTX64.EFI
# + grub.cfg) + p2 ext4 root (LAST so growroot expands it). Boots any UEFI PC the
# image is dd'd onto (no NVRAM entry — --no-nvram + --removable fallback path).
#
# Runs entirely as root (the build is already privileged): losetup, mkfs, mount,
# grub-mkimage and xattr-preserving extraction all require it. A cleanup trap
# tears down the ESP+root mounts and the loop device on ANY failure/early return.
IMG_PATH="(not built)"
INSTALLER_ISO_PATH="(not built)"
FS_TAR_PATH="(not built)"
build_img() {
    local img_size_mib loop esp_part root_part root_mnt esp_uuid root_uuid kver vmlinuz initrd
    # Init ALL vars the EXIT/ERR cleanup trap reads BEFORE the trap is armed: the trap
    # (_img_cleanup) references esp_part/root_part/loop, but they are assigned much later
    # (losetup, below). Under `set -euo pipefail` a failure in the window between arming the
    # trap and those assignments (e.g. parted/sfdisk) would fire the trap, which would then
    # die on `unbound variable: esp_part` and MASK the real error. Empty-init keeps cleanup
    # a safe no-op for the not-yet-created loops.
    loop=""; root_mnt=""; esp_part=""; root_part=""

    IMG_PATH="${WORK_DIR}/${BRAND}-x86-amd64-${ROLE_TAG}-${ENV}-${BUILD_TS}.img"

    # 1MiB alignment gap + 512MiB ESP + ROOT_MiB ext4 root + 1MiB slack.
    img_size_mib=$(( 1 + 512 + ROOT_MiB + 1 ))

    # Pre-flight (fail in seconds, not after a long extraction): does the finished
    # payload fit the ROOT_MiB root partition? Converts the cryptic mid-tar "No space
    # left on device" into an upfront, actionable error. -x stays on the sysroot fs so
    # any still-bound mounts aren't counted.
    local payload_mib cap_mib
    payload_mib="$(du -sxBM "${SYSROOT}" 2>/dev/null | cut -f1 | tr -dc '0-9')"
    cap_mib=$(( ROOT_MiB * 93 / 100 ))   # ext4 metadata + 5% reserved ≈ 7% overhead
    if [ -n "${payload_mib}" ] && [ "${payload_mib}" -gt "${cap_mib}" ]; then
        # AUTO-GROW (was a fatal error): bump the compact root to fit the payload +
        # ~15% headroom, aligned to a GiB. growroot still resizes to the real disk on
        # first boot, so a larger compact .img is harmless — far better than failing
        # the whole build on a payload-size surprise (a --capable-heavy or seed/
        # pollution-bloated desktop). An explicit --img-size is grown too (fitting the
        # payload beats erroring); pass a bigger one if you want extra slack.
        local new_root=$(( (payload_mib * 115 / 100 / 1024 + 1) * 1024 ))
        warn "Payload ${payload_mib} MiB exceeds the ${ROOT_MiB} MiB root (usable ~${cap_mib} MiB) — auto-growing the .img root to ${new_root} MiB (growroot still resizes on boot)."
        ROOT_MiB="${new_root}"
        cap_mib=$(( ROOT_MiB * 93 / 100 ))
        img_size_mib=$(( 1 + 512 + ROOT_MiB + 1 ))
    fi
    info "Pre-flight: payload ${payload_mib:-?} MiB fits the ${ROOT_MiB} MiB root (usable ~${cap_mib} MiB)"

    _img_cleanup() {
        local rc=$? _lp
        set +e
        [ -n "${root_mnt}" ] && mountpoint -q "${root_mnt}/boot/efi" && umount "${root_mnt}/boot/efi"
        [ -n "${root_mnt}" ] && mountpoint -q "${root_mnt}" && umount "${root_mnt}"
        # Detach the per-partition offset loops (esp_part/root_part) and any
        # whole-disk loop. Each is a real /dev/loopN created by losetup --offset.
        for _lp in "${esp_part}" "${root_part}" "${loop}"; do
            [ -n "${_lp}" ] && losetup "${_lp}" &>/dev/null && losetup -d "${_lp}"
        done
        [ -n "${root_mnt}" ] && rmdir "${root_mnt}" 2>/dev/null
        return "${rc}"
    }
    trap '_img_cleanup' ERR EXIT

    info "Image size: ${img_size_mib} MiB (1 gap + 512 ESP + ${ROOT_MiB} ext4 + 1 slack)"
    rm -f "${IMG_PATH}"
    truncate -s "${img_size_mib}MiB" "${IMG_PATH}"

    # GPT: p1 ESP FAT32 (esp flag), p2 ext4 root (513..100%). p2 is LAST so
    # growroot can expand it to the end of the medium on first boot. Pure UEFI —
    # no BIOS-boot partition (the adopted design is UEFI-only for the .img).
    parted -s "${IMG_PATH}" mklabel gpt
    parted -s "${IMG_PATH}" mkpart ESP fat32 1MiB 513MiB
    parted -s "${IMG_PATH}" set 1 esp on
    parted -s "${IMG_PATH}" mkpart root ext4 513MiB 100%

    # Map each partition with its OWN offset loop device. `losetup -fP` partition
    # CHILD nodes (loopXp1/p2) are NOT materialised inside a `docker run --privileged`
    # container — the kernel scans the table but with no udev nothing creates
    # /dev/loopXpN, so mkfs/mount silently fail on the missing node and the image is
    # shipped HOLLOW (GPT table only, empty partitions) while the script prints
    # "Image created". Per-partition offset loops sidestep partition scanning: each
    # is a plain block device over just that partition's byte range, so it always
    # appears as /dev/loopN regardless of udev. (loop=whole-disk loop kept only for
    # PARTUUID-free fallback/cleanup; not used for mkfs/mount.)
    local geom esp_start esp_size root_start root_size
    geom="$(sfdisk -d "${IMG_PATH}")"
    # sfdisk -d emits one "... : start=N, size=M, type=..., uuid=U, name=..." line
    # per partition, in order (p1=ESP, p2=root). Parse start/size (sectors) + uuid
    # (the GPT partition GUID == PARTUUID; lower-cased to match blkid's old output).
    local -a _pl; mapfile -t _pl < <(printf '%s\n' "${geom}" | grep -E 'start=')
    # Guard the partition-line count BEFORE indexing _pl[1]: under `set -u` an out-of-range
    # array subscript aborts (unbound variable) — which would fire here, before the friendly
    # geometry guard below, and then re-trip the cleanup trap. sfdisk -d must list both the
    # ESP and root partition lines; anything less means the GPT table write failed upstream.
    [ "${#_pl[@]}" -ge 2 ] \
        || { err "sfdisk reported ${#_pl[@]} partition line(s), expected 2 (ESP+root) — GPT table write failed; refusing to image"; exit 1; }
    _fld() { printf '%s' "$1" | grep -oE "$2=[ ]*[^,]*" | sed "s/$2=//; s/[\" ]//g"; }
    esp_start="$(_fld "${_pl[0]}" start)"; esp_size="$(_fld "${_pl[0]}" size)"
    root_start="$(_fld "${_pl[1]}" start)"; root_size="$(_fld "${_pl[1]}" size)"
    esp_uuid="$(_fld "${_pl[0]}" uuid | tr 'A-Z' 'a-z')"
    root_uuid="$(_fld "${_pl[1]}" uuid | tr 'A-Z' 'a-z')"
    [ -n "${esp_start}" ] && [ -n "${root_start}" ] && [ -n "${root_size}" ] \
        || { err "could not parse GPT geometry from sfdisk -d — refusing to image"; exit 1; }

    # The container ships only /dev/loop0 and has no udev to create more on demand,
    # so `losetup --find` for the 2nd partition fails "device node /dev/loopN is
    # lost. You may use mknod(1) to recover it." Pre-create a pool of loop nodes
    # (block major 7) so --find always has a backing /dev node to claim.
    local _ln
    for _ln in $(seq 0 31); do
        [ -e "/dev/loop${_ln}" ] || mknod "/dev/loop${_ln}" b 7 "${_ln}" 2>/dev/null || true
    done

    esp_part="$(losetup --show -f --offset $((esp_start*512))  --sizelimit $((esp_size*512))  "${IMG_PATH}")"
    root_part="$(losetup --show -f --offset $((root_start*512)) --sizelimit $((root_size*512)) "${IMG_PATH}")"
    [ -b "${esp_part}" ] && [ -b "${root_part}" ] \
        || { err "offset loop devices not created (esp=${esp_part} root=${root_part}) — refusing to image"; exit 1; }

    info "Formatting ${esp_part} (FAT32 ${ESP_LABEL}) and ${root_part} (ext4 ${ROOT_LABEL})"
    mkfs.vfat -F 32 -n "${ESP_LABEL}" "${esp_part}"
    mkfs.ext4 -q -L "${ROOT_LABEL}" -F "${root_part}"

    root_mnt="$(mktemp -d "${BUILD_ROOT}/img-root.XXXXXX")"
    mount "${root_part}" "${root_mnt}"

    info "Extracting stage4 into ${root_mnt}"
    tar -C "${root_mnt}" --xattrs-include='*.*' -xpf "${STAGE4}" 2>/dev/null || \
    tar -C "${root_mnt}" -xpf "${STAGE4}"

    # HARD anti-hollow assert: the extraction must have produced a real rootfs.
    # Without this a future mount/extract failure ships an empty image silently
    # (the bug this whole block fixes). Require the kernel + modules + init tree.
    { [ -d "${root_mnt}/usr/lib/modules" ] && [ -n "$(ls -A "${root_mnt}/usr/lib/modules" 2>/dev/null)" ] \
        && ls "${root_mnt}/boot/vmlinuz"* &>/dev/null && [ -x "${root_mnt}/sbin/init" -o -L "${root_mnt}/sbin/init" ]; } \
        || { err "rootfs is empty/incomplete after stage4 extraction (no modules/vmlinuz/init) — refusing to ship a HOLLOW .img"; exit 1; }

    # Mount the ESP at /boot/efi (the kernel/initramfs stay on the ext4 /boot per
    # the fstab; the ESP holds only /EFI/BOOT/BOOTX64.EFI + grub.cfg).
    mkdir -p "${root_mnt}/boot/efi"
    mount "${esp_part}" "${root_mnt}/boot/efi"

    # ── Root identity (PARTUUID for the kernel/fstab; fs-UUID for grub search) ──
    # PARTUUIDs come from the GPT (parsed above) — an offset loop exposes only the
    # filesystem, not the partition table, so blkid -s PARTUUID would be empty here.
    info "Root identity: root PARTUUID=${root_uuid}  ESP PARTUUID=${esp_uuid}"
    local root_fsuuid; root_fsuuid="$(blkid -s UUID -o value "${root_part}")"
    # The ESP's FILESYSTEM UUID (not its PARTUUID): grub.cfg's UKI menuentry must
    # `search --fs-uuid` its way to the ESP before chainloading (see below) — the
    # embedded grub-mkimage config points $root at the ext4 ROOT partition, where
    # the UKI does not live.
    local esp_fsuuid; esp_fsuuid="$(blkid -s UUID -o value "${esp_part}")"
    info "Root identity: root PARTUUID=${root_uuid}  ESP PARTUUID=${esp_uuid}"
    # The stage4 already carries specs-x86/etc/fstab with the two tokens; rewrite
    # them to the real PARTUUIDs of this image.
    sed -i -e "s/__ROOT_PARTUUID__/${root_uuid}/g" -e "s/__ESP_PARTUUID__/${esp_uuid}/g" \
        "${root_mnt}/etc/fstab"

    # ── Locate the kernel + disk initramfs on the ext4 /boot ──────────
    kver="$(ls "${root_mnt}/lib/modules" 2>/dev/null | sort -V | tail -1)"
    vmlinuz="$(ls -1 "${root_mnt}/boot/vmlinuz-"* "${root_mnt}/boot/vmlinuz" 2>/dev/null | sort -V | tail -1 || true)"
    initrd="$(ls -1 "${root_mnt}/boot/initramfs-"*.img 2>/dev/null | grep -v 'initramfs-live' | sort -V | tail -1 || true)"
    vmlinuz="${vmlinuz##*/}"; initrd="${initrd##*/}"

    # The initrd is LOAD-BEARING (rd.luks unlock, dm_crypt/usb/nvme staging):
    # never seal an .img whose grub.cfg would silently omit its "initrd" line.
    # The host-side DISK-INITRAMFS GATE (after the kernel phase) already
    # enforced this from the sysroot; this is the last line of defense at the
    # sealed filesystem itself — grub-mkimage-gate posture, not a warning.
    if [ -z "${initrd}" ] || [ ! -s "${root_mnt}/boot/${initrd}" ]; then
        err "no non-empty disk initramfs on the image /boot (found: '${initrd:-none}') —"
        err "refusing to seal an .img that would boot kernel-only (its grub.cfg would"
        err "carry no initrd line; the disk would not boot on LUKS/USB/NVMe systems)."
        exit 1
    fi

    # ── GRUB-EFI via grub-mkimage (loop-device-safe) ──────────────────
    # grub-install probes the backing disk via hostdisk// which fails for loop
    # devices — GRUB's native disk layer cannot open a loop-device backing file.
    # grub-mkimage bypasses the probe: it embeds a search-by-fs-uuid config that
    # finds the root partition at runtime, disk-order-independent. The module tree
    # is copied to the ext4 /boot so the running GRUB can load fonts/themes.
    info "Building GRUB-EFI core image (grub-mkimage, loop-device-safe)"
    mkdir -p "${root_mnt}/boot/efi/EFI/BOOT"
    mkdir -p "${root_mnt}/boot/grub/x86_64-efi"
    cp -a /usr/lib/grub/x86_64-efi/. "${root_mnt}/boot/grub/x86_64-efi/"
    local grub_embed; grub_embed="$(mktemp)"
    printf 'search --no-floppy --fs-uuid --set=root %s\nset prefix=($root)/boot/grub\nconfigfile ($root)/boot/grub/grub.cfg\n' \
        "${root_fsuuid}" > "${grub_embed}"
    grub-mkimage \
        --directory /usr/lib/grub/x86_64-efi \
        --output "${root_mnt}/boot/efi/EFI/BOOT/BOOTX64.EFI" \
        --format x86_64-efi \
        --config "${grub_embed}" \
        --prefix '/boot/grub' \
        part_gpt fat ext2 normal linux search search_fs_uuid configfile gzio all_video \
        || { rm -f "${grub_embed}"; err "grub-mkimage FAILED — .img would not be UEFI-bootable"; exit 1; }
    rm -f "${grub_embed}"
    # Bootloader must be present before sealing the image.
    [ -f "${root_mnt}/boot/efi/EFI/BOOT/BOOTX64.EFI" ] \
        || { err "ESP has no EFI/BOOT/BOOTX64.EFI after grub-mkimage — refusing to ship a non-booting .img"; exit 1; }

    # ── UKI → ESP (Secure Boot direct-boot path) ──────────────────
    # The signed UKI (kernel+initramfs+cmdline as a PE binary) was built and signed
    # outside the chroot. Install it into the ESP so UEFI / shim / GRUB can load it.
    local uki_src="${SYSROOT}/boot/${UKI_NAME}"
    if [ -f "${uki_src}" ]; then
        mkdir -p "${root_mnt}/boot/efi/EFI/Linux"
        cp "${uki_src}" "${root_mnt}/boot/efi/EFI/Linux/${UKI_NAME}"
        info "UKI installed to ESP: EFI/Linux/${UKI_NAME}"
        # Org cert and db.auth: keys-provision enrolls via mokutil on first boot.
        # SB_ETC_DIR/SB_EFI_VENDOR come from the boot-chain identity fold — the
        # same fold the stager used — so UNAFFILIATED certs (staged under the
        # neutral /etc/gentoo dir) land on the ESP as EFI/gentoo/ instead of
        # silently never shipping.
        if [ -d "${SYSROOT}${SB_ETC_DIR}" ]; then
            mkdir -p "${root_mnt}/boot/efi/EFI/${SB_EFI_VENDOR}"
            cp "${SYSROOT}${SB_ETC_DIR}"/*.{crt,cer,auth} \
               "${root_mnt}/boot/efi/EFI/${SB_EFI_VENDOR}/" 2>/dev/null || true
            info "Org Secure Boot cert installed to ESP: EFI/${SB_EFI_VENDOR}/"
        fi
    else
        info "No signed UKI at ${uki_src} — .img boots via GRUB+vmlinuz only (no Secure Boot UKI)"
    fi

    # ── Shim → ESP (replaces bare GRUB for Secure Boot chain) ─────
    # shim (Microsoft-signed) lets the image boot on hardware with Secure Boot in
    # User Mode without needing to enroll a custom PK. shim loads grubx64.efi
    # (signed with the org key) which then loads the UKI or vmlinuz.
    # Find shim on the build host (sys-boot/shim installs to /usr/share/shim).
    local shim_src; shim_src="$(find /usr/share/shim /usr/lib/shim 2>/dev/null \
        -name 'BOOTX64.EFI' -o -name 'shimx64.efi' 2>/dev/null | head -1 || true)"
    local mmgr_src; mmgr_src="$(find /usr/share/shim /usr/lib/shim 2>/dev/null \
        -name 'mmx64.efi' -o -name 'MokManager.efi' 2>/dev/null | head -1 || true)"
    if [ -n "${shim_src}" ] && [ -f "${shim_src}" ]; then
        # Move GRUB image to grubx64.efi so shim loads it as the second stage.
        if [ -f "${root_mnt}/boot/efi/EFI/BOOT/BOOTX64.EFI" ]; then
            cp "${root_mnt}/boot/efi/EFI/BOOT/BOOTX64.EFI" \
               "${root_mnt}/boot/efi/EFI/BOOT/grubx64.efi"
        fi
        # Sign GRUB with org key so shim verifies it.
        if command -v sbsign >/dev/null && [ -f "${SBKEY:-}" ] && [ -f "${SBCRT:-}" ]; then
            sbsign --key "${SBKEY}" --cert "${SBCRT}" \
                --output "${root_mnt}/boot/efi/EFI/BOOT/grubx64.efi" \
                "${root_mnt}/boot/efi/EFI/BOOT/grubx64.efi" 2>/dev/null \
                && info "GRUB EFI signed with org key → grubx64.efi"
        fi
        cp "${shim_src}" "${root_mnt}/boot/efi/EFI/BOOT/BOOTX64.EFI"
        [ -n "${mmgr_src}" ] && [ -f "${mmgr_src}" ] && \
            cp "${mmgr_src}" "${root_mnt}/boot/efi/EFI/BOOT/mmx64.efi"
        info "Shim installed as EFI/BOOT/BOOTX64.EFI (Secure Boot chain: shim→grubx64.efi→UKI)"
    else
        info "Shim not found on build host (install sys-boot/shim); .img uses bare GRUB at BOOTX64.EFI"
    fi

    # ── Hand-written grub.cfg (no grub-mkconfig => no host os-prober/chroot) ──
    # Source the hardened cmdline from the grub defaults so the .img and the live
    # ISO share ONE cmdline (lsm=,selinux=1,audit=1,cgroup,slab,ASLR hardening).
    local cmdline=""
    if [ -f "${root_mnt}/etc/default/grub" ]; then
        cmdline="$(. "${root_mnt}/etc/default/grub"; printf '%s' "${GRUB_CMDLINE_LINUX:-}")"
    fi
    [ -z "${cmdline}" ] && cmdline="lsm=lockdown,yama,selinux,bpf lockdown=integrity selinux=1 audit=1"
    mkdir -p "${root_mnt}/boot/grub"
    {
        echo "set timeout=5"
        echo "set default=0"
        echo "insmod part_gpt"
        echo "insmod ext2"
        echo "insmod fat"
        echo "insmod search_fs_uuid"
        # GRUB's EFI chainload command lives in chain.mod — `insmod chainloader`
        # names a module that does not exist, so the UKI menuentry died with
        # "can't find command \`chainloader'" and GRUB sat at its menu until the
        # harness SSH timeout (the whole-x86-column 2400s hang, matrix triage
        # 2026-08-13). The module tree copied to /boot/grub above makes insmod
        # chain resolvable at runtime.
        echo "insmod chain"
        # UKI entry: direct chainload from ESP — preferred when Secure Boot is active.
        if [ -f "${root_mnt}/boot/efi/EFI/Linux/${UKI_NAME}" ]; then
            echo "menuentry \"${BRAND_TITLE} (${ROLE}) — Secure Boot UKI\" {"
            # $root still points at the ext4 ROOT partition here (the embedded
            # grub-mkimage config search'd for ${root_fsuuid}), but the UKI was
            # installed on the ESP — re-point $root at the ESP's fs-UUID first
            # or the chainloader line fails file-not-found.
            echo "    search --no-floppy --fs-uuid --set=root ${esp_fsuuid}"
            echo "    chainloader /EFI/Linux/${UKI_NAME}"
            echo "}"
        fi
        echo "menuentry \"${BRAND_TITLE} (${ROLE})\" {"
        echo "    search --no-floppy --fs-uuid --set=root ${root_fsuuid}"
        if [ -n "${vmlinuz}" ]; then
            echo "    linux /boot/${vmlinuz} root=PARTUUID=${root_uuid} ro ${cmdline}"
            [ -n "${initrd}" ] && echo "    initrd /boot/${initrd}"
        else
            echo "    # WARNING: no vmlinuz found under /boot at build time"
        fi
        echo "}"
    } > "${root_mnt}/boot/grub/grub.cfg"

    # Drop a per-device-editable growfs.conf on the ESP so an operator can retune
    # the first-boot grow (fill|none|<size>) on a flashed disk WITHOUT a rebuild.
    # growroot reads /boot/efi/growfs.conf ahead of the baked /etc copy.
    write_growfs_conf "${root_mnt}/boot/efi/growfs.conf"

    # ── Filesystem tarball ────────────────────────────────────────────
    # Capture the FULLY-MOUNTED tree (ext4 root with the FAT ESP mounted at
    # /boot/efi) as one tar, so it can be untarred onto pre-mounted partitions
    # (mount the ESP at /boot/efi first) to provision a disk without dd. tar
    # crosses the /boot/efi mountpoint by default, so the ESP contents
    # (EFI/BOOT/BOOTX64.EFI + grub.cfg) are captured at /boot/efi/*. This is the
    # .img's exact final filesystem (PARTUUID fstab + grub.cfg baked in) — the
    # rootfs "as if mounted". Mirrors the rpi5 build's FS-tarball step.
    if ${BUILD_TAR}; then
        local fs_tar="${WORK_DIR}/${BRAND}-x86-amd64-${ROLE_TAG}-${ENV}-${BUILD_TS}.fs.tar.xz"
        info "Filesystem tarball (mounted tree) -> ${fs_tar}"
        tar -C "${root_mnt}" --xattrs --xattrs-include='*.*' --numeric-owner -cpf - . 2>/dev/null \
            | xz -T0 -6 > "${fs_tar}" \
          || tar -C "${root_mnt}" --numeric-owner -cpf - . | xz -T0 -6 > "${fs_tar}"
        FS_TAR_PATH="${fs_tar}"
    fi

    sync
    umount "${root_mnt}/boot/efi"
    umount "${root_mnt}"
    rmdir  "${root_mnt}"; root_mnt=""
    losetup -d "${loop}"; loop=""
    trap - ERR EXIT

    if ${COMPRESS_IMG}; then
        info "Compressing image (xz -T0 -9)..."
        xz -T0 -9 -f "${IMG_PATH}"
        IMG_PATH="${IMG_PATH}.xz"
    fi

    info "Image created: ${IMG_PATH}"
    info "Size: $(du -sh "${IMG_PATH}" | cut -f1)"
}

if ${BUILD_IMG}; then
    banner "Building raw .img (UEFI GPT: ESP + ext4 root, GRUB-EFI --removable)"
    # A bootable image needs a kernel on the ext4 /boot. Guard like the ISO path:
    # if no vmlinuz is present (kernel skipped / build failed), skip rather than crash.
    if [ -z "$(ls -1 "${SYSROOT}/boot/vmlinuz-"* "${SYSROOT}/boot/vmlinuz" 2>/dev/null)" ]; then
        warn "No vmlinuz in ${SYSROOT}/boot — skipping .img (don't pass --skip-kernel)."
        IMG_PATH="(not built — kernel missing)"
    else
        build_img
    fi
else
    banner "SKIPPED raw .img (--no-img)"
fi

# ── 11. ISOs (live + installer, both opt-in) ───────────────────────
ISO_PATH="(not built)"
if ! ${SKIP_ISO}; then
    KVER="$(ls "${SYSROOT}/lib/modules" 2>/dev/null | sort -V | tail -1)"
    VMLINUZ="$(ls -1 "${SYSROOT}/boot/vmlinuz-"* "${SYSROOT}/boot/vmlinuz" 2>/dev/null | sort -V | tail -1 || true)"

    if ${LIVE_ISO} && [ -n "${VMLINUZ}" ] && [ -n "${KVER}" ]; then
        ISO_PATH="${WORK_DIR}/${BRAND}-x86-amd64-${ROLE_TAG}-${ENV}-${BUILD_TS}.live.iso"
        banner "Building LIVE image (bootable ISO: grub-mkrescue + squashfs)"
        # Live initramfs (dmsquash-live) built inside the chroot.
        mount_chroot; trap umount_chroot EXIT
        chroot "${SYSROOT}" /bin/bash -eo pipefail <<CHROOT || warn "live-initramfs dracut step FAILED (live ISO will be skipped)"
if ! command -v dracut >/dev/null; then
    echo "[build-x86] ERROR: dracut not installed in sysroot"; exit 1
fi
dracut --force --no-hostonly \
    --add "dmsquash-live" \
    --add-drivers "squashfs iso9660 loop sr_mod usb_storage ahci nvme" \
    --kver "${KVER}" /boot/initramfs-live.img
CHROOT
        umount_chroot; trap - EXIT

        if [ ! -s "${SYSROOT}/boot/initramfs-live.img" ]; then
            err "no live initramfs was generated — a live ISO without it cannot boot (root=live:/rd.live.* are dracut directives). Skipping live ISO."
            ISO_PATH="(not built — live initramfs missing)"
            SKIP_LIVE_PACK=true
        else
            SKIP_LIVE_PACK=false
        fi
        if ! ${SKIP_LIVE_PACK}; then
        mkdir -p "${ISO_DIR}/boot/grub" "${ISO_DIR}/LiveOS"
        cp "${VMLINUZ}" "${ISO_DIR}/boot/vmlinuz"
        cp "${SYSROOT}/boot/initramfs-live.img" "${ISO_DIR}/boot/initramfs.img"
        # Brand the live/installer GRUB boot screen with the same background + full GRUB
        # theme baked into the image, so the boot -> login -> desktop chain is consistent.
        [ -n "${BRAND_GRUB_BG_STAGED:-}" ] && cp "${BRAND_GRUB_BG_STAGED}" "${ISO_DIR}/boot/grub/hugmesh-background.png" 2>/dev/null || true
        if [ -n "${BRAND_GRUB_THEME_STAGED:-}" ] && [ -d "${BRAND_GRUB_THEME_STAGED}" ]; then
            mkdir -p "${ISO_DIR}/boot/grub/themes/hugmesh"
            cp -r "${BRAND_GRUB_THEME_STAGED}/." "${ISO_DIR}/boot/grub/themes/hugmesh/" 2>/dev/null || true
        fi
        rm -f "${ISO_DIR}/LiveOS/squashfs.img"
        if command -v mksquashfs >/dev/null; then
            # The build host's mksquashfs may lack zstd/xz (USE-gated). A hard-coded
            # -comp zstd then FAILS and (previously) silently shipped a rootfs-less
            # ISO. Probe for the best compressor it actually supports (zstd>xz>lz4>gzip).
            sq_comp=gzip; _sqp="$(mktemp -d)"
            for c in zstd xz lz4 lzo gzip; do
                if mksquashfs "${_sqp}" /tmp/.sqprobe.sqfs -comp "$c" -noappend -quiet >/dev/null 2>&1; then sq_comp="$c"; break; fi
            done
            rm -rf "${_sqp}" /tmp/.sqprobe.sqfs
            info "Squashing rootfs with -comp ${sq_comp} (this can take a while)..."
            mksquashfs "${SYSROOT}" "${ISO_DIR}/LiveOS/squashfs.img" \
                -comp "${sq_comp}" -e proc sys dev run var/cache/distfiles "home/${DEFAULT_USER}" >/dev/null \
                || { err "mksquashfs failed — cannot build a bootable live ISO"; exit 1; }
        else
            # squashfs-tools-ng fallback: same excludes, xz (kernel has SQUASHFS_XZ).
            # --xattrs: mksquashfs (above) preserves xattrs by DEFAULT, but GNU tar
            # stores none unless told to — without these flags this fallback silently
            # shipped a squashfs with every xattr (security.selinux included) stripped,
            # while the mksquashfs path, the stage4 tar and fs.tar all kept them.
            # tar2sqfs itself keeps whatever xattrs it finds in the archive.
            info "Squashing rootfs with tar2sqfs -c xz (this can take a while)..."
            tar -C "${SYSROOT}" --xattrs --xattrs-include='*.*' --numeric-owner \
                --exclude='./proc' --exclude='./sys' --exclude='./dev' \
                --exclude='./run' --exclude='./var/cache/distfiles' --exclude="./home/${DEFAULT_USER}" \
                -cpf - . | tar2sqfs -q -c xz -j "${JOBS}" "${ISO_DIR}/LiveOS/squashfs.img" \
                || { err "tar2sqfs failed — cannot build a bootable live ISO"; exit 1; }
        fi
        # Sanity: a real desktop rootfs squashes to GiBs; a tiny image means the squash
        # silently failed (unsupported compressor, bad excludes) — refuse to ship a
        # live ISO that boots to nothing (this is exactly the 111 MiB rootfs-less ISO).
        sq_mib=$(( $(stat -c%s "${ISO_DIR}/LiveOS/squashfs.img" 2>/dev/null || echo 0) / 1048576 ))
        if [ "${sq_mib}" -lt 200 ]; then
            err "live squashfs is only ${sq_mib} MiB — the rootfs was not captured; not shipping a broken live ISO."; exit 1
        fi
        info "Live rootfs squashed: ${sq_mib} MiB (-comp ${sq_comp:-xz})"
        # Unify the cmdline with the .img: source GRUB_CMDLINE_LINUX from the same
        # grub defaults (full KSPP/LSM/audit/cgroup hardening), not a short literal.
        LIVE_CMDLINE="$(. "${SPECS_DIR}/etc/default/grub"; printf '%s' "${GRUB_CMDLINE_LINUX:-lsm=lockdown,yama,selinux,bpf lockdown=integrity selinux=1 audit=1}")"
        # Live-ISO boot menu: plain live, copy-to-RAM (removable), and the two
        # installer entries (graphical Calamares / text ncurses) that boot the live
        # env and autostart the installer via the hugmesh.install= cmdline. The
        # toram + graphical-install entries set rd.live.ram=1 so the whole system
        # caches into memory and the USB/DVD can be pulled (and the installer can
        # even repartition the very disk it booted from).
        # console=ttyS0 first (kernel log also goes to serial — lets QEMU/headless
        # boot-tests capture it; harmless on PCs with no serial), tty0 last so the
        # SCREEN stays the primary console for a real desktop.
        _LBASE="root=live:CDLABEL=${LIVE_VOLID} rd.live.dir=/LiveOS rd.live.squashimg=squashfs.img console=ttyS0,115200 console=tty0"
        {
            echo "set timeout=10"
            echo "set default=0"
            # Branded boot screen: graphics + PNG modules, then either the FULL GRUB
            # theme (gfxmenu: title, accent-highlighted menu, countdown) or, failing
            # that, the background image alone. Same brand baked into the installed
            # system's /etc/default/grub (GRUB_THEME/GRUB_BACKGROUND/GRUB_COLOR_*).
            if [ -f "${ISO_DIR}/boot/grub/hugmesh-background.png" ] \
                    || [ -f "${ISO_DIR}/boot/grub/themes/hugmesh/theme.txt" ]; then
                echo "insmod all_video"
                echo "insmod png"
                echo "insmod gfxterm"
                echo "set gfxmode=1920x1080,1280x720,auto"
                echo "terminal_output gfxterm"
                if [ -f "${ISO_DIR}/boot/grub/themes/hugmesh/theme.txt" ]; then
                    echo "insmod gfxmenu"
                    [ -f "${ISO_DIR}/boot/grub/themes/hugmesh/font.pf2" ] \
                        && echo "loadfont /boot/grub/themes/hugmesh/font.pf2"
                    echo "set theme=/boot/grub/themes/hugmesh/theme.txt"
                fi
                [ -f "${ISO_DIR}/boot/grub/hugmesh-background.png" ] \
                    && echo "background_image /boot/grub/hugmesh-background.png"
            fi
            echo "menuentry \"${BRAND_TITLE} ${ROLE} (live)\" {"
            echo "    linux /boot/vmlinuz ${_LBASE} ${LIVE_CMDLINE}"
            echo "    initrd /boot/initramfs.img"
            echo "}"
            if ${LIVE_TORAM}; then
                echo "menuentry \"${BRAND_TITLE} ${ROLE} (live — Copy to RAM, removable)\" {"
                echo "    linux /boot/vmlinuz ${_LBASE} rd.live.ram=1 ${LIVE_CMDLINE}"
                echo "    initrd /boot/initramfs.img"
                echo "}"
            fi
            echo "menuentry \"Install ${BRAND_TITLE} (graphical installer)\" {"
            echo "    linux /boot/vmlinuz ${_LBASE} rd.live.ram=1 ${INSTALL_CMDLINE_KEY}=calamares ${LIVE_CMDLINE}"
            echo "    initrd /boot/initramfs.img"
            echo "}"
            echo "menuentry \"Install ${BRAND_TITLE} (text / ncurses installer)\" {"
            echo "    linux /boot/vmlinuz ${_LBASE} ${INSTALL_CMDLINE_KEY}=ncurses ${LIVE_CMDLINE}"
            echo "    initrd /boot/initramfs.img"
            echo "}"
        } > "${ISO_DIR}/boot/grub/grub.cfg"
        # Build the ISO via grub-mkrescue (GRUB at EFI/BOOT/BOOTX64.EFI).
        # Then, if shim is on the build host, post-process: move GRUB to grubx64.efi,
        # sign it with the org key, and install shim as BOOTX64.EFI so the ISO boots
        # on Secure Boot hardware without requiring a Microsoft-trusted firmware cert.
        # The live rootfs squashfs is >4 GiB. grub-mkrescue drives xorriso in
        # mkisofs-emulation mode, whose default ISO level caps a SINGLE file at
        # 4 GiB-1 and SILENTLY DROPS anything larger — yielding a bootable-looking
        # but rootfs-less ~111 MiB ISO (kernel+initramfs only, no /LiveOS/squashfs.img).
        # -iso-level 3 enables multi-extent files so the 5+ GiB squashfs is embedded.
        if grub-mkrescue -o "${ISO_PATH}" "${ISO_DIR}" -volid "${LIVE_VOLID}" -iso-level 3 2>/dev/null; then
            # Verify the squashfs actually made it IN: the ISO must be at least as large
            # as the squashfs we built (minus 10% slack). If it isn't, xorriso dropped the
            # >4 GiB file again — fail loud rather than ship a live ISO that boots to nothing.
            iso_mib=$(( $(stat -c%s "${ISO_PATH}" 2>/dev/null || echo 0) / 1048576 ))
            if [ "${iso_mib}" -lt $(( sq_mib * 9 / 10 )) ]; then
                err "live ISO is only ${iso_mib} MiB but the squashfs is ${sq_mib} MiB — the rootfs was dropped from the ISO (ISO-level/large-file issue); not shipping a broken live ISO."; exit 1
            fi
            info "Bootable live ISO: ${ISO_PATH} (${iso_mib} MiB)"
        else
            warn "grub-mkrescue failed; live ISO not produced"; ISO_PATH="(not built — grub-mkrescue failed)"
        fi
        # ── Shim post-processing for Secure Boot live boot ──────────
        # This block had NEVER succeeded before 2026-07-29: 4 of 4 live ISOs
        # shipped WITHOUT shim while printing only a warning (sessions
        # 20260724-013844-53b498, 20260725-061608-978c99, and both x86 roles of
        # 20260719-103006-a775c2 all logged "WARNING: xorriso shim
        # post-processing failed; live ISO uses bare GRUB (no shim)").
        # Root causes, each proven against 53b498's real ISO:
        #   1. it extracted UPPERCASE /EFI/BOOT/BOOTX64.EFI, but grub-mkrescue
        #      writes the (case-sensitive) Rock Ridge tree LOWERCASE — the real
        #      path is /efi/boot/bootx64.efi — so the extract always died:
        #        xorriso : FAILURE : Cannot determine attributes of (ISO) source
        #        file '/EFI/BOOT/BOOTX64.EFI' : No such file or directory
        #      and `2>/dev/null || true` swallowed exactly that line. The later
        #      -map of the never-created grubx64.efi then failed the rewrite.
        #   2. even with the extract fixed, patching the ISO TREE is cosmetic:
        #      UEFI firmware boots the El Torito image /efi.img (which is also
        #      the GPT "EFI boot partition" — verified via -report_el_torito /
        #      -report_system_area), so a tree-level shim is never read. The
        #      REPLACEMENT El Torito FAT below is the actual fix.
        #   3. the rewrite had no -boot_image directive, so xorriso DISCARDED
        #      the El Torito + MBR/GPT equipment ("Detected El-Torito boot
        #      information which currently is set to be discarded") — had it
        #      ever produced output, that ISO would have booted NOWHERE.
        #      '-boot_image any replay' regenerates BIOS+UEFI El Torito, the
        #      grub2 MBR and the GPT for the new layout.
        # '-hfsplus off': replay pins grub-mkrescue's Mac APM gap layout to the
        # OLD file placement and libisofs dies "GPT partitions 1 and 2 overlap
        # by 80 blocks"; dropping the Mac blessing resolves it, and shim is a
        # Microsoft-signed PC artifact — Mac APM boot is not an SB-shim target.
        # (grub-mkstandalone was probed by the old gate but never invoked —
        # dropped; mkfs.vfat + mtools build the replacement FAT instead.)
        # A FAILED attempt now FAILS THE BUILD: shim installed on the build
        # host declares Secure Boot intent (the .img path installs it
        # unconditionally on the same signal), every step past the tool probe
        # is deterministic tooling — not environment — and warn-only is exactly
        # how 4/4 ISOs shipped broken. A host WITHOUT shim keeps the
        # informational skip; missing sbsign/org-key only degrades to a LOUD
        # warning (environmental, and shim without a signed GRUB still boots
        # non-SB machines unchanged).
        _shim_src="$(find /usr/share/shim /usr/lib/shim 2>/dev/null \
            \( -name 'BOOTX64.EFI' -o -name 'shimx64.efi' \) 2>/dev/null | head -1 || true)"
        if [ -f "${ISO_PATH}" ] && [ -n "${_shim_src}" ] && [ -f "${_shim_src}" ] \
                && command -v xorriso >/dev/null && command -v mkfs.vfat >/dev/null \
                && command -v mcopy >/dev/null && command -v mmd >/dev/null; then
            info "Post-processing live ISO to add shim (Secure Boot: shim→signed GRUB→kernel)"
            _iso_tmp="${ISO_PATH}.shim-work"
            rm -rf "${_iso_tmp}"; mkdir -p "${_iso_tmp}/EFI/BOOT"
            _shim_fail() {
                err "shim post-processing FAILED: $1"
                err "Refusing to ship the live ISO without its Secure Boot chain — 4/4 prior"
                err "live ISOs shipped exactly that way, silently. Uninstall sys-boot/shim from"
                err "the BUILD HOST if a shim-less live ISO is genuinely wanted."
                rm -rf "${_iso_tmp}"
                exit 1
            }
            # 1) GRUB EFI out of the ISO — probe the tree CASE-INSENSITIVELY,
            #    fall back to unpacking the El Torito /efi.img (authoritative
            #    for firmware anyway). Errors are LOUD from here on.
            _grub_in_iso="$(xorriso -indev "${ISO_PATH}" -find / -type f 2>/dev/null \
                | tr -d "'" | grep -iE '^/efi/boot/bootx64\.efi$' | head -1 || true)"
            if [ -n "${_grub_in_iso}" ]; then
                xorriso -indev "${ISO_PATH}" -osirrox on \
                    -extract "${_grub_in_iso}" "${_iso_tmp}/EFI/BOOT/grubx64.efi" \
                    || _shim_fail "could not extract ${_grub_in_iso} from ${ISO_PATH}"
            else
                xorriso -indev "${ISO_PATH}" -osirrox on \
                    -extract /efi.img "${_iso_tmp}/efi-old.img" \
                    || _shim_fail "no /efi/boot/bootx64.efi in the ISO tree and /efi.img is not extractable"
                mcopy -n -i "${_iso_tmp}/efi-old.img" ::/efi/boot/bootx64.efi \
                    "${_iso_tmp}/EFI/BOOT/grubx64.efi" \
                    || _shim_fail "the El Torito /efi.img carries no efi/boot/bootx64.efi"
            fi
            chmod u+w "${_iso_tmp}/EFI/BOOT/grubx64.efi"   # osirrox preserves the ISO's r--r--r--
            # 2) Sign GRUB with the org key so shim verifies it. In-place sbsign
            #    (--output X X) is live-proven by the .img path ("GRUB EFI
            #    signed with org key" in 3 sessions' logs). Without a key the
            #    chain is INCOMPLETE — SB firmware will refuse the unsigned
            #    GRUB — but non-SB boot is unchanged: warn loudly, keep going.
            if command -v sbsign >/dev/null && [ -f "${SBKEY:-}" ] && [ -f "${SBCRT:-}" ]; then
                sbsign --key "${SBKEY}" --cert "${SBCRT}" \
                    --output "${_iso_tmp}/EFI/BOOT/grubx64.efi" \
                    "${_iso_tmp}/EFI/BOOT/grubx64.efi" \
                    && info "Live GRUB EFI signed with org key" \
                    || _shim_fail "sbsign failed on the live GRUB EFI (key: ${SBKEY})"
            else
                warn "live ISO: shim will ship with an UNSIGNED GRUB (sbsign or the org key is"
                warn "unavailable) — Secure Boot firmware will refuse it until GRUB is signed;"
                warn "non-Secure-Boot boot is unaffected."
            fi
            # 3) Shim + MOK manager.
            cp "${_shim_src}" "${_iso_tmp}/EFI/BOOT/BOOTX64.EFI" \
                || _shim_fail "could not stage shim from ${_shim_src}"
            _mmgr="$(find /usr/share/shim /usr/lib/shim 2>/dev/null \
                \( -name 'mmx64.efi' -o -name 'MokManager.efi' \) | head -1 || true)"
            if [ -n "${_mmgr}" ]; then
                cp "${_mmgr}" "${_iso_tmp}/EFI/BOOT/mmx64.efi" \
                    || _shim_fail "could not stage MokManager from ${_mmgr}"
            else
                warn "live ISO: no mmx64.efi/MokManager next to shim — org-cert MOK enrollment"
                warn "from this media will not be possible (the shim chain itself still works)."
            fi
            # Org cert for enrollment inside the live env. SB_ETC_DIR /
            # SB_EFI_VENDOR come from the boot-chain identity fold (same
            # resolution as the stager), so UNAFFILIATED media carries the cert
            # under the neutral efi/gentoo/ dir. Tolerant glob: no cert staged
            # is a legitimate (--no-secure-boot / unsigned) build.
            if [ -d "${SYSROOT}${SB_ETC_DIR}" ]; then
                mkdir -p "${_iso_tmp}/EFI/${SB_EFI_VENDOR}"
                cp "${SYSROOT}${SB_ETC_DIR}"/*.{crt,cer,auth} \
                   "${_iso_tmp}/EFI/${SB_EFI_VENDOR}/" 2>/dev/null || true
            fi
            # 4) REPLACEMENT El Torito FAT — the filesystem firmware actually
            #    reads (El Torito UEFI entry + GPT ESP both point at /efi.img).
            #    Same efi/boot layout grub-mkrescue used; sized to content + 3
            #    MiB slack (replay accepts a size different from the original —
            #    proven with an 8 MiB image against 53b498's real ISO).
            _efi_new="${_iso_tmp}/efi-new.img"
            _need_kb="$(du -kc "${_iso_tmp}/EFI/BOOT/"* | tail -1 | cut -f1)"
            truncate -s "$(( _need_kb / 1024 + 3 ))MiB" "${_efi_new}" \
                || _shim_fail "could not allocate the replacement EFI FAT image"
            mkfs.vfat "${_efi_new}" >/dev/null \
                || _shim_fail "mkfs.vfat on the replacement EFI image failed"
            mmd -i "${_efi_new}" ::/efi ::/efi/boot \
                || _shim_fail "mmd (mtools) failed on the replacement EFI image"
            mcopy -i "${_efi_new}" "${_iso_tmp}/EFI/BOOT/BOOTX64.EFI" ::/efi/boot/bootx64.efi \
                || _shim_fail "mcopy of shim into the replacement EFI image failed"
            mcopy -i "${_efi_new}" "${_iso_tmp}/EFI/BOOT/grubx64.efi" ::/efi/boot/grubx64.efi \
                || _shim_fail "mcopy of grubx64.efi into the replacement EFI image failed"
            if [ -f "${_iso_tmp}/EFI/BOOT/mmx64.efi" ]; then
                mcopy -i "${_efi_new}" "${_iso_tmp}/EFI/BOOT/mmx64.efi" ::/efi/boot/mmx64.efi \
                    || _shim_fail "mcopy of mmx64.efi into the replacement EFI image failed"
            fi
            # Org certs into the FAT too — MokManager browses the ESP it booted
            # from, not the ISO9660 tree.
            if [ -d "${_iso_tmp}/EFI/${SB_EFI_VENDOR}" ] \
                    && ls "${_iso_tmp}/EFI/${SB_EFI_VENDOR}/"* >/dev/null 2>&1; then
                mmd -i "${_efi_new}" "::/efi/${SB_EFI_VENDOR}" \
                    || _shim_fail "mmd of the vendor cert dir failed"
                mcopy -i "${_efi_new}" "${_iso_tmp}/EFI/${SB_EFI_VENDOR}/"* "::/efi/${SB_EFI_VENDOR}/" \
                    || _shim_fail "mcopy of the org certs into the EFI image failed"
            fi
            # 5) Rewrite the ISO, REPLAYING the boot equipment, and mirror the
            #    shim chain into the (lowercase, matching grub-mkrescue) tree so
            #    a mounted ISO shows what the firmware will run.
            _iso_new="${ISO_PATH%.iso}-sb.iso"
            _xr_args=( -boot_image any replay -hfsplus off
                       -map "${_efi_new}" /efi.img
                       -map "${_iso_tmp}/EFI/BOOT/BOOTX64.EFI" /efi/boot/bootx64.efi
                       -map "${_iso_tmp}/EFI/BOOT/grubx64.efi" /efi/boot/grubx64.efi )
            [ -f "${_iso_tmp}/EFI/BOOT/mmx64.efi" ] \
                && _xr_args+=( -map "${_iso_tmp}/EFI/BOOT/mmx64.efi" /efi/boot/mmx64.efi )
            [ -d "${_iso_tmp}/EFI/${SB_EFI_VENDOR}" ] \
                && _xr_args+=( -map "${_iso_tmp}/EFI/${SB_EFI_VENDOR}" "/efi/${SB_EFI_VENDOR}" )
            xorriso -indev "${ISO_PATH}" -outdev "${_iso_new}" "${_xr_args[@]}" \
                || { rm -f "${_iso_new}"; _shim_fail "xorriso rewrite (-boot_image any replay) failed"; }
            # 6) POSTCONDITION, not vibes: the NEW El Torito FAT must carry the
            #    byte-identical shim where firmware will look for it.
            xorriso -indev "${_iso_new}" -osirrox on \
                -extract /efi.img "${_iso_tmp}/efi-verify.img" \
                || { rm -f "${_iso_new}"; _shim_fail "cannot re-extract /efi.img from the rewritten ISO"; }
            mcopy -n -i "${_iso_tmp}/efi-verify.img" ::/efi/boot/bootx64.efi \
                "${_iso_tmp}/verify-bootx64.efi" \
                || { rm -f "${_iso_new}"; _shim_fail "the rewritten /efi.img has no efi/boot/bootx64.efi"; }
            cmp -s "${_shim_src}" "${_iso_tmp}/verify-bootx64.efi" \
                || { rm -f "${_iso_new}"; _shim_fail "bootx64.efi inside the rewritten /efi.img is NOT the shim binary"; }
            mv "${_iso_new}" "${ISO_PATH}"
            rm -rf "${_iso_tmp}"
            info "Shim added to live ISO and VERIFIED (El Torito FAT rebuilt: shim → grubx64.efi"
            info "→ kernel; Mac APM/HFS+ blessing dropped — see comment). Secure Boot ready."
        elif [ -f "${ISO_PATH}" ] && [ -n "${_shim_src}" ]; then
            warn "shim found (${_shim_src}) but xorriso/mkfs.vfat/mtools (mcopy+mmd) is missing —"
            warn "cannot post-process; live ISO ships BARE GRUB (no Secure Boot chain)."
        elif [ -f "${ISO_PATH}" ]; then
            info "Shim not found on build host (install sys-boot/shim); live ISO uses bare GRUB (no Secure Boot chain)"
        fi
        fi
    elif ${LIVE_ISO}; then
        warn "Live ISO requested but no vmlinuz/modules present — skipping (don't pass --skip-kernel)"
    fi

    if ${INSTALLER_ISO}; then
        INSTALLER_ISO_PATH="${WORK_DIR}/${BRAND}-x86-amd64-${ROLE_TAG}-${ENV}-${BUILD_TS}.installer.iso"
        banner "Building INSTALLER image (installer ISO: stage4 + install-x86.sh; boot a live USB to install)"
        INST_DIR="${BUILD_ROOT}/isoroot-installer"
        rm -rf "${INST_DIR}"; mkdir -p "${INST_DIR}/stage4"
        cp "${STAGE4}" "${INST_DIR}/stage4/"
        cp "${SPECS_DIR}/installer/install-x86.sh" "${INST_DIR}/install-x86.sh"; chmod +x "${INST_DIR}/install-x86.sh"
        # UNAFFILIATED: neutralize the STAGED installer copy — UI titles, the
        # cmdline key it greps, the home.conf path it sources, and the partition
        # labels it formats. Functional patterns are asserted first so upstream
        # drift fails the build loudly instead of shipping a half-neutral ISO.
        if ${UNAFFILIATED}; then
            for _pat in 'hugmesh.install=ncurses' '/etc/hugmesh/home.conf' 'SNAP_ESP' 'SNAP_ROOT' \
                        '# HugMesh x86_64 installer'; do
                grep -qF "${_pat}" "${INST_DIR}/install-x86.sh" \
                    || { err "install-x86.sh drifted: '${_pat}' not found (unaffiliated neutralization would break silently)"; exit 1; }
            done; unset _pat
            sed -i \
                -e "s/hugmesh\.install=/${INSTALL_CMDLINE_KEY}=/g" \
                -e "s|/etc/hugmesh/home.conf|${HOME_CONF_DIR}/home.conf|g" \
                -e "s/\bSNAP_ESP\b/${ESP_LABEL}/g" -e "s/\bSNAP_ROOT\b/${ROOT_LABEL}/g" \
                -e 's/HugMesh Installer/Gentoo Installer/g' \
                -e 's/Install HugMesh onto/Install Gentoo onto/g' \
                -e 's/# HugMesh encrypted-root layout/# Encrypted-root layout/' \
                -e 's/# HugMesh x86_64 installer.*/# Gentoo x86_64 installer (hardened desktop, optional GPU)./' \
                "${INST_DIR}/install-x86.sh"
        fi
        cp "${SPECS_DIR}/etc/fstab" "${INST_DIR}/fstab.template" 2>/dev/null || true
        # ── LUKS2 FDE + unlock-factor + home-archive payloads for the installer ──
        if ${ENCRYPT_ROOT}; then
            : > "${INST_DIR}/encrypt-root"   # marker: installer LUKS2-encrypts the target root
            info "Installer ISO: encrypt-root marker set (installer prompts for the root-unlock passphrase)."
            if [ -n "${LUKS_PASS}" ]; then
                # OPTIONAL unattended passphrase — loudly warned (it lands on the ISO).
                printf '%s' "${LUKS_PASS}" > "${INST_DIR}/luks-passphrase"; chmod 600 "${INST_DIR}/luks-passphrase"
                warn "Installer ISO carries an unattended LUKS passphrase (luks-passphrase, 0600) — anyone with the ISO can read it. Prefer the interactive install-time prompt."
            fi
        fi
        # Boot keyfile factor: generate a random keyfile the installer adds as a 2nd
        # LUKS keyslot (kept on the ESP). The matching copy is also saved to WORK_DIR
        # so the operator can stash it on a KEYS USB.
        if [ "${UNLOCK_KEYFILE}" = "boot" ]; then
            head -c 4096 /dev/urandom > "${INST_DIR}/luks-keyfile"; chmod 600 "${INST_DIR}/luks-keyfile"
            cp "${INST_DIR}/luks-keyfile" "${WORK_DIR}/${BRAND}-x86-amd64-${ROLE_TAG}-${ENV}-${BUILD_TS}.luks-keyfile"; chmod 600 "${WORK_DIR}/${BRAND}-x86-amd64-${ROLE_TAG}-${ENV}-${BUILD_TS}.luks-keyfile"
            info "Installer ISO: boot keyfile generated (also saved to WORK_DIR; stash it on a KEYS USB)."
        fi
        # FIDO2/YubiKey boot factor: marker → installer runs systemd-cryptenroll.
        [ "${UNLOCK_YUBIKEY}" = "boot" ] && { : > "${INST_DIR}/fido2-enroll"; info "Installer ISO: FIDO2/YubiKey LUKS enroll marker set (device must be present at install)."; }
        # Bundle a $HOME archive to unpack into the new user's home at install.
        if [ -n "${INCLUDE_HOME_ARCHIVE}" ] && [ -f "${INCLUDE_HOME_ARCHIVE}" ]; then
            cp "${INCLUDE_HOME_ARCHIVE}" "${INST_DIR}/home-archive.tar.xz"
            info "Installer ISO: bundling home archive ${INCLUDE_HOME_ARCHIVE} (unpacked into the new user's home)."
        fi
        if command -v xorriso >/dev/null; then
            xorriso -as mkisofs -o "${INSTALLER_ISO_PATH}" -volid "${INSTALL_VOLID}" -joliet -rock "${INST_DIR}"
            info "Installer ISO: ${INSTALLER_ISO_PATH}"
            [ "${ISO_PATH}" = "(not built)" ] && ISO_PATH="${INSTALLER_ISO_PATH}"
        else
            INSTALLER_ISO_PATH="${INST_DIR}  (tree; no xorriso to wrap an ISO)"
            warn "xorriso missing — left an installable tree at ${INST_DIR}"
            [ "${ISO_PATH}" = "(not built)" ] && ISO_PATH="${INSTALLER_ISO_PATH}"
        fi
    fi
fi

# ── 12. Summary ────────────────────────────────────────────────────
# UNAFFILIATED prints a neutral summary: no k8s/cluster-domain/KEYS-stick lines
# (none of that machinery exists on a plain desktop) — same neutralization the
# firstboot banner gets above ('hardened desktop' wording precedent).
if ${UNAFFILIATED}; then
    echo -e "\n${CYAN}${BOLD}=== ${BRAND_TITLE} x86_64 (hardened desktop, role=${ROLE}) ===${RST}"
else
    echo -e "\n${CYAN}${BOLD}=== ${BRAND_TITLE} x86_64 (hardened k8s, role=${ROLE}) ===${RST}"
fi
echo "  Profile:    $(readlink "${SYSROOT}/etc/portage/make.profile" | sed 's|.*/profiles/||')  (effective: read from the make.profile symlink, not from a spec copy)"
echo "  Kernel:     $(${SKIP_KERNEL} && echo 'skipped' || echo 'Gentoo hardened (gentoo-sources + hardened profile + KSPP/SELinux config)')"
if ${UNAFFILIATED}; then
    echo "  Role:       ${ROLE}   (no cluster affiliation)"
    echo "  ENV:        ${ENV}   (plain desktop: no cluster DNS/ACME machinery baked)"
else
    echo "  Role:       ${ROLE}   (cluster domain: ${CLUSTER_DOMAIN})"
    echo "  ENV:        ${ENV}   $([ "${ENV}" = test ] && echo '(LAN-first: cluster wildcard DNS; cloudflared/ACME pruned)' || echo '(PROD: public domain; Cloudflare/ACME; creds from keys USB)')"
fi
echo "  Brand:      ${BRAND} / \"${BRAND_TITLE}\" / ${ORG}${CONFIG_FILE:+   (profile: ${CONFIG_FILE})}"
echo "  GPU:        $(${GPU} && echo 'vendor-agnostic Mesa/Vulkan (amdgpu/i915/nouveau) + DRM kernel' || echo 'headless (no Mesa/Vulkan, virtio-gpu console only)')"
if ! ${UNAFFILIATED}; then
    echo "  k8s:        ${ROLE_K8S}  (init/join/single-node is applied at runtime by the KEYS stick)"
    echo "  Labels:     ${ROLE_LABELS}  (set on the KEYS stick: .hugmesh.node_labels)"
    echo "  headscale:  $(${ROLE_HEADSCALE} && echo 'in runlevel (identity/mesh control server)' || echo 'no (tailscale client only)')"
fi
echo "  Work dir:   ${WORK_DIR}  (products below); build root: ${BUILD_ROOT}"
echo "  Stage4:     ${STAGE4}"
echo "  Image:      ${IMG_PATH}"
echo "  FS tarball: ${FS_TAR_PATH}"
echo "  Live ISO:   ${ISO_PATH}"
echo "  Installer:  ${INSTALLER_ISO_PATH}"
echo ""
echo "  growroot expands the ext4 root to fill the medium on first boot."
echo "  Default artifact = the .img (dd it to a disk/USB; UEFI GPT, GRUB-EFI removable)."
# KEYS-stick provisioning is cluster machinery — an unaffiliated desktop has no
# stick to provision (the case below already has no arm for standalone roles).
if ! ${UNAFFILIATED}; then
    echo ""
    echo "  Provision a KEYS stick for this node with:"
    case "${ROLE}" in
        pki)     echo "    ./scripts/gen-provision-keys.sh -r pki -o keys-${ROLE_TAG}        # control-plane (kubeadm init)" ;;
        be)      echo "    ./scripts/gen-provision-keys.sh -r backend -o keys-${ROLE_TAG}    # worker; label hugmesh.net/backend=true" ;;
        fe)      echo "    ./scripts/gen-provision-keys.sh -r frontend -o keys-${ROLE_TAG}   # worker; label hugmesh.net/frontend=true" ;;
        be+gpu)  echo "    ./scripts/gen-provision-keys.sh -r backend -o keys-${ROLE_TAG}    # worker; edit:";
                 echo "    hugmesh.role=games, node_labels { hugmesh.net/compute: gpu }" ;;
        omnibus) echo "    ./scripts/gen-provision-keys.sh -r pki -o keys-${ROLE_TAG}        # single-node CP; all labels (pki/backend/frontend/compute=gpu)" ;;
    esac
fi
